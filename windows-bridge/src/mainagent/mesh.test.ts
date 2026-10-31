import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { WebSocket } from "ws";

// エージェントどうしで頼み合う: 設定・深さ・cycle・別の PC へ送る（A）・別の PC から頼まれる口（B）・
// 全部の PC の一覧。実ホームの設定・PATH 上の実 CLI に触れないようにしてから読み込む（orchestrator.test.ts と同じ）。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-mesh-test-"));
const fakeHome = path.join(tmp, "home");
fs.mkdirSync(path.join(tmp, "bin"), { recursive: true });
fs.mkdirSync(fakeHome, { recursive: true });
process.env.HOME = fakeHome;
process.env.USERPROFILE = fakeHome;
process.env.PATH = path.join(tmp, "bin");
for (const key of ["BUDDYOS_PUSH_RELAY_URL", "BUDDYOS_PUSH_RELAY_TOKEN", "CLAUDE_BIN", "CODEX_BIN"]) delete process.env[key];

const { BridgeIdentity } = await import("../identity.js");
const { createBridgeServer } = await import("../server.js");
const { JsonSessionStore } = await import("../sessionStore.js");
const { event } = await import("../protocol.js");
const { credentialHash, deviceKeyId, newCredential } = await import("../tunnelV3.js");
const { callTool } = await import("./mcpEndpoint.js");
const { MAX_DEPTH, Orchestrator, orchestrator } = await import("./orchestrator.js");
const { agyMcpConfig, ensureAgyMcpConfig, setMainAgentRoot, TOOL_NAMES } = await import("./workspace.js");
type BridgeServerT = import("../server.js").BridgeServer;
type BridgeIdentityT = import("../identity.js").BridgeIdentity;
type Caller = import("./orchestrator.js").Caller;
type McpGrant = import("./orchestrator.js").McpGrant;
type AgentAdapter = import("../agents/types.js").AgentAdapter;
type AgentSession = import("../agents/types.js").AgentSession;
type SessionEvent = import("../protocol.js").SessionEvent;

const ADMIN = `bda_${crypto.randomBytes(32).toString("base64url")}`;
const mainRoot = path.join(tmp, "main");
fs.mkdirSync(mainRoot, { recursive: true });
let bridge: BridgeServerT;
let identity: BridgeIdentityT;
let port = 0;
const sockets = new Set<WebSocket>();
const uniq = (prefix: string): string => `${prefix}-${crypto.randomUUID().slice(0, 8)}`;
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

function tmpDir(): string {
  const dir = path.join(tmp, uniq("work"));
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

before(async () => {
  const configDir = path.join(tmp, "config");
  identity = BridgeIdentity.open(configDir, { env: { BUDDYOS_BRIDGE_ID: "mesh-test" }, homeDir: fakeHome, log: () => {} });
  setMainAgentRoot(mainRoot);
  bridge = createBridgeServer(
    {
      configDir,
      identity,
      bridgeId: "mesh-test",
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
  bridge.admin.set(ADMIN);
  await bridge.start();
  port = (bridge.server.address() as net.AddressInfo).port;
  orchestrator.enablePersistence(path.join(configDir, "mainagent-tracks.json"));
  orchestrator.enableSettings(Orchestrator.defaultSettingsFile(configDir));
});

after(async () => {
  for (const ws of sockets) ws.terminate();
  bridge.server.closeAllConnections();
  await new Promise((r) => bridge.server.close(r));
  fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
});

// ---- HTTP（この PC の中から・トンネル経由） ----

interface Resp {
  status: number;
  body: string;
}

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
    const write = (): void => void socket.write(head + body);
    if (socket.connecting) socket.once("connect", write);
    else write();
  });
}

