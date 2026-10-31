import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { mcpTokenEnv } from "../mcpService.js";
import { event, type SessionEvent } from "../protocol.js";
import { JsonRpcProcess } from "../runtime/jsonRpcProcess.js";
import { JsonRpcWebSocket } from "../runtime/jsonRpcWebSocket.js";
import { normalizeRuntimeCwd, toWslPath, type RuntimeCommand } from "../runtime/command.js";
import { isInjectedUserContext, stripImageTags } from "./codexHistory.js";
import { codexTerminals, type CodexSharedEndpoint } from "./codexShared.js";
import { attachmentTextNotes, metadataText, type AgentSession, type Emit, type SessionOverrides, type StopTaskOutcome, type StopTaskRequest } from "./types.js";
import { SubagentTracker } from "./subagentTracker.js";

/// `codex app-server`（stdio の JSON-RPC）で 1 つの thread を動かすセッション（mac の CodexAppServerSession の移植）。
/// `codex exec` と違い、コマンド実行・ファイル変更などの承認を iPhone に出して答えを返せる。
/// 子プロセスはセッションごとに 1 本。死んだら次の送信で起動し直して thread/resume する。
/// 共有の app-server（CodexSharedAppServer）があればそこへ WebSocket で繋ぎ、ターミナル（buddy-codex）の
/// ターンも同じ thread の通知として流す（remoteTurnIds）。

type RpcClient = JsonRpcProcess | JsonRpcWebSocket;

export interface CodexTurnConfig {
  model?: string;
  effort?: string;
  approvalPolicy: string;
  sandboxMode: string;
  /** "plan" なら collaborationMode を plan にする。 */
  mode?: string;
}

const REQUEST_TIMEOUT_MS = 90_000;
/** 停止・中断の要求の待ち時間と、停止の後に行が閉じるのを待つ時間（BACKGROUND_CONTROL §3.5・§4.4）。テストが短くする。 */
export const codexStopTiming = { requestMs: 5_000, closeMs: 5_000 };
const SUMMARY_LIMIT = 1200;
const DIFF_LIMIT = 40_000;

type PendingKind = "approval" | "legacyApproval" | "elicitation" | "userInput";

interface PendingRequest {
  id: number | string;
  kind: PendingKind;
  questionIds: string[];
}

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" && v.length > 0 ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);

export function sandboxPolicy(mode: string): Record<string, unknown> {
  switch (mode) {
    case "read-only":
      return { type: "readOnly", networkAccess: false };
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    default:
      return { type: "workspaceWrite", writableRoots: [], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false };
  }
}

const APPROVAL_OPTIONS: Record<string, string> = {
  option_count: "3",
  option_0_title: "承認",
  option_0_subtitle: "一度だけ許可",
  option_0_value: "accept",
  option_1_title: "このセッションでは承認",
  option_1_subtitle: "同種の操作を続けて許可",
  option_1_value: "acceptForSession",
  option_2_title: "非承認",
  option_2_subtitle: "実行しない",
  option_2_value: "decline",
  allowsOther: "0"
};

/** iOS の answers_json（{質問 id: "答え" | ["答え", ...]}）を app-server の answers に直す。 */
export function userInputAnswers(questionIds: string[], decision: string, answersJson: string | undefined): Record<string, unknown> {
  let parsed: Record<string, unknown> = {};
  try {
    parsed = obj(answersJson ? JSON.parse(answersJson) : {});
  } catch {
    /* 決定だけ使う */
  }
  const answers: Record<string, unknown> = {};
  questionIds.forEach((qid, i) => {
    const raw = parsed[qid];
    const picked = Array.isArray(raw) ? raw.map(String) : typeof raw === "string" ? [raw] : i === 0 && decision ? [decision] : [];
    answers[qid] = { answers: picked };
  });
  if (questionIds.length === 0) answers.answer = { answers: decision ? [decision] : [] };
  return { answers };
}

/**
 * コマンドの承認カードの本文。実際に動くコマンドと作業フォルダを必ず先に出し、モデルの理由文は後ろに補足として添える
 * （理由文だけを見せると、無害に見える理由と危険なコマンドの組み合わせを中身を見ないまま承認してしまう）。
 */
export function commandApprovalSubtitle(params: Record<string, unknown>): string {
  const command = Array.isArray(params.command) ? params.command.map(String).join(" ") : str(params.command);
  const cwd = str(params.cwd);
  const reason = str(params.reason);
  return [command ?? "（コマンドが届いていません）", cwd ? `フォルダ: ${cwd}` : undefined, reason ? `理由: ${reason}` : undefined]
    .filter(Boolean)
    .join("\n");
}

/** ファイル変更の承認カードの本文。書き込みを許す範囲（grantRoot）を先に出し、理由文は補足にする。 */
export function fileApprovalSubtitle(params: Record<string, unknown>): string | undefined {
  const root = str(params.grantRoot);
  const reason = str(params.reason);
  const lines = [root ? `書き込む範囲: ${root}` : undefined, reason ? `理由: ${reason}` : undefined].filter(Boolean);
  return lines.length > 0 ? lines.join("\n") : undefined;
}

/** action_response の答え → JSON-RPC の result（mac の respondToAction と同じ）。 */
export function approvalResult(kind: PendingKind, decision: string): Record<string, unknown> {
  if (kind === "legacyApproval") {
    const map: Record<string, string> = { accept: "approved", acceptForSession: "approved_for_session", decline: "denied" };
    return { decision: map[decision] ?? "denied" };
  }
  if (kind === "elicitation") {
    if (decision === "accept") return { action: "accept", content: {}, _meta: null };
    if (decision === "acceptForSession") return { action: "accept", content: {}, _meta: { persist: "session" } };
    return { action: "decline", content: null, _meta: null };
  }
  return { decision };
}

function fileChangeSummary(item: Record<string, unknown>): { title: string; diff?: string } {
  const changes = Array.isArray(item.changes) ? item.changes.map(obj) : [];
  const names = changes.map((c) => path.basename(String(c.path ?? ""))).filter(Boolean);
  const title = names.length === 0 ? "ファイル変更" : names.length <= 2 ? `ファイル変更: ${names.join(", ")}` : `ファイル変更: ${names.slice(0, 2).join(", ")} ほか ${names.length - 2} 件`;
  let budget = DIFF_LIMIT;
  const diffs = changes.map((c) => {
    const kindRaw = c.kind;
    const kind = typeof kindRaw === "string" ? kindRaw : str(obj(kindRaw).type) ?? "update";
    const full = typeof c.diff === "string" ? c.diff : "";
    const diff = full.slice(0, Math.max(0, budget));
    budget -= diff.length;
    return { path: String(c.path ?? ""), kind, diff, truncated: diff.length < full.length };
  });
  return { title, diff: diffs.length > 0 ? JSON.stringify(diffs) : undefined };
}

