import { existsSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { execRuntime } from "./agentProbe.js";
import type { RuntimeCommand } from "./runtime/command.js";

/// 公開したサイトの一覧（sites_request → sites_report。desktop/src/main/sites.ts の移植）。
/// この PC でログインしている CLI から読む（鍵は BuddyOS で預からない）。WSL 側の CLI は見ない（Windows で直接動かす）。
///   - Vercel: `vercel project ls --format json`（名前・本番の URL・更新日時。20 件ずつなので数ページ読む）
///   - Cloudflare Pages: `wrangler pages project list --json`（wrangler が無ければ npx で動かす）
/// Cloudflare Workers は CLI に一覧が無いので、まだ出さない。形は shared/protocol.json の payloads.sites_report。

export type SiteHost = "vercel" | "cloudflare";

export interface SiteHostStatus {
  host: SiteHost;
  state: "ok" | "missing" | "signedOut" | "error";
  /** Vercel の contextName（チーム・個人の名前）。 */
  account?: string;
  /** error のときだけ。stderr の末尾 3 行、400 文字まで。 */
  message?: string;
}

export interface SiteItem {
  host: SiteHost;
  name: string;
  url?: string;
  updatedAt?: string;
}

export interface SiteList {
  hosts: SiteHostStatus[];
  items: SiteItem[];
  at: string;
}

export interface RunResult {
  ok: boolean;
  /** CLI が見つからない。 */
  missing: boolean;
  out: string;
  err: string;
}

/** CLI を 1 回動かす（テストでは差し替える）。 */
export type SiteRunner = (command: string, args: string[], timeoutMs: number) => Promise<RunResult>;

const MAX_VERCEL_PAGES = 5;
const CACHE_MS = 5 * 60_000;

// npm / pnpm のグローバルの置き場所は PATH に入っていないことがある（サービスとして起動したとき等）。
const EXTRA_DIRS =
  process.platform === "win32"
    ? [process.env.APPDATA && join(process.env.APPDATA, "npm"), process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, "pnpm")]
    : ["/opt/homebrew/bin", "/usr/local/bin", join(homedir(), ".local", "bin"), join(homedir(), ".npm-global", "bin")];
// win32 では拡張子なしの候補（npm の sh シム）を除く（agentProbe の locateOnPath と同じ）。npm の CLI は .cmd。
const WIN_EXTS = [".exe", ".cmd", ".bat"];

function locate(command: string): string | undefined {
  const exts = process.platform === "win32" ? WIN_EXTS : [""];
  const dirs = [...(process.env.PATH ?? "").split(delimiter), ...EXTRA_DIRS].filter((d): d is string => Boolean(d));
  for (const dir of dirs) {
    for (const ext of exts) {
      const candidate = join(dir, command + ext);
      if (existsSync(candidate)) return candidate;
    }
  }
  return undefined;
}

/** 実際に CLI を動かす。.cmd は spawnRuntime が cmd.exe 経由で起こし、時間切れは子孫ごと止める（execRuntime）。 */
export const defaultRunner: SiteRunner = async (command, args, timeoutMs) => {
  const executable = locate(command);
  if (!executable) return { ok: false, missing: true, out: "", err: "" };
  const runtime: RuntimeCommand = { kind: "native", executable, label: `native:${executable}`, shell: false };
  // 作業のフォルダにある vercel.json / wrangler.toml を拾わないよう、一時フォルダで動かす。
  // 対話の入力待ち（ログイン・確認）で止まらないように CI=1。
  const r = await execRuntime(runtime, args, timeoutMs, {
    cwd: tmpdir(),
    env: { ...process.env, CI: "1", NO_COLOR: "1", FORCE_COLOR: "0" }
  });
  return {
    ok: r.ok,
    missing: /ENOENT/.test(r.error ?? ""),
    out: r.stdout,
    err: r.stderr.trim() || (r.error ?? "")
  };
};

/** 出力の先頭にある案内の行を飛ばして、{ か [ のところから JSON として読む（読めなければ次の位置から）。 */
export function parseJsonTail<T>(out: string, open: "{" | "["): T | null {
  for (let i = out.indexOf(open), tries = 0; i >= 0 && tries < 20; i = out.indexOf(open, i + 1), tries++) {
    try {
      return JSON.parse(out.slice(i)) as T;
    } catch {
      // 案内の中の [WARNING] 等。次へ。
    }
  }
  return null;
}

/** ログインしていないときの CLI の言い方。 */
export const notLoggedIn = (err: string): boolean => /not (be )?(logged|authenticated)|log ?in|credentials|authenticate/i.test(err);

export function hostStatus(host: SiteHost, r: RunResult): SiteHostStatus {
  if (r.missing) return { host, state: "missing" };
  if (notLoggedIn(r.err)) return { host, state: "signedOut" };
  return { host, state: "error", message: r.err.split(/\r?\n/).slice(-3).join("\n").slice(0, 400) };
}

interface VercelProject {
  name?: string;
  latestProductionUrl?: string | null;
  updatedAt?: number;
}

export function vercelItems(projects: VercelProject[]): SiteItem[] {
  return projects
    .filter((p) => typeof p.name === "string")
    .map((p) => ({
      host: "vercel" as const,
      name: p.name as string,
      url: p.latestProductionUrl || undefined,
      updatedAt: typeof p.updatedAt === "number" ? new Date(p.updatedAt).toISOString() : undefined
    }));
}

