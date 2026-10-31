import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";
import type { AgentAdapter, AgentSession, Emit } from "../agents/types.js";
import type { BridgeConfig } from "../config.js";
import { BridgeIdentity } from "../identity.js";
import { ProjectRegistry } from "../projects.js";
import { event, type SessionEvent } from "../protocol.js";
import { createBridgeServer, type BridgeServer } from "../server.js";
import { JsonSessionStore } from "../sessionStore.js";
import { respondMcp } from "./mcpEndpoint.js";
import {
  approvalChoice,
  approvalFromEvent,
  childModeFor,
  codexStrength,
  DEFAULT_CEILING,
  modeStrength,
  Orchestrator,
  orchestrator,
  type Caller
} from "./orchestrator.js";
import {
  acpHttpServer,
  codexMainAgentConfig,
  codexMainAgentExecArgs,
  ensureMainAgentWorkspace,
  isMainWorkspace,
  LEGACY_DISPATCH_SKILL_V1,
  LEGACY_ROLE_TEXT_V1,
  MANAGED_BEGIN,
  MANAGED_END,
  MANAGED_FILES,
  PROJECT_NAME,
  setMainAgentRoot,
  TOOL_NAMES,
  TOOL_TIMEOUT_SECONDS
} from "./workspace.js";
import { acpStdioRelayServer } from "./stdioRelay.js";

// mainagent の道具（orchestrator）と /mcp の JSON-RPC、mainagent のフォルダ・起動引数を確かめる（mac の OrchestratorTests の移植）。
// 子のセッションは台本の adapter で作り、本番と同じく Bridge（server.ts の hub・WS）を通す。mainagent 役のチャットは WS 1 本で見る。

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-mainagent-test-"));
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
const mainRoot = path.join(tmp, "main");
let bridge: BridgeServer;
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
  const identity = BridgeIdentity.open(configDir, {
    env: { BUDDYOS_BRIDGE_API_KEY: API_KEY, BUDDYOS_BRIDGE_ID: "mainagent-test" },
    homeDir: fakeHome,
    log: () => {}
  });
  const config: BridgeConfig = {
    configDir,
    identity,
    bridgeId: "mainagent-test",
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
  };
  setMainAgentRoot(mainRoot);
  bridge = createBridgeServer(config, new JsonSessionStore(configDir));
  await bridge.start();
  const address = bridge.server.address();
  assert.ok(address && typeof address === "object");
  port = address.port;
});

after(() => {
  for (const ws of sockets) ws.terminate();
  bridge.server.closeAllConnections();
  bridge.server.close();
  fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
});

// ---- 台本の adapter ----

interface ScriptedSession extends AgentSession {
  answers: Array<{ requestId: string; decision: string }>;
  /** 答えが届いたら返事を出して終える（undefined なら何も出さない）。 */
  onAnswer?: (requestId: string, decision: string) => void;
}

function adapterOf(id: string, open: (sessionId: string | undefined) => AgentSession, modes?: string[]): AgentAdapter {
  return {
    id,
    displayName: `${id} name`,
    runtimeLabel: `local:${id}`,
    modes,
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

class Gate {
  private release!: () => void;
  readonly wait = new Promise<void>((r) => (this.release = r));
  open(): void {
    this.release();
  }
}

/** 新規は仮 ID で開き、最初の送信で確定 ID を知らせてから "echo: <本文>" を返す adapter。gate で返事の途中に止まる。approval で承認を出す。 */
function scripted(agentId: string, realId: string, opts: { gate?: Gate; approval?: boolean; modes?: string[] } = {}): AgentAdapter {
  const adapter = adapterOf(agentId, (sid) => {
    let n = 0;
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
          emit({ type: "action_request", agentId, sessionId: session.sessionId, messageId: "req-1", content: "Bash: rm -rf build", metadata: { requestId: "req-1", title: "Bash: rm -rf build" } });
        }
        emit(event.assistantDelta(agentId, session.sessionId, mid, `echo: ${text}`));
        if (n === 1 && opts.gate) await opts.gate.wait;
        emit(event.done(agentId, session.sessionId, mid));
      },
      async close() {}
    };
    return session;
  }, opts.modes);
  bridge.adapters.set(agentId, adapter);
  return adapter;
}

/** 最初の送信で承認を出して止まる子。答えが届いたら "answered: <答え>" を返して終わる。 */
function approvingChild(agentId: string, realId: string, options: Array<[string, string]>): { session?: ScriptedSession } {
  const box: { session?: ScriptedSession } = {};
  bridge.adapters.set(agentId, adapterOf(agentId, (sid) => {
    let n = 0;
    let emitTurn: Emit | undefined;
    let finish: (() => void) | undefined;
    const session: ScriptedSession = {
      sessionId: sid ?? `pending-${crypto.randomUUID().slice(0, 8)}`,
      answers: [],
      async send(_text, _evt, emit) {
        n += 1;
        emitTurn = emit;
        if (n === 1 && !sid) {
          session.sessionId = realId;
          emit(event.sessionStarted(agentId, realId));
        }
        const meta: Record<string, string> = { requestId: `req-${n}`, kind: "approval", allowsOther: "0", option_count: String(options.length), title: "「Bash」を実行しますか？", subtitle: "npm test" };
        options.forEach(([v, t], i) => {
          meta[`option_${i}_value`] = v;
          meta[`option_${i}_title`] = t;
        });
        emit({ type: "action_request", agentId, sessionId: realId, messageId: `req-${n}`, content: "「Bash」を実行しますか？", metadata: meta });
        await new Promise<void>((r) => (finish = r));
      },
      async respondToAction(requestId, decision) {
        session.answers.push({ requestId, decision });
        session.onAnswer?.(requestId, decision);
      },
      async close() {
        finish?.();
      }
    };
    session.onAnswer = (requestId, decision) => {
      emitTurn?.(event.assistantDelta(agentId, realId, `a-${requestId}`, `answered: ${decision}`));
      emitTurn?.(event.done(agentId, realId, `a-${requestId}`));
      finish?.();
    };
    box.session = session;
    return session;
  }));
  return box;
}

// ---- WS（iPhone） ----

interface Client {
  events: SessionEvent[];
  send(evt: SessionEvent): void;
  until(pred: (evt: SessionEvent) => boolean, timeoutMs?: number): Promise<SessionEvent>;
  close(): Promise<void>;
}

