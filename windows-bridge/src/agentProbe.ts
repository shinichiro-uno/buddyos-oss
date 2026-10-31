import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { delimiter, isAbsolute, join } from "node:path";
import { isAntigravityConfigured, isCursorKeyConfigured, isGrokConfigured } from "./agents/headlessCli.js";
import { openRouterKey } from "./agents/buddy.js";
import { killProcessTree, spawnRuntime, type RuntimeCommand } from "./runtime/command.js";

export interface ProbeResult {
  installed: boolean;
  binaryPath?: string;
  configured: boolean;
  version?: string;
}

const CACHE_TTL_MS = 15_000;
// wsl.exe は起動が重いので、WSL 側で「設定済み」と確認できた結果は長めに持つ。
const WSL_CACHE_TTL_MS = 60_000;
const WSL_EXEC_TIMEOUT_MS = 4000;
const cache = new Map<string, { at: number; ttl: number; result: ProbeResult }>();

/** probe 結果のキャッシュを捨てる（/status?fresh=1。インストール直後・再確認で即再判定させる）。 */
export function clearProbeCache(): void {
  cache.clear();
}

interface Spec {
  envKey: string;
  command: string;
  configs: string[];
}

const SPECS: Record<string, Spec> = {
  claude: { envKey: "CLAUDE_BIN", command: "claude", configs: [".claude/settings.json", ".claude/settings.local.json"] },
  codex: { envKey: "CODEX_BIN", command: "codex", configs: [".codex/config.toml", ".codex/auth.json"] },
  hermes: { envKey: "HERMES_BIN", command: "hermes", configs: [".hermes/config.yaml"] },
  openclaw: { envKey: "OPENCLAW_BIN", command: "openclaw", configs: [".openclaw/openclaw.json"] },
  opencode: { envKey: "OPENCODE_BIN", command: "opencode", configs: [".config/opencode/opencode.json", ".local/share/opencode/auth.json"] },
  cursor: { envKey: "CURSOR_AGENT_BIN", command: "cursor-agent", configs: [] },
  grok: { envKey: "GROK_BIN", command: "grok", configs: [] },
  antigravity: { envKey: "ANTIGRAVITY_BIN", command: "agy", configs: [] }
};

// win32 では拡張子なしの候補（npm の sh シム %APPDATA%\npm\claude 等）を除外する。
// libuv は拡張子なしのパスに .com/.exe しか補わず ENOENT になるため。
const WIN_EXTS = [".exe", ".cmd", ".bat"];

/** Resolve an executable from $PATH, trying Windows extensions. */
function locateOnPath(command: string): string | undefined {
  const exts = process.platform === "win32" ? WIN_EXTS : [""];
  const dirs = (process.env.PATH ?? "").split(delimiter).filter(Boolean);
  for (const dir of dirs) {
    for (const ext of exts) {
      const candidate = join(dir, command + ext);
      if (existsSync(candidate)) return candidate;
    }
  }
  return undefined;
}

/** win32 で拡張子なしのパスなら、同じ場所の .exe/.cmd/.bat を優先する。 */
function winExecutable(path: string): string {
  if (process.platform !== "win32" || /\.(exe|cmd|bat|com)$/i.test(path)) return path;
  return WIN_EXTS.map((ext) => path + ext).find((p) => existsSync(p)) ?? path;
}

/**
 * adapter の runtimeLabel（resolveRuntime の label = "native:<path>" /
 * "wsl:<distro|default>:<command>"）から RuntimeCommand を復元する。
 * echo フォールバック（"local:echo"）など外部 CLI を持たないものは undefined。
 */
function runtimeFromLabel(label?: string): RuntimeCommand | undefined {
  if (!label) return undefined;
  const wsl = /^wsl:([^:]+):(.+)$/.exec(label);
  if (wsl) {
    return { kind: "wsl", executable: wsl[2], label, shell: false, wslDistro: wsl[1] === "default" ? undefined : wsl[1] };
  }
  const native = /^native:(.+)$/.exec(label);
  if (native) return { kind: "native", executable: winExecutable(native[1]), label, shell: false };
  return undefined;
}

