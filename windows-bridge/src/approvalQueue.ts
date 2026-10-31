import crypto from "node:crypto";
import { b64u, constantTimeEquals, normalizeCode, type Payload2Error } from "./tunnelV3.js";

// アカウントで見つけた PC への承認（spec/PROTOCOL-v3.md §10.4・Appendix A）。
// mac-bridge/Sources/BridgeApp/ApprovalQueue.swift の Node 版。Node は 1 本のスレッドで動くので、mac の lock の中の処理は
// 1 つの関数の中（同期）で行えば同じ順番になる。
// 「端末を追加」の窓（10 分。開き直すと延びる）、承認待ち（同時 3 件・1 台 1 件・5 分）、回数（approve_nonce で数える。
// 1 台 1 時間 3 回・全体 1 時間 20 回）、拒否した端末（24 時間）、番号の照合と間違いの数（窓 1 回で 3 回）。
// どれもメモリだけ。確認コードは承認待ちの中にだけ持ち、一覧（DevicesView・/device/approvals）には出さない。
//
// スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）: 窓が閉じていても、スマホでの許可が使えるなら
// 受け付ける（remote の申し込み）。remote は全体で 1 時間 6 件まで。窓を閉じても取り下げない（5 分・入力・拒否・切断・reset で終わる）。

export const APPROVAL_WINDOW_MS = 10 * 60 * 1000;
export const PENDING_LIFETIME_MS = 5 * 60 * 1000;
export const MAX_PENDING = 3;
export const PER_DEVICE_PER_HOUR = 3;
export const GLOBAL_PER_HOUR = 20;
/** remote の申し込みだけの上限（全体で 1 時間。approve_nonce で数える）。 */
export const REMOTE_GLOBAL_PER_HOUR = 6;
export const REJECTED_MS = 24 * 60 * 60 * 1000;
export const MAX_MISMATCHES = 3;
const HOUR_MS = 60 * 60 * 1000;

/** 承認待ちが終わった理由（`pair_rejected.reason`）。 */
export type EndReason = "rejected" | "timeout" | "code_mismatch" | "closed" | "reset";

/** 番号が合ったときに、トンネル側が `paired` を送れたか。 */
export type ApproveOutcome = { kind: "ok"; display: string } | { kind: "device_gone" };

/** msg1 を受け付けるか。窓が開いていれば window、窓が閉じていてスマホでの許可で受け付けるなら remote。 */
export type Admission = { kind: "window" } | { kind: "remote" } | { kind: "refused"; error: Payload2Error };

export type SubmitResult =
  | { kind: "ok"; deviceKeyId: string; display: string }
  | { kind: "mismatch"; remaining: number }
  | { kind: "bad_code" }
  | { kind: "no_pending" }
  | { kind: "device_gone" };

/** 承認待ち 1 件の見える部分（番号は入れない）。 */
export interface PendingView {
  pendingId: string;
  deviceKeyId: string;
  display: string;
  name: string;
  platform: string;
  requestedAt: number;
  expiresAt: number;
  sameNameExists: boolean;
  /** 窓が閉じていて、スマホでの許可で受け付けた申し込み（窓を閉じても取り下げない）。 */
  remote: boolean;
}

export interface AddInput {
  deviceKeyId: string;
  display: string;
  name: string;
  platform: string;
  sameNameExists: boolean;
  remote: boolean;
  code: string;
  /** 番号が合ったときに呼ぶ（行を pendingAck で入れて `paired` を送る）。引数は入力した端末の deviceKeyId（PC なら undefined）。 */
  approve: (approvedBy: string | undefined) => Promise<ApproveOutcome>;
  /** 取り下げのときに呼ぶ（トンネルは `pair_rejected` を送って閉じる）。 */
  end: (reason: EndReason) => void;
}

interface Entry {
  view: PendingView;
  code: string;
  approve: AddInput["approve"];
  end: AddInput["end"];
}