async function connect(agentId: string, query = ""): Promise<Client> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/${agentId}?apiKey=${API_KEY}${query}`);
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

/** mainagent 役のセッション（iPhone 1 台が見ている）と、その合鍵。承認カードはこの接続に届く。 */
async function mainagent(): Promise<{ caller: Caller; conn: Client; agent: string }> {
  const agent = uniq("main");
  const sid = uniq("msid");
  bridge.adapters.set(agent, adapterOf(agent, (s) => ({ sessionId: s ?? sid, async send() {}, async close() {} })));
  const conn = await connect(agent, `&sessionId=${sid}`);
  const token = orchestrator.issueToken(agent, sid);
  return { caller: { token, agentId: agent, parentSessionId: sid }, conn, agent };
}

const cards = (conn: Client): SessionEvent[] => conn.events.filter((e) => e.type === "action_request");

/** n 枚目（0 始まり）の承認カードに、iPhone と同じ action_response で答える。 */
async function answerNth(conn: Client, caller: Caller, n: number, decision: string): Promise<SessionEvent> {
  await conn.until(() => cards(conn).length > n);
  const card = cards(conn)[n];
  const id = card.messageId ?? "";
  conn.send({ type: "action_response", agentId: caller.agentId, sessionId: caller.parentSessionId, messageId: id, content: decision, metadata: { requestId: id, decision } });
  return card;
}

function sessionsRow(e: SessionEvent, agent: string): Record<string, unknown> | undefined {
  if (e.type !== "workflow_progress") return undefined;
  try {
    const obj = JSON.parse(e.content ?? "") as { kind?: string; agents?: Array<Record<string, unknown>> };
    if (obj.kind !== "sessions") return undefined;
    return obj.agents?.find((r) => r.agentId === agent);
  } catch {
    return undefined;
  }
}

function sessionsCards(conn: Client): Array<Record<string, unknown>> {
  return conn.events
    .filter((e) => e.type === "workflow_progress")
    .map((e) => JSON.parse(e.content ?? "{}") as Record<string, unknown>)
    .filter((c) => c.kind === "sessions");
}

async function expectToolError(p: Promise<unknown>, includes?: string): Promise<void> {
  await assert.rejects(p, (err: Error) => {
    if (includes) assert.ok(err.message.includes(includes), err.message);
    return true;
  });
}

// ---- 道具 ----

test("start_session → 承認カード → 確定 ID、get_reply で返事、list_sessions に頼んだ文", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  scripted(agent, real);
  const dir = tmpDir();
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, dir, "hello");
  const card = await answerNth(conn, caller, 0, "allow");
  assert.equal(card.metadata?.kind, "approval");
  assert.ok((card.metadata?.subtitle ?? "").includes("hello"), "頼む文がカードに出る");
  assert.ok((card.metadata?.requestId ?? "").startsWith("mainagent-"));
  const started = await starting;
  assert.equal(started.session_id, real, "確定した ID を返す");
  assert.equal(started.confirmed, true);
  await conn.until((e) => e.type === "action_resolved" && e.messageId === card.messageId);

  const reply = await orchestrator.getReply(caller, agent, real, 5);
  assert.equal(reply.status, "done");
  assert.equal(reply.reply, "echo: hello");
  const rows = orchestrator.listSessions(caller).filter((r) => r.agent === agent);
  assert.equal(rows[0]?.session_id, real);
  assert.equal(rows[0]?.last_request, "hello");
  assert.equal(rows[0]?.cwd, dir);
  await conn.close();
});

test("作業中に送ると予約になり、done の後に実行される。「このセッションでは承認」の後は尋ねない", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  const gate = new Gate();
  scripted(agent, real, { gate });
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "first");
  await answerNth(conn, caller, 0, "allowForSession");
  await starting;
  const running = await orchestrator.getReply(caller, agent, real, 0);
  assert.equal(running.status, "running");
  const sent = await orchestrator.sendMessage(caller, agent, real, "second");
  assert.equal(sent.state, "queued", "作業中は予約に積む");
  assert.equal(cards(conn).length, 1);
  gate.open();
  const reply = await orchestrator.getReply(caller, agent, real, 5);
  assert.equal(reply.status, "done");
  assert.equal(reply.reply, "echo: second", "後から送った分の返事");
  await conn.close();
});

test("子の承認待ちは needs_approval で返す", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  const gate = new Gate();
  scripted(agent, real, { gate, approval: true });
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "clean");
  await answerNth(conn, caller, 0, "allow");
  await starting;
  const waiting = await orchestrator.getReply(caller, agent, real, 5);
  assert.equal(waiting.status, "needs_approval");
  assert.equal((waiting.approval as Record<string, unknown>).title, "Bash: rm -rf build");
  gate.open();
  let status: unknown;
  for (let i = 0; i < 50 && status !== "done"; i += 1) {
    status = (await orchestrator.getReply(caller, agent, real, 0)).status;
    if (status !== "done") await sleep(100);
  }
  assert.equal(status, "done");
  await conn.close();
});

test("断ったら頼まない（セッションも起こさない）", async () => {
  const agent = uniq("agent");
  let opened = 0;
  bridge.adapters.set(agent, adapterOf(agent, (sid) => (opened++, { sessionId: sid ?? "pending-x", async send() {}, async close() {} })));
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "delete build");
  await answerNth(conn, caller, 0, "deny");
  await expectToolError(starting, "承認しなかった");
  assert.equal(opened, 0);
  assert.deepEqual(orchestrator.listSessions(caller).filter((r) => r.agent === agent), []);
  await conn.close();
});

test("wait_seconds で返事まで待って返す", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  scripted(agent, real);
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "now", undefined, 5);
  await answerNth(conn, caller, 0, "allow");
  const r = await starting;
  assert.equal(r.status, "done");
  assert.equal(r.reply, "echo: now");
  assert.equal(r.session_id, real);
  assert.equal(r.state, undefined);
  await conn.close();
});

test("親のセッションが閉じたら（合鍵を無効にしたら）出している承認は断ったことになる", async () => {
  const agent = uniq("agent");
  scripted(agent, uniq("sid"));
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "x");
  await conn.until((e) => e.type === "action_request");
  orchestrator.revoke(caller.token);
  await expectToolError(starting);
  assert.equal(orchestrator.caller(caller.token), undefined);
  await conn.close();
});

test("子のモードは上限を超えない（agent ごとの強さで比べる）", () => {
  const claude = ["plan", "edit", "auto", "dangerous"];
  const codex = ["plan", "ask", "auto", "dangerous"];
  const oldCodex = ["plan", "auto", "dangerous"];
  const ask = DEFAULT_CEILING;
  assert.equal(childModeFor(undefined, "claude", claude, ask), "auto", "既定の上限は「毎回尋ねる」= claude の auto");
  assert.equal(childModeFor("edit", "claude", claude, ask), "auto");
  assert.equal(childModeFor("dangerous", "claude", claude, ask), "auto");
  assert.equal(childModeFor("plan", "claude", claude, ask), "plan");
  const edit = modeStrength("edit", "claude")!;
  assert.equal(childModeFor(undefined, "claude", claude, edit), "edit");
  assert.equal(childModeFor("auto", "claude", claude, edit), "auto");
  assert.equal(childModeFor(undefined, "codex", codex, ask), "ask", "上限が「毎回尋ねる」なら codex は ask");
  assert.equal(childModeFor("auto", "codex", codex, edit), "ask");
  assert.equal(childModeFor("plan", "codex", codex, ask), "plan");
  assert.equal(childModeFor(undefined, "codex", oldCodex, ask), "plan", "ask を持たない codex（古い申告）は plan");
  assert.equal(childModeFor(undefined, "codex", codex, 4), "dangerous");
  assert.equal(childModeFor(undefined, "codex", codex, 3), "auto");
  assert.throws(() => childModeFor(undefined, "opencode", ["build"], ask), "上限以下のモードが無ければ起こさない");
  assert.equal(childModeFor(undefined, "x", [], ask), undefined, "モードを持たない agent は絞れない");

  assert.ok(modeStrength("auto", "claude")! < modeStrength("edit", "claude")!);
  assert.ok(modeStrength("auto", "codex")! > modeStrength("edit", "claude")!);
  assert.equal(codexStrength("workspace-write", "on-request"), 1);
  assert.equal(codexStrength("workspace-write", "never"), 3);
  assert.equal(codexStrength("read-only", "never"), 0);
  assert.equal(modeStrength("yolo", "claude"), undefined);
});

test("send_message は上限より強いセッションには送らない（承認も尋ねない）。下げれば送れる", async () => {
  const agent = uniq("agent");
  bridge.adapters.set(agent, adapterOf(agent, (sid) => {
    let n = 0;
    const s: AgentSession = {
      sessionId: sid ?? "x",
      async send(text, _e, emit) {
        n += 1;
        emit(event.assistantDelta(agent, s.sessionId, `m${n}`, `echo: ${text}`));
        emit(event.done(agent, s.sessionId, `m${n}`));
      },
      async close() {}
    };
    return s;
  }));
  const target = uniq("target");
  const other = await connect(agent, `&sessionId=${target}`);
  const { caller, conn } = await mainagent();
  orchestrator.noteChatMode(agent, target, "dangerous");
  await expectToolError(orchestrator.sendMessage(caller, agent, target, "hi"), "全権");
  assert.equal(cards(conn).length, 0, "断るときは承認も尋ねない");

  orchestrator.noteChatMode(agent, target, "plan");
  const sending = orchestrator.sendMessage(caller, agent, target, "hi", 5);
  const card = await answerNth(conn, caller, 0, "allow");
  assert.ok((card.metadata?.subtitle ?? "").startsWith("モード: 計画"), card.metadata?.subtitle);
  const r = await sending;
  assert.equal(r.reply, "echo: hi");
  await other.close();
  await conn.close();
});

test("mainagent のチャットで選んだモード（WS の chatOverrides）が子の上限になる", async () => {
  const agent = uniq("agent");
  scripted(agent, uniq("sid"), { modes: ["plan", "edit", "auto"] });
  const { caller, conn, agent: mainId } = await mainagent();
  // iPhone が mainagent のチャットで plan を選んで送った（チャットの上書きは送信ごとに届く）。
  conn.send({ type: "user_message", agentId: mainId, sessionId: caller.parentSessionId, content: "x", metadata: { clientMessageId: uniq("c"), chatOverrides: "1", chatMode: "plan" } });
  for (let i = 0; i < 50 && orchestrator.ceilingFor(caller) !== 0; i += 1) await sleep(20);
  assert.equal(orchestrator.ceilingFor(caller), 0);
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "look", "auto");
  const card = await answerNth(conn, caller, 0, "allow");
  assert.ok((card.metadata?.subtitle ?? "").startsWith("モード: plan"), card.metadata?.subtitle);
  const r = await starting;
  assert.equal(r.mode, "plan");
  await conn.close();
});

test("頼んだ相手と最後の返事は保存され、作り直した Orchestrator（Bridge の再起動）でも読める", async () => {
  const store = path.join(tmpDir(), "tracks.json");
  const beforeRestart = new Orchestrator();
  beforeRestart.attach(bridge.mainagentHub);
  beforeRestart.enablePersistence(store);
  const agent = uniq("agent");
  const done = uniq("sid");
  const busy = uniq("sid");
  const gate = new Gate();
  scripted(agent, done);
  const busyAgent = uniq("agent");
  scripted(busyAgent, busy, { gate });
  const dir = tmpDir();
  const { caller: shared, conn } = await mainagent();
  const token = beforeRestart.issueToken(shared.agentId, shared.parentSessionId);
  const caller: Caller = { ...shared, token };
  const allowNext = async (seen: number): Promise<void> => {
    await conn.until(() => cards(conn).length > seen);
    beforeRestart.resolveApproval(cards(conn)[seen].messageId ?? "", "allow");
  };
  const first = beforeRestart.startSession(caller, agent, dir, "hello", undefined, 5);
  await allowNext(0);
  assert.equal((await first).reply, "echo: hello");
  const second = beforeRestart.startSession(caller, busyAgent, dir, "long");
  await allowNext(1);
  await second;
  beforeRestart.saveNow();
  gate.open();

  const afterRestart = new Orchestrator();
  afterRestart.attach(bridge.mainagentHub);
  afterRestart.enablePersistence(store);
  const r = await afterRestart.getReply(caller, agent, done, 0);
  assert.equal(r.status, "done");
  assert.equal(r.reply, "echo: hello");
  assert.equal(r.cwd, dir);
  const stopped = await afterRestart.getReply(caller, busyAgent, busy, 0);
  assert.equal(stopped.status, "error");
  assert.ok(String(stopped.error).includes("再起動"), JSON.stringify(stopped));
  // 子のカードも読み直した分から作り直せる（mainagent のチャットを開き直したときに出す）。
  const card = afterRestart.sessionsCardJson(caller.agentId, caller.parentSessionId ?? "") ?? "";
  assert.ok(card.includes(done) && card.includes(busy), card);
  assert.ok(card.includes('"status":"error"'), "止まったターンは error の行");
  if (process.platform !== "win32") assert.equal(fs.statSync(store).mode & 0o777, 0o600, "本人だけが読める");
  await conn.close();
});

test("list_sessions に自分自身は出ない・自分には送れない", async () => {
  const agent = uniq("agent");
  bridge.adapters.set(agent, adapterOf(agent, (sid) => ({ sessionId: sid ?? "x", async send() {}, async close() {} })));
  const mine = uniq("main");
  const other = uniq("other");
  // 購読だけでなく、実際に開いた（liveSessions にある）セッション。
  const a = await connect(agent, `&sessionId=${mine}`);
  const b = await connect(agent, `&sessionId=${other}`);
  for (const [c, sid] of [[a, mine], [b, other]] as const) {
    c.send({ type: "user_message", agentId: agent, sessionId: sid, content: "hi", metadata: { clientMessageId: uniq("c") } });
  }
  const me: Caller = { token: "t", agentId: agent, parentSessionId: mine };
  let ids: unknown[] = [];
  for (let i = 0; i < 50 && ids.length < 1; i += 1) {
    ids = orchestrator.listSessions(me).filter((r) => r.agent === agent).map((r) => r.session_id);
    if (ids.length < 1) await sleep(20);
  }
  assert.deepEqual(ids, [other]);
  await expectToolError(orchestrator.sendMessage(me, agent, mine, "hi"), "自分自身");
  await a.close();
  await b.close();
});

test("無いフォルダ・知らないエージェント・mainagent のフォルダでは起こさない", async () => {
  const caller: Caller = { token: "t", agentId: "claude" };
  await expectToolError(orchestrator.startSession(caller, "claude", path.join(tmp, "no-such-dir"), "x"), "cwd");
  await expectToolError(orchestrator.startSession(caller, uniq("nobody"), tmpDir(), "x"), "知らないエージェント");
  fs.mkdirSync(mainRoot, { recursive: true });
  await expectToolError(orchestrator.startSession(caller, "echo", mainRoot, "x"), "mainagent のフォルダ");
});

// ---- 合鍵と /mcp ----

test("合鍵は無効にするまで使える", () => {
  const token = orchestrator.issueToken("claude", undefined);
  assert.match(token, /^bmt_[A-Za-z0-9_-]{43}$/);
  orchestrator.setParentSessionId(token, "abc");
  assert.equal(orchestrator.caller(token)?.parentSessionId, "abc");
  orchestrator.revoke(token);
  assert.equal(orchestrator.caller(token), undefined);
  assert.equal(orchestrator.caller("bmt_nope"), undefined);
});

test("/mcp の JSON-RPC: initialize・通知・tools/list・引数不足・知らないメソッド", async () => {
  const caller: Caller = { token: "test", agentId: "claude" };
  const rpc = async (obj: unknown): Promise<Record<string, any> | undefined> => {
    const out = await respondMcp(JSON.stringify(obj), caller);
    return out === undefined ? undefined : (JSON.parse(out) as Record<string, any>);
  };
  const ini = await rpc({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-03-26" } });
  assert.equal(ini?.result.protocolVersion, "2025-03-26");
  assert.ok(ini?.result.capabilities.tools);
  assert.equal(ini?.result.serverInfo.name, "buddyos");
  assert.equal(await rpc({ jsonrpc: "2.0", method: "notifications/initialized" }), undefined, "通知には返さない（HTTP は 202）");
  const list = await rpc({ jsonrpc: "2.0", id: 2, method: "tools/list" });
  const names = (list?.result.tools as Array<{ name: string }>).map((t) => t.name);
  assert.deepEqual(new Set(names), new Set(["list_pcs", "list_projects", "list_agents", "list_sessions", "start_session", "send_message", "get_reply", "answer_approval", "save_note"]));
  assert.deepEqual(new Set(TOOL_NAMES), new Set(names), "エージェントに許す道具の名前と一致する");
  const bad = await rpc({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "send_message", arguments: { agent: "claude" } } });
  assert.equal(bad?.result.isError, true, "引数が足りなければ道具の失敗として返す");
  const unknown = await rpc({ jsonrpc: "2.0", id: 4, method: "resources/list" });
  assert.equal(unknown?.error.code, -32601);
  const parse = await respondMcp("{nope", caller);
  assert.equal(JSON.parse(parse ?? "{}").error.code, -32700);
});

/** 生の HTTP 要求を送る（トンネル経由のふりをするときは、つないだ番号を peers に入れてから書く）。 */
async function rawHttp(request: (localPort: number) => string, beforeWrite?: (localPort: number) => void): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const socket = net.connect({ host: "127.0.0.1", port }, () => {
      const localPort = socket.localPort!;
      beforeWrite?.(localPort);
      socket.write(request(localPort));
    });
    let data = "";
    socket.setEncoding("utf8");
    socket.on("data", (c: string) => (data += c));
    // Connection: close なので、閉じるまで読んでから分ける（chunked なら戻す）。
    socket.on("end", () => {
      const head = data.indexOf("\r\n\r\n");
      const headers = data.slice(0, head);
      let body = data.slice(head + 4);
      if (/transfer-encoding: chunked/i.test(headers)) {
        let out = "";
        for (;;) {
          const nl = body.indexOf("\r\n");
          const size = Number.parseInt(body.slice(0, nl), 16);
          if (!size) break;
          out += body.slice(nl + 2, nl + 2 + size);
          body = body.slice(nl + 2 + size + 2);
        }
        body = out;
      }
      resolve({ status: Number(/^HTTP\/1\.1 (\d+)/.exec(data)?.[1] ?? 0), body });
    });
    socket.on("error", reject);
  });
}

function mcpRequest(token: string | undefined, opts: { method?: string; path?: string; origin?: string; body?: string } = {}): string {
  const body = opts.body ?? JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} });
  const lines = [
    `${opts.method ?? "POST"} ${opts.path ?? "/mcp"} HTTP/1.1`,
    `Host: 127.0.0.1:${port}`,
    "Content-Type: application/json",
    `Content-Length: ${Buffer.byteLength(body)}`,
    "Connection: close"
  ];
  if (token) lines.push(`Authorization: Bearer ${token}`);
  if (opts.origin) lines.push(`Origin: ${opts.origin}`);
  return `${lines.join("\r\n")}\r\n\r\n${body}`;
}

test("/mcp の関門: 合鍵だけ・トンネル経由は 403 local_only・?apiKey= は 401・ブラウザの Origin は 403・GET/DELETE は 405", async () => {
  const token = orchestrator.issueToken("claude", "parent-x");
  const ok = await rawHttp(() => mcpRequest(token));
  assert.equal(ok.status, 200, ok.body);
  assert.equal(JSON.parse(ok.body).result.serverInfo.name, "buddyos");
  const note = await rawHttp(() => mcpRequest(token, { body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) }));
  assert.equal(note.status, 202);

  assert.equal((await rawHttp(() => mcpRequest(undefined))).status, 401, "合鍵なし");
  assert.equal((await rawHttp(() => mcpRequest("bmt_wrong"))).status, 401, "知らない合鍵");
  assert.equal((await rawHttp(() => mcpRequest(API_KEY))).status, 401, "ローカル鍵（api-key）は受け付けない");
  assert.equal((await rawHttp(() => mcpRequest(token, { path: `/mcp?apiKey=${token}` }))).status, 401, "?apiKey= は受けない");
  const browser = await rawHttp(() => mcpRequest(token, { origin: "http://localhost:3000" }));
  assert.equal(browser.status, 403);
  assert.equal(JSON.parse(browser.body).error, "forbidden_origin");
  assert.equal((await rawHttp(() => mcpRequest(undefined, { method: "GET" }))).status, 405);
  assert.equal((await rawHttp(() => mcpRequest(undefined, { method: "DELETE" }))).status, 405);

  // 中継のトンネル経由（端末から）は、合鍵があっても 403 local_only。
  const peer = { deviceKeyId: "dev-1", connectionId: "c-1", close() {} };
  let used = 0;
  const tunnel = await rawHttp(
    () => mcpRequest(token),
    (localPort) => {
      used = localPort;
      bridge.peers.add(localPort, peer);
    }
  );
  bridge.peers.remove(used, peer);
  assert.equal(tunnel.status, 403);
  assert.equal(JSON.parse(tunnel.body).error, "local_only");

  // WebSocket の upgrade は表に無い（404）。
  await assert.rejects(
    new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/mcp`, { headers: { Authorization: `Bearer ${token}` } });
      ws.once("open", resolve);
      ws.once("error", reject);
    })
  );
  orchestrator.revoke(token);
  assert.equal((await rawHttp(() => mcpRequest(token))).status, 401, "閉じた後の合鍵");
});

