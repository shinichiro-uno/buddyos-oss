import type { ChildProcessWithoutNullStreams } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { event, type HistoryMessage, type ProviderCatalog, type SessionEvent, type SessionSummary } from "../protocol.js";
import type { AgentInfo, ModelCatalogItem } from "../protocol.js";
import type { RuntimeCommand } from "../runtime/command.js";
import { decodeConsoleText, killProcessTree, spawnRuntime, toWslPath } from "../runtime/command.js";
import type { JsonSessionStore } from "../sessionStore.js";
import { attachmentTextNotes, BaseAdapter, imageAttachments, imagePlaceholder, metadataText, type AgentSession, type Emit, type SessionOptions, type SessionOverrides } from "./types.js";
import { delegation, SubagentTracker } from "./subagentTracker.js";
import { execRuntime } from "../agentProbe.js";
import { AcpSession, type AcpTuning } from "./acpAdapter.js";
import { agyApprovals, AgyApprovalHook, AgyApprovalPolicy } from "./agyApproval.js";
import { AgyInbox, AntigravityPresence, AntigravityTerminalMirror, AntigravityTranscript, isAgyConversationId, readAgySummaries, type MirrorEvent } from "./antigravityTerminal.js";
import { bridgeGrokSessions, GrokLeader, GrokPresence } from "./grokPresence.js";
import { JsonRpcProcess } from "../runtime/jsonRpcProcess.js";
import { attachmentExportDir, exportImageFile } from "./attachmentStore.js";
import { orchestrator, type McpGrant } from "../mainagent/orchestrator.js";
import { relayCommand } from "../mainagent/stdioRelay.js";
import { ensureAgyMcpConfig, mainAgentPort, PORT_ENV_VAR, TOKEN_ENV_VAR } from "../mainagent/workspace.js";

/**
 * cursor-agent / grok など「1ターン = 1プロセスの headless 実行で、行区切り JSON を
 * ストリームする」CLI を BuddyOS エージェントにするための共有アダプタ。
 * mac の HeadlessCliAdapter.swift と同形。CLI ごとのフラグ体系とストリーム形式の
 * 差分は profile で吸収する。
 */
export interface HeadlessCliProfile {
  /** cursor: Claude Code 互換の stream-json / grok: {type:text|thought|end} の streaming-json /
   *  antigravity: {event:init|step_update|result} の stream-json */
  flavor: "cursor" | "grok" | "antigravity";
  id: string;
  displayName: string;
  provider: string;
  /** 設定が空のときの表示用フォールバックモデル。spawn 時は dotfile があるときだけ --model を渡す。 */
  defaultModel?: string;
  /** 認証前でも出す静的カタログ。認証後は動的取得で置き換える。 */
  staticCatalog: ProviderCatalog[];
  /** grok / antigravity は `--effort` を受ける。 */
  supportsEffort: boolean;
  /** 受け付ける effort（無ければ VALID_EFFORTS）。 */
  supportedEfforts?: string[];
}

export const CURSOR_PROFILE: HeadlessCliProfile = {
  flavor: "cursor",
  id: "cursor",
  displayName: "Cursor CLI",
  provider: "cursor",
  defaultModel: "auto",
  staticCatalog: [
    {
      id: "cursor",
      label: "Cursor",
      models: [{ id: "auto", label: "Auto", subtitle: "Cursor が最適なモデルを自動選択" }]
    }
  ],
  supportsEffort: false
};

export const GROK_PROFILE: HeadlessCliProfile = {
  flavor: "grok",
  id: "grok",
  displayName: "Grok Build",
  provider: "xai",
  defaultModel: "grok-build",
  staticCatalog: [
    {
      id: "xai",
      label: "Grok (xAI)",
      models: [{ id: "grok-build", label: "Grok Build", subtitle: "既定のコーディングモデル" }]
    }
  ],
  supportsEffort: true
};

/** Antigravity CLI（agy。Gemini CLI の後継）。資格情報は Antigravity IDE と共有。 */
export const ANTIGRAVITY_PROFILE: HeadlessCliProfile = {
  flavor: "antigravity",
  id: "antigravity",
  displayName: "Antigravity",
  provider: "google",
  defaultModel: "gemini-4-argon-medium",
  staticCatalog: [
    {
      id: "google",
      label: "Google",
      models: [
        { id: "gemini-4-argon-medium", label: "Gemini 4 Argon (Medium)", subtitle: "既定のコーディングモデル" },
        { id: "gemini-4-argon-high", label: "Gemini 4 Argon (High)", subtitle: "いちばん賢い（使える量の減りが早い）" },
        { id: "gemini-3.8-flash-medium", label: "Gemini 3.8 Flash (Medium)", subtitle: "軽量・高速" }
      ]
    }
  ],
  supportsEffort: true,
  supportedEfforts: ["low", "medium", "high"]
};

const VALID_MODES = ["plan", "edit", "auto", "dangerous"];
const VALID_EFFORTS = ["low", "medium", "high", "xhigh", "max"];

function nonEmpty(value: string | undefined | null): string | undefined {
  if (value == null) return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function dotfilePath(name: string): string {
  return path.join(os.homedir(), ".buddyos", name);
}

function readDotfile(name: string): string | undefined {
  try {
    return nonEmpty(fs.readFileSync(dotfilePath(name), "utf8"));
  } catch {
    return undefined;
  }
}

function writeDotfile(name: string, value: string): void {
  const v = nonEmpty(value);
  if (!v) return;
  const p = dotfilePath(name);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, v, "utf8");
}

export function configuredModel(profile: HeadlessCliProfile): string | undefined {
  const env = nonEmpty(process.env[`BUDDYOS_${profile.id.toUpperCase()}_MODEL`]);
  if (env) return env;
  return readDotfile(`${profile.id}.model`);
}

function readMode(profile: HeadlessCliProfile): string | undefined {
  const v = readDotfile(`${profile.id}.mode`);
  return v && VALID_MODES.includes(v) ? v : undefined;
}

function readEffort(profile: HeadlessCliProfile): string | undefined {
  if (!profile.supportsEffort) return undefined;
  const v = readDotfile(`${profile.id}.effort`);
  return v && (profile.supportedEfforts ?? VALID_EFFORTS).includes(v) ? v : undefined;
}

/* ── Antigravity（agy） ─────────────────────────────────────────────── */

const AGY_AUTH_OK_TTL_MS = 30 * 60_000;
const AGY_AUTH_NG_TTL_MS = 60_000;
const agyAuthCache = new Map<string, { at: number; ok: boolean }>();
const agyModelsCache = new Map<string, { at: number; catalog: ProviderCatalog[] }>();

async function agyModelsOutput(runtime: RuntimeCommand): Promise<string | undefined> {
  const r = await execRuntime(runtime, ["models"], 12_000);
  return r.ok ? r.stdout.trim() : undefined;
}

/** `agy models` に gemini- のモデルが出ればサインイン済み（~/.gemini/antigravity-cli は失敗しても作られるので見ない）。 */
export async function isAntigravityConfigured(runtime: RuntimeCommand): Promise<boolean> {
  const hit = agyAuthCache.get(runtime.label);
  if (hit && Date.now() - hit.at < (hit.ok ? AGY_AUTH_OK_TTL_MS : AGY_AUTH_NG_TTL_MS)) return hit.ok;
  const ok = (await agyModelsOutput(runtime))?.includes("gemini-") ?? false;
  agyAuthCache.set(runtime.label, { at: Date.now(), ok });
  return ok;
}

/** `agy models` の「id<TAB>表示名」を、枠ごとの提供元に分ける。 */
export function parseAgyModels(stdout: string): ProviderCatalog[] {
  const groups: Record<string, ProviderCatalog> = {
    google: { id: "google", label: "Google (Gemini 枠)", models: [] },
    anthropic: { id: "anthropic", label: "Anthropic (Claude/GPT 枠)", models: [] },
    openai: { id: "openai", label: "OpenAI (Claude/GPT 枠)", models: [] }
  };
  for (const line of stdout.split(/\r?\n/)) {
    const [id, label] = line.split("\t").map((s) => s?.trim());
    if (!id || /\s/.test(id)) continue;
    const group = id.startsWith("gemini-") ? groups.google : id.startsWith("claude-") ? groups.anthropic : groups.openai;
    group.models.push({ id, label: label || id });
  }
  return Object.values(groups).filter((g) => g.models.length > 0);
}

