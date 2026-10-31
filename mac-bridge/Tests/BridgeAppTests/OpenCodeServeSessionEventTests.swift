import XCTest
@testable import BridgeApp

/// OpenCodeServeSession の SSE イベント → SessionEvent 翻訳の単体テスト（サーバ不要）。
/// handleServeEvent に opencode serve と同じ形のイベントを直接流して検証する。
final class OpenCodeServeSessionEventTests: XCTestCase {

    /// close して stream を閉じ、それまでに流れたイベントを全部回収する。
    private func drain(_ session: OpenCodeServeSession) async -> [SessionEvent] {
        await session.close()
        var out: [SessionEvent] = []
        do {
            for try await event in session.events { out.append(event) }
        } catch {}
        return out
    }

    func testDeltaAndFinalPartAreNotDuplicatedAndIdleClosesOnce() async {
        let session = OpenCodeServeSession(sessionId: "ses_x", client: .shared)
        // send() 冒頭と同じリセット(POST は投げない)。始めはターンが閉じている。
        session.beginTurn()

        // ユーザー発言（POST 後に part として publish される）→ エコーしない。
        session.handleServeEvent(type: "message.updated", properties: [
            "info": ["id": "msg_u1", "role": "user"]
        ])
        session.handleServeEvent(type: "message.part.updated", properties: [
            "part": ["id": "prt_u", "messageID": "msg_u1", "type": "text", "text": "質問"]
        ])
        // アシスタント応答: 空の text part → delta 2 回 → text-end の全文。
        session.handleServeEvent(type: "message.updated", properties: [
            "info": ["id": "msg_a1", "role": "assistant", "parentID": "msg_u1"]
        ])
        session.handleServeEvent(type: "message.part.updated", properties: [
            "part": ["id": "prt_1", "messageID": "msg_a1", "type": "text", "text": ""]
        ])
        session.handleServeEvent(type: "message.part.delta", properties: [
            "partID": "prt_1", "messageID": "msg_a1", "field": "text", "delta": "こん"
        ])
        session.handleServeEvent(type: "message.part.delta", properties: [
            "partID": "prt_1", "messageID": "msg_a1", "field": "text", "delta": "にちは"
        ])
        session.handleServeEvent(type: "message.part.updated", properties: [
            "part": ["id": "prt_1", "messageID": "msg_a1", "type": "text", "text": "こんにちは"]
        ])
        session.handleServeEvent(type: "session.idle", properties: ["sessionID": "ses_x"])
        // 同じターン内で終端判定が重なっても(idle の重複等) done を増やさない。
        // (次ターンに遅れて届く idle は testLateIdleFromPreviousTurnDoesNotCloseNextTurn で見る)
        session.handleServeEvent(type: "session.idle", properties: ["sessionID": "ses_x"])

        let events = await drain(session)
        let text = events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertEqual(text, "こんにちは", "delta と全文の part.updated で二重化せず、ユーザー発言もエコーしない")
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1, "done はちょうど 1 回")
    }

    /// send() でターンを切り替えた後に前ターンの idle が遅れて届いても、次ターンを閉じない。
    /// (閉じると次ターンの part が done 後の遅延分として全部捨てられ、応答が表示されない)
    func testLateIdleFromPreviousTurnDoesNotCloseNextTurn() async {
        let session = OpenCodeServeSession(sessionId: "ses_x", client: .shared)

        // ターン1: 応答して idle で閉じる。
        session.beginTurn()
        session.handleServeEvent(type: "message.updated", properties: [
            "info": ["id": "msg_u1", "role": "user"]
        ])
        session.handleServeEvent(type: "message.updated", properties: [
            "info": ["id": "msg_a1", "role": "assistant", "parentID": "msg_u1"]
        ])
        session.handleServeEvent(type: "message.part.delta", properties: [
            "partID": "prt_1", "messageID": "msg_a1", "field": "text", "delta": "こんにちは"
        ])
        session.handleServeEvent(type: "session.idle", properties: ["sessionID": "ses_x"])

        // ターン2: send() 冒頭と同じリセット(POST は投げない)。
        session.beginTurn()
        // 前ターンの user message の再 publish(summary 更新等)はターン開始とみなさず、
        // その後に遅れて届いた前ターンの idle でも次ターンを閉じない。
        session.handleServeEvent(type: "message.updated", properties: [
            "info": ["id": "msg_u1", "role": "user"]
        ])
        session.handleServeEvent(type: "session.idle", properties: ["sessionID": "ses_x"])
        // 前ターンの assistant の遅延 part も次ターンに混ぜない。
        session.handleServeEvent(type: "message.part.delta", properties: [
            "partID": "prt_1", "messageID": "msg_a1", "field": "text", "delta": "(遅延)"
        ])
        // 次ターンの user message を観測してからの応答と idle で閉じる。
        session.handleServeEvent(type: "message.updated", properties: [
            "info": ["id": "msg_u2", "role": "user"]
        ])
        session.handleServeEvent(type: "message.updated", properties: [
            "info": ["id": "msg_a2", "role": "assistant", "parentID": "msg_u2"]
        ])
        session.handleServeEvent(type: "message.part.delta", properties: [
            "partID": "prt_2", "messageID": "msg_a2", "field": "text", "delta": "元気です"
        ])
        session.handleServeEvent(type: "session.idle", properties: ["sessionID": "ses_x"])

        let events = await drain(session)
        let doneIndices = events.indices.filter { events[$0].type == .done }
        guard doneIndices.count == 2 else {
            return XCTFail("done はターン毎に 1 回ずつ計 2 回のはず: \(doneIndices.count) 回")
        }
        func text(_ range: Range<Int>) -> String {
            events[range].filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        }
        XCTAssertEqual(text(0..<doneIndices[0]), "こんにちは", "ターン1の本文")
        XCTAssertEqual(text(doneIndices[0]..<doneIndices[1]), "元気です",
                       "遅延 idle で閉じられずターン2の本文が 2 回目の done の前に出る(前ターンの遅延 part は混ざらない)")
    }
}

