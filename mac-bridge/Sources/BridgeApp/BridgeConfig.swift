import Foundation

/// 外のサービス（中継・登録簿・通知）と、任意の機能の設定の読み方。
///
/// 読む順: 環境変数 → `OfficialDefaults`（配布物に入れた既定。公開版では空）→ 無し。
/// 値の無い機能は動かさないだけで、Bridge は止めない（中継が無ければトンネルを張らずに案内を出す、
/// 登録簿が無ければ QR だけで使う、通知の送り先が無ければ送らない）。
/// 起動時に出どころを 1 行だけログに出す（`describe()`。値は出さない。中継の URL だけは出す）。
/// Windows の Bridge（windows-bridge/src/settings.ts）と同じ名前・同じ形にしてある。
struct BridgeConfig: Sendable {
    enum Source: String, Sendable {
        case env
        case accountConfig = "account-config"
        case `default`
        case none
    }

    enum PushMode: String, Sendable, CaseIterable {
        /// APNs の鍵（.p8）があれば apns-direct、無ければ convex。
        case auto
        case none
        /// 登録簿の `/v3/push`（端末トークン `bdt_` で送る）。`BUDDYOS_PUSH_RELAY_URL` があればその中継。
        case convex
        /// `.p8` の JWT で APNs へ直接送る。
        case apnsDirect = "apns-direct"
    }

    struct Setting<Value: Sendable>: Sendable {
        let value: Value
        let source: Source
    }

    /// `OfficialDefaults` を値として持つ形（テストでは公開版の値を渡して確かめる）。
    struct Defaults: Sendable {
        var edition: String
        var convexSite: String
        var paseoRelayURL: String
        var pushMode: String
        var apnsKeyId: String
        var apnsTeamId: String
        var apnsBundleId: String
        var apnsKeyFile: String
        var claudeUsage: String
        var openRouterReferer: String
        var idPrefix: String

        static let builtIn = Defaults(
            edition: OfficialDefaults.edition,
            convexSite: OfficialDefaults.convexSite,
            paseoRelayURL: OfficialDefaults.paseoRelayURL,
            pushMode: OfficialDefaults.pushMode,
            apnsKeyId: OfficialDefaults.apnsKeyId,
            apnsTeamId: OfficialDefaults.apnsTeamId,
            apnsBundleId: OfficialDefaults.apnsBundleId,
            apnsKeyFile: OfficialDefaults.apnsKeyFile,
            claudeUsage: OfficialDefaults.claudeUsage,
            openRouterReferer: OfficialDefaults.openRouterReferer,
            idPrefix: OfficialDefaults.idPrefix
        )

        /// 公開版（空の版）と同じ値。
        static let empty = Defaults(
            edition: "oss", convexSite: "", paseoRelayURL: "", pushMode: "none",
            apnsKeyId: "", apnsTeamId: "", apnsBundleId: "", apnsKeyFile: "",
            claudeUsage: "off", openRouterReferer: "", idPrefix: "dev.buddyos.oss"
        )
    }

    /// apns-direct の設定。どれかが無ければ apns-direct は使わない。
    struct APNs: Sendable {
        let keyPath: String?
        let keyId: String?
        let teamId: String?
        let bundleId: String?

        var isComplete: Bool {
            [keyPath, keyId, teamId, bundleId].allSatisfy { $0?.isEmpty == false }
        }
    }

    /// 中継が無いときの案内（ログと `/health` の `relay.hint`。Windows と同じ文言）。
    static let relayHint = "No relay is configured. Set BUDDYOS_PASEO_RELAY_URL to your Paseo relay (for example wss://relay.example.com/ws) and restart the bridge."

    let edition: String
    let relayURL: Setting<String?>
    let pushMode: Setting<PushMode>
    /// 読めなかった `BUDDYOS_PUSH_MODE` の値（ログに出すだけ）。
    let ignoredPushMode: String?
    let apns: APNs
    let claudeUsage: Setting<Bool>
    let openRouterReferer: Setting<String?>
    let idPrefix: Setting<String>
    private let envConvexSite: String?
    private let defaultConvexSite: String?

    /// いまの環境変数と配布物の既定から作る（環境変数は動いている間に変わりうるので、呼ぶたびに読む）。
    static var current: BridgeConfig {
        BridgeConfig(env: ProcessInfo.processInfo.environment, defaults: .builtIn)
    }

