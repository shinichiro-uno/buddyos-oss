import XCTest
@testable import BridgeApp

// claude --bg の見張り・配信・操作・知らせ（docs/BACKGROUND_CONTROL_2026-10-21.md §7.4〜§7.9）。
// 一時フォルダの ~/.claude に例を並べ、偽の claude（runCli）を渡して refresh() を直接呼ぶ。FSEvents は張らない。

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func update(_ change: (inout T) -> Void) { lock.lock(); change(&_value); lock.unlock() }
}

/// 偽の claude。呼ばれた引数を控え、handler の返事を返す。
final class FakeClaude: @unchecked Sendable {
    private let calls = LockedBox<[[String]]>([])
    private let running = LockedBox<Int>(0)
    let maxRunning = LockedBox<Int>(0)
    let handler = LockedBox<@Sendable ([String]) async -> BgCliResult>({ _ in BgCliResult(code: 0, stdout: "[]", stderr: "", timedOut: false) })

    var allCalls: [[String]] { calls.value }
    func calls(starting verb: String) -> [[String]] { calls.value.filter { $0.first == verb } }

    func run(_ args: [String], _ timeout: TimeInterval) async -> BgCliResult {
        calls.update { $0.append(args) }
        running.update { $0 += 1 }
        maxRunning.update { $0 = max($0, running.value) }
        defer { running.update { $0 -= 1 } }
        return await handler.value(args)
    }

    static func ok(_ stdout: String = "") -> BgCliResult { BgCliResult(code: 0, stdout: stdout, stderr: "", timedOut: false) }
}

final class BgEventRecorder: @unchecked Sendable {
    private let items = LockedBox<[SessionEvent]>([])
    var send: @Sendable (SessionEvent) -> Void { { [items] e in items.update { $0.append(e) } } }
    var events: [SessionEvent] { items.value }
    func clear() { items.value = [] }

    /// bg_session_changed の content を JSON にしたもの（古い順）。
    var changes: [[String: Any]] {
        events.filter { $0.type == .bgSessionChanged }.compactMap {
            (try? JSONSerialization.jsonObject(with: Data(($0.content ?? "").utf8))) as? [String: Any]
        }
    }
}

final class ClaudeBackgroundJobsTests: XCTestCase {
    private var files: [String: Any]!
    private var home: BgHome!
    private var claude: FakeClaude!
    private var clock: LockedBox<Date>!
    private var pushes: LockedBox<[(sessionId: String, body: String)]>!
    private var sleeps: LockedBox<[Bool]>!
    private var alive: LockedBox<Bool>!

    private let sidA = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
    private let sidB = "bb74b880-d7c9-4099-9378-fbbbe9b9bed5"
    private let sidC = "45221487-9c4c-4592-83bd-5b2006e65854"

    override func setUpWithError() throws {
        files = try BgFixtures.load("examples-registry-files.json")
        home = try BgHome()
        claude = FakeClaude()
        clock = LockedBox(Date(timeIntervalSince1970: 1_792_582_500))
        pushes = LockedBox([])
        sleeps = LockedBox([])
        alive = LockedBox(true)
    }

    private var nowMs: Int64 { Int64(clock.value.timeIntervalSince1970 * 1000) }

    private func makeJobs(title: @escaping @Sendable (String) async -> String? = { _ in nil }) -> ClaudeBackgroundJobs {
        let claude = self.claude!, clock = self.clock!, pushes = self.pushes!, sleeps = self.sleeps!, alive = self.alive!
        var timing = BgTiming()
        timing.mismatchRecheck = 0.01
        timing.cliMinGap = 0
        return ClaudeBackgroundJobs(config: BgJobsConfig(
            home: home.root, timing: timing,
            runCli: { args, timeout in await claude.run(args, timeout) },
            now: { clock.value },
            buddyTitle: title,
            push: { sid, body in pushes.update { $0.append((sid, body)) } },
            setSleep: { active in sleeps.update { $0.append(active) } },
            isAlive: { _, _ in alive.value },
            log: { _ in }))
    }

