import crypto from "node:crypto";
import http from "node:http";
import type { AddressInfo } from "node:net";
import os from "node:os";
import path from "node:path";
import { WebSocket, WebSocketServer, type RawData } from "ws";
import { LISTEN_HOST, type BridgeConfig } from "./config.js";
import { deriveWSKeys, publicKey, E2ECryptoError, E2EFrameReceiver, E2EFrameSender } from "./e2e.js";
import { AdminKey, authorizeRoute, denialBody, routeAccess, TunnelPeers, tunnelOrigin, principalFor, type AuthContext, type Principal, type RouteAccess } from "./auth.js";
import { ApprovalQueue } from "./approvalQueue.js";
import type { DeviceStore } from "./deviceStore.js";
import { handleDeviceRoute, handleLocalRoute, type LocalRoutesContext } from "./localRoutes.js";
import { PairingInvites } from "./pairingInvites.js";
import { BRIDGE_NAME_FALLBACK, displayName, sanitizeName } from "./tunnelV3.js";
import { event, stopReason, type SessionEvent } from "./protocol.js";
import { pickWhereResult, resolveRuntime, resolveWinPath, type RuntimeCommand } from "./runtime/command.js";
import { systemExe } from "./runtime/systemExe.js";
import type { JsonSessionStore } from "./sessionStore.js";
import { ClaudeCodeAdapter } from "./agents/claudeCode.js";
import { resolveClaudeSessionCwd } from "./agents/claudeProfile.js";
import { ANTIGRAVITY_PROFILE, CURSOR_PROFILE, GROK_PROFILE, HeadlessCliAdapter } from "./agents/headlessCli.js";
import { CodexHistoryAdapter } from "./agents/codexHistory.js";
import { EchoAdapter } from "./agents/echo.js";
import { HermesAcpAdapter } from "./agents/hermesAcp.js";
import { OpenclawAcpAdapter } from "./agents/openclaw.js";
import { OpenCodeAcpAdapter } from "./agents/opencodeAcp.js";
import { BuddyAdapter } from "./agents/buddy.js";
import { imageAttachments, parseChatOverrides, type AgentAdapter, type AgentSession, type Emit, type SessionOptions, type StopTaskOutcome } from "./agents/types.js";
import { historyAttachmentMetadata, putImage, restoreHistoryImages, type HistoryMessageWithImages } from "./agents/attachmentStore.js";
import { agentsOrWorkflows, anyBackground, WorkflowCardMirror, type CardCounts } from "./workflowCardMirror.js";
import { stripVoiceContext, voiceTurnFrom, withVoiceContext } from "./agents/voiceTurn.js";
import { clearProbeCache, execRuntime, probeAgent, wslWindowsPath, type ProbeResult } from "./agentProbe.js";
import { deleteMcp, listMcp, mcpRegisterSupported, registerMcp, type McpRegisterSpec } from "./mcpService.js";
import { dropPreviewSessions, handlePreview, previewOwner, type PreviewAuth } from "./preview.js";
import { listOpencodeSkills, loadOpencodeSkill } from "./agents/opencodeSkills.js";
import { PushService } from "./pushService.js";
import { convexSite, readDeviceToken } from "./registry.js";
import { RELAY_HINT, resolvePushMode } from "./settings.js";
import { gitBranch } from "./gitInfo.js";
import { FAILURE_STATUS, FILES_MARKER_HEADER, loadProjectImage } from "./projectFiles.js";
import { createBridgeServices, type BridgeServices } from "./services.js";
import type { SiteList } from "./sites.js";
import { cronBackend, type CronOp } from "./cron/cronService.js";
import { deleteSkill, listSkills, loadSkill, saveSkill } from "./skills.js";
import type { ProjectItem } from "./projects.js";
import { loginStatusEvent, loginSupported } from "./agentLogin.js";
import { extensionsList, extensionsSync } from "./extensionsShare.js";
import { ClaudeChannelInbox } from "./terminal/channelInbox.js";
import { ClaudeTerminalRegistry, ClaudeTerminalSession, isTypedByUser, markTypedByUser } from "./terminal/claudeTerminal.js";
import { ClaudeBackgroundSession, findHolder } from "./terminal/claudeBackgroundSession.js";
import type { ClaudeBackgroundJobs } from "./terminal/claudeBackgroundJobs.js";
import { TerminalKeyRouter } from "./terminal/keys.js";
import { TerminalPaneStatus } from "./terminal/paneStatus.js";
import { handleTerminalRoute, type TerminalServices } from "./terminal/routes.js";
import { handleAgentTerminalRoute } from "./terminal/agentRoutes.js";
import { agyApprovals } from "./agents/agyApproval.js";
import { OpenCodeServe } from "./agents/opencodeServe.js";
import { dropPtySessions, handlePtyUpgrade, ptyAvailable } from "./terminal/ptyRoute.js";
import { dropShareViewers, handleShareHostUpgrade, handleShareViewerUpgrade, sharePanes } from "./terminal/shareRoute.js";
import { forbiddenBody, guardRejection } from "./originGuard.js";
import { trafficMeter } from "./trafficMeter.js";
import { codexStrength, modeStrength, orchestrator, type HubSubscription, type LiveSessionInfo, type OrchestratorHub } from "./mainagent/orchestrator.js";
import { handleMcpRequest, mainAgentRouteDenial } from "./mainagent/mcpEndpoint.js";
import { isMainWorkspace, mainAgentRoot, setMainAgentPort } from "./mainagent/workspace.js";
import { defaultHeartbeatDir, HeartbeatService } from "./mainagent/heartbeat.js";
import { claudeDefaultMode } from "./agents/claudeCode.js";

export interface BridgeServer {
  server: http.Server;
  adapters: Map<string, AgentAdapter>;
  /** 端末の一覧（identity.devices と同じ）。Paseo 中継のトンネルも同じものを使う。 */
  devices: DeviceStore;
  /** トンネル経由の TCP の送り元の番号 → 端末（paseoRelay.ts が入れ、HTTP の認証が引く。spec/PROTOCOL-v3.md §13.1）。 */
  peers: TunnelPeers;
  /** QR・リンクの招待（メモリだけ）。 */
  invites: PairingInvites;
  /** アカウントで見つけた PC からの承認待ち（メモリだけ。Paseo 中継のトンネルと /local・/device の口で共有する）。 */
  approvals: ApprovalQueue;
  /** 管理鍵（index.ts が stdin から読んで入れる。PROTOCOL-v3 Appendix A）。 */
  admin: AdminKey;
  /** PC の名前（PROTOCOL-v3 §5.3 で無害化済み）。 */
  bridgeName(): string;
  /** 中継のトンネルをつなぐ（端末の接続中の表示と、端末を外したときにトンネルを閉じるため）。 */
  attachTunnel(tunnel: { isOnline(deviceKeyId: string): boolean; closeTunnels(deviceKeyId: string): void }): void;
  /** 接続をまたぐ常駐機能（cron 等）。 */
  services: BridgeServices;
  /** APNs push（Convex の /v3/push を端末トークンで。登録簿に初めて載ったら宛先を登録し直す）。 */
  push: PushService;
  /** /local/devices/reset・/local/registry/resume の後に登録し直す先（index.ts が BridgeRegistry をつなぐ）。 */
  setRegistrationHandler(handler: () => void): void;
  /** mainagent の orchestrator に渡した口（テストで別の Orchestrator にもつなぐ）。 */
  mainagentHub: OrchestratorHub;
  start(): Promise<void>;
  /** 動いている session（エージェントの子プロセス）をすべて閉じる（止めるとき）。 */
  closeSessions(): Promise<void>;
}

/**
 * PR #7（Windows 対応）で足したルートのうち、auth.ts の ROUTES にまだ無いもの。表と同じく authorizeRoute の
 * Principal で確かめる（?apiKey= の扱いも表と同じ）。auth.ts の ROUTES へ移したら消す。
 */
const EXTRA_ROUTES: ReadonlyArray<{ pattern: RegExp; access: RouteAccess }> = [
  // プロジェクトの中の画像（iPhone はトンネル越しに端末の鍵で読む）。
  { pattern: /^\/files\/image$/, access: "any" },
  // buddy-codex の中継（この PC の中からローカル鍵で）。
  { pattern: /^\/codex\/terminal$/, access: "local" }
];

function extraRouteAccess(pathname: string): RouteAccess | undefined {
  return EXTRA_ROUTES.find((r) => r.pattern.test(pathname))?.access;
}

