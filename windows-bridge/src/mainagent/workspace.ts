import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { ProjectRegistry } from "../projects.js";

// mainagent（窓口のエージェント）の作業フォルダと、エージェントへの渡し方（mac の MainAgentWorkspace.swift の移植）。
//
// このフォルダで開いた Claude Code / Codex / ACP のセッションに、Bridge の MCP（POST /mcp、
// orchestrator.ts）を差し込み、自分ではコードを書かせない。設定 allSessions が有効なら、ほかのフォルダのセッションにも
// MCP を渡す（書く道具は外さない）。役割とスキルはフォルダに置いたファイルで渡す
// （CLAUDE.md / AGENTS.md / .claude/skills/）。iPhone とデスクトップは、共有のプロジェクト一覧に出る「メイン」で開くだけでよい。
//
// 場所: Windows は %USERPROFILE%\.buddyos\main（mac の ~/.buddyos/main と同じ形）。それ以外（開発用に mac / Linux で
// 動かすとき）は設定フォルダの下の main（同じ Mac で mac の Bridge と同じフォルダを取り合わない）。
// BUDDYOS_MAINAGENT_DIR で差し替えられる。

export const PROJECT_NAME = "メイン";
/** エージェントに渡す MCP サーバの名前。道具は `mcp__buddyos__<tool>` で見える。 */
export const MCP_SERVER_NAME = "buddyos";
/** 合鍵を渡す環境変数（Claude CLI・stdio の中継）。引数に載せるとプロセスの一覧で見えるので、環境変数で渡す。 */
export const TOKEN_ENV_VAR = "BUDDYOS_MCP_TOKEN";
/** stdio の中継に Bridge の待ち受けの番号を渡す環境変数。 */
export const PORT_ENV_VAR = "BUDDYOS_MCP_PORT";
/** 道具の呼び出しを待つ上限（承認 5 分 + 返事 5 分を待てる長さ）。Codex の既定は 60 秒で足りない。 */
export const TOOL_TIMEOUT_SECONDS = 900;
/** 道具の名前（mcpEndpoint.ts の TOOLS と同じ）。承認は Bridge が出すので、エージェント側では尋ねさせない。 */
export const TOOL_NAMES = ["list_projects", "list_agents", "list_sessions", "start_session", "send_message", "get_reply", "answer_approval", "list_pcs", "save_note"];
/** mainagent に使わせない道具（コードを書かない・コマンドを打たない）。 */
/**
 * mainagent（と定期チェック）に尋ねずに使わせる、読むだけの道具（claude.ai の Gmail / Google ドライブのコネクタ）。
 * 定期チェックで「返事をしていないメール・進んでいない文書」を知らせるため。つないでいなければ無いだけ。
 * 送る・消す・書き換える道具は入れない（使おうとすればふつうに承認を尋ねる）。
 */
export const READ_ONLY_CONNECTOR_TOOLS: readonly string[] = [
  "mcp__claude_ai_Gmail__search_threads", "mcp__claude_ai_Gmail__get_thread", "mcp__claude_ai_Gmail__get_message",
  "mcp__claude_ai_Gmail__list_labels", "mcp__claude_ai_Gmail__list_drafts", "mcp__claude_ai_Gmail__get_draft",
  "mcp__claude_ai_Google_Drive__search_files", "mcp__claude_ai_Google_Drive__list_recent_files",
  "mcp__claude_ai_Google_Drive__get_file_metadata", "mcp__claude_ai_Google_Drive__read_file_content"
];
export const DENIED_TOOLS = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Bash"];

let rootDir: string | undefined;
let configDir: string | undefined;
let currentPort: number | undefined;

/** 既定の場所。 */
export function defaultMainAgentRoot(bridgeConfigDir: string, platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env): string {
  const override = env.BUDDYOS_MAINAGENT_DIR?.trim();
  if (override) return override;
  if (platform === "win32") return path.win32.join(env.USERPROFILE || os.homedir(), ".buddyos", "main");
  return path.join(bridgeConfigDir, "main");
}

/** 起動時に決める（index.ts）。テストは差し替える。undefined にすると、どのフォルダも mainagent にならない。 */
export function setMainAgentRoot(dir: string | undefined): void {
  rootDir = dir;
}

export function mainAgentRoot(): string | undefined {
  return rootDir;
}

