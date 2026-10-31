import XCTest
@testable import BridgeApp

final class BridgeCronScheduleTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    // MARK: - Interval parsing

    func testParseIntervalVariants() {
        XCTAssertEqual(BridgeCronSchedule.parse("every 30m"), .interval(1800))
        XCTAssertEqual(BridgeCronSchedule.parse("every 2h"), .interval(7200))
        XCTAssertEqual(BridgeCronSchedule.parse("30m"), .interval(1800))
        XCTAssertEqual(BridgeCronSchedule.parse("1d"), .interval(86400))
        XCTAssertEqual(BridgeCronSchedule.parse("every 1 h"), .interval(3600))
        // 60 秒未満は 60 秒に丸める
        XCTAssertEqual(BridgeCronSchedule.parse("10s"), .interval(60))
        // iOS preset で任意整数が来る (divisor 制約なし)
        XCTAssertEqual(BridgeCronSchedule.parse("every 90m"), .interval(5400))
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(BridgeCronSchedule.parse(""))
        XCTAssertNil(BridgeCronSchedule.parse("tomorrow"))
        XCTAssertNil(BridgeCronSchedule.parse("every banana"))
        XCTAssertNil(BridgeCronSchedule.parse("* * *"))          // フィールド不足
        XCTAssertNil(BridgeCronSchedule.parse("61 * * * *"))     // 範囲外
        XCTAssertNil(BridgeCronSchedule.parse("0 9 * * MON"))    // 名前エイリアス非対応
    }

    func testIntervalNext() {
        let schedule = BridgeCronSchedule.parse("every 30m")!
        let base = date(2026, 6, 12, 10, 0)
        XCTAssertEqual(schedule.next(after: base), base.addingTimeInterval(1800))
    }

    // MARK: - Cron parsing

    func testParseCronDaily9am() {
        guard case .cron(let expr)? = BridgeCronSchedule.parse("0 9 * * *") else {
            return XCTFail("should parse as cron")
        }
        XCTAssertEqual(expr.minutes, [0])
        XCTAssertEqual(expr.hours, [9])
        XCTAssertFalse(expr.dayRestricted)
        XCTAssertFalse(expr.weekdayRestricted)
    }

    func testCronNextSameDay() {
        let expr = CronExpression.parse("0 9 * * *")!
        // 8:30 → 当日 9:00
        XCTAssertEqual(expr.next(after: date(2026, 6, 12, 8, 30)), date(2026, 6, 12, 9, 0))
        // 9:00 ちょうど → 翌日 9:00 (after は排他)
        XCTAssertEqual(expr.next(after: date(2026, 6, 12, 9, 0)), date(2026, 6, 13, 9, 0))
    }

    func testCronWeekdays() {
        // 平日 9:00 (2026-06-12 は金曜)
        let expr = CronExpression.parse("0 9 * * 1-5")!
        // 金曜 10:00 → 月曜 9:00 (6/15)
        XCTAssertEqual(expr.next(after: date(2026, 6, 12, 10, 0)), date(2026, 6, 15, 9, 0))
    }

    func testCronSundayAsZeroAndSeven() {
        let zero = CronExpression.parse("0 9 * * 0")!
        let seven = CronExpression.parse("0 9 * * 7")!
        let after = date(2026, 6, 12, 10, 0)   // 金曜
        let expected = date(2026, 6, 14, 9, 0) // 日曜
        XCTAssertEqual(zero.next(after: after), expected)
        XCTAssertEqual(seven.next(after: after), expected)
    }

    func testCronStep() {
        let expr = CronExpression.parse("*/15 * * * *")!
        XCTAssertEqual(expr.next(after: date(2026, 6, 12, 10, 0)), date(2026, 6, 12, 10, 15))
        XCTAssertEqual(expr.next(after: date(2026, 6, 12, 10, 50)), date(2026, 6, 12, 11, 0))
    }

    func testCronCommaList() {
        let expr = CronExpression.parse("0 9 * * 1,3,5")!
        // 金曜 (6/12) 10:00 → 月曜 (6/15) 9:00
        XCTAssertEqual(expr.next(after: date(2026, 6, 12, 10, 0)), date(2026, 6, 15, 9, 0))
    }

    func testCronSpecificDate() {
        let expr = CronExpression.parse("30 14 15 3 *")!
        XCTAssertEqual(expr.next(after: date(2026, 6, 12, 0, 0)), date(2027, 3, 15, 14, 30))
    }

    /// vixie 互換: day-of-month と day-of-week が両方制約されている場合は OR。
    func testCronVixieDayOrWeekday() {
        let expr = CronExpression.parse("0 9 13 * 1")!
        // 金曜 6/12 10:00 → 6/13 (土, day=13 一致) が月曜 6/15 より先
        XCTAssertEqual(expr.next(after: date(2026, 6, 12, 10, 0)), date(2026, 6, 13, 9, 0))
    }

    // MARK: - Jitter

    func testJitterDeterministicAndBounded() {
        let schedule = BridgeCronSchedule.parse("0 9 * * *")!
        let a = BridgeCronScheduler.jitter(jobId: "abcd1234", schedule: schedule)
        let b = BridgeCronScheduler.jitter(jobId: "abcd1234", schedule: schedule)
        XCTAssertEqual(a, b, "同じ jobId は常に同じオフセット")
        XCTAssertGreaterThanOrEqual(a, 0)
        XCTAssertLessThan(a, 90)
    }

    func testJitterScalesWithShortInterval() {
        // 2 分間隔 → 上限は interval/10 = 12 秒
        let schedule = BridgeCronSchedule.parse("every 2m")!
        for id in ["a", "bb", "ccc", "dddd", "ffffffff"] {
            let j = BridgeCronScheduler.jitter(jobId: id, schedule: schedule)
            XCTAssertLessThan(j, 12)
        }
    }

    // MARK: - Job persistence roundtrip

    func testJobCodableRoundtrip() throws {
        let job = BridgeCronJob(
            id: "a1b2c3d4",
            agentId: "claude",
            name: "daily-review",
            prompt: "review the repo",
            schedule: "0 9 * * 1-5",
            cwd: "/tmp/project",
            permissionMode: "edit",
            deliver: "local",
            enabled: true,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            lastRunAt: nil,
            lastStatus: nil,
            repeatCount: 3,
            runsCompleted: 0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode([job])
        let decoded = try decoder.decode([BridgeCronJob].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, job.id)
        XCTAssertEqual(decoded[0].schedule, job.schedule)
        XCTAssertEqual(decoded[0].permissionMode, "edit")
        XCTAssertEqual(decoded[0].repeatCount, 3)
        XCTAssertNotNil(decoded[0].parsedSchedule)
    }
}

final class BridgeCronLastSessionTests: XCTestCase {
    func testReadsSessionFromNewestOutput() throws {
        let root = NSTemporaryDirectory() + "cron-out-\(UUID().uuidString)"
        let dir = root + "/abcd1234"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "# a\nagent: claude\nstatus: ok\nsession: old-1\n---\nx\n".write(toFile: dir + "/2026-10-19_08-00-00.md", atomically: true, encoding: .utf8)
        try "# a\nagent: claude\nstatus: ok\nsession: new-2\n---\nx\n".write(toFile: dir + "/2026-10-20_08-00-00.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(BridgeCronScheduler.latestOutputSessionId(jobId: "abcd1234", root: root), "new-2")
        XCTAssertNil(BridgeCronScheduler.latestOutputSessionId(jobId: "missing", root: root))
    }
}
