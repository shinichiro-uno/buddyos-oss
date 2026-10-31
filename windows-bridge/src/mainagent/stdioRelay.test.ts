import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { acpMainAgentTransport } from "../agents/acpAdapter.js";
import { handleMcpRequest, mainAgentRouteDenial } from "./mcpEndpoint.js";
import { orchestrator } from "./orchestrator.js";
import { isRelayInvocation, oneLineJson, RELAY_UNAUTHORIZED_CODE, RELAY_UNREACHABLE_CODE, relayLine, type RelayTransport } from "./stdioRelay.js";

// stdio の MCP しか受け取れない ACP エージェント向けの中継（mac の McpStdioRelayTests の移植）。

const srcDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-relay-test-"));

/** 本物の /mcp（関門と合鍵の確かめを含む）だけを持つ小さなサーバ。 */
let server: http.Server;
let port = 0;

before(async () => {
  server = http.createServer((req, res) => {
    const url = new URL(req.url ?? "/", "http://127.0.0.1");
    const denial = mainAgentRouteDenial(req, url, { peers: { get: () => undefined } as never, listenPort: () => port });
    if (denial) {
      res.writeHead(denial.status);
      res.end(JSON.stringify({ error: denial.error }));
      return;
    }
    void handleMcpRequest(req, res, orchestrator);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  port = (server.address() as AddressInfo).port;
});

after(() => {
  server.closeAllConnections();
  server.close();
  fs.rmSync(tmp, { recursive: true, force: true });
});

function fake(status: number, body: string, seen?: string[]): RelayTransport {
  return async (b) => {
    seen?.push(b);
    return { status, body };
  };
}

test("1 行を Bridge へ送り、応答を 1 行で返す（複数行の本文は詰める）", async () => {
  const seen: string[] = [];
  const line = '{"jsonrpc":"2.0","id":7,"method":"tools/list"}';
  assert.equal(await relayLine(line, fake(200, '{"jsonrpc":"2.0","id":7,"result":{}}', seen), 1), '{"jsonrpc":"2.0","id":7,"result":{}}');
  assert.deepEqual(seen, [line]);
  const multi = await relayLine(line, fake(200, '{\n  "id": 7,\n  "result": {}\n}'), 1);
  assert.equal(multi, '{"id":7,"result":{}}');
  assert.equal(oneLineJson("not json"), undefined);
});

test("通知は送るが返さない・クライアントの応答と空行は送らない", async () => {
  const seen: string[] = [];
  assert.equal(await relayLine('{"jsonrpc":"2.0","method":"notifications/initialized"}', fake(202, "", seen), 1), undefined);
  assert.equal(seen.length, 1);
  assert.equal(await relayLine('{"jsonrpc":"2.0","id":1,"result":{}}', fake(200, "{}", seen), 1), undefined);
  assert.equal(await relayLine("   ", fake(200, "{}", seen), 1), undefined);
  assert.equal(seen.length, 1);
});

test("壊れた入力・401・繋がらない・HTTP エラーは、要求の id で JSON-RPC の error にする", async () => {
  assert.equal(JSON.parse((await relayLine("{nope", fake(200, "{}"), 1))!).error.code, -32700);
  assert.equal(JSON.parse((await relayLine("[1,2]", fake(200, "{}"), 1))!).error.code, -32600);
  const unauthorized = JSON.parse((await relayLine('{"jsonrpc":"2.0","id":"a","method":"ping"}', fake(401, ""), 1))!);
  assert.equal(unauthorized.id, "a");
  assert.equal(unauthorized.error.code, RELAY_UNAUTHORIZED_CODE);
  const down = JSON.parse((await relayLine('{"jsonrpc":"2.0","id":3,"method":"ping"}', async () => { throw new Error("ECONNREFUSED"); }, 1))!);
  assert.equal(down.error.code, RELAY_UNREACHABLE_CODE);
  assert.equal(JSON.parse((await relayLine('{"jsonrpc":"2.0","id":4,"method":"ping"}', fake(500, "x"), 1))!).error.code, RELAY_UNREACHABLE_CODE);
  assert.equal(JSON.parse((await relayLine('{"jsonrpc":"2.0","id":5,"method":"ping"}', fake(200, "<html>"), 1))!).error.code, -32603);
});

test("ACP: http を申告すれば /mcp を直接、しなければ stdio の中継。WSL は中継、中継が分からなければ渡さない", () => {
  const relay = { command: "node", args: ["bridge.cjs", "mcp-stdio-relay"] };
  const advertised = { agentCapabilities: { mcpCapabilities: { http: true } } };
  assert.equal(acpMainAgentTransport(advertised, "native", relay), "http");
  assert.deepEqual(acpMainAgentTransport({}, "native", relay), { stdio: relay });
  assert.deepEqual(acpMainAgentTransport(advertised, "wsl", relay), { stdio: relay });
  assert.equal(acpMainAgentTransport({}, "native", undefined), undefined);
  assert.ok(isRelayInvocation(["node", "bridge.cjs", "mcp-stdio-relay"]));
  assert.ok(!isRelayInvocation(["node", "bridge.cjs"]));
});

/** Bridge の入口（src/index.ts）を mcp-stdio-relay で起こす（本番の `node bridge.cjs mcp-stdio-relay` と同じ入口）。 */
function spawnRelay(env: NodeJS.ProcessEnv) {
  return spawn(process.execPath, ["--import", "tsx", path.join(srcDir, "index.ts"), "mcp-stdio-relay"], {
    cwd: path.dirname(srcDir),
    // 合鍵は env で渡す（引数には載せない）。設定フォルダに触らないことも見るため HOME / LOCALAPPDATA を空の場所に向ける。
    env: { PATH: process.env.PATH, HOME: tmp, USERPROFILE: tmp, LOCALAPPDATA: tmp, ...env },
    stdio: ["pipe", "pipe", "pipe"]
  });
}

test("入口を mcp-stdio-relay で起こすと、stdio を本物の /mcp へ中継し、stdin が閉じたら 0 で終わる", async () => {
  const token = orchestrator.issueToken("hermes", "parent-relay");
  const child = spawnRelay({ BUDDYOS_MCP_TOKEN: token, BUDDYOS_MCP_PORT: String(port) });
  let out = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (c: string) => (out += c));
  let err = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (c: string) => (err += c));
  child.stdin.write('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}\n');
  child.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
  child.stdin.write('{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n');
  for (let i = 0; i < 200 && out.split("\n").filter(Boolean).length < 2; i += 1) await new Promise((r) => setTimeout(r, 50));
  child.stdin.end();
  const code = await new Promise<number | null>((r) => child.once("exit", r));
  assert.equal(code, 0, err);
  const lines = out.split("\n").filter(Boolean).map((l) => JSON.parse(l) as { id: number; result: Record<string, unknown> });
  assert.equal(lines.length, 2, out);
  const byId = new Map(lines.map((l) => [l.id, l]));
  assert.equal((byId.get(1)?.result.serverInfo as { name: string }).name, "buddyos");
  assert.equal((byId.get(2)?.result.tools as unknown[]).length, 9, "7 つの道具と list_pcs・save_note");
  assert.ok(!err.includes(token), "合鍵をログに書かない");
  assert.ok(!fs.existsSync(path.join(tmp, ".buddyos-windows-bridge")), "設定フォルダに触らない");
  orchestrator.revoke(token);
});

test("無効な合鍵は -32001、合鍵かポートが無ければ 64 で終わる", async () => {
  const child = spawnRelay({ BUDDYOS_MCP_TOKEN: "bmt_nope", BUDDYOS_MCP_PORT: String(port) });
  let out = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (c: string) => (out += c));
  child.stdin.end('{"jsonrpc":"2.0","id":9,"method":"ping"}\n');
  await new Promise((r) => child.once("exit", r));
  assert.equal(JSON.parse(out.trim()).error.code, RELAY_UNAUTHORIZED_CODE);

  const noToken = spawnRelay({ BUDDYOS_MCP_PORT: String(port) });
  noToken.stdin.end();
  assert.equal(await new Promise((r) => noToken.once("exit", r)), 64);
  const noPort = spawnRelay({ BUDDYOS_MCP_TOKEN: "bmt_x" });
  noPort.stdin.end();
  assert.equal(await new Promise((r) => noPort.once("exit", r)), 64);
});
