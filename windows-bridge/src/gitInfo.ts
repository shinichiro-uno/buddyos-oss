import fs from "node:fs";
import path from "node:path";
import { agentRuntime, execRuntime } from "./agentProbe.js";
import type { RuntimeCommand } from "./runtime/command.js";

/// 作業フォルダの git ブランチ名を読む（iOS / Android の最下部バー用。mac の GitInfoReader の移植）。
/// `git -C <cwd> rev-parse --abbrev-ref HEAD`。WSL で動くエージェントの /home/... は WSL 側の git で読む。
/// git 管理外・失敗はすべて undefined（静かに失敗）。git が入っていないときは .git/HEAD を直接読む。

const GIT_TIMEOUT_MS = 2000;

/** .git/HEAD の中身からブランチ名。detached HEAD は "HEAD"（git rev-parse と同じ）。 */
export function parseGitHead(content: string): string | undefined {
  const t = content.trim();
  if (!t) return undefined;
  const ref = /^ref:\s*refs\/heads\/(.+)$/.exec(t);
  if (ref) return ref[1].trim() || undefined;
  return /^[0-9a-f]{7,64}$/i.test(t) ? "HEAD" : undefined;
}

/** cwd から上へ .git を探して HEAD を読む（worktree の `gitdir: ...` ファイルにも対応）。 */
export function branchFromGitDir(cwd: string): string | undefined {
  let dir = path.resolve(cwd);
  for (;;) {
    const dotGit = path.join(dir, ".git");
    try {
      let gitDir = dotGit;
      if (fs.statSync(dotGit).isFile()) {
        const m = /^gitdir:\s*(.+)$/m.exec(fs.readFileSync(dotGit, "utf8"));
        if (!m) return undefined;
        gitDir = path.resolve(dir, m[1].trim());
      }
      return parseGitHead(fs.readFileSync(path.join(gitDir, "HEAD"), "utf8"));
    } catch {
      /* 無ければ親へ */
    }
    const parent = path.dirname(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
}

/** runtimeLabel は adapter.runtimeLabel（WSL で動くエージェントは WSL の git で読む）。 */
export async function gitBranch(cwd: string | undefined, agentId: string, runtimeLabel?: string): Promise<string | undefined> {
  const dir = cwd?.trim();
  if (!dir) return undefined;
  const agent = agentRuntime(agentId, runtimeLabel);
  // WSL のパス（/home/...）は Windows から開けないので WSL 側の git で読む。
  if (process.platform === "win32" && agent?.kind === "wsl" && dir.startsWith("/")) {
    const git: RuntimeCommand = { kind: "wsl", executable: "git", label: "wsl:git", shell: false, wslDistro: agent.wslDistro };
    const r = await execRuntime(git, ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], GIT_TIMEOUT_MS);
    return r.ok ? r.stdout.trim() || undefined : undefined;
  }
  if (!fs.existsSync(dir)) return undefined;
  const git: RuntimeCommand = { kind: "native", executable: "git", label: "native:git", shell: false };
  const r = await execRuntime(git, ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"], GIT_TIMEOUT_MS);
  if (r.ok) return r.stdout.trim() || undefined;
  // git が起動できない（未インストール・時間切れ）ときだけ .git/HEAD から読む。git 管理外の exit は諦める。
  return r.error && !r.error.startsWith("exit ") ? branchFromGitDir(dir) : undefined;
}
