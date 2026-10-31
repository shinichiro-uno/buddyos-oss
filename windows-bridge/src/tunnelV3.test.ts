import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { E2ECryptoError, E2EFrameReceiver, E2EFrameSender, FRAME_VERSION_V3 } from "./e2e.js";
import {
  APPROVAL_WAITING_MESSAGE,
  approveRevealMessage,
  b64uDecodeStrict,
  buildPairUrl,
  constantTimeEquals,
  credentialHash,
  deviceKeyId,
  DEVICE_NAME_FALLBACK,
  displayName,
  initiatorRead2,
  initiatorWrite1,
  invitePsk,
  inviteId,
  normalizeCode,
  openFrameV3,
  parseControl,
  parseInitV3,
  parsePayload1,
  parseQuery,
  payload2Ok,
  PROLOGUE,
  qrEncode,
  responderRead1,
  responderWrite2,
  sanitizeName,
  sasCode,
  sasCommit,
  sealFrameV3,
  x25519Pub,
  ZERO_PSK
} from "./tunnelV3.js";

// spec/PROTOCOL-v3.md §18 のベクタ。正本の shared/e2e-test-vectors.json だけを読む（写しは持たない。
// mac-bridge・desktop・iOS・Android・convex のテストも同じファイルを読む）。
const here = path.dirname(fileURLToPath(import.meta.url));
const shared = JSON.parse(fs.readFileSync(path.join(here, "..", "..", "shared", "e2e-test-vectors.json"), "utf8"));
const tv = shared.tunnelV3;
const pv = shared.pairingV3;
assert.ok(tv && pv, "shared/e2e-test-vectors.json に tunnelV3 / pairingV3 が無い");
const keys = shared.keys;
const hex = (s: string) => Buffer.from(s, "hex");
const b64 = (s: string) => Buffer.from(s, "base64url");

type ModeName = "connect" | "pair" | "approve";

function pskOf(mode: ModeName): Buffer {
  return hex(tv[mode].psk);
}

function runInitiator(mode: ModeName, psk = pskOf(mode)) {
  const inp = { prologue: PROLOGUE, sI: hex(keys.devicePriv), eI: hex(tv.deviceEphemeralPriv), sRpub: hex(keys.bridgePub), psk };
  const m1 = initiatorWrite1(inp, Buffer.from(tv[mode].payload1, "utf8"));
  return { inp, m1 };
}

for (const mode of ["connect", "pair", "approve"] as const) {
  test(`tunnelV3 ${mode}: 固定の一時鍵で init / hello / handshakeHash / 鍵 / フレームがベクタと一致する`, () => {
    const v = tv[mode];
    const { inp, m1 } = runInitiator(mode);
    assert.equal(m1.ePub.toString("base64url"), v.init.e);
    assert.equal(m1.sPubCt.toString("base64url"), v.init.s);
    assert.equal(m1.payloadCt.toString("base64url"), v.init.p);

    // Bridge（responder）が init を読むと payload1 と端末の公開鍵が出る（PROTOCOL-v3 §18 ②）
    const res = { prologue: PROLOGUE, sR: hex(keys.bridgePriv), eR: hex(tv.bridgeEphemeralPriv) };
    const r1 = responderRead1(res, b64(v.init.e), b64(v.init.s), b64(v.init.p));
    assert.equal(r1.payload.toString("utf8"), v.payload1);
    assert.equal(r1.sIpub.toString("hex"), keys.devicePub);
    assert.equal(deviceKeyId(r1.sIpub), tv.deviceKeyId);
    const w2 = responderWrite2(res, r1.st, b64(v.init.e), r1.sIpub, pskOf(mode), Buffer.from(v.payload2, "utf8"));
    assert.equal(w2.eRpub.toString("base64url"), v.hello.e);
    assert.equal(w2.payloadCt.toString("base64url"), v.hello.p);
    assert.equal(w2.handshakeHash.toString("hex"), v.handshakeHash);
    assert.equal(w2.c2s.toString("hex"), v.kC2S);
    assert.equal(w2.s2c.toString("hex"), v.kS2C);

    // 端末（initiator）が hello を読むと payload2 が出る（PROTOCOL-v3 §18 ③）
    const i2 = initiatorRead2(inp, m1.st, b64(v.hello.e), b64(v.hello.p));
    assert.equal(i2.payload.toString("utf8"), v.payload2);
    assert.equal(i2.handshakeHash.toString("hex"), v.handshakeHash);

    // v3 のフレーム（参照実装と e2e.ts の version=0x03 の両方で）
    const seqs = { c2s: 1n, s2c: 1n };
    const senders = { c2s: new E2EFrameSender(w2.c2s, FRAME_VERSION_V3), s2c: new E2EFrameSender(w2.s2c, FRAME_VERSION_V3) };
    const receivers = { c2s: new E2EFrameReceiver(w2.c2s, FRAME_VERSION_V3), s2c: new E2EFrameReceiver(w2.s2c, FRAME_VERSION_V3) };
    for (const f of v.frames as Array<{ direction: "c2s" | "s2c"; seq: number; plaintext: string; frame: string }>) {
      const key = f.direction === "c2s" ? w2.c2s : w2.s2c;
      assert.equal(sealFrameV3(key, BigInt(f.seq), Buffer.from(f.plaintext, "utf8")).toString("hex"), f.frame);
      assert.equal(senders[f.direction].seal(Buffer.from(f.plaintext, "utf8")).toString("hex"), f.frame);
      assert.equal(openFrameV3(key, hex(f.frame), seqs[f.direction]).pt.toString("utf8"), f.plaintext);
      assert.equal(receivers[f.direction].open(hex(f.frame)).toString("utf8"), f.plaintext);
      seqs[f.direction] += 1n;
    }
  });
}

