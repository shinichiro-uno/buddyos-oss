import XCTest
@testable import BridgeApp

// claude --bg の台帳の読み取りと状態の導出（docs/BACKGROUND_CONTROL_2026-10-21.md §7.1〜§7.3）。
// shared/fixtures/background-control/claude-bg の例を、一時フォルダの ~/.claude に並べて読む。

/// 一時フォルダの ~/.claude（sessions / jobs / daemon）。
final class BgHome {
    let root: URL
    var claude: URL { root.appendingPathComponent(".claude") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bg-home-\(UUID().uuidString)")
        for sub in ["sessions", "jobs", "daemon"] {
            try FileManager.default.createDirectory(at: claude.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
    }

    func session(_ pid: Int, _ json: String) throws {
        try json.write(to: claude.appendingPathComponent("sessions/\(pid).json"), atomically: true, encoding: .utf8)
    }

    func job(_ id: String, _ json: String) throws {
        let dir = claude.appendingPathComponent("jobs/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }

    func removeJob(_ id: String) throws {
        try FileManager.default.removeItem(at: claude.appendingPathComponent("jobs/\(id)"))
    }

    func roster(_ ids: [String]) throws {
        let workers = ids.map { "\"\($0)\": {\"pid\": 1, \"rvAuth\": \"secret\"}" }.joined(separator: ",")
        try "{\"proto\": 1, \"workers\": {\(workers)}}".write(to: claude.appendingPathComponent("daemon/roster.json"),
                                                              atomically: true, encoding: .utf8)
    }
}

enum BgFixtures {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/fixtures/background-control/claude-bg")

    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func json(_ any: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: any), as: UTF8.self)
    }

    /// 例を取り出し、項目を上書きした JSON にする。
    static func variant(_ dict: [String: Any], _ key: String, _ patch: [String: Any?] = [:]) throws -> String {
        var o = try XCTUnwrap(dict[key] as? [String: Any])
        for (k, v) in patch { if let v { o[k] = v } else { o.removeValue(forKey: k) } }
        return try json(o)
    }

    static func iso(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

final class ClaudeAgentsRegistryTests: XCTestCase {
    private var files: [String: Any]!
    private var home: BgHome!
    /// 例の job_state_* の createdAt の少し後（blocked の例は 2026-10-21T11:32:56Z）。
    private let nowMs: Int64 = 1_792_582_500_000

    override func setUpWithError() throws {
        files = try BgFixtures.load("examples-registry-files.json")
        home = try BgHome()
    }

    private func entries(alive: @escaping (Int32, String?) -> Bool = { _, _ in true },
                         nowMs: Int64? = nil) -> [String: BgEntry] {
        let snapshot = ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: alive)
        let all = ClaudeAgentsRegistry.ledgerEntries(snapshot, nowMs: nowMs ?? self.nowMs, buddyTitle: { _ in nil })
        return Dictionary(uniqueKeysWithValues: all.map { ($0.row.id, $0) })
    }

    /// 例の sessions を pid と状態を変えて置く。
    private func liveSession(pid: Int, jobId: String?, sessionId: String, status: String, kind: String = "bg",
                             extra: [String: Any?] = [:]) throws {
        var patch: [String: Any?] = ["pid": pid, "sessionId": sessionId, "status": status, "kind": kind, "jobId": jobId]
        patch.merge(extra) { _, new in new }
        try home.session(pid, try BgFixtures.variant(files, "sessions_bg_busy", patch))
    }

    // MARK: - 寛容な読み方

    func testTolerantParseKeepsFirstObjectAndDropsTrailingGarbage() throws {
        let text = "{\"pid\": 7, \"name\": \"a } b { c\", \"inner\": {\"x\": 1}}\n}\n"
        let parsed = try XCTUnwrap(ClaudeAgentsRegistry.parseTolerantObject(Data(text.utf8)))
        XCTAssertEqual(parsed["pid"] as? Int, 7)
        XCTAssertEqual(parsed["name"] as? String, "a } b { c")
        XCTAssertNil(ClaudeAgentsRegistry.parseTolerantObject(Data("{\"a\": 1".utf8)))
        XCTAssertNil(ClaudeAgentsRegistry.parseTolerantObject(Data("garbage".utf8)))
    }

    func testSessionFileWithExtraClosingBraceIsStillRead() throws {
        let broken = try BgFixtures.variant(files, "sessions_bg_busy", ["pid": 4242]) + "}\n"
        try home.session(4242, broken)
        let snapshot = ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: { _, _ in true })
        XCTAssertEqual(snapshot.sessions.map(\.pid), [4242])
        XCTAssertEqual(snapshot.sessions.first?.jobId, "dceba663")
        XCTAssertEqual(snapshot.sessions.first?.inbox, "/tmp/cc-socks/31875.sock")
    }

    func testOnlyNumericJsonSessionFilesAndJobDirectoriesAreOpened() throws {
        try home.session(100, try BgFixtures.variant(files, "sessions_bg_busy", ["pid": 100]))
        try "{\"pid\": 101}".write(to: home.claude.appendingPathComponent("sessions/101.key"), atomically: true, encoding: .utf8)
        try "{\"pid\": 102}".write(to: home.claude.appendingPathComponent("sessions/notes.json"), atomically: true, encoding: .utf8)
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done"))
        try home.job("not-a-job", try BgFixtures.variant(files, "job_state_done"))
        try home.job("DCEBA663", try BgFixtures.variant(files, "job_state_done"))
        try "{}".write(to: home.claude.appendingPathComponent("jobs/pins.json"), atomically: true, encoding: .utf8)
        let snapshot = ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: { _, _ in true })
        XCTAssertEqual(snapshot.sessions.map(\.pid), [100])
        XCTAssertEqual(Array(snapshot.jobs.keys), ["dceba663"])
    }

    func testRosterReadsOnlyWorkerKeys() throws {
        try home.roster(["dceba663", "bb74b880"])
        let snapshot = ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: { _, _ in true })
        XCTAssertEqual(snapshot.roster, ["dceba663", "bb74b880"])
    }

