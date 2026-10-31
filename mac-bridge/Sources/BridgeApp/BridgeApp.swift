import AppKit
import Foundation
import SwiftUI

/// プロセスの入口。`BridgeApp mcp-stdio-relay` は mainagent の MCP の中継（McpStdioRelay）だけを動かして終わる
/// （stdio の MCP しか受け取れない ACP エージェントが起こす。アプリも Bridge のサーバも起こさない）。
/// `BridgeApp --print-id-prefix` は ID の頭（`BUDDYOS_ID_PREFIX` → 配布物の既定）を 1 行出して終わる
/// （LaunchAgent のラベル `<頭>.bridge` をスクリプトが決めるのに使う）。
/// それ以外はメニューバー常駐の Bridge として起動する。
@main
enum BridgeEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--print-id-prefix" {
            print(BridgeConfig.current.idPrefix.value)
            exit(0)
        }
        if McpStdioRelay.isInvocation(CommandLine.arguments) { McpStdioRelay.runAndExit() }
        BuddyOSBridgeApp.main()
    }
}

struct BuddyOSBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // メニューバー常駐アプリ。表示はすべて AppDelegate の NSStatusItem +
        // NSPopover が持つ（アニメーション制御のため MenuBarExtra は使わない）。
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var sigtermSource: DispatchSourceSignal?
    private var parentExitSource: DispatchSourceProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        // Bridge は 1 台に 1 つだけ。ほかの Bridge が動いていれば、何にも触らずに終わる
        // （下の子プロセスの片付けやログの切り詰めを 2 つ目が走らせると、動いている方の会話やログまで消してしまう）。
        // 終了コード 75 で、デスクトップアプリは「動いている方につなぐ」と判断する。
        guard InstanceLock.acquire() else {
            FileHandle.standardError.write(Data("[bridge] another BuddyOS bridge is already running; exiting\n".utf8))
            exit(75)
        }
        // launchd の StandardOut/ErrorPath は launchd 自身がローテーションしないため、
        // 前回までの運用で肥大していたらここで切り詰める (/tmp 枯渇→bind 失敗の防止)。
        // launchd から起動されたとき（親が launchd = PID 1）だけ。デスクトップアプリが起動した
        // Bridge のログはパイプで渡るので、ほかの（launchd の）Bridge のログに手を出さない。
        if getppid() == 1 { Self.truncateLaunchdLogsIfNeeded() }
        // 前回起動が SIGKILL (launchctl kickstart -k 等) で死んだ場合、setpgid で
        // 独立グループ化した acp/claude/codex 子プロセスが孤児 (PPID=1) として残っている。
        // 新しいセッションを spawn する前にここで回収する。
        SpawnRegistry.sweepStaleProcesses()
        // 終了済みの子プロセスのパイプへ書いたとき、SIGPIPE で Bridge ごと落ちないようにする
        // （書き込み側は EPIPE を受け取る）。AcpClient の stdin は
        // F_SETNOSIGPIPE を付けていないので、実際にこの設定だけで守られている。
        signal(SIGPIPE, SIG_IGN)
        // SIGTERM (launchctl unload / 通常停止) では子プロセスを道連れにしてから終了する。
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { Self.shutdownAndExit() }
        source.resume()
        sigtermSource = source
        // desktop の supervisor は stdio をパイプで繋いで spawn する。SIGPIPE を無視したので、
        // desktop がクラッシュ/SIGKILL で消えても次のログ書き込みで道連れにならず、孤児 (PPID=1)
        // のままポートを握り続ける（再起動した desktop は attach するだけで止められない）。
        // launchd 配下 (PPID=1) 以外では親の終了を監視し、SIGTERM と同じ手順で終了する。
        let ppid = getppid()
        if ppid != 1 {
            let parent = DispatchSource.makeProcessSource(identifier: ppid, eventMask: .exit, queue: .main)
            parent.setEventHandler {
                WebSocketServer.wslog("parent process \(ppid) exited; shutting down bridge")
                Self.shutdownAndExit()
            }
            parent.resume()
            parentExitSource = parent
        }
        // 管理鍵（spec/PROTOCOL-v3.md Appendix A）。デスクトップが stdin に 1 行で渡す。
        // 読み始める前に fd 0 を /dev/null にするので、Bridge が起こす子プロセスは管理鍵のパイプを受け継がない。
        // stdin が閉じたら（デスクトップがいなくなった）「端末を追加」の窓を閉じ、承認待ちを closed で取り下げる。
        // 別の PC の一覧（中継口の番号と合言葉）も、渡したデスクトップがいなくなったので空にする。
        AdminChannel.start(onEOF: {
            ApprovalQueue.shared.closeWindow(reason: .closed)
            Task { await Orchestrator.shared.setRemotePCs([]) }
        })
        // サーバーを起動する（BridgeServer は最初に触れたときに start する）。
        let server = BridgeServer.shared
        // メニューバーのアイコンは、頼まれたとき（BUDDYOS_MENU_BAR=1）だけ出す。
        // デスクトップアプリが起動したときはアプリ側に状態が出るので、アイコンが 2 種類並ばないようにする。
        if ProcessInfo.processInfo.environment["BUDDYOS_MENU_BAR"] == "1" {
            menuBar = MenuBarController(server: server)
        }
    }

    /// SIGTERM / 親プロセス終了時の後始末。どちらも .main キューのハンドラから呼ぶ。
    nonisolated private static func shutdownAndExit() -> Never {
        SpawnRegistry.killAllRegistered()
        // hook は実行のたびに bridge.port を読むので、古いポートを残すと全 hook が失敗し続ける。
        // ~/.buddyos は別インスタンス（dev 8764 等）と共有なので、自分が bind して書いたポートの時だけ消す
        // （bind 待ちで一度も書いていないなら、中身が同じポートでも相手のもの）。
        MainActor.assumeIsolated {
            let server = BridgeServer.shared
            if server.isRunning { KeyStore.clearBridgePort(ifEquals: server.port) }
            KeyStore.clearBridgePid(ifEquals: getpid())
        }
        exit(0)
    }

    /// launchd の plist が向けている ~/Library/Logs/BuddyOS/bridge.{out,err}.log（古い plist は /tmp）の肥大対策。
    /// launchd はログをローテーションしないので、上限超過なら起動時に in-place で切り詰める。
    /// rename 退避だと launchd が掴んでいる inode に書き続けて新ファイルへ切り替わらないため、
    /// truncate(2) を使う (launchd は O_APPEND で開くので truncate 後の追記も安全)。
    private static let launchdLogMaxBytes = 10 * 1024 * 1024   // 10MB
    private static let launchdLogKeepTailBytes = 1 * 1024 * 1024   // 退避する末尾 1MB

    private static func truncateLaunchdLogsIfNeeded() {
        // 新しい plist は ~/Library/Logs/BuddyOS に書く。古い plist（/tmp）のままの環境も切り詰める。
        let logDir = NSHomeDirectory() + "/Library/Logs/BuddyOS"
        for path in [logDir + "/bridge.out.log", logDir + "/bridge.err.log",
                     "/tmp/buddyos-bridge.out.log", "/tmp/buddyos-bridge.err.log"] {
            // シンボリックリンク・他人のファイルには触らない（attributesOfItem はリンクをたどらない）。
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let size = attrs[.size] as? Int, size > launchdLogMaxBytes else { continue }
            // クラッシュ→KeepAlive 再起動の直後は「直前のクラッシュ痕跡」がこのログの末尾にある。
            // 全消しすると原因調査ができなくなるので、末尾だけ .1 へ退避してから切り詰める。
            if let fh = FileHandle(forReadingAtPath: path) {
                try? fh.seek(toOffset: UInt64(Swift.max(0, size - launchdLogKeepTailBytes)))
                if let tail = try? fh.readToEnd() {
                    // .atomic は一時ファイルから rename するので、.1 に置かれたリンクの先へは書かない。
                    try? tail.write(to: URL(fileURLWithPath: path + ".1"), options: [.atomic])
                }
                try? fh.close()
            }
            truncate(path, 0)
            WebSocketServer.wslog("launchd log truncated \(path) bytes=\(size)")
        }
    }
}

