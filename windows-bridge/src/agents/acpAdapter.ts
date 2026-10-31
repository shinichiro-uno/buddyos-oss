import crypto from "node:crypto";
import { event, type HistoryMessage, type SessionEvent, type SessionSummary } from "../protocol.js";
import { JsonRpcProcess } from "../runtime/jsonRpcProcess.js";
import { normalizeRuntimeCwd, toWslPath, type RuntimeCommand } from "../runtime/command.js";
import type { JsonSessionStore } from "../sessionStore.js";
import {
  attachmentBlocks,
  attachmentTextNotes,
  BaseAdapter,
  imageAttachments,
  imagePlaceholder,
  metadataText,
  type AgentSession,
  type Emit,
  type SessionOptions,
  type SessionOverrides
} from "./types.js";
import { normalizedToolName, SubagentTracker } from "./subagentTracker.js";
import { exportImageFile } from "./attachmentStore.js";
import { createLedgerReader, grokReceiptKey, hermesReceipt, LedgerWatcher, openclawReceipt, type LedgerKind, type LedgerRow } from "./acpDelegations.js";
import { orchestrator, type McpPlan } from "../mainagent/orchestrator.js";
import { acpHttpServer, mainAgentPort } from "../mainagent/workspace.js";
import { acpStdioRelayServer, relayCommand } from "../mainagent/stdioRelay.js";

export interface AcpAdapterOptions {
  /** UI 表示名。指定がなければ `id` を Capitalize したものを使う。 */
  displayName?: string;
  /** `acp` プロセス起動時の追加引数。デフォルトは `["acp"]`。 */
  args?: string[];
  /** プロセスに渡す追加環境変数 (e.g. Hermes は GLM_BASE_URL を固定, OpenCode は XDG_CACHE_HOME)。 */
  env?: Record<string, string>;
  /** セッションごとの違い（cursor / grok の承認カード・モード等）。無ければ従来の挙動。 */
  tuning?: (options?: SessionOptions) => AcpTuning;
}

/** AcpSession の agent ごとの違い（mac の AcpSessionTuning）。既定は hermes / openclaw / opencode の従来の挙動。 */
export interface AcpTuning {
  /** session/request_permission を iPhone の承認カードにする。false なら従来どおり拒否で即答する。 */
  approvals?: boolean;
  /** BuddyOS のモード → ACP の mode 設定（configOptions）の値。"*" はそれ以外のモード。例: cursor は plan → "plan"、他 → "agent"。 */
  modeConfigValues?: Record<string, string>;
  /** BuddyOS のモード → prompt の頭に付ける文字。例: grok の plan は `/plan `（設定項目に plan が無いため）。 */
  modePromptPrefix?: Record<string, string>;
  /** ACP の image block を受けない agent（grok）は、画像をファイルに書き出してパスを渡す。 */
  imagesAsFiles?: boolean;
  /** エージェント既定（新しいチャットの初期値）。チャットの上書きが無い項目に使う。 */
  defaults?: SessionOverrides;
  /** 無人実行（cron）。答えられない承認要求は拒否で返す。 */
  unattended?: boolean;
  /** 無人実行の権限モード（cron の job ごとの指定）。チャットの上書きより弱く、既定より強い。 */
  permissionMode?: string;
  /** `_x.ai/session_notification` と起こされたターンの `_x.ai/queue/changed` を扱う（grok だけ）。 */
  xaiNotifications?: boolean;
  /** false なら、状態の無い tool_call_update でツールの行を閉じない（grok だけ）。既定は true。 */
  statuslessUpdateEndsTool?: boolean;
  /** 非同期の委任を台帳で追う agent（hermes は state.db、openclaw は openclaw.sqlite）。 */
  delegationLedger?: LedgerKind;
}

/**
 * モードで答えが決まる承認要求の選択肢 id（mac の autoPermissionAnswer と同じ）。undefined = iPhone に出して待つ。"" = 取り消す。
 * - dangerous: 許可（一度だけ）
 * - edit: 編集系（ACP の tool kind が edit / delete / move）だけ許可
 * - 無人実行（cron）: 答える人がいないので拒否
 */
export function autoPermissionAnswer(
  mode: string | undefined,
  toolKind: string | undefined,
  unattended: boolean,
  options: Array<{ id: string; kind: string }>
): string | undefined {
  const pick = (wanted: string[]): string | undefined => {
    for (const kind of wanted) {
      const o = options.find((option) => option.kind === kind);
      if (o) return o.id;
    }
    return undefined;
  };
  const allow = pick(["allow_once", "allow_always"]);
  if (mode === "dangerous" && allow) return allow;
  if (mode === "edit" && toolKind && ["edit", "delete", "move"].includes(toolKind) && allow) return allow;
  if (unattended) return pick(["reject_once", "reject_always"]) ?? "";
  return undefined;
}

/** ACP `configOptions` から抽出した、`{value,name}` 形式の選択肢。 */
export interface ConfigOption {
  value: string;
  name: string;
}

/** OpenCode が push する available_commands_update の 1 エントリ。 */
export interface AcpCommand {
  name: string;
  description: string;
}

/** interrupt 後、cancelled 応答が返らないエージェントでもターンを畳むまでの猶予（mac と同じ 5 秒）。 */
export const INTERRUPT_DONE_GRACE_MS = 5000;
/** cancel 済みの session/prompt が戻るまで、次の session/prompt を送らずに待つ上限。 */
export const CANCELLED_PROMPT_WAIT_MS = 30_000;

/// Hermes / OpenClaw のような ACP (Agent Client Protocol) 互換エージェント向けの
/// 汎用アダプタ。`agentId` と `runtime` のほか、起動引数と env を任意で受け取る。
/**
 * mainagent の MCP の渡し方（mac の AcpSession.mainagentMcpTransport と同じ）。initialize の agentCapabilities.mcpCapabilities.http が
 * true なら /mcp を直接、そうでなければ stdio の中継。WSL で動くエージェントは http でも中継（WSL2 の NAT では 127.0.0.1 が
 * Windows に届かないことがある）。中継のコマンドが分からなければ渡さない。
 */
export function acpMainAgentTransport(
  initResult: Record<string, unknown>,
  kind: RuntimeCommand["kind"],
  relay: { command: string; args: string[] } | undefined
): "http" | { stdio: { command: string; args: string[] } } | undefined {
  const http = asObject(asObject(initResult.agentCapabilities).mcpCapabilities).http === true;
  if (http && kind !== "wsl") return "http";
  return relay ? { stdio: relay } : undefined;
}

export class AcpAdapter extends BaseAdapter {
  public readonly displayName: string;
  public readonly runtimeLabel: string;
  /** interrupt() は ACP の session/cancel を送る。 */
  public readonly supportsInterrupt = true;
  private readonly args: string[];
  private readonly env: Record<string, string>;
  private readonly tuning?: (options?: SessionOptions) => AcpTuning;
  /** 最後に開いた live session。OpenCode の models/mode/commands クエリで参照する。 */
  protected liveSession?: AcpSession;

  constructor(
    public readonly id: string,
    private readonly runtime: RuntimeCommand,
    private readonly store: JsonSessionStore,
    options: AcpAdapterOptions = {}
  ) {
    super();
    this.displayName = options.displayName ?? capitalize(id);
    this.runtimeLabel = runtime.label;
    this.args = options.args ?? ["acp"];
    this.env = options.env ?? {};
    this.tuning = options.tuning;
  }

  async openSession(sessionId: string | undefined, cwd: string | undefined, options?: SessionOptions): Promise<AgentSession> {
    const session = new AcpSession(this.id, sessionId, cwd, this.runtime, this.store, this.args, this.env, this.tuning?.(options));
    this.liveSession = session;
    return session;
  }

