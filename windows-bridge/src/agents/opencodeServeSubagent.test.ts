import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test, { type TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import type { SessionEvent } from "../protocol.js";
import { OpenCodeServe, OpenCodeServeTerminalSession, OpenCodeServeTranslator, serveStopTiming, taskOutputSessionId } from "./opencodeServe.js";

/**
 * OpenCode（serve。ターミナルと共有する会話）のサブエージェント（task）の行と、自分が送っていないターン（ターミナルの TUI・
 * 裏で動いていた子の結果の差し込み）の扱い。opencode 1.18.32 の実測（docs/BACKGROUND_WORK_2026-10-21.md §1.3・§3.6）と
 * 同じ形のイベントを流す。子セッションのイベントは OpenCodeServe.dispatch を通し、親への回し方まで確かめる。
 */

type Row = Record<string, unknown>;

const uid = (): string => crypto.randomUUID().slice(0, 8);

/** `/global/event` の 1 フレームとして流す（sessionID でセッションへ振り分けられる）。 */
const dispatch = (type: string, properties: Record<string, unknown>): void =>
  OpenCodeServe.dispatch(JSON.stringify({ directory: "/tmp", payload: { type, properties } }));

/** ターミナルの会話を開いた（watch）セッション。流れたイベントを全部ためる。 */
async function open(): Promise<{ session: OpenCodeServeTerminalSession; sid: string; events: SessionEvent[] }> {
  const sid = `ses_p${uid()}`;
  const session = new OpenCodeServeTerminalSession("opencode", sid, undefined);
  const events: SessionEvent[] = [];
  await session.watch((e) => events.push(e));
  return { session, sid, events };
}

const user = (sid: string, id: string, createdMs = Date.now()): void =>
  dispatch("message.updated", { sessionID: sid, info: { id, role: "user", sessionID: sid, time: { created: createdMs } } });
const userText = (sid: string, messageId: string, text: string, synthetic = false): void =>
  dispatch("message.part.updated", {
    sessionID: sid,
    part: { id: `prt_${messageId}`, messageID: messageId, sessionID: sid, type: "text", text, ...(synthetic ? { synthetic: true } : {}) }
  });
const assistant = (sid: string, id: string, parent: string, extra: Record<string, unknown> = {}): void =>
  dispatch("message.updated", { sessionID: sid, info: { id, role: "assistant", parentID: parent, sessionID: sid, ...extra } });
const delta = (sid: string, messageId: string, text: string): void =>
  dispatch("message.part.delta", { sessionID: sid, messageID: messageId, partID: `prt_${messageId}`, field: "text", delta: text });
const idle = (sid: string): void => dispatch("session.idle", { sessionID: sid });
const taskPart = (sid: string, messageId: string, callID: string, state: Record<string, unknown>): void =>
  dispatch("message.part.updated", {
    sessionID: sid,
    part: { id: `prt_${callID}`, messageID: messageId, sessionID: sid, type: "tool", tool: "task", callID, state }
  });
const childTool = (child: string, messageId: string, callID: string, tool: string, state: Record<string, unknown>): void =>
  dispatch("message.part.updated", { sessionID: child, part: { id: `prt_${callID}`, messageID: messageId, sessionID: child, type: "tool", tool, callID, state } });

/** 流れた workflow_progress（subagents）の行を、届いた順に返す。 */
function rows(events: SessionEvent[], id?: string): Row[] {
  return events
    .filter((e) => e.type === "workflow_progress")
    .flatMap((e) => {
      const o = JSON.parse(e.content ?? "{}") as { taskId?: string; agents?: Row[] };
      return o.taskId === "subagents" ? (o.agents ?? []) : [];
    })
    .filter((r) => id === undefined || r.id === id);
}

const text = (events: SessionEvent[]): string =>
  events
    .filter((e) => e.type === "assistant_delta")
    .map((e) => e.content ?? "")
    .join("");
const doneIndexes = (events: SessionEvent[]): number[] => events.flatMap((e, i) => (e.type === "done" ? [i] : []));

// ---- 前景の task ----

test("前景の task: 子のツールの title が作業の文とツール回数に、tokens・model が行に入り、<task_result> の中身が結果になる", async () => {
  const { session, sid, events } = await open();
  const child = `ses_c${uid()}`;
  try {
    // ターミナルの TUI で打った発言で始まったターン。
    user(sid, "msg_u1");
    userText(sid, "msg_u1", "サブエージェントで ls して");
    assistant(sid, "msg_a1", "msg_u1");
    taskPart(sid, "msg_a1", "call_fg", { status: "pending", input: {} });
    dispatch("session.created", { sessionID: child, info: { id: child, parentID: sid, title: "List scratch dir (@general subagent)" } });
    const input = { description: "List scratch dir", prompt: "Run ls -la", subagent_type: "general" };
    taskPart(sid, "msg_a1", "call_fg", {
      status: "running",
      title: "List scratch dir",
      input,
      metadata: { parentSessionId: sid, sessionId: child, model: { modelID: "big-pickle", providerID: "opencode" } }
    });
    // 子セッションのイベント（sessionID = 子）。ルートを持つ親の行に回る。
    dispatch("message.updated", { sessionID: child, info: { id: "msg_cu", role: "user", sessionID: child } });
    dispatch("message.part.updated", { sessionID: child, part: { id: "prt_cu", messageID: "msg_cu", sessionID: child, type: "text", text: "Run ls -la" } });
    dispatch("session.status", { sessionID: child, status: { type: "busy" } });
    assistant(child, "msg_ca1", "msg_cu", { modelID: "big-pickle", tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } } });
    for (const state of [
      { status: "pending", input: {} },
      { status: "running", input: { command: "ls -la" } },
      { status: "running", input: { command: "ls -la" }, metadata: { output: "total 0\n" } },
      { status: "completed", input: { command: "ls -la" }, title: "ls -la", output: "total 0\n" }
    ]) {
      childTool(child, "msg_ca1", "call_b1", "bash", state);
    }
    assistant(child, "msg_ca1", "msg_cu", { modelID: "big-pickle", tokens: { total: 5387, input: 5137, output: 23, reasoning: 63, cache: { read: 164, write: 0 } } });
    assistant(child, "msg_ca2", "msg_cu", { modelID: "big-pickle", tokens: { total: 5599, input: 81, output: 8, reasoning: 207, cache: { read: 5303, write: 0 } } });
    dispatch("message.part.updated", { sessionID: child, part: { id: "prt_ct", messageID: "msg_ca2", sessionID: child, type: "text", text: "2" } });
    dispatch("session.status", { sessionID: child, status: { type: "idle" } });
    idle(child);
    taskPart(sid, "msg_a1", "call_fg", {
      status: "completed",
      title: "List scratch dir",
      input,
      output: `<task id="${child}" state="completed">\n<task_result>\n2\n</task_result>\n</task>`,
      metadata: { parentSessionId: sid, sessionId: child, truncated: false }
    });
    assistant(sid, "msg_a2", "msg_u1");
    delta(sid, "msg_a2", "DONE 2");
    idle(sid);

    const dones = doneIndexes(events);
    assert.equal(dones.length, 1, "子の idle は親のターンを閉じない");
    assert.equal(text(events), "DONE 2", "子の本文やツールは親の本文に混ぜない");
    assert.ok(!events.some((e) => e.type === "tool_start" && e.toolUseId === "call_b1"), "子のツールは親のツールの行にしない");
    assert.deepEqual(
      events.filter((e) => e.type === "user_message").map((e) => e.content),
      ["サブエージェントで ls して"]
    );
    const all = rows(events, "call_fg");
    assert.ok(all.some((r) => r.state === "running" && r.resultPreview === "bash: ls -la"), `実行中は子のツールを作業の文にする: ${JSON.stringify(all)}`);
    const last = all.at(-1)!;
    assert.equal(last.state, "done");
    assert.equal(last.label, "List scratch dir");
    assert.equal(last.agentType, "general");
    assert.equal(last.model, "big-pickle");
    assert.equal(last.toolCalls, 1, "同じツール呼び出しの更新は 1 回に数える");
    assert.equal(last.tokens, 5387 + 5599, "子の assistant ごとのトークンの合計");
    assert.equal(last.background, false);
    assert.equal(last.resultPreview, "2", "<task_result> の中身を結果にする（囲みを出さない）");
    assert.equal(last.result, "2");
    const lastRowEvent = events.map((e) => e.type).lastIndexOf("workflow_progress");
    assert.ok(lastRowEvent < dones[0], "行を閉じてから done");
  } finally {
    await session.close();
  }
});