    init(env: [String: String], defaults: Defaults, home: String = NSHomeDirectory()) {
        func trimmed(_ key: String) -> String? {
            let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? nil : v
        }
        func nonEmpty(_ s: String) -> String? {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }

        edition = defaults.edition

        if let v = trimmed("BUDDYOS_PASEO_RELAY_URL") {
            relayURL = Setting(value: v, source: .env)
        } else if let v = nonEmpty(defaults.paseoRelayURL) {
            relayURL = Setting(value: v, source: .default)
        } else {
            relayURL = Setting(value: nil, source: .none)
        }

        // BUDDYOS_PUSH_MODE → （BUDDYOS_PUSH_RELAY_URL と _TOKEN が両方あれば convex）→ 既定。
        let rawMode = trimmed("BUDDYOS_PUSH_MODE")?.lowercased()
        if let rawMode, let mode = PushMode(rawValue: rawMode) {
            pushMode = Setting(value: mode, source: .env)
            ignoredPushMode = nil
        } else {
            ignoredPushMode = rawMode.map { String($0.prefix(32)) }
            if trimmed("BUDDYOS_PUSH_RELAY_URL") != nil, trimmed("BUDDYOS_PUSH_RELAY_TOKEN") != nil {
                pushMode = Setting(value: .convex, source: .env)
            } else {
                pushMode = Setting(value: PushMode(rawValue: defaults.pushMode.lowercased()) ?? .none, source: .default)
            }
        }

        // APNs は「環境変数があればその値（空でも）」。以前の `env[...] ?? 既定` と同じ読み方。
        let keyFile = nonEmpty(defaults.apnsKeyFile)
        apns = APNs(
            keyPath: env["APNS_KEY_PATH"] ?? keyFile.map { (home as NSString).appendingPathComponent(".buddyos/\($0)") },
            keyId: env["APNS_KEY_ID"] ?? nonEmpty(defaults.apnsKeyId),
            teamId: env["APNS_TEAM_ID"] ?? nonEmpty(defaults.apnsTeamId),
            bundleId: env["APNS_BUNDLE_ID"] ?? nonEmpty(defaults.apnsBundleId)
        )

        switch trimmed("BUDDYOS_CLAUDE_USAGE")?.lowercased() {
        case "on", "1", "true": claudeUsage = Setting(value: true, source: .env)
        case "off", "0", "false": claudeUsage = Setting(value: false, source: .env)
        default: claudeUsage = Setting(value: defaults.claudeUsage.lowercased() == "on", source: .default)
        }

        if let v = trimmed("BUDDYOS_OPENROUTER_REFERER") {
            openRouterReferer = Setting(value: v, source: .env)
        } else if let v = nonEmpty(defaults.openRouterReferer) {
            openRouterReferer = Setting(value: v, source: .default)
        } else {
            openRouterReferer = Setting(value: nil, source: .none)
        }

        if let v = trimmed("BUDDYOS_ID_PREFIX"), Self.isValidIdPrefix(v) {
            idPrefix = Setting(value: v, source: .env)
        } else {
            idPrefix = Setting(value: defaults.idPrefix, source: .default)
        }

        envConvexSite = trimmed("BUDDYOS_CONVEX_SITE")
        defaultConvexSite = nonEmpty(defaults.convexSite)
    }

    /// 登録簿のサイト。`BUDDYOS_CONVEX_SITE` → `~/.buddyos/account.config.json` → 既定 → nil（登録しない。QR だけ）。
    /// account.config.json は desktop が後から書くことがあるので、呼ぶたびに読む。
    func convexSite(accountConfig: () -> String? = AccountConfigFile.convexSiteURL) -> Setting<String?> {
        if let envConvexSite { return Setting(value: envConvexSite, source: .env) }
        if let v = accountConfig() { return Setting(value: v, source: .accountConfig) }
        if let defaultConvexSite { return Setting(value: defaultConvexSite, source: .default) }
        return Setting(value: nil, source: .none)
    }

    /// LaunchAgent のラベル（`<頭>.bridge`）。
    var launchAgentLabel: String { idPrefix.value + ".bridge" }

    /// 逆 DNS の形（英数字とハイフンの区切りを `.` でつなぐ）。
    static func isValidIdPrefix(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 100 else { return false }
        return s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D
            }
        }
    }

    /// 起動時のログの 1 行。値は出さない（中継の URL だけは出す）。
    func describe(registry: Source? = nil) -> String {
        let registrySource = registry ?? convexSite().source
        var parts = [
            "edition=\(edition)",
            "relay=\(relayURL.source.rawValue)\(relayURL.value.map { "(\($0))" } ?? "")",
            "registry=\(registrySource.rawValue)",
            "push=\(pushMode.value.rawValue)(\(pushMode.source.rawValue))",
            "claudeUsage=\(claudeUsage.value ? "on" : "off")(\(claudeUsage.source.rawValue))",
            "openrouterReferer=\(openRouterReferer.source.rawValue)",
        ]
        if let ignoredPushMode { parts[3] += " ignored BUDDYOS_PUSH_MODE=\(ignoredPushMode)" }
        return "[config] " + parts.joined(separator: " ")
    }
}