async function agyCatalog(runtime: RuntimeCommand): Promise<ProviderCatalog[] | undefined> {
  const hit = agyModelsCache.get(runtime.label);
  if (hit && Date.now() - hit.at < 300_000) return hit.catalog;
  const out = await agyModelsOutput(runtime);
  const catalog = out ? parseAgyModels(out) : [];
  if (catalog.length === 0) return undefined;
  agyModelsCache.set(runtime.label, { at: Date.now(), catalog });
  return catalog;
}

/**
 * Cursor CLI の API キーを解決する（`cursor-agent login` が主経路。env / token
 * ファイルは launchd/サービス起動向けの補助）。
 */
export function resolveCursorKey(): { key: string; envKey: string } | undefined {
  for (const envKey of ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"]) {
    const v = nonEmpty(process.env[envKey]);
    if (v) return { key: v, envKey };
  }
  try {
    const v = nonEmpty(fs.readFileSync(dotfilePath("cursor.token"), "utf8"));
    if (v) return { key: v, envKey: "CURSOR_API_KEY" };
  } catch {
    /* missing file */
  }
  return undefined;
}

/** Grok Build CLI の API キー（XAI_API_KEY / ~/.buddyos/grok.token）。 */
export function resolveGrokKey(): string | undefined {
  const v = nonEmpty(process.env.XAI_API_KEY);
  if (v) return v;
  try {
    return nonEmpty(fs.readFileSync(dotfilePath("grok.token"), "utf8"));
  } catch {
    return undefined;
  }
}

/**
 * grok が認証済みか。未認証の grok は headless で終了せずハングするため、
 * spawn 前ガードと agentProbe の configured 判定の両方でこれを使う。
 */
export function isGrokConfigured(): boolean {
  if (resolveGrokKey()) return true;
  try {
    const obj = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".grok", "auth.json"), "utf8")) as Record<string, unknown>;
    return Object.keys(obj).length > 0;
  } catch {
    return false;
  }
}

/** cursor の API キー/トークンが env・token ファイルで解決できるか（probe 補助）。 */
export function isCursorKeyConfigured(): boolean {
  return resolveCursorKey() !== undefined;
}

/** grok CLI 自身が認証時に書くモデルキャッシュ（~/.grok/models_cache.json）を読む。 */
function grokCatalogFromCache(): ProviderCatalog[] | undefined {
  try {
    const obj = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".grok", "models_cache.json"), "utf8")) as Record<string, unknown>;
    const models = obj.models as Record<string, { info?: { name?: string; description?: string; hidden?: boolean } }> | undefined;
    if (!models) return undefined;
    const items: ModelCatalogItem[] = [];
    for (const [id, value] of Object.entries(models)) {
      const info = value?.info ?? {};
      if (info.hidden === true) continue;
      items.push({ id, label: nonEmpty(info.name) ?? id, subtitle: info.description });
    }
    if (items.length === 0) return undefined;
    items.sort((a, b) => (a.id === "grok-build" ? -1 : b.id === "grok-build" ? 1 : a.id.localeCompare(b.id)));
    return [{ id: "xai", label: "Grok (xAI)", models: items }];
  } catch {
    return undefined;
  }
}

/** ACP で動かすときの起動引数。undefined = headless 実行だけ（agy は ACP を持たない）。mac の acpArgs と同じ。 */
function acpArgs(profile: HeadlessCliProfile): string[] | undefined {
  switch (profile.flavor) {
    case "cursor":
      return ["acp"];
    case "grok":
      return ["agent", "stdio"];
    default:
      return undefined;
  }
}

/** ACP の session/list（ターミナルで始めた会話も入る）。一覧は頻繁に読まれるので少しの間覚えておく。 */
const acpListCache = new Map<string, { at: number; list: SessionSummary[] }>();
const ACP_LIST_TTL_MS = 30_000;

export class HeadlessCliAdapter extends BaseAdapter {
  public readonly displayName: string;
  public readonly runtimeLabel: string;
  /** interrupt() はターンの子プロセスを kill して done で畳む（ACP なら session/cancel）。 */
  public readonly supportsInterrupt = true;

  constructor(
    public readonly id: string,
    private readonly runtime: RuntimeCommand,
    private readonly store: JsonSessionStore,
    private readonly profile: HeadlessCliProfile
  ) {
    super();
    this.displayName = profile.displayName;
    this.runtimeLabel = runtime.label;
  }

  /**
   * ACP で動かすか（承認カード・画像・中断・ターミナルで始めた会話の一覧が付く。mac の usesAcp と同じ）。
   * cursor（`cursor-agent acp`）と grok（`grok agent stdio`）。`BUDDYOS_<ID>_HEADLESS=1` で 1 ターン 1 プロセスの実行に戻せる。
   */
  get usesAcp(): boolean {
    return acpArgs(this.profile) !== undefined && process.env[`BUDDYOS_${this.profile.id.toUpperCase()}_HEADLESS`] !== "1";
  }

  /** setModel が保存し `--effort` に渡す値。cursor は持たない（モデルの変種で決まる）。 */
  get efforts(): readonly string[] {
    // grok の ACP の reasoning_effort は low〜xhigh。
    if (this.profile.flavor === "grok" && this.usesAcp) return ["low", "medium", "high", "xhigh"];
    return this.profile.supportsEffort ? (this.profile.supportedEfforts ?? VALID_EFFORTS) : [];
  }

  /**
   * cursor の headless には edit に当たる指定が無い（plan → --mode plan、dangerous → --force だけ）。
   * ACP なら編集の承認だけを Bridge が自動で許可して edit にする（autoPermissionAnswer）。
   */
  get modes(): readonly string[] {
    return this.profile.flavor === "cursor" && !this.usesAcp ? ["plan", "auto", "dangerous"] : VALID_MODES;
  }

  /**
   * ターミナルの会話を見る・送れるか（capabilities.terminal）。native の CLI だけ。
   * grok は leader（`grok agent --leader`）に対応した版なら、agy はターミナル連携の hook（受け取り箱）を入れてあれば。
   */
  get terminal(): boolean {
    if (this.runtime.kind !== "native") return false;
    if (this.profile.flavor === "grok") return GrokLeader.cached(this.runtime);
    if (this.profile.flavor === "antigravity") return AgyInbox.isInstalled();
    return false;
  }

  /** agy の会話がターミナルで開かれているか（開いた時点から記録を流す）。grok は送ったときだけ leader に乗る。 */
  async terminalSession(sessionId: string): Promise<boolean> {
    if (this.profile.flavor !== "antigravity" || this.runtime.kind !== "native" || !isAgyConversationId(sessionId)) return false;
    return AntigravityPresence.liveConversationIds().has(sessionId);
  }

