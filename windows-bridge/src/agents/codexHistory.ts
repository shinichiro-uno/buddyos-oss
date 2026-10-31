import crypto from "node:crypto";
import type { ChildProcessWithoutNullStreams } from "node:child_process";
import fs from "node:fs/promises";
import type { Dirent } from "node:fs";
import os from "node:os";
import path from "node:path";
import { event, type AgentInfo, type CommandInfo, type HistoryMessage, type ModelCatalogItem, type ProviderCatalog, type SessionEvent, type SessionSummary } from "../protocol.js";
import { wslWindowsPath } from "../agentProbe.js";
import { mcpTokenEnv } from "../mcpService.js";
import type { RuntimeCommand } from "../runtime/command.js";
import { killProcessTree, normalizeRuntimeCwd, spawnRuntime } from "../runtime/command.js";
import { CodexAppServerSession } from "./codexAppServer.js";
import { orchestrator, type McpGrant } from "../mainagent/orchestrator.js";
import { codexMainAgentConfig, codexMainAgentExecArgs, codexMcpExecArgs, mainAgentPort, TOKEN_ENV_VAR } from "../mainagent/workspace.js";
import { codexSharedEnabled, CodexSharedAppServer, codexTerminals } from "./codexShared.js";
import { attachmentTextNotes, BaseAdapter, metadataText, type AgentSession, type Emit, type SessionOptions, type SessionOverrides } from "./types.js";
import { SubagentTracker } from "./subagentTracker.js";

interface ParsedSession {
  sessionId: string;
  cwd: string;
  created: string;
  modified: string;
  firstPrompt: string;
  lastPrompt: string;
  lastAssistant: string;
  messageCount: number;
}

interface ParsedMessage {
  role: string;
  content: string;
  timestamp?: string;
}

export class CodexHistoryAdapter extends BaseAdapter {
  readonly displayName = "Codex";
  readonly runtimeLabel: string;
  /** ライブ実行（codex exec）のときだけ interrupt（子プロセスの kill）できる。 */
  readonly supportsInterrupt: boolean;
  /** app-server なら生成中の送信を turn/steer で今のターンへ足せる（exec は予約に回す）。 */
  readonly supportsMidTurnInjection: boolean;
  /** config.toml の model_reasoning_effort に書く（mac と同じ値。実際の対応値は agent_info の supportedReasoningEfforts が優先）。 */
  readonly efforts = ["low", "medium", "high", "xhigh"];
  /**
   * config.toml の sandbox_mode / approval_policy に書く（codexModeValues）。ask = workspace-write ＋ on-request（毎回尋ねる）、
   * auto = workspace-write ＋ never（作業フォルダの中は尋ねない）。
   */
  readonly modes = ["plan", "ask", "auto", "dangerous"];
  private readonly config: CodexConfigStore;

  constructor(
    readonly id = "codex",
    private readonly runtime?: RuntimeCommand,
    private readonly store = new CodexHistoryStore(codexRootResolver(runtime))
  ) {
    super();
    this.runtimeLabel = runtime ? runtime.label : "local:codex-history";
    this.supportsInterrupt = Boolean(runtime);
    this.supportsMidTurnInjection = this.usesAppServer();
    this.config = new CodexConfigStore(store.root);
  }

  async openSession(sessionId: string | undefined, cwd?: string, options?: SessionOptions): Promise<AgentSession> {
    // 対話は app-server（承認を iPhone に出せる）。cron 等の無人実行と BUDDYOS_CODEX_TRANSPORT=exec は
    // codex exec（承認なしで最後まで走る）。codex が無ければ履歴の読み取りだけ。
    // ほかのセッションを操作する MCP の合鍵を渡す（mainagent のフォルダ・設定 allSessions のときのふつうのセッション。無人実行には
    // 渡さない）。mainagent のフォルダだけ読むだけにする。
    const mcp = this.runtime ? orchestrator.grantFor(this.id, sessionId, cwd, options?.unattended, options?.heartbeat) : undefined;
    if (this.runtime && this.usesAppServer(options)) {
      const config = this.config;
      const runtime = this.runtime;
      // チャットの上書き（chatOverrides）はそのチャットの turn/start にだけ効かせ、config.toml には書かない（mac と同じ）。
      const session = new CodexAppServerSession(
        this.id,
        sessionId,
        cwd,
        runtime,
        async (overrides) => {
          const model = overrides.model ?? (await config.currentModel());
          const effort = validCodexEffort(overrides.reasoningEffort) ?? (await config.currentReasoningEffort());
          // mainagent は書かない（読むだけ）ので、尋ねることも無い（mac と同じ）。
          if (mcp?.main) return { model, effort, approvalPolicy: "never", sandboxMode: "read-only" };
          // チャットで選んだモード（plan / ask / auto / dangerous）の sandbox / approval > config.toml > 既定（mac と同じ）。
          const chatMode = overrides.mode ? codexModeValues(overrides.mode) : undefined;
          const approvalPolicy = chatMode?.approvalPolicy ?? (await config.currentApprovalPolicy()) ?? "on-request";
          const sandboxMode = chatMode?.sandboxMode ?? (await config.currentSandboxMode()) ?? "workspace-write";
          return { model, effort, approvalPolicy, sandboxMode, mode: config.currentCodexMode(approvalPolicy, sandboxMode) };
        },
        // ターミナル（buddy-codex）と共有の app-server があればそこへ繋ぐ。
        this.sharedTerminal ? () => CodexSharedAppServer.ensureRunning(runtime) : undefined,
        // Bridge の MCP（点区切りのキーで -c と同じ上書き）。承認は Bridge が尋ねる。
        mcp ? () => codexMainAgentConfig(mcp.token, mainAgentPort()) : undefined,
        mcp ? () => orchestrator.revoke(mcp.token) : undefined
      );
      if (mcp) orchestrator.bind(mcp.token, session);
      return session;
    }
    if (this.runtime) {
      const session = new CodexLiveSession(this.id, sessionId, cwd, this.runtime, this.config, options?.permissionMode, mcp);
      if (mcp) orchestrator.bind(mcp.token, session);
      return session;
    }
    return new CodexReadOnlySession(this.id, sessionId ?? cryptoRandomId());
  }