/**
 * probe / MCP 操作でエージェント CLI を起動する実行環境。adapter の runtimeLabel が
 * あればそれに揃え（WSL で動く adapter を Windows 側 PATH で誤判定しない）、無ければ
 * 従来どおり Windows 側の env 上書き → PATH で native を探す。
 */
export function agentRuntime(id: string, runtimeLabel?: string): RuntimeCommand | undefined {
  const fromLabel = runtimeFromLabel(runtimeLabel);
  if (fromLabel) return fromLabel;
  const spec = SPECS[id.split("-")[0]];
  if (!spec) return undefined;
  const override = process.env[spec.envKey];
  const bin = override && existsSync(override) ? winExecutable(override) : locateOnPath(spec.command);
  return bin ? { kind: "native", executable: bin, label: `native:${bin}`, shell: false } : undefined;
}

export interface ExecResult {
  ok: boolean;
  stdout: string;
  stderr: string;
  error?: string;
}

const EXEC_MAX_OUTPUT = 1024 * 1024;

/**
 * spawnRuntime 経由（WSL は wsl.exe --exec、.cmd/.bat は cmd.exe /d /s /c）で実行して
 * 出力を集める。.cmd を shell なしで起動したときの EINVAL 同期 throw や ENOENT も
 * ok:false で返し、reject しない（/health の Promise.all を落とさない）。
 */
export function execRuntime(
  runtime: RuntimeCommand,
  args: string[],
  timeoutMs: number,
  options: { cwd?: string; env?: NodeJS.ProcessEnv } = {}
): Promise<ExecResult> {
  return new Promise((resolve) => {
    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawnRuntime(runtime, args, options);
    } catch (err) {
      resolve({ ok: false, stdout: "", stderr: "", error: String(err) });
      return;
    }
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (r: ExecResult) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(r);
    };
    const timer = setTimeout(() => {
      killProcessTree(child);
      finish({ ok: false, stdout, stderr, error: "timeout" });
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      if (stdout.length < EXEC_MAX_OUTPUT) stdout += String(d);
    });
    child.stderr.on("data", (d) => {
      if (stderr.length < EXEC_MAX_OUTPUT) stderr += String(d);
    });
    child.stdin.on("error", () => {});
    child.stdin.end();
    child.on("error", (err) => finish({ ok: false, stdout, stderr, error: err.message }));
    child.on("close", (code) => finish({ ok: code === 0, stdout, stderr, error: code === 0 ? undefined : `exit ${code}` }));
  });
}

// WSL の初回起動（VM のコールドスタート）は数秒かかるので probe より長めに待つ。
const WSL_PATH_TIMEOUT_MS = 10_000;
const wslPathCache = new Map<string, Promise<string | undefined>>();

/**
 * WSL で動く adapter の Linux 側パスを、Windows のプロセスから読み書きできる UNC パス
 * （\\wsl.localhost\<distro>\... / \\wsl$\<distro>\...）で返す。script は WSL の sh で実行し、
 * stdout の 1 行目（wslpath -w の出力）を採る。解決できなければ undefined（失敗はキャッシュしない）。
 * wsl.exe の引数に " を渡すと引用が崩れ得るので、script には " を使わないこと。
 */
export function wslWindowsPath(runtime: RuntimeCommand, script: string): Promise<string | undefined> {
  const key = `${runtime.wslDistro ?? ""}\0${script}`;
  let hit = wslPathCache.get(key);
  if (!hit) {
    hit = execRuntime({ ...runtime, executable: "sh" }, ["-c", script], WSL_PATH_TIMEOUT_MS).then((r) => {
      const line = r.ok ? r.stdout.split(/\r?\n/).map((l) => l.trim()).find(Boolean) : undefined;
      if (!line) wslPathCache.delete(key);
      return line;
    });
    wslPathCache.set(key, hit);
  }
  return hit;
}

/** WSL 側の $HOME を UNC パスで返す（WSL の ~/.codex・~/.hermes 等を Windows から読み書きする用）。 */
export function wslWindowsHome(runtime: RuntimeCommand): Promise<string | undefined> {
  return wslWindowsPath(runtime, "wslpath -w $HOME");
}

