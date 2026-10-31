import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { agentRuntime, execRuntime } from "./agentProbe.js";
import { agentHome } from "./mcpService.js";
import type { SessionEvent } from "./protocol.js";
import { JsonRpcProcess } from "./runtime/jsonRpcProcess.js";
import { resolveClaudeUsage } from "./settings.js";

/// サブスクの使用量（5 時間枠・週枠）を集めて全端末へ配る（mac の UsageReader / UsageHub の移植）。
///   - Claude: ~/.claude/.credentials.json の OAuth トークンで api.anthropic.com/api/oauth/usage
///     （BUDDYOS_CLAUDE_USAGE=off・既定値が off のときは読まない・呼ばない。一覧にも出さない）
///   - Codex: `codex app-server` の account/rateLimits/read、だめなら ~/.codex/sessions の記録
///   - Antigravity: `agy -p /usage`
///   - Grok: `grok agent stdio`（ACP）の `_x.ai/billing`
/// 60 秒ごとに読み直し、usage_request で前倒しする。WSL で動くエージェントは WSL 側のホームを読む。

export interface UsageWindow {
  usedPercent: number;
  resetsAt?: string;
  windowMinutes?: number;
}

export interface ProviderUsage {
  provider: string;
  fiveHour?: UsageWindow;
  sevenDay?: UsageWindow;
  sevenDaySonnet?: UsageWindow;
  planType?: string;
  contextPressure?: number;
  error?: string;
  label?: string;
}

export interface UsageReport {
  providers: ProviderUsage[];
}

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const hasData = (p: ProviderUsage): boolean => !p.error && Boolean(p.fiveHour || p.sevenDay);

/* ── Claude ─────────────────────────────────────────────────────────── */

function claudeOauth(home: string): Record<string, unknown> | undefined {
  try {
    const parsed = obj(JSON.parse(fs.readFileSync(path.join(home, ".claude", ".credentials.json"), "utf8")));
    const oauth = obj(parsed.claudeAiOauth);
    return str(oauth.accessToken) ? oauth : undefined;
  } catch {
    return undefined;
  }
}

function claudeWindow(raw: unknown, windowMinutes: number): UsageWindow | undefined {
  const w = obj(raw);
  const utilization = num(w.utilization);
  if (utilization === undefined) return undefined;
  const out: UsageWindow = { usedPercent: Math.round(utilization), windowMinutes };
  const resets = str(w.resets_at);
  if (resets) out.resetsAt = resets;
  return out;
}

export async function readClaudeUsage(home: string | undefined): Promise<ProviderUsage> {
  const oauth = home ? claudeOauth(home) : undefined;
  if (!oauth) return { provider: "claude", error: "Claude OAuth token unavailable" };
  try {
    const res = await fetch("https://api.anthropic.com/api/oauth/usage", {
      headers: { Authorization: `Bearer ${str(oauth.accessToken)}`, "anthropic-beta": "oauth-2025-04-20" },
      signal: AbortSignal.timeout(15_000)
    });
    if (res.status !== 200) return { provider: "claude", error: `usage endpoint HTTP ${res.status}` };
    const body = await res.json().catch(() => undefined);
    if (!body || typeof body !== "object" || Array.isArray(body)) return { provider: "claude", error: "usage decode failed" };
    const o = body as Record<string, unknown>;
    const out: ProviderUsage = { provider: "claude" };
    const five = claudeWindow(o.five_hour, 300);
    const week = claudeWindow(o.seven_day, 10_080);
    const sonnet = claudeWindow(o.seven_day_sonnet, 10_080);
    if (five) out.fiveHour = five;
    if (week) out.sevenDay = week;
    if (sonnet) out.sevenDaySonnet = sonnet;
    const plan = str(oauth.subscriptionType);
    if (plan) out.planType = plan;
    const pressure = home ? readClaudeContextPressure(home) : undefined;
    if (pressure !== undefined) out.contextPressure = pressure;
    return out;
  } catch (error) {
    return { provider: "claude", error: error instanceof Error ? error.message : String(error) };
  }
}

function newestJsonl(dir: string, skipDir: string): string | undefined {
  let best: { file: string; mtime: number } | undefined;
  const walk = (d: string, depth: number): void => {
    if (depth > 4) return;
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) {
        if (e.name !== skipDir) walk(p, depth + 1);
      } else if (e.name.endsWith(".jsonl")) {
        try {
          const mtime = fs.statSync(p).mtimeMs;
          if (!best || mtime > best.mtime) best = { file: p, mtime };
        } catch {
          /* 消えた */
        }
      }
    }
  };
  walk(dir, 0);
  return best?.file;
}

