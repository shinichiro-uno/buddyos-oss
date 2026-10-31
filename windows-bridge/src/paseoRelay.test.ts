import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { WebSocket, WebSocketServer, type RawData } from "ws";

import { ApprovalQueue, type PendingView } from "./approvalQueue.js";
import { TunnelPeers } from "./auth.js";
import { loadOrCreatePaseoRelayId, paseoRelayURL } from "./config.js";
import { DeviceStore } from "./deviceStore.js";
import { E2EFrameReceiver, E2EFrameSender, FRAME_VERSION_V3 } from "./e2e.js";
import { OFFICIAL_DEFAULTS } from "./officialDefaults.js";
import { PairingInvites, type Invite } from "./pairingInvites.js";
import { connectRefusal, PaseoRelayTunnel, relayBackoffMs, relayEndpoint } from "./paseoRelay.js";
import {
  credentialHash,
  deviceKeyId,
  initiatorRead2,
  initiatorWrite1,
  newCredential,
  PROLOGUE,
  sasCode,
  sasCommit,
  sealFrameV3,
  x25519Pub,
  ZERO_PSK
} from "./tunnelV3.js";

// トンネル v3（spec/PROTOCOL-v3.md §8）を、偽の Paseo 中継と、参照実装の initiator で作った
// テスト用の端末で通す。握手のバイト列そのものは tunnelV3.test.ts の PROTOCOL-v3 §18 のベクタで確かめている。

const b64u = (b: Buffer) => b.toString("base64url");

// ---- URL・設定 ----

test("中継の URL は iOS / mac と同じクエリになる", () => {
  assert.equal(
    relayEndpoint("wss://relay.example.com/ws", "client", "srv_-1", "c-1"),
    "wss://relay.example.com/ws?v=2&role=client&serverId=srv_-1&connectionId=c-1"
  );
  assert.equal(
    relayEndpoint("wss://relay.example.com/ws?token=x", "server", "srv"),
    "wss://relay.example.com/ws?token=x&v=2&role=server&serverId=srv"
  );
  assert.throws(() => relayEndpoint("not a url", "server", "srv"));
});

test("中継の URL は BUDDYOS_PASEO_RELAY_URL → 既定値（officialDefaults.ts）→ 無し", () => {
  const withDefault = { ...OFFICIAL_DEFAULTS, paseoRelayURL: "wss://relay.example.com/ws" };
  const empty = { ...OFFICIAL_DEFAULTS, paseoRelayURL: "" };
  assert.equal(paseoRelayURL({}), OFFICIAL_DEFAULTS.paseoRelayURL, "既定は officialDefaults.ts の値（公開版は空）");
  assert.equal(paseoRelayURL({}, withDefault), "wss://relay.example.com/ws");
  assert.equal(paseoRelayURL({ BUDDYOS_PASEO_RELAY_URL: "  wss://relay.example.com/custom \n" }, withDefault), "wss://relay.example.com/custom");
  assert.equal(paseoRelayURL({ BUDDYOS_PASEO_RELAY_URL: "   " }, withDefault), "wss://relay.example.com/ws");
  assert.equal(paseoRelayURL({}, empty), "", "中継が無ければ空（中継につながず案内を出す）");
  assert.equal(paseoRelayURL({ BUDDYOS_PASEO_RELAY_URL: "wss://relay.example.com/ws" }, empty), "wss://relay.example.com/ws");
});

test("中継が無ければ start してもつながず、案内を 1 回だけログに出す", () => {
  const logs: string[] = [];
  const tunnel = new PaseoRelayTunnel({
    relayURL: "",
    identity: { e2eKey: crypto.randomBytes(32), relayId: "r".repeat(43), bridgeId: "windows-bridge-no-relay" },
    devices: undefined as never,
    invites: undefined as never,
    approvals: undefined as never,
    peers: undefined as never,
    bridgeName: () => "PC",
    log: (m) => logs.push(m)
  });
  tunnel.start(1);
  tunnel.start(1);
  assert.equal(tunnel.controlOpen, false);
  assert.equal(logs.length, 1);
  assert.match(logs[0], /BUDDYOS_PASEO_RELAY_URL/);
  tunnel.stop();
});

test("再接続の待ちは mac と同じ 2, 4, 8, 16, 30 秒で頭打ち", () => {
  assert.deepEqual([1, 2, 3, 4, 5, 6, 20].map(relayBackoffMs), [2000, 4000, 8000, 16000, 30000, 30000, 30000]);
});

