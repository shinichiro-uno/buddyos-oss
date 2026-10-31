import XCTest
@testable import BridgeApp

/// stop_task_request / stop_task_result（docs/BACKGROUND_CONTROL_2026-10-21.md §3.3）。

/// stopTask の結果を台本で決める session。delay が長いと timeout になる。
private final class StopScriptedSession: AgentSession, @unchecked Sendable {
    let sessionId = "sid-stop"
    let events = AsyncThrowingStream<SessionEvent, Error> { _ in }
    private let lock = NSLock()
    private var _requests: [StopTaskRequest] = []
    var outcome: StopTaskOutcome = .stopped
    var delay: TimeInterval = 0
    /// true だと取り消されても delay が過ぎるまで戻らない（取り消しを無視する stopTask）。
    var ignoresCancel = false

    var requests: [StopTaskRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {}
    func close() async {}

    func stopTask(_ request: StopTaskRequest) async -> StopTaskOutcome {
        lock.lock(); _requests.append(request); lock.unlock()
        if ignoresCancel {
            let end = Date().addingTimeInterval(delay)
            while Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
        } else if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return outcome
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SessionEvent] = []
    var events: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func add(_ e: SessionEvent) { lock.lock(); _events.append(e); lock.unlock() }
}

final class StopTaskProtocolTests: XCTestCase {
    func testOutcomeToMetadata() {
        let cases: [(StopTaskOutcome, String, String)] = [
            (.stopped, "stopped", "1"), (.notRunning, "not_running", "1"), (.stale, "stale", "1"),
            (.unsupported(nil), "unsupported", "0"), (.failed("boom"), "failed", "0"), (.timeout, "timeout", "0"),
        ]
        for (outcome, reason, ok) in cases {
            let e = SessionEvent.stopTaskResult(agentId: "claude", sessionId: "s", requestId: "r1", taskId: "subagents",
                                                rowId: "row", outcome: outcome)
            XCTAssertEqual(e.type, .stopTaskResult)
            XCTAssertEqual(e.messageId, "r1")
            XCTAssertEqual(e.metadata?["requestId"], "r1")
            XCTAssertEqual(e.metadata?["taskId"], "subagents")
            XCTAssertEqual(e.metadata?["rowId"], "row")
            XCTAssertEqual(e.metadata?["reason"], reason)
            XCTAssertEqual(e.metadata?["ok"], ok)
        }
    }

    func testMessageIsClippedTo200AndOnlyForFailures() {
        let long = String(repeating: "あ", count: 300)
        let failed = SessionEvent.stopTaskResult(agentId: "claude", sessionId: "s", requestId: "r", taskId: "t",
                                                 rowId: nil, outcome: .failed(long))
        XCTAssertEqual(failed.metadata?["message"]?.count, 200)
        XCTAssertNil(failed.metadata?["rowId"])
        let unsupported = SessionEvent.stopTaskResult(agentId: "claude", sessionId: "s", requestId: "r", taskId: "t",
                                                      rowId: nil, outcome: .unsupported("no"))
        XCTAssertEqual(unsupported.metadata?["message"], "no")
        let stopped = SessionEvent.stopTaskResult(agentId: "claude", sessionId: "s", requestId: "r", taskId: "t",
                                                  rowId: nil, outcome: .stopped)
        XCTAssertNil(stopped.metadata?["message"])
        let empty = SessionEvent.stopTaskResult(agentId: "claude", sessionId: "s", requestId: "r", taskId: "t",
                                                rowId: nil, outcome: .failed(""))
        XCTAssertNil(empty.metadata?["message"])
    }

    func testBackgroundWorkStateHasNoAgentOrSession() {
        let e = SessionEvent.backgroundWorkState("{\"v\":1}")
        XCTAssertEqual(e.type, .backgroundWorkState)
        XCTAssertNil(e.agentId)
        XCTAssertNil(e.sessionId)
        XCTAssertEqual(e.content, "{\"v\":1}")
    }

    func testBgSessionEventBuilders() {
        let item = SessionEvent.bgSessionItem(json: "{}", sessionId: "abc")
        XCTAssertEqual(item.type, .bgSessionItem)
        XCTAssertEqual(item.sessionId, "abc")
        XCTAssertEqual(SessionEvent.bgSessionListEnd(count: 3).metadata?["count"], "3")
        XCTAssertEqual(SessionEvent.bgSessionChanged(json: "{}", sessionId: "abc").type, .bgSessionChanged)
        let r = SessionEvent.bgSessionResult(op: "stop", ok: true, id: "dceba663", shells: 2, sessionId: "abc", content: "x")
        XCTAssertEqual(r.metadata, ["op": "stop", "ok": "1", "id": "dceba663", "shells": "2"])
        XCTAssertEqual(r.content, "x")
    }

