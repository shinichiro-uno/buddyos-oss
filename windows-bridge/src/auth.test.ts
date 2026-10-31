import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import type http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { WebSocket } from "ws";

// server.ts を起動するので、実ホームの設定・PATH 上の実 CLI に触れないようにしてから読み込む（server.test.ts と同じ）。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-auth-test-"));
const fakeHome = path.join(tmp, "home");
fs.mkdirSync(path.join(tmp, "bin"), { recursive: true });
fs.mkdirSync(fakeHome, { recursive: true });
process.env.HOME = fakeHome;
process.env.USERPROFILE = fakeHome;
process.env.PATH = path.join(tmp, "bin");
for (const key of ["BUDDYOS_PUSH_RELAY_URL", "BUDDYOS_PUSH_RELAY_TOKEN"]) delete process.env[key];

const { AdminKey, credentialOf, principalFor, readAdminKey, routeAccess, TunnelPeers } = await import("./auth.js");
const { BridgeIdentity } = await import("./identity.js");
const { createBridgeServer } = await import("./server.js");
const { JsonSessionStore } = await import("./sessionStore.js");
const { credentialHash, deviceKeyId, newCredential } = await import("./tunnelV3.js");
type BridgeServerT = import("./server.js").BridgeServer;
type BridgeIdentityT = import("./identity.js").BridgeIdentity;

// 端末認証 v3 の Principal とルートの表（spec/PROTOCOL-v3.md §13・Appendix A・§13.5・§18.2）。

const ADMIN = `bda_${crypto.randomBytes(32).toString("base64url")}`;
let bridge: BridgeServerT;
let identity: BridgeIdentityT;
let port = 0;

before(async () => {
  const configDir = path.join(tmp, "config");
  identity = BridgeIdentity.open(configDir, { env: { BUDDYOS_BRIDGE_ID: "windows-bridge-auth-test" }, homeDir: fakeHome, log: () => {} });
  bridge = createBridgeServer(
    {
      configDir,
      identity,
      bridgeId: "windows-bridge-auth-test",
      port: 0,
      paseoRelayURL: "wss://relay.example.com/ws",
      defaultCwd: tmp,
      hermesMode: "off",
      claudeMode: "off",
      codexMode: "off",
      openclawMode: "off",
      opencodeMode: "off",
      cursorMode: "off",
      grokMode: "off",
      antigravityMode: "off"
    },
    new JsonSessionStore(configDir)
  );
  await bridge.start();
  port = (bridge.server.address() as net.AddressInfo).port;
});

after(async () => {
  bridge.server.closeAllConnections();
  await new Promise((r) => bridge.server.close(r));
});

interface Resp {
  status: number;
  body: string;
}

/** 普通の（この PC の中からの）要求。 */
function request(p: string, opts: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<Resp> {
  return send(net.connect({ host: "127.0.0.1", port }), p, opts);
}

/** 生の TCP で HTTP/1.1 を 1 本送る。 */
function send(socket: net.Socket, p: string, opts: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<Resp> {
  return new Promise((resolve, reject) => {
    const body = opts.body ?? "";
    const headers = { host: `127.0.0.1:${port}`, connection: "close", "content-length": String(Buffer.byteLength(body)), ...opts.headers };
    const head = `${opts.method ?? "GET"} ${p} HTTP/1.1\r\n${Object.entries(headers).map(([k, v]) => `${k}: ${v}`).join("\r\n")}\r\n\r\n`;
    const chunks: Buffer[] = [];
    socket.on("data", (c: Buffer) => chunks.push(c));
    socket.on("error", reject);
    socket.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      const status = Number(/^HTTP\/1\.1 (\d{3})/.exec(text)?.[1] ?? 0);
      let payload = text.slice(text.indexOf("\r\n\r\n") + 4);
      if (/transfer-encoding: chunked/i.test(text.slice(0, text.indexOf("\r\n\r\n")))) {
        payload = payload.replace(/^[0-9a-f]+\r\n/, "").replace(/\r\n0\r\n\r\n$/, "");
      }
      resolve({ status, body: payload });
    });
    const write = () => socket.write(head + body);
    if (socket.connecting) socket.once("connect", write);
    else write();
  });
}