export class CodexAppServerSession implements AgentSession {
  public sessionId: string;
  /** 生成中に届いた送信は turn/steer で実行中の自分のターンへ足す（新しいターンを始めない。mac と同じ）。 */
  readonly supportsMidTurnInjection = true;
  private client?: RpcClient;
  private starting?: Promise<RpcClient>;
  /** 今の接続が共有の app-server か。 */
  private onShared = false;
  /** ターミナル側（他の接続）が始めたターン。done は流すが、send() の完了には数えない。 */
  private readonly remoteTurnIds = new Set<string>();
  /** iPhone から一度でも送ったか。先行購読だけの接続が切れても、エラーは出さずに静かに畳む。 */
  private didSend = false;
  private watching?: Promise<void>;
  /** この子プロセスで thread を開いたか（start / resume 済み）。 */
  private threadReady = false;
  private didEmitSessionStarted: boolean;
  private emit?: Emit;
  private activeTurnId?: string;
  private localTurnPending = false;
  private readonly localTurnIds = new Set<string>();
  private readonly lastMessageByTurn = new Map<string, string>();
  private readonly deltaItems = new Set<string>();
  private readonly erroredTurns = new Set<string>();
  private readonly pending = new Map<string, PendingRequest>();
  private turnDone?: () => void;
  /** 実行中の send() の区間（turn/start から完了まで）。終わると解ける。 */
  private running?: Promise<void>;
  private localMessageId = "";
  private closed = false;
  /**
   * サブエージェント（子 thread。キーは子 thread id）とバックグラウンドの端末（キーは commandExecution の item id）。
   * セッションに 1 つ持つ（ターンごとに作らない）。stdio の app-server はターンでは止めないので、行が動いている間も残る。
   */
  private readonly work = new CodexBackgroundWork();
  /**
   * 自分が始めていないターンのうち、発話（ターミナルの発話か、そこへ steer した自分の発話）があったもの。
   * 発話の無いターンは、子の完了などで親が自分から起きた知らせのターンとして、done に origin を付ける。
   */
  private readonly turnsWithUtterance = new Set<string>();
  /** 自分の turn/start が steer になった、自分が始めていないターン。その終わりで send() の待ちを解く。 */
  private steeredInto?: string;
  /** turn/steer で足した画像の一時フォルダ。足した先のターンが終わったら消す。 */
  private steerTmpDirs: string[] = [];
  /** このチャットだけのモデル / Effort / モード。turn/start の引数にだけ使い、config.toml には書かない。 */
  private overrides: SessionOverrides = {};
  /** もう turn/interrupt を送った turn id（親も子も）。同じ turn id に 2 回送ると 2 回目は返事が来ない。 */
  private readonly interruptedTurnIds = new Set<string>();
  /** 子の turn/interrupt が時間切れだった turn id（届いたかどうか分からない。同じ turn id には送り直さない）。 */
  private readonly timedOutChildTurnIds = new Set<string>();
  /** 同じ行への停止の実行中（同時に押されたら、最初の結果を返す）。 */
  private readonly stopRuns = new Map<string, Promise<StopTaskOutcome>>();

  constructor(
    private readonly agentId: string,
    initialSessionId: string | undefined,
    private readonly cwd: string | undefined,
    private readonly runtime: RuntimeCommand,
    /** そのターンの設定。チャットの上書きを config.toml の既定に重ねて返す。 */
    private readonly turnConfig: (overrides: SessionOverrides) => Promise<CodexTurnConfig>,
    /** 共有の app-server の接続先（無ければ・起動できなければ stdio の子プロセス）。 */
    private readonly shared?: () => Promise<CodexSharedEndpoint | undefined>,
    /** thread/start・resume の config（-c と同じ点区切りのキー）。mainagent の MCP を渡すときに使う（合鍵を引数に載せない）。 */
    private readonly threadConfig?: () => Record<string, unknown>,
    /** 閉じたときに呼ぶ（mainagent の合鍵を無効にする）。 */
    private readonly onClose?: () => void
  ) {
    this.sessionId = initialSessionId ?? `pending-${crypto.randomUUID().slice(0, 8)}`;
    this.didEmitSessionStarted = Boolean(initialSessionId);
  }

  private get hasThread(): boolean {
    return !this.sessionId.startsWith("pending-");
  }

  private runtimeCwd(): string | undefined {
    return normalizeRuntimeCwd(this.runtime, this.cwd);
  }