export function createBridgeServer(config: BridgeConfig, store: JsonSessionStore): BridgeServer {
  const adapters = createAdapters(config, store);
  // 端末認証 v3（spec/PROTOCOL-v3.md）。身元（静的鍵・ローカル鍵）は作り直しで変わるので、
  // 起動時の値を閉じ込めず、使うたびに identity から読む。
  const identity = config.identity;
  const devices = identity.devices;
  const peers = new TunnelPeers();
  const admin = new AdminKey();
  const invites = new PairingInvites({ onChange: () => devices.bump() });
  const approvals = new ApprovalQueue();
  approvals.onChange = () => devices.bump();
  const bridgeName = (): string => sanitizeName(os.hostname(), BRIDGE_NAME_FALLBACK);
  let tunnel: { isOnline(deviceKeyId: string): boolean; closeTunnels(deviceKeyId: string): void } | undefined;
  let registrationHandler: (() => void) | undefined;
  const authCtx: AuthContext = {
    peers,
    devices,
    localKey: () => identity.localKey(),
    admin,
    listenPort: () => (server.address() as AddressInfo | null)?.port
  };
  // 端末を外した・解除したときの片付け（PROTOCOL-v3 Appendix A）: その端末のトンネルとプレビューのセッション。
  const forgetDevice = (deviceKeyId: string): void => {
    tunnel?.closeTunnels(deviceKeyId);
    dropPreviewSessions(`device:${deviceKeyId}`);
    // その端末が開いたターミナルも止める（外した端末に 24 時間シェルを残さない）。
    dropPtySessions(`device:${deviceKeyId}`);
    dropShareViewers(`device:${deviceKeyId}`);
  };
  // 「すべての端末を切断」などの作り直し（PROTOCOL-v3 Appendix A）: 招待とプレビューのセッションを全部捨てる（トンネルは index.ts が張り直す）。
  identity.onReset(() => {
    invites.clear();
    approvals.resetAll();
    dropPreviewSessions();
    dropPtySessions();
    dropShareViewers();
  });
  const localCtx: LocalRoutesContext = {
    identity,
    invites,
    approvals,
    relayURL: config.paseoRelayURL,
    bridgeName,
    isOnline: (deviceKeyId) => tunnel?.isOnline(deviceKeyId) ?? false,
    forgetDevice,
    requestRegistration: () => registrationHandler?.(),
    orchestrator
  };
  const previewAuth: PreviewAuth = {
    bearer: (req, url) => principalFor(req, url, authCtx, { allowQuery: false }),
    origin: (req) => {
      const peer = tunnelOrigin(req, authCtx);
      return peer ? `device:${peer.deviceKeyId}` : "local";
    }
  };
  const server = http.createServer((req, res) => {
    // ブラウザ（プレビュー中のページ・別のサイト）からの要求は、本文を読む前に断る（originGuard.ts。Host は全ルート、
    // Origin はプレビューのセッションで認証するルート以外）。
    const rejection = guardRejection(req);
    if (rejection) {
      res.writeHead(403, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
      res.end(forbiddenBody(rejection));
      return;
    }
    // Live Preview ルート（/preview/*）の URL を先に組み立てておく。
    // テンプレートリテラルのバッククォートは使わず文字列連結で作る。
    const url = new URL(req.url ?? "/", "http://" + (req.headers.host ?? "localhost"));
    // ルートの表（auth.ts の ROUTES）に無いパスは認証の前に 404。表にあるルートは Principal で確かめる
    // （トンネル経由なら端末の bdc_、この PC の中からならローカル鍵。PROTOCOL-v3 §13.2・§13.3）。/preview/* は preview.ts が確かめる。
    // ルートはクエリ付き（/status?fresh=1 等）でも一致するよう req.url の完全一致ではなく pathname で判定する。
    // agy の承認 hook（Bridge が起こした agy の PreToolUse hook）。資格情報はターンごとの合言葉（X-BuddyOS-Hook-Token。
    // agyApprovals が確かめる）で、この PC の中からだけ受ける（トンネル経由は 403。/mcp と同じ考え方）。
    if (url.pathname === "/antigravity/hook") {
      if (tunnelOrigin(req, authCtx)) {
        req.resume();
        res.writeHead(403, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
        res.end(denialBody({ status: 403, error: "local_only" }));
        return;
      }
    }
    const access = url.pathname === "/antigravity/hook" ? "hook" : (routeAccess(url.pathname, false) ?? extraRouteAccess(url.pathname));
    if (!access) {
      res.writeHead(404, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
      res.end(JSON.stringify({ error: "not_found" }));
      return;
    }
    // mainagent の道具（POST /mcp）。この PC の中の CLI だけが、セッションごとの合鍵（Bearer bmt_…）で呼ぶ。
    // トンネル経由は 403 local_only、?apiKey= は 401（mac の BridgeAuth の .mainAgentToken と同じ）。
    if (access === "mainagent") {
      const denial = mainAgentRouteDenial(req, url, authCtx);
      if (denial) {
        req.resume();
        res.writeHead(denial.status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
        res.end(denialBody(denial));
        return;
      }
      void handleMcpRequest(req, res, orchestrator).catch(() => {
        if (!res.headersSent) {
          res.writeHead(500);
          res.end("mcp error");
        }
      });
      return;
    }
    let principal: Principal | undefined;
    if (access !== "preview" && access !== "hook") {
      const checked = authorizeRoute(req, url, authCtx, access);
      if ("denial" in checked) {
        res.writeHead(checked.denial.status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
        res.end(denialBody(checked.denial));
        return;
      }
      principal = checked.principal;
    }
    // 端末の管理（/local/*。この PC のデスクトップアプリ ＋管理鍵）と、端末の自己管理（/device/*。トンネル経由の端末）。
    if (url.pathname.startsWith("/local/") || url.pathname.startsWith("/device/")) {
      void (async () => {
        if (principal?.kind === "device") await handleDeviceRoute(req, res, url, principal, localCtx);
        else await handleLocalRoute(req, res, url, localCtx);
      })().catch(() => {
        if (!res.headersSent) {
          res.writeHead(500);
          res.end("error");
        }
      });
      return;
    }
    if (url.pathname === "/health") {
      void (async () => {
        const agents = await Promise.all(
          [...adapters.values()].map(async (adapter) => ({
            id: adapter.id,
            displayName: adapter.displayName,
            runtime: adapter.runtimeLabel,
            capabilities: capabilitiesFor(adapter, services.bgSessions.capable),
            // installed/configured/version を載せて iOS 側の readiness gate を機能させる。
            // 未インストール or echo フォールバック中のエージェントをグレーアウトさせる
            // （probeAgent は実バイナリ/設定実体を見るので echo 偽装も検出できる）。
            // runtimeLabel を渡し、WSL で動く adapter は WSL 側で、native は adapter が実際に使う
            // 解決済みパスで判定する（Windows 側 PATH だけを見ると WSL 版がグレーアウトされる）。
            ...(await probeAgent(adapter.id, adapter.runtimeLabel))
          }))
        );
        // e2e フィールドは互換のため残す。端末はこれを見て固定した鍵を変えない（spec/PROTOCOL-v3.md §13.7）。
        // "auth-v3" = 端末認証 v3 の Bridge（デスクトップが見分ける）。
        const pub = identity.bridgePub();
        const body = JSON.stringify({
          ok: true,
          bridgeId: config.bridgeId,
          adapters: [...adapters.keys()],
          agents,
          ...(pub ? { e2e: { v: 1, pub: pub.toString("base64url") } } : {}),
          // できること。"terminal" = /terminal/pty（別の PC のデスクトップからこの PC のターミナルを操作できる）。
          // "sites" = sites_request に答えられる。"heartbeat" = メインの定期チェック（heartbeat_get / set / run_now）。
          // "terminal-share" = /terminal/share（相手の PC で開いているペインを見る。node-pty の有無にかかわらず出す）。
          features: ptyAvailable()
            ? ["terminal", "terminal-share", "auth-v3", "sites", "heartbeat"]
            : ["terminal-share", "auth-v3", "sites", "heartbeat"],
          // 可観測性（mac と同じ）。プロセスの稼働秒数と、生きている会話（子プロセス・ACP 接続・ターミナル）の数。
          uptimeSeconds: Math.floor(process.uptime()),
          aliveSessions: liveSessions.size,
          // 中継が設定されていないときだけ載せる（中継につながっていない理由と直し方）。
          ...(config.paseoRelayURL ? {} : { relay: { configured: false, hint: RELAY_HINT } })
        });
        // mac（Vapor）と同じく Content-Length を付ける（中継越しの疎通確認 scripts/paseo-health-check.mts が読む）。
        trafficMeter.record("http.health.out", Buffer.byteLength(body));
        res.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
        res.end(body);
      })().catch(() => {
        if (!res.headersSent) {
          res.writeHead(500);
          res.end("health error");
        }
      });
      return;
    }
    if (url.pathname === "/status") {
      // Probed setup state (installed / configured / version) for the desktop
      // dashboard. Mirrors the mac-bridge /status shape.
      // desktop はインストール直後・再確認で ?fresh=1 を付ける（mac と同じく "1" / "true"）。
      const freshParam = url.searchParams.get("fresh");
      const fresh = freshParam === "1" || freshParam === "true";
      void (async () => {
        // fresh は probe のキャッシュ（TTL 15 秒 / WSL 60 秒）も捨てて、新しく入れたエージェントを即反映する。
        // desktop は 4 秒で打ち切って再送するので、直前の fresh と同じ再判定なら捨て直さず、そこで始まった
        // probe・得た結果を使い回す（beginFreshProbe / sharedProbe）。
        const reprobe = fresh && beginFreshProbe();
        const runtimeEnv: Record<string, string | undefined> = {
          hermes: process.env.HERMES_BIN,
          claude: process.env.CLAUDE_BIN,
          codex: process.env.CODEX_BIN,
          openclaw: process.env.OPENCLAW_BIN,
          opencode: process.env.OPENCODE_BIN
        };
        const agents = await Promise.all(
          [...adapters.values()].map(async (adapter) => {
            const base = adapter.id.split("-")[0];
            const hasRuntimes = base in runtimeEnv;
            return {
              id: adapter.id,
              displayName: adapter.displayName,
              capabilities: capabilitiesFor(adapter, services.bgSessions.capable),
              // native / wsl 両対応エージェントは選択肢と現在の実行環境を返す
              // （デスクトップの実行環境セレクタ用。mac-bridge は返さない）。
              ...(hasRuntimes
                ? {
                    availableRuntimes: await availableRuntimes(base, runtimeEnv[base], config.wslDistro, reprobe),
                    activeRuntime: adapter.runtimeLabel.startsWith("wsl:") ? "wsl" : "native"
                  }
                : {}),
              ...(await sharedProbe(adapter.id, adapter.runtimeLabel, fresh))
            };
          })
        );
        const statusBody = JSON.stringify({ ok: true, bridgeId: config.bridgeId, agents });
        trafficMeter.record("http.status.out", Buffer.byteLength(statusBody));
        res.writeHead(200, { "content-type": "application/json" });
        res.end(statusBody);
      })().catch(() => {
        if (!res.headersSent) {
          res.writeHead(500);
          res.end("status error");
        }
      });
      return;
    }
    // Live Preview（WEB-LOCAL リバースプロキシ）を 404 フォールスルー前に処理。
    if (url.pathname.startsWith("/preview/")) {
      void (async () => {
        if (await handlePreview(req, res, url, previewAuth)) return;
        res.writeHead(404);
        res.end("not found");
      })().catch(() => {
        if (!res.headersSent) {
          res.writeHead(500);
          res.end("preview error");
        }
      });
      return;
    }
    // プロジェクトの中の画像（返事に出てくる docs/shot.png 等をチャットの中で見る。mac の ProjectFileRoutes と同じ）。
    if (url.pathname === "/files/image") {
      void (async () => {
        const wsl: RuntimeCommand = { kind: "wsl", executable: "sh", label: "wsl:sh", shell: false, wslDistro: config.wslDistro };
        const result = await loadProjectImage(
          url.searchParams.get("path") ?? "",
          url.searchParams.get("cwd") ?? undefined,
          services.projects.list().map((p) => p.path),
          undefined,
          (p) => wslWindowsPath(wsl, `wslpath -w '${p.replace(/'/g, "'\\''")}'`)
        );
        if (result.ok) {
          trafficMeter.record("files.image.out", result.data.length);
          const headers: Record<string, string> = {
            "content-type": result.mime,
            "cache-control": "private, max-age=60",
            "x-content-type-options": "nosniff",
            [FILES_MARKER_HEADER]: "1"
          };
          // SVG は文書なので、万一ブラウザで開かれてもスクリプトや外部の読み込みを動かさない。
          if (result.mime === "image/svg+xml") headers["content-security-policy"] = "default-src 'none'; style-src 'unsafe-inline'; sandbox";
          res.writeHead(200, headers);
          res.end(result.data);
          return;
        }
        // 端末はこのヘッダの有無で「ファイルが無い」と「Bridge が古くてこの入口が無い」を見分ける。
        res.writeHead(FAILURE_STATUS[result.failure], { "content-type": "application/json", "cache-control": "no-store", [FILES_MARKER_HEADER]: "1" });
        res.end(JSON.stringify({ error: result.failure }));
      })().catch(() => {
        if (!res.headersSent) {
          res.writeHead(500, { [FILES_MARKER_HEADER]: "1" });
          res.end("files error");
        }
      });
      return;
    }
    // 通信量（件数とバイト数だけ）と、通知のテスト送信（mac と同じ）。
    if (url.pathname === "/traffic" || url.pathname === "/traffic/reset" || url.pathname === "/push-test") {
      void (async () => {
        let body: unknown;
        if (url.pathname === "/push-test") {
          const r = await pushService.sendTest();
          body = { ok: !r.error && r.registered > 0, registered: r.registered, remaining: r.remaining, error: r.error ?? null };
        } else if (url.pathname === "/traffic/reset" && req.method === "POST") {
          body = trafficMeter.reset();
        } else if (url.pathname === "/traffic") {
          body = trafficMeter.snapshot();
        } else {
          res.writeHead(404);
          res.end("not found");
          return;
        }
        res.writeHead(200, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
        res.end(JSON.stringify(body));
      })().catch(() => {
        if (!res.headersSent) {
          res.writeHead(500);
          res.end("error");
        }
      });
      return;
    }
    // Codex / Antigravity のターミナル連携（buddy-codex の中継はローカル鍵、agy の承認 hook はターンごとのトークン）。
    if (url.pathname === "/codex/terminal" || url.pathname === "/antigravity/hook") {
      void (async () => {
        if (await handleAgentTerminalRoute(req, res, url)) return;
        res.writeHead(404);
        res.end("not found");
      })().catch(() => {
        if (!res.headersSent) {
          res.writeHead(500);
          res.end("terminal error");
        }
      });
      return;
    }
    // 見られるペインの一覧（docs/PANE_SHARE_2026-10-25.md）。鍵はヘッダだけ（ルートの表の any は ?apiKey= も通すので、ここで断る）。
    if (url.pathname === "/terminal/share/panes") {
      req.resume();
      let status = 200;
      let body: string;
      if (url.searchParams.has("apiKey")) {
        status = 401;
        body = denialBody({ status: 401, error: "unauthorized" });
      } else if (req.method !== "GET") {
        status = 404;
        body = JSON.stringify({ error: "not_found" });
      } else body = JSON.stringify(sharePanes((p) => panes.stateOfPane(p)));
      res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "content-length": Buffer.byteLength(body) });
      res.end(body);
      return;
    }
    // ターミナル連携（Claude Code の hook・channel、デスクトップのキー入力・ペインの状態）。
    if (url.pathname.startsWith("/claude/") || url.pathname.startsWith("/terminal/")) {
      void (async () => {
        if (await handleTerminalRoute(req, res, url, terminal)) return;
        res.writeHead(404);
        res.end("not found");
      })().catch(() => {
        if (!res.headersSent) {
          res.writeHead(500);
          res.end("terminal error");
        }
      });
      return;
    }
    res.writeHead(404);
    res.end("not found");
  });

  const wss = new WebSocketServer({ noServer: true, maxPayload: 10 * 1024 * 1024 });
  const liveSessions = new Map<string, AgentSession>();
  const liveHistory = new LiveHistoryIndex();
  // session key (`${agentId}:${sessionId}`) ごとの生購読者。セッションの出力はここから購読者全員へ配る。
  // 最後の購読者が切れて猶予後も誰も掴み直さなければ、その session の子プロセスを dispose する。
  const subscribers = new SessionSubscribers();
  // APNs push（relay 経由）。env 未設定なら Convex の /push を端末トークンで使う（mac と同じ）。
  // confirmed E2E デバイス宛はデバイス毎に暗号化して送るため鍵素材と登録簿を渡す（PROTOCOL-v3 §14）。
  // 宛先は端末の行の push。すべて端末ごとの鍵で封をして送る（平文の本文は送らない。PROTOCOL-v3 §14）。
  // env が無ければ Convex の /v3/push を端末トークンで使う（mac と同じ。宛先は /v3/push-targets で登録する）。
  // BUDDYOS_PUSH_MODE=none・登録簿のサイトが無いときは既定の relay を使わない（settings.ts）。
  const pushSite = convexSite();
  const pushService = new PushService(
    { bridgeId: () => identity.bridgeId, privateKey: () => identity.e2eKey, devices },
    pushSite
      ? {
          url: `${pushSite}/v3/push`,
          targetsUrl: `${pushSite}/v3/push-targets`,
          liveActivityTargetsUrl: `${pushSite}/v3/live-activity-targets`,
          liveActivityUrl: `${pushSite}/v3/live-activity`,
          token: () => readDeviceToken(config.configDir)
        }
      : undefined,
    resolvePushMode().value
  );
  // スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）: remote の承認待ちを作ったら、許可できる端末にだけ E2E の push を 1 回。
  approvals.onRemoteAdded = (pending) => void pushService.sendPairRequest(pending.pendingId, pending.display, bridgeName());
  const services = createBridgeServices(config, adapters, pushService);
  // claude --bg の完了の push は、その会話を開いている人も Bridge の session も無いときだけ出す。
  services.bgSessions.attach({
    buddyTitle: (sid) => store.titles.title("claude", sid),
    hasWatchers: (sid) => subscribers.count(`claude:${sid}`) > 0,
    hasLiveSession: (sid) => liveSessions.has(`claude:${sid}`)
  });
  server.on("close", () => services.stop());
  // バックグラウンドのサブエージェントか dynamic workflow が動いている間も、PC のアイドルスリープを止める（mac の SessionHub と
  // SleepGuard と同じ。開いている session のカードの写しで数える）。バックグラウンドのコマンドだけでは止めない
  // （dev サーバーで眠れなくなるため）。
  liveHistory.onCardsChanged = () => {
    let active = false;
    for (const [key, session] of liveSessions) {
      const counts = liveHistory.cards(key.slice(0, key.indexOf(":")), session.sessionId)?.counts;
      if (counts && agentsOrWorkflows(counts)) {
        active = true;
        break;
      }
    }
    services.sleep.setActive(active, "background");
    noteHubCounts();
  };
  // Live Activity の数（出どころ hub）: 開いている session ごとに、終わっていない dynamic workflow + 行の数。
  // 行は、ターン中なら background の行だけ、そうでなければ動いている行の全部（BACKGROUND_CONTROL §8.2）。
  // 数えた session の liveHistory の key（閉じた直後の release でも「数えていた」と分かるよう、前回の分を覚える）。
  let hubCounted = new Set<string>();
  const noteHubCounts = (): void => {
    const counts: Record<string, number> = {};
    const counted = new Set<string>();
    for (const [key, session] of liveSessions) {
      const agentId = key.slice(0, key.indexOf(":"));
      counted.add(`${agentId}:${session.sessionId}`);
      const c = liveHistory.cards(agentId, session.sessionId)?.counts;
      if (!c) continue;
      const n = c.workflows + (liveHistory.inTurn(agentId, session.sessionId) ? c.backgroundOnlyAgents : c.agents);
      const id = session.sessionId || `hub:${key}`;
      if (n > 0) counts[id] = Math.max(counts[id] ?? 0, n);
    }
    hubCounted = counted;
    services.liveActivity.noteSource("hub", counts);
  };
  // 数えていない session（BuddyOS が開いていない端末の Claude など）の終わりは、別の batch の終わり方を変えないよう渡さない。
  liveHistory.isCounted = (key) => hubCounted.has(key) || liveSessions.has(key);
  liveHistory.onFinished = (finished) => services.liveActivity.noteFinished(finished);
  // ターンが進んでいる間も止める（mac の SleepGuard は生成中を数える）。送信の待ち（sessions）だけでは、知らせのターン
  // （CLI が自分から始めたターン）と、差し込んだ発話が result の後の別ターンとして走る間に眠れてしまう。
  liveHistory.onTurnsChanged = () => {
    services.sleep.setActive(liveHistory.anyTurnInProgress, "turns");
    noteHubCounts();
  };
  // agy の承認 hook が問い合わせる先。ターミナルの OpenCode と共有する serve は Bridge と一緒に止める。
  agyApprovals.port = config.port;
  server.on("close", () => OpenCodeServe.stop());

  // ターミナルの Claude Code（hook で見る・channel / 受け箱で送る）。イベントは "claude:<sid>" の購読者へ配り、
  // 再接続の差分用に記録する。ターミナルで打ったターンの完了は push しない（承認待ちだけ、見ている人がいなければ知らせる）。
  const publishClaude = (evt: SessionEvent): void => {
    const withSeq = liveHistory.record(evt);
    subscribers.deliver(`claude:${evt.sessionId}`, withSeq);
  };
  // claude --bg の会話の出力。ターミナルの発話と違い、Bridge が握っているワーカーのターンは Mac と同じく、誰も見ていなければ
  // 完了を push する（pending の done は留め置く。直前にジョブ側が出した push と重ならないよう間隔は共有する）。
  const publishBgSession = (evt: SessionEvent): void => {
    const held = evt.type === "done" && evt.metadata?.pending === "1";
    const key = `claude:${evt.sessionId}`;
    const withSeq = liveHistory.record(evt, held);
    if (evt.type === "done" && !held && evt.metadata?.silent !== "1") cancelDeferredPush(key);
    if (subscribers.deliver(key, withSeq) > 0 || held || evt.type !== "done" || evt.metadata?.silent === "1") return;
    if (!pushService.enabled || !evt.sessionId || !services.bgSessions.claimPush(evt.sessionId)) return;
    const body = liveHistory.lastBubble("claude", evt.sessionId) ?? "新しい応答があります";
    void pushService.broadcast("Claude Code", body, { kind: "chat", agentId: "claude", sessionId: evt.sessionId, bridgeId: config.bridgeId }).catch(() => {});
  };
  services.publishClaude = publishBgSession;
  const claudeAdapter = adapters.get("claude");
  if (claudeAdapter instanceof ClaudeCodeAdapter) {
    claudeAdapter.attachBackground({ isJob: (sid) => services.bgSessions.entryFor(sid) !== undefined, refresh: () => void services.bgSessions.refresh(), ready: () => services.bgSessions.ready() });
  }
  const inbox = new ClaudeChannelInbox();
  const keys = new TerminalKeyRouter();
  const panes = new TerminalPaneStatus();
  panes.onBackgroundChanged = () => services.liveActivity.noteSource("panes", panes.liveActivityCounts());
  const registry = new ClaudeTerminalRegistry({
    publish: publishClaude,
    push: (title, body, data) => void pushService.broadcast(title, body, data),
    watchers: (sid) => subscribers.count(`claude:${sid}`),
    isBackgroundWorker: (sid) => services.bgSessions.isBackgroundWorker(sid),
    inbox,
    keys,
    panes,
    bridgeId: config.bridgeId,
    persistFile: path.join(config.configDir, "claude-terminals.json")
  });
  const terminal: TerminalServices = {
    registry,
    inbox,
    keys,
    panes,
    // 同じ会話を 2 つのプロセスが持つと静かに二股になるので、ターミナルが開いたら Bridge が起こした方を止める。
    handOver: (sid) => {
      const key = `claude:${sid}`;
      const existing = liveSessions.get(key);
      if (!existing || existing instanceof ClaudeTerminalSession) return false;
      void Promise.resolve(existing.interrupt?.()).catch(() => {});
      void Promise.resolve(existing.close()).catch(() => {});
      const t = liveHistory.currentTurn("claude", sid);
      if (t) registry.publishDone(sid, t.messageId);
      liveSessions.set(key, new ClaudeTerminalSession(sid, registry, inbox));
      // 引き継いだ購読者のサブエージェントのカードを、ターミナルのトラッカーの全行（行が無くても epoch 付き）に置き換える
      // （止めた spawn 側の行を「実行中」のまま残さない。mac の SessionHub.closeSession と同じ）。
      const snapshot = registry.subagentSnapshot(sid);
      if (snapshot) {
        liveHistory.adoptSubagents("claude", sid, snapshot);
        subscribers.deliver(key, event.workflowProgress("claude", sid, snapshot));
      }
      return true;
    }
  };
  services.terminal = terminal;

  // mainagent（窓口のエージェント）が子のセッションを操作する口（mac の SessionHub の acquire / submitExternal / emitExternal /
  // snapshot / publishSessionsCard 相当）。子は iPhone の WS と同じ「接続」として購読する（openConnection）。
  const sessionsCards = new Map<string, string>();
  services.mainagentCards = sessionsCards;
  const hub: OrchestratorHub = {
    adapter: (agentId) => adapters.get(agentId),
    adapters: () => [...adapters.values()],
    probe: async (agentId) => {
      const r = await probeAgent(agentId, adapters.get(agentId)?.runtimeLabel ?? "");
      return { installed: r.installed, configured: r.configured };
    },
    projects: () => services.projects.list(),
    acquire: async (agentId, sessionId, cwd, send, options) => {
      const adapter = adapters.get(agentId);
      if (!adapter) throw new Error(`unknown agent: ${agentId}`);
      let gone = false;
      const core = openConnection(
        { isOpen: () => !gone, send },
        adapter, undefined, cwd, config.defaultCwd, liveSessions, liveHistory, store, subscribers, pushService, config.bridgeId,
        { principal: { kind: "local" }, devices }, services, false
      );
      const session = await core.attach(sessionId, options);
      const subscription: HubSubscription = {
        get session() {
          return core.state.session ?? session;
        },
        holds: () => !gone && core.state.session === session && liveSessions.get(`${agentId}:${session.sessionId}`) === session,
        submit: (clientMessageId, content) => (gone ? "missing" : core.submitExternal(clientMessageId, content)),
        release: () => {
          if (gone) return;
          gone = true;
          core.gone();
        }
      };
      return subscription;
    },
    emitExternal: (agentId, sessionId, evt) => {
      const withSeq = liveHistory.record(evt);
      const delivered = subscribers.deliver(`${agentId}:${sessionId}`, withSeq);
      // 誰も見ていなければ承認要求は push で呼び出す（mac の SessionHub.emitExternal と同じ）。
      if (delivered === 0 && evt.type === "action_request" && pushService.enabled) {
        void pushService.broadcast(adapters.get(agentId)?.displayName ?? agentId, evt.metadata?.title ?? evt.content ?? "承認が必要です", {
          kind: "approval_request",
          agentId,
          sessionId,
          requestId: evt.messageId ?? "",
          bridgeId: config.bridgeId
        });
      }
    },
    snapshot: () => {
      const seen = new Set<AgentSession>();
      const out: LiveSessionInfo[] = [];
      for (const [key, session] of liveSessions) {
        if (seen.has(session)) continue;
        seen.add(session);
        const agentId = key.slice(0, key.indexOf(":"));
        const sid = session.sessionId;
        out.push({
          agentId,
          sessionId: sid,
          cwd: sessionCwds.get(session),
          generating: (sendsInFlight.get(session) ?? 0) > 0 || liveHistory.currentTurn(agentId, sid) != null,
          queued: sendQueues.get(session)?.length ?? 0,
          awaiting: liveHistory.awaitingAnswer(agentId, sid),
          updatedAtMs: liveHistory.lastActivity(agentId, sid)
        });
      }
      return out;
    },
    terminal: () =>
      registry.liveEntries().map((e) => ({
        sessionId: e.sessionId,
        cwd: e.cwd,
        generating: e.generating,
        awaiting: liveHistory.awaitingAnswer("claude", e.sessionId),
        updatedAtMs: liveHistory.lastActivity("claude", e.sessionId) ?? e.startedAt
      })),
    // この PC（list_pcs の先頭・/device/sessions/summary の pc）。bridgeId は作り直しで変わるので毎回読む。
    selfPc: () => ({ bridgeId: identity.bridgeId, name: bridgeName(), platform: "windows" }),
    gitBranch: (cwd, agentId) => gitBranch(cwd, agentId, adapters.get(agentId)?.runtimeLabel),
    publishSessionsCard: (agentId, sessionId, payloadJson) => {
      const key = `${agentId}:${sessionId}`;
      // 最新だけを覚える（再接続・開き直しで渡す。done で消えるターンの記録とは別に持つ）。古いものから 200 件まで。
      sessionsCards.delete(key);
      sessionsCards.set(key, payloadJson);
      if (sessionsCards.size > 200) {
        const oldest = sessionsCards.keys().next().value;
        if (oldest !== undefined) sessionsCards.delete(oldest);
      }
      subscribers.deliver(key, event.workflowProgress(agentId, sessionId, payloadJson));
    },
    loadHistory: async (agentId, sessionId) => (await adapters.get(agentId)?.loadHistory(sessionId)) ?? [],
    defaultStrength: async (agentId) => {
      if (agentId === "claude") {
        const mode = claudeDefaultMode();
        return mode ? modeStrength(mode, agentId) : undefined;
      }
      if (agentId === "codex") {
        const info = await adapters.get("codex")?.currentInfo();
        return codexStrength(info?.sandboxMode ?? "workspace-write", info?.approvalPolicy ?? "on-request");
      }
      return undefined;
    }
  };
  orchestrator.attach(hub);

  // メインの定期チェック（docs/MAIN_HEARTBEAT_2026-10-20.md）。mainagent のフォルダの専用の会話に、hub を通して送る。
  services.heartbeat = new HeartbeatService({
    dir: defaultHeartbeatDir(config.configDir),
    mainRoot: () => mainAgentRoot(),
    hub: () => hub,
    push: (title, body, data) => void pushService.broadcast(title, body, data),
    bridgeId: () => config.bridgeId,
    watchers: (agentId, sid) => subscribers.count(`${agentId}:${sid}`),
    rename: (agentId, sid, title) => {
      void adapters.get(agentId)?.renameSession(sid, title).catch(() => false);
      store.titles.setTitle(agentId, sid, title);
    },
    onActiveChange: (active) => services.sleep.setActive(active, "heartbeat")
  });

  server.on("upgrade", (req, socket, head) => {
    // WebSocket もブラウザからは張らせない（Origin が無いか、デスクトップアプリの画面のときだけ。Host は 127.0.0.1 等）。
    if (guardRejection(req)) {
      socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
      socket.destroy();
      return;
    }
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    // WebSocket もルートの表で確かめる（表に無ければ 404、あれば Principal。ブラウザの WS はヘッダを付けられないので ?apiKey= も可）。
    const access = routeAccess(url.pathname, true);
    if (!access) {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }
    const checked = authorizeRoute(req, url, authCtx, access);
    if ("denial" in checked) {
      socket.write(`HTTP/1.1 ${checked.denial.status} ${checked.denial.status === 401 ? "Unauthorized" : "Forbidden"}\r\n\r\n`);
      socket.destroy();
      return;
    }
    const principal = checked.principal;
    // 別の PC のデスクトップから、この PC のターミナルを操作する口。
    if (url.pathname === "/terminal/pty") {
      handlePtyUpgrade(req, socket, head, url, previewOwner(principal));
      return;
    }
    // 相手の PC で開いているペインを見る口。host はこの PC の常駐プロセスが張る（表で local）。
    if (url.pathname === "/terminal/share/host") {
      handleShareHostUpgrade(req, socket, head, url);
      return;
    }
    if (url.pathname === "/terminal/share") {
      // 見ている端末の名前は、この PC の画面に「○○ が見ています」と出すのに使う。
      const name = principal.kind === "device" ? displayName(principal.row.label ?? principal.row.name, principal.deviceKeyId) : undefined;
      handleShareViewerUpgrade(req, socket, head, url, previewOwner(principal), name);
      return;
    }
    const match = /^\/ws\/agent\/([^/]+)$/.exec(url.pathname);
    if (!match) {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }

    const agentId = decodeURIComponent(match[1]);
    const adapter = adapters.get(agentId);
    if (!adapter) {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      const querySessionId = url.searchParams.get("sessionId") ?? undefined;
      // cwd 未指定（iOS の「全て」表示）は undefined のまま持つ（mac と同じ）。defaultCwd で
      // 埋めると一覧がホームで作ったセッションに絞られ、Claude の resume も transcript 記録の
      // cwd を引けなくなる。defaultCwd は新規セッションを開くときの既定値としてだけ使う。
      const queryCwd = url.searchParams.get("cwd") ?? undefined;
      // 内側の E2E（e2e=v1）はトンネル経由の端末（.device）の WS だけ。鍵はその端末の行の公開鍵で、deviceId は
      // 行の clientDeviceId と同じであること（違えば 1008 で閉じる）。この PC の中から（.local）は e2e のクエリを無視する
      // （spec/PROTOCOL-v3.md §13.6）。
      let e2e: E2EConnection | undefined;
      if (principal.kind === "device" && url.searchParams.get("e2e") === "v1") {
        const bridgeKey = identity.e2eKey;
        if (!bridgeKey) {
          ws.close(1011, "connection key unavailable");
          return;
        }
        e2e = setupE2E(ws, url.searchParams.get("deviceId"), bridgeKey, principal);
        if (!e2e) return;
      }
      void handleConnection(ws, adapter, querySessionId, queryCwd, config.defaultCwd, liveSessions, liveHistory, store, subscribers, pushService, config.bridgeId, { principal, devices }, e2e, services);
    });
  });

  return {
    server,
    adapters,
    devices,
    peers,
    invites,
    approvals,
    admin,
    bridgeName,
    attachTunnel: (t) => {
      tunnel = t;
    },
    services,
    push: pushService,
    setRegistrationHandler: (handler) => {
      registrationHandler = handler;
    },
    mainagentHub: hub,
    closeSessions: async (): Promise<void> => {
      await Promise.allSettled([...liveSessions.values()].map((s) => Promise.resolve(s.close())));
    },
    // 待ち受けに失敗したら（番号が取られていた等）起動失敗にする。黙って待ち受けないまま動き続けないように。
    start: () =>
      new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(config.port, LISTEN_HOST, () => {
          server.off("error", reject);
          // mainagent に渡す MCP の URL（http://127.0.0.1:<番号>/mcp）は、実際に待ち受けた番号で作る。
          setMainAgentPort((server.address() as AddressInfo | null)?.port);
          // agy の承認 hook が問い合わせる番号も、実際に待ち受けた番号にする（8765 が取られていれば次の番号）。
          agyApprovals.port = (server.address() as AddressInfo | null)?.port ?? config.port;
          // 見回り（cron 等）は待ち受けが開いてから始める（起動時の走査で WS の受け付けを遅らせない）。
          services.start();
          // buddy-opencode が繋げるよう、ターミナル連携を入れてあれば serve を起こしておく。
          const opencode = adapters.get("opencode");
          if (opencode instanceof OpenCodeAcpAdapter) void opencode.startTerminalServe().catch(() => {});
          resolve();
        });
      })
  };
}

function createAdapters(config: BridgeConfig, store: JsonSessionStore): Map<string, AgentAdapter> {
  const adapters = new Map<string, AgentAdapter>();
  adapters.set("echo", new EchoAdapter("echo", "Echo", store));

  // 1 エージェント = 1 エントリ。実行環境（native/wsl）は -native/-wsl の
  // alias を並べるのではなく、mode（BUDDYOS_*_MODE 環境変数 = デスクトップの
  // 設定）でどちらか一方に解決する。両方インストール済みの環境では
  // /status の availableRuntimes でデスクトップ側に選択肢を提示する。
  const hermesDefault = resolveRuntime("hermes", config.hermesMode, process.env.HERMES_BIN, config.wslDistro);
  adapters.set("hermes", hermesDefault ? new HermesAcpAdapter("hermes", hermesDefault, store) : new EchoAdapter("hermes", "Hermes (echo fallback)", store));

  const claudeDefault = resolveRuntime("claude", config.claudeMode, process.env.CLAUDE_BIN, config.wslDistro);
  adapters.set(
    "claude",
    claudeDefault
      ? new ClaudeCodeAdapter("claude", claudeDefault, store)
      : new EchoAdapter("claude", "Claude Code (echo fallback)", store)
  );

  // Cursor CLI / Grok Build CLI（headless stream-json 実行）。beta トグル配下。
  const cursorDefault = resolveRuntime("cursor-agent", config.cursorMode, process.env.CURSOR_AGENT_BIN, config.wslDistro);
  adapters.set(
    "cursor",
    cursorDefault
      ? new HeadlessCliAdapter("cursor", cursorDefault, store, CURSOR_PROFILE)
      : new EchoAdapter("cursor", "Cursor CLI (echo fallback)", store)
  );

  const grokDefault = resolveRuntime("grok", config.grokMode, process.env.GROK_BIN, config.wslDistro);
  adapters.set(
    "grok",
    grokDefault
      ? new HeadlessCliAdapter("grok", grokDefault, store, GROK_PROFILE)
      : new EchoAdapter("grok", "Grok Build (echo fallback)", store)
  );

  // Buddy（Bridge 内蔵の汎用アシスタント。OpenRouter を直接呼ぶ）。
  adapters.set("buddy", new BuddyAdapter("buddy"));

  // Antigravity CLI（agy。Gemini CLI の後継）。
  const agyDefault = resolveRuntime("agy", config.antigravityMode ?? "auto", process.env.ANTIGRAVITY_BIN, config.wslDistro);
  adapters.set(
    "antigravity",
    agyDefault
      ? new HeadlessCliAdapter("antigravity", agyDefault, store, ANTIGRAVITY_PROFILE)
      : new EchoAdapter("antigravity", "Antigravity (echo fallback)", store)
  );

  // Codex も他エージェントと同じく runtime を解決し、解決できればライブ実行
  // （codex exec --json）、できなければ履歴読み取り専用へフォールバックする。
  const codexDefault = resolveRuntime("codex", config.codexMode, process.env.CODEX_BIN, config.wslDistro);
  adapters.set("codex", new CodexHistoryAdapter("codex", codexDefault));

  const openclawDefault = resolveRuntime("openclaw", config.openclawMode, process.env.OPENCLAW_BIN, config.wslDistro);
  adapters.set(
    "openclaw",
    openclawDefault
      ? new OpenclawAcpAdapter("openclaw", openclawDefault, store)
      : new EchoAdapter("openclaw", "OpenClaw (echo fallback)", store)
  );

  const opencodeDefault = resolveRuntime("opencode", config.opencodeMode, process.env.OPENCODE_BIN, config.wslDistro);
  adapters.set(
    "opencode",
    opencodeDefault
      ? new OpenCodeAcpAdapter("opencode", opencodeDefault, store)
      : new EchoAdapter("opencode", "OpenCode (echo fallback)", store)
  );

  return adapters;
}

/**
 * native / wsl それぞれにインストール実体があるかの検出結果。
 * 検出は where.exe / wsl.exe（各最大5秒）を起動するので、/status のポーリング毎に
 * 回すと重い。実体の有無は滅多に変わらないため 60 秒キャッシュする。
 * resolveRuntime（spawnSync）で検出するとその間ブリッジ全体のイベントループが止まる
 * （WS の delta 送出・ping も止まる）ため、非同期に検出し、期限切れ後は前回値を即返して
 * 裏で再検出する（stale-while-revalidate）。初回だけ検出完了を待つ。
 */
const runtimeAvailCache = new Map<string, { at: number; runtimes: string[] }>();
const runtimeAvailInflight = new Map<string, Promise<string[]>>();
const RUNTIME_AVAIL_TTL_MS = 60_000;
const RUNTIME_DETECT_TIMEOUT_MS = 5000;

/** force=true（/status?fresh=1 で再判定を始めたとき）はキャッシュ期限内でも再検出を始める（結果は次回以降の応答に載る）。 */
export async function availableRuntimes(command: string, envOverride?: string, wslDistro?: string, force = false): Promise<string[]> {
  const hit = runtimeAvailCache.get(command);
  if (hit && !force && Date.now() - hit.at < RUNTIME_AVAIL_TTL_MS) return hit.runtimes;
  let refresh = runtimeAvailInflight.get(command);
  if (!refresh) {
    refresh = detectRuntimes(command, envOverride, wslDistro)
      .then((runtimes) => {
        runtimeAvailCache.set(command, { at: Date.now(), runtimes });
        return runtimes;
      })
      .catch(() => hit?.runtimes ?? [])
      .finally(() => runtimeAvailInflight.delete(command));
    runtimeAvailInflight.set(command, refresh);
  }
  return hit ? hit.runtimes : refresh;
}

async function detectRuntimes(command: string, envOverride?: string, wslDistro?: string): Promise<string[]> {
  const [native, wsl] = await Promise.all([
    nativeCommandExists(envOverride ?? command),
    wslCommandExists(command, wslDistro)
  ]);
  const runtimes: string[] = [];
  if (native) runtimes.push("native");
  if (wsl) runtimes.push("wsl");
  return runtimes;
}

/** resolveRuntime の native 判定（where.exe / 非 Windows は --version）の非同期版。 */
async function nativeCommandExists(command: string): Promise<boolean> {
  if (process.platform === "win32") {
    // 拡張子での選別（.ps1・拡張子なしのシムは不可、*_BIN には .exe/.cmd を補う）は resolveRuntime と共通。
    if (command.includes("/") || command.includes("\\")) return resolveWinPath(command) !== undefined;
    const r = await execRuntime({ kind: "native", executable: systemExe("where.exe"), label: "native:where.exe", shell: false }, [command], RUNTIME_DETECT_TIMEOUT_MS);
    return r.ok && pickWhereResult(r.stdout) !== undefined;
  }
  const r = await execRuntime({ kind: "native", executable: command, label: `native:${command}`, shell: false }, ["--version"], RUNTIME_DETECT_TIMEOUT_MS);
  return r.ok;
}

/** resolveRuntime の wsl 判定（wsl.exe --exec sh -lc 'command -v ...'）の非同期版。 */
async function wslCommandExists(command: string, wslDistro?: string): Promise<boolean> {
  if (process.platform !== "win32") return false;
  const quoted = `'${command.replace(/'/g, "'\\''")}'`;
  const r = await execRuntime(
    { kind: "wsl", executable: "sh", label: "wsl:sh", shell: false, wslDistro },
    ["-lc", `command -v ${quoted} >/dev/null 2>&1`],
    RUNTIME_DETECT_TIMEOUT_MS
  );
  return r.ok;
}

/**
 * /status の probeAgent の進行中 Promise（エージェント × 実行環境ごと）。desktop の recheckAgents は
 * /status?fresh=1 を 4 秒で打ち切り、500ms 後に送り直す（最大 6 回）。要求ごとにキャッシュを捨てて
 * 最初から probe し直すと、WSL の起動待ち等で 4 秒を超える間ずっと揃わず、wsl.exe / --version の
 * 子プロセスも重なって溜まる。進行中の probe は共有し、続けて来た fresh は同じ再判定として扱う。
 */
const probeInflight = new Map<string, { startedAt: number; promise: Promise<ProbeResult> }>();
// 再判定を始めてからこの間に来た fresh は同じ再判定とみなす（desktop の再送間隔 4.5 秒を覆う）。
// これより古い結果は fresh では使わない。
const FRESH_PROBE_REUSE_MS = 10_000;
// 今の再判定を始めた時刻（これ以降に始まった probe・得た結果は fresh でも使い回す）。
let freshProbeSince = 0;

/** fresh=1 を受けたら呼ぶ。新しい再判定を始めたとき（probe のキャッシュを捨てたとき）だけ true。 */
function beginFreshProbe(): boolean {
  const now = Date.now();
  if (now - freshProbeSince <= FRESH_PROBE_REUSE_MS) return false;
  freshProbeSince = now;
  clearProbeCache();
  return true;
}

/** 進行中の同じ probe があればそれを待つ。fresh は再判定を始める前から走っていた probe には相乗りしない。 */
function sharedProbe(id: string, runtimeLabel: string, fresh: boolean): Promise<ProbeResult> {
  const key = id + "\0" + runtimeLabel;
  const running = probeInflight.get(key);
  if (running && (!fresh || running.startedAt >= freshProbeSince)) return running.promise;
  const entry = { startedAt: Date.now(), promise: probeAgent(id, runtimeLabel) };
  probeInflight.set(key, entry);
  const cleanup = (): void => {
    if (probeInflight.get(key) === entry) probeInflight.delete(key);
  };
  entry.promise.then(cleanup, cleanup);
  return entry.promise;
}

/** 使用量を読めるエージェント（UsageService.defaultReadAll と揃える）。 */
const USAGE_AGENTS = new Set(["claude", "codex", "antigravity", "grok"]);
/** MCP の一覧・追加・削除ができる headless CLI のエージェント。 */
const HEADLESS_MCP_AGENTS = new Set(["cursor", "grok", "antigravity"]);

/**
 * クライアントの出し分けに使う能力。サービス側の事実（定期実行の仕組み・ログイン・使用量・MCP の書き込み）を
 * ここで合流させる（mac の AgentRegistry.capabilities(of:) と同じ）。effort / モードの選択肢は adapter が
 * set_model_request で実際に保存・適用できるものだけ（AgentAdapter.efforts / modes）。空 = 切り替えられない（mac と同じ形）。
 */
function capabilitiesFor(adapter: AgentAdapter, bgSessions = false): Record<string, boolean | readonly string[]> {
  const base = adapter.id.split("-")[0];
  return {
    ...coreCapabilities(adapter),
    cronOptions: cronBackend(adapter) === "scheduler",
    login: loginSupported(adapter.id),
    usage: USAGE_AGENTS.has(base),
    // 公開したサイトの一覧（sites_request）。Bridge の機能なので agent によらず true。
    sites: true,
    // メインの定期チェック（heartbeat_get / set / run_now）。Bridge の機能なので agent によらず true。
    heartbeat: true,
    mcpRegister: mcpRegisterSupported(adapter.id),
    efforts: adapter.efforts ?? [],
    modes: adapter.modes ?? [],
    // ターミナル連携。Claude Code は hook と受け箱、ほかは adapter が持つ（codex の共有 app-server、opencode serve、
    // grok の leader、agy の受け取り箱）。
    terminal: adapter.id === "claude" || adapter.terminal === true,
    // ~/.buddyos/main（Windows は %USERPROFILE%\.buddyos\main）で開くと mainagent になる（mac と同じく claude と codex）。
    orchestrate: adapter instanceof ClaudeCodeAdapter || adapter instanceof CodexHistoryAdapter,
    // claude --bg のセッションの一覧・停止・削除。claude で native の runtime のときだけ true（WSL は受け箱が届かないので false）。
    bgSessions: adapter.id === "claude" && adapter instanceof ClaudeCodeAdapter && bgSessions
  };
}

function coreCapabilities(adapter: AgentAdapter): Record<string, boolean> {
  const baseId = adapter.id.split("-")[0];
  // injectMidTurn is wired only for agents that keep one process across turns
  // (Claude Code / Codex app-server); everything else falls back to queue-as-new-turn. interrupt is also
  // advertised by adapters whose sessions implement interrupt() on their own
  // (CLI process kill / ACP session/cancel), so it is not tied to injectMidTurn.
  const inject = adapter.supportsMidTurnInjection === true;
  const interrupt = inject || adapter.supportsInterrupt === true;
  const common = {
    chat: true,
    history: true,
    projects: true,
    commands: true,
    models: true,
    cron: cronBackend(adapter) !== undefined,
    // スキルは cwd の .claude/skills（読み書き）とホームのスキル（読むだけ）。
    skills: true,
    mcp: false,
    attachments: true,
    actions: false,
    injectMidTurn: inject,
    interrupt,
    warm: adapter.supportsWarm === true
  };
  // Cursor / Grok / Antigravity の MCP は各 CLI の設定（~/.cursor/mcp.json・grok / agy の mcp add）へ書く（mac の HeadlessCliAdapter と同じ）。
  if (HEADLESS_MCP_AGENTS.has(baseId)) return { ...common, mcp: true };
  switch (baseId) {
    case "hermes":
      return { ...common, mcp: true };
    case "codex":
      // 対話は app-server（承認を往復できる）。BUDDYOS_CODEX_TRANSPORT=exec のときは codex exec で承認なし。
      return { ...common, skills: true, mcp: true, actions: adapter instanceof CodexHistoryAdapter && adapter.usesAppServer() };
    case "claude":
      return { ...common, mcp: true, actions: true };
    case "openclaw":
      return { ...common, mcp: false };
    case "opencode":
      // 6 機能すべて有効。history は JsonSessionStore、models/mode/commands は live
      // AcpSession の configOptions / available_commands_update、skills/mcp は
      // ~/.config/opencode 配下のファイルから供給する。
      return { ...common, history: true, commands: true, models: true, skills: true, mcp: true };
    case "antigravity":
      // native の agy はコマンド実行の承認を iPhone で受ける（AgyApprovalHook）。
      return { ...common, actions: adapter.runtimeLabel.startsWith("native:") };
    case "echo":
      return { ...common, commands: false, models: false, skills: false };
    case "buddy":
      // 会話の一覧・履歴は持たない（同じ id で開き直せば続きから話せる）。ツールは承認を取って実行する。
      return { ...common, history: false, projects: false, commands: false, skills: false, mcp: true, actions: true };
    case "cursor":
    case "grok":
      // ACP で動かすときは承認を iPhone に出せる（BUDDYOS_<ID>_HEADLESS=1 の headless 実行では出せない）。
      return { ...common, actions: adapter instanceof HeadlessCliAdapter && adapter.usesAcp };
    default:
      return common;
  }
}

/**
 * E2E モードの接続状態（PROTOCOL-v3 §13.6）。方向鍵は接続確立時に connSalt から導出済み。
 * verified はクライアント最初の暗号化フレームの open 成功で立つ「鍵確認」—
 * それまで Bridge は暗号化データ（sessionStarted 等）を送らず pending に溜める。
 */
interface E2EConnection {
  deviceId: string;
  sender: E2EFrameSender;
  receiver: E2EFrameReceiver;
  verified: boolean;
  pending: Buffer[];
}

/**
 * e2e=v1 接続の確立（spec/PROTOCOL-v3.md §13.6）。トンネル経由の端末（.device）の
 * WS だけが使う。deviceId はその端末の行の clientDeviceId と同じであること（違えば e2e_error を送って 1008 で閉じ、
 * undefined を返す）。鍵の導出には行の公開鍵を使う。connSalt を生成して方向鍵を導出し、最初に 1 通だけ平文 TEXT の
 * e2e_hello を送る。
 */
function setupE2E(
  ws: WebSocket,
  deviceId: string | null,
  bridgeKey: Buffer,
  principal: Extract<Principal, { kind: "device" }>
): E2EConnection | undefined {
  const record = principal.row;
  if (!deviceId || deviceId !== record.clientDeviceId) {
    ws.send(JSON.stringify({ type: "e2e_error", metadata: { reason: "unknown_device" } }));
    ws.close(1008, "e2e device mismatch");
    return undefined;
  }
  // connSalt による接続ごとの鍵分離（PROTOCOL-v3 §13.6）— 1 接続の鍵漏洩の影響を局所化する。
  const connSalt = crypto.randomBytes(32);
  let keys: { c2s: Buffer; s2c: Buffer };
  try {
    keys = deriveWSKeys(bridgeKey, Buffer.from(record.pub, "base64url"), connSalt);
  } catch {
    ws.send(JSON.stringify({ type: "e2e_error", metadata: { reason: "unknown_device" } }));
    ws.close(1008, "e2e failure");
    return undefined;
  }
  // kid = SHA256(bridge_pub) 先頭 8B hex。
  const kid = crypto.createHash("sha256").update(publicKey(bridgeKey)).digest("hex").slice(0, 16);
  ws.send(JSON.stringify({ type: "e2e_hello", metadata: { v: "1", salt: connSalt.toString("base64url"), kid } }));
  return {
    deviceId,
    sender: new E2EFrameSender(keys.s2c),
    receiver: new E2EFrameReceiver(keys.c2s),
    verified: false,
    pending: []
  };
}

/** WS 1 本の Principal（誰の接続か）と端末の一覧。register_push_token は .device の接続からだけ受ける（PROTOCOL-v3 §14）。 */
interface ConnectionAuth {
  principal: Principal;
  devices: DeviceStore;
}

function rawToBuffer(raw: RawData): Buffer {
  if (Buffer.isBuffer(raw)) return raw;
  if (Array.isArray(raw)) return Buffer.concat(raw);
  return Buffer.from(raw);
}

/** 接続 1 本（WS か、mainagent が子を購読する仮の接続）の送り口。 */
interface ConnectionTransport {
  /** 送れるか（WS が開いている・mainagent がまだ購読している）。 */
  isOpen(): boolean;
  /** 出来事をそのまま送る（liveHistory へ記録しない・push もしない）。 */
  send: Emit;
}

/** 接続 1 本の中身（mac の SessionHub の購読者 1 人分）。WS（handleConnection）と mainagent の子の購読（hub.acquire）が使う。 */
interface ConnectionCore {
  state: ConnectionState;
  /**
   * 受けた 1 通（復号済みの JSON）を処理する。
   * fromClient: WebSocket が受けた通か。そのうち、ペアリング済みの端末（principal が .device の接続）の
   * user_message / queue_user_message だけが、人が入力欄で打った発話なので、ターミナルの claude には打ち込んで届ける
   * （markTypedByUser。handleMessage が principal を見て付ける）。.local の接続（この PC の api-key を持つプロセス。
   * デスクトップの会話画面を含む）の送信には付けず、今までどおり受け箱で届く。
   * 常駐機能（mainagent・定期の見回り）の送信は submitExternal を使う。ここで true にしない。
   */
  handle(text: string, fromClient: boolean): void;
  /** セッションを開いて（あれば使って）購読する（mainagent の子）。 */
  attach(sessionId: string | undefined, options?: SessionOptions): Promise<AgentSession>;
  /**
   * iPhone 以外（mainagent）からの送信（mac の SessionHub.submitExternal）。空いていれば queue_dispatched を配ってすぐ送り、
   * 作業中なら予約に積む（done の後に dispatchNext が送り、そのとき queue_dispatched を配る）。
   */
  submitExternal(clientMessageId: string, content: string): "sent" | "queued" | "missing";
  /** 接続が切れた（購読を外し、最後の購読者なら猶予の後に session を閉じる）。 */
  gone(): void;
}

async function handleConnection(
  ws: WebSocket,
  adapter: AgentAdapter,
  querySessionId: string | undefined,
  queryCwd: string | undefined,
  defaultCwd: string,
  liveSessions: Map<string, AgentSession>,
  liveHistory: LiveHistoryIndex,
  store: JsonSessionStore,
  subscribers: SessionSubscribers,
  pushService: PushService,
  bridgeId: string,
  connectionAuth: ConnectionAuth,
  e2e: E2EConnection | undefined,
  services: BridgeServices
): Promise<void> {
  // ws への送出だけを行う（liveHistory へは記録しない・push もしない）。接続時の
  // session_started や load_history の差分 replay（採番済みイベントの再送）はこちらで送る。
  const sendRaw: Emit = (outbound) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    if (e2e) {
      const plaintext = Buffer.from(JSON.stringify(outbound), "utf8");
      // 鍵確認（PROTOCOL-v3 §13.6）: クライアント最初のフレームの open 成功まで暗号化データを
      // 送らない。seq は seal 時に採番されるため、溜めてから流しても単調性は保たれる。
      if (!e2e.verified) {
        e2e.pending.push(plaintext);
        return;
      }
      ws.send(e2e.sender.seal(plaintext));
      return;
    }
    ws.send(JSON.stringify(outbound));
  };

  const core = openConnection(
    { isOpen: () => ws.readyState === WebSocket.OPEN, send: sendRaw },
    adapter, querySessionId, queryCwd, defaultCwd, liveSessions, liveHistory, store, subscribers, pushService, bridgeId, connectionAuth, services, true
  );

  ws.on("message", (raw, isBinary) => {
    let text: string;
    if (e2e) {
      // e2e 接続では平文フレーム混在を禁止（フレーム単位のダウングレード攻撃防止、PROTOCOL-v3 §13.6）。
      if (!isBinary) {
        ws.close(1008, "plaintext frame on e2e connection");
        return;
      }
      try {
        text = e2e.receiver.open(rawToBuffer(raw)).toString("utf8");
      } catch (err) {
        // seq 逆行/重複/欠番・改竄・鍵不一致はすべてプロトコル違反として即切断（PROTOCOL-v3 §13.6）
        ws.close(1008, err instanceof E2ECryptoError ? err.reason : "e2e failure");
        return;
      }
      if (!e2e.verified) {
        // 最初の open 成功 = 鍵確認完了。保留していた暗号化データを流す（端末の鍵はペアリングで確かめ済み）。
        e2e.verified = true;
        for (const pending of e2e.pending.splice(0)) ws.send(e2e.sender.seal(pending));
      }
    } else {
      text = String(raw);
    }
    // WebSocket が受けた 1 通。ペアリング済みの端末（.device）の user_message は、人が入力欄で打った発話
    // （handleMessage が principal を見て印を付ける。.local の接続の発話には付けない）。
    core.handle(text, true);
  });
  ws.on("close", core.gone);
  ws.on("error", core.gone);
}

