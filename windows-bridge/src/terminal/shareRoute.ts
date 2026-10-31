import type http from "node:http";
import type { Duplex } from "node:stream";
import { WebSocket, WebSocketServer } from "ws";

/**
 * 相手の PC のデスクトップで開いているターミナルのペインを、別の PC から見て打つ口（docs/PANE_SHARE_2026-10-25.md）。
 *
 * - `/terminal/share/host`（この PC の中だけ）: 常駐プロセス（PtyCore）が 1 本張る。`?client=` ごとに 1 本（開発版と製品版が並ぶ）。
 *   受ける: `panes` / `attached` / `gone` / `data` / `replay` / `size` / `exit`。送る: `attach` / `input` / `resize` / `detach` / `resync`
 * - `/terminal/share?pane=&cols=&rows=`（見る人）: `/terminal/pty` と同じ形。
 *   送る: バイナリ = 出力。テキスト = `{"type":"attached","restored":true}` / `replay` / `size` / `exit` / `gone`
 *   受ける: `{"type":"input","data"}` / `{"type":"resize","cols","rows"}`（`kill` も含め、ほかは捨てる）
 * - `GET /terminal/share/panes`: 全部の常駐プロセスのペインの一覧（sharePanes）。
 *
 * 見る人は Bridge が振る sid（v1, v2, …）で分ける。B の端末は止めない（A で閉じてもつなぎを切るだけ）。
 * 出力が中継より速いときは溜めずに捨て、追いついたら常駐プロセスに画面の写しを頼み直す（resync）。
 */

/** 1 つの端末（Principal）が同時に見られるペインの数（/terminal/pty と同じ）。 */
const MAX_PER_OWNER = 32;
/** 見る人へ送りきれていない出力がこれを超えたら、出力を捨て始める。LOW まで減ったら写しを頼み直す。 */
const SEND_HIGH = 1024 * 1024;
const SEND_LOW = 256 * 1024;
/** 死んだ接続を見つける間隔（/terminal/pty と同じ）。 */
const PING_MS = 30_000;
/** 同じ client の常駐プロセスがつなぎ直したとき、古い方を閉じるコード。 */
const REPLACED_CODE = 4000;
/** 一覧に載せるペインの数の上限（壊れた常駐プロセスで一覧が膨らまないように）。 */
const PANES_LIMIT = 1000;

/** 待つ時間（テストで縮める）。hostWaitMs = ペインを持つ常駐プロセスが来るまで、attachMs = attached の答えまで。 */
export const shareTimeouts = { hostWaitMs: 5000, attachMs: 15_000 };

export interface SharePane {
  id: string;
  agentId?: string;
  cwd?: string;
  cols: number;
  rows: number;
}

interface HostLink {
  client: string;
  ws: WebSocket;
  panes: SharePane[];
  /** 最後に panes が届いた順番（同じペインを 2 つの常駐プロセスが持っていたら、新しく届いた方へつなぐ）。 */
  panesSeq: number;
}

interface Viewer {
  sid: string;
  /** 見ている端末（previewOwner と同じ形。"local" か "device:<deviceKeyId>"）。 */
  owner: string;
  /** 見ている端末の表示名（B の画面に「○○ が見ています」と出す）。この PC の中からなら無し。 */
  name?: string;
  pane: string;
  size: { cols: number; rows: number } | null;
  ws: WebSocket;
  host: HostLink | null;
  attached: boolean;
  /** ok = 送る、lagging = 送りきれず捨てている、resyncing = 写しを頼んで replay を待っている（それまでの data は捨てる）。 */
  flow: "ok" | "lagging" | "resyncing";
  waitTimer?: NodeJS.Timeout;
  attachTimer?: NodeJS.Timeout;
}

const hosts = new Map<string, HostLink>();
const viewers = new Map<string, Viewer>();
let nextSid = 1;
let panesSeq = 0;
const hostWss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024 * 1024 });
const viewerWss = new WebSocketServer({ noServer: true, maxPayload: 4 * 1024 * 1024 });