// MARK: - Menu bar (status item + popover + animated eyes glyph)

@MainActor
final class MenuBarController: NSObject {
    private let server: BridgeServer
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var timer: Timer?
    private var tick = 0

    init(server: BridgeServer) {
        self.server = server
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = EyesGlyph.image(blink: false)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "BuddyOS Bridge"
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: BridgeMenuView(server: server, onOpenDesktop: { [weak self] in self?.openDesktopApp() })
        )

        // 10Hz の単一タイマーで「まばたき（画像差し替え）」と「状態パルス（透明度）」を駆動。
        // メニューバー1個の更新なので 10Hz でも軽量。
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.animate() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private func animate() {
        guard let button = statusItem.button else { return }
        tick &+= 1

        // まばたき: 約4.5秒ごとに2tick(0.2s)だけ目を閉じる。
        let blinking = (tick % 45) < 2
        button.image = EyesGlyph.image(blink: blinking)

        // 状態パルス: 起動中/復旧中だけ透明度を 0.35↔1.0 で滑らかに脈動。
        let s = server.status
        let busy = s == "starting" || s == "recovering"
        if busy {
            let phase = Double(tick % 12) / 12.0
            button.alphaValue = 0.4 + 0.6 * (0.5 + 0.5 * cos(2 * Double.pi * phase))
        } else {
            button.alphaValue = 1.0
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// デスクトップ（Electron）アプリを前面に出す。インストール済みなら Launch Services
    /// 経由で bundle id から、開発時は自分の実行パスから親 .app を辿って開く。
    private func openDesktopApp() {
        let bundleId = BridgeConfig.current.idPrefix.value + ".superdos"
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
            return
        }
        // フォールバック: …/BuddyOS.app/Contents/Resources/bin/mac/BridgeApp から .app を辿る。
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            if dir.pathExtension == "app" {
                NSWorkspace.shared.openApplication(at: dir, configuration: cfg, completionHandler: nil)
                return
            }
            dir.deleteLastPathComponent()
        }
    }
}

