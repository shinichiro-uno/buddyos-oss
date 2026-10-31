import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import { fileURLToPath } from "node:url";
import type { SessionEvent } from "../protocol.js";
import { CodexAppServerSession, CodexBackgroundWork, codexStopTiming } from "./codexAppServer.js";
import { isInjectedUserContext } from "./codexHistory.js";

/**
 * Codex の子 thread（サブエージェント）とバックグラウンドの端末を、サブエージェントのカードの行にする
 * （CodexAppServerSession / CodexBackgroundWork。docs/BACKGROUND_WORK_2026-10-21.md §3.6）。
 * セッションの試験は、codex 0.162.1 の app-server を実際に動かして記録した通知の行（PROBE。mac の CodexBackgroundWorkTests と同じ）を、
 * 偽の app-server（stdio）が自分の turn/start の応答の後にそのまま流す。phase ごとに区切り、次の phase は gate のファイルを
 * 置くまで流さない（親のターンが終わった後の、子や端末の終わりを後から届ける）。
 */

/**
 * codex 0.162.1 の app-server（stdio。CODEX_HOME を隔離し、モデルは 127.0.0.1 のモック）で記録した通知。
 * probe の wire.jsonl から account/rateLimits/updated と親の thread/started を除き、cwd を "/tmp/w" に縮めた。
 * - spawnV2: v2 の spawn。親は子を待たずに終わり（14）、子は 3 秒 sleep して 'child done'（22）、親に subAgentActivity completed（23・24）
 * - backgroundTerminal: メインのターンで unified exec の端末を起こし、閉じる前にターンが終わる（10）。5 秒後に exitCode 0（12）
 * - failedChild: 子が contextWindowExceeded で失敗（systemError → error → turn/completed failed）。親には何も来ない
 * - interruptedChild: 親が interrupt_agent で子を止める（subAgentActivity interrupted → 子の turn/completed interrupted）
 */
