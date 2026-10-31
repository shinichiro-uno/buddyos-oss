import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { SessionEvent } from "../protocol.js";
import type { AgentAdapter, AgentSession } from "../agents/types.js";
import { agentsOrWorkflows, WorkflowCardMirror } from "../workflowCardMirror.js";
import {
  cronJitterSeconds,
  formatLocalDateTime,
  formatOutputStamp,
  nextScheduleFire,
  parseSchedule
} from "./schedule.js";

/// Bridge 内蔵の定期実行（mac-bridge の BridgeCronScheduler の移植）。
/// ジョブは ~/.buddyos/cron/jobs.json、実行結果は ~/.buddyos/cron/output/<jobId>/<時刻>.md に書く。
/// 結果ファイルは CronOutputHub が拾って iPhone へ配り、push する。
/// 1 回の実行は「無人の新規チャット 1 ターン」。ジョブは Bridge が動いている間だけ発火する
/// （スリープ等で逃した分は、起きた後の最初の見回りで 1 回だけ取り戻す）。

export interface CronCreateSpec {
  name?: string;
  schedule: string;
  prompt: string;
  deliver?: string;
  repeatCount?: number;
  cwd?: string;
  permissionMode?: string;
}

export interface CronJobSummary {
  id: string;
  name: string;
  prompt: string;
  scheduleDisplay: string;
  deliver: string;
  enabled: boolean;
  state: "scheduled" | "paused" | "running";
  nextRunAt?: string;
  lastRunAt?: string;
  lastStatus?: string;
  /** 前回の実行の会話（一覧から開く）。 */
  lastSessionId?: string;
}

interface BridgeCronJob {
  id: string;
  agentId: string;
  name: string;
  prompt: string;
  schedule: string;
  cwd?: string;
  permissionMode?: string;
  deliver: string;
  enabled: boolean;
  createdAt: string;
  lastRunAt?: string;
  lastStatus?: string;
  repeatCount?: number;
  runsCompleted: number;
  lastSessionId?: string;
}

export interface CronSchedulerOptions {
  /** ~/.buddyos/cron（テストで差し替える）。 */
  root?: string;
  /** job.agentId から adapter を引く。 */
  adapterFor(agentId: string): AgentAdapter | undefined;
  /** 実行中ジョブの有無が変わったとき（スリープ防止の切り替え用）。 */
  onActiveChange?(active: boolean): void;
  tickMs?: number;
  runTimeoutMs?: number;
}

const TICK_MS = 30_000;
const RUN_TIMEOUT_MS = 30 * 60_000;
const FORCE_CLOSE_AFTER_MS = 10_000;
/** バックグラウンドの作業が終わったのに知らせのターンが始まらないときの打ち切り（mac の backgroundSettleGrace）。 */
const BACKGROUND_SETTLE_GRACE_MS = 120_000;

/**
 * 1 回分の本文と、バックグラウンドの作業を集める（mac の BridgeCronScheduler.TurnCollector と同じ）。
 * 結果は最後の空でないターンの本文。done の後もバックグラウンドのサブエージェントか workflow が動いていれば、
 * 終わった後の知らせのターンの done まで集め続ける。バックグラウンドのコマンドだけなら待たない（dev サーバーは終わらない）。
 */
export class TurnCollector {
  /** 結果の本文（最後の空でないターン） */
  text = "";
  private turnText = "";
  private readonly cards = new WorkflowCardMirror();
  /** done の後、バックグラウンドの作業の終わり（知らせのターンの done）を待っている */
  waitingForBackground = false;
  /** 最後の done の後に、ターンの出力が届いた（知らせのターンが始まった） */
  turnStarted = false;

  get backgroundRunning(): boolean {
    return agentsOrWorkflows(this.cards.counts);
  }

  /** 出来事を 1 つ受ける。集め終わった（バックグラウンドの作業が残っていない done）なら true。 */
  ingest(evt: SessionEvent): boolean {
    switch (evt.type) {
      case "assistant_delta":
        this.turnStarted = true;
        this.turnText += evt.content ?? "";
        break;
      case "activity":
      case "tool_start":
        this.turnStarted = true;
        break;
      case "workflow_progress":
        this.cards.apply(evt.content);
        break;
      case "done":
        this.closeTurn();
        this.turnStarted = false;
        this.waitingForBackground = this.backgroundRunning;
        return !this.waitingForBackground;
      default:
        break;
    }
    return false;
  }

