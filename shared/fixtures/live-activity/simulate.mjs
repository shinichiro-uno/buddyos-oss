// Runs scenarios through rules.mjs with a 1-second tick and prints/writes the vectors.
import { writeFileSync } from "node:fs";
import { CFG, Rules } from "./rules.mjs";

// Each step: [t, op, arg]. The simulator ticks every second up to T.
const cases = [
  {
    name: "S1 3 agents for 5 min; app opens at 30 s and starts the activity",
    T: 400,
    steps: [
      [0, "counts", 1], [2, "counts", 2], [4, "counts", 3],
      [31, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 3, shownFailed: 0 }],
      [70, "finished", { done: 1 }], [70, "counts", 2],
      [95, "finished", { done: 1 }], [95, "counts", 1],
      [300, "finished", { done: 1 }], [300, "counts", 0],
    ],
  },
  {
    name: "S2 short agent (8 s): no activity, no push",
    T: 120,
    steps: [[0, "counts", 1], [8, "finished", { done: 1 }], [8, "counts", 0]],
  },
  {
    name: "S3 one of two fails",
    T: 300,
    steps: [
      [0, "counts", 2],
      [16, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 2, shownFailed: 0 }],
      [40, "finished", { failed: 1 }], [40, "counts", 1],
      [90, "finished", { done: 1 }], [90, "counts", 0],
    ],
  },
  {
    name: "S4 single agent 40 min (keepalives)",
    T: 2500,
    steps: [
      [0, "counts", 1],
      [20, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 1, shownFailed: 0 }],
      [2400, "finished", { done: 1 }], [2400, "counts", 0],
    ],
  },
  {
    name: "S5 back-to-back agents with a 10 s gap stay in one batch",
    T: 200,
    steps: [
      [0, "counts", 1],
      [16, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 1, shownFailed: 0 }],
      [50, "finished", { done: 1 }], [50, "counts", 0],
      [60, "counts", 1],
      [100, "finished", { done: 1 }], [100, "counts", 0],
    ],
  },
  {
    name: "S6 counts flap every 3 s for 60 s (coalesced to 10 s)",
    T: 200,
    steps: [
      [0, "counts", 2],
      [16, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 2, shownFailed: 0 }],
      ...Array.from({ length: 20 }, (_, i) => [20 + i * 3, "counts", [3, 2, 4, 2][i % 4]]),
      [90, "counts", 0],
    ],
  },
  {
    name: "S7 count changed between local start and token: first update right away",
    T: 200,
    steps: [
      [0, "counts", 3],
      [15, "counts", 2],
      [17, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 3, shownFailed: 0 }],
      [80, "counts", 0],
    ],
  },
  {
    name: "S8 token arrives after the batch ended: end is sent at once",
    T: 200,
    steps: [
      [0, "counts", 1],
      [14, "counts", 0],
      [40, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 1, shownFailed: 0 }],
    ],
  },
  {
    name: "S9 all stopped by the user",
    T: 200,
    steps: [
      [0, "counts", 2],
      [16, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 2, shownFailed: 0 }],
      [30, "finished", { stopped: 2 }], [30, "counts", 0],
    ],
  },
  {
    name: "S11 two iPhones: each activity is updated on its own",
    T: 300,
    steps: [
      [0, "counts", 2],
      [16, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 2, shownFailed: 0 }],
      [30, "counts", 1],
      [40, "register", { device: "d2", activityId: "a9", batch: "b1", shownRunning: 2, shownFailed: 0 }],
      [100, "counts", 0],
    ],
  },
  {
    name: "S12 new batch after the end: old token is not reused",
    T: 400,
    steps: [
      [0, "counts", 1],
      [16, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 1, shownFailed: 0 }],
      [50, "counts", 0],
      [100, "counts", 2],
      [110, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 1, shownFailed: 0 }],
      [120, "register", { device: "d1", activityId: "a2", batch: "b2", shownRunning: 2, shownFailed: 0 }],
      [200, "counts", 0],
    ],
  },
  {
    name: "S10 user dismissed it (clear): nothing more is sent",
    T: 200,
    steps: [
      [0, "counts", 2],
      [16, "register", { device: "d1", activityId: "a1", batch: "b1", shownRunning: 2, shownFailed: 0 }],
      [30, "clear", { device: "d1", activityId: "a1" }],
      [40, "counts", 1], [90, "counts", 0],
    ],
  },
];

const out = [];
for (const c of cases) {
  const r = new Rules();
  const byT = new Map();
  for (const s of c.steps) {
    if (!byT.has(s[0])) byT.set(s[0], []);
    byT.get(s[0]).push(s);
  }
  for (let t = 0; t <= c.T; t++) {
    for (const [, op, arg] of byT.get(t) ?? []) r[op](t, arg);
    r.tick(t);
  }
  const p10 = r.pushes.filter((p) => p.priority === 10).length;
  console.log(`\n=== ${c.name}  pushes=${r.pushes.length} prio10=${p10}`);
  for (const p of r.pushes) {
    const extra = p.dismissAfterSec !== undefined ? ` dismiss+${p.dismissAfterSec}` : ` stale+${p.staleAfterSec}${p.keepalive ? " keepalive" : ""}`;
    console.log(`  t=${String(p.t).padStart(5)} ${p.event.padEnd(6)} p${p.priority} ${p.state.phase} running=${p.state.running} failed=${p.state.failed}${extra}`);
  }
  for (const s of r.states) console.log(`    state t=${s.t} rev=${s.rev} ${s.phase} batch=${s.batch} running=${s.running} failed=${s.failed} since=${s.since}`);
  out.push({ name: c.name, T: c.T, ids: ["b1", "b2", "b3", "b4"], steps: c.steps.map(([t, op, arg]) => ({ t, op, arg })), expectPushes: r.pushes, expectStates: r.states.map(({ rev, ...s }) => s) });
}
writeFileSync(new URL("./publisher-cases.json", import.meta.url), JSON.stringify({ cfg: CFG, cases: out }, null, 1));
console.log("\nwrote publisher-cases.json", out.length, "cases");