const PROBE = {
  spawnV2: [
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}},\"emittedAtMs\":1792507189253}",
    "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turn\":{\"id\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"rootTurnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"inProgress\",\"error\":null,\"startedAt\":1792507189,\"completedAt\":null,\"durationMs\":null}},\"emittedAtMs\":1792507189253}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"01a159c1-1806-78d0-bcff-37fc5075b438\",\"clientId\":null,\"content\":[{\"type\":\"text\",\"text\":\"PARENT_PROBE_PROMPT: spawn one sub-agent\",\"text_elements\":[]}]},\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"startedAtMs\":1792507189254},\"emittedAtMs\":1792507189254}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"01a159c1-1806-78d0-bcff-37fc5075b438\",\"clientId\":null,\"content\":[{\"type\":\"text\",\"text\":\"PARENT_PROBE_PROMPT: spawn one sub-agent\",\"text_elements\":[]}]},\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"completedAtMs\":1792507189254},\"emittedAtMs\":1792507189254}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":\"gpt-6-luna\",\"reasoningEffort\":\"medium\",\"id\":\"call_spawn_1\",\"kind\":\"started\",\"agentThreadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"startedAtMs\":1792507189482},\"emittedAtMs\":1792507189484}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":\"gpt-6-luna\",\"reasoningEffort\":\"medium\",\"id\":\"call_spawn_1\",\"kind\":\"started\",\"agentThreadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"completedAtMs\":1792507189483},\"emittedAtMs\":1792507189484}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507189484}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"tokenUsage\":{\"total\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507189484}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}},\"emittedAtMs\":1792507189487}",
    "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"turn\":{\"id\":\"01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"rootTurnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"inProgress\",\"error\":null,\"startedAt\":1792507189,\"completedAt\":null,\"durationMs\":null}},\"emittedAtMs\":1792507189487}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"startedAtMs\":1792507189703},\"emittedAtMs\":1792507189703}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"completedAtMs\":1792507189703},\"emittedAtMs\":1792507189703}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"tokenUsage\":{\"total\":{\"totalTokens\":30,\"inputTokens\":20,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":10,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507189703}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507189703}",
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turn\":{\"id\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"rootTurnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"items\":[{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null}],\"itemsView\":\"summary\",\"status\":\"completed\",\"error\":null,\"startedAt\":1792507189,\"completedAt\":1792507189,\"durationMs\":452}},\"emittedAtMs\":1792507189703}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"sleep\",\"id\":\"call_sleep_child_1\",\"durationMs\":3000},\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"turnId\":\"01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"startedAtMs\":1792507189704},\"emittedAtMs\":1792507189704}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"sleep\",\"id\":\"call_sleep_child_1\",\"durationMs\":3000},\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"turnId\":\"01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"completedAtMs\":1792507192708},\"emittedAtMs\":1792507192709}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"turnId\":\"01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"tokenUsage\":{\"total\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507192709}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_5\",\"text\":\"child done\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"turnId\":\"01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"startedAtMs\":1792507193723},\"emittedAtMs\":1792507193723}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_5\",\"text\":\"child done\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"turnId\":\"01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"completedAtMs\":1792507193723},\"emittedAtMs\":1792507193723}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"turnId\":\"01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"tokenUsage\":{\"total\":{\"totalTokens\":30,\"inputTokens\":20,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":10,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507193723}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507193724}",
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"turn\":{\"id\":\"01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"rootTurnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"items\":[{\"type\":\"agentMessage\",\"id\":\"msg_5\",\"text\":\"child done\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null}],\"itemsView\":\"summary\",\"status\":\"completed\",\"error\":null,\"startedAt\":1792507189,\"completedAt\":1792507193,\"durationMs\":4240}},\"emittedAtMs\":1792507193724}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":null,\"reasoningEffort\":null,\"id\":\"subagent-completed-01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"kind\":\"completed\",\"agentThreadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"startedAtMs\":1792507193724},\"emittedAtMs\":1792507193724}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":null,\"reasoningEffort\":null,\"id\":\"subagent-completed-01a159c1-18ea-7243-96ef-15a4a6c6880d\",\"kind\":\"completed\",\"agentThreadId\":\"01a159c1-18e7-75e2-b3f7-07bff18af412\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c1-17f0-7a03-b8bc-468dec521b66\",\"turnId\":\"01a159c1-1800-7383-a57b-c0adc1a48562\",\"completedAtMs\":1792507193724},\"emittedAtMs\":1792507193724}",
  ],
  backgroundTerminal: [
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}},\"emittedAtMs\":1792507417426}",
    "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turn\":{\"id\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"rootTurnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"inProgress\",\"error\":null,\"startedAt\":1792507417,\"completedAt\":null,\"durationMs\":null}},\"emittedAtMs\":1792507417426}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"01a159c4-9353-7e83-b27b-d7fabb3dd097\",\"clientId\":null,\"content\":[{\"type\":\"text\",\"text\":\"PARENT_PROBE_PROMPT: spawn one sub-agent\",\"text_elements\":[]}]},\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"startedAtMs\":1792507417427},\"emittedAtMs\":1792507417427}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"01a159c4-9353-7e83-b27b-d7fabb3dd097\",\"clientId\":null,\"content\":[{\"type\":\"text\",\"text\":\"PARENT_PROBE_PROMPT: spawn one sub-agent\",\"text_elements\":[]}]},\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"completedAtMs\":1792507417427},\"emittedAtMs\":1792507417427}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"commandExecution\",\"id\":\"exec-170d2c38-fc2a-457f-a102-478c88c4b5de\",\"pluginId\":null,\"scriptPath\":null,\"command\":\"/bin/zsh -lc 'sleep 6; echo bg-done'\",\"cwd\":\"/tmp/w\",\"processId\":\"4376\",\"source\":\"unifiedExecStartup\",\"status\":\"inProgress\",\"commandActions\":[{\"type\":\"unknown\",\"command\":\"sleep 6; echo bg-done\"}],\"aggregatedOutput\":null,\"exitCode\":null,\"durationMs\":null},\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"startedAtMs\":1792507417938},\"emittedAtMs\":1792507417940}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"tokenUsage\":{\"total\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507418445}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done, command left running\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"startedAtMs\":1792507418649},\"emittedAtMs\":1792507418649}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done, command left running\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"completedAtMs\":1792507418649},\"emittedAtMs\":1792507418649}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"tokenUsage\":{\"total\":{\"totalTokens\":30,\"inputTokens\":20,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":10,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507418649}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507418649}",
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turn\":{\"id\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"rootTurnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"items\":[{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done, command left running\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null}],\"itemsView\":\"summary\",\"status\":\"completed\",\"error\":null,\"startedAt\":1792507417,\"completedAt\":1792507418,\"durationMs\":1225}},\"emittedAtMs\":1792507418649}",
    "{\"method\":\"item/commandExecution/outputDelta\",\"params\":{\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"itemId\":\"exec-170d2c38-fc2a-457f-a102-478c88c4b5de\",\"delta\":\"bg-done\\n\"},\"emittedAtMs\":1792507423812}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"commandExecution\",\"id\":\"exec-170d2c38-fc2a-457f-a102-478c88c4b5de\",\"pluginId\":null,\"scriptPath\":null,\"command\":\"/bin/zsh -lc 'sleep 6; echo bg-done'\",\"cwd\":\"/tmp/w\",\"processId\":\"4376\",\"source\":\"unifiedExecStartup\",\"status\":\"completed\",\"commandActions\":[{\"type\":\"unknown\",\"command\":\"sleep 6; echo bg-done\"}],\"aggregatedOutput\":\"bg-done\\n\",\"exitCode\":0,\"durationMs\":5873},\"threadId\":\"01a159c4-9345-7d91-948e-aedd17cccfa0\",\"turnId\":\"01a159c4-934e-7b10-88c2-33df68b50555\",\"completedAtMs\":1792507423812},\"emittedAtMs\":1792507423812}",
  ],
  failedChild: [
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}},\"emittedAtMs\":1792507462667}",
    "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turn\":{\"id\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"rootTurnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"inProgress\",\"error\":null,\"startedAt\":1792507462,\"completedAt\":null,\"durationMs\":null}},\"emittedAtMs\":1792507462667}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"01a159c5-440c-7f20-832a-8dabbe4781df\",\"clientId\":null,\"content\":[{\"type\":\"text\",\"text\":\"PARENT_PROBE_PROMPT: spawn one sub-agent\",\"text_elements\":[]}]},\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"startedAtMs\":1792507462668},\"emittedAtMs\":1792507462669}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"01a159c5-440c-7f20-832a-8dabbe4781df\",\"clientId\":null,\"content\":[{\"type\":\"text\",\"text\":\"PARENT_PROBE_PROMPT: spawn one sub-agent\",\"text_elements\":[]}]},\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"completedAtMs\":1792507462668},\"emittedAtMs\":1792507462669}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":\"gpt-6-luna\",\"reasoningEffort\":\"medium\",\"id\":\"call_spawn_1\",\"kind\":\"started\",\"agentThreadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"startedAtMs\":1792507462886},\"emittedAtMs\":1792507462887}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":\"gpt-6-luna\",\"reasoningEffort\":\"medium\",\"id\":\"call_spawn_1\",\"kind\":\"started\",\"agentThreadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"completedAtMs\":1792507462886},\"emittedAtMs\":1792507462887}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507462887}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"tokenUsage\":{\"total\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507462887}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}},\"emittedAtMs\":1792507462890}",
    "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"turn\":{\"id\":\"01a159c5-44e6-7863-9029-c9586e1bb26c\",\"rootTurnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"inProgress\",\"error\":null,\"startedAt\":1792507462,\"completedAt\":null,\"durationMs\":null}},\"emittedAtMs\":1792507462890}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"turnId\":\"01a159c5-44e6-7863-9029-c9586e1bb26c\",\"tokenUsage\":{\"total\":{\"totalTokens\":258400,\"inputTokens\":0,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":0,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":258400,\"inputTokens\":0,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":0,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507462897}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"status\":{\"type\":\"systemError\"}},\"emittedAtMs\":1792507462897}",
    "{\"method\":\"error\",\"params\":{\"error\":{\"message\":\"Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying.\",\"codexErrorInfo\":\"contextWindowExceeded\",\"additionalDetails\":null,\"misalignment\":null},\"willRetry\":false,\"threadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"turnId\":\"01a159c5-44e6-7863-9029-c9586e1bb26c\"},\"emittedAtMs\":1792507462897}",
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"01a159c5-44e3-7e62-9923-d5b2e7abb41b\",\"turn\":{\"id\":\"01a159c5-44e6-7863-9029-c9586e1bb26c\",\"rootTurnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"failed\",\"error\":{\"message\":\"Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying.\",\"codexErrorInfo\":\"contextWindowExceeded\",\"additionalDetails\":null,\"misalignment\":null},\"startedAt\":1792507462,\"completedAt\":1792507462,\"durationMs\":9}},\"emittedAtMs\":1792507462897}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"startedAtMs\":1792507463106},\"emittedAtMs\":1792507463106}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"completedAtMs\":1792507463106},\"emittedAtMs\":1792507463106}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"tokenUsage\":{\"total\":{\"totalTokens\":30,\"inputTokens\":20,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":10,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507463106}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507463106}",
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"01a159c5-43ed-7501-b28f-2a40ebc72360\",\"turn\":{\"id\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"rootTurnId\":\"01a159c5-4404-7763-9777-a90be9c482a8\",\"items\":[{\"type\":\"agentMessage\",\"id\":\"msg_3\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null}],\"itemsView\":\"summary\",\"status\":\"completed\",\"error\":null,\"startedAt\":1792507462,\"completedAt\":1792507463,\"durationMs\":442}},\"emittedAtMs\":1792507463106}",
  ],
  interruptedChild: [
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}},\"emittedAtMs\":1792507479145}",
    "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turn\":{\"id\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"rootTurnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"inProgress\",\"error\":null,\"startedAt\":1792507479,\"completedAt\":null,\"durationMs\":null}},\"emittedAtMs\":1792507479145}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"01a159c5-846a-7141-9acf-e3bc3c2717e7\",\"clientId\":null,\"content\":[{\"type\":\"text\",\"text\":\"PARENT_PROBE_PROMPT: spawn one sub-agent\",\"text_elements\":[]}]},\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"startedAtMs\":1792507479146},\"emittedAtMs\":1792507479146}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"userMessage\",\"id\":\"01a159c5-846a-7141-9acf-e3bc3c2717e7\",\"clientId\":null,\"content\":[{\"type\":\"text\",\"text\":\"PARENT_PROBE_PROMPT: spawn one sub-agent\",\"text_elements\":[]}]},\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"completedAtMs\":1792507479146},\"emittedAtMs\":1792507479146}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507479362}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":\"gpt-6-luna\",\"reasoningEffort\":\"medium\",\"id\":\"call_spawn_1\",\"kind\":\"started\",\"agentThreadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"startedAtMs\":1792507479362},\"emittedAtMs\":1792507479362}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":\"gpt-6-luna\",\"reasoningEffort\":\"medium\",\"id\":\"call_spawn_1\",\"kind\":\"started\",\"agentThreadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"completedAtMs\":1792507479362},\"emittedAtMs\":1792507479362}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"tokenUsage\":{\"total\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507479362}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"status\":{\"type\":\"active\",\"activeFlags\":[]}},\"emittedAtMs\":1792507479362}",
    "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"turn\":{\"id\":\"01a159c5-8542-7360-9543-18dc43b5875b\",\"rootTurnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"inProgress\",\"error\":null,\"startedAt\":1792507479,\"completedAt\":null,\"durationMs\":null}},\"emittedAtMs\":1792507479362}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"sleep\",\"id\":\"call_sleep_child_1\",\"durationMs\":8000},\"threadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"turnId\":\"01a159c5-8542-7360-9543-18dc43b5875b\",\"startedAtMs\":1792507479574},\"emittedAtMs\":1792507479575}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"turnId\":\"01a159c5-8542-7360-9543-18dc43b5875b\",\"tokenUsage\":{\"total\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507480375}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":null,\"reasoningEffort\":null,\"id\":\"call_interrupt_1\",\"kind\":\"interrupted\",\"agentThreadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"startedAtMs\":1792507480374},\"emittedAtMs\":1792507480375}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"subAgentActivity\",\"model\":null,\"reasoningEffort\":null,\"id\":\"call_interrupt_1\",\"kind\":\"interrupted\",\"agentThreadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"agentPath\":\"/root/probe_child\"},\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"completedAtMs\":1792507480374},\"emittedAtMs\":1792507480375}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"tokenUsage\":{\"total\":{\"totalTokens\":30,\"inputTokens\":20,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":10,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507480375}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507480375}",
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"01a159c5-8541-7673-b8b7-0620fc133902\",\"turn\":{\"id\":\"01a159c5-8542-7360-9543-18dc43b5875b\",\"rootTurnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"items\":[],\"itemsView\":\"notLoaded\",\"status\":\"interrupted\",\"error\":null,\"startedAt\":1792507479,\"completedAt\":1792507480,\"durationMs\":1012}},\"emittedAtMs\":1792507480375}",
    "{\"method\":\"item/started\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_5\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"startedAtMs\":1792507480588},\"emittedAtMs\":1792507480588}",
    "{\"method\":\"item/completed\",\"params\":{\"item\":{\"type\":\"agentMessage\",\"id\":\"msg_5\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null},\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"completedAtMs\":1792507480588},\"emittedAtMs\":1792507480588}",
    "{\"method\":\"thread/tokenUsage/updated\",\"params\":{\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"tokenUsage\":{\"total\":{\"totalTokens\":45,\"inputTokens\":30,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":15,\"reasoningOutputTokens\":0},\"last\":{\"totalTokens\":15,\"inputTokens\":10,\"cachedInputTokens\":0,\"cacheWriteInputTokens\":0,\"outputTokens\":5,\"reasoningOutputTokens\":0},\"modelContextWindow\":258400}},\"emittedAtMs\":1792507480588}",
    "{\"method\":\"thread/status/changed\",\"params\":{\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"status\":{\"type\":\"idle\"}},\"emittedAtMs\":1792507480588}",
    "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"01a159c5-845d-7413-9bd6-4ec50887b9ab\",\"turn\":{\"id\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"rootTurnId\":\"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8\",\"items\":[{\"type\":\"agentMessage\",\"id\":\"msg_5\",\"text\":\"parent done without waiting\",\"phase\":null,\"memoryCitation\":null,\"delivery\":null,\"questions\":null}],\"itemsView\":\"summary\",\"status\":\"completed\",\"error\":null,\"startedAt\":1792507479,\"completedAt\":1792507480,\"durationMs\":1444}},\"emittedAtMs\":1792507480588}",
  ],
};

