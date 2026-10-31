import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import type { SessionEvent } from "../protocol.js";
import { ClaudeCodeAdapter, claudeSessionTiming, workflowPhases, type BackgroundJobHost } from "./claudeCode.js";
import type { AgentSession } from "./types.js";

// spawn 経路（ClaudeCodeSession）のターンの結び付け・停止・dynamic workflow・バックグラウンドの作業の後片付けを、
// 偽物の claude で確かめる（docs/BACKGROUND_WORK_2026-10-21.md §3.3。mac の ClaudeSpawnBackgroundTests と同じ場面）。
// 偽物は claude 2.1.300 と同じ形の行（command_lifecycle・user_message_uuids・origin 付きの result・control_response）を、
// 本文の語で選んだ並びで出す。

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-claude-bg-"));
after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const fake = path.join(tmp, "fake-claude.mjs");
fs.writeFileSync(
  fake,
  `import fs from "node:fs"; import readline from "node:readline";
const SID = "44444444-4444-4444-8444-444444444444";
fs.appendFileSync(process.env.FAKE_CLAUDE_STARTS, "start\\n");
const say = (o) => process.stdout.write(JSON.stringify(o) + "\\n");
const life = (u, state) => say({ type: "command_lifecycle", command_uuid: u, state, session_id: SID });
const init = () => say({ type: "system", subtype: "init", session_id: SID, model: "claude-fake-1" });
const status = (uuids) => say({ type: "system", subtype: "status", status: "requesting", user_message_uuids: uuids, session_id: SID });
const plainStatus = () => say({ type: "system", subtype: "status", status: "requesting", session_id: SID });
const text = (t) => say({ type: "stream_event", parent_tool_use_id: null, event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: t } }, session_id: SID });
const result = (extra, r) => say({ type: "result", subtype: "success", is_error: false, result: r, ...extra, session_id: SID });
const task = (o) => say({ type: "system", ...o, session_id: SID });
const tool = (name, input, parent) => say({ type: "assistant", parent_tool_use_id: parent ?? null, message: { role: "assistant", content: [{ type: "tool_use", id: "toolu_" + name + (parent ? "_sub" : ""), name, input }] }, session_id: SID });
const finish = (u, r) => { result({ user_message_uuid: u, user_message_uuids: [u] }, r); life(u, "completed"); };
const startAgent = () => task({ subtype: "task_started", task_id: "ag1", task_type: "local_agent", subagent_type: "Explore", description: "look around", is_backgrounded: true, run_id: "r1" });
let cur = "";
readline.createInterface({ input: process.stdin }).on("line", (raw) => {
  fs.appendFileSync(process.env.FAKE_CLAUDE_STDIN, raw + "\\n");
  const line = JSON.parse(raw);
  if (line.type === "control_request") {
    const sub = line.request.subtype;
    if (sub === "initialize") {
      // FAKE_CLAUDE_OLD: 行の停止を知らない古い CLI（initialize を断る）。
      if (process.env.FAKE_CLAUDE_OLD) say({ type: "control_response", response: { subtype: "error", request_id: line.request_id, error: "Unsupported control request subtype: initialize" } });
      else say({ type: "control_response", response: { subtype: "success", request_id: line.request_id, response: { commands: [], account: { email: "sentinel@example.invalid" }, pid: 424242 } } });
      return;
    }
    if (sub === "stop_task") {
      const id = line.request.task_id;
      const mode = process.env.FAKE_CLAUDE_STOP || "";
      if (mode === "silent") return;
      const reply = (r) => say({ type: "control_response", response: { request_id: line.request_id, ...r } });
      if (mode === "error") return reply({ subtype: "error", error: "stop_task: no such task" });
      // 押した直後に task が終わった: 終わりの知らせが先に届き、CLI は「Task X is not running」と返す。
      if (mode === "gone") {
        task({ subtype: "task_updated", task_id: id, patch: { status: "completed", end_time: Date.now() } });
        task({ subtype: "task_notification", task_id: id, status: "completed", summary: "done" });
        return reply({ subtype: "error", error: "Task " + id + " is not running (status: completed)" });
      }
      // 返事の後で、カードが終わる前に進み具合が届く。
      if (mode === "slowend") {
        reply({ subtype: "success", response: {} });
        setTimeout(() => task({ subtype: "task_progress", task_id: id, description: "winding down" }), 60);
        setTimeout(() => { task({ subtype: "task_updated", task_id: id, patch: { status: "killed", end_time: Date.now() } }); task({ subtype: "task_notification", task_id: id, status: "stopped", summary: "stopped" }); }, 160);
        return;
      }
      if (mode === "old") return reply({ subtype: "error", error: "Unsupported control request subtype: stop_task" });
      if (mode !== "idle" && mode !== "stuck") {
        task({ subtype: "task_updated", task_id: id, patch: { status: "killed", end_time: Date.now() } });
        task({ subtype: "task_notification", task_id: id, status: "stopped", summary: "stopped" });
        task({ subtype: "background_tasks_changed", tasks: [] });
      }
      return reply({ subtype: "success", response: {} });
    }
    // FAKE_CLAUDE_DEAF: 停止の制御要求に答えない CLI（Bridge は今までどおりプロセスを止める）。
    if (process.env.FAKE_CLAUDE_DEAF) return;
    // FAKE_CLAUDE_LATEACK: 返事だけが猶予を過ぎてから届く CLI（ターンは中断しない）。
    if (process.env.FAKE_CLAUDE_LATEACK) {
      setTimeout(() => say({ type: "control_response", response: { subtype: "success", request_id: line.request_id, response: { still_queued: [] } } }), 700);
      return;
    }
    say({ type: "control_response", response: { subtype: "success", request_id: line.request_id, response: { still_queued: [] } } });
    status([cur]);
    say({ type: "user", parent_tool_use_id: null, message: { role: "user", content: [{ type: "text", text: "[Request interrupted by user]" }] }, session_id: SID });
    say({ type: "result", subtype: "error_during_execution", is_error: true, user_message_uuid: cur, user_message_uuids: [cur], session_id: SID });
    life(cur, "completed");
    cur = "";
    return;
  }
  if (line.type !== "user") return;
  const u = line.uuid;
  const c = line.message.content;
  const t = typeof c === "string" ? c : c.find((b) => b.type === "text").text;
  life(u, "queued");
  if (t.includes("taken")) {
    // 起こしている間に claude --bg のワーカーが起きた: CLI はこの文を stderr に出して終わる。
    process.stderr.write("Error: session is running in the background (a1b2c3d4); use claude attach a1b2c3d4\\n");
    process.exit(1);
  } else if (t.includes("sepsecond")) {
    // 2.1.300 の U3: 差し込んだ発話は今のターンに合流せず、前の result の後に別のターンとして走る。
    const first = cur; cur = "";
    finish(first, "a");
    life(u, "started"); status([u]); text("b"); finish(u, "b");
  } else if (t.includes("inject")) {
    life(u, "started"); status([cur, u]); text("both"); life(u, "completed");
    result({ user_message_uuid: cur, user_message_uuids: [cur, u] }, "both"); life(cur, "completed"); cur = "";
    init(); plainStatus(); text("report"); result({ origin: { kind: "task-notification", producer: "session-task" } }, "report");
  } else if (t.includes("subapproval")) {
    // 背景のサブエージェント（ag1）の承認待ちと、main の承認待ちが並んだまま、ターンが走っている。
    life(u, "started"); init(); status([u]); startAgent(); text("partial"); cur = u;
    say({ type: "control_request", request_id: "ap-sub", request: { subtype: "can_use_tool", tool_name: "Bash", input: { command: "touch x" }, agent_id: "ag1" } });
    say({ type: "control_request", request_id: "ap-main", request: { subtype: "can_use_tool", tool_name: "Bash", input: { command: "touch y" } } });
  } else if (t.includes("slow") || t.includes("stop")) {
    life(u, "started"); init(); status([u]); text("partial"); cur = u;
  } else if (t.includes("workflow")) {
    life(u, "started"); init(); status([u]);
    task({ subtype: "task_started", task_id: "w1", task_type: "local_workflow", workflow_name: "review", description: "Review the change", is_backgrounded: true });
    task({ subtype: "task_progress", task_id: "w1", description: "planning", workflow_progress: [
      { type: "workflow_phase", index: 1, title: "Plan" },
      { type: "workflow_agent", index: 1, label: "planner", phaseIndex: 1, phaseTitle: "Plan", state: "progress", startedAt: 1760000000000 },
      { type: "workflow_agent", index: 2, label: "checker", state: "error", error: "boom" }] });
    task({ subtype: "task_notification", task_id: "a1", status: "completed", summary: "the CI workflow file is fine" });
    text("launched"); finish(u, "launched");
    task({ subtype: "task_updated", task_id: "w1", patch: { status: "killed", end_time: 1760000005000 } });
    task({ subtype: "task_notification", task_id: "w1", status: "stopped", summary: "stopped" });
  } else if (t.includes("gap")) {
    // バックグラウンドのサブエージェントが終わり、知らせのターンが開く（init / status）が、最初の本文までに時間がかかる。
    life(u, "started"); init(); status([u]); startAgent(); text("launched"); finish(u, "launched");
    setTimeout(() => {
      task({ subtype: "task_updated", task_id: "ag1", patch: { status: "completed", end_time: Date.now() } });
      task({ subtype: "task_notification", task_id: "ag1", status: "completed", summary: "found it" });
      task({ subtype: "background_tasks_changed", tasks: [] });
      init(); plainStatus();
      setTimeout(() => { text("late report"); result({ origin: { kind: "task-notification", producer: "session-task" } }, "late report"); }, 700);
    }, 50);
  } else if (t.includes("behind")) {
    // 差し込んだ発話が CLI の待ち行列に残り、前のターンの result の後の別ターンとして走る。
    life(u, "queued");
    result({ user_message_uuid: cur, user_message_uuids: [cur] }, "first"); life(cur, "completed"); cur = "";
    setTimeout(() => { life(u, "started"); status([u]); text("second"); finish(u, "second"); }, 400);
  } else if (t.includes("quiet")) {
    life(u, "started"); init(); status([u]); text("plain"); finish(u, "plain");
    // 本文の無い知らせのターン（見せるものが無い）。
    init(); plainStatus(); result({ origin: { kind: "task-notification", producer: "session-task" } }, "");
  } else if (t.includes("background")) {
    life(u, "started"); init(); status([u]); startAgent();
    task({ subtype: "task_started", task_id: "w2", task_type: "local_workflow", workflow_name: "audit", is_backgrounded: true });
    task({ subtype: "task_progress", task_id: "w2", workflow_progress: [{ type: "workflow_agent", index: 1, label: "auditor", state: "progress" }] });
    text("started"); finish(u, "started");
  } else if (t.includes("later")) {
    // バックグラウンドのサブエージェントが、ターンの後で終わる（終わりの行と知らせのターンはターンの外で届く）。
    life(u, "started"); init(); status([u]); startAgent(); text("launched"); finish(u, "launched");
    setTimeout(() => {
      task({ subtype: "task_updated", task_id: "ag1", patch: { status: "completed", end_time: Date.now() } });
      task({ subtype: "task_notification", task_id: "ag1", status: "completed", summary: "found it", usage: { total_tokens: 1200, tool_uses: 3, duration_ms: 4000 } });
      task({ subtype: "background_tasks_changed", tasks: [] });
      init(); plainStatus(); text("finished"); result({ origin: { kind: "task-notification", producer: "session-task", runId: "r1" } }, "finished");
    }, 50);
  } else if (t.includes("plan")) {
    life(u, "started"); init(); status([u]);
    tool("TodoWrite", { todos: [{ content: "親 1", status: "pending" }, { content: "親 2", status: "pending" }] });
    // サブエージェント自身のチェックリスト（親のものを置き換えない）
    tool("TodoWrite", { todos: [{ content: "子", status: "in_progress" }] }, "toolu_Agent");
    text("planned"); finish(u, "planned");
  } else {
    life(u, "started"); init(); status([u]); text("plain"); finish(u, "plain");
  }
});
`
);
const bin = process.platform === "win32" ? path.join(tmp, "claude.cmd") : path.join(tmp, "claude");
fs.writeFileSync(
  bin,
  process.platform === "win32" ? `@"${process.execPath}" "${fake}" %*\r\n` : `#!/bin/sh\nexec "${process.execPath}" "${fake}" "$@"\n`,
  { mode: 0o755 }
);

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

