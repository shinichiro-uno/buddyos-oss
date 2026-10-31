import XCTest
@testable import BridgeApp

// SessionHub がターンより長く動く作業（バックグラウンドのサブエージェント・コマンド・dynamic workflow）を扱う筋書き。
// 規則は docs/BACKGROUND_WORK_2026-10-21.md §3.5。WebSocket を通さず、hub の購読者として直接つなぐ。

/// SubagentTracker を持つ session。track で行を動かし、その payload を流す。hasTracker = false なら
/// subagentSnapshot を持たない（hub のミラーから全行を作る経路）。
final class BackgroundWorkSession: AgentSession, @unchecked Sendable {
    let sessionId: String
    let agentId: String
    let hasTracker: Bool
    let events: AsyncThrowingStream<SessionEvent, Error>
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private let lock = NSLock()
    private var tracker = SubagentTracker()
    private var _closed = false

    init(agentId: String, sessionId: String, hasTracker: Bool) {
        self.agentId = agentId
        self.sessionId = sessionId
        self.hasTracker = hasTracker
        var cont: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { cont = $0 }
        self.continuation = cont
    }

    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    var epoch: String { lock.lock(); defer { lock.unlock() }; return tracker.epoch }

    /// トラッカーを動かし、変わった行の payload を流す。
    func track(_ change: (inout SubagentTracker) -> String?) {
        lock.lock()
        let payload = change(&tracker)
        lock.unlock()
        if let payload { emit(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: payload)) }
    }

    func emit(_ event: SessionEvent) { continuation.yield(event) }

    func delta(_ text: String, _ mid: String) {
        emit(.assistantDelta(text, agentId: agentId, sessionId: sessionId, messageId: mid))
    }

    func done(_ mid: String, origin: String? = nil) {
        emit(SessionEvent(type: .done, agentId: agentId, sessionId: sessionId, messageId: mid, toolUseId: nil,
                          content: nil, toolName: nil, metadata: origin.map { ["origin": $0] }))
    }

    func done(_ mid: String, metadata: [String: String]) {
        emit(SessionEvent(type: .done, agentId: agentId, sessionId: sessionId, messageId: mid, toolUseId: nil,
                          content: nil, toolName: nil, metadata: metadata))
    }

    /// 知らせのターンが開いた（Claude の spawn 経路は、本文の前に空の activity を出す）。
    func opened(_ mid: String) {
        emit(.activity(agentId: agentId, sessionId: sessionId, messageId: mid, text: ""))
    }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {}

    func subagentSnapshot() async -> String? {
        guard hasTracker else { return nil }
        return lock.withLock { tracker.snapshot(includeEmpty: true) }
    }

    func close() async {
        lock.withLock { _closed = true }
        continuation.finish()
    }
}

final class BackgroundWorkAdapter: AgentAdapter {
    let id: String
    let displayName = "Background"
    let hasTracker: Bool
    var listed: [SessionSummary] = []
    private let lock = NSLock()
    private var _sessions: [BackgroundWorkSession] = []

    init(id: String, hasTracker: Bool = true) {
        self.id = id
        self.hasTracker = hasTracker
    }

    var sessions: [BackgroundWorkSession] { lock.lock(); defer { lock.unlock() }; return _sessions }

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        let s = BackgroundWorkSession(agentId: id, sessionId: sessionId ?? "\(id)-new", hasTracker: hasTracker)
        lock.withLock { _sessions.append(s) }
        return s
    }

    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] { listed }
    func loadHistory(sessionId: String) async -> [HistoryMessage] { [] }
}

/// SessionHub が出した完了の push（kind "chat"）を控える（SessionHub.chatPushObserver）。
final class ChatPushRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(agentId: String, body: String)] = []

    var observer: @Sendable (String, String, String) -> Void {
        { [weak self] agentId, _, body in self?.add(agentId, body) }
    }

    private func add(_ agentId: String, _ body: String) {
        lock.lock(); items.append((agentId, body)); lock.unlock()
    }

    func bodies(_ agentId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return items.filter { $0.agentId == agentId }.map(\.body)
    }

    func until(_ agentId: String, count: Int, timeout: TimeInterval = 5,
               file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while bodies(agentId).count < count, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThanOrEqual(bodies(agentId).count, count, "push が届かなかった: \(bodies(agentId))", file: file, line: line)
    }
}