const request = (p: string, opts: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<Resp> =>
  send(net.connect({ host: "127.0.0.1", port }), p, opts);

async function tunnelSocket(id: string): Promise<net.Socket> {
  const socket = net.connect({ host: "127.0.0.1", port });
  await new Promise<void>((r) => socket.once("connect", () => r()));
  const peer = { deviceKeyId: id, connectionId: "test", close: () => socket.destroy() };
  bridge.peers.add(socket.localPort!, peer);
  const local = socket.localPort!;
  socket.once("close", () => bridge.peers.remove(local, peer));
  return socket;
}

function addDevice(clientDeviceId: string): { id: string; credential: string } {
  const pub = crypto.randomBytes(32);
  const id = deviceKeyId(pub);
  const credential = newCredential();
  identity.devices.putPending(id, {
    pub: pub.toString("base64url"),
    clientDeviceId,
    name: "Mac",
    label: null,
    platform: "mac",
    credHash: credentialHash(credential),
    via: "qr",
    createdAt: Date.now()
  });
  identity.devices.confirm(id, credentialHash(credential));
  return { id, credential };
}

const local = (): Record<string, string> => ({ authorization: `Bearer ${identity.localKey()}` });
const admin = (): Record<string, string> => ({ ...local(), "x-buddyos-admin": ADMIN, "content-type": "application/json" });

/** 端末 d として、トンネル経由で B の口を呼ぶ。 */
async function deviceCall(d: { id: string; credential: string }, p: string, body?: unknown): Promise<{ status: number; json: any }> {
  const r = await send(await tunnelSocket(d.id), p, {
    method: body === undefined ? "GET" : "POST",
    headers: { authorization: `Bearer ${d.credential}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  return { status: r.status, json: r.body ? JSON.parse(r.body) : undefined };
}

// ---- 台本の adapter と WS（iPhone） ----

function adapterOf(id: string, open: (sessionId: string | undefined, cwd: string | undefined) => AgentSession, modes?: string[]): AgentAdapter {
  return {
    id,
    displayName: `${id} name`,
    runtimeLabel: `local:${id}`,
    modes,
    openSession: async (sessionId, cwd) => open(sessionId, cwd),
    listSessions: async () => [],
    loadHistory: async () => [],
    renameSession: async () => false,
    listCommands: async () => [],
    currentInfo: async () => undefined,
    setModel: async () => {},
    listAvailableModels: async () => []
  };
}

/** 新規は仮 ID で開き、最初の送信で確定 ID を知らせて "echo: <本文>" を返す。開くたびに orchestrator.grantFor を呼んで記録する（adapter と同じ）。 */
function scripted(agentId: string, realId: string, opts: { grants?: Array<McpGrant | undefined>; modes?: string[]; approval?: boolean } = {}): void {
  bridge.adapters.set(
    agentId,
    adapterOf(
      agentId,
      (sid, cwd) => {
        opts.grants?.push(orchestrator.grantFor(agentId, sid, cwd));
        let n = 0;
        let finish: (() => void) | undefined;
        const session: AgentSession = {
          sessionId: sid ?? `pending-${crypto.randomUUID().slice(0, 8)}`,
          async send(text, _evt, emit) {
            n += 1;
            if (n === 1 && !sid) {
              session.sessionId = realId;
              emit(event.sessionStarted(agentId, realId));
            }
            const mid = `m-${n}`;
            if (opts.approval && n === 1) {
              const meta: Record<string, string> = { requestId: "req-1", kind: "approval", option_count: "2", option_0_value: "allow", option_0_title: "許可", option_1_value: "deny", option_1_title: "拒否", title: "Bash" };
              emit({ type: "action_request", agentId, sessionId: session.sessionId, messageId: "req-1", content: "Bash", metadata: meta });
              await new Promise<void>((r) => (finish = r));
            }
            emit(event.assistantDelta(agentId, session.sessionId, mid, `echo: ${text}`));
            emit(event.done(agentId, session.sessionId, mid));
          },
          async respondToAction() {
            finish?.();
          },
          async close() {
            finish?.();
          }
        };
        return session;
      },
      opts.modes
    )
  );
}

interface Client {
  events: SessionEvent[];
  send(evt: SessionEvent): void;
  until(pred: (evt: SessionEvent) => boolean, timeoutMs?: number): Promise<SessionEvent>;
  close(): Promise<void>;
}

async function connect(agentId: string, query = ""): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/${agentId}?apiKey=${identity.localKey()}${query}`);
  sockets.add(ws);
  ws.once("close", () => sockets.delete(ws));
  const events: SessionEvent[] = [];
  const waiters: Array<{ pred: (evt: SessionEvent) => boolean; resolve: (evt: SessionEvent) => void }> = [];
  ws.on("message", (raw) => {
    const evt = JSON.parse(String(raw)) as SessionEvent;
    events.push(evt);
    for (const w of waiters.splice(0)) {
      if (w.pred(evt)) w.resolve(evt);
      else waiters.push(w);
    }
  });
  await new Promise<void>((resolve, reject) => {
    ws.once("open", () => resolve());
    ws.once("error", reject);
  });
  return {
    events,
    send: (evt) => ws.send(JSON.stringify(evt)),
    until: (pred, timeoutMs = 5000) =>
      new Promise((resolve, reject) => {
        const found = events.find(pred);
        if (found) return resolve(found);
        const timer = setTimeout(() => reject(new Error(`timed out; got ${events.map((e) => e.type).join(",")}`)), timeoutMs);
        waiters.push({ pred, resolve: (e) => (clearTimeout(timer), resolve(e)) });
      }),
    close: () =>
      new Promise<void>((resolve) => {
        if (ws.readyState === WebSocket.CLOSED) return resolve();
        ws.once("close", () => resolve());
        ws.close();
      })
  };
}

/** 呼んだ側のセッション（ふつうのフォルダ。iPhone 1 台が見ている）と、その合鍵（深さ 0）。 */
async function callerSession(): Promise<{ caller: Caller; conn: Client }> {
  const agent = uniq("caller");
  const sid = uniq("csid");
  bridge.adapters.set(agent, adapterOf(agent, (s) => ({ sessionId: s ?? sid, async send() {}, async close() {} })));
  const conn = await connect(agent, `&sessionId=${sid}`);
  const token = orchestrator.issueToken(agent, sid);
  return { caller: { token, agentId: agent, parentSessionId: sid }, conn };
}

const cards = (conn: Client): SessionEvent[] => conn.events.filter((e) => e.type === "action_request");

async function answerNth(conn: Client, caller: Caller, n: number, decision: string): Promise<SessionEvent> {
  await conn.until(() => cards(conn).length > n);
  const card = cards(conn)[n];
  const id = card.messageId ?? "";
  conn.send({ type: "action_response", agentId: caller.agentId, sessionId: caller.parentSessionId, messageId: id, content: decision, metadata: { requestId: id, decision } });
  return card;
}

function sessionsRows(conn: Client): Array<Record<string, any>> {
  const last = conn.events
    .filter((e) => e.type === "workflow_progress")
    .map((e) => JSON.parse(e.content ?? "{}") as Record<string, any>)
    .filter((c) => c.kind === "sessions")
    .at(-1);
  return (last?.agents ?? []) as Array<Record<string, any>>;
}

// ---- 設定 ----

test("設定: 既定は有効・GET/POST /local/orchestrator/settings（管理鍵）・ファイルに残る・切るとふつうのセッションに渡さない", async () => {
  assert.equal(orchestrator.allSessions, true, "ファイルが無ければ有効");
  const get = await request("/local/orchestrator/settings", { headers: admin() });
  assert.deepEqual({ status: get.status, body: JSON.parse(get.body) }, { status: 200, body: { allSessions: true } });
  assert.equal((await request("/local/orchestrator/settings", { headers: local() })).status, 401, "管理鍵が要る");

  const off = await request("/local/orchestrator/settings", { method: "POST", headers: admin(), body: JSON.stringify({ allSessions: false }) });
  assert.deepEqual({ status: off.status, body: JSON.parse(off.body) }, { status: 200, body: { ok: true } });
  const file = Orchestrator.defaultSettingsFile(path.join(tmp, "config"));
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), { allSessions: false });
  if (process.platform !== "win32") assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  const reloaded = new Orchestrator();
  reloaded.enableSettings(file);
  assert.equal(reloaded.allSessions, false, "Bridge を起動し直しても残る");
  assert.equal(orchestrator.planFor("claude", undefined, tmpDir()), undefined, "切るとふつうのセッションには渡さない");
  assert.deepEqual(orchestrator.planFor("claude", undefined, mainRoot), { main: true, depth: 0 }, "mainagent のフォルダには渡す");
  assert.equal(orchestrator.planFor("claude", undefined, mainRoot, true), undefined, "無人実行には渡さない");

  const bad = await request("/local/orchestrator/settings", { method: "POST", headers: admin(), body: JSON.stringify({ allSessions: "yes" }) });
  assert.deepEqual({ status: bad.status, body: JSON.parse(bad.body) }, { status: 400, body: { error: "bad_request" } });
  await request("/local/orchestrator/settings", { method: "POST", headers: admin(), body: JSON.stringify({ allSessions: true }) });
  assert.deepEqual(orchestrator.planFor("claude", undefined, tmpDir()), { main: false, depth: 0, chatMode: undefined });
});

// ---- 深さと cycle ----

test("深さ: 利用者が開いたものは 0、子は 1、孫は 2 で合鍵を渡さない。深さは保存し、開き直しも同じ深さ。同じ鎖へは送れない（cycle）", async () => {
  const childAgent = uniq("child");
  const grandAgent = uniq("grand");
  const realChild = uniq("rc");
  const realGrand = uniq("rg");
  const childGrants: Array<McpGrant | undefined> = [];
  const grandGrants: Array<McpGrant | undefined> = [];
  scripted(childAgent, realChild, { grants: childGrants });
  scripted(grandAgent, realGrand, { grants: grandGrants });
  const { caller, conn } = await callerSession();
  assert.equal(orchestrator.depthOfToken(caller.token), 0);

  const starting = orchestrator.startSession(caller, childAgent, tmpDir(), "子へ");
  await answerNth(conn, caller, 0, "allow");
  const started = await starting;
  assert.equal(started.session_id, realChild);
  assert.equal(childGrants[0]?.depth, 1, "子は呼んだ側 + 1");
  assert.equal(childGrants[0]?.main, false);

  // 子が孫を起こす（承認カードは子のチャットに出る）。
  const childCaller: Caller = { token: childGrants[0]!.token, agentId: childAgent, parentSessionId: realChild };
  const childConn = await connect(childAgent, `&sessionId=${realChild}`);
  const startingGrand = orchestrator.startSession(childCaller, grandAgent, tmpDir(), "孫へ");
  await answerNth(childConn, childCaller, 0, "allow");
  await startingGrand;
  assert.equal(grandGrants.length, 1);
  assert.equal(grandGrants[0], undefined, `深さ ${MAX_DEPTH} の孫には合鍵を渡さない`);

  // 深さは mainagent-tracks.json に残り、開き直し（opening の無い openSession）でも同じ深さで決める。
  orchestrator.saveNow();
  const stored = JSON.parse(fs.readFileSync(path.join(tmp, "config", "mainagent-tracks.json"), "utf8")) as Array<{ agentId: string; depth?: number }>;
  assert.equal(stored.find((t) => t.agentId === childAgent)?.depth, 1);
  assert.equal(stored.find((t) => t.agentId === grandAgent)?.depth, 2);
  assert.equal(orchestrator.planFor(childAgent, realChild, tmpDir())?.depth, 1);
  assert.equal(orchestrator.planFor(grandAgent, realGrand, tmpDir()), undefined);

  // 子から親（呼んだ側）へ・自分へは送れない（カードも出さない）。
  const before = cards(childConn).length;
  await assert.rejects(orchestrator.sendMessage(childCaller, caller.agentId, caller.parentSessionId!, "親へ"), (e: Error) => e.message.startsWith("cycle: "));
  await assert.rejects(orchestrator.sendMessage(childCaller, childAgent, realChild, "自分へ"), (e: Error) => e.message.startsWith("cycle: "));
  assert.equal(cards(childConn).length, before);

  // 深さの上限に達した呼んだ側（B で depth 2 として来た）は頼めない。
  const deep: Caller = { token: "", agentId: "", remote: { deviceKeyId: "d", capMode: 1, depth: MAX_DEPTH } };
  await assert.rejects(orchestrator.startSession(deep, childAgent, tmpDir(), "x"), (e: Error) => e.message.startsWith("depth: "));
  await conn.close();
  await childConn.close();
});

test("呼んだ側のチャットのモードが上限（ふつうのセッションでも）", async () => {
  const agent = uniq("capped");
  scripted(agent, uniq("sid"), { modes: ["plan", "edit", "auto"] });
  const { caller, conn } = await callerSession();
  conn.send({ type: "user_message", agentId: caller.agentId, sessionId: caller.parentSessionId, content: "x", metadata: { clientMessageId: uniq("c"), chatOverrides: "1", chatMode: "plan" } });
  for (let i = 0; i < 50 && orchestrator.ceilingFor(caller) !== 0; i += 1) await sleep(20);
  assert.equal(orchestrator.ceilingFor(caller), 0);
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "look", "auto");
  await answerNth(conn, caller, 0, "allow");
  assert.equal((await starting).mode, "plan");
  await conn.close();
});

