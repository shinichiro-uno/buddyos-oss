import Darwin
import XCTest
@testable import BridgeApp

/// ターミナルの Claude Code に出た選択肢を、iPhone / デスクトップのカードで答える流れ。実 claude は使わない。
/// hook の JSON は実機（claude 2.1.285、2026-10-08）の PermissionRequest をそのまま使っている。
final class TerminalPromptTests: XCTestCase {

    private let questions: [[String: Any]] = [
        ["question": "Pick a color", "header": "Color", "multiSelect": false,
         "options": [["label": "Red"], ["label": "Blue"], ["label": "Green"]]],
        ["question": "Pick fruits", "header": "Fruits", "multiSelect": true,
         "options": [["label": "Apple"], ["label": "Banana"], ["label": "Cherry"]]],
    ]

    // MARK: - キー手順（tmux で実測した順番）

    func testQuestionKeysFollowTheTuiOrder() {
        // 単一選択は番号で選んで次へ、複数選択は番号で印を付けて → 、最後に確認画面で Enter
        XCTAssertEqual(
            TerminalKeyPlan.questions(questions, answers: ["Pick a color": ["Blue"], "Pick fruits": ["Apple", "Cherry"]]),
            ["2", "1", "3", "\u{1b}[C", "\r"])
        // 1 問だけの単一選択は番号だけで送られる（確認画面が無い）
        XCTAssertEqual(TerminalKeyPlan.questions([questions[0]], answers: ["Pick a color": ["Green"]]), ["3"])
        // 選択肢に無い文は「Type something」（N+1）に打って Enter
        XCTAssertEqual(TerminalKeyPlan.questions([questions[0]], answers: ["Pick a color": ["紫"]]), ["4", "紫", "\r"])
        // 答えの無い質問があれば送らない（勝手に選ばない）
        XCTAssertNil(TerminalKeyPlan.questions(questions, answers: ["Pick a color": ["Red"]]))
    }

    /// 受け箱の保留ダイアログ（番号なし・Deny が先頭）。claude 2.1.293 で実測した手順。
    func testHeldKeys() {
        XCTAssertEqual(TerminalKeyPlan.held(decision: "allow"), ["\u{1b}[B", "\r"])
        XCTAssertEqual(TerminalKeyPlan.held(decision: "deny"), ["\u{1b}"])
    }

    /// /new はキー入力の /clear + Enter（発話として送っても Claude Code のコマンドにならない）。
    func testNewConversationKeysAndCommand() {
        XCTAssertEqual(TerminalKeyPlan.newConversation, ["/clear", "\r"])
        for text in ["/new", " /NEW\n", "/clear", "/reset"] {
            XCTAssertTrue(ClaudeTerminalSession.isNewConversationCommand(text), text)
        }
        for text in ["/new 続きの話", "/newer", "new", "/compact"] {
            XCTAssertFalse(ClaudeTerminalSession.isNewConversationCommand(text), text)
        }
    }

    func testApprovalAndPlanKeys() {
        XCTAssertEqual(TerminalKeyPlan.approval(decision: "allow", hasSuggestions: true), ["1"])
        XCTAssertEqual(TerminalKeyPlan.approval(decision: "allowForSession", hasSuggestions: true), ["2"])
        // 候補が無いと画面に 2 番（次から聞かない）が無いので、一度だけ許可にする
        XCTAssertEqual(TerminalKeyPlan.approval(decision: "allowForSession", hasSuggestions: false), ["1"])
        XCTAssertEqual(TerminalKeyPlan.approval(decision: "deny", hasSuggestions: true), ["\u{1b}"])
        XCTAssertEqual(TerminalKeyPlan.plan(decision: "allowAuto"), ["1"])
        XCTAssertEqual(TerminalKeyPlan.plan(decision: "allow"), ["2"])
        XCTAssertEqual(TerminalKeyPlan.plan(decision: "deny"), ["\u{1b}"])
        XCTAssertEqual(TerminalKeyPlan.plan(decision: "テストを先に書いて"), ["3", "テストを先に書いて", "\r"])
    }

