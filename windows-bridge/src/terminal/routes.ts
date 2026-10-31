import type http from "node:http";
import type { ClaudeChannelInbox } from "./channelInbox.js";
import type { ClaudeTerminalRegistry } from "./claudeTerminal.js";
import { parsePanes, type TerminalKeyRouter } from "./keys.js";
import { parsePaneEvent, validPane, type TerminalPaneStatus } from "./paneStatus.js";

/// ターミナル連携の HTTP ルート（mac の WebSocketServer の /claude/*・/terminal/* と同じ）。
///   POST /claude/session-start   SessionStart hook（buddy-register）。台帳に載せ、Bridge が起こした同じ会話を引き継ぐ
///   POST /claude/hook            ほかの hook（PermissionRequest はカードにする）。応答は空にする（返すと TUI の選択肢が消える）。
///                                ただしキー入力でも channel でも答えられない PermissionRequest は、応答を持っておいて
///                                カードの答えを返す（X-BuddyOS-Hold: 1 の hook だけ）
///   POST /claude/session-end     SessionEnd hook
///   GET  /claude/channel/poll    channel サーバの long-poll（iPhone からの発話・許可の答え）
///   POST /claude/channel/permission  channel が受けた許可の依頼
///   GET  /terminal/keys/poll     デスクトップの pty へのキー入力の long-poll（選択肢への答えと、人が打った発話の打ち込み）
///                                ?client=<名前>&pids=123,456&panes=<id>:<pid>,…&typing=1 → {"items":[{"pid":123,"keys":["1"],"gapMs":800}]}
///                                typing=1 は打ち込みを受け付けるデスクトップ（書く前に expectPid の claude が生きているかと、
///                                sessions/<expectPid>.json が expectSession の idle かを確かめる）。
///                                打ち込みの item には expectPid と expectSession が付く
///   GET  /terminal/panes/poll    デスクトップのペインの状態の long-poll（各ペインに agent、done なら reply、
///                                動いているバックグラウンドの作業の数 backgroundAgents / backgroundShells）
///   POST /terminal/pane-event    hook を使わないエージェント（Codex の proxy など）がペインの状態を知らせる
///                                {"pane","agent","state":"working|attention|done|error|idle","sessionId"?,"cwd"?,"reply"?}

export interface TerminalServices {
  registry: ClaudeTerminalRegistry;
  inbox: ClaudeChannelInbox;
  keys: TerminalKeyRouter;
  panes: TerminalPaneStatus;
  /** 台帳に新しく載った会話について、Bridge が起こしていた同じ会話を止めてターミナルへ引き継ぐ。引き継いだら true。 */
  handOver(sessionId: string): boolean;
}

const LONG_POLL_MS = 25_000;
const HOOK_BODY_LIMIT = 8 * 1024 * 1024;
const BODY_LIMIT = 1024 * 1024;
const PANE_EVENT_LIMIT = 64 * 1024;

