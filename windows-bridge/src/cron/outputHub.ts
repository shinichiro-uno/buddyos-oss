import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { SessionEvent } from "../protocol.js";
import { parseOutputStamp } from "./schedule.js";

/// cron の実行結果ファイル（<root>/<jobId>/<時刻>.md）を見張り、新しいものを接続中の全端末へ配って push する
/// （mac-bridge の CronOutputHub の移植）。見張る場所は Bridge 内蔵の cron の出力と、Hermes の
/// ~/.hermes/cron/output（addRoot で足す。WSL の Hermes は \\wsl.localhost\... を間隔をあけて見る）。

export type CronOutputListener = (evt: SessionEvent) => void;
export type CronPush = (title: string, body: string, data: Record<string, string>) => void;

const POLL_MS = 1500;
/// 起動直後や時計ずれで古い結果をまとめて通知しないよう、15 分より古いファイルは配らない。
const FRESH_MS = 15 * 60_000;

export function cronOutputEvent(
  agentId: string,
  jobId: string,
  jobName: string,
  timestamp: string,
  content: string,
  continuableSessionId?: string,
  silent = false
): SessionEvent {
  const metadata: Record<string, string> = { jobName, timestamp };
  if (continuableSessionId) metadata.continuableSessionId = continuableSessionId;
  if (silent) metadata.silent = "1";
  return { type: "cron_output", agentId, sessionId: jobId, content, metadata };
}

/**
 * 「知らせなくてよい」結果か。Hermes の cron が何もないときに返す約束なので Hermes の出力だけで見る
 * （mac の CronOutputWatcher.isSilentCronOutput と同じ。hermes の gateway/response_filters.py の
 * is_autonomous_silence_response と同じ判定で、hermes が配信を止めた出力だけ止める）。
 * - 応答（"## Response" より後）が "[SILENT]" で始まる
 * - 応答の全体・最初の行・最後の行のどれかが、ちょうど印（[SILENT] / SILENT / NO_REPLY / NO REPLY）
 * - "## Response" より前の見出し部分に "**Status:** silent" の行そのものがある
 * 本文の途中に "[SILENT]" が含まれるだけでは止めない（push と履歴から消えると、エージェントの出力で結果を隠せてしまう）。
 */
export function isSilentCronOutput(body: string, agentId: string): boolean {
  if (agentId !== "hermes") return false;
  const idx = body.indexOf("## Response");
  if (idx >= 0 && /^\*\*status:\*\*\s*silent\s*$/im.test(body.slice(0, idx))) return true;
  const response = (idx >= 0 ? body.slice(idx + "## Response".length) : body).trim();
  if (!response) return false;
  if (response.toUpperCase().startsWith("[SILENT]")) return true;
  const lines = response.split(/\r?\n/).filter((l) => l.trim().length > 0);
  return [response, lines[0] ?? "", lines.at(-1) ?? ""].some(isSilenceMarker);
}

const SILENCE_MARKERS = new Set(["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY"]);

/** 印だけの短い文字列か（64 文字まで。端の句読点は外して見るが、[ ] は外さない）。 */
function isSilenceMarker(text: string): boolean {
  const s = text.trim();
  if (!s || [...s].length > 64) return false;
  const canonical = (t: string): string => t.toUpperCase().split(/\s+/).filter(Boolean).join(" ");
  const edge = /[^[\]\P{P}]/u;
  const chars = [...s];
  let start = 0;
  let end = chars.length;
  while (start < end && edge.test(chars[start])) start++;
  while (end > start && edge.test(chars[end - 1])) end--;
  const trimmed = chars.slice(start, end).join("");
  return SILENCE_MARKERS.has(canonical(s)) || SILENCE_MARKERS.has(canonical(trimmed));
}

/** fixedAgent は Hermes の出力用（ヘッダ行を持たないので agent / session は読まない。mac と同じ）。 */
export function parseCronOutputFile(file: string, fixedAgent?: string): SessionEvent | undefined {
  let raw: string;
  try {
    raw = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
  } catch {
    return undefined;
  }
  const timestamp = path.basename(file, ".md");
  const jobId = path.basename(path.dirname(file));
  const firstLine = raw.split("\n", 1)[0] ?? "";
  const jobName = firstLine.startsWith("# ") ? firstLine.slice(2).trim() || jobId : jobId;
  const sep = raw.indexOf("\n---\n");
  const header = sep >= 0 ? raw.slice(0, sep) : "";
  const body = (sep >= 0 ? raw.slice(sep + 5) : raw).trim();
  if (fixedAgent) return cronOutputEvent(fixedAgent, jobId, jobName, timestamp, body, undefined, isSilentCronOutput(body, fixedAgent));
  const fields: Record<string, string> = {};
  for (const line of header.split("\n")) {
    const m = /^([a-z]+):\s*(.*)$/.exec(line);
    if (m) fields[m[1]] = m[2].trim();
  }
  const agentId = fields.agent || "claude";
  return cronOutputEvent(agentId, jobId, jobName, timestamp, body, fields.session || undefined, isSilentCronOutput(body, agentId));
}

/** 足して見張る出力の場所（Hermes の cron）。slow は WSL の UNC パス（9P は重いので間隔をあけて見る）。 */
interface ExtraRoot {
  root: string;
  agentId: string;
  slow: boolean;
}

/** slow の場所は POLL_MS × これごとに見る（約 15 秒）。 */
const SLOW_EVERY = 10;