interface Harness {
  session: AgentSession;
  events: SessionEvent[];
  emit: (e: SessionEvent) => void;
  stored: Array<{ role: string; content: string; messageId?: string }>;
  starts(): number;
  stdin(): string;
}

async function start(name: string, background?: BackgroundJobHost): Promise<Harness> {
  const dir = fs.mkdtempSync(path.join(tmp, `${name}-`));
  process.env.FAKE_CLAUDE_STARTS = path.join(dir, "starts");
  process.env.FAKE_CLAUDE_STDIN = path.join(dir, "stdin");
  const stored: Harness["stored"] = [];
  const store = {
    ensureSession() {},
    appendMessage(_agentId: string, _sessionId: string, role: string, content: string, _cwd: string | undefined, messageId?: string) {
      stored.push({ role, content, messageId });
      return "";
    },
    replaceSessionId() {},
    list: () => [],
    history: () => [],
    rename: () => false
  };
  const adapter = new ClaudeCodeAdapter("claude", { kind: "native", executable: bin, label: `native:${bin}`, shell: false }, store as never);
  if (background) adapter.attachBackground(background);
  const session = await adapter.openSession(undefined, dir, { permissionMode: "dangerous", unattended: true });
  const events: SessionEvent[] = [];
  const read = (file: string): string => (fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "");
  return {
    session,
    events,
    emit: (e) => events.push(e),
    stored,
    starts: () => read(path.join(dir, "starts")).split("\n").filter(Boolean).length,
    stdin: () => read(path.join(dir, "stdin"))
  };
}

const msg = (content: string): SessionEvent => ({ type: "user_message", agentId: "claude", content });

async function waitFor(events: SessionEvent[], pred: (e: SessionEvent) => boolean, timeoutMs = 10_000): Promise<SessionEvent> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const found = events.find(pred);
    if (found) return found;
    if (Date.now() > deadline) throw new Error("timed out waiting for event");
    await sleep(20);
  }
}

const payload = (e: SessionEvent): Record<string, unknown> | undefined =>
  e.type === "workflow_progress" ? (JSON.parse(e.content ?? "{}") as Record<string, unknown>) : undefined;
const payloads = (events: SessionEvent[]): Array<Record<string, unknown>> => events.map(payload).filter((p): p is Record<string, unknown> => p !== undefined);
const rows = (p: Record<string, unknown> | undefined): Array<Record<string, unknown>> => (p?.agents as Array<Record<string, unknown>> | undefined) ?? [];
/** subagents のカードの行（id → 最後に届いた行）。 */
function subagentRows(events: SessionEvent[]): Map<string, Record<string, unknown>> {
  const out = new Map<string, Record<string, unknown>>();
  for (const p of payloads(events)) if (p.taskId === "subagents") for (const r of rows(p)) out.set(String(r.id), r);
  return out;
}

