import crypto from "node:crypto";

// トンネル v3（Noise_IKpsk2_25519_ChaChaPoly_SHA256）と、端末認証 v3 のワイヤ形式の決まり。
// 正本は spec/PROTOCOL-v3.md（§5・§6・§8）。握手・b64u・名前・URL は仕様の参照実装（TypeScript、node:crypto）を
// そのまま写したもの。値は shared/e2e-test-vectors.json の tunnelV3 / pairingV3（PROTOCOL-v3 §18）で mac-bridge・iOS・desktop・
// Android と一致を確かめる。変えるときは 5 実装と文書をそろえること。

export const PROTOCOL_NAME = "Noise_IKpsk2_25519_ChaChaPoly_SHA256";
const PKCS8_X25519_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI_X25519_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const ZERO32 = Buffer.alloc(32);

export function x25519Pub(priv: Buffer): Buffer {
  const key = crypto.createPrivateKey({ key: Buffer.concat([PKCS8_X25519_PREFIX, priv]), format: "der", type: "pkcs8" });
  const spki = crypto.createPublicKey(key).export({ format: "der", type: "spki" }) as Buffer;
  return Buffer.from(spki.subarray(spki.length - 32));
}

/** X25519。結果が 0 が 32 バイトなら失敗（PROTOCOL-v3 §8.1）。 */
export function dh(priv: Buffer, pub: Buffer): Buffer {
  const out = crypto.diffieHellman({
    privateKey: crypto.createPrivateKey({ key: Buffer.concat([PKCS8_X25519_PREFIX, priv]), format: "der", type: "pkcs8" }),
    publicKey: crypto.createPublicKey({ key: Buffer.concat([SPKI_X25519_PREFIX, pub]), format: "der", type: "spki" })
  });
  if (crypto.timingSafeEqual(out, ZERO32)) throw new Error("dh: all-zero output");
  return out;
}

const sha256 = (...parts: Buffer[]): Buffer => crypto.createHash("sha256").update(Buffer.concat(parts)).digest();
const hmac = (key: Buffer, data: Buffer): Buffer => crypto.createHmac("sha256", key).update(data).digest();

/** Noise HKDF (== RFC 5869 HKDF-SHA256 with salt=ck, info="", but written with HMAC so an empty ikm is fine). */
export function noiseHkdf(ck: Buffer, ikm: Buffer, n: 2 | 3): Buffer[] {
  const temp = hmac(ck, ikm);
  const o1 = hmac(temp, Buffer.from([1]));
  const o2 = hmac(temp, Buffer.concat([o1, Buffer.from([2])]));
  if (n === 2) return [o1, o2];
  const o3 = hmac(temp, Buffer.concat([o2, Buffer.from([3])]));
  return [o1, o2, o3];
}

/** Noise ChaChaPoly nonce: 4 zero bytes || 64-bit little-endian counter. */
function noiseNonce(n: bigint): Buffer {
  const b = Buffer.alloc(12);
  b.writeBigUInt64LE(n, 4);
  return b;
}

export function aeadSeal(key: Buffer, nonce: Buffer, ad: Buffer, pt: Buffer): Buffer {
  const c = crypto.createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
  c.setAAD(ad, { plaintextLength: pt.length });
  return Buffer.concat([c.update(pt), c.final(), c.getAuthTag()]);
}

export function aeadOpen(key: Buffer, nonce: Buffer, ad: Buffer, ct: Buffer): Buffer {
  if (ct.length < 16) throw new Error("aead: short");
  const d = crypto.createDecipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
  d.setAAD(ad, { plaintextLength: ct.length - 16 });
  d.setAuthTag(ct.subarray(ct.length - 16));
  return Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
}

/** Noise SymmetricState (HASHLEN = 32). */
export class Symmetric {
  ck: Buffer;
  h: Buffer;
  k: Buffer | null = null;
  n = 0n;