// ---- 別の PC へ（A） ----

interface Stub {
  port: number;
  requests: Array<{ path: string; auth?: string; body: Record<string, any> }>;
  reply: (path: string, body: Record<string, any>) => { status: number; body: unknown };
  close(): Promise<void>;
}

/** デスクトップの中継口のふり（受けた要求を覚え、reply で答える）。 */
async function stubPc(): Promise<Stub> {
  const stub: Stub = {
    port: 0,
    requests: [],
    reply: () => ({ status: 200, body: {} }),
    close: async () => {}
  };
  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}") as Record<string, any>;
      stub.requests.push({ path: req.url ?? "", auth: req.headers.authorization, body });
      const r = stub.reply(req.url ?? "", body);
      const text = JSON.stringify(r.body);
      res.writeHead(r.status, { "content-type": "application/json", "content-length": Buffer.byteLength(text) });
      res.end(text);
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  stub.port = (server.address() as net.AddressInfo).port;
  stub.close = () => new Promise((r) => server.close(() => r()));
  return stub;
}

test("PUT /local/remote-pcs（管理鍵）と list_pcs。形の違う行があれば 400 で前の一覧のまま。管理鍵のパイプが閉じたら空", async () => {
  const pcs = [{ bridgeId: "pc-b", name: "Studio", platform: "mac", port: 40001, secret: "bdp_x" }];
  const put = await request("/local/remote-pcs", { method: "PUT", headers: admin(), body: JSON.stringify({ pcs }) });
  assert.equal(put.status, 204);
  assert.equal((await request("/local/remote-pcs", { method: "PUT", headers: local(), body: JSON.stringify({ pcs }) })).status, 401);
  const bad = await request("/local/remote-pcs", { method: "PUT", headers: admin(), body: JSON.stringify({ pcs: [{ bridgeId: "x", port: "nope", secret: "s" }] }) });
  assert.deepEqual({ status: bad.status, body: JSON.parse(bad.body) }, { status: 400, body: { error: "bad_request" } });
  const caller: Caller = { token: "t", agentId: "claude" };
  const listed = (await callTool("list_pcs", {}, caller)) as { pcs: Array<Record<string, unknown>> };
  assert.deepEqual(listed.pcs[0], { pc: identity.bridgeId, name: bridge.bridgeName(), platform: "windows", self: true }, "自分の PC が先頭");
  assert.deepEqual(listed.pcs[1], { pc: "pc-b", name: "Studio", platform: "mac", self: false }, "合言葉と番号は出さない");
  assert.equal(listed.pcs.length, 2);
  await assert.rejects(callTool("list_sessions", { pc: "nowhere" }, caller), (e: Error) => e.message.startsWith("unknown_pc: "));
  assert.ok(Array.isArray(await callTool("list_projects", { pc: identity.bridgeId }, caller)), "自分の bridgeId ならこの PC");
  orchestrator.clearRemotePcs();
  assert.equal(((await callTool("list_pcs", {}, caller)) as { pcs: unknown[] }).pcs.length, 1);
  assert.ok(TOOL_NAMES.includes("list_pcs"));
});

