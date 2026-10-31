import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";
import { SubagentTracker } from "./agents/subagentTracker.js";
import type { AgentAdapter, AgentSession, Emit } from "./agents/types.js";
import type { BridgeConfig } from "./config.js";
import { BridgeIdentity } from "./identity.js";
import { event, type SessionEvent } from "./protocol.js";
import { agentsOrWorkflows, cancelDeferredPush, deferPushUntilSettled, fireDeferredPushIfSettled, LiveHistoryIndex, anyBackground, createBridgeServer, lastTurnBubble, WorkflowCardMirror, type BridgeServer } from "./server.js";
import { resolveClaudeUsage } from "./settings.js";
import { SitesService, type SiteList } from "./sites.js";
import { JsonSessionStore } from "./sessionStore.js";
import { typingKeys } from "./terminal/keys.js";
import { credentialHash, deviceKeyId, newCredential } from "./tunnelV3.js";

// server.ts の回帰テスト（全 mode off + echo / モックアダプタ）。実ホームの設定・秘密や PATH 上の
// 実 CLI に触れないよう、ホームと PATH を空の一時ディレクトリに向けてから Bridge を起動する。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-server-test-"));
const fakeHome = path.join(tmp, "home");
const emptyBin = path.join(tmp, "bin");
fs.mkdirSync(fakeHome, { recursive: true });
fs.mkdirSync(emptyBin, { recursive: true });
process.env.HOME = fakeHome;
process.env.USERPROFILE = fakeHome;
process.env.PATH = emptyBin;
for (const key of ["CLAUDE_BIN", "CODEX_BIN", "HERMES_BIN", "OPENCLAW_BIN", "OPENCODE_BIN", "CURSOR_AGENT_BIN", "GROK_BIN", "BUDDYOS_PUSH_RELAY_URL", "BUDDYOS_PUSH_RELAY_TOKEN"]) {
  delete process.env[key];
}

const API_KEY = "test-api-key";
const BRIDGE_ID = "windows-bridge-test";
const defaultCwd = path.join(tmp, "default-cwd");

let bridge: BridgeServer;
let bridgeConfig: BridgeConfig;
let port = 0;
/** テストで開いた WS。失敗で close まで到達しなくても after で閉じ、プロセスを残さない。 */
const sockets = new Set<WebSocket>();
/** slow アダプタの進行中ターンを進める（send() 内で差し替わる）。 */
let releaseSlow: (() => void) | undefined;
/** pendy アダプタの進行中ターンを進める。 */
let releasePendy: (() => void) | undefined;
/** stopper アダプタの stopTask が受けた要求。 */
const stopTaskCalls: Array<{ taskId: string; rowId?: string; epoch?: string }> = [];

function mockAdapter(id: string, open: (sessionId: string | undefined) => AgentSession): AgentAdapter {
  return {
    id,
    displayName: id,
    runtimeLabel: `local:${id}`,
    openSession: async (sessionId) => open(sessionId),
    listSessions: async () => [],
    loadHistory: async () => [],
    renameSession: async () => false,
    listCommands: async () => [],
    currentInfo: async () => undefined,
    setModel: async () => {},
    listAvailableModels: async () => []
  };
}

before(async () => {
  const configDir = path.join(tmp, "config");
  // ローカル鍵と bridgeId は環境変数で固定する（作り直しても変わらない。実際の %LOCALAPPDATA% には触れない）。
  const identity = BridgeIdentity.open(configDir, {
    env: { BUDDYOS_BRIDGE_API_KEY: API_KEY, BUDDYOS_BRIDGE_ID: BRIDGE_ID },
    homeDir: fakeHome,
    log: () => {}
  });
  const config: BridgeConfig = {
    configDir,
    identity,
    bridgeId: BRIDGE_ID,
    port: 0,
    paseoRelayURL: "wss://relay.example.com/ws",
    defaultCwd,
    hermesMode: "off",
    claudeMode: "off",
    codexMode: "off",
    openclawMode: "off",
    opencodeMode: "off",
    cursorMode: "off",
    grokMode: "off",
    antigravityMode: "off"
  };
  bridgeConfig = config;
  bridge = createBridgeServer(config, new JsonSessionStore(config.configDir));

  // error だけで終わる（done を伴わない）ターン。
  bridge.adapters.set("failing", mockAdapter("failing", (sessionId) => {
    const session: AgentSession = {
      sessionId: sessionId ?? "fail-1",
      async send(_text, _event, emit) {
        emit(event.error("failing", session.sessionId, "boom"));
      },
      async close() {}
    };
    return session;
  }));

  // pending-xxx → 実 id に確定し、release されるまでターンの途中で止まる。
  bridge.adapters.set("slow", mockAdapter("slow", (sessionId) => {
    const session: AgentSession = {
      sessionId: sessionId ?? "pending-slow",
      async send(_text, _event, emit) {
        session.sessionId = "slow-1";
        emit(event.sessionStarted("slow", "slow-1"));
        emit(event.assistantDelta("slow", "slow-1", "m-1", "before "));
        await new Promise<void>((resolve) => {
          releaseSlow = resolve;
        });
        emit(event.assistantDelta("slow", "slow-1", "m-1", "after"));
        emit(event.done("slow", "slow-1", "m-1"));
      },
      async close() {}
    };
    return session;
  }));

  // 途中の done（metadata.pending）を出して止まり、release されたら最後の done で終わる。
  // 本文が "notify" なら pending を付けず origin = task-notification だけの done（Bridge が pending を刻む）。
  bridge.adapters.set("pendy", mockAdapter("pendy", (sessionId) => {
    const session: AgentSession = {
      sessionId: sessionId ?? "pendy-1",
      async send(text, _event, emit) {
        emit(event.sessionStarted("pendy", "pendy-1"));
        emit(event.assistantDelta("pendy", "pendy-1", "m-1", "first"));
        const metadata: Record<string, string> = text === "notify" ? { origin: "task-notification" } : { pending: "1" };
        emit({ ...event.done("pendy", "pendy-1", "m-1"), metadata });
        await new Promise<void>((resolve) => {
          releasePendy = resolve;
        });
        emit(event.assistantDelta("pendy", "pendy-1", "m-2", "second"));
        emit(event.done("pendy", "pendy-1", "m-2"));
      },
      async close() {}
    };
    return session;
  }));

  // injectMidTurn 無しで interrupt() だけ持つアダプタ（CLI 版 claude・headless・ACP・ライブ Codex 相当）。
  bridge.adapters.set("stoppable", {
    ...mockAdapter("stoppable", (sessionId) => ({
      sessionId: sessionId ?? "stop-1",
      async send() {},
      async interrupt() {},
      async close() {}
    })),
    supportsInterrupt: true
  });

  // 生成中の送信を流し込めるアダプタ（Claude Code・Codex app-server 相当）。interrupt も広告される。
  bridge.adapters.set("injectable", {
    ...mockAdapter("injectable", (sessionId) => ({
      sessionId: sessionId ?? "inject-1",
      async send() {},
      inject: () => true,
      async interrupt() {},
      async close() {}
    })),
    supportsMidTurnInjection: true
  });

  // stopTask を持つアダプタ（taskId で結果を選ぶ）と、持たないアダプタ。
  bridge.adapters.set("stopper", mockAdapter("stopper", (sessionId) => {
    const session: AgentSession = {
      sessionId: sessionId ?? "stopper-1",
      async send(_text, _event, emit) {
        emit(event.sessionStarted("stopper", "stopper-1"));
        emit(event.done("stopper", "stopper-1", "m-1"));
      },
      async stopTask(req) {
        stopTaskCalls.push(req);
        return req.taskId === "gone" ? { kind: "notRunning" } : { kind: "stopped" };
      },
      async close() {}
    };
    return session;
  }));
  bridge.adapters.set("nostop", mockAdapter("nostop", (sessionId) => ({
    sessionId: sessionId ?? "nostop-1",
    async send(_text, _event, emit) {
      emit(event.sessionStarted("nostop", "nostop-1"));
      emit(event.done("nostop", "nostop-1", "m-1"));
    },
    async close() {}
  })));

  await bridge.start();
  const address = bridge.server.address();
  assert.ok(address && typeof address === "object");
  port = address.port;
});

after(() => {
  for (const ws of sockets) ws.terminate();
  bridge.server.closeAllConnections();
  bridge.server.close();
  // Windows では Defender / インデクサが sessions.json を一時的に掴み EBUSY/EPERM になるのでリトライする。
  fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
});

interface Client {
  events: SessionEvent[];
  send(evt: SessionEvent): void;
  until(pred: (evt: SessionEvent) => boolean, timeoutMs?: number): Promise<SessionEvent>;
  close(): Promise<void>;
}

/** via: ペアリング済みの端末（.device）として張るときの、トンネルのふりをした TCP と端末の bdc_（connectAsDevice）。無ければ api-key の .local。 */
async function connect(agentId: string, query = "", via?: { socket: net.Socket; credential: string }): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/${agentId}?apiKey=${via?.credential ?? API_KEY}${query}`, via ? { createConnection: () => via.socket } : undefined);
  sockets.add(ws);
  ws.once("close", () => sockets.delete(ws));
  const events: SessionEvent[] = [];
  const waiters: Array<{ pred: (evt: SessionEvent) => boolean; resolve: (evt: SessionEvent) => void }> = [];
  ws.on("message", (raw) => {
    const evt = JSON.parse(String(raw)) as SessionEvent;
    events.push(evt);
    for (const waiter of waiters.splice(0)) {
      if (waiter.pred(evt)) waiter.resolve(evt);
      else waiters.push(waiter);
    }
  });
  await new Promise<void>((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
  });
  return {
    events,
    send: (evt) => ws.send(JSON.stringify(evt)),
    until: (pred, timeoutMs = 3000) =>
      new Promise((resolve, reject) => {
        const found = events.find(pred);
        if (found) {
          resolve(found);
          return;
        }
        const timer = setTimeout(() => reject(new Error("timed out waiting for event")), timeoutMs);
        waiters.push({
          pred,
          resolve: (evt) => {
            clearTimeout(timer);
            resolve(evt);
          }
        });
      }),
    close: () =>
      new Promise<void>((resolve) => {
        if (ws.readyState === WebSocket.CLOSED) {
          resolve();
          return;
        }
        ws.once("close", () => resolve());
        ws.close();
      })
  };
}

/**
 * ペアリング済みの端末（.device）として WS をつなぐ。トンネルのふり（auth.test.ts と同じ）: Bridge へつないだ TCP の送り元の番号を
 * TunnelPeers に入れ、その端末の bdc_ で張る。api-key（.local）の connect と違い、人が入力欄で打った発話として扱われる。
 */
async function connectAsDevice(agentId: string, query = ""): Promise<Client> {
  const pub = crypto.randomBytes(32);
  const id = deviceKeyId(pub);
  const credential = newCredential();
  bridge.devices.putPending(id, {
    pub: pub.toString("base64url"),
    clientDeviceId: `device-${id.slice(0, 8)}`,
    name: "iPhone",
    label: null,
    platform: "ios",
    credHash: credentialHash(credential),
    via: "qr",
    createdAt: Date.now()
  });
  bridge.devices.confirm(id, credentialHash(credential));
  const socket = net.connect({ host: "127.0.0.1", port });
  await new Promise<void>((resolve, reject) => {
    socket.once("connect", () => resolve());
    socket.once("error", reject);
  });
  const localPort = socket.localPort!;
  const peer = { deviceKeyId: id, connectionId: "test", close: () => socket.destroy() };
  bridge.peers.add(localPort, peer);
  socket.once("close", () => bridge.peers.remove(localPort, peer));
  return connect(agentId, query, { socket, credential });
}

/** echo で 1 ターン回し、sessionId と最新 seq を返す。 */
async function echoTurn(query: string, text: string): Promise<{ sessionId: string; latestSeq: number }> {
  const client = await connect("echo", query);
  client.send({ type: "user_message", agentId: "echo", content: text, metadata: { clientMessageId: crypto.randomUUID() } });
  const started = await client.until((e) => e.type === "session_started");
  await client.until((e) => e.type === "done");
  const latestSeq = Math.max(...client.events.map((e) => e.seq ?? 0));
  await client.close();
  return { sessionId: started.sessionId!, latestSeq };
}

/** サーバ側で close イベント（購読解除）が処理されるのを待つ。 */
const settle = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 50));

test("/health・/status は無認証なら 401、Bearer 付きの /status?fresh=1 は 200", async () => {
  const base = `http://127.0.0.1:${port}`;
  assert.equal((await fetch(`${base}/health`)).status, 401);
  assert.equal((await fetch(`${base}/status`)).status, 401);
  assert.equal((await fetch(`${base}/status?fresh=1`)).status, 401);

  const status = await fetch(`${base}/status?fresh=1`, { headers: { Authorization: `Bearer ${API_KEY}` } });
  assert.equal(status.status, 200);
  const body = (await status.json()) as { ok: boolean; bridgeId: string };
  assert.equal(body.ok, true);
  assert.equal(body.bridgeId, BRIDGE_ID);

  // interrupt は injectMidTurn と切り離して広告する（echo は停止できない）。
  const health = await fetch(`${base}/health`, { headers: { Authorization: `Bearer ${API_KEY}` } });
  assert.equal(health.status, 200);
  const agents = ((await health.json()) as { agents: Array<{ id: string; capabilities: Record<string, boolean> }> }).agents;
  assert.equal(agents.find((a) => a.id === "echo")?.capabilities.interrupt, false);
  const injectable = agents.find((a) => a.id === "injectable")?.capabilities;
  assert.equal(injectable?.interrupt, true);
  assert.equal(injectable?.injectMidTurn, true);
  // supportsInterrupt だけのアダプタも interrupt=true（injectMidTurn は false のまま）
  const stoppable = agents.find((a) => a.id === "stoppable")?.capabilities;
  assert.equal(stoppable?.interrupt, true);
  assert.equal(stoppable?.injectMidTurn, false);
});

