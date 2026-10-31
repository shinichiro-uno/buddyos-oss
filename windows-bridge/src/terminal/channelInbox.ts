/// iPhone → ターミナルの Claude Code への受け箱（mac の ClaudeChannelInbox の移植）。
/// ターミナルの claude が起動した channel サーバ（buddy-channel）が GET /claude/channel/poll で long-poll して取りに来る。
/// poll が来ている間だけ「送れる」とみなす（channel 付きで起動していない claude は poll しない）。

export type ChannelItem = { kind: "text"; text: string } | { kind: "permission"; requestId: string; behavior: string };

export class ClaudeChannelInbox {
  private readonly queues = new Map<string, ChannelItem[]>();
  private readonly waiters = new Map<string, { token: number; resolve: (items: ChannelItem[]) => void }>();
  private readonly lastSeen = new Map<string, number>();
  private token = 0;

  isConnected(sessionId: string): boolean {
    if (this.waiters.has(sessionId)) return true;
    const t = this.lastSeen.get(sessionId);
    return t !== undefined && Date.now() - t < 10_000;
  }

  forget(sessionId: string): void {
    this.waiters.get(sessionId)?.resolve([]);
    this.waiters.delete(sessionId);
    this.queues.delete(sessionId);
    this.lastSeen.delete(sessionId);
  }

  post(sessionId: string, text: string): void {
    this.enqueue(sessionId, { kind: "text", text });
  }

  postPermission(sessionId: string, requestId: string, behavior: string): void {
    this.enqueue(sessionId, { kind: "permission", requestId, behavior });
  }

  private enqueue(sessionId: string, item: ChannelItem): void {
    const w = this.waiters.get(sessionId);
    if (w) {
      this.waiters.delete(sessionId);
      w.resolve([item]);
      return;
    }
    const q = this.queues.get(sessionId) ?? [];
    q.push(item);
    this.queues.set(sessionId, q);
  }

  /** 溜まっていれば即返す。無ければ timeoutMs まで待つ（空で返る）。同じ session の古い poll は空で返して入れ替える。 */
  poll(sessionId: string, timeoutMs: number): Promise<ChannelItem[]> {
    this.lastSeen.set(sessionId, Date.now());
    const q = this.queues.get(sessionId);
    if (q && q.length > 0) {
      this.queues.delete(sessionId);
      return Promise.resolve(q);
    }
    this.waiters.get(sessionId)?.resolve([]);
    const token = ++this.token;
    return new Promise((resolve) => {
      const finish = (items: ChannelItem[]): void => {
        clearTimeout(timer);
        if (this.waiters.get(sessionId)?.token === token) this.waiters.delete(sessionId);
        this.lastSeen.set(sessionId, Date.now());
        resolve(items);
      };
      const timer = setTimeout(() => finish([]), timeoutMs);
      this.waiters.set(sessionId, { token, resolve: finish });
    });
  }
}
