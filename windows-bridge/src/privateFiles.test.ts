import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { ensurePrivateDir } from "./config.js";
import { lockPath } from "./instanceLock.js";
import { JsonSessionStore } from "./sessionStore.js";

// Linux / WSL で、設定フォルダ・会話の履歴・インスタンスの鍵を他のユーザーから見えない・取られない場所に置く。
const posix = process.platform !== "win32";
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-private-"));

test("設定フォルダは 0700 で作り、以前の 0755 も絞り直す", { skip: !posix }, () => {
  const fresh = path.join(tmp(), "cfg");
  ensurePrivateDir(fresh);
  assert.equal(fs.statSync(fresh).mode & 0o777, 0o700);
  const old = tmp();
  fs.chmodSync(old, 0o755);
  ensurePrivateDir(old);
  assert.equal(fs.statSync(old).mode & 0o777, 0o700);
});

test("会話の履歴は 0600 で書く", { skip: !posix }, () => {
  const dir = path.join(tmp(), "cfg");
  const store = new JsonSessionStore(dir);
  store.ensureSession("echo", "s1", undefined);
  store.appendMessage("echo", "s1", "user", "秘密の話", undefined, "m1");
  assert.equal(fs.statSync(path.join(dir, "sessions.json")).mode & 0o777, 0o600);
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
});

test("Unix の鍵（ソケット）は /tmp ではなく設定フォルダの中に置く", { skip: !posix }, () => {
  const dir = tmp();
  assert.equal(lockPath(dir), path.join(path.resolve(dir), "bridge.lock"));
  // パスが長すぎて Unix ソケットにできないときだけ一時フォルダ
  const long = path.join(dir, "x".repeat(120));
  assert.equal(path.dirname(lockPath(long)), os.tmpdir());
});