export interface ApprovalQueueOptions {
  now?: () => number;
}

export class ApprovalQueue {
  private readonly now: () => number;
  private openUntil?: number;
  private mismatches = 0;
  private readonly pendings = new Map<string, Entry>();
  private readonly attempts = new Map<string, number[]>();
  private globalAttempts: number[] = [];
  private remoteAttempts: number[] = [];
  private readonly rejected = new Map<string, number>();
  /** 窓・承認待ちが変わったときに呼ぶ（DevicesView の version を進める）。 */
  onChange?: () => void;
  /** remote の承認待ちを作ったときに呼ぶ（許可できる端末へ pair_request の push を 1 回送る。spec/PROTOCOL-v3.md §10.4.1）。 */
  onRemoteAdded?: (pending: PendingView) => void;

  constructor(opts: ApprovalQueueOptions = {}) {
    this.now = opts.now ?? Date.now;
  }

  // ---- 窓 ----

  /** 「端末を追加」の窓を開く（開いていれば今から 10 分に延ばす）。戻り値は閉じる時刻（ms）。 */
  openWindow(): number {
    const t = this.now();
    if (!this.isOpen(t)) this.mismatches = 0;
    this.openUntil = t + APPROVAL_WINDOW_MS;
    this.onChange?.();
    return this.openUntil;
  }

  /**
   * 窓を閉じ、窓の申し込み（remote でないもの）を reason で全部取り下げる（/local/approvals/close・管理鍵のパイプが閉じた）。
   * remote の申し込みは残す。間違いの数は、残った承認待ちが無ければ 0 に戻す。
   */
  closeWindow(reason: EndReason = "closed"): void {
    const t = this.now();
    this.openUntil = undefined;
    const ended = [...this.pendings.values()].filter((e) => !e.view.remote);
    for (const e of ended) this.pendings.delete(e.view.pendingId);
    this.settle(t);
    for (const e of ended) e.end(reason);
    this.onChange?.();
  }

  /** remote の申し込みを全部 reason で取り下げる（スマホからの許可を切った・アカウントで見つけた PC からの承認を切った）。 */
  closeRemote(reason: EndReason = "closed"): void {
    const t = this.now();
    const ended = [...this.pendings.values()].filter((e) => e.view.remote);
    for (const e of ended) this.pendings.delete(e.view.pendingId);
    this.settle(t);
    if (ended.length === 0) return;
    for (const e of ended) e.end(reason);
    this.onChange?.();
  }

  /** 窓が閉じる時刻（開いていなければ undefined）。 */
  get windowOpenUntil(): number | undefined {
    return this.isOpen(this.now()) ? this.openUntil : undefined;
  }

  private isOpen(t: number): boolean {
    return this.openUntil !== undefined && t < this.openUntil;
  }

  /** 窓が閉じていて承認待ちが 0 件になったら、間違いの数を 0 に戻す（spec/PROTOCOL-v3.md §10.4.1）。窓が開いている間は窓ごとに数える。 */
  private settle(t: number): void {
    if (this.pendings.size === 0 && !this.isOpen(t)) this.mismatches = 0;
  }

  // ---- 申し込み（PROTOCOL-v3 §10.4） ----

  /**
   * msg1 を読んだときの確かめ（状態を変えない）。外した印・20 台・壊れた一覧はトンネルの側で DeviceStore を見る。
   * remoteAvailable = スマホでの許可が使える（設定が有効で、許可できる端末に push の宛先がある。spec/PROTOCOL-v3.md §10.4.1）。
   */
  admit(deviceKeyId: string, approvalsEnabled: boolean, remoteAvailable: boolean): Admission {
    const t = this.now();
    if (!approvalsEnabled) return { kind: "refused", error: "approval_unavailable" };
    const remote = !this.isOpen(t);
    if (remote && !remoteAvailable) return { kind: "refused", error: "approval_unavailable" };
    this.prune(t);
    if (this.isRejectedAt(deviceKeyId, t)) return { kind: "refused", error: "rate_limited" };
    if (
      (this.attempts.get(deviceKeyId)?.length ?? 0) >= PER_DEVICE_PER_HOUR ||
      this.globalAttempts.length >= GLOBAL_PER_HOUR ||
      (remote && this.remoteAttempts.length >= REMOTE_GLOBAL_PER_HOUR)
    ) {
      return { kind: "refused", error: "rate_limited" };
    }
    if (this.pendings.size >= MAX_PENDING || this.hasPendingFor(deviceKeyId)) return { kind: "refused", error: "busy" };
    return { kind: remote ? "remote" : "window" };
  }

