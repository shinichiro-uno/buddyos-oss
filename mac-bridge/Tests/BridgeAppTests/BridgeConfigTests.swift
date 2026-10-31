import XCTest
@testable import BridgeApp

/// 外のサービスの設定の読み方（環境変数 → 配布物の既定 → 無し）。公開版の既定（空）でも落ちないこと。
final class BridgeConfigTests: XCTestCase {
    private let empty = BridgeConfig.Defaults.empty

    private var sample: BridgeConfig.Defaults {
        BridgeConfig.Defaults(
            edition: "official", convexSite: "https://registry.example.com", paseoRelayURL: "wss://relay.example.com/ws",
            pushMode: "auto", apnsKeyId: "KEYID00000", apnsTeamId: "TEAMID0000", apnsBundleId: "com.example.app",
            apnsKeyFile: "AuthKey_KEYID00000.p8", claudeUsage: "on", openRouterReferer: "https://example.com",
            idPrefix: "com.example"
        )
    }

    func testEmptyDefaultsTurnEverythingOff() {
        let c = BridgeConfig(env: [:], defaults: empty, home: "/home/u")
        XCTAssertNil(c.relayURL.value)
        XCTAssertEqual(c.relayURL.source, .none)
        XCTAssertNil(c.convexSite(accountConfig: { nil }).value)
        XCTAssertEqual(c.pushMode.value, .none)
        XCTAssertFalse(c.apns.isComplete)
        XCTAssertNil(c.apns.keyPath)
        XCTAssertFalse(c.claudeUsage.value)
        XCTAssertNil(c.openRouterReferer.value)
        XCTAssertEqual(c.idPrefix.value, "dev.buddyos.oss")
        XCTAssertEqual(c.launchAgentLabel, "dev.buddyos.oss.bridge")
    }

    func testDefaultsAreUsedWhenEnvIsEmpty() {
        let c = BridgeConfig(env: ["BUDDYOS_PASEO_RELAY_URL": "  "], defaults: sample, home: "/home/u")
        XCTAssertEqual(c.relayURL.value, "wss://relay.example.com/ws")
        XCTAssertEqual(c.relayURL.source, .default)
        XCTAssertEqual(c.convexSite(accountConfig: { nil }).value, "https://registry.example.com")
        XCTAssertEqual(c.pushMode.value, .auto)
        XCTAssertEqual(c.apns.keyPath, "/home/u/.buddyos/AuthKey_KEYID00000.p8")
        XCTAssertTrue(c.apns.isComplete)
        XCTAssertTrue(c.claudeUsage.value)
        XCTAssertEqual(c.openRouterReferer.value, "https://example.com")
        XCTAssertEqual(c.launchAgentLabel, "com.example.bridge")
    }

    func testEnvWins() {
        let env = [
            "BUDDYOS_PASEO_RELAY_URL": "wss://my-relay.example.net/ws",
            "BUDDYOS_CONVEX_SITE": "https://my-registry.example.net",
            "BUDDYOS_PUSH_MODE": "apns-direct",
            "APNS_KEY_PATH": "/keys/k.p8", "APNS_KEY_ID": "K", "APNS_TEAM_ID": "T", "APNS_BUNDLE_ID": "b.c",
            "BUDDYOS_CLAUDE_USAGE": "off",
            "BUDDYOS_OPENROUTER_REFERER": "https://mine.example.net",
            "BUDDYOS_ID_PREFIX": "net.example.mine",
        ]
        let c = BridgeConfig(env: env, defaults: sample)
        XCTAssertEqual(c.relayURL.value, "wss://my-relay.example.net/ws")
        XCTAssertEqual(c.relayURL.source, .env)
        let site = c.convexSite(accountConfig: { "https://from-file.example.net" })
        XCTAssertEqual(site.value, "https://my-registry.example.net")
        XCTAssertEqual(site.source, .env)
        XCTAssertEqual(c.pushMode.value, .apnsDirect)
        XCTAssertEqual(c.apns.keyPath, "/keys/k.p8")
        XCTAssertEqual(c.apns.teamId, "T")
        XCTAssertFalse(c.claudeUsage.value)
        XCTAssertEqual(c.openRouterReferer.value, "https://mine.example.net")
        XCTAssertEqual(c.idPrefix.value, "net.example.mine")
    }