  constructor(protocolName: string) {
    const name = Buffer.from(protocolName, "ascii");
    this.h = name.length <= 32 ? Buffer.concat([name, Buffer.alloc(32 - name.length)]) : sha256(name);
    this.ck = Buffer.from(this.h);
  }
  mixHash(data: Buffer): void {
    this.h = sha256(this.h, data);
  }
  mixKey(ikm: Buffer): void {
    const [ck, k] = noiseHkdf(this.ck, ikm, 2);
    this.ck = ck;
    this.k = k;
    this.n = 0n;
  }
  mixKeyAndHash(ikm: Buffer): void {
    const [ck, th, k] = noiseHkdf(this.ck, ikm, 3);
    this.ck = ck;
    this.mixHash(th);
    this.k = k;
    this.n = 0n;
  }
  encryptAndHash(pt: Buffer): Buffer {
    if (!this.k) {
      this.mixHash(pt);
      return pt;
    }
    const ct = aeadSeal(this.k, noiseNonce(this.n), this.h, pt);
    this.n += 1n;
    this.mixHash(ct);
    return ct;
  }
  decryptAndHash(ct: Buffer): Buffer {
    if (!this.k) {
      this.mixHash(ct);
      return ct;
    }
    const pt = aeadOpen(this.k, noiseNonce(this.n), this.h, ct);
    this.n += 1n;
    this.mixHash(ct);
    return pt;
  }
  split(): [Buffer, Buffer] {
    const [k1, k2] = noiseHkdf(this.ck, Buffer.alloc(0), 2);
    return [k1, k2];
  }
}

export interface InitiatorInput {
  prologue: Buffer;
  sI: Buffer; // initiator static private
  eI: Buffer; // initiator ephemeral private (tests only; random otherwise)
  sRpub: Buffer; // responder static public (pinned)
  psk: Buffer; // 32 bytes (zeros when not pairing)
}

/** Initiator: write message 1 (-> e, es, s, ss). Bridge では使わない（テストの相手役）。 */
export function initiatorWrite1(inp: InitiatorInput, payload: Buffer) {
  const st = new Symmetric(PROTOCOL_NAME);
  st.mixHash(inp.prologue);
  st.mixHash(inp.sRpub); // pre-message <- s
  const ePub = x25519Pub(inp.eI);
  st.mixHash(ePub);
  st.mixKey(ePub); // psk rule: e also feeds MixKey
  st.mixKey(dh(inp.eI, inp.sRpub)); // es
  const sPubCt = st.encryptAndHash(x25519Pub(inp.sI)); // s
  st.mixKey(dh(inp.sI, inp.sRpub)); // ss
  const payloadCt = st.encryptAndHash(payload);
  return { st, ePub, sPubCt, payloadCt };
}

/** Initiator: read message 2 (<- e, ee, se, psk). */
export function initiatorRead2(inp: InitiatorInput, st: Symmetric, eRpub: Buffer, payloadCt: Buffer) {
  st.mixHash(eRpub);
  st.mixKey(eRpub);
  st.mixKey(dh(inp.eI, eRpub)); // ee
  st.mixKey(dh(inp.sI, eRpub)); // se
  st.mixKeyAndHash(inp.psk); // psk
  const payload = st.decryptAndHash(payloadCt);
  const [c2s, s2c] = st.split();
  return { payload, c2s, s2c, handshakeHash: st.h };
}

export interface ResponderInput {
  prologue: Buffer;
  sR: Buffer; // responder static private
  eR: Buffer; // responder ephemeral private (tests only)
}

/** Responder: read message 1. Returns the initiator static public key and payload. */
export function responderRead1(inp: ResponderInput, ePub: Buffer, sPubCt: Buffer, payloadCt: Buffer) {
  const st = new Symmetric(PROTOCOL_NAME);
  st.mixHash(inp.prologue);
  st.mixHash(x25519Pub(inp.sR));
  st.mixHash(ePub);
  st.mixKey(ePub);
  st.mixKey(dh(inp.sR, ePub)); // es
  const sIpub = st.decryptAndHash(sPubCt);
  st.mixKey(dh(inp.sR, sIpub)); // ss
  const payload = st.decryptAndHash(payloadCt);
  return { st, sIpub, payload };
}

