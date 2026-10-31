import fs from "node:fs";
import path from "node:path";

/// claude --bg のセッションの台帳の読み取り（mac の ClaudeAgentsRegistry.swift の Windows 版。BACKGROUND_CONTROL §7.1・§7.2・§7.3）。
/// Windows は一覧をいつも CLI（claude agents --json --all）で作り、sessions\<pid>.json と jobs\<id>\state.json は
/// 足りない項目（生の status・受け箱・needs・detail・createdAt・shells・繰り返し）を足すためだけに読む。

export type BgState = "working" | "blocked" | "done" | "failed" | "stopped";

export const BG_STATES: readonly BgState[] = ["working", "blocked", "done", "failed", "stopped"];
export const BG_ID = /^[0-9a-f]{8}$/;

/** claude --bg のワーカーが動いている会話の「返事だけ止める」への答え（7.8）。 */
export const BG_INTERRUPT_TEXT =
  "このセッションは PC のバックグラウンドで動いています。返事だけを止めることはできません。止めるときは、会話のメニューの「停止」を使ってください（セッションごと止まります）。";

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);

export function isBgState(v: unknown): v is BgState {
  return typeof v === "string" && (BG_STATES as readonly string[]).includes(v);
}

/** 先頭の `{` に対応する `}` までを、文字列の中の括弧を数えずに切り出して読む。後ろのごみは捨てる。 */
export function parseTolerantObject(text: string): Obj | undefined {
  const start = text.indexOf("{");
  if (start < 0) return undefined;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = start; i < text.length; i++) {
    const c = text[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) {
      try {
        const value: unknown = JSON.parse(text.slice(start, i + 1));
        return value && typeof value === "object" && !Array.isArray(value) ? (value as Obj) : undefined;
      } catch {
        return undefined;
      }
    }
  }
  return undefined;
}

function readTolerantFile(file: string): Obj | undefined {
  try {
    return parseTolerantObject(fs.readFileSync(file, "utf8"));
  } catch {
    return undefined;
  }
}

// ---- CLI の出力 ----

/** claude agents --json --all の 1 行（kind が background のものだけ）。 */
export interface CliAgentRow {
  id: string;
  sessionId: string;
  cwd: string;
  name?: string;
  /** 生きているワーカーの pid（無ければ止まっている）。 */
  pid?: number;
  status?: string;
  waitingFor?: string;
  state?: string;
  startedAt?: number;
}

/** CLI の標準出力から background の行を取り出す。JSON の配列でなければ undefined（失敗として扱う）。 */
export function parseAgentsJson(stdout: string): CliAgentRow[] | undefined {
  let value: unknown;
  const text = stdout.trim();
  try {
    value = JSON.parse(text);
  } catch {
    const from = text.indexOf("[");
    const to = text.lastIndexOf("]");
    if (from < 0 || to <= from) return undefined;
    try {
      value = JSON.parse(text.slice(from, to + 1));
    } catch {
      return undefined;
    }
  }
  if (!Array.isArray(value)) return undefined;
  const rows: CliAgentRow[] = [];
  for (const item of value) {
    const o = obj(item);
    if (o.kind !== "background") continue;
    const sessionId = str(o.sessionId);
    // id の無い行は捨てる（sessionId の先頭から偽の id を作らない）。
    const id = str(o.id);
    if (!id || !sessionId || !BG_ID.test(id)) continue;
    rows.push({
      id,
      sessionId,
      cwd: str(o.cwd) ?? "",
      name: str(o.name),
      pid: num(o.pid),
      status: str(o.status),
      waitingFor: str(o.waitingFor),
      state: str(o.state),
      startedAt: num(o.startedAt)
    });
  }
  return rows;
}

// ---- sessions\<pid>.json ----

export interface SessionFile {
  pid?: number;
  sessionId?: string;
  kind?: string;
  entrypoint?: string;
  jobId?: string;
  name?: string;
  /** 生の status（busy / idle / waiting / shell など）。 */
  status?: string;
  startedAt?: number;
  /** 受け箱の宛先。名前付きパイプのパスか、存在するファイルのときだけ入る。 */
  messagingSocketPath?: string;
}

const PIPE_PREFIX = /^\\\\[.?]\\pipe\\/i;

export function usableInboxPath(p: string | undefined, exists: (file: string) => boolean = fs.existsSync): string | undefined {
  if (!p) return undefined;
  if (PIPE_PREFIX.test(p)) return p;
  return exists(p) ? p : undefined;
}

export function parseSessionFile(text: string, exists?: (file: string) => boolean): SessionFile | undefined {
  const o = parseTolerantObject(text);
  if (!o) return undefined;
  return {
    pid: num(o.pid),
    sessionId: str(o.sessionId),
    kind: str(o.kind),
    entrypoint: str(o.entrypoint),
    jobId: str(o.jobId),
    name: str(o.name),
    status: str(o.status),
    startedAt: num(o.startedAt),
    messagingSocketPath: usableInboxPath(str(o.messagingSocketPath), exists)
  };
}