test("/health は protocol.json の health.required と windows の任意キーを送り、capabilities は windows のキーだけ", async () => {
  // e2e.test.ts と同じくリポジトリ直下の shared/ を読む。
  const protocolPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "protocol.json");
  const protocol = JSON.parse(fs.readFileSync(protocolPath, "utf8")) as {
    health: { required: string[]; optional: Record<string, { platforms: string[] }> };
    capabilities: { keys: Record<string, { platforms: string[] }> };
  };
  const res = await fetch(`http://127.0.0.1:${port}/health`, { headers: { Authorization: `Bearer ${API_KEY}` } });
  const body = (await res.json()) as Record<string, unknown> & {
    agents: Array<{ id: string; capabilities: Record<string, unknown> }>;
  };
  // relay は中継が無いときだけ載せる（このテストの Bridge は中継を持つ）。
  const conditional = new Set(["relay"]);
  const windowsOptional = Object.entries(protocol.health.optional)
    .filter(([k, v]) => v.platforms.includes("windows") && !conditional.has(k))
    .map(([k]) => k);
  assert.ok(!("relay" in body), "中継があるときは relay を載せない");
  for (const key of [...protocol.health.required, ...windowsOptional]) assert.ok(key in body, `/health に ${key} が無い`);
  assert.equal(typeof body.uptimeSeconds, "number");
  assert.ok(Number.isInteger(body.aliveSessions) && (body.aliveSessions as number) >= 0);

  const expectedCaps = Object.entries(protocol.capabilities.keys).filter(([, v]) => v.platforms.includes("windows")).map(([k]) => k).sort();
  for (const agent of body.agents) {
    assert.deepEqual(Object.keys(agent.capabilities).sort(), expectedCaps, `${agent.id} の capabilities のキー`);
    assert.ok(Array.isArray(agent.capabilities.efforts) && Array.isArray(agent.capabilities.modes));
  }
  // set_model_request で切り替えられないもの（echo・モック）は空。
  assert.deepEqual(body.agents.find((a) => a.id === "echo")?.capabilities.modes, []);
});

test("/health: 中継が設定されていないときだけ relay の案内を載せる（ほかのキーは変えない）", async () => {
  const get = async () =>
    (await (await fetch(`http://127.0.0.1:${port}/health`, { headers: { Authorization: `Bearer ${API_KEY}` } })).json()) as Record<string, unknown>;
  const withRelay = await get();
  assert.equal("relay" in withRelay, false);
  const saved = bridgeConfig.paseoRelayURL;
  bridgeConfig.paseoRelayURL = "";
  try {
    const without = await get();
    assert.deepEqual(Object.keys(without).filter((k) => k !== "relay").sort(), Object.keys(withRelay).sort());
    const relay = without.relay as { configured: boolean; hint: string };
    assert.equal(relay.configured, false);
    assert.match(relay.hint, /BUDDYOS_PASEO_RELAY_URL/);
  } finally {
    bridgeConfig.paseoRelayURL = saved;
  }
});

test("停止できないセッションへの interrupt と queue_user_message に unsupported_message を返さない", async () => {
  const { sessionId } = await echoTurn("", "stop");
  const client = await connect("echo", `&sessionId=${encodeURIComponent(sessionId)}`);
  await client.until((e) => e.type === "session_started");

  client.send({ type: "interrupt", agentId: "echo", sessionId });
  client.send({ type: "queue_user_message", agentId: "echo", sessionId, content: "later", metadata: { clientMessageId: "q-1" } });
  // 同じ接続の後続 ping の pong が届いた時点で、上の 2 件への応答（あれば）は届いている
  client.send({ type: "ping", agentId: "echo", sessionId });
  await client.until((e) => e.type === "pong");
  assert.deepEqual(client.events.filter((e) => e.type === "unsupported_message"), []);
  await client.close();
});

test("stop_task_request は stopTask を呼び、結果は頼んだ接続にだけ sendRaw で届く", async () => {
  const sender = await connect("stopper");
  sender.send({ type: "user_message", agentId: "stopper", content: "hi", metadata: { clientMessageId: crypto.randomUUID() } });
  await sender.until((e) => e.type === "done");
  const watcher = await connect("stopper", "&sessionId=stopper-1");
  await watcher.until((e) => e.type === "session_started");
  stopTaskCalls.length = 0;

  const requestId = crypto.randomUUID();
  sender.send({
    type: "stop_task_request", agentId: "stopper", sessionId: "stopper-1",
    metadata: { requestId, taskId: "subagents", rowId: "br1", epoch: "ep1" }
  });
  const result = await sender.until((e) => e.type === "stop_task_result");
  assert.deepEqual(stopTaskCalls, [{ taskId: "subagents", rowId: "br1", epoch: "ep1" }]);
  assert.equal(result.messageId, requestId);
  assert.deepEqual(result.metadata, { requestId, taskId: "subagents", ok: "1", reason: "stopped", rowId: "br1" });
  sender.send({ type: "ping", agentId: "stopper", sessionId: "stopper-1" });
  await sender.until((e) => e.type === "pong");
  watcher.send({ type: "ping", agentId: "stopper", sessionId: "stopper-1" });
  await watcher.until((e) => e.type === "pong");
  assert.deepEqual(watcher.events.filter((e) => e.type === "stop_task_result"), []);
  assert.deepEqual(sender.events.filter((e) => e.type === "error" || e.type === "unsupported_message"), []);

  // requestId か taskId が無い要求は捨てる（返事なし）
  sender.send({ type: "stop_task_request", agentId: "stopper", sessionId: "stopper-1", metadata: { taskId: "subagents" } });
  sender.send({ type: "ping", agentId: "stopper", sessionId: "stopper-1" });
  await settle();
  assert.equal(sender.events.filter((e) => e.type === "stop_task_result").length, 1);
  await sender.close();
  await watcher.close();
});

test("stop_task_request: stopTask の無い session は unsupported", async () => {
  const client = await connect("nostop");
  client.send({ type: "user_message", agentId: "nostop", content: "hi", metadata: { clientMessageId: crypto.randomUUID() } });
  await client.until((e) => e.type === "done");
  const requestId = crypto.randomUUID();
  client.send({ type: "stop_task_request", agentId: "nostop", sessionId: "nostop-1", metadata: { requestId, taskId: "subagents", rowId: "r", epoch: "e" } });
  const result = await client.until((e) => e.type === "stop_task_result");
  assert.equal(result.metadata?.ok, "0");
  assert.equal(result.metadata?.reason, "unsupported");
  assert.deepEqual(client.events.filter((e) => e.type === "error" || e.type === "unsupported_message"), []);
  await client.close();
});

test("stop_task_request: session が無いと turn status の応答の後に not_running を返す", async () => {
  const client = await connect("echo");
  const requestId = crypto.randomUUID();
  client.send({ type: "stop_task_request", agentId: "echo", sessionId: "no-such-session", metadata: { requestId, taskId: "subagents", rowId: "r", epoch: "e" } });
  const result = await client.until((e) => e.type === "stop_task_result");
  assert.equal(result.metadata?.ok, "1");
  assert.equal(result.metadata?.reason, "not_running");
  const doneAt = client.events.findIndex((e) => e.type === "done" && e.sessionId === "no-such-session");
  assert.ok(doneAt >= 0 && doneAt < client.events.indexOf(result), "turn status の done が先に届く");
  // 空の subagents の全行（新しい epoch）が done より先に届き、アプリが古い running の行を落とせる。
  const snapAt = client.events.findIndex((e) => e.type === "workflow_progress" && e.sessionId === "no-such-session");
  assert.ok(snapAt >= 0 && snapAt < doneAt, "空の全行が done より先に届く");
  const snap = parse(client.events[snapAt].content);
  assert.equal(snap.subtype, "workflow_snapshot");
  assert.equal(snap.taskId, "subagents");
  assert.equal(snap.kind, "subagents");
  assert.equal(snap.status, "completed");
  assert.deepEqual(snap.agents, []);
  assert.ok(typeof snap.epoch === "string" && snap.epoch.length > 0);
  await client.close();
});

test("stop_task_request: 行の stopped の payload は stop_task_result より先に接続へ届く（§3.3 規則 8）", async () => {
  let emitSession: Emit | undefined;
  bridge.adapters.set("stopemit", mockAdapter("stopemit", (sessionId) => ({
    sessionId: sessionId ?? "stopemit-1",
    async send(_text, _event, emit) {
      emitSession = emit;
      emit(event.sessionStarted("stopemit", "stopemit-1"));
      emit(event.done("stopemit", "stopemit-1", "m-1"));
    },
    async stopTask(req) {
      emitSession?.(event.workflowProgress("stopemit", "stopemit-1", JSON.stringify({
        subtype: "task_progress", taskId: req.taskId, kind: "subagents", status: "completed", epoch: req.epoch,
        agents: [{ index: 0, id: req.rowId, state: "stopped", stoppable: false }]
      })));
      return { kind: "stopped" };
    },
    async close() {}
  })));
  const client = await connect("stopemit");
  client.send({ type: "user_message", agentId: "stopemit", content: "hi", metadata: { clientMessageId: crypto.randomUUID() } });
  await client.until((e) => e.type === "done");
  client.events.length = 0;
  client.send({ type: "stop_task_request", agentId: "stopemit", sessionId: "stopemit-1", metadata: { requestId: "r-9", taskId: "subagents", rowId: "br9", epoch: "ep9" } });
  const result = await client.until((e) => e.type === "stop_task_result");
  const payloadAt = client.events.findIndex((e) => e.type === "workflow_progress" && (parse(e.content).agents as Array<{ state: string }> | undefined)?.[0]?.state === "stopped");
  assert.ok(payloadAt >= 0 && payloadAt < client.events.indexOf(result), "stopped の payload が先に届く");
  await client.close();
});