/** トンネルのふり: Bridge へつないだ TCP の送り元の番号を TunnelPeers に入れる（paseoRelay.ts と同じ）。 */
async function tunnelSocket(deviceKeyIdValue: string): Promise<net.Socket> {
  const socket = net.connect({ host: "127.0.0.1", port });
  await new Promise<void>((r) => socket.once("connect", () => r()));
  bridge.peers.add(socket.localPort!, { deviceKeyId: deviceKeyIdValue, connectionId: "test", close: () => socket.destroy() });
  socket.once("close", () => bridge.peers.remove(socket.localPort!, bridge.peers.get(socket.localPort!)!));
  return socket;
}

function addDevice(clientDeviceId = "device-test-1", platform = "ios"): { id: string; credential: string } {
  const pub = crypto.randomBytes(32);
  const id = deviceKeyId(pub);
  const credential = newCredential();
  identity.devices.putPending(id, {
    pub: pub.toString("base64url"),
    clientDeviceId,
    name: "iPhone",
    label: null,
    platform,
    credHash: credentialHash(credential),
    via: "qr",
    createdAt: Date.now()
  });
  identity.devices.confirm(id, credentialHash(credential));
  return { id, credential };
}

const local = () => ({ authorization: `Bearer ${identity.localKey()}` });
const admin = () => ({ ...local(), "x-buddyos-admin": ADMIN });

// ---- 純粋な関数 ----

test("ルートの表: 表に無いパスは undefined、/local/* は admin、/device/* は device", () => {
  assert.equal(routeAccess("/health", false), "any");
  assert.equal(routeAccess("/ws/agent/echo", true), "any");
  assert.equal(routeAccess("/ws/agent/echo", false), undefined);
  assert.equal(routeAccess("/terminal/pty", false), undefined);
  assert.equal(routeAccess("/traffic", false), "local");
  assert.equal(routeAccess("/claude/hook", false), "local");
  assert.equal(routeAccess("/terminal/panes/poll", false), "local");
  assert.equal(routeAccess("/terminal/pane-event", false), "local");
  assert.equal(routeAccess("/local/devices", false), "admin");
  assert.equal(routeAccess("/local/devices/abc/revoke", false), "admin");
  assert.equal(routeAccess("/local/unknown", false), undefined);
  assert.equal(routeAccess("/device/self", false), "device");
  assert.equal(routeAccess("/device/approvals", false), "device");
  assert.equal(routeAccess("/device/approvals/approve", false), "device");
  assert.equal(routeAccess("/device/approvals/p_abc/reject", false), "device");
  assert.equal(routeAccess("/device/approvals/p_abc", false), undefined);
  assert.equal(routeAccess("/local/devices/pending/p_abc/reject", false), "admin");
  assert.equal(routeAccess("/files/x", false), undefined);
  assert.equal(routeAccess("/livez", false), undefined);
});

test("PROTOCOL-v3 §18.2: 受けた番号が待ち受けの番号でない・送り元が 127.0.0.1 でない要求は Principal にしない", () => {
  const peers = new TunnelPeers();
  const ctx = { peers, devices: identity.devices, localKey: () => "k", admin: new AdminKey(), listenPort: () => 9000 };
  const fake = (remoteAddress: string, localPort: number) =>
    ({ socket: { remoteAddress, remotePort: 5555, localPort }, headers: { authorization: "Bearer k" } }) as unknown as http.IncomingMessage;
  const url = new URL("http://127.0.0.1/health");
  assert.deepEqual(principalFor(fake("127.0.0.1", 9000), url, ctx, { allowQuery: true }), { kind: "local" });
  assert.deepEqual(principalFor(fake("::ffff:127.0.0.1", 9000), url, ctx, { allowQuery: true }), { kind: "local" });
  assert.equal(principalFor(fake("127.0.0.1", 9001), url, ctx, { allowQuery: true }), null);
  assert.equal(principalFor(fake("::1", 9000), url, ctx, { allowQuery: true }), null);
  // トンネル経由（送り元の番号が表にある）なら、ローカル鍵は通らない
  peers.add(5555, { deviceKeyId: "x", connectionId: "c", close: () => {} });
  assert.equal(principalFor(fake("127.0.0.1", 9000), url, ctx, { allowQuery: true }), null);
});

