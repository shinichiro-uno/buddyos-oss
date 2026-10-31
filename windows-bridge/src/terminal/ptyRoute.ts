import type http from "node:http";
import type { Duplex } from "node:stream";
import { execFile, spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { WebSocket, WebSocketServer } from "ws";
import { systemExe } from "../runtime/systemExe.js";

/**
 * 別の PC のデスクトップアプリから、この PC のターミナルを操作するための口（`/terminal/pty`）。
 * mac-bridge の TerminalPtyRoutes.swift と同じ約束:
 *
 * - クエリ: `id`（ペインの id。必須）`cols` `rows` `cwd` `agentId` `resumeSessionId` `command` `attach=1`（つなぎ直しだけ）
 * - 送る: バイナリ = 端末の出力。テキスト = `{"type":"attached","restored"}` / `{"type":"replay","data"}` / `{"type":"exit","code"}` / `{"type":"gone"}`
 * - 受ける: テキスト = `{"type":"input","data"}` / `{"type":"resize","cols","rows"}` / `{"type":"kill"}`
 *
 * 端末の部品（node-pty）は、Bridge を起動したデスクトップアプリが同梱しているものを使う（場所は BUDDYOS_NODE_PTY）。
 * 無ければこの口は出さない（/health の features に "terminal" を入れない）。
 *
 * 端末は開いた端末（Principal）のもの。ほかの端末からはつなげず、その端末を外したら止める（プレビューと同じ）。
 * 出力が中継より速いときは、送りきるまで端末を読むのを止める（Bridge のメモリに積み上げない）。
 */

type IPty = {
  pid: number;
  onData(cb: (data: string) => void): void;
  onExit(cb: (e: { exitCode: number; signal?: number }) => void): void;
  write(data: string): void;
  resize(cols: number, rows: number): void;
  kill(signal?: string): void;
  pause(): void;
  resume(): void;
};
type PtyModule = { spawn(file: string, args: string[], opts: Record<string, unknown>): IPty };

const SCROLLBACK_LIMIT = 256 * 1024;
const DETACHED_LIMIT_MS = 24 * 60 * 60 * 1000;
/** 1 つの端末（Principal）が同時に持てるターミナルの数。 */
const MAX_PER_OWNER = 32;
/** 送りきれていない出力がこれを超えたら、端末を読むのを止める。LOW まで減ったら再開する。 */
const SEND_HIGH = 1024 * 1024;
const SEND_LOW = 256 * 1024;
/** 積んでおける入力の上限（mac-bridge と同じ）。超えた分は捨てる。 */
const INPUT_LIMIT = 16 * 1024 * 1024;
/** 入力は少しずつ流す（あいだに届いた Ctrl-C で残りを捨てられるように）。 */
const INPUT_STEP = 64 * 1024;
const INPUT_STEP_MS = 10;
/** 死んだ接続を見つける間隔（mac-bridge の pingInterval と同じ）。 */
const PING_MS = 30_000;
/** 止めるとき、これだけ待っても終わらなければ強く止める。 */
const KILL_GRACE_MS = 3000;

let ptyModule: PtyModule | null | undefined;

function loadPty(): PtyModule | null {
  if (ptyModule !== undefined) return ptyModule;
  try {
    const req = createRequire(pathToFileURL(process.argv[1] ?? join(process.cwd(), "bridge.cjs")).href);
    ptyModule = req(process.env.BUDDYOS_NODE_PTY || "node-pty") as PtyModule;
  } catch {
    ptyModule = null;
  }
  return ptyModule;
}

/** この PC のターミナルを別の PC から操作できるか（/health の features に使う）。 */
export function ptyAvailable(): boolean {
  return loadPty() !== null;
}

/**
 * 直近の出力（バイト数で数える）。切るのは UTF-8 の文字の境目で、送り直すときは切った行の残りを飛ばす
 * （行やエスケープの途中から描き始めない）。
 */
export class Scrollback {
  private chunks: { text: string; bytes: number }[] = [];
  private bytes = 0;
  private trimmed = false;

  constructor(private readonly limit = SCROLLBACK_LIMIT) {}

  push(text: string): void {
    const bytes = Buffer.byteLength(text, "utf8");
    if (!bytes) return;
    this.chunks.push({ text, bytes });
    this.bytes += bytes;
    while (this.bytes > this.limit) {
      this.trimmed = true;
      const first = this.chunks[0];
      const over = this.bytes - this.limit;
      if (first.bytes <= over) {
        this.chunks.shift();
        this.bytes -= first.bytes;
        continue;
      }
      const buf = Buffer.from(first.text, "utf8");
      let at = over;
      while (at < buf.length && (buf[at] & 0xc0) === 0x80) at++;
      this.chunks[0] = { text: buf.subarray(at).toString("utf8"), bytes: buf.length - at };
      this.bytes -= at;
    }
  }

  text(): string {
    const all = this.chunks.map((c) => c.text).join("");
    if (!this.trimmed) return all;
    const nl = all.indexOf("\n");
    return nl >= 0 && nl < 4096 ? all.slice(nl + 1) : all;
  }

  get size(): number {
    return this.bytes;
  }
}

interface Session {
  id: string;
  /** 開いた端末（previewOwner と同じ形。"local" か "device:<deviceKeyId>"）。 */
  owner: string;
  pty: IPty;
  scrollback: Scrollback;
  client: WebSocket | null;
  detachedAt: number;
  alive: boolean;
  /** 送りきれず、端末を読むのを止めている。 */
  paused: boolean;
  input: string[];
  inputBytes: number;
  inputTimer?: NodeJS.Timeout;
}

const sessions = new Map<string, Session>();
const wss = new WebSocketServer({ noServer: true, maxPayload: 4 * 1024 * 1024 });
let reaper: NodeJS.Timeout | undefined;

function sendJSON(ws: WebSocket, obj: Record<string, unknown>): void {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function defaultShell(): { file: string; args: string[] } {
  if (process.platform === "win32") return { file: process.env.COMSPEC || systemExe("powershell.exe"), args: [] };
  return { file: process.env.SHELL || "/bin/zsh", args: ["-l"] };
}

// Claude Code の設定（利用者が入れる CLAUDE_CODE_*）。子のセッションの印ではないので残す（デスクトップの ptyCore.ts と同じ）。
const CLAUDE_CONFIG =
  /^CLAUDE_CODE_(GIT_BASH_PATH|SHELL|SHELL_PREFIX|OAUTH_TOKEN|API_KEY_HELPER_TTL_MS|CLIENT_CERT|CLIENT_KEY|CLIENT_KEY_PASSPHRASE|EFFORT_LEVEL|SUBAGENT_MODEL|(USE|DISABLE|ENABLE|MAX|SKIP)_[A-Z0-9_]+)$/;

/** Bridge を起動したプロセスから引き継いだ印で、シェルに渡さないもの。 */
export function isInheritedMarker(k: string): boolean {
  return (
    k === "CLAUDECODE" ||
    (k.startsWith("CLAUDE_CODE_") && !CLAUDE_CONFIG.test(k)) ||
    k.startsWith("ELECTRON_") ||
    k === "BUDDYOS_BRIDGE_PORT"
  );
}

const normPath = (p: string): string => p.toLowerCase().replace(/[\\/]+$/, "");
const splitPath = (v: string | undefined): string[] =>
  (v ?? "")
    .split(";")
    .map((p) => p.trim().replace(/^"(.*)"$/, "$1"))
    .filter(Boolean);

/** いまの PATH にレジストリの PATH を足す（Bridge が足した項目を前に残し、重なりは 1 つにする）。 */
export function mergeWinPath(current: string | undefined, registry: string[]): string {
  const reg = new Set(registry.map(normPath));
  const seen = new Set<string>();
  return [...splitPath(current).filter((p) => !reg.has(normPath(p))), ...registry]
    .filter((p) => !seen.has(normPath(p)) && seen.add(normPath(p)))
    .join(";");
}

let regPath: { at: number; entries: string[] } | null = null;
let regRefreshing = false;
const REG_SCRIPT =
  "[Console]::OutputEncoding=[Text.Encoding]::UTF8;" +
  "[Environment]::GetEnvironmentVariable('Path','Machine');'--';[Environment]::GetEnvironmentVariable('Path','User')";
const powershell = (): string => join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");

function keepRegistryPath(out: string): void {
  const entries = out
    .replace(/^﻿/, "")
    .split(/\r?\n/)
    .filter((l) => l.trim() !== "--")
    .flatMap(splitPath)
    .map((p) => p.replace(/%([^%;]+)%/g, (all, n: string) => process.env[n] ?? all));
  // 読めなかったときも時刻は進める（PowerShell が使えない PC で、ターミナルを開くたびに待たない）。
  regPath = { at: Date.now(), entries: entries.length ? entries : (regPath?.entries ?? []) };
}

/**
 * レジストリの PATH（システム + ユーザー）。Bridge は起動した時点の環境を持ち続けるので、
 * あとから入れた CLI（%APPDATA%\npm など）がターミナルで見つからないのを防ぐ。
 * 初めてだけ待って読み、30 秒より古くなったら裏で読み直す。
 */
function registryPath(): string[] {
  const opts = { encoding: "utf8" as const, windowsHide: true, timeout: 5000 };
  const args = ["-NoProfile", "-NonInteractive", "-Command", REG_SCRIPT];
  if (!regPath) {
    try {
      keepRegistryPath(spawnSync(powershell(), args, opts).stdout ?? "");
    } catch {
      // 読めなければ、いまの PATH のまま。
      keepRegistryPath("");
    }
  } else if (Date.now() - regPath.at > 30_000 && !regRefreshing) {
    regRefreshing = true;
    execFile(powershell(), args, opts, (_e, stdout) => {
      regRefreshing = false;
      keepRegistryPath(String(stdout ?? ""));
    });
  }
  return regPath?.entries ?? [];
}

const pathKey = (env: Record<string, string>): string => Object.keys(env).find((k) => k.toUpperCase() === "PATH") ?? "Path";

/** シェルに渡さない秘密（mac-bridge の ChildEnvironment と同じ）。 */
export function isSecretEnv(k: string): boolean {
  return k === "BUDDYOS_CLERK_TOKEN" || k === "OPENCODE_SERVER_PASSWORD" || k.startsWith("BUDDYOS_MCP_");
}

function shellEnv(id: string): Record<string, string> {
  const env: Record<string, string> = { ...(process.env as Record<string, string>) };
  for (const k of Object.keys(env)) {
    if (isInheritedMarker(k) || isSecretEnv(k)) delete env[k];
  }
  if (process.platform === "win32") {
    const reg = registryPath();
    if (reg.length) {
      const key = pathKey(env);
      const merged = mergeWinPath(env[key], reg);
      for (const k of Object.keys(env)) if (k.toUpperCase() === "PATH") delete env[k];
      env[key] = merged;
    }
  }
  env.TERM = "xterm-256color";
  env.COLORTERM = "truecolor";
  env.TERM_PROGRAM = "BuddyOS";
  env.BUDDYOS_PANE_ID = id;
  return env;
}

/** Windows でエージェントの CLI が PATH にあるか（cmd.exe と同じく PATHEXT の拡張子で探す）。 */
export function onWinPath(name: string, env: Record<string, string>): boolean {
  const exts = (env.PATHEXT || ".COM;.EXE;.BAT;.CMD").split(";").filter(Boolean);
  return splitPath(env[pathKey(env)]).some((dir) =>
    exts.some((e) => {
      try {
        return statSync(join(dir, name + e.toLowerCase())).isFile();
      } catch {
        return false;
      }
    })
  );
}

const AGENT_CLIS = new Set(["claude", "codex", "opencode", "agy"]);

function directory(p: string | null): string {
  const home = homedir();
  if (!p) return home;
  const full = p === "~" ? home : p.startsWith("~/") ? join(home, p.slice(2)) : p;
  try {
    return existsSync(full) && statSync(full).isDirectory() ? full : home;
  } catch {
    return home;
  }
}

const shQuote = (s: string): string => (process.platform === "win32" ? `"${s.replace(/"/g, '""')}"` : `'${s.replace(/'/g, `'\\''`)}'`);

/** 起動するエージェントのコマンド。デスクトップの agentCommand.ts と同じ。 */
export function startCommand(q: URLSearchParams): string | null {
  const command = q.get("command")?.trim();
  if (command && !/[\r\n]/.test(command)) return command;
  const agentId = q.get("agentId");
  const sid = q.get("resumeSessionId");
  const wrapper = (name: string, fallback: string): string => {
    const p = join(homedir(), ".local", "bin", name);
    return existsSync(p) ? shQuote(p) : fallback;
  };
  if (sid && /^[A-Za-z0-9._:-]{1,128}$/.test(sid)) {
    if (agentId === "claude") return `claude --resume ${shQuote(sid)}`;
    if (agentId === "codex") return `${wrapper("buddy-codex", "codex")} resume ${shQuote(sid)}`;
    if (agentId === "opencode") return `${wrapper("buddy-opencode", "opencode")} --session ${shQuote(sid)}`;
  }
  switch (agentId) {
    case "claude":
      return "claude";
    case "codex":
      return wrapper("buddy-codex", "codex");
    case "opencode":
      return wrapper("buddy-opencode", "opencode");
    case "antigravity":
      return "agy";
    default:
      return null;
  }
}

function clamp(n: number, fallback: number): number {
  return Number.isFinite(n) && n > 0 ? Math.max(2, Math.min(1000, Math.floor(n))) : fallback;
}

function resumeOutput(s: Session): void {
  if (!s.paused) return;
  s.paused = false;
  if (s.alive) s.pty.resume();
}

/** 終わったあとの resize は node-pty が投げる（exit が届く前の短いあいだ）。 */
function resizePty(s: Session, cols: number, rows: number): void {
  if (!s.alive) return;
  try {
    s.pty.resize(cols, rows);
  } catch {
    /* もう終わっている */
  }
}

/** 止める（「閉じる」・24 時間つながらなかった・端末を外した）。終わらなければ強く止める。 */
function terminate(s: Session): void {
  if (!s.alive) return;
  try {
    s.pty.kill();
  } catch {
    return;
  }
  // Windows の kill は ConPTY ごと閉じる。Unix（テスト・開発）は SIGHUP なので、残れば SIGKILL。
  if (process.platform !== "win32") {
    setTimeout(() => {
      if (!s.alive) return;
      try {
        s.pty.kill("SIGKILL");
      } catch {
        /* もう終わっている */
      }
    }, KILL_GRACE_MS).unref();
  }
}

/** 入力を積んで、少しずつ流す。Ctrl-C（ETX）は、積んである貼り付けの残りより先に届ける（残りは捨てる）。 */
function queueInput(s: Session, data: string): void {
  if (!s.alive || !data) return;
  if (data.includes("\x03")) {
    s.input = [];
    s.inputBytes = 0;
  }
  const bytes = Buffer.byteLength(data, "utf8");
  if (s.inputBytes + bytes > INPUT_LIMIT) return;
  s.input.push(data);
  s.inputBytes += bytes;
  if (!s.inputTimer) flushInput(s);
}

function flushInput(s: Session): void {
  s.inputTimer = undefined;
  let budget = INPUT_STEP;
  while (s.input.length && budget > 0 && s.alive) {
    let d = s.input[0];
    if (d.length > budget) {
      // サロゲートペアの途中では切らない。
      let cut = budget;
      const c = d.charCodeAt(cut - 1);
      if (c >= 0xd800 && c <= 0xdbff) cut--;
      s.input[0] = d.slice(cut);
      d = d.slice(0, cut);
    } else s.input.shift();
    s.inputBytes -= Buffer.byteLength(d, "utf8");
    budget -= d.length;
    s.pty.write(d);
  }
  if (s.input.length && s.alive) s.inputTimer = setTimeout(() => flushInput(s), INPUT_STEP_MS);
}

/** 端末を外した・すべての端末を切断したときに、その端末が開いたターミナルを止める（owner を省くと全部）。 */
export function dropPtySessions(owner?: string): void {
  for (const s of [...sessions.values()]) {
    if (owner !== undefined && s.owner !== owner) continue;
    sessions.delete(s.id);
    if (s.client) {
      sendJSON(s.client, { type: "exit", code: -1 });
      s.client.close();
      s.client = null;
    }
    terminate(s);
  }
}

function spawn(id: string, owner: string, q: URLSearchParams, cols: number, rows: number): Session {
  const pty = loadPty()!;
  const { file, args } = defaultShell();
  const env = shellEnv(id);
  const p = pty.spawn(file, args, { name: "xterm-256color", cols, rows, cwd: directory(q.get("cwd")), env });
  const s: Session = {
    id,
    owner,
    pty: p,
    scrollback: new Scrollback(),
    client: null,
    detachedAt: Date.now(),
    alive: true,
    paused: false,
    input: [],
    inputBytes: 0
  };
  p.onData((data) => {
    s.scrollback.push(data);
    const c = s.client;
    if (c?.readyState !== WebSocket.OPEN) return;
    c.send(Buffer.from(data, "utf8"), () => {
      if (s.paused && (s.client !== c || c.bufferedAmount < SEND_LOW)) resumeOutput(s);
    });
    if (!s.paused && c.bufferedAmount > SEND_HIGH) {
      s.paused = true;
      s.pty.pause();
    }
  });
  p.onExit(({ exitCode }) => {
    s.alive = false;
    if (sessions.get(id) === s) sessions.delete(id);
    clearTimeout(s.inputTimer);
    s.input = [];
    s.inputBytes = 0;
    if (s.client) {
      sendJSON(s.client, { type: "exit", code: exitCode });
      s.client.close();
    }
    s.client = null;
  });
  const start = startCommand(q);
  const name = start?.trim().split(/\s+/)[0] ?? "";
  // Windows でエージェントの CLI が見つからなければ、打たずに案内を出す（cmd の「認識されていません」の代わり）。
  if (start && process.platform === "win32" && AGENT_CLIS.has(name) && !onWinPath(name, env)) {
    p.write(`echo ${name} が見つかりません。BuddyOS の設定からインストールしてください。\r`);
  } else if (start) p.write(`${start}\r`);
  if (!reaper) {
    reaper = setInterval(() => {
      for (const x of sessions.values()) {
        if (!x.client && Date.now() - x.detachedAt > DETACHED_LIMIT_MS) terminate(x);
      }
    }, 10 * 60 * 1000);
    reaper.unref();
  }
  return s;
}

/** size が null なら大きさは変えない（つなぎ直しで、画面の大きさがまだ分からないとき）。 */
function attach(s: Session, ws: WebSocket, size: { cols: number; rows: number } | null, restored: boolean): void {
  // 後から来た接続を正とする（同じペインを 2 か所で開いたら、前の方は閉じる）。
  if (s.client && s.client !== ws) s.client.close();
  s.client = ws;
  // 前の接続に送りきれずに止めていたら、読むのを再開する（前の接続の残りは捨てる）。
  resumeOutput(s);
  if (size) resizePty(s, size.cols, size.rows);
  sendJSON(ws, { type: "attached", restored });
  const replay = restored ? s.scrollback.text() : "";
  if (replay) sendJSON(ws, { type: "replay", data: replay });
  // 相手が眠った・中継が半開きのまま、という接続を見つけて閉じる（閉じないと 24 時間で止める数え始めが来ない）。
  let pong = true;
  ws.on("pong", () => {
    pong = true;
  });
  const ping = setInterval(() => {
    if (!pong) return ws.terminate();
    pong = false;
    try {
      ws.ping();
    } catch {
      ws.terminate();
    }
  }, PING_MS);
  ping.unref();
  ws.on("message", (raw, isBinary) => {
    if (isBinary || s.client !== ws || !s.alive) return;
    let msg: { type?: string; data?: unknown; cols?: unknown; rows?: unknown };
    try {
      msg = JSON.parse(String(raw));
    } catch {
      return;
    }
    if (msg.type === "input" && typeof msg.data === "string") queueInput(s, msg.data);
    else if (msg.type === "resize") resizePty(s, clamp(Number(msg.cols), 80), clamp(Number(msg.rows), 24));
    else if (msg.type === "kill") terminate(s);
  });
  ws.on("close", () => {
    clearInterval(ping);
    if (s.client !== ws) return;
    s.client = null;
    s.detachedAt = Date.now();
    resumeOutput(s);
  });
}

/** server の upgrade から呼ぶ。認証は済んでいること。owner は previewOwner(principal)。 */
export function handlePtyUpgrade(req: http.IncomingMessage, socket: Duplex, head: Buffer, url: URL, owner: string): void {
  const q = url.searchParams;
  const id = q.get("id") ?? "";
  if (!loadPty() || !id || id.length > 128) {
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
    return;
  }
  const cols = clamp(Number(q.get("cols")), 80);
  const rows = clamp(Number(q.get("rows")), 24);
  // つなぎ直しで大きさを付けてこなければ、動いている端末の大きさはそのまま（80×24 で描き直させない）。
  const size = q.has("cols") && q.has("rows") ? { cols, rows } : null;
  wss.handleUpgrade(req, socket, head, (ws) => {
    const existing = sessions.get(id);
    // ほかの端末が開いたターミナルにはつながない（その id は無いのと同じに扱う）。
    if (existing?.alive && existing.owner !== owner) {
      sendJSON(ws, { type: "gone" });
      ws.close();
      return;
    }
    if (existing?.alive) {
      attach(existing, ws, size, true);
      return;
    }
    if (q.get("attach") === "1") {
      sendJSON(ws, { type: "gone" });
      ws.close();
      return;
    }
    if ([...sessions.values()].filter((x) => x.owner === owner).length >= MAX_PER_OWNER) {
      sendJSON(ws, { type: "exit", code: -1, message: `ターミナルが多すぎます（${MAX_PER_OWNER} 個まで）。使っていないターミナルを閉じてください` });
      ws.close();
      return;
    }
    try {
      const s = spawn(id, owner, q, cols, rows);
      sessions.set(id, s);
      attach(s, ws, { cols, rows }, false);
    } catch (e) {
      sendJSON(ws, { type: "exit", code: -1, message: `ターミナルを起動できませんでした（${e instanceof Error ? e.message : String(e)}）` });
      ws.close();
    }
  });
}