test("state=\"error\" の <task_error> は failed。中断（Tool execution aborted）は stopped、ほかのエラーは failed", () => {
  const t = new OpenCodeServeTranslator("opencode", "ses_p");
  const events: SessionEvent[] = [];
  const feed = (type: string, props: Record<string, unknown>): void => {
    events.push(...t.feed(type, props));
  };
  t.noteOwnText("やって");
  feed("message.updated", { info: { id: "msg_u1", role: "user" } });
  feed("message.updated", { info: { id: "msg_a1", role: "assistant", parentID: "msg_u1" } });
  const input = { description: "Do it", subagent_type: "general" };
  const part = (callID: string, state: Record<string, unknown>): void =>
    feed("message.part.updated", { part: { id: `prt_${callID}`, messageID: "msg_a1", type: "tool", tool: "task", callID, state } });
  for (const id of ["call_e", "call_abort", "call_fail"]) part(id, { status: "running", input });
  part("call_e", { status: "completed", input, output: '<task id="ses_e" state="error">\n<task_error>\nboom\n</task_error>\n</task>' });
  part("call_abort", { status: "error", input, error: "Tool execution aborted" });
  part("call_fail", { status: "error", input, error: "Rate limit exceeded" });
  feed("session.idle", {});
  assert.equal(rows(events, "call_e").at(-1)?.state, "failed");
  assert.equal(rows(events, "call_e").at(-1)?.result, "boom");
  assert.equal(rows(events, "call_abort").at(-1)?.state, "stopped", "止めたものは失敗ではない");
  assert.equal(rows(events, "call_fail").at(-1)?.state, "failed");
  assert.equal(rows(events, "call_fail").at(-1)?.result, "Rate limit exceeded");
});

