import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  E2ECryptoError,
  E2EFrameReceiver,
  E2EFrameSender,
  decodeFrame,
  derivePushKey,
  deriveWSKeys,
  encodeFrame,
  openPush,
  publicKey,
  sealPush,
  sharedSecret,
} from "./e2e.js";

// shared/e2e-test-vectors.json は Swift 側(E2ECryptoTests)が生成した相互運用ベクタ。
// ここでの検証 = 「Swift が seal した暗号文を TS で open できる / TS の seal がベクタと
// バイト一致する」ことの証明。ベクタ JSON の改変は禁止。
const vectorsPath = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "..",
  "shared",
  "e2e-test-vectors.json",
);

interface WSFrameVector {
  direction: "c2s" | "s2c";
  seq: number;
  plaintext: string;
  frame: string;
}

interface Vectors {
  keys: {
    bridgePriv: string;
    bridgePub: string;
    devicePriv: string;
    devicePub: string;
    sharedSecret: string;
  };
  ws: { connSalt: string; kC2S: string; kS2C: string; frames: WSFrameVector[] };
  push: {
    bridgeId: string;
    deviceId: string;
    kPush: string;
    vectors: { nonce: string; plaintext: string; ciphertext: string }[];
  };
}

const vectors: Vectors = JSON.parse(fs.readFileSync(vectorsPath, "utf8"));
const hex = (s: string) => Buffer.from(s, "hex");
const keys = vectors.keys;

test("ベクタ: 秘密鍵から公開鍵を導出できる (RFC 7748 §6.1)", () => {
  assert.deepEqual(publicKey(hex(keys.bridgePriv)), hex(keys.bridgePub));
  assert.deepEqual(publicKey(hex(keys.devicePriv)), hex(keys.devicePub));
});

test("ベクタ: 共有秘密が両方向で一致する", () => {
  const expected = hex(keys.sharedSecret);
  assert.deepEqual(sharedSecret(hex(keys.bridgePriv), hex(keys.devicePub)), expected);
  assert.deepEqual(sharedSecret(hex(keys.devicePriv), hex(keys.bridgePub)), expected);
});

test("ベクタ: WS 方向別鍵の導出 (info=buddyos/ws/v1/c2s|s2c)", () => {
  // Bridge 視点(自分の秘密鍵 + デバイス公開鍵)とデバイス視点で同一鍵に到達すること
  const fromBridge = deriveWSKeys(hex(keys.bridgePriv), hex(keys.devicePub), hex(vectors.ws.connSalt));
  const fromDevice = deriveWSKeys(hex(keys.devicePriv), hex(keys.bridgePub), hex(vectors.ws.connSalt));
  assert.deepEqual(fromBridge.c2s, hex(vectors.ws.kC2S));
  assert.deepEqual(fromBridge.s2c, hex(vectors.ws.kS2C));
  assert.deepEqual(fromDevice.c2s, fromBridge.c2s);
  assert.deepEqual(fromDevice.s2c, fromBridge.s2c);
});

test("ベクタ: push 鍵の導出 (salt=buddyos/push/v1, info=bridgeId|deviceId)", () => {
  const kPush = derivePushKey(
    hex(keys.bridgePriv),
    hex(keys.devicePub),
    vectors.push.bridgeId,
    vectors.push.deviceId,
  );
  assert.deepEqual(kPush, hex(vectors.push.kPush));
});

test("ベクタ: WS フレームの encode が Swift 生成のフレームとバイト一致する", () => {
  for (const v of vectors.ws.frames) {
    const key = hex(v.direction === "c2s" ? vectors.ws.kC2S : vectors.ws.kS2C);
    const frame = encodeFrame(Buffer.from(v.plaintext, "utf8"), BigInt(v.seq), key);
    assert.equal(frame.toString("hex"), v.frame, `direction=${v.direction} seq=${v.seq}`);
  }
});

test("ベクタ: Swift 生成の WS フレームを decode できる", () => {
  for (const v of vectors.ws.frames) {
    const key = hex(v.direction === "c2s" ? vectors.ws.kC2S : vectors.ws.kS2C);
    const { seq, plaintext } = decodeFrame(hex(v.frame), key);
    assert.equal(seq, BigInt(v.seq));
    assert.equal(plaintext.toString("utf8"), v.plaintext);
  }
});

