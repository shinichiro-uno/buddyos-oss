#!/usr/bin/env node
// 最初に読み込む: Windows で子プロセスが作業フォルダの cmd.exe / node.exe を掴まないようにする（systemExe.ts）。
import "./runtime/systemExe.js";
// 子プロセスに渡したくない環境変数（ELECTRON_RUN_AS_NODE 等）を、他のモジュールより先に消す。
import "./runtime/processEnv.js";
import type { AddressInfo } from "node:net";
import qrcode from "qrcode-terminal";
import { readAdminKey } from "./auth.js";
import { LISTEN_HOST, loadConfig, resolveConfigDir } from "./config.js";
import { acquireInstanceLock, type InstanceLock, writeRuntimeFiles } from "./instanceLock.js";
import { invitePairUrl } from "./pairingInvites.js";
import { PaseoRelayTunnel } from "./paseoRelay.js";
import { BridgeRegistry, convexSiteSetting } from "./registry.js";
import { createBridgeServer } from "./server.js";
import { describeSettings } from "./settings.js";
import { JsonSessionStore } from "./sessionStore.js";
import { startSystemMonitor } from "./systemMonitor.js";
import { orchestrator, Orchestrator } from "./mainagent/orchestrator.js";
import { isRelayInvocation, runStdioRelay } from "./mainagent/stdioRelay.js";
import { defaultMainAgentRoot, ensureMainAgentWorkspace, setMainAgentConfigDir, setMainAgentRoot } from "./mainagent/workspace.js";

/** e2e-key が読めない（権限・I/O）ときに読み直す間隔。 */
const KEY_RETRY_MS = 30_000;
/** 一度もつながらない端末の行・古い外した印を消す間隔（PROTOCOL-v3 §12）。 */
const PURGE_INTERVAL_MS = 60 * 60 * 1000;

/** 止めるときに片付けるもの（起動の途中で止められても、できたところまで片付ける）。 */
const running: {
  lock?: InstanceLock;
  bridge?: ReturnType<typeof createBridgeServer>;
  relay?: PaseoRelayTunnel;
  registry?: BridgeRegistry;
  stopMonitor?: () => void;
} = {};

