import XCTest
@testable import BridgeApp

/// クライアントは agent id で分岐せず capabilities だけで UI を出し分ける。
/// その申告が adapter とサービス（cron / ログイン / 使用量）から正しく合流しているかを見る。
final class AgentCapabilitiesTests: XCTestCase {
    func testBridgeCronHostedGetsCronOptions() {
        let cursor = AgentRegistry.capabilities(of: HeadlessCliAdapter(profile: .cursor, executable: "/usr/bin/true"))
        XCTAssertTrue(cursor.cron)
        XCTAssertTrue(cursor.cronOptions)

        // hermes は CLI 側の cron なので、作業フォルダ・モードの指定は出さない。
        let hermes = AgentRegistry.capabilities(of: HermesAdapter())
        XCTAssertTrue(hermes.cron)
        XCTAssertFalse(hermes.cronOptions)
    }

    func testEffortsAndModesComeFromProfile() {
        let grok = AgentRegistry.capabilities(of: HeadlessCliAdapter(profile: .grok, executable: "/usr/bin/true"))
        XCTAssertEqual(grok.modes, ["plan", "edit", "auto", "dangerous"])
        XCTAssertEqual(grok.efforts, ["low", "medium", "high", "xhigh"], "grok の ACP の reasoning_effort と同じ")

        let cursor = AgentRegistry.capabilities(of: HeadlessCliAdapter(profile: .cursor, executable: "/usr/bin/true"))
        XCTAssertEqual(cursor.efforts, [])
        // ACP では編集の承認だけを Bridge が自動で許可するので edit がある。headless には無い。
        XCTAssertTrue(cursor.modes.contains("edit"))
        setenv("BUDDYOS_CURSOR_HEADLESS", "1", 1)
        defer { unsetenv("BUDDYOS_CURSOR_HEADLESS") }
        XCTAssertFalse(HeadlessCliProfile.cursor.modes.contains("edit"))

        let claude = AgentRegistry.capabilities(of: ClaudeCodeAdapter())
        XCTAssertTrue(claude.efforts.contains("ultracode"))
        XCTAssertTrue(claude.terminal)
    }

    func testLoginAndUsageFollowServices() {
        let claude = AgentRegistry.capabilities(of: ClaudeCodeAdapter())
        XCTAssertTrue(claude.login)
        // Claude の使用量は BUDDYOS_CLAUDE_USAGE（配布物の既定）に従う。
        XCTAssertEqual(claude.usage, BridgeConfig.current.claudeUsage.value)

        let antigravity = AgentRegistry.capabilities(of: HeadlessCliAdapter(profile: .antigravity, executable: "/usr/bin/true"))
        XCTAssertEqual(antigravity.login, AgentLoginService.supports("antigravity"))
        XCTAssertTrue(antigravity.usage)

        let hermes = AgentRegistry.capabilities(of: HermesAdapter())
        XCTAssertFalse(hermes.usage)
    }

    /// 古いクライアントが知らない項目は無視されるだけだが、新しいクライアントは
    /// 「空配列 = 持たない」と「欠けている = 古い Bridge」を見分ける。空でも必ず送る。
    func testEmptyListsAreEncoded() throws {
        let caps = AgentRegistry.capabilities(of: HermesAdapter())
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(caps)) as? [String: Any]
        XCTAssertEqual(json?["efforts"] as? [String], [])
        XCTAssertEqual(json?["modes"] as? [String], [])
    }
}

extension AgentCapabilitiesTests {
    /// MCP サーバは設定を書ける agent にだけ登録する。
    func testMcpRegisterOnlyForConfigOwners() {
        XCTAssertTrue(McpService.canRegister("claude"))
        XCTAssertTrue(McpService.canRegister("antigravity"))
        XCTAssertFalse(McpService.canRegister("openclaw"))
    }
}

final class GrokUsageTests: XCTestCase {
    func testParsesBilling() {
        let usage = UsageReader.parseGrokBilling([
            "config": ["creditUsagePercent": 3.4,
                       "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-13T02:16:02+00:00"]],
            "subscription_tier": "X Premium"
        ])
        XCTAssertEqual(usage?.sevenDay?.usedPercent, 3)
        XCTAssertEqual(usage?.sevenDay?.resetsAt, "2026-10-13T02:16:02+00:00")
        XCTAssertEqual(usage?.planType, "X Premium")
        XCTAssertTrue(usage?.hasData ?? false)
    }

    func testLiveBilling() async throws {
        guard ProcessInfo.processInfo.environment["BUDDYOS_LIVE_ACP"] == "grok" else { throw XCTSkip("live only") }
        let usage = await UsageReader.readGrokUsage()
        print("LIVE grok usage:", usage.map { "\($0.sevenDay?.usedPercent ?? -1)% \($0.planType ?? "")" })
        XCTAssertFalse(usage.isEmpty)
    }
}

final class GrokPresenceTests: XCTestCase {
    func testOnlyLiveTerminalSessions() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("active-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let me = ProcessInfo.processInfo.processIdentifier
        let json = """
        [{"session_id":"term","pid":\(me),"cwd":"/a"},{"session_id":"bridge","pid":\(me),"cwd":"/b"},{"session_id":"dead","pid":999999,"cwd":"/c"}]
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        var calls = 0
        let live = GrokPresence.liveSessionIds(path: path) { _ in
            calls += 1
            return calls == 1 ? "/Users/me/.grok/bin/grok" : "/Users/me/.grok/bin/grok agent stdio"
        }
        XCTAssertEqual(live, ["term"], "Bridge の ACP と終わったプロセスは除く")
    }
}