/** Bridge の設定フォルダ（Claude CLI に渡す MCP の設定ファイルを置く）。 */
export function setMainAgentConfigDir(dir: string | undefined): void {
  configDir = dir;
}

/** Bridge の待ち受けの番号（server.start() が入れる）。 */
export function setMainAgentPort(port: number | undefined): void {
  currentPort = port;
}

export function mainAgentPort(): number {
  return currentPort ?? 8765;
}

export function mcpURL(port: number): string {
  return `http://127.0.0.1:${port}/mcp`;
}

/** このフォルダか（大文字小文字・区切り・末尾の区切りをそろえ、シンボリックリンクも解いて比べる）。 */
export function isMainWorkspace(cwd: string | undefined, root: string | undefined = rootDir): boolean {
  if (!cwd?.trim() || !root?.trim()) return false;
  return canonicalPath(cwd) === canonicalPath(root);
}

export function canonicalPath(p: string): string {
  let s = p.trim();
  try {
    s = fs.realpathSync.native(s);
  } catch {
    /* 無いフォルダはそのまま比べる */
  }
  const windows = process.platform === "win32" || /^[A-Za-z]:[\\/]/.test(s) || s.startsWith("\\\\");
  if (windows) return s.replace(/\//g, "\\").replace(/\\+$/, "").toLowerCase();
  return s.length > 1 ? s.replace(/\/+$/, "") : s;
}

// ---- フォルダに置くファイル ----

/**
 * Bridge が置くファイル 1 つ。frontmatter（スキルの `---` で囲んだ頭）は範囲の前に置き、範囲と一緒に書き換える
 * （Claude Code は frontmatter がファイルの先頭にあるときだけ読む）。
 */
export interface ManagedFile {
  path: string;
  frontmatter?: string;
  body: string;
  /** 前の版の Bridge が範囲の印なしで書いた中身。これと同じならユーザーは手を入れていない（mac の v1）。 */
  legacy: string[];
}

export const MANAGED_VERSION = 3;
export const MANAGED_BEGIN = "<!-- buddyos:managed:begin";
export const MANAGED_END = "<!-- buddyos:managed:end -->";

export function renderedManagedFile(file: ManagedFile): string {
  let out = "";
  if (file.frontmatter) out += `${file.frontmatter}\n\n`;
  out += `${MANAGED_BEGIN} v${MANAGED_VERSION} — この印の間は BuddyOS の Bridge が起動のたびに書き直します。足したい決まりは印の外に書いてください -->\n`;
  out += file.body;
  if (!file.body.endsWith("\n")) out += "\n";
  out += `${MANAGED_END}\n`;
  return out;
}

/** 今のファイルの中身から、書くべき中身を作る。undefined なら触らない。 */
export function updatedManagedContent(current: string | undefined, file: ManagedFile): string | undefined {
  const fresh = renderedManagedFile(file);
  if (current === undefined) return fresh;
  const begin = current.indexOf(MANAGED_BEGIN);
  const end = begin >= 0 ? current.indexOf(MANAGED_END, begin + MANAGED_BEGIN.length) : -1;
  if (begin >= 0 && end >= 0) {
    // 範囲の後ろ（ユーザーが足した文）は残す。改行 1 つは範囲の一部として扱う。
    let after = current.slice(end + MANAGED_END.length);
    if (after.startsWith("\n")) after = after.slice(1);
    // スキル: 頭から範囲の終わりまでが Bridge のもの（frontmatter を含む）。
    if (file.frontmatter) return fresh + after;
    // CLAUDE.md / AGENTS.md: 範囲の前（ユーザーが頭に足した文）も残す。
    return current.slice(0, begin) + fresh + after;
  }
  const trimmed = current.trim();
  if (file.legacy.some((l) => l.trim() === trimmed)) return fresh;
  return undefined;
}

/**
 * フォルダとファイルを用意する。Bridge の決まりは「Bridge が書き換える範囲」に入れ、起動のたびにその範囲だけを今の版へ
 * 書き直す（ユーザーが範囲の外に足した文は残す）。範囲の印が無いファイルは、前の版の Bridge が書いたまま（手を入れて
 * いない）なら今の版に置き換え、手で書き換えたものは触らない。
 * 「メイン」はプロジェクト一覧から消せない。一覧に無ければ（古い版で消した・projects.json を手で直した）足し直す。
 */
export function ensureMainAgentWorkspace(root: string, projects: Pick<ProjectRegistry, "add" | "list">): void {
  for (const file of MANAGED_FILES) {
    const target = path.join(root, ...file.path.split("/"));
    let current: string | undefined;
    if (fs.existsSync(target)) {
      try {
        current = fs.readFileSync(target, "utf8");
      } catch {
        continue; // 読めないなら触らない
      }
    }
    const next = updatedManagedContent(current, file);
    if (next === undefined || next === current) continue;
    try {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      const tmp = `${target}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, next, "utf8");
      fs.renameSync(tmp, target);
    } catch (error) {
      process.stderr.write(`[mainagent] could not write ${file.path}: ${error instanceof Error ? error.message : String(error)}\n`);
    }
  }
  ensureHeartbeatFiles(root);
  if (!projects.list().some((p) => isMainWorkspace(p.path, root))) projects.add(root, PROJECT_NAME);
}

// ---- 定期チェックのファイル（HEARTBEAT.md / NOTES.md。docs/MAIN_HEARTBEAT_2026-10-20.md §2） ----
//
// どちらも無いときだけ Bridge が作り、あとは利用者のもの（書き換えない）。NOTES.md は save_note が末尾に 1 行ずつ足す。

export const HEARTBEAT_FILE = "HEARTBEAT.md";
export const NOTES_FILE = "NOTES.md";
/** save_note の 1 件の上限（文字）。 */
export const NOTE_MAX_CHARS = 500;

export const HEARTBEAT_TEMPLATE = `# 定期チェックで見ること

メインが定期チェックのたびに読みます。自由に書き足したり消したりしてください。

- 承認を待って止まっている会話はないか
- 途中で止まったままの作業はないか（最後の返事が質問・確認・「残りは…」で終わっている、しばらく動いていない）
- 失敗したままの作業はないか
- 長く動き続けている作業はないか
- Gmail / Google ドライブを見る道具があれば：返事をしていないメール、しばらく進んでいない文書

伝えるときは、何が・どこで止まっていて・次に何をすればよいかを 1 行ずつ。作業は頼まない（気づいたことを知らせるだけ）。
`;

/** 前の版の HEARTBEAT.md（このままなら今の版に置き換える）。 */
export const LEGACY_HEARTBEAT_TEMPLATES: readonly string[] = [`# 定期チェックで見ること

メインが定期チェックのたびに読みます。自由に書き足したり消したりしてください。

- 承認を待って止まっている会話はないか
- 終わった作業・失敗した作業はないか（終わったものは要点だけ）
- 長く動き続けている作業はないか
`];

export const NOTES_TEMPLATE = `# メインのメモ

メインが覚えておくことです。自由に直したり消したりしてください。
`;

/** 手元の時刻を `YYYY-MM-DD HH:mm` で（定期チェックの文・メモの行）。 */
export function formatLocalMinute(d: Date): string {
  const p = (n: number): string => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** 無いファイルだけ作る（利用者が直したものは書き換えない。HEARTBEAT.md が前の版のままなら今の版に置き換える）。 */
export function ensureHeartbeatFiles(root: string): void {
  for (const [name, body] of [[HEARTBEAT_FILE, HEARTBEAT_TEMPLATE], [NOTES_FILE, NOTES_TEMPLATE]] as const) {
    const target = path.join(root, name);
    if (name === HEARTBEAT_FILE) {
      try {
        if (LEGACY_HEARTBEAT_TEMPLATES.includes(fs.readFileSync(target, "utf8"))) {
          fs.writeFileSync(target, body, "utf8");
          continue;
        }
      } catch {
        // 無い・読めない。下で無いときだけ作る。
      }
    }
    try {
      fs.mkdirSync(root, { recursive: true });
      // wx: あれば作らない（確かめてから書くまでの間に利用者が作ったものも上書きしない）。
      fs.writeFileSync(target, body, { encoding: "utf8", flag: "wx" });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "EEXIST") continue;
      process.stderr.write(`[mainagent] could not write ${name}: ${error instanceof Error ? error.message : String(error)}\n`);
    }
  }
}

/** save_note の文をそろえる（改行は空白に、前後の空白を除き、500 文字まで）。空なら undefined。 */
export function normalizeNote(text: string): string | undefined {
  const flat = text.replace(/\s*[\r\n]+\s*/g, " ").trim();
  if (!flat) return undefined;
  return Array.from(flat).slice(0, NOTE_MAX_CHARS).join("");
}

/** NOTES.md の末尾に `- YYYY-MM-DD HH:mm {text}` を 1 行足し、その行を返す（無ければ初期の中身で作ってから足す）。 */
export function appendNote(root: string, text: string, now: Date = new Date()): string {
  const note = normalizeNote(text);
  if (note === undefined) throw new Error("text が空");
  const line = `- ${formatLocalMinute(now)} ${note}`;
  const target = path.join(root, NOTES_FILE);
  ensureHeartbeatFiles(root);
  let current = "";
  try {
    current = fs.readFileSync(target, "utf8");
  } catch {
    /* 作れなかった（下の追記で失敗を返す） */
  }
  const prefix = current && !current.endsWith("\n") ? "\n" : "";
  fs.appendFileSync(target, `${prefix}${line}\n`, "utf8");
  return line;
}

// ---- エージェントへの渡し方 ----

/** Claude CLI の --mcp-config に渡す設定。合鍵は ${BUDDYOS_MCP_TOKEN} と書いて CLI に展開させる（中身に秘密は入らない）。 */
export function claudeMcpConfig(port: number): Record<string, unknown> {
  return {
    mcpServers: {
      [MCP_SERVER_NAME]: {
        type: "http",
        url: mcpURL(port),
        headers: { Authorization: `Bearer \${${TOKEN_ENV_VAR}}` }
      }
    }
  };
}

/**
 * Claude CLI の --mcp-config に渡すファイルを書き、そのパスを返す。Windows では JSON を引数に載せると cmd.exe・wsl.exe の
 * 引用で崩れうるので、mac と違ってファイルで渡す（中身は合鍵を含まない）。
 */
export function writeClaudeMcpConfigFile(port: number): string {
  const dir = configDir ?? os.tmpdir();
  const file = path.join(dir, "mainagent-mcp.json");
  const body = JSON.stringify(claudeMcpConfig(port));
  try {
    if (fs.readFileSync(file, "utf8") === body) return file;
  } catch {
    /* 無い */
  }
  fs.mkdirSync(dir, { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, body, "utf8");
  fs.renameSync(tmp, file);
  return file;
}

/** Claude CLI に足す引数。権限モードは default に固定する（書く道具は外してある）。configPath は --mcp-config のファイル。 */
export function claudeMainAgentArgs(configPath: string): string[] {
  return [
    "--mcp-config", configPath,
    "--allowedTools", [...TOOL_NAMES.map((t) => `mcp__${MCP_SERVER_NAME}__${t}`), ...READ_ONLY_CONNECTOR_TOOLS].join(","),
    "--disallowedTools", DENIED_TOOLS.join(","),
    "--permission-mode", "default"
  ];
}

/**
 * Claude CLI に足す引数（main = mainagent のフォルダ）。ふつうのセッションは MCP と道具の許可だけ（書く道具は外さず、
 * 権限モードもそのセッションのまま。頼む・許可の確認は Bridge が出すので、Claude 側では道具を尋ねさせない）。
 */
export function claudeMcpArgs(configPath: string, main: boolean): string[] {
  if (main) return claudeMainAgentArgs(configPath);
  return ["--mcp-config", configPath, "--allowedTools", TOOL_NAMES.map((t) => `mcp__${MCP_SERVER_NAME}__${t}`).join(",")];
}

/** Codex app-server の thread/start・resume の config（-c と同じ点区切りのキー）。 */
export function codexMainAgentConfig(token: string, port: number): Record<string, unknown> {
  const key = `mcp_servers.${MCP_SERVER_NAME}`;
  return {
    [`${key}.url`]: mcpURL(port),
    [`${key}.http_headers`]: { Authorization: `Bearer ${token}` },
    [`${key}.tool_timeout_sec`]: TOOL_TIMEOUT_SECONDS,
    [`${key}.default_tools_approval_mode`]: "approve"
  };
}

/** `codex exec` に足す -c（TOML の値。BUDDYOS_CODEX_TRANSPORT=exec のときだけ）。合鍵は引数に載せず、環境変数 TOKEN_ENV_VAR を読ませる。 */
export function codexMainAgentExecArgs(port: number): string[] {
  return [...codexMcpExecArgs(port), "-c", 'sandbox_mode="read-only"', "-c", 'approval_policy="never"'];
}

/** `codex exec` に足す MCP だけの -c（ふつうのセッション。sandbox / approval はそのセッションのまま）。 */
export function codexMcpExecArgs(port: number): string[] {
  const key = `mcp_servers.${MCP_SERVER_NAME}`;
  return [
    "-c", `${key}.url="${mcpURL(port)}"`,
    "-c", `${key}.bearer_token_env_var="${TOKEN_ENV_VAR}"`,
    "-c", `${key}.tool_timeout_sec=${TOOL_TIMEOUT_SECONDS}`,
    "-c", `${key}.default_tools_approval_mode="approve"`
  ];
}

/** ACP の session/new・load の mcpServers の 1 件（http の形）。エージェントが mcpCapabilities.http を申告したときに使う。 */
export function acpHttpServer(token: string, port: number): Record<string, unknown> {
  return {
    type: "http",
    name: MCP_SERVER_NAME,
    url: mcpURL(port),
    headers: [{ name: "Authorization", value: `Bearer ${token}` }]
  };
}

// ---- Antigravity（agy）への渡し方 ----
//
// agy には会話ごとに MCP を渡す引数が無い（`agy mcp add` は全体の ~/.gemini/config/mcp_config.json に書く）。ただし
// `--add-dir` で足したフォルダの `.agents/mcp_config.json` も読み、その stdio のサーバは agy の環境変数を引き継ぐ
// （2026-10-18 に agy 1.4.2 で確かめた。承認 hook の `.agents/hooks.json` と同じ読まれ方）。そこで、合鍵を含まない設定
// （stdio の中継 = この Bridge を mcp-stdio-relay で起こす）を BuddyOS 専用のフォルダに置き、合鍵を渡すセッションの agy にだけ
// `--add-dir` で読ませる。合鍵と番号は agy の環境変数（BUDDYOS_MCP_TOKEN / BUDDYOS_MCP_PORT）で渡し、引数・ファイルには載せない。

/** agy に --add-dir で読ませるフォルダ（~/.buddyos/agy-mcp。.agents/mcp_config.json を置く）。 */
export function agyMcpDirectory(): string {
  return path.join(os.homedir(), ".buddyos", "agy-mcp");
}

/** agy の mcp_config.json の中身（合鍵を含まない）。Electron で動く Bridge なら、中継を node として動かす。 */
export function agyMcpConfig(cmd: { command: string; args: string[] }): Record<string, unknown> {
  const server: Record<string, unknown> = { command: cmd.command, args: cmd.args };
  if (process.versions.electron) server.env = { ELECTRON_RUN_AS_NODE: "1" };
  return { mcpServers: { [MCP_SERVER_NAME]: server } };
}

/**
 * agy の設定を置く（中身が同じなら書かない）。置けたらフォルダのパス、置けなければ undefined（agy には渡さない）。
 * フォルダは 0700（agy が中に入れるように。0600 のフォルダは agy が読めなかった。mac で確認）、ファイルは 0600。
 * Windows では mode は効かず、ユーザーのフォルダ（%USERPROFILE%\.buddyos）から引き継ぐ権限になる（同じユーザーで動く agy は読める）。
 */
export function ensureAgyMcpConfig(cmd: { command: string; args: string[] }, dir: string = agyMcpDirectory()): string | undefined {
  const agents = path.join(dir, ".agents");
  const file = path.join(agents, "mcp_config.json");
  const body = `${JSON.stringify(agyMcpConfig(cmd), null, 2)}\n`;
  try {
    // 先にフォルダを 0700 に直す（入れないフォルダの中は作ることも読むこともできない）。リンクは触らない。
    if (process.platform !== "win32") {
      for (const d of [dir, agents]) {
        try {
          const st = fs.lstatSync(d);
          if (st.isDirectory() && (st.mode & 0o777) !== 0o700) fs.chmodSync(d, 0o700);
        } catch {
          /* 無ければ下で作る */
        }
      }
    }
    fs.mkdirSync(agents, { recursive: true, mode: 0o700 });
    let current: string | undefined;
    try {
      current = fs.readFileSync(file, "utf8");
    } catch {
      /* 無ければ書く */
    }
    if (current !== body) {
      const tmp = `${file}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, body, { encoding: "utf8", mode: 0o600 });
      fs.renameSync(tmp, file);
    }
    if (process.platform !== "win32") {
      for (const d of [dir, agents]) if ((fs.statSync(d).mode & 0o777) !== 0o700) fs.chmodSync(d, 0o700);
      if ((fs.statSync(file).mode & 0o777) !== 0o600) fs.chmodSync(file, 0o600);
    }
    return dir;
  } catch (error) {
    process.stderr.write(`[mainagent] could not write the agy MCP config: ${error instanceof Error ? error.message : String(error)}\n`);
    return undefined;
  }
}

