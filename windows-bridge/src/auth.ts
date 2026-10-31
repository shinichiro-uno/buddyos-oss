import crypto from "node:crypto";
import type http from "node:http";
import type { DeviceRow, DeviceStore } from "./deviceStore.js";

// トンネルの中の認証（spec/PROTOCOL-v3.md §13・Appendix A）。mac の BridgeAuth.swift と同じ約束。
// - TunnelPeers: Bridge 自身が中継のトンネルから 127.0.0.1:<待ち受け> へつないだ TCP の、ローカル側の番号 → 端末。
//   HTTP 側は要求の送り元の番号でこれを引き、トンネル経由なら端末の bdc_ だけ、この PC の中からならローカル鍵だけを通す。
// - ルートの表（ROUTES）を 1 か所に持ち、表に無いパスは認証の前に 404 にする。資格情報なしで通るルートは作らない。

// ---- TunnelPeers ----

export interface TunnelPeer {
  deviceKeyId: string;
  connectionId: string;
  /** そのトンネルを閉じる（同じ番号が入れ直されたとき・端末を外したとき）。 */
  close(): void;
}

export class TunnelPeers {
  private readonly byPort = new Map<number, TunnelPeer>();

  /** 入れる。同じ番号が既にあったら（起こらないはずだが）、古い方のトンネルを閉じてから入れ直す。 */
  add(localPort: number, peer: TunnelPeer): void {
    const old = this.byPort.get(localPort);
    if (old && old !== peer) {
      this.byPort.delete(localPort);
      old.close();
    }
    this.byPort.set(localPort, peer);
  }

  /** 外す（そのトンネルが入れたものだけ）。ローカルの TCP を閉じる前に呼ぶ。 */
  remove(localPort: number, peer: TunnelPeer): void {
    if (this.byPort.get(localPort) === peer) this.byPort.delete(localPort);
  }

  get(remotePort: number | undefined): TunnelPeer | undefined {
    return remotePort === undefined ? undefined : this.byPort.get(remotePort);
  }

  countFor(deviceKeyId: string): number {
    let n = 0;
    for (const peer of this.byPort.values()) if (peer.deviceKeyId === deviceKeyId) n += 1;
    return n;
  }

  get size(): number {
    return this.byPort.size;
  }
}

// ---- ローカル鍵・管理鍵 ----

/** 管理鍵（PROTOCOL-v3 Appendix A）。デスクトップが Bridge を起こすたびに stdin で 1 行だけ渡す。ファイル・環境変数には置かない。 */
export class AdminKey {
  private value?: string;

  get available(): boolean {
    return this.value !== undefined;
  }

  /** 起動時に 1 回だけ入れる。 */
  set(key: string): void {
    if (this.value === undefined && ADMIN_KEY_PATTERN.test(key)) this.value = key;
  }

  matches(presented: string | undefined): boolean {
    return this.value !== undefined && presented !== undefined && constantTimeEqual(presented, this.value);
  }
}

export const ADMIN_KEY_PATTERN = /^bda_[A-Za-z0-9_-]{43}$/;

/**
 * stdin から管理鍵を 1 行（256 バイトまで）読む（PROTOCOL-v3 Appendix A）。TTY・5 秒で来ない・形が違うときは undefined。
 * 読んだ後も stdin を読み続け、閉じたら（デスクトップがいなくなった）onEnd を呼ぶ。
 */
export function readAdminKey(
  stdin: NodeJS.ReadableStream & { isTTY?: boolean },
  opts: { timeoutMs?: number; onEnd?: () => void } = {}
): Promise<string | undefined> {
  if (stdin.isTTY) return Promise.resolve(undefined);
  return new Promise((resolve) => {
    let buffered = Buffer.alloc(0);
    let settled = false;
    const finish = (key: string | undefined) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(key);
    };
    const timer = setTimeout(() => finish(undefined), opts.timeoutMs ?? 5000);
    timer.unref?.();
    stdin.on("data", (chunk: Buffer | string) => {
      if (settled) return;
      buffered = Buffer.concat([buffered, Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)]);
      const nl = buffered.indexOf(0x0a);
      if (nl < 0) {
        if (buffered.length > 256) finish(undefined);
        return;
      }
      if (nl > 256) return finish(undefined);
      finish(parseAdminLine(buffered.subarray(0, nl).toString("utf8")));
    });
    stdin.on("end", () => {
      finish(undefined);
      opts.onEnd?.();
    });
    stdin.on("error", () => finish(undefined));
    stdin.resume?.();
  });
}

function parseAdminLine(line: string): string | undefined {
  try {
    const value = JSON.parse(line) as { adminKey?: unknown };
    return typeof value.adminKey === "string" && ADMIN_KEY_PATTERN.test(value.adminKey) ? value.adminKey : undefined;
  } catch {
    return undefined;
  }
}

