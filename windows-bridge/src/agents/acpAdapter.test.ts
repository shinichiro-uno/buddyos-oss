import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { SessionEvent } from "../protocol.js";
import { AcpSession, autoPermissionAnswer, matchConfigOption } from "./acpAdapter.js";
import { delegationTiming } from "./acpDelegations.js";
import { CURSOR_PROFILE, GROK_PROFILE, HeadlessCliAdapter } from "./headlessCli.js";
import { HermesAcpAdapter } from "./hermesAcp.js";
import { OpenclawAcpAdapter } from "./openclaw.js";

const options = [
  { id: "a1", kind: "allow_once" },
  { id: "a2", kind: "allow_always" },
  { id: "r1", kind: "reject_once" }
];

test("承認の自動回答: Dangerous は許可、Edit は編集だけ、無人実行は拒否、それ以外は iPhone に聞く", () => {
  assert.equal(autoPermissionAnswer("dangerous", "execute", false, options), "a1");
  assert.equal(autoPermissionAnswer("edit", "edit", false, options), "a1");
  assert.equal(autoPermissionAnswer("edit", "execute", false, options), undefined);
  assert.equal(autoPermissionAnswer("auto", "edit", false, options), undefined);
  assert.equal(autoPermissionAnswer("auto", "execute", true, options), "r1");
  assert.equal(autoPermissionAnswer(undefined, undefined, true, [{ id: "a1", kind: "allow_once" }]), "", "拒否の選択肢が無ければ取り消す");
});

test("設定の選択肢合わせ: 完全一致 → 変種の付かない名前 → 表示名", () => {
  const models = [
    { value: "composer-2.5[fast=true]", name: "Composer 2.5" },
    { value: "auto", name: "Auto" }
  ];
  assert.equal(matchConfigOption("auto", models), "auto");
  assert.equal(matchConfigOption("composer-2.5", models), "composer-2.5[fast=true]");
  assert.equal(matchConfigOption("composer 2.5", models), "composer-2.5[fast=true]");
  assert.equal(matchConfigOption("gpt-x", models), undefined);
});

// 偽の ACP エージェント（cursor-agent acp 相当）: prompt の途中で承認を求め、選ばれた選択肢を返事に書く。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-acp-"));
// 実ホームの ~/.buddyos/cursor.*（既定のモデル・モード）を読まないよう、ホームを一時ディレクトリに向ける。
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;
after(() => {
  try {
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  } catch {
    /* Windows で子プロセスが掴んだまま残っても害は無い */
  }
});
const log = path.join(tmp, "acp-log.jsonl");
const fake = path.join(tmp, "fake-acp.mjs");
fs.writeFileSync(
  fake,
  `import fs from "node:fs"; import readline from "node:readline";
const rl = readline.createInterface({ input: process.stdin });
const send = (m) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\\n");
let mode = "agent"; let prompt;
const modeOption = () => ({ id: "mode", category: "mode", currentValue: mode, options: [{ value: "agent", name: "Agent" }, { value: "plan", name: "Plan" }] });
rl.on("line", (line) => {
  const m = JSON.parse(line);
  fs.appendFileSync(${JSON.stringify(log)}, line + "\\n");
  if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  else if (m.method === "session/new") send({ id: m.id, result: { sessionId: "s-1", configOptions: [modeOption()] } });
  else if (m.method === "session/set_config_option") { mode = m.params.value; send({ id: m.id, result: { configOptions: [modeOption()] } }); }
  else if (m.method === "session/prompt") {
    prompt = m.id;
    send({ id: 77, method: "session/request_permission", params: { sessionId: "s-1", toolCall: { title: "Run ls", kind: "execute", rawInput: { command: "ls" } }, options: [{ optionId: "ok", name: "Allow", kind: "allow_once" }, { optionId: "no", name: "Reject", kind: "reject_once" }] } });
  } else if (m.id === 77 && !m.method) {
    const o = m.result.outcome;
    send({ method: "session/update", params: { sessionId: "s-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "chose:" + (o.optionId ?? o.outcome) } } } });
    send({ id: prompt, result: { stopReason: "end_turn" } });
  }
});`
);
const bin = process.platform === "win32" ? path.join(tmp, "cursor-agent.cmd") : path.join(tmp, "cursor-agent");
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

