import crypto from "node:crypto";
import type { DevicePush, DeviceStore } from "./deviceStore.js";
import { derivePushKey, publicKey, sealPush } from "./e2e.js";
import { trafficMeter } from "./trafficMeter.js";

/** E2E push（spec/PROTOCOL-v3.md §14）に必要な鍵素材。server.ts が注入する。 */
export interface PushE2EContext {
  /** いまの bridgeId（作り直しで変わることがある）。 */
  bridgeId: () => string;
  /** いまの Bridge 静的 X25519 秘密鍵 raw 32B（読めない間は undefined）。 */
  privateKey: () => Buffer | undefined;
  /** 端末の一覧。push の宛先は各端末の行の push（spec/PROTOCOL-v3.md §14）。 */
  devices: DeviceStore;
}

/** 通知の仮の文言（NSE が復号して差し替える。PROTOCOL-v3 §15.6 と同じ）。 */
const PLACEHOLDER = {
  ja: { title: "BuddyOS", body: "新しい通知があります" },
  en: { title: "BuddyOS", body: "You have a new notification" }
} as const;

/** 宛先の token の SHA-256（小文字の 16 進。Convex の tokenHash）。 */
export function tokenHash(token: string): string {
  return crypto.createHash("sha256").update(token.toLowerCase()).digest("hex");
}

/** /v3/live-activity の要求（docs/BACKGROUND_CONTROL_2026-10-21.md §8.8）。数と 4 つの状態のほか、文字列は入れない。 */
export interface LiveActivityRequest {
  environment: "production" | "sandbox";
  token: string;
  event: "update" | "end";
  timestamp: number;
  state: { phase: "running" | "done" | "failed" | "stopped"; running: number; failed: number };
  staleAfterSec?: number;
  dismissAfterSec?: number;
}

/** 登録簿の応答。status 0 は通信の失敗・設定が無い。 */
export interface LiveActivityResponse {
  status: number;
  error?: string;
  sent?: boolean;
  invalid?: boolean;
  retryAfterSec?: number;
}

/** 平文の title / body の上限（Unicode のスカラー値。Mac の PushService と同じ）。 */
export const MAX_TITLE_SCALARS = 64;
export const MAX_BODY_SCALARS = 300;

/**
 * push の平文 {"title","body","payload"}。Convex の /v3/push は e2e.c を base64 で 4096 文字までしか受け付けない
 * （平文で約 3 KB）ので、封をする前に title / body を切る（承認要求の本文はコマンドが入って長くなりうる）。
 */
export function pushPlaintext(title: string, body: string, data: Record<string, string>): Buffer {
  const cut = (s: string, n: number): string => Array.from(s).slice(0, n).join("");
  return Buffer.from(JSON.stringify({ title: cut(title, MAX_TITLE_SCALARS), body: cut(body, MAX_BODY_SCALARS), payload: data }), "utf8");
}

/**
 * スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）の pair_request の文言。title は申し込んだ端末の表示名、
 * body はこの PC の名前を入れた案内（push の locale が en なら英語）。番号は入れない。
 */
export function pairRequestText(locale: DevicePush["locale"], requester: string, bridgeName: string): { title: string; body: string } {
  return locale === "en"
    ? { title: requester, body: `is trying to connect to this PC (${bridgeName}). To allow it, enter the 6-digit code shown on that device.` }
    : { title: requester, body: `この PC（${bridgeName}）につなごうとしています。許可するには、その端末に出ている 6 桁を入力してください。` };
}

/**
 * Windows bridge の push 送出。Windows は APNs 秘密鍵 (.p8) を持たないので、いつも relay 経由で送る。
 * `BUDDYOS_PUSH_RELAY_URL` + `BUDDYOS_PUSH_RELAY_TOKEN` が両方設定されていればその relay。
 * 未設定なら既定の relay（Convex の `/v3/push`）を端末トークン（bdt_）で使う（mac の relayUsesDeviceToken と同じ）。
 * 端末トークンはサインイン後に登録簿の処理が作るので、送信のたびに読む（無い間は送らない）。
 * 既定の relay は Bridge が登録した宛先にしか送らないので、`/v3/push-targets` で宛先を登録する（unknown_token のとき登録し直す）。
 *
 * 宛先は端末の一覧（devices.json）の各端末の push。すべての通知を端末ごとの鍵（k_push。clientDeviceId を使う）で
 * 封をして 1 件ずつ送り、relay には device token と暗号文と仮の文言しか見せない。**平文の本文は送らない**（PROTOCOL-v3 §14）。
 */