  async openSession(sessionId: string | undefined, cwd: string | undefined, options?: SessionOptions): Promise<AgentSession> {
    // ターミナルの grok が開いている会話は、共有の leader に乗って送る（別の grok を起こすと会話が二股になる）。
    if (this.profile.flavor === "grok" && sessionId && !options?.permissionMode && this.runtime.kind === "native") {
      const live = GrokPresence.liveSessions().get(sessionId);
      if (live && (await GrokLeader.isSupported(this.runtime))) {
        // grok はパスが一字違うと会話を見つけられないので、ターミナルが記録している作業フォルダで開く。
        return new AcpSession(this.id, sessionId, live.cwd ?? cwd, this.runtime, this.store, ["agent", "--leader", "stdio"], headlessEnv(this.profile), this.acpTuning(options));
      }
    }
    const args = acpArgs(this.profile);
    if (args && this.usesAcp) {
      return new AcpSession(this.id, sessionId, cwd, this.runtime, this.store, args, headlessEnv(this.profile), this.acpTuning(options));
    }
    // Antigravity（agy）: 会話ごとの MCP は、--add-dir で読ませるフォルダの .agents/mcp_config.json（stdio の中継）で渡す。
    // 合鍵は agy の環境変数（中継が引き継ぐ）。Windows の agy（native）だけ（WSL からは Bridge の node を起こせない）。
    let mcp: McpGrant | undefined;
    let mcpDir: string | undefined;
    const relay = this.profile.flavor === "antigravity" && this.runtime.kind === "native" ? relayCommand() : undefined;
    if (relay) {
      const plan = orchestrator.planFor(this.id, sessionId, cwd, options?.unattended);
      mcpDir = plan ? ensureAgyMcpConfig(relay) : undefined;
      if (plan && mcpDir) mcp = { token: orchestrator.issueToken(this.id, sessionId, plan), main: plan.main, depth: plan.depth };
    }
    const session = new HeadlessCliSession(this.id, sessionId, cwd, this.runtime, this.store, this.profile, options?.permissionMode, mcp, mcpDir);
    if (mcp) orchestrator.bind(mcp.token, session);
    return session;
  }

  /** AcpSession に渡す、この CLI ならではの違い（mac の HeadlessCliAdapter.acpTuning と同じ）。 */
  private acpTuning(options?: SessionOptions): AcpTuning {
    const tuning: AcpTuning = {
      approvals: true,
      // 新しいチャットの初期値は、モデル設定で「既定にする」を押したときの値（~/.buddyos/<id>.*）。
      defaults: {
        model: configuredModel(this.profile),
        reasoningEffort: readEffort(this.profile),
        mode: readMode(this.profile)
      },
      unattended: options?.unattended === true,
      permissionMode: options?.permissionMode
    };
    if (this.profile.flavor === "cursor") {
      // cursor の mode 設定は agent / plan / ask。BuddyOS の plan 以外は agent（承認は Bridge が答える）。
      tuning.modeConfigValues = { plan: "plan", "*": "agent" };
    } else {
      // grok の ACP には mode の設定が無い。plan は `/plan` コマンドで入る。画像は image block を受けない。
      tuning.modePromptPrefix = { plan: "/plan " };
      tuning.imagesAsFiles = true;
      // grok は背景の spawn と起こされたターンを `_x.ai/*` で知らせる。状態の無い tool_call_update は子が始まる前にも届く。
      tuning.xaiNotifications = true;
      tuning.statuslessUpdateEndsTool = false;
    }
    return tuning;
  }

  async listSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    const sessions = await this.mergedSessions(limit, cwd);
    if (this.runtime.kind !== "native") return sessions;
    if (this.profile.flavor === "grok") {
      // ターミナルで今開いている会話に印を付ける。BuddyOS の履歴に無い会話（ターミナルで始めたもの）は足す。
      const live = GrokPresence.liveSessions();
      if (live.size === 0) return sessions;
      const out = sessions.map((s) => (live.has(s.sessionId) ? { ...s, terminal: true } : s));
      const known = new Set(out.map((s) => s.sessionId));
      const now = new Date().toISOString();
      for (const [sid, info] of live) {
        if (known.has(sid) || (cwd && info.cwd && !sameDir(info.cwd, cwd))) continue;
        out.unshift({ sessionId: sid, title: "Grok（ターミナル）", lastActive: now, cwd: info.cwd, terminal: true });
      }
      return out;
    }
    if (this.profile.flavor !== "antigravity") return sessions;
    // ターミナルの agy で今開かれている会話に印を付ける。BuddyOS の履歴に無い会話（ターミナルで始めたもの）は
    // 一覧に足す。cwd で絞り込み中は足さない（場所が分からない）。agy が付けた会話名があれば優先する。
    const live = AntigravityPresence.liveConversationIds();
    const summaries = await readAgySummaries();
    const out = sessions.map((s) => {
      const title = summaries.get(s.sessionId)?.title;
      return { ...s, ...(title ? { title } : {}), ...(live.has(s.sessionId) ? { terminal: true } : {}) };
    });
    if (!cwd) {
      const known = new Set(out.map((s) => s.sessionId));
      const now = new Date().toISOString();
      for (const cid of [...live].filter((id) => !known.has(id)).sort()) {
        const info = summaries.get(cid);
        const name = [info?.title, info?.preview].find((v) => v) ?? "Antigravity（ターミナル）";
        out.push({ sessionId: cid, title: name, lastActive: now, cwd: info?.cwd, terminal: true });
      }
    }
    return out;
  }

  /** BuddyOS の履歴（ACP なら CLI の `session/list` と合わせたもの）。 */
  private async mergedSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    const stored = await this.store.list(this.id, this.usesAcp ? 500 : limit, cwd);
    if (!this.usesAcp) return stored;
    // BuddyOS の履歴と CLI の一覧を合わせる。同じ会話は BuddyOS 側の件数・場所を使い、名前は CLI が付けたものを優先する。
    const byId = new Map(stored.map((s) => [s.sessionId, s]));
    for (const s of await this.acpSessions()) {
      if (cwd && s.cwd && !sameDir(s.cwd, cwd)) continue;
      const known = byId.get(s.sessionId);
      byId.set(
        s.sessionId,
        known
          ? { ...known, title: s.title && s.title !== s.sessionId ? s.title : known.title, lastActive: later(known.lastActive, s.lastActive), cwd: known.cwd ?? s.cwd }
          : s
      );
    }
    return [...byId.values()].sort((a, b) => Date.parse(b.lastActive) - Date.parse(a.lastActive)).slice(0, Math.max(1, limit));
  }

  /** CLI の `session/list`。起動できない・答えない CLI では空（BuddyOS の履歴だけを出す）。 */
  private async acpSessions(): Promise<SessionSummary[]> {
    const hit = acpListCache.get(this.id);
    if (hit && Date.now() - hit.at < ACP_LIST_TTL_MS) return hit.list;
    const args = acpArgs(this.profile);
    let list: SessionSummary[] = [];
    if (args) {
      let client: JsonRpcProcess | undefined;
      try {
        client = new JsonRpcProcess(this.runtime, args, undefined, headlessEnv(this.profile));
        client.on("stderr", () => {});
        const init = await client.request(
          "initialize",
          { protocolVersion: 1, clientInfo: { name: "BuddyOS Windows Bridge", version: "0.1.0" }, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } } },
          20_000
        );
        if (!init.error) {
          // session/list は params オブジェクト必須（無いと -32602）。
          const res = await client.request("session/list", {}, 20_000);
          const sessions = asObject(res.result).sessions;
          list = (Array.isArray(sessions) ? sessions : [])
            .map(asObject)
            .filter((s) => asString(s.sessionId))
            .map((s) => {
              const summary: SessionSummary = {
                sessionId: String(s.sessionId),
                title: asString(s.title) ?? String(s.sessionId),
                lastActive: asString(s.updatedAt) ?? new Date(0).toISOString()
              };
              const sessionCwd = asString(s.cwd);
              if (sessionCwd) summary.cwd = sessionCwd;
              return summary;
            });
        }
      } catch {
        list = [];
      } finally {
        client?.close();
      }
    }
    acpListCache.set(this.id, { at: Date.now(), list });
    return list;
  }

  async loadHistory(sessionId: string): Promise<HistoryMessage[]> {
    const stored = this.store.history(this.id, sessionId);
    // ターミナルの agy で始めた・続けた会話は BuddyOS の履歴に無い（足りない）。agy 自身の記録の方が長ければそちらを出す。
    if (this.profile.flavor === "antigravity" && this.runtime.kind === "native") {
      const transcript = AntigravityTranscript.read(sessionId);
      if (transcript.length > stored.length) return transcript;
    }
    return stored;
  }

  async renameSession(sessionId: string, title: string): Promise<boolean> {
    return this.store.rename(this.id, sessionId, title);
  }

  async listCommands() {
    const commands = [
      { id: "plan", kind: "prompt", title: "plan", subtitle: "Plan first, show options, and wait" },
      { id: "options", kind: "prompt", title: "options", subtitle: "Present 2-3 choices with a recommendation" },
      { id: "model", kind: "ui", title: "model", subtitle: "モデル設定を開く" },
      { id: "mode", kind: "ui", title: "mode", subtitle: "権限モード（Plan/Auto/Dangerous）" }
    ];
    if (this.profile.supportsEffort) {
      commands.splice(3, 0, { id: "effort", kind: "ui", title: "effort", subtitle: "推論の強さ" });
    }
    return commands;
  }

  async currentInfo(): Promise<AgentInfo | undefined> {
    return {
      model: configuredModel(this.profile) ?? this.profile.defaultModel,
      provider: this.profile.provider,
      runtime: this.runtimeLabel,
      reasoningEffort: this.profile.supportsEffort ? (readEffort(this.profile) ?? "high") : undefined,
      codexMode: readMode(this.profile) ?? "auto"
    };
  }

  async setModel(model: string, _provider?: string, reasoningEffort?: string, codexMode?: string): Promise<void> {
    if (this.profile.supportsEffort && reasoningEffort && (this.profile.supportedEfforts ?? VALID_EFFORTS).includes(reasoningEffort)) {
      writeDotfile(`${this.profile.id}.effort`, reasoningEffort);
    }
    if (codexMode && VALID_MODES.includes(codexMode.toLowerCase())) {
      writeDotfile(`${this.profile.id}.mode`, codexMode.toLowerCase());
    }
    if (model.trim()) writeDotfile(`${this.profile.id}.model`, model.trim());
  }

  async listAvailableModels(): Promise<ProviderCatalog[]> {
    if (this.profile.flavor === "grok") {
      return grokCatalogFromCache() ?? this.profile.staticCatalog;
    }
    if (this.profile.flavor === "antigravity") {
      return (await agyCatalog(this.runtime)) ?? this.profile.staticCatalog;
    }
    return this.profile.staticCatalog;
  }
}

