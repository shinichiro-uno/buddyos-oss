import AppKit
import Foundation
import Observation
import Vapor

@Observable
@MainActor
final class BridgeServer {
    static let shared = BridgeServer()

    // 待ち受けの番号。BUDDYOS_BRIDGE_PORT があればそれ（デスクトップアプリや dev の固定）、無ければ
    // 8765 が空いていれば 8765、ふさがっていれば次に空いている番号。iPhone とは Paseo の中継でつながり
    // QR に番号は入らないので、番号が変わってもペアリングは切れない（実際の番号は bridge.port に書く）。
    private static let pinnedPort: Int? = ProcessInfo.processInfo.environment["BUDDYOS_BRIDGE_PORT"].flatMap { Int($0) }
    private(set) var port: Int
    // 待ち受けは自分の Mac の中だけ。iPhone は Paseo の中継でつながるので外に開かない。
    private let bindHost = "127.0.0.1"

    private(set) var status: String = "stopped"
    private(set) var isRunning: Bool = false
    /// メニューバーの「QR を表示」で作った招待（10 分・1 回だけ。spec/PROTOCOL-v3.md §6）。
    struct PairingQR {
        let image: NSImage
        let inviteId: String
        let expiresAt: Int64
    }
    private(set) var pairingQR: PairingQR?
    /// 端末認証 v3 の起動時の確かめ（移行・作り直しの続き）。keyIO の間はトンネルを張らず、30 秒ごとに読み直す。
    private(set) var identityStatus: KeyStore.IdentityStatus?
    private var keyRetryTask: Task<Void, Never>?
    /// 起動後に初めて登録に成功したら push の宛先も登録する（spec/PROTOCOL-v3.md §14.1）。
    private var pushTargetsSynced = false
    private var lastPurgeAt = Date.distantPast
    /// Claude / Codex の使用量スナップショット（メニューバーのポップオーバー表示用）。
    /// UsageHub は元々 WS 経由で iOS にしか流していないので、同一プロセスの
    /// メニューから読めるようここにミラーする。取得失敗時は providers[].error が立つ。
    private(set) var usage: UsageReport?
    /// usage listener はアプリ生存期間に1回だけ登録する（usage ポーリングは HTTP
    /// サーバの start/stop とは独立なので、wake-recovery の stop→start で二重登録
    /// しない）。BridgeServer はシングルトンなので listener の解除は不要。
    private var usageRegistered = false
    /// claude --bg の見張りの Live Activity リスナーも 1 回だけ登録する。
    private var bgActivityRegistered = false

    private var app: Application?
    private var server: Server?
    private var networkMonitor: NetworkMonitor?
    private var powerEventMonitor: PowerEventMonitor?
    private var wakeRecoveryTask: Task<Void, Never>?
    /// recoverAfterWake の実行中か。実行中に届いた wake/screen 通知で自分を cancel すると、
    /// cancel された URLSession が即失敗し、健全なサーバを再起動してしまうため合流させる。
    private var wakeRecoveryInFlight = false
    /// recoverAfterWake の実行中に wake/screen 通知が届いたか。捨てると、復旧の途中で再スリープ→復帰
    /// した時に relay や health を確かめ直さないまま終わるので、完了後に 1 回だけ再実行する。
    private var wakeRecoveryPending = false
    /// willSleep で Paseo relay を止めたか。wake 時はこれが立っている時だけ relay を張り直す
    /// （システムスリープを伴わない画面点灯 = screensDidWake で健全なトンネルを切らない）。
    private var relayStoppedForSleep = false
    /// Paseo relay を最後に start した時刻。経路変化通知の直前に別経路（wake 復旧など）で
    /// 張り直し済みなら、同じ経路で二重に切らないために使う。スリープ時間も数える単調時計。
    private var relayStartedAt: ContinuousClock.Instant?
    /// 起動失敗（別インスタンスが 8765 を握っている等）の自動再試行。stop() / 起動成功で取り消す。
    private var startRetryTask: Task<Void, Never>?
    private var startRetryAttempt = 0
    /// Keep discovery fresh and retry startup failures or refreshed credentials.
    private var registryHeartbeatTask: Task<Void, Never>?
    private let lifecycleLock = NSLock()
    private var isStarting = false

    private init() {
        port = Self.pinnedPort ?? PortPicker.firstFree(from: 8765) ?? 8765
        Task { await start() }
    }

    func toggle() async {
        isRunning ? await stop() : await start()
    }