// ---- フォルダに置くファイルの中身（mac と同じ文） ----

export const ROLE_TEXT = `# mainagent

あなたは BuddyOS の mainagent（窓口）です。ユーザーとはここだけで話し、実際の作業はほかのセッションに任せます。

## 決まり
- 自分ではコードを書かない。ファイルも編集しない。コマンドも打たない（使えないようにしてある）。
- 仕事は \`buddyos\` の道具（MCP）だけで進める。
  - \`list_projects\` / \`list_agents\` / \`list_sessions\` / \`get_reply\` / \`list_pcs\` / \`save_note\` は、いつ使ってもよい。
  - \`start_session\` / \`send_message\` は作業を頼む道具。呼ぶと BuddyOS がユーザーに承認を尋ねる（断られたら頼まない）。
  - \`list_pcs\` は頼める PC の一覧（この PC と、つないでいる別の PC）。どの道具にも \`pc\`（\`list_pcs\` の pc か name）を付けると、
    その PC のプロジェクト・セッションを扱う。付けなければこの PC。別の PC へ頼むときも承認カード（「PC: 名前」付き）が出る。
    別の PC のセッションの返事・承認も、同じ \`pc\` を付けた \`get_reply\` / \`answer_approval\` で扱う。
  - \`start_session\` の \`mode\` で子の権限モードを選べる（plan / ask / edit / auto）。このチャットで選んだモードより強くはならない。
  - \`send_message\` は、相手のセッションのモードがこのチャットのモードより強いと断られる（エラーに「…より強いので送らない」と出る）。
    そのときは勝手に別のセッションを起こさず、ユーザーに「相手のチャットのモードを下げるか、このチャットのモードを上げるか」を聞く。
  - \`wait_seconds\` を付けると、送ったまま返事を待てる（最大 300 秒）。
  - \`answer_approval\` は、子が承認待ち（\`needs_approval\`）のときに代わりに答える道具。
    - \`deny\` はすぐ答える。\`allow\` / \`allow_for_session\` は、BuddyOS がユーザーに承認を尋ねてから答える。
    - このチャットのモードが計画（plan）なら許可できない。\`allow_for_session\` は「編集は尋ねない」以上のときだけ。
    - 何を許すのか（\`approval\` の \`title\` / \`summary\`）が依頼の範囲か確かめてから答える。範囲の外・分からないものは答えずにユーザーに聞く。
    - \`choices\` に無い答えは使えない。質問（答えられないと書いてあるもの）は、ユーザーにそのセッションを開いてもらう。
- 1 つの作業は 1 つのセッションに頼む。同じプロジェクトを 2 つのセッションに同時に触らせない。
- 頼む文には、目的・やってほしいこと・やってはいけないこと・終わりの条件・報告の形を書く。
  commit / push / デプロイ / 削除は、ユーザーが頼んだときだけ指示に入れる。

## 案件の回し方
1. どのプロジェクトの話かを決める（\`list_projects\`）。わからなければユーザーに聞く。
   別の PC の話なら \`list_pcs\` で PC を決め、以後の道具に \`pc\` を付ける。
2. そのプロジェクトで動いているセッションを探す（\`list_sessions\` の cwd で見る）。
   - あれば \`send_message\` で送る。断られたら上の決まりのとおりユーザーに聞く。
   - 無ければ \`start_session\` で起こす。エージェントの指定が無ければ claude を使う。
3. \`get_reply\` で返事を待つ。\`running\` のあいだは、待つか、ユーザーに途中経過を伝える。
   - \`needs_approval\` なら、どのセッションが何の承認で止まっているかをユーザーに伝える。
     依頼の範囲の操作なら \`answer_approval\` で答えてよいか聞く（ユーザーが「許可して」と言えば \`allow\`）。
     答えられないもの・迷うものは、そのセッションを開いてもらう。
4. 返事を短くまとめて答える：結果 / 止まっている点 / ユーザーの判断が必要な点。

## 定期チェックとメモ
定期チェック（[定期チェック …] で始まる依頼）では、HEARTBEAT.md に沿って見るだけにし、伝えることが無ければ HEARTBEAT_OK とだけ返す。覚えておくとよいこと（利用者の好み・続いている作業・決まったこと）は save_note で残す。前に残したことは NOTES.md にある。

## 話し方
- ユーザーへの返事は日本語。短く、結論から。
- セッションは「プロジェクト名 + エージェント名」で呼ぶ（ID は必要なときだけ）。
- 任せたセッションの進み具合は、BuddyOS がこのチャットにカードで出す。同じ内容を長々と繰り返さない。`;

