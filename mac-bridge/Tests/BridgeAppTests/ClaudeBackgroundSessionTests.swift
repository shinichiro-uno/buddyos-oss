import XCTest
@testable import BridgeApp

// claude --bg の会話（docs/BACKGROUND_CONTROL_2026-10-21.md §7.8）。transcript は一時フォルダに書き、
// ClaudeBackgroundJobs の代わりに偽の host を渡す。受け箱は post に差し替える。

private final class FakeBgHost: BgSessionHost, @unchecked Sendable {
    let homeDir: URL
    private let box = LockedBox<BgEntry?>(nil)
    private let listeners = LockedBox<[UUID: @Sendable (BgEntry?) -> Void]>([:])

    init(home: URL) { homeDir = home }

    var entry: BgEntry? { box.value }

    func set(_ e: BgEntry?) {
        box.value = e
        for l in listeners.value.values { l(e) }
    }

    func mutate(_ change: (inout BgEntry) -> Void) {
        guard var e = box.value else { return }
        change(&e)
        set(e)
    }

    func entryFor(sessionId: String) async -> BgEntry? { box.value }

    func watchEntry(sessionId: String, _ listener: @escaping @Sendable (BgEntry?) -> Void) async -> UUID {
        let id = UUID()
        listeners.update { $0[id] = listener }
        return id
    }

    func unwatchEntry(_ id: UUID) async { listeners.update { $0.removeValue(forKey: id) } }
}

final class ClaudeBackgroundSessionTests: XCTestCase {
    private let sid = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"
    private var home: URL!
    private var transcript: URL!
    private var host: FakeBgHost!
    private var posts: LockedBox<[(text: String, socket: String)]>!
    private var postError: LockedBox<Error?>!
    private var collected: LockedBox<[SessionEvent]>!
    private var sessions: [ClaudeBackgroundSession] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("bg-session-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".claude/projects/-tmp-x", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        transcript = dir.appendingPathComponent("\(sid).jsonl")
        FileManager.default.createFile(atPath: transcript.path, contents: nil)
        host = FakeBgHost(home: home)
        posts = LockedBox([])
        postError = LockedBox(nil)
        collected = LockedBox([])
    }

    override func tearDown() async throws {
        for s in sessions { await s.close() }
        sessions = []
    }

    private func entry(state: BgState = .working, live: Bool = true, status: String? = "idle",
                       inbox: String? = "/tmp/cc-socks/1.sock") -> BgEntry {
        BgEntry(row: BgRow(id: "dceba663", sessionId: sid, title: "t", cwd: "/tmp/x", state: state, live: live,
                           needs: nil, detail: nil, shells: 0, createdAtMs: 0),
                workerStatus: live ? status : nil, inbox: live ? inbox : nil, linkScanPath: transcript.path)
    }

    private func timing(historyWait: TimeInterval = 0, ack: TimeInterval = 30) -> ClaudeBackgroundSession.Timing {
        .init(fast: 0.02, slow: 0.03, historyWait: historyWait, ack: ack)
    }

    private func open(_ e: BgEntry?, mode: ClaudeBackgroundSession.Mode = .worker,
                      holder: ClaudeBackgroundSession.Holder? = nil, feed: BgHistoryFeed = BgHistoryFeed(),
                      timing: ClaudeBackgroundSession.Timing? = nil) async -> ClaudeBackgroundSession {
        host.set(e)
        let posts = self.posts!, postError = self.postError!
        let session = ClaudeBackgroundSession(
            agentId: "claude", sessionId: sid, mode: mode, host: host, holder: holder, feed: feed,
            timing: timing ?? self.timing(), isAlive: { _, _ in true },
            post: { text, socket in
                if let error = postError.value { throw error }
                posts.update { $0.append((text, socket)) }
            })
        sessions.append(session)
        let collected = self.collected!
        Task { do { for try await e in session.events { collected.update { $0.append(e) } } } catch {} }
        await session.start()
        return session
    }

    private func append(_ objects: [String: Any]...) throws {
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for o in objects {
            try handle.write(contentsOf: Data((try BgFixtures.json(o) + "\n").utf8))
        }
    }