test("paseo-relay-id は mac と同じ形式（32B の base64url、改行なし）で保存し、使い回す", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-relay-id-"));
  const file = path.join(dir, "paseo-relay-id");
  const id = loadOrCreatePaseoRelayId(file);
  assert.match(id, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(fs.readFileSync(file, "utf8"), id);
  assert.equal(loadOrCreatePaseoRelayId(file), id);
  if (process.platform !== "win32") assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  fs.writeFileSync(file, " given-id\n");
  assert.equal(loadOrCreatePaseoRelayId(file), "given-id");
  fs.writeFileSync(file, "\n");
  const regenerated = loadOrCreatePaseoRelayId(file);
  assert.match(regenerated, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(regenerated, id);
  assert.deepEqual(fs.readdirSync(dir), ["paseo-relay-id"]);
});

// ---- 偽の Paseo v2 中継を通した往復 ----

interface Pair {
  client: WebSocket;
  server?: WebSocket;
}

/**
 * Paseo v2 中継の最小の偽物。server の制御用の接続に connected / disconnected / sync を送り、
 * connectionId ごとに client と server のデータ用の接続をつなぐ。server が付く前に client が送った分は捨てる
 * （iOS が init を再送する理由）。
 */
class FakeRelay {
  readonly wss: WebSocketServer;
  readonly controls = new Map<string, WebSocket>();
  readonly pairs = new Map<string, Pair>();
  controlConnects = 0;

  constructor() {
    this.wss = new WebSocketServer({ host: "127.0.0.1", port: 0 });
    this.wss.on("connection", (ws, req) => this.accept(ws, new URL(req.url ?? "/", "ws://relay")));
  }

  get url(): string {
    const address = this.wss.address() as net.AddressInfo;
    return `ws://127.0.0.1:${address.port}/ws`;
  }

  ready(): Promise<void> {
    return new Promise((resolve) => {
      if ((this.wss.address() as net.AddressInfo | null)?.port) resolve();
      else this.wss.once("listening", () => resolve());
    });
  }

  private accept(ws: WebSocket, url: URL): void {
    const q = url.searchParams;
    assert.equal(q.get("v"), "2");
    const serverId = q.get("serverId") ?? "";
    const connectionId = q.get("connectionId");
    const key = `${serverId}/${connectionId}`;
    if (q.get("role") === "server" && !connectionId) {
      this.controlConnects += 1;
      this.controls.set(serverId, ws);
      ws.on("close", () => {
        if (this.controls.get(serverId) === ws) this.controls.delete(serverId);
      });
      const waiting = [...this.pairs.entries()]
        .filter(([k, p]) => k.startsWith(`${serverId}/`) && !p.server)
        .map(([k]) => k.slice(serverId.length + 1));
      ws.send(JSON.stringify({ type: "sync", connectionIds: waiting }));
      return;
    }
    if (q.get("role") === "client" && connectionId) {
      const pair: Pair = { client: ws };
      this.pairs.set(key, pair);
      ws.on("message", (data, isBinary) => {
        if (pair.server?.readyState === WebSocket.OPEN) pair.server.send(data, { binary: isBinary });
      });
      ws.on("close", () => {
        this.pairs.delete(key);
        pair.server?.close();
        this.controls.get(serverId)?.send(JSON.stringify({ type: "disconnected", connectionId }));
      });
      this.controls.get(serverId)?.send(JSON.stringify({ type: "connected", connectionId }));
      return;
    }
    if (q.get("role") === "server" && connectionId) {
      const pair = this.pairs.get(key);
      if (!pair || pair.server) {
        ws.close();
        return;
      }
      pair.server = ws;
      ws.on("message", (data, isBinary) => {
        if (pair.client.readyState === WebSocket.OPEN) pair.client.send(data, { binary: isBinary });
      });
      ws.on("close", () => pair.client.close());
      return;
    }
    ws.close();
  }

  dropControl(serverId: string): void {
    this.controls.get(serverId)?.terminate();
  }

  close(): Promise<void> {
    for (const ws of this.wss.clients) ws.terminate();
    return new Promise((resolve) => this.wss.close(() => resolve()));
  }
}


// ---- テスト用の端末（initiator。tunnelV3.ts の参照実装） ----

interface V3Client {
  /** msg2 の payload2（開けたとき）。 */
  payload2?: Record<string, unknown>;
  /** 平文のエラー（buddyos_tunnel_error）の code。 */
  errorCode?: string;
  /** msg2 を開けなかった（psk 違いなど）。 */
  helloFailed?: boolean;
  /** 握手のハッシュ（approve の確認コードを端末の側で出すため）。 */
  handshakeHash?: Buffer;
  sendControl(obj: unknown): void;
  send(data: Buffer): void;
  /** 生のバイナリを送る（壊れたフレームのテスト用）。 */
  sendRaw(data: Buffer): void;
  /** 受け取った制御メッセージ（JSON）を 1 つ待つ。 */
  nextControl(ms?: number): Promise<Record<string, unknown>>;
  received(): Buffer;
  closed: Promise<void>;
  isClosed(): boolean;
  close(): void;
}

function v3Client(opts: {
  relayId: string;
  devicePriv: Buffer;
  payload1: Record<string, unknown>;
  psk?: Buffer;
  /** msg1 の代わりに送る TEXT（v2 の init など）。 */
  rawInit?: string;
}): Promise<V3Client> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(relayEndpoint(relay.url, "client", opts.relayId, crypto.randomUUID()));
    const inp = { prologue: PROLOGUE, sI: opts.devicePriv, eI: crypto.randomBytes(32), sRpub: bridgePub, psk: opts.psk ?? ZERO_PSK };
    const m1 = initiatorWrite1(inp, Buffer.from(JSON.stringify(opts.payload1), "utf8"));
    const init = opts.rawInit ?? JSON.stringify({ type: "buddyos_tunnel_init", v: 3, e: b64u(m1.ePub), s: b64u(m1.sPubCt), p: b64u(m1.payloadCt) });
    let retry: NodeJS.Timeout | undefined;
    let sender: E2EFrameSender | undefined;
    let receiver: E2EFrameReceiver | undefined;
    let received = Buffer.alloc(0);
    const controls: Array<Record<string, unknown>> = [];
    const controlWaiters: Array<(c: Record<string, unknown>) => void> = [];
    let closedFlag = false;
    let closedResolve: () => void = () => {};
    const closed = new Promise<void>((r) => (closedResolve = r));
    const client: V3Client = {
      sendControl: (obj) => ws.send(sender!.seal(Buffer.from(JSON.stringify(obj), "utf8"))),
      send: (data) => ws.send(sender!.seal(data)),
      sendRaw: (data) => ws.send(data),
      nextControl: (ms = 5000) =>
        new Promise((res, rej) => {
          const c = controls.shift();
          if (c) return res(c);
          const t = setTimeout(() => rej(new Error("no control message")), ms);
          controlWaiters.push((v) => {
            clearTimeout(t);
            res(v);
          });
        }),
      received: () => received,
      closed,
      isClosed: () => closedFlag,
      close: () => ws.close()
    };
    let settled = false;
    const settle = () => {
      if (settled) return;
      settled = true;
      clearInterval(retry);
      clearTimeout(timeout);
      resolve(client);
    };
    const timeout = setTimeout(() => {
      ws.terminate();
      if (!settled) reject(new Error("handshake timeout"));
    }, 10_000);
    ws.on("open", () => {
      ws.send(init);
      retry = setInterval(() => ws.readyState === WebSocket.OPEN && ws.send(init), 350);
    });
    ws.on("message", (raw: RawData, isBinary) => {
      const data = Buffer.isBuffer(raw) ? raw : Buffer.concat(raw as Buffer[]);
      if (!isBinary) {
        if (settled) return;
        const msg = JSON.parse(data.toString("utf8"));
        if (msg.type === "buddyos_tunnel_error") {
          client.errorCode = msg.code;
          return settle();
        }
        if (msg.type !== "buddyos_tunnel_hello") return;
        try {
          const r = initiatorRead2(inp, m1.st, Buffer.from(msg.e, "base64url"), Buffer.from(msg.p, "base64url"));
          client.payload2 = JSON.parse(r.payload.toString("utf8"));
          client.handshakeHash = r.handshakeHash;
          sender = new E2EFrameSender(r.c2s, FRAME_VERSION_V3);
          receiver = new E2EFrameReceiver(r.s2c, FRAME_VERSION_V3);
        } catch {
          client.helloFailed = true;
        }
        return settle();
      }
      if (!receiver) return;
      const pt = receiver.open(data);
      // connect のトンネルは TCP のバイト列、pair のトンネルは制御メッセージ（JSON）だけ。
      if (opts.payload1.mode === "connect") {
        received = Buffer.concat([received, pt]);
        return;
      }
      const parsed = JSON.parse(pt.toString("utf8")) as Record<string, unknown>;
      const w = controlWaiters.shift();
      if (w) w(parsed);
      else controls.push(parsed);
    });
    ws.on("error", () => {});
    ws.on("close", () => {
      closedFlag = true;
      clearInterval(retry);
      closedResolve();
      if (!settled) {
        settled = true;
        clearTimeout(timeout);
        reject(new Error("closed before hello"));
      }
    });
  });
}

