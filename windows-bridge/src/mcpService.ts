// MCP server read/write for windows-bridge — TS mirror of mac-bridge McpService.
// Writes go through each agent's own CLI where one exists; Codex is written by
// surgical config.toml append (CLI-independent). Mirrors the Connector Store.

import { chmodSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { agentRuntime, execRuntime, wslWindowsHome } from "./agentProbe.js";
import { readBuddyMcpConfig, writeBuddyMcpConfig } from "./agents/buddyMcp.js";

export interface McpSummary {
  name: string;
  transport: string;
}

export interface McpRegisterSpec {
  serverName: string;
  transportKind: "url" | "command";
  url?: string;
  command?: string;
  args: string[];
  authType: string;
  env: Record<string, string>;
}

export type OpResult = { ok: boolean; message?: string };

const baseId = (id: string): string => id.split("-")[0];
/** base = 設定ファイルの基準になるホーム（agentHome で解決する）。 */
const home = (base: string, rel: string): string => join(base, rel);

/** MCP 設定ファイルの基準ディレクトリ（~）。WSL で動く adapter は WSL 側の $HOME を UNC パスで使う
 *  （Windows 側の ~ を読み書きすると、WSL の CLI が実際に使う設定とずれる）。解決できなければ undefined。 */
export async function agentHome(agentId: string, runtimeLabel?: string): Promise<string | undefined> {
  const runtime = agentRuntime(agentId, runtimeLabel);
  return runtime?.kind === "wsl" ? wslWindowsHome(runtime) : homedir();
}

const WSL_HOME_UNRESOLVED = "WSL 側のホームディレクトリを解決できません（WSL が起動しているか確認してください）";

/* ── Read ─────────────────────────────────────────────────────────────── */

/** runtimeLabel は adapter.runtimeLabel（WSL で動く adapter は WSL 側の設定を読む）。 */
export async function listMcp(agentId: string, runtimeLabel?: string): Promise<McpSummary[]> {
  // Buddy は Bridge の中で動くので、Bridge の ~/.buddyos/buddy-mcp.json を読む。
  if (baseId(agentId) === "buddy") {
    return Object.entries(readBuddyMcpConfig())
      .map(([name, def]) => ({
        name,
        transport: transportFrom(typeof def.url === "string" ? def.url : undefined, typeof def.command === "string" ? def.command : undefined, Array.isArray(def.args) ? def.args.map(String) : undefined)
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
  }
  const base = await agentHome(agentId, runtimeLabel);
  return base ? listMcpAt(agentId, base) : [];
}

function listMcpAt(agentId: string, base: string): McpSummary[] {
  switch (baseId(agentId)) {
    case "claude":
      return listClaude(base);
    case "codex":
      return listCodex(base);
    case "openclaw":
      return listOpenclaw(base);
    case "hermes":
      return listHermes(base);
    case "opencode":
      return listOpencode(base);
    case "cursor":
      return listJsonMcp(cursorConfigPath(base));
    case "antigravity":
      return listJsonMcp(antigravityConfigPath(base));
    case "grok":
      // Grok は ~/.grok/config.toml の [mcp_servers.*]（Codex と同じ TOML）。
      return listCodex(base, ".grok/config.toml");
    default:
      return [];
  }
}

/* ── Cursor / Antigravity（mcpServers の JSON。mac の listJsonMcpServers と同じ） ── */

const cursorConfigPath = (base: string): string => home(base, ".cursor/mcp.json");
/** agy が読む MCP 設定（`agy mcp add` の書き込み先。http のサーバは serverUrl で持つ）。 */
const antigravityConfigPath = (base: string): string => home(base, ".gemini/config/mcp_config.json");

function readJsonObject(path: string): Record<string, unknown> | undefined {
  const raw = readText(path)?.replace(/^\uFEFF/, "");
  if (!raw?.trim()) return undefined;
  try {
    const parsed: unknown = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

export function listJsonMcp(path: string): McpSummary[] {
  const servers = readJsonObject(path)?.mcpServers;
  if (!servers || typeof servers !== "object" || Array.isArray(servers)) return [];
  const result: McpSummary[] = [];
  for (const [name, raw] of Object.entries(servers as Record<string, Record<string, unknown>>)) {
    const def = raw && typeof raw === "object" ? raw : {};
    if (def.enabled === false || def.disabled === true) continue;
    // CLI ごとに URL のキー名が違う（Claude / Cursor: url、agy: serverUrl、Gemini 系: httpUrl）。
    const url = ["url", "serverUrl", "httpUrl"].map((k) => def[k]).find((v): v is string => typeof v === "string" && v.length > 0);
    const command = typeof def.command === "string" && def.command ? def.command : undefined;
    const args = Array.isArray(def.args) ? def.args.map(String) : undefined;
    result.push({ name, transport: transportFrom(url, command, args) });
  }
  return result.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
}

/** "mcpServers" に 1 件足す（読み直して書く。ほかのキーは残す）。CLI の設定には知らないキーを足さない。 */
function registerJsonMcp(path: string, name: string, spec: McpRegisterSpec): OpResult {
  const root = readJsonObject(path);
  // 読めない（JSONC 等）まま {} から書き戻すと既存の設定が消えるので中止する
  if (!root && readText(path)?.trim()) return { ok: false, message: "MCP の設定ファイルを解析できないため追加できません" };
  const config = root ?? {};
  const servers = { ...((config.mcpServers as Record<string, unknown> | undefined) ?? {}) };
  let entry: Record<string, unknown>;
  if (spec.transportKind === "url" && spec.url) {
    entry = { url: spec.url };
    if (Object.keys(spec.env).length > 0) entry.headers = { ...spec.env };
  } else if (spec.command) {
    entry = { command: spec.command };
    if (spec.args.length > 0) entry.args = spec.args;
    if (Object.keys(spec.env).length > 0) entry.env = { ...spec.env };
  } else {
    return { ok: false, message: "transport が不正です" };
  }
  servers[name] = entry;
  config.mcpServers = servers;
  return writeJsonFile(path, config);
}

function deleteJsonMcp(path: string, name: string): OpResult {
  const config = readJsonObject(path);
  const servers = config?.mcpServers as Record<string, unknown> | undefined;
  if (!config || !servers || !(name in servers)) return { ok: true, message: "ok" };
  const next = { ...servers };
  delete next[name];
  config.mcpServers = next;
  return writeJsonFile(path, config);
}

function writeJsonFile(path: string, config: Record<string, unknown>): OpResult {
  const tmp = `${path}.tmp-${process.pid}`;
  try {
    mkdirSync(dirname(path), { recursive: true });
    // headers / env にトークンが平文で入るので新規は 0600（Windows では ACL はフォルダの継承）
    writeFileSync(tmp, `${JSON.stringify(config, null, 2)}\n`, { encoding: "utf8", mode: 0o600 });
    renameSync(tmp, path);
    return { ok: true, message: "ok" };
  } catch (e) {
    try {
      unlinkSync(tmp);
    } catch {
      /* tmp が無ければ何もしない */
    }
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

/** `<cli> mcp add`（agy / grok）の引数。フラグは名前より前に置き（agy は名前の後のフラグを拒否する）、
 *  コマンドは `--` の後ろに置いて `-y` などを CLI のフラグと取り違えさせない（mac と同じ）。 */
export function cliMcpAddArgs(name: string, spec: McpRegisterSpec): string[] | undefined {
  const args = ["mcp", "add"];
  const keys = Object.keys(spec.env).sort();
  if (spec.transportKind === "url" && spec.url) {
    for (const k of keys) args.push("--header", `${k}: ${spec.env[k]}`);
    args.push(name, spec.url);
  } else if (spec.command) {
    for (const k of keys) args.push("--env", `${k}=${spec.env[k]}`);
    args.push(name, "--", spec.command, ...spec.args);
  } else {
    return undefined;
  }
  return args;
}

/* ── Codex の OAuth トークン（mac の McpTokenVault の移植） ─────────────────
 * codex の url 型 MCP は HTTP ヘッダを config に書けず、bearer_token_env_var（環境変数名）しか読まない。
 * トークン本体は ~/.buddyos/mcp-tokens.json（serverName → 生トークン）に置き、codex の起動時に環境変数で渡す。 */

const mcpTokenFile = (): string => join(homedir(), ".buddyos", "mcp-tokens.json");

/** serverName から環境変数名（英数以外は _、大文字、BUDDYOS_MCP_ 接頭辞）。例: "github" → BUDDYOS_MCP_GITHUB */
export function mcpTokenEnvVarName(serverName: string): string {
  return "BUDDYOS_MCP_" + Array.from(serverName.toUpperCase(), (ch) => (/[\p{L}\p{N}]/u.test(ch) ? ch : "_")).join("");
}

function loadMcpTokens(): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(readJsonObject(mcpTokenFile()) ?? {})) if (typeof v === "string") out[k] = v;
  return out;
}

function setMcpToken(serverName: string, token: string | undefined): void {
  const all = loadMcpTokens();
  if (token === undefined) {
    if (!(serverName in all)) return;
    delete all[serverName];
  } else {
    all[serverName] = token;
  }
  writeJsonFile(mcpTokenFile(), all);
}

/** codex の子プロセスに足す環境変数（{BUDDYOS_MCP_<NAME>: トークン}）。 */
export function mcpTokenEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [name, token] of Object.entries(loadMcpTokens())) env[mcpTokenEnvVarName(name)] = token;
  return env;
}

function readText(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return undefined;
  }
}

function transportFrom(url?: string, command?: string, args?: string[]): string {
  if (url) return url;
  if (command) return args && args.length > 0 ? `${command} ${args.join(" ")}` : command;
  return "(unknown)";
}

/** settings.json → settings.local.json → ~/.claude.json の順に読み、同名はあとに読んだ方が勝つ。
 *  ~/.claude.json のトップレベル mcpServers は `claude mcp add --scope user`（registerClaude）の書き込み先。 */
function listClaude(base: string): McpSummary[] {
  const merged = new Map<string, McpSummary>();
  for (const rel of [".claude/settings.json", ".claude/settings.local.json", ".claude.json"]) {
    const raw = readText(home(base, rel));
    if (!raw) continue;
    try {
      const root = JSON.parse(raw) as { mcpServers?: Record<string, { url?: string; command?: string; args?: string[] }> };
      for (const [name, def] of Object.entries(root.mcpServers ?? {})) {
        merged.set(name, { name, transport: transportFrom(def.url, def.command, def.args) });
      }
    } catch {
      /* ignore malformed */
    }
  }
  return [...merged.values()].sort((a, b) => a.name.localeCompare(b.name));
}

function listOpenclaw(base: string): McpSummary[] {
  const raw = readText(home(base, ".openclaw/openclaw.json"));
  if (!raw) return [];
  try {
    const root = JSON.parse(raw) as { plugins?: { entries?: Record<string, { enabled?: boolean }> } };
    return Object.entries(root.plugins?.entries ?? {})
      .filter(([, v]) => v.enabled === true)
      .map(([name]) => ({ name, transport: "openclaw-plugin" }))
      .sort((a, b) => a.name.localeCompare(b.name));
  } catch {
    return [];
  }
}

/** Minimal TOML scan for top-level `[mcp_servers.NAME]` blocks.
 *  ヘッダは deleteCodex と同じ tomlHeaderKeys で読む（行末コメント・クォート付きでドットを含む名前を許す。
 *  shared/fixtures/codex/home/.codex/config.toml）。サブテーブル（.env / .tools）以降の行はサーバの値にしない。 */
function listCodex(base: string, rel = ".codex/config.toml"): McpSummary[] {
  const raw = readText(home(base, rel));
  if (!raw) return [];
  const result: McpSummary[] = [];
  let cur: { name: string; url?: string; command?: string; args: string[]; type?: string } | null = null;
  const flush = (): void => {
    // url も command も無ければ type（mac の parseToml と同じ）。
    if (cur) result.push({ name: cur.name, transport: cur.url || cur.command ? transportFrom(cur.url, cur.command, cur.args) : cur.type || "(unknown)" });
    cur = null;
  };
  for (const rawLine of raw.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const keys = tomlHeaderKeys(line);
    if (keys) {
      flush();
      if (keys.length === 2 && keys[0] === "mcp_servers") cur = { name: keys[1], args: [] };
      continue;
    }
    if (!cur) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    const value = line.slice(eq + 1).trim();
    if (key === "url") cur.url = stripQuotes(value);
    else if (key === "command") cur.command = stripQuotes(value);
    else if (key === "args") cur.args = parseInlineList(value);
    else if (key === "type") cur.type = stripQuotes(value);
  }
  flush();
  return result.sort((a, b) => a.name.localeCompare(b.name));
}

/** Minimal YAML scan for the `mcp_servers:` block. */
function listHermes(base: string): McpSummary[] {
  const raw = readText(home(base, ".hermes/config.yaml"));
  if (!raw) return [];
  const result: McpSummary[] = [];
  let inBlock = false;
  let nameIndent: number | null = null;
  let cur: { name: string; url?: string; command?: string; args: string[] } | null = null;
  const flush = (): void => {
    if (cur) result.push({ name: cur.name, transport: transportFrom(cur.url, cur.command, cur.args) });
    cur = null;
  };
  for (const rawLine of raw.split("\n")) {
    const trimmed = rawLine.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const indent = rawLine.length - rawLine.trimStart().length;
    const body = rawLine.slice(indent);
    if (indent === 0) {
      flush();
      inBlock = body.startsWith("mcp_servers:");
      nameIndent = null;
      continue;
    }
    if (!inBlock) continue;
    if (nameIndent === null) nameIndent = indent;
    if (indent === nameIndent) {
      flush();
      const name = body.split(":")[0]?.trim() ?? "";
      if (name) cur = { name, args: [] };
    } else if (cur && indent > (nameIndent ?? 0)) {
      const idx = body.indexOf(":");
      if (idx < 0) continue;
      const key = body.slice(0, idx).trim();
      const value = body.slice(idx + 1).trim();
      if (key === "url") cur.url = stripQuotes(value);
      else if (key === "command") cur.command = stripQuotes(value);
      else if (key === "args") cur.args = parseInlineList(value);
    }
  }
  flush();
  return result.sort((a, b) => a.name.localeCompare(b.name));
}

/* ── OpenCode (~/.config/opencode/opencode.json "mcp") ────────────────────── */

interface OpencodeMcpEntry {
  type?: string;
  url?: string;
  command?: string[];
  enabled?: boolean;
  headers?: Record<string, string>;
  environment?: Record<string, string>;
}

const opencodeConfigPath = (base: string): string => home(base, ".config/opencode/opencode.json");

/** opencode.json の root object を読む。ファイルが無い／空なら空 object、読めない・中身が
 *  object として解析できない（JSONC のコメントや末尾カンマ等）なら null（呼び出し側は書き込まない）。
 *  null のまま {} から書き戻すと provider / model / 既存 mcp が全部消えるため。 */
function readOpencodeConfig(base: string): Record<string, unknown> | null {
  let raw: string;
  try {
    raw = readFileSync(opencodeConfigPath(base), "utf8");
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "ENOENT" ? {} : null;
  }
  raw = raw.replace(/^\uFEFF/, "");
  if (!raw.trim()) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function opencodeMcpObject(config: Record<string, unknown>): Record<string, OpencodeMcpEntry> {
  const mcp = config.mcp;
  return mcp && typeof mcp === "object" && !Array.isArray(mcp) ? (mcp as Record<string, OpencodeMcpEntry>) : {};
}

function listOpencode(base: string): McpSummary[] {
  const mcp = opencodeMcpObject(readOpencodeConfig(base) ?? {});
  return Object.entries(mcp)
    .map(([name, def]) => {
      const transport = def.type === "remote" || def.url
        ? def.url ?? "(unknown)"
        : Array.isArray(def.command)
          ? def.command.join(" ")
          : "(unknown)";
      return { name, transport };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** \\wsl$\<distro>\... / \\wsl.localhost\<distro>\...（WSL 側のファイルを 9P 経由で見る UNC パス）か。 */
const isWslUncPath = (p: string): boolean => /^[\\/]{2}wsl(\$|\.localhost)[\\/]/i.test(p);

function writeOpencodeConfig(base: string, config: Record<string, unknown>): OpResult {
  return writeJsonConfig(opencodeConfigPath(base), config);
}

/** JSON の設定ファイルを書き換える（opencode.json / ~/.claude.json）。secret なら所有者だけが読める 0600 に絞る。 */
function writeJsonConfig(target: string, config: Record<string, unknown>, secret = false): OpResult {
  let path = target;
  // dotfiles 管理（stow 等）のシンボリックリンクなら実体に書く（rename でリンク自体を通常ファイルに置き換えない）
  try {
    path = realpathSync(path);
  } catch {
    /* 未作成・解決できないリンクは path のまま */
  }
  // 既存ファイルのモードを引き継ぎ、新規は 0o600（headers / environment に OAuth トークン等が平文で入るため）。
  // mode が効くのは POSIX だけ。Windows 版 Node では読み取り専用属性にしか反映されない（ACL は親ディレクトリの継承）。
  let mode = 0o600;
  try {
    mode = statSync(path).mode & 0o777;
  } catch {
    /* 新規作成 */
  }
  if (secret) mode &= 0o600;
  const data = `${JSON.stringify(config, null, 2)}\n`;
  const tmp = `${path}.tmp-${process.pid}`;
  try {
    mkdirSync(dirname(path), { recursive: true });
    if (isWslUncPath(path)) {
      // WSL 側は Windows から Linux のモードを引き継げず、rename で置き換えると chmod 600 等が
      // 9P の既定値（多くは 0644）に戻るので、その場で上書きする（inode・モードを保つ）。
      writeFileSync(path, data, "utf8");
    } else {
      // 一時ファイル（実体と同じディレクトリ）に書いてから rename（途中で落ちても設定ファイルを壊さない）
      writeFileSync(tmp, data, { encoding: "utf8", mode });
      chmodSync(tmp, mode); // writeFileSync の mode は umask で削られるので合わせ直す
      renameSync(tmp, path);
    }
    return { ok: true, message: "ok" };
  } catch (e) {
    try {
      unlinkSync(tmp);
    } catch {
      /* tmp が無ければ何もしない */
    }
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

function registerOpencode(base: string, name: string, spec: McpRegisterSpec): OpResult {
  const config = readOpencodeConfig(base);
  if (!config) {
    return { ok: false, message: "opencode.json を解析できないため追加できません（コメント等を含む場合は手動で追加してください）" };
  }
  const mcp = { ...opencodeMcpObject(config) };
  let entry: OpencodeMcpEntry;
  if (spec.transportKind === "url" && spec.url) {
    entry = { type: "remote", url: spec.url, enabled: true };
    if (Object.keys(spec.env).length > 0) entry.headers = { ...spec.env };
  } else if (spec.command) {
    entry = { type: "local", command: [spec.command, ...spec.args], enabled: true };
    if (Object.keys(spec.env).length > 0) entry.environment = { ...spec.env };
  } else {
    return { ok: false, message: "transport が不正です" };
  }
  mcp[name] = entry;
  config.mcp = mcp;
  return writeOpencodeConfig(base, config);
}

function deleteOpencode(base: string, name: string): OpResult {
  const config = readOpencodeConfig(base);
  // ファイル無し／空 = {} = 既に存在しない。読めないときは成功と偽らずエラーにする
  if (!config) return { ok: false, message: "opencode.json を解析できないため削除できません" };
  const mcp = { ...opencodeMcpObject(config) };
  if (!(name in mcp)) return { ok: true, message: "ok" };
  delete mcp[name];
  config.mcp = mcp;
  return writeOpencodeConfig(base, config);
}

function stripQuotes(s: string): string {
  if (s.length >= 2 && ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))) {
    return s.slice(1, -1);
  }
  return s;
}

function parseInlineList(raw: string): string[] {
  const t = raw.trim();
  if (!t.startsWith("[") || !t.endsWith("]")) return [];
  return t
    .slice(1, -1)
    .split(",")
    .map((x) => stripQuotes(x.trim()))
    .filter((x) => x.length > 0);
}

/* ── Write ────────────────────────────────────────────────────────────── */

/** runtimeLabel は adapter.runtimeLabel。WSL で動く adapter は CLI を wsl.exe 経由で実行し、
 *  直接書き込む設定ファイル（codex / opencode）も WSL 側のホームを使う。 */
/** registerMcp が書ける agent（設定の持ち主の id）。capabilities.mcpRegister の出どころ。 */
const MCP_REGISTRABLE = new Set(["claude", "codex", "hermes", "opencode", "buddy", "cursor", "grok", "antigravity"]);

/** その agent 自身の設定へ書けるか（MCP_REGISTRABLE に無い id は false）。 */
export function mcpRegisterSupported(agentId: string): boolean {
  return MCP_REGISTRABLE.has(agentId);
}

export async function registerMcp(agentId: string, spec: McpRegisterSpec, runtimeLabel?: string): Promise<OpResult> {
  const name = spec.serverName.trim();
  if (!name) return { ok: false, message: "サーバ名が空です" };
  if (baseId(agentId) === "openclaw") return { ok: false, message: "OpenCLAW は Connector Store での追加に未対応です" };
  if (baseId(agentId) === "buddy") {
    const servers = readBuddyMcpConfig();
    if (servers[name] && spec.authType !== "oauth") return { ok: false, message: `${name} は既に接続済みです` };
    servers[name] =
      spec.transportKind === "url"
        ? { url: spec.url ?? "", ...(Object.keys(spec.env).length > 0 ? { headers: spec.env } : {}) }
        : { command: spec.command ?? "", args: spec.args, ...(Object.keys(spec.env).length > 0 ? { env: spec.env } : {}) };
    try {
      writeBuddyMcpConfig(servers);
      return { ok: true, message: "ok" };
    } catch (error) {
      return { ok: false, message: error instanceof Error ? error.message : String(error) };
    }
  }
  const base = await agentHome(agentId, runtimeLabel);
  if (!base) return { ok: false, message: WSL_HOME_UNRESOLVED };
  // OAuth はトークン更新のたびに再登録する設計なので upsert（削除→追加）する。
  // 手動登録の誤上書きを防ぐため oauth 以外は従来どおりエラーにする（mac と同じ）。
  let upserting = false;
  if (listMcpAt(agentId, base).some((s) => s.name === name)) {
    if (spec.authType !== "oauth") return { ok: false, message: `${name} は既に接続済みです` };
    // Hermes は `hermes mcp add` が対話式で非対話では保存されないので、既存を残して成功扱い
    if (baseId(agentId) === "hermes") return { ok: true, message: "ok" };
    // 削除に失敗したまま追加すると codex は同名テーブルが重複して起動できず、claude は同名が二重登録になる
    // codex は本体だけを消し、「常に許可」したツールの承認（[mcp_servers.NAME.tools.*]）を残す（mac と同じ）。
    const d = baseId(agentId) === "codex" ? deleteCodex(base, name, true) : await deleteMcp(agentId, name, runtimeLabel);
    if (!d.ok) return { ok: false, message: `既存の ${name} を更新できません: ${d.message ?? ""}` };
    upserting = true;
  }

  switch (baseId(agentId)) {
    case "claude":
      return registerClaude(agentId, name, spec, runtimeLabel);
    case "codex": {
      const r = registerCodex(base, name, spec);
      // 承認だけ残ると transport の無い mcp_servers.NAME になり codex が起動できないので、失敗したら一緒に消す
      if (!r.ok && upserting) deleteCodex(base, name);
      return r;
    }
    case "cursor":
      return registerJsonMcp(cursorConfigPath(base), name, spec);
    case "grok":
    case "antigravity": {
      const args = cliMcpAddArgs(name, spec);
      return args ? runAgentCli(agentId, args, runtimeLabel) : { ok: false, message: "transport が不正です" };
    }
    case "hermes":
      return registerHermes(base, name, spec);
    case "opencode":
      return registerOpencode(base, name, spec);
    default:
      return { ok: false, message: `${agentId} は MCP の追加に未対応です` };
  }
}

export async function deleteMcp(agentId: string, serverName: string, runtimeLabel?: string): Promise<OpResult> {
  const name = serverName.trim();
  if (!name) return { ok: false, message: "サーバ名が空です" };
  switch (baseId(agentId)) {
    case "buddy": {
      const servers = readBuddyMcpConfig();
      if (!servers[name]) return { ok: false, message: `${name} は見つかりません` };
      delete servers[name];
      writeBuddyMcpConfig(servers);
      return { ok: true, message: "ok" };
    }
    case "openclaw":
      return { ok: false, message: "OpenCLAW は未対応です" };
    case "codex": {
      const base = await agentHome(agentId, runtimeLabel);
      return base ? deleteCodex(base, name) : { ok: false, message: WSL_HOME_UNRESOLVED };
    }
    case "claude": {
      // user scope（register と対）→ 見つからなければ旧 local scope 登録も試す
      const r = await runAgentCli(agentId, ["mcp", "remove", "--scope", "user", name], runtimeLabel);
      if (r.ok) return r;
      return runAgentCli(agentId, ["mcp", "remove", name], runtimeLabel);
    }
    case "hermes":
      return runAgentCli(agentId, ["mcp", "remove", name], runtimeLabel);
    case "opencode": {
      const base = await agentHome(agentId, runtimeLabel);
      return base ? deleteOpencode(base, name) : { ok: false, message: WSL_HOME_UNRESOLVED };
    }
    case "cursor": {
      const base = await agentHome(agentId, runtimeLabel);
      return base ? deleteJsonMcp(cursorConfigPath(base), name) : { ok: false, message: WSL_HOME_UNRESOLVED };
    }
    case "grok":
    case "antigravity":
      return runAgentCli(agentId, ["mcp", "remove", name], runtimeLabel);
    default:
      return { ok: false, message: `${agentId} は MCP の削除に未対応です` };
  }
}

async function registerClaude(agentId: string, name: string, spec: McpRegisterSpec, runtimeLabel?: string): Promise<OpResult> {
  // 認証ヘッダ・環境変数（トークン）があるときは CLI の引数に載せない（コマンドラインは同じ PC の他のプロセスから
  // 見える）。`claude mcp add --scope user` と同じ ~/.claude.json のトップレベル mcpServers に直接書く。
  if (Object.keys(spec.env).length > 0) return registerClaudeWithSecrets(agentId, name, spec, runtimeLabel);
  let args: string[];
  // --scope user: 既定の local scope は「add を実行した cwd のプロジェクト」限定になり
  // （bridge の cwd に紐づき、チャットの作業ディレクトリからは見えない）。
  // コネクタはプロジェクト横断で使うものなので user scope に登録する。
  if (spec.transportKind === "url" && spec.url) {
    args = ["mcp", "add", "--scope", "user", "--transport", "http", name, spec.url];
  } else if (spec.command) {
    args = ["mcp", "add", "--scope", "user", name, "--", spec.command, ...spec.args];
  } else {
    return { ok: false, message: "transport が不正です" };
  }
  return runAgentCli(agentId, args, runtimeLabel);
}

async function registerClaudeWithSecrets(agentId: string, name: string, spec: McpRegisterSpec, runtimeLabel?: string): Promise<OpResult> {
  if (!agentRuntime(agentId, runtimeLabel)) return { ok: false, message: `${baseId(agentId)} がインストールされていません` };
  const base = await agentHome(agentId, runtimeLabel);
  if (!base) return { ok: false, message: WSL_HOME_UNRESOLVED };
  let server: Record<string, unknown>;
  if (spec.transportKind === "url" && spec.url) {
    // OAuth 等の認証ヘッダ（例 Authorization: Bearer <token>）
    server = { url: spec.url, headers: { ...spec.env }, type: "http" };
  } else if (spec.command) {
    server = { command: spec.command, args: [...spec.args], env: { ...spec.env }, type: "stdio" };
  } else {
    return { ok: false, message: "transport が不正です" };
  }
  const path = home(base, ".claude.json");
  const raw = existsSync(path) ? readText(path) : "";
  // 読めない・解析できないまま書くと Claude Code の設定が全部消えるので中止する
  if (raw === undefined) return { ok: false, message: "~/.claude.json を読めないため追加できません" };
  let root: Record<string, unknown> = {};
  if (raw.trim()) {
    try {
      const parsed = JSON.parse(raw) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
      root = parsed as Record<string, unknown>;
    } catch {
      return { ok: false, message: "~/.claude.json を解析できないため追加できません" };
    }
  }
  const current = root.mcpServers;
  const servers = current && typeof current === "object" && !Array.isArray(current) ? { ...(current as Record<string, unknown>) } : {};
  if (servers[name] !== undefined) return { ok: false, message: `${name} は既に接続済みです` };
  servers[name] = server;
  return writeJsonConfig(path, { ...root, mcpServers: servers }, true);
}

/** YAML の double-quoted scalar（PyYAML でも読めるよう \ " と改行類だけエスケープする）。 */
function yamlQuote(v: string): string {
  return `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t")}"`;
}

function yamlKey(k: string): string {
  return /^[A-Za-z0-9_-]+$/.test(k) ? k : yamlQuote(k);
}

/**
 * Hermes は `~/.hermes/config.yaml` の `mcp_servers:` にサーバを 1 件追記する（Mac の registerHermes と同じ）。
 * `hermes mcp add` は対話式で、stdin が EOF だと保存せずに exit 0 で戻るため使わない。
 * url 型は url と headers、コマンド型は command / args / env を書く（listHermes / fullMcpSpecs が読む形）。
 * 行単位の追記で、ほかのキー・コメント・既存サーバには触れない。
 */
function registerHermes(base: string, name: string, spec: McpRegisterSpec): OpResult {
  const url = spec.transportKind === "url" ? (spec.url ?? "") : "";
  const command = spec.transportKind === "command" ? (spec.command ?? "") : "";
  if (!url && !command) return { ok: false, message: "Hermes に追加する MCP の url かコマンドがありません" };
  if (spec.authType === "oauth" && Object.keys(spec.env).length === 0) {
    return { ok: false, message: "Hermes は OAuth 連携の自動追加に未対応です（トークンが渡されていません）" };
  }
  const path = home(base, ".hermes/config.yaml");
  const raw = existsSync(path) ? readText(path) : "";
  // 読めないまま書くと model / provider 等の設定が全部消えるので中止する
  if (raw === undefined) return { ok: false, message: "Hermes の config.yaml を読めないため追加できません" };
  const lines = raw.split("\n");
  if (lines.at(-1) === "") lines.pop();
  const isContent = (l: string): boolean => l.trim() !== "" && !l.trim().startsWith("#");
  const indentOf = (l: string): number => l.length - l.trimStart().length;

  let nameIndent = 2;
  let insertAt = lines.length;
  const header = lines.findIndex((l) => l.startsWith("mcp_servers:"));
  if (header >= 0) {
    const value = lines[header].slice("mcp_servers:".length).split("#")[0].trim();
    if (!["", "{}", "null", "~"].includes(value)) {
      return { ok: false, message: "Hermes の config.yaml の mcp_servers を解析できないため追加できません" };
    }
    lines[header] = "mcp_servers:";
    let end = lines.findIndex((l, i) => i > header && isContent(l) && indentOf(l) === 0);
    if (end < 0) end = lines.length;
    const body: number[] = [];
    for (let i = header + 1; i < end; i++) if (isContent(lines[i])) body.push(i);
    if (body.length > 0 && lines[body[0]].trim().startsWith("-")) {
      return { ok: false, message: "Hermes の config.yaml の mcp_servers を解析できないため追加できません" };
    }
    if (body.length > 0) nameIndent = indentOf(lines[body[0]]);
    const exists = body.some((i) => {
      if (indentOf(lines[i]) !== nameIndent) return false;
      return lines[i].split(":")[0].trim().replace(/^["']|["']$/g, "") === name;
    });
    if (exists) return { ok: false, message: `${name} は既に接続済みです` };
    insertAt = (body.at(-1) ?? header) + 1;
  } else {
    lines.push("mcp_servers:");
    insertAt = lines.length;
  }

  const pad = " ".repeat(nameIndent);
  const entry = [`${pad}${yamlKey(name)}:`];
  const envKeys = Object.keys(spec.env).sort();
  if (url) {
    entry.push(`${pad}  url: ${yamlQuote(url)}`);
    // OAuth 等の認証ヘッダ（例 Authorization: Bearer <token>）。hermes は headers をそのまま送る
    if (envKeys.length > 0) {
      entry.push(`${pad}  headers:`);
      for (const k of envKeys) entry.push(`${pad}    ${yamlKey(k)}: ${yamlQuote(spec.env[k])}`);
    }
  } else {
    entry.push(`${pad}  command: ${yamlQuote(command)}`);
    if (spec.args.length > 0) {
      entry.push(`${pad}  args:`);
      for (const a of spec.args) entry.push(`${pad}    - ${yamlQuote(a)}`);
    }
    if (envKeys.length > 0) {
      entry.push(`${pad}  env:`);
      for (const k of envKeys) entry.push(`${pad}    ${yamlKey(k)}: ${yamlQuote(spec.env[k])}`);
    }
  }
  entry.push(`${pad}  enabled: true`);
  lines.splice(insertAt, 0, ...entry);
  try {
    mkdirSync(dirname(path), { recursive: true });
    // headers / env にトークンが平文で入るので 0600 で書く（hermes 自身も config.yaml を 0600 にする）
    writeFileSync(path, lines.join("\n") + "\n", { encoding: "utf8", mode: 0o600 });
    return { ok: true, message: "ok" };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

/**
 * adapter と同じ実行環境（runtimeLabel。無ければ Windows 側の env 上書き → PATH）でエージェント CLI を実行する。
 * spawnRuntime 経由なので .cmd/.bat（npm シム）は cmd.exe、WSL は wsl.exe を通る（.cmd を shell なしの
 * execFile で起動すると EINVAL で同期 throw する）。stdin は即 EOF（対話プロンプトで待ち続けない）。
 */
async function runAgentCli(agentId: string, args: string[], runtimeLabel?: string): Promise<OpResult> {
  const runtime = agentRuntime(agentId, runtimeLabel);
  if (!runtime) {
    return { ok: false, message: `${baseId(agentId)} がインストールされていません` };
  }
  const r = await execRuntime(runtime, args, 20_000);
  if (r.ok) return { ok: true, message: "ok" };
  const line = String(r.stderr || r.error || "").split("\n").map((l) => l.trim()).filter(Boolean).pop() ?? "コマンドが失敗しました";
  return { ok: false, message: line.slice(0, 200) };
}

function escapeToml(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function tomlKey(s: string): string {
  return /^[A-Za-z0-9_-]+$/.test(s) ? s : `"${escapeToml(s)}"`;
}

function registerCodex(base: string, name: string, spec: McpRegisterSpec): OpResult {
  const path = home(base, ".codex/config.toml");
  let raw = readText(path) ?? "";
  let block = `[mcp_servers.${tomlKey(name)}]\n`;
  const inlineTable = (map: Record<string, string>): string =>
    `{ ${Object.keys(map).sort().map((k) => `${tomlKey(k)} = "${escapeToml(map[k])}"`).join(", ")} }`;
  if (spec.transportKind === "url" && spec.url) {
    block += `url = "${escapeToml(spec.url)}"\n`;
    // codex は url 型にヘッダを直接書けない（env は起動環境変数なので効かない）。OAuth のトークンは
    // bearer_token_env_var（環境変数名）で参照させ、本体は mcp-tokens.json から起動時に渡す（mac と同じ）。
    const headers = { ...spec.env };
    const auth = headers.Authorization;
    if (spec.authType === "oauth" && auth) {
      setMcpToken(name, auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : auth);
      block += `bearer_token_env_var = "${mcpTokenEnvVarName(name)}"\n`;
      delete headers.Authorization;
    }
    if (Object.keys(headers).length > 0) block += `http_headers = ${inlineTable(headers)}\n`;
  } else if (spec.command) {
    block += `command = "${escapeToml(spec.command)}"\n`;
    if (spec.args.length > 0) {
      block += `args = [${spec.args.map((a) => `"${escapeToml(a)}"`).join(", ")}]\n`;
    }
    // env は stdio サーバの起動環境変数（url 型には無意味なので command のときだけ）
    if (Object.keys(spec.env).length > 0) block += `env = ${inlineTable(spec.env)}\n`;
  } else {
    return { ok: false, message: "transport が不正です" };
  }
  if (raw && !raw.endsWith("\n")) raw += "\n";
  if (raw) raw += "\n";
  raw += block;
  try {
    mkdirSync(dirname(path), { recursive: true });
    // env にトークンが入り得るので、新しく作るときは 0600（既存ファイルのモードはそのまま）
    writeFileSync(path, raw, { encoding: "utf8", mode: 0o600 });
    return { ok: true, message: "ok" };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

/** config.toml から `[mcp_servers.NAME]` ブロックと、そのサブテーブル
 *  （`[mcp_servers.NAME.env]` / `[[mcp_servers.NAME.tools.x]]` 等。離れた位置にあっても）
 *  を除去する。各ブロックは次の（別の）table 開始まで。
 *  keepToolApprovals（OAuth の上書き）は `.tools.*` を残し、トークンも消さない（直後に入れ直す）。 */
function deleteCodex(base: string, name: string, keepToolApprovals = false): OpResult {
  if (!keepToolApprovals) setMcpToken(name, undefined);
  const path = home(base, ".codex/config.toml");
  const raw = readText(path);
  if (!raw) return { ok: true, message: "ok" };
  const out: string[] = [];
  let skipping = false;
  let removed = false;
  for (const line of raw.split("\n")) {
    const keys = tomlHeaderKeys(line);
    if (keys) {
      // サブテーブルだけ残すと transport の無い mcp_servers.NAME になり codex が起動できない
      skipping = keys.length >= 2 && keys[0] === "mcp_servers" && keys[1] === name
        && !(keepToolApprovals && keys.length >= 3 && keys[2] === "tools");
      if (skipping) {
        removed = true;
        continue;
      }
    } else if (skipping) {
      continue; // ブロック内の行を捨てる
    }
    out.push(line);
  }
  if (!removed) return { ok: true, message: "ok" };
  try {
    writeFileSync(path, out.join("\n"), "utf8");
    return { ok: true, message: "ok" };
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) };
  }
}

/** TOML のテーブルヘッダ行（`[a.b]` / `[[a.b]]`）をドット区切りのキー列に分解する。
 *  括弧内の空白・クォート付きキー（"..." / '...'）・行末コメントを許す。ヘッダでなければ null
 *  （例: 複数行配列の途中の `["a", "b"],` は閉じ括弧のあとに `,` が残るので null）。 */
function tomlHeaderKeys(line: string): string[] | null {
  const t = line.trim();
  if (!t.startsWith("[")) return null;
  const isArray = t.startsWith("[[");
  let i = isArray ? 2 : 1;
  const keys: string[] = [];
  let cur = "";
  let quote: string | null = null;
  let closed = false;
  while (i < t.length && !closed) {
    const c = t[i++];
    if (quote) {
      if (quote === '"' && c === "\\" && i < t.length) {
        cur += t[i++]; // basic string のエスケープ（tomlKey の逆）
      } else if (c === quote) {
        quote = null;
      } else {
        cur += c;
      }
      continue;
    }
    if (c === '"' || c === "'") quote = c;
    else if (c === ".") {
      keys.push(cur);
      cur = "";
    } else if (c === "]") closed = true;
    else if (c !== " " && c !== "\t") cur += c;
  }
  if (!closed) return null;
  keys.push(cur);
  if (isArray) {
    if (t[i] !== "]") return null;
    i++;
  }
  const rest = t.slice(i).trim();
  return rest === "" || rest.startsWith("#") ? keys : null;
}

/* ── Full specs（拡張機能の共有用。ヘッダー・環境変数＝秘密も含むので Bridge の外へは出さない） ── */

export interface McpFullSpec {
  name: string;
  kind: "url" | "command";
  url?: string;
  command?: string;
  args: string[];
  /** url のときはヘッダー、command のときは環境変数。 */
  env: Record<string, string>;
}

/** 一覧に出す短い説明（url そのもの、または「コマンド 最初の引数 …」）。 */
export function mcpSpecSummary(spec: McpFullSpec): string {
  if (spec.kind === "url") return spec.url ?? "";
  const firstArg = spec.args.find((a) => !a.startsWith("-"));
  const head = [spec.command, firstArg].filter(Boolean).join(" ");
  return spec.args.length > 1 ? `${head} …` : head;
}

const strMap = (v: unknown): Record<string, string> => {
  const out: Record<string, string> = {};
  if (v && typeof v === "object" && !Array.isArray(v)) {
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) if (typeof val === "string") out[k] = val;
  }
  return out;
};

function fullSpec(name: string, def: { url?: unknown; command?: unknown; args?: unknown }, env: Record<string, string>): McpFullSpec | undefined {
  if (typeof def.url === "string" && def.url) return { name, kind: "url", url: def.url, args: [], env };
  if (typeof def.command === "string" && def.command) {
    const args = Array.isArray(def.args) ? def.args.filter((a): a is string => typeof a === "string") : [];
    return { name, kind: "command", command: def.command, args, env };
  }
  return undefined;
}

export async function fullMcpSpecs(agentId: string, runtimeLabel?: string): Promise<McpFullSpec[]> {
  const base = await agentHome(agentId, runtimeLabel);
  if (!base) return [];
  switch (baseId(agentId)) {
    case "claude":
      return claudeFullSpecs(base);
    case "codex":
      return codexFullSpecs(base);
    case "opencode":
      return opencodeFullSpecs(base);
    case "hermes":
      return hermesFullSpecs(base);
    default:
      return [];
  }
}

function claudeFullSpecs(base: string): McpFullSpec[] {
  const merged = new Map<string, McpFullSpec>();
  for (const rel of [".claude/settings.json", ".claude/settings.local.json", ".claude.json"]) {
    const raw = readText(home(base, rel));
    if (!raw) continue;
    try {
      const root = JSON.parse(raw) as { mcpServers?: Record<string, Record<string, unknown>> };
      for (const [name, def] of Object.entries(root.mcpServers ?? {})) {
        const spec = fullSpec(name, def, strMap(typeof def.url === "string" ? def.headers : def.env));
        if (spec) merged.set(name, spec);
      }
    } catch {
      /* ignore malformed */
    }
  }
  return [...merged.values()];
}

/** `key = "v"` / `{ k = "v", ... }` のインラインテーブル。 */
function parseInlineTable(raw: string): Record<string, string> {
  const t = raw.trim();
  if (!t.startsWith("{") || !t.endsWith("}")) return {};
  const out: Record<string, string> = {};
  for (const part of t.slice(1, -1).split(",")) {
    const eq = part.indexOf("=");
    if (eq < 0) continue;
    const k = stripQuotes(part.slice(0, eq).trim());
    if (k) out[k] = stripQuotes(part.slice(eq + 1).trim());
  }
  return out;
}

function codexFullSpecs(base: string): McpFullSpec[] {
  const raw = readText(home(base, ".codex/config.toml"));
  if (!raw) return [];
  type Cur = { name: string; url?: string; command?: string; args: string[]; env: Record<string, string>; headers: Record<string, string> };
  const servers = new Map<string, Cur>();
  let cur: Cur | undefined;
  let sub: "env" | "http_headers" | undefined;
  for (const rawLine of raw.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("[") && line.endsWith("]")) {
      const inner = line.slice(1, -1).trim();
      cur = undefined;
      sub = undefined;
      if (!inner.startsWith("mcp_servers.")) continue;
      const parts = inner.slice("mcp_servers.".length).split(".");
      const name = stripQuotes(parts[0]);
      cur = servers.get(name) ?? { name, args: [], env: {}, headers: {} };
      servers.set(name, cur);
      if (parts[1] === "env" || parts[1] === "http_headers") sub = parts[1];
      else if (parts.length > 1) cur = undefined;
      continue;
    }
    if (!cur) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = stripQuotes(line.slice(0, eq).trim());
    const value = line.slice(eq + 1).trim();
    if (sub === "env") cur.env[key] = stripQuotes(value);
    else if (sub === "http_headers") cur.headers[key] = stripQuotes(value);
    else if (key === "url") cur.url = stripQuotes(value);
    else if (key === "command") cur.command = stripQuotes(value);
    else if (key === "args") cur.args = parseInlineList(value);
    else if (key === "env") Object.assign(cur.env, parseInlineTable(value));
    else if (key === "http_headers") Object.assign(cur.headers, parseInlineTable(value));
  }
  const out: McpFullSpec[] = [];
  for (const c of servers.values()) {
    const spec = fullSpec(c.name, c, c.url ? c.headers : c.env);
    if (spec) out.push(spec);
  }
  return out;
}

function opencodeFullSpecs(base: string): McpFullSpec[] {
  const mcp = opencodeMcpObject(readOpencodeConfig(base) ?? {});
  const out: McpFullSpec[] = [];
  for (const [name, def] of Object.entries(mcp)) {
    if (def.enabled === false) continue;
    if (def.url) out.push({ name, kind: "url", url: def.url, args: [], env: strMap(def.headers) });
    else if (Array.isArray(def.command) && def.command.length > 0) {
      out.push({ name, kind: "command", command: def.command[0], args: def.command.slice(1), env: strMap(def.environment) });
    }
  }
  return out;
}

function hermesFullSpecs(base: string): McpFullSpec[] {
  const raw = readText(home(base, ".hermes/config.yaml"));
  if (!raw) return [];
  type Cur = { name: string; url?: string; command?: string; args: string[]; map: Record<string, string> };
  const out: McpFullSpec[] = [];
  let inBlock = false;
  let nameIndent: number | null = null;
  let cur: Cur | undefined;
  let mapIndent: number | null = null;
  let listKey: "args" | undefined;
  const flush = (): void => {
    if (cur) {
      const spec = fullSpec(cur.name, cur, cur.map);
      if (spec) out.push(spec);
    }
    cur = undefined;
  };
  for (const rawLine of raw.split(/\r?\n/)) {
    const trimmed = rawLine.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const indent = rawLine.length - rawLine.trimStart().length;
    if (indent === 0) {
      flush();
      inBlock = trimmed.startsWith("mcp_servers:");
      nameIndent = null;
      continue;
    }
    if (!inBlock) continue;
    if (nameIndent === null) nameIndent = indent;
    if (indent === nameIndent) {
      flush();
      const name = trimmed.split(":")[0]?.trim() ?? "";
      if (name) cur = { name, args: [], map: {} };
      mapIndent = null;
      listKey = undefined;
      continue;
    }
    if (!cur) continue;
    if (mapIndent !== null && indent > mapIndent) {
      // env: / headers: の中身
      const idx = trimmed.indexOf(":");
      if (idx > 0) cur.map[stripQuotes(trimmed.slice(0, idx).trim())] = stripQuotes(trimmed.slice(idx + 1).trim());
      continue;
    }
    if (listKey && trimmed.startsWith("- ")) {
      cur.args.push(stripQuotes(trimmed.slice(2).trim()));
      continue;
    }
    mapIndent = null;
    listKey = undefined;
    const idx = trimmed.indexOf(":");
    if (idx < 0) continue;
    const key = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1).trim();
    if (key === "url") cur.url = stripQuotes(value);
    else if (key === "command") cur.command = stripQuotes(value);
    else if (key === "args") {
      if (value) cur.args = parseInlineList(value);
      else listKey = "args";
    } else if ((key === "env" || key === "headers") && !value) mapIndent = indent;
  }
  flush();
  return out;
}