  async send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    this.emit = emit;
    this.didSend = true;
    // 自分のターンが走っていれば、止めずにそのターンへ足す。完了（done）は元のターンの 1 回だけ出る。
    // 間に合わなかった（直前に終わった等）ときは、新しいターンとして始める。
    if (this.canSteer() && (await this.steer(text, originalEvent))) return;
    // 足せなかったのに前のターンがまだ走っていれば、終わってから始める（並べて turn/start すると turnDone を上書きし、前の send が終わらなくなる）。
    while (this.running) await this.running;
    let endRunning!: () => void;
    const running = new Promise<void>((resolve) => (endRunning = resolve));
    this.running = running;
    this.localMessageId = crypto.randomUUID();
    const finished = new Promise<void>((resolve) => (this.turnDone = resolve));
    const tmpDir = path.join(os.tmpdir(), `buddyos-codex-${crypto.randomUUID()}`);
    try {
      const client = await this.ensureClient();
      const config = await this.turnConfig(this.overrides);
      await this.ensureThread(client, config);
      const input = this.buildInput(text, originalEvent, tmpDir);
      const cwd = this.runtimeCwd();
      const params: Record<string, unknown> = {
        threadId: this.sessionId,
        input,
        approvalPolicy: config.approvalPolicy,
        sandboxPolicy: sandboxPolicy(config.sandboxMode),
        clientUserMessageId: this.localMessageId,
        collaborationMode: {
          mode: config.mode === "plan" ? "plan" : "default",
          settings: { model: config.model ?? null, reasoning_effort: config.effort ?? null, developer_instructions: null }
        }
      };
      if (config.model) params.model = config.model;
      if (config.effort) params.effort = config.effort;
      if (cwd) {
        params.cwd = cwd;
        params.runtimeWorkspaceRoots = [cwd];
      }
      this.localTurnPending = true;
      // 新しいターン。終わった行を忘れる（アプリも送信で終わった行を捨てる）。動いているものは残す。
      this.work.pruneFinished();
      const res = await client.request("turn/start", params, REQUEST_TIMEOUT_MS);
      this.localTurnPending = false;
      if (res.error) throw new Error(str(obj(res.error).message) ?? "turn/start failed");
      const turnId = str(obj(obj(res.result).turn).id);
      if (turnId) this.noteLocalTurn(turnId);
      await finished;
    } catch (error) {
      this.localTurnPending = false;
      if (!this.closed) {
        emit(event.error(this.agentId, this.sessionId, error instanceof Error ? error.message : String(error)));
        emit(event.done(this.agentId, this.sessionId, this.localMessageId));
      }
    } finally {
      this.turnDone = undefined;
      for (const dir of [tmpDir, ...this.steerTmpDirs.splice(0)]) fs.rmSync(dir, { recursive: true, force: true });
      if (this.running === running) this.running = undefined;
      endRunning();
    }
  }

  /// 生成中のフォローアップ。実行中の自分のターンへ turn/steer で足す。足せなければ（直前に終わった等）新しいターンとして送る。
  /// 実行中の自分のターンが無ければ false（server が予約・新しいターンとして扱う）。
  inject(text: string, originalEvent: SessionEvent, emit: Emit): boolean {
    if (!this.canSteer()) return false;
    this.emit = emit;
    void this.steer(text, originalEvent).then((ok) => {
      if (!ok && !this.closed) void this.send(text, originalEvent, emit);
    });
    return true;
  }

  applyOverrides(overrides: SessionOverrides): void {
    this.overrides = { ...overrides };
  }

  /**
   * turn/start の応答。自分が始めていないターン（ターミナル側・知らせのターン）が進行中なら、この turn/start はそのターンへの
   * steer になっている（新しいターンは始まらず turn/started も来ない。mac と同じ判定）。その送信はそのターンの終わりで畳み、
   * 発話のあるターンなので知らせのターンにもしない。停止の宛先は上書きしない。
   */
  private noteLocalTurn(turnId: string): void {
    const active = this.activeTurnId;
    const into = this.remoteTurnIds.has(turnId) ? turnId : active && active !== turnId && this.remoteTurnIds.has(active) ? active : undefined;
    if (into) {
      this.turnsWithUtterance.add(into);
      this.steeredInto = into;
      return;
    }
    this.localTurnIds.add(turnId);
    this.activeTurnId ??= turnId;
  }

  /** 自分が始めたターンが実行中で、その完了を send() が待っているか（turn/steer の宛先がある）。 */
  private canSteer(): boolean {
    const turnId = this.activeTurnId;
    return Boolean(this.client?.alive && this.threadReady && this.turnDone && turnId && this.localTurnIds.has(turnId));
  }

  private async steer(text: string, originalEvent: SessionEvent): Promise<boolean> {
    const client = this.client;
    const turnId = this.activeTurnId;
    if (!client?.alive || !turnId) return false;
    const tmpDir = path.join(os.tmpdir(), `buddyos-codex-${crypto.randomUUID()}`);
    this.steerTmpDirs.push(tmpDir);
    let input: Array<Record<string, unknown>>;
    try {
      input = this.buildInput(text, originalEvent, tmpDir);
    } catch (error) {
      // 画像を書き出せない等。足さずに新しいターンとして送る（エラーはそちらで返す）。
      process.stderr.write(`[codex-app-server] turn/steer input failed: ${error instanceof Error ? error.message : String(error)}\n`);
      return false;
    }
    const res = await client
      .request("turn/steer", { threadId: this.sessionId, expectedTurnId: turnId, input, clientUserMessageId: crypto.randomUUID() }, REQUEST_TIMEOUT_MS)
      .catch(() => undefined);
    if (res && !res.error) return true;
    process.stderr.write(`[codex-app-server] turn/steer fell back to turn/start: ${res?.error ? JSON.stringify(res.error) : "no response"}\n`);
    return false;
  }

  async interrupt(): Promise<void> {
    const client = this.client;
    if (!client?.alive || !this.activeTurnId || !this.hasThread) return;
    // 子プロセスは止めない。app-server が turn/completed(interrupted) を返し、そこで done になる。
    // 同じ turn id に 2 回送らない（2 回目は返事が来ない）。
    const turnId = this.activeTurnId;
    if (this.interruptedTurnIds.has(turnId)) return;
    this.interruptedTurnIds.add(turnId);
    const res = await client.request("turn/interrupt", { threadId: this.sessionId, turnId }, codexStopTiming.requestMs).catch(() => undefined);
    // 断られたなら止まっていない。押し直せるように戻す。
    if (res?.error) this.interruptedTurnIds.delete(turnId);
  }

  /// 背景の作業を 1 つ止める（stop_task_request）。shell 行は端末の terminate、agent 行は子の turn/interrupt。
  /// 親のターンには触らない。同じ行への停止がもう出ていれば、その結果を待つ。
  async stopTask(req: StopTaskRequest): Promise<StopTaskOutcome> {
    const tracker = this.work.tracker;
    if (req.taskId !== SubagentTracker.taskId) return { kind: "unsupported" };
    if (!req.rowId || req.epoch !== tracker.epoch) return { kind: "stale" };
    const rowId = req.rowId;
    const running = this.stopRuns.get(rowId);
    if (running) return running;
    const run = this.stopRow(rowId);
    this.stopRuns.set(rowId, run);
    try {
      return await run;
    } finally {
      if (this.stopRuns.get(rowId) === run) this.stopRuns.delete(rowId);
    }
  }

  private async stopRow(rowId: string): Promise<StopTaskOutcome> {
    const tracker = this.work.tracker;
    const begin = tracker.beginStop(rowId);
    if (begin.kind === "notRunning") return tracker.has(rowId) ? { kind: "notRunning" } : { kind: "stale" };
    if (begin.kind === "inFlight") return this.stopRuns.get(rowId) ?? { kind: "notRunning" };
    if (begin.kind !== "ok") return { kind: "unsupported" };
    const client = this.client;
    if (!client?.alive || !this.hasThread) {
      this.emitSubagent(tracker.endStop(rowId));
      return { kind: "notRunning" };
    }
    this.emitSubagent(begin.payload);
    return begin.rowKind === "shell" ? this.stopTerminal(client, rowId) : this.stopChild(client, rowId);
  }

  /** 返事の error の文。返事が来なかった（時間切れ・接続が切れた）ときは timeout を返す。 */
  private static rpcFailure(res: Record<string, unknown> | undefined, thrown: unknown): { message: string; timeout: boolean } {
    if (res === undefined) {
      const message = thrown instanceof Error ? thrown.message : String(thrown ?? "");
      return { message, timeout: message.includes("timed out") };
    }
    return { message: str(obj(res.error).message) ?? "", timeout: false };
  }

  private async stopTerminal(client: RpcClient, rowId: string): Promise<StopTaskOutcome> {
    const work = this.work;
    const tracker = work.tracker;
    const processId = work.processIdOf(rowId);
    if (processId === undefined || !work.terminalStopSupported) {
      this.emitSubagent(tracker.setStopHandle(rowId, false));
      this.emitSubagent(tracker.endStop(rowId));
      return { kind: "unsupported" };
    }
    let thrown: unknown;
    const res = await client
      .request("thread/backgroundTerminals/terminate", { threadId: this.sessionId, processId }, codexStopTiming.requestMs)
      .catch((error: unknown) => {
        thrown = error;
        return undefined;
      });
    if (res === undefined || res.error) {
      const failure = CodexAppServerSession.rpcFailure(res, thrown);
      if (/requires experimentalApi capability|unknown variant/.test(failure.message)) {
        this.emitSubagents(work.disableTerminalStop());
        this.emitSubagent(tracker.endStop(rowId));
        return { kind: "unsupported" };
      }
      this.emitSubagent(tracker.endStop(rowId));
      return failure.timeout ? { kind: "timeout" } : { kind: "failed", message: failure.message.slice(0, 200) || undefined };
    }
    const terminated = obj(res.result).terminated === true;
    if (terminated) {
      work.markStoppedExec(rowId);
      if (tracker.isRunning(rowId)) this.emitSubagent(tracker.finish(rowId, "stopped"));
      return { kind: tracker.stateOf(rowId) === "stopped" ? "stopped" : "notRunning" };
    }
    // もういない。行がまだ running なら、止まったものとして閉じる（先に done になった行は書き換えない）。
    if (tracker.isRunning(rowId)) this.emitSubagent(tracker.finish(rowId, "stopped"));
    return { kind: "notRunning" };
  }

  private async stopChild(client: RpcClient, rowId: string): Promise<StopTaskOutcome> {
    const work = this.work;
    const tracker = work.tracker;
    const turnId = work.childTurns.get(rowId);
    if (!turnId) {
      this.emitSubagent(tracker.setStopHandle(rowId, false));
      this.emitSubagent(tracker.endStop(rowId));
      return { kind: "unsupported" };
    }
    // 同じ turn id にはもう送っている（親の interrupt と同じ集合）。返事を待たず、行が閉じるのだけを待つ。
    const alreadySent = this.interruptedTurnIds.has(turnId);
    this.interruptedTurnIds.add(turnId);
    if (!alreadySent) {
      let thrown: unknown;
      const res = await client
        .request("turn/interrupt", { threadId: rowId, turnId }, codexStopTiming.requestMs)
        .catch((error: unknown) => {
          thrown = error;
          return undefined;
        });
      if (res === undefined || res.error) {
        const failure = CodexAppServerSession.rpcFailure(res, thrown);
        if (failure.timeout) {
          // 時間切れは送信済みの印を残す（同じ turn id に 2 回送らない。2 回目は返事が来ない）。次に押したら行が閉じるのを待つだけにし、
          // 閉じなければ stopped にせず timeout を返す（子はまだ動いているかもしれない）。
          this.timedOutChildTurnIds.add(turnId);
          this.emitSubagent(tracker.endStop(rowId));
          return { kind: "timeout" };
        }
        this.interruptedTurnIds.delete(turnId);
        // 先に終わった（競合）。手がかりも落とす。
        if (/no active turn to interrupt|expected active turn id|thread not found/.test(failure.message)) {
          work.childTurns.delete(rowId);
          this.emitSubagent(tracker.setStopHandle(rowId, false));
          this.emitSubagent(tracker.endStop(rowId));
          return { kind: "notRunning" };
        }
        this.emitSubagent(tracker.endStop(rowId));
        return { kind: "failed", message: failure.message.slice(0, 200) || undefined };
      }
    }
    // 子の turn/completed(interrupted) が行を stopped にする。来なければ自分で閉じる。
    await untilTrue(() => !tracker.isRunning(rowId), codexStopTiming.closeMs);
    if (tracker.isRunning(rowId)) {
      // 前の送信が時間切れだったままなら、止まったか分からない。stopped にせず、押し直せる状態に戻す。
      if (this.timedOutChildTurnIds.has(turnId)) {
        this.emitSubagent(tracker.endStop(rowId));
        return { kind: "timeout" };
      }
      this.emitSubagent(tracker.finish(rowId, "stopped"));
    }
    this.timedOutChildTurnIds.delete(turnId);
    // 子の端末は子を止めても残る。結果は見ない。
    if (work.terminalStopSupported && client.alive) {
      void client.request("thread/backgroundTerminals/clean", { threadId: rowId }, codexStopTiming.requestMs).catch(() => undefined);
    }
    return { kind: tracker.stateOf(rowId) === "stopped" ? "stopped" : "notRunning" };
  }

  async respondToAction(requestId: string, decision: string, answers: Record<string, string>): Promise<void> {
    const pending = this.pending.get(requestId);
    if (!pending || !this.client?.alive) return;
    this.pending.delete(requestId);
    const result = pending.kind === "userInput" ? userInputAnswers(pending.questionIds, decision, answers.answers_json) : approvalResult(pending.kind, decision);
    this.client.respond(pending.id, result);
    this.emit?.({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId });
  }

  async close(): Promise<void> {
    this.closed = true;
    this.client?.close();
    this.client = undefined;
    // もう子の thread も裏の端末も追えない（stdio はプロセスごと止まる）。実行中の行は止めたものとして閉じる。
    this.emitSubagent(this.work.abandonRunning("stopped"));
    this.turnDone?.();
    this.onClose?.();
  }

  /**
   * サブエージェントのカードの全行（workflow_progress の JSON。subtype "workflow_snapshot"、kind "subagents"、epoch 付き）。
   * 接続したときと turn_status_request のときに server が送る。行が無くても agents: [] で返す（§3.5）。
   */
  subagentSnapshot(): string | undefined {
    return this.work.tracker.snapshot({ includeEmpty: true });
  }

  /**
   * ターミナル（buddy-codex）で開いている thread を、iPhone から送る前から購読する（ターミナル側のターンを流す）。
   * 見るだけなので thread/resume は threadId と excludeTurns だけ（ターミナル側の設定を上書きしない）。
   * rollout がまだ無い thread（開いた直後）は購読できないので、開いている間は 3 秒おきに試し直す。
   */
  watch(emit: Emit): Promise<void> {
    if (!this.shared || !this.hasThread || this.closed) return Promise.resolve();
    this.emit ??= emit;
    this.watching ??= (async () => {
      await new Promise((r) => setTimeout(r, 500));
      while (!this.closed && !this.threadReady && codexTerminals.isLive(this.sessionId)) {
        try {
          const client = await this.ensureClient();
          if (!this.onShared) return;
          if (this.threadReady) return;
          const res = await client.request("thread/resume", { threadId: this.sessionId, excludeTurns: true }, REQUEST_TIMEOUT_MS);
          if (!res.error) {
            this.threadReady = true;
            return;
          }
          const message = str(obj(res.error).message) ?? "";
          if (!message.includes("no rollout found")) return;
        } catch (error) {
          process.stderr.write(`[codex-app-server] early subscribe failed: ${error instanceof Error ? error.message : String(error)}\n`);
          return;
        }
        await new Promise((r) => setTimeout(r, 3000));
      }
    })().finally(() => {
      this.watching = undefined;
    });
    return this.watching;
  }

  private ensureClient(): Promise<RpcClient> {
    if (this.client?.alive) return Promise.resolve(this.client);
    if (this.starting) return this.starting;
    this.starting = (async () => {
      const endpoint = this.shared ? await this.shared().catch(() => undefined) : undefined;
      let client: RpcClient | undefined;
      if (endpoint) {
        try {
          client = await JsonRpcWebSocket.connect(endpoint.url, endpoint.token);
        } catch (error) {
          process.stderr.write(`[codex-app-server] shared connect failed, falling back to stdio: ${error instanceof Error ? error.message : String(error)}\n`);
        }
      }
      this.onShared = Boolean(client);
      // OAuth で足した MCP のトークンは bearer_token_env_var が指す環境変数で渡す（mac の McpTokenVault と同じ）。
      client ??= new JsonRpcProcess(this.runtime, ["app-server"], this.runtimeCwdForSpawn(), mcpTokenEnv(), { jsonrpcField: false });
      client.on("stderr", (chunk: string) => process.stderr.write(`[codex-app-server] ${chunk}`));
      client.on("notification", (m: Record<string, unknown>) => this.handleNotification(m));
      client.on("request", (m: Record<string, unknown>) => this.handleServerRequest(client, m));
      client.on("close", () => this.handleExit(client));
      const init = await client.request(
        "initialize",
        { clientInfo: { name: "buddyos", title: "BuddyOS", version: "0.1.0" }, capabilities: { experimentalApi: true, requestAttestation: false } },
        REQUEST_TIMEOUT_MS
      );
      if (init.error) throw new Error(str(obj(init.error).message) ?? "initialize failed");
      client.notify("initialized", {});
      this.client = client;
      this.threadReady = false;
      return client;
    })().finally(() => {
      this.starting = undefined;
    });
    return this.starting;
  }

  /** 子プロセスの cwd（Windows 側のフォルダ。WSL は spawnRuntime が変換する）。 */
  private runtimeCwdForSpawn(): string | undefined {
    return this.cwd;
  }

  private async ensureThread(client: RpcClient, config: CodexTurnConfig): Promise<void> {
    if (this.threadReady) return;
    const cwd = this.runtimeCwd();
    const params: Record<string, unknown> = {
      approvalPolicy: config.approvalPolicy,
      sandbox: config.sandboxMode,
      persistExtendedHistory: false,
      experimentalRawEvents: false
    };
    if (cwd) {
      params.cwd = cwd;
      params.runtimeWorkspaceRoots = [cwd];
    }
    if (config.model) params.model = config.model;
    const extra = this.threadConfig?.();
    if (extra) params.config = extra;
    const resuming = this.hasThread;
    if (resuming) {
      params.threadId = this.sessionId;
      params.excludeTurns = true;
    } else {
      params.sessionStartSource = "startup";
      params.threadSource = "user";
    }
    const res = await client.request(resuming ? "thread/resume" : "thread/start", params, REQUEST_TIMEOUT_MS);
    if (res.error) throw new Error(str(obj(res.error).message) ?? "thread start failed");
    const thread = obj(obj(res.result).thread);
    const id = str(thread.id) ?? str(thread.sessionId);
    if (id && id !== this.sessionId) this.sessionId = id;
    this.threadReady = true;
    this.emitSessionStarted();
  }

  private emitSessionStarted(): void {
    if (this.didEmitSessionStarted || !this.hasThread) return;
    this.didEmitSessionStarted = true;
    this.emit?.(event.sessionStarted(this.agentId, this.sessionId));
  }

  private buildInput(text: string, originalEvent: SessionEvent, tmpDir: string): Array<Record<string, unknown>> {
    const meta = originalEvent.metadata ?? {};
    const count = Number.parseInt(meta.attachment_count ?? "0", 10);
    const images: Array<Record<string, unknown>> = [];
    const placeholders: string[] = [];
    for (let i = 0; i < count; i += 1) {
      if (meta[`attachment_${i}_kind`] !== "image" || !meta[`attachment_${i}_b64`]) continue;
      const mime = meta[`attachment_${i}_mime`] ?? "image/png";
      const name = meta[`attachment_${i}_name`] ?? `image-${i}`;
      const bytes = Buffer.from(meta[`attachment_${i}_b64`], "base64");
      const ext = mime.split("/")[1]?.replace("jpeg", "jpg") ?? "png";
      fs.mkdirSync(tmpDir, { recursive: true });
      const file = path.join(tmpDir, `${crypto.randomUUID()}.${ext}`);
      fs.writeFileSync(file, bytes);
      images.push({ type: "localImage", path: this.runtime.kind === "wsl" ? toWslPath(file) : file });
      placeholders.push(`[image "${name}" attached: ${mime}, ${bytes.byteLength} bytes]`);
    }
    const parts = [...attachmentTextNotes(originalEvent), ...placeholders, metadataText(originalEvent, text)].filter(Boolean);
    return [{ type: "text", text: parts.join("\n\n"), text_elements: [] }, ...images];
  }

  /** notification = 子の完了などで親が自分から起きたターン（知らせのターン）。done に origin を付ける。 */
  private finishTurn(turnId: string | undefined, messageId?: string, notification = false): void {
    const mid = messageId ?? (turnId ? this.lastMessageByTurn.get(turnId) : undefined) ?? this.localMessageId;
    const done = event.done(this.agentId, this.sessionId, mid);
    this.emit?.(notification ? { ...done, metadata: { origin: "task-notification" } } : done);
    if (turnId) {
      this.localTurnIds.delete(turnId);
      this.lastMessageByTurn.delete(turnId);
      this.erroredTurns.delete(turnId);
      this.turnsWithUtterance.delete(turnId);
    }
    if (!turnId || turnId === this.activeTurnId) this.activeTurnId = undefined;
    // ターミナル側のターンの終わりは、iPhone から送ったターン（send の待ち）を終わらせない。そのターンへ steer した送信は除く。
    if (turnId && this.remoteTurnIds.delete(turnId) && turnId !== this.steeredInto) return;
    if (turnId === this.steeredInto) this.steeredInto = undefined;
    this.turnDone?.();
  }

  private handleNotification(m: Record<string, unknown>): void {
    const method = String(m.method ?? "");
    const params = obj(m.params);
    // thread/started はサブエージェント（子 thread）の開始。自分の thread id は start / resume の応答で確定させる。
    if (method === "thread/started") {
      this.emitSubagents(this.work.threadStarted(obj(params.thread), this.hasThread ? this.sessionId : undefined));
      return;
    }
    const tid = str(params.threadId) ?? str(obj(params.thread).id);
    if (method === "turn/completed") {
      const doneTurn = str(params.turnId) ?? str(obj(params.turn).id);
      if (doneTurn) this.interruptedTurnIds.delete(doneTurn);
    }
    if (tid && this.hasThread && tid !== this.sessionId) {
      // 自分の thread が spawn したサブエージェントの thread なら、その進行だけ拾う
      // （子 thread の通知は、購読していない接続にも届く。0.162.1 の実測）。
      if (this.work.isChildThread(tid)) this.emitSubagents(this.work.childNotification(method, params, tid));
      return;
    }
    const emit = this.emit;
    if (!emit) return;
    const turnId = str(params.turnId) ?? str(obj(params.turn).id);
    switch (method) {
      case "turn/started":
        // 自分のターン = turn/start の応答で得た id か、応答待ちの間に来たもの。それ以外はターミナル側のターンか、
        // 子の完了などで親が自分から起きたターン（stdio でも起きうる）。
        if (turnId && !this.localTurnIds.has(turnId) && !this.localTurnPending) this.remoteTurnIds.add(turnId);
        // iPhone の停止ボタンでターミナル側のターンも止められるように。
        if (turnId) this.activeTurnId ??= turnId;
        return;
      case "item/agentMessage/delta":
      case "item/plan/delta": {
        const itemId = str(params.itemId) ?? this.localMessageId;
        const delta = typeof params.delta === "string" ? params.delta : "";
        if (!delta) return;
        this.deltaItems.add(itemId);
        if (turnId) this.lastMessageByTurn.set(turnId, itemId);
        this.emitSessionStarted();
        emit(event.assistantDelta(this.agentId, this.sessionId, itemId, delta));
        return;
      }
      case "item/started": {
        const item = obj(params.item);
        const id = str(item.id) ?? crypto.randomUUID();
        if (item.type === "userMessage") {
          // ターミナルで打った発話。iPhone から送った分は送った側が表示済みなので流さない。
          if (!turnId || !this.remoteTurnIds.has(turnId)) return;
          if (str(item.clientId) === this.localMessageId) {
            // 自分の発話が、自分の始めていないターンへ steer された（知らせのターンではない）。
            this.turnsWithUtterance.add(turnId);
            return;
          }
          const content = Array.isArray(item.content) ? item.content.map(obj) : [];
          const text = stripImageTags(content.map((c) => (c.type === "text" && typeof c.text === "string" ? c.text : "")).filter(Boolean).join("\n"));
          // 差し込まれた文脈（AGENTS.md・<subagent_notification> 等）は発話ではない（知らせのターンのまま）。
          if (isInjectedUserContext(text)) return;
          const first = !this.turnsWithUtterance.has(turnId);
          this.turnsWithUtterance.add(turnId);
          if (!text) return;
          // ほかの画面（ターミナル）の発話で始まった新しいターンなら、終わった行を捨てる（アプリも user_message で
          // 捨てる）。同じターンへの 2 つ目からの発話（steer）では捨てない。
          if (first) this.work.pruneFinished();
          emit({ type: "user_message", agentId: this.agentId, sessionId: this.sessionId, messageId: id, content: text });
          return;
        }
        // サブエージェントの item（collabAgentToolCall・subAgentActivity）と、ターンより長く動きうる端末の覚え書き。
        this.emitSubagents(this.work.ownItemStarted(item, num(params.startedAtMs)));
        if (item.type === "commandExecution") {
          const command = Array.isArray(item.command) ? item.command.join(" ") : String(item.command ?? "");
          emit(event.toolStart(this.agentId, this.sessionId, id, "command", command, "execute"));
        } else if (item.type === "mcpToolCall") {
          const name = `${String(item.server ?? "mcp")}.${String(item.tool ?? "tool")}`;
          emit(event.toolStart(this.agentId, this.sessionId, id, name, name, "other"));
        } else if (item.type === "fileChange") {
          const { title, diff } = fileChangeSummary(item);
          const start = event.toolStart(this.agentId, this.sessionId, id, "file_change", title, "edit");
          if (diff) start.metadata = { ...start.metadata, diff };
          emit(start);
        }
        return;
      }
      case "item/completed": {
        const item = obj(params.item);
        const id = str(item.id) ?? "";
        // 止めた端末の item/completed は failed / -1 で来る。止めたものとして読む（赤くしない）。
        const stoppedExec = item.type === "commandExecution" && this.work.execStopped(item);
        // サブエージェントの item と、ターンの後に閉じた裏の端末（exitCode で done / failed）。
        this.emitSubagents(this.work.ownItemCompleted(item));
        if (item.type === "agentMessage") {
          if (!this.deltaItems.has(id) && typeof item.text === "string" && item.text) {
            if (turnId) this.lastMessageByTurn.set(turnId, id);
            emit(event.assistantDelta(this.agentId, this.sessionId, id, item.text));
          }
        } else if (item.type === "plan") {
          const steps = Array.isArray(item.plan) ? item.plan : Array.isArray(item.steps) ? item.steps : Array.isArray(item.entries) ? item.entries : undefined;
          if (steps) {
            const entries = steps.map((s) => {
              const o = obj(s);
              return { content: String(o.step ?? o.content ?? o.text ?? o.title ?? ""), status: String(o.status ?? "pending") };
            });
            emit(event.planUpdate(this.agentId, this.sessionId, JSON.stringify({ entries })));
          } else if (typeof item.text === "string" && !this.deltaItems.has(id)) {
            emit(event.assistantDelta(this.agentId, this.sessionId, id, item.text));
          }
        } else if (item.type === "commandExecution") {
          const failed = item.status === "failed" || item.status === "declined";
          const output = typeof item.aggregatedOutput === "string" ? item.aggregatedOutput.slice(0, SUMMARY_LIMIT) : undefined;
          const duration = typeof item.durationMs === "number" ? item.durationMs : undefined;
          emit(event.toolEnd(this.agentId, this.sessionId, id, "command", stoppedExec ? "interrupted" : failed ? "failed" : "completed", output, duration));
        } else if (item.type === "mcpToolCall") {
          const name = `${String(item.server ?? "mcp")}.${String(item.tool ?? "tool")}`;
          emit(event.toolEnd(this.agentId, this.sessionId, id, name, item.status === "failed" ? "failed" : "completed"));
        } else if (item.type === "fileChange") {
          const { title, diff } = fileChangeSummary(item);
          const end = event.toolEnd(this.agentId, this.sessionId, id, "file_change", item.status === "failed" ? "failed" : "completed", title);
          if (diff) end.metadata = { ...end.metadata, diff };
          emit(end);
        }
        return;
      }
      case "turn/completed": {
        const turn = obj(params.turn);
        // ターンより長く動く端末（processId 付きで、まだ閉じていない commandExecution）を shell の行にする。
        // done より先に流す（done を受けた server が、バックグラウンドの作業があると分かるように）。
        this.emitSubagents(this.work.ownTurnCompleted());
        // 自分が始めておらず発話も無いターン = 子の完了などで親が自分から起きた知らせのターン。
        const notification = turnId !== undefined && this.remoteTurnIds.has(turnId) && !this.turnsWithUtterance.has(turnId);
        if (turn.status === "failed" && !(turnId && this.erroredTurns.has(turnId))) {
          emit(event.error(this.agentId, this.sessionId, str(obj(turn.error).message) ?? "Codex turn failed"));
        }
        this.finishTurn(turnId, undefined, notification);
        return;
      }
      case "error": {
        const message = str(obj(params.error).message) ?? "Codex error";
        if (params.willRetry === true) {
          const mid = (turnId && this.lastMessageByTurn.get(turnId)) ?? "pending-thought";
          emit(event.activity(this.agentId, this.sessionId, mid, `${message}\n`));
          return;
        }
        // ターンに結びつくエラーは turn/completed(failed) で done にする。結びつかないものはここで畳む。
        // （途中経過として見せ、エラーとしての表示は turn/completed(failed) の error に任せる）。
        if (turnId ?? this.activeTurnId ?? this.localTurnPending) {
          emit(event.activity(this.agentId, this.sessionId, this.localMessageId, `${message}\n`));
          return;
        }
        emit(event.error(this.agentId, this.sessionId, message));
        this.finishTurn(undefined);
        return;
      }
      case "turn/failed":
      case "thread/error": {
        emit(event.error(this.agentId, this.sessionId, str(obj(params.error).message) ?? method));
        this.finishTurn(turnId);
        return;
      }
      case "serverRequest/resolved": {
        const rid = params.requestId !== undefined ? String(params.requestId) : undefined;
        if (rid && this.pending.delete(rid)) emit({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: rid });
        return;
      }
      case "thread/tokenUsage/updated": {
        const total = obj(obj(params.tokenUsage).total);
        const metadata: Record<string, string> = {};
        for (const [k, key] of [["totalTokens", "totalTokens"], ["inputTokens", "inputTokens"], ["outputTokens", "outputTokens"], ["reasoningOutputTokens", "reasoningOutputTokens"]]) {
          if (typeof total[key] === "number") metadata[k] = String(total[key]);
        }
        emit({ type: "usage_update", agentId: this.agentId, sessionId: this.sessionId, messageId: turnId, metadata });
        return;
      }
      default:
        return;
    }
  }

  // ── サブエージェント（multi_agent / collab）とバックグラウンドの端末（行は CodexBackgroundWork） ──

  private emitSubagent(payload: string | undefined): void {
    if (payload) this.emit?.(event.workflowProgress(this.agentId, this.sessionId, payload));
  }

  private emitSubagents(payloads: string[]): void {
    for (const p of payloads) this.emitSubagent(p);
  }

  private handleServerRequest(client: RpcClient, m: Record<string, unknown>): void {
    const id = m.id as number | string;
    const method = String(m.method ?? "");
    const params = obj(m.params);
    const requestId = String(id);
    // 共有 app-server では他の thread（ターミナルや別の会話）の要求もこの接続に届く。取り違えないよう出さない。
    const tid = str(params.threadId) ?? str(params.conversationId);
    if (this.onShared && tid && tid !== this.sessionId && !this.work.isChildThread(tid)) return;
    // 自動の断り（未対応・elicitation）は、ターミナルで開いている thread には返さない（ターミナル側の UI を潰さない）。
    const respondAuto = (send: () => void): void => {
      if (this.onShared && codexTerminals.isLive(this.sessionId)) return;
      send();
    };
    const card = (kind: string, title: string, subtitle: string | undefined, pendingKind: PendingKind): void => {
      this.pending.set(requestId, { id, kind: pendingKind, questionIds: [] });
      const metadata: Record<string, string> = { requestId, kind, title, ...APPROVAL_OPTIONS };
      if (subtitle) metadata.subtitle = subtitle;
      this.emit?.({ type: "action_request", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId, content: title, metadata });
    };
    switch (method) {
      case "item/commandExecution/requestApproval": {
        card("commandApproval", "コマンド実行を承認しますか", commandApprovalSubtitle(params), "approval");
        return;
      }
      case "item/fileChange/requestApproval":
        card("fileApproval", "ファイル変更を承認しますか", fileApprovalSubtitle(params), "approval");
        return;
      case "item/permissions/requestApproval":
        card("permissionsApproval", "権限変更を承認しますか", str(params.reason), "approval");
        return;
      case "execCommandApproval": {
        card("commandApproval", "コマンド実行を承認しますか", commandApprovalSubtitle(params), "legacyApproval");
        return;
      }
      case "applyPatchApproval":
        card("fileApproval", "ファイル変更を承認しますか", fileApprovalSubtitle(params), "legacyApproval");
        return;
      case "mcpServer/elicitation/request": {
        if (obj(params._meta).codex_approval_kind === "mcp_tool_call") {
          card("mcpToolApproval", "MCP ツールの実行を承認しますか", [str(params.message), str(params.serverName)].filter(Boolean).join("\n"), "elicitation");
        } else {
          respondAuto(() => client.respond(id, { action: "decline", content: null, _meta: null }));
        }
        return;
      }
      case "item/tool/requestUserInput": {
        const questions = Array.isArray(params.questions) ? params.questions.map(obj) : [];
        if (questions.length === 0) {
          client.respond(id, { answers: {} });
          return;
        }
        const questionIds = questions.map((q, i) => str(q.id) ?? `q${i}`);
        this.pending.set(requestId, { id, kind: "userInput", questionIds });
        const first = questions[0];
        const options = Array.isArray(first.options) ? first.options.map(obj) : [];
        const allowsOther = questions.some((q) => q.isOther === true || !Array.isArray(q.options) || q.options.length === 0);
        const metadata: Record<string, string> = {
          requestId,
          kind: "userInput",
          title: str(first.header) ?? "選択してください",
          allowsOther: allowsOther ? "1" : "0",
          option_count: String(options.length),
          questions_json: JSON.stringify(
            questions.map((q, i) => ({
              id: questionIds[i],
              question: str(q.question) ?? "",
              header: str(q.header) ?? "",
              multiSelect: false,
              options: (Array.isArray(q.options) ? q.options.map(obj) : []).map((o) => ({ label: str(o.label) ?? "", description: str(o.description) ?? "" }))
            }))
          )
        };
        if (str(first.question)) metadata.subtitle = str(first.question)!;
        options.forEach((o, i) => {
          metadata[`option_${i}_title`] = str(o.label) ?? `Option ${i + 1}`;
          metadata[`option_${i}_subtitle`] = str(o.description) ?? "";
          metadata[`option_${i}_value`] = str(o.label) ?? `Option ${i + 1}`;
        });
        this.emit?.({ type: "action_request", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId, content: metadata.title, metadata });
        return;
      }
      default:
        respondAuto(() => client.respondError(id, -32601, `BuddyOS does not support ${method}`));
    }
  }

  private handleExit(client: RpcClient): void {
    if (this.client !== client) return;
    this.client = undefined;
    this.threadReady = false;
    this.remoteTurnIds.clear();
    this.turnsWithUtterance.clear();
    this.steeredInto = undefined;
    // app-server が落ちた（共有サーバーとの接続が切れた）ので、子の thread と裏の端末はもう追えない。失敗として閉じる
    // （close() で止めたときは先に stopped で閉じてあり、ここには来ない）。
    this.emitSubagent(this.work.abandonRunning("failed"));
    // 先行購読だけで繋いでいて iPhone から送っておらず、ターンも進行中でなければ静かに畳む。
    if (this.onShared && !this.didSend && !this.activeTurnId && !this.localTurnPending) {
      this.pending.clear();
      return;
    }
    for (const rid of this.pending.keys()) this.emit?.({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: rid });
    this.pending.clear();
    if (this.turnDone && !this.closed) {
      this.emit?.(event.error(this.agentId, this.sessionId, "Codex app-server が終了しました"));
      this.finishTurn(this.activeTurnId);
    }
  }
}

