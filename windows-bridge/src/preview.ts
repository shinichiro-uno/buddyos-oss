import crypto from "node:crypto";
import type http from "node:http";
import { Readable } from "node:stream";
import type { Principal } from "./auth.js";
import { allowedHost, allowedOrigin, forbiddenBody, pathComponents } from "./originGuard.js";
import { androidAspect, androidControl, androidFrame, androidPageHTML, androidTargets, streamAndroid } from "./androidPreview.js";
import { trafficMeter } from "./trafficMeter.js";

/// Live Preview の HTTP ルート（/preview/*）。mac-bridge の PreviewRoutes / WebProxy を Windows ブリッジ
/// （raw node:http）へ移植したもの。認証の約束は mac の実装が正本。
///
/// iOS Simulator（idb / simctl）は Windows に無いので、sim の口は adb でつながった Android の
/// エミュレータ・実機に向ける（androidPreview.ts。sim の各項目に platform:"android" を付ける）。
/// `?apiKey=` のクエリはどのルートでも受け付けない。
///   - POST /preview/session      -> 1 つの表示対象（web:<port> か sim:<serial>）だけに効くセッションを作る（Bearer ヘッダ）
///   - GET  /preview/targets      -> Android 端末（sim）+ 到達可能な web ポート一覧（Bearer ヘッダ）
///   - GET  /preview/ui?s=<session> -> web は sandbox の iframe で /preview/w/<session>/ を、sim は端末画面を出すページ
///   - GET  /preview/sim/stream|tap|swipe?udid=<serial> -> 端末画面と操作（sim のセッション `s=` か Bearer ヘッダ）
///   - GET  /preview/sim/frame|home|text?udid=<serial>  -> 1 枚・ホーム・文字入力（Bearer ヘッダ）
///   - ALL  /preview/w/<session>/** -> 127.0.0.1:<セッションのポート> へのリバースプロキシ（sandbox の iframe 用）
///   - ALL  /preview/web/<port>/**  -> 127.0.0.1:<port> へのリバースプロキシ（Bearer ヘッダ直。デバッグ用）
/// 返り値 true = /preview/* を処理した（呼び出し側は return する）。
///
/// 資格情報は端末認証 v3 の Principal（spec/PROTOCOL-v3.md §13.2）: Bearer はトンネル経由なら
/// その端末の bdc_、この PC の中からならローカル鍵。セッションは作った Principal を覚え、セッションで認証するルートは
/// 要求の出どころ（TunnelPeers で引いた端末、無ければこの PC）が作った Principal と同じときだけ通す。
export interface PreviewAuth {
  /** Bearer ヘッダの Principal。通らなければ null（?apiKey= は見ない）。 */
  bearer(req: http.IncomingMessage, url: URL): Principal | null;
  /** 要求の出どころ（"local" か "device:<deviceKeyId>"）。 */
  origin(req: http.IncomingMessage): string;
}

/** セッションの持ち主の表し方（"local" か "device:<deviceKeyId>"）。 */
export function previewOwner(principal: Principal): string {
  return principal.kind === "local" ? "local" : `device:${principal.deviceKeyId}`;
}

