import type { ChildProcessWithoutNullStreams } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { event, type HistoryMessage, type SessionEvent, type SessionSummary } from "../protocol.js";
import type { AgentInfo } from "../protocol.js";
import type { RuntimeCommand } from "../runtime/command.js";
import { decodeConsoleText, killProcessTree, spawnRuntime, toWslPath } from "../runtime/command.js";
import { orchestrator, type McpGrant } from "../mainagent/orchestrator.js";
import { claudeMcpArgs, mainAgentPort, TOKEN_ENV_VAR, writeClaudeMcpConfigFile } from "../mainagent/workspace.js";
import type { JsonSessionStore } from "../sessionStore.js";
import {
  attachmentTextNotes,
  BaseAdapter,
  imageAttachments,
  imagePlaceholder,
  metadataText,
  type AgentSession,
  type Emit,
  type ImageAttachment,
  type SessionOptions,
  type SessionOverrides,
  type StopTaskOutcome,
  type StopTaskRequest
} from "./types.js";
import { voiceTurnFrom, withVoiceContext, type VoiceTurn } from "./voiceTurn.js";
import { finalState, SubagentTracker } from "./subagentTracker.js";
import { ClaudeProjectsScanner } from "./claudeProjectsScanner.js";
import { cardFor, errorResponse, initializeRequest, parseControlLine, permissionResult, stopTaskRequest, successResponse, type ControlLine, type ToolRequest } from "./claudeControl.js";
import { agentHome } from "../mcpService.js";
import { buildClaudeEnv, configuredModel, resolveClaudeSessionCwd } from "./claudeProfile.js";

// Claude Code の権限モード（Plan/Edit/Auto/Dangerous）。
// BuddyOS の UI ラベルを ~/.buddyos/claude.mode に永続化し、
// 起動時に `claude --permission-mode <value>` へマッピングする。
const CLAUDE_MODES = ["plan", "edit", "auto", "dangerous"];

// Effort（mac と同じ語彙）。ultracode は CLI に無い BuddyOS の tier で、xhigh と Workflow の指示に展開する。
// 既定は ~/.buddyos/claude.effort に保存し、起動時に `--effort` で渡す（無ければ CLI が settings.json を読む）。
const CLAUDE_EFFORTS = ["low", "medium", "high", "xhigh", "max", "ultracode"];

/** 対話モードの `/effort ultracode` が入れる「常時 Workflow 活用」の姿勢を、`-p` でも再現する追記（mac と同じ文）。 */
const ULTRACODE_DIRECTIVE =
  "Ultracode mode is on. Optimize for the most exhaustive, correct result over speed or cost. For every substantive task, use the Workflow tool to orchestrate multiple subagents — decompose and fan out in parallel, verify findings adversarially, then synthesize. Work solo only on trivial or purely conversational turns.";

/** warm() で起こしたまま送られなければ、この時間で畳む（次の send がまた起こす）。 */
const WARM_IDLE_MS = 5 * 60_000;
/** 常駐プロセスの stderr は末尾だけ持つ（終了時のエラー表示用）。 */
const STDERR_TAIL_BYTES = 64 * 1024;
/** interrupt 等で止めたプロセスの終了を待つ上限。過ぎたら強制終了して次を起こす。 */
const DYING_WAIT_MS = 3000;

function buddyosFile(name: string): string {
  return path.join(os.homedir(), ".buddyos", name);
}

function readChoice(name: string, valid: string[]): string | undefined {
  try {
    const v = fs.readFileSync(buddyosFile(name), "utf8").trim();
    return valid.includes(v) ? v : undefined;
  } catch {
    return undefined;
  }
}

function writeChoice(name: string, value: string, valid: string[]): void {
  const v = value.trim().toLowerCase();
  if (!valid.includes(v)) return;
  const p = buddyosFile(name);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, v, "utf8");
}

export function readClaudeMode(): string | undefined {
  return readChoice("claude.mode", CLAUDE_MODES);
}

/**
 * claude の既定の権限モード（BuddyOS のラベル）。claude.mode（setModel で保存したもの）、無ければ ~/.claude/settings.json の
 * permissions.defaultMode（CLI が使う既定）。どちらも無ければ undefined（mainagent は「モード: 不明」として扱う。mac と同じ）。
 */
export function claudeDefaultMode(): string | undefined {
  const saved = readClaudeMode();
  if (saved) return saved;
  try {
    const settings = JSON.parse(fs.readFileSync(path.join(os.homedir(), ".claude", "settings.json"), "utf8")) as { permissions?: { defaultMode?: unknown } };
    switch (settings.permissions?.defaultMode) {
      case "plan":
        return "plan";
      case "acceptEdits":
        return "edit";
      case "default":
        return "auto";
      case "bypassPermissions":
        return "dangerous";
      default:
        return undefined;
    }
  } catch {
    return undefined;
  }
}

function readClaudeEffort(): string | undefined {
  return readChoice("claude.effort", CLAUDE_EFFORTS);
}

function claudePermissionFlag(mode: string | undefined): string | undefined {
  switch (mode) {
    case "plan":
      return "plan";
    case "edit":
      return "acceptEdits";
    case "auto":
      return "default";
    case "dangerous":
      return "bypassPermissions";
    default:
      return undefined;
  }
}

/** BuddyOS の effort tier → `claude --effort` の値（ultracode は CLI に無いので xhigh）。 */
function cliEffort(tier: string): string {
  return tier === "ultracode" ? "xhigh" : tier;
}

/** claude --bg のジョブを知る口（server が ClaudeBackgroundJobs につなぐ）。 */
export interface BackgroundJobHost {
  isJob(sessionId: string): boolean;
  refresh(): void;
  /** 最初の一覧の読み取りが終わるまで待つ（Bridge を起動した直後に、生きたワーカーを -p で開かないため）。 */
  ready?(): Promise<void>;
}

/** 履歴を読み終えた位置（claude --bg の transcript の追いかけが、同じ行を履歴と live の両方に出さないために使う）。 */
export interface HistoryReadFeed {
  lastRead(sessionId: string): { file?: string; end: number } | undefined;
  onRead(sessionId: string, listener: (read: { file?: string; end: number }) => void): () => void;
}

const BG_RUNNING = /running in the background \(([0-9a-f]{8})\)/;

export class ClaudeCodeAdapter extends BaseAdapter implements HistoryReadFeed {
  public readonly displayName: string;
  public readonly runtimeLabel: string;
  /** interrupt() は制御要求でターンだけを止める（返事が無く背景の作業も無ければ常駐プロセスを止め、次の send が --resume で起こし直す）。 */
  public readonly supportsInterrupt = true;
  /** 常駐プロセスなので、生成中の送信は予約に回さず stdin へそのまま流せる（mac と同じ）。 */
  public readonly supportsMidTurnInjection = true;
  /** チャットを開いた時点で claude を起こしておける（session_warm）。 */
  public readonly supportsWarm = true;
  public readonly efforts = CLAUDE_EFFORTS;
  public readonly modes = CLAUDE_MODES;

  private readonly scanner: ClaudeProjectsScanner;
  private background?: BackgroundJobHost;
  private readonly historyReads = new Map<string, { file?: string; end: number }>();
  private readonly historyListeners = new Map<string, Set<(read: { file?: string; end: number }) => void>>();

  /** claude --bg のジョブを知る口をつなぐ。bg のジョブの会話は warm しない。 */
  attachBackground(host: BackgroundJobHost): void {
    this.background = host;
  }

  lastRead(sessionId: string): { file?: string; end: number } | undefined {
    return this.historyReads.get(sessionId);
  }

  onRead(sessionId: string, listener: (read: { file?: string; end: number }) => void): () => void {
    let set = this.historyListeners.get(sessionId);
    if (!set) this.historyListeners.set(sessionId, (set = new Set()));
    set.add(listener);
    return () => {
      set.delete(listener);
      if (set.size === 0 && this.historyListeners.get(sessionId) === set) this.historyListeners.delete(sessionId);
    };
  }

  /** claude を動かす runtime（claude --bg の一覧・操作が同じ実行ファイルを使う）。 */
  get runtimeCommand(): RuntimeCommand {
    return this.runtime;
  }

  constructor(
    public readonly id: string,
    private readonly runtime: RuntimeCommand,
    private readonly store: JsonSessionStore
  ) {
    super();
    this.displayName = id === "claude" ? "Claude Code" : `Claude Code (${runtime.kind})`;
    this.runtimeLabel = runtime.label;
    // WSL で動くなら WSL 側の ~/.claude/projects を読む。
    this.scanner = new ClaudeProjectsScanner(async () => {
      const home = await agentHome("claude", runtime.label);
      return home ? path.join(home, ".claude", "projects") : undefined;
    });
  }

  async openSession(sessionId: string | undefined, cwd: string | undefined, options?: SessionOptions): Promise<AgentSession> {
    const resolvedCwd = resolveClaudeSessionCwd(cwd, sessionId);
    // ほかのセッションを操作する MCP の合鍵を渡す（mainagent のフォルダ・設定 allSessions のときのふつうのセッション。
    // 無人実行には渡さない）。
    const mcp = orchestrator.grantFor(this.id, sessionId, resolvedCwd, options?.unattended, options?.heartbeat);
    const session = new ClaudeCodeSession(
      this.id,
      sessionId,
      resolvedCwd,
      this.runtime,
      this.store,
      options?.permissionMode,
      // 承認を iPhone に尋ねる。無人実行（cron）は答える人が居ないので付けない（mac と同じ）。
      !options?.unattended && !options?.permissionMode,
      mcp,
      this.background
    );
    if (mcp) orchestrator.bind(mcp.token, session);
    return session;
  }

  async listSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    const stored = await this.store.list(this.id, limit, cwd);
    // 会話記録（ターミナルで始めた会話も含む）を先に、BuddyOS の記録で補う。同じ id は記録側を採る。
    const scanned = await this.scanner.listSessions(limit, cwd).catch(() => []);
    const seen = new Set<string>();
    const merged: SessionSummary[] = [];
    for (const s of [...scanned, ...stored]) {
      if (seen.has(s.sessionId)) continue;
      seen.add(s.sessionId);
      merged.push(s);
    }
    merged.sort((a, b) => Date.parse(b.lastActive) - Date.parse(a.lastActive));
    return merged.slice(0, Math.max(1, limit));
  }

  async loadHistory(sessionId: string): Promise<HistoryMessage[]> {
    const read = await this.scanner.loadHistoryRead(sessionId).catch(() => undefined);
    if (read?.end !== undefined) {
      const entry = { file: read.file, end: read.end };
      this.historyReads.set(sessionId, entry);
      if (this.historyReads.size > 50) this.historyReads.delete(this.historyReads.keys().next().value!);
      for (const listener of [...(this.historyListeners.get(sessionId) ?? [])]) listener(entry);
    }
    const scanned = read?.messages ?? [];
    return scanned.length > 0 ? scanned : this.store.history(this.id, sessionId);
  }

  async renameSession(sessionId: string, title: string): Promise<boolean> {
    return this.store.rename(this.id, sessionId, title);
  }

  async listCommands() {
    const builtin = [
      { id: "plan", kind: "prompt", title: "plan", subtitle: "Plan first, show options, and wait" },
      { id: "options", kind: "prompt", title: "options", subtitle: "Present 2-3 choices with a recommendation" },
      { id: "resume", kind: "claude", title: "resume", subtitle: "Resume a Claude Code session" },
      { id: "review", kind: "claude", title: "review", subtitle: "Ask Claude Code to review code" },
      { id: "model", kind: "claude", title: "model", subtitle: "Change Claude Code model" },
      { id: "help", kind: "claude", title: "help", subtitle: "Show Claude Code help" }
    ];
    // ユーザーのスキルとプラグインのスキルも / の候補に出す（mac の ClaudeSkillsScanner と同じ）。
    const home = await agentHome("claude", this.runtime.label);
    return home ? [...builtin, ...scanClaudeSkills(home)] : builtin;
  }

  async currentInfo(): Promise<AgentInfo | undefined> {
    return {
      model: configuredModel(),
      provider: "anthropic",
      runtime: this.runtimeLabel,
      reasoningEffort: readClaudeEffort(),
      codexMode: readClaudeMode() ?? "auto"
    };
  }

  async setModel(_model: string, _provider?: string, reasoningEffort?: string, codexMode?: string): Promise<void> {
    if (codexMode !== undefined) writeChoice("claude.mode", codexMode, CLAUDE_MODES);
    if (reasoningEffort !== undefined) writeChoice("claude.effort", reasoningEffort, CLAUDE_EFFORTS);
  }
}

/* ── ターンの結び付け（docs/BACKGROUND_WORK_2026-10-21.md §3.3。mac の ClaudeTurnRouter の移植） ───────────── */

type Obj = Record<string, unknown>;

/** 停止・行の停止の返事を待つ時間（テストで縮める）。 */
export const claudeSessionTiming = {
  /** 停止の返事（control_response か中断の result）を待つ時間。来なければ、背景の作業が無いときはプロセスツリーを止める。 */
  interruptGraceMs: 3000,
  /** 行・workflow の停止（stop_task）の返事を待つ時間。 */
  stopReplyMs: 5000,
  /** workflow の停止の返事が success のあと、カードが終わるのを待つ時間。 */
  workflowEndMs: 5000
};

/** stdin に書いた発話のターン。 */
interface RegisteredTurn {
  messageId: string;
  /** stdin の user 行に付けた uuid（messageId の小文字） */
  uuid: string;
  /** CLI がこの発話のターンを始めた（command_lifecycle started か、行の uuid で見た） */
  started: boolean;
}