async function main(): Promise<void> {
  const dir = resolveConfigDir();
  // 同じ設定の Bridge がもう動いていたら、2 つ目は終わる（デスクトップアプリは終了コード 75 を見て、動いている方へ付く）。
  // 鍵を取ってから設定を読む（v3 への移行・鍵の作り直しを 2 つの Bridge で同時に行わない）。
  const lock = await acquireInstanceLock(dir);
  if (!lock) {
    console.error("[bridge] another BuddyOS bridge is already running; exiting");
    process.exit(75);
  }
  running.lock = lock;
  const config = loadConfig(dir);
  const identity = config.identity;
  // 中継・登録簿・通知などの設定の出どころ（環境変数か既定値か）を 1 行だけ。値は出さない（中継の URL だけ出す）。
  console.log(describeSettings(convexSiteSetting().source));
  const store = new JsonSessionStore(config.configDir);
  // mainagent（窓口のエージェント）の作業フォルダ（Windows は %USERPROFILE%\.buddyos\main）。決まりのファイルを用意し、
  // 初めて作ったときだけ「メイン」をプロジェクト一覧へ足す。頼んだ相手の記録は設定フォルダに置く。
  const mainRoot = defaultMainAgentRoot(config.configDir);
  setMainAgentRoot(mainRoot);
  setMainAgentConfigDir(config.configDir);
  const bridge = createBridgeServer(config, store);
  running.bridge = bridge;
  ensureMainAgentWorkspace(mainRoot, bridge.services.projects);
  orchestrator.enablePersistence(Orchestrator.defaultStoreFile(config.configDir));
  // 設定「ほかのエージェントに頼めるようにする」（%LOCALAPPDATA%\BuddyOS\Bridge\orchestrator-settings.json。無ければ有効）。
  orchestrator.enableSettings(Orchestrator.defaultSettingsFile(config.configDir));

  // 管理鍵（PROTOCOL-v3 Appendix A）: デスクトップアプリが Bridge を起こした直後に stdin へ 1 行だけ書く。TTY・手で起こした・
  // タスク スケジューラなどで来ないときは管理鍵なしで動く（/local/* は 403 admin_unavailable）。環境変数・引数・ファイル・
  // ログには出さない。子プロセスの stdin はどれも "pipe" か "ignore"（Bridge の stdin を引き継がない）。
  let adminReceived = false;
  const adminKey = await readAdminKey(process.stdin, {
    onEnd: () => {
      // デスクトップがいなくなったら「端末を追加」の窓を閉じる（mac の AdminChannel の onEOF と同じ。remote の申し込みは残る）。
      bridge.approvals.closeWindow("closed");
      // 別の PC の中継口はデスクトップのもの。いなくなったら一覧を空にする。
      orchestrator.clearRemotePcs();
      if (adminReceived) console.log("[bridge] the desktop app closed the admin pipe");
    }
  });
  adminReceived = adminKey !== undefined;
  if (adminKey) bridge.admin.set(adminKey);
  else console.log("[bridge] no admin key; device management is available only from the BuddyOS app that starts this bridge");

  await bridge.start();
  const port = (bridge.server.address() as AddressInfo | null)?.port ?? config.port;
  writeRuntimeFiles(config.configDir, port);

  // 端末とは Paseo の中継だけでつながる（mac と同じ）。中継から来た接続は、この PC の中の待ち受けへ流す。
  const relay = new PaseoRelayTunnel({
    relayURL: config.paseoRelayURL,
    identity,
    devices: identity.devices,
    invites: bridge.invites,
    approvals: bridge.approvals,
    peers: bridge.peers,
    bridgeName: bridge.bridgeName,
    onDevicePaired: (_id, display) => console.log(`[bridge] connected a new device: ${display}`)
  });
  running.relay = relay;
  bridge.attachTunnel(relay);
  relay.start(port, LISTEN_HOST);
  // アカウントの登録簿（Convex）へ v3 で自己登録する（registry.ts）。サインイン済みの iPhone・別の PC の
  // 「アカウントの PC」に QR なしで出る。端末トークンができれば push（/v3/push）も使えるようになる。
  const registry = new BridgeRegistry({
    identity,
    relayURL: config.paseoRelayURL,
    machineName: bridge.bridgeName,
    onFirstRegistered: () => {
      void bridge.push.syncTargetsNow();
      // Live Activity の宛先の口が使えるかを確かめる（前の Bridge の宛先も消える）。
      bridge.services.liveActivity.registryReady();
    }
  });
  running.registry = registry;
  bridge.setRegistrationHandler(() => registry.requestSoon());
  registry.start();
  // 作り直し（すべての端末を切断など）の後は、新しい静的鍵と relayId で張り直し（古い relayId の接続は全部切れる）、
  // 登録簿にもすぐ登録し直す（前の値を keyRotation に付ける）。
  identity.onReset(() => {
    relay.start(port, LISTEN_HOST);
    registry.requestSoon();
  });
  // スリープからの復帰・ネットワークの切り替えでは、生存確認を待たずに中継へ張り直し、登録し直す（mac の PowerEventMonitor / NetworkMonitor）。
  running.stopMonitor = startSystemMonitor((reason) => {
    console.log(`[bridge] ${reason} detected; reconnecting relay`);
    relay.start(port, LISTEN_HOST);
    registry.requestSoon();
  });
  // e2e-key が読めないあいだは中継を張らずに待ち、読めたら張って登録する（読めないだけで鍵を作り直さない）。
  if (identity.keyState === "io_error") {
    const timer = setInterval(() => {
      if (identity.keyState === "ok" || identity.retryKey()) {
        clearInterval(timer);
        relay.start(port, LISTEN_HOST);
        registry.requestSoon();
      }
    }, KEY_RETRY_MS);
  }
  identity.devices.purge();
  setInterval(() => identity.devices.purge(), PURGE_INTERVAL_MS).unref();
  // 5 分たった承認待ちを取り下げる（mac の housekeeping と同じ 5 秒ごと。トンネルの側も自分の期限で閉じる）。
  setInterval(() => bridge.approvals.expire(), 5_000).unref();

  console.log("BuddyOS Windows Bridge");
  console.log(`bridgeId: ${config.bridgeId}`);
  console.log(`listen:   ${LISTEN_HOST}:${port}`);
  console.log(`relay:    ${config.paseoRelayURL || "(not configured — set BUDDYOS_PASEO_RELAY_URL)"}`);
  console.log(`config:   ${config.configDir}`);
  console.log("");
  console.log("adapters:");
  for (const [id, adapter] of bridge.adapters) {
    console.log(`  - ${id}: ${adapter.displayName} [${adapter.runtimeLabel}]`);
  }
  console.log("");
  // 対話ターミナルで起動したときだけ、10 分・1 回だけ使える招待の QR を出す（PROTOCOL-v3 §6。ふだんはデスクトップアプリの QR を使う）。
  const bridgePub = identity.bridgePub();
  if (!config.paseoRelayURL) {
    console.log("pair:     unavailable until a relay is configured (BUDDYOS_PASEO_RELAY_URL)");
  } else if (process.stdout.isTTY && bridgePub) {
    const invite = bridge.invites.create();
    const pairUrl = invitePairUrl(invite, {
      bridgeId: config.bridgeId,
      name: bridge.bridgeName(),
      relayURL: config.paseoRelayURL,
      relayId: identity.relayId,
      bridgePub
    });
    console.log("pair:     scan this QR within 10 minutes (it works once)");
    qrcode.generate(pairUrl, { small: true });
  } else {
    console.log("pair:     scan the QR in the BuddyOS desktop app");
  }
}