// ── サブエージェントとバックグラウンドの端末の行 ──

/**
 * Codex の子 thread（サブエージェント）とバックグラウンドの端末を、SubagentTracker の行にする（mac の CodexBackgroundWork と同じ）。
 * 規則は docs/BACKGROUND_WORK_2026-10-21.md §3.6（codex 0.162.1 の実測）。
 * - 子の開始: subAgentActivity started（multi-agent v2。いまの既定のモデルはこちらで、model・reasoningEffort が付く）、
 *   collabAgentToolCall spawnAgent（v1。receiverThreadIds・prompt・model）、thread/started（0.162.1 の子には来ない）。
 *   行のキーは子 thread id
 * - 子の進行と終わりは子 thread の通知で見る。turn/completed は completed → done（最後の発言を結果に）、
 *   interrupted → stopped、failed → failed（turn.error か、子の error 通知の文を結果に）。
 *   error（willRetry=false）と thread/status/changed の systemError も failed
 * - subAgentActivity の interacted（send_message・followup_task）は作業の文だけ変える（send_message は子のターンを
 *   起こさない）。実行中に戻すのは子の turn/started。interrupted → stopped、completed → done
 *   （子の turn/completed の後に来る。failed / stopped の行は上書きしない＝SubagentTracker が受けない）
 * - バックグラウンドの端末: 自分の thread の turn/completed の時点で閉じていない commandExecution（processId あり）を
 *   shell の行（tool "exec"）にし、後から届く item/completed の exitCode で done / failed にする。行のキーは item id
 */
