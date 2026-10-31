import http from "node:http";
import readline from "node:readline";
import { toWslPath, type RuntimeKind } from "../runtime/command.js";
import { MCP_SERVER_NAME, PORT_ENV_VAR, TOKEN_ENV_VAR, TOOL_TIMEOUT_SECONDS } from "./workspace.js";

// stdio の MCP サーバしか受け取れない ACP エージェント（hermes など。initialize で mcpCapabilities.http を申告しない）に、
// mainagent の道具を渡すための中継（mac の McpStdioRelay.swift の移植）。Bridge を `node bridge.cjs mcp-stdio-relay` で起こすと、
// この中継だけが動く（Bridge のサーバも起こさず、設定フォルダにも触らない。index.ts の入口で分ける）。
//
// - stdin: MCP の stdio（改行区切りの JSON-RPC 1 件ずつ）。1 行ずつ POST http://127.0.0.1:<port>/mcp へ送る
//   （/mcp は JSON で返し SSE を使わないので、応答の本文をそのまま 1 行で stdout に書く）。
// - 通知（id 無し）には何も返さない（Bridge は 202）。クライアントからの応答（method 無し）は送らない。
// - Bridge に繋がらない・401（合鍵が無効）などは、要求の id で JSON-RPC の error を返す。
// - stdin が閉じたら、送りかけの返事を少しだけ待って終わる。
//
// 合鍵とポートは環境変数で受け取る（ACP の stdio の McpServer の env）。引数に載せるとプロセスの一覧で見えるため。

export const RELAY_SUBCOMMAND = "mcp-stdio-relay";
/** Bridge にもエージェントにも無い、中継が自分で返す error の code（JSON-RPC の server error の範囲）。 */
export const RELAY_UNREACHABLE_CODE = -32000;
export const RELAY_UNAUTHORIZED_CODE = -32001;

export interface RelayResponse {
  status: number;
  body: string;
}

/** Bridge へ 1 件送る（テストは差し替える）。 */
export type RelayTransport = (body: string) => Promise<RelayResponse>;

/** 道具の呼び出しは承認（5 分）と返事（5 分）を待つので、Bridge が黙っている間に切らない長さにする。 */
export function httpRelayTransport(port: number, token: string, timeoutMs = (TOOL_TIMEOUT_SECONDS + 60) * 1000): RelayTransport {
  return (body) =>
    new Promise((resolve, reject) => {
      const req = http.request(
        {
          host: "127.0.0.1",
          port,
          path: "/mcp",
          method: "POST",
          headers: {
            "content-type": "application/json",
            accept: "application/json, text/event-stream",
            authorization: `Bearer ${token}`,
            "content-length": Buffer.byteLength(body)
          }
        },
        (res) => {
          const chunks: Buffer[] = [];
          res.on("data", (c: Buffer) => chunks.push(c));
          res.on("end", () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8") }));
          res.on("error", reject);
        }
      );
      req.setTimeout(timeoutMs, () => req.destroy(new Error("timed out")));
      req.on("error", reject);
      req.end(body);
    });
}

export function relayErrorLine(id: unknown, code: number, message: string): string {
  return JSON.stringify({ error: { code, message }, id: id ?? null, jsonrpc: "2.0" });
}

/** 応答の本文を 1 行にする。JSON でなければ undefined。 */
export function oneLineJson(body: string): string | undefined {
  try {
    const obj = JSON.parse(body) as unknown;
    return /[\r\n]/.test(body) ? JSON.stringify(obj) : body;
  } catch {
    return undefined;
  }
}

/** stdin の 1 行を Bridge へ送り、stdout に書く 1 行（改行を含まない）を返す。書くものが無ければ undefined。 */
export async function relayLine(line: string, transport: RelayTransport, port: number): Promise<string | undefined> {
  const trimmed = line.trim();
  if (!trimmed) return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return relayErrorLine(null, -32700, "parse error");
  }
  // バッチ（配列）は MCP 2025-06-18 で無くなり、Bridge も受けない。
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return relayErrorLine(null, -32600, "invalid request");
  const msg = parsed as Record<string, unknown>;
  if (typeof msg.method !== "string") return undefined;
  const id = msg.id ?? undefined;
  let res: RelayResponse;
  try {
    res = await transport(trimmed);
  } catch (error) {
    relayLog(`Bridge に繋がらない: ${error instanceof Error ? error.message : String(error)}`);
    if (id === undefined) return undefined;
    return relayErrorLine(id, RELAY_UNREACHABLE_CODE, `BuddyOS の Bridge（127.0.0.1:${port}）に繋がらない。Bridge が動いているか確かめてください`);
  }
  if (res.status >= 200 && res.status < 300) {
    if (id === undefined) return undefined;
    const line1 = oneLineJson(res.body);
    if (line1 !== undefined) return line1;
    relayLog(`Bridge の応答が JSON ではない（HTTP ${res.status}、${Buffer.byteLength(res.body)} バイト）`);
    return relayErrorLine(id, -32603, `Bridge の応答が JSON ではない（HTTP ${res.status}）`);
  }
  if (res.status === 401) {
    relayLog("Bridge が合鍵を受け付けない（401）");
    if (id === undefined) return undefined;
    return relayErrorLine(id, RELAY_UNAUTHORIZED_CODE, "BuddyOS の Bridge が合鍵を受け付けない（401）。mainagent のセッションを開き直してください");
  }
  relayLog(`Bridge が HTTP ${res.status} を返した`);
  if (id === undefined) return undefined;
  return relayErrorLine(id, RELAY_UNREACHABLE_CODE, `BuddyOS の Bridge が HTTP ${res.status} を返した`);
}