/** 閉じるターン。done は最後のターン（無ければ知らせのターン）で 1 回だけ出す。 */
export interface TurnClosure {
  /** 閉じる発話のターン（stdin に書いた順） */
  messageIds: string[];
  /** 閉じる知らせのターン */
  notificationId: string | undefined;
  /** 中断で閉じる（result error_during_execution・interrupt の返事・cancelled）。エラーにはしない。 */
  interrupted: boolean;
  /** done を出すか。false は、ほかのターンが出力している間に、始まっていない発話だけを静かに閉じるとき。 */
  emitsDone: boolean;
}

/** 1 行を読んだ結果。 */
export interface TurnStep {
  /** 出力の行なら、本文を流す先のターンの messageId */
  output?: string;
  /** 出力の宛先が替わった（差し込んだ発話が始まった・知らせのターンに発話が合流した）。直前の宛先の messageId（呼び出し側は吹き出しを区切る） */
  switchedFrom?: string;
  /** この行で開いた知らせのターンの messageId */
  openedNotification?: string;
  /** 閉じるターン */
  closure?: TurnClosure;
  /** 閉じたターンの残り（中断の後の行・閉じた発話の uuid の行）。本文にも done にも使わない */
  swallowed: boolean;
  /** result の行か */
  isResult: boolean;
}

const emptyStep = (): TurnStep => ({ swallowed: false, isResult: false });

export const closureIsEmpty = (c: TurnClosure): boolean => c.messageIds.length === 0 && c.notificationId === undefined;
/** done を出すターン（最後の発話。無ければ知らせのターン） */
export const closureDoneMessageId = (c: TurnClosure): string | undefined => c.messageIds.at(-1) ?? c.notificationId;
/** 知らせのターンだけを閉じる（done に origin = task-notification を付ける） */
export const closureNotificationOnly = (c: TurnClosure): boolean => c.messageIds.length === 0 && c.notificationId !== undefined;

/**
 * 常駐の claude（-p --input-format stream-json）の stdout の行が、どのターンのものかを決める（mac の ClaudeTurnRouter と同じ）。
 * 規則は docs/BACKGROUND_WORK_2026-10-21.md §3.3（実測: probe-uuid の U1〜U3、probe-stream の S1・S3r・S9・S11。claude 2.1.300）。
 *
 * - stdin の user 行には uuid（Turn.messageId の小文字）を付ける。CLI は command_lifecycle（queued / started / completed）を出し、
 *   system/status の user_message_uuids、最初の stream_event と assistant、result の user_message_uuid(s) にその uuid を返す。
 * - 出力の宛先は 3 つ: なし / 発話のターン（messageId の列）/ 知らせのターン（合成の messageId）。
 *   知らせのターンは、バックグラウンドの作業が終わったときに CLI が自分から始めるターン。stdout に user 行は出ず、
 *   status にも result にも uuid が無い（result には origin = task-notification が付く）。待つ人はいない。
 * - 生成中に差し込んだ発話は今のターンに合流し、result は 2 通分で 1 つ（U2）。差し込んだ発話が始まったら、以後の本文は
 *   その発話の messageId で流す（差し込んだ発話の下の新しい吹き出し）。result が覆うターンは全部閉じる。
 * - command_lifecycle を一度も見ていない（uuid を返さない古い CLI）ときだけ、今までどおり先頭のターンへ結ぶ（FIFO）。
 * - interrupt の返事（control_response）で閉じたターンの残り（中断の result まで）は捨てる。
 *
 * プロセスごとに 1 つ持つ。
 */
export class ClaudeTurnRouter {
  /** 閉じた発話の uuid を覚えておく数（後から届いた、そのターンの行を見分ける）。 */
  static readonly closedMemory = 64;

  private turns: RegisteredTurn[] = [];
  /** 出力の宛先の発話のターン（始まった順。差し込んだ発話が合流すると増える。本文は最後のものへ流す） */
  private outputTurns: string[] = [];
  private notification: string | undefined;
  private lifecycleSeen = false;
  private textDeltaSeen = false;
  private drainingTail = false;
  private closedUuids: string[] = [];

  constructor(private readonly makeId: () => string = () => crypto.randomUUID()) {}

  /** stdin に書いて、まだ閉じていない発話のターン（書いた順）。 */
  get registered(): readonly RegisteredTurn[] {
    return this.turns;
  }

  /** 出力の宛先の知らせのターン */
  get notificationId(): string | undefined {
    return this.notification;
  }

  /** command_lifecycle を一度でも見たか（見ていなければ uuid を返さない古い CLI として FIFO で結ぶ） */
  get sawLifecycle(): boolean {
    return this.lifecycleSeen;
  }

  /** 今の CLI のターンで本文の差分（text_delta）を見たか。見ていなければ result の本文を本文にする。 */
  get sawTextDelta(): boolean {
    return this.textDeltaSeen;
  }

  /** interrupt の返事でターンを閉じた後。中断した CLI のターンの残りを、その result（か次のターンの始まり）まで捨てる。 */
  get draining(): boolean {
    return this.drainingTail;
  }

  /** 出力の宛先が無い（CLI のターンの外） */
  get isIdle(): boolean {
    return this.outputTurns.length === 0 && this.notification === undefined;
  }

  /** 本文を流す先（最後に始まった発話。無ければ知らせのターン） */
  get current(): string | undefined {
    return this.outputTurns.at(-1) ?? this.notification;
  }

  /** stdin に書く前に呼ぶ（書いてから登録すると、速い応答の行を取りこぼす）。 */
  register(messageId: string): void {
    const uuid = messageId.toLowerCase();
    if (this.turns.some((t) => t.uuid === uuid)) return;
    this.turns.push({ messageId, uuid, started: false });
  }

  /** stdin に書けなかった発話を外す。 */
  unregister(messageId: string): void {
    this.turns = this.turns.filter((t) => t.messageId !== messageId);
    this.outputTurns = this.outputTurns.filter((id) => id !== messageId);
  }

  /**
   * stdout の 1 行（JSON）を読む。ターンの出力でない行（system/init・task_*・background_tasks_changed・
   * サブエージェントの行・hook の行など）は空の Step を返す。
   */
  ingest(obj: Obj): TurnStep {
    switch (obj.type) {
      case "command_lifecycle":
        return this.lifecycle(obj);
      case "result":
        return this.result(obj);
      case "system":
        switch (obj.subtype) {
          case "init":
            // CLI のターンはどれも init から始まる。中断したターンの残りはもう来ない。
            this.drainingTail = false;
            return emptyStep();
          case "status":
            // API を呼ぶたびに出る（status: requesting）。null は待ちの終わりなので出力ではない。
            return typeof obj.status === "string" && obj.status !== "" ? this.output(obj) : emptyStep();
          default:
            return emptyStep();
        }
      case "stream_event":
      case "assistant":
      case "user":
        // サブエージェントの行（parent_tool_use_id に親の tool_use id）はターンの出力ではない（メインの行は null）。
        return typeof obj.parent_tool_use_id === "string" ? emptyStep() : this.output(obj);
      default:
        return emptyStep();
    }
  }

  /** JSON でない行（壊れた出力など）。今の宛先へ流す。宛先が無ければ、古い CLI のときだけ先頭の発話へ。 */
  routeRawText(): TurnStep {
    const step = emptyStep();
    if (this.drainingTail) {
      step.swallowed = true;
      return step;
    }
    if (this.isIdle && !this.lifecycleSeen && this.turns.length > 0) this.join(0);
    step.output = this.current;
    return step;
  }

  /**
   * interrupt の返事（control_response）。止めると決めたとき（interrupt を書いたとき）にあったターン（targets）を
   * 中断として閉じる。stillQueued（中断を生き延びて、まだ走る発話の uuid。cancel_queued を知らない古い CLI）は閉じない。
   * CLI のターンが動いていたら、その残り（中断の result まで）を捨てる。
   */
  acknowledgeInterrupt(targets: ReadonlySet<string>, stillQueued: readonly string[]): TurnClosure {
    const survivors = new Set(stillQueued.map((u) => u.toLowerCase()));
    // 生き延びた発話はまだ走っていない（走り出す前の待ち行列）。宛先から外して、始まりを待ち直す。
    for (const t of this.turns) {
      if (!survivors.has(t.uuid)) continue;
      this.outputTurns = this.outputTurns.filter((id) => id !== t.messageId);
      t.started = false;
    }
    const ids = this.turns.filter((t) => targets.has(t.messageId) && !survivors.has(t.uuid)).map((t) => t.messageId);
    const closesNotification = this.notification !== undefined && targets.has(this.notification);
    const closure = this.close(ids, closesNotification, true);
    if (!closureIsEmpty(closure)) {
      this.drainingTail = true;
      this.textDeltaSeen = false;
    }
    return closure;
  }

  private lifecycle(obj: Obj): TurnStep {
    this.lifecycleSeen = true;
    const step = emptyStep();
    const uuid = typeof obj.command_uuid === "string" ? obj.command_uuid.toLowerCase() : undefined;
    const i = uuid === undefined ? -1 : this.turns.findIndex((t) => t.uuid === uuid);
    if (i < 0) return step;
    switch (obj.state) {
      case "started": {
        this.drainingTail = false;
        const before = this.current;
        this.join(i);
        if (before !== undefined && before !== this.current) step.switchedFrom = before;
        break;
      }
      case "completed":
        // 取りこぼしの保険: 始まってもいないのに終わった発話だけを閉じる（始まったものは result で閉じる）。
        // ほかのターンが出力している間は done を出さない（done はターンの終わりの印。今のターンを終わらせない）。
        if (this.turns[i].started) break;
        step.closure = this.close([this.turns[i].messageId], false, false, this.isIdle);
        break;
      case "cancelled":
      case "canceled": {
        // interrupt の cancel_queued などで取り消された（走らない）。
        const id = this.turns[i].messageId;
        this.outputTurns = this.outputTurns.filter((x) => x !== id);
        step.closure = this.close([id], false, true, this.isIdle);
        break;
      }
      default:
        break;
    }
    return step;
  }

  /** 出力の行（system/status・メインの stream_event / assistant / user）。 */
  private output(obj: Obj): TurnStep {
    const step = emptyStep();
    const names = ClaudeTurnRouter.uuids(obj);
    const named = this.turns.flatMap((t, i) => (names.includes(t.uuid) ? [i] : []));
    const before = this.current;
    if (named.length > 0) {
      // この行が名指しする発話を始める（status / 最初の stream_event と assistant が uuid を持つ）。
      this.drainingTail = false;
      for (const i of named) this.join(i);
    } else if (names.length > 0 && names.every((n) => this.closedUuids.includes(n))) {
      // 閉じた発話のターンの行（中断した後の残りなど）
      step.swallowed = true;
      return step;
    } else if (this.drainingTail) {
      step.swallowed = true;
      return step;
    }
    if (this.isIdle) {
      if (!this.lifecycleSeen && this.turns.length > 0) {
        // 古い CLI: 今までどおり先頭の発話へ
        this.join(0);
      } else {
        // 発話の無いターン = 知らせのターン（待つ人はいない）
        const id = this.makeId();
        this.notification = id;
        step.openedNotification = id;
      }
    }
    const now = this.current;
    if (before !== undefined && now !== undefined && before !== now) step.switchedFrom = before;
    step.output = now;
    if (ClaudeTurnRouter.isTextDelta(obj)) this.textDeltaSeen = true;
    return step;
  }

  /**
   * result。閉じるターンは次の順に決める（§3.3）。
   * 1. result.user_message_uuids（無ければ user_message_uuid）にある登録済みの発話
   * 2. 宛先の発話（合流した差し込みを含む。1 に足す）
   * 3. どれも無く、宛先も無く、command_lifecycle を見ていない → 先頭の発話（古い CLI）
   * 4. 開いている知らせのターン
   * 名指しした発話が全部閉じたものなら、そのターンの result（中断の後など）なので何も閉じない。
   */
  private result(obj: Obj): TurnStep {
    const step = emptyStep();
    step.isResult = true;
    try {
      const names = ClaudeTurnRouter.uuids(obj);
      const named = this.turns.filter((t) => names.includes(t.uuid)).map((t) => t.messageId);
      if (this.drainingTail) {
        this.drainingTail = false;
        // 中断したターンの result。閉じてある。
        if (named.length === 0) {
          step.swallowed = true;
          return step;
        }
      }
      if (named.length === 0 && names.length > 0 && names.every((n) => this.closedUuids.includes(n))) {
        step.swallowed = true;
        return step;
      }
      const ids = [...named];
      for (const id of this.outputTurns) if (!ids.includes(id)) ids.push(id);
      if (ids.length === 0 && this.isIdle && !this.lifecycleSeen && this.turns.length > 0) ids.push(this.turns[0].messageId);
      const closure = this.close(ids, true, obj.subtype === "error_during_execution");
      if (!closureIsEmpty(closure)) step.closure = closure;
      return step;
    } finally {
      this.textDeltaSeen = false;
    }
  }

  /** 発話を出力の宛先に入れる（始まった印を付ける）。既に宛先にあれば何もしない。 */
  private join(i: number): void {
    const t = this.turns[i];
    t.started = true;
    if (!this.outputTurns.includes(t.messageId)) this.outputTurns.push(t.messageId);
  }