const IDS = {
  spawnV2Parent: "01a159c1-17f0-7a03-b8bc-468dec521b66",
  spawnV2Turn: "01a159c1-1800-7383-a57b-c0adc1a48562",
  spawnV2Child: "01a159c1-18e7-75e2-b3f7-07bff18af412",
  backgroundTerminalParent: "01a159c4-9345-7d91-948e-aedd17cccfa0",
  backgroundTerminalTurn: "01a159c4-934e-7b10-88c2-33df68b50555",
  backgroundTerminalItem: "exec-170d2c38-fc2a-457f-a102-478c88c4b5de",
  failedChildParent: "01a159c5-43ed-7501-b28f-2a40ebc72360",
  failedChildTurn: "01a159c5-4404-7763-9777-a90be9c482a8",
  failedChildThread: "01a159c5-44e3-7e62-9923-d5b2e7abb41b",
  interruptedChildParent: "01a159c5-845d-7413-9bd6-4ec50887b9ab",
  interruptedChildTurn: "01a159c5-8466-7ad0-bc3b-71c0c4cbefb8",
  interruptedChildThread: "01a159c5-8541-7673-b8b7-0620fc133902"
};

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-codex-bg-"));
after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

// 偽の codex app-server: initialize・thread/start・turn/start に答え、turn/start の応答の後に scenario の行を phase ごとに流す。
// "__EXIT__" の行で終了する（app-server が落ちた）。
const fake = path.join(tmp, "fake.mjs");
fs.writeFileSync(
  fake,
  `import fs from "node:fs"; import readline from "node:readline";
const scenario = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const rl = readline.createInterface({ input: process.stdin });
const send = (line) => process.stdout.write(line + "\\n");
const until = (file) => new Promise((resolve) => { const t = setInterval(() => { if (fs.existsSync(file)) { clearInterval(t); resolve(); } }, 10); });
rl.on("line", async (raw) => {
  const m = JSON.parse(raw);
  if (m.method === "initialize") send(JSON.stringify({ id: m.id, result: {} }));
  else if (m.method === "thread/start") send(JSON.stringify({ id: m.id, result: { thread: { id: scenario.thread } } }));
  else if (m.method === "turn/start") {
    send(JSON.stringify({ id: m.id, result: { turn: { id: scenario.turn } } }));
    for (let i = 0; i < scenario.phases.length; i += 1) {
      if (i > 0) await until(scenario.gate + "." + i);
      for (const line of scenario.phases[i]) {
        if (line === "__EXIT__") process.exit(1);
        send(line);
      }
    }
  }
});`
);

type Row = Record<string, unknown>;

interface Replay {
  session: CodexAppServerSession;
  events: SessionEvent[];
  /** phase（1 から）の行を流させる。 */
  open(phase: number): void;
}

let scenarios = 0;

/** 記録した通知を、自分の turn/start の応答の後に流す偽の app-server（stdio）で、1 ターン送る（親のターンの終わりまで待つ）。 */
async function replay(thread: string, turn: string, phases: string[][]): Promise<Replay> {
  scenarios += 1;
  const scenarioFile = path.join(tmp, `scenario-${scenarios}.json`);
  const gate = path.join(tmp, `gate-${scenarios}`);
  fs.writeFileSync(scenarioFile, JSON.stringify({ thread, turn, phases, gate }));
  const bin = process.platform === "win32" ? path.join(tmp, `codex-${scenarios}.cmd`) : path.join(tmp, `codex-${scenarios}`);
  fs.writeFileSync(
    bin,
    process.platform === "win32"
      ? `@"${process.execPath}" "${fake}" "${scenarioFile}" %*\r\n`
      : `#!/bin/sh\nexec "${process.execPath}" "${fake}" "${scenarioFile}" "$@"\n`,
    { mode: 0o755 }
  );
  const session = new CodexAppServerSession("codex", undefined, tmp, { kind: "native", executable: bin, label: `native:${bin}`, shell: false }, async () => ({
    approvalPolicy: "on-request",
    sandboxMode: "workspace-write"
  }));
  const events: SessionEvent[] = [];
  let timer: NodeJS.Timeout | undefined;
  try {
    await Promise.race([
      session.send("PARENT_PROBE_PROMPT: spawn one sub-agent", { type: "user_message", content: "PARENT_PROBE_PROMPT: spawn one sub-agent" }, (e) => events.push(e)),
      new Promise((_, reject) => (timer = setTimeout(() => reject(new Error("send が終わらない")), 10_000)))
    ]);
  } catch (error) {
    await session.close();
    throw error;
  } finally {
    clearTimeout(timer);
  }
  return { session, events, open: (phase) => fs.writeFileSync(`${gate}.${phase}`, "") };
}

async function until(cond: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 250 && !cond(); i += 1) await new Promise((r) => setTimeout(r, 20));
  assert.ok(cond(), label);
}

const rowsOf = (payload: string | undefined): Row[] => (payload ? ((JSON.parse(payload) as { agents?: Row[] }).agents ?? []) : []);

/** 流れた workflow_progress の行を、届いた順に全部。 */
const progressRows = (events: SessionEvent[]): Row[] => events.filter((e) => e.type === "workflow_progress").flatMap((e) => rowsOf(e.content));
/** id の行の、最後に届いた形。 */
const last = (id: string, events: SessionEvent[]): Row | undefined => progressRows(events).filter((r) => r.id === id).at(-1);
/** id の行の state の移り変わり。 */
const states = (id: string, events: SessionEvent[]): unknown[] => progressRows(events).filter((r) => r.id === id).map((r) => r.state);
const dones = (events: SessionEvent[]): SessionEvent[] => events.filter((e) => e.type === "done");
const obj = (json: string): Record<string, unknown> => JSON.parse(json) as Record<string, unknown>;

// ---- 記録した通知（セッション） ----

test("cx-run3: v2 の子は親のターンより長く動き、子の turn/completed で結果付きの done になる", async () => {
  const lines = PROBE.spawnV2;
  const r = await replay(IDS.spawnV2Parent, IDS.spawnV2Turn, [lines.slice(0, 15), lines.slice(15)]);
  try {
    const child = IDS.spawnV2Child;
    // 親のターンが終わった時点では、子はまだ動いている（stdio の app-server も止めない）。
    const mid = r.session.subagentSnapshot();
    assert.equal(obj(mid!).subtype, "workflow_snapshot");
    assert.deepEqual(rowsOf(mid).map((row) => row.state), ["running"]);
    assert.equal(dones(r.events).length, 1);
    assert.equal(dones(r.events)[0].metadata?.origin, undefined, "自分の送信のターンは知らせのターンではない");

    r.open(1);
    await until(() => last(child, r.events)?.state === "done", "子の turn/completed で done になる");
    const first = progressRows(r.events).find((row) => row.id === child)!;
    assert.equal(first.state, "running");
    assert.equal(first.model, "gpt-6-luna (medium)");
    const row = last(child, r.events)!;
    assert.equal(row.result, "child done");
    assert.equal(row.resultPreview, "child done");
    assert.equal(row.agentType, "probe_child");
    assert.equal(row.label, "probe_child");
    assert.equal(row.labelIsFallback, true);
    assert.equal(row.model, "gpt-6-luna (medium)");
    assert.equal(row.rowKind, "agent");
    assert.equal(row.tokens, 30);
    assert.equal(typeof row.endedAtMs, "number");
    assert.ok(!states(child, r.events).includes("failed"));
    // 後から親に届く subAgentActivity completed では変わらない。done も増えない。
    assert.equal(dones(r.events).length, 1);
  } finally {
    await r.session.close();
  }
});