  /** 途中のターンの本文も結果に入れる（時間切れ・close）。 */
  finishStream(): void {
    this.closeTurn();
  }

  private closeTurn(): void {
    if (this.turnText.trim()) this.text = this.turnText;
    this.turnText = "";
  }
}

export function defaultCronRoot(): string {
  return path.join(os.homedir(), ".buddyos", "cron");
}

/**
 * 定期実行の作業フォルダを決める。空欄ならホーム（Bridge の起動フォルダ = アプリの bin や / で
 * workspace-write の無人実行が走らないように）。ドライブの直下・/・Windows のフォルダ・Bridge のフォルダは断る。
 * Windows のパスはフォルダがあることを確かめる（WSL の /home/... は Windows からは見えないので形だけ見る）。
 */
export function normalizeCronCwd(raw: string | undefined, home = os.homedir(), platform: NodeJS.Platform = process.platform): string {
  const trimmed = raw?.trim();
  const cwd = trimmed ? trimmed : home;
  const posixOnWindows = platform === "win32" && cwd.startsWith("/");
  const p = platform === "win32" && !posixOnWindows ? path.win32 : path.posix;
  if (!p.isAbsolute(cwd) || (platform === "win32" && !posixOnWindows && !/^[a-zA-Z]:[\\/]/.test(cwd) && !cwd.startsWith("\\\\"))) {
    throw new Error(`作業フォルダはフルパスで指定してください（${cwd}）。`);
  }
  const resolved = p.resolve(cwd);
  const notAllowed = (dir: string) => new Error(`このフォルダでは定期実行を動かせません（${dir}）。プロジェクトのフォルダを指定してください。`);
  if (forbiddenCronCwd(resolved, p, platform, home)) throw notAllowed(resolved);
  if (!posixOnWindows) {
    let real: string | undefined;
    try {
      if (fs.statSync(resolved).isDirectory()) real = fs.realpathSync(resolved);
    } catch {
      /* 無い */
    }
    if (!real) throw new Error(`作業フォルダが見つかりません（${resolved}）。`);
    // シンボリックリンク・ジャンクションの先が断るフォルダなら断る（返すのは指定どおりのパス）。
    if (real !== resolved && forbiddenCronCwd(real, p, platform, home)) throw notAllowed(real);
  }
  return resolved;
}