export class CodexBackgroundWork {
  /** interacted のときの作業の文（v2 の item は、送った中身を持たない）。 */
  static readonly interactedActivity = "message from parent";

  readonly tracker = new SubagentTracker();
  /** 自分の thread で始まり、まだ item/completed の来ていない commandExecution（processId あり）。始まった順。 */
  private openExecs: Array<{ id: string; command: string; processId: string; startedAtMs?: number }> = [];
  /** 子 thread の今の turn id（turn/started で覚え、turn/completed で消す）。子の turn/interrupt に要る。 */
  readonly childTurns = new Map<string, string>();
  /** thread/backgroundTerminals/terminate で止めた端末の item id（後から来る failed / -1 を stopped と読む）。 */
  private readonly stoppedExecs = new Set<string>();
  /** app-server が端末の停止（thread/backgroundTerminals/terminate）を受け付けるか。断られたら false。 */
  terminalStopSupported = true;
  /** 子 thread の最後の発言（turn/completed の items に無いときの結果）。 */
  private readonly lastMessages = new Map<string, string>();
  /** 子 thread の error の文（turn/completed の turn.error が無いときの結果）。 */
  private readonly errors = new Map<string, string>();

  /** これまでに行にした子 thread（終わった行を捨てても忘れない。後のターンで followup_task に起こされた子を見つけるため）。 */
  private readonly knownChildren = new Map<string, { agentType?: string; model?: string }>();

