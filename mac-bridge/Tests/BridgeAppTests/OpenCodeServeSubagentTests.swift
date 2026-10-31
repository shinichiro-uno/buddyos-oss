import XCTest
@testable import BridgeApp

/// OpenCodeServeSession のサブエージェント（task）の行と、自分が送っていないターン（ターミナルの TUI・裏で動いていた
/// 子の結果の差し込み）の扱い。opencode 1.18.32 の実測（docs/BACKGROUND_WORK_2026-10-21.md §1.3・§3.6）と同じ形の
/// イベントを流す。子セッションのイベントは OpenCodeServeClient.dispatchEvent を通し、親への回し方まで確かめる。
final class OpenCodeServeSubagentTests: XCTestCase {

    /// abort は 200 で本文 `true` を返す(実測 e1b)。トップレベルの値も読めないと、行の停止が毎回 failed になる。
    func testTopLevelBooleanBodyIsDecoded() throws {
        XCTAssertEqual(try OpenCodeServeClient.decodeBody(Data("true".utf8)) as? Bool, true)
        XCTAssertEqual(try OpenCodeServeClient.decodeBody(Data("false".utf8)) as? Bool, false)
        XCTAssertNotNil(try OpenCodeServeClient.decodeBody(Data("{\"a\":1}".utf8)) as? [String: Any])
    }

    private func makeSession() -> OpenCodeServeSession {
        OpenCodeServeSession(sessionId: "ses_p\(UUID().uuidString.prefix(8))", client: .shared)
    }

    /// close して stream を閉じ、それまでに流れたイベントを全部回収する。
    private func drain(_ session: OpenCodeServeSession) async -> [SessionEvent] {
        await session.close()
        var out: [SessionEvent] = []
        do {
            for try await event in session.events { out.append(event) }
        } catch {}
        return out
    }

    /// `/global/event` の 1 フレームとして client に流す（sessionID でセッションへ振り分けられる）。
    private func dispatch(_ type: String, _ props: [String: Any]) {
        let frame: [String: Any] = ["directory": "/tmp", "payload": ["type": type, "properties": props]]
        OpenCodeServeClient.shared.dispatchEvent(try! JSONSerialization.data(withJSONObject: frame))
    }

    private var nowMs: Double { Date().timeIntervalSince1970 * 1000 }

    private func user(_ session: OpenCodeServeSession, _ id: String, createdMs: Double? = nil) {
        session.handleServeEvent(type: "message.updated", properties: [
            "sessionID": session.sessionId,
            "info": ["id": id, "role": "user", "time": ["created": createdMs ?? nowMs]]
        ])
    }

    private func assistant(_ session: OpenCodeServeSession, _ id: String, parent: String) {
        session.handleServeEvent(type: "message.updated", properties: [
            "sessionID": session.sessionId,
            "info": ["id": id, "role": "assistant", "parentID": parent, "time": ["created": nowMs]]
        ])
    }

    private func delta(_ session: OpenCodeServeSession, _ messageId: String, _ text: String) {
        session.handleServeEvent(type: "message.part.delta", properties: [
            "sessionID": session.sessionId, "messageID": messageId,
            "partID": "prt_\(messageId)", "field": "text", "delta": text
        ])
    }

    private func idle(_ session: OpenCodeServeSession) {
        session.handleServeEvent(type: "session.idle", properties: ["sessionID": session.sessionId])
    }

    private func taskPart(_ session: OpenCodeServeSession, messageId: String, callID: String,
                          state: [String: Any]) {
        session.handleServeEvent(type: "message.part.updated", properties: [
            "sessionID": session.sessionId,
            "part": ["id": "prt_\(callID)", "messageID": messageId, "sessionID": session.sessionId,
                     "type": "tool", "tool": "task", "callID": callID, "state": state]
        ])
    }

    /// 流れた workflow_progress（subagents）の行を、届いた順に返す。
    private func rows(_ events: [SessionEvent], id: String? = nil) -> [[String: Any]] {
        events.filter { $0.type == .workflowProgress }.flatMap { e -> [[String: Any]] in
            guard let data = e.content?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["taskId"] as? String == "subagents" else { return [] }
            return (obj["agents"] as? [[String: Any]]) ?? []
        }.filter { id == nil || $0["id"] as? String == id }
    }

    private func text(_ events: ArraySlice<SessionEvent>) -> String {
        events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
    }

    // MARK: - 前景の task