export async function handlePreview(
  req: http.IncomingMessage,
  res: http.ServerResponse,
  url: URL,
  auth: PreviewAuth
): Promise<boolean> {
  const comps = pathComponents(req.url) ?? [];
  if (comps[0] !== "preview" || comps.length < 2) return false;
  const method = req.method ?? "GET";

  // 0) セッションを作る ------------------------------------------------
  if (comps[1] === "session" && comps.length === 2) {
    if (method !== "POST") return false;
    const checked = bearerCheck(req, url, auth);
    if ("status" in checked) return jsonError(res, checked.status, checked.code);
    // 本文は認証を通ってから読む（4KB まで）。
    const body = await readBody(req, SESSION_REQUEST_MAX_BYTES);
    if (body === undefined) return abortError(res, 413, "payload_too_large");
    let raw = "";
    try {
      const parsed: unknown = JSON.parse(body.toString("utf8"));
      if (parsed && typeof parsed === "object" && typeof (parsed as { target?: unknown }).target === "string") {
        raw = (parsed as { target: string }).target;
      }
    } catch {
      raw = "";
    }
    const owner = previewOwner(checked.principal);
    let session: string;
    let target: string;
    const serial = parseSimTarget(raw);
    if (serial !== undefined) {
      // sim:<serial> は adb でつながっている Android 端末だけ（それ以外は invalid_target）。
      if (!(await androidTargets()).some((t) => t.udid === serial)) return jsonError(res, 400, "invalid_target");
      session = previewSessions.createSim(serial, owner);
      target = `sim:${serial}`;
    } else {
      const port = parseWebTarget(raw);
      if (port === undefined) return jsonError(res, 400, "invalid_target");
      if (!allowedWebPorts(req).has(port)) return jsonError(res, 403, "port_not_allowed");
      session = previewSessions.create(port, owner);
      target = `web:${port}`;
    }
    res.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
    res.end(JSON.stringify({
      session,
      url: `/preview/ui?s=${session}`,
      target,
      expiresIn: PREVIEW_SESSION_IDLE_TTL_SEC
    }));
    return true;
  }

  // 1) ターゲット探索 ---------------------------------------------------
  if (comps[1] === "targets" && comps.length === 2) {
    if (method !== "GET" && method !== "HEAD") return false;
    const checked = bearerCheck(req, url, auth);
    if ("status" in checked) return abortError(res, checked.status, checked.code);
    const [web, sim] = await Promise.all([webTargets([...allowedWebPorts(req)].sort((a, b) => a - b)), androidTargets()]);
    // iOS の PreviewTargets（Codable）が sim を要求するため、空配列でも必ず含める（adb の端末が無ければ空）。
    const payload = { sim, web };
    res.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store"
    });
    res.end(JSON.stringify(payload));
    return true;
  }

  // 2) ホスト済みコントロールページ（web は sandbox の iframe）------------
  if (comps[1] === "ui" && comps.length === 2) {
    if (method !== "GET" && method !== "HEAD") return false;
    const headers: Record<string, string> = {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "referrer-policy": "no-referrer",
      "content-security-policy": PAGE_CONTENT_SECURITY_POLICY
    };
    const session = url.searchParams.get("s");
    const port = session === null ? undefined : previewSessions.port(session, auth.origin(req));
    const serial = session === null || port !== undefined ? undefined : previewSessions.simSerial(session, auth.origin(req));
    if (session === null || (port === undefined && serial === undefined)) {
      headers["content-security-policy"] = "default-src 'none'; style-src 'unsafe-inline'";
      res.writeHead(401, headers);
      res.end(EXPIRED_PAGE_HTML);
      return true;
    }
    res.writeHead(200, headers);
    res.end(serial !== undefined ? simPageHTML(serial, session, await androidAspect(serial)) : webPageHTML(session));
    return true;
  }

  // 3) 端末画面（Android）のストリーム・1 枚・操作 -----------------------
  // stream / tap / swipe は sim のセッション（s=）か Bearer。frame / home / text は Bearer だけ（mac と同じ）。
  if (comps[1] === "sim" && comps.length === 3 && SIM_ACTIONS.has(comps[2])) {
    if (method !== "GET" && method !== "HEAD") return false;
    const action = comps[2];
    const sessionToken = url.searchParams.get("s");
    let serial: string | undefined;
    if (sessionToken !== null && SIM_SESSION_ACTIONS.has(action)) {
      serial = previewSessions.simSerial(sessionToken, auth.origin(req));
      if (serial === undefined) return abortError(res, 401, "unauthorized");
      const asked = url.searchParams.get("udid");
      if (asked !== null && asked !== serial) return abortError(res, 403, "udid mismatch");
    } else {
      const checked = bearerCheck(req, url, auth);
      if ("status" in checked) return abortError(res, checked.status, checked.code);
      serial = parseAdbSerial(url.searchParams.get("udid") ?? "");
      if (serial === undefined) return abortError(res, 400, "invalid udid");
    }
    if (action === "stream") {
      streamAndroid(req, res, serial);
      return true;
    }
    if (action === "frame") {
      const frame = await androidFrame(serial);
      if (!frame) return abortError(res, 503, "no frame");
      trafficMeter.record("preview.sim.frame.out", frame.length);
      res.writeHead(200, { "content-type": "image/png", "cache-control": "no-store" });
      res.end(frame);
      return true;
    }
    const r = await androidControl(serial, action, url.searchParams);
    res.writeHead(r.ok ? 200 : 500, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
    res.end(r.body);
    return true;
  }

  // 4) Web リバースプロキシ（catch-all）--------------------------------
  // 4a) sandbox の iframe 用。中継先のポートはセッションが決める。
  if (comps[1] === "w" && comps.length >= 3) {
    const session = comps[2];
    const port = previewSessions.port(session, auth.origin(req));
    if (port === undefined) return abortError(res, 401, "unauthorized");
    // 作った時点でポートは確かめ済み。Bridge 自身の番号でないことだけ毎回見る。
    if (bridgePorts(req).has(port)) return abortError(res, 403, "port_not_allowed");
    await proxyWeb(req, res, url, port, `/preview/w/${session}`, true);
    return true;
  }
  // 4b) Bearer 直（ネイティブ・ツール用）。検出した開発サーバーのポートだけ。
  if (comps[1] === "web" && comps.length >= 3) {
    const checked = bearerCheck(req, url, auth);
    if ("status" in checked) return abortError(res, checked.status, checked.code);
    const port = /^\d{1,5}$/.test(comps[2]) ? Number.parseInt(comps[2], 10) : NaN;
    if (!(port > 0 && port < 65536)) return abortError(res, 400, "invalid port");
    if (!allowedWebPorts(req).has(port)) return abortError(res, 403, "port_not_allowed");
    await proxyWeb(req, res, url, port, `/preview/web/${port}`, false);
    return true;
  }

  return false;
}

