import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// `ClaudeCodeAdapter` が claude CLI を起こすときの設定（モデル・作業フォルダ・子プロセスの env）。

function nonEmpty(value: string | undefined | null): string | undefined {
  if (value == null) return undefined;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/**
 * 設定されたモデル。env BUDDYOS_CLAUDE_MODEL だけを見る（無ければ CLI が settings.json を読む）。
 */
export function configuredModel(): string | undefined {
  return nonEmpty(process.env.BUDDYOS_CLAUDE_MODEL);
}

/**
 * spawn 用 cwd の解決。未指定のまま spawn すると bridge プロセスの cwd を継承し、
 * 履歴が `~/.claude/projects` の誰も開かないスラグに紐づいてターミナル側の /resume に
 * 出なくなる。新規セッションはホームに固定し、resume は transcript に記録された cwd に
 * 合わせる（--resume は cwd 不一致だとセッションを解決できない）。
 * fallback は transcript が見つからないときの戻り先（Bridge の既定 cwd。省略時はホーム）。
 */
export function resolveClaudeSessionCwd(cwd: string | undefined, resumingSessionId: string | undefined, fallback?: string): string {
  const trimmed = nonEmpty(cwd);
  if (trimmed) return trimmed;
  if (resumingSessionId && isBareUuid(resumingSessionId)) {
    const recorded = recordedSessionCwd(resumingSessionId);
    if (recorded) return recorded;
  }
  return nonEmpty(fallback) ?? os.homedir();
}

function isBareUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
}

/** `~/.claude/projects/<slug>/<sessionId>.jsonl` の先頭から transcript 記録の cwd を読む。 */
function recordedSessionCwd(sessionId: string): string | undefined {
  const projectsDir = path.join(os.homedir(), ".claude", "projects");
  let dirs: string[];
  try {
    dirs = fs.readdirSync(projectsDir);
  } catch {
    return undefined;
  }
  for (const dir of dirs) {
    const file = path.join(projectsDir, dir, `${sessionId}.jsonl`);
    let head: string;
    try {
      const fd = fs.openSync(file, "r");
      try {
        const buf = Buffer.alloc(256 * 1024);
        const read = fs.readSync(fd, buf, 0, buf.length, 0);
        head = buf.toString("utf8", 0, read);
      } finally {
        fs.closeSync(fd);
      }
    } catch {
      continue;
    }
    for (const raw of head.split("\n")) {
      const line = raw.trim();
      if (!line) continue;
      try {
        const obj = JSON.parse(line) as Record<string, unknown>;
        if (typeof obj.cwd === "string" && obj.cwd) return obj.cwd;
      } catch {
        /* 読み切りで途切れた行など。次の行へ。 */
      }
    }
    return undefined;
  }
  return undefined;
}

/** 子プロセスへ渡す env を組み立てる。 */
export function buildClaudeEnv(): NodeJS.ProcessEnv {
  // Bridge が起こした claude の印。ターミナル連携の hook はこれを見て何もしない（自分自身を「ターミナル」として登録しない）。
  return { ...process.env, BUDDYOS_SPAWNED: "1" };
}
