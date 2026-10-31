import { spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { mcpTokenEnv } from "../mcpService.js";
import { commandLine, isCmdShim, type RuntimeCommand } from "../runtime/command.js";
import { systemExe } from "../runtime/systemExe.js";

/**
 * ターミナルの Codex と iPhone で同じ会話を共有するための、常駐 app-server（mac の CodexSharedAppServer の移植）。
 *
 * app-server は 1 プロセスに複数の接続がぶら下がれて、同じ thread を resume した接続すべてに通知が流れる。
 * ターミナル側は `codex --remote ws://…`（buddy-codex）で、Bridge 側は CodexAppServerSession がここへ WebSocket で繋ぐ。
 * - 待ち受けは 127.0.0.1:47620 のみ。capability-token 必須（~/.buddyos/codex-app-server.token。buddy-codex も同じものを読む）
 * - Bridge の子にはせず切り離して起動する（Bridge が再起動してもターミナル側が切れないように）
 * - 起動できなければ undefined を返し、呼び出し側は従来の stdio app-server に倒す。5 分は spawn し直さない
 * - native の codex だけ（WSL の codex は Windows 側のポートで待ち受けない）。BUDDYOS_CODEX_SHARED=0 で無効
 * - mac のモデル一覧の鮮度確認・MCP トークンの入れ替えによる再起動は未移植（Windows の Bridge は MCP トークンを渡さない）
 */

export interface CodexSharedEndpoint {
  url: string;
  token: string;
}

export const CODEX_SHARED_PORT = 47620;
const FAILURE_COOLDOWN_MS = 5 * 60_000;

const buddyDir = (): string => path.join(os.homedir(), ".buddyos");
export const codexTokenFile = (): string => path.join(buddyDir(), "codex-app-server.token");
const codexLogFile = (): string => path.join(buddyDir(), "codex-app-server.log");

export function codexSharedEnabled(runtime: RuntimeCommand | undefined): boolean {
  return process.env.BUDDYOS_CODEX_SHARED !== "0" && runtime?.kind === "native";
}

/** /readyz は認証なしで 200 を返す。 */
export async function codexSharedReady(port = CODEX_SHARED_PORT): Promise<boolean> {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/readyz`, { signal: AbortSignal.timeout(1000) });
    return res.status === 200;
  } catch {
    return false;
  }
}

export function loadOrCreateCodexToken(file = codexTokenFile()): string | undefined {
  try {
    const t = fs.readFileSync(file, "utf8").trim();
    if (t) return t;
  } catch {
    // 無ければ作る
  }
  try {
    const token = crypto.randomBytes(32).toString("hex");
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, token, { encoding: "utf8", mode: 0o600 });
    return token;
  } catch {
    return undefined;
  }
}

class CodexSharedAppServerImpl {
  private starting?: Promise<CodexSharedEndpoint | undefined>;
  private lastFailure?: { at: number; executable: string };

  /** 動いていればそのまま、止まっていれば起動して返す。起動できなければ undefined。 */
  async ensureRunning(runtime: RuntimeCommand | undefined): Promise<CodexSharedEndpoint | undefined> {
    if (!runtime || !codexSharedEnabled(runtime)) return undefined;
    if (this.starting) return this.starting;
    const failure = this.lastFailure;
    if (failure && failure.executable === runtime.executable && Date.now() - failure.at < FAILURE_COOLDOWN_MS) {
      // しばらくは spawn しない。buddy-codex が起動したものは使えるよう、ready かどうかだけは見る。
      const token = loadOrCreateCodexToken();
      if (!token || !(await codexSharedReady())) return undefined;
      this.lastFailure = undefined;
      return endpointFor(token);
    }
    this.starting = this.start(runtime).finally(() => {
      this.starting = undefined;
    });
    const result = await this.starting;
    this.lastFailure = result ? undefined : { at: Date.now(), executable: runtime.executable };
    return result;
  }

  private async start(runtime: RuntimeCommand): Promise<CodexSharedEndpoint | undefined> {
    const token = loadOrCreateCodexToken();
    if (!token) return undefined;
    if (await codexSharedReady()) return endpointFor(token);
    const args = [
      "app-server",
      "--listen",
      `ws://127.0.0.1:${CODEX_SHARED_PORT}`,
      "--ws-auth",
      "capability-token",
      "--ws-token-file",
      codexTokenFile()
    ];
    let exited = false;
    try {
      fs.mkdirSync(buddyDir(), { recursive: true });
      // ポートを他が取っていれば bind に失敗して終わるだけ。
      // Windows は detached にしない（DETACHED_PROCESS だと codex の子のコンソールが見える窓で開く）。cmd.exe を窓なしで
      // 起動し、ログは cmd のリダイレクトで書く。cmd.exe は Bridge と一緒に終わるが、その子の codex は残る（libuv の
      // ジョブは孫に及ばない）。
      const child = codexSharedSpawn(runtime.executable, args, codexLogFile());
      child.on("error", () => (exited = true));
      child.on("exit", () => (exited = true));
      child.unref();
    } catch (error) {
      process.stderr.write(`[codex-shared] spawn failed: ${error instanceof Error ? error.message : String(error)}\n`);
      return undefined;
    }
    for (let i = 0; i < 40; i += 1) {
      await new Promise((r) => setTimeout(r, 250));
      if (await codexSharedReady()) {
        process.stderr.write(`[codex-shared] app-server started on :${CODEX_SHARED_PORT}\n`);
        return endpointFor(token);
      }
      // 自分の app-server は落ちた。同時に別の起動（buddy-codex）が上がっていればそれを使う。
      if (exited) return (await codexSharedReady()) ? endpointFor(token) : undefined;
    }
    process.stderr.write(`[codex-shared] app-server did not become ready (log: ${codexLogFile()})\n`);
    return undefined;
  }
}

