import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import type { AgentAdapter, AgentSession, Emit } from "../agents/types.js";
import { event, type SessionEvent } from "../protocol.js";
import { openclawAddArgs, openclawJobs, hermesJobs } from "./nativeCron.js";
import { CronOutputHub, isSilentCronOutput, parseCronOutputFile } from "./outputHub.js";
import { BridgeCronScheduler, normalizeCronCwd, TurnCollector } from "./scheduler.js";
import { codexExecArgs } from "../agents/codexHistory.js";
import { cronJitterSeconds, nextCronFire, parseCronExpression, parseSchedule } from "./schedule.js";

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-cron-"));

test("間隔の書き方を読み、60 秒未満は 60 秒に揃える", () => {
  assert.deepEqual(parseSchedule("30m"), { kind: "interval", seconds: 1800 });
  assert.deepEqual(parseSchedule("every 2 h"), { kind: "interval", seconds: 7200 });
  assert.deepEqual(parseSchedule("10s"), { kind: "interval", seconds: 60 });
  assert.equal(parseSchedule("every"), undefined);
  assert.equal(parseSchedule("0m"), undefined);
});

test("cron 式: 範囲・刻み・曜日の 7、名前は不可", () => {
  const e = parseCronExpression("*/15 9-17 * * 1-5");
  assert.ok(e);
  assert.deepEqual([...e.minutes], [0, 15, 30, 45]);
  assert.equal(e.hours.size, 9);
  assert.ok(parseCronExpression("0 0 * * 7")?.weekdays.has(0));
  assert.deepEqual([...parseCronExpression("5/20 * * * *")!.minutes], [5, 25, 45]);
  assert.equal(parseCronExpression("0 0 * * MON"), undefined);
  assert.equal(parseCronExpression("60 * * * *"), undefined);
  assert.equal(parseCronExpression("* * * *"), undefined);
});

test("次の発火はローカル時刻で、after より厳密に後", () => {
  const e = parseCronExpression("30 9 * * *")!;
  const after = new Date(2026, 9, 8, 9, 30, 0);
  assert.equal(nextCronFire(e, after)?.getTime(), new Date(2026, 9, 9, 9, 30, 0).getTime());
  assert.equal(nextCronFire(e, new Date(2026, 9, 8, 8, 0, 0))?.getTime(), new Date(2026, 9, 8, 9, 30, 0).getTime());
});

test("日と曜日の両方を指定したら、どちらかが合えば発火（vixie cron）", () => {
  const e = parseCronExpression("0 0 1 * 1")!; // 毎月 1 日 または 月曜
  // 2026-10-05 は月曜
  assert.equal(nextCronFire(e, new Date(2026, 9, 2, 0, 0, 0))?.getTime(), new Date(2026, 9, 5, 0, 0, 0).getTime());
});

test("ずらしは id ごとに決まり、短い間隔では小さい", () => {
  const s = parseSchedule("5m")!;
  assert.equal(cronJitterSeconds("abcd1234", s), cronJitterSeconds("abcd1234", s));
  assert.ok(cronJitterSeconds("abcd1234", s) < 30);
  assert.equal(cronJitterSeconds("x", parseSchedule("60s")!) < 6, true);
});

function fakeAdapter(id: string, reply: (emit: Emit, sessionId: string) => void, seen: { options?: unknown }[]): AgentAdapter {
  return {
    id,
    displayName: id,
    runtimeLabel: `native:${id}`,
    openSession: async (_sid, _cwd, options) => {
      seen.push({ options });
      const session: AgentSession = {
        sessionId: "pending-1",
        send: async (_text, _evt, emit) => {
          session.sessionId = "real-1";
          reply(emit, "real-1");
        },
        close: async () => {}
      };
      return session;
    },
    listSessions: async () => [],
    loadHistory: async () => [],
    renameSession: async () => false,
    listCommands: async () => [],
    currentInfo: async () => undefined,
    setModel: async () => {},
    listAvailableModels: async () => []
  };
}