    func testAccountConfigFileComesBeforeDefaults() {
        let c = BridgeConfig(env: [:], defaults: sample)
        let site = c.convexSite(accountConfig: { "https://from-file.example.net" })
        XCTAssertEqual(site.value, "https://from-file.example.net")
        XCTAssertEqual(site.source, .accountConfig)
        // 公開版でも account.config.json の値は使う。
        XCTAssertEqual(BridgeConfig(env: [:], defaults: empty).convexSite(accountConfig: { "https://f.example.net" }).value,
                       "https://f.example.net")
    }

    func testPushModeFallbacks() {
        // 中継の URL とトークンが揃っていれば convex（環境変数から）。
        let relay = BridgeConfig(env: ["BUDDYOS_PUSH_RELAY_URL": "https://p.example.net/v3/push",
                                       "BUDDYOS_PUSH_RELAY_TOKEN": "t"], defaults: empty)
        XCTAssertEqual(relay.pushMode.value, .convex)
        XCTAssertEqual(relay.pushMode.source, .env)
        // 読めない値は既定に戻し、ログに残す。
        let bogus = BridgeConfig(env: ["BUDDYOS_PUSH_MODE": "Carrier-Pigeon"], defaults: sample)
        XCTAssertEqual(bogus.pushMode.value, .auto)
        XCTAssertEqual(bogus.ignoredPushMode, "carrier-pigeon")
        XCTAssertTrue(bogus.describe(registry: .default).contains("ignored BUDDYOS_PUSH_MODE=carrier-pigeon"))
        // none は明示でも。
        XCTAssertEqual(BridgeConfig(env: ["BUDDYOS_PUSH_MODE": "NONE"], defaults: sample).pushMode.value, .none)
    }

    func testInvalidIdPrefixIsIgnored() {
        for bad in ["", "a..b", ".a", "a.", "a b", "a/b", "ä.b"] {
            XCTAssertFalse(BridgeConfig.isValidIdPrefix(bad), bad)
            XCTAssertEqual(BridgeConfig(env: ["BUDDYOS_ID_PREFIX": bad], defaults: sample).idPrefix.value, "com.example", bad)
        }
        XCTAssertTrue(BridgeConfig.isValidIdPrefix("dev.buddyos.oss"))
        XCTAssertTrue(BridgeConfig.isValidIdPrefix("my-org.app2"))
    }

    /// ログの 1 行に値を出さない（中継の URL だけ）。
    func testDescribeShowsSourcesNotValues() {
        let line = BridgeConfig(env: [:], defaults: sample).describe(registry: .default)
        XCTAssertTrue(line.hasPrefix("[config] edition=official "))
        XCTAssertTrue(line.contains("relay=default(wss://relay.example.com/ws)"))
        XCTAssertTrue(line.contains("registry=default"))
        XCTAssertTrue(line.contains("push=auto(default)"))
        XCTAssertTrue(line.contains("claudeUsage=on(default)"))
        XCTAssertFalse(line.contains("registry.example.com"))
        XCTAssertFalse(line.contains("KEYID"))
        XCTAssertFalse(line.contains("com.example"))
        let off = BridgeConfig(env: [:], defaults: empty).describe(registry: .none)
        XCTAssertTrue(off.contains("relay=none "))
        XCTAssertTrue(off.contains("push=none(default)"))
    }

    /// 配布物に入れた既定（OfficialDefaults）が、BridgeConfig にそのまま渡ること。
    func testBuiltInDefaultsMirrorOfficialDefaults() {
        let d = BridgeConfig.Defaults.builtIn
        XCTAssertEqual(d.paseoRelayURL, OfficialDefaults.paseoRelayURL)
        XCTAssertEqual(d.convexSite, OfficialDefaults.convexSite)
        XCTAssertEqual(d.idPrefix, OfficialDefaults.idPrefix)
        XCTAssertTrue(BridgeConfig.isValidIdPrefix(d.idPrefix))
        XCTAssertNotNil(BridgeConfig.PushMode(rawValue: d.pushMode))
    }
}