test("ベクタ: push の seal が Swift 生成の暗号文と一致し、open で平文に戻る", () => {
  const kPush = hex(vectors.push.kPush);
  for (const v of vectors.push.vectors) {
    const sealed = sealPush(Buffer.from(v.plaintext, "utf8"), kPush, hex(v.nonce));
    assert.equal(sealed.ciphertext.toString("hex"), v.ciphertext);
    const opened = openPush(hex(v.ciphertext), hex(v.nonce), kPush);
    assert.equal(opened.toString("utf8"), v.plaintext);
  }
});

test("ラウンドトリップ: ランダム鍵で sender→receiver が復元できる", () => {
  const key = crypto.randomBytes(32);
  const sender = new E2EFrameSender(key);
  const receiver = new E2EFrameReceiver(key);
  for (const text of ["{\"type\":\"ping\"}", "{\"type\":\"user_message\",\"content\":\"日本語🚀\"}", ""]) {
    const plaintext = Buffer.from(text, "utf8");
    assert.deepEqual(receiver.open(sender.seal(plaintext)), plaintext);
  }
  assert.equal(sender.nextSeq, 4n);
  assert.equal(receiver.lastSeq, 3n);
});

test("ラウンドトリップ: push はランダム nonce でも復元できる", () => {
  const key = crypto.randomBytes(32);
  const plaintext = Buffer.from("{\"title\":\"BuddyOS\",\"body\":\"完了\"}", "utf8");
  const sealed = sealPush(plaintext, key);
  assert.equal(sealed.nonce.length, 12);
  assert.deepEqual(openPush(sealed.ciphertext, sealed.nonce, key), plaintext);
});

test("seq 検証: 逆行・重複フレームは sequenceViolation で拒否する", () => {
  const key = crypto.randomBytes(32);
  const receiver = new E2EFrameReceiver(key);
  const frame1 = encodeFrame(Buffer.from("a"), 1n, key);
  const frame2 = encodeFrame(Buffer.from("b"), 2n, key);
  receiver.open(frame1);
  receiver.open(frame2);
  // 重複(seq=2 再送)と逆行(seq=1)の両方を拒否
  assert.throws(() => receiver.open(frame2), (e: E2ECryptoError) => e.reason === "sequenceViolation");
  assert.throws(() => receiver.open(frame1), (e: E2ECryptoError) => e.reason === "sequenceViolation");
  assert.equal(receiver.lastSeq, 2n);
});

test("seq 検証: 欠番(1→3)は sequenceViolation で拒否する", () => {
  const key = crypto.randomBytes(32);
  const receiver = new E2EFrameReceiver(key);
  receiver.open(encodeFrame(Buffer.from("a"), 1n, key));
  // relay が seq=2 を捨てた想定。seq=3 は受理しない
  const frame3 = encodeFrame(Buffer.from("c"), 3n, key);
  assert.throws(() => receiver.open(frame3), (e: E2ECryptoError) => e.reason === "sequenceViolation");
  assert.equal(receiver.lastSeq, 1n);
  // 先頭が 1 以外(seq=2 から始まる)も欠番として拒否
  const fresh = new E2EFrameReceiver(key);
  assert.throws(() => fresh.open(encodeFrame(Buffer.from("b"), 2n, key)), (e: E2ECryptoError) => e.reason === "sequenceViolation");
  assert.equal(fresh.lastSeq, 0n);
});