test("期限のジョブを無人の新規セッションで 1 ターン動かし、結果を書く", async () => {
  const root = tmp();
  const seen: { options?: unknown }[] = [];
  const adapter = fakeAdapter("claude", (emit, sid) => {
    emit(event.sessionStarted("claude", sid));
    emit(event.assistantDelta("claude", sid, "m", "こんにちは"));
    emit(event.done("claude", sid, "m"));
  }, seen);
  const sched = new BridgeCronScheduler({ root, adapterFor: () => adapter, tickMs: 60_000 });
  const id = sched.create("claude", { name: "朝", schedule: "1m", prompt: "おはよう", permissionMode: "plan", repeatCount: 1 });
  // 作成直後は期限前。作成時刻を過去にずらして期限にする。
  const jobs = JSON.parse(fs.readFileSync(path.join(root, "jobs.json"), "utf8"));
  jobs[0].createdAt = new Date(Date.now() - 10 * 60_000).toISOString();
  fs.writeFileSync(path.join(root, "jobs.json"), JSON.stringify(jobs));
  const sched2 = new BridgeCronScheduler({ root, adapterFor: () => adapter, tickMs: 60_000 });
  await sched2.runDueNow();
  assert.deepEqual(seen[0].options, { permissionMode: "plan", unattended: true });
  const [summary] = sched2.list("claude");
  assert.equal(summary.lastStatus, "ok");
  assert.equal(summary.enabled, false, "repeat=1 なので 1 回で止まる");
  const files = fs.readdirSync(path.join(root, "output", id));
  assert.equal(files.length, 1);
  const evt = parseCronOutputFile(path.join(root, "output", id, files[0]))!;
  assert.equal(evt.content, "こんにちは");
  assert.equal(evt.metadata?.jobName, "朝");
  assert.equal(evt.metadata?.continuableSessionId, "real-1");
  assert.equal(evt.agentId, "claude");
});

test("error だけで done を出さない adapter でも結果を書いて終わる", async () => {
  const root = tmp();
  const adapter = fakeAdapter("codex", (emit, sid) => emit(event.error("codex", sid, "boom")), []);
  const sched = new BridgeCronScheduler({ root, adapterFor: () => adapter, tickMs: 60_000 });
  sched.create("codex", { schedule: "1m", prompt: "x" });
  const jobs = JSON.parse(fs.readFileSync(path.join(root, "jobs.json"), "utf8"));
  jobs[0].createdAt = new Date(Date.now() - 10 * 60_000).toISOString();
  fs.writeFileSync(path.join(root, "jobs.json"), JSON.stringify(jobs));
  const s2 = new BridgeCronScheduler({ root, adapterFor: () => adapter, tickMs: 60_000 });
  const started = Date.now();
  await s2.runDueNow();
  assert.ok(Date.now() - started < 15_000);
  assert.equal(s2.list("codex")[0].lastStatus, "error");
});

test("作成の検証と、他エージェントのジョブは操作できない", () => {
  const sched = new BridgeCronScheduler({ root: tmp(), adapterFor: () => undefined });
  assert.throws(() => sched.create("claude", { schedule: "sometimes", prompt: "x" }), /unsupported schedule/);
  assert.throws(() => sched.create("claude", { schedule: "1h", prompt: "  " }), /prompt is required/);
  const id = sched.create("claude", { schedule: "1h", prompt: "x" });
  assert.throws(() => sched.delete("codex", id), /job not found/);
  sched.setEnabled("claude", id, false);
  assert.equal(sched.list("claude")[0].state, "paused");
  assert.equal(sched.list("claude")[0].nextRunAt, undefined);
});