test("tunnelV3: inviteId / psk / credentialHash / commit / sas がベクタと一致する", () => {
  const secret = hex(tv.pair.inviteSecret);
  assert.equal(secret.toString("base64url"), tv.pair.inviteSecretB64u);
  assert.equal(inviteId(secret), tv.pair.inviteId);
  assert.equal(invitePsk(secret).toString("hex"), tv.pair.psk);
  assert.equal(credentialHash(tv.pair.credential), tv.pair.credentialHash);
  assert.equal(sasCommit(hex(tv.approve.nR)).toString("hex"), tv.approve.commit);
  assert.equal(sasCode(hex(tv.approve.handshakeHash), hex(tv.approve.nI), hex(tv.approve.nR)), tv.approve.sas);
  assert.equal(x25519Pub(hex(keys.bridgePriv)).toString("hex"), keys.bridgePub);
});

test("tunnelV3: payload2（commit 付き）と approve_reveal の平文がベクタと一致する。approval_waiting の形", () => {
  const p2 = JSON.parse(tv.approve.payload2) as { bridgeId: string; name: string; platform: "mac"; deviceKeyId: string };
  const fields = { bridgeId: p2.bridgeId, name: p2.name, platform: p2.platform, deviceKeyId: p2.deviceKeyId };
  assert.equal(payload2Ok({ ...fields, commit: hex(tv.approve.commit) }).toString("utf8"), tv.approve.payload2);
  assert.equal(payload2Ok(fields).toString("utf8"), tv.pair.payload2);
  const reveal = tv.approve.frames.find((f: { plaintext: string }) => f.plaintext.includes("approve_reveal"));
  assert.equal(approveRevealMessage(hex(tv.approve.nR)).toString("utf8"), reveal.plaintext);
  assert.deepEqual(JSON.parse(APPROVAL_WAITING_MESSAGE.toString("utf8")), { type: "approval_waiting" });
  assert.equal(constantTimeEquals("213854", "213854"), true);
  assert.equal(constantTimeEquals("213854", "213855"), false);
  assert.equal(constantTimeEquals("213854", "21385"), false);
});

test("PROTOCOL-v3 §18.2: pair の hello を psk を 0 埋めにした initiator で読むと復号に失敗する", () => {
  const { inp, m1 } = runInitiator("pair", ZERO_PSK);
  assert.throws(() => initiatorRead2(inp, m1.st, b64(tv.pair.hello.e), b64(tv.pair.hello.p)));
});

test("PROTOCOL-v3 §18.2: init の s・p の改竄、別の静的鍵の responder は復号に失敗する", () => {
  const v = tv.connect;
  const res = { prologue: PROLOGUE, sR: hex(keys.bridgePriv), eR: hex(tv.bridgeEphemeralPriv) };
  const flip = (s: string) => {
    const b = b64(s);
    b[0] ^= 0x01;
    return b;
  };
  assert.throws(() => responderRead1(res, b64(v.init.e), flip(v.init.s), b64(v.init.p)));
  assert.throws(() => responderRead1(res, b64(v.init.e), b64(v.init.s), flip(v.init.p)));
  const other = { ...res, sR: hex(keys.devicePriv) };
  assert.throws(() => responderRead1(other, b64(v.init.e), b64(v.init.s), b64(v.init.p)));
});

