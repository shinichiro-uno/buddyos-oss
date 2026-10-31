import crypto from "node:crypto";

// NOTE: mac-bridge/Sources/Network/E2ECrypto.swift / ios/Sources/E2E/E2ECrypto.swift の
// Node 版同等物。ワイヤ互換を壊さないため、変更は必ず 3 実装すべてに反映すること
// (shared/e2e-test-vectors.json で固定)。

/// E2E 暗号化の失敗理由。WS フレームの検証失敗は呼び出し側で close(1008) すること。
export type E2ECryptoErrorReason =
  // ヘッダ不足・version 不一致など、フレームとして解釈できない
  | "invalidFrame"
  // seq の逆行・重複・欠番(リプレイ/並べ替え/フレーム破棄の疑い)
  | "sequenceViolation"
  // AEAD 検証失敗(改竄または鍵不一致)
  | "decryptionFailed"
  // 鍵素材の長さ不正など
  | "invalidKey";

export class E2ECryptoError extends Error {
  constructor(readonly reason: E2ECryptoErrorReason) {
    super(`E2ECryptoError: ${reason}`);
    this.name = "E2ECryptoError";
  }
}

// アプリ層 E2E 暗号化コア: X25519 + HKDF-SHA256 + ChaCha20-Poly1305(spec/PROTOCOL-v3.md §13.6)。
//
// WS フレーム(PROTOCOL-v3 §13.6、バイナリ):
//   offset 0      : uint8  version = 0x01
//   offset 1      : uint8  flags   = 0x00 (予約)
//   offset 2..9   : uint64 BE seq  (方向ごとに 1 から単調増加)
//   offset 10..   : ChaChaPoly ciphertext || tag(16B)
//   nonce = 0x00000000 || seq(8B BE)   // 方向は鍵で分離済みなので nonce は counter のみ
//   AAD   = ヘッダ 10 バイト

export const FRAME_VERSION = 0x01;
export const HEADER_LENGTH = 10;
export const TAG_LENGTH = 16;
// ヘッダ + tag。暗号化フレームはこれ以上の長さを持つ
export const FRAME_OVERHEAD = HEADER_LENGTH + TAG_LENGTH;

// 経路別の鍵導出ラベル(PROTOCOL-v3 §13.6 / PROTOCOL-v3 §14)。3 実装で共通。変更禁止。
const INFO_C2S = Buffer.from("buddyos/ws/v1/c2s", "utf8");
const INFO_S2C = Buffer.from("buddyos/ws/v1/s2c", "utf8");
const PUSH_SALT = Buffer.from("buddyos/push/v1", "utf8");

// Node は raw 32B の X25519 鍵を直接 import できないため、DER 固定プレフィックスで
// PKCS#8 / SPKI に包む(swift-crypto の rawRepresentation と等価な鍵素材)。
const PKCS8_X25519_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");
const SPKI_X25519_PREFIX = Buffer.from("302a300506032b656e032100", "hex");

// ---- 鍵導出 ----

/** X25519 秘密鍵(raw 32B)から公開鍵(raw 32B)を得る。QR / register_e2e_key 用。 */
export function publicKey(privateKey: Buffer): Buffer {
  const spki = crypto
    .createPublicKey(importPrivateKey(privateKey))
    .export({ format: "der", type: "spki" });
  return Buffer.from(spki.subarray(spki.length - 32));
}

/** SS = X25519(static, static)。ディスクに書かないこと。 */
export function sharedSecret(privateKey: Buffer, peerPublicKey: Buffer): Buffer {
  let ss: Buffer;
  try {
    ss = crypto.diffieHellman({
      privateKey: importPrivateKey(privateKey),
      publicKey: importPublicKey(peerPublicKey),
    });
  } catch {
    throw new E2ECryptoError("invalidKey");
  }
  // CryptoKit は低位点(all-zero 共有秘密)を自動で弾くが Node は返すため、
  // RFC 7748 §6.1 の要請どおり明示的に拒否して挙動を揃える
  if (ss.every((b) => b === 0)) throw new E2ECryptoError("invalidKey");
  return ss;
}

/**
 * WS 方向別鍵(PROTOCOL-v3 §13.6)。connSalt は接続ごとに Bridge が生成する 32B 乱数
 * (接続ごとの鍵分離 — 1 接続の鍵漏洩の影響を局所化)。
 *
 *   k_c2s = HKDF-SHA256(ikm=SS, salt=connSalt, info="buddyos/ws/v1/c2s", L=32)
 *   k_s2c = HKDF-SHA256(ikm=SS, salt=connSalt, info="buddyos/ws/v1/s2c", L=32)
 */