// MARK: - 認証

/// Bearer ヘッダ専用のルートの確認。Origin / Host の関門（server.ts と同じ）もここで見る。`?apiKey=` は受け付けない（401）。
function bearerCheck(req: http.IncomingMessage, url: URL, auth: PreviewAuth): { principal: Principal } | { status: number; code: string } {
  if (!allowedHost(req)) return { status: 403, code: "forbidden_host" };
  if (!allowedOrigin(req)) return { status: 403, code: "forbidden_origin" };
  const principal = auth.bearer(req, url);
  if (!principal) return { status: 401, code: "unauthorized" };
  return { principal };
}

/// 関門と POST /preview/session の失敗の本文（mac と同じ `{"error":"<code>"}`）。
function jsonError(res: http.ServerResponse, status: number, code: string): boolean {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(code === "forbidden_host" || code === "forbidden_origin" ? forbiddenBody(code) : JSON.stringify({ error: code }));
  return true;
}

/// それ以外のプレビューのルートの失敗の本文（mac の Vapor の Abort と同じ形 `{"error":true,"reason":"<code>"}`）。
/// クライアントは状態コードで判断し、本文に頼らない。
function abortError(res: http.ServerResponse, status: number, reason: string): boolean {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify({ error: true, reason }));
  return true;
}

/// 本文を `max` バイトまで読む。超えたら undefined。
async function readBody(req: http.IncomingMessage, max: number): Promise<Buffer | undefined> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string);
    size += buf.length;
    if (size > max) return undefined;
    chunks.push(buf);
  }
  return Buffer.concat(chunks);
}

/** POST /preview/session の本文の上限。 */
const SESSION_REQUEST_MAX_BYTES = 4 * 1024;

// MARK: - プレビューのセッション（mac の PreviewSessionStore と同じ）

/** 使わずにこの秒数たったら無効。 */
export const PREVIEW_SESSION_IDLE_TTL_SEC = 2 * 60 * 60;
/** 作ってからこの秒数で必ず無効。 */
export const PREVIEW_SESSION_ABSOLUTE_TTL_SEC = 12 * 60 * 60;
/** 同時に持てる数。超えたら最後に使ったのが一番古いものから捨てる。 */
export const PREVIEW_SESSION_MAX = 64;

/** base64url の 43 文字だけ（パスやクエリに紛れた別の文字列を照合に回さない）。 */
export function isWellFormedSession(token: string): boolean {
  return /^[A-Za-z0-9_-]{43}$/.test(token);
}

/// 資格情報とは別の、1 つの web ポートだけに効く合言葉。Bridge のメモリにだけ持つ（再起動で全部無効）。
/// キーはセッションの SHA-256。照合で値そのものを比べない（時間差で当てられないように）。
/// 作った Principal（owner）を覚え、使えるのは同じ出どころからの要求だけ（spec/PROTOCOL-v3.md §13.2）。
export class PreviewSessionStore {
  /** 表示対象は web のポートか、Android 端末（sim）の adb の serial のどちらか一方。 */
  private readonly entries = new Map<string, { port?: number; serial?: string; owner: string; createdAt: number; lastUsedAt: number }>();

  constructor(private readonly now: () => number = Date.now) {}

  /** 新しいセッションを作る。返り値は base64url の 43 文字。owner は previewOwner() の値。 */
  create(port: number, owner = "local"): string {
    return this.insert({ port }, owner);
  }

  /** Android 端末（sim:<serial>）のセッションを作る。 */
  createSim(serial: string, owner = "local"): string {
    return this.insert({ serial }, owner);
  }

