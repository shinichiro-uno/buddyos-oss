import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { HistoryReadFeed } from "../agents/claudeCode.js";
import type { SessionEvent } from "../protocol.js";
import type { BgEntry, BgState } from "./claudeAgentsRegistry.js";
import { BG_INTERRUPT_TEXT } from "./claudeAgentsRegistry.js";
import { bgSessionTiming, ClaudeBackgroundSession, findHolder, type BgHolder, type BgSessionHost } from "./claudeBackgroundSession.js";

/// claude --bg のワーカーの会話（BACKGROUND_CONTROL §7.8、Windows は §7.10）。transcript を追って受け箱で送る。

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-bgsession-"));
after(() => {
  try {
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  } catch {
    /* 掃除できなくても落とさない */
  }
});

bgSessionTiming.fastMs = 15;
bgSessionTiming.slowMs = 15;
bgSessionTiming.historyWaitMs = 80;
bgSessionTiming.ackMs = 120;

const SID = "66666666-6666-4666-8666-666666666666";
const JOB = "a1b2c3d4";
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

let seq = 0;

class FakeHost implements BgSessionHost {
  readonly homeDir: string;
  entry?: BgEntry;
  listeners = new Set<(entry: BgEntry | undefined) => void>();
  refreshes = 0;
  constructor() {
    this.homeDir = path.join(tmp, `home${seq++}`);
    fs.mkdirSync(path.join(this.homeDir, ".claude", "projects", "p"), { recursive: true });
  }
  get transcript(): string {
    return path.join(this.homeDir, ".claude", "projects", "p", `${SID}.jsonl`);
  }
  entryFor(sessionId: string): BgEntry | undefined {
    return sessionId === SID ? this.entry : undefined;
  }
  watchEntry(_sessionId: string, listener: (entry: BgEntry | undefined) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
  async refresh(): Promise<void> {
    this.refreshes++;
  }
  /** ジョブの様子を変えて、読み取りがあったことにする。 */
  set(patch: { status?: string; live?: boolean; state?: BgState; inbox?: string | null }): void {
    const base = this.entry;
    const live = patch.live ?? base?.row.live ?? true;
    this.entry = makeEntry(this, {
      status: "status" in patch ? patch.status : base?.workerStatus,
      live,
      state: patch.state ?? base?.row.state ?? "working",
      inbox: patch.inbox === null ? undefined : (patch.inbox ?? base?.inbox)
    });
    for (const l of [...this.listeners]) l(this.entry);
  }
  write(...rows: unknown[]): void {
    fs.appendFileSync(this.transcript, rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
  }
}

function makeEntry(host: FakeHost, o: { status?: string; live: boolean; state: BgState; inbox?: string }): BgEntry {
  return {
    row: { id: JOB, sessionId: SID, title: "t", cwd: "C:\\w", state: o.state, live: o.live, shells: 0, createdAtMs: 1 },
    recurringWait: false,
    workerStatus: o.live ? o.status : undefined,
    inbox: o.live ? o.inbox : undefined,
    firstTerminal: false,
    linkScanPath: host.transcript
  };
}

interface Harness {
  host: FakeHost;
  session: ClaudeBackgroundSession;
  events: SessionEvent[];
  posts: { socket: string; text: string }[];
  emitted: SessionEvent[];
  emit: (e: SessionEvent) => void;
}

function harness(
  init: { status?: string; live?: boolean; state?: BgState; inbox?: string; mode?: "worker" | "elsewhere"; holder?: BgHolder; history?: HistoryReadFeed; fail?: string; existing?: boolean } = {}
): Harness {
  const host = new FakeHost();
  if (init.existing !== false) fs.writeFileSync(host.transcript, "");
  host.entry = makeEntry(host, { status: init.status ?? "idle", live: init.live ?? true, state: init.state ?? "working", inbox: init.inbox ?? "\\\\.\\pipe\\cc-1" });
  const events: SessionEvent[] = [];
  const posts: Harness["posts"] = [];
  const session = new ClaudeBackgroundSession(SID, {
    mode: init.mode ?? "worker",
    host,
    publish: (e) => events.push(e),
    history: init.history,
    holder: init.holder,
    post: async (socket, text) => {
      if (init.fail) throw new Error(init.fail);
      posts.push({ socket, text });
    }
  });
  const emitted: SessionEvent[] = [];
  return { host, session, events, posts, emitted, emit: (e) => emitted.push(e) };
}

async function until(pred: () => boolean, ms = 3000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!pred()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await sleep(5);
  }
}

const types = (events: SessionEvent[]): string[] => events.map((e) => e.type);
const msg = (content: string): SessionEvent => ({ type: "user_message", agentId: "claude", content });
const assistant = (id: string, ...blocks: unknown[]): Record<string, unknown> => ({ type: "assistant", message: { id, role: "assistant", content: blocks }, uuid: `u-${id}` });
const text = (t: string): unknown => ({ type: "text", text: t });

test("transcript の行: 本文・ツール・結果・PC で打った発話を流し、sidechain / meta などは捨てる", async () => {
  const h = harness({ status: "busy" });
  h.host.write(
    { type: "user", message: { role: "user", content: "<system-reminder>x</system-reminder>PC から\n<task-notification>n</task-notification>" } },
    assistant("m1", text("考えます"), { type: "tool_use", id: "tu1", name: "Bash", input: { command: "ls" } }),
    { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "tu1", content: "a".repeat(300) }] } },
    assistant("m1", { type: "tool_use", id: "tu2", name: "Edit", input: { file_path: "a.ts" } }),
    { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "tu2", content: [{ type: "text", text: "boom" }], is_error: true }] } },
    assistant("m2", text("終わり")),
    { ...assistant("side", text("子")), isSidechain: true },
    { ...assistant("meta", text("メタ")), isMeta: true },
    { type: "ai-title", aiTitle: "x" }
  );
  await until(() => h.events.some((e) => e.type === "assistant_delta" && e.content === "終わり"));
  // 作った時点のファイルの大きさから読むので、作った後に書いた行だけが流れる。
  const body = h.events.filter((e) => e.type !== "activity");
  assert.deepEqual(types(body), ["user_message", "assistant_delta", "tool_start", "tool_end", "tool_start", "tool_end", "assistant_delta"]);
  assert.equal(body[0].content, "PC から");
  const turn = h.events.find((e) => e.type === "activity")!.messageId;
  assert.equal(body[1].messageId, turn, "ターンの最初のメッセージはターンの messageId");
  assert.equal(body[6].messageId === turn, false, "message.id が変わると新しい吹き出し");
  assert.equal(body[2].content, "ls");
  assert.equal(body[3].metadata?.status, "completed");
  assert.equal(body[3].content?.length, 200, "summary は 200 字まで");
  assert.equal(body[5].metadata?.status, "failed");
  assert.equal(body[5].content, "boom");
  await h.session.close();
});

