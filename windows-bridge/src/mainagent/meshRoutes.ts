import type http from "node:http";
import { callTool, SESSION_TOOLS, sortKeys } from "./mcpEndpoint.js";
import { DEFAULT_CEILING, MeshError, orchestrator as sharedOrchestrator, ToolError, type Caller, type Orchestrator } from "./orchestrator.js";

// 別の PC（A）から頼まれる口と、全部の PC の一覧の口（mac と同じ形）。
// どちらもトンネルからの端末の bdc_ だけ（ルートの表の access: "device"。ローカル鍵は 403 device_only）。
//
// POST /device/orchestrator/<tool>（<tool> は 7 つの道具）
// - 本文は道具の引数 ＋ capMode（段 0〜4。無ければ 1 = 毎回尋ねる）・depth（A の呼んだセッションの深さ）・caller {bridgeId, name}。
// - 承認カードは出さない（A で承認済み）。上限・深さ・mainagent のフォルダへ頼まない・自分へ頼まないは B でも確かめる。
// - get_reply / answer_approval で触れるのは、その端末から頼んだターンだけ。
// - 返事は MCP の道具の結果と同じ JSON（200。list_projects などは配列）。知らない道具（list_pcs を含む）は 404 {"error":"unknown_tool"}。
//   道具の失敗は 422 {"error": tool_error | depth | cycle | self | not_requested, "message": 文}（mac と同じ）。
// - ログは端末の deviceKeyId の先頭 8 文字と道具の名前だけ（本文は出さない）。

const MAX_BODY_BYTES = 1024 * 1024;


function writeJson(res: http.ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "content-length": Buffer.byteLength(text) });
  res.end(text);
}

async function readBody(req: http.IncomingMessage): Promise<Record<string, unknown> | undefined> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string);
    size += buf.length;
    if (size > MAX_BODY_BYTES) return undefined;
    chunks.push(buf);
  }
  const text = Buffer.concat(chunks).toString("utf8").trim();
  if (!text) return {};
  try {
    const value: unknown = JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

/** 本文から、B での呼んだ側（端末と capMode / depth / caller）を作る。 */
export function remoteCallerOf(deviceKeyId: string, body: Record<string, unknown>): Caller {
  const cap = body.capMode;
  const depth = body.depth;
  const from = body.caller && typeof body.caller === "object" && !Array.isArray(body.caller) ? (body.caller as Record<string, unknown>) : undefined;
  const pc =
    from && typeof from.bridgeId === "string" && from.bridgeId
      ? { bridgeId: from.bridgeId, name: typeof from.name === "string" && from.name ? from.name : from.bridgeId.slice(0, 8) }
      : undefined;
  return {
    token: "",
    agentId: "",
    remote: {
      deviceKeyId,
      capMode: typeof cap === "number" && Number.isInteger(cap) && cap >= 0 && cap <= 4 ? cap : DEFAULT_CEILING,
      depth: typeof depth === "number" && Number.isInteger(depth) && depth >= 0 ? depth : 0,
      pc
    }
  };
}

/** POST /device/orchestrator/<tool>（principal は .device）。 */
export async function handleDeviceOrchestrator(
  req: http.IncomingMessage,
  res: http.ServerResponse,
  tool: string,
  deviceKeyId: string,
  orch: Orchestrator = sharedOrchestrator
): Promise<void> {
  if (req.method !== "POST") {
    req.resume();
    res.writeHead(405, { allow: "POST", "cache-control": "no-store" });
    res.end();
    return;
  }
  if (!SESSION_TOOLS.includes(tool)) {
    req.resume();
    return writeJson(res, 404, { error: "unknown_tool" });
  }
  const body = await readBody(req);
  if (body === undefined) return writeJson(res, 400, { error: "bad_json" });
  console.log(`[mainagent] ${deviceKeyId.slice(0, 8)} ${tool}`);
  const caller = remoteCallerOf(deviceKeyId, body);
  const args: Record<string, unknown> = { ...body };
  for (const k of ["capMode", "depth", "caller", "pc"]) delete args[k];
  try {
    const value = await callTool(tool, args, caller, orch);
    if (res.destroyed) return;
    writeJson(res, 200, sortKeys(value));
  } catch (error) {
    if (res.destroyed) return;
    if (error instanceof MeshError) return writeJson(res, error.code === "unknown_tool" ? 404 : 422, error.code === "unknown_tool" ? { error: "unknown_tool" } : error.body);
    if (error instanceof ToolError) return writeJson(res, 422, { error: "tool_error", message: error.message });
    writeJson(res, 500, { error: "bridge_error" });
  }
}

/** GET /device/sessions/summary（principal は .device）。 */
export async function handleSessionsSummary(req: http.IncomingMessage, res: http.ServerResponse, orch: Orchestrator = sharedOrchestrator): Promise<void> {
  if (req.method !== "GET") {
    req.resume();
    res.writeHead(405, { allow: "GET", "cache-control": "no-store" });
    res.end();
    return;
  }
  writeJson(res, 200, await orch.sessionsSummary());
}