test("stop_task_request: stopTask が notRunning を返したときも返事の前に turn status を送る", async () => {
  const client = await connect("stopper");
  client.send({ type: "user_message", agentId: "stopper", content: "hi", metadata: { clientMessageId: crypto.randomUUID() } });
  await client.until((e) => e.type === "done");
  client.events.length = 0;
  client.send({ type: "stop_task_request", agentId: "stopper", sessionId: "stopper-1", metadata: { requestId: "r-1", taskId: "gone" } });
  const result = await client.until((e) => e.type === "stop_task_result");
  assert.equal(result.metadata?.reason, "not_running");
  assert.ok(client.events.findIndex((e) => e.type === "done") < client.events.indexOf(result));
  await client.close();
});

test("再接続の session_started に seq が無く、差分 replay は記録されず、続きを返せなければ全履歴に落ちる", async () => {
  const { sessionId, latestSeq } = await echoTurn("", "hi");
  const client = await connect("echo", `&sessionId=${encodeURIComponent(sessionId)}`);

  // (a) 接続時の session_started は採番しない
  const started = await client.until((e) => e.type === "session_started");
  assert.equal(started.seq, undefined);

  // (b) 2 回とも同じ 3 件が返り、replay は record されないので latestSeq は変わらない
  for (let i = 0; i < 2; i += 1) {
    client.events.length = 0;
    client.send({ type: "load_history_request", agentId: "echo", sessionId, metadata: { sinceSeq: String(latestSeq - 3) } });
    const end = await client.until((e) => e.type === "load_history_end");
    const replayed = client.events.filter((e) => e.type !== "load_history_end").map((e) => e.seq);
    assert.deepEqual(replayed, [latestSeq - 2, latestSeq - 1, latestSeq]);
    assert.equal(end.seq, latestSeq);
  }

  // (c) live buffer に無い sinceSeq（Bridge 再起動相当）は全履歴。ストアの番号体系を seq に混ぜない
  client.events.length = 0;
  client.send({ type: "load_history_request", agentId: "echo", sessionId, metadata: { sinceSeq: String(latestSeq + 100) } });
  const end = await client.until((e) => e.type === "load_history_end");
  const history = client.events.filter((e) => e.type === "history_message");
  assert.deepEqual(history.map((e) => e.content), ["hi", "echo: hi"]);
  assert.ok(history.every((e) => e.seq === undefined && e.metadata?.seq === undefined));
  assert.equal(end.seq, latestSeq);
  await client.close();
});

test("error だけで終わったターンの後、turn_status_request には done が返る", async () => {
  const client = await connect("failing");
  client.send({ type: "user_message", agentId: "failing", sessionId: "fail-1", content: "x", metadata: { clientMessageId: "f-1" } });
  const error = await client.until((e) => e.type === "error");
  assert.equal(error.metadata?.turnFailed, "true");

  client.send({ type: "turn_status_request", agentId: "failing", sessionId: "fail-1" });
  const probe = await client.until((e) => e.type === "done" || e.type === "turn_resume");
  assert.equal(probe.type, "done");
  await client.close();
});

test("metadata.pending の done は留め置き（ターンを終わらせない）、最後の done だけが終わらせる", async () => {
  const client = await connect("pendy");
  client.send({ type: "user_message", agentId: "pendy", content: "go", metadata: { clientMessageId: "p-1" } });
  const intermediate = await client.until((e) => e.type === "done" && e.messageId === "m-1");
  assert.equal(intermediate.metadata?.pending, "1");
  const mark = client.events.length;
  client.send({ type: "turn_status_request", agentId: "pendy", sessionId: "pendy-1" });
  const probe = await client.until((e) => client.events.indexOf(e) >= mark && (e.type === "done" || e.type === "turn_resume"));
  assert.equal(probe.type, "turn_resume", "中間の done ではターンは終わっていない");
  assert.equal(probe.metadata?.phase, "thinking", "確定済みの吹き出しを streaming に戻さない");
  assert.equal(probe.messageId, undefined);
  assert.equal(probe.content, "");
  releasePendy?.();
  const last = await client.until((e) => e.type === "done" && e.messageId === "m-2");
  assert.equal(last.metadata?.pending, undefined);
  await client.close();
});

test("origin = task-notification の done は、送信中の発話があれば Bridge が pending を刻んで留め置く", async () => {
  const client = await connect("pendy");
  client.send({ type: "user_message", agentId: "pendy", content: "notify", metadata: { clientMessageId: "p-2" } });
  const stamped = await client.until((e) => e.type === "done" && e.messageId === "m-1");
  assert.equal(stamped.metadata?.origin, "task-notification");
  assert.equal(stamped.metadata?.pending, "1");
  client.send({ type: "turn_status_request", agentId: "pendy", sessionId: "pendy-1" });
  const probe = await client.until((e) => e.type === "turn_resume");
  assert.equal(probe.type, "turn_resume");
  releasePendy?.();
  await client.until((e) => e.type === "done" && e.messageId === "m-2");
  await client.close();
});

test("cwd なしの接続の list_sessions は全 cwd のセッションを返す", async () => {
  const otherCwd = path.join(tmp, "other-cwd");
  const inDefault = await echoTurn("", "default");
  const inOther = await echoTurn(`&cwd=${encodeURIComponent(otherCwd)}`, "other");

  const listIds = async (query: string): Promise<string[]> => {
    const client = await connect("echo", query);
    client.send({ type: "list_sessions_request", agentId: "echo", metadata: { limit: "100" } });
    await client.until((e) => e.type === "session_list_end");
    await client.close();
    return client.events.filter((e) => e.type === "session_list_item").map((e) => e.sessionId!);
  };

  const all = await listIds("");
  assert.ok(all.includes(inDefault.sessionId));
  assert.ok(all.includes(inOther.sessionId));
  const filtered = await listIds(`&cwd=${encodeURIComponent(otherCwd)}`);
  assert.deepEqual(filtered, [inOther.sessionId]);
});

test("ターン途中に再接続した接続へ残りの出力が届き、live で届いた分は差分 replay で再送しない", async () => {
  const first = await connect("slow");
  first.send({ type: "user_message", agentId: "slow", content: "go", metadata: { clientMessageId: "s-1" } });
  await first.until((e) => e.type === "assistant_delta");
  await first.close();
  await settle();

  const second = await connect("slow", "&sessionId=slow-1");
  const resume = await second.until((e) => e.type === "turn_resume");
  assert.equal(resume.content, "before ");
  const snapshotSeq = Number(resume.metadata?.snapshotSeq);
  assert.ok(snapshotSeq > 0);

  // send() を呼んだ接続は閉じているが、出力は session の購読者（再接続した側）へ届く
  assert.ok(releaseSlow);
  releaseSlow();
  const done = await second.until((e) => e.type === "done");
  const after = second.events.find((e) => e.type === "assistant_delta" && e.content === "after");
  assert.ok(after, "reconnected client receives the rest of the turn");

  // sinceSeq をスナップショット直前にすると、replay は live で届けていない "before " だけになる
  second.events.length = 0;
  second.send({ type: "load_history_request", agentId: "slow", sessionId: "slow-1", metadata: { sinceSeq: String(snapshotSeq - 1) } });
  const end = await second.until((e) => e.type === "load_history_end");
  const replayed = second.events.filter((e) => e.type !== "load_history_end");
  assert.deepEqual(replayed.map((e) => e.seq), [snapshotSeq]);
  assert.equal(replayed[0].content, "before ");
  assert.equal(end.seq, done.seq);
  await second.close();
});

test("プロジェクトの追加・一覧が project_item… + projects_end で返る", async () => {
  const client = await connect("echo");
  client.send({ type: "add_project_request", agentId: "echo", metadata: { path: "C:\\work\\demo" } });
  await client.until((e) => e.type === "projects_end");
  const items = client.events.filter((e) => e.type === "project_item");
  assert.equal(items.length, 1);
  assert.equal(items[0].metadata?.name, "demo");
  assert.ok(Number(items[0].metadata?.addedAt) > 0);
  await client.close();
});

test("使用量: usage_request で読み直した usage_report が届く（未知のメッセージ扱いにしない）", async () => {
  const client = await connect("echo");
  client.send({ type: "usage_request" });
  const report = await client.until((e) => e.type === "usage_report", 10_000);
  const providers = (JSON.parse(report.content ?? "{}") as { providers: Array<{ provider: string }> }).providers.map((p) => p.provider);
  // Claude の使用量は BUDDYOS_CLAUDE_USAGE（既定値は officialDefaults.ts）が off なら一覧に出さない。
  const expected = resolveClaudeUsage().value ? ["claude", "codex"] : ["codex"];
  assert.deepEqual(providers.slice(0, expected.length), expected);
  assert.deepEqual(client.events.filter((e) => e.type === "unsupported_message"), []);
  await client.close();
});

test("サイト: sites_request は送った接続にだけ sites_report を返し、force=1 でキャッシュを使わない", async () => {
  // 実 CLI（vercel / wrangler）は動かさない。読み取りを差し替えて、呼ばれた回数を数える。
  let reads = 0;
  const original = bridge.services.sites;
  bridge.services.sites = new SitesService(async () => {
    reads++;
    return {
      hosts: [
        { host: "vercel", state: "ok", account: "me" },
        { host: "cloudflare", state: "missing" }
      ],
      items: [{ host: "vercel", name: `site-${reads}`, url: "https://site.vercel.app" }],
      at: "2026-10-20T00:00:00.000Z"
    };
  });
  try {
    const client = await connect("echo");
    const other = await connect("echo");
    client.send({ type: "sites_request", agentId: "echo" });
    const first = JSON.parse((await client.until((e) => e.type === "sites_report")).content ?? "{}") as SiteList;
    assert.deepEqual(first.hosts.map((h) => [h.host, h.state]), [["vercel", "ok"], ["cloudflare", "missing"]]);
    assert.equal(first.items[0].name, "site-1");

    // 5 分以内はキャッシュ、force=1 なら読み直す。
    client.send({ type: "sites_request", agentId: "echo" });
    client.send({ type: "sites_request", agentId: "echo", metadata: { force: "1" } });
    await client.until(() => client.events.filter((e) => e.type === "sites_report").length >= 3);
    assert.equal(reads, 2);

    await settle();
    assert.equal(other.events.filter((e) => e.type === "sites_report").length, 0, "ほかの接続には配らない");
    assert.deepEqual(client.events.filter((e) => e.type === "unsupported_message"), []);
    await client.close();
    await other.close();
  } finally {
    bridge.services.sites = original;
  }
});

test("定期チェック: heartbeat_get は送った接続にだけ返し、heartbeat_set は保存して全接続へ配る", async () => {
  const heartbeat = bridge.services.heartbeat;
  assert.ok(heartbeat);
  const before = heartbeat.settings;
  try {
    const client = await connect("echo");
    const other = await connect("echo");
    client.send({ type: "heartbeat_get", agentId: "echo" });
    const got = JSON.parse((await client.until((e) => e.type === "heartbeat_status")).content ?? "{}") as { settings: Record<string, unknown>; state: Record<string, unknown> };
    assert.deepEqual(got.settings, { enabled: true, intervalMinutes: 180, quietHours: { enabled: true, start: "22:00", end: "08:00" }, agentId: "claude", prompt: "" });
    assert.equal(typeof got.state, "object");
    await settle();
    assert.equal(other.events.filter((e) => e.type === "heartbeat_status").length, 0, "get はほかの接続には配らない");

    // 一部だけの設定。間隔は 30〜1440 に丸め、足りない項目は今の値のまま。
    client.send({ type: "heartbeat_set", agentId: "echo", content: JSON.stringify({ intervalMinutes: 5, quietHours: { enabled: false } }) });
    const pushed = JSON.parse((await other.until((e) => e.type === "heartbeat_status")).content ?? "{}") as { settings: { intervalMinutes: number; enabled: boolean; quietHours: { enabled: boolean; start: string } } };
    assert.equal(pushed.settings.intervalMinutes, 30);
    assert.equal(pushed.settings.enabled, true);
    assert.deepEqual(pushed.settings.quietHours, { enabled: false, start: "22:00", end: "08:00" });
    await client.until(() => client.events.filter((e) => e.type === "heartbeat_status").length >= 2);
    const saved = JSON.parse(fs.readFileSync(path.join(bridgeConfig.configDir, "heartbeat.json"), "utf8")) as { intervalMinutes: number };
    assert.equal(saved.intervalMinutes, 30);

    // mainagent のフォルダが無い Bridge では回さず、今の状態を返す。
    client.send({ type: "heartbeat_run_now", agentId: "echo" });
    await client.until(() => client.events.filter((e) => e.type === "heartbeat_status").length >= 3);
    assert.equal(heartbeat.isRunning, false);
    assert.deepEqual(client.events.filter((e) => e.type === "unsupported_message"), []);
    await client.close();
    await other.close();
  } finally {
    heartbeat.setSettings(before);
  }
});

