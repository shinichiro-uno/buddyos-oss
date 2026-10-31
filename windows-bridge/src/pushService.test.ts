import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import type net from "node:net";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

import { DeviceStore } from "./deviceStore.js";
import { derivePushKey, openPush, publicKey, sealPush } from "./e2e.js";
import { MAX_BODY_SCALARS, MAX_TITLE_SCALARS, pairRequestText, PushService, pushPlaintext } from "./pushService.js";
import { credentialHash, deviceKeyId, newCredential } from "./tunnelV3.js";

test("長い承認要求の本文でも、封をした e2e.c が Convex の上限（base64 で 4096 文字）に収まる", () => {
  const payload = { kind: "approval_request", agentId: "claude", sessionId: "s".repeat(36), requestId: "r".repeat(36), bridgeId: "b".repeat(70) };
  // JSON で 6 バイトに膨らむ制御文字と、4 バイトの絵文字（JS ではサロゲートの組）で最悪に近い形にする。
  const plaintext = pushPlaintext("😀".repeat(500), "\u0001".repeat(5000), payload);
  const sealed = sealPush(plaintext, Buffer.alloc(32, 7));
  assert.ok(sealed.ciphertext.toString("base64").length <= 4096);
  const obj = JSON.parse(plaintext.toString("utf8")) as { title: string; body: string; payload: unknown };
  assert.equal(Array.from(obj.title).length, MAX_TITLE_SCALARS);
  assert.equal(Array.from(obj.body).length, MAX_BODY_SCALARS);
  assert.deepEqual(obj.payload, payload);
});

test("pair_request（spec/PROTOCOL-v3.md §10.4.1）: 許可できる端末（ios・android）の宛先にだけ、端末ごとの鍵で封をして 1 回送る。平文は送らない", async () => {
  const bodies: Array<Record<string, unknown>> = [];
  const relay = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      bodies.push(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      res.writeHead(200, { "content-type": "application/json" });
      res.end("{}");
    });
  });
  await new Promise<void>((r) => relay.listen(0, "127.0.0.1", () => r()));
  const port = (relay.address() as net.AddressInfo).port;
  const store = DeviceStore.createFresh(fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-push-")), "migration_v3", { log: () => {} });
  const bridgePriv = crypto.randomBytes(32);
  const add = (platform: string, locale: string | undefined, push: boolean) => {
    const devicePriv = crypto.randomBytes(32);
    const pub = publicKey(devicePriv);
    const id = deviceKeyId(pub);
    const credential = newCredential();
    const clientDeviceId = `device-${platform}-${crypto.randomBytes(3).toString("hex")}`;
    store.putPending(id, { pub: pub.toString("base64url"), clientDeviceId, name: platform, label: null, platform, credHash: credentialHash(credential), via: "qr", createdAt: Date.now() });
    store.confirm(id, credentialHash(credential));
    const token = crypto.randomBytes(32).toString("hex");
    if (push) store.setPush(id, token, "production", locale);
    return { id, pub, clientDeviceId, token };
  };
  const iphone = add("ios", "en", true);
  const android = add("android", "ja", true);
  add("mac", "ja", true);
  add("ios", "ja", false);

  process.env.BUDDYOS_PUSH_RELAY_URL = `http://127.0.0.1:${port}/push`;
  process.env.BUDDYOS_PUSH_RELAY_TOKEN = "relay-token";
  try {
    const push = new PushService({ bridgeId: () => "windows-bridge-push", privateKey: () => bridgePriv, devices: store });
    await push.sendPairRequest("p_abc", "MacBook Air · AB12", "Office PC");
  } finally {
    delete process.env.BUDDYOS_PUSH_RELAY_URL;
    delete process.env.BUDDYOS_PUSH_RELAY_TOKEN;
    await new Promise((r) => relay.close(r));
  }
  assert.equal(bodies.length, 2, "PC と宛先の無い端末には送らない");
  const byToken = new Map(bodies.map((b) => [b.token as string, b]));
  for (const [target, locale] of [[iphone, "en"], [android, "ja"]] as const) {
    const body = byToken.get(target.token)!;
    assert.ok(body, "宛先ごとに 1 回");
    const text = JSON.stringify(body);
    assert.ok(!text.includes("MacBook Air") && !text.includes("p_abc") && !text.includes("pair_request"), "relay に平文を見せない");
    const e2e = body.e2e as { v: number; bid: string; n: string; c: string };
    assert.equal(e2e.bid, "windows-bridge-push");
    const key = derivePushKey(bridgePriv, target.pub, "windows-bridge-push", target.clientDeviceId);
    const plain = JSON.parse(openPush(Buffer.from(e2e.c, "base64"), Buffer.from(e2e.n, "base64"), key).toString("utf8"));
    const expected = pairRequestText(locale, "MacBook Air · AB12", "Office PC");
    assert.deepEqual(plain, { title: expected.title, body: expected.body, payload: { kind: "pair_request", pendingId: "p_abc" } });
  }
  assert.match(pairRequestText("ja", "A", "B").body, /^この PC（B）につなごうとしています。/);
  assert.match(pairRequestText("en", "A", "B").body, /6-digit code/);
});