test("cursor（ACP）: 承認を iPhone のカードにして答えを返し、チャットのモードを set_config_option で効かせる", async () => {
  const adapter = new HeadlessCliAdapter("cursor", { kind: "native", executable: bin, label: `native:${bin}`, shell: false }, store as never, CURSOR_PROFILE);
  assert.equal(adapter.usesAcp, true);
  assert.deepEqual(adapter.modes, ["plan", "edit", "auto", "dangerous"]);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  const emit = (e: SessionEvent): void => {
    events.push(e);
    if (e.type === "action_request") void session.respondToAction!(e.messageId!, "ok", {});
  };
  try {
    session.applyOverrides!({ mode: "plan" });
    await session.send("ls して", { type: "user_message", content: "ls して" }, emit);
    const card = events.find((e) => e.type === "action_request");
    assert.equal(card?.metadata?.kind, "approval");
    assert.equal(card?.metadata?.subtitle, "ls");
    assert.deepEqual([card?.metadata?.option_0_value, card?.metadata?.option_1_value], ["ok", "no"]);
    assert.ok(events.some((e) => e.type === "action_resolved"));
    assert.ok(events.some((e) => e.type === "assistant_delta" && e.content === "chose:ok"));
    assert.equal(events.at(-1)?.type, "done");

    // Dangerous は iPhone に聞かずに許可する。
    session.applyOverrides!({ mode: "dangerous" });
    const cards = events.filter((e) => e.type === "action_request").length;
    const replies = events.filter((e) => e.type === "assistant_delta" && e.content === "chose:ok").length;
    await session.send("もう一度", { type: "user_message", content: "もう一度" }, emit);
    assert.equal(events.filter((e) => e.type === "action_request").length, cards);
    assert.equal(events.filter((e) => e.type === "assistant_delta" && e.content === "chose:ok").length, replies + 1);

    const sent = fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l) as Record<string, unknown>);
    const sets = sent.filter((m) => m.method === "session/set_config_option").map((m) => (m.params as Record<string, unknown>).value);
    assert.deepEqual(sets, ["plan", "agent"], "plan はそのまま、それ以外のモードは agent");
  } finally {
    await session.close();
  }
});

// ---- 非同期の委任の本当の完了（docs/BACKGROUND_CONTROL_2026-10-21.md §5。shared/fixtures/background-control/acp-delegation を流す） ----

type Row = Record<string, unknown>;
type Rpc = Record<string, unknown>;
interface Segment {
  /** 順に流す。respond は session/prompt の応答（id は実際の prompt に付け替える） */
  messages: Array<{ msg: Rpc; respond?: boolean }>;
}

const fixtureDir = path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "..", "..", "..", "shared", "fixtures", "background-control", "acp-delegation");

/** 実測の記録（{t, rel, dir, msg}）から、prompt ごとに流す recv を切り出す。transform で並びを加工できる。 */
function fixtureScript(name: string, transform: (msgs: Rpc[]) => Rpc[] = (m) => m): { sessionId: string; segments: Segment[] } {
  const lines = fs.readFileSync(path.join(fixtureDir, name), "utf8").trim().split("\n").map((l) => JSON.parse(l) as { dir: string; msg: Rpc });
  const promptIndexes = lines.flatMap((l, i) => (l.dir === "send" && l.msg.method === "session/prompt" ? [i] : []));
  const sessionId = (lines[promptIndexes[0]].msg.params as Rpc).sessionId as string;
  const segments = promptIndexes.map((from, k) => {
    const to = promptIndexes[k + 1] ?? lines.length;
    const recvs = transform(lines.slice(from + 1, to).filter((l) => l.dir === "recv").map((l) => l.msg));
    return { messages: recvs.map((msg) => ({ msg, respond: msg.method === undefined && (msg.result as Rpc | undefined)?.stopReason !== undefined })) };
  });
  return { sessionId, segments };
}

// 記録を流す偽の ACP エージェント。prompt ごとに 1 区間を 2 ms 間隔で流し、exitAfter の prompt の後で落ちる。
const replayBin = (() => {
  const file = path.join(tmp, "replay-acp.mjs");
  fs.writeFileSync(
    file,
    `import fs from "node:fs"; import readline from "node:readline";
const script = JSON.parse(fs.readFileSync(process.env.REPLAY_SCRIPT, "utf8"));
const send = (m) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let n = 0;
const rl = readline.createInterface({ input: process.stdin });
rl.on("line", async (line) => {
  const m = JSON.parse(line);
  if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  else if (m.method === "session/new") send({ id: m.id, result: { sessionId: script.sessionId } });
  else if (m.method === "session/set_config_option") send({ id: m.id, result: {} });
  else if (m.method === "session/prompt") {
    const seg = script.segments[n++] ?? { messages: [] };
    for (const { msg, respond } of seg.messages) {
      await sleep(2);
      if (respond) send({ id: m.id, result: msg.result }); else send(msg);
    }
    if (script.exitAfter === n) setTimeout(() => process.exit(0), 30);
  }
});`
  );
  const bin = path.join(tmp, process.platform === "win32" ? "replay-acp.cmd" : "replay-acp");
  fs.writeFileSync(bin, process.platform === "win32" ? `@"${process.execPath}" "${file}" %*\r\n` : `#!/bin/sh\nexec "${process.execPath}" "${file}" "$@"\n`, { mode: 0o755 });
  return bin;
})();
const nativeRuntime = { kind: "native" as const, executable: replayBin, label: `native:${replayBin}`, shell: false };