function sendJSON(ws: WebSocket, obj: Record<string, unknown>): void {
  if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
}

function clamp(n: number, fallback: number): number {
  return Number.isFinite(n) && n > 0 ? Math.max(2, Math.min(1000, Math.floor(n))) : fallback;
}

const validPaneId = (v: unknown): v is string => typeof v === "string" && v.length > 0 && v.length <= 128;
const CLIENT = /^[A-Za-z0-9._-]{1,64}$/;

/** 相手が眠った・中継が半開きのまま、という接続を見つけて閉じる。止めるときは返した関数を呼ぶ。 */
function keepAlive(ws: WebSocket): () => void {
  let pong = true;
  ws.on("pong", () => {
    pong = true;
  });
  const ping = setInterval(() => {
    if (!pong) return ws.terminate();
    pong = false;
    try {
      ws.ping();
    } catch {
      ws.terminate();
    }
  }, PING_MS);
  ping.unref();
  return () => clearInterval(ping);
}

function parsePanes(v: unknown): SharePane[] {
  if (!Array.isArray(v)) return [];
  const out: SharePane[] = [];
  for (const p of v.slice(0, PANES_LIMIT)) {
    if (!p || typeof p !== "object" || !validPaneId((p as SharePane).id)) continue;
    const x = p as Record<string, unknown>;
    out.push({
      id: x.id as string,
      ...(typeof x.agentId === "string" ? { agentId: x.agentId } : {}),
      ...(typeof x.cwd === "string" ? { cwd: x.cwd } : {}),
      cols: clamp(Number(x.cols), 80),
      rows: clamp(Number(x.rows), 24)
    });
  }
  return out;
}

/**
 * 見る人を閉じる。detach なら常駐プロセスに detach を送る（B の端末は止めない。exit / gone の後は常駐プロセスが知っているので送らない）。
 * code は 1000（ふつう）か 1001（常駐プロセスが切れた・答えが無い。A はつなぎ直す）。
 */
function closeViewer(v: Viewer, opts: { last?: Record<string, unknown>; detach?: boolean; code?: number } = {}): void {
  if (viewers.get(v.sid) !== v) return;
  viewers.delete(v.sid);
  clearTimeout(v.waitTimer);
  clearTimeout(v.attachTimer);
  if (opts.detach !== false && v.host && hosts.get(v.host.client) === v.host) sendJSON(v.host.ws, { t: "detach", sid: v.sid });
  if (opts.last) sendJSON(v.ws, opts.last);
  v.ws.close(opts.code ?? 1000);
}

/** ペインを持つ常駐プロセス（同じペインが 2 つにあれば、panes が新しく届いた方）。 */
function hostFor(pane: string): HostLink | undefined {
  let best: HostLink | undefined;
  for (const h of hosts.values()) {
    if (h.panes.some((p) => p.id === pane) && (!best || h.panesSeq > best.panesSeq)) best = h;
  }
  return best;
}

/** 常駐プロセスへ attach を送る。attached が来なければ閉じる（A がつなぎ直す）。 */
function attachViewer(v: Viewer, h: HostLink): void {
  clearTimeout(v.waitTimer);
  v.waitTimer = undefined;
  v.host = h;
  sendJSON(h.ws, { t: "attach", sid: v.sid, id: v.pane, ...(v.size ?? {}), ...(v.name ? { name: v.name } : {}) });
  v.attachTimer = setTimeout(() => closeViewer(v, { code: 1001 }), shareTimeouts.attachMs);
  v.attachTimer.unref();
}

/** ペインを持つ常駐プロセスを待っている見る人を、つなげるものからつなぐ（panes が届いたとき）。 */
function routeWaiting(): void {
  for (const v of viewers.values()) {
    if (v.host) continue;
    const h = hostFor(v.pane);
    if (h) attachViewer(v, h);
  }
}