async function waitFor(check: () => boolean, ms = 5000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
}

// ---- 共通の準備 ----

let relay: FakeRelay;
let httpServer: http.Server;
let httpPort = 0;
let tmp: string;
const bridgeKey = crypto.randomBytes(32);
const bridgePub = x25519Pub(bridgeKey);
const tunnels: PaseoRelayTunnel[] = [];
/** HTTP の要求が届いたときの、送り元の番号で引いた端末（トンネル経由の見分けを確かめる）。 */
let lastPeerSeen: string | null | undefined;
let currentPeers: TunnelPeers | undefined;

interface Rig {
  serverId: string;
  devices: DeviceStore;
  invites: PairingInvites;
  approvals: ApprovalQueue;
  /** remote の承認待ちを作ったときに呼ばれた分（push の代わり）。 */
  remoteAdded: PendingView[];
  peers: TunnelPeers;
  tunnel: PaseoRelayTunnel;
}

async function rig(name: string, limits: Record<string, number> = {}): Promise<Rig> {
  const dir = fs.mkdtempSync(path.join(tmp, `${name}-`));
  const devices = DeviceStore.createFresh(dir, "migration_v3", { log: () => {} });
  const invites = new PairingInvites();
  const approvals = new ApprovalQueue();
  const remoteAdded: PendingView[] = [];
  approvals.onRemoteAdded = (p) => remoteAdded.push(p);
  const peers = new TunnelPeers();
  currentPeers = peers;
  const serverId = `srv-${name}`;
  const tunnel = new PaseoRelayTunnel({
    relayURL: relay.url,
    identity: { e2eKey: bridgeKey, relayId: serverId, bridgeId: "windows-bridge-test" },
    devices,
    invites,
    approvals,
    peers,
    bridgeName: () => "Test PC",
    log: () => {},
    backoffMs: () => 20,
    limits
  });
  tunnels.push(tunnel);
  tunnel.start(httpPort);
  await waitFor(() => tunnel.controlOpen && relay.controls.has(serverId));
  return { serverId, devices, invites, approvals, remoteAdded, peers, tunnel };
}