test("資格情報の取り出し: ヘッダとクエリが違えば conflict、/preview・/local ではクエリを受け付けない", () => {
  const req = (authorization?: string) => ({ headers: authorization ? { authorization } : {} }) as unknown as http.IncomingMessage;
  assert.deepEqual(credentialOf(req("Bearer a"), new URL("http://x/?apiKey=a"), true), { value: "a", conflict: false, query: true });
  assert.equal(credentialOf(req("Bearer a"), new URL("http://x/?apiKey=b"), true).conflict, true);
  assert.equal(credentialOf(req(), new URL("http://x/?apiKey=a&apiKey=a"), true).conflict, true);
  assert.equal(credentialOf(req(), new URL("http://x/?apiKey=a"), false).conflict, true);
  assert.equal(credentialOf(req("Basic a"), new URL("http://x/"), true).conflict, true);
});

test("管理鍵: stdin の 1 行を読み、形が違う・TTY なら読まない。閉じたら知らせる", async () => {
  const { PassThrough } = await import("node:stream");
  const good = new PassThrough();
  let ended = false;
  const reading = readAdminKey(good, { onEnd: () => (ended = true) });
  good.write(`${JSON.stringify({ adminKey: ADMIN })}\n`);
  assert.equal(await reading, ADMIN);
  good.end();
  await new Promise((r) => setImmediate(r));
  assert.equal(ended, true);

  const bad = new PassThrough();
  const badReading = readAdminKey(bad);
  bad.write('{"adminKey":"bda_short"}\n');
  assert.equal(await badReading, undefined);

  const tty = Object.assign(new PassThrough(), { isTTY: true });
  assert.equal(await readAdminKey(tty), undefined);
  const silent = new PassThrough();
  assert.equal(await readAdminKey(silent, { timeoutMs: 30 }), undefined);
});

// ---- 本物の Bridge ----

test("PROTOCOL-v3 §18.2: 表に無いルートは 404、Authorization と ?apiKey= が違えば 401、/local/* は管理鍵が要る", async () => {
  assert.deepEqual(await request("/nope"), { status: 404, body: '{"error":"not_found"}' });
  assert.equal((await request("/files/a.png", { headers: local() })).status, 404);
  assert.equal((await request("/health", { headers: local() })).status, 200);
  assert.equal((await request(`/health?apiKey=${identity.localKey()}`)).status, 200);
  assert.equal((await request("/health?apiKey=other", { headers: local() })).status, 401);
  assert.deepEqual(await request("/health"), { status: 401, body: '{"error":"unauthorized"}' });

  // 管理鍵が無い Bridge では 403 admin_unavailable（デスクトップは「この Bridge は管理できない」案内を出す）
  assert.deepEqual(await request("/local/devices", { headers: admin() }), { status: 403, body: '{"error":"admin_unavailable"}' });
  bridge.admin.set(ADMIN);
  assert.equal((await request("/local/devices", { headers: admin() })).status, 200);
  assert.equal((await request("/local/devices", { headers: local() })).status, 401);
  assert.equal((await request("/local/devices", { headers: { ...local(), "x-buddyos-admin": `${ADMIN}x` } })).status, 401);
  assert.equal((await request(`/local/devices?apiKey=${identity.localKey()}`, { headers: { "x-buddyos-admin": ADMIN } })).status, 401);
  assert.equal((await request(`/local/devices?apiKey=${identity.localKey()}`, { headers: admin() })).status, 401);
  assert.deepEqual(await request("/local/devices", { headers: { ...admin(), origin: "buddyos-desktop://app" } }), { status: 403, body: '{"error":"forbidden"}' });
  assert.deepEqual(await request("/device/self", { headers: local() }), { status: 403, body: '{"error":"device_only"}' });
});

test("トンネル経由の要求は、その端末の bdc_ だけが通り、ローカル鍵・他の端末の bdc_ は 401。local_only のルートは 403", async () => {
  bridge.admin.set(ADMIN);
  const a = addDevice("device-aaaa-1");
  const b = addDevice("device-bbbb-2");
  const self = await send(await tunnelSocket(a.id), "/device/self", { headers: { authorization: `Bearer ${a.credential}` } });
  assert.equal(self.status, 200);
  assert.equal(JSON.parse(self.body).deviceKeyId, a.id);
  assert.equal((await send(await tunnelSocket(a.id), "/health", { headers: local() })).status, 401);
  assert.equal((await send(await tunnelSocket(a.id), "/health", { headers: { authorization: `Bearer ${b.credential}` } })).status, 401);
  assert.equal((await send(await tunnelSocket(a.id), `/health?apiKey=${a.credential}`)).status, 200);
  assert.deepEqual(await send(await tunnelSocket(a.id), "/traffic", { headers: { authorization: `Bearer ${a.credential}` } }), { status: 403, body: '{"error":"local_only"}' });
  assert.equal((await send(await tunnelSocket(a.id), "/local/devices", { headers: { authorization: `Bearer ${a.credential}`, "x-buddyos-admin": ADMIN } })).status, 403);
  // この PC の中から bdc_ は通らない
  assert.equal((await request("/health", { headers: { authorization: `Bearer ${a.credential}` } })).status, 401);
  // /health は auth-v3 を広告する
  const health = JSON.parse((await request("/health", { headers: local() })).body);
  assert.ok(health.features.includes("auth-v3"));
});