/** stderr へ（エージェントのログに残る）。合鍵は書かない。 */
function relayLog(message: string): void {
  process.stderr.write(`[buddyos-mcp-relay] ${message}\n`);
}

export function isRelayInvocation(argv: readonly string[]): boolean {
  return argv[2] === RELAY_SUBCOMMAND;
}

/** stdin が閉じるまで中継して終わる。合鍵かポートが無ければ 64（EX_USAGE）で終わる。 */
export async function runStdioRelay(env: NodeJS.ProcessEnv = process.env): Promise<never> {
  const token = env[TOKEN_ENV_VAR];
  if (!token) {
    relayLog(`${TOKEN_ENV_VAR} が無い`);
    process.exit(64);
  }
  const port = Number.parseInt(env[PORT_ENV_VAR] ?? "", 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    relayLog(`${PORT_ENV_VAR} が無いか正しくない`);
    process.exit(64);
  }
  const transport = httpRelayTransport(port, token);
  // クライアントが先に消えたら、書けないので終わる。
  process.stdout.on("error", () => process.exit(0));
  const inFlight = new Set<Promise<void>>();
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity, terminal: false });
  // 要求は並べて送る（長い tools/call の間にも ping などへ答える）。JSON-RPC は id で対応するので順は問わない。
  rl.on("line", (line) => {
    const p = relayLine(line, transport, port)
      .then((reply) => {
        if (reply !== undefined) process.stdout.write(`${reply}\n`);
      })
      .catch(() => undefined)
      .finally(() => inFlight.delete(p));
    inFlight.add(p);
  });
  await new Promise<void>((resolve) => rl.once("close", () => resolve()));
  // stdin が閉じた = クライアントが終わった。送りかけの返事だけ少し待つ。
  await Promise.race([Promise.allSettled([...inFlight]), new Promise((r) => setTimeout(r, 5000).unref())]);
  process.exit(0);
}

// ---- ACP の McpServer（stdio） ----

let executableOverride: { command: string; args: string[] } | undefined;

/** テスト用: 中継として起こすコマンドを差し替える。 */
export function setRelayCommandOverride(cmd: { command: string; args: string[] } | undefined): void {
  executableOverride = cmd;
}

/**
 * この Bridge を中継として起こすコマンド（いま動いている node と入口のスクリプト）。開発時の tsx などの読み込みは
 * execArgv で引き継ぎ、--inspect は外す。入口が分からなければ undefined（stdio の中継は渡さない）。
 */
export function relayCommand(): { command: string; args: string[] } | undefined {
  if (executableOverride) return executableOverride;
  const entry = process.argv[1];
  if (!entry) return undefined;
  const execArgv = process.execArgv.filter((a) => !a.startsWith("--inspect") && !a.startsWith("--debug"));
  return { command: process.execPath, args: [...execArgv, entry, RELAY_SUBCOMMAND] };
}

/**
 * ACP の session/new・load の mcpServers の 1 件（stdio の形：name / command / args / env）。合鍵とポートは env に入れ、args には載せない。
 * WSL で動くエージェントには、WSL から Windows の node.exe を起こしてもらう（WSL の相互運用。127.0.0.1 は Windows 側になる）。
 * そのとき env を Windows 側へ引き継がせるため WSLENV に名前を足す（未確認。docs に書いた）。
 */
export function acpStdioRelayServer(token: string, port: number, cmd: { command: string; args: string[] }, kind: RuntimeKind = "native"): Record<string, unknown> {
  const env = [
    { name: TOKEN_ENV_VAR, value: token },
    { name: PORT_ENV_VAR, value: String(port) }
  ];
  if (kind === "wsl") env.push({ name: "WSLENV", value: `${TOKEN_ENV_VAR}:${PORT_ENV_VAR}` });
  return {
    name: MCP_SERVER_NAME,
    command: kind === "wsl" ? toWslPath(cmd.command) : cmd.command,
    args: cmd.args,
    env
  };
}
