import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { SessionEvent } from "../protocol.js";
import type { RuntimeCommand } from "../runtime/command.js";
import { SleepGuard } from "../sleepGuard.js";
import {
  composeBgEntry,
  countShells,
  deriveBgState,
  parseAgentsJson,
  parseJobState,
  parseSessionFile,
  parseTolerantObject,
  readSessionFile,
  selectListed,
  usableInboxPath,
  type JobRecord
} from "./claudeAgentsRegistry.js";
import {
  bgTiming,
  ClaudeBackgroundJobs,
  judge,
  type BgActivity,
  type BgJobsDeps,
  type BgWatcher,
  type CliResult,
  type RunCli
} from "./claudeBackgroundJobs.js";

/// claude --bg のセッション（BACKGROUND_CONTROL §7、Windows は §7.10）。

const fixtureDir = path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "..", "..", "..", "shared", "fixtures", "background-control", "claude-bg");
const agentsFixture = JSON.parse(fs.readFileSync(path.join(fixtureDir, "examples-agents-json.json"), "utf8")) as Record<string, Record<string, unknown>>;
const filesFixture = JSON.parse(fs.readFileSync(path.join(fixtureDir, "examples-registry-files.json"), "utf8")) as Record<string, Record<string, unknown>>;

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-bgjobs-"));
after(() => {
  try {
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  } catch {
    /* 掃除できなくても落とさない */
  }
});

const native: RuntimeCommand = { kind: "native", executable: "claude", label: "native:claude", shell: false };
const wsl: RuntimeCommand = { kind: "wsl", executable: "claude", label: "wsl:default:claude", shell: false };

let homeSeq = 0;
function freshHome(): string {
  const home = path.join(tmp, `home${homeSeq++}`);
  fs.mkdirSync(path.join(home, ".claude", "jobs"), { recursive: true });
  fs.mkdirSync(path.join(home, ".claude", "sessions"), { recursive: true });
  return home;
}

function writeJob(home: string, id: string, state: Record<string, unknown>): void {
  fs.mkdirSync(path.join(home, ".claude", "jobs", id), { recursive: true });
  fs.writeFileSync(path.join(home, ".claude", "jobs", id, "state.json"), JSON.stringify(state));
}

function writeSession(home: string, pid: number, body: string): void {
  fs.writeFileSync(path.join(home, ".claude", "sessions", `${pid}.json`), body);
}

const ok = (stdout: string): CliResult => ({ code: 0, stdout, stderr: "", timedOut: false });

interface Harness {
  jobs: ClaudeBackgroundJobs;
  home: string;
  calls: string[][];
  events: SessionEvent[];
  setCli(rows: Record<string, unknown>[] | CliResult): void;
  pushes: { title: string; body: string; data: Record<string, string> }[];
  activities: BgActivity[];
  sleeps: boolean[];
}

function harness(extra: Partial<BgJobsDeps> = {}, runtime: RuntimeCommand | null = native): Harness {
  const home = freshHome();
  let cli: Record<string, unknown>[] | CliResult = [];
  const calls: string[][] = [];
  const runCli: RunCli = async (_runtime, args) => {
    calls.push(args);
    if (args[0] === "agents") return Array.isArray(cli) ? ok(JSON.stringify(cli)) : cli;
    return ok("");
  };
  const h: Harness = {
    home,
    calls,
    events: [],
    pushes: [],
    activities: [],
    sleeps: [],
    setCli: (v) => {
      cli = v;
    },
    jobs: undefined as unknown as ClaudeBackgroundJobs
  };
  h.jobs = new ClaudeBackgroundJobs({
    runtime: runtime ?? undefined,
    home,
    runCli,
    log: () => {},
    push: (title, body, data) => {
      h.pushes.push({ title, body, data });
    },
    setSleep: (active) => h.sleeps.push(active),
    bridgeId: "bridge-1",
    ...extra
  });
  h.jobs.register((e) => h.events.push(e));
  h.jobs.onActivity((a) => h.activities.push(a));
  return h;
}

type BgEntryLike = import("./claudeAgentsRegistry.js").BgEntry;

const A = agentsFixture.background_live_busy;
const B = agentsFixture.background_live_waiting_permission;

test("CLI の出力: kind が background の行だけ取り出す。配列でなければ失敗", () => {
  const rows = parseAgentsJson(JSON.stringify(Object.values(agentsFixture)));
  assert.ok(rows);
  assert.deepEqual(
    rows.map((r) => r.id),
    ["dceba663", "bb74b880", "dceba663", "bb74b880", "26107a74", "28f38cc2"]
  );
  assert.equal(rows[0].pid, 31875);
  assert.equal(rows[1].waitingFor, "permission prompt");
  assert.equal(rows[3].pid, undefined);
  assert.equal(parseAgentsJson("{}"), undefined);
  assert.equal(parseAgentsJson("not json"), undefined);
  // 前後に余計な出力が付いていても配列を取り出す
  assert.equal(parseAgentsJson(`warn\n${JSON.stringify([A])}\n`)?.length, 1);
  // id が 8 桁の 16 進でない行は捨てる
  assert.deepEqual(parseAgentsJson(JSON.stringify([{ ...A, id: "../x", sessionId: "../x" }])), []);
  // id の無い行も捨てる（sessionId の先頭 8 桁から偽の id を作らない）
  const { id: _omitted, ...noId } = A as Record<string, unknown>;
  assert.deepEqual(parseAgentsJson(JSON.stringify([noId])), []);
});