const devicePayload = (mode: string, extra: Record<string, unknown> = {}) => ({
  mode,
  deviceId: "device-test-1",
  name: "Test iPhone",
  platform: "ios",
  app: "131",
  ...extra
});

/** QR の招待でペアリングし、資格情報を返す。 */
async function pair(r: Rig, devicePriv: Buffer, invite: Invite): Promise<{ credential: string; paired: Record<string, unknown> }> {
  const client = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("pair", { invite: invite.id }), psk: invite.psk });
  assert.equal(client.payload2?.ok, true, JSON.stringify(client.payload2 ?? client.errorCode));
  client.sendControl({ type: "pair_confirm" });
  const paired = await client.nextControl();
  assert.equal(paired.type, "paired");
  client.sendControl({ type: "paired_ack" });
  await client.closed;
  return { credential: paired.credential as string, paired };
}

before(async () => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-paseo-v3-"));
  relay = new FakeRelay();
  await relay.ready();
  httpServer = http.createServer((req, res) => {
    lastPeerSeen = currentPeers?.get(req.socket.remotePort)?.deviceKeyId ?? null;
    res.writeHead(200, { "content-type": "application/json", connection: "close" });
    res.end(JSON.stringify({ ok: true, path: req.url, auth: req.headers.authorization ?? null }));
  });
  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", () => resolve()));
  httpPort = (httpServer.address() as net.AddressInfo).port;
});

after(async () => {
  for (const tunnel of tunnels) tunnel.stop();
  await relay.close();
  httpServer.closeAllConnections();
  await new Promise((r) => httpServer.close(r));
});

// ---- 流れ ----

test("pair → connect: QR の招待でペアリングし、bdc_ でつなぐと HTTP が届き、送り元の番号で端末が分かる", { timeout: 30_000 }, async () => {
  const r = await rig("pair-connect");
  const devicePriv = crypto.randomBytes(32);
  const keyId = deviceKeyId(x25519Pub(devicePriv));
  const invite = r.invites.create();
  const { credential, paired } = await pair(r, devicePriv, invite);
  assert.match(credential, /^bdc_[A-Za-z0-9_-]{43}$/);
  assert.equal(paired.deviceKeyId, keyId);
  assert.deepEqual(paired.bridge, { bridgeId: "windows-bridge-test", name: "Test PC", platform: "windows", relayId: r.serverId, relayURL: relay.url });
  // 行は確定し、資格情報は hash だけを持つ。招待には使った端末が残る（同じ端末のやり直しにだけ使える）。
  await waitFor(() => r.devices.state(keyId) === undefined && !!r.devices.get(keyId));
  assert.equal(r.devices.get(keyId)?.via, "qr");
  assert.equal(r.devices.verify(keyId, credential), true);
  assert.ok(!fs.readFileSync(r.devices.file, "utf8").includes(credential));
  assert.equal(r.invites.views()[0].usedBy?.display, `Test iPhone · ${keyId.slice(0, 4)}`);

  const client = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect") });
  assert.deepEqual(client.payload2, { ok: true, bridgeId: "windows-bridge-test", name: "Test PC", platform: "windows", deviceKeyId: keyId });
  client.sendControl({ type: "open" });
  client.send(Buffer.from(`GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer ${credential}\r\n\r\n`));
  await client.closed;
  assert.match(client.received().toString("utf8"), /^HTTP\/1\.1 200 OK\r\n/);
  assert.equal(lastPeerSeen, keyId);
  // 閉じたら TunnelPeers から外れる。lastSeenAt が入る。
  await waitFor(() => r.peers.size === 0);
  assert.ok(r.devices.get(keyId)?.lastSeenAt);
});

