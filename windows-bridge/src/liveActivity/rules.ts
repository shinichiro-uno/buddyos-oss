/// Live Activity の規則（docs/BACKGROUND_CONTROL_2026-10-21.md §8.3・§8.7。Mac の LiveActivityRules と同じ）。
/// 純粋な状態機械で、時計（UNIX 秒）と batch の id は外から渡す。shared/fixtures/live-activity/publisher-cases.json の
/// 同じケースで、Mac と同じ push と状態の列を出す。

export const LA_CFG = {
  /** running が 0 になってから batch を終えるまで。 */
  END_GRACE: 20,
  /** 1 つの LA への更新の間隔の下限。 */
  MIN_INTERVAL: 10,
  /** 数が変わらなくても stale-date を延ばす更新。 */
  KEEPALIVE: 600,
  /** 更新のたびに stale-date = 今 + 25 分。 */
  STALE_AFTER: 1500,
  /** done / stopped の終わりを残す時間。 */
  DISMISS_DONE: 300,
  DISMISS_FAILED: 900,
  /** 終えた batch を覚えておく時間。 */
  ENDED_MEMORY: 900
} as const;

/** token を覚えておく上限（§8.6）。 */
export const LA_TOKEN_LIMITS = { perDevice: 4, total: 8, ageSec: 12 * 3600 } as const;

export type LaPhase = "running" | "done" | "failed" | "stopped";

export interface LaFinished {
  done?: number;
  failed?: number;
  stopped?: number;
}

export interface LaRegister {
  device: string;
  activityId: string;
  batch: string;
  shownRunning: number;
  shownFailed: number;
  /** 本番では ActivityKit の token（小文字の 16 進）。fixture には無い。 */
  token?: string;
  /** production / sandbox。 */
  environment?: string;
}

export interface LaState {
  phase: LaPhase;
  running: number;
  failed: number;
}

export interface LaPush {
  t: number;
  device: string;
  activityId: string;
  event: "update" | "end";
  priority: 5 | 10;
  state: LaState;
  staleAfterSec?: number;
  dismissAfterSec?: number;
  keepalive?: boolean;
  token?: string;
  environment?: string;
}

/** background_work_state の batch・phase・数。 */
export interface LaSnapshot {
  batch: string | null;
  phase: "idle" | LaPhase;
  running: number;
  failed: number;
  since: number | null;
}

export interface LaTarget {
  device: string;
  activityId: string;
  batch: string;
  token?: string;
  environment?: string;
  /** LA に出ている数（アプリが始めたときの数か、最後に送った数）。 */
  shown: { running: number; failed: number } | null;
  lastPushAt: number | null;
  registeredAt: number;
  /** この秒まで送らない（送り直しの待ち）。 */
  holdUntil: number;
  /** 送り直した回数。 */
  attempt: number;
  /** 最後に出した push の種類（種類が変わったら attempt を戻す）。 */
  lastEvent?: "update" | "end";
}

interface Batch {
  id: string;
  since: number;
  running: number;
  done: number;
  failed: number;
  stopped: number;
  endAt: number | null;
}

interface Ended {
  id: string;
  since: number;
  phase: Exclude<LaPhase, "running">;
  failed: number;
  at: number;
}

export interface LiveActivityRulesOptions {
  /** 新しい batch の id（UUID の小文字）。 */
  newId: () => string;
  onPush: (push: LaPush) => void;
  /** batch・phase・数が変わったとき。 */
  onState?: (t: number, state: LaSnapshot) => void;
  /** false の token には送らず、持っておく（登録簿に宛先が無い間・ready が false の間）。 */
  canSend?: (target: LaTarget) => boolean;
}

export class LiveActivityRules {
  private batch?: Batch;
  private lastEnded?: Ended;
  private readonly targets = new Map<string, LaTarget>();
  private readonly pushes = new WeakMap<LaPush, { target: LaTarget; shown: LaTarget["shown"]; lastPushAt: number | null }>();

  constructor(private readonly opts: LiveActivityRulesOptions) {}

  private key(device: string, activityId: string): string {
    return `${device}|${activityId}`;
  }