/** 出力を見る人へ送る。送りきれていない分が多ければ捨てて遅れ中にし、減ったら写しを頼み直す。 */
function sendData(v: Viewer, data: string): void {
  if (!v.attached || v.flow !== "ok" || v.ws.readyState !== WebSocket.OPEN) return;
  const ws = v.ws;
  if (ws.bufferedAmount > SEND_HIGH) {
    v.flow = "lagging";
    return;
  }
  ws.send(Buffer.from(data, "utf8"), () => {
    if (v.flow !== "lagging" || ws.bufferedAmount >= SEND_LOW || viewers.get(v.sid) !== v || !v.host) return;
    v.flow = "resyncing";
    sendJSON(v.host.ws, { t: "resync", sid: v.sid });
  });
}

function onHostMessage(h: HostLink, raw: WebSocket.RawData, isBinary: boolean): void {
  if (isBinary || hosts.get(h.client) !== h) return;
  let msg: Record<string, unknown>;
  try {
    msg = JSON.parse(String(raw));
  } catch {
    return;
  }
  if (!msg || typeof msg !== "object") return;
  if (msg.t === "panes") {
    h.panes = parsePanes(msg.panes);
    h.panesSeq = ++panesSeq;
    routeWaiting();
    return;
  }
  // 知らない sid・ほかの常駐プロセスにつないでいる sid のメッセージは捨てる。
  const v = typeof msg.sid === "string" ? viewers.get(msg.sid) : undefined;
  if (!v || v.host !== h) return;
  const size = { type: "size", cols: clamp(Number(msg.cols), 80), rows: clamp(Number(msg.rows), 24) };
  const snapshot = typeof msg.snapshot === "string" ? msg.snapshot : "";
  switch (msg.t) {
    case "attached":
      if (v.attached) return;
      clearTimeout(v.attachTimer);
      v.attachTimer = undefined;
      v.attached = true;
      sendJSON(v.ws, { type: "attached", restored: true });
      if (snapshot) sendJSON(v.ws, { type: "replay", data: snapshot });
      sendJSON(v.ws, size);
      return;
    case "data":
      if (typeof msg.data === "string" && msg.data) sendData(v, msg.data);
      return;
    case "replay":
      if (!v.attached) return;
      // 写しに捨てた分も含まれるので、ここから送り直す。
      v.flow = "ok";
      sendJSON(v.ws, { type: "replay", data: snapshot });
      sendJSON(v.ws, size);
      return;
    case "size":
      if (v.attached) sendJSON(v.ws, size);
      return;
    case "exit":
      closeViewer(v, { last: { type: "exit", code: Number.isFinite(Number(msg.code)) ? Number(msg.code) : -1 }, detach: false });
      return;
    case "gone":
      closeViewer(v, { last: { type: "gone" }, detach: false });
      return;
  }
}

/** その常駐プロセスにつないでいた見る人を全部閉じる（A はつなぎ直しを試みる）。 */
function dropHostViewers(h: HostLink): void {
  for (const v of [...viewers.values()]) if (v.host === h) closeViewer(v, { detach: false, code: 1001 });
}

/** server の upgrade から呼ぶ（/terminal/share/host）。認証（この PC の中のローカル鍵）は済んでいること。 */
export function handleShareHostUpgrade(req: http.IncomingMessage, socket: Duplex, head: Buffer, url: URL): void {
  const client = url.searchParams.get("client") ?? "default";
  if (!CLIENT.test(client)) {
    socket.write("HTTP/1.1 400 Bad Request\r\n\r\n");
    socket.destroy();
    return;
  }
  hostWss.handleUpgrade(req, socket, head, (ws) => {
    // 同じ client は新しい方を正とする（古い方と、そこにつないでいた見る人は切る）。違う client は並べて持つ。
    const old = hosts.get(client);
    if (old) {
      hosts.delete(client);
      dropHostViewers(old);
      old.ws.close(REPLACED_CODE, "replaced");
    }
    const h: HostLink = { client, ws, panes: [], panesSeq: 0 };
    hosts.set(client, h);
    const stop = keepAlive(ws);
    ws.on("message", (raw, isBinary) => onHostMessage(h, raw, isBinary));
    ws.on("close", () => {
      stop();
      if (hosts.get(client) !== h) return;
      hosts.delete(client);
      dropHostViewers(h);
    });
  });
}