/** hermes の認証実体があるか（~/.hermes/.env の API キー or auth.json）。 */
function hermesAuthed(): boolean {
  try {
    const env = join(homedir(), ".hermes", ".env");
    if (existsSync(env)) {
      const s = readFileSync(env, "utf8");
      if (/^(GLM_API_KEY|ZAI_API_KEY|Z_AI_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY)=.+/m.test(s)) return true;
    }
    const auth = join(homedir(), ".hermes", "auth.json");
    if (existsSync(auth) && statSync(auth).size > 2) return true;
  } catch {
    /* treat as unauthed */
  }
  return false;
}

/** openclaw の gateway token と既定モデルが設定済みか（mac AgentProbe と同じ判定）。 */
function openclawReady(): boolean {
  try {
    const cfg = join(homedir(), ".openclaw", "openclaw.json");
    if (!existsSync(cfg)) return false;
    const s = readFileSync(cfg, "utf8");
    return /"token"\s*:\s*"[^"]+"/.test(s) && /"primary"\s*:\s*"[^"]+"/.test(s);
  } catch {
    return false;
  }
}

/** OpenCode の provider 認証実体があるか。 */
function opencodeReady(): boolean {
  try {
    const auth = join(homedir(), ".local", "share", "opencode", "auth.json");
    if (existsSync(auth) && statSync(auth).size > 2) return true;
    const cfg = join(homedir(), ".config", "opencode", "opencode.json");
    if (existsSync(cfg) && statSync(cfg).size > 2) return true;
    const appData = process.env.APPDATA;
    if (appData) {
      const appAuth = join(appData, "opencode", "auth.json");
      if (existsSync(appAuth) && statSync(appAuth).size > 2) return true;
    }
    const localAppData = process.env.LOCALAPPDATA;
    if (localAppData) {
      const localAuth = join(localAppData, "opencode", "auth.json");
      if (existsSync(localAuth) && statSync(localAuth).size > 2) return true;
    }
  } catch {
    /* treat as unauthed */
  }
  return false;
}

/** claude のログイン実体（~/.claude/.credentials.json・~/.claude.json の oauthAccount・ANTHROPIC_API_KEY）。 */
function claudeAuthed(): boolean {
  if (process.env.ANTHROPIC_API_KEY) return true;
  try {
    const creds = join(homedir(), ".claude", ".credentials.json");
    if (existsSync(creds) && statSync(creds).size > 2) return true;
    const state = join(homedir(), ".claude.json");
    if (existsSync(state)) {
      const parsed = JSON.parse(readFileSync(state, "utf8")) as Record<string, unknown>;
      if (parsed.oauthAccount && typeof parsed.oauthAccount === "object") return true;
    }
  } catch {
    /* treat as unauthed */
  }
  return false;
}

/** codex のログイン実体（~/.codex/auth.json の tokens か OPENAI_API_KEY、または環境変数）。 */
function codexAuthed(): boolean {
  if (process.env.OPENAI_API_KEY) return true;
  try {
    const auth = JSON.parse(readFileSync(join(homedir(), ".codex", "auth.json"), "utf8")) as Record<string, unknown>;
    const tokens = auth.tokens;
    if (tokens && typeof tokens === "object" && Object.keys(tokens).length > 0) return true;
    return typeof auth.OPENAI_API_KEY === "string" && auth.OPENAI_API_KEY.length > 0;
  } catch {
    return false;
  }
}

/** `cursor-agent status` が「Not logged in」以外を返せばログイン済みとみなす。タイムアウトは undefined（判定不能）。 */
async function cursorLoggedIn(runtime: RuntimeCommand, timeoutMs = 5000): Promise<boolean | undefined> {
  const r = await execRuntime(runtime, ["status"], timeoutMs);
  if (r.error === "timeout") return undefined;
  if (!r.ok) return false;
  const out = r.stdout.toLowerCase();
  return out.trim().length > 0 && !out.includes("not logged in");
}

async function runVersion(runtime: RuntimeCommand): Promise<string | undefined> {
  // wsl.exe / cmd.exe 経由は起動が遅いので猶予を伸ばす。
  const timeout = runtime.kind === "wsl" ? WSL_EXEC_TIMEOUT_MS : /\.(cmd|bat)$/i.test(runtime.executable) ? 3000 : 1500;
  const r = await execRuntime(runtime, ["--version"], timeout);
  if (!r.ok) return undefined;
  const line = r.stdout.trim().split("\n")[0]?.trim();
  return line || undefined;
}

