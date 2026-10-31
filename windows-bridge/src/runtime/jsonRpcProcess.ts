import { EventEmitter } from "node:events";
import type { RuntimeCommand } from "./command.js";
import { killProcessTree, spawnRuntime } from "./command.js";

interface PendingRequest {
  resolve: (value: Record<string, unknown>) => void;
  reject: (error: Error) => void;
  timeout?: NodeJS.Timeout;
}

export interface JsonRpcProcessOptions {
  /** false で "jsonrpc":"2.0" を付けない（codex app-server は付けない流儀。mac と同じ形で送る）。 */
  jsonrpcField?: boolean;
}

export class JsonRpcProcess extends EventEmitter {
  private readonly child;
  private readonly jsonrpcField: boolean;
  private nextId = 0;
  private stdoutBuffer = "";
  private readonly pending = new Map<number, PendingRequest>();
  /** 子プロセスが exit / close / spawn 失敗した。以後の request() は即 reject する。 */
  private processExited = false;

  constructor(runtime: RuntimeCommand, args: string[], cwd?: string, env?: NodeJS.ProcessEnv, options: JsonRpcProcessOptions = {}) {
    super();
    this.jsonrpcField = options.jsonrpcField !== false;
    this.child = spawnRuntime(runtime, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: "pipe"
    });

    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk: string) => this.handleStdout(chunk));
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk: string) => this.emit("stderr", chunk));
    // stdin の 'error'（EPIPE / ERR_STREAM_DESTROYED）を捕まえないと、子プロセスが
    // 先に死んだ後の write が uncaughtException 化してブリッジ全体を落とす。stdin が
    // 壊れた = もう応答は来ないので、在飛行リクエストも即 reject して timeout 待ちを防ぐ。
    this.child.stdin.on("error", (error) => {
      this.emit("stderr", `[json-rpc stdin error] ${String(error)}\n`);
      this.failAll(error instanceof Error ? error : new Error(String(error)));
    });
    this.child.on("error", (error) => this.failAll(error));
    // exit 時点で Node は stdin を destroy する。孫プロセス（cmd.exe / wsl.exe 配下）が
    // stdout を握ったままだと 'close' が遅れる・来ないので、'exit' でも死亡扱いにする。
    // ただし 'exit' は stdout を読み切る前に来ることがある（Windows で顕著）。ここで即 failAll すると
    // パイプに残った応答（initialize の error 等）を捨て、failTurn の後に残りの session/update が流れる。
    // 新しい request は processExited で弾きつつ、failAll は stdout の 'end'（読み切った）か 'close' まで待つ。
    // 孫プロセスが stdout を握って両方来ないときは、猶予後に畳む。
    this.child.on("exit", (code, signal) => {
      this.processExited = true;
      const fail = () => this.failAll(new Error(`json-rpc process exited code=${code ?? "null"} signal=${signal ?? "null"}`));
      if (this.child.stdout.readableEnded) {
        fail();
        return;
      }
      const timer = setTimeout(fail, 1000);
      timer.unref();
      this.child.stdout.once("end", () => {
        clearTimeout(timer);
        fail();
      });
    });
    this.child.on("close", (code, signal) => {
      this.processExited = true;
      this.failAll(new Error(`json-rpc process closed code=${code ?? "null"} signal=${signal ?? "null"}`));
      this.emit("close", code, signal);
    });
  }

  /** 子プロセスが生きていて stdin に書ける状態か。死んだ client を使い回さない判定に使う。 */
  get alive(): boolean {
    return !this.processExited && !this.child.stdin.destroyed && this.child.stdin.writable;
  }

  /** timeoutMs が 0 以下（または有限でない）なら時間切れを付けない（長く走る ACP の session/prompt 用）。 */
  request(method: string, params: Record<string, unknown>, timeoutMs = 30000): Promise<Record<string, unknown>> {
    // 死んだ stdin への write は throw も 'error' も起きず、timeout まで宙吊りになる。先に弾く。
    if (!this.alive) {
      return Promise.reject(new Error(`json-rpc process is not running: ${method}`));
    }
    this.nextId += 1;
    const id = this.nextId;
    const payload = JSON.stringify(this.envelope({ id, method, params }));

    return new Promise((resolve, reject) => {
      // setTimeout は 2^31-1 ms を超える値を 1ms に丸めるので、時間切れ無しはタイマーを作らない。
      const timeout =
        timeoutMs > 0 && Number.isFinite(timeoutMs)
          ? setTimeout(() => {
              this.pending.delete(id);
              reject(new Error(`json-rpc request timed out: ${method}`));
            }, timeoutMs)
          : undefined;
      this.pending.set(id, { resolve, reject, timeout });
      // 子プロセスが死んでいると write が同期 throw する。pending を畳んで reject し、
      // ここで例外を逃がさない（'error' リスナと二重の防御）。
      // destroyed なストリームでは throw せずコールバックに ERR_STREAM_DESTROYED が来るだけなので、
      // そちらでも reject する（failAll / timeout 済みなら pending に無いので何もしない）。
      const failWrite = (error: unknown) => {
        if (!this.pending.has(id)) return;
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(new Error(`json-rpc write failed: ${error instanceof Error ? error.message : String(error)}`));
      };
      try {
        this.child.stdin.write(`${payload}\n`, (error) => {
          if (error) failWrite(error);
        });
      } catch (error) {
        failWrite(error);
      }
    });
  }

  /** 応答を求めない通知（`session/cancel` 等）を送る。死んだプロセスには送らない。 */
  notify(method: string, params: Record<string, unknown>): void {
    this.writeMessage(this.envelope({ method, params }));
  }

  /** エージェント → クライアントの要求（`request` イベント）に result を返す。 */
  respond(id: number | string, result: Record<string, unknown>): void {
    this.writeMessage(this.envelope({ id, result }));
  }

  /** エージェント → クライアントの要求に error を返す（未対応メソッドは -32601）。 */
  respondError(id: number | string, code: number, message: string): void {
    this.writeMessage(this.envelope({ id, error: { code, message } }));
  }

  close(): void {
    try {
      this.child.stdin.end();
    } catch {
      /* stdin already closed */
    }
    // child.kill() だけだと WSL / opencode serve 等の孫プロセスが孤児化する。
    // プロセスツリーごと終了させる。
    killProcessTree(this.child);
  }

  private handleStdout(chunk: string): void {
    this.stdoutBuffer += chunk;
    for (;;) {
      const newline = this.stdoutBuffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.stdoutBuffer.slice(0, newline).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(newline + 1);
      if (line) this.handleLine(line);
    }
  }

  private handleLine(line: string): void {
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(line) as Record<string, unknown>;
    } catch {
      this.emit("stderr", `[json-rpc parse failed] ${line}\n`);
      return;
    }

    // method を持つものは相手からの要求・通知。id が自分の pending と偶然一致しても
    // 応答として扱わない（session/request_permission で session/prompt が解決される事故を防ぐ）。
    if (typeof message.method === "string") {
      const id = message.id;
      if (typeof id === "number" || typeof id === "string") {
        // 要求は必ず応答しないと相手が待ち続ける。購読者がいなければ -32601 で即返す。
        if (this.listenerCount("request") > 0) {
          this.emit("request", message);
        } else {
          this.respondError(id, -32601, `Method not found: ${message.method}`);
        }
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

  private envelope(body: Record<string, unknown>): Record<string, unknown> {
    return this.jsonrpcField ? { jsonrpc: "2.0", ...body } : body;
  }

  private writeMessage(message: Record<string, unknown>): void {
    if (!this.alive) return;
    // 失敗は 'error' リスナ / exit 側で処理されるので、ここでは例外を逃がさないだけ。
    try {
      this.child.stdin.write(`${JSON.stringify(message)}\n`);
    } catch {
      /* stdin already closed */
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
