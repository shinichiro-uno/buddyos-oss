import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execRuntime } from "../agentProbe.js";
import type { RuntimeCommand } from "../runtime/command.js";

/**
 * ターミナルで開かれている Grok の会話（mac の GrokPresence の移植）。
 * grok は開いている会話を `~/.grok/active_sessions.json`（[{session_id, pid, cwd, opened_at}]）に書く。
 * pid が生きていて、Bridge 自身が動かしている会話でないものをターミナルとみなす
 * （mac は ps でコマンド行の ` agent ` を見るが、Windows では重いので Bridge の実行中の会話を除く）。
 */
const activeSessionsPath = (): string => path.join(os.homedir(), ".grok", "active_sessions.json");

export const GrokPresence = {
  path: activeSessionsPath,

  liveSessions(
    file = activeSessionsPath(),
    alive: (pid: number) => boolean = pidAlive,
    exclude: ReadonlySet<string> = bridgeGrokSessions
  ): Map<string, { cwd?: string }> {
    const live = new Map<string, { cwd?: string }>();
    let list: unknown;
    try {
      list = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch {
      return live;
    }
    if (!Array.isArray(list)) return live;
    for (const entry of list) {
      if (!entry || typeof entry !== "object") continue;
      const e = entry as Record<string, unknown>;
      const sid = typeof e.session_id === "string" ? e.session_id : "";
      const pid = typeof e.pid === "number" ? e.pid : Number.NaN;
      if (!sid || !(pid > 0) || exclude.has(sid) || !alive(pid)) continue;
      live.set(sid, { cwd: typeof e.cwd === "string" && e.cwd ? e.cwd : undefined });
    }
    return live;
  }
};

/** Bridge が headless の grok を動かしている会話（ターミナルの印から除く）。 */
export const bridgeGrokSessions = new Set<string>();

export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

/**
 * grok の leader（同じ会話を複数の画面で共有する常駐プロセス）。`grok agent --leader stdio` で乗る。
 * 古い grok には無いので、`grok agent --help` に --leader があるかを一度だけ確かめる（結果は覚えておく）。
 */
const leaderCache = new Map<string, boolean>();
const leaderProbing = new Map<string, Promise<boolean>>();

export const GrokLeader = {
  /** 確かめ済みの結果（まだなら false を返し、裏で確かめ始める）。capabilities のような同期の判定に使う。 */
  cached(runtime: RuntimeCommand): boolean {
    const hit = leaderCache.get(runtime.label);
    if (hit !== undefined) return hit;
    void GrokLeader.isSupported(runtime);
    return false;
  },

  isSupported(runtime: RuntimeCommand): Promise<boolean> {
    const hit = leaderCache.get(runtime.label);
    if (hit !== undefined) return Promise.resolve(hit);
    let probe = leaderProbing.get(runtime.label);
    if (!probe) {
      probe = execRuntime(runtime, ["agent", "--help"], 10_000)
        .then((r) => `${r.stdout}\n${r.stderr}`.includes("--leader"))
        .catch(() => false)
        .then((ok) => {
          leaderCache.set(runtime.label, ok);
          leaderProbing.delete(runtime.label);
          return ok;
        });
      leaderProbing.set(runtime.label, probe);
    }
    return probe;
  }
};