test("cx-run5: ターンより長く動く端末は shell の行（exec）になって done より先に流れ、exitCode 0 で done", async () => {
  const lines = PROBE.backgroundTerminal;
  const r = await replay(IDS.backgroundTerminalParent, IDS.backgroundTerminalTurn, [lines.slice(0, 11), lines.slice(11)]);
  try {
    const exec = IDS.backgroundTerminalItem;
    const first = progressRows(r.events).find((row) => row.id === exec);
    assert.ok(first, "親の turn/completed で shell の行になる");
    assert.equal(first.rowKind, "shell");
    assert.equal(first.tool, "exec");
    assert.equal(first.command, "sleep 6; echo bg-done");
    assert.equal(first.label, "sleep 6; echo bg-done");
    assert.equal(first.background, true);
    assert.equal(first.state, "running");
    const rowIndex = r.events.findIndex((e) => e.type === "workflow_progress" && rowsOf(e.content).some((row) => row.id === exec));
    const doneIndex = r.events.findIndex((e) => e.type === "done");
    assert.ok(rowIndex >= 0 && rowIndex < doneIndex, "shell の行は親のターンの done より先に流れる");

    r.open(1);
    await until(() => last(exec, r.events)?.state === "done", "item/completed の exitCode 0 で done");
    assert.equal(last(exec, r.events)?.result, "bg-done");
    // ツール行の終わりも今までどおり流れる。
    assert.ok(r.events.some((e) => e.type === "tool_end" && e.toolUseId === exec && e.metadata?.status === "completed"));
  } finally {
    await r.session.close();
  }
});

test("cx-run6: 子の失敗（systemError → error → turn/completed failed）は failed で、error の文を結果にする", async () => {
  const r = await replay(IDS.failedChildParent, IDS.failedChildTurn, [PROBE.failedChild]);
  try {
    const child = IDS.failedChildThread;
    const message = "Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying.";
    const row = last(child, r.events)!;
    assert.equal(row.state, "failed");
    assert.equal(row.result, message);
    assert.equal(row.resultPreview, message);
    assert.ok(!states(child, r.events).includes("done"));
    // 子の失敗はセッションのエラーにしない（親のターンは成功している）。
    assert.equal(r.events.filter((e) => e.type === "error").length, 0);
  } finally {
    await r.session.close();
  }
});

test("cx-run7: interrupt_agent で止めた子は stopped で、後から届く turn/completed(interrupted) で done にならない", async () => {
  const r = await replay(IDS.interruptedChildParent, IDS.interruptedChildTurn, [PROBE.interruptedChild]);
  try {
    const child = IDS.interruptedChildThread;
    assert.equal(states(child, r.events).at(-1), "stopped");
    assert.ok(!states(child, r.events).includes("done"));
    assert.ok(!states(child, r.events).includes("failed"));
    assert.equal(last(child, r.events)?.result, undefined);
  } finally {
    await r.session.close();
  }
});

test("自分が始めておらず発話も無いターンは知らせのターン（done に origin）。差し込まれた知らせは発話として出さない", async () => {
  const t = "thread-P";
  const line = (m: Record<string, unknown>): string => JSON.stringify(m);
  const turn = (id: string, phase: "started" | "completed"): string =>
    line({ method: `turn/${phase}`, params: { threadId: t, turn: { id, items: [], status: phase === "started" ? "inProgress" : "completed", error: null } } });
  const user = (turnId: string, text: string): string =>
    line({ method: "item/started", params: { threadId: t, turnId, item: { type: "userMessage", id: `u-${turnId}`, clientId: null, content: [{ type: "text", text, text_elements: [] }] } } });
  const answer = (turnId: string, itemId: string, text: string): string[] => [
    line({ method: "item/agentMessage/delta", params: { threadId: t, turnId, itemId, delta: text } }),
    line({ method: "item/completed", params: { threadId: t, turnId, item: { type: "agentMessage", id: itemId, text } } })
  ];
  const r = await replay(t, "turn-1", [
    [turn("turn-1", "started"), ...answer("turn-1", "msg_1", "起動しました"), turn("turn-1", "completed")],
    // 子の完了で親が自分から起きたターン（発話は差し込まれた知らせだけ）。
    [
      turn("turn-N", "started"),
      user("turn-N", '<subagent_notification>{"agent_path":"/root/worker","status":"completed"}</subagent_notification>'),
      ...answer("turn-N", "msg_N", "子の報告です"),
      turn("turn-N", "completed")
    ],
    // ターミナルの発話が画像だけ（本文は画像の囲みだけ）でも発話として数える。
    [turn("turn-I", "started"), user("turn-I", '<image name=[Image #1] path="/tmp/a.png">\n</image>'), turn("turn-I", "completed")],
    // ターミナルの発話で始まったターン。発話を流す。
    [turn("turn-T", "started"), user("turn-T", "ターミナルから"), ...answer("turn-T", "msg_T", "はい"), turn("turn-T", "completed")]
  ]);
  try {
    r.open(1);
    await until(() => dones(r.events).length === 2, "知らせのターンの done");
    const notification = dones(r.events)[1];
    assert.equal(notification.metadata?.origin, "task-notification");
    assert.equal(notification.messageId, "msg_N");
    assert.ok(r.events.some((e) => e.type === "assistant_delta" && e.content === "子の報告です"), "知らせのターンの本文を流す");
    r.open(2);
    await until(() => dones(r.events).length === 3, "画像だけの発話のターンの done");
    assert.equal(dones(r.events)[2].metadata?.origin, undefined);
    r.open(3);
    await until(() => dones(r.events).length === 4, "ターミナルの発話のターンの done");
    assert.equal(dones(r.events)[3].metadata?.origin, undefined);
    assert.deepEqual(
      r.events.filter((e) => e.type === "user_message").map((e) => e.content),
      ["ターミナルから"],
      "差し込まれた知らせと画像の囲みは発話として出さない"
    );
  } finally {
    await r.session.close();
  }
});

test("close は実行中の行を stopped で閉じる。スナップショットは全行の置き換え（epoch 付き）", async () => {
  const lines = PROBE.spawnV2;
  const r = await replay(IDS.spawnV2Parent, IDS.spawnV2Turn, [lines.slice(0, 15), lines.slice(15)]);
  const snapshot = r.session.subagentSnapshot();
  const snap = obj(snapshot!);
  assert.equal(snap.subtype, "workflow_snapshot");
  assert.equal(snap.kind, "subagents");
  assert.equal(snap.taskId, "subagents");
  const epoch = snap.epoch;
  assert.equal(typeof epoch, "string");
  assert.ok((epoch as string).length > 0);
  assert.equal(rowsOf(snapshot)[0]?.state, "running");
  await r.session.close();
  assert.equal(last(IDS.spawnV2Child, r.events)?.state, "stopped");
  const progress = r.events.find((e) => e.type === "workflow_progress")!;
  assert.equal(obj(progress.content!).epoch, epoch, "行の payload とスナップショットは同じ世代");
  assert.equal(rowsOf(r.session.subagentSnapshot())[0]?.state, "stopped");
});

test("app-server が落ちたら、実行中の行を failed で閉じる", async () => {
  const lines = PROBE.spawnV2;
  const r = await replay(IDS.spawnV2Parent, IDS.spawnV2Turn, [lines.slice(0, 15), ["__EXIT__"]]);
  try {
    r.open(1);
    await until(() => last(IDS.spawnV2Child, r.events)?.state === "failed", "落ちたら failed で閉じる");
    // 送信の待ちは終わっているので、エラーも done も足さない。
    assert.equal(r.events.filter((e) => e.type === "error").length, 0);
    assert.equal(dones(r.events).length, 1);
  } finally {
    await r.session.close();
  }
});

