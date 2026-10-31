import crypto from "node:crypto";
import { event, type HistoryMessage, type SessionEvent, type SessionSummary } from "../protocol.js";
import type { JsonSessionStore } from "../sessionStore.js";
import { BaseAdapter, metadataText, type AgentSession, type Emit } from "./types.js";

export class EchoAdapter extends BaseAdapter {
  runtimeLabel = "local:echo";

  constructor(
    public id: string,
    public displayName: string,
    private readonly store: JsonSessionStore
  ) {
    super();
  }

  async openSession(sessionId: string | undefined, cwd: string | undefined): Promise<AgentSession> {
    return new EchoSession(this.id, sessionId ?? `echo-${crypto.randomUUID()}`, cwd, this.store);
  }

  async listSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    return this.store.list(this.id, limit, cwd);
  }

  async loadHistory(sessionId: string): Promise<HistoryMessage[]> {
    return this.store.history(this.id, sessionId);
  }

  async renameSession(sessionId: string, title: string): Promise<boolean> {
    return this.store.rename(this.id, sessionId, title);
  }
}

class EchoSession implements AgentSession {
  private started = false;

  constructor(
    private readonly agentId: string,
    public sessionId: string,
    private readonly cwd: string | undefined,
    private readonly store: JsonSessionStore
  ) {}

  async send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    if (!this.started) {
      this.started = true;
      this.store.ensureSession(this.agentId, this.sessionId, this.cwd);
      emit(event.sessionStarted(this.agentId, this.sessionId));
    }

    const userText = metadataText(originalEvent, text);
    this.store.appendMessage(this.agentId, this.sessionId, "user", userText, this.cwd, originalEvent.messageId ?? crypto.randomUUID());

    const messageId = crypto.randomUUID();
    const reply = `echo: ${userText}`;
    for (const char of reply) {
      emit(event.assistantDelta(this.agentId, this.sessionId, messageId, char));
      await sleep(8);
    }
    this.store.appendMessage(this.agentId, this.sessionId, "assistant", reply, this.cwd, messageId);
    emit(event.done(this.agentId, this.sessionId, messageId));
  }

  async close(): Promise<void> {}
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