test("PROTOCOL-v3 §18.2・§13.5: /device/unpair の直後から 401 になり、1 秒後に行が消える（外した印は残さない）", async () => {
  const d = addDevice("device-unpair-1");
  const auth = { authorization: `Bearer ${d.credential}` };
  assert.deepEqual(await send(await tunnelSocket(d.id), "/device/unpair", { method: "POST", headers: auth }), { status: 200, body: '{"ok":true}' });
  assert.equal((await send(await tunnelSocket(d.id), "/device/self", { headers: auth })).status, 401);
  assert.equal(identity.devices.state(d.id), "unpairing");
  await new Promise((r) => setTimeout(r, 1200));
  assert.equal(identity.devices.get(d.id), undefined);
  assert.equal(identity.devices.isRevoked(d.id), false);
});

test("/local/*: 招待・一覧・名前・外す・承認の窓と設定・すべての端末を切断", async () => {
  bridge.admin.set(ADMIN);
  const post = (p: string, body = "{}") => request(p, { method: "POST", headers: { ...admin(), "content-type": "application/json" }, body });
  const created = await post("/local/pairing/invites");
  assert.equal(created.status, 201);
  const invite = JSON.parse(created.body) as { inviteId: string; url: string; expiresAt: number };
  assert.match(invite.url, /^buddyos:\/\/pair\?v=3&bridgeId=windows-bridge-auth-test&name=.+&platform=windows&relay=wss%3A%2F%2Frelay\.example\.com%2Fws&relayId=[A-Za-z0-9_-]{43}&key=[A-Za-z0-9_-]{43}&secret=[A-Za-z0-9_-]{43}&exp=\d+$/);
  assert.ok(!invite.url.includes(identity.localKey()));
  assert.ok(invite.expiresAt > Date.now());

  const view = JSON.parse((await request("/local/devices", { headers: admin() })).body);
  assert.equal(view.approvalsEnabled, true);
  assert.equal(view.approvalsOpenUntil, null);
  assert.equal(view.remoteApprovalsEnabled, true);
  assert.equal(typeof view.remoteApprovalsAvailable, "boolean");
  assert.deepEqual(view.pending, []);
  assert.ok(view.invites.some((i: { inviteId: string }) => i.inviteId === invite.inviteId));
  assert.ok(!JSON.stringify(view).match(/"\d{6}"/), "確認コードは載せない");
  assert.equal((await request(`/local/pairing/invites/${invite.inviteId}`, { method: "DELETE", headers: admin() })).status, 204);
  assert.equal((await request(`/local/pairing/invites/${invite.inviteId}`, { method: "DELETE", headers: admin() })).status, 404);

  // events: version か boot が違えばすぐ返る
  const quick = await request(`/local/devices/events?since=${view.version - 1}&boot=${view.bootId}`, { headers: admin() });
  assert.equal(quick.status, 200);

  const d = addDevice("device-local-1");
  const renamed = await post(`/local/devices/${d.id}/rename`, JSON.stringify({ name: "  仕事用​ " }));
  assert.deepEqual(JSON.parse(renamed.body), { ok: true, display: `仕事用 · ${d.id.slice(0, 4)}` });
  assert.equal((await post(`/local/devices/${d.id}/rename`, JSON.stringify({ name: "" }))).status, 200);
  assert.equal(identity.devices.get(d.id)?.label, null);
  assert.deepEqual(JSON.parse((await post(`/local/devices/${d.id}/revoke`)).body), { ok: true });
  assert.equal(identity.devices.isRevoked(d.id), true);
  assert.equal((await post(`/local/devices/${d.id}/revoke`)).status, 404);

  // 「端末を追加」の窓（mac と同じ。「アカウントで見つけた PC からの承認」が切れていれば 409 approvals_disabled）
  const opened = await post("/local/approvals/open");
  assert.equal(opened.status, 200);
  const until = JSON.parse(opened.body).until as number;
  assert.ok(until > Date.now());
  assert.equal(JSON.parse((await request("/local/devices", { headers: admin() })).body).approvalsOpenUntil, until);
  assert.equal((await post("/local/approvals/close")).status, 204);
  assert.equal(JSON.parse((await request("/local/devices", { headers: admin() })).body).approvalsOpenUntil, null);
  assert.deepEqual(await post("/local/devices/settings", '{"approvalsEnabled":false}'), { status: 200, body: '{"ok":true}' });
  assert.deepEqual(await post("/local/approvals/open"), { status: 409, body: '{"error":"approvals_disabled"}' });
  assert.equal(JSON.parse((await request("/local/devices", { headers: admin() })).body).approvalsEnabled, false);
  assert.equal((await post("/local/devices/settings", '{"approvalsEnabled":true}')).status, 200);
  assert.deepEqual(await post("/local/devices/settings", '{"other":1}'), { status: 400, body: '{"error":"bad_json"}' });
  assert.equal((await post(`/local/devices/pending/p_unknown/reject`)).status, 404);
  assert.deepEqual(await post("/local/devices/pending/approve", '{"code":"21385"}'), { status: 400, body: '{"error":"bad_code"}' });
  assert.deepEqual(await post("/local/devices/pending/approve", '{"code":"213 854"}'), { status: 404, body: '{"error":"no_pending"}' });
  assert.equal((await post("/local/registry/resume")).status, 200);

  addDevice("device-local-2");
  bridge.invites.create();
  const relayBefore = identity.relayId;
  const keyBefore = identity.localKey();
  assert.deepEqual(await post("/local/devices/reset", '{"reason":"revoked_by_account"}'), { status: 400, body: '{"error":"bad_reason"}' });
  const reset = await post("/local/devices/reset", '{"reason":"user_reset"}');
  assert.deepEqual(JSON.parse(reset.body), { ok: true, bridgeId: "windows-bridge-auth-test" });
  assert.notEqual(identity.relayId, relayBefore);
  assert.notEqual(identity.localKey(), keyBefore);
  assert.equal(identity.devices.confirmedIds().length, 0);
  assert.equal(bridge.invites.size, 0);
  // 古いローカル鍵は使えない（毎回いまの値を読む）
  assert.equal((await request("/health", { headers: { authorization: `Bearer ${keyBefore}` } })).status, 401);
  assert.equal((await request("/health", { headers: local() })).status, 200);
  const after = JSON.parse((await request("/local/devices", { headers: admin() })).body);
  assert.equal(after.lastReset.reason, "user_reset");
});

