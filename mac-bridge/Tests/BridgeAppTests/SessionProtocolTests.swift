import XCTest
@testable import BridgeApp

// windows-bridge/src/server.test.ts の通信の筋書き（再接続の差分 replay・live と replay の重複除去・
// 送信予約・生成中の確認・baseSeq の競合ガード・知らない種別）を mac の SessionInbox / SessionHub で確かめる。
// WebSocket の代わりに WebSocketServer.bindSession で接続 1 本分を組み立てる（本番と同じ配線）。

/// 送られた文と、届いたら出す出来事を台本で決める session。
final class ScriptedSession: AgentSession, @unchecked Sendable {
    let sessionId: String
    let agentId: String
    let events: AsyncThrowingStream<SessionEvent, Error>
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _interrupts = 0
    /// (session, 本文, 何回目か 1 始まり)
    var onSend: ((ScriptedSession, String, Int) async -> Void)?

    init(agentId: String, sessionId: String) {
        self.agentId = agentId
        self.sessionId = sessionId
        var cont: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { cont = $0 }
        self.continuation = cont
    }

    var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
    var interrupts: Int { lock.lock(); defer { lock.unlock() }; return _interrupts }

    func emit(_ event: SessionEvent) { continuation.yield(event) }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        lock.lock(); _sent.append(text); let n = _sent.count; lock.unlock()
        await onSend?(self, text, n)
    }

    func interrupt() async { lock.lock(); _interrupts += 1; lock.unlock() }

    /// 承認への答え（requestId, decision）。届いた順。
    private var _answers: [(requestId: String, decision: String)] = []
    var answers: [(requestId: String, decision: String)] { lock.lock(); defer { lock.unlock() }; return _answers }
    /// 答えが届いたときの続き（返事を出して done にするなど）。
    var onAnswer: ((ScriptedSession, String, String) async -> Void)?

    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {
        lock.lock(); _answers.append((requestId, decision)); lock.unlock()
        await onAnswer?(self, requestId, decision)
    }

    func close() async { continuation.finish() }
}

final class ScriptedAdapter: AgentAdapter {
    let id: String
    let displayName: String
    var history: [HistoryMessage] = []
    /// 申告する権限モード（mainagent の子のモードを確かめる用）。
    var modesForTesting: [String] = []
    var capabilities: AgentCapabilities { AgentCapabilities(modes: modesForTesting) }
    private let make: (String?) -> ScriptedSession

    init(id: String, displayName: String = "Scripted", make: @escaping (String?) -> ScriptedSession) {
        self.id = id
        self.displayName = displayName
        self.make = make
    }

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession { make(sessionId) }
    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] { [] }
    func loadHistory(sessionId: String) async -> [HistoryMessage] { history }
}

/// WS 接続 1 本の代わり。届いた SessionEvent を控える。
final class TestConnection: @unchecked Sendable {
    let inbox: SessionInbox
    let subscriberId = UUID()
    private let lock = NSLock()
    private var _events: [SessionEvent] = []

    private init(inbox: SessionInbox) { self.inbox = inbox }

    var events: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func clear() { lock.lock(); _events.removeAll(); lock.unlock() }
    func append(_ e: SessionEvent) { lock.lock(); _events.append(e); lock.unlock() }

    static func open(_ adapter: AgentAdapter, sessionId: String? = nil) async -> TestConnection {
        let live = LiveDeliveredEvents()
        let conn = TestConnection(inbox: SessionInbox(liveDelivered: live))
        let send: @Sendable (SessionEvent) -> Void = { [weak conn] in conn?.append($0) }
        let hubSend: @Sendable (SessionEvent) -> Void = { live.note($0); send($0) }
        await WebSocketServer.bindSession(
            inbox: conn.inbox, adapter: adapter, agentId: adapter.id,
            sessionId: sessionId, cwd: nil, options: nil,
            subscriberId: conn.subscriberId, send: send, hubSend: hubSend
        )
        return conn
    }

    func send(_ object: [String: Any]) async {
        let data = try! JSONSerialization.data(withJSONObject: object)
        await inbox.deliver(text: String(data: data, encoding: .utf8)!)
    }

