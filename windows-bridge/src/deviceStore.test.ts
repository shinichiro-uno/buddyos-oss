import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

import { DeviceStore, MAX_DEVICES, NEVER_SEEN_TTL_MS, REVOKED_MARK_MS, type DeviceRow } from "./deviceStore.js";
import { credentialHash, deviceKeyId, newCredential } from "./tunnelV3.js";

// devices.json（spec/PROTOCOL-v3.md §14・§12）。

const tmpDir = () => fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-devices-"));
const quiet = { log: () => {} };

function newDevice(clientDeviceId = "device-test-1", name = "iPhone"): { id: string; row: DeviceRow; credential: string } {
  const pub = crypto.randomBytes(32);
  const credential = newCredential();
  return {
    id: deviceKeyId(pub),
    credential,
    row: {
      pub: pub.toString("base64url"),
      clientDeviceId,
      name,
      label: null,
      platform: "ios",
      credHash: credentialHash(credential),
      via: "qr",
      createdAt: Date.now()
    }
  };
}

function addConfirmed(store: DeviceStore, d = newDevice()): ReturnType<typeof newDevice> {
  store.putPending(d.id, d.row);
  assert.equal(store.confirm(d.id, d.row.credHash), true);
  return d;
}

test("追加・確定・照合: pendingAck の行はファイルに書かず照合も通さない。確定後は bdc_ だけが通る", () => {
  const dir = tmpDir();
  const store = DeviceStore.createFresh(dir, "migration_v3", quiet);
  const d = newDevice();
  store.putPending(d.id, d.row);
  assert.equal(store.verify(d.id, d.credential), false);
  assert.ok(!fs.readFileSync(store.file, "utf8").includes(d.id));
  assert.equal(store.confirm(d.id, d.row.credHash), true);
  assert.equal(store.verify(d.id, d.credential), true);
  assert.equal(store.verify(d.id, newCredential()), false);
  assert.equal(store.verify(d.id, d.credential.slice(4)), false);
  const onDisk = JSON.parse(fs.readFileSync(store.file, "utf8"));
  assert.equal(onDisk.v, 3);
  assert.equal(onDisk.epoch, 1);
  assert.equal(onDisk.lastReset.reason, "migration_v3");
  assert.equal(onDisk.devices[d.id].credHash, d.row.credHash);
  assert.equal(fs.readFileSync(store.backup, "utf8"), fs.readFileSync(store.file, "utf8"));
  if (process.platform !== "win32") assert.equal(fs.statSync(store.file).mode & 0o777, 0o600);
});

test("外す: 外した印が 90 日残り、QR でのペアリングで消える。解除（unpair）は印を残さない", () => {
  let now = 1_800_000_000_000;
  const store = DeviceStore.createFresh(tmpDir(), "migration_v3", { ...quiet, now: () => now });
  const d = addConfirmed(store);
  assert.equal(store.revoke(d.id), true);
  assert.equal(store.isRevoked(d.id), true);
  assert.equal(store.get(d.id), undefined);
  now += REVOKED_MARK_MS + 1;
  assert.equal(store.isRevoked(d.id), false);
  now -= REVOKED_MARK_MS;
  store.putPending(d.id, d.row);
  assert.equal(store.isRevoked(d.id), false);
  store.confirm(d.id, d.row.credHash);
  assert.equal(store.markUnpairing(d.id), true);
  assert.equal(store.verify(d.id, d.credential), false);
  store.removeUnpairing(d.id);
  assert.equal(store.get(d.id), undefined);
  assert.equal(store.isRevoked(d.id), false);
});