test("ターン: busy で activity を流して開き、idle / waiting / shell で最後まで読んでから done で閉じる", async () => {
  const h = harness({ status: "idle" });
  assert.deepEqual(types(h.events), []);
  h.host.set({ status: "busy" });
  assert.deepEqual(types(h.events), ["activity"]);
  assert.equal(h.events[0].content, "", "本文の無い activity");
  h.host.set({ status: "busy" });
  assert.equal(h.events.length, 1, "開いているターンは重ねて開かない");
  h.host.write(assistant("m1", text("途中")));
  h.host.set({ status: "shell" });
  assert.deepEqual(types(h.events), ["activity", "assistant_delta", "done"], "閉じる前に transcript を読み切る");
  assert.equal(h.events[2].messageId, h.events[0].messageId);
  assert.equal(h.events[2].metadata, undefined);
  h.host.set({ status: "busy" });
  h.host.set({ status: "waiting" });
  assert.equal(types(h.events).slice(-2).join(), "activity,done");
  await h.session.close();
});

test("作った時点で busy ならターンを開く", async () => {
  const h = harness({ status: "busy" });
  assert.deepEqual(types(h.events), ["activity"]);
  await h.session.close();
});

test("ワーカーが消えた: 失敗なら error の後に errored の done、ほかは普通の done", async () => {
  const failed = harness({ status: "busy" });
  failed.host.set({ live: false, state: "failed" });
  assert.deepEqual(types(failed.events), ["activity", "error", "done"]);
  assert.equal(failed.events[1].content, "PC のバックグラウンドのセッションが止まりました（失敗）");
  assert.equal(failed.events[2].metadata?.errored, "true");
  assert.equal(failed.session.isStillUsable(), false);
  await failed.session.close();
  const stopped = harness({ status: "busy" });
  stopped.host.set({ live: false, state: "stopped" });
  assert.deepEqual(types(stopped.events), ["activity", "done"]);
  assert.equal(stopped.events[1].metadata, undefined);
  await stopped.session.close();
});

