import crypto from "node:crypto";
import { event, type SessionEvent } from "../protocol.js";
import { tokenHash, type LiveActivityRequest, type LiveActivityResponse } from "../pushService.js";
import { LiveActivityRules, type LaFinished, type LaPush, type LaSnapshot } from "./rules.js";

/// Live Activity の送り手（docs/BACKGROUND_CONTROL_2026-10-21.md §8.3・§8.6・§8.7。Mac の LiveActivityPublisher と同じ）。
/// 出どころの数の合算・token の持ち方・ready・宛先の登録・登録簿の応答の扱い・background_work_state の配信。規則は rules.ts。

/** 登録簿への口（PushService）。 */
export interface LiveActivityTransport {
  /** 登録簿へ送れる設定か（pushMode が none でない・端末トークンがある・サイトがある）。 */
  readonly liveActivityAvailable: boolean;
  liveActivityTargets(targets: Array<{ token: string; environment: string }>): Promise<LiveActivityResponse>;
  sendLiveActivity(req: LiveActivityRequest): Promise<LiveActivityResponse>;
}

export type LiveActivitySource = "hub" | "panes" | "bg";

export interface LiveActivityPublisherOptions {
  transport: LiveActivityTransport;
  /** ミリ秒。 */
  now?: () => number;
  newId?: () => string;
  boot?: string;
  log?: (message: string) => void;
}

/** background_work_state を 1 秒までまとめる。 */
const WS_COALESCE_MS = 1000;
/** 登録簿が古い（404）ときに確かめ直す間隔。 */
const RECHECK_404_MS = 3600_000;
/** 429・5xx・通信の失敗で ready を確かめられなかったとき。 */
const RECHECK_FAIL_MS = 300_000;
/** 宛先の登録の送り直し（5 秒・30 秒・2 分）。 */
const SYNC_RETRY_MS = [5000, 30_000, 120_000];
/** 宛先が消えたときのまとめ。 */
const SYNC_COALESCE_MS = 2000;

const TOKEN_RE = /^[0-9a-f]{64,400}$/;
const ACTIVITY_RE = /^[A-Za-z0-9-]{1,64}$/;
const BATCH_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const head8 = (token: string): string => `${token.slice(0, 8)}…`;

function count(value: string | undefined): number {
  const n = Number.parseInt(value ?? "", 10);
  return Number.isFinite(n) && n >= 0 && n <= 999 ? n : 0;
}

export class LiveActivityPublisher {
  private readonly transport: LiveActivityTransport;
  private readonly rules: LiveActivityRules;
  private readonly nowFn: () => number;
  private readonly log: (message: string) => void;
  private readonly boot: string;
  private readonly sources: Record<LiveActivitySource, Record<string, number>> = { hub: {}, panes: {}, bg: {} };
  private readonly senders = new Set<(evt: SessionEvent) => void>();
  private readonly chains = new Map<string, Promise<void>>();
  private timer?: NodeJS.Timeout;

  private ready = false;
  private recheckAt?: number;
  private checking = false;

  private rev = 0;
  private shown?: { push: boolean; snap: LaSnapshot };
  private dirtyAt?: number;

  /** 登録簿に宛先として登録できた token の hash。 */
  private registered = new Set<string>();
  private syncDueAt?: number;
  private syncing?: Promise<void>;
  private syncFailures = 0;
  /** 429 のとき、この時刻（ミリ秒）まで全部の宛先へ送らない。 */
  private holdUntilMs = 0;

  constructor(options: LiveActivityPublisherOptions) {
    this.transport = options.transport;
    this.nowFn = options.now ?? Date.now;
    this.log = options.log ?? ((m) => console.log(`[LiveActivity] ${m}`));
    this.boot = options.boot ?? crypto.randomUUID();
    const newId = options.newId ?? ((): string => crypto.randomUUID().toLowerCase());
    this.rules = new LiveActivityRules({
      newId,
      onPush: (push) => this.enqueue(push),
      canSend: (target) => this.ready && this.nowFn() >= this.holdUntilMs && target.token !== undefined && this.registered.has(tokenHash(target.token))
    });
  }