// ---- 中断・終了 ----

test("停止で前景の task は stopped。後から届いた task の error も running の part も、stopped を変えない", async () => {
  const { session, sid, events } = await open();
  try {
    user(sid, "msg_u1");
    userText(sid, "msg_u1", "explore して");
    assistant(sid, "msg_a1", "msg_u1");
    const running = { status: "running", input: { description: "Explore", subagent_type: "explore" }, metadata: { parentSessionId: sid, sessionId: `ses_c${uid()}` } };
    taskPart(sid, "msg_a1", "call_i", running);
    await session.interrupt();
    taskPart(sid, "msg_a1", "call_i", running);
    taskPart(sid, "msg_a1", "call_i", { status: "error", input: { description: "Explore" }, error: "Task cancelled" });
    idle(sid);
    const all = rows(events, "call_i");
    assert.equal(all.at(-1)?.state, "stopped", `中断した前景の task は stopped: ${JSON.stringify(all)}`);
    assert.ok(!all.some((r) => r.state === "failed"));
    const stoppedAt = all.findIndex((r) => r.state === "stopped");
    assert.ok(stoppedAt >= 0 && all.slice(stoppedAt).every((r) => r.state === "stopped"), "stopped の後に実行中へ戻らない");
    assert.equal(doneIndexes(events).length, 1);
  } finally {
    await session.close();
  }
});

test("close は実行中の行を（裏で動く task も）stopped で閉じる", async () => {
  const { session, sid, events } = await open();
  user(sid, "msg_u1");
  assistant(sid, "msg_a1", "msg_u1");
  taskPart(sid, "msg_a1", "call_bg", {
    status: "running",
    input: { description: "Slow", background: true },
    metadata: { sessionId: `ses_bgc${uid()}`, background: true }
  });
  idle(sid);
  assert.equal(rows(events, "call_bg").at(-1)?.state, "running", "background の task は親のターンが終わっても実行中");
  await session.close();
  assert.equal(rows(events, "call_bg").at(-1)?.state, "stopped");
});

test("serve の終了では、実行中の行を（裏で動く task も）failed で閉じ、ほかの画面の発言で開いたターンを閉じる", async () => {
  const { session, sid, events } = await open();
  try {
    user(sid, "msg_u1");
    userText(sid, "msg_u1", "裏で動かして");
    assistant(sid, "msg_a1", "msg_u1");
    taskPart(sid, "msg_a1", "call_bg", {
      status: "running",
      input: { description: "Slow", background: true },
      metadata: { sessionId: `ses_bgc${uid()}`, background: true }
    });
    OpenCodeServe.serverExited();
    const all = rows(events, "call_bg");
    assert.equal(all.at(-1)?.state, "failed", JSON.stringify(all));
    assert.equal(doneIndexes(events).length, 1, "閉じる手段の無くなったターンを閉じる");
  } finally {
    await session.close();
  }
  assert.equal(rows(events, "call_bg").filter((r) => r.state !== "running").length, 1, "close では閉じ直さない");
});

// ---- background の task と知らせのターン ----

