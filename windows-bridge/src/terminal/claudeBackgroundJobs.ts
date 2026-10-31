import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { event, type SessionEvent } from "../protocol.js";
import type { RuntimeCommand } from "../runtime/command.js";
import { killProcessTree, spawnRuntime } from "../runtime/command.js";
import {
  BG_ID,
  composeBgEntry,
  parseAgentsJson,
  readJobState,
  readSessionFile,
  selectListed,
  type BgEntry,
  type BgRow,
  type BgState
} from "./claudeAgentsRegistry.js";

/// claude --bg のセッション（BACKGROUND_CONTROL §7、Windows は §7.10）。一覧・差分の配信・停止と削除・完了の知らせ・スリープの抑止・
/// Live Activity の数。一覧はいつも CLI 方式（claude agents --json --all）で作り、台帳のファイルは足りない項目を足すためだけに読む。
/// 実測していないので安全側で動く: WSL の runtime では機能を切る。CLI が失敗したら直前の結果を保ち（Mac の §7.5.3 と同じ）、
/// 3 回続けて失敗したときだけ一覧を空にする。試し直しは 30 秒後、次に 5 分後、そのあとは 30 分ごと。

/** テストが短くするための間隔。 */
export const bgTiming = {
  /** 変化を拾ってから読み直すまで待つ。 */
  debounceMs: 300,
  /** 続けて拾っても、最初の変化からこれより長くは待たない。 */
  maxDebounceMs: 1000,
  /** CLI を動かす最短の間隔。 */
  minGapMs: 3000,
  /** 保険の読み直し（working / blocked / live のジョブがある間 / 無いとき）。 */
  activeMs: 10_000,
  idleMs: 120_000,
  /** CLI が失敗した後の試し直し（1 回目の失敗の後・2 回目の後・3 回目以降）。 */
  retryFirstMs: 30_000,
  retrySecondMs: 5 * 60_000,
  retryMs: 30 * 60_000,
  /** 失敗している間にファイルの変化で読み直す最短の間隔。 */
  failGapMs: 30_000,
  /** 何回続けて失敗したら一覧を空にするか。 */
  failLimit: 3,
  /** .claude の作成を待つ間隔。 */
  waitDirMs: 60_000,
  listCliMs: 20_000,
  stopCliMs: 15_000,
  deleteCliMs: 20_000,
  /** 同じ会話へ続けて完了の push を出さない間隔。 */
  pushGapMs: 60_000,
  /** 同じジョブが続けて busy でも、これを過ぎたらスリープの抑止に数えない。 */
  busyLimitMs: 6 * 3600_000
};

export interface CliResult {
  code: number | null;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export type RunCli = (runtime: RuntimeCommand, args: string[], timeoutMs: number) => Promise<CliResult>;

/** spawnRuntime で動かす（シェルを通さない。作業フォルダはホーム）。時間切れは子孫ごと止める。 */
export const runCli: RunCli = (runtime, args, timeoutMs) =>
  new Promise((resolve, reject) => {
    let child: ReturnType<typeof spawnRuntime>;
    try {
      child = spawnRuntime(runtime, args, { stdio: "pipe", cwd: os.homedir(), env: { ...process.env, BUDDYOS_SPAWNED: "1" } });
    } catch (error) {
      reject(error);
      return;
    }
    const stdoutChunks: Buffer[] = [];
    const stderrChunks: Buffer[] = [];
    let stdoutSize = 0;
    let stderrSize = 0;
    // 1 つの文字が複数の chunk にまたがっても壊れないよう、最後に 1 回だけ decode する。
    const text = (chunks: Buffer[]): string => Buffer.concat(chunks).toString("utf8");
    let timedOut = false;
    let settled = false;
    const settle = (fn: () => void): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };
    const timer = setTimeout(() => {
      timedOut = true;
      killProcessTree(child);
      settle(() => resolve({ code: null, stdout: text(stdoutChunks), stderr: text(stderrChunks), timedOut }));
    }, timeoutMs);
    timer.unref();
    child.stdout?.on("data", (d) => {
      if (stdoutSize < 4 * 1024 * 1024) {
        const b = Buffer.isBuffer(d) ? d : Buffer.from(String(d));
        stdoutChunks.push(b);
        stdoutSize += b.length;
      }
    });
    child.stderr?.on("data", (d) => {
      if (stderrSize < 64 * 1024) {
        const b = Buffer.isBuffer(d) ? d : Buffer.from(String(d));
        stderrChunks.push(b);
        stderrSize += b.length;
      }
    });
    child.stdin?.on("error", () => {});
    child.stdin?.end();
    child.on("error", (error) => settle(() => reject(error)));
    child.on("close", (code) => settle(() => resolve({ code, stdout: text(stdoutChunks), stderr: text(stderrChunks), timedOut })));
  });