/** 古い vercel が --format を知らないときの言い方（39.0.4 で確認）。 */
export const tooOldVercel = (err: string): boolean => /unknown or unexpected option/i.test(err);

export async function readVercel(run: SiteRunner): Promise<{ status: SiteHostStatus; items: SiteItem[] }> {
  let viaNpx = false;
  const items: SiteItem[] = [];
  let next: number | undefined;
  let account: string | undefined;
  const ok = (): SiteHostStatus => ({ host: "vercel", state: "ok", ...(account ? { account } : {}) });
  for (let page = 0; page < MAX_VERCEL_PAGES; page++) {
    const args = ["project", "ls", "--format", "json", ...(next ? ["--next", String(next)] : [])];
    let r = viaNpx ? await run("npx", ["--yes", "vercel@latest", ...args], 120_000) : await run("vercel", args, 45_000);
    // 古い vercel（39.x など）は --format json を知らない。そのときは新しい版を npx で動かす。
    if (!viaNpx && !r.ok && tooOldVercel(r.err)) {
      viaNpx = true;
      r = await run("npx", ["--yes", "vercel@latest", ...args], 120_000);
    }
    const j = r.ok ? parseJsonTail<{ projects?: VercelProject[]; pagination?: { next?: number | null }; contextName?: string }>(r.out, "{") : null;
    // 2 ページ目から先で読めなければ、読めた分だけ返す。
    if (!j) return page === 0 ? { status: hostStatus("vercel", r), items: [] } : { status: ok(), items };
    account ??= typeof j.contextName === "string" && j.contextName ? j.contextName : undefined;
    items.push(...vercelItems(j.projects ?? []));
    next = j.pagination?.next ?? undefined;
    if (!next) break;
  }
  return { status: ok(), items };
}

interface PagesProject {
  "Project Name"?: string;
  "Project Domains"?: string;
  "Last Modified"?: string;
}

const UNIT_MS: Record<string, number> = {
  second: 1_000,
  minute: 60_000,
  hour: 3_600_000,
  day: 86_400_000,
  week: 7 * 86_400_000,
  month: 30 * 86_400_000,
  year: 365 * 86_400_000
};

/** wrangler の「6 days ago」「a minute ago」をおおよその日時にする（Vercel と並べて新しい順にするため）。読めなければ undefined。 */
export function parseAgo(text: string, now = Date.now()): string | undefined {
  const m = /^(\d+|an?)\s+(second|minute|hour|day|week|month|year)s?\s+ago$/i.exec(text.trim());
  if (!m) return undefined;
  const n = /^\d+$/.test(m[1]) ? Number(m[1]) : 1;
  return new Date(now - n * UNIT_MS[m[2].toLowerCase()]).toISOString();
}

export function pagesItems(projects: PagesProject[], now = Date.now()): SiteItem[] {
  return projects
    .filter((p) => typeof p["Project Name"] === "string")
    .map((p) => {
      const domains = (p["Project Domains"] ?? "").split(/[,\s]+/).filter(Boolean);
      // 自分のドメインがあればそちらを先に（*.pages.dev は後ろ）。
      const main = domains.find((d) => !d.endsWith(".pages.dev")) ?? domains[0];
      return {
        host: "cloudflare" as const,
        name: p["Project Name"] as string,
        url: main ? (main.startsWith("http") ? main : `https://${main}`) : undefined,
        updatedAt: parseAgo(p["Last Modified"] ?? "", now)
      };
    });
}

export async function readCloudflare(run: SiteRunner, now = Date.now): Promise<{ status: SiteHostStatus; items: SiteItem[] }> {
  const args = ["pages", "project", "list", "--json"];
  let r = await run("wrangler", args, 60_000);
  // wrangler を入れていない PC が多い。ログイン済みなら npx で動かせば読める（初回はダウンロードで時間がかかる）。
  if (r.missing) r = await run("npx", ["--yes", "wrangler@4", ...args], 120_000);
  const j = r.ok ? parseJsonTail<PagesProject[]>(r.out, "[") : null;
  if (!j || !Array.isArray(j)) return { status: hostStatus("cloudflare", r), items: [] };
  return { status: { host: "cloudflare", state: "ok" }, items: pagesItems(j, now()) };
}

export async function readSites(run: SiteRunner = defaultRunner): Promise<SiteList> {
  const [vercel, cloudflare] = await Promise.all([readVercel(run), readCloudflare(run)]);
  return { hosts: [vercel.status, cloudflare.status], items: [...vercel.items, ...cloudflare.items], at: new Date().toISOString() };
}

/** 5 分のキャッシュ付きの読み取り。読んでいる途中に来た要求は同じ結果を待つ。 */
export class SitesService {
  private cache?: { at: number; value: SiteList };
  private inflight?: Promise<SiteList>;

  constructor(
    private readonly readAll: () => Promise<SiteList> = () => readSites(),
    private readonly now: () => number = Date.now
  ) {}

  list(force = false): Promise<SiteList> {
    if (!force && this.cache && this.now() - this.cache.at < CACHE_MS) return Promise.resolve(this.cache.value);
    if (this.inflight) return this.inflight;
    const p = this.readAll()
      .then((value) => {
        this.cache = { at: this.now(), value };
        return value;
      })
      .finally(() => {
        if (this.inflight === p) this.inflight = undefined;
      });
    this.inflight = p;
    return p;
  }
}
