import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { event, type SessionEvent } from "../protocol.js";
import type { AgentSession, Emit } from "../agents/types.js";
import { attachmentTextNotes, metadataText } from "../agents/types.js";
import { isAgentTool, isInternalHelper, stripNotifications, SubagentTracker, toolActivity } from "../agents/subagentTracker.js";
import type { ClaudeChannelInbox } from "./channelInbox.js";
import {
  answerLists,
  approvalKeys,
  ESC,
  heldKeys,
  planKeys,
  questionKeys,
  sanitizedForTyping,
  TYPING_GAP_MS,
  typingKeys,
  type TerminalKeyRouter
} from "./keys.js";
import { paneState, type TerminalPaneStatus } from "./paneStatus.js";
import { BG_INTERRUPT_TEXT, readSessionFile, sessionFileNames } from "./claudeAgentsRegistry.js";

/// ターミナルで動いている Claude Code に、後から BuddyOS を繋ぐ（mac の ClaudeTerminalRegistry の移植）。
///   見る: Claude Code の hooks が、そのセッションで起きたことを Bridge に POST する（/claude/hook）
///   送る: ペアリング済みの端末で人が打った発話は、デスクトップのアプリ内ターミナルならそこに打ち込む（typePrompt。キーボードで
///         打ったのと同じ発話になる）。
///         それ以外（mainagent・定期の見回りの文、.local の接続からの文、ターミナルの外の claude）は、channel サーバ
///         （buddy-channel）が受け箱を long-poll する。無ければ Claude Code の受け箱（cross-session messaging。
///         「別のセッションから」と分かる形で届く）
///   答える: channel の許可中継か、デスクトップのターミナルへのキー入力
/// 結合キーは session_id。イベントは publish（Bridge の配信口。"claude:<sid>" の購読者へ配り、再接続用に記録する）へ流す。

const AGENT = "claude";
const INBOX_TIMEOUT_MS = 30_000;
/** 打ち込んだ発話が届くのを待つ時間。届かないのは、デスクトップが打ち込まなかった（claude が前面にいない・入力欄が
 *  空いていない）か、入力欄が別の画面（/model の一覧など）になっていたとき。 */
const TYPED_DELIVERY_MS = 20_000;
/** コマンド（/compact・/model など）は発話にならず UserPromptSubmit が来ないので、短く待って打ち込んだことだけ伝える。 */
const TYPED_COMMAND_MS = 5000;
/** デスクトップは 1 操作ずつ 0.5 秒あけて書く。操作の数だけ、上の待ち時間に足す（長い文を分けた貼り付けで、書き終える前に
 *  失敗にしない。余裕を見て 1 操作 1 秒）。 */
const TYPED_KEY_MS = 1000;
/** ターミナル側のターンが終わるのを待ってから打ち込む上限（前の発話が届くのを待つ上限も同じ）と、その確かめの間隔。 */
const TYPING_BUSY_WAIT_MS = 900_000;
const TYPING_POLL_MS = 1000;
/** 打ち込んだ発話が届く（か届かないと決まる）のを待つ間隔（前の発話が済むまで、次の発話を打たない）。 */
const TYPED_SETTLE_POLL_MS = 250;
const INTERRUPT_POLL_MS = 3000;
/** transcript を見張る間隔（受け箱の保留・バックグラウンドの作業の完了）。 */
const TAIL_INTERVAL_MS = 1000;
/** 見張る理由（受け箱の保留・動いている行）が無くなった後も読み続ける時間。Stop の reconcile が結果なしで閉じた行の、
 *  後から積まれる知らせ（失敗・終了コード）を落とさないため。 */
const TAIL_GRACE_MS = 10_000;
/** Stop の後に遅れて届いた MessageDisplay を捨ててよい時間（実測は Stop の 0〜0.2 秒後）。 */
const LATE_DISPLAY_WINDOW_MS = 3000;
/**
 * ターミナルの保留ダイアログが自動で取り消されるまでの時間（Claude Code の既定 5 分）に余裕を足したもの。
 * これを過ぎても届かなければ、時間切れかターミナルで Deny されたとみなしてカードを閉じる。
 */
const HELD_EXPIRY_MS = 315_000;

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : typeof v === "number" ? String(v) : undefined);

/* ── カード（mac の ClaudeControlProtocol と同じ形） ──────────────── */

function jsonText(input: Obj): string {
  try {
    return JSON.stringify(Object.fromEntries(Object.keys(input).sort().map((k) => [k, input[k]])));
  } catch {
    return "";
  }
}

