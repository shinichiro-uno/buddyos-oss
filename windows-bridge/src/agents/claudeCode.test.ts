import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { SessionEvent } from "../protocol.js";

// 実ホームの ~/.buddyos・~/.claude を読まないよう、ホームを一時ディレクトリに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-claude-"));
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;

const { ClaudeCodeAdapter, claudeContentBlocks, claudeSessionTiming, userContent } = await import("./claudeCode.js");
const control = await import("./claudeControl.js");

after(() => {
  // Windows は止めた子プロセスが cwd を掴んだまま少し残ることがある。消せなくても失敗にしない。
  try {
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  } catch {
    /* 一時ディレクトリなので残っても害は無い */
  }
});

// 実機（claude 2.1.285）の stdout をそのまま使う（mac の ClaudeControlProtocolTests と同じ）。
const bashRequest =
  '{"type":"control_request","request_id":"dd7e27d0-8478-4460-8fae-933cd8ac6b90","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"echo approved > approved.txt","description":"Write approved"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo approved *"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/tmp/x"],"destination":"session"}],"tool_use_id":"toolu_1"}}';

test("制御行: can_use_tool・取り消し・未対応を読み、本文の行は読まない", () => {
  const parsed = control.parseControlLine(bashRequest);
  assert.equal(parsed?.kind, "canUseTool");
  if (parsed?.kind !== "canUseTool") return;
  assert.equal(parsed.request.requestId, "dd7e27d0-8478-4460-8fae-933cd8ac6b90");
  assert.equal(parsed.request.input.command, "echo approved > approved.txt");
  assert.equal(parsed.request.suggestions.length, 2);
  assert.equal(control.parseControlLine('{"type":"assistant","message":{"content":[{"type":"text","text":"the control_request type"}]}}'), undefined);
  assert.equal(control.parseControlLine("not json"), undefined);
  assert.deepEqual(control.parseControlLine('{"type":"control_cancel_request","request_id":"r1"}'), { kind: "cancel", requestId: "r1" });
  assert.deepEqual(control.parseControlLine('{"type":"control_request","request_id":"r2","request":{"subtype":"hook_callback"}}'), {
    kind: "unsupported",
    requestId: "r2",
    subtype: "hook_callback"
  });
});

test("承認カード: 候補があるときだけ「このセッションでは承認」、答えは claude の形で返す", () => {
  const parsed = control.parseControlLine(bashRequest);
  assert.ok(parsed?.kind === "canUseTool");
  const card = control.cardFor(parsed.request, "claude", "s")!;
  const m = card.metadata!;
  assert.equal(m.kind, "approval");
  assert.deepEqual([m.option_0_value, m.option_1_value, m.option_2_value], ["allow", "allowForSession", "deny"]);
  assert.equal(card.messageId, parsed.request.requestId);
  assert.equal(m.subtitle, "echo approved > approved.txt");
  const bare = control.cardFor({ requestId: "r", toolName: "Bash", input: { command: "ls" }, suggestions: [] }, "claude", "s")!;
  assert.equal(bare.metadata!.option_count, "2");

  const session = control.permissionResult(parsed.request, "allowForSession", {});
  assert.deepEqual(
    (session.updatedPermissions as Array<Record<string, unknown>>).map((p) => p.destination),
    ["session", "session"]
  );
  assert.equal(control.permissionResult(parsed.request, "deny", {}).behavior, "deny");
  assert.match(String(control.permissionResult(parsed.request, "やめて", {}).message), /やめて/);
  assert.deepEqual(control.successResponse("r", { behavior: "allow" }), {
    type: "control_response",
    response: { subtype: "success", request_id: "r", response: { behavior: "allow" } }
  });
});