test("connect: 一覧に無い鍵は unknown_device、外した鍵は revoked、deviceId 違いは unknown_device", { timeout: 30_000 }, async () => {
  const r = await rig("connect-refusals");
  const devicePriv = crypto.randomBytes(32);
  const keyId = deviceKeyId(x25519Pub(devicePriv));
  const unknown = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect") });
  assert.deepEqual(unknown.payload2, { ok: false, error: "unknown_device" });
  await unknown.closed;

  await pair(r, devicePriv, r.invites.create());
  const wrongId = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect", { deviceId: "other-device-9" }) });
  assert.deepEqual(wrongId.payload2, { ok: false, error: "unknown_device" });

  // PROTOCOL-v3 §18.2: 解除中（/device/unpair の直後）は revoked
  assert.equal(r.devices.markUnpairing(keyId), true);
  const unpairing = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect") });
  assert.deepEqual(unpairing.payload2, { ok: false, error: "revoked" });
  r.devices.removeUnpairing(keyId);

  await pair(r, devicePriv, r.invites.create());
  assert.equal(r.devices.revoke(keyId), true);
  const revoked = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect") });
  assert.deepEqual(revoked.payload2, { ok: false, error: "revoked" });
  assert.equal(connectRefusal(r.devices, keyId, "device-test-1"), "revoked");
});

test("PROTOCOL-v3 §18.2: approve は窓が閉じていてスマホでの許可も使えなければ approval_unavailable。v2 の init は version", { timeout: 30_000 }, async () => {
  const r = await rig("approve");
  const approve = await v3Client({ relayId: r.serverId, devicePriv: crypto.randomBytes(32), payload1: devicePayload("approve") });
  assert.deepEqual(approve.payload2, { ok: false, error: "approval_unavailable" });
  // 許可できる端末でも push の宛先が無い・デスクトップ（別の PC）だけに宛先がある、ではスマホでの許可は使えない。
  addDevice(r, { platform: "ios" });
  addDevice(r, { platform: "mac", push: true });
  const stillNo = await v3Client({ relayId: r.serverId, devicePriv: crypto.randomBytes(32), payload1: devicePayload("approve") });
  assert.deepEqual(stillNo.payload2, { ok: false, error: "approval_unavailable" });
  const v2 = await v3Client({
    relayId: r.serverId,
    devicePriv: crypto.randomBytes(32),
    payload1: devicePayload("connect"),
    rawInit: JSON.stringify({ type: "buddyos_tunnel_init", deviceId: "device-test-1", devicePub: b64u(crypto.randomBytes(32)), v: 2, clientNonce: b64u(crypto.randomBytes(32)) })
  });
  assert.equal(v2.errorCode, "version");
  const legacy = await v3Client({
    relayId: r.serverId,
    devicePriv: crypto.randomBytes(32),
    payload1: devicePayload("connect"),
    rawInit: JSON.stringify({ type: "buddyos_tunnel_init", deviceId: "device-test-1", devicePub: b64u(crypto.randomBytes(32)) })
  });
  assert.equal(legacy.errorCode, "version");
  const badInvite = await v3Client({ relayId: r.serverId, devicePriv: crypto.randomBytes(32), payload1: devicePayload("pair", { invite: b64u(crypto.randomBytes(16)) }) });
  assert.equal(badInvite.errorCode, "invite_invalid");
});

test("PROTOCOL-v3 §18.2: pair の msg2 の後に開けないバイナリを入れても招待は有効なまま。psk 違いは msg2 を開けない", { timeout: 60_000 }, async () => {
  const r = await rig("garbage");
  const devicePriv = crypto.randomBytes(32);
  const invite = r.invites.create();
  for (let i = 0; i < 10; i++) {
    const c = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("pair", { invite: invite.id }), psk: invite.psk });
    assert.equal(c.payload2?.ok, true);
    c.sendRaw(sealFrameV3(crypto.randomBytes(32), 1n, Buffer.from('{"type":"pair_confirm"}')));
    await c.closed;
  }
  const wrongPsk = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("pair", { invite: invite.id }), psk: crypto.randomBytes(32) });
  assert.equal(wrongPsk.helloFailed, true);
  // 開けなかった端末は何も送らずに切る（Bridge 側はペアリングの枠から外れる）。
  wrongPsk.close();
  await wrongPsk.closed;
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(r.invites.find(invite.id)?.usedBy, undefined);
  const { credential } = await pair(r, devicePriv, invite);
  assert.ok(credential);
});