// ---- Principal ----

export type Principal = { kind: "local" } | { kind: "device"; deviceKeyId: string; row: DeviceRow };

export interface AuthContext {
  peers: TunnelPeers;
  devices: DeviceStore;
  /** いまのローカル鍵（作り直しで変わる）。 */
  localKey(): string;
  admin: AdminKey;
  /** Bridge の待ち受けの番号。 */
  listenPort(): number | undefined;
}

/** 要求の送り元（::ffff: を外す）と番号。 */
function remoteOf(req: http.IncomingMessage): { address?: string; port?: number } {
  const address = req.socket.remoteAddress?.replace(/^::ffff:/i, "");
  return { address, port: req.socket.remotePort };
}

/** 要求がトンネル経由なら、その端末（TunnelPeers で引いた deviceKeyId）。この PC の中からなら undefined。 */
export function tunnelOrigin(req: http.IncomingMessage, ctx: Pick<AuthContext, "peers">): TunnelPeer | undefined {
  return ctx.peers.get(remoteOf(req).port);
}

/**
 * 資格情報の取り出し（PROTOCOL-v3 §13.2）。Authorization: Bearer と、allowQuery のときは ?apiKey= も見る。
 * 両方あって値が違う・?apiKey= が 2 本以上ある・Bearer でない Authorization は conflict。
 */
export function credentialOf(req: http.IncomingMessage, url: URL, allowQuery: boolean): { value?: string; conflict: boolean; query: boolean } {
  const header = req.headers.authorization;
  let fromHeader: string | undefined;
  if (header !== undefined) {
    const m = /^Bearer (\S+)$/.exec(header);
    if (!m) return { conflict: true, query: false };
    fromHeader = m[1];
  }
  const queries = url.searchParams.getAll("apiKey");
  if (queries.length > 1) return { conflict: true, query: true };
  const fromQuery = queries[0];
  if (fromQuery !== undefined && !allowQuery) return { conflict: true, query: true };
  if (fromHeader !== undefined && fromQuery !== undefined && fromHeader !== fromQuery) return { conflict: true, query: true };
  return { value: fromHeader ?? fromQuery, conflict: false, query: fromQuery !== undefined };
}

/**
 * 誰からの要求か（PROTOCOL-v3 §13.2）。送り元の番号が TunnelPeers にあればトンネル経由（端末 D）で、D の bdc_ だけを通す。
 * 無ければこの PC の中からで、ローカル鍵だけを通す。送り元が 127.0.0.1 でない・受けた番号が待ち受けの番号でない
 * 要求は通さない。
 */
export function principalFor(req: http.IncomingMessage, url: URL, ctx: AuthContext, opts: { allowQuery: boolean }): Principal | null {
  const remote = remoteOf(req);
  if (remote.address !== "127.0.0.1") return null;
  const listen = ctx.listenPort();
  if (listen === undefined || req.socket.localPort !== listen) return null;
  const cred = credentialOf(req, url, opts.allowQuery);
  if (cred.conflict || cred.value === undefined) return null;
  const peer = ctx.peers.get(remote.port);
  if (peer) {
    if (!cred.value.startsWith("bdc_") || !ctx.devices.verify(peer.deviceKeyId, cred.value)) return null;
    const row = ctx.devices.get(peer.deviceKeyId);
    return row ? { kind: "device", deviceKeyId: peer.deviceKeyId, row } : null;
  }
  if (cred.value.startsWith("bdc_")) return null;
  return constantTimeEqual(cred.value, ctx.localKey()) ? { kind: "local" } : null;
}

// ---- ルートの表（PROTOCOL-v3 §13.3） ----

/**
 * any = .local と .device、local = .local だけ、admin = .local ＋管理鍵、device = .device だけ、preview = preview.ts が自分で確かめる、
 * mainagent = この PC の中から mainagent のセッションごとの合鍵 bmt_（mainagent/mcpEndpoint.ts が確かめる。トンネル経由は 403）。
 */
export type RouteAccess = "any" | "local" | "admin" | "device" | "preview" | "mainagent";

interface RouteEntry {
  pattern: RegExp;
  access: RouteAccess;
  /** WebSocket の upgrade で受けるルートか。 */
  ws?: boolean;
}

/**
 * Windows の Bridge のルートの表。ルートを足すときは、ここに行を足してから（PROTOCOL-v3 §13.3）。
 * /preview/* は preview.ts が Bearer かプレビューのセッションで確かめる（?apiKey= は受け付けない）。
 */