test("/health: すべての agent の capabilities.heartbeat が true で、features に heartbeat がある", async () => {
  const res = await fetch(`http://127.0.0.1:${port}/health`, { headers: { Authorization: `Bearer ${API_KEY}` } });
  const body = (await res.json()) as { features: string[]; agents: Array<{ capabilities: Record<string, unknown> }> };
  assert.ok(body.features.includes("heartbeat"));
  assert.ok(body.agents.length > 0 && body.agents.every((a) => a.capabilities.heartbeat === true));
});

test("/health: すべての agent の capabilities.sites が true で、features に sites がある", async () => {
  const res = await fetch(`http://127.0.0.1:${port}/health`, { headers: { Authorization: `Bearer ${API_KEY}` } });
  const body = (await res.json()) as { features: string[]; agents: Array<{ capabilities: Record<string, unknown> }> };
  assert.ok(body.features.includes("sites"));
  assert.ok(body.agents.length > 0 && body.agents.every((a) => a.capabilities.sites === true));
});

test("ログイン状態の問い合わせは idle、未対応のエージェントの開始は failed(unsupported)", async () => {
  const client = await connect("echo");
  client.send({ type: "agent_login_request", agentId: "codex", metadata: { op: "status" } });
  const idle = await client.until((e) => e.type === "agent_login_status" && e.agentId === "codex");
  assert.deepEqual(idle.metadata, { phase: "idle", needsCode: "0" });
  client.send({ type: "agent_login_request", agentId: "echo", metadata: { op: "start" } });
  const failed = await client.until((e) => e.type === "agent_login_status" && e.agentId === "echo");
  assert.equal(failed.metadata?.message, "unsupported");
  await client.close();
});

test("cron: 非対応のエージェントは一覧が空で作成は失敗、結果の取得は jobId 必須", async () => {
  const client = await connect("echo");
  client.send({ type: "list_cron_jobs_request", agentId: "echo" });
  await client.until((e) => e.type === "cron_job_list_end");
  client.send({ type: "create_cron_request", agentId: "echo", content: "x", metadata: { schedule: "1h" } });
  const created = await client.until((e) => e.type === "cron_job_result");
  assert.equal(created.metadata?.ok, "0");
  client.send({ type: "cron_outputs_request", agentId: "echo" });
  const missing = await client.until((e) => e.type === "unsupported_message");
  assert.equal(missing.content, "cron_outputs_missing_job_id");
  await client.close();
});

test("拡張機能の共有の一覧が extensions_share_result で返る", async () => {
  const client = await connect("echo");
  client.send({ type: "extensions_share_request", agentId: "echo" });
  const result = await client.until((e) => e.type === "extensions_share_result", 10_000);
  assert.equal(result.metadata?.op, "list");
  assert.ok(Array.isArray((JSON.parse(result.content ?? "{}") as { items: unknown[] }).items));
  await client.close();
});

test("送信予約: 生成中は預かって queue_ack、ターンが終わると queue_dispatched して次のターンを送る", async () => {
  const sent: string[] = [];
  let release: (() => void) | undefined;
  bridge.adapters.set("queued", mockAdapter("queued", (sessionId) => {
    const session: AgentSession = {
      sessionId: sessionId ?? "queued-1",
      async send(text, _event, emit) {
        sent.push(text);
        emit(event.assistantDelta("queued", "queued-1", `m-${sent.length}`, text));
        if (sent.length === 1) await new Promise<void>((r) => (release = r));
        emit(event.done("queued", "queued-1", `m-${sent.length}`));
      },
      async close() {}
    };
    return session;
  }));
  const client = await connect("queued", "&sessionId=queued-1");
  client.send({ type: "user_message", agentId: "queued", sessionId: "queued-1", content: "one", metadata: { clientMessageId: "c-1" } });
  await client.until((e) => e.type === "assistant_delta" && e.content === "one");
  client.send({ type: "queue_user_message", agentId: "queued", sessionId: "queued-1", content: "two", metadata: { clientMessageId: "c-2" } });
  client.send({ type: "queue_user_message", agentId: "queued", sessionId: "queued-1", content: "three", metadata: { clientMessageId: "c-3" } });
  await client.until((e) => e.type === "queue_ack" && e.metadata?.clientMessageId === "c-3");
  client.send({ type: "queue_remove", agentId: "queued", sessionId: "queued-1", metadata: { clientMessageId: "c-3" } });
  // 3 件目の queue_state（c-3 を取り消した後）を待つ（1 件目も同じ中身なので数で見る）。
  await client.until(
    (e) =>
      e.type === "queue_state" &&
      e.content === JSON.stringify([{ clientMessageId: "c-2", content: "two" }]) &&
      client.events.filter((x) => x.type === "queue_state").length >= 3
  );
  assert.deepEqual(sent, ["one"], "生成中は送らない");
  release?.();
  await client.until((e) => e.type === "queue_dispatched" && e.metadata?.clientMessageId === "c-2");
  await client.until((e) => e.type === "done" && e.messageId === "m-2");
  assert.deepEqual(sent, ["one", "two"], "取り消した予約は送らない");
  await client.close();
});

test("送信予約: 空いているときはすぐ送る（queue_dispatched と input_ack）", async () => {
  const client = await connect("echo");
  client.send({ type: "queue_user_message", agentId: "echo", content: "now", metadata: { clientMessageId: "qn-1" } });
  await client.until((e) => e.type === "queue_dispatched" && e.metadata?.clientMessageId === "qn-1");
  await client.until((e) => e.type === "input_ack" && e.metadata?.clientMessageId === "qn-1");
  await client.until((e) => e.type === "done");
  await client.close();
});

test("ターミナル連携: hook の POST が claude の会話を見ている端末に届き、一覧では印付きで先頭に出る", async () => {
  const sid = "55555555-5555-4555-8555-555555555555";
  const post = (p: string, body: unknown, headers: Record<string, string> = {}) =>
    fetch(`http://127.0.0.1:${port}${p}`, {
      method: "POST",
      headers: { authorization: `Bearer ${API_KEY}`, "content-type": "application/json", ...headers },
      body: JSON.stringify(body)
    });
  assert.equal((await fetch(`http://127.0.0.1:${port}/claude/hook`, { method: "POST", body: "{}" })).status, 401);
  // Bridge が起こした claude の hook は受けない。
  assert.equal((await post("/claude/session-start", { session_id: sid }, { "X-Buddy-Spawned": "1" })).status, 202);
  const started = await post("/claude/session-start", { session_id: sid, cwd: "C:\\proj", pid: process.pid });
  assert.deepEqual(await started.json(), { ok: true, handedOver: false });

  const client = await connect("claude", `&sessionId=${sid}`);
  await client.until((e) => e.type === "session_started");
  await post("/claude/hook", { session_id: sid, hook_event_name: "UserPromptSubmit", prompt: "ターミナルから" });
  const hook = await post("/claude/hook", { session_id: sid, hook_event_name: "MessageDisplay", message_id: "m", delta: "返事" });
  assert.equal(hook.status, 200);
  assert.equal(await hook.text(), "", "hook の応答は空（TUI の選択肢を消さない）");
  await client.until((e) => e.type === "assistant_delta" && e.content === "返事");

  client.send({ type: "list_sessions_request", agentId: "claude" });
  await client.until((e) => e.type === "session_list_end");
  const first = client.events.find((e) => e.type === "session_list_item");
  assert.equal(first?.sessionId, sid);
  assert.equal(first?.metadata?.terminal, "1");
  assert.equal(first?.metadata?.running, "1", "ターン中");

  // iPhone から送ると、channel が無いので閲覧のみのエラーで返る（Bridge の claude は起こさない）。
  client.send({ type: "user_message", agentId: "claude", sessionId: sid, content: "続けて", metadata: { clientMessageId: "tm-1" } });
  const err = await client.until((e) => e.type === "error" && (e.content ?? "").includes("閲覧のみ"));
  assert.ok(err);

  await post("/claude/hook", { session_id: sid, hook_event_name: "Stop" });
  await client.until((e) => e.type === "done" && e.messageId !== undefined && client.events.some((x) => x.type === "assistant_delta" && x.messageId === e.messageId));
  assert.equal((await post("/claude/session-end", { session_id: sid })).status, 200);
  await client.close();
});

test("選択肢が出たままの session は list_sessions で awaiting になり、先へ進むと外れる", async () => {
  const sid = "77777777-7777-4777-8777-777777777777";
  const post = (body: unknown) =>
    fetch(`http://127.0.0.1:${port}/claude/hook`, {
      method: "POST",
      headers: { authorization: `Bearer ${API_KEY}`, "content-type": "application/json" },
      body: JSON.stringify({ session_id: sid, ...(body as object) })
    });
  const awaiting = async (): Promise<string | undefined> => {
    const client = await connect("claude");
    client.send({ type: "list_sessions_request", agentId: "claude" });
    await client.until((e) => e.type === "session_list_end");
    await client.close();
    return client.events.find((e) => e.type === "session_list_item" && e.sessionId === sid)?.metadata?.awaiting;
  };
  await post({ hook_event_name: "UserPromptSubmit", prompt: "消して" });
  assert.equal(await awaiting(), undefined, "選択肢が出るまでは付かない");
  await post({ hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: { command: "rm -rf x" } });
  assert.equal(await awaiting(), "1");
  await post({ hook_event_name: "PostToolUse", tool_name: "Bash" });
  assert.equal(await awaiting(), undefined, "ターミナルで答えて先へ進んだら外れる");
  await post({ hook_event_name: "Stop" });
});

test("ターミナル連携: ペインの状態とキー入力の long-poll", async () => {
  const get = (p: string) => fetch(`http://127.0.0.1:${port}${p}`, { headers: { authorization: `Bearer ${API_KEY}` } });
  const panes = (await (await get("/terminal/panes/poll?since=-1")).json()) as { version: number; panes: unknown[] };
  assert.equal(typeof panes.version, "number");
  const pending = get(`/terminal/panes/poll?since=${panes.version}`);
  await fetch(`http://127.0.0.1:${port}/claude/hook`, {
    method: "POST",
    headers: { authorization: `Bearer ${API_KEY}`, "content-type": "application/json", "X-BuddyOS-Pane": "pane-a" },
    body: JSON.stringify({ session_id: "66666666-6666-4666-8666-666666666666", hook_event_name: "UserPromptSubmit", prompt: "x" })
  });
  const changed = (await (await pending).json()) as { panes: Array<{ pane: string; state: string }> };
  assert.deepEqual(changed.panes.map((p) => [p.pane, p.state]), [["pane-a", "working"]]);
});

type TerminalDelivery = { pid: number; keys: string[]; gapMs: number; expectPid?: number; expectSession?: string };

/**
 * アプリ内ターミナルで動く claude への打ち込みを試す道具。デスクトップ（pty 424242。typing=1）の long-poll・hook の POST・
 * 台帳への登録・sessions/<pid>.json の status。claude の pid は生きているこのテストのプロセス。
 * 打ち込めるのは、その session の status が idle（か shell）と sessions のファイルで確かめられたときだけ。
 */