function openConnection(
  transport: ConnectionTransport,
  adapter: AgentAdapter,
  querySessionId: string | undefined,
  queryCwd: string | undefined,
  defaultCwd: string,
  liveSessions: Map<string, AgentSession>,
  liveHistory: LiveHistoryIndex,
  store: JsonSessionStore,
  subscribers: SessionSubscribers,
  pushService: PushService,
  bridgeId: string,
  connectionAuth: ConnectionAuth,
  services: BridgeServices,
  /** cron の結果・使用量の配信を受けるか（WS だけ。mainagent の子の購読は受けない）。 */
  feeds: boolean
): ConnectionCore {
  const state: ConnectionState = { sessionId: querySessionId, cwd: queryCwd };

  // セッションの出力がどの生接続にも届かなかった（背面で WS が畳まれた等）とき、APNs push で
  // 通知する（mac の SessionHub と同思想。判定は fanout 側）。
  // cron の結果の push は CronOutputHub が出すので、ここでのトリガは done / action_request のみ。
  const maybePush = (outbound: SessionEvent): void => {
    if (!pushService.enabled) return;
    const sid = outbound.sessionId;
    if (!sid) return;
    const agentDisplay = adapter.displayName;
    if (outbound.type === "done") {
      // 本文の無い知らせのターンの done（silent。ターンを閉じるだけ）では何も鳴らさない。
      if (outbound.metadata?.silent === "1") return;
      // 本文はこのターンの最後の吹き出しの頭（前置きの「調べます」ではなく結論）。done を記録した時点の本文から取る。
      const body = liveHistory.lastBubble(adapter.id, sid) ?? "新しい応答があります";
      void (async () => {
        // バックグラウンドのサブエージェントか workflow が動いていれば push しない（その作業が終わったときの知らせのターンの
        // done で push する）。バックグラウンドのコマンドだけなら待たない（dev サーバーは終わらない）。
        const key = `${adapter.id}:${sid}`;
        const background = await backgroundWork(adapter.id, sid, liveSessions.get(key), liveHistory, services.terminal);
        const payload = {
          kind: "chat",
          agentId: adapter.id,
          sessionId: sid,
          // タップで送信元 Bridge（PC）のその会話を開くため（承認要求と同じ）。
          bridgeId
        };
        if (agentsOrWorkflows(background)) {
          // 子が終わっても親が起きない CLI（Codex の multi-agent v2 など）は、後の知らせのターンの done が来ない。
          // 行が 0 に落ちて猶予の間に done が来なければ、ここで預かった本文で push する。
          deferPushUntilSettled({
            key,
            isRunning: async () => agentsOrWorkflows(await backgroundWork(adapter.id, sid, liveSessions.get(key), liveHistory, services.terminal)),
            // 購読者が付いたなら、利用者はもう見ている。
            isStale: () => subscribers.count(key) > 0,
            // ターンが動いている間は数えない（そのターンの done が push を引き継ぐ。本文の無い知らせのターンなら終わってから数え直す）。
            isBusy: () => liveHistory.currentTurn(adapter.id, sid) != null,
            fire: () => pushService.broadcast(agentDisplay, body, payload)
          });
          return;
        }
        cancelDeferredPush(key);
        await pushService.broadcast(agentDisplay, body, payload);
      })().catch(() => {});
    } else if (outbound.type === "action_request") {
      const title = outbound.metadata?.title ?? outbound.content ?? "承認が必要です";
      void pushService.broadcast(agentDisplay, title, {
        kind: "approval_request",
        agentId: adapter.id,
        sessionId: sid,
        requestId: outbound.messageId ?? "",
        // タップ時に送信元 Bridge（PC）へ切り替えてから開くため（複数 Bridge ペアリング時）。
        bridgeId
      });
    }
  };

  const sendRaw = transport.send;

  // cron の結果は、どのエージェントの接続にも配る（iOS は jobId/timestamp で重複を除く）。
  // 再接続の差分 replay に載せるものではないので記録せず、そのまま送る（mac と同じ）。
  const unregisterCronOutputs = feeds ? services.cronOutputs.register(sendRaw) : () => {};
  // 使用量も全接続へ配る（手元の最新値は登録した時点で届く）。
  const unregisterUsage = feeds ? services.usage.register(sendRaw) : () => {};
  // 定期チェックの状態（回し始め・終わり・設定の変更）も全接続へ配る。
  // claude --bg のセッションの変化も全接続へ配る（採番せず、差分 replay にも載せない）。
  const unregisterBgSessions = feeds ? services.bgSessions.register(sendRaw) : () => {};
  const unregisterHeartbeat = feeds && services.heartbeat ? services.heartbeat.register(sendRaw) : () => {};
  // Live Activity の状態は、トンネル経由の端末（.device）の WS だけへ送る（デスクトップ・mainagent の子の購読へは送らない）。
  const unregisterLiveActivity = feeds && connectionAuth.principal.kind === "device" ? services.liveActivity.registerSender(sendRaw) : () => {};

  // この接続へ live で届けた採番済みイベントの控え。load_history の差分 replay で同じものを再送しない
  // （再接続で購読に加わった後に届いた delta / done が replay でもう一度届くと、本文が二重になる）。
  const liveDelivered = new LiveDeliveredEvents();
  const sendLive: Emit = (outbound) => {
    liveDelivered.note(outbound);
    sendRaw(outbound);
  };

  // この接続への応答（一覧・履歴・ack・状態プローブ等）。liveHistory へ記録してこの接続にだけ送る。
  // 閉じた接続への応答は捨てる（セッションの出力は fanout が購読者へ配り、届かなければ push する）。
  const emit: Emit = (outbound) => {
    const withSeq = liveHistory.record(outbound);
    if (transport.isOpen()) sendLive(withSeq);
  };

  // セッションの出力の配送（mac の SessionHub の fan-out 相当）。liveHistory への記録は 1 イベントにつき
  // 1 回で、その session key の生きた購読者全員（ターン途中に再接続した接続・同時に開いている別接続を
  // 含む）へ送り、誰にも届かなかったときだけ push する。
  const fanout = (key: string, outbound: SessionEvent): void => {
    // 送った発話がまだ CLI の待ち行列にある間の知らせのターンの done は、その発話のターンを終わらせず、push もしない
    // （終わった行を捨てない・session を閉じない。その発話の done で終わる。mac の SessionHub と同じ）。
    const live = liveSessions.get(key);
    // adapter が metadata.pending = "1" を付けた done（まだ CLI に発話が残っている中間の done）も同じ扱いにする。
    const held =
      outbound.type === "done" &&
      (outbound.metadata?.pending === "1" ||
        (outbound.metadata?.origin === "task-notification" && live !== undefined && (sendsInFlight.get(live) ?? 0) > 0));
    // どの adapter（Codex / OpenCode の知らせのターンを含む）でもアプリへ同じ信号が届くよう、留め置く done には pending を刻む。
    if (held && outbound.metadata?.pending !== "1") outbound = { ...outbound, metadata: { ...outbound.metadata, pending: "1" } };
    const withSeq = liveHistory.record(outbound, held);
    // 新しい done は、預かっていた完了の push を引き継ぐ（push するか預け直すかは maybePush が決める）。
    if (outbound.type === "done" && !held && outbound.metadata?.silent !== "1") cancelDeferredPush(key);
    // 本文の無い知らせのターンの done で作業が全部終わっていれば、これ以上良い本文は来ないので預かっていた push を今出す。
    if (outbound.type === "done" && !held && outbound.metadata?.silent === "1") void fireDeferredPushIfSettled(key);
    if (subscribers.deliver(key, withSeq) === 0 && !held) maybePush(outbound);
    // send() を持たないターン（知らせのターン・差し込んだ発話）の最終 done でも、預かっている予約を送る（mac は !promptPending の done で送る）。
    if (live && endsTurn(withSeq)) queueDispatchers.get(live)?.();
  };

  // この接続の購読。session id は new→real（pending-xxx→codex thread 等）に変わり得るので、
  // その都度付け替える（ターン中の確定は turnEmit が購読者ごと移す）。
  const subscriber: Subscriber = { alive: () => transport.isOpen(), send: sendLive };
  let adoptedSid: string | undefined;
  /** サブエージェントのカードの全行を送った session（替わったら、新しい session の全行を送り直す）。 */
  let cardsSession: AgentSession | undefined;
  // サブエージェントのカードの全行（ターンの状態に関係なく。行が無くても epoch 付き）と dynamic workflow のカード
  // （進行中ならこのターンの全部、アイドルなら終わっていないもの）をこの接続へ送る（mac の SessionHub の
  // emitSnapshotIfActive と同じ。カードは backlog に残らず、ターンを越えて動く）。
  const sendCards = async (sid: string, session: AgentSession | undefined): Promise<void> => {
    const subagents = await subagentsCard(adapter.id, sid, session, liveHistory, services.terminal);
    // 聞いている間に切断された・別の会話に移った。
    if (!transport.isOpen() || adoptedSid !== sid) return;
    if (subagents) sendRaw(event.workflowProgress(adapter.id, sid, subagents));
    const inTurn = liveHistory.currentTurn(adapter.id, sid) != null;
    for (const card of liveHistory.workflowCards(adapter.id, sid, !inTurn)) sendRaw(event.workflowProgress(adapter.id, sid, card));
  };
  const adopt = (): void => {
    // 切断済みソケットでは adopt しない。長いターンの最中に背面化で ws が閉じると
    // onGone が先に購読を外すが、その後 send() 完了で走る .then(adopt) が
    // 死んだ接続を購読者に戻してしまい、購読者>0 のまま session が dispose されず
    // 子プロセスがリークする。
    if (!transport.isOpen()) return;
    const sid = state.sessionId;
    if (!sid) return;
    const key = `${adapter.id}:${sid}`;
    const live = liveSessions.get(key);
    const subscribing = sid !== adoptedSid;
    if (subscribing) {
      adoptedSid = sid;
      subscribers.subscribe(subscriber, key);
      // 開いているセッションに付いたら予約の現状を送る（空でも送り、端末に残った古い予約カードを消させる）。
      if (live) sendRaw(event.queueState(adapter.id, sid, queueItems(live)));
      // mainagent のチャットなら、任せた子のカード（workflow_progress kind = "sessions"）を、ターンが終わっていても渡す。
      const card = services.mainagentCards?.get(key);
      if (card) sendRaw(event.workflowProgress(adapter.id, sid, card));
    }
    // サブエージェントのカードは、購読を始めたときと、この接続で開いた session が替わったとき（作り直した session の
    // 新しい epoch で、アプリが前の世代の行を消せるように）に送る。
    if (subscribing || (live !== undefined && live !== cardsSession)) {
      cardsSession = live;
      void sendCards(sid, live).catch(() => {});
    }
  };

  if (querySessionId) {
    // 接続時の session_started は記録しない（mac と同じ）。record すると再接続のたびに
    // seq=最新+1 が振られ、iOS の lastHistorySeq がそこまで進んで差分同期の取りこぼし・
    // 履歴の空表示を起こす（リングバッファにも溜まって本物の delta を押し出す）。
    sendRaw(event.sessionStarted(adapter.id, querySessionId));
    // 進行中ターンがあれば再接続スナップショットを送る（cold-resume で考え中/回答中から再開）。
    const t = liveHistory.currentTurn(adapter.id, querySessionId);
    if (t) {
      emit(withSnapshotSeq(
        event.turnResume(adapter.id, querySessionId, t.phase, t.messageId, t.textSoFar, t.toolUseId, t.toolName, t.toolKind),
        liveHistory.latestSeq(adapter.id, querySessionId)
      ));
    }
    adopt();
    // ターミナルで開いている会話（codex / opencode / agy）は、iPhone から送る前からターミナル側のターンを流す。
    // 出力は Claude Code のターミナルと同じく、その会話の購読者全員へ配って再接続用に記録する。
    if (adapter.terminalSession) {
      const sid = querySessionId;
      void (async () => {
        if (!(await adapter.terminalSession?.(sid)) || !transport.isOpen()) return;
        const session = await acquireSession(adapter, liveSessions, state, sid, queryCwd, defaultCwd, services.terminal, undefined, services.bgSessions, services.publishClaude);
        state.session ??= session;
        await session.watch?.((evt) => {
          const withSeq = liveHistory.record(evt);
          subscribers.deliver(`${adapter.id}:${evt.sessionId ?? sid}`, withSeq);
        });
      })().catch((err) => console.error(`[bridge] terminal watch failed: ${String(err)}`));
    }
  }

  const handle = (text: string, fromClient: boolean): void => {
    void handleMessage(text, adapter, state, liveSessions, liveHistory, store, emit, pushService, connectionAuth, sendRaw, adopt, defaultCwd, fanout, subscribers, liveDelivered, services, fromClient)
      .then(() => {
        adopt();
        // 処理中（openSession の await 等）に切断されていた場合、onGone はこの session を
        // 知らないまま終わっている。購読者の居ない session として dispose を仕掛ける。
        if (!transport.isOpen() && state.session) armDispose(state.session);
      })
      .catch((err) => console.error(`[bridge] handleMessage failed: ${String(err)}`));
  };

  // 切断時、最後の購読者が一定猶予後も戻らなければ session を dispose する。
  // ACP 系（hermes/openclaw/opencode）の長命子プロセスのリーク防止。
  // 猶予中の再接続（同 session を adopt）・生成中ターン・バックグラウンドの作業は保護する。
  let disposeArmed: AgentSession | undefined;
  const armDispose = (session: AgentSession): void => {
    if (disposeArmed === session) return; // close / error の二重発火
    disposeArmed = session;
    // 切断時に生成中だと一発タイマーでは取りこぼす（猶予満了時もまだ生成中なら
    // 何もせず終わる）。誰も掴み直さない限り、生成完了まで猶予を再アームし続ける。
    const rearm = (): void => {
      setTimeout(() => void check().catch(() => {}), SESSION_DISPOSE_GRACE_MS).unref();
    };
    // send() 実行中（承認待ちを含む）も生成中とみなす。新規チャットの初回ターンは
    // user_message が pending-xxx 側に記録されるので、実 id の currentTurn だけでは見逃す。
    const generating = (): boolean =>
      (sendsInFlight.get(session) ?? 0) > 0 || session.hasPendingTurn === true || liveHistory.currentTurn(adapter.id, session.sessionId) != null;
    const check = async (): Promise<void> => {
      // 猶予中に id が pending-xxx → 実 id に変わり得るので、キーは毎回 session から引き直す。
      const key = `${adapter.id}:${session.sessionId}`;
      if (subscribers.count(key) > 0) return; // 別の生接続が掴み直した
      if (generating()) return rearm(); // 生成中 → 再アーム
      if (liveSessions.get(key) !== session) return; // dispose 済み / 別 session に置き換わった
      // バックグラウンドの作業（サブエージェント・シェル・終わっていない dynamic workflow）が残っている間は閉じない
      // （プロセスごと止めると作業が消え、終わりの知らせも来ない）。作業が終わった後の知らせのターンの done の後に閉じる。
      // ただし、購読者がいないままイベントの無い時間が BACKGROUND_IDLE_TIMEOUT_MS を過ぎたら閉じる（終わりの知らせを
      // 取りこぼした行や、止まらない dev サーバーで永久に残さない。閉じるときは session が実行中の行を stopped で閉じる）。
      const background = await backgroundWork(adapter.id, session.sessionId, session, liveHistory, services.terminal);
      // 聞いている間に購読者が付いた・送信が始まった・外された session は触らない。
      if (subscribers.count(key) > 0 || liveSessions.get(key) !== session) return;
      if (generating()) return rearm();
      const idleFor = Date.now() - (liveHistory.lastActivity(adapter.id, session.sessionId) ?? 0);
      if (anyBackground(background) && idleFor < BACKGROUND_IDLE_TIMEOUT_MS) return rearm();
      liveSessions.delete(key);
      sendQueues.delete(session);
      // 購読者も生成中のターンも無いので live 記録も捨てる（seq は墓標から続け、戻った端末は全履歴で同期する）。
      liveHistory.release(adapter.id, session.sessionId);
      void Promise.resolve(session.close()).catch(() => {});
    };
    // 猶予タイマーではプロセスの終了を引き止めない（常駐中は HTTP サーバが生かしている。
    // サーバを閉じた後のテスト・終了処理が猶予ぶん待たされないようにする）。
    rearm();
  };
  const gone = (): void => {
    unregisterCronOutputs();
    unregisterUsage();
    unregisterBgSessions();
    unregisterHeartbeat();
    unregisterLiveActivity();
    state.unsubscribeLogin?.();
    state.unsubscribeLogin = undefined;
    const key = subscriber.key;
    subscribers.unsubscribe(subscriber);
    // 購読が無くても（新規チャットで id 確定前に切断等）この接続が開いた session は対象にする。
    const session = state.session ?? (key ? liveSessions.get(key) : undefined);
    if (session) armDispose(session);
  };

  const attach = async (sessionId: string | undefined, options?: SessionOptions): Promise<AgentSession> => {
    const session = await acquireSession(adapter, liveSessions, state, sessionId, state.cwd, defaultCwd, services.terminal, options, services.bgSessions, services.publishClaude);
    state.session = session;
    state.sessionId = session.sessionId;
    const key = `${adapter.id}:${session.sessionId}`;
    if (!liveSessions.has(key)) liveSessions.set(key, session);
    adopt();
    return session;
  };

  const submitExternal = (clientMessageId: string, content: string): "sent" | "queued" | "missing" => {
    const session = state.session;
    if (!session) return "missing";
    const sid = session.sessionId;
    const key = `${adapter.id}:${sid}`;
    const inbound: SessionEvent = { type: "user_message", agentId: adapter.id, sessionId: sid, content, metadata: { clientMessageId } };
    const busy = (sendsInFlight.get(session) ?? 0) > 0 || liveHistory.currentTurn(adapter.id, sid) != null;
    if (busy) {
      // 生成中 → 預かる（queue_user_message と同じ）。ターンが終わったら dispatchNext が送る。
      const queue = sendQueues.get(session) ?? [];
      queue.push({ clientMessageId, content, inbound });
      sendQueues.set(session, queue);
      subscribers.deliver(key, event.queueState(adapter.id, sid, queueItems(session)));
      return "queued";
    }
    // 空いている → すぐ送る。送り主（mainagent）は自分の clientMessageId の queue_dispatched でターンの始まりを知る。
    subscribers.deliver(key, event.queueDispatched(adapter.id, sid, clientMessageId, content));
    // mainagent・定期の見回りの文は人が打った発話ではない（false）。ターミナルの claude へは受け箱で届く。
    handle(JSON.stringify(inbound), false);
    return "sent";
  };

  return { state, handle, attach, submitExternal, gone };
}

