import { execFile } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { BridgeIdentity } from "./identity.js";
import { OFFICIAL_DEFAULTS, type OfficialDefaults } from "./officialDefaults.js";
import {
  clearRegistered,
  readRegistered,
  readRegistryHold,
  readRegistryStatus,
  recordRegistryFailure,
  recordRegistryPrevious,
  recordRegistrySuccess,
  RegistryReason,
  setRegistered,
  writeFileAtomic,
  type RegisteredValues
} from "./registryFiles.js";
import type { SettingSource } from "./settings.js";
import { trafficMeter } from "./trafficMeter.js";

/// アカウントの登録簿（Convex）への自己登録・端末認証 v3（mac の BridgeServer.registerBridgeToRegistry の移植）。
/// spec/PROTOCOL-v3.md §15.7・§15.4・§15.5。
/// サインイン済みの iPhone・別の PC のデスクトップ（/v3/my-bridges）が、QR なしでこの PC を一覧に出せるようにする。
///   - 載せるのは秘密の無い値だけ（bridgeId・名前・relayURL・relayId・Bridge の公開鍵）。ローカル鍵は載せない。
///   - 認証は端末トークン bdt_ だけ。無ければ Clerk のトークン（デスクトップが ~/.buddyos/clerk-access-token に書く）で
///     /v3/device-token から発行する。Clerk のトークンで登録はしない。
///   - 1 分ごとに登録し直す（Clerk のトークンが書き直されたら 5 秒以内に。作り直し・resume の後はすぐ）。
///   - 403 revoked（アカウントから外された）は registry-hold を置き、デスクトップが /local/registry/resume するまで止まる。
///   - 結果は registry-status.json に書く（デスクトップの「iPhone から見つかるか」の根拠）。
/// 端末トークン・registry-status.json などは Bridge の設定フォルダに置く（mac の ~/.buddyos と取り合わない）。
/// Clerk のトークンと account.config.json はデスクトップと共有する ~/.buddyos から読む（mac と同じ）。


const HEARTBEAT_TICK_MS = 5_000;
export const RETRY_MS = 60_000;
const REQUEST_TIMEOUT_MS = 10_000;

const defaultBuddyosDir = (): string => path.join(os.homedir(), ".buddyos");

/**
 * 登録簿のサイトと出どころ。env（BUDDYOS_CONVEX_SITE）→ ~/.buddyos/account.config.json → 既定値（officialDefaults.ts）の順
 * （mac と同じ）。どれも無ければ ""（登録しない。QR だけでつなぐ）。
 */
export function convexSiteSetting(
  env: NodeJS.ProcessEnv = process.env,
  buddyosDir = defaultBuddyosDir(),
  defaults: OfficialDefaults = OFFICIAL_DEFAULTS
): { value: string; source: SettingSource } {
  const fromEnv = env.BUDDYOS_CONVEX_SITE?.trim();
  if (fromEnv) return { value: fromEnv.replace(/\/$/, ""), source: "env" };
  try {
    const parsed = JSON.parse(fs.readFileSync(path.join(buddyosDir, "account.config.json"), "utf8")) as { convexSiteUrl?: unknown };
    const v = typeof parsed.convexSiteUrl === "string" ? parsed.convexSiteUrl.trim() : "";
    if (v) return { value: v.replace(/\/$/, ""), source: "account-config" };
  } catch {
    /* 無い・壊れている = 既定値 */
  }
  const fallback = defaults.convexSite.trim().replace(/\/$/, "");
  return fallback ? { value: fallback, source: "default" } : { value: "", source: "none" };
}

/** 登録簿のサイト（無ければ ""）。 */
export function convexSite(env: NodeJS.ProcessEnv = process.env, buddyosDir = defaultBuddyosDir(), defaults: OfficialDefaults = OFFICIAL_DEFAULTS): string {
  return convexSiteSetting(env, buddyosDir, defaults).value;
}

/** 端末トークン（無ければ undefined）。push の中継の認証にも使う。 */
export function readDeviceToken(configDir: string): string | undefined {
  try {
    const token = fs.readFileSync(path.join(configDir, "device-token"), "utf8").trim();
    return token || undefined;
  } catch {
    return undefined;
  }
}