    func testAnswersJsonAndOldClientFallback() {
        let meta = ["answers_json": #"{"Pick a color":"Red","Pick fruits":["Banana","Cherry"]}"#]
        XCTAssertEqual(TerminalKeyPlan.answerLists(meta, fallback: "", questions: questions),
                       ["Pick a color": ["Red"], "Pick fruits": ["Banana", "Cherry"]])
        // 古いクライアントは最初の質問の答えを decision だけで返す
        XCTAssertEqual(TerminalKeyPlan.answerLists([:], fallback: "Blue", questions: questions), ["Pick a color": ["Blue"]])
        // spawn 側（質問文がキー）の答え。複数選択は ", " でつなぐ
        XCTAssertEqual(ClaudeControlProtocol.answers(for: questions, decision: "x", explicit: meta),
                       ["Pick a color": "Red", "Pick fruits": "Banana, Cherry"])
    }

    func testQuestionCardCarriesAllQuestions() throws {
        let r = ClaudeControlProtocol.ToolRequest(requestId: "r", toolName: "AskUserQuestion",
                                                  input: ["questions": questions], suggestions: [])
        let card = try XCTUnwrap(ClaudeControlProtocol.questionCard(r, agentId: "claude", sessionId: "s"))
        let raw = try XCTUnwrap(card.metadata?["questions_json"])
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[1]["multiSelect"] as? Bool, true)
        XCTAssertEqual(parsed[1]["id"] as? String, "Pick fruits")
        // 古いクライアント向けに最初の質問の選択肢も載せる
        XCTAssertEqual(card.metadata?["option_count"], "3")
        XCTAssertEqual(card.metadata?["option_1_value"], "Blue")
    }

    // MARK: - 台帳: カードを出す → 答える → 閉じる

    /// デスクトップのターミナル（pty）の中で動いている claude。答えはキー入力で届く。
    func testPtyAnsweredApproval() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-pty-" + UUID().uuidString
        let me = getpid()
        // デスクトップが「この pid の pty を持っている」と名乗って poll している状態にする
        let poller = Task { await TerminalKeyRouter.shared.poll(client: "test", pids: [me], timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await registry.register(sessionId: sid, cwd: "/tmp", pid: me, transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        let session = ClaudeTerminalSession(agentId: "claude", sessionId: sid)
        await registry.attach(session)
        var events = session.events.makeAsyncIterator()
        _ = try await events.next()   // sessionStarted

        let handled = await registry.ingestPermission([
            "session_id": sid, "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": ["command": "shasum x.bin", "description": "checksum"],
            "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "shasum *"]],
                                        "behavior": "allow", "destination": "localSettings"]],
        ])
        XCTAssertTrue(handled)
        let card = try await XCTUnwrapAsync(await events.next())
        XCTAssertEqual(card.type, .actionRequest)
        XCTAssertEqual(card.metadata?["source"], "terminal")
        XCTAssertEqual(card.metadata?["answerVia"], "pty")
        XCTAssertEqual(card.metadata?["answerable"], "1")
        XCTAssertEqual(card.metadata?["option_count"], "3")   // 承認 / このセッションでは承認 / 非承認
        let requestId = try XCTUnwrap(card.messageId)
        // 選択肢が出ている間は list_sessions で回答待ち
        let waiting = await registry.awaitingSessionIds()
        XCTAssertTrue(waiting.contains(sid))
        XCTAssertEqual(SessionEvent.sessionListItem(
            agentId: "claude", summary: SessionSummary(sessionId: sid, title: "t", lastActive: "", messageCount: nil, cwd: nil),
            awaiting: true).metadata?["awaiting"], "1")

        let problem = await registry.answer(sessionId: sid, requestId: requestId, decision: "allowForSession", meta: [:])
        XCTAssertNil(problem)
        let answered = await registry.awaitingSessionIds()
        XCTAssertFalse(answered.contains(sid))
        let delivered = await poller.value
        XCTAssertEqual(delivered.first?.pid, me)
        XCTAssertEqual(delivered.first?.keys, ["2"])
        // 2 回目の答えは送らない
        let second = await registry.answer(sessionId: sid, requestId: requestId, decision: "deny", meta: [:])
        XCTAssertNil(second)

        // ツールが実行されたらカードを閉じる
        _ = await registry.ingest(["session_id": sid, "hook_event_name": "PostToolUse", "tool_name": "Bash",
                                   "tool_use_id": "toolu_1", "tool_response": "ok"])
        var resolved = false
        for _ in 0..<3 {
            guard let e = try await events.next() else { break }
            if e.type == .actionResolved { XCTAssertEqual(e.messageId, requestId); resolved = true; break }
        }
        XCTAssertTrue(resolved)
    }