test("寛容な読み方: 先頭の {…} だけを読み、文字列の中の括弧は数えない。後ろのごみは捨てる", () => {
  assert.deepEqual(parseTolerantObject('{"a":"}{\\"","b":{"c":1}}\n{"x":1}garbage'), { a: '}{"', b: { c: 1 } });
  assert.deepEqual(parseTolerantObject('noise {"a":1} tail'), { a: 1 });
  assert.equal(parseTolerantObject('{"a":'), undefined);
  assert.equal(parseTolerantObject("[]"), undefined);

  const session = filesFixture.sessions_bg_busy;
  const broken = `${JSON.stringify(session)}\n{"torn":`;
  const parsed = parseSessionFile(broken, () => true);
  assert.equal(parsed?.status, "busy");
  assert.equal(parsed?.pid, 31875);
  assert.equal(parsed?.jobId, "dceba663");
});

test("受け箱の宛先: 名前付きパイプのパスか、存在するファイルだけ", () => {
  assert.equal(usableInboxPath("\\\\.\\pipe\\cc-1", () => false), "\\\\.\\pipe\\cc-1");
  assert.equal(usableInboxPath("\\\\?\\pipe\\cc-1", () => false), "\\\\?\\pipe\\cc-1");
  assert.equal(usableInboxPath("C:\\x\\a.sock", () => false), undefined);
  assert.equal(usableInboxPath("C:\\x\\a.sock", () => true), "C:\\x\\a.sock");
  assert.equal(usableInboxPath(undefined), undefined);
  assert.equal(usableInboxPath(""), undefined);
});

test("sessions\\<pid>.json は壊れていても読み、無ければ undefined", () => {
  const home = freshHome();
  const body = JSON.stringify({ ...filesFixture.sessions_bg_busy, messagingSocketPath: "\\\\.\\pipe\\cc-31875" });
  writeSession(home, 31875, `${body}trailing`);
  const dir = path.join(home, ".claude", "sessions");
  const s = readSessionFile(dir, 31875);
  assert.equal(s?.status, "busy");
  assert.equal(s?.messagingSocketPath, "\\\\.\\pipe\\cc-31875");
  assert.equal(readSessionFile(dir, 1), undefined);
  writeSession(home, 2, "{");
  assert.equal(readSessionFile(dir, 2), undefined);
});

test("shells: fan があれば shell の数。無ければ local_bash のとき tasks。どちらも無ければ 0", () => {
  assert.equal(countShells(filesFixture.job_state_working_with_inflight_task), 1);
  assert.equal(countShells({ fan: [{ kind: "shell" }, { kind: "agent" }, { kind: "shell" }], inFlight: { tasks: 9, kinds: ["local_bash"] } }), 2);
  assert.equal(countShells({ inFlight: { tasks: 3, kinds: ["local_bash"] } }), 3);
  assert.equal(countShells({ inFlight: { tasks: 3, kinds: ["monitor"] } }), 0);
  assert.equal(countShells(filesFixture.job_state_done), 0);
});

test("state.json: needs / detail / createdAt / 繰り返しの見分け", () => {
  const blocked = parseJobState(JSON.stringify(filesFixture.job_state_blocked));
  assert.equal(blocked?.needs, "approve Write: /tmp/fixture/claude-bg-sessions/cwd/bgB/hello.txt");
  assert.equal(blocked?.tempo, "blocked");
  assert.equal(blocked?.createdAtMs, Date.parse("2026-10-21T11:32:56.338Z"));
  assert.equal(blocked?.recurring, false);
  const done = parseJobState(JSON.stringify(filesFixture.job_state_done));
  assert.equal(done?.firstTerminalAtMs, Date.parse("2026-10-21T11:27:49.096Z"));
  for (const extra of [{ routine: { cron: "* * * * *" } }, { selfWake: true }, { inFlight: { kinds: ["session_cron"], tasks: 0 } }, { intent: "/loop 5m check" }, { initialPrompt: " /loop x" }]) {
    assert.equal(parseJobState(JSON.stringify({ state: "done", ...extra }))?.recurring, true, JSON.stringify(extra));
  }
});

function job(over: Partial<JobRecord>): JobRecord {
  return { shells: 0, recurring: false, keptBy: false, ...over };
}

test("状態の導出 §7.2: createdAt が無いジョブも孤児の読み替えを受け（0 とみなす）、exec で respawnFlags が空の blocked は failed にする", () => {
  const nowMs = 1_000_000;
  const base = { id: "aaaaaaaa", shorts: new Set<string>(), nowMs };
  assert.equal(deriveBgState({ ...base, job: job({ state: "working", tempo: "active" }) }).state, "failed");
  assert.equal(deriveBgState({ ...base, job: job({ state: "blocked", tempo: "idle", createdAtMs: nowMs - 6000, template: "exec", respawnFlagCount: 0 }) }).state, "failed");
  assert.equal(deriveBgState({ ...base, job: job({ state: "blocked", tempo: "idle", createdAtMs: nowMs - 6000, template: "exec", respawnFlagCount: 2 }) }).state, "blocked");
  assert.equal(deriveBgState({ ...base, job: job({ state: "blocked", tempo: "idle", createdAtMs: nowMs - 6000, template: "other" }) }).state, "blocked");
  const parsed = parseJobState(JSON.stringify({ state: "blocked", template: "exec", respawnFlags: ["--x", "y"] }));
  assert.equal(parsed?.template, "exec");
  assert.equal(parsed?.respawnFlagCount, 2);
  assert.equal(JSON.stringify(parsed).includes("--x"), false, "respawnFlags の値は持たない");
});