function clearDeviceToken(configDir: string): void {
  try {
    fs.rmSync(path.join(configDir, "device-token"), { force: true });
  } catch {
    /* 次回また試す */
  }
}

/** `reg query` の出力から MachineGuid を取り出す。 */
export function parseMachineGuid(stdout: string): string | undefined {
  return /MachineGuid\s+REG_SZ\s+([0-9A-Fa-f-]{8,})/.exec(stdout)?.[1];
}

/** mac の KeyStore.registryMachineId と同じ式。ハードウェアの ID そのものは送らない。 */
export function registryMachineIdFrom(machineGuid: string, username: string): string {
  return crypto.createHash("sha256").update(`cool.buddyos.registry.v1:${machineGuid}:${username}`).digest("hex");
}

let machineIdCache: Promise<string | undefined> | undefined;

/** Windows は HKLM\SOFTWARE\Microsoft\Cryptography の MachineGuid から作る（デスクトップの解除と同じ値）。 */
export function registryMachineId(): Promise<string | undefined> {
  if (process.platform !== "win32") return Promise.resolve(undefined);
  machineIdCache ??= new Promise((resolve) => {
    execFile(
      "reg",
      ["query", "HKLM\\SOFTWARE\\Microsoft\\Cryptography", "/v", "MachineGuid"],
      { timeout: 5000, windowsHide: true },
      (err, stdout) => {
        const guid = err ? undefined : parseMachineGuid(String(stdout));
        if (!guid) machineIdCache = undefined; // 失敗は次回やり直す
        resolve(guid ? registryMachineIdFrom(guid, os.userInfo().username) : undefined);
      }
    );
  });
  return machineIdCache;
}

/** 403 かつ body.error == "revoked"。401（期限切れ・未知のトークン）とは区別する。 */
export function isRevokedResponse(status: number, body: string): boolean {
  if (status !== 403) return false;
  try {
    return (JSON.parse(body) as { error?: unknown }).error === "revoked";
  } catch {
    return false;
  }
}

export interface BridgeRegistryOptions {
  identity: BridgeIdentity;
  /** 中継の URL（config.paseoRelayURL）。 */
  relayURL: string;
  /** PC の名前（PROTOCOL-v3 §5.3 で無害化済み。server.ts の bridgeName）。 */
  machineName: () => string;
  /** 登録できたとき（最初の 1 回だけ。push の宛先を登録し直す）。 */
  onFirstRegistered?: () => void;
  /** 以下はテスト用。 */
  /** 既定値（既定は officialDefaults.ts）。 */
  defaults?: OfficialDefaults;
  fetch?: typeof fetch;
  env?: NodeJS.ProcessEnv;
  /** clerk-access-token・account.config.json の置き場所（既定は ~/.buddyos）。 */
  buddyosDir?: string;
  machineId?: () => Promise<string | undefined>;
  log?: (message: string) => void;
}

type MintResult =
  | { kind: "minted"; token: string }
  /** (userSub, bridgeId) に失効の記録がある（403 {error:"revoked"}）。 */
  | { kind: "revoked" }
  /** 有効な bdt_ がすでにある（409 already_registered）。 */
  | { kind: "already_registered" }
  | { kind: "rate_limited" }
  | { kind: "failed"; reason: string };

type PostResult = { ok: true; status: number; json: Record<string, unknown> } | { ok: false; reason: string };

export class BridgeRegistry {
  private inFlight = false;
  private lastAttempt = 0;
  private tokenModifiedAt: number | undefined;
  private timer?: NodeJS.Timeout;
  private registeredOnce = false;
  private notConfiguredLogged = false;
  private readonly identity: BridgeIdentity;
  private readonly fetchImpl: typeof fetch;
  private readonly env: NodeJS.ProcessEnv;
  private readonly buddyosDir: string;
  private readonly machineId: () => Promise<string | undefined>;
  private readonly log: (message: string) => void;

  constructor(private readonly opts: BridgeRegistryOptions) {
    this.identity = opts.identity;
    this.fetchImpl = opts.fetch ?? fetch;
    this.env = opts.env ?? process.env;
    this.buddyosDir = opts.buddyosDir ?? defaultBuddyosDir();
    this.machineId = opts.machineId ?? registryMachineId;
    this.log = opts.log ?? ((m) => console.log(`[registry] ${m}`));
  }

