import { AsyncLocalStorage } from "node:async_hooks";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { AgentAdapter, AgentSession, SessionOptions } from "../agents/types.js";
import { normalizeProjectPath, projectDisplayName, type ProjectItem } from "../projects.js";
import type { HistoryMessage, SessionEvent } from "../protocol.js";
import { httpRemoteTransport, type RemotePc, type RemoteTransport } from "./remoteTransport.js";
import { agentsOrWorkflows, WorkflowCardMirror } from "../workflowCardMirror.js";
import { isMainWorkspace, PROJECT_NAME } from "./workspace.js";

// mainagent（窓口のエージェント）が、Bridge の持つほかのセッションを操作するための中身（mac の Orchestrator.swift の移植）。
// 口は POST /mcp（mcpEndpoint.ts）で、道具の実体はここにある。
//
// - 合鍵: mainagent のセッションを開くたびに使い捨ての合鍵を発行し、/mcp はこれだけを受け付ける
//   （中継からも届く口なので api-key は使わない）。親のセッションが閉じたら無効。
// - 子: 頼んだセッションは server.ts の hub（OrchestratorHub）を通して購読する（iPhone からも同じセッションが見える）。
//   自分の送信は queue_dispatched の clientMessageId で見分け、そこから done までを 1 ターンとして集める。
//
// どのセッションからも頼める・別の PC に頼む・全部の PC の一覧:
// - 設定 allSessions（既定は有効）なら、mainagent のフォルダ以外のセッションにも合鍵と MCP を渡す（planFor / grantFor）。
//   書く道具を外す・権限モードを default に固定するのは mainagent のフォルダだけ（adapter が McpGrant.main を見る）。
// - 合鍵ごとに深さ（depth）を持つ。利用者が開いたセッションは 0、道具で起こした・頼んだ子は呼んだ側 + 1。
//   子を開くとき depth < MAX_DEPTH なら合鍵を渡す（opening の AsyncLocalStorage で adapter の openSession に伝える）。
// - 道具に pc（別の PC）が付いたら、デスクトップが渡した中継口へ /device/orchestrator/<tool> を送る（forward）。
//   B 側の口は meshRoutes.ts。B では呼んだ側を端末（deviceKeyId）と capMode / depth / caller で表す（RemoteCaller）。

// ---- server.ts が渡す口 ----

/** 動いているセッション（mainagent の list_sessions・/device/sessions/summary 用）。 */
export interface LiveSessionInfo {
  agentId: string;
  sessionId: string;
  /** 開いたときの作業フォルダ（resume で cwd が渡らなかったものは undefined）。 */
  cwd?: string;
  generating: boolean;
  queued: number;
  /** 承認・質問への答えを待っているか（/device/sessions/summary の needs_approval）。 */
  awaiting?: boolean;
  /** 最後に出来事があった時刻（ミリ秒）。 */
  updatedAtMs?: number;
}

/** この PC（list_pcs の先頭・/device/sessions/summary の pc）。 */
export interface PcInfo {
  bridgeId: string;
  name: string;
  platform: string;
}

/** hub を購読した 1 本（iPhone の WS 接続と同じ扱い）。 */
export interface HubSubscription {
  /** 購読しているセッション（id は pending-xxx → 実 id に変わる）。 */
  readonly session: AgentSession;
  /** まだ購読していて、そのセッションが開いたままか。 */
  holds(): boolean;
  /**
   * iPhone 以外（mainagent）からの送信。空いていれば queue_dispatched を配ってすぐ送り（sent）、作業中なら予約に積む（queued。
   * done の後に hub が送り、そのとき queue_dispatched を配る）。セッションが無ければ missing。
   */
  submit(clientMessageId: string, content: string): "sent" | "queued" | "missing";
  /** 購読を外す（ほかに誰も見ていなければ、猶予の後に hub が閉じる）。 */
  release(): void;
}

export interface OrchestratorHub {
  adapter(agentId: string): AgentAdapter | undefined;
  adapters(): AgentAdapter[];
  probe(agentId: string): Promise<{ installed: boolean; configured: boolean }>;
  projects(): ProjectItem[];
  /** セッションを開いて（あれば使って）購読する。send には、そのセッションの出来事が届いた順に同期で届く。 */
  acquire(
    agentId: string,
    sessionId: string | undefined,
    cwd: string | undefined,
    send: (evt: SessionEvent) => void,
    /** まだ開いていないセッションを開くときの指定（定期チェックの無人・印）。開いているものはそのまま使う。 */
    options?: SessionOptions
  ): Promise<HubSubscription>;
  /** Bridge 自身が出す出来事（mainagent の承認カードなど）を、そのセッションを見ている全員へ配る（記録し、誰も見ていなければ承認要求は push）。 */
  emitExternal(agentId: string, sessionId: string, evt: SessionEvent): void;
  snapshot(): LiveSessionInfo[];
  /** ターミナルで開いている Claude Code。 */
  terminal(): Array<{ sessionId: string; cwd?: string; generating: boolean; awaiting?: boolean; updatedAtMs?: number }>;
  /** この PC の bridgeId・名前・platform（無ければ hostname で代える）。 */
  selfPc?(): PcInfo;
  /** cwd の git のブランチ（分からなければ undefined）。 */
  gitBranch?(cwd: string, agentId: string): Promise<string | undefined>;
  /** 子のカード（workflow_progress kind = "sessions"）を覚えて、そのセッションを見ている全員へ配る（採番しない）。 */
  publishSessionsCard(agentId: string, sessionId: string, payloadJson: string): void;
  loadHistory(agentId: string, sessionId: string): Promise<HistoryMessage[]>;
  /** その agent の既定の権限モードの強さ（claude は claude.mode / settings.json、codex は config.toml）。分からなければ undefined。 */
  defaultStrength(agentId: string): Promise<number | undefined>;
}

export class ToolError extends Error {}

/**
 * 種類の付いた道具のエラー（mac と同じ）。道具の結果の文は「<code>: <文>」。B の口の本文は {"error": code, "message": 文}。
 * - A: unknown_pc（知らない PC）/ pc_unreachable（中継口が無い・応答なし・401 など）/ unknown_tool
 * - A・B: cycle（自分・同じ鎖の中へ送る）/ self（自分の PC から別の PC として来た）/ depth（深さの上限）/
 *   not_requested（その端末が頼んでいないターン）/ tool_error（そのほかの道具の失敗。B から返すとき）
 */
export type MeshErrorCode = "unknown_pc" | "pc_unreachable" | "unknown_tool" | "cycle" | "self" | "depth" | "not_requested" | "tool_error";

export class MeshError extends ToolError {
  constructor(
    readonly code: string,
    readonly detail?: string
  ) {
    super(detail ? `${code}: ${detail}` : code);
  }

  /** B の口の本文。 */
  get body(): Record<string, string> {
    return { error: this.code, message: this.detail ?? this.code };
  }
}

/** 別の PC（A）から /device/orchestrator で頼まれたときの呼んだ側（B で使う）。 */
export interface RemoteCaller {
  /** 頼んできた端末（トンネルの bdc_）。get_reply / answer_approval で触れるのは、この端末が頼んだターンだけ。 */
  deviceKeyId: string;
  /** A の呼んだ側のチャットのモード（段 0〜4）。子はこれより強くしない。 */
  capMode: number;
  /** A の呼んだセッションの深さ。子は + 1。 */
  depth: number;
  /** A の PC（ログと表示用）。 */
  pc?: { bridgeId: string; name: string };
}

export interface Caller {
  token: string;
  agentId: string;
  parentSessionId?: string;
  /** 別の PC から頼まれたとき（B）。合鍵は無く、承認カードも出さない（A で承認済み）。 */
  remote?: RemoteCaller;
  /** mainagent のフォルダのセッションの合鍵か（ふつうのセッションは false）。save_note はこれだけが使える。 */
  main?: boolean;
}

/** 頼む連鎖の深さの上限。利用者が開いたセッションは 0、子は 1、孫は 2（孫には道具を渡さない）。 */
export const MAX_DEPTH = 2;

/** セッションに MCP を渡すかの決定（openSession で決める）。 */
export interface McpPlan {
  /** mainagent のフォルダ（書く道具を外す・権限モードを default に固定する）。 */
  main: boolean;
  depth: number;
  /** 道具で起こした子に渡したモード（その子が頼むときの上限の初期値）。 */
  chatMode?: string;
}

/** 発行した合鍵と、adapter が渡し方を決めるのに使う印。 */
export interface McpGrant {
  token: string;
  main: boolean;
  depth: number;
}

/** 道具で子を開く間だけ立てる印（adapter の openSession が planFor で読む）。 */
const opening = new AsyncLocalStorage<{ depth: number; mode?: string }>();

interface Grant {
  agentId: string;
  /** 合鍵を渡したセッション。確定前の ID（pending）から確定 ID に変わるので、毎回ここから読む。 */
  session?: AgentSession;
  parentSessionId?: string;
  /** 呼んだ側のチャットで選んだ権限モード。子のセッションはこれより強くしない（undefined = 既定の上限）。 */
  chatMode?: string;
  /** 「このセッションでは承認」を選んだら、以後の送る・起こすは尋ねない。 */
  autoApprove: boolean;
  depth: number;
  main: boolean;
}

interface PendingApproval {
  token: string;
  resolve: (decision: string) => void;
}

type TurnState = "queued" | "running" | "done" | "error";

/** 子のターンで回答を待っている承認・質問（子の action_request）。 */
export interface Approval {
  requestId: string;
  title: string;
  /** 何を許すのか（action_request の subtitle。コマンドやファイル名など）。 */
  summary?: string;
  kind?: string;
  /** カードの選択肢（value は子の respondToAction に渡す値）。 */
  options: Array<{ value: string; title: string }>;
  /** mainagent が answer_approval で答えられるか（質問・ターミナルへの発話の保留などは答えない）。 */
  answerable: boolean;
}

/** answer_approval で選べる答え（子の選択肢の名前は agent ごとに違うので、この 3 つにそろえる）。 */
export type ApprovalChoice = "allow" | "allow_for_session" | "deny";
const APPROVAL_CHOICES: readonly ApprovalChoice[] = ["allow", "allow_for_session", "deny"];

interface Turn {
  clientMessageId: string;
  prompt: string;
  state: TurnState;
  sentAt: number;
  startedAt?: number;
  finishedAt?: number;
  lastEventAt: number;
  currentMessageId?: string;
  bubbleClosed: boolean;
  lastBubble: string;
  full: string;
  /** 回答待ちの承認・質問（届いた順）。並べて出す agent があるので複数持つ。 */
  approvals: Approval[];
  errorText?: string;
  /** 別の PC から頼まれたターンなら、その端末（deviceKeyId）。 */
  requester?: string;
  /** 起動だけのターンが done になったが、子のバックグラウンドの作業（サブエージェント・workflow）がまだ動いている。
   *  結論は後の知らせのターンで届くので、それまで done にしない（本文はそのターンのものを返事にする）。 */
  awaitingBackground?: boolean;
}

/** 別の PC の子（A のチャットのカードの行）。A は B の子を購読せず、道具の結果で行を作る。 */
class RemoteRow {
  aliases: Set<string>;
  confirmed = true;
  cwd?: string;
  project?: string;
  mode?: string;
  title?: string;
  status = "queued";
  summary?: string;
  approval?: Record<string, unknown>;
  createdAt = Date.now();
  startedAt?: number;
  finishedAt?: number;
  parentAgentId?: string;
  parentSessionId?: string;
  cardIndex = 0;
  cardSignature?: string;
  cardUpdatedAt = Date.now();

  constructor(
    readonly bridgeId: string,
    public pcName: string,
    readonly agentId: string,
    public sessionId: string
  ) {
    this.aliases = new Set([sessionId]);
  }
}