/** Responder: write message 2. psk is chosen after reading message 1 (invite psk or zeros). */
export function responderWrite2(inp: ResponderInput, st: Symmetric, ePubI: Buffer, sIpub: Buffer, psk: Buffer, payload: Buffer) {
  const eRpub = x25519Pub(inp.eR);
  st.mixHash(eRpub);
  st.mixKey(eRpub);
  st.mixKey(dh(inp.eR, ePubI)); // ee
  st.mixKey(dh(inp.eR, sIpub)); // se
  st.mixKeyAndHash(psk);
  const payloadCt = st.encryptAndHash(payload);
  const [c2s, s2c] = st.split();
  return { eRpub, payloadCt, c2s, s2c, handshakeHash: st.h };
}

// ---- BuddyOS-specific helpers ----

export const PROLOGUE = Buffer.from("buddyos-tunnel-v3", "ascii");
export const ZERO_PSK = Buffer.alloc(32);

export const b64u = (b: Buffer): string => b.toString("base64url");

/** RFC 5869 HKDF-SHA256 (used for invite id / psk; ikm is never empty here). */
export function hkdf(ikm: Buffer, salt: Buffer, info: string, len: number): Buffer {
  return Buffer.from(crypto.hkdfSync("sha256", ikm, salt, Buffer.from(info, "utf8"), len));
}

export function inviteId(secret: Buffer): string {
  return b64u(hkdf(secret, Buffer.alloc(0), "buddyos/v3/invite-id", 16));
}
export function invitePsk(secret: Buffer): Buffer {
  return hkdf(secret, Buffer.alloc(0), "buddyos/v3/invite-psk", 32);
}
export function deviceKeyId(devicePub: Buffer): string {
  return b64u(sha256(devicePub).subarray(0, 16));
}
export function sasCommit(nR: Buffer): Buffer {
  return sha256(Buffer.from("buddyos/v3/sas-commit", "utf8"), nR);
}
export function sasCode(handshakeHash: Buffer, nI: Buffer, nR: Buffer): string {
  const d = sha256(Buffer.from("buddyos/v3/sas", "utf8"), handshakeHash, nI, nR);
  return String(d.readUInt32BE(0) % 1_000_000).padStart(6, "0");
}
export function credentialHash(credential: string): string {
  return crypto.createHash("sha256").update(credential, "utf8").digest("hex");
}
/** 端末ごとの資格情報（PROTOCOL-v3 §4）。"bdc_" + b64u(32 バイトの乱数)、47 文字。 */
export function newCredential(): string {
  return `bdc_${b64u(crypto.randomBytes(32))}`;
}

/** BuddyOS frame (v3): header = [0x03, 0x00, seq(8 BE)], nonce = 0^4 || seq BE, AAD = header. */
export function sealFrameV3(key: Buffer, seq: bigint, pt: Buffer): Buffer {
  const header = Buffer.alloc(10);
  header[0] = 0x03;
  header[1] = 0x00;
  header.writeBigUInt64BE(seq, 2);
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(seq, 4);
  return Buffer.concat([header, aeadSeal(key, nonce, header, pt)]);
}
/** BuddyOS frame (v3) receive side. Checks PROTOCOL-v3 §9 (length, version, flags, seq) BEFORE decrypting. */
export function openFrameV3(key: Buffer, frame: Buffer, expectedSeq: bigint): { seq: bigint; pt: Buffer } {
  if (frame.length < 26 || frame.length > 16 * 1024 * 1024 + 26) throw new Error("frame: length");
  if (frame[0] !== 0x03 || frame[1] !== 0x00) throw new Error("frame: header");
  const header = frame.subarray(0, 10);
  const seq = header.readBigUInt64BE(2);
  if (seq === 0n || seq !== expectedSeq) throw new Error("frame: seq");
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(seq, 4);
  return { seq, pt: aeadOpen(key, nonce, header, frame.subarray(10)) };
}

// ---- b64u・名前・URL・番号（PROTOCOL-v3 §5） ----

/** PROTOCOL-v3 §5.1: strict base64url (no padding, canonical). Returns null when invalid. */
export function b64uDecodeStrict(s: string, len?: number): Buffer | null {
  if (!/^[A-Za-z0-9_-]*$/.test(s) || s.length % 4 === 1) return null;
  const b = Buffer.from(s, "base64url");
  if (b.toString("base64url") !== s) return null;
  if (len !== undefined && b.length !== len) return null;
  return b;
}