  /** 承認を往復できる app-server で動かすか（無人実行・exec 指定でなければ）。 */
  usesAppServer(options?: SessionOptions): boolean {
    if (!this.runtime || options?.unattended || options?.permissionMode) return false;
    return process.env.BUDDYOS_CODEX_TRANSPORT !== "exec";
  }

  /** ターミナル（buddy-codex）と共有の app-server で会話を分け合えるか（native の codex で app-server の経路）。 */
  get sharedTerminal(): boolean {
    return this.usesAppServer() && codexSharedEnabled(this.runtime);
  }

  get terminal(): boolean {
    return this.sharedTerminal;
  }

  async terminalSession(sessionId: string): Promise<boolean> {
    return this.sharedTerminal && codexTerminals.isLive(sessionId);
  }

  async listSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    const merged = await this.store.listSessions(limit, cwd);
    if (!this.sharedTerminal) return merged;
    // ターミナルで開かれている thread は印を付けて先頭に固定する。まだ履歴に無い thread は台帳から行を作って足す。
    const norm = (p?: string): string | undefined => (p ? p.replace(/[\\/]+$/, "").replace(/\\/g, "/").toLowerCase() : undefined);
    const live = codexTerminals.liveEntries().filter((e) => !cwd || !e.cwd || norm(e.cwd) === norm(cwd));
    if (live.length === 0) return merged;
    const liveIds = new Set(live.map((e) => e.threadId));
    const seen = new Set(merged.map((s) => s.sessionId));
    const out = merged.map((s) => (liveIds.has(s.sessionId) ? { ...s, terminal: true } : s));
    for (const e of live) {
      if (seen.has(e.threadId)) continue;
      out.push({ sessionId: e.threadId, title: "ターミナル", lastActive: new Date(e.openedAt).toISOString(), cwd: e.cwd, terminal: true });
    }
    out.sort((a, b) => Number(Boolean(b.terminal)) - Number(Boolean(a.terminal)) || b.lastActive.localeCompare(a.lastActive));
    return out.slice(0, Math.max(1, limit));
  }

  async loadHistory(sessionId: string): Promise<HistoryMessage[]> {
    return this.store.loadHistory(sessionId);
  }

  async listCommands(): Promise<CommandInfo[]> {
    return [
      { id: "plan", kind: "prompt", title: "plan", subtitle: "Plan first, show options, and wait" },
      { id: "options", kind: "prompt", title: "options", subtitle: "Present 2-3 choices with a recommendation" },
      { id: "resume", kind: "codex", title: "resume", subtitle: "Resume a Codex thread" },
      { id: "fork", kind: "codex", title: "fork", subtitle: "Fork a previous Codex thread" },
      { id: "review", kind: "codex", title: "review", subtitle: "Run a Codex code review" },
      { id: "model", kind: "codex", title: "model", subtitle: "Change or inspect the active model" },
      { id: "help", kind: "codex", title: "help", subtitle: "Show Codex help" }
    ];
  }

  async renameSession(sessionId: string, title: string): Promise<boolean> {
    return this.store.renameSession(sessionId, title);
  }

  async currentInfo(): Promise<AgentInfo> {
    const approvalPolicy = await this.config.currentApprovalPolicy();
    const sandboxMode = await this.config.currentSandboxMode();
    return {
      model: await this.config.currentModel(),
      provider: "openai",
      reasoningEffort: await this.config.currentReasoningEffort(),
      codexMode: this.config.currentCodexMode(approvalPolicy, sandboxMode),
      approvalPolicy,
      sandboxMode,
      runtime: this.runtimeLabel
    };
  }

  async setModel(model: string, _provider?: string, reasoningEffort?: string, codexMode?: string): Promise<void> {
    if (model.trim()) await this.config.setModel(model);
    if (reasoningEffort !== undefined) await this.config.setReasoningEffort(reasoningEffort);
    if (codexMode !== undefined) await this.config.setCodexMode(codexMode);
  }

  async listAvailableModels(): Promise<ProviderCatalog[]> {
    const configured = await this.config.loadBuddyModelCatalog();
    if (configured.length > 0) return configured;
    const currentModel = await this.config.currentModel();
    const liveModels = this.runtime ? await loadCodexModelCatalog(this.runtime, currentModel) : [];
    if (liveModels.length > 0) {
      return [{
        id: "openai",
        label: "OpenAI",
        models: liveModels
      }];
    }
    const ids = await this.config.defaultModelIds([]);
    return [{
      id: "openai",
      label: "OpenAI",
      models: ids.map((id) => ({ id, label: id }))
    }];
  }
}

async function loadCodexModelCatalog(runtime: RuntimeCommand, currentModel: string | undefined): Promise<ModelCatalogItem[]> {
  const stdout = await runCodexDebugModels(runtime);
  if (!stdout) return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout) as unknown;
  } catch {
    return [];
  }

  const root = asRecord(parsed);
  const rows = Array.isArray(root?.models) ? root.models : [];
  const listed = rows
    .map(asRecord)
    .filter((row): row is Record<string, unknown> => !!row)
    .filter((row) => stringValue(row.visibility) === "list")
    .map((row) => {
      const slug = nonEmpty(stringValue(row.slug));
      if (!slug) return undefined;
      return {
        id: slug,
        label: nonEmpty(stringValue(row.display_name)) ?? slug,
        ...(nonEmpty(stringValue(row.description)) ? { subtitle: nonEmpty(stringValue(row.description)) } : {})
      };
    })
    .filter((model): model is ModelCatalogItem => !!model);

  return mergeCurrentModel(currentModel, listed);
}