test("状態の導出 §7.2: 孤児の読み替え・ワーカーの status・終わっている・繰り返しの待ち", () => {
  const nowMs = 1_000_000;
  const base = { id: "aaaaaaaa", shorts: new Set<string>(), nowMs };
  // 孤児（shorts に無く 5 秒以上）は failed に読み替える。5 秒未満は読み替えない
  assert.equal(deriveBgState({ ...base, job: job({ state: "working", tempo: "active", createdAtMs: nowMs - 6000 }) }).state, "failed");
  assert.equal(deriveBgState({ ...base, job: job({ state: "working", tempo: "active", createdAtMs: nowMs - 1000 }) }).state, "working");
  // blocked は tempo を blocked に読み替える
  assert.equal(deriveBgState({ ...base, job: job({ state: "blocked", tempo: "idle", createdAtMs: nowMs - 6000 }) }).state, "blocked");
  // keptBy で「send a prompt to start」の blocked は読み替えない
  assert.equal(
    deriveBgState({ ...base, job: job({ state: "working", tempo: "blocked", keptBy: true, intent: "", needs: "send a prompt to start", createdAtMs: nowMs - 9000 }) }).state,
    "blocked"
  );
  // 生きているワーカーが busy / shell なら working
  const live = { ...base, shorts: new Set(["aaaaaaaa"]) };
  assert.equal(deriveBgState({ ...live, workerStatus: "busy", job: job({ state: "done", tempo: "idle" }) }).state, "working");
  assert.equal(deriveBgState({ ...live, workerStatus: "shell", job: job({ state: "done", tempo: "idle" }) }).state, "working");
  // 終わっていて tempo が active でなければ done / failed / stopped
  assert.equal(deriveBgState({ ...live, job: job({ state: "stopped", tempo: "idle" }) }).state, "stopped");
  assert.equal(deriveBgState({ ...live, job: job({ state: "done", tempo: "active" }) }).state, "working");
  // waiting は blocked
  assert.equal(deriveBgState({ ...live, workerStatus: "waiting", job: job({ state: "working", tempo: "active" }) }).state, "blocked");
  // 繰り返しの done は working のまま、待ちの印
  const recurring = deriveBgState({ ...live, workerStatus: "idle", job: job({ state: "done", tempo: "idle", recurring: true }) });
  assert.deepEqual(recurring, { state: "working", recurringWait: true });
  assert.equal(deriveBgState({ ...live, workerStatus: "busy", job: job({ state: "done", tempo: "idle", recurring: true }) }).recurringWait, false);
});

test("行: sessions の生の status と state.json の足し、BuddyOS の名前が優先、読めなければ CLI の値だけ", () => {
  const [cliA, cliB, , , cliFailed] = parseAgentsJson(JSON.stringify(Object.values(agentsFixture))) ?? [];
  const sessionA = parseSessionFile(JSON.stringify(filesFixture.sessions_bg_busy));
  const entry = composeBgEntry({ cli: cliA, job: parseJobState(JSON.stringify(filesFixture.job_state_working_with_inflight_task)), session: sessionA });
  assert.equal(entry.workerStatus, "busy");
  assert.equal(entry.row.shells, 1);
  assert.equal(entry.row.live, true);
  assert.equal(entry.row.title, "count slowly from 1 to 5, one number every 10 seconds using sleep, then say done".slice(0, 80));
  assert.equal(composeBgEntry({ cli: cliA, session: sessionA, buddyTitle: "自分の名前" }).row.title, "自分の名前");
  // 読めないとき: createdAtMs は CLI の startedAt、needs / detail / shells は無し
  const bare = composeBgEntry({ cli: cliB });
  assert.equal(bare.row.state, "blocked");
  assert.equal(bare.row.needs, undefined);
  assert.equal(bare.row.createdAtMs, 1792582377137);
  assert.equal(bare.row.shells, 0);
  assert.equal(bare.row.title, B.name?.toString().slice(0, 80));
  // blocked の needs / failed の detail
  const blocked = composeBgEntry({ cli: cliB, job: parseJobState(JSON.stringify(filesFixture.job_state_blocked)) });
  assert.equal(blocked.row.needs, "approve Write: /tmp/fixture/claude-bg-sessions/cwd/bgB/hello.txt");
  const failed = composeBgEntry({ cli: cliFailed, job: parseJobState(JSON.stringify(filesFixture.job_state_failed_before_init)) });
  assert.match(failed.row.detail ?? "", /^exit 1 before init/);
  assert.ok((failed.row.detail ?? "").length <= 200);
  assert.equal(failed.row.live, false);
  assert.equal(failed.row.shells, 0);
  // 生の status が読めないときは、CLI が busy で tempo が active のときだけ busy
  const busyCli = { ...cliA };
  assert.equal(composeBgEntry({ cli: busyCli, job: job({ tempo: "active" }) }).workerStatus, "busy");
  assert.notEqual(composeBgEntry({ cli: busyCli, job: job({ tempo: "idle" }) }).workerStatus, "busy");
  assert.notEqual(composeBgEntry({ cli: busyCli }).workerStatus, "busy");
  // shell は busy に取り違えない
  assert.equal(composeBgEntry({ cli: { ...cliA, status: "shell" }, job: job({ tempo: "active" }) }).workerStatus, "shell");
});