  private remember(tid: string, info: { agentType?: string; model?: string }): void {
    this.knownChildren.delete(tid);
    this.knownChildren.set(tid, info);
    if (this.knownChildren.size > 256) {
      const oldest = this.knownChildren.keys().next().value;
      if (oldest !== undefined) this.knownChildren.delete(oldest);
    }
  }

  /** 行にしている（か、行にしたことがある）子 thread か（知らない thread の通知は捨てる）。 */
  isChildThread(threadId: string): boolean {
    return this.tracker.has(threadId) || this.knownChildren.has(threadId);
  }

  /** 新しいターンを始める前に、終わった行を忘れる（動いているものは残す）。 */
  pruneFinished(): void {
    this.tracker.pruneFinished();
  }

  /**
   * close・異常終了で、もう終わりの知らせが来ない実行中の行を閉じる（止めたなら stopped、落ちたなら failed）。
   * 閉じた行があれば payload を返す。
   */
  abandonRunning(state: string): string | undefined {
    this.openExecs = [];
    this.childTurns.clear();
    this.stoppedExecs.clear();
    this.knownChildren.clear();
    this.lastMessages.clear();
    this.errors.clear();
    return this.tracker.abandonRunning({ state });
  }

  /** 自分の thread の item/started。サブエージェントの item は行に、processId 付きの端末は覚えておく。 */
  ownItemStarted(item: Record<string, unknown>, startedAtMs?: number): string[] {
    switch (item.type) {
      case "subAgentActivity":
      case "collabAgentToolCall":
        return this.subagentItem(item);
      case "commandExecution": {
        // processId 付き（unified exec の端末）は、ツールの呼び出しやターンが終わっても動き続けることがある。
        const id = str(item.id);
        const pid = processId(item);
        if (!id || pid === undefined || this.openExecs.some((e) => e.id === id)) return [];
        this.openExecs.push({ id, command: CodexBackgroundWork.execCommand(item) ?? "command", processId: pid, startedAtMs: startedAtMs ?? num(item.startedAtMs) });
        if (this.openExecs.length > 64) this.openExecs.shift();
        return [];
      }
      default:
        return [];
    }
  }