test("生成中に差し込んだ発話は今のターンに合流し、1 つの result で両方閉じる。続く知らせのターンは本文と done（origin）で届く", async () => {
  const h = await start("inject");
  try {
    const first = h.session.send("slow first", msg("slow first"), h.emit);
    const a = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial")).messageId!;
    const second = h.session.send("inject second", msg("inject second"), h.emit);
    const b = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "both")).messageId!;
    await first;
    await second;
    const n = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "report")).messageId!;
    const notificationDone = await waitFor(h.events, (e) => e.type === "done" && e.messageId === n);

    assert.notEqual(a, b, "差し込んだ発話の返事は、その発話の吹き出しに出す");
    assert.ok(![a, b].includes(n), "知らせのターンは別の吹き出し");
    assert.equal(notificationDone.metadata?.origin, "task-notification");
    assert.ok(h.events.some((e) => e.type === "assistant_turn_end" && e.messageId === a), "前の吹き出しを区切ってから流す");
    assert.deepEqual(h.events.filter((e) => e.type === "done").map((e) => e.messageId), [b, n], "result 1 つに done 1 つ");
    assert.ok(!h.events.some((e) => e.type === "error"));
    assert.deepEqual(
      h.stored.filter((m) => m.role === "assistant").map((m) => [m.messageId, m.content]),
      [[a, "partial"], [b, "both"], [n, "report"]],
      "前の発話の途中までの本文も残す"
    );
    // stdin の user 行には uuid（messageId の小文字）を付ける。
    assert.ok(h.stdin().includes(`"uuid":"${a.toLowerCase()}"`));
    assert.ok(h.stdin().includes(`"uuid":"${b.toLowerCase()}"`));
    assert.equal(h.starts(), 1);
  } finally {
    await h.session.close();
  }
});

test("差し込んだ発話が別のターンとして待ち行列に残っている間の done は pending を持ち、残りが無くなれば付けない", async () => {
  const h = await start("pending");
  try {
    const first = h.session.send("slow sepfirst", msg("slow sepfirst"), h.emit);
    const a = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial")).messageId!;
    const second = h.session.send("sepsecond", msg("sepsecond"), h.emit);
    const b = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "b")).messageId!;
    await first;
    await second;
    const dones = h.events.filter((e) => e.type === "done");
    assert.deepEqual(dones.map((e) => e.messageId), [a, b]);
    assert.equal(dones[0].metadata?.pending, "1", "差し込んだ発話がまだ残っている間の done");
    assert.equal(dones[1].metadata?.pending, undefined, "何も残っていない最後の done");
  } finally {
    await h.session.close();
  }
});

test("停止は制御要求（interrupt）でターンだけを中断として閉じ、プロセスは残す（次の送信もそのまま答える）", async () => {
  const h = await start("interrupt");
  try {
    const sending = h.session.send("stop me", msg("stop me"), h.emit);
    const c = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial")).messageId!;
    await h.session.interrupt!();
    await sending;
    await h.session.send("hello again", msg("hello again"), h.emit);
    const d = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "plain")).messageId!;

    assert.deepEqual(h.events.filter((e) => e.type === "done").map((e) => e.messageId), [c, d], "中断の残りで done を重ねない");
    assert.ok(!h.events.some((e) => e.type === "error"), "中断はエラーにしない");
    assert.equal(h.starts(), 1, "プロセスを止めない（次の送信が冷えた起動にならない）");
    assert.ok(h.stdin().includes('"subtype":"interrupt"'));
    assert.ok(h.stdin().includes('"cancel_queued":true'));
    assert.deepEqual(h.stored.find((m) => m.messageId === c)?.content, "partial");
  } finally {
    await h.session.close();
  }
});

test("dynamic workflow のカード: task_started で覚えた task_id で振り分け、状態をそろえ、止まった workflow は failed + outcome stopped", async () => {
  const h = await start("workflow");
  try {
    await h.session.send("workflow please", msg("workflow please"), h.emit);
    await waitFor(h.events, (e) => payload(e)?.taskId === "w1" && payload(e)?.subtype === "task_notification");
    const all = payloads(h.events);
    const w1 = all.filter((p) => p.taskId === "w1");
    assert.deepEqual(w1.map((p) => p.subtype), ["task_started", "task_progress", "task_updated", "task_notification"]);
    assert.deepEqual(w1.map((p) => p.status), ["running", "running", "failed", "failed"]);
    assert.deepEqual(w1.map((p) => p.outcome), [undefined, undefined, "stopped", "stopped"]);
    assert.equal(w1.at(-1)?.workflowName, "review", "名前は task_started の後も載せる");
    const progress = rows(w1[1]);
    assert.deepEqual(progress.map((r) => r.label), ["planner", "checker"], "phase の見出しは行にしない");
    assert.deepEqual(progress.map((r) => r.state), ["running", "failed"]);
    assert.equal(progress[1].resultPreview, "boom", "失敗の理由");
    assert.equal(progress[0].startedAtMs, 1760000000000);
    assert.ok(!all.some((p) => p.taskId === "a1"), "summary に workflow という語があるだけの知らせを workflow のカードにしない");
    assert.ok(!all.some((p) => p.taskId === "subagents" && rows(p).some((r) => r.id === "w1")), "workflow はサブエージェントの行にしない");
  } finally {
    await h.session.close();
  }
});

test("バックグラウンドの作業がある間は設定が変わっても起こし直さない。close はそれらを stopped で閉じる payload を流す", async () => {
  const h = await start("background");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const snapshot = JSON.parse((await (h.session as unknown as { subagentSnapshot(): string | undefined }).subagentSnapshot()) ?? "{}") as Record<string, unknown>;
    assert.equal(snapshot.subtype, "workflow_snapshot");
    assert.deepEqual(rows(snapshot).map((r) => [r.id, r.state]), [["ag1", "running"]]);

    h.session.applyOverrides!({ model: "claude-other-model" });
    await h.session.send("hello again", msg("hello again"), h.emit);
    assert.equal(h.starts(), 1, "動いているバックグラウンドの作業があるので起こし直さない");
  } finally {
    await h.session.close();
  }
  assert.equal(subagentRows(h.events).get("ag1")?.state, "stopped");
  const w2 = payloads(h.events).filter((p) => p.taskId === "w2").at(-1);
  assert.equal(w2?.status, "failed");
  assert.equal(w2?.outcome, "stopped");
  assert.equal(rows(w2)[0]?.state, "stopped");
});

test("停止の返事が来なくても背景の作業があればプロセスを止めない。ターンは中断（エラーではない）で閉じ、行と workflow は動いたまま。同じプロセスで 2 回続けたら止める", async () => {
  const grace = claudeSessionTiming.interruptGraceMs;
  claudeSessionTiming.interruptGraceMs = 300;
  process.env.FAKE_CLAUDE_DEAF = "1";
  const h = await start("deaf");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const sending = h.session.send("stop me", msg("stop me"), h.emit);
    const c = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial")).messageId!;
    await h.session.interrupt!();
    await sending;
    const done = await waitFor(h.events, (e) => e.type === "done" && e.messageId === c);
    assert.equal(done.metadata?.origin, undefined);
    assert.ok(!h.events.some((e) => e.type === "error"), "止めたのでエラーにしない");
    assert.equal(h.starts(), 1, "背景の作業があるのでプロセスを止めない");
    assert.equal(subagentRows(h.events).get("ag1")?.state, "running", "背景のサブエージェントは動いたまま");
    assert.ok(!payloads(h.events).some((p) => p.taskId === "w2" && p.outcome === "stopped"), "workflow も閉じない");
    assert.deepEqual(h.stored.find((m) => m.messageId === c)?.content, "partial");

    // 続けてもう 1 回、また返事が来なければ、背景の作業があっても止める（CLI が固まっている）。
    const again = h.session.send("stop me again", msg("stop me again"), h.emit);
    await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial" && e.messageId !== c);
    await h.session.interrupt!();
    await again;
    assert.equal(subagentRows(h.events).get("ag1")?.state, "stopped", "プロセスと一緒に止まる。失敗にはしない");
    assert.equal(payloads(h.events).filter((p) => p.taskId === "w2").at(-1)?.outcome, "stopped");
    delete process.env.FAKE_CLAUDE_DEAF;
    await h.session.send("hello again", msg("hello again"), h.emit);
    await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "plain");
    assert.equal(h.starts(), 2, "止めたプロセスの代わりに起こし直す");
  } finally {
    delete process.env.FAKE_CLAUDE_DEAF;
    claudeSessionTiming.interruptGraceMs = grace;
    await h.session.close();
  }
});