test("質問カード: 全部の質問を questions_json で出し、answers_json を質問ごとに返す", () => {
  const input = {
    questions: [
      { question: "どちらにしますか？", header: "方式", options: [{ label: "A", description: "速い" }, { label: "B", description: "安全" }] },
      { question: "言語は？", header: "言語", options: [{ label: "TS" }, { label: "Swift" }], multiSelect: true }
    ]
  };
  const r = { requestId: "q1", toolName: "AskUserQuestion", input, suggestions: [] };
  const card = control.cardFor(r, "claude", "s")!;
  assert.equal(card.metadata!.kind, "userInput");
  assert.equal(card.metadata!.title, "方式");
  assert.equal(JSON.parse(card.metadata!.questions_json).length, 2);
  const result = control.permissionResult(r, "A", { answers_json: JSON.stringify({ "どちらにしますか？": "B", "言語は？": ["TS", "Swift"] }) });
  assert.deepEqual((result.updatedInput as Record<string, unknown>).answers, { "どちらにしますか？": "B", "言語は？": "TS, Swift" });
  // answers_json が無い古いアプリは、選んだ選択肢を答えにする。
  assert.deepEqual((control.permissionResult(r, "A", {}).updatedInput as Record<string, unknown>).answers, { "どちらにしますか？": "A", "言語は？": "A" });
});

test("画像: Claude が受け付ける形式は画像ブロックで渡し、履歴には目印を残す", () => {
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]).toString("base64");
  const inbound: SessionEvent = {
    type: "user_message",
    content: "これは何？",
    metadata: {
      attachment_count: "2",
      attachment_0_kind: "image",
      attachment_0_name: "a.png",
      attachment_0_mime: "image/jpg",
      attachment_0_b64: png,
      attachment_1_kind: "image",
      attachment_1_name: "c.heic",
      attachment_1_mime: "image/heic",
      attachment_1_b64: "AQ=="
    }
  };
  const { prompt, content } = userContent("これは何？", inbound, undefined);
  assert.equal(prompt, '[image "a.png" attached: image/jpg, 7 bytes]\n\n[image "c.heic" attached: image/heic, 1 bytes]\n\nこれは何？');
  assert.ok(Array.isArray(content));
  assert.deepEqual(content[0], { type: "image", source: { type: "base64", media_type: "image/jpeg", data: png } });
  // heic は画像ブロックで渡せないので目印だけ。
  assert.deepEqual(content[1], { type: "text", text: '[image "c.heic" attached: image/heic, 1 bytes]\n\nこれは何？' });
  assert.deepEqual(claudeContentBlocks("x", []), [{ type: "text", text: "x" }]);
});

// 偽の claude: stdin の stream-json を 1 行ずつ順に処理する。"bash" は承認を求め、"slow" は少し待ってから返す。
const log = path.join(tmp, "claude-log.jsonl");
const fake = path.join(tmp, "fake-claude.mjs");
fs.writeFileSync(
  fake,
  `import fs from "node:fs"; import readline from "node:readline";
const log = (o) => fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(o) + "\\n");
const send = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
const SID = "11111111-2222-4333-8444-555555555555";
log({ argv: process.argv.slice(2) });
const lines = []; let wake;
const rl = readline.createInterface({ input: process.stdin });
rl.on("line", (line) => { log({ line: JSON.parse(line) }); lines.push(JSON.parse(line)); wake?.(); });
const next = (pred) => new Promise((resolve) => { const check = () => { const i = lines.findIndex(pred); if (i >= 0) { wake = undefined; resolve(lines.splice(i, 1)[0]); } else { wake = check; } }; check(); });
for (;;) {
  const m = await next((l) => l.type === "user");
  const c = m.message.content;
  const text = typeof c === "string" ? c : c.find((b) => b.type === "text").text;
  send({ type: "system", subtype: "init", session_id: SID });
  if (text.includes("bash")) {
    send({ type: "control_request", request_id: "req-1", request: { subtype: "can_use_tool", tool_name: "Bash", input: { command: "ls" }, permission_suggestions: [] } });
    const r = await next((l) => l.type === "control_response");
    send({ type: "stream_event", event: { delta: { type: "text_delta", text: "perm:" + r.response.response.behavior } } });
  }
  if (text.startsWith("slow")) await new Promise((r) => setTimeout(r, 400));
  send({ type: "stream_event", event: { delta: { type: "text_delta", text: "ok:" + text } } });
  send({ type: "result", subtype: "success", result: "ok:" + text, session_id: SID });
}
`
);
const bin = process.platform === "win32" ? path.join(tmp, "claude.cmd") : path.join(tmp, "claude");
fs.writeFileSync(
  bin,
  process.platform === "win32" ? `@"${process.execPath}" "${fake}" %*\r\n` : `#!/bin/sh\nexec "${process.execPath}" "${fake}" "$@"\n`,
  { mode: 0o755 }
);