  private close(ids: readonly string[], notification: boolean, interrupted: boolean, emitsDone = true): TurnClosure {
    const closing = this.turns.filter((t) => ids.includes(t.messageId));
    const closure: TurnClosure = { messageIds: closing.map((t) => t.messageId), notificationId: undefined, interrupted, emitsDone };
    for (const t of closing) this.remember(t.uuid);
    this.turns = this.turns.filter((t) => !ids.includes(t.messageId));
    this.outputTurns = this.outputTurns.filter((id) => !ids.includes(id));
    if (notification && this.notification !== undefined) {
      closure.notificationId = this.notification;
      this.notification = undefined;
    }
    return closure;
  }

  private remember(uuid: string): void {
    this.closedUuids = this.closedUuids.filter((u) => u !== uuid);
    this.closedUuids.push(uuid);
    if (this.closedUuids.length > ClaudeTurnRouter.closedMemory) this.closedUuids.splice(0, this.closedUuids.length - ClaudeTurnRouter.closedMemory);
  }

  /** 行が名指しする発話の uuid（user_message_uuids と user_message_uuid。小文字）。 */
  static uuids(obj: Obj): string[] {
    const out: string[] = [];
    const add = (v: unknown): void => {
      if (typeof v !== "string" || v === "") return;
      const s = v.toLowerCase();
      if (!out.includes(s)) out.push(s);
    };
    if (Array.isArray(obj.user_message_uuids)) for (const v of obj.user_message_uuids) add(v);
    add(obj.user_message_uuid);
    return out;
  }

  /** 本文の差分の行か（--include-partial-messages の stream_event text_delta）。 */
  static isTextDelta(obj: Obj): boolean {
    const event = asObject(obj.event);
    const delta = isPlainObject(event.delta) ? event.delta : asObject(obj.delta);
    return delta.type === "text_delta";
  }
}

/** こちらが書いた制御要求（interrupt）への返事。 */
export interface ControlResponse {
  requestId: string;
  /** subtype が success か（error なら要求は通っていない） */
  success: boolean;
  error?: string;
  /** interrupt の返事: 中断を生き延びて、まだ走る発話の uuid（cancel_queued を知らない古い CLI では待ち行列の全部）。 */
  stillQueued: string[];
}

/**
 * stdout の 1 行が、こちらの制御要求への返事（control_response）ならパースして返す（実測 S6a。request_id は response の中）:
 *
 *   {"type":"control_response","response":{"subtype":"success","request_id":"<uuid>","response":{"still_queued":[]}}}
 */
export function parseControlResponse(line: string): ControlResponse | undefined {
  if (!line.includes('"control_response"')) return undefined;
  const o = parseObject(line);
  if (!o || o.type !== "control_response") return undefined;
  const r = asObject(o.response);
  const requestId = asString(r.request_id);
  if (!requestId) return undefined;
  const body = asObject(r.response);
  return {
    requestId,
    success: r.subtype === "success",
    error: asString(r.error),
    stillQueued: Array.isArray(body.still_queued) ? body.still_queued.filter((u): u is string => typeof u === "string") : []
  };
}

/**
 * 今のターンを止める制御要求（プロセスは残す。実測 2026-10-21、2.1.300）。iPhone の停止は全部を止めるので、待ち行列の発話も
 * 取り消す（cancel_queued。取り消した発話には command_lifecycle cancelled が出る。知らない古い CLI は無視して still_queued に残す）。
 * ターン中なら、返事の後に result{subtype:"error_during_execution"} でターンが閉じ、プロセスは生き続ける。
 */
export function interruptRequest(requestId: string): Obj {
  return { type: "control_request", request_id: requestId, request: { subtype: "interrupt", cancel_queued: true } };
}

/** stdin に流した発話のターンと、CLI が自分から始めた知らせのターン。stdout の行がどのターンのものかは
 *  プロセスごとの ClaudeTurnRouter が決める（発話 1 つに result 1 つとは限らないので、FIFO では数えない）。 */
interface Turn {
  messageId: string;
  child: ChildProcessWithoutNullStreams;
  assistant: string;
  /** このターンの出力の送り先（送った接続の emit。session key の購読者全員へ配られる）。知らせのターンは無し（最後に送った接続へ）。 */
  emit?: Emit;
  /** send() の待機を解く。知らせのターンには無い（待つ人はいない）。 */
  resolve?: () => void;
  /** 知らせのターン（バックグラウンドの作業が終わって CLI が始めた。発話も、待つ人もいない） */
  notification: boolean;
}

/** dynamic workflow のカード（task_id ごと）。終わったものも、後の知らせに名前を載せるために次の新しいターンまで覚えておく。 */
interface WorkflowCard {
  name?: string;
  agents: Obj[];
  /** workflow_progress の phase の全リスト（待機中の見出し用。workflow_progress の行で作り直す） */
  phases?: Obj[];
  finished: boolean;
  /** stop_task を出して返事を待っている（最上位の stoppable を false にする） */
  stopRequested?: boolean;
}

/** プロセスの世代ごとの、行ごとの停止の可否。initialize の success で立て、古い CLI の error や workflow が終わらなかったときに下ろす。 */
interface StopCaps {
  stopTask: boolean;
  workflowStop: boolean;
}

/** こちらが書いた stop_task への返事待ち。プロセスが終わったら undefined で解く。 */
interface PendingStop {
  child: ChildProcessWithoutNullStreams;
  resolve: (response: ControlResponse | undefined) => void;
}

/** interrupt() が書いた停止の制御要求。返事（control_response）か中断の result が来るまで持つ。 */
interface PendingInterrupt {
  requestId: string;
  child: ChildProcessWithoutNullStreams;
  /** 止めると決めたときにあったターン（発話と知らせ）。後から送った発話は閉じない。 */
  targets: Set<string>;
  /** 中断の result などで、止めるターンを done で畳んだ */
  settled: boolean;
  /** 返事がエラーだった（今までどおりプロセスを止める） */
  refused: boolean;
}

/// セッション 1 本につき claude を 1 つ常駐させる（mac の ClaudeCodeSession の移植）。
/// `-p --input-format stream-json` は stdin から user メッセージを 1 行ずつ受け取り、プロセスを生かしたまま
/// 複数ターンを続ける。stdout の行がどのターンのものかは ClaudeTurnRouter が決める（user 行に付けた uuid で結ぶ）。
/// 承認は `--permission-prompt-tool stdio` の制御行で iPhone に尋ね、答えを stdin に書き戻す。
/// 停止は stdin に制御要求（control_request の interrupt）を書く。ターンだけが中断で閉じ、プロセスとバックグラウンドの
/// 作業（サブエージェント・コマンド・dynamic workflow）は残る（実測 2.1.300）。背景の作業は行ごとの stop_task で止める。
/// 返事が来なくても背景の作業があればプロセスは止めない。無ければ（か 2 回続けて来なければ）プロセスごと止め、
/// 次の send が --resume で起こし直す。
class ClaudeCodeSession implements AgentSession {
  /** 音声会話モードの指示は自分で本文末尾の <voice-context> に入れる（server のフォールバックは不要）。 */
  public readonly handlesVoice = true;
  public readonly supportsMidTurnInjection = true;
  public sessionId: string;
  private didEmitSessionStarted: boolean;
  /** 常駐中の claude。無ければ次の send / warm が起こす。 */
  private child?: ChildProcessWithoutNullStreams;
  /** interrupt・設定の変更で外した、終わるのを待っている旧プロセス。次の起動はこれの終了を待つ（同じ transcript に 2 本で書かない）。 */
  private dying?: ChildProcessWithoutNullStreams;
  /** 起動して、まだ終了処理をしていないプロセス。 */
  private readonly liveChildren = new Set<ChildProcessWithoutNullStreams>();
  /** interrupt() 等で止めたプロセス。その終了はエラーではなく done で畳む。 */
  private readonly interruptedChildren = new WeakSet<ChildProcessWithoutNullStreams>();
  /** 未完了のターン（stdin に流した発話と、CLI が自分から始めた知らせのターン）。 */
  private turns: Turn[] = [];
  /** プロセスごとの、stdout の行とターンの結び付け。 */
  private readonly routers = new Map<ChildProcessWithoutNullStreams, ClaudeTurnRouter>();
  /** iPhone の返事待ちの承認・質問（requestId → 内容と、返事を書くプロセス）。プロセスが終われば無効。 */
  private readonly pendingActions = new Map<string, { child: ChildProcessWithoutNullStreams; request: ToolRequest }>();
  /** ターンに属さない出力（知らせのターン・バックグラウンドの作業・承認カードの片付け等）の送り先。最後に send した接続。 */
  private emit?: Emit;
  /** チェックリスト進捗（TaskCreate/TaskUpdate/TodoWrite）。アイドルからの送信で作り直す。 */
  private planTasks: PlanTask[] = [];
  /** サブエージェントとバックグラウンドのコマンドの進行（taskId "subagents" のカード）。バックグラウンドのものはターンをまたぐので、
   *  終わったものだけ次の送信で忘れる。 */
  private readonly subagents = new SubagentTracker();
  /** dynamic workflow（task_id → 名前と最後の行）。終わっていない間は設定の変化での起こし直しを延ばし、
   *  プロセスが終わったとき・close で閉じる payload を出す。 */
  private readonly workflows = new Map<string, WorkflowCard>();
  /** interrupt() が書いた停止の制御要求。返事か中断の result が来るまで持つ。 */
  private pendingInterrupt?: PendingInterrupt;
  /** 返事待ちの initialize（request_id → プロセス）。 */
  private readonly pendingInitialize = new Map<string, ChildProcessWithoutNullStreams>();
  /** プロセスごとの行の停止の可否（initialize が success のプロセスだけ入る）。 */
  private readonly stopCaps = new Map<ChildProcessWithoutNullStreams, StopCaps>();
  /** 返事待ちの stop_task（request_id → 待っている呼び出し）。 */
  private readonly pendingStops = new Map<string, PendingStop>();
  /** 出している行・カードの停止の結果（"row:<id>" / "wf:<task_id>"）。同じものへの 2 度目の停止はこれを待って同じ結果を返す。 */
  private readonly stopRuns = new Map<string, Promise<StopTaskOutcome>>();
  /** 返事が来なかった interrupt の続けて数えた回数（プロセスごと。返事が来たら消す）。 */
  private readonly silentInterrupts = new Map<ChildProcessWithoutNullStreams, number>();
  /** プロセスを残した（kept）interrupt の request_id → プロセス。返事が遅れて届いたら silentInterrupts を戻す。 */
  private readonly keptInterruptIds = new Map<string, ChildProcessWithoutNullStreams>();
  /** 書き込み（ターンの登録）がまだ済んでいない send の数。interrupt() が「止めるターンが無い」と誤って判断しないよう、
   *  登録前の送信もターン中として数える。 */
  private sendsInFlight = 0;
  /** 最後に done で畳んだターンの messageId。止めるターンが無い interrupt に同じ done を返す。 */
  private lastFinishedMessageId?: string;
  /** このチャットだけのモデル / Effort / モード。変わったら次のアイドル送信で起こし直す。 */
  private overrides: SessionOverrides = {};
  /** 今のプロセスを起動したときの設定（configSignature）。 */
  private spawnedSignature?: string;
  /** send() を呼んだ回数。warm() で起こしたプロセスが、その後に使われたかを見る。 */
  private sendCount = 0;
  private closed = false;
  /** 起こしたプロセスが「PC のバックグラウンドで動き始めた」で終わった。server は閉じて取り直す。 */
  private backgroundTaken = false;
  /** send() の前半（プロセスの用意と stdin への書き込み）を呼び出し順に直列化する。追い越すと発話の順が入れ替わる。 */
  private writeChain: Promise<void> = Promise.resolve();

  constructor(
    private readonly agentId: string,
    initialSessionId: string | undefined,
    private readonly cwd: string | undefined,
    private readonly runtime: RuntimeCommand,
    private readonly store: JsonSessionStore,
    /** cron 等が指定した権限モード（plan / edit / auto / dangerous）。全体設定より優先する。 */
    private readonly permissionOverride?: string,
    /** 承認が要る操作を iPhone に尋ねるか（--permission-prompt-tool stdio。無人実行では false）。 */
    private readonly permissionPrompts = true,
    /** 合鍵（orchestrator）。あれば Bridge の MCP を渡す。mainagent のフォルダ（main）なら書く道具も外す。閉じたら無効にする。 */
    private readonly mcp?: McpGrant,
    /** claude --bg のジョブを知る口。bg のジョブの会話は warm で起こさない。 */
    private readonly background?: BackgroundJobHost
  ) {
    this.sessionId = initialSessionId ?? `claude-${crypto.randomUUID()}`;
    this.didEmitSessionStarted = Boolean(initialSessionId);
  }