export function deriveWSKeys(
  privateKey: Buffer,
  peerPublicKey: Buffer,
  connSalt: Buffer,
): { c2s: Buffer; s2c: Buffer } {
  const ss = sharedSecret(privateKey, peerPublicKey);
  return {
    c2s: hkdf(ss, connSalt, INFO_C2S),
    s2c: hkdf(ss, connSalt, INFO_S2C),
  };
}

/**
 * push 用鍵(PROTOCOL-v3 §14)。生きたセッションなしで両端が同じ鍵に到達できるよう、salt/info は静的。
 *
 *   k_push = HKDF-SHA256(ikm=SS, salt="buddyos/push/v1", info=bridgeId+"|"+deviceId, L=32)
 */
export function derivePushKey(
  privateKey: Buffer,
  peerPublicKey: Buffer,
  bridgeId: string,
  deviceId: string,
): Buffer {
  const ss = sharedSecret(privateKey, peerPublicKey);
  return hkdf(ss, PUSH_SALT, Buffer.from(`${bridgeId}|${deviceId}`, "utf8"));
}

// ---- WS フレーム encode/decode ----

/** トンネル v3 のフレームの version（spec/PROTOCOL-v3.md §9）。中身の形は v1 と同じ。 */
export const FRAME_VERSION_V3 = 0x03;
/** 1 フレームの暗号文（平文 + tag）の上限。これを超えるフレームは復号せずに拒否する（PROTOCOL-v3 §9）。 */
export const FRAME_MAX_LENGTH = 16 * 1024 * 1024 + FRAME_OVERHEAD;

/**
 * 平文(SessionEvent JSON UTF-8)を暗号化フレームにする。seq は方向ごとに 1 から単調増加。
 * version は先頭の 1 バイト（内側の E2E は 0x01、トンネル v3 は 0x03。PROTOCOL-v3 §9）。
 */
export function encodeFrame(plaintext: Buffer, seq: bigint, key: Buffer, version: number = FRAME_VERSION): Buffer {
  const symKey = requireKey(key);
  const header = Buffer.alloc(HEADER_LENGTH);
  header[0] = version;
  header[1] = 0x00;
  header.writeBigUInt64BE(seq, 2);
  const cipher = crypto.createCipheriv("chacha20-poly1305", symKey, nonceForSeq(seq), {
    authTagLength: TAG_LENGTH,
  });
  // plaintextLength は CCM 用で ChaChaPoly の実行時には不要だが、@types/node の型が要求する
  cipher.setAAD(header, { plaintextLength: plaintext.length });
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([header, ciphertext, cipher.getAuthTag()]);
}

/**
 * 暗号化フレームを開く。長さ・version・flags は復号の前に確かめる（PROTOCOL-v3 §9）。
 * seq の単調性検証は呼び出し側(E2EFrameReceiver)の責務。
 */
export function decodeFrame(frame: Buffer, key: Buffer, version: number = FRAME_VERSION): { seq: bigint; plaintext: Buffer } {
  const symKey = requireKey(key);
  if (frame.length < FRAME_OVERHEAD || frame.length > FRAME_MAX_LENGTH) throw new E2ECryptoError("invalidFrame");
  if (frame[0] !== version) throw new E2ECryptoError("invalidFrame");
  // flags(offset 1)は将来のための予約。0 以外は復号せずに拒否する（PROTOCOL-v3 §9）
  if (frame[1] !== 0x00) throw new E2ECryptoError("invalidFrame");
  const seq = frame.readBigUInt64BE(2);
  const header = frame.subarray(0, HEADER_LENGTH);
  const decipher = crypto.createDecipheriv("chacha20-poly1305", symKey, nonceForSeq(seq), {
    authTagLength: TAG_LENGTH,
  });
  decipher.setAAD(header, { plaintextLength: frame.length - FRAME_OVERHEAD });
  decipher.setAuthTag(frame.subarray(frame.length - TAG_LENGTH));
  try {
    const plaintext = Buffer.concat([
      decipher.update(frame.subarray(HEADER_LENGTH, frame.length - TAG_LENGTH)),
      decipher.final(),
    ]);
    return { seq, plaintext };
  } catch {
    throw new E2ECryptoError("decryptionFailed");
  }
}

// ---- push seal/open ----

/**
 * push ペイロードの暗号化(PROTOCOL-v3 §14)。nonce 省略時はランダム 12B
 * (push は低頻度なので誕生日限界 2^32 に遠く及ばない)。戻り値は (nonce, ciphertext) = (12B, ct||tag)。
 */
export function sealPush(
  plaintext: Buffer,
  key: Buffer,
  nonce?: Buffer,
): { nonce: Buffer; ciphertext: Buffer } {
  const symKey = requireKey(key);
  const n = nonce ?? crypto.randomBytes(12);
  if (n.length !== 12) throw new E2ECryptoError("invalidFrame");
  const cipher = crypto.createCipheriv("chacha20-poly1305", symKey, n, {
    authTagLength: TAG_LENGTH,
  });
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return { nonce: n, ciphertext };
}

