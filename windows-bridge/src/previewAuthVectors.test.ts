import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import type { AddressInfo } from "node:net";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  allowedHostValues,
  allowedOriginValues,
  DESKTOP_ORIGIN,
  forbiddenBody,
  guardRejection,
  isPreviewSessionPath
} from "./originGuard.js";
import {
  candidateWebPorts,
  handlePreview,
  IFRAME_SANDBOX,
  isWellFormedSession,
  PAGE_CONTENT_SECURITY_POLICY,
  parseWebTarget,
  PREVIEW_SESSION_ABSOLUTE_TTL_SEC,
  PREVIEW_SESSION_IDLE_TTL_SEC,
  PREVIEW_SESSION_MAX,
  PreviewSessionStore,
  type PreviewAuth,
  PROXY_SANDBOX_POLICY,
  rewriteLocation
} from "./preview.js";
import { credentialOf } from "./auth.js";

// shared/preview-auth-vectors.json は mac（PreviewAuthVectorTests.swift）・desktop と共通の固定値
// （プレビューの認証の約束）。改変するときは 3 実装を一緒に直す。
interface Vectors {
  desktopOrigin: string;
  host: { allow: string[][]; deny: string[][] };
  origin: { allow: string[][]; deny: string[][] };
  paths: { sessionAuth: string[]; guarded: string[] };
  targets: { valid: Array<{ raw: string; param: string }>; invalid: string[] };
  session: { tokenLength: number; idleTTLSeconds: number; absoluteTTLSeconds: number; maxSessions: number; wellFormed: string[]; malformed: string[] };
  routes: { createSession: string; pagePrefix: string; sessionProxyPrefix: string; bearerProxyPrefix: string };
  errors: Record<string, string>;
  iframeSandbox: string;
  proxySandboxPolicy: string;
  pageContentSecurityPolicy: string;
  defaultWebPorts: number[];
  locationRewrite: Array<{ location: string; port: number; prefix: string; expected: string }>;
}

const vectors = JSON.parse(
  fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "preview-auth-vectors.json"), "utf8")
) as Vectors;

test("ベクタ: Host と Origin", () => {
  assert.equal(DESKTOP_ORIGIN, vectors.desktopOrigin);
  for (const h of vectors.host.allow) assert.equal(allowedHostValues(h), true, JSON.stringify(h));
  for (const h of vectors.host.deny) assert.equal(allowedHostValues(h), false, JSON.stringify(h));
  for (const o of vectors.origin.allow) assert.equal(allowedOriginValues(o), true, JSON.stringify(o));
  for (const o of vectors.origin.deny) assert.equal(allowedOriginValues(o), false, JSON.stringify(o));
});

test("ベクタ: Origin の関門をかけないルート", () => {
  for (const p of vectors.paths.sessionAuth) assert.equal(isPreviewSessionPath(p), true, p);
  for (const p of vectors.paths.guarded) assert.equal(isPreviewSessionPath(p), false, p);
  // 正規化すると別のルートになるものは、正規化した後で見る（ルーターと同じ）。
  assert.equal(isPreviewSessionPath("/preview/w/x/../../ws/agent/claude"), false);
});

test("ベクタ: target（Windows は web だけ。sim は invalid_target）", () => {
  for (const t of vectors.targets.valid) {
    const port = parseWebTarget(t.raw);
    if (t.param.startsWith("web:")) assert.equal(`web:${port}`, t.param, t.raw);
    else assert.equal(port, undefined, t.raw);
  }
  for (const raw of vectors.targets.invalid) assert.equal(parseWebTarget(raw), undefined, raw);
});

test("ベクタ: セッションの形・寿命・個数", () => {
  assert.equal(PREVIEW_SESSION_IDLE_TTL_SEC, vectors.session.idleTTLSeconds);
  assert.equal(PREVIEW_SESSION_ABSOLUTE_TTL_SEC, vectors.session.absoluteTTLSeconds);
  assert.equal(PREVIEW_SESSION_MAX, vectors.session.maxSessions);
  for (const t of vectors.session.wellFormed) assert.equal(isWellFormedSession(t), true, t);
  for (const t of vectors.session.malformed) assert.equal(isWellFormedSession(t), false, t);

  let now = 1_000_000_000;
  const store = new PreviewSessionStore(() => now);
  const s = store.create(5173);
  assert.equal(s.length, vectors.session.tokenLength);
  assert.equal(isWellFormedSession(s), true);
  now += (PREVIEW_SESSION_IDLE_TTL_SEC - 1) * 1000;
  assert.equal(store.port(s), 5173); // 使うと延びる
  now += (PREVIEW_SESSION_IDLE_TTL_SEC + 1) * 1000;
  assert.equal(store.port(s), undefined);

  const t = store.create(3000);
  for (let i = 0; i < 50; i++) {
    now += (PREVIEW_SESSION_IDLE_TTL_SEC / 2) * 1000;
    store.port(t);
  }
  assert.equal(store.port(t), undefined); // 12 時間で必ず切れる

  for (let i = 0; i < PREVIEW_SESSION_MAX + 10; i++) store.create(3000);
  assert.ok(store.size <= PREVIEW_SESSION_MAX);
});