  /** 端末を 24 時間以内に拒否したか。 */
  isRejected(deviceKeyId: string): boolean {
    return this.isRejectedAt(deviceKeyId, this.now());
  }

  private isRejectedAt(deviceKeyId: string, t: number): boolean {
    const at = this.rejected.get(deviceKeyId);
    return at !== undefined && t - at < REJECTED_MS;
  }

  /** いま申し込みを作ると remote になるか（窓が閉じているか）。approve_nonce のときに数える種類を選ぶ。 */
  wouldBeRemote(): boolean {
    return !this.isOpen(this.now());
  }

  /** approve_nonce を受けたときに数える（その deviceKeyId と全体の両方。remote なら remote の全体も）。上限を超えたら false。 */
  countAttempt(deviceKeyId: string, remote = false): boolean {
    const t = this.now();
    this.prune(t);
    if (
      (this.attempts.get(deviceKeyId)?.length ?? 0) >= PER_DEVICE_PER_HOUR ||
      this.globalAttempts.length >= GLOBAL_PER_HOUR ||
      (remote && this.remoteAttempts.length >= REMOTE_GLOBAL_PER_HOUR)
    ) {
      return false;
    }
    this.attempts.set(deviceKeyId, [...(this.attempts.get(deviceKeyId) ?? []), t]);
    this.globalAttempts.push(t);
    if (remote) this.remoteAttempts.push(t);
    return true;
  }

  private prune(t: number): void {
    this.globalAttempts = this.globalAttempts.filter((at) => t - at < HOUR_MS);
    this.remoteAttempts = this.remoteAttempts.filter((at) => t - at < HOUR_MS);
    for (const [id, list] of this.attempts) {
      const kept = list.filter((at) => t - at < HOUR_MS);
      if (kept.length) this.attempts.set(id, kept);
      else this.attempts.delete(id);
    }
    for (const [id, at] of this.rejected) if (t - at >= REJECTED_MS) this.rejected.delete(id);
  }

  private hasPendingFor(deviceKeyId: string): boolean {
    for (const e of this.pendings.values()) if (e.view.deviceKeyId === deviceKeyId) return true;
    return false;
  }

  /** 承認待ちを作る（数と同じ端末をもう一度確かめる。remote でなければ窓が開いていること）。だめなら undefined（busy）。 */
  add(input: AddInput): PendingView | undefined {
    const t = this.now();
    if (!input.remote && !this.isOpen(t)) return undefined;
    if (this.pendings.size >= MAX_PENDING || this.hasPendingFor(input.deviceKeyId)) return undefined;
    // 窓が閉じていて承認待ちが無いなら、間違いの数は 0 から数える（窓が時間切れで閉じた後など）。
    this.settle(t);
    const view: PendingView = {
      pendingId: `p_${b64u(crypto.randomBytes(9))}`,
      deviceKeyId: input.deviceKeyId,
      display: input.display,
      name: input.name,
      platform: input.platform,
      requestedAt: t,
      expiresAt: t + PENDING_LIFETIME_MS,
      sameNameExists: input.sameNameExists,
      remote: input.remote
    };
    this.pendings.set(view.pendingId, { view, code: input.code, approve: input.approve, end: input.end });
    this.onChange?.();
    if (view.remote) this.onRemoteAdded?.({ ...view });
    return { ...view };
  }