test("PROTOCOL-v3 §18.2: 使われた招待は、別の鍵なら invite_invalid、同じ鍵ならやり直せて bdc_ が置き換わる", { timeout: 30_000 }, async () => {
  const r = await rig("reuse");
  const devicePriv = crypto.randomBytes(32);
  const keyId = deviceKeyId(x25519Pub(devicePriv));
  const invite = r.invites.create();
  const first = await pair(r, devicePriv, invite);
  const other = await v3Client({ relayId: r.serverId, devicePriv: crypto.randomBytes(32), payload1: devicePayload("pair", { invite: invite.id }), psk: invite.psk });
  assert.equal(other.errorCode, "invite_invalid");
  // ペアリングし直しでは、デスクトップで付けたラベルを引き継ぐ。
  assert.ok(r.devices.rename(keyId, "仕事用"));
  const second = await pair(r, devicePriv, invite);
  await waitFor(() => r.devices.get(keyId)?.credHash !== undefined && r.devices.state(keyId) === undefined && r.devices.verify(keyId, second.credential));
  assert.equal(r.devices.get(keyId)?.label, "仕事用");
  assert.notEqual(second.credential, first.credential);
  await waitFor(() => r.devices.verify(keyId, second.credential));
  assert.equal(r.devices.verify(keyId, first.credential), false);
});

test("PROTOCOL-v3 §18.2: paired_ack が来なければ行は消える。同じ鍵の pair を 2 本同時に始めると 2 本目は busy", { timeout: 30_000 }, async () => {
  const r = await rig("ack", { pairedAckTimeoutMs: 300 });
  const devicePriv = crypto.randomBytes(32);
  const keyId = deviceKeyId(x25519Pub(devicePriv));
  const invite = r.invites.create();
  const a = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("pair", { invite: invite.id }), psk: invite.psk });
  assert.equal(a.payload2?.ok, true);
  const b = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("pair", { invite: invite.id }), psk: invite.psk });
  assert.deepEqual(b.payload2, { ok: false, error: "busy" });
  a.sendControl({ type: "pair_confirm" });
  const paired = await a.nextControl();
  assert.equal(paired.type, "paired");
  assert.equal(r.devices.state(keyId), "pendingAck");
  // pendingAck の行はファイルに書かない。connect も通さない。
  assert.ok(!fs.readFileSync(r.devices.file, "utf8").includes(keyId));
  await a.closed;
  await waitFor(() => !r.devices.get(keyId));
  // 招待は期限まで、この端末のやり直しに使える。
  assert.ok(r.invites.usableBy(invite.id, keyId));
});

test("PROTOCOL-v3 §18.2: msg2 の後・open の前に端末を外すと、open を受けても流さずに閉じる。外すと開いているトンネルも閉じる", { timeout: 30_000 }, async () => {
  const r = await rig("revoke-open");
  const devicePriv = crypto.randomBytes(32);
  const keyId = deviceKeyId(x25519Pub(devicePriv));
  await pair(r, devicePriv, r.invites.create());
  const c = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect") });
  assert.equal(c.payload2?.ok, true);
  r.devices.revoke(keyId);
  c.sendControl({ type: "open" });
  await c.closed;
  assert.equal(r.peers.size, 0);

  // 開いているトンネルを closeTunnels で閉じる
  await pair(r, devicePriv, r.invites.create());
  const live = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect") });
  live.sendControl({ type: "open" });
  await waitFor(() => r.peers.size === 1);
  assert.equal(r.tunnel.isOnline(keyId), true);
  r.tunnel.closeTunnels(keyId);
  await live.closed;
  await waitFor(() => r.peers.size === 0 && !r.tunnel.isOnline(keyId));
});

test("認証済みの枠: 1 台の端末の上限を超えた connect は開かない", { timeout: 30_000 }, async () => {
  const r = await rig("slots", { authedPerDevice: 1 });
  const devicePriv = crypto.randomBytes(32);
  await pair(r, devicePriv, r.invites.create());
  const first = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect") });
  first.sendControl({ type: "open" });
  await waitFor(() => r.peers.size === 1);
  const second = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("connect") });
  assert.equal(second.payload2?.ok, true);
  second.sendControl({ type: "open" });
  await second.closed;
  assert.equal(first.isClosed(), false);
  first.close();
  await first.closed;
});

// ---- approve（アカウントで見つけた PC からの承認・スマホで許可する） ----

/** 一覧に確定済みの端末を足す（許可する側のスマホ・別の PC）。push を付けると宛先も入れる。 */
function addDevice(r: Rig, opts: { platform: string; push?: boolean; name?: string }): string {
  const pub = crypto.randomBytes(32);
  const id = deviceKeyId(pub);
  const credential = newCredential();
  const clientDeviceId = `device-${crypto.randomBytes(4).toString("hex")}`;
  r.devices.putPending(id, {
    pub: b64u(pub),
    clientDeviceId,
    name: opts.name ?? "Approver",
    label: null,
    platform: opts.platform,
    credHash: credentialHash(credential),
    via: "qr",
    createdAt: Date.now()
  });
  assert.equal(r.devices.confirm(id, credentialHash(credential)), true);
  if (opts.push) assert.equal(r.devices.setPush(id, crypto.randomBytes(32).toString("hex"), "production", "ja"), "ok");
  return id;
}