// ---- mainagent のフォルダと起動引数 ----

test("フォルダを用意して「メイン」を登録する。一覧から消えていたら足し直す。手で直したファイルは上書きしない", () => {
  const base = tmpDir();
  const root = path.join(base, "main");
  const projects = new ProjectRegistry(path.join(base, "projects.json"));
  ensureMainAgentWorkspace(root, projects);
  for (const f of MANAGED_FILES) assert.ok(fs.existsSync(path.join(root, ...f.path.split("/"))), f.path);
  assert.deepEqual(projects.list().map((p) => p.name), [PROJECT_NAME]);

  const claudeMd = path.join(root, "CLAUDE.md");
  fs.writeFileSync(claudeMd, "custom");
  projects.remove(root);
  ensureMainAgentWorkspace(root, projects);
  assert.equal(fs.readFileSync(claudeMd, "utf8"), "custom");
  assert.deepEqual(projects.list().map((p) => p.name), [PROJECT_NAME], "「メイン」は消せない（足し直す）");
  ensureMainAgentWorkspace(root, projects);
  assert.equal(projects.list().length, 1, "二重には足さない");

  assert.ok(isMainWorkspace(`${root}/`, root));
  assert.ok(!isMainWorkspace(base, root));
  assert.ok(!isMainWorkspace(undefined, root));
});