test("PROTOCOL-v3 §18.2: init.e が 0 の公開鍵なら DH の失敗", () => {
  const v = tv.connect;
  const res = { prologue: PROLOGUE, sR: hex(keys.bridgePriv), eR: hex(tv.bridgeEphemeralPriv) };
  // OpenSSL が低位点を先に断る版もあるので、どちらの失敗でもよい（dh() は全 0 も自分で確かめる）
  assert.throws(() => responderRead1(res, Buffer.alloc(32), b64(v.init.s), b64(v.init.p)));
});

test("PROTOCOL-v3 §18.2: v3 の受け側は先頭 0x01・seq の飛び・flags 0x01・seq 0・25 バイトを復号せずに拒否する", () => {
  const key = hex(tv.connect.kC2S);
  const frame1 = hex(tv.connect.frames[0].frame);
  const v1 = Buffer.from(frame1);
  v1[0] = 0x01;
  assert.throws(() => new E2EFrameReceiver(key, FRAME_VERSION_V3).open(v1), (e: E2ECryptoError) => e.reason === "invalidFrame");
  assert.throws(() => new E2EFrameReceiver(key, FRAME_VERSION_V3).open(hex(tv.connect.frames[1].frame)), (e: E2ECryptoError) => e.reason === "sequenceViolation");
  const flags = Buffer.from(frame1);
  flags[1] = 0x01;
  assert.throws(() => new E2EFrameReceiver(key, FRAME_VERSION_V3).open(flags), (e: E2ECryptoError) => e.reason === "invalidFrame");
  const seq0 = sealFrameV3(key, 0n, Buffer.from("x"));
  assert.throws(() => new E2EFrameReceiver(key, FRAME_VERSION_V3).open(seq0), (e: E2ECryptoError) => e.reason === "sequenceViolation");
  assert.throws(() => openFrameV3(key, seq0, 1n), /seq/);
  assert.throws(() => new E2EFrameReceiver(key, FRAME_VERSION_V3).open(Buffer.alloc(25)), (e: E2ECryptoError) => e.reason === "invalidFrame");
  assert.throws(() => openFrameV3(key, Buffer.alloc(25), 1n), /length/);
});

// ---- PROTOCOL-v3 §18 pairingV3 ----

test("pairingV3: b64u の厳しい読み方", () => {
  for (const c of pv.b64u as Array<{ in: string; hex: string | null }>) {
    const got = b64uDecodeStrict(c.in);
    assert.equal(got === null ? null : got.toString("hex"), c.hex, JSON.stringify(c.in));
  }
  assert.equal(b64uDecodeStrict(keys.bridgePub && Buffer.from(keys.bridgePub, "hex").toString("base64url"), 31), null);
});

test("pairingV3: 名前の無害化と表示名", () => {
  assert.equal(pv.nameSanitize.deviceFallback, DEVICE_NAME_FALLBACK);
  for (const c of pv.nameSanitize.cases as Array<{ in: string; out: string }>) {
    assert.equal(sanitizeName(c.in, pv.nameSanitize.deviceFallback), c.out, JSON.stringify(c.in));
  }
  assert.equal(sanitizeName("", pv.nameSanitize.bridgeFallback), "PC");
  for (const c of pv.displayName as Array<{ name: string; deviceKeyId: string; display: string }>) {
    assert.equal(displayName(c.name, c.deviceKeyId), c.display);
  }
});

test("pairingV3: QR の名前・URL の符号化と、+ を空白に戻さない読み方", () => {
  assert.equal(qrEncode(pv.qrName.in), pv.qrName.encoded);
  assert.equal(buildPairUrl(pv.qrUrl.fields), pv.qrUrl.url);
  assert.equal(pv.qrUrl.fields.key, Buffer.from(keys.bridgePub, "hex").toString("base64url"));
  assert.equal(pv.qrUrl.fields.secret, tv.pair.inviteSecretB64u);
  const parsed = parseQuery(pv.qrUrl.url.slice(pv.qrUrl.url.indexOf("?") + 1));
  assert.deepEqual(Object.fromEntries(parsed!), pv.qrUrl.fields);
  const plus = pv.qrUrl.plusIsLiteral;
  assert.equal(parseQuery(plus.url.slice(plus.url.indexOf("?") + 1))?.get("name"), plus.name);
  assert.equal(parseQuery("a=1&a=2"), null);
  assert.equal(parseQuery("a=%zz"), null);
});