class HeadlessCliSession implements AgentSession {
  public sessionId: string;
  private didEmitSessionStarted: boolean;
  /** cursor の chatId は CLI 採番。実 ID が届くまでは pending 扱い（--resume しない）。 */
  private resolvedSessionId?: string;
  /** 実行中ターンの子プロセス（interrupt で止める）。 */
  private readonly activeChildren = new Set<ChildProcessWithoutNullStreams>();
  /** interrupt() で止めた子プロセス。その終了はエラーではなく done で畳む。 */
  private readonly interruptedChildren = new WeakSet<ChildProcessWithoutNullStreams>();
  /** このチャットだけのモデル / Effort / モード。ターンごとの起動引数にだけ使う。 */
  private overrides: SessionOverrides = {};
  /**
   * サブエージェントの進行（Cursor の Task・Grok の task）。セッションに 1 つ持つ（ターンごとに作り直すと index が 0 から
   * 振り直しになる）。1 ターン 1 プロセスなので、プロセスが終わったら実行中の行は閉じる。
   */
  private readonly subagents = new SubagentTracker();
  /** 最後に送ったターンの emit（close で実行中の行を閉じる payload を流す）。 */
  private turnEmit?: Emit;
  /** ターミナルの agy の記録を追いかける（開いた時点・受け取り箱で送った時点から）。 */
  private mirror?: AntigravityTerminalMirror;
  private mirrorEmit?: Emit;
  private mirrorTurnActive = false;
  private mirrorTools: Array<{ id: string; name: string }> = [];
  /** 受け取り箱で渡した文（記録に user として戻ってきたら、iPhone には出し直さない）。 */
  private readonly sentToTerminal: string[] = [];
  /** 承認 hook の問い合わせで iPhone の答えを待っているもの（requestId → 許可したか）。 */
  private readonly pendingApprovals = new Map<string, (allow: boolean) => void>();
  /** このターンで読ませるフォルダ（画像の書き出し先）。agy はワークスペースの外を読めないので --add-dir で渡す。 */
  private extraDirs: string[] = [];
  /** このターンで agy に読ませる MCP の設定のフォルダ（ターンごとに中身を確かめ直す。直せなければ渡さない）。 */
  private turnMcpDir?: string;

  constructor(
    private readonly agentId: string,
    initialSessionId: string | undefined,
    private readonly cwd: string | undefined,
    private readonly runtime: RuntimeCommand,
    private readonly store: JsonSessionStore,
    private readonly profile: HeadlessCliProfile,
    /** cron 等が指定した権限モード（plan / edit / auto / dangerous）。全体設定より優先する。 */
    private readonly permissionOverride?: string,
    /** 合鍵（agy だけ）。あれば mcpDir を --add-dir で読ませ、合鍵と番号を環境変数で渡す。閉じたら無効にする。 */
    private readonly mcp?: McpGrant,
    /** agy に読ませる MCP の設定のフォルダ（.agents/mcp_config.json。合鍵は含まない）。 */
    private readonly mcpDir?: string
  ) {
    if (profile.flavor === "grok") {
      // grok は `-s <id>` で「指定 ID のセッションを作成 or 再開」できるため、
      // 新規でもこちらで採番して常に -s を渡す。
      this.resolvedSessionId = initialSessionId ?? crypto.randomUUID();
      this.sessionId = this.resolvedSessionId;
    } else {
      this.resolvedSessionId = initialSessionId;
      this.sessionId = initialSessionId ?? `pending-${crypto.randomUUID().slice(0, 8)}`;
    }
    this.didEmitSessionStarted = Boolean(initialSessionId);
  }

  /** ターミナルの agy で開いている会話なら、iPhone から送る前からターミナルのターンを流す。 */
  async watch(emit: Emit): Promise<void> {
    const sid = this.resolvedSessionId;
    if (this.profile.flavor !== "antigravity" || this.runtime.kind !== "native" || !sid || !isAgyConversationId(sid)) return;
    if (!AntigravityPresence.liveConversationIds().has(sid)) return;
    this.startTerminalMirror(sid, emit);
  }

  async send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    // ターミナルの agy で開いている会話には、別の agy を起動せず受け取り箱で渡す（ターミナル連携の hook が要る）。
    const sid = this.resolvedSessionId;
    if (
      this.profile.flavor === "antigravity" &&
      this.runtime.kind === "native" &&
      sid &&
      isAgyConversationId(sid) &&
      AgyInbox.isInstalled() &&
      AntigravityPresence.liveConversationIds().has(sid)
    ) {
      this.sendToTerminal(sid, text, originalEvent, emit);
      return;
    }
    // 新しいターン。終わった行を忘れる（アプリも送信で終わった行を捨てる）。
    this.subagents.pruneFinished();
    this.turnEmit = emit;

    // 未認証の grok は headless で終了せず無応答のままハングするため、spawn 前に弾く。
    if (this.profile.flavor === "grok" && !isGrokConfigured()) {
      emit(event.error(this.agentId, this.sessionId, "Grok CLI が未認証です。ターミナルで `grok login` を実行するか、~/.buddyos/grok.token に API キーを置いてください。"));
      return;
    }

    // 未サインインの agy も無応答で止まるので、spawn 前に弾く。
    if (this.profile.flavor === "antigravity" && !(await isAntigravityConfigured(this.runtime))) {
      emit(event.error(this.agentId, this.sessionId, "Antigravity CLI が未認証です。ターミナルで `agy` を一度起動して Google アカウントでサインインしてください（Antigravity IDE にサインイン済みなら資格情報が共有されます）。"));
      return;
    }