  async send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    this.emit = emit;
    this.sendCount += 1;
    this.sendsInFlight += 1;
    // 音声会話モードのターン。応え方の指示と遮られた注記は本文末尾の <voice-context> で渡す（起動引数は変えない。mac と同じ）。
    const voice = voiceTurnFrom(originalEvent);
    const { prompt, content } = userContent(text, originalEvent, voice);
    // 先行する send の書き込みが終わるまで待つ（呼び出し順に直列化）。ターンの result を待つのは鎖の外。
    let release!: () => void;
    const previous = this.writeChain;
    this.writeChain = new Promise<void>((resolve) => (release = resolve));
    let finished: Promise<void> | undefined;
    try {
      await previous;
      this.retireProcessIfConfigChanged();
      this.store.ensureSession(this.agentId, this.sessionId, this.cwd);
      this.store.appendMessage(this.agentId, this.sessionId, "user", prompt, this.cwd, originalEvent.messageId ?? crypto.randomUUID());
      let child: ChildProcessWithoutNullStreams;
      try {
        child = await this.ensureProcess();
      } catch (error) {
        // 同期 throw（EINVAL 等）は server の汎用 catch に任せず、ここで Claude Code のエラーとして返す。
        emit(event.error(this.agentId, this.sessionId, `Claude Code spawn failed: ${error instanceof Error ? error.message : String(error)}`));
        return;
      }
      // アイドルからの新しいターンだけチェックリストを作り直し、終わった行と終わった workflow を捨てる（アプリの新しいターンと同じ時点）。
      // 生成中の注入（中断していないターン・知らせのターンが残っている）では消さない。知らせのターンは開いた時点で
      // 空の activity を出すので、本文の前でも server とアプリには生成中に見えている（どちらもこの送信で捨てない。mac と同じ）。
      if (!this.turns.some((t) => !this.interruptedChildren.has(t.child))) {
        this.planTasks = [];
        this.subagents.pruneFinished();
        for (const [taskId, card] of this.workflows) if (card.finished) this.workflows.delete(taskId);
      }
      finished = this.startTurn(child, content, emit);
    } finally {
      // 書き込みが済んだ（または書けなかった）時点で後続の send を通し、登録前の数から外す。
      this.sendsInFlight -= 1;
      release();
    }
    await finished;
  }

  /// 登録済みで終わっていないターンがあるか（差し込んだ発話は、前のターンの result の後の別ターンとして走ることがある。
  /// その間 server は done を見て session を閉じかねないので、閉じる判断に使う。中断したターンは数えない）。
  get hasPendingTurn(): boolean {
    return this.turns.some((t) => !this.interruptedChildren.has(t.child));
  }

  /// 生成中に届いた送信を、今のターンを止めずに stdin へ流す（2.1.300 ではツールの区切りで今のターンに合流し、
  /// result は 2 通分で 1 つになる。probe-uuid U2。ClaudeTurnRouter が両方のターンを閉じる）。
  /// 生きているプロセスで進行中のターンが無ければ false（server が新しいターンとして send する）。
  inject(text: string, originalEvent: SessionEvent, emit: Emit): boolean {
    const child = this.child;
    if (this.closed || !child || !this.liveChildren.has(child) || !this.turns.some((t) => t.child === child)) return false;
    this.emit = emit;
    const { prompt, content } = userContent(text, originalEvent, voiceTurnFrom(originalEvent));
    this.store.ensureSession(this.agentId, this.sessionId, this.cwd);
    this.store.appendMessage(this.agentId, this.sessionId, "user", prompt, this.cwd, originalEvent.messageId ?? crypto.randomUUID());
    void this.startTurn(child, content, emit);
    return true;
  }

  /// 実行中ターンを止める。生きているプロセスには制御要求（interrupt）を書き、ターンだけを中断で閉じる（プロセスと
  /// 背景のサブエージェント・コマンド・dynamic workflow は止まらない。initialize で perTaskStopAffordance を宣言した後の
  /// CLI の動き。止めるのは行ごとの stopTask）。古い CLI（initialize が error）では背景のサブエージェントも止まる。
  /// 返事が interruptGraceMs のうちに来なければ、背景の作業（動いている行・終わっていない workflow）があるときは
  /// プロセスを止めずにそのターンを中断として閉じる。無いとき（と、同じプロセスで 2 回続けて来なかったとき）は
  /// 子プロセスツリーごと止める（cmd シム / wsl.exe 経由だと child.kill では子孫が残る）。
  /// 次の send は --resume で同じ会話を続ける（文脈は transcript が保つ）。
  async interrupt(): Promise<void> {
    // 送ったばかりで stdin に書く前の発話しか無ければ、登録を少しだけ待つ（止める相手を決めてから書く）。
    for (let i = 0; i < 20 && this.sendsInFlight > 0 && !this.turns.some((t) => !this.interruptedChildren.has(t.child)); i += 1) {
      await sleep(50);
    }
    const child = this.child;
    // 止めるターン（発話か知らせのターン）が無ければプロセスを残し、制御要求も書かない（宣言の無い CLI ではアイドル中の
    // interrupt が背景のサブエージェントまで止める。実測 S6e）。止めると次の送信が冷えた起動（--resume）になり、
    // 4〜5 秒待たせる（音声会話で読み上げ中に話しかけたときなど、done の後の停止で起きていた）。
    if (child && !this.hasActiveTurn()) {
      this.emitLastDone();
      return;
    }
    if (child && this.liveChildren.has(child) && !child.stdin.destroyed && !child.stdin.writableEnded) {
      const pending = this.pendingInterrupt;
      if (pending && pending.child === child && !pending.settled && !pending.refused) {
        // 前の停止の返事を待っている。重ねて書かずに、同じ返事を待つ。
        await this.awaitInterrupt(pending.requestId, child);
        return;
      }
      const targets = new Set(this.turns.filter((t) => t.child === child).map((t) => t.messageId));
      if (targets.size === 0) {
        // 止める相手がまだ CLI に居ない（書く前の発話だけ）。アイドル中の interrupt は書かない
        // （宣言の無い CLI では背景のサブエージェントまで止める）。止めた側の「生成中」だけ解く。
        this.emitLastDone();
        return;
      }
      const requestId = crypto.randomUUID();
      this.pendingInterrupt = { requestId, child, targets, settled: false, refused: false };
      if (writeStdinLine(child, interruptRequest(requestId), this.runtime.kind)) await this.awaitInterrupt(requestId, child);
      else this.terminateForInterrupt(requestId, child);
      return;
    }
    if (child) {
      this.retire(child);
      return;
    }
    // プロセスが既に無いのに残っているターン（終了処理に拾われなかったもの）は、止めた側が done で閉じる。
    for (const turn of this.turns.filter((t) => !this.liveChildren.has(t.child))) {
      this.turns.splice(this.turns.indexOf(turn), 1);
      this.emitOf(turn)?.(event.done(this.agentId, this.sessionId, turn.messageId));
      turn.resolve?.();
    }
  }

  /** 止めるべきターンがあるか（登録前の送信を含む）。 */
  private hasActiveTurn(): boolean {
    return this.sendsInFlight > 0 || this.turns.some((t) => !this.interruptedChildren.has(t.child));
  }

  /** 止めた側の「生成中」を必ず解く（直近の done と同じ id なので、完了音などは繰り返されない）。 */
  private emitLastDone(): void {
    this.emit?.({ type: "done", agentId: this.agentId, sessionId: this.sessionId, messageId: this.lastFinishedMessageId });
  }

  /** 停止の返事（か中断の result）を interruptGraceMs まで待つ。来なければ（返事がエラーでも）terminateForInterrupt が決める。 */
  private async awaitInterrupt(requestId: string, child: ChildProcessWithoutNullStreams): Promise<void> {
    const steps = Math.max(1, Math.round(claudeSessionTiming.interruptGraceMs / 100));
    for (let i = 0; i < steps; i += 1) {
      // 返事が来た・プロセスが終わった・別の停止に替わった。
      const state = this.pendingInterrupt;
      if (!state || state.requestId !== requestId) return;
      if (state.refused) break;
      if (state.settled) return;
      await sleep(100);
    }
    this.terminateForInterrupt(requestId, child);
  }

  /** 制御要求で止められなかった（返事が来ない・error）。背景の作業があれば、プロセスは止めずに止めると決めたターンだけを
   *  中断として閉じる（プロセスを止めると背景の作業が消える。残りの出力はルーターが捨てる）。無ければ、と、同じプロセスで
   *  2 回続けて来ないとき（CLI が固まっている）は、プロセスツリーを止め、終了処理が進行中のターンを中断として畳む。 */
  private terminateForInterrupt(requestId: string, child: ChildProcessWithoutNullStreams): void {
    const pending = this.pendingInterrupt;
    if (pending?.requestId !== requestId) return;
    this.pendingInterrupt = undefined;
    if (this.child !== child) return;
    const silent = this.silentInterrupts.get(child) ?? 0;
    if (silent === 0 && (this.subagents.hasRunning || this.hasUnfinishedWorkflow)) {
      this.silentInterrupts.set(child, 1);
      this.keptInterruptIds.set(requestId, child);
      process.stderr.write(`[claude-code:${this.runtime.kind}] interrupt not acknowledged; kept process for background work session=${this.sessionId}\n`);
      const closure = this.routers.get(child)?.acknowledgeInterrupt(pending.targets, []);
      if (closure && !closureIsEmpty(closure)) {
        this.resolvePendingActions(child, { deny: true });
        this.closeTurns(closure, child);
      } else {
        this.emitLastDone();
      }
      return;
    }
    process.stderr.write(`[claude-code:${this.runtime.kind}] interrupt not acknowledged, terminating session=${this.sessionId}\n`);
    this.retire(child);
  }

  /** こちらが書いた制御要求への返事。initialize と stop_task は request_id で見分け、それ以外は停止（interrupt）。
   *  interrupt は止めると決めたときのターンを中断として閉じ、プロセスは残す。中断したターンの残り（result まで）はルーターが捨てる。
   *  initialize の返事の中身（アカウントのメールと pid）は見ない・出さない。 */
  private handleControlResponse(response: ControlResponse, child: ChildProcessWithoutNullStreams): void {
    if (this.pendingInitialize.get(response.requestId) === child) {
      this.pendingInitialize.delete(response.requestId);
      this.handleInitializeResponse(response, child);
      return;
    }
    const stop = this.pendingStops.get(response.requestId);
    if (stop && stop.child === child) {
      this.pendingStops.delete(response.requestId);
      stop.resolve(response);
      return;
    }
    // kept にした interrupt の返事が遅れて届いた。CLI は生きていて応じたので、数え直す。
    if (this.keptInterruptIds.get(response.requestId) === child) {
      this.keptInterruptIds.delete(response.requestId);
      this.silentInterrupts.delete(child);
      return;
    }
    const pending = this.pendingInterrupt;
    if (!pending || pending.requestId !== response.requestId || pending.child !== child) return;
    if (!response.success) {
      // 受け付けられなかった。awaitInterrupt が今までどおりプロセスを止める。
      pending.refused = true;
      process.stderr.write(`[claude-code:${this.runtime.kind}] interrupt refused: ${response.error ?? "-"}\n`);
      return;
    }
    this.pendingInterrupt = undefined;
    this.silentInterrupts.delete(child);
    const closure = this.routers.get(child)?.acknowledgeInterrupt(pending.targets, response.stillQueued);
    if (closure && !closureIsEmpty(closure)) {
      // 止めたターンの返事待ちは、もう誰も待っていない（背景のサブエージェントの承認は残す）。
      this.resolvePendingActions(child, { deny: false });
      this.closeTurns(closure, child);
    } else if (!pending.settled) {
      // 止めるターンは返事の前に終わっていた。止めた側の「生成中」を必ず解く（直近の done と同じ id）。
      this.emitLastDone();
    }
  }

  /** initialize の返事。success ならそのプロセスの世代で行の停止を有効にする。error なら無効のまま（interrupt は今までの意味）。 */
  private handleInitializeResponse(response: ControlResponse, child: ChildProcessWithoutNullStreams): void {
    if (!response.success) {
      process.stderr.write(`[claude-code:${this.runtime.kind}] initialize refused; per-task stop disabled\n`);
      return;
    }
    this.stopCaps.set(child, { stopTask: true, workflowStop: true });
    if (this.child === child) this.emitPayload(this.subagents.setClaudeStopTask(true), child);
  }

  /** トラッカーの payload を流す（無ければ何もしない）。 */
  private emitPayload(payload: string | undefined, child?: ChildProcessWithoutNullStreams): void {
    if (!payload) return;
    const emit = child ? this.emitFor(child) : this.emit;
    emit?.(event.workflowProgress(this.agentId, this.sessionId, payload));
  }

  /// 背景の作業を 1 つ止める（stop_task_request）。taskId が "subagents" なら行、それ以外は dynamic workflow のカード全体。
  /// 同じものへの停止がもう CLI に出ていれば、新しく書かずにその結果を待つ。
  async stopTask(req: StopTaskRequest): Promise<StopTaskOutcome> {
    const row = req.taskId === SubagentTracker.taskId;
    if (row && (!req.rowId || req.epoch !== this.subagents.epoch)) return { kind: "stale" };
    const key = row ? `row:${req.rowId}` : `wf:${req.taskId}`;
    const running = this.stopRuns.get(key);
    if (running) return running;
    const run = row ? this.stopRow(req.rowId!) : this.stopWorkflow(req.taskId);
    this.stopRuns.set(key, run);
    try {
      return await run;
    } finally {
      if (this.stopRuns.get(key) === run) this.stopRuns.delete(key);
    }
  }

  /** stop_task を書いて、同じ request_id の返事を待つ。プロセスが終わったら undefined、来なければ "timeout"。 */
  private async writeStopTask(child: ChildProcessWithoutNullStreams, taskId: string): Promise<ControlResponse | "timeout" | undefined> {
    const requestId = crypto.randomUUID().toLowerCase();
    let timer: NodeJS.Timeout | undefined;
    const reply = new Promise<ControlResponse | undefined>((resolve) => this.pendingStops.set(requestId, { child, resolve }));
    const timeout = new Promise<"timeout">((resolve) => {
      timer = setTimeout(() => resolve("timeout"), claudeSessionTiming.stopReplyMs);
    });
    if (!writeStdinLine(child, stopTaskRequest(requestId, taskId), this.runtime.kind)) {
      this.pendingStops.delete(requestId);
      clearTimeout(timer);
      return undefined;
    }
    try {
      return await Promise.race([reply, timeout]);
    } finally {
      clearTimeout(timer);
      this.pendingStops.delete(requestId);
    }
  }

  private async stopRow(rowId: string): Promise<StopTaskOutcome> {
    const tracker = this.subagents;
    const begin = tracker.beginStop(rowId);
    if (begin.kind === "notRunning") return tracker.has(rowId) ? { kind: "notRunning" } : { kind: "stale" };
    if (begin.kind === "inFlight") return this.stopRuns.get(`row:${rowId}`) ?? { kind: "notRunning" };
    if (begin.kind !== "ok") return { kind: "unsupported" };
    const child = this.child;
    const caps = child ? this.stopCaps.get(child) : undefined;
    if (!child || !this.liveChildren.has(child)) {
      tracker.endStop(rowId);
      return { kind: "notRunning" };
    }
    if (!caps?.stopTask) {
      this.emitPayload(tracker.endStop(rowId), child);
      return { kind: "unsupported" };
    }
    this.emitPayload(begin.payload, child);
    const response = await this.writeStopTask(child, rowId);
    if (response === undefined) {
      // 書けなかった。プロセスがまだ生きているなら、行を止められない状態のまま残さない。
      if (!this.liveChildren.has(child)) return { kind: "notRunning" };
      this.emitPayload(tracker.endStop(rowId), child);
      return { kind: "failed" };
    }
    if (response === "timeout") {
      this.emitPayload(tracker.endStop(rowId), child);
      return { kind: "timeout" };
    }
    if (!response.success) {
      const message = response.error ?? "";
      if (!message.includes("Unsupported control request subtype") && tracker.stateOf(rowId) !== "running") {
        // 押した直後に行が終わった（CLI は「Task X is not running」と返す）。失敗ではなく not_running。
        this.emitPayload(tracker.endStop(rowId), child);
        return { kind: "notRunning" };
      }
      if (message.includes("Unsupported control request subtype")) {
        // 古い CLI。この世代の行の停止を下ろし、全行の手がかりを外して送り直す。
        caps.stopTask = false;
        tracker.endStop(rowId);
        this.emitPayload(tracker.setClaudeStopTask(false), child);
        return { kind: "unsupported" };
      }
      this.emitPayload(tracker.endStop(rowId), child);
      return { kind: "failed", message: message.slice(0, 200) || undefined };
    }
    const state = tracker.stateOf(rowId);
    if (state === "running") {
      // CLI はその task を動かしていなかった。こちらで stopped にして閉じる。
      this.emitPayload(tracker.finish(rowId, "stopped"), child);
      return { kind: "stopped" };
    }
    if (state === "stopped") return { kind: "stopped" };
    return { kind: "notRunning" };
  }

  private async stopWorkflow(taskId: string): Promise<StopTaskOutcome> {
    const card = this.workflows.get(taskId);
    if (!card || card.finished) return { kind: "notRunning" };
    const child = this.child;
    const caps = child ? this.stopCaps.get(child) : undefined;
    if (!child || !this.liveChildren.has(child)) return { kind: "notRunning" };
    if (!caps?.stopTask || !caps.workflowStop) return { kind: "unsupported" };
    card.stopRequested = true;
    this.emitWorkflowStoppable(taskId, card, child);
    const response = await this.writeStopTask(child, taskId);
    // success のあいだは true のまま（カードが終わるまで stoppable: false を送る）。戻すのは下の各分岐。
    if (response === undefined) {
      card.stopRequested = false;
      return { kind: "notRunning" };
    }
    if (response === "timeout") {
      card.stopRequested = false;
      if (card.finished) return { kind: "notRunning" };
      this.emitWorkflowStoppable(taskId, card, child);
      return { kind: "timeout" };
    }
    if (!response.success) {
      card.stopRequested = false;
      const message = response.error ?? "";
      if (!message.includes("Unsupported control request subtype") && card.finished) return { kind: "notRunning" };
      if (message.includes("Unsupported control request subtype")) {
        caps.stopTask = false;
        this.emitPayload(this.subagents.setClaudeStopTask(false), child);
        this.emitUnfinishedWorkflowsLocked(child);
        return { kind: "unsupported" };
      }
      this.emitWorkflowStoppable(taskId, card, child);
      return { kind: "failed", message: message.slice(0, 200) || undefined };
    }
    // success の後、カードが終わる（task_updated killed か task_notification stopped）のを待つ。
    const deadline = Date.now() + claudeSessionTiming.workflowEndMs;
    while (!card.finished && Date.now() < deadline && this.liveChildren.has(child)) await sleep(50);
    card.stopRequested = false;
    if (card.finished) return { kind: "stopped" };
    if (!this.liveChildren.has(child)) return { kind: "notRunning" };
    // まだ動いているかもしれないので閉じない。この世代では workflow の停止を下ろす。
    caps.workflowStop = false;
    this.emitUnfinishedWorkflowsLocked(child);
    return { kind: "failed" };
  }

  /** workflow のカード 1 枚の stoppable だけを変えて送る（task_progress。agents などは付けない）。 */
  private emitWorkflowStoppable(taskId: string, card: WorkflowCard, child: ChildProcessWithoutNullStreams): void {
    // 終わったカードに running を送ると生き返る。終わりの payload が stoppable: false を運んでいる。
    if (card.finished) return;
    const out: Obj = { subtype: "task_progress", taskId, status: "running", stoppable: this.workflowStoppable(card) };
    if (card.name !== undefined) out.workflowName = card.name;
    this.emitFor(child)?.(event.workflowProgress(this.agentId, this.sessionId, JSON.stringify(out)));
  }

  /** 終わっていない workflow のカードを、今の可否で送り直す（workflow の停止を下ろしたとき）。 */
  private emitUnfinishedWorkflowsLocked(child: ChildProcessWithoutNullStreams): void {
    for (const [taskId, card] of this.workflows) if (!card.finished) this.emitWorkflowStoppable(taskId, card, child);
  }

  /** 終わっていない workflow のカードを今止められるか（現在のプロセスの世代が宣言済みで、返事待ちでないこと）。 */
  private workflowStoppable(card: WorkflowCard): boolean {
    const caps = this.child ? this.stopCaps.get(this.child) : undefined;
    return !card.finished && card.stopRequested !== true && caps?.stopTask === true && caps.workflowStop;
  }

  async close(): Promise<void> {
    this.closed = true;
    // バックグラウンドの作業はプロセスと一緒に止まり、終わりの知らせはもう来ない。止める前に、実行中の行と終わっていない
    // dynamic workflow を stopped で閉じる payload を流す（自分で止めた）。
    this.emitAbandoned("stopped");
    for (const child of [this.child, this.dying]) {
      if (!child) continue;
      this.interruptedChildren.add(child);
      killProcessTree(child);
    }
    this.child = undefined;
    this.resolvePendingActions();
    if (this.mcp) orchestrator.revoke(this.mcp.token);
  }

  /** 合鍵（テスト用）。 */
  get mainToken(): string | undefined {
    return this.mcp?.token;
  }

  applyOverrides(overrides: SessionOverrides): void {
    this.overrides = { ...overrides };
  }

  /** 生成中は取り直さない。 */
  isStillUsable(): boolean {
    return !this.backgroundTaken || this.sendsInFlight > 0 || this.turns.length > 0;
  }

  /// 送る前に claude を起こしておく（チャットを開いたとき）。起動と SessionStart の hook を先に済ませ、1 通目の待ちを縮める。
  /// ここで起こしたプロセスが WARM_IDLE_MS のあいだ使われなければ畳む。前から動いているプロセスには触らない。
  async warm(): Promise<void> {
    // bg のジョブの会話は、開いただけで 5 分握ると PC の claude respawn / attach が断られる。
    await this.background?.ready?.().catch(() => {});
    if (this.background?.isJob(this.sessionId)) return;
    this.retireProcessIfConfigChanged();
    const before = this.child;
    const sends = this.sendCount;
    let child: ChildProcessWithoutNullStreams;
    try {
      child = await this.ensureProcess();
    } catch {
      return;
    }
    if (child === before) return;
    const timer = setTimeout(() => {
      if (this.sendCount !== sends || this.child !== child || this.turns.length > 0 || this.pendingActions.size > 0) return;
      this.retire(child);
    }, WARM_IDLE_MS);
    timer.unref();
  }

  async respondToAction(requestId: string, decision: string, answers: Record<string, string>): Promise<void> {
    const pending = this.pendingActions.get(requestId);
    // 応答済み・プロセス交代後など、もう待っていない要求には書かない（iPhone に残った古いカード対策）。
    if (!pending) return;
    this.pendingActions.delete(requestId);
    if (this.liveChildren.has(pending.child)) {
      writeStdinLine(pending.child, successResponse(requestId, permissionResult(pending.request, decision, answers)), this.runtime.kind);
    }
    // 他の画面（デスクトップ等）に残っているカードも閉じさせる。
    this.emit?.({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId });
  }

  /** サブエージェントのカードの全行（workflow_snapshot、epoch 付き。行が無くても agents: []）。
   *  server が接続したときと turn_status_request のときに、ターンの状態に関係なく送る（§3.5）。 */
  subagentSnapshot(): string | undefined {
    return this.subagents.snapshot({ includeEmpty: true });
  }

  argsForPrompt(_voice?: VoiceTurn): string[] {
    // プロンプトは argv ではなく stdin から stream-json で流す（プロセスがターンをまたいで生き続ける。
    // 長いプロンプトが Windows のコマンドライン上限を超えて spawn や .cmd シムが失敗することもない）。
    const args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"];
    if (!this.sessionId.startsWith("claude-")) args.push("--resume", this.sessionId);
    if (this.mcp) {
      // Bridge の MCP を渡す。合鍵は環境変数（ensureProcess の env）。mainagent は書く道具を外し、権限モードを default に
      // 固定する（送る・起こすの承認は Bridge が iPhone に尋ねる。チャットで Auto などを選んでいても使わない）。
      const file = writeClaudeMcpConfigFile(mainAgentPort());
      args.push(...claudeMcpArgs(this.runtime.kind === "wsl" ? toWslPath(file) : file, this.mcp.main));
    }
    if (!this.mcp?.main) {
      // per-run 上書き（cron 等）> チャットの上書き > 全体設定 > 環境変数の生値、の優先順（mac と同じ）。
      const permission =
        claudePermissionFlag(this.permissionOverride) ??
        claudePermissionFlag(this.overrides.mode) ??
        claudePermissionFlag(readClaudeMode()) ??
        process.env.BUDDYOS_CLAUDE_PERMISSION_MODE;
      if (permission) args.push("--permission-mode", permission);
    }
    // 承認が要る操作を iPhone に尋ねる。付けないと claude は何も尋ねずに自動で断る（mac で実測）。
    // BUDDYOS_CLAUDE_PERMISSION_PROMPTS=0 で無効化できる。
    if (this.permissionPrompts && process.env.BUDDYOS_CLAUDE_PERMISSION_PROMPTS !== "0") {
      args.push("--permission-prompt-tool", "stdio");
    }
    const model = this.effectiveModel();
    if (model) args.push("--model", model);
    // 音声会話でも起動引数は変えない（指示は本文の <voice-context>。system prompt を変えるとキャッシュが効かず、起こし直しも要る）。
    // Effort はチャットの上書き（ユーザーが選んだもの）> 既定をそのまま使う。
    const tier = this.explicitEffort();
    if (tier) args.push("--effort", cliEffort(tier));
    if (tier === "ultracode") args.push("--append-system-prompt", ULTRACODE_DIRECTIVE);
    return args;
  }

  /** このチャットで使うモデル。チャットの上書き > env の既定。 */
  private effectiveModel(): string | undefined {
    return this.overrides.model ?? configuredModel();
  }

  /** `--effort` に明示する tier。チャットの上書き > env > 保存した既定。無ければ付けず、CLI が settings.json を読む。 */
  private explicitEffort(): string | undefined {
    const chat = this.overrides.reasoningEffort;
    if (chat && CLAUDE_EFFORTS.includes(chat)) return chat;
    const env = process.env.BUDDYOS_CLAUDE_EFFORT?.trim();
    if (env) return env;
    return readClaudeEffort();
  }

  /** プロセス起動時に効く設定の要約。変わったら次のアイドル送信で起こし直す（--resume の有無は含めない）。 */
  private configSignature(): string {
    return [
      this.effectiveModel() ?? "",
      this.explicitEffort() ?? "",
      // mainagent は権限モードを default に固定するので、モードの変更では起こし直さない。
      this.mcp?.main ? "main" : (this.permissionOverride ?? this.overrides.mode ?? readClaudeMode() ?? "")
    ].join("|");
  }

  /// 設定（チャットの上書き・既定）が起動時から変わっていて、ターンも承認待ちも無ければ常駐プロセスを畳む。
  /// 次の ensureProcess が新しい設定と --resume で起こし直す。生成中は畳まず、次にアイドルで送るときに反映する。
  /// バックグラウンドの作業（動いているサブエージェント・コマンドの行、終わっていない dynamic workflow）がある間も
  /// 延ばす（プロセスと一緒に止まり、終わりの知らせも来なくなる）。
  private retireProcessIfConfigChanged(): void {
    const child = this.child;
    if (!child || this.spawnedSignature === undefined || this.spawnedSignature === this.configSignature()) return;
    if (this.turns.some((t) => t.child === child) || this.pendingActions.size > 0) return;
    if (this.subagents.hasRunning || this.hasUnfinishedWorkflow) return;
    this.retire(child);
  }

  /** 今のプロセスを外して止める。終了はエラーではなく done で畳み、次の起動はこれの終了を待つ。 */
  private retire(child: ChildProcessWithoutNullStreams): void {
    this.interruptedChildren.add(child);
    if (this.child === child) this.child = undefined;
    this.dying = child;
    // 止めたプロセスへの返事は届かない。iPhone に残った承認カードを閉じる。
    this.resolvePendingActions(child);
    killProcessTree(child);
  }

  /** 常駐プロセスを返す。無ければ（初回 / interrupt 後 / 異常終了後）起動する。 */
  private async ensureProcess(): Promise<ChildProcessWithoutNullStreams> {
    await this.waitForDying();
    if (this.closed) throw new Error("session closed");
    if (this.child && this.liveChildren.has(this.child)) return this.child;
    const args = this.argsForPrompt();
    const signature = this.configSignature();
    const env = buildClaudeEnv();
    // mainagent の合鍵は環境変数で渡す（--mcp-config のヘッダは ${BUDDYOS_MCP_TOKEN} で展開させる。引数に載せると見える）。
    if (this.mcp) env[TOKEN_ENV_VAR] = this.mcp.token;
    // ultracode では dynamic workflows を確実に有効にする（mac と同じ）。
    if (this.explicitEffort() === "ultracode") env.CLAUDE_CODE_WORKFLOWS = "1";
    const child = spawnRuntime(this.runtime, args, { cwd: this.cwd, env, stdio: "pipe" });
    this.child = child;
    this.spawnedSignature = signature;
    this.liveChildren.add(child);
    this.routers.set(child, new ClaudeTurnRouter());
    this.attach(child);
    // 前のプロセスの宣言は引き継がない（このプロセスの initialize が success になるまで行は止められない）。
    this.emitPayload(this.subagents.setClaudeStopTask(false));
    // 最初の user 行より前に、行ごとの停止を使うと宣言する。返事は待たない（handleControlResponse が受ける）。
    const initializeId = crypto.randomUUID().toLowerCase();
    this.pendingInitialize.set(initializeId, child);
    if (!writeStdinLine(child, initializeRequest(initializeId), this.runtime.kind)) this.pendingInitialize.delete(initializeId);
    return child;
  }

  /** 止めた旧プロセスの終了を待つ（transcript を書き終えてから --resume で起こし直す）。落ちなければ強制終了する。 */
  private async waitForDying(): Promise<void> {
    const dying = this.dying;
    if (!dying) return;
    if (this.liveChildren.has(dying)) {
      await new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
          killProcessTree(dying);
          resolve();
        }, DYING_WAIT_MS);
        timer.unref();
        dying.once("close", () => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
    if (this.dying === dying) this.dying = undefined;
  }

  private attach(child: ChildProcessWithoutNullStreams): void {
    // stderr は常に読んで末尾だけ持つ（読まないと長時間の常駐でパイプが詰まる）。cmd.exe / wsl.exe の
    // エラーは UTF-8 ではないので、Buffer のまま持って表示するときに読み直す。
    const stderrChunks: Buffer[] = [];
    let stderrBytes = 0;
    child.stderr.on("data", (chunk: Buffer) => {
      stderrChunks.push(chunk);
      stderrBytes += chunk.length;
      while (stderrBytes > STDERR_TAIL_BYTES && stderrChunks.length > 1) stderrBytes -= stderrChunks.shift()!.length;
      process.stderr.write(`[claude-code:${this.runtime.kind}] ${decodeConsoleText(chunk)}`);
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
        if (line) this.handleLine(line, child);
      }
    });

    // stdin の 'error'（EPIPE / ERR_STREAM_DESTROYED）は子プロセスが先に死んだ場合に出るので拾ってログだけにし、
    // 失敗自体は終了処理で error として返す。
    child.stdin.on("error", (error) => {
      process.stderr.write(`[claude-code:${this.runtime.kind}] stdin error: ${String(error)}\n`);
    });

    let exited = false;
    const onExit = (failure: string | undefined): void => {
      if (exited) return;
      exited = true;
      this.handleExit(child, failure);
    };
    child.on("close", (code) => {
      onExit(code === 0 ? undefined : `Claude Code failed: ${decodeConsoleText(Buffer.concat(stderrChunks)).trim() || `exit code ${code}`}`);
    });
    child.on("error", (error) => onExit(`Claude Code spawn failed: ${error.message}`));
  }

  /** そのプロセスの、stdout の行とターンの結び付け。 */
  private routerFor(child: ChildProcessWithoutNullStreams): ClaudeTurnRouter {
    let router = this.routers.get(child);
    if (!router) {
      router = new ClaudeTurnRouter();
      this.routers.set(child, router);
    }
    return router;
  }

  /// ターンを登録してから stdin に書く（書いてから登録すると、速い応答のターンを見つけられない）。そのターンを閉じたら解決する。
  /// user 行には uuid（messageId の小文字）を付ける。CLI が command_lifecycle と user_message_uuid(s) でこの発話のターンを名指しする（§3.3）。
  private startTurn(child: ChildProcessWithoutNullStreams, content: string | Array<Record<string, unknown>>, emit: Emit): Promise<void> {
    let resolve!: () => void;
    const finished = new Promise<void>((r) => (resolve = r));
    const messageId = crypto.randomUUID();
    const turn: Turn = { messageId, child, assistant: "", emit, resolve, notification: false };
    this.turns.push(turn);
    const live = this.liveChildren.has(child);
    const router = live ? this.routerFor(child) : undefined;
    router?.register(messageId);
    const written = live && writeStdinLine(child, { type: "user", uuid: messageId.toLowerCase(), message: { role: "user", content } }, this.runtime.kind);
    if (!written) {
      this.turns.splice(this.turns.indexOf(turn), 1);
      router?.unregister(messageId);
      emit(event.error(this.agentId, this.sessionId, "Claude Code exited before the message was delivered"));
      resolve();
    }
    return finished;
  }

  private handleLine(line: string, child: ChildProcessWithoutNullStreams): void {
    // こちらが書いた制御要求（停止）への返事。
    const response = parseControlResponse(line);
    if (response) {
      this.handleControlResponse(response, child);
      return;
    }
    // 承認・質問の制御行（--permission-prompt-tool stdio）。本文ではないので parseLine には渡さない。
    const control = parseControlLine(line);
    if (control) {
      this.handleControl(control, child);
      return;
    }
    const obj = parseObject(line);
    const router = this.routerFor(child);
    // warm() で送る前に起こしたプロセスは、起動してすぐ SessionStart の hook の行（session_id 付き）を出す。まだ発話が無く
    // transcript も作られていないので、ここで session を確定（session_started）させない（覚えた ID で --resume すると
    // 「会話が無い」で失敗する）。確定は最初の発話の後の行で行う。
    if (obj && isHookLine(obj) && router.isIdle && !this.turns.some((t) => t.child === child)) return;

    // どのターンの行かを決める。発話のターンは uuid で結び、発話の無い出力は知らせのターンとして開く。
    const sawTextDelta = router.sawTextDelta;
    const step = obj ? router.ingest(obj) : router.routeRawText();
    if (step.openedNotification !== undefined) {
      const opened: Turn = { messageId: step.openedNotification, child, assistant: "", notification: true };
      this.turns.push(opened);
      // 最初の本文が来るまで（1〜数秒。thinking やツールが先に走ればもっと長い）、server に何も届かないと
      // 「アイドル」に見えて dispose / 解放で CLI が止められ、報告と push が消える。空の activity で生成中にする
      // （終わりは必ず done。本文の無い知らせのターンは silent の done）。
      this.emitOf(opened)?.(event.activity(this.agentId, this.sessionId, opened.messageId, ""));
    }
    if (step.switchedFrom !== undefined) {
      // 差し込んだ発話（か、知らせのターンに合流した発話）が始まった。ここまでの吹き出しを区切り、
      // 以後の本文はその発話の下の新しい吹き出しに出す（アプリは次の差分を新しい吹き出しにする）。
      const prev = this.turns.find((t) => t.messageId === step.switchedFrom);
      if (prev && prev.assistant !== "") this.emitOf(prev)?.(event.assistantTurnEnd(this.agentId, this.sessionId, prev.messageId));
    }

    const parsed = this.parseLine(obj, line, sawTextDelta);
    if (parsed.sessionId && parsed.sessionId !== this.sessionId) this.adoptSessionId(parsed.sessionId);

    // CLI のターンの終わり。stream-json では `type: "result"` の行がターン境界（常駐なのでプロセス終了ではない）。
    // 1 つの result が、合流した差し込みの発話を含む複数のターンと、開いている知らせのターンを閉じる。
    if (step.isResult) {
      // ターンが終わったのに返事待ちが残っていれば、もう誰も待っていない。カードを閉じる（背景のサブエージェントの承認は残す）。
      this.resolvePendingActions(child, { deny: false });
      // 中断した後の残り・閉じるターンの無い result は、本文にも done にも使わない。
      const closure = step.closure;
      if (!closure) return;
      // 部分メッセージを受けていなければ、result の本文を done を出すターンに反映してから畳む。
      const mid = closureDoneMessageId(closure);
      if (!sawTextDelta && parsed.text && mid !== undefined) {
        const turn = this.turns.find((t) => t.messageId === mid);
        if (turn) turn.assistant += parsed.text;
        const emit = this.emitOf(turn);
        this.emitSessionStartedIfNeeded(emit);
        emit?.(event.assistantDelta(this.agentId, this.sessionId, mid, parsed.text));
      }
      this.closeTurns(closure, child);
      return;
    }
    // command_lifecycle で閉じるターン（始まる前に終わった・取り消された発話）。
    if (step.closure) this.closeTurns(step.closure, child);

    if (parsed.text) {
      const turn = step.output !== undefined ? this.turns.find((t) => t.messageId === step.output) : undefined;
      const emit = turn ? this.emitOf(turn) : this.emitFor(child);
      this.emitSessionStartedIfNeeded(emit);
      if (!step.swallowed && step.output !== undefined) {
        if (turn) turn.assistant += parsed.text;
        emit?.(event.assistantDelta(this.agentId, this.sessionId, step.output, parsed.text));
      }
    } else if (parsed.sessionId) {
      this.emitSessionStartedIfNeeded(this.emitFor(child));
    }
    if (!obj) return;
    const emit = this.emitFor(child);
    // dynamic workflow（system/task_*）の進捗を正規化してクライアントへ。
    const workflow = this.workflowEventPayload(obj);
    if (workflow) emit?.(event.workflowProgress(this.agentId, this.sessionId, workflow));
    // サブエージェントとバックグラウンドのコマンドの進行も workflow カードとして送る。ターンの外の行も渡す
    // （バックグラウンドの作業は result の後も動き、終わりの知らせは知らせのターンの前に届く）。
    if (obj.type === "system" || obj.type === "assistant" || obj.type === "user") {
      const p = this.subagents.ingestStreamLine(obj);
      if (p) emit?.(event.workflowProgress(this.agentId, this.sessionId, p));
    }
    // チェックリスト進捗（TaskCreate/TaskUpdate/TodoWrite）を全置換スナップショットで流す（mac ClaudeCodeAdapter と同形）。
    const planJson = applyPlanFromLine(obj, this.planTasks);
    if (planJson) emit?.(event.planUpdate(this.agentId, this.sessionId, planJson));
  }

  /** 実 session_id を覚える（sessions.json の付け替えと、mainagent の親の id）。 */
  private adoptSessionId(sessionId: string): void {
    // sessions.json の保存失敗（Windows の rename EPERM/EBUSY 等）で chunk の残り行を失わないよう握る。
    // メモリ上は置換済みなので次の save で永続化される。
    try {
      this.store.replaceSessionId(this.agentId, this.sessionId, sessionId, this.cwd);
    } catch (error) {
      process.stderr.write(`[claude-code:${this.runtime.kind}] session store save failed: ${error instanceof Error ? error.message : String(error)}\n`);
    }
    this.sessionId = sessionId;
    if (this.mcp) orchestrator.setParentSessionId(this.mcp.token, sessionId);
  }

  /** そのターンの出力の送り先。知らせのターンは最後に送った接続へ（購読者全員へ配られる）。 */
  private emitOf(turn: Turn | undefined): Emit | undefined {
    return turn?.emit ?? this.emit;
  }

  /** ターンに属さない行（task_*・承認のカードなど）の送り先。そのプロセスの先頭のターン、無ければ最後に送った接続。 */
  private emitFor(child: ChildProcessWithoutNullStreams): Emit | undefined {
    return this.emitOf(this.turns.find((t) => t.child === child));
  }

  /// 承認・質問の制御行。カードを出して返事を待つ（返事は respondToAction が stdin に書く）。
  private handleControl(control: ControlLine, child: ChildProcessWithoutNullStreams): void {
    const emit = this.emitFor(child);
    switch (control.kind) {
      case "canUseTool": {
        const request = control.request;
        const card = cardFor(request, this.agentId, this.sessionId);
        if (!card || !emit) {
          // 出せる質問が無い（AskUserQuestion の形が想定外）。待たせずに元の入力のまま通す。
          writeStdinLine(child, successResponse(request.requestId, { behavior: "allow", updatedInput: request.input }), this.runtime.kind);
          return;
        }
        this.pendingActions.set(request.requestId, { child, request });
        this.emitSessionStartedIfNeeded(emit);
        emit(card);
        return;
      }
      case "cancel":
        if (this.pendingActions.delete(control.requestId)) {
          emit?.({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: control.requestId });
        }
        return;
      case "unsupported":
        // 返事をしないと claude はその要求で待ち続ける。
        writeStdinLine(child, errorResponse(control.requestId, `unsupported control request: ${control.subtype}`), this.runtime.kind);
        return;
    }
  }

  /** 返事待ちを取り下げ、iPhone のカードを閉じさせる。child を指定したらそのプロセスの分だけ。
   *  turn を付けると「ターンが終わった・中断した」ときの閉じ方になる。行の停止を宣言済みの世代では、interrupt は背景のサブエージェントを
   *  止めないので、動いている行の承認は CLI が取り下げる（control_cancel_request）まで残す。deny を付けると、閉じる main の承認に
   *  拒否を書く（プロセスを残したとき、CLI のターンはまだ答えを待っている）。 */
  private resolvePendingActions(child?: ChildProcessWithoutNullStreams, turn?: { deny: boolean }): void {
    for (const [requestId, pending] of [...this.pendingActions]) {
      if (child && pending.child !== child) continue;
      const agentId = pending.request.agentId;
      if (turn && agentId !== undefined && this.stopCaps.get(pending.child)?.stopTask === true && this.subagents.stateOf(agentId) === "running") continue;
      this.pendingActions.delete(requestId);
      if (turn?.deny && agentId === undefined && this.liveChildren.has(pending.child)) {
        writeStdinLine(pending.child, successResponse(requestId, permissionResult(pending.request, "deny", {})), this.runtime.kind);
      }
      this.emit?.({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId });
    }
  }

  /// ルーターが閉じると決めたターンを畳む。各ターンの本文を store に残して send() の待機を解き、
  /// done は最後のターンの messageId で 1 回だけ出す（知らせのターンだけなら metadata.origin = "task-notification"）。
  /// 知らせのターンは終わった行を捨てない（pruneFinished は送信のときだけ）。
  private closeTurns(closure: TurnClosure, child: ChildProcessWithoutNullStreams): void {
    const ids = closure.notificationId !== undefined ? [...closure.messageIds, closure.notificationId] : closure.messageIds;
    const closed: Turn[] = [];
    for (const id of ids) {
      const index = this.turns.findIndex((t) => t.messageId === id && t.child === child);
      if (index >= 0) closed.push(...this.turns.splice(index, 1));
    }
    const hasText = closed.some((t) => t.assistant !== "");
    const doneId = closureDoneMessageId(closure);
    let doneTurn = closure.emitsDone ? (closed.find((t) => t.messageId === doneId) ?? closed.at(-1)) : undefined;
    // 本文の無い知らせのターンは silent の done で閉じる（開いたときの activity で生成中になっているので、閉じないと
    // 固着する。アプリは silent の done も普通の最終 done として扱い（完了音はバックグラウンドのエージェントが残っていなければ鳴る）、
    // 吹き出しだけ足さない。止めるのは Bridge の push だけ）。
    const silentDone = doneTurn?.notification === true && !hasText;
    if (doneTurn && !silentDone) this.lastFinishedMessageId = doneTurn.messageId;
    // ターンが普通に閉じたなら CLI は応答している。続いていない 2 回目の取りこぼしで背景の作業ごと止めない。
    if (doneTurn && !closure.interrupted) this.silentInterrupts.delete(child);
    // 止めると決めたターンを畳んだら、停止は済んだ（interrupt() はプロセスを止めない）。
    const pending = this.pendingInterrupt;
    if (doneTurn && pending && pending.child === child && closed.some((t) => pending.targets.has(t.messageId))) pending.settled = true;
    if (closed.length === 0) return;
    // 新規チャットの初回ターンを init 行（実 session_id）より前に止めたときは session_started を出さない。
    // 仮 ID（claude-<uuid>）で出すと iOS がチャットを仮 ID に固定し、次ターンで実 ID に替わっても
    // session_started は二度と出ない（開き直すと --resume されず文脈・履歴を失う）。done だけ返せば
    // iOS は pending のまま次の send で同じ session を使い、実 ID の session_started でキーを確定する。
    if (doneTurn && (!closure.interrupted || !this.sessionId.startsWith("claude-"))) this.emitSessionStartedIfNeeded(this.emitOf(doneTurn));
    // 保存失敗（Windows の rename EPERM/EBUSY 等）で done と resolve() が飛ばされるとターンが永久に終わらない。
    // メモリ上は追記済みなので次の save で永続化される。差し込みの前の発話の途中までの本文も残す。
    for (const turn of closed) {
      if (!turn.assistant.trim()) continue;
      try {
        this.store.appendMessage(this.agentId, this.sessionId, "assistant", turn.assistant, this.cwd, turn.messageId);
      } catch (error) {
        process.stderr.write(`[claude-code:${this.runtime.kind}] session store save failed: ${error instanceof Error ? error.message : String(error)}\n`);
      }
    }
    if (doneTurn) {
      const done = event.done(this.agentId, this.sessionId, doneTurn.messageId);
      // 知らせのターンの done（誰も頼んでいないターン。server はバックグラウンドの作業の完了として扱う）。
      const metadata: Record<string, string> = {};
      if (closureNotificationOnly(closure)) metadata.origin = "task-notification";
      if (silentDone) metadata.silent = "1";
      // 閉じた後も利用者の発話が未完了なら pending（アプリはこの done でターンを終わらせない）。中断済みの子プロセスのターンは
      // 二度と done を出さないので hasPendingTurn と同じく数えない。
      const promptPending = this.sendsInFlight > 0 || this.turns.some((t) => !t.notification && !this.interruptedChildren.has(t.child));
      if (promptPending) metadata.pending = "1";
      this.emitOf(doneTurn)?.(Object.keys(metadata).length > 0 ? { ...done, metadata } : done);
    }
    for (const turn of closed) turn.resolve?.();
  }

  /** このプロセスの残りのターンを全部畳む（プロセスが終わった）。done は最後のターンで 1 回。 */
  private closeRemainingTurns(child: ChildProcessWithoutNullStreams, interrupted: boolean): void {
    const remaining = this.turns.filter((t) => t.child === child);
    this.closeTurns(
      {
        messageIds: remaining.filter((t) => !t.notification).map((t) => t.messageId),
        notificationId: [...remaining].reverse().find((t) => t.notification)?.messageId,
        interrupted,
        emitsDone: true
      },
      child
    );
    // 知らせのターンが 2 つ残ることは無いが、残っていれば待機の無いまま捨てる。
    this.turns = this.turns.filter((t) => !(t.child === child && t.notification));
  }

  /// プロセス終了。止めたもの（interrupt・設定の変化・close）なら進行中のターンを done で畳み、異常終了ならエラーを返す。
  /// このプロセスのターンは全部畳んで send() の待機を解く（別のプロセス宛てのターンには触れない）。
  private handleExit(child: ChildProcessWithoutNullStreams, failure: string | undefined): void {
    this.liveChildren.delete(child);
    if (this.child === child) this.child = undefined;
    this.routers.delete(child);
    if (this.pendingInterrupt?.child === child) this.pendingInterrupt = undefined;
    for (const [id, c] of this.pendingInitialize) if (c === child) this.pendingInitialize.delete(id);
    // 待っている行・カードの停止は not_running で解く（行は下の終了処理が閉じる）。
    for (const [id, stop] of [...this.pendingStops]) {
      if (stop.child !== child) continue;
      this.pendingStops.delete(id);
      stop.resolve(undefined);
    }
    this.stopCaps.delete(child);
    this.silentInterrupts.delete(child);
    for (const [id, c] of this.keptInterruptIds) if (c === child) this.keptInterruptIds.delete(id);
    this.resolvePendingActions(child);
    const stoppedByUs = this.interruptedChildren.has(child) || this.closed;
    // プロセスと一緒にバックグラウンドのサブエージェント・コマンド・dynamic workflow も終わる。終わりの知らせ
    // （task_notification）はもう来ないので、実行中の行と終わっていない workflow を閉じる（閉じないとカードが
    // 「実行中」のまま残る）。自分で止めた・正常に終わったなら stopped、異常終了だけ failed。
    this.emitAbandoned(!stoppedByUs && failure !== undefined ? "failed" : "stopped");
    if (this.stopCaps.size === 0) this.subagents.setClaudeStopTask(false);
    if (stoppedByUs) {
      // ユーザーが停止した（か close した）。エラー扱いにせず、途中までの出力を確定して done。
      this.closeRemainingTurns(child, true);
      return;
    }
    // 起こしている間にワーカーが起きた（CLI が「running in the background (<id>)」と断った）。stderr はそのまま出さない。
    const taken = failure !== undefined ? BG_RUNNING.exec(failure)?.[1] : undefined;
    if (taken) {
      this.backgroundTaken = true;
      this.background?.refresh();
    }
    if (failure) {
      const shown = taken ? `この会話は PC のバックグラウンド（${taken}）でまた動き始めました。もう一度送ると、そちらに届けます。` : failure;
      for (const turn of this.turns.filter((t) => t.child === child)) {
        this.turns.splice(this.turns.indexOf(turn), 1);
        this.emitOf(turn)?.(event.error(this.agentId, this.sessionId, shown));
        turn.resolve?.();
      }
      return;
    }
    // 正常終了（stdin が閉じられた等）。残ったターンを畳む。
    this.closeRemainingTurns(child, false);
  }

  /** 実行中の行と終わっていない dynamic workflow を閉じる payload を流す（プロセスが終わった・close。終わりの知らせはもう来ない）。 */
  private emitAbandoned(state: string): void {
    const abandoned = this.subagents.abandonRunning({ state });
    if (abandoned) this.emit?.(event.workflowProgress(this.agentId, this.sessionId, abandoned));
    for (const payload of this.abandonWorkflows(state)) this.emit?.(event.workflowProgress(this.agentId, this.sessionId, payload));
  }

  private parseLine(object: Obj | undefined, line: string, sawTextDelta: boolean): { text?: string; sessionId?: string } {
    if (!object) return sawTextDelta ? {} : { text: `${line}\n` };
    const sessionId = typeof object.session_id === "string" ? object.session_id : undefined;
    // サブエージェント（Task / Explore 等）の行は parent_tool_use_id に親の tool_use id を持つ（メインの行は null）。
    // その本文を親ターンに混ぜない。
    const isSubagent = typeof object.parent_tool_use_id === "string";
    const delta = asObject(asObject(object.event).delta);
    if (!isSubagent && object.type === "stream_event" && delta.type === "text_delta" && typeof delta.text === "string") {
      return { text: delta.text, sessionId };
    }
    if (!sawTextDelta && typeof object.result === "string") {
      return { text: object.result, sessionId };
    }
    return { sessionId };
  }

  private emitSessionStartedIfNeeded(emit: Emit | undefined): void {
    if (this.didEmitSessionStarted || !emit) return;
    this.didEmitSessionStarted = true;
    emit(event.sessionStarted(this.agentId, this.sessionId));
  }

  /** 終わっていない dynamic workflow があるか。 */
  private get hasUnfinishedWorkflow(): boolean {
    return [...this.workflows.values()].some((w) => !w.finished);
  }

  /**
   * claude stream-json の dynamic workflow のライフサイクル行（system/task_*）を、クライアント向けの正規化 JSON へ
   * 変換する。workflow の行でなければ undefined（docs/BACKGROUND_WORK_2026-10-21.md §3.3。mac の workflowEventPayload と同じ）。
   * - workflow かどうかは行の印（task_type = local_workflow・workflow_name・workflow_progress）と、task_started で覚えた
   *   task_id（SubagentTracker.isWorkflowTask）で決める。task_notification は task_type も名前も持たないので id で見分け、
   *   summary の文字では決めない（サブエージェントやコマンドの結果に workflow という語が入ると取り違える）。
   * - 行の state は running / done / failed / stopped に、カードの status は running / completed / failed にそろえる
   *   （止まった workflow は failed に outcome: "stopped" を添える。古いアプリの spinner が止まるように）。
   * - workflow は覚えておき（終わったものは後の知らせに名前を載せるため、次の新しいターンまで）、終わっていないものは
   *   プロセスが終わったとき・close で閉じる（abandonWorkflows）。
   * テストからも呼ぶ。
   */
  workflowEventPayload(obj: Obj): string | undefined {
    if (obj.type !== "system" || typeof obj.subtype !== "string" || !WORKFLOW_SUBTYPES.has(obj.subtype)) return undefined;
    const subtype = obj.subtype;
    const taskId = asString(obj.task_id);
    if (!taskId) return undefined;
    const progress = objectArray(obj.workflow_progress);
    if (
      obj.task_type !== "local_workflow" &&
      typeof obj.workflow_name !== "string" &&
      progress === undefined &&
      !this.subagents.isWorkflowTask(taskId) &&
      !this.workflows.has(taskId)
    ) {
      return undefined;
    }
    // 終わり方: task_updated は patch.status（completed / failed / killed）、task_notification は status
    // （completed / failed / stopped）。task_started / task_progress は動いている。
    let final: string | undefined;
    if (subtype === "task_updated") {
      const status = asObject(obj.patch).status;
      // 状態も進み具合も無い更新（裏に回った印など）は出さない。
      if (typeof status !== "string" && progress === undefined) return undefined;
      final = typeof status === "string" ? finalState(status) : undefined;
    } else if (subtype === "task_notification") {
      final = finalState(typeof obj.status === "string" ? obj.status : "completed") ?? "done";
    }
    const card = this.workflows.get(taskId) ?? { agents: [], finished: false };
    if (subtype === "task_started") {
      card.finished = false;
    } else if (card.finished && final === undefined) {
      // 終わった後に遅れて届いた進み具合では、実行中に戻さない（やり直しは task_started で来る）。
      return undefined;
    }
    if (typeof obj.workflow_name === "string") card.name = obj.workflow_name;
    if (progress) {
      card.agents = workflowRows(progress);
      card.phases = workflowPhases(progress);
    }
    if (final !== undefined) card.finished = true;
    this.workflows.set(taskId, card);

    const out: Obj = { subtype, taskId };
    if (final === undefined) {
      out.status = "running";
    } else if (final === "done") {
      out.status = "completed";
    } else if (final === "stopped") {
      out.status = "failed";
      out.outcome = "stopped";
    } else {
      out.status = "failed";
    }
    if (card.name !== undefined) out.workflowName = card.name;
    for (const key of ["description", "summary"]) if (typeof obj[key] === "string") out[key] = obj[key];
    if (progress) {
      out.agents = card.agents;
      out.phases = card.phases;
    }
    out.stoppable = this.workflowStoppable(card);
    return JSON.stringify(out);
  }

  /** 終わっていない dynamic workflow を閉じる payload（プロセスが終わった・close）。CLI の終わりの知らせはもう来ない。
   *  動いていた行も同じ状態で閉じる。state は stopped（自分で止めた）か failed（異常終了）。 */
  private abandonWorkflows(state: string): string[] {
    const open = [...this.workflows].filter(([, card]) => !card.finished).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return open.map(([taskId, card]) => {
      card.finished = true;
      const out: Obj = { subtype: "task_notification", taskId, status: "failed", stoppable: false };
      if (state === "stopped") out.outcome = "stopped";
      if (card.name !== undefined) out.workflowName = card.name;
      if (card.agents.length > 0) out.agents = card.agents.map((row) => (row.state === "running" ? { ...row, state } : row));
      return JSON.stringify(out);
    });
  }
}

