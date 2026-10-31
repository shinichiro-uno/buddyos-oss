import assert from "node:assert/strict";
import { test } from "node:test";

import type { LiveActivityRequest, LiveActivityResponse } from "../pushService.js";
import type { SessionEvent } from "../protocol.js";
import { LiveActivityPublisher, type LiveActivityTransport } from "./publisher.js";

const TOKEN = "ab".repeat(32);
const BATCH = "0b9e2f4a-1c3d-4e5f-8a6b-7c8d9e0f1a2b";

class FakeTransport implements LiveActivityTransport {
  liveActivityAvailable = true;
  targetCalls: Array<Array<{ token: string; environment: string }>> = [];
  sends: LiveActivityRequest[] = [];
  targetsResult: LiveActivityResponse = { status: 200 };
  sendResults: LiveActivityResponse[] = [];
  async liveActivityTargets(targets: Array<{ token: string; environment: string }>): Promise<LiveActivityResponse> {
    this.targetCalls.push(targets);
    return this.targetsResult;
  }
  async sendLiveActivity(req: LiveActivityRequest): Promise<LiveActivityResponse> {
    this.sends.push(req);
    return this.sendResults.shift() ?? { status: 200, sent: true };
  }
}

const flush = async (): Promise<void> => {
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
};

function rig() {
  const transport = new FakeTransport();
  let ms = 1_792_540_800_000;
  const logs: string[] = [];
  const pub = new LiveActivityPublisher({ transport, now: () => ms, newId: () => BATCH, boot: "boot-1", log: (m) => logs.push(m) });
  const states: Array<Record<string, unknown>> = [];
  const send = (evt: SessionEvent): void => void states.push(JSON.parse(evt.content ?? "{}"));
  /** 秒を進めて 1 秒ずつ tick する。 */
  const advance = async (sec: number): Promise<void> => {
    for (let i = 0; i < sec; i++) {
      ms += 1000;
      pub.tick();
      await flush();
    }
  };
  const now = (): number => Math.floor(ms / 1000);
  return { pub, transport, states, send, advance, now, logs };
}

const meta = (over: Record<string, string> = {}): Record<string, string> => ({
  activityId: "act-1", batch: BATCH, environment: "production", running: "3", failed: "0", ...over
});

test("合算: 出どころごとに key の大きい方を取って足す（同じ sessionId は二重に数えない）", async () => {
  const { pub, states, send, advance } = rig();
  pub.registerSender(send);
  assert.equal(states.length, 1);
  assert.deepEqual(states[0], { v: 1, boot: "boot-1", rev: 0, push: false, batch: null, phase: "idle", running: 0, failed: 0, since: null, now: 1_792_540_800 });

  pub.noteSource("hub", { s1: 2, s2: 1 });
  pub.noteSource("panes", { s1: 3, "pane:p9": 1 });
  pub.noteSource("bg", { s2: 1, s3: 1 });
  await advance(1);
  // s1 = max(2, 3), s2 = max(1, 1), pane:p9 = 1, s3 = 1
  const last = states.at(-1)!;
  assert.deepEqual([last.phase, last.running, last.batch, last.since], ["running", 6, BATCH, 1_792_540_800]);
  pub.noteSource("panes", {});
  pub.noteSource("bg", {});
  pub.noteSource("hub", {});
});