test("別の PC へ: 頼む前に「PC: 名前」付きの承認カード。本文は引数（pc を除く）＋ capMode / depth / caller。結果はそのまま、子のカードに bridgeId / pcName", async () => {
  const stub = await stubPc();
  orchestrator.setRemotePcs([{ bridgeId: "pc-b", name: "Studio", platform: "mac", port: stub.port, secret: "bdp_secret" }]);
  const started = { agent: "claude", session_id: "b-sid-1", cwd: "/Users/b/proj", state: "queued", confirmed: true, mode: "plan", next: "get_reply で返事を待つ" };
  stub.reply = (p) => {
    if (p.endsWith("/start_session")) return { status: 200, body: started };
    if (p.endsWith("/get_reply")) return { status: 200, body: { agent: "claude", session_id: "b-sid-1", status: "needs_approval", approval: { request_id: "r1", title: "Bash", choices: ["allow", "deny"] } } };
    if (p.endsWith("/answer_approval")) return { status: 200, body: { agent: "claude", session_id: "b-sid-1", request_id: "r1", answered: "allow" } };
    if (p.endsWith("/list_projects")) return { status: 200, body: [{ name: "proj", path: "/Users/b/proj" }] };
    return { status: 200, body: {} };
  };
  const { caller, conn } = await callerSession();

  // 状況を見る道具は承認なし。配列の結果もそのまま。
  assert.deepEqual(await callTool("list_projects", { pc: "Studio" }, caller), [{ name: "proj", path: "/Users/b/proj" }], "名前でも引ける");
  assert.equal(cards(conn).length, 0);

  const starting = callTool("start_session", { pc: "pc-b", cwd: "/Users/b/proj", prompt: "テストを回して", mode: "plan" }, caller);
  const card = await answerNth(conn, caller, 0, "allow");
  assert.ok((card.metadata?.subtitle ?? "").startsWith("PC: Studio"), card.metadata?.subtitle);
  assert.ok((card.metadata?.title ?? "").includes("Studio"));
  assert.deepEqual(await starting, started, "B の結果をそのまま返す");
  const req = stub.requests.find((r) => r.path === "/device/orchestrator/start_session")!;
  assert.equal(req.auth, "Bearer bdp_secret");
  assert.equal(req.body.pc, undefined, "pc は外す");
  assert.equal(req.body.capMode, 1, "上限の段（既定は毎回尋ねる）");
  assert.equal(req.body.depth, 0);
  assert.deepEqual(req.body.caller, { bridgeId: identity.bridgeId, name: bridge.bridgeName() });
  assert.equal(req.body.prompt, "テストを回して");

  await conn.until(() => sessionsRows(conn).some((r) => r.bridgeId === "pc-b"));
  let row = sessionsRows(conn).find((r) => r.bridgeId === "pc-b")!;
  assert.equal(row.pcName, "Studio");
  assert.equal(row.sessionId, "b-sid-1");
  assert.equal(row.status, "queued");
  assert.ok(String(row.label).startsWith("Studio"), row.label);

  // get_reply の結果で行を直す（承認待ち）。
  await callTool("get_reply", { pc: "pc-b", agent: "claude", session_id: "b-sid-1", wait_seconds: 0 }, caller);
  await conn.until(() => sessionsRows(conn).some((r) => r.bridgeId === "pc-b" && r.status === "needs_approval"));
  row = sessionsRows(conn).find((r) => r.bridgeId === "pc-b")!;
  assert.equal(row.approval.requestId, "r1");

  // 許可で答えるときもカード（PC 付き）。deny ならカード無し。
  const answering = callTool("answer_approval", { pc: "pc-b", agent: "claude", session_id: "b-sid-1", request_id: "r1", decision: "allow" }, caller);
  const card2 = await answerNth(conn, caller, 1, "allow");
  assert.ok((card2.metadata?.subtitle ?? "").includes("PC: Studio"));
  assert.ok((card2.metadata?.subtitle ?? "").includes("確認: Bash"), "B で何を許すのかもカードに出す");
  await answering;
  await callTool("answer_approval", { pc: "pc-b", agent: "claude", session_id: "b-sid-1", request_id: "r1", decision: "deny" }, caller);
  assert.equal(cards(conn).length, 2);

  // 断ったら送らない。
  const n = stub.requests.length;
  const denied = callTool("send_message", { pc: "pc-b", agent: "claude", session_id: "b-sid-1", text: "続けて" }, caller);
  await answerNth(conn, caller, 2, "deny");
  await assert.rejects(denied, /承認しなかった/);
  assert.equal(stub.requests.length, n);
  await conn.close();
  await stub.close();
  orchestrator.clearRemotePcs();
});