/** 端末の名前の既定値（PROTOCOL-v3 §5.3）。 */
export const DEVICE_NAME_FALLBACK = "端末";
/** PC の名前の既定値（PROTOCOL-v3 §5.3）。 */
export const BRIDGE_NAME_FALLBACK = "PC";

/** PROTOCOL-v3 §5.3: name sanitizer (counts Unicode scalar values, never splits a surrogate pair). */
export function sanitizeName(input: string, fallback: string): string {
  let mapped = "";
  for (const ch of input) {
    const cp = ch.codePointAt(0)!;
    if (/^[\p{Zs}\p{Zl}\p{Zp}]$/u.test(ch) || (cp >= 0x09 && cp <= 0x0d) || cp === 0x85) mapped += " ";
    else if (/^[\p{Cc}\p{Cf}\p{Cs}]$/u.test(ch)) continue;
    else mapped += ch;
  }
  const collapsed = mapped.replace(/ {2,}/g, " ").trim();
  const cut = Array.from(collapsed).slice(0, 64).join("").trim();
  return cut.length ? cut : fallback;
}

/** PROTOCOL-v3 §5.3: "<name> · <first 4 chars of deviceKeyId>" */
export const displayName = (name: string, deviceKeyId: string): string => `${name} · ${deviceKeyId.slice(0, 4)}`;

/** PROTOCOL-v3 §5.4: encode everything except [A-Za-z0-9-._~]; "+" becomes %2B, space %20. */
export const qrEncode = (v: string): string =>
  encodeURIComponent(v).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());

/** PROTOCOL-v3 §5.4: split on "&" and the first "="; only %XX is decoded ("+" stays "+"). Duplicate keys → null. */
export function parseQuery(query: string): Map<string, string> | null {
  const out = new Map<string, string>();
  for (const part of query.split("&")) {
    if (!part) continue;
    const i = part.indexOf("=");
    const rawKey = i < 0 ? part : part.slice(0, i);
    const rawValue = i < 0 ? "" : part.slice(i + 1);
    let key: string, value: string;
    try { key = decodeURIComponent(rawKey); value = decodeURIComponent(rawValue); } catch { return null; }
    if (out.has(key)) return null;
    out.set(key, value);
  }
  return out;
}

/** PROTOCOL-v3 §5.4 / PROTOCOL-v3 §6: build the pairing URL in the fixed key order. */
export const QR_KEYS = ["v", "bridgeId", "name", "platform", "relay", "relayId", "key", "secret", "exp"] as const;
export type PairUrlFields = Record<(typeof QR_KEYS)[number], string>;
export function buildPairUrl(fields: PairUrlFields): string {
  return "buddyos://pair?" + QR_KEYS.map((k) => `${k}=${qrEncode(fields[k])}`).join("&");
}

/** PROTOCOL-v3 Appendix A: confirmation code typed on the PC. Spaces and hyphens are removed; only 6 ASCII digits pass. */
export function normalizeCode(input: string): string | null {
  const s = input.replace(/[ -]/g, "");
  return /^[0-9]{6}$/.test(s) ? s : null;
}

/** 定数時間の比較（長さは漏れてよい値だけに使う。確認コードは 6 桁で長さが決まっている）。 */
export function constantTimeEquals(a: string, b: string): boolean {
  const lhs = Buffer.from(a, "utf8");
  const rhs = Buffer.from(b, "utf8");
  return lhs.length === rhs.length && crypto.timingSafeEqual(lhs, rhs);
}

// ---- PROTOCOL-v3 §8.3・§10: 握手のメッセージ ----

/** TEXT の JSON・制御メッセージの上限（PROTOCOL-v3 §12）。 */
export const CONTROL_MAX_BYTES = 4096;
/** payload1・payload2 の上限（PROTOCOL-v3 §8.6）。 */
export const PAYLOAD_MAX_BYTES = 1024;

export type TunnelMode = "connect" | "pair" | "approve";
export type DevicePlatform = "ios" | "android" | "mac" | "windows";
const PLATFORMS: readonly string[] = ["ios", "android", "mac", "windows"];
const DEVICE_ID_PATTERN = /^[A-Za-z0-9._-]{8,80}$/;