    const userText = metadataText(originalEvent, text);
    const notes = attachmentTextNotes(originalEvent);
    // 画像はファイルでしか渡せないので、書き出してパスを本文に添える（mac の HeadlessCliSession と同じ書き方。
    // 履歴を開いたときは目印から AttachmentStore の実画像へ戻し、パスの部分も一緒に消える）。
    const images = imageAttachments(originalEvent);
    const imageFiles = images.map((image) => exportImageFile(image));
    images.forEach((image, i) => {
      const file = imageFiles[i];
      const shown = file && this.runtime.kind === "wsl" ? toWslPath(file) : file;
      notes.push(shown ? `${imagePlaceholder(image)} (file: ${shown} — open this file to see the image)` : imagePlaceholder(image));
    });
    this.extraDirs = imageFiles.some(Boolean) ? [attachmentExportDir()] : [];
    const prompt = notes.length > 0 ? `${notes.join("\n\n")}\n\n${userText}` : userText;
    // agy はプロンプトを argv（-p）でしか受けない。Windows のコマンドライン上限を超える長さは送れない。
    if (this.profile.flavor === "antigravity" && !promptFitsArgv(this.runtime, prompt)) {
      emit(event.error(this.agentId, this.sessionId, "Antigravity に送るには長すぎます（Windows のコマンドラインの上限）。添付を減らすか、分けて送ってください。"));
      return;
    }
    this.store.ensureSession(this.agentId, this.sessionId, this.cwd);
    this.store.appendMessage(this.agentId, this.sessionId, "user", prompt, this.cwd, originalEvent.messageId ?? crypto.randomUUID());

    const messageId = crypto.randomUUID();
    let assistant = "";
    let sawTextDelta = false;
    const stderrChunks: Buffer[] = [];
    let sawAnyOutput = false;
    let watchdogTripped = false;

    // grok は headless で stdin を読まない（--prompt-file を使う）。argv に収まらない長さ
    // （Windows のコマンドライン上限）や .cmd 経由で改行が潰れる場合だけ一時ファイルで渡す。
    let promptFile: string | undefined;
    if (this.profile.flavor === "grok" && !promptFitsArgv(this.runtime, prompt)) {
      try {
        promptFile = writePromptFile(prompt);
      } catch (error) {
        emit(event.error(this.agentId, this.sessionId, `${this.profile.displayName} のプロンプトを一時ファイルに書けませんでした: ${error instanceof Error ? error.message : String(error)}`));
        return;
      }
    }
    const removePromptFile = (): void => {
      if (!promptFile) return;
      try {
        fs.unlinkSync(promptFile);
      } catch {
        /* 既に無い */
      }
      promptFile = undefined;
    };