// ブリッジは長命の常駐プロセス。1 本の浮いた Promise / 子プロセス stdio の EPIPE で
// プロセス全体が落ちると、Task Scheduler/supervisor の再起動まで iOS から使えなくなる。
// 安全網として捕捉してログするだけにし、稼働を継続させる（真の修正は各 I/O の try/catch・
// stdin 'error' ハンドラ側で実施済み）。
process.on("unhandledRejection", (reason) => {
  console.error(`[bridge] unhandledRejection: ${reason instanceof Error ? reason.stack ?? reason.message : String(reason)}`);
});
process.on("uncaughtException", (error) => {
  const code = (error as NodeJS.ErrnoException)?.code;
  const benign = code === "EPIPE" || /EPIPE|ERR_STREAM_DESTROYED|ECONNRESET/.test(error?.message ?? "");
  console.error(`[bridge] uncaughtException${benign ? " (benign)" : ""}: ${error instanceof Error ? error.stack ?? error.message : String(error)}`);
});

const SHUTDOWN_GRACE_MS = 2500;
let shuttingDown = false;

/**
 * 止める合図を受けたら、エージェントの子プロセス・スリープ止め・中継を畳んでから通常の終了にする
 * （終了時に bridge.port / bridge.pid を片付ける）。片付けが詰まっても猶予の後には終わる。
 */
async function shutdown(reason: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[bridge] shutting down (${reason})`);
  setTimeout(() => process.exit(0), SHUTDOWN_GRACE_MS).unref();
  try {
    running.stopMonitor?.();
    running.registry?.stop();
    running.relay?.stop();
    await running.bridge?.closeSessions();
    running.bridge?.services.stop();
    running.bridge?.server.close();
    running.lock?.release();
  } catch (error) {
    console.error(`[bridge] shutdown failed: ${String(error)}`);
  }
  process.exit(0);
}

// Windows の子プロセスにはシグナルが届かない（kill は TerminateProcess で、片付けが走らない）。
// デスクトップアプリは IPC で止める合図を送る。アプリが落ちて IPC が切れたときも、取り残されないよう終わる。
for (const signal of ["SIGINT", "SIGTERM"] as const) process.on(signal, () => void shutdown(signal));
process.on("message", (message) => {
  if ((message as { type?: unknown } | null)?.type === "shutdown") void shutdown("ipc");
});
process.on("disconnect", () => void shutdown("disconnect"));

// `node bridge.cjs mcp-stdio-relay` は mainagent の MCP の中継（stdio → /mcp）だけを動かして終わる
// （設定フォルダ・インスタンスの鍵・待ち受けには触らない。mainagent/stdioRelay.ts）。
if (isRelayInvocation(process.argv)) {
  void runStdioRelay();
} else {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