test("background_work_state: batch の始まりと終わりはすぐ、数の変化は 1 秒まとめる。rev は変わるたびに増える", async () => {
  const { pub, states, send, advance } = rig();
  pub.registerSender(send);
  pub.noteSource("hub", { s1: 1 });
  assert.equal(states.length, 2, "始まりはすぐ");
  pub.noteSource("hub", { s1: 2 });
  pub.noteSource("hub", { s1: 3 });
  assert.equal(states.length, 2, "数の変化はまとめる");
  await advance(1);
  assert.equal(states.length, 3);
  assert.deepEqual([states[2].running, states[2].rev], [3, 3]);
  pub.noteFinished({ failed: 1 });
  pub.noteSource("hub", {});
  await advance(1);
  assert.equal(states.at(-1)!.phase, "running", "END_GRACE の間は running のまま 0");
  assert.equal(states.at(-1)!.running, 0);
  await advance(20);
  const end = states.at(-1)!;
  assert.deepEqual([end.phase, end.failed, end.batch, end.running], ["failed", 1, BATCH, 0]);
  const revs = states.map((s) => s.rev as number);
  assert.deepEqual(revs, [...revs].sort((a, b) => a - b));
  assert.equal(new Set(revs).size, revs.length, "同じ rev を 2 回送らない");
});

test("register: 形が合わない token・activityId・batch は捨てる。今の batch でなければ受けない", async () => {
  const { pub, transport, advance, logs } = rig();
  pub.registryReady();
  await flush();
  pub.noteSource("hub", { s1: 3 });
  pub.register("dev1", "not-hex", meta());
  pub.register("dev1", TOKEN, meta({ activityId: "bad id!" }));
  pub.register("dev1", TOKEN, meta({ batch: "B1" }));
  pub.register("dev1", TOKEN, meta({ batch: "11111111-2222-4333-8444-555555555555" }));
  await advance(30);
  assert.deepEqual(transport.targetCalls, [[]], "ready の確認のほかは宛先を登録しない");
  assert.equal(transport.sends.length, 0);
  assert.ok(logs.some((l) => l.includes("register rejected")));
  assert.ok(!logs.some((l) => l.includes(TOKEN)), "token 全体はログに出さない");
});

test("register: 登録簿に宛先を登録してから、数が違えばすぐ update（priority 5 の本文は数と phase だけ）", async () => {
  const { pub, transport, advance } = rig();
  pub.registryReady();
  await flush();
  assert.deepEqual(transport.targetCalls, [[]], "ready の確認は空の宛先");
  pub.noteSource("hub", { s1: 2 });
  pub.register("dev1", TOKEN.toUpperCase(), meta({ running: "3" }));
  await flush();
  assert.deepEqual(transport.targetCalls[1], [{ token: TOKEN, environment: "production" }]);
  await advance(1);
  assert.equal(transport.sends.length, 1);
  assert.deepEqual(transport.sends[0], {
    environment: "production",
    token: TOKEN,
    event: "update",
    timestamp: 1_792_540_800,
    state: { phase: "running", running: 2, failed: 0 },
    staleAfterSec: 1500
  });
  // 数が同じなら送らない。終わったら end（dismissAfterSec 300）を 1 回。
  await advance(30);
  assert.equal(transport.sends.length, 1);
  pub.noteFinished({ done: 2 });
  pub.noteSource("hub", {});
  await advance(21);
  assert.equal(transport.sends.length, 2);
  assert.deepEqual(transport.sends[1].state, { phase: "done", running: 0, failed: 0 });
  assert.deepEqual([transport.sends[1].event, transport.sends[1].dismissAfterSec], ["end", 300]);
  await advance(60);
  assert.equal(transport.sends.length, 2);
});

test("ready が false の間は何も送らない（token は持っておき、true になったら登録してから送る）", async () => {
  const { pub, transport, states, send, advance } = rig();
  transport.liveActivityAvailable = false;
  pub.registerSender(send);
  pub.registryReady();
  await flush();
  pub.noteSource("hub", { s1: 1 });
  pub.register("dev1", TOKEN, meta({ running: "1" }));
  pub.noteSource("hub", { s1: 4 });
  await advance(30);
  assert.deepEqual([transport.targetCalls.length, transport.sends.length], [0, 0]);
  assert.equal(states.at(-1)!.push, false);

  transport.liveActivityAvailable = true;
  pub.registryReady();
  await flush();
  await advance(1);
  assert.equal(states.at(-1)!.push, true);
  assert.equal(transport.sends.length, 1);
  assert.equal(transport.sends[0].state.running, 4, "待たせた分は最新の値で");
});