  private get dir(): string {
    return this.identity.dir;
  }

  private logOnce(message: string): void {
    if (this.notConfiguredLogged) return;
    this.notConfiguredLogged = true;
    this.log(message);
  }

  start(): void {
    if (this.timer) return;
    void this.register();
    // 起動時のオフライン・認証の更新の後も 1 分以内に登録し直す（mac の heartbeatRegistry と同じ）。
    this.timer = setInterval(() => void this.heartbeat(), HEARTBEAT_TICK_MS);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  /** 作り直し・/local/registry/resume・ネットワークの切り替えの後、すぐ登録し直す。 */
  requestSoon(): void {
    this.lastAttempt = 0;
    void this.register();
  }

  private clerkTokenFile(): string {
    return path.join(this.buddyosDir, "clerk-access-token");
  }

  private currentTokenModifiedAt(): number | undefined {
    try {
      return fs.statSync(this.clerkTokenFile()).mtimeMs;
    } catch {
      return undefined;
    }
  }

  /**
   * Clerk のトークンは短命（~2h）。デスクトップが更新のたびに書き直す ~/.buddyos/clerk-access-token を
   * env（BUDDYOS_CLERK_TOKEN）より優先する。bdt_ は Clerk のトークンではないので使わない。
   */
  private clerkToken(): string | undefined {
    let fileToken: string | undefined;
    try {
      fileToken = fs.readFileSync(this.clerkTokenFile(), "utf8").trim() || undefined;
    } catch {
      /* 未サインイン */
    }
    const token = fileToken ?? (this.env.BUDDYOS_CLERK_TOKEN?.trim() || undefined);
    return token && !token.startsWith("bdt_") ? token : undefined;
  }

  /** 5 秒ごとに呼ぶ。前の試行から 1 分たったか、Clerk のトークンが書き直されたときだけ登録する。 */
  async heartbeat(): Promise<void> {
    if (Date.now() - this.lastAttempt < RETRY_MS && this.currentTokenModifiedAt() === this.tokenModifiedAt) return;
    await this.register();
  }

  async register(): Promise<void> {
    if (this.inFlight) return;
    this.inFlight = true;
    this.lastAttempt = Date.now();
    this.tokenModifiedAt = this.currentTokenModifiedAt();
    try {
      await this.registerOnce();
    } finally {
      this.inFlight = false;
    }
  }

  private async registerOnce(): Promise<void> {
    const dir = this.dir;
    // 登録簿・中継が設定されていなければ登録しない（QR だけでつなぐ）。通信もしない。
    const site = convexSite(this.env, this.buddyosDir, this.opts.defaults);
    if (!site || !this.opts.relayURL) {
      this.logOnce(!site ? "registry is off: no registry site (set BUDDYOS_CONVEX_SITE to enable sign-in discovery)" : "registry is off: no relay URL");
      return;
    }
    this.notConfiguredLogged = false;
    // アカウントから外された・この PC を外した: デスクトップで明示的にサインインし直すまで、発行も登録もしない（PROTOCOL-v3 §15.7）。
    // 「revoked」はデスクトップが「端末も切断するか」を聞く手がかりなので、「hold」で上書きしない。
    if (readRegistryHold(dir)) {
      if (readRegistryStatus(dir)?.lastError !== RegistryReason.revoked) recordRegistryFailure(dir, RegistryReason.hold);
      return;
    }
    const bridgePub = this.identity.keyState === "ok" ? this.identity.bridgePub() : undefined;
    if (!bridgePub) {
      recordRegistryFailure(dir, RegistryReason.keyIO);
      return;
    }
    const machineId = await this.machineId();
    let deviceToken = readDeviceToken(dir);
    if (!deviceToken) {
      const clerk = this.clerkToken();
      if (!clerk) {
        this.log("register skipped: no device token and no clerk token (desktop でサインインすると復帰)");
        recordRegistryFailure(dir, RegistryReason.signinRequired);
        return;
      }
      let outcome = await this.mint(site, clerk, machineId);
      if (outcome.kind === "already_registered") {
        // この bridgeId には有効な bdt_ がもうある（トークンを失くしたか、盗まれた）。古い bridgeId を控えて
        // bridgeId を作り直し、1 回だけ発行し直す（PROTOCOL-v3 §15.4。ペアリングは鍵で続くので切れない）。
        const previous = this.identity.bridgeId;
        if (this.identity.regenerateBridgeId()) {
          this.log("device-token: 409 already_registered — renewing bridgeId and minting once more");
          recordRegistryPrevious(dir, previous);
          clearRegistered(dir);
          this.identity.devices.bump();
          outcome = await this.mint(site, clerk, machineId);
        }
      }
      switch (outcome.kind) {
        case "minted":
          deviceToken = outcome.token;
          break;
        case "revoked":
          this.markAccountRevoked();
          return;
        case "rate_limited":
          recordRegistryFailure(dir, RegistryReason.rateLimited);
          return;
        case "already_registered":
          recordRegistryFailure(dir, "already_registered");
          return;
        case "failed":
          recordRegistryFailure(dir, outcome.reason);
          return;
      }
    }

    const current: RegisteredValues = {
      bridgePub: bridgePub.toString("base64url"),
      relayId: this.identity.relayId,
      relayURL: this.opts.relayURL
    };
    const body: Record<string, unknown> = {
      v: 3,
      bridgeId: this.identity.bridgeId,
      machineName: this.opts.machineName(),
      platform: "windows",
      relayURL: current.relayURL,
      relayId: current.relayId,
      bridgePub: current.bridgePub
    };
    if (machineId) body.machineId = machineId;
    // 前に登録できた値と違えば（作り直しの後）、前の値を付ける（409 key_changed は誤動作を防ぐだけ。PROTOCOL-v3 §3.3）。
    const prev = readRegistered(dir);
    if (prev && (prev.bridgePub !== current.bridgePub || prev.relayId !== current.relayId || prev.relayURL !== current.relayURL)) {
      body.keyRotation = { prevBridgePub: prev.bridgePub, prevRelayId: prev.relayId };
    }
    const res = await this.post(`${site}/v3/bridges/register`, { authorization: `Bearer ${deviceToken}` }, body);
    if (!res.ok) {
      recordRegistryFailure(dir, res.reason);
      return;
    }
    const errorCode = typeof res.json.error === "string" ? res.json.error : undefined;
    if (res.status >= 200 && res.status < 300) {
      this.log("registered Paseo bridge to registry (v3)");
      setRegistered(dir, current);
      // (userSub, bridgeId) は bdt_ の行のもの。サーバーが返す bridgeId に合わせる。
      const authoritative = res.json.bridgeId;
      if (typeof authoritative === "string" && authoritative && authoritative !== this.identity.bridgeId) {
        this.log(`register: adopting server bridgeId ${authoritative.slice(0, 24)}…`);
        this.identity.adoptBridgeId(authoritative);
      }
      // 期限が近いとサーバーが新しい資格情報を同梱してくる。保存に失敗したら旧トークンを使い続ける。
      const rotated = res.json.deviceToken;
      if (typeof rotated === "string" && rotated) {
        const saved = writeFileAtomic(path.join(dir, "device-token"), rotated);
        this.log(saved ? "device-token rotated" : "device-token rotation not saved — keeping the current token");
      }
      recordRegistrySuccess(dir);
      if (!this.registeredOnce) {
        this.registeredOnce = true;
        this.opts.onFirstRegistered?.();
      }
    } else if (res.status === 403 && errorCode === "revoked") {
      this.markAccountRevoked();
    } else if (res.status === 409 && errorCode === "key_changed") {
      // 登録簿の鍵と食い違う（古い Bridge の書き戻しなど）。新しい PC として登録し直す（PROTOCOL-v3 §15.5）。
      const previous = this.identity.bridgeId;
      if (this.identity.regenerateBridgeId()) {
        this.log("register: 409 key_changed — renewing bridgeId and registering as a new computer");
        recordRegistryPrevious(dir, previous);
        clearDeviceToken(dir);
        clearRegistered(dir);
        this.identity.devices.bump();
        this.lastAttempt = 0;
      } else {
        this.log("register: 409 key_changed — BUDDYOS_BRIDGE_ID is fixed, cannot register as a new computer");
      }
      recordRegistryFailure(dir, RegistryReason.keyChanged);
    } else if (res.status === 429) {
      recordRegistryFailure(dir, RegistryReason.rateLimited);
    } else if (res.status === 401) {
      // 期限切れ・行が消えた。次は Clerk から発行し直す。並走する別の Bridge がローテーション後の新しいトークンを
      // 書いた後なら、それは消さない（今回送ったトークンのときだけ消す）。
      if (readDeviceToken(dir) === deviceToken) {
        this.log("register: device token rejected (401) — clearing, will re-mint");
        clearDeviceToken(dir);
      } else {
        this.log("register: device token rejected (401) — file already replaced, keeping it");
      }
      recordRegistryFailure(dir, "device token rejected (401)");
    } else {
      this.log(`register rejected: HTTP ${res.status} ${errorCode ?? "-"}`);
      recordRegistryFailure(dir, `HTTP ${res.status}`);
    }
  }

  /** 登録・発行で 403 revoked（アカウントから外された）。端末の一覧と鍵は消さない（端末も切断するかはデスクトップで選ぶ。PROTOCOL-v3 §15.7）。 */
  private markAccountRevoked(): void {
    this.log("register: bridge revoked (403) — removed from account");
    this.identity.accountRevoked();
    recordRegistryFailure(this.dir, RegistryReason.revoked);
  }

  /** Clerk のトークンで端末トークンを発行する（`/v3/device-token`。PROTOCOL-v3 §15.4）。1 台に 1 回。 */
  private async mint(site: string, clerk: string, machineId: string | undefined): Promise<MintResult> {
    const body: Record<string, unknown> = { bridgeId: this.identity.bridgeId, machineName: this.opts.machineName(), platform: "windows" };
    if (machineId) body.machineId = machineId;
    const headers: Record<string, string> = { authorization: `Bearer ${clerk}` };
    const current = readDeviceToken(this.dir);
    if (current) headers["x-buddyos-device-token"] = current;
    const res = await this.post(`${site}/v3/device-token`, headers, body);
    if (!res.ok) return { kind: "failed", reason: res.reason };
    const errorCode = typeof res.json.error === "string" ? res.json.error : undefined;
    if (res.status === 403 && errorCode === "revoked") return { kind: "revoked" };
    if (res.status === 409 && errorCode === "already_registered") return { kind: "already_registered" };
    if (res.status === 429) return { kind: "rate_limited" };
    const token = typeof res.json.deviceToken === "string" && res.json.deviceToken ? res.json.deviceToken : undefined;
    if (res.status < 200 || res.status >= 300 || !token) {
      this.log(`device-token mint failed: HTTP ${res.status} (clerk token 失効なら desktop で再サインイン)`);
      return { kind: "failed", reason: `device-token HTTP ${res.status}` };
    }
    if (!writeFileAtomic(path.join(this.dir, "device-token"), token)) return { kind: "failed", reason: "device-token not saved" };
    this.log("device-token minted — heartbeat no longer depends on the Clerk session");
    return { kind: "minted", token };
  }

  /** 通信の失敗（site の URL が壊れている・つながらない）は投げずに理由を返す。 */
  private async post(url: string, headers: Record<string, string>, body: Record<string, unknown>): Promise<PostResult> {
    const payload = JSON.stringify(body);
    trafficMeter.record("registry.out", Buffer.byteLength(payload));
    try {
      const resp = await this.fetchImpl(url, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: payload,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
      });
      const text = await resp.text().catch(() => "");
      trafficMeter.record("registry.in", Buffer.byteLength(text));
      let json: Record<string, unknown> = {};
      try {
        const v: unknown = JSON.parse(text);
        if (v && typeof v === "object" && !Array.isArray(v)) json = v as Record<string, unknown>;
      } catch {
        /* 本文なし */
      }
      return { ok: true, status: resp.status, json };
    } catch (err) {
      // site の設定が壊れていても（new URL が投げる）ここで止めないよう、URL はそのまま出す。
      this.log(`${url} failed: ${String(err)}`);
      return { ok: false, reason: String(err) };
    }
  }
}