let scriptCount = 0;
function useScript(script: { sessionId: string; segments: Segment[]; exitAfter?: number }): void {
  const file = path.join(tmp, `script-${scriptCount++}.json`);
  fs.writeFileSync(file, JSON.stringify(script));
  process.env.REPLAY_SCRIPT = file;
}

/** ホームを新しい一時ディレクトリにして（台帳の場所が変わる）、そのパスを返す。 */
function freshHome(): string {
  const home = fs.mkdtempSync(path.join(tmp, "home-"));
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  return home;
}

function rowsOf(events: SessionEvent[], id?: string): Row[] {
  return events
    .filter((e) => e.type === "workflow_progress")
    .flatMap((e) => (JSON.parse(e.content ?? "{}") as { agents?: Row[] }).agents ?? [])
    .filter((r) => id === undefined || r.id === id);
}

async function until(cond: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 400 && !cond(); i += 1) await new Promise((r) => setTimeout(r, 20));
  assert.ok(cond(), label);
}

const send = (session: Awaited<ReturnType<HeadlessCliAdapter["openSession"]>>, text: string, emit: (e: SessionEvent) => void): Promise<void> =>
  session.send(text, { type: "user_message", content: text }, emit);

const notificationDones = (events: SessionEvent[]): SessionEvent[] => events.filter((e) => e.type === "done" && e.metadata?.origin === "task-notification");

function grokSession(): { adapter: HeadlessCliAdapter } {
  return { adapter: new HeadlessCliAdapter("grok", nativeRuntime, store as never, GROK_PROFILE) };
}

test("Grok（背景の spawn）: 受領票で行を閉じず、subagent_finished で閉じ、起こされたターンを発言にして origin 付きの done で閉じる", async () => {
  freshHome();
  const script = fixtureScript("grok-run1.raw.jsonl");
  useScript(script);
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  const toolCallId = "call-7ebffa87-781c-4172-bb7c-264e7e212d9e-0";
  try {
    await send(session, "背景で委任して", (e) => events.push(e));
    // 受領票（completed）を過ぎた時点では行は running のまま。ツールの行だけ閉じる。
    const afterTurn = rowsOf(events, toolCallId);
    assert.ok(afterTurn.length > 0);
    assert.ok(afterTurn.every((r) => r.state === "running" && r.background === true && r.stoppable === false), "子が終わるまで done にしない（状態の無い更新・受領票では閉じない）");
    assert.ok(events.some((e) => e.type === "tool_end" && e.toolUseId === toolCallId));
    assert.equal(events.filter((e) => e.type === "tool_end" && e.toolUseId === toolCallId).length, 1, "状態の無い更新はツールの終わりにしない");
    await until(() => notificationDones(events).length > 0, "起こされたターンの done");

    const rows = rowsOf(events, toolCallId);
    assert.ok(rows.some((r) => r.agentType === "general-purpose" && r.model === "grok-4.7"), "subagent_spawned で種類とモデルが入る");
    assert.ok(rows.some((r) => r.state === "running" && r.tokens === 1516), "subagent_progress で tokens");
    const last = rows.at(-1)!;
    assert.equal(last.state, "done");
    assert.equal(last.result, "OK");
    assert.equal(last.durationMs, 25287);
    assert.equal(last.tokens, 10889);
    assert.equal(last.toolCalls, 1);

    // 起こされたターン: 空の activity で開き、本文は同じ messageId の吹き出し、done に origin。
    const done = notificationDones(events)[0];
    const woken = script.segments[0].messages
      .map((m) => m.msg)
      .filter((m) => m.method === "session/update" && ((m.params as Rpc)._meta as Rpc | undefined)?.promptId === "subagent-completed-01a15e42-115f-7950-b35f-fbb0486940f6");
    const expected = woken.map((m) => ((m.params as Rpc).update as Rpc).content as Rpc).map((c) => c.text as string).join("");
    assert.ok(expected.length > 0);
    const bubble = events.filter((e) => e.type === "assistant_delta" && e.messageId === done.messageId);
    assert.equal(bubble.map((e) => e.content).join(""), expected);
    assert.equal(done.metadata?.silent, undefined, "本文があれば silent にしない");
    assert.ok(events.some((e) => e.type === "activity" && e.messageId === done.messageId && e.content === ""), "開いたときの空の activity");
    // 子のセッションの発言は親に混ざらない。
    const parentText = events.filter((e) => e.type === "assistant_delta").map((e) => e.content).join("");
    assert.ok(!parentText.includes("Run the shell command"));
    assert.equal(notificationDones(events).length, 1, "will_wake == true では silent の done を足さない");
  } finally {
    await session.close();
  }
});