test("決まりのファイルは印の範囲だけ書き直し、範囲の外の文は残す（v1 のままなら置き換え）", () => {
  const base = tmpDir();
  const root = path.join(base, "main");
  const projects = new ProjectRegistry(path.join(base, "projects.json"));
  const claudeMd = path.join(root, "CLAUDE.md");
  const dispatch = path.join(root, ".claude", "skills", "dispatch", "SKILL.md");
  fs.mkdirSync(path.dirname(dispatch), { recursive: true });
  fs.writeFileSync(claudeMd, LEGACY_ROLE_TEXT_V1);
  fs.writeFileSync(dispatch, LEGACY_DISPATCH_SKILL_V1);
  ensureMainAgentWorkspace(root, projects);
  let text = fs.readFileSync(claudeMd, "utf8");
  assert.ok(text.includes(MANAGED_BEGIN));
  assert.ok(text.includes("answer_approval"));
  const skill = fs.readFileSync(dispatch, "utf8");
  assert.ok(skill.startsWith("---\nname: dispatch\n"), "frontmatter はファイルの先頭のまま");
  assert.ok(skill.includes("answer_approval"));

  text = `# 自分のメモ\n- 朝は短く\n\n${text.replaceAll("answer_approval", "OLD_TOOL")}\n## 追加の決まり\n- 返事は 3 行まで\n`;
  fs.writeFileSync(claudeMd, text);
  fs.writeFileSync(dispatch, `${skill}\n追記: 急ぎは codex に回す\n`);
  ensureMainAgentWorkspace(root, projects);
  const refreshed = fs.readFileSync(claudeMd, "utf8");
  assert.ok(refreshed.startsWith("# 自分のメモ\n- 朝は短く\n"), refreshed);
  assert.ok(refreshed.includes("## 追加の決まり\n- 返事は 3 行まで"));
  assert.ok(refreshed.includes("answer_approval"));
  assert.ok(!refreshed.includes("OLD_TOOL"));
  assert.equal(refreshed.split(MANAGED_END).length, 2, "範囲は 1 つのまま");
  const refreshedSkill = fs.readFileSync(dispatch, "utf8");
  assert.ok(refreshedSkill.endsWith("追記: 急ぎは codex に回す\n"));
  assert.ok(refreshedSkill.startsWith("---\nname: dispatch\n"));
  ensureMainAgentWorkspace(root, projects);
  assert.equal(fs.readFileSync(claudeMd, "utf8"), refreshed, "もう一度呼んでも変わらない");
});

