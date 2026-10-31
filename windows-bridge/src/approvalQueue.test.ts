import assert from "node:assert/strict";
import { test } from "node:test";

import {
  APPROVAL_WINDOW_MS,
  ApprovalQueue,
  GLOBAL_PER_HOUR,
  PENDING_LIFETIME_MS,
  REJECTED_MS,
  REMOTE_GLOBAL_PER_HOUR,
  type AddInput,
  type EndReason
} from "./approvalQueue.js";

// 承認待ち（mac の ApprovalQueue.swift と同じ規則。spec/PROTOCOL-v3.md §10・Appendix A）と、
// スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）の remote の申し込み。時計は差し替える。

function rig() {
  let t = 1_800_000_000_000;
  const q = new ApprovalQueue({ now: () => t });
  const ended = new Map<string, EndReason>();
  const approvedBy = new Map<string, string | undefined>();
  let changes = 0;
  q.onChange = () => (changes += 1);
  const add = (deviceKeyId: string, code: string, remote = false, extra: Partial<AddInput> = {}) =>
    q.add({
      deviceKeyId,
      display: `Mac · ${deviceKeyId.slice(0, 4)}`,
      name: "Mac",
      platform: "mac",
      sameNameExists: false,
      remote,
      code,
      approve: async (by) => {
        approvedBy.set(deviceKeyId, by);
        return { kind: "ok", display: `Mac · ${deviceKeyId.slice(0, 4)}` };
      },
      end: (reason) => ended.set(deviceKeyId, reason),
      ...extra
    });
  return {
    q,
    add,
    ended,
    approvedBy,
    changes: () => changes,
    advance: (ms: number) => (t += ms)
  };
}

test("admit: アカウントで見つけた PC からの承認が切れている・窓が閉じていてスマホでの許可も使えないなら approval_unavailable。開いていれば window、閉じていて使えれば remote", () => {
  const { q } = rig();
  assert.deepEqual(q.admit("dev-a", false, true), { kind: "refused", error: "approval_unavailable" });
  assert.deepEqual(q.admit("dev-a", true, false), { kind: "refused", error: "approval_unavailable" });
  assert.deepEqual(q.admit("dev-a", true, true), { kind: "remote" });
  q.openWindow();
  assert.deepEqual(q.admit("dev-a", true, false), { kind: "window" });
  assert.deepEqual(q.admit("dev-a", false, true), { kind: "refused", error: "approval_unavailable" });
});

test("窓: 10 分で閉じ、開き直すと今から 10 分に延びる", () => {
  const r = rig();
  const until = r.q.openWindow();
  assert.equal(r.q.windowOpenUntil, until);
  r.advance(APPROVAL_WINDOW_MS - 1000);
  const extended = r.q.openWindow();
  assert.equal(extended, until + APPROVAL_WINDOW_MS - 1000);
  r.advance(APPROVAL_WINDOW_MS);
  assert.equal(r.q.windowOpenUntil, undefined);
  // 窓が閉じていれば、窓の申し込みは作れない（remote なら作れる）
  assert.equal(r.add("dev-a", "111111"), undefined);
  assert.ok(r.add("dev-a", "111111", true));
});

test("上限: 同時 3 件・1 台 1 件で busy。1 台 1 時間 3 回・全体 20 回・remote は全体 6 回で rate_limited（1 時間で戻る）", () => {
  const r = rig();
  r.q.openWindow();
  assert.ok(r.add("dev-a", "111111"));
  assert.deepEqual(r.q.admit("dev-a", true, true), { kind: "refused", error: "busy" });
  assert.equal(r.add("dev-a", "222222"), undefined);
  assert.ok(r.add("dev-b", "222222"));
  assert.ok(r.add("dev-c", "333333"));
  assert.deepEqual(r.q.admit("dev-d", true, true), { kind: "refused", error: "busy" });
  assert.equal(r.add("dev-d", "444444"), undefined);

  const s = rig();
  s.q.openWindow();
  for (let i = 0; i < 3; i++) assert.equal(s.q.countAttempt("dev-a"), true);
  assert.equal(s.q.countAttempt("dev-a"), false);
  assert.deepEqual(s.q.admit("dev-a", true, true), { kind: "refused", error: "rate_limited" });
  for (let i = 0; i < GLOBAL_PER_HOUR - 3; i++) assert.equal(s.q.countAttempt(`dev-${i}`), true);
  assert.equal(s.q.countAttempt("dev-new"), false);
  assert.deepEqual(s.q.admit("dev-new", true, true), { kind: "refused", error: "rate_limited" });
  s.advance(60 * 60 * 1000);
  assert.equal(s.q.countAttempt("dev-a"), true);

  // remote: 全体で 1 時間 6 件。窓の申し込みは remote の数に入らず、remote の上限に当たっても窓なら通る。
  const m = rig();
  for (let i = 0; i < REMOTE_GLOBAL_PER_HOUR; i++) {
    assert.equal(m.q.wouldBeRemote(), true);
    assert.equal(m.q.countAttempt(`dev-${i}`, true), true);
  }
  assert.equal(m.q.countAttempt("dev-x", true), false);
  assert.deepEqual(m.q.admit("dev-x", true, true), { kind: "refused", error: "rate_limited" });
  m.q.openWindow();
  assert.equal(m.q.wouldBeRemote(), false);
  assert.deepEqual(m.q.admit("dev-x", true, true), { kind: "window" });
  assert.equal(m.q.countAttempt("dev-x", false), true);
});