test("Grok（背景の spawn）: 子のセッションの tool_call の title がその行のいまの作業になる", async () => {
  freshHome();
  useScript(fixtureScript("grok-run2.raw.jsonl"));
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "背景で委任して", (e) => events.push(e));
    await until(() => notificationDones(events).length > 0, "起こされたターンの done");
    const rows = rowsOf(events, "call-8e37557c-b179-4814-8b07-9cc6523ed204-0");
    assert.ok(rows.some((r) => r.state === "running" && r.resultPreview === "run_terminal_command"), "子の tool_call の title");
    assert.equal(rows.at(-1)?.state, "done");
    // 子の available_commands_update・agent_message_chunk は親の出力にならない。
    assert.equal((session as unknown as AcpSession).commands.length, 0, "子の available_commands_update は親の commands にならない");
    assert.ok(!events.some((e) => e.type === "assistant_delta" && /sleep 20/.test(e.content ?? "")));
  } finally {
    await session.close();
  }
});

test("Grok（前景の spawn）: subagent_finished で閉じ、結果は子の出力。silent の done は足さない", async () => {
  freshHome();
  // 記録は rate_limit で止められていて prompt の応答が無いので、end_turn の応答を足す。
  useScript(fixtureScript("grok-run3.raw.jsonl", (msgs) => [...msgs, { id: 0, result: { stopReason: "end_turn" } }]));
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "前景で委任して", (e) => events.push(e));
    const rows = rowsOf(events, "call-f0a5c9f4-e034-444e-8909-cc0f2744f4dd-0");
    const last = rows.at(-1)!;
    assert.equal(last.state, "done");
    // tool_call_update の completed が子の出力（subagent_finished の output を含む本文）を持って来て、結果を更新する（今まで通り）。
    assert.ok(String(last.result).startsWith("OK"));
    assert.notEqual(last.background, true);
    assert.equal(notificationDones(events).length, 0);
  } finally {
    await session.close();
  }
});

test("Grok: will_wake が false なら、最後の背景の行が閉じたときに本文の無い silent の done を 1 つ出す", async () => {
  freshHome();
  // subagent_finished の will_wake を false にして、その後（起こされたターン）を落とす。
  const script = fixtureScript("grok-run1.raw.jsonl", (msgs) => {
    const cut = msgs.findIndex((m) => (((m.params as Rpc | undefined)?.update as Rpc | undefined)?.sessionUpdate) === "subagent_finished");
    const head = msgs.slice(0, cut + 1);
    const finished = head[cut];
    ((finished.params as Rpc).update as Rpc).will_wake = false;
    return head;
  });
  useScript(script);
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "背景で委任して", (e) => events.push(e));
    await until(() => notificationDones(events).length > 0, "silent の done");
    const done = notificationDones(events)[0];
    assert.deepEqual(done.metadata, { origin: "task-notification", silent: "1" });
    assert.equal(rowsOf(events).at(-1)?.state, "done");
    assert.equal(notificationDones(events).length, 1);
  } finally {
    await session.close();
  }
});

test("Grok: 起こされたターンが開いたままプロセスが終わったら、done（silent）で閉じる", async () => {
  freshHome();
  const script = fixtureScript("grok-run1.raw.jsonl", (msgs) => {
    // 起こされたターンを開いたところ（queue/changed の runningPromptId）で切る。
    const cut = msgs.findIndex((m) => m.method === "_x.ai/queue/changed" && String((m.params as Rpc).runningPromptId ?? "").startsWith("subagent-completed-"));
    return msgs.slice(0, cut + 1);
  });
  useScript({ ...script, exitAfter: 1 });
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "背景で委任して", (e) => events.push(e));
    await until(() => notificationDones(events).length > 0, "保険の done");
    assert.equal(notificationDones(events)[0].metadata?.silent, "1");
  } finally {
    await session.close();
  }
});

/** 記録（{dir, msg}）の 1 行を取り出す。sid を渡すと sessionId を付け替える。 */
function fixtureLine(name: string, index: number, sid?: string): Rpc {
  const lines = fs.readFileSync(path.join(fixtureDir, name), "utf8").trim().split("\n").map((l) => JSON.parse(l) as { dir: string; msg: Rpc });
  const msg = structuredClone(lines[index].msg);
  if (sid) (msg.params as Rpc).sessionId = sid;
  return msg;
}

const GROK_RUN1_PARENT = "01a15e41-dd82-7540-80d6-94ee898efdca";
const GROK_RUN1_CHILD_ROW = "call-7ebffa87-781c-4172-bb7c-264e7e212d9e-0";