  private insert(target: { port?: number; serial?: string }, owner: string): string {
    const token = crypto.randomBytes(32).toString("base64url");
    const t = this.now();
    this.purge(t);
    if (this.entries.size >= PREVIEW_SESSION_MAX) {
      let oldest: string | undefined;
      let oldestAt = Infinity;
      for (const [key, e] of this.entries) {
        if (e.lastUsedAt < oldestAt) {
          oldestAt = e.lastUsedAt;
          oldest = key;
        }
      }
      if (oldest !== undefined) this.entries.delete(oldest);
    }
    this.entries.set(digest(token), { ...target, owner, createdAt: t, lastUsedAt: t });
    return token;
  }

  /** セッションが生きていて、要求の出どころ（owner）が作った Principal と同じなら、その中継先のポートを返す（使った時刻を更新する）。 */
  port(token: string, owner = "local"): number | undefined {
    return this.lookup(token, owner)?.port;
  }

  /** sim のセッションなら、その端末の serial を返す（port と同じ確かめ方）。 */
  simSerial(token: string, owner = "local"): string | undefined {
    return this.lookup(token, owner)?.serial;
  }

  private lookup(token: string, owner: string): { port?: number; serial?: string } | undefined {
    if (!isWellFormedSession(token)) return undefined;
    const t = this.now();
    const key = digest(token);
    const e = this.entries.get(key);
    if (!e) return undefined;
    if (!this.alive(e, t)) {
      this.entries.delete(key);
      return undefined;
    }
    if (e.owner !== owner) return undefined;
    e.lastUsedAt = t;
    return e;
  }

  /** その持ち主のセッションを全部捨てる（端末を外したとき）。owner を省くと全部（すべての端末を切断）。 */
  drop(owner?: string): void {
    for (const [key, e] of this.entries) if (owner === undefined || e.owner === owner) this.entries.delete(key);
  }

  get size(): number {
    return this.entries.size;
  }

  private alive(e: { createdAt: number; lastUsedAt: number }, t: number): boolean {
    return t - e.lastUsedAt <= PREVIEW_SESSION_IDLE_TTL_SEC * 1000 && t - e.createdAt <= PREVIEW_SESSION_ABSOLUTE_TTL_SEC * 1000;
  }

  private purge(t: number): void {
    for (const [key, e] of this.entries) if (!this.alive(e, t)) this.entries.delete(key);
  }
}

function digest(token: string): string {
  return crypto.createHash("sha256").update(token, "utf8").digest("hex");
}

const previewSessions = new PreviewSessionStore();

/** 端末を外した・作り直したときに、プレビューのセッションを捨てる（owner を省くと全部）。 */
export function dropPreviewSessions(owner?: string): void {
  previewSessions.drop(owner);
}

/**
 * POST /preview/session の web の target。"web:<port>"（1〜65535 の 10 進、5 桁まで）だけ。
 * sim は parseSimTarget（Android 端末の adb の serial）で別に見る。
 */
export function parseWebTarget(raw: string): number | undefined {
  if (!raw.startsWith("web:")) return undefined;
  const digits = raw.slice("web:".length);
  if (!/^\d{1,5}$/.test(digits)) return undefined;
  const port = Number.parseInt(digits, 10);
  return port > 0 && port < 65536 ? port : undefined;
}

/** adb の serial（emulator-5554・192.168.0.5:5555 など）。パスやシェルに紛れる文字は通さない。 */
export function parseAdbSerial(raw: string): string | undefined {
  return /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(raw) && !raw.includes("..") ? raw : undefined;
}

/** POST /preview/session の sim の target（"sim:<adb の serial>"）。形が違えば undefined。 */
export function parseSimTarget(raw: string): string | undefined {
  return raw.startsWith("sim:") ? parseAdbSerial(raw.slice("sim:".length)) : undefined;
}

/** /preview/sim/* の操作。stream / tap / swipe はセッションでも使える（mac と同じ）。 */
const SIM_ACTIONS = new Set(["stream", "frame", "tap", "swipe", "home", "text"]);
const SIM_SESSION_ACTIONS = new Set(["stream", "tap", "swipe"]);

/**
 * /preview/ui の Android 端末の画面ページ。androidPageHTML は ?apiKey= を付けて /preview/sim/* を呼ぶ作りなので、
 * 代わりにプレビューのセッション（s=）を付けるよう書き換える（資格情報はページに載せない）。
 */