    private func assistant(_ id: String, _ blocks: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "uuid": UUID().uuidString, "message": ["id": id, "role": "assistant", "content": blocks]]
    }

    private func user(_ content: Any, extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = ["type": "user", "uuid": UUID().uuidString, "message": ["role": "user", "content": content]]
        for (k, v) in extra { o[k] = v }
        return o
    }

    private func peer(_ body: String) -> [String: Any] {
        user("Another Claude session sent a message:\n\(body)\n\nThis came from another Claude session via cross-session messaging.",
             extra: ["origin": ["kind": "peer"]])
    }

    private var events: [SessionEvent] { collected.value.filter { $0.type != .sessionStarted } }

    private func types() -> [SessionEventType] { events.map(\.type) }

    private func until(_ what: String, timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
                       _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "待ちきれなかった: \(what)", file: file, line: line)
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 150_000_000) }

    // MARK: - transcript → イベント

    func testBusyOpensTurnWithActivityAndTextBecomesAssistantDelta() async throws {
        _ = await open(entry(status: "idle"))
        host.mutate { $0.workerStatus = "busy" }
        try await until("activity") { types() == [.activity] }
        let turn = try XCTUnwrap(events.first?.messageId)
        XCTAssertEqual(events.first?.content, "")

        try append(assistant("m1", [["type": "text", "text": "1"]]))
        try await until("first delta") { types().contains(.assistantDelta) }
        XCTAssertEqual(events.last?.messageId, turn)
        XCTAssertEqual(events.last?.content, "1")

        // message.id が変わるたびに新しい吹き出し
        try append(assistant("m2", [["type": "text", "text": "2"]]))
        try await until("second delta") { events.filter { $0.type == .assistantDelta }.count == 2 }
        XCTAssertNotEqual(events.last?.messageId, turn)

        host.mutate { $0.workerStatus = "idle" }
        try await until("done") { types().last == .done }
        XCTAssertEqual(events.last?.messageId, turn)
        XCTAssertNil(events.last?.metadata?["pending"])
    }

    func testToolUseAndToolResult() async throws {
        _ = await open(entry(status: "busy"))
        try append(
            assistant("m1", [["type": "tool_use", "id": "tu1", "name": "Bash", "input": ["command": "sleep 5"]]]),
            user([["type": "tool_result", "tool_use_id": "tu1", "content": "ok"]]),
            assistant("m2", [["type": "tool_use", "id": "tu2", "name": "Read", "input": ["file_path": "/a"]]]),
            user([["type": "tool_result", "tool_use_id": "tu2", "content": [["type": "text", "text": "boom"]], "is_error": true]]))
        try await until("4 tool events") { types().filter { $0 == .toolStart || $0 == .toolEnd }.count == 4 }
        let tools = events.filter { $0.type == .toolStart || $0.type == .toolEnd }
        XCTAssertEqual(tools[0].toolUseId, "tu1")
        XCTAssertEqual(tools[0].content, "sleep 5")
        XCTAssertEqual(tools[1].metadata?["status"], "completed")
        XCTAssertEqual(tools[1].toolName, "Bash")
        XCTAssertEqual(tools[3].metadata?["status"], "failed")
        XCTAssertEqual(tools[3].content, "boom")
    }

    func testSidechainAndMetaRowsAreDropped() async throws {
        _ = await open(entry(status: "busy"))
        try append(
            ["type": "assistant", "isSidechain": true, "message": ["id": "s", "content": [["type": "text", "text": "side"]]]],
            user("meta", extra: ["isMeta": true]),
            assistant("m1", [["type": "text", "text": "main"]]))
        try await until("main delta") { types().contains(.assistantDelta) }
        try await settle()
        XCTAssertEqual(events.filter { $0.type == .assistantDelta }.map(\.content), ["main"])
        XCTAssertFalse(types().contains(.userMessage))
    }

    func testAttachTypedRowAndUnknownPeerRowBecomeUserMessage() async throws {
        _ = await open(entry(status: "idle"))
        try append(
            user("<system-reminder>x</system-reminder>PCで打った"),
            peer("ほかの人から"))
        try await until("2 user messages") { types().filter { $0 == .userMessage }.count == 2 }
        XCTAssertEqual(events.filter { $0.type == .userMessage }.map(\.content), ["PCで打った", "ほかの人から"])
    }

    // MARK: - ターンと送信

    func testSentPromptEchoIsDroppedAndOpensTurn() async throws {
        let session = await open(entry(status: "idle"))
        await session.send("やって", skills: [], attachments: [])
        XCTAssertEqual(posts.value.map(\.text), ["やって"])
        XCTAssertEqual(posts.value.first?.socket, "/tmp/cc-socks/1.sock")

        try append(peer("やって"))
        try await until("turn opened by the echo") { types() == [.activity] }
        try await settle()
        XCTAssertFalse(types().contains(.userMessage))
        host.mutate { $0.workerStatus = "idle" }
        try await until("done") { types().last == .done }
        XCTAssertNil(events.last?.metadata?["pending"], "届いた発話は覚えから外れている")
    }

    func testDonePendingWhenSentPromptNotYetInTranscript() async throws {
        let session = await open(entry(status: "idle"))
        await session.send("あとで", skills: [], attachments: [])
        host.mutate { $0.workerStatus = "busy" }
        try await until("activity") { types() == [.activity] }
        host.mutate { $0.workerStatus = "shell" }
        try await until("done") { types().last == .done }
        XCTAssertEqual(events.last?.metadata?["pending"], "1")
    }

    func testBlockedAndNoWorkerRefuseToSend() async throws {
        let session = await open(entry(state: .blocked, status: "waiting"))
        await session.send("x", skills: [], attachments: [])
        XCTAssertTrue(posts.value.isEmpty)
        try await until("error and done") { types() == [.error, .done] }
        XCTAssertTrue(events[0].content?.contains("claude attach dceba663") == true)
        XCTAssertEqual(events[1].metadata?["errored"], "true")
        let usable = await session.isUsable()
        XCTAssertTrue(usable)

        collected.value = []
        host.set(entry(state: .done, live: false))
        await session.send("y", skills: [], attachments: [])
        XCTAssertTrue(posts.value.isEmpty)
        try await until("worker gone error") { events.contains { $0.type == .error && $0.content?.contains("止まりました") == true } }
        let after = await session.isUsable()
        XCTAssertFalse(after, "送って分かった「使えない」印")
    }

    func testPostFailureIsReported() async throws {
        let session = await open(entry(status: "idle"))
        postError.value = ClaudeInboxSocket.PostError(description: "connect failed errno=61")
        await session.send("x", skills: [], attachments: [])
        try await until("error") { types() == [.error, .done] }
        XCTAssertTrue(events[0].content?.contains("connect failed errno=61") == true)
        XCTAssertEqual(events[1].metadata?["errored"], "true")
    }

    func testNotAcceptedAfterAckTimeoutButNotWhileBusy() async throws {
        let session = await open(entry(status: "busy"), timing: timing(ack: 0.3))
        await session.send("x", skills: [], attachments: [])
        // busy の間は数えない
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(types().contains(.error))
        host.mutate { $0.workerStatus = "idle" }
        try await until("timeout error") { types().contains(.error) }
        let error = try XCTUnwrap(events.first { $0.type == .error })
        XCTAssertTrue(error.content?.contains("30 秒たっても反応がありません") == true)
        let done = try XCTUnwrap(events.last)
        XCTAssertEqual(done.type, .done)
        XCTAssertEqual(done.metadata?["errored"], "true")
    }

    func testHeldPeerMessage() async throws {
        let session = await open(entry(status: "idle"))
        await session.send("x", skills: [], attachments: [])
        try append(["type": "system", "content": "Held peer message from another session"])
        try await until("held error") { types() == [.error, .done] }
        XCTAssertTrue(events[0].content?.contains("保留しました") == true)
        XCTAssertTrue(events[0].content?.contains("claude attach dceba663") == true)
        XCTAssertEqual(events[1].metadata?["errored"], "true")
    }

    /// ターンが開いている間の「保留」「受け付けず」は、動いているターンを終わらせない（新しい messageId の pending な done）。
    func testHeldPeerMessageWhileTurnIsOpenDoesNotEndTheTurn() async throws {
        let session = await open(entry(status: "busy"))
        try await until("activity") { types() == [.activity] }
        let turnId = try XCTUnwrap(events[0].messageId)
        await session.send("x", skills: [], attachments: [])
        try append(["type": "system", "content": "Held peer message from another session"])
        try await until("held error") { types() == [.activity, .error, .done] }
        let done = events[2]
        XCTAssertNotEqual(done.messageId, turnId)
        XCTAssertEqual(done.metadata?["errored"], "true")
        XCTAssertEqual(done.metadata?["pending"], "1")
    }

    func testWorkerGoneWhileFailedClosesTurnWithError() async throws {
        _ = await open(entry(status: "busy"))
        try await until("activity") { types() == [.activity] }
        var gone = entry(state: .failed, live: false)
        gone.row.detail = "boom"
        host.set(gone)
        try await until("error then done") { types() == [.activity, .error, .done] }
        XCTAssertTrue(events[1].content?.contains("失敗") == true)
        XCTAssertEqual(events[2].metadata?["errored"], "true")
    }

    func testWorkerGoneAfterDoneClosesTurnPlainly() async throws {
        _ = await open(entry(status: "busy"))
        try await until("activity") { types() == [.activity] }
        host.set(entry(state: .done, live: false))
        try await until("done") { types() == [.activity, .done] }
        XCTAssertNil(events[1].metadata?["errored"])
    }

    // MARK: - 読み始めの位置

    func testReadsAfterLoadHistoryEnd() async throws {
        let feed = BgHistoryFeed()
        _ = await open(entry(status: "busy"), feed: feed, timing: timing(historyWait: 30))
        try append(assistant("old", [["type": "text", "text": "履歴にある"]]))
        let end = UInt64(try Data(contentsOf: transcript).count)
        try append(assistant("new", [["type": "text", "text": "これから"]]))
        // 履歴を読み終えるまで読まない（同じ行を履歴と live の両方に出さない）
        try await settle()
        XCTAssertFalse(types().contains(.assistantDelta))
        feed.note(sessionId: sid, file: transcript.path, end: end)
        try await until("delta after history") { types().contains(.assistantDelta) }
        try await settle()
        XCTAssertEqual(events.filter { $0.type == .assistantDelta }.map(\.content), ["これから"])
    }

    // MACBG-1: 開き直しで古い lastRead が残っていても、新しい履歴の読み終わりまで待つ
    func testReopenWithStaleLastReadStillWaitsForHistory() async throws {
        let feed = BgHistoryFeed()
        try append(assistant("a", [["type": "text", "text": "ずっと前"]]))
        let stale = UInt64(try Data(contentsOf: transcript).count)
        feed.note(sessionId: sid, file: transcript.path, end: stale)
        // 閉じている間にワーカーが書き進めた
        try append(assistant("b", [["type": "text", "text": "履歴で読む分"]]))
        _ = await open(entry(status: "busy"), feed: feed, timing: timing(historyWait: 30))
        let s1 = UInt64(try Data(contentsOf: transcript).count)
        try append(assistant("c", [["type": "text", "text": "履歴で読む分その2"]]))
        let e2 = UInt64(try Data(contentsOf: transcript).count)
        try append(assistant("d", [["type": "text", "text": "live の分"]]))
        try await settle()
        XCTAssertFalse(types().contains(.assistantDelta))
        XCTAssertGreaterThan(e2, s1)
        feed.note(sessionId: sid, file: transcript.path, end: e2)
        try await until("delta after history") { types().contains(.assistantDelta) }
        try await settle()
        XCTAssertEqual(events.filter { $0.type == .assistantDelta }.map(\.content), ["live の分"])
    }

    // 前の回の読み終わりがいまの大きさと同じでも、開いたあとに書き進んだ分は履歴の読み取りを待つ（二重に出さない）
    func testReopenWithUpToDateLastReadStillWaitsForNewHistory() async throws {
        let feed = BgHistoryFeed()
        try append(assistant("a", [["type": "text", "text": "ずっと前"]]))
        let end = UInt64(try Data(contentsOf: transcript).count)
        feed.note(sessionId: sid, file: transcript.path, end: end)
        _ = await open(entry(status: "busy"), feed: feed, timing: timing(historyWait: 30))
        try append(assistant("b", [["type": "text", "text": "履歴で読む分"]]))
        let e2 = UInt64(try Data(contentsOf: transcript).count)
        try await settle()
        XCTAssertFalse(types().contains(.assistantDelta), "新しい履歴の読み取りまで読まない")
        feed.note(sessionId: sid, file: transcript.path, end: e2)
        try await settle()
        XCTAssertFalse(types().contains(.assistantDelta), "履歴で読んだ行を live にも出さない")
    }

    // MISSED-mac-bg-1: 履歴を待つ間は、ターンを閉じても読まない
    func testCloseTurnDoesNotDrainWhileWaitingForHistory() async throws {
        _ = await open(entry(status: "busy"), timing: timing(historyWait: 30))
        try await until("activity") { types() == [.activity] }
        try append(assistant("x", [["type": "text", "text": "履歴と重なる行"]]))
        host.set(entry(status: "idle"))
        try await until("done") { types().contains(.done) }
        try await settle()
        XCTAssertFalse(types().contains(.assistantDelta))
    }

    // MACBG-8: 発話を受け取る前にワーカーが消えたら、失敗で閉じて sent を残さない
    func testWorkerGoneBeforeAckFailsSentPrompt() async throws {
        let session = await open(entry(status: "busy"))
        try await until("activity") { types() == [.activity] }
        await session.send("やって", skills: [], attachments: [])
        host.set(entry(state: .stopped, live: false))
        try await until("error and done") { types().contains(.done) }
        let done = try XCTUnwrap(events.first { $0.type == .done })
        XCTAssertEqual(done.metadata?["errored"], "true")
        XCTAssertNil(done.metadata?["pending"])
        XCTAssertTrue(events.contains { $0.type == .error && $0.content?.contains("受け取る前に止まりました") == true })
    }

    func testWorkerGoneBeforeAckWithoutOpenTurnPublishesFailure() async throws {
        let session = await open(entry(status: "idle"))
        await session.send("やって", skills: [], attachments: [])
        host.set(entry(state: .stopped, live: false))
        try await until("done") { types().contains(.done) }
        XCTAssertEqual(events.first { $0.type == .done }?.metadata?["errored"], "true")
    }

    // MISSED-mac-bg-3: 上限を超える 1 行は読み飛ばして先へ進む
    func testReadLinesSkipsOversizedLineWithoutNewline() throws {
        let big = Data(repeating: 0x61, count: 100)
        try big.write(to: transcript)
        let r = ClaudeBackgroundSession.readLines(path: transcript.path, from: 0, maxBytes: 40)
        XCTAssertTrue(r.lines.isEmpty)
        XCTAssertEqual(r.next, 40)
        // 上限に届かない書きかけの行は待つ
        let partial = ClaudeBackgroundSession.readLines(path: transcript.path, from: 0, maxBytes: 1000)
        XCTAssertEqual(partial.next, 0)
    }

    func testStartsAtCurrentEndWhenHistoryIsNotRead() async throws {
        try append(assistant("old", [["type": "text", "text": "前の"]]))
        _ = await open(entry(status: "busy"))
        try append(assistant("new", [["type": "text", "text": "後の"]]))
        try await until("delta") { types().contains(.assistantDelta) }
        try await settle()
        XCTAssertEqual(events.filter { $0.type == .assistantDelta }.map(\.content), ["後の"])
    }

    func testReadLinesOnlyCompleteLinesAndShrink() throws {
        try append(["type": "x"])
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"part".utf8))
        try handle.close()
        let first = ClaudeBackgroundSession.readLines(path: transcript.path, from: 0)
        XCTAssertEqual(first.lines.count, 1)
        let complete = UInt64(try BgFixtures.json(["type": "x"]).utf8.count + 1)
        XCTAssertEqual(first.next, complete)
        // 縮んだら末尾から
        let shrunk = ClaudeBackgroundSession.readLines(path: transcript.path, from: 10_000)
        XCTAssertTrue(shrunk.lines.isEmpty)
        XCTAssertEqual(shrunk.next, UInt64(try Data(contentsOf: transcript).count))
    }

    // MARK: - そのほか

    func testInterruptSaysWhatToDo() async throws {
        let session = await open(entry(status: "busy"))
        await session.interrupt()
        try await until("error") { types().contains(.error) }
        let error = try XCTUnwrap(events.first { $0.type == .error })
        XCTAssertEqual(error.content, ClaudeBackgroundSession.interruptText)
        XCTAssertTrue(error.content?.contains("「停止」") == true)
        XCTAssertTrue(session.supportsMidTurnInjection)
        let snapshot = await session.subagentSnapshot()
        XCTAssertNil(snapshot)
    }

    func testElsewhereRefusesToSendAndFollowsHolderStatus() async throws {
        let holder = ClaudeBackgroundSession.Holder(pid: 4242, entrypoint: "cli", status: "busy", procStart: nil)
        let session = await open(entry(state: .done, live: false), mode: .elsewhere, holder: holder)
        // 握っているプロセスの status でターンが開く（見るだけ）
        try await until("activity") { types() == [.activity] }
        await session.send("x", skills: [], attachments: [])
        XCTAssertTrue(posts.value.isEmpty)
        try await until("errored done") { events.last?.metadata?["errored"] == "true" }
        let error = try XCTUnwrap(events.last { $0.type == .error })
        XCTAssertTrue(error.content?.contains("ターミナル、pid 4242") == true)
        XCTAssertEqual(events.last?.metadata?["errored"], "true")

        // entrypoint が cli でなければ「ほかのアプリ」
        let other = ClaudeBackgroundSession(agentId: "claude", sessionId: sid, mode: .elsewhere, host: host,
                                            holder: .init(pid: 7, entrypoint: "sdk-cli", status: "idle", procStart: nil),
                                            feed: BgHistoryFeed(), timing: timing())
        sessions.append(other)
        var events2: [SessionEvent] = []
        let reader = Task { for try await e in other.events { events2.append(e); if e.type == .done { break } } }
        await other.send("x", skills: [], attachments: [])
        _ = try? await reader.value
        XCTAssertTrue(events2.contains { $0.content?.contains("ほかのアプリ、pid 7") == true })
    }

    func testIsUsableFollowsWorkerLiveness() async throws {
        let session = await open(entry(status: "idle"))
        var usable = await session.isUsable()
        XCTAssertTrue(usable)
        host.set(entry(state: .done, live: false))
        usable = await session.isUsable()
        XCTAssertFalse(usable)
    }

    /// 握っていた人が閉じてワーカーが起きたら、elsewhere の会話は使えない（作り直して worker にする）。
    func testElsewhereIsNotUsableOnceTheWorkerIsLive() async throws {
        let holder = ClaudeBackgroundSession.Holder(pid: 4242, entrypoint: "cli", status: "idle", procStart: nil)
        let session = await open(entry(state: .done, live: false), mode: .elsewhere, holder: holder)
        var usable = await session.isUsable()
        XCTAssertTrue(usable)
        host.set(entry(status: "idle"))
        usable = await session.isUsable()
        XCTAssertFalse(usable)
    }

    func testCloseStopsReadingAndWarmAndRespondDoNothing() async throws {
        let session = await open(entry(status: "idle"))
        await session.warm()
        await session.respondToAction(requestId: "r", decision: "allow", answers: [:])
        await session.close()
        try append(assistant("m", [["type": "text", "text": "after close"]]))
        host.mutate { $0.workerStatus = "busy" }
        try await settle()
        XCTAssertTrue(events.isEmpty)
    }
}

