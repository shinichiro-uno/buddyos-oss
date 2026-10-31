// 参照実装（spec/PROTOCOL-v3.md §5・§8 の関数）。設計の原本からそのまま写したもの。手で直さない（直すなら原本から）。
// Reference implementation of BuddyOS tunnel v3 handshake (Noise_IKpsk2_25519_ChaChaPoly_SHA256).
// Runs with Node >= 22.6 (type stripping). Uses only node:crypto.
import crypto from "node:crypto";

export const PROTOCOL_NAME = "Noise_IKpsk2_25519_ChaChaPoly_SHA256";
const PKCS8_X25519_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI_X25519_PREFIX = Buffer.from("302a300506032b656e032100", "hex");
const ZERO32 = Buffer.alloc(32);

export function x25519Pub(priv: Buffer): Buffer {
  const key = crypto.createPrivateKey({ key: Buffer.concat([PKCS8_X25519_PREFIX, priv]), format: "der", type: "pkcs8" });
  const spki = crypto.createPublicKey(key).export({ format: "der", type: "spki" }) as Buffer;
  return spki.subarray(spki.length - 32);
}

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

/** Initiator: write message 1 (-> e, es, s, ss). */
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
/** BuddyOS frame (v3) receive side. Checks §4.2.5 (length, version, flags, seq) BEFORE decrypting. */
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

// ---- 付録 A.2 ----

/** §4.0.1: strict base64url (no padding, canonical). Returns null when invalid. */
export function b64uDecodeStrict(s: string, len?: number): Buffer | null {
  if (!/^[A-Za-z0-9_-]*$/.test(s) || s.length % 4 === 1) return null;
  const b = Buffer.from(s, "base64url");
  if (b.toString("base64url") !== s) return null;
  if (len !== undefined && b.length !== len) return null;
  return b;
}

/** §4.0.2: name sanitizer (counts Unicode scalar values, never splits a surrogate pair). */
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

/** §4.0.2: "<name> · <first 4 chars of deviceKeyId>" */
export const displayName = (name: string, deviceKeyId: string): string => `${name} · ${deviceKeyId.slice(0, 4)}`;

/** §4.0.3: encode everything except [A-Za-z0-9-._~]; "+" becomes %2B, space %20. */
export const qrEncode = (v: string): string =>
  encodeURIComponent(v).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());

/** §4.0.3: split on "&" and the first "="; only %XX is decoded ("+" stays "+"). Duplicate keys → null. */
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

/** §4.0.3 / §4.1: build the pairing URL in the fixed key order. */
export const QR_KEYS = ["v", "bridgeId", "name", "platform", "relay", "relayId", "key", "secret", "exp"] as const;
export function buildPairUrl(fields: Record<(typeof QR_KEYS)[number], string>): string {
  return "buddyos://pair?" + QR_KEYS.map((k) => `${k}=${qrEncode(fields[k])}`).join("&");
}

/** §4.4.2: confirmation code typed on the PC. Spaces and hyphens are removed; only 6 ASCII digits pass. */
export function normalizeCode(input: string): string | null {
  const s = input.replace(/[ -]/g, "");
  return /^[0-9]{6}$/.test(s) ? s : null;
}

/** §4.2.8: "213854" → "213 854" */
export const sasDisplay = (code: string): string => `${code.slice(0, 3)} ${code.slice(3)}`;