test("Grok: 下の停止で猶予が切れた後（discardingStale）でも、起こされたターンの発言は捨てない。背景の行も stopped にしない", async () => {
  freshHome();
  // 親の prompt の応答を落として（cancel に応じない Grok）、停止の猶予切れで畳ませる。起こされたターンはその後に流れる。
  useScript(fixtureScript("grok-run1.raw.jsonl", (msgs) => msgs.filter((m) => !(m.method === undefined && (m.result as Rpc | undefined)?.stopReason !== undefined))));
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  const saved = AcpSession.interruptGraceMs;
  AcpSession.interruptGraceMs = 20;
  try {
    const turn = send(session, "背景で委任して", (e) => events.push(e));
    await until(() => rowsOf(events, GROK_RUN1_CHILD_ROW).some((r) => r.state === "running" && r.background === true), "背景の行が running");
    await session.interrupt!();
    await turn;
    await until(() => notificationDones(events).length > 0, "起こされたターンの done");
    const rows = rowsOf(events, GROK_RUN1_CHILD_ROW);
    assert.ok(!rows.some((r) => r.state === "stopped"), "下の停止は背景の行を止めない");
    assert.equal(rows.at(-1)?.state, "done", "subagent_finished で閉じる");
    const done = notificationDones(events)[0];
    const bubble = events.filter((e) => e.type === "assistant_delta" && e.messageId === done.messageId).map((e) => e.content).join("");
    assert.ok(bubble.length > 0, "起こされたターンの発言が届く");
    assert.equal(done.metadata?.silent, undefined);
  } finally {
    AcpSession.interruptGraceMs = saved;
    await session.close();
  }
});

test("Grok: 起こされたターンの最中の下の停止は、そのターンを 1 つの done で閉じ、以後の発言を流さない", async () => {
  freshHome();
  useScript(fixtureScript("grok-run1.raw.jsonl"));
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "背景で委任して", (e) => {
      events.push(e);
      // 起こされたターンを開いた空の activity で、すぐ停止する。
      if (e.type === "activity" && e.content === "") void session.interrupt!();
    });
    await until(() => notificationDones(events).length > 0, "done");
    await new Promise((r) => setTimeout(r, 120)); // 残りの発言が流れ終わるまで
    assert.equal(notificationDones(events).length, 1);
    const at = events.indexOf(notificationDones(events)[0]);
    assert.ok(!events.slice(at + 1).some((e) => e.type === "assistant_delta"), "停止の後は発言を流さない");
    assert.equal(notificationDones(events)[0].metadata?.silent, "1", "停止の前に本文が無ければ silent");
  } finally {
    await session.close();
  }
});

test("Grok: 起こされたターンの途中のツールで吹き出しを区切る。ツール前の本文は履歴に残し、後の本文は新しい吹き出し", async () => {
  freshHome();
  const sid = GROK_RUN1_PARENT;
  const pid = "subagent-completed-01a15e42-115f-7950-b35f-fbb0486940f6";
  const chunk = (text: string): Rpc => ({ method: "session/update", params: { sessionId: sid, _meta: { promptId: pid }, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } } });
  const tool = (kind: string, extra: Rpc): Rpc => ({ method: "session/update", params: { sessionId: sid, _meta: { promptId: pid }, update: { sessionUpdate: kind, toolCallId: "wk-1", ...extra } } });
  useScript({
    sessionId: sid,
    segments: [
      {
        messages: [
          { msg: { method: "_x.ai/queue/changed", params: { sessionId: sid, runningPromptId: pid, runningKind: "prompt" } } },
          { msg: chunk("before") },
          { msg: tool("tool_call", { title: "run_terminal_command", kind: "execute" }) },
          { msg: tool("tool_call_update", { status: "completed" }) },
          { msg: chunk("after") },
          { msg: { method: "_x.ai/session_notification", params: { sessionId: sid, update: { sessionUpdate: "turn_completed", prompt_id: pid } } } },
          { msg: { id: 0, result: { stopReason: "end_turn" } }, respond: true }
        ]
      }
    ]
  });
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "go", (e) => events.push(e));
    await until(() => notificationDones(events).length > 0, "done");
    const deltas = events.filter((e) => e.type === "assistant_delta");
    assert.deepEqual(deltas.map((e) => e.content), ["before", "after"]);
    assert.notEqual(deltas[0].messageId, deltas[1].messageId, "ツールの後は新しい吹き出し");
    const ends = events.filter((e) => e.type === "assistant_turn_end").map((e) => e.messageId);
    assert.deepEqual(ends, [deltas[0].messageId, deltas[1].messageId]);
    const iBefore = events.findIndex((e) => e.type === "assistant_turn_end" && e.messageId === deltas[0].messageId);
    const iTool = events.findIndex((e) => e.type === "tool_start");
    assert.ok(iBefore >= 0 && iBefore < iTool, "ツールの前に吹き出しを閉じる");
    assert.ok(events.filter((e) => e.type === "assistant_turn_end").length === 2, "ツールで前のターンの吹き出しを二重に閉じない");
  } finally {
    await session.close();
  }
});