export function toolSummary(toolName: string, input: Obj, limit = 300): string {
  const s = (k: string): string | undefined => (typeof input[k] === "string" && input[k] ? String(input[k]) : undefined);
  let text: string;
  switch (toolName) {
    case "Bash":
      text = s("command") ?? "シェルコマンドを実行";
      break;
    case "Write":
    case "Edit":
    case "MultiEdit":
    case "Read":
    case "NotebookEdit":
      text = s("file_path") ?? s("path") ?? s("notebook_path") ?? jsonText(input);
      break;
    case "WebFetch":
      text = s("url") ?? jsonText(input);
      break;
    case "WebSearch":
      text = s("query") ?? jsonText(input);
      break;
    case "ExitPlanMode":
      text = s("plan") ?? "計画を承認して実装に進みます";
      break;
    default:
      text = jsonText(input);
  }
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

export function questionsIn(input: Obj): Obj[] {
  return Array.isArray(input.questions) ? input.questions.map(obj) : [];
}

function setOptions(meta: Record<string, string>, options: Array<[string, string, string]>): void {
  for (const k of Object.keys(meta)) if (k.startsWith("option_")) delete meta[k];
  meta.option_count = String(options.length);
  options.forEach(([title, subtitle, value], i) => {
    meta[`option_${i}_title`] = title;
    meta[`option_${i}_subtitle`] = subtitle;
    meta[`option_${i}_value`] = value;
  });
}

function questionMetadata(qs: Obj[]): Record<string, string> {
  const first = qs[0] ?? {};
  const options = (Array.isArray(first.options) ? first.options : []).map(obj);
  const meta: Record<string, string> = {
    kind: "userInput",
    allowsOther: "1",
    questions_json: JSON.stringify(
      qs.map((q, i) => {
        const question = str(q.question) ?? "";
        return {
          id: str(q.id) ?? (question || `q${i}`),
          question,
          header: str(q.header) ?? "",
          multiSelect: q.multiSelect === true,
          options: (Array.isArray(q.options) ? q.options : []).map(obj).map((o, j) => ({ label: str(o.label) ?? `Option ${j + 1}`, description: str(o.description) ?? "" }))
        };
      })
    ),
    option_count: String(options.length)
  };
  if (first.multiSelect === true) meta.multiSelect = "1";
  options.forEach((o, i) => {
    const label = str(o.label) ?? `Option ${i + 1}`;
    meta[`option_${i}_title`] = label;
    meta[`option_${i}_subtitle`] = str(o.description) ?? "";
    meta[`option_${i}_value`] = label;
  });
  return meta;
}

/** hook のカードと channel の依頼を結び付けてよい時間（これより古いカードには結び付けない）。 */
const CHANNEL_BIND_MS = 30_000;

/**
 * channel の input_preview（引数の JSON を途中で切ったもの）が hook の tool_input と食い違わないか。
 * 一致 = true、食い違い = false、どちらかが無くて確かめられない = undefined。
 */
export function inputPreviewMatches(input: Obj, preview: string | undefined): boolean | undefined {
  const compact = (v: string): string => v.replace(/\s+/g, "");
  const want = compact(preview ?? "").replace(/(…|\.\.\.)$/, "");
  if (!want || Object.keys(input).length === 0) return undefined;
  let have: string;
  try {
    have = compact(JSON.stringify(input));
  } catch {
    return undefined;
  }
  const n = Math.min(want.length, have.length, 160);
  return n > 0 && have.slice(0, n) === want.slice(0, n);
}

interface TerminalPrompt {
  requestId: string;
  /** approval / userInput / plan / held（受け箱に送った発話をターミナルが保留した） */
  kind: "approval" | "userInput" | "plan" | "held";
  toolName: string;
  input: Obj;
  hasSuggestions: boolean;
  /** hook = PermissionRequest hook の応答を Bridge が持っていて、それで答える（ターミナルの外の claude）。 */
  via: "pty" | "channel" | "hook" | "none";
  fromHook: boolean;
  createdAt: number;
  channelRequestId?: string;
  verdict?: string;
  answered: boolean;
  /** permission_suggestions（「このセッションでは承認」で hook の応答に載せる）。 */
  suggestions?: unknown[];
  /** 持っている hook の応答を返す（undefined = 空で返す）。返したら消える。 */
  hookReply?: (out: Obj | undefined) => void;
  /** サブエージェントの選択肢なら、その agent_id（main は undefined）。閉じるのは同じ agent_id の hook だけ
   *  （並んで動くサブエージェントの同じ名前のツールで、親の選択肢を閉じない）。 */
  agentId?: string;
}

/** hook の応答を持っておく時間（hook の timeout 300 秒より短く）。 */
const HOOK_HOLD_MS = 280_000;

/** ターミナルの外で開いた会話に、ここから答えるための案内（Windows には buddy-claude が無い）。 */
export function terminalFixHint(sessionId: string): string {
  return `BuddyOS のターミナルタブで \`claude --resume ${sessionId}\` を開くと、ここから答えられます。`;
}

export function terminalCard(p: TerminalPrompt, sessionId: string, description?: string): SessionEvent {
  let title: string;
  let subtitle: string | undefined;
  let meta: Record<string, string>;
  const qs = questionsIn(p.input);
  if (p.kind === "userInput" && qs.length > 0) {
    meta = questionMetadata(qs);
    title = str(qs[0].header) ?? "選択してください";
    subtitle = str(qs[0].question);
  } else if (p.kind === "plan") {
    meta = { kind: "plan", plan: str(p.input.plan) ?? "", allowsOther: "1", otherPlaceholder: "直してほしいところ" };
    title = "この計画で進めますか？";
    subtitle = toolSummary("ExitPlanMode", p.input);
    // ターミナルの計画の承認は 3 択（自動で編集 / 1 つずつ確認 / 計画を続ける）。
    setOptions(meta, [
      ["自動で編集して進める", "ファイルの編集は確認せずに進めます", "allowAuto"],
      ["1 つずつ確認して進める", "編集のたびに確認します", "allow"],
      ["計画を続ける", "まだ実装に進みません", "deny"]
    ]);
  } else {
    meta = { kind: "approval", allowsOther: "0" };
    title = `「${p.toolName}」を実行しますか？`;
    subtitle = toolSummary(p.toolName, p.input);
    if (p.via === "channel") {
      // 許可の中継は 許可 / 拒否 の 2 つだけ。
      setOptions(meta, [["承認", "一度だけ許可", "allow"], ["非承認", "実行しない", "deny"]]);
    } else {
      const options: Array<[string, string, string]> = [["承認", "一度だけ許可", "allow"]];
      if (p.hasSuggestions) options.push(["このセッションでは承認", "同種の操作を続けて許可", "allowForSession"]);
      options.push(["非承認", "実行しない", "deny"]);
      setOptions(meta, options);
    }
  }
  meta.requestId = p.requestId;
  meta.title = title;
  if (description) meta.subtitle = description;
  else if (subtitle) meta.subtitle = subtitle;
  meta.source = "terminal";
  meta.toolName = p.toolName;
  meta.answerVia = p.via;
  meta.answerable = p.via === "none" ? "0" : "1";
  if (p.via === "none") meta.allowsOther = "0";
  return { type: "action_request", agentId: AGENT, sessionId, messageId: p.requestId, content: title, toolName: p.toolName, metadata: meta };
}

/** 保留のカード。キー入力で答えられるなら 届ける / 取り消す、答えられないなら見せるだけ。 */
export function heldCard(p: TerminalPrompt, sessionId: string, text: string): SessionEvent {
  const why = "このターミナルは許可の確認を省くモード（bypassPermissions）なので、ほかから届いた発話を保留しています。";
  const subtitle =
    p.via === "pty"
      ? `${why}届けるとこのまま Claude に渡ります。`
      : `${why}ターミナルで「Deliver this message to Claude」を選ぶと届きます（5 分で自動的に取り消されます）。\n\n${terminalFixHint(sessionId)}`;
  const meta: Record<string, string> = { kind: "approval", allowsOther: "0" };
  setOptions(meta, [
    ["届ける", "この発話を Claude に渡します", "allow"],
    ["取り消す", "届けずに捨てます", "deny"]
  ]);
  const quoted = toolActivity("", { description: text }).replace(/^[: ]+|[: ]+$/g, "");
  const title = `ターミナルで保留されています${quoted ? `：「${quoted}」` : ""}`;
  Object.assign(meta, {
    requestId: p.requestId,
    title,
    subtitle,
    source: "terminal",
    toolName: p.toolName,
    answerVia: p.via,
    answerable: p.via === "none" ? "0" : "1"
  });
  return { type: "action_request", agentId: AGENT, sessionId, messageId: p.requestId, content: title, toolName: p.toolName, metadata: meta };
}

/* ── 台帳 ─────────────────────────────────────────────────────────── */

interface Live {
  sessionId: string;
  cwd?: string;
  pid?: number;
  transcriptPath?: string;
  startedAt: number;
  inboxSocket?: string;
  messageIds: Map<string, string>;
  currentMessageId?: string;
  generating: boolean;
  subagents: SubagentTracker;
  prompts: TerminalPrompt[];
  pane?: string;
  /** 最後に hook・登録が届いた時刻（pid の分からない会話の掃除に使う。保存しない）。 */
  seenAt: number;
  /** 今のターンが知らせのターン（バックグラウンドの作業が終わって CLI が自分から始めたターン。prompt は
   *  <task-notification> の塊だけ）か。done の metadata に origin = task-notification を付ける。 */
  notificationTurn: boolean;
  /** 今のターンで toolStart を出し、まだ toolEnd を出していない main のツール（出した順）。
   *  中断されたツールには PostToolUse も PostToolUseFailure も来ない（実測）ので、Stop で閉じる。 */
  openTools: Array<{ id: string; name: string }>;
  /** 今のターンの本文（MessageDisplay の message 識別子 → 届いた delta を届いた順に）と、最後に本文が届いたメッセージ。
   *  Stop の last_assistant_message と突き合わせ、足りない分を流す。 */
  chunks: Map<string, string[]>;
  lastMessageKey?: string;
  /** 終わったターンの最後のメッセージ。Stop の後に遅れて届いた、その MessageDisplay を捨てる。 */
  settled?: SettledMessage;
  /** SubagentStart を受けたことがあるか。無ければ hook が古い install（SubagentStart を入れていない）とみなし、
   *  知らない agent_id のツールを今までどおり親のツール行に出す。 */
  sawSubagentStart: boolean;
}

/** Stop の last_assistant_message で流し終えた、ターンの最後のメッセージ。 */
interface SettledMessage {
  text: string;
  /** そのメッセージの MessageDisplay の識別子（Stop までに届いていたもの・後から届いて捨てたもの）。 */
  keys: Set<string>;
  at: number;
}

/** pid の分からない会話を、hook が来なくなってから台帳に残しておく時間（また hook が来れば載せ直す）。 */
const PIDLESS_STALE_MS = 60 * 60_000;

export interface TerminalDeps {
  /** "claude:<sid>" の購読者へ配る（再接続用に記録する。誰も見ていなくても push はしない）。 */
  publish(evt: SessionEvent): void;
  /** 誰も見ていないときの承認の通知。 */
  push(title: string, body: string, data: Record<string, string>): void;
  /** その会話を開いている端末の数（0 なら承認を通知で知らせる）。 */
  watchers(sessionId: string): number;
  inbox: ClaudeChannelInbox;
  keys: TerminalKeyRouter;
  panes: TerminalPaneStatus;
  bridgeId: string;
  /** 台帳の保存先（Bridge の設定フォルダ）。 */
  persistFile: string;
  /** Claude Code のホーム（~/.claude/sessions を読む）。 */
  claudeHome?: string;
  /** claude --bg のワーカーか（hooks で載ったワーカーの承認はカードも push も出さず、interrupt は bg の文を返す。BACKGROUND_CONTROL §7.8）。 */
  isBackgroundWorker?(sessionId: string): boolean;
  /** テスト用: transcript を見張る間隔・保留のカードの期限。 */
  tailIntervalMs?: number;
  heldExpiryMs?: number;
  /** テスト用: hook の応答を持っておく時間。 */
  hookHoldMs?: number;
  /**
   * テスト用: 打ち込みの待ち時間（ターンの終わりを待つ上限・その確かめの間隔・打ち込んだ発話が届くのを待つ時間・コマンドの場合・
   * 操作 1 つごとに足す時間）。
   */
  typingBusyWaitMs?: number;
  typingPollMs?: number;
  typedDeliveryMs?: number;
  typedCommandMs?: number;
  typedKeyMs?: number;
  /**
   * sessions/<pid>.json の status（idle / busy / waiting / shell など）を読む口。テストが差し替える（mac の setStatusReader）。
   * 既定は claudeHome の sessions のファイル。その pid のファイルがこの session のものでなければ undefined を返す。
   */
  readStatus?(pid: number, sessionId: string): string | undefined;
}

/** typePrompt の結果。 */
export type TypingOutcome =
  /** 打ち込んだ。届けば UserPromptSubmit が来る。来なければ typedDeliveryMs（＋操作の数の秒）でエラーを返す。 */
  | "typed"
  /** ターミナルに選択肢（許可確認・質問・計画の承認・保留）か一覧（/model など）が出ている。打った Enter で選んでしまうので打たない。 */
  | "dialogOpen"
  /** ターミナル側のターンが typingBusyWaitMs たっても終わらない。 */
  | "busy"
  /** 打ち込めない（アプリ内ターミナルではない・デスクトップが古い・文が空か長すぎる・sessions のファイルで
   *  その claude だと確かめられない）。呼び元は channel・受け箱へ。 */
  | "unavailable";

/** 先頭がコマンド名（`/compact` など）なら、その名前。`/Users/…` のようなパスはコマンドではない（普通の発話として届く）。 */
export function slashCommand(text: string): string | null {
  const first = text.trim().split(/\s+/)[0] ?? "";
  return /^\/[A-Za-z0-9][A-Za-z0-9:_-]*$/.test(first) ? first : null;
}

/**
 * 人がペアリング済みの端末の入力欄で打った発話の印（mac の dispatch の typedByUser）。server が、ペアリング済みの端末
 * （principal が .device の WebSocket）から届いた user_message / queue_user_message にだけ付ける。.local（この PC の
 * api-key を持つプロセス。デスクトップの会話画面を含む）・mainagent・定期の見回り（submitExternal）と cron の文は
 * 付けないので、受け箱のまま届く（PC の中の別のプロセスや自動の文を、本人の入力としては扱わせない）。
 * イベントの metadata には入れない: 履歴に記録されて再生され、端末が送る JSON でも名乗れてしまうため。
 * イベントの object そのものに付けるので、コピーした object には引き継がれない（予約を送るときは付け直す）。
 */
const typedByUserEvents = new WeakSet<SessionEvent>();

export function markTypedByUser(evt: SessionEvent): void {
  typedByUserEvents.add(evt);
}

export function isTypedByUser(evt: SessionEvent): boolean {
  return typedByUserEvents.has(evt);
}

export function isAlive(pid: number | undefined): boolean {
  if (!pid) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

export class ClaudeTerminalRegistry {
  private readonly live = new Map<string, Live>();
  /** 受け箱経由で送った発話とアプリ内ターミナルに打ち込んだ発話。UserPromptSubmit で同じ文が戻ってきたら二重表示しない。 */
  private readonly inboxSent = new Map<string, string[]>();
  /** アプリ内ターミナルに打ち込んだが、まだ UserPromptSubmit が来ていない送信（session ごとに最新の 1 件）。 */
  private readonly typedPending = new Map<string, number>();
  /**
   * session ごとの打ち込みの列の末尾（mac の typingTail）。前の発話が届く（UserPromptSubmit）か、届かないと決まるまで次を
   * 打たない（続けて送った発話の順が入れ替わったり、前の発話のターンで出た選択肢を次の Enter で選んだりしないように）。
   * 解決するだけで、拒否はしない。
   */
  private readonly typingTail = new Map<string, Promise<void>>();
  /** 受け箱に置いたが、まだ UserPromptSubmit が来ていない送信（session ごとに最新の 1 件）。 */
  private readonly inboxPending = new Map<string, number>();
  /** inboxPending の本文（保留のカードに出す）。 */
  private readonly inboxPendingText = new Map<string, string>();
  /** transcript を見張っている session → 次に読む位置と、見張る理由が無くなった時刻（入れ物の同一性で、古い見張りを止める）。 */
  private readonly tails = new Map<string, { offset: number; idleSince?: number }>();
  private readonly turnWaiters = new Map<string, Set<() => void>>();
  /** Esc を送ったターン（session → currentMessageId）。同じターンに 2 回送らないため。 */
  private readonly interruptedTurns = new Map<string, string>();
  private inboxToken = 0;
  private typedToken = 0;

  constructor(private readonly deps: TerminalDeps) {
    this.restore();
  }

  /* 永続化（Bridge を起こし直しても台帳を失わない。pid が生きているものだけ戻す） */

  private restore(): void {
    try {
      const entries = JSON.parse(fs.readFileSync(this.deps.persistFile, "utf8")) as Array<Partial<Live> & { sessionId: string }>;
      for (const e of entries) {
        if (!e.pid || !isAlive(e.pid)) continue;
        this.live.set(e.sessionId, this.newLive(e.sessionId, e.cwd, e.pid, e.transcriptPath, e.inboxSocket, e.startedAt));
      }
    } catch {
      /* 無い */
    }
  }

  private persist(): void {
    const entries = [...this.live.values()].map((l) => ({
      sessionId: l.sessionId,
      cwd: l.cwd,
      pid: l.pid,
      transcriptPath: l.transcriptPath,
      startedAt: l.startedAt,
      inboxSocket: l.inboxSocket
    }));
    try {
      fs.mkdirSync(path.dirname(this.deps.persistFile), { recursive: true });
      const tmp = `${this.deps.persistFile}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(entries));
      fs.renameSync(tmp, this.deps.persistFile);
    } catch {
      /* 次回 */
    }
  }

  private newLive(sessionId: string, cwd?: string, pid?: number, transcriptPath?: string, inboxSocket?: string, startedAt?: number): Live {
    return {
      sessionId,
      cwd,
      pid,
      transcriptPath,
      inboxSocket,
      startedAt: startedAt ?? Date.now(),
      seenAt: Date.now(),
      messageIds: new Map(),
      generating: false,
      subagents: new SubagentTracker(),
      prompts: [],
      notificationTurn: false,
      openTools: [],
      chunks: new Map(),
      sawSubagentStart: false
    };
  }

  /** ~/.claude/sessions/<pid>.json（Claude Code が実行中セッションごとに書く）から pid と受け箱を引く。 */
  private lookupClaudeProcess(sessionId: string): { pid: number; inboxSocket?: string } | undefined {
    const dir = path.join(this.deps.claudeHome ?? os.homedir(), ".claude", "sessions");
    let best: { pid: number; inboxSocket?: string; startedAt: number } | undefined;
    let names: string[];
    try {
      names = fs.readdirSync(dir);
    } catch {
      return undefined;
    }
    for (const name of sessionFileNames(names)) {
      // 壊れた・後ろにごみの付いたファイルも、読める先頭の JSON で引く（寛容な読み方。BACKGROUND_CONTROL §7.1）。
      const o = readSessionFile(dir, Number.parseInt(name, 10));
      const pid = o?.pid;
      if (!o || o.sessionId !== sessionId || !pid || !isAlive(pid)) continue;
      const startedAt = o.startedAt ?? 0;
      if (best && best.startedAt >= startedAt) continue;
      best = { pid, inboxSocket: o.messagingSocketPath, startedAt };
    }
    return best;
  }

  /** pane: アプリ内ターミナルのペインで起きた会話（buddy-register が X-BuddyOS-Pane で名乗る）。ペインを待機中にする。 */
  register(sessionId: string, cwd?: string, pid?: number, transcriptPath?: string, inboxSocket?: string, pane?: string): void {
    let l = this.live.get(sessionId);
    let resolvedPid = pid ?? l?.pid;
    let socket = inboxSocket;
    if (!resolvedPid) {
      const found = this.lookupClaudeProcess(sessionId);
      if (found) {
        resolvedPid = found.pid;
        socket ??= l?.inboxSocket ?? found.inboxSocket;
      }
    }
    if (l) {
      if (cwd) l.cwd = cwd;
      l.pid = resolvedPid;
      if (transcriptPath) l.transcriptPath = transcriptPath;
      if (socket) l.inboxSocket = socket;
    } else {
      l = this.newLive(sessionId, cwd, resolvedPid, transcriptPath, socket);
      this.live.set(sessionId, l);
    }
    l.seenAt = Date.now();
    if (pane) {
      l.pane = pane;
      // 同じ会話の状態がもうあれば（compact の後の SessionStart など）そのままにする。
      if (this.deps.panes.state(pane, sessionId) === undefined) this.deps.panes.set(pane, "idle", sessionId, l.cwd);
    }
    this.persist();
  }

  /**
   * 終わった会話を台帳から落とす（SessionEnd のとき）。ウィンドウを閉じると SessionEnd を出さずに死ぬので、
   * claude-terminals.json に残ったままになる。pid の分からないものは、しばらく hook が来なければ落とす。
   */
  pruneStale(now = Date.now()): void {
    for (const [sid, l] of [...this.live]) {
      if (!this.isLive(sid)) continue;
      if (!l.pid && now - l.seenAt > PIDLESS_STALE_MS) this.unregister(sid);
    }
  }

  unregister(sessionId: string): void {
    const l = this.live.get(sessionId);
    if (!l) return;
    this.live.delete(sessionId);
    for (const p of l.prompts) p.hookReply?.(undefined);
    if (l.pane) this.deps.panes.remove(l.pane, sessionId);
    this.persist();
    this.inboxPending.delete(sessionId);
    this.inboxPendingText.delete(sessionId);
    this.typedPending.delete(sessionId);
    this.typingTail.delete(sessionId);
    this.tails.delete(sessionId);
    this.interruptedTurns.delete(sessionId);
    this.deps.inbox.forget(sessionId);
    // 会話が終わった（SessionEnd・pid の死）。実行中の行はもう終わりの知らせが来ないので stopped で閉じる
    // （閉じないと server の写しに「実行中」が残り、バックグラウンド印とスリープ抑止が居座る。mac の terminalEnded と同じ）。
    const abandoned = l.subagents.abandonRunning({ state: "stopped" });
    if (abandoned) this.deps.publish(event.workflowProgress(AGENT, sessionId, abandoned));
    if (l.generating) this.deps.publish(event.done(AGENT, sessionId, l.currentMessageId ?? crypto.randomUUID()));
    this.releaseTurn(sessionId);
  }

  /** プロセスが消えていれば台帳から落とす（ウィンドウを閉じると SessionEnd を出さずに死ぬ）。 */
  isLive(sessionId: string): boolean {
    const l = this.live.get(sessionId);
    if (!l) return false;
    if (!l.pid) {
      const found = this.lookupClaudeProcess(sessionId);
      if (found) this.register(sessionId, undefined, found.pid, undefined, l.inboxSocket ? undefined : found.inboxSocket);
    }
    if (l.pid && !isAlive(l.pid)) {
      this.unregister(sessionId);
      return false;
    }
    return true;
  }

  liveEntries(): Array<{ sessionId: string; cwd?: string; startedAt: number; generating: boolean }> {
    for (const sid of [...this.live.keys()]) this.isLive(sid);
    return [...this.live.values()].map((l) => ({ sessionId: l.sessionId, cwd: l.cwd, startedAt: l.startedAt, generating: l.generating }));
  }

  inboxSocket(sessionId: string): string | undefined {
    return this.live.get(sessionId)?.inboxSocket || undefined;
  }

  /** iPhone からの送信のターンが終わるまで待つ（Stop / 終了 / 受け箱に届かない）。 */
  waitTurn(sessionId: string): Promise<void> {
    return new Promise((resolve) => {
      const set = this.turnWaiters.get(sessionId) ?? new Set();
      set.add(resolve);
      this.turnWaiters.set(sessionId, set);
    });
  }

  private releaseTurn(sessionId: string): void {
    const set = this.turnWaiters.get(sessionId);
    this.turnWaiters.delete(sessionId);
    for (const r of set ?? []) r();
  }

  /** iPhone から channel で送った。UserPromptSubmit が来ない場合もあるので、ここでターンを始める。 */
  noteChannelPrompt(sessionId: string): void {
    const l = this.live.get(sessionId);
    if (!l) return;
    startTurn(l, false);
    this.watchInterrupt(sessionId);
  }

  /** transcript の今の末尾。受け箱に書く前に取り、保留の印（すぐ書かれる）を読み落とさないようにする。 */
  transcriptEnd(sessionId: string): number | undefined {
    const file = this.live.get(sessionId)?.transcriptPath;
    if (!file) return undefined;
    try {
      return fs.statSync(file).size;
    } catch {
      return undefined;
    }
  }

  /**
   * 受け箱に置いた発話。UserPromptSubmit で同じ文が戻ってきたら二重表示しない。届かなければ時間切れで戻す。
   * YOLO（bypassPermissions）のターミナルは、送り主の権限モードを名乗らない発話を保留する（Claude Code の
   * cross-session messaging の安全機構）。保留は transcript に「Held peer message」と書かれるので、それを見張る。
   */
  noteInboxPrompt(sessionId: string, text: string, transcriptOffset?: number): void {
    this.rememberSent(sessionId, text);
    const token = ++this.inboxToken;
    this.inboxPending.set(sessionId, token);
    this.inboxPendingText.set(sessionId, text);
    this.ensureTail(sessionId, transcriptOffset);
    const check = (): void => {
      if (this.inboxPending.get(sessionId) !== token) return;
      const l = this.live.get(sessionId);
      if (!l) return;
      if (l.generating) {
        setTimeout(check, INBOX_TIMEOUT_MS).unref();
        return;
      }
      this.inboxPending.delete(sessionId);
      this.inboxPendingText.delete(sessionId);
      const mid = crypto.randomUUID();
      // 保留なら transcript の印で先にカードになっている。ここに来るのは、保留の印も UserPromptSubmit も
      // 無いまま時間が経ったとき（受け手が crossSessionInbound = refuse、受け箱が詰まっている等）。
      this.deps.publish(
        event.error(
          AGENT,
          sessionId,
          `ターミナルの Claude Code がこの発話を受け付けませんでした（${INBOX_TIMEOUT_MS / 1000} 秒たっても反応がありません）。ターミナルを確かめてください。届かないときは、ターミナルで直接入力してください。`
        )
      );
      this.deps.publish({ ...event.done(AGENT, sessionId, mid), metadata: { errored: "true" } });
      this.releaseTurn(sessionId);
    };
    setTimeout(check, INBOX_TIMEOUT_MS).unref();
  }

  /** 送った（受け箱に置いた・打ち込んだ）発話を覚える。UserPromptSubmit で戻ってきたら照合する（直近 20 件）。 */
  private rememberSent(sessionId: string, text: string): void {
    const sent = this.inboxSent.get(sessionId) ?? [];
    sent.push(text.trim());
    if (sent.length > 20) sent.shift();
    this.inboxSent.set(sessionId, sent);
  }

  /**
   * 覚えた発話を 1 件消す。打ち込んだのに届かなかった分の照合の文を消す（残すと、後でターミナルで打った同じ文を自分の
   * 送信と取り違えて、吹き出しにせず隠してしまう）。
   */
  private forgetSent(sessionId: string, text: string): void {
    const sent = this.inboxSent.get(sessionId);
    const i = sent?.indexOf(text) ?? -1;
    if (sent && i >= 0) sent.splice(i, 1);
  }

  private consumeInboxEcho(sessionId: string, prompt: string): boolean {
    const sent = this.inboxSent.get(sessionId);
    const i = sent?.findIndex((s) => s && prompt.includes(s)) ?? -1;
    if (!sent || i < 0) return false;
    sent.splice(i, 1);
    return true;
  }

  /* アプリ内ターミナルへの打ち込み */

  /**
   * 人がペアリング済みの端末の入力欄で打った発話を、デスクトップのアプリ内ターミナルで動く claude に打ち込む。
   * キーボードで打ったのと同じ発話になる（受け箱だと「別のセッションからの依頼」として届き、承認や設定の変更が通らない）。
   * 同じ session への打ち込みは 1 件ずつ、前の発話が届いてから順に行う（typingTail）。呼び元には、自分の打ち込みの結果が
   * 出た時点で返す（届くまでは待たせない）。
   * echo は UserPromptSubmit で戻ってきたときに照合する本文（二重表示しない）。mac の typePrompt と同じ。
   */
  async typePrompt(sessionId: string, text: string, echo: string): Promise<TypingOutcome> {
    const previous = this.typingTail.get(sessionId);
    const attempt = (async (): Promise<TypingOutcome> => {
      await previous;
      return this.typeNow(sessionId, text, echo);
    })();
    // 列の末尾は、この打ち込みが済み、打ったなら届く（か届かないと決まる）まで。失敗でも解決する（次の発話を巻き込まない）。
    const tail: Promise<void> = attempt.then(
      (outcome) => (outcome === "typed" ? this.waitTypedSettled(sessionId) : undefined),
      () => undefined
    );
    this.typingTail.set(sessionId, tail);
    void tail.then(() => {
      // 後ろに続く発話が無ければ、列を空にする（unregister でも消す）。
      if (this.typingTail.get(sessionId) === tail) this.typingTail.delete(sessionId);
    });
    return attempt;
  }

  /** ターンの途中は許可確認などの選択肢がいつ出てもおかしくない（打ち込んだ Enter で選んでしまう）ので、終わるまで待つ。 */
  private async typeNow(sessionId: string, text: string, echo: string): Promise<TypingOutcome> {
    const keys = typingKeys(text);
    if (!keys) return "unavailable";
    const started = Date.now();
    for (;;) {
      // 終わった会話・pid の分からない会話には打てない（宛先の claude を確かめられない）。
      if (!this.isLive(sessionId)) return "unavailable";
      const before = this.live.get(sessionId);
      const pid = before?.pid;
      if (!before || !pid) return "unavailable";
      const pty = await this.typingPtyFor(before);
      if (pty === undefined) return "unavailable";
      // 上の await の間に台帳が変わっていれば読み直す。
      const l = this.live.get(sessionId);
      if (!l || l.pid !== pid) return "unavailable";
      // 状態は Claude Code が書く sessions/<pid>.json を正とする（質問の選択肢が出ている間も busy、/model などの一覧が
      // 開いている間は waiting）。この session のファイルで確かめられない（無い・壊れている・pid の使い回し・古い claude）なら
      // 打たない（台帳の pid が別のプロセスになっていても、そこへ打ち込まない）。hook で追っているターンの進み具合では見ない。
      const status = this.statusOf(pid, sessionId);
      if (status === undefined) return "unavailable";
      if (l.prompts.some((p) => !p.answered) || status === "waiting") return "dialogOpen";
      switch (status) {
        // shell は、返事の後に裏のコマンド（dev サーバーなど）だけが動いている状態。入力欄は空いている
        // （docs/BACKGROUND_CONTROL_2026-10-21.md）。
        case "idle":
        case "shell": {
          // 打ち込むのと同じように整えた文で照合する（\r\n は \n になって戻ってくる）。
          const echoText = sanitizedForTyping(echo).trim();
          this.rememberSent(sessionId, echoText);
          const token = ++this.typedToken;
          this.typedPending.set(sessionId, token);
          this.deps.keys.enqueue({ pid: pty, keys, gapMs: TYPING_GAP_MS, expectPid: pid, expectSession: sessionId });
          this.watchTypedDelivery(sessionId, token, slashCommand(text), echoText, keys.length);
          return "typed";
        }
        case "busy":
          break;
        default:
          // 打ってよいか分からない状態（知らない値）。
          return "unavailable";
      }
      if (Date.now() - started >= (this.deps.typingBusyWaitMs ?? TYPING_BUSY_WAIT_MS)) return "busy";
      await new Promise((r) => setTimeout(r, this.deps.typingPollMs ?? TYPING_POLL_MS));
    }
  }

  /**
   * 打ち込んだ発話が届く（UserPromptSubmit・PreToolUse・Stop）か、届かないと決まる（watchTypedDelivery・unregister）まで待つ。
   * 上限は typingBusyWaitMs。次の発話は、これが済んでから打つ。
   */
  private async waitTypedSettled(sessionId: string): Promise<void> {
    const started = Date.now();
    const limit = this.deps.typingBusyWaitMs ?? TYPING_BUSY_WAIT_MS;
    const every = Math.min(TYPED_SETTLE_POLL_MS, this.deps.typingPollMs ?? TYPING_POLL_MS);
    while (this.typedPending.has(sessionId) && Date.now() - started < limit) {
      await new Promise((r) => setTimeout(r, every));
    }
  }

  /** その会話が動いているデスクトップの pty のうち、発話を打ち込めるもの。ペインを名乗っていればそれで、無ければ親をたどる。 */
  private async typingPtyFor(l: Live): Promise<number | undefined> {
    return this.deps.keys.typingPtyForPane(l.pane) ?? (await this.deps.keys.typingOwner(l.pid));
  }

  private statusOf(pid: number, sessionId: string): string | undefined {
    return this.deps.readStatus ? this.deps.readStatus(pid, sessionId) : this.claudeStatus(pid, sessionId);
  }

  /**
   * Claude Code が書く ~/.claude/sessions/<pid>.json の status（idle / busy / waiting / shell）。読めない・別の session の
   * ファイル（pid の使い回し）のときは undefined。claude 2.1.300 で実測: 許可確認と /model などの一覧の間は waiting
   * （waitingFor が permission prompt・dialog open）、AskUserQuestion の選択肢の間は busy。入力欄の打ちかけ・`!` の
   * bash モードでは idle のまま。
   */
  private claudeStatus(pid: number, sessionId: string): string | undefined {
    const dir = path.join(this.deps.claudeHome ?? os.homedir(), ".claude", "sessions");
    const file = readSessionFile(dir, pid);
    return file?.sessionId === sessionId ? file.status : undefined;
  }

  /**
   * 打ち込んだ発話が届かないまま時間が経ったら、送った側が立てた「考え中」を error + done で戻す。
   * ターミナルで別のターンが進んでいる間は、その後ろで待っているので計時を延ばす。
   * コマンド（`/compact`・`/model` など）は発話にならず UserPromptSubmit が来ないので、打ち込んだことだけ伝える。
   * デスクトップは 1 操作ずつ間をあけて書くので、操作の数（keyCount）の分だけ待ち時間を足す（長い文を分けた貼り付けで
   * 早まって失敗にしない）。
   * 届かなかった分の照合の文（echo）は消す（残すと、後でターミナルで打った同じ文を自分の送信と取り違えて隠す）。
   */
  private watchTypedDelivery(sessionId: string, token: number, command: string | null, echo: string, keyCount: number): void {
    const base = command === null ? (this.deps.typedDeliveryMs ?? TYPED_DELIVERY_MS) : (this.deps.typedCommandMs ?? TYPED_COMMAND_MS);
    const wait = base + Math.max(0, keyCount) * (this.deps.typedKeyMs ?? TYPED_KEY_MS);
    const check = (): void => {
      if (this.typedPending.get(sessionId) !== token) return;
      const l = this.live.get(sessionId);
      if (!l) return;
      if (l.generating) {
        setTimeout(check, wait).unref();
        return;
      }
      this.typedPending.delete(sessionId);
      this.forgetSent(sessionId, echo);
      const mid = crypto.randomUUID();
      if (command !== null) {
        this.deps.publish(event.assistantDelta(AGENT, sessionId, mid, `ターミナルに \`${command}\` を打ち込みました。結果はターミナルに出ます。`));
        this.deps.publish(event.done(AGENT, sessionId, mid));
      } else {
        this.deps.publish(
          event.error(
            AGENT,
            sessionId,
            `アプリ内ターミナルに打ち込もうとしましたが、Claude Code が受け付けませんでした（${wait / 1000} 秒たっても反応がありません）。ターミナルの画面を確かめてください（Claude Code が終わっている、打ち込む途中で許可の確認や一覧が開いた、など。途中まで貼った文が入力欄に残っていることがあります）。`
          )
        );
        this.deps.publish({ ...event.done(AGENT, sessionId, mid), metadata: { errored: "true" } });
      }
      this.releaseTurn(sessionId);
    };
    setTimeout(check, wait).unref();
  }

  /** Bridge が起こしていたターンを、ターミナルへの引き継ぎで閉じる。 */
  publishDone(sessionId: string, messageId?: string): void {
    this.deps.publish(event.done(AGENT, sessionId, messageId ?? crypto.randomUUID()));
  }

  /**
   * サブエージェントのカードの全行（workflow_progress の JSON。subtype "workflow_snapshot"、kind "subagents"、epoch 付き）。
   * 行が無くても agents: [] で返す（アプリが持っている幽霊行を消せるように）。台帳に無ければ undefined。
   * server が接続したときと turn_status_request で送る（行はターンを越えて動き、終わった結果も次の発話まで残す）。
   */
  subagentSnapshot(sessionId: string): string | undefined {
    return this.live.get(sessionId)?.subagents.snapshot({ includeEmpty: true });
  }

  /**
   * バックグラウンドのサブエージェントが動いている session（バックグラウンドのコマンドだけでは数えない）。
   * list_sessions の background に使う。プロセスが消えたもの（SessionEnd を出さずに終わった）は台帳から落としてから返す。
   */
  backgroundSessionIds(): Set<string> {
    for (const [sid, l] of [...this.live]) if (l.subagents.hasRunningAgents) this.isLive(sid);
    return new Set([...this.live.values()].filter((l) => l.subagents.hasRunningAgents).map((l) => l.sessionId));
  }

  /* hook → イベント */

  ingest(hook: Obj, pane?: string): boolean {
    const sid = str(hook.session_id);
    const name = str(hook.hook_event_name);
    if (!sid || !name) return false;
    // サブエージェントの中の hook（main のスレッドは undefined）。
    const subagentId = subagentIdOf(hook);
    // 内部の補助（Stop のたびの次の発話の候補づくり・バックグラウンドのエージェントの要約。agent_id があり、agent_type が
    // 空か無い）は最初に捨てる。行にも親のツール行にもペインの状態にも、受け箱の保留にも使わない。
    if (isInternalHelper(subagentId, hook.agent_type)) return true;
    if (!this.live.has(sid)) this.register(sid, str(hook.cwd), undefined, str(hook.transcript_path));
    const l = this.live.get(sid)!;
    if (pane) l.pane = pane;
    l.seenAt = Date.now();
    const out: SessionEvent[] = [];

    // ツールが実行された・ターンが終わった・次の発話が来た = ターミナルの選択肢は（どこかで）答えられた。
    // 閉じるのは同じスレッド（agent_id が同じ。main は undefined）の選択肢だけ（並んで動くサブエージェントのツールで、
    // 親の選択肢を閉じない）。ツールの実行は同じツールの選択肢だけを閉じる。PreToolUse は選択肢より前に来るので数えない。
    let resolved: SessionEvent[] = [];
    if (name === "PostToolUse" || name === "PostToolUseFailure") resolved = this.resolvePrompts(l, str(hook.tool_name) ?? "", subagentId);
    // 終わったサブエージェントの選択肢は、もう答えられない。
    else if (name === "SubagentStop" && subagentId) resolved = this.resolvePrompts(l, undefined, subagentId);
    // 保留のカードは閉じない（ターミナルのダイアログはターンとは別に残る。届いたら下で閉じる）。
    else if (name === "Stop" || name === "StopFailure" || name === "UserPromptSubmit") resolved = this.resolvePrompts(l, undefined, undefined);
    out.push(...resolved);

    switch (name) {
      case "UserPromptSubmit": {
        // ターミナルで打った発話か、知らせのターン（バックグラウンドの作業が終わって CLI が自分から始めたターン。
        // prompt は <task-notification> の塊だけ）。どちらも新しいターンの始まり。
        const text = str(hook.prompt) ?? "";
        const shown = stripNotifications(text);
        const notification = text.includes("<task-notification>") && shown === "";
        // 前のターンで閉じていないツール行（Stop が来ずに終わった分）は、中断として閉じる。
        out.push(...closeOpenTools(l, "interrupted"));
        startTurn(l, notification);
        // バックグラウンドの作業の完了の知らせは発話として届く。行を閉じ、吹き出しには出さない。
        for (const p of l.subagents.ingestNotifications(text)) out.push(event.workflowProgress(AGENT, sid, p));
        // 終わった行は新しいターンで捨てる（クライアントも送信で捨てる）。知らせのターンでは捨てない
        // （終わった結果をカードに残す。頼んだ人はまだ見ていない）。知らせを取り込んだ後に捨てる: server とアプリは、
        // 上の行の payload の後に届く下の user_message で捨てるので、同じ行が残る（先に捨てると、この発話で閉じた行が
        // トラッカーにだけ残り、接続のたびの subagentSnapshot がアプリの捨てた行を戻す。mac と同じ）。
        if (!notification) l.subagents.pruneFinished();
        // iPhone から送った分は送った側が表示している（記録済み）ので流さない。
        if (shown.includes('<channel source="buddy"')) {
          // 何もしない
        } else if (this.consumeInboxEcho(sid, shown)) {
          // 受け箱の発話が届いた。保留のカードを出していれば閉じる。
          out.push(...this.resolveHeld(l));
        } else if (shown) {
          out.push({ type: "user_message", agentId: AGENT, sessionId: sid, messageId: crypto.randomUUID(), content: shown });
        }
        break;
      }
      case "MessageDisplay": {
        // 行バッチ単位の本文。message 識別子ごとに 1 バブル。サブエージェントの本文は親の吹き出しに混ぜない。
        if (subagentId) break;
        const delta = str(hook.delta) ?? "";
        const key = str(hook.message_id) ?? str(hook.messageId) ?? str(hook.turn_id) ?? l.currentMessageId ?? "turn";
        // 終わったターンの最後のメッセージが Stop より遅れて届いた（Stop の last_assistant_message で流し終えている）。
        if (isLateSettled(l, key, delta)) return true;
        let mid = l.messageIds.get(key);
        if (!mid) {
          mid = l.currentMessageId && l.messageIds.size === 0 ? l.currentMessageId : crypto.randomUUID();
          l.messageIds.set(key, mid);
          l.currentMessageId ??= mid;
        }
        if (delta) {
          l.chunks.set(key, [...(l.chunks.get(key) ?? []), delta]);
          l.lastMessageKey = key;
          out.push(event.assistantDelta(AGENT, sid, mid, delta));
        }
        break;
      }
      case "PreToolUse": {
        const tool = str(hook.tool_name) ?? "tool";
        if (subagentId) {
          // サブエージェントの中のツールは親のツール行に混ぜず、サブエージェントの行に出す。
          if (l.subagents.has(subagentId)) {
            const p = l.subagents.hookTool(subagentId, tool, hook.tool_input);
            if (p) out.push(event.workflowProgress(AGENT, sid, p));
            break;
          }
          // 行にしていないもの（起動の PreToolUse を伴わない SubagentStart・知らない agent_id）は出さない。
          // SubagentStart を一度も受けていない（hook が古い install）ときだけ、今までどおり親のツール行に出す。
          if (l.subagents.isIgnored(subagentId) || l.sawSubagentStart) break;
        } else {
          l.subagents.noteLaunch(tool, hook.tool_input, str(hook.tool_use_id));
        }
        const id = str(hook.tool_use_id) ?? crypto.randomUUID();
        out.push(event.toolStart(AGENT, sid, id, tool, toolTitle(tool, hook.tool_input), "tool"));
        if (!subagentId) l.openTools.push({ id, name: tool });
        break;
      }
      case "PostToolUse":
      case "PostToolUseFailure": {
        const tool = str(hook.tool_name) ?? "tool";
        const toolUseId = str(hook.tool_use_id);
        const failed = name === "PostToolUseFailure";
        if (subagentId) {
          // サブエージェントの中のツールは toolStart を出していない。ただ、起動（Agent の async_launched）と停止（TaskStop）は
          // tool_response に相手の id が入っているので、どのスレッドのものでもその行に効かせる。
          if (!failed && (isAgentTool(tool) || tool === "TaskStop" || tool === "KillShell")) {
            const p = l.subagents.hookToolResult(toolUseId, tool, hook.tool_input, hook.tool_response);
            if (p) out.push(event.workflowProgress(AGENT, sid, p));
          }
          if (l.subagents.has(subagentId) || l.subagents.isIgnored(subagentId) || l.sawSubagentStart) break;
        }
        const id = toolUseId ?? crypto.randomUUID();
        const summary = preview(hook.tool_response ?? hook.error, 200);
        out.push(event.toolEnd(AGENT, sid, id, tool, failed ? "failed" : "completed", summary));
        if (subagentId) break;
        l.openTools = l.openTools.filter((t) => t.id !== id);
        // バックグラウンドで起動したもの（run_in_background の Bash・Monitor・Agent の async_launched）は、終わるまで
        // カードの行で見せる。TaskStop は止めた行をすぐ stopped で閉じる（止めたシェルには完了の知らせが来ない）。
        const p = failed ? undefined : l.subagents.hookToolResult(toolUseId, tool, hook.tool_input, hook.tool_response);
        if (p) out.push(event.workflowProgress(AGENT, sid, p));
        break;
      }
      case "SubagentStart": {
        if (!subagentId) break;
        l.sawSubagentStart = true;
        const p = l.subagents.hookStart(subagentId, str(hook.agent_type));
        if (p) out.push(event.workflowProgress(AGENT, sid, p));
        break;
      }
      case "SubagentStop": {
        // SubagentStop の background_tasks は、終わったサブエージェント自身を running のまま含むので照合に使わない
        // （照合は Stop の一覧だけ）。
        if (!subagentId) break;
        const p = l.subagents.hookStop(subagentId, str(hook.agent_type), str(hook.last_assistant_message));
        if (p) out.push(event.workflowProgress(AGENT, sid, p));
        break;
      }
      case "Stop":
      case "StopFailure": {
        // ターン完了。server はこれで生成中を落とす。StopFailure は API エラーでターンが終わったとき（このときは Stop が来ない）。
        const mid = l.currentMessageId ?? crypto.randomUUID();
        const interrupted = hook.buddy_interrupted === true;
        // Esc で中断したとき（watchInterrupt が送る）。前景のサブエージェントには SubagentStop が来ないので、ここで閉じる
        // （閉じないと行が「実行中」のまま残る）。バックグラウンドのサブエージェントとシェルは Esc では止まらない
        // （実測。後から SubagentStop と知らせのターンが来る）ので閉じない。
        if (interrupted) {
          const p = l.subagents.abandonRunning({ state: "stopped", includeShells: false, onlyForeground: true });
          if (p) out.push(event.workflowProgress(AGENT, sid, p));
        }
        // Stop hook はその時点で動いているバックグラウンドの作業の一覧を持つ。行の状態を合わせる。
        const reconciled = l.subagents.reconcile(hook.background_tasks);
        if (reconciled) out.push(event.workflowProgress(AGENT, sid, reconciled));
        // 開いたままのツール行を閉じる（中断されたツールには PostToolUse も PostToolUseFailure も来ない）。
        out.push(...closeOpenTools(l, interrupted ? "interrupted" : name === "StopFailure" ? "failed" : "completed"));
        // 吹き出しの本文を last_assistant_message で確かめ、足りない分を done の前に流す
        // （最後の MessageDisplay は Stop より遅れて届くことがある）。
        const last = str(hook.last_assistant_message);
        if (!interrupted && last !== undefined) out.push(...settleLastMessage(l, last, mid));
        if (name === "StopFailure") {
          const detail = preview(hook.error_details ?? hook.error, 200) ?? "";
          out.push(event.error(AGENT, sid, `ターミナルの Claude Code のターンがエラーで終了しました${detail ? `（${detail}）` : ""}`));
        }
        const done = event.done(AGENT, sid, mid);
        // 知らせのターンの done（誰も頼んでいないターン。server はバックグラウンドの作業の完了として扱う）。
        out.push(l.notificationTurn ? { ...done, metadata: { origin: "task-notification" } } : done);
        l.currentMessageId = undefined;
        l.messageIds.clear();
        l.chunks.clear();
        l.lastMessageKey = undefined;
        l.generating = false;
        l.notificationTurn = false;
        break;
      }
      case "PermissionRequest":
      case "Notification": {
        if (str(hook.notification_type) === "permission_prompt" || name === "PermissionRequest") break;
        const msg = str(hook.message) ?? str(hook.title);
        if (msg) out.push(event.activity(AGENT, sid, l.currentMessageId ?? "system", msg));
        break;
      }
      case "SessionEnd":
        this.unregister(sid);
        return true;
      default:
        return false;
    }
    // ターンが動いている印（main のスレッドの発話・ツール・Stop）があれば、受け箱の発話・打ち込んだ発話は届いた（かターミナル側の
    // ターンの後ろで待っている）。どちらでも Stop の done で送った側の「考え中」は戻る。サブエージェントの hook
    // （ターンの外でも動く）と、本文・承認待ちの通知は数えない。
    if (!subagentId && (name === "UserPromptSubmit" || name === "PreToolUse" || name === "Stop")) {
      this.inboxPending.delete(sid);
      this.typedPending.delete(sid);
    }
    for (const e of out) this.deps.publish(e);
    if (name === "Stop" || name === "StopFailure") this.releaseTurn(sid);
    if (name === "UserPromptSubmit") this.watchInterrupt(sid);
    // バックグラウンドの作業が動いている間は、transcript に積まれる完了の知らせを見張る。
    if (l.subagents.hasRunning) this.ensureTail(sid);
    this.notePane(l, name, hook, resolved.length > 0);
    return true;
  }

  /** PermissionRequest hook。ターミナルに選択肢が出た。iPhone / デスクトップにカードで出す（hook には何も返さない）。 */
  async ingestPermission(hook: Obj, pane?: string): Promise<boolean> {
    return (await this.ingestPermissionHeld(hook, pane, false)).handled;
  }

  /**
   * PermissionRequest hook。canHold（hook が応答を待てる版）で、キー入力でも channel でも答えられないとき
   * （ターミナルの外の claude）は、hook の応答を持っておき、カードの答えを応答（hookSpecificOutput）で返す。
   * Claude Code は hook と並べてターミナルにも選択肢を出すので、ターミナルで先に選ばれても困らない。
   * decision は応答の本文（undefined = 空で返す）。cancel は hook が先に切れたとき。
   */
  async ingestPermissionHeld(
    hook: Obj,
    pane: string | undefined,
    canHold: boolean
  ): Promise<{ handled: boolean; decision?: Promise<Obj | undefined>; cancel?: () => void }> {
    const sid = str(hook.session_id);
    if (!sid) return { handled: false };
    if (!this.live.has(sid)) this.register(sid, str(hook.cwd), undefined, str(hook.transcript_path));
    const l = this.live.get(sid)!;
    if (pane) l.pane = pane;
    l.seenAt = Date.now();
    this.notePane(l, "PermissionRequest", hook);
    // バックグラウンドのワーカーの承認は、スマホから答えられない。一覧と会話のカードの「承認待ち」で見せる。
    if (this.deps.isBackgroundWorker?.(sid)) return { handled: true };
    const pty = await this.ptyFor(l);
    const channel = this.deps.inbox.isConnected(sid);
    const tool = str(hook.tool_name) ?? "tool";
    const input = obj(hook.tool_input);
    const suggestions = Array.isArray(hook.permission_suggestions) ? hook.permission_suggestions : [];
    // サブエージェントの選択肢なら、その agent_id（main は undefined）。
    const subagentId = subagentIdOf(hook);
    // channel の依頼で先にカードを出していれば重ねない。
    if (l.prompts.some((p) => !p.fromHook && !p.answered && p.toolName === tool && Date.now() - p.createdAt < 10_000)) return { handled: true };
    // 同じスレッドの前の選択肢は答えられている（次の選択肢が出た）。
    const out = this.resolvePrompts(l, undefined, subagentId);
    const isQuestion = tool === "AskUserQuestion" && questionsIn(input).length > 0;
    const kind: TerminalPrompt["kind"] = isQuestion ? "userInput" : tool === "ExitPlanMode" ? "plan" : "approval";
    // 応答で返せるのは許可 / 拒否だけ（質問・計画は答えの形が違う）。
    const via: TerminalPrompt["via"] =
      pty !== undefined ? "pty" : kind === "approval" && channel ? "channel" : kind === "approval" && canHold ? "hook" : "none";
    const prompt: TerminalPrompt = {
      requestId: `term-${crypto.randomUUID().slice(0, 8)}`,
      kind,
      toolName: tool,
      input,
      hasSuggestions: suggestions.length > 0,
      via,
      fromHook: true,
      createdAt: Date.now(),
      answered: false,
      suggestions,
      agentId: subagentId
    };
    let held: { decision: Promise<Obj | undefined>; cancel: () => void } | undefined;
    if (via === "hook") held = this.holdHook(l, prompt);
    l.prompts.push(prompt);
    out.push(terminalCard(prompt, sid));
    for (const e of out) this.deps.publish(e);
    if (this.deps.watchers(sid) === 0) this.pushPrompt(prompt, sid);
    return { handled: true, ...held };
  }

  /**
   * hook の応答を持つ。時間切れになったら、カードは見せるだけに戻す（もう答えを返せない）。
   * hook が先に切れた（ターミナルで選ばれた・claude が終わった）ら、カードを閉じる。
   */
  private holdHook(l: Live, prompt: TerminalPrompt): { decision: Promise<Obj | undefined>; cancel: () => void } {
    let settle!: (out: Obj | undefined) => void;
    const decision = new Promise<Obj | undefined>((resolve) => {
      settle = resolve;
    });
    const release = (closeCard: boolean): void => {
      if (!prompt.hookReply) return;
      prompt.hookReply(undefined);
      if (prompt.answered || !l.prompts.includes(prompt) || this.live.get(l.sessionId) !== l) return;
      if (closeCard) {
        l.prompts = l.prompts.filter((p) => p !== prompt);
        this.deps.publish({ type: "action_resolved", agentId: AGENT, sessionId: l.sessionId, messageId: prompt.requestId });
        return;
      }
      prompt.via = "none";
      this.deps.publish(terminalCard(prompt, l.sessionId));
    };
    const timer = setTimeout(() => release(false), this.deps.hookHoldMs ?? HOOK_HOLD_MS);
    timer.unref();
    prompt.hookReply = (out) => {
      prompt.hookReply = undefined;
      clearTimeout(timer);
      settle(out);
    };
    return { decision, cancel: () => release(true) };
  }

  /** その会話が動いているデスクトップの pty の pid。ペインを名乗っていればそれで、無ければ親をたどる。 */
  private async ptyFor(l: Live): Promise<number | undefined> {
    return this.deps.keys.ptyForPane(l.pane) ?? (await this.deps.keys.ptyOwner(l.pid));
  }

  /** channel（buddy-channel）が受けた許可の依頼。hook のカードに依頼 id を結びつける（無ければ channel の情報でカードを出す）。 */
  channelPermission(sid: string, requestId: string, toolName: string, description?: string, inputPreview?: string): void {
    const l = this.live.get(sid);
    if (!l) return;
    // 結び付けるのは、同じツールで、少し前に出した、引数の要約が食い違わないカードだけ（ツール名だけで結ぶと、
    // 前のカードへの答えが後から来た別の依頼に使われる）。先に答えた verdict は、引数の要約が一致したときに 1 回だけ使う。
    const existing = [...l.prompts]
      .reverse()
      .find((p) => p.kind === "approval" && p.toolName === toolName && !p.channelRequestId && Date.now() - p.createdAt < CHANNEL_BIND_MS && inputPreviewMatches(p.input, inputPreview) !== false);
    if (existing && (!existing.verdict || inputPreviewMatches(existing.input, inputPreview) === true)) {
      existing.channelRequestId = requestId;
      if (existing.verdict) {
        const verdict = existing.verdict;
        existing.verdict = undefined;
        this.deps.inbox.postPermission(sid, requestId, verdict);
      }
      return;
    }
    // 答えを確かめられない古い verdict は捨て、この依頼は改めてカードで聞く。
    if (existing) existing.verdict = undefined;
    const out = this.resolvePrompts(l, undefined, undefined);
    const prompt: TerminalPrompt = {
      requestId: `term-${crypto.randomUUID().slice(0, 8)}`,
      kind: "approval",
      toolName,
      input: {},
      hasSuggestions: false,
      via: "channel",
      fromHook: false,
      createdAt: Date.now(),
      channelRequestId: requestId,
      answered: false
    };
    l.prompts.push(prompt);
    out.push(terminalCard(prompt, sid, [description, inputPreview].filter(Boolean).join("\n")));
    for (const e of out) this.deps.publish(e);
    if (this.deps.watchers(sid) === 0) this.pushPrompt(prompt, sid);
  }

  /** iPhone / デスクトップで選んだ答えをターミナルへ届ける。届けられなかったら理由を返す。 */
  async answer(sid: string, requestId: string, decision: string, meta: Record<string, string>): Promise<string | undefined> {
    const l = this.live.get(sid);
    const prompt = l?.prompts.find((p) => p.requestId === requestId);
    if (!l || !prompt || prompt.answered) return undefined;
    if (prompt.via === "channel") {
      const behavior = decision.startsWith("allow") ? "allow" : "deny";
      prompt.answered = true;
      if (prompt.channelRequestId) this.deps.inbox.postPermission(sid, prompt.channelRequestId, behavior);
      else prompt.verdict = behavior;
      return undefined;
    }
    if (prompt.via === "hook") {
      if (!prompt.hookReply) return "この選択肢はもうここからは答えられません。ターミナルで選んでください。";
      const allow = decision.startsWith("allow");
      const d: Obj = { behavior: allow ? "allow" : "deny" };
      if (decision === "allowForSession" && prompt.suggestions?.length) d.updatedPermissions = prompt.suggestions;
      if (!allow) d.message = "BuddyOS で非承認にしました";
      prompt.answered = true;
      prompt.hookReply({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: d } });
      // 非承認だと PostToolUse が来ないので、ここでカードを閉じる。
      l.prompts = l.prompts.filter((p) => p !== prompt);
      this.deps.publish({ type: "action_resolved", agentId: AGENT, sessionId: sid, messageId: requestId });
      return undefined;
    }
    if (prompt.via === "pty") {
      const pty = await this.ptyFor(l);
      if (pty === undefined) return "デスクトップのターミナルに届けられませんでした。ターミナルで選んでください。";
      let keys: string[] | undefined;
      if (prompt.kind === "held") keys = heldKeys(decision);
      else if (prompt.kind === "userInput") {
        const qs = questionsIn(prompt.input);
        keys = questionKeys(qs, answerLists(meta, decision, qs));
      } else if (prompt.kind === "plan") keys = planKeys(decision);
      else keys = approvalKeys(decision, prompt.hasSuggestions);
      if (!keys) return "すべての質問に答えてください。";
      if (prompt.answered) return undefined;
      prompt.answered = true;
      // 取り消しは hook が来ないので、ここでカードを閉じる（届けるなら UserPromptSubmit で閉じる）。
      if (prompt.kind === "held" && !decision.startsWith("allow")) {
        l.prompts = l.prompts.filter((p) => p !== prompt);
        this.deps.publish({ type: "action_resolved", agentId: AGENT, sessionId: sid, messageId: requestId });
      }
      this.deps.keys.enqueue({ pid: pty, keys, gapMs: 800 });
      return undefined;
    }
    return `この選択肢はターミナルで選んでください。${terminalFixHint(sid)}`;
  }

  /**
   * iPhone / デスクトップの停止。デスクトップのアプリ内ターミナルで動いていれば、そのペインに Esc を送る
   * （ターミナルで Esc を押したのと同じ）。ターンを閉じるのは、transcript の中断の印を見る見張り。
   * Esc を 2 回続けると Claude Code は巻き戻しの画面を開くので、1 つのターンには 1 回だけ送る。
   * 返り値は届けられなかったときの理由（undefined = 送った / 止めるターンが無い）。mac と同じ。
   */
  async interrupt(sid: string): Promise<string | undefined> {
    if (this.deps.isBackgroundWorker?.(sid)) return BG_INTERRUPT_TEXT;
    const l = this.live.get(sid);
    const turn = l?.currentMessageId;
    if (!l?.generating || !turn || this.interruptedTurns.get(sid) === turn) return undefined;
    const pty = await this.ptyFor(l);
    if (pty === undefined) return "デスクトップのターミナルで動いていないため、ここからは止められません。ターミナルで Esc を押してください。";
    this.interruptedTurns.set(sid, turn);
    this.deps.keys.enqueue({ pid: pty, keys: [ESC], gapMs: 0 });
    return undefined;
  }

  /**
   * 出しているカードのうち、agentId のスレッド（main は undefined）のものを閉じる（toolName を渡すとそのツールの分だけ）。
   * 保留のカードは resolveHeld で閉じる。
   */
  private resolvePrompts(l: Live, toolName: string | undefined, agentId: string | undefined): SessionEvent[] {
    const matches = (p: TerminalPrompt): boolean =>
      p.kind !== "held" && p.agentId === agentId && (toolName === undefined || p.toolName === toolName);
    const closing = l.prompts.filter(matches);
    if (closing.length === 0) return [];
    l.prompts = l.prompts.filter((p) => !matches(p));
    // ターミナルで選ばれた。持っている hook の応答は空で返す。
    for (const p of closing) p.hookReply?.(undefined);
    return closing.map((p) => ({ type: "action_resolved", agentId: AGENT, sessionId: l.sessionId, messageId: p.requestId }));
  }

  /** 保留のカードを閉じる（発話が届いた・時間切れ）。 */
  private resolveHeld(l: Live): SessionEvent[] {
    const closing = l.prompts.filter((p) => p.kind === "held");
    if (closing.length === 0) return [];
    l.prompts = l.prompts.filter((p) => p.kind !== "held");
    return closing.map((p) => ({ type: "action_resolved", agentId: AGENT, sessionId: l.sessionId, messageId: p.requestId }));
  }

  /* transcript の見張り（受け箱の保留・バックグラウンドの作業の完了） */

  /**
   * transcript の見張りを始める（動いていれば、読む位置を from まで戻すだけ）。
   * 見張るのは、受け箱の発話の行方が分からない間と、バックグラウンドの作業が動いている間だけ。
   */
  private ensureTail(sid: string, from?: number): void {
    const file = this.live.get(sid)?.transcriptPath;
    if (!file) return;
    const cur = this.tails.get(sid);
    if (cur) {
      if (from !== undefined && from < cur.offset) cur.offset = from;
      return;
    }
    let start = from;
    if (start === undefined) {
      try {
        start = fs.statSync(file).size;
      } catch {
        start = 0;
      }
    }
    const state: { offset: number; idleSince?: number } = { offset: start };
    this.tails.set(sid, state);
    const interval = this.deps.tailIntervalMs ?? TAIL_INTERVAL_MS;
    const tick = async (): Promise<void> => {
      // 保留のカードの答え方（キー入力で答えられるか）は先に調べる（以降は await を挟まずに台帳を書き換える）。
      const cur = this.live.get(sid);
      const pty = cur && this.inboxPending.has(sid) ? await this.ptyFor(cur) : undefined;
      const l = this.live.get(sid);
      if (this.tails.get(sid) !== state) return;
      if (!l || l.transcriptPath !== file || !this.keepTailing(sid, l, state)) {
        this.tails.delete(sid);
        return;
      }
      const { lines, next } = readJsonLines(file, state.offset);
      state.offset = next;
      const out: SessionEvent[] = [];
      for (const o of lines) {
        const text = str(o.content);
        if (o.type === "system" && text?.startsWith("Held peer message") && this.inboxPending.has(sid)) {
          out.push(...this.held(l, pty));
        } else if (o.type === "queue-operation" && o.operation === "enqueue" && text) {
          // バックグラウンドの作業の完了の知らせ。積まれた時点で書かれる（発話として届くのはターンの後）。
          for (const p of l.subagents.ingestNotifications(text)) out.push(event.workflowProgress(AGENT, sid, p));
        }
      }
      for (const e of out) this.deps.publish(e);
      if (out.length > 0) this.notePaneBackground(l);
      setTimeout(() => void tick(), interval).unref();
    };
    setTimeout(() => void tick(), interval).unref();
  }

  /** 見張りを続けるか。受け箱の発話の行方が分からない間と、バックグラウンドの作業が動いている間。
   *  どちらも無くなってからも TAIL_GRACE_MS は読む。 */
  private keepTailing(sid: string, l: Live, state: { idleSince?: number }): boolean {
    if (this.inboxPending.has(sid) || l.subagents.hasRunning) {
      state.idleSince = undefined;
      return true;
    }
    if (state.idleSince === undefined) {
      state.idleSince = Date.now();
      return true;
    }
    return Date.now() - state.idleSince < TAIL_GRACE_MS;
  }

  /**
   * 受け箱の発話がターミナルで保留された。iPhone の「考え中」を終わらせ、保留のカードを出す。
   * デスクトップのアプリ内ターミナルなら、カードから Deliver / Deny をキー入力で選べる。
   */
  private held(l: Live, pty: number | undefined): SessionEvent[] {
    const sid = l.sessionId;
    const text = this.inboxPendingText.get(sid) ?? "";
    this.inboxPendingText.delete(sid);
    this.inboxPending.delete(sid);
    const out = this.resolveHeld(l);
    const prompt: TerminalPrompt = {
      requestId: `held-${crypto.randomUUID().slice(0, 8)}`,
      kind: "held",
      toolName: "BuddyOS",
      input: { text },
      hasSuggestions: false,
      via: pty !== undefined ? "pty" : "none",
      fromHook: true,
      createdAt: Date.now(),
      answered: false
    };
    l.prompts.push(prompt);
    // 送った側が立てた「考え中」を戻す。応答の通知は送らない。
    out.push({ ...event.done(AGENT, sid, crypto.randomUUID()), metadata: { errored: "true" } });
    out.push(heldCard(prompt, sid, text));
    this.releaseTurn(sid);
    if (this.deps.watchers(sid) === 0) {
      this.deps.push("claude", "ターミナルの Claude Code が iPhone からの発話を保留しています。ターミナルで「Deliver」を選ぶと届きます", {
        kind: "approval_request",
        agentId: AGENT,
        sessionId: sid,
        requestId: prompt.requestId,
        bridgeId: this.deps.bridgeId
      });
    }
    setTimeout(() => this.expireHeld(sid, prompt.requestId), this.deps.heldExpiryMs ?? HELD_EXPIRY_MS).unref();
    return out;
  }

  /** 保留のカードが出たまま時間が経った。ターミナル側で時間切れになったか、Deny されている。 */
  private expireHeld(sid: string, requestId: string): void {
    const l = this.live.get(sid);
    if (!l || !l.prompts.some((p) => p.requestId === requestId)) return;
    l.prompts = l.prompts.filter((p) => p.requestId !== requestId);
    this.deps.publish({ type: "action_resolved", agentId: AGENT, sessionId: sid, messageId: requestId });
    this.deps.publish(
      event.error(AGENT, sid, "ターミナルで保留されていた発話は届きませんでした（時間切れか、ターミナルで Deny されました）。もう一度送ってください。")
    );
  }

  private pushPrompt(p: TerminalPrompt, sid: string): void {
    const body =
      p.kind === "userInput"
        ? "ターミナルの Claude Code が質問しています"
        : p.kind === "plan"
          ? "ターミナルの Claude Code が計画の承認を待っています"
          : `ターミナルの Claude Code が「${p.toolName}」の許可を待っています`;
    this.deps.push("claude", body, { kind: "approval_request", agentId: AGENT, sessionId: sid, requestId: p.requestId, bridgeId: this.deps.bridgeId });
  }

  /**
   * デスクトップのアプリ内ターミナルで動いているなら、ペインの状態（TerminalPaneStatus）を書く。
   * 動いているバックグラウンドの作業の数は、状態が変わらない hook でも毎回書く。
   * resolvedPrompt: この hook で選択肢を閉じた（サブエージェントの選択肢は、そのサブエージェントのツールの実行・終わりで閉じる）。
   */
  private notePane(l: Live, name: string, hook: Obj, resolvedPrompt = false): void {
    if (!l.pane) return;
    const panes = this.deps.panes;
    const background = {
      agents: l.subagents.runningAgentCount,
      shells: l.subagents.runningShellCount,
      onlyAgents: l.subagents.runningBackgroundOnlyAgentCount
    };
    const current = panes.state(l.pane, l.sessionId);
    let state = paneState(name, hook, current);
    // サブエージェントの hook は状態を変えないが、その選択肢が閉じてほかに出ていなければ attention を外す
    // （main のターンが動いていれば作業中、終わっていれば idle。終わった 1 回には数えない）。
    if (state === undefined && resolvedPrompt && current === "attention" && !l.prompts.some((p) => p.kind !== "held")) {
      state = l.generating ? "working" : "idle";
    }
    if (state === undefined) {
      // main の本文はターンの動きとして覚える（UserPromptSubmit の来ないターンも、次の Stop の done で 1 回に数える）。
      panes.note(l.pane, l.sessionId, { activity: name === "MessageDisplay" && subagentIdOf(hook) === undefined, background });
      return;
    }
    // 返事が終わった（done）ときだけ、その返事の文を持たせる（デスクトップの音声会話が読み上げる）。
    const reply = state === "done" && name === "Stop" ? str(hook.last_assistant_message) : undefined;
    panes.set(l.pane, state, l.sessionId, l.cwd, "claude", reply, background);
  }

  /** 動いているバックグラウンドの作業の数だけをペインに書く（transcript の知らせで行が閉じたとき）。 */
  private notePaneBackground(l: Live): void {
    if (!l.pane) return;
    this.deps.panes.note(l.pane, l.sessionId, {
      background: {
        agents: l.subagents.runningAgentCount,
        shells: l.subagents.runningShellCount,
        onlyAgents: l.subagents.runningBackgroundOnlyAgentCount
      }
    });
  }

  /** Esc で中断したターンには Stop が来ない。transcript の「[Request interrupted by user」を見張り、来たら Stop と同じく閉じる。 */
  private watchInterrupt(sessionId: string): void {
    const l = this.live.get(sessionId);
    const file = l?.transcriptPath;
    const turn = l?.currentMessageId;
    if (!file || !turn) return;
    let offset = 0;
    try {
      offset = fs.statSync(file).size;
    } catch {
      /* まだ無い */
    }
    const tick = (): void => {
      const cur = this.live.get(sessionId);
      if (!cur || !cur.generating || cur.currentMessageId !== turn) return;
      const { interrupted, next } = scanInterrupt(file, offset);
      offset = next;
      if (interrupted) {
        this.ingest({ session_id: sessionId, hook_event_name: "Stop", buddy_interrupted: true });
        return;
      }
      setTimeout(tick, INTERRUPT_POLL_MS).unref();
    };
    setTimeout(tick, INTERRUPT_POLL_MS).unref();
  }
}