test("改竄検知: 暗号文・AAD ヘッダ・鍵違いは decryptionFailed", () => {
  const key = crypto.randomBytes(32);
  const frame = encodeFrame(Buffer.from("{\"type\":\"ping\"}"), 1n, key);

  const tamperedBody = Buffer.from(frame);
  tamperedBody[12] ^= 0xff;
  assert.throws(() => decodeFrame(tamperedBody, key), (e: E2ECryptoError) => e.reason === "decryptionFailed");

  // flags は予約。0 以外は復号の前に invalidFrame で拒否する（spec/PROTOCOL-v3.md §9）
  const tamperedFlags = Buffer.from(frame);
  tamperedFlags[1] = 0x01;
  assert.throws(() => decodeFrame(tamperedFlags, key), (e: E2ECryptoError) => e.reason === "invalidFrame");

  assert.throws(
    () => decodeFrame(frame, crypto.randomBytes(32)),
    (e: E2ECryptoError) => e.reason === "decryptionFailed",
  );

  // 改竄フレームで receiver の lastSeq が進まないこと
  const receiver = new E2EFrameReceiver(key);
  assert.throws(() => receiver.open(tamperedBody), (e: E2ECryptoError) => e.reason === "decryptionFailed");
  assert.equal(receiver.lastSeq, 0n);
  assert.deepEqual(receiver.open(frame), Buffer.from("{\"type\":\"ping\"}"));
});

test("改竄検知: push の暗号文・nonce・鍵違いは decryptionFailed", () => {
  const key = crypto.randomBytes(32);
  const sealed = sealPush(Buffer.from("secret"), key);

  const tampered = Buffer.from(sealed.ciphertext);
  tampered[0] ^= 0xff;
  assert.throws(() => openPush(tampered, sealed.nonce, key), (e: E2ECryptoError) => e.reason === "decryptionFailed");

  const wrongNonce = Buffer.from(sealed.nonce);
  wrongNonce[0] ^= 0xff;
  assert.throws(
    () => openPush(sealed.ciphertext, wrongNonce, key),
    (e: E2ECryptoError) => e.reason === "decryptionFailed",
  );

  assert.throws(
    () => openPush(sealed.ciphertext, sealed.nonce, crypto.randomBytes(32)),
    (e: E2ECryptoError) => e.reason === "decryptionFailed",
  );
});

test("フレーム検証: version 不一致・短小フレームは invalidFrame", () => {
  const key = crypto.randomBytes(32);
  const frame = encodeFrame(Buffer.from("x"), 1n, key);

  const wrongVersion = Buffer.from(frame);
  wrongVersion[0] = 0x02;
  assert.throws(() => decodeFrame(wrongVersion, key), (e: E2ECryptoError) => e.reason === "invalidFrame");

  assert.throws(() => decodeFrame(Buffer.alloc(25), key), (e: E2ECryptoError) => e.reason === "invalidFrame");
});

test("鍵検証: 32B 以外の鍵素材は invalidKey", () => {
  assert.throws(() => encodeFrame(Buffer.from("x"), 1n, Buffer.alloc(16)), (e: E2ECryptoError) => e.reason === "invalidKey");
  assert.throws(() => publicKey(Buffer.alloc(31)), (e: E2ECryptoError) => e.reason === "invalidKey");
  assert.throws(
    () => sharedSecret(Buffer.alloc(32), hex(keys.bridgePub).subarray(0, 16)),
    (e: E2ECryptoError) => e.reason === "invalidKey",
  );
});

test("version 引数: 0x03 のフレームは v3 の受け側だけが開け、v1 の受け側は復号せずに拒否する", () => {
  const key = crypto.randomBytes(32);
  const v3 = new E2EFrameSender(key, 0x03).seal(Buffer.from("hi"));
  assert.equal(v3[0], 0x03);
  assert.throws(() => new E2EFrameReceiver(key).open(v3), (e: E2ECryptoError) => e.reason === "invalidFrame");
  assert.deepEqual(new E2EFrameReceiver(key, 0x03).open(v3), Buffer.from("hi"));
  // v3 の受け側に v1 のフレーム（先頭 0x01）
  const v1 = new E2EFrameSender(key).seal(Buffer.from("hi"));
  assert.throws(() => new E2EFrameReceiver(key, 0x03).open(v1), (e: E2ECryptoError) => e.reason === "invalidFrame");
  // seq 0・長すぎるフレームは復号せずに拒否
  assert.throws(() => new E2EFrameReceiver(key).open(encodeFrame(Buffer.from("x"), 0n, key)), (e: E2ECryptoError) => e.reason === "sequenceViolation");
  assert.throws(() => decodeFrame(Buffer.alloc(16 * 1024 * 1024 + 27), key), (e: E2ECryptoError) => e.reason === "invalidFrame");
});
