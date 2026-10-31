import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { killProcessTree, spawnRuntime, type RuntimeCommand } from "../runtime/command.js";

/**
 * ACP の非同期の委任の本当の終わり（docs/BACKGROUND_CONTROL_2026-10-21.md §5）。受領票の読み取り、Hermes・OpenClaw の台帳、
 * 台帳の見張り。台帳が読めないときは何も足さない（受領票の時点で行を閉じる、今まで通りの動き）。
 */

export type LedgerKind = "hermes" | "openclaw";
export type LedgerState = "running" | "done" | "failed" | "stopped";

/** 台帳の 1 件。running のときの text と toolCalls は、行のいまの作業。 */
export interface LedgerRow {
  state: LedgerState;
  result?: string;
  durationMs?: number;
  text?: string;
  toolCalls?: number;
}

export interface LedgerReader {
  /** 見張りの間隔（ミリ秒） */
  readonly intervalMs: number;
  /** 鍵をまとめて読む。見つからない鍵は結果に入れない。台帳そのものが読めないときは throw。 */
  read(keys: string[]): Promise<Map<string, LedgerRow>>;
}

type Obj = Record<string, unknown>;

/** 見張りの回数と間隔の上書き（テストが短くする）。 */
export const delegationTiming = { intervalMs: undefined as number | undefined, maxFailures: 30 };

const HERMES_SQLITE_MS = 2000;
const HERMES_MANIFEST_MS = 5000;
const OPENCLAW_SQLITE_MS = 3000;
const OPENCLAW_CLI_MS = 10_000;
const HERMES_WSL_TIMEOUT_MS = 5000;
const OPENCLAW_CLI_TIMEOUT_MS = 10_000;
const SAFE_ID = /^[A-Za-z0-9_-]+$/;

// ---- 受領票 ----

/** Grok の背景の spawn の受領票（`Subagent started in background.\nsubagent_id: <id>`）の subagent_id。 */
export function grokReceiptKey(text: string | undefined): string | undefined {
  if (!text || !/started in background/i.test(text)) return undefined;
  return /subagent_id:\s*(\S+)/.exec(text)?.[1];
}

/** Hermes の delegate_task の受領票。status が dispatched で、action（list / steer / stop）も results（同期の経路）も無いとき。 */
export function hermesReceipt(text: string | undefined): { key: string; taskCount?: number } | undefined {
  const o = parseObject(text);
  if (!o || o.status !== "dispatched" || o.action !== undefined || o.results !== undefined) return undefined;
  const key = typeof o.delegation_id === "string" ? o.delegation_id : undefined;
  if (!key) return undefined;
  return { key, taskCount: typeof o.count === "number" ? o.count : undefined };
}

/** OpenClaw の sessions_spawn の受領票。rawOutput.details（無ければ本文の JSON）が accepted・run・expectsCompletionMessage。 */
export function openclawReceipt(details: unknown, text: string | undefined): { key: string } | undefined {
  const o = asObject(details) ?? parseObject(text);
  if (!o || o.status !== "accepted" || o.mode !== "run" || o.expectsCompletionMessage !== true) return undefined;
  return typeof o.runId === "string" && o.runId ? { key: o.runId } : undefined;
}

// ---- 台帳の行の読み方 ----

/** Hermes の async_delegations の 1 行。 */
export function hermesLedgerRow(row: Obj): LedgerRow {
  const state = hermesState(String(row.state ?? ""), row.completed_at ?? row.completedAt);
  if (state === "running") return { state };
  const event = parseObject(typeof row.event_json === "string" ? row.event_json : undefined) ?? {};
  const results = Array.isArray(event.results) ? event.results.map(asObject).filter((r): r is Obj => r !== undefined) : [];
  const parts = (results.length > 0 ? results.map((r) => nonEmpty(r.summary) ?? nonEmpty(r.error)) : [nonEmpty(event.summary) ?? nonEmpty(event.error)]).filter(
    (p): p is string => p !== undefined
  );
  const seconds = number(event.total_duration_seconds) ?? number(event.duration_seconds);
  return {
    state,
    result: parts.length > 0 ? parts.join("\n\n") : undefined,
    durationMs: seconds !== undefined ? Math.round(seconds * 1000) : undefined
  };
}

function hermesState(state: string, completedAt?: unknown): LedgerState {
  switch (state) {
    case "running":
    case "stalling":
    case "finalizing":
      return "running";
    case "completed":
      return "done";
    case "interrupted":
    case "cancelled":
      return "stopped";
    case "error":
    case "stalled":
    case "unknown":
      return "failed";
    default:
      // 知らない state（queued・将来の版）は、completed_at があるときだけ終わり。無ければ動いているとみなす。
      return completedAt != null ? "failed" : "running";
  }
}

