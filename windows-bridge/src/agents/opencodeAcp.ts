import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { AgentInfo, CommandInfo, HistoryMessage, ProviderCatalog, SessionSummary } from "../protocol.js";
import type { RuntimeCommand } from "../runtime/command.js";
import type { JsonSessionStore } from "../sessionStore.js";
import { AcpAdapter } from "./acpAdapter.js";
import { opencodeSkillNames } from "./opencodeSkills.js";
import { OpenCodeServe, OpenCodeServeTerminalSession, opencodeWrapperScript, summaryFromServe } from "./opencodeServe.js";
import type { AgentSession, SessionOptions } from "./types.js";

/**
 * OpenCode ACP 起動に必須の cache dir（XDG_CACHE_HOME。無いと ACP が起動しない）。
 * 中の opencode/bin（rg 等）・models.json・node_modules は実行に使われるので、全ユーザー共有の場所
 * （以前の C:\tmp\oc-cache・/tmp/oc-cache）には置かない。Windows は %LOCALAPPDATA%\BuddyOS\oc-cache、
 * それ以外は ~/.cache/buddyos-oc を 0700 で作る。シンボリックリンクや他人の持ち物なら使わず、起動ごとの一時フォルダにする。
 */
export function opencodeCacheHome(platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env, home = os.homedir()): string {
  const dir =
    platform === "win32"
      ? path.win32.join(env.LOCALAPPDATA || path.win32.join(home, "AppData", "Local"), "BuddyOS", "oc-cache")
      : path.posix.join(home, ".cache", "buddyos-oc");
  try {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const st = lstatSync(dir);
    const mine = typeof process.getuid !== "function" || st.uid === process.getuid();
    if (!st.isDirectory() || st.isSymbolicLink() || !mine) throw new Error("unsafe cache dir");
    if (platform !== "win32") chmodSync(dir, 0o700);
    return dir;
  } catch {
    return mkdtempSync(path.join(os.tmpdir(), "buddyos-oc-"));
  }
}

/**
 * WSL では Linux 側の $HOME/.cache/buddyos-oc を 0700 で作り、XDG_CACHE_HOME にしてから opencode を exec する
 * （Windows 側のパスは渡せないので sh で組み立てる）。$1 以降 = コマンドと引数。wsl.exe の引数に " を渡すと
 * 引用が崩れ得るので " は使わず、IFS を空にして単語分割を止める。シンボリックリンク・他人の持ち物なら起動しない。
 */
export const WSL_OPENCODE_CACHE_SCRIPT =
  "IFS=; set -f; umask 077; d=$HOME/.cache/buddyos-oc; mkdir -p $d && [ -O $d ] && [ ! -L $d ] && chmod 700 $d && mkdir -p $d/opencode/bin || exit 1; export XDG_CACHE_HOME=$d; exec $@";

/** 起動の仕方。WSL は表示名・runtimeLabel は元のまま、起動だけ sh を挟んで Linux 側のキャッシュを作る。 */
export function opencodeLaunch(runtime: RuntimeCommand): { runtime: RuntimeCommand; args: string[]; env?: Record<string, string> } {
  if (runtime.kind === "wsl") {
    return { runtime: { ...runtime, executable: "sh" }, args: ["-c", WSL_OPENCODE_CACHE_SCRIPT, "sh", runtime.executable, "acp"] };
  }
  const cacheHome = opencodeCacheHome();
  try {
    mkdirSync(path.join(cacheHome, "opencode", "bin"), { recursive: true, mode: 0o700 });
  } catch {
    /* ベストエフォート。spawn 時に再試行されるため握りつぶす。 */
  }
  return { runtime, args: ["acp"], env: { XDG_CACHE_HOME: cacheHome } };
}

const sameDir = (a: string, b: string): boolean => {
  const norm = (p: string): string => p.replace(/[\\/]+$/, "").replace(/\\/g, "/").toLowerCase();
  return norm(a) === norm(b);
};

/// OpenCode ACP adapter (Windows bridge 側)。
///
/// OpenCode は npm パッケージ `opencode-ai` の CLI で、`opencode acp` で
/// ACP サーバーを stdio 起動する。認証は `opencode providers login` 側で管理する。
///
/// models / mode / commands は live AcpSession が ACP の configOptions と
/// available_commands_update からキャプチャした値で答える。history は親 (AcpAdapter)
/// の JsonSessionStore をそのまま利用する。
export class OpenCodeAcpAdapter extends AcpAdapter {
  /** ACP configOptions の mode（値をそのまま set_config_option に渡す。mac と同じ）。effort はモデルで変わるので申告しない。 */
  readonly modes = ["build", "plan"];

  constructor(id: string, private readonly ocRuntime: RuntimeCommand, store: JsonSessionStore) {
    // XDG_CACHE_HOME を固定しないと OpenCode は ~/.cache の mkdir で落ちる。
    const launch = opencodeLaunch(ocRuntime);
    super(id, launch.runtime, store, {
      displayName: id === "opencode" ? "OpenCode" : `OpenCode (${ocRuntime.kind})`,
      args: launch.args,
      env: launch.env
    });
  }