test("Grok: 背景と前景の spawn が同時でも、前景の子の subagent_spawned は前景の行に結ぶ", async () => {
  freshHome();
  const sid = GROK_RUN1_PARENT;
  const fg = fixtureLine("grok-run3.raw.jsonl", 42, sid);
  const fgSpawned = fixtureLine("grok-run3.raw.jsonl", 50, sid);
  const fgFinished = fixtureLine("grok-run3.raw.jsonl", 78, sid);
  ((fgFinished.params as Rpc).update as Rpc).output = "B-OUT";
  const bgFinished = fixtureLine("grok-run1.raw.jsonl", 77, sid);
  ((bgFinished.params as Rpc).update as Rpc).will_wake = false;
  useScript({
    sessionId: sid,
    segments: [
      {
        messages: [
          { msg: fixtureLine("grok-run1.raw.jsonl", 28) },
          { msg: fg },
          { msg: fgSpawned },
          { msg: fixtureLine("grok-run1.raw.jsonl", 34) },
          { msg: fgFinished },
          { msg: fixtureLine("grok-run1.raw.jsonl", 37) },
          { msg: { id: 0, result: { stopReason: "end_turn" } }, respond: true },
          { msg: bgFinished }
        ]
      }
    ]
  });
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "go", (e) => events.push(e));
    await until(() => notificationDones(events).length > 0, "背景の行が閉じて silent の done");
    assert.equal(rowsOf(events, GROK_RUN1_CHILD_ROW).at(-1)?.result, "OK", "背景の行は背景の子の出力");
    assert.equal(rowsOf(events, GROK_RUN1_CHILD_ROW).at(-1)?.state, "done");
    assert.equal(rowsOf(events, "call-f0a5c9f4-e034-444e-8909-cc0f2744f4dd-0").at(-1)?.result, "B-OUT", "前景の行は前景の子の出力");
  } finally {
    await session.close();
  }
});

test("Grok: 子の subagent_finished が受領票より先に来ても、受領票の文で結果を上書きしない", async () => {
  freshHome();
  const sid = GROK_RUN1_PARENT;
  const bgFinished = fixtureLine("grok-run1.raw.jsonl", 77, sid);
  ((bgFinished.params as Rpc).update as Rpc).will_wake = false;
  useScript({
    sessionId: sid,
    segments: [
      {
        messages: [
          { msg: fixtureLine("grok-run1.raw.jsonl", 28) },
          { msg: fixtureLine("grok-run1.raw.jsonl", 34) },
          { msg: bgFinished },
          { msg: fixtureLine("grok-run1.raw.jsonl", 37) },
          { msg: { id: 0, result: { stopReason: "end_turn" } }, respond: true }
        ]
      }
    ]
  });
  const { adapter } = grokSession();
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "go", (e) => events.push(e));
    const last = rowsOf(events, GROK_RUN1_CHILD_ROW).at(-1)!;
    assert.equal(last.state, "done");
    assert.equal(last.result, "OK");
  } finally {
    await session.close();
  }
});

// ---- 先に直す不具合 ----

test("不具合: 別のセッションの available_commands_update は親の commands にならず、状態の無い tool_call_update では行を閉じない", async () => {
  freshHome();
  const sid = "s-parent";
  const update = (sessionId: string, u: Rpc): Rpc => ({ method: "session/update", params: { sessionId, update: u } });
  useScript({
    sessionId: sid,
    segments: [
      {
        messages: [
          { msg: update("s-other", { sessionUpdate: "available_commands_update", availableCommands: [{ name: "other", description: "" }] }) },
          { msg: update(sid, { sessionUpdate: "available_commands_update", availableCommands: [{ name: "mine", description: "" }] }) },
          { msg: update(sid, { sessionUpdate: "tool_call", toolCallId: "d1", title: "delegate_task: 1 tasks: a", kind: "execute", status: "in_progress" }) },
          { msg: update(sid, { sessionUpdate: "tool_call_update", toolCallId: "d1", title: "delegate_task: 1 tasks: a" }) },
          { msg: update(sid, { sessionUpdate: "tool_call", toolCallId: "d2", title: "delegate_task: list", kind: "execute", status: "in_progress" }) },
          { msg: update(sid, { sessionUpdate: "tool_call_update", toolCallId: "d2", status: "completed" }) },
          { msg: { id: 0, result: { stopReason: "end_turn" } }, respond: true }
        ]
      }
    ]
  });
  const adapter = new HeadlessCliAdapter("cursor", nativeRuntime, store as never, CURSOR_PROFILE);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "go", (e) => events.push(e));
    assert.deepEqual((session as unknown as AcpSession).commands.map((c) => c.name), ["mine"]);
    // cursor は従来どおり、状態の無い更新をツールの終わりとみなす。トラッカーは行を閉じない。
    assert.equal(events.filter((e) => e.type === "tool_end" && e.toolUseId === "d1").length, 1);
    const d1 = rowsOf(events, "d1");
    assert.ok(d1.length > 0 && d1.every((r) => r.state === "running"), "状態の無い更新では行を閉じない");
    assert.equal(rowsOf(events, "d2").length, 0, "delegate_task の list は委任ではない");
  } finally {
    await session.close();
  }
});