test("履歴を待つ間にターンが閉じても、履歴より先の行は流さない（done は出す）", async () => {
  const feed = new Map<string, (read: { file?: string; end: number }) => void>();
  const history: HistoryReadFeed = {
    lastRead: () => undefined,
    onRead: (sid, listener) => {
      feed.set(sid, listener);
      return () => feed.delete(sid);
    }
  };
  const h = harness({ status: "busy", history });
  h.host.write(assistant("old", text("履歴にある")));
  const end = fs.statSync(h.host.transcript).size;
  h.host.set({ status: "idle" });
  assert.equal(h.events.some((e) => e.type === "assistant_delta"), false, "履歴の前に行を流さない");
  assert.equal(h.events.some((e) => e.type === "done"), true, "done は出す");
  feed.get(SID)!({ file: h.host.transcript, end });
  await sleep(60);
  assert.equal(h.events.some((e) => e.type === "assistant_delta"), false, "履歴に出した分は live に出さない");
  await h.session.close();
});

test("届いたと分かる前にワーカーが消えた発話は捨てて知らせ、読み取りを止める", async () => {
  const h = harness({ status: "idle" });
  await h.session.send("やって", msg("やって"), h.emit);
  h.events.length = 0;
  h.host.set({ live: false, state: "stopped" });
  assert.deepEqual(types(h.events), ["error", "done"]);
  // Mac の ClaudeBackgroundSession と同じ文（BACKGROUND_CONTROL §7.8）。
  assert.equal(h.events[0].content, "PC のバックグラウンドのセッションが、この発話を受け取る前に止まりました。");
  assert.equal(h.events[1].metadata?.errored, "true");
  assert.equal(h.events[1].metadata?.pending, undefined);
  // 以後、ackMs を過ぎても二重に知らせない（送った発話はもう残っていない）。
  h.events.length = 0;
  await sleep(200);
  assert.deepEqual(types(h.events), []);
  await h.session.close();
});

test("送信: 受け箱に書き、送った文を覚えてすぐ返る。peer 行が出たら表示済みとして捨て、ターンを開く", async () => {
  const h = harness({ status: "idle" });
  await h.session.send("やって", msg("やって"), h.emit);
  assert.deepEqual(h.posts, [{ socket: "\\\\.\\pipe\\cc-1", text: "やって" }]);
  assert.deepEqual(h.emitted, [], "成功では何も返さない");
  h.host.write(
    { type: "user", origin: { kind: "peer" }, message: { role: "user", content: "Another Claude session sent a message:\nやって\n\nThis came from another Claude session via x" } },
    { type: "user", origin: { kind: "peer" }, message: { role: "user", content: "Another Claude session sent a message:\nほかの人\n\nThis came from another Claude session via x" } }
  );
  await until(() => h.events.some((e) => e.type === "user_message"));
  assert.deepEqual(types(h.events), ["activity", "user_message"], "送った文は捨てて turn を開き、ほかの peer は枠を外して user_message");
  assert.equal(h.events[1].content, "ほかの人");
  h.host.write(assistant("m1", text("はい")));
  h.host.set({ status: "busy" });
  h.host.set({ status: "idle" });
  assert.equal(h.events.at(-1)?.type, "done");
  assert.equal(h.events.at(-1)?.metadata, undefined, "送った発話は全部届いたので pending は付かない");
  await h.session.close();
});