function simPageHTML(serial: string, session: string, aspect: number): string {
  const safe = session.replace(/[^A-Za-z0-9_-]/g, "");
  return androidPageHTML(serial, aspect)
    .replace("const KEY=new URLSearchParams(location.search).get('apiKey')||'';", `const KEY='${safe}';`)
    .replace("(KEY?'&apiKey='+encodeURIComponent(KEY):'')", "(KEY?'&s='+encodeURIComponent(KEY):'')");
}

// MARK: - 中継してよいポート

export const DEFAULT_WEB_PORTS = "3000,5173,8080,4321,19006,8081";

/** 既定の候補（BUDDYOS_PREVIEW_WEB_PORTS で置き換えられる）。 */
export function candidateWebPorts(env: NodeJS.ProcessEnv = process.env): Set<number> {
  const raw = env.BUDDYOS_PREVIEW_WEB_PORTS;
  const portsStr = raw && raw.length > 0 ? raw : DEFAULT_WEB_PORTS;
  return new Set(
    portsStr
      .split(",")
      .map((s) => Number.parseInt(s.trim(), 10))
      .filter((n) => Number.isInteger(n) && n > 0 && n < 65536)
  );
}

/** Bridge 自身の待ち受けの番号（この要求が届いた番号）。 */
function bridgePorts(req: http.IncomingMessage): Set<number> {
  const out = new Set<number>();
  if (req.socket.localPort) out.add(req.socket.localPort);
  return out;
}

/**
 * 中継してよいポート = 既定の候補 − Bridge 自身。
 * mac は lsof で見つけた開発サーバーのポートも足すが、Windows ではまだ検出していないので候補だけ（狭い側に倒す）。
 * 候補にない番号の開発サーバーは BUDDYOS_PREVIEW_WEB_PORTS に足す。
 */
function allowedWebPorts(req: http.IncomingMessage): Set<number> {
  const out = candidateWebPorts();
  for (const p of bridgePorts(req)) out.delete(p);
  return out;
}

// MARK: - targets 探索

/// 候補ポートに並列で軽量 GET を投げ、待ち受けている dev サーバーだけを返す。
/// title は応答先頭 ~8KB から <title> を抜き出す（取れれば）。
async function webTargets(candidates: number[]): Promise<Array<{ port: number; reachable: boolean; title: string | null }>> {
  const results = await Promise.all(candidates.map((port) => probeWeb(port)));
  const out: Array<{ port: number; reachable: boolean; title: string | null }> = [];
  for (let i = 0; i < candidates.length; i++) {
    const { reachable, title } = results[i];
    if (reachable) out.push({ port: candidates[i], reachable: true, title });
  }
  return out;
}

/// ループバックへの短タイムアウト GET。待ち受け確認と <title> 抽出を行う。
async function probeWeb(port: number): Promise<{ reachable: boolean; title: string | null }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 500);
  try {
    const resp = await fetch(`http://127.0.0.1:${port}/`, {
      method: "GET",
      // リダイレクトはたどらない（待ち受けが分かれば足りる。外へ要求を出さない）。
      redirect: "manual",
      signal: controller.signal
    });
    let title: string | null = null;
    try {
      const reader = resp.body?.getReader();
      if (reader) {
        // 先頭 ~8KB だけ読めば十分（残りは破棄）。
        const { value } = await reader.read();
        await reader.cancel().catch(() => {});
        if (value) {
          const body = new TextDecoder("utf-8").decode(value.subarray(0, 8192));
          const m = /<title>(.*?)<\/title>/is.exec(body);
          if (m) title = m[1].trim();
        }
      }
    } catch {
      // body 読み取り失敗は致命的でない（到達可否のみ確定）。
    }
    return { reachable: true, title };
  } catch {
    return { reachable: false, title: null };
  } finally {
    clearTimeout(timer);
  }
}

// MARK: - /preview/ui の web ページ（sandbox の iframe）

/** web ターゲットの iframe の sandbox 属性。allow-same-origin / allow-top-navigation は付けない。 */
export const IFRAME_SANDBOX = "allow-scripts allow-forms allow-popups allow-modals allow-downloads";
/** 中継した応答に足す CSP。iframe の sandbox 属性と同じ（トップレベルで直接開かれても sandbox のまま）。 */
export const PROXY_SANDBOX_POLICY = `sandbox ${IFRAME_SANDBOX}`;
/** /preview/ui のページに付ける CSP（自分のパス以外には読み書きさせない）。 */
export const PAGE_CONTENT_SECURITY_POLICY =
  "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data: blob:; "
  + "connect-src 'self'; frame-src 'self'; base-uri 'none'; form-action 'none'";