  async listSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    return this.store.list(this.id, limit, cwd);
  }

  async loadHistory(sessionId: string): Promise<HistoryMessage[]> {
    return this.store.history(this.id, sessionId);
  }

  async renameSession(sessionId: string, title: string): Promise<boolean> {
    return this.store.rename(this.id, sessionId, title);
  }
}

export class AcpSession implements AgentSession {
  /** 停止の猶予と、cancel 済みの prompt を待つ上限（テストで短くする）。 */
  static interruptGraceMs = INTERRUPT_DONE_GRACE_MS;
  static cancelledPromptWaitMs = CANCELLED_PROMPT_WAIT_MS;
  public sessionId: string;
  private client?: JsonRpcProcess;
  private acpSessionId?: string;
  private bootstrapped = false;
  private currentMessageId?: string;
  private assistantBuffer = "";
  private toolStartTimes = new Map<string, number>();
  private toolNames = new Map<string, string>();
  /**
   * サブエージェントへの委任ツール（Hermes の delegate_task、OpenClaw の sessions_spawn 等。キーは toolCallId）。
   * セッションに 1 つ持つ。非同期の委任（Hermes delegate_task・OpenClaw sessions_spawn・Grok spawn_subagent）は、受領票で行を
   * running のまま残し、Grok は終わりの知らせ、Hermes・OpenClaw は台帳で閉じる（読めないときは受領票で閉じる。BACKGROUND_CONTROL §5）。
   */
  private subagents = new SubagentTracker();
  /** 非同期の委任の行（BACKGROUND_CONTROL §5）。終わった行は prune で捨てる。 */
  private readonly delegations = new Map<string, Delegation>();
  /** 台帳の見張り（Hermes・OpenClaw。最初の台帳の行で作る）。 */
  private watcher?: LedgerWatcher;
  /** 開いている知らせのターン（Grok の起こされたターン）。 */
  private notifyTurn?: { promptId: string; messageId: string; bubbleId?: string; hadBody: boolean };
  /** 知らせのターンの、いま開いている吹き出しの本文（履歴に残す。ツールの呼び出しで区切る）。 */
  private notifyText = "";
  /** 見たことのある知らせのターンの prompt id（同じ id で開き直さない）。 */
  private readonly seenNotifyPrompts = new Set<string>();
  /** close() した。以後のプロセスの終了は、止めたもの（行はもう stopped で閉じてある）。 */
  private closed = false;
  private readonly agentCwd: string | undefined;
  /** 通知の送り先。session は接続をまたいで共有されるので、send() のたびに最新の接続の emit に差し替える。 */
  private emit?: Emit;
  /** session/load 中の履歴 replay を捨てるためのゲート（mac の acceptingUpdates と同じ）。
   *  並行 send で bootstrap が 2 本走ったとき、先に終わった側が他方の replay 中に開けないよう在飛行数で持つ。 */
  private loadsInFlight = 0;
  /** 実行中の session/prompt の数（interrupt は実行中があるときだけ session/cancel を送る）。 */
  private promptsInFlight = 0;
  /** interrupt() で session/cancel を送った。以後の prompt の失敗は error ではなく done で畳む。 */
  private cancelRequested = false;
  /** 実行中の session/prompt を待つのをやめさせる関数（interrupt の猶予切れで呼ぶ）。 */
  private readonly abandoners = new Set<() => void>();
  /** 猶予切れで待つのをやめた（cancel 済みの）session/prompt。戻るまで次の session/prompt を送らない。 */
  private stalePrompt?: Promise<void>;
  /** 猶予切れで畳んだ旧ターンの残りの出力を、次の session/prompt を送るまで捨てる。 */
  private discardingStale = false;
  /** このチャットだけのモデル / Effort / モード。次の session/prompt の前に set_config_option で反映する。 */
  private overrides: SessionOverrides = {};
  /** エージェントの既定（session/new・load の時点の値と、全体の切り替え setConfigOption の値）。上書きを外したら戻す。 */
  private baseline: { model?: string; mode?: string; effort?: string } = {};
  /** 合鍵（orchestrator）。プロセスを張り直すたびに発行し直す。 */
  private mainToken?: string;
  /** MCP を渡すか（開いたときに決める。道具で起こした子なら深さもここで決まる）。 */
  private readonly mcpPlan?: McpPlan;
  /** session/new・load に渡す mcpServers（mainagent のときだけ Bridge の MCP）。 */
  private mcpServers: Array<Record<string, unknown>> = [];
  /** 回答待ちの session/request_permission（action_request の requestId → JSON-RPC の id と選択肢）。 */
  private readonly pendingPermissions = new Map<string, { rpcId: number | string; optionIds: string[]; client: JsonRpcProcess }>();
  /** configOptions の id（agent ごとに違う。category でも探す）。 */
  private modelConfigId?: string;
  private modeConfigId?: string;
  private effortConfigId?: string;

  // ── ACP configOptions / available_commands_update のキャプチャ ──────────
  // OpenCode は session/new・session/load の result.configOptions と、
  // その後に push される available_commands_update を返す。Hermes/OpenClaw は
  // configOptions を返さないため、すべて undefined / 空のままで無害。
  public modelCurrent?: string;
  public modelOptions: ConfigOption[] = [];
  public modeCurrent?: string;
  public modeOptions: ConfigOption[] = [];
  public effortCurrent?: string;
  public effortOptions: ConfigOption[] = [];
  public commands: AcpCommand[] = [];
  /** commands が再 push されたときに呼ばれる（live re-push 用）。 */
  public onCommandsChanged?: (commands: AcpCommand[]) => void;

  constructor(
    private readonly agentId: string,
    initialSessionId: string | undefined,
    private readonly cwd: string | undefined,
    private readonly runtime: RuntimeCommand,
    private readonly store: JsonSessionStore,
    private readonly args: string[],
    private readonly env: Record<string, string>,
    private readonly tuning: AcpTuning = {}
  ) {
    this.sessionId = initialSessionId ?? `pending-${crypto.randomUUID()}`;
    this.agentCwd = normalizeRuntimeCwd(runtime, cwd);
    // 開いた時点（adapter の openSession の中）で、合鍵を渡すかと深さを決める。
    this.mcpPlan = orchestrator.planFor(agentId, initialSessionId, cwd, tuning.unattended);
  }

  async send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    // bootstrap より前に差し替える（bootstrap 中に届く通知も今の接続へ流すため）。
    this.emit = emit;
    this.subagents.pruneFinished();
    this.pruneDelegations();
    try {
      await this.bootstrap(emit);
    } catch (error) {
      this.failTurn(emit, `${this.agentId} ACP start failed: ${errorMessage(error)}`);
      return;
    }

    const client = this.client;
    const acpSessionId = this.acpSessionId;
    if (!client || !acpSessionId) {
      this.failTurn(emit, `${this.agentId} ACP session is not ready`);
      return;
    }