test("一覧の絞り込みと並び: live か working / blocked と 24 時間以内の終わり、blocked → working → ほか、新しい順、50 件まで", () => {
  const now = Date.UTC(2026, 9, 22);
  const mk = (id: string, state: "working" | "blocked" | "done" | "failed" | "stopped", createdAtMs: number, over: { live?: boolean; endedAtMs?: number } = {}) => {
    const e = composeBgEntry({ cli: { id, sessionId: `${id}-0000-0000-0000-000000000000`, cwd: "c", state, pid: over.live ? 1 : undefined, startedAt: createdAtMs } });
    return { ...e, row: { ...e.row, createdAtMs }, endedAtMs: over.endedAtMs };
  };
  const entries = [
    mk("00000001", "done", 100, { endedAtMs: now - 3600_000 }),
    mk("00000002", "working", 50),
    mk("00000003", "blocked", 10),
    mk("00000004", "done", 500, { endedAtMs: now - 25 * 3600_000 }),
    mk("00000005", "working", 70),
    mk("00000006", "stopped", 900, { endedAtMs: now - 1000 }),
    mk("00000007", "failed", 800, { live: true, endedAtMs: now - 48 * 3600_000 })
  ];
  assert.deepEqual(
    selectListed(entries, now).map((e) => e.row.id),
    ["00000003", "00000005", "00000002", "00000006", "00000007", "00000001"]
  );
  const many = Array.from({ length: 80 }, (_, i) => mk(`${(i + 16).toString(16).padStart(8, "0")}`, "working", i));
  assert.equal(selectListed(many, now).length, 50);
  assert.equal(selectListed(many, now)[0].row.createdAtMs, 79);
});

test("WSL の runtime では機能を切る: capable が false、CLI を動かさず、一覧は空、操作は使えない", async () => {
  const h = harness({}, wsl);
  assert.equal(h.jobs.capable, false);
  h.jobs.start();
  await h.jobs.ready();
  await h.jobs.refresh();
  assert.deepEqual(h.jobs.rows(), []);
  assert.equal(h.calls.length, 0);
  const result = await h.jobs.operate("stop", "x", "dceba663");
  assert.equal(result.ok, false);
  h.jobs.stop();
  const none = harness({}, null);
  assert.equal(none.jobs.capable, false);
});

test("CLI が失敗しても直前の結果を保つ（一覧・台帳・数。開いている会話にも知らせない）。3 回続けて失敗したときだけ空にする", async () => {
  const saved = { ...bgTiming };
  const h = harness();
  try {
    h.setCli([A]);
    await h.jobs.refresh();
    assert.equal(h.jobs.rows().length, 1);
    const seen: (BgEntryLike | undefined)[] = [];
    h.jobs.watchEntry(A.sessionId as string, (e) => seen.push(e));
    h.events.length = 0;
    const activities = h.activities.length;
    h.setCli({ code: 1, stdout: "", stderr: "boom", timedOut: false });
    // 1 回目・2 回目の失敗: 一覧も台帳も数もそのまま、誰にも何も送らない。
    await h.jobs.refresh();
    h.setCli(ok("{}"));
    await h.jobs.refresh();
    assert.equal(h.jobs.rows().length, 1);
    assert.ok(h.jobs.entryFor(A.sessionId as string));
    assert.equal(h.jobs.isBackgroundWorker(A.sessionId as string), true);
    assert.deepEqual(h.jobs.activityCounts(), { [A.sessionId as string]: 1 });
    assert.equal(h.events.length, 0);
    assert.equal(seen.length, 0);
    assert.equal(h.activities.length, activities);
    // 3 回目（時間切れ）: 一覧を空にして removed を送り、数を落とし、開いている会話には undefined を知らせる。
    h.setCli({ code: null, stdout: "", stderr: "", timedOut: true });
    await h.jobs.refresh();
    assert.deepEqual(h.jobs.rows(), []);
    assert.equal(h.jobs.entryFor(A.sessionId as string), undefined);
    assert.equal(h.events.length, 1);
    assert.deepEqual(JSON.parse(h.events[0].content ?? ""), { id: "dceba663", sessionId: A.sessionId, removed: true });
    assert.deepEqual(h.activities.at(-1)?.counts, {});
    assert.deepEqual(seen, [undefined]);
    // 成功したら戻る。
    h.setCli([A]);
    await h.jobs.refresh();
    assert.equal(h.jobs.rows().length, 1);
    // 試し直しの間隔: 30 秒、5 分、30 分。
    assert.equal(bgTiming.retryFirstMs, 30_000);
    assert.equal(bgTiming.retrySecondMs, 5 * 60_000);
    assert.equal(bgTiming.retryMs, 30 * 60_000);
  } finally {
    Object.assign(bgTiming, saved);
    h.jobs.stop();
  }
});

test("失敗の間に終わったジョブ: 回復した最初の読み取りで、失敗の前の台帳と比べて完了の知らせと遷移を出す", async () => {
  for (const failures of [1, 3]) {
    const h = harness();
    writeJob(h.home, "dceba663", { state: "working", tempo: "active", createdAt: "2026-10-21T11:26:21.328Z" });
    h.setCli([A]);
    await h.jobs.refresh();
    h.setCli({ code: 1, stdout: "", stderr: "boom", timedOut: false });
    for (let i = 0; i < failures; i++) await h.jobs.refresh();
    writeJob(h.home, "dceba663", {
      state: "done",
      tempo: "idle",
      createdAt: "2026-10-21T11:26:21.328Z",
      firstTerminalAt: new Date().toISOString(),
      lastTerminalAt: new Date().toISOString()
    });
    h.setCli([{ ...A, status: "idle", state: "done" }]);
    await h.jobs.refresh();
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(h.pushes.length, 1, `failures=${failures}`);
    assert.deepEqual(h.activities.at(-1)?.finished, ["done"], `failures=${failures}`);
  }
});