    /// 子セッションのツールの title が行の作業の文とツール回数に、assistant の tokens・model が行に入り、
    /// `<task id=… state="completed"><task_result>` の中身が結果になる。子の idle は親のターンを閉じない。
    func testForegroundTaskShowsChildProgressAndParsedResult() async {
        let session = makeSession()
        let parent = session.sessionId
        let child = "ses_c\(UUID().uuidString.prefix(8))"
        session.notePostSent(session.beginTurn())
        user(session, "msg_u1")
        assistant(session, "msg_a1", parent: "msg_u1")
        taskPart(session, messageId: "msg_a1", callID: "call_fg", state: ["status": "pending", "input": [String: Any]()])
        dispatch("session.created", ["sessionID": child, "info": ["id": child, "parentID": parent,
                                                                  "title": "List scratch dir (@general subagent)"]])
        taskPart(session, messageId: "msg_a1", callID: "call_fg", state: [
            "status": "running", "title": "List scratch dir",
            "input": ["description": "List scratch dir", "prompt": "Run ls -la", "subagent_type": "general"],
            "metadata": ["parentSessionId": parent, "sessionId": child,
                         "model": ["modelID": "big-pickle", "providerID": "opencode"]]
        ])
        // 子セッションのイベント（sessionID = 子）。ルートを持つ親の行に回る。
        dispatch("message.updated", ["sessionID": child, "info": ["id": "msg_cu", "role": "user", "sessionID": child]])
        dispatch("message.part.updated", ["sessionID": child, "part": [
            "id": "prt_cu", "messageID": "msg_cu", "sessionID": child, "type": "text", "text": "Run ls -la"]])
        dispatch("session.status", ["sessionID": child, "status": ["type": "busy"]])
        dispatch("message.updated", ["sessionID": child, "info": [
            "id": "msg_ca1", "role": "assistant", "parentID": "msg_cu", "modelID": "big-pickle",
            "tokens": ["input": 0, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0]]]])
        for state: [String: Any] in [
            ["status": "pending", "input": [String: Any]()],
            ["status": "running", "input": ["command": "ls -la"]],
            ["status": "running", "input": ["command": "ls -la"], "metadata": ["output": "total 0\n"]],
            ["status": "completed", "input": ["command": "ls -la"], "title": "ls -la", "output": "total 0\n"],
        ] {
            dispatch("message.part.updated", ["sessionID": child, "part": [
                "id": "prt_b1", "messageID": "msg_ca1", "sessionID": child, "type": "tool", "tool": "bash",
                "callID": "call_b1", "state": state]])
        }
        dispatch("message.updated", ["sessionID": child, "info": [
            "id": "msg_ca1", "role": "assistant", "parentID": "msg_cu", "modelID": "big-pickle",
            "tokens": ["total": 5387, "input": 5137, "output": 23, "reasoning": 63, "cache": ["read": 164, "write": 0]]]])
        dispatch("message.updated", ["sessionID": child, "info": [
            "id": "msg_ca2", "role": "assistant", "parentID": "msg_cu", "modelID": "big-pickle",
            "tokens": ["total": 5599, "input": 81, "output": 8, "reasoning": 207, "cache": ["read": 5303, "write": 0]]]])
        dispatch("message.part.updated", ["sessionID": child, "part": [
            "id": "prt_ct", "messageID": "msg_ca2", "sessionID": child, "type": "text", "text": "2"]])
        dispatch("session.status", ["sessionID": child, "status": ["type": "idle"]])
        dispatch("session.idle", ["sessionID": child])
        taskPart(session, messageId: "msg_a1", callID: "call_fg", state: [
            "status": "completed", "title": "List scratch dir",
            "input": ["description": "List scratch dir", "prompt": "Run ls -la", "subagent_type": "general"],
            "output": "<task id=\"\(child)\" state=\"completed\">\n<task_result>\n2\n</task_result>\n</task>",
            "metadata": ["parentSessionId": parent, "sessionId": child, "truncated": false]
        ])
        assistant(session, "msg_a2", parent: "msg_u1")
        delta(session, "msg_a2", "DONE 2")
        idle(session)

