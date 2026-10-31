import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { RuntimeCommand } from "../runtime/command.js";
import {
  createLedgerReader,
  delegationTiming,
  grokReceiptKey,
  hermesLedgerRow,
  hermesManifestRow,
  hermesReceipt,
  LedgerWatcher,
  loadSqlite,
  openclawLedgerRow,
  openclawReceipt,
  type LedgerReader,
  type LedgerRow,
  type RunText
} from "./acpDelegations.js";

/** 受領票の読み取り・台帳の行の読み方・読み取り元の選び方・見張り（BACKGROUND_CONTROL §5.1 / 5.4 / 5.5 / 5.6 / 5.7）。 */

type Row = Record<string, unknown>;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-delegations-"));
after(() => {
  try {
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  } catch {
    /* Windows で掴んだまま残っても害は無い */
  }
});

const fixtureDir = path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1")), "..", "..", "..", "shared", "fixtures", "background-control", "acp-delegation");
type SqliteSpec = { table: string; columns: Array<{ name: string; type: string; pk: number }>; rows: Row[] };
const ledgers = JSON.parse(fs.readFileSync(path.join(fixtureDir, "ledgers.json"), "utf8")) as { hermes: SqliteSpec; openclaw: SqliteSpec };

const native: RuntimeCommand = { kind: "native", executable: "x", label: "native:x", shell: false };
const wsl: RuntimeCommand = { kind: "wsl", executable: "hermes", label: "wsl:default:hermes", shell: false };

const hasSqlite = (await loadSqlite()) !== undefined;

async function makeLedger(file: string, spec: SqliteSpec, rows: Row[], dropColumn?: string): Promise<void> {
  const { DatabaseSync } = (await import("node:sqlite")) as { DatabaseSync: new (f: string) => { exec(sql: string): void; prepare(sql: string): { run(...p: unknown[]): void }; close(): void } };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  try {
    const columns = spec.columns.filter((c) => c.name !== dropColumn);
    db.exec(`CREATE TABLE ${spec.table} (${columns.map((c) => `${c.name} ${c.type}${c.pk ? " PRIMARY KEY" : ""}`).join(", ")})`);
    for (const row of rows) {
      const names = Object.keys(row).filter((n) => n !== dropColumn);
      db.prepare(`INSERT INTO ${spec.table} (${names.join(", ")}) VALUES (${names.map(() => "?").join(", ")})`).run(...names.map((n) => row[n]));
    }
  } finally {
    db.close();
  }
}

test("受領票: Grok は subagent_id、Hermes は dispatched（action・results があれば同期）、OpenClaw は accepted・run・expectsCompletionMessage", () => {
  assert.equal(grokReceiptKey("Subagent started in background.\nsubagent_id: 01a15e42-115f\ndescription: x"), "01a15e42-115f");
  assert.equal(grokReceiptKey("Subagent finished.\nsubagent_id: 01a15e42"), undefined);
  assert.equal(grokReceiptKey(undefined), undefined);

  const dispatched = JSON.stringify({ status: "dispatched", mode: "background", count: 2, delegation_id: "deleg_cbe3a7c4" });
  assert.deepEqual(hermesReceipt(dispatched), { key: "deleg_cbe3a7c4", taskCount: 2 });
  assert.equal(hermesReceipt(JSON.stringify({ status: "dispatched", delegation_id: "d", action: "list" })), undefined);
  assert.equal(hermesReceipt(JSON.stringify({ status: "dispatched", delegation_id: "d", results: [] })), undefined);
  assert.equal(hermesReceipt(JSON.stringify({ status: "completed", delegation_id: "d" })), undefined);
  assert.equal(hermesReceipt("3 tasks started"), undefined);

  const accepted = { status: "accepted", mode: "run", runId: "4fcca178", expectsCompletionMessage: true };
  assert.deepEqual(openclawReceipt(accepted, undefined), { key: "4fcca178" });
  assert.deepEqual(openclawReceipt(undefined, JSON.stringify(accepted)), { key: "4fcca178" }, "details が無ければ本文の JSON");
  assert.equal(openclawReceipt({ ...accepted, mode: "session" }, undefined), undefined, "session は未実測なので今まで通り閉じる");
  assert.equal(openclawReceipt({ ...accepted, expectsCompletionMessage: false }, undefined), undefined);
  assert.equal(openclawReceipt({ ...accepted, status: "rejected" }, undefined), undefined);
});