    // Bridge の MCP の設定はターンごとに確かめ直す（書き換えられていたら直す。直せなければこのターンは渡さない。mac と同じ）。
    const relay = this.mcp && this.mcpDir ? relayCommand() : undefined;
    this.turnMcpDir = relay && this.mcpDir ? ensureAgyMcpConfig(relay, this.mcpDir) : undefined;
    // agy の承認を iPhone で受ける（auto / edit のとき）。hook の置き場も作業フォルダに足す。
    const hook = this.beginApprovalHook(emit);
    const endHook = (): void => {
      if (hook) agyApprovals.unregister(hook.token);
      this.resolveAllApprovals(false);
    };
    const grokSid = this.profile.flavor === "grok" ? this.sessionId : undefined;
    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawnRuntime(this.runtime, this.argsForPrompt(prompt, promptFile, Boolean(hook)), {
        cwd: this.cwd,
        env: { ...this.buildEnv(), ...(hook?.env ?? {}) },
        stdio: "pipe"
      });
    } catch (error) {
      // 同期 throw（ENAMETOOLONG / EINVAL 等）は server の汎用 catch に任せず、ここでエラーとして返す。
      removePromptFile();
      endHook();
      emit(event.error(this.agentId, this.sessionId, `${this.profile.displayName} spawn failed: ${error instanceof Error ? error.message : String(error)}`));
      return;
    }
    this.activeChildren.add(child);
    // Bridge が動かしている grok の会話は、ターミナルの印から除く。
    if (grokSid) bridgeGrokSessions.add(grokSid);

    // cursor-agent は -p（--print）で位置引数のプロンプトが無いと stdin を EOF まで読むので、プロンプトは
    // stdin で渡す（添付本文入りの長文が Windows のコマンドライン上限を超えない）。grok は argv / --prompt-file で
    // 渡すので stdin は即 EOF にする（開いたままだと EOF 待ちで watchdog まで止まりうる）。
    // stdin の 'error'（EPIPE / ERR_STREAM_DESTROYED）は子が先に死んだ場合に出るのでログだけにし、
    // 失敗自体は close の exit code 側で error として返す。
    child.stdin.on("error", (error) => {
      process.stderr.write(`[${this.agentId}:${this.runtime.kind}] stdin error: ${String(error)}\n`);
    });
    try {
      if (this.profile.flavor === "cursor") child.stdin.end(prompt);
      else child.stdin.end();
    } catch (error) {
      process.stderr.write(`[${this.agentId}:${this.runtime.kind}] stdin write failed: ${error instanceof Error ? error.message : String(error)}\n`);
    }

    // 認証切れ等で CLI が無出力のままハングするのを検知する watchdog。
    // 90 秒間 stdout / stderr が 1 バイトも出なければ打ち切る。
    const watchdog = setTimeout(() => {
      if (!sawAnyOutput) {
        watchdogTripped = true;
        killProcessTree(child);
      }
    }, 90_000);

    // cmd.exe / wsl.exe のエラーは UTF-8 ではないので、Buffer のまま持って表示するときに読み直す。
    child.stderr.on("data", (chunk: Buffer) => {
      sawAnyOutput = true;
      stderrChunks.push(chunk);
      process.stderr.write(`[${this.agentId}:${this.runtime.kind}] ${decodeConsoleText(chunk)}`);
    });

    child.stdout.setEncoding("utf8");
    let buffer = "";
    // 1 ターン 1 プロセスなので、プロセスが終わった後に行の終わりの知らせは来ない。どの終わり方でも、まだ実行中の行を
    // done / error より先に閉じる（止めた・正常に終わったなら stopped、異常終了なら failed）。
    const abandonSubagents = (state: string): void => {
      const p = this.subagents.abandonRunning({ state });
      if (p) emit(event.workflowProgress(this.agentId, this.sessionId, p));
    };
    child.stdout.on("data", (chunk: string) => {
      sawAnyOutput = true;
      buffer += chunk;
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) break;
        const line = buffer.slice(0, newline).trim();
        buffer = buffer.slice(newline + 1);
        if (!line) continue;
        for (const p of this.subagentPayloads(line, this.subagents)) emit(event.workflowProgress(this.agentId, this.sessionId, p));
        const delta = this.parseLine(line, sawTextDelta);
        if (delta.sessionId && delta.sessionId !== this.sessionId) {
          // sessions.json の保存失敗で chunk の残り行を失わないよう握る（メモリ上は置換済み）。
          try {
            this.store.replaceSessionId(this.agentId, this.sessionId, delta.sessionId, this.cwd);
          } catch (error) {
            process.stderr.write(`[${this.agentId}:${this.runtime.kind}] session store save failed: ${error instanceof Error ? error.message : String(error)}\n`);
          }
          this.sessionId = delta.sessionId;
          this.resolvedSessionId = delta.sessionId;
          if (this.mcp) orchestrator.setParentSessionId(this.mcp.token, delta.sessionId);
        }
        if (delta.sessionId || delta.text) {
          this.emitSessionStartedIfNeeded(emit);
        }
        if (delta.text) {
          sawTextDelta = true;
          assistant += delta.text;
          emit(event.assistantDelta(this.agentId, this.sessionId, messageId, delta.text));
        }
      }
    });

    await new Promise<void>((resolve) => {
      child.on("close", (code) => {
        clearTimeout(watchdog);
        this.activeChildren.delete(child);
        removePromptFile();
        abandonSubagents(!this.interruptedChildren.has(child) && (watchdogTripped || code !== 0) ? "failed" : "stopped");
        if (this.interruptedChildren.has(child)) {
          // ユーザーが停止した。非 0 終了でもエラーにせず、途中までの本文を確定して done で畳む。
          // cursor の新規チャットを init 行（実 chatId）より前に止めたときは session_started を出さない。
          // pending-xxx で出すと iOS がチャットを仮 ID に固定し、次ターンで実 ID に替わっても
          // session_started は二度と出ない（--resume されず文脈・履歴を失う）。done だけ返せば
          // 次の send が同じ session を使い、実 ID の session_started でキーを確定する（grok は常に採番済み）。
          if (this.resolvedSessionId) this.emitSessionStartedIfNeeded(emit);
          this.appendAssistant(assistant, messageId);
          emit(event.done(this.agentId, this.sessionId, messageId));
          resolve();
          return;
        }
        if (watchdogTripped) {
          const hint = this.profile.flavor === "grok"
            ? "Grok CLI が応答しません。認証が切れている可能性があります。ターミナルで `grok login` を実行してください。"
            : this.profile.flavor === "antigravity"
              ? "Antigravity が応答しません。ターミナルで `agy` を一度起動して、サインインと状態を確認してください。"
              : `${this.profile.displayName} が応答しません。ターミナルで CLI を一度起動して状態を確認してください。`;
          emit(event.error(this.agentId, this.sessionId, hint));
          resolve();
          return;
        }
        if (code !== 0) {
          const stderr = decodeConsoleText(Buffer.concat(stderrChunks)).trim();
          emit(event.error(this.agentId, this.sessionId, `${this.profile.displayName} failed: ${stderr || `exit code ${code}`}`));
          resolve();
          return;
        }
        this.emitSessionStartedIfNeeded(emit);
        this.appendAssistant(assistant, messageId);
        emit(event.done(this.agentId, this.sessionId, messageId));
        resolve();
      });
      child.on("error", (error) => {
        clearTimeout(watchdog);
        this.activeChildren.delete(child);
        removePromptFile();
        abandonSubagents("failed");
        emit(event.error(this.agentId, this.sessionId, `${this.profile.displayName} spawn failed: ${error.message}`));
        resolve();
      });
    });
    endHook();
    if (grokSid) bridgeGrokSessions.delete(grokSid);
  }

  /** ターミナルのターンを iPhone 向けのイベントにする。Bridge 自身が agy を動かしている間は、そのターンを send() が流す。 */
  private handleMirror(e: MirrorEvent): void {
    const emit = this.mirrorEmit;
    if (!emit || this.activeChildren.size > 0) return;
    switch (e.kind) {
      case "user": {
        this.mirrorTurnActive = true;
        const i = this.sentToTerminal.findIndex((t) => e.text.includes(t) || t.includes(e.text));
        if (i >= 0) this.sentToTerminal.splice(i, 1);
        else emit({ type: "user_message", agentId: this.agentId, sessionId: this.sessionId, messageId: crypto.randomUUID(), content: e.text });
        return;
      }
      case "assistant": {
        this.mirrorTurnActive = true;
        const mid = crypto.randomUUID();
        emit(event.assistantDelta(this.agentId, this.sessionId, mid, e.text));
        emit(event.assistantTurnEnd(this.agentId, this.sessionId, mid));
        return;
      }
      case "toolStart": {
        const id = crypto.randomUUID();
        this.mirrorTurnActive = true;
        this.mirrorTools.push({ id, name: e.name });
        emit(event.toolStart(this.agentId, this.sessionId, id, e.name, e.name, "other"));
        return;
      }
      case "toolEnd": {
        const tool = this.mirrorTools.shift();
        if (tool) emit(event.toolEnd(this.agentId, this.sessionId, tool.id, tool.name, "completed"));
        return;
      }
      case "turnEnd": {
        const wasActive = this.mirrorTurnActive;
        this.mirrorTurnActive = false;
        this.mirrorTools = [];
        if (wasActive) emit(event.done(this.agentId, this.sessionId, crypto.randomUUID()));
        return;
      }
    }
  }

  private startTerminalMirror(conversationId: string, emit: Emit): void {
    this.mirrorEmit = emit;
    if (this.mirror) return;
    this.mirror = new AntigravityTerminalMirror(conversationId, (e) => this.handleMirror(e));
    this.mirror.start();
  }

  /** 受け取り箱へ置く。agy が次にモデルを呼ぶときに hook が会話へ入れ、その後の返事は記録から流れる。 */
  private sendToTerminal(conversationId: string, text: string, originalEvent: SessionEvent, emit: Emit): void {
    const messageId = crypto.randomUUID();
    const notes = attachmentTextNotes(originalEvent);
    const userText = metadataText(originalEvent, text);
    const prompt = notes.length > 0 ? `${notes.join("\n\n")}\n\n${userText}` : userText;
    try {
      AgyInbox.enqueue(conversationId, prompt);
    } catch (error) {
      emit(event.error(this.agentId, this.sessionId, `ターミナルの Antigravity に渡せませんでした: ${error instanceof Error ? error.message : String(error)}`));
      return;
    }
    this.sentToTerminal.push(prompt);
    this.startTerminalMirror(conversationId, emit);
    this.store.ensureSession(this.agentId, this.sessionId, this.cwd);
    this.store.appendMessage(this.agentId, this.sessionId, "user", prompt, this.cwd, originalEvent.messageId ?? crypto.randomUUID());
    emit({
      type: "proactive",
      agentId: this.agentId,
      sessionId: this.sessionId,
      messageId: crypto.randomUUID(),
      content: "ターミナルの Antigravity に渡しました。agy が次に考え始めるときに入ります（入力待ちで止まっているときは、ターミナルで何か送るまで届きません）。"
    });
    emit(event.done(this.agentId, this.sessionId, messageId));
  }

  /** auto / edit のターンだけ承認 hook を有効にし、agy に渡す環境変数を返す（使わないときは undefined）。 */
  private beginApprovalHook(emit: Emit): { token: string; env: Record<string, string> } | undefined {
    if (this.profile.flavor !== "antigravity" || this.runtime.kind !== "native" || this.permissionOverride) return undefined;
    const mode = readMode(this.profile) ?? "auto";
    const port = agyApprovals.port;
    if ((mode !== "auto" && mode !== "edit") || !port || !AgyApprovalHook.ensureInstalled()) return undefined;
    const token = agyApprovals.register((body) => this.handleApprovalHook(body, emit));
    return { token, env: AgyApprovalHook.env(port, token) };
  }

  /** hook の問い合わせ 1 件。コマンド実行は許可リストに無ければ iPhone に聞く。 */
  private async handleApprovalHook(body: string, emit: Emit): Promise<Record<string, unknown>> {
    let obj: Record<string, unknown>;
    try {
      obj = asObject(JSON.parse(body));
    } catch {
      return { decision: "deny", reason: "承認の問い合わせを読めませんでした。" };
    }
    const call = asObject(obj.toolCall);
    const args = asObject(call.args);
    const rules = AgyApprovalPolicy.loadRules();
    // Bridge の MCP を渡しているターンなら、buddyos の道具の呼び出しとその説明を読むことは通す（承認は Bridge が呼んだ側のチャットに出す）。
    const verdict = AgyApprovalPolicy.verdict(asString(call.name) ?? "", args, rules.allow, rules.deny, {
      bridgeMcp: Boolean(this.mcp && this.turnMcpDir),
      cwd: this.cwd
    });
    let out: Record<string, unknown>;
    if (verdict.kind === "allow") out = { decision: "allow" };
    else if (verdict.kind === "deny") out = { decision: "deny", reason: verdict.reason };
    else {
      const ok = await this.askOnPhone(verdict.title, verdict.detail, emit);
      out = ok ? { decision: "allow" } : { decision: "deny", reason: "ユーザーが iPhone で拒否しました。" };
    }
    // agy が hook の置き場を作業フォルダと取り違えたら、本来の作業フォルダで実行させる。
    const runIn = asString(args.Cwd);
    if (out.decision === "allow" && this.cwd && runIn && sameDir(runIn, AgyApprovalHook.directory(), true)) {
      out.overwrite = { Cwd: this.cwd };
    }
    return out;
  }

  private askOnPhone(title: string, detail: string | undefined, emit: Emit): Promise<boolean> {
    const requestId = crypto.randomUUID();
    const metadata: Record<string, string> = {
      requestId,
      kind: "approval",
      title,
      option_count: "2",
      option_0_title: "許可",
      option_0_value: "allow",
      option_1_title: "拒否",
      option_1_value: "deny",
      allowsOther: "0"
    };
    if (detail) metadata.subtitle = detail;
    return new Promise((resolve) => {
      // 答えが来なければ、hook が打ち切られる前に拒否で返す。
      const timer = setTimeout(() => this.resolveApproval(requestId, false), (AgyApprovalHook.timeoutSeconds - 30) * 1000);
      timer.unref();
      this.pendingApprovals.set(requestId, (allow) => {
        clearTimeout(timer);
        emit({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId });
        resolve(allow);
      });
      emit({ type: "action_request", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId, content: title, metadata });
    });
  }

  async respondToAction(requestId: string, decision: string): Promise<void> {
    this.resolveApproval(requestId, decision === "allow");
  }

  private resolveApproval(requestId: string, allow: boolean): void {
    const done = this.pendingApprovals.get(requestId);
    if (!done) return;
    this.pendingApprovals.delete(requestId);
    done(allow);
  }

  private resolveAllApprovals(allow: boolean): void {
    for (const id of [...this.pendingApprovals.keys()]) this.resolveApproval(id, allow);
  }

  /// 実行中ターンを止める。CLI にはターンだけ止める手段が無いので子プロセスツリーごと kill し
  /// （cmd シム / wsl.exe 経由だと child.kill では子孫が残る）、close で done として畳む。
  /// 次の send は --resume / -s で同じ会話を続ける。
  async interrupt(): Promise<void> {
    this.resolveAllApprovals(false);
    for (const child of this.activeChildren) {
      this.interruptedChildren.add(child);
      killProcessTree(child);
    }
  }

  async close(): Promise<void> {
    this.mirror?.stop();
    this.mirror = undefined;
    this.resolveAllApprovals(false);
    // 閉じた後は行の終わりの知らせを受けない。実行中の行は stopped で閉じる。
    const p = this.subagents.abandonRunning({ state: "stopped" });
    if (p) this.turnEmit?.(event.workflowProgress(this.agentId, this.sessionId, p));
    if (this.mcp) orchestrator.revoke(this.mcp.token);
  }

  /** サブエージェントのカードの全行（workflow_snapshot。行が無くても agents: []）。agy は行を作らないので undefined。 */
  subagentSnapshot(): string | undefined {
    if (this.profile.flavor === "antigravity") return undefined;
    return this.subagents.snapshot({ includeEmpty: true });
  }

  /** 合鍵（テスト用）。 */
  get mainToken(): string | undefined {
    return this.mcp?.token;
  }

  /// ターンの本文を履歴に保存する。保存失敗（Windows の rename EPERM/EBUSY 等）で done / resolve が
  /// 飛ばされないよう握る（メモリ上は追記済みなので次の save で永続化される）。
  private appendAssistant(assistant: string, messageId: string): void {
    if (!assistant.trim()) return;
    try {
      this.store.appendMessage(this.agentId, this.sessionId, "assistant", assistant, this.cwd, messageId);
    } catch (error) {
      process.stderr.write(`[${this.agentId}:${this.runtime.kind}] session store save failed: ${error instanceof Error ? error.message : String(error)}\n`);
    }
  }

  applyOverrides(overrides: SessionOverrides): void {
    this.overrides = { ...overrides };
  }

  /** `--model` に渡すモデル。チャットの上書き > 既定。 */
  private effectiveModel(): string | undefined {
    return this.overrides.model ?? configuredModel(this.profile);
  }

  private effectiveEffort(): string | undefined {
    if (!this.profile.supportsEffort) return undefined;
    const e = this.overrides.reasoningEffort;
    if (e && (this.profile.supportedEfforts ?? VALID_EFFORTS).includes(e)) return e;
    return readEffort(this.profile);
  }

  /** cron 等の指定 > チャットの上書き > 全体設定。 */
  private effectiveMode(): string | undefined {
    if (this.permissionOverride) return this.permissionOverride;
    const m = this.overrides.mode;
    if (m && VALID_MODES.includes(m)) return m;
    return readMode(this.profile);
  }

  argsForPrompt(prompt: string, promptFile?: string, approvalHook = false): string[] {
    const mode = this.effectiveMode();
    if (this.profile.flavor === "cursor") {
      // ワークスペース信頼のプロンプトで headless がブロックされるのを防ぐため --trust。
      // プロンプト本文は stdin で渡すので argv には含めない（-p は --print のフラグ。send() 参照）。
      const args = ["-p", "--output-format", "stream-json", "--trust"];
      if (this.resolvedSessionId && isUuid(this.resolvedSessionId)) {
        args.push("--resume", this.resolvedSessionId);
      }
      const model = this.effectiveModel();
      if (model) args.push("--model", model);
      if (mode === "plan") args.push("--mode", "plan");
      else if (mode === "dangerous") args.push("--force");
      return args;
    }
    if (this.profile.flavor === "antigravity") {
      const args = ["-p", prompt, "--output-format", "stream-json"];
      // agy は headless だとシェルの cwd を見ないので、作業フォルダは --add-dir で渡す（無いとファイル操作できない）。
      if (this.cwd) args.push("--add-dir", this.runtime.kind === "wsl" ? toWslPath(this.cwd) : this.cwd);
      for (const dir of this.extraDirs) args.push("--add-dir", this.runtime.kind === "wsl" ? toWslPath(dir) : dir);
      // Bridge の MCP（stdio の中継）の設定を置いたフォルダ。合鍵は環境変数（buildEnv）で渡す。
      if (this.mcp && this.turnMcpDir) args.push("--add-dir", this.turnMcpDir);
      if (this.resolvedSessionId && isUuid(this.resolvedSessionId)) args.push("--conversation", this.resolvedSessionId);
      const model = this.effectiveModel();
      if (model) args.push("--model", model);
      const effort = this.effectiveEffort();
      if (effort) args.push("--effort", effort);
      if (mode === "plan") args.push("--mode", "plan");
      else if (mode === "edit") args.push("--mode", "accept-edits");
      else if (mode === "dangerous") args.push("--dangerously-skip-permissions");
      // 承認 hook を使うターンは、組み込みの確認（headless では聞けずに自動で拒否される）を外し、
      // コマンド実行の可否は hook（iPhone）が決める。hook の置き場も読ませる。
      if (approvalHook && mode !== "dangerous" && mode !== "plan") {
        args.push("--add-dir", AgyApprovalHook.directory(), "--dangerously-skip-permissions");
      }
      return args;
    }
    const promptArgs = promptFile
      ? ["--prompt-file", this.runtime.kind === "wsl" ? toWslPath(promptFile) : promptFile]
      : ["-p", prompt];
    const args = [...promptArgs, "--output-format", "streaming-json", "--no-auto-update"];
    if (this.resolvedSessionId) args.push("-s", this.resolvedSessionId);
    const model = this.effectiveModel();
    if (model) args.push("-m", model);
    const effort = this.effectiveEffort();
    if (effort) args.push("--effort", effort);
    // BuddyOS モード → grok --permission-mode（claude と同じ語彙）。
    const permission = mode === "plan" ? "plan"
      : mode === "edit" ? "acceptEdits"
      : mode === "auto" ? "default"
      : mode === "dangerous" ? "bypassPermissions"
      : undefined;
    if (permission) args.push("--permission-mode", permission);
    return args;
  }

  private buildEnv(): NodeJS.ProcessEnv {
    const env: NodeJS.ProcessEnv = { ...process.env, ...headlessEnv(this.profile) };
    // agy の stdio の MCP サーバ（中継）は agy の環境変数を引き継ぐので、合鍵と番号はここで渡す（引数・ファイルに載せない）。
    if (this.mcp && this.turnMcpDir) {
      env[TOKEN_ENV_VAR] = this.mcp.token;
      env[PORT_ENV_VAR] = String(mainAgentPort());
    }
    return env;
  }

  /** CLI ごとのストリーム 1 行を {text, sessionId} に正規化する。 */
  /// CLI ごとのストリーム 1 行から、サブエージェントの進行を取り出す（mac HeadlessCliAdapter と同じ）。
  private subagentPayloads(line: string, tracker: SubagentTracker): string[] {
    let object: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(line);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return [];
      object = parsed as Record<string, unknown>;
    } catch {
      return [];
    }
    const rec = (v: unknown): Record<string, unknown> | undefined =>
      v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
    if (this.profile.flavor === "grok") {
      // ACP の session/update（NDJSON 単体と JSON-RPC の封筒の両方）。
      const params = rec(object.params) ?? object;
      const p = tracker.ingestAcpUpdate(rec(params.update) ?? params);
      return p ? [p] : [];
    }
    // Cursor: Claude 互換の Task / Agent ツールと、独自の tool_call 行
    // （{"type":"tool_call","subtype":"started|completed","call_id","tool_call":{"<name>ToolCall":{args,result}}}）。
    const out = tracker.ingestToolUseLine(object);
    const streamed = tracker.ingestStreamLine(object);
    if (streamed) out.push(streamed);
    const call = rec(object.tool_call);
    const id = typeof object.call_id === "string" ? object.call_id : undefined;
    if (object.type === "tool_call" && call && id) {
      const [key, raw] = Object.entries(call)[0] ?? [];
      const inner = rec(raw);
      const name = key?.endsWith("ToolCall") ? key.slice(0, -"ToolCall".length) : (key ?? "");
      if (object.subtype === "started") {
        const d = delegation(name, undefined, inner?.args);
        const p = d ? tracker.begin(id, d.label, d.agentType) : undefined;
        if (p) out.push(p);
      } else if (object.subtype === "completed" && tracker.has(id)) {
        const result = rec(inner?.result);
        const success = rec(result?.success);
        const text = [success?.content, success?.output, success?.summary].find((v): v is string => typeof v === "string");
        const p = tracker.finish(id, result?.error !== undefined || result?.failure !== undefined, text);
        if (p) out.push(p);
      }
    }
    return out;
  }

  private parseLine(line: string, sawTextDelta: boolean): { text?: string; sessionId?: string } {
    let object: Record<string, unknown>;
    try {
      object = JSON.parse(line) as Record<string, unknown>;
    } catch {
      // JSON でない行（生エラー等）は、まだ本文が無ければそのまま見せる。
      return sawTextDelta ? {} : { text: `${line}\n` };
    }

    if (this.profile.flavor === "antigravity") {
      // {"event":"init"|"step_update"|"result", "conversation_id":..., "<event>":{...}}
      const sid = asString(object.conversation_id);
      if (object.event === "step_update") {
        const step = asObject(object.step_update);
        const stepSid = sid ?? asString(step.conversation_id);
        if (step.step_type === "agent_response" && typeof step.text_delta === "string" && step.text_delta) {
          return { text: step.text_delta, sessionId: stepSid };
        }
        return { sessionId: stepSid };
      }
      if (object.event === "result") {
        const result = asObject(object.result);
        const resultSid = sid ?? asString(result.conversation_id);
        if (!sawTextDelta && typeof result.response === "string") return { text: result.response, sessionId: resultSid };
        return { sessionId: resultSid };
      }
      return { sessionId: sid };
    }
    if (this.profile.flavor === "grok") {
      // {"type":"text","data":"..."} / {"type":"thought",...} / {"type":"end","sessionId":...}
      if (object.type === "text" && typeof object.data === "string") return { text: object.data };
      if (object.type === "end") return { sessionId: asString(object.sessionId) };
      return {};
    }

    // cursor: Claude Code 互換形（type = system(init) / user / assistant / result）。
    const sessionId = asString(object.session_id) ?? asString(object.sessionId) ?? asString(object.chatId) ?? asString(object.chat_id);
    if (object.type === "assistant") {
      const message = asObject(object.message);
      const content = Array.isArray(message.content) ? message.content : [];
      const text = content
        .map((block) => {
          const b = asObject(block);
          return b.type === "text" && typeof b.text === "string" ? b.text : "";
        })
        .join("");
      if (text) return { text, sessionId };
      return { sessionId };
    }
    if (object.type === "result") {
      // assistant 行を一度も見ていないときだけ最終テキストを採用（二重出力防止）。
      if (!sawTextDelta && typeof object.result === "string") return { text: object.result, sessionId };
      return { sessionId };
    }
    return { sessionId };
  }

  private emitSessionStartedIfNeeded(emit: Emit): void {
    if (this.didEmitSessionStarted) return;
    this.didEmitSessionStarted = true;
    emit(event.sessionStarted(this.agentId, this.sessionId));
  }
}