export interface BgWatcher {
  close(): void;
}
export type BgWatch = (dir: string, recursive: boolean, onEvent: (name: string | null) => void) => BgWatcher;

const fsWatch: BgWatch = (dir, recursive, onEvent) => {
  let watcher: fs.FSWatcher;
  try {
    watcher = fs.watch(dir, { recursive }, (_type, name) => onEvent(name === null ? null : String(name)));
  } catch (error) {
    if (!recursive) throw error;
    // recursive を持たない環境は、直下だけを見る。
    watcher = fs.watch(dir, {}, (_type, name) => onEvent(name === null ? null : String(name)));
  }
  watcher.on("error", () => {});
  return { close: () => watcher.close() };
};

/** Live Activity へ渡す口（WIN-9 がつなぐ）。 */
export interface BgActivity {
  /** sessionId → 1。working / blocked のセッション（繰り返しの待ちは数えない。8.2）。 */
  counts: Record<string, number>;
  /** この読み取りで終わった遷移（working / blocked から done / failed / stopped。消えたジョブは stopped）。 */
  finished: ("done" | "failed" | "stopped")[];
}

export interface BgJobsDeps {
  /** claude の runtime。native でなければ機能を切る。 */
  runtime?: RuntimeCommand;
  home?: string;
  runCli?: RunCli;
  watch?: BgWatch;
  now?: () => number;
  log?: (message: string) => void;
  /** 完了の push（title, body, data）。 */
  push?: (title: string, body: string, data: Record<string, string>) => void | Promise<void>;
  bridgeId?: string;
  /** スリープの抑止（owner "claude-bg"）。 */
  setSleep?: (active: boolean) => void;
  /** BuddyOS で付けた会話の名前。 */
  buddyTitle?: (sessionId: string) => string | undefined;
  /** その会話を開いている人がいる（subscribers.count("claude:<sid>") > 0）。 */
  hasWatchers?: (sessionId: string) => boolean;
  /** Bridge がその会話の session を握っている（liveSessions にある）。 */
  hasLiveSession?: (sessionId: string) => boolean;
}

export type BgOperation = "stop" | "delete";

export interface BgOperationResult {
  ok: boolean;
  shells: number;
  text: string;
}

const NOT_FOUND = "このセッションは見つかりません（もう消えています）";

export function removedJson(id: string, sessionId: string): string {
  return JSON.stringify({ id, sessionId, removed: true });
}

export function rowJson(row: BgRow): string {
  return JSON.stringify(row);
}

type Send = (event: SessionEvent) => void;