/** セッションが無い・切れたときの /preview/ui の本文（mac と同じ文言）。 */
const EXPIRED_PAGE_HTML = `<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>BuddyOS Preview</title>
<style>html,body{margin:0;height:100%;background:#111;color:#ccc;font-family:-apple-system,sans-serif}
p{margin:0;padding:32px 24px;text-align:center;line-height:1.6}</style></head>
<body><p>プレビューを開き直してください。<br>アプリが古い場合は、更新してから開いてください。</p></body></html>`;

/// mac-bridge webPageHTML の移植。apiKey はページに一切載せず、セッションを iframe のパスに入れる。
/// 中継したページは sandbox の iframe（allow-same-origin 無し = opaque origin）で開くので、
/// 親（このページ。URL に s= がある）・parent.performance・Bridge の他のパスは読めない。
function webPageHTML(session: string): string {
  // セッションは base64url（英数と - _）だけなので、そのまま属性値に入れてよい。
  const safe = session.replace(/[^A-Za-z0-9_-]/g, "");
  return `<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>BuddyOS Web</title>
<style>
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:#fff}
iframe{border:0;width:100%;height:100%;display:block}
</style></head>
<body>
<iframe src="/preview/w/${safe}/" sandbox="${IFRAME_SANDBOX}" referrerpolicy="no-referrer"></iframe>
</body></html>`;
}

// MARK: - web リバースプロキシ

