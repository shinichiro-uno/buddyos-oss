import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { SessionEvent } from "../protocol.js";
import { AcpAdapter, AcpSession, toolNameFromTitle } from "./acpAdapter.js";
import { CURSOR_PROFILE, HeadlessCliAdapter } from "./headlessCli.js";

/**
 * ACP と headless（Cursor / Grok の HEADLESS=1）のサブエージェントの行（docs/BACKGROUND_WORK_2026-10-21.md §3.6）。
 * ツール名は title の先頭の識別子にそろえ、委任の行はどの終わり方（中断・猶予切れ・プロセスの死・close・1 ターン 1 プロセスの終了）
 * でも閉じる（中断・close は stopped、異常終了は failed）。
 */

type Row = Record<string, unknown>;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-acp-subagent-"));
// 実ホームの ~/.buddyos（mainagent の設定・既定のモデル）を読まないよう、ホームを一時ディレクトリに向ける。
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;
after(() => {
  try {
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  } catch {
    /* Windows で子プロセスが掴んだまま残っても害は無い */
  }
});

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

/** node のスクリプトを CLI として起こす実行ファイル（Windows は .cmd）。 */
function cli(name: string, script: string): string {
  const file = path.join(tmp, `${name}.mjs`);
  fs.writeFileSync(file, script);
  const bin = process.platform === "win32" ? path.join(tmp, `${name}.cmd`) : path.join(tmp, name);
  fs.writeFileSync(
    bin,
    process.platform === "win32" ? `@"${process.execPath}" "${file}" %*\r\n` : `#!/bin/sh\nexec "${process.execPath}" "${file}" "$@"\n`,
    { mode: 0o755 }
  );
  return bin;
}

/** 流れた workflow_progress（subagents）の行を、届いた順に返す。 */
function rows(events: SessionEvent[], id?: string): Row[] {
  return events
    .filter((e) => e.type === "workflow_progress")
    .flatMap((e) => (JSON.parse(e.content ?? "{}") as { agents?: Row[] }).agents ?? [])
    .filter((r) => id === undefined || r.id === id);
}

async function until(cond: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 250 && !cond(); i += 1) await new Promise((r) => setTimeout(r, 20));
  assert.ok(cond(), label);
}

// ---- ACP ----