/** push ペイロードの復号。失敗時はプレースホルダ表示に落とすこと(PROTOCOL-v3 §14)。 */
export function openPush(ciphertext: Buffer, nonce: Buffer, key: Buffer): Buffer {
  const symKey = requireKey(key);
  if (ciphertext.length < TAG_LENGTH || nonce.length !== 12) {
    throw new E2ECryptoError("invalidFrame");
  }
  const decipher = crypto.createDecipheriv("chacha20-poly1305", symKey, nonce, {
    authTagLength: TAG_LENGTH,
  });
  decipher.setAuthTag(ciphertext.subarray(ciphertext.length - TAG_LENGTH));
  try {
    return Buffer.concat([
      decipher.update(ciphertext.subarray(0, ciphertext.length - TAG_LENGTH)),
      decipher.final(),
    ]);
  } catch {
    throw new E2ECryptoError("decryptionFailed");
  }
}

// ---- 送受信ヘルパ ----

/** WS 送信側: 方向鍵を保持し、seq を 1 から自動採番して seal する(PROTOCOL-v3 §13.6)。 */
export class E2EFrameSender {
  private nextSeqValue = 1n;

  constructor(private readonly key: Buffer, private readonly version: number = FRAME_VERSION) {}

  get nextSeq(): bigint {
    return this.nextSeqValue;
  }

  seal(plaintext: Buffer): Buffer {
    // 2^64 - 1 に達したら送らない（PROTOCOL-v3 §9。呼び出し側は閉じる）
    if (this.nextSeqValue > 0xffff_ffff_ffff_fffen) throw new E2ECryptoError("sequenceViolation");
    const frame = encodeFrame(plaintext, this.nextSeqValue, this.key, this.version);
    this.nextSeqValue += 1n;
    return frame;
  }
}

/**
 * WS 受信側: seq が欠番なしの連番(lastSeq + 1)であることを検証して open する。
 * E2ECryptoError が投げられたら呼び出し側は close(1008) すること — WS は TCP 順序保証が
 * あるため、これだけでリプレイ/並べ替え/途中フレームの破棄を検知できる(PROTOCOL-v3 §13.6)。
 * 末尾フレームを落としてから切断する攻撃は、認証付き close フレームがないため検知できない。
 */
export class E2EFrameReceiver {
  private lastSeqValue = 0n;

  constructor(private readonly key: Buffer, private readonly version: number = FRAME_VERSION) {}

  get lastSeq(): bigint {
    return this.lastSeqValue;
  }

  open(frame: Buffer): Buffer {
    // 長さ・version・flags・seq はすべて復号の前に確かめる（PROTOCOL-v3 §9）。seq は 1 から始まり、0 は不正。
    // 送信側は必ず +1 で採番するので、欠番は relay による選択的な破棄とみなして拒否する
    if (frame.length < FRAME_OVERHEAD || frame.length > FRAME_MAX_LENGTH) throw new E2ECryptoError("invalidFrame");
    if (frame[0] !== this.version || frame[1] !== 0x00) throw new E2ECryptoError("invalidFrame");
    if (frame.readBigUInt64BE(2) !== this.lastSeqValue + 1n) throw new E2ECryptoError("sequenceViolation");
    const { seq, plaintext } = decodeFrame(frame, this.key, this.version);
    // 改竄フレームで seq を進められないよう、更新は open 成功後に行う。
    this.lastSeqValue = seq;
    return plaintext;
  }
}

// ---- private ----

function importPrivateKey(raw: Buffer): crypto.KeyObject {
  if (raw.length !== 32) throw new E2ECryptoError("invalidKey");
  try {
    return crypto.createPrivateKey({
      key: Buffer.concat([PKCS8_X25519_PREFIX, raw]),
      format: "der",
      type: "pkcs8",
    });
  } catch {
    throw new E2ECryptoError("invalidKey");
  }
}

function importPublicKey(raw: Buffer): crypto.KeyObject {
  if (raw.length !== 32) throw new E2ECryptoError("invalidKey");
  try {
    return crypto.createPublicKey({
      key: Buffer.concat([SPKI_X25519_PREFIX, raw]),
      format: "der",
      type: "spki",
    });
  } catch {
    throw new E2ECryptoError("invalidKey");
  }
}

function requireKey(key: Buffer): Buffer {
  if (key.length !== 32) throw new E2ECryptoError("invalidKey");
  return key;
}

function hkdf(ikm: Buffer, salt: Buffer, info: Buffer): Buffer {
  return Buffer.from(crypto.hkdfSync("sha256", ikm, salt, info, 32));
}

function nonceForSeq(seq: bigint): Buffer {
  // 方向は鍵で分離済みなので nonce は counter のみで衝突しない(PROTOCOL-v3 §13.6)
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(seq, 4);
  return nonce;
}
