import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { WebSocketServer } from "ws";
import type { SessionEvent } from "../protocol.js";
import { JsonRpcWebSocket } from "../runtime/jsonRpcWebSocket.js";
import { AgyApprovalHook, AgyApprovalPolicy } from "./agyApproval.js";
import { AgyInbox, AntigravityPresence, AntigravityTerminalMirror, AntigravityTranscript, firstWorkspace, mirrorEvents, userRequest } from "./antigravityTerminal.js";
import { CodexAppServerSession } from "./codexAppServer.js";
import { codexSharedCommandLine, CodexTerminalRegistry, codexTerminals } from "./codexShared.js";
import { GrokPresence } from "./grokPresence.js";
import { historyFromServe, OpenCodeServeTranslator, OpenCodeTerminals } from "./opencodeServe.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-agent-terminals-"));

test("CodexTerminalRegistry は送り直しが 45 秒途絶えた thread を落とす", () => {
  let now = 1_000;
  const reg = new CodexTerminalRegistry(() => now);
  reg.open("t-1", "C:\\w");
  assert.equal(reg.isLive("t-1"), true);
  now += 30_000;
  reg.open("t-1");
  now += 30_000;
  assert.deepEqual(reg.liveEntries().map((e) => [e.threadId, e.cwd]), [["t-1", "C:\\w"]]);
  now += 45_000;
  assert.equal(reg.isLive("t-1"), false);
  reg.open("t-2");
  reg.close("t-2");
  assert.equal(reg.liveEntries().length, 0);
});

test("AgyApprovalPolicy: コマンド実行だけを止め、許可・拒否リストは区切りごとに見る", () => {
  const allow = ["command(git status)", "command(ls)", "command(regex:npm run (build|test))"];
  const deny = ["command(rm)"];
  const run = (c: string) => AgyApprovalPolicy.verdict("run_command", { CommandLine: c }, allow, deny);
  assert.deepEqual(AgyApprovalPolicy.verdict("view_file", {}, allow, deny), { kind: "allow" });
  assert.deepEqual(run("git status"), { kind: "allow" });
  assert.deepEqual(run("ls -la && npm run test"), { kind: "allow" });
  assert.equal(run("ls; rm -rf x").kind, "deny");
  assert.equal(run("ls $(whoami)").kind, "ask");
  assert.equal(run("git push").kind, "ask");
  assert.deepEqual(AgyApprovalPolicy.splitCommand(`echo "a && b" | grep a; ls & pwd`), [`echo "a && b"`, "grep a", "ls", "pwd"]);
  assert.equal(AgyApprovalPolicy.matches("git statusx", ["command(git status)"]), false);
  assert.equal(AgyApprovalPolicy.matches("anything", ["command(*)"]), true);
});

test("AgyApprovalHook の設定は / 区切りで node とスクリプトを呼ぶ", () => {
  const config = JSON.parse(AgyApprovalHook.config("C:\\Program Files\\node\\node.exe")) as Record<string, { PreToolUse: Array<{ hooks: Array<{ command: string; timeout: number }> }> }>;
  const hook = config["buddyos-approval"].PreToolUse[0].hooks[0];
  assert.match(hook.command, /^"C:\/Program Files\/node\/node\.exe" ".*buddy-agy-approval\.mjs"$/);
  assert.equal(hook.timeout, 600);
  const env = AgyApprovalHook.env(8765, "tok");
  assert.equal(env.BUDDYOS_AGY_HOOK_URL, "http://127.0.0.1:8765/antigravity/hook");
  assert.equal(env.BUDDYOS_AGY_HOOK_TOKEN, "tok");
});