export class PushService {
  readonly enabled: boolean;
  private readonly relayUrl?: string;
  private readonly relayToken?: () => string | undefined;
  /** 既定の relay の宛先登録の URL（端末トークンで送るときだけ）。 */
  private readonly targetsUrl?: string;
  /** Live Activity の登録簿の口（/v3/live-activity-targets・/v3/live-activity。端末トークンで送るときだけ）。 */
  private readonly liveActivityTargetsUrl?: string;
  private readonly liveActivityUrl?: string;
  private targetsTimer?: NodeJS.Timeout;

  constructor(
    private readonly e2e?: PushE2EContext,
    defaultRelay?: { url: string; token: () => string | undefined; targetsUrl?: string; liveActivityTargetsUrl?: string; liveActivityUrl?: string },
    /** "none" なら何も送らない（BUDDYOS_PUSH_MODE。settings.ts の resolvePushMode）。 */
    mode: "none" | "convex" = "convex"
  ) {
    const envUrl = process.env.BUDDYOS_PUSH_RELAY_URL;
    const envToken = process.env.BUDDYOS_PUSH_RELAY_TOKEN;
    if (mode === "none") {
      // 送らない（relayUrl を持たないので enabled は false）
    } else if (envUrl && envToken) {
      this.relayUrl = envUrl;
      this.relayToken = () => envToken;
    } else if (defaultRelay) {
      this.relayUrl = defaultRelay.url;
      this.relayToken = defaultRelay.token;
      this.targetsUrl = defaultRelay.targetsUrl;
      this.liveActivityTargetsUrl = defaultRelay.liveActivityTargetsUrl;
      this.liveActivityUrl = defaultRelay.liveActivityUrl;
    }
    this.enabled = Boolean(this.relayUrl && this.relayToken);
    if (this.enabled) {
      console.log(`[push] relay mode url=${this.relayUrl}${envUrl && envToken ? "" : " (device token)"} targets=${this.targets().length}`);
    }
  }

  private targets(): ReturnType<DeviceStore["pushTargets"]> {
    return this.e2e?.devices.pushTargets() ?? [];
  }

  /** テスト通知（GET /push-test）。送った時点の宛先の数と、失効を除いた残りの数を返す。 */
  async sendTest(): Promise<{ registered: number; remaining: number; error?: string }> {
    const registered = this.targets().length;
    if (!this.enabled) return { registered, remaining: registered, error: "push relay is not configured" };
    if (!this.relayToken?.()) return { registered, remaining: registered, error: "push relay is not configured: no bridge device token (sign in on the desktop app)" };
    if (registered === 0) return { registered, remaining: 0, error: "no device token registered" };
    await this.broadcast("BuddyOS", "テスト通知です", { kind: "test" });
    return { registered, remaining: this.targets().length };
  }

  /** 宛先のある全端末に、端末ごとの鍵で封をして送る。失効したトークンはその端末の行から外す。 */
  async broadcast(title: string, body: string, data: Record<string, string>): Promise<void> {
    // 平文は表示内容 + タップ配線用 payload をまるごと包む（PROTOCOL-v3 §14）
    const plaintext = pushPlaintext(title, body, data);
    await this.sendSealed(this.targets(), () => plaintext);
  }