export const DISPATCH_FRONTMATTER = `---
name: dispatch
description: ユーザーの依頼を、担当のプロジェクトのセッションに回して結果をまとめる。「〇〇を直して」「〇〇で△△して」と頼まれたときに使う。
---`;

export const DISPATCH_SKILL = `# 依頼を回す

1. \`list_projects\` で、依頼がどのプロジェクトのものかを決める。候補が複数ならユーザーに聞く。
   - 別の PC のプロジェクトなら、\`list_pcs\` で PC を選び、以後の道具すべてに同じ \`pc\` を付ける。
2. \`list_sessions\` で、そのプロジェクト（cwd が一致）のセッションを探す。
   - 作業中（state=working）のセッションに送ると、今のターンの後に実行される（予約）。急ぎなら新しく起こす。
3. 指示文を書く。目的 / やること / やらないこと / 終わりの条件 / 報告の形（変更したファイル・確認結果・残課題）。
4. 既存のセッションなら \`send_message\`、無ければ \`start_session\`（agent は指定が無ければ claude）。
   - \`send_message\` が「モードが上限より強い」で断られたら、別のセッションを起こさずユーザーに聞く。
5. 送るときに wait_seconds=120 を付けて返事を待つ。\`running\` なら \`get_reply\` でもう一度待つか、ユーザーに「作業中」と伝えて戻る。
   - 調べるだけの依頼は mode=plan で起こす。
6. \`needs_approval\` なら、\`approval\` の title / summary を見て、依頼の範囲の操作かを確かめる。
   - 範囲の中で、ユーザーが許可すると言っていれば \`answer_approval\`（decision=allow）。BuddyOS が承認を尋ねる。
   - 範囲の外・分からないもの・\`choices\` が無いものは答えず、ユーザーに伝える。
7. 返事をまとめる：結果 / 止まっている点 / ユーザーの判断が必要な点。`;