test("AntigravityTranscript: 発話はタグの中身、返事は道具を挟んでも 1 つにまとめる", () => {
  const lines = [
    { type: "USER_INPUT", content: "<USER_REQUEST>\nこんにちは\n</USER_REQUEST><META>x</META>" },
    { type: "PLANNER_RESPONSE", content: "調べます", tool_calls: [{ name: "run_command" }] },
    { type: "GENERIC", content: "out" },
    { type: "PLANNER_RESPONSE", content: "終わりました" },
    { type: "SYSTEM_MESSAGE", content: "sys" }
  ].map((l) => JSON.stringify(l)).join("\n");
  const id = "11111111-2222-3333-4444-555555555555";
  assert.deepEqual(AntigravityTranscript.parse(lines, id).map((m) => [m.role, m.content]), [
    ["user", "こんにちは"],
    ["assistant", "調べます\n\n終わりました"]
  ]);
  assert.deepEqual(AntigravityTranscript.read("../etc"), []);
  assert.equal(userRequest("plain"), "plain");
  assert.deepEqual(mirrorEvents(JSON.stringify({ type: "PLANNER_RESPONSE", content: "a", tool_calls: [{ name: "x" }] })), [
    { kind: "assistant", text: "a" },
    { kind: "toolStart", name: "x" }
  ]);
  assert.deepEqual(mirrorEvents(JSON.stringify({ type: "PLANNER_RESPONSE", content: "" })), [{ kind: "turnEnd" }]);
  assert.deepEqual(mirrorEvents("not json"), []);
});

test("firstWorkspace は file URL をこの OS のパスにする", () => {
  const url = process.platform === "win32" ? "file:///C:/work/app" : "file:///work/app";
  const expected = process.platform === "win32" ? "C:\\work\\app" : "/work/app";
  assert.equal(firstWorkspace(JSON.stringify([url])), expected);
  assert.equal(firstWorkspace("[]"), undefined);
  assert.equal(firstWorkspace("broken"), undefined);
});

test("AgyInbox: 未読の分の後ろに足し、hook の有無は hooks.json とスクリプトで見る", () => {
  const dir = path.join(tmp, "inbox");
  const id = "11111111-2222-3333-4444-555555555555";
  AgyInbox.enqueue(id, "一つ目", dir);
  AgyInbox.enqueue(id, "二つ目", dir);
  AgyInbox.enqueue("not-a-uuid", "x", dir);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir, `${id}.json`), "utf8")), {
    injectSteps: [{ userMessage: "一つ目" }, { userMessage: "二つ目" }]
  });
  assert.deepEqual(fs.readdirSync(dir), [`${id}.json`]);
  const hooks = path.join(tmp, "hooks.json");
  const script = path.join(tmp, "buddy-agy-inbox.mjs");
  fs.writeFileSync(hooks, JSON.stringify({ "buddyos-inbox": {} }));
  assert.equal(AgyInbox.isInstalled(hooks, script), false);
  fs.writeFileSync(script, "");
  assert.equal(AgyInbox.isInstalled(hooks, script), true);
});

test("AntigravityPresence はロックされている .lock だけを開いている会話とみなす", () => {
  const dir = path.join(tmp, "presence");
  fs.mkdirSync(dir, { recursive: true });
  for (const n of ["a.lock", "b.lock", "c.txt"]) fs.writeFileSync(path.join(dir, n), "");
  const live = AntigravityPresence.liveConversationIds(dir, (f) => f.endsWith("a.lock"));
  assert.deepEqual([...live], ["a"]);
  assert.deepEqual([...AntigravityPresence.liveConversationIds(path.join(tmp, "missing"))], []);
});

test("GrokPresence: pid が生きていて Bridge が動かしていない会話だけ", () => {
  const file = path.join(tmp, "active_sessions.json");
  fs.writeFileSync(
    file,
    JSON.stringify([
      { session_id: "s-live", pid: 10, cwd: "C:\\a" },
      { session_id: "s-dead", pid: 11 },
      { session_id: "s-bridge", pid: 12 },
      { session_id: "", pid: 13 },
      { pid: 14 }
    ])
  );
  const live = GrokPresence.liveSessions(file, (pid) => pid !== 11, new Set(["s-bridge"]));
  assert.deepEqual([...live.entries()], [["s-live", { cwd: "C:\\a" }]]);
  assert.equal(GrokPresence.liveSessions(path.join(tmp, "none.json")).size, 0);
});