test("最初の一覧の読み取り中に ready() を呼んでも、CLI は 1 回しか動かさない", async () => {
  const h = harness();
  h.setCli([A]);
  const first = h.jobs.refresh();
  await h.jobs.ready();
  await first;
  assert.equal(h.calls.filter((c) => c[0] === "agents").length, 1);
});

test("claimPush: 同じ会話へ 60 秒以内に続けて出さない", () => {
  let now = 1_000_000;
  const h = harness({ now: () => now });
  assert.equal(h.jobs.claimPush("s"), true);
  assert.equal(h.jobs.claimPush("s"), false);
  assert.equal(h.jobs.claimPush("t"), true);
  now += bgTiming.pushGapMs;
  assert.equal(h.jobs.claimPush("s"), true);
});

test("差分: 変わった行だけ bg_session_changed。一覧から外れた行と消えたジョブは removed", async () => {
  const h = harness();
  h.setCli([A, B]);
  await h.jobs.refresh();
  const changed = h.events.filter((e) => e.type === "bg_session_changed");
  assert.equal(changed.length, 2);
  assert.equal((JSON.parse(changed.find((e) => e.sessionId === A.sessionId)?.content ?? "") as { state: string }).state, "working");
  h.events.length = 0;

  await h.jobs.refresh();
  assert.equal(h.events.length, 0);

  h.setCli([{ ...A, status: "idle", state: "done" }, B]);
  await h.jobs.refresh();
  assert.equal(h.events.length, 1);
  assert.equal((JSON.parse(h.events[0].content ?? "") as { state: string }).state, "done");
  h.events.length = 0;

  // rm されて CLI から消えた
  h.setCli([{ ...A, status: "idle", state: "done" }]);
  await h.jobs.refresh();
  assert.equal(h.events.length, 1);
  assert.deepEqual(JSON.parse(h.events[0].content ?? ""), { id: "bb74b880", sessionId: B.sessionId, removed: true });

  // 終わって 24 時間を過ぎた行は一覧から外れて removed
  h.events.length = 0;
  writeJob(h.home, "dceba663", { state: "done", tempo: "idle", lastTerminalAt: new Date(Date.now() - 25 * 3600_000).toISOString(), createdAt: new Date(Date.now() - 26 * 3600_000).toISOString() });
  const deadA = { id: "dceba663", cwd: "c", kind: "background", startedAt: 1, sessionId: A.sessionId, state: "done" };
  h.setCli([deadA]);
  await h.jobs.refresh();
  assert.equal(h.jobs.rows().length, 0);
  assert.equal(h.events.length, 1);
  assert.equal((JSON.parse(h.events[0].content ?? "") as { removed?: boolean }).removed, true);
});

test("一覧: 台帳のファイルを読めたときだけ needs / detail / createdAt / shells を足す", async () => {
  const h = harness();
  writeJob(h.home, "dceba663", filesFixture.job_state_working_with_inflight_task);
  writeSession(h.home, 31875, JSON.stringify(filesFixture.sessions_bg_busy));
  writeJob(h.home, "bb74b880", filesFixture.job_state_blocked);
  h.setCli([A, B]);
  await h.jobs.refresh();
  const rows = h.jobs.rows();
  assert.deepEqual(
    rows.map((r) => [r.id, r.state]),
    [
      ["bb74b880", "blocked"],
      ["dceba663", "working"]
    ]
  );
  assert.equal(rows[0].needs, "approve Write: /tmp/fixture/claude-bg-sessions/cwd/bgB/hello.txt");
  assert.equal(rows[0].createdAtMs, Date.parse("2026-10-21T11:32:56.338Z"));
  assert.equal(rows[1].shells, 1);
  assert.ok(!("pid" in rows[1]));
  assert.equal(JSON.stringify(rows[1]).includes("respawnFlags"), false);
});

test("操作の判定: 成功・No job matching・時間切れ・ほかの失敗（stderr の最後の 3 行）", () => {
  const res = (code: number | null, stdout: string, stderr: string, timedOut = false): CliResult => ({ code, stdout, stderr, timedOut });
  assert.deepEqual(judge("stop", "dceba663", res(0, "stopped dceba663\n", "")), { ok: true, text: "" });
  assert.deepEqual(judge("delete", "dceba663", res(0, "removed dceba663\n", "")), { ok: true, text: "" });
  assert.equal(judge("stop", "dceba663", res(0, "removed dceba663\n", "")).ok, false);
  assert.equal(judge("stop", "dceba663", res(0, "", "")).ok, false);
  const missingStop = judge("stop", "dceba663", res(1, "", "No job matching dceba663"));
  assert.equal(missingStop.ok, false);
  assert.match(missingStop.text, /見つかりません/);
  assert.deepEqual(judge("delete", "dceba663", res(1, "", "No job matching dceba663")), { ok: true, text: "" });
  assert.equal(judge("stop", "dceba663", res(null, "", "", true)).text, "PC で止められませんでした（15秒たっても終わりません）");
  assert.equal(judge("delete", "dceba663", res(null, "", "", true)).text, "PC で削除できませんでした（20秒たっても終わりません）");
  const other = judge("delete", "dceba663", res(1, "", "l1\nl2\nl3\nl4\n"));
  assert.deepEqual(other, { ok: false, text: "l2\nl3\nl4" });
  assert.ok(judge("delete", "dceba663", res(1, "", "x".repeat(900))).text.length <= 400);
});