test("セッションは作った Principal の出どころからだけ使え、端末を外すと捨てられる（spec/PROTOCOL-v3.md §13.2）", () => {
  const store = new PreviewSessionStore();
  const mine = store.create(5173, "device:AAAA");
  const local = store.create(5173, "local");
  assert.equal(store.port(mine, "local"), undefined);
  assert.equal(store.port(mine, "device:BBBB"), undefined);
  assert.equal(store.port(mine, "device:AAAA"), 5173);
  assert.equal(store.port(local, "device:AAAA"), undefined);
  store.drop("device:AAAA");
  assert.equal(store.port(mine, "device:AAAA"), undefined);
  assert.equal(store.port(local, "local"), 5173);
  store.drop();
  assert.equal(store.port(local, "local"), undefined);
});

test("ベクタ: CSP・sandbox・既定のポート・Location の書き換え", () => {
  assert.equal(IFRAME_SANDBOX, vectors.iframeSandbox);
  assert.equal(PROXY_SANDBOX_POLICY, vectors.proxySandboxPolicy);
  assert.equal(PAGE_CONTENT_SECURITY_POLICY, vectors.pageContentSecurityPolicy);
  assert.deepEqual([...candidateWebPorts({})].sort((a, b) => a - b), [...vectors.defaultWebPorts].sort((a, b) => a - b));
  for (const c of vectors.locationRewrite) assert.equal(rewriteLocation(c.location, c.port, c.prefix), c.expected, c.location);
  assert.equal(forbiddenBody("forbidden_host"), `{"error":"${vectors.errors.forbiddenHost}"}`);
  assert.equal(forbiddenBody("forbidden_origin"), `{"error":"${vectors.errors.forbiddenOrigin}"}`);
});

// MARK: - 本物の HTTP（関門 + /preview/* だけを載せた小さなサーバー。server.ts と同じ順に呼ぶ）

const API_KEY = "test-api-key-preview";
/** この PC の中から（TunnelPeers に無い）だけのテスト用の認証。Bearer がローカル鍵なら .local（?apiKey= は見ない）。 */
const testAuth: PreviewAuth = {
  bearer: (req, url) => {
    const cred = credentialOf(req, url, false);
    return !cred.conflict && cred.value === API_KEY ? { kind: "local" } : null;
  },
  origin: () => "local"
};
let bridgeServer: http.Server;
let upstreamServer: http.Server;
let port = 0;
let upstreamPort = 0;
const savedPorts = process.env.BUDDYOS_PREVIEW_WEB_PORTS;

before(async () => {
  upstreamServer = http.createServer((req, res) => {
    if (req.url === "/redirect") {
      res.writeHead(302, { location: "/login", "set-cookie": ["a=1; Path=/", "b=2; Path=/"] });
      res.end();
      return;
    }
    if (req.url === "/echo") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ cookie: req.headers.cookie ?? null, origin: req.headers.origin ?? null, referer: req.headers.referer ?? null, auth: req.headers.authorization ?? null }));
      return;
    }
    res.writeHead(200, {
      "content-type": "text/html; charset=utf-8",
      "x-frame-options": "DENY",
      "content-security-policy": "frame-ancestors 'none'; default-src 'self'",
      "access-control-allow-origin": "http://localhost:5173"
    });
    res.end('<html><head><title>dev</title></head><body><script src="/app.js"></script></body></html>');
  });
  await new Promise<void>((resolve) => upstreamServer.listen(0, "127.0.0.1", () => resolve()));
  upstreamPort = (upstreamServer.address() as AddressInfo).port;

  bridgeServer = http.createServer((req, res) => {
    const rejection = guardRejection(req);
    if (rejection) {
      res.writeHead(403, { "content-type": "application/json; charset=utf-8" });
      res.end(forbiddenBody(rejection));
      return;
    }
    const url = new URL(req.url ?? "/", "http://" + (req.headers.host ?? "localhost"));
    void handlePreview(req, res, url, testAuth).then((handled) => {
      if (!handled) {
        res.writeHead(404);
        res.end("not found");
      }
    });
  });
  await new Promise<void>((resolve) => bridgeServer.listen(0, "127.0.0.1", () => resolve()));
  port = (bridgeServer.address() as AddressInfo).port;
  process.env.BUDDYOS_PREVIEW_WEB_PORTS = `${upstreamPort},${port}`;
});