// MARK: - 周辺

final class ClaudeBackgroundSessionSupportTests: XCTestCase {
    func testPeerFrameIsStripped() {
        let frame = "Another Claude session sent a message:\n本文\n二行目\n\nThis came from another Claude session via cross-session messaging."
        XCTAssertEqual(ClaudeCodeProjectsScanner.stripPeerFrame(frame), "本文\n二行目")
        // 後ろの枠が無ければ 1 行目だけ落とす
        XCTAssertEqual(ClaudeCodeProjectsScanner.stripPeerFrame("Another Claude session sent a message:\nだけ"), "だけ")
        XCTAssertEqual(ClaudeCodeProjectsScanner.stripPeerFrame("一行だけ"), "")
    }

    func testLoadHistoryDropsPeerFrameAndReturnsReadEnd() async throws {
        let sid = UUID().uuidString.lowercased()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sid).jsonl")
        let peer: [String: Any] = [
            "type": "user", "uuid": "u1", "origin": ["kind": "peer"],
            "message": ["role": "user", "content": "Another Claude session sent a message:\nやって\n\nThis came from another Claude session via x"]]
        let plain: [String: Any] = ["type": "user", "uuid": "u2", "message": ["role": "user", "content": "ふつう"]]
        var text = try BgFixtures.json(peer) + "\n" + BgFixtures.json(plain) + "\n"
        let complete = UInt64(text.utf8.count)
        text += "{\"type\":\"user\",\"mess"   // 書きかけの最後の行
        try text.write(to: file, atomically: true, encoding: .utf8)