// WSL 側 ~ の設定実体チェック（Windows 側の configs / hermesAuthed / openclawReady /
// opencodeReady と同じ判定を sh で行う）。wsl.exe の引数に " を渡すと引用が崩れ得るので、
// スクリプト内では " を使わず、必要な箇所は printf '\042' で作る。
const WSL_CHECK_PRELUDE = "cd || exit 1; set -f; q=$(printf '\\042'); big() { [ -f $1 ] && [ $(wc -c < $1) -gt 2 ]; }; ";
const WSL_CONFIG_CHECKS: Record<string, string> = {
  claude:
    "test -e .claude/settings.json || test -e .claude/settings.local.json || big .claude/.credentials.json || grep -qs oauthAccount .claude.json",
  codex: "grep -Eqs '(access_token|OPENAI_API_KEY.*:.*[A-Za-z0-9])' .codex/auth.json",
  hermes:
    "test -e .hermes/config.yaml && { grep -Eqs '^(GLM_API_KEY|ZAI_API_KEY|Z_AI_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY)=.+' .hermes/.env || big .hermes/auth.json; }",
  openclaw:
    "grep -Eqs ${q}token${q}[[:space:]]*:[[:space:]]*${q}[^${q}]+${q} .openclaw/openclaw.json && grep -Eqs ${q}primary${q}[[:space:]]*:[[:space:]]*${q}[^${q}]+${q} .openclaw/openclaw.json",
  opencode: "big .local/share/opencode/auth.json || big .config/opencode/opencode.json",
  grok: "big .grok/auth.json"
};

/**
 * WSL で動く adapter の configured 判定と --version。キー類（cursor / grok）は bridge 側で解決する。
 * /health は全エージェントを並列に probe するので、設定実体チェックと `<command> --version` は
 * 1 本の wsl.exe にまとめる（1 行目が判定結果 1/0、以降が --version の出力）。
 * configured が undefined はタイムアウトで判定できなかったこと（WSL VM のコールドスタート等。未設定と区別する）。
 */
async function wslProbe(id: string, runtime: RuntimeCommand): Promise<{ configured?: boolean; version?: string }> {
  const base = id.split("-")[0];
  let known: boolean | Promise<boolean | undefined> | undefined;
  // cursor のログインは status の出力で見るので別プロセスで並行に聞く（/health が 5 秒を超えないよう WSL の猶予に揃える）。
  if (base === "cursor") known = isCursorKeyConfigured() || cursorLoggedIn(runtime, WSL_EXEC_TIMEOUT_MS);
  else if (base === "grok" && isGrokConfigured()) known = true;
  else if (base === "antigravity") known = isAntigravityConfigured(runtime);
  else if (!WSL_CONFIG_CHECKS[base]) known = false;
  if (known !== undefined) {
    const [configured, version] = await Promise.all([known, runVersion(runtime)]);
    return { configured, version };
  }
  const script = `if (${WSL_CHECK_PRELUDE}${WSL_CONFIG_CHECKS[base]}) >/dev/null 2>&1; then echo 1; else echo 0; fi; exec $1 --version`;
  const r = await execRuntime({ ...runtime, executable: "sh" }, ["-c", script, "sh", runtime.executable], WSL_EXEC_TIMEOUT_MS);
  const [flag, ...rest] = r.stdout.split(/\r?\n/).map((l) => l.trim());
  const configured = flag === "1" ? true : flag === "0" ? false : r.error === "timeout" ? undefined : false;
  return { configured, version: r.ok ? rest.find(Boolean) : undefined };
}

/**
 * runtimeLabel は adapter.runtimeLabel。渡すと adapter と同じ実行環境（native の解決済み
 * パス / WSL）で判定する。キャッシュも実行環境ごとに分ける（native ⇄ wsl 切替で古い結果を返さない）。
 */
