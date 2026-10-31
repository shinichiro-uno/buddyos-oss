import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { legacyConfigDir, migrateLegacyDir, resolveConfigDir } from "./config.js";

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-config-"));
const quiet = () => {};
const read = (file: string) => fs.readFileSync(file, "utf8");

test("Windows は Local、古い置き場所は Roaming", () => {
  const env = { LOCALAPPDATA: path.join("C:", "L"), APPDATA: path.join("C:", "R") };
  assert.equal(resolveConfigDir(env, "win32"), path.join("C:", "L", "BuddyOS", "Bridge"));
  assert.equal(legacyConfigDir(env, "win32"), path.join("C:", "R", "BuddyOS", "Bridge"));
});

test("Windows 以外は今までどおり、古い置き場所も無い", () => {
  assert.equal(resolveConfigDir({}, "darwin"), path.join(os.homedir(), ".buddyos-windows-bridge"));
  assert.equal(legacyConfigDir({}, "darwin"), undefined);
});

test("Roaming の ID と状態を Local へ引き継ぎ、古い鍵と止まった Bridge の番号は消す", () => {
  const legacy = tmp();
  const dir = path.join(tmp(), "Bridge");
  fs.writeFileSync(path.join(legacy, "api-key"), "old-key\n");
  fs.writeFileSync(path.join(legacy, "bridge-id"), "windows-bridge-1\n");
  fs.writeFileSync(path.join(legacy, "e2e-key"), "a2V5\n");
  fs.writeFileSync(path.join(legacy, "sessions.json"), "[]");
  fs.mkdirSync(path.join(legacy, "cron"));
  fs.writeFileSync(path.join(legacy, "cron", "jobs.json"), "{}");
  fs.writeFileSync(path.join(legacy, "bridge.port"), "8765");
  // 使われていない（はずの）大きな番号。
  fs.writeFileSync(path.join(legacy, "bridge.pid"), "2147483646");

  migrateLegacyDir(legacy, dir, quiet);

  // 古い鍵は写さずに消す（端末認証 v3 で作り直す。identity.ts の LEGACY_SECRETS）。
  assert.equal(fs.existsSync(path.join(dir, "api-key")), false);
  assert.equal(read(path.join(dir, "bridge-id")), "windows-bridge-1\n");
  assert.equal(fs.existsSync(path.join(dir, "e2e-key")), false);
  assert.equal(read(path.join(dir, "sessions.json")), "[]");
  assert.equal(read(path.join(dir, "cron", "jobs.json")), "{}");
  for (const gone of ["api-key", "bridge-id", "e2e-key", "bridge.port", "bridge.pid"]) {
    assert.equal(fs.existsSync(path.join(legacy, gone)), false, gone);
  }
  // 状態は写すだけ（古い版へ戻したときにも残る）。
  assert.ok(fs.existsSync(path.join(legacy, "sessions.json")));
});

test("Local に先にあるもの（0.1.75 が移したもの）は上書きしない", () => {
  const legacy = tmp();
  const dir = tmp();
  fs.writeFileSync(path.join(legacy, "api-key"), "roaming\n");
  fs.writeFileSync(path.join(legacy, "projects.json"), "[1]");
  fs.writeFileSync(path.join(dir, "api-key"), "local\n");
  fs.writeFileSync(path.join(dir, "projects.json"), "[2]");

  migrateLegacyDir(legacy, dir, quiet);

  assert.equal(read(path.join(dir, "api-key")), "local\n");
  assert.equal(read(path.join(dir, "projects.json")), "[2]");
  assert.equal(fs.existsSync(path.join(legacy, "api-key")), false);
});

test("動いている Bridge の番号は消さない", () => {
  const legacy = tmp();
  const dir = tmp();
  fs.writeFileSync(path.join(legacy, "bridge.port"), "8765");
  fs.writeFileSync(path.join(legacy, "bridge.pid"), String(process.pid));

  migrateLegacyDir(legacy, dir, quiet);

  assert.ok(fs.existsSync(path.join(legacy, "bridge.port")));
  assert.ok(fs.existsSync(path.join(legacy, "bridge.pid")));
});

test("古い置き場所が無い・同じ場所なら何もしない", () => {
  const dir = tmp();
  migrateLegacyDir(path.join(dir, "missing"), path.join(dir, "new"), quiet);
  assert.equal(fs.existsSync(path.join(dir, "new")), false);
  fs.writeFileSync(path.join(dir, "api-key"), "k");
  migrateLegacyDir(dir, dir, quiet);
  assert.equal(read(path.join(dir, "api-key")), "k");
});
