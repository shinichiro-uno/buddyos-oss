import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/**
 * Bridge が起動した agy（Antigravity CLI）の操作の承認を、iPhone の承認カードで受けるための hook（mac の AgyApprovalHook の移植）。
 *
 * agy の headless 実行は、確認が要る操作（コマンド実行）を聞けずに自動で拒否する。そこで組み込みの確認を
 * `--dangerously-skip-permissions` で外し、代わりに PreToolUse hook でコマンドを止めて Bridge に問い合わせる。
 * agy の許可リスト（~/.gemini/antigravity-cli/settings.json の permissions.allow）にあるコマンドはそのまま通す。
 *
 * hook は BuddyOS 専用のフォルダ（~/.buddyos/agy-hooks）に置き、Bridge が起動する agy にだけ `--add-dir` で読ませる。
 * 利用者の ~/.gemini/config/hooks.json は触らない。スクリプトは BUDDYOS_AGY_HOOK_URL が無ければ何も出さずに終わる。
 * Windows では bash / curl が無いことがあるので、hook は Bridge を動かしている node（Electron なら ELECTRON_RUN_AS_NODE）で動かす。
 */
export const AgyApprovalHook = {
  directory: (): string => path.join(os.homedir(), ".buddyos", "agy-hooks"),
  scriptPath: (): string => path.join(AgyApprovalHook.directory(), "buddy-agy-approval.mjs"),
  configPath: (): string => path.join(AgyApprovalHook.directory(), ".agents", "hooks.json"),
  /** iPhone で答えるまで待つ上限（hook の timeout）。Bridge 側はこれより少し短く打ち切る。 */
  timeoutSeconds: 600,

  script(): string {
    return `// BuddyOS: Bridge が起動した agy の操作の承認を iPhone で受ける（PreToolUse hook）。
// Bridge から起動されていなければ何も出さない（agy の通常の判断に任せる）。
// fetch は応答ヘッダーを 5 分で打ち切る（undici）ので、iPhone の答えを長く待てる node:http で聞く。
import http from "node:http";
const url = process.env.BUDDYOS_AGY_HOOK_URL;
if (!url) process.exit(0);
const chunks = [];
process.stdin.on("data", (c) => chunks.push(c));
process.stdin.on("error", () => process.exit(0));
process.stdin.on("end", async () => {
  const out = await new Promise((resolve) => {
    const req = http.request(url, {
      method: "POST",
      headers: { "content-type": "application/json", "x-buddyos-hook-token": process.env.BUDDYOS_AGY_HOOK_TOKEN || "" },
      timeout: 590000
    }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (c) => (body += c));
      res.on("end", () => resolve(res.statusCode === 200 ? body.trim() : ""));
      res.on("error", () => resolve(""));
    });
    req.on("timeout", () => req.destroy());
    req.on("error", () => resolve(""));
    req.end(Buffer.concat(chunks));
  });
  process.stdout.write((out || JSON.stringify({ decision: "deny", reason: "BuddyOS の Bridge に承認を問い合わせられませんでした。" })) + "\\n");
  process.exit(0);
});
`;
  },

  /** hook のコマンド（Claude Code の hooks と同じく / 区切りにして " で囲む）。 */
  config(node: string): string {
    const q = (p: string): string => `"${p.replace(/\\/g, "/")}"`;
    return `${JSON.stringify(
      {
        "buddyos-approval": {
          PreToolUse: [{ matcher: "*", hooks: [{ type: "command", command: `${q(node)} ${q(AgyApprovalHook.scriptPath())}`, timeout: AgyApprovalHook.timeoutSeconds }] }]
        }
      },
      null,
      2
    )}\n`;
  },

  /** hook のファイルを置く（中身が同じなら書かない）。置けなければ false（承認は従来どおり agy 任せ）。 */
  ensureInstalled(node = process.execPath): boolean {
    try {
      fs.mkdirSync(path.dirname(AgyApprovalHook.configPath()), { recursive: true });
      const write = (file: string, text: string): void => {
        let current: string | undefined;
        try {
          current = fs.readFileSync(file, "utf8");
        } catch {
          // 無ければ書く
        }
        if (current !== text) fs.writeFileSync(file, text, "utf8");
      };
      write(AgyApprovalHook.scriptPath(), AgyApprovalHook.script());
      write(AgyApprovalHook.configPath(), AgyApprovalHook.config(node));
      return true;
    } catch (error) {
      process.stderr.write(`[agy-hook] install failed: ${error instanceof Error ? error.message : String(error)}\n`);
      return false;
    }
  },

  /** agy に渡す環境変数。Electron で動いている Bridge なら、hook の node として動くよう ELECTRON_RUN_AS_NODE も渡す。 */
  env(port: number, token: string): Record<string, string> {
    const env: Record<string, string> = {
      BUDDYOS_AGY_HOOK_URL: `http://127.0.0.1:${port}/antigravity/hook`,
      BUDDYOS_AGY_HOOK_TOKEN: token
    };
    if (process.versions.electron) env.ELECTRON_RUN_AS_NODE = "1";
    return env;
  }
};

