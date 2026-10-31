import type http from "node:http";
import type { ApprovalQueue, SubmitResult } from "./approvalQueue.js";
import type { Principal } from "./auth.js";
import type { ResetReason } from "./deviceStore.js";
import type { BridgeIdentity } from "./identity.js";
import { handleDeviceOrchestrator, handleSessionsSummary } from "./mainagent/meshRoutes.js";
import type { Orchestrator } from "./mainagent/orchestrator.js";
import { parseRemotePcs } from "./mainagent/remoteTransport.js";
import { invitePairUrl, type PairingInvites } from "./pairingInvites.js";
import { clearRegistryHold, clearRegistryPrevious, readRegistryHold, readRegistryStatus } from "./registryFiles.js";
import { displayName, sanitizeName } from "./tunnelV3.js";

// Bridge のローカル管理 API（/local/*。.local ＋管理鍵）と端末の自己管理 API（/device/*。.device だけ）。
// spec/PROTOCOL-v3.md Appendix A・§13.5。認証は server.ts がルートの表（auth.ts）で済ませてから呼ぶ。
// 承認（approve。PROTOCOL-v3 Appendix A）は mac の LocalDeviceRoutes と同じ: /local/approvals/open|close で「端末を追加」の窓、
// /local/devices/pending/approve で PC での番号の入力、/local/devices/pending/:id/reject で拒否（approvalQueue.ts）。
// スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）: 許可できる端末（ios・android）はトンネル越しに
// /device/approvals で同じ承認待ちを見て、番号を入力・拒否できる。設定の remoteApprovalsEnabled で切れる。
// 登録簿（registry.ts）: /local/registry/resume は registry-hold を外してすぐ登録し直す、/local/registry/previous/dismiss は
// 409 で作り直す前の bridgeId の控え（registryPrevious）を消す（mac の LocalDeviceRoutes と同じ）。
// エージェントどうしで頼み合う: /local/orchestrator/settings（allSessions）と
// /local/remote-pcs（デスクトップが開いた別の PC の中継口。メモリだけ）、端末からの /device/orchestrator/<tool> と
// /device/sessions/summary（mainagent/meshRoutes.ts）。

const BODY_LIMIT = 4 * 1024;
/** PUT /local/remote-pcs の本文の上限（PC ごとに合言葉と名前が入る）。 */
const REMOTE_PCS_LIMIT = 64 * 1024;
/** /local/devices/events を待たせる長さ（PROTOCOL-v3 Appendix A）。 */
export const EVENTS_WAIT_MS = 25_000;
/** /device/unpair の応答を返してから行を消すまで（PROTOCOL-v3 §13.5）。 */
export const UNPAIR_DELAY_MS = 1_000;

export interface LocalRoutesContext {
  identity: BridgeIdentity;
  invites: PairingInvites;
  approvals: ApprovalQueue;
  relayURL: string;
  bridgeName: () => string;
  isOnline: (deviceKeyId: string) => boolean;
  /** 端末を外した・解除したときに、その端末のトンネルとプレビューのセッションを片付ける。 */
  forgetDevice: (deviceKeyId: string) => void;
  /** 作り直し・/local/registry/resume の後、すぐ登録簿に登録し直してもらう（index.ts が BridgeRegistry をつなぐ）。 */
  requestRegistration: () => void;
  /** 長いポーリングの待ち時間（テストのときだけ短くする）。 */
  eventsWaitMs?: number;
  unpairDelayMs?: number;
  /** エージェントどうしで頼み合う口（無ければ /local/orchestrator/*・/local/remote-pcs・/device/orchestrator/* は 404）。 */
  orchestrator?: Orchestrator;
}

/** DevicesView（PROTOCOL-v3 Appendix A。時刻はすべて UNIX ミリ秒。確認コードは載せない）。 */
export function devicesView(ctx: LocalRoutesContext): Record<string, unknown> {
  const devices = ctx.identity.devices;
  return {
    bootId: devices.bootId,
    version: devices.version,
    broken: devices.broken,
    approvalsEnabled: devices.approvalsSetting,
    approvalsOpenUntil: ctx.approvals.windowOpenUntil ?? null,
    remoteApprovalsEnabled: devices.remoteApprovalsEnabled,
    remoteApprovalsAvailable: devices.remoteApprovalsAvailable,
    devices: devices.deviceViews(ctx.isOnline),
    pending: pendingViews(ctx),
    invites: ctx.invites.views(),
    lastReset: devices.lastReset ?? null,
    registryPrevious: readRegistryStatus(ctx.identity.dir)?.registryPrevious ?? null
  };
}