/** Hermes の manifest（`{delegation_id, task_count, tasks:[{status, exit_reason}], completed?}`）。最上位の completed が終わりの印。結果は無い。 */
export function hermesManifestRow(text: string): LedgerRow | undefined {
  const m = parseObject(text);
  if (!m) return undefined;
  if (!m.completed) return { state: "running" };
  const statuses = (Array.isArray(m.tasks) ? m.tasks : []).map((t) => String(asObject(t)?.status ?? ""));
  if (statuses.some((s) => s === "error" || s === "stalled" || s === "unknown")) return { state: "failed" };
  if (statuses.length > 0 && statuses.every((s) => s === "completed")) return { state: "done" };
  return { state: "stopped" };
}

/** OpenClaw の task_runs の 1 行（列名は snake_case。`tasks show --json` の camelCase も受ける）。 */
export function openclawLedgerRow(row: Obj): LedgerRow | undefined {
  const pick = (snake: string): unknown => row[snake] ?? row[snake.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase())];
  const status = String(pick("status") ?? "");
  if (status === "queued" || status === "running") {
    return { state: "running", text: nonEmpty(pick("last_tool_name")), toolCalls: number(pick("tool_use_count")) };
  }
  if (pick("terminal_outcome") === "blocked") return { state: "failed", result: nonEmpty(pick("error")) ?? nonEmpty(pick("progress_summary")) };
  switch (status) {
    case "succeeded":
      return { state: "done", result: nonEmpty(pick("progress_summary")) };
    case "failed":
    case "timed_out":
    case "lost":
      return { state: "failed", result: nonEmpty(pick("error")) };
    case "cancelled":
      return { state: "stopped", result: nonEmpty(pick("error")) };
    default:
      // 知らない status は読み取りの失敗にしない。終わっていれば failed、そうでなければ running のまま見る。
      if (pick("ended_at") != null) return { state: "failed", result: nonEmpty(pick("error")) ?? nonEmpty(pick("progress_summary")) };
      return { state: "running", text: nonEmpty(pick("last_tool_name")), toolCalls: number(pick("tool_use_count")) };
  }
}

// ---- 読み取り ----

export interface SqliteDb {
  prepare(sql: string): { all(...params: unknown[]): Array<Obj> };
  close(): void;
}
export type SqliteCtor = new (file: string, options?: Obj) => SqliteDb;

/** node:sqlite（Node 22.13 以降は旗なしで使える）。無い Node では undefined。 */
export async function loadSqlite(): Promise<SqliteCtor | undefined> {
  try {
    const spec = "node:sqlite";
    return ((await import(spec)) as { DatabaseSync: SqliteCtor }).DatabaseSync;
  } catch {
    return undefined;
  }
}

/** 外部コマンドの標準出力（失敗・時間切れは throw） */
export type RunText = (runtime: RuntimeCommand, args: string[], timeoutMs: number) => Promise<string>;

export interface LedgerDeps {
  /** undefined は読み込みを試す。null は node:sqlite が無い Node として扱う。 */
  sqlite?: SqliteCtor | null;
  home?: string;
  run?: RunText;
}

export async function createLedgerReader(kind: LedgerKind, runtime: RuntimeCommand, deps: LedgerDeps = {}): Promise<LedgerReader> {
  const run = deps.run ?? runText;
  // WSL の台帳は Linux 側のファイルなので、Windows の node:sqlite では読めない。
  const sqlite = runtime.kind === "wsl" ? undefined : deps.sqlite === null ? undefined : (deps.sqlite ?? (await loadSqlite()));
  const home = deps.home ?? os.homedir();
  if (kind === "hermes") {
    if (sqlite) return hermesSqliteReader(sqlite, path.join(home, ".hermes", "state.db"));
    return hermesManifestReader(runtime, home, run);
  }
  if (sqlite) {
    const dir = process.env.OPENCLAW_STATE_DIR?.trim() || path.join(home, ".openclaw");
    return openclawSqliteReader(sqlite, path.join(dir, "state", "openclaw.sqlite"));
  }
  return openclawCliReader(runtime, run);
}

function hermesSqliteReader(Db: SqliteCtor, file: string): LedgerReader {
  return {
    intervalMs: HERMES_SQLITE_MS,
    async read(keys) {
      const out = new Map<string, LedgerRow>();
      if (keys.length === 0) return out;
      const rows = withDb(Db, file, (db) =>
        db.prepare(`SELECT delegation_id, state, completed_at, event_json FROM async_delegations WHERE delegation_id IN (${keys.map(() => "?").join(", ")})`).all(...keys)
      );
      for (const row of rows) out.set(String(row.delegation_id), hermesLedgerRow(row));
      return out;
    }
  };
}