test("取りこぼした interrupt の数は、間に普通のターンが閉じれば戻る（続いていない 2 回目で背景の作業ごと止めない）", async () => {
  const grace = claudeSessionTiming.interruptGraceMs;
  claudeSessionTiming.interruptGraceMs = 300;
  process.env.FAKE_CLAUDE_DEAF = "1";
  const h = await start("deaf-normal-between");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const first = h.session.send("stop me", msg("stop me"), h.emit);
    await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial");
    await h.session.interrupt!();
    await first;
    assert.equal(h.starts(), 1, "1 回目は背景の作業があるので残す");
    // 普通のターンが閉じる（CLI は応答している）。
    await h.session.send("hello", msg("hello"), h.emit);
    await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "plain");
    const again = h.session.send("stop me again", msg("stop me again"), h.emit);
    await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial" && e.messageId !== undefined && h.events.filter((x) => x.type === "assistant_delta" && x.content === "partial").length >= 2);
    await h.session.interrupt!();
    await again;
    assert.equal(h.starts(), 1, "続いていない 2 回目の取りこぼしではプロセスを止めない");
    assert.equal(subagentRows(h.events).get("ag1")?.state, "running", "背景のサブエージェントは動いたまま");
  } finally {
    delete process.env.FAKE_CLAUDE_DEAF;
    claudeSessionTiming.interruptGraceMs = grace;
    await h.session.close();
  }
});

test("kept にした interrupt の返事が遅れて届いたら、取りこぼしの数を戻す", async () => {
  const grace = claudeSessionTiming.interruptGraceMs;
  claudeSessionTiming.interruptGraceMs = 300;
  process.env.FAKE_CLAUDE_LATEACK = "1";
  const h = await start("late-ack");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const first = h.session.send("stop me", msg("stop me"), h.emit);
    await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial");
    await h.session.interrupt!();
    await first;
    assert.equal(h.starts(), 1);
    await sleep(600); // 遅れた返事が届く
    const again = h.session.send("stop me again", msg("stop me again"), h.emit);
    await waitFor(h.events, () => h.events.filter((x) => x.type === "assistant_delta" && x.content === "partial").length >= 2);
    await h.session.interrupt!();
    await again;
    assert.equal(h.starts(), 1, "遅れた返事で数が戻っているのでプロセスを止めない");
    assert.equal(subagentRows(h.events).get("ag1")?.state, "running");
  } finally {
    delete process.env.FAKE_CLAUDE_LATEACK;
    claudeSessionTiming.interruptGraceMs = grace;
    await h.session.close();
  }
});

test("停止の返事が来ず背景の作業も無ければ、今までどおりプロセスを止める（行は無い）", async () => {
  const grace = claudeSessionTiming.interruptGraceMs;
  claudeSessionTiming.interruptGraceMs = 300;
  process.env.FAKE_CLAUDE_DEAF = "1";
  const h = await start("deaf-plain");
  try {
    const sending = h.session.send("stop me", msg("stop me"), h.emit);
    const c = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial")).messageId!;
    await h.session.interrupt!();
    await sending;
    await waitFor(h.events, (e) => e.type === "done" && e.messageId === c);
    assert.ok(!h.events.some((e) => e.type === "error"));
    delete process.env.FAKE_CLAUDE_DEAF;
    await h.session.send("hello again", msg("hello again"), h.emit);
    await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "plain");
    assert.equal(h.starts(), 2);
  } finally {
    delete process.env.FAKE_CLAUDE_DEAF;
    claudeSessionTiming.interruptGraceMs = grace;
    await h.session.close();
  }
});

test("本文の無い知らせのターンは silent の done で閉じる（開いたときの activity で生成中になるので、閉じないと固着する。音・未読・push は出さない）", async () => {
  const h = await start("quiet");
  try {
    await h.session.send("quiet please", msg("quiet please"), h.emit);
    await sleep(300);
    const dones = h.events.filter((e) => e.type === "done");
    assert.equal(dones.length, 2, "発話のターンの done と、知らせのターンの silent の done");
    assert.equal(dones[0].metadata?.origin, undefined);
    assert.equal(dones[0].metadata?.silent, undefined);
    assert.equal(dones[1].metadata?.origin, "task-notification");
    assert.equal(dones[1].metadata?.silent, "1");
    assert.equal(dones[1].metadata?.pending, undefined, "残りの発話が無ければ pending を付けない");
    const activity = h.events.find((e) => e.type === "activity" && e.messageId === dones[1].messageId);
    assert.ok(activity, "開いたときに activity を出している");
    assert.ok(h.events.indexOf(activity!) < h.events.indexOf(dones[1]));
    assert.equal((h.session as unknown as { turns: unknown[] }).turns.length, 0, "知らせのターンも閉じている");
  } finally {
    await h.session.close();
  }
});

test("止めるターンが無い（バックグラウンドの作業だけが動いている）ときの停止は、制御要求を書かずに直近の done を返す", async () => {
  const h = await start("idle-interrupt");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const last = h.events.filter((e) => e.type === "done").at(-1)?.messageId;
    await h.session.interrupt!();
    assert.ok(!h.stdin().includes('"subtype":"interrupt"'));
    assert.equal(h.events.filter((e) => e.type === "done").at(-1)?.messageId, last, "直近の done を返す（生成中を解く）");
    const snapshot = (await (h.session as unknown as { subagentSnapshot(): string | undefined }).subagentSnapshot()) ?? "";
    assert.ok(snapshot.includes('"state":"running"'), "バックグラウンドのサブエージェントは動いたまま");
    assert.equal(h.starts(), 1);
  } finally {
    await h.session.close();
  }
});

test("ターンの外で届いた task_* と知らせのターンも流す（バックグラウンドのサブエージェントの完了の報告が消えない）", async () => {
  const h = await start("later");
  try {
    await h.session.send("later please", msg("later please"), h.emit);
    const turnDone = h.events.filter((e) => e.type === "done").at(-1)!;
    assert.equal(subagentRows(h.events).get("ag1")?.state, "running", "ターンの done の時点ではまだ動いている");
    const n = (await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "finished")).messageId!;
    const done = await waitFor(h.events, (e) => e.type === "done" && e.messageId === n);
    assert.notEqual(n, turnDone.messageId);
    assert.equal(done.metadata?.origin, "task-notification");
    const row = subagentRows(h.events).get("ag1");
    assert.equal(row?.state, "done");
    assert.equal(row?.result, "found it");
    assert.equal(row?.tokens, 1200);
    // 知らせのターンの本文も履歴に残る。
    assert.equal(h.stored.find((m) => m.messageId === n)?.content, "finished");
    // 完了した行は知らせのターンでは捨てない（次の送信で捨てる）。
    const snapshot = JSON.parse((await (h.session as unknown as { subagentSnapshot(): string | undefined }).subagentSnapshot()) ?? "{}") as Record<string, unknown>;
    assert.deepEqual(rows(snapshot).map((r) => r.state), ["done"]);
    await h.session.send("hello again", msg("hello again"), h.emit);
    const pruned = JSON.parse((await (h.session as unknown as { subagentSnapshot(): string | undefined }).subagentSnapshot()) ?? "{}") as Record<string, unknown>;
    assert.deepEqual(rows(pruned), [], "行が無くても agents: [] で返す");
  } finally {
    await h.session.close();
  }
});

test("サブエージェントの TodoWrite は親のチェックリストを置き換えない", async () => {
  const h = await start("plan");
  try {
    await h.session.send("plan please", msg("plan please"), h.emit);
    const plans = h.events.filter((e) => e.type === "plan_update").map((e) => JSON.parse(e.content ?? "{}") as { entries: Array<{ content: string }> });
    assert.deepEqual(plans.map((p) => p.entries.map((x) => x.content)), [["親 1", "親 2"]]);
  } finally {
    await h.session.close();
  }
});