// 偽の ACP エージェント。prompt の本文（SCENARIO:<名前>）で、委任の tool_call の流れ方を変える。
//   hermes   : Hermes の「<tool>: <preview>」の title（rawInput 無し）。プレビューにバッククォートがあっても名前は先頭の識別子
//   opencode : opencode acp。pending の tool_call は title "task"・rawInput {}、in_progress の更新で説明と種類、完了は <task …>
//   hang     : 委任を始め、session/cancel を無視して次の委任を始める（prompt に答えない）
//   die      : 委任を始めてプロセスが落ちる
//   error    : 委任を始めて、prompt がエラーで戻る（プロセスは生きている）
//   bg       : opencode の background の task（出力は state="running"）。prompt はすぐ終わる
const acpBin = cli(
  "fake-acp",
  `import readline from "node:readline";
const rl = readline.createInterface({ input: process.stdin });
const send = (m) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\\n");
const update = (u) => send({ method: "session/update", params: { sessionId: "s-1", update: u } });
let prompt;
let scenario = "";
rl.on("line", (line) => {
  const m = JSON.parse(line);
  if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  else if (m.method === "session/new") send({ id: m.id, result: { sessionId: "s-1" } });
  else if (m.method === "session/cancel") {
    if (scenario === "hang") update({ sessionUpdate: "tool_call", toolCallId: "d2", title: "delegate_task: after cancel", kind: "execute", status: "in_progress" });
  } else if (m.method === "session/prompt") {
    prompt = m.id;
    scenario = /SCENARIO:(\\w+)/.exec(m.params.prompt[0].text)?.[1] ?? "";
    const done = () => send({ id: prompt, result: { stopReason: "end_turn" } });
    if (scenario === "hermes") {
      update({ sessionUpdate: "tool_call", toolCallId: "h1", title: "delegate_task: 3 tasks: a | b | c", kind: "execute", status: "in_progress" });
      update({ sessionUpdate: "tool_call_update", toolCallId: "h1", status: "completed", content: [{ type: "content", content: { type: "text", text: "3 tasks started" } }] });
      update({ sessionUpdate: "tool_call", toolCallId: "h2", title: "delegate_task: run \`npm test\` in the repo", kind: "execute", status: "in_progress" });
      update({ sessionUpdate: "tool_call_update", toolCallId: "h2", status: "completed" });
      done();
    } else if (scenario === "opencode") {
      update({ sessionUpdate: "tool_call", toolCallId: "o1", title: "task", kind: "think", status: "pending", rawInput: {} });
      update({ sessionUpdate: "tool_call_update", toolCallId: "o1", status: "in_progress", title: "Explore auth", rawInput: { description: "Explore the auth flow", subagent_type: "explore" } });
      update({ sessionUpdate: "tool_call_update", toolCallId: "o1", status: "completed", content: [{ type: "content", content: { type: "text", text: '<task id="ses_x" state="completed">\\n<task_result>\\nfound it\\n</task_result>\\n</task>' } }] });
      done();
    } else if (scenario === "hang") {
      update({ sessionUpdate: "tool_call", toolCallId: "d1", title: "delegate_task: before cancel", kind: "execute", status: "in_progress" });
    } else if (scenario === "die") {
      update({ sessionUpdate: "tool_call", toolCallId: "x1", title: "delegate_task: doomed", kind: "execute", status: "in_progress" });
      setTimeout(() => process.exit(1), 50);
    } else if (scenario === "error") {
      update({ sessionUpdate: "tool_call", toolCallId: "e1", title: "delegate_task: will fail", kind: "execute", status: "in_progress" });
      send({ id: prompt, error: { code: -32000, message: "model overloaded" } });
    } else if (scenario === "bg") {
      update({ sessionUpdate: "tool_call", toolCallId: "b1", title: "task", kind: "think", status: "pending", rawInput: {} });
      update({ sessionUpdate: "tool_call_update", toolCallId: "b1", status: "completed", content: [{ type: "content", content: { type: "text", text: '<task id="ses_b" state="running">\\n<summary>Background task started</summary>\\n<task_result>\\nworking\\n</task_result>\\n</task>' } }] });
      done();
    } else done();
  }
});`
);
const acpRuntime = { kind: "native" as const, executable: acpBin, label: `native:${acpBin}`, shell: false };

async function openAcp(): Promise<{ session: AcpSession; events: SessionEvent[]; emit: (e: SessionEvent) => void }> {
  const adapter = new AcpAdapter("hermes", acpRuntime, store as never);
  const session = (await adapter.openSession(undefined, tmp)) as AcpSession;
  const events: SessionEvent[] = [];
  return { session, events, emit: (e) => events.push(e) };
}

const prompt = (scenario: string): SessionEvent => ({ type: "user_message", content: `SCENARIO:${scenario}` });

test("ACP のツール名: 「<tool>: <preview>」は先頭の識別子にする（preview のバッククォートより先）", () => {
  assert.equal(toolNameFromTitle("delegate_task: 3 tasks: a | b | c", "execute"), "delegate_task");
  assert.equal(toolNameFromTitle("delegate_task: run `npm test` in the repo", "execute"), "delegate_task");
  assert.equal(toolNameFromTitle("sessions_spawn: task: ビルドして, agentId: coder", "execute"), "sessions_spawn");
  assert.equal(toolNameFromTitle("Run `ls -la`", "execute"), "ls");
  assert.equal(toolNameFromTitle("Read file", "read"), "Read");
  assert.equal(toolNameFromTitle("", "other"), "other");
});