// MARK: - Eyes glyph (template image for the menu bar)

enum EyesGlyph {
    /// BuddyOS の「目」を template NSImage で描く（メニューバーの明暗に自動追従）。
    /// blink=true で薄い横スリット（まばたき）にする。
    static func image(blink: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            let cx = rect.width / 2
            let cy = rect.height / 2
            let gap: CGFloat = 6.6              // 目の中心間距離
            let eyeW: CGFloat = 3.4
            let openH: CGFloat = 8.6
            let closedH: CGFloat = 1.8
            let w = blink ? eyeW + 0.6 : eyeW
            let h = blink ? closedH : openH
            for ex in [cx - gap / 2, cx + gap / 2] {
                let r = NSRect(x: ex - w / 2, y: cy - h / 2, width: w, height: h)
                NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: min(w / 2, h / 2)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Popover content

struct BridgeMenuView: View {
    @Bindable var server: BridgeServer
    var onOpenDesktop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            infoRow("Port", "\(server.port)")

            if let usage = server.usage, !usage.providers.isEmpty {
                Divider()
                usageSection(usage)
            }

            Divider()
            qrSection
            recentDevice
            accountRemovedSection

            Divider()
            actions
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: header / status

    private var header: some View {
        HStack(spacing: 8) {
            EyesBadge()
            Text("BuddyOS Bridge").font(.headline)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch server.status {
        case "running": return .green
        case "starting", "recovering": return .orange
        case "stopped": return .gray
        default: return server.status.hasPrefix("error") ? .red : .gray
        }
    }

    private var statusLabel: String {
        switch server.status {
        case "running": return "稼働中"
        case "starting": return "起動中"
        case "recovering": return "復旧中"
        case "stopped": return "停止"
        default: return server.status.hasPrefix("error") ? "エラー" : server.status
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).monospaced().lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: usage

    @ViewBuilder
    private func usageSection(_ usage: UsageReport) -> some View {
        Text("使用量").font(.caption).foregroundStyle(.secondary)
        ForEach(usage.providers, id: \.provider) { p in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(providerName(p)).font(.caption).frame(width: 96, alignment: .leading)
                    if p.error != nil || !p.hasData {
                        Text("—").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                    } else {
                        usageBadge("5h", p.fiveHour?.usedPercent)
                        usageBadge("週", p.sevenDay?.usedPercent)
                        Spacer()
                    }
                }
                if p.hasData, let reset = resetSummary(p) {
                    Text(reset).font(.system(size: 9)).foregroundStyle(.tertiary)
                        .padding(.leading, 104)
                }
            }
        }
    }

    /// "リセット 5h 19:01 · 週 10/10 22:54"（Mac のローカル時刻）。枠が無い・時刻が無いものは出さない。
    private func resetSummary(_ p: ProviderUsage) -> String? {
        var parts: [String] = []
        if let t = resetText(p.fiveHour?.resetsAt, withDate: false) { parts.append("5h \(t)") }
        if let t = resetText(p.sevenDay?.resetsAt, withDate: true) { parts.append("週 \(t)") }
        return parts.isEmpty ? nil : "リセット " + parts.joined(separator: " · ")
    }

    private func resetText(_ iso: String?, withDate: Bool) -> String? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = f.date(from: iso) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: iso) }() else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ja_JP")
        // 5 時間枠でも日をまたぐ場合は日付を付ける。
        let sameDay = Calendar.current.isDateInToday(date)
        out.dateFormat = (withDate || !sameDay) ? "M/d HH:mm" : "HH:mm"
        return out.string(from: date)
    }