test("別の PC へ: つながらない・401・古い Bridge は pc_unreachable、B の 422 は種類そのままに PC 名を付ける。打ち切りは wait_seconds + 30 秒", async () => {
  const caller: Caller = { token: "t", agentId: "claude" };
  // つながらない（番号を空けておく）
  const free = net.createServer();
  await new Promise<void>((r) => free.listen(0, "127.0.0.1", () => r()));
  const freePort = (free.address() as net.AddressInfo).port;
  await new Promise((r) => free.close(r));
  orchestrator.setRemotePcs([{ bridgeId: "pc-gone", name: "Gone", platform: "windows", port: freePort, secret: "bdp_x" }]);
  await assert.rejects(callTool("list_agents", { pc: "pc-gone" }, caller), (e: Error) => e.message.startsWith("pc_unreachable: Gone"));

  const stub = await stubPc();
  orchestrator.setRemotePcs([{ bridgeId: "pc-b", name: "Studio", platform: "mac", port: stub.port, secret: "bdp_x" }]);
  stub.reply = () => ({ status: 401, body: { error: "unauthorized" } });
  await assert.rejects(callTool("list_agents", { pc: "pc-b" }, caller), (e: Error) => e.message.startsWith("pc_unreachable: ") && e.message.includes("401"));
  stub.reply = () => ({ status: 404, body: { error: "not_found" } });
  await assert.rejects(callTool("list_agents", { pc: "pc-b" }, caller), (e: Error) => e.message.startsWith("pc_unreachable: ") && e.message.includes("古い"));
  stub.reply = () => ({ status: 422, body: { error: "not_requested", message: "この端末から頼んだセッションではない" } });
  await assert.rejects(callTool("get_reply", { pc: "pc-b", agent: "claude", session_id: "x" }, caller), (e: Error) => e.message === "not_requested: Studio: この端末から頼んだセッションではない");
  stub.reply = () => ({ status: 404, body: { error: "unknown_tool" } });
  await assert.rejects(callTool("list_agents", { pc: "pc-b" }, caller), (e: Error) => e.message.startsWith("unknown_tool: "));
  await stub.close();

  const seen: Array<{ tool: string; timeoutMs: number }> = [];
  const original = orchestrator.remoteTransport;
  orchestrator.remoteTransport = async (_pc, tool, _body, timeoutMs) => {
    seen.push({ tool, timeoutMs });
    return { status: 200, body: "{}" };
  };
  try {
    await callTool("get_reply", { pc: "pc-b", agent: "claude", session_id: "x", wait_seconds: 10 }, caller);
    await callTool("get_reply", { pc: "pc-b", agent: "claude", session_id: "x" }, caller);
    await callTool("list_sessions", { pc: "pc-b" }, caller);
    await callTool("get_reply", { pc: "pc-b", agent: "claude", session_id: "x", wait_seconds: 9999 }, caller);
  } finally {
    orchestrator.remoteTransport = original;
  }
  assert.deepEqual(seen.map((s) => s.timeoutMs), [40_000, 90_000, 30_000, 330_000]);
  orchestrator.clearRemotePcs();
});