/// セッション出力の購読者（WS 接続 1 本）。
interface Subscriber {
  /** 現在購読している session key。未購読なら undefined（SessionSubscribers が書き換える）。 */
  key?: string;
  /** 接続が生きていて送れるか。 */
  alive(): boolean;
  send: Emit;
}

/// session key（`${agentId}:${sessionId}`）ごとの生購読者（mac の SessionHub の subscribers 相当）。
/// セッションは接続をまたいで共有されるので、出力は send() を呼んだ接続ではなくここの購読者全員へ配る。
/// 件数は dispose 判定（最後の購読者が切れたか）にも使う。
class SessionSubscribers {
  private readonly byKey = new Map<string, Set<Subscriber>>();

  count(key: string): number {
    return this.byKey.get(key)?.size ?? 0;
  }

  subscribe(sub: Subscriber, key: string): void {
    if (sub.key === key) return;
    this.unsubscribe(sub);
    let set = this.byKey.get(key);
    if (!set) {
      set = new Set();
      this.byKey.set(key, set);
    }
    set.add(sub);
    sub.key = key;
  }

  unsubscribe(sub: Subscriber): void {
    const key = sub.key;
    if (key === undefined) return;
    const set = this.byKey.get(key);
    set?.delete(sub);
    if (set?.size === 0) this.byKey.delete(key);
    sub.key = undefined;
  }

  /// id の確定（pending-xxx → 実 id 等）で、旧キーの購読者を新しいキーへ移す。
  rekey(from: string, to: string): void {
    if (from === to) return;
    for (const sub of [...(this.byKey.get(from) ?? [])]) this.subscribe(sub, to);
  }