test("spec/PROTOCOL-v3.md §10.4.1: /device/approvals は許可できる端末だけ。番号の入力・拒否は PC と同じ承認待ちに効き、approvedBy が渡る", async () => {
  bridge.admin.set(ADMIN);
  const post = (p: string, body = "{}") => request(p, { method: "POST", headers: { ...admin(), "content-type": "application/json" }, body });
  const phone = addDevice("device-approve-1", "ios");
  const pc = addDevice("device-approve-2", "mac");
  const asPhone = async (p: string, method = "GET", body?: string) =>
    send(await tunnelSocket(phone.id), p, { method, headers: { authorization: `Bearer ${phone.credential}` }, body });
  const asPc = async (p: string, method = "GET", body?: string) =>
    send(await tunnelSocket(pc.id), p, { method, headers: { authorization: `Bearer ${pc.credential}` }, body });

  // 別の PC（デスクトップ）は許可できない。この PC の中からも使えない（/device/* はトンネルの bdc_ だけ）
  assert.deepEqual(await asPc("/device/approvals"), { status: 403, body: '{"error":"not_approver"}' });
  assert.deepEqual(await asPc("/device/approvals/approve", "POST", '{"code":"123456"}'), { status: 403, body: '{"error":"not_approver"}' });
  assert.equal((await request("/device/approvals", { headers: local() })).status, 403);
  assert.deepEqual(JSON.parse((await asPhone("/device/approvals")).body), { pending: [], enabled: true });
  assert.deepEqual(await asPhone("/device/approvals/approve", "POST", '{"code":"123456"}'), { status: 404, body: '{"error":"no_pending"}' });

  const approvedBy: Array<string | undefined> = [];
  const ended: string[] = [];
  const addPending = (deviceKeyId: string, code: string, remote: boolean) =>
    bridge.approvals.add({
      deviceKeyId,
      display: `MacBook Air · ${deviceKeyId.slice(0, 4)}`,
      name: "MacBook Air",
      platform: "mac",
      sameNameExists: false,
      remote,
      code,
      approve: async (by) => {
        approvedBy.push(by);
        return { kind: "ok", display: `MacBook Air · ${deviceKeyId.slice(0, 4)}` };
      },
      end: (reason) => ended.push(`${deviceKeyId}:${reason}`)
    })!;
  const a = addPending("requester-aaaa", "213854", true);
  const list = JSON.parse((await asPhone("/device/approvals")).body);
  assert.equal(list.enabled, true);
  assert.deepEqual(list.pending, [
    { pendingId: a.pendingId, display: a.display, platform: "mac", requestedAt: a.requestedAt, expiresAt: a.expiresAt, sameNameExists: false, remote: true }
  ]);
  assert.ok(!JSON.stringify(list).includes("213854"), "番号は入れない");
  // DevicesView にも remote の申し込みとして出る
  const view = JSON.parse((await request("/local/devices", { headers: admin() })).body);
  assert.deepEqual(view.pending.map((p: { pendingId: string; remote: boolean }) => [p.pendingId, p.remote]), [[a.pendingId, true]]);

  assert.deepEqual(await asPhone("/device/approvals/approve", "POST", '{"code":"12345"}'), { status: 400, body: '{"error":"bad_code"}' });
  assert.deepEqual(JSON.parse((await asPhone("/device/approvals/approve", "POST", '{"code":"999999"}')).body), { error: "code_mismatch", remaining: 2 });
  // PC での間違いも同じ数に入る
  assert.deepEqual(JSON.parse((await post("/local/devices/pending/approve", '{"code":"999998"}')).body), { error: "code_mismatch", remaining: 1 });
  const ok = await asPhone("/device/approvals/approve", "POST", '{"code":"213-854"}');
  assert.deepEqual(JSON.parse(ok.body), { ok: true, deviceKeyId: "requester-aaaa", display: a.display });
  assert.deepEqual(approvedBy, [phone.id]);

  // PC で入力したら approvedBy は無い
  assert.equal((await post("/local/approvals/open")).status, 200);
  addPending("requester-bbbb", "111111", false);
  assert.equal((await post("/local/devices/pending/approve", '{"code":"111 111"}')).status, 200);
  assert.equal((await post("/local/approvals/close")).status, 204);
  assert.deepEqual(approvedBy, [phone.id, undefined]);

  // スマホで拒否 → その鍵を断る
  const c = addPending("requester-cccc", "222222", true);
  assert.deepEqual(await asPhone(`/device/approvals/${c.pendingId}/reject`, "POST"), { status: 200, body: '{"ok":true}' });
  assert.deepEqual(ended, ["requester-cccc:rejected"]);
  assert.equal(bridge.approvals.isRejected("requester-cccc"), true);
  assert.deepEqual(await asPhone(`/device/approvals/${c.pendingId}/reject`, "POST"), { status: 404, body: '{"error":"not_found"}' });

  // スマホからの許可を切ると、remote の申し込みは closed で取り下げ、/device/approvals は enabled:false・409 disabled
  addPending("requester-dddd", "333333", true);
  assert.equal((await post("/local/devices/settings", '{"remoteApprovalsEnabled":false}')).status, 200);
  assert.ok(ended.includes("requester-dddd:closed"));
  assert.deepEqual(JSON.parse((await asPhone("/device/approvals")).body), { pending: [], enabled: false });
  assert.deepEqual(await asPhone("/device/approvals/approve", "POST", '{"code":"333333"}'), { status: 409, body: '{"error":"disabled"}' });
  assert.deepEqual(await asPhone("/device/approvals/p_x/reject", "POST"), { status: 409, body: '{"error":"disabled"}' });
  const off = JSON.parse((await request("/local/devices", { headers: admin() })).body);
  assert.equal(off.remoteApprovalsEnabled, false);
  assert.equal(off.remoteApprovalsAvailable, false);
  assert.equal((await post("/local/devices/settings", '{"remoteApprovalsEnabled":true}')).status, 200);
});