// ---- 別の PC から頼まれる口（B） ----

test("B の口: トンネルの bdc_ だけ・承認カード無し・capMode で絞る・その端末が頼んだターンだけ・知らない道具は 404・mainagent のフォルダと自分の PC は断る", async () => {
  const agent = uniq("bside");
  const real = uniq("bsid");
  scripted(agent, real, { modes: ["plan", "auto"] });
  const a = addDevice(uniq("mac-a"));
  const other = addDevice(uniq("mac-c"));
  const callerPc = { bridgeId: "pc-a", name: "MacBook" };

  // ローカル鍵は通さない（/device/* はトンネルの bdc_ だけ）。
  const viaLocal = await request("/device/orchestrator/list_agents", { method: "POST", headers: local(), body: "{}" });
  assert.deepEqual({ status: viaLocal.status, body: JSON.parse(viaLocal.body) }, { status: 403, body: { error: "device_only" } });

  const r = await deviceCall(a, "/device/orchestrator/start_session", { agent, cwd: tmpDir(), prompt: "hi", mode: "auto", capMode: 0, depth: 0, caller: callerPc, wait_seconds: 5 });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.mode, "plan", "capMode（計画）以下に絞る");
  assert.equal(r.json.session_id, real);
  assert.equal(r.json.reply, "echo: hi");
  assert.equal(orchestrator.pendingApprovalCount, 0, "B は承認カードを出さない");

  const mine = await deviceCall(a, "/device/orchestrator/get_reply", { agent, session_id: real, wait_seconds: 0 });
  assert.equal(mine.json.status, "done");
  const notMine = await deviceCall(other, "/device/orchestrator/get_reply", { agent, session_id: real, wait_seconds: 0 });
  assert.deepEqual({ status: notMine.status, error: notMine.json.error }, { status: 422, error: "not_requested" });
  const answer = await deviceCall(other, "/device/orchestrator/answer_approval", { agent, session_id: real, request_id: "x", decision: "deny" });
  assert.deepEqual({ status: answer.status, error: answer.json.error }, { status: 422, error: "not_requested" });

  const list = await deviceCall(a, "/device/orchestrator/list_projects", {});
  assert.equal(list.status, 200);
  assert.ok(Array.isArray(list.json), "配列の結果もそのまま");
  assert.deepEqual(await deviceCall(a, "/device/orchestrator/list_pcs", {}), { status: 404, json: { error: "unknown_tool" } });
  assert.deepEqual(await deviceCall(a, "/device/orchestrator/nope", {}), { status: 404, json: { error: "unknown_tool" } });

  const main = await deviceCall(a, "/device/orchestrator/start_session", { agent, cwd: mainRoot, prompt: "x", caller: callerPc });
  assert.equal(main.status, 422);
  assert.equal(main.json.error, "tool_error");
  assert.ok(String(main.json.message).includes("mainagent のフォルダ"));
  const self = await deviceCall(a, "/device/orchestrator/send_message", { agent, session_id: real, text: "x", caller: { bridgeId: identity.bridgeId, name: "me" } });
  assert.deepEqual({ status: self.status, error: self.json.error }, { status: 422, error: "self" });
  const deep = await deviceCall(a, "/device/orchestrator/send_message", { agent, session_id: real, text: "x", depth: MAX_DEPTH, caller: callerPc });
  assert.deepEqual({ status: deep.status, error: deep.json.error }, { status: 422, error: "depth" });
});