export async function probeAgent(id: string, runtimeLabel?: string): Promise<ProbeResult> {
  const key = `${id}\0${runtimeLabel ?? ""}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < hit.ttl) return hit.result;

  let result: ProbeResult;
  let ttl = CACHE_TTL_MS;
  if (id === "echo") {
    result = { installed: true, configured: true };
  } else if (id === "buddy") {
    // Bridge 内蔵。OpenRouter のキーがあれば使える。
    result = { installed: true, configured: openRouterKey() !== undefined, version: "1.0" };
  } else if (runtimeLabel === "local:echo") {
    // echo フォールバック中（選んだ実行環境に CLI が無い）。別の実行環境（Windows 側 PATH 等）に
    // バイナリがあっても adapter は echo 応答しか返さないので、未インストール扱いでグレーアウトさせる。
    result = { installed: false, configured: false };
  } else {
    const spec = SPECS[id.split("-")[0]];
    const labeled = runtimeFromLabel(runtimeLabel);
    if (!spec) {
      result = { installed: false, configured: false };
    } else if (labeled?.kind === "wsl") {
      // WSL 実行: installed は resolveRuntime の `command -v` で確認済み。binaryPath は
      // Windows のパスではないので載せない（実行環境は /health の runtime で分かる）。
      const { configured, version } = await wslProbe(id, labeled);
      if (configured === undefined) {
        // タイムアウトで判定できなかった。未設定としてキャッシュすると設定済みでもグレーアウトが
        // 続くので、直前の結果があればそれを返し、無ければ未設定扱いで返すがキャッシュしない（次の probe で再判定）。
        return hit?.result ?? { installed: true, configured: false, version };
      }
      result = { installed: true, configured, version };
      if (configured) ttl = WSL_CACHE_TTL_MS;
    } else {
      const runtime = labeled ?? agentRuntime(id);
      // 解決済みパスが後から消えた（アンインストール）場合は未インストール扱いに戻す。
      const bin = runtime && (!isAbsolute(runtime.executable) || existsSync(runtime.executable)) ? runtime.executable : undefined;
      let configured = spec.configs.some((rel) => existsSync(join(homedir(), rel)));
      // hermes: config.yaml の存在だけだと「APIキー無しでも ✓」の誤緑になるため、
      // 認証実体（.env のキー or auth.json）も要求する（mac AgentProbe と同じ判定）。
      if (id.split("-")[0] === "hermes" && configured) {
        configured = hermesAuthed();
      }
      // openclaw: onboard 未実行（gateway token / 既定モデル無し）の誤緑を防ぐ。
      // openclaw.json は JSON5 なので正規表現で実体だけ確認する。
      if (id.split("-")[0] === "openclaw" && configured) {
        configured = openclawReady();
      }
      if (id.split("-")[0] === "opencode") {
        configured = opencodeReady();
      }
      // claude: ログインしても settings.json は作られない。OAuth の資格情報か API キーでも可（mac と同じ）。
      if (id.split("-")[0] === "claude") {
        configured = configured || claudeAuthed();
      }
      // codex: config.toml だけでは未ログイン。auth.json のトークンか API キーを見る（mac と同じ）。
      if (id.split("-")[0] === "codex") {
        configured = codexAuthed();
      }
      // cursor: API キー（env / ~/.buddyos/cursor.token）か `cursor-agent status` の
      // ログイン状態（ログイン実体は CLI 管理でパス非公開のため status に聞く）。
      if (id === "cursor") {
        configured = isCursorKeyConfigured() || (runtime && bin ? ((await cursorLoggedIn(runtime)) ?? false) : false);
      }
      // grok: XAI_API_KEY / ~/.buddyos/grok.token / `grok login` の ~/.grok/auth.json。
      if (id === "grok") {
        configured = isGrokConfigured();
      }
      // antigravity: `agy models` に Gemini のモデルが出ればサインイン済み。
      if (id === "antigravity") {
        configured = runtime && bin ? await isAntigravityConfigured(runtime) : false;
      }
      const version = runtime && bin ? await runVersion(runtime) : undefined;
      result = { installed: Boolean(bin), binaryPath: bin, configured, version };
    }
  }

  cache.set(key, { at: Date.now(), ttl, result });
  return result;
}