function runCodexDebugModels(runtime: RuntimeCommand): Promise<string | undefined> {
  return new Promise((resolve) => {
    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawnRuntime(runtime, ["debug", "models"], { env: process.env, stdio: "pipe" });
    } catch {
      resolve(undefined);
      return;
    }
    // stdin 待ちで 5 秒タイムアウトまで引っ張らないよう、入力は即 EOF にする。
    child.stdin.on("error", () => {});
    child.stdin.end();

    let settled = false;
    let stdout = "";
    const finish = (value: string | undefined): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };

    const timer = setTimeout(() => {
      killProcessTree(child);
      finish(undefined);
    }, 5000);

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (stdout.length < 2_000_000) stdout += chunk;
    });
    child.stderr.resume();
    child.on("close", (code) => {
      finish(code === 0 ? stdout : undefined);
    });
    child.on("error", () => {
      finish(undefined);
    });
  });
}

function mergeCurrentModel(currentModel: string | undefined, models: ModelCatalogItem[]): ModelCatalogItem[] {
  const result: ModelCatalogItem[] = [];
  const seen = new Set<string>();
  const append = (model: ModelCatalogItem): void => {
    const id = model.id.trim();
    if (!id || seen.has(id)) return;
    seen.add(id);
    result.push(model);
  };

  const current = nonEmpty(currentModel);
  if (current && !models.some((model) => model.id === current)) {
    append({ id: current, label: current });
  }
  for (const model of models) append(model);
  return result;
}

class CodexReadOnlySession implements AgentSession {
  private started = false;

  constructor(
    private readonly agentId: string,
    readonly sessionId: string
  ) {}

  async send(_text: string, _originalEvent: SessionEvent, emit: Emit): Promise<void> {
    if (!this.started) {
      this.started = true;
      emit(event.sessionStarted(this.agentId, this.sessionId));
    }
    emit(event.error(
      this.agentId,
      this.sessionId,
      "Codex live execution is not wired yet. This adapter currently exposes local Codex history only."
    ));
  }

  async close(): Promise<void> {}
}

/**
 * `codex exec --json` を 1 ターン 1 子プロセスで回すライブセッション
 * （mac の CodexLiveSession を TS へ移植。ClaudeCodeSession と同じ流儀）。
 * 履歴は codex 自身が ~/.codex/sessions に書く rollout を CodexHistoryStore 経由で読む。
 */
class CodexLiveSession implements AgentSession {
  public sessionId: string;
  private resolvedSessionId: string | undefined;
  private didEmitSessionStarted: boolean;
  // 同一セッションに複数 send が並行しても各子を取りこぼさず追跡する
  // （単一フィールドだと後発 spawn が前の子を untracked 化し orphan になる）。
  private readonly activeChildren = new Set<ChildProcessWithoutNullStreams>();
  /** interrupt() で止めた子プロセス。その終了はエラーではなく done で畳む。 */
  private readonly interruptedChildren = new WeakSet<ChildProcessWithoutNullStreams>();
  /** interrupt() のたびに進める。spawn 前（execOverrides 待ち）の send が停止要求を検知するのに使う。 */
  private interruptGeneration = 0;
  /** このチャットだけのモデル / Effort / モード。次の codex exec の -c 上書きに使う。 */
  private overrides: SessionOverrides = {};

  constructor(
    private readonly agentId: string,
    initialSessionId: string | undefined,
    private readonly cwd: string | undefined,
    private readonly runtime: RuntimeCommand,
    private readonly config: CodexConfigStore,
    /** cron 等が指定した権限モード（plan / edit / auto / dangerous）。config.toml より優先する。 */
    private readonly permissionOverride?: string,
    /** 合鍵（BUDDYOS_CODEX_TRANSPORT=exec のとき）。あれば -c で Bridge の MCP を渡す。mainagent のフォルダなら読むだけにする。 */
    private readonly mcp?: McpGrant
  ) {
    this.resolvedSessionId = initialSessionId;
    // 本物の codex thread id が来るまでは pending- プレフィックスのプレースホルダ。
    // これにより新規セッションを誤って `exec resume <偽id>` しないようゲートする。
    this.sessionId = initialSessionId ?? `pending-${crypto.randomUUID().slice(0, 8)}`;
    this.didEmitSessionStarted = Boolean(initialSessionId);
  }

  async send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    const userText = metadataText(originalEvent, text);
    const notes = attachmentTextNotes(originalEvent);
    const prompt = notes.length > 0 ? `${notes.join("\n\n")}\n\n${userText}` : userText;

    const messageId = crypto.randomUUID();
    // execOverrides の待ち（WSL だと config.toml を UNC 越しに読む）の間に来た interrupt() には止める子が
    // まだ無いので、世代を見て spawn せずに done で畳む（放っておくと停止後にターンが最後まで走る）。
    const interruptGeneration = this.interruptGeneration;
    const overrides = await this.execOverrides();
    if (this.interruptGeneration !== interruptGeneration) {
      emit(event.done(this.agentId, this.sessionId, messageId));
      return;
    }
    const args = this.argsForPrompt(overrides);

    let child: ChildProcessWithoutNullStreams;
    try {
      // OAuth で足した MCP のトークンは bearer_token_env_var が指す環境変数で渡す。mainagent の合鍵も環境変数で（引数に載せない）。
      const env = { ...process.env, ...mcpTokenEnv(), ...(this.mcp ? { [TOKEN_ENV_VAR]: this.mcp.token } : {}) };
      child = spawnRuntime(this.runtime, args, { cwd: this.cwd, env, stdio: "pipe" });
    } catch (error) {
      emit(event.error(this.agentId, this.sessionId, `Codex spawn failed: ${error instanceof Error ? error.message : String(error)}`));
      return;
    }
    this.activeChildren.add(child);
    // プロンプトは argv ではなく stdin で渡す（引数は `-`）。npm 版 codex.cmd は cmd.exe 経由で改行が
    // 空白に潰れ 8191 文字の上限もあるので、複数行・添付入りの長文を argv には載せられない。
    // codex exec は EOF まで stdin を読むので、書いたら end() で閉じる（閉じないとターンが終わらない）。
    // 子が先に死んだ場合の EPIPE / ERR_STREAM_DESTROYED は uncaughtException 化しないようログだけにし、
    // 失敗自体は close の exit code 側で error として返す。
    child.stdin.on("error", (error) => {
      process.stderr.write(`[codex:${this.runtime.kind}] stdin error: ${String(error)}\n`);
    });
    try {
      child.stdin.end(prompt);
    } catch (error) {
      process.stderr.write(`[codex:${this.runtime.kind}] stdin write failed: ${error instanceof Error ? error.message : String(error)}\n`);
    }

