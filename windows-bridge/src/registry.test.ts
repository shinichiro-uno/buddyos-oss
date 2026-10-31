import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { ApprovalQueue } from "./approvalQueue.js";
import { BridgeIdentity } from "./identity.js";
import { handleLocalRoute, type LocalRoutesContext } from "./localRoutes.js";
import { PairingInvites } from "./pairingInvites.js";
import { BridgeRegistry } from "./registry.js";
import { readRegistered, readRegistryHold, readRegistryStatus } from "./registryFiles.js";

// 登録簿への v3 の自己登録（registry.ts。mac の BridgeServer.registerBridgeToRegistry の移植）。
// spec/PROTOCOL-v3.md §15.7・§15.4・§15.5。Convex は偽の fetch で置き換える。

const root = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-registry-"));
after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const SITE = "https://site.test";
const RELAY = "wss://relay.example.com/ws";
const quiet = { log: () => {} };

interface Call {
  path: string;
  auth: string | undefined;
  deviceHeader: string | undefined;
  body: Record<string, unknown>;
}
type Reply = { status: number; body?: unknown } | ((call: Call) => { status: number; body?: unknown });

/** 道ごとに返事を順に返す偽の fetch。足りなくなったら最後の返事を繰り返す。 */
function fakeConvex(replies: Record<string, Reply[]>) {
  const calls: Call[] = [];
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    const headers = new Headers(init?.headers);
    const call: Call = {
      path: url.pathname,
      auth: headers.get("authorization") ?? undefined,
      deviceHeader: headers.get("x-buddyos-device-token") ?? undefined,
      body: JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>
    };
    calls.push(call);
    const queue = replies[url.pathname];
    if (!queue?.length) return new Response('{"error":"not_found"}', { status: 404 });
    const next = queue.length > 1 ? queue.shift()! : queue[0];
    const r = typeof next === "function" ? next(call) : next;
    return new Response(r.body === undefined ? "" : JSON.stringify(r.body), { status: r.status });
  }) as typeof fetch;
  return { calls, fetchImpl, paths: () => calls.map((c) => c.path) };
}

let seq = 0;
function setup(replies: Record<string, Reply[]>, opts: { clerk?: string; deviceToken?: string } = {}) {
  const base = path.join(root, `case-${++seq}`);
  const dir = path.join(base, "cfg");
  const buddyosDir = path.join(base, "buddyos");
  fs.mkdirSync(buddyosDir, { recursive: true });
  if (opts.clerk !== undefined) fs.writeFileSync(path.join(buddyosDir, "clerk-access-token"), opts.clerk);
  const identity = BridgeIdentity.open(dir, { ...quiet, env: {}, homeDir: base });
  if (opts.deviceToken) fs.writeFileSync(path.join(dir, "device-token"), opts.deviceToken);
  const convex = fakeConvex(replies);
  let firstRegistered = 0;
  const registry = new BridgeRegistry({
    identity,
    relayURL: RELAY,
    machineName: () => "Test PC",
    onFirstRegistered: () => firstRegistered++,
    fetch: convex.fetchImpl,
    env: { BUDDYOS_CONVEX_SITE: SITE },
    buddyosDir,
    machineId: async () => "a".repeat(64),
    log: () => {}
  });
  return { dir, identity, registry, convex, firstRegistered: () => firstRegistered };
}

const token = (dir: string): string | undefined => {
  try {
    return fs.readFileSync(path.join(dir, "device-token"), "utf8").trim();
  } catch {
    return undefined;
  }
};