/** sessions ディレクトリの `<pid>.json`（`*.key` は開かない）。 */
export function readSessionFile(sessionsDir: string, pid: number, exists?: (file: string) => boolean): SessionFile | undefined {
  try {
    return parseSessionFile(fs.readFileSync(path.join(sessionsDir, `${pid}.json`), "utf8"), exists);
  } catch {
    return undefined;
  }
}

export function sessionFileNames(names: string[]): string[] {
  return names.filter((n) => /^\d+\.json$/.test(n));
}

// ---- jobs\<id>\state.json ----

export interface JobRecord {
  state?: string;
  tempo?: string;
  detail?: string;
  needs?: string;
  intent?: string;
  name?: string;
  sessionId?: string;
  createdAtMs?: number;
  updatedAtMs?: number;
  firstTerminalAtMs?: number;
  lastTerminalAtMs?: number;
  linkScanPath?: string;
  /** state.json の template と respawnFlags の数（値は読み捨てる）。孤児の読み替えで exec の扱いを分けるのに使う。 */
  template?: string;
  respawnFlagCount?: number;
  /** いま動いている裏のコマンドの数（7.7）。 */
  shells: number;
  /** 繰り返し（7.2）。 */
  recurring: boolean;
  keptBy: boolean;
}

function isoMs(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v !== "string") return undefined;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : undefined;
}

/** `fan` があれば kind が shell の数。無ければ `inFlight.kinds` に local_bash があるとき `inFlight.tasks`。 */
export function countShells(o: Obj): number {
  if (Array.isArray(o.fan)) return o.fan.filter((f) => obj(f).kind === "shell").length;
  const inFlight = obj(o.inFlight);
  const kinds = Array.isArray(inFlight.kinds) ? inFlight.kinds : [];
  if (kinds.includes("local_bash")) return Math.max(0, Math.trunc(num(inFlight.tasks) ?? 0));
  return 0;
}

export function isRecurringJob(o: Obj): boolean {
  if (o.routine !== undefined && o.routine !== null && o.routine !== false && o.routine !== "") return true;
  if (o.selfWake === true) return true;
  const kinds = Array.isArray(obj(o.inFlight).kinds) ? (obj(o.inFlight).kinds as unknown[]) : [];
  if (kinds.includes("session_cron")) return true;
  return [o.intent, o.initialPrompt].some((v) => typeof v === "string" && v.trimStart().startsWith("/loop"));
}

export function parseJobState(text: string): JobRecord | undefined {
  const o = parseTolerantObject(text);
  if (!o) return undefined;
  return {
    state: str(o.state),
    tempo: str(o.tempo),
    detail: str(o.detail),
    needs: str(o.needs),
    intent: str(o.intent),
    name: str(o.name),
    sessionId: str(o.sessionId),
    createdAtMs: isoMs(o.createdAt),
    updatedAtMs: isoMs(o.updatedAt),
    firstTerminalAtMs: isoMs(o.firstTerminalAt),
    lastTerminalAtMs: isoMs(o.lastTerminalAt),
    linkScanPath: str(o.linkScanPath),
    template: str(o.template),
    respawnFlagCount: Array.isArray(o.respawnFlags) ? o.respawnFlags.length : undefined,
    shells: countShells(o),
    recurring: isRecurringJob(o),
    keptBy: o.keptBy !== undefined && o.keptBy !== null && o.keptBy !== false
  };
}

/** jobs の直下で名前が 8 桁の 16 進のディレクトリの state.json だけを読む。 */
export function readJobState(jobsDir: string, id: string): JobRecord | undefined {
  if (!BG_ID.test(id)) return undefined;
  try {
    return parseJobState(fs.readFileSync(path.join(jobsDir, id, "state.json"), "utf8"));
  } catch {
    return undefined;
  }
}

// ---- 状態の導出（§7.2。CLI の printAgentsJson と同じ） ----

const FINISHED = new Set(["done", "failed", "stopped"]);

export function isFinishedState(state: string | undefined, tempo: string | undefined): boolean {
  return state !== undefined && FINISHED.has(state) && tempo !== "active";
}

export function isBusyStatus(status: string | undefined): boolean {
  return status === "busy" || status === "shell";
}

export interface DeriveInput {
  id: string;
  job: JobRecord;
  /** 生きているワーカーの生の status（無ければ生きていない）。 */
  workerStatus?: string;
  /** roster のキー ∪ 生きている bg の jobId。 */
  shorts: ReadonlySet<string>;
  nowMs: number;
}

export interface Derived {
  state: BgState;
  /** 繰り返しの待ち（一覧には出すが Live Activity には数えない。7.2 の 4）。 */
  recurringWait: boolean;
}