test("GET /device/sessions/summary: PC と、動いているセッション（mainagent のフォルダも「メイン」で）。ブランチは cwd の git", async () => {
  const agent = uniq("sum");
  scripted(agent, uniq("never"));
  const repo = tmpDir();
  fs.mkdirSync(path.join(repo, ".git"));
  fs.writeFileSync(path.join(repo, ".git", "HEAD"), "ref: refs/heads/feature-x\n");
  const sidRepo = uniq("s1");
  const sidMain = uniq("s2");
  const c1 = await connect(agent, `&sessionId=${sidRepo}&cwd=${encodeURIComponent(repo)}`);
  const c2 = await connect(agent, `&sessionId=${sidMain}&cwd=${encodeURIComponent(mainRoot)}`);
  for (const [c, sid] of [[c1, sidRepo], [c2, sidMain]] as const) {
    c.send({ type: "user_message", agentId: agent, sessionId: sid, content: "hi", metadata: { clientMessageId: uniq("c") } });
    await c.until((e) => e.type === "done");
  }
  const d = addDevice(uniq("phone"));
  const r = await deviceCall(d, "/device/sessions/summary");
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.pc, { bridgeId: identity.bridgeId, name: bridge.bridgeName(), platform: "windows" });
  const rows = (r.json.sessions as Array<Record<string, unknown>>).filter((s) => s.agentId === agent);
  assert.equal(rows.length, 2);
  for (const row of rows) {
    assert.deepEqual(Object.keys(row).sort(), ["agentId", "agentName", "branch", "cwd", "project", "sessionId", "status", "title", "updatedAtMs"]);
    assert.equal(row.agentName, `${agent} name`);
    assert.equal(row.status, "idle");
    assert.equal(row.title, null, "道具で頼んでいないセッションの名前は null");
    assert.equal(typeof row.updatedAtMs, "number");
  }
  const repoRow = rows.find((s) => s.sessionId === sidRepo)!;
  assert.equal(repoRow.branch, "feature-x");
  assert.equal(repoRow.cwd, repo);
  assert.equal(repoRow.project, path.basename(repo));
  assert.equal(rows.find((s) => s.sessionId === sidMain)!.project, "メイン");
  const all = r.json.sessions as Array<{ updatedAtMs: number }>;
  assert.ok(all.every((s, i) => i === 0 || all[i - 1].updatedAtMs >= s.updatedAtMs), "新しい順");
  assert.ok(all.length <= 50);
  const viaLocal = await request("/device/sessions/summary", { headers: local() });
  assert.equal(viaLocal.status, 403);
  await c1.close();
  await c2.close();
});

// ---- Antigravity ----

test("Antigravity: --add-dir で読ませる .agents/mcp_config.json は stdio の中継だけで、合鍵を含まない", () => {
  const dir = path.join(tmp, "agy-mcp");
  const cmd = { command: process.execPath, args: ["/app/bridge.cjs", "mcp-stdio-relay"] };
  assert.equal(ensureAgyMcpConfig(cmd, dir), dir);
  const file = path.join(dir, ".agents", "mcp_config.json");
  const config = JSON.parse(fs.readFileSync(file, "utf8")) as { mcpServers: Record<string, { command: string; args: string[] }> };
  assert.deepEqual(config, agyMcpConfig(cmd));
  assert.equal(config.mcpServers.buddyos.command, process.execPath);
  assert.deepEqual(config.mcpServers.buddyos.args, cmd.args);
  assert.ok(!fs.readFileSync(file, "utf8").includes("bmt_"), "合鍵はファイルに書かない（agy の環境変数で渡す）");
  const mtime = fs.statSync(file).mtimeMs;
  ensureAgyMcpConfig(cmd, dir);
  assert.equal(fs.statSync(file).mtimeMs, mtime, "同じ中身なら書き直さない");
});