    func testSessionWithoutStopTaskIsUnsupported() async {
        let session = ScriptedSession(agentId: "echo", sessionId: "s1")
        let outcome = await session.stopTask(StopTaskRequest(taskId: "subagents", rowId: "r", epoch: "e"))
        XCTAssertEqual(outcome, .unsupported(nil))
    }

    func testRunStopTaskReportsStoppedOnlyToTheRequester() async {
        let session = StopScriptedSession()
        let box = EventBox()
        await WebSocketServer.runStopTask(
            agentId: "claude", sessionId: session.sessionId, requestId: "req-1",
            request: StopTaskRequest(taskId: "subagents", rowId: "row-1", epoch: "ep"),
            session: session, send: { box.add($0) })
        XCTAssertEqual(session.requests, [StopTaskRequest(taskId: "subagents", rowId: "row-1", epoch: "ep")])
        let events = box.events
        XCTAssertEqual(events.map(\.type), [.stopTaskResult])
        XCTAssertEqual(events[0].metadata?["reason"], "stopped")
        XCTAssertEqual(events[0].messageId, "req-1")
    }

    func testRunStopTaskWithoutSessionSendsTurnStatusBeforeNotRunning() async {
        let box = EventBox()
        await WebSocketServer.runStopTask(
            agentId: "claude", sessionId: "no-such-session", requestId: "req-2",
            request: StopTaskRequest(taskId: "subagents", rowId: "row-1", epoch: "ep"),
            session: nil, send: { box.add($0) })
        let events = box.events
        XCTAssertEqual(events.map(\.type), [.workflowProgress, .done, .stopTaskResult])
        XCTAssertEqual(events[2].metadata?["reason"], "not_running")
        XCTAssertEqual(events[2].metadata?["ok"], "1")
    }

    func testRunStopTaskStaleAlsoSendsTurnStatusFirst() async {
        let session = StopScriptedSession()
        session.outcome = .stale
        let box = EventBox()
        await WebSocketServer.runStopTask(
            agentId: "claude", sessionId: "no-such-session", requestId: "req-3",
            request: StopTaskRequest(taskId: "subagents", rowId: "row-1", epoch: "old"),
            session: session, send: { box.add($0) })
        let events = box.events
        XCTAssertEqual(events.last?.type, .stopTaskResult)
        XCTAssertEqual(events.last?.metadata?["reason"], "stale")
        XCTAssertEqual(events.count, 3)
    }