test("OpenCodeTerminals: 生きている buddy-opencode の場所で最新のトップレベルの会話", () => {
  const dir = path.join(tmp, "oc-terms");
  fs.mkdirSync(dir, { recursive: true });
  const work = path.join(tmp, "work");
  fs.writeFileSync(path.join(dir, "100.json"), JSON.stringify({ cwd: work }));
  fs.writeFileSync(path.join(dir, "200.json"), JSON.stringify({ cwd: path.join(tmp, "gone") }));
  const live = OpenCodeTerminals.liveDirectories(dir, (pid) => pid === 100);
  assert.equal(live.size, 1);
  assert.equal(fs.existsSync(path.join(dir, "200.json")), false, "死んだ pid の台帳は消す");
  const ids = OpenCodeTerminals.terminalSessionIds(
    [
      { id: "old", directory: work, time: { updated: 1 } },
      { id: "new", directory: `${work}${path.sep}`, time: { updated: 5 } },
      { id: "child", directory: work, parentID: "new", time: { updated: 9 } },
      { id: "other", directory: path.join(tmp, "elsewhere"), time: { updated: 9 } }
    ],
    live
  );
  assert.deepEqual([...ids], ["new"]);
});

test("OpenCodeServeTranslator: ターミナルの発話・返事・道具・idle を流し、自分の発話は出し直さない", () => {
  const t = new OpenCodeServeTranslator("opencode", "ses-1");
  const out: SessionEvent[] = [];
  const feed = (type: string, props: Record<string, unknown>) => out.push(...t.feed(type, props));
  feed("message.updated", { info: { id: "u1", role: "user", sessionID: "ses-1" } });
  feed("message.part.updated", { part: { id: "p1", messageID: "u1", type: "text", text: "ターミナルから" } });
  feed("message.updated", { info: { id: "a1", role: "assistant", sessionID: "ses-1" } });
  feed("message.part.updated", { part: { id: "p2", messageID: "a1", type: "text", text: "" } });
  feed("message.part.delta", { partID: "p2", messageID: "a1", field: "text", delta: "こん" });
  feed("message.part.updated", { part: { id: "p2", messageID: "a1", type: "text", text: "こんにちは" } });
  feed("message.part.updated", { part: { id: "p3", messageID: "a1", type: "tool", callID: "c1", tool: "bash", state: { status: "running", input: { command: "ls" } } } });
  feed("message.part.updated", { part: { id: "p3", messageID: "a1", type: "tool", callID: "c1", tool: "bash", state: { status: "completed", output: "x" } } });
  feed("session.idle", { sessionID: "ses-1" });
  feed("session.idle", { sessionID: "ses-1" });
  assert.deepEqual(
    out.map((e) => [e.type, e.type.startsWith("tool_") ? e.toolName : (e.content ?? "")]),
    [
      ["user_message", "ターミナルから"],
      ["assistant_delta", "こん"],
      ["assistant_delta", "にちは"],
      ["tool_start", "bash"],
      ["tool_end", "bash"],
      ["done", ""]
    ]
  );
  assert.equal(out.at(-1)?.messageId, "a1");

  const own = new OpenCodeServeTranslator("opencode", "ses-1");
  own.noteOwnText("iPhone から");
  own.feed("message.updated", { info: { id: "u2", role: "user" } });
  assert.deepEqual(own.feed("message.part.updated", { part: { id: "q1", messageID: "u2", type: "text", text: "iPhone から" } }), []);
  assert.deepEqual(own.feed("session.error", { error: { data: { message: "boom" } } }).map((e) => [e.type, e.content]), [
    ["error", "boom"],
    ["done", undefined]
  ]);
});

test("historyFromServe は本文の part だけを順に拾う", () => {
  const h = historyFromServe([
    { info: { id: "m1", role: "user", time: { created: 1_700_000_000_000 } }, parts: [{ type: "text", text: "質問" }] },
    { info: { id: "m2", role: "assistant" }, parts: [{ type: "reasoning", text: "x" }, { type: "text", text: "答え" }, { type: "text", text: "注", synthetic: true }] },
    { info: { id: "m3", role: "assistant" }, parts: [{ type: "tool" }] }
  ]);
  assert.deepEqual(h.map((m) => [m.role, m.content, m.messageId]), [
    ["user", "質問", "m1"],
    ["assistant", "答え", "m2"]
  ]);
  assert.equal(h[0].createdAt, new Date(1_700_000_000_000).toISOString());
});