export class ClaudeBackgroundJobs {
  private deps: BgJobsDeps;
  private readonly senders = new Set<Send>();
  private readonly activityListeners = new Set<(activity: BgActivity) => void>();
  /** 台帳の全部（7.3 の絞り込みの前）。id → 1 件。 */
  private ledger = new Map<string, BgEntry>();
  /** 一覧に出している行の JSON（sessionId → JSON）。 */
  private sent = new Map<string, string>();
  private listed: BgEntry[] = [];
  private initialized = false;
  /** 3 回続けて失敗して、一覧を空にしている。 */
  private failed = false;
  /** 続けて失敗した回数。 */
  private failures = 0;
  /** 一覧を空にする前の台帳。回復した最初の読み取りで、その間に終わったジョブの遷移を拾うために使う。 */
  private stale?: Map<string, BgEntry>;
  private started = false;
  private stopped = false;
  private inflight?: Promise<void>;
  private again = false;
  private firstRun?: Promise<void>;
  private lastRunAt = 0;
  private lastEndAt = 0;
  private dirtyAt?: number;
  private dirtyFirstAt?: number;
  private timer?: NodeJS.Timeout;
  private watchers: BgWatcher[] = [];
  private watchTimer?: NodeJS.Timeout;
  private readonly operations = new Map<string, Promise<unknown>>();
  private readonly entryWatchers = new Map<string, Set<(entry: BgEntry | undefined) => void>>();
  private readonly lastPush = new Map<string, number>();
  private readonly busySince = new Map<string, number>();
  private readonly busyLogged = new Set<string>();
  private sleeping = false;

  constructor(deps: BgJobsDeps = {}) {
    this.deps = deps;
  }

  /** server が組み立てたあとで、会話を開いている人・名前・push の口をつなぐ。 */
  attach(deps: Partial<BgJobsDeps>): void {
    this.deps = { ...this.deps, ...deps };
  }

  /** native の runtime のときだけ使える（WSL の受け箱は WSL の中の Unix ソケットで、Windows から届かない。7.10 の 1）。 */
  get capable(): boolean {
    return this.deps.runtime?.kind === "native";
  }

  private get home(): string {
    return this.deps.home ?? os.homedir();
  }

  /** transcript と sessions の置き場所の基準（ClaudeBackgroundSession が使う）。 */
  get homeDir(): string {
    return this.home;
  }

  private get claudeDir(): string {
    return path.join(this.home, ".claude");
  }

  private get jobsDir(): string {
    return path.join(this.claudeDir, "jobs");
  }

  private get sessionsDir(): string {
    return path.join(this.claudeDir, "sessions");
  }

  private now(): number {
    return this.deps.now ? this.deps.now() : Date.now();
  }

  private log(message: string): void {
    (this.deps.log ?? ((m: string) => console.log(`[claude-bg] ${m}`)))(message);
  }

  // ---- 開始・終了 ----

  start(): void {
    if (this.started || !this.capable) return;
    this.started = true;
    this.stopped = false;
    this.rewatch();
    this.watchTimer = setInterval(() => this.rewatch(), bgTiming.waitDirMs);
    this.watchTimer.unref();
    this.schedule();
  }

  stop(): void {
    this.stopped = true;
    this.started = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    if (this.watchTimer) clearInterval(this.watchTimer);
    this.watchTimer = undefined;
    for (const w of this.watchers) w.close();
    this.watchers = [];
    if (this.sleeping) this.deps.setSleep?.(false);
    this.sleeping = false;
  }

  /** 接続のたびに登録する（開いている全部の WS へ変化を送る。採番せず、差分 replay にも載せない）。 */
  register(send: Send): () => void {
    this.senders.add(send);
    return () => this.senders.delete(send);
  }

  /** Live Activity が数と終わった遷移を受ける。 */
  onActivity(listener: (activity: BgActivity) => void): () => void {
    this.activityListeners.add(listener);
    return () => this.activityListeners.delete(listener);
  }

  /** いまの数（sessionId → 1）。 */
  activityCounts(): Record<string, number> {
    const counts: Record<string, number> = {};
    for (const entry of this.ledger.values()) {
      if (isRunning(entry)) counts[entry.row.sessionId] = 1;
    }
    return counts;
  }

  // ---- 一覧 ----

  /** 最初の読み取りが終わるまで（最大 waitMs）待つ。 */
  async ready(waitMs = 5000): Promise<void> {
    if (!this.capable) return;
    if (!this.firstRun) this.firstRun = this.inflight ?? this.refresh();
    await Promise.race([this.firstRun, new Promise<void>((resolve) => setTimeout(resolve, waitMs).unref())]);
  }