test("WS: register_e2e_key は unsupported。register_push_token は端末の WS からだけ受け、内側の E2E の deviceId 違いは 1008", async () => {
  const d = addDevice("device-ws-0001");
  const token = "ab".repeat(32);
  // この PC の中から（.local）: register_push_token は無視し、register_e2e_key は unsupported
  const localWs = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/echo?apiKey=${identity.localKey()}`);
  await new Promise((r) => localWs.once("open", r));
  const result = new Promise<Record<string, unknown>>((resolve) =>
    localWs.on("message", (raw) => {
      const evt = JSON.parse(String(raw));
      if (evt.type === "e2e_register_result") resolve(evt);
    })
  );
  localWs.send(JSON.stringify({ type: "register_push_token", agentId: "echo", content: token, metadata: { environment: "production" } }));
  localWs.send(JSON.stringify({ type: "register_e2e_key", agentId: "echo", content: "x", metadata: { deviceId: "device-ws-0001" } }));
  assert.deepEqual((await result).metadata, { ok: "0", reason: "unsupported" });
  assert.equal(identity.devices.get(d.id)?.push, undefined);
  localWs.close();

  // トンネル経由の端末（.device）
  const socket = await tunnelSocket(d.id);
  const deviceWs = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/echo?apiKey=${d.credential}`, { createConnection: () => socket } as never);
  await new Promise((r) => deviceWs.once("open", r));
  deviceWs.send(JSON.stringify({ type: "register_push_token", agentId: "echo", content: token.toUpperCase(), metadata: { environment: "production", locale: "en", deviceId: "ignored" } }));
  const deadline = Date.now() + 3000;
  while (!identity.devices.get(d.id)?.push && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(identity.devices.get(d.id)?.push, { token, env: "production", locale: "en" });
  deviceWs.close();

  const socket2 = await tunnelSocket(d.id);
  const mismatched = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/echo?apiKey=${d.credential}&e2e=v1&deviceId=someone-else`, { createConnection: () => socket2 } as never);
  const code = await new Promise<number>((resolve) => mismatched.once("close", (c) => resolve(c)));
  assert.equal(code, 1008);
});

test("WS: background_work_state は端末（.device）の WS にだけ送り、register_activity_token も端末の WS からだけ受ける", async () => {
  const d = addDevice("device-ws-0002");
  const liveActivity = bridge.services.liveActivity;
  const original = liveActivity.register.bind(liveActivity);
  const calls: Array<[string, string | undefined, Record<string, string> | undefined]> = [];
  liveActivity.register = (deviceKeyId, content, metadata) => void calls.push([deviceKeyId, content, metadata]);
  const token = "cd".repeat(32);
  const metadata = { activityId: "act-1", batch: crypto.randomUUID(), environment: "production", running: "2", failed: "0" };
  try {
    // この PC の中から（.local）: 状態は届かず、token も受けない
    const localWs = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/echo?apiKey=${identity.localKey()}`);
    const localEvents: Array<{ type: string }> = [];
    localWs.on("message", (raw) => localEvents.push(JSON.parse(String(raw))));
    await new Promise((r) => localWs.once("open", r));
    localWs.send(JSON.stringify({ type: "register_activity_token", agentId: "echo", content: token, metadata }));
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(localEvents.filter((e) => e.type === "background_work_state").length, 0);
    assert.deepEqual(calls, []);
    localWs.close();

    // トンネル経由の端末（.device）: 開いたとき今の状態を 1 回受け、token は deviceKeyId つきで渡る
    const socket = await tunnelSocket(d.id);
    const deviceWs = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/echo?apiKey=${d.credential}`, { createConnection: () => socket } as never);
    const state = new Promise<Record<string, unknown>>((resolve) =>
      deviceWs.on("message", (raw) => {
        const evt = JSON.parse(String(raw));
        if (evt.type === "background_work_state") resolve(JSON.parse(evt.content));
      })
    );
    await new Promise((r) => deviceWs.once("open", r));
    const got = await state;
    assert.deepEqual([got.v, got.push, got.phase, got.running, got.batch], [1, false, "idle", 0, null]);
    deviceWs.send(JSON.stringify({ type: "register_activity_token", agentId: "echo", content: token, metadata }));
    const deadline = Date.now() + 3000;
    while (calls.length === 0 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
    assert.deepEqual(calls, [[d.id, token, metadata]]);
    deviceWs.close();
  } finally {
    liveActivity.register = original;
  }
});