test("発行 → 登録: Clerk で bdt_ を作り、登録は bdt_ だけで v3 の本文を送る（apiKey・e2ePub・route は送らない）", async () => {
  const t = setup(
    {
      "/v3/device-token": [{ status: 200, body: { deviceToken: "bdt_first" } }],
      "/v3/bridges/register": [
        (c) => ({ status: 200, body: { ok: true, bridgeId: c.body.bridgeId } }),
        (c) => ({ status: 200, body: { ok: true, bridgeId: c.body.bridgeId, deviceToken: "bdt_rotated" } })
      ]
    },
    { clerk: "clerk_test\n" }
  );
  await t.registry.register();
  assert.deepEqual(t.convex.paths(), ["/v3/device-token", "/v3/bridges/register"]);
  const [mint, reg] = t.convex.calls;
  assert.equal(mint.auth, "Bearer clerk_test");
  assert.equal(mint.deviceHeader, undefined);
  assert.deepEqual(mint.body, { bridgeId: t.identity.bridgeId, machineName: "Test PC", platform: "windows", machineId: "a".repeat(64) });
  assert.equal(reg.auth, "Bearer bdt_first", "登録は端末トークンだけ（Clerk のトークンでは登録しない）");
  const pub = t.identity.bridgePub()!.toString("base64url");
  assert.deepEqual(reg.body, {
    v: 3,
    bridgeId: t.identity.bridgeId,
    machineName: "Test PC",
    platform: "windows",
    relayURL: RELAY,
    relayId: t.identity.relayId,
    bridgePub: pub,
    machineId: "a".repeat(64)
  });
  assert.equal(token(t.dir), "bdt_first");
  assert.deepEqual(readRegistered(t.dir), { bridgePub: pub, relayId: t.identity.relayId, relayURL: RELAY });
  const status = readRegistryStatus(t.dir)!;
  assert.equal(status.auth, "device");
  assert.equal(status.hasDeviceToken, true);
  assert.equal(status.lastError, undefined);
  assert.ok(status.lastSuccessAt && status.lastSuccessAt > 1e9 && status.lastSuccessAt < 1e11, "秒で書く");
  assert.equal(t.firstRegistered(), 1);

  // 2 回目は発行しない。値が同じなので keyRotation も付けない。同梱された新しいトークンは保存する。
  await t.registry.register();
  assert.deepEqual(t.convex.paths().slice(2), ["/v3/bridges/register"]);
  assert.equal(t.convex.calls[2].auth, "Bearer bdt_first");
  assert.equal(t.convex.calls[2].body.keyRotation, undefined);
  assert.equal(token(t.dir), "bdt_rotated");
  assert.equal(t.firstRegistered(), 1, "push の宛先の登録し直しは最初の 1 回だけ");
});

test("登録: サーバーが返した bridgeId に合わせる", async () => {
  const t = setup({ "/v3/bridges/register": [{ status: 200, body: { ok: true, bridgeId: "windows-bridge-server-side" } }] }, { deviceToken: "bdt_x" });
  await t.registry.register();
  assert.equal(t.identity.bridgeId, "windows-bridge-server-side");
  assert.equal(fs.readFileSync(path.join(t.dir, "bridge-id"), "utf8").trim(), "windows-bridge-server-side");
});

test("登録: 作り直しで鍵・relayId が変わったら、前に登録できた値を keyRotation に付ける", async () => {
  const t = setup({ "/v3/bridges/register": [(c) => ({ status: 200, body: { ok: true, bridgeId: c.body.bridgeId } })] }, { deviceToken: "bdt_x" });
  await t.registry.register();
  const before = readRegistered(t.dir)!;
  t.identity.resetIdentity("user_reset");
  await t.registry.register();
  const body = t.convex.calls[1].body;
  assert.deepEqual(body.keyRotation, { prevBridgePub: before.bridgePub, prevRelayId: before.relayId });
  assert.notEqual(body.bridgePub, before.bridgePub);
  assert.equal(body.relayId, t.identity.relayId);
  // 登録できたら新しい値を覚え、次からは付けない。
  await t.registry.register();
  assert.equal(t.convex.calls[2].body.keyRotation, undefined);
});

test("発行: 409 already_registered は古い bridgeId を控え、bridgeId を作り直して 1 回だけ発行し直す", async () => {
  const t = setup(
    {
      "/v3/device-token": [{ status: 409, body: { error: "already_registered" } }, { status: 200, body: { deviceToken: "bdt_new" } }],
      "/v3/bridges/register": [(c) => ({ status: 200, body: { ok: true, bridgeId: c.body.bridgeId } })]
    },
    { clerk: "clerk_test" }
  );
  const old = t.identity.bridgeId;
  const version = t.identity.devices.version;
  await t.registry.register();
  assert.deepEqual(t.convex.paths(), ["/v3/device-token", "/v3/device-token", "/v3/bridges/register"]);
  assert.equal(t.convex.calls[0].body.bridgeId, old);
  assert.notEqual(t.identity.bridgeId, old);
  assert.match(t.identity.bridgeId, /^windows-bridge-/);
  assert.equal(t.convex.calls[1].body.bridgeId, t.identity.bridgeId);
  assert.equal(t.convex.calls[2].body.bridgeId, t.identity.bridgeId);
  assert.equal(readRegistryStatus(t.dir)?.registryPrevious?.bridgeId, old);
  assert.ok(t.identity.devices.version > version, "DevicesView の registryPrevious を出し直す");
  assert.equal(token(t.dir), "bdt_new");

  // 2 回続けて 409 なら、それ以上は試さない。
  const u = setup({ "/v3/device-token": [{ status: 409, body: { error: "already_registered" } }] }, { clerk: "clerk_test" });
  await u.registry.register();
  assert.deepEqual(u.convex.paths(), ["/v3/device-token", "/v3/device-token"]);
  assert.equal(readRegistryStatus(u.dir)?.lastError, "already_registered");
});