    func sendRaw(_ text: String) async { await inbox.deliver(text: text) }

    /// 条件に合う出来事が届くまで待つ（届いている分も見る）。
    @discardableResult
    func until(_ what: String = "", timeout: TimeInterval = 5,
               file: StaticString = #filePath, line: UInt = #line,
               _ match: (SessionEvent) -> Bool) async throws -> SessionEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = events.first(where: match) { return hit }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("待ちきれなかった: \(what) / 届いた種別 \(events.map(\.type.rawValue))", file: file, line: line)
        throw CancellationError()
    }

    /// WS の onClose と同じ後始末。
    func close() async {
        await SessionHub.shared.release(subscriberId: subscriberId)
        await inbox.close()
    }
}

/// 一度だけ開ける門（台本の途中でターンを止めておく）。
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }

    func open() {
        lock.lock(); opened = true; let ws = waiters; waiters.removeAll(); lock.unlock()
        ws.forEach { $0.resume() }
    }
}

final class SessionProtocolTests: XCTestCase {
    private func uniq(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())" }

    /// "echo: <本文>" を 1 つの delta で返して done する adapter。
    private func echoAdapter(_ agentId: String) -> ScriptedAdapter {
        ScriptedAdapter(id: agentId) { sid in
            let s = ScriptedSession(agentId: agentId, sessionId: sid ?? "\(agentId)-new")
            s.onSend = { s, text, n in
                let mid = "m-\(n)"
                s.emit(.assistantDelta("echo: \(text)", agentId: agentId, sessionId: s.sessionId, messageId: mid))
                s.emit(.done(agentId: agentId, sessionId: s.sessionId, messageId: mid))
            }
            return s
        }
    }

    private func userMessage(_ agentId: String, _ sid: String?, _ text: String, cmid: String,
                             extra: [String: String] = [:]) -> [String: Any] {
        var meta = ["clientMessageId": cmid]
        meta.merge(extra) { _, new in new }
        var o: [String: Any] = ["type": "user_message", "agentId": agentId, "content": text, "metadata": meta]
        if let sid { o["sessionId"] = sid }
        return o
    }

    // MARK: - 再接続と差分 replay

    func testReconnectReplayIsNotRecordedAndFallsBackToFullHistory() async throws {
        let agent = uniq("echo")
        let sid = uniq("s")
        let adapter = echoAdapter(agent)
        adapter.history = [HistoryMessage(role: "user", content: "hi", messageId: "h1"),
                           HistoryMessage(role: "assistant", content: "echo: hi", messageId: "h2")]

        // 2 ターン流す（1 ターン目の直前 = この entry の作成時点は、ターミナル等で進んだ分を
        // 持っていないので差分 replay の起点にできない。mac の startSeq の判定）。
        let first = await TestConnection.open(adapter, sessionId: sid)
        await first.send(userMessage(agent, sid, "warm", cmid: uniq("c")))
        try await first.until("done 1") { $0.type == .done }
        first.clear()
        await first.send(userMessage(agent, sid, "hi", cmid: uniq("c")))
        let done = try await first.until("done 2") { $0.type == .done }
        let latest = try XCTUnwrap(done.seq)

        // (a) 接続時の session_started は採番しない
        let second = await TestConnection.open(adapter, sessionId: sid)
        let started = try await second.until("session_started") { $0.type == .sessionStarted }
        XCTAssertNil(started.seq)

        // (b) 2 回とも同じ 3 件（user_message / delta / done）が返り、replay は記録されない
        for _ in 0..<2 {
            second.clear()
            await second.send(["type": "load_history_request", "agentId": agent, "sessionId": sid,
                               "metadata": ["sinceSeq": String(latest - 3)]])
            let end = try await second.until("load_history_end") { $0.type == .loadHistoryEnd }
            let replayed = second.events.filter { $0.type != .loadHistoryEnd }
            XCTAssertEqual(replayed.map(\.seq), [latest - 2, latest - 1, latest])
            XCTAssertEqual(replayed.map(\.type), [.userMessage, .assistantDelta, .done])
            XCTAssertEqual(end.seq, latest)
        }

        // (c) live buffer に無い sinceSeq（Bridge 再起動相当）は全履歴。履歴行に seq は載せない
        second.clear()
        await second.send(["type": "load_history_request", "agentId": agent, "sessionId": sid,
                           "metadata": ["sinceSeq": String(latest + 100)]])
        let end = try await second.until("load_history_end") { $0.type == .loadHistoryEnd }
        let history = second.events.filter { $0.type == .historyMessage }
        XCTAssertEqual(history.map(\.content), ["hi", "echo: hi"])
        XCTAssertTrue(history.allSatisfy { $0.seq == nil })
        XCTAssertEqual(end.seq, latest)

        // (d) 新着なし（sinceSeq = 最新）は終端だけ
        second.clear()
        await second.send(["type": "load_history_request", "agentId": agent, "sessionId": sid,
                           "metadata": ["sinceSeq": String(latest)]])
        let upToDate = try await second.until("load_history_end") { $0.type == .loadHistoryEnd }
        XCTAssertEqual(second.events.map(\.type), [.loadHistoryEnd])
        XCTAssertEqual(upToDate.seq, latest)

        await first.close()
        await second.close()
    }