  /// 生きた購読者全員へ送り、送れた数を返す（0 なら呼び出し側が push する）。
  deliver(key: string, evt: SessionEvent): number {
    let delivered = 0;
    for (const sub of [...(this.byKey.get(key) ?? [])]) {
      if (!sub.alive()) continue;
      sub.send(evt);
      delivered += 1;
    }
    return delivered;
  }
}

/// 接続 1 本分の「live で届けた採番済みイベント」の控え（mac の LiveDeliveredEvents と同じ）。
/// load_history の差分 replay は sinceSeq より後を全部返すので、購読に加わった後にこの接続へ live で
/// 届けた分も含まれ、同じ delta / done が二重に届く（本文の二重追記・完了処理の再実行）。
class LiveDeliveredEvents {
  private readonly keys = new Set<string>();
  // live buffer（1500 件）を覆える分だけ保持する（Set は挿入順なので古いものから捨てる）。
  private static readonly MAX_KEYS = 2000;

  note(evt: SessionEvent): void {
    const key = LiveDeliveredEvents.key(evt);
    if (key === undefined || this.keys.has(key)) return;
    this.keys.add(key);
    if (this.keys.size > LiveDeliveredEvents.MAX_KEYS) {
      const oldest = this.keys.values().next().value;
      if (oldest !== undefined) this.keys.delete(oldest);
    }
  }

  has(evt: SessionEvent): boolean {
    const key = LiveDeliveredEvents.key(evt);
    return key !== undefined && this.keys.has(key);
  }

  private static key(evt: SessionEvent): string | undefined {
    return evt.seq === undefined ? undefined : `${evt.sessionId ?? ""}:${evt.seq}:${evt.type}`;
  }
}

interface ConnectionState {
  sessionId?: string;
  session?: AgentSession;
  cwd?: string;
  /** agent_login_request を受けた接続だけ、ログイン状態の配信を購読する（切断で外す）。 */
  unsubscribeLogin?: () => void;
}