  /** 一覧の行（blocked → working → ほか）。使えない・CLI が失敗し続けているときは空。 */
  rows(): BgRow[] {
    if (!this.capable || this.failed) return [];
    return this.listed.map((e) => e.row);
  }

  /** 台帳にあるジョブ（7.3 の絞り込みの前）を sessionId で引く。会話を開くときの振り分け・受け箱に使う。 */
  entryFor(sessionId: string): BgEntry | undefined {
    if (!this.capable || this.failed) return undefined;
    for (const entry of this.ledger.values()) if (entry.row.sessionId === sessionId) return entry;
    return undefined;
  }

  isBackgroundWorker(sessionId: string): boolean {
    return this.entryFor(sessionId)?.row.live === true;
  }

  /** そのセッションのジョブの変化（読み取りのたび）を受ける。ワーカーの status でターンを開け閉めするのに使う。 */
  watchEntry(sessionId: string, listener: (entry: BgEntry | undefined) => void): () => void {
    let set = this.entryWatchers.get(sessionId);
    if (!set) this.entryWatchers.set(sessionId, (set = new Set()));
    set.add(listener);
    return () => {
      set.delete(listener);
      if (set.size === 0 && this.entryWatchers.get(sessionId) === set) this.entryWatchers.delete(sessionId);
    };
  }

  private notifyEntries(): void {
    for (const [sessionId, listeners] of [...this.entryWatchers]) {
      const entry = this.entryFor(sessionId);
      for (const listener of [...listeners]) {
        try {
          listener(entry);
        } catch {
          /* 受け手の失敗は読み取りに響かせない */
        }
      }
    }
  }

  // ---- 読み取り ----

  /** 読み直す。読み取り中なら終わってからもう 1 回だけ読む。 */
  refresh(): Promise<void> {
    if (!this.capable) return Promise.resolve();
    if (this.inflight) {
      this.again = true;
      return this.inflight;
    }
    const run = this.read().finally(() => {
      this.inflight = undefined;
      if (this.again && !this.stopped) {
        this.again = false;
        void this.refresh();
      } else this.schedule();
    });
    this.inflight = run;
    return run;
  }

  /** いまの読み取りが終わってから、改めて 1 回読む（操作の直後に使う）。 */
  private async refreshFresh(): Promise<void> {
    if (this.inflight) await this.inflight.catch(() => {});
    await this.refresh();
  }

  private async read(): Promise<void> {
    const runtime = this.deps.runtime;
    if (!runtime) return;
    this.lastRunAt = this.now();
    try {
      await this.readOnce();
    } finally {
      this.lastEndAt = this.now();
    }
  }

  private async readOnce(): Promise<void> {
    const runtime = this.deps.runtime;
    if (!runtime) return;
    let cliRows: ReturnType<typeof parseAgentsJson>;
    try {
      const result = await (this.deps.runCli ?? runCli)(runtime, ["agents", "--json", "--all"], bgTiming.listCliMs);
      cliRows = result.code === 0 && !result.timedOut ? parseAgentsJson(result.stdout) : undefined;
      if (!cliRows) this.log(`list failed ${result.timedOut ? "timeout" : `exit ${result.code}`}`);
    } catch (error) {
      cliRows = undefined;
      this.log(`list failed ${error instanceof Error ? error.message : String(error)}`);
    }
    if (this.stopped) return;
    if (!cliRows) {
      this.fail();
      return;
    }
    this.failures = 0;
    this.failed = false;

    const now = this.now();
    const ledger = new Map<string, BgEntry>();
    for (const cli of cliRows) {
      const job = readJobState(this.jobsDir, cli.id);
      let session = cli.pid !== undefined ? readSessionFile(this.sessionsDir, cli.pid) : undefined;
      if (session?.sessionId && session.sessionId !== cli.sessionId) session = undefined;
      ledger.set(cli.id, composeBgEntry({ cli, job, session, buddyTitle: this.deps.buddyTitle?.(cli.sessionId) }));
    }
    const listed = selectListed([...ledger.values()], now);
    // 一覧を空にしていたときは、空にする前の台帳と比べる（その間に終わったジョブにも完了の知らせと遷移を出す）。
    const previous = this.stale ?? this.ledger;
    this.stale = undefined;
    this.ledger = ledger;
    this.listed = listed;

    this.deliver(listed);
    const finished: BgActivity["finished"] = [];
    if (this.initialized) {
      this.collectFinished(previous, ledger, finished);
      this.notifyEnded(previous, ledger);
    }
    this.initialized = true;
    this.updateSleep(ledger, now);
    this.emitActivity(finished);
    this.notifyEntries();
  }