test("送信の断り: 止まった・承認待ち・受け箱なし・書けない", async () => {
  const dead = harness({ live: false, state: "stopped" });
  await dead.session.send("x", msg("x"), dead.emit);
  assert.equal(dead.emitted[0].content, "PC のバックグラウンドのセッションが止まりました。もう一度送ると、BuddyOS で続きから再開します。");
  assert.equal(dead.emitted[1].metadata?.errored, "true");
  assert.equal(dead.session.isStillUsable(), false, "使えない印");
  assert.equal(dead.posts.length, 0);

  const blocked = harness({ state: "blocked", status: "waiting" });
  await blocked.session.send("x", msg("x"), blocked.emit);
  assert.equal(blocked.emitted[0].content, `PC で承認を待っています。PC で \`claude attach ${JOB}\` を開いて答えてから、もう一度送ってください。`);
  assert.equal(blocked.emitted[1].type, "done");
  assert.equal(blocked.posts.length, 0);

  const failing = harness({ fail: "inbox connect timeout" });
  await failing.session.send("x", msg("x"), failing.emit);
  assert.equal(failing.emitted[0].content, "PC のバックグラウンドのセッションに届けられませんでした（inbox connect timeout）。");
  assert.equal(failing.emitted[1].metadata?.errored, "true");
  assert.equal(failing.session.isStillUsable(), true, "書けなかっただけでは使えなくしない");

  const noInbox = harness({ inbox: "" });
  noInbox.host.set({ inbox: null });
  await noInbox.session.send("x", msg("x"), noInbox.emit);
  assert.match(noInbox.emitted[0].content ?? "", /^PC のバックグラウンドのセッションに届けられませんでした/);
  for (const h of [dead, blocked, failing, noInbox]) await h.session.close();
});

test("30 秒: status が idle のまま transcript に出なければ受け付けなかったとして errored の done。busy の間は数えない", async () => {
  const h = harness({ status: "idle" });
  await h.session.send("届かない", msg("届かない"), h.emit);
  await sleep(40);
  h.host.set({ status: "busy" });
  await sleep(bgSessionTiming.ackMs + 60);
  assert.equal(h.events.filter((e) => e.type === "error").length, 0, "busy の間は数えない");
  h.host.set({ status: "idle" });
  await until(() => h.events.some((e) => e.type === "error"));
  const error = h.events.find((e) => e.type === "error")!;
  assert.equal(error.content, "PC のバックグラウンドのセッションが、この発話を受け付けませんでした（30 秒たっても反応がありません）。");
  assert.equal(h.events.at(-1)?.metadata?.errored, "true");
  await h.session.close();
});

test("保留: Held peer message を見たら Deliver の案内で errored の done", async () => {
  const h = harness({ status: "idle" });
  await h.session.send("保留される", msg("保留される"), h.emit);
  h.host.write({ type: "system", content: "Held peer message from another session" });
  await until(() => h.events.some((e) => e.type === "error"));
  assert.equal(h.events[0].content, `PC のバックグラウンドのセッションが、この発話を保留しました。PC で \`claude attach ${JOB}\` を開いて「Deliver」を選ぶと届きます。`);
  assert.equal(h.events[1].metadata?.errored, "true");
  // 送っていない保留は無視する。
  h.host.write({ type: "system", content: "Held peer message again" });
  await sleep(60);
  assert.equal(h.events.length, 2);
  await h.session.close();
});