  snapshot(): LaSnapshot {
    const b = this.batch;
    if (b) return { batch: b.id, phase: "running", running: b.running, failed: b.failed, since: b.since };
    const e = this.lastEnded;
    if (e) return { batch: e.id, phase: e.phase, running: 0, failed: e.failed, since: e.since };
    return { batch: null, phase: "idle", running: 0, failed: 0, since: null };
  }

  private publish(t: number): void {
    this.opts.onState?.(t, this.snapshot());
  }

  counts(t: number, running: number): void {
    const b = this.batch;
    if (!b) {
      if (running <= 0) return this.tick(t);
      this.batch = { id: this.opts.newId(), since: t, running, done: 0, failed: 0, stopped: 0, endAt: null };
      this.lastEnded = undefined;
      this.publish(t);
      return this.tick(t);
    }
    if (b.running !== running) {
      b.running = running;
      if (running > 0) b.endAt = null;
      else if (b.endAt === null) b.endAt = t + LA_CFG.END_GRACE;
      this.publish(t);
    }
    this.tick(t);
  }

  finished(t: number, d: LaFinished): void {
    const b = this.batch;
    if (!b) return this.tick(t);
    b.done += d.done ?? 0;
    const failed = d.failed ?? 0;
    b.failed += failed;
    b.stopped += d.stopped ?? 0;
    if (failed > 0) this.publish(t);
    this.tick(t);
  }

  /** token を受ける。今の batch でも覚えている終えた batch でもなければ受けず false（その LA はアプリが自分で終える）。 */
  register(t: number, r: LaRegister): boolean {
    const known = (this.batch && r.batch === this.batch.id) || (this.lastEnded && r.batch === this.lastEnded.id);
    if (!known) {
      this.tick(t);
      return false;
    }
    const k = this.key(r.device, r.activityId);
    const prev = this.targets.get(k);
    // 新しいものが後ろ（古いものから捨てるため、置き換えも後ろへ回す）。
    this.targets.delete(k);
    this.targets.set(k, {
      device: r.device,
      activityId: r.activityId,
      batch: r.batch,
      token: r.token,
      environment: r.environment,
      shown: prev?.shown ?? { running: r.shownRunning, failed: r.shownFailed },
      lastPushAt: prev?.lastPushAt ?? null,
      registeredAt: t,
      holdUntil: 0,
      attempt: 0
    });
    this.trim();
    this.tick(t);
    return true;
  }

  clear(t: number, r: { device: string; activityId: string }): void {
    this.targets.delete(this.key(r.device, r.activityId));
    this.tick(t);
  }

  /** 登録簿が無効と答えた token を捨てる。 */
  drop(target: LaTarget): void {
    const k = this.key(target.device, target.activityId);
    if (this.targets.get(k) === target) this.targets.delete(k);
  }

  /** 登録簿へ宛先として渡す token（新しい順に 8 件まで）。 */
  tokens(): Array<{ token: string; environment: string }> {
    const out: Array<{ token: string; environment: string }> = [];
    for (const tg of [...this.targets.values()].reverse()) {
      if (tg.token && out.length < LA_TOKEN_LIMITS.total) out.push({ token: tg.token, environment: tg.environment ?? "production" });
    }
    return out;
  }

  /** push が送ろうとした token の持ち主。 */
  targetOf(push: LaPush): LaTarget | undefined {
    return this.pushes.get(push)?.target;
  }

  /**
   * 送れなかった push を、hold 秒後（hold が undefined を返したら諦める）に最新の値で送り直す。
   * 更新は「出ている数」を送る前に戻す。終わりは token を戻す（終えた batch を覚えている間だけ）。
   */
  retry(t: number, push: LaPush, hold: (attempt: number) => number | undefined): boolean {
    const rec = this.pushes.get(push);
    if (!rec) return false;
    const tg = rec.target;
    const k = this.key(tg.device, tg.activityId);
    const seconds = hold(tg.attempt);
    if (seconds === undefined) {
      if (push.event === "update") this.drop(tg);
      return false;
    }
    tg.attempt += 1;
    tg.holdUntil = t + seconds;
    if (push.event === "update") {
      if (this.targets.get(k) !== tg) return false;
      tg.shown = rec.shown;
      tg.lastPushAt = rec.lastPushAt;
    } else {
      if (this.lastEnded?.id !== tg.batch || this.targets.has(k)) return false;
      this.targets.set(k, tg);
    }
    return true;
  }