  /** 端末が先に切った・pair_cancel・トンネルの時間切れなど、トンネルの側で終わったとき。 */
  remove(pendingId: string): void {
    if (!this.pendings.delete(pendingId)) return;
    this.settle(this.now());
    this.onChange?.();
  }

  /** まだ待っているか。 */
  contains(pendingId: string): boolean {
    return this.pendings.has(pendingId);
  }

  /** 5 分たった承認待ちを timeout で取り下げる。 */
  expire(): void {
    const t = this.now();
    const ended = [...this.pendings.values()].filter((e) => t >= e.view.expiresAt);
    if (ended.length === 0) return;
    for (const e of ended) this.pendings.delete(e.view.pendingId);
    this.settle(t);
    for (const e of ended) e.end("timeout");
    this.onChange?.();
  }

  // ---- PC・スマホでの操作（PROTOCOL-v3 Appendix A・spec/PROTOCOL-v3.md §10.4.1） ----

  /**
   * 入力された番号を、待っている承認待ち（最大 3 件）と 1 件ずつ定数時間で比べ、一致したものだけを許可する。
   * approvedBy はスマホで入力したときのその端末の deviceKeyId（PC なら undefined）。間違いの数は PC とスマホで同じ数に入れる。
   */
  async submit(input: string, approvedBy?: string): Promise<SubmitResult> {
    const code = normalizeCode(input);
    if (code === null) return { kind: "bad_code" };
    const t = this.now();
    const live = [...this.pendings.values()].filter((e) => t < e.view.expiresAt);
    if (live.length === 0) return { kind: "no_pending" };
    let found: Entry | undefined;
    // 一致してもすぐには抜けず、全件と比べる（どれが一致したかを時間で漏らさない）。
    for (const e of live.sort((a, b) => a.view.requestedAt - b.view.requestedAt)) {
      if (constantTimeEquals(e.code, code) && !found) found = e;
    }
    if (found) {
      this.pendings.delete(found.view.pendingId);
      this.settle(t);
      this.onChange?.();
      const outcome = await found.approve(approvedBy);
      return outcome.kind === "ok" ? { kind: "ok", deviceKeyId: found.view.deviceKeyId, display: outcome.display } : { kind: "device_gone" };
    }
    this.mismatches += 1;
    const remaining = Math.max(0, MAX_MISMATCHES - this.mismatches);
    if (remaining > 0) {
      this.onChange?.();
      return { kind: "mismatch", remaining };
    }
    // 3 回外れたら、その時の承認待ちを全部取り下げる（窓が開いていれば閉じる）。
    const ended = [...this.pendings.values()];
    this.pendings.clear();
    this.openUntil = undefined;
    this.mismatches = 0;
    for (const e of ended) e.end("code_mismatch");
    this.onChange?.();
    return { kind: "mismatch", remaining: 0 };
  }

  /** PC・スマホで拒否する。その deviceKeyId を 24 時間断る。 */
  reject(pendingId: string): boolean {
    const e = this.pendings.get(pendingId);
    if (!e) return false;
    this.pendings.delete(pendingId);
    this.rejected.set(e.view.deviceKeyId, this.now());
    this.settle(this.now());
    e.end("rejected");
    this.onChange?.();
    return true;
  }

  /** 「すべての端末を切断」などで epoch が変わった（PROTOCOL-v3 §18.2）。 */
  resetAll(): void {
    const ended = [...this.pendings.values()];
    this.pendings.clear();
    this.settle(this.now());
    for (const e of ended) e.end("reset");
    if (ended.length) this.onChange?.();
  }

  /** DevicesView の pending・/device/approvals の一覧（番号は入れない。古い順）。 */
  views(): PendingView[] {
    const t = this.now();
    return [...this.pendings.values()]
      .filter((e) => t < e.view.expiresAt)
      .map((e) => ({ ...e.view }))
      .sort((a, b) => a.requestedAt - b.requestedAt);
  }
}