  /**
   * CLI が失敗した。直前の結果（一覧・台帳・Live Activity の数）はそのまま保ち、開いている会話にも知らせない。
   * 3 回続けて失敗したときだけ、一覧を空にして（removed を送る）数を落とす。
   */
  private fail(): void {
    this.failures++;
    if (this.failures >= bgTiming.failLimit && !this.failed) {
      this.failed = true;
      this.stale = this.ledger;
      this.ledger = new Map();
      this.listed = [];
      this.deliver([]);
      this.updateSleep(this.ledger, this.now());
      this.emitActivity([]);
      this.notifyEntries();
    }
    this.schedule();
  }

  /** 行の項目が変わったものを送る。一覧から外れた行と消えたジョブは removed にする。 */
  private deliver(listed: BgEntry[]): void {
    const next = new Map<string, string>();
    for (const entry of listed) next.set(entry.row.sessionId, rowJson(entry.row));
    for (const [sessionId, json] of next) {
      if (this.sent.get(sessionId) !== json) this.broadcast(event.bgSessionChanged(sessionId, json));
    }
    for (const [sessionId, json] of this.sent) {
      if (next.has(sessionId)) continue;
      let id = sessionId.slice(0, 8);
      try {
        const parsed = JSON.parse(json) as { id?: string };
        if (parsed.id) id = parsed.id;
      } catch {
        /* 先頭 8 桁のまま */
      }
      this.broadcast(event.bgSessionChanged(sessionId, removedJson(id, sessionId)));
    }
    this.sent = next;
  }

  private broadcast(e: SessionEvent): void {
    for (const send of this.senders) {
      try {
        send(e);
      } catch {
        /* 閉じた接続 */
      }
    }
  }

  // ---- Live Activity ----

  private collectFinished(previous: Map<string, BgEntry>, next: Map<string, BgEntry>, out: BgActivity["finished"]): void {
    for (const [id, before] of previous) {
      if (!isRunning(before)) continue;
      const after = next.get(id);
      if (!after) out.push("stopped");
      else if (after.row.state === "done" || after.row.state === "failed" || after.row.state === "stopped") out.push(after.row.state);
    }
  }

  private emitActivity(finished: BgActivity["finished"]): void {
    if (this.activityListeners.size === 0) return;
    const activity: BgActivity = { counts: this.activityCounts(), finished };
    for (const listener of this.activityListeners) {
      try {
        listener(activity);
      } catch {
        /* 受け手の失敗は読み取りに響かせない */
      }
    }
  }

  // ---- 知らせ（7.9） ----

  private notifyEnded(previous: Map<string, BgEntry>, next: Map<string, BgEntry>): void {
    const push = this.deps.push;
    if (!push) return;
    for (const [id, entry] of next) {
      const before = previous.get(id);
      if (!before) continue;
      if (before.row.state !== "working" && before.row.state !== "blocked") continue;
      if (before.firstTerminal || !entry.firstTerminal) continue;
      if (entry.row.state !== "done" && entry.row.state !== "failed") continue;
      const sessionId = entry.row.sessionId;
      if (this.deps.hasWatchers?.(sessionId) || this.deps.hasLiveSession?.(sessionId)) continue;
      const now = this.now();
      const last = this.lastPush.get(sessionId);
      if (last !== undefined && now - last < bgTiming.pushGapMs) continue;
      this.lastPush.set(sessionId, now);
      void this.pushEnded(entry).catch(() => {});
    }
  }