function openclawSqliteReader(Db: SqliteCtor, file: string): LedgerReader {
  return {
    intervalMs: OPENCLAW_SQLITE_MS,
    async read(keys) {
      const out = new Map<string, LedgerRow>();
      if (keys.length === 0) return out;
      const rows = withDb(Db, file, (db) =>
        db
          .prepare(
            `SELECT run_id, status, ended_at, progress_summary, error, terminal_outcome, tool_use_count, last_tool_name FROM task_runs WHERE run_id IN (${keys.map(() => "?").join(", ")})`
          )
          .all(...keys)
      );
      for (const row of rows) {
        const parsed = openclawLedgerRow(row);
        if (parsed) out.set(String(row.run_id), parsed);
      }
      return out;
    }
  };
}

/** read-only で開き、毎回閉じる。書かない。 */
function withDb<T>(Db: SqliteCtor, file: string, use: (db: SqliteDb) => T): T {
  const db = new Db(file, { readOnly: true });
  try {
    return use(db);
  } finally {
    db.close();
  }
}

/** node:sqlite が無い Hermes は manifest。WSL は wsl.exe の引数に " を入れないよう、id を検査してから sh で cat する。 */
function hermesManifestReader(runtime: RuntimeCommand, home: string, run: RunText): LedgerReader {
  return {
    intervalMs: HERMES_MANIFEST_MS,
    async read(keys) {
      const out = new Map<string, LedgerRow>();
      for (const key of keys) {
        if (!SAFE_ID.test(key)) continue;
        try {
          const text =
            runtime.kind === "wsl"
              ? await run({ ...runtime, executable: "sh" }, ["-c", "cat $HOME/.hermes/cache/delegation/live/$1/manifest.json", "sh", key], HERMES_WSL_TIMEOUT_MS)
              : fs.readFileSync(path.join(home, ".hermes", "cache", "delegation", "live", key, "manifest.json"), "utf8");
          const row = hermesManifestRow(text);
          if (row) out.set(key, row);
        } catch {
          // その鍵は読めなかった（見張りが数える）
        }
      }
      return out;
    }
  };
}

/** WSL と node:sqlite が無いときの OpenClaw。`openclaw tasks show <runId> --json` を 1 本ずつ順に読む。 */
function openclawCliReader(runtime: RuntimeCommand, run: RunText): LedgerReader {
  return {
    intervalMs: OPENCLAW_CLI_MS,
    async read(keys) {
      const out = new Map<string, LedgerRow>();
      for (const key of keys) {
        if (!SAFE_ID.test(key)) continue;
        try {
          const o = parseObject(await run(runtime, ["tasks", "show", key, "--json"], OPENCLAW_CLI_TIMEOUT_MS));
          const row = o ? openclawLedgerRow(asObject(o.task) ?? o) : undefined;
          if (row) out.set(key, row);
        } catch {
          // その鍵は読めなかった（見張りが数える）
        }
      }
      return out;
    }
  };
}

/** spawnRuntime で動かして標準出力を返す。時間切れは子孫ごと止める。 */
export const runText: RunText = (runtime, args, timeoutMs) =>
  new Promise((resolve, reject) => {
    let child: ReturnType<typeof spawn>;
    try {
      child = spawnRuntime(runtime, args, { stdio: "pipe", cwd: runtime.kind === "wsl" ? undefined : os.homedir() });
    } catch (error) {
      reject(error);
      return;
    }
    let stdout = "";
    let settled = false;
    const settle = (fn: () => void): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };
    const timer = setTimeout(() => {
      killProcessTree(child);
      settle(() => reject(new Error("timeout")));
    }, timeoutMs);
    timer.unref();
    child.stdout?.on("data", (d) => {
      if (stdout.length < 1024 * 1024) stdout += String(d);
    });
    // stderr を読まないと、パイプが満杯になった子が書き込みで止まる。
    child.stderr?.resume();
    child.stdin?.on("error", () => {});
    child.stdin?.end();
    child.on("error", (error) => settle(() => reject(error)));
    child.on("close", (code) => settle(() => (code === 0 ? resolve(stdout) : reject(new Error(`exit ${code}`)))));
  });

// ---- 見張り（§5.6） ----