  /**
   * remote の承認待ちを作ったときに、許可できる端末（ios・android）で宛先のあるものにだけ 1 回送る（spec/PROTOCOL-v3.md §10.4.1）。
   * 平文は端末ごとの鍵で封をする（平文では送らない）。payload は {"kind":"pair_request","pendingId"}。
   */
  async sendPairRequest(pendingId: string, requester: string, bridgeName: string): Promise<void> {
    const targets = this.e2e?.devices.approverPushTargets() ?? [];
    await this.sendSealed(targets, (locale) => {
      const text = pairRequestText(locale, requester, bridgeName);
      return pushPlaintext(text.title, text.body, { kind: "pair_request", pendingId });
    });
  }

  private async sendSealed(
    targets: ReturnType<DeviceStore["pushTargets"]>,
    plaintextFor: (locale: DevicePush["locale"]) => Buffer
  ): Promise<void> {
    if (!this.enabled || !this.e2e) return;
    const privateKey = this.e2e.privateKey();
    if (!privateKey) return;
    const bridgeId = this.e2e.bridgeId();
    const kid = crypto.createHash("sha256").update(publicKey(privateKey)).digest("hex").slice(0, 16);
    for (const target of targets) {
      const plaintext = plaintextFor(target.push.locale);
      let encrypted: { n: string; c: string };
      try {
        const key = derivePushKey(privateKey, Buffer.from(target.row.pub, "base64url"), bridgeId, target.row.clientDeviceId);
        const sealed = sealPush(plaintext, key);
        encrypted = { n: sealed.nonce.toString("base64"), c: sealed.ciphertext.toString("base64") };
      } catch (err) {
        // 暗号化に失敗した宛先へ平文で送るとダウングレードになるため、送らずにログのみ
        console.warn(`[push] e2e seal failed device=${target.deviceKeyId.slice(0, 8)} error=${String(err)}`);
        continue;
      }
      const placeholder = PLACEHOLDER[target.push.locale];
      const e2e = { v: 1, bid: bridgeId, kid, ...encrypted };
      await this.post(target.push.env, target.push.token, {
        // 表示は仮の文言。NSE が復号して title/body を差し替える（PROTOCOL-v3 §14）
        notification: placeholder,
        mutableContent: true,
        placeholder: target.push.locale,
        e2e,
        data: { e2e }
      });
    }
  }

  /** 宛先が変わったら 2 秒まとめてから既定の relay に登録する（端末トークンで送るときだけ）。 */
  scheduleTargetsSync(): void {
    if (!this.targetsUrl) return;
    if (this.targetsTimer) clearTimeout(this.targetsTimer);
    this.targetsTimer = setTimeout(() => {
      this.targetsTimer = undefined;
      void this.syncTargetsNow();
    }, 2000);
    this.targetsTimer.unref?.();
  }