function terminalHarness(sid: string) {
  const pty = 424242;
  const base = `http://127.0.0.1:${port}`;
  const auth = { authorization: `Bearer ${API_KEY}` };
  const post = (p: string, body: Record<string, unknown>, headers: Record<string, string> = {}) =>
    fetch(`${base}${p}`, { method: "POST", headers: { ...auth, "content-type": "application/json", ...headers }, body: JSON.stringify({ session_id: sid, ...body }) });
  const hook = (name: string, extra: Record<string, unknown> = {}) => post("/claude/hook", { hook_event_name: name, ...extra });
  // デスクトップの long-poll（typing=1）。1 回の poll は 1 組の配達で返るので、次の配達の前に張り直す。
  const desktop = async (): Promise<TerminalDelivery[]> => {
    const res = await fetch(`${base}/terminal/keys/poll?client=srv-typing&pids=${pty}&panes=${encodeURIComponent(`pane-ty:${pty}`)}&typing=1`, { headers: auth });
    return ((await res.json()) as { items: TerminalDelivery[] }).items;
  };
  const until = async (pred: () => boolean, what: string): Promise<void> => {
    for (let i = 0; i < 300 && !pred(); i += 1) await new Promise((r) => setTimeout(r, 10));
    assert.ok(pred(), `timed out: ${what}`);
  };
  // 配られるはずのキーが来ないとき、long-poll の期限（25 秒）まで待たずに落とす。
  const within = async <T>(p: Promise<T>, what: string): Promise<T> => {
    let timer: NodeJS.Timeout | undefined;
    try {
      return await Promise.race([p, new Promise<never>((_, reject) => (timer = setTimeout(() => reject(new Error(`timed out: ${what}`)), 3000)))]);
    } finally {
      clearTimeout(timer);
    }
  };
  // 配られないことの確かめ（short な間だけ待つ）。
  const quiet = async (polled: Promise<unknown>, ms = 300): Promise<string> =>
    Promise.race([polled.then(() => "typed"), new Promise<string>((r) => setTimeout(() => r("quiet"), ms))]);
  const sessionsDir = path.join(fakeHome, ".claude", "sessions");
  const statusFile = path.join(sessionsDir, `${process.pid}.json`);
  const setStatus = (status: string): void => {
    fs.mkdirSync(sessionsDir, { recursive: true });
    fs.writeFileSync(statusFile, JSON.stringify({ pid: process.pid, sessionId: sid, status, startedAt: 1 }));
  };
  const registerTerminal = async (): Promise<void> => {
    // アプリ内ターミナル（ペイン pane-ty）で動く claude として台帳に載せる。pid は生きているこのテストのプロセス。
    assert.equal((await post("/claude/session-start", { cwd: "C:\\proj", pid: process.pid }, { "X-BuddyOS-Pane": "pane-ty" })).status, 200);
  };
  return { pty, post, hook, desktop, until, within, quiet, setStatus, registerTerminal, cleanup: () => fs.rmSync(statusFile, { force: true }) };
}

test("ターミナル連携: ペアリング済みの端末（.device）の発話と予約はアプリ内ターミナルに打ち込み、.local の WS・mainagent の送信（予約も）は打ち込まない", async (t) => {
  const sid = "99999999-9999-4999-8999-999999999999";
  const terminal = bridge.services.terminal!;
  const { pty, post, hook, desktop, until, within, quiet, setStatus, registerTerminal, cleanup } = terminalHarness(sid);
  setStatus("idle");
  t.after(cleanup);

  let polled = desktop();
  await until(() => terminal.keys.typingPtyForPane("pane-ty") === pty, "デスクトップが pty を名乗る");
  await registerTerminal();
  // 端末（iPhone）はペアリング済みの .device、デスクトップの会話画面や PC の中のプロセスは api-key の .local。
  const client = await connectAsDevice("claude", `&sessionId=${sid}`);
  await client.until((e) => e.type === "session_started");
  const local = await connect("claude", `&sessionId=${sid}`);
  await local.until((e) => e.type === "session_started");
  const mainagentEvents: SessionEvent[] = [];
  const sub = await bridge.mainagentHub.acquire("claude", sid, undefined, (evt) => mainagentEvents.push(evt));
  // 打ち込みに回らず受け箱へ回った送信（channel も受け箱も無いので、閲覧のみのエラーで返る）の数。
  const viewOnly = (): number => mainagentEvents.filter((e) => e.type === "error" && (e.content ?? "").includes("閲覧のみ")).length;
  const doneCount = (): number => client.events.filter((e) => e.type === "done").length;
  try {
    // .local の WS の user_message は打ち込まない（受け箱へ回る）。
    local.send({ type: "user_message", agentId: "claude", sessionId: sid, content: "ローカルの発話", metadata: { clientMessageId: "ty-l1" } });
    await until(() => viewOnly() === 1, ".local の発話が受け箱へ回った（閲覧のみ）");
    assert.equal(await quiet(polled), "quiet", ".local の発話には印が付かない");

    // 端末（.device）の user_message は打ち込む（受け箱には置かない）。キーには宛先の claude の pid（expectPid）と session id（expectSession）が付く。
    client.send({ type: "user_message", agentId: "claude", sessionId: sid, content: "テストを実行して", metadata: { clientMessageId: "ty-1" } });
    assert.deepEqual(await within(polled, "端末の user_message が打ち込まれる"), [
      { pid: pty, keys: typingKeys("テストを実行して"), gapMs: 500, expectPid: process.pid, expectSession: sid }
    ]);
    polled = desktop();

    // 打ち込んだ発話のターンが続いている間に、mainagent の送信と .local の予約と端末の予約が積まれる。
    assert.equal(sub.submit("ma-1", "mainagent の依頼"), "queued");
    local.send({ type: "queue_user_message", agentId: "claude", sessionId: sid, content: "ローカルの予約", metadata: { clientMessageId: "ty-lq1" } });
    await local.until((e) => e.type === "queue_ack" && e.metadata?.clientMessageId === "ty-lq1");
    client.send({ type: "queue_user_message", agentId: "claude", sessionId: sid, content: "予約した文", metadata: { clientMessageId: "ty-q1" } });
    await client.until((e) => e.type === "queue_ack" && e.metadata?.clientMessageId === "ty-q1");

    // ターンが終わると預かった順に送られる。mainagent の文と .local の予約は印が無いので打ち込まず（閲覧のみで返る）、
    // 端末の予約は予約したときの印が引き継がれて打ち込まれる。
    await hook("UserPromptSubmit", { prompt: "テストを実行して" });
    await hook("Stop");
    assert.deepEqual(
      await within(polled, "端末の予約が打ち込まれる"),
      [{ pid: pty, keys: typingKeys("予約した文"), gapMs: 500, expectPid: process.pid, expectSession: sid }],
      "最初に配られるのは端末の予約"
    );
    assert.ok(mainagentEvents.some((e) => e.type === "queue_dispatched" && e.metadata?.clientMessageId === "ma-1"));
    assert.equal(viewOnly(), 3, "mainagent の文と .local の予約は打ち込みに回らなかった");
    polled = desktop();

    // 予約のターンが終わった後、空いているときの mainagent の送信（submitExternal）も打ち込まない。
    await hook("UserPromptSubmit", { prompt: "予約した文" });
    const doneBefore = doneCount();
    await hook("Stop");
    await until(() => doneCount() > doneBefore, "予約のターンの終わり");
    const errors = viewOnly();
    assert.equal(sub.submit("ma-2", "空いているときの依頼"), "sent");
    await until(() => viewOnly() > errors, "mainagent の文が受け箱へ回った（閲覧のみ）");
    assert.equal(await quiet(polled), "quiet", "空いているときの mainagent の文にも印は付かない");

    // .local の予約も、空いていればすぐ送る（user_message と同じ流れ）。こちらにも印は付かない。
    local.send({ type: "queue_user_message", agentId: "claude", sessionId: sid, content: "空いているときのローカルの予約", metadata: { clientMessageId: "ty-lq2" } });
    await until(() => viewOnly() > errors + 1, ".local の予約が受け箱へ回った（閲覧のみ）");
    assert.equal(await quiet(polled), "quiet", "空いているときの .local の予約にも印は付かない");

    // 端末の予約も、空いていればすぐ送る（user_message と同じ流れ）。こちらは印が付いたまま打ち込まれる。
    client.send({ type: "queue_user_message", agentId: "claude", sessionId: sid, content: "空いているときの予約", metadata: { clientMessageId: "ty-q2" } });
    assert.deepEqual(await within(polled, "空いているときの予約が打ち込まれる"), [
      { pid: pty, keys: typingKeys("空いているときの予約"), gapMs: 500, expectPid: process.pid, expectSession: sid }
    ]);
  } finally {
    sub.release();
    await client.close();
    await local.close();
    // 張ったままの poll を返して片付ける（返さないと long-poll の待ちが残る）。
    void terminal.keys.poll("srv-typing", [pty], 1, new Map([["pane-ty", pty]]), true);
    await polled;
    await post("/claude/session-end", {});
  }

  // typing=1 を名乗らない古いデスクトップしか無いときは、端末の発話でも打ち込まず、今までどおり閲覧のみで返る。
  await registerTerminal();
  void terminal.keys.poll("srv-typing", [pty], 100, new Map([["pane-ty", pty]]));
  const old = await connectAsDevice("claude", `&sessionId=${sid}`);
  try {
    old.send({ type: "user_message", agentId: "claude", sessionId: sid, content: "古いデスクトップ", metadata: { clientMessageId: "ty-2" } });
    await old.until((e) => e.type === "error" && (e.content ?? "").includes("閲覧のみ"));
  } finally {
    await old.close();
    await post("/claude/session-end", {});
  }
});

test("ターミナル連携: 打ち込みの印は .device の WS の発話だけ。api-key の .local の WS の user_message・queue_user_message は印が付かず受け箱へ回る", async (t) => {
  const sid = "abababab-abab-4bab-8bab-abababababab";
  const terminal = bridge.services.terminal!;
  const { pty, post, desktop, until, within, quiet, setStatus, registerTerminal, cleanup } = terminalHarness(sid);
  setStatus("idle");
  t.after(cleanup);
  const polled = desktop();
  await until(() => terminal.keys.typingPtyForPane("pane-ty") === pty, "デスクトップが pty を名乗る");
  await registerTerminal();
  const local = await connect("claude", `&sessionId=${sid}`);
  const device = await connectAsDevice("claude", `&sessionId=${sid}`);
  const viewOnly = (c: Client): number => c.events.filter((e) => e.type === "error" && (e.content ?? "").includes("閲覧のみ")).length;
  try {
    await local.until((e) => e.type === "session_started");
    await device.until((e) => e.type === "session_started");
    // .local: user_message も、空いているときの queue_user_message も、打ち込まない（このプロセスは本人の入力にならない）。
    local.send({ type: "user_message", agentId: "claude", sessionId: sid, content: "api-key で送った発話", metadata: { clientMessageId: "pr-1" } });
    await until(() => viewOnly(local) === 1, "user_message が受け箱へ回った（閲覧のみ）");
    local.send({ type: "queue_user_message", agentId: "claude", sessionId: sid, content: "api-key で送った予約", metadata: { clientMessageId: "pr-2" } });
    await until(() => viewOnly(local) === 2, "queue_user_message が受け箱へ回った（閲覧のみ）");
    assert.equal(await quiet(polled), "quiet", ".local の発話には印が付かない");
    await until(() => viewOnly(device) === 2, "同じ session の購読者には、どちらも閲覧のみで届く");

    // .device: 同じ session への同じ種類の送信は打ち込まれる。
    device.send({ type: "user_message", agentId: "claude", sessionId: sid, content: "端末で打った発話", metadata: { clientMessageId: "pr-3" } });
    assert.deepEqual(await within(polled, ".device の user_message が打ち込まれる"), [
      { pid: pty, keys: typingKeys("端末で打った発話"), gapMs: 500, expectPid: process.pid, expectSession: sid }
    ]);
    assert.equal(viewOnly(local), 2, "端末の発話は受け箱へ回らない");
  } finally {
    await local.close();
    await device.close();
    void terminal.keys.poll("srv-typing", [pty], 1, new Map([["pane-ty", pty]]), true);
    await polled;
    await post("/claude/session-end", {});
  }
});