function readSlice(file: string, start: number, length: number): string {
  const fd = fs.openSync(file, "r");
  try {
    const buf = Buffer.alloc(length);
    const n = fs.readSync(fd, buf, 0, length, start);
    return buf.subarray(0, n).toString("utf8");
  } finally {
    fs.closeSync(fd);
  }
}

/** 直近の会話がコンテキスト（1M 枠）をどれだけ使っているか（%）。1M のときだけ値を返す（mac と同じ）。 */
export function readClaudeContextPressure(home: string): number | undefined {
  try {
    const file = newestJsonl(path.join(home, ".claude", "projects"), "subagents");
    if (!file) return undefined;
    const size = fs.statSync(file).size;
    const tailLen = Math.min(size, 1024 * 1024);
    let tail = readSlice(file, size - tailLen, tailLen);
    if (size > tailLen) tail = tail.slice(tail.indexOf("\n") + 1);
    const lines = tail.split("\n");
    let total: number | undefined;
    let model: string | undefined;
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      const line = lines[i];
      if (!line.includes('"usage"')) continue;
      let o: Record<string, unknown>;
      try {
        o = obj(JSON.parse(line));
      } catch {
        continue;
      }
      if (o.type !== "assistant" || o.isSidechain === true) continue;
      const message = obj(o.message);
      const usage = obj(message.usage);
      if (!message.usage || message.model === "<synthetic>") continue;
      total = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"].reduce(
        (sum, k) => sum + (num(usage[k]) ?? 0),
        0
      );
      model = str(message.model);
      break;
    }
    if (total === undefined || !model || !/claude|sonnet|opus|haiku/.test(model)) return undefined;
    const identity = (text: string): string | undefined => {
      const ls = text.split("\n");
      for (let i = ls.length - 1; i >= 0; i -= 1) {
        if (!ls[i].includes('"identity"')) continue;
        try {
          const o = obj(JSON.parse(ls[i]));
          const att = obj(o.attachment);
          const id = str(obj(att.identity).modelId);
          if (o.type === "attachment" && att.type === "model" && id) return id;
        } catch {
          /* 途中の行 */
        }
      }
      return undefined;
    };
    let modelId = identity(tail);
    if (!modelId) {
      const headLen = Math.min(size, 256 * 1024);
      let head = readSlice(file, 0, headLen);
      if (size > headLen) head = head.slice(0, head.lastIndexOf("\n"));
      modelId = identity(head);
    }
    const is1M = Boolean(modelId && modelId.toLowerCase().includes("[1m]") && modelId.replace(/\[1m\]/gi, "") === model);
    if (!is1M && total <= 200_000) return undefined;
    return Math.min(100, Math.floor((total * 100) / 1_000_000));
  } catch {
    return undefined;
  }
}

/* ── Codex ──────────────────────────────────────────────────────────── */

function isWeekly(w: UsageWindow | undefined): boolean | undefined {
  const m = w?.windowMinutes;
  if (m === undefined || m <= 0) return undefined;
  return m > 24 * 60;
}

/** primary / secondary を 5 時間枠・週枠に振り分ける（mac の codexWindows と同じ）。 */
export function codexWindows(primary?: UsageWindow, secondary?: UsageWindow): { fiveHour?: UsageWindow; sevenDay?: UsageWindow } {
  const pw = isWeekly(primary) ?? (isWeekly(secondary) !== undefined ? !isWeekly(secondary) : undefined) ?? false;
  const sw = isWeekly(secondary) ?? (isWeekly(primary) !== undefined ? !isWeekly(primary) : undefined) ?? true;
  if (primary && secondary && pw === sw) return { fiveHour: primary, sevenDay: secondary };
  const out: { fiveHour?: UsageWindow; sevenDay?: UsageWindow } = {};
  for (const [w, weekly] of [[primary, pw], [secondary, sw]] as const) {
    if (!w) continue;
    if (weekly) out.sevenDay = w;
    else out.fiveHour = w;
  }
  return out;
}