test("ターンが閉じるとき、送った発話がまだ transcript に出ていなければ done に pending", async () => {
  const h = harness({ status: "busy" });
  await h.session.send("次の発話", msg("次の発話"), h.emit);
  h.host.set({ status: "idle" });
  assert.equal(h.events.at(-1)?.type, "done");
  assert.equal(h.events.at(-1)?.metadata?.pending, "1");
  await h.session.close();
});

test("interrupt は返事だけ止められない文を流す。warm・respondToAction は何もしない", async () => {
  const h = harness({ status: "busy" });
  await h.session.interrupt();
  assert.equal(h.events.at(-1)?.type, "error");
  assert.equal(h.events.at(-1)?.content, BG_INTERRUPT_TEXT);
  await h.session.warm();
  await h.session.respondToAction();
  assert.equal(h.session.subagentSnapshot(), undefined);
  assert.equal(h.session.supportsMidTurnInjection, true);
  await h.session.close();
});

test("elsewhere: 見るだけ。送信は断り、握っているプロセスが消えたら使えない", async () => {
  const holder: BgHolder = { pid: process.pid, entrypoint: "cli", status: "idle" };
  const h = harness({ mode: "elsewhere", holder, live: false, state: "stopped" });
  await h.session.send("x", msg("x"), h.emit);
  assert.equal(h.emitted[0].content, `この会話は PC の別の Claude Code（ターミナル、pid ${process.pid}）で開かれています。そちらを閉じてから送ってください。`);
  assert.equal(h.emitted[1].metadata?.errored, "true");
  assert.equal(h.posts.length, 0);
  assert.equal(h.session.isStillUsable(), true);
  await h.session.close();

  const other = harness({ mode: "elsewhere", holder: { pid: process.pid, entrypoint: "sdk-ts" }, live: false });
  await other.session.send("x", msg("x"), other.emit);
  assert.match(other.emitted[0].content ?? "", /ほかのアプリ、pid/);
  await other.session.close();

  const gone = harness({ mode: "elsewhere", holder: { pid: 2 ** 31 - 2, entrypoint: "cli" }, live: false });
  assert.equal(gone.session.isStillUsable(), false);
  await gone.session.close();
});

test("履歴の読み終えた位置: 履歴の後ろから流し、同じ行を履歴と live の両方に出さない", async () => {
  const feed = new Map<string, (read: { file?: string; end: number }) => void>();
  let last: { file?: string; end: number } | undefined;
  const history: HistoryReadFeed = {
    lastRead: () => last,
    onRead: (sid, listener) => {
      feed.set(sid, listener);
      return () => feed.delete(sid);
    }
  };
  const h = harness({ status: "busy", history });
  const head = fs.statSync(h.host.transcript).size;
  h.host.write(assistant("old", text("履歴にある")));
  const afterOld = fs.statSync(h.host.transcript).size;
  await sleep(40);
  assert.equal(h.events.some((e) => e.type === "assistant_delta"), false, "履歴を読み終えるまで最初の読み取りを待つ");
  // 履歴の読み取りが終わった: そこまでは出さない。
  assert.ok(head < afterOld);
  feed.get(SID)!({ file: h.host.transcript, end: afterOld });
  h.host.write(assistant("new", text("新しい")));
  await until(() => h.events.some((e) => e.type === "assistant_delta"));
  assert.deepEqual(h.events.filter((e) => e.type === "assistant_delta").map((e) => e.content), ["新しい"]);
  await h.session.close();

  // 履歴を読まれないまま 3 秒（ここでは短縮）たったら、作った時点の大きさから読み始める。
  const slow = harness({ status: "busy", history });
  slow.host.write(assistant("a", text("待たされた")));
  await until(() => slow.events.some((e) => e.type === "assistant_delta"));
  await slow.session.close();

  // 前に開いたときの読み終えた位置が分かっていても、今回の履歴の読み取りが済むか 3 秒たつまでは待つ（位置は下限にだけ使う）。
  last = { file: undefined, end: 0 };
  const known = harness({ status: "busy", history });
  known.host.write(assistant("a", text("すぐ")));
  await sleep(30);
  assert.equal(known.events.some((e) => e.type === "assistant_delta"), false, "今回の履歴の読み取りを待つ");
  assert.ok(feed.has(SID), "onRead を登録している");
  const knownEnd = fs.statSync(known.host.transcript).size;
  feed.get(SID)!({ file: known.host.transcript, end: knownEnd });
  await sleep(60);
  assert.equal(known.events.some((e) => e.type === "assistant_delta"), false, "履歴に出した分は live に出さない");
  await known.session.close();
});