  /** ワーカーの会話の完了を push してよいか（同じ会話へ続けて出さない間隔を、ジョブ側の知らせと共有する）。 */
  claimPush(sessionId: string): boolean {
    const now = this.now();
    const last = this.lastPush.get(sessionId);
    if (last !== undefined && now - last < bgTiming.pushGapMs) return false;
    this.lastPush.set(sessionId, now);
    return true;
  }

  private async pushEnded(entry: BgEntry): Promise<void> {
    const push = this.deps.push;
    if (!push) return;
    let body: string;
    if (entry.row.state === "failed") {
      const detail = entry.row.detail?.slice(0, 120);
      body = "バックグラウンドのセッションが失敗しました" + (detail ? `（${detail}）` : "");
    } else {
      body = (await lastAssistantText(entry.linkScanPath, entry.row.sessionId, this.home))?.slice(0, 180) || "バックグラウンドのセッションが終わりました";
    }
    await push("Claude Code", body, { kind: "chat", agentId: "claude", sessionId: entry.row.sessionId, bridgeId: this.deps.bridgeId ?? "" });
  }

  // ---- スリープの抑止（7.9） ----

  /** 生きているワーカーのどれかの生の status が busy の間だけ保つ。shell は数えない。同じジョブが 6 時間続けて busy なら数えない。 */
  private updateSleep(ledger: Map<string, BgEntry>, now: number): void {
    const busyIds = new Set<string>();
    let count = 0;
    for (const [id, entry] of ledger) {
      if (!entry.row.live || entry.workerStatus !== "busy") continue;
      busyIds.add(id);
      const since = this.busySince.get(id) ?? now;
      this.busySince.set(id, since);
      if (now - since >= bgTiming.busyLimitMs) {
        if (!this.busyLogged.has(id)) {
          this.busyLogged.add(id);
          this.log(`job ${id} busy for 6h, not holding sleep`);
        }
        continue;
      }
      count++;
    }
    for (const id of [...this.busySince.keys()]) {
      if (busyIds.has(id)) continue;
      this.busySince.delete(id);
      this.busyLogged.delete(id);
    }
    const active = count > 0;
    if (active !== this.sleeping) {
      this.sleeping = active;
      this.deps.setSleep?.(active);
    }
  }

  // ---- 操作（7.7） ----

  /** claude stop / rm。同じ id への操作は 1 本ずつ。 */
  operate(op: BgOperation, sessionId: string | undefined, id: string | undefined): Promise<BgOperationResult> {
    const key = id ?? "";
    const previous = this.operations.get(key) ?? Promise.resolve();
    const run = previous.catch(() => {}).then(() => this.runOperation(op, sessionId, id));
    this.operations.set(key, run);
    const clear = (): void => {
      if (this.operations.get(key) === run) this.operations.delete(key);
    };
    run.then(clear, clear);
    return run;
  }