        let events = await drain(session)
        let doneIdx = events.indices.filter { events[$0].type == .done }
        XCTAssertEqual(doneIdx.count, 1, "子の idle は親のターンを閉じない")
        XCTAssertEqual(text(events[...]), "DONE 2", "子の本文やツールは親の本文に混ぜない")
        XCTAssertFalse(events.contains { $0.type == .toolStart && $0.toolUseId == "call_b1" }, "子のツールは親のツールの行にしない")
        let all = rows(events, id: "call_fg")
        XCTAssertTrue(all.contains { $0["state"] as? String == "running" && $0["resultPreview"] as? String == "bash: ls -la" },
                      "実行中は子のツールの title を作業の文にする: \(all)")
        guard let last = all.last else { return XCTFail("行が流れていない") }
        XCTAssertEqual(last["state"] as? String, "done")
        XCTAssertEqual(last["label"] as? String, "List scratch dir")
        XCTAssertEqual(last["agentType"] as? String, "general")
        XCTAssertEqual(last["model"] as? String, "big-pickle")
        XCTAssertEqual(last["toolCalls"] as? Int, 1, "同じツール呼び出しの更新は 1 回に数える")
        XCTAssertEqual(last["tokens"] as? Int, 5387 + 5599, "子の assistant ごとのトークンの合計")
        XCTAssertEqual(last["background"] as? Bool, false)
        XCTAssertEqual(last["resultPreview"] as? String, "2", "<task_result> の中身を結果にする（囲みを出さない）")
        XCTAssertEqual(last["result"] as? String, "2")
        let lastRowEvent = events.lastIndex { $0.type == .workflowProgress } ?? 0
        XCTAssertLessThan(lastRowEvent, doneIdx[0], "行を閉じてから done")
    }

    /// `state="error"` の `<task_error>` は failed。中断（「Tool execution aborted」）は stopped。
    func testTaskErrorsAreFailedAndAbortsAreStopped() async {
        let session = makeSession()
        session.notePostSent(session.beginTurn())
        user(session, "msg_u1")
        assistant(session, "msg_a1", parent: "msg_u1")
        let input: [String: Any] = ["description": "Do it", "subagent_type": "general"]
        for id in ["call_e", "call_abort", "call_fail"] {
            taskPart(session, messageId: "msg_a1", callID: id, state: ["status": "running", "input": input])
        }
        taskPart(session, messageId: "msg_a1", callID: "call_e", state: [
            "status": "completed", "input": input,
            "output": "<task id=\"ses_e\" state=\"error\">\n<task_error>\nboom\n</task_error>\n</task>"])
        taskPart(session, messageId: "msg_a1", callID: "call_abort", state: [
            "status": "error", "input": input, "error": "Tool execution aborted"])
        taskPart(session, messageId: "msg_a1", callID: "call_fail", state: [
            "status": "error", "input": input, "error": "Rate limit exceeded"])
        idle(session)

        let events = await drain(session)
        XCTAssertEqual(rows(events, id: "call_e").last?["state"] as? String, "failed")
        XCTAssertEqual(rows(events, id: "call_e").last?["result"] as? String, "boom")
        XCTAssertEqual(rows(events, id: "call_abort").last?["state"] as? String, "stopped", "止めたものは失敗ではない")
        XCTAssertEqual(rows(events, id: "call_fail").last?["state"] as? String, "failed")
    }

    // MARK: - 中断・終了

    /// 停止で前景の task は stopped で閉じる。後から届いた task の error（abort で子が止まった）は、
    /// 閉じたターンでも行に反映するが、stopped を failed に変えない。
    func testInterruptStopsForegroundTaskAndLateErrorKeepsStopped() async {
        let session = makeSession()
        let child = "ses_c\(UUID().uuidString.prefix(8))"
        session.notePostSent(session.beginTurn())
        user(session, "msg_u1")
        assistant(session, "msg_a1", parent: "msg_u1")
        taskPart(session, messageId: "msg_a1", callID: "call_i", state: [
            "status": "running", "input": ["description": "Explore", "subagent_type": "explore"],
            "metadata": ["parentSessionId": session.sessionId, "sessionId": child]])
        await session.interrupt()
        taskPart(session, messageId: "msg_a1", callID: "call_i", state: [
            "status": "error", "input": ["description": "Explore"], "error": "Task cancelled"])
        // 閉じたターンでも、知らない task の part は行にしない。
        taskPart(session, messageId: "msg_a1", callID: "call_unknown", state: [
            "status": "completed", "input": ["description": "Other"], "output": "x"])

        let events = await drain(session)
        let all = rows(events, id: "call_i")
        XCTAssertEqual(all.last?["state"] as? String, "stopped", "中断した前景の task は stopped: \(all)")
        XCTAssertFalse(all.contains { $0["state"] as? String == "failed" })
        XCTAssertTrue(rows(events, id: "call_unknown").isEmpty)
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1)
    }

    /// close は実行中の行を（裏で動く task も）stopped で閉じてから stream を閉じる。
    func testCloseStopsRunningRows() async {
        let session = makeSession()
        session.notePostSent(session.beginTurn())
        user(session, "msg_u1")
        assistant(session, "msg_a1", parent: "msg_u1")
        taskPart(session, messageId: "msg_a1", callID: "call_bg", state: [
            "status": "running", "input": ["description": "Slow", "background": true],
            "metadata": ["sessionId": "ses_bgc\(UUID().uuidString.prefix(6))", "background": true]])
        idle(session)
        let events = await drain(session)
        XCTAssertEqual(rows(events, id: "call_bg").last?["state"] as? String, "stopped")
    }

    /// serve の終了では、子も一緒に止まるので実行中の行を（裏で動く task も）failed で閉じる。
    func testServerExitFailsRunningRows() async {
        let session = makeSession()
        session.notePostSent(session.beginTurn())
        user(session, "msg_u1")
        assistant(session, "msg_a1", parent: "msg_u1")
        taskPart(session, messageId: "msg_a1", callID: "call_bg", state: [
            "status": "running", "input": ["description": "Slow", "background": true],
            "metadata": ["sessionId": "ses_bgc\(UUID().uuidString.prefix(6))", "background": true]])
        idle(session)
        session.serverDidExit()
        let events = await drain(session)
        let all = rows(events, id: "call_bg")
        XCTAssertEqual(all.last?["state"] as? String, "failed", "\(all)")
        XCTAssertEqual(all.filter { $0["state"] as? String != "running" }.count, 1, "close では閉じ直さない")
    }

    // MARK: - background の task と知らせのターン

    /// background の task はすぐ completed（state="running"）になるが、行は実行中のまま持ち、子の idle で閉じる。
    /// 子が終わると opencode が親へ synthetic な `<task id=子 state="completed">` を差し込んで新しいターンを回すので、
    /// それを知らせのターンとして本文と done（origin = task-notification）を流す。
    func testBackgroundTaskClosesOnChildIdleAndInjectionOpensNotificationTurn() async {
        let session = makeSession()
        let parent = session.sessionId
        let child = "ses_c\(UUID().uuidString.prefix(8))"
        session.notePostSent(session.beginTurn())
        user(session, "msg_u1")
        assistant(session, "msg_a1", parent: "msg_u1")
        taskPart(session, messageId: "msg_a1", callID: "call_bg", state: ["status": "pending", "input": [String: Any]()])
        dispatch("session.created", ["sessionID": child, "info": ["id": child, "parentID": parent]])
        let input: [String: Any] = ["description": "Slow sleeper", "prompt": "sleep 20", "subagent_type": "general",
                                    "background": true]
        taskPart(session, messageId: "msg_a1", callID: "call_bg", state: [
            "status": "running", "title": "Slow sleeper", "input": input,
            "metadata": ["parentSessionId": parent, "sessionId": child, "background": true,
                         "model": ["modelID": "big-pickle", "providerID": "opencode"]]])
        taskPart(session, messageId: "msg_a1", callID: "call_bg", state: [
            "status": "completed", "title": "Slow sleeper", "input": input,
            "output": "<task id=\"\(child)\" state=\"running\">\n<summary>Background task started</summary>\n"
                + "<task_result>\nThe task is working in the background.\n</task_result>\n</task>",
            "metadata": ["parentSessionId": parent, "sessionId": child, "background": true, "jobId": child]])
        delta(session, "msg_a1", "LAUNCHED")
        idle(session)
        let snapshot = await session.subagentSnapshot()

        // 親のターンが終わった後の子の進み具合と終わり。
        dispatch("message.updated", ["sessionID": child, "info": [
            "id": "msg_ca", "role": "assistant", "parentID": "msg_cu", "modelID": "big-pickle"]])
        dispatch("message.part.updated", ["sessionID": child, "part": [
            "id": "prt_cb", "messageID": "msg_ca", "sessionID": child, "type": "tool", "tool": "bash",
            "callID": "call_sleep", "state": ["status": "running", "input": ["command": "sleep 20"]]]])
        dispatch("message.part.updated", ["sessionID": child, "part": [
            "id": "prt_ct", "messageID": "msg_ca", "sessionID": child, "type": "text", "text": "slept"]])
        dispatch("session.status", ["sessionID": child, "status": ["type": "idle"]])
        dispatch("session.idle", ["sessionID": child])

        // 差し込まれた子の結果で、親の新しいターンが回る。
        user(session, "msg_u2")
        session.handleServeEvent(type: "message.part.updated", properties: [
            "sessionID": parent,
            "part": ["id": "prt_inj", "messageID": "msg_u2", "sessionID": parent, "type": "text", "synthetic": true,
                     "text": "<task id=\"\(child)\" state=\"completed\">\n<summary>Background task completed: Slow sleeper"
                        + "</summary>\n<task_result>\nslept\n</task_result>\n</task>"]])
        assistant(session, "msg_a3", parent: "msg_u2")
        delta(session, "msg_a3", "DONE")
        idle(session)

        let events = await drain(session)
        let doneIdx = events.indices.filter { events[$0].type == .done }
        guard doneIdx.count == 2 else { return XCTFail("done は自分のターンと知らせのターンで 2 回: \(doneIdx.count)") }
        XCTAssertNil(events[doneIdx[0]].metadata?["origin"])
        XCTAssertEqual(events[doneIdx[1]].metadata?["origin"], "task-notification")
        XCTAssertEqual(text(events[..<doneIdx[0]]), "LAUNCHED")
        XCTAssertEqual(text(events[doneIdx[0]..<doneIdx[1]]), "DONE", "知らせのターンの本文を流す")
        XCTAssertFalse(events.contains { $0.type == .userMessage }, "差し込みは発言として流さない")

        let all = rows(events, id: "call_bg")
        let beforeIdle = rows(Array(events[..<doneIdx[0]]), id: "call_bg")
        XCTAssertEqual(beforeIdle.last?["state"] as? String, "running", "state=\"running\" の出力では終わりにしない: \(beforeIdle)")
        XCTAssertEqual(beforeIdle.last?["background"] as? Bool, true)
        XCTAssertEqual(all.last?["state"] as? String, "done")
        XCTAssertEqual(all.last?["result"] as? String, "slept")
        XCTAssertTrue(all.contains { $0["resultPreview"] as? String == "bash: sleep 20" }, "親のターンの後も子の作業を出す")

        // 親のターンが終わった時点のスナップショットにも、実行中の行が入る。
        let snap = snapshot.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(snap?["subtype"] as? String, "workflow_snapshot")
        let snapRows = snap?["agents"] as? [[String: Any]] ?? []
        XCTAssertEqual(snapRows.first?["state"] as? String, "running")
        XCTAssertNotNil(snap?["epoch"] as? String)
    }

    // MARK: - 自分が送っていないターン

    /// 自分のターンが閉じた後に、ほかの画面（ターミナルの TUI）の発言が来たら、別のターンとして発言・本文・done を流す。
    /// 前からある発言の再 publish（作られたのが古い）では開かない。
    func testTerminalTurnAfterOurTurnIsStreamedWithEcho() async {
        let session = makeSession()
        session.notePostSent(session.beginTurn())
        user(session, "msg_u1")
        session.handleServeEvent(type: "message.part.updated", properties: [
            "part": ["id": "prt_u1", "messageID": "msg_u1", "type": "text", "text": "自分の質問"]])
        assistant(session, "msg_a1", parent: "msg_u1")
        delta(session, "msg_a1", "A")
        idle(session)

        user(session, "msg_u2")
        session.handleServeEvent(type: "message.part.updated", properties: [
            "part": ["id": "prt_u2", "messageID": "msg_u2", "type": "text", "text": "ターミナルから"]])
        assistant(session, "msg_a2", parent: "msg_u2")
        delta(session, "msg_a2", "B")
        idle(session)

        user(session, "msg_old", createdMs: nowMs - 600_000)
        assistant(session, "msg_aold", parent: "msg_old")
        delta(session, "msg_aold", "old")
        idle(session)

        let events = await drain(session)
        let doneIdx = events.indices.filter { events[$0].type == .done }
        guard doneIdx.count == 2 else { return XCTFail("done は 2 回: \(doneIdx.count)") }
        let echoes = events.filter { $0.type == .userMessage }.compactMap(\.content)
        XCTAssertEqual(echoes, ["ターミナルから"], "自分の送信は流さず、ほかの画面の発言だけ 1 回流す")
        XCTAssertEqual(text(events[doneIdx[0]..<doneIdx[1]]), "B")
        XCTAssertNil(events[doneIdx[1]].metadata?["origin"])
        XCTAssertFalse(text(events[...]).contains("old"), "古い発言の再 publish ではターンを開かない")
    }

    /// 中断した自分の送信の発言が後から届いても、ほかの画面のターンとして開かない（その返事は捨てる）。
    func testLateUserMessageOfInterruptedSendDoesNotOpenTurn() async {
        let session = makeSession()
        session.notePostSent(session.beginTurn())
        await session.interrupt()
        user(session, "msg_u1")
        assistant(session, "msg_a1", parent: "msg_u1")
        delta(session, "msg_a1", "late")
        idle(session)

        let events = await drain(session)
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1, "中断の done だけ")
        XCTAssertEqual(text(events[...]), "")
    }

    func testSnapshotWithoutRowsIsEmptyList() async {
        let session = makeSession()
        let snapshot = await session.subagentSnapshot()
        let obj = snapshot.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(obj?["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(obj?["kind"] as? String, "subagents")
        XCTAssertEqual((obj?["agents"] as? [Any])?.count, 0)
        _ = await drain(session)
    }

    func testTaskOutputSessionId() {
        XCTAssertEqual(OpenCodeServeSession.taskOutputSessionId(
            "<task id=\"ses_ea64\" state=\"completed\">\n<task_result>\n2\n</task_result>\n</task>"), "ses_ea64")
        XCTAssertEqual(OpenCodeServeSession.taskOutputSessionId("<task state=\"running\" id=\"ses_b\">"), "ses_b")
        XCTAssertNil(OpenCodeServeSession.taskOutputSessionId("<task task_id=\"x\">"))
        XCTAssertNil(OpenCodeServeSession.taskOutputSessionId("plain text"))
    }
}

// MARK: - 行ごとの停止（docs/BACKGROUND_CONTROL_2026-10-21.md §3.6）

/// shared/fixtures/background-control/opencode-stop（opencode 1.18.32 の `serve` の SSE 記録。`{t, kind: sse|probe, ...}`）。
private struct OpenCodeStopFixture {
    let lines: [[String: Any]]

    init(_ name: String) throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BridgeAppTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // mac-bridge/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("shared/fixtures/background-control/opencode-stop")
        let text = try String(contentsOf: dir.appendingPathComponent("\(name).events.jsonl"), encoding: .utf8)
        lines = text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    /// 記録の行番号(0 始まり)の範囲の SSE フレーム(`/global/event` の 1 フレームと同じ形)。
    func frames(_ range: Range<Int>) -> [Data] {
        lines.enumerated().compactMap { n, line in
            guard range.contains(n), line["kind"] as? String == "sse", let frame = line["frame"] else { return nil }
            return try? JSONSerialization.data(withJSONObject: frame)
        }
    }

    /// probe の what が合う最初の行番号。
    func probe(_ what: String) -> Int {
        lines.firstIndex { $0["kind"] as? String == "probe" && $0["what"] as? String == what } ?? -1
    }

    /// SSE のイベントの type が合う最初の行番号。
    func event(_ type: String, where match: ([String: Any]) -> Bool = { _ in true }) -> Int {
        lines.firstIndex { line in
            guard line["kind"] as? String == "sse",
                  let payload = (line["frame"] as? [String: Any])?["payload"] as? [String: Any],
                  payload["type"] as? String == type else { return false }
            return match(payload["properties"] as? [String: Any] ?? [:])
        } ?? -1
    }
}

private final class OpenCodeStopRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var abortsStorage: [String] = []
    private var postsStorage: [(path: String, body: [String: Any])] = []
    var aborts: [String] { lock.withLock { abortsStorage } }
    var posts: [(path: String, body: [String: Any])] { lock.withLock { postsStorage } }
    func abort(_ sid: String) { lock.withLock { abortsStorage.append(sid) } }
    func post(_ path: String, _ body: [String: Any]) { lock.withLock { postsStorage.append((path, body)) } }
}

