import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

import { legacyConfigDir, resolveConfigDir } from "./config.js";
import { BridgeIdentity, migrateLegacyDir, readE2EKey } from "./identity.js";

// 起動時の確かめ・移行・作り直し（spec/PROTOCOL-v3.md Appendix A）。

const quiet = { log: () => {} };
const tmpDir = () => fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-identity-"));
const read = (dir: string, name: string) => fs.readFileSync(path.join(dir, name), "utf8").trim();

/** v2 の Bridge が残したファイル（鍵・端末の登録簿・push のトークン）。 */
function v2Layout(dir: string, home: string): void {
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "e2e-key"), `${Buffer.alloc(32, 7).toString("base64")}\n`);
  fs.writeFileSync(path.join(dir, "api-key"), "old-api-key\n");
  fs.writeFileSync(path.join(dir, "paseo-relay-id"), "old-relay-id");
  fs.writeFileSync(path.join(dir, "bridge-id"), "windows-bridge-keep\n");
  fs.writeFileSync(path.join(dir, "e2e-devices.json"), "{}");
  fs.mkdirSync(path.join(home, ".buddyos"), { recursive: true });
  fs.writeFileSync(path.join(home, ".buddyos", "push_tokens.json"), "{}");
}

test("設定フォルダ: Windows は %LOCALAPPDATA%\\BuddyOS\\Bridge、以前の置き場所は %APPDATA%", () => {
  assert.equal(resolveConfigDir({ LOCALAPPDATA: "C:\\Users\\u\\AppData\\Local" }, "win32"), path.join("C:\\Users\\u\\AppData\\Local", "BuddyOS", "Bridge"));
  assert.equal(legacyConfigDir({ APPDATA: "C:\\Users\\u\\AppData\\Roaming" }, "win32"), path.join("C:\\Users\\u\\AppData\\Roaming", "BuddyOS", "Bridge"));
  assert.equal(legacyConfigDir({}, "linux"), undefined);
  assert.equal(resolveConfigDir({}, "linux"), path.join(os.homedir(), ".buddyos-windows-bridge"));
});

test("移行（auth-v3.json が無い）: 鍵・中継の ID・ローカル鍵を作り直し、bridgeId は残し、古いファイルを消す", () => {
  const dir = tmpDir();
  const home = tmpDir();
  v2Layout(dir, home);
  const identity = BridgeIdentity.open(dir, { ...quiet, env: {}, homeDir: home });
  assert.equal(identity.bridgeId, "windows-bridge-keep");
  assert.notEqual(read(dir, "api-key"), "old-api-key");
  assert.equal(identity.localKey(), read(dir, "api-key"));
  assert.notEqual(identity.relayId, "old-relay-id");
  assert.match(identity.relayId, /^[A-Za-z0-9_-]{43}$/);
  assert.notDeepEqual(identity.e2eKey, Buffer.alloc(32, 7));
  assert.equal(readE2EKey(path.join(dir, "e2e-key")).kind, "ok");
  assert.equal(fs.existsSync(path.join(dir, "e2e-devices.json")), false);
  assert.equal(fs.existsSync(path.join(home, ".buddyos", "push_tokens.json")), false);
  assert.equal(fs.existsSync(path.join(dir, "reset-pending")), false);
  const marker = JSON.parse(read(dir, "auth-v3.json"));
  assert.equal(marker.machineId, null);
  assert.equal(typeof marker.migratedAt, "number");
  assert.equal(identity.devices.lastReset?.reason, "migration_v3");
  assert.equal(identity.devices.epoch, 1);

  // 2 回目の起動では何も作り直さない
  const again = BridgeIdentity.open(dir, { ...quiet, env: {}, homeDir: home });
  assert.equal(again.relayId, identity.relayId);
  assert.equal(again.localKey(), identity.localKey());
  assert.deepEqual(again.e2eKey, identity.e2eKey);
});

test("静的鍵: e2e-key が無い・壊れているときだけ作り直して端末の一覧を空にする。読めない（権限）ときは作り直さずに待つ", { skip: process.platform === "win32" || process.getuid?.() === 0 }, () => {
  const dir = tmpDir();
  const first = BridgeIdentity.open(dir, { ...quiet, env: {} });
  const relayId = first.relayId;

  fs.writeFileSync(path.join(dir, "e2e-key"), "not a key\n");
  const corrupt = BridgeIdentity.open(dir, { ...quiet, env: {} });
  assert.equal(corrupt.keyState, "ok");
  assert.notEqual(corrupt.relayId, relayId);
  assert.equal(corrupt.devices.lastReset?.reason, "key_unreadable");

  fs.rmSync(path.join(dir, "e2e-key"));
  const missing = BridgeIdentity.open(dir, { ...quiet, env: {} });
  assert.equal(missing.devices.lastReset?.reason, "key_unreadable");
  const keyText = read(dir, "e2e-key");

  fs.chmodSync(path.join(dir, "e2e-key"), 0o000);
  try {
    const io = BridgeIdentity.open(dir, { ...quiet, env: {} });
    assert.equal(io.keyState, "io_error");
    assert.equal(io.e2eKey, undefined);
    assert.equal(io.relayId, missing.relayId, "中継の ID も作り直さない");
    assert.equal(JSON.parse(read(dir, "registry-status.json")).lastError, "key_io");
    assert.equal(io.retryKey(), false);
    fs.chmodSync(path.join(dir, "e2e-key"), 0o600);
    assert.equal(io.retryKey(), true);
    assert.equal(io.keyState, "ok");
    assert.equal(read(dir, "e2e-key"), keyText, "読めるようになった鍵をそのまま使う");
    assert.equal(JSON.parse(read(dir, "registry-status.json")).lastError, undefined);
  } finally {
    fs.chmodSync(path.join(dir, "e2e-key"), 0o600);
  }
});