/** 共有 app-server の偽物（WebSocket）。initialize / thread/resume に答え、ターミナル側のターンを流せる。 */
async function fakeSharedServer(token: string): Promise<{ url: string; push: (m: Record<string, unknown>) => void; received: Array<Record<string, unknown>>; close: () => Promise<void> }> {
  const received: Array<Record<string, unknown>> = [];
  const wss = new WebSocketServer({ host: "127.0.0.1", port: 0, verifyClient: (info: { req: { headers: Record<string, string | string[] | undefined> } }) => info.req.headers.authorization === `Bearer ${token}` });
  const sockets = new Set<import("ws").WebSocket>();
  wss.on("connection", (ws) => {
    sockets.add(ws);
    ws.on("message", (raw) => {
      const m = JSON.parse(String(raw)) as Record<string, unknown>;
      received.push(m);
      const params = (m.params ?? {}) as Record<string, unknown>;
      if (m.method === "initialize") ws.send(JSON.stringify({ id: m.id, result: {} }));
      else if (m.method === "thread/resume") ws.send(JSON.stringify({ id: m.id, result: { thread: { id: params.threadId } } }));
    });
  });
  await new Promise<void>((r) => wss.once("listening", () => r()));
  const port = (wss.address() as { port: number }).port;
  return {
    url: `ws://127.0.0.1:${port}`,
    received,
    push: (m) => {
      for (const s of sockets) s.send(JSON.stringify(m));
    },
    close: () =>
      new Promise((r) => {
        for (const s of sockets) s.terminate();
        wss.close(() => r());
      })
  };
}

test("JsonRpcWebSocket は Bearer で繋ぎ、要求と応答を対応づける", async () => {
  const server = await fakeSharedServer("secret");
  await assert.rejects(JsonRpcWebSocket.connect(server.url, "wrong"));
  const client = await JsonRpcWebSocket.connect(server.url, "secret");
  const res = await client.request("initialize", {});
  assert.deepEqual(res, { id: 1, result: {} });
  client.close();
  await server.close();
});

test("CodexAppServerSession は共有 app-server でターミナル側のターンを先行購読して流す", async () => {
  const server = await fakeSharedServer("tok");
  codexTerminals.open("thread-term", "C:\\w");
  const session = new CodexAppServerSession(
    "codex",
    "thread-term",
    undefined,
    { kind: "native", executable: "codex", label: "native:codex", shell: false },
    async () => ({ approvalPolicy: "on-request", sandboxMode: "workspace-write" }),
    async () => ({ url: server.url, token: "tok" })
  );
  const events: SessionEvent[] = [];
  await session.watch((e) => events.push(e));
  const resume = server.received.find((m) => m.method === "thread/resume");
  assert.deepEqual(resume?.params, { threadId: "thread-term", excludeTurns: true });
  // ターミナルで打ったターン（Bridge の turn/start ではないもの）。他の thread の通知は捨てる。
  server.push({ method: "turn/started", params: { threadId: "thread-term", turn: { id: "turn-r" } } });
  server.push({ method: "item/started", params: { threadId: "thread-term", turnId: "turn-r", item: { type: "userMessage", id: "um-1", content: [{ type: "text", text: "端末から" }] } } });
  server.push({ method: "item/agentMessage/delta", params: { threadId: "other", turnId: "x", itemId: "i-x", delta: "混ざらない" } });
  server.push({ method: "item/agentMessage/delta", params: { threadId: "thread-term", turnId: "turn-r", itemId: "msg-1", delta: "返事" } });
  server.push({ method: "turn/completed", params: { threadId: "thread-term", turn: { id: "turn-r", status: "completed" } } });
  // 他の thread の承認要求には答えない（ターミナル側の UI を潰さない）。
  server.push({ id: 77, method: "item/commandExecution/requestApproval", params: { threadId: "other", command: "ls" } });
  for (let i = 0; i < 50 && !events.some((e) => e.type === "done"); i += 1) await new Promise((r) => setTimeout(r, 20));
  assert.deepEqual(events.map((e) => [e.type, e.content ?? ""]), [
    ["user_message", "端末から"],
    ["assistant_delta", "返事"],
    ["done", ""]
  ]);
  assert.equal(events.at(-1)?.messageId, "msg-1");
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(server.received.some((m) => m.id === 77), false);
  await session.close();
  codexTerminals.close("thread-term");
  await server.close();
});