class Track {
  readonly id = crypto.randomUUID();
  aliases: Set<string>;
  sub?: HubSubscription;
  releaseTimer?: NodeJS.Timeout;
  turns: Turn[] = [];
  touchedAt = Date.now();
  /** start_session で渡したモード（送り直すときの確認に使う。iPhone で変えればそちらが優先）。 */
  childMode?: string;
  /** 最後に頼んだ mainagent のセッション。子のカード（workflow_progress kind = "sessions"）はここへ出す。 */
  parentAgentId?: string;
  parentSessionId?: string;
  /** カードの行番号（agents[].index）。同じ mainagent のチャットの中で重ならない。 */
  cardIndex = 0;
  createdAt = Date.now();
  project?: string;
  agentName?: string;
  /** 最後にカードへ出した行（updatedAtMs を除く）。変わったときだけ出し直す。 */
  cardSignature?: string;
  cardUpdatedAt = Date.now();
  /** この子の深さ（最後に頼んだ呼んだ側 + 1）。開き直す（resume）ときも同じ深さの合鍵にする。 */
  depth = 1;
  /** 子の workflow_progress の写し（バックグラウンドの作業が動いているか。購読している間の出来事だけ）。 */
  cards = new WorkflowCardMirror();
  /** 作業の行が 0 になった後、知らせのターンの done を待つ猶予のタイマー。 */
  backgroundTimer?: NodeJS.Timeout;

  constructor(
    readonly agentId: string,
    public sessionId: string,
    public cwd: string | undefined,
    public confirmed: boolean
  ) {
    this.aliases = new Set([sessionId]);
  }

  get busy(): boolean {
    return this.turns.some((t) => t.state === "queued" || t.state === "running");
  }
}

interface StoredTurn {
  clientMessageId: string;
  prompt: string;
  state: string;
  sentAt: number;
  startedAt?: number;
  finishedAt?: number;
  lastBubble: string;
  full: string;
  errorText?: string;
  requester?: string;
}

interface StoredTrack {
  agentId: string;
  sessionId: string;
  aliases: string[];
  cwd?: string;
  confirmed: boolean;
  childMode?: string;
  touchedAt: number;
  turns: StoredTurn[];
  parentAgentId?: string;
  parentSessionId?: string;
  cardIndex?: number;
  createdAt?: number;
  project?: string;
  agentName?: string;
  depth?: number;
}

/** 権限の強さの名前（T3 Code の runtimeMode の 4 段の下に「計画（読むだけ）」を足した 5 段）。 */
export const STRENGTH_NAMES = ["計画（読むだけ）", "毎回尋ねる", "編集は尋ねない", "作業フォルダの中は尋ねない", "全権"];
/** mainagent のチャットでモードを選んでいないときの上限（毎回尋ねる）。 */
export const DEFAULT_CEILING = 1;

/** その agent でのモード名の強さ。知らない名前は undefined（名前は agent ごとに意味が違うので、名前ではなくこの段で比べる）。 */
export function modeStrength(mode: string, agentId: string): number | undefined {
  switch (mode) {
    case "plan":
      return 0;
    case "ask":
      return 1; // codex: workspace-write ＋ on-request（毎回尋ねる）
    case "auto":
      return agentId === "codex" ? 3 : 1; // codex: workspace-write ＋ never / ほか: CLI 既定の承認
    case "edit":
      return 2; // acceptEdits / accept-edits
    case "build":
      return 3; // opencode の build は既定で書く・実行するを尋ねない
    case "dangerous":
      return 4;
    default:
      return undefined;
  }
}

/** codex の実際の設定（sandbox と approval）の強さ。 */
export function codexStrength(sandbox: string | undefined, approval: string | undefined): number | undefined {
  switch (sandbox) {
    case "read-only":
      return 0;
    case "danger-full-access":
      return 4;
    case "workspace-write":
      return approval === "never" ? 3 : 1;
    default:
      return undefined;
  }
}

/**
 * 子に使わせるモード。要求（無ければ上限）を上限以下に抑え、その agent が持つモードのうち、それ以下で一番強いものを選ぶ。
 * agent がモードを持たなければ undefined（その agent の設定のまま）。上限以下のモードを持たなければ断る（強い既定のまま動かさない）。
 */
export function childModeFor(requested: string | undefined, agentId: string, supported: readonly string[], ceiling: number): string | undefined {
  const options = supported.flatMap((m) => {
    const s = modeStrength(m, agentId);
    return s === undefined ? [] : [{ mode: m, strength: s }];
  });
  if (options.length === 0) return undefined;
  const asked = requested !== undefined ? modeStrength(requested, agentId) : undefined;
  const want = Math.min(asked ?? ceiling, ceiling);
  let pick: { mode: string; strength: number } | undefined;
  for (const o of options) if (o.strength <= want && (!pick || o.strength > pick.strength)) pick = o;
  if (!pick) {
    throw new ToolError(`${agentId} には「${STRENGTH_NAMES[Math.max(0, want)]}」以下のモードが無いので起こせない（上限: ${STRENGTH_NAMES[ceiling]}）`);
  }
  return pick.mode;
}

/**
 * 子のカードの選択肢 1 つが、どの答えにあたるか。分からなければ undefined（選ばせない）。
 * claude: allow / allowForSession / deny、codex: accept / acceptForSession / decline、
 * opencode: once / always / reject、ACP: optionId（allow_once / allow_always / reject_once / proceed_always など）。
 */
export function approvalChoice(value: string, title: string): ApprovalChoice | undefined {
  const classify = (raw: string): ApprovalChoice | undefined => {
    const v = raw.toLowerCase().replace(/-/g, "_").replace(/ /g, "_");
    if (["deny", "denied", "decline", "reject", "cancel", "abort", "no"].some((w) => v.startsWith(w) || v.includes(`_${w}`))) return "deny";
    if (v.includes("always") || v.includes("forsession") || v.includes("for_session") || v.includes("session")) return "allow_for_session";
    if (["allow", "accept", "approve", "proceed", "once", "yes"].some((w) => v.startsWith(w))) return "allow";
    return undefined;
  };
  return classify(value) ?? classify(title);
}

/** answer_approval の decision ごとに、子のどの選択肢を選ぶか。 */
export function approvalChoices(a: Approval): Array<{ choice: ApprovalChoice; value: string }> {
  const out: Array<{ choice: ApprovalChoice; value: string }> = [];
  for (const c of APPROVAL_CHOICES) {
    const o = a.options.find((opt) => approvalChoice(opt.value, opt.title) === c);
    if (o) out.push({ choice: c, value: o.value });
  }
  return out;
}

/** 子の action_request を、mainagent が読める承認にする。 */
export function approvalFromEvent(evt: SessionEvent): Approval {
  const meta = evt.metadata ?? {};
  const requestId = meta.requestId ?? evt.messageId ?? "";
  const count = Number.parseInt(meta.option_count ?? "", 10) || 0;
  const options: Approval["options"] = [];
  for (let i = 0; i < count; i += 1) {
    const v = meta[`option_${i}_value`];
    if (v) options.push({ value: v, title: meta[`option_${i}_title`] ?? v });
  }
  const kind = meta.kind;
  // 答えられないもの: 質問（選択肢が答えそのもの）、答える口の無いカード、ターミナルへの発話の保留
  // （許可の確認を省くターミナルへ、mainagent が自分の発話を通すことになる）。
  const answerable = options.length > 0 && kind !== "userInput" && kind !== "question" && meta.answerable !== "0" && !requestId.startsWith("held-");
  return { requestId, title: meta.title ?? evt.content ?? "承認が必要", summary: meta.subtitle, kind, options, answerable };
}

/** 子の承認 1 件を、mainagent に見せる形にする（get_reply / list_sessions）。 */
export function approvalInfo(a: Approval): Record<string, unknown> {
  const r: Record<string, unknown> = { request_id: a.requestId, title: a.title };
  if (a.summary) r.summary = a.summary.length > 600 ? `${a.summary.slice(0, 600)}…` : a.summary;
  if (a.kind) r.kind = a.kind;
  if (a.answerable) {
    r.choices = approvalChoices(a).map((c) => c.choice);
    r.hint = "answer_approval で答えられる（許可はユーザーの承認が要る）。何を許すのか分からなければユーザーに聞く";
  } else {
    r.hint = "mainagent からは答えられない。このセッションを BuddyOS で開いて答えてもらう";
  }
  return r;
}

function turnStatus(turn: Turn): string {
  switch (turn.state) {
    case "queued":
      return "queued";
    case "running":
      return turn.approvals.length === 0 ? "running" : "needs_approval";
    case "done":
      return !turn.full && turn.errorText !== undefined ? "error" : "done";
    case "error":
      return "error";
  }
}

const tail = (s: string, n: number): string => (s.length > n ? `…${s.slice(-n)}` : s);
const oneLine = (s: string, n: number): string => {
  const flat = s.split(/\r?\n|\r/).map((l) => l.trim()).filter(Boolean).join(" ");
  return flat.length > n ? `${flat.slice(0, n)}…` : flat;
};
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** キーを並べた JSON（mac の .sortedKeys と同じ。変わったかどうかの比較とカードの本文に使う）。 */
export function sortedJson(value: unknown): string {
  return JSON.stringify(value, (_k, v: unknown) => {
    if (v && typeof v === "object" && !Array.isArray(v)) {
      return Object.fromEntries(Object.keys(v as Record<string, unknown>).sort().map((k) => [k, (v as Record<string, unknown>)[k]]));
    }
    return v;
  });
}

