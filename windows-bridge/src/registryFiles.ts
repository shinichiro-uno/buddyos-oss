import fs from "node:fs";
import path from "node:path";

// 登録簿（Convex）まわりの小さなファイル（mac の RegistryStatus と KeyStore の registry-hold・registered.json と同じ形）。
// どれも Bridge の設定フォルダ（Windows は %LOCALAPPDATA%\BuddyOS\Bridge）に置く。秘密は入れない（結果と公開の値だけ）。
//   registry-status.json  最後の登録の結果（デスクトップの「iPhone から見つかるか」の根拠）。時刻は秒、registryPrevious.since はミリ秒
//   registry-hold         ある間は端末トークンを発行し直さず、登録もしない {"since":<ms>,"reason"}（PROTOCOL-v3 §15.7）
//   registered.json       最後に登録できた値 {"bridgePub","relayId","relayURL"}（違えば keyRotation を付ける。PROTOCOL-v3 §15.5）
// identity.ts（作り直し・key_io）と registry.ts（登録）の両方から使うので、どちらにも依存しない。

/** 失敗の理由（mac の RegistryStatus.Reason と同じ）。 */
export const RegistryReason = {
  revoked: "revoked",
  keyChanged: "key_changed",
  hold: "hold",
  rateLimited: "rate_limited",
  keyIO: "key_io",
  signinRequired: "signin-required"
} as const;

export interface RegistryPrevious {
  bridgeId: string;
  /** UNIX ミリ秒。 */
  since: number;
}

/** registry-status.json の中身（mac の RegistryStatus.Snapshot と同じ形。時刻は秒）。 */
export interface RegistrySnapshot {
  lastSuccessAt?: number;
  lastAttemptAt: number;
  auth?: "device" | "clerk";
  hasDeviceToken: boolean;
  lastError?: string;
  registryPrevious?: RegistryPrevious;
}

const statusFile = (dir: string): string => path.join(dir, "registry-status.json");
const nowSec = (): number => Date.now() / 1000;

/** 一時ファイルに 0600 で書いてから置き換える（書きかけをデスクトップに読ませない）。書けなくても止めない。 */
export function writeFileAtomic(file: string, content: string): boolean {
  const tmp = `${file}.${process.pid}.tmp`;
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(tmp, content, { mode: 0o600 });
    fs.renameSync(tmp, file);
    return true;
  } catch (err) {
    try {
      fs.unlinkSync(tmp);
    } catch {
      /* tmp が無ければ何もしない */
    }
    console.warn(`[registry] write failed ${path.basename(file)}: ${String(err)}`);
    return false;
  }
}

function removeFile(file: string): void {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    /* 消せなくても続ける */
  }
}