test("通信量（件数とバイト数だけ）と通知のテスト送信", async () => {
  const get = (p: string, method = "GET") => fetch(`http://127.0.0.1:${port}${p}`, { method, headers: { authorization: `Bearer ${API_KEY}` } });
  assert.equal((await fetch(`http://127.0.0.1:${port}/traffic`)).status, 401);
  const client = await connect("echo");
  client.send({ type: "ping", agentId: "echo" });
  await client.until((e) => e.type === "pong");
  const snap = (await (await get("/traffic")).json()) as { totalMessages: number; buckets: Record<string, { messages: number; bytes: number }> };
  assert.ok(snap.buckets["ws.in.ping"].messages >= 1);
  const reset = (await (await get("/traffic/reset", "POST")).json()) as { totalMessages: number };
  assert.equal(reset.totalMessages, 0);
  const push = (await (await get("/push-test")).json()) as { ok: boolean; error: string | null };
  assert.equal(push.ok, false);
  assert.match(push.error ?? "", /not configured/);
  await client.close();
});

/** 任意の Host / Origin を付けた HTTP 要求（fetch は Host を差し替えられないので http.request を使う）。 */
function rawStatus(p: string, headers: Record<string, string>, method = "GET"): Promise<number> {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: "127.0.0.1", port, path: p, method, headers }, (res) => {
      res.resume();
      resolve(res.statusCode ?? 0);
    });
    r.on("error", reject);
    r.end();
  });
}

/** WebSocket の upgrade を送り、101 で開けたら 101、断られたらその番号を返す。 */
function upgradeStatus(p: string, headers: Record<string, string>): Promise<number> {
  return new Promise((resolve, reject) => {
    const r = http.request({
      host: "127.0.0.1",
      port,
      path: p,
      headers: { Connection: "Upgrade", Upgrade: "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": crypto.randomBytes(16).toString("base64"), ...headers }
    });
    r.on("upgrade", (_res, socket) => {
      socket.destroy();
      resolve(101);
    });
    r.on("response", (res) => {
      res.resume();
      resolve(res.statusCode ?? 0);
    });
    r.on("error", reject);
    r.end();
  });
}

test("Origin / Host の関門: ブラウザ由来の Origin と 127.0.0.1 以外の Host は認証より前に 403、デスクトップの画面は通す", async () => {
  const self = `127.0.0.1:${port}`;
  const auth = { authorization: `Bearer ${API_KEY}` };
  const badOrigins = ["null", `http://${self}`, `http://localhost:${port}`, "http://localhost:3000", "file://", "https://evil.example"];

  // HTTP: /status・/health・/traffic・/claude/*・/terminal/*
  for (const p of ["/status", "/health", "/traffic", "/claude/terminal/sessions", "/terminal/keys/poll?pids=1"]) {
    for (const origin of badOrigins) {
      assert.equal(await rawStatus(p, { ...auth, host: self, origin }), 403, `${p} ${origin}`);
    }
    assert.equal(await rawStatus(p, { ...auth, host: `rebind.example:${port}` }), 403, `${p} host`);
  }
  assert.equal(await rawStatus("/traffic/reset", { ...auth, host: self, origin: "null" }, "POST"), 403);
  // 正規化すると /status になる /preview/.. も関門を通さない
  assert.equal(await rawStatus("/preview/../status", { ...auth, host: self, origin: "null" }), 403);
  // Origin なし（iPhone / Android / hook）とデスクトップの画面は通る。Host は番号が違っても 127.0.0.1 / localhost なら通る（中継経由）
  assert.equal(await rawStatus("/status", { ...auth, host: self }), 200);
  assert.equal(await rawStatus("/status", { ...auth, host: self, origin: "buddyos-desktop://app" }), 200);
  assert.equal(await rawStatus("/status", { ...auth, host: "localhost:61234" }), 200);
  // 関門を通っても認証は必要
  assert.equal(await rawStatus("/status", { host: self, origin: "buddyos-desktop://app" }), 401);
  // /preview/* は対象外（Origin が付いていても 403 にしない）
  assert.notEqual(await rawStatus("/preview/ui", { host: self, origin: `http://${self}` }), 403);

  // WebSocket: /ws/agent と /terminal/pty
  const ws = `/ws/agent/echo?apiKey=${API_KEY}`;
  for (const origin of badOrigins) {
    assert.equal(await upgradeStatus(ws, { host: self, origin }), 403, `ws ${origin}`);
    assert.equal(await upgradeStatus(`/terminal/pty?id=x&apiKey=${API_KEY}`, { host: self, origin }), 403, `pty ${origin}`);
  }
  assert.equal(await upgradeStatus(ws, { host: `rebind.example:${port}` }), 403);
  assert.equal(await upgradeStatus(ws, { host: self }), 101);
  assert.equal(await upgradeStatus(ws, { host: self, origin: "buddyos-desktop://app" }), 101);
  assert.equal(await upgradeStatus(`/ws/agent/echo?apiKey=wrong`, { host: self }), 401);
  await settle();
});

test("apiKey の照合: Bearer とクエリのどちらでも、違う値・長さ違いは 401", async () => {
  const self = `127.0.0.1:${port}`;
  assert.equal(await rawStatus("/status", { host: self, authorization: `Bearer ${API_KEY}x` }), 401);
  assert.equal(await rawStatus("/status", { host: self, authorization: `Bearer ${API_KEY.slice(0, -1)}` }), 401);
  assert.equal(await rawStatus("/status", { host: self, authorization: "" }), 401);
  assert.equal(await rawStatus(`/status?apiKey=${API_KEY}`, { host: self }), 200);
  assert.equal(await rawStatus("/status?apiKey=", { host: self }), 401);
});

test("名前の付け替えは全エージェント共通の記録に残り、一覧に重なる（記録を持たない会話でも）", async () => {
  const listed = [{ sessionId: "r-1", title: "元の名前", lastActive: new Date().toISOString() }];
  bridge.adapters.set("renamable", {
    ...mockAdapter("renamable", (sessionId) => ({ sessionId: sessionId ?? "r-1", async send() {}, async close() {} })),
    listSessions: async () => listed
  });
  const client = await connect("renamable");
  client.send({ type: "rename_session_request", agentId: "renamable", sessionId: "r-1", content: "  新しい名前 " });
  const result = await client.until((e) => e.type === "rename_session_result");
  assert.equal(result.content, "新しい名前");
  assert.notEqual(result.metadata?.ok, "false");
  client.send({ type: "list_sessions_request", agentId: "renamable" });
  const item = await client.until((e) => e.type === "session_list_item");
  assert.match(JSON.stringify(item), /新しい名前/);
  // 再起動しても残る（ファイルに書いてある）
  const saved = JSON.parse(fs.readFileSync(path.join(tmp, "config", "session-overrides.json"), "utf8"));
  assert.equal(saved["renamable:r-1"].title, "新しい名前");
  // 空の名前で付け替えを外す
  client.send({ type: "rename_session_request", agentId: "renamable", sessionId: "r-1", content: "" });
  await client.until((e) => e.type === "rename_session_result" && e.content === "");
  client.events.length = 0;
  client.send({ type: "list_sessions_request", agentId: "renamable" });
  const again = await client.until((e) => e.type === "session_list_item");
  assert.match(JSON.stringify(again), /元の名前/);
  await client.close();
  await settle();
});

test("チャットの上書き（chatOverrides=1）を送信の前に session へ渡し、印の無い送信では触らない", async () => {
  const applied: unknown[] = [];
  bridge.adapters.set("overridable", mockAdapter("overridable", (sessionId) => {
    const session: AgentSession = {
      sessionId: sessionId ?? "o-1",
      applyOverrides: (o) => applied.push(o),
      async send(_text, _event, emit) {
        emit(event.sessionStarted("overridable", session.sessionId));
        emit(event.done("overridable", session.sessionId, crypto.randomUUID()));
      },
      async close() {}
    };
    return session;
  }));
  const client = await connect("overridable");
  client.send({
    type: "user_message",
    agentId: "overridable",
    content: "計画だけ",
    metadata: { clientMessageId: crypto.randomUUID(), chatOverrides: "1", chatMode: "Plan", chatModel: "m-1", chatEffort: "high" }
  });
  await client.until((e) => e.type === "done");
  assert.deepEqual(applied, [{ model: "m-1", provider: undefined, reasoningEffort: "high", mode: "plan" }]);
  client.events.length = 0;
  client.send({ type: "user_message", agentId: "overridable", sessionId: "o-1", content: "古いアプリ", metadata: { clientMessageId: crypto.randomUUID() } });
  await client.until((e) => e.type === "done");
  assert.equal(applied.length, 1, "印の無い送信は上書きを変えない");
  await client.close();
  await settle();
});

/* ── バックグラウンドの作業（docs/BACKGROUND_WORK_2026-10-21.md §3.1・§3.5。mac の WorkflowCardMirrorTests・SessionHubBackgroundTests と同じ規則） ── */

const parse = (json: string | undefined): Record<string, unknown> => JSON.parse(json ?? "{}") as Record<string, unknown>;
const rowIds = (json: string | undefined): string[] => ((parse(json).agents as Array<{ id: string }> | undefined) ?? []).map((a) => a.id);

test("カードの写し: 動いているサブエージェント・コマンド・終わっていない workflow を数える（コマンドだけならスリープ抑止・push 待ちにしない）", () => {
  const t = new SubagentTracker();
  const m = new WorkflowCardMirror();
  m.apply(t.begin("a1", "Explore auth", { agentType: "Explore", background: true }));
  m.apply(t.begin("b1", "npm run dev", { background: true, rowKind: "shell", tool: "Bash", command: "npm run dev" }));
  m.apply('{"subtype":"task_started","taskId":"wf1","workflowName":"review","status":"running"}');
  assert.deepEqual(m.counts, { agents: 1, backgroundOnlyAgents: 1, shells: 1, workflows: 1 });
  assert.equal(agentsOrWorkflows(m.counts), true);

  m.apply(t.finish("a1", "done", "見つかりました"));
  m.apply('{"subtype":"task_notification","taskId":"wf1","status":"completed"}');
  assert.deepEqual(m.counts, { agents: 0, backgroundOnlyAgents: 0, shells: 1, workflows: 0 });
  assert.equal(anyBackground(m.counts), true, "バックグラウンドのコマンドだけでも閉じない");
  assert.equal(agentsOrWorkflows(m.counts), false, "コマンドだけではスリープ抑止・push 待ちにしない");

  // 止まった workflow は終わり（outcome も残す）。status の無い workflow は動いているとみなし、行は届いた項目だけを上書きする。
  m.apply('{"subtype":"task_started","taskId":"wf2","workflowName":"audit","status":"running"}');
  m.apply('{"subtype":"task_updated","taskId":"wf2","status":"failed","outcome":"stopped"}');
  assert.equal(m.counts.workflows, 0);
  assert.equal(parse(m.snapshotJSON("wf2")).outcome, "stopped");
  m.apply('{"subtype":"task_progress","taskId":"wf3","agents":[{"index":0,"label":"phase 1","state":"running","model":"haiku"}]}');
  m.apply('{"subtype":"task_progress","taskId":"wf3","agents":[{"index":0,"state":"done"}]}');
  assert.equal(m.counts.workflows, 1);
  assert.deepEqual((parse(m.snapshotJSON("wf3")).agents as unknown[])[0], { index: 0, label: "phase 1", state: "done", model: "haiku" });
});