// ---- Hermes・OpenClaw（台帳） ----

type SqliteSpec = { table: string; columns: Array<{ name: string; type: string; pk: number }>; rows: Row[] };
const ledgers = JSON.parse(fs.readFileSync(path.join(fixtureDir, "ledgers.json"), "utf8")) as { hermes: SqliteSpec; openclaw: SqliteSpec };

async function makeLedger(file: string, spec: SqliteSpec, rows: Row[]): Promise<void> {
  const { DatabaseSync } = (await import("node:sqlite")) as { DatabaseSync: new (f: string) => { exec(sql: string): void; prepare(sql: string): { run(...p: unknown[]): void }; close(): void } };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  try {
    db.exec(`CREATE TABLE IF NOT EXISTS ${spec.table} (${spec.columns.map((c) => `${c.name} ${c.type}${c.pk ? " PRIMARY KEY" : ""}`).join(", ")})`);
    db.exec(`DELETE FROM ${spec.table}`);
    for (const row of rows) {
      const names = Object.keys(row);
      db.prepare(`INSERT INTO ${spec.table} (${names.join(", ")}) VALUES (${names.map(() => "?").join(", ")})`).run(...names.map((n) => row[n]));
    }
  } finally {
    db.close();
  }
}

test("Hermes: 受領票で行を running のまま background にし、台帳が completed になったら done・結果・所要時間で閉じて silent の done", async () => {
  const home = freshHome();
  delegationTiming.intervalMs = 40;
  const dbFile = path.join(home, ".hermes", "state.db");
  const running = ledgers.hermes.rows[0];
  const completed = ledgers.hermes.rows[1];
  await makeLedger(dbFile, ledgers.hermes, [running]);
  useScript(fixtureScript("hermes-run1.raw.jsonl"));
  const adapter = new HermesAcpAdapter("hermes", nativeRuntime, store as never);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "委任して", (e) => events.push(e));
    const id = "tc-8cc4babe04d6";
    const first = rowsOf(events, id);
    assert.ok(first.length > 0);
    assert.ok(first.every((r) => r.state === "running"), "受領票では閉じない");
    const open = rowsOf(events, id).at(-1)!;
    assert.equal(open.background, true);
    assert.equal(open.taskCount, 1);
    assert.equal(open.stoppable, false);
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(rowsOf(events, id).at(-1)?.state, "running", "台帳が running の間は何も変わらない");
    assert.equal(notificationDones(events).length, 0);

    await makeLedger(dbFile, ledgers.hermes, [completed]);
    await until(() => notificationDones(events).length > 0, "台帳の完了");
    const last = rowsOf(events, id).at(-1)!;
    assert.equal(last.state, "done");
    assert.equal(last.result, "OK");
    assert.equal(last.durationMs, 24250);
    assert.deepEqual(notificationDones(events)[0].metadata, { origin: "task-notification", silent: "1" });

    // 次のターンの control call（delegate_task: list）は行を作らない。
    const before = rowsOf(events).length;
    await send(session, "状況は", (e) => events.push(e));
    assert.equal(rowsOf(events, "tc-b5078e40f2c0").length, 0);
    assert.equal(rowsOf(events).length, before);
  } finally {
    delegationTiming.intervalMs = undefined;
    await session.close();
  }
});

test("Hermes: 台帳が読めないときは、今まで通り受領票の時点で done にする（受領票の文が結果）", async () => {
  freshHome();
  delegationTiming.intervalMs = 40;
  useScript(fixtureScript("hermes-run1.raw.jsonl"));
  const adapter = new HermesAcpAdapter("hermes", nativeRuntime, store as never);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "委任して", (e) => events.push(e));
    const id = "tc-8cc4babe04d6";
    await until(() => rowsOf(events, id).at(-1)?.state === "done", "受領票で閉じる");
    assert.ok(String(rowsOf(events, id).at(-1)?.result).includes("dispatched"));
    assert.equal(notificationDones(events).length, 0, "読めないときの終わりは知らせの done にしない");
  } finally {
    delegationTiming.intervalMs = undefined;
    await session.close();
  }
});