  /** 自分の thread の item/completed。 */
  ownItemCompleted(item: Record<string, unknown>): string[] {
    switch (item.type) {
      case "subAgentActivity":
      case "collabAgentToolCall":
        return this.subagentItem(item);
      case "commandExecution": {
        const id = str(item.id);
        if (!id) return [];
        this.openExecs = this.openExecs.filter((e) => e.id !== id);
        // ターンの後も動いていた端末が閉じた（turnId は終わったターンのまま届く）。
        if (!this.tracker.has(id)) return [];
        const state = this.execStopped(item) ? "stopped" : CodexBackgroundWork.execState(item);
        return list(this.tracker.finish(id, state, CodexBackgroundWork.outputTail(item.aggregatedOutput), num(item.durationMs)));
      }
      default:
        return [];
    }
  }

  /** 止めた端末の item/completed（返事待ちか止めた覚えのある端末で、exitCode が -1）か。 */
  execStopped(item: Record<string, unknown>): boolean {
    const id = str(item.id);
    return id !== undefined && item.exitCode === -1 && (this.stoppedExecs.has(id) || this.tracker.isStopRequested(id));
  }

  markStoppedExec(id: string): void {
    this.stoppedExecs.add(id);
    if (this.stoppedExecs.size > 256) {
      const oldest = this.stoppedExecs.values().next().value;
      if (oldest !== undefined) this.stoppedExecs.delete(oldest);
    }
  }

  /** 端末の processId（開いたままの端末だけ）。 */
  processIdOf(id: string): string | undefined {
    return this.openExecs.find((e) => e.id === id)?.processId;
  }

  /** 端末の停止が受け付けられない app-server だった。全 shell 行の手がかりを外して、変わった行の payload を返す。 */
  disableTerminalStop(): string[] {
    this.terminalStopSupported = false;
    return this.openExecs.flatMap((e) => list(this.tracker.setStopHandle(e.id, false)));
  }

  /**
   * 自分の thread の turn/completed。まだ閉じていない端末を shell の行にする（バックグラウンドの端末を示す
   * 明示のイベントは無い。目印は、ターンが終わっても開いたままの processId 付きの commandExecution）。
   */
  ownTurnCompleted(): string[] {
    const out: string[] = [];
    for (const exec of this.openExecs) {
      if (this.tracker.has(exec.id)) continue;
      const p = this.tracker.begin(exec.id, exec.command, { background: true, rowKind: "shell", tool: "exec", command: exec.command, startedAt: exec.startedAtMs });
      // 手がかりを立てた payload が begin のものを置き換える（同じ行の payload を 2 つ流さない）。
      const handled = this.terminalStopSupported ? this.tracker.setStopHandle(exec.id, true) : undefined;
      if (handled ?? p) out.push((handled ?? p)!);
    }
    return out;
  }

  /** thread/started（parentThreadId が自分の子 thread）。役割・ニックネームを種類にする。 */
  threadStarted(thread: Record<string, unknown>, ownThreadId: string | undefined): string[] {
    const id = str(thread.id);
    const parent = str(thread.parentThreadId);
    if (!id || !parent || parent !== ownThreadId) return [];
    this.remember(id, { agentType: str(thread.agentRole) ?? str(thread.agentNickname) });
    return list(this.tracker.begin(id, undefined, { agentType: str(thread.agentRole) ?? str(thread.agentNickname) }));
  }