    private func job(_ id: String, base: String = "job_state_working_with_inflight_task", _ patch: [String: Any?] = [:]) throws {
        var p = patch
        if p.index(forKey: "createdAt") == nil { p["createdAt"] = BgFixtures.iso(nowMs - 60_000) }
        try home.job(id, try BgFixtures.variant(files, base, p))
    }

    private func live(_ pid: Int, _ jobId: String, _ sid: String, _ status: String) throws {
        try home.session(pid, try BgFixtures.variant(files, "sessions_bg_busy",
                                                     ["pid": pid, "jobId": jobId, "sessionId": sid, "status": status]))
    }

    private func until(_ what: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "待ちきれなかった: \(what)", file: file, line: line)
    }

    // MARK: - 変化の配信（§7.6）

    func testChangedOnStateChangeThenRemovedAfter24HoursAndWhenJobVanishes() async throws {
        try job("dceba663", ["sessionId": sidA])
        try home.roster(["dceba663"])
        try live(900, "dceba663", sidA, "busy")
        let jobs = makeJobs()
        let rec = BgEventRecorder()
        _ = await jobs.register(send: rec.send)

        await jobs.refresh()
        XCTAssertEqual(rec.changes.map { $0["state"] as? String }, ["working"])
        // 変わらなければ送らない
        await jobs.refresh()
        XCTAssertEqual(rec.changes.count, 1)

        // 終わった
        try job("dceba663", base: "job_state_done", ["sessionId": sidA])
        try live(900, "dceba663", sidA, "idle")
        await jobs.refresh()
        XCTAssertEqual(rec.changes.last?["state"] as? String, "done")
        XCTAssertEqual(rec.changes.last?["live"] as? Bool, true)

        // ワーカーが消え、終わってから 24 時間を過ぎる
        try FileManager.default.removeItem(at: home.claude.appendingPathComponent("sessions/900.json"))
        await jobs.refresh()
        XCTAssertEqual(rec.changes.last?["live"] as? Bool, false)
        let before = rec.changes.count
        clock.value = clock.value.addingTimeInterval(25 * 3600)
        await jobs.refresh()
        XCTAssertEqual(rec.changes.count, before + 1)
        let removed = try XCTUnwrap(rec.changes.last)
        XCTAssertEqual(removed["removed"] as? Bool, true)
        XCTAssertEqual(removed["id"] as? String, "dceba663")
        XCTAssertEqual(removed["sessionId"] as? String, sidA)
        let rows = await jobs.rows()
        XCTAssertTrue(rows.isEmpty)
        // 台帳には残る（操作の確認は絞り込みの前）
        let kept = await jobs.entryFor(sessionId: sidA)
        XCTAssertNotNil(kept)

        // ジョブが消えたら removed
        try job("bb74b880", base: "job_state_blocked", ["state": "blocked"])
        await jobs.refresh()
        XCTAssertEqual(rec.changes.last?["state"] as? String, "blocked")
        try home.removeJob("bb74b880")
        await jobs.refresh()
        XCTAssertEqual(rec.changes.last?["removed"] as? Bool, true)
        XCTAssertEqual(rec.changes.last?["id"] as? String, "bb74b880")
    }

    func testUnregisteredConnectionGetsNothingAndTitleFollowsBuddyName() async throws {
        try job("dceba663", ["sessionId": sidA])
        try home.roster(["dceba663"])
        let name = LockedBox<String?>(nil)
        let jobs = makeJobs(title: { _ in name.value })
        let rec = BgEventRecorder()
        let token = await jobs.register(send: rec.send)
        await jobs.refresh()
        XCTAssertEqual(rec.changes.count, 1)
        name.value = "付けた名前"
        await jobs.refresh()
        XCTAssertEqual(rec.changes.last?["title"] as? String, "付けた名前")
        await jobs.unregister(token)
        name.value = nil
        await jobs.refresh()
        XCTAssertEqual(rec.changes.count, 2)
    }

    func testRowsAreSortedAndListedForTheListRequest() async throws {
        try job("aaaaaaa1", base: "job_state_done", ["sessionId": "aaaaaaa1-0000-0000-0000-000000000000"])
        try job("aaaaaaa2", ["sessionId": "aaaaaaa2-0000-0000-0000-000000000000", "createdAt": BgFixtures.iso(nowMs - 10_000)])
        try job("aaaaaaa3", base: "job_state_blocked", ["sessionId": "aaaaaaa3-0000-0000-0000-000000000000", "state": "blocked"])
        try home.roster(["aaaaaaa2", "aaaaaaa3"])
        let jobs = makeJobs()
        await jobs.ready()
        let ids = await jobs.rows().map(\.id)
        XCTAssertEqual(ids, ["aaaaaaa3", "aaaaaaa2", "aaaaaaa1"])
    }

    // MARK: - 完了の push（§7.9）

    private func writeTranscript(_ sid: String, lines: [String]) throws -> String {
        let dir = home.claude.appendingPathComponent("projects/-tmp-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sid).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    private func assistant(_ text: String, sidechain: Bool = false) -> String {
        let block = ["type": "text", "text": text]
        let o: [String: Any] = ["type": "assistant", "isSidechain": sidechain, "message": ["content": [block]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }

    func testPushOnceWhenFirstWorkEndsWithTranscriptBody() async throws {
        let final = String(repeating: "あ", count: 300)
        let transcript = try writeTranscript(sidA, lines: [
            assistant("途中の返事"), assistant("サブエージェントの返事", sidechain: true), assistant(final),
            "{\"type\":\"user\",\"message\":{\"content\":\"x\"}}"])
        try job("dceba663", ["sessionId": sidA, "firstTerminalAt": nil, "lastTerminalAt": nil])
        try home.roster(["dceba663"])
        try live(901, "dceba663", sidA, "busy")
        let jobs = makeJobs()
        await jobs.refresh()
        XCTAssertTrue(pushes.value.isEmpty)

        try job("dceba663", base: "job_state_done", ["sessionId": sidA, "linkScanPath": transcript])
        try live(901, "dceba663", sidA, "idle")
        await jobs.refresh()
        try await until("push") { pushes.value.count == 1 }
        XCTAssertEqual(pushes.value[0].sessionId, sidA)
        XCTAssertEqual(pushes.value[0].body, String(final.prefix(180)))

        // 2 回目以降は出さない（同じ状態・もう 1 回作業して終わる）
        await jobs.refresh()
        try job("dceba663", ["sessionId": sidA, "firstTerminalAt": BgFixtures.iso(nowMs - 30_000)])
        await jobs.refresh()
        try job("dceba663", base: "job_state_done", ["sessionId": sidA, "linkScanPath": transcript])
        await jobs.refresh()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(pushes.value.count, 1)
    }

    func testPushBodyFallsBackAndFailedCarriesDetail() async throws {
        try job("dceba663", ["sessionId": sidA, "firstTerminalAt": nil])
        try job("bb74b880", ["sessionId": sidB, "firstTerminalAt": nil])
        try home.roster(["dceba663", "bb74b880"])
        let jobs = makeJobs()
        await jobs.refresh()
        try job("dceba663", base: "job_state_done", ["sessionId": sidA, "linkScanPath": nil])
        try job("bb74b880", base: "job_state_failed_before_init", ["sessionId": sidB, "detail": String(repeating: "x", count: 300)])
        await jobs.refresh()
        try await until("2 pushes") { pushes.value.count == 2 }
        let bodies = Dictionary(uniqueKeysWithValues: pushes.value.map { ($0.sessionId, $0.body) })
        XCTAssertEqual(bodies[sidA], "バックグラウンドのセッションが終わりました")
        XCTAssertEqual(bodies[sidB], "バックグラウンドのセッションが失敗しました（" + String(repeating: "x", count: 120) + "）")
    }

    func testNoPushAtStartupForStoppedOrForBlockedToWorking() async throws {
        // 起動して最初の読み取りで終わっていたものは出さない
        try job("dceba663", base: "job_state_done", ["sessionId": sidA])
        // 止めたのは利用者
        try job("bb74b880", ["sessionId": sidB, "firstTerminalAt": nil])
        try job("45221487", base: "job_state_blocked", ["sessionId": sidC, "state": "blocked"])
        try home.roster(["bb74b880", "45221487"])
        let jobs = makeJobs()
        await jobs.refresh()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(pushes.value.isEmpty)
        try job("bb74b880", base: "job_state_stopped", ["sessionId": sidB])
        // blocked が working に戻っただけ
        try job("45221487", ["sessionId": sidC, "firstTerminalAt": nil])
        await jobs.refresh()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(pushes.value.isEmpty)
    }

    func testHubSkipsPushWhenConversationIsOpenOrPushedWithin60Seconds() async throws {
        let recorder = ChatPushRecorder()
        SessionHub.chatPushObserver = recorder.observer
        defer { SessionHub.chatPushObserver = nil }
        let sid = "hub-\(UUID().uuidString.lowercased())"
        let hub = SessionHub.shared

        // 開いている人がいる（entry がある）
        let adapter = BackgroundWorkAdapter(id: "claude")
        let listener = HubListener()
        _ = await hub.acquire(agentId: "claude", sessionId: sid, cwd: nil, adapter: adapter, subscriberId: listener.id, send: listener.send)
        var sent = await hub.pushBackgroundSessionEnded(sessionId: sid, body: "開いている")
        XCTAssertFalse(sent)
        await hub.release(subscriberId: listener.id)
        try await Task.sleep(nanoseconds: 200_000_000)

        let other = "hub-\(UUID().uuidString.lowercased())"
        sent = await hub.pushBackgroundSessionEnded(sessionId: other, body: "1 回目")
        XCTAssertTrue(sent)
        sent = await hub.pushBackgroundSessionEnded(sessionId: other, body: "60 秒以内", now: Date().addingTimeInterval(30))
        XCTAssertFalse(sent)
        sent = await hub.pushBackgroundSessionEnded(sessionId: other, body: "60 秒後", now: Date().addingTimeInterval(61))
        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.bodies("claude").filter { $0 == "開いている" || $0 == "60 秒以内" }, [])
        XCTAssertEqual(recorder.bodies("claude").filter { $0 == "1 回目" || $0 == "60 秒後" }, ["1 回目", "60 秒後"])
    }

    // MARK: - 停止と削除（§7.7）

    private func prepareShellJob() throws {
        try job("45221487", ["sessionId": sidC])
        try home.roster(["45221487"])
        try live(902, "45221487", sidC, "shell")
    }

    func testStopStdoutStoppedIsOkAndRemembersShells() async throws {
        try prepareShellJob()
        let jobs = makeJobs()
        let rec = BgEventRecorder()
        _ = await jobs.register(send: rec.send)
        await jobs.refresh()
        let home = self.home!
        let files = self.files!
        claude.handler.value = { args in
            // 止まった後の台帳に書き換える
            if args.first == "stop" {
                try? home.job("45221487", try BgFixtures.variant(files, "job_state_stopped", ["sessionId": "45221487-9c4c-4592-83bd-5b2006e65854"]))
                try? FileManager.default.removeItem(at: home.claude.appendingPathComponent("sessions/902.json"))
            }
            return FakeClaude.ok("stopped 45221487\n")
        }
        rec.clear()
        let result = await jobs.operate(.stop, id: "45221487", sessionId: sidC)
        XCTAssertEqual(result, BgOperationResult(ok: true, shells: 1, text: "止めました。裏で動いていたコマンド 1 件は PC で動いたままです。"))
        XCTAssertEqual(claude.calls(starting: "stop"), [["stop", "45221487"]])
        // 結果を返したあと、台帳を読み直して bg_session_changed を送る（読み直しは待たない）
        try await until("changed stopped") { rec.changes.last?["state"] as? String == "stopped" }
        XCTAssertEqual(rec.changes.last?["state"] as? String, "stopped")
        XCTAssertEqual(rec.changes.last?["live"] as? Bool, false)
    }

    func testDeleteOkAndPlainTextEmptyWithoutShells() async throws {
        try job("dceba663", base: "job_state_done", ["sessionId": sidA])
        let jobs = makeJobs()
        await jobs.refresh()
        claude.handler.value = { _ in FakeClaude.ok("removed dceba663\n") }
        let result = await jobs.operate(.delete, id: "dceba663", sessionId: sidA)
        XCTAssertEqual(result, BgOperationResult(ok: true, shells: 0, text: ""))
        XCTAssertEqual(claude.calls(starting: "rm"), [["rm", "dceba663"]])
    }

    func testNoJobMatchingMeansStopFailedButDeleteSucceeded() async throws {
        try job("dceba663", base: "job_state_done", ["sessionId": sidA])
        let jobs = makeJobs()
        await jobs.refresh()
        claude.handler.value = { _ in BgCliResult(code: 1, stdout: "", stderr: "No job matching dceba663\n", timedOut: false) }
        let stop = await jobs.operate(.stop, id: "dceba663", sessionId: sidA)
        XCTAssertEqual(stop, BgOperationResult(ok: false, shells: 0, text: "このセッションは見つかりません（もう消えています）"))
        let delete = await jobs.operate(.delete, id: "dceba663", sessionId: sidA)
        XCTAssertEqual(delete, BgOperationResult(ok: true, shells: 0, text: ""))
    }

    func testTimeoutAndOtherFailures() async throws {
        try job("dceba663", base: "job_state_done", ["sessionId": sidA])
        let jobs = makeJobs()
        await jobs.refresh()
        claude.handler.value = { _ in BgCliResult(code: -1, stdout: "", stderr: "", timedOut: true) }
        let stop = await jobs.operate(.stop, id: "dceba663", sessionId: sidA)
        XCTAssertEqual(stop.text, "PC で止められませんでした（15秒たっても終わりません）")
        XCTAssertFalse(stop.ok)
        let delete = await jobs.operate(.delete, id: "dceba663", sessionId: sidA)
        XCTAssertEqual(delete.text, "PC で削除できませんでした（20秒たっても終わりません）")
        XCTAssertFalse(delete.ok)

        claude.handler.value = { _ in BgCliResult(code: 1, stdout: "", stderr: "one\ntwo\n\nthree\nfour\n", timedOut: false) }
        let other = await jobs.operate(.delete, id: "dceba663", sessionId: sidA)
        XCTAssertEqual(other, BgOperationResult(ok: false, shells: 0, text: "two\nthree\nfour"))
        // 終了コード 0 でも stdout が違えば失敗
        claude.handler.value = { _ in FakeClaude.ok("something else\n") }
        let odd = await jobs.operate(.stop, id: "dceba663", sessionId: sidA)
        XCTAssertFalse(odd.ok)
    }

    func testBadIdOrMismatchedSessionDoesNotRunTheCli() async throws {
        try job("dceba663", base: "job_state_done", ["sessionId": sidA])
        let jobs = makeJobs()
        await jobs.refresh()
        let expected = BgOperationResult(ok: false, shells: 0, text: "このセッションは見つかりません（もう消えています）")
        for (id, sid) in [("../etc", sidA), ("DCEBA663", sidA), ("dceba66", sidA), ("dceba663 ", sidA), ("bb74b880", sidB),
                          ("dceba663", sidB), ("dceba663", nil)] as [(String, String?)] {
            let r = await jobs.operate(.stop, id: id, sessionId: sid)
            XCTAssertEqual(r, expected, "\(id) \(sid ?? "nil")")
            let d = await jobs.operate(.delete, id: id, sessionId: sid)
            XCTAssertEqual(d, expected)
        }
        XCTAssertTrue(claude.allCalls.isEmpty)
    }

    func testOperationsOnTheSameIdRunOneAtATime() async throws {
        try job("dceba663", base: "job_state_done", ["sessionId": sidA])
        let jobs = makeJobs()
        await jobs.refresh()
        claude.handler.value = { args in
            try? await Task.sleep(nanoseconds: 120_000_000)
            return FakeClaude.ok("\(args[0] == "stop" ? "stopped" : "removed") dceba663\n")
        }
        async let a = jobs.operate(.stop, id: "dceba663", sessionId: sidA)
        async let b = jobs.operate(.delete, id: "dceba663", sessionId: sidA)
        let (ra, rb) = await (a, b)
        XCTAssertTrue(ra.ok && rb.ok)
        XCTAssertEqual(claude.maxRunning.value, 1)
    }

    // MARK: - スリープの抑止（§7.9）と Live Activity の数

    func testSleepIsHeldOnlyWhileWorkerIsBusyNotForShell() async throws {
        try job("dceba663", ["sessionId": sidA])
        try home.roster(["dceba663"])
        try live(903, "dceba663", sidA, "busy")
        let jobs = makeJobs()
        await jobs.refresh()
        XCTAssertEqual(sleeps.value, [true])
        try live(903, "dceba663", sidA, "shell")
        await jobs.refresh()
        XCTAssertEqual(sleeps.value, [true, false])
        try live(903, "dceba663", sidA, "waiting")
        await jobs.refresh()
        XCTAssertEqual(sleeps.value, [true, false])
        try live(903, "dceba663", sidA, "busy")
        await jobs.refresh()
        XCTAssertEqual(sleeps.value, [true, false, true])
        // 同じジョブが 6 時間続けて busy なら数えない
        clock.value = clock.value.addingTimeInterval(6 * 3600 + 1)
        await jobs.refresh()
        XCTAssertEqual(sleeps.value, [true, false, true, false])
    }

    func testActivityCountsAndFinishedTransitions() async throws {
        try job("dceba663", ["sessionId": sidA, "firstTerminalAt": nil])
        try job("bb74b880", base: "job_state_blocked", ["sessionId": sidB, "state": "blocked"])
        try job("45221487", base: "job_state_done", ["sessionId": sidC, "intent": "/loop 5m check"])
        try home.roster(["dceba663", "bb74b880", "45221487"])
        try live(904, "45221487", sidC, "idle")
        let jobs = makeJobs()
        let seen = LockedBox<[BgActivity]>([])
        _ = await jobs.onActivity { a in seen.update { $0.append(a) } }
        await jobs.refresh()
        // 繰り返しの待ちは数えない
        XCTAssertEqual(seen.value.last?.counts, [sidA: 1, sidB: 1])
        let counts = await jobs.activityCounts()
        XCTAssertEqual(counts, [sidA: 1, sidB: 1])

        try job("dceba663", base: "job_state_done", ["sessionId": sidA])
        try home.removeJob("bb74b880")
        await jobs.refresh()
        XCTAssertEqual(seen.value.last?.counts, [:])
        XCTAssertEqual(Set((seen.value.last?.finished ?? []).map(\.rawValue)), ["done", "stopped"])
    }

    // MARK: - 能力・状態を渡す口

    func testEntryWatchersSeeRawStatusChangesAndWorkerLookup() async throws {
        try job("dceba663", ["sessionId": sidA])
        try home.roster(["dceba663"])
        try live(905, "dceba663", sidA, "busy")
        let jobs = makeJobs()
        let seen = LockedBox<[String?]>([])
        _ = await jobs.watchEntry(sessionId: sidA) { entry in seen.update { $0.append(entry?.workerStatus) } }
        await jobs.refresh()
        let isWorker = await jobs.isBackgroundWorker(sessionId: sidA)
        let inbox = await jobs.entryFor(sessionId: sidA)?.inbox
        XCTAssertTrue(isWorker)
        XCTAssertEqual(inbox, "/tmp/cc-socks/31875.sock")
        try live(905, "dceba663", sidA, "idle")
        await jobs.refresh()
        await jobs.refresh()
        XCTAssertEqual(seen.value, ["busy", "idle"])
        let other = await jobs.isBackgroundWorker(sessionId: sidB)
        XCTAssertFalse(other)
    }

    // MARK: - CLI との突き合わせ（§7.5）

    private func agentsJSON(_ rows: [[String: Any]]) -> BgCliResult {
        FakeClaude.ok(String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
    }

    func testTwoMismatchesSwitchToCliModeAndMatchSwitchesBack() async throws {
        try job("dceba663", ["sessionId": sidA])
        try home.roster(["dceba663"])
        try live(906, "dceba663", sidA, "busy")
        let jobs = makeJobs()
        await jobs.refresh()
        let busyRow: [String: Any] = ["pid": 906, "id": "dceba663", "cwd": "/x", "kind": "background", "startedAt": 1,
                                      "sessionId": sidA, "name": "n", "status": "busy", "state": "working"]
        // 台帳は working・pid あり。CLI は done・pid なし（違う）
        let doneRow: [String: Any] = ["id": "dceba663", "cwd": "/x", "kind": "background", "startedAt": 1,
                                      "sessionId": sidA, "name": "n", "state": "done"]
        claude.handler.value = { [self] _ in agentsJSON([doneRow]) }
        await jobs.crossCheck()
        let isCli = await jobs.isCliMode
        XCTAssertTrue(isCli)
        XCTAssertEqual(claude.calls(starting: "agents").count, 3)   // 2 回の突き合わせ + 切り替えの読み取り
        var rows = await jobs.rows()
        XCTAssertEqual(rows.first?.state, .done)
        XCTAssertEqual(rows.first?.live, false)

        // CLI が失敗したら前の結果を保つ
        claude.handler.value = { _ in BgCliResult(code: 1, stdout: "", stderr: "boom", timedOut: false) }
        await jobs.refresh()
        rows = await jobs.rows()
        XCTAssertEqual(rows.first?.state, .done)

        // 一致すれば台帳の方式に戻す
        claude.handler.value = { [self] _ in agentsJSON([busyRow]) }
        await jobs.crossCheck()
        let back = await jobs.isCliMode
        XCTAssertFalse(back)
        rows = await jobs.rows()
        XCTAssertEqual(rows.first?.state, .working)
    }

    func testSingleMismatchThatClearsOnRecheckKeepsRegistryMode() async throws {
        try job("dceba663", ["sessionId": sidA])
        try home.roster(["dceba663"])
        try live(907, "dceba663", sidA, "busy")
        let jobs = makeJobs()
        await jobs.refresh()
        let calls = LockedBox(0)
        let busyRow: [String: Any] = ["pid": 907, "id": "dceba663", "cwd": "/x", "kind": "background", "startedAt": 1,
                                      "sessionId": sidA, "status": "busy", "state": "working"]
        claude.handler.value = { [self] _ in
            calls.update { $0 += 1 }
            return agentsJSON(calls.value == 1 ? [] : [busyRow])
        }
        await jobs.crossCheck()
        let isCli = await jobs.isCliMode
        XCTAssertFalse(isCli)
        XCTAssertEqual(calls.value, 2)
    }

    func testCliFailureDuringCrossCheckChangesNothing() async throws {
        try job("dceba663", ["sessionId": sidA])
        let jobs = makeJobs()
        await jobs.refresh()
        claude.handler.value = { _ in BgCliResult(code: 127, stdout: "", stderr: "not found", timedOut: false) }
        await jobs.crossCheck()
        let isCli = await jobs.isCliMode
        XCTAssertFalse(isCli)
        XCTAssertEqual(claude.calls(starting: "agents").count, 1)
    }

    // MARK: - 見張りの拾い方（§7.4）

    // PP-4: 操作の結果は、CLI 方式の一覧の読み直しを待たずに返す
    func testOperationResultDoesNotWaitForTheListRefresh() async throws {
        try job("dceba663", ["sessionId": sidA])
        try home.roster(["dceba663"])
        try live(908, "dceba663", sidA, "busy")
        let jobs = makeJobs()
        await jobs.refresh()
        let doneRow: [String: Any] = ["id": "dceba663", "cwd": "/x", "kind": "background", "startedAt": 1,
                                      "sessionId": sidA, "name": "n", "state": "done"]
        claude.handler.value = { [self] _ in agentsJSON([doneRow]) }
        await jobs.crossCheck()
        let isCli = await jobs.isCliMode
        XCTAssertTrue(isCli)
        claude.handler.value = { [self] args in
            if args.first == "agents" {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return agentsJSON([doneRow])
            }
            return FakeClaude.ok("stopped dceba663\n")
        }
        let started = Date()
        let result = await jobs.operate(.stop, id: "dceba663", sessionId: sidA)
        XCTAssertTrue(result.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    // MACBG-10: CLI が 3 回続けて失敗している間は、一覧も変化の配信も数も 0 件にそろえる
    func testCliUnavailableEmptiesRowsChangesAndActivityTogether() async throws {
        try job("dceba663", ["sessionId": sidA])
        try home.roster(["dceba663"])
        try live(909, "dceba663", sidA, "busy")
        let jobs = makeJobs()
        let rec = BgEventRecorder()
        _ = await jobs.register(send: rec.send)
        await jobs.refresh()
        let stoppedRow: [String: Any] = ["id": "dceba663", "cwd": "/x", "kind": "background", "startedAt": 1,
                                         "sessionId": sidA, "name": "n", "state": "done"]
        claude.handler.value = { [self] _ in agentsJSON([stoppedRow]) }
        await jobs.crossCheck()
        let isCli = await jobs.isCliMode
        XCTAssertTrue(isCli)
        claude.handler.value = { _ in BgCliResult(code: 1, stdout: "", stderr: "boom", timedOut: false) }
        for _ in 0..<3 {
            clock.update { $0 = $0.addingTimeInterval(400) }
            await jobs.refresh()
        }
        let rows = await jobs.rows()
        XCTAssertTrue(rows.isEmpty)
        let counts = await jobs.activityCounts()
        XCTAssertTrue(counts.isEmpty)
        // 古い行は一度だけ removed で消える。そのあとの読み直しでは何も送らない
        XCTAssertEqual(rec.changes.last?["removed"] as? Bool, true)
        let sentSoFar = rec.changes.count
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_blocked", ["sessionId": sidA, "state": "blocked"]))
        clock.update { $0 = $0.addingTimeInterval(400) }
        await jobs.refresh()
        XCTAssertEqual(rec.changes.count, sentSoFar)
    }

    // MACBG-9: シンボリックリンクの実体のパスや、取りこぼしの印でも拾う
    func testRelevantChangeFollowsRealPathAndOverflowTriggers() async throws {
        let roots = ["/Users/me/.claude", "/Users/me/dotfiles/claude"]
        XCTAssertTrue(ClaudeBackgroundJobs.isRelevantChange("/Users/me/dotfiles/claude/sessions/1.json", roots: roots))
        XCTAssertFalse(ClaudeBackgroundJobs.isRelevantChange("/Users/me/dotfiles/claude/projects/x.jsonl", roots: roots))
        XCTAssertFalse(ClaudeBackgroundJobs.isRelevantChange("/Users/me/dotfiles/claude/sessions/1.json"))
        let jobs = makeJobs()
        await jobs.trigger(paths: ["/Users/me/.claude"], overflow: true)
        await jobs.stop()
    }

    func testOnlySessionsJobsAndRosterChangesAreRelevant() {
        let base = "/Users/me/.claude"
        XCTAssertTrue(ClaudeBackgroundJobs.isRelevantChange("\(base)/sessions/123.json"))
        XCTAssertTrue(ClaudeBackgroundJobs.isRelevantChange("\(base)/jobs/dceba663/state.json"))
        XCTAssertTrue(ClaudeBackgroundJobs.isRelevantChange("\(base)/daemon/roster.json"))
        XCTAssertFalse(ClaudeBackgroundJobs.isRelevantChange("\(base)/sessions/123.key"))
        XCTAssertFalse(ClaudeBackgroundJobs.isRelevantChange("\(base)/jobs/dceba663/state.json.tmp.99"))
        XCTAssertFalse(ClaudeBackgroundJobs.isRelevantChange("\(base)/daemon/daemon.log"))
        XCTAssertFalse(ClaudeBackgroundJobs.isRelevantChange("\(base)/projects/-x/a.jsonl"))
        XCTAssertFalse(ClaudeBackgroundJobs.isRelevantChange("/Users/me/other/sessions/1.json"))
    }

    func testWorkerCapabilityIsAdvertisedOnlyWithAClaudeExecutable() {
        let present = ClaudeCodeAdapter(executable: "/bin/sh")
        XCTAssertTrue(AgentRegistry.capabilities(of: present).bgSessions)
        let missing = ClaudeCodeAdapter(executable: "/no/such/claude")
        XCTAssertFalse(AgentRegistry.capabilities(of: missing).bgSessions)
        XCTAssertFalse(AgentRegistry.capabilities(of: EchoAdapter()).bgSessions)
    }
}