test("AntigravityTerminalMirror は行や文字の途中で切れた書き込みも 1 行ずつ流す", () => {
  const root = path.join(tmp, "agy-mirror");
  const id = "33333333-4444-5555-6666-777777777777";
  const file = AntigravityTranscript.path(id, root);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify({ type: "USER_INPUT", content: "前からある分" })}\n`);
  const got: string[] = [];
  const mirror = new AntigravityTerminalMirror(id, (e) => got.push(e.kind === "assistant" || e.kind === "user" ? `${e.kind}:${e.text}` : e.kind), root);
  mirror.start(60_000);
  const line = Buffer.from(`${JSON.stringify({ type: "PLANNER_RESPONSE", content: "日本語の返事" })}\n`, "utf8");
  // 「日」（3 バイト）の途中で切る。
  const cut = line.indexOf(Buffer.from("日", "utf8")) + 1;
  fs.appendFileSync(file, line.subarray(0, cut));
  mirror.poll();
  assert.deepEqual(got, []);
  fs.appendFileSync(file, line.subarray(cut));
  mirror.poll();
  mirror.stop();
  assert.deepEqual(got, ["assistant:日本語の返事", "turnEnd"]);
});

test("共有 app-server の起動行: .exe は ^ を 1 回、.cmd シムは 2 回。ログはリダイレクトで書く", () => {
  const exe = codexSharedCommandLine("C:\\bin\\codex.exe", ["--ws-token-file", "C:\\Users\\山田 (仕事)\\t"], "C:\\Users\\山田 (仕事)\\.buddyos\\codex-app-server.log");
  assert.equal(exe, '"C:\\bin\\codex.exe" ^"--ws-token-file^" ^"C:\\Users\\山田^ ^(仕事^)\\t^" >> "C:\\Users\\山田 (仕事)\\.buddyos\\codex-app-server.log" 2>&1');
  const shim = codexSharedCommandLine("C:\\npm\\codex.cmd", ["a b"], "C:\\l.log");
  assert.equal(shim, '"C:\\npm\\codex.cmd" ^^^"a^^^ b^^^" >> "C:\\l.log" 2>&1');
});

test("agy の承認 hook のスクリプトは Bridge の答えをそのまま返し、繋がらなければ拒否する", async () => {
  const file = path.join(tmp, "buddy-agy-approval.mjs");
  fs.writeFileSync(file, AgyApprovalHook.script());
  let seen: { token?: string; body?: string } = {};
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c: Buffer) => (body += c.toString("utf8")));
    req.on("end", () => {
      seen = { token: String(req.headers["x-buddyos-hook-token"]), body };
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ decision: "allow" }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  const port = (server.address() as { port: number }).port;
  const run = (url: string): Promise<string> =>
    new Promise((resolve) => {
      const child = spawn(process.execPath, [file], { env: { ...process.env, BUDDYOS_AGY_HOOK_URL: url, BUDDYOS_AGY_HOOK_TOKEN: "tok" } });
      let out = "";
      child.stdout.on("data", (c: Buffer) => (out += c.toString("utf8")));
      child.on("close", () => resolve(out.trim()));
      child.stdin.end(JSON.stringify({ toolCall: { name: "run_command", args: { CommandLine: "ls" } } }));
    });
  assert.deepEqual(JSON.parse(await run(`http://127.0.0.1:${port}/antigravity/hook`)), { decision: "allow" });
  assert.equal(seen.token, "tok");
  assert.equal((JSON.parse(seen.body ?? "{}") as { toolCall: { name: string } }).toolCall.name, "run_command");
  await new Promise<void>((r) => server.close(() => r()));
  assert.equal((JSON.parse(await run(`http://127.0.0.1:${port}/antigravity/hook`)) as { decision: string }).decision, "deny");
});