test("行が無くてもスナップショットは agents: [] で返す（アプリが持っている幽霊行を消せるように）", async () => {
  const session = new CodexAppServerSession("codex", undefined, tmp, { kind: "native", executable: "codex", label: "native:codex", shell: false }, async () => ({
    approvalPolicy: "on-request",
    sandboxMode: "workspace-write"
  }));
  const snap = obj(session.subagentSnapshot()!);
  assert.equal(snap.subtype, "workflow_snapshot");
  assert.deepEqual(snap.agents, []);
  await session.close();
});

// ---- CodexBackgroundWork ----

const startedC1 = obj('{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"high","id":"call_1","kind":"started","agentThreadId":"C1","agentPath":"/root/worker"}');
const interactedC1 = obj('{"type":"subAgentActivity","model":null,"reasoningEffort":null,"id":"call_2","kind":"interacted","agentThreadId":"C1","agentPath":"/root/worker"}');
const execStarted = obj(
  `{"type":"commandExecution","id":"exec-1","command":"/bin/zsh -lc 'npm run dev'","processId":"77","source":"unifiedExecStartup","status":"inProgress","commandActions":[{"type":"unknown","command":"npm run dev"}],"aggregatedOutput":null,"exitCode":null,"durationMs":null}`
);
const lastRow = (payloads: string[]): Row | undefined => rowsOf(payloads.at(-1))[0];
const byId = (w: CodexBackgroundWork): Record<string, Row> => Object.fromEntries(rowsOf(w.tracker.snapshot()).map((row) => [String(row.id), row]));

test("interacted は作業の文だけ変え、終わった行を実行中に戻さない（戻すのは子の turn/started）", () => {
  const w = new CodexBackgroundWork();
  assert.equal(lastRow(w.ownItemStarted(startedC1))?.state, "running");
  const running = lastRow(w.ownItemCompleted(interactedC1));
  assert.equal(running?.state, "running");
  assert.equal(running?.resultPreview, CodexBackgroundWork.interactedActivity);

  w.childNotification(
    "turn/completed",
    obj('{"threadId":"C1","turn":{"id":"t1","items":[{"type":"agentMessage","id":"m","text":"finished"}],"status":"completed","error":null}}'),
    "C1"
  );
  assert.deepEqual(w.ownItemCompleted(interactedC1), [], "send_message では子のターンは起きない");
  assert.equal(byId(w).C1.state, "done");
  assert.equal(byId(w).C1.result, "finished");
  const reopened = w.childNotification("turn/started", obj('{"threadId":"C1","turn":{"id":"t2","status":"inProgress"}}'), "C1");
  assert.equal(lastRow(reopened)?.state, "running");
});

test("後から届く completed は failed / stopped の行を上書きしない", () => {
  const w = new CodexBackgroundWork();
  w.ownItemStarted(obj('{"type":"subAgentActivity","id":"s1","kind":"started","agentThreadId":"C1","agentPath":"/root/a"}'));
  w.ownItemStarted(obj('{"type":"subAgentActivity","id":"s2","kind":"started","agentThreadId":"C2","agentPath":"/root/b"}'));
  w.childNotification("thread/status/changed", obj('{"threadId":"C1","status":{"type":"systemError"}}'), "C1");
  w.ownItemCompleted(obj('{"type":"subAgentActivity","id":"i2","kind":"interrupted","agentThreadId":"C2","agentPath":"/root/b"}'));
  assert.deepEqual(w.ownItemCompleted(obj('{"type":"subAgentActivity","id":"c1","kind":"completed","agentThreadId":"C1","agentPath":"/root/a"}')), []);
  assert.deepEqual(w.ownItemCompleted(obj('{"type":"subAgentActivity","id":"c2","kind":"completed","agentThreadId":"C2","agentPath":"/root/b"}')), []);
  assert.deepEqual(w.childNotification("turn/completed", obj('{"threadId":"C2","turn":{"id":"t","items":[],"status":"completed","error":null}}'), "C2"), []);
  assert.equal(byId(w).C1.state, "failed");
  assert.equal(byId(w).C2.state, "stopped");
});

test("子の turn/completed は interrupted → stopped、failed → failed（turn.error を結果に）、completed → done（最後の発言を結果に）", () => {
  const w = new CodexBackgroundWork();
  for (const tid of ["C1", "C2", "C3"]) {
    w.ownItemStarted(obj(`{"type":"subAgentActivity","id":"s-${tid}","kind":"started","agentThreadId":"${tid}","agentPath":"/root/${tid}"}`));
  }
  w.childNotification("item/completed", obj('{"threadId":"C3","item":{"type":"agentMessage","id":"m3","text":"all good"}}'), "C3");
  w.childNotification("turn/completed", obj('{"threadId":"C1","turn":{"id":"t1","items":[],"status":"interrupted","error":null}}'), "C1");
  w.childNotification("turn/completed", obj('{"threadId":"C2","turn":{"id":"t2","items":[],"status":"failed","error":{"message":"usage limit"}}}'), "C2");
  w.childNotification("turn/completed", obj('{"threadId":"C3","turn":{"id":"t3","items":[],"status":"completed","error":null}}'), "C3");
  const rows = byId(w);
  assert.equal(rows.C1.state, "stopped");
  assert.equal(rows.C1.result, undefined);
  assert.equal(rows.C2.state, "failed");
  assert.equal(rows.C2.result, "usage limit");
  assert.equal(rows.C3.state, "done");
  assert.equal(rows.C3.result, "all good", "turn.items に無ければ、子の最後の発言");
});

test("v1（collabAgentToolCall）の agentsStates: completed / shutdown → done、interrupted → stopped、errored → failed", () => {
  const w = new CodexBackgroundWork();
  const spawn = obj(
    '{"type":"collabAgentToolCall","id":"call_s","tool":"spawnAgent","status":"completed","receiverThreadIds":["C1","C2","C3"],"prompt":"audit auth","model":"gpt-5.6-luna","agentsStates":{}}'
  );
  assert.equal(w.ownItemCompleted(spawn).length, 3);
  w.ownItemCompleted(
    obj(
      '{"type":"collabAgentToolCall","id":"call_w","tool":"wait","status":"completed","receiverThreadIds":[],"agentsStates":{"C1":{"status":"completed","message":"ok"},"C2":{"status":"interrupted","message":null},"C3":{"status":"errored","message":"boom"}}}'
    )
  );
  const rows = byId(w);
  assert.equal(rows.C1.state, "done");
  assert.equal(rows.C1.result, "ok");
  assert.equal(rows.C1.label, "audit auth");
  assert.equal(rows.C1.model, "gpt-5.6-luna");
  assert.equal(rows.C2.state, "stopped");
  assert.equal(rows.C3.state, "failed");
  assert.equal(rows.C3.result, "boom");
});

test("子の error（willRetry=true）は失敗にせず、いまの作業として見せる。知らない thread は捨てる", () => {
  const w = new CodexBackgroundWork();
  w.ownItemStarted(startedC1);
  const retry = lastRow(
    w.childNotification("error", obj('{"error":{"message":"Reconnecting... 1/5","codexErrorInfo":null},"willRetry":true,"threadId":"C1","turnId":"t"}'), "C1")
  );
  assert.equal(retry?.state, "running");
  assert.equal(retry?.resultPreview, "Reconnecting... 1/5");
  assert.deepEqual(w.childNotification("turn/started", {}, "unknown"), []);
});

test("ターンの中で閉じた端末と、processId の無いコマンドは行にしない", () => {
  const w = new CodexBackgroundWork();
  assert.deepEqual(w.ownItemStarted(execStarted), []);
  assert.deepEqual(
    w.ownItemCompleted(obj('{"type":"commandExecution","id":"exec-1","processId":"77","status":"completed","commandActions":[],"aggregatedOutput":"ok\\n","exitCode":0}')),
    []
  );
  assert.deepEqual(w.ownTurnCompleted(), []);
  w.ownItemStarted(obj('{"type":"commandExecution","id":"exec-2","command":"sleep 1","processId":null,"source":"agent","status":"inProgress","commandActions":[]}'));
  assert.deepEqual(w.ownTurnCompleted(), []);
  assert.equal(w.tracker.isEmpty, true);
});

test("裏の端末が 0 以外で終わったら failed（結果は出力の終わり）。行は 1 度だけ作る", () => {
  const w = new CodexBackgroundWork();
  w.ownItemStarted(execStarted);
  assert.equal(w.ownTurnCompleted().length, 1);
  assert.deepEqual(w.ownTurnCompleted(), [], "次のターンの終わりで作り直さない");
  assert.equal(w.tracker.runningShellCount, 1);
  const closed = lastRow(
    w.ownItemCompleted(
      obj(
        '{"type":"commandExecution","id":"exec-1","processId":"77","status":"failed","commandActions":[{"type":"unknown","command":"npm run dev"}],"aggregatedOutput":"Error: port 3000 is in use\\n","exitCode":1}'
      )
    )
  );
  assert.equal(closed?.state, "failed");
  assert.equal(closed?.result, "Error: port 3000 is in use");
  assert.equal(closed?.command, "npm run dev");
});