test("PROTOCOL-v3 §18.2: 同じトークンが別の端末の行にあり clientDeviceId が違えば、どちらの行も変わらない", () => {
  const store = DeviceStore.createFresh(tmpDir(), "migration_v3", quiet);
  const a = addConfirmed(store, newDevice("device-a-0001"));
  const b = addConfirmed(store, newDevice("device-b-0002"));
  const token = "AB".repeat(32);
  assert.equal(store.setPush(a.id, token, "production", "en"), "ok");
  assert.deepEqual(store.get(a.id)?.push, { token: token.toLowerCase(), env: "production", locale: "en" });
  assert.equal(store.setPush(a.id, token, "production", "en"), "unchanged");
  assert.equal(store.setPush(b.id, token, "development", "ja"), "conflict");
  assert.equal(store.get(b.id)?.push, undefined);
  assert.equal(store.get(a.id)?.push?.token, token.toLowerCase());
  assert.equal(store.setPush(b.id, "xyz", undefined, undefined), "invalid");
  // 同じ clientDeviceId（入れ直した端末）なら移る
  const a2 = addConfirmed(store, newDevice("device-a-0001"));
  assert.equal(store.setPush(a2.id, token, undefined, undefined), "ok");
  assert.equal(store.get(a.id)?.push, undefined);
  assert.deepEqual(store.get(a2.id)?.push, { token: token.toLowerCase(), env: "development", locale: "ja" });
  store.removePushToken(token);
  assert.equal(store.pushTargets().length, 0);
});

test("lastSeenAt は行があるときだけ。一度もつながらない行は 24 時間で消える。20 台まで", () => {
  let now = 1_800_000_000_000;
  const store = DeviceStore.createFresh(tmpDir(), "migration_v3", { ...quiet, now: () => now });
  const seen = addConfirmed(store);
  const never = addConfirmed(store, newDevice("device-never-1"));
  store.touch(seen.id);
  assert.equal(store.get(seen.id)?.lastSeenAt, now);
  store.revoke(seen.id);
  store.touch(seen.id);
  assert.equal(store.get(seen.id), undefined, "消えた行を生き返らせない");
  now += NEVER_SEEN_TTL_MS;
  store.purge();
  assert.equal(store.get(never.id), undefined);

  for (let i = 0; i < MAX_DEVICES; i++) addConfirmed(store, newDevice(`device-many-${i}`));
  const extra = newDevice("device-extra-1");
  assert.equal(store.wouldExceedLimit(extra.id), true);
  assert.equal(store.wouldExceedLimit(store.confirmedIds()[0]), false);
});

test("devices.json が読めなければ .bak から戻し、どちらも読めなければ上書きせず壊れた状態にする。リセットで退避して作り直す", () => {
  const dir = tmpDir();
  const first = DeviceStore.createFresh(dir, "migration_v3", quiet);
  const d = addConfirmed(first);

  fs.writeFileSync(first.file, "{broken");
  const restored = DeviceStore.open(dir, quiet);
  assert.equal(restored.broken, false);
  assert.ok(restored.get(d.id));
  assert.equal(restored.lastReset?.reason, "devices_restored");
  assert.ok(JSON.parse(fs.readFileSync(first.file, "utf8")).devices[d.id]);

  fs.writeFileSync(first.file, "{broken");
  fs.writeFileSync(first.backup, "{broken too");
  const broken = DeviceStore.open(dir, quiet);
  assert.equal(broken.broken, true);
  assert.equal(fs.readFileSync(first.file, "utf8"), "{broken");
  broken.resetAll("user_reset");
  assert.equal(broken.broken, false);
  assert.ok(fs.readdirSync(dir).some((f) => f.startsWith("devices.json.broken-")));
  assert.equal(JSON.parse(fs.readFileSync(first.file, "utf8")).lastReset.reason, "user_reset");

  const empty = tmpDir();
  const missing = DeviceStore.open(empty, quiet);
  assert.equal(missing.lastReset?.reason, "devices_missing");
  assert.ok(fs.existsSync(path.join(empty, "devices.json")));
});

test("resetAll は端末を空にして epoch を 1 増やす。version と待ち合わせ", async () => {
  const store = DeviceStore.createFresh(tmpDir(), "migration_v3", quiet);
  addConfirmed(store);
  const version = store.version;
  const waiting = store.waitForChange(version, store.bootId, 5_000);
  store.resetAll("user_reset");
  await waiting;
  assert.equal(store.epoch, 2);
  assert.equal(store.confirmedIds().length, 0);
  assert.ok(store.version > version);
  // since か boot が違えばすぐ返る
  await store.waitForChange(0, "other-boot", 5_000);
  const started = Date.now();
  // waitForChange のタイマーは unref なので、待つ間だけイベントループを生かしておく（Node 22 はここで打ち切る）。
  const keepAlive = setTimeout(() => {}, 1_000);
  await store.waitForChange(store.version, store.bootId, 50);
  clearTimeout(keepAlive);
  assert.ok(Date.now() - started >= 40);
});

