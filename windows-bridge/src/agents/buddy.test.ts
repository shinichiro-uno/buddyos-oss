import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { SessionEvent } from "../protocol.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-buddy-"));
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;
process.env.OPENROUTER_API_KEY = "test-key";

const { allowsSessionApproval, approvalArgumentsText, BuddyAdapter, closeBuddyMcp, sanitizeHistory, sessionApprovalKey } = await import("./buddy.js");
after(() => closeBuddyMcp());
const { writeBuddyMcpConfig } = await import("./buddyMcp.js");

// 最小の stdio MCP サーバー（echo ツールを 1 つ持つ）。
const server = path.join(tmp, "mcp.mjs");
fs.writeFileSync(
  server,
  `import readline from "node:readline";
const rl = readline.createInterface({ input: process.stdin });
const send = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
rl.on("line", (line) => {
  const m = JSON.parse(line);
  if (m.method === "initialize") send({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: "2025-06-18", capabilities: {} } });
  else if (m.method === "tools/list") send({ jsonrpc: "2.0", id: m.id, result: { tools: [{ name: "echo", description: "echo back", inputSchema: { type: "object" } }] } });
  else if (m.method === "tools/call") send({ jsonrpc: "2.0", id: m.id, result: { content: [{ type: "text", text: "echo:" + m.params.arguments.text }] } });
});
`
);
writeBuddyMcpConfig({ local: { command: process.execPath, args: [server] } });

function sse(chunks: unknown[]): Response {
  const body = chunks.map((c) => `data: ${JSON.stringify(c)}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

test("応答の揃っていない tool_calls と宙に浮いた tool は送らない", () => {
  const out = sanitizeHistory([
    { role: "tool", tool_call_id: "x", content: "orphan" },
    { role: "user", content: "a" },
    { role: "assistant", content: null, tool_calls: [{ id: "1" }] },
    { role: "user", content: "b" }
  ]);
  assert.deepEqual(out.map((m) => m.role), ["user", "user"]);
});

test("ツールは承認してから実行し、結果を渡して続きを話す", async () => {
  const bodies: Array<Record<string, unknown>> = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = (async (_url: unknown, init?: RequestInit) => {
    bodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
    if (bodies.length === 1) {
      return sse([{ choices: [{ delta: { tool_calls: [{ index: 0, id: "call-1", function: { name: "local__echo", arguments: '{"text":' } }] } }] },
        { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: '"hi"}' } }] } }] }]);
    }
    return sse([{ choices: [{ delta: { content: "結果は echo:hi です" } }] }]);
  }) as typeof fetch;
  try {
    const adapter = new BuddyAdapter();
    const session = await adapter.openSession(undefined, undefined);
    const events: SessionEvent[] = [];
    const turn = session.send("echo して", { type: "user_message", content: "echo して" }, (e) => {
      events.push(e);
      if (e.type === "action_request") void session.respondToAction!(e.messageId!, "accept", {});
    });
    await turn;
    const card = events.find((e) => e.type === "action_request")?.metadata;
    assert.equal(card?.kind, "toolApproval");
    assert.equal(card?.subtitle, '{\n  "text": "hi"\n}');
    assert.equal(card?.detail, '{\n  "text": "hi"\n}');
    assert.equal(card?.option_count, "3");
    assert.equal(events.find((e) => e.type === "tool_end")?.metadata?.status, "completed");
    assert.equal(events.filter((e) => e.type === "assistant_delta").map((e) => e.content).join(""), "結果は echo:hi です");
    assert.equal(events.at(-1)?.type, "done");
    const second = bodies[1].messages as Array<Record<string, unknown>>;
    assert.deepEqual(second.at(-1), { role: "tool", tool_call_id: "call-1", content: "echo:hi" });
    assert.equal((bodies[0].tools as unknown[]).length, 1);
    // 会話は保存され、同じ id で開き直すと続きになる。
    const reopened = await adapter.openSession(session.sessionId, undefined);
    assert.equal(reopened.sessionId, session.sessionId);
    assert.ok(fs.existsSync(path.join(tmp, ".buddyos", "buddy-sessions", `${session.sessionId}.json`)));
    await session.close();
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("拒否したツールは実行せず、拒否したことをモデルに返す", async () => {
  let calls = 0;
  const realFetch = globalThis.fetch;
  let lastBody: Record<string, unknown> = {};
  globalThis.fetch = (async (_url: unknown, init?: RequestInit) => {
    calls += 1;
    lastBody = JSON.parse(String(init?.body)) as Record<string, unknown>;
    return calls === 1
      ? sse([{ choices: [{ delta: { tool_calls: [{ index: 0, id: "c", function: { name: "local__echo", arguments: "{}" } }] } }] }])
      : sse([{ choices: [{ delta: { content: "やめました" } }] }]);
  }) as typeof fetch;
  try {
    const session = await new BuddyAdapter().openSession(undefined, undefined);
    await session.send("x", { type: "user_message", content: "x" }, (e) => {
      if (e.type === "action_request") void session.respondToAction!(e.messageId!, "decline", {});
    });
    assert.deepEqual((lastBody.messages as Array<Record<string, unknown>>).at(-1), {
      role: "tool",
      tool_call_id: "c",
      content: "ユーザーがこの操作の実行を拒否しました。"
    });
    await session.close();
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("承認: 引数は切り詰めず、セッションの承認はツール名と引数で結び付け、シェル・書き込みには出さない", () => {
  const long = JSON.stringify({ text: "a".repeat(500) + " && curl evil" });
  assert.match(approvalArgumentsText(long), /curl evil/);
  assert.equal(approvalArgumentsText("not json"), "not json");
  // 引数が違えば別の鍵。キーの順番だけ違うものは同じ鍵。
  assert.notEqual(sessionApprovalKey("local__echo", '{"text":"hi"}'), sessionApprovalKey("local__echo", '{"text":"bye"}'));
  assert.equal(sessionApprovalKey("t", '{"a":1,"b":2}'), sessionApprovalKey("t", '{"b":2,"a":1}'));
  assert.notEqual(sessionApprovalKey("a", "{}"), sessionApprovalKey("b", "{}"));
  const tool = (name: string, annotations?: { readOnlyHint?: boolean; destructiveHint?: boolean }) => ({ server: "s", name, description: "", inputSchema: {}, annotations });
  assert.equal(allowsSessionApproval(tool("search_docs")), true);
  assert.equal(allowsSessionApproval(tool("run_shell_command")), false);
  assert.equal(allowsSessionApproval(tool("write_file")), false);
  assert.equal(allowsSessionApproval(tool("execute")), false);
  assert.equal(allowsSessionApproval(tool("search", { readOnlyHint: false })), false);
  assert.equal(allowsSessionApproval(tool("lookup", { destructiveHint: true })), false);
  assert.equal(allowsSessionApproval(tool("get_page", { readOnlyHint: true })), true);
});