test("異常終了は動いている行（サブエージェントもシェルも）を failed で閉じる。閉じた後は何もしない", () => {
  const w = new CodexBackgroundWork();
  w.ownItemStarted(startedC1);
  w.ownItemStarted(execStarted);
  w.ownTurnCompleted();
  assert.equal(w.tracker.runningAgentCount, 1);
  assert.equal(w.tracker.runningShellCount, 1);
  const closed = rowsOf(w.abandonRunning("failed"));
  assert.equal(closed.length, 2);
  assert.ok(closed.every((row) => row.state === "failed"));
  assert.equal(w.tracker.hasRunning, false);
  assert.equal(w.abandonRunning("stopped"), undefined);
});

test("CodexBackgroundWork の小さな関数", () => {
  assert.equal(CodexBackgroundWork.modelLabel("gpt-6-luna", "medium"), "gpt-6-luna (medium)");
  assert.equal(CodexBackgroundWork.modelLabel("gpt-6-luna", undefined), "gpt-6-luna");
  assert.equal(CodexBackgroundWork.modelLabel(undefined, "high"), undefined);
  assert.equal(CodexBackgroundWork.execCommand(execStarted), "npm run dev");
  assert.equal(CodexBackgroundWork.execCommand(obj('{"command":"/bin/zsh -lc ls","commandActions":[]}')), "/bin/zsh -lc ls");
  assert.equal(CodexBackgroundWork.execCommand(obj('{"command":["rg","foo"]}')), "rg foo");
  assert.equal(CodexBackgroundWork.execState(obj('{"status":"completed","exitCode":0}')), "done");
  assert.equal(CodexBackgroundWork.execState(obj('{"status":"failed","exitCode":143}')), "failed");
  assert.equal(CodexBackgroundWork.execState(obj('{"status":"declined","exitCode":null}')), "failed");
  assert.equal(CodexBackgroundWork.execState(obj('{"status":"completed","exitCode":null}')), "done");
  const long = Array.from({ length: 600 }, (_, i) => `line ${i + 1}`).join("\n");
  const tail = CodexBackgroundWork.outputTail(long)!;
  assert.ok(tail.startsWith("…"));
  assert.ok(tail.endsWith("line 600"));
  assert.ok(Array.from(tail).length <= 2000);
  assert.equal(CodexBackgroundWork.outputTail("  \n"), undefined);
});

test("サブエージェントの完了の知らせ（<subagent_notification>）は、ユーザーの発話として出さない（履歴・ターミナルのターン）", () => {
  assert.equal(isInjectedUserContext('<subagent_notification>\n{"agent_path":"/root/a","status":"completed"}\n</subagent_notification>'), true);
  assert.equal(isInjectedUserContext("subagent_notification とは何？"), false);
});

test("終わって行を捨てた子が、後のターンの followup_task で起こされても行が戻る（isChildThread は捨てた子も知っている）", () => {
  const w = new CodexBackgroundWork();
  w.ownItemStarted(startedC1);
  w.childNotification("turn/completed", obj('{"threadId":"C1","turn":{"id":"t1","items":[{"type":"agentMessage","id":"m","text":"first"}],"status":"completed","error":null}}'), "C1");
  w.pruneFinished();
  assert.deepEqual(rowsOf(w.tracker.snapshot({ includeEmpty: true })), [], "捨てた");
  assert.equal(w.isChildThread("C1"), true, "捨てた子の通知も門を通す（承認要求も捨てない）");
  assert.equal(w.isChildThread("ZZ"), false, "知らない thread は捨てる");
  // interacted は send_message でも来て子を起こさないので、行にしない。
  assert.deepEqual(w.ownItemCompleted(interactedC1), []);
  assert.deepEqual(w.childNotification("item/completed", obj('{"threadId":"C1","item":{"type":"agentMessage","id":"m2","text":"x"}}'), "C1"), [], "turn/started より前の通知は捨てる");
  const reopened = w.childNotification("turn/started", obj('{"threadId":"C1","turn":{"id":"t2","status":"inProgress"}}'), "C1");
  assert.equal(lastRow(reopened)?.state, "running");
  assert.equal(lastRow(reopened)?.agentType, "worker", "種類は覚えておく");
  w.childNotification("turn/completed", obj('{"threadId":"C1","turn":{"id":"t2","items":[{"type":"agentMessage","id":"m3","text":"second"}],"status":"completed","error":null}}'), "C1");
  assert.equal(byId(w).C1.state, "done");
  assert.equal(byId(w).C1.result, "second");
  // 異常終了・close で忘れる（もう子はいない）。
  w.pruneFinished();
  w.abandonRunning("stopped");
  assert.equal(w.isChildThread("C1"), false);
});

test("バックグラウンドの端末の開始時刻は params.startedAtMs（item の外）を使う", () => {
  const w = new CodexBackgroundWork();
  w.ownItemStarted(execStarted, 1792507417938);
  const rows = rowsOf(w.ownTurnCompleted().at(-1));
  assert.equal(rows[0].startedAtMs, 1792507417938);
});

// ---- 停止（shared/fixtures/background-control/codex-stop。BACKGROUND_CONTROL §3.5・§4.4） ----

const stopFixtureDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "shared", "fixtures", "background-control", "codex-stop");

interface FixtureRecord {
  i: number;
  dir: string;
  msg: Record<string, unknown>;
}

interface FixtureReply {
  result?: unknown;
  error?: unknown;
  /** 返事の後に流れた通知（次の要求まで）。 */
  after: string[];
}

interface StopScenario {
  thread: string;
  turn: string;
  /** turn/start の応答の後、すぐ流す通知。 */
  phase0: string[];
  /** 要求の method ごとの、記録した返事（順に消費する）。 */
  replies: Record<string, FixtureReply[]>;
}

/**
 * 記録（Mac が codex 0.162.1 で取ったもの）から偽の app-server の台本を作る。phase0 = turn/start の応答から stopAt の通知まで。
 * 返事 = 記録した要求ごとの応答と、その後（次の要求まで。afterAll なら最後まで）に届いた通知。
 */