    let assistant = "";
    let stderr = "";
    // サブエージェント（multi_agent の spawn_agent。1 ターン = 1 プロセスなのでターン内で完結する。
    // プロセスが終わった時点で実行中の行は、子も一緒に止まったものとして閉じる）。
    const subagents = new SubagentTracker();
    const abandonSubagents = (state: string): void => {
      const p = subagents.abandonRunning({ state });
      if (p) emit(event.workflowProgress(this.agentId, this.sessionId, p));
    };

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderr += chunk;
      process.stderr.write(`[codex:${this.runtime.kind}] ${chunk}`);
    });

    child.stdout.setEncoding("utf8");
    let buffer = "";
    child.stdout.on("data", (chunk: string) => {
      buffer += chunk;
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) break;
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        const parsed = parseCodexLine(line);
        for (const p of codexSubagentPayloads(line, subagents)) emit(event.workflowProgress(this.agentId, this.sessionId, p));
        if (parsed.sessionId && parsed.sessionId !== this.sessionId) {
          this.sessionId = parsed.sessionId;
          this.resolvedSessionId = parsed.sessionId;
        }
        if (parsed.sessionId) this.emitSessionStartedIfNeeded(emit);
        if (parsed.text) {
          this.emitSessionStartedIfNeeded(emit);
          assistant += parsed.text;
          emit(event.assistantDelta(this.agentId, this.sessionId, messageId, parsed.text));
        }
      }
    });

    await new Promise<void>((resolve) => {
      child.on("close", (code) => {
        this.activeChildren.delete(child);
        // interrupt() で止めた場合は非 0 終了でもエラーにせず done で畳む（done で currentTurn も終わる）。
        if (code !== 0 && !this.interruptedChildren.has(child)) {
          abandonSubagents("failed");
          emit(event.error(this.agentId, this.sessionId, `Codex failed: ${stderr.trim() || `exit code ${code}`}`));
          resolve();
          return;
        }
        abandonSubagents("stopped");
        this.emitSessionStartedIfNeeded(emit);
        emit(event.done(this.agentId, this.sessionId, messageId));
        resolve();
      });
      child.on("error", (error) => {
        this.activeChildren.delete(child);
        abandonSubagents("failed");
        emit(event.error(this.agentId, this.sessionId, `Codex spawn failed: ${error.message}`));
        resolve();
      });
    });
  }

  /// 実行中ターンを止める。codex exec にはターンだけ止める手段が無いので子プロセスツリーごと kill し
  /// （close() と同じ経路だがセッションは閉じない）、close で done として畳む。次の send は exec resume で続ける。
  /// spawn 前の send は interruptGeneration で止める（send() 参照）。
  async interrupt(): Promise<void> {
    this.interruptGeneration += 1;
    for (const child of this.activeChildren) {
      this.interruptedChildren.add(child);
      killProcessTree(child);
    }
  }

  async close(): Promise<void> {
    for (const child of this.activeChildren) killProcessTree(child);
    this.activeChildren.clear();
    if (this.mcp) orchestrator.revoke(this.mcp.token);
  }

  applyOverrides(overrides: SessionOverrides): void {
    this.overrides = { ...overrides };
  }

  /// プロンプト本文は stdin で渡すので、位置引数は `-`（stdin から読む）にする（send() 参照）。
  /// 作業フォルダは spawn の cwd に加えて -C でも明示する（workspace-write の範囲を Bridge の起動フォルダにしない）。
  private argsForPrompt(overrides: string[]): string[] {
    return codexExecArgs(this.resolvedSessionId, normalizeRuntimeCwd(this.runtime, this.cwd), overrides);
  }

  private async execOverrides(): Promise<string[]> {
    // cron 等の指定 > チャットの上書き > config.toml。モデル / Effort はチャットの上書きがあるときだけ -c で渡す。
    const chat = codexChatOverrides(this.overrides);
    // mainagent: Bridge の MCP を -c で渡し、sandbox は read-only・approval は never（mac と同じ。合鍵は環境変数で渡す）。
    if (this.mcp?.main) return [...codexMainAgentExecArgs(mainAgentPort()), ...chat];
    // ふつうのセッション（設定 allSessions）: MCP だけ足し、sandbox / approval はそのセッションのまま。
    const mcp = this.mcp ? codexMcpExecArgs(mainAgentPort()) : [];
    if (this.permissionOverride) return [...mcp, ...codexExecOverrides(this.permissionOverride), ...chat];
    if (this.overrides.mode && codexModeValues(this.overrides.mode)) return [...mcp, ...codexExecOverrides(this.overrides.mode), ...chat];
    const approvalPolicy = await this.config.currentApprovalPolicy();
    const sandboxMode = await this.config.currentSandboxMode();
    const mode = this.config.currentCodexMode(approvalPolicy, sandboxMode);
    return [...mcp, ...codexExecOverrides(mode), ...chat];
  }

  private emitSessionStartedIfNeeded(emit: Emit): void {
    if (this.didEmitSessionStarted) return;
    this.didEmitSessionStarted = true;
    emit(event.sessionStarted(this.agentId, this.sessionId));
  }
}