test("DevicesView の端末: 表示名・同じ名前の数・ラベル", () => {
  const store = DeviceStore.createFresh(tmpDir(), "migration_v3", quiet);
  const a = addConfirmed(store, newDevice("device-a-0001", "iPhone"));
  addConfirmed(store, newDevice("device-b-0002", "iPhone"));
  const views = store.deviceViews(() => false);
  assert.equal(views.length, 2);
  assert.equal(views[0].display, `iPhone · ${a.id.slice(0, 4)}`);
  assert.equal(views[0].sameNameCount, 2);
  assert.equal(store.rename(a.id, "仕事用"), `仕事用 · ${a.id.slice(0, 4)}`);
  assert.equal(store.deviceViews(() => true)[0].sameNameCount, 1);
  assert.equal(store.deviceViews(() => true)[0].online, true);
  // ラベルは数えない（ラベルの無い端末どうしの同じ name だけ。Mac と同じ）。
  assert.ok(store.rename(a.id, "iPhone"));
  assert.deepEqual(store.deviceViews(() => false).map((v) => v.sameNameCount), [1, 1]);
});

// ---- スマホで許可する（spec/PROTOCOL-v3.md §10.4.1） ----

test("devices.json: mac と同じ形。approvedBy・remoteApprovalsEnabled は任意（古いファイルも読め、無ければ有効・書かない）", () => {
  const dir = tmpDir();
  const phone = newDevice("device-phone-1", "iPhone");
  const mac = newDevice("device-mac-0001", "MacBook Air");
  mac.row.platform = "mac";
  mac.row.via = "approval";
  // mac の DeviceStore が書いた形（approvedBy と settings.remoteApprovalsEnabled 入り）
  const macFile = {
    v: 3,
    epoch: 4,
    settings: { approvalsEnabled: true, remoteApprovalsEnabled: false },
    devices: { [phone.id]: phone.row, [mac.id]: { ...mac.row, approvedBy: phone.id } },
    revoked: {}
  };
  fs.writeFileSync(path.join(dir, "devices.json"), JSON.stringify(macFile));
  const store = DeviceStore.open(dir, quiet);
  assert.equal(store.broken, false);
  assert.equal(store.get(mac.id)?.approvedBy, phone.id);
  assert.equal(store.get(phone.id)?.approvedBy, undefined);
  assert.equal(store.remoteApprovalsEnabled, false);
  store.rename(phone.id, "仕事用");
  const written = JSON.parse(fs.readFileSync(store.file, "utf8"));
  assert.deepEqual(written.settings, { approvalsEnabled: true, remoteApprovalsEnabled: false });
  assert.equal(written.devices[mac.id].approvedBy, phone.id);
  assert.ok(!("approvedBy" in written.devices[phone.id]), "無いときはキーごと書かない（mac の String? と同じ）");

  // 古いファイル（どちらも無い）: 読めて、スマホからの許可は有効。書き直しても settings に足さない
  const oldDir = tmpDir();
  fs.writeFileSync(
    path.join(oldDir, "devices.json"),
    JSON.stringify({ v: 3, epoch: 1, settings: { approvalsEnabled: true }, devices: { [phone.id]: phone.row }, revoked: {} })
  );
  const old = DeviceStore.open(oldDir, quiet);
  assert.equal(old.remoteApprovalsEnabled, true);
  old.rename(phone.id, null);
  assert.deepEqual(JSON.parse(fs.readFileSync(old.file, "utf8")).settings, { approvalsEnabled: true });
  old.setRemoteApprovalsEnabled(false);
  assert.deepEqual(JSON.parse(fs.readFileSync(old.file, "utf8")).settings, { approvalsEnabled: true, remoteApprovalsEnabled: false });

  // approvedBy が文字列でなければ、その行（ファイル全体）を読めないものとして扱う。null は無いのと同じ
  const badDir = tmpDir();
  fs.writeFileSync(path.join(badDir, "devices.json"), JSON.stringify({ ...macFile, devices: { [mac.id]: { ...mac.row, approvedBy: 5 } } }));
  assert.equal(DeviceStore.open(badDir, quiet).broken, true);
  const nullDir = tmpDir();
  fs.writeFileSync(path.join(nullDir, "devices.json"), JSON.stringify({ ...macFile, devices: { [mac.id]: { ...mac.row, approvedBy: null } } }));
  assert.equal(DeviceStore.open(nullDir, quiet).get(mac.id)?.approvedBy, undefined);
});