test("Antigravity の承認 hook: buddyos の道具の呼び出しと、その説明（~/.gemini/antigravity-cli/mcp/buddyos/）を読むことは Bridge の MCP のセッションだけ通す", async () => {
  const { AgyApprovalPolicy } = await import("../agents/agyApproval.js");
  const use = (tool: string, args: Record<string, unknown>, opts: Record<string, unknown>): boolean => AgyApprovalPolicy.isBridgeMcpUse(tool, args, opts);

  // POSIX（mac で動かすとき）
  const home = path.join(tmp, "agyhome");
  const schema = path.join(home, ".gemini", "antigravity-cli", "mcp", "buddyos");
  fs.mkdirSync(schema, { recursive: true });
  const on = { bridgeMcp: true, home, cwd: tmpDir() };
  assert.equal(use("call_mcp_tool", { ServerName: "buddyos", ToolName: "send_message", Arguments: {} }, on), true);
  assert.equal(use("call_mcp_tool", { ServerName: "github", ToolName: "x" }, on), false, "ほかの MCP サーバは当てはまらない");
  assert.equal(use("call_mcp_tool", { ServerName: "buddyos" }, { ...on, bridgeMcp: false }), false, "MCP を渡していないセッションは当てはまらない");
  assert.equal(use("view_file", { AbsolutePath: path.join(schema, "send_message.json") }, on), true);
  assert.equal(use("view_file", { AbsolutePath: "~/.gemini/antigravity-cli/mcp/buddyos/get_reply.json" }, on), true, "~ も解く");
  assert.equal(use("view_file", { AbsolutePath: `file://${path.join(schema, "list_pcs.json")}` }, on), true, "file:// も解く");
  assert.equal(use("view_file", { AbsolutePath: path.join(schema, "..", "github", "x.json") }, on), false, "ほかのサーバの説明");
  assert.equal(use("view_file", { AbsolutePath: path.join(home, ".gemini", "antigravity-cli", "settings.json") }, on), false, "ほかの .gemini の中");
  assert.equal(use("view_file", { AbsolutePath: `${schema}-evil/x.json` }, on), false, "名前の前方一致では通さない");
  assert.equal(use("write_to_file", { TargetFile: path.join(schema, "x.json") }, on), false, "書く道具は当てはまらない");
  assert.equal(use("view_file", {}, on), false, "パスが無ければ当てはまらない");
  if (process.platform !== "win32") {
    // 説明の置き場の中のリンクで別の場所を指しても、リンクを解いて比べる。
    const outside = path.join(home, "secrets");
    fs.mkdirSync(outside, { recursive: true });
    fs.symlinkSync(outside, path.join(schema, "link"));
    assert.equal(use("view_file", { AbsolutePath: path.join(schema, "link", "key.txt") }, on), false);
  }

  // Windows のパス（区切り・大文字小文字・file:///C:/・..・別のドライブ）
  const win = { bridgeMcp: true, home: "C:\\Users\\Me", cwd: "C:\\work" };
  assert.equal(use("view_file", { AbsolutePath: "C:\\Users\\Me\\.gemini\\antigravity-cli\\mcp\\buddyos\\send_message.json" }, win), true);
  assert.equal(use("view_file", { AbsolutePath: "c:/users/me/.GEMINI/antigravity-cli/mcp/BuddyOS/x.json" }, win), true, "大文字小文字と / を区別しない");
  assert.equal(use("view_file", { AbsolutePath: "file:///C:/Users/Me/.gemini/antigravity-cli/mcp/buddyos/x.json" }, win), true);
  assert.equal(use("view_file", { AbsolutePath: "~\\.gemini\\antigravity-cli\\mcp\\buddyos\\x.json" }, win), true);
  assert.equal(use("view_file", { AbsolutePath: "C:\\Users\\Me\\.gemini\\antigravity-cli\\mcp\\buddyos\\..\\..\\settings.json" }, win), false);
  assert.equal(use("list_dir", { DirectoryPath: "C:\\Users\\Me\\.gemini\\antigravity-cli\\mcp\\buddyos" }, win), true, "フォルダそのもの");
  assert.equal(use("view_file", { AbsolutePath: "D:\\Users\\Me\\.gemini\\antigravity-cli\\mcp\\buddyos\\x.json" }, win), false, "別のドライブ");

  // verdict: 当てはまれば通す。コマンド実行の決まりは今までどおり。
  assert.deepEqual(AgyApprovalPolicy.verdict("call_mcp_tool", { ServerName: "buddyos" }, [], [], on), { kind: "allow" });
  assert.equal(AgyApprovalPolicy.verdict("run_command", { CommandLine: "npm publish" }, [], [], on).kind, "ask");
});

test("Antigravity の MCP の設定フォルダは agy が入れる権限（フォルダ 0700・ファイル 0600。0600 のフォルダは直す）", { skip: process.platform === "win32" }, () => {
  const dir = path.join(tmp, "agy-perm");
  fs.mkdirSync(path.join(dir, ".agents"), { recursive: true });
  fs.chmodSync(path.join(dir, ".agents"), 0o600);
  fs.chmodSync(dir, 0o600);
  assert.equal(ensureAgyMcpConfig({ command: process.execPath, args: ["mcp-stdio-relay"] }, dir), dir);
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(dir, ".agents")).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(dir, ".agents", "mcp_config.json")).mode & 0o777, 0o600);
});