/** 1 回に読む上限。改行の無いまま上限まで届いた行（大きな tool_result・画像の base64）は捨てて先へ進める（永久に止まらない）。 */
export const READ_JSON_LINES_MAX_BYTES = 32 * 1024 * 1024;

/** file の offset 以降の、書き終わった行（JSON）と、次に読む位置。縮んだ（作り直された）ら末尾から読み直す。 */
export function readJsonLines(file: string, offset: number, maxBytes = READ_JSON_LINES_MAX_BYTES): { lines: Obj[]; next: number } {
  let size: number;
  try {
    size = fs.statSync(file).size;
  } catch {
    return { lines: [], next: offset };
  }
  if (size <= offset) return { lines: [], next: size };
  let buf: Buffer;
  const fd = fs.openSync(file, "r");
  try {
    buf = Buffer.alloc(Math.min(size - offset, maxBytes));
    fs.readSync(fd, buf, 0, buf.length, offset);
  } finally {
    fs.closeSync(fd);
  }
  const lastNl = buf.lastIndexOf(0x0a);
  // 改行が無いまま上限まで読んだ行は、その分を捨てて進める（残りは途中の行として JSON に読めず、次の改行で終わる）。
  if (lastNl < 0) return { lines: [], next: buf.length >= maxBytes ? offset + buf.length : offset };
  const lines: Obj[] = [];
  for (const line of buf.subarray(0, lastNl + 1).toString("utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      lines.push(obj(JSON.parse(line)));
    } catch {
      /* 途中の行 */
    }
  }
  return { lines, next: offset + lastNl + 1 };
}