/// hub の購読者 1 人分。届いた出来事を控える。
final class HubListener: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var _events: [SessionEvent] = []

    var events: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func clear() { lock.lock(); _events.removeAll(); lock.unlock() }
    var send: @Sendable (SessionEvent) -> Void { { [weak self] e in self?.append(e) } }
    private func append(_ e: SessionEvent) { lock.lock(); _events.append(e); lock.unlock() }

    @discardableResult
    func until(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
               _ match: (SessionEvent) -> Bool) async throws -> SessionEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = events.first(where: match) { return hit }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("待ちきれなかった: \(what) / 届いた種別 \(events.map(\.type.rawValue))", file: file, line: line)
        throw CancellationError()
    }
}

final class SessionHubBackgroundTests: XCTestCase {
    private let pushes = ChatPushRecorder()

    override func setUp() async throws {
        SessionHub.chatPushObserver = pushes.observer
    }

    override func tearDown() async throws {
        SessionHub.chatPushObserver = nil
        await SessionHub.shared.setOwedPushGraceForTesting(120)
    }

    private func uniq(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())" }

    private func obj(_ json: String?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((json ?? "{}").utf8))) as? [String: Any] ?? [:]
    }

    private func isSnapshot(_ e: SessionEvent, taskId: String = "subagents") -> Bool {
        let o = obj(e.content)
        return e.type == .workflowProgress && o["subtype"] as? String == "workflow_snapshot" && o["taskId"] as? String == taskId
    }

    private func rowIds(_ e: SessionEvent) -> [String] {
        ((obj(e.content)["agents"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
    }

    private func acquire(_ adapter: BackgroundWorkAdapter, _ sid: String, _ listener: HubListener) async -> BackgroundWorkSession {
        let session = await SessionHub.shared.acquire(agentId: adapter.id, sessionId: sid, cwd: nil, adapter: adapter,
                                                      subscriberId: listener.id, send: listener.send)
        return session as! BackgroundWorkSession
    }

    /// 少し待っても閉じられていないこと。
    private func assertStaysOpen(_ session: BackgroundWorkSession, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(session.closed, message, file: file, line: line)
    }

    private func waitClosed(_ session: BackgroundWorkSession, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !session.closed && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(session.closed, "閉じられなかった", file: file, line: line)
    }

    // MARK: - Live Activity の数（§8.2）

    private final class LARecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _counts: [[String: Int]] = []
        private var _finished: [[Int]] = []
        var counts: [[String: Int]] { lock.withLock { _counts } }
        var finished: [[Int]] { lock.withLock { _finished } }
        var observer: SessionHub.LiveActivityObserver {
            SessionHub.LiveActivityObserver(
                report: { [weak self] c in self?.lock.withLock { self?._counts.append(c) } },
                finished: { [weak self] d, f, s in self?.lock.withLock { self?._finished.append([d, f, s]) } })
        }
        func last(_ sid: String) -> Int? { counts.last(where: { $0[sid] != nil || $0.isEmpty })?[sid] }
    }

    /// 生成中は background の行だけ、生成中でなければ動いている行の全部を数える。終わった行は同じ規則で終わりの数に渡し、
    /// entry を外したときは数えていた分を stopped で 1 回だけ渡す。
    func testLiveActivityCountsFollowGeneratingAndRemoveEntryCountsStoppedOnce() async throws {
        let recorder = LARecorder()
        SessionHub.liveActivityObserver = recorder.observer
        defer { SessionHub.liveActivityObserver = nil }
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        session.track { $0.begin(key: "fg", label: "前景", agentType: "Explore", background: false) }
        session.track { $0.begin(key: "bg", label: "背景", agentType: "Explore", background: true) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.last(sid), 1, "生成中は background の行だけ")
        // 前景の行が生成中に終わっても、終わりの数には渡さない。
        session.track { $0.finish(key: "fg", state: "done", result: "ok") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(recorder.finished.isEmpty, "生成中の前景の終わりは数えない: \(recorder.finished)")
        session.done("m1")
        try await listener.until("done") { $0.type == .done }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.last(sid), 1, "done の後は動いている行の全部（前景は終わっている）")
        // 閉じる: 数えていた 1 件は stopped で 1 回。
        _ = await SessionHub.shared.closeSession(agentId: adapter.id, sessionId: sid)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.finished.reduce(0) { $0 + $1[2] }, 1, "stopped は 1 回だけ: \(recorder.finished)")
        XCTAssertNil(recorder.counts.last?[sid])
    }

    // MARK: - 再接続のスナップショットと閉じない条件

    func testBackgroundAgentSurvivesReleaseAndReconnectGetsRowsBeforeDone() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let first = HubListener()
        let session = await acquire(adapter, sid, first)
        // 新しい entry でも、トラッカーの全行（行が無くても epoch 付き）を渡す。
        let fresh = try await first.until("fresh snapshot") { self.isSnapshot($0) }
        XCTAssertEqual(obj(fresh.content)["epoch"] as? String, session.epoch)
        XCTAssertEqual(rowIds(fresh), [])

        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        session.track { $0.begin(key: "a1", label: "Explore auth", agentType: "Explore", background: true) }
        session.delta("2 つのエージェントで調べています。", "m1")
        session.done("m1")
        try await first.until("done m1") { $0.type == .done && $0.messageId == "m1" }
        let generating = await SessionHub.shared.generatingSessionIds(agentId: adapter.id)
        XCTAssertFalse(generating.contains(sid))
        let background = await SessionHub.shared.backgroundSessionIds(agentId: adapter.id)
        XCTAssertTrue(background.contains(sid))

        // 見る人がいなくなっても、バックグラウンドのサブエージェントが動いている間は閉じない。
        await SessionHub.shared.release(subscriberId: first.id)
        try await assertStaysOpen(session, "動いているサブエージェントごと閉じた")

        // 戻ってきた購読者には、idle でも全行（kind・epoch 付き）を done より先に渡す。
        let second = HubListener()
        let again = await acquire(adapter, sid, second)
        XCTAssertTrue(again === session, "同じ entry に付く")
        let snap = try await second.until("snapshot") { self.isSnapshot($0) }
        let snapObj = obj(snap.content)
        XCTAssertEqual(snapObj["kind"] as? String, "subagents")
        XCTAssertEqual(snapObj["epoch"] as? String, session.epoch)
        XCTAssertEqual(rowIds(snap), ["a1"])
        try await second.until("done re-send") { $0.type == .done && $0.messageId == "m1" }
        let order = second.events
        let snapIndex = try XCTUnwrap(order.firstIndex { self.isSnapshot($0) })
        let doneIndex = try XCTUnwrap(order.firstIndex { $0.type == .done })
        XCTAssertLessThan(snapIndex, doneIndex, "done の時点でバックグラウンドの作業が分かるように、カードを先に送る")
        XCTAssertFalse(order.contains { $0.type == .turnResume })

        // アイドル中の終わりの知らせは phase も generating も変えない。
        session.track { $0.finish(key: "a1", state: "done", result: "原因は X") }
        try await second.until("row done") {
            $0.type == .workflowProgress && (self.obj($0.content)["agents"] as? [[String: Any]])?.first?["state"] as? String == "done"
        }
        let stillIdle = await SessionHub.shared.generatingSessionIds(agentId: adapter.id)
        XCTAssertFalse(stillIdle.contains(sid))

        // 知らせのターン → done。終わった行はカードに残す（次の新しいターンで捨てる）。
        session.delta("原因は X でした。", "m2")
        session.done("m2", origin: "task-notification")
        try await second.until("done m2") { $0.type == .done && $0.messageId == "m2" }
        second.clear()
        await SessionHub.shared.requestTurnStatus(agentId: adapter.id, sessionId: sid, send: second.send)
        let probe = try await second.until("probe snapshot") { self.isSnapshot($0) }
        XCTAssertEqual(rowIds(probe), ["a1"])
        XCTAssertEqual((obj(probe.content)["agents"] as? [[String: Any]])?.first?["state"] as? String, "done")
        let afterBackground = await SessionHub.shared.backgroundSessionIds(agentId: adapter.id)
        XCTAssertFalse(afterBackground.contains(sid))

        // 作業が終わった後は、見る人がいなくなれば閉じる。
        await SessionHub.shared.release(subscriberId: second.id)
        try await waitClosed(session)
    }

    func testDoneWithoutSubscribersWaitsForBackgroundAgentThenCloses() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        // 生成中に見る人がいなくなる（iPhone を閉じた）。
        await SessionHub.shared.release(subscriberId: listener.id)
        try await assertStaysOpen(session, "生成中に閉じた")

        // 親のターンはバックグラウンドのサブエージェントを起こしただけで終わる。
        session.track { $0.begin(key: "a1", label: "調査", background: true) }
        session.delta("バックグラウンドで調べています。", "m1")
        session.done("m1")
        try await assertStaysOpen(session, "done の後、動いているサブエージェントごと閉じた")

        // 作業が終わり、知らせのターンの done で閉じる。
        session.track { $0.finish(key: "a1", state: "done", result: "見つかりました") }
        session.delta("結論: 見つかりました。", "m2")
        session.done("m2", origin: "task-notification")
        try await waitClosed(session)
    }

    /// 送った発話が CLI の待ち行列にある間に知らせのターンが終わっても（done の metadata.origin = task-notification、
    /// outstandingPrompts > 0）、ターンの終わりにしない。生成中（考え中）のまま、予約も実行せず、見る人がいなくても閉じない。
    /// 終わった行も捨てない。その発話の done で、ふつうに終わる（予約を実行する）。
    func testNotificationDoneWhileOwnPromptIsQueuedKeepsTurnRunning() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        // 前のターンでバックグラウンドのサブエージェントを起こした。
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        session.track { $0.begin(key: "a1", label: "調査", background: true) }
        session.delta("裏で調べています。", "m1")
        session.done("m1")
        try await listener.until("done m1") { $0.type == .done && $0.messageId == "m1" }

        // アイドルで次の発話を送った直後に、CLI が先に知らせのターンを始める（発話は CLI の待ち行列に残る）。
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        let queued = SessionHub.QueuedMessage(clientMessageId: uniq("q"), content: "そのあとで", skills: [], attachments: [])
        let accepted = await SessionHub.shared.enqueue(agentId: adapter.id, sessionId: sid, message: queued)
        XCTAssertTrue(accepted, "生成中なので予約に積む")
        session.track { $0.finish(key: "a1", state: "done", result: "見つかりました") }
        session.delta("調査が終わりました。", "n1")
        session.done("n1", origin: "task-notification")
        try await listener.until("done n1") { $0.type == .done && $0.messageId == "n1" }

        let generating = await SessionHub.shared.generatingSessionIds(agentId: adapter.id)
        XCTAssertTrue(generating.contains(sid), "知らせのターンの done で、待ち行列の発話のターンまで終わりにした")
        XCTAssertFalse(listener.events.contains { $0.type == .queueDispatched }, "知らせのターンの done で予約を実行した")
        listener.clear()
        await SessionHub.shared.requestTurnStatus(agentId: adapter.id, sessionId: sid, send: listener.send)
        let resume = try await listener.until("turn_resume") { $0.type == .turnResume }
        XCTAssertEqual(resume.metadata?["phase"], "thinking", "次は送った発話の返事を待つ")
        let probe = try XCTUnwrap(listener.events.first { self.isSnapshot($0) })
        XCTAssertEqual(rowIds(probe), ["a1"], "知らせのターンでは終わった行を捨てない")

        // 見る人がいなくなっても、送った発話のターンが残っているので閉じない。
        await SessionHub.shared.release(subscriberId: listener.id)
        try await assertStaysOpen(session, "待ち行列の発話ごと閉じた")

        // 送った発話の返事と done。ここでターンが終わり、予約を実行する（生成中のまま次のターンへ）。
        session.delta("ご質問の答えです。", "x1")
        session.done("x1")
        let deadline = Date().addingTimeInterval(5)
        var queueLeft = true
        while queueLeft, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            queueLeft = await SessionHub.shared.snapshot().first { $0.agentId == adapter.id && $0.sessionId == sid }?.queued != 0
        }
        XCTAssertFalse(queueLeft, "送った発話の done で予約を実行しなかった")
        XCTAssertFalse(session.closed, "予約を実行したのに閉じた")
        session.done("q1")
        try await waitClosed(session)
    }

    func testBackgroundShellAloneKeepsSessionOpen() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        session.track { $0.begin(key: "b1", label: "npm run dev", background: true, rowKind: "shell", tool: "Bash") }
        session.delta("起動しました。", "m1")
        session.done("m1")
        try await listener.until("done") { $0.type == .done }
        await SessionHub.shared.release(subscriberId: listener.id)
        try await assertStaysOpen(session, "dev サーバーごと閉じた")
        // コマンドだけでは一覧の background を載せない（dev サーバーは終わらないので、ずっと稼働中に見えてしまう）。
        let background = await SessionHub.shared.backgroundSessionIds(agentId: adapter.id)
        XCTAssertFalse(background.contains(sid))
        let shells = await SessionHub.shared.anyBackgroundSessionIdsForTesting(agentId: adapter.id)
        XCTAssertTrue(shells.contains(sid))

        session.track { $0.finish(key: "b1", state: "stopped", result: nil) }
        // ミラーに届くまで待つ（pump が配った後）。
        let deadline = Date().addingTimeInterval(5)
        while await SessionHub.shared.anyBackgroundSessionIdsForTesting(agentId: adapter.id).contains(sid), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let after = await SessionHub.shared.anyBackgroundSessionIdsForTesting(agentId: adapter.id)
        XCTAssertFalse(after.contains(sid))
        // 終わった後は sweep（60 秒ごと）か次の done で閉じる。ここでは次の購読者の出入りで確かめる。
        let other = HubListener()
        _ = await acquire(adapter, sid, other)
        await SessionHub.shared.release(subscriberId: other.id)
        try await waitClosed(session)
    }

    // MARK: - 完了の push

    /// 生成中に見る人がいなくなり、親のターンはバックグラウンドの子を起こしただけで終わる。子が終わっても親は起きない
    /// （Codex の multi-agent v2。知らせのターンの done が来ない）。作業が無くなってから猶予の間に何も始まらなければ、
    /// done のときに出さなかった push を、そのターンの最後の吹き出しで出し、閉じる。
    func testHeldPushIsSentWhenNoWakeTurnFollows() async throws {
        await SessionHub.shared.setOwedPushGraceForTesting(0.3)
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        await SessionHub.shared.release(subscriberId: listener.id)

        session.track { $0.begin(key: "c1", label: "調査", background: true) }
        session.delta("子に調べてもらっています。", "m1")
        session.done("m1")
        try await assertStaysOpen(session, "動いている子ごと閉じた")
        XCTAssertEqual(pushes.bodies(adapter.id), [], "子が動いている間に push した")

        session.track { $0.finish(key: "c1", state: "done", result: "見つかりました") }
        try await pushes.until(adapter.id, count: 1)
        XCTAssertEqual(pushes.bodies(adapter.id), ["子に調べてもらっています。"])
        try await waitClosed(session)
    }

    /// 作業が終わった後の知らせのターン（開いたときの activity → 本文 → done）が、預かった push を引き継ぐ。push は結論で 1 回だけ。
    func testWakeTurnTakesOverHeldPush() async throws {
        await SessionHub.shared.setOwedPushGraceForTesting(0.3)
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        await SessionHub.shared.release(subscriberId: listener.id)
        session.track { $0.begin(key: "a1", label: "調査", background: true) }
        session.delta("Explore で調べています。", "m1")
        session.done("m1")

        session.track { $0.finish(key: "a1", state: "done", result: "原因は X") }
        session.opened("n1")
        session.delta("結論: 原因は X でした。", "n1")
        session.done("n1", origin: "task-notification")
        try await waitClosed(session)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(pushes.bodies(adapter.id), ["結論: 原因は X でした。"])
    }

    /// 本文の無い知らせのターン（silent の done）は、自分の push（「新しい応答があります」）を出さない。作業は全部終わり、
    /// もっと良い本文は来ないので、預かった push を猶予を待たずにその done で出す（猶予は既定の 120 秒のまま）。
    func testSilentWakeTurnDoesNotPushButHeldPushIsSent() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        await SessionHub.shared.release(subscriberId: listener.id)
        session.track { $0.begin(key: "b1", label: "sleep 20", background: true) }
        session.delta("裏で動かしています。", "m1")
        session.done("m1")

        session.track { $0.finish(key: "b1", state: "done", result: nil) }
        session.opened("n1")
        session.done("n1", metadata: ["origin": "task-notification", "silent": "1"])
        try await pushes.until(adapter.id, count: 1)
        try await waitClosed(session)
        XCTAssertEqual(pushes.bodies(adapter.id), ["裏で動かしています。"], "本文の無い done で「新しい応答があります」を出した")
    }

    /// ACP の非同期の委任（Hermes・OpenClaw・Grok の will_wake でない子）は、台帳か通知で最後の行が閉じたとき、
    /// 開いたときの activity なしで、本文の無い知らせのターンの done（origin = task-notification・silent）だけを出す。
    /// 預かった push は、その done で猶予（既定 120 秒）を待たずに出て、閉じる。「新しい応答があります」は出さない。
    func testSilentDoneWithoutOpeningActivityReleasesHeldPush() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("acp"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        await SessionHub.shared.release(subscriberId: listener.id)
        session.track { $0.begin(key: "d1", label: "調査", background: true) }
        session.delta("子に任せました。", "m1")
        session.done("m1")
        try await assertStaysOpen(session, "動いている子ごと閉じた")
        XCTAssertEqual(pushes.bodies(adapter.id), [], "子が動いている間に push した")

        session.track { $0.finish(key: "d1", state: "done", result: "OK") }
        session.done("n1", metadata: ["origin": "task-notification", "silent": "1"])
        try await pushes.until(adapter.id, count: 1)
        try await waitClosed(session)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(pushes.bodies(adapter.id), ["子に任せました。"])
    }

    /// adapter が、まだ始まっていない発話が残っている done（metadata.pending = "1"）を出した（最後の文を生成中に差し込んだ
    /// 発話は、今のターンに合流せず result の後に回る）。ターンの終わりにしない（閉じない・push しない・予約も実行しない）。
    /// その発話の done で、ふつうに終わる（push はその返事で 1 回）。
    func testDoneWithPromptStillQueuedKeepsTheSessionOpen() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        session.delta("最初の返事の途中", "a1")
        // 生成中に 2 通目を差し込み、アプリを閉じた。
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        await SessionHub.shared.release(subscriberId: listener.id)

        session.done("a1", metadata: ["pending": "1"])
        try await assertStaysOpen(session, "まだ始まっていない発話ごと閉じた")
        let generating = await SessionHub.shared.generatingSessionIds(agentId: adapter.id)
        XCTAssertTrue(generating.contains(sid), "待っている発話があるのに、ターンを終わりにした")
        XCTAssertEqual(pushes.bodies(adapter.id), [], "待っている発話の前に push した")

        session.delta("2 通目の返事", "b1")
        session.done("b1")
        try await waitClosed(session)
        XCTAssertEqual(pushes.bodies(adapter.id), ["2 通目の返事"])
    }

    /// 送った発話が CLI の待ち行列にある間に閉じた知らせのターンの done では push しない（その発話の done で 1 回。
    /// 本文はその発話の返事。Windows と同じ）。
    func testHeldNotificationDonePushesOnceWithTheReply() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        await SessionHub.shared.release(subscriberId: listener.id)
        session.track { $0.begin(key: "a1", label: "調査", background: true) }
        session.delta("裏で調べています。", "m1")
        session.done("m1")
        session.track { $0.finish(key: "a1", state: "done", result: "見つかりました") }
        try await assertStaysOpen(session, "預かった push ごと閉じた")

        // アイドルで次の発話を送った直後に、CLI が先に知らせのターンを回す（発話は CLI の待ち行列に残る）。
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        session.delta("調査が終わりました。", "n1")
        session.done("n1", origin: "task-notification")
        session.delta("ご質問の答えです。", "x1")
        session.done("x1")
        try await waitClosed(session)
        XCTAssertEqual(pushes.bodies(adapter.id), ["ご質問の答えです。"])
    }

    /// 送った発話が待ち行列にある間の知らせのターンの done は、adapter が pending を付けなくても（Codex・OpenCode）、hub が
    /// pending = "1" を付けて流す。その発話の done には付けない。
    func testHeldNotificationDoneIsStampedPendingForSubscribers() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("bg"))
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        session.opened("n1")
        session.delta("調査が終わりました。", "n1")
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        session.done("n1", origin: "task-notification")
        let held = try await listener.until("知らせのターンの done") { $0.type == .done && $0.messageId == "n1" }
        XCTAssertEqual(held.metadata?["pending"], "1")
        XCTAssertEqual(held.metadata?["origin"], "task-notification")

        session.delta("ご質問の答えです。", "x1")
        session.done("x1")
        let own = try await listener.until("発話の done") { $0.type == .done && $0.messageId == "x1" }
        XCTAssertNil(own.metadata?["pending"])
    }

    func testStampingPendingOnlyForHeldNotificationDone() {
        func done(_ metadata: [String: String]?) -> SessionEvent {
            SessionEvent(type: .done, agentId: "a", sessionId: "s", messageId: "m", toolUseId: nil,
                         content: nil, toolName: nil, metadata: metadata)
        }
        let notification = ["origin": "task-notification"]
        XCTAssertEqual(SessionHub.stampingPending(done(notification), outstandingPrompts: 1).metadata?["pending"], "1")
        XCTAssertNil(SessionHub.stampingPending(done(notification), outstandingPrompts: 0).metadata?["pending"])
        XCTAssertNil(SessionHub.stampingPending(done(nil), outstandingPrompts: 2).metadata?["pending"])
        let delta = SessionEvent.assistantDelta("x", agentId: "a", sessionId: "s", messageId: "m")
        XCTAssertNil(SessionHub.stampingPending(delta, outstandingPrompts: 1).metadata?["pending"])
    }

    // MARK: - ミラー（subagentSnapshot を持たない session）

    func testIdleWorkflowProgressDoesNotStartTurnAndUnfinishedWorkflowIsReplayed() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("mirror"), hasTracker: false)
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        session.delta("Workflow を起動しました。", "m1")
        session.done("m1")
        try await listener.until("done") { $0.type == .done }

        // ターンの後に届く dynamic workflow の進み具合。考え中に戻さない。
        session.emit(.workflowProgress(agentId: adapter.id, sessionId: sid, payloadJSON:
            #"{"subtype":"task_started","taskId":"wf1","workflowName":"review","status":"running"}"#))
        try await listener.until("workflow") { $0.type == .workflowProgress && self.obj($0.content)["taskId"] as? String == "wf1" }
        let generating = await SessionHub.shared.generatingSessionIds(agentId: adapter.id)
        XCTAssertFalse(generating.contains(sid))

        listener.clear()
        await SessionHub.shared.requestTurnStatus(agentId: adapter.id, sessionId: sid, send: listener.send)
        try await listener.until("probe done") { $0.type == .done }
        XCTAssertFalse(listener.events.contains { $0.type == .turnResume })
        XCTAssertTrue(listener.events.contains { self.isSnapshot($0, taskId: "wf1") }, "終わっていない workflow は idle でも再生する")
        XCTAssertFalse(listener.events.contains { self.isSnapshot($0) }, "subagents のカードが無ければ送らない")

        // 終わった workflow は done で捨て、idle では再生しない。
        session.emit(.workflowProgress(agentId: adapter.id, sessionId: sid, payloadJSON:
            #"{"subtype":"task_notification","taskId":"wf1","status":"completed"}"#))
        session.delta("レビューが終わりました。", "m2")
        session.done("m2", origin: "task-notification")
        try await listener.until("done m2") { $0.type == .done && $0.messageId == "m2" }
        listener.clear()
        await SessionHub.shared.requestTurnStatus(agentId: adapter.id, sessionId: sid, send: listener.send)
        try await listener.until("probe done 2") { $0.type == .done }
        XCTAssertFalse(listener.events.contains { self.isSnapshot($0, taskId: "wf1") })
        await SessionHub.shared.release(subscriberId: listener.id)
        try await waitClosed(session)
    }

    func testNewTurnPrunesFinishedRowsFromMirror() async throws {
        let adapter = BackgroundWorkAdapter(id: uniq("mirror"), hasTracker: false)
        let sid = uniq("s")
        let listener = HubListener()
        let session = await acquire(adapter, sid, listener)
        var t = SubagentTracker()
        func publish(_ payload: String?) {
            if let payload { session.emit(.workflowProgress(agentId: adapter.id, sessionId: sid, payloadJSON: payload)) }
        }
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        publish(t.begin(key: "a1", label: "動いている", background: true))
        publish(t.begin(key: "a2", label: "終わった"))
        publish(t.finish(key: "a2", state: "done", result: "ok"))
        session.delta("ok", "m1")
        session.done("m1")
        try await listener.until("done") { $0.type == .done }

        // done では消さない（終わった行も知らせのターンまで残す）。
        listener.clear()
        await SessionHub.shared.requestTurnStatus(agentId: adapter.id, sessionId: sid, send: listener.send)
        let idle = try await listener.until("snapshot") { self.isSnapshot($0) }
        XCTAssertEqual(rowIds(idle), ["a1", "a2"])
        XCTAssertEqual(obj(idle.content)["epoch"] as? String, t.epoch)

        // 生成中でない送信は新しいターン: 終わった行を捨て、動いている行は残す。
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        listener.clear()
        await SessionHub.shared.requestTurnStatus(agentId: adapter.id, sessionId: sid, send: listener.send)
        let midTurn = try await listener.until("snapshot mid-turn") { self.isSnapshot($0) }
        XCTAssertEqual(rowIds(midTurn), ["a1"])
        XCTAssertTrue(listener.events.contains { $0.type == .turnResume })

        // 差し込み（生成中の送信）は今のターンに合流するので捨てない。
        publish(t.begin(key: "a3", label: "もう 1 つ"))
        publish(t.finish(key: "a3", state: "done", result: nil))
        try await listener.until("a3 done") {
            $0.type == .workflowProgress && (self.obj($0.content)["agents"] as? [[String: Any]])?.first?["id"] as? String == "a3"
                && (self.obj($0.content)["agents"] as? [[String: Any]])?.first?["state"] as? String == "done"
        }
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: sid)
        listener.clear()
        await SessionHub.shared.requestTurnStatus(agentId: adapter.id, sessionId: sid, send: listener.send)
        let injected = try await listener.until("snapshot after injection") { self.isSnapshot($0) }
        XCTAssertEqual(rowIds(injected), ["a1", "a3"])

        publish(t.finish(key: "a1", state: "done", result: nil))
        session.done("m2")
        try await listener.until("done m2") { $0.type == .done && $0.messageId == "m2" }
        await SessionHub.shared.release(subscriberId: listener.id)
        try await waitClosed(session)
    }
}