test("background の task は state=\"running\" の出力では終わらず、子の idle で閉じる。差し込まれた結果のターンは知らせのターン", async () => {
  const { session, sid, events } = await open();
  const child = `ses_c${uid()}`;
  try {
    user(sid, "msg_u1");
    userText(sid, "msg_u1", "裏で sleep して");
    assistant(sid, "msg_a1", "msg_u1");
    taskPart(sid, "msg_a1", "call_bg", { status: "pending", input: {} });
    dispatch("session.created", { sessionID: child, info: { id: child, parentID: sid } });
    const input = { description: "Slow sleeper", prompt: "sleep 20", subagent_type: "general", background: true };
    taskPart(sid, "msg_a1", "call_bg", {
      status: "running",
      title: "Slow sleeper",
      input,
      metadata: { parentSessionId: sid, sessionId: child, background: true, model: { modelID: "big-pickle", providerID: "opencode" } }
    });
    taskPart(sid, "msg_a1", "call_bg", {
      status: "completed",
      title: "Slow sleeper",
      input,
      output: `<task id="${child}" state="running">\n<summary>Background task started</summary>\n<task_result>\nThe task is working in the background.\n</task_result>\n</task>`,
      metadata: { parentSessionId: sid, sessionId: child, background: true, jobId: child }
    });
    delta(sid, "msg_a1", "LAUNCHED");
    idle(sid);
    const snapshot = JSON.parse(session.subagentSnapshot() ?? "{}") as { subtype?: string; epoch?: string; agents?: Row[] };

    // 親のターンが終わった後の子の進み具合と終わり。
    assistant(child, "msg_ca", "msg_cu", { modelID: "big-pickle" });
    childTool(child, "msg_ca", "call_sleep", "bash", { status: "running", input: { command: "sleep 20" } });
    dispatch("message.part.updated", { sessionID: child, part: { id: "prt_ct", messageID: "msg_ca", sessionID: child, type: "text", text: "slept" } });
    dispatch("session.status", { sessionID: child, status: { type: "idle" } });
    idle(child);

    // 差し込まれた子の結果で、親の新しいターンが回る。
    user(sid, "msg_u2");
    userText(
      sid,
      "msg_u2",
      `<task id="${child}" state="completed">\n<summary>Background task completed: Slow sleeper</summary>\n<task_result>\nslept\n</task_result>\n</task>`,
      true
    );
    assistant(sid, "msg_a3", "msg_u2");
    delta(sid, "msg_a3", "DONE");
    idle(sid);

    const dones = doneIndexes(events);
    assert.equal(dones.length, 2, "done はターミナルのターンと知らせのターンで 2 回");
    assert.equal(events[dones[0]].metadata?.origin, undefined);
    assert.equal(events[dones[1]].metadata?.origin, "task-notification");
    assert.equal(text(events.slice(0, dones[0])), "LAUNCHED");
    assert.equal(text(events.slice(dones[0], dones[1])), "DONE", "知らせのターンの本文を流す");
    assert.deepEqual(
      events.filter((e) => e.type === "user_message").map((e) => e.content),
      ["裏で sleep して"],
      "差し込みは発言として流さない"
    );
    const beforeIdle = rows(events.slice(0, dones[0]), "call_bg");
    assert.equal(beforeIdle.at(-1)?.state, "running", `state="running" の出力では終わりにしない: ${JSON.stringify(beforeIdle)}`);
    assert.equal(beforeIdle.at(-1)?.background, true);
    const all = rows(events, "call_bg");
    assert.equal(all.at(-1)?.state, "done");
    assert.equal(all.at(-1)?.result, "slept");
    assert.ok(all.some((r) => r.resultPreview === "bash: sleep 20"), "親のターンの後も子の作業を出す");
    // 親のターンが終わった時点のスナップショットにも、実行中の行が入る。
    assert.equal(snapshot.subtype, "workflow_snapshot");
    assert.equal(snapshot.agents?.[0]?.state, "running");
    assert.equal(typeof snapshot.epoch, "string");
  } finally {
    await session.close();
  }
});

test("孫のセッションの進み具合は、祖先の直下の子の行に数える（孫の idle では閉じない）", async () => {
  const { session, sid, events } = await open();
  const child = `ses_c${uid()}`;
  const grandchild = `ses_g${uid()}`;
  try {
    user(sid, "msg_u1");
    assistant(sid, "msg_a1", "msg_u1");
    taskPart(sid, "msg_a1", "call_bg", {
      status: "running",
      input: { description: "Delegate", background: true },
      metadata: { parentSessionId: sid, sessionId: child, background: true }
    });
    dispatch("session.created", { sessionID: grandchild, info: { id: grandchild, parentID: child } });
    childTool(grandchild, "msg_ga", "call_g1", "grep", { status: "running", input: { pattern: "TODO" } });
    idle(grandchild);
    const last = rows(events, "call_bg").at(-1);
    assert.equal(last?.state, "running");
    assert.equal(last?.toolCalls, 1);
    assert.equal(last?.resultPreview, "grep: TODO");
  } finally {
    await session.close();
  }
});

// ---- 自分が送っていないターン ----

test("自分のターンの後に来たターミナルの発言は別のターンとして流し、古い発言の再 publish ではターンを開かない", () => {
  const t = new OpenCodeServeTranslator("opencode", "ses_p");
  const events: SessionEvent[] = [];
  const feed = (type: string, props: Record<string, unknown>): void => {
    events.push(...t.feed(type, props));
  };
  t.noteOwnText("自分の質問");
  feed("message.updated", { info: { id: "msg_u1", role: "user", time: { created: Date.now() } } });
  feed("message.part.updated", { part: { id: "prt_u1", messageID: "msg_u1", type: "text", text: "自分の質問" } });
  feed("message.updated", { info: { id: "msg_a1", role: "assistant", parentID: "msg_u1" } });
  feed("message.part.delta", { messageID: "msg_a1", partID: "prt_a1", field: "text", delta: "A" });
  feed("session.idle", {});

  feed("message.updated", { info: { id: "msg_u2", role: "user", time: { created: Date.now() } } });
  feed("message.part.updated", { part: { id: "prt_u2", messageID: "msg_u2", type: "text", text: "ターミナルから" } });
  feed("message.updated", { info: { id: "msg_a2", role: "assistant", parentID: "msg_u2" } });
  feed("message.part.delta", { messageID: "msg_a2", partID: "prt_a2", field: "text", delta: "B" });
  feed("session.idle", {});

  feed("message.updated", { info: { id: "msg_old", role: "user", time: { created: Date.now() - 600_000 } } });
  feed("session.idle", {});

  const dones = doneIndexes(events);
  assert.equal(dones.length, 2, "古い発言の再 publish ではターンを開かない");
  assert.deepEqual(
    events.filter((e) => e.type === "user_message").map((e) => e.content),
    ["ターミナルから"],
    "自分の送信は流さず、ほかの画面の発言だけ 1 回流す"
  );
  assert.equal(text(events.slice(dones[0], dones[1])), "B");
  assert.equal(events[dones[1]].metadata?.origin, undefined);
});