test("Hermes の台帳の行: running 系は動いている、completed は done、error 系は failed、interrupted・cancelled は stopped、ほかは failed", () => {
  for (const state of ["running", "stalling", "finalizing"]) assert.equal(hermesLedgerRow({ state }).state, "running");
  assert.equal(hermesLedgerRow({ state: "completed" }).state, "done");
  for (const state of ["error", "stalled", "unknown"]) assert.equal(hermesLedgerRow({ state }).state, "failed");
  assert.equal(hermesLedgerRow({ state: "weird", completed_at: 5 }).state, "failed", "知らない state でも completed_at があれば failed");
  assert.equal(hermesLedgerRow({ state: "queued", completed_at: null }).state, "running", "知らない state で completed_at が無ければ動いている");
  for (const state of ["interrupted", "cancelled"]) assert.equal(hermesLedgerRow({ state }).state, "stopped");

  // 実測の行（completed）。結果は results の summary、所要時間は total_duration_seconds。
  const done = hermesLedgerRow(ledgers.hermes.rows[1]);
  assert.deepEqual(done, { state: "done", result: "OK", durationMs: 24250 });
  assert.deepEqual(hermesLedgerRow(ledgers.hermes.rows[0]), { state: "running" });

  const event = (e: unknown): Row => ({ state: "error", event_json: JSON.stringify(e) });
  assert.equal(hermesLedgerRow(event({ results: [{ summary: "a" }, { error: "b" }, { summary: " " }] })).result, "a\n\nb", "summary（無ければ error）を空行でつなぐ");
  assert.equal(hermesLedgerRow(event({ error: "boom" })).result, "boom", "results の無い形は summary / error");
  assert.equal(hermesLedgerRow(event({ summary: "s", duration_seconds: 2 })).durationMs, 2000, "total_duration_seconds が無ければ duration_seconds");
  assert.equal(hermesLedgerRow({ state: "error", event_json: "not json" }).result, undefined);
});

test("Hermes の manifest: completed が無ければ running、全部 completed なら done、error 系があれば failed、ほかの終わりは stopped", () => {
  const manifest = (completed: unknown, statuses: string[]): string =>
    JSON.stringify({ delegation_id: "d", task_count: statuses.length, tasks: statuses.map((status, index) => ({ index, status })), completed });
  assert.equal(hermesManifestRow(manifest(undefined, ["running"]))?.state, "running");
  assert.equal(hermesManifestRow(manifest(1792582383, ["completed", "completed"]))?.state, "done");
  for (const bad of ["error", "stalled", "unknown"]) assert.equal(hermesManifestRow(manifest(true, ["completed", bad]))?.state, "failed");
  assert.equal(hermesManifestRow(manifest(true, ["completed", "cancelled"]))?.state, "stopped");
  assert.equal(hermesManifestRow("{"), undefined);
});

test("OpenClaw の台帳の行: queued・running は動いている（最後のツールと回数）、succeeded は done（progress_summary）、failed 系は error、cancelled は stopped、blocked は failed", () => {
  assert.deepEqual(openclawLedgerRow({ status: "running", tool_use_count: 2, last_tool_name: "exec" }), { state: "running", text: "exec", toolCalls: 2 });
  assert.equal(openclawLedgerRow({ status: "queued" })?.state, "running");
  assert.deepEqual(openclawLedgerRow(ledgers.openclaw.rows[0]), { state: "done", result: "OK" });
  for (const status of ["failed", "timed_out", "lost"]) assert.deepEqual(openclawLedgerRow({ status, error: "boom" }), { state: "failed", result: "boom" });
  assert.equal(openclawLedgerRow({ status: "cancelled" })?.state, "stopped");
  assert.equal(openclawLedgerRow({ status: "succeeded", terminal_outcome: "blocked", error: "needs approval" })?.state, "failed");
  assert.deepEqual(openclawLedgerRow({ status: "pending-review", last_tool_name: "exec" }), { state: "running", text: "exec", toolCalls: undefined }, "知らない状態は読み取りの失敗にせず、動いているとみなす");
  assert.deepEqual(openclawLedgerRow({ status: "pending-review", ended_at: 5, error: "x" }), { state: "failed", result: "x" }, "知らない状態でも ended_at があれば failed");
  assert.equal(openclawLedgerRow({ status: "succeeded", progressSummary: "camel" })?.result, "camel", "tasks show --json の camelCase も読む");
});