    // 停止の猶予切れで畳んだ旧ターンがまだ戻っていなければ、戻るまで（上限つきで）次を送らない。
    // 並行して送ると、旧ターンの残りの出力がこのターンに混ざる。
    const stale = this.stalePrompt;
    if (stale) {
      await Promise.race([stale, delay(AcpSession.cancelledPromptWaitMs)]);
      if (this.stalePrompt === stale) this.stalePrompt = undefined;
    }
    this.discardingStale = false;
    // チャットで選んだモデル / Effort / モードを、今の値と違う分だけこの prompt の前に効かせる。
    await this.applyConfigForTurn();
    const mode = this.effectiveMode();
    // モードを prompt の頭の文字で効かせる agent（grok の plan は `/plan `）。
    const userText = `${(mode && this.tuning.modePromptPrefix?.[mode]) ?? ""}${metadataText(originalEvent, text)}`;
    const notes = attachmentTextNotes(originalEvent);
    const images = imageAttachments(originalEvent);
    if (this.tuning.imagesAsFiles) {
      // image block を受けない agent には、ファイルに書き出してパスを渡す（履歴の目印と同じ書き方で、末尾にパスを足す）。
      for (const image of images) {
        const file = exportImageFile(image);
        const shown = file && this.runtime.kind === "wsl" ? toWslPath(file) : file;
        notes.push(shown ? `${imagePlaceholder(image)} (file: ${shown} — open this file to see the image)` : imagePlaceholder(image));
      }
    }
    const fullText = notes.length > 0 ? `${notes.join("\n\n")}\n\n${userText}` : userText;
    const prompt: Array<Record<string, unknown>> = [{ type: "text", text: fullText }, ...(this.tuning.imagesAsFiles ? [] : attachmentBlocks(originalEvent))];
    // 履歴には画像の目印を残す（履歴を開いたときに AttachmentStore から実画像へ戻す）。
    const recorded = this.tuning.imagesAsFiles || images.length === 0 ? fullText : `${images.map(imagePlaceholder).join("\n\n")}\n\n${fullText}`;

    this.store.appendMessage(this.agentId, this.sessionId, "user", recorded, this.cwd, originalEvent.messageId ?? crypto.randomUUID());
    this.currentMessageId = undefined;
    this.assistantBuffer = "";

    if (this.promptsInFlight === 0) this.cancelRequested = false;
    this.promptsInFlight += 1;
    // 長いターン（大きな実装・調査）は 10 分を超えるのが普通なので、session/prompt には時間切れを付けない
    // （mac と同じ）。プロセスが死ねば JsonRpcProcess が reject し、止めるのは interrupt() の session/cancel。
    const request = client.request("session/prompt", { sessionId: acpSessionId, prompt }, 0);
    let abandon!: () => void;
    const abandoned = new Promise<"abandoned">((resolve) => {
      abandon = () => resolve("abandoned");
    });
    this.abandoners.add(abandon);
    try {
      const response = await Promise.race([request, abandoned]);
      if (response === "abandoned") {
        // cancel に応じないエージェント。ターンは done で畳み、遅れて届く応答と出力は捨てる。
        this.stalePrompt = request.then(() => undefined, () => undefined);
        this.discardingStale = true;
        // 以後の更新は捨てるので、委任の行は終わりの知らせで閉じられない。cancel の後に始まった委任もここで閉じる。
        this.abandonSubagents("stopped", true);
      } else if (response.error && !this.cancelRequested) {
        // interrupt 後は stopReason "cancelled" の正常応答が来る。エラーで返すエージェントも停止として done で畳む。
        this.failTurn(emit, `session/prompt error: ${JSON.stringify(response.error)}`);
        return;
      }
    } catch (error) {
      if (!this.cancelRequested) {
        this.failTurn(emit, `session/prompt failed: ${errorMessage(error)}`);
        return;
      }
    } finally {
      this.abandoners.delete(abandon);
      this.promptsInFlight -= 1;
    }