  private get t(): number {
    return Math.floor(this.nowFn() / 1000);
  }

  // ---- 開始・終了 ----

  start(): void {
    if (this.timer) return;
    this.timer = setInterval(() => this.tick(), 1000);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  /** 1 秒ごと（テストは時計を進めて呼ぶ）。 */
  tick(): void {
    this.rules.tick(this.t);
    this.refreshState();
    const nowMs = this.nowFn();
    if (this.dirtyAt !== undefined && nowMs - this.dirtyAt >= WS_COALESCE_MS) this.flushState();
    if (this.recheckAt !== undefined && nowMs >= this.recheckAt) void this.checkReady();
    this.kickSync();
  }

  // ---- 入力 ----

  /** 出どころごとの最新の数（sessionId または pane:<pane> → 数）。 */
  noteSource(source: LiveActivitySource, counts: Record<string, number>): void {
    this.sources[source] = counts;
    const merged = new Map<string, number>();
    for (const part of Object.values(this.sources)) {
      for (const [key, n] of Object.entries(part)) if (n > 0) merged.set(key, Math.max(merged.get(key) ?? 0, n));
    }
    let running = 0;
    for (const n of merged.values()) running += n;
    this.rules.counts(this.t, running);
    this.refreshState();
  }

  /** 終わった数（8.2）。 */
  noteFinished(finished: LaFinished): void {
    if (!(finished.done || finished.failed || finished.stopped)) return;
    this.rules.finished(this.t, finished);
    this.refreshState();
  }

  /** register_activity_token（device の WS だけ。形が合わなければ捨ててログに出す）。 */
  register(deviceKeyId: string, content: string | undefined, metadata: Record<string, string> | undefined): void {
    const md = metadata ?? {};
    const activityId = md.activityId ?? "";
    if (!ACTIVITY_RE.test(activityId)) {
      this.log("register rejected reason=activityId");
      return;
    }
    if (md.clear === "1") {
      this.rules.clear(this.t, { device: deviceKeyId, activityId });
      this.syncSoon(SYNC_COALESCE_MS);
      this.refreshState();
      return;
    }
    const token = (content ?? "").toLowerCase();
    if (!TOKEN_RE.test(token)) {
      this.log(`register rejected reason=token token=${head8(token)}`);
      return;
    }
    const batch = md.batch ?? "";
    if (!BATCH_RE.test(batch)) {
      this.log(`register rejected reason=batch token=${head8(token)}`);
      return;
    }
    const accepted = this.rules.register(this.t, {
      device: deviceKeyId,
      activityId,
      batch,
      shownRunning: count(md.running),
      shownFailed: count(md.failed),
      token,
      environment: md.environment === "production" ? "production" : "sandbox"
    });
    if (!accepted) {
      this.log(`register ignored reason=batch token=${head8(token)}`);
      return;
    }
    // 新しい token はすぐ登録簿へ。登録が済むまで push は待たせる。
    if (!this.registered.has(tokenHash(token))) this.syncSoon(0);
    this.refreshState();
  }

  /** 登録簿への登録が初めて成功したとき。 */
  registryReady(): void {
    void this.checkReady();
  }

  /** 接続ごとに登録する（.device の WS だけ）。今の値を 1 回送り、その後は変わるたびに送る。戻り値で外す。 */
  registerSender(send: (evt: SessionEvent) => void): () => void {
    this.senders.add(send);
    try {
      send(this.stateEvent());
    } catch {
      /* 閉じた接続は無視する */
    }
    return () => this.senders.delete(send);
  }

  // ---- background_work_state ----

  private stateEvent(): SessionEvent {
    const snap = this.rules.snapshot();
    return event.backgroundWorkState(
      JSON.stringify({
        v: 1,
        boot: this.boot,
        rev: this.rev,
        push: this.ready,
        batch: snap.batch,
        phase: snap.phase,
        running: snap.running,
        failed: snap.failed,
        since: snap.since,
        now: this.t
      })
    );
  }

  /** push・batch・phase・数が変わっていれば rev を進める。batch の始まりと終わり（batch・phase の変化）はすぐ送り、ほかは 1 秒まとめる。 */
  private refreshState(): void {
    const snap = this.rules.snapshot();
    const prev = this.shown;
    if (prev && prev.push === this.ready && prev.snap.batch === snap.batch && prev.snap.phase === snap.phase && prev.snap.running === snap.running && prev.snap.failed === snap.failed) {
      return;
    }
    this.shown = { push: this.ready, snap };
    this.rev += 1;
    if (prev && prev.snap.batch !== snap.batch && snap.phase === "running") this.log(`batch start id=${snap.batch} running=${snap.running} phase=${snap.phase}`);
    else if (prev && prev.snap.phase === "running" && snap.phase !== "running") this.log(`batch end id=${snap.batch} running=${snap.running} phase=${snap.phase}`);
    if (!prev || prev.snap.batch !== snap.batch || prev.snap.phase !== snap.phase) this.flushState();
    else this.dirtyAt ??= this.nowFn();
  }

  private flushState(): void {
    this.dirtyAt = undefined;
    if (this.senders.size === 0) return;
    const evt = this.stateEvent();
    for (const send of [...this.senders]) {
      try {
        send(evt);
      } catch {
        /* 閉じた接続は無視する */
      }
    }
  }

  // ---- ready ----

  private setReady(value: boolean): void {
    if (this.ready === value) return;
    this.ready = value;
    this.refreshState();
  }

  /** `{"targets":[]}` を送って確かめる（前の Bridge の宛先を消すことにもなる）。 */
  private async checkReady(): Promise<void> {
    if (this.checking) return;
    this.recheckAt = undefined;
    if (!this.transport.liveActivityAvailable) {
      this.setReady(false);
      return;
    }
    this.checking = true;
    let res: LiveActivityResponse;
    try {
      res = await this.transport.liveActivityTargets([]);
    } catch {
      res = { status: 0 };
    }
    this.checking = false;
    if (res.status === 200) {
      this.registered = new Set();
      this.setReady(true);
      if (this.rules.tokens().length > 0) this.syncSoon(0);
      this.log("registry ready");
      return;
    }
    this.setReady(false);
    this.recheckAt = this.nowFn() + (res.status === 404 ? RECHECK_404_MS : RECHECK_FAIL_MS);
    this.log(`registry check status=${res.status}`);
  }

  /** 登録簿の応答で ready が変わるもの。 */
  private noteStatus(res: LiveActivityResponse): void {
    if (res.status === 404) {
      this.setReady(false);
      this.recheckAt = this.nowFn() + RECHECK_404_MS;
    } else if (res.status === 401 || (res.status === 403 && res.error !== "unknown_token")) {
      this.setReady(false);
      this.recheckAt ??= this.nowFn() + RECHECK_FAIL_MS;
    }
  }

  // ---- 宛先の登録 ----

  private syncSoon(delayMs: number): void {
    const due = this.nowFn() + delayMs;
    if (this.syncDueAt === undefined || due < this.syncDueAt) this.syncDueAt = due;
    if (delayMs === 0) this.kickSync();
  }

  private kickSync(): void {
    if (this.syncDueAt === undefined || this.syncing || !this.ready || this.nowFn() < this.syncDueAt) return;
    void this.runSync();
  }

  private runSync(): Promise<void> {
    if (this.syncing) return this.syncing;
    this.syncDueAt = undefined;
    const list = this.rules.tokens();
    const signature = list.map((t) => t.token).join(",");
    const run = (async (): Promise<void> => {
      let res: LiveActivityResponse;
      try {
        res = await this.transport.liveActivityTargets(list);
      } catch {
        res = { status: 0 };
      }
      this.syncing = undefined;
      if (res.status === 200) {
        this.registered = new Set(list.map((t) => tokenHash(t.token)));
        this.syncFailures = 0;
        // 送っている間に変わっていれば、もう一度。
        if (this.rules.tokens().map((t) => t.token).join(",") !== signature) this.syncDueAt = this.nowFn();
        this.tick();
        return;
      }
      this.noteStatus(res);
      this.log(`targets status=${res.status}`);
      if (!this.ready) return;
      this.syncDueAt = this.nowFn() + SYNC_RETRY_MS[Math.min(this.syncFailures, SYNC_RETRY_MS.length - 1)];
      this.syncFailures += 1;
    })();
    this.syncing = run;
    return run;
  }

  // ---- 送る ----

  private enqueue(push: LaPush): void {
    const key = `${push.device}|${push.activityId}`;
    const next = (this.chains.get(key) ?? Promise.resolve()).then(() => this.deliver(push, false)).catch(() => {});
    this.chains.set(key, next);
    void next.then(() => {
      if (this.chains.get(key) === next) this.chains.delete(key);
    });
  }

  private async deliver(push: LaPush, retried: boolean): Promise<void> {
    if (!push.token) return;
    const req: LiveActivityRequest = {
      environment: push.environment === "production" ? "production" : "sandbox",
      token: push.token,
      event: push.event,
      timestamp: push.t,
      // 登録簿は running 1..999・failed 0..999 だけ受ける。
      state: { ...push.state, running: Math.min(push.state.running, 999), failed: Math.min(push.state.failed, 999) }
    };
    if (push.staleAfterSec !== undefined) req.staleAfterSec = push.staleAfterSec;
    if (push.dismissAfterSec !== undefined) req.dismissAfterSec = push.dismissAfterSec;
    let res: LiveActivityResponse;
    try {
      res = await this.transport.sendLiveActivity(req);
    } catch {
      res = { status: 0 };
    }
    this.log(`push event=${push.event} status=${res.status} sent=${res.sent ?? "-"} token=${head8(push.token)}`);
    const t = this.t;
    const isEnd = push.event === "end";
    // 終わりは 30 秒・2 分・10 分で 3 回まで（更新は最新の値でいつまでも）。
    const endDelays = (attempt: number): number | undefined => [30, 120, 600][attempt];
    const later = (seconds: number): ((attempt: number) => number | undefined) => (isEnd ? endDelays : () => seconds);
    if (res.status === 200) {
      if (res.invalid) {
        const target = this.rules.targetOf(push);
        if (target) this.rules.drop(target);
        this.syncSoon(SYNC_COALESCE_MS);
      } else if (res.sent === false) {
        this.rules.retry(t, push, later(60));
      } else {
        this.rules.delivered(push);
      }
    } else if (res.status === 403 && res.error === "unknown_token") {
      // 登録簿が token を知らない。登録済みの印を外し、登録し直せたときだけすぐ送り直す。取れなければ 120 秒後（token は捨てない）。
      this.registered.delete(tokenHash(push.token));
      if (!retried) {
        await this.runSync();
        if (this.registered.has(tokenHash(push.token))) {
          await this.deliver(push, true);
          return;
        }
      }
      this.rules.retry(t, push, () => 120);
      this.syncSoon(SYNC_COALESCE_MS);
    } else if (res.status === 401 || res.status === 403 || res.status === 404) {
      this.noteStatus(res);
      this.rules.retry(t, push, () => 0);
    } else if (res.status === 429) {
      // Retry-After（無ければ 60 秒）まで全体で送らない。回数の上限は無く、token も捨てない。
      const seconds = res.retryAfterSec ?? 60;
      this.holdUntilMs = Math.max(this.holdUntilMs, this.nowFn() + seconds * 1000);
      this.rules.retry(t, push, () => seconds);
    } else if (res.status === 400) {
      // 形が合わない要求は何度送っても通らない。送り直さず、数が変わるまで待つ。
      this.log(`push rejected status=400 token=${head8(push.token)}`);
      this.rules.delivered(push);
    } else {
      this.rules.retry(t, push, (attempt) => (isEnd ? [30, 120][attempt] : attempt === 0 ? 30 : 120));
    }
    this.refreshState();
  }
}