test("決まりの文は mac の MainAgentWorkspace.swift と同じ", () => {
  const swift = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "mac-bridge", "Sources", "Agents", "MainAgentWorkspace.swift");
  if (!fs.existsSync(swift)) return; // windows-bridge だけを取り出して動かすとき
  const src = fs.readFileSync(swift, "utf8");
  const literal = (name: string): string => {
    const m = new RegExp(`static let ${name} = """\\n([\\s\\S]*?)\\n\\s*"""`).exec(src);
    assert.ok(m, name);
    const lines = m[1].split("\n");
    const indent = Math.min(...lines.filter((l) => l.trim()).map((l) => /^ */.exec(l)![0].length));
    return lines.map((l) => l.slice(indent)).join("\n");
  };
  const byPath = new Map(MANAGED_FILES.map((f) => [f.path, f]));
  assert.equal(byPath.get("CLAUDE.md")?.body, literal("roleText"));
  assert.equal(byPath.get(".claude/skills/dispatch/SKILL.md")?.body, literal("dispatchSkill"));
  assert.equal(byPath.get(".claude/skills/dispatch/SKILL.md")?.frontmatter, literal("dispatchFrontmatter"));
  assert.equal(byPath.get(".claude/skills/status/SKILL.md")?.body, literal("statusSkill"));
  assert.equal(byPath.get(".claude/skills/status/SKILL.md")?.frontmatter, literal("statusFrontmatter"));
  assert.equal(LEGACY_ROLE_TEXT_V1, literal("legacyRoleTextV1"));
  assert.equal(LEGACY_DISPATCH_SKILL_V1, literal("legacyDispatchSkillV1"));
});