/// <prefix>/<rest> を http://127.0.0.1:<port>/<rest> へ転送する（mac の WebProxy.handle と同じ）。
/// `prefix` は中継の入口（セッション経由なら /preview/w/<session>、Bearer 直なら /preview/web/<port>）。
/// `sandboxed` はプレビューのページの sandbox iframe（opaque origin）に出す応答か。そのときだけ
/// CSP sandbox を足し、X-Frame-Options / frame-ancestors を書き換え、CORS を開ける。
async function proxyWeb(
  req: http.IncomingMessage,
  res: http.ServerResponse,
  url: URL,
  port: number,
  prefix: string,
  sandboxed: boolean
): Promise<void> {
  const method = req.method ?? "GET";
  // opaque origin のページの fetch が出す CORS の preflight は上流へ流さず、ここで答える。
  const preflightMethod = req.headers["access-control-request-method"];
  if (sandboxed && method === "OPTIONS" && typeof preflightMethod === "string") {
    const headers: Record<string, string> = {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": preflightMethod,
      "access-control-max-age": "600",
      "content-security-policy": PROXY_SANDBOX_POLICY
    };
    const requestHeaders = req.headers["access-control-request-headers"];
    if (typeof requestHeaders === "string") headers["access-control-allow-headers"] = requestHeaders;
    res.writeHead(204, headers);
    res.end();
    return;
  }

  // 転送先 URL を組み立て（apiKey はクエリから除外）。入口（/preview/w/<session> か /preview/web/<port>）より後ろは
  // %エンコードも末尾の / もそのまま渡す。
  const rest = /^\/+preview\/+(?:w|web)\/+[^/]+\/?(.*)$/s.exec(url.pathname)?.[1] ?? "";
  const forwardedQuery = strippedQuery(url.search);
  let uri = `http://127.0.0.1:${port}/${rest}`;
  if (forwardedQuery) uri += `?${forwardedQuery}`;

  // リクエストヘッダは hop-by-hop と host/authorization を落として転送。
  // accept-encoding も落として upstream を identity（無圧縮）にする。HTML/CSS は
  // バッファして書き換えるため、圧縮ボディを text 化すると壊れる。
  // referer / origin は /preview/ui?s=... など Bridge 側の URL を含み得るので上流へ渡さない。cookie は
  // 以前の BuddyOS のプレビュー Cookie（buddyos_pv_*。今は使わないがブラウザに残りうる）だけ取り除く
  // （dev アプリ自身のセッション Cookie は通す）。
  const headers: Record<string, string> = {};
  for (const [name, value] of Object.entries(req.headers)) {
    const lower = name.toLowerCase();
    if (
      lower === "host" ||
      lower === "connection" ||
      lower === "authorization" ||
      lower === "content-length" ||
      lower === "accept-encoding" ||
      lower === "referer" ||
      lower === "origin"
    ) {
      continue;
    }
    if (value === undefined) continue;
    const joined = Array.isArray(value) ? value.join(", ") : value;
    if (lower === "cookie") {
      const kept = joined.split(";").map((p) => p.trim()).filter((p) => p && !p.startsWith("buddyos_pv_"));
      if (kept.length > 0) headers[name] = kept.join("; ");
      continue;
    }
    headers[name] = joined;
  }

  // メソッド + ボディを転送。GET/HEAD は body 不可。
  const hasBody = method !== "GET" && method !== "HEAD";

  let upstream: Response;
  try {
    upstream = await fetch(uri, {
      method,
      headers,
      body: hasBody ? (Readable.toWeb(req) as ReadableStream) : undefined,
      // リダイレクトは追従せず返す（途中の 302 の Set-Cookie を読み捨てない。mac と同じ）。
      redirect: "manual",
      // ストリーム body には half-duplex 指定が必要（Node fetch）。
      ...(hasBody ? { duplex: "half" } : {})
    } as RequestInit);
  } catch (error) {
    res.writeHead(502, { "content-type": "text/plain; charset=utf-8" });
    res.end(`web preview: cannot reach 127.0.0.1:${port} (${error instanceof Error ? error.message : String(error)})`);
    return;
  }

  // 応答ヘッダをコピー（hop-by-hop と content-length は除外）。
  // Set-Cookie は 1 本ずつ別ヘッダで返す必要があるので getSetCookie() で全部取り、配列で渡す
  // （Record に 1 本ずつ代入すると最後の 1 本に潰れ、dev アプリのログイン・CSRF がプレビュー内でだけ壊れる）。
  // sandbox の iframe に出すときは、X-Frame-Options: DENY や CSP frame-ancestors 'none' で真っ白にならないよう
  // SAMEORIGIN / 'self' に書き換える（下で CSP sandbox を足すときだけ）。CORS は opaque origin から読めるよう
  // * にそろえる（上流の値は捨てる）。リダイレクトは追従せず返すので、Location もプロキシ経由の URL に直す。
  const outHeaders: Record<string, string | string[]> = {};
  const csp: string[] = [];
  upstream.headers.forEach((value, name) => {
    const lower = name.toLowerCase();
    if (lower === "transfer-encoding" || lower === "connection" || lower === "content-length" || lower === "set-cookie") return;
    if (sandboxed && (lower === "access-control-allow-origin" || lower === "access-control-allow-credentials")) return;
    if (lower === "content-security-policy") csp.push(sandboxed ? rewriteFrameAncestors(value) : value);
    else if (sandboxed && lower === "x-frame-options") outHeaders[name] = "SAMEORIGIN";
    else if (lower === "location") outHeaders[name] = rewriteLocation(value, port, prefix);
    else outHeaders[name] = value;
  });
  const setCookies = upstream.headers.getSetCookie();
  if (setCookies.length > 0) outHeaders["set-cookie"] = setCookies;
  if (sandboxed) {
    // トップレベルで直接開かれても opaque origin のまま（親や Bridge の他のパスを読めない）。上流の CSP は残す。
    csp.push(PROXY_SANDBOX_POLICY);
    outHeaders["access-control-allow-origin"] = "*";
  }
  if (csp.length > 0) outHeaders["content-security-policy"] = csp;
  // プロキシしたページから辿るサブリソース・遷移の Referer に、iframe の文書 URL を載せない。
  outHeaders["referrer-policy"] = "no-referrer";

  const contentType = upstream.headers.get("content-type")?.toLowerCase() ?? "";
  if (contentType.includes("text/html")) {
    // HTML はバッファして <base> 注入 + ルート絶対パス書き換えしてから返す。
    const original = await upstream.text();
    const injected = rewriteHtml(original, prefix);
    delete outHeaders["content-length"];
    delete outHeaders["content-encoding"];
    res.writeHead(upstream.status, outHeaders);
    res.end(injected);
    return;
  }
  if (contentType.includes("text/css")) {
    // CSS は url(/...) / @import "/..." を書き換えてから返す。
    const original = await upstream.text();
    const rewritten = rewriteCssUrls(original, prefix);
    delete outHeaders["content-length"];
    delete outHeaders["content-encoding"];
    res.writeHead(upstream.status, outHeaders);
    res.end(rewritten);
    return;
  }

  res.writeHead(upstream.status, outHeaders);
  if (upstream.body) {
    // 上流が途中で切れたときの 'error' を拾う（拾わないと uncaughtException で Bridge ごと落ちる）。
    const body = Readable.fromWeb(upstream.body as Parameters<typeof Readable.fromWeb>[0]);
    body.on("error", () => res.destroy());
    res.on("close", () => body.destroy());
    body.pipe(res);
  } else {
    res.end();
  }
}