        var contents: [String] = []
        let end = ClaudeCodeProjectsScanner.forEachLineTracking(file: file) { line in
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               ClaudeCodeProjectsScanner.isPeer(o),
               let m = o["message"] as? [String: Any] {
                contents.append(ClaudeCodeProjectsScanner.stripPeerFrame(ClaudeCodeProjectsScanner.rawText(from: m["content"])))
            }
            return true
        }
        XCTAssertEqual(contents, ["やって"])
        XCTAssertEqual(end, complete, "改行で終わらない最後の行は読み終えた位置に含めない")
    }

    func testBackgroundJobIdInStderr() {
        XCTAssertEqual(ClaudeCodeSession.backgroundJobId(inStderr: "Error: session abc is running in the background (dceba663). Use claude attach."), "dceba663")
        XCTAssertNil(ClaudeCodeSession.backgroundJobId(inStderr: "running in the background (XYZ)"))
        XCTAssertNil(ClaudeCodeSession.backgroundJobId(inStderr: "boom"))
    }

    func testWarmDoesNothingForBackgroundJob() async throws {
        let previous = ClaudeCodeSession.isBackgroundJob
        defer { ClaudeCodeSession.isBackgroundJob = previous }
        ClaudeCodeSession.isBackgroundJob = { _ in true }
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID().uuidString)")
        // 起こせば marker を作る偽の claude。起こさなければ marker は残らない。
        let exe = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nsleep 5\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let session = ClaudeCodeSession(agentId: "claude", profile: .claude, initialSessionId: UUID().uuidString.lowercased(),
                                        cwd: NSTemporaryDirectory(), executable: exe.path, store: .shared)
        await session.warm()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "bg のジョブは warm で起こさない")
        await session.close()
    }

    func testBackgroundStderrOnExitReportsAndMarksUnusable() async throws {
        let previous = ClaudeCodeSession.refreshBackgroundJobs
        defer { ClaudeCodeSession.refreshBackgroundJobs = previous }
        let refreshed = LockedBox(0)
        ClaudeCodeSession.refreshBackgroundJobs = { refreshed.update { $0 += 1 } }
        let exe = FileManager.default.temporaryDirectory.appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        try "#!/bin/sh\necho 'Error: this session is running in the background (dceba663)' >&2\nexit 1\n"
            .write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let session = ClaudeCodeSession(agentId: "claude", profile: .claude, initialSessionId: UUID().uuidString.lowercased(),
                                        cwd: NSTemporaryDirectory(), executable: exe.path, store: .shared)
        XCTAssertFalse(session.isStaleForBackground)
        let collected = LockedBox<[SessionEvent]>([])
        Task { do { for try await e in session.events { collected.update { $0.append(e) } } } catch {} }
        await session.send("やって", skills: [], attachments: [])
        let deadline = Date().addingTimeInterval(5)
        while !collected.value.contains(where: { $0.type == .error }), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let error = try XCTUnwrap(collected.value.first { $0.type == .error })
        XCTAssertTrue(error.content?.contains("バックグラウンド（dceba663）でまた動き始めました") == true)
        XCTAssertFalse(error.content?.contains("Error: this session") == true, "stderr をそのまま出さない")
        XCTAssertTrue(session.isStaleForBackground)
        let refreshDeadline = Date().addingTimeInterval(3)
        while refreshed.value == 0, Date() < refreshDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(refreshed.value, 1)
        await session.close()
    }

    // MARK: - 振り分け（ClaudeCodeAdapter.openBackgroundSession）

    private let sidA = "dceba663-6fad-4d6f-8410-2ce7d7b0c50f"

    private func jobs(_ home: BgHome, files: [String: Any]) throws -> ClaudeBackgroundJobs {
        var timing = BgTiming()
        timing.cliMinGap = 0
        return ClaudeBackgroundJobs(config: BgJobsConfig(
            home: home.root, timing: timing,
            runCli: { _, _ in BgCliResult(code: 0, stdout: "[]", stderr: "", timedOut: false) },
            buddyTitle: { _ in nil }, push: { _, _ in }, setSleep: { _ in }, isAlive: { _, _ in true }, log: { _ in }))
    }

    func testOpenBackgroundSessionRoutesWorkerElsewhereOrNothing() async throws {
        let files = try BgFixtures.load("examples-registry-files.json")
        let home = try BgHome()
        let adapter = ClaudeCodeAdapter(profile: .claude, executable: "/usr/bin/true")
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let working = try BgFixtures.variant(files, "job_state_working_with_inflight_task",
                                             ["sessionId": sidA, "createdAt": BgFixtures.iso(nowMs - 60_000)])
        try home.job("dceba663", working)
        try home.roster(["dceba663"])

        // 台帳に無い sessionId は nil（今までどおり）
        let none = await adapter.openBackgroundSession(sessionId: "00000000-0000-4000-8000-000000000000", jobs: try jobs(home, files: files))
        XCTAssertNil(none)

        // ワーカーが生きている → worker
        try home.session(900, try BgFixtures.variant(files, "sessions_bg_busy",
                                                     ["pid": 900, "jobId": "dceba663", "sessionId": sidA, "status": "busy"]))
        let worker = await adapter.openBackgroundSession(sessionId: sidA, jobs: try jobs(home, files: files))
        XCTAssertEqual(worker?.mode, .worker)
        await worker?.close()

        // ワーカーが居ない。別のプロセス（ターミナル）が同じ sessionId を握っている → elsewhere
        try FileManager.default.removeItem(at: home.claude.appendingPathComponent("sessions/900.json"))
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["sessionId": sidA]))
        try home.session(901, try BgFixtures.variant(files, "sessions_bg_busy",
                                                     ["pid": 901, "sessionId": sidA, "status": "idle", "kind": "interactive",
                                                      "entrypoint": "cli"]))
        let elsewhere = await adapter.openBackgroundSession(sessionId: sidA, jobs: try jobs(home, files: files))
        XCTAssertEqual(elsewhere?.mode, .elsewhere)
        await elsewhere?.close()

        // Bridge 自身の -p は握っているとは数えない → nil（ClaudeCodeSession で続ける）
        BridgeSpawnedClaude.add(901)
        defer { BridgeSpawnedClaude.remove(901) }
        let own = await adapter.openBackgroundSession(sessionId: sidA, jobs: try jobs(home, files: files))
        XCTAssertNil(own)
    }

    /// 台帳が古いうちに（PC の respawn 直後）開いても、握っているのがワーカー自身なら worker にする。
    func testOpenBackgroundSessionWithStaleLedgerBecomesWorker() async throws {
        let files = try BgFixtures.load("examples-registry-files.json")
        let home = try BgHome()
        let adapter = ClaudeCodeAdapter(profile: .claude, executable: "/usr/bin/true")
        try home.job("dceba663", try BgFixtures.variant(files, "job_state_done", ["sessionId": sidA]))
        let stale = try jobs(home, files: files)
        await stale.ready()
        let before = await stale.entryFor(sessionId: sidA)
        XCTAssertEqual(before?.row.live, false)
        // 読んだあとにワーカーが起きた
        try home.session(900, try BgFixtures.variant(files, "sessions_bg_busy",
                                                     ["pid": 900, "jobId": "dceba663", "sessionId": sidA, "status": "busy"]))
        let opened = await adapter.openBackgroundSession(sessionId: sidA, jobs: stale)
        XCTAssertEqual(opened?.mode, .worker)
        await opened?.close()
    }
}
