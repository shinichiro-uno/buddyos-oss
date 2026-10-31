import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { acquireInstanceLock, lockPath } from "./instanceLock.js";

const tmpConfig = () => fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-lock-"));
const closed = () => new Promise((r) => setTimeout(r, 50));

test("2 つ目は鍵が取れず、1 つ目が手放すと取れる", async () => {
  const dir = tmpConfig();
  const first = await acquireInstanceLock(dir);
  assert.ok(first);
  assert.equal(await acquireInstanceLock(dir), null);
  first.release();
  await closed();
  const again = await acquireInstanceLock(dir);
  assert.ok(again);
  again.release();
});

test("設定フォルダが違えば別の鍵", async () => {
  const a = await acquireInstanceLock(tmpConfig());
  const b = await acquireInstanceLock(tmpConfig());
  assert.ok(a);
  assert.ok(b);
  a.release();
  b.release();
});

test("落ちた Bridge のソケットファイルが残っていても取れる", { skip: process.platform === "win32" }, async () => {
  const dir = tmpConfig();
  fs.writeFileSync(lockPath(dir), "");
  const lock = await acquireInstanceLock(dir);
  assert.ok(lock);
  lock.release();
});