/**
 * 上流の `Location` を iframe から辿れる URL に直す（mac の WebProxy.rewriteLocation と同じ）。
 * ルート絶対パス（`/login`）と、同じポートの `http://127.0.0.1|localhost|[::1]:<port>/...` を `<prefix>/...` に
 * 置き換える。プロトコル相対（`//host/...`）・書き換え済み・相対 URL・外部 URL は触らない。
 */
export function rewriteLocation(location: string, port: number, prefix: string): string {
  if (location.startsWith("/")) {
    if (location.startsWith("//") || location.startsWith(`${prefix}/`) || location === prefix) return location;
    return prefix + location;
  }
  let parsed: URL;
  try {
    parsed = new URL(location);
  } catch {
    return location;
  }
  const host = parsed.hostname.toLowerCase();
  if (parsed.protocol !== "http:" || !["127.0.0.1", "localhost", "[::1]"].includes(host)) return location;
  if ((parsed.port === "" ? 80 : Number(parsed.port)) !== port) return location;
  return prefix + parsed.pathname + parsed.search + parsed.hash;
}

/// HTML 全体の書き換え：<base> 注入に加え、<base href> が効かないルート絶対
/// パス（`/` 始まり：Vite `/@vite/client`、Next.js `/_next/static/...`、
/// `/assets/app.css` 等）を <prefix>/ へ書き換える。
/// <base href> は相対 URL にしか効かず、絶対パスは Bridge のルートへ
/// 解決され（プロキシを迂回して 404/401）CSS が剥がれるため。
export function rewriteHtml(html: string, prefix: string): string {
  let s = injectBase(html, prefix);
  s = rewriteAbsoluteAttrs(s, prefix);
  s = rewriteCssUrls(s, prefix); // インライン <style> の url(/...) + @import
  return s;
}

/// ルート絶対の href/src/poster/action をプロキシパスへ前置。
/// protocol-relative（//cdn）と既に前置済みの URL は除外する。
function rewriteAbsoluteAttrs(s: string, prefix: string): string {
  return s.replace(
    /(\s(?:href|src|poster|action)\s*=\s*["'])\/(?!\/|preview\/(?:web|w)\/)/gi,
    (_m, head: string) => `${head}${prefix}/`
  );
}

/// CSS 内のルート絶対 url(/...) と @import "/..." を前置（HTML のインライン
/// <style> にも適用）。
function rewriteCssUrls(s: string, prefix: string): string {
  return s
    .replace(/url\(\s*(['"]?)\/(?!\/|preview\/(?:web|w)\/)/gi, (_m, q: string) => `url(${q}${prefix}/`)
    .replace(/@import\s+(['"])\/(?!\/|preview\/(?:web|w)\/)/gi, (_m, q: string) => `@import ${q}${prefix}/`);
}

/// <head> 直後に <base href> を注入（case-insensitive）。<head ...> 属性付きや
/// <head> 不在にも対応する（mac-bridge injectBase と同等）。
function injectBase(html: string, prefix: string): string {
  const baseTag = `<base href="${prefix}/">`;
  const headOpen = /<head(\s[^>]*)?>/i.exec(html);
  if (headOpen) {
    const end = headOpen.index + headOpen[0].length;
    return html.slice(0, end) + baseTag + html.slice(end);
  }
  return baseTag + html;
}

/// CSP ヘッダ値の `frame-ancestors` ディレクティブだけを `'self'` に置き換える（他の指定は残す）。
/// 1 行に複数ポリシーが `,` 区切りで入っている場合（同名ヘッダの結合を含む）も各ポリシーごとに処理する。
function rewriteFrameAncestors(csp: string): string {
  return csp
    .split(",")
    .map((policy) =>
      policy
        .split(";")
        .map((directive) => {
          const name = directive.trim().split(/[ \t]+/)[0]?.toLowerCase() ?? "";
          if (name !== "frame-ancestors") return directive;
          const leading = /^[ \t]*/.exec(directive)?.[0] ?? "";
          return `${leading}frame-ancestors 'self'`;
        })
        .join(";")
    )
    .join(",");
}

/// 転送前にクエリ文字列から apiKey を除く。
function strippedQuery(search: string): string {
  const q = search.startsWith("?") ? search.slice(1) : search;
  if (!q) return "";
  return q
    .split("&")
    .filter((pair) => {
      const key = pair.split("=", 1)[0];
      return key !== "apiKey";
    })
    .join("&");
}