export class CronOutputHub {
  private readonly listeners = new Set<CronOutputListener>();
  private seen = new Set<string>();
  private timer?: NodeJS.Timeout;
  private readonly seenFile: string;
  private readonly extraRoots: ExtraRoot[] = [];
  private tick = 0;

  constructor(
    private readonly outputRoot: string,
    private readonly push?: CronPush,
    seenFile = path.join(os.homedir(), ".buddyos", "cron_pushed.json")
  ) {
    this.seenFile = seenFile;
  }

  register(listener: CronOutputListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  start(): void {
    if (this.timer) return;
    fs.mkdirSync(this.outputRoot, { recursive: true });
    // 起動時点で既にあるファイルは「見た」扱いにする（再起動のたびに昔の結果を流さない）。
    this.seen = new Set([...this.loadSeen(), ...this.scan()]);
    this.saveSeen();
    this.timer = setInterval(() => this.poll(), POLL_MS);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  /**
   * Hermes の ~/.hermes/cron/output のような、ヘッダを持たない出力の場所を足す（mac の outputRoots と同じ）。
   * 足した時点で既にあるファイルは「見た」扱いにする。無いフォルダは作らない（Hermes が作る）。
   */
  addRoot(root: string, agentId: string, slow = false): void {
    if (root === this.outputRoot || this.extraRoots.some((r) => r.root === root)) return;
    const extra: ExtraRoot = { root, agentId, slow };
    this.extraRoots.push(extra);
    for (const f of this.scanRoot(root)) this.seen.add(f);
    this.saveSeen();
  }

  /** 1 回分の見回り（テストからも呼ぶ）。 */
  poll(): void {
    const withSlow = this.tick++ % SLOW_EVERY === 0;
    const current = this.scan(withSlow);
    const fresh = current.filter((f) => !this.seen.has(f));
    if (fresh.length === 0) return;
    for (const f of current) this.seen.add(f);
    this.saveSeen();
    for (const file of fresh) {
      const extra = this.extraRootOf(file);
      if (!this.isFresh(file, extra !== undefined)) continue;
      const evt = parseCronOutputFile(file, extra?.agentId);
      if (!evt || evt.metadata?.silent === "1") continue;
      for (const l of [...this.listeners]) l(evt);
      this.push?.(evt.metadata?.jobName ?? "Cron", Array.from(evt.content ?? "").slice(0, 200).join(""), {
        kind: "cron_output",
        jobId: evt.sessionId ?? "",
        timestamp: evt.metadata?.timestamp ?? "",
        sessionId: evt.metadata?.continuableSessionId ?? ""
      });
    }
  }

  /** 過去の結果（新しい順、silent は除く）。 */
  loadPast(jobId: string, limit = 200): SessionEvent[] {
    // 最初に見つかった場所の結果（mac と同じ。job の ID は Bridge の cron と Hermes で重ならない）。
    for (const { root, agentId } of [{ root: this.outputRoot, agentId: undefined }, ...this.extraRoots]) {
      const dir = path.join(root, jobId);
      let names: string[];
      try {
        names = fs.readdirSync(dir).filter((n) => n.endsWith(".md"));
      } catch {
        continue;
      }
      names.sort().reverse();
      const out: SessionEvent[] = [];
      for (const name of names) {
        if (out.length >= limit) break;
        const evt = parseCronOutputFile(path.join(dir, name), agentId);
        if (evt && evt.metadata?.silent !== "1") out.push(evt);
      }
      return out;
    }
    return [];
  }

  private extraRootOf(file: string): ExtraRoot | undefined {
    return this.extraRoots.find((r) => path.dirname(path.dirname(file)) === r.root);
  }

  /**
   * 15 分より古い結果は配らない。Hermes の出力は WSL の時刻帯で名前が付くことがある
   * （WSL が UTC だと名前の時刻が数時間ずれる）ので、名前ではなくファイルの更新時刻で見る。
   */
  private isFresh(file: string, byMtime: boolean): boolean {
    if (byMtime) {
      try {
        return Date.now() - fs.statSync(file).mtimeMs <= FRESH_MS;
      } catch {
        return false;
      }
    }
    const ts = parseOutputStamp(path.basename(file, ".md"));
    return !ts || Date.now() - ts.getTime() <= FRESH_MS;
  }

  private scan(withSlow = true): string[] {
    const files = this.scanRoot(this.outputRoot);
    for (const r of this.extraRoots) if (withSlow || !r.slow) files.push(...this.scanRoot(r.root));
    return files;
  }

  private scanRoot(root: string): string[] {
    const files: string[] = [];
    let dirs: fs.Dirent[];
    try {
      dirs = fs.readdirSync(root, { withFileTypes: true });
    } catch {
      return files;
    }
    for (const d of dirs) {
      if (!d.isDirectory()) continue;
      const dir = path.join(root, d.name);
      try {
        for (const n of fs.readdirSync(dir)) if (n.endsWith(".md")) files.push(path.join(dir, n));
      } catch {
        /* 消えた */
      }
    }
    return files;
  }

  private loadSeen(): string[] {
    try {
      const parsed = JSON.parse(fs.readFileSync(this.seenFile, "utf8"));
      return Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === "string") : [];
    } catch {
      return [];
    }
  }

  private saveSeen(): void {
    try {
      fs.mkdirSync(path.dirname(this.seenFile), { recursive: true });
      fs.writeFileSync(this.seenFile, JSON.stringify([...this.seen]));
    } catch {
      /* 次回また書く */
    }
  }
}