/** server の upgrade から呼ぶ（/terminal/share）。認証は済んでいること。owner は previewOwner(principal)。 */
export function handleShareViewerUpgrade(req: http.IncomingMessage, socket: Duplex, head: Buffer, url: URL, owner: string, name?: string): void {
  const q = url.searchParams;
  const pane = q.get("pane") ?? "";
  if (!validPaneId(pane)) {
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
    return;
  }
  // 大きさは A の枠。B のアプリがつながっていないペインだけ、常駐プロセスがこれに合わせる。
  const size = q.has("cols") && q.has("rows") ? { cols: clamp(Number(q.get("cols")), 80), rows: clamp(Number(q.get("rows")), 24) } : null;
  viewerWss.handleUpgrade(req, socket, head, (ws) => {
    if ([...viewers.values()].filter((x) => x.owner === owner).length >= MAX_PER_OWNER) {
      sendJSON(ws, { type: "exit", code: -1, message: `見ているターミナルが多すぎます（${MAX_PER_OWNER} 個まで）。使っていないものを閉じてください` });
      ws.close();
      return;
    }
    const v: Viewer = { sid: `v${nextSid++}`, owner, name, pane, size, ws, host: null, attached: false, flow: "ok" };
    viewers.set(v.sid, v);
    const stop = keepAlive(ws);
    ws.on("message", (raw, isBinary) => {
      if (isBinary || viewers.get(v.sid) !== v) return;
      let msg: { type?: string; data?: unknown; cols?: unknown; rows?: unknown };
      try {
        msg = JSON.parse(String(raw));
      } catch {
        return;
      }
      if (msg.type === "input" && typeof msg.data === "string") {
        if (v.host) sendJSON(v.host.ws, { t: "input", sid: v.sid, data: msg.data });
      } else if (msg.type === "resize") {
        // attach の前なら、attach に載せる大きさだけ変える。
        v.size = { cols: clamp(Number(msg.cols), 80), rows: clamp(Number(msg.rows), 24) };
        if (v.host) sendJSON(v.host.ws, { t: "resize", sid: v.sid, ...v.size });
      }
      // kill は受けない（A で閉じても B の端末は止めない）。
    });
    ws.on("close", () => {
      stop();
      closeViewer(v);
    });
    const h = hostFor(pane);
    if (h) {
      attachViewer(v, h);
      return;
    }
    // そのペインを持つ常駐プロセスがまだいない（つなぎ直しの途中など）。panes が届くのを少し待つ。
    v.waitTimer = setTimeout(() => closeViewer(v, { last: { type: "gone" }, detach: false }), shareTimeouts.hostWaitMs);
    v.waitTimer.unref();
  });
}

/** GET /terminal/share/panes の本文。stateOf はペインの状態（/terminal/panes/poll と同じもの。分かるときだけ）。 */
export function sharePanes(stateOf?: (pane: string) => string | undefined): {
  available: boolean;
  panes: Array<SharePane & { viewers: number; state?: string }>;
} {
  const panes: Array<SharePane & { viewers: number; state?: string }> = [];
  for (const h of hosts.values()) {
    for (const p of h.panes) {
      let n = 0;
      for (const v of viewers.values()) if (v.host === h && v.pane === p.id) n++;
      const state = stateOf?.(p.id);
      panes.push({ ...p, viewers: n, ...(state ? { state } : {}) });
    }
  }
  return { available: hosts.size > 0, panes };
}

/** 端末を外した・すべての端末を切断したときに、その端末が見ているものを切る（owner を省くと全部。mac と同じく exit -1）。B の端末は止めない。 */
export function dropShareViewers(owner?: string): void {
  for (const v of [...viewers.values()]) {
    if (owner === undefined || v.owner === owner) closeViewer(v, { last: { type: "exit", code: -1 } });
  }
}