/// `codex exec` の引数。作業フォルダがあれば -C で明示し、続きなら resume で再開する（プロンプトは stdin の `-`）。
export function codexExecArgs(sessionId: string | undefined, dir: string | undefined, overrides: string[]): string[] {
  const cd = dir ? ["-C", dir] : [];
  if (sessionId && !sessionId.startsWith("pending-")) {
    return ["exec", ...cd, "resume", "--json", "--skip-git-repo-check", ...overrides, sessionId, "-"];
  }
  return ["exec", ...cd, "--json", "--skip-git-repo-check", ...overrides, "-"];
}

const CODEX_EFFORTS = ["minimal", "low", "medium", "high", "xhigh"];

function validCodexEffort(effort: string | undefined): string | undefined {
  return effort && CODEX_EFFORTS.includes(effort) ? effort : undefined;
}

/// チャットの上書きのモデル / Effort → `codex exec -c`（config.toml は書き換えない）。
export function codexChatOverrides(overrides: SessionOverrides): string[] {
  const out: string[] = [];
  if (overrides.model) out.push("-c", `model="${escapeTomlBasicString(overrides.model)}"`);
  const effort = validCodexEffort(overrides.reasoningEffort);
  if (effort) out.push("-c", `model_reasoning_effort="${effort}"`);
  return out;
}

/// BuddyOS モード → `codex exec -c` 上書き。無人実行（承認往復に応答できない）なので
/// approval は常に never に固定し、モードに応じて sandbox を切り替える。
function codexExecOverrides(mode: string | undefined): string[] {
  let sandbox: string;
  switch (mode) {
    case "plan":
      sandbox = "read-only";
      break;
    case "dangerous":
      sandbox = "danger-full-access";
      break;
    default:
      sandbox = "workspace-write"; // ask / auto / edit / 未設定（無人なので ask も尋ねない）
  }
  return ["-c", `sandbox_mode="${sandbox}"`, "-c", "approval_policy=\"never\""];
}

/// `codex exec --json` の NDJSON 1 行をパースする（mac CodexLiveSession.parseLine 相当）。
function parseCodexLine(line: string): { text?: string; sessionId?: string } {
  if (line === "Reading additional input from stdin...") return {};
  let object: Record<string, unknown> | undefined;
  try {
    object = asRecord(JSON.parse(line));
  } catch {
    return {};
  }
  if (!object) return {};
  if (object.type === "thread.started") {
    const tid = stringValue(object.thread_id);
    return tid ? { sessionId: tid } : {};
  }
  if (object.type === "item.completed") {
    const item = asRecord(object.item);
    if (item && item.type === "agent_message") {
      const text = stringValue(item.text);
      if (text) return { text };
    }
  }
  return {};
}

/// `codex exec --json` の collab_tool_call（spawn_agent / wait 等）からサブエージェントの進行を取り出す。
/// item = { type: "collab_tool_call", tool, receiver_thread_ids, prompt, agents_states: { id: { status, message } } }。
/// app-server（camelCase）と同じ形も受ける。
function codexSubagentPayloads(line: string, tracker: SubagentTracker): string[] {
  if (!line.includes("collab")) return [];
  let object: Record<string, unknown> | undefined;
  try {
    object = asRecord(JSON.parse(line));
  } catch {
    return [];
  }
  const item = asRecord(object?.item);
  if (!item || (item.type !== "collab_tool_call" && item.type !== "collabAgentToolCall")) return [];
  const out: string[] = [];
  const push = (p: string | undefined): void => {
    if (p) out.push(p);
  };
  const tool = stringValue(item.tool);
  const receivers = (Array.isArray(item.receiver_thread_ids) ? item.receiver_thread_ids : Array.isArray(item.receiverThreadIds) ? item.receiverThreadIds : [])
    .filter((v): v is string => typeof v === "string");
  if (tool === "spawn_agent" || tool === "spawnAgent") {
    for (const id of receivers) push(tracker.begin(id, stringValue(item.prompt), undefined, stringValue(item.model)));
  }
  const states = asRecord(item.agents_states) ?? asRecord(item.agentsStates) ?? {};
  for (const [id, raw] of Object.entries(states)) {
    const state = asRecord(raw);
    if (!state || !tracker.has(id)) continue;
    const message = stringValue(state.message);
    const status = stringValue(state.status) ?? "";
    // 止めたもの（interrupted）は失敗ではない（app-server の agentsStates と同じ対応）。
    if (["completed", "shutdown"].includes(status)) push(tracker.finish(id, "done", message));
    else if (status === "interrupted") push(tracker.finish(id, "stopped", message));
    else if (["errored", "not_found", "notFound"].includes(status)) push(tracker.finish(id, "failed", message));
    else if (message) push(tracker.activity(id, message));
  }
  return out;
}

class CodexHistoryStore {
  /** @param root ~/.codex の場所（codexRootResolver。WSL で動く codex は WSL 側）。 */
  constructor(readonly root: () => Promise<string> = async () => codexRoot()) {}

  async listSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    const names = await this.loadSessionNames();
    const normalizedFilter = normalizePath(cwd);
    const maxCount = Math.max(1, limit);
    const result: SessionSummary[] = [];

    for (const file of await this.codexSessionFiles()) {
      const parsed = await this.parseSession(file);
      if (!parsed) continue;
      if (normalizedFilter && normalizePath(parsed.cwd) !== normalizedFilter) continue;

      result.push({
        sessionId: parsed.sessionId,
        title: nonEmpty(names.get(parsed.sessionId)) ?? preview(parsed.firstPrompt) ?? preview(parsed.lastAssistant) ?? parsed.sessionId,
        lastActive: parsed.modified,
        messageCount: parsed.messageCount,
        cwd: parsed.cwd
      });
      if (result.length >= maxCount) break;
    }