async function handleMessage(
  raw: string,
  adapter: AgentAdapter,
  state: ConnectionState,
  liveSessions: Map<string, AgentSession>,
  liveHistory: LiveHistoryIndex,
  store: JsonSessionStore,
  emit: Emit,
  pushService: PushService,
  connectionAuth: ConnectionAuth,
  sendRaw: Emit,
  adopt: () => void,
  defaultCwd: string,
  fanout: (key: string, outbound: SessionEvent) => void,
  subscribers: SessionSubscribers,
  liveDelivered: LiveDeliveredEvents,
  services: BridgeServices,
  /** WebSocket が受けた通か（openConnection の handle を参照）。true で、かつ接続がペアリング済みの端末（.device）のときだけ、送信に「人が打った発話」の印を付ける。 */
  fromClient: boolean
): Promise<void> {
  let inbound: SessionEvent;
  try {
    inbound = JSON.parse(raw) as SessionEvent;
  } catch {
    emit(event.unsupported("decode_failed"));
    return;
  }
  trafficMeter.record(`ws.in.${inbound.type}`, Buffer.byteLength(raw));
  // ペアリング済みの端末（.device の WebSocket）が入力欄から送った発話にだけ印を付ける（ClaudeTerminalSession が見て、
  // ターミナルに打ち込む）。.local（この PC の api-key を持つプロセス。デスクトップの会話画面を含む）の送信には付けない
  // （PC の中の別のプロセスが、本人の入力として claude を動かせないように。受け箱で届く）。印はイベントの
  // object に付け、metadata には入れない（履歴に記録されて再生される・端末の JSON で名乗れてしまうため）。
  if (fromClient && connectionAuth.principal.kind === "device" && (inbound.type === "user_message" || inbound.type === "queue_user_message")) {
    markTypedByUser(inbound);
  }

  const cwd = inbound.metadata?.cwd ?? state.cwd;
  const sessionId = inbound.sessionId ?? state.sessionId;

  // 予約の現状を、その session の購読者全員へ送る（再接続の差分には載せない）。
  const broadcastQueueState = (session: AgentSession): void => {
    const sid = session.sessionId;
    subscribers.deliver(`${adapter.id}:${sid}`, event.queueState(adapter.id, sid, queueItems(session)));
  };
  // ターンが終わった session の予約を 1 件送る（そのターンが終わればまた次へ）。
  const dispatchNext = (session: AgentSession): void => {
    const queue = sendQueues.get(session);
    if (!queue?.length || (sendsInFlight.get(session) ?? 0) > 0) return;
    // CLI がまだ続けている（留め置いた done の後に発話が残っている・知らせのターンの最中）間は送らない。
    if (liveHistory.currentTurn(adapter.id, session.sessionId) != null) return;
    while (queue.length > 0) {
      const next = queue.shift()!;
      const sid = session.sessionId;
      // 別経路（再送の user_message 等）で実行済みなら飛ばす。
      if (liveHistory.findMessageSeq(adapter.id, sid, next.clientMessageId) !== undefined) continue;
      // 履歴には普通の user_message として残し、いま見ている端末には予約カードを吹き出しに替える合図を送る。
      liveHistory.record({
        type: "user_message",
        agentId: adapter.id,
        sessionId: sid,
        messageId: next.clientMessageId,
        content: next.content,
        metadata: withoutAttachmentData(next.inbound.metadata)
      });
      subscribers.deliver(`${adapter.id}:${sid}`, event.queueDispatched(adapter.id, sid, next.clientMessageId, next.content));
      broadcastQueueState(session);
      const turnEmit: Emit = (o) => fanout(`${adapter.id}:${session.sessionId}`, o.type === "error" ? markTurnFailed(o) : o);
      void runQueued(session, next, turnEmit);
      return;
    }
    broadcastQueueState(session);
  };
  // fanout がターンの終端 done で呼べるよう、この session の送り出しを登録する（接続が替わっても同じ session なら上書きで足りる）。
  const registerDispatcher = (session: AgentSession | undefined): void => {
    if (session) queueDispatchers.set(session, () => dispatchNext(session));
  };
  registerDispatcher(state.session);
  const runQueued = async (session: AgentSession, next: QueuedMessage, turnEmit: Emit): Promise<void> => {
    sendsInFlight.set(session, (sendsInFlight.get(session) ?? 0) + 1);
    trackSend(services, 1);
    try {
      // 予約分も同じチャットの設定で実行し、画像は履歴で戻せるよう保管する（user_message と同じ）。
      prepareSend(session, next.inbound, adapter.id);
      const original: SessionEvent = { ...next.inbound, type: "user_message" };
      // 人が打った発話の印はコピーに引き継がれないので、予約に付いていれば付け直す（予約した接続の印のまま。
      // mainagent の予約と .local の接続の予約には付いていない）。
      if (isTypedByUser(next.inbound)) markTypedByUser(original);
      await session.send(voiceText(session, next.content, next.inbound), original, turnEmit);
    } catch (error) {
      turnEmit(event.error(adapter.id, session.sessionId, error instanceof Error ? error.message : String(error)));
    } finally {
      const remaining = (sendsInFlight.get(session) ?? 1) - 1;
      if (remaining > 0) sendsInFlight.set(session, remaining);
      else sendsInFlight.delete(session);
      trackSend(services, -1);
      dispatchNext(session);
    }
  };

  try {
  switch (inbound.type) {
    case "ping":
      emit(event.pong(adapter.id, sessionId));
      return;
    case "user_message": {
      const session = await acquireSession(adapter, liveSessions, state, sessionId, cwd, defaultCwd, services.terminal, undefined, services.bgSessions, services.publishClaude);
      state.session = session;
      state.sessionId = session.sessionId;
      // send 中に sessionId が pending-xxx → 本物の thread id に変わり得るので、
      // 登録時のキーを控えておき、確定後に古いキーを掃除する（Map リーク防止）。
      const priorKey = `${adapter.id}:${session.sessionId}`;
      liveSessions.set(priorKey, session);
      // 送信前に購読を取る。ターン完了後の adopt だけだと、新規チャットの初回ターン中に
      // 切断されたとき onGone が session を知らず、子プロセスが dispose されない。
      adopt();
      // セッションに渡す emit。出力はこの接続ではなく session key の購読者全員へ fanout する
      // （ターン途中に再接続した接続・同時に開いている別接続にも delta が届く）。
      // (1) session_started で id が pending-xxx → 実 id に確定したら、クライアントへ流す前に
      //     liveSessions のキーと購読者を付け替える。送信完了まで待つと、その間に実 id で
      //     再接続した側の action_response / interrupt が空振りし、user_message は resume で
      //     二つ目の session を開いてしまう。
      // (2) セッションが出す error は常にターン終端（非0終了・spawn 失敗等は done を伴わない）。
      //     印を付けて currentTurn が「進行中」のまま残らないようにする。
      let boundKey = priorKey;
      let boundSid = session.sessionId;
      let recordedUser: SessionEvent | undefined;
      const turnEmit: Emit = (outbound) => {
        if (outbound.type === "session_started" && outbound.sessionId) {
          const nextKey = `${adapter.id}:${outbound.sessionId}`;
          if (nextKey !== boundKey) {
            if (!liveSessions.has(nextKey)) liveSessions.set(nextKey, session);
            if (liveSessions.get(boundKey) === session) liveSessions.delete(boundKey);
            // 旧キーの購読者（この接続を含む）も実 id 側へ移す。移さないと以後の出力が誰にも届かない。
            subscribers.rekey(boundKey, nextKey);
            // 旧キーの live 記録（初回ターンの user_message 等）はもう誰も参照しない。done が無いまま残ると
            // currentTurn(旧 id) が進行中のまま居座り、新規チャットのたびに孤立した記録が増える。
            // 旧キーを別 session が使っていなければ捨てる（user_message は下で実 id 側に載せ直す）。
            if (!liveSessions.has(boundKey)) liveHistory.release(adapter.id, boundSid);
            boundKey = nextKey;
            boundSid = outbound.sessionId;
            // 旧 id 側に記録した user_message を実 id 側にも載せる。無いと実 id の currentTurn が
            // 最初の delta まで「考え中」を見逃し（再接続の turn_resume / 固着プローブ）、同じ
            // clientMessageId の実 id 経由の再送も input_ack で止められず二重実行になる。
            if (recordedUser) liveHistory.record({ ...recordedUser, sessionId: outbound.sessionId, seq: undefined });
            if (state.session === session) {
              state.sessionId = outbound.sessionId;
              adopt();
            }
          }
        }
        fanout(boundKey, outbound.type === "error" ? markTurnFailed(outbound) : outbound);
      };
      const clientMessageId = inbound.metadata?.clientMessageId ?? inbound.messageId;
      const baseSeq = parseOptionalPositiveInt(inbound.metadata?.baseSeq);
      const followUp = inbound.metadata?.followUp === "true";
      // Whether a turn was already in flight BEFORE we record this message
      // (must be read before record(), which would itself make currentTurn non-null).
      const turnLive = liveHistory.currentTurn(adapter.id, session.sessionId) != null;
      const existingSeq = clientMessageId
        ? liveHistory.findMessageSeq(adapter.id, session.sessionId, clientMessageId)
        : undefined;
      if (existingSeq !== undefined && clientMessageId) {
        emit(event.inputAck(adapter.id, session.sessionId, clientMessageId, existingSeq));
        return;
      }
      // A follow-up is deliberately based on a seq before the in-flight turn's own
      // user_message, so skip the optimistic-concurrency guard for it.
      // baseSeq=0 は live の seq をまだ一つも受け取っていない状態（全履歴ロード直後など。履歴行・
      // 接続時 session_started には seq を載せない）。ここで弾くと iOS は sinceSeq 同期で追いつけず
      // 再送が競合し続けるので、ガードの対象にしない。
      if (!followUp && baseSeq !== undefined && baseSeq > 0 && liveHistory.hasUserInputAfter(adapter.id, session.sessionId, baseSeq)) {
        emit(event.inputRejected(adapter.id, session.sessionId, clientMessageId, "conflict"));
        return;
      }
      // live buffer には添付の本体（attachment_*_b64、最大 10MB）を載せない。セッション終了後も
      // index に残り続け、差分 replay のたびに再送される。send/inject には元の inbound を渡す。
      recordedUser = liveHistory.record({
        type: "user_message",
        agentId: adapter.id,
        sessionId: session.sessionId,
        messageId: clientMessageId,
        content: inbound.content,
        metadata: withoutAttachmentData(inbound.metadata)
      });
      const userSeq = recordedUser.seq;
      if (clientMessageId && userSeq !== undefined) {
        emit(event.inputAck(adapter.id, session.sessionId, clientMessageId, userSeq));
      }
      // このチャットだけのモデル / Effort / モード（印のある送信だけ）を渡し、画像は履歴で戻せるよう保管する（mac と同じ）。
      prepareSend(session, inbound, adapter.id);
      // Mid-turn follow-up: if the agent can absorb it and a turn is live, push it
      // into the running turn instead of starting a new one (no second query).
      if (
        followUp &&
        turnLive &&
        typeof session.inject === "function" &&
        session.inject(voiceText(session, inbound.content ?? "", inbound), inbound, turnEmit)
      ) {
        return;
      }
      registerDispatcher(session);
      sendsInFlight.set(session, (sendsInFlight.get(session) ?? 0) + 1);
      trackSend(services, 1);
      try {
        await session.send(voiceText(session, inbound.content ?? "", inbound), inbound, turnEmit);
      } catch (error) {
        // user_message は記録済みなので、ここで終端の error を出さないとターンが進行中のまま残る。
        turnEmit(event.error(adapter.id, session.sessionId, error instanceof Error ? error.message : String(error)));
      } finally {
        const remaining = (sendsInFlight.get(session) ?? 1) - 1;
        if (remaining > 0) sendsInFlight.set(session, remaining);
        else sendsInFlight.delete(session);
        trackSend(services, -1);
      }
      // ターンが終わったので、預かっている予約があれば次を送る。
      dispatchNext(session);
      state.sessionId = session.sessionId;
      const settledKey = `${adapter.id}:${session.sessionId}`;
      // 別接続が同じキーに登録した別 session は上書きしない（向こうの子プロセスが孤児化する）。
      if (!liveSessions.has(settledKey)) liveSessions.set(settledKey, session);
      // pending-xxx や旧 sessionId のキーに取り残された死んだ session を掃除（自分の session のときだけ）。
      if (priorKey !== settledKey && liveSessions.get(priorKey) === session) liveSessions.delete(priorKey);
      if (sessionId) {
        const requestedKey = `${adapter.id}:${sessionId}`;
        if (requestedKey !== settledKey && liveSessions.get(requestedKey) === session) liveSessions.delete(requestedKey);
      }
      return;
    }
    case "action_response": {
      const requestId = inbound.metadata?.requestId ?? inbound.messageId;
      if (!requestId) {
        emit(event.unsupported("action_response_missing_request_id"));
        return;
      }
      const decision = inbound.content ?? inbound.metadata?.decision ?? "";
      // mainagent の承認カード（Bridge が出したもの）への返事は orchestrator が受け取る。
      if (orchestrator.resolveApproval(requestId, decision)) return;
      // ターミナルの会話のカードは、まだ送っていない（見ているだけの）接続からも答えられるようにする。
      const target =
        (sessionId ? terminalSessionFor(adapter.id, sessionId, liveSessions, services.terminal) : undefined) ??
        state.session ??
        (sessionId ? liveSessions.get(`${adapter.id}:${sessionId}`) : undefined);
      if (!target?.respondToAction) {
        emit(event.unsupported("action_response_not_supported"));
        return;
      }
      // answers（JSON）に加えて metadata 全体も渡す（answers_json 等をそのまま読む adapter がある。mac と同じ）。
      await target.respondToAction(
        requestId,
        decision,
        { ...(inbound.metadata ?? {}), ...parseJsonObject(inbound.metadata?.answers) }
      );
      // mainagent が頼んだ子の承認なら、mainagent 側の「承認待ち」も外す（答えたことを知らせない adapter がある）。
      orchestrator.noteApprovalAnswered(adapter.id, requestId);
      return;
    }
    case "turn_status_request": {
      // 生成中固着の能動プローブ。現在のターン状態を再送してライブ接続のまま
      // done を取りこぼした spinner を解除させる（idle なら done、進行中なら turn_resume）。
      if (!sessionId) return;
      await replyTurnStatus(adapter, sessionId, state, liveSessions, liveHistory, emit, sendRaw, services);
      return;
    }
    case "stop_task_request": {
      const requestId = inbound.metadata?.requestId;
      const taskId = inbound.metadata?.taskId;
      if (!requestId || !taskId) return;
      const rowId = inbound.metadata?.rowId || undefined;
      const epoch = inbound.metadata?.epoch || undefined;
      const started = Date.now();
      const target: { sessionId: string; stopTask?: AgentSession["stopTask"] } | undefined =
        (sessionId ? terminalSessionFor(adapter.id, sessionId, liveSessions, services.terminal) : undefined) ??
        state.session ??
        (sessionId ? liveSessions.get(`${adapter.id}:${sessionId}`) : undefined);
      const sid = target?.sessionId ?? sessionId;
      let outcome: StopTaskOutcome;
      if (!target) outcome = { kind: "notRunning" };
      else if (!target.stopTask) outcome = { kind: "unsupported" };
      else {
        outcome = await withStopTimeout(
          target.stopTask({ taskId, rowId, epoch }).catch((err): StopTaskOutcome => ({ kind: "failed", message: err instanceof Error ? err.message : String(err) }))
        );
      }
      // もう動いていない・行が無いときは、返事の前に全行を取り直させる（turn_status_request と同じ応答）。
      if (sid && (outcome.kind === "notRunning" || outcome.kind === "stale")) {
        await replyTurnStatus(adapter, sid, state, liveSessions, liveHistory, emit, sendRaw, services);
      }
      sendRaw(event.stopTaskResult(adapter.id, sid ?? "", requestId, taskId, rowId, outcome));
      console.log(`stop-task agent=${adapter.id} row=${rowId ?? taskId} reason=${stopReason(outcome)} ms=${Date.now() - started}`);
      return;
    }
    // claude --bg のセッションの一覧・停止・削除。返事は要求した接続にだけ送る（採番しない）。
    case "list_bg_sessions_request": {
      await services.bgSessions.ready();
      const rows = services.bgSessions.rows();
      for (const row of rows) sendRaw(event.bgSessionItem(row.sessionId, JSON.stringify(row)));
      sendRaw(event.bgSessionListEnd(rows.length));
      return;
    }
    case "stop_bg_session_request":
    case "delete_bg_session_request": {
      const op = inbound.type === "stop_bg_session_request" ? "stop" : "delete";
      const id = inbound.metadata?.id ?? "";
      const outcome = await services.bgSessions.operate(op, sessionId, id);
      sendRaw(event.bgSessionResult(sessionId, op, outcome.ok, id, outcome.shells, outcome.text));
      return;
    }
    case "register_activity_token": {
      // トンネル経由の端末（.device）の WS からだけ受ける（.local は捨てる）。agentId は見ない（BACKGROUND_CONTROL §8.6）。
      const { principal } = connectionAuth;
      if (principal.kind === "device") services.liveActivity.register(principal.deviceKeyId, inbound.content, inbound.metadata);
      return;
    }
    case "list_sessions_request": {
      const limit = Number.parseInt(inbound.metadata?.limit ?? "50", 10);
      let sessions = await adapter.listSessions(Number.isFinite(limit) ? limit : 50, cwd);
      // ターミナルで開いている Claude Code の会話は印を付けて先頭へ。まだ記録の無いものも「ターミナル」として出す。
      if (adapter.id === "claude" && services.terminal) {
        const live = services.terminal.registry.liveEntries().filter((e) => !cwd || !e.cwd || sameCwd(e.cwd, cwd));
        const liveIds = new Set(live.map((e) => e.sessionId));
        const listed = new Set(sessions.map((s) => s.sessionId));
        const extra = live
          .filter((e) => !listed.has(e.sessionId))
          .map((e) => ({ sessionId: e.sessionId, title: "ターミナル", lastActive: new Date(e.startedAt).toISOString(), cwd: e.cwd }));
        sessions = [...extra, ...sessions].map((s) => (liveIds.has(s.sessionId) ? { ...s, terminal: true } : s));
        sessions.sort((a, b) => Number(Boolean(b.terminal)) - Number(Boolean(a.terminal)));
      }
      // ターンの後もサブエージェントか終わっていない dynamic workflow が動いている会話（コマンドだけでは数えない）。
      // ターミナルの Claude Code の会話は、その台帳の行で見る。
      const background = backgroundSessionIds(adapter.id, liveSessions, liveHistory);
      if (adapter.id === "claude" && services.terminal) for (const sid of services.terminal.registry.backgroundSessionIds()) background.add(sid);
      // 進行中ターンを持つ session には running フラグを立てる（サイドバーの稼働中表示用）。
      for (const summary of sessions) {
        const running = liveHistory.currentTurn(adapter.id, summary.sessionId) != null;
        const awaiting = liveHistory.awaitingAnswer(adapter.id, summary.sessionId);
        // 音声会話モードのフォールバック（本文末尾の `<voice-context>`）が一覧のタイトルに残った場合。
        const custom = store.titles.title(adapter.id, summary.sessionId);
        const shown = custom
          ? { ...summary, title: custom }
          : summary.title.includes("<v") ? { ...summary, title: stripVoiceContext(summary.title) } : summary;
        const item = event.sessionListItem(adapter.id, shown, running, awaiting);
        // ターンが終わってもサブエージェントか workflow が動いている（開いていないチャットでもサイドバーで稼働中に見せる）。
        // running・awaiting と同じく metadata の "1" で載せる（mac と同じ）。
        if (background.has(summary.sessionId)) item.metadata = { ...item.metadata, background: "1" };
        emit(item);
      }
      emit(event.sessionListEnd(adapter.id));
      return;
    }
    case "load_history_request": {
      if (!sessionId) {
        emit(event.unsupported("load_history_missing_session_id"));
        return;
      }
      const sinceSeq = parseOptionalPositiveInt(inbound.metadata?.sinceSeq);
      // 履歴が長すぎると読み取り時にクラッシュ/ハングするため、初回ロードは末尾(最新)N件に制限する。
      // metadata.maxMessages で上書き可能（0 を渡すと無制限）。
      const maxMessages = parseOptionalPositiveInt(inbound.metadata?.maxMessages) ?? DEFAULT_HISTORY_LIMIT;
      if (sinceSeq !== undefined) {
        // live buffer が sinceSeq の続きを途切れなく持っていれば、その差分（新着なしなら空）だけ返す。
        const liveDelta = liveHistory.replayableDelta(adapter.id, sessionId, sinceSeq);
        if (liveDelta) {
          // 採番済みイベントの再送なので record を通さない（index に同じ seq で二重記録され、
          // currentTurn の本文が倍になる）。切断中でも push しない。この接続へ既に live で届けたものは
          // 送らない（turn_resume の snapshotSeq と併せて、再接続時の本文の二重化を防ぐ）。
          for (const item of liveDelta) {
            if (!liveDelivered.has(item)) sendRaw(item);
          }
          emit(event.loadHistoryEnd(adapter.id, sessionId, liveHistory.latestSeq(adapter.id, sessionId)));
          return;
        }
      }
      // 続きを返せない（buffer から溢れた / Bridge 再起動で採番が振り直された）ときは全履歴に落とす。
      // ストア履歴の番号（メッセージ index）は live の seq（イベント番号）と別体系なので sinceSeq では
      // 絞らない（mac と同じ。重複はクライアント側で除く）。同じ理由で履歴行に seq を載せず、
      // loadHistoryEnd も live の seq だけを返す（iOS の lastHistorySeq に別体系の番号を混ぜない）。
      const fullHistory = await adapter.loadHistory(sessionId);
      // 最新 maxMessages 件のみ送る。
      const history = maxMessages > 0 && fullHistory.length > maxMessages
        ? fullHistory.slice(-maxMessages)
        : fullHistory;
      for (const message of history) {
        // 音声会話モードでモデルにだけ渡した `<voice-context>` はユーザーに見せない。
        const content = message.role === "user" ? stripVoiceContext(message.content) : message.content;
        // 送った画像は目印（[image "…" attached: …]）から保管済みの実画像に戻す（mac の enrichHistory と同じ）。
        // 会話記録に画像そのものが残っている（Claude の transcript）ときはそれを使う。
        const kept = (message as HistoryMessageWithImages).attachments ?? [];
        const restored = kept.length > 0 ? { content, attachments: kept } : restoreHistoryImages({ ...message, content });
        const item = event.historyMessage(adapter.id, sessionId, { ...message, content: restored.content, seq: undefined });
        if (restored.attachments.length > 0) item.metadata = { ...item.metadata, ...historyAttachmentMetadata(restored.attachments) };
        emit(item);
      }
      emit(event.loadHistoryEnd(adapter.id, sessionId, liveHistory.latestSeq(adapter.id, sessionId) || undefined));
      return;
    }
    case "rename_session_request": {
      if (!sessionId) {
        emit(event.renameSessionResult(adapter.id, "", inbound.content ?? "", false, "sessionId is required"));
        return;
      }
      // 名前は全エージェント共通の付け替え（store.titles）に持ち、一覧を返すときに重ねる（mac の SessionOverrideStore と同じ）。
      // エージェント自身の記録（Claude Code の会話記録・ターミナルの会話）は書き換えられない・まだ無いことがあるため。
      // 空の名前は付け替えを外す。エージェント側の名前も分かる範囲で揃える（codex の session_index 等。失敗しても構わない）。
      const title = (inbound.content ?? "").trim();
      if (title) await adapter.renameSession(sessionId, title).catch(() => false);
      const ok = store.titles.setTitle(adapter.id, sessionId, title);
      emit(event.renameSessionResult(adapter.id, sessionId, store.titles.title(adapter.id, sessionId) ?? "", ok, ok ? undefined : "save failed"));
      // bg セッションの行は名前も持つので、読み直して送る。
      if (adapter.id === "claude" && services.bgSessions.entryFor(sessionId)) void services.bgSessions.refresh();
      return;
    }
    case "list_commands_request": {
      const commands = await adapter.listCommands();
      for (const command of commands) emit(event.commandItem(adapter.id, command));
      emit(event.commandsEnd(adapter.id));
      return;
    }
    case "agent_info_request": {
      // cwd の git ブランチを引いて相乗りで返す（mac と同じ。git 管理外は付けない）。
      const [info, branch] = await Promise.all([adapter.currentInfo(), gitBranch(cwd, adapter.id, adapter.runtimeLabel)]);
      emit(event.agentInfoResult(adapter.id, info, { branch, cwd }));
      return;
    }
    case "set_model_request":
      try {
        await adapter.setModel(
          inbound.metadata?.model ?? "",
          inbound.metadata?.provider,
          inbound.metadata?.reasoningEffort ?? inbound.metadata?.effort,
          inbound.metadata?.codexMode ?? inbound.metadata?.mode
        );
        emit(event.setModelResult(adapter.id, true));
        emit(event.agentInfoResult(adapter.id, await adapter.currentInfo()));
      } catch (error) {
        emit(event.setModelResult(adapter.id, false, error instanceof Error ? error.message : String(error)));
      }
      return;
    case "list_models_request": {
      const providers = await adapter.listAvailableModels();
      for (const provider of providers) emit(event.modelProviderItem(adapter.id, provider));
      emit(event.modelsEnd(adapter.id));
      return;
    }
    case "list_cron_jobs_request": {
      for (const job of await services.cron.list(adapter)) emit(event.cronJobItem(adapter.id, job));
      emit(event.cronJobListEnd(adapter.id));
      return;
    }
    case "cron_outputs_request": {
      // 結果ファイルを直接読むので、どのエージェントの接続からでも引ける（mac と同じ）。
      const jobId = inbound.sessionId;
      if (!jobId) {
        emit(event.unsupported("cron_outputs_missing_job_id"));
        return;
      }
      const limit = Number.parseInt(inbound.metadata?.limit ?? "200", 10);
      for (const item of services.cronOutputs.loadPast(jobId, Number.isFinite(limit) && limit > 0 ? limit : 200)) sendRaw(item);
      emit(event.cronOutputsEnd(adapter.id, jobId));
      return;
    }
    case "create_cron_request": {
      const meta = inbound.metadata ?? {};
      const schedule = meta.schedule ?? "";
      if (!schedule.trim()) {
        emit(event.cronJobResult(adapter.id, "create", undefined, false, "schedule is required"));
        return;
      }
      const repeat = meta.repeat !== undefined ? Number.parseInt(meta.repeat, 10) : undefined;
      try {
        const jobId = await services.cron.create(adapter, {
          name: meta.name,
          schedule,
          prompt: inbound.content ?? "",
          deliver: meta.deliver,
          repeatCount: repeat !== undefined && Number.isFinite(repeat) ? repeat : undefined,
          cwd: meta.cwd ?? state.cwd,
          permissionMode: meta.permissionMode || undefined
        });
        emit(event.cronJobResult(adapter.id, "create", jobId, true, "ok"));
      } catch (error) {
        emit(event.cronJobResult(adapter.id, "create", undefined, false, error instanceof Error ? error.message : String(error)));
      }
      return;
    }
    case "delete_cron_request":
    case "pause_cron_request":
    case "resume_cron_request": {
      const op = inbound.type.replace("_cron_request", "") as CronOp;
      // job id は sessionId で来る（state.sessionId に落とすとチャットの id を消してしまう）。
      const jobId = inbound.sessionId;
      if (!jobId) {
        emit(event.cronJobResult(adapter.id, op, undefined, false, "jobId is required"));
        return;
      }
      try {
        await services.cron.op(adapter, op, jobId);
        emit(event.cronJobResult(adapter.id, op, jobId, true, "ok"));
      } catch (error) {
        emit(event.cronJobResult(adapter.id, op, jobId, false, error instanceof Error ? error.message : String(error)));
      }
      return;
    }
    case "list_skills_request":
      // OpenCode は ~/.config/opencode/skills を read-only で列挙する。他は cwd の .claude/skills かホームのスキル。
      if (adapter.id === "opencode") {
        for (const skill of listOpencodeSkills()) emit(event.skillItem(adapter.id, skill.name, skill.description));
      } else {
        for (const skill of await listSkills(adapter.id, adapter.runtimeLabel, cwd)) emit(event.skillItem(adapter.id, skill.name, skill.description));
      }
      emit(event.skillsEnd(adapter.id));
      return;
    case "load_skill_request": {
      const skillName = inbound.metadata?.name ?? "";
      const body = adapter.id === "opencode"
        ? loadOpencodeSkill(skillName) ?? ""
        : (await loadSkill(adapter.id, adapter.runtimeLabel, cwd, skillName)) ?? "";
      emit(event.skillContent(adapter.id, skillName, body));
      return;
    }
    case "save_skill_request": {
      const skillName = inbound.metadata?.name ?? "";
      if (adapter.id === "opencode") {
        emit(event.skillOpResult(adapter.id, "save", skillName, false, "opencode skills are read-only"));
        return;
      }
      const r = await saveSkill(adapter.id, adapter.runtimeLabel, cwd, skillName, inbound.content ?? "");
      emit(event.skillOpResult(adapter.id, "save", skillName, r.ok, r.ok ? undefined : r.message));
      // 保存できたら一覧を送り直す（mac と同じ。削除は送り直さない）。
      if (r.ok) {
        for (const skill of await listSkills(adapter.id, adapter.runtimeLabel, cwd)) emit(event.skillItem(adapter.id, skill.name, skill.description));
        emit(event.skillsEnd(adapter.id));
      }
      return;
    }
    case "delete_skill_request": {
      const skillName = inbound.metadata?.name ?? "";
      if (adapter.id === "opencode") {
        emit(event.skillOpResult(adapter.id, "delete", skillName, false, "opencode skills are read-only"));
        return;
      }
      const r = await deleteSkill(adapter.id, adapter.runtimeLabel, cwd, skillName);
      emit(event.skillOpResult(adapter.id, "delete", skillName, r.ok, r.ok ? undefined : r.message));
      return;
    }
    case "agent_login_request": {
      const target = inbound.agentId ?? "";
      if (!target) return;
      if (!state.unsubscribeLogin) state.unsubscribeLogin = services.login.subscribe((s) => emit(loginStatusEvent(s)));
      const runtimeLabel = services.adapters.get(target)?.runtimeLabel;
      switch (inbound.metadata?.op) {
        case "start":
          await services.login.start(target, runtimeLabel);
          return;
        case "code":
          services.login.submitCode(target, inbound.content ?? "");
          return;
        case "cancel":
          services.login.cancel(target);
          return;
        default:
          emit(loginStatusEvent(services.login.status(target) ?? { agentId: target, phase: "idle", needsCode: false }));
          return;
      }
    }
    case "extensions_share_request": {
      const meta = inbound.metadata ?? {};
      const labelOf = (id: string): string | undefined => services.adapters.get(id)?.runtimeLabel;
      const content = meta.op === "sync"
        ? await extensionsSync(labelOf, parseJsonArray(meta.items), parseJsonArray(meta.targets))
        : await extensionsList(labelOf);
      emit({ type: "extensions_share_result", agentId: adapter.id, content, metadata: { op: meta.op ?? "list" } });
      return;
    }
    case "usage_request":
      // 応答は読み直しが終わったときの usage_report（全接続へ配る）。
      void services.usage.requestRefresh();
      return;
    case "sites_request": {
      // 送ってきた接続にだけ返す。agentId は見ない。metadata.force = "1" で 5 分のキャッシュを使わない。
      let list: SiteList;
      try {
        list = await services.sites.list(inbound.metadata?.force === "1");
      } catch (err) {
        const message = String(err instanceof Error ? err.message : err).slice(0, 400);
        list = {
          hosts: [
            { host: "vercel", state: "error", message },
            { host: "cloudflare", state: "error", message }
          ],
          items: [],
          at: new Date().toISOString()
        };
      }
      emit({ type: "sites_report", content: JSON.stringify(list) });
      return;
    }
    case "heartbeat_get":
    case "heartbeat_set":
    case "heartbeat_run_now": {
      // メインの定期チェック（Bridge 全体のもの。agentId は見ない）。
      const heartbeat = services.heartbeat;
      if (!heartbeat) {
        emit(event.unsupported(inbound.type));
        return;
      }
      if (inbound.type === "heartbeat_set") {
        let patch: unknown;
        try {
          patch = JSON.parse(inbound.content ?? "{}");
        } catch {
          patch = undefined;
        }
        // 保存して全接続へ配る（送ってきた接続にも届く）。
        heartbeat.setSettings(patch);
        return;
      }
      // run_now: 回し始めたら、その知らせ（running）が全接続へ届く。回さなかったら今の状態を返す。
      if (inbound.type === "heartbeat_run_now" && heartbeat.runNow()) return;
      emit(heartbeat.statusEvent());
      return;
    }
    case "list_projects_request":
    case "add_project_request":
    case "remove_project_request":
    case "reorder_projects_request": {
      const meta = inbound.metadata ?? {};
      let items: ProjectItem[];
      if (inbound.type === "add_project_request") items = services.projects.add(meta.path ?? "", meta.name);
      // 「メイン」（mainagent のフォルダ）は消せない。今の一覧を返して、画面を元に戻させる。
      else if (inbound.type === "remove_project_request") items = isMainWorkspace(meta.path) ? services.projects.list() : services.projects.remove(meta.path ?? "");
      else if (inbound.type === "reorder_projects_request") items = services.projects.reorder(parseJsonArray(meta.paths));
      else items = services.projects.list();
      for (const item of items) emit(event.projectItem(adapter.id, item));
      emit(event.projectsEnd(adapter.id));
      return;
    }
    case "list_mcp_servers_request": {
      for (const s of await listMcp(adapter.id, adapter.runtimeLabel)) emit(event.mcpServerItem(adapter.id, s.name, s.transport));
      emit(event.mcpServersEnd(adapter.id));
      return;
    }
    case "register_mcp_server_request": {
      const meta = inbound.metadata ?? {};
      const serverName = meta.serverName ?? "";
      const spec: McpRegisterSpec = {
        serverName,
        transportKind: meta.transportKind === "command" ? "command" : "url",
        url: meta.url,
        command: meta.command,
        args: parseJsonArray(meta.args),
        authType: meta.authType ?? "none",
        env: parseJsonObject(meta.env)
      };
      // runtimeLabel: WSL で動く adapter は CLI を wsl.exe 経由で実行し、WSL 側の設定を読み書きする。
      const r = await registerMcp(adapter.id, spec, adapter.runtimeLabel);
      emit(event.mcpServerOpResult(adapter.id, "register", serverName, r.ok, r.message));
      if (r.ok) {
        for (const s of await listMcp(adapter.id, adapter.runtimeLabel)) emit(event.mcpServerItem(adapter.id, s.name, s.transport));
        emit(event.mcpServersEnd(adapter.id));
      }
      return;
    }
    case "delete_mcp_server_request": {
      const serverName = inbound.metadata?.serverName ?? "";
      const r = await deleteMcp(adapter.id, serverName, adapter.runtimeLabel);
      emit(event.mcpServerOpResult(adapter.id, "delete", serverName, r.ok, r.message));
      if (r.ok) {
        for (const s of await listMcp(adapter.id, adapter.runtimeLabel)) emit(event.mcpServerItem(adapter.id, s.name, s.transport));
        emit(event.mcpServersEnd(adapter.id));
      }
      return;
    }
    case "register_push_token": {
      // トンネル経由の端末（.device）の WS からだけ受け、その端末の行の push に入れる（spec/PROTOCOL-v3.md §14）。
      // metadata.deviceId は読まない。同じトークンが別の端末の行にあり clientDeviceId が違えば、何も変えない。
      const { principal, devices } = connectionAuth;
      if (principal.kind === "device" && inbound.content) {
        const result = devices.setPush(principal.deviceKeyId, inbound.content, inbound.metadata?.environment, inbound.metadata?.locale);
        // 宛先が変わったら /v3/push-targets に登録し直す（mac の DeviceStore.onPushTargetsChanged）。
        if (result === "ok") pushService.scheduleTargetsSync();
      }
      return;
    }
    case "register_e2e_key": {
      // 端末の鍵はペアリングでしか決まらない。受け付けない（spec/PROTOCOL-v3.md §13.6）。
      emit({ type: "e2e_register_result", agentId: adapter.id, metadata: { ok: "0", reason: "unsupported" } });
      return;
    }
    case "e2e_confirm":
      // 鍵確認用フレーム（PROTOCOL-v3 §13.6）。open 成功時点で目的を果たしているので中身は無視。
      return;
    case "session_warm": {
      // チャットを開いた。送る前に CLI を起こしておく（capabilities.warm の agent だけが送ってくる）。
      // warm できる adapter（Claude Code の常駐プロセス）は、新規接続でもここで session を開く（mac と同じ）。
      // それ以外は既にある session を起こすだけ。unsupported も返さない（iPhone に吹き出しが出るため）。
      let target = state.session ?? (sessionId ? liveSessions.get(`${adapter.id}:${sessionId}`) : undefined);
      if (!target && adapter.supportsWarm) {
        target = await acquireSession(adapter, liveSessions, state, sessionId, cwd, defaultCwd, services.terminal, undefined, services.bgSessions, services.publishClaude);
        state.session = target;
        state.sessionId = target.sessionId;
        if (!liveSessions.has(`${adapter.id}:${target.sessionId}`)) liveSessions.set(`${adapter.id}:${target.sessionId}`, target);
        // 開いただけで切断されても、購読者が居ない session として dispose されるようにする。
        adopt();
      }
      const overrides = parseChatOverrides(inbound.metadata);
      if (target && overrides) target.applyOverrides?.(overrides);
      await target?.warm?.();
      return;
    }
    case "interrupt": {
      const target =
        (sessionId ? terminalSessionFor(adapter.id, sessionId, liveSessions, services.terminal) : undefined) ??
        state.session ??
        (sessionId ? liveSessions.get(`${adapter.id}:${sessionId}`) : undefined);
      if (target?.interrupt) {
        await target.interrupt();
        return;
      }
      // 停止できないセッション（echo・履歴専用 Codex 等）。unsupported を返すと iOS がチャットに「未対応メッセージ」
      // バブルを出すので返さない（mac と同じく無視）。iOS は停止を押した時点で楽観的に idle に
      // しているため、ターンがまだ続いていれば現在の状態を送り直して生成中表示と同じ bubble への
      // 追記を戻す（turn_status_request と同じ応答）。
      const sid = target?.sessionId ?? sessionId;
      const t = sid ? liveHistory.currentTurn(adapter.id, sid) : null;
      if (sid && t) {
        emit(withSnapshotSeq(
          event.turnResume(adapter.id, sid, t.phase, t.messageId, t.textSoFar, t.toolUseId, t.toolName, t.toolKind),
          liveHistory.latestSeq(adapter.id, sid)
        ));
      }
      return;
    }
    case "queue_user_message": {
      const clientMessageId = inbound.metadata?.clientMessageId ?? inbound.messageId ?? crypto.randomUUID();
      const session = await acquireSession(adapter, liveSessions, state, sessionId, cwd, defaultCwd, services.terminal, undefined, services.bgSessions, services.publishClaude);
      state.session = session;
      state.sessionId = session.sessionId;
      if (!liveSessions.has(`${adapter.id}:${session.sessionId}`)) liveSessions.set(`${adapter.id}:${session.sessionId}`, session);
      adopt();
      registerDispatcher(session);
      const busy = (sendsInFlight.get(session) ?? 0) > 0 || liveHistory.currentTurn(adapter.id, session.sessionId) != null;
      if (busy) {
        // 生成中 → 預かる。同じものの再送・実行済みは預け直さず ack だけ返す。
        const queue = sendQueues.get(session) ?? [];
        const duplicate =
          queue.some((m) => m.clientMessageId === clientMessageId) ||
          liveHistory.findMessageSeq(adapter.id, session.sessionId, clientMessageId) !== undefined;
        if (!duplicate) {
          queue.push({ clientMessageId, content: inbound.content ?? "", inbound });
          sendQueues.set(session, queue);
          broadcastQueueState(session);
        }
        emit(event.queueAck(adapter.id, session.sessionId, clientMessageId));
        return;
      }
      // 空いている → すぐ送る（user_message と同じ流れ）。予約カードを吹き出しに替える合図を先に送る。
      if (liveHistory.findMessageSeq(adapter.id, session.sessionId, clientMessageId) === undefined) {
        const dispatched = event.queueDispatched(adapter.id, session.sessionId, clientMessageId, inbound.content ?? "");
        if (subscribers.deliver(`${adapter.id}:${session.sessionId}`, dispatched) === 0) sendRaw(dispatched);
      }
      await handleMessage(
        JSON.stringify({ ...inbound, type: "user_message", sessionId: session.sessionId, metadata: { ...inbound.metadata, clientMessageId } }),
        adapter, state, liveSessions, liveHistory, store, emit, pushService, connectionAuth, sendRaw, adopt, defaultCwd, fanout, subscribers, liveDelivered, services, fromClient
      );
      return;
    }
    case "queue_remove": {
      const clientMessageId = inbound.metadata?.clientMessageId ?? inbound.messageId;
      const session = state.session ?? (sessionId ? liveSessions.get(`${adapter.id}:${sessionId}`) : undefined);
      const queue = session ? sendQueues.get(session) : undefined;
      if (!session || !queue || !clientMessageId) return;
      const kept = queue.filter((m) => m.clientMessageId !== clientMessageId);
      if (kept.length === queue.length) return;
      sendQueues.set(session, kept);
      broadcastQueueState(session);
      return;
    }
    default:
      emit(event.unsupported(inbound.type));
  }
  } catch (error) {
    // send()/openSession() 等が throw しても接続を落とさず、エラーを 1 イベントとして
    // クライアントに返す（set_model_request 等で既にやっている流儀に揃える）。
    emit(event.error(adapter.id, sessionId, error instanceof Error ? error.message : String(error)));
  }
}

