import assert from "node:assert/strict";
import test from "node:test";
import { SleepGuard } from "./sleepGuard.js";
import { networkSignature } from "./systemMonitor.js";

test("スリープ防止は owner ごとに数え、全部外れたら解く", () => {
  const guard = new SleepGuard(false);
  guard.setActive(true, "sessions");
  guard.setActive(true, "cron");
  guard.setActive(false, "sessions");
  assert.equal(guard.held, true);
  guard.setActive(false, "cron");
  assert.equal(guard.held, false);
});

test("ネットワークの指紋は内部アドレスを含まない", () => {
  assert.equal(networkSignature().includes("127.0.0.1"), false);
});