test("pairingV3: 番号の入力の正規化", () => {
  for (const c of pv.codeInput as Array<{ in: string; normalized: string | null }>) {
    assert.equal(normalizeCode(c.in), c.normalized, c.in);
  }
});

// ---- メッセージの読み方 ----

test("msg1 の読み方: v なし・v2 は version、形の崩れは bad、init でない TEXT は読み捨て", () => {
  const init = tv.connect.init;
  const ok = parseInitV3(JSON.stringify(init));
  assert.equal(ok.kind, "ok");
  assert.equal(parseInitV3(JSON.stringify({ ...init, v: 2 })).kind, "version");
  assert.equal(parseInitV3(JSON.stringify({ type: "buddyos_tunnel_init", deviceId: "x", devicePub: "y", v: 2 })).kind, "version");
  const noV: Record<string, unknown> = { ...init };
  delete noV.v;
  assert.equal(parseInitV3(JSON.stringify(noV)).kind, "version");
  assert.equal(parseInitV3(JSON.stringify({ ...init, e: init.e + "=" })).kind, "bad");
  assert.equal(parseInitV3(JSON.stringify({ ...init, s: init.e })).kind, "bad");
  assert.equal(parseInitV3(JSON.stringify({ ...init, p: "AAAA" })).kind, "bad");
  assert.equal(parseInitV3(JSON.stringify({ type: "other" })).kind, "ignore");
  assert.equal(parseInitV3("not json").kind, "ignore");
  assert.equal(parseInitV3(JSON.stringify({ ...init, pad: "x".repeat(5000) })).kind, "bad");
});

test("payload1 の読み方", () => {
  const p = parsePayload1(Buffer.from(tv.pair.payload1, "utf8"));
  assert.equal(p.kind, "ok");
  if (p.kind === "ok") {
    assert.equal(p.payload.mode, "pair");
    assert.equal(p.payload.invite, tv.pair.inviteId);
    assert.equal(p.payload.name, "Test iPhone");
  }
  const connect = parsePayload1(Buffer.from(tv.connect.payload1, "utf8"));
  assert.equal(connect.kind === "ok" && connect.payload.name, undefined);
  const bad = (o: unknown) => parsePayload1(Buffer.from(JSON.stringify(o), "utf8"));
  assert.deepEqual(bad({ mode: "x", deviceId: "device-test-1", platform: "ios" }), { kind: "bad" });
  assert.equal(bad({ mode: "connect", deviceId: "short", platform: "ios" }).kind, "bad");
  assert.equal(bad({ mode: "connect", deviceId: "device-test-1", platform: "linux" }).kind, "bad");
  assert.equal(bad({ mode: "pair", deviceId: "device-test-1", platform: "ios", name: "x" }).kind, "bad");
  assert.equal(bad({ mode: "approve", deviceId: "device-test-1", platform: "ios" }).kind, "bad");
  const unnamed = bad({ mode: "approve", deviceId: "device-test-1", platform: "ios", name: "​" });
  assert.equal(unnamed.kind === "ok" && unnamed.payload.name, "端末");
  assert.equal(parsePayload1(Buffer.alloc(1025, 0x20)).kind, "bad");
});

test("制御メッセージの読み方: 知らない type・JSON でない・4096 バイト超は null", () => {
  assert.deepEqual(parseControl(Buffer.from('{"type":"open"}')), { type: "open" });
  assert.deepEqual(parseControl(Buffer.from('{"type":"paired_ack"}')), { type: "paired_ack" });
  assert.equal(parseControl(Buffer.from('{"type":"paired"}')), null);
  assert.equal(parseControl(Buffer.from("open")), null);
  assert.equal(parseControl(Buffer.from(JSON.stringify({ type: "open", pad: "x".repeat(4100) }))), null);
  assert.equal(parseControl(Buffer.from('{"type":"approve_nonce","n":"AAAA"}')), null);
});