export function readBody(req: http.IncomingMessage, limit: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

async function readJson(req: http.IncomingMessage, limit = BODY_LIMIT): Promise<Record<string, unknown> | undefined> {
  try {
    const parsed = JSON.parse(await readBody(req, limit)) as unknown;
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

function json(res: http.ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json", "content-length": Buffer.byteLength(text) });
  res.end(text);
}

function empty(res: http.ServerResponse, status: number): void {
  res.writeHead(status, { "content-length": "0" });
  res.end();
}

const str = (v: unknown): string | undefined => (typeof v === "string" && v ? v : typeof v === "number" ? String(v) : undefined);

/** ターミナル連携のルートなら処理して true。認証は呼び元で済ませる。 */
export async function handleTerminalRoute(
  req: http.IncomingMessage,
  res: http.ServerResponse,
  url: URL,
  t: TerminalServices
): Promise<boolean> {
  const p = url.pathname;
  const spawned = req.headers["x-buddy-spawned"] === "1";
  if (req.method === "POST" && p === "/claude/session-start") {
    // Bridge が起こした claude の hook は自分自身なので受けない。
    if (spawned) return empty(res, 202), true;
    const body = await readJson(req);
    const sid = str(body?.session_id);
    if (!body || !sid) return empty(res, 400), true;
    const wasLive = t.registry.isLive(sid);
    const pid = Number.parseInt(str(body.pid) ?? "", 10);
    const pane = validPane(req.headers["x-buddyos-pane"] as string | undefined);
    t.registry.register(sid, str(body.cwd), Number.isFinite(pid) && pid > 0 ? pid : undefined, str(body.transcript_path), str(body.inbox_socket), pane);
    const handedOver = wasLive ? false : t.handOver(sid);
    json(res, 200, { ok: true, handedOver });
    return true;
  }
  if (req.method === "POST" && p === "/claude/hook") {
    if (spawned) return empty(res, 202), true;
    const body = await readJson(req, HOOK_BODY_LIMIT);
    if (!body) return empty(res, 400), true;
    const pane = validPane(req.headers["x-buddyos-pane"] as string | undefined);
    if (body.hook_event_name !== "PermissionRequest") {
      empty(res, t.registry.ingest(body, pane) ? 200 : 202);
      return true;
    }
    // 応答を待てない（前の版の）hook には先に空で返してから、カードにする（宛先を調べる間 hook を待たせない）。
    if (req.headers["x-buddyos-hold"] !== "1") {
      empty(res, 200);
      void t.registry.ingestPermission(body, pane).catch(() => {});
      return true;
    }
    const held = await t.registry.ingestPermissionHeld(body, pane, true);
    if (!held.decision) return empty(res, held.handled ? 200 : 202), true;
    // hook が先に切れた（Claude Code の timeout 等）。もう答えを返せない。
    res.on("close", () => {
      if (!res.writableEnded) held.cancel?.();
    });
    // 宛先を調べている間にもう切れていた（close はもう来ない）。
    if (res.destroyed || res.socket?.destroyed) held.cancel?.();
    const out = await held.decision;
    if (res.destroyed) return true;
    if (out) json(res, 200, out);
    else empty(res, 200);
    return true;
  }
  if (req.method === "POST" && p === "/claude/session-end") {
    if (spawned) return empty(res, 202), true;
    const body = await readJson(req);
    const sid = str(body?.session_id);
    if (!sid) return empty(res, 400), true;
    t.registry.unregister(sid);
    // ついでに、SessionEnd を出さずに終わった会話も台帳（claude-terminals.json）から落とす。
    t.registry.pruneStale();
    empty(res, 200);
    return true;
  }
  if (req.method === "GET" && p === "/claude/channel/poll") {
    const sid = url.searchParams.get("session");
    if (!sid) return empty(res, 400), true;
    if (!t.registry.isLive(sid)) {
      // SessionStart の登録より先に channel が来ることがある。少し待ってから見直す。
      await new Promise((r) => setTimeout(r, 2000));
      if (!t.registry.isLive(sid)) return json(res, 200, { messages: [] }), true;
    }
    const items = await t.inbox.poll(sid, LONG_POLL_MS);
    json(res, 200, {
      messages: items.filter((i) => i.kind === "text").map((i) => (i as { text: string }).text),
      permissions: items
        .filter((i) => i.kind === "permission")
        .map((i) => ({ request_id: (i as { requestId: string }).requestId, behavior: (i as { behavior: string }).behavior }))
    });
    return true;
  }
  if (req.method === "POST" && p === "/claude/channel/permission") {
    const body = await readJson(req);
    const sid = str(body?.session);
    const rid = str(body?.request_id);
    if (!body || !sid || !rid) return empty(res, 400), true;
    t.registry.channelPermission(sid, rid, str(body.tool_name) ?? "tool", str(body.description), str(body.input_preview));
    empty(res, 200);
    return true;
  }
  if (req.method === "GET" && p === "/terminal/keys/poll") {
    const client = url.searchParams.get("client") || "default";
    const pids = (url.searchParams.get("pids") ?? "")
      .split(",")
      .map((v) => Number.parseInt(v, 10))
      .filter((v) => Number.isFinite(v) && v > 0);
    // typing=1 は発話の打ち込みを受け付けるデスクトップ（書く前に expectPid の claude が生きているかと、
    // sessions/<expectPid>.json が expectSession の idle かを確かめる）。
    const canType = url.searchParams.get("typing") === "1";
    const items = await t.keys.poll(client, pids, LONG_POLL_MS, parsePanes(url.searchParams.get("panes")), canType);
    // 打ち込みの item にだけ expectPid と expectSession が付く（選択肢への答えは今までの形のまま）。
    json(res, 200, {
      items: items.map((d) => {
        const item: { pid: number; keys: string[]; gapMs: number; expectPid?: number; expectSession?: string } = { pid: d.pid, keys: d.keys, gapMs: d.gapMs };
        if (d.expectPid) item.expectPid = d.expectPid;
        if (d.expectSession) item.expectSession = d.expectSession;
        return item;
      })
    });
    return true;
  }
  if (req.method === "GET" && p === "/terminal/panes/poll") {
    const since = Number.parseInt(url.searchParams.get("since") ?? "-1", 10);
    const r = await t.panes.poll(Number.isFinite(since) ? since : -1, LONG_POLL_MS);
    json(res, 200, { version: r.version, panes: r.panes });
    return true;
  }
  if (req.method === "POST" && p === "/terminal/pane-event") {
    const body = await readJson(req, PANE_EVENT_LIMIT);
    const ev = body && parsePaneEvent(body);
    if (!ev) return empty(res, 400), true;
    t.panes.set(ev.pane, ev.state, ev.sessionId, ev.cwd, ev.agent, ev.reply);
    empty(res, 200);
    return true;
  }
  return false;
}