test("workflow の行の振り分け（プロセス無しで行を直接渡す）。終わった後の遅れた進み具合では実行中に戻さず、task_started のやり直しでは戻す", async () => {
  const adapter = new ClaudeCodeAdapter("claude", { kind: "native", executable: "claude-missing", label: "native", shell: false }, {} as never);
  const session = (await adapter.openSession(undefined, tmp)) as unknown as { workflowEventPayload(o: Record<string, unknown>): string | undefined };
  const p = (json: string): Record<string, unknown> | undefined => {
    const out = session.workflowEventPayload(JSON.parse(json) as Record<string, unknown>);
    return out !== undefined ? (JSON.parse(out) as Record<string, unknown>) : undefined;
  };
  assert.equal(p('{"type":"system","subtype":"task_notification","task_id":"a1","status":"completed","summary":"workflow ok"}'), undefined);
  assert.equal(p('{"type":"system","subtype":"task_started","task_id":"w","task_type":"local_workflow","workflow_name":"r"}')?.status, "running");
  const done = p('{"type":"system","subtype":"task_notification","task_id":"w","status":"completed","summary":"ok"}');
  assert.equal(done?.status, "completed");
  assert.equal(done?.workflowName, "r");
  assert.equal(p('{"type":"system","subtype":"task_progress","task_id":"w","workflow_progress":[]}'), undefined, "終わった後の進み具合で実行中に戻さない");
  assert.equal(p('{"type":"system","subtype":"task_updated","task_id":"w","patch":{"status":"failed"}}')?.status, "failed");
  assert.equal(p('{"type":"system","subtype":"task_updated","task_id":"w","patch":{"is_backgrounded":true}}'), undefined);
  assert.equal(p('{"type":"system","subtype":"task_started","task_id":"w","task_type":"local_workflow"}')?.status, "running");
});

test("知らせのターンは開いた時点で空の activity を出す（最初の本文までの間も server が生成中と見て、dispose で止めない）", async () => {
  const h = await start("gap");
  try {
    await h.session.send("gap please", msg("gap please"), h.emit);
    await waitFor(h.events, (e) => e.type === "workflow_progress" && subagentRows([e]).get("ag1")?.state === "done");
    const n = await waitFor(h.events, (e) => e.type === "activity" && e.content === "");
    assert.ok(!h.events.some((e) => e.type === "assistant_delta" && e.content === "late report"), "本文より先に出ている");
    assert.equal((h.session as unknown as { hasPendingTurn: boolean }).hasPendingTurn, true, "本文が来る前も、終わっていないターンがある");
    const delta = await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "late report");
    assert.equal(delta.messageId, n.messageId, "同じ messageId の本文が続く");
    const done = await waitFor(h.events, (e) => e.type === "done" && e.messageId === n.messageId);
    assert.equal(done.metadata?.origin, "task-notification");
    assert.equal(done.metadata?.silent, undefined, "本文があれば silent にしない");
  } finally {
    await h.session.close();
  }
});

test("本文がまだ無い知らせのターンの間の送信は差し込みなので、終わった行を捨てない（開いた時点の空の activity で server / アプリも生成中と見ている。mac と同じ）", async () => {
  const h = await start("gap-prune");
  try {
    await h.session.send("gap please", msg("gap please"), h.emit);
    await waitFor(h.events, (e) => e.type === "workflow_progress" && subagentRows([e]).get("ag1")?.state === "done");
    await waitFor(h.events, (e) => e.type === "activity" && e.content === "");
    await h.session.send("plain next", msg("plain next"), h.emit);
    const snapshot = (await (h.session as unknown as { subagentSnapshot(): string | undefined }).subagentSnapshot()) ?? "";
    assert.ok(snapshot.includes('"id":"ag1"'), `生成中の差し込みで終わった行 ag1 を捨てた: ${snapshot}`);
  } finally {
    await h.session.close();
  }
});

test("差し込んだ発話が待ち行列に残る間（前のターンの done の後）は hasPendingTurn が true で、その発話の done で false に戻る", async () => {
  const h = await start("behind");
  try {
    const first = h.session.send("slow first", msg("slow first"), h.emit);
    await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "partial");
    assert.equal(h.session.inject!("behind second", msg("behind second"), h.emit), true);
    const a = await waitFor(h.events, (e) => e.type === "done");
    await first;
    assert.equal((h.session as unknown as { hasPendingTurn: boolean }).hasPendingTurn, true, "前のターンの done の後も、差し込んだ発話が残っている");
    const b = await waitFor(h.events, (e) => e.type === "assistant_delta" && e.content === "second");
    await waitFor(h.events, (e) => e.type === "done" && e.messageId === b.messageId);
    assert.notEqual(a.messageId, b.messageId);
    assert.equal((h.session as unknown as { hasPendingTurn: boolean }).hasPendingTurn, false);
  } finally {
    await h.session.close();
  }
});

/* ── 行ごとの停止（stop_task）と initialize ───────────────────────────────── */

type Stopper = AgentSession & {
  stopTask(req: { taskId: string; rowId?: string; epoch?: string }): Promise<{ kind: string; message?: string }>;
  workflowEventPayload(obj: Record<string, unknown>): string | undefined;
};

const stdinLines = (h: Harness): Array<Record<string, unknown>> =>
  h.stdin().split("\n").filter(Boolean).map((l) => JSON.parse(l) as Record<string, unknown>);
const epochOf = (events: SessionEvent[]): string => String(payloads(events).find((p) => p.taskId === "subagents")?.epoch);

test("プロセスを起こしたら最初の user 行より前に initialize（perTaskStopAffordance）を書き、success で行が stoppable になる", async () => {
  const h = await start("init");
  const captured: string[] = [];
  const realErr = process.stderr.write.bind(process.stderr);
  const realLog = console.log;
  const realConsoleErr = console.error;
  process.stderr.write = ((chunk: unknown, ...rest: unknown[]) => (captured.push(String(chunk)), (realErr as (...a: unknown[]) => boolean)(chunk, ...rest))) as typeof process.stderr.write;
  console.log = (...a: unknown[]) => (captured.push(a.join(" ")), realLog(...a));
  console.error = (...a: unknown[]) => (captured.push(a.join(" ")), realConsoleErr(...a));
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const lines = stdinLines(h);
    assert.equal(lines[0].type, "control_request");
    const request = lines[0].request as Record<string, unknown>;
    assert.deepEqual(request, { subtype: "initialize", perTaskStopAffordance: true });
    assert.match(String(lines[0].request_id), /^[0-9a-f-]{36}$/);
    assert.equal(lines[1].type, "user");
    assert.equal(subagentRows(h.events).get("ag1")?.stoppable, true);
    const w2 = payloads(h.events).filter((p) => p.taskId === "w2");
    assert.equal(w2.at(-1)?.stoppable, true, "workflow のカードも最上位に stoppable");
    assert.ok(!JSON.stringify(h.events).includes("commands"), "initialize の返事の中身は出さない");
    // アカウントのメールと pid（initialize の返事にある）は、イベントにもログにも出さない。
    const everything = JSON.stringify(h.events) + captured.join("\n");
    assert.ok(!everything.includes("sentinel@example.invalid") && !everything.includes("424242"), "返事の個人情報を出さない");
  } finally {
    process.stderr.write = realErr as typeof process.stderr.write;
    console.log = realLog;
    console.error = realConsoleErr;
    await h.session.close();
  }
});

test("initialize が error の古い CLI では行は stoppable にならず、行の停止は unsupported", async () => {
  process.env.FAKE_CLAUDE_OLD = "1";
  const h = await start("old");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    assert.equal(subagentRows(h.events).get("ag1")?.stoppable, false);
    const s = h.session as Stopper;
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "ag1", epoch: epochOf(h.events) }), { kind: "unsupported" });
    assert.deepEqual(await s.stopTask({ taskId: "w2" }), { kind: "unsupported" });
    assert.ok(!h.stdin().includes('"stop_task"'));
  } finally {
    delete process.env.FAKE_CLAUDE_OLD;
    await h.session.close();
  }
});

