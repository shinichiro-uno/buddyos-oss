import fs from "node:fs";
import path from "node:path";

/// 会話の名前の付け替え（mac の SessionOverrideStore と同じ。`<configDir>/session-overrides.json`）。
/// agentId / sessionId ごとにユーザーが付けた名前を持ち、会話一覧を返すときに重ねる。
/// エージェント自身の記録（~/.claude/projects・sessions.json・ターミナルの会話）には頼らないので、
/// どのエージェントでも、記録をまだ持たないターミナルの会話でも同じように効く。
export class SessionTitleStore {
  private entries: Record<string, { title?: string }> | undefined;

  constructor(private readonly file: string) {}

  title(agentId: string, sessionId: string): string | undefined {
    return this.load()[key(agentId, sessionId)]?.title;
  }

  /** 空の名前は付け替えを外す（エージェントの記録の名前に戻る）。保存できたか返す。 */
  setTitle(agentId: string, sessionId: string, title: string | undefined): boolean {
    const entries = this.load();
    const k = key(agentId, sessionId);
    const trimmed = title?.trim();
    if (trimmed) entries[k] = { ...entries[k], title: trimmed };
    else delete entries[k];
    return this.save(entries);
  }

  private load(): Record<string, { title?: string }> {
    if (this.entries) return this.entries;
    let parsed: unknown;
    try {
      parsed = JSON.parse(fs.readFileSync(this.file, "utf8"));
    } catch {
      parsed = undefined;
    }
    const entries: Record<string, { title?: string }> = {};
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
        const t = v && typeof v === "object" ? (v as { title?: unknown }).title : undefined;
        if (typeof t === "string" && t) entries[k] = { title: t };
      }
    }
    this.entries = entries;
    return entries;
  }

  private save(entries: Record<string, { title?: string }>): boolean {
    const tmp = `${this.file}.${process.pid}.tmp`;
    try {
      // ~/.buddyos 配下は秘密も置く場所。フォルダは 0700・ファイルは 0600（Windows では mode は効かない）。
      fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
      const sorted = Object.fromEntries(Object.keys(entries).sort().map((k) => [k, entries[k]]));
      fs.writeFileSync(tmp, JSON.stringify(sorted, null, 2), { mode: 0o600 });
      fs.renameSync(tmp, this.file);
      return true;
    } catch (error) {
      console.error(`[session-titles] save failed: ${error instanceof Error ? error.message : String(error)}`);
      try {
        fs.rmSync(tmp, { force: true });
      } catch {
        /* 無視 */
      }
      return false;
    }
  }
}

function key(agentId: string, sessionId: string): string {
  return `${agentId}:${sessionId}`;
}
