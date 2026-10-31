import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { SessionEvent } from "../protocol.js";
import { agentsOrWorkflows, WorkflowCardMirror } from "../workflowCardMirror.js";
import type { OrchestratorHub } from "./orchestrator.js";
import { ensureHeartbeatFiles, formatLocalMinute } from "./workspace.js";

// メインの定期チェック（heartbeat。docs/MAIN_HEARTBEAT_2026-10-20.md）。
//
// Bridge の中のタイマー（60 秒ごと）が、mainagent のフォルダの専用の会話 1 つに決まった文を送り、伝えることがあるときだけ
// 全端末へ通知する。cron（cron/scheduler.ts）とは別に持つ（cron は毎回新しい会話・無人で、mainagent の道具が付かない）。
// - 会話は hub（server.ts の OrchestratorHub）で開く。iPhone のセッション一覧にも出て、開けば履歴が読める。
//   開くときは無人（unattended）に定期チェックの印（heartbeat）を付け、orchestrator.planFor がその会話にだけ道具を渡す。
// - 会話の ID は heartbeat-state.json に覚え、次は続き（resume）で開く。続きで開けなければ新しく作って覚え直す。
// - 設定は heartbeat.json（画面から変える）、状態は heartbeat-state.json（Bridge のもの）。

// ---- 設定と状態 ----

export interface QuietHours {
  enabled: boolean;
  /** "HH:mm"（手元の時刻）。start > end は日をまたぐ。 */
  start: string;
  end: string;
}

export interface HeartbeatSettings {
  enabled: boolean;
  intervalMinutes: number;
  quietHours: QuietHours;
  agentId: string;
  /** 頼む文の本文（空なら既定の文）。頭の「[定期チェック …]」と HEARTBEAT_OK の決まりは Bridge が足す。 */
  prompt: string;
}

export type HeartbeatResult = "ok" | "reported" | "skipped" | "error" | "running";

export interface HeartbeatState {
  sessionId?: string;
  agentId?: string;
  lastRunAt?: string;
  lastResult?: HeartbeatResult;
  lastMessage?: string;
  nextRunAt?: string;
}

export const DEFAULT_SETTINGS: Readonly<HeartbeatSettings> = Object.freeze({
  enabled: true,
  intervalMinutes: 180,
  quietHours: Object.freeze({ enabled: true, start: "22:00", end: "08:00" }),
  agentId: "claude",
  prompt: ""
});

export const MIN_INTERVAL_MINUTES = 30;
export const MAX_INTERVAL_MINUTES = 1440;
export const MAX_PROMPT_CHARS = 2000;
/** mainagent を扱えるエージェント（道具を渡せて、resume で同じ会話を続けられるもの）。 */
export const HEARTBEAT_AGENTS: readonly string[] = ["claude", "codex"];
/** 見回りの間隔。 */
export const TICK_MS = 60_000;
/** lastRunAt が無い（初めて）ときは、Bridge が起きてからこれだけ待って初回。 */
export const FIRST_RUN_DELAY_MS = 10 * 60_000;
/** 1 回の上限。超えたら止めて error。 */
export const RUN_TIMEOUT_MS = 10 * 60_000;
/** error だけで終わり done が来ないターンを打ち切るまでの猶予。 */
export const FORCE_CLOSE_AFTER_MS = 6_000;
/** バックグラウンドの行が全部終わってから、知らせのターンの done を待つ猶予。 */
export const BACKGROUND_SETTLE_MS = 120_000;
/** 返事がこれで始まり、全体がこの長さ以下なら「伝えることなし」。 */
export const OK_TOKEN = "HEARTBEAT_OK";
export const OK_MAX_CHARS = 40;
export const PUSH_TITLE = "メイン（定期チェック）";
export const PUSH_MAX_LINES = 3;
export const PUSH_MAX_CHARS = 200;
/** iPhone のセッション一覧での名前。 */
export const SESSION_TITLE = "定期チェック";

export const SETTINGS_FILE = "heartbeat.json";
export const STATE_FILE = "heartbeat-state.json";

/** 設定と状態を置くフォルダ。Windows は %USERPROFILE%\.buddyos（mac の ~/.buddyos と同じ形）、それ以外（開発用）は設定フォルダ。 */
export function defaultHeartbeatDir(bridgeConfigDir: string, platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env): string {
  if (platform === "win32") return path.win32.join(env.USERPROFILE || os.homedir(), ".buddyos");
  return bridgeConfigDir;
}