  /** 子 thread の通知。行にしていない thread のものは捨てる。 */
  childNotification(method: string, params: Record<string, unknown>, tid: string): string[] {
    if (!this.tracker.has(tid)) {
      // 終わって行を捨てた子が、後のターンの followup_task で起こされた。子のターンが始まったら行を作り直す
      // （interacted は send_message でも来て子を起こさないので、行にしない）。
      const known = this.knownChildren.get(tid);
      if (method !== "turn/started" || !known) return [];
      return this.childTurnStarted(tid, params, this.tracker.begin(tid, undefined, { agentType: known.agentType, model: known.model }));
    }
    const item = obj(params.item);
    switch (method) {
      case "item/started":
        switch (item.type) {
          case "commandExecution":
            return list(this.tracker.activity(tid, `command: ${CodexBackgroundWork.execCommand(item) ?? ""}`, { toolCall: true }));
          case "mcpToolCall":
            return list(this.tracker.activity(tid, [str(item.server), str(item.tool)].filter(Boolean).join("."), { toolCall: true }));
          case "fileChange":
            return list(this.tracker.activity(tid, fileChangeSummary(item).title, { toolCall: true }));
          case "webSearch":
            return list(this.tracker.activity(tid, "web search", { toolCall: true }));
          default:
            return [];
        }
      case "item/completed": {
        const text = item.type === "agentMessage" ? str(item.text) : undefined;
        if (!text) return [];
        this.lastMessages.set(tid, text);
        return list(this.tracker.activity(tid, text));
      }
      case "thread/tokenUsage/updated": {
        const total = obj(obj(params.tokenUsage).total);
        return list(this.tracker.activity(tid, undefined, { tokens: typeof total.totalTokens === "number" ? total.totalTokens : undefined }));
      }
      case "thread/status/changed":
        // systemError は子のターンの失敗（理由は直後の error と turn/completed(failed) で届く）。
        if (str(obj(params.status).type) !== "systemError") return [];
        return list(this.tracker.finish(tid, "failed", this.errors.get(tid)));
      case "error": {
        const message = str(obj(params.error).message) ?? str(params.message);
        // willRetry=true は再接続中（ターンは続く）。いまの作業として見せる。
        if (params.willRetry === true) return list(this.tracker.activity(tid, message));
        if (message) this.errors.set(tid, message);
        return list(this.tracker.finish(tid, "failed", message));
      }
      case "turn/started":
        // 話しかけ直された（followup_task 等）子は実行中に戻す。
        this.lastMessages.delete(tid);
        this.errors.delete(tid);
        return this.childTurnStarted(tid, params, this.tracker.begin(tid));
      case "turn/completed": {
        const turn = obj(params.turn);
        this.childTurns.delete(tid);
        this.tracker.setStopHandle(tid, false); // 手がかりごと落とす。行を閉じる payload は下で送る。
        const message = lastAgentMessage(turn.items) ?? this.lastMessages.get(tid);
        const error = str(obj(turn.error).message) ?? this.errors.get(tid);
        this.lastMessages.delete(tid);
        this.errors.delete(tid);
        switch (str(turn.status)) {
          case "failed":
            return list(this.tracker.finish(tid, "failed", error));
          case "interrupted":
            return list(this.tracker.finish(tid, "stopped"));
          default:
            return list(this.tracker.finish(tid, "done", message));
        }
      }
      default:
        return [];
    }
  }

  /** 子の turn/started。今の turn id を覚え、止める手がかりを立てる（turn id が分からなければ立てない）。 */
  private childTurnStarted(tid: string, params: Record<string, unknown>, begun: string | undefined): string[] {
    const turnId = str(obj(params.turn).id) ?? str(params.turnId);
    if (!turnId) return list(begun);
    this.childTurns.set(tid, turnId);
    return list(this.tracker.setStopHandle(tid, true) ?? begun);
  }

  /**
   * collabAgentToolCall（v1: spawnAgent / wait 等）と subAgentActivity（v2: started / interacted / interrupted / completed）。
   * collabAgentToolCall = { tool, status, receiverThreadIds, prompt, model, agentsStates: { threadId: { status, message } } }
   * subAgentActivity    = { kind, agentThreadId, agentPath, model, reasoningEffort }（model と reasoningEffort は
   *                       0.162.1 で増えた。started のときだけ入る）
   */
  private subagentItem(item: Record<string, unknown>): string[] {
    if (item.type === "subAgentActivity") {
      const tid = str(item.agentThreadId);
      if (!tid) return [];
      const agentPath = str(item.agentPath)?.split("/").filter(Boolean).pop();
      switch (str(item.kind)) {
        case "started": {
          const model = CodexBackgroundWork.modelLabel(str(item.model), str(item.reasoningEffort));
          this.remember(tid, { agentType: agentPath, model });
          return list(this.tracker.begin(tid, undefined, { agentType: agentPath, model }));
        }
        case "interacted":
          // send_message（子のターンを起こさない）と followup_task の両方で来る。実行中には戻さない。
          return list(this.tracker.activity(tid, CodexBackgroundWork.interactedActivity));
        case "interrupted":
          return list(this.tracker.finish(tid, "stopped"));
        case "completed":
          return list(this.tracker.finish(tid, "done"));
        default:
          return [];
      }
    }
    const out: Array<string | undefined> = [];
    const receivers = (Array.isArray(item.receiverThreadIds) ? item.receiverThreadIds : []).filter((v): v is string => typeof v === "string");
    if (item.tool === "spawnAgent") {
      for (const tid of receivers) {
        this.remember(tid, { model: str(item.model) });
        out.push(this.tracker.begin(tid, str(item.prompt), { model: str(item.model) }));
      }
    } else if (item.tool === "wait") {
      for (const tid of receivers) out.push(this.tracker.activity(tid));
    }
    for (const [tid, raw] of Object.entries(obj(item.agentsStates))) {
      if (!this.tracker.has(tid)) continue;
      const state = obj(raw);
      const message = str(state.message);
      switch (str(state.status)) {
        case "completed":
        case "shutdown":
          out.push(this.tracker.finish(tid, "done", message));
          break;
        case "interrupted":
          out.push(this.tracker.finish(tid, "stopped", message));
          break;
        case "errored":
        case "notFound":
          out.push(this.tracker.finish(tid, "failed", message));
          break;
        default:
          if (message) out.push(this.tracker.activity(tid, message));
      }
    }
    return out.filter((p): p is string => p !== undefined);
  }

  /** 行のモデル。reasoningEffort があれば「gpt-6-luna (medium)」の形で添える（行に努力度の項目は無い）。 */
  static modelLabel(model: string | undefined, effort: string | undefined): string | undefined {
    if (!model) return undefined;
    return effort ? `${model} (${effort})` : model;
  }

  /** 端末のコマンド。command はシェルの包み（/bin/zsh -lc '…'）付きなので、生のコマンド（commandActions[0].command）を優先する。 */
  static execCommand(item: Record<string, unknown>): string | undefined {
    const actions = Array.isArray(item.commandActions) ? item.commandActions : [];
    const raw = actions.length > 0 ? str(obj(actions[0]).command) : undefined;
    return raw ?? (Array.isArray(item.command) ? item.command.map(String).join(" ") || undefined : str(item.command));
  }

  /** 閉じた端末の行の状態。exitCode が 0 なら done、それ以外は failed（exitCode が無ければ status で決める）。 */
  static execState(item: Record<string, unknown>): string {
    if (typeof item.exitCode === "number") return item.exitCode === 0 ? "done" : "failed";
    return item.status === "failed" || item.status === "declined" ? "failed" : "done";
  }

  /** 端末の出力の終わりの方（行の結果。長い出力は頭より終わりの方が役に立つ）。SubagentTracker の上限（2000 字）に収める。 */
  static outputTail(raw: unknown, limit = 1990): string | undefined {
    if (typeof raw !== "string") return undefined;
    const t = raw.trim();
    if (!t) return undefined;
    const chars = Array.from(t);
    return chars.length > limit ? `…${chars.slice(-limit).join("")}` : t;
  }
}

/** turn.items の最後の agentMessage の本文。 */
function lastAgentMessage(raw: unknown): string | undefined {
  const items = Array.isArray(raw) ? raw.map(obj) : [];
  for (let i = items.length - 1; i >= 0; i -= 1) if (items[i].type === "agentMessage") return str(items[i].text);
  return undefined;
}

/** commandExecution の processId（文字列でも数値でも来る）。 */
function processId(item: Record<string, unknown>): string | undefined {
  return str(item.processId) ?? (typeof item.processId === "number" ? String(item.processId) : undefined);
}

const list = (payload: string | undefined): string[] => (payload ? [payload] : []);

/** cond が true になるか ms が過ぎるまで待つ。 */
async function untilTrue(cond: () => boolean, ms: number): Promise<void> {
  const deadline = Date.now() + ms;
  while (!cond() && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
}