    func testReconnectMidTurnGetsRestAndReplaySkipsLiveDelivered() async throws {
        let agent = uniq("slow")
        let sid = uniq("slow")
        let gate = Gate()
        let adapter = ScriptedAdapter(id: agent) { _ in
            // 新規の接続（sessionId なし）から始まり、adapter が sid を確定させる。
            let s = ScriptedSession(agentId: agent, sessionId: sid)
            s.onSend = { s, _, _ in
                s.emit(.sessionStarted(agentId: agent, sessionId: sid))
                s.emit(.assistantDelta("before ", agentId: agent, sessionId: sid, messageId: "m-1"))
                await gate.wait()
                s.emit(.assistantDelta("after", agentId: agent, sessionId: sid, messageId: "m-1"))
                s.emit(.done(agentId: agent, sessionId: sid, messageId: "m-1"))
            }
            return s
        }

        let first = await TestConnection.open(adapter)
        await first.send(userMessage(agent, nil, "go", cmid: uniq("c")))
        try await first.until("delta") { $0.type == .assistantDelta }
        await first.close()

        let second = await TestConnection.open(adapter, sessionId: sid)
        let resume = try await second.until("turn_resume") { $0.type == .turnResume }
        XCTAssertEqual(resume.content, "before ")
        XCTAssertEqual(resume.metadata?["phase"], "streaming")
        XCTAssertNil(resume.seq, "スナップショットは採番しない")
        let snapshotSeq = try XCTUnwrap(Int(resume.metadata?["snapshotSeq"] ?? ""))

        // 生成中の確認は turn_resume で答える
        second.clear()
        await second.send(["type": "turn_status_request", "agentId": agent, "sessionId": sid])
        let probe = try await second.until("probe") { $0.type == .turnResume || $0.type == .done }
        XCTAssertEqual(probe.type, .turnResume)

        // send() を呼んだ接続は閉じているが、出力は session の購読者（再接続した側）へ届く
        gate.open()
        let done = try await second.until("done") { $0.type == .done }
        XCTAssertNotNil(second.events.first { $0.type == .assistantDelta && $0.content == "after" })

        // sinceSeq をスナップショット直前にすると、replay は live で届けていない "before " だけになる
        second.clear()
        await second.send(["type": "load_history_request", "agentId": agent, "sessionId": sid,
                           "metadata": ["sinceSeq": String(snapshotSeq - 1)]])
        let end = try await second.until("load_history_end") { $0.type == .loadHistoryEnd }
        let replayed = second.events.filter { $0.type != .loadHistoryEnd }
        XCTAssertEqual(replayed.map(\.seq), [snapshotSeq])
        XCTAssertEqual(replayed.first?.content, "before ")
        XCTAssertEqual(end.seq, done.seq)
        await second.close()
    }