export type AgyVerdict = { kind: "allow" } | { kind: "deny"; reason: string } | { kind: "ask"; title: string; detail?: string };

/** Bridge の MCP のサーバ名（mainagent/workspace.ts の MCP_SERVER_NAME と同じ。循環 import を避けて持つ）。 */
const BRIDGE_MCP_SERVER = "buddyos";

/** 中身を読むだけの道具（mac の AgyApprovalPolicy.readOnlyTools と同じ）。 */
export const AGY_READ_ONLY_TOOLS = new Set([
  "view_file", "view_file_outline", "view_code_item", "list_dir", "find_by_name", "grep_search",
  "codebase_search", "search_web", "command_status", "read_terminal", "manage_task"
]);

export interface AgyVerdictOptions {
  /**
   * このセッションに Bridge の MCP（buddyos）を渡しているか。渡していれば、buddyos の道具の呼び出し（agy 1.4.2 は
   * `call_mcp_tool`、args の ServerName / ToolName / Arguments）と、agy が呼ぶ前に読む道具の説明
   * （~/.gemini/antigravity-cli/mcp/buddyos/<tool>.json）を通す。頼む道具は Bridge が呼んだ側のチャットに承認カードを
   * 出すので、ここで重ねて聞かない（mac の bridgeMcp と同じ）。
   */
  bridgeMcp?: boolean;
  /** 相対パスを解く作業フォルダ。 */
  cwd?: string;
  /** ホーム（テストで差し替える）。 */
  home?: string;
}

