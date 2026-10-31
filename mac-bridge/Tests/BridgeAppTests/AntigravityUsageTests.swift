import XCTest
@testable import BridgeApp

/// `agy -p "/usage"` の出力（実機 2026-10-04）を使用量に変換する。
final class AntigravityUsageTests: XCTestCase {
    private let sample = """
    Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-10T13:54:09Z
    Gemini Models\tFive Hour Limit Remaining\t60%\t2026-10-04T19:01:22Z
    Claude and GPT models\tWeekly Limit Remaining\t100%\t2026-10-11T14:01:22Z
    Claude and GPT models\tFive Hour Limit Remaining\t0%\t2026-10-04T19:01:22Z
    """

    func testParsesTwoPoolsAsUsedPercent() throws {
        let r = UsageReader.parseAntigravityUsage(sample)
        XCTAssertEqual(r.map(\.provider), ["antigravity", "antigravity:claude"])
        XCTAssertEqual(r[0].fiveHour?.usedPercent, 40, "残り 60% → 使用 40%")
        XCTAssertEqual(r[0].sevenDay?.usedPercent, 0)
        XCTAssertEqual(r[0].fiveHour?.windowMinutes, 300)
        XCTAssertEqual(r[0].sevenDay?.resetsAt, "2026-10-10T13:54:09Z")
        XCTAssertEqual(r[1].fiveHour?.usedPercent, 100, "残り 0% → 使用 100%")
        XCTAssertEqual(r[1].label, "Claude / GPT")
        XCTAssertTrue(r.allSatisfy(\.hasData))
    }

    /// モデル専用の枠（実機 2026-10-19）は「Gemini」と取り違えず、名前のまま別の枠にする。
    func testModelSpecificPoolKeepsItsName() {
        let r = UsageReader.parseAntigravityUsage(sample + "\nGemini 4 Argon\tGemini 4 Argon Weekly Limit\t99%\t2026-10-24T08:29:05Z")
        XCTAssertEqual(r.map(\.provider), ["antigravity", "antigravity:claude", "antigravity:gemini-4-argon"])
        XCTAssertEqual(r[2].label, "Gemini 4 Argon")
        XCTAssertEqual(r[2].sevenDay?.usedPercent, 1)
        XCTAssertNil(r[2].fiveHour)
    }

    func testGarbageYieldsNothing() {
        XCTAssertTrue(UsageReader.parseAntigravityUsage("Error: not logged in").isEmpty)
        XCTAssertTrue(UsageReader.parseAntigravityUsage("").isEmpty)
    }
}

/// Codex の `account/rateLimits/read`（実機 2026-10-07 の応答）を使用量に変換する。
final class CodexRateLimitsTests: XCTestCase {
    func testParsesWeeklyOnlyPlan() throws {
        let future = Date().addingTimeInterval(86_400 * 3).timeIntervalSince1970
        let result: [String: Any] = ["rateLimits": [
            "limitId": "codex", "planType": "prolite",
            "primary": ["usedPercent": 1, "windowDurationMins": 10080, "resetsAt": future],
            "secondary": NSNull(),
        ]]
        let u = try XCTUnwrap(UsageReader.parseCodexRateLimits(result))
        XCTAssertEqual(u.provider, "codex")
        XCTAssertNil(u.fiveHour, "週枠だけのプラン（primary が 10080 分）は週に振り分ける")
        XCTAssertEqual(u.sevenDay?.usedPercent, 1)
        XCTAssertNotNil(u.sevenDay?.resetsAt)
        XCTAssertEqual(u.planType, "prolite")
    }

    func testPassedResetBecomesZeroAndGarbageIsNil() {
        let past = Date().addingTimeInterval(-60).timeIntervalSince1970
        let u = UsageReader.parseCodexRateLimits(["rateLimits": ["primary": ["usedPercent": 53, "windowDurationMins": 10080, "resetsAt": past]]])
        XCTAssertEqual(u?.sevenDay?.usedPercent, 0)
        XCTAssertNil(UsageReader.parseCodexRateLimits(["foo": 1]))
        XCTAssertNil(UsageReader.parseCodexRateLimits(["rateLimits": ["primary": NSNull(), "secondary": NSNull()]]))
    }
}

final class CodexLiveUsageTests: XCTestCase {
    /// 実際の `codex app-server` に尋ねる。codex が無い・未ログインの環境ではスキップ。
    func testFetchesLiveRateLimits() throws {
        try XCTSkipIf(ExecutableFinder.locate("codex") == nil, "codex が無い")
        guard let u = UsageReader.fetchCodexRateLimits(timeout: 15) else { throw XCTSkip("取得できない（未ログイン等）") }
        XCTAssertEqual(u.provider, "codex")
        XCTAssertTrue(u.fiveHour != nil || u.sevenDay != nil)
        XCTAssertTrue((0...100).contains((u.sevenDay ?? u.fiveHour)!.usedPercent))
    }
}