test("操作: 台帳に無い id・sessionId の不一致・8 桁でない id は CLI を動かさず ok 0。stop は ok 1 で shells を知らせる", async () => {
  const h = harness();
  writeJob(h.home, "dceba663", filesFixture.job_state_working_with_inflight_task);
  h.setCli([A]);
  await h.jobs.refresh();
  const before = h.calls.length;
  for (const [sid, id] of [
    [A.sessionId, "ffffffff"],
    ["other", "dceba663"],
    [A.sessionId, "../../x"],
    [undefined, undefined]
  ] as const) {
    const r = await h.jobs.operate("stop", sid as string | undefined, id);
    assert.equal(r.ok, false);
    assert.match(r.text, /見つかりません/);
  }
  assert.equal(h.calls.length, before);

  const runCli: RunCli = async (_r, args) => (args[0] === "agents" ? ok(JSON.stringify([A])) : ok(`stopped ${args[1]}\n`));
  h.jobs.attach({ runCli });
  const stop = await h.jobs.operate("stop", A.sessionId as string, "dceba663");
  assert.deepEqual(stop, { ok: true, shells: 1, text: "止めました。裏で動いていたコマンド 1 件は PC で動いたままです。" });
  h.jobs.attach({ runCli: async (_r, args) => (args[0] === "agents" ? ok(JSON.stringify([A])) : ok(`removed ${args[1]}\n`)) });
  const del = await h.jobs.operate("delete", A.sessionId as string, "dceba663");
  assert.equal(del.text, "削除しました。裏で動いていたコマンド 1 件は PC で動いたままです。");
  // shells が 0 のときは空
  writeJob(h.home, "dceba663", filesFixture.job_state_done);
  await h.jobs.refresh();
  assert.equal((await h.jobs.operate("delete", A.sessionId as string, "dceba663")).text, "");
});