test("読み取り元（native + node:sqlite）: Hermes は state.db、OpenClaw は OPENCLAW_STATE_DIR（無ければ ~/.openclaw）の state/openclaw.sqlite を read-only で読む", { skip: !hasSqlite }, async () => {
  const home = fs.mkdtempSync(path.join(tmp, "sqlite-"));
  await makeLedger(path.join(home, ".hermes", "state.db"), ledgers.hermes, [ledgers.hermes.rows[1]]);
  const hermes = await createLedgerReader("hermes", native, { home });
  assert.equal(hermes.intervalMs, 2000);
  const rows = await hermes.read(["deleg_cbe3a7c4", "deleg_nope"]);
  assert.equal(rows.get("deleg_cbe3a7c4")?.state, "done");
  assert.ok(!rows.has("deleg_nope"));
  assert.equal((await hermes.read([])).size, 0);

  await makeLedger(path.join(home, ".openclaw", "state", "openclaw.sqlite"), ledgers.openclaw, ledgers.openclaw.rows);
  const saved = process.env.OPENCLAW_STATE_DIR;
  delete process.env.OPENCLAW_STATE_DIR;
  try {
    const openclaw = await createLedgerReader("openclaw", native, { home });
    assert.equal(openclaw.intervalMs, 3000);
    const got = await openclaw.read(["4fcca178-5f28-48a1-aed4-9de0fcf4d69c"]);
    assert.deepEqual(got.get("4fcca178-5f28-48a1-aed4-9de0fcf4d69c"), { state: "done", result: "OK" });

    const other = fs.mkdtempSync(path.join(tmp, "oc-state-"));
    process.env.OPENCLAW_STATE_DIR = other;
    const missing = await createLedgerReader("openclaw", native, { home });
    await assert.rejects(missing.read(["x"]), "ファイルが無ければ throw（読めない）");
  } finally {
    if (saved === undefined) delete process.env.OPENCLAW_STATE_DIR;
    else process.env.OPENCLAW_STATE_DIR = saved;
  }
});

test("読み取り元: 表や列が無い台帳は throw する", { skip: !hasSqlite }, async () => {
  const home = fs.mkdtempSync(path.join(tmp, "broken-"));
  await makeLedger(path.join(home, ".hermes", "state.db"), ledgers.hermes, [ledgers.hermes.rows[1]], "event_json");
  const reader = await createLedgerReader("hermes", native, { home });
  await assert.rejects(reader.read(["deleg_cbe3a7c4"]));
});

test("読み取り元（native で node:sqlite が無い）: Hermes は manifest。OpenClaw は tasks show --json を 1 本ずつ", async () => {
  const home = fs.mkdtempSync(path.join(tmp, "manifest-"));
  const dir = path.join(home, ".hermes", "cache", "delegation", "live", "deleg_a");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "manifest.json"), JSON.stringify({ delegation_id: "deleg_a", tasks: [{ status: "completed" }], completed: 1 }));
  const hermes = await createLedgerReader("hermes", native, { home, sqlite: null });
  assert.equal(hermes.intervalMs, 5000);
  const rows = await hermes.read(["deleg_a", "deleg_b", "../escape"]);
  assert.equal(rows.get("deleg_a")?.state, "done");
  assert.equal(rows.size, 1, "manifest が無い鍵・安全でない id は入れない");

  const calls: string[][] = [];
  let running = 0;
  let maxRunning = 0;
  const run: RunText = async (_runtime, args) => {
    calls.push(args);
    running += 1;
    maxRunning = Math.max(maxRunning, running);
    await new Promise((r) => setTimeout(r, 5));
    running -= 1;
    if (args[2] === "bad") throw new Error("exit 1");
    return JSON.stringify({ task: { status: "succeeded", progress_summary: `done ${args[2]}` } });
  };
  const openclaw = await createLedgerReader("openclaw", native, { home, sqlite: null, run });
  assert.equal(openclaw.intervalMs, 10_000);
  const got = await openclaw.read(["r1", "bad", "r2", "r;rm"]);
  assert.deepEqual(calls, [
    ["tasks", "show", "r1", "--json"],
    ["tasks", "show", "bad", "--json"],
    ["tasks", "show", "r2", "--json"]
  ]);
  assert.equal(maxRunning, 1, "1 本ずつ順に");
  assert.equal(got.get("r2")?.result, "done r2");
  assert.ok(!got.has("bad") && !got.has("r;rm"));
});