function codexWindow(raw: unknown, usedKey: string, resetKey: string, minutesKey: string): UsageWindow | undefined {
  const w = obj(raw);
  const used = num(w[usedKey]);
  if (used === undefined) return undefined;
  const out: UsageWindow = { usedPercent: Math.round(used) };
  const resets = num(w[resetKey]);
  if (resets !== undefined && resets * 1000 > Date.now()) out.resetsAt = new Date(resets * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
  else out.usedPercent = 0;
  const minutes = num(w[minutesKey]);
  if (minutes !== undefined) out.windowMinutes = minutes;
  return out;
}

export function parseCodexSessionLine(line: string): ProviderUsage | undefined {
  if (!line.includes("rate_limits") || !line.includes("token_count")) return undefined;
  let o: Record<string, unknown>;
  try {
    o = obj(JSON.parse(line));
  } catch {
    return undefined;
  }
  const payload = obj(o.payload);
  if (o.type !== "event_msg" || payload.type !== "token_count" || !payload.rate_limits) return undefined;
  const rl = obj(payload.rate_limits);
  const windows = codexWindows(
    codexWindow(rl.primary, "used_percent", "resets_at", "window_minutes"),
    codexWindow(rl.secondary, "used_percent", "resets_at", "window_minutes")
  );
  const out: ProviderUsage = { provider: "codex", ...windows };
  const plan = str(rl.plan_type);
  if (plan) out.planType = plan;
  const info = obj(payload.info);
  const ctx = num(info.model_context_window) ?? num(payload.model_context_window) ?? num(payload.context_limit);
  const total = num(obj(info.last_token_usage).total_tokens) ?? num(payload.total_tokens);
  if (ctx && total !== undefined) out.contextPressure = Math.min(100, Math.floor((total * 100) / ctx));
  return out;
}

export function readCodexUsageFromSessions(home: string | undefined): ProviderUsage {
  const root = home ? path.join(home, ".codex", "sessions") : undefined;
  if (!root || !fs.existsSync(root)) return { provider: "codex", error: "Codex sessions directory not found" };
  const files: { file: string; mtime: number }[] = [];
  const cutoff = Date.now() - 7 * 86_400_000;
  const digits = (n: number) => new RegExp(`^\\d{${n}}$`);
  const sub = (d: string, re: RegExp) => {
    try {
      return fs.readdirSync(d).filter((n) => re.test(n)).map((n) => path.join(d, n));
    } catch {
      return [];
    }
  };
  for (const y of sub(root, digits(4)))
    for (const m of sub(y, digits(2)))
      for (const d of sub(m, digits(2)))
        for (const f of sub(d, /\.jsonl$/)) {
          try {
            const mtime = fs.statSync(f).mtimeMs;
            if (mtime >= cutoff) files.push({ file: f, mtime });
          } catch {
            /* 消えた */
          }
        }
  if (files.length === 0) return { provider: "codex", error: "No recent Codex sessions found" };
  files.sort((a, b) => b.mtime - a.mtime);
  for (const { file } of files) {
    let lines: string[];
    try {
      lines = fs.readFileSync(file, "utf8").split("\n");
    } catch {
      continue;
    }
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      const parsed = parseCodexSessionLine(lines[i]);
      if (parsed) return parsed;
    }
  }
  return { provider: "codex", error: "No rate limit data found in recent Codex sessions" };
}

async function fetchCodexRateLimits(runtimeLabel: string | undefined): Promise<ProviderUsage | undefined> {
  const runtime = agentRuntime("codex", runtimeLabel);
  if (!runtime) return undefined;
  let client: JsonRpcProcess | undefined;
  try {
    client = new JsonRpcProcess(runtime, ["app-server"], undefined, undefined, { jsonrpcField: false });
    client.on("stderr", () => {});
    const init = await client.request("initialize", { clientInfo: { name: "buddyos-usage", version: "1" } }, 10_000);
    if (init.error) return undefined;
    client.notify("initialized", {});
    const res = await client.request("account/rateLimits/read", {}, 10_000);
    const rl = obj(obj(res.result).rateLimits);
    if (!res.result) return undefined;
    const windows = codexWindows(
      codexWindow(rl.primary, "usedPercent", "resetsAt", "windowDurationMins"),
      codexWindow(rl.secondary, "usedPercent", "resetsAt", "windowDurationMins")
    );
    if (!windows.fiveHour && !windows.sevenDay) return undefined;
    const out: ProviderUsage = { provider: "codex", ...windows };
    const plan = str(rl.planType);
    if (plan) out.planType = plan;
    return out;
  } catch {
    return undefined;
  } finally {
    client?.close();
  }
}

/* ── Antigravity ────────────────────────────────────────────────────── */