/** msg1（`buddyos_tunnel_init`、v=3）を読んだ結果。 */
export type InitParse =
  | { kind: "ok"; e: Buffer; s: Buffer; p: Buffer }
  /** v が無い・3 以外（v2 以前の init を含む）。`buddyos_tunnel_error`（version）を返して閉じる。 */
  | { kind: "version" }
  /** v=3 だが e・s・p の形が違う。`bad_message` を返して閉じる。 */
  | { kind: "bad" }
  /** init ではない TEXT（読み捨てる）。 */
  | { kind: "ignore" };

/** msg1 の TEXT を読む（PROTOCOL-v3 §8.3・§8.10）。e は 32 バイト、s は 48 バイト、p は 16 バイト以上（厳しい b64u）。 */
export function parseInitV3(text: string): InitParse {
  if (Buffer.byteLength(text, "utf8") > CONTROL_MAX_BYTES) return { kind: "bad" };
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return { kind: "ignore" };
  }
  if (!isObject(value) || value.type !== "buddyos_tunnel_init") return { kind: "ignore" };
  if (value.v !== 3) return { kind: "version" };
  if (typeof value.e !== "string" || typeof value.s !== "string" || typeof value.p !== "string") return { kind: "bad" };
  const e = b64uDecodeStrict(value.e, 32);
  const s = b64uDecodeStrict(value.s, 48);
  const p = b64uDecodeStrict(value.p);
  if (!e || !s || !p || p.length < 16) return { kind: "bad" };
  return { kind: "ok", e, s, p };
}

/** msg2（PROTOCOL-v3 §8.4）の TEXT。 */
export function helloText(e: Buffer, p: Buffer): string {
  return JSON.stringify({ type: "buddyos_tunnel_hello", v: 3, e: b64u(e), p: b64u(p) });
}

/** PROTOCOL-v3 §8.9 の平文のエラー（認証されない）。 */
export type TunnelErrorCode = "version" | "invite_invalid" | "bad_message" | "rate_limited";
export function tunnelErrorText(code: TunnelErrorCode): string {
  return JSON.stringify({ type: "buddyos_tunnel_error", v: 3, code });
}

export interface Payload1 {
  mode: TunnelMode;
  deviceId: string;
  /** pair・approve のときだけ。PROTOCOL-v3 §5.3 で無害化済み（空なら「端末」）。 */
  name?: string;
  platform: DevicePlatform;
  app?: string;
  /** pair のときだけ。inviteId（b64u 22 文字）。 */
  invite?: string;
}

/** payload1 を読んだ結果。mode が読めたら、形の誤りでも mode を返す（pair の psk を選ぶため）。 */
export type Payload1Parse =
  | { kind: "ok"; payload: Payload1 }
  | { kind: "bad"; mode?: TunnelMode; invite?: string };

/** payload1（PROTOCOL-v3 §8.6）。知らないキーは無視する。 */
export function parsePayload1(raw: Buffer): Payload1Parse {
  if (raw.length > PAYLOAD_MAX_BYTES) return { kind: "bad" };
  let value: unknown;
  try {
    value = JSON.parse(raw.toString("utf8"));
  } catch {
    return { kind: "bad" };
  }
  if (!isObject(value)) return { kind: "bad" };
  const mode = value.mode === "connect" || value.mode === "pair" || value.mode === "approve" ? value.mode : undefined;
  if (!mode) return { kind: "bad" };
  const invite = mode === "pair" && typeof value.invite === "string" && b64uDecodeStrict(value.invite, 16) ? value.invite : undefined;
  const bad: Payload1Parse = { kind: "bad", mode, invite };
  if (typeof value.deviceId !== "string" || !DEVICE_ID_PATTERN.test(value.deviceId)) return bad;
  if (typeof value.platform !== "string" || !PLATFORMS.includes(value.platform)) return bad;
  if (value.app !== undefined && (typeof value.app !== "string" || value.app.length > 32)) return bad;
  let name: string | undefined;
  if (mode !== "connect") {
    if (typeof value.name !== "string") return bad;
    name = sanitizeName(value.name, DEVICE_NAME_FALLBACK);
  }
  if (mode === "pair" && !invite) return bad;
  return {
    kind: "ok",
    payload: {
      mode,
      deviceId: value.deviceId,
      name,
      platform: value.platform as DevicePlatform,
      app: typeof value.app === "string" ? value.app : undefined,
      invite
    }
  };
}