    const messageId = this.currentMessageId ?? crypto.randomUUID();
    if (this.assistantBuffer.trim()) {
      this.store.appendMessage(this.agentId, this.sessionId, "assistant", this.assistantBuffer, this.cwd, messageId);
      emit(event.assistantTurnEnd(this.agentId, this.sessionId, messageId));
    }
    emit(event.done(this.agentId, this.sessionId, messageId));
  }

  /// 実行中ターンを止める。ACP の session/cancel 通知を送ると、エージェントは進行中の turn を止めて
  /// session/prompt に stopReason "cancelled" で応答する。done はその戻り（send()）で出す（ここでも出すと二重になる）。
  async interrupt(): Promise<void> {
    const client = this.client;
    const acpSessionId = this.acpSessionId;
    if (!client?.alive || !acpSessionId) return;
    if (this.promptsInFlight === 0) {
      // 起こされたターン（Grok の知らせのターン）の最中の停止。cancel を送り（best effort）、ターンを今閉じる。
      // 以後の同じ promptId の更新は、開いているターンが無いので捨てられる。
      if (this.notifyTurn) {
        client.notify("session/cancel", { sessionId: acpSessionId });
        this.closeNotifyTurn();
      }
      return;
    }
    this.cancelRequested = true;
    // 回答待ちの承認は cancelled で返す（ACP の規定。返さないとエージェントが待ち続ける）。
    this.cancelPendingPermissions();
    client.notify("session/cancel", { sessionId: acpSessionId });
    // 止めたターンの委任は stopped で閉じる（猶予切れの後は更新を捨てるので、終わりの知らせで閉じられない）。
    this.abandonSubagents("stopped", true);
    // cancel に応じない / 応答が遅いエージェントでも止まるよう、猶予後に今の session/prompt を待つのをやめる
    // （send() が done で畳む。後から始まったターンは対象にしない）。
    const targets = [...this.abandoners];
    setTimeout(() => {
      for (const abandon of targets) abandon();
    }, AcpSession.interruptGraceMs).unref();
  }

  async close(): Promise<void> {
    this.closed = true;
    for (const abandon of this.abandoners) abandon();
    this.cancelPendingPermissions();
    // プロセスごと閉じるので、実行中の委任の行は stopped で閉じる。
    this.abandonSubagents("stopped", false);
    this.watcher?.stop();
    this.closeNotifyTurn();
    this.client?.close();
    if (this.mainToken) orchestrator.revoke(this.mainToken);
    this.mainToken = undefined;
  }

  /**
   * サブエージェントのカードの全行（workflow_snapshot。行が無くても agents: []）。接続したときと turn_status_request の
   * ときに server が送る。
   */
  subagentSnapshot(): string | undefined {
    return this.subagents.snapshot({ includeEmpty: true });
  }

  /**
   * 実行中の委任の行を閉じて流す。もう終わりの知らせが来ない（中断・猶予切れ・プロセスの死・close・失敗で終わったターン）。
   * onlyForeground = true では、裏で動いていると分かっている行（background）を残す。
   */
  private abandonSubagents(state: string, onlyForeground: boolean, except?: ReadonlySet<string>): void {
    const p = this.subagents.abandonRunning({ state, onlyForeground, except });
    if (p) this.emit?.(event.workflowProgress(this.agentId, this.sessionId, p));
    this.pruneDelegations();
  }

  applyOverrides(overrides: SessionOverrides): void {
    this.overrides = { ...overrides };
  }

  /** iPhone の承認カードの答え。選択肢の id ならそれを選び、それ以外は取り消す。 */
  async respondToAction(requestId: string, decision: string): Promise<void> {
    const pending = this.pendingPermissions.get(requestId);
    if (!pending) return;
    this.pendingPermissions.delete(requestId);
    const outcome = pending.optionIds.includes(decision) ? { outcome: "selected", optionId: decision } : { outcome: "cancelled" };
    pending.client.respond(pending.rpcId, { outcome });
    this.emit?.({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId });
  }

  /** チャットの上書き > 無人実行の指定 > エージェント既定。 */
  private effectiveMode(): string | undefined {
    return this.overrides.mode ?? this.tuning.permissionMode ?? this.tuning.defaults?.mode;
  }

  /// 上書き・既定のモデル / Effort / モードのうち、今の値と違うものを session/set_config_option で切り替える。
  /// 優先はチャットの上書き > エージェント既定（tuning.defaults）> このセッションの既定（baseline）。
  /// その agent が持っていない項目・選択肢に無い値は送らない（送ると prompt ごと失敗する agent がある。mac と同じ）。
  private async applyConfigForTurn(): Promise<void> {
    const changes: Array<[string, string]> = [];
    const want = (id: string | undefined, value: string | undefined, options: ConfigOption[], current: string | undefined): void => {
      if (!id || !value || options.length === 0) return;
      const matched = matchConfigOption(value, options);
      if (matched && matched !== current) changes.push([id, matched]);
    };
    want(this.modelConfigId, this.overrides.model ?? this.tuning.defaults?.model ?? this.baseline.model, this.modelOptions, this.modelCurrent);
    want(
      this.effortConfigId,
      this.overrides.reasoningEffort ?? this.tuning.defaults?.reasoningEffort ?? this.baseline.effort,
      this.effortOptions,
      this.effortCurrent
    );
    // モードは BuddyOS の値。tuning の対応表（cursor 等）→ 同じ名前 → OpenCode 向けの読み替えの順。指定が無ければ既定に戻す。
    const mode = this.effectiveMode();
    const map = this.tuning.modeConfigValues;
    const modeValue = mode
      ? map
        ? (map[mode] ?? map["*"])
        : (matchConfigOption(mode, this.modeOptions) ?? matchConfigOption(ACP_MODE_FALLBACK[mode] ?? "", this.modeOptions))
      : this.baseline.mode;
    want(this.modeConfigId, modeValue, this.modeOptions, this.modeCurrent);
    for (const [id, value] of changes) {
      try {
        await this.setConfigOption(id, value, false);
      } catch (error) {
        process.stderr.write(`[${this.agentId}-acp:${this.runtime.kind}] set ${id}=${value} failed: ${errorMessage(error)}\n`);
      }
    }
  }

  /** 回答待ちの承認をすべて cancelled で返し、iPhone のカードを閉じさせる。 */
  private cancelPendingPermissions(): void {
    for (const [requestId, pending] of [...this.pendingPermissions]) {
      this.pendingPermissions.delete(requestId);
      pending.client.respond(pending.rpcId, { outcome: { outcome: "cancelled" } });
      this.emit?.({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId });
    }
  }

  /// ターンを失敗で終える。error に続けて done も出す（mac の AcpSession.finishPrompt と同じ）。
  private failTurn(emit: Emit, message: string): void {
    // 失敗で終わったターンの委任には、もう終わりの知らせが来ない。
    const p = this.subagents.abandonRunning({ state: "failed", onlyForeground: true });
    if (p) emit(event.workflowProgress(this.agentId, this.sessionId, p));
    emit(event.error(this.agentId, this.sessionId, message));
    emit(event.done(this.agentId, this.sessionId, crypto.randomUUID()));
  }

  /// 死んだ / 起動に失敗した client を捨てて、次の send() で起こし直せる状態に戻す。
  /// sessionId は解決済みの実 ID のまま残すので、再 bootstrap は session/load に進み会話を復元する。
  private resetClient(): void {
    // 死んだプロセスへの答えは届かない。iPhone に残った承認カードを閉じる。
    for (const requestId of this.pendingPermissions.keys()) {
      this.emit?.({ type: "action_resolved", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId });
    }
    this.pendingPermissions.clear();
    // 委任の先もプロセスと一緒に止まった（Hermes・Grok の子はプロセスの中で動く）。異常終了なので failed で閉じる。
    // OpenClaw の子は gateway で動き続けるので、その行は閉じずに台帳を見続ける。
    this.abandonSubagents("failed", false, this.survivingRows());
    this.closeNotifyTurn();
    this.client?.removeAllListeners();
    this.client = undefined;
    this.acpSessionId = undefined;
    this.bootstrapped = false;
    this.currentMessageId = undefined;
    this.toolStartTimes.clear();
    this.toolNames.clear();
  }

  private async bootstrap(emit: Emit): Promise<void> {
    if (this.bootstrapped && this.client?.alive) return;
    // ACP プロセスが落ちた（クラッシュ・`wsl --shutdown`・スリープ復帰での WSL VM 終了等）。
    // bootstrapped のまま死んだ client を使い続けると、以後の request が即 reject され続けて復旧しない。
    if (this.client && !this.client.alive) this.resetClient();
    const client = new JsonRpcProcess(this.runtime, this.args, this.agentCwd, this.env);
    this.client = client;
    client.on("stderr", (chunk) => process.stderr.write(`[${this.agentId}-acp:${this.runtime.kind}] ${chunk}`));
    // 初回 send の emit を閉じ込めると、再接続後のターンの delta が閉じた旧接続に流れる。
    // 呼ばれた時点の this.emit（最後に send した接続）を使う。
    client.on("notification", (message) => {
      // 並行 bootstrap で置き換えられた client の通知は捨てる（prompt は常に this.client に投げる）。
      if (client !== this.client) return;
      const current = this.emit;
      if (current) this.handleNotification(message as Record<string, unknown>, current);
    });
    // 購読すると JsonRpcProcess は -32601 を自動で返さなくなるので、handleAgentRequest は全メソッドに応答する。
    client.on("request", (message) => this.handleAgentRequest(client, message as Record<string, unknown>));
    // プロセスが落ちた（クラッシュ・`wsl --shutdown` 等）。委任の先も一緒に止まったので、実行中の行を failed で閉じる
    // （ターンの途中なら session/prompt の失敗でも閉じる）。close() で止めたときは先に stopped で閉じてある。
    client.on("close", () => {
      if (client === this.client && !this.closed) {
        this.abandonSubagents("failed", false, this.survivingRows());
        this.closeNotifyTurn();
      }
    });

    try {
      await this.startSession(client, emit);
    } catch (error) {
      // initialize / session/new 等の途中で失敗した client は閉じて捨てる（残すとプロセスがリークし、
      // bootstrapped=false のまま次の send がもう 1 本起動する）。次の send で起こし直す。
      if (this.client === client) this.resetClient();
      client.close();
      throw error;
    }
  }

  private async startSession(client: JsonRpcProcess, emit: Emit): Promise<void> {
    const init = await client.request("initialize", {
      protocolVersion: 1,
      clientInfo: { name: "BuddyOS Windows Bridge", version: "0.1.0" },
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } }
    }, 15000);
    if (init.error) throw new Error(JSON.stringify(init.error));
    this.mcpServers = this.mainagentMcpServers(asObject(init.result));

    const shouldLoad = !this.sessionId.startsWith("pending-");
    // mainagent のときは session/new・load の中でエージェントが Bridge の MCP（stdio の中継なら子プロセス）につなぐので、
    // mac と同じ長さ（new 60 秒・load 120 秒）まで待つ。hermes は自分の MCP サーバも全部つないでから返す（実測 15 秒超）。
    const newTimeout = this.mcpServers.length > 0 ? 60_000 : 15000;
    const loadTimeout = this.mcpServers.length > 0 ? 120_000 : 15000;
    let sessionResponse: Record<string, unknown>;
    if (shouldLoad) {
      // ACP の session/load は応答前に会話全体を session/update で replay してくる。
      // ライブの delta/tool として流さないよう、応答が返るまでゲートを閉じる。
      // 通知は行順に同期 dispatch されるので、応答前の replay は await 再開前に処理済み。
      // load 失敗 → session/new のフォールバックや throw でも必ず開け直す。
      this.loadsInFlight += 1;
      try {
        sessionResponse = await client.request("session/load", this.sessionParams({
          sessionId: this.sessionId,
        }), loadTimeout).catch(async () => client.request("session/new", this.sessionParams(), newTimeout));
      } finally {
        this.loadsInFlight -= 1;
      }
    } else {
      sessionResponse = await client.request("session/new", this.sessionParams(), newTimeout);
    }

    if (sessionResponse.error) throw new Error(JSON.stringify(sessionResponse.error));
    const result = asObject(sessionResponse.result);
    this.captureConfigOptions(result.configOptions);
    // プロセスを起こし直したら、その時点の値が既定（前のプロセスで切り替えた上書きは引き継がれない）。
    this.baseline = { model: this.modelCurrent, mode: this.modeCurrent, effort: this.effortCurrent };
    const resolvedSessionId = stringValue(result.sessionId) ?? stringValue(result.id) ?? this.sessionId;
    this.store.replaceSessionId(this.agentId, this.sessionId, resolvedSessionId, this.cwd);
    this.sessionId = resolvedSessionId;
    this.acpSessionId = resolvedSessionId;
    this.bootstrapped = true;
    emit(event.sessionStarted(this.agentId, this.sessionId));
  }

  /**
   * mainagent のフォルダ・設定 allSessions のときのふつうのセッションに、Bridge の MCP を渡す（mac の AcpSession.mainagentMcpServers と同じ）。書く道具は外せないので、
   * 決まりは AGENTS.md だけ。initialize の agentCapabilities.mcpCapabilities.http が true なら /mcp を直接、そうでなければ
   * stdio の中継（この Bridge を mcp-stdio-relay で起こす。合鍵と番号は env）。WSL で動くエージェントは、WSL から 127.0.0.1 で
   * Windows の Bridge に届かないことがある（WSL2 の NAT）ので、http を申告していても中継（Windows の node.exe）を使う。
   */
  private mainagentMcpServers(initResult: Record<string, unknown>): Array<Record<string, unknown>> {
    if (!this.mcpPlan) return [];
    const transport = acpMainAgentTransport(initResult, this.runtime.kind, relayCommand());
    if (!transport) return [];
    if (this.mainToken) orchestrator.revoke(this.mainToken);
    const token = orchestrator.issueToken(this.agentId, this.sessionId.startsWith("pending-") ? undefined : this.sessionId, this.mcpPlan);
    orchestrator.bind(token, this);
    this.mainToken = token;
    const port = mainAgentPort();
    return [transport === "http" ? acpHttpServer(token, port) : acpStdioRelayServer(token, port, transport.stdio, this.runtime.kind)];
  }

  private sessionParams(extra: Record<string, unknown> = {}): Record<string, unknown> {
    const params: Record<string, unknown> = { ...extra, mcpServers: this.mcpServers };
    if (this.agentCwd) params.cwd = this.agentCwd;
    return params;
  }

  /// result.configOptions（`[{id,category,type,currentValue,options:[{value,name}]}]`）から
  /// model / mode / effort の現在値と選択肢を抽出する。configOptions が無いエージェント
  /// (Hermes/OpenClaw) では何も起きない。
  private captureConfigOptions(raw: unknown): void {
    if (!Array.isArray(raw)) return;
    for (const item of raw) {
      const option = asObject(item);
      const id = stringValue(option.id);
      if (!id) continue;
      const current = stringValue(option.currentValue);
      const choices = (Array.isArray(option.options) ? option.options : [])
        .map(asObject)
        .map((choice) => {
          const value = stringValue(choice.value);
          if (value === undefined) return undefined;
          return { value, name: stringValue(choice.name) ?? value };
        })
        .filter((choice): choice is ConfigOption => choice !== undefined);
      const category = stringValue(option.category);
      if (id === "model" || category === "model") {
        this.modelConfigId = id;
        this.modelCurrent = current;
        this.modelOptions = choices;
      } else if (id === "mode" || category === "mode") {
        this.modeConfigId = id;
        this.modeCurrent = current;
        this.modeOptions = choices;
      } else if (id === "effort" || id === "reasoning_effort" || category === "thought_level") {
        this.effortConfigId = id;
        this.effortCurrent = current;
        this.effortOptions = choices;
      }
    }
  }

  /// session/set_config_option を投げ、返ってきた configOptions で現在値を更新する。
  /// 汎用名 `{configId, value}` を使う（typed alias の modelId/modeId 揺れを避けるため）。
  async setConfigOption(configId: string, value: string, asDefault = true): Promise<void> {
    const client = this.client;
    const acpSessionId = this.acpSessionId;
    // 死んだ client に投げても応答は来ない（即 reject されるだけ）ので、開き直しを促す。
    if (!client || !acpSessionId || !client.alive) {
      throw new Error("チャットを開いてから切り替えてください");
    }
    const response = await client.request("session/set_config_option", {
      sessionId: acpSessionId,
      configId,
      value
    }, 30000);
    if (response.error) throw new Error(JSON.stringify(response.error));
    this.captureConfigOptions(asObject(response.result).configOptions);
    // 全体の切り替え（set_model_request）はこのセッションの既定も変える。チャットの上書きの反映は変えない。
    if (asDefault) {
      if (configId === "model" || configId === this.modelConfigId) this.baseline.model = value;
      else if (configId === "mode" || configId === this.modeConfigId) this.baseline.mode = value;
      else if (configId === "effort" || configId === this.effortConfigId) this.baseline.effort = value;
    }
  }

  /// エージェント → クライアントの要求に応答する（応答しないとエージェントは待ち続け、session/prompt が
  /// 戻らない）。session/request_permission は iOS へ中継する経路が無い
  /// （ACP 系は actions 非対応）ので、拒否の選択肢を選んで即答する（mac は -32601 で断っている）。
  /// interrupt 後の要求は ACP の規定どおり cancelled で返す。未知のメソッドは -32601。
  private handleAgentRequest(client: JsonRpcProcess, message: Record<string, unknown>): void {
    const id = message.id as number | string;
    const method = stringValue(message.method) ?? "";
    if (method !== "session/request_permission") {
      client.respondError(id, -32601, `Method not found: ${method}`);
      return;
    }
    const params = asObject(message.params);
    const options = (Array.isArray(params.options) ? params.options : []).map(asObject);
    if (this.tuning.approvals) {
      this.askPermission(client, id, params, options);
      return;
    }
    const reject = options.find((o) => o.kind === "reject_once") ?? options.find((o) => o.kind === "reject_always");
    const optionId = stringValue(reject?.optionId);
    const outcome = !this.cancelRequested && optionId ? { outcome: "selected", optionId } : { outcome: "cancelled" };
    const title = stringValue(asObject(params.toolCall).title) ?? "";
    process.stderr.write(`[${this.agentId}-acp:${this.runtime.kind}] permission request ${optionId && !this.cancelRequested ? "rejected" : "cancelled"}: ${title}\n`);
    client.respond(id, { outcome });
  }

  /// session/request_permission を iPhone の承認カードにする（mac の AcpSession.handlePermissionRequest と同じ）。
  /// モードで答えが決まるもの（Dangerous は全部許可・Edit は編集だけ許可・無人実行は拒否）はその場で返す。
  private askPermission(client: JsonRpcProcess, id: number | string, params: Record<string, unknown>, raw: Array<Record<string, unknown>>): void {
    const options = raw
      .map((o) => ({ id: stringValue(o.optionId) ?? "", name: stringValue(o.name) ?? stringValue(o.optionId) ?? "", kind: stringValue(o.kind) ?? "" }))
      .filter((o) => o.id);
    const toolCall = asObject(params.toolCall);
    if (options.length === 0 || this.cancelRequested) {
      client.respond(id, { outcome: { outcome: "cancelled" } });
      return;
    }
    const decided = autoPermissionAnswer(this.effectiveMode(), stringValue(toolCall.kind), this.tuning.unattended === true, options);
    if (decided !== undefined) {
      client.respond(id, { outcome: decided ? { outcome: "selected", optionId: decided } : { outcome: "cancelled" } });
      return;
    }
    const emit = this.emit;
    if (!emit) {
      client.respond(id, { outcome: { outcome: "cancelled" } });
      return;
    }
    const requestId = crypto.randomUUID();
    const title = stringValue(toolCall.title) ?? `${this.agentId} の承認`;
    const metadata: Record<string, string> = { requestId, kind: "approval", title, option_count: String(options.length), allowsOther: "0" };
    const subtitle = stringValue(asObject(toolCall.rawInput).command);
    if (subtitle) metadata.subtitle = subtitle;
    options.forEach((option, i) => {
      metadata[`option_${i}_title`] = option.name;
      metadata[`option_${i}_value`] = option.id;
    });
    this.pendingPermissions.set(requestId, { rpcId: id, optionIds: options.map((o) => o.id), client });
    emit({ type: "action_request", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId, content: title, metadata });
  }

  private handleNotification(message: Record<string, unknown>, emit: Emit): void {
    const method = message.method;
    const xai = this.tuning.xaiNotifications === true && (method === "_x.ai/session_notification" || method === "_x.ai/queue/changed");
    if (method !== "session/update" && !xai) return;
    const params = asObject(message.params);
    const update = asObject(params.update);
    const kind = stringValue(update.sessionUpdate) ?? stringValue(update.kind) ?? stringValue(update.type);

    // 今のセッション以外の通知は親の出力にしない（session/load が timeout して session/new に切り替えた後の旧セッションの replay や、
    // Grok の子のセッションの更新）。acpSessionId は session/new・load の返事で決まるので、それまでは絞らない。
    const sid = stringValue(params.sessionId);
    if (sid && this.acpSessionId && sid !== this.acpSessionId) {
      // Grok の子の tool_call の title だけは、その行のいまの作業にする。
      if (this.tuning.xaiNotifications && method === "session/update" && kind === "tool_call") this.childToolCall(sid, update, emit);
      return;
    }

    if (method === "_x.ai/queue/changed") {
      if (this.loadsInFlight === 0) this.xaiQueueChanged(params, emit);
      return;
    }
    if (method === "_x.ai/session_notification") {
      if (this.loadsInFlight === 0) this.xaiNotification(kind, update, emit);
      return;
    }

    if (kind === "available_commands_update") {
      // OpenCode は built-ins とユーザの skills を commands として push する。
      // session/load の replay 中でも届くので、トランスクリプト gate とは無関係に
      // 常にキャプチャする（loadsInFlight のゲートより前で処理する）。
      const list = Array.isArray(update.availableCommands) ? update.availableCommands : [];
      this.commands = list
        .map(asObject)
        .map((entry) => ({
          name: stringValue(entry.name) ?? "",
          description: stringValue(entry.description) ?? ""
        }))
        .filter((entry) => entry.name.length > 0);
      this.onCommandsChanged?.(this.commands);
      return;
    }

    // session/load の replay 中は捨てる（過去の発言・ツールを今回の返答として再表示しない）。
    if (this.loadsInFlight > 0) return;
    // 起こされたターン（Grok の知らせのターン）の更新。発言は知らせのターンの吹き出しにし、ツールだけ下の普通の経路で扱う。
    // 停止の猶予切れの後（discardingStale）でも、開いている知らせのターンの更新は捨てない（BACKGROUND_CONTROL §4.4）。
    const promptId = stringValue(asObject(params._meta).promptId);
    let notifyTool = false;
    if (this.tuning.xaiNotifications && promptId && isNotifyPrompt(promptId)) {
      if (this.notifyTurn?.promptId !== promptId) return;
      if (kind === "agent_message_chunk" || kind === "agent_thought_chunk") {
        const text = extractText(update.content);
        if (!text) return;
        const turn = this.notifyTurn;
        if (kind === "agent_thought_chunk") {
          emit(event.activity(this.agentId, this.sessionId, turn.bubbleId ?? turn.messageId, text));
        } else {
          turn.bubbleId ??= crypto.randomUUID();
          turn.hadBody = true;
          this.notifyText += text;
          emit(event.assistantDelta(this.agentId, this.sessionId, turn.bubbleId, text));
        }
        return;
      }
      if (kind !== "tool_call" && kind !== "tool_call_update") return;
      notifyTool = true;
      // ツールの前までの発言は 1 つの吹き出しとして閉じ、後の発言は新しい吹き出しにする。
      if (kind === "tool_call") this.endNotifyBubble();
    } else if (this.discardingStale) {
      // 停止の猶予切れで畳んだ旧ターンの残り。done の後に流すとクライアントが「考え中」に戻る。
      return;
    }

    if (kind === "agent_message_chunk") {
      const text = extractText(update.content);
      if (!text) return;
      if (!this.currentMessageId) this.currentMessageId = crypto.randomUUID();
      this.assistantBuffer += text;
      emit(event.assistantDelta(this.agentId, this.sessionId, this.currentMessageId, text));
      return;
    }

    if (kind === "agent_thought_chunk") {
      const text = extractText(update.content);
      if (!text) return;
      emit(event.activity(this.agentId, this.sessionId, this.currentMessageId ?? "pending-thought", text));
      return;
    }

    if (kind === "tool_call" || kind === "tool_call_update") {
      const toolCallId = stringValue(update.toolCallId);
      if (kind === "tool_call" && toolCallId) this.noteGrokSpawn(toolCallId, update);
      // 受領票が非同期の委任を示したら、行は running のまま（ツールの行だけ下で閉じる）。
      const asynchronous = kind === "tool_call_update" && toolCallId !== undefined && this.acceptReceipt(toolCallId, update, emit);
      if (!asynchronous) {
        // 委任かどうか（title の「<tool>: …」は先頭の識別子にそろえる）、後の更新で届く説明と種類の埋め直し（opencode acp は
        // pending の tool_call では title も rawInput も空）、opencode の `<task …>` の出力の取り出しは SubagentTracker に任せる。
        // 状態の無い tool_call_update は終わりではない（トラッカーは行を閉じず、埋め直しだけ）。
        const background = toolCallId !== undefined && this.delegations.get(toolCallId)?.background === true;
        const subagentJson = this.subagents.ingestAcpUpdate(update, background ? { background: true } : {});
        if (subagentJson) emit(event.workflowProgress(this.agentId, this.sessionId, subagentJson));
      }
    }

    if (kind === "tool_call") {
      const toolUseId = stringValue(update.toolCallId) ?? crypto.randomUUID();
      const title = stringValue(update.title) ?? "";
      const toolKind = stringValue(update.kind) ?? "other";
      const toolName = toolNameFromTitle(title, toolKind);
      this.toolStartTimes.set(toolUseId, Date.now());
      this.toolNames.set(toolUseId, toolName);
      if (!notifyTool) {
        if (this.currentMessageId) emit(event.assistantTurnEnd(this.agentId, this.sessionId, this.currentMessageId));
        this.currentMessageId = undefined;
      }
      emit(event.toolStart(this.agentId, this.sessionId, toolUseId, toolName, title, toolKind));
      return;
    }

    if (kind === "tool_call_update") {
      const toolUseId = stringValue(update.toolCallId);
      if (!toolUseId) return;
      // 状態の無い更新は、既定ではツールの終わりとみなす（Grok は title の埋め直しだけなので閉じない）。
      const rawStatus = stringValue(update.status);
      if (rawStatus === undefined && this.tuning.statuslessUpdateEndsTool === false) return;
      const status = rawStatus ?? "completed";
      if (status !== "completed" && status !== "failed") return;
      const toolName = this.toolNames.get(toolUseId) ?? "";
      const startedAt = this.toolStartTimes.get(toolUseId);
      this.toolStartTimes.delete(toolUseId);
      this.toolNames.delete(toolUseId);
      emit(event.toolEnd(this.agentId, this.sessionId, toolUseId, toolName, status, extractToolSummary(update.content), startedAt ? Date.now() - startedAt : undefined));
    }
  }

  // ---- 非同期の委任（BACKGROUND_CONTROL §5） ----

  /** Grok の spawn_subagent の tool_call。背景かどうかと説明を覚える（subagent_spawned を行に結ぶ）。 */
  private noteGrokSpawn(toolCallId: string, update: Record<string, unknown>): void {
    if (!this.tuning.xaiNotifications) return;
    const meta = asObject(update._meta);
    if (stringValue(asObject(meta["x.ai/tool"]).name) !== "spawn_subagent") return;
    const input = asObject(update.rawInput);
    this.delegations.set(toolCallId, {
      kind: "grok",
      background: meta.subagentBackground === true || input.background === true,
      label: stringValue(input.description)
    });
  }

  /**
   * tool_call_update の completed が非同期の委任の受領票なら、鍵を覚えて true（行は running のまま、結果を上書きしない）。
   * 台帳は受領票の直後の 1 回目の読み取りで読めるか決める（読めなければ受領票の文で done にする）。
   */
  private acceptReceipt(toolCallId: string, update: Record<string, unknown>, emit: Emit): boolean {
    if (stringValue(update.status) !== "completed") return false;
    const text = extractText(update.content);
    const grok = this.delegations.get(toolCallId);
    if (grok?.kind === "grok") {
      const key = grok.background ? grokReceiptKey(text) : undefined;
      if (!key) return false;
      // 子の終わりの知らせが先に来て閉じていたら、受領票の文で結果を上書きしない。
      if (this.subagents.isRunning(toolCallId)) grok.key = key;
      return true;
    }
    const ledger = this.tuning.delegationLedger;
    if (!ledger || !this.subagents.isRunning(toolCallId)) return false;
    const tool = normalizedToolName(this.toolNames.get(toolCallId) ?? "").toLowerCase();
    let key: string | undefined;
    let taskCount: number | undefined;
    if (ledger === "hermes" && tool === "delegate_task") {
      const receipt = hermesReceipt(text);
      key = receipt?.key;
      taskCount = receipt?.taskCount;
    } else if (ledger === "openclaw" && tool === "sessions_spawn") {
      key = openclawReceipt(asObject(update.rawOutput).details, text)?.key;
    }
    if (!key) return false;
    this.delegations.set(toolCallId, { kind: ledger, background: true, key, receipt: text ?? "" });
    const p = this.subagents.begin(toolCallId, undefined, { background: true, taskCount });
    if (p) emit(event.workflowProgress(this.agentId, this.sessionId, p));
    this.watchLedger(ledger, key);
    return true;
  }

  private watchLedger(kind: LedgerKind, key: string): void {
    this.watcher ??= new LedgerWatcher(() => createLedgerReader(kind, this.runtime), {
      row: (k, row) => this.onLedgerRow(k, row),
      unreadable: (k) => this.onLedgerUnreadable(k)
    });
    this.watcher.add(key);
  }

  private rowForKey(key: string, kind?: Delegation["kind"]): string | undefined {
    for (const [id, d] of this.delegations) if (d.key === key && (kind === undefined || d.kind === kind) && this.subagents.isRunning(id)) return id;
    return undefined;
  }

  /** 台帳の行。running は作業の文か回数が変わったときだけ流し、終わりは行を閉じる（最後の背景の行なら silent の done）。 */
  private onLedgerRow(key: string, row: LedgerRow): void {
    const id = this.rowForKey(key);
    if (!id) {
      this.watcher?.remove(key);
      return;
    }
    const d = this.delegations.get(id)!;
    let p: string | undefined;
    if (row.state === "running") {
      const shown = `${row.text ?? ""}|${row.toolCalls ?? ""}`;
      if ((row.text === undefined && row.toolCalls === undefined) || shown === d.shown) return;
      d.shown = shown;
      p = this.subagents.activity(id, row.text, { toolCalls: row.toolCalls });
    } else {
      p = this.subagents.finish(id, row.state, row.result, row.durationMs);
      this.delegations.delete(id);
    }
    if (p) this.emit?.(event.workflowProgress(this.agentId, this.sessionId, p));
    if (row.state !== "running") this.backgroundClosed(false);
  }

  /** 台帳が読めない（1 回目で・30 回続けて）。今まで通り、受領票の文で行を done にする（知らせの done は出さない）。 */
  private onLedgerUnreadable(key: string): void {
    const id = this.rowForKey(key);
    if (!id) return;
    const d = this.delegations.get(id)!;
    this.delegations.delete(id);
    const p = this.subagents.finish(id, "done", d.receipt);
    if (p) this.emit?.(event.workflowProgress(this.agentId, this.sessionId, p));
    // 最後の背景の行なら silent の done（受領票のターンの最中は promptsInFlight で出ない）。
    this.backgroundClosed(false);
  }

  /** 動いている背景の委任の行の数 */
  private runningBackgroundDelegations(): number {
    let n = 0;
    for (const [id, d] of this.delegations) if (d.background && this.subagents.isRunning(id)) n += 1;
    return n;
  }

  /**
   * 背景の委任の行が閉じた。最後の行で、起こされたターンが来ず（willWake == false）、実行中の session/prompt も開いている
   * 知らせのターンも無ければ、本文の無い知らせのターンの done を 1 つ出す（SessionHub の push とアプリの silent の done が使う）。
   */
  private backgroundClosed(willWake: boolean): void {
    if (willWake || this.notifyTurn || this.promptsInFlight > 0 || this.runningBackgroundDelegations() > 0) return;
    this.emit?.({
      ...event.done(this.agentId, this.sessionId, crypto.randomUUID()),
      metadata: { origin: "task-notification", silent: "1" }
    });
  }

  /** 終わった行を忘れ、閉じた行の台帳の見張りを止める。 */
  private pruneDelegations(): void {
    for (const [id, d] of this.delegations) {
      if (this.subagents.isRunning(id)) continue;
      this.delegations.delete(id);
      if (d.key) this.watcher?.remove(d.key);
    }
  }

  /** プロセスが落ちても台帳を見続ける行（OpenClaw の子は gateway で動き続ける）。 */
  private survivingRows(): Set<string> {
    const keep = new Set<string>();
    for (const [id, d] of this.delegations) if (d.kind === "openclaw" && d.key) keep.add(id);
    return keep;
  }

  // ---- Grok の _x.ai/* ----

  private grokRow(key: string | undefined): string | undefined {
    return key ? this.rowForKey(key, "grok") : undefined;
  }

  private xaiNotification(kind: string | undefined, update: Record<string, unknown>, emit: Emit): void {
    const flush = (p: string | undefined): void => {
      if (p) emit(event.workflowProgress(this.agentId, this.sessionId, p));
    };
    const key = stringValue(update.subagent_id);
    switch (kind) {
      case "subagent_spawned": {
        if (!key) return;
        const id = this.grokRow(key) ?? this.bindGrokSpawn(key, stringValue(update.description));
        if (!id) return;
        const d = this.delegations.get(id)!;
        d.key = key;
        d.child = stringValue(update.child_session_id) ?? d.child;
        flush(this.subagents.begin(id, undefined, { agentType: stringValue(update.subagent_type), model: stringValue(update.model) }));
        return;
      }
      case "subagent_progress": {
        const id = this.grokRow(key);
        if (!id) return;
        const tools = Array.isArray(update.tools_used) ? update.tools_used : [];
        flush(this.subagents.activity(id, stringValue(tools.at(-1)), { toolCalls: numberValue(update.tool_call_count), tokens: numberValue(update.tokens_used) }));
        return;
      }
      case "subagent_finished": {
        const id = this.grokRow(key);
        if (!id) return;
        const d = this.delegations.get(id)!;
        flush(this.subagents.activity(id, undefined, { toolCalls: numberValue(update.tool_calls), tokens: numberValue(update.tokens_used) }));
        flush(this.subagents.finish(id, grokFinishedState(stringValue(update.status)), stringValue(update.output), numberValue(update.duration_ms)));
        // 受領票が遅れて届いても結果を上書きしないよう、Grok の行は残す（次の send() の pruneDelegations で消える）。
        if (d.background) this.backgroundClosed(update.will_wake === true);
        return;
      }
      case "turn_completed": {
        if (this.notifyTurn && stringValue(update.prompt_id) === this.notifyTurn.promptId) this.closeNotifyTurn();
        return;
      }
      default:
        return;
    }
  }

  /** subagent_spawned を、鍵の無い spawn の行に結ぶ。前景の spawn も含め、説明が一致する最も古い行、無ければ鍵の無い最も古い行。 */
  private bindGrokSpawn(key: string, description: string | undefined): string | undefined {
    const open = [...this.delegations].filter(([id, d]) => d.kind === "grok" && d.key === undefined && this.subagents.isRunning(id));
    const hit = open.find(([, d]) => description !== undefined && d.label === description) ?? open[0];
    return hit?.[0];
  }

  /** 子のセッションの tool_call の title を、その行のいまの作業にする。 */
  private childToolCall(sid: string, update: Record<string, unknown>, emit: Emit): void {
    const title = stringValue(update.title);
    if (!title) return;
    for (const [id, d] of this.delegations) {
      if (d.child !== sid || !this.subagents.isRunning(id)) continue;
      const p = this.subagents.activity(id, title);
      if (p) emit(event.workflowProgress(this.agentId, this.sessionId, p));
    }
  }

  /** 起こされたターンを開く（runningPromptId が subagent-completed- か task-completed-）。 */
  private xaiQueueChanged(params: Record<string, unknown>, emit: Emit): void {
    const promptId = stringValue(params.runningPromptId);
    const runningKind = stringValue(params.runningKind);
    if (!promptId || !isNotifyPrompt(promptId) || (runningKind !== undefined && runningKind !== "prompt") || this.seenNotifyPrompts.has(promptId)) return;
    this.seenNotifyPrompts.add(promptId);
    // Grok は prompt を 1 つずつ動かす。前の知らせのターンが開いたままなら、終わりが届かなかったので閉じてから開く。
    this.closeNotifyTurn();
    const messageId = crypto.randomUUID();
    this.notifyTurn = { promptId, messageId, bubbleId: messageId, hadBody: false };
    this.notifyText = "";
    // 空の activity で、SessionHub とアプリが生成中とみなす（runningText の system-reminder は発言にしない）。
    emit(event.activity(this.agentId, this.sessionId, messageId, ""));
  }

  /** 知らせのターンの開いている吹き出しを、本文があれば履歴に残して閉じる。 */
  private endNotifyBubble(): void {
    const turn = this.notifyTurn;
    if (!turn) return;
    const text = this.notifyText;
    this.notifyText = "";
    const bubbleId = turn.bubbleId;
    turn.bubbleId = undefined;
    if (text.trim() === "" || !bubbleId) return;
    this.store.appendMessage(this.agentId, this.sessionId, "assistant", text, this.cwd, bubbleId);
    this.emit?.(event.assistantTurnEnd(this.agentId, this.sessionId, bubbleId));
  }

  /** 知らせのターンを閉じる。本文は履歴に残し、done に origin = task-notification を付ける（本文が無ければ silent）。 */
  private closeNotifyTurn(): void {
    const turn = this.notifyTurn;
    if (!turn) return;
    this.endNotifyBubble();
    this.notifyTurn = undefined;
    const metadata: Record<string, string> = { origin: "task-notification" };
    if (!turn.hadBody) metadata.silent = "1";
    this.emit?.({ ...event.done(this.agentId, this.sessionId, turn.messageId), metadata });
  }
}