test("resetIdentity: reset-pending を書いてから端末・鍵・中継の ID・ローカル鍵を作り直し、listener の後で消す。account_removed は bridgeId も", () => {
  const dir = tmpDir();
  const identity = BridgeIdentity.open(dir, { ...quiet, env: {} });
  const before = { relayId: identity.relayId, key: identity.localKey(), e2e: identity.e2eKey, bridgeId: identity.bridgeId, epoch: identity.devices.epoch };
  const seen: string[] = [];
  identity.onReset((reason) => {
    seen.push(reason);
    // listener の時点では新しい値になっていて、reset-pending はまだある（途中で落ちたら続きから）
    assert.notEqual(identity.relayId, before.relayId);
    assert.ok(fs.existsSync(path.join(dir, "reset-pending")));
  });
  identity.resetIdentity("user_reset");
  assert.deepEqual(seen, ["user_reset"]);
  assert.equal(fs.existsSync(path.join(dir, "reset-pending")), false);
  assert.equal(identity.bridgeId, before.bridgeId);
  assert.notEqual(identity.localKey(), before.key);
  assert.notDeepEqual(identity.e2eKey, before.e2e);
  assert.equal(identity.devices.epoch, before.epoch + 1);
  assert.equal(identity.devices.lastReset?.reason, "user_reset");

  identity.resetIdentity("account_removed");
  assert.notEqual(identity.bridgeId, before.bridgeId);
  assert.equal(read(dir, "bridge-id"), identity.bridgeId);
});

test("途中で落ちた作り直し（reset-pending が残っている）は、次の起動で続きから行う", () => {
  const dir = tmpDir();
  const first = BridgeIdentity.open(dir, { ...quiet, env: {} });
  fs.writeFileSync(path.join(dir, "reset-pending"), JSON.stringify({ reason: "user_reset", at: 1 }));
  const resumed = BridgeIdentity.open(dir, { ...quiet, env: {} });
  assert.notEqual(resumed.relayId, first.relayId);
  assert.equal(resumed.devices.lastReset?.reason, "user_reset");
  assert.equal(fs.existsSync(path.join(dir, "reset-pending")), false);

  // 移行の途中で落ちた（auth-v3.json が書かれていない）ときも、移行をやり直して印を書く
  const dir2 = tmpDir();
  fs.writeFileSync(path.join(dir2, "reset-pending"), JSON.stringify({ reason: "migration_v3", at: 1 }));
  BridgeIdentity.open(dir2, { ...quiet, env: {} });
  assert.ok(fs.existsSync(path.join(dir2, "auth-v3.json")));
});

test("BUDDYOS_BRIDGE_API_KEY を設定しているとローカル鍵は作り直せない（警告だけ）", () => {
  const dir = tmpDir();
  const identity = BridgeIdentity.open(dir, { ...quiet, env: { BUDDYOS_BRIDGE_API_KEY: "fixed-key" } });
  assert.equal(identity.localKeyFixed, true);
  identity.resetIdentity("user_reset");
  assert.equal(identity.localKey(), "fixed-key");
});

test("Roaming からの移行: bridge-id だけを移し、鍵は消し、鍵でない状態は新しい置き場所に無いときだけ写す", () => {
  const legacy = tmpDir();
  const dir = path.join(tmpDir(), "Local", "BuddyOS", "Bridge");
  v2Layout(legacy, tmpDir());
  fs.writeFileSync(path.join(legacy, "sessions.json"), '{"s":1}');
  fs.mkdirSync(path.join(legacy, "cron"));
  fs.writeFileSync(path.join(legacy, "cron", "jobs.json"), "[]");
  migrateLegacyDir(legacy, dir, () => {});
  assert.equal(read(dir, "bridge-id"), "windows-bridge-keep");
  assert.equal(fs.existsSync(path.join(legacy, "bridge-id")), false);
  for (const secret of ["e2e-key", "api-key", "paseo-relay-id", "e2e-devices.json"]) {
    assert.equal(fs.existsSync(path.join(legacy, secret)), false, secret);
    assert.equal(fs.existsSync(path.join(dir, secret)), false, `${secret} は写さない`);
  }
  assert.equal(read(dir, "sessions.json"), '{"s":1}');
  assert.equal(read(path.join(dir, "cron"), "jobs.json"), "[]");
});