function stopScenario(name: string, opts: { stopAt: "firstParentCompleted" | number; afterAll?: boolean }): StopScenario {
  const records = fs
    .readFileSync(path.join(stopFixtureDir, `${name}.jsonl`), "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l) as FixtureRecord);
  const startReq = records.find((r) => r.dir === "out" && r.msg.method === "turn/start")!;
  const thread = String((startReq.msg.params as Record<string, unknown>).threadId);
  const startRes = records.find((r) => r.dir === "in" && r.msg.id === startReq.msg.id && r.msg.result)!;
  const turn = String(((startRes.msg.result as Record<string, unknown>).turn as Record<string, unknown>).id);
  const notif = (r: FixtureRecord): boolean => r.dir === "in" && r.msg.method !== undefined && r.msg.id === undefined;
  const stopAt =
    opts.stopAt === "firstParentCompleted"
      ? records.find((r) => notif(r) && r.msg.method === "turn/completed" && (r.msg.params as Record<string, unknown>).threadId === thread)!.i
      : opts.stopAt;
  const phase0 = records.filter((r) => notif(r) && r.i > startRes.i && r.i <= stopAt).map((r) => JSON.stringify(r.msg));
  const replies: Record<string, FixtureReply[]> = {};
  for (const req of records.filter((r) => r.dir === "out" && typeof r.msg.method === "string" && r.msg.id !== undefined && r.i > stopAt)) {
    const res = records.find((r) => r.dir === "in" && r.msg.id === req.msg.id && r.i > req.i);
    if (!res) continue; // 返事が来なかった記録（二重の interrupt）
    const next = records.find((r) => r.dir === "out" && r.i > res.i);
    const after = records.filter((r) => notif(r) && r.i > res.i && (opts.afterAll || next === undefined || r.i < next.i)).map((r) => JSON.stringify(r.msg));
    (replies[String(req.msg.method)] ??= []).push({ result: res.msg.result, error: res.msg.error, after });
  }
  return { thread, turn, phase0, replies };
}

// 台本の返事を順に返す偽の app-server。受けた要求は log のファイルに 1 行ずつ残す。返事が無い要求には答えない。
const fakeStop = path.join(tmp, "fake-stop.mjs");
fs.writeFileSync(
  fakeStop,
  `import fs from "node:fs"; import readline from "node:readline";
const scenario = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const rl = readline.createInterface({ input: process.stdin });
const send = (line) => process.stdout.write(line + "\\n");
rl.on("line", (raw) => {
  const m = JSON.parse(raw);
  if (m.method === "initialize") return send(JSON.stringify({ id: m.id, result: {} }));
  if (m.method === "thread/start") return send(JSON.stringify({ id: m.id, result: { thread: { id: scenario.thread } } }));
  if (m.method === "turn/start") {
    send(JSON.stringify({ id: m.id, result: { turn: { id: scenario.turn } } }));
    for (const line of scenario.phase0) send(line);
    return;
  }
  if (m.id === undefined) return;
  fs.appendFileSync(scenario.log, JSON.stringify({ method: m.method, params: m.params }) + "\\n");
  const reply = (scenario.replies[m.method] || []).shift();
  if (!reply) return;
  send(JSON.stringify(reply.error !== undefined ? { id: m.id, error: reply.error } : { id: m.id, result: reply.result }));
  for (const line of reply.after) send(line);
});`
);

interface StopReplay {
  session: CodexAppServerSession;
  events: SessionEvent[];
  /** 偽の app-server が受けた要求（method と params）。 */
  requests(): Array<{ method: string; params: Record<string, unknown> }>;
  /** 今のカードの epoch。 */
  epoch(): string;
  send: Promise<void>;
}

/** 台本を流す偽の app-server に繋いで 1 ターン送る。waitDone が false なら send の完了を待たない（ターンの途中で止める試験）。 */
async function stopReplay(scenario: StopScenario, opts: { skip?: Record<string, number>; waitDone?: boolean } = {}): Promise<StopReplay> {
  scenarios += 1;
  for (const [method, n] of Object.entries(opts.skip ?? {})) scenario.replies[method]?.splice(0, n);
  const log = path.join(tmp, `stop-log-${scenarios}`);
  fs.writeFileSync(log, "");
  const scenarioFile = path.join(tmp, `stop-scenario-${scenarios}.json`);
  fs.writeFileSync(scenarioFile, JSON.stringify({ ...scenario, log }));
  const bin = process.platform === "win32" ? path.join(tmp, `codex-stop-${scenarios}.cmd`) : path.join(tmp, `codex-stop-${scenarios}`);
  fs.writeFileSync(
    bin,
    process.platform === "win32"
      ? `@"${process.execPath}" "${fakeStop}" "${scenarioFile}" %*\r\n`
      : `#!/bin/sh\nexec "${process.execPath}" "${fakeStop}" "${scenarioFile}" "$@"\n`,
    { mode: 0o755 }
  );
  const session = new CodexAppServerSession("codex", undefined, tmp, { kind: "native", executable: bin, label: `native:${bin}`, shell: false }, async () => ({
    approvalPolicy: "on-request",
    sandboxMode: "workspace-write"
  }));
  const events: SessionEvent[] = [];
  const sent = session.send("hello", { type: "user_message", content: "hello" }, (e) => events.push(e));
  if (opts.waitDone !== false) {
    let timer: NodeJS.Timeout | undefined;
    try {
      await Promise.race([sent, new Promise((_, reject) => (timer = setTimeout(() => reject(new Error("send が終わらない")), 10_000)))]);
    } finally {
      clearTimeout(timer);
    }
  } else {
    await until(() => events.length > 0 || scenario.phase0.length === 0, "最初の通知が届く");
    await new Promise((r) => setTimeout(r, 100));
  }
  return {
    session,
    events,
    send: sent,
    requests: () =>
      fs
        .readFileSync(log, "utf8")
        .split("\n")
        .filter(Boolean)
        .map((l) => JSON.parse(l) as { method: string; params: Record<string, unknown> }),
    epoch: () => String(obj(session.subagentSnapshot()!).epoch)
  };
}

const TERMINAL_ITEM = "exec-0fa47f37-965d-4f5c-b33e-b492fd839ebc"; // s1a
const stopReq = (r: StopReplay, rowId: string) => ({ taskId: "subagents", rowId, epoch: r.epoch() });
const toolEnds = (events: SessionEvent[]): SessionEvent[] => events.filter((e) => e.type === "tool_end");
const stoppables = (id: string, events: SessionEvent[]): unknown[] => progressRows(events).filter((r) => r.id === id).map((r) => r.stoppable);

test("codex-stop s1a: 端末の行は stoppable で、terminate が terminated:true なら stopped。後の failed / -1 は stopped と読み tool_end は interrupted", async () => {
  const sc = stopScenario("s1a-terminal", { stopAt: "firstParentCompleted" });
  const r = await stopReplay(sc);
  try {
    assert.equal(last(TERMINAL_ITEM, r.events)?.state, "running");
    assert.equal(last(TERMINAL_ITEM, r.events)?.stoppable, true);
    assert.equal(last(TERMINAL_ITEM, r.events)?.rowKind, "shell");

    const outcome = await r.session.stopTask(stopReq(r, TERMINAL_ITEM));
    assert.deepEqual(outcome, { kind: "stopped" });
    const sent = r.requests();
    assert.deepEqual(sent.map((q) => q.method), ["thread/backgroundTerminals/terminate"]);
    assert.deepEqual(sent[0].params, { threadId: sc.thread, processId: "93607" });
    // 返事待ちの間は stoppable: false。stopped の行も false。
    assert.deepEqual(stoppables(TERMINAL_ITEM, r.events), [true, false, false]);
    // item/completed(failed / -1) は返事のすぐ後に届く。行は stopped のまま、tool_end は interrupted。
    await until(() => toolEnds(r.events).some((e) => e.toolUseId === TERMINAL_ITEM), "tool_end が届く");
    assert.equal(toolEnds(r.events).find((e) => e.toolUseId === TERMINAL_ITEM)?.metadata?.status, "interrupted");
    assert.deepEqual(states(TERMINAL_ITEM, r.events).filter((s, i, a) => a.indexOf(s) === i), ["running", "stopped"]);
    // 閉じた行への停止は何も送らず not_running。
    assert.deepEqual(await r.session.stopTask(stopReq(r, TERMINAL_ITEM)), { kind: "notRunning" });
    assert.equal(r.requests().length, 1);
  } finally {
    await r.session.close();
  }
});

test("codex-stop s1a: terminated:false はもういない（行が running なら stopped で閉じて not_running）", async () => {
  const r = await stopReplay(stopScenario("s1a-terminal", { stopAt: "firstParentCompleted" }), { skip: { "thread/backgroundTerminals/terminate": 1 } });
  try {
    assert.deepEqual(await r.session.stopTask(stopReq(r, TERMINAL_ITEM)), { kind: "notRunning" });
    assert.equal(last(TERMINAL_ITEM, r.events)?.state, "stopped");
    assert.equal(last(TERMINAL_ITEM, r.events)?.stoppable, false);
  } finally {
    await r.session.close();
  }
});

test("codex-stop s1a / s9: terminate のエラーは failed（CLI の文つき）で行は止められるまま。unknown variant は unsupported で全 shell 行の手がかりを外す", async () => {
  const r = await stopReplay(stopScenario("s1a-terminal", { stopAt: "firstParentCompleted" }), { skip: { "thread/backgroundTerminals/terminate": 2 } });
  try {
    const failed = await r.session.stopTask(stopReq(r, TERMINAL_ITEM));
    assert.equal(failed.kind, "failed");
    assert.match((failed as { message?: string }).message ?? "", /invalid background terminal process id/);
    assert.equal(last(TERMINAL_ITEM, r.events)?.state, "running");
    assert.equal(last(TERMINAL_ITEM, r.events)?.stoppable, true, "失敗したら true に戻して送る");
  } finally {
    await r.session.close();
  }
  const unknownVariant = fs
    .readFileSync(path.join(stopFixtureDir, "s9-errors.jsonl"), "utf8")
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l) as FixtureRecord)
    .find((rec) => rec.dir === "in" && String(obj(JSON.stringify(rec.msg.error ?? {})).message ?? "").includes("unknown variant"))!.msg.error;
  const unsupported = stopScenario("s1a-terminal", { stopAt: "firstParentCompleted" });
  // s9 の「unknown variant」の返事を、terminate への返事として使う。
  unsupported.replies["thread/backgroundTerminals/terminate"] = [{ error: unknownVariant, after: [] }];
  const u = await stopReplay(unsupported);
  try {
    assert.deepEqual(await u.session.stopTask(stopReq(u, TERMINAL_ITEM)), { kind: "unsupported" });
    assert.equal(last(TERMINAL_ITEM, u.events)?.stoppable, false);
    assert.deepEqual(await u.session.stopTask(stopReq(u, TERMINAL_ITEM)), { kind: "unsupported" });
    assert.equal(u.requests().length, 1, "断られた後は送らない");
  } finally {
    await u.session.close();
  }
});