/// 下の停止ボタン（interrupt）とツールの中断（docs/BACKGROUND_CONTROL_2026-10-21.md §4.4・§3.6）。
final class OpenCodeServeInterruptTests: XCTestCase {
    override func tearDown() {
        OpenCodeServeClient.shared.abortHook = nil
        super.tearDown()
    }

    private func drain(_ session: OpenCodeServeSession) async -> [SessionEvent] {
        await session.close()
        var out: [SessionEvent] = []
        do { for try await event in session.events { out.append(event) } } catch {}
        return out
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var aborts: [String] = []
        private var posts: [String] = []
        var abortList: [String] { lock.withLock { aborts } }
        var postList: [String] { lock.withLock { posts } }
        func abort(_ sid: String) { lock.withLock { aborts.append(sid) } }
        func post(_ path: String) { lock.withLock { posts.append(path) } }
    }

    /// ターンが動いていないとき（アイドル）の interrupt は abort しない（アイドル中の abort は背景の子まで止める。実測 e11）。
    /// 止まったことだけ done で伝え直す。
    func testIdleInterruptDoesNotAbortAndResendsDone() async {
        let calls = Calls()
        OpenCodeServeClient.shared.abortHook = { sid, _ in calls.abort(sid); return true }
        let session = OpenCodeServeSession(sessionId: "ses_idle_\(UUID().uuidString.prefix(8))", client: .shared)
        await session.interrupt()
        await session.interrupt()
        let events = await drain(session)
        XCTAssertTrue(calls.abortList.isEmpty)
        XCTAssertEqual(events.filter { $0.type == .done }.count, 2)
    }

    /// ターンが動いているときの interrupt は abort し、その後で保留中の承認・質問をサーバー側でも断る（abort では消えない。実測 e9b2）。
    /// アプリのカードは先に閉じる。
    func testInterruptAbortsThenRejectsPendingRequests() async {
        let calls = Calls()
        var order: [String] = []
        let session = OpenCodeServeSession(sessionId: "ses_busy_\(UUID().uuidString.prefix(8))", client: .shared)
        OpenCodeServeClient.shared.abortHook = { sid, _ in calls.abort(sid); calls.post("abort"); return true }
        session.postHook = { path, _ in calls.post(path) }
        session.notePostSent(session.beginTurn())
        session.handleServeEvent(type: "message.updated", properties: [
            "info": ["id": "msg_u", "role": "user"]])
        session.handleServeEvent(type: "permission.asked", properties: [
            "id": "per_1", "sessionID": session.sessionId, "permission": "bash", "patterns": ["ls"]])
        session.handleServeEvent(type: "question.asked", properties: [
            "id": "que_1", "sessionID": session.sessionId,
            "questions": [["question": "q", "header": "h", "options": [["label": "a"]]]]])
        await session.interrupt()
        order = calls.postList
        let events = await drain(session)
        XCTAssertEqual(calls.abortList, [session.sessionId])
        XCTAssertEqual(order.first, "abort", "abort の後に断る")
        XCTAssertEqual(Set(order.dropFirst()), ["permission/per_1/reply", "question/que_1/reject"])
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1)
        XCTAssertTrue(events.contains { $0.type == .actionResolved })
    }

    private func toolEnd(error: String) async -> String? {
        let session = OpenCodeServeSession(sessionId: "ses_tool_\(UUID().uuidString.prefix(8))", client: .shared)
        session.notePostSent(session.beginTurn())
        session.handleServeEvent(type: "message.updated", properties: ["info": ["id": "msg_u", "role": "user"]])
        for status in ["running", "error"] {
            var state: [String: Any] = ["status": status, "input": ["command": "sleep 9"]]
            if status == "error" { state["error"] = error }
            session.handleServeEvent(type: "message.part.updated", properties: ["part": [
                "id": "prt", "messageID": "msg_a", "type": "tool", "tool": "bash", "callID": "call_t", "state": state]])
        }
        let events = await drain(session)
        return events.first { $0.type == .toolEnd }?.metadata?["status"]
    }

    /// 中断で終わったツール（Tool execution aborted・Task cancelled）の tool_end は interrupted。ほかのエラーは failed のまま。
    func testAbortedToolEndsAsInterruptedAndOtherErrorsFail() async {
        let aborted = await toolEnd(error: "Tool execution aborted")
        let cancelled = await toolEnd(error: "Task cancelled")
        let broken = await toolEnd(error: "command not found")
        XCTAssertEqual(aborted, "interrupted")
        XCTAssertEqual(cancelled, "interrupted")
        XCTAssertEqual(broken, "failed")
    }
}