test("ready の確認: 404 は false（1 時間後に確かめ直す）、429・5xx・通信の失敗は 5 分後", async () => {
  const { pub, transport, states, send, advance } = rig();
  pub.registerSender(send);
  transport.targetsResult = { status: 404 };
  pub.registryReady();
  await flush();
  assert.equal(states.at(-1)!.push, false);
  await advance(3599);
  assert.equal(transport.targetCalls.length, 1);
  transport.targetsResult = { status: 200 };
  await advance(2);
  assert.equal(transport.targetCalls.length, 2);
  assert.equal(states.at(-1)!.push, true);

  transport.targetsResult = { status: 0 };
  const other = rig();
  other.transport.targetsResult = { status: 503 };
  other.pub.registryReady();
  await flush();
  await other.advance(299);
  assert.equal(other.transport.targetCalls.length, 1);
  await other.advance(2);
  assert.equal(other.transport.targetCalls.length, 2);
});

test("登録簿の応答: invalid は token を捨てて宛先を登録し直し、sent:false は 60 秒後に最新の値で送り直す", async () => {
  const { pub, transport, advance } = rig();
  pub.registryReady();
  await flush();
  pub.noteSource("hub", { s1: 2 });
  pub.register("dev1", TOKEN, meta({ running: "2" }));
  await flush();
  pub.noteSource("hub", { s1: 3 });
  transport.sendResults.push({ status: 200, sent: false });
  await advance(1);
  assert.equal(transport.sends.length, 1);
  pub.noteSource("hub", { s1: 5 });
  await advance(58);
  assert.equal(transport.sends.length, 1, "60 秒までは送り直さない");
  await advance(3);
  assert.equal(transport.sends.length, 2);
  assert.equal(transport.sends[1].state.running, 5);

  transport.sendResults.push({ status: 200, invalid: true });
  pub.noteSource("hub", { s1: 6 });
  await advance(10);
  assert.equal(transport.sends.length, 3);
  const calls = transport.targetCalls.length;
  await advance(3);
  assert.ok(transport.targetCalls.length > calls, "宛先を登録し直す");
  assert.deepEqual(transport.targetCalls.at(-1), [], "捨てた token は宛先から消える");
  pub.noteSource("hub", { s1: 7 });
  await advance(30);
  assert.equal(transport.sends.length, 3, "捨てた token には送らない");
});

test("登録簿の応答: 403 unknown_token は宛先を登録し直して 1 回だけ送り直す。401 は ready を false にする", async () => {
  const { pub, transport, states, send, advance } = rig();
  pub.registerSender(send);
  pub.registryReady();
  await flush();
  pub.noteSource("hub", { s1: 2 });
  transport.sendResults.push({ status: 403, error: "unknown_token" });
  pub.register("dev1", TOKEN, meta({ running: "1" }));
  await flush();
  await advance(1);
  assert.equal(transport.sends.length, 2, "登録し直して 1 回だけ送り直す");
  assert.equal(transport.targetCalls.length, 3);

  transport.sendResults.push({ status: 401 });
  pub.noteSource("hub", { s1: 4 });
  await advance(11);
  assert.equal(states.at(-1)!.push, false);
  const sent = transport.sends.length;
  pub.noteSource("hub", { s1: 5 });
  await advance(30);
  assert.equal(transport.sends.length, sent, "ready が false の間は送らない");
});

test("clear: token を外し、以後は送らない", async () => {
  const { pub, transport, advance } = rig();
  pub.registryReady();
  await flush();
  pub.noteSource("hub", { s1: 2 });
  pub.register("dev1", TOKEN, meta({ running: "2" }));
  await flush();
  pub.register("dev1", "", { activityId: "act-1", clear: "1" });
  pub.noteSource("hub", { s1: 3 });
  await advance(30);
  assert.equal(transport.sends.length, 0);
});