test("ACP（Hermes）: delegate_task の title から委任の行を作り、ツール行の名前に「:」を残さない", async () => {
  const { session, events, emit } = await openAcp();
  try {
    await session.send("SCENARIO:hermes", prompt("hermes"), emit);
    const starts = events.filter((e) => e.type === "tool_start");
    assert.deepEqual(starts.map((e) => e.toolName), ["delegate_task", "delegate_task"]);
    const h1 = rows(events, "h1").at(-1)!;
    assert.equal(h1.state, "done");
    assert.equal(h1.label, "3 tasks: a | b | c", "label から「<tool>: 」を外す");
    assert.equal(h1.labelIsFallback, false);
    assert.equal(rows(events, "h2").at(-1)?.state, "done");
    assert.equal(events.at(-1)?.type, "done");
  } finally {
    await session.close();
  }
});

test("ACP（opencode acp）: in_progress の更新で説明と種類を埋め直し、<task …> の出力から結果を取り出す", async () => {
  const { session, events, emit } = await openAcp();
  try {
    await session.send("SCENARIO:opencode", prompt("opencode"), emit);
    const all = rows(events, "o1");
    assert.equal(all[0]?.labelIsFallback, true, "pending の tool_call は説明が無い");
    const last = all.at(-1)!;
    assert.equal(last.state, "done");
    assert.equal(last.label, "Explore the auth flow");
    assert.equal(last.agentType, "explore");
    assert.equal(last.result, "found it");
    assert.equal(last.resultPreview, "found it");
  } finally {
    await session.close();
  }
});

test("ACP: 停止で委任の行を stopped にし、cancel に応じないまま始まった委任も猶予切れで stopped にする", async () => {
  const grace = AcpSession.interruptGraceMs;
  AcpSession.interruptGraceMs = 300;
  const { session, events, emit } = await openAcp();
  try {
    const turn = session.send("SCENARIO:hang", prompt("hang"), emit);
    await until(() => rows(events, "d1").length > 0, "委任 d1 が始まる");
    await session.interrupt();
    assert.equal(rows(events, "d1").at(-1)?.state, "stopped", "止めたターンの委任は stopped");
    await until(() => rows(events, "d2").length > 0, "cancel の後に委任 d2 が始まる");
    assert.equal(rows(events, "d2").at(-1)?.state, "running");
    await turn;
    assert.equal(rows(events, "d2").at(-1)?.state, "stopped", "猶予切れの後は更新を捨てるので、ここで閉じる");
    assert.equal(events.at(-1)?.type, "done");
    assert.ok(!rows(events).some((r) => r.state === "failed"));
  } finally {
    AcpSession.interruptGraceMs = grace;
    await session.close();
  }
});

test("ACP: エージェントのプロセスが落ちたら、委任の行を failed で閉じてから error と done", async () => {
  const { session, events, emit } = await openAcp();
  try {
    await session.send("SCENARIO:die", prompt("die"), emit);
    assert.equal(rows(events, "x1").at(-1)?.state, "failed");
    const rowAt = events.map((e) => e.type).lastIndexOf("workflow_progress");
    const errorAt = events.findIndex((e) => e.type === "error");
    assert.ok(errorAt > rowAt, "行を閉じてから error");
    assert.equal(events.at(-1)?.type, "done");
  } finally {
    await session.close();
  }
});

test("ACP: prompt がエラーで戻ったターンの委任は、終わりの知らせが来ないので failed で閉じる", async () => {
  const { session, events, emit } = await openAcp();
  try {
    await session.send("SCENARIO:error", prompt("error"), emit);
    assert.equal(rows(events, "e1").at(-1)?.state, "failed");
    assert.deepEqual(
      events.slice(-2).map((e) => e.type),
      ["error", "done"]
    );
  } finally {
    await session.close();
  }
});

test("ACP: 裏で動く task（state=\"running\"）は実行中のまま残し、close で stopped にする。スナップショットは全行", async () => {
  const { session, events, emit } = await openAcp();
  await session.send("SCENARIO:bg", prompt("bg"), emit);
  // ACP は裏で動く task の終わりを転送しないので、running の出力は起動の返事で閉じる（実行中のまま永久に残さない）。
  assert.equal(rows(events, "b1").at(-1)?.state, "done", "running の出力は起動の返事で閉じる");
  assert.equal(rows(events, "b1").at(-1)?.resultPreview, "Background task started");
  const snap = JSON.parse(session.subagentSnapshot() ?? "{}") as { subtype?: string; agents?: Row[] };
  assert.equal(snap.subtype, "workflow_snapshot");
  assert.equal(snap.agents?.[0]?.state, "done");
  await session.close();
  assert.equal(rows(events, "b1").at(-1)?.state, "done");
});