/** 作業フォルダの比較（Windows の大文字小文字・区切り・末尾の区切りを揃える）。 */
function samePath(a: string | undefined, b: string | undefined): boolean {
  if (!a || !b) return false;
  const norm = (p: string): string => {
    const t = p.trim().replace(/[\\/]+$/, "");
    return /^[A-Za-z]:[\\/]|^\\\\/.test(t) || process.platform === "win32" ? t.replace(/\//g, "\\").toLowerCase() : t;
  };
  return norm(a) === norm(b);
}

function baseName(p: string): string {
  return projectDisplayName(p.replace(/[\\/]+$/, ""));
}

export class Orchestrator {
  /** 返事を受け取った後も、続けて頼めるように子を開いたままにしておく時間。過ぎたら購読を外す。 */
  idleReleaseMs = 10 * 60 * 1000;
  /** error だけで終わり done が来ないターンを、error 扱いにするまでの猶予（hub の currentTurn と同じ考え方）。 */
  static erroredTurnSettleMs = 6000;
  /** バックグラウンドの行が全部終わってから、知らせのターンの done を待つ猶予（cron の backgroundSettleGrace と同じ 120 秒）。 */
  static backgroundSettleMs = 120_000;
  /** バックグラウンドの結果を待つ上限（hub の backgroundIdleTimeout と同じ 6 時間。出来事が無いまま過ぎたら done にする）。 */
  static backgroundWaitMaxMs = 6 * 60 * 60_000;
  static readonly maxReplyChars = 6000;
  /** 送る・起こす・許可の前に出す承認カードの返事を待つ上限。 */
  approvalTimeoutMs = 5 * 60 * 1000;
  static readonly sessionsTaskId = "mainagent-sessions";
  static readonly sessionsCardName = "任せたセッション";
  private static readonly maxTracks = 50;
  private static readonly maxTurnsPerTrack = 5;

  private hub?: OrchestratorHub;
  private readonly grants = new Map<string, Grant>();
  private readonly pendingApprovals = new Map<string, PendingApproval>();
  /** iPhone のチャットや mainagent が選んだ、セッションごとのモード（"agentId:sessionId" → モード名）。 */
  private readonly sessionModes = new Map<string, string | undefined>();
  private tracks: Track[] = [];
  private storeFile?: string;
  private saveTimer?: NodeJS.Timeout;
  /** 別の PC の子（カードの行だけ。保存しない）。 */
  private remoteRows: RemoteRow[] = [];
  /** デスクトップが渡した別の PC（メモリだけ。管理鍵のパイプが閉じたら空にする）。 */
  private remotePcs: RemotePc[] = [];
  /** 別の PC へ送る口（テストは差し替える）。 */
  remoteTransport: RemoteTransport = httpRemoteTransport;
  /** 設定「ほかのエージェントに頼めるようにする」（orchestrator-settings.json。無ければ有効）。 */
  private allSessionsSetting = true;
  private settingsFile?: string;
  /** cwd の git のブランチ（30 秒覚える）。 */
  private readonly branchCache = new Map<string, { at: number; value: string | null }>();
  static readonly branchCacheMs = 30_000;
  /** /device/sessions/summary の行数の上限。 */
  static readonly summaryLimit = 50;

  /** server.ts が hub を渡す。 */
  attach(hub: OrchestratorHub): void {
    this.hub = hub;
  }

  private get h(): OrchestratorHub {
    if (!this.hub) throw new ToolError("Bridge の準備ができていない");
    return this.hub;
  }

  // ---- 保存（Bridge を再起動しても、頼んだ相手と最後の返事を忘れない） ----

  static defaultStoreFile(configDir: string): string {
    return path.join(configDir, "mainagent-tracks.json");
  }

  /** 保存先を決め、前回の分を読み込む。作業中だったターンは、再起動で止まったものとして error にする。読み込んだ子のカードは hub に預け直す。 */
  enablePersistence(file: string): void {
    this.storeFile = file;
    let stored: StoredTrack[];
    try {
      const parsed = JSON.parse(fs.readFileSync(file, "utf8")) as unknown;
      if (!Array.isArray(parsed)) return;
      stored = parsed as StoredTrack[];
    } catch {
      return;
    }
    for (const s of stored) {
      if (!s || typeof s.agentId !== "string" || typeof s.sessionId !== "string") continue;
      if (this.tracks.some((t) => t.agentId === s.agentId && t.aliases.has(s.sessionId))) continue;
      const t = new Track(s.agentId, s.sessionId, s.cwd, Boolean(s.confirmed));
      t.aliases = new Set([s.sessionId, ...(Array.isArray(s.aliases) ? s.aliases : [])]);
      t.childMode = s.childMode;
      t.touchedAt = s.touchedAt ?? Date.now();
      t.parentAgentId = s.parentAgentId;
      t.parentSessionId = s.parentSessionId;
      t.cardIndex = s.cardIndex ?? 0;
      t.createdAt = s.createdAt ?? t.touchedAt;
      t.project = s.project;
      t.agentName = s.agentName;
      t.depth = typeof s.depth === "number" && Number.isInteger(s.depth) && s.depth >= 0 ? s.depth : 1;
      t.turns = (Array.isArray(s.turns) ? s.turns : []).map((st) => {
        const turn: Turn = {
          clientMessageId: st.clientMessageId,
          prompt: st.prompt ?? "",
          state: (["queued", "running", "done", "error"] as const).find((x) => x === st.state) ?? "error",
          sentAt: st.sentAt ?? Date.now(),
          startedAt: st.startedAt,
          finishedAt: st.finishedAt,
          lastEventAt: Date.now(),
          bubbleClosed: true,
          lastBubble: st.lastBubble ?? "",
          full: st.full ?? "",
          approvals: [],
          errorText: st.errorText,
          requester: typeof st.requester === "string" ? st.requester : undefined
        };
        if (turn.state === "queued" || turn.state === "running") {
          turn.state = "error";
          turn.finishedAt = turn.finishedAt ?? Date.now();
          turn.errorText = "Bridge が再起動したので、このターンは途中で止まった。続きは send_message で頼み直す";
        }
        return turn;
      });
      this.tracks.push(t);
    }
    this.trimTracks();
    const parents = new Set<string>();
    for (const t of this.tracks) {
      if (!t.parentAgentId || !t.parentSessionId) continue;
      const key = `${t.parentAgentId}:${t.parentSessionId}`;
      if (parents.has(key)) continue;
      parents.add(key);
      t.cardSignature = this.cardSignature(t);
      this.publishCard(t.parentAgentId, t.parentSessionId);
    }
  }

  /** 出来事のたびに呼ばれるので、まとめて 1 秒後に書く。 */
  private scheduleSave(): void {
    if (!this.storeFile || this.saveTimer) return;
    this.saveTimer = setTimeout(() => this.saveNow(), 1000);
    this.saveTimer.unref?.();
  }

  saveNow(): void {
    if (this.saveTimer) clearTimeout(this.saveTimer);
    this.saveTimer = undefined;
    const file = this.storeFile;
    if (!file) return;
    const stored: StoredTrack[] = this.tracks.filter((t) => t.sessionId).map((t) => ({
      agentId: t.agentId,
      sessionId: t.sessionId,
      aliases: [...t.aliases],
      cwd: t.cwd,
      confirmed: t.confirmed,
      childMode: t.childMode,
      touchedAt: t.touchedAt,
      turns: t.turns.map((turn) => ({
        clientMessageId: turn.clientMessageId,
        prompt: turn.prompt,
        state: turn.state,
        sentAt: turn.sentAt,
        startedAt: turn.startedAt,
        finishedAt: turn.finishedAt,
        lastBubble: tail(turn.lastBubble, Orchestrator.maxReplyChars),
        full: tail(turn.full, Orchestrator.maxReplyChars),
        errorText: turn.errorText,
        requester: turn.requester
      })),
      parentAgentId: t.parentAgentId,
      parentSessionId: t.parentSessionId,
      cardIndex: t.cardIndex,
      createdAt: t.createdAt,
      project: t.project,
      agentName: t.agentName,
      depth: t.depth
    }));
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      const tmp = `${file}.${process.pid}.tmp`;
      // 頼んだ文と返事が入るので、本人だけが読めるようにする（Windows では mode は効かず、%LOCALAPPDATA% の権限に任せる）。
      fs.writeFileSync(tmp, JSON.stringify(stored), { encoding: "utf8", mode: 0o600 });
      fs.renameSync(tmp, file);
      if (process.platform !== "win32") fs.chmodSync(file, 0o600);
    } catch (error) {
      process.stderr.write(`[mainagent] could not save tracks: ${error instanceof Error ? error.message : String(error)}\n`);
    }
  }

  // ---- 設定（ほかのエージェントに頼めるようにする） ----

  static defaultSettingsFile(configDir: string): string {
    return path.join(configDir, "orchestrator-settings.json");
  }

  /** 設定ファイルを決めて読む（無い・読めなければ有効のまま）。 */
  enableSettings(file: string): void {
    this.settingsFile = file;
    try {
      const value = (JSON.parse(fs.readFileSync(file, "utf8")) as { allSessions?: unknown }).allSessions;
      if (typeof value === "boolean") this.allSessionsSetting = value;
    } catch {
      /* 無ければ既定（有効） */
    }
  }

  get allSessions(): boolean {
    return this.allSessionsSetting;
  }

  /** 切り替える。次に開くセッションから効く（開いているセッションの合鍵は取り上げない）。保存できたか返す。 */
  setAllSessions(value: boolean): boolean {
    this.allSessionsSetting = value;
    const file = this.settingsFile;
    if (!file) return true;
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      const tmp = `${file}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify({ allSessions: value }), { encoding: "utf8", mode: 0o600 });
      fs.renameSync(tmp, file);
      if (process.platform !== "win32") fs.chmodSync(file, 0o600);
      return true;
    } catch (error) {
      process.stderr.write(`[mainagent] could not save settings: ${error instanceof Error ? error.message : String(error)}\n`);
      return false;
    }
  }

  // ---- 合鍵 ----

  /**
   * このセッションに合鍵と MCP を渡すか（adapter の openSession で呼ぶ）。渡さないなら undefined。
   * - 無人実行（cron など）には渡さない。ただし定期チェックの印（heartbeat）が付いた mainagent のフォルダの会話には渡す。
   * - mainagent のフォルダは今までどおり渡す（main = true。深さ 0）。
   * - それ以外は設定 allSessions が有効なときだけ。道具で開く子は opening の深さ、開き直しは覚えた深さ、利用者が開いたものは 0。
   *   深さが MAX_DEPTH 以上なら渡さない（孫はそれ以上頼めない）。
   */
  planFor(agentId: string, sessionId: string | undefined, cwd: string | undefined, unattended?: boolean, heartbeat?: boolean): McpPlan | undefined {
    if (unattended) return heartbeat && isMainWorkspace(cwd) ? { main: true, depth: 0 } : undefined;
    if (isMainWorkspace(cwd)) return { main: true, depth: 0 };
    if (!this.allSessionsSetting) return undefined;
    const ctx = opening.getStore();
    const depth = ctx?.depth ?? (sessionId ? this.track(agentId, sessionId)?.depth : undefined) ?? 0;
    if (depth >= MAX_DEPTH) return undefined;
    return { main: false, depth, chatMode: ctx?.mode };
  }

  /** planFor で渡すと決まれば合鍵を発行する。 */
  grantFor(agentId: string, sessionId: string | undefined, cwd: string | undefined, unattended?: boolean, heartbeat?: boolean): McpGrant | undefined {
    const plan = this.planFor(agentId, sessionId, cwd, unattended, heartbeat);
    if (!plan) return undefined;
    return { token: this.issueToken(agentId, sessionId, plan), main: plan.main, depth: plan.depth };
  }

  issueToken(agentId: string, parentSessionId?: string, plan: McpPlan = { main: false, depth: 0 }): string {
    const token = `bmt_${crypto.randomBytes(32).toString("base64url")}`;
    const chatMode = plan.chatMode ?? (parentSessionId ? this.sessionModes.get(`${agentId}:${parentSessionId}`) : undefined);
    this.grants.set(token, { agentId, parentSessionId, autoApprove: false, depth: plan.depth, main: plan.main, chatMode });
    return token;
  }

  /** 合鍵の深さ（テスト用）。 */
  depthOfToken(token: string): number | undefined {
    return this.grants.get(token)?.depth;
  }

  /** 呼んだ側の深さ。 */
  private depthOf(caller: Caller): number {
    if (caller.remote) return caller.remote.depth;
    return this.grants.get(caller.token)?.depth ?? 0;
  }

  /** 合鍵を mainagent のセッションに結びつける（親のセッションの今の ID を、この session から読む）。 */
  bind(token: string, session: AgentSession): void {
    const g = this.grants.get(token);
    if (g) g.session = session;
  }

  setParentSessionId(token: string, sessionId: string): void {
    const g = this.grants.get(token);
    if (g) g.parentSessionId = sessionId;
  }

  /** 親のセッションが閉じた。合鍵を無効にし、出している承認カードは断ったことにする。 */
  revoke(token: string): void {
    this.grants.delete(token);
    for (const [id, p] of [...this.pendingApprovals]) {
      if (p.token !== token) continue;
      this.pendingApprovals.delete(id);
      p.resolve("deny");
    }
  }

  private parentOf(g: Grant): string | undefined {
    return g.session?.sessionId ?? g.parentSessionId;
  }

  caller(token: string): Caller | undefined {
    const g = this.grants.get(token);
    if (!g) return undefined;
    return { token, agentId: g.agentId, parentSessionId: this.parentOf(g), main: g.main };
  }

  /** チャットで権限モードが選ばれた（iPhone の送信ごとに届く。undefined = 既定に戻した）。どのセッションでも覚える。 */
  noteChatMode(agentId: string, sessionId: string, mode: string | undefined): void {
    for (const g of this.grants.values()) {
      if (g.agentId === agentId && this.parentOf(g) === sessionId) g.chatMode = mode;
    }
    this.sessionModes.set(`${agentId}:${sessionId}`, mode);
  }

  // ---- 承認（送る・起こすの前に、mainagent の画面へ承認カードを出す） ----

  /** iPhone の action_response が mainagent の承認への返事なら受け取って true。 */
  resolveApproval(requestId: string, decision: string): boolean {
    const p = this.pendingApprovals.get(requestId);
    if (!p) return false;
    this.pendingApprovals.delete(requestId);
    p.resolve(decision);
    return true;
  }

  /**
   * - honorAutoApprove: false なら「このセッションでは承認」を選んでいても尋ねる（子の承認に答えるとき、上限が低い場合）。
   * - offerSessionOption: false ならカードに「このセッションでは承認」を出さない。
   */
  private async requireApproval(caller: Caller, title: string, subtitle: string, honorAutoApprove = true, offerSessionOption = true): Promise<void> {
    // 別の PC から頼まれたとき（B）は、A が呼んだ側のチャットでカードを出して承認済み。
    if (caller.remote) return;
    const g = this.grants.get(caller.token);
    if (!g) throw new ToolError("合鍵が無効");
    if (g.autoApprove && honorAutoApprove) return;
    const parentSid = caller.parentSessionId;
    if (!parentSid) throw new ToolError("承認を出せない（mainagent のセッションが未確定）");
    const requestId = `mainagent-${crypto.randomUUID()}`;
    const meta: Record<string, string> = { requestId, kind: "approval", allowsOther: "0", title, subtitle };
    const options: Array<[string, string, string]> = [["承認", "一度だけ許可", "allow"]];
    if (offerSessionOption) options.push(["このセッションでは承認", "以後の依頼は尋ねない", "allowForSession"]);
    options.push(["非承認", "頼まない", "deny"]);
    meta.option_count = String(options.length);
    options.forEach(([t, s, v], i) => {
      meta[`option_${i}_title`] = t;
      meta[`option_${i}_subtitle`] = s;
      meta[`option_${i}_value`] = v;
    });
    const card: SessionEvent = { type: "action_request", agentId: caller.agentId, sessionId: parentSid, messageId: requestId, content: title, metadata: meta };
    const decision = await new Promise<string>((resolve) => {
      const timer = setTimeout(() => this.resolveApproval(requestId, "timeout"), this.approvalTimeoutMs);
      timer.unref?.();
      this.pendingApprovals.set(requestId, {
        token: caller.token,
        resolve: (d) => {
          clearTimeout(timer);
          resolve(d);
        }
      });
      this.h.emitExternal(caller.agentId, parentSid, card);
    });
    this.h.emitExternal(caller.agentId, parentSid, { type: "action_resolved", agentId: caller.agentId, sessionId: parentSid, messageId: requestId });
    if (decision === "allow") return;
    if (decision === "allowForSession" && offerSessionOption) {
      const live = this.grants.get(caller.token);
      if (live) live.autoApprove = true;
      return;
    }
    if (decision === "timeout") {
      throw new ToolError(`ユーザーの承認が ${Math.round(this.approvalTimeoutMs / 60000)} 分以内に無かった。頼むならもう一度呼ぶ`);
    }
    throw new ToolError("ユーザーが承認しなかった");
  }

  // ---- 子の権限モード（親より強くしない） ----

  /**
   * 子への上限。チャットで選んだモードを、呼んだ側の agent での意味で測る（mainagent のフォルダ以外のセッションでも同じ）。
   * 別の PC から頼まれたときは、A が送った段（capMode。無ければ毎回尋ねる）。
   */
  private ceiling(caller: Caller): number {
    if (caller.remote) {
      const c = caller.remote.capMode;
      return Number.isInteger(c) ? Math.max(0, Math.min(STRENGTH_NAMES.length - 1, c)) : DEFAULT_CEILING;
    }
    const g = this.grants.get(caller.token);
    if (!g?.chatMode) return DEFAULT_CEILING;
    return modeStrength(g.chatMode, g.agentId) ?? DEFAULT_CEILING;
  }

  /** 開いているセッションの今の強さ。チャットで選んだモード、無ければその agent の既定の設定。分からなければ undefined。 */
  private async currentStrength(agentId: string, sessionId: string): Promise<number | undefined> {
    const mode = this.sessionModes.get(`${agentId}:${sessionId}`) ?? this.track(agentId, sessionId)?.childMode;
    if (mode) return modeStrength(mode, agentId);
    return this.h.defaultStrength(agentId).catch(() => undefined);
  }

  /** 既にあるセッションへ送る前に、相手のモードが上限を超えていないか確かめる（超えていれば送らない）。 */
  private async checkTargetMode(caller: Caller, agentId: string, sessionId: string): Promise<number | undefined> {
    const cap = this.ceiling(caller);
    const now = await this.currentStrength(agentId, sessionId);
    if (now === undefined) return undefined;
    if (now > cap) {
      throw new ToolError(
        `相手のセッションは「${STRENGTH_NAMES[now]}」で動いていて、mainagent の上限「${STRENGTH_NAMES[cap]}」より強いので送らない。` +
          "相手のチャットでモードを下げるか、mainagent のチャットのモードを上げてからもう一度呼ぶ"
      );
    }
    return now;
  }

  // ---- 道具 ----

  private track(agentId: string, sessionId: string): Track | undefined {
    return this.tracks.find((t) => t.agentId === agentId && t.aliases.has(sessionId));
  }

  private projectName(dir: string | undefined): string | undefined {
    if (!dir) return undefined;
    return this.h.projects().find((p) => samePath(p.path, dir))?.name;
  }

  listProjects(): Array<Record<string, unknown>> {
    return this.h.projects().filter((p) => !isMainWorkspace(p.path)).map((p) => ({ name: p.name, path: p.path }));
  }

  async listAgents(): Promise<Array<Record<string, unknown>>> {
    const out: Array<Record<string, unknown>> = [];
    for (const a of this.h.adapters()) {
      if (a.id === "echo") continue;
      const p = await this.h.probe(a.id).catch(() => ({ installed: false, configured: false }));
      out.push({ agent: a.id, name: a.displayName, installed: p.installed, configured: p.configured });
    }
    return out;
  }

  listSessions(caller: Caller): Array<Record<string, unknown>> {
    const hub = this.h;
    const live = hub.snapshot();
    const terminal = hub.terminal();
    const terminalCwd = new Map(terminal.map((t) => [t.sessionId, t.cwd]));
    const seen = new Set<string>();
    const out: Array<Record<string, unknown>> = [];

    const row = (agent: string, sid: string, cwd: string | undefined, state: string, source: string): Record<string, unknown> => {
      const r: Record<string, unknown> = { agent, session_id: sid, state, source };
      if (cwd) {
        r.cwd = cwd;
        const name = this.projectName(cwd);
        if (name) r.project = name;
      }
      const last = this.track(agent, sid)?.turns.at(-1);
      if (last) {
        r.last_request = last.prompt.slice(0, 120);
        r.last_request_state = turnStatus(last);
        if (last.state === "running" && last.approvals.length > 0) r.pending_approvals = last.approvals.map(approvalInfo);
      }
      return r;
    };

    for (const info of live) {
      const cwd = info.cwd ?? this.track(info.agentId, info.sessionId)?.cwd ?? (info.agentId === "claude" ? terminalCwd.get(info.sessionId) : undefined);
      if (this.isSelf(caller, info.agentId, info.sessionId) || isMainWorkspace(cwd)) continue;
      seen.add(`${info.agentId}:${info.sessionId}`);
      const r = row(info.agentId, info.sessionId, cwd, info.generating ? "working" : "idle", terminalCwd.has(info.sessionId) ? "terminal" : "bridge");
      if (info.queued > 0) r.queued = info.queued;
      out.push(r);
    }
    for (const t of terminal) {
      if (seen.has(`claude:${t.sessionId}`)) continue;
      if (this.isSelf(caller, "claude", t.sessionId) || isMainWorkspace(t.cwd)) continue;
      seen.add(`claude:${t.sessionId}`);
      out.push(row("claude", t.sessionId, t.cwd, t.generating ? "working" : "idle", "terminal"));
    }
    // 頼んだことがあり、今は閉じているもの（send_message で開き直せる）。
    for (const t of this.tracks) {
      if ([...t.aliases].some((a) => seen.has(`${t.agentId}:${a}`))) continue;
      out.push(row(t.agentId, t.sessionId, t.cwd, "closed", "mainagent"));
    }
    return out;
  }

  async startSession(caller: Caller, agentId: string, cwd: string, prompt: string, mode?: string, waitSeconds = 0): Promise<Record<string, unknown>> {
    const dir = normalizeProjectPath(cwd);
    if (!dir || !Orchestrator.isDirectory(dir)) throw new ToolError(`cwd が見つからない: ${cwd}`);
    if (isMainWorkspace(dir)) throw new ToolError("mainagent のフォルダではセッションを起こせない");
    const text = prompt.trim();
    if (!text) throw new ToolError("prompt が空");
    this.checkRemoteCaller(caller);
    const adapter = this.chatAdapter(agentId);
    if (mode !== undefined && modeStrength(mode, agentId) === undefined) {
      throw new ToolError(`知らない mode: ${mode}（plan / ask / edit / auto / dangerous）`);
    }
    const childMode = childModeFor(mode, agentId, adapter.modes ?? [], this.ceiling(caller));
    const project = this.projectName(dir) ?? baseName(dir);
    await this.requireApproval(caller, `${project} で ${adapter.displayName} を起こして頼みますか？`, Orchestrator.approvalSubtitle(text, childMode));

    const track = new Track(agentId, "", dir, false);
    // 子の深さと渡すモードは、開く前に決めておく（adapter の openSession が合鍵を出すか決めるのに使う）。
    track.childMode = childMode;
    track.depth = this.depthOf(caller) + 1;
    const session = await this.subscribe(track, undefined);
    // iPhone のチャットでモードを選ぶのと同じ経路で渡す（承認は今までどおり iPhone に尋ねる）。
    if (childMode) session.applyOverrides?.({ mode: childMode });
    track.sessionId = session.sessionId;
    track.aliases.add(session.sessionId);
    track.project = project;
    track.agentName = adapter.displayName;
    this.tracks.push(track);
    this.attachToCaller(track, caller);
    this.trimTracks();
    this.submit(track, text, caller.remote?.deviceKeyId);

    // 確定した ID を返したいので、session_started を少し待つ（返事そのものは get_reply で待つ）。
    const deadline = Date.now() + 30_000;
    while (!track.confirmed && Date.now() < deadline) {
      const s = track.turns.at(-1)?.state;
      if (s === "error" || s === "done") break;
      await sleep(200);
    }
    const out: Record<string, unknown> = {
      agent: agentId,
      session_id: track.sessionId,
      cwd: dir,
      state: track.turns.at(-1)?.state ?? "queued",
      confirmed: track.confirmed,
      mode: childMode ?? "（このエージェントの設定のまま）"
    };
    return this.withReply(out, caller, agentId, track.sessionId, waitSeconds);
  }

  async sendMessage(caller: Caller, agentId: string, sessionId: string, raw: string, waitSeconds = 0): Promise<Record<string, unknown>> {
    const text = raw.trim();
    if (!text) throw new ToolError("text が空");
    this.checkRemoteCaller(caller);
    if (this.isSelf(caller, agentId, sessionId)) throw new MeshError("cycle", "自分自身には送れない");
    if (this.isAncestor(caller, agentId, sessionId)) throw new MeshError("cycle", "自分に頼んだセッション（同じ鎖の中のセッション）には送れない");
    const adapter = this.chatAdapter(agentId);
    const existing = this.track(agentId, sessionId);
    const liveCwd = this.h.snapshot().find((s) => s.agentId === agentId && s.sessionId === sessionId)?.cwd;
    if (isMainWorkspace(liveCwd ?? existing?.cwd)) throw new ToolError("mainagent のセッションには送れない");
    const where = liveCwd ?? existing?.cwd;
    const project = (where ? this.projectName(where) ?? baseName(where) : undefined) ?? sessionId.slice(0, 8);
    const level = await this.checkTargetMode(caller, agentId, sessionId);
    await this.requireApproval(
      caller,
      `${project} の ${adapter.displayName} に送りますか？`,
      Orchestrator.approvalSubtitle(text, level !== undefined ? STRENGTH_NAMES[level] : "不明")
    );
    // 承認を待つ間に相手のモードが上がっていないか、送る直前にもう一度確かめる。
    await this.checkTargetMode(caller, agentId, sessionId);
    let track = this.track(agentId, sessionId);
    if (!track) {
      track = new Track(agentId, sessionId, liveCwd, true);
      this.tracks.push(track);
      this.trimTracks();
    }
    if (!track.cwd) track.cwd = liveCwd;
    if (where) track.project = project;
    track.agentName = adapter.displayName;
    // 最後に頼んだ呼んだ側 + 1（閉じていて開き直すときは、この深さの合鍵になる）。
    track.depth = this.depthOf(caller) + 1;
    this.attachToCaller(track, caller);
    if (!track.sub?.holds()) {
      this.unsubscribe(track);
      await this.subscribe(track, track.sessionId);
    }
    this.submit(track, text, caller.remote?.deviceKeyId);
    const out: Record<string, unknown> = { agent: agentId, session_id: track.sessionId, state: track.turns.at(-1)?.state ?? "queued" };
    return this.withReply(out, caller, agentId, track.sessionId, waitSeconds);
  }

  /** wait_seconds があれば、その間返事を待って結果に足す。 */
  private async withReply(out: Record<string, unknown>, caller: Caller, agentId: string, sessionId: string, waitSeconds: number): Promise<Record<string, unknown>> {
    if (!(waitSeconds > 0)) {
      out.next = "get_reply で返事を待つ";
      return out;
    }
    const reply = await this.getReply(caller, agentId, sessionId, waitSeconds);
    for (const [k, v] of Object.entries(reply)) if (out[k] === undefined || k === "session_id") out[k] = v;
    delete out.state;
    return out;
  }

  private static approvalSubtitle(prompt: string, mode: string | undefined): string {
    const body = prompt.length > 400 ? `${prompt.slice(0, 400)}…` : prompt;
    return mode ? `モード: ${mode}\n${body}` : body;
  }

  async getReply(caller: Caller, agentId: string, sessionId: string, waitSeconds: number): Promise<Record<string, unknown>> {
    const wait = Math.max(0, Math.min(Number.isFinite(waitSeconds) ? waitSeconds : 0, 300));
    const deadline = Date.now() + wait * 1000;
    const device = caller.remote?.deviceKeyId;
    for (;;) {
      const track = this.track(agentId, sessionId);
      // 別の PC から頼まれたときは、その端末が頼んだターンだけを見る（頼んでいないセッションは not_requested）。
      const idx = !track ? -1 : device === undefined ? track.turns.length - 1 : track.turns.map((t) => t.requester).lastIndexOf(device);
      if (device !== undefined && idx < 0) throw new MeshError("not_requested", "この端末から頼んだセッションではない");
      if (!track || idx < 0) return this.untrackedStatus(agentId, sessionId);
      this.settleIfErrored(track, idx);
      this.settleIfBackgroundStale(track, idx);
      const turn = track.turns[idx];
      const status = turnStatus(turn);
      if ((status !== "running" && status !== "queued") || Date.now() >= deadline) return this.describe(track, turn, status);
      await sleep(250);
    }
  }

  /**
   * 子のセッションの承認に、mainagent が代わりに答える。
   * - 答えられるのは、mainagent が頼んだターンで待っている承認だけ。質問（userInput）や、ターミナルへの発話の保留は答えない。
   * - deny はいつでも答えられる（ユーザーにも尋ねない）。
   * - allow は上限が「毎回尋ねる」以上、allow_for_session は「編集は尋ねない」以上のときだけ。相手のモードが上限より強ければ答えない。
   * - 許可するときは、Bridge が mainagent の画面に承認カードを出す。「このセッションでは承認」を選んでいても、
   *   上限が「作業フォルダの中は尋ねない」より低ければ毎回尋ねる。
   */
  async answerApproval(caller: Caller, agentId: string, sessionId: string, requestId: string, raw: string): Promise<Record<string, unknown>> {
    const choice = APPROVAL_CHOICES.find((c) => c === raw);
    if (!choice) throw new ToolError("decision は allow / allow_for_session / deny のどれか");
    if (this.isSelf(caller, agentId, sessionId)) throw new ToolError("自分自身の承認には答えられない");
    const device = caller.remote?.deviceKeyId;
    const pending = (): { track: Track; approval: Approval } => {
      const t = this.track(agentId, sessionId);
      // 別の PC から頼まれたときは、その端末が頼んだターンで待っている承認だけ。
      const turn = t ? [...t.turns].reverse().find((x) => x.state === "running" && (device === undefined || x.requester === device)) : undefined;
      const a = turn?.approvals.find((x) => x.requestId === requestId);
      if ((!t || !a) && device !== undefined) throw new MeshError("not_requested", "この端末から頼んだターンで待っている承認ではない");
      if (!t || !a) throw new ToolError("その承認は待っていない（もう答えられたか、mainagent が頼んだターンではない）。get_reply で今の承認を見る");
      return { track: t, approval: a };
    };
    const { track, approval } = pending();
    if (!approval.answerable) {
      throw new ToolError(`この確認（${approval.kind ?? "不明"}）には mainagent から答えられない。ユーザーにこのセッションを BuddyOS で開いて答えてもらう`);
    }
    const choices = approvalChoices(approval);
    const value = choices.find((c) => c.choice === choice)?.value;
    if (value === undefined) {
      const can = choices.map((c) => c.choice).join(" / ");
      throw new ToolError(`この承認には ${choice} にあたる選択肢が無い（選べるもの: ${can || "なし"}）`);
    }
    if (choice !== "deny") {
      const cap = this.ceiling(caller);
      if (cap < 1) {
        throw new ToolError(
          `mainagent の上限が「${STRENGTH_NAMES[cap]}」なので、子の承認に許可で答えられない。` +
            "ユーザーにこのセッションを開いて答えてもらうか、mainagent のチャットのモードを上げてもらう"
        );
      }
      if (choice === "allow_for_session" && cap < 2) {
        throw new ToolError(
          `「このセッションでは許可」は、mainagent の上限が「編集は尋ねない」以上のときだけ使える（今は「${STRENGTH_NAMES[cap]}」）。allow で一度だけ許可する`
        );
      }
      const level = await this.checkTargetMode(caller, agentId, sessionId);
      const name = track.agentName ?? agentId;
      const place = track.project ?? (track.cwd ? baseName(track.cwd) : sessionId.slice(0, 8));
      const lines = [
        `答え: ${choice === "allow" ? "一度だけ許可" : "このセッションでは許可"}`,
        `モード: ${level !== undefined ? STRENGTH_NAMES[level] : "不明"}`,
        `確認: ${approval.title}`
      ];
      if (approval.summary) lines.push(approval.summary.length > 400 ? `${approval.summary.slice(0, 400)}…` : approval.summary);
      await this.requireApproval(caller, `${place} の ${name} の承認に、mainagent が許可で答えますか？`, lines.join("\n"), cap >= 3, cap >= 3);
      // カードを出している間に、別の端末で答えられた・相手のモードが上がったことがある。
      await this.checkTargetMode(caller, agentId, sessionId);
      pending();
    }
    const session = track.sub?.session;
    if (!session?.respondToAction) throw new ToolError("セッションが閉じていて答えられない。ユーザーにこのセッションを開いてもらう");
    for (const turn of track.turns) turn.approvals = turn.approvals.filter((a) => a.requestId !== requestId);
    await session.respondToAction(requestId, value, {});
    // 子のチャットを見ている iPhone のカードも閉じる（答えたことを知らせない adapter がある）。
    this.h.emitExternal(track.agentId, track.sessionId, { type: "action_resolved", agentId: track.agentId, sessionId: track.sessionId, messageId: requestId });
    this.publishIfChanged(track);
    this.scheduleSave();
    return { agent: agentId, session_id: track.sessionId, request_id: requestId, answered: choice, next: "get_reply で続きを待つ" };
  }

  // ---- 中身 ----

  private static isDirectory(dir: string): boolean {
    // Windows の Bridge で WSL 側のパス（/home/...）は Windows から見えないので、ここでは確かめない（開くときに失敗すれば error になる）。
    if (process.platform === "win32" && dir.startsWith("/")) return true;
    try {
      return fs.statSync(dir).isDirectory();
    } catch {
      return false;
    }
  }

  /** 頼んだ mainagent のチャットを覚える（子のカードはそこへ出す）。別の mainagent から頼まれたら移す。 */
  private attachToCaller(track: Track, caller: Caller): void {
    // 別の PC から頼まれた子のカードは A が出す（B には呼んだ側のチャットが無い）。
    if (caller.remote) return;
    const parentSid = caller.parentSessionId;
    if (!parentSid) return;
    if (track.parentAgentId === caller.agentId && track.parentSessionId === parentSid) return;
    const old = track.parentAgentId && track.parentSessionId ? [track.parentAgentId, track.parentSessionId] as const : undefined;
    track.parentAgentId = caller.agentId;
    track.parentSessionId = parentSid;
    track.cardIndex = this.nextCardIndex(caller.agentId, parentSid, track);
    track.cardSignature = undefined;
    if (old) this.publishCard(old[0], old[1]);
  }

  /** そのチャットのカードで、まだ使っていない行番号（この PC の子と別の PC の子で重ならない）。 */
  private nextCardIndex(parentAgentId: string, parentSessionId: string, except?: Track | RemoteRow): number {
    const used = [
      ...this.tracks.filter((t) => t !== except && t.parentAgentId === parentAgentId && t.parentSessionId === parentSessionId),
      ...this.remoteRows.filter((r) => r !== except && r.parentAgentId === parentAgentId && r.parentSessionId === parentSessionId)
    ].map((x) => x.cardIndex);
    return (used.length > 0 ? Math.max(...used) : -1) + 1;
  }

  private isSelf(caller: Caller, agentId: string, sessionId: string): boolean {
    return Boolean(caller.parentSessionId) && agentId === caller.agentId && sessionId === caller.parentSessionId;
  }

  /**
   * 送り先が、呼んだ側の祖先（呼んだ側に頼んだセッション、その親…）か。同じ鎖の中へ送ると、互いに待ち合って止まる（cycle）。
   * 別の PC から頼まれたとき（B）は、送り先が頼んできた PC に子を持っていれば同じ鎖とみなす（A が B の子の親）。
   */
  private isAncestor(caller: Caller, agentId: string, sessionId: string): boolean {
    const targetIds = this.track(agentId, sessionId)?.aliases ?? new Set([sessionId]);
    if (caller.remote) {
      const from = caller.remote.pc?.bridgeId;
      return Boolean(from) && this.remoteRows.some((r) => r.bridgeId === from && r.parentAgentId === agentId && Boolean(r.parentSessionId) && targetIds.has(r.parentSessionId!));
    }
    let cur: { agentId: string; sessionId?: string } = { agentId: caller.agentId, sessionId: caller.parentSessionId };
    for (let i = 0; i < 16 && cur.sessionId; i += 1) {
      const t = this.track(cur.agentId, cur.sessionId);
      if (!t?.parentAgentId || !t.parentSessionId) return false;
      if (t.parentAgentId === agentId && targetIds.has(t.parentSessionId)) return true;
      cur = { agentId: t.parentAgentId, sessionId: t.parentSessionId };
    }
    return false;
  }

  /** 頼む道具（起こす・送る）の前に、呼んだ側の深さと、別の PC からなら自分の PC から来ていないかを確かめる（B でも確かめる）。 */
  private checkRemoteCaller(caller: Caller): void {
    if (this.depthOf(caller) >= MAX_DEPTH) {
      throw new MeshError("depth", `頼む連鎖の深さの上限（${MAX_DEPTH}）に達しているので、これ以上は頼めない`);
    }
    const from = caller.remote?.pc?.bridgeId;
    if (from && from === this.selfPc().bridgeId) throw new MeshError("self", "自分の PC から自分の PC へは、別の PC としては頼めない");
  }

  private chatAdapter(agentId: string): AgentAdapter {
    const adapter = this.h.adapter(agentId);
    if (!adapter) throw new ToolError(`知らないエージェント: ${agentId}（list_agents で確かめる）`);
    return adapter;
  }

  /** hub を購読する。届いた出来事は順番どおりに ingest へ流す。 */
  private async subscribe(track: Track, sessionId: string | undefined): Promise<AgentSession> {
    const trackId = track.id;
    // 開くあいだ子の深さとモードを立てておく（adapter の openSession が planFor で読み、depth < MAX_DEPTH なら合鍵を渡す）。
    const sub = await opening.run({ depth: track.depth, mode: track.childMode }, () =>
      this.h.acquire(track.agentId, sessionId, track.cwd, (evt) => this.ingest(trackId, evt))
    );
    track.sub = sub;
    return sub.session;
  }

  private unsubscribe(track: Track): void {
    if (track.releaseTimer) clearTimeout(track.releaseTimer);
    track.releaseTimer = undefined;
    track.sub?.release();
    track.sub = undefined;
  }

  private submit(track: Track, text: string, requester?: string): void {
    const sub = track.sub;
    if (!sub) throw new ToolError("セッションを開けなかった");
    if (track.releaseTimer) clearTimeout(track.releaseTimer);
    track.releaseTimer = undefined;
    track.touchedAt = Date.now();
    const clientMessageId = `mainagent-${crypto.randomUUID()}`;
    const now = Date.now();
    track.turns.push({
      clientMessageId,
      prompt: text,
      state: "queued",
      sentAt: now,
      lastEventAt: now,
      bubbleClosed: false,
      lastBubble: "",
      full: "",
      approvals: [],
      requester
    });
    if (track.turns.length > Orchestrator.maxTurnsPerTrack) track.turns.splice(0, track.turns.length - Orchestrator.maxTurnsPerTrack);
    if (sub.submit(clientMessageId, text) === "missing") {
      track.turns = track.turns.filter((t) => t.clientMessageId !== clientMessageId);
      throw new ToolError("セッションが閉じていた。もう一度送る");
    }
    this.publishIfChanged(track);
    this.scheduleSave();
  }

  private ingest(trackId: string, evt: SessionEvent): void {
    const track = this.tracks.find((t) => t.id === trackId);
    if (!track) return;
    this.scheduleSave();
    if (evt.type === "session_started" && evt.sessionId) {
      track.aliases.add(evt.sessionId);
      track.sessionId = evt.sessionId;
      track.confirmed = true;
      this.publishIfChanged(track);
      return;
    }
    if (evt.type === "queue_dispatched") {
      const cmid = evt.metadata?.clientMessageId ?? evt.messageId;
      const turn = track.turns.find((t) => t.clientMessageId === cmid && t.state === "queued");
      if (turn) {
        turn.state = "running";
        turn.startedAt = Date.now();
        turn.lastEventAt = Date.now();
        this.publishIfChanged(track);
        return;
      }
    }
    // バックグラウンドの作業の行は、ターンの外でも写しに重ねる（起動だけのターンを done にしてよいかの判断に使う）。
    if (evt.type === "workflow_progress") {
      track.cards.apply(evt.content);
      this.watchBackground(track);
      return;
    }
    // 自分の送信が始まるまでの出来事（購読直後のスナップショット・前のターンの残り）は見ない。
    const turn = [...track.turns].reverse().find((t) => t.state === "running");
    if (!turn) return;
    turn.lastEventAt = Date.now();
    switch (evt.type) {
      case "assistant_delta": {
        const chunk = evt.content ?? "";
        if (turn.bubbleClosed || evt.messageId !== turn.currentMessageId) {
          if (turn.lastBubble) turn.full += "\n\n";
          turn.lastBubble = "";
          turn.bubbleClosed = false;
          turn.currentMessageId = evt.messageId;
        }
        turn.lastBubble += chunk;
        turn.full += chunk;
        return;
      }
      case "assistant_turn_end":
        turn.bubbleClosed = true;
        return;
      case "action_request": {
        const a = approvalFromEvent(evt);
        turn.approvals = [...turn.approvals.filter((x) => x.requestId !== a.requestId), a];
        this.publishIfChanged(track);
        return;
      }
      case "action_resolved":
        turn.approvals = turn.approvals.filter((x) => x.requestId !== evt.messageId);
        this.publishIfChanged(track);
        return;
      case "error":
        turn.errorText = evt.content ?? "error";
        return;
      case "done":
        // バックグラウンドの作業の終わりを知らせるターン（Claude の task-notification）は、自分が送ったターンの返事ではない。
        // 送った発話が CLI の待ち行列にある間に届くので、ここで終わらせず、そのターンの本文も返事から外す。
        if (evt.metadata?.origin === "task-notification") {
          // 起動だけのターンの結果待ち: この知らせのターンの本文が返事。作業が全部終わっていれば、ここで終わりにする。
          if (turn.awaitingBackground) {
            if (!agentsOrWorkflows(track.cards.counts)) this.finishTurn(track, turn);
            return;
          }
          if (evt.messageId !== undefined && evt.messageId === turn.currentMessageId) {
            turn.full = turn.full.slice(0, turn.full.length - turn.lastBubble.length).replace(/\n\n$/, "");
            turn.lastBubble = "";
            turn.bubbleClosed = true;
          }
          return;
        }
        // 子がバックグラウンドで作業を続けている（Claude の既定のサブエージェントなど）。起動の返事で終わりにせず、
        // 知らせのターンの結論を待つ（待つ間は購読も外さない）。
        if (agentsOrWorkflows(track.cards.counts)) {
          turn.awaitingBackground = true;
          turn.approvals = [];
          this.publishIfChanged(track);
          return;
        }
        this.finishTurn(track, turn);
        return;
      default:
        return;
    }
  }

  private finishTurn(track: Track, turn: Turn): void {
    if (track.backgroundTimer) clearTimeout(track.backgroundTimer);
    track.backgroundTimer = undefined;
    turn.awaitingBackground = false;
    turn.state = "done";
    turn.finishedAt = Date.now();
    turn.approvals = [];
    this.scheduleReleaseIfIdle(track);
    this.publishIfChanged(track);
    this.scheduleSave();
  }

  /** 結果待ちのターンがあり、作業の行が 0 になったら猶予を数え始める（その間に知らせのターンの done が来れば、そちらで終わる）。 */
  private watchBackground(track: Track): void {
    const turn = [...track.turns].reverse().find((t) => t.state === "running" && t.awaitingBackground);
    if (!turn) return;
    if (track.backgroundTimer) clearTimeout(track.backgroundTimer);
    track.backgroundTimer = undefined;
    if (agentsOrWorkflows(track.cards.counts)) return;
    track.backgroundTimer = setTimeout(() => {
      track.backgroundTimer = undefined;
      if (turn.state === "running" && turn.awaitingBackground) this.finishTurn(track, turn);
    }, Orchestrator.backgroundSettleMs);
    track.backgroundTimer.unref?.();
  }

  /** 結果待ちのまま出来事が無い時間が上限を過ぎたら done にする（終わりの知らせを取りこぼした行で永久に待たない）。 */
  private settleIfBackgroundStale(track: Track, i: number): void {
    const t = track.turns[i];
    if (t.state === "running" && t.awaitingBackground && Date.now() - t.lastEventAt > Orchestrator.backgroundWaitMaxMs) this.finishTurn(track, t);
  }

  /** iPhone が子のチャットで承認に答えた。答えたことを知らせない adapter があるので、ここで待ちから外す。 */
  noteApprovalAnswered(agentId: string, requestId: string): void {
    for (const t of this.tracks) {
      if (t.agentId !== agentId) continue;
      let changed = false;
      for (const turn of t.turns) {
        if (!turn.approvals.some((a) => a.requestId === requestId)) continue;
        turn.approvals = turn.approvals.filter((a) => a.requestId !== requestId);
        changed = true;
      }
      if (changed) this.publishIfChanged(t);
    }
  }

  private settleIfErrored(track: Track, i: number): void {
    const t = track.turns[i];
    if (t.state !== "running" || t.errorText === undefined || Date.now() - t.lastEventAt <= Orchestrator.erroredTurnSettleMs) return;
    t.state = "error";
    t.finishedAt = Date.now();
    t.approvals = [];
    this.scheduleReleaseIfIdle(track);
    this.publishIfChanged(track);
    this.scheduleSave();
  }

  private scheduleReleaseIfIdle(track: Track): void {
    if (track.busy) return;
    if (track.releaseTimer) clearTimeout(track.releaseTimer);
    const trackId = track.id;
    track.releaseTimer = setTimeout(() => this.releaseIfIdle(trackId), this.idleReleaseMs);
    track.releaseTimer.unref?.();
  }

  private releaseIfIdle(trackId: string): void {
    const track = this.tracks.find((t) => t.id === trackId);
    if (!track || track.busy) return;
    this.unsubscribe(track);
  }

  private trimTracks(): void {
    if (this.tracks.length <= Orchestrator.maxTracks) return;
    const removable = this.tracks.filter((t) => !t.sub && !t.busy).sort((a, b) => a.touchedAt - b.touchedAt);
    const drop = new Set(removable.slice(0, this.tracks.length - Orchestrator.maxTracks));
    this.tracks = this.tracks.filter((t) => !drop.has(t));
  }

  private describe(track: Track, turn: Turn, status: string): Record<string, unknown> {
    const r: Record<string, unknown> = {
      agent: track.agentId,
      session_id: track.sessionId,
      status,
      request: turn.prompt.slice(0, 200),
      elapsed_seconds: Math.floor(((turn.finishedAt ?? Date.now()) - turn.sentAt) / 1000)
    };
    if (track.cwd) r.cwd = track.cwd;
    const reply = turn.lastBubble || turn.full;
    if (reply) r.reply = tail(reply, Orchestrator.maxReplyChars);
    const earlier = turn.full.length > reply.length ? turn.full.slice(0, turn.full.length - reply.length) : "";
    if (earlier.trim() && status !== "running") r.earlier = tail(earlier, 2000);
    if (turn.state === "running" && turn.approvals.length > 0) {
      // approval は最初の 1 件（前の版と同じキー）、approvals は待っているもの全部。
      r.approval = approvalInfo(turn.approvals[0]);
      if (turn.approvals.length > 1) r.approvals = turn.approvals.map(approvalInfo);
    }
    if (turn.errorText !== undefined) r.error = turn.errorText.slice(0, 500);
    if (status === "running" || status === "queued") {
      r.hint = turn.awaitingBackground
        ? "バックグラウンドの作業の結果待ち（reply は起動の返事）。少し待ってもう一度 get_reply を呼ぶ"
        : "まだ作業中。少し待ってもう一度 get_reply を呼ぶ";
    }
    return r;
  }

  /** 頼んでいないセッション（ユーザーが開いたもの）の状況。最後の返事は履歴から読む。 */
  private async untrackedStatus(agentId: string, sessionId: string): Promise<Record<string, unknown>> {
    const live = this.h.snapshot().find((s) => s.agentId === agentId && s.sessionId === sessionId);
    const terminalWorking = agentId === "claude" && this.h.terminal().some((t) => t.sessionId === sessionId && t.generating);
    const r: Record<string, unknown> = { agent: agentId, session_id: sessionId, status: live?.generating || terminalWorking ? "running" : "idle" };
    if (live?.cwd) r.cwd = live.cwd;
    if (this.h.adapter(agentId)) {
      const history = await this.h.loadHistory(agentId, sessionId).catch(() => []);
      const lastReply = [...history].reverse().find((m) => m.role === "assistant");
      if (lastReply) r.last_reply = tail(lastReply.content, Orchestrator.maxReplyChars);
      const lastUser = [...history].reverse().find((m) => m.role === "user");
      if (lastUser) r.last_request = lastUser.content.slice(0, 200);
    }
    return r;
  }

  // ---- 子のカード（mainagent のチャットに出す workflow_progress kind = "sessions"） ----

  /** 子 1 つの行。形は shared/protocol.json の payloads["workflow_progress.sessions"]。updatedAtMs は入れない。 */
  private cardRow(t: Track): Record<string, unknown> {
    const turn = t.turns.at(-1);
    const status = turn ? turnStatus(turn) : "idle";
    const row: Record<string, unknown> = {
      index: t.cardIndex,
      rowKind: "session",
      agentId: t.agentId,
      sessionId: t.sessionId,
      confirmed: t.confirmed,
      status,
      createdAtMs: Math.floor(t.createdAt)
    };
    // 古いアプリ（dynamic workflow のカードとして出す）向けの state / label / resultPreview。
    row.state = status === "done" || status === "idle" ? "done" : status === "error" ? "failed" : "running";
    const name = t.agentName ?? t.agentId;
    const place = t.project ?? (t.cwd ? baseName(t.cwd) : undefined);
    row.agentName = name;
    row.label = place ? `${place} · ${name}` : name;
    if (t.cwd) row.cwd = t.cwd;
    if (t.project) row.project = t.project;
    if (t.childMode) row.mode = t.childMode;
    if (!turn) return row;
    row.title = oneLine(turn.prompt, 60);
    row.startedAtMs = Math.floor(turn.sentAt);
    if (turn.finishedAt !== undefined && (turn.state === "done" || turn.state === "error")) {
      row.finishedAtMs = Math.floor(turn.finishedAt);
      row.durationMs = Math.max(0, Math.floor(turn.finishedAt) - Math.floor(turn.sentAt));
    }
    let summary: string | undefined;
    if (status === "needs_approval") {
      const a = turn.approvals[0];
      summary = `承認待ち: ${oneLine(a.title, 80)}`;
      const info: Record<string, unknown> = { requestId: a.requestId, title: a.title, answerable: a.answerable, count: turn.approvals.length };
      if (a.summary) info.summary = oneLine(a.summary, 200);
      if (a.kind) info.kind = a.kind;
      row.approval = info;
    } else if (status === "done") {
      const reply = turn.lastBubble || turn.full;
      if (reply) summary = oneLine(reply.slice(-400), 160);
    } else if (status === "error") {
      summary = oneLine(turn.errorText ?? "エラーで止まった", 160);
    }
    if (summary) {
      row.summary = summary;
      row.resultPreview = summary;
    }
    return row;
  }

  private cardSignature(t: Track): string {
    return sortedJson(this.cardRow(t));
  }

  /** 行が変わっていれば、その mainagent のチャットへカードを出し直す。 */
  private publishIfChanged(track: Track): void {
    if (!track.parentAgentId || !track.parentSessionId) return;
    const sig = this.cardSignature(track);
    if (sig === track.cardSignature) return;
    track.cardSignature = sig;
    track.cardUpdatedAt = Date.now();
    this.publishCard(track.parentAgentId, track.parentSessionId);
  }

  /** カード全体（その mainagent が頼んだ子の全行）。行が無ければ undefined。 */
  sessionsCardJson(parentAgentId: string, parentSessionId: string): string | undefined {
    const mine: Array<{ index: number; updatedAt: number; row: () => Record<string, unknown> }> = [
      ...this.tracks
        .filter((t) => t.parentAgentId === parentAgentId && t.parentSessionId === parentSessionId)
        .map((t) => ({ index: t.cardIndex, updatedAt: t.cardUpdatedAt, row: () => this.cardRow(t) })),
      ...this.remoteRows
        .filter((r) => r.parentAgentId === parentAgentId && r.parentSessionId === parentSessionId)
        .map((r) => ({ index: r.cardIndex, updatedAt: r.cardUpdatedAt, row: () => this.remoteCardRow(r) }))
    ].sort((a, b) => a.index - b.index);
    if (mine.length === 0) return undefined;
    let active = false;
    const rows = mine.map((m) => {
      const row = m.row();
      row.updatedAtMs = Math.floor(m.updatedAt);
      if (["queued", "running", "needs_approval"].includes(String(row.status))) active = true;
      return row;
    });
    return sortedJson({
      subtype: "task_progress",
      taskId: Orchestrator.sessionsTaskId,
      kind: "sessions",
      workflowName: Orchestrator.sessionsCardName,
      status: active ? "running" : "completed",
      updatedAtMs: Math.max(...mine.map((m) => Math.floor(m.updatedAt))),
      agents: rows
    });
  }

  /** 別の PC の子の行（この PC の子の行と同じ形に bridgeId / pcName を足す）。updatedAtMs は入れない。 */
  private remoteCardRow(r: RemoteRow): Record<string, unknown> {
    const status = r.status;
    const place = r.project ?? (r.cwd ? baseName(r.cwd) : undefined);
    const row: Record<string, unknown> = {
      index: r.cardIndex,
      rowKind: "session",
      agentId: r.agentId,
      agentName: r.agentId,
      sessionId: r.sessionId,
      confirmed: r.confirmed,
      status,
      createdAtMs: Math.floor(r.createdAt),
      bridgeId: r.bridgeId,
      pcName: r.pcName,
      state: status === "done" || status === "idle" ? "done" : status === "error" ? "failed" : "running",
      label: `${r.pcName} · ${place ? `${place} · ` : ""}${r.agentId}`
    };
    if (r.cwd) row.cwd = r.cwd;
    if (r.project) row.project = r.project;
    if (r.mode) row.mode = r.mode;
    if (r.title) row.title = r.title;
    if (r.startedAt !== undefined) row.startedAtMs = Math.floor(r.startedAt);
    if (r.finishedAt !== undefined && (status === "done" || status === "error")) {
      row.finishedAtMs = Math.floor(r.finishedAt);
      row.durationMs = Math.max(0, Math.floor(r.finishedAt) - Math.floor(r.startedAt ?? r.createdAt));
    }
    if (status === "needs_approval" && r.approval) row.approval = r.approval;
    if (r.summary) {
      row.summary = r.summary;
      row.resultPreview = r.summary;
    }
    return row;
  }

  private publishRemoteIfChanged(r: RemoteRow): void {
    if (!r.parentAgentId || !r.parentSessionId) return;
    const sig = sortedJson(this.remoteCardRow(r));
    if (sig === r.cardSignature) return;
    r.cardSignature = sig;
    r.cardUpdatedAt = Date.now();
    this.publishCard(r.parentAgentId, r.parentSessionId);
  }

  /** 行がすべて別の mainagent へ移ったときのカード（行は消せないので、カードを終わったことにするだけ）。 */
  static readonly emptySessionsCardJson = sortedJson({
    subtype: "task_progress",
    taskId: Orchestrator.sessionsTaskId,
    kind: "sessions",
    workflowName: Orchestrator.sessionsCardName,
    status: "completed",
    agents: []
  });

  private publishCard(parentAgentId: string, parentSessionId: string): void {
    const json = this.sessionsCardJson(parentAgentId, parentSessionId) ?? Orchestrator.emptySessionsCardJson;
    this.hub?.publishSessionsCard(parentAgentId, parentSessionId, json);
  }

  // ---- 別の PC ----

  selfPc(): PcInfo {
    return this.hub?.selfPc?.() ?? { bridgeId: "", name: os.hostname(), platform: "windows" };
  }

  /** PUT /local/remote-pcs（まるごと置き換える。メモリだけ）。 */
  setRemotePcs(pcs: RemotePc[]): void {
    this.remotePcs = pcs.map((p) => ({ ...p }));
  }

  /** デスクトップがいなくなった（管理鍵のパイプが閉じた）。 */
  clearRemotePcs(): void {
    this.remotePcs = [];
  }

  get remotePcCount(): number {
    return this.remotePcs.length;
  }

  /** list_pcs。自分の PC を先頭に、次にデスクトップが渡した PC。 */
  listPcs(): Record<string, unknown> {
    const self = this.selfPc();
    return {
      pcs: [
        { pc: self.bridgeId, name: self.name, platform: self.platform, self: true },
        ...this.remotePcs.filter((p) => p.bridgeId !== self.bridgeId).map((p) => ({ pc: p.bridgeId, name: p.name, platform: p.platform, self: false }))
      ]
    };
  }

  /**
   * 道具の pc を引く。無い・自分の bridgeId・自分の名前なら undefined（この PC）。別の PC なら RemotePc。見つからなければ unknown_pc。
   * 別の PC から頼まれたとき（B）は pc を見ない（A が外して送る。さらに別の PC へは送らない）。
   */
  resolvePc(caller: Caller, pc: string | undefined): RemotePc | undefined {
    if (caller.remote || pc === undefined || !pc.trim()) return undefined;
    const want = pc.trim();
    const self = this.selfPc();
    if (self.bridgeId && want === self.bridgeId) return undefined;
    const byId = this.remotePcs.find((p) => p.bridgeId === want);
    if (byId) return byId;
    if (want === self.name) return undefined;
    const byName = this.remotePcs.find((p) => p.name === want);
    if (byName) return byName;
    throw new MeshError("unknown_pc", `${want}（list_pcs で確かめる）`);
  }

  /**
   * 道具を別の PC（B）で呼ぶ。頼む・許可で答える道具は、A が呼んだ側のチャットに承認カード（「PC: <name>」付き）を
   * 出してから送る。本文は道具の引数（pc を除く）に capMode（上限の段）・depth（呼んだセッションの深さ）・caller（この PC）を足したもの。
   * 応答は B で呼んだときの結果をそのまま返す。
   */
  async forward(caller: Caller, pc: RemotePc, tool: string, args: Record<string, unknown>): Promise<unknown> {
    if (caller.remote) throw new ToolError("別の PC から頼まれた道具は、さらに別の PC へは送れない");
    const str = (key: string): string => {
      const v = args[key];
      if (typeof v !== "string" || !v) throw new ToolError(`${key} が無い`);
      return v;
    };
    const cap = this.ceiling(caller);
    const self = this.selfPc();
    const body: Record<string, unknown> = { ...args };
    delete body.pc;
    body.capMode = cap;
    body.depth = this.depthOf(caller);
    body.caller = { bridgeId: self.bridgeId, name: self.name };
    const pcLine = `PC: ${pc.name}`;
    if (tool === "start_session") {
      this.checkRemoteCaller(caller);
      const cwd = str("cwd");
      const text = str("prompt").trim();
      const agent = typeof args.agent === "string" && args.agent ? args.agent : "claude";
      const mode = typeof args.mode === "string" ? args.mode : undefined;
      if (mode !== undefined && modeStrength(mode, agent) === undefined) throw new ToolError(`知らない mode: ${mode}（plan / ask / edit / auto / dangerous）`);
      body.agent = agent;
      await this.requireApproval(
        caller,
        `${pc.name} の ${baseName(cwd)} で ${agent} を起こして頼みますか？`,
        `${pcLine}\n${Orchestrator.approvalSubtitle(text, `${mode ?? "上限まで"}（上限: ${STRENGTH_NAMES[cap]}）`)}`
      );
    } else if (tool === "send_message") {
      this.checkRemoteCaller(caller);
      const agent = str("agent");
      const sid = str("session_id");
      const text = str("text").trim();
      const place = this.remoteRow(pc.bridgeId, agent, sid)?.project;
      await this.requireApproval(
        caller,
        `${pc.name} の ${place ? `${place} の ` : ""}${agent} に送りますか？`,
        `${pcLine}\n${Orchestrator.approvalSubtitle(text, `${pc.name} で確かめる（上限: ${STRENGTH_NAMES[cap]}）`)}`
      );
    } else if (tool === "answer_approval") {
      const agent = str("agent");
      const sid = str("session_id");
      const decision = str("decision");
      if (decision !== "deny") {
        // 上限の決まりは B でも確かめるが、通らないカードは出さない（この PC と同じ決まり）。
        if (cap < 1) throw new ToolError(`上限が「${STRENGTH_NAMES[cap]}」なので、子の承認に許可で答えられない`);
        if (decision === "allow_for_session" && cap < 2) {
          throw new ToolError(`「このセッションでは許可」は、上限が「編集は尋ねない」以上のときだけ使える（今は「${STRENGTH_NAMES[cap]}」）。allow で一度だけ許可する`);
        }
        const row = this.remoteRow(pc.bridgeId, agent, sid);
        const lines = [pcLine, `答え: ${decision === "allow" ? "一度だけ許可" : "このセッションでは許可"}`];
        const title = typeof row?.approval?.title === "string" ? row.approval.title : undefined;
        if (title) lines.push(`確認: ${title}`);
        const summary = typeof row?.approval?.summary === "string" ? row.approval.summary : undefined;
        if (summary) lines.push(summary);
        await this.requireApproval(caller, `${pc.name} の ${row?.project ? `${row.project} の ` : ""}${agent} の承認に、許可で答えますか？`, lines.join("\n"), cap >= 3, cap >= 3);
      }
    }
    const rawWait = typeof args.wait_seconds === "number" && Number.isFinite(args.wait_seconds) ? args.wait_seconds : tool === "get_reply" ? 60 : 0;
    const wait = Math.max(0, Math.min(rawWait, 300));
    // B が待つ分（wait_seconds）より長く待つ。start_session は B が確定 ID を最大 30 秒待つので + 60 秒、ほかは + 30 秒。
    const result = await this.remoteCall(pc, tool, body, (wait + (tool === "start_session" ? 60 : 30)) * 1000);
    if (result && typeof result === "object" && !Array.isArray(result)) this.noteRemoteResult(caller, pc, tool, args, result as Record<string, unknown>);
    return result;
  }

  /** B へ送って、応答を道具の結果かエラーにする。 */
  private async remoteCall(pc: RemotePc, tool: string, body: Record<string, unknown>, timeoutMs: number): Promise<unknown> {
    let res: { status: number; body: string };
    try {
      res = await this.remoteTransport(pc, tool, JSON.stringify(body), timeoutMs);
    } catch (error) {
      throw new MeshError("pc_unreachable", `${pc.name}: ${error instanceof Error ? error.message : String(error)}`);
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(res.body);
    } catch {
      parsed = undefined;
    }
    if (res.status >= 200 && res.status < 300 && parsed !== undefined) return parsed;
    const obj = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {};
    const code = typeof obj.error === "string" ? obj.error : undefined;
    const message = typeof obj.message === "string" ? obj.message : undefined;
    // 道具の失敗（422）は種類をそのままに、文の頭に PC の名前を付けて返す。
    if (res.status === 422 && code) throw new MeshError(code, `${pc.name}: ${message ?? code}`);
    if (res.status === 404 && code === "unknown_tool") throw new MeshError("unknown_tool", `${pc.name}: ${tool}`);
    if (res.status === 404) throw new MeshError("pc_unreachable", `${pc.name} の BuddyOS が古いので、別の PC からは頼めない（/device/orchestrator が無い）`);
    throw new MeshError("pc_unreachable", `${pc.name}: HTTP ${res.status}${code ? ` ${code}` : ""}`);
  }

  private remoteRow(bridgeId: string, agentId: string, sessionId: string): RemoteRow | undefined {
    return this.remoteRows.find((r) => r.bridgeId === bridgeId && r.agentId === agentId && r.aliases.has(sessionId));
  }

  /** B から受けた結果で、呼んだ側のチャットのカードの行を作る・直す（start_session / send_message は行を作り、ほかは直すだけ）。 */
  private noteRemoteResult(caller: Caller, pc: RemotePc, tool: string, args: Record<string, unknown>, result: Record<string, unknown>): void {
    const parentSid = caller.parentSessionId;
    if (!parentSid) return;
    const sidArg = typeof args.session_id === "string" ? args.session_id : undefined;
    const sid = typeof result.session_id === "string" && result.session_id ? result.session_id : sidArg;
    const agent = typeof result.agent === "string" && result.agent ? result.agent : typeof args.agent === "string" && args.agent ? args.agent : "claude";
    if (!sid) return;
    let row = this.remoteRow(pc.bridgeId, agent, sid) ?? (sidArg ? this.remoteRow(pc.bridgeId, agent, sidArg) : undefined);
    const now = Date.now();
    if (!row) {
      if (tool !== "start_session" && tool !== "send_message") return;
      row = new RemoteRow(pc.bridgeId, pc.name, agent, sid);
      row.parentAgentId = caller.agentId;
      row.parentSessionId = parentSid;
      row.cardIndex = this.nextCardIndex(caller.agentId, parentSid, row);
      this.remoteRows.push(row);
      if (this.remoteRows.length > Orchestrator.maxTracks) this.remoteRows.splice(0, this.remoteRows.length - Orchestrator.maxTracks);
    } else if (tool === "start_session" || tool === "send_message") {
      // 別のチャットから頼み直したら、行をそちらのカードへ移す（この PC の子と同じ）。
      if (row.parentAgentId !== caller.agentId || row.parentSessionId !== parentSid) {
        const old = row.parentAgentId && row.parentSessionId ? [row.parentAgentId, row.parentSessionId] as const : undefined;
        row.parentAgentId = caller.agentId;
        row.parentSessionId = parentSid;
        row.cardIndex = this.nextCardIndex(caller.agentId, parentSid, row);
        row.cardSignature = undefined;
        if (old) this.publishCard(old[0], old[1]);
      }
    }
    row.pcName = pc.name;
    if (sid !== row.sessionId) {
      row.aliases.add(sid);
      row.sessionId = sid;
    }
    if (typeof result.confirmed === "boolean") row.confirmed = result.confirmed;
    if (typeof result.cwd === "string") row.cwd = result.cwd;
    else if (tool === "start_session" && typeof args.cwd === "string") row.cwd = args.cwd;
    if (row.cwd && !row.project) row.project = baseName(row.cwd);
    if (tool === "start_session" && typeof result.mode === "string") row.mode = result.mode;
    if (tool === "start_session" || tool === "send_message") {
      const text = typeof args.prompt === "string" ? args.prompt : typeof args.text === "string" ? args.text : "";
      row.title = oneLine(text, 60);
      row.startedAt = now;
      row.finishedAt = undefined;
      row.approval = undefined;
      row.summary = undefined;
    }
    const status = typeof result.status === "string" ? result.status : typeof result.state === "string" ? result.state : undefined;
    if (tool === "answer_approval" && typeof result.answered === "string") {
      row.status = "running";
      row.approval = undefined;
      row.summary = undefined;
    } else if (status) {
      row.status = ["queued", "running", "needs_approval", "done", "error", "idle"].includes(status) ? status : row.status;
      const approval = result.approval && typeof result.approval === "object" ? (result.approval as Record<string, unknown>) : undefined;
      if (row.status === "needs_approval" && approval) {
        const info: Record<string, unknown> = {
          requestId: typeof approval.request_id === "string" ? approval.request_id : "",
          title: typeof approval.title === "string" ? approval.title : "承認が必要",
          answerable: Array.isArray(approval.choices) && approval.choices.length > 0,
          count: Array.isArray(result.approvals) ? result.approvals.length : 1
        };
        if (typeof approval.summary === "string") info.summary = oneLine(approval.summary, 200);
        if (typeof approval.kind === "string") info.kind = approval.kind;
        row.approval = info;
        row.summary = `承認待ち: ${oneLine(String(info.title), 80)}`;
      } else {
        row.approval = undefined;
        if (row.status === "done" && typeof result.reply === "string" && result.reply) row.summary = oneLine(result.reply.slice(-400), 160);
        else if (row.status === "error") row.summary = oneLine(typeof result.error === "string" ? result.error : "エラーで止まった", 160);
        else if (row.status !== "done") row.summary = undefined;
      }
      if (row.status === "done" || row.status === "error") row.finishedAt ??= now;
    }
    this.publishRemoteIfChanged(row);
  }

  // ---- 全部の PC の一覧（GET /device/sessions/summary） ----

  /** list_sessions と同じ集め方（hub の entry・ターミナルの Claude。閉じた子は除く）。mainagent のフォルダのものも含める。新しい順に 50 件まで。 */
  async sessionsSummary(): Promise<Record<string, unknown>> {
    const hub = this.h;
    const self = this.selfPc();
    const live = hub.snapshot();
    const terminal = hub.terminal();
    const terminalCwd = new Map(terminal.map((t) => [t.sessionId, t.cwd]));
    const seen = new Set<string>();
    const rows: Array<{ agentId: string; sessionId: string; cwd?: string; generating: boolean; awaiting?: boolean; updatedAtMs?: number }> = [];
    for (const info of live) {
      const cwd = info.cwd ?? this.track(info.agentId, info.sessionId)?.cwd ?? (info.agentId === "claude" ? terminalCwd.get(info.sessionId) : undefined);
      seen.add(`${info.agentId}:${info.sessionId}`);
      rows.push({ ...info, cwd });
    }
    for (const t of terminal) {
      if (seen.has(`claude:${t.sessionId}`)) continue;
      seen.add(`claude:${t.sessionId}`);
      rows.push({ agentId: "claude", sessionId: t.sessionId, cwd: t.cwd, generating: t.generating, awaiting: t.awaiting, updatedAtMs: t.updatedAtMs });
    }
    const now = Date.now();
    const shaped = rows.map((r) => {
      const track = this.track(r.agentId, r.sessionId);
      const last = track?.turns.at(-1);
      const waiting = Boolean(r.awaiting) || (last?.state === "running" && last.approvals.length > 0);
      const status = waiting ? "needs_approval" : r.generating ? "running" : "idle";
      const project = r.cwd ? (isMainWorkspace(r.cwd) ? PROJECT_NAME : this.projectName(r.cwd) ?? baseName(r.cwd)) : undefined;
      // 名前は道具で頼んだセッションだけ（頼んだ文。mac と同じ）。
      const title = last ? oneLine(last.prompt, 60) : undefined;
      return {
        agentId: r.agentId,
        agentName: this.h.adapter(r.agentId)?.displayName ?? r.agentId,
        sessionId: r.sessionId,
        cwd: r.cwd ?? null,
        project: project ?? null,
        branch: null as string | null,
        status,
        title: title ?? null,
        updatedAtMs: Math.floor(r.updatedAtMs ?? track?.touchedAt ?? now)
      };
    });
    shaped.sort((a, b) => b.updatedAtMs - a.updatedAtMs);
    const top = shaped.slice(0, Orchestrator.summaryLimit);
    await Promise.all(top.map(async (row) => {
      if (row.cwd) row.branch = await this.branchOf(row.cwd, row.agentId);
    }));
    return { pc: { bridgeId: self.bridgeId, name: self.name, platform: self.platform }, sessions: top };
  }

  /** cwd の git のブランチ（GitInfoReader の結果を 30 秒覚える。分からなければ null）。 */
  private async branchOf(cwd: string, agentId: string): Promise<string | null> {
    const key = `${agentId}\n${cwd}`;
    const hit = this.branchCache.get(key);
    if (hit && Date.now() - hit.at < Orchestrator.branchCacheMs) return hit.value;
    const value = (await this.hub?.gitBranch?.(cwd, agentId).catch(() => undefined)) ?? null;
    this.branchCache.set(key, { at: Date.now(), value });
    if (this.branchCache.size > 500) {
      const oldest = this.branchCache.keys().next().value;
      if (oldest !== undefined) this.branchCache.delete(oldest);
    }
    return value;
  }

  // ---- テスト用 ----

  /** 今の上限（テスト用）。 */
  ceilingFor(caller: Caller): number {
    return this.ceiling(caller);
  }

  /** 出している承認カードの数（テスト用）。 */
  get pendingApprovalCount(): number {
    return this.pendingApprovals.size;
  }
}

/** Bridge に 1 つ。adapter（合鍵の発行）・server（/mcp と action_response）が使う。 */
export const orchestrator = new Orchestrator();