/**
 * 枠の名前 → provider と表示名（mac-bridge の UsageReader.antigravityPool と同じ）。共通の 2 つのほかに、
 * モデル専用の枠（例: "Gemini 4 Argon" の週の上限）があるので、それは名前をそのまま出す（「Gemini」と取り違えない）。
 */
export function agyPool(name: string): { provider: string; label: string } {
  const n = name.toLowerCase();
  if (n === "gemini models") return { provider: "antigravity", label: "Gemini" };
  if (n.includes("claude") || n.includes("gpt")) return { provider: "antigravity:claude", label: "Claude / GPT" };
  const slug = n.split(/[^\p{L}\p{N}]+/u).filter(Boolean).join("-");
  return { provider: `antigravity:${slug}`, label: name };
}

export function parseAgyUsage(stdout: string): ProviderUsage[] {
  const pools = new Map<string, ProviderUsage>();
  for (const line of stdout.split(/\r?\n/)) {
    const cols = line.split("\t");
    if (cols.length < 3) continue;
    const remaining = Number.parseInt(cols[2].replace("%", "").trim(), 10);
    if (!Number.isFinite(remaining)) continue;
    const kind = cols[1].toLowerCase();
    const isWeek = kind.includes("weekly");
    if (!isWeek && !kind.includes("five hour")) continue;
    const name = cols[0].trim();
    let pool = pools.get(name);
    if (!pool) {
      pool = { ...agyPool(name) };
      pools.set(name, pool);
    }
    const w: UsageWindow = { usedPercent: Math.max(0, Math.min(100, 100 - remaining)), windowMinutes: isWeek ? 10_080 : 300 };
    if (cols[3]?.trim()) w.resetsAt = cols[3].trim();
    if (isWeek) pool.sevenDay = w;
    else pool.fiveHour = w;
  }
  return [...pools.values()];
}

async function readAntigravityUsage(runtimeLabel: string | undefined): Promise<ProviderUsage[]> {
  const runtime = agentRuntime("antigravity", runtimeLabel);
  if (!runtime) return [];
  const dir = runtime.kind === "wsl" ? "/tmp" : os.tmpdir();
  const r = await execRuntime(runtime, ["--add-dir", dir, "-p", "/usage"], 40_000, { cwd: runtime.kind === "wsl" ? undefined : dir });
  return r.ok ? parseAgyUsage(r.stdout) : [];
}

/* ── Grok（ACP の `_x.ai/billing`） ─────────────────────────────────────── */

/** `_x.ai/billing` の結果。週以外の期間も週の欄に出す（BuddyOS の表示は 5 時間と週の 2 枠。mac と同じ）。
 *  例: {"config":{"creditUsagePercent":3.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"…"}},"subscription_tier":"X Premium"} */
export function parseGrokBilling(result: unknown): ProviderUsage | undefined {
  const config = obj(obj(result).config);
  const percent = num(config.creditUsagePercent);
  if (percent === undefined) return undefined;
  const period = obj(config.currentPeriod);
  const w: UsageWindow = { usedPercent: Math.round(percent) };
  const resetsAt = str(period.end) ?? str(config.billingPeriodEnd);
  if (resetsAt) w.resetsAt = resetsAt;
  const type = str(period.type);
  if (type === "USAGE_PERIOD_TYPE_WEEKLY") w.windowMinutes = 10_080;
  else if (type === "USAGE_PERIOD_TYPE_DAILY") w.windowMinutes = 1_440;
  const out: ProviderUsage = { provider: "grok", sevenDay: w };
  const tier = str(obj(result).subscription_tier);
  if (tier) out.planType = tier;
  return out;
}

/** 使用率は ACP の独自メソッドが返す（モデルは呼ばない）。未導入・未ログインは空。 */
async function readGrokUsage(runtimeLabel: string | undefined): Promise<ProviderUsage[]> {
  const runtime = agentRuntime("grok", runtimeLabel);
  if (!runtime) return [];
  let client: JsonRpcProcess | undefined;
  try {
    client = new JsonRpcProcess(runtime, ["agent", "stdio"]);
    client.on("stderr", () => {});
    await client.request(
      "initialize",
      { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } }, clientInfo: { name: "BuddyOS-Bridge", version: "0.1" } },
      20_000
    );
    const res = await client.request("_x.ai/billing", {}, 20_000);
    const usage = parseGrokBilling(res.result);
    return usage ? [usage] : [];
  } catch {
    return [];
  } finally {
    client?.close();
  }
}

/* ── Hub ────────────────────────────────────────────────────────────── */