test("Hermes: 台帳が途中から読めなくなったら（30 回続けて）受領票の文で done にし、最後の行なら silent の done を 1 つ出す", async () => {
  const home = freshHome();
  delegationTiming.intervalMs = 20;
  const savedMax = delegationTiming.maxFailures;
  delegationTiming.maxFailures = 3;
  const dbFile = path.join(home, ".hermes", "state.db");
  await makeLedger(dbFile, ledgers.hermes, [ledgers.hermes.rows[0]]);
  useScript(fixtureScript("hermes-run1.raw.jsonl"));
  const adapter = new HermesAcpAdapter("hermes", nativeRuntime, store as never);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "委任して", (e) => events.push(e));
    const id = "tc-8cc4babe04d6";
    assert.equal(rowsOf(events, id).at(-1)?.state, "running");
    await makeLedger(dbFile, ledgers.hermes, []); // 行が消えて読めなくなる
    await until(() => rowsOf(events, id).at(-1)?.state === "done", "読めないので閉じる");
    await until(() => notificationDones(events).length > 0, "silent の done");
    await new Promise((r) => setTimeout(r, 80));
    assert.equal(notificationDones(events).length, 1);
    assert.equal(notificationDones(events)[0].metadata?.silent, "1");
  } finally {
    delegationTiming.intervalMs = undefined;
    delegationTiming.maxFailures = savedMax;
    await session.close();
  }
});

test("Hermes: 下の停止は背景の委任の行を止めない（台帳が終わるまで running）", async () => {
  const home = freshHome();
  delegationTiming.intervalMs = 30;
  const dbFile = path.join(home, ".hermes", "state.db");
  await makeLedger(dbFile, ledgers.hermes, [ledgers.hermes.rows[0]]);
  useScript(fixtureScript("hermes-run1.raw.jsonl"));
  const adapter = new HermesAcpAdapter("hermes", nativeRuntime, store as never);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "委任して", (e) => events.push(e));
    const id = "tc-8cc4babe04d6";
    await session.interrupt!(); // 実行中の prompt は無い
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(rowsOf(events, id).at(-1)?.state, "running");
    await makeLedger(dbFile, ledgers.hermes, [ledgers.hermes.rows[1]]);
    await until(() => rowsOf(events, id).at(-1)?.state === "done", "台帳の完了で閉じる");
  } finally {
    delegationTiming.intervalMs = undefined;
    await session.close();
  }
});

test("Hermes: プロセスが落ちたら動いている行は failed。台帳も止まる", async () => {
  const home = freshHome();
  delegationTiming.intervalMs = 40;
  await makeLedger(path.join(home, ".hermes", "state.db"), ledgers.hermes, [ledgers.hermes.rows[0]]);
  useScript({ ...fixtureScript("hermes-run1.raw.jsonl"), exitAfter: 1 });
  const adapter = new HermesAcpAdapter("hermes", nativeRuntime, store as never);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "委任して", (e) => events.push(e));
    await until(() => rowsOf(events, "tc-8cc4babe04d6").at(-1)?.state === "failed", "failed");
  } finally {
    delegationTiming.intervalMs = undefined;
    await session.close();
  }
});

test("OpenClaw: 受領票の runId を台帳で追い、作業の文を流し、プロセスが落ちても行は閉じずに見続け、succeeded で done", async () => {
  const home = freshHome();
  const stateDir = path.join(home, "oc");
  process.env.OPENCLAW_STATE_DIR = stateDir;
  delegationTiming.intervalMs = 40;
  const dbFile = path.join(stateDir, "state", "openclaw.sqlite");
  const child = ledgers.openclaw.rows[0];
  await makeLedger(dbFile, ledgers.openclaw, [{ ...child, status: "running", ended_at: null, progress_summary: null, tool_use_count: 1, last_tool_name: "exec" }]);
  useScript({ ...fixtureScript("openclaw-run3.raw.jsonl"), exitAfter: 1 });
  const adapter = new OpenclawAcpAdapter("openclaw", nativeRuntime, store as never);
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  try {
    await send(session, "委任して", (e) => events.push(e));
    const id = "call_rq3m76fe";
    await until(() => rowsOf(events, id).some((r) => r.resultPreview === "exec" && r.toolCalls === 1), "作業の文");
    await new Promise((r) => setTimeout(r, 200)); // プロセスの終了（close）を過ぎても
    assert.equal(rowsOf(events, id).at(-1)?.state, "running", "OpenClaw の行は閉じない");
    const activities = rowsOf(events, id).filter((r) => r.resultPreview === "exec").length;
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(rowsOf(events, id).filter((r) => r.resultPreview === "exec").length, activities, "変化が無ければ送らない");

    await makeLedger(dbFile, ledgers.openclaw, [child]);
    await until(() => notificationDones(events).length > 0, "succeeded");
    const last = rowsOf(events, id).at(-1)!;
    assert.equal(last.state, "done");
    assert.equal(last.result, "OK");
    assert.equal(notificationDones(events)[0].metadata?.silent, "1");
  } finally {
    delegationTiming.intervalMs = undefined;
    delete process.env.OPENCLAW_STATE_DIR;
    await session.close();
  }
});