    // MARK: - 生きているか

    func testProcStartFormatPadsSingleDigitDayWithSpace() {
        // 2026-10-05 07:08:09 UTC は月曜日。
        let seconds = Int(ISO8601DateFormatter().date(from: "2026-10-05T07:08:09Z")!.timeIntervalSince1970)
        let text = ClaudeAgentsRegistry.formatProcStart(seconds: seconds)
        XCTAssertEqual(text, "Mon Oct  5 07:08:09 2026")
        XCTAssertEqual(ClaudeAgentsRegistry.collapsingSpaces(text), "Mon Oct 5 07:08:09 2026")
        let two = Int(ISO8601DateFormatter().date(from: "2026-10-21T11:26:43Z")!.timeIntervalSince1970)
        XCTAssertEqual(ClaudeAgentsRegistry.formatProcStart(seconds: two), "Wed Oct 21 11:26:43 2026")
    }

    func testAliveNeedsMatchingProcStartAndCollapsesSpaces() throws {
        let pid = getpid()
        let actual = try XCTUnwrap(ClaudeAgentsRegistry.processStartString(pid: pid))
        XCTAssertTrue(ClaudeAgentsRegistry.isProcessAlive(pid: pid, procStart: actual))
        XCTAssertTrue(ClaudeAgentsRegistry.isProcessAlive(pid: pid, procStart: ClaudeAgentsRegistry.collapsingSpaces(actual)))
        XCTAssertTrue(ClaudeAgentsRegistry.isProcessAlive(pid: pid, procStart: nil))
        XCTAssertFalse(ClaudeAgentsRegistry.isProcessAlive(pid: pid, procStart: "Thu Jan  1 00:00:00 1970"))
        XCTAssertFalse(ClaudeAgentsRegistry.isProcessAlive(pid: 99_999_999, procStart: nil))
    }

    func testEpermIsNotAlive() throws {
        try XCTSkipIf(geteuid() == 0, "root では EPERM にならない")
        XCTAssertFalse(ClaudeAgentsRegistry.isProcessAlive(pid: 1, procStart: nil))
    }