/** 共有 app-server を Bridge から切り離して起動する（stdout / stderr はログへ）。 */
function codexSharedSpawn(executable: string, args: string[], logFile: string): ChildProcess {
  if (process.platform === "win32") {
    return spawn(systemExe("cmd"), ["/d", "/s", "/c", `"${codexSharedCommandLine(executable, args, logFile)}"`], {
      cwd: os.homedir(),
      // OAuth で足した MCP のトークン（bearer_token_env_var）も共有の app-server に渡す。
      env: { ...process.env, ...mcpTokenEnv() },
      stdio: "ignore",
      windowsHide: true,
      windowsVerbatimArguments: true
    });
  }
  const log = fs.openSync(logFile, "a");
  try {
    return spawn(executable, args, { cwd: os.homedir(), env: { ...process.env, ...mcpTokenEnv() }, detached: true, stdio: ["ignore", log, log] });
  } finally {
    fs.closeSync(log);
  }
}

/** cmd.exe /s /c に渡す 1 行（.cmd シムは %* で再パースされるので ^ を二重に、.exe は 1 回）。 */
export function codexSharedCommandLine(executable: string, args: string[], logFile: string): string {
  return `${commandLine(executable, args, isCmdShim(executable))} >> "${logFile}" 2>&1`;
}

function endpointFor(token: string): CodexSharedEndpoint {
  return { url: `ws://127.0.0.1:${CODEX_SHARED_PORT}`, token };
}

export const CodexSharedAppServer = new CodexSharedAppServerImpl();

/**
 * ターミナル（buddy-codex）でいま開いている Codex の thread。一覧の印と、開いた時点からの購読に使う。
 * buddy-codex が TUI と app-server の間に挟む中継が、thread/start・resume の応答から thread id を拾って
 * POST /codex/terminal で知らせる。中継は 15 秒ごとに送り直すので、Bridge が再起動しても戻る。
 */
export interface CodexTerminalEntry {
  threadId: string;
  cwd?: string;
  lastSeen: number;
  openedAt: number;
}

export class CodexTerminalRegistry {
  /** 送り直しが途絶えてから落とすまで（中継の送り直しは 15 秒間隔）。 */
  static readonly TTL_MS = 45_000;
  private readonly entries = new Map<string, CodexTerminalEntry>();

  constructor(private readonly now: () => number = Date.now) {}

  open(threadId: string, cwd?: string): void {
    const e = this.entries.get(threadId);
    if (e) {
      e.lastSeen = this.now();
      if (cwd) e.cwd = cwd;
      return;
    }
    this.entries.set(threadId, { threadId, cwd, lastSeen: this.now(), openedAt: this.now() });
    process.stderr.write(`[codex-terminal] open thread=${threadId.slice(0, 8)}…\n`);
  }

  close(threadId: string): void {
    if (this.entries.delete(threadId)) process.stderr.write(`[codex-terminal] closed thread=${threadId.slice(0, 8)}…\n`);
  }

  liveEntries(): CodexTerminalEntry[] {
    const now = this.now();
    for (const [id, e] of this.entries) if (now - e.lastSeen >= CodexTerminalRegistry.TTL_MS) this.entries.delete(id);
    return [...this.entries.values()];
  }

  isLive(threadId: string): boolean {
    return this.liveEntries().some((e) => e.threadId === threadId);
  }
}

export const codexTerminals = new CodexTerminalRegistry();