    return result;
  }

  async loadHistory(sessionId: string): Promise<HistoryMessage[]> {
    const file = await this.findSessionFile(sessionId);
    if (!file) return [];
    const messages = await this.parseMessages(file);
    return messages.map((message, index) => ({
      role: message.role,
      content: message.content,
      messageId: `${sessionId}-${index}`,
      createdAt: message.timestamp
    }));
  }

  async renameSession(sessionId: string, title: string): Promise<boolean> {
    try {
      const file = path.join(await this.root(), "session_index.jsonl");
      await fs.mkdir(path.dirname(file), { recursive: true });
      await fs.appendFile(file, `${JSON.stringify({
        id: sessionId,
        thread_name: title,
        updated_at: new Date().toISOString()
      })}\n`);
      return true;
    } catch {
      return false;
    }
  }

  private async codexSessionFiles(): Promise<string[]> {
    const root = path.join(await this.root(), "sessions");
    const files: Array<{ file: string; modified: number }> = [];
    await collectJsonlFiles(root, files);
    return files.sort((a, b) => b.modified - a.modified).map((entry) => entry.file);
  }

  private async findSessionFile(sessionId: string): Promise<string | undefined> {
    const files = await this.codexSessionFiles();
    const byName = files.find((file) => path.basename(file, ".jsonl").includes(sessionId));
    if (byName) return byName;

    for (const file of files) {
      const parsed = await this.parseSession(file);
      if (parsed?.sessionId === sessionId) return file;
    }
    return undefined;
  }

  private async parseSession(file: string): Promise<ParsedSession | undefined> {
    const lines = await readLines(file);
    let sessionId = fallbackSessionId(file);
    let cwd = "";
    let created = "";
    let modified = "";
    let firstPrompt = "";
    let lastPrompt = "";
    let lastAssistant = "";
    const summaryMessages: ParsedMessage[] = [];
    let skip = false;

    for (const line of lines) {
      const entry = parseJsonLine(line);
      if (!entry) continue;
      const timestamp = stringValue(entry.timestamp);
      if (timestamp) {
        if (!created) created = timestamp;
        modified = timestamp;
      }

      switch (stringValue(entry.type)) {
        case "session_meta": {
          const payload = asRecord(entry.payload);
          if (!payload) break;
          if (isInternalSessionSource(payload.source)) skip = true;
          sessionId = nonEmpty(stringValue(payload.id)) ?? sessionId;
          cwd = nonEmpty(stringValue(payload.cwd)) ?? cwd;
          break;
        }
        case "turn_context": {
          const payload = asRecord(entry.payload);
          cwd = cwd || nonEmpty(stringValue(payload?.cwd)) || "";
          break;
        }
        case "event_msg": {
          const payload = asRecord(entry.payload);
          const type = stringValue(payload?.type);
          if (type === "user_message") {
            const text = nonEmpty(stripImageTags(stringValue(payload?.message) ?? ""));
            if (text && !isInjectedUserContext(text)) {
              if (appendMessage(summaryMessages, "user", text, timestamp)) {
                if (!firstPrompt) firstPrompt = text;
                lastPrompt = text;
              }
            }
          } else if (type === "agent_message") {
            const text = nonEmpty(stringValue(payload?.message));
            if (text) {
              if (appendMessage(summaryMessages, "assistant", text, timestamp)) {
                lastAssistant = text;
              }
            }
          }
          break;
        }
        case "response_item": {
          const payload = asRecord(entry.payload);
          if (!payload || stringValue(payload.type) !== "message") break;
          const role = stringValue(payload.role);
          if (role === "assistant") {
            const text = nonEmpty(messageText(payload, "output_text"));
            if (text) {
              if (appendMessage(summaryMessages, "assistant", text, timestamp)) {
                lastAssistant = text;
              }
            }
          } else if (role === "user") {
            const text = nonEmpty(messageText(payload, "input_text"));
            if (text && !isInjectedUserContext(text)) {
              if (appendMessage(summaryMessages, "user", text, timestamp)) {
                if (!firstPrompt) firstPrompt = text;
                lastPrompt = text;
              }
            }
          }
          break;
        }
      }
    }

    if (skip || !cwd || summaryMessages.length === 0) return undefined;
    if (!modified) modified = (await fileModifiedIso(file)) ?? created;
    if (!created) created = modified;
    return { sessionId, cwd, created, modified, firstPrompt, lastPrompt, lastAssistant, messageCount: summaryMessages.length };
  }

  private async parseMessages(file: string): Promise<ParsedMessage[]> {
    const messages: ParsedMessage[] = [];
    for (const line of await readLines(file)) {
      const entry = parseJsonLine(line);
      if (!entry) continue;
      const timestamp = stringValue(entry.timestamp);

      switch (stringValue(entry.type)) {
        case "event_msg": {
          const payload = asRecord(entry.payload);
          const type = stringValue(payload?.type);
          if (type === "user_message") {
            const text = nonEmpty(stripImageTags(stringValue(payload?.message) ?? ""));
            if (text && !isInjectedUserContext(text)) appendMessage(messages, "user", text, timestamp);
          } else if (type === "agent_message") {
            const text = nonEmpty(stringValue(payload?.message));
            if (text) appendMessage(messages, "assistant", text, timestamp);
          }
          break;
        }
        case "response_item": {
          const payload = asRecord(entry.payload);
          if (!payload || stringValue(payload.type) !== "message") break;
          if (stringValue(payload.role) === "assistant") {
            const text = nonEmpty(messageText(payload, "output_text"));
            if (text) appendMessage(messages, "assistant", text, timestamp);
          } else if (stringValue(payload.role) === "user") {
            const text = nonEmpty(messageText(payload, "input_text"));
            if (text && !isInjectedUserContext(text)) appendMessage(messages, "user", text, timestamp);
          }
          break;
        }
      }
    }
    return messages;
  }

  private async loadSessionNames(): Promise<Map<string, string>> {
    const names = new Map<string, string>();
    const file = path.join(await this.root(), "session_index.jsonl");
    for (const line of await readLines(file)) {
      const entry = parseJsonLine(line);
      const id = nonEmpty(stringValue(entry?.id));
      if (!id) continue;
      names.set(id, nonEmpty(stringValue(entry?.thread_name)) ?? "");
    }
    return names;
  }
}