test("カードの写し: epoch が変われば前の世代の行を捨て、workflow_snapshot は行を丸ごと置き換え、再開した行は置き換える", () => {
  const old = new SubagentTracker();
  const m = new WorkflowCardMirror();
  m.apply(old.begin("a1", "old 1", { background: true }));
  m.apply(old.begin("a2", "old 2", { background: true }));
  assert.equal(m.counts.agents, 2);
  // 作り直したトラッカー（epoch が違う）の index 0 は、前の世代の index 0 と混ぜない。
  const fresh = new SubagentTracker();
  m.apply(fresh.begin("n1", "new", { background: true }));
  assert.equal(m.subagentsEpoch, fresh.epoch);
  assert.deepEqual(rowIds(m.subagentsSnapshot()), ["n1"]);
  // workflow_snapshot は行を丸ごと置き換える（agents: [] なら行が無い）。
  fresh.finish("n1", "stopped");
  fresh.pruneFinished();
  m.apply(fresh.snapshot({ includeEmpty: true }));
  assert.equal(m.hasSubagents, true);
  assert.deepEqual(rowIds(m.subagentsSnapshot()), []);
  assert.deepEqual(m.counts, { agents: 0, backgroundOnlyAgents: 0, shells: 0, workflows: 0 });

  // 再開（同じ key の begin）。行は毎回全項目なので置き換え、前の実行の結果を残さない。
  const t = new SubagentTracker();
  const r = new WorkflowCardMirror();
  r.apply(t.begin("a1", "x", { background: true }));
  r.apply(t.finish("a1", "done", "1 回目の結果"));
  assert.equal((parse(r.subagentsSnapshot()).agents as Array<Record<string, unknown>>)[0].result, "1 回目の結果");
  r.apply(t.begin("a1", "x", { background: true }));
  const row = (parse(r.subagentsSnapshot()).agents as Array<Record<string, unknown>>)[0];
  assert.deepEqual([row.state, row.result, row.endedAtMs], ["running", "", undefined]);
});

test("カードの写し: 全行は kind・epoch を持ち status を数え直す。古い Bridge の payload も subagents とみなす", () => {
  const t = new SubagentTracker();
  const m = new WorkflowCardMirror();
  m.apply(t.begin("a1", "x", { background: true }));
  m.apply(t.finish("a1", "failed", "exit code 3"));
  const snap = parse(m.subagentsSnapshot());
  assert.deepEqual([snap.subtype, snap.taskId, snap.kind, snap.epoch, snap.status], ["workflow_snapshot", "subagents", "subagents", t.epoch, "failed"]);

  const legacy = new WorkflowCardMirror();
  legacy.apply('{"subtype":"task_progress","taskId":"subagents","status":"running","agents":[{"index":0,"label":"x","state":"running"}]}');
  assert.equal(parse(legacy.subagentsSnapshot()).kind, "subagents");
  assert.equal(legacy.counts.agents, 1);
  assert.deepEqual(legacy.workflowSnapshots(false), [], "subagents は workflow として再生しない");

  // session の全行から、世代と動いている行の数を読む。
  const s = new SubagentTracker();
  s.begin("a1", "x", { background: true });
  s.begin("s1", "dev", { background: true, rowKind: "shell" });
  s.begin("a2", "y", { background: true });
  s.finish("a2", "done");
  assert.deepEqual(WorkflowCardMirror.rowCounts(s.snapshot({ includeEmpty: true })!), { epoch: s.epoch, agents: 1, shells: 1 });
  assert.equal(WorkflowCardMirror.rowCounts('{"subtype":"workflow_snapshot","taskId":"wf","agents":[]}'), undefined);
  assert.equal(WorkflowCardMirror.rowCounts("not json"), undefined);
});

test("カードの写し: done はサブエージェントのカードと終わっていない workflow を残し、新しいターンで終わった行と workflow を捨てる", () => {
  const t = new SubagentTracker();
  const m = new WorkflowCardMirror();
  m.apply(t.begin("a1", "動いている", { background: true }));
  m.apply(t.begin("a2", "終わった", { background: true }));
  m.apply(t.finish("a2", "done", "ok"));
  m.apply('{"subtype":"task_started","taskId":"wf-done","workflowName":"a"}');
  m.apply('{"subtype":"task_notification","taskId":"wf-done","status":"completed"}');
  m.apply('{"subtype":"task_started","taskId":"wf-live","workflowName":"b"}');
  assert.deepEqual(m.workflowSnapshots(true).map((j) => parse(j).taskId), ["wf-live"], "アイドルでは終わっていないものだけ再生する");
  assert.deepEqual(m.workflowSnapshots(false).map((j) => parse(j).taskId), ["wf-done", "wf-live"]);

  // ターンの終わり（done）: 終わった workflow だけを捨てる。subagents の終わった行は知らせのターンまで残す。
  m.dropFinishedWorkflows();
  assert.deepEqual(rowIds(m.subagentsSnapshot()), ["a1", "a2"]);
  assert.deepEqual(m.workflowSnapshots(false).map((j) => parse(j).taskId), ["wf-live"]);
  // 新しいターン: 終わった行を捨て、動いている行と終わっていない workflow は残す。
  m.pruneFinished();
  assert.deepEqual(rowIds(m.subagentsSnapshot()), ["a1"]);
  assert.deepEqual(m.counts, { agents: 1, backgroundOnlyAgents: 1, shells: 0, workflows: 1 });
});

test("カードの写し: backgroundOnlyAgents は動いていて background == true の agent 行だけ（前景の行・コマンドは数えない）", () => {
  const t = new SubagentTracker();
  const m = new WorkflowCardMirror();
  m.apply(t.begin("fg", "前景", { background: false }));
  m.apply(t.begin("bg", "裏", { background: true }));
  m.apply(t.begin("sh", "npm run dev", { background: true, rowKind: "shell", command: "npm run dev" }));
  assert.deepEqual(m.counts, { agents: 2, backgroundOnlyAgents: 1, shells: 1, workflows: 0 });
  m.apply(t.finish("bg", "done"));
  assert.equal(m.counts.backgroundOnlyAgents, 0);
});

test("カードの写し: lastFinished は apply で終わった agent 行と workflow（apply のたびに上書き）", () => {
  const t = new SubagentTracker();
  const m = new WorkflowCardMirror();
  m.apply(t.begin("a1", "裏", { background: true }));
  m.apply(t.begin("a2", "前景", { background: false }));
  m.apply(t.begin("sh", "dev", { background: true, rowKind: "shell" }));
  assert.deepEqual(m.lastFinished, []);
  m.apply(t.finish("a1", "done"));
  assert.deepEqual(m.lastFinished, [{ state: "done", background: true }]);
  m.apply(t.finish("a2", "failed"));
  assert.deepEqual(m.lastFinished, [{ state: "failed", background: false }]);
  m.apply(t.finish("sh", "stopped"));
  assert.deepEqual(m.lastFinished, [], "shell の行は数えない");
  m.apply(t.begin("a3", "また動く", { background: true }));
  assert.deepEqual(m.lastFinished, []);

  // epoch が変わったら、前に動いていた agent 行は stopped。
  const fresh = new SubagentTracker();
  m.apply(fresh.begin("n1", "新しい世代", { background: true }));
  assert.deepEqual(m.lastFinished, [{ state: "stopped", background: true }]);
  // workflow_snapshot で消えたものも stopped。
  fresh.finish("n1", "stopped");
  fresh.pruneFinished();
  m.apply(fresh.begin("n2", "もう 1 つ", { background: false }));
  m.apply(fresh.snapshot({ includeEmpty: true }));
  assert.deepEqual(m.lastFinished, [{ state: "stopped", background: true }], "写しだけに残っていた n1");

  // dynamic workflow: 終わっていなかったカードが終わったら 1 つ（いつも background）。stopped・failed・それ以外。
  const w = new WorkflowCardMirror();
  w.apply('{"subtype":"task_started","taskId":"w1","workflowName":"a","status":"running"}');
  w.apply('{"subtype":"task_started","taskId":"w2","workflowName":"b","status":"running"}');
  w.apply('{"subtype":"task_started","taskId":"w3","workflowName":"c","status":"running"}');
  assert.deepEqual(w.lastFinished, []);
  w.apply('{"subtype":"task_updated","taskId":"w1","status":"failed","outcome":"stopped"}');
  assert.deepEqual(w.lastFinished, [{ state: "stopped", background: true }]);
  w.apply('{"subtype":"task_updated","taskId":"w2","status":"failed"}');
  assert.deepEqual(w.lastFinished, [{ state: "failed", background: true }]);
  w.apply('{"subtype":"task_notification","taskId":"w3","status":"completed"}');
  assert.deepEqual(w.lastFinished, [{ state: "done", background: true }]);
  w.apply('{"subtype":"task_updated","taskId":"w3","status":"completed"}');
  assert.deepEqual(w.lastFinished, [], "もう終わっているカードは数え直さない");
});

test("LiveHistoryIndex.onFinished: 生成中は background の分だけ、生成中でなければ全部。release は数えていた分を stopped にする", () => {
  const got: Array<{ done: number; failed: number; stopped: number }> = [];
  const idx = new LiveHistoryIndex();
  idx.onFinished = (f) => got.push(f);
  const t = new SubagentTracker();
  const payload = (json: string | undefined): SessionEvent => ({ type: "workflow_progress", agentId: "codex", sessionId: "s1", content: json });
  const turnStart = (): SessionEvent => event.assistantDelta("codex", "s1", "m", "x");
  idx.record(payload(t.begin("a1", "裏", { background: true })));
  idx.record(payload(t.begin("a2", "前景", { background: false })));
  idx.record(turnStart());
  assert.equal(idx.inTurn("codex", "s1"), true);
  // ターン中: 前景の行の完了は数えない。
  idx.record(payload(t.finish("a2", "done")));
  assert.equal(got.length, 0);
  idx.record(payload(t.finish("a1", "failed")));
  assert.deepEqual(got, [{ done: 0, failed: 1, stopped: 0 }]);
  // ターンが終わったら全部を数える。
  idx.record(event.done("codex", "s1", "m"));
  assert.equal(idx.inTurn("codex", "s1"), false);
  idx.record(payload(t.begin("a3", "x", { background: false })));
  idx.record(payload(t.finish("a3", "done")));
  assert.deepEqual(got.at(-1), { done: 1, failed: 0, stopped: 0 });
  // release: 動いているままの行（ターン外は agent 全部）を stopped にする。閉じ済みなら何も渡さない。
  idx.record(payload(t.begin("a4", "x", { background: false })));
  idx.record(payload('{"subtype":"task_started","taskId":"wf","workflowName":"w","status":"running"}'));
  const n = got.length;
  idx.release("codex", "s1");
  assert.deepEqual(got.slice(n), [{ done: 0, failed: 0, stopped: 2 }]);
  const none = new LiveHistoryIndex();
  none.onFinished = (f) => got.push(f);
  const m = got.length;
  none.record({ type: "workflow_progress", agentId: "codex", sessionId: "s2", content: new SubagentTracker().snapshot({ includeEmpty: true }) });
  none.release("codex", "s2");
  assert.equal(got.length, m);
});

test("完了の push の本文は、そのターンの最後の空でない吹き出しの頭（前置きではなく結論）", () => {
  const delta = (mid: string, text: string): SessionEvent => event.assistantDelta("claude", "s", mid, text);
  const done = (mid: string): SessionEvent => event.done("claude", "s", mid);
  assert.equal(lastTurnBubble([]), undefined);
  const turn = [
    delta("m0", "前のターンの結論"),
    done("m0"),
    delta("m1", "Explore エージェントで"),
    delta("m1", "関連ファイルを調べます。"),
    delta("m2", "\n原因は X でした。修正案: …"),
    delta("m3", " \n "),
    done("m3")
  ];
  assert.equal(lastTurnBubble(turn), "原因は X でした。修正案: …", "空白だけの吹き出しは飛ばし、前のターンの本文は使わない");
  assert.equal(lastTurnBubble([done("m0"), delta("m4", "あ".repeat(300)), done("m4")]), "あ".repeat(180));
  assert.equal(lastTurnBubble([done("m0"), done("m1")]), undefined, "本文の無いターン");
  const big = Array.from({ length: 50 }, () => delta("m1", "a".repeat(1000)));
  assert.ok((lastTurnBubble([...big, done("m1")], Number.MAX_SAFE_INTEGER)?.length ?? 0) <= 8 * 1024 + 1000, "長い本文を抱え込まない");
});