  private async runOperation(op: BgOperation, sessionId: string | undefined, id: string | undefined): Promise<BgOperationResult> {
    const runtime = this.deps.runtime;
    if (!this.capable || !runtime) return { ok: false, shells: 0, text: "この PC では使えません" };
    const entry = id && BG_ID.test(id) ? this.ledger.get(id) : undefined;
    if (!id || !entry || entry.row.sessionId !== sessionId) return { ok: false, shells: 0, text: NOT_FOUND };
    const shells = entry.row.shells;
    const timeoutMs = op === "stop" ? bgTiming.stopCliMs : bgTiming.deleteCliMs;
    let result: CliResult;
    try {
      result = await (this.deps.runCli ?? runCli)(runtime, [op === "stop" ? "stop" : "rm", id], timeoutMs);
    } catch (error) {
      return { ok: false, shells, text: lastLines(error instanceof Error ? error.message : String(error)) };
    }
    const outcome = judge(op, id, result, timeoutMs);
    // 結果はすぐ返す（読み直しを待つと、アプリの 25 秒を超えることがある）。台帳は待たずに読み直し、変化は bg_session_changed で届く。
    void this.refreshFresh().catch(() => {});
    if (!outcome.ok) return { ok: false, shells, text: outcome.text };
    const text =
      shells > 0 ? `${op === "stop" ? "止めました" : "削除しました"}。裏で動いていたコマンド ${shells} 件は PC で動いたままです。` : "";
    return { ok: true, shells, text };
  }

  // ---- きっかけ（7.10 の 3） ----

  /** jobs と sessions の変化を拾った。300 ミリ秒待ってから読み直す（最短 3 秒おき）。 */
  trigger(name?: string | null): void {
    if (this.stopped || !this.capable) return;
    if (name && (name.endsWith(".key") || name.includes(".tmp."))) return;
    const now = this.now();
    this.dirtyAt = now;
    this.dirtyFirstAt ??= now;
    this.schedule();
  }

  private hasActive(): boolean {
    for (const entry of this.ledger.values()) {
      if (entry.row.live || entry.row.state === "working" || entry.row.state === "blocked") return true;
    }
    return false;
  }

  private schedule(): void {
    if (!this.started || this.stopped || this.inflight) return;
    if (this.timer) clearTimeout(this.timer);
    const now = this.now();
    const retry =
      this.failures <= 1 ? bgTiming.retryFirstMs : this.failures === 2 ? bgTiming.retrySecondMs : bgTiming.retryMs;
    const lastEnd = Math.max(this.lastRunAt, this.lastEndAt);
    const periodic = lastEnd + (this.failures > 0 ? retry : this.hasActive() ? bgTiming.activeMs : bgTiming.idleMs);
    let due = this.lastRunAt === 0 ? now : periodic;
    if (this.dirtyAt !== undefined) {
      const settle = Math.min(this.dirtyAt + bgTiming.debounceMs, (this.dirtyFirstAt ?? this.dirtyAt) + bgTiming.maxDebounceMs);
      // 失敗している間も変化では読み直すが、30 秒に 1 回まで。間隔は前の読み取りが終わってから測る。
      const gap = this.failures > 0 ? bgTiming.failGapMs : bgTiming.minGapMs;
      due = Math.min(due, Math.max(settle, lastEnd + gap));
    }
    this.timer = setTimeout(() => {
      this.timer = undefined;
      this.dirtyAt = undefined;
      this.dirtyFirstAt = undefined;
      void this.refresh();
    }, Math.max(0, due - now));
    this.timer.unref();
  }