    func testRunStopTaskTimesOut() async {
        let session = StopScriptedSession()
        session.delay = 5
        let box = EventBox()
        let started = Date()
        await WebSocketServer.runStopTask(
            agentId: "claude", sessionId: session.sessionId, requestId: "req-4",
            request: StopTaskRequest(taskId: "t", rowId: nil, epoch: nil),
            session: session, send: { box.add($0) }, timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(box.events.map(\.type), [.stopTaskResult])
        XCTAssertEqual(box.events[0].metadata?["reason"], "timeout")
        XCTAssertEqual(box.events[0].metadata?["ok"], "0")
    }

    func testRunStopTaskTimesOutEvenWhenStopTaskIgnoresCancellation() async {
        let session = StopScriptedSession()
        session.delay = 3
        session.ignoresCancel = true
        let box = EventBox()
        let started = Date()
        await WebSocketServer.runStopTask(
            agentId: "claude", sessionId: session.sessionId, requestId: "req-4b",
            request: StopTaskRequest(taskId: "t", rowId: nil, epoch: nil),
            session: session, send: { box.add($0) }, timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(box.events.map(\.type), [.stopTaskResult])
        XCTAssertEqual(box.events[0].metadata?["reason"], "timeout")
    }

    func testUnsupportedDoesNotRequestTurnStatus() async {
        let session = ScriptedSession(agentId: "echo", sessionId: "s1")
        let box = EventBox()
        await WebSocketServer.runStopTask(
            agentId: "echo", sessionId: "s1", requestId: "req-5",
            request: StopTaskRequest(taskId: "subagents", rowId: "r", epoch: "e"),
            session: session, send: { box.add($0) })
        XCTAssertEqual(box.events.map(\.type), [.stopTaskResult])
        XCTAssertEqual(box.events[0].metadata?["reason"], "unsupported")
    }

    // MARK: - stopped の payload は結果より先に届く（§3.3 の規則 8）

    private func rowPayload(_ state: String, subtype: String = "task_progress") -> String {
        let obj: [String: Any] = [
            "subtype": subtype, "taskId": "subagents", "kind": "subagents", "epoch": "ep-1", "status": state == "running" ? "running" : "completed",
            "agents": [["index": 0, "id": "row-1", "label": "a", "state": state, "stoppable": state == "running"]],
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testStopTargetStillRunningFollowsMirror() {
        var mirror = WorkflowCardMirror()
        let request = StopTaskRequest(taskId: "subagents", rowId: "row-1", epoch: "ep-1")
        XCTAssertFalse(SessionHub.stopTargetStillRunning(mirror, request))
        mirror.apply(rowPayload("running"))
        XCTAssertTrue(SessionHub.stopTargetStillRunning(mirror, request))
        XCTAssertFalse(SessionHub.stopTargetStillRunning(mirror, StopTaskRequest(taskId: "subagents", rowId: "row-1", epoch: "other")))
        mirror.apply(rowPayload("stopped"))
        XCTAssertFalse(SessionHub.stopTargetStillRunning(mirror, request))
    }

    func testStoppedResultWaitsForStoppedPayloadToReachTheConnection() async throws {
        let agent = "stopwait-\(UUID().uuidString.prefix(8).lowercased())"
        let sid = "sid-\(UUID().uuidString.prefix(8).lowercased())"
        let box = Box<ScriptedSession>()
        let adapter = ScriptedAdapter(id: agent) { sid in
            let s = ScriptedSession(agentId: agent, sessionId: sid ?? "x")
            box.value = s
            return s
        }
        let client = await TestConnection.open(adapter, sessionId: sid)
        let session = try XCTUnwrap(box.value)
        session.emit(.workflowProgress(agentId: agent, sessionId: sid, payloadJSON: rowPayload("running")))
        try await client.until("running row") { $0.type == .workflowProgress && ($0.content ?? "").contains("\"running\"") }
        client.clear()

        // stopTask は先に .stopped を返すが、stopped の payload は pump に遅れて届く（実際の CLI の流れの逆順）。
        let stopper = StopScriptedSession()
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            session.emit(.workflowProgress(agentId: agent, sessionId: sid, payloadJSON: self.rowPayload("stopped")))
        }
        await WebSocketServer.runStopTask(
            agentId: agent, sessionId: sid, requestId: "req-w",
            request: StopTaskRequest(taskId: "subagents", rowId: "row-1", epoch: "ep-1"),
            session: stopper, send: { client.append($0) })
        let types = client.events.map(\.type)
        XCTAssertEqual(types, [.workflowProgress, .stopTaskResult], "stopped の payload が結果より先")
        XCTAssertTrue((client.events[0].content ?? "").contains("\"stopped\""))
        await client.close()
    }

    func testAwaitStopDeliveredGivesUpAtTheLimit() async throws {
        let agent = "stoplimit-\(UUID().uuidString.prefix(8).lowercased())"
        let sid = "sid-\(UUID().uuidString.prefix(8).lowercased())"
        let box = Box<ScriptedSession>()
        let adapter = ScriptedAdapter(id: agent) { sid in
            let s = ScriptedSession(agentId: agent, sessionId: sid ?? "x")
            box.value = s
            return s
        }
        let client = await TestConnection.open(adapter, sessionId: sid)
        let session = try XCTUnwrap(box.value)
        session.emit(.workflowProgress(agentId: agent, sessionId: sid, payloadJSON: rowPayload("running")))
        try await client.until("running row") { $0.type == .workflowProgress }
        let started = Date()
        await SessionHub.shared.awaitStopDelivered(
            agentId: agent, sessionId: sid,
            request: StopTaskRequest(taskId: "subagents", rowId: "row-1", epoch: "ep-1"), timeout: 0.15)
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.12)
        XCTAssertLessThan(waited, 1.5)
        await client.close()
    }

    func testTurnStatusWithoutEntrySendsEmptySubagentsSnapshotBeforeDone() async throws {
        let box = EventBox()
        await SessionHub.shared.requestTurnStatus(agentId: "claude", sessionId: "gone-\(UUID().uuidString.prefix(8))", send: { box.add($0) })
        XCTAssertEqual(box.events.map(\.type), [.workflowProgress, .done])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((box.events[0].content ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(obj["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(obj["taskId"] as? String, "subagents")
        XCTAssertEqual(obj["kind"] as? String, "subagents")
        XCTAssertEqual(obj["status"] as? String, "completed")
        XCTAssertEqual((obj["agents"] as? [Any])?.count, 0)
        XCTAssertFalse((obj["epoch"] as? String ?? "").isEmpty)
        // 世代は毎回新しい（アプリは前の世代の行を捨てる）。
        let again = EventBox()
        await SessionHub.shared.requestTurnStatus(agentId: "claude", sessionId: "gone2", send: { again.add($0) })
        let obj2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((again.events[0].content ?? "").utf8)) as? [String: Any])
        XCTAssertNotEqual(obj["epoch"] as? String, obj2["epoch"] as? String)
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: T?
    var value: T? { get { lock.lock(); defer { lock.unlock() }; return _v } set { lock.lock(); _v = newValue; lock.unlock() } }
}