export function scanInterrupt(file: string, offset: number): { interrupted: boolean; next: number } {
  const { lines, next } = readJsonLines(file, offset);
  const marker = "[Request interrupted by user";
  for (const o of lines) {
    if (o.type !== "user" || o.isSidechain === true) continue;
    const content = obj(o.message).content;
    if (typeof content === "string" && content.startsWith(marker)) return { interrupted: true, next };
    if (Array.isArray(content) && content.some((b) => obj(b).type === "text" && String(obj(b).text ?? "").startsWith(marker))) {
      return { interrupted: true, next };
    }
  }
  return { interrupted: false, next };
}

export function toolTitle(name: string, input: unknown): string {
  const d = obj(input);
  for (const k of ["command", "file_path", "path", "pattern", "url", "query", "prompt", "description"]) {
    if (typeof d[k] === "string" && d[k]) return preview(d[k], 120) ?? name;
  }
  return name;
}

function preview(v: unknown, limit: number): string | undefined {
  if (v === undefined || v === null) return undefined;
  const s = typeof v === "string" ? v : JSON.stringify(v);
  const t = (s ?? "").trim();
  return t.length > limit ? `${t.slice(0, limit)}…` : t;
}

/* ── ターン（mac の ClaudeTerminalRegistry と同じ） ────────────────────── */