    func start() async {
        lifecycleLock.lock()
        guard !isRunning, !isStarting else {
            lifecycleLock.unlock()
            return
        }
        isStarting = true
        lifecycleLock.unlock()
        defer {
            lifecycleLock.lock()
            isStarting = false
            lifecycleLock.unlock()
        }
        status = "starting"

        // 端末認証 v3: ルートを登録する前に、移行・作り直しの続き・devices.json・e2e-key を確かめる。
        Self.installIdentityHooks()
        if identityStatus == nil {
            identityStatus = KeyStore.prepareIdentityV3()
            // 古い QR（apiKey 入り）の PNG はもう書かない。起動時に消す。
            QRCodeGenerator.removePNG()
            DeviceStore.shared.purgeNeverSeen()
            lastPurgeAt = Date()
        }

        do {
            let app = try await Application.make(.detect())
            self.app = app
            app.http.server.configuration.port = port
            app.http.server.configuration.hostname = bindHost

            // 外のサービスの設定の出どころ（値は出さない。中継の URL だけ）。中継が無ければ案内も出す。
            WebSocketServer.wslog(BridgeConfig.current.describe())
            if PaseoRelayTunnelService.shared.relayURL == nil { WebSocketServer.wslog("[config] \(BridgeConfig.relayHint)") }
            await PushService.shared.configure()
            // 認証は BridgeAuth（トンネル経由は端末ごとの bdc_、この PC の中はローカル鍵。spec/PROTOCOL-v3.md §13）。
            // ルートに apiKey を閉じ込めない（作り直しで変わるため、毎回 LocalKey を読む）。
            WebSocketServer.register(app: app, agentRegistry: AgentRegistry.shared)
            // Live Preview (iOS simulator MJPEG stream + control, web reverse-proxy).
            PreviewRoutes.register(app: app)
            // プロジェクト内の画像ファイル（チャットの中で見る用）。
            ProjectFileRoutes.register(app: app)
            // 別の PC のデスクトップから、この Mac のターミナルを操作する口。
            TerminalPtyRoutes.register(app: app)
            // この Mac のデスクトップで開いているペインを、別の PC のデスクトップから見る口。
            TerminalShareRoutes.register(app: app)
            // 端末の管理（/local/*、管理鍵）と端末の自己管理（/device/*）。spec/PROTOCOL-v3.md Appendix A・§13.5
            LocalDeviceRoutes.register(app: app)
            // mainagent（窓口のエージェント）がほかのセッションを操作する口。認証は mainagent ごとの合鍵。
            // Host / Origin は BridgeRequestGuard、トンネル経由は BridgeAuth（.mainAgentToken）が断る。
            McpEndpoint.register(app: app)
            // エージェントどうしの依頼（設定・別の PC の一覧・別の PC から頼まれる口・すべての PC の一覧）。
            AgentMeshRoutes.register(app: app)
            MainAgentWorkspace.ensure()
            // アプリ内ターミナルで開いた mainagent の claude にも道具を渡す（.mcp.json の中継とターミナル用の合鍵）。
            MainAgentWorkspace.ensureTerminalToken()
            MainAgentWorkspace.ensureTerminalMcp(executable: McpStdioRelay.currentExecutable)
            await Orchestrator.shared.enablePersistence(at: Orchestrator.defaultStoreURL)
            // wake 復旧の生存確認専用。/health は全エージェントの probe（CLI 起動）を伴い
            // スリープ明けは 3 秒を超えうるので、actor やプロセス起動に触れず即 200 を返す。
            app.get("livez") { req -> HTTPStatus in
                try BridgeAuth.requireLocal(req)
                return .ok
            }

            try await app.asyncBoot()
            let server = app.server
            self.server = server
            // アプリ内ターミナルのペインの数を Live Activity へ。起動の途中に届く hook の数を取りこぼさないよう、
            // サーバーを開く前に付ける（すでに溜まっている数は付けたときに渡される）。
            TerminalPaneStatus.shared.setOnBackgroundChanged { key, count in
                LiveActivityPublisher.notePane(key: key, count: count)
            }
            try await server.start(address: nil)

            isRunning = true
            status = "running"
            startRetryTask?.cancel()
            startRetryTask = nil
            startRetryAttempt = 0
            relayStoppedForSleep = false
            startRelayIfIdentityReady()
            Task { [weak self] in await self?.registerBridgeToRegistry() }
            // 実ポートを発見用ファイルに書き出す（env で 8764/8765 等が変わりうるため）。
            KeyStore.writeBridgePort(port)

            // Bridge 内蔵 cron (claude/codex) と出力監視は WS リッスン開始後に
            // バックグラウンドで初期化する。CronOutputHub.startIfNeeded() は出力ファイルの
            // 全走査 (scanRoots) と seen JSON 読込を同期実行するため、蓄積が増えると
            // 無視できない時間がかかる。これを server.start() より前に await すると
            // 「プロセスは生きているのに WS ソケットが開かず iOS から繋がらない」状態
            // (= 起動失敗・同期失敗に見える) を生む。cron の発火/結果配信は元から
            // 非同期 (APNs push + WS broadcast) なので、初期化が数百ms遅れても実害はない。
            Task {
                await BridgeCronScheduler.shared.startIfNeeded()
                await CronOutputHub.shared.startIfNeeded()
                // メインの定期チェック（cron とは別のタイマー。60 秒ごとに回すかを見る）。
                await MainHeartbeat.shared.startIfNeeded()
                // claude --bg のセッションの見張り（一覧・変化の配信・完了の知らせ）。
                // 数と終わった遷移は Live Activity の数に渡す（最初の読み取りの遷移は渡されない）。
                // start() は stop→start で繰り返されるので、リスナーは 1 回だけ登録する（二重に数えない）。
                if !bgActivityRegistered {
                    bgActivityRegistered = true
                    _ = await ClaudeBackgroundJobs.shared.onActivity { activity in
                        LiveActivityPublisher.report(.bg, counts: activity.counts)
                        var done = 0, failed = 0, stopped = 0
                        for state in activity.finished {
                            switch state {
                            case .failed: failed += 1
                            case .stopped: stopped += 1
                            default: done += 1
                            }
                        }
                        LiveActivityPublisher.reportFinished(done: done, failed: failed, stopped: stopped)
                    }
                }
                await ClaudeBackgroundJobs.shared.start()
                // opencode のモデル一覧を先回りでキャッシュ。launchd 配下のコールド
                // bootstrap は ~13s かかり、クライアントがピッカーを開いた瞬間に取得すると
                // タイムアウトして「一覧が取れない」ように見える。起動直後に暖めておけば
                // 以降の list_models は即返せる（接続非依存なので確実にキャッシュされる）。
                // 入れていない・ログインしていない Mac で常駐させると、使わないのに CPU とメモリを取るので暖めない。
                let ocProbe = await AgentProbe.shared.probe(id: "opencode")
                if ocProbe.installed, ocProbe.configured,
                   let oc = await AgentRegistry.shared.adapter(for: "opencode") as? OpenCodeAdapter {
                    // serve(HTTP) サーバを起動時プリウォーム。初回チャットのコールドブートを隠す。
                    await oc.prewarmServer()
                    await oc.warmModelCatalog()
                }
            }

            // 使用量ハブを WS 接続有無に関わらず起動し、メニューバー表示用に購読する。
            // listener は actor から @Sendable で呼ばれるので MainActor へ hop して反映。
            // 登録はアプリ生存期間に1回だけ（再 start での二重登録を防ぐ）。
            if !usageRegistered {
                usageRegistered = true
                Task { [weak self] in
                    await UsageHub.shared.startIfNeeded()
                    _ = await UsageHub.shared.register(send: { event in
                        guard event.type == .usageReport,
                              let json = event.content,
                              let data = json.data(using: .utf8),
                              let report = try? JSONDecoder().decode(UsageReport.self, from: data)
                        else { return }
                        Task { @MainActor in self?.usage = report }
                    })
                }
            }

            // ネットワーク変化 (Wi-Fi↔有線の切替、IP 変更、スリープ復帰) を監視し、登録と QR を更新する。
            // 実際の経路変化なので、古い経路に残った relay ソケットは張り直す。
            let monitor = NetworkMonitor { [weak self] in
                Task { await self?.refreshNetworkEndpoints(restartRelay: true) }
            }
            monitor.start()
            self.networkMonitor = monitor

            let powerMonitor = PowerEventMonitor(
                onWillSleep: { [weak self] in
                    PaseoRelayTunnelService.shared.stop()
                    self?.relayStoppedForSleep = true
                    WebSocketServer.wslog("mac will sleep; Paseo sockets closed")
                },
                onDidWake: { [weak self] in
                    Task { await self?.scheduleWakeRecovery() }
                }
            )
            powerMonitor.start()
            self.powerEventMonitor = powerMonitor

            // 起動時のオフライン・認証更新後も1分以内に再登録する。
            registryHeartbeatTask?.cancel()
            registryHeartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await self?.heartbeatRegistry()
                    await self?.housekeeping()
                }
            }