test("操作: 同じ id は 1 本ずつ。操作の後は台帳を読み直して bg_session_changed を送る", async () => {
  const h = harness();
  h.setCli([A]);
  await h.jobs.refresh();
  h.events.length = 0;
  let running = 0;
  let maxRunning = 0;
  const order: string[] = [];
  let state = "working";
  const runCli: RunCli = async (_r, args) => {
    if (args[0] === "agents") return ok(JSON.stringify([{ ...A, state }]));
    running++;
    maxRunning = Math.max(maxRunning, running);
    order.push(`start ${args[0]}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
    order.push(`end ${args[0]}`);
    running--;
    state = "stopped";
    return ok(`${args[0] === "stop" ? "stopped" : "removed"} ${args[1]}\n`);
  };
  h.jobs.attach({ runCli });
  const [r1, r2] = await Promise.all([h.jobs.operate("stop", A.sessionId as string, "dceba663"), h.jobs.operate("delete", A.sessionId as string, "dceba663")]);
  assert.equal(r1.ok, true);
  assert.equal(r2.ok, true);
  assert.equal(maxRunning, 1);
  assert.deepEqual(order, ["start stop", "end stop", "start rm", "end rm"]);
  assert.ok(h.events.some((e) => e.type === "bg_session_changed" && (JSON.parse(e.content ?? "") as { state: string }).state === "stopped"));
});

test("操作: stop は claude stop <id>、delete は claude rm <id> を配列の引数で動かす", async () => {
  const h = harness();
  h.setCli([A]);
  await h.jobs.refresh();
  const seen: [string[], number][] = [];
  const runCli: RunCli = async (_r, args, timeoutMs) => {
    seen.push([args, timeoutMs]);
    return args[0] === "agents" ? ok(JSON.stringify([A])) : ok(`${args[0] === "stop" ? "stopped" : "removed"} ${args[1]}\n`);
  };
  h.jobs.attach({ runCli });
  await h.jobs.operate("stop", A.sessionId as string, "dceba663");
  await h.jobs.operate("delete", A.sessionId as string, "dceba663");
  const ops = seen.filter(([args]) => args[0] !== "agents");
  assert.deepEqual(ops, [
    [["stop", "dceba663"], 15_000],
    [["rm", "dceba663"], 20_000]
  ]);
});

async function finishedFlow(opts: { watchers?: boolean; live?: boolean; state?: string; firstBefore?: boolean; text?: string } = {}) {
  const h = harness({
    hasWatchers: () => opts.watchers === true,
    hasLiveSession: () => opts.live === true
  });
  const transcript = path.join(h.home, ".claude", "projects", "x", `${A.sessionId}.jsonl`);
  fs.mkdirSync(path.dirname(transcript), { recursive: true });
  const lines = [
    { type: "user", message: { role: "user", content: "go" } },
    { type: "assistant", message: { content: [{ type: "text", text: opts.text ?? "最後の答え" }] } },
    { type: "assistant", isSidechain: true, message: { content: [{ type: "text", text: "サブの答え" }] } }
  ];
  fs.writeFileSync(transcript, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  writeJob(h.home, "dceba663", { state: "working", tempo: "active", createdAt: "2026-10-21T11:26:21.328Z", linkScanPath: transcript });
  h.setCli([A]);
  await h.jobs.refresh();
  writeJob(h.home, "dceba663", {
    state: opts.state ?? "done",
    tempo: "idle",
    detail: "exit 1",
    createdAt: "2026-10-21T11:26:21.328Z",
    firstTerminalAt: new Date().toISOString(),
    lastTerminalAt: new Date().toISOString(),
    linkScanPath: transcript
  });
  h.setCli([{ ...A, status: "idle", state: opts.state ?? "done" }]);
  await h.jobs.refresh();
  await new Promise((resolve) => setTimeout(resolve, 20));
  return h;
}

test("完了の push: 最初の作業が終わったとき 1 回だけ。本文は transcript の main の最後の assistant の text", async () => {
  const h = await finishedFlow();
  assert.equal(h.pushes.length, 1);
  assert.equal(h.pushes[0].title, "Claude Code");
  assert.equal(h.pushes[0].body, "最後の答え");
  assert.deepEqual(h.pushes[0].data, { kind: "chat", agentId: "claude", sessionId: A.sessionId, bridgeId: "bridge-1" });
  // 同じ状態の読み直しでは出さない
  await h.jobs.refresh();
  assert.equal(h.pushes.length, 1);
});

test("完了の push: 180 字まで。失敗は detail の頭 120 字。本文が取れなければ定型", async () => {
  const long = await finishedFlow({ text: "あ".repeat(300) });
  assert.equal(long.pushes[0].body.length, 180);
  const failed = await finishedFlow({ state: "failed" });
  assert.equal(failed.pushes[0].body, "バックグラウンドのセッションが失敗しました（exit 1）");
  const h = harness();
  writeJob(h.home, "dceba663", { state: "working", tempo: "active" });
  h.setCli([A]);
  await h.jobs.refresh();
  writeJob(h.home, "dceba663", { state: "done", tempo: "idle", firstTerminalAt: new Date().toISOString() });
  h.setCli([{ ...A, state: "done" }]);
  await h.jobs.refresh();
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(h.pushes[0].body, "バックグラウンドのセッションが終わりました");
});

test("完了の push を出さない: 会話を開いている人がいる・Bridge の session がある・stopped・最初の読み取り・firstTerminalAt が前からある・60 秒以内", async () => {
  assert.equal((await finishedFlow({ watchers: true })).pushes.length, 0);
  assert.equal((await finishedFlow({ live: true })).pushes.length, 0);
  assert.equal((await finishedFlow({ state: "stopped" })).pushes.length, 0);

  // 起動して最初の読み取りで終わっていたものは出さない
  const first = harness();
  writeJob(first.home, "dceba663", { state: "done", tempo: "idle", firstTerminalAt: new Date().toISOString(), lastTerminalAt: new Date().toISOString() });
  first.setCli([{ ...A, state: "done" }]);
  await first.jobs.refresh();
  assert.equal(first.pushes.length, 0);

  // 2 回目からのターン（firstTerminalAt が前からある）の終わりでは出さない
  const second = harness();
  const stamp = new Date().toISOString();
  writeJob(second.home, "dceba663", { state: "working", tempo: "active", firstTerminalAt: stamp });
  second.setCli([A]);
  await second.jobs.refresh();
  writeJob(second.home, "dceba663", { state: "done", tempo: "idle", firstTerminalAt: stamp });
  second.setCli([{ ...A, state: "done" }]);
  await second.jobs.refresh();
  assert.equal(second.pushes.length, 0);

  // 同じ会話へ 60 秒以内の 2 回目は出さない
  let now = 1_000_000;
  const gap = harness({ now: () => now });
  const cycle = async (round: number): Promise<void> => {
    writeJob(gap.home, "dceba663", { state: "working", tempo: "active" });
    gap.setCli([A]);
    await gap.jobs.refresh();
    writeJob(gap.home, "dceba663", { state: "done", tempo: "idle", firstTerminalAt: `2026-10-21T11:27:0${round}Z` });
    gap.setCli([{ ...A, state: "done" }]);
    await gap.jobs.refresh();
  };
  await cycle(1);
  now += 30_000;
  await cycle(2);
  now += 31_000;
  await cycle(3);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(gap.pushes.length, 2);
});

test("SleepGuard: 生の status が busy の間だけ保つ。shell は数えない。読めないときは CLI の busy かつ tempo active だけ", async () => {
  const guard = new SleepGuard(false);
  const h = harness({ setSleep: (active) => guard.setActive(active, "claude-bg") });
  writeSession(h.home, 31875, JSON.stringify({ ...filesFixture.sessions_bg_busy, status: "busy" }));
  h.setCli([A]);
  await h.jobs.refresh();
  assert.equal(guard.held, true);

  // dev サーバーのような shell
  writeSession(h.home, 31875, JSON.stringify({ ...filesFixture.sessions_bg_busy, status: "shell" }));
  h.setCli([{ ...A, status: "shell" }]);
  await h.jobs.refresh();
  assert.equal(guard.held, false);

  // 生の status が読めない: CLI が busy でも tempo が active でなければ数えない
  fs.rmSync(path.join(h.home, ".claude", "sessions", "31875.json"));
  writeJob(h.home, "dceba663", { state: "working", tempo: "idle" });
  h.setCli([A]);
  await h.jobs.refresh();
  assert.equal(guard.held, false);
  writeJob(h.home, "dceba663", { state: "working", tempo: "active" });
  await h.jobs.refresh();
  assert.equal(guard.held, true);

  // 生きていない（pid が無い）ジョブは数えない
  h.setCli([{ ...A, pid: undefined }]);
  await h.jobs.refresh();
  assert.equal(guard.held, false);
});

test("SleepGuard: 同じジョブが 6 時間続けて busy なら数えない", async () => {
  let now = 1_000_000;
  const guard = new SleepGuard(false);
  const h = harness({ now: () => now, setSleep: (active) => guard.setActive(active, "claude-bg") });
  writeSession(h.home, 31875, JSON.stringify({ ...filesFixture.sessions_bg_busy, status: "busy" }));
  h.setCli([A]);
  await h.jobs.refresh();
  assert.equal(guard.held, true);
  now += 5 * 3600_000;
  await h.jobs.refresh();
  assert.equal(guard.held, true);
  now += 2 * 3600_000;
  await h.jobs.refresh();
  assert.equal(guard.held, false);
  // 他の owner は巻き込まない
  guard.setActive(true, "sessions");
  assert.equal(guard.held, true);
});

test("Live Activity の数: working / blocked は 1、繰り返しの待ちは 0。終わった遷移と消えたジョブ（stopped）を渡す。最初の読み取りでは渡さない", async () => {
  const h = harness();
  writeJob(h.home, "bb74b880", filesFixture.job_state_blocked);
  h.setCli([A, B]);
  await h.jobs.refresh();
  assert.deepEqual(h.jobs.activityCounts(), { [A.sessionId as string]: 1, [B.sessionId as string]: 1 });
  assert.deepEqual(h.activities.at(-1)?.finished, []);

  h.setCli([{ ...A, state: "done", status: "idle" }, { ...B, state: "failed", pid: undefined }]);
  await h.jobs.refresh();
  assert.deepEqual(h.jobs.activityCounts(), {});
  assert.deepEqual(h.activities.at(-1)?.finished.sort(), ["done", "failed"]);

  h.setCli([A, B]);
  await h.jobs.refresh();
  h.setCli([A]);
  await h.jobs.refresh();
  assert.deepEqual(h.activities.at(-1)?.finished, ["stopped"]);

  // 繰り返しの待ち
  const r = harness();
  writeJob(r.home, "dceba663", { state: "done", tempo: "idle", selfWake: true, createdAt: "2026-10-21T11:26:21.328Z" });
  r.setCli([{ ...A, state: "working", status: "idle" }]);
  await r.jobs.refresh();
  assert.equal(r.jobs.rows().length, 1);
  assert.deepEqual(r.jobs.activityCounts(), {});
});

test("見張り: jobs と sessions の変化を 300 ミリ秒待って読み直す。.key と state.json.tmp は無視。無ければ .claude の作成を待つ", async () => {
  const saved = { ...bgTiming };
  Object.assign(bgTiming, { debounceMs: 20, maxDebounceMs: 60, minGapMs: 30, activeMs: 100_000, idleMs: 100_000, waitDirMs: 40 });
  const watched: { dir: string; recursive: boolean; fire: (name: string | null) => void; closed: boolean }[] = [];
  const watch = (dir: string, recursive: boolean, onEvent: (name: string | null) => void): BgWatcher => {
    const w = { dir, recursive, fire: onEvent, closed: false };
    watched.push(w);
    return { close: () => (w.closed = true) };
  };
  const h = harness({ watch });
  try {
    h.setCli([]);
    h.jobs.start();
    await new Promise((resolve) => setTimeout(resolve, 60));
    const initial = h.calls.length;
    assert.ok(initial >= 1);
    assert.deepEqual(watched.map((w) => [path.basename(w.dir), w.recursive]).sort(), [["jobs", true], ["sessions", true]]);

    h.setCli([A]);
    watched[0].fire("dceba663\\state.json.tmp.1");
    watched[0].fire("x.key");
    await new Promise((resolve) => setTimeout(resolve, 100));
    assert.equal(h.calls.length, initial);

    watched[0].fire("dceba663\\state.json");
    watched[0].fire("dceba663\\state.json");
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.equal(h.calls.length, initial + 1);
    assert.equal(h.jobs.rows().length, 1);
  } finally {
    h.jobs.stop();
    Object.assign(bgTiming, saved);
  }

  // .claude も無い: 作られるまで待ち、できたら jobs と sessions を見張る
  const lateHome = path.join(tmp, "late-home");
  const lateWatched: string[] = [];
  const late = new ClaudeBackgroundJobs({
    runtime: native,
    home: lateHome,
    runCli: async () => ok("[]"),
    log: () => {},
    watch: (dir) => {
      lateWatched.push(dir);
      return { close() {} };
    }
  });
  Object.assign(bgTiming, { waitDirMs: 30, idleMs: 100_000, activeMs: 100_000 });
  try {
    late.start();
    assert.deepEqual(lateWatched, []);
    fs.mkdirSync(path.join(lateHome, ".claude", "jobs"), { recursive: true });
    fs.mkdirSync(path.join(lateHome, ".claude", "sessions"), { recursive: true });
    await new Promise((resolve) => setTimeout(resolve, 90));
    assert.deepEqual(lateWatched.map((d) => path.basename(d)).sort(), ["jobs", "sessions"]);
  } finally {
    late.stop();
    Object.assign(bgTiming, saved);
  }
});

test("操作の結果は一覧の読み直しを待たずに返す（アプリの 25 秒を超えない）。変化は bg_session_changed で届く", async () => {
  const h = harness();
  h.setCli([A]);
  await h.jobs.refresh();
  h.events.length = 0;
  let release: (() => void) | undefined;
  const gate = new Promise<void>((resolve) => (release = resolve));
  h.jobs.attach({
    runCli: async (_r, args) => {
      if (args[0] === "agents") {
        await gate;
        return ok(JSON.stringify([{ ...A, state: "stopped" }]));
      }
      return ok(`stopped ${args[1]}\n`);
    }
  });
  const result = await h.jobs.operate("stop", A.sessionId as string, "dceba663");
  assert.equal(result.ok, true);
  assert.equal(h.events.length, 0, "読み直しはまだ終わっていない");
  release?.();
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.ok(h.events.some((e) => e.type === "bg_session_changed"));
});