async function collectJsonlFiles(dir: string, files: Array<{ file: string; modified: number }>): Promise<void> {
  let entries: Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }

  await Promise.all(entries.map(async (entry) => {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await collectJsonlFiles(file, files);
      return;
    }
    if (!entry.isFile() || !file.endsWith(".jsonl")) return;
    try {
      const stat = await fs.stat(file);
      files.push({ file, modified: stat.mtimeMs });
    } catch {
      // Ignore files that disappear during scan.
    }
  }));
}

async function readLines(file: string): Promise<string[]> {
  try {
    return (await fs.readFile(file, "utf8")).split("\n").filter((line) => line.trim().length > 0);
  } catch {
    return [];
  }
}

function parseJsonLine(line: string): Record<string, unknown> | undefined {
  try {
    const parsed = JSON.parse(line) as unknown;
    return asRecord(parsed);
  } catch {
    return undefined;
  }
}

function messageText(payload: Record<string, unknown>, itemType: string): string {
  const content = Array.isArray(payload.content) ? payload.content : [];
  const text = content
    .map(asRecord)
    .filter((item): item is Record<string, unknown> => !!item && item.type === itemType)
    .map((item) => stringValue(item.text) ?? "")
    .filter(Boolean)
    .join("\n");
  return itemType === "input_text" ? stripImageTags(text) : text;
}

/** 画像を付けた発話を挟む `<image name=[Image #1] path="…">` と `</image>` を外す（mac の CodexInjectedContext と同じ）。 */
export function stripImageTags(text: string): string {
  return text.replace(/<\/?image\b[^>]*>/g, "").trim();
}

function appendMessage(messages: ParsedMessage[], role: string, content: string, timestamp?: string): boolean {
  const normalized = compact(content);
  if (!normalized) return false;
  const last = messages.at(-1);
  if (last?.role === role && compact(last.content) === normalized) return false;
  messages.push({ role, content, ...(timestamp ? { timestamp } : {}) });
  return true;
}

function codexRoot(): string {
  return process.env.BUDDYOS_CODEX_HOME || process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
}

// WSL 側の CODEX_HOME（あれば）か $HOME/.codex を UNC パスで返す。wsl.exe の引数に " を渡すと引用が
// 崩れ得るので " は使わない（代わりに IFS= で空白入りのパスを分割させない）。wslpath が失敗したら何も
// 出さない（printf だけ走ると \.codex が成功扱いでキャッシュされ、カレントドライブの C:\.codex に固定される）。
const WSL_CODEX_ROOT_SCRIPT = "IFS=; case $CODEX_HOME in '') ;; *) [ -d $CODEX_HOME ] && exec wslpath -w $CODEX_HOME;; esac; h=$(wslpath -w $HOME) && case $h in '') ;; *) printf '%s\\\\.codex' $h;; esac";

/**
 * ~/.codex の場所を返す関数。WSL で動く codex は rollout / session_index / config.toml を WSL 側の
 * ホーム（\\wsl$\<distro>\home\<user>\.codex、または WSL 側の CODEX_HOME）に書くので、Windows 側の
 * ~/.codex ではなくそちらを読む（読まないと履歴一覧が空になり、モデル設定も効かない）。
 * BUDDYOS_CODEX_HOME はどちらでも最優先。WSL 側を解決できないときは Windows 側に落とす（次回また解決を試す）。
 */
function codexRootResolver(runtime: RuntimeCommand | undefined): () => Promise<string> {
  if (runtime?.kind !== "wsl") return async () => codexRoot();
  return async () => process.env.BUDDYOS_CODEX_HOME || (await wslWindowsPath(runtime, WSL_CODEX_ROOT_SCRIPT)) || codexRoot();
}

export class CodexConfigStore {
  constructor(private readonly root: () => Promise<string>) {}

  async currentModel(): Promise<string | undefined> {
    return this.stringValue("model");
  }

  async currentReasoningEffort(): Promise<string | undefined> {
    return this.stringValue("model_reasoning_effort");
  }

  async currentApprovalPolicy(): Promise<string | undefined> {
    return this.stringValue("approval_policy");
  }

  async currentSandboxMode(): Promise<string | undefined> {
    return this.stringValue("sandbox_mode");
  }

  currentCodexMode(approvalPolicy?: string, sandboxMode?: string): string | undefined {
    if (sandboxMode === "read-only") return "plan";
    // 承認を尋ねない workspace-write が auto、尋ねる（on-request など。未設定も Codex の既定は尋ねる）のが ask（mac と同じ）。
    if (sandboxMode === "workspace-write") return approvalPolicy === "never" ? "auto" : "ask";
    if (sandboxMode === "danger-full-access") return "dangerous";
    return undefined;
  }

  async setModel(model: string): Promise<void> {
    const trimmed = model.trim();
    if (!trimmed) throw new Error("model is required");
    await this.writeTopLevelString("model", trimmed);
  }

  async setReasoningEffort(effort: string): Promise<void> {
    const trimmed = effort.trim();
    if (!["minimal", "low", "medium", "high", "xhigh"].includes(trimmed)) {
      throw new Error(`unsupported reasoning effort: ${trimmed}`);
    }
    await this.writeTopLevelString("model_reasoning_effort", trimmed);
  }

  async setCodexMode(mode: string): Promise<void> {
    const normalized = mode.trim().toLowerCase();
    const values = codexModeValues(normalized);
    if (!values) throw new Error(`unsupported codex mode: ${normalized}`);
    await this.writeTopLevelString("sandbox_mode", values.sandboxMode);
    await this.writeTopLevelString("approval_policy", values.approvalPolicy);
  }

