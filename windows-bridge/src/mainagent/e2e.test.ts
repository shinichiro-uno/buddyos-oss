import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { WebSocket } from "ws";
import type { AgentAdapter, AgentSession } from "../agents/types.js";
import type { BridgeConfig } from "../config.js";
import { BridgeIdentity } from "../identity.js";
import { event, type SessionEvent } from "../protocol.js";
import { createBridgeServer, type BridgeServer } from "../server.js";
import { JsonSessionStore } from "../sessionStore.js";
import { setMainAgentConfigDir, setMainAgentRoot } from "./workspace.js";
import { setRelayCommandOverride } from "./stdioRelay.js";
import { HermesAcpAdapter } from "../agents/hermesAcp.js";
import { resolveRuntime } from "../runtime/command.js";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createRequire } from "node:module";

// 実 claude（haiku）を mainagent として起こし、/mcp の道具で子のセッションに頼んで返事を受け取るまでを通す E2E
// （mac の MainAgentE2ETests の移植）。claude の利用枠を少し使うので RUN_CLAUDE_E2E=1 のときだけ走らせる。
// Windows の Bridge のコードを、この PC（mac / Linux）の node でそのまま動かす。実ホームの ~/.claude を使う（ログイン済みであること）。
//
// 本番と同じく Bridge（HTTP の関門・/mcp・WS）を通し、mainagent のフォルダ（一時フォルダに差し替え）で開く。
// 送る・起こすの承認カードは Bridge が mainagent のチャットへ出し、iPhone と同じ action_response で許可する。子は台本の adapter。

const enabled = process.env.RUN_CLAUDE_E2E === "1";
const hermesEnabled = process.env.RUN_HERMES_E2E === "1";
const codexEnabled = process.env.RUN_CODEX_E2E === "1";
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-mainagent-e2e-"));
const API_KEY = "e2e-api-key";
const mainDir = path.join(tmp, "main");
const work = path.join(tmp, "project");
const child = `e2e-child-${crypto.randomUUID().slice(0, 6)}`;
const childSid = `child-${crypto.randomUUID().slice(0, 6)}`;
let bridge: BridgeServer | undefined;
let port = 0;

before(async () => {
  if (!enabled && !hermesEnabled && !codexEnabled) return;
  fs.mkdirSync(mainDir, { recursive: true });
  fs.mkdirSync(work, { recursive: true });
  const configDir = path.join(tmp, "config");
  const identity = BridgeIdentity.open(configDir, { env: { BUDDYOS_BRIDGE_API_KEY: API_KEY, BUDDYOS_BRIDGE_ID: "e2e" }, homeDir: tmp, log: () => {} });
  const config: BridgeConfig = {
    configDir,
    identity,
    bridgeId: "e2e",
    port: 0,
    paseoRelayURL: "wss://relay.example.com/ws",
    defaultCwd: tmp,
    hermesMode: "off",
    claudeMode: "native",
    codexMode: codexEnabled ? "native" : "off",
    openclawMode: "off",
    opencodeMode: "off",
    cursorMode: "off",
    grokMode: "off",
    antigravityMode: "off"
  };
  setMainAgentRoot(mainDir);
  setMainAgentConfigDir(configDir);
  bridge = createBridgeServer(config, new JsonSessionStore(configDir));
  const open = (sid: string | undefined): AgentSession => {
    let n = 0;
    const s: AgentSession = {
      sessionId: sid ?? `pending-${crypto.randomUUID().slice(0, 6)}`,
      async send(text, _e, emit) {
        n += 1;
        if (n === 1 && !sid) {
          s.sessionId = childSid;
          emit(event.sessionStarted(child, childSid));
        }
        emit(event.assistantDelta(child, childSid, `m${n}`, `echo: ${text}`));
        emit(event.done(child, childSid, `m${n}`));
      },
      async close() {}
    };
    return s;
  };
  const adapter: AgentAdapter = {
    id: child,
    displayName: "E2E child",
    runtimeLabel: "local:e2e",
    openSession: async (sid) => open(sid),
    listSessions: async () => [],
    loadHistory: async () => [],
    renameSession: async () => false,
    listCommands: async () => [],
    currentInfo: async () => undefined,
    setModel: async () => {},
    listAvailableModels: async () => []
  };
  bridge.adapters.set(child, adapter);
  await bridge.start();
  port = (bridge.server.address() as { port: number }).port;
});

after(() => {
  bridge?.server.closeAllConnections();
  bridge?.server.close();
  fs.rmSync(tmp, { recursive: true, force: true });
});