test("Codex の config は点区切りのキーで、承認は Bridge が出す。ACP の mcpServers の形（合鍵は引数に載せない）", () => {
  const c = codexMainAgentConfig("bmt_x", 9999);
  assert.equal(c["mcp_servers.buddyos.url"], "http://127.0.0.1:9999/mcp");
  assert.deepEqual(c["mcp_servers.buddyos.http_headers"], { Authorization: "Bearer bmt_x" });
  assert.equal(c["mcp_servers.buddyos.default_tools_approval_mode"], "approve");
  assert.equal(c["mcp_servers.buddyos.tool_timeout_sec"], TOOL_TIMEOUT_SECONDS);
  const exec = codexMainAgentExecArgs(9999).join(" ");
  assert.ok(exec.includes('sandbox_mode="read-only"'));
  assert.ok(exec.includes('bearer_token_env_var="BUDDYOS_MCP_TOKEN"'));
  assert.ok(!exec.includes("Bearer"), "合鍵を引数に載せない");

  const http = acpHttpServer("bmt_x", 9999);
  assert.equal(http.type, "http");
  assert.equal(http.name, "buddyos");
  assert.deepEqual(http.headers, [{ name: "Authorization", value: "Bearer bmt_x" }]);

  const stdio = acpStdioRelayServer("bmt_secret", 9999, { command: "C:\\node\\node.exe", args: ["C:\\app\\bridge.cjs", "mcp-stdio-relay"] });
  assert.equal(stdio.command, "C:\\node\\node.exe");
  assert.deepEqual(stdio.args, ["C:\\app\\bridge.cjs", "mcp-stdio-relay"]);
  assert.ok(!JSON.stringify(stdio.args).includes("bmt_secret"), "合鍵は引数に載せない");
  assert.deepEqual(stdio.env, [
    { name: "BUDDYOS_MCP_TOKEN", value: "bmt_secret" },
    { name: "BUDDYOS_MCP_PORT", value: "9999" }
  ]);
  const wsl = acpStdioRelayServer("bmt_secret", 9999, { command: "C:\\node\\node.exe", args: ["x"] }, "wsl");
  assert.equal(wsl.command, "/mnt/c/node/node.exe", "WSL からは Windows の node.exe を /mnt/c で起こす");
  assert.ok((wsl.env as Array<{ name: string; value: string }>).some((e) => e.name === "WSLENV" && e.value === "BUDDYOS_MCP_TOKEN:BUDDYOS_MCP_PORT"));
});

test("/health の capabilities.orchestrate は claude と codex だけ", async () => {
  const res = await fetch(`http://127.0.0.1:${port}/health`, { headers: { Authorization: `Bearer ${API_KEY}` } });
  const agents = ((await res.json()) as { agents: Array<{ id: string; capabilities: Record<string, unknown> }> }).agents;
  const cap = (id: string): unknown => agents.find((a) => a.id === id)?.capabilities.orchestrate;
  assert.equal(cap("codex"), true);
  assert.equal(cap("echo"), false);
  assert.equal(cap("hermes"), false);
  // claude は CLI が無いと echo の代わりになる（そのときは false）。
  assert.equal(typeof cap("claude"), "boolean");
  const codexModes = agents.find((a) => a.id === "codex")?.capabilities.modes;
  assert.deepEqual(codexModes, ["plan", "ask", "auto", "dangerous"]);
});

// ---- 子の承認に答える（answer_approval） ----

test("answer_approval: 上限が「毎回尋ねる」なら、許可のたびにカード（「このセッションでは承認」は出さない）", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  const box = approvingChild(agent, real, [["allow", "承認"], ["allowForSession", "このセッションでは承認"], ["deny", "非承認"]]);
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "run tests");
  await answerNth(conn, caller, 0, "allowForSession"); // 以後の依頼は尋ねない
  await starting;

  const waiting = await orchestrator.getReply(caller, agent, real, 5);
  assert.equal(waiting.status, "needs_approval");
  const approval = waiting.approval as Record<string, unknown>;
  assert.equal(approval.request_id, "req-1");
  assert.equal(approval.summary, "npm test", "何を許すのかが見える");
  assert.deepEqual(approval.choices, ["allow", "allow_for_session", "deny"]);
  const listed = orchestrator.listSessions(caller).find((r) => r.agent === agent);
  assert.equal(listed?.last_request_state, "needs_approval");
  assert.equal((listed?.pending_approvals as Array<Record<string, unknown>>)[0].request_id, "req-1");

  await expectToolError(orchestrator.answerApproval(caller, agent, real, "req-1", "allow_for_session"), "編集は尋ねない");
  assert.equal(cards(conn).length, 1, "断るときは尋ねない");

  const answering = orchestrator.answerApproval(caller, agent, real, "req-1", "allow");
  const card = await answerNth(conn, caller, 1, "allow");
  assert.equal(card.metadata?.option_count, "2", "「このセッションでは承認」は出さない");
  assert.ok((card.metadata?.subtitle ?? "").includes("npm test"), card.metadata?.subtitle);
  const answered = await answering;
  assert.equal(answered.answered, "allow");
  assert.deepEqual(box.session?.answers.map((a) => a.decision), ["allow"], "子の選択肢の値で答える");

  const done = await orchestrator.getReply(caller, agent, real, 5);
  assert.equal(done.status, "done");
  assert.equal(done.reply, "answered: allow");
  await expectToolError(orchestrator.answerApproval(caller, agent, real, "req-1", "deny"), "待っていない");
  await conn.close();
});