/** 承認待ちの一覧（DevicesView の pending・/device/approvals。確認コードは載せない）。 */
function pendingViews(ctx: LocalRoutesContext): Array<Record<string, unknown>> {
  return ctx.approvals.views().map((p) => ({
    pendingId: p.pendingId,
    display: p.display,
    platform: p.platform,
    requestedAt: p.requestedAt,
    expiresAt: p.expiresAt,
    sameNameExists: p.sameNameExists,
    remote: p.remote
  }));
}

/** 番号の入力の結果を HTTP にする（PC・スマホで同じ形。PROTOCOL-v3 Appendix A・spec/PROTOCOL-v3.md §10.4.1）。 */
function submitResponse(res: http.ServerResponse, result: SubmitResult): void {
  switch (result.kind) {
    case "ok":
      return json(res, 200, { ok: true, deviceKeyId: result.deviceKeyId, display: result.display });
    case "mismatch":
      return json(res, 400, { error: "code_mismatch", remaining: result.remaining });
    case "bad_code":
      return json(res, 400, { error: "bad_code" });
    case "no_pending":
      return json(res, 404, { error: "no_pending" });
    case "device_gone":
      return json(res, 410, { error: "device_gone" });
  }
}

/** /local/* を処理する。表（auth.ts の ROUTES）にあるパスだけが来る。 */
export async function handleLocalRoute(req: http.IncomingMessage, res: http.ServerResponse, url: URL, ctx: LocalRoutesContext): Promise<void> {
  const p = url.pathname;
  const method = req.method ?? "GET";
  const devices = ctx.identity.devices;

  if (p === "/local/pairing/invites" && method === "POST") {
    if ((await readJson(req)) === undefined) return json(res, 400, { error: "bad_json" });
    const bridgePub = ctx.identity.bridgePub();
    if (!bridgePub) return json(res, 503, { error: "bridge_error" });
    // 中継が無いと、QR を読んだ端末がつなぎに行く先が無い。
    if (!ctx.relayURL) return json(res, 503, { error: "relay_not_configured" });
    const invite = ctx.invites.create();
    const url = invitePairUrl(invite, {
      bridgeId: ctx.identity.bridgeId,
      name: ctx.bridgeName(),
      relayURL: ctx.relayURL,
      relayId: ctx.identity.relayId,
      bridgePub
    });
    console.log("[devices] a pairing invite was created");
    return json(res, 201, { inviteId: invite.id, url, expiresAt: invite.expiresAt });
  }
  const inviteMatch = /^\/local\/pairing\/invites\/([^/]+)$/.exec(p);
  if (inviteMatch && method === "DELETE") {
    return ctx.invites.remove(decodeURIComponent(inviteMatch[1])) ? empty(res, 204) : json(res, 404, { error: "not_found" });
  }
  if (p === "/local/devices" && method === "GET") return json(res, 200, devicesView(ctx));
  if (p === "/local/devices/events" && method === "GET") {
    const sinceRaw = url.searchParams.get("since");
    const since = sinceRaw !== null && /^\d+$/.test(sinceRaw) ? Number(sinceRaw) : undefined;
    await devices.waitForChange(since, url.searchParams.get("boot") ?? undefined, ctx.eventsWaitMs ?? EVENTS_WAIT_MS);
    if (res.destroyed) return;
    return json(res, 200, devicesView(ctx));
  }
  const deviceMatch = /^\/local\/devices\/([^/]+)\/(revoke|rename)$/.exec(p);
  if (deviceMatch && method === "POST") {
    const id = decodeURIComponent(deviceMatch[1]);
    if (deviceMatch[2] === "revoke") {
      if ((await readJson(req)) === undefined) return json(res, 400, { error: "bad_json" });
      // lock の中（同期）で行を消して外した印を残してから、トンネル・プレビューのセッションを片付ける（PROTOCOL-v3 Appendix A）。
      if (!devices.revoke(id)) return json(res, 404, { error: "not_found" });
      ctx.forgetDevice(id);
      console.log(`[devices] removed ${id.slice(0, 8)}`);
      return json(res, 200, { ok: true });
    }
    const body = await readJson(req);
    if (body === undefined) return json(res, 400, { error: "bad_json" });
    const raw = typeof body.name === "string" ? body.name : "";
    const label = sanitizeName(raw, "") || null;
    const display = devices.rename(id, label);
    return display === undefined ? json(res, 404, { error: "not_found" }) : json(res, 200, { ok: true, display });
  }
  if (p === "/local/approvals/open" && method === "POST") {
    if ((await readJson(req)) === undefined) return json(res, 400, { error: "bad_json" });
    if (!devices.approvalsSetting) return json(res, 409, { error: "approvals_disabled" });
    return json(res, 200, { until: ctx.approvals.openWindow() });
  }
  if (p === "/local/approvals/close" && method === "POST") {
    ctx.approvals.closeWindow("closed");
    return empty(res, 204);
  }
  if (p === "/local/devices/pending/approve" && method === "POST") {
    const body = await readJson(req);
    if (body === undefined) return json(res, 400, { error: "bad_json" });
    const result = await ctx.approvals.submit(typeof body.code === "string" ? body.code : "");
    if (result.kind === "ok") console.log(`[devices] approved ${result.deviceKeyId.slice(0, 8)} on this PC`);
    return submitResponse(res, result);
  }
  const rejectMatch = /^\/local\/devices\/pending\/([^/]+)\/reject$/.exec(p);
  if (rejectMatch && method === "POST") {
    return ctx.approvals.reject(decodeURIComponent(rejectMatch[1])) ? json(res, 200, { ok: true }) : json(res, 404, { error: "not_found" });
  }
  if (p === "/local/devices/reset" && method === "POST") {
    const body = await readJson(req);
    if (body === undefined) return json(res, 400, { error: "bad_json" });
    // revoked_by_account は registry-hold の理由が revoked_by_account のときだけ（アカウントから外されたとき、デスクトップで「端末もすべて切断」を選んだ場合）。
    const reasons: string[] = ["user_reset", "account_removed"];
    if (readRegistryHold(ctx.identity.dir)?.reason === "revoked_by_account") reasons.push("revoked_by_account");
    if (typeof body.reason !== "string" || !reasons.includes(body.reason)) return json(res, 400, { error: "bad_reason" });
    ctx.identity.resetIdentity(body.reason as ResetReason);
    ctx.requestRegistration();
    return json(res, 200, { ok: true, bridgeId: ctx.identity.bridgeId });
  }
  if (p === "/local/devices/settings" && method === "POST") {
    const body = await readJson(req);
    const approvals = body?.approvalsEnabled;
    const remote = body?.remoteApprovalsEnabled;
    if (body === undefined || (typeof approvals !== "boolean" && typeof remote !== "boolean")) return json(res, 400, { error: "bad_json" });
    if (typeof approvals === "boolean") {
      devices.setApprovalsEnabled(approvals);
      // 「アカウントで見つけた PC からの承認」を切ったら、窓の申し込みも remote の申し込みも全部取り下げる（mac と同じ）。
      if (!approvals) {
        ctx.approvals.closeWindow("closed");
        ctx.approvals.closeRemote("closed");
      }
    }
    if (typeof remote === "boolean") {
      devices.setRemoteApprovalsEnabled(remote);
      // スマホからの許可を切ったら、remote の申し込みを全部 closed で取り下げる（spec/PROTOCOL-v3.md §10.4.1）。
      if (!remote) ctx.approvals.closeRemote("closed");
    }
    return json(res, 200, { ok: true });
  }
  if (p === "/local/registry/resume" && method === "POST") {
    clearRegistryHold(ctx.identity.dir);
    ctx.requestRegistration();
    return json(res, 200, { ok: true });
  }
  if (p === "/local/registry/previous/dismiss" && method === "POST") {
    clearRegistryPrevious(ctx.identity.dir);
    devices.bump();
    return empty(res, 204);
  }
  const orch = ctx.orchestrator;
  // 設定「ほかのエージェントに頼めるようにする」。切り替えは次に開くセッションから効く。
  if (p === "/local/orchestrator/settings" && orch) {
    if (method === "GET") return json(res, 200, { allSessions: orch.allSessions });
    if (method === "POST") {
      const body = await readJson(req);
      if (body === undefined || typeof body.allSessions !== "boolean") return json(res, 400, { error: "bad_request" });
      orch.setAllSessions(body.allSessions);
      console.log(`[mainagent] allSessions = ${body.allSessions}`);
      return json(res, 200, { ok: true });
    }
  }
  // 別の PC の中継口の一覧。毎回まるごと置き換える。合言葉を含むのでログには数だけ出す。
  if (p === "/local/remote-pcs" && method === "PUT" && orch) {
    const pcs = parseRemotePcs(await readJson(req, REMOTE_PCS_LIMIT));
    // 形の違う行が 1 つでもあれば、まるごと断って前の一覧のままにする（mac と同じ）。
    if (pcs === undefined) return json(res, 400, { error: "bad_request" });
    orch.setRemotePcs(pcs);
    console.log(`[mainagent] remote PCs: ${pcs.length}`);
    return empty(res, 204);
  }
  return json(res, 404, { error: "not_found" });
}