function readJson(file: string): Record<string, unknown> | undefined {
  try {
    const v: unknown = JSON.parse(fs.readFileSync(file, "utf8"));
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

function hasDeviceToken(dir: string): boolean {
  try {
    return fs.readFileSync(path.join(dir, "device-token"), "utf8").trim().length > 0;
  } catch {
    return false;
  }
}

// ---- registry-status.json ----

export function readRegistryStatus(dir: string): RegistrySnapshot | undefined {
  const j = readJson(statusFile(dir));
  if (!j) return undefined;
  const prev = j.registryPrevious as { bridgeId?: unknown; since?: unknown } | undefined;
  return {
    lastSuccessAt: typeof j.lastSuccessAt === "number" ? j.lastSuccessAt : undefined,
    lastAttemptAt: typeof j.lastAttemptAt === "number" ? j.lastAttemptAt : 0,
    auth: j.auth === "device" || j.auth === "clerk" ? j.auth : undefined,
    hasDeviceToken: j.hasDeviceToken === true,
    lastError: typeof j.lastError === "string" ? j.lastError : undefined,
    registryPrevious:
      prev && typeof prev.bridgeId === "string" ? { bridgeId: prev.bridgeId, since: typeof prev.since === "number" ? prev.since : 0 } : undefined
  };
}

function writeStatus(dir: string, snap: RegistrySnapshot): void {
  const json: Record<string, unknown> = { lastAttemptAt: snap.lastAttemptAt, hasDeviceToken: snap.hasDeviceToken };
  if (snap.lastSuccessAt !== undefined) json.lastSuccessAt = snap.lastSuccessAt;
  if (snap.auth) json.auth = snap.auth;
  if (snap.lastError) json.lastError = snap.lastError;
  if (snap.registryPrevious) json.registryPrevious = { bridgeId: snap.registryPrevious.bridgeId, since: snap.registryPrevious.since };
  writeFileAtomic(statusFile(dir), JSON.stringify(json, null, 2));
}

/** 登録できた（v3 はいつも端末トークン）。 */
export function recordRegistrySuccess(dir: string, now = nowSec()): void {
  writeStatus(dir, {
    lastSuccessAt: now,
    lastAttemptAt: now,
    auth: "device",
    hasDeviceToken: hasDeviceToken(dir),
    registryPrevious: readRegistryStatus(dir)?.registryPrevious
  });
}

/** 失敗。前回の成功時刻は残す（「4 分前」と「6 日前」では出す言葉が違う）。 */
export function recordRegistryFailure(dir: string, reason: string, now = nowSec()): void {
  const prev = readRegistryStatus(dir);
  writeStatus(dir, {
    lastSuccessAt: prev?.lastSuccessAt,
    lastAttemptAt: now,
    auth: prev?.auth,
    hasDeviceToken: hasDeviceToken(dir),
    lastError: reason,
    registryPrevious: prev?.registryPrevious
  });
}

/** その理由の失敗のときだけ lastError を消す（e2e-key が読めるようになったとき）。 */
export function clearRegistryError(dir: string, reason: string): void {
  const prev = readRegistryStatus(dir);
  if (!prev || prev.lastError !== reason) return;
  writeStatus(dir, { ...prev, lastError: undefined, hasDeviceToken: hasDeviceToken(dir) });
}

/** 409 で bridgeId を作り直す前の bridgeId を控える（デスクトップは「この PC を新しい PC として登録し直した」案内を出す。PROTOCOL-v3 §15.4）。 */
export function recordRegistryPrevious(dir: string, bridgeId: string, nowMs = Date.now()): void {
  const prev = readRegistryStatus(dir) ?? { lastAttemptAt: nowMs / 1000, hasDeviceToken: hasDeviceToken(dir) };
  writeStatus(dir, { ...prev, registryPrevious: { bridgeId, since: nowMs } });
}

/** `/local/registry/previous/dismiss`。消したら true。 */
export function clearRegistryPrevious(dir: string): boolean {
  const prev = readRegistryStatus(dir);
  if (!prev?.registryPrevious) return false;
  writeStatus(dir, { ...prev, registryPrevious: undefined });
  return true;
}

// ---- registry-hold ----

export interface RegistryHold {
  /** UNIX ミリ秒。 */
  since: number;
  reason: string;
}

export function readRegistryHold(dir: string): RegistryHold | undefined {
  const j = readJson(path.join(dir, "registry-hold"));
  if (!j || typeof j.reason !== "string") return undefined;
  return { since: typeof j.since === "number" ? j.since : 0, reason: j.reason };
}

export function setRegistryHold(dir: string, reason: string, nowMs = Date.now()): void {
  writeFileAtomic(path.join(dir, "registry-hold"), JSON.stringify({ since: nowMs, reason }));
}

export function clearRegistryHold(dir: string): void {
  removeFile(path.join(dir, "registry-hold"));
}

// ---- registered.json ----

export interface RegisteredValues {
  bridgePub: string;
  relayId: string;
  relayURL: string;
}

export function readRegistered(dir: string): RegisteredValues | undefined {
  const j = readJson(path.join(dir, "registered.json"));
  if (!j || typeof j.bridgePub !== "string" || typeof j.relayId !== "string" || typeof j.relayURL !== "string") return undefined;
  return { bridgePub: j.bridgePub, relayId: j.relayId, relayURL: j.relayURL };
}

export function setRegistered(dir: string, r: RegisteredValues): void {
  writeFileAtomic(path.join(dir, "registered.json"), JSON.stringify({ bridgePub: r.bridgePub, relayId: r.relayId, relayURL: r.relayURL }));
}

export function clearRegistered(dir: string): void {
  removeFile(path.join(dir, "registered.json"));
}