export const STATUS_FRONTMATTER = `---
name: status
description: 動いているセッションの状況をまとめる。「今どうなってる？」「みんな何してる？」と聞かれたときに使う。
---`;

export const STATUS_SKILL = `# 状況をまとめる

1. \`list_sessions\` で動いているセッションを取る。
   - 別の PC も聞かれたら、\`list_pcs\` の PC ごとに \`pc\` を付けて \`list_sessions\` を呼ぶ。
2. 気になるもの（作業中・承認待ち・最近動いたもの）だけ \`get_reply\`（wait_seconds=0）で最新の返事を見る。
   - 承認待ちは \`pending_approvals\`（list_sessions）か \`approval\`（get_reply）に、何の承認かが出る。
3. プロジェクトごとに 1 行でまとめる：エージェント / 状態（作業中・待機・承認待ち）/ 直近の内容。
4. ユーザーの判断が必要なもの（承認待ちを含む）を最後に挙げる。承認は \`answer_approval\` で代わりに答えられると添える。`;

// 前の版（mac の Bridge が範囲の印なしで書いていたもの）。Windows の Bridge は書いたことが無いが、同じ ~/.buddyos/main を
// 使い回した人のために mac と同じく置き換えの対象にする。
export const LEGACY_ROLE_TEXT_V1 = `# mainagent

あなたは BuddyOS の mainagent（窓口）です。ユーザーとはここだけで話し、実際の作業はほかのセッションに任せます。

## 決まり
- 自分ではコードを書かない。ファイルも編集しない。コマンドも打たない（使えないようにしてある）。
- 仕事は \`buddyos\` の道具（MCP）だけで進める。
  - \`list_projects\` / \`list_agents\` / \`list_sessions\` / \`get_reply\` は、いつ使ってもよい。
  - \`start_session\` / \`send_message\` は作業を頼む道具。呼ぶと BuddyOS がユーザーに承認を尋ねる（断られたら頼まない）。
  - \`start_session\` の \`mode\` で子の権限モードを選べる（plan / edit / auto）。このチャットで選んだモードより強くはならない。
  - \`send_message\` は、相手のセッションのモードがこのチャットのモードより強いと断られる。そのときはユーザーに伝える。
  - \`wait_seconds\` を付けると、送ったまま返事を待てる（最大 300 秒）。
- 1 つの作業は 1 つのセッションに頼む。同じプロジェクトを 2 つのセッションに同時に触らせない。
- 頼む文には、目的・やってほしいこと・やってはいけないこと・終わりの条件・報告の形を書く。
  commit / push / デプロイ / 削除は、ユーザーが頼んだときだけ指示に入れる。

## 案件の回し方
1. どのプロジェクトの話かを決める（\`list_projects\`）。わからなければユーザーに聞く。
2. そのプロジェクトで動いているセッションを探す（\`list_sessions\` の cwd で見る）。
   - あれば \`send_message\` で送る。
   - 無ければ \`start_session\` で起こす。エージェントの指定が無ければ claude を使う。
3. \`get_reply\` で返事を待つ。\`running\` のあいだは、待つか、ユーザーに途中経過を伝える。
   - \`needs_approval\` なら、どのセッションが何の承認で止まっているかをユーザーに伝え、そのセッションを開いてもらう。
4. 返事を短くまとめて答える：結果 / 止まっている点 / ユーザーの判断が必要な点。

## 話し方
- ユーザーへの返事は日本語。短く、結論から。
- セッションは「プロジェクト名 + エージェント名」で呼ぶ（ID は必要なときだけ）。`;