test("行の停止: stop_task を行の id で書き、返事を待って stopped。stopped の payload は結果より先に出ている。epoch・行・終わった行は書かずに返す", async () => {
  const h = await start("stop-row");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const s = h.session as Stopper;
    const epoch = epochOf(h.events);
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "ag1", epoch: "other" }), { kind: "stale" });
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "nope", epoch }), { kind: "stale" });
    assert.deepEqual(await s.stopTask({ taskId: "subagents", epoch }), { kind: "stale" });
    assert.ok(!h.stdin().includes('"stop_task"'), "確かめる段で返すものは書かない");

    // 同時に 2 回押しても stop_task は 1 つで、同じ結果を返す。
    const [a, b] = await Promise.all([
      s.stopTask({ taskId: "subagents", rowId: "ag1", epoch }),
      s.stopTask({ taskId: "subagents", rowId: "ag1", epoch })
    ]);
    assert.deepEqual([a, b], [{ kind: "stopped" }, { kind: "stopped" }]);
    const stops = stdinLines(h).filter((l) => (l.request as Record<string, unknown> | undefined)?.subtype === "stop_task");
    assert.equal(stops.length, 1);
    assert.deepEqual((stops[0].request as Record<string, unknown>).task_id, "ag1");
    const states = payloads(h.events).filter((p) => p.taskId === "subagents").flatMap((p) => rows(p).filter((r) => r.id === "ag1").map((r) => [r.state, r.stoppable]));
    assert.deepEqual(states.at(-3), ["running", false], "返事待ちの間は stoppable false");
    assert.deepEqual(states.at(-1), ["stopped", false]);
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "ag1", epoch }), { kind: "notRunning" });
  } finally {
    await h.session.close();
  }
});

test("行の停止: CLI が動かしていなかった task は success でも running のままなので、こちらで stopped に閉じる", async () => {
  process.env.FAKE_CLAUDE_STOP = "idle";
  const h = await start("stop-idle");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const s = h.session as Stopper;
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "ag1", epoch: epochOf(h.events) }), { kind: "stopped" });
    assert.equal(subagentRows(h.events).get("ag1")?.state, "stopped");
  } finally {
    delete process.env.FAKE_CLAUDE_STOP;
    await h.session.close();
  }
});

test("行の停止: 返事が来なければ timeout（行は stoppable に戻る）、CLI の error は failed + message、stop_task を知らない CLI は unsupported で全行 stoppable false", async () => {
  const reply = claudeSessionTiming.stopReplyMs;
  claudeSessionTiming.stopReplyMs = 200;
  try {
    for (const [mode, expected] of [
      ["silent", { kind: "timeout" }],
      ["error", { kind: "failed", message: "stop_task: no such task" }],
      ["old", { kind: "unsupported" }]
    ] as const) {
      process.env.FAKE_CLAUDE_STOP = mode;
      const h = await start(`stop-${mode}`);
      try {
        await h.session.send("background job", msg("background job"), h.emit);
        const s = h.session as Stopper;
        assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "ag1", epoch: epochOf(h.events) }), expected, mode);
        const row = subagentRows(h.events).get("ag1");
        assert.equal(row?.state, "running", `${mode}: 行は閉じない`);
        assert.equal(row?.stoppable, mode !== "old", `${mode}: stoppable`);
        assert.equal(h.starts(), 1, "プロセスは止めない");
      } finally {
        delete process.env.FAKE_CLAUDE_STOP;
        await h.session.close();
      }
    }
  } finally {
    claudeSessionTiming.stopReplyMs = reply;
  }
});

test("dynamic workflow のカード全体の停止: stop_task を workflow の task_id で書き、カードが終われば stopped。終わらなければ failed でこの世代の workflow の停止を下ろす", async () => {
  const h = await start("stop-wf");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const s = h.session as Stopper;
    assert.deepEqual(await s.stopTask({ taskId: "w2" }), { kind: "stopped" });
    const w2 = payloads(h.events).filter((p) => p.taskId === "w2");
    assert.equal(w2.at(-1)?.outcome, "stopped");
    assert.equal(w2.at(-1)?.stoppable, false);
    assert.ok(w2.some((p) => p.status === "running" && p.stoppable === false), "返事待ちの間は stoppable false");
    assert.deepEqual(await s.stopTask({ taskId: "w2" }), { kind: "notRunning" });
    assert.deepEqual(await s.stopTask({ taskId: "unknown" }), { kind: "notRunning" });
  } finally {
    await h.session.close();
  }

  const end = claudeSessionTiming.workflowEndMs;
  claudeSessionTiming.workflowEndMs = 200;
  process.env.FAKE_CLAUDE_STOP = "stuck";
  const g = await start("stop-wf-stuck");
  try {
    await g.session.send("background job", msg("background job"), g.emit);
    const s = g.session as Stopper;
    assert.deepEqual(await s.stopTask({ taskId: "w2" }), { kind: "failed" });
    const last = payloads(g.events).filter((p) => p.taskId === "w2").at(-1);
    assert.equal(last?.status, "running", "閉じない");
    assert.equal(last?.stoppable, false);
    assert.deepEqual(await s.stopTask({ taskId: "w2" }), { kind: "unsupported" }, "この世代では workflow の停止を使わない");
  } finally {
    delete process.env.FAKE_CLAUDE_STOP;
    claudeSessionTiming.workflowEndMs = end;
    await g.session.close();
  }
});

test("待っている間にプロセスが終わったら not_running", async () => {
  const reply = claudeSessionTiming.stopReplyMs;
  claudeSessionTiming.stopReplyMs = 5000;
  process.env.FAKE_CLAUDE_STOP = "silent";
  const h = await start("stop-exit");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const s = h.session as Stopper;
    const pending = s.stopTask({ taskId: "subagents", rowId: "ag1", epoch: epochOf(h.events) });
    await sleep(100);
    await h.session.close();
    assert.deepEqual(await pending, { kind: "notRunning" });
  } finally {
    delete process.env.FAKE_CLAUDE_STOP;
    claudeSessionTiming.stopReplyMs = reply;
  }
});

/* ── 実測の記録（shared/fixtures/background-control）を偽の claude に流す ───────────────────────── */