function grokFinishedState(status: string | undefined): string {
  switch (status) {
    case "completed":
      return "done";
    case "cancelled":
    case "killed":
    case "stopped":
    case "interrupted":
      return "stopped";
    default:
      return "failed";
  }
}

/** 非同期の委任の行（キーは tool の toolCallId = 行の鍵）。Grok は前景の spawn も持つ。 */
interface Delegation {
  kind: "grok" | LedgerKind;
  /** 裏で動く（終わりが tool の呼び出しの後に来る）。 */
  background: boolean;
  /** 台帳の鍵（delegation_id / runId / subagent_id）。payload には出さない。 */
  key?: string;
  /** 台帳が読めないときに行を閉じる受領票の文 */
  receipt?: string;
  /** Grok: spawn の説明（subagent_spawned を行に結ぶ） */
  label?: string;
  /** Grok: 子のセッションの ID */
  child?: string;
  /** 動いている間に最後に送った作業の文と回数（変化の判定） */
  shown?: string;
}

/** 起こされたターン（Grok の知らせのターン）の prompt id の頭。 */
const NOTIFY_PROMPT_PREFIXES = ["subagent-completed-", "task-completed-"];
const isNotifyPrompt = (id: string): boolean => NOTIFY_PROMPT_PREFIXES.some((p) => id.startsWith(p));