export interface UsageSources {
  /** エージェントの runtimeLabel（WSL で動くなら WSL 側を読む）。 */
  runtimeLabel(agentId: string): string | undefined;
}

type Listener = (evt: SessionEvent) => void;

const POLL_MS = 60_000;
const LAST_GOOD_MS = 30 * 60_000;
const CODEX_LIVE_TTL_MS = 120_000;
const AGY_TTL_MS = 5 * 60_000;
const GROK_TTL_MS = 5 * 60_000;

export class UsageHub {
  private readonly listeners = new Set<Listener>();
  private cached?: SessionEvent;
  private refreshing = false;
  private timer?: NodeJS.Timeout;
  private readonly lastGood = new Map<string, { at: number; usage: ProviderUsage }>();
  private codexLive?: { at: number; usage: ProviderUsage };
  private agy?: { at: number; usage: ProviderUsage[] };
  private grok?: { at: number; usage: ProviderUsage[] };

  constructor(
    private readonly sources: UsageSources,
    private readonly readAll: () => Promise<UsageReport> = () => this.defaultReadAll()
  ) {}

  /** 接続ごとに登録する。手元の最新値があればすぐ送る。初回の登録で見回りを始める。 */
  register(listener: Listener): () => void {
    this.listeners.add(listener);
    if (this.cached) listener(this.cached);
    if (!this.timer) {
      void this.refresh();
      this.timer = setInterval(() => void this.refresh(), POLL_MS);
      this.timer.unref();
    }
    return () => this.listeners.delete(listener);
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  /** usage_request。読み直し中なら、その結果が配られるので何もしない。 */
  requestRefresh(): Promise<void> {
    return this.refresh();
  }

  async refresh(): Promise<void> {
    if (this.refreshing) return;
    this.refreshing = true;
    try {
      const report = await this.readAll();
      const now = Date.now();
      const merged = report.providers.map((p) => {
        if (hasData(p)) {
          this.lastGood.set(p.provider, { at: now, usage: p });
          return p;
        }
        const good = this.lastGood.get(p.provider);
        return good && now - good.at < LAST_GOOD_MS ? good.usage : p;
      });
      this.cached = { type: "usage_report", content: JSON.stringify({ providers: merged }) };
      for (const l of [...this.listeners]) l(this.cached);
    } finally {
      this.refreshing = false;
    }
  }

  private async defaultReadAll(): Promise<UsageReport> {
    const claudeLabel = this.sources.runtimeLabel("claude");
    const codexLabel = this.sources.runtimeLabel("codex");
    const claudeOn = resolveClaudeUsage().value;
    const [claude, codex, agy, grok] = await Promise.all([
      claudeOn ? agentHome("claude", claudeLabel).then((home) => readClaudeUsage(home)) : Promise.resolve(undefined),
      this.readCodex(codexLabel),
      this.readAgy(this.sources.runtimeLabel("antigravity")),
      this.readGrok(this.sources.runtimeLabel("grok"))
    ]);
    // grok も未導入・未ログインの PC では出さない（mac と同じ）。
    return { providers: [...(claude ? [claude] : []), codex, ...agy.filter(hasData), ...grok.filter(hasData)] };
  }

  private async readGrok(runtimeLabel: string | undefined): Promise<ProviderUsage[]> {
    if (this.grok && Date.now() - this.grok.at < GROK_TTL_MS) return this.grok.usage;
    const usage = await readGrokUsage(runtimeLabel);
    this.grok = { at: Date.now(), usage };
    return usage;
  }

  private async readCodex(runtimeLabel: string | undefined): Promise<ProviderUsage> {
    const file = readCodexUsageFromSessions(await agentHome("codex", runtimeLabel));
    const withContext = (live: ProviderUsage): ProviderUsage =>
      file.contextPressure !== undefined ? { ...live, contextPressure: file.contextPressure } : live;
    if (this.codexLive && Date.now() - this.codexLive.at < CODEX_LIVE_TTL_MS) return withContext(this.codexLive.usage);
    const live = await fetchCodexRateLimits(runtimeLabel);
    if (!live) return file;
    this.codexLive = { at: Date.now(), usage: live };
    return withContext(live);
  }

  private async readAgy(runtimeLabel: string | undefined): Promise<ProviderUsage[]> {
    if (this.agy && Date.now() - this.agy.at < AGY_TTL_MS) return this.agy.usage;
    const usage = await readAntigravityUsage(runtimeLabel);
    this.agy = { at: Date.now(), usage };
    return usage;
  }
}