/**
 * session のサブエージェントのカードの全行（subagentSnapshot。subtype "workflow_snapshot"、kind "subagents"、epoch 付き）。
 * トラッカーを持たない session は undefined。claude で session がまだ無ければ、ターミナルの台帳の全行。
 * 聞いている間に subagents の payload が記録されたら聞き直す（記録した行より古い全行を後から送って、新しい状態を上書きしない
 * ように）。写しが持っていない世代（作り直した session・ターミナルのトラッカー）なら、写しをそれに合わせる。
 */
async function sessionSubagentSnapshot(
  agentId: string,
  sessionId: string,
  session: AgentSession | undefined,
  liveHistory: LiveHistoryIndex,
  terminal: TerminalServices | undefined
): Promise<string | undefined> {
  const ask = async (): Promise<string | undefined> => {
    if (session?.subagentSnapshot) return (await session.subagentSnapshot()) ?? undefined;
    return agentId === "claude" ? terminal?.registry.subagentSnapshot(sessionId) : undefined;
  };
  let snapshot: string | undefined;
  for (let i = 0; i < 3; i += 1) {
    const delivered = liveHistory.subagentsDelivered(agentId, sessionId);
    snapshot = await ask().catch(() => undefined);
    if (snapshot === undefined || liveHistory.subagentsDelivered(agentId, sessionId) === delivered) break;
  }
  if (snapshot !== undefined) liveHistory.adoptSubagents(agentId, sessionId, snapshot);
  return snapshot;
}

/** 接続したとき・turn_status_request に送る、サブエージェントのカードの全行。session の全行が無ければ写しから作る。 */
async function subagentsCard(
  agentId: string,
  sessionId: string,
  session: AgentSession | undefined,
  liveHistory: LiveHistoryIndex,
  terminal: TerminalServices | undefined
): Promise<string | undefined> {
  return (await sessionSubagentSnapshot(agentId, sessionId, session, liveHistory, terminal)) ?? liveHistory.cards(agentId, sessionId)?.subagentsSnapshot();
}

/**
 * バックグラウンドの作業（ターンより長く動くサブエージェント・シェル・dynamic workflow）の数（mac の SessionHub.backgroundWork）。
 * 行は session の全行（subagentSnapshot）と写しの多い方で数える（まだ記録していない始まり・終わりの間に、動いている作業を
 * 閉じない）。dynamic workflow は写しだけが知っている。
 */
async function backgroundWork(
  agentId: string,
  sessionId: string,
  session: AgentSession | undefined,
  liveHistory: LiveHistoryIndex,
  terminal: TerminalServices | undefined
): Promise<CardCounts> {
  const snapshot = await sessionSubagentSnapshot(agentId, sessionId, session, liveHistory, terminal);
  const counts: CardCounts = { ...(liveHistory.cards(agentId, sessionId)?.counts ?? { agents: 0, backgroundOnlyAgents: 0, shells: 0, workflows: 0 }) };
  const rows = snapshot !== undefined ? WorkflowCardMirror.rowCounts(snapshot) : undefined;
  if (rows) {
    counts.agents = Math.max(counts.agents, rows.agents);
    counts.shells = Math.max(counts.shells, rows.shells);
  }
  return counts;
}

/**
 * 記録の末尾のターン（最後の done の前。その前の done・ターン終端の error の後から）の、最後の空でない吹き出しの頭
 * （前後の空白を詰めて limit 字まで）。完了の push の本文に使う（前置きの「調べます」ではなく結論。mac の TurnBubbles と
 * 同じ規則）。吹き出しは messageId ごと、最初に出た順。無ければ undefined。
 */
export function lastTurnBubble(list: readonly SessionEvent[], limit = 180): string | undefined {
  let end = list.length;
  if (list[end - 1]?.type === "done") end -= 1;
  let start = 0;
  for (let i = end - 1; i >= 0; i--) {
    if (endsTurn(list[i])) {
      start = i + 1;
      break;
    }
  }
  const texts = new Map<string, string>();
  for (const e of list.slice(start, end)) {
    if (e.type !== "assistant_delta") continue;
    const id = e.messageId ?? "";
    const text = texts.get(id) ?? "";
    // 吹き出し 1 つに覚えるのは 8KB まで（push に使うのは頭だけなので、長い本文を抱え込まない）。
    texts.set(id, Buffer.byteLength(text) < 8 * 1024 ? text + (e.content ?? "") : text);
  }
  for (const text of [...texts.values()].reverse()) {
    const t = text.trim();
    if (t) return Array.from(t).slice(0, limit).join("");
  }
  return undefined;
}

/** 指定 agent で、ターンの後もサブエージェントか終わっていない dynamic workflow が動いている開いている session（写しで数える）。
 *  list_sessions に background の印を付け、開いていないチャットでもサイドバーで稼働中に見せるために使う。
 *  バックグラウンドのコマンドだけでは数えない（dev サーバーは終わらないので、ずっと稼働中に見えてしまう）。 */
function backgroundSessionIds(agentId: string, liveSessions: Map<string, AgentSession>, liveHistory: LiveHistoryIndex): Set<string> {
  const ids = new Set<string>();
  for (const [key, session] of liveSessions) {
    if (!key.startsWith(`${agentId}:`)) continue;
    const counts = liveHistory.cards(agentId, session.sessionId)?.counts;
    if (counts && agentsOrWorkflows(counts)) ids.add(session.sessionId);
  }
  return ids;
}

export class LiveHistoryIndex {
  private entries = new Map<string, SessionEvent[]>();
  private maxEntries = 1500;
  /// key ごとの workflow_progress のカードの写し（mac の SessionHub の cards）。記録した payload を重ね、新しいターン
  /// （生成中でないときの発話）で終わった行を、ターンの終わり（done・ターン終端の error）で終わった dynamic workflow を捨てる。
  private cardMirrors = new Map<string, WorkflowCardMirror>();
  /// key ごとの、記録した subagents の payload の数（session の全行を聞いている間に届いた行があれば聞き直す）。
  private subagentsSeen = new Map<string, number>();
  /// カードの写しが変わった（スリープ抑止を見直す）。
  onCardsChanged?: () => void;
  /// 終わった数（Live Activity の「終わった数」。生成中なら background の分だけ、生成中でなければ全部。docs/BACKGROUND_CONTROL_2026-10-21.md §8.2）。
  onFinished?: (finished: { done: number; failed: number; stopped: number }) => void;
  /// その key の行を Live Activity が数えているか（未設定なら全部数える）。数えていない key の終わりは onFinished へ渡さない。
  isCounted?: (key: string) => boolean;
  /// ターンが進行中の key（currentTurn と同じ区切り。始まりは発話・本文・activity・tool_start、終わりは留め置いていない done と
  /// ターン終端の error）。記録のたびに全部を数え直さないよう、出来事ごとに足し引きする。
  private turnKeys = new Set<string>();
  /// 進行中のターンの有無が変わった（スリープ抑止を見直す）。
  onTurnsChanged?: () => void;

  /// どこかの session でターンが進行中か。
  get anyTurnInProgress(): boolean {
    return this.turnKeys.size > 0;
  }

  /// その session でターンが進行中か（noteTurn が進める印。currentTurn と同じ区切り）。
  inTurn(agentId: string, sessionId: string): boolean {
    return this.turnKeys.has(this.key(agentId, sessionId));
  }

  /// 写しが数える終わった数を onFinished へ渡す。生成中は background の分だけ。
  private noteFinished(key: string, items: ReadonlyArray<{ state: "done" | "failed" | "stopped"; background: boolean }>): void {
    if (this.isCounted && !this.isCounted(key)) return;
    const inTurn = this.turnKeys.has(key);
    const out = { done: 0, failed: 0, stopped: 0 };
    for (const item of items) if (!inTurn || item.background) out[item.state] += 1;
    if (out.done + out.failed + out.stopped > 0) this.onFinished?.(out);
  }
  /// seq の起点。Bridge を再起動しても seq が後戻りしないよう、プロセス起動時刻（ms）から振る（mac の
  /// SessionHub.seqBase と同じ）。1 から振り直すと、端末に残った前世代の sinceSeq に新世代の seq が追いついた
  /// 時点で、replayableDelta が新世代の前半（別の端末が流した発話・応答の冒頭）を欠いた差分を続きとして返す。
  private static readonly seqBase = Date.now();
  /// release した key の最終 seq（墓標）。同じ key に記録し直すときも続きから振り、seq を逆行させない。
  private releasedSeq = new Map<string, number>();
  /// release した記録にあった user_message の `${key}\n${clientMessageId}` → seq（古いものから捨てる）。
  /// 解放後に届いた outbox 再送も findMessageSeq で input_ack に止める（二重実行の防止）。
  private releasedMessageSeqs = new Map<string, number>();
  private static readonly MAX_RELEASED_MESSAGES = 2000;

  /// key ごとの最後に記録した時刻（ミリ秒。/device/sessions/summary の updatedAtMs）。
  private lastAt = new Map<string, number>();

  lastActivity(agentId: string, sessionId: string): number | undefined {
    return this.lastAt.get(this.key(agentId, sessionId));
  }

  /// holdTurn: 送った発話の待ち行列が残っている間の知らせのターンの done。記録するが、ターンの終わりにしない。
  record(evt: SessionEvent, holdTurn = false): SessionEvent {
    if (!evt.sessionId || !evt.agentId) return evt;
    if (!this.shouldRecord(evt)) return evt;
    const key = this.key(evt.agentId, evt.sessionId);
    // 新しいターン（生成中でないときの発話。自分の送信・予約の実行・ほかの画面からの発話）は、記録する前の状態で見分ける。
    // 生成中の差し込みは今のターンに合流するので、終わった行を捨てない。
    const newTurn = evt.type === "user_message" && this.cardMirrors.has(key) && this.currentTurn(evt.agentId, evt.sessionId) === null;
    this.lastAt.delete(key);
    this.lastAt.set(key, Date.now());
    if (this.lastAt.size > 5000) {
      const oldest = this.lastAt.keys().next().value;
      if (oldest !== undefined) this.lastAt.delete(oldest);
    }
    const list = this.entries.get(key) ?? [];
    const seq = list.at(-1)?.seq ?? this.releasedSeq.get(key) ?? LiveHistoryIndex.seqBase;
    const withSeq: SessionEvent = { ...evt, seq: evt.seq ?? seq + 1 };
    list.push(withSeq);
    if (list.length > this.maxEntries) list.splice(0, list.length - this.maxEntries);
    this.entries.set(key, list);
    if (holdTurn && evt.type === "done") heldDones.add(withSeq);
    else this.applyCards(key, withSeq, newTurn);
    this.noteTurn(key, withSeq);
    return withSeq;
  }

  /// 記録した出来事で、key のターンの進行の有無を進める（留め置いた done はターンを終えない）。
  private noteTurn(key: string, evt: SessionEvent): void {
    let changed = false;
    if (endsTurn(evt)) changed = this.turnKeys.delete(key);
    else if (["user_message", "assistant_delta", "activity", "tool_start"].includes(evt.type) && !this.turnKeys.has(key)) {
      this.turnKeys.add(key);
      changed = true;
    }
    if (changed) this.onTurnsChanged?.();
  }

  /// カードの写しを記録したイベントで進める。新しいターンでは終わった行と終わった workflow を、ターンの終わりでは終わった
  /// workflow だけを捨てる（サブエージェントのカードと終わっていない workflow はターンより長く動くので残す）。
  /// アイドル中に届いた workflow_progress も写しに重ねるだけ（currentTurn は workflow_progress を生成中に数えない）。
  private applyCards(key: string, evt: SessionEvent, newTurn: boolean): void {
    let mirror = this.cardMirrors.get(key);
    let changed = false;
    if (newTurn && mirror) {
      mirror.pruneFinished();
      changed = true;
    }
    if (evt.type === "workflow_progress") {
      if (!mirror) {
        mirror = new WorkflowCardMirror();
        this.cardMirrors.set(key, mirror);
        if (this.cardMirrors.size > 2000) {
          const oldest = this.cardMirrors.keys().next().value;
          if (oldest !== undefined && oldest !== key) this.cardMirrors.delete(oldest);
        }
      }
      if (mirror.apply(evt.content) === WorkflowCardMirror.subagentsTaskId) this.subagentsSeen.set(key, (this.subagentsSeen.get(key) ?? 0) + 1);
      this.noteFinished(key, mirror.lastFinished);
      changed = true;
    } else if (mirror && (evt.type === "done" || isTurnFailure(evt))) {
      mirror.dropFinishedWorkflows();
      changed = true;
    }
    if (changed) this.onCardsChanged?.();
  }

  /// key のカードの写し（workflow_progress を一度も記録していなければ undefined）。
  cards(agentId: string, sessionId: string): WorkflowCardMirror | undefined {
    return this.cardMirrors.get(this.key(agentId, sessionId));
  }

  /// key で記録した subagents の payload の数。
  subagentsDelivered(agentId: string, sessionId: string): number {
    return this.subagentsSeen.get(this.key(agentId, sessionId)) ?? 0;
  }

  /// session の全行（subagentSnapshot）を写しに入れる。写しに subagents のカードが無い・世代が違う（作り直した session・
  /// ターミナルのトラッカー）ときだけ。同じ世代なら、記録した payload で写しは追いついている。
  adoptSubagents(agentId: string, sessionId: string, snapshot: string): void {
    const rows = WorkflowCardMirror.rowCounts(snapshot);
    if (!rows) return;
    const key = this.key(agentId, sessionId);
    const mirror = this.cardMirrors.get(key) ?? new WorkflowCardMirror();
    if (mirror.hasSubagents && mirror.subagentsEpoch === rows.epoch) return;
    mirror.apply(snapshot);
    this.cardMirrors.set(key, mirror);
    this.noteFinished(key, mirror.lastFinished);
    this.onCardsChanged?.();
  }

  /// dynamic workflow のカードの全行（workflow_snapshot）を届いた順に。unfinishedOnly なら終わっていないものだけ。
  workflowCards(agentId: string, sessionId: string, unfinishedOnly: boolean): string[] {
    return this.cards(agentId, sessionId)?.workflowSnapshots(unfinishedOnly) ?? [];
  }

  /// 終わったターン（最後に記録した done の前のターン）の最後の空でない吹き出しの頭。完了の push の本文。
  lastBubble(agentId: string, sessionId: string, limit = 180): string | undefined {
    return lastTurnBubble(this.entries.get(this.key(agentId, sessionId)) ?? [], limit);
  }

  /// session の live 記録を捨てる（dispose した・id の確定で誰も参照しなくなった key）。最後の seq は
  /// 墓標として、user_message の clientMessageId → seq は再送検出用に残す。以後の差分同期は全履歴に落ちる。
  /// カードの写しも捨てる（閉じる前に session が実行中の行を stopped で閉じる payload を流している）。
  release(agentId: string, sessionId: string): void {
    const key = this.key(agentId, sessionId);
    this.subagentsSeen.delete(key);
    // 写しを消す前に、数えていた分（workflow + 生成中なら background の agent、でなければ agent 全部）を stopped にする。
    const counts = this.cardMirrors.get(key)?.counts;
    if (counts) {
      const n = counts.workflows + (this.turnKeys.has(key) ? counts.backgroundOnlyAgents : counts.agents);
      if (n > 0 && (!this.isCounted || this.isCounted(key))) this.onFinished?.({ done: 0, failed: 0, stopped: n });
    }
    if (this.cardMirrors.delete(key)) this.onCardsChanged?.();
    if (this.turnKeys.delete(key)) this.onTurnsChanged?.();
    const list = this.entries.get(key);
    if (!list) return;
    const lastSeq = list.at(-1)?.seq;
    if (lastSeq !== undefined) this.releasedSeq.set(key, lastSeq);
    for (const entry of list) {
      if (entry.type !== "user_message" || !entry.messageId || entry.seq === undefined) continue;
      this.releasedMessageSeqs.set(`${key}\n${entry.messageId}`, entry.seq);
      if (this.releasedMessageSeqs.size > LiveHistoryIndex.MAX_RELEASED_MESSAGES) {
        const oldest = this.releasedMessageSeqs.keys().next().value;
        if (oldest !== undefined) this.releasedMessageSeqs.delete(oldest);
      }
    }
    this.entries.delete(key);
  }

  delta(agentId: string, sessionId: string, sinceSeq: number): SessionEvent[] {
    return (this.entries.get(this.key(agentId, sessionId)) ?? []).filter((entry) => (entry.seq ?? 0) > sinceSeq);
  }

  /// load_history の差分 replay 用（mac SessionHub.liveDelta と同じ判定）。sinceSeq の続きを
  /// 途切れなく返せるときだけ差分（新着なしなら空配列）を返し、返せないときは undefined。
  /// - 先頭が sinceSeq+1 より新しい: maxEntries の上限で溢れた / Bridge 再起動前の sinceSeq（新世代は
  ///   起動時刻から採番するので、前世代の seq は新世代の先頭より小さい）
  /// - sinceSeq が最新採番より大きい / 記録なし: 採番が食い違う・release で記録を捨てた
  replayableDelta(agentId: string, sessionId: string, sinceSeq: number): SessionEvent[] | undefined {
    const list = this.entries.get(this.key(agentId, sessionId)) ?? [];
    const firstSeq = list[0]?.seq;
    const lastSeq = list.at(-1)?.seq ?? 0;
    if (firstSeq === undefined || sinceSeq > lastSeq || firstSeq > sinceSeq + 1) return undefined;
    // workflow_progress は再送しない（写しの更新だけに使う。接続時の epoch 付き snapshot の後に前の世代の payload が届くと、
    // アプリが今の行を捨てて古い行を出す。カードは sendCards が全行を送る。mac の SessionHub も記録しない）。
    return list.filter((entry) => (entry.seq ?? 0) > sinceSeq && entry.type !== "workflow_progress");
  }

  latestSeq(agentId: string, sessionId: string): number {
    return this.entries.get(this.key(agentId, sessionId))?.at(-1)?.seq ?? 0;
  }

  findMessageSeq(agentId: string, sessionId: string, messageId: string): number | undefined {
    const key = this.key(agentId, sessionId);
    return this.entries
      .get(key)
      ?.find((entry) => entry.messageId === messageId)?.seq ?? this.releasedMessageSeqs.get(`${key}\n${messageId}`);
  }

  hasUserInputAfter(agentId: string, sessionId: string, seq: number): boolean {
    return this.delta(agentId, sessionId, seq).some((entry) => entry.type === "user_message");
  }

  /// 進行中ターンのスナップショット（再接続 turn_resume 用）を index の末尾から導出する。
  /// 最後の done（またはターン終端の error = done を伴わない失敗）以降を 1 ターンとみなし、
  /// phase / 進行中 bubble / 実行中 tool を割り出す。
  currentTurn(
    agentId: string,
    sessionId: string
  ): { phase: "thinking" | "streaming"; messageId?: string; textSoFar: string; toolUseId?: string; toolName?: string; toolKind?: string } | null {
    const list = this.entries.get(this.key(agentId, sessionId)) ?? [];
    let start = 0;
    for (let i = list.length - 1; i >= 0; i--) {
      // handleMessage の汎用 catch（action_response 等の失敗）の error は印が無いので終端にしない。
      if (endsTurn(list[i])) { start = i + 1; break; }
    }
    const turn = list.slice(start);
    if (!turn.some((e) => ["user_message", "assistant_delta", "activity", "tool_start"].includes(e.type))) {
      return null; // ターン進行中ではない
    }
    // 実行中の tool（tool_start のうち対応する tool_end が無いもの）
    let activeTool: SessionEvent | undefined;
    for (let i = turn.length - 1; i >= 0; i--) {
      if (turn[i].type === "tool_start") {
        const tid = turn[i].toolUseId;
        const ended = turn.some((e) => e.type === "tool_end" && e.toolUseId === tid);
        if (!ended) { activeTool = turn[i]; break; }
      }
    }
    if (activeTool) {
      return {
        phase: "thinking",
        textSoFar: "",
        toolUseId: activeTool.toolUseId,
        toolName: activeTool.toolName,
        toolKind: activeTool.metadata?.kind
      };
    }
    // 現 bubble（最後の assistant_turn_end 以降）の delta
    // 留め置いた done（pending）も吹き出しの区切り。アプリはそこで確定済みの吹き出しを streaming に戻さない。
    let lastTurnEnd = -1;
    for (let i = turn.length - 1; i >= 0; i--) {
      if (turn[i].type === "assistant_turn_end" || (turn[i].type === "done" && heldDones.has(turn[i]))) { lastTurnEnd = i; break; }
    }
    const tail = turn.slice(lastTurnEnd + 1);
    const deltas = tail.filter((e) => e.type === "assistant_delta");
    if (deltas.length > 0) {
      const mid = deltas[deltas.length - 1].messageId;
      const text = deltas.filter((d) => d.messageId === mid).map((d) => d.content ?? "").join("");
      return { phase: "streaming", messageId: mid, textSoFar: text };
    }
    return { phase: "thinking", textSoFar: "" };
  }

