import path from "node:path";
import type { AgentAdapter } from "./agents/types.js";
import type { BridgeConfig } from "./config.js";
import type { SessionEvent } from "./protocol.js";
import { AgentLoginService } from "./agentLogin.js";
import { CronService } from "./cron/cronService.js";
import { CronOutputHub } from "./cron/outputHub.js";
import { BridgeCronScheduler } from "./cron/scheduler.js";
import { ProjectRegistry } from "./projects.js";
import type { PushService } from "./pushService.js";
import { UsageHub } from "./usage.js";
import { SitesService } from "./sites.js";
import { agentHome } from "./mcpService.js";
import { closeBuddyMcp } from "./agents/buddy.js";
import type { TerminalServices } from "./terminal/routes.js";
import { SleepGuard } from "./sleepGuard.js";
import { ClaudeCodeAdapter } from "./agents/claudeCode.js";
import { ClaudeBackgroundJobs } from "./terminal/claudeBackgroundJobs.js";
import type { HeartbeatService } from "./mainagent/heartbeat.js";
import { LiveActivityPublisher } from "./liveActivity/publisher.js";

/// 接続をまたいで 1 つだけ持つ Bridge の常駐機能（mac の各 actor.shared 相当）。
/// 状態ファイルは Bridge の設定フォルダ（Windows は %LOCALAPPDATA%\BuddyOS\Bridge）に置く。
/// mac の ~/.buddyos と分けておくと、同じ Mac で両方の Bridge を動かしても状態を取り合わない。
export interface BridgeServices {
  adapters: Map<string, AgentAdapter>;
  cron: CronService;
  cronScheduler: BridgeCronScheduler;
  cronOutputs: CronOutputHub;
  projects: ProjectRegistry;
  usage: UsageHub;
  /** 公開したサイトの一覧（vercel / wrangler の CLI から。5 分キャッシュ）。 */
  sites: SitesService;
  login: AgentLoginService;
  /** 生成中・cron の実行中だけスリープを止める。 */
  sleep: SleepGuard;
  /** claude --bg のセッション（一覧・操作・知らせ。native の runtime のときだけ動く）。 */
  bgSessions: ClaudeBackgroundJobs;
  /** Live Activity（バックグラウンドの作業の数・batch・登録簿への push。docs/BACKGROUND_CONTROL_2026-10-21.md §8）。 */
  liveActivity: LiveActivityPublisher;
  /** ターミナル連携（server が組み立てて入れる）。 */
  terminal?: TerminalServices;
  /** "claude:<sid>" の購読者へ配る（再接続用に記録する。claude --bg の会話が使う）。 */
  publishClaude?: (evt: SessionEvent) => void;
  /**
   * mainagent のセッション（"agentId:sessionId"）→ 任せた子のカード（workflow_progress kind = "sessions"）の最新。
   * server が組み立てて入れ、購読したとき・turn_status_request に渡す（チャットの「子のカード」）。
   */
  mainagentCards?: Map<string, string>;
  /** メインの定期チェック（hub が要るので server が組み立てて入れる。docs/MAIN_HEARTBEAT_2026-10-20.md）。 */
  heartbeat?: HeartbeatService;
  /** listen 後に呼ぶ（見回りの開始）。 */
  start(): void;
  stop(): void;
}

export function createBridgeServices(
  config: BridgeConfig,
  adapters: Map<string, AgentAdapter>,
  pushService: PushService
): BridgeServices {
  const cronRoot = path.join(config.configDir, "cron");
  const sleep = new SleepGuard();
  const cronScheduler = new BridgeCronScheduler({
    root: cronRoot,
    adapterFor: (id) => adapters.get(id),
    onActiveChange: (active) => sleep.setActive(active, "cron")
  });
  const cronOutputs = new CronOutputHub(
    cronScheduler.outputRoot,
    (title, body, data) => void pushService.broadcast(title, body, data),
    path.join(config.configDir, "cron_pushed.json")
  );
  const claude = adapters.get("claude");
  const bgSessions = new ClaudeBackgroundJobs({
    runtime: claude instanceof ClaudeCodeAdapter ? claude.runtimeCommand : undefined,
    bridgeId: config.bridgeId,
    push: (title, body, data) => pushService.broadcast(title, body, data),
    setSleep: (active) => sleep.setActive(active, "claude-bg")
  });
  // claude --bg のセッションの数（working / blocked）と終わった遷移を Live Activity へ渡す。
  const liveActivity = new LiveActivityPublisher({ transport: pushService });
  bgSessions.onActivity(({ counts, finished }) => {
    const tally = { done: 0, failed: 0, stopped: 0 };
    for (const state of finished) tally[state] += 1;
    liveActivity.noteFinished(tally);
    liveActivity.noteSource("bg", counts);
  });
  const usage = new UsageHub({ runtimeLabel: (id) => adapters.get(id)?.runtimeLabel });
  const services: BridgeServices = {
    adapters,
    sleep,
    bgSessions,
    liveActivity,
    login: new AgentLoginService(),
    cron: new CronService(cronScheduler),
    cronScheduler,
    cronOutputs,
    projects: new ProjectRegistry(path.join(config.configDir, "projects.json")),
    usage,
    sites: new SitesService(),
    start() {
      cronScheduler.start();
      cronOutputs.start();
      bgSessions.start();
      liveActivity.start();
      services.heartbeat?.start();
      // Hermes 自身の cron の結果（~/.hermes/cron/output）も配る（mac の CronOutputWatcher と同じ）。
      // WSL の Hermes は WSL 側のホームを UNC パスで見る。
      const hermesLabel = adapters.get("hermes")?.runtimeLabel;
      void agentHome("hermes", hermesLabel)
        .then((home) => {
          if (home) cronOutputs.addRoot(path.join(home, ".hermes", "cron", "output"), "hermes", /^[\\/]{2}wsl/i.test(home));
        })
        .catch(() => {});
    },
    stop() {
      cronScheduler.stop();
      services.heartbeat?.stop();
      cronOutputs.stop();
      bgSessions.stop();
      liveActivity.stop();
      usage.stop();
      closeBuddyMcp();
      sleep.stop();
    }
  };
  return services;
}