export const LEGACY_DISPATCH_SKILL_V1 = `---
name: dispatch
description: ユーザーの依頼を、担当のプロジェクトのセッションに回して結果をまとめる。「〇〇を直して」「〇〇で△△して」と頼まれたときに使う。
---

# 依頼を回す

1. \`list_projects\` で、依頼がどのプロジェクトのものかを決める。候補が複数ならユーザーに聞く。
2. \`list_sessions\` で、そのプロジェクト（cwd が一致）のセッションを探す。
   - 生成中（generating=true）のセッションに送ると、今のターンの後に実行される（予約）。急ぎなら新しく起こす。
3. 指示文を書く。目的 / やること / やらないこと / 終わりの条件 / 報告の形（変更したファイル・確認結果・残課題）。
4. 既存のセッションなら \`send_message\`、無ければ \`start_session\`（agent は指定が無ければ claude）。
5. 送るときに wait_seconds=120 を付けて返事を待つ。\`running\` なら \`get_reply\` でもう一度待つか、ユーザーに「作業中」と伝えて戻る。
   - 調べるだけの依頼は mode=plan で起こす。
6. 返事をまとめる：結果 / 止まっている点 / ユーザーの判断が必要な点。`;

export const LEGACY_STATUS_SKILL_V1 = `---
name: status
description: 動いているセッションの状況をまとめる。「今どうなってる？」「みんな何してる？」と聞かれたときに使う。
---

# 状況をまとめる

1. \`list_sessions\` で動いているセッションを取る。
2. 気になるもの（生成中・承認待ち・最近動いたもの）だけ \`get_reply\`（wait_seconds=0）で最新の返事を見る。
3. プロジェクトごとに 1 行でまとめる：エージェント / 状態（作業中・待機・承認待ち）/ 直近の内容。
4. ユーザーの判断が必要なものを最後に挙げる。`;

export const MANAGED_FILES: readonly ManagedFile[] = [
  { path: "CLAUDE.md", body: ROLE_TEXT, legacy: [LEGACY_ROLE_TEXT_V1] },
  { path: "AGENTS.md", body: ROLE_TEXT, legacy: [LEGACY_ROLE_TEXT_V1] },
  { path: ".claude/skills/dispatch/SKILL.md", frontmatter: DISPATCH_FRONTMATTER, body: DISPATCH_SKILL, legacy: [LEGACY_DISPATCH_SKILL_V1] },
  { path: ".claude/skills/status/SKILL.md", frontmatter: STATUS_FRONTMATTER, body: STATUS_SKILL, legacy: [LEGACY_STATUS_SKILL_V1] }
];