// Mac の String.prefix(80) と同じく、80 文字は書記素（grapheme cluster）で数える。
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/**
 * workflow_progress の phase の全リスト（type = workflow_phase の index と title だけ。待機中の見出し用）。
 * title は改行を空白に、前後の空白を除き、続く空白を 1 つにして 80 字で切る。空の title は捨て、同じ index は最初の 1 つ、index の昇順。
 */
export function workflowPhases(progress: Obj[]): Obj[] {
  const seen = new Set<number>();
  const phases: Obj[] = [];
  for (const a of progress) {
    if (a.type !== "workflow_phase" || typeof a.index !== "number" || !Number.isFinite(a.index) || typeof a.title !== "string") continue;
    const index = Math.trunc(a.index);
    const title = Array.from(graphemes.segment(a.title.replace(/[\r\n]+/g, " ").trim().replace(/\s+/g, " ")), (g) => g.segment).slice(0, 80).join("");
    if (title === "" || seen.has(index)) continue;
    seen.add(index);
    phases.push({ index, title });
  }
  return phases.sort((x, y) => (x.index as number) - (y.index as number));
}

const WORKFLOW_SUBTYPES: ReadonlySet<string> = new Set(["task_started", "task_progress", "task_updated", "task_notification"]);

/**
 * workflow_progress の要素を行にする。phase の見出し（type = workflow_phase）は行にしない。
 * state は running / done / failed / stopped にそろえ（CLI は start / progress / done / error）、失敗の理由（error）は
 * resultPreview に出す（アプリは失敗の行の 2 段目に resultPreview を出す）。
 */