after(async () => {
  if (savedPorts === undefined) delete process.env.BUDDYOS_PREVIEW_WEB_PORTS;
  else process.env.BUDDYOS_PREVIEW_WEB_PORTS = savedPorts;
  await new Promise<void>((resolve) => bridgeServer.close(() => resolve()));
  await new Promise<void>((resolve) => upstreamServer.close(() => resolve()));
});

interface RawResponse {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: string;
}

function raw(p: string, opts: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<RawResponse> {
  return new Promise((resolve, reject) => {
    const r = http.request(
      { host: "127.0.0.1", port, path: p, method: opts.method ?? "GET", headers: { host: `127.0.0.1:${port}`, ...opts.headers } },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (c: Buffer) => chunks.push(c));
        res.on("end", () => resolve({ status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(chunks).toString("utf8") }));
      }
    );
    r.on("error", reject);
    r.end(opts.body);
  });
}

const bearer = { authorization: `Bearer ${API_KEY}` };

function createSession(target: string, headers: Record<string, string> = {}): Promise<RawResponse> {
  return raw(vectors.routes.createSession, {
    method: "POST",
    headers: { ...bearer, "content-type": "application/json", ...headers },
    body: JSON.stringify({ target })
  });
}

test("POST /preview/session: Bearer だけ・target の形・ポートの制限", async () => {
  assert.equal((await raw(vectors.routes.createSession, { method: "POST", body: '{"target":"web:1"}' })).status, 401);
  assert.equal((await raw(`${vectors.routes.createSession}?apiKey=${API_KEY}`, { method: "POST", body: `{"target":"web:${upstreamPort}"}` })).status, 401);
  const badOrigin = await createSession(`web:${upstreamPort}`, { origin: "null" });
  assert.equal(badOrigin.status, 403);
  assert.deepEqual(JSON.parse(badOrigin.body), { error: vectors.errors.forbiddenOrigin });
  const badHost = await createSession(`web:${upstreamPort}`, { host: "rebind.example" });
  assert.equal(badHost.status, 403);
  assert.deepEqual(JSON.parse(badHost.body), { error: vectors.errors.forbiddenHost });
  for (const target of ["sim:7F3C2A10-1B2C-4D5E-8F90-0123456789AB", "web:0", "nope"]) {
    const r = await createSession(target);
    assert.equal(r.status, 400, target);
    assert.deepEqual(JSON.parse(r.body), { error: vectors.errors.invalidTarget });
  }
  for (const target of [`web:${port}`, "web:1"]) {
    const r = await createSession(target);
    assert.equal(r.status, 403, target);
    assert.deepEqual(JSON.parse(r.body), { error: vectors.errors.portNotAllowed });
  }
  const ok = await createSession(`web:${upstreamPort}`, { origin: DESKTOP_ORIGIN });
  assert.equal(ok.status, 200);
  const body = JSON.parse(ok.body) as { session: string; url: string; target: string; expiresIn: number };
  assert.equal(body.session.length, vectors.session.tokenLength);
  assert.equal(body.url, `${vectors.routes.pagePrefix}${body.session}`);
  assert.equal(body.target, `web:${upstreamPort}`);
  assert.equal(body.expiresIn, vectors.session.idleTTLSeconds);
});