export const ROUTES: readonly RouteEntry[] = [
  { pattern: /^\/(health|status)$/, access: "any" },
  { pattern: /^\/ws\/agent\/[^/]+$/, access: "any", ws: true },
  { pattern: /^\/terminal\/pty$/, access: "any", ws: true },
  // 開いているペインを見る口（docs/PANE_SHARE_2026-10-25.md）。常駐プロセスがつなぐ host はこの PC の中だけ。
  // 一覧はヘッダの鍵だけ（表では言えないので、?apiKey= は server.ts が断る）。
  { pattern: /^\/terminal\/share$/, access: "any", ws: true },
  { pattern: /^\/terminal\/share\/host$/, access: "local", ws: true },
  { pattern: /^\/terminal\/share\/panes$/, access: "any" },
  { pattern: /^\/preview\/.+$/, access: "preview" },
  { pattern: /^\/(traffic|traffic\/reset|push-test)$/, access: "local" },
  {
    pattern: /^\/(claude\/(session-start|hook|session-end|channel\/poll|channel\/permission)|terminal\/((keys|panes)\/poll|pane-event))$/,
    access: "local"
  },
  {
    pattern:
      /^\/local\/(pairing\/invites(\/[^/]+)?|devices|devices\/events|devices\/[^/]+\/(revoke|rename)|approvals\/(open|close)|devices\/pending\/approve|devices\/pending\/[^/]+\/reject|devices\/reset|devices\/settings|registry\/resume|registry\/previous\/dismiss|orchestrator\/settings|remote-pcs)$/,
    access: "admin"
  },
  // 端末の自己管理（PROTOCOL-v3 §13.5）と、スマホで許可する口（spec/PROTOCOL-v3.md §10.4.1。許可できる端末かは localRoutes.ts が見る）。
  // 別の PC から頼まれる口と全部の PC の一覧（mainagent/meshRoutes.ts）。
  {
    pattern: /^\/device\/(self|unpair|approvals|approvals\/approve|approvals\/[^/]+\/reject|orchestrator\/[^/]+|sessions\/summary)$/,
    access: "device"
  },
  // mainagent の道具。ローカル鍵・端末の鍵では通さず、合鍵 bmt_ だけ。
  { pattern: /^\/mcp$/, access: "mainagent" }
];

/** パスがどの行に当たるか。表に無ければ undefined（認証の前に 404）。 */
export function routeAccess(pathname: string, ws: boolean): RouteAccess | undefined {
  for (const route of ROUTES) {
    if (!!route.ws === ws && route.pattern.test(pathname)) return route.access;
  }
  return undefined;
}

export type AuthDenial = { status: 401 | 403 | 404; error: "unauthorized" | "local_only" | "device_only" | "forbidden" | "admin_unavailable" | "not_found" };

/**
 * ルートの表と Principal で、要求を通すかを決める（preview は呼び出し側が preview.ts に渡す）。
 * 通すなら Principal、断るなら AuthDenial。エラーの本文は PROTOCOL-v3 §13.4（理由は細かく出さない）。
 */
export function authorizeRoute(
  req: http.IncomingMessage,
  url: URL,
  ctx: AuthContext,
  access: RouteAccess
): { principal: Principal } | { denial: AuthDenial } {
  // /mcp は Principal を作らない（mainAgentRouteDenial と合鍵で確かめる）。ここへ来たら通さない。
  if (access === "mainagent") return { denial: { status: 401, error: "unauthorized" } };
  if (access === "admin") {
    // ブラウザからは呼ばせない。?apiKey= は無視せず 401。ヘッダだけを受け付ける（PROTOCOL-v3 §13.2）。
    if (req.headers.origin !== undefined) return { denial: { status: 403, error: "forbidden" } };
    if (url.searchParams.has("apiKey")) return { denial: { status: 401, error: "unauthorized" } };
  }
  const principal = principalFor(req, url, ctx, { allowQuery: access !== "admin" && access !== "preview" });
  if (!principal) return { denial: { status: 401, error: "unauthorized" } };
  if ((access === "local" || access === "admin") && principal.kind !== "local") return { denial: { status: 403, error: "local_only" } };
  if (access === "device" && principal.kind !== "device") return { denial: { status: 403, error: "device_only" } };
  if (access === "admin") {
    if (!ctx.admin.available) return { denial: { status: 403, error: "admin_unavailable" } };
    const presented = req.headers["x-buddyos-admin"];
    if (typeof presented !== "string" || !ctx.admin.matches(presented)) return { denial: { status: 401, error: "unauthorized" } };
  }
  return { principal };
}

/** 断ったときの本文（PROTOCOL-v3 §13.4）。 */
export function denialBody(denial: AuthDenial): string {
  return JSON.stringify({ error: denial.error });
}

/** 秘密の比較を定数時間で行う（長さの違いは SHA-256 にそろえてから比べるので、長さも漏らさない）。 */
export function constantTimeEqual(a: string, b: string): boolean {
  const ha = crypto.createHash("sha256").update(a).digest();
  const hb = crypto.createHash("sha256").update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}