test("読み取り元（WSL）: Hermes の manifest は sh -c で cat（5 秒）、id は ^[A-Za-z0-9_-]+$ だけ。node:sqlite があっても WSL では使わない", async () => {
  const calls: Array<{ runtime: RuntimeCommand; args: string[]; timeoutMs: number }> = [];
  const run: RunText = async (runtime, args, timeoutMs) => {
    calls.push({ runtime, args, timeoutMs });
    return JSON.stringify({ delegation_id: args[3], tasks: [{ status: "completed" }], completed: 1 });
  };
  const reader = await createLedgerReader("hermes", wsl, { home: tmp, run });
  assert.equal(reader.intervalMs, 5000);
  const rows = await reader.read(["deleg_ok-1", 'a"b', "a b", "$(x)"]);
  assert.equal(rows.get("deleg_ok-1")?.state, "done");
  assert.equal(calls.length, 1, "安全でない id は wsl.exe に渡さない");
  assert.equal(calls[0].runtime.executable, "sh");
  assert.equal(calls[0].runtime.kind, "wsl");
  assert.deepEqual(calls[0].args, ["-c", "cat $HOME/.hermes/cache/delegation/live/$1/manifest.json", "sh", "deleg_ok-1"]);
  assert.equal(calls[0].timeoutMs, 5000);
  assert.ok(!calls[0].args[1].includes('"'));

  const cliCalls: Array<[RuntimeCommand, string[], number]> = [];
  const cli: RunText = async (runtime, args, timeoutMs) => {
    cliCalls.push([runtime, args, timeoutMs]);
    return JSON.stringify({ status: "running", tool_use_count: 1, last_tool_name: "exec" });
  };
  const openclaw = await createLedgerReader("openclaw", { ...wsl, executable: "openclaw" }, { home: tmp, run: cli });
  assert.deepEqual((await openclaw.read(["run-1"])).get("run-1"), { state: "running", text: "exec", toolCalls: 1 });
  assert.equal(cliCalls[0][0].executable, "openclaw");
  assert.deepEqual(cliCalls[0][1], ["tasks", "show", "run-1", "--json"]);
  assert.equal(cliCalls[0][2], 10_000);
});

// ---- 見張り ----

function fakeReader(read: LedgerReader["read"]): () => Promise<LedgerReader> {
  return async () => ({ intervalMs: 5, read });
}

async function until(cond: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 300 && !cond(); i += 1) await new Promise((r) => setTimeout(r, 10));
  assert.ok(cond(), label);
}

test("見張り: 1 回目で読めなければ unreadable（読めるかは 1 回目の読み取りで決める）。鍵が無い・台帳が throw も同じ", async () => {
  const seen: string[] = [];
  const sink = { row: () => seen.push("row"), unreadable: (k: string) => seen.push(`unreadable:${k}`) };
  const absent = new LedgerWatcher(fakeReader(async () => new Map()), sink);
  absent.add("a");
  const broken = new LedgerWatcher(fakeReader(async () => { throw new Error("no such table"); }), sink);
  broken.add("b");
  await until(() => seen.length === 2, "両方 unreadable");
  assert.deepEqual(seen.sort(), ["unreadable:a", "unreadable:b"]);
});

test("見張り: 動いている鍵をまとめて 1 回で読み、終わりの行を渡した鍵は見張りから外れ、全部終われば止まる", async () => {
  const reads: string[][] = [];
  let phase = 0;
  const reader = fakeReader(async (keys) => {
    reads.push([...keys]);
    const out = new Map<string, LedgerRow>();
    for (const k of keys) out.set(k, k === "a" && phase >= 1 ? { state: "done", result: "A" } : k === "b" && phase >= 2 ? { state: "failed" } : { state: "running" });
    return out;
  });
  const got: Array<[string, string]> = [];
  const watcher = new LedgerWatcher(reader, { row: (k, r) => got.push([k, r.state]), unreadable: () => assert.fail("読めるはず") });
  watcher.add("a");
  watcher.add("b");
  await until(() => got.length >= 2, "1 回目");
  await until(() => reads.some((r) => r.length === 2), "まとめて読む");
  phase = 1;
  await until(() => got.some(([k, s]) => k === "a" && s === "done"), "a が done");
  const afterA = reads.length;
  await until(() => reads.length > afterA, "続けて読む");
  assert.deepEqual(reads.at(-1), ["b"], "終わった鍵は読まない");
  phase = 2;
  await until(() => got.some(([k, s]) => k === "b" && s === "failed"), "b が failed");
  const total = reads.length;
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(reads.length, total, "全部終わったら止まる");
});