test("ほかの画面の発言で始まったターンでは終わった行を捨て、知らせのターンでは捨てない", () => {
  const t = new OpenCodeServeTranslator("opencode", "ses_p");
  const feed = (type: string, props: Record<string, unknown>): SessionEvent[] => t.feed(type, props);
  t.noteOwnText("やって");
  feed("message.updated", { info: { id: "msg_u1", role: "user" } });
  feed("message.updated", { info: { id: "msg_a1", role: "assistant", parentID: "msg_u1" } });
  const part = (callID: string, state: Record<string, unknown>): void => {
    feed("message.part.updated", { part: { id: `prt_${callID}`, messageID: "msg_a1", type: "tool", tool: "task", callID, state } });
  };
  part("call_1", { status: "running", input: { description: "One" } });
  part("call_1", { status: "completed", input: { description: "One" }, output: '<task id="ses_1" state="completed">\n<task_result>\nok\n</task_result>\n</task>' });
  feed("session.idle", {});
  // 差し込みで開いた知らせのターン: 終わった行を残す。
  feed("message.updated", { info: { id: "msg_n", role: "user", time: { created: Date.now() } } });
  feed("message.part.updated", { part: { id: "prt_n", messageID: "msg_n", type: "text", synthetic: true, text: '<task id="ses_x" state="completed">\n<task_result>\nx\n</task_result>\n</task>' } });
  const notified = feed("session.idle", {});
  assert.equal(notified[0]?.metadata?.origin, "task-notification");
  assert.equal((JSON.parse(t.snapshot()!) as { agents: Row[] }).agents.length, 1, "知らせのターンでは終わった行を捨てない");
  // ターミナルの発言で開いたターン: 終わった行を捨てる。
  feed("message.updated", { info: { id: "msg_t", role: "user", time: { created: Date.now() } } });
  feed("message.part.updated", { part: { id: "prt_t", messageID: "msg_t", type: "text", text: "ターミナルから" } });
  assert.equal((JSON.parse(t.snapshot()!) as { agents: Row[] }).agents.length, 0);
});

test("POST の戻りの控えの finish(turn) は、その後に開いた差し込みのターンを閉じない", () => {
  const t = new OpenCodeServeTranslator("opencode", "ses_p");
  t.noteOwnText("やって");
  const own = t.currentTurn;
  t.feed("message.updated", { info: { id: "msg_u1", role: "user" } });
  assert.equal(t.feed("session.idle", {}).length, 1);
  // 裏で動いていた子の結果が、POST の戻りの直後に差し込まれた。
  t.feed("message.updated", { info: { id: "msg_n", role: "user", time: { created: Date.now() } } });
  t.feed("message.part.updated", { part: { id: "prt_n", messageID: "msg_n", type: "text", synthetic: true, text: '<task id="ses_x" state="completed">\n<task_result>\nx\n</task_result>\n</task>' } });
  assert.deepEqual(t.finish(own), [], "自分のターンはもう閉じている");
  t.feed("message.updated", { info: { id: "msg_a", role: "assistant", parentID: "msg_n" } });
  t.feed("message.part.delta", { messageID: "msg_a", partID: "prt_a", field: "text", delta: "報告" });
  const done = t.feed("session.idle", {});
  assert.equal(done[0]?.type, "done");
  assert.equal(done[0]?.metadata?.origin, "task-notification");
});

test("行が無くてもスナップショットは agents: []（kind subagents・epoch 付き）", async () => {
  const { session } = await open();
  const snap = JSON.parse(session.subagentSnapshot() ?? "{}") as Record<string, unknown>;
  assert.equal(snap.subtype, "workflow_snapshot");
  assert.equal(snap.kind, "subagents");
  assert.equal(typeof snap.epoch, "string");
  assert.deepEqual(snap.agents, []);
  await session.close();
});

test("taskOutputSessionId は <task …> の id 属性だけを読む", () => {
  assert.equal(taskOutputSessionId('<task id="ses_ea64" state="completed">\n<task_result>\n2\n</task_result>\n</task>'), "ses_ea64");
  assert.equal(taskOutputSessionId('<task state="running" id="ses_b">'), "ses_b");
  assert.equal(taskOutputSessionId('<task task_id="x">'), undefined);
  assert.equal(taskOutputSessionId("plain text"), undefined);
});

// ---- 行ごとの停止（shared/fixtures/background-control/opencode-stop。BACKGROUND_CONTROL §3.6・§4.4） ----

const stopFixtureDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "shared", "fixtures", "background-control", "opencode-stop");
const DIRECTORY = "/tmp/fixture/opencode-stop/work/proj";

type Frame = Record<string, unknown>;