export function workflowRows(progress: Obj[]): Obj[] {
  return progress.flatMap((a): Obj[] => {
    if (a.type === "workflow_phase" || a.type === "workflow_log") return [];
    const e: Obj = {};
    for (const k of ["index", "label", "phaseIndex", "phaseTitle", "agentType", "model", "tokens", "toolCalls", "durationMs", "resultPreview"]) {
      if (a[k] !== undefined && a[k] !== null) e[k] = a[k];
    }
    const state = workflowRowState(typeof a.state === "string" ? a.state : undefined);
    if (state !== undefined) e.state = state;
    if (state === "failed" && e.resultPreview === undefined && typeof a.error === "string" && a.error) e.resultPreview = a.error;
    if (typeof a.startedAt === "number" && Number.isFinite(a.startedAt)) e.startedAtMs = Math.trunc(a.startedAt);
    return [e];
  });
}

/**
 * dynamic workflow の行の状態をそろえる。start / progress / running → running、done / completed → done、
 * error / failed → failed、killed / stopped / cancelled → stopped。知らない語はそのまま。
 */
export function workflowRowState(raw: string | undefined): string | undefined {
  if (raw === undefined) return undefined;
  if (raw === "start" || raw === "progress" || raw === "running") return "running";
  return finalState(raw) ?? raw;
}