/** /device/*（PROTOCOL-v3 §13.5）。principal は .device。 */
export async function handleDeviceRoute(
  req: http.IncomingMessage,
  res: http.ServerResponse,
  url: URL,
  principal: Extract<Principal, { kind: "device" }>,
  ctx: LocalRoutesContext
): Promise<void> {
  const devices = ctx.identity.devices;
  const id = principal.deviceKeyId;
  if (url.pathname === "/device/self" && req.method === "GET") {
    const row = devices.get(id);
    if (!row) return json(res, 401, { error: "unauthorized" });
    return json(res, 200, { deviceKeyId: id, display: displayName(row.label ?? row.name, id), platform: row.platform, createdAt: row.createdAt });
  }
  if (url.pathname === "/device/unpair" && req.method === "POST") {
    // 受けた時点で解除中にする（新しい connect は revoked、新しい HTTP は 401）。応答を返してから 1 秒後に行を消す。
    if (!devices.markUnpairing(id)) return json(res, 401, { error: "unauthorized" });
    json(res, 200, { ok: true });
    const timer = setTimeout(() => {
      devices.removeUnpairing(id);
      ctx.forgetDevice(id);
      console.log(`[devices] ${id.slice(0, 8)} unpaired itself`);
    }, ctx.unpairDelayMs ?? UNPAIR_DELAY_MS);
    timer.unref?.();
    return;
  }
  // スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）。許可できる端末（確定済みの ios・android）だけ。ログには deviceKeyId の先頭 8 文字だけ。
  if (url.pathname === "/device/approvals" && req.method === "GET") {
    if (!devices.isApprover(id)) return json(res, 403, { error: "not_approver" });
    if (!devices.remoteApprovalsEnabled) return json(res, 200, { pending: [], enabled: false });
    return json(res, 200, { pending: pendingViews(ctx), enabled: true });
  }
  if (url.pathname === "/device/approvals/approve" && req.method === "POST") {
    const body = await readJson(req);
    if (!devices.isApprover(id)) return json(res, 403, { error: "not_approver" });
    if (!devices.remoteApprovalsEnabled) return json(res, 409, { error: "disabled" });
    if (body === undefined) return json(res, 400, { error: "bad_json" });
    const result = await ctx.approvals.submit(typeof body.code === "string" ? body.code : "", id);
    if (result.kind === "ok") console.log(`[devices] ${id.slice(0, 8)} approved ${result.deviceKeyId.slice(0, 8)} from the phone`);
    return submitResponse(res, result);
  }
  // 別の PC（A）から頼まれる口と、全部の PC の一覧。どの端末でも呼べる。
  const toolMatch = /^\/device\/orchestrator\/([^/]+)$/.exec(url.pathname);
  if (toolMatch && ctx.orchestrator) return handleDeviceOrchestrator(req, res, decodeURIComponent(toolMatch[1]), id, ctx.orchestrator);
  if (url.pathname === "/device/sessions/summary" && ctx.orchestrator) return handleSessionsSummary(req, res, ctx.orchestrator);
  const rejectMatch = /^\/device\/approvals\/([^/]+)\/reject$/.exec(url.pathname);
  if (rejectMatch && req.method === "POST") {
    if ((await readJson(req)) === undefined) return json(res, 400, { error: "bad_json" });
    if (!devices.isApprover(id)) return json(res, 403, { error: "not_approver" });
    if (!devices.remoteApprovalsEnabled) return json(res, 409, { error: "disabled" });
    if (!ctx.approvals.reject(decodeURIComponent(rejectMatch[1]))) return json(res, 404, { error: "not_found" });
    console.log(`[devices] ${id.slice(0, 8)} rejected a pending device from the phone`);
    return json(res, 200, { ok: true });
  }
  return json(res, 404, { error: "not_found" });
}

/** 本文（既定 4 KB まで）を JSON のオブジェクトとして読む。空なら {}。読めなければ undefined。 */
async function readJson(req: http.IncomingMessage, limit = BODY_LIMIT): Promise<Record<string, unknown> | undefined> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string);
    size += buf.length;
    if (size > limit) return undefined;
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

function json(res: http.ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "content-length": Buffer.byteLength(text) });
  res.end(text);
}

function empty(res: http.ServerResponse, status: number): void {
  res.writeHead(status, { "cache-control": "no-store" });
  res.end();
}