test("/preview/ui と /preview/w/<session>: apiKey を載せず、sandbox の iframe で中継する", async () => {
  // 古いアプリの開き方（?apiKey=）は 401 で、開き直しの案内を出す。
  const legacy = await raw(`/preview/ui?target=web:${upstreamPort}&apiKey=${API_KEY}`);
  assert.equal(legacy.status, 401);
  assert.match(legacy.body, /プレビューを開き直してください/);

  const session = (JSON.parse((await createSession(`web:${upstreamPort}`)).body) as { session: string }).session;
  // 中継したページは Origin: null で来る。セッションのルートは Origin の関門の外。
  const page = await raw(`${vectors.routes.pagePrefix}${session}`, { headers: { origin: "null" } });
  assert.equal(page.status, 200);
  assert.equal(page.headers["content-security-policy"], vectors.pageContentSecurityPolicy);
  assert.equal(page.headers["referrer-policy"], "no-referrer");
  assert.ok(page.body.includes(`src="${vectors.routes.sessionProxyPrefix}${session}/"`));
  assert.ok(page.body.includes(`sandbox="${vectors.iframeSandbox}"`));
  assert.ok(!page.body.includes(API_KEY));

  const proxied = await raw(`${vectors.routes.sessionProxyPrefix}${session}/`, { headers: { origin: "null" } });
  assert.equal(proxied.status, 200);
  assert.equal(proxied.headers["x-frame-options"], "SAMEORIGIN");
  assert.equal(proxied.headers["access-control-allow-origin"], "*");
  const csp = String(proxied.headers["content-security-policy"]);
  assert.match(csp, /frame-ancestors 'self'/);
  assert.ok(csp.includes(vectors.proxySandboxPolicy));
  assert.ok(proxied.body.includes(`<base href="${vectors.routes.sessionProxyPrefix}${session}/">`));
  assert.ok(proxied.body.includes(`src="${vectors.routes.sessionProxyPrefix}${session}/app.js"`));

  // 上流へは Origin / Referer / Authorization / buddyos_pv_* の Cookie を渡さない。
  const echo = await raw(`${vectors.routes.sessionProxyPrefix}${session}/echo`, {
    headers: { origin: "null", referer: "http://127.0.0.1/preview/ui?s=x", cookie: "buddyos_pv_abc=1; app=2", ...bearer }
  });
  assert.deepEqual(JSON.parse(echo.body), { cookie: "app=2", origin: null, referer: null, auth: null });

  // リダイレクトは追従せず、Location を中継の URL に直し、Set-Cookie は 1 本ずつ返す。
  const redirect = await raw(`${vectors.routes.sessionProxyPrefix}${session}/redirect`);
  assert.equal(redirect.status, 302);
  assert.equal(redirect.headers.location, `${vectors.routes.sessionProxyPrefix}${session}/login`);
  assert.deepEqual(redirect.headers["set-cookie"], ["a=1; Path=/", "b=2; Path=/"]);

  // CORS の preflight は Bridge が答える。
  const preflight = await raw(`${vectors.routes.sessionProxyPrefix}${session}/api`, {
    method: "OPTIONS",
    headers: { origin: "null", "access-control-request-method": "PUT", "access-control-request-headers": "x-a" }
  });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers["access-control-allow-origin"], "*");
  assert.equal(preflight.headers["access-control-allow-methods"], "PUT");
  assert.equal(preflight.headers["access-control-allow-headers"], "x-a");
  assert.equal(preflight.headers["access-control-max-age"], "600");

  // セッションが無い・形が違うものは 401。Host の関門はプレビューにもかかる。
  assert.equal((await raw(`${vectors.routes.sessionProxyPrefix}${"A".repeat(43)}/`)).status, 401);
  assert.equal((await raw(`${vectors.routes.sessionProxyPrefix}${session}/`, { headers: { host: "rebind.example" } })).status, 403);
});

test("Bearer 専用のプレビューのルート: クエリの apiKey と Origin を断り、枠の制限は外さない", async () => {
  assert.equal((await raw(`/preview/targets?apiKey=${API_KEY}`)).status, 401);
  assert.equal((await raw("/preview/targets", { headers: { ...bearer, origin: "null" } })).status, 403);
  const targets = await raw("/preview/targets", { headers: bearer });
  assert.equal(targets.status, 200);
  const parsed = JSON.parse(targets.body) as { sim: unknown[]; web: Array<{ port: number }> };
  assert.deepEqual(parsed.sim, []);
  assert.ok(parsed.web.some((w) => w.port === upstreamPort));
  assert.ok(!parsed.web.some((w) => w.port === port));

  assert.equal((await raw(`${vectors.routes.bearerProxyPrefix}${upstreamPort}/?apiKey=${API_KEY}`)).status, 401);
  assert.equal((await raw(`${vectors.routes.bearerProxyPrefix}${port}/`, { headers: bearer })).status, 403);
  assert.equal((await raw(`${vectors.routes.bearerProxyPrefix}1/`, { headers: bearer })).status, 403);
  const direct = await raw(`${vectors.routes.bearerProxyPrefix}${upstreamPort}/`, { headers: bearer });
  assert.equal(direct.status, 200);
  assert.equal(direct.headers["x-frame-options"], "DENY");
  assert.equal(direct.headers["content-security-policy"], "frame-ancestors 'none'; default-src 'self'");
  assert.ok(direct.body.includes(`<base href="${vectors.routes.bearerProxyPrefix}${upstreamPort}/">`));
});