/** BuddyOS のモード → ACP の mode の値（OpenCode は build / plan。完全一致が無いときだけ使う）。 */
const ACP_MODE_FALLBACK: Record<string, string> = { plan: "plan", edit: "build", auto: "build", dangerous: "build" };

/// BuddyOS 側の値（"auto" / "composer-2.5" など）を agent の選択肢の値に合わせる。
/// 完全一致 → 変種の付かない名前（"composer-2.5[fast=true]" の形）→ 表示名の順に探す（mac の matchOption と同じ）。
export function matchConfigOption(wanted: string, options: ConfigOption[]): string | undefined {
  if (!wanted) return undefined;
  if (options.some((o) => o.value === wanted)) return wanted;
  const variant = options.find((o) => o.value.split("[")[0] === wanted);
  if (variant) return variant.value;
  return options.find((o) => o.name.toLowerCase() === wanted.toLowerCase())?.value;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms).unref());
}

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function numberValue(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stringValue(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function extractText(raw: unknown): string | undefined {
  if (typeof raw === "string") return raw;
  if (Array.isArray(raw)) {
    const parts = raw.map((item) => extractText(item)).filter(Boolean);
    return parts.length > 0 ? parts.join("") : undefined;
  }
  const object = asObject(raw);
  if (typeof object.text === "string") return object.text;
  if (object.content) return extractText(object.content);
  return undefined;
}

function extractToolSummary(raw: unknown): string | undefined {
  const text = extractText(raw);
  if (!text) return undefined;
  return text.length > 400 ? `${text.slice(0, 397)}...` : text;
}

/**
 * ACP の title からツール名を作る。Hermes / OpenClaw の「<tool>: <preview>」は、preview のバッククォートより先に、
 * 先頭の識別子をツール名にする（「delegate_task:」のように記号を残すと、委任と認識できない）。
 */
export function toolNameFromTitle(title: string, fallback: string): string {
  const trimmed = title.trim();
  const head = normalizedToolName(trimmed);
  if (head && trimmed.slice(head.length).startsWith(":")) return head;
  const backtick = /`([^` ]+)/.exec(title);
  if (backtick) return backtick[1];
  const word = /[A-Za-z_][A-Za-z0-9_-]*/.exec(title);
  return word?.[0] ?? fallback;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function capitalize(value: string): string {
  if (!value) return value;
  return value.charAt(0).toUpperCase() + value.slice(1);
}