// ---- headless（Cursor の HEADLESS=1。1 ターン 1 プロセス） ----

// 偽の cursor-agent（-p の stream-json）。stdin の本文（SCENARIO:<名前>）で終わり方を変える。どれも Task の委任を始めて閉じない。
//   stop: 正常終了（exit 0）  fail: 異常終了（exit 1）  hang: 止められるまで動く
const cursorBin = cli(
  "fake-cursor",
  `let input = "";
process.stdin.on("data", (c) => (input += c));
process.stdin.on("end", () => {
  const scenario = /SCENARIO:(\\w+)/.exec(input)?.[1] ?? "";
  const call = (id) => process.stdout.write(JSON.stringify({ type: "tool_call", subtype: "started", call_id: id, tool_call: { taskToolCall: { args: { description: "Explore " + id, subagent_type: "explore" } } } }) + "\\n");
  call("c-" + scenario);
  if (scenario === "stop") process.exit(0);
  else if (scenario === "fail") setTimeout(() => process.exit(1), 20);
  else setInterval(() => {}, 1000);
});`
);

test("headless（Cursor）: トラッカーはセッションに 1 つ。どの終わり方でも実行中の行を閉じる（止めた・正常終了は stopped、異常終了は failed）", async () => {
  const previous = process.env.BUDDYOS_CURSOR_HEADLESS;
  process.env.BUDDYOS_CURSOR_HEADLESS = "1";
  try {
    const adapter = new HeadlessCliAdapter("cursor", { kind: "native", executable: cursorBin, label: `native:${cursorBin}`, shell: false }, store as never, CURSOR_PROFILE);
    assert.equal(adapter.usesAcp, false);
    const session = await adapter.openSession(undefined, tmp);
    const events: SessionEvent[] = [];
    const emit = (e: SessionEvent): void => {
      events.push(e);
    };
    try {
      await session.send("SCENARIO:stop", prompt("stop"), emit);
      assert.equal(rows(events, "c-stop").at(-1)?.state, "stopped");
      assert.equal(events.at(-1)?.type, "done");
      const epoch = (JSON.parse(events.find((e) => e.type === "workflow_progress")!.content!) as { epoch: string }).epoch;

      await session.send("SCENARIO:fail", prompt("fail"), emit);
      const failed = rows(events, "c-fail").at(-1)!;
      assert.equal(failed.state, "failed");
      assert.equal(failed.index, 1, "index はセッションの間で続ける");
      assert.ok(events.findIndex((e) => e.type === "error") > events.map((e) => e.type).lastIndexOf("workflow_progress"), "行を閉じてから error");
      const progress = events.filter((e) => e.type === "workflow_progress").map((e) => (JSON.parse(e.content!) as { epoch: string }).epoch);
      assert.ok(progress.every((p) => p === epoch), "同じ世代のまま");

      const turn = session.send("SCENARIO:hang", prompt("hang"), emit);
      await until(() => rows(events, "c-hang").length > 0, "委任が始まる");
      await session.interrupt!();
      await turn;
      assert.equal(rows(events, "c-hang").at(-1)?.state, "stopped");
      assert.equal(events.at(-1)?.type, "done");

      const snap = JSON.parse((session as unknown as { subagentSnapshot(): string }).subagentSnapshot()) as { subtype: string; agents: Row[] };
      assert.equal(snap.subtype, "workflow_snapshot");
      assert.deepEqual(
        snap.agents.map((a) => a.id),
        ["c-hang"],
        "新しいターンで終わった行を捨てる"
      );
    } finally {
      await session.close();
    }
  } finally {
    if (previous === undefined) delete process.env.BUDDYOS_CURSOR_HEADLESS;
    else process.env.BUDDYOS_CURSOR_HEADLESS = previous;
  }
});