test("answer_approval: deny はカード無し・上限が計画なら許可できない・Codex の値で答える", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  const box = approvingChild(agent, real, [["accept", "承認"], ["acceptForSession", "このセッションでは承認"], ["decline", "非承認"]]);
  const { caller, conn } = await mainagent();
  orchestrator.noteChatMode(caller.agentId, caller.parentSessionId ?? "", "plan");
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "look");
  await answerNth(conn, caller, 0, "allow");
  await starting;
  assert.equal((await orchestrator.getReply(caller, agent, real, 5)).status, "needs_approval");
  await expectToolError(orchestrator.answerApproval(caller, agent, real, "req-1", "allow"), "計画");
  const r = await orchestrator.answerApproval(caller, agent, real, "req-1", "deny");
  assert.equal(r.answered, "deny");
  assert.equal(cards(conn).length, 1, "断るのはユーザーに尋ねない");
  assert.deepEqual(box.session?.answers.map((a) => a.decision), ["decline"]);
  await expectToolError(orchestrator.answerApproval(caller, agent, real, "req-1", "maybe"), "decision");
  await conn.close();
});

test("子のチャットを開いた iPhone が答えたら、答えたことを知らせない adapter でも承認待ちを外す", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  const box = approvingChild(agent, real, [["allow", "承認"], ["deny", "非承認"]]);
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "x");
  await answerNth(conn, caller, 0, "allow");
  await starting;
  assert.equal((await orchestrator.getReply(caller, agent, real, 5)).status, "needs_approval");
  box.session!.onAnswer = undefined; // 答えても何も出さない（action_resolved も done も無い）
  const phone = await connect(agent, `&sessionId=${real}`);
  phone.send({ type: "action_response", agentId: agent, sessionId: real, messageId: "req-1", content: "allow", metadata: { requestId: "req-1", decision: "allow" } });
  let status: unknown;
  for (let i = 0; i < 50 && status !== "running"; i += 1) {
    status = (await orchestrator.getReply(caller, agent, real, 0)).status;
    if (status !== "running") await sleep(50);
  }
  assert.equal(status, "running");
  assert.deepEqual(box.session?.answers.map((a) => a.decision), ["allow"]);
  await phone.close();
  await box.session?.close();
  await conn.close();
});

test("子の選択肢を allow / allow_for_session / deny に振り分ける。質問・保留・選択肢なしは答えない", () => {
  const c = (v: string, t = ""): string | undefined => approvalChoice(v, t);
  assert.equal(c("allow"), "allow");
  assert.equal(c("allowForSession"), "allow_for_session");
  assert.equal(c("deny"), "deny");
  assert.equal(c("accept"), "allow");
  assert.equal(c("acceptForSession"), "allow_for_session");
  assert.equal(c("decline"), "deny");
  assert.equal(c("once"), "allow");
  assert.equal(c("always"), "allow_for_session");
  assert.equal(c("reject"), "deny");
  assert.equal(c("allow_once"), "allow");
  assert.equal(c("allow_always"), "allow_for_session");
  assert.equal(c("reject_once"), "deny");
  assert.equal(c("reject_always"), "deny", "always でも断る側は deny");
  assert.equal(c("proceed_always"), "allow_for_session");
  assert.equal(c("opt-1", "Allow"), "allow");
  assert.equal(c("opt-3", "Reject"), "deny");
  assert.equal(c("opt-9", "Something else"), undefined, "分からない選択肢は選ばせない");

  const card = (meta: Record<string, string>, id = "r") =>
    approvalFromEvent({ type: "action_request", agentId: "a", sessionId: "s", messageId: id, content: "t", metadata: meta });
  const opts = { option_count: "2", option_0_value: "allow", option_1_value: "deny" };
  assert.ok(card({ ...opts, kind: "approval" }).answerable);
  assert.ok(card({ ...opts, kind: "plan" }).answerable, "計画の承認は答えられる（上限で絞る）");
  assert.ok(!card({ ...opts, kind: "userInput" }).answerable, "質問は答えない");
  assert.ok(!card({ ...opts, kind: "approval", answerable: "0" }).answerable);
  assert.ok(!card({ ...opts, kind: "approval" }, "held-1234").answerable, "ターミナルへの発話の保留は通さない");
  assert.ok(!card({ kind: "approval" }).answerable, "選択肢が無いものは答えない");
});

// ---- 子のカード（workflow_progress kind = "sessions"） ----

test("子のカード: running → done の行、開き直し・誰も見なくなった後でも最新のカードが届く", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  const gate = new Gate();
  scripted(agent, real, { gate });
  const dir = tmpDir();
  const { caller, conn, agent: mainId } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, dir, "check git status\nand report");
  await answerNth(conn, caller, 0, "allow");
  await starting;

  const running = await conn.until((e) => {
    const r = sessionsRow(e, agent);
    return r?.status === "running" && r?.sessionId === real;
  });
  const row = sessionsRow(running, agent)!;
  assert.equal(row.cwd, dir);
  assert.equal(row.title, "check git status and report");
  assert.equal(row.state, "running", "古いアプリ向けの state");
  assert.equal(row.index, 0);
  assert.equal(row.rowKind, "session");
  assert.equal(row.agentName, `${agent} name`);
  assert.equal(typeof row.startedAtMs, "number");
  assert.equal(typeof row.updatedAtMs, "number");
  assert.equal(row.finishedAtMs, undefined);
  const card = sessionsCards(conn).at(-1)!;
  assert.equal(card.taskId, "mainagent-sessions");
  assert.equal(card.subtype, "task_progress");
  assert.equal(card.workflowName, "任せたセッション");
  assert.equal(card.status, "running");

  gate.open();
  const doneEvent = await conn.until((e) => sessionsRow(e, agent)?.status === "done");
  const done = sessionsRow(doneEvent, agent)!;
  assert.equal(done.summary, "echo: check git status and report");
  assert.equal(done.resultPreview, done.summary);
  assert.equal(done.state, "done");
  assert.equal(typeof done.finishedAtMs, "number");
  assert.equal(typeof done.durationMs, "number");
  assert.equal(sessionsCards(conn).at(-1)?.status, "completed");
  assert.ok(sessionsCards(conn).length <= 4, `${sessionsCards(conn).length} 回（変わったときだけ出す）`);

  // 開き直した iPhone（別の購読者）にも、ターンが終わっていても最新のカードが届く。
  const again = await connect(mainId, `&sessionId=${caller.parentSessionId}`);
  await again.until((e) => sessionsRow(e, agent)?.status === "done");
  await conn.close();
  await again.close();
  await sleep(50);
  const third = await connect(mainId, `&sessionId=${caller.parentSessionId}`);
  await third.until((e) => sessionsRow(e, agent)?.status === "done");
  // turn_status_request の返事でも送り直す。
  const before = sessionsCards(third).length;
  third.send({ type: "turn_status_request", agentId: mainId, sessionId: caller.parentSessionId });
  await third.until(() => sessionsCards(third).length > before);
  await third.close();
});