/** payload2 の `error`（PROTOCOL-v3 §8.6）。 */
export type Payload2Error =
  | "unknown_device"
  | "revoked"
  | "bad_request"
  | "approval_unavailable"
  | "busy"
  | "rate_limited"
  | "too_many_devices"
  | "bridge_error";

/** payload2（Bridge → 端末）。キーの順はベクタと同じ（ok・bridgeId・name・platform・deviceKeyId・commit）。commit は approve だけ。 */
export function payload2Ok(fields: { bridgeId: string; name: string; platform: "mac" | "windows"; deviceKeyId: string; commit?: Buffer }): Buffer {
  return Buffer.from(
    JSON.stringify({
      ok: true,
      bridgeId: fields.bridgeId,
      name: fields.name,
      platform: fields.platform,
      deviceKeyId: fields.deviceKeyId,
      ...(fields.commit ? { commit: b64u(fields.commit) } : {})
    }),
    "utf8"
  );
}

export function payload2Error(error: Payload2Error): Buffer {
  return Buffer.from(JSON.stringify({ ok: false, error }), "utf8");
}

/** トンネルの中の制御メッセージ（PROTOCOL-v3 §10 の表）。c2s で Windows が受けるもの。 */
export type ControlC2S = { type: "open" } | { type: "pair_confirm" } | { type: "paired_ack" } | { type: "pair_cancel" } | { type: "approve_nonce"; n: string };

/** 制御メッセージを読む。JSON でない・4096 バイトを超える・知らない type は null（呼び出し側は閉じる）。 */
export function parseControl(raw: Buffer): ControlC2S | null {
  if (raw.length > CONTROL_MAX_BYTES) return null;
  let value: unknown;
  try {
    value = JSON.parse(raw.toString("utf8"));
  } catch {
    return null;
  }
  if (!isObject(value)) return null;
  switch (value.type) {
    case "open":
    case "pair_confirm":
    case "paired_ack":
    case "pair_cancel":
      return { type: value.type };
    case "approve_nonce":
      return typeof value.n === "string" && b64uDecodeStrict(value.n, 32) ? { type: "approve_nonce", n: value.n } : null;
    default:
      return null;
  }
}

export interface PairedBridgeInfo {
  bridgeId: string;
  name: string;
  platform: "mac" | "windows";
  relayId: string;
  relayURL: string;
}

/** `paired`（s2c）の平文。 */
export function pairedMessage(deviceKeyIdValue: string, credential: string, bridge: PairedBridgeInfo): Buffer {
  return Buffer.from(
    JSON.stringify({
      type: "paired",
      deviceKeyId: deviceKeyIdValue,
      credential,
      bridge: { bridgeId: bridge.bridgeId, name: bridge.name, platform: bridge.platform, relayId: bridge.relayId, relayURL: bridge.relayURL }
    }),
    "utf8"
  );
}

/**
 * approve: approve_nonce を受けて承認待ちを作った後に nR を明かす（PROTOCOL-v3 §10.4.2）。mac と同じく文字列で組む
 * （b64u は JSON でそのまま書ける文字だけ。トンネルの中の制御メッセージなので protocol.json の種別には入れない）。
 */
export function approveRevealMessage(nR: Buffer): Buffer {
  return Buffer.from(`{"type":"approve_reveal","n":"${b64u(nR)}"}`, "utf8");
}

/** approve: 承認待ちの間、20 秒ごとに送る keepalive（PROTOCOL-v3 §12）。 */
export const APPROVAL_WAITING_MESSAGE = Buffer.from('{"type":"approval_waiting"}', "utf8");

export type PairRejectedReason =
  | "rejected"
  | "timeout"
  | "code_mismatch"
  | "closed"
  | "busy"
  | "rate_limited"
  | "too_many_devices"
  | "bridge_error"
  | "reset";

export function pairRejectedMessage(reason: PairRejectedReason): Buffer {
  return Buffer.from(JSON.stringify({ type: "pair_rejected", reason }), "utf8");
}

function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