test("Live Activity: /v3/live-activity-targets と /v3/live-activity の要求の形（認証は端末トークン、宛先は SHA-256 だけ）", async () => {
  const seen: Array<{ url: string; auth: string | undefined; body: Record<string, unknown> }> = [];
  const relay = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      seen.push({ url: req.url ?? "", auth: req.headers.authorization, body: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
      if (req.url === "/v3/live-activity") {
        res.writeHead(429, { "content-type": "application/json", "retry-after": "42" });
        res.end('{"error":"rate_limited"}');
        return;
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end('{"ok":true,"count":1}');
    });
  });
  await new Promise<void>((r) => relay.listen(0, "127.0.0.1", () => r()));
  const base = `http://127.0.0.1:${(relay.address() as net.AddressInfo).port}`;
  try {
    const push = new PushService(undefined, {
      url: `${base}/v3/push`,
      token: () => "bdt_test",
      targetsUrl: `${base}/v3/push-targets`,
      liveActivityTargetsUrl: `${base}/v3/live-activity-targets`,
      liveActivityUrl: `${base}/v3/live-activity`
    });
    assert.equal(push.liveActivityAvailable, true);
    const token = "ab".repeat(32);
    const hash = crypto.createHash("sha256").update(token).digest("hex");
    const targets = await push.liveActivityTargets([
      { token: token.toUpperCase(), environment: "production" },
      { token, environment: "production" },
      { token: "cd".repeat(32), environment: "development" }
    ]);
    assert.equal(targets.status, 200);
    assert.deepEqual(seen[0].body, {
      targets: [
        { tokenHash: hash, env: "production" },
        { tokenHash: crypto.createHash("sha256").update("cd".repeat(32)).digest("hex"), env: "sandbox" }
      ]
    });
    assert.deepEqual([seen[0].url, seen[0].auth], ["/v3/live-activity-targets", "Bearer bdt_test"]);
    await push.liveActivityTargets([]);
    assert.deepEqual(seen[1].body, { targets: [] });

    const sent = await push.sendLiveActivity({
      environment: "production",
      token,
      event: "update",
      timestamp: 1792540805,
      state: { phase: "running", running: 3, failed: 0 },
      staleAfterSec: 1500
    });
    assert.deepEqual(seen[2].body, {
      environment: "production",
      token,
      event: "update",
      timestamp: 1792540805,
      state: { phase: "running", running: 3, failed: 0 },
      staleAfterSec: 1500
    });
    assert.deepEqual([seen[2].url, seen[2].auth], ["/v3/live-activity", "Bearer bdt_test"]);
    assert.deepEqual(sent, { status: 429, error: "rate_limited", sent: undefined, invalid: undefined, retryAfterSec: 42 });
  } finally {
    relay.close();
  }
});

test("Live Activity: 公開版（mode none）・端末トークンが無いときは使わず、何も送らない", async () => {
  const requests: string[] = [];
  const relay = http.createServer((req, res) => {
    requests.push(req.url ?? "");
    res.writeHead(200);
    res.end("{}");
  });
  await new Promise<void>((r) => relay.listen(0, "127.0.0.1", () => r()));
  const base = `http://127.0.0.1:${(relay.address() as net.AddressInfo).port}`;
  const defaults = (token: () => string | undefined) => ({
    url: `${base}/v3/push`,
    token,
    targetsUrl: `${base}/v3/push-targets`,
    liveActivityTargetsUrl: `${base}/v3/live-activity-targets`,
    liveActivityUrl: `${base}/v3/live-activity`
  });
  try {
    const none = new PushService(undefined, defaults(() => "bdt_x"), "none");
    assert.equal(none.liveActivityAvailable, false);
    assert.equal((await none.liveActivityTargets([])).status, 0);
    const noToken = new PushService(undefined, defaults(() => undefined));
    assert.equal(noToken.liveActivityAvailable, false);
    assert.equal((await noToken.sendLiveActivity({ environment: "sandbox", token: "ab".repeat(32), event: "end", timestamp: 1, state: { phase: "done", running: 0, failed: 0 } })).status, 0);
    assert.deepEqual(requests, []);
  } finally {
    relay.close();
  }
});