    func testTurnStatusAfterErrorOnlyTurnReturnsDone() async throws {
        let agent = uniq("failing")
        let sid = uniq("fail")
        let adapter = ScriptedAdapter(id: agent) { sid in
            let s = ScriptedSession(agentId: agent, sessionId: sid ?? "x")
            s.onSend = { s, _, _ in
                s.emit(SessionEvent(type: .error, agentId: agent, sessionId: s.sessionId, messageId: nil,
                                    toolUseId: nil, content: "boom", toolName: nil, metadata: nil))
            }
            return s
        }
        let client = await TestConnection.open(adapter, sessionId: sid)
        await client.send(userMessage(agent, sid, "x", cmid: uniq("f")))
        try await client.until("error") { $0.type == .error }
        await client.send(["type": "turn_status_request", "agentId": agent, "sessionId": sid])
        let probe = try await client.until("probe") { $0.type == .done || $0.type == .turnResume }
        XCTAssertEqual(probe.type, .done)
        await client.close()
    }

    // MARK: - 送信予約

    func testQueueHoldsWhileGeneratingAndDispatchesAfterDone() async throws {
        let agent = uniq("queued")
        let sid = uniq("q")
        let gate = Gate()
        var session: ScriptedSession?
        let adapter = ScriptedAdapter(id: agent) { _ in
            let s = ScriptedSession(agentId: agent, sessionId: sid)
            s.onSend = { s, text, n in
                s.emit(.assistantDelta(text, agentId: agent, sessionId: sid, messageId: "m-\(n)"))
                if n == 1 { await gate.wait() }
                s.emit(.done(agentId: agent, sessionId: sid, messageId: "m-\(n)"))
            }
            session = s
            return s
        }
        let client = await TestConnection.open(adapter, sessionId: sid)
        let c1 = uniq("c1"), c2 = uniq("c2"), c3 = uniq("c3")
        await client.send(userMessage(agent, sid, "one", cmid: c1))
        try await client.until("delta one") { $0.type == .assistantDelta && $0.content == "one" }
        for (cmid, text) in [(c2, "two"), (c3, "three")] {
            await client.send(["type": "queue_user_message", "agentId": agent, "sessionId": sid,
                               "content": text, "metadata": ["clientMessageId": cmid]])
        }
        try await client.until("queue_ack c3") { $0.type == .queueAck && $0.metadata?["clientMessageId"] == c3 }

        client.clear()
        await client.send(["type": "queue_remove", "agentId": agent, "sessionId": sid,
                           "metadata": ["clientMessageId": c3]])
        let state = try await client.until("queue_state") { $0.type == .queueState }
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((state.content ?? "").utf8)) as? [[String: String]])
        XCTAssertEqual(items, [["clientMessageId": c2, "content": "two"]])
        XCTAssertEqual(session?.sent, ["one"], "生成中は送らない")

        gate.open()
        try await client.until("dispatched c2") { $0.type == .queueDispatched && $0.metadata?["clientMessageId"] == c2 }
        try await client.until("done m-2") { $0.type == .done && $0.messageId == "m-2" }
        XCTAssertEqual(session?.sent, ["one", "two"], "取り消した予約は送らない")
        await client.close()
    }

    func testQueueWhenIdleSendsImmediately() async throws {
        let agent = uniq("echo")
        let client = await TestConnection.open(echoAdapter(agent))
        let cmid = uniq("qn")
        await client.send(["type": "queue_user_message", "agentId": agent, "content": "now",
                           "metadata": ["clientMessageId": cmid]])
        try await client.until("dispatched") { $0.type == .queueDispatched && $0.metadata?["clientMessageId"] == cmid }
        let ack = try await client.until("ack") { $0.type == .inputAck && $0.metadata?["clientMessageId"] == cmid }
        XCTAssertNotNil(ack.seq)
        try await client.until("done") { $0.type == .done }
        await client.close()
    }

    /// interrupt と queue_user_message は知らない種別として扱わない（ping の pong までに unsupported が無い）。
    func testInterruptAndQueueAreNotUnsupported() async throws {
        let agent = uniq("echo")
        let sid = uniq("s")
        var session: ScriptedSession?
        let adapter = ScriptedAdapter(id: agent) { id in
            let s = ScriptedSession(agentId: agent, sessionId: id ?? sid)
            session = s
            return s
        }
        let client = await TestConnection.open(adapter, sessionId: sid)
        await client.send(["type": "interrupt", "agentId": agent, "sessionId": sid])
        await client.send(["type": "queue_user_message", "agentId": agent, "sessionId": sid, "content": "later",
                           "metadata": ["clientMessageId": uniq("q")]])
        await client.send(["type": "ping", "agentId": agent, "sessionId": sid])
        try await client.until("pong") { $0.type == .pong }
        XCTAssertEqual(client.events.filter { $0.type == .unsupportedMessage }.count, 0)
        // interrupt は Task で session へ渡る
        let deadline = Date().addingTimeInterval(2)
        while (session?.interrupts ?? 0) == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(session?.interrupts, 1)
        await client.close()
    }

    // MARK: - baseSeq の競合ガード

    func testBaseSeqConflictIsRejectedWithWindowsShape() async throws {
        let agent = uniq("echo")
        let sid = uniq("s")
        var session: ScriptedSession?
        let adapter = ScriptedAdapter(id: agent) { id in
            let s = ScriptedSession(agentId: agent, sessionId: id ?? sid)
            s.onSend = { s, text, n in
                s.emit(.assistantDelta("echo: \(text)", agentId: agent, sessionId: s.sessionId, messageId: "m-\(n)"))
                s.emit(.done(agentId: agent, sessionId: s.sessionId, messageId: "m-\(n)"))
            }
            session = s
            return s
        }
        let a = await TestConnection.open(adapter, sessionId: sid)
        let b = await TestConnection.open(adapter, sessionId: sid)

        // A: 古いアプリ（baseSeq なし）はそのまま通る
        let a1 = uniq("a1")
        await a.send(userMessage(agent, sid, "first", cmid: a1))
        let ackA = try await a.until("ack a1") { $0.type == .inputAck && $0.messageId == a1 }
        let firstUserSeq = try XCTUnwrap(ackA.seq)
        let doneA = try await a.until("done") { $0.type == .done }
        let latest = try XCTUnwrap(doneA.seq)

        // B: A の発話より前の baseSeq → input_rejected（実行しない）
        let b1 = uniq("b1")
        await b.send(userMessage(agent, sid, "second", cmid: b1, extra: ["baseSeq": String(firstUserSeq - 1)]))
        let rejected = try await b.until("input_rejected") { $0.type == .inputRejected }
        XCTAssertEqual(rejected.content, "conflict")
        XCTAssertEqual(rejected.messageId, b1)
        XCTAssertEqual(rejected.sessionId, sid)
        XCTAssertEqual(rejected.agentId, agent)
        XCTAssertEqual(rejected.metadata, ["reason": "conflict", "clientMessageId": b1])
        XCTAssertNil(rejected.seq)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rejected)) as? [String: Any])
        XCTAssertEqual(Set(wire.keys), ["type", "agentId", "sessionId", "messageId", "content", "metadata"])
        XCTAssertEqual(wire["type"] as? String, "input_rejected")
        XCTAssertFalse(b.events.contains { $0.type == .inputAck && $0.messageId == b1 })
        XCTAssertEqual(session?.sent, ["first"])

        // 同期し直した B が同じ clientMessageId で送り直すと通る（拒否は処理済みにしない）
        await b.send(userMessage(agent, sid, "second", cmid: b1, extra: ["baseSeq": String(latest)]))
        let ackB = try await b.until("ack b1") { $0.type == .inputAck && $0.messageId == b1 }
        XCTAssertNotNil(ackB.seq)

        // followUp は前の seq を基準にしてよい
        let f1 = uniq("f1")
        await b.send(userMessage(agent, sid, "follow", cmid: f1, extra: ["baseSeq": String(firstUserSeq - 1), "followUp": "true"]))
        try await b.until("ack f1") { $0.type == .inputAck && $0.messageId == f1 }

        // baseSeq=0（live の seq をまだ受けていない）はガードしない
        let z1 = uniq("z1")
        await b.send(userMessage(agent, sid, "zero", cmid: z1, extra: ["baseSeq": "0"]))
        try await b.until("ack z1") { $0.type == .inputAck && $0.messageId == z1 }
        XCTAssertEqual(b.events.filter { $0.type == .inputRejected }.count, 1)

        await a.close()
        await b.close()
    }

    func testBaseSeqHelpers() {
        XCTAssertEqual(SessionHub.parseBaseSeq("12"), 12)
        XCTAssertEqual(SessionHub.parseBaseSeq("0"), 0)
        XCTAssertNil(SessionHub.parseBaseSeq(nil))
        XCTAssertNil(SessionHub.parseBaseSeq(""))
        XCTAssertNil(SessionHub.parseBaseSeq("-1"))
        XCTAssertNil(SessionHub.parseBaseSeq("abc"))

        var user = SessionEvent.userMessage("x", agentId: "a", sessionId: "s"); user.seq = 5
        var delta = SessionEvent.assistantDelta("y", agentId: "a", sessionId: "s", messageId: "m"); delta.seq = 7
        XCTAssertTrue(SessionHub.hasUserInput(after: 4, in: [user, delta]))
        XCTAssertFalse(SessionHub.hasUserInput(after: 5, in: [user, delta]), "delta は入力ではない")
    }

    // MARK: - 知らない種別

    func testUnknownTypeIsAnsweredWithItsName() async throws {
        let agent = uniq("echo")
        let client = await TestConnection.open(echoAdapter(agent))
        await client.send(["type": "future_feature_request", "agentId": agent])
        let reply = try await client.until("unsupported") { $0.type == .unsupportedMessage }
        XCTAssertEqual(reply.content, "future_feature_request")

        client.clear()
        await client.sendRaw("not json")
        let broken = try await client.until("decode_failed") { $0.type == .unsupportedMessage }
        XCTAssertEqual(broken.content, "decode_failed")

        // 知っている種別は返事の種別名をそのまま使う（受け取らない s2c 種別も同じ）
        client.clear()
        await client.send(["type": "done", "agentId": agent])
        let s2c = try await client.until("unsupported done") { $0.type == .unsupportedMessage }
        XCTAssertEqual(s2c.content, "done")
        await client.close()
    }

    func testInboundFrameParse() {
        func parse(_ s: String) -> InboundFrame { InboundFrame.parse(Data(s.utf8)) }
        if case .event(let e) = parse(#"{"type":"ping"}"#) { XCTAssertEqual(e.type, .ping) } else { XCTFail() }
        if case .unknownType(let t) = parse(#"{"type":"brand_new","metadata":{"a":"b"}}"#) { XCTAssertEqual(t, "brand_new") } else { XCTFail() }
        // 知っている種別で形が違う / type が無い / JSON でない
        if case .malformed = parse(#"{"type":"ping","metadata":"x"}"#) {} else { XCTFail() }
        if case .malformed = parse(#"{"content":"x"}"#) {} else { XCTFail() }
        if case .malformed = parse("[") {} else { XCTFail() }
        XCTAssertEqual(InboundFrame.meterType(Data(#"{"type":"ping"}"#.utf8)), "ping")
        XCTAssertEqual(InboundFrame.meterType(Data(#"{"type":"brand_new"}"#.utf8)), "unknown")
        let name = "once-\(UUID().uuidString)"
        XCTAssertTrue(InboundFrame.shouldLogUnknown(name))
        XCTAssertFalse(InboundFrame.shouldLogUnknown(name), "同じ種別は 1 回だけ記録する")
    }

    // MARK: - 通知のタイトル

    func testPushTitleUsesDisplayName() {
        XCTAssertEqual(SessionHub.pushTitle(agentId: "codex", displayName: CodexHistoryAdapter().displayName), "Codex")
        XCTAssertEqual(SessionHub.pushTitle(agentId: "hermes", displayName: HermesAdapter().displayName), "Hermes")
        XCTAssertEqual(SessionHub.pushTitle(agentId: "codex", displayName: nil), "codex")
        XCTAssertEqual(SessionHub.pushTitle(agentId: "codex", displayName: " "), "codex")
    }
}