const fixtureDir = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "../../../shared/fixtures/background-control");
const readJsonl = (file: string): Array<Record<string, unknown>> =>
  fs.readFileSync(path.join(fixtureDir, file), "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as Record<string, unknown>);

// 記録した stdout を、最初の user 行に 1 区切り目まで、各 stop_task に次の区切りまで流す。区切りは記録の `in` の
// stop_task（と mark）。command_uuid は今の user 行の uuid に置き換え、停止の返事の request_id は今の要求のものにする。
const replay = path.join(tmp, "fake-replay.mjs");
fs.writeFileSync(
  replay,
  `import fs from "node:fs"; import readline from "node:readline";
const entries = fs.readFileSync(process.env.FAKE_FIXTURE, "utf8").split("\\n").filter(Boolean).map((l) => JSON.parse(l));
const say = (raw) => process.stdout.write(raw + "\\n");
const sub = (e) => { try { return JSON.parse(e.raw).request?.subtype; } catch { return undefined; } };
const taskOf = (e) => { try { return JSON.parse(e.raw).request?.task_id; } catch { return undefined; } };
const segments = [{ trigger: undefined, task: undefined, id: undefined, outs: [] }];
for (const e of entries) {
  if (e.dir === "in" && sub(e) === "stop_task") {
    const last = segments.at(-1);
    if (last.trigger && last.outs.length === 0) last.group.push(e);
    else segments.push({ trigger: e, group: [e], task: taskOf(e), id: JSON.parse(e.raw).request_id, outs: [] });
    continue;
  }
  if (e.dir === "mark") { if (segments.at(-1).outs.length > 0 || segments.at(-1).trigger) segments.push({ trigger: undefined, group: [], outs: [], skip: true }); continue; }
  if (e.dir !== "out") continue;
  let o; try { o = JSON.parse(e.raw); } catch { continue; }
  if (o.type === "control_request") continue;
  segments.at(-1).outs.push(e.raw);
}
const firstCommand = entries.map((e) => { try { return JSON.parse(e.raw); } catch { return {}; } }).find((o) => o.type === "command_lifecycle")?.command_uuid;
let uuid;
let started = false;
const used = new Set();
readline.createInterface({ input: process.stdin }).on("line", (raw) => {
  fs.appendFileSync(process.env.FAKE_CLAUDE_STDIN, raw + "\\n");
  const line = JSON.parse(raw);
  const fix = (s) => (uuid && firstCommand ? s.split(firstCommand).join(uuid) : s);
  if (line.type === "control_request") {
    const request = line.request;
    if (request.subtype === "initialize") {
      say(JSON.stringify({ type: "control_response", response: { subtype: "success", request_id: line.request_id, response: {} } }));
    } else if (request.subtype === "stop_task") {
      const index = segments.findIndex((s, i) => !used.has(i) && s.trigger && s.task === request.task_id);
      if (index < 0) return;
      used.add(index);
      for (const out of segments[index].outs) {
        const o = JSON.parse(out);
        if (o.type === "control_response" && o.response.request_id === segments[index].id) o.response.request_id = line.request_id;
        say(fix(JSON.stringify(o)));
      }
    }
    return;
  }
  if (line.type === "user" && !started) {
    started = true; uuid = line.uuid;
    for (const out of segments[0].outs) say(fix(out));
  }
});
`
);
const replayBin = process.platform === "win32" ? path.join(tmp, "claude-replay.cmd") : path.join(tmp, "claude-replay");
fs.writeFileSync(
  replayBin,
  process.platform === "win32" ? `@"${process.execPath}" "${replay}" %*\r\n` : `#!/bin/sh\nexec "${process.execPath}" "${replay}" "$@"\n`,
  { mode: 0o755 }
);

async function startReplay(name: string, fixture: string): Promise<Harness> {
  process.env.FAKE_FIXTURE = path.join(fixtureDir, "claude-stop", `${fixture}.jsonl`);
  const dir = fs.mkdtempSync(path.join(tmp, `${name}-`));
  process.env.FAKE_CLAUDE_STARTS = path.join(dir, "starts");
  process.env.FAKE_CLAUDE_STDIN = path.join(dir, "stdin");
  const stored: Harness["stored"] = [];
  const store = {
    ensureSession() {},
    appendMessage() {
      return "";
    },
    replaceSessionId() {},
    list: () => [],
    history: () => [],
    rename: () => false
  };
  const adapter = new ClaudeCodeAdapter("claude", { kind: "native", executable: replayBin, label: `native:${replayBin}`, shell: false }, store as never);
  const session = await adapter.openSession(undefined, dir, { permissionMode: "dangerous", unattended: true });
  const events: SessionEvent[] = [];
  const read = (file: string): string => (fs.existsSync(file) ? fs.readFileSync(file, "utf8") : "");
  return { session, events, emit: (e) => events.push(e), stored, starts: () => 1, stdin: () => read(path.join(dir, "stdin")) };
}

const stateOf = (h: Harness, id: string): unknown => subagentRows(h.events).get(id)?.state;

test("実測 s1: アイドル中の背景の Bash を stop_task で止める（task_updated killed → task_notification stopped → 返事）", async () => {
  const h = await startReplay("replay-s1", "s1-stop-bg-bash");
  try {
    await h.session.send("go", msg("go"), h.emit);
    assert.equal(stateOf(h, "br1svjoeb"), "running");
    assert.equal(subagentRows(h.events).get("br1svjoeb")?.stoppable, true, "task_type local_bash");
    const s = h.session as Stopper;
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "br1svjoeb", epoch: epochOf(h.events) }), { kind: "stopped" });
    assert.equal(stateOf(h, "br1svjoeb"), "stopped");
    assert.equal(subagentRows(h.events).get("br1svjoeb")?.stoppable, false);
    assert.ok(stdinLines(h).some((l) => JSON.stringify(l.request) === '{"subtype":"stop_task","task_id":"br1svjoeb"}'));
  } finally {
    await h.session.close();
  }
});

test("実測 s2: 背景のサブエージェントを止めると、行は stopped になる。前景の子のシェル（owned_by_subagent）は行にならず、そのまま閉じる", async () => {
  const h = await startReplay("replay-s2", "s2-stop-bg-agent");
  try {
    await h.session.send("go", msg("go"), h.emit);
    assert.equal(stateOf(h, "af42a6def78386e01"), "running");
    assert.equal(subagentRows(h.events).get("af42a6def78386e01")?.stoppable, true, "task_type local_agent");
    const s = h.session as Stopper;
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "af42a6def78386e01", epoch: epochOf(h.events) }), { kind: "stopped" });
    assert.equal(stateOf(h, "af42a6def78386e01"), "stopped");
    assert.equal(subagentRows(h.events).get("bw3b4in6b"), undefined, "前景の子のシェルは行にしない");
    assert.ok(!h.events.some((e) => e.type === "error"));
  } finally {
    await h.session.close();
  }
});

test("実測 s6: 行の id で止まり、止めた行をもう一度止めても書かない（not_running）。別の行は続けて止められる", async () => {
  const h = await startReplay("replay-s6", "s6-stop-id-variants");
  try {
    await h.session.send("go", msg("go"), h.emit);
    const s = h.session as Stopper;
    const epoch = epochOf(h.events);
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "bpzp9542e", epoch }), { kind: "stopped" });
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "bpzp9542e", epoch }), { kind: "notRunning" });
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "a5a7fe42c3e7ff80f", epoch }), { kind: "stopped" });
    const ids = stdinLines(h).filter((l) => (l.request as Record<string, unknown> | undefined)?.subtype === "stop_task").map((l) => (l.request as Record<string, unknown>).task_id);
    assert.deepEqual(ids, ["bpzp9542e", "a5a7fe42c3e7ff80f"], "行の id だけを送る");
    assert.equal(stateOf(h, "a5a7fe42c3e7ff80f"), "stopped");
  } finally {
    await h.session.close();
  }
});

test("実測 s15: 親のサブエージェントを止めると、背景の子のシェルの行も各 task_* で stopped になる", async () => {
  const h = await startReplay("replay-s15", "s15-stop-parent-with-bg-child");
  try {
    await h.session.send("go", msg("go"), h.emit);
    const s = h.session as Stopper;
    assert.equal(stateOf(h, "a9ff03b60381154d4"), "running");
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "a9ff03b60381154d4", epoch: epochOf(h.events) }), { kind: "stopped" });
    await waitFor(h.events, (e) => subagentRows([e]).get("bvq0ugsjl")?.state === "stopped");
    assert.equal(subagentRows(h.events).get("bucejfnlw"), undefined, "前景の子のシェルは行にしない");
    assert.equal(stateOf(h, "a9ff03b60381154d4"), "stopped");
  } finally {
    await h.session.close();
  }
});

test("実測 workflow-phases の W・X: phases は workflow_progress のある行にだけ付き、記録した写像の提案と同じ（最上位の stoppable は別）", async () => {
  for (const name of ["W", "X"]) {
    const lines = readJsonl(`workflow-phases/${name}.workflow-lines.jsonl`);
    const expected = readJsonl(`workflow-phases/${name}.payloads.jsonl`);
    const h = await start(`phases-${name}`);
    try {
      const s = h.session as Stopper;
      const got = lines.flatMap((line) => {
        const out = s.workflowEventPayload(line);
        return out === undefined ? [] : [JSON.parse(out) as Record<string, unknown>];
      });
      // 記録した提案は title を整える前のもの（X の "  Padded   Title "）。整え方は設計 6.1 の 4。
      const trim = (t: unknown): unknown => (typeof t === "string" ? t.replace(/[\r\n]+/g, " ").trim().replace(/\s+/g, " ") : t);
      const want = expected
        .filter((e) => e.proposed !== null && e.proposed !== undefined)
        .map((e) => {
          const p = e.proposed as Record<string, unknown>;
          return Array.isArray(p.phases) ? { ...p, phases: (p.phases as Array<Record<string, unknown>>).map((x) => ({ ...x, title: trim(x.title) })) } : p;
        });
      assert.ok(got.length > 0);
      assert.deepEqual(
        got.map((p) => Object.fromEntries(Object.entries(p).filter(([k]) => k !== "stoppable"))),
        want,
        name
      );
      assert.ok(got.every((p) => p.stoppable === false), "宣言の無いプロセスでは止められない");
      for (const p of got) assert.equal("phases" in p, "agents" in p, "phases は agents と同じ条件で付く");
    } finally {
      await h.session.close();
    }
  }
});