test("許可できる端末: 確定済みの ios・android だけ。スマホでの許可は設定が有効で、許可できる端末に宛先があるときだけ使える", () => {
  const store = DeviceStore.createFresh(tmpDir(), "migration_v3", quiet);
  assert.equal(store.remoteApprovalsAvailable, false);
  const iphone = addConfirmed(store, newDevice("device-phone-1"));
  const android = newDevice("device-android-1");
  android.row.platform = "android";
  addConfirmed(store, android);
  const pc = newDevice("device-pc-00001");
  pc.row.platform = "windows";
  addConfirmed(store, pc);
  const pending = newDevice("device-pend-001");
  store.putPending(pending.id, pending.row);
  assert.equal(store.isApprover(iphone.id), true);
  assert.equal(store.isApprover(android.id), true);
  assert.equal(store.isApprover(pc.id), false, "別の PC は許可できない");
  assert.equal(store.isApprover(pending.id), false, "pendingAck の行は許可できない");
  assert.equal(store.isApprover("nobody"), false);

  // 宛先が PC にだけあっても使えない
  assert.equal(store.setPush(pc.id, "aa".repeat(32), "production", "ja"), "ok");
  assert.equal(store.remoteApprovalsAvailable, false);
  assert.equal(store.setPush(android.id, "bb".repeat(32), "production", "en"), "ok");
  assert.equal(store.remoteApprovalsAvailable, true);
  assert.deepEqual(store.approverPushTargets().map((t) => t.deviceKeyId), [android.id]);
  store.setRemoteApprovalsEnabled(false);
  assert.equal(store.remoteApprovalsAvailable, false);
  // 作り直しでも設定は引き継ぐ
  store.resetAll("user_reset");
  assert.equal(store.remoteApprovalsEnabled, false);
});

test("insertPending: epoch が変わった・20 台を超えるなら入れない。approval では外した印を消さない。deviceViews の approvedBy は表示名", () => {
  const store = DeviceStore.createFresh(tmpDir(), "migration_v3", quiet);
  const phone = addConfirmed(store, newDevice("device-phone-1", "iPhone"));
  const added = newDevice("device-mac-0001", "MacBook Air");
  added.row.via = "approval";
  added.row.approvedBy = phone.id;
  assert.equal(store.insertPending(added.id, added.row, store.epoch + 1), false);
  assert.equal(store.revoke(added.id), false);
  assert.equal(store.insertPending(added.id, added.row, store.epoch), true);
  assert.equal(store.confirm(added.id, added.row.credHash), true);
  const view = () => store.deviceViews(() => false).find((v) => v.deviceKeyId === added.id)!;
  assert.equal(view().approvedBy, `iPhone · ${phone.id.slice(0, 4)}`);
  assert.equal(store.deviceViews(() => false).find((v) => v.deviceKeyId === phone.id)!.approvedBy, null);
  store.rename(phone.id, "私の iPhone");
  assert.equal(view().approvedBy, `私の iPhone · ${phone.id.slice(0, 4)}`);
  // 許可したスマホを外しても、足した端末は残る。approvedBy は deviceKeyId の先頭 4 文字
  store.revoke(phone.id);
  assert.equal(view().approvedBy, phone.id.slice(0, 4));

  // 外した端末を approval で入れ直しても、外した印は残る（QR のときだけ消す）
  const again = newDevice("device-mac-0001", "MacBook Air");
  again.row.via = "approval";
  assert.equal(store.insertPending(phone.id, again.row, store.epoch), true);
  assert.equal(store.isRevoked(phone.id), true);

  const full = DeviceStore.createFresh(tmpDir(), "migration_v3", quiet);
  for (let i = 0; i < MAX_DEVICES; i++) addConfirmed(full, newDevice(`device-full-${String(i).padStart(3, "0")}`));
  const extra = newDevice("device-extra-01");
  extra.row.via = "approval";
  assert.equal(full.insertPending(extra.id, extra.row, full.epoch), false);
  assert.equal(store.sameNameCount("MacBook Air"), 2, "ラベルの無い同じ name の行（pendingAck も数える。mac と同じ）");
});