test("子のカード: 承認待ちの行（approval）と、答えた後の done", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  approvingChild(agent, real, [["allow", "承認"], ["deny", "非承認"]]);
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "test");
  await answerNth(conn, caller, 0, "allow");
  await starting;
  const e = await conn.until((x) => sessionsRow(x, agent)?.status === "needs_approval");
  const row = sessionsRow(e, agent)!;
  const approval = row.approval as Record<string, unknown>;
  assert.equal(approval.requestId, "req-1");
  assert.equal(approval.answerable, true);
  assert.equal(approval.count, 1);
  assert.equal(row.summary, "承認待ち: 「Bash」を実行しますか？");
  assert.equal(row.state, "running");
  await orchestrator.answerApproval(caller, agent, real, "req-1", "deny");
  await conn.until((x) => sessionsRow(x, agent)?.status === "done");
  await conn.close();
});

/** 起動だけのターンを done にしたあと、バックグラウンドの子の作業が続く adapter。late() で後から出来事を流す（emit は最初の送信のもの）。 */
function backgroundLauncher(agentId: string, realId: string, rowKind = "agent"): { late: (fn: (emit: Emit, sid: string) => void) => void } {
  const box: { emit?: Emit } = {};
  bridge.adapters.set(agentId, adapterOf(agentId, (sid) => {
    const session: AgentSession = {
      sessionId: sid ?? `pending-${crypto.randomUUID().slice(0, 8)}`,
      async send(text, _evt, emit) {
        box.emit = emit;
        if (!sid) {
          session.sessionId = realId;
          emit(event.sessionStarted(agentId, realId));
        }
        emit(event.workflowProgress(agentId, realId, JSON.stringify({ subtype: "task_progress", taskId: "subagents", kind: "subagents", epoch: "E1", agents: [{ index: 0, id: "a1", state: "running", rowKind }] })));
        emit(event.assistantDelta(agentId, realId, "m-launch", `launching: ${text}`));
        emit(event.done(agentId, realId, "m-launch"));
      },
      async close() {}
    };
    return session;
  }));
  return { late: (fn) => fn(box.emit!, realId) };
}

const rowPayload = (agentId: string, sid: string, state: string, rowKind = "agent"): SessionEvent =>
  event.workflowProgress(agentId, sid, JSON.stringify({ subtype: "task_progress", taskId: "subagents", kind: "subagents", epoch: "E1", agents: [{ index: 0, id: "a1", state, rowKind }] }));

test("子が起動だけのターンを done にしても、バックグラウンドのサブエージェントが動いている間は done にせず、知らせのターンの結論を返事にする", async () => {
  const agent = uniq("agent");
  const real = uniq("sid");
  const box = backgroundLauncher(agent, real);
  const { caller, conn } = await mainagent();
  const starting = orchestrator.startSession(caller, agent, tmpDir(), "調べて");
  await answerNth(conn, caller, 0, "allow");
  await starting;
  await sleep(150);
  const waiting = await orchestrator.getReply(caller, agent, real, 0);
  assert.equal(waiting.status, "running", "起動の返事で done にしない");
  assert.match(String(waiting.hint), /バックグラウンド/);
  box.late((emit, sid) => {
    emit(rowPayload(agent, sid, "done"));
    emit(event.assistantDelta(agent, sid, "m-report", "結論: 見つかった"));
    emit({ ...event.done(agent, sid, "m-report"), metadata: { origin: "task-notification" } });
  });
  const reply = await orchestrator.getReply(caller, agent, real, 5);
  assert.equal(reply.status, "done");
  assert.equal(reply.reply, "結論: 見つかった", "知らせのターンの本文が返事");
  await conn.close();
});

test("バックグラウンドの行が全部終わっても知らせのターンの done が来ない子は、猶予のあとに done にする。コマンドだけなら待たない", async () => {
  const saved = Orchestrator.backgroundSettleMs;
  Orchestrator.backgroundSettleMs = 120;
  try {
    const agent = uniq("agent");
    const real = uniq("sid");
    const box = backgroundLauncher(agent, real);
    const { caller, conn } = await mainagent();
    const starting = orchestrator.startSession(caller, agent, tmpDir(), "調べて");
    await answerNth(conn, caller, 0, "allow");
    await starting;
    await sleep(150);
    assert.equal((await orchestrator.getReply(caller, agent, real, 0)).status, "running");
    box.late((emit, sid) => emit(rowPayload(agent, sid, "done")));
    const reply = await orchestrator.getReply(caller, agent, real, 5);
    assert.equal(reply.status, "done");
    assert.equal(reply.reply, "launching: 調べて", "知らせが無ければ起動の返事のまま");

    const shellAgent = uniq("agent");
    const shellReal = uniq("sid");
    backgroundLauncher(shellAgent, shellReal, "shell");
    const starting2 = orchestrator.startSession(caller, shellAgent, tmpDir(), "dev サーバー");
    await answerNth(conn, caller, 1, "allow");
    await starting2;
    assert.equal((await orchestrator.getReply(caller, shellAgent, shellReal, 5)).status, "done", "バックグラウンドのコマンドだけなら待たない");
    await conn.close();
  } finally {
    Orchestrator.backgroundSettleMs = saved;
  }
});