test("登録: 409 key_changed は bridgeId・端末トークン・登録した値を捨て、新しい PC として登録し直す", async () => {
  const t = setup(
    {
      "/v3/bridges/register": [(c) => ({ status: 200, body: { ok: true, bridgeId: c.body.bridgeId } }), { status: 409, body: { error: "key_changed" } }]
    },
    { deviceToken: "bdt_x" }
  );
  await t.registry.register();
  const old = t.identity.bridgeId;
  await t.registry.register();
  assert.notEqual(t.identity.bridgeId, old);
  assert.equal(token(t.dir), undefined);
  assert.equal(readRegistered(t.dir), undefined);
  const status = readRegistryStatus(t.dir)!;
  assert.equal(status.lastError, "key_changed");
  assert.equal(status.registryPrevious?.bridgeId, old);
});

test("403 revoked: registry-hold を置き、resume まで発行も登録もしない。resume で外して登録し直す", async () => {
  const t = setup(
    {
      "/v3/device-token": [{ status: 200, body: { deviceToken: "bdt_again" } }],
      "/v3/bridges/register": [{ status: 403, body: { error: "revoked" } }, (c) => ({ status: 200, body: { ok: true, bridgeId: c.body.bridgeId } })]
    },
    { deviceToken: "bdt_x", clerk: "clerk_test" }
  );
  const old = t.identity.bridgeId;
  const relayId = t.identity.relayId;
  await t.registry.register();
  assert.deepEqual(readRegistryHold(t.dir)?.reason, "revoked_by_account");
  assert.equal(token(t.dir), undefined);
  assert.notEqual(t.identity.bridgeId, old);
  assert.equal(t.identity.relayId, relayId, "端末の一覧と鍵は消さない（端末も切断するかはデスクトップで選ぶ）");
  assert.equal(readRegistryStatus(t.dir)?.lastError, "revoked");

  // hold の間は何度試しても通信しない。デスクトップが「端末も切断するか」を聞く手がかり（revoked）も上書きしない。
  await t.registry.register();
  await t.registry.heartbeat();
  assert.equal(t.convex.calls.length, 1);
  assert.equal(readRegistryStatus(t.dir)?.lastError, "revoked");

  // /local/registry/resume（管理鍵の確認は server.ts が済ませた後）。
  let requested = 0;
  const ctx: LocalRoutesContext = {
    identity: t.identity,
    invites: new PairingInvites(),
    approvals: new ApprovalQueue(),
    relayURL: RELAY,
    bridgeName: () => "Test PC",
    isOnline: () => false,
    forgetDevice: () => {},
    requestRegistration: () => {
      requested++;
      t.registry.requestSoon();
    }
  };
  const server = http.createServer((req, res) => void handleLocalRoute(req, res, new URL(req.url ?? "/", "http://127.0.0.1"), ctx));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const port = (server.address() as AddressInfo).port;
    const post = async (p: string, body = "{}") => {
      const r = await fetch(`http://127.0.0.1:${port}${p}`, { method: "POST", body, headers: { "content-type": "application/json" } });
      return { status: r.status, text: await r.text() };
    };
    const resumed = await post("/local/registry/resume");
    assert.equal(resumed.status, 200);
    assert.equal(requested, 1);
    assert.equal(readRegistryHold(t.dir), undefined);
    await waitFor(() => t.convex.calls.length >= 3);
    assert.deepEqual(t.convex.paths(), ["/v3/bridges/register", "/v3/device-token", "/v3/bridges/register"]);
    assert.equal(t.convex.calls[1].body.bridgeId, t.identity.bridgeId, "新しい bridgeId で発行し直す（失効した bridgeId は戻さない）");
    assert.equal(readRegistryStatus(t.dir)?.lastError, undefined);
  } finally {
    server.close();
  }
});