export interface LedgerSink {
  /** 台帳の行を受ける（running でも。変化の判定は受け手）。終わりの行を渡したら、その鍵の見張りは終わる。 */
  row(key: string, row: LedgerRow): void;
  /** 1 回目の読み取りで読めなかった・30 回続けて読めなかった。受け手は受領票の時点の終わり方で行を閉じる。 */
  unreadable(key: string): void;
}

/**
 * セッションに 1 つ。最初の鍵で始め、鍵が全部終わったら止める。前の読み取りが終わっていなければその回は飛ばし、
 * 動いている鍵はまとめて 1 回で読む。読めるかは、鍵ごとの 1 回目の読み取りで決める。
 */
export class LedgerWatcher {
  private readonly keys = new Set<string>();
  private readonly firsts = new Set<string>();
  private readonly fails = new Map<string, number>();
  private reader?: Promise<LedgerReader>;
  private timer?: ReturnType<typeof setInterval>;
  /** 読み取りの順番待ち（1 本ずつ順に読む。CLI / WSL の読み取りは外部プロセスを起こす）。 */
  private chain: Promise<void> = Promise.resolve();
  private inflight = 0;
  private stopped = false;

  constructor(
    private readonly makeReader: () => Promise<LedgerReader>,
    private readonly sink: LedgerSink
  ) {}

  has(key: string): boolean {
    return this.keys.has(key) || this.firsts.has(key);
  }

  add(key: string): void {
    if (this.stopped || this.has(key)) return;
    this.firsts.add(key);
    void this.first(key);
  }

  remove(key: string): void {
    this.keys.delete(key);
    this.firsts.delete(key);
    this.fails.delete(key);
    this.settleTimer();
  }

  stop(): void {
    this.stopped = true;
    this.keys.clear();
    this.firsts.clear();
    this.fails.clear();
    this.settleTimer();
  }

  private getReader(): Promise<LedgerReader> {
    this.reader ??= this.makeReader();
    return this.reader;
  }

  private serial<T>(fn: () => Promise<T>): Promise<T> {
    this.inflight += 1;
    const run = this.chain.then(fn);
    this.chain = run.then(() => undefined, () => undefined);
    return run.finally(() => {
      this.inflight -= 1;
    });
  }

  private async first(key: string): Promise<void> {
    let row: LedgerRow | undefined;
    let reader: LedgerReader | undefined;
    try {
      [reader, row] = await this.serial(async () => {
        const r = await this.getReader();
        return [r, (await r.read([key])).get(key)] as const;
      });
    } catch {
      row = undefined;
    }
    if (!this.firsts.delete(key) || this.stopped) return;
    if (!row || !reader) {
      this.sink.unreadable(key);
      return;
    }
    this.keys.add(key);
    this.deliver(key, row);
    this.ensureTimer(reader);
  }

  private deliver(key: string, row: LedgerRow): void {
    if (row.state !== "running") this.remove(key);
    this.sink.row(key, row);
  }

  private ensureTimer(reader: LedgerReader): void {
    if (this.timer || this.keys.size === 0) return;
    this.timer = setInterval(() => void this.tick(reader), delegationTiming.intervalMs ?? reader.intervalMs);
    this.timer.unref();
  }

  private settleTimer(): void {
    if (this.timer && this.keys.size === 0 && this.firsts.size === 0) {
      clearInterval(this.timer);
      this.timer = undefined;
    }
  }

  private async tick(reader: LedgerReader): Promise<void> {
    // 前の読み取り（1 回目の読み取りを含む）が終わっていなければ、その回は飛ばす。
    if (this.inflight > 0 || this.keys.size === 0) return;
    const keys = [...this.keys];
    let rows: Map<string, LedgerRow> | undefined;
    try {
      rows = await this.serial(() => reader.read(keys));
    } catch {
      rows = undefined;
    }
    for (const key of keys) {
      if (this.stopped || !this.keys.has(key)) continue;
      const row = rows?.get(key);
      if (row) {
        this.fails.delete(key);
        this.deliver(key, row);
      } else {
        this.fail(key);
      }
    }
  }

  /** 読み取りの失敗（busy・locked など）は次の回にやり直す。30 回続けたら読めないとみなす。 */
  private fail(key: string): void {
    const n = (this.fails.get(key) ?? 0) + 1;
    if (n >= delegationTiming.maxFailures) {
      this.remove(key);
      this.sink.unreadable(key);
      return;
    }
    this.fails.set(key, n);
  }
}

// ---- 小物 ----

function asObject(value: unknown): Obj | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Obj) : undefined;
}

function parseObject(text: string | undefined): Obj | undefined {
  if (!text) return undefined;
  try {
    return asObject(JSON.parse(text));
  } catch {
    return undefined;
  }
}

function nonEmpty(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() !== "" ? value : undefined;
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
