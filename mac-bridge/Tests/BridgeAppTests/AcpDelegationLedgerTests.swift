import XCTest
import GRDB
@testable import BridgeApp

/// ACP の非同期の委任の台帳（Hermes の async_delegations・OpenClaw の task_runs）と受領票の読み取り
/// （docs/BACKGROUND_CONTROL_2026-10-21.md §5.4〜5.6）。SQL・状態の対応・表や列が無いとき・見張りの規則を確かめる。
final class AcpDelegationLedgerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-ledger-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var dbPath: String { tempDir.appendingPathComponent("ledger.db").path }

    // MARK: Hermes の状態の対応

    func testHermesStatesMapToRowStates() {
        func status(_ state: String?) -> AcpLedgerStatus { HermesLedger.status(state: state, eventJSON: nil) }
        for running in ["running", "stalling", "finalizing"] {
            XCTAssertEqual(status(running), .running(text: nil, toolCalls: nil), running)
        }
        XCTAssertEqual(status("completed"), .finished(state: "done", result: nil, durationMs: nil))
        for failed in ["error", "stalled", "unknown"] {
            XCTAssertEqual(status(failed), .finished(state: "failed", result: nil, durationMs: nil), failed)
        }
        // 知らない状態は completed_at で決める（無ければ動いている。将来の版で状態が増えても赤で閉じない）。
        for unknown in ["queued", "pending", "something-new", nil] {
            XCTAssertEqual(status(unknown), .running(text: nil, toolCalls: nil), unknown ?? "nil")
            XCTAssertEqual(HermesLedger.status(state: unknown, eventJSON: nil, completedAt: 1_000),
                           .finished(state: "failed", result: nil, durationMs: nil), unknown ?? "nil")
        }
        for stopped in ["interrupted", "cancelled"] {
            XCTAssertEqual(status(stopped), .finished(state: "stopped", result: nil, durationMs: nil), stopped)
        }
    }

    func testHermesResultJoinsSummariesAndFallsBackToError() {
        let event = """
        {"results":[{"summary":"first"},{"error":"boom"},{"summary":"  "},{"summary":"third"}],"total_duration_seconds":24.25}
        """
        XCTAssertEqual(HermesLedger.status(state: "completed", eventJSON: event),
                       .finished(state: "done", result: "first\n\nboom\n\nthird", durationMs: 24250))
        // results の無い形は summary / error。所要時間は duration_seconds にも従う。
        XCTAssertEqual(HermesLedger.status(state: "error", eventJSON: #"{"error":"failed to start","duration_seconds":1.5}"#),
                       .finished(state: "failed", result: "failed to start", durationMs: 1500))
        XCTAssertEqual(HermesLedger.status(state: "completed", eventJSON: #"{"summary":"all good"}"#),
                       .finished(state: "done", result: "all good", durationMs: nil))
        XCTAssertEqual(HermesLedger.status(state: "completed", eventJSON: "not json"),
                       .finished(state: "done", result: nil, durationMs: nil))
    }

    // MARK: Hermes の SQL

    private func makeHermesDb(columns: String = "delegation_id TEXT, state TEXT, completed_at REAL, event_json TEXT",
                              rows: [(String, String, String?)] = []) throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE async_delegations (\(columns))")
            for (id, state, event) in rows {
                try db.execute(sql: "INSERT INTO async_delegations (delegation_id, state, event_json) VALUES (?, ?, ?)",
                               arguments: [id, state, event])
            }
        }
    }

    func testHermesReadsOnlyTheAskedKeysAndMarksUnknownOnesMissing() throws {
        try makeHermesDb(rows: [("d1", "running", nil), ("d2", "completed", #"{"summary":"ok"}"#), ("d3", "error", nil)])
        let out = try HermesLedger(path: dbPath).read(keys: ["d1", "d2", "nope"])
        XCTAssertEqual(out["d1"], .running(text: nil, toolCalls: nil))
        XCTAssertEqual(out["d2"], .finished(state: "done", result: "ok", durationMs: nil))
        XCTAssertEqual(out["nope"], .missing)
        XCTAssertNil(out["d3"])
    }

    func testHermesUnreadableWhenFileTableOrColumnIsMissing() throws {
        XCTAssertThrowsError(try HermesLedger(path: dbPath).read(keys: ["d1"])) { error in
            guard case AcpLedgerError.unreadable = error else { return XCTFail("ファイルが無い: \(error)") }
        }
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { try $0.execute(sql: "CREATE TABLE other (x TEXT)") }
        XCTAssertThrowsError(try HermesLedger(path: dbPath).read(keys: ["d1"])) { error in
            guard case AcpLedgerError.unreadable = error else { return XCTFail("表が無い: \(error)") }
        }
        let noColumn = tempDir.appendingPathComponent("old.db").path
        let old = try DatabaseQueue(path: noColumn)
        try old.write { try $0.execute(sql: "CREATE TABLE async_delegations (delegation_id TEXT, state TEXT)") }
        XCTAssertThrowsError(try HermesLedger(path: noColumn).read(keys: ["d1"])) { error in
            guard case AcpLedgerError.unreadable = error else { return XCTFail("列が無い: \(error)") }
        }
    }

    func testHermesLockedDatabaseIsTransientAndTypesAreReadSafely() throws {
        // INTEGER の state / event_json でも落ちない（GRDB の String 取得は型違いで fatalError になる）。
        var unsafe = Configuration()
        unsafe.allowsUnsafeTransactions = true
        let queue = try DatabaseQueue(path: dbPath, configuration: unsafe)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE async_delegations (delegation_id TEXT, state TEXT, completed_at REAL, event_json TEXT)")
            try db.execute(sql: "INSERT INTO async_delegations VALUES ('d1', 7, NULL, 42)")
        }
        // 知らない状態（INTEGER の 7）で completed_at が無いので、動いているとみなす。
        XCTAssertEqual(try HermesLedger(path: dbPath).read(keys: ["d1"])["d1"], .running(text: nil, toolCalls: nil))

        try queue.writeWithoutTransaction { try $0.execute(sql: "BEGIN EXCLUSIVE") }
        XCTAssertThrowsError(try HermesLedger(path: dbPath).read(keys: ["d1"])) { error in
            guard case AcpLedgerError.transient = error else { return XCTFail("busy は次の回にやり直す: \(error)") }
        }
        try queue.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
    }

    // MARK: OpenClaw の状態の対応

    private func openclaw(_ status: String?, ended: Double? = nil, started: Double? = nil, progress: String? = nil,
                          error: String? = nil, outcome: String? = nil, tools: Int? = nil, last: String? = nil) -> AcpLedgerStatus {
        OpenclawLedger.status(status: status, endedAt: ended, startedAt: started, progress: progress, error: error,
                              terminalOutcome: outcome, toolUseCount: tools, lastToolName: last)
    }

    func testOpenclawStatusMapping() {
        XCTAssertEqual(openclaw("queued", tools: nil, last: nil), .running(text: nil, toolCalls: nil))
        XCTAssertEqual(openclaw("running", tools: 3, last: "exec"), .running(text: "exec", toolCalls: 3))
        XCTAssertEqual(openclaw("succeeded", ended: 2000, started: 500, progress: "OK"),
                       .finished(state: "done", result: "OK", durationMs: 1500))
        XCTAssertEqual(openclaw("succeeded", progress: "x", error: "blocked by policy", outcome: "blocked"),
                       .finished(state: "failed", result: "blocked by policy", durationMs: nil))
        XCTAssertEqual(openclaw("failed", progress: "partial", error: "crashed"),
                       .finished(state: "failed", result: "crashed", durationMs: nil))
        XCTAssertEqual(openclaw("timed_out", error: "slow"), .finished(state: "failed", result: "slow", durationMs: nil))
        XCTAssertEqual(openclaw("lost", progress: "last words", error: nil),
                       .finished(state: "failed", result: "last words", durationMs: nil))
        XCTAssertEqual(openclaw("cancelled"), .finished(state: "stopped", result: nil, durationMs: nil))
        // 知らない状態は、終わった印があれば失敗、無ければ動いている。
        XCTAssertEqual(openclaw("weird", ended: 10), .finished(state: "failed", result: nil, durationMs: nil))
        XCTAssertEqual(openclaw("weird", tools: 1, last: "read"), .running(text: "read", toolCalls: 1))
    }

    // MARK: OpenClaw の SQL と CLI

    private let taskRunsColumns = """
        run_id TEXT, status TEXT, ended_at INTEGER, started_at INTEGER, progress_summary TEXT, error TEXT, \
        terminal_outcome TEXT, tool_use_count INTEGER, last_tool_name TEXT
        """

    func testOpenclawReadsTaskRunsAndIgnoresMissingStartedAtColumn() throws {
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE task_runs (\(taskRunsColumns))")
            try db.execute(sql: "INSERT INTO task_runs VALUES ('r1', 'running', NULL, 100, NULL, NULL, NULL, 2, 'exec')")
            try db.execute(sql: "INSERT INTO task_runs VALUES ('r2', 'succeeded', 900, 100, 'done!', NULL, NULL, 1, 'exec')")
        }
        let out = try OpenclawLedger(path: dbPath).read(keys: ["r1", "r2", "r3"])
        XCTAssertEqual(out["r1"], .running(text: "exec", toolCalls: 2))
        XCTAssertEqual(out["r2"], .finished(state: "done", result: "done!", durationMs: 800))
        XCTAssertEqual(out["r3"], .missing)

        let old = tempDir.appendingPathComponent("old.sqlite").path
        let oldQueue = try DatabaseQueue(path: old)
        try oldQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE task_runs (run_id TEXT, status TEXT, ended_at INTEGER, progress_summary TEXT, error TEXT, \
                terminal_outcome TEXT, tool_use_count INTEGER, last_tool_name TEXT)
                """)
            try db.execute(sql: "INSERT INTO task_runs VALUES ('r1', 'succeeded', 900, 'ok', NULL, NULL, 1, 'exec')")
        }
        XCTAssertEqual(try OpenclawLedger(path: old).read(keys: ["r1"])["r1"], .finished(state: "done", result: "ok", durationMs: nil))
    }

    func testOpenclawWithoutDatabaseOrCliIsUnreadable() {
        XCTAssertThrowsError(try OpenclawLedger(path: dbPath).read(keys: ["r1"])) { error in
            guard case AcpLedgerError.unreadable = error else { return XCTFail("\(error)") }
        }
    }

    /// DB が読めないときは `openclaw tasks show <runId> --json` を 1 本ずつ順に読み、間隔は 10 秒になる。
    func testOpenclawFallsBackToCliOneKeyAtATime() throws {
        let asked = Counter2()
        let ledger = OpenclawLedger(path: dbPath, cli: { runId in
            asked.add(runId)
            return #"{"task":{"runId":"\#(runId)","status":"succeeded","progressSummary":"from cli","endedAt":30,"startedAt":10}}"#
        })
        XCTAssertEqual(ledger.pollInterval, 3)
        let first = try ledger.read(keys: ["a", "b"])
        XCTAssertEqual(first, ["a": .finished(state: "done", result: "from cli", durationMs: 20)])
        let second = try ledger.read(keys: ["a", "b"])
        XCTAssertEqual(Array(second.keys), ["b"])
        XCTAssertEqual(asked.all, ["a", "b"])
        XCTAssertEqual(ledger.pollInterval, 10)
    }

    func testOpenclawCliFailureIsUnreadableUntilItHasWorkedOnce() throws {
        let broken = OpenclawLedger(path: dbPath, cli: { _ in nil })
        XCTAssertThrowsError(try broken.read(keys: ["a"])) { error in
            guard case AcpLedgerError.unreadable = error else { return XCTFail("\(error)") }
        }
        let flaky = Flaky()
        let ledger = OpenclawLedger(path: dbPath, cli: { _ in flaky.next() })
        XCTAssertNoThrow(try ledger.read(keys: ["a"]))
        XCTAssertEqual(try ledger.read(keys: ["a"]), ["a": .retry], "読めると分かってからの失敗は、その鍵だけ数えて次の回にやり直す")
    }

    func testCliFieldsAcceptsPlainAndNestedAndCamelCase() {
        XCTAssertEqual(OpenclawLedger.cliFields(#"{"status":"running","last_tool_name":"x"}"#)?["last_tool_name"] as? String, "x")
        XCTAssertEqual(OpenclawLedger.cliFields(#"{"task":{"status":"running","lastToolName":"y"}}"#)?["last_tool_name"] as? String, "y")
        XCTAssertNil(OpenclawLedger.cliFields("Error: task not found"))
        XCTAssertNil(OpenclawLedger.cliFields(#"{"message":"no status"}"#))
    }

    // MARK: 受領票

    private func update(_ text: String, rawOutput: [String: Any]? = nil) -> [String: Any] {
        var u: [String: Any] = ["sessionUpdate": "tool_call_update", "status": "completed",
                                "content": [["type": "content", "content": ["type": "text", "text": text]]]]
        if let rawOutput { u["rawOutput"] = rawOutput }
        return u
    }

    func testHermesReceipt() {
        let dispatched = #"{"status":"dispatched","mode":"background","count":2,"delegation_id":"deleg_1","goals":["a","b"]}"#
        XCTAssertEqual(AcpDelegationReceipt.hermes(update(dispatched))?.delegationId, "deleg_1")
        XCTAssertEqual(AcpDelegationReceipt.hermes(update(dispatched))?.count, 2)
        // action（list / steer / stop）と results（同期の経路）は今まで通り閉じる。
        XCTAssertNil(AcpDelegationReceipt.hermes(update(#"{"action":"list","status":"dispatched","delegation_id":"x"}"#)))
        XCTAssertNil(AcpDelegationReceipt.hermes(update(#"{"status":"dispatched","delegation_id":"x","results":[]}"#)))
        XCTAssertNil(AcpDelegationReceipt.hermes(update(#"{"status":"completed","delegation_id":"x"}"#)))
        XCTAssertNil(AcpDelegationReceipt.hermes(update(#"{"status":"dispatched"}"#)), "鍵が無い")
        XCTAssertNil(AcpDelegationReceipt.hermes(update("Started 3 tasks")))
    }

    func testOpenclawReceipt() {
        let details: [String: Any] = ["status": "accepted", "mode": "run", "expectsCompletionMessage": true, "runId": "run-1"]
        XCTAssertEqual(AcpDelegationReceipt.openclaw(update("x", rawOutput: ["details": details])), "run-1")
        // details が無ければ本文（rawOutput.content か content）の JSON。
        let json = #"{"status":"accepted","mode":"run","expectsCompletionMessage":true,"runId":"run-2"}"#
        XCTAssertEqual(AcpDelegationReceipt.openclaw(update(json)), "run-2")
        XCTAssertEqual(AcpDelegationReceipt.openclaw(update("x", rawOutput: ["content": [["type": "text", "text": json]]])), "run-2")
        var session = details
        session["mode"] = "session"
        XCTAssertNil(AcpDelegationReceipt.openclaw(update("x", rawOutput: ["details": session])), "mode: session は未実測なので今まで通り")
        var noCompletion = details
        noCompletion["expectsCompletionMessage"] = false
        XCTAssertNil(AcpDelegationReceipt.openclaw(update("x", rawOutput: ["details": noCompletion])))
        var rejected = details
        rejected["status"] = "forbidden"
        XCTAssertNil(AcpDelegationReceipt.openclaw(update("x", rawOutput: ["details": rejected])))
    }

    func testGrokReceiptAndBackgroundSpawn() {
        let meta: [String: Any] = ["x.ai/tool": ["name": "spawn_subagent"], "subagentBackground": true]
        XCTAssertEqual(AcpDelegationReceipt.grokBackgroundSpawn(["_meta": meta, "rawInput": ["description": "d"]])?.description, "d")
        // rawInput.background だけでも背景。
        let plain: [String: Any] = ["x.ai/tool": ["name": "spawn_subagent"]]
        XCTAssertNotNil(AcpDelegationReceipt.grokBackgroundSpawn(["_meta": plain, "rawInput": ["background": true]]))
        XCTAssertNil(AcpDelegationReceipt.grokBackgroundSpawn(["_meta": plain, "rawInput": ["background": false]]), "前景")
        XCTAssertNil(AcpDelegationReceipt.grokBackgroundSpawn(["_meta": ["x.ai/tool": ["name": "run_terminal_command"],
                                                                         "subagentBackground": true]]))
        XCTAssertEqual(AcpDelegationReceipt.grokSubagentId("Subagent started in background.\nsubagent_id: abc-123\ndescription: x"), "abc-123")
        XCTAssertNil(AcpDelegationReceipt.grokSubagentId("Subagent finished."))
        XCTAssertNil(AcpDelegationReceipt.grokSubagentId(nil))
    }

    // MARK: 見張り

    /// 返す状態を差し替えられる偽の台帳。
    private final class StubLedger: AcpLedgerReader, @unchecked Sendable {
        private let lock = NSLock()
        private var _next: Result<[String: AcpLedgerStatus], Error>
        private var _reads = 0
        let pollInterval: TimeInterval = 0.005

        init(_ next: Result<[String: AcpLedgerStatus], Error>) { _next = next }
        func set(_ next: Result<[String: AcpLedgerStatus], Error>) { lock.lock(); _next = next; lock.unlock() }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
        func read(keys: [String]) throws -> [String: AcpLedgerStatus] {
            lock.lock(); defer { lock.unlock() }
            _reads += 1
            return try _next.get()
        }
    }

    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [AcpDelegationWatcher.Change] = []
        func add(_ c: [AcpDelegationWatcher.Change]) { lock.lock(); items += c; lock.unlock() }
        var all: [AcpDelegationWatcher.Change] { lock.lock(); defer { lock.unlock() }; return items }
        func until(_ what: String, _ match: ([AcpDelegationWatcher.Change]) -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if match(all) { return }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTFail("待ちきれなかった: \(what) / \(all)")
        }
    }

    private func entry(_ row: String, _ key: String) -> AcpDelegationWatcher.Entry {
        AcpDelegationWatcher.Entry(rowKey: row, ledgerKey: key, receiptText: "receipt-\(row)")
    }

    /// 動いている間に送るのは変化だけ。終わった行は外れ、全部終わったら止まる（それ以上読まない）。
    func testWatcherSendsOnlyChangesAndStopsWhenAllRowsFinished() async throws {
        let ledger = StubLedger(.success(["k1": .running(text: "exec", toolCalls: 1)]))
        let changes = Changes()
        let watcher = AcpDelegationWatcher(reader: ledger) { changes.add($0) }
        watcher.add(entry("row1", "k1"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(changes.all, [.activity(rowKey: "row1", text: "exec", toolCalls: 1)], "同じ状態は 1 回だけ送る")

        ledger.set(.success(["k1": .running(text: "exec", toolCalls: 2)]))
        try await changes.until("数の変化") { $0.count == 2 }
        ledger.set(.success(["k1": .finished(state: "done", result: "OK", durationMs: 5)]))
        try await changes.until("終わり") { $0.count == 3 }
        XCTAssertEqual(changes.all.last, .finished(rowKey: "row1", state: "done", result: "OK", durationMs: 5))
        try await Task.sleep(nanoseconds: 50_000_000)
        let reads = ledger.reads
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(ledger.reads, reads, "全部終わったのに読み続けた")
        XCTAssertTrue(watcher.watchedRowKeys.isEmpty)

        // 新しい行で起き直す。
        ledger.set(.success(["k2": .finished(state: "failed", result: "x", durationMs: nil)]))
        watcher.add(entry("row2", "k2"))
        try await changes.until("起き直し") { $0.count == 4 }
        watcher.stop()
    }

    func testWatcherGivesUpAfterTheFailureLimitOfTransientErrors() async throws {
        let ledger = StubLedger(.failure(AcpLedgerError.transient("busy")))
        let changes = Changes()
        let watcher = AcpDelegationWatcher(reader: ledger, failureLimit: 30) { changes.add($0) }
        watcher.add(entry("row1", "k1"))
        try await changes.until("読めない扱い") { !$0.isEmpty }
        XCTAssertEqual(changes.all, [.unreadable(rowKey: "row1", receiptText: "receipt-row1")])
        XCTAssertEqual(ledger.reads, 30, "30 回続けて失敗するまでやり直す")
    }

    func testWatcherResetsTheFailureCountOnSuccess() async throws {
        let ledger = StubLedger(.failure(AcpLedgerError.transient("busy")))
        let changes = Changes()
        let watcher = AcpDelegationWatcher(reader: ledger, failureLimit: 30) { changes.add($0) }
        watcher.add(entry("row1", "k1"))
        try await Task.sleep(nanoseconds: 60_000_000)
        ledger.set(.success(["k1": .running(text: nil, toolCalls: nil)]))
        try await Task.sleep(nanoseconds: 30_000_000)
        ledger.set(.failure(AcpLedgerError.transient("busy")))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(changes.all.isEmpty, "成功で数え直さない: \(changes.all)")
        watcher.stop()
    }

    func testWatcherUnreadableAndMissingCloseAtOnce() async throws {
        let ledger = StubLedger(.failure(AcpLedgerError.unreadable("no file")))
        let changes = Changes()
        let watcher = AcpDelegationWatcher(reader: ledger) { changes.add($0) }
        watcher.add(entry("row1", "k1"))
        watcher.add(entry("row2", "k2"))
        try await changes.until("読めない") { $0.count == 2 }
        XCTAssertEqual(ledger.reads, 1)

        ledger.set(.success(["k3": .missing]))
        watcher.add(entry("row3", "k3"))
        try await changes.until("行が無い") { $0.count == 3 }
        XCTAssertEqual(changes.all.last, .unreadable(rowKey: "row3", receiptText: "receipt-row3"))
    }

    /// 一度読めた行は、あとで読めなくなっても・台帳から消えても、すぐ受領票で done にしない（数回は待つ）。
    func testWatcherKeepsAConfirmedRowThroughUnreadableAndMissing() async throws {
        let ledger = StubLedger(.success(["k1": .running(text: nil, toolCalls: nil)]))
        let changes = Changes()
        let watcher = AcpDelegationWatcher(reader: ledger, failureLimit: 30) { changes.add($0) }
        watcher.add(entry("row1", "k1"))
        try await Task.sleep(nanoseconds: 60_000_000)
        ledger.set(.failure(AcpLedgerError.unreadable("replaced")))
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(changes.all.isEmpty, "読めた行を、1 回の失敗で閉じた: \(changes.all)")
        ledger.set(.success(["k1": .missing]))
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(changes.all.isEmpty, "読めた行を、1 回の欠けで閉じた: \(changes.all)")
        ledger.set(.success(["k1": .finished(state: "done", result: "OK", durationMs: nil)]))
        try await changes.until("台帳で終わり") { !$0.isEmpty }
        XCTAssertEqual(changes.all.last, .finished(rowKey: "row1", state: "done", result: "OK", durationMs: nil))
    }

    /// CLI で鍵ごとに失敗するとき、別の鍵が成功しても、失敗し続ける鍵は上限で諦める。
    func testWatcherCountsRetriesPerKey() async throws {
        let ledger = StubLedger(.success(["k1": .running(text: nil, toolCalls: nil), "k2": .retry]))
        let changes = Changes()
        let watcher = AcpDelegationWatcher(reader: ledger, failureLimit: 5) { changes.add($0) }
        watcher.add(entry("row1", "k1"))
        watcher.add(entry("row2", "k2"))
        try await changes.until("k2 だけ諦める") { $0.contains(.unreadable(rowKey: "row2", receiptText: "receipt-row2")) }
        XCTAssertFalse(changes.all.contains(.unreadable(rowKey: "row1", receiptText: "receipt-row1")))
        XCTAssertEqual(watcher.watchedRowKeys, ["row1"])
        watcher.stop()
    }

    /// stop のあとは台帳を読まない。
    func testWatcherStopsReading() async throws {
        let ledger = StubLedger(.success(["k1": .running(text: nil, toolCalls: nil)]))
        let watcher = AcpDelegationWatcher(reader: ledger) { _ in }
        watcher.add(entry("row1", "k1"))
        try await Task.sleep(nanoseconds: 50_000_000)
        watcher.stop()
        try await Task.sleep(nanoseconds: 30_000_000)
        let reads = ledger.reads
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(ledger.reads, reads, "stop のあとも読んでいる")
    }

    func testLedgerNumbersNeverTrap() {
        XCTAssertNil(ledgerSafeInt(.infinity))
        XCTAssertNil(ledgerSafeInt(.nan))
        XCTAssertNil(ledgerSafeInt(1e300))
        XCTAssertEqual(ledgerSafeInt(12), 12)
    }

    func testWatcherStopDropsPendingRows() async throws {
        let ledger = StubLedger(.success(["k1": .running(text: nil, toolCalls: nil)]))
        let watcher = AcpDelegationWatcher(reader: ledger) { _ in }
        watcher.add(entry("row1", "k1"))
        watcher.stop()
        XCTAssertTrue(watcher.watchedRowKeys.isEmpty)
        watcher.add(entry("row2", "k2"))
        XCTAssertTrue(watcher.watchedRowKeys.isEmpty, "stop のあとに足せない")
    }

    private final class Counter2: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private final class Flaky: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func next() -> String? {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls == 1 ? #"{"status":"running"}"# : nil
        }
    }
}