/** サブエージェントの中の hook なら、その agent_id（main のスレッドは undefined）。 */
function subagentIdOf(hook: Obj): string | undefined {
  const id = str(hook.agent_id);
  return id ? id : undefined;
}

/** 新しいターンを始める（UserPromptSubmit・channel の送信）。前のターンの吹き出しと、突き合わせの分を捨てる。 */
function startTurn(l: Live, notification: boolean): void {
  l.currentMessageId = crypto.randomUUID();
  l.messageIds.clear();
  l.chunks.clear();
  l.lastMessageKey = undefined;
  l.settled = undefined;
  l.generating = true;
  l.notificationTurn = notification;
}

/** 今のターンで toolStart を出したまま toolEnd の来ていない main のツール行を閉じる（status は completed /
 *  interrupted / failed）。中断されたツールには PostToolUse も PostToolUseFailure も来ない（実測）。 */
function closeOpenTools(l: Live, status: string): SessionEvent[] {
  const open = l.openTools;
  l.openTools = [];
  return open.map((t) => event.toolEnd(AGENT, l.sessionId, t.id, t.name, status));
}

/**
 * Stop の last_assistant_message（ターンの最後のメッセージの本文）で吹き出しを確かめ、足りない分の delta を返す。
 * 最後の MessageDisplay は Stop より遅れて届くことがある（実測 18 回中 5 回）。
 *   - 最後に本文が届いた吹き出しの行バッチが、どれもそのメッセージの一部 → 同じメッセージ。頭の部分なら残りを流す
 *     （届いた順が入れ替わっていたら、足しても直らないので流さない）
 *   - そうでない（まだ 1 つも届いていない）→ 新しい吹き出し（ターンの最初の吹き出しならターンの messageId）で全部を流す
 * どちらも、そのメッセージの MessageDisplay が後から届いたら捨てる（settled）。
 */
