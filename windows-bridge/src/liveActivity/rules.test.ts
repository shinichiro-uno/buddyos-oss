import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { LA_CFG, LiveActivityRules, type LaFinished, type LaPush, type LaRegister, type LaSnapshot } from "./rules.js";

// shared/fixtures/live-activity/publisher-cases.json は Mac（LiveActivityRules）と同じ。同じケースで同じ push と状態の列を出す。
const fixturePath = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "shared", "fixtures", "live-activity", "publisher-cases.json");

interface Step {
  t: number;
  op: "counts" | "finished" | "register" | "clear";
  arg: unknown;
}
interface Case {
  name: string;
  T: number;
  ids: string[];
  steps: Step[];
  expectPushes: Array<Record<string, unknown>>;
  expectStates: Array<Record<string, unknown>>;
}
const fixture = JSON.parse(fs.readFileSync(fixturePath, "utf8")) as { cfg: Record<string, number>; cases: Case[] };

test("規則の値は fixture の cfg と同じ", () => {
  assert.deepEqual({ ...LA_CFG }, fixture.cfg);
});

test("fixture は 12 ケース", () => {
  assert.equal(fixture.cases.length, 12);
});

for (const c of fixture.cases) {
  test(`publisher-cases: ${c.name}`, () => {
    const ids = [...c.ids];
    const pushes: LaPush[] = [];
    const states: Array<{ t: number; s: LaSnapshot }> = [];
    const rules = new LiveActivityRules({
      newId: () => ids.shift() ?? "none",
      onPush: (p) => pushes.push(p),
      onState: (t, s) => states.push({ t, s })
    });
    const byT = new Map<number, Step[]>();
    for (const s of c.steps) byT.set(s.t, [...(byT.get(s.t) ?? []), s]);
    for (let t = 0; t <= c.T; t++) {
      for (const s of byT.get(t) ?? []) {
        if (s.op === "counts") rules.counts(t, s.arg as number);
        else if (s.op === "finished") rules.finished(t, s.arg as LaFinished);
        else if (s.op === "register") rules.register(t, s.arg as LaRegister);
        else rules.clear(t, s.arg as { device: string; activityId: string });
      }
      rules.tick(t);
    }
    const gotPushes = pushes.map((p) => {
      const out: Record<string, unknown> = {
        t: p.t, device: p.device, activityId: p.activityId, event: p.event, priority: p.priority, state: p.state
      };
      if (p.staleAfterSec !== undefined) out.staleAfterSec = p.staleAfterSec;
      if (p.dismissAfterSec !== undefined) out.dismissAfterSec = p.dismissAfterSec;
      return out;
    });
    const wantPushes = c.expectPushes.map(({ keepalive: _keepalive, ...rest }) => rest);
    assert.deepEqual(gotPushes, wantPushes);
    const gotStates = states.map(({ t, s }) => ({ t, batch: s.batch, phase: s.phase, running: s.running, failed: s.failed, since: s.since }));
    assert.deepEqual(gotStates, c.expectStates);
  });
}

function rig(canSend?: () => boolean) {
  let n = 0;
  const pushes: LaPush[] = [];
  const rules = new LiveActivityRules({ newId: () => `b${++n}`, onPush: (p) => pushes.push(p), canSend });
  return { rules, pushes };
}

const reg = (batch: string, over: Partial<LaRegister> = {}): LaRegister => ({
  device: "d1", activityId: "a1", batch, shownRunning: 1, shownFailed: 0, token: "ab".repeat(32), environment: "production", ...over
});

test("canSend が false の間は送らず token を持ち、true になったら最新の値で送る", () => {
  let open = false;
  const { rules, pushes } = rig(() => open);
  rules.counts(0, 1);
  rules.register(1, reg("b1", { shownRunning: 1 }));
  rules.counts(5, 3);
  for (let t = 5; t < 40; t++) rules.tick(t);
  assert.equal(pushes.length, 0);
  open = true;
  rules.tick(40);
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].state.running, 3);
  assert.equal(pushes[0].token, "ab".repeat(32));
});

test("1 端末 4 件・全体 8 件まで。古いものから捨てる", () => {
  const { rules } = rig();
  rules.counts(0, 1);
  for (let i = 0; i < 6; i++) rules.register(1 + i, reg("b1", { activityId: `a${i}`, token: `${i}`.repeat(64) }));
  assert.equal(rules.tokens().length, 4);
  assert.equal(rules.tokens()[0].token, "5".repeat(64));
  for (let d = 2; d <= 4; d++) for (let i = 0; i < 3; i++) rules.register(10 + d * 3 + i, reg("b1", { device: `d${d}`, activityId: `x${i}`, token: `${d}${i}`.repeat(32) }));
  assert.equal(rules.tokens().length, 8);
});

test("12 時間たった token は捨てる", () => {
  const { rules } = rig();
  rules.counts(0, 1);
  rules.register(1, reg("b1"));
  assert.equal(rules.tokens().length, 1);
  rules.tick(1 + 12 * 3600);
  assert.equal(rules.tokens().length, 0);
});

test("retry: 更新は出ている数を戻して待ち、終わりは token を戻す。諦めると捨てる", () => {
  const { rules, pushes } = rig();
  rules.counts(0, 2);
  rules.register(1, reg("b1", { shownRunning: 2 }));
  rules.counts(20, 3);
  assert.equal(pushes.length, 1);
  assert.ok(rules.retry(20, pushes[0], () => 60));
  for (let t = 21; t < 80; t++) rules.tick(t);
  assert.equal(pushes.length, 1);
  rules.tick(80);
  assert.equal(pushes.length, 2);
  assert.equal(pushes[1].state.running, 3);
  rules.delivered(pushes[1]);
  rules.counts(90, 0);
  rules.tick(110);
  const end = pushes.at(-1)!;
  assert.equal(end.event, "end");
  assert.ok(rules.retry(110, end, (a) => [30][a]));
  rules.tick(139);
  assert.equal(pushes.length, 3);
  rules.tick(140);
  assert.equal(pushes.length, 4);
  assert.equal(rules.retry(140, pushes[3], (a) => [30][a]), false);
  rules.tick(1000);
  assert.equal(pushes.length, 4);
});