test("codex-stop s1b: 2 つの端末のうち 1 つを止めても、もう 1 つは動き続け stoppable のまま", async () => {
  const r = await stopReplay(stopScenario("s1b-two-terminals", { stopAt: "firstParentCompleted" }), { skip: {} });
  try {
    const ids = [...new Set(progressRows(r.events).filter((row) => row.rowKind === "shell").map((row) => String(row.id)))];
    assert.equal(ids.length, 2);
    const [first, second] = ids;
    // 記録の 3 つめの terminate 以外は使わない。最初の terminate の返事は記録のとおり processId 15559 の分。
    const outcome = await r.session.stopTask(stopReq(r, first));
    assert.deepEqual(outcome, { kind: "stopped" });
    assert.equal(r.requests()[0].params.processId, "15559");
    assert.equal(last(second, r.events)?.state, "running");
    assert.equal(last(second, r.events)?.stoppable, true);
    assert.equal(last(first, r.events)?.state, "stopped");
  } finally {
    await r.session.close();
  }
});

test("codex-stop s2a: 子の行は turn/started で stoppable になり、turn/interrupt（子の thread と今の turn id）→ clean。stopped。親には送らない", async () => {
  const sc = stopScenario("s2a-subagent-after", { stopAt: "firstParentCompleted" });
  const r = await stopReplay(sc);
  try {
    const child = "01a15e3d-9b92-7281-b27f-3875d636a6af";
    assert.equal(last(child, r.events)?.state, "running");
    assert.equal(last(child, r.events)?.stoppable, true);
    const outcome = await r.session.stopTask(stopReq(r, child));
    assert.deepEqual(outcome, { kind: "stopped" });
    await until(() => r.requests().some((q) => q.method === "thread/backgroundTerminals/clean"), "clean が送られる");
    const sent = r.requests();
    assert.deepEqual(sent[0], { method: "turn/interrupt", params: { threadId: child, turnId: "01a15e3d-9c24-73d2-a896-752f41891d1a" } });
    assert.deepEqual(sent[1], { method: "thread/backgroundTerminals/clean", params: { threadId: child } });
    assert.equal(sent.filter((q) => q.params.threadId === sc.thread).length, 0, "親には何も送らない");
    assert.equal(last(child, r.events)?.state, "stopped");
    assert.equal(last(child, r.events)?.stoppable, false);
    assert.deepEqual(stoppables(child, r.events).slice(-2), [false, false]);
  } finally {
    await r.session.close();
  }
});

test("codex-stop s5: turn/interrupt の競合エラー（expected active turn id / thread not found）は not_running。手がかりを落とし、次は送らず unsupported", async () => {
  const r = await stopReplay(stopScenario("s5-child-edges", { stopAt: "firstParentCompleted" }));
  try {
    const child = "01a15e4d-9a59-7e01-8fd8-90c0ea8d2f80";
    assert.equal(last(child, r.events)?.stoppable, true);
    assert.deepEqual(await r.session.stopTask(stopReq(r, child)), { kind: "notRunning" });
    // 古い turn id のまま何度も押させない。行は running のまま、止められない印にする（Mac の dropChildTurnHandle と同じ）。
    assert.equal(last(child, r.events)?.state, "running");
    assert.equal(last(child, r.events)?.stoppable, false);
    assert.deepEqual(await r.session.stopTask(stopReq(r, child)), { kind: "unsupported" });
    assert.equal(r.requests().filter((q) => q.method === "turn/interrupt").length, 1);
  } finally {
    await r.session.close();
  }
});

test("codex-stop: 子の turn/interrupt が時間切れなら timeout。次に押しても送り直さず（同じ turn id に 2 回送らない）、閉じなければ stopped にせず timeout", async () => {
  const sc = stopScenario("s2a-subagent-after", { stopAt: "firstParentCompleted" });
  sc.replies["turn/interrupt"] = []; // 返事が来ない
  const saved = { ...codexStopTiming };
  codexStopTiming.requestMs = 150;
  codexStopTiming.closeMs = 150;
  const r = await stopReplay(sc);
  try {
    const child = "01a15e3d-9b92-7281-b27f-3875d636a6af";
    assert.deepEqual(await r.session.stopTask(stopReq(r, child)), { kind: "timeout" });
    assert.equal(last(child, r.events)?.state, "running");
    assert.equal(last(child, r.events)?.stoppable, true);
    assert.deepEqual(await r.session.stopTask(stopReq(r, child)), { kind: "timeout" });
    assert.equal(r.requests().filter((q) => q.method === "turn/interrupt").length, 1, "2 回目は送らない");
    assert.equal(last(child, r.events)?.stoppable, true, "押し直せる");
    assert.equal(last(child, r.events)?.state, "running");
  } finally {
    Object.assign(codexStopTiming, saved);
    await r.session.close();
  }
});

test("codex-stop s2c: 子の端末は子を止めても残る。子を止めると clean（子の thread）まで送る", async () => {
  const r = await stopReplay(stopScenario("s2c-child-cleanup", { stopAt: 60 }), { skip: { "turn/interrupt": 1 }, waitDone: false });
  try {
    const child = "01a15e42-9015-7b23-a680-9dbc1d156c97";
    assert.equal(last(child, r.events)?.stoppable, true);
    assert.deepEqual(await r.session.stopTask(stopReq(r, child)), { kind: "stopped" });
    await until(() => r.requests().some((q) => q.method === "thread/backgroundTerminals/clean"), "clean が送られる");
    assert.deepEqual(r.requests().map((q) => q.method), ["turn/interrupt", "thread/backgroundTerminals/clean"]);
    assert.equal(r.requests()[1].params.threadId, child);
  } finally {
    await r.session.close();
  }
});

test("同じ行への停止が重なったら、1 つの要求にまとめて同じ結果を返す。epoch が違えば stale、taskId が違えば unsupported", async () => {
  const r = await stopReplay(stopScenario("s1a-terminal", { stopAt: "firstParentCompleted" }));
  try {
    const [a, b] = await Promise.all([r.session.stopTask(stopReq(r, TERMINAL_ITEM)), r.session.stopTask(stopReq(r, TERMINAL_ITEM))]);
    assert.deepEqual(a, { kind: "stopped" });
    assert.deepEqual(b, { kind: "stopped" });
    assert.equal(r.requests().length, 1);
    assert.deepEqual(await r.session.stopTask({ taskId: "subagents", rowId: TERMINAL_ITEM, epoch: "other" }), { kind: "stale" });
    assert.deepEqual(await r.session.stopTask({ taskId: "subagents", epoch: r.epoch() }), { kind: "stale" });
    assert.deepEqual(await r.session.stopTask({ taskId: "subagents", rowId: "nope", epoch: r.epoch() }), { kind: "stale" });
    assert.deepEqual(await r.session.stopTask({ taskId: "wf-1" }), { kind: "unsupported" });
  } finally {
    await r.session.close();
  }
});

test("codex-stop s12: 親の turn/interrupt は同じ turn id に 2 回送らない（待ち時間は 5 秒）", async () => {
  const sc = stopScenario("s12-parent-double-interrupt", { stopAt: 30, afterAll: true });
  const r = await stopReplay(sc, { waitDone: false });
  try {
    await new Promise((resolve) => setTimeout(resolve, 200));
    await r.session.interrupt();
    await r.session.interrupt();
    await Promise.race([r.send, new Promise((_, reject) => setTimeout(() => reject(new Error("turn/completed(interrupted) で終わらない")), 5000))]);
    assert.equal(r.requests().filter((q) => q.method === "turn/interrupt").length, 1);
    assert.equal(dones(r.events).length, 1);
  } finally {
    await r.session.close();
  }
});

test("子への turn/interrupt と親の interrupt も同じ集合を見る（同じ turn id には送らない）", async () => {
  const sc = stopScenario("s2a-subagent-after", { stopAt: "firstParentCompleted" });
  const r = await stopReplay(sc);
  try {
    const child = "01a15e3d-9b92-7281-b27f-3875d636a6af";
    assert.deepEqual(await r.session.stopTask(stopReq(r, child)), { kind: "stopped" });
    await r.session.interrupt(); // 親のターンは終わっていて何も送らない
    assert.equal(r.requests().filter((q) => q.method === "turn/interrupt").length, 1);
  } finally {
    await r.session.close();
  }
});