function settleLastMessage(l: Live, text: string, turnMessageId: string): SessionEvent[] {
  if (!text) return [];
  // 同じメッセージの Stop が重ねて届いた（その後に本文が 1 つも来ていない）。流し直さない。
  if (l.lastMessageKey === undefined && l.settled?.text === text) return [];
  const keys = new Set<string>();
  const out: SessionEvent[] = [];
  const key = l.lastMessageKey;
  const received = key !== undefined ? l.chunks.get(key) : undefined;
  const mid = key !== undefined ? l.messageIds.get(key) : undefined;
  if (key !== undefined && received && mid && received.every((chunk) => !chunk.trim() || text.includes(chunk.trim()))) {
    keys.add(key);
    const streamed = received.join("");
    if (text.length > streamed.length && text.startsWith(streamed)) {
      out.push(event.assistantDelta(AGENT, l.sessionId, mid, text.slice(streamed.length)));
    }
  } else {
    out.push(event.assistantDelta(AGENT, l.sessionId, l.messageIds.size === 0 ? turnMessageId : crypto.randomUUID(), text));
  }
  l.settled = { text, keys, at: Date.now() };
  return out;
}

/**
 * Stop の後に遅れて届いた、終わったターンの最後のメッセージの MessageDisplay か（Stop の last_assistant_message で
 * 流し終えている）。次のターンが始まる前の LATE_DISPLAY_WINDOW_MS の間で、識別子を知っているもの、または
 * まだ見ていないメッセージで本文がそのメッセージの一部のもの。
 */