test("出力の見張り: 起動時にあった分は流さず、新しい分を配って push、silent は配らない", () => {
  const root = tmp();
  const outputs = path.join(root, "output");
  const job = path.join(outputs, "job1");
  fs.mkdirSync(job, { recursive: true });
  const stamp = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}_${String(d.getHours()).padStart(2, "0")}-${String(d.getMinutes()).padStart(2, "0")}-${String(d.getSeconds()).padStart(2, "0")}`;
  fs.writeFileSync(path.join(job, "2020-01-01_00-00-00.md"), "# 古い\nagent: claude\nstatus: ok\n---\nold\n");
  const pushes: Record<string, string>[] = [];
  const hub = new CronOutputHub(outputs, (_t, _b, data) => pushes.push(data), path.join(root, "seen.json"));
  const got: SessionEvent[] = [];
  hub.register((e) => got.push(e));
  hub.start();
  hub.stop();
  const now = new Date();
  fs.writeFileSync(path.join(job, `${stamp(now)}.md`), "# 新しい\nagent: codex\nstatus: ok\nsession: s1\n---\nnew\n");
  fs.writeFileSync(path.join(job, `${stamp(new Date(now.getTime() - 1000))}.md`), "# 黙る\nagent: hermes\nstatus: ok\n---\n[SILENT]\n");
  hub.poll();
  assert.equal(got.length, 1);
  assert.equal(got[0].content, "new");
  assert.equal(got[0].agentId, "codex");
  assert.deepEqual(pushes, [{ kind: "cron_output", jobId: "job1", timestamp: stamp(now), sessionId: "s1" }]);
  hub.poll();
  assert.equal(got.length, 1, "同じファイルは二度配らない");
  const past = hub.loadPast("job1");
  assert.deepEqual(past.map((e) => e.content), ["new", "old"]);
});

test("silent は Hermes の出力で、Hermes 本体と同じ印のときだけ（mac と同じ判定）", () => {
  assert.equal(isSilentCronOutput("[SILENT]", "hermes"), true);
  assert.equal(isSilentCronOutput("  [silent]\n", "hermes"), true);
  assert.equal(isSilentCronOutput("## Prompt\nx\n## Response\n[SILENT]", "hermes"), true);
  assert.equal(isSilentCronOutput("## Response\n[SILENT] 変化なし", "hermes"), true);
  assert.equal(isSilentCronOutput("## Response\n*NO_REPLY*", "hermes"), true);
  assert.equal(isSilentCronOutput("## Response\n確認しました\nSILENT", "hermes"), true);
  assert.equal(isSilentCronOutput("**Status:** silent\n## Response\nnothing", "hermes"), true);
  // 他のエージェント・本文に含まれるだけ・応答の中の Status 行は配る
  assert.equal(isSilentCronOutput("[SILENT]", "codex"), false);
  assert.equal(isSilentCronOutput("[SILENT]", "claude"), false);
  assert.equal(isSilentCronOutput("ファイルを消しました [SILENT]", "hermes"), false);
  assert.equal(isSilentCronOutput("## Response\n消しました\n**Status:** silent\n以上", "hermes"), false);
  assert.equal(isSilentCronOutput("the status:** silent part", "hermes"), false);
  assert.equal(isSilentCronOutput("## Response\n", "hermes"), false);
});

test("作業フォルダ: 空欄はホーム、/・ドライブ直下・Windows のフォルダ・無いフォルダ・相対パスは断る", () => {
  const home = tmp();
  assert.equal(normalizeCronCwd(undefined, home, "linux"), home);
  assert.equal(normalizeCronCwd("   ", home, "linux"), home);
  assert.equal(normalizeCronCwd(home + "/", home, "linux"), home);
  assert.throws(() => normalizeCronCwd("/", home, "linux"), /動かせません/);
  assert.throws(() => normalizeCronCwd("/usr/local", home, "linux"), /動かせません/);
  assert.throws(() => normalizeCronCwd("relative/dir", home, "linux"), /フルパス/);
  assert.throws(() => normalizeCronCwd(path.join(home, "missing"), home, "linux"), /見つかりません/);
  // Windows
  assert.throws(() => normalizeCronCwd("C:\\", "C:\\Users\\u", "win32"), /動かせません/);
  assert.throws(() => normalizeCronCwd("c:/", "C:\\Users\\u", "win32"), /動かせません/);
  assert.throws(() => normalizeCronCwd("C:\\Windows\\System32", "C:\\Users\\u", "win32"), /動かせません/);
  assert.throws(() => normalizeCronCwd("work", "C:\\Users\\u", "win32"), /フルパス/);
  // WSL のパスは Windows からは見えないので形だけ見る
  assert.equal(normalizeCronCwd("/home/u/proj", "C:\\Users\\u", "win32"), "/home/u/proj");
  assert.throws(() => normalizeCronCwd("/", "C:\\Users\\u", "win32"), /動かせません/);
  assert.throws(() => normalizeCronCwd("/mnt/c", "C:\\Users\\u", "win32"), /動かせません/);
  assert.throws(() => normalizeCronCwd("/mnt/c/Windows/System32", "C:\\Users\\u", "win32"), /動かせません/);
  // リンクの先が断るフォルダなら断る
  if (process.platform !== "win32") {
    fs.symlinkSync("/usr", path.join(home, "to-usr"));
    assert.throws(() => normalizeCronCwd(path.join(home, "to-usr"), home, "linux"), /動かせません/);
  }
});

test("作業フォルダを空欄で作ったジョブはホームで動く", async () => {
  const root = tmp();
  const cwds: Array<string | undefined> = [];
  const adapter: AgentAdapter = {
    ...fakeAdapter("codex", (emit, sid) => emit(event.done("codex", sid, "m")), []),
    openSession: async (_sid, cwd) => {
      cwds.push(cwd);
      return { sessionId: "s", send: async (_t, _e, emit) => emit(event.done("codex", "s", "m")), close: async () => {} };
    }
  };
  const sched = new BridgeCronScheduler({ root, adapterFor: () => adapter, tickMs: 60_000 });
  assert.throws(() => sched.create("codex", { schedule: "1m", prompt: "x", cwd: "/" }), /動かせません/);
  sched.create("codex", { schedule: "1m", prompt: "x" });
  const jobs = JSON.parse(fs.readFileSync(path.join(root, "jobs.json"), "utf8"));
  assert.equal(jobs[0].cwd, os.homedir());
  // 以前の版で cwd なしに保存されたジョブもホームで動かす
  delete jobs[0].cwd;
  jobs[0].createdAt = new Date(Date.now() - 10 * 60_000).toISOString();
  fs.writeFileSync(path.join(root, "jobs.json"), JSON.stringify(jobs));
  const s2 = new BridgeCronScheduler({ root, adapterFor: () => adapter, tickMs: 60_000 });
  await s2.runDueNow();
  assert.deepEqual(cwds, [os.homedir()]);
});

test("Hermes / OpenClaw の一覧の読み取りと add の引数", () => {
  const h = hermesJobs({ jobs: [{ id: "a", name: "n", schedule: { display: "every 1h" }, enabled: false, next_run_at: "x" }, { id: "b" }] });
  assert.equal(h.length, 1);
  assert.equal(h[0].scheduleDisplay, "every 1h");
  assert.equal(h[0].enabled, false);
  const o = openclawJobs({ jobs: [{ id: "j", description: "d", enabled: false, schedule: { kind: "every", everyMs: 3_600_000 }, payload: { message: "p" } }] });
  assert.equal(o[0].name, "d");
  assert.equal(o[0].state, "paused");
  assert.equal(o[0].scheduleDisplay, "every 1h");
  assert.deepEqual(openclawAddArgs({ schedule: "0 9 * * *", prompt: "p", repeatCount: 1, deliver: "announce" }), [
    "cron", "add", "--json", "--cron", "0 9 * * *", "--announce", "--delete-after-run", "p"
  ]);
  assert.deepEqual(openclawAddArgs({ schedule: "every 30m", prompt: "p" }).slice(3, 5), ["--every", "30m"]);
});

test("Codex の無人実行は作業フォルダを -C で明示する（新規・再開とも）", () => {
  assert.deepEqual(codexExecArgs(undefined, "C:\\w", ["-c", "x"]), ["exec", "-C", "C:\\w", "--json", "--skip-git-repo-check", "-c", "x", "-"]);
  assert.deepEqual(codexExecArgs("pending-1", "/home/u/p", []), ["exec", "-C", "/home/u/p", "--json", "--skip-git-repo-check", "-"]);
  assert.deepEqual(codexExecArgs("abc", "/home/u/p", []), ["exec", "-C", "/home/u/p", "resume", "--json", "--skip-git-repo-check", "abc", "-"]);
  assert.deepEqual(codexExecArgs(undefined, undefined, []), ["exec", "--json", "--skip-git-repo-check", "-"]);
});

test("jobs.json が壊れていたら退避してから空で始め、元の中身は消さない", () => {
  const root = tmp();
  fs.writeFileSync(path.join(root, "jobs.json"), "[{ 途中で切れた");
  const sched = new BridgeCronScheduler({ root, adapterFor: () => undefined });
  assert.deepEqual(sched.list("claude"), []);
  const backups = fs.readdirSync(root).filter((f) => f.startsWith("jobs.json.broken-"));
  assert.equal(backups.length, 1);
  assert.equal(fs.readFileSync(path.join(root, backups[0]), "utf8"), "[{ 途中で切れた");
  // 退避できたので新しいジョブは保存できる
  sched.create("claude", { schedule: "1h", prompt: "x" });
  assert.equal(JSON.parse(fs.readFileSync(path.join(root, "jobs.json"), "utf8")).length, 1);
});

test("jobs.json を読めない（ロック・権限）間は保存しない。読めるようになったら続きから", { skip: process.platform === "win32" || process.getuid?.() === 0 }, () => {
  const root = tmp();
  const file = path.join(root, "jobs.json");
  const job = { id: "j1", agentId: "claude", name: "朝", prompt: "おはよう", schedule: "1h", deliver: "local", enabled: true, createdAt: new Date().toISOString(), runsCompleted: 0 };
  fs.writeFileSync(file, JSON.stringify([job]));
  fs.chmodSync(file, 0o000);
  const sched = new BridgeCronScheduler({ root, adapterFor: () => undefined });
  try {
    assert.deepEqual(sched.list("claude"), []);
    assert.throws(() => sched.create("claude", { schedule: "1h", prompt: "y" }), /読めませんでした/);
  } finally {
    fs.chmodSync(file, 0o600);
  }
  assert.equal(JSON.parse(fs.readFileSync(file, "utf8"))[0].id, "j1", "元のファイルは上書きしていない");
  sched.create("claude", { schedule: "1h", prompt: "y" });
  assert.deepEqual(sched.list("claude").map((j) => j.name).sort(), ["job-" + JSON.parse(fs.readFileSync(file, "utf8"))[1].id, "朝"].sort());
});

test("jobs.json は要素ごとに読み、読めない要素は捨てずに保存し直す", () => {
  const root = tmp();
  const file = path.join(root, "jobs.json");
  const good = { id: "g1", agentId: "claude", prompt: "おはよう", schedule: "1h" };
  const bad = { id: "b1", agentId: "claude", schedule: 42 };
  fs.writeFileSync(file, JSON.stringify([good, bad, "壊れた"]));
  const sched = new BridgeCronScheduler({ root, adapterFor: () => undefined });
  const [summary] = sched.list("claude");
  assert.equal(sched.list("claude").length, 1);
  assert.equal(summary.name, "job-g1", "足りない項目は既定で補う");
  assert.equal(summary.enabled, true);
  sched.setEnabled("claude", "g1", false);
  const saved = JSON.parse(fs.readFileSync(file, "utf8")) as unknown[];
  assert.equal(saved.length, 3);
  assert.deepEqual(saved.slice(1), [bad, "壊れた"]);
});

test("TurnCollector: バックグラウンドの作業が動いている間は done で抜けず、最後の空でないターンを結果にする", () => {
  const c = new TurnCollector();
  const card = (status: string, state: string): SessionEvent => ({
    type: "workflow_progress",
    content: JSON.stringify({
      subtype: "task_progress",
      taskId: "subagents",
      kind: "subagents",
      status,
      agents: [{ index: 0, id: "a", rowKind: "agent", state }]
    })
  });
  assert.equal(c.ingest(card("running", "running")), false);
  assert.equal(c.ingest({ type: "assistant_delta", content: "起動した" }), false);
  assert.equal(c.ingest({ type: "done" }), false, "サブエージェントが動いている間は集め続ける");
  assert.equal(c.waitingForBackground, true);
  assert.equal(c.ingest(card("completed", "done")), false);
  assert.equal(c.ingest({ type: "assistant_delta", content: "結果" }), false);
  assert.equal(c.ingest({ type: "done", metadata: { origin: "task-notification" } }), true);
  assert.equal(c.text, "結果");
});
