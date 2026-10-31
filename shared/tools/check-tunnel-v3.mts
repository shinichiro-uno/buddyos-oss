// shared/e2e-test-vectors.json の tunnelV3・pairingV3 を、付録 A・A.2 の参照実装（tunnelV3Ref.mts）で確かめる。
// ベクタを作り直すのではなく、一致を確かめるだけ。違えば 0 以外で終わる。
//   node shared/tools/check-tunnel-v3.mts
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  PROLOGUE, b64u, initiatorWrite1, initiatorRead2, responderRead1, responderWrite2,
  inviteId, invitePsk, deviceKeyId, sasCommit, sasCode, credentialHash, sealFrameV3, openFrameV3,
  b64uDecodeStrict, sanitizeName, displayName, qrEncode, parseQuery, buildPairUrl, normalizeCode, sasDisplay, QR_KEYS,
} from "./tunnelV3Ref.mts";

const here = path.dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(fs.readFileSync(path.join(here, "..", "e2e-test-vectors.json"), "utf8"));
const keys = vectors.keys;
const tv = vectors.tunnelV3;
const pv = vectors.pairingV3;

let failures = 0;
let checks = 0;
function eq(label: string, actual: unknown, expected: unknown): void {
  checks += 1;
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    failures += 1;
    console.error(`NG ${label}\n   actual:   ${a}\n   expected: ${e}`);
  }
}
const hex = (b: Buffer): string => b.toString("hex");
const fromHex = (s: string): Buffer => Buffer.from(s, "hex");
const fromB64u = (s: string): Buffer => Buffer.from(s, "base64url");

const bridgePriv = fromHex(keys.bridgePriv);
const bridgePub = fromHex(keys.bridgePub);
const devicePriv = fromHex(keys.devicePriv);
const devicePub = fromHex(keys.devicePub);
const eI = fromHex(tv.deviceEphemeralPriv);
const eR = fromHex(tv.bridgeEphemeralPriv);

eq("protocolName", tv.protocolName, "Noise_IKpsk2_25519_ChaChaPoly_SHA256");
eq("prologue", tv.prologue, PROLOGUE.toString("ascii"));
eq("deviceKeyId", deviceKeyId(devicePub), tv.deviceKeyId);

for (const mode of ["connect", "pair", "approve"] as const) {
  const m = tv[mode];
  const psk = fromHex(m.psk);
  const ini = { prologue: PROLOGUE, sI: devicePriv, eI, sRpub: bridgePub, psk };
  const w1 = initiatorWrite1(ini, Buffer.from(m.payload1, "utf8"));
  eq(`${mode}.init.e`, b64u(w1.ePub), m.init.e);
  eq(`${mode}.init.s`, b64u(w1.sPubCt), m.init.s);
  eq(`${mode}.init.p`, b64u(w1.payloadCt), m.init.p);

  const res = { prologue: PROLOGUE, sR: bridgePriv, eR };
  const r1 = responderRead1(res, fromB64u(m.init.e), fromB64u(m.init.s), fromB64u(m.init.p));
  eq(`${mode}.responder.devicePub`, hex(r1.sIpub), keys.devicePub);
  eq(`${mode}.responder.payload1`, r1.payload.toString("utf8"), m.payload1);
  const w2 = responderWrite2(res, r1.st, fromB64u(m.init.e), r1.sIpub, psk, Buffer.from(m.payload2, "utf8"));
  eq(`${mode}.hello.e`, b64u(w2.eRpub), m.hello.e);
  eq(`${mode}.hello.p`, b64u(w2.payloadCt), m.hello.p);
  eq(`${mode}.responder.handshakeHash`, hex(w2.handshakeHash), m.handshakeHash);
  eq(`${mode}.responder.kC2S`, hex(w2.c2s), m.kC2S);
  eq(`${mode}.responder.kS2C`, hex(w2.s2c), m.kS2C);

  const r2 = initiatorRead2(ini, w1.st, fromB64u(m.hello.e), fromB64u(m.hello.p));
  eq(`${mode}.initiator.payload2`, r2.payload.toString("utf8"), m.payload2);
  eq(`${mode}.initiator.handshakeHash`, hex(r2.handshakeHash), m.handshakeHash);
  eq(`${mode}.initiator.kC2S`, hex(r2.c2s), m.kC2S);
  eq(`${mode}.initiator.kS2C`, hex(r2.s2c), m.kS2C);

  const expected = { c2s: 1n, s2c: 1n };
  for (const f of m.frames) {
    const key = f.direction === "c2s" ? r2.c2s : r2.s2c;
    eq(`${mode}.frame.${f.direction}.${f.seq}`, hex(sealFrameV3(key, BigInt(f.seq), Buffer.from(f.plaintext, "utf8"))), f.frame);
    const dir = f.direction as "c2s" | "s2c";
    const opened = openFrameV3(key, fromHex(f.frame), expected[dir]);
    expected[dir] += 1n;
    eq(`${mode}.open.${f.direction}.${f.seq}`, opened.pt.toString("utf8"), f.plaintext);
  }
}