function isLateSettled(l: Live, key: string, delta: string): boolean {
  const s = l.settled;
  if (!s || l.generating || Date.now() - s.at >= LATE_DISPLAY_WINDOW_MS) return false;
  if (s.keys.has(key)) return true;
  const t = delta.trim();
  if (l.messageIds.has(key) || !t || !s.text.includes(t)) return false;
  s.keys.add(key);
  return true;
}

/* ── 受け箱（Claude Code の cross-session messaging。Windows は名前付きパイプのこともある） ── */

export function postToInbox(socketPath: string, text: string, timeoutMs = 3000): Promise<void> {
  return new Promise((resolve, reject) => {
    const sock = net.connect(socketPath);
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error("inbox connect timeout"));
    }, timeoutMs);
    sock.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    sock.once("connect", () => {
      sock.end(`${JSON.stringify({ type: "user", message: { role: "user", content: text } })}\n`, () => {
        clearTimeout(timer);
        resolve();
      });
    });
  });
}

/* ── iPhone から見たターミナルのセッション ─────────────────────────── */

export class ClaudeTerminalSession implements AgentSession {
  readonly supportsMidTurnInjection = false;
  readonly terminal = true;

  constructor(
    public readonly sessionId: string,
    private readonly registry: ClaudeTerminalRegistry,
    private readonly inbox: ClaudeChannelInbox
  ) {}