const store = {
  ensureSession() {},
  appendMessage() {
    return "";
  },
  replaceSessionId() {},
  list() {
    return [];
  },
  history() {
    return [];
  },
  rename() {
    return false;
  }
};

function readLog(): Array<Record<string, unknown>> {
  return fs.existsSync(log) ? fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l) as Record<string, unknown>) : [];
}

test("常駐: 1 本の claude で複数ターン・承認の往復・生成中の注入をこなす", async () => {
  const adapter = new ClaudeCodeAdapter("claude", { kind: "native", executable: bin, label: `native:${bin}`, shell: false }, store as never);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  const emit = (e: SessionEvent): void => {
    events.push(e);
    if (e.type === "action_request") void session.respondToAction!(e.messageId!, "allow", {});
  };
  const msg = (content: string): SessionEvent => ({ type: "user_message", agentId: "claude", content });
  const dones = (): number => events.filter((e) => e.type === "done").length;
  try {
    await session.send("hello", msg("hello"), emit);
    assert.equal(events[0].type, "session_started");
    assert.equal(events[0].sessionId, "11111111-2222-4333-8444-555555555555");
    assert.equal(session.sessionId, "11111111-2222-4333-8444-555555555555");
    assert.equal(dones(), 1);

    // 承認: カードを出し、答えを stdin に返して続ける。
    await session.send("bash please", msg("bash please"), emit);
    assert.ok(events.some((e) => e.type === "action_request" && e.metadata?.kind === "approval"));
    assert.ok(events.some((e) => e.type === "action_resolved"));
    assert.ok(events.some((e) => e.type === "assistant_delta" && e.content === "perm:allow"));

    // 生成中の注入: 同じプロセスに流し、ターンごとに done が出る。
    const slow = session.send("slow one", msg("slow one"), emit);
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(session.inject!("follow", msg("follow"), emit), true);
    await slow;
    for (let i = 0; i < 50 && dones() < 4; i += 1) await new Promise((r) => setTimeout(r, 50));
    assert.equal(dones(), 4);
    assert.ok(events.some((e) => e.type === "assistant_delta" && e.content === "ok:follow"));

    const entries = readLog();
    const argvs = entries.filter((e) => e.argv);
    assert.equal(argvs.length, 1, "プロセスは 1 本だけ");
    const argv = argvs[0].argv as string[];
    assert.ok(argv.includes("--input-format"));
    assert.equal(argv[argv.indexOf("--permission-prompt-tool") + 1], "stdio");
    const response = entries.map((e) => e.line as Record<string, unknown> | undefined).find((l) => l?.type === "control_response");
    assert.deepEqual(response, {
      type: "control_response",
      response: { subtype: "success", request_id: "req-1", response: { behavior: "allow", updatedInput: { command: "ls" } } }
    });

    // 停止: 停止の制御要求に答えない CLI は、返事を待つ時間の後に（背景の作業が無ければ）今までどおりプロセスを止め、
    // 次の送信は --resume で起こし直す（答える CLI ならプロセスは残る。背景の作業があれば、答えなくても残す）。
    // 偽 claude は答えないので、待つ時間を縮めて確かめる。
    const stopped = session.send("slow stop", msg("slow stop"), emit);
    await new Promise((r) => setTimeout(r, 100));
    claudeSessionTiming.interruptGraceMs = 100;
    try {
      await session.interrupt!();
      await stopped;
    } finally {
      claudeSessionTiming.interruptGraceMs = 3000;
    }
    assert.equal(events.at(-1)?.type, "done");
    await session.send("again", msg("again"), emit);
    const restarted = readLog().filter((e) => e.argv);
    assert.equal(restarted.length, 2);
    const resumed = restarted[1].argv as string[];
    assert.equal(resumed[resumed.indexOf("--resume") + 1], "11111111-2222-4333-8444-555555555555");
  } finally {
    await session.close();
  }
});

test("無人実行（cron）は承認を尋ねない", async () => {
  const adapter = new ClaudeCodeAdapter("claude", { kind: "native", executable: "claude", label: "native", shell: false }, store as never);
  const session = (await adapter.openSession(undefined, tmp, { permissionMode: "edit", unattended: true })) as unknown as { argsForPrompt(): string[] };
  const args = session.argsForPrompt();
  assert.ok(!args.includes("--permission-prompt-tool"));
  assert.equal(args[args.indexOf("--permission-mode") + 1], "acceptEdits");
});