test("見張り: 前の読み取りが終わっていなければその回は飛ばす（重ならない）", async () => {
  let inFlight = 0;
  let maxInFlight = 0;
  let calls = 0;
  const reader = fakeReader(async (keys) => {
    calls += 1;
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    await new Promise((r) => setTimeout(r, 40));
    inFlight -= 1;
    return new Map(keys.map((k) => [k, { state: "running" as const }]));
  });
  const watcher = new LedgerWatcher(reader, { row: () => {}, unreadable: () => assert.fail() });
  watcher.add("a");
  await until(() => calls >= 3, "3 回読む");
  watcher.stop();
  assert.equal(maxInFlight, 1);
});

test("見張り: 1 回目の読み取りも 1 本ずつ順に読む（複数の受領票を同時に読まない）", async () => {
  let inFlight = 0;
  let maxInFlight = 0;
  let total = 0;
  const reader = fakeReader(async (keys) => {
    total += 1;
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    await new Promise((r) => setTimeout(r, 30));
    inFlight -= 1;
    return new Map(keys.map((k) => [k, { state: "running" as const }]));
  });
  const got: string[] = [];
  const watcher = new LedgerWatcher(reader, { row: (k) => got.push(k), unreadable: () => assert.fail() });
  watcher.add("a");
  watcher.add("b");
  watcher.add("c");
  await until(() => got.length >= 3, "3 本の 1 回目");
  watcher.stop();
  assert.equal(maxInFlight, 1);
  assert.ok(total >= 3);
});

test("見張り: 読み取りの失敗は次の回にやり直し、30 回続けて失敗したら unreadable。成功すれば数え直し", async () => {
  assert.equal(delegationTiming.maxFailures, 30);
  let calls = 0;
  let failFrom = 2; // 1 回目は成功、2 回目から失敗
  const reader = fakeReader(async (keys) => {
    calls += 1;
    if (calls >= failFrom) throw new Error("database is locked");
    return new Map(keys.map((k) => [k, { state: "running" as const }]));
  });
  const unreadable: string[] = [];
  const watcher = new LedgerWatcher(reader, { row: () => {}, unreadable: (k) => unreadable.push(k) });
  watcher.add("a");
  await until(() => unreadable.length === 1, "30 回続けて失敗");
  assert.equal(calls, 1 + 30, "1 回目の成功のあと 30 回");

  // 29 回失敗したあとの成功で数え直す。
  calls = 0;
  failFrom = 2;
  const flaky = fakeReader(async (keys) => {
    calls += 1;
    if (calls >= 2 && calls <= 30) throw new Error("busy"); // 29 回
    return new Map(keys.map((k) => [k, { state: "running" as const }]));
  });
  const second: string[] = [];
  const w2 = new LedgerWatcher(flaky, { row: () => {}, unreadable: (k) => second.push(k) });
  w2.add("b");
  await until(() => calls >= 35, "29 回の失敗のあとも続く");
  w2.stop();
  assert.deepEqual(second, [], "29 回なら読めないとみなさない");
});

test("見張り: stop() のあとは何も流さず、remove した鍵は読まない", async () => {
  const reads: string[][] = [];
  const reader = fakeReader(async (keys) => {
    reads.push([...keys]);
    return new Map(keys.map((k) => [k, { state: "running" as const }]));
  });
  const got: string[] = [];
  const watcher = new LedgerWatcher(reader, { row: (k) => got.push(k), unreadable: () => {} });
  watcher.add("a");
  watcher.add("b");
  await until(() => reads.some((r) => r.length === 2), "2 本");
  watcher.remove("a");
  await until(() => reads.at(-1)?.length === 1, "a を読まない");
  assert.deepEqual(reads.at(-1), ["b"]);
  watcher.stop();
  const n = got.length;
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(got.length, n);
});
