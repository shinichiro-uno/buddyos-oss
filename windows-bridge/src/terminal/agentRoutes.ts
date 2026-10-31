import type http from "node:http";
import { agyApprovals } from "../agents/agyApproval.js";
import { codexTerminals } from "../agents/codexShared.js";
import { readBody } from "./routes.js";

/// Claude Code 以外のターミナル連携の HTTP ルート（mac の WebSocketServer と同じ）。
///   POST /codex/terminal      buddy-codex の中継が、TUI が開いている thread を知らせる（Bearer の api-key）
///                             {"thread_id": "...", "cwd": "...", "state": "open" | "closed"}
///   POST /antigravity/hook    Bridge が起動した agy の PreToolUse hook からの承認の問い合わせ
///                             （認証はターンごとのトークン X-BuddyOS-Hook-Token。iPhone で答えるまで応答を返さない）

export const AGENT_TERMINAL_ROUTES = new Set(["/codex/terminal", "/antigravity/hook"]);

const BODY_LIMIT = 2 * 1024 * 1024;

/** 扱ったら true。/codex/terminal の api-key の確認は呼び出し側で済ませておく。 */
export async function handleAgentTerminalRoute(req: http.IncomingMessage, res: http.ServerResponse, url: URL): Promise<boolean> {
  if (req.method !== "POST" || !AGENT_TERMINAL_ROUTES.has(url.pathname)) return false;
  const body = await readBody(req, BODY_LIMIT);
  if (url.pathname === "/codex/terminal") {
    let obj: Record<string, unknown> = {};
    try {
      const parsed = JSON.parse(body || "{}") as unknown;
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) obj = parsed as Record<string, unknown>;
    } catch {
      // 下で 400
    }
    const tid = typeof obj.thread_id === "string" ? obj.thread_id : "";
    if (!tid) {
      res.writeHead(400);
      res.end("bad request");
      return true;
    }
    if (obj.state === "closed") codexTerminals.close(tid);
    else codexTerminals.open(tid, typeof obj.cwd === "string" && obj.cwd ? obj.cwd : undefined);
    res.writeHead(200);
    res.end();
    return true;
  }
  const token = req.headers["x-buddyos-hook-token"];
  if (typeof token !== "string" || !token) {
    res.writeHead(400);
    res.end("bad request");
    return true;
  }
  const out = await agyApprovals.handle(token, body);
  if (!out) {
    res.writeHead(404);
    res.end("not found");
    return true;
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify(out));
  return true;
}