    /// buddy-claude（channel 付き）で動いている claude。許可確認は channel の中継で答える。
    func testChannelAnsweredApproval() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-ch-" + UUID().uuidString
        await registry.register(sessionId: sid, cwd: "/tmp", pid: nil, transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid); await ClaudeChannelInbox.shared.forget(sid) } }
        // channel が poll している状態にする（直後に返らせる）
        let first = Task { await ClaudeChannelInbox.shared.poll(sessionId: sid, timeout: 0.2) }
        _ = await first.value
        let session = ClaudeTerminalSession(agentId: "claude", sessionId: sid)
        await registry.attach(session)
        var events = session.events.makeAsyncIterator()
        _ = try await events.next()

        _ = await registry.ingestPermission([
            "session_id": sid, "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": ["command": "shasum y.bin"], "permission_suggestions": [],
        ])
        let card = try await XCTUnwrapAsync(await events.next())
        XCTAssertEqual(card.metadata?["answerVia"], "channel")
        XCTAssertEqual(card.metadata?["option_count"], "2")   // 中継は 許可 / 拒否 だけ
        let requestId = try XCTUnwrap(card.messageId)

        // channel の依頼 id が届く前に答えても、届いた時点で送る（引数の要約が一致したときだけ）
        let early = await registry.answer(sessionId: sid, requestId: requestId, decision: "allow", meta: [:])
        XCTAssertNil(early)
        await registry.channelPermission(sessionId: sid, requestId: "abcde", toolName: "Bash",
                                         description: "checksum", inputPreview: #"{"command":"shasum y.bin"}"#)
        let items = await ClaudeChannelInbox.shared.poll(sessionId: sid, timeout: 1)
        guard case .permission(let rid, let behavior)? = items.first else { return XCTFail("答えが channel に積まれていない") }
        XCTAssertEqual(rid, "abcde")
        XCTAssertEqual(behavior, "allow")
    }

    /// 前のカードへの答えを、後から来た別の依頼（引数が違う）には使わない。
    func testChannelVerdictIsNotReusedForDifferentRequest() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-ch2-" + UUID().uuidString
        await registry.register(sessionId: sid, cwd: "/tmp", pid: nil, transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid); await ClaudeChannelInbox.shared.forget(sid) } }
        let first = Task { await ClaudeChannelInbox.shared.poll(sessionId: sid, timeout: 0.2) }
        _ = await first.value
        let session = ClaudeTerminalSession(agentId: "claude", sessionId: sid)
        await registry.attach(session)
        var events = session.events.makeAsyncIterator()
        _ = try await events.next()

        _ = await registry.ingestPermission([
            "session_id": sid, "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": ["command": "ls"], "permission_suggestions": [],
        ])
        let card = try await XCTUnwrapAsync(await events.next())
        let requestId = try XCTUnwrap(card.messageId)
        _ = await registry.answer(sessionId: sid, requestId: requestId, decision: "allow", meta: [:])

        // 別のコマンドの依頼。前の「許可」は使わず、改めてカードで聞く。
        await registry.channelPermission(sessionId: sid, requestId: "fghij", toolName: "Bash",
                                         description: "other", inputPreview: #"{"command":"touch other.txt"}"#)
        let items = await ClaudeChannelInbox.shared.poll(sessionId: sid, timeout: 0.5)
        XCTAssertTrue(items.isEmpty, "前の答えが別の依頼に使われた")
        var asked = false
        for _ in 0..<3 {
            guard let e = try await events.next() else { break }
            if e.type == .actionRequest { asked = true; break }
        }
        XCTAssertTrue(asked, "改めてカードで聞く")
    }

    /// どちらの口も無い（普通のターミナルで普通の claude）。カードは出すが、答えはターミナルで。
    func testUnanswerablePromptIsShownReadOnly() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-none-" + UUID().uuidString
        await registry.register(sessionId: sid, cwd: "/tmp", pid: nil, transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        let session = ClaudeTerminalSession(agentId: "claude", sessionId: sid)
        await registry.attach(session)
        var events = session.events.makeAsyncIterator()
        _ = try await events.next()

        _ = await registry.ingestPermission([
            "session_id": sid, "hook_event_name": "PermissionRequest", "tool_name": "ExitPlanMode",
            "tool_input": ["plan": "# Plan\n1. do it"],
        ])
        let card = try await XCTUnwrapAsync(await events.next())
        XCTAssertEqual(card.metadata?["kind"], "plan")
        XCTAssertEqual(card.metadata?["plan"], "# Plan\n1. do it")
        XCTAssertEqual(card.metadata?["answerable"], "0")
        let problem = await registry.answer(sessionId: sid, requestId: try XCTUnwrap(card.messageId), decision: "allow", meta: [:])
        XCTAssertNotNil(problem)
        // ターンが終わればカードは閉じる
        _ = await registry.ingest(["session_id": sid, "hook_event_name": "Stop"])
        var resolved = false
        for _ in 0..<3 {
            guard let e = try await events.next() else { break }
            if e.type == .actionResolved { resolved = true; break }
        }
        XCTAssertTrue(resolved)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}