  // ── ターミナルの OpenCode（buddy-opencode）と共有する serve（opencodeServe.ts） ──────────

  /** デスクトップのターミナル連携で buddy-opencode を入れてあり、native の opencode なら serve を使える。 */
  get terminal(): boolean {
    return this.ocRuntime.kind === "native" && existsSync(opencodeWrapperScript());
  }

  /** serve を起動しておく（buddy-opencode が繋げるように。Bridge の起動時に呼ぶ）。 */
  async startTerminalServe(): Promise<void> {
    if (this.terminal) await OpenCodeServe.ensure(this.ocRuntime);
  }

  async terminalSession(sessionId: string): Promise<boolean> {
    if (!this.terminal || !OpenCodeServe.url) return false;
    return (await OpenCodeServe.terminalSessions()).some((s) => s.id === sessionId);
  }

  override async openSession(sessionId: string | undefined, cwd: string | undefined, options?: SessionOptions): Promise<AgentSession> {
    // ターミナルで開いている会話は、同じ serve 越しに送る（別の opencode acp で開くと TUI に流れない）。
    if (sessionId && !options?.permissionMode && this.terminal && OpenCodeServe.url) {
      const live = (await OpenCodeServe.terminalSessions()).find((s) => s.id === sessionId);
      if (live) return new OpenCodeServeTerminalSession(this.id, sessionId, typeof live.directory === "string" ? live.directory : cwd);
    }
    return super.openSession(sessionId, cwd);
  }

  override async listSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    const sessions = await super.listSessions(limit, cwd);
    if (!this.terminal) return sessions;
    if (!OpenCodeServe.url) void OpenCodeServe.ensure(this.ocRuntime);
    const live = await OpenCodeServe.terminalSessions().catch(() => []);
    if (live.length === 0) return sessions;
    // ターミナルで開いている会話は印を付けて先頭へ。ACP の履歴に無いもの（ターミナルで始めた会話）は serve の情報で足す。
    const rows = live.map(summaryFromServe).filter((s) => !cwd || !s.cwd || sameDir(s.cwd, cwd));
    const liveIds = new Set(rows.map((s) => s.sessionId));
    return [...rows, ...sessions.filter((s) => !liveIds.has(s.sessionId))];
  }

  override async loadHistory(sessionId: string): Promise<HistoryMessage[]> {
    const stored = await super.loadHistory(sessionId);
    // ターミナルで続けた分は ACP の履歴に無い。serve の記録の方が長ければそちらを出す。
    if (!this.terminal || !OpenCodeServe.url) return stored;
    const served = await OpenCodeServe.history(sessionId).catch(() => []);
    return served.length > stored.length ? served : stored;
  }

  override async currentInfo(): Promise<AgentInfo | undefined> {
    const live = this.liveSession;
    return {
      model: live?.modelCurrent,
      provider: "OpenCode",
      reasoningEffort: live?.effortCurrent,
      codexMode: live?.modeCurrent,
      runtime: this.runtimeLabel
    };
  }

  override async listAvailableModels(): Promise<ProviderCatalog[]> {
    const options = this.liveSession?.modelOptions ?? [];
    if (options.length === 0) return [];
    return [
      {
        id: "opencode",
        label: "OpenCode",
        models: options.map((option) => ({ id: option.value, label: option.name }))
      }
    ];
  }

  override async setModel(
    model: string,
    _provider?: string,
    reasoningEffort?: string,
    codexMode?: string
  ): Promise<void> {
    const live = this.liveSession;
    if (!live) throw new Error("チャットを開いてから切り替えてください");
    // 設定の順番: mode → effort → model（1 リクエストにつき 1 set のみ）。
    if (codexMode && codexMode.trim()) {
      await live.setConfigOption("mode", codexMode.trim());
    } else if (reasoningEffort && reasoningEffort.trim()) {
      await live.setConfigOption("effort", reasoningEffort.trim());
    } else if (model && model.trim()) {
      await live.setConfigOption("model", model.trim());
    } else {
      throw new Error("変更内容が指定されていません");
    }
  }

  override async listCommands(): Promise<CommandInfo[]> {
    const commands = this.liveSession?.commands ?? [];
    if (commands.length === 0) return [];
    // skills は別タブで出すため、commands からは skills-dir に存在する名前を除外する。
    const skillNames = opencodeSkillNames();
    return commands
      .filter((command) => !skillNames.has(command.name))
      .map((command) => ({
        // skills-dir に重複するものは除外済みなので、残るのは built-in のみ → kind="local"。
        id: command.name,
        kind: "local",
        title: command.name,
        ...(command.description ? { subtitle: command.description } : {})
      }));
  }
}