/** CLI に足す環境変数（API キーと grok の更新チェック止め。従来の buildEnv と同じ）。ACP の起動にも使う。 */
export function headlessEnv(profile: HeadlessCliProfile): Record<string, string> {
  const env: Record<string, string> = {};
  if (profile.flavor === "cursor") {
    const resolved = resolveCursorKey();
    if (resolved && !process.env[resolved.envKey]) env[resolved.envKey] = resolved.key;
  } else {
    const key = resolveGrokKey();
    if (key && !process.env.XAI_API_KEY) env.XAI_API_KEY = key;
    // update チェックのノイズを止める（stdout は streaming-json / JSON-RPC 専用に保つ）。
    env.GROK_DISABLE_UPDATE_CHECK = "1";
  }
  return env;
}

function later(a: string, b: string): string {
  return (Date.parse(a) || 0) >= (Date.parse(b) || 0) ? a : b;
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

// cmd.exe のメタ文字（runtime/command.ts の quoteCmdArg の ^ エスケープ等で 1 文字が最大 5 文字に膨らむ）。
const CMD_META_CHARS = /[()\][%!^"`<>&|;, *?]/g;
// プロンプト以外の引数（フラグ・セッション ID・モデル名・実行ファイルパス）の分の余裕。
const ARGV_RESERVED = 2048;

/// プロンプトを argv 1 要素でそのまま渡せるか。Windows のコマンドライン上限（CreateProcess 32767 /
/// cmd.exe 8191 文字）から他の引数の分を引いた長さを目安にする。.cmd/.bat（cmd.exe 経由）は
/// エスケープで膨らむ分も見積もり、改行は空白に潰れるので改行を含むときも不可とする。
/// どちらの経路も CommandLineToArgvW 向けのクオート（libuv / quoteCmdArg）で、外側の "..."、" 前の \、
/// " や末尾の直前の \ の倍化の分だけ膨らむ（\ は全部倍になる前提で上限を見積もる）。
function promptFitsArgv(runtime: RuntimeCommand, prompt: string): boolean {
  if (process.platform !== "win32") return true;
  const viaCmd = runtime.kind === "native" && /\.(cmd|bat)$/i.test(runtime.executable);
  if (viaCmd && /[\r\n]/.test(prompt)) return false;
  const backslashes = prompt.match(/\\/g)?.length ?? 0;
  // cmd 経由は外側の " 2 個も ^^^" に膨らむ（8 文字）。" の \ は CMD_META_CHARS の 4 倍に含む。
  const length = viaCmd
    ? prompt.length + 8 + backslashes + 4 * (prompt.match(CMD_META_CHARS)?.length ?? 0)
    : prompt.length + 2 + backslashes + (prompt.match(/"/g)?.length ?? 0);
  return length <= (viaCmd ? 8191 : 32767) - ARGV_RESERVED;
}

/// grok の --prompt-file 用に、本人のみ読める一時ファイルへプロンプトを書く（ターン終了で消す）。
function writePromptFile(prompt: string): string {
  const file = path.join(os.tmpdir(), `buddyos-grok-prompt-${crypto.randomUUID()}.txt`);
  fs.writeFileSync(file, prompt, { encoding: "utf8", mode: 0o600 });
  return file;
}

/**
 * 作業フォルダの比較（大文字小文字・区切り・末尾の区切りを揃える）。prefix なら b の中にあるか。
 * WSL で動く CLI は /mnt/c/... で返すので、Windows のパスに揃えて比べる。
 */
function sameDir(a: string, b: string, prefix = false): boolean {
  const norm = (p: string): string =>
    p.replace(/\\/g, "/").replace(/^\/mnt\/([a-z])(?=\/|$)/i, "$1:").replace(/\/+$/, "").toLowerCase();
  return prefix ? norm(a).startsWith(norm(b)) : norm(a) === norm(b);
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}