test("403 revoked（発行）: hold を置いて止まる。reset は hold の理由が revoked_by_account のときだけ revoked_by_account を受ける", async () => {
  const t = setup({ "/v3/device-token": [{ status: 403, body: { error: "revoked" } }] }, { clerk: "clerk_test" });
  await t.registry.register();
  assert.equal(readRegistryHold(t.dir)?.reason, "revoked_by_account");
  assert.deepEqual(t.convex.paths(), ["/v3/device-token"]);

  let requested = 0;
  const ctx: LocalRoutesContext = {
    identity: t.identity,
    invites: new PairingInvites(),
    approvals: new ApprovalQueue(),
    relayURL: RELAY,
    bridgeName: () => "Test PC",
    isOnline: () => false,
    forgetDevice: () => {},
    requestRegistration: () => requested++
  };
  const server = http.createServer((req, res) => void handleLocalRoute(req, res, new URL(req.url ?? "/", "http://127.0.0.1"), ctx));
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const port = (server.address() as AddressInfo).port;
    const bridgeId = t.identity.bridgeId;
    const r = await fetch(`http://127.0.0.1:${port}/local/devices/reset`, { method: "POST", body: '{"reason":"revoked_by_account"}' });
    assert.equal(r.status, 200);
    assert.equal(t.identity.devices.lastReset?.reason, "revoked_by_account");
    assert.equal(t.identity.bridgeId, bridgeId, "bridgeId は accountRevoked で作り直し済み");
    assert.equal(requested, 1);
    const view = await (await fetch(`http://127.0.0.1:${port}/local/devices`)).json();
    assert.equal((view as { registryPrevious: unknown }).registryPrevious, null);
  } finally {
    server.close();
  }
});

test("account_removed の作り直し: 端末トークン・登録した値を捨て、bridgeId を作り直し、hold を置く", async () => {
  const t = setup({ "/v3/bridges/register": [(c) => ({ status: 200, body: { ok: true, bridgeId: c.body.bridgeId } })] }, { deviceToken: "bdt_x" });
  await t.registry.register();
  const old = t.identity.bridgeId;
  t.identity.resetIdentity("account_removed");
  assert.notEqual(t.identity.bridgeId, old);
  assert.equal(token(t.dir), undefined);
  assert.equal(readRegistered(t.dir), undefined);
  assert.equal(readRegistryHold(t.dir)?.reason, "account_removed");
  await t.registry.register();
  assert.equal(t.convex.calls.length, 1);
  assert.equal(readRegistryStatus(t.dir)?.lastError, "hold");
});

test("401: 送ったトークンのときだけ消す（並走する Bridge が書き直した後なら残す）", async () => {
  const t = setup({ "/v3/bridges/register": [{ status: 401, body: { error: "unauthenticated" } }] }, { deviceToken: "bdt_dead" });
  await t.registry.register();
  assert.equal(token(t.dir), undefined);
  assert.equal(readRegistryStatus(t.dir)?.lastError, "device token rejected (401)");

  const u = setup(
    {
      "/v3/bridges/register": [
        () => {
          fs.writeFileSync(path.join(u.dir, "device-token"), "bdt_newer");
          return { status: 401, body: { error: "unauthenticated" } };
        }
      ]
    },
    { deviceToken: "bdt_old" }
  );
  await u.registry.register();
  assert.equal(token(u.dir), "bdt_newer");
});

test("サインインしていない・429・site の URL が壊れている: 投げずに理由を registry-status.json に書く", async () => {
  const t = setup({});
  await t.registry.register();
  assert.equal(t.convex.calls.length, 0);
  assert.equal(readRegistryStatus(t.dir)?.lastError, "signin-required");

  const u = setup({ "/v3/device-token": [{ status: 429, body: { error: "rate_limited" } }] }, { clerk: "clerk_test" });
  await u.registry.register();
  assert.equal(readRegistryStatus(u.dir)?.lastError, "rate_limited");

  // bdt_ は Clerk のトークンとして使わない
  const w = setup({}, { clerk: "bdt_not_clerk" });
  await w.registry.register();
  assert.equal(w.convex.calls.length, 0);
  assert.equal(readRegistryStatus(w.dir)?.lastError, "signin-required");

  const base = path.join(root, "badsite");
  const identity = BridgeIdentity.open(path.join(base, "cfg"), { ...quiet, env: {}, homeDir: base });
  fs.writeFileSync(path.join(identity.dir, "device-token"), "bdt_x");
  const reg = new BridgeRegistry({ identity, relayURL: RELAY, machineName: () => "PC", env: { BUDDYOS_CONVEX_SITE: "not a url" }, buddyosDir: base, machineId: async () => undefined, log: () => {} });
  await reg.register();
  const snap = readRegistryStatus(identity.dir);
  assert.equal(snap?.lastSuccessAt, undefined);
  assert.ok(snap?.lastError);
});

async function waitFor(cond: () => boolean, ms = 2000): Promise<void> {
  const until = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > until) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
}