/** hook に返す判断（mac の AgyApprovalPolicy と同じ）。 */
export const AgyApprovalPolicy = {
  /**
   * コマンド実行だけを止める。許可リストにあるものは通し、拒否リストにあるものは止める。それ以外は iPhone に聞く。
   * bridgeMcp なら、buddyos の道具の呼び出しと、その説明（~/.gemini/antigravity-cli/mcp/buddyos/ の中）を読むことは先に通す。
   */
  verdict(toolName: string, args: Record<string, unknown>, allow: string[], deny: string[], opts: AgyVerdictOptions = {}): AgyVerdict {
    if (AgyApprovalPolicy.isBridgeMcpUse(toolName, args, opts)) return { kind: "allow" };
    // Windows の Bridge は、コマンド実行のほかは今までどおり通す（mac のような読み書きの場所の確認はまだ無い）。
    if (toolName !== "run_command") return { kind: "allow" };
    const command = (typeof args.CommandLine === "string" ? args.CommandLine : "").trim();
    if (!command) return { kind: "allow" };
    const segments = AgyApprovalPolicy.splitCommand(command);
    if (segments.some((s) => AgyApprovalPolicy.matches(s, deny))) return { kind: "deny", reason: "agy の拒否リストにあるコマンドです。" };
    // 置き換え（$( ) や ``）を含むと中で何が走るか分からないので、許可リストでは通さない。
    const hasSubstitution = command.includes("$(") || command.includes("`");
    if (!hasSubstitution && segments.length > 0 && segments.every((s) => AgyApprovalPolicy.matches(s, allow))) return { kind: "allow" };
    return { kind: "ask", title: "Antigravity: コマンドを実行", detail: command };
  },

  /**
   * Bridge の MCP（buddyos）を使う操作か: bridgeMcp のセッションで、`call_mcp_tool` の ServerName が buddyos、または
   * 読むだけの道具で、パスがすべて ~/.gemini/antigravity-cli/mcp/buddyos/ の中（agy が呼ぶ前に読む道具の説明）。
   * ほかの MCP サーバ・ほかの .gemini の中は当てはまらない。
   */
  isBridgeMcpUse(toolName: string, args: Record<string, unknown>, opts: AgyVerdictOptions = {}): boolean {
    if (!opts.bridgeMcp) return false;
    if (toolName === "call_mcp_tool") return args.ServerName === BRIDGE_MCP_SERVER;
    if (!AGY_READ_ONLY_TOOLS.has(toolName)) return false;
    const home = opts.home ?? os.homedir();
    const sep = /^[A-Za-z]:[\\/]|^\\\\/.test(home) ? "\\" : "/";
    const root = AgyApprovalPolicy.normalizePath([home, ".gemini", "antigravity-cli", "mcp", BRIDGE_MCP_SERVER].join(sep), undefined, home);
    const paths = AgyApprovalPolicy.candidatePaths(args, opts.cwd, home);
    return paths.length > 0 && paths.every((p) => AgyApprovalPolicy.isInside(p, root));
  },

  /** 引数の中のパスらしい文字列（キーに path / file / dir / uri を含むもの、または絶対パス・~・file://）を、絶対パスにして集める。 */
  candidatePaths(args: Record<string, unknown>, cwd: string | undefined, home: string): string[] {
    const out: string[] = [];
    const visit = (key: string, value: unknown): void => {
      if (typeof value === "string") {
        const k = key.toLowerCase();
        const looksLikePath = /^(\/|~|file:\/\/|[A-Za-z]:[\\/]|\\\\)/.test(value);
        const pathKey = ["path", "file", "dir", "uri"].some((w) => k.includes(w));
        if (value && (looksLikePath || pathKey) && !value.includes("\n")) out.push(AgyApprovalPolicy.normalizePath(value, cwd, home));
      } else if (Array.isArray(value)) {
        for (const v of value) visit(key, v);
      } else if (value && typeof value === "object") {
        for (const [k, v] of Object.entries(value as Record<string, unknown>)) visit(k, v);
      }
    };
    for (const [k, v] of Object.entries(args)) visit(k, v);
    return out;
  },

  /**
   * ~ と file:// と相対パスを解き、.. を畳み、存在する一番深い親までリンク（ジャンクション）を解いた絶対パスにする
   * （作業フォルダの中のリンクで別の場所を指す、のような抜け道を塞ぐ）。Windows のパス（C:\…・\\server\…・file:///C:/…）は
   * 区切りを \ にそろえ、大文字小文字を区別しない（小文字にする）。
   */
  normalizePath(raw: string, cwd: string | undefined, home: string): string {
    let p = raw.trim();
    if (/^file:\/\/\/[A-Za-z]:/i.test(p)) p = decodeURIComponent(p.slice("file:///".length));
    else if (/^file:\/\//i.test(p)) {
      try {
        p = decodeURIComponent(new URL(p).pathname);
      } catch {
        /* そのまま */
      }
    }
    if (p === "~") p = home;
    else if (/^~[\\/]/.test(p)) p = home + p.slice(1);
    const windows = process.platform === "win32" || /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("\\\\") || /^[A-Za-z]:[\\/]/.test(home);
    const lib = windows ? path.win32 : path.posix;
    let resolved = lib.resolve(cwd ?? home, p);
    // 存在する一番深い親までリンクを解き、残りを足し直す。
    const rest: string[] = [];
    let existing = resolved;
    for (;;) {
      try {
        const real = fs.realpathSync.native(existing);
        resolved = rest.length ? lib.join(real, ...rest) : real;
        break;
      } catch {
        const parent = lib.dirname(existing);
        if (parent === existing) break;
        rest.unshift(lib.basename(existing));
        existing = parent;
      }
    }
    if (windows) return resolved.replace(/\//g, "\\").replace(/\\+$/, "").toLowerCase();
    return resolved.length > 1 ? resolved.replace(/\/+$/, "") : resolved;
  },

  /** path が root の中（root そのものを含む）か。どちらも normalizePath したもの。 */
  isInside(p: string, root: string): boolean {
    const sep = /^[a-z]:\\|^\\\\/.test(root) ? "\\" : "/";
    const r = root.endsWith(sep) ? root.slice(0, -1) : root;
    return p === r || p.startsWith(r + sep);
  },

  /** `a && b | c; d` を個々のコマンドに分ける（引用符の中の区切りは分けない）。 */
  splitCommand(command: string): string[] {
    const out: string[] = [];
    let cur = "";
    let quote: string | undefined;
    const flush = (): void => {
      const t = cur.trim();
      if (t) out.push(t);
      cur = "";
    };
    for (let i = 0; i < command.length; i += 1) {
      const c = command[i];
      if (quote) {
        cur += c;
        if (c === quote) quote = undefined;
      } else if (c === '"' || c === "'") {
        quote = c;
        cur += c;
      } else if (c === ";" || c === "\n") {
        flush();
      } else if (c === "&" || c === "|") {
        // && / || / | を区切りにする（& 単体の背景実行も区切り）。
        if (command[i + 1] === c) i += 1;
        flush();
      } else {
        cur += c;
      }
    }
    flush();
    return out;
  },

  /** agy の規則（`command(ls)`、`command(git status)`、`command(regex:npm run (build|test))`）に合うか。 */
  matches(command: string, rules: string[]): boolean {
    for (const rule of rules) {
      if (!rule.startsWith("command(") || !rule.endsWith(")")) continue;
      const body = rule.slice("command(".length, -1);
      if (body === "*") return true;
      if (body.startsWith("regex:")) {
        try {
          if (new RegExp(`^(?:${body.slice("regex:".length)})`).test(command)) return true;
        } catch {
          // 壊れた正規表現は無視
        }
      } else if (command === body || command.startsWith(`${body} `)) {
        return true;
      }
    }
    return false;
  },

  /** agy の許可・拒否リスト。読めなければ空（= すべて iPhone に聞く）。 */
  loadRules(file = path.join(os.homedir(), ".gemini", "antigravity-cli", "settings.json")): { allow: string[]; deny: string[] } {
    try {
      const perms = (JSON.parse(fs.readFileSync(file, "utf8")) as { permissions?: { allow?: unknown; deny?: unknown } }).permissions ?? {};
      const list = (v: unknown): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
      return { allow: list(perms.allow), deny: list(perms.deny) };
    } catch {
      return { allow: [], deny: [] };
    }
  }
};

type HookHandler = (body: string) => Promise<Record<string, unknown>>;

/** hook の問い合わせ（トークン → その agy を起動したセッション）。トークンはターンごとに作り、終われば消す。 */
class AgyApprovalRegistry {
  private readonly handlers = new Map<string, HookHandler>();
  /** Bridge の待ち受け番号（server が起動時に入れる）。無ければ承認 hook は使わない。 */
  port?: number;

  register(handler: HookHandler): string {
    const token = crypto.randomBytes(32).toString("hex");
    this.handlers.set(token, handler);
    return token;
  }

  unregister(token: string): void {
    this.handlers.delete(token);
  }

  /** 知らないトークンなら undefined（404）。 */
  async handle(token: string, body: string): Promise<Record<string, unknown> | undefined> {
    const handler = this.handlers.get(token);
    return handler ? handler(body) : undefined;
  }
}

export const agyApprovals = new AgyApprovalRegistry();