            // ペアリングの URL は 10 分・1 回きりの招待（spec/PROTOCOL-v3.md §6）。それでもログに残さないよう、
            // 対話ターミナル (TTY) で起動された時だけ QR / URL を表示する。
            if isatty(STDOUT_FILENO) == 1 {
                print("─── BuddyOS Bridge ───────────────────────────────────")
                if PaseoRelayTunnelService.shared.relayURL == nil {
                    print(BridgeConfig.relayHint)
                } else if let invite = try? PairingInvites.shared.create() {
                    let payload = LocalDeviceRoutes.pairURL(for: invite)
                    if let qr = QRCodeGenerator.ascii(payload: payload) {
                        print(qr)
                    }
                    print("Pair URL: \(payload)")
                    print("この QR は 10 分間、1 回だけ使えます。")
                }
                print("──────────────────────────────────────────────────────")
            } else {
                print("BuddyOS Bridge running on port \(port). Pair from BuddyOS (Add a device) or the menu bar QR")
            }
            fflush(stdout)
        } catch {
            if let app = self.app {
                await server?.shutdown()
                try? await app.asyncShutdown()
            }
            self.app = nil
            self.server = nil
            isRunning = false
            status = "error: \(error.localizedDescription)"
            WebSocketServer.wslog("bridge start failed: \(error)")
            scheduleStartRetry()
        }
    }

    /// 起動失敗（ログイン時に別インスタンスと 8765 の bind を取り合った等）を放置すると、
    /// プロセスは生きたまま二度と listen しない。exit すると launchd / desktop が再起動する
    /// たびに共有レジストリの子プロセス掃除が走り、稼働中の側のセッションまで殺すため、
    /// プロセス内で上限付き指数バックオフ（2s→30s）で再試行する。QR/PNG は共有なので消さない。
    private func scheduleStartRetry() {
        startRetryTask?.cancel()
        let delay = min(30.0, 2.0 * pow(2.0, Double(startRetryAttempt)))
        startRetryAttempt = min(startRetryAttempt + 1, 5)
        WebSocketServer.wslog("bridge start retry in \(Int(delay))s")
        startRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.startRetryTask = nil
            // 番号を固定していなければ、ほかのアプリに取られた番号を待ち続けず、空いている番号で起動し直す。
            if Self.pinnedPort == nil, let free = PortPicker.firstFree(from: 8765) { self.port = free }
            await self.start()
        }
    }

    func stop() async {
        // usage listener はアプリ生存期間で1回だけ登録するため、ここでは解除しない
        // （HTTP サーバの stop と usage ポーリングは独立）。
        startRetryTask?.cancel()
        startRetryTask = nil
        startRetryAttempt = 0
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        registryHeartbeatTask?.cancel()
        registryHeartbeatTask = nil
        powerEventMonitor?.stop()
        powerEventMonitor = nil
        networkMonitor?.stop()
        networkMonitor = nil
        PaseoRelayTunnelService.shared.stop()
        if let server {
            await server.shutdown()
        }
        server = nil
        if let app {
            try? await app.asyncShutdown()
        }
        app = nil
        isRunning = false
        status = "stopped"
        KeyStore.clearBridgePort()
    }

    /// Lid open / wake can leave the Paseo relay or the Vapor listener
    /// looking alive while one of them is stale. Debounce duplicated wake/screen
    /// notifications, then refresh endpoints and restart only when local health
    /// no longer answers.
    private func scheduleWakeRecovery() async {
        guard isRunning else { return }
        // 復旧処理の実行中は cancel しない（debounce 中の重複通知だけまとめる）。
        // 実行中に cancel すると health チェックが cancelled で失敗し、不要な再起動になる。
        // ただし通知は捨てない。実行中の復旧は relay 再開の分岐を通過済みなので、途中で再スリープ→復帰
        // していたら relay だけはここで張り直し（復旧が cancel に反応しない await で止まっていても
        // 取りこぼさない）、残りは完了後に 1 回だけ再実行する。
        if wakeRecoveryInFlight {
            wakeRecoveryPending = true
            if relayStoppedForSleep {
                relayStoppedForSleep = false
                startRelayIfIdentityReady()
            }
            return
        }
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.recoverAfterWake()
        }
    }

    private func recoverAfterWake() async {
        guard isRunning, !Task.isCancelled else { return }
        wakeRecoveryInFlight = true
        wakeRecoveryPending = false
        defer {
            wakeRecoveryInFlight = false
            if wakeRecoveryPending {
                wakeRecoveryPending = false
                Task { [weak self] in await self?.scheduleWakeRecovery() }
            }
        }
        WebSocketServer.wslog("mac did wake; refreshing bridge endpoints")
        await refreshNetworkEndpoints(restartRelay: false)
        // 復旧中に「停止」された（stop() が cancel し isRunning=false）なら何もしない。
        guard !Task.isCancelled, isRunning else { return }

        var health = await localHealth()
        if health == .failed {
            // 一度の取りこぼしで全接続を切る再起動をしないよう、1 秒後に 1 回だけ再確認する。
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, isRunning else { return }
            health = await localHealth()
        }
        guard health != .cancelled, !Task.isCancelled, isRunning else { return }
        if health == .ok {
            WebSocketServer.wslog("wake recovery ok: local health responded")
            return
        }

        WebSocketServer.wslog("wake recovery: local health failed; restarting bridge server")
        status = "recovering"
        // stop() は wakeRecoveryTask（= 実行中のこのタスク）を cancel する。先に切り離さないと
        // 続く start() がキャンセル済みの文脈で走る。
        wakeRecoveryTask = nil
        await stop()
        await start()
    }

    /// ネットワーク変化時に呼ばれる。登録簿への登録と QR / ペアリング情報を作り直す。
    /// @Observable なのでメニュー表示も更新される。
    /// relay の張り直し（start は内部で stop し全トンネルを切る）は、実際の経路変化
    /// （restartRelay）か willSleep で止めていた時だけ行う。
    private func refreshNetworkEndpoints(restartRelay: Bool) async {
        guard isRunning else { return }
        // 経路変化の通知は最後の変化から debounce 後に届く。その間に relay を start 済み
        // （wake 直後に recoverAfterWake が先に張り直した等）なら新しい経路で張られているので、
        // iPhone が張り直した接続をもう一度切らない。
        let relayFreshOnPath = relayStartedAt.map {
            ContinuousClock.now - $0 < .seconds(NetworkMonitor.debounceInterval)
        } ?? false
        if relayStoppedForSleep || (restartRelay && !relayFreshOnPath) {
            relayStoppedForSleep = false
            startRelayIfIdentityReady()
        }
        await registerBridgeToRegistry()
        // 「ネット切替に追従したか」をリモート (/status) から確認できるよう時刻を残す。
        WebSocketServer.noteNetworkRefresh()
        WebSocketServer.wslog("network changed → refreshed registry")
    }

    /// この Bridge の中継の接続先を Convex の登録簿（v3）に載せる（spec/PROTOCOL-v3.md §15.5）。
    /// 載せるのは秘密の無い値だけ（bridgeId・名前・relayURL・relayId・Bridge の公開鍵）。apiKey は載せない。
    /// 認証は端末トークン `bdt_`。無ければ Clerk のトークン（desktop が ~/.buddyos/clerk-access-token に書く）で発行する。
    private var registryInFlight = false
    private var registryLastAttempt = Date.distantPast
    private var registryTokenModifiedAt: Date?

    private var currentTokenModifiedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: NSHomeDirectory() + "/.buddyos/clerk-access-token"))?[.modificationDate] as? Date
    }

    /// Clerk access token は短命（~2h）。spawn 時の env だけだと常駐 bridge の発行が失効トークンで
    /// 401 になるため、desktop が refresh のたびに書き直す ~/.buddyos/clerk-access-token を優先して読む（無ければ env）。
    private func currentClerkToken() -> String? {
        let fileToken = (try? String(
            contentsOfFile: NSHomeDirectory() + "/.buddyos/clerk-access-token", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = (fileToken?.isEmpty == false ? fileToken : nil) ?? ProcessInfo.processInfo.environment["BUDDYOS_CLERK_TOKEN"]
        guard let token, !token.isEmpty, !token.hasPrefix("bdt_") else { return nil }
        return token
    }

    /// 作り直し・/local/registry/resume のあと、すぐ登録し直す。
    func requestRegistrationSoon() {
        registryLastAttempt = .distantPast
        Task { [weak self] in await self?.registerBridgeToRegistry() }
    }

    /// 登録簿・中継が無いことを 1 回だけログに出したか。
    private var registryOffLogged = false

    private func registerBridgeToRegistry() async {
        guard !registryInFlight else { return }
        // 登録簿が無い（公開版の既定）・中継が無い: 登録しない。QR のペアリングだけで使う。
        guard let site = PushService.convexSite(), PaseoRelayTunnelService.shared.relayURL != nil else {
            if !registryOffLogged {
                registryOffLogged = true
                WebSocketServer.wslog("registry is off (no BUDDYOS_CONVEX_SITE or no relay): pairing by QR only")
            }
            return
        }
        registryInFlight = true
        registryLastAttempt = Date()
        registryTokenModifiedAt = currentTokenModifiedAt
        defer { registryInFlight = false }
        // アカウントから外された・この PC を外した: デスクトップで明示的にサインインし直すまで、発行も登録もしない（§15.7）。
        if KeyStore.registryHold() != nil {
            RegistryStatus.recordFailure(RegistryStatus.Reason.hold)
            return
        }
        guard identityStatus == .ready, KeyStore.e2eKey() != nil else {
            RegistryStatus.recordFailure(RegistryStatus.Reason.keyIO)
            return
        }
        var deviceToken = KeyStore.deviceToken()
        if deviceToken == nil {
            guard let clerk = currentClerkToken() else {
                WebSocketServer.wslog("register skipped: no device token and no clerk token (desktop でサインインすると復帰)")
                RegistryStatus.recordFailure(RegistryStatus.Reason.signinRequired)
                return
            }
            var outcome = await mintDeviceToken(site: site, clerkToken: clerk)
            if case .alreadyRegistered = outcome {
                // この bridgeId には有効な bdt_ がもうある（トークンを失くしたか、盗まれた）。古い bridgeId を控えて
                // bridgeId を作り直し、1 回だけ発行し直す（§15.4。ペアリングは鍵で続くので切れない）。
                RegistryStatus.recordPrevious(bridgeId: KeyStore.loadOrCreateBridgeId())
                KeyStore.regenerateBridgeId()
                KeyStore.clearRegistered()
                DeviceStore.shared.bumpVersion()
                outcome = await mintDeviceToken(site: site, clerkToken: clerk)
            }
            switch outcome {
            case .minted(let token):
                deviceToken = token
            case .revoked:
                markAccountRevoked()
                return
            case .rateLimited:
                RegistryStatus.recordFailure(RegistryStatus.Reason.rateLimited)
                return
            case .alreadyRegistered, .failed(_):
                if case .failed(let reason) = outcome { RegistryStatus.recordFailure(reason) }
                else { RegistryStatus.recordFailure("already_registered") }
                return
            }
        }
        guard let token = deviceToken, let url = URL(string: "\(site)/v3/bridges/register") else { return }
        let current = KeyStore.Registered(
            bridgePub: KeyStore.e2ePublicKeyBase64URL(),
            relayId: KeyStore.loadOrCreatePaseoRelayId(),
            relayURL: PaseoRelayTunnelService.shared.relayURLString
        )
        var body: [String: Any] = [
            "v": 3,
            "bridgeId": KeyStore.loadOrCreateBridgeId(),
            "machineName": BridgeIdentityInfo.machineName,
            "platform": "mac",
            "relayURL": current.relayURL,
            "relayId": current.relayId,
            "bridgePub": current.bridgePub,
        ]
        if let machineId = KeyStore.registryMachineId() { body["machineId"] = machineId }
        // 前に登録できた値と違えば（作り直しの後）、前の値を付ける（409 key_changed は誤動作を防ぐだけ。§3.3）。
        if let prev = KeyStore.registered(), prev != current {
            body["keyRotation"] = ["prevBridgePub": prev.bridgePub, "prevRelayId": prev.relayId]
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        TrafficMeter.shared.record("registry.out", bytes: req.httpBody?.count ?? 0)
        do {
            // URLSession は 401 等でも throw しない。ステータスを見ないと
            // 「registered」と偽陽性ログを出し続ける（実際に起きた）。
            let (data, response) = try await URLSession.shared.data(for: req)
            TrafficMeter.shared.record("registry.in", bytes: data.count)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorCode = json?["error"] as? String
            if (200..<300).contains(status) {
                WebSocketServer.wslog("registered Paseo bridge to registry (v3)")
                KeyStore.setRegistered(current)
                RegistryStatus.recordSuccess(usedDeviceToken: true)
                // (userSub, bridgeId) は bdt_ の行のもの。サーバーが返す bridgeId に合わせる。
                if let authoritative = json?["bridgeId"] as? String,
                   !authoritative.isEmpty,
                   authoritative != KeyStore.loadOrCreateBridgeId() {
                    WebSocketServer.wslog("register: adopting server bridgeId \(authoritative.prefix(24))…")
                    KeyStore.setBridgeId(authoritative)
                }
                // 期限が近いとサーバーが新しい資格情報を同梱してくる。保存に失敗したら旧トークンを使い続ける。
                if let rotated = json?["deviceToken"] as? String, !rotated.isEmpty {
                    if KeyStore.setDeviceToken(rotated) {
                        WebSocketServer.wslog("device-token rotated")
                    } else {
                        WebSocketServer.wslog("device-token rotation not saved — keeping the current token")
                    }
                }
                if !pushTargetsSynced {
                    pushTargetsSynced = true
                    Task { await PushService.shared.syncTargetsNow() }
                }
                // 初めてと、401 / 403 で ready を落としたあとの登録で、Live Activity の push を確かめ直す。
                Task { await LiveActivityPublisher.shared.registryReadyIfNeeded() }
            } else if status == 403 && errorCode == "revoked" {
                markAccountRevoked()
            } else if status == 409 && errorCode == "key_changed" {
                // 登録簿の鍵と食い違う（古い Bridge の書き戻しなど）。新しい PC として登録し直す（§15.5）。
                WebSocketServer.wslog("register: 409 key_changed — rotating bridgeId and registering as a new computer")
                RegistryStatus.recordPrevious(bridgeId: KeyStore.loadOrCreateBridgeId())
                KeyStore.regenerateBridgeId()
                KeyStore.clearDeviceToken()
                KeyStore.clearRegistered()
                DeviceStore.shared.bumpVersion()
                RegistryStatus.recordFailure(RegistryStatus.Reason.keyChanged)
                registryLastAttempt = .distantPast
            } else if status == 429 {
                RegistryStatus.recordFailure(RegistryStatus.Reason.rateLimited)
            } else if status == 401 {
                // The device token expired or the row was deleted. Drop it so
                // the next attempt re-mints from Clerk instead of retrying a dead credential forever.
                // ~/.buddyos を共有して並走する別の Bridge がローテーション後の新トークンを
                // 書いた後なら、それを消さない（今回送ったトークンのときだけ消す）。
                if KeyStore.deviceToken() == token {
                    WebSocketServer.wslog("register: device token rejected (401) — clearing, will re-mint")
                    KeyStore.clearDeviceToken()
                } else {
                    WebSocketServer.wslog("register: device token rejected (401) — file already replaced, keeping it")
                }
                RegistryStatus.recordFailure("device token rejected (401)")
            } else {
                WebSocketServer.wslog("register rejected: HTTP \(status) \(errorCode ?? "-")")
                RegistryStatus.recordFailure("HTTP \(status)")
            }
        } catch {
            // stop() / wake 復旧で heartbeat 等が cancel された時は失敗として記録しない。
            if Self.isCancellation(error) {
                WebSocketServer.wslog("register cancelled")
                return
            }
            WebSocketServer.wslog("register failed: \(error)")
            RegistryStatus.recordFailure("\(error)")
        }
    }

    /// 登録で 403 revoked（アカウントから外された）。device-token を消し、bridgeId を作り直し、registry-hold を置く。
    /// 端末の一覧と鍵は消さない（デスクトップかメニューバーで選ぶ。§15.7）。
    private func markAccountRevoked() {
        WebSocketServer.wslog("register: bridge revoked (403) — removed from account")
        KeyStore.accountRevoked()
        RegistryStatus.recordFailure(RegistryStatus.Reason.revoked)
        DeviceStore.shared.bumpVersion()
    }

    private enum DeviceTokenMintResult {
        case minted(String)
        /// (userSub, bridgeId) に失効の記録がある（403 {error:"revoked"}）。
        case revoked
        /// 有効な bdt_ がすでにある（409 already_registered）。
        case alreadyRegistered
        case rateLimited
        case failed(String)
    }

    /// Clerk のトークンで端末トークンを発行する（`/v3/device-token`。§15.4）。1 台に 1 回。
    private func mintDeviceToken(site: String, clerkToken: String) async -> DeviceTokenMintResult {
        guard let url = URL(string: "\(site)/v3/device-token") else { return .failed("bad site") }
        var body: [String: Any] = [
            "bridgeId": KeyStore.loadOrCreateBridgeId(),
            "machineName": BridgeIdentityInfo.machineName,
            "platform": "mac",
        ]
        if let machineId = KeyStore.registryMachineId() { body["machineId"] = machineId }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(clerkToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let current = KeyStore.deviceToken() { req.setValue(current, forHTTPHeaderField: "X-BuddyOS-Device-Token") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        TrafficMeter.shared.record("registry.out", bytes: req.httpBody?.count ?? 0)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            TrafficMeter.shared.record("registry.in", bytes: data.count)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let errorCode = json?["error"] as? String
            if status == 403 && errorCode == "revoked" { return .revoked }
            if status == 409 && errorCode == "already_registered" { return .alreadyRegistered }
            if status == 429 { return .rateLimited }
            guard (200..<300).contains(status), let token = json?["deviceToken"] as? String, !token.isEmpty else {
                WebSocketServer.wslog("device-token mint failed: HTTP \(status) (clerk token 失効なら desktop で再サインイン)")
                return .failed("device-token HTTP \(status)")
            }
            KeyStore.setDeviceToken(token)
            WebSocketServer.wslog("device-token minted — heartbeat no longer depends on the Clerk session")
            return .minted(token)
        } catch {
            WebSocketServer.wslog("device-token mint failed: \(error)")
            return .failed("\(error)")
        }
    }

    /// Retry every minute; notice newly refreshed credentials within five seconds.
    private func heartbeatRegistry() async {
        guard isRunning else { return }
        guard Date().timeIntervalSince(registryLastAttempt) >= 60
            || currentTokenModifiedAt != registryTokenModifiedAt else { return }
        await registerBridgeToRegistry()
    }

    /// 5 秒ごと: 承認待ちの時間切れ。1 時間ごと: 一度もつながらなかった端末の行の掃除（§12）。
    private func housekeeping() async {
        ApprovalQueue.shared.expire()
        if Date().timeIntervalSince(lastPurgeAt) >= 3600 {
            lastPurgeAt = Date()
            DeviceStore.shared.purgeNeverSeen()
        }
        if let qr = pairingQR, DeviceStore.nowMs() >= qr.expiresAt { pairingQR = nil }
    }

    // MARK: - 端末認証 v3 の結線

    /// トンネルは e2e-key が読めるときだけ張る。読めない（key_io）なら 30 秒ごとに読み直す。
    private func startRelayIfIdentityReady() {
        guard identityStatus == .ready else {
            RegistryStatus.recordFailure(RegistryStatus.Reason.keyIO)
            scheduleKeyRetry()
            return
        }
        PaseoRelayTunnelService.shared.start(port: port)
        relayStartedAt = .now
    }

    private func scheduleKeyRetry() {
        guard keyRetryTask == nil else { return }
        keyRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                let status = KeyStore.checkE2EKey()
                guard status == .ready else { continue }
                self.identityStatus = .ready
                self.keyRetryTask = nil
                if self.isRunning {
                    self.startRelayIfIdentityReady()
                    self.requestRegistrationSoon()
                }
                return
            }
        }
    }

    private static var identityHooksInstalled = false

    /// 作り直し・宛先の変化・招待と承認待ちの変化を、トンネル・push・DevicesView の version につなぐ（1 回だけ）。
    private static func installIdentityHooks() {
        guard !identityHooksInstalled else { return }
        identityHooksInstalled = true
        KeyStore.onIdentityReset = { _ in
            PaseoRelayTunnelService.shared.restartIfRunning()
            Task { @MainActor in
                BridgeServer.shared.pairingQR = nil
                BridgeServer.shared.requestRegistrationSoon()
            }
        }
        DeviceStore.shared.onPushTargetsChanged = {
            Task { await PushService.shared.scheduleTargetsSync() }
        }
        PairingInvites.shared.onChange = { DeviceStore.shared.bumpVersion() }
        ApprovalQueue.shared.onChange = { DeviceStore.shared.bumpVersion() }
        DeviceAdmin.requestRegistration = {
            Task { @MainActor in BridgeServer.shared.requestRegistrationSoon() }
        }
    }

    /// メニューバーの「QR を表示」。押したら招待を作って QR を出す。HTTP を通らない（管理鍵が無い Bridge でも使える）。
    func showPairingQR() {
        guard let invite = try? PairingInvites.shared.create() else { return }
        let url = LocalDeviceRoutes.pairURL(for: invite)
        guard let image = QRCodeGenerator.make(payload: url) else {
            PairingInvites.shared.cancel(inviteId: invite.inviteId)
            return
        }
        if let old = pairingQR { PairingInvites.shared.cancel(inviteId: old.inviteId) }
        pairingQR = PairingQR(image: image, inviteId: invite.inviteId, expiresAt: invite.expiresAt)
        WebSocketServer.wslog("pairing invite created via menu bar")
    }

    /// QR を隠したら招待を取り消す（使われていても、その後のやり直しの分は取り消す）。
    func hidePairingQR() {
        if let qr = pairingQR { PairingInvites.shared.cancel(inviteId: qr.inviteId) }
        pairingQR = nil
    }

    /// アカウントから外された後の選択をメニューバーで選んだか（「端末はそのまま」は起動している間だけ覚える）。
    private(set) var accountRemovalChoiceMade = false

    /// アカウントから外された後の選択をメニューバーに出すか: アカウントから外された（registry-hold が revoked_by_account）後で、
    /// まだ選んでおらず、その後に「すべて切断」もしていないとき。デスクトップが動いていれば（管理鍵がある）出さない。
    var needsAccountRemovalChoice: Bool {
        guard !AdminKey.shared.isAvailable, !accountRemovalChoiceMade,
              let hold = KeyStore.registryHold(),
              hold.reason == KeyStore.ResetReason.revokedByAccount.rawValue else { return false }
        if let last = DeviceStore.shared.lastReset,
           last.reason == KeyStore.ResetReason.revokedByAccount.rawValue, last.at >= hold.since { return false }
        return true
    }

    /// メニューバー: 「すべて切断」。アカウントから外された後にだけ選べる。
    func disconnectAllAfterAccountRemoval() {
        guard KeyStore.registryHold()?.reason == KeyStore.ResetReason.revokedByAccount.rawValue else { return }
        accountRemovalChoiceMade = true
        KeyStore.resetIdentity(.revokedByAccount)
    }

    /// メニューバー: 「端末はそのまま」。端末の一覧と鍵は残す。
    func keepDevicesAfterAccountRemoval() {
        accountRemovalChoiceMade = true
    }

    private enum LocalHealth { case ok, failed, cancelled }

    /// wake 復旧の生存確認。/health は全エージェントの probe を伴い重いので軽量な /livez を叩く。
    /// cancel（復旧中の停止など）は「応答なし」と区別し、再起動の理由にしない。
    private func localHealth() async -> LocalHealth {
        let apiKey = LocalKey.shared.current()
        guard let url = URL(string: "http://127.0.0.1:\(port)/livez") else { return .failed }
        var request = URLRequest(url: url, timeoutInterval: 3.0)
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200 ? .ok : .failed
        } catch {
            if Self.isCancellation(error) { return .cancelled }
            WebSocketServer.wslog("wake recovery health check failed: \(error)")
            return .failed
        }
    }

    /// URLSession はタスク cancel 時に CancellationError ではなく URLError(.cancelled) を投げる。
    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// 空いている待ち受けの番号を探す。
enum PortPicker {
    /// from から順に count 個試し、どこにも使われていない番号を返す（無ければ nil）。
    static func firstFree(from: Int, count: Int = 64) -> Int? {
        for port in from..<(from + count) where isFree(port) { return port }
        return nil
    }

    /// 0.0.0.0 と 127.0.0.1 の両方に bind できたら「空き」。
    /// SO_REUSEADDR を付けるのは、切断直後の残り（TIME_WAIT）を使用中と見ないため（付けないと再起動のたびに番号がずれる）。
    /// 付けると 0.0.0.0 だけでは 127.0.0.1 だけで待ち受けるアプリを見逃すので、127.0.0.1 でも試す。
    static func isFree(_ port: Int) -> Bool {
        canBind(port, INADDR_ANY) && canBind(port, INADDR_LOOPBACK)
    }

    private static func canBind(_ port: Int, _ host: in_addr_t) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: host.bigEndian)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