async function run(agentId: string, overrides: Record<string, string> = { chatOverrides: "1", chatModel: "haiku" }): Promise<void> {
  assert.ok(bridge?.adapters.get(agentId), `${agentId} が無い（claude CLI が見つからない？）`);
  const ws = new WebSocket(`ws://127.0.0.1:${port}/ws/agent/${agentId}?apiKey=${API_KEY}&cwd=${encodeURIComponent(mainDir)}`);
  const events: SessionEvent[] = [];
  ws.on("message", (raw) => events.push(JSON.parse(String(raw)) as SessionEvent));
  await new Promise<void>((r, j) => (ws.once("open", () => r()), ws.once("error", j)));
  const waitFor = async (pred: (e: SessionEvent) => boolean, ms: number): Promise<SessionEvent> => {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      const hit = events.find(pred);
      if (hit) return hit;
      await new Promise((r) => setTimeout(r, 200));
    }
    throw new Error(`待ちきれなかった。届いた種別: ${events.map((e) => e.type).join(",")} / error: ${events.filter((e) => e.type === "error").map((e) => e.content).join(" | ")} / 本文: ${events.filter((e) => e.type === "assistant_delta").map((e) => e.content).join("")}`);
  };
  const prompt = `Use the buddyos MCP tools. 1) Call start_session with agent "${child}", cwd "${work}", prompt "ping-42", wait_seconds 10. 2) Answer with only the reply text you got.`;
  ws.send(JSON.stringify({ type: "user_message", agentId, content: prompt, metadata: { clientMessageId: crypto.randomUUID(), cwd: mainDir, ...overrides } }));

  // start_session は Bridge が承認カードを出す（Claude 側の承認ではない）。iPhone と同じく許可して進める。
  const card = await waitFor((e) => e.type === "action_request", 180_000);
  assert.ok((card.metadata?.requestId ?? "").startsWith("mainagent-"), `Bridge のカード: ${JSON.stringify(card.metadata)}`);
  assert.ok((card.metadata?.subtitle ?? "").includes("ping-42"), "頼む文がカードに出る");
  ws.send(JSON.stringify({ type: "action_response", agentId, sessionId: card.sessionId, messageId: card.messageId, content: "allow", metadata: { requestId: card.messageId, decision: "allow" } }));

  await waitFor((e) => e.type === "done", 180_000);
  const text = events.filter((e) => e.type === "assistant_delta").map((e) => e.content ?? "").join("");
  assert.ok(text.includes("echo: ping-42"), `子の返事が mainagent まで届く: ${text}`);
  assert.equal(events.filter((e) => e.type === "action_request").length, 1, "承認は Bridge の 1 枚だけ");
  // 任せた子の進み具合が、mainagent のチャットにカード（workflow_progress kind = "sessions"）で届く。
  const sessionsCard = await waitFor(
    (e) => e.type === "workflow_progress" && (e.content ?? "").includes('"kind":"sessions"') && (e.content ?? "").includes('"status":"done"') && (e.content ?? "").includes(child),
    10_000
  );
  assert.ok((sessionsCard.content ?? "").includes("echo: ping-42"), sessionsCard.content);
  ws.close();
}

test("claude CLI の mainagent が /mcp で子に頼み、返事を受け取る（RUN_CLAUDE_E2E=1）", { skip: !enabled, timeout: 300_000 }, async () => {
  await run("claude");
});

// 実 hermes（stdio の MCP しか申告しない ACP エージェント）を mainagent のフォルダで開き、stdio の中継越しに list_agents を
// 呼ばせる（mac の testHermesMainagentUsesToolsThroughStdioRelay）。hermes の利用枠を少し使うので RUN_HERMES_E2E=1 のときだけ。
test("hermes（ACP）の mainagent が stdio の中継越しに道具を使う（RUN_HERMES_E2E=1）", { skip: !hermesEnabled, timeout: 300_000 }, async () => {
  const runtime = resolveRuntime("hermes", "native", process.env.HERMES_BIN);
  assert.ok(runtime, "hermes が見つからない");
  // 中継は本番と同じ入口（src/index.ts mcp-stdio-relay）。hermes は別の作業フォルダで起こすので、tsx は絶対パスで読ませる。
  const tsx = pathToFileURL(createRequire(import.meta.url).resolve("tsx")).href;
  const entry = path.join(path.dirname(path.dirname(fileURLToPath(import.meta.url))), "index.ts");
  setRelayCommandOverride({ command: process.execPath, args: ["--import", tsx, entry, "mcp-stdio-relay"] });
  // list_agents に出る目印（hermes が道具を呼ばなければ知りようがない名前）。
  const marker = `relayprobe${crypto.randomUUID().slice(0, 6)}`;
  bridge!.adapters.set(marker, { ...bridge!.adapters.get(child)!, id: marker, displayName: marker });
  const adapter = new HermesAcpAdapter("hermes", runtime, new JsonSessionStore(path.join(tmp, "hermes-store")));
  const session = await adapter.openSession(undefined, mainDir);
  const events: SessionEvent[] = [];
  await session.send(
    "Call the MCP tool list_agents of the buddyos server, then reply with only the agent ids it returned, comma separated.",
    { type: "user_message", agentId: "hermes", content: "" },
    (e) => events.push(e)
  );
  await session.close();
  setRelayCommandOverride(undefined);
  const text = events.filter((e) => e.type === "assistant_delta").map((e) => e.content ?? "").join("");
  assert.ok(text.includes(marker), `中継越しの list_agents の結果が返事に入る: ${text} / error: ${events.filter((e) => e.type === "error").map((e) => e.content).join(" | ")}`);
});

// 実 codex（app-server）を mainagent として起こす。thread/start の config で渡す mcp_servers.buddyos.*（http_headers /
// tool_timeout_sec / default_tools_approval_mode）が効くかを見る。codex の利用枠を使うので RUN_CODEX_E2E=1 のときだけ。
test("codex（app-server）の mainagent が /mcp で子に頼み、返事を受け取る（RUN_CODEX_E2E=1）", { skip: !codexEnabled, timeout: 300_000 }, async () => {
  await run("codex", {});
});