test("終えた batch の token が後から届いたら、すぐ end を送る", async () => {
  const { pub, transport, states, send, advance } = rig();
  pub.registerSender(send);
  pub.registryReady();
  await flush();
  pub.noteSource("hub", { s1: 1 });
  pub.noteFinished({ done: 1 });
  pub.noteSource("hub", {});
  await advance(21);
  assert.equal(states.at(-1)!.phase, "done");
  pub.register("dev1", TOKEN, meta({ running: "1" }));
  await flush();
  await advance(1);
  assert.deepEqual(transport.sends.map((s) => [s.event, s.state.phase]), [["end", "done"]]);
});

async function readyRig(results: LiveActivityResponse[] = []) {
  const r = rig();
  r.transport.sendResults.push(...results);
  r.pub.registryReady();
  await flush();
  r.pub.noteSource("hub", { s1: 2 });
  r.pub.register("dev1", TOKEN, meta({ running: "3" }));
  await flush();
  return r;
}

test("429: 回数に上限を付けず token を捨てない。全体で Retry-After まで待ち、終わりも送られる", async () => {
  const { pub, transport, advance } = await readyRig(Array.from({ length: 8 }, () => ({ status: 429, retryAfterSec: 10 })));
  await advance(1);
  for (let i = 0; i < 80; i++) {
    pub.noteSource("hub", { s1: 3 + (i % 2) });
    await advance(11);
  }
  assert.ok(transport.sends.length >= 8, "429 のあとも送り直す");
  pub.noteFinished({ done: 1 });
  pub.noteSource("hub", {});
  await advance(25);
  assert.equal(transport.sends.at(-1)!.event, "end");
});

test("更新の失敗で数えた回数を、終わりの送り直しへ持ち越さない（終わりは 5xx でも 30 秒後に送り直す）", async () => {
  const { pub, transport, advance } = await readyRig(Array.from({ length: 5 }, () => ({ status: 0 })));
  for (let i = 0; i < 6; i++) {
    pub.noteSource("hub", { s1: 3 + (i % 2) });
    await advance(125);
  }
  transport.sendResults.push({ status: 502 });
  pub.noteFinished({ done: 1 });
  pub.noteSource("hub", {});
  await advance(21);
  const ends = () => transport.sends.filter((s) => s.event === "end").length;
  assert.equal(ends(), 1);
  await advance(31);
  assert.equal(ends(), 2, "end の 502 のあとに送り直す");
});

test("unknown_token が続いても、宛先の登録に失敗しても token は捨てず 120 秒後に送り直す", async () => {
  const r = rig();
  const { pub, transport, advance } = r;
  let targetCalls = 0;
  transport.liveActivityTargets = async (targets) => {
    transport.targetCalls.push(targets);
    return targetCalls++ < 2 ? { status: 200 } : transport.targetsResult;
  };
  transport.targetsResult = { status: 503 };
  transport.sendResults.push({ status: 403, error: "unknown_token" });
  pub.registryReady();
  await flush();
  pub.noteSource("hub", { s1: 2 });
  pub.register("dev1", TOKEN, meta({ running: "3" }));
  await flush();
  await advance(1);
  const first = transport.sends.length;
  assert.equal(first, 1, "登録できなかったので、すぐの送り直しはしない");
  transport.targetsResult = { status: 200 };
  await advance(130);
  assert.ok(transport.sends.length > first, "登録できたあとに送り直す");
});

test("running・failed は 999 までにして送る。400 は送り直さない", async () => {
  const { pub, transport, advance } = await readyRig([{ status: 400 }]);
  pub.noteSource("hub", { s1: 1200 });
  await advance(12);
  const sent = transport.sends.filter((s) => s.event === "update");
  assert.equal(sent.at(-1)!.state.running, 999);
  const n = transport.sends.length;
  await advance(300);
  assert.equal(transport.sends.length - n <= 1, true, "400 を 2 分ごとに送り直さない");
});