    private func usageBadge(_ label: String, _ percent: Int?) -> some View {
        Group {
            if let v = percent {
                HStack(spacing: 3) {
                    Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("\(v)%").font(.system(size: 11, weight: .medium)).foregroundStyle(percentColor(v))
                }
            } else {
                EmptyView()
            }
        }
    }

    private func percentColor(_ v: Int) -> Color {
        if v >= 90 { return .red }
        if v >= 70 { return .orange }
        return .primary
    }

    private func providerName(_ p: ProviderUsage) -> String {
        switch p.provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case let id where id == "antigravity" || id.hasPrefix("antigravity:"): return "Antigravity · " + (p.label ?? "")
        default: return p.provider.capitalized
        }
    }

    // MARK: QR（10 分・1 回きりの招待）

    @ViewBuilder
    private var qrSection: some View {
        if let qr = server.pairingQR {
            Button {
                server.hidePairingQR()
            } label: {
                Label("QR を隠す", systemImage: "qrcode")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int((Double(qr.expiresAt) / 1000 - context.date.timeIntervalSince1970).rounded(.down)))
                VStack(spacing: 4) {
                    if remaining > 0 {
                        Image(nsImage: qr.image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 150, height: 150)
                        Text("この QR は 10 分間、1 回だけ使えます。")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("あと \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        if let used = PairingInvites.shared.invite(qr.inviteId)?.usedBy {
                            Text("この QR は「\(used.display)」で使われました（\(timeText(used.at))）。心当たりがなければ、BuddyOS の「つないでいる端末」から外してください。")
                                .font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("QR の期限が切れました").font(.caption).foregroundStyle(.secondary)
                        Button("新しい QR を出す") { server.showPairingQR() }
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
            }
        } else {
            Button {
                server.showPairingQR()
            } label: {
                Label("QR を表示（10 分間・1 回だけ）", systemImage: "qrcode")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    /// 「最近追加した端末: {表示名}（{時刻}）」。
    @ViewBuilder
    private var recentDevice: some View {
        if let added = DeviceStore.shared.lastAdded {
            Text("最近追加した端末: \(added.display)（\(timeText(added.at))）")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    /// アカウントから外された後の選択（すべて切断 / 端末はそのまま）。デスクトップが動いていなければメニューバーで選ぶ。
    @ViewBuilder
    private var accountRemovedSection: some View {
        if server.needsAccountRemovalChoice {
            VStack(alignment: .leading, spacing: 6) {
                Text("この PC はアカウントから外されました。つないでいる端末も切断しますか？ なくした・譲った PC でなければ、端末はそのままにできます。")
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("すべて切断") { server.disconnectAllAfterAccountRemoval() }
                    Spacer()
                    Button("端末はそのまま") { server.keepDevicesAfterAccountRemoval() }
                }
                .font(.caption)
            }
        }
    }

    private func timeText(_ ms: Int64) -> String {
        let out = DateFormatter()
        out.locale = Locale(identifier: "ja_JP")
        out.dateFormat = "M/d HH:mm"
        return out.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onOpenDesktop) {
                Label("BuddyOS を開く", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.borderless)

            HStack {
                Button(server.isRunning ? "停止" : "開始") {
                    Task { await server.toggle() }
                }
                Spacer()
                Button("終了") { NSApp.terminate(nil) }
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}

/// ポップオーバー見出しの小さな「目」ブランドマーク。
private struct EyesBadge: View {
    var body: some View {
        HStack(spacing: 3) {
            Capsule().frame(width: 4, height: 12)
            Capsule().frame(width: 4, height: 12)
        }
        .foregroundStyle(.primary)
    }
}