test("バックグラウンドの作業: 接続と turn_status_request でサブエージェントの全行を送り、一覧に background を載せる", async () => {
  const tracker = new SubagentTracker();
  const sid = "bg-1";
  bridge.adapters.set("bgagent", {
    ...mockAdapter("bgagent", (sessionId) => {
      const session = {
        sessionId: sessionId ?? sid,
        async send(text: string, _event: SessionEvent, emit: Emit) {
          if (text === "launch") {
            emit(event.workflowProgress("bgagent", sid, tracker.begin("a1", "調査", { agentType: "Explore", background: true })!));
            emit(event.assistantDelta("bgagent", sid, "m1", "サブエージェントで調べます。"));
            emit(event.assistantDelta("bgagent", sid, "m2", "起動しました"));
            emit(event.done("bgagent", sid, "m2"));
          } else {
            emit(event.workflowProgress("bgagent", sid, tracker.finish("a1", "done", "見つけた")!));
            emit(event.assistantDelta("bgagent", sid, "m3", "見つけました"));
            emit(event.done("bgagent", sid, "m3"));
          }
        },
        subagentSnapshot: async () => tracker.snapshot({ includeEmpty: true }),
        async close() {}
      };
      return session as AgentSession;
    }),
    listSessions: async () => [{ sessionId: sid, title: "bg", lastActive: new Date().toISOString() }]
  });
  const background = async (client: Client): Promise<string | undefined> => {
    client.events.length = 0;
    client.send({ type: "list_sessions_request", agentId: "bgagent" });
    await client.until((e) => e.type === "session_list_end");
    return client.events.find((e) => e.type === "session_list_item" && e.sessionId === sid)?.metadata?.background;
  };
  const first = await connect("bgagent", `&sessionId=${sid}`);
  first.send({ type: "user_message", agentId: "bgagent", sessionId: sid, content: "launch", metadata: { clientMessageId: "bg-c1" } });
  await first.until((e) => e.type === "done" && e.messageId === "m2");
  assert.equal(await background(first), "1", "ターンが終わってもバックグラウンドの作業がある");

  // 後から開いた端末: アイドルでも全行を受け取る（行は backlog に残らない）。
  const second = await connect("bgagent", `&sessionId=${sid}`);
  const snap = await second.until((e) => e.type === "workflow_progress" && parse(e.content).subtype === "workflow_snapshot");
  assert.equal(parse(snap.content).epoch, tracker.epoch);
  assert.deepEqual((parse(snap.content).agents as Array<{ id: string; state: string }>).map((a) => [a.id, a.state]), [["a1", "running"]]);

  // turn_status_request: done より先に全行を送る（done の時点でバックグラウンドの作業が動いていると分かるように）。
  second.events.length = 0;
  second.send({ type: "turn_status_request", agentId: "bgagent", sessionId: sid });
  await second.until((e) => e.type === "done");
  const types = second.events.map((e) => e.type);
  assert.ok(types.includes("workflow_progress") && types.indexOf("workflow_progress") < types.indexOf("done"), JSON.stringify(types));

  // 作業が終わると一覧の background が外れる。
  first.send({ type: "user_message", agentId: "bgagent", sessionId: sid, content: "finish", metadata: { clientMessageId: "bg-c2" } });
  await first.until((e) => e.type === "done" && e.messageId === "m3");
  assert.equal(await background(first), undefined);
  await first.close();
  await second.close();
  await settle();
});

test("新しく開いた session の全行（行が無くても epoch 付き）を、購読した接続へ送る（前の世代の行を消せるように）", async () => {
  const trackers: SubagentTracker[] = [];
  bridge.adapters.set("bgfresh", mockAdapter("bgfresh", (sessionId) => {
    const tracker = new SubagentTracker();
    trackers.push(tracker);
    const session = {
      sessionId: sessionId ?? "fresh-1",
      async send(_text: string, _event: SessionEvent, emit: Emit) {
        emit(event.assistantDelta("bgfresh", session.sessionId, "m1", "ok"));
        emit(event.done("bgfresh", session.sessionId, "m1"));
      },
      subagentSnapshot: async () => tracker.snapshot({ includeEmpty: true }),
      async close() {}
    };
    return session as AgentSession;
  }));
  const client = await connect("bgfresh");
  client.send({ type: "user_message", agentId: "bgfresh", content: "hi", metadata: { clientMessageId: "fresh-c1" } });
  await client.until((e) => e.type === "done");
  const snap = await client.until((e) => e.type === "workflow_progress");
  const p = parse(snap.content);
  assert.deepEqual([p.subtype, p.kind, p.agents, p.epoch], ["workflow_snapshot", "subagents", [], trackers[0].epoch]);
  await client.close();
  await settle();
});

test("再送（load_history の差分）に workflow_progress を含めない（接続時の epoch 付き snapshot の後に前の世代の payload を届けない）", () => {
  const h = new LiveHistoryIndex();
  const rec = (type: SessionEvent["type"], content?: string) => h.record({ type, agentId: "claude", sessionId: "s1", messageId: "m", content } as SessionEvent);
  const first = rec("user_message", "hi");
  rec("workflow_progress", JSON.stringify({ taskId: "subagents", kind: "subagents", epoch: "E1", agents: [] }));
  rec("assistant_delta", "ok");
  const delta = h.replayableDelta("claude", "s1", first.seq! - 1);
  assert.deepEqual(delta?.map((e) => e.type), ["user_message", "assistant_delta"]);
});

test("空の activity でもターンは進行中（本文の無い知らせのターンの間も生成中に見える）。silent の done で閉じる", () => {
  const h = new LiveHistoryIndex();
  const rec = (e: Partial<SessionEvent> & { type: SessionEvent["type"] }) => h.record({ agentId: "claude", sessionId: "s1", ...e } as SessionEvent);
  rec({ type: "done", messageId: "a" });
  assert.equal(h.currentTurn("claude", "s1"), null);
  rec({ type: "activity", messageId: "n", content: "" });
  assert.notEqual(h.currentTurn("claude", "s1"), null);
  rec({ type: "done", messageId: "n", metadata: { origin: "task-notification", silent: "1" } });
  assert.equal(h.currentTurn("claude", "s1"), null);
});

test("ターンの進行（スリープ抑止）: 知らせのターンの activity・発話で始まり、留め置いた done では続き、終わりの done・release で終わる", () => {
  const h = new LiveHistoryIndex();
  const changes: boolean[] = [];
  h.onTurnsChanged = () => changes.push(h.anyTurnInProgress);
  const rec = (e: Partial<SessionEvent> & { type: SessionEvent["type"] }, held = false) =>
    h.record({ agentId: "claude", sessionId: "s1", ...e } as SessionEvent, held);
  rec({ type: "activity", messageId: "n", content: "" });
  assert.equal(h.anyTurnInProgress, true);
  rec({ type: "assistant_delta", messageId: "n", content: "報告です" });
  // 送った発話が CLI に残っている間の done（留め置き）では終わらない
  rec({ type: "done", messageId: "n", metadata: { origin: "task-notification", pending: "1" } }, true);
  assert.equal(h.anyTurnInProgress, true);
  rec({ type: "assistant_delta", messageId: "b", content: "返事です" });
  rec({ type: "done", messageId: "b" });
  assert.equal(h.anyTurnInProgress, false);
  rec({ type: "user_message", messageId: "u", content: "次" });
  assert.equal(h.anyTurnInProgress, true);
  h.release("claude", "s1");
  assert.equal(h.anyTurnInProgress, false);
  assert.deepEqual(changes, [true, false, true, false], "変わったときだけ知らせる");
});

test("deferPushUntilSettled: 行が 0 になって猶予の間に done が来なければ push する。done が来れば取り下げ、動いている間は数えない", async () => {
  const wait = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
  let running = true;
  let fired = 0;
  deferPushUntilSettled({ key: "k1", isRunning: async () => running, isStale: () => false, fire: async () => void (fired += 1), pollMs: 10, graceMs: 60 });
  await wait(120);
  assert.equal(fired, 0, "作業が動いている間は push しない");
  running = false;
  await wait(40);
  assert.equal(fired, 0, "猶予の間は待つ");
  await wait(120);
  assert.equal(fired, 1, "猶予の間に done が来なければ push する");

  // 猶予の間に新しい done が来た（cancelDeferredPush）なら、そちらが push するので取り下げる。
  running = false;
  deferPushUntilSettled({ key: "k2", isRunning: async () => running, isStale: () => false, fire: async () => void (fired += 1), pollMs: 10, graceMs: 60 });
  await wait(30);
  cancelDeferredPush("k2");
  await wait(150);
  assert.equal(fired, 1);

  // 利用者が戻った（購読者がいる）なら push しない。ターンが動いている間は猶予を数えない。
  let busy = true;
  deferPushUntilSettled({ key: "k3", isRunning: async () => false, isStale: () => false, isBusy: () => busy, fire: async () => void (fired += 1), pollMs: 10, graceMs: 40 });
  await wait(120);
  assert.equal(fired, 1, "ターンが動いている間は数えない");
  busy = false;
  await wait(150);
  assert.equal(fired, 2);
  deferPushUntilSettled({ key: "k4", isRunning: async () => false, isStale: () => true, fire: async () => void (fired += 1), pollMs: 10, graceMs: 20 });
  await wait(100);
  assert.equal(fired, 2);
});

test("fireDeferredPushIfSettled: 作業が全部終わっていれば猶予を待たずに預かっていた push を出す（動いている間・利用者が戻っている間は出さない）", async () => {
  const wait = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
  let running = true;
  let stale = false;
  let fired = 0;
  deferPushUntilSettled({ key: "f1", isRunning: async () => running, isStale: () => stale, fire: async () => void (fired += 1), pollMs: 1000, graceMs: 60_000 });
  await fireDeferredPushIfSettled("f1");
  assert.equal(fired, 0, "作業が動いている間は出さない");
  running = false;
  await fireDeferredPushIfSettled("f1");
  assert.equal(fired, 1, "猶予を待たずに出す");
  await fireDeferredPushIfSettled("f1");
  assert.equal(fired, 1, "預かりは 1 回だけ");

  stale = true;
  deferPushUntilSettled({ key: "f2", isRunning: async () => false, isStale: () => stale, fire: async () => void (fired += 1), pollMs: 1000, graceMs: 60_000 });
  await fireDeferredPushIfSettled("f2");
  await wait(10);
  assert.equal(fired, 1, "利用者が戻っていれば出さない");
  await fireDeferredPushIfSettled("no-such-key");
});

test("LiveHistoryIndex.isCounted: 数えていない key の終わった数・release は onFinished へ渡さない", () => {
  const got: Array<{ done: number; failed: number; stopped: number }> = [];
  const idx = new LiveHistoryIndex();
  idx.onFinished = (f) => got.push(f);
  idx.isCounted = (key) => key === "codex:s1";
  const payload = (sid: string, json: string | undefined): SessionEvent => ({ type: "workflow_progress", agentId: "codex", sessionId: sid, content: json });
  for (const sid of ["s1", "s2"]) {
    const t = new SubagentTracker();
    idx.record(payload(sid, t.begin("a1", "x", { background: true })));
    idx.record(payload(sid, t.finish("a1", "failed")));
  }
  assert.deepEqual(got, [{ done: 0, failed: 1, stopped: 0 }]);
});