  /** `/v3/push-targets` にこの Bridge の宛先を丸ごと登録する（20 件まで。token は小文字の SHA-256 だけを渡す）。 */
  async syncTargetsNow(): Promise<void> {
    const deviceToken = this.relayToken?.();
    if (!this.targetsUrl || !deviceToken) return;
    const seen = new Set<string>();
    const targets: Array<{ tokenHash: string; env: string }> = [];
    for (const t of this.targets()) {
      const hash = tokenHash(t.push.token);
      if (seen.has(hash)) continue;
      seen.add(hash);
      targets.push({ tokenHash: hash, env: t.push.env === "production" ? "production" : "sandbox" });
      if (targets.length >= 20) break;
    }
    const body = JSON.stringify({ targets });
    try {
      trafficMeter.record("registry.out", Buffer.byteLength(body));
      const resp = await fetch(this.targetsUrl, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${deviceToken}` },
        body,
        redirect: "manual"
      });
      const text = await resp.text().catch(() => "");
      trafficMeter.record("registry.in", Buffer.byteLength(text));
      console.log(`[push] push-targets status=${resp.status} count=${targets.length}`);
    } catch (err) {
      console.warn(`[push] push-targets failed error=${String(err)}`);
    }
  }

  /** Live Activity を登録簿へ送れる設定か（公開版の pushMode none・端末トークン（bdt_）が無い・登録簿のサイトが無いときは false）。 */
  get liveActivityAvailable(): boolean {
    return Boolean(this.liveActivityTargetsUrl && this.liveActivityUrl && this.relayToken?.());
  }

  /** `/v3/live-activity-targets` にこの Bridge の LA の宛先を丸ごと登録する（8 件まで。`[]` は「確かめる」にも使う）。 */
  async liveActivityTargets(targets: Array<{ token: string; environment: string }>): Promise<LiveActivityResponse> {
    const seen = new Set<string>();
    const list: Array<{ tokenHash: string; env: string }> = [];
    for (const t of targets) {
      const hash = tokenHash(t.token);
      if (seen.has(hash)) continue;
      seen.add(hash);
      list.push({ tokenHash: hash, env: t.environment === "production" ? "production" : "sandbox" });
      if (list.length >= 8) break;
    }
    return this.postLiveActivity(this.liveActivityTargetsUrl, { targets: list });
  }

  /** `/v3/live-activity` に 1 件送る。 */
  async sendLiveActivity(req: LiveActivityRequest): Promise<LiveActivityResponse> {
    return this.postLiveActivity(this.liveActivityUrl, req);
  }

  private async postLiveActivity(url: string | undefined, payload: unknown): Promise<LiveActivityResponse> {
    const deviceToken = this.relayToken?.();
    if (!url || !deviceToken) return { status: 0 };
    try {
      const body = JSON.stringify(payload);
      trafficMeter.record("push.la.out", Buffer.byteLength(body));
      const resp = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${deviceToken}` },
        body,
        redirect: "manual",
        signal: AbortSignal.timeout(15_000)
      });
      const text = await resp.text().catch(() => "");
      trafficMeter.record("push.la.in", Buffer.byteLength(text));
      let json: { error?: unknown; sent?: unknown; invalid?: unknown } = {};
      try {
        json = JSON.parse(text) as typeof json;
      } catch {
        /* 空 */
      }
      const retryAfter = Number.parseInt(resp.headers.get("retry-after") ?? "", 10);
      return {
        status: resp.status,
        error: typeof json.error === "string" ? json.error : undefined,
        sent: typeof json.sent === "boolean" ? json.sent : undefined,
        invalid: json.invalid === true ? true : undefined,
        retryAfterSec: Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : undefined
      };
    } catch {
      return { status: 0 };
    }
  }

  private async post(env: string, token: string, payload: Record<string, unknown>, retried = false): Promise<void> {
    const relayToken = this.relayToken?.();
    // 未サインイン（端末トークンがまだ無い）の間は送れない。サインインすると送れるようになる。
    if (!relayToken) return;
    try {
      const body = JSON.stringify({
        environment: env,
        token,
        tokens: [token],
        interruptionLevel: "time-sensitive",
        ...payload
      });
      trafficMeter.record("push.relay.out", Buffer.byteLength(body));
      const resp = await fetch(this.relayUrl!, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${relayToken}`
        },
        body,
        redirect: "manual"
      });
      const text = await resp.text().catch(() => "");
      trafficMeter.record("push.relay.in", Buffer.byteLength(text));
      let json: { invalid?: unknown; error?: unknown } = {};
      try {
        json = JSON.parse(text) as { invalid?: unknown; error?: unknown };
      } catch {
        /* 空 */
      }
      // 古い relay は無効なトークンの配列、v3 の relay は invalid: true を返す。
      const invalid = json.invalid === true || (Array.isArray(json.invalid) && json.invalid.includes(token));
      if (invalid) {
        this.e2e?.devices.removePushToken(token);
        console.log("[push] relay reported an invalid token; removed it from the device");
        this.scheduleTargetsSync();
      } else if (resp.status === 403 && json.error === "unknown_token" && this.targetsUrl && !retried) {
        // Convex の宛先が古い。登録し直してから 1 回だけ送り直す（mac と同じ）。
        await this.syncTargetsNow();
        await this.post(env, token, payload, true);
        return;
      }
      console.log(`[push] relay env=${env} status=${resp.status}`);
    } catch (err) {
      console.warn(`[push] relay send failed env=${env} error=${String(err)}`);
    }
  }
}
