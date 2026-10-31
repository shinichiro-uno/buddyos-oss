import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { SessionEvent } from "../protocol.js";

// 実ホームの ~/.buddyos・~/.claude を読まないよう、ホームを一時ディレクトリに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-control-"));
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;
delete process.env.BUDDYOS_CLAUDE_PERMISSION_PROMPTS;
after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const { approvalCard, initializeRequest, parseControlLine, stopTaskRequest, permissionResult, questionCard, questionAnswers } = await import("./claudeControl.js");
const { ClaudeCodeAdapter } = await import("./claudeCode.js");
const { JsonSessionStore } = await import("../sessionStore.js");

const QUESTIONS = [
  { question: "どの言語？", header: "言語", options: [{ label: "TS", description: "型あり" }, { label: "Go" }] },
  { question: "どれを入れる？", header: "機能", multiSelect: true, options: [{ label: "ログ" }, { label: "通知" }] }
];

test("制御行の読み取り: can_use_tool / 取り下げ / 未対応。普通の行は読まない", () => {
  assert.equal(parseControlLine('{"type":"stream_event","event":{}}'), undefined);
  const req = parseControlLine(
    JSON.stringify({ type: "control_request", request_id: "r1", request: { subtype: "can_use_tool", tool_name: "Bash", input: { command: "ls" }, permission_suggestions: [{ type: "addRules" }] } })
  );
  assert.deepEqual(req, { kind: "canUseTool", request: { requestId: "r1", toolName: "Bash", input: { command: "ls" }, suggestions: [{ type: "addRules" }] } });
  assert.deepEqual(parseControlLine('{"type":"control_cancel_request","request_id":"r1"}'), { kind: "cancel", requestId: "r1" });
  assert.deepEqual(parseControlLine('{"type":"control_request","request_id":"r2","request":{"subtype":"hook_callback"}}'), { kind: "unsupported", requestId: "r2", subtype: "hook_callback" });
});

test("こちらから書く制御要求の 1 行の形: initialize（perTaskStopAffordance）と stop_task（task_id）", () => {
  assert.equal(
    JSON.stringify(initializeRequest("r1")),
    '{"type":"control_request","request_id":"r1","request":{"subtype":"initialize","perTaskStopAffordance":true}}'
  );
  assert.equal(
    JSON.stringify(stopTaskRequest("r2", "br1svjoeb")),
    '{"type":"control_request","request_id":"r2","request":{"subtype":"stop_task","task_id":"br1svjoeb"}}'
  );
});

test("質問カードは全問を questions_json で渡し、答えは質問ごとに返す（1 問目の答えを全部に入れない）", () => {
  const r = { requestId: "q1", toolName: "AskUserQuestion", input: { questions: QUESTIONS }, suggestions: [] };
  const card = questionCard(r, "claude", "s1")!;
  assert.equal(card.metadata?.kind, "userInput");
  const qs = JSON.parse(card.metadata!.questions_json) as Array<{ id: string; multiSelect: boolean }>;
  assert.deepEqual(qs.map((q) => [q.id, q.multiSelect]), [["どの言語？", false], ["どれを入れる？", true]]);
  assert.equal(card.metadata?.option_0_title, "TS");
  const answers_json = JSON.stringify({ "どの言語？": "Go", "どれを入れる？": ["ログ", "通知"] });
  assert.deepEqual(questionAnswers(QUESTIONS, "Go", { answers_json }), { "どの言語？": "Go", "どれを入れる？": "ログ, 通知" });
  // 古いクライアント（decision だけ）は全問に decision
  assert.deepEqual(questionAnswers(QUESTIONS, "TS", {}), { "どの言語？": "TS", "どれを入れる？": "TS" });
  const result = permissionResult(r, "Go", { answers_json }) as { behavior: string; updatedInput: { answers: Record<string, string>; questions: unknown[] } };
  assert.equal(result.behavior, "allow");
  assert.equal(result.updatedInput.questions.length, 2);
  assert.equal(result.updatedInput.answers["どれを入れる？"], "ログ, 通知");
});

