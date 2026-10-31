import { EventEmitter } from "node:events";
import WebSocket from "ws";

interface PendingRequest {
  resolve: (value: Record<string, unknown>) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
}

/**
 * WebSocket 上の JSON-RPC（1 フレーム = 1 メッセージ）。JsonRpcProcess と同じ口（request / notify /
 * respond / respondError / close / alive と notification・request・close イベント）を持つので、
 * 共有の codex app-server（CodexSharedAppServer）に繋ぐときに差し替えて使う。"jsonrpc" は付けない（codex の流儀）。
 */
export class JsonRpcWebSocket extends EventEmitter {
  private nextId = 0;
  private readonly pending = new Map<number, PendingRequest>();
  private closed = false;

  private constructor(private readonly ws: WebSocket) {
    super();
    ws.on("message", (data, isBinary) => {
      const text = isBinary ? Buffer.from(data as Buffer).toString("utf8") : String(data);
      // 1 フレームに改行区切りで複数入っていても読めるようにする。
      for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (trimmed) this.handleLine(trimmed);
      }
    });
    ws.on("error", (error) => this.emit("stderr", `[json-rpc ws error] ${String(error)}\n`));
    ws.on("close", (code) => {
      this.closed = true;
      this.failAll(new Error(`json-rpc websocket closed code=${code}`));
      this.emit("close", code, null);
    });
  }

  /** 繋がるまで待つ。認証に失敗した・待ち受けていないときは reject。 */
  static connect(url: string, token: string, timeoutMs = 5000): Promise<JsonRpcWebSocket> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url, {
        headers: { Authorization: `Bearer ${token}` },
        perMessageDeflate: false,
        handshakeTimeout: timeoutMs,
        maxPayload: 64 * 1024 * 1024
      });
      const fail = (error: Error): void => reject(error);
      ws.once("error", fail);
      ws.once("unexpected-response", (_req, res) => {
        reject(new Error(`websocket handshake failed: HTTP ${res.statusCode ?? "?"}`));
        // terminate は "error" を出すので、fail を付けたまま閉じる（reject は 2 回目以降は効かない）。
        ws.terminate();
      });
      ws.once("open", () => {
        ws.removeListener("error", fail);
        resolve(new JsonRpcWebSocket(ws));
      });
    });
  }

  get alive(): boolean {
    return !this.closed && this.ws.readyState === WebSocket.OPEN;
  }

  request(method: string, params: Record<string, unknown>, timeoutMs = 30000): Promise<Record<string, unknown>> {
    if (!this.alive) return Promise.reject(new Error(`json-rpc websocket is not open: ${method}`));
    this.nextId += 1;
    const id = this.nextId;
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`json-rpc request timed out: ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timeout });
      this.ws.send(JSON.stringify({ id, method, params }), (error) => {
        if (!error || !this.pending.has(id)) return;
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(new Error(`json-rpc write failed: ${error.message}`));
      });
    });
  }

  notify(method: string, params: Record<string, unknown>): void {
    this.write({ method, params });
  }

  respond(id: number | string, result: Record<string, unknown>): void {
    this.write({ id, result });
  }

  respondError(id: number | string, code: number, message: string): void {
    this.write({ id, error: { code, message } });
  }

  /** 接続だけを閉じる（共有の app-server は止めない）。 */
  close(): void {
    this.closed = true;
    try {
      this.ws.close();
    } catch {
      /* already closed */
    }
  }

  private write(message: Record<string, unknown>): void {
    if (!this.alive) return;
    try {
      this.ws.send(JSON.stringify(message));
    } catch {
      /* 閉じかけ。close 側で畳む */
    }
  }

  private handleLine(line: string): void {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(line) as Record<string, unknown>;
    } catch {
      this.emit("stderr", `[json-rpc parse failed] ${line.slice(0, 200)}\n`);
      return;
    }
    if (typeof message.method === "string") {
      const id = message.id;
      if (typeof id === "number" || typeof id === "string") {
        // 共有サーバーでは他の接続の要求にも答えてしまわないよう、購読者がいないときも黙って捨てる。
        if (this.listenerCount("request") > 0) this.emit("request", message);
        return;
      }
      this.emit("notification", message);
      return;
    }
    if (typeof message.id === "number") {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      clearTimeout(pending.timeout);
      pending.resolve(message);
    }
  }

  private failAll(error: Error): void {
    for (const [id, pending] of this.pending.entries()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
      this.pending.delete(id);
    }
  }
}