  private async stringValue(key: string): Promise<string | undefined> {
    const raw = await readText(await this.configFile());
    const escaped = escapeRegExp(key);
    const doubleQuoted = new RegExp(`^\\s*${escaped}\\s*=\\s*"((?:\\\\.|[^"\\\\])*)"`, "m").exec(raw);
    if (doubleQuoted) return unescapeTomlBasicString(doubleQuoted[1]);
    const singleQuoted = new RegExp(`^\\s*${escaped}\\s*=\\s*'([^']*)'`, "m").exec(raw);
    return singleQuoted?.[1];
  }

  private async writeTopLevelString(key: string, value: string): Promise<void> {
    const file = await this.configFile();
    await fs.mkdir(path.dirname(file), { recursive: true });
    const raw = await readText(file);
    const escaped = escapeRegExp(key);
    const line = `${key} = "${escapeTomlBasicString(value)}"`;
    const pattern = new RegExp(`^\\s*${escaped}\\s*=\\s*(?:"(?:\\\\.|[^"\\\\])*"|'(?:\\\\.|[^'\\\\])*'|[^\\n#]+)`, "m");
    const next = pattern.test(raw)
      ? raw.replace(pattern, line)
      : raw.length > 0
        ? `${line}\n${raw}`
        : `${line}\n`;
    await fs.writeFile(file, next, "utf8");
  }

  async loadBuddyModelCatalog(): Promise<ProviderCatalog[]> {
    const file = path.join(os.homedir(), ".buddyos", "models.json");
    let parsed: unknown;
    try {
      parsed = JSON.parse(await fs.readFile(file, "utf8")) as unknown;
    } catch {
      return [];
    }
    const codex = asRecord(asRecord(parsed)?.codex);
    const providers = Array.isArray(codex?.providers) ? codex.providers : [];
    return providers
      .map(asRecord)
      .filter((provider): provider is Record<string, unknown> => !!provider)
      .map((provider) => {
        const id = nonEmpty(stringValue(provider.id));
        if (!id) return undefined;
        const modelRows = Array.isArray(provider.models) ? provider.models : [];
        return {
          id,
          label: nonEmpty(stringValue(provider.label)) ?? id,
          models: modelRows
            .map(asRecord)
            .filter((model): model is Record<string, unknown> => !!model)
            .map((model) => {
              const mid = nonEmpty(stringValue(model.id));
              if (!mid) return undefined;
              return {
                id: mid,
                label: nonEmpty(stringValue(model.label)) ?? mid,
                ...(nonEmpty(stringValue(model.subtitle)) ? { subtitle: nonEmpty(stringValue(model.subtitle)) } : {})
              };
            })
            .filter((model): model is { id: string; label: string; subtitle?: string } => !!model)
        };
      })
      .filter((provider): provider is ProviderCatalog => !!provider);
  }

  async defaultModelIds(recent: string[]): Promise<string[]> {
    const result: string[] = [];
    const seen = new Set<string>();
    for (const id of [await this.currentModel(), ...recent, "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark"]) {
      const trimmed = id?.trim();
      if (!trimmed || seen.has(trimmed)) continue;
      seen.add(trimmed);
      result.push(trimmed);
    }
    return result;
  }

  private async configFile(): Promise<string> {
    return path.join(await this.root(), "config.toml");
  }
}

async function readText(file: string): Promise<string> {
  try {
    return await fs.readFile(file, "utf8");
  } catch {
    return "";
  }
}

function fallbackSessionId(file: string): string {
  const name = path.basename(file, ".jsonl");
  return /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/.exec(name)?.[0] ?? name;
}

function normalizePath(value: string | undefined): string | undefined {
  const trimmed = nonEmpty(value);
  if (!trimmed) return undefined;
  return path.normalize(trimmed).replace(/[\\/]+$/, "");
}

async function fileModifiedIso(file: string): Promise<string | undefined> {
  try {
    return (await fs.stat(file)).mtime.toISOString();
  } catch {
    return undefined;
  }
}

function isInternalSessionSource(value: unknown): boolean {
  return asRecord(value)?.subagent !== undefined;
}

/** Codex が user ロールで差し込む、ユーザーが打っていない文脈か（履歴と、app-server のターミナル側の発話の表示から外す）。 */
export function isInjectedUserContext(text: string): boolean {
  const trimmed = text.trimStart();
  // mac の CodexInjectedContext と同じ一覧（shared/fixtures/codex で両方を確かめる）。
  return [
    // Codex のバージョンによって "# AGENTS.md instructions for <dir>" と "# AGENTS.md instructions" の両方がある。
    "# AGENTS.md instructions",
    "<INSTRUCTIONS>",
    "<user_instructions>",
    "<environment_context>",
    "<permissions instructions>",
    "<collaboration_mode>",
    "<personality_spec>",
    "<skills_instructions>",
    "<plugins_instructions>",
    "<skill>",
    // サブエージェントの完了の知らせ。Codex が親の次の要求に差し込み、rollout にも user の発話として残る。
    "<subagent_notification>"
  ].some((prefix) => trimmed.startsWith(prefix));
}

function preview(text: string): string | undefined {
  const compacted = compact(text);
  if (!compacted) return undefined;
  return compacted.length > 80 ? `${compacted.slice(0, 77)}...` : compacted;
}

function compact(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function escapeTomlBasicString(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"");
}

function unescapeTomlBasicString(value: string): string {
  return value.replace(/\\"/g, "\"").replace(/\\\\/g, "\\");
}

export function codexModeValues(mode: string): { sandboxMode: string; approvalPolicy: string } | undefined {
  switch (mode) {
    case "plan":
      return { sandboxMode: "read-only", approvalPolicy: "on-request" };
    case "ask":
      // 毎回尋ねる（mainagent の子の上限が「毎回尋ねる」のときにも使う）。
      return { sandboxMode: "workspace-write", approvalPolicy: "on-request" };
    case "auto":
      return { sandboxMode: "workspace-write", approvalPolicy: "never" };
    case "dangerous":
      return { sandboxMode: "danger-full-access", approvalPolicy: "never" };
    default:
      return undefined;
  }
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function nonEmpty(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function cryptoRandomId(): string {
  return globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2);
}