/** SessionStart などの hook の進み具合の行（type: system, subtype: hook_started / hook_response）。 */
function isHookLine(obj: Obj): boolean {
  return obj.type === "system" && typeof obj.subtype === "string" && obj.subtype.startsWith("hook_");
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

/** Claude が画像ブロックで受け付ける形式。それ以外（heic 等）は目印の文字だけ渡す。 */
const INLINE_IMAGE_MIMES = ["image/jpeg", "image/png", "image/gif", "image/webp"];

function normalizedImageMime(mime: string): string {
  const m = mime.toLowerCase();
  return m === "image/jpg" ? "image/jpeg" : m;
}

/**
 * 送信 1 通分の、履歴に残す本文（prompt）と stdin に流す content。
 * 画像は画像ブロック（base64）で渡す（目印の文字だけだと Claude は画像を見られない）。履歴の本文には
 * 目印を残し、履歴を開いたときに AttachmentStore から実画像へ戻す。画像ブロックで渡す分はモデル向けの本文に目印を入れない
 * （入れるとモデルが「ファイルが見つからない」と探しに行く）。
 */
export function userContent(
  text: string,
  originalEvent: SessionEvent,
  voice: VoiceTurn | undefined
): { prompt: string; content: string | Array<Record<string, unknown>> } {
  const userText = metadataText(originalEvent, text);
  const notes = attachmentTextNotes(originalEvent);
  const images = imageAttachments(originalEvent);
  const inline = images.filter((image) => INLINE_IMAGE_MIMES.includes(normalizedImageMime(image.mime)));
  const join = (head: string[]): string => (head.length > 0 ? `${head.join("\n\n")}\n\n${userText}` : userText);
  const prompt = join([...notes, ...images.map(imagePlaceholder)]);
  // 音声会話の応え方の指示も本文末尾の <voice-context> で渡す（起動引数・system prompt は変えない）。
  const modelText = withVoiceContext(join([...notes, ...images.filter((image) => !inline.includes(image)).map(imagePlaceholder)]), voice, true);
  return { prompt, content: inline.length > 0 ? claudeContentBlocks(modelText, inline) : modelText };
}

/** stream-json の user メッセージの content。画像ブロックを先に、本文を後に並べる（mac と同じ）。 */
export function claudeContentBlocks(text: string, images: ImageAttachment[]): Array<Record<string, unknown>> {
  return [
    ...images.map((image) => ({
      type: "image",
      source: { type: "base64", media_type: normalizedImageMime(image.mime), data: image.b64 }
    })),
    { type: "text", text }
  ];
}

/** stdin に 1 行書く。プロセスが既に無ければ false。 */
function writeStdinLine(child: ChildProcessWithoutNullStreams, message: Record<string, unknown>, kind: string): boolean {
  if (child.stdin.destroyed || child.stdin.writableEnded) return false;
  try {
    child.stdin.write(`${JSON.stringify(message)}\n`);
    return true;
  } catch (error) {
    process.stderr.write(`[claude-code:${kind}] stdin write failed: ${error instanceof Error ? error.message : String(error)}\n`);
    return false;
  }
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function asObject(value: unknown): Record<string, unknown> {
  return isPlainObject(value) ? value : {};
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** stdout の 1 行の JSON（オブジェクトでなければ undefined。壊れた行は本文として扱う）。 */
function parseObject(line: string): Record<string, unknown> | undefined {
  try {
    const value = JSON.parse(line) as unknown;
    return isPlainObject(value) ? value : undefined;
  } catch {
    return undefined;
  }
}

/** 要素が全部オブジェクトの配列（mac の as? [[String: Any]] と同じく、1 つでも違えば undefined）。 */
function objectArray(value: unknown): Array<Record<string, unknown>> | undefined {
  return Array.isArray(value) && value.every(isPlainObject) ? value : undefined;
}

interface PlanTask {
  id: string;
  subject: string;
  activeForm?: string;
  status: string;
}

/// consolidated `type:"assistant"` 行の tool_use からチェックリストを更新し、変化があれば
/// 全置換スナップショット JSON `{entries:[{content,status,activeForm?}]}` を返す（無変化は null）。
/// - TaskCreate {subject|content, activeForm?} → 作成順 1-indexed id で追加（status=pending）
/// - TaskUpdate {taskId|id, status}            → 該当 id の status を更新
/// - TodoWrite  {todos:[{content,status,activeForm}]} → 全置換（別 CLI 版向けの保険）
/// 部分ストリーム(stream_event)は type!=assistant なので拾わず二重計上しない。
function applyPlanFromLine(object: Record<string, unknown>, planTasks: PlanTask[]): string | null {
  if (object.type !== "assistant") return null;
  const message = asObject(object.message);
  const content = Array.isArray(message.content) ? message.content : null;
  if (!content) return null;
  // サブエージェント（Task / Explore 等）の行は parent_tool_use_id を持つ（メインは null）。TodoWrite はエージェントごとの
  // リストなので親のチェックリストに混ぜない。TaskCreate/TaskUpdate はセッション共有の連番を消費しうるため除外しない
  // （除外すると親の taskId と番号がずれる。mac と同じ）。
  const isSubagent = typeof object.parent_tool_use_id === "string";
  let changed = false;
  for (const block of content) {
    const b = asObject(block);
    if (b.type !== "tool_use") continue;
    const name = asString(b.name) ?? "";
    const input = asObject(b.input);
    switch (name) {
      case "TaskCreate": {
        const subject = asString(input.subject) ?? asString(input.content);
        if (!subject) continue;
        planTasks.push({ id: String(planTasks.length + 1), subject, activeForm: asString(input.activeForm), status: "pending" });
        changed = true;
        break;
      }
      case "TaskUpdate": {
        const taskId = asString(input.taskId) ?? asString(input.id);
        const status = asString(input.status);
        if (!taskId || !status) continue;
        const idx = planTasks.findIndex((t) => t.id === taskId);
        if (idx < 0) continue;
        planTasks[idx].status = status;
        changed = true;
        break;
      }
      case "TodoWrite": {
        const todos = Array.isArray(input.todos) ? input.todos : null;
        if (isSubagent || !todos) continue;
        planTasks.length = 0;
        todos.forEach((td, i) => {
          const t = asObject(td);
          const c = asString(t.content);
          if (!c) return;
          planTasks.push({ id: String(i + 1), subject: c, activeForm: asString(t.activeForm), status: asString(t.status) ?? "pending" });
        });
        changed = true;
        break;
      }
      default:
        continue;
    }
  }
  if (!changed || planTasks.length === 0) return null;
  const entries = planTasks.map((t) => {
    const e: Record<string, string> = { content: t.subject, status: t.status };
    if (t.activeForm) e.activeForm = t.activeForm;
    return e;
  });
  return JSON.stringify({ entries });
}

/// ~/.claude/skills/<name>/SKILL.md と、インストール済みプラグインの skills/<name>/SKILL.md を集める。
/// プラグインの id は "<plugin>:<name>"。同じ id はユーザーのスキルを優先する。
export function scanClaudeSkills(home: string): Array<{ id: string; kind: string; title: string; subtitle?: string }> {
  const out = new Map<string, { id: string; kind: string; title: string; subtitle?: string }>();
  const describe = (dir: string): string | undefined => {
    try {
      const text = fs.readFileSync(path.join(dir, "SKILL.md"), "utf8");
      const lines = text.split(/\r?\n/);
      if (lines[0]?.trim() !== "---") return undefined;
      for (const line of lines.slice(1)) {
        const t = line.trim();
        if (t === "---") break;
        if (t.toLowerCase().startsWith("description:")) return t.slice("description:".length).trim().replace(/^(["'])(.*)\1$/, "$2");
      }
    } catch {
      /* 説明なし */
    }
    return undefined;
  };
  const collect = (root: string, prefix: string): void => {
    let names: string[];
    try {
      names = fs.readdirSync(root);
    } catch {
      return;
    }
    for (const name of names) {
      const dir = path.join(root, name);
      if (name.startsWith(".") || !fs.existsSync(path.join(dir, "SKILL.md"))) continue;
      const id = `${prefix}${name}`;
      if (!out.has(id)) out.set(id, { id, kind: "skill", title: id, subtitle: describe(dir) });
    }
  };
  collect(path.join(home, ".claude", "skills"), "");
  try {
    const installed = JSON.parse(fs.readFileSync(path.join(home, ".claude", "plugins", "installed_plugins.json"), "utf8")) as {
      plugins?: Record<string, unknown>;
    };
    for (const [key, value] of Object.entries(installed.plugins ?? {})) {
      const plugin = key.split("@")[0];
      const entries = Array.isArray(value) ? (value as Array<Record<string, unknown>>) : [value as Record<string, unknown>];
      const entry = entries.find((e) => e?.scope === "user") ?? entries[0];
      const installPath = typeof entry?.installPath === "string" ? entry.installPath : undefined;
      if (installPath) collect(path.join(installPath, "skills"), `${plugin}:`);
    }
  } catch {
    /* プラグイン無し */
  }
  return [...out.values()].sort((a, b) => a.title.localeCompare(b.title, undefined, { sensitivity: "base" }));
}