    func testLookupProcessReadsBrokenFileAndPicksNewest() throws {
        let sid = "11111111-2222-3333-4444-555555555555"
        let pid = Int(getpid())
        let actual = try XCTUnwrap(ClaudeAgentsRegistry.processStartString(pid: getpid()))
        try home.session(pid, try BgFixtures.variant(files, "sessions_bg_busy",
                                                     ["pid": pid, "sessionId": sid, "procStart": actual, "startedAt": 100]) + "}")
        try home.session(pid + 1, try BgFixtures.variant(files, "sessions_bg_busy",
                                                         ["pid": pid + 1, "sessionId": sid, "startedAt": 200]))
        let found = ClaudeAgentsRegistry.lookupProcess(sessionId: sid, home: home.root, isAlive: { p, _ in Int(p) == pid })
        XCTAssertEqual(found?.pid, getpid())
        XCTAssertEqual(found?.inboxSocket, "/tmp/cc-socks/31875.sock")
        XCTAssertNil(ClaudeAgentsRegistry.lookupProcess(sessionId: "other", home: home.root, isAlive: { _, _ in true }))
    }

    // MARK: - 状態の導出（§7.2）

    func testBusyWorkerIsWorkingAndShellCountsAsWorkingToo() throws {
        let sid = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_working_with_inflight_task",
                                                        ["sessionId": sid, "createdAt": BgFixtures.iso(nowMs - 60_000)]))
        try liveSession(pid: 500, jobId: "dceba663", sessionId: sid, status: "busy")
        var e = try XCTUnwrap(entries()["dceba663"])
        XCTAssertEqual(e.row.state, .working)
        XCTAssertTrue(e.row.live)
        XCTAssertEqual(e.row.shells, 1)
        XCTAssertEqual(e.workerStatus, "busy")
        XCTAssertEqual(e.pid, 500)

        try liveSession(pid: 500, jobId: "dceba663", sessionId: sid, status: "shell")
        e = try XCTUnwrap(entries()["dceba663"])
        XCTAssertEqual(e.row.state, .working)
        XCTAssertEqual(e.workerStatus, "shell")
    }

    func testWaitingAndQuestionWaitingAreBlocked() throws {
        let sid = "bb74b880-d7c9-4099-9378-fbbbe9b9bed5"
        try home.job("bb74b880", try BgFixtures.variant(files, "job_state_blocked"))
        try liveSession(pid: 501, jobId: "bb74b880", sessionId: sid, status: "waiting")
        var e = try XCTUnwrap(entries(nowMs: 1_792_582_380_000)["bb74b880"])
        XCTAssertEqual(e.row.state, .blocked)
        XCTAssertEqual(e.row.needs, "approve Write: /tmp/fixture/claude-bg-sessions/cwd/bgB/hello.txt")
        XCTAssertNil(e.row.detail)

        // 質問待ち: ワーカーは idle で、state が blocked。
        try home.job("bb74b880", try BgFixtures.variant(files, "job_state_blocked", ["state": "blocked", "tempo": "blocked"]))
        try liveSession(pid: 501, jobId: "bb74b880", sessionId: sid, status: "idle")
        e = try XCTUnwrap(entries(nowMs: 1_792_582_380_000)["bb74b880"])
        XCTAssertEqual(e.row.state, .blocked)
        XCTAssertEqual(e.workerStatus, "idle")
    }

    func testDoneWithActiveTempoAndBusyWorkerIsWorking() throws {
        let sid = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["tempo": "active"]))
        try liveSession(pid: 502, jobId: "dceba663", sessionId: sid, status: "busy")
        var e = try XCTUnwrap(entries()["dceba663"])
        XCTAssertEqual(e.row.state, .working)
        // 終わっていて、tempo が active でなければ done。ワーカーが idle でも live のまま。
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done"))
        try liveSession(pid: 502, jobId: "dceba663", sessionId: sid, status: "idle", extra: ["name": nil])
        e = try XCTUnwrap(entries()["dceba663"])
        XCTAssertEqual(e.row.state, .done)
        XCTAssertTrue(e.row.live)
        XCTAssertEqual(e.row.title, "count 1-5 with sleep")
    }

    func testStoppedAndFailedBeforeInit() throws {
        try home.job("bb74b880", try BgFixtures.variant(files, "job_state_stopped"))
        try home.job("26107a74", try BgFixtures.variant(files, "job_state_failed_before_init"))
        let all = entries(nowMs: 1_792_583_000_000)
        XCTAssertEqual(all["bb74b880"]?.row.state, .stopped)
        XCTAssertEqual(all["bb74b880"]?.row.live, false)
        XCTAssertNil(all["bb74b880"]?.row.needs)
        let failed = try XCTUnwrap(all["26107a74"])
        XCTAssertEqual(failed.row.state, .failed)
        XCTAssertTrue(try XCTUnwrap(failed.row.detail).hasPrefix("exit 1 before init"))
        XCTAssertLessThanOrEqual(try XCTUnwrap(failed.row.detail).count, 200)
        XCTAssertTrue(failed.firstTerminal)
    }

    func testOrphanJobIsReadAsFailedAfterFiveSeconds() throws {
        let created = nowMs - 6000
        let orphan = ["state": "working", "tempo": "active", "createdAt": BgFixtures.iso(created)] as [String: Any?]
        try home.job("45221487", try BgFixtures.variant(files, "job_state_working_with_inflight_task", orphan))
        // roster に無く、生きている sessions も無く、5 秒以上たっている → failed
        XCTAssertEqual(entries()["45221487"]?.row.state, .failed)
        // 5 秒に満たなければ待つ
        XCTAssertEqual(entries(nowMs: created + 4000)["45221487"]?.row.state, .working)
        // roster にあれば孤児ではない
        try home.roster(["45221487"])
        XCTAssertEqual(entries()["45221487"]?.row.state, .working)
    }

    func testOrphanBlockedStaysBlockedAndKeptEmptyJobIsNotRewritten() throws {
        try home.job("bb74b880", try BgFixtures.variant(files, "job_state_blocked", ["state": "blocked"]))
        XCTAssertEqual(entries()["bb74b880"]?.row.state, .blocked)

        try home.job("cc000000", try BgFixtures.variant(files, "job_state_blocked", [
            "keptBy": "x", "intent": "", "needs": "send a prompt to start", "tempo": "blocked", "sessionId": "cc000000-0000-0000-0000-000000000000"]))
        let kept = try XCTUnwrap(entries()["cc000000"])
        XCTAssertEqual(kept.row.state, .blocked)
        XCTAssertEqual(kept.row.needs, "send a prompt to start")
    }

    func testRecurringDoneWaitsAndIsNotFinished() throws {
        let sid = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["intent": "/loop 5m check the build"]))
        try liveSession(pid: 503, jobId: "dceba663", sessionId: sid, status: "idle")
        let waiting = try XCTUnwrap(entries()["dceba663"])
        XCTAssertEqual(waiting.row.state, .working)
        XCTAssertTrue(waiting.recurringWait)
        XCTAssertFalse(ClaudeBackgroundJobs.isRunning(waiting))

        // ほかの印でも繰り返しになる
        for patch in [["selfWake": true], ["routine": ["every": "5m"]], ["inFlight": ["tasks": 0, "kinds": ["session_cron"]]]] as [[String: Any]] {
            try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", patch.mapValues { $0 as Any? }))
            XCTAssertTrue(entries()["dceba663"]?.recurringWait == true, "\(patch)")
        }

        // 動いている間は繰り返しの待ちではない
        try liveSession(pid: 503, jobId: "dceba663", sessionId: sid, status: "busy")
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["intent": "/loop 5m check the build"]))
        let busy = try XCTUnwrap(entries()["dceba663"])
        XCTAssertEqual(busy.row.state, .working)
        XCTAssertFalse(busy.recurringWait)
    }

    func testShellsCountFanShellsOtherwiseLocalBashTasks() throws {
        let sid = "45221487-9c4c-4592-83bd-5b2006e65854"
        try home.job("45221487", try BgFixtures.variant(files, "job_state_working_with_inflight_task",
                                                        ["createdAt": BgFixtures.iso(nowMs - 60_000)]))
        try home.roster(["45221487"])
        try liveSession(pid: 504, jobId: "45221487", sessionId: sid, status: "shell")
        XCTAssertEqual(entries()["45221487"]?.row.shells, 1)
        try home.job("45221487", try BgFixtures.variant(files, "job_state_working_with_inflight_task", [
            "createdAt": BgFixtures.iso(nowMs - 60_000), "fan": nil, "inFlight": ["tasks": 3, "kinds": ["local_bash"]]]))
        XCTAssertEqual(entries()["45221487"]?.row.shells, 3)
        try home.job("45221487", try BgFixtures.variant(files, "job_state_working_with_inflight_task", [
            "createdAt": BgFixtures.iso(nowMs - 60_000), "fan": [["kind": "agent"], ["kind": "shell"], ["kind": "shell"]]]))
        XCTAssertEqual(entries()["45221487"]?.row.shells, 2)
        // 生きていなければ数えない
        try FileManager.default.removeItem(at: home.claude.appendingPathComponent("sessions/504.json"))
        XCTAssertEqual(entries()["45221487"]?.row.shells, 0)
    }

    func testInteractiveBgWithoutJobIdAndParkedRowsAreNotListed() throws {
        let sid = "416ae8b3-ea15-4e7d-b0ad-ee33006b5d2d"
        try home.session(600, try BgFixtures.variant(files, "sessions_dash_p_sdk_cli_busy", ["pid": 600]))
        try liveSession(pid: 601, jobId: nil, sessionId: "aaaaaaaa-0000-0000-0000-000000000000", status: "busy")
        try liveSession(pid: 602, jobId: "dceba663", sessionId: sid, status: "busy", extra: ["parkedJobId": "dceba663"])
        let snapshot = ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: { _, _ in true })
        XCTAssertEqual(snapshot.sessions.count, 3)
        XCTAssertTrue(ClaudeAgentsRegistry.ledgerEntries(snapshot, nowMs: nowMs, buddyTitle: { _ in nil }).isEmpty)
        // 駐車中の行があっても、ジョブの記録があれば live にはならない
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["sessionId": sid]))
        let e = try XCTUnwrap(entries()["dceba663"])
        XCTAssertFalse(e.row.live)
    }

    func testDeadSessionFileDoesNotMakeJobLive() throws {
        let sid = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done"))
        try liveSession(pid: 505, jobId: "dceba663", sessionId: sid, status: "busy")
        let e = try XCTUnwrap(entries(alive: { _, _ in false })["dceba663"])
        XCTAssertFalse(e.row.live)
        XCTAssertNil(e.workerStatus)
        XCTAssertNil(e.inbox)
        XCTAssertEqual(e.row.state, .done)
    }

    func testTitlePriorityAndLength() throws {
        let sid = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["name": nil]))
        try liveSession(pid: 506, jobId: "dceba663", sessionId: sid, status: "idle", extra: ["name": "session name"])
        let snapshot = ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: { _, _ in true })
        func title(_ buddy: String?) -> String {
            ClaudeAgentsRegistry.ledgerEntries(snapshot, nowMs: nowMs, buddyTitle: { _ in buddy }).first?.row.title ?? "?"
        }
        XCTAssertEqual(title("BuddyOS で付けた名前"), "BuddyOS で付けた名前")
        XCTAssertEqual(title(nil), "session name")
        try FileManager.default.removeItem(at: home.claude.appendingPathComponent("sessions/506.json"))
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["name": nil, "intent": String(repeating: "あ", count: 200) + "\n2 行目"]))
        let long = ClaudeAgentsRegistry.ledgerEntries(ClaudeAgentsRegistry.readSnapshot(home: home.root), nowMs: nowMs, buddyTitle: { _ in nil })
        XCTAssertEqual(long.first?.row.title.count, 80)
    }

    // MARK: - 一覧に出す行（§7.3）

    private func entry(_ id: String, _ state: BgState, createdAtMs: Int64, live: Bool = false, endedAtMs: Int64? = nil) -> BgEntry {
        BgEntry(row: BgRow(id: id, sessionId: id + "-x", title: "", cwd: "", state: state, live: live, needs: nil, detail: nil,
                           shells: 0, createdAtMs: createdAtMs),
                endedAtMs: endedAtMs)
    }

    func testListedKeepsLiveAndActiveAndRecentlyEndedOnly() {
        let now: Int64 = 10_000_000_000
        let day: Int64 = 24 * 3600 * 1000
        let all = [
            entry("aaaaaaa1", .done, createdAtMs: 1, live: true, endedAtMs: now - 5 * day),
            entry("aaaaaaa2", .stopped, createdAtMs: 2, endedAtMs: now - day - 1),
            entry("aaaaaaa3", .failed, createdAtMs: 3, endedAtMs: now - day + 1000),
            entry("aaaaaaa4", .working, createdAtMs: 4),
            entry("aaaaaaa5", .done, createdAtMs: 5)
        ]
        let ids = Set(ClaudeAgentsRegistry.selectListed(all, nowMs: now).map(\.row.id))
        XCTAssertEqual(ids, Set(["aaaaaaa1", "aaaaaaa3", "aaaaaaa4"]))
    }

    func testOrderBlockedThenWorkingThenOthersNewestFirstAndCappedAtFifty() {
        let now: Int64 = 10_000_000_000
        let all = [
            entry("aaaaaaa1", .done, createdAtMs: 900, endedAtMs: now),
            entry("aaaaaaa2", .working, createdAtMs: 100),
            entry("aaaaaaa3", .blocked, createdAtMs: 50),
            entry("aaaaaaa4", .working, createdAtMs: 200),
            entry("aaaaaaa5", .failed, createdAtMs: 950, endedAtMs: now),
            entry("aaaaaaa6", .blocked, createdAtMs: 60)
        ]
        XCTAssertEqual(ClaudeAgentsRegistry.selectListed(all, nowMs: now).map(\.row.id),
                       ["aaaaaaa6", "aaaaaaa3", "aaaaaaa4", "aaaaaaa2", "aaaaaaa5", "aaaaaaa1"])
        let many = (0..<80).map { entry(String(format: "%08x", $0), .working, createdAtMs: Int64($0)) }
        let listed = ClaudeAgentsRegistry.selectListed(many, nowMs: now)
        XCTAssertEqual(listed.count, 50)
        XCTAssertEqual(listed.first?.row.createdAtMs, 79)
    }

    func testRowJsonOmitsEmptyOptionalsAndNeverCarriesPidOrSecrets() throws {
        let sid = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done"))
        try liveSession(pid: 507, jobId: "dceba663", sessionId: sid, status: "idle")
        let json = try XCTUnwrap(entries()["dceba663"]).row.json
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(o.keys), ["id", "sessionId", "title", "cwd", "state", "live", "shells", "createdAtMs"])
        XCTAssertEqual(o["state"] as? String, "done")
        XCTAssertEqual(o["createdAtMs"] as? Int64, 1_792_581_981_328)
        XCTAssertFalse(json.contains("\\/"))
        let removed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(BgRow.removedJSON(id: "dceba663", sessionId: sid).utf8)) as? [String: Any])
        XCTAssertEqual(removed["removed"] as? Bool, true)
        XCTAssertEqual(Set(removed.keys), ["id", "sessionId", "removed"])
    }

    // MARK: - CLI の出力との一致（§7.5）

    private func cliRows(_ keys: [String]) throws -> [BgCliRow] {
        let cli = try BgFixtures.load("examples-agents-json.json")
        let array = try keys.map { try XCTUnwrap(cli[$0]) }
        return try XCTUnwrap(ClaudeAgentsRegistry.parseAgentsJSON(try BgFixtures.json(array)))
    }

    func testParseAgentsJsonKeepsOnlyBackgroundRowsAndRejectsNonArrays() throws {
        let cli = try BgFixtures.load("examples-agents-json.json")
        let rows = try XCTUnwrap(ClaudeAgentsRegistry.parseAgentsJSON(try BgFixtures.json(Array(cli.values))))
        XCTAssertEqual(rows.count, 6)
        XCTAssertFalse(rows.contains { $0.id.isEmpty })
        XCTAssertNil(ClaudeAgentsRegistry.parseAgentsJSON("{\"a\": 1}"))
        XCTAssertNil(ClaudeAgentsRegistry.parseAgentsJSON("not json"))
        XCTAssertEqual(ClaudeAgentsRegistry.parseAgentsJSON("warning\n[]\n")?.count, 0)
    }

    func testLedgerMatchesCliOutput() throws {
        let busySid = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
        let waitSid = "bb74b880-d7c9-4099-9378-fbbbe9b9bed5"
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_working_with_inflight_task", [
            "sessionId": busySid, "createdAt": BgFixtures.iso(nowMs - 60_000)]))
        try home.job("bb74b880", try BgFixtures.variant(files, "job_state_blocked"))
        try home.job("26107a74", try BgFixtures.variant(files, "job_state_failed_before_init"))
        try home.job("28f38cc2", try BgFixtures.variant(files, "job_state_failed_before_init", [
            "sessionId": "28f38cc2-b707-41f4-9ac0-6d57cf5684f1"]))
        try home.roster(["dceba663", "bb74b880"])
        try liveSession(pid: 700, jobId: "dceba663", sessionId: busySid, status: "busy")
        try liveSession(pid: 701, jobId: "bb74b880", sessionId: waitSid, status: "waiting")

        let snapshot = ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: { _, _ in true })
        let ledger = ClaudeAgentsRegistry.ledgerEntries(snapshot, nowMs: 1_792_582_380_000, buddyTitle: { _ in nil })
        let rows = try cliRows(["background_live_busy", "background_live_waiting_permission",
                                "background_failed_before_init_with_all", "background_orphan_failed_old_job_with_all"])
        XCTAssertTrue(ClaudeAgentsRegistry.ledgerMatchesCli(ledger, cli: rows))

        // 台帳がワーカーを生きていないと読むと（CLI は pid あり）一致しない
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["sessionId": busySid]))
        let changed = ClaudeAgentsRegistry.ledgerEntries(ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: { _, _ in false }),
                                                         nowMs: 1_792_582_380_000, buddyTitle: { _ in nil })
        XCTAssertFalse(ClaudeAgentsRegistry.ledgerMatchesCli(changed, cli: rows))
    }

    func testCliEntryUsesCliStateAndFillsFromFiles() throws {
        let sid = "bb74b880-d7c9-4099-9378-fbbbe9b9bed5"
        try home.job("bb74b880", try BgFixtures.variant(files, "job_state_blocked"))
        try liveSession(pid: 31436, jobId: "bb74b880", sessionId: sid, status: "waiting")
        let snapshot = ClaudeAgentsRegistry.readSnapshot(home: home.root, isAlive: { _, _ in false })
        let rows = try cliRows(["background_live_waiting_permission", "background_stopped_with_all"])
        let entries = ClaudeAgentsRegistry.cliEntries(rows, snapshot: snapshot, nowMs: nowMs, buddyTitle: { _ in nil })
        let waiting = try XCTUnwrap(entries.first { $0.row.id == "bb74b880" && $0.row.live })
        // 台帳の生存判定が外れていても、CLI が pid を持つなら live。受け箱と生の status は pid の sessions から取る。
        XCTAssertEqual(waiting.row.state, .blocked)
        XCTAssertEqual(waiting.workerStatus, "waiting")
        XCTAssertEqual(waiting.row.needs, "approve Write: /tmp/fixture/claude-bg-sessions/cwd/bgB/hello.txt")
        let stopped = try XCTUnwrap(entries.first { !$0.row.live })
        XCTAssertEqual(stopped.row.state, .stopped)
        XCTAssertEqual(stopped.row.shells, 0)
    }

    func testCliStatusBusyWithoutSessionFileCountsOnlyWithActiveTempo() throws {
        let cli = try XCTUnwrap(try cliRows(["background_live_busy"]).first)
        var job = BgJobRecord()
        job.tempo = "active"
        var entry = ClaudeAgentsRegistry.cliEntry(cli, job: job, session: nil, nowMs: nowMs, buddyTitle: { _ in nil })
        XCTAssertEqual(entry.workerStatus, "busy")
        job.tempo = "idle"
        entry = ClaudeAgentsRegistry.cliEntry(cli, job: job, session: nil, nowMs: nowMs, buddyTitle: { _ in nil })
        XCTAssertEqual(entry.workerStatus, "unknown")
    }

    // MACBG-2: createdAt が無い孤児は 0 とみなして failed にする。exec で respawnFlags が空の blocked も failed
    func testOrphanWithoutCreatedAtBecomesFailedAndExecBlockedWithoutRespawnFlags() {
        var job = BgJobRecord()
        job.state = "working"
        job.tempo = "active"
        let d = ClaudeAgentsRegistry.derive(id: "aaaaaaaa", job: job, workerStatus: nil, shorts: [], nowMs: nowMs)
        XCTAssertEqual(d.state, .failed)

        var blocked = BgJobRecord()
        blocked.state = "blocked"
        blocked.tempo = "blocked"
        blocked.createdAtMs = nowMs - 60_000
        XCTAssertEqual(ClaudeAgentsRegistry.derive(id: "aaaaaaaa", job: blocked, workerStatus: nil, shorts: [], nowMs: nowMs).state, .blocked)
        blocked.template = "exec"
        blocked.respawnFlagCount = 0
        XCTAssertEqual(ClaudeAgentsRegistry.derive(id: "aaaaaaaa", job: blocked, workerStatus: nil, shorts: [], nowMs: nowMs).state, .failed)
        blocked.respawnFlagCount = 2
        XCTAssertEqual(ClaudeAgentsRegistry.derive(id: "aaaaaaaa", job: blocked, workerStatus: nil, shorts: [], nowMs: nowMs).state, .blocked)
    }

    // MACBG-3: id の無い background 行は捨てる
    func testParseAgentsJsonDropsBackgroundRowWithoutId() {
        let json = #"[{"kind":"background","sessionId":"dceba663-6fad-4d6f-8410-2ce7d7b0c50f","pid":5,"cwd":"/x"}]"#
        XCTAssertEqual(ClaudeAgentsRegistry.parseAgentsJSON(json)?.count, 0)
    }

    // MACBG-4 / MISSED-mac-bg-2: 範囲外の数値で落ちない
    func testOutOfRangeNumbersDoNotTrap() {
        let json = #"[{"kind":"background","id":"dceba663","sessionId":"s","pid":1e20,"startedAt":-1e30,"cwd":"/x"}]"#
        let rows = ClaudeAgentsRegistry.parseAgentsJSON(json)
        XCTAssertEqual(rows?.count, 1)
        XCTAssertNil(rows?.first?.pid)
        XCTAssertNil(rows?.first?.startedAt)
        let session = ClaudeAgentsRegistry.parseSession(Data(#"{"pid":7,"startedAt":1e40,"kind":"bg","jobId":"dceba663","sessionId":"s"}"#.utf8))
        XCTAssertEqual(session?.startedAt, 0)
        let job = ClaudeAgentsRegistry.parseJob(Data(#"{"state":"working","createdAt":1e30,"inFlight":{"kinds":["local_bash"],"tasks":1e30}}"#.utf8))
        XCTAssertNil(job?.createdAtMs)
        XCTAssertEqual(job?.shells, 0)
        let snapshot = BgLedgerSnapshot(sessions: [], jobs: ["dceba663": job!], roster: ["dceba663"])
        _ = ClaudeAgentsRegistry.ledgerEntries(snapshot, nowMs: nowMs, buddyTitle: { _ in nil })
    }

    // MACBG-5: roster が読めないときは前に読めた分を使い続ける。ファイルが無いときだけ空
    func testRosterUnreadableKeepsLastGoodAndMissingIsEmpty() throws {
        let home = try BgHome()
        let file = home.claude.appendingPathComponent("daemon/roster.json")
        try home.roster(["dceba663"])
        XCTAssertEqual(ClaudeAgentsRegistry.readRosterShorts(file: file), ["dceba663"])
        try "{\"proto\": 1, \"workers\": {\"dceba663\": {\"pid\"".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeAgentsRegistry.readRosterShorts(file: file), ["dceba663"])
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(ClaudeAgentsRegistry.readRosterShorts(file: file), [])
    }
}