export function deriveBgState(input: DeriveInput): Derived {
  const { job } = input;
  let state = job.state;
  let tempo = job.tempo;
  // createdAt が無い・読めないものは 0 とみなす（CLI と同じ）。
  const orphan =
    !isFinishedState(state, tempo) &&
    !input.shorts.has(input.id) &&
    input.nowMs - (job.createdAtMs ?? 0) >= 5000 &&
    !(job.keptBy && (job.intent ?? "") === "" && job.needs === "send a prompt to start" && tempo === "blocked");
  if (orphan) {
    // exec で respawnFlags が空の blocked は、再開できないので blocked のままにしない。
    if (state === "blocked" && !(job.template === "exec" && (job.respawnFlagCount ?? 0) === 0)) tempo = "blocked";
    else {
      state = "failed";
      tempo = "idle";
    }
  }
  const busy = isBusyStatus(input.workerStatus);
  const recurringDone = job.recurring && state === "done";
  const recurringWait = recurringDone && tempo !== "active" && !busy;
  let result: BgState;
  if (busy) result = "working";
  else if (isFinishedState(state, tempo) && !recurringDone) result = state as BgState;
  else if (tempo === "blocked" || input.workerStatus === "waiting") result = "blocked";
  else result = "working";
  return { state: result, recurringWait };
}

// ---- 行（§7.7） ----

export interface BgRow {
  id: string;
  sessionId: string;
  title: string;
  cwd: string;
  state: BgState;
  live: boolean;
  needs?: string;
  detail?: string;
  shells: number;
  createdAtMs: number;
}

export interface BgEntry {
  row: BgRow;
  recurringWait: boolean;
  /** 生の status。読めないときは CLI の busy かつ tempo が active のときだけ "busy"。 */
  workerStatus?: string;
  /** 受け箱の宛先（使えるときだけ）。 */
  inbox?: string;
  /** 最初の作業が終わった（firstTerminalAt がある）。 */
  firstTerminal: boolean;
  /** 終わった時刻（lastTerminalAt、無ければ updatedAt。7.3 の 24 時間に使う）。 */
  endedAtMs?: number;
  linkScanPath?: string;
}

const clip = (s: string, n: number): string => (s.length <= n ? s : s.slice(0, n));

export interface ComposeInput {
  cli: CliAgentRow;
  job?: JobRecord;
  session?: SessionFile;
  /** BuddyOS で付けた名前。 */
  buddyTitle?: string;
}

/** CLI の 1 行と、読めた分の sessions / state.json から一覧の 1 件を作る。読めなかった項目は無しのまま。 */
export function composeBgEntry({ cli, job, session, buddyTitle }: ComposeInput): BgEntry {
  const live = cli.pid !== undefined;
  const cliBusy = cli.status === "busy" && job?.tempo === "active";
  const workerStatus = live ? (session?.status ?? (cliBusy ? "busy" : cli.status === "busy" ? "unknown" : cli.status)) : undefined;

  let state: BgState = isBgState(cli.state) ? cli.state : "working";
  let recurringWait = false;
  if (!isBgState(cli.state) && job) {
    const derived = deriveBgState({ id: cli.id, job, workerStatus, shorts: new Set(live ? [cli.id] : []), nowMs: Date.now() });
    state = derived.state;
    recurringWait = derived.recurringWait;
  }
  if (job?.recurring && job.state === "done" && job.tempo !== "active" && !isBusyStatus(workerStatus) && state !== "failed" && state !== "stopped") {
    recurringWait = true;
  }

  const intentLine = (job?.intent ?? "").split(/\r?\n/)[0];
  const title = clip([buddyTitle, session?.name, job?.name, intentLine, cli.name].map((t) => (t ?? "").trim()).find((t) => t !== "") ?? "", 80);
  const row: BgRow = {
    id: cli.id,
    sessionId: cli.sessionId,
    title,
    cwd: cli.cwd,
    state,
    live,
    shells: live ? (job?.shells ?? 0) : 0,
    createdAtMs: job?.createdAtMs ?? cli.startedAt ?? 0
  };
  if (state === "blocked" && job?.needs) row.needs = clip(job.needs, 400);
  if (state === "failed" && job?.detail) row.detail = clip(job.detail, 200);
  return {
    row,
    recurringWait,
    workerStatus,
    inbox: session?.messagingSocketPath,
    firstTerminal: job?.firstTerminalAtMs !== undefined,
    endedAtMs: job ? (job.lastTerminalAtMs ?? job.updatedAtMs) : undefined,
    linkScanPath: job?.linkScanPath
  };
}

export const RECENT_MS = 24 * 3600_000;
export const MAX_ROWS = 50;

/** 一覧に出すもの（7.3 の 1）。出すのは live か working / blocked と、終わってから 24 時間以内（多くても 50 件）。 */
export function selectListed(entries: BgEntry[], nowMs: number): BgEntry[] {
  const listed = entries.filter((e) => {
    if (e.row.live || e.row.state === "working" || e.row.state === "blocked") return true;
    const ended = e.endedAtMs ?? e.row.createdAtMs;
    return nowMs - ended <= RECENT_MS;
  });
  return sortEntries(listed).slice(0, MAX_ROWS);
}

const ORDER: Record<BgState, number> = { blocked: 0, working: 1, done: 2, failed: 2, stopped: 2 };

/** blocked → working → ほか、同じ組は createdAtMs の新しい順。 */
export function sortEntries(entries: BgEntry[]): BgEntry[] {
  return [...entries].sort((a, b) => ORDER[a.row.state] - ORDER[b.row.state] || b.row.createdAtMs - a.row.createdAtMs);
}