test("transcript がまだ無い: 見つかるまで待ち、見つかったら先頭から流す", async () => {
  const h = harness({ status: "busy", existing: false });
  await sleep(40);
  h.host.write(assistant("a", text("遅れて")));
  await until(() => h.events.some((e) => e.type === "assistant_delta"));
  assert.equal(h.events.find((e) => e.type === "assistant_delta")?.content, "遅れて");
  await h.session.close();
});

test("PC で attach して打ったターン（status が追いつかない）は、動きが止まっていれば閉じる", async () => {
  const h = harness({ status: "idle" });
  h.host.write(assistant("a", text("勝手に")));
  await until(() => h.events.some((e) => e.type === "done"));
  assert.deepEqual(types(h.events), ["activity", "assistant_delta", "done"]);
  await h.session.close();
});

test("findHolder: 同じ sessionId を握っている生きているプロセスのうち startedAt の新しいものを返す", () => {
  const home = path.join(tmp, "holder");
  const dir = path.join(home, ".claude", "sessions");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: SID, entrypoint: "cli", status: "idle", startedAt: 10 }));
  fs.writeFileSync(path.join(dir, `${process.ppid}.json`), JSON.stringify({ pid: process.ppid, sessionId: SID, entrypoint: "sdk-cli", startedAt: 5 }));
  fs.writeFileSync(path.join(dir, `${2 ** 31 - 3}.json`), JSON.stringify({ pid: 2 ** 31 - 3, sessionId: SID, startedAt: 99 }));
  fs.writeFileSync(path.join(dir, `${process.pid}.key`), "secret");
  assert.deepEqual(findHolder(home, SID), { pid: process.pid, entrypoint: "cli", status: "idle" });
  assert.equal(findHolder(home, "other"), undefined);
  assert.equal(findHolder(path.join(tmp, "nowhere"), SID), undefined);
});

test("保留・受け付けなかった: ターンが開いている間は pending の done にして、動いているターンを終わらせない", async () => {
  const h = harness({ status: "busy" });
  await h.session.send("保留される", msg("保留される"), h.emit);
  h.host.write({ type: "system", content: "Held peer message from another session" });
  await until(() => h.events.some((e) => e.type === "error"));
  const done = h.events.find((e) => e.type === "done");
  assert.equal(done?.metadata?.errored, "true");
  assert.equal(done?.metadata?.pending, "1");
  const turnId = h.events.find((e) => e.type === "activity")?.messageId;
  assert.notEqual(done?.messageId, turnId);
  // 動いているターンは自分の done で閉じる。
  h.host.set({ status: "idle" });
  assert.equal(h.events.filter((e) => e.type === "done").length, 2);
  assert.equal(h.events.at(-1)?.messageId, turnId);
  await h.session.close();
});

test("findHolder: kind が bg のワーカー自身は握り手に数えず、onWorker を呼ぶ。elsewhere はワーカーが生き返ったら使えない", () => {
  const home = path.join(tmp, "holder-bg");
  const dir = path.join(home, ".claude", "sessions");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: SID, kind: "bg", entrypoint: "cli", status: "busy", startedAt: 10 }));
  let called = 0;
  assert.equal(findHolder(home, SID, () => called++), undefined);
  assert.equal(called, 1);
  const h = harness({ mode: "elsewhere", holder: { pid: process.pid }, live: false });
  assert.equal(h.session.isStillUsable(), true);
  h.host.set({ live: true });
  assert.equal(h.session.isStillUsable(), false);
});