test("workflowPhases: 80 字は書記素で数える（国旗や ZWJ の途中で切らない）", () => {
  const flag = "\u{1F1EF}\u{1F1F5}";
  const phases = workflowPhases([{ type: "workflow_phase", index: 1, title: "a".repeat(79) + flag + flag }]);
  assert.deepEqual(phases, [{ index: 1, title: "a".repeat(79) + flag }]);
});

test("行の停止: 押した直後に行が終わっていて CLI が「is not running」と返したら、失敗ではなく not_running（行は終わったまま）", async () => {
  process.env.FAKE_CLAUDE_STOP = "gone";
  const h = await start("stop-gone");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const s = h.session as Stopper;
    assert.deepEqual(await s.stopTask({ taskId: "subagents", rowId: "ag1", epoch: epochOf(h.events) }), { kind: "notRunning" });
    assert.equal(subagentRows(h.events).get("ag1")?.state, "done");
    assert.equal(subagentRows(h.events).get("ag1")?.stoppable, false);
    // workflow のカードも同じ。終わったカードに running を送り直して生き返らせない。
    assert.deepEqual(await s.stopTask({ taskId: "w2" }), { kind: "notRunning" });
    const w2 = payloads(h.events).filter((p) => p.taskId === "w2");
    assert.ok(w2.length > 0 && w2.at(-1)?.stoppable === false);
    const closedAt = w2.findIndex((p) => p.subtype === "task_notification");
    assert.ok(closedAt >= 0 && w2.slice(closedAt + 1).every((p) => p.status !== "running"), "終わった後に running を送らない");
  } finally {
    delete process.env.FAKE_CLAUDE_STOP;
    await h.session.close();
  }
});

test("workflow の停止: success の返事の後、カードが終わるまでの進み具合も stoppable false のまま", async () => {
  process.env.FAKE_CLAUDE_STOP = "slowend";
  const h = await start("stop-wf-slowend");
  try {
    await h.session.send("background job", msg("background job"), h.emit);
    const s = h.session as Stopper;
    const before = payloads(h.events).length;
    assert.deepEqual(await s.stopTask({ taskId: "w2" }), { kind: "stopped" });
    const during = payloads(h.events).slice(before).filter((p) => p.taskId === "w2");
    assert.ok(during.some((p) => p.subtype === "task_progress" && p.status === "running"), "待つ間に進み具合が届く");
    assert.ok(during.every((p) => p.stoppable === false), "待つ間は stoppable true を送らない");
  } finally {
    delete process.env.FAKE_CLAUDE_STOP;
    await h.session.close();
  }
});

test("interrupt: 行の停止を宣言した世代では、背景のサブエージェントの承認待ちは閉じない（main の承認だけ閉じる）。後から答えられる", async () => {
  const h = await start("sub-approval");
  try {
    const sending = h.session.send("subapproval", msg("subapproval"), h.emit);
    await waitFor(h.events, (e) => e.type === "action_request" && e.messageId === "ap-main");
    await waitFor(h.events, (e) => e.type === "action_request" && e.messageId === "ap-sub");
    await h.session.interrupt!();
    await sending;
    const resolved = (id: string): boolean => h.events.some((e) => e.type === "action_resolved" && e.messageId === id);
    assert.ok(resolved("ap-main"), "main の承認は閉じる");
    assert.ok(!resolved("ap-sub"), "背景の子の承認は残す");
    // 残した承認には、後から答えが CLI に届く。
    await h.session.respondToAction!("ap-sub", "allow", {});
    await sleep(200);
    assert.ok(stdinLines(h).some((l) => (l.response as Record<string, unknown> | undefined)?.request_id === "ap-sub"));
    assert.ok(resolved("ap-sub"));
  } finally {
    await h.session.close();
  }
});

test("workflowPhases: type = workflow_phase だけを index 昇順に。title は整え、空と重複した index は捨てる", () => {
  const long = "あ".repeat(100);
  const phases = workflowPhases([
    { type: "workflow_agent", index: 9, label: "x" },
    { type: "workflow_phase", index: 3, title: "Third" },
    { type: "workflow_phase", index: 1, title: "  First\n line \r\n  here  " },
    { type: "workflow_phase", index: 1, title: "Dup" },
    { type: "workflow_phase", index: 2, title: "   " },
    { type: "workflow_phase", index: 4, title: long },
    { type: "workflow_phase", index: "5", title: "str index" },
    { type: "workflow_phase", index: 6 }
  ]);
  assert.deepEqual(phases, [
    { index: 1, title: "First line here" },
    { index: 3, title: "Third" },
    { index: 4, title: "あ".repeat(80) }
  ]);
  assert.deepEqual(workflowPhases([]), []);
});

test("workflow のカード: phases は workflow_progress のある行にだけ付き、agents が 0 個でも付く。閉じる payload には付けず stoppable false", async () => {
  const h = await start("phases-card");
  try {
    const s = h.session as Stopper;
    const p = (o: Record<string, unknown>): Record<string, unknown> | undefined => {
      const out = s.workflowEventPayload({ type: "system", ...o });
      return out === undefined ? undefined : (JSON.parse(out) as Record<string, unknown>);
    };
    const started = p({ subtype: "task_started", task_id: "w", task_type: "local_workflow", workflow_name: "r" });
    assert.ok(started && !("phases" in started));
    const progress = p({ subtype: "task_progress", task_id: "w", workflow_progress: [{ type: "workflow_phase", index: 1, title: "Scan" }] });
    assert.deepEqual(progress?.phases, [{ index: 1, title: "Scan" }]);
    assert.deepEqual(progress?.agents, []);
    const plain = p({ subtype: "task_progress", task_id: "w", description: "x" });
    assert.ok(plain && !("phases" in plain) && !("agents" in plain));
    const [closed] = (h.session as unknown as { abandonWorkflows(state: string): string[] }).abandonWorkflows("stopped").map((x) => JSON.parse(x) as Record<string, unknown>);
    assert.equal(closed.stoppable, false);
    assert.ok(!("phases" in closed));
  } finally {
    await h.session.close();
  }
});

test("bg のジョブの会話は warm で起こさない（bg でなければ起こす）", async () => {
  const bg = await start("warm-bg", { isJob: () => true, refresh() {} });
  const plain = await start("warm-plain", { isJob: () => false, refresh() {} });
  try {
    await bg.session.warm?.();
    await plain.session.warm?.();
    await sleep(500);
    assert.equal(bg.starts(), 0, "開いただけで握ると PC の claude respawn / attach が断られる");
    assert.equal(plain.starts(), 1);
  } finally {
    await bg.session.close();
    await plain.session.close();
  }
});

test("起こしたプロセスが running in the background (<id>) で終わったら、bg の文を出して読み直しを頼み、使えない印を付ける", async () => {
  let refreshed = 0;
  const h = await start("taken", { isJob: () => true, refresh: () => void refreshed++ });
  assert.equal(h.session.isStillUsable?.(), true);
  await h.session.send("taken", msg("taken"), h.emit);
  const error = h.events.find((e) => e.type === "error");
  assert.equal(error?.content, "この会話は PC のバックグラウンド（a1b2c3d4）でまた動き始めました。もう一度送ると、そちらに届けます。");
  assert.equal(h.events.some((e) => (e.content ?? "").includes("Error: session")), false, "stderr はそのまま出さない");
  assert.equal(refreshed, 1);
  assert.equal(h.session.isStillUsable?.(), false);
  await h.session.close();
});
