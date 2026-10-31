import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { INVITE_TTL_MS, invitePairUrl, MAX_INVITES, PairingInvites } from "./pairingInvites.js";

// 招待（spec/PROTOCOL-v3.md §6・§10.3・§12）。
const here = path.dirname(fileURLToPath(import.meta.url));
const shared = JSON.parse(fs.readFileSync(path.join(here, "..", "..", "shared", "e2e-test-vectors.json"), "utf8"));
const tv = shared.tunnelV3;
const pv = shared.pairingV3;
assert.ok(tv && pv, "shared/e2e-test-vectors.json に tunnelV3 / pairingV3 が無い");

test("招待の ID・psk は PROTOCOL-v3 §18 のベクタどおりで、QR の URL は qrUrl と完全に一致する（platform は windows）", () => {
  const now = Number(pv.qrUrl.fields.exp) * 1000 - INVITE_TTL_MS;
  const invites = new PairingInvites({ now: () => now });
  const invite = invites.create(Buffer.from(tv.pair.inviteSecret, "hex"));
  assert.equal(invite.id, tv.pair.inviteId);
  assert.equal(invite.psk.toString("hex"), tv.pair.psk);
  const url = invitePairUrl(invite, {
    bridgeId: pv.qrUrl.fields.bridgeId,
    name: pv.qrUrl.fields.name,
    relayURL: pv.qrUrl.fields.relay,
    relayId: pv.qrUrl.fields.relayId,
    bridgePub: Buffer.from(pv.qrUrl.fields.key, "base64url")
  });
  assert.equal(url, pv.qrUrl.url.replace("platform=mac", "platform=windows"));
  assert.ok(!url.includes("apiKey"));
});

test("10 分で切れ、同時に 3 つまで（4 つ目で一番古いものを捨てる）", () => {
  let now = 1_000_000;
  const invites = new PairingInvites({ now: () => now });
  const first = invites.create();
  for (let i = 0; i < MAX_INVITES; i++) {
    now += 1;
    invites.create();
  }
  assert.equal(invites.size, MAX_INVITES);
  assert.equal(invites.find(first.id), undefined);
  const latest = invites.create();
  now += INVITE_TTL_MS;
  assert.equal(invites.find(latest.id), undefined);
});

test("PROTOCOL-v3 §18.2: 使われた招待は、その端末のやり直しにだけ使える。失敗の回数では消えない", () => {
  const invites = new PairingInvites();
  const invite = invites.create();
  assert.ok(invites.usableBy(invite.id, "device-A"));
  invites.markUsed(invite, "device-A", "iPhone · 815W");
  assert.equal(invites.usableBy(invite.id, "device-B"), undefined);
  assert.ok(invites.usableBy(invite.id, "device-A"));
  assert.deepEqual(invites.views()[0].usedBy, { display: "iPhone · 815W", at: invite.usedBy!.at });
  assert.equal(invites.remove(invite.id), true);
  assert.equal(invites.remove(invite.id), false);
});