/** 30〜1440 分に丸める（数でなければ undefined）。 */
export function clampInterval(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return Math.min(MAX_INTERVAL_MINUTES, Math.max(MIN_INTERVAL_MINUTES, Math.round(value)));
}

/** "HH:mm" → 0 時からの分（形が違えば undefined）。 */
export function parseClock(value: unknown): number | undefined {
  if (typeof value !== "string") return undefined;
  const m = /^(\d{1,2}):(\d{2})$/.exec(value.trim());
  if (!m) return undefined;
  const h = Number(m[1]);
  const min = Number(m[2]);
  if (h > 23 || min > 59) return undefined;
  return h * 60 + min;
}

function clockString(minutes: number): string {
  return `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;
}

/** 今の設定に、届いた設定（一部だけでもよい）を重ねる。形の違う項目は今の値のまま。 */
export function mergeSettings(base: HeartbeatSettings, patch: unknown): HeartbeatSettings {
  const out: HeartbeatSettings = { ...base, quietHours: { ...base.quietHours } };
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) return out;
  const p = patch as Record<string, unknown>;
  if (typeof p.enabled === "boolean") out.enabled = p.enabled;
  const interval = clampInterval(p.intervalMinutes);
  if (interval !== undefined) out.intervalMinutes = interval;
  if (typeof p.agentId === "string" && HEARTBEAT_AGENTS.includes(p.agentId)) out.agentId = p.agentId;
  if (typeof p.prompt === "string") out.prompt = Array.from(p.prompt.trim()).slice(0, MAX_PROMPT_CHARS).join("");
  const q = p.quietHours;
  if (q && typeof q === "object" && !Array.isArray(q)) {
    const qq = q as Record<string, unknown>;
    if (typeof qq.enabled === "boolean") out.quietHours.enabled = qq.enabled;
    const start = parseClock(qq.start);
    if (start !== undefined) out.quietHours.start = clockString(start);
    const end = parseClock(qq.end);
    if (end !== undefined) out.quietHours.end = clockString(end);
  }
  return out;
}

/** ファイルの中身（無い・壊れていれば既定）。 */
export function normalizeSettings(raw: unknown): HeartbeatSettings {
  return mergeSettings({ ...DEFAULT_SETTINGS, quietHours: { ...DEFAULT_SETTINGS.quietHours } }, raw);
}

/** 静かな時間か（手元の時刻。start > end は日をまたぐ。start = end は静かな時間なし）。 */
export function inQuietHours(now: Date, quiet: QuietHours): boolean {
  if (!quiet.enabled) return false;
  const start = parseClock(quiet.start);
  const end = parseClock(quiet.end);
  if (start === undefined || end === undefined || start === end) return false;
  const t = now.getHours() * 60 + now.getMinutes();
  return start < end ? t >= start && t < end : t >= start || t < end;
}

/** 静かな時間が明ける時刻（now 以降で最初の end）。 */
function quietEndAfter(now: Date, quiet: QuietHours): Date {
  const end = parseClock(quiet.end) ?? 0;
  const d = new Date(now.getTime());
  d.setHours(Math.floor(end / 60), end % 60, 0, 0);
  if (d.getTime() <= now.getTime()) d.setDate(d.getDate() + 1);
  return d;
}

/** 間隔だけで見た次の時刻（lastRunAt + 間隔。初めてなら Bridge が起きてから 10 分）。 */
function intervalDue(settings: HeartbeatSettings, state: HeartbeatState, bootAt: Date): Date {
  const last = state.lastRunAt ? Date.parse(state.lastRunAt) : NaN;
  if (Number.isFinite(last)) return new Date(last + settings.intervalMinutes * 60_000);
  return new Date(bootAt.getTime() + FIRST_RUN_DELAY_MS);
}

/** いま回すか（動いているかは見ない。呼ぶ側が見る）。 */
export function isDue(settings: HeartbeatSettings, state: HeartbeatState, now: Date, bootAt: Date): boolean {
  if (!settings.enabled) return false;
  if (intervalDue(settings, state, bootAt).getTime() > now.getTime()) return false;
  return !inQuietHours(now, settings.quietHours);
}

/** 次に回る予定（画面の表示用）。止めていれば undefined。静かな時間に当たれば明ける時刻。 */
export function nextRunAt(settings: HeartbeatSettings, state: HeartbeatState, now: Date, bootAt: Date): Date | undefined {
  if (!settings.enabled) return undefined;
  let due = intervalDue(settings, state, bootAt);
  if (due.getTime() < now.getTime()) due = now;
  if (inQuietHours(due, settings.quietHours)) due = quietEndAfter(due, settings.quietHours);
  return due;
}

/** 「伝えることなし」か（前後の空白を除いて HEARTBEAT_OK で始まり 40 文字以下）。 */
export function isHeartbeatOk(text: string): boolean {
  const t = text.trim();
  return t.startsWith(OK_TOKEN) && Array.from(t).length <= OK_MAX_CHARS;
}

/** 通知の本文（返事の頭 3 行・200 文字まで。空の行は数えない）。 */
export function pushBody(text: string): string {
  const lines = text
    .trim()
    .split(/\r?\n/)
    .map((l) => l.trimEnd())
    .filter((l) => l.trim().length > 0)
    .slice(0, PUSH_MAX_LINES);
  const chars = Array.from(lines.join("\n"));
  if (chars.length <= PUSH_MAX_CHARS) return chars.join("");
  return `${chars.slice(0, PUSH_MAX_CHARS - 1).join("")}…`;
}

/** 頼む文の本文の既定（設定の prompt が空のとき）。 */
export const DEFAULT_PROMPT_BODY = `~/.buddyos/main/HEARTBEAT.md の項目に沿って、途中で止まっていることや忘れていそうなことが無いかを確かめてください。見るだけにして、作業は頼まないでください（気づいたことを知らせるのが役目です）。
覚えておくとよいことは save_note で残してください。前に残したことは ~/.buddyos/main/NOTES.md にあります。`;

/** 送る文。本文は設定で変えられる。頭（mainagent が定期チェックと見分ける印）と終わり（HEARTBEAT_OK の決まり）は固定。 */
export function heartbeatPrompt(now: Date, body = ""): string {
  return `[定期チェック ${formatLocalMinute(now)}]
${body.trim() || DEFAULT_PROMPT_BODY}
伝えることが無ければ、ほかに何も書かずに HEARTBEAT_OK とだけ返してください。伝えることがあれば、スマホの通知で読める短さ（3 行まで）で書いてください。`;
}

/** 状態ファイルの中身をそろえる。前の Bridge が回している最中に止まった（running のまま）なら error にする。 */
export function normalizeState(raw: unknown): HeartbeatState {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const r = raw as Record<string, unknown>;
  const str = (k: string): string | undefined => (typeof r[k] === "string" && r[k] ? (r[k] as string) : undefined);
  const results: readonly HeartbeatResult[] = ["ok", "reported", "skipped", "error", "running"];
  const state: HeartbeatState = {
    sessionId: str("sessionId"),
    agentId: str("agentId"),
    lastRunAt: str("lastRunAt"),
    lastResult: results.find((x) => x === r.lastResult),
    lastMessage: str("lastMessage"),
    nextRunAt: str("nextRunAt")
  };
  if (state.lastResult === "running") {
    state.lastResult = "error";
    state.lastMessage = "Bridge が止まったので、前の定期チェックは途中で終わった";
  }
  return state;
}

// ---- 回す ----

/** hub のうち定期チェックが使うところ。 */
export type HeartbeatHub = Pick<OrchestratorHub, "acquire" | "snapshot" | "adapter">;

export interface HeartbeatStatus {
  settings: HeartbeatSettings;
  state: HeartbeatState;
}

export interface HeartbeatServiceOptions {
  /** heartbeat.json / heartbeat-state.json を置くフォルダ。 */
  dir: string;
  /** mainagent のフォルダ（無ければ回さない）。 */
  mainRoot: () => string | undefined;
  hub: () => HeartbeatHub | undefined;
  /** 全端末への通知（PushService.broadcast）。 */
  push: (title: string, body: string, data: Record<string, string>) => void;
  bridgeId: () => string;
  /**
   * その会話を見ている接続の数（定期チェック自身の購読を含む）。承認カード（start_session / send_message の確認）は、
   * 定期チェックのほかに誰も見ていなければ承認の通知で呼び出す（hub は自分の購読も「見ている」と数えて通知しないため）。
   */
  watchers?: (agentId: string, sessionId: string) => number;
  /** 新しく作った会話に「定期チェック」の名前を付ける。 */
  rename?: (agentId: string, sessionId: string, title: string) => void;
  /** 回している間（スリープ止め）。 */
  onActiveChange?: (active: boolean) => void;
  runTimeoutMs?: number;
  /** バックグラウンドの行が全部終わってから、知らせのターンの done を待つ猶予（既定 120 秒）。 */
  backgroundSettleMs?: number;
  tickMs?: number;
  now?: () => Date;
  log?: (line: string) => void;
}

/** 1 回の結果。 */
interface RunOutcome {
  sessionId?: string;
  text: string;
  errorText?: string;
  timedOut: boolean;
}

export class HeartbeatService {
  private settingsValue: HeartbeatSettings;
  private stateValue: HeartbeatState;
  private readonly listeners = new Set<(evt: SessionEvent) => void>();
  private timer?: NodeJS.Timeout;
  private running = false;
  private bootAt: Date;
  private current?: Promise<void>;

  constructor(private readonly options: HeartbeatServiceOptions) {
    this.settingsValue = normalizeSettings(this.readJson(SETTINGS_FILE));
    this.stateValue = normalizeState(this.readJson(STATE_FILE));
    this.bootAt = this.now();
    this.refreshNextRun();
  }

  private now(): Date {
    return this.options.now?.() ?? new Date();
  }

  private log(line: string): void {
    (this.options.log ?? ((l: string) => process.stderr.write(`${l}\n`)))(`[heartbeat] ${line}`);
  }

  get settings(): HeartbeatSettings {
    return { ...this.settingsValue, quietHours: { ...this.settingsValue.quietHours } };
  }

  get state(): HeartbeatState {
    return { ...this.stateValue };
  }

  get isRunning(): boolean {
    return this.running;
  }

  status(): HeartbeatStatus {
    return { settings: this.settings, state: this.state };
  }

  statusEvent(): SessionEvent {
    return { type: "heartbeat_status", content: JSON.stringify(this.status()) };
  }

  /** 接続ごとに登録する（回し始め・終わり・設定の変更を全クライアントへ配る）。戻り値で外す。 */
  register(send: (evt: SessionEvent) => void): () => void {
    this.listeners.add(send);
    return () => this.listeners.delete(send);
  }

  private broadcast(): void {
    const evt = this.statusEvent();
    for (const l of [...this.listeners]) {
      try {
        l(evt);
      } catch {
        /* 閉じた接続は無視する */
      }
    }
  }

  start(): void {
    if (this.timer) return;
    this.bootAt = this.now();
    this.refreshNextRun();
    this.saveState();
    this.timer = setInterval(() => this.tick(), this.options.tickMs ?? TICK_MS);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  /** 設定を変える（一部だけでもよい）。保存して、全クライアントへ配る。 */
  setSettings(patch: unknown): HeartbeatStatus {
    this.settingsValue = mergeSettings(this.settingsValue, patch);
    this.writeJson(SETTINGS_FILE, this.settingsValue);
    this.refreshNextRun();
    this.saveState();
    this.broadcast();
    return this.status();
  }

  /** 60 秒ごとの見回り。回し始めたら、その回の終わりを待てる Promise を返す。 */
  tick(): Promise<void> | undefined {
    if (this.running) return undefined;
    if (!isDue(this.settingsValue, this.stateValue, this.now(), this.bootAt)) return undefined;
    return this.trigger();
  }

  /** 間隔と静かな時間を無視してすぐ回す（動いている最中なら何もしない）。回し始めたら true。 */
  runNow(): boolean {
    if (this.running) return false;
    return this.trigger() !== undefined;
  }

  /** テスト用: 回している回の終わりを待つ。 */
  async idle(): Promise<void> {
    while (this.current) await this.current;
  }

  private trigger(): Promise<void> | undefined {
    const hub = this.options.hub();
    const root = this.options.mainRoot();
    if (!hub || !root) return undefined;
    const agentId = this.settingsValue.agentId;
    // 前の回の会話がまだ動いている（終わっていない・承認待ち）なら回さない（lastRunAt は進めない）。
    const sid = this.stateValue.agentId === agentId ? this.stateValue.sessionId : undefined;
    if (sid) {
      const live = hub.snapshot().find((s) => s.agentId === agentId && s.sessionId === sid);
      if (live && (live.generating || live.awaiting || live.queued > 0)) {
        if (this.stateValue.lastResult !== "skipped") {
          this.stateValue.lastResult = "skipped";
          this.stateValue.lastMessage = "前の定期チェックの会話がまだ動いている";
          this.saveState();
          this.broadcast();
        }
        return undefined;
      }
    }
    this.running = true;
    this.options.onActiveChange?.(true);
    this.stateValue.lastRunAt = this.now().toISOString();
    this.stateValue.lastResult = "running";
    this.stateValue.lastMessage = undefined;
    this.stateValue.agentId = agentId;
    this.refreshNextRun();
    this.saveState();
    this.broadcast();
    const run = this.execute(hub, root, agentId, sid)
      .catch((error) => {
        this.finish("error", error instanceof Error ? error.message : String(error));
      })
      .finally(() => {
        this.running = false;
        this.current = undefined;
        this.options.onActiveChange?.(false);
      });
    this.current = run;
    return run;
  }

  private async execute(hub: HeartbeatHub, root: string, agentId: string, resumeId: string | undefined): Promise<void> {
    if (!hub.adapter(agentId)) {
      this.finish("error", `エージェントが無い: ${agentId}`);
      return;
    }
    ensureHeartbeatFiles(root);
    const prompt = heartbeatPrompt(this.now(), this.settingsValue.prompt);
    let outcome: RunOutcome | undefined;
    if (resumeId) {
      try {
        outcome = await this.runOnce(hub, root, agentId, resumeId, prompt);
      } catch (error) {
        this.log(`could not resume ${agentId}:${resumeId}: ${error instanceof Error ? error.message : String(error)}`);
        outcome = undefined;
      }
      // 続きで開けなかった（開けない・何も返さずに失敗した）なら、新しく作って覚え直す。
      if (outcome && !outcome.timedOut && outcome.errorText !== undefined && !outcome.text.trim()) {
        this.log(`resume of ${agentId}:${resumeId} failed (${outcome.errorText}); starting a new session`);
        outcome = undefined;
      }
    }
    let fresh = false;
    if (!outcome) {
      fresh = true;
      outcome = await this.runOnce(hub, root, agentId, undefined, prompt);
    }
    if (outcome.sessionId) {
      const changed = outcome.sessionId !== this.stateValue.sessionId;
      this.stateValue.sessionId = outcome.sessionId;
      this.stateValue.agentId = agentId;
      if (fresh && changed) this.options.rename?.(agentId, outcome.sessionId, SESSION_TITLE);
    }
    if (outcome.timedOut) {
      this.finish("error", "時間切れ（10 分）で止めた");
      return;
    }
    if (outcome.errorText !== undefined) {
      this.finish("error", outcome.errorText);
      return;
    }
    const text = outcome.text.trim();
    if (isHeartbeatOk(text)) {
      this.finish("ok", text);
      return;
    }
    if (!text) {
      this.finish("error", "返事が空だった");
      return;
    }
    this.finish("reported", text);
    if (outcome.sessionId) {
      this.options.push(PUSH_TITLE, pushBody(text), {
        kind: "chat",
        agentId,
        sessionId: outcome.sessionId,
        bridgeId: this.options.bridgeId()
      });
    }
  }

  /** 会話を開いて（resume）1 ターン送り、終わるのを待つ。開けなければ投げる。 */
  private async runOnce(hub: HeartbeatHub, root: string, agentId: string, sessionId: string | undefined, prompt: string): Promise<RunOutcome> {
    const clientMessageId = `heartbeat-${crypto.randomUUID()}`;
    let started = false;
    let sid: string | undefined = sessionId;
    let errorText: string | undefined;
    let timedOut = false;
    // 最後のアシスタントの文（吹き出し）。messageId が変わる・assistant_turn_end で区切る。
    let bubble = "";
    let bubbleId: string | undefined;
    let bubbleClosed = true;
    let prevBubble = "";
    let resolveDone!: () => void;
    const finished = new Promise<void>((r) => (resolveDone = r));
    const timers: NodeJS.Timeout[] = [];
    const closeLater = (ms: number): void => {
      const t = setTimeout(resolveDone, ms);
      t.unref?.();
      timers.push(t);
    };
    const cards = new WorkflowCardMirror();
    let doneSeen = false;
    let settleTimer: NodeJS.Timeout | undefined;
    // 結果待ちの間に作業の行が 0 になったら、猶予の間に知らせのターンの done が来なくても終わりにする。
    const armSettle = (): void => {
      if (settleTimer) clearTimeout(settleTimer);
      settleTimer = undefined;
      if (agentsOrWorkflows(cards.counts)) return;
      settleTimer = setTimeout(resolveDone, this.options.backgroundSettleMs ?? BACKGROUND_SETTLE_MS);
      settleTimer.unref?.();
      timers.push(settleTimer);
    };
    const onEvent = (evt: SessionEvent): void => {
      if (evt.type === "session_started" && evt.sessionId && !evt.sessionId.startsWith("pending")) sid = evt.sessionId;
      if (evt.type === "queue_dispatched" && (evt.metadata?.clientMessageId ?? evt.messageId) === clientMessageId) {
        started = true;
        return;
      }
      // 自分の送信が始まるまでの出来事（購読直後のスナップショット・前のターンの残り）は見ない。
      if (!started) return;
      switch (evt.type) {
        case "action_request": {
          const target = evt.sessionId ?? sid;
          if (!target || (this.options.watchers?.(agentId, target) ?? 1) > 1) return;
          this.options.push(PUSH_TITLE, evt.metadata?.title ?? evt.content ?? "承認が必要です", {
            kind: "approval_request",
            agentId,
            sessionId: target,
            requestId: evt.messageId ?? "",
            bridgeId: this.options.bridgeId()
          });
          return;
        }
        case "assistant_delta": {
          if (bubbleClosed || evt.messageId !== bubbleId) {
            if (bubble) prevBubble = bubble;
            bubble = "";
            bubbleClosed = false;
            bubbleId = evt.messageId;
          }
          bubble += evt.content ?? "";
          return;
        }
        case "assistant_turn_end":
          bubbleClosed = true;
          return;
        case "error":
          errorText = evt.content ?? "error";
          closeLater(FORCE_CLOSE_AFTER_MS);
          return;
        case "workflow_progress":
          cards.apply(evt.content);
          if (doneSeen) armSettle();
          return;
        case "done":
          // バックグラウンドの作業の終わりを知らせるターン（task-notification）は、送った発話の返事ではない。
          // 送った発話が CLI の待ち行列にある間に届くので、そのターンの本文を外して待ち続ける。
          // ただし起動だけのターンが終わった後の結果待ち（doneSeen）なら、その本文が返事。
          if (evt.metadata?.origin === "task-notification") {
            if (doneSeen) {
              if (!agentsOrWorkflows(cards.counts)) resolveDone();
              return;
            }
            if (evt.messageId !== undefined && evt.messageId === bubbleId) {
              bubble = prevBubble;
              prevBubble = "";
              bubbleClosed = true;
            }
            return;
          }
          // 子がバックグラウンドで作業を続けているなら、起動の返事で終わりにせず、知らせのターンの結論を待つ
          // （待つ上限は runTimeoutMs）。
          doneSeen = true;
          if (agentsOrWorkflows(cards.counts)) return;
          resolveDone();
          return;
        default:
          return;
      }
    };
    const sub = await hub.acquire(agentId, sessionId, root, onEvent, { unattended: true, heartbeat: true });
    try {
      const deadline = setTimeout(() => {
        timedOut = true;
        void Promise.resolve(sub.session.interrupt?.()).catch(() => {});
        closeLater(FORCE_CLOSE_AFTER_MS);
      }, this.options.runTimeoutMs ?? RUN_TIMEOUT_MS);
      deadline.unref?.();
      timers.push(deadline);
      const sent = sub.submit(clientMessageId, prompt);
      if (sent === "missing") {
        errorText = "会話を開けなかった";
        resolveDone();
      }
      await finished;
    } finally {
      for (const t of timers) clearTimeout(t);
      const current = sub.session.sessionId;
      if (current && !current.startsWith("pending")) sid = current;
      sub.release();
    }
    return { sessionId: sid, text: bubble, errorText, timedOut };
  }

  private finish(result: HeartbeatResult, message: string): void {
    this.stateValue.lastResult = result;
    this.stateValue.lastMessage = message.length > 2000 ? `${message.slice(0, 1999)}…` : message;
    this.refreshNextRun();
    this.saveState();
    this.broadcast();
  }

  private refreshNextRun(): void {
    this.stateValue.nextRunAt = nextRunAt(this.settingsValue, this.stateValue, this.now(), this.bootAt)?.toISOString();
  }

  // ---- ファイル ----

  private readJson(name: string): unknown {
    try {
      return JSON.parse(fs.readFileSync(path.join(this.options.dir, name), "utf8")) as unknown;
    } catch {
      return undefined;
    }
  }

  private writeJson(name: string, value: unknown): void {
    const file = path.join(this.options.dir, name);
    try {
      fs.mkdirSync(this.options.dir, { recursive: true });
      const tmp = `${file}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, `${JSON.stringify(value, null, 2)}\n`, "utf8");
      fs.renameSync(tmp, file);
    } catch (error) {
      this.log(`could not write ${name}: ${error instanceof Error ? error.message : String(error)}`);
    }
  }

  private saveState(): void {
    this.writeJson(STATE_FILE, this.stateValue);
  }
}