final class OpenCodeServeStopTaskTests: XCTestCase {
    override func tearDown() {
        OpenCodeServeClient.shared.abortHook = nil
        super.tearDown()
    }

    private func obj(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func replay(_ frames: [Data]) {
        frames.forEach(OpenCodeServeClient.shared.dispatchEvent)
    }

    private func drain(_ session: OpenCodeServeSession) async -> [SessionEvent] {
        await session.close()
        var out: [SessionEvent] = []
        do { for try await event in session.events { out.append(event) } } catch {}
        return out
    }

    private func rows(_ events: [SessionEvent], id: String) -> [[String: Any]] {
        events.filter { $0.type == .workflowProgress }.flatMap { e -> [[String: Any]] in
            (e.content.map(obj)?["agents"] as? [[String: Any]]) ?? []
        }.filter { $0["id"] as? String == id }
    }

    private func states(_ events: [SessionEvent], id: String) -> [String] {
        rows(events, id: id).compactMap { $0["state"] as? String }
    }

    private func row(_ session: OpenCodeServeSession, _ id: String) async -> [String: Any]? {
        let snapshot = await session.subagentSnapshot()
        return (snapshot.map(obj)?["agents"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    private func rowOrFail(_ session: OpenCodeServeSession, _ id: String) async throws -> [String: Any] {
        let found = await row(session, id)
        return try XCTUnwrap(found)
    }

    private func request(_ session: OpenCodeServeSession, _ id: String) async -> StopTaskRequest {
        let snapshot = await session.subagentSnapshot()
        return StopTaskRequest(taskId: "subagents", rowId: id, epoch: snapshot.map(obj)?["epoch"] as? String)
    }

    private func stop(_ session: OpenCodeServeSession, _ id: String) async -> StopTaskOutcome {
        await session.stopTask(request(session, id))
    }

    /// 親のターンを自分の送信として開く(記録の最初の user message が、そのターンのものになる)。
    private func openTurn(_ parent: String) -> OpenCodeServeSession {
        let session = OpenCodeServeSession(sessionId: parent, client: .shared)
        session.notePostSent(session.beginTurn())
        session.stopSettleSeconds = 0.5
        return session
    }

    /// e1b: 前景の子 1 つを止める。abort は子だけに送る。親の task の part が Task cancelled で届いて行は stopped、
    /// task の tool_end は interrupted（赤くしない）。親のターンはそのまま続き、done は 1 回。
    func testStopForegroundChildEndsRowAsStoppedAndParentTurnContinues() async throws {
        let f = try OpenCodeStopFixture("e1b-abort-child")
        let parent = "ses_ea1c307efffe65t16u3tCDy2iq"
        let child = "ses_ea1c2f7fbffetg4wPJb8wFEz5C"
        let call = "call_00_V9AQ7I78Wc0nzMbcCAou4156"
        let sent = f.probe("stop-sent"), response = f.probe("stop-response")
        let session = openTurn(parent)
        replay(f.frames(0..<sent))
        let before = try await rowOrFail(session, call)
        XCTAssertEqual(before["state"] as? String, "running")
        XCTAssertEqual(before["stoppable"] as? Bool, true)

        let rec = OpenCodeStopRecorder()
        OpenCodeServeClient.shared.abortHook = { sid, _ in
            rec.abort(sid)
            self.replay(f.frames((sent + 1)..<response))
            return true
        }
        let outcome = await stop(session, call)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(rec.aborts, [child], "親ではなく子にだけ abort を送る")
        replay(f.frames((response + 1)..<f.lines.count))
        let events = await drain(session)
        XCTAssertEqual(states(events, id: call).last, "stopped")
        XCTAssertFalse(states(events, id: call).contains("failed"))
        let flags = rows(events, id: call).compactMap { $0["stoppable"] as? Bool }
        XCTAssertTrue(flags.contains(true), "子の id が分かると止められる")
        XCTAssertEqual(flags.last, false)
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1)
        XCTAssertEqual(events.first { $0.type == .toolEnd && $0.toolUseId == call }?.metadata?["status"], "interrupted")
        XCTAssertTrue(events.filter { $0.type == .error }.isEmpty)
    }

    /// e3: 2 つの前景の子のうち片方だけ止める。もう片方は動き続け、後で done になる。
    func testStopOneOfTwoChildrenLeavesTheOtherRunning() async throws {
        let f = try OpenCodeStopFixture("e3-two-children")
        let parent = "ses_ea1c262b7ffepd732yF5Ep1DjP"
        let callA = "call_00_ET_YIOMlKMVbN1Gj2zThJYf1620"
        let callB = "call_01_ET_Xz3XJM434PxgKto5vKvi2880"
        let sent = f.probe("stop-sent"), response = f.probe("stop-response")
        let session = openTurn(parent)
        replay(f.frames(0..<sent))
        let rec = OpenCodeStopRecorder()
        OpenCodeServeClient.shared.abortHook = { sid, _ in
            rec.abort(sid)
            self.replay(f.frames((sent + 1)..<response))
            return true
        }
        let outcome = await stop(session, callA)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(rec.aborts, ["ses_ea1c22c50ffeKfilLdhR7K5CPA"])
        let other = try await rowOrFail(session, callB)
        XCTAssertEqual(other["state"] as? String, "running")
        XCTAssertEqual(other["stoppable"] as? Bool, true)
        replay(f.frames((response + 1)..<f.lines.count))
        let events = await drain(session)
        XCTAssertEqual(states(events, id: callA).last, "stopped")
        XCTAssertEqual(states(events, id: callB).last, "done")
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1)
    }

    /// e6: 背景の子（親のターンは終わっている）。子の session.error(MessageAbortedError) と idle で行が stopped になる。
    func testStopBackgroundChildClosesOnChildAbortAndIdle() async throws {
        let f = try OpenCodeStopFixture("e6-bg-abort")
        let parent = "ses_ea1bde5ccffeDuFx4RHGccqZhd"
        let child = "ses_ea1bdd79dffeM6gWqYLBZvRE4N"
        let call = "call_00_glfke4n3ftz97wv44yycmg6q"
        let sent = f.probe("abort-child-sent"), response = f.probe("abort-child-response")
        let session = openTurn(parent)
        replay(f.frames(0..<sent))
        let before = try await rowOrFail(session, call)
        XCTAssertEqual(before["state"] as? String, "running")
        XCTAssertEqual(before["background"] as? Bool, true)
        XCTAssertEqual(before["stoppable"] as? Bool, true)
        OpenCodeServeClient.shared.abortHook = { sid, _ in
            XCTAssertEqual(sid, child)
            self.replay(f.frames((sent + 1)..<response))
            return true
        }
        let outcome = await stop(session, call)
        XCTAssertEqual(outcome, .stopped)
        let events = await drain(session)
        XCTAssertEqual(states(events, id: call).last, "stopped")
        XCTAssertFalse(states(events, id: call).contains("done"))
    }

    /// e9b2: 子が承認待ち。abort では消えないので、子の permission を POST /permission/<id>/reply {reject} で断る。
    /// 断った後の permission.replied で、iPhone に出していたカードが閉じる。
    func testStopRejectsPendingPermissionOfTheChild() async throws {
        let f = try OpenCodeStopFixture("e9b2-edge-B2")
        let parent = "ses_ea1b711a1ffejQ805lcMHCdUwC"
        let child = "ses_ea1b70232ffeEaKjEJa8unoOXy"
        let call = "call_00_4qk53ettf73ak50ija5ep34p"
        let permission = "per_15e49028b001frQJiEGPFs353D"
        let marker = f.probe("abort-while-permission")
        let parentError = f.event("session.error") { $0["sessionID"] as? String == parent }
        let replied = f.event("permission.replied")
        let session = openTurn(parent)
        let rec = OpenCodeStopRecorder()
        session.postHook = { path, body in rec.post(path, body) }
        replay(f.frames(0..<marker))
        OpenCodeServeClient.shared.abortHook = { sid, _ in
            rec.abort(sid)
            // abort は子と task の part を片付けるが、承認は残す（記録: pending-after-abort）。
            self.replay(f.frames((marker + 1)..<parentError))
            return true
        }
        let outcome = await stop(session, call)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(rec.aborts, [child])
        XCTAssertEqual(rec.posts.count, 1)
        XCTAssertEqual(rec.posts.first?.path, "permission/\(permission)/reply")
        XCTAssertEqual(rec.posts.first?.body["reply"] as? String, "reject")
        replay(f.frames(replied..<(replied + 1)))
        let events = await drain(session)
        XCTAssertEqual(events.filter { $0.type == .actionRequest }.count, 1)
        XCTAssertEqual(events.filter { $0.type == .actionResolved }.count, 1)
    }

    /// 子の子孫の承認・質問も断る。無関係なセッション（兄弟の子）の要求は断らない。質問は POST /question/<id>/reject。
    func testStopRejectsDescendantRequestsButNotUnrelatedOnes() async throws {
        let parent = "ses_p\(UUID().uuidString.prefix(8))"
        let child = "ses_c\(UUID().uuidString.prefix(8))"
        let grandchild = "ses_g\(UUID().uuidString.prefix(8))"
        let sibling = "ses_s\(UUID().uuidString.prefix(8))"
        let call = "call_stop"
        let session = openTurn(parent)
        let rec = OpenCodeStopRecorder()
        session.postHook = { path, body in rec.post(path, body) }
        session.handleServeEvent(type: "message.updated", properties: [
            "sessionID": parent, "info": ["id": "msg_u", "role": "user", "time": ["created": Date().timeIntervalSince1970 * 1000]]])
        for (id, up) in [(child, parent), (grandchild, child), (sibling, parent)] {
            replay([try JSONSerialization.data(withJSONObject: ["payload": ["type": "session.created", "properties": [
                "sessionID": id, "info": ["id": id, "parentID": up]]]])])
        }
        session.handleServeEvent(type: "message.part.updated", properties: ["sessionID": parent, "part": [
            "id": "prt", "messageID": "msg_a", "sessionID": parent, "type": "tool", "tool": "task", "callID": call,
            "state": ["status": "running", "input": ["description": "d"],
                      "metadata": ["parentSessionId": parent, "sessionId": child]]]])
        func ask(_ type: String, _ id: String, from sid: String) {
            var props: [String: Any] = ["id": id, "sessionID": sid]
            if type == "question.asked" { props["questions"] = [["question": "q", "header": "h", "options": [["label": "a"]]]] }
            else { props["permission"] = "external_directory"; props["patterns"] = ["/etc/*"] }
            replay([try! JSONSerialization.data(withJSONObject: ["payload": ["type": type, "properties": props]])])
        }
        ask("permission.asked", "per_child", from: child)
        ask("permission.asked", "per_grand", from: grandchild)
        ask("question.asked", "que_grand", from: grandchild)
        ask("permission.asked", "per_sibling", from: sibling)
        OpenCodeServeClient.shared.abortHook = { _, _ in true }
        session.stopSettleSeconds = 0.05
        // 行は閉じない（記録に無い）ので failed。断りは行の結果と関係なく送る。
        let outcome = await stop(session, call)
        XCTAssertEqual(outcome, .failed(nil))
        let paths = Set(rec.posts.map(\.path))
        XCTAssertEqual(paths, ["permission/per_child/reply", "permission/per_grand/reply", "question/que_grand/reject"])
        _ = await drain(session)
    }

    /// 行が閉じなければ（abort の true は何も保証しない）自分では閉じず、failed を返して行は止められる状態に戻る。
    /// abort が 2xx でないときも同じ。
    func testRowThatNeverClosesIsFailedAndStaysStoppable() async throws {
        let f = try OpenCodeStopFixture("e1b-abort-child")
        let parent = "ses_ea1c307efffe65t16u3tCDy2iq"
        let call = "call_00_V9AQ7I78Wc0nzMbcCAou4156"
        let session = openTurn(parent)
        session.stopSettleSeconds = 0.1
        replay(f.frames(0..<f.probe("stop-sent")))
        for ok in [true, false] {
            OpenCodeServeClient.shared.abortHook = { _, _ in ok }
            let outcome = await stop(session, call)
            XCTAssertEqual(outcome, .failed(nil))
            let after = try await rowOrFail(session, call)
            XCTAssertEqual(after["state"] as? String, "running")
            XCTAssertEqual(after["stoppable"] as? Bool, true)
        }
        let events = await drain(session)
        XCTAssertFalse(events.contains { $0.type == .done }, "親のターンには触らない")
    }

    /// 古い epoch・行の無いキーは stale。終わった行は not_running。abort は送らない。
    func testStaleAndFinishedRowsSendNothing() async throws {
        let f = try OpenCodeStopFixture("e1b-abort-child")
        let parent = "ses_ea1c307efffe65t16u3tCDy2iq"
        let call = "call_00_V9AQ7I78Wc0nzMbcCAou4156"
        let session = openTurn(parent)
        replay(f.frames(0..<f.probe("stop-sent")))
        let rec = OpenCodeStopRecorder()
        OpenCodeServeClient.shared.abortHook = { sid, _ in rec.abort(sid); return true }
        var stale = await request(session, call)
        stale.epoch = "old"
        let a = await session.stopTask(stale)
        let b = await stop(session, "nope")
        XCTAssertEqual(a, .stale)
        XCTAssertEqual(b, .stale)
        XCTAssertTrue(rec.aborts.isEmpty)
        _ = await drain(session)
    }

    /// 同じ行への 2 つ目の停止は新しく送らず、1 つ目の結果を待って同じ結果を返す。
    func testSecondStopOnSameRowJoinsTheFirst() async throws {
        let f = try OpenCodeStopFixture("e1b-abort-child")
        let parent = "ses_ea1c307efffe65t16u3tCDy2iq"
        let call = "call_00_V9AQ7I78Wc0nzMbcCAou4156"
        let sent = f.probe("stop-sent"), response = f.probe("stop-response")
        let session = openTurn(parent)
        session.stopSettleSeconds = 2
        replay(f.frames(0..<sent))
        let rec = OpenCodeStopRecorder()
        OpenCodeServeClient.shared.abortHook = { sid, _ in
            rec.abort(sid)
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.replay(f.frames((sent + 1)..<response))
            return true
        }
        let req = await request(session, call)
        async let first = session.stopTask(req)
        try await Task.sleep(nanoseconds: 40_000_000)
        async let second = session.stopTask(req)
        let (a, b) = await (first, second)
        XCTAssertEqual(a, .stopped)
        XCTAssertEqual(b, .stopped)
        XCTAssertEqual(rec.aborts.count, 1)
        _ = await drain(session)
    }
}