  /** jobs と sessions を見張る。無ければ .claude を見て作られるのを待つ（.claude も無ければ 60 秒ごとに確かめる）。 */
  private rewatch(): void {
    if (this.stopped) return;
    const watch = this.deps.watch ?? fsWatch;
    const want: { dir: string; recursive: boolean }[] = [];
    let missing = false;
    for (const dir of [this.jobsDir, this.sessionsDir]) {
      if (fs.existsSync(dir)) want.push({ dir, recursive: true });
      else missing = true;
    }
    if (missing && fs.existsSync(this.claudeDir)) want.push({ dir: this.claudeDir, recursive: false });
    // 前に張ったものと同じなら張り直さない。
    const signature = want.map((w) => w.dir).join("|");
    if (signature === this.watchSignature && this.watchers.length > 0) return;
    this.watchSignature = signature;
    for (const w of this.watchers) w.close();
    this.watchers = [];
    for (const { dir, recursive } of want) {
      try {
        this.watchers.push(
          watch(dir, recursive, (name) => {
            if (dir === this.claudeDir) {
              // jobs / sessions が作られたら張り直す。
              this.rewatch();
              return;
            }
            this.trigger(name);
          })
        );
      } catch (error) {
        this.log(`watch failed ${dir}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }

  private watchSignature = "";
}

function isRunning(entry: BgEntry): boolean {
  return (entry.row.state === "working" || entry.row.state === "blocked") && !entry.recurringWait;
}

export function lastLines(text: string, lines = 3, limit = 400): string {
  const out = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l !== "")
    .slice(-lines)
    .join("\n");
  return out.length > limit ? out.slice(out.length - limit) : out;
}

/** 7.7 の 5 の判定。 */
export function judge(op: BgOperation, id: string, result: CliResult, timeoutMs = op === "stop" ? bgTiming.stopCliMs : bgTiming.deleteCliMs): { ok: boolean; text: string } {
  const seconds = Math.round(timeoutMs / 1000);
  if (result.timedOut) {
    return { ok: false, text: op === "stop" ? `PC で止められませんでした（${seconds}秒たっても終わりません）` : `PC で削除できませんでした（${seconds}秒たっても終わりません）` };
  }
  const word = op === "stop" ? "stopped" : "removed";
  if (result.code === 0 && new RegExp(`^${word} ${id}\\s*$`, "m").test(result.stdout)) return { ok: true, text: "" };
  if (result.code === 1 && result.stderr.includes("No job matching")) {
    return op === "stop" ? { ok: false, text: NOT_FOUND } : { ok: true, text: "" };
  }
  return { ok: false, text: lastLines(result.stderr) || (op === "stop" ? "PC で止められませんでした" : "PC で削除できませんでした") };
}

// ---- 完了の本文 ----

const TAIL_BYTES = 512 * 1024;

/** transcript として読んでよい場所か（名前が `<sessionId>.jsonl`、ホームの中、自分の普通のファイル）。 */
export function validTranscriptPath(file: string | undefined, sessionId: string, home: string): string | undefined {
  if (!file || path.basename(file) !== `${sessionId}.jsonl`) return undefined;
  const resolved = path.resolve(file);
  const root = path.resolve(home);
  const rel = path.relative(root, resolved);
  if (rel === "" || rel.startsWith("..") || path.isAbsolute(rel)) return undefined;
  try {
    const stat = fs.lstatSync(resolved);
    return stat.isFile() ? resolved : undefined;
  } catch {
    return undefined;
  }
}

/** transcript の末尾 512 KB にある main の最後の assistant の text。 */
export async function lastAssistantText(file: string | undefined, sessionId: string, home: string): Promise<string | undefined> {
  const valid = validTranscriptPath(file, sessionId, home);
  if (!valid) return undefined;
  let handle: fs.promises.FileHandle | undefined;
  try {
    handle = await fs.promises.open(valid, "r");
    const { size } = await handle.stat();
    const start = Math.max(0, size - TAIL_BYTES);
    const buffer = Buffer.alloc(size - start);
    await handle.read(buffer, 0, buffer.length, start);
    let lines = buffer.toString("utf8").split("\n");
    if (start > 0) lines = lines.slice(1);
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line) continue;
      let o: { type?: string; isSidechain?: boolean; message?: { content?: unknown } };
      try {
        o = JSON.parse(line);
      } catch {
        continue;
      }
      if (o.type !== "assistant" || o.isSidechain === true) continue;
      const content = o.message?.content;
      const text =
        typeof content === "string"
          ? content
          : Array.isArray(content)
            ? content
                .filter((b): b is { type: string; text: string } => !!b && (b as { type?: string }).type === "text" && typeof (b as { text?: unknown }).text === "string")
                .map((b) => b.text)
                .join("\n")
            : "";
      if (text.trim()) return text.trim();
    }
    return undefined;
  } catch {
    return undefined;
  } finally {
    await handle?.close().catch(() => {});
  }
}

export type { BgEntry, BgRow, BgState };