  isTerminalAlive(): boolean {
    return this.registry.isLive(this.sessionId);
  }

  /**
   * ターミナルへ届ける。ターンの進み具合は hook で流れるので、ここではターンの終わりまで待つだけ。
   * 人がペアリング済みの端末の入力欄で打った発話（server が印を付ける。isTypedByUser）で、デスクトップのアプリ内
   * ターミナルなら、受け箱ではなくターミナルに打ち込む（キーボードで打ったのと同じ発話になる）。
   * mainagent・定期の見回りの文と、.local の接続（この PC の api-key を持つプロセス）からの文は印が無いので、
   * 今までどおり channel・受け箱で届ける。
   */
  async send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    const notes = attachmentTextNotes(originalEvent);
    const userText = metadataText(originalEvent, text);
    const prompt = [...notes, userText].filter(Boolean).join("\n\n");
    if (isTypedByUser(originalEvent)) {
      // ターミナルに打ち込む文は skill の行を `/` で始めない（Claude Code が `/skill` をコマンドとして読み、
      // 「Unknown command: /skill」になる）。受け箱・channel へ送る文（prompt）は今までどおり。
      const typed = [...notes, metadataText(originalEvent, text, { typed: true })].filter(Boolean).join("\n\n");
      // エコー判定は contains なので、本文があれば元の本文で照合する（添付だけなら展開後）。
      switch (await this.registry.typePrompt(this.sessionId, typed, text || typed)) {
        case "typed":
          // 打ち込んだ後に待ち始める（ターミナル側のターンの終わりを待つ間に来た Stop で、打ち込んだ発話のターンを終わらせない）。
          await this.registry.waitTurn(this.sessionId);
          return;
        case "dialogOpen":
          this.fail(emit, "ターミナルに選択肢か一覧（許可の確認・質問・/model など）が出ているので、打ち込みませんでした。カードかターミナルで答えるか閉じてから、もう一度送ってください。");
          return;
        case "busy":
          this.fail(emit, "ターミナルの Claude Code が作業を続けているので、打ち込みませんでした。終わってから、もう一度送ってください。");
          return;
        case "unavailable":
          break;
      }
    }
    const done = this.registry.waitTurn(this.sessionId);
    if (this.inbox.isConnected(this.sessionId)) {
      this.registry.noteChannelPrompt(this.sessionId);
      this.inbox.post(this.sessionId, prompt);
      await done;
      return;
    }
    const socket = this.registry.inboxSocket(this.sessionId);
    if (socket) {
      // 保留の印は書いた直後に transcript に載るので、書く前の末尾から見張る。
      const offset = this.registry.transcriptEnd(this.sessionId);
      try {
        await postToInbox(socket, prompt);
        this.registry.noteInboxPrompt(this.sessionId, text || prompt, offset);
        await done;
        return;
      } catch {
        /* 閲覧のみとして返す */
      }
    }
    this.fail(emit, "このセッションはターミナルで開かれていて、いまは閲覧のみです。iPhone から送るには、ターミナルで `/buddy` を実行してください。");
  }

  /** 送れなかったことを伝え、送った側が立てた「考え中」を error + 応答の無い done で戻す。 */
  private fail(emit: Emit, message: string): void {
    emit(event.error(AGENT, this.sessionId, message));
    emit({ ...event.done(AGENT, this.sessionId, crypto.randomUUID()), metadata: { errored: "true" } });
  }

  /** デスクトップのアプリ内ターミナルで動いていれば Esc で止める。それ以外のターミナルには届かない。 */
  async interrupt(): Promise<void> {
    const problem = await this.registry.interrupt(this.sessionId);
    if (problem) throw new Error(problem);
  }

  async respondToAction(requestId: string, decision: string, answers: Record<string, string>): Promise<void> {
    const problem = await this.registry.answer(this.sessionId, requestId, decision, answers);
    if (problem) throw new Error(problem);
  }

  /** サブエージェントのカードの全行（subtype "workflow_snapshot"。行が無くても agents: []）。server が接続のたびと
   *  turn_status_request で送る。ターミナルの台帳から外れていれば undefined。 */
  subagentSnapshot(): string | undefined {
    return this.registry.subagentSnapshot(this.sessionId);
  }

  async close(): Promise<void> {}
}