// pair: 招待の ID・psk・資格情報の hash。psk を知らない端末は hello.p を開けない（§7.3 の 1）。
const secret = fromHex(tv.pair.inviteSecret);
eq("pair.inviteSecretB64u", b64u(secret), tv.pair.inviteSecretB64u);
eq("pair.inviteId", inviteId(secret), tv.pair.inviteId);
eq("pair.psk", hex(invitePsk(secret)), tv.pair.psk);
eq("pair.credentialHash", credentialHash(tv.pair.credential), tv.pair.credentialHash);
{
  const ini = { prologue: PROLOGUE, sI: devicePriv, eI, sRpub: bridgePub, psk: Buffer.alloc(32) };
  const w1 = initiatorWrite1(ini, Buffer.from(tv.pair.payload1, "utf8"));
  let opened = true;
  try { initiatorRead2(ini, w1.st, fromB64u(tv.pair.hello.e), fromB64u(tv.pair.hello.p)); } catch { opened = false; }
  eq("pair.negative (zero psk cannot open hello)", opened, false);
}

// approve: コミットと確認コード。
eq("approve.commit", hex(sasCommit(fromHex(tv.approve.nR))), tv.approve.commit);
eq("approve.payload2.commit", JSON.parse(tv.approve.payload2).commit, b64u(sasCommit(fromHex(tv.approve.nR))));
eq("approve.sas", sasCode(fromHex(tv.approve.handshakeHash), fromHex(tv.approve.nI), fromHex(tv.approve.nR)), tv.approve.sas);

// §7.3 の 7・9・10（フレームの受け側）。
{
  const k = fromHex(tv.connect.kC2S);
  const good = fromHex(tv.connect.frames[0].frame);
  const rejects = (label: string, frame: Buffer, seq: bigint): void => {
    let ok = true;
    try { openFrameV3(k, frame, seq); } catch { ok = false; }
    eq(label, ok, false);
  };
  const v1 = Buffer.from(good); v1[0] = 0x01; rejects("frame version 0x01", v1, 1n);
  const fl = Buffer.from(good); fl[1] = 0x01; rejects("frame flags 0x01", fl, 1n);
  rejects("frame seq 2 first", fromHex(tv.connect.frames[1].frame), 1n);
  rejects("frame length 25", good.subarray(0, 25), 1n);
}

// §7.2（pairingV3）
for (const c of pv.nameSanitize.cases) eq(`nameSanitize ${JSON.stringify(c.in)}`, sanitizeName(c.in, pv.nameSanitize.deviceFallback), c.out);
for (const d of pv.displayName) eq(`displayName ${d.name}`, displayName(d.name, d.deviceKeyId), d.display);
for (const b of pv.b64u) {
  const out = b64uDecodeStrict(b.in);
  eq(`b64u ${JSON.stringify(b.in)}`, out === null ? null : out.toString("hex"), b.hex);
}
eq("qrName", qrEncode(pv.qrName.in), pv.qrName.encoded);
eq("qrUrl.build", buildPairUrl(pv.qrUrl.fields), pv.qrUrl.url);
{
  const q = parseQuery(pv.qrUrl.url.slice(pv.qrUrl.url.indexOf("?") + 1));
  eq("qrUrl.parse", q ? Object.fromEntries(QR_KEYS.map((k) => [k, q.get(k)])) : null, pv.qrUrl.fields);
  const plus = parseQuery(pv.qrUrl.plusIsLiteral.url.slice(pv.qrUrl.plusIsLiteral.url.indexOf("?") + 1));
  eq("qrUrl.plusIsLiteral", plus?.get("name") ?? null, pv.qrUrl.plusIsLiteral.name);
}
eq("qrUrl.fields.key", pv.qrUrl.fields.key, b64u(bridgePub));
eq("qrUrl.fields.secret", pv.qrUrl.fields.secret, tv.pair.inviteSecretB64u);
eq("sasDisplay", sasDisplay(pv.sasDisplay.code), pv.sasDisplay.display);
for (const c of pv.codeInput) eq(`codeInput ${JSON.stringify(c.in)}`, normalizeCode(c.in), c.normalized);

// 値の正本は文書の §7 の JSON。shared の tunnelV3・pairingV3 がそれと 1 文字も違わないこと
// （各実装のテストは shared だけを読み、写しを持たないので、ここで文書とのずれを止める）。
{
  const docPath = path.join(here, "..", "..", "docs", "DEVICE_AUTH_REDESIGN_2026-10-12.md");
  if (fs.existsSync(docPath)) {
    const doc = fs.readFileSync(docPath, "utf8");
    const jsonAfter = (heading: string): unknown => {
      const at = doc.indexOf(heading);
      if (at < 0) return undefined;
      const start = doc.indexOf("```json", at);
      const end = doc.indexOf("```", start + 7);
      return JSON.parse(doc.slice(start + 7, end));
    };
    eq("docs §7.1 tunnelV3 == shared", tv, jsonAfter("### 7.1 `tunnelV3`"));
    eq("docs §7.2 pairingV3 == shared", pv, jsonAfter("### 7.2 `pairingV3`"));
  }
}

if (failures > 0) {
  console.error(`check-tunnel-v3: ${failures} / ${checks} checks failed`);
  process.exit(1);
}
console.log(`check-tunnel-v3: all ${checks} checks passed`);