/** approve の msg1 → msg2（commit）→ approve_nonce → approve_reveal まで進め、端末の側で出る確認コードを返す。 */
async function startApprove(r: Rig, devicePriv: Buffer, extra: Record<string, unknown> = {}): Promise<{ client: V3Client; code: string }> {
  const client = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("approve", { name: "MacBook Air", platform: "mac", ...extra }) });
  assert.equal(client.payload2?.ok, true, JSON.stringify(client.payload2 ?? client.errorCode));
  assert.equal(client.payload2?.platform, "windows");
  const commit = Buffer.from(String(client.payload2?.commit), "base64url");
  const nD = crypto.randomBytes(32);
  client.sendControl({ type: "approve_nonce", n: b64u(nD) });
  const reveal = await client.nextControl();
  assert.equal(reveal.type, "approve_reveal");
  const nR = Buffer.from(String(reveal.n), "base64url");
  // commit は nR を縛っている（Bridge は msg2 の後で nR を選び直せない。PROTOCOL-v3 §10.4.2）
  assert.ok(sasCommit(nR).equals(commit));
  return { client, code: sasCode(client.handshakeHash!, nD, nR) };
}

const wrongCode = (code: string) => String((Number(code) + 1) % 1_000_000).padStart(6, "0");

test("approve（窓）: 番号の照合で paired、paired_ack で via=approval の行が確定する。間違いは数える", { timeout: 30_000 }, async () => {
  const r = await rig("approve-window");
  r.approvals.openWindow();
  const devicePriv = crypto.randomBytes(32);
  const keyId = deviceKeyId(x25519Pub(devicePriv));
  const { client, code } = await startApprove(r, devicePriv);
  const [view] = r.approvals.views();
  assert.equal(view.deviceKeyId, keyId);
  assert.equal(view.display, `MacBook Air · ${keyId.slice(0, 4)}`);
  assert.equal(view.remote, false);
  assert.equal(r.remoteAdded.length, 0, "窓の申し込みでは push しない");
  assert.ok(!JSON.stringify(r.approvals.views()).includes(code), "一覧に番号は無い");

  assert.deepEqual(await r.approvals.submit(wrongCode(code)), { kind: "mismatch", remaining: 2 });
  const result = r.approvals.submit(code.slice(0, 3) + " " + code.slice(3));
  const paired = await client.nextControl();
  assert.equal(paired.type, "paired");
  assert.equal(paired.deviceKeyId, keyId);
  assert.deepEqual(await result, { kind: "ok", deviceKeyId: keyId, display: `MacBook Air · ${keyId.slice(0, 4)}` });
  assert.equal(r.devices.state(keyId), "pendingAck");
  client.sendControl({ type: "paired_ack" });
  await client.closed;
  await waitFor(() => r.devices.state(keyId) === undefined && !!r.devices.get(keyId));
  const row = r.devices.get(keyId)!;
  assert.equal(row.via, "approval");
  assert.equal(row.platform, "mac");
  assert.equal(row.approvedBy, undefined, "PC で入力したら approvedBy は付けない");
  assert.equal(r.devices.verify(keyId, String(paired.credential)), true);
  assert.equal(r.approvals.views().length, 0);
});

test("approve（スマホ）: 窓が閉じていても許可できる端末に宛先があれば受け付け、push を 1 回。窓を閉じても残り、approvedBy が残る", { timeout: 30_000 }, async () => {
  const r = await rig("approve-remote");
  const phone = addDevice(r, { platform: "ios", push: true });
  const devicePriv = crypto.randomBytes(32);
  const keyId = deviceKeyId(x25519Pub(devicePriv));
  const { client, code } = await startApprove(r, devicePriv);
  const [view] = r.approvals.views();
  assert.equal(view.remote, true);
  assert.equal(r.remoteAdded.length, 1);
  assert.equal(r.remoteAdded[0].pendingId, view.pendingId);
  // デスクトップが窓を閉じても（管理鍵のパイプが閉じても）remote の申し込みは取り下げない
  r.approvals.closeWindow("closed");
  assert.equal(r.approvals.views().length, 1);
  const result = r.approvals.submit(code, phone);
  const paired = await client.nextControl();
  assert.equal(paired.type, "paired");
  assert.equal((await result).kind, "ok");
  client.sendControl({ type: "paired_ack" });
  await client.closed;
  await waitFor(() => r.devices.state(keyId) === undefined && !!r.devices.get(keyId));
  assert.equal(r.devices.get(keyId)?.approvedBy, phone);
  assert.equal(JSON.parse(fs.readFileSync(r.devices.file, "utf8")).devices[keyId].approvedBy, phone);
});