test("承認: このセッションでは承認は候補を session に付け替え、拒否の理由は Claude に渡す", () => {
  const r = { requestId: "a1", toolName: "Bash", input: { command: "rm -rf build" }, suggestions: [{ type: "addRules", destination: "localSettings" }] };
  const card = approvalCard(r, "claude", "s1");
  assert.equal(card.metadata?.option_count, "3");
  assert.equal(card.metadata?.subtitle, "rm -rf build");
  assert.deepEqual(permissionResult(r, "allowForSession", {}), { behavior: "allow", updatedInput: r.input, updatedPermissions: [{ type: "addRules", destination: "session" }] });
  assert.equal((permissionResult(r, "deny", {}) as { behavior: string }).behavior, "deny");
  assert.match(String((permissionResult(r, "ビルドは消さないで", {}) as { message: string }).message), /ビルドは消さないで/);
  assert.equal(approvalCard({ ...r, suggestions: [] }, "claude", "s1").metadata?.option_count, "2");
});

/* ── Claude Code（CLI 経路）の偽 claude。stdin の stream-json を読み、承認を尋ね、返事を本文に書いて終える ── */

const FAKE_CLAUDE = `#!/usr/bin/env node
const fs = require("node:fs");
fs.writeFileSync(process.env.FAKE_CLAUDE_ARGS, JSON.stringify(process.argv.slice(2)));
const out = (m) => process.stdout.write(JSON.stringify(m) + "\\n");
let buf = "";
process.stdin.on("data", (c) => {
  buf += c;
  let i;
  while ((i = buf.indexOf("\\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    const m = JSON.parse(line);
    if (m.type === "user") {
      out({ type: "system", subtype: "init", session_id: "11111111-2222-3333-4444-555555555555" });
      out({ type: "control_request", request_id: "req-1", request: { subtype: "can_use_tool", tool_name: "AskUserQuestion", input: { questions: ${JSON.stringify(QUESTIONS)} } } });
    } else if (m.type === "control_response") {
      const text = JSON.stringify(m.response.response);
      out({ type: "stream_event", session_id: "11111111-2222-3333-4444-555555555555", event: { type: "content_block_delta", delta: { type: "text_delta", text } } });
      out({ type: "result", subtype: "success", result: text, session_id: "11111111-2222-3333-4444-555555555555" });
    }
  }
});
process.stdin.on("end", () => process.exit(0));
`;

test("Claude Code（CLI）: --permission-prompt-tool stdio の質問をカードにし、全問の答えを stdin に返す", { skip: process.platform === "win32" }, async () => {
  const bin = path.join(tmp, "fake-claude.cjs");
  fs.writeFileSync(bin, FAKE_CLAUDE, { mode: 0o755 });
  const argsFile = path.join(tmp, "claude-args.json");
  process.env.FAKE_CLAUDE_ARGS = argsFile;
  const adapter = new ClaudeCodeAdapter("claude", { kind: "native", executable: bin, label: `native:${bin}`, shell: false }, new JsonSessionStore(path.join(tmp, "store")));
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  let onCard: ((e: SessionEvent) => void) | undefined;
  const emit = (e: SessionEvent): void => {
    events.push(e);
    if (e.type === "action_request") onCard?.(e);
  };
  const card = new Promise<SessionEvent>((resolve) => (onCard = resolve));
  const turn = session.send("聞いて", { type: "user_message", content: "聞いて" }, emit);
  const request = await card;
  assert.equal(request.metadata?.requestId, "req-1");
  assert.equal((JSON.parse(request.metadata!.questions_json) as unknown[]).length, 2);
  await session.respondToAction!("req-1", "Go", { answers_json: JSON.stringify({ "どの言語？": "Go", "どれを入れる？": ["通知"] }) });
  await turn;
  const args = JSON.parse(fs.readFileSync(argsFile, "utf8")) as string[];
  assert.equal(args[args.indexOf("--permission-prompt-tool") + 1], "stdio");
  assert.equal(args[args.indexOf("--input-format") + 1], "stream-json");
  const text = events.filter((e) => e.type === "assistant_delta").map((e) => e.content).join("");
  const reply = JSON.parse(text) as { behavior: string; updatedInput: { answers: Record<string, string> } };
  assert.equal(reply.behavior, "allow");
  assert.deepEqual(reply.updatedInput.answers, { "どの言語？": "Go", "どれを入れる？": "通知" });
  assert.ok(events.some((e) => e.type === "action_resolved" && e.messageId === "req-1"), "他の画面のカードも閉じさせる");
  assert.ok(events.some((e) => e.type === "done"));
  assert.ok(!events.some((e) => e.type === "error"));
  assert.equal(session.sessionId, "11111111-2222-3333-4444-555555555555");
  // Claude Code はチャットごとに常駐するので、閉じないとテストのプロセスが終わらない。
  await session.close();
});