  /// 承認や質問への回答を待っているか（list_sessions の awaiting 用）。最後の action_request の後に、その解決・
  /// ユーザーの発話・エージェントの続き（別の端末やターミナルで答えた）・ターンの失敗が無ければ待っている。
  /// done では外さない（ターンを終えてから文章での回答を待つエージェントがある）。
  awaitingAnswer(agentId: string, sessionId: string): boolean {
    const list = this.entries.get(this.key(agentId, sessionId)) ?? [];
    const resolved = new Set<string>();
    for (let i = list.length - 1; i >= 0; i--) {
      const e = list[i];
      if (e.type === "action_resolved") resolved.add(e.messageId ?? "");
      else if (e.type === "action_request" && !resolved.has(e.messageId ?? "")) return true;
      else if (["user_message", "assistant_delta", "tool_start"].includes(e.type) || isTurnFailure(e)) return false;
    }
    return false;
  }

  /// 直近に完了したターンの messageId（無ければ最後の assistant_delta の id、それも無ければ空）。
  /// 生成中固着プローブで idle と判定した時、done 再送に添える id として使う。
  lastDoneMessageId(agentId: string, sessionId: string): string {
    const list = this.entries.get(this.key(agentId, sessionId)) ?? [];
    for (let i = list.length - 1; i >= 0; i--) {
      if (list[i].type === "done" && list[i].messageId) return list[i].messageId!;
    }
    for (let i = list.length - 1; i >= 0; i--) {
      if (list[i].type === "assistant_delta" && list[i].messageId) return list[i].messageId!;
    }
    return "";
  }

  private shouldRecord(evt: SessionEvent): boolean {
    return [
      "session_started",
      "user_message",
      "assistant_delta",
      "activity",
      "tool_start",
      "tool_end",
      "assistant_turn_end",
      "done",
      "error",
      "action_request",
      "action_resolved",
      "plan_update",
      "workflow_progress"
    ].includes(evt.type);
  }

  private key(agentId: string, sessionId: string): string {
    return `${agentId}:${sessionId}`;
  }
}

// 初回履歴ロードで送る最新メッセージ件数の上限。長い会話でも末尾のこの件数だけ取得すれば足りる。
const DEFAULT_HISTORY_LIMIT = 100;

// 切断後この猶予の間に再接続が無ければ session を dispose する。一時的な
// ネットワーク断・画面遷移での即時切断/再接続を吸収する長さにする。
const SESSION_DISPOSE_GRACE_MS = 45_000;

// バックグラウンドの作業（サブエージェント・シェル・dynamic workflow）が残っている session を、購読者がいないまま
// イベントの無い状態で残しておく上限（mac の SessionHub.backgroundIdleTimeout と同じ 6 時間）。
const BACKGROUND_IDLE_TIMEOUT_MS = 6 * 60 * 60_000;

// バックグラウンドの行が全部終わってから、知らせのターンの done を待つ猶予（mac の cron の backgroundSettleGrace と同じ 120 秒）。
const PUSH_SETTLE_GRACE_MS = 120_000;
const PUSH_SETTLE_POLL_MS = 5_000;

/** 預かっている完了の push の世代（key ごと）。新しい done・購読者・次のターンで世代が替わると、預かりは捨てる。 */
const deferredPushes = new Map<
  string,
  { generation: number; isRunning: () => Promise<boolean>; isStale: () => boolean; fire: () => Promise<unknown> }
>();
let deferredPushSeq = 0;

export function cancelDeferredPush(key: string): void {
  deferredPushes.delete(key);
}

/**
 * 預かっている完了の push を、バックグラウンドの作業がもう無ければ猶予を待たずに今出す。
 * 本文の無い知らせのターン（silent の done）が来たとき用で、その後に良い本文は来ない。預かりが無い・作業が残っている・
 * 利用者が戻っている（isStale）ときは何もしない（isStale は預かりを捨てる）。
 */
export async function fireDeferredPushIfSettled(key: string): Promise<void> {
  const entry = deferredPushes.get(key);
  if (!entry) return;
  try {
    if (entry.isStale()) {
      deferredPushes.delete(key);
      return;
    }
    if (await entry.isRunning()) return;
    if (deferredPushes.get(key)?.generation !== entry.generation) return; // 待つ間に取り下げ・預け直しがあった
    deferredPushes.delete(key);
    await entry.fire();
  } catch {
    deferredPushes.delete(key);
  }
}

/**
 * done の時点でバックグラウンドの作業が動いていて push を見送ったとき、その push を預かる。作業の行（agents + workflows）が
 * 0 になってから grace の間に何も起きなければ fire する。その間に done が来た（cancelDeferredPush）・利用者が戻った
 * （isStale）なら捨てる。ターンが動いている間（isBusy）は猶予を数えない。知らせのターンが来る CLI ではその done が push するので二重にならない。
 */
export function deferPushUntilSettled(opts: {
  key: string;
  isRunning: () => Promise<boolean>;
  isStale: () => boolean;
  isBusy?: () => boolean;
  fire: () => Promise<unknown>;
  pollMs?: number;
  graceMs?: number;
  maxMs?: number;
}): void {
  const generation = ++deferredPushSeq;
  deferredPushes.set(opts.key, { generation, isRunning: opts.isRunning, isStale: opts.isStale, fire: opts.fire });
  const poll = opts.pollMs ?? PUSH_SETTLE_POLL_MS;
  const grace = opts.graceMs ?? PUSH_SETTLE_GRACE_MS;
  const deadline = Date.now() + (opts.maxMs ?? BACKGROUND_IDLE_TIMEOUT_MS);
  let settledAt: number | undefined;
  const tick = (): void => {
    const timer = setTimeout(() => {
      void (async () => {
        if (deferredPushes.get(opts.key)?.generation !== generation) return; // 取り下げ・預け直し
        if (opts.isStale() || Date.now() > deadline) {
          deferredPushes.delete(opts.key);
          return;
        }
        if (opts.isBusy?.() || (await opts.isRunning())) settledAt = undefined;
        else settledAt ??= Date.now();
        if (deferredPushes.get(opts.key)?.generation !== generation) return;
        if (settledAt !== undefined && Date.now() - settledAt >= grace) {
          deferredPushes.delete(opts.key);
          await opts.fire();
          return;
        }
        tick();
      })().catch(() => deferredPushes.delete(opts.key));
    }, poll);
    timer.unref();
  };
  tick();
}

// Bridge 全体の実行中 send() 数。1 つでもあればスリープを止める（mac の SessionHub と SleepGuard）。
let activeSends = 0;
function trackSend(services: BridgeServices, delta: number): void {
  activeSends = Math.max(0, activeSends + delta);
  services.sleep.setActive(activeSends > 0, "sessions");
}

// session ごとの実行中 send() 数（全接続で共有）。dispose 判定で「生成中」とみなすのに使う。
const sendsInFlight = new WeakMap<AgentSession, number>();
/** session ごとの「預かった予約を 1 件送る」。fanout がターンの終端 done で呼ぶ（handleMessage が登録する）。 */
const queueDispatchers = new WeakMap<AgentSession, () => void>();

// session を開いたときの作業フォルダ（mainagent の list_sessions 用）。
const sessionCwds = new WeakMap<AgentSession, string>();

/// 送信予約（mac の SessionHub の messageQueue）。生成中に届いた queue_user_message を預かり、
/// ターンが終わったら 1 件ずつ送る。session オブジェクトに紐付けるので、id が pending-xxx → 実 id に
/// 変わっても付け替え不要。メモリだけに持つ（Bridge を再起動すると消え、iOS は自前の予約に戻る）。
interface QueuedMessage {
  clientMessageId: string;
  content: string;
  /** 送るときに session.send() へ渡す元のイベント（スキル・添付の metadata を含む）。 */
  inbound: SessionEvent;
}
const sendQueues = new WeakMap<AgentSession, QueuedMessage[]>();

function queueItems(session: AgentSession): Array<{ clientMessageId: string; content: string }> {
  return (sendQueues.get(session) ?? []).map((m) => ({ clientMessageId: m.clientMessageId, content: m.content }));
}

// ターン終端の error（セッションの失敗で done が出ない）に付ける印。
const TURN_FAILED_KEY = "turnFailed";

function markTurnFailed(outbound: SessionEvent): SessionEvent {
  return { ...outbound, metadata: { ...outbound.metadata, [TURN_FAILED_KEY]: "true" } };
}

function isTurnFailure(evt: SessionEvent): boolean {
  return evt.type === "error" && evt.metadata?.[TURN_FAILED_KEY] === "true";
}

/**
 * 送った発話が CLI の待ち行列に残っている間に届いた、知らせのターン（metadata.origin = task-notification）の done。
 * 記録も配信もするが、その発話のターンの終わりとしては数えない（mac の SessionHub と同じ）。
 */
const heldDones = new WeakSet<SessionEvent>();

/** 記録の中のターンの終わり（done・ターン終端の error）か。留め置いた知らせのターンの done は数えない。 */
const endsTurn = (e: SessionEvent): boolean => (e.type === "done" && !heldDones.has(e)) || isTurnFailure(e);

/**
 * セッションに渡す本文。音声会話モードの指定を自分で読めないセッションには、応え方の指示と
 * 遮られた注記を本文末尾の `<voice-context>` で渡す（履歴では load_history_request が剥がす）。
 */
/**
 * 送信の metadata にチャット単位の上書き（chatOverrides=1）があれば、その session に渡す。
 * agentId があれば orchestrator にもモードを知らせる（mainagent のチャットなら、ここで選んだモードが子の上限になる。
 * ほかのチャットでは、mainagent が送る前に相手のモードを確かめるのに使う）。
 */
export function applyChatOverrides(session: AgentSession, metadata: Record<string, string> | undefined, agentId?: string): void {
  const overrides = parseChatOverrides(metadata);
  if (!overrides) return;
  session.applyOverrides?.(overrides);
  if (agentId) orchestrator.noteChatMode(agentId, session.sessionId, overrides.mode);
}

export function voiceText(session: Pick<AgentSession, "handlesVoice">, text: string, inbound: SessionEvent | undefined): string {
  if (session.handlesVoice) return text;
  return withVoiceContext(text, voiceTurnFrom(inbound), true);
}

/// 送信の直前の準備。チャット単位の設定（chatOverrides）を session に渡し、送られた画像を AttachmentStore に保管する
/// （履歴には目印しか残らないので、履歴を開いたときに実画像へ戻すため。mac の WebSocketServer と同じ）。
function prepareSend(session: AgentSession, inbound: SessionEvent, agentId?: string): void {
  applyChatOverrides(session, inbound.metadata, agentId);
  for (const image of imageAttachments(inbound)) putImage(image);
}

/// metadata から添付の本体（attachment_<i>_b64）だけを除いたコピー。kind/name/mime/件数・
/// clientMessageId 等は残す（live buffer への記録用。元の metadata は書き換えない）。
function withoutAttachmentData(metadata: Record<string, string> | undefined): Record<string, string> | undefined {
  if (!metadata) return metadata;
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(metadata)) {
    if (!/^attachment_\d+_b64$/.test(k)) out[k] = v;
  }
  return out;
}

/// turn_resume に本文置換時点の seq を添える。iOS は load_history の差分 replay で再送される
/// 置換済み区間の delta（seq <= snapshotSeq）を本文に足さない（二重表示の防止）。
function withSnapshotSeq(resume: SessionEvent, snapshotSeq: number): SessionEvent {
  return { ...resume, metadata: { ...resume.metadata, snapshotSeq: String(snapshotSeq) } };
}

function parseOptionalPositiveInt(value: string | undefined): number | undefined {
  if (value === undefined || value.trim() === "") return undefined;
  const parsed = Number.parseInt(value, 10);
  return Number.isInteger(parsed) && parsed >= 0 ? parsed : undefined;
}

/** stop_task_request の全体の上限（CLI ごとの待ち時間はその内側）。 */
const STOP_TASK_TIMEOUT_MS = 15_000;

function withStopTimeout(work: Promise<StopTaskOutcome>): Promise<StopTaskOutcome> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<StopTaskOutcome>((resolve) => {
    timer = setTimeout(() => resolve({ kind: "timeout" }), STOP_TASK_TIMEOUT_MS);
  });
  return Promise.race([work, timeout]).finally(() => clearTimeout(timer));
}

/** 行の無い subagents のカードの全行（workflow_snapshot。epoch は毎回新しい）。 */
function emptySubagentsSnapshot(): string {
  return JSON.stringify({
    subtype: "workflow_snapshot",
    taskId: "subagents",
    kind: "subagents",
    workflowName: "サブエージェント",
    status: "completed",
    epoch: crypto.randomUUID().toLowerCase(),
    agents: []
  });
}

/** turn_status_request の応答。stop_task_request の not_running / stale でも同じものを送る。 */
async function replyTurnStatus(
  adapter: AgentAdapter,
  sessionId: string,
  state: ConnectionState,
  liveSessions: Map<string, AgentSession>,
  liveHistory: LiveHistoryIndex,
  emit: Emit,
  sendRaw: Emit,
  services: BridgeServices
): Promise<void> {
  // mainagent のチャットなら、任せた子のカードも送り直す（ターンが終わっていても。mac の emitSnapshotIfActive と同じ）。
  const card = services.mainagentCards?.get(`${adapter.id}:${sessionId}`);
  if (card) sendRaw(event.workflowProgress(adapter.id, sessionId, card));
  // サブエージェントのカードは、ターンの状態に関係なく全行で渡す（行はターンを越えて動く。行が無くても epoch 付き）。
  // done より先に送る（done の時点でバックグラウンドの作業が動いていると分かるように）。
  const live = liveSessions.get(`${adapter.id}:${sessionId}`) ?? (state.session?.sessionId === sessionId ? state.session : undefined);
  const subagents = await subagentsCard(adapter.id, sessionId, live, liveHistory, services.terminal);
  if (subagents) sendRaw(event.workflowProgress(adapter.id, sessionId, subagents));
  // session が無く写しも無いときは、空の全行を新しい epoch で送る（アプリが持っている古い running の行を落とさせる。mac の MS-9 と同じ）。
  else if (!live) sendRaw(event.workflowProgress(adapter.id, sessionId, emptySubagentsSnapshot()));
  const t = liveHistory.currentTurn(adapter.id, sessionId);
  if (t) {
    emit(withSnapshotSeq(
      event.turnResume(adapter.id, sessionId, t.phase, t.messageId, t.textSoFar, t.toolUseId, t.toolName, t.toolKind),
      liveHistory.latestSeq(adapter.id, sessionId)
    ));
    // 進行中の dynamic workflow のツリー（再接続でも「動いてる」を認知できる）。
    for (const wf of liveHistory.workflowCards(adapter.id, sessionId, false)) sendRaw(event.workflowProgress(adapter.id, sessionId, wf));
  } else {
    // 終わっていない dynamic workflow（ターンが終わった後もバックグラウンドで続く）。
    for (const wf of liveHistory.workflowCards(adapter.id, sessionId, true)) sendRaw(event.workflowProgress(adapter.id, sessionId, wf));
    emit(event.done(adapter.id, sessionId, liveHistory.lastDoneMessageId(adapter.id, sessionId)));
  }
}

/**
 * ターミナルで開かれている Claude Code の会話なら、その窓口（ClaudeTerminalSession）を返す（無ければ作って載せる）。
 * Bridge が起こした同じ会話が動いていれば、そちらは handOver に任せて undefined。
 */
function terminalSessionFor(
  adapterId: string,
  sessionId: string,
  liveSessions: Map<string, AgentSession>,
  terminal?: TerminalServices
): ClaudeTerminalSession | undefined {
  if (!terminal || adapterId !== "claude" || !terminal.registry.isLive(sessionId)) return undefined;
  const key = `claude:${sessionId}`;
  const existing = liveSessions.get(key);
  if (existing instanceof ClaudeTerminalSession) return existing;
  if (existing) return undefined;
  const session = new ClaudeTerminalSession(sessionId, terminal.registry, terminal.inbox);
  liveSessions.set(key, session);
  return session;
}

/**
 * bg のジョブの会話の振り分け（BACKGROUND_CONTROL §7.8）。ワーカーが生きていれば worker、ほかのプロセスが同じ sessionId を
 * 握っていれば elsewhere。どちらでもない・bg のジョブでなければ undefined（今までどおり -p --resume）。
 */
function backgroundSessionFor(
  adapter: ClaudeCodeAdapter,
  jobs: ClaudeBackgroundJobs,
  publish: (evt: SessionEvent) => void,
  sessionId: string
): ClaudeBackgroundSession | undefined {
  const entry = jobs.entryFor(sessionId);
  if (!entry) return undefined;
  if (entry.row.live) return new ClaudeBackgroundSession(sessionId, { mode: "worker", host: jobs, publish, history: adapter });
  const holder = findHolder(jobs.homeDir, sessionId, () => void jobs.refresh());
  if (holder) return new ClaudeBackgroundSession(sessionId, { mode: "elsewhere", host: jobs, publish, history: adapter, holder });
  return undefined;
}

async function acquireSession(
  adapter: AgentAdapter,
  liveSessions: Map<string, AgentSession>,
  state: ConnectionState,
  sessionId: string | undefined,
  cwd: string | undefined,
  defaultCwd: string,
  terminal?: TerminalServices,
  /** まだ開いていないセッションを開くときの指定（定期チェックの無人・印）。 */
  options?: SessionOptions,
  /** claude --bg のジョブ（あれば、bg のジョブの会話を worker / elsewhere に振り分ける。BACKGROUND_CONTROL §7.8）。 */
  bgJobs?: ClaudeBackgroundJobs,
  publishClaude?: (evt: SessionEvent) => void
): Promise<AgentSession> {
  const key = `${adapter.id}:${sessionId ?? "new"}`;
  // ターミナルで開かれている Claude Code の会話は、iPhone から送ってもターミナルへ届ける（同じ会話を
  // 2 つのプロセスで動かすと静かに二股になる）。ターミナルが閉じたら、以後は Bridge が起こし直す。
  if (terminal && adapter.id === "claude" && sessionId) {
    const existing = liveSessions.get(key);
    if (terminal.registry.isLive(sessionId)) {
      if (existing instanceof ClaudeTerminalSession) return existing;
      const session = new ClaudeTerminalSession(sessionId, terminal.registry, terminal.inbox);
      liveSessions.set(key, session);
      return session;
    }
    if (existing instanceof ClaudeTerminalSession) liveSessions.delete(key);
  }
  if (!sessionId && state.session) return state.session;
  // 使えなくなった session（bg のワーカーが消えた・起こしたプロセスがワーカーに取られた）は閉じて取り直す。
  const reused = sessionId ? liveSessions.get(key) : undefined;
  if (sessionId && reused?.isStillUsable && !reused.isStillUsable()) {
    liveSessions.delete(key);
    void Promise.resolve(reused.close()).catch(() => {});
  }
  if (sessionId && liveSessions.has(key)) return liveSessions.get(key)!;
  if (bgJobs && publishClaude && sessionId && adapter.id === "claude" && adapter instanceof ClaudeCodeAdapter) {
    // Bridge を起動した直後は最初の一覧がまだ無い。生きたワーカーを -p で開かないよう、読み終わるまで待つ（最大 5 秒）。
    await bgJobs.ready().catch(() => {});
    if (liveSessions.has(key)) return liveSessions.get(key)!;
    const bg = backgroundSessionFor(adapter, bgJobs, publishClaude, sessionId);
    if (bg) {
      liveSessions.set(key, bg);
      return bg;
    }
  }
  // cwd 未指定なら defaultCwd で開く。ただし Claude 系の resume は transcript に記録された cwd で
  // --resume させる（cwd 不一致だと解決できない）。transcript が見つからない（WSL 側の ~/.claude にある等）
  // ときはホームではなく defaultCwd に戻す（既定 cwd で作ったセッションを従来どおり resume できるように）。
  const resumesAtRecordedCwd = sessionId !== undefined && adapter instanceof ClaudeCodeAdapter;
  const session = await adapter.openSession(sessionId, cwd ?? (resumesAtRecordedCwd ? resolveClaudeSessionCwd(undefined, sessionId, defaultCwd) : defaultCwd), options);
  // 開いたときの作業フォルダ（mainagent の list_sessions に出す。resume で cwd が渡らなかったものは持たない。mac と同じ）。
  if (cwd) sessionCwds.set(session, cwd);
  // openSession の await 中に別接続が同 id を開いていたら、こちらは捨てて既存を使う。
  // （捨てる側を close しないと ACP 系の子プロセスが orphan になる）。
  if (sessionId) {
    const existing = liveSessions.get(key);
    if (existing) {
      void Promise.resolve(session.close()).catch(() => {});
      return existing;
    }
  }
  liveSessions.set(`${adapter.id}:${session.sessionId}`, session);
  return session;
}


/** 作業フォルダの比較（Windows の大文字小文字・区切り・末尾の区切りを揃える）。 */
function sameCwd(a: string, b: string): boolean {
  const norm = (p: string): string => p.replace(/[\\/]+$/, "").replace(/\\/g, "/").toLowerCase();
  return norm(a) === norm(b);
}

function parseJsonArray(raw?: string): string[] {
  if (!raw) return [];
  try {
    const v = JSON.parse(raw);
    return Array.isArray(v) ? v.map(String) : [];
  } catch {
    return [];
  }
}

function parseJsonObject(raw?: string): Record<string, string> {
  if (!raw) return {};
  try {
    const v = JSON.parse(raw);
    if (v && typeof v === "object" && !Array.isArray(v)) {
      const out: Record<string, string> = {};
      for (const [k, val] of Object.entries(v as Record<string, unknown>)) out[k] = String(val);
      return out;
    }
    return {};
  } catch {
    return {};
  }
}

export { agentsOrWorkflows, anyBackground, WorkflowCardMirror, type CardCounts };