test("approve: 拒否で pair_rejected(rejected)、その鍵は 24 時間 rate_limited。外した鍵は revoked", { timeout: 30_000 }, async () => {
  const r = await rig("approve-reject");
  r.approvals.openWindow();
  const devicePriv = crypto.randomBytes(32);
  const { client } = await startApprove(r, devicePriv);
  assert.equal(r.approvals.reject(r.approvals.views()[0].pendingId), true);
  assert.deepEqual(await client.nextControl(), { type: "pair_rejected", reason: "rejected" });
  await client.closed;
  const again = await v3Client({ relayId: r.serverId, devicePriv, payload1: devicePayload("approve") });
  assert.deepEqual(again.payload2, { ok: false, error: "rate_limited" });

  const revokedPriv = crypto.randomBytes(32);
  const revokedId = deviceKeyId(x25519Pub(revokedPriv));
  await pair(r, revokedPriv, r.invites.create());
  r.devices.revoke(revokedId);
  const revoked = await v3Client({ relayId: r.serverId, devicePriv: revokedPriv, payload1: devicePayload("approve") });
  assert.deepEqual(revoked.payload2, { ok: false, error: "revoked" });
});

test("approve: 待つ間は approval_waiting、5 分（ここでは短く）で pair_rejected(timeout)。pair_cancel で承認待ちから外れる", { timeout: 30_000 }, async () => {
  const r = await rig("approve-timeout", { approvalKeepaliveMs: 80, approvalLifetimeMs: 400 });
  r.approvals.openWindow();
  const { client } = await startApprove(r, crypto.randomBytes(32));
  assert.deepEqual(await client.nextControl(), { type: "approval_waiting" });
  let last = await client.nextControl();
  while (last.type === "approval_waiting") last = await client.nextControl();
  assert.deepEqual(last, { type: "pair_rejected", reason: "timeout" });
  await client.closed;
  await waitFor(() => r.approvals.views().length === 0);

  const cancel = await startApprove(r, crypto.randomBytes(32));
  assert.equal(r.approvals.views().length, 1);
  cancel.client.sendControl({ type: "pair_cancel" });
  await cancel.client.closed;
  await waitFor(() => r.approvals.views().length === 0);
});

test("approve: paired の後に paired_ack が来なければ仮の行は消える。窓を閉じると窓の申し込みは closed", { timeout: 30_000 }, async () => {
  const r = await rig("approve-ack", { approveAckTimeoutMs: 300 });
  r.approvals.openWindow();
  const devicePriv = crypto.randomBytes(32);
  const keyId = deviceKeyId(x25519Pub(devicePriv));
  const { client, code } = await startApprove(r, devicePriv);
  const result = r.approvals.submit(code);
  assert.equal((await client.nextControl()).type, "paired");
  assert.equal((await result).kind, "ok");
  await client.closed;
  await waitFor(() => !r.devices.get(keyId));

  const second = await startApprove(r, crypto.randomBytes(32));
  r.approvals.closeWindow("closed");
  assert.deepEqual(await second.client.nextControl(), { type: "pair_rejected", reason: "closed" });
  await second.client.closed;
});

test("approve: 番号が 3 回外れると、待っている申し込みを全部 code_mismatch で取り下げる。端末が先に切ると no_pending", { timeout: 30_000 }, async () => {
  const r = await rig("approve-mismatch");
  r.approvals.openWindow();
  const a = await startApprove(r, crypto.randomBytes(32));
  const b = await startApprove(r, crypto.randomBytes(32));
  assert.equal(r.approvals.views().length, 2);
  // どちらの番号でもない 3 つ
  const wrong = ["000000", "000001", "000002", "000003", "000004"].filter((c) => c !== a.code && c !== b.code);
  assert.deepEqual(await r.approvals.submit(wrong[0]), { kind: "mismatch", remaining: 2 });
  assert.deepEqual(await r.approvals.submit(wrong[1]), { kind: "mismatch", remaining: 1 });
  assert.deepEqual(await r.approvals.submit(wrong[2]), { kind: "mismatch", remaining: 0 });
  assert.deepEqual(await a.client.nextControl(), { type: "pair_rejected", reason: "code_mismatch" });
  assert.deepEqual(await b.client.nextControl(), { type: "pair_rejected", reason: "code_mismatch" });
  assert.equal(r.approvals.windowOpenUntil, undefined, "窓も閉じる");

  // 端末が先に切ったら承認待ちから外れる（PC で入力しても no_pending）
  r.approvals.openWindow();
  const gone = await startApprove(r, crypto.randomBytes(32));
  gone.client.close();
  await gone.client.closed;
  await waitFor(() => r.approvals.views().length === 0);
  assert.deepEqual(await r.approvals.submit(gone.code), { kind: "no_pending" });
});