function forbiddenCronCwd(cwd: string, p: path.PlatformPath, platform: NodeJS.Platform, home: string): boolean {
  const norm = (v: string): string => (p === path.win32 ? v.replace(/\//g, "\\").toLowerCase() : v).replace(/[\\/]+$/, "");
  const target = norm(cwd);
  // ドライブ直下・/（WSL から見たドライブ直下 /mnt/c も）
  if (target === "" || /^[a-z]:$/.test(target) || /^\/mnt\/[a-zA-Z]$/.test(target)) return true;
  // WSL から見た Windows のフォルダ（/mnt/c/Windows）
  if (p === path.posix && platform === "win32" && /^\/mnt\/[a-zA-Z]\/windows(\/|$)/i.test(target)) return true;
  const within = (dir: string): boolean => {
    const base = norm(dir);
    return base !== "" && (target === base || target.startsWith(base + p.sep));
  };
  const blocked =
    p === path.win32
      ? [process.env.SystemRoot || process.env.windir || "C:\\Windows"]
      : ["/System", "/bin", "/sbin", "/usr", "/etc", "/dev", "/proc", "/sys", "/boot"];
  // Bridge 自身（同梱の node / バイナリ）のフォルダ。アプリの中で書き込める実行を走らせない。
  // （node がホームの直下にあるような環境でホーム自体を断らないよう、ホームやその上のフォルダは除く。）
  const bridgeDir = path.dirname(process.execPath);
  if (platform === process.platform && !(norm(home) + p.sep).startsWith(norm(bridgeDir) + p.sep)) blocked.push(bridgeDir);
  return blocked.some(within);
}

/** jobs.json の 1 要素を読む。必須の項目（id / agentId / prompt / schedule）が無ければ undefined。ほかは既定で補う。 */
export function decodeCronJob(item: unknown): BridgeCronJob | undefined {
  if (!item || typeof item !== "object" || Array.isArray(item)) return undefined;
  const o = item as Record<string, unknown>;
  const text = (v: unknown): string | undefined => (typeof v === "string" && v.length > 0 ? v : undefined);
  const id = text(o.id);
  const agentId = text(o.agentId);
  const prompt = text(o.prompt);
  const schedule = text(o.schedule);
  if (!id || !agentId || !prompt || !schedule) return undefined;
  const job: BridgeCronJob = {
    id,
    agentId,
    name: text(o.name) ?? `job-${id}`,
    prompt,
    schedule,
    deliver: text(o.deliver) ?? "local",
    enabled: typeof o.enabled === "boolean" ? o.enabled : true,
    createdAt: text(o.createdAt) ?? new Date().toISOString(),
    runsCompleted: typeof o.runsCompleted === "number" && Number.isFinite(o.runsCompleted) ? o.runsCompleted : 0
  };
  if (text(o.cwd)) job.cwd = text(o.cwd);
  if (text(o.permissionMode)) job.permissionMode = text(o.permissionMode);
  if (text(o.lastRunAt)) job.lastRunAt = text(o.lastRunAt);
  if (text(o.lastStatus)) job.lastStatus = text(o.lastStatus);
  if (text(o.lastSessionId)) job.lastSessionId = text(o.lastSessionId);
  if (typeof o.repeatCount === "number" && Number.isFinite(o.repeatCount)) job.repeatCount = o.repeatCount;
  return job;
}

export class BridgeCronScheduler {
  readonly root: string;
  readonly outputRoot: string;
  private readonly jobsFile: string;
  private jobs: BridgeCronJob[] = [];
  /** jobs.json を読み終えたか（無いファイルは空として読み終えた扱い）。 */
  private loaded = false;
  /**
   * jobs.json を読めない理由（一時的なロック・権限・壊れていて退避もできない）。読めるまで保存しない
   * （空のジョブ一覧で元のファイルを上書きして、全ジョブが消えないように）。読み直しは次の操作・見回りで行う。
   */
  private loadError?: string;
  /** 読めなかった要素（壊れた・知らない形）。消さずに保存し直す。 */
  private unreadable: unknown[] = [];
  /** 退避済みの壊れた中身（読み直しのたびに同じものを退避し直さない）。 */
  private backedUpRaw?: string;
  private readonly running = new Set<string>();
  private timer?: NodeJS.Timeout;
  private started = false;

  constructor(private readonly options: CronSchedulerOptions) {
    this.root = options.root ?? defaultCronRoot();
    this.outputRoot = path.join(this.root, "output");
    this.jobsFile = path.join(this.root, "jobs.json");
  }

  start(): void {
    if (this.started) return;
    this.started = true;
    this.ensureLoaded();
    fs.mkdirSync(this.outputRoot, { recursive: true });
    this.tick();
    this.timer = setInterval(() => this.tick(), this.options.tickMs ?? TICK_MS);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  list(agentId: string): CronJobSummary[] {
    this.ensureLoaded();
    return this.jobs.filter((j) => j.agentId === agentId).map((j) => this.summary(j));
  }

  create(agentId: string, spec: CronCreateSpec): string {
    this.ensureWritable();
    const schedule = spec.schedule.trim();
    if (!parseSchedule(schedule)) throw new Error(`unsupported schedule: ${spec.schedule}`);
    const prompt = spec.prompt.trim();
    if (!prompt) throw new Error("prompt is required");
    const id = crypto.randomBytes(4).toString("hex");
    const job: BridgeCronJob = {
      id,
      agentId,
      name: spec.name?.trim() ? spec.name.trim() : `job-${id}`,
      prompt: spec.prompt,
      schedule,
      deliver: spec.deliver ?? "local",
      enabled: true,
      createdAt: new Date().toISOString(),
      runsCompleted: 0
    };
    job.cwd = normalizeCronCwd(spec.cwd);
    if (spec.permissionMode) job.permissionMode = spec.permissionMode;
    if (spec.repeatCount !== undefined && spec.repeatCount > 0) job.repeatCount = spec.repeatCount;
    this.jobs.push(job);
    this.save();
    return id;
  }

  delete(agentId: string, jobId: string): void {
    this.ensureWritable();
    const idx = this.indexOf(agentId, jobId);
    this.jobs.splice(idx, 1);
    this.save();
  }

  setEnabled(agentId: string, jobId: string, enabled: boolean): void {
    this.ensureWritable();
    const idx = this.indexOf(agentId, jobId);
    const job = this.jobs[idx];
    job.enabled = enabled;
    // 再開時、止めていた間に過ぎた回はまとめて取り戻さない（実行回数には数えない）。
    if (enabled) {
      const due = this.nextFire(job);
      if (due && due.getTime() <= Date.now()) job.lastRunAt = new Date().toISOString();
    }
    this.save();
  }

  private indexOf(agentId: string, jobId: string): number {
    this.ensureLoaded();
    const idx = this.jobs.findIndex((j) => j.id === jobId && j.agentId === agentId);
    if (idx < 0) throw new Error(`job not found: ${jobId}`);
    return idx;
  }

  /** 読み終えていなければ読む（前回読めなかったときも読み直す）。起動前は外から書き換えたファイルも読み直す。 */
  private ensureLoaded(): void {
    if (this.loaded && (this.started || this.jobs.length > 0)) return;
    this.load();
  }

  /** 書き換える操作の前に呼ぶ。jobs.json を読めないままなら、上書きしないよう断る。 */
  private ensureWritable(): void {
    this.ensureLoaded();
    if (this.loadError) throw new Error(this.loadError);
  }

  /// jobs.json を読む（mac と同じ方針）。無ければ空。読めない（ロック・権限）ときは保存を止めて次の機会に読み直す。
  /// JSON として壊れていたら別名で退避してから空で始める（退避できなければ保存を止める）。
  /// 要素ごとに読み、読めない要素は捨てずに取っておいて保存し直す（1 件の破損で全ジョブを失わない）。
  private load(): void {
    let raw: string;
    try {
      raw = fs.readFileSync(this.jobsFile, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        this.applyLoaded([], []);
        return;
      }
      this.failLoad(`定期実行の設定ファイルを読めませんでした（${this.jobsFile}）。少し待ってからもう一度試してください。`, error);
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      parsed = error;
    }
    if (!Array.isArray(parsed)) {
      if (this.backedUpRaw !== raw) {
        const backup = this.backupBroken();
        if (!backup) {
          this.failLoad(`定期実行の設定ファイルが壊れていて読めません（${this.jobsFile}）。`, parsed);
          return;
        }
        this.backedUpRaw = raw;
        process.stderr.write(`[cron] jobs.json is unreadable; saved a copy to ${backup} and started empty\n`);
      }
      this.applyLoaded([], []);
      return;
    }
    const jobs: BridgeCronJob[] = [];
    const unreadable: unknown[] = [];
    for (const item of parsed) {
      const job = decodeCronJob(item);
      if (job) jobs.push(job);
      else unreadable.push(item);
    }
    if (unreadable.length > 0) process.stderr.write(`[cron] ${unreadable.length} job(s) in jobs.json could not be read; kept as-is\n`);
    this.applyLoaded(jobs, unreadable);
  }

  private applyLoaded(jobs: BridgeCronJob[], unreadable: unknown[]): void {
    // 実行中のジョブの記録は差し替えない（終わったときの finish が古い参照を更新して保存するので）。
    this.jobs = jobs.map((job) => this.jobs.find((j) => j.id === job.id && this.running.has(j.id)) ?? job);
    this.unreadable = unreadable;
    this.loaded = true;
    this.loadError = undefined;
  }

  private failLoad(message: string, error: unknown): void {
    process.stderr.write(`[cron] ${message} ${error instanceof Error ? error.message : String(error)}\n`);
    this.loaded = false;
    this.loadError = message;
  }

  /** 壊れた jobs.json を jobs.json.broken-<時刻> に写す。写せたら退避先を返す。 */
  private backupBroken(): string | undefined {
    const backup = `${this.jobsFile}.broken-${formatOutputStamp(new Date())}`;
    try {
      fs.copyFileSync(this.jobsFile, backup, fs.constants.COPYFILE_EXCL);
      return backup;
    } catch (error) {
      // 同じ秒に二度目（既に退避済み）なら、それで足りる。
      return (error as NodeJS.ErrnoException).code === "EEXIST" ? backup : undefined;
    }
  }

  private save(): void {
    // 読めないままのファイルは上書きしない（空の一覧で全ジョブを消さない）。
    if (this.loadError) {
      process.stderr.write(`[cron] not saving jobs.json: ${this.loadError}\n`);
      return;
    }
    // 指示文と結果（会話の中身）なので、フォルダは 0700・ファイルは 0600（Linux / WSL。Windows では mode は効かない）。
    fs.mkdirSync(this.root, { recursive: true, mode: 0o700 });
    const tmp = `${this.jobsFile}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify([...this.jobs, ...this.unreadable], null, 2), { mode: 0o600 });
    fs.renameSync(tmp, this.jobsFile);
  }

  private nextFire(job: BridgeCronJob): Date | undefined {
    const schedule = parseSchedule(job.schedule);
    if (!schedule) return undefined;
    const base = new Date(job.lastRunAt ?? job.createdAt);
    const next = nextScheduleFire(schedule, base);
    if (!next) return undefined;
    return new Date(next.getTime() + cronJitterSeconds(job.id, schedule) * 1000);
  }

  private summary(job: BridgeCronJob): CronJobSummary {
    const state = this.running.has(job.id) ? "running" : job.enabled ? "scheduled" : "paused";
    const next = job.enabled ? this.nextFire(job) : undefined;
    const out: CronJobSummary = {
      id: job.id,
      name: job.name,
      prompt: job.prompt,
      scheduleDisplay: job.schedule,
      deliver: job.deliver,
      enabled: job.enabled,
      state
    };
    if (next) out.nextRunAt = formatLocalDateTime(next);
    if (job.lastRunAt) out.lastRunAt = formatLocalDateTime(new Date(job.lastRunAt));
    if (job.lastStatus) out.lastStatus = job.lastStatus;
    if (job.lastSessionId) out.lastSessionId = job.lastSessionId;
    return out;
  }

  private tick(): void {
    // 前回読めなかった jobs.json は、見回りのたびに読み直す。
    if (this.loadError) this.ensureLoaded();
    const now = Date.now();
    for (const job of this.jobs) {
      if (!job.enabled || this.running.has(job.id)) continue;
      const due = this.nextFire(job);
      if (!due || due.getTime() > now) continue;
      this.running.add(job.id);
      if (this.running.size === 1) this.options.onActiveChange?.(true);
      void this.execute(job).finally(() => {
        this.running.delete(job.id);
        if (this.running.size === 0) this.options.onActiveChange?.(false);
      });
    }
  }

  /** テスト用: いま期限のジョブを動かし、全部終わるまで待つ。 */
  async runDueNow(): Promise<void> {
    this.ensureLoaded();
    this.tick();
    while (this.running.size > 0) await new Promise((r) => setTimeout(r, 10));
  }

  private async execute(job: BridgeCronJob): Promise<void> {
    const adapter = this.options.adapterFor(job.agentId);
    if (!adapter) {
      this.finish(job.id, "error", "", "", "agent adapter not found");
      return;
    }
    let session: AgentSession;
    try {
      // 以前に作業フォルダなしで作ったジョブもホームで動かす（作成時と同じ確認を毎回通す）。
      const cwd = normalizeCronCwd(job.cwd);
      session = await adapter.openSession(undefined, cwd, { permissionMode: job.permissionMode, unattended: true });
    } catch (error) {
      this.finish(job.id, "error", "", "", error instanceof Error ? error.message : String(error));
      return;
    }
    let sessionId = "";
    const turns = new TurnCollector();
    let errorText: string | undefined;
    let timedOut = false;
    let resolveDone!: () => void;
    const finished = new Promise<void>((r) => (resolveDone = r));
    const timers: NodeJS.Timeout[] = [];
    const closeLater = (ms: number): void => {
      timers.push(
        setTimeout(() => {
          resolveDone();
        }, ms)
      );
    };
    let settle: NodeJS.Timeout | undefined;
    const collect = (evt: SessionEvent): void => {
      switch (evt.type) {
        case "session_started":
          if (evt.sessionId) sessionId = evt.sessionId;
          break;
        case "error":
          errorText = evt.content ?? "unknown error";
          // error だけ出して done を出さない adapter もあるので、少し待って打ち切る。
          closeLater(FORCE_CLOSE_AFTER_MS);
          break;
      }
      // 本文は最後の空でないターン。done の後もバックグラウンドの作業が動いていれば、知らせのターンの done まで集め続ける。
      if (turns.ingest(evt)) resolveDone();
      // 待っていた作業が終わったのに知らせのターンが始まらないときは、猶予の後に打ち切る。
      if (turns.waitingForBackground && !turns.backgroundRunning && !turns.turnStarted) {
        settle ??= setTimeout(resolveDone, BACKGROUND_SETTLE_GRACE_MS);
      } else if (settle) {
        clearTimeout(settle);
        settle = undefined;
      }
    };
    const deadline = setTimeout(() => {
      timedOut = true;
      void Promise.resolve(session.interrupt?.()).catch(() => {});
      closeLater(FORCE_CLOSE_AFTER_MS);
    }, this.options.runTimeoutMs ?? RUN_TIMEOUT_MS);
    timers.push(deadline);
    const original: SessionEvent = { type: "user_message", content: job.prompt };
    // send() がターン完了まで待たない adapter もあるので、終わりは done / error / 時間切れで決める。
    void session
      .send(job.prompt, original, collect)
      .catch((error) => {
        errorText = error instanceof Error ? error.message : String(error);
      })
      .finally(() => {
        // send が返った時点でターンが終わっている adapter のための保険（done が来ていれば何もしない）。
        // バックグラウンドの作業を待っている間は打ち切らない（時間切れの deadline が止める）。
        timers.push(
          setTimeout(() => {
            if (!turns.waitingForBackground && !turns.backgroundRunning) resolveDone();
          }, FORCE_CLOSE_AFTER_MS)
        );
      });
    await finished;
    for (const t of timers) clearTimeout(t);
    if (settle) clearTimeout(settle);
    turns.finishStream();
    const text = turns.text;
    await Promise.resolve(session.close()).catch(() => {});
    if (!sessionId) sessionId = session.sessionId.startsWith("pending") ? "" : session.sessionId;
    const status = timedOut ? "timeout" : errorText ? "error" : "ok";
    this.finish(job.id, status, sessionId, text, errorText);
  }

  private finish(jobId: string, status: string, sessionId: string, text: string, errorText?: string): void {
    const job = this.jobs.find((j) => j.id === jobId);
    if (!job) return; // 実行中に消された
    job.lastRunAt = new Date().toISOString();
    job.lastStatus = status;
    job.runsCompleted += 1;
    if (sessionId) job.lastSessionId = sessionId;
    if (job.repeatCount !== undefined && job.runsCompleted >= job.repeatCount) job.enabled = false;
    this.save();
    this.writeOutput(job, status, sessionId, text, errorText);
  }

  private writeOutput(job: BridgeCronJob, status: string, sessionId: string, text: string, errorText?: string): void {
    const dir = path.join(this.outputRoot, job.id);
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    let body = text.trim();
    if (errorText) body = body ? `${body}\n\n[error] ${errorText}` : `[error] ${errorText}`;
    if (!body) body = "(出力なし)";
    const header = [`# ${job.name}`, `agent: ${job.agentId}`, `status: ${status}`];
    if (sessionId) header.push(`session: ${sessionId}`);
    const content = `${header.join("\n")}\n---\n${body}\n`;
    const file = path.join(dir, `${formatOutputStamp(new Date())}.md`);
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, content, { mode: 0o600 });
    fs.renameSync(tmp, file);
  }
}