const loadFrames = (name: string): Frame[] =>
  fs
    .readFileSync(path.join(stopFixtureDir, `${name}.events.jsonl`), "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l) as Frame);

const probeIndex = (frames: Frame[], pattern: RegExp): number => frames.findIndex((f) => f.kind === "probe" && pattern.test(String(f.what)));

/** 記録した SSE のフレームを、ServeListener へ回る OpenCodeServe.dispatch に流す（probe は飛ばす）。 */
const play = (frames: Frame[]): void => {
  for (const f of frames) if (f.kind === "sse") OpenCodeServe.dispatch(JSON.stringify(f.frame));
};

interface StopCall {
  method: string;
  route: string;
  body?: unknown;
  directory?: string;
}

interface StopHarness {
  session: OpenCodeServeTerminalSession;
  sid: string;
  events: SessionEvent[];
  calls: StopCall[];
  epoch(): string;
}

/**
 * 記録の「停止を送る直前」まで流し、その後の POST /session/<子>/abort は記録の続き（反応）を流して true を返す偽の http にする。
 * pending は GET /permission の返事。reaction が false なら abort を受けても何も流さない（行が閉じない）。
 */
async function stopHarness(
  t: TestContext,
  name: string,
  opts: { sent: RegExp; until: RegExp; pending?: Array<Record<string, unknown>>; reaction?: boolean; abortFails?: boolean }
): Promise<StopHarness> {
  const frames = loadFrames(name);
  const sentAt = probeIndex(frames, opts.sent);
  const untilAt = probeIndex(frames, opts.until);
  assert.ok(sentAt > 0 && untilAt > sentAt, `${name}: probe が見つかる`);
  const created = frames.find((f) => f.kind === "sse" && ((f.frame as Frame).payload as Frame).type === "session.created" && !(((((f.frame as Frame).payload as Frame).properties as Frame).info as Frame).parentID));
  const sid = String((((((created!.frame as Frame).payload as Frame).properties as Frame).info as Frame).id));
  const calls: StopCall[] = [];
  t.mock.method(OpenCodeServe, "http", async (method: string, route: string, body?: unknown, directory?: string) => {
    calls.push({ method, route, body, directory });
    if (method === "POST" && /\/abort$/.test(route)) {
      if (opts.abortFails) throw new Error("HTTP 500 POST abort: boom");
      if (opts.reaction !== false) play(frames.slice(sentAt + 1, untilAt));
      return true;
    }
    if (method === "GET" && route === "permission") return opts.pending ?? [];
    if (method === "GET" && route === "question") return [];
    return true;
  });
  const session = new OpenCodeServeTerminalSession("opencode", sid, DIRECTORY);
  const events: SessionEvent[] = [];
  await session.watch((e) => events.push(e));
  play(frames.slice(0, sentAt));
  return { session, sid, events, calls, epoch: () => String((JSON.parse(session.subagentSnapshot() ?? "{}") as Frame).epoch) };
}

const stopOf = (h: StopHarness, rowId: string) => ({ taskId: "subagents", rowId, epoch: h.epoch() });
const toolEndsOf = (events: SessionEvent[], id: string): SessionEvent[] => events.filter((e) => e.type === "tool_end" && e.toolUseId === id);
const lastRow = (events: SessionEvent[], id: string): Row | undefined => rows(events, id).at(-1);

test("opencode-stop e1b: 前景の子の行は子 sid が分かると stoppable。abort は子の sid へ（親には送らない）、stopped で、task の tool_end は interrupted", async (t) => {
  const h = await stopHarness(t, "e1b-abort-child", { sent: /^stop-sent$/, until: /^stop-response$/ });
  try {
    const call = "call_00_V9AQ7I78Wc0nzMbcCAou4156";
    const child = "ses_ea1c2f7fbffetg4wPJb8wFEz5C";
    assert.equal(lastRow(h.events, call)?.state, "running");
    assert.equal(lastRow(h.events, call)?.stoppable, true);
    assert.deepEqual(await h.session.stopTask(stopOf(h, call)), { kind: "stopped" });
    const abort = h.calls.find((c) => c.method === "POST");
    assert.deepEqual(abort, { method: "POST", route: `session/${child}/abort`, body: {}, directory: DIRECTORY });
    assert.ok(!h.calls.some((c) => c.route.includes(h.sid)), "親のセッションには何も送らない");
    assert.equal(lastRow(h.events, call)?.state, "stopped");
    assert.equal(lastRow(h.events, call)?.stoppable, false);
    // 返事待ちの間は stoppable: false。閉じた行も false。
    assert.deepEqual(rows(h.events, call).map((r) => r.stoppable).slice(-3), [true, false, false]);
    assert.ok(!rows(h.events, call).some((r) => r.state === "failed"));
    // 親のターンは止めない（done を出さない）。
    assert.equal(doneIndexes(h.events).length, 0);
    const ends = toolEndsOf(h.events, call);
    assert.equal(ends.length, 1);
    assert.equal(ends[0].metadata?.status, "interrupted");
    // 閉じた行への停止は何も送らず not_running。
    const before = h.calls.length;
    assert.deepEqual(await h.session.stopTask(stopOf(h, call)), { kind: "notRunning" });
    assert.equal(h.calls.length, before);
  } finally {
    await h.session.close();
  }
});

test("opencode-stop e3: 2 つの子のうち 1 つを止めても、もう 1 つは動き続け stoppable のまま", async (t) => {
  const h = await stopHarness(t, "e3-two-children", { sent: /^stop-sent$/, until: /^stop-response$/ });
  try {
    const a = "call_00_ET_YIOMlKMVbN1Gj2zThJYf1620";
    const others = [...new Set(rows(h.events).map((r) => String(r.id)))].filter((id) => id !== a);
    assert.equal(others.length, 1);
    assert.deepEqual(await h.session.stopTask(stopOf(h, a)), { kind: "stopped" });
    assert.equal(lastRow(h.events, a)?.state, "stopped");
    assert.equal(lastRow(h.events, others[0])?.state, "running");
    assert.equal(lastRow(h.events, others[0])?.stoppable, true);
  } finally {
    await h.session.close();
  }
});

test("opencode-stop e6: 背景の子は abort の後の子の session.error（MessageAbortedError）と idle で stopped になる", async (t) => {
  const h = await stopHarness(t, "e6-bg-abort", { sent: /^abort-child-sent$/, until: /^abort-child-response$/ });
  try {
    const call = rows(h.events)[0].id as string;
    assert.equal(lastRow(h.events, call)?.background, true);
    assert.equal(lastRow(h.events, call)?.state, "running");
    assert.equal(lastRow(h.events, call)?.stoppable, true);
    assert.deepEqual(await h.session.stopTask(stopOf(h, call)), { kind: "stopped" });
    assert.equal(lastRow(h.events, call)?.state, "stopped");
    assert.ok(!rows(h.events, call).some((r) => r.state === "failed"));
  } finally {
    await h.session.close();
  }
});

test("opencode-stop e9b2 / e9b3: abort の後に、子と子孫の保留中の承認だけを reject（permission は reply reject、question は reject）。関係ないセッションは断らない", async (t) => {
  const e9b2 = loadFrames("e9b2-edge-B2");
  const perm = (e9b2[probeIndex(e9b2, /^perm-asked$/)] as Frame).perm as Record<string, unknown>;
  const child = String(perm.sessionID);
  const grandchild = `ses_gc${uid()}`;
  const other = `ses_other${uid()}`;
  const pending = [
    { id: String(perm.id), sessionID: child },
    { id: "per_grandchild", sessionID: grandchild },
    { id: "per_other", sessionID: other }
  ];
  const h = await stopHarness(t, "e9b2-edge-B2", { sent: /^abort-while-permission$/, until: /^pending-after-abort$/, pending });
  try {
    dispatch("session.created", { sessionID: grandchild, info: { id: grandchild, parentID: child } });
    const call = rows(h.events)[0].id as string;
    assert.deepEqual(await h.session.stopTask(stopOf(h, call)), { kind: "stopped" });
    const methods = h.calls.map((c) => `${c.method} ${c.route}`);
    const abortAt = methods.indexOf(`POST session/${child}/abort`);
    assert.ok(abortAt >= 0, "子へ abort");
    const rejects = h.calls.filter((c) => c.method === "POST" && c.route.startsWith("permission/"));
    // e9b3 の記録した reject と同じ route・本文の形
    const e9b3 = loadFrames("e9b3-edge-B");
    const recorded = e9b3[probeIndex(e9b3, /^reject-stale-permission$/)] as Frame;
    assert.deepEqual(recorded.body, { reply: "reject" });
    assert.match(String(recorded.route), /^\/permission\/per_[^/]+\/reply$/);
    assert.deepEqual(
      rejects.map((c) => ({ route: c.route, body: c.body })).sort((x, y) => x.route.localeCompare(y.route)),
      [
        { route: "permission/per_grandchild/reply", body: { reply: "reject" } },
        { route: `permission/${String(perm.id)}/reply`, body: { reply: "reject" } }
      ].sort((x, y) => x.route.localeCompare(y.route))
    );
    for (const r of rejects) assert.ok(methods.indexOf(`POST ${r.route}`) > abortAt, "reject は abort の後");
    assert.ok(!h.calls.some((c) => c.route.includes("per_other")));
    assert.ok(h.calls.some((c) => c.method === "GET" && c.route === "question"));
  } finally {
    await h.session.close();
  }
});

test("question も子と子孫のものだけ POST /question/<id>/reject {} で断る", async (t) => {
  const h = await stopHarness(t, "e1b-abort-child", { sent: /^stop-sent$/, until: /^stop-response$/ });
  const child = "ses_ea1c2f7fbffetg4wPJb8wFEz5C";
  const questions = [
    { id: "que_child", sessionID: child },
    { id: "que_other", sessionID: "ses_unrelated" }
  ];
  const original = OpenCodeServe.http;
  t.mock.method(OpenCodeServe, "http", async (method: string, route: string, body?: unknown, directory?: string) => {
    if (method === "GET" && route === "question") return questions;
    return (original as (...a: unknown[]) => Promise<unknown>).call(OpenCodeServe, method, route, body, directory);
  });
  try {
    const call = "call_00_V9AQ7I78Wc0nzMbcCAou4156";
    assert.deepEqual(await h.session.stopTask(stopOf(h, call)), { kind: "stopped" });
    const posted = h.calls.filter((c) => c.method === "POST" && c.route.startsWith("question/"));
    assert.deepEqual(posted, [{ method: "POST", route: "question/que_child/reject", body: {}, directory: DIRECTORY }]);
  } finally {
    await h.session.close();
  }
});

test("abort が 2xx でなければ failed（CLI の文つき）で、行は止められるまま。閉じなければ failed で stoppable に戻す", async (t) => {
  const failing = await stopHarness(t, "e1b-abort-child", { sent: /^stop-sent$/, until: /^stop-response$/, abortFails: true });
  try {
    const call = "call_00_V9AQ7I78Wc0nzMbcCAou4156";
    const outcome = await failing.session.stopTask(stopOf(failing, call));
    assert.equal(outcome.kind, "failed");
    assert.match((outcome as { message?: string }).message ?? "", /HTTP 500/);
    assert.equal(lastRow(failing.events, call)?.state, "running");
    assert.equal(lastRow(failing.events, call)?.stoppable, true);
  } finally {
    await failing.session.close();
  }
  const saved = { ...serveStopTiming };
  serveStopTiming.closeMs = 150;
  const silent = await stopHarness(t, "e1b-abort-child", { sent: /^stop-sent$/, until: /^stop-response$/, reaction: false });
  try {
    const call = "call_00_V9AQ7I78Wc0nzMbcCAou4156";
    assert.deepEqual(await silent.session.stopTask(stopOf(silent, call)), { kind: "failed" });
    assert.equal(lastRow(silent.events, call)?.state, "running", "abort の true は何も保証しないので、自分では閉じない");
    assert.equal(lastRow(silent.events, call)?.stoppable, true);
  } finally {
    Object.assign(serveStopTiming, saved);
    await silent.session.close();
  }
});

test("同時の停止は 1 回の abort にまとめる。epoch が違うか行が無ければ stale、子 sid の分からない行は unsupported", async (t) => {
  const h = await stopHarness(t, "e1b-abort-child", { sent: /^stop-sent$/, until: /^stop-response$/ });
  try {
    const call = "call_00_V9AQ7I78Wc0nzMbcCAou4156";
    const [x, y] = await Promise.all([h.session.stopTask(stopOf(h, call)), h.session.stopTask(stopOf(h, call))]);
    assert.deepEqual(x, { kind: "stopped" });
    assert.deepEqual(y, { kind: "stopped" });
    assert.equal(h.calls.filter((c) => /\/abort$/.test(c.route)).length, 1);
    assert.deepEqual(await h.session.stopTask({ taskId: "subagents", rowId: call, epoch: "other" }), { kind: "stale" });
    assert.deepEqual(await h.session.stopTask({ taskId: "subagents", epoch: h.epoch() }), { kind: "stale" });
    assert.deepEqual(await h.session.stopTask({ taskId: "subagents", rowId: "call_unknown", epoch: h.epoch() }), { kind: "stale" });
    assert.deepEqual(await h.session.stopTask({ taskId: "wf-1" }), { kind: "unsupported" });
    // 子 sid が分からない（pending の）行は止められない。
    taskPart(h.sid, "msg_x", "call_pending", { status: "pending", input: { description: "later" } });
    assert.equal(lastRow(h.events, "call_pending")?.stoppable, false);
    assert.deepEqual(await h.session.stopTask(stopOf(h, "call_pending")), { kind: "unsupported" });
  } finally {
    await h.session.close();
  }
});

test("interrupt: 親のターンが動いていなければ abort しない（done を送り直すだけ）。動いていれば abort の後に保留の承認・質問を断る", async (t) => {
  const calls: StopCall[] = [];
  const sid = `ses_i${uid()}`;
  const child = `ses_ic${uid()}`;
  t.mock.method(OpenCodeServe, "http", async (method: string, route: string, body?: unknown, directory?: string) => {
    calls.push({ method, route, body, directory });
    if (method === "GET" && route === "permission") return [{ id: "per_p", sessionID: sid }, { id: "per_c", sessionID: child }, { id: "per_x", sessionID: "ses_other" }];
    if (method === "GET" && route === "question") return [{ id: "que_p", sessionID: sid }];
    return true;
  });
  const session = new OpenCodeServeTerminalSession("opencode", sid, DIRECTORY);
  const events: SessionEvent[] = [];
  await session.watch((e) => events.push(e));
  try {
    await session.interrupt();
    assert.equal(calls.length, 0, "アイドル中は abort しない（背景の子まで止まる）");
    assert.deepEqual(doneIndexes(events).length, 1, "done は送り直す");

    dispatch("session.created", { sessionID: child, info: { id: child, parentID: sid } });
    user(sid, "msg_u1");
    userText(sid, "msg_u1", "続けて");
    assistant(sid, "msg_a1", "msg_u1");
    delta(sid, "msg_a1", "書いています");
    await session.interrupt();
    assert.equal(calls[0].route, `session/${sid}/abort`);
    const rest = calls.slice(1).filter((c) => c.method === "POST");
    assert.deepEqual(
      rest.map((c) => c.route).sort(),
      ["permission/per_c/reply", "permission/per_p/reply", "question/que_p/reject"].sort()
    );
    assert.ok(!calls.some((c) => c.route.includes("per_x")));
  } finally {
    await session.close();
  }
});