  /** 送れた。送り直しの数を戻す。 */
  delivered(push: LaPush): void {
    const rec = this.pushes.get(push);
    if (rec) rec.target.attempt = 0;
  }

  private trim(): void {
    const perDevice = new Map<string, number>();
    for (const tg of this.targets.values()) perDevice.set(tg.device, (perDevice.get(tg.device) ?? 0) + 1);
    for (const [k, tg] of [...this.targets]) {
      if ((perDevice.get(tg.device) ?? 0) > LA_TOKEN_LIMITS.perDevice) {
        this.targets.delete(k);
        perDevice.set(tg.device, (perDevice.get(tg.device) ?? 0) - 1);
      }
    }
    while (this.targets.size > LA_TOKEN_LIMITS.total) {
      const oldest = this.targets.keys().next().value;
      if (oldest === undefined) break;
      this.targets.delete(oldest);
    }
  }

  private canSend(tg: LaTarget, t: number): boolean {
    return t >= tg.holdUntil && (this.opts.canSend?.(tg) ?? true);
  }

  private emit(t: number, tg: LaTarget, event: "update" | "end", state: LaState, extra: { staleAfterSec?: number; dismissAfterSec?: number; keepalive?: boolean }): void {
    const push: LaPush = { t, device: tg.device, activityId: tg.activityId, event, priority: event === "end" ? 10 : 5, state, ...extra };
    if (tg.token !== undefined) {
      push.token = tg.token;
      push.environment = tg.environment;
    }
    this.pushes.set(push, { target: tg, shown: tg.shown, lastPushAt: tg.lastPushAt });
    // 更新の失敗で数えた回数を、終わりの送り直しに持ち越さない。
    if (tg.lastEvent !== event) tg.attempt = 0;
    tg.lastEvent = event;
    tg.shown = { running: state.running, failed: state.failed };
    tg.lastPushAt = t;
    this.opts.onPush(push);
  }

  tick(t: number): void {
    const b = this.batch;
    // 終える
    if (b && b.running === 0 && b.endAt !== null && t >= b.endAt) {
      const phase = b.failed > 0 ? "failed" : b.stopped > 0 && b.done === 0 ? "stopped" : "done";
      this.lastEnded = { id: b.id, since: b.since, phase, failed: b.failed, at: t };
      this.batch = undefined;
      this.publish(t);
    }
    // 12 時間たった token は捨てる
    for (const [k, tg] of this.targets) {
      if (t - tg.registeredAt >= LA_TOKEN_LIMITS.ageSec) this.targets.delete(k);
    }
    // 遅れて届いた token・送れなかった終わり
    const e = this.lastEnded;
    if (e) {
      for (const [k, tg] of this.targets) {
        if (tg.batch !== e.id || !this.canSend(tg, t)) continue;
        const state: LaState = { phase: e.phase, running: 0, failed: e.failed };
        this.emit(t, tg, "end", state, { dismissAfterSec: e.phase === "failed" ? LA_CFG.DISMISS_FAILED : LA_CFG.DISMISS_DONE });
        this.targets.delete(k);
      }
      if (t - e.at >= LA_CFG.ENDED_MEMORY && !this.batch) {
        this.lastEnded = undefined;
        this.publish(t);
      }
    }
    // 更新
    const cur = this.batch;
    if (cur && cur.running > 0) {
      for (const tg of this.targets.values()) {
        if (tg.batch !== cur.id || !this.canSend(tg, t)) continue;
        const want: LaState = { phase: "running", running: cur.running, failed: cur.failed };
        const since = tg.lastPushAt;
        if (tg.shown === null || tg.shown.running !== want.running) {
          if (since === null || t - since >= LA_CFG.MIN_INTERVAL) this.emit(t, tg, "update", want, { staleAfterSec: LA_CFG.STALE_AFTER });
        } else {
          const base = since ?? tg.registeredAt;
          if (t - base >= LA_CFG.KEEPALIVE) this.emit(t, tg, "update", want, { staleAfterSec: LA_CFG.STALE_AFTER, keepalive: true });
        }
      }
    }
    // どちらの batch でもない token は捨てる
    for (const [k, tg] of this.targets) {
      const ok = (this.batch && tg.batch === this.batch.id) || (this.lastEnded && tg.batch === this.lastEnded.id);
      if (!ok) this.targets.delete(k);
    }
  }
}