test("拒否: その鍵を 24 時間 rate_limited。取り下げの理由は rejected", () => {
  const r = rig();
  r.q.openWindow();
  const p = r.add("dev-a", "111111")!;
  assert.equal(r.q.reject(p.pendingId), true);
  assert.equal(r.ended.get("dev-a"), "rejected");
  assert.equal(r.q.reject(p.pendingId), false);
  assert.equal(r.q.isRejected("dev-a"), true);
  assert.deepEqual(r.q.admit("dev-a", true, true), { kind: "refused", error: "rate_limited" });
  r.advance(REJECTED_MS);
  assert.equal(r.q.isRejected("dev-a"), false);
});

test("submit: 番号は空白・ハイフンを無視して全件と比べ、合ったものだけを許可する。approvedBy をそのまま渡す。一覧に番号は無い", async () => {
  const r = rig();
  r.q.openWindow();
  r.add("dev-a", "111111");
  r.add("dev-b", "222222", true);
  assert.ok(!JSON.stringify(r.q.views()).includes("111111"));
  assert.deepEqual(await r.q.submit("12345"), { kind: "bad_code" });
  assert.deepEqual(await r.q.submit("２２２２２２"), { kind: "bad_code" });
  assert.deepEqual(await r.q.submit("222-222", "phone-1"), { kind: "ok", deviceKeyId: "dev-b", display: "Mac · dev-" });
  assert.equal(r.approvedBy.get("dev-b"), "phone-1");
  assert.deepEqual(await r.q.submit("111 111"), { kind: "ok", deviceKeyId: "dev-a", display: "Mac · dev-" });
  assert.equal(r.approvedBy.get("dev-a"), undefined);
  assert.deepEqual(await r.q.submit("111111"), { kind: "no_pending" });

  // トンネルが送れなかった（端末が切れていた）なら device_gone
  r.add("dev-c", "333333", false, { approve: async () => ({ kind: "device_gone" }) });
  assert.deepEqual(await r.q.submit("333333"), { kind: "device_gone" });
});

test("間違い: 窓が開いている間は窓ごとに 3 回。3 回目で全部 code_mismatch で取り下げて窓も閉じる（remote も含む）", async () => {
  const r = rig();
  r.q.openWindow();
  r.add("dev-a", "111111");
  r.add("dev-b", "222222", true);
  assert.deepEqual(await r.q.submit("999999"), { kind: "mismatch", remaining: 2 });
  assert.deepEqual(await r.q.submit("999999", "phone-1"), { kind: "mismatch", remaining: 1 }, "PC とスマホは同じ数");
  assert.deepEqual(await r.q.submit("999999"), { kind: "mismatch", remaining: 0 });
  assert.equal(r.ended.get("dev-a"), "code_mismatch");
  assert.equal(r.ended.get("dev-b"), "code_mismatch");
  assert.equal(r.q.windowOpenUntil, undefined);
  assert.equal(r.q.views().length, 0);
});

test("間違い: 窓が閉じているときは、承認待ちが 0 件になったら数を 0 に戻す", async () => {
  const r = rig();
  const a = r.add("dev-a", "111111", true)!;
  assert.deepEqual(await r.q.submit("999999"), { kind: "mismatch", remaining: 2 });
  assert.deepEqual(await r.q.submit("999999"), { kind: "mismatch", remaining: 1 });
  r.q.remove(a.pendingId);
  r.add("dev-b", "222222", true);
  assert.deepEqual(await r.q.submit("999999"), { kind: "mismatch", remaining: 2 }, "0 件になったので数え直し");
  // 窓を開くと窓ごとに数え直す。窓を閉じても remote が残っていれば、その窓での数は残る
  r.q.openWindow();
  r.add("dev-c", "333333");
  assert.deepEqual(await r.q.submit("999999"), { kind: "mismatch", remaining: 2 });
  r.q.closeWindow();
  assert.equal(r.ended.get("dev-c"), "closed");
  assert.deepEqual(await r.q.submit("999999"), { kind: "mismatch", remaining: 1 });
});

test("closeWindow は窓の申し込みだけ、closeRemote は remote だけを closed で取り下げる。resetAll は全部 reset", () => {
  const r = rig();
  r.q.openWindow();
  r.add("dev-a", "111111");
  r.add("dev-b", "222222", true);
  r.q.closeWindow("closed");
  assert.equal(r.ended.get("dev-a"), "closed");
  assert.equal(r.ended.has("dev-b"), false);
  assert.deepEqual(r.q.views().map((v) => [v.deviceKeyId, v.remote]), [["dev-b", true]]);
  r.q.closeRemote("closed");
  assert.equal(r.ended.get("dev-b"), "closed");
  assert.equal(r.q.views().length, 0);

  r.q.openWindow();
  r.add("dev-c", "333333");
  r.add("dev-d", "444444", true);
  r.q.resetAll();
  assert.equal(r.ended.get("dev-c"), "reset");
  assert.equal(r.ended.get("dev-d"), "reset");
});

test("expire: 5 分たった承認待ちは timeout で取り下げ、一覧からも消える。onRemoteAdded は remote のときだけ 1 回", () => {
  const r = rig();
  const remoteAdded: string[] = [];
  r.q.onRemoteAdded = (p) => remoteAdded.push(p.pendingId);
  r.q.openWindow();
  r.add("dev-a", "111111");
  const b = r.add("dev-b", "222222", true)!;
  assert.deepEqual(remoteAdded, [b.pendingId]);
  assert.equal(b.expiresAt - b.requestedAt, PENDING_LIFETIME_MS);
  assert.match(b.pendingId, /^p_[A-Za-z0-9_-]{12}$/);
  r.advance(PENDING_LIFETIME_MS);
  assert.equal(r.q.views().length, 0);
  r.q.expire();
  assert.equal(r.ended.get("dev-a"), "timeout");
  assert.equal(r.ended.get("dev-b"), "timeout");
  assert.ok(r.changes() > 0);
});
