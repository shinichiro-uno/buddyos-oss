import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import type { HistoryMessage, SessionSummary } from "./protocol.js";
import { SessionTitleStore } from "./sessionTitles.js";

interface StoredRoot {
  sessions: StoredSession[];
}

interface StoredSession {
  agentId: string;
  sessionId: string;
  title: string;
  cwd?: string;
  createdAt: string;
  lastActive: string;
  messages: StoredMessage[];
}

interface StoredMessage {
  role: string;
  content: string;
  messageId: string;
  createdAt: string;
}

export class JsonSessionStore {
  private readonly file: string;
  private root: StoredRoot;
  /** 全エージェント共通の名前の付け替え（session-overrides.json。一覧を返すときに server が重ねる）。 */
  readonly titles: SessionTitleStore;

  constructor(configDir: string) {
    this.file = path.join(configDir, "sessions.json");
    this.root = this.load();
    this.titles = new SessionTitleStore(path.join(configDir, "session-overrides.json"));
  }

  list(agentId: string, limit: number, cwd?: string): SessionSummary[] {
    return this.root.sessions
      .filter((session) => session.agentId === agentId)
      .filter((session) => !cwd || session.cwd === cwd)
      .sort((a, b) => b.lastActive.localeCompare(a.lastActive))
      .slice(0, Math.max(1, limit))
      .map((session) => ({
        sessionId: session.sessionId,
        title: session.title || "(no messages)",
        lastActive: session.lastActive,
        messageCount: session.messages.length,
        cwd: session.cwd
      }));
  }

  history(agentId: string, sessionId: string): HistoryMessage[] {
    const session = this.find(agentId, sessionId);
    return (session?.messages ?? []).map((message, index) => ({ ...message, seq: index + 1 }));
  }

  historySince(agentId: string, sessionId: string, sinceSeq: number): HistoryMessage[] {
    return this.history(agentId, sessionId).filter((message) => (message.seq ?? 0) > sinceSeq);
  }

  latestSeq(agentId: string, sessionId: string): number {
    return this.find(agentId, sessionId)?.messages.length ?? 0;
  }

  rename(agentId: string, sessionId: string, title: string): boolean {
    const session = this.find(agentId, sessionId);
    if (!session) return false;
    session.title = title;
    session.lastActive = new Date().toISOString();
    this.save();
    return true;
  }

  appendMessage(agentId: string, sessionId: string, role: string, content: string, cwd?: string, messageId: string = crypto.randomUUID()): string {
    const now = new Date().toISOString();
    const session = this.ensure(agentId, sessionId, cwd);
    session.cwd = cwd ?? session.cwd;
    session.lastActive = now;
    if (role === "user" && (!session.title || session.title === "(no messages)")) {
      session.title = preview(content);
    }
    session.messages.push({ role, content, messageId, createdAt: now });
    this.save();
    return messageId;
  }

  ensureSession(agentId: string, sessionId: string, cwd?: string, title = "(no messages)"): void {
    this.ensure(agentId, sessionId, cwd, title);
    this.save();
  }

  replaceSessionId(agentId: string, oldSessionId: string, newSessionId: string, cwd?: string): void {
    if (oldSessionId === newSessionId) return;
    const oldSession = this.find(agentId, oldSessionId);
    const newSession = this.find(agentId, newSessionId);
    if (!oldSession) {
      this.ensure(agentId, newSessionId, cwd);
      this.save();
      return;
    }

    if (newSession) {
      const existingIds = new Set(newSession.messages.map((message) => message.messageId));
      for (const message of oldSession.messages) {
        if (!existingIds.has(message.messageId)) newSession.messages.push(message);
      }
      newSession.title = newSession.title || oldSession.title;
      newSession.lastActive = [newSession.lastActive, oldSession.lastActive].sort().at(-1) ?? newSession.lastActive;
      newSession.cwd = newSession.cwd ?? oldSession.cwd ?? cwd;
      this.root.sessions = this.root.sessions.filter((session) => session !== oldSession);
    } else {
      oldSession.sessionId = newSessionId;
      oldSession.cwd = oldSession.cwd ?? cwd;
    }
    this.save();
  }

  private ensure(agentId: string, sessionId: string, cwd?: string, title = "(no messages)"): StoredSession {
    const found = this.find(agentId, sessionId);
    if (found) return found;
    const now = new Date().toISOString();
    const created: StoredSession = {
      agentId,
      sessionId,
      title,
      cwd,
      createdAt: now,
      lastActive: now,
      messages: []
    };
    this.root.sessions.push(created);
    return created;
  }

  private find(agentId: string, sessionId: string): StoredSession | undefined {
    return this.root.sessions.find((session) => session.agentId === agentId && session.sessionId === sessionId);
  }

  private load(): StoredRoot {
    try {
      const parsed = JSON.parse(fs.readFileSync(this.file, "utf8")) as StoredRoot;
      if (Array.isArray(parsed.sessions)) return parsed;
    } catch {
      // Fall through to an empty store.
    }
    return { sessions: [] };
  }

  private save(): void {
    // Windows では Defender / インデクサが sessions.json を掴んでいると write / rename が
    // EPERM・EBUSY・EACCES で一時的に失敗する（graceful-fs と同じ事情）。短く同期リトライし、
    // それでも駄目ならログだけ残して throw しない。呼び出し側（close / data ハンドラ）の done・resolve が
    // 飛ばされるとターンが終わらなくなるため。メモリ上の root は更新済みなので次の save 成功時に永続化される。
    const tmp = `${this.file}.tmp`;
    for (let attempt = 0; ; attempt += 1) {
      try {
        // 会話の中身なので、フォルダは 0700・ファイルは 0600（Linux / WSL。Windows では mode は効かない）。
        fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
        fs.writeFileSync(tmp, JSON.stringify(this.root, null, 2), { mode: 0o600 });
        if (process.platform !== "win32") fs.chmodSync(tmp, 0o600);
        fs.renameSync(tmp, this.file);
        return;
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (attempt < SAVE_RETRIES && (code === "EPERM" || code === "EBUSY" || code === "EACCES")) {
          sleepSync(SAVE_RETRY_DELAY_MS);
          continue;
        }
        console.error(`[session-store] save failed: ${error instanceof Error ? error.message : String(error)}`);
        return;
      }
    }
  }
}

// save() の一時的な失敗（EPERM/EBUSY/EACCES）に対する同期リトライ。合計でも 100ms 未満に収める。
const SAVE_RETRIES = 3;
const SAVE_RETRY_DELAY_MS = 25;

function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function preview(content: string): string {
  const compact = content.replace(/\s+/g, " ").trim();
  return compact.length > 80 ? `${compact.slice(0, 77)}...` : compact || "(no messages)";
}
