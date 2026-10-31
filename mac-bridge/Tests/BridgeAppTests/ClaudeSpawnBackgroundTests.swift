import XCTest
@testable import BridgeApp

/// spawn 経路（ClaudeCodeSession）のターンの結び付け・停止・dynamic workflow・バックグラウンドの作業の後片付けを、
/// 偽物の claude で確かめる（docs/BACKGROUND_WORK_2026-10-21.md §3.3）。偽物は claude 2.1.300 と同じ形の行
/// （command_lifecycle・user_message_uuids・origin 付きの result・control_response）を、本文の語で選んだ並びで出す。
final class ClaudeSpawnBackgroundTests: XCTestCase {
    private static let sid = "44444444-4444-4444-8444-444444444444"
    private var dir: URL!
    private var agentId = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-spawn-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FAKE_CLAUDE_STARTS", dir.appendingPathComponent("starts").path, 1)
        setenv("FAKE_CLAUDE_STDIN", dir.appendingPathComponent("stdin").path, 1)
        agentId = "fake-spawn-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        unsetenv("FAKE_CLAUDE_STARTS")
        unsetenv("FAKE_CLAUDE_STDIN")
        unsetenv("FAKE_CLAUDE_DEAF")
        unsetenv("FAKE_CLAUDE_NOINIT")
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// 偽物の claude。stdin の user 行の uuid（と停止の制御要求）に答える。
    private func fakeClaude() throws -> String {
        let script = dir.appendingPathComponent("claude")
        try #"""
        #!/bin/sh
        echo start >> "$FAKE_CLAUDE_STARTS"
        SID=44444444-4444-4444-8444-444444444444
        cur=""
        say() { printf '%s\n' "$1"; }
        life() { say '{"type":"command_lifecycle","command_uuid":"'"$1"'","state":"'"$2"'","session_id":"'"$SID"'"}'; }
        turninit() { say '{"type":"system","subtype":"init","session_id":"'"$SID"'","model":"claude-fake-1"}'; }
        status() { say '{"type":"system","subtype":"status","status":"requesting","user_message_uuids":['"$1"'],"session_id":"'"$SID"'"}'; }
        plainstatus() { say '{"type":"system","subtype":"status","status":"requesting","session_id":"'"$SID"'"}'; }
        text() { say '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"'"$1"'"}},"session_id":"'"$SID"'"}'; }
        result() { say '{"type":"result","subtype":"success","is_error":false,"result":"'"$2"'",'"$1"'"session_id":"'"$SID"'"}'; }
        task() { say '{"type":"system",'"$1"',"session_id":"'"$SID"'"}'; }
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$FAKE_CLAUDE_STDIN"
          case "$line" in
          *'"control_request"'*)
            rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
            case "$line" in
            *'"subtype":"initialize"'*)
              # FAKE_CLAUDE_NOINIT: initialize を知らない古い CLI。
              if [ -n "$FAKE_CLAUDE_NOINIT" ]; then
                say '{"type":"control_response","response":{"subtype":"error","request_id":"'"$rid"'","error":"Unsupported control request subtype: initialize"}}'
              else
                say '{"type":"control_response","response":{"subtype":"success","request_id":"'"$rid"'","response":{}}}'
              fi
              continue
              ;;
            *'"subtype":"stop_task"'*)
              say '{"type":"control_response","response":{"subtype":"success","request_id":"'"$rid"'","response":{}}}'
              continue
              ;;
            esac
            # FAKE_CLAUDE_DEAF: 停止の制御要求に答えない CLI（背景の作業が無ければ Bridge は今までどおりプロセスを止める）。
            if [ -n "$FAKE_CLAUDE_DEAF" ]; then continue; fi
            say '{"type":"control_response","response":{"subtype":"success","request_id":"'"$rid"'","response":{"still_queued":[]}}}'
            status '"'"$cur"'"'
            say '{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"session_id":"'"$SID"'"}'
            say '{"type":"result","subtype":"error_during_execution","is_error":true,"user_message_uuid":"'"$cur"'","user_message_uuids":["'"$cur"'"],"session_id":"'"$SID"'"}'
            life "$cur" completed
            cur=""
            ;;
          *'"type":"user"'*)
            u=$(printf '%s' "$line" | sed -n 's/.*"uuid":"\([^"]*\)".*/\1/p')
            life "$u" queued
            case "$line" in
            *inject*)
              life "$u" started
              status '"'"$cur"'","'"$u"'"'
              text both
              life "$u" completed
              result '"user_message_uuid":"'"$cur"'","user_message_uuids":["'"$cur"'","'"$u"'"],' both
              life "$cur" completed
              cur=""
              turninit
              plainstatus
              text report
              result '"origin":{"kind":"task-notification","producer":"session-task"},' report
              ;;
            *childask*)
              # 背景のサブエージェント（agent_id 付き）と main の承認待ちを抱えたターン。
              life "$u" started
              turninit
              status '"'"$u"'"'
              task '"subtype":"task_started","task_id":"ag1","task_type":"local_agent","subagent_type":"Explore","description":"look around","is_backgrounded":true,"run_id":"r1"'
              say '{"type":"control_request","request_id":"req-child","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"agent_id":"ag1","tool_use_id":"t1"}}'
              say '{"type":"control_request","request_id":"req-main","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"pwd"},"tool_use_id":"t2"}}'
              text partial
              cur=$u
              ;;
            *slow*|*stop*)
              life "$u" started
              turninit
              status '"'"$u"'"'
              text partial
              cur=$u
              ;;
            *behind*)
              # 最後の文を生成中に書いた発話は今のターンに合流せず、その result の後に別のターンとして回る（実測 S9）。
              result '"user_message_uuid":"'"$cur"'","user_message_uuids":["'"$cur"'"],' partial
              life "$cur" completed
              cur=""
              life "$u" started
              turninit
              status '"'"$u"'"'
              text second
              result '"user_message_uuid":"'"$u"'","user_message_uuids":["'"$u"'"],' second
              life "$u" completed
              ;;
            *workflow*)
              life "$u" started
              turninit
              status '"'"$u"'"'
              task '"subtype":"task_started","task_id":"w1","task_type":"local_workflow","workflow_name":"review","description":"Review the change","is_backgrounded":true'
              task '"subtype":"task_progress","task_id":"w1","description":"planning","workflow_progress":[{"type":"workflow_phase","index":1,"title":"Plan"},{"type":"workflow_agent","index":1,"label":"planner","phaseIndex":1,"phaseTitle":"Plan","state":"progress","startedAt":1760000000000},{"type":"workflow_agent","index":2,"label":"checker","state":"error","error":"boom"}]'
              task '"subtype":"task_notification","task_id":"a1","status":"completed","summary":"the CI workflow file is fine"'
              text launched
              result '"user_message_uuid":"'"$u"'","user_message_uuids":["'"$u"'"],' launched
              life "$u" completed
              task '"subtype":"task_updated","task_id":"w1","patch":{"status":"killed","end_time":1760000005000}'
              task '"subtype":"task_notification","task_id":"w1","status":"stopped","summary":"stopped"'
              ;;
            *quiet*)
              life "$u" started
              turninit
              status '"'"$u"'"'
              text plain
              result '"user_message_uuid":"'"$u"'","user_message_uuids":["'"$u"'"],' plain
              life "$u" completed
              # 本文の無い知らせのターン（見せるものが無い）。
              turninit
              plainstatus
              result '"origin":{"kind":"task-notification","producer":"session-task"},' ""
              ;;
            *finished*)
              life "$u" started
              turninit
              status '"'"$u"'"'
              task '"subtype":"task_started","task_id":"ag9","task_type":"local_agent","subagent_type":"Explore","description":"quick look","is_backgrounded":true,"run_id":"r9"'
              task '"subtype":"task_notification","task_id":"ag9","status":"completed","summary":"nothing found","run_id":"r9"'
              text checked
              result '"user_message_uuid":"'"$u"'","user_message_uuids":["'"$u"'"],' checked
              life "$u" completed
              # 知らせのターンが始まったが、まだ本文が無い（SessionHub とアプリにはアイドルに見える）。
              turninit
              plainstatus
              ;;
            *background*)
              life "$u" started
              turninit
              status '"'"$u"'"'
              task '"subtype":"task_started","task_id":"ag1","task_type":"local_agent","subagent_type":"Explore","description":"look around","is_backgrounded":true,"run_id":"r1"'
              task '"subtype":"task_started","task_id":"w2","task_type":"local_workflow","workflow_name":"audit","is_backgrounded":true'
              task '"subtype":"task_progress","task_id":"w2","workflow_progress":[{"type":"workflow_agent","index":1,"label":"auditor","state":"progress"}]'
              text started
              result '"user_message_uuid":"'"$u"'","user_message_uuids":["'"$u"'"],' started
              life "$u" completed
              ;;
            *)
              life "$u" started
              turninit
              status '"'"$u"'"'
              text plain
              result '"user_message_uuid":"'"$u"'","user_message_uuids":["'"$u"'"],' plain
              life "$u" completed
              ;;
            esac
            ;;
          esac
        done
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private struct Timeout: Error {}

    private func start() throws -> (ClaudeCodeSession, SpawnEventLog, Task<Void, Never>) {
        let session = ClaudeCodeSession(
            agentId: agentId, profile: .claude, initialSessionId: nil, cwd: dir.path,
            executable: try fakeClaude(), store: .shared, permissionPrompts: false)
        let log = SpawnEventLog()
        let events = session.events
        let pump = Task { do { for try await e in events { await log.add(e) } } catch {} }
        return (session, log, pump)
    }

    private func waitFor(_ log: SpawnEventLog, timeout: TimeInterval = 10,
                         _ match: @escaping @Sendable (SessionEvent) -> Bool) async throws -> SessionEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = await log.first(where: match) { return e }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out")
        throw Timeout()
    }

    private func starts() -> Int {
        let text = (try? String(contentsOf: dir.appendingPathComponent("starts"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").count
    }

    private func stdin() -> String {
        (try? String(contentsOf: dir.appendingPathComponent("stdin"), encoding: .utf8)) ?? ""
    }

    private static func payload(_ e: SessionEvent) -> [String: Any]? {
        guard e.type == .workflowProgress, let data = e.content?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 生成中に差し込んだ発話は今のターンに合流し、result は 2 通分で 1 つ（実測 U2）。差し込みの後の本文は差し込んだ
    /// 発話の吹き出しに流し、done はその発話で 1 回。前の発話の途中までの本文も履歴に残る。続く知らせのターン
    /// （発話の無いターン）は本文と done（origin = task-notification）で届く。
    func testInjectedMessageAndNotificationTurn() async throws {
        let (session, log, pump) = try start()
        let first = Task { await session.send("slow first", skills: [], attachments: []) }
        let a = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "partial" }.messageId ?? ""
        let second = Task { await session.send("inject second", skills: [], attachments: []) }
        let b = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "both" }.messageId ?? ""
        await first.value
        await second.value
        let n = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "report" }.messageId ?? ""
        let notificationDone = try await waitFor(log) { $0.type == .done && $0.messageId == n }

        XCTAssertNotEqual(a, b, "差し込んだ発話の返事は、その発話の吹き出しに出す")
        XCTAssertFalse([a, b].contains(n), "知らせのターンは別の吹き出し")
        XCTAssertEqual(notificationDone.metadata?["origin"], "task-notification")
        let events = await log.all()
        XCTAssertTrue(events.contains { $0.type == .assistantTurnEnd && $0.messageId == a }, "前の吹き出しを区切ってから流す")
        XCTAssertEqual(events.filter { $0.type == .done }.compactMap(\.messageId), [b, n], "result 1 つに done 1 つ")
        XCTAssertFalse(events.contains { $0.type == .error })
        let history = await ClaudeCodeSessionStore.shared.history(agentId: agentId, sessionId: Self.sid)
        XCTAssertEqual(history.first { $0.messageId == a }?.content, "partial", "前の発話の途中までの本文も残す")
        XCTAssertEqual(history.first { $0.messageId == b }?.content, "both")
        XCTAssertEqual(history.first { $0.messageId == n }?.content, "report")
        // stdin の user 行には uuid（messageId の小文字）を付ける。
        XCTAssertTrue(stdin().contains("\"uuid\":\"\(a.lowercased())\""))
        XCTAssertTrue(stdin().contains("\"uuid\":\"\(b.lowercased())\""))
        XCTAssertEqual(starts(), 1)
        await session.close()
        pump.cancel()
    }

    /// 停止は制御要求（interrupt）で、ターンだけを中断として閉じる。プロセスは残り、次の送信もそのまま答える。
    /// 中断したターンの残り（status・[Request interrupted by user]・result error_during_execution）で done を重ねない。
    func testInterruptKeepsTheProcess() async throws {
        let (session, log, pump) = try start()
        let sending = Task { await session.send("stop me", skills: [], attachments: []) }
        let c = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "partial" }.messageId ?? ""
        await session.interrupt()
        await sending.value
        let next = Task { await session.send("hello again", skills: [], attachments: []) }
        let d = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "plain" }.messageId ?? ""
        await next.value

        let events = await log.all()
        XCTAssertEqual(events.filter { $0.type == .done }.compactMap(\.messageId), [c, d])
        XCTAssertFalse(events.contains { $0.type == .error }, "中断はエラーにしない")
        XCTAssertEqual(starts(), 1, "プロセスを止めない（次の送信が冷えた起動にならない）")
        XCTAssertTrue(stdin().contains("\"subtype\":\"interrupt\""))
        XCTAssertFalse(session.hasActiveTurn)
        let history = await ClaudeCodeSessionStore.shared.history(agentId: agentId, sessionId: Self.sid)
        XCTAssertEqual(history.first { $0.messageId == c }?.content, "partial")
        await session.close()
        pump.cancel()
    }

    /// dynamic workflow のカード: task_started で覚えた task_id で振り分け（summary の文字では決めない）、
    /// 行の state とカードの status をそろえ、phase の見出しは行にしない。止まった workflow は failed + outcome stopped。
    func testWorkflowPayloadIsRoutedByTaskIdAndNormalised() async throws {
        let (session, log, pump) = try start()
        await session.send("workflow please", skills: [], attachments: [])
        _ = try await waitFor(log) { e in
            let p = Self.payload(e)
            return p?["taskId"] as? String == "w1" && p?["subtype"] as? String == "task_notification"
        }
        let payloads = await log.all().compactMap(Self.payload)
        let w1 = payloads.filter { $0["taskId"] as? String == "w1" }
        XCTAssertEqual(w1.map { $0["subtype"] as? String }, ["task_started", "task_progress", "task_updated", "task_notification"])
        XCTAssertEqual(w1.map { $0["status"] as? String }, ["running", "running", "failed", "failed"])
        XCTAssertEqual(w1.map { $0["outcome"] as? String }, [nil, nil, "stopped", "stopped"])
        XCTAssertEqual(w1.last?["workflowName"] as? String, "review", "名前は task_started の後も載せる")
        let rows = w1.count > 1 ? (w1[1]["agents"] as? [[String: Any]] ?? []) : []
        XCTAssertEqual(rows.map { $0["label"] as? String }, ["planner", "checker"], "phase の見出しは行にしない")
        XCTAssertEqual(rows.map { $0["state"] as? String }, ["running", "failed"])
        XCTAssertEqual(rows.last?["resultPreview"] as? String, "boom", "失敗の理由")
        XCTAssertEqual(rows.first?["startedAtMs"] as? Int, 1_760_000_000_000)
        XCTAssertFalse(payloads.contains { $0["taskId"] as? String == "a1" },
                       "summary に workflow という語があるだけの知らせを workflow のカードにしない")
        await session.close()
        pump.cancel()
    }

    /// バックグラウンドの作業（サブエージェントの行・終わっていない workflow）がある間は、設定が変わっても
    /// プロセスを起こし直さない。close は continuation を閉じる前に、それらを stopped で閉じる payload を流す。
    func testBackgroundWorkBlocksRespawnAndCloseStopsIt() async throws {
        let (session, log, pump) = try start()
        await session.send("background job", skills: [], attachments: [])
        let snapshot = await session.subagentSnapshot()
        let snap = snapshot.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(snap?["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual((snap?["agents"] as? [[String: Any]])?.map { $0["state"] as? String }, ["running"])

        session.applyOverrides(SessionOverrides(model: "claude-other-model"))
        await session.send("hello again", skills: [], attachments: [])
        XCTAssertEqual(starts(), 1, "動いているバックグラウンドの作業があるので起こし直さない")

        await session.close()
        await pump.value
        let payloads = await log.all().compactMap(Self.payload)
        let rows = payloads.filter { $0["taskId"] as? String == "subagents" }.last?["agents"] as? [[String: Any]]
        XCTAssertEqual(rows?.first { $0["id"] as? String == "ag1" }?["state"] as? String, "stopped")
        let w2 = payloads.last { $0["taskId"] as? String == "w2" }
        XCTAssertEqual(w2?["status"] as? String, "failed")
        XCTAssertEqual(w2?["outcome"] as? String, "stopped")
        XCTAssertEqual((w2?["agents"] as? [[String: Any]])?.first?["state"] as? String, "stopped")
    }

    /// 停止の返事が来ず、背景の作業も無ければ、今までどおりプロセスグループを止める。ターンは中断（エラーではない）で
    /// 閉じる。次の送信は起こし直す。
    func testInterruptFallsBackToTerminatingWithoutAnswer() async throws {
        setenv("FAKE_CLAUDE_DEAF", "1", 1)
        let (session, log, pump) = try start()
        let sending = Task { await session.send("stop me", skills: [], attachments: []) }
        let c = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "partial" }.messageId ?? ""
        await session.interrupt()
        await sending.value
        let done = try await waitFor(log) { $0.type == .done && $0.messageId == c }
        XCTAssertNil(done.metadata?["origin"])
        let events = await log.all()
        XCTAssertFalse(events.contains { $0.type == .error }, "止めたのでエラーにしない")
        let next = Task { await session.send("hello again", skills: [], attachments: []) }
        _ = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "plain" }
        await next.value
        XCTAssertEqual(starts(), 2, "止めたプロセスの代わりに起こし直す")
        await session.close()
        pump.cancel()
    }

    /// 返事が来なくても、背景の作業（動いている行・終わっていない workflow）があれば、プロセスを止めない。
    /// 止めると決めたターンを中断として自分で閉じる（背景の作業は動いたまま。次の送信もそのまま答える）。
    func testDeafInterruptKeepsProcessForBackgroundWork() async throws {
        setenv("FAKE_CLAUDE_DEAF", "1", 1)
        let (session, log, pump) = try start()
        await session.send("background job", skills: [], attachments: [])
        let sending = Task { await session.send("stop me", skills: [], attachments: []) }
        let c = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "partial" }.messageId ?? ""
        await session.interrupt()
        await sending.value
        _ = try await waitFor(log) { $0.type == .done && $0.messageId == c }
        let events = await log.all()
        XCTAssertFalse(events.contains { $0.type == .error })
        XCTAssertFalse(session.hasActiveTurn, "止めたターンは閉じている")
        let snapshot = await session.subagentSnapshot() ?? ""
        XCTAssertTrue(snapshot.contains("\"state\":\"running\""), "背景のサブエージェントは動いたまま")
        let payloads = events.compactMap(Self.payload)
        XCTAssertNil(payloads.first { $0["taskId"] as? String == "w2" && $0["outcome"] != nil }, "workflow を閉じていない")
        let next = Task { await session.send("hello again", skills: [], attachments: []) }
        _ = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "plain" }
        await next.value
        XCTAssertEqual(starts(), 1, "プロセスを止めない")
        await session.close()
        pump.cancel()
    }

    /// interrupt は main の承認だけ閉じる。背景のサブエージェントの承認は CLI が子を止めないので残し、後から答えられる。
    func testInterruptKeepsBackgroundChildApproval() async throws {
        let (session, log, pump) = try start()
        let sending = Task { await session.send("childask now", skills: [], attachments: []) }
        _ = try await waitFor(log) { $0.type == .actionRequest && $0.messageId == "req-child" }
        _ = try await waitFor(log) { $0.type == .actionRequest && $0.messageId == "req-main" }
        await session.interrupt()
        await sending.value
        _ = try await waitFor(log) { $0.type == .actionResolved && $0.messageId == "req-main" }
        let events = await log.all()
        XCTAssertFalse(events.contains { $0.type == .actionResolved && $0.messageId == "req-child" },
                       "背景の子の承認カードは閉じない")
        await session.respondToAction(requestId: "req-child", decision: "allow", answers: [:])
        // 偽物の CLI が stdin の行を記録するのを少し待つ。
        for _ in 0..<100 where !stdin().contains("\"request_id\":\"req-child\"") {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(stdin().contains("\"request_id\":\"req-child\""), "子の承認にはまだ答えられる")
        await session.close()
        pump.cancel()
    }

    /// 返事が来なくて背景の作業のためにプロセスを残すとき、閉じる main の承認には拒否を書く（CLI はまだ待っている）。
    func testKeptInterruptDeniesMainApprovalAndKeepsChildApproval() async throws {
        setenv("FAKE_CLAUDE_DEAF", "1", 1)
        let (session, log, pump) = try start()
        let sending = Task { await session.send("childask now", skills: [], attachments: []) }
        _ = try await waitFor(log) { $0.type == .actionRequest && $0.messageId == "req-main" }
        _ = try await waitFor(log) { $0.type == .actionRequest && $0.messageId == "req-child" }
        await session.interrupt()
        await sending.value
        _ = try await waitFor(log) { $0.type == .actionResolved && $0.messageId == "req-main" }
        XCTAssertEqual(starts(), 1, "背景の作業があるのでプロセスを残す")
        for _ in 0..<100 where !stdin().contains("\"behavior\":\"deny\"") {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let written = stdin()
        XCTAssertTrue(written.contains("\"request_id\":\"req-main\"") && written.contains("\"behavior\":\"deny\""),
                      "main の承認には拒否を書く")
        let events = await log.all()
        XCTAssertFalse(events.contains { $0.type == .actionResolved && $0.messageId == "req-child" })
        await session.close()
        pump.cancel()
    }

    /// 同じプロセスで 2 回続けて返事が来なければ、背景の作業があっても止める（CLI が固まっている）。
    /// 動いていた行と workflow は stopped（自分で止めた）。
    func testDeafInterruptTwiceTerminatesEvenWithBackgroundWork() async throws {
        setenv("FAKE_CLAUDE_DEAF", "1", 1)
        let (session, log, pump) = try start()
        await session.send("background job", skills: [], attachments: [])
        let first = Task { await session.send("stop me", skills: [], attachments: []) }
        let c = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "partial" }.messageId ?? ""
        await session.interrupt()
        await first.value
        _ = try await waitFor(log) { $0.type == .done && $0.messageId == c }
        XCTAssertEqual(starts(), 1)

        let second = Task { await session.send("stop me again", skills: [], attachments: []) }
        let d = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "partial" && $0.messageId != c }.messageId ?? ""
        await session.interrupt()
        await second.value
        _ = try await waitFor(log) { $0.type == .done && $0.messageId == d }
        let events = await log.all()
        XCTAssertFalse(events.contains { $0.type == .error }, "止めたのでエラーにしない")
        let payloads = events.compactMap(Self.payload)
        let rows = payloads.filter { $0["taskId"] as? String == "subagents" }.last?["agents"] as? [[String: Any]]
        XCTAssertEqual(rows?.first { $0["id"] as? String == "ag1" }?["state"] as? String, "stopped", "失敗にしない")
        XCTAssertEqual(payloads.last { $0["taskId"] as? String == "w2" }?["outcome"] as? String, "stopped")
        let next = Task { await session.send("hello again", skills: [], attachments: []) }
        _ = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "plain" }
        await next.value
        XCTAssertEqual(starts(), 2, "止めたプロセスの代わりに起こし直す")
        await session.close()
        pump.cancel()
    }

    /// 本文の無い知らせのターンも、開いたときに空の activity を出し、silent の done（metadata.silent = "1"、origin 付き）で
    /// 閉じる（done を出さないと、開いたときの activity で立った SessionHub とアプリの生成中が残る）。見せるものが無いので
    /// 空の吹き出しは作らない。
    func testSilentNotificationTurnEndsWithSilentDone() async throws {
        let (session, log, pump) = try start()
        await session.send("quiet please", skills: [], attachments: [])
        let first = try await waitFor(log) { $0.type == .done }
        let silent = try await waitFor(log) { $0.type == .done && $0.messageId != first.messageId }
        XCTAssertNil(first.metadata?["origin"])
        XCTAssertEqual(silent.metadata?["origin"], "task-notification")
        XCTAssertEqual(silent.metadata?["silent"], "1")
        let events = await log.all()
        XCTAssertTrue(events.contains { $0.type == .activity && $0.messageId == silent.messageId && $0.content == "" },
                      "知らせのターンを開いたときに考え中を出す")
        XCTAssertFalse(events.contains { $0.type == .assistantDelta && $0.messageId == silent.messageId }, "空の吹き出しを作った")
        XCTAssertEqual(events.filter { $0.type == .done }.count, 2)
        XCTAssertFalse(session.hasActiveTurn, "知らせのターンも閉じている")
        await session.close()
        pump.cancel()
    }

    /// 知らせのターンは、本文の前（system/status から最初の差分まで 1〜数秒）でも、開いた時点で空の activity を出す
    /// （SessionHub とアプリには生成中に見える）。その間の送信は差し込みなので、終わった行を捨てない（hub・アプリと同じ。
    /// 捨てると、接続のたびの subagentSnapshot がアプリの残している行を消してしまう）。
    func testNotificationTurnBeforeItsTextIsActiveAndSendKeepsFinishedRows() async throws {
        let (session, log, pump) = try start()
        await session.send("finished job", skills: [], attachments: [])
        let a = await log.all().last { $0.type == .done }?.messageId
        let before = await session.subagentSnapshot() ?? ""
        XCTAssertTrue(before.contains("\"id\":\"ag9\""), "終わった行は次の新しいターンまで残る")
        let opened = try await waitFor(log) { $0.type == .activity && $0.messageId != a }
        XCTAssertEqual(opened.content, "")
        XCTAssertTrue(session.hasActiveTurn, "本文の無い知らせのターンが開いていない")

        await session.send("hello again", skills: [], attachments: [])
        let after = await session.subagentSnapshot() ?? ""
        XCTAssertTrue(after.contains("\"id\":\"ag9\""), "生成中の差し込みで終わった行を捨てた")
        let dones = await log.all().filter { $0.type == .done }
        XCTAssertEqual(dones.count, 2, "知らせのターンに合流した発話の done は 1 回")
        XCTAssertNil(dones.last?.metadata?["origin"])
        XCTAssertNil(dones.last?.metadata?["silent"])
        await session.close()
        pump.cancel()
    }

    /// 本文の前の知らせのターンの間に見る人がいなくなっても、SessionHub は閉じない（開いたときの空の activity で生成中と
    /// みなす）。閉じると CLI ごと止まり、報告も done も push も消える。
    func testHubKeepsSessionThroughNotificationTurnBeforeItsText() async throws {
        let session = ClaudeCodeSession(
            agentId: agentId, profile: .claude, initialSessionId: nil, cwd: dir.path,
            executable: try fakeClaude(), store: .shared, permissionPrompts: false)
        let adapter = FixedSessionAdapter(id: agentId, session: session)
        let listener = HubListener()
        _ = await SessionHub.shared.acquire(agentId: agentId, sessionId: nil, cwd: dir.path, adapter: adapter,
                                            subscriberId: listener.id, send: listener.send)
        await SessionHub.shared.notePromptSent(agentId: agentId, sessionId: session.sessionId)
        await session.send("finished job", skills: [], attachments: [])
        let a = try await listener.until("done of the request") { $0.type == .done }.messageId
        _ = try await listener.until("notification turn opened") { $0.type == .activity && $0.messageId != a }

        await SessionHub.shared.release(subscriberId: listener.id)
        try await Task.sleep(nanoseconds: 300_000_000)
        let live = await SessionHub.shared.snapshot().first { $0.agentId == agentId }
        XCTAssertNotNil(live, "知らせのターンの途中で閉じた")
        XCTAssertEqual(live?.generating, true)
        XCTAssertTrue(session.hasActiveTurn)
        XCTAssertEqual(starts(), 1)
        await session.close()
    }

    /// 最後の文を生成中に書いた発話は今のターンに合流せず、result の後に別のターンとして回る（実測 S9）。前のターンの done には、
    /// まだ始まっていない発話が残っている印（metadata.pending = "1"）を付ける（SessionHub がそこでターンを終わりにして閉じると、
    /// その発話ごとプロセスが止まる）。後の発話の done には付けない。
    func testDoneMarksPromptStillQueuedInTheCli() async throws {
        let (session, log, pump) = try start()
        let first = Task { await session.send("slow first", skills: [], attachments: []) }
        let a = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "partial" }.messageId ?? ""
        let second = Task { await session.send("queued behind", skills: [], attachments: []) }
        let doneA = try await waitFor(log) { $0.type == .done && $0.messageId == a }
        let b = try await waitFor(log) { $0.type == .assistantDelta && $0.content == "second" }.messageId ?? ""
        let doneB = try await waitFor(log) { $0.type == .done && $0.messageId == b }
        await first.value
        await second.value

        XCTAssertNotEqual(a, b, "後の発話は別の吹き出し")
        XCTAssertEqual(doneA.metadata?["pending"], "1", "始まっていない発話が残っているのに、ターンの終わりの done にした")
        XCTAssertNil(doneA.metadata?["origin"])
        XCTAssertNil(doneB.metadata?["pending"])
        XCTAssertFalse(session.hasActiveTurn)
        let errored = await log.all().contains { $0.type == .error }
        XCTAssertFalse(errored)
        await session.close()
        pump.cancel()
    }

    /// 止めるターンが無い（バックグラウンドの作業だけが動いている）ときの停止は、制御要求を書かない
    /// （アイドル中の interrupt はバックグラウンドのサブエージェントまで止める。実測 S6e）。直近の done を返す。
    func testIdleInterruptLeavesBackgroundWorkAlone() async throws {
        let (session, log, pump) = try start()
        await session.send("background job", skills: [], attachments: [])
        let last = await log.all().last { $0.type == .done }?.messageId
        await session.interrupt()
        XCTAssertFalse(stdin().contains("\"subtype\":\"interrupt\""))
        let dones = await log.all().filter { $0.type == .done }.map(\.messageId)
        XCTAssertEqual(dones.last, last, "直近の done を返す（生成中を解く）")
        let snapshot = await session.subagentSnapshot() ?? ""
        XCTAssertTrue(snapshot.contains("\"state\":\"running\""), "バックグラウンドのサブエージェントは動いたまま")
        await session.close()
        pump.cancel()
    }

    /// workflow の行の振り分け（プロセス無しで行を直接渡す）。終わった後の遅れた進み具合では実行中に戻さず、
    /// task_started のやり直しでは戻す。
    func testWorkflowPayloadLifecycle() {
        let session = ClaudeCodeSession(agentId: agentId, profile: .claude, initialSessionId: nil, cwd: dir.path,
                                        executable: "/usr/bin/false", store: .shared)
        func payload(_ json: String) -> [String: Any]? {
            let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            return session.workflowEventPayload(from: obj)
                .flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        XCTAssertNil(payload(#"{"type":"system","subtype":"task_notification","task_id":"a1","status":"completed","summary":"workflow ok"}"#))
        XCTAssertEqual(payload(#"{"type":"system","subtype":"task_started","task_id":"w","task_type":"local_workflow","workflow_name":"r"}"#)?["status"] as? String, "running")
        let done = payload(#"{"type":"system","subtype":"task_notification","task_id":"w","status":"completed","summary":"ok"}"#)
        XCTAssertEqual(done?["status"] as? String, "completed")
        XCTAssertEqual(done?["workflowName"] as? String, "r")
        XCTAssertNil(payload(#"{"type":"system","subtype":"task_progress","task_id":"w","workflow_progress":[]}"#),
                     "終わった後の進み具合で実行中に戻さない")
        XCTAssertEqual(payload(#"{"type":"system","subtype":"task_updated","task_id":"w","patch":{"status":"failed"}}"#)?["status"] as? String, "failed")
        XCTAssertNil(payload(#"{"type":"system","subtype":"task_updated","task_id":"w","patch":{"is_backgrounded":true}}"#))
        XCTAssertEqual(payload(#"{"type":"system","subtype":"task_started","task_id":"w","task_type":"local_workflow"}"#)?["status"] as? String, "running")
    }

    func testWorkflowRowStateVocabulary() {
        XCTAssertEqual(["start", "progress", "running", "done", "completed", "error", "failed", "killed", "stopped", "cancelled", "queued"]
            .map { ClaudeCodeSession.workflowRowState($0) },
                       ["running", "running", "running", "done", "done", "failed", "failed", "stopped", "stopped", "stopped", "queued"])
        XCTAssertNil(ClaudeCodeSession.workflowRowState(nil))
    }
}

private actor SpawnEventLog {
    private var events: [SessionEvent] = []
    func add(_ e: SessionEvent) { events.append(e) }
    func all() -> [SessionEvent] { events }
    func first(where match: @Sendable (SessionEvent) -> Bool) -> SessionEvent? { events.first(where: match) }
}

/// 作っておいた session をそのまま開く adapter（SessionHub を通して確かめる）。
private final class FixedSessionAdapter: AgentAdapter {
    let id: String
    let displayName = "Claude (fake)"
    private let session: AgentSession

    init(id: String, session: AgentSession) {
        self.id = id
        self.session = session
    }

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession { session }
    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] { [] }
    func loadHistory(sessionId: String) async -> [HistoryMessage] { [] }
}

// MARK: - 行ごとの停止（stop_task）と workflow の phases

/// shared/fixtures/background-control の実測（claude-stop・workflow-phases）を流して確かめる
/// （docs/BACKGROUND_CONTROL_2026-10-21.md §3.4・§6）。偽の claude は、最初の user 行で開始の行を流し、
/// stop_task には用意した行（無ければ何も起きない success）を返す。
final class ClaudeStopTaskSpawnTests: XCTestCase {
    private static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/fixtures/background-control")
    private static let envKeys = ["FAKE_CLAUDE_STARTS", "FAKE_CLAUDE_STDIN", "FAKE_DIR", "FAKE_CLAUDE_NOINIT",
                                  "FAKE_STOP_DELAY", "FAKE_STOP_EXIT", "FAKE_STOP_SILENT", "FAKE_STOP_ERROR"]
    private var dir: URL!
    private var agentId = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-stop-task-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("FAKE_CLAUDE_STARTS", dir.appendingPathComponent("starts").path, 1)
        setenv("FAKE_CLAUDE_STDIN", dir.appendingPathComponent("stdin").path, 1)
        setenv("FAKE_DIR", dir.path, 1)
        agentId = "fake-stop-\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        for key in Self.envKeys { unsetenv(key) }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: 偽物と実測の読み込み

    private func fakeClaude() throws -> String {
        let script = dir.appendingPathComponent("claude")
        try #"""
        #!/bin/sh
        echo start >> "$FAKE_CLAUDE_STARTS"
        say() { printf '%s\n' "$1"; }
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$FAKE_CLAUDE_STDIN"
          case "$line" in
          *'"control_request"'*)
            rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
            case "$line" in
            *'"subtype":"initialize"'*)
              if [ -n "$FAKE_CLAUDE_NOINIT" ]; then
                say '{"type":"control_response","response":{"subtype":"error","request_id":"'"$rid"'","error":"Unsupported control request subtype: initialize"}}'
              else
                say '{"type":"control_response","response":{"subtype":"success","request_id":"'"$rid"'","response":{"account":{"email":"sentinel@example.invalid"},"pid":424242}}}'
              fi
              ;;
            *'"subtype":"stop_task"'*)
              tid=$(printf '%s' "$line" | sed -n 's/.*"task_id":"\([^"]*\)".*/\1/p')
              if [ -n "$FAKE_STOP_DELAY" ]; then sleep "$FAKE_STOP_DELAY"; fi
              if [ -n "$FAKE_STOP_EXIT" ]; then exit 0; fi
              if [ -n "$FAKE_STOP_SILENT" ]; then continue; fi
              if [ -n "$FAKE_STOP_ERROR" ]; then
                say '{"type":"control_response","response":{"subtype":"error","request_id":"'"$rid"'","error":"'"$FAKE_STOP_ERROR"'"}}'
                continue
              fi
              if [ -f "$FAKE_DIR/stop-$tid.out" ]; then
                sed "s/__RID__/$rid/" "$FAKE_DIR/stop-$tid.out"
              else
                say '{"type":"control_response","response":{"subtype":"success","request_id":"'"$rid"'","response":{}}}'
              fi
              ;;
            esac
            ;;
          *'"type":"user"'*)
            if [ -f "$FAKE_DIR/start.out" ]; then cat "$FAKE_DIR/start.out"; mv "$FAKE_DIR/start.out" "$FAKE_DIR/start.done"; fi
            ;;
          esac
        done
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private struct Entry {
        let dir: String
        let raw: String?
        let text: String?
        var json: [String: Any]? {
            raw.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }

    private func fixture(_ path: String) throws -> [Entry] {
        let text = try String(contentsOf: Self.fixtureDir.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let d = obj["dir"] as? String else { return nil }
            return Entry(dir: d, raw: obj["raw"] as? String, text: obj["text"] as? String)
        }
    }

    /// 流す価値のある行（task_* と background_tasks_changed。開始の行には result も）。承認・本文・lifecycle は流さない。
    private static func replayable(_ entry: Entry, result: Bool) -> String? {
        guard entry.dir == "out", let raw = entry.raw, let obj = entry.json else { return nil }
        switch obj["type"] as? String {
        case "system":
            let subtype = obj["subtype"] as? String ?? ""
            return ["task_started", "task_progress", "task_updated", "task_notification", "background_tasks_changed"].contains(subtype) ? raw : nil
        case "result": return result ? raw : nil
        default: return nil
        }
    }

    /// 最初の user 行への返事として流す行（最初の印の次の印まで）。
    private func startLines(_ name: String) throws -> [String] {
        var lines: [String] = []
        var marks = 0
        for e in try fixture("claude-stop/\(name).jsonl") {
            if e.dir == "mark" { marks += 1; if marks >= 2 { break } }
            if let raw = Self.replayable(e, result: true) { lines.append(raw) }
        }
        return lines
    }

    /// taskId への stop_task の後に CLI が出した行（次の入力か印まで）。control_response の request_id は __RID__ にする。
    private func stopLines(_ name: String, taskId: String) throws -> [String] {
        let entries = try fixture("claude-stop/\(name).jsonl")
        guard let i = entries.firstIndex(where: {
            let request = $0.json?["request"] as? [String: Any]
            return $0.dir == "in" && request?["subtype"] as? String == "stop_task" && request?["task_id"] as? String == taskId
        }), let requestId = entries[i].json?["request_id"] as? String else { return [] }
        var lines: [String] = []
        for e in entries[(i + 1)...] {
            if e.dir != "out" { break }
            if let raw = Self.replayable(e, result: false) {
                lines.append(raw)
            } else if e.json?["type"] as? String == "control_response", let raw = e.raw {
                lines.append(raw.replacingOccurrences(of: requestId, with: "__RID__"))
            }
        }
        return lines
    }

    private func install(start: [String], stops: [String: [String]] = [:]) throws {
        try (start.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("start.out"), atomically: true, encoding: .utf8)
        for (id, lines) in stops {
            try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("stop-\(id).out"), atomically: true, encoding: .utf8)
        }
    }

    private func start() throws -> (ClaudeCodeSession, SpawnEventLog, Task<Void, Never>) {
        let session = ClaudeCodeSession(
            agentId: agentId, profile: .claude, initialSessionId: nil, cwd: dir.path,
            executable: try fakeClaude(), store: .shared, permissionPrompts: false)
        let log = SpawnEventLog()
        let events = session.events
        let pump = Task { do { for try await e in events { await log.add(e) } } catch {} }
        return (session, log, pump)
    }

    private struct Timeout: Error {}

    private func waitFor(_ timeout: TimeInterval = 10, _ what: String = "", _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out \(what)")
        throw Timeout()
    }

    private static func obj(_ json: String?) -> [String: Any] {
        json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
    }

    private static func rows(_ json: String?) -> [[String: Any]] { obj(json)["agents"] as? [[String: Any]] ?? [] }

    private func row(_ session: ClaudeCodeSession, _ id: String) async -> [String: Any]? {
        Self.rows(await session.subagentSnapshot()).first { $0["id"] as? String == id }
    }

    private func epoch(_ session: ClaudeCodeSession) async -> String {
        Self.obj(await session.subagentSnapshot())["epoch"] as? String ?? ""
    }

    /// 最初の user 行を送り、行が出て stoppable になる（initialize の返事が来る）のを待つ。
    private func launch(_ session: ClaudeCodeSession, rows ids: [String]) async throws {
        await session.send("go", skills: [], attachments: [])
        try await waitFor(10, "rows \(ids)") { [self] in
            for id in ids { guard await row(session, id)?["stoppable"] as? Bool == true else { return false } }
            return true
        }
    }

    private func stopRequest(_ session: ClaudeCodeSession, _ id: String) async -> StopTaskRequest {
        StopTaskRequest(taskId: "subagents", rowId: id, epoch: await epoch(session))
    }

    private func stdinLines() -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("stdin"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func starts() -> Int {
        ((try? String(contentsOf: dir.appendingPathComponent("starts"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func stopWrites(_ id: String) -> Int {
        stdinLines().filter { $0.contains("\"subtype\":\"stop_task\"") && $0.contains("\"task_id\":\"\(id)\"") }.count
    }

    private func payloads(_ log: SpawnEventLog) async -> [[String: Any]] {
        await log.all().filter { $0.type == .workflowProgress }.map { Self.obj($0.content) }
    }

    /// subagents のカードの payload を、時刻順に (行の state, stoppable) だけに畳む。
    private func history(_ log: SpawnEventLog, _ id: String) async -> [(state: String?, stoppable: Bool?)] {
        await payloads(log).compactMap { p in
            guard p["taskId"] as? String == "subagents",
                  let r = (p["agents"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) else { return nil }
            return (r["state"] as? String, r["stoppable"] as? Bool)
        }
    }

    // MARK: initialize

    /// プロセスを起こしたら、最初の user 行より前に initialize を書く（warm でも）。
    func testInitializeIsWrittenBeforeTheFirstUserLine() async throws {
        try install(start: [#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#])
        let (session, _, pump) = try start()
        await session.warm()
        try await waitFor(5, "initialize") { [self] in !stdinLines().isEmpty }
        await session.send("go", skills: [], attachments: [])
        let lines = stdinLines()
        XCTAssertTrue(lines[0].contains("\"subtype\":\"initialize\""))
        XCTAssertTrue(lines[0].contains("\"perTaskStopAffordance\":true"))
        XCTAssertEqual(lines.filter { $0.contains("\"subtype\":\"initialize\"") }.count, 1)
        XCTAssertTrue(lines.last?.contains("\"type\":\"user\"") == true)
        await session.close()
        pump.cancel()
    }

    /// initialize の返事はアカウントのメールと pid を含む。イベントにもログ（stderr）にも出さない。
    func testInitializeReplyBodyIsNeverLoggedOrEmitted() async throws {
        let logFile = dir.appendingPathComponent("captured-stderr")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let saved = dup(2)
        let fd = open(logFile.path, O_WRONLY | O_TRUNC)
        dup2(fd, 2)
        close(fd)
        defer { dup2(saved, 2); close(saved) }
        try install(start: startLines("s1-stop-bg-bash"))
        let (session, log, pump) = try start()
        try await launch(session, rows: ["br1svjoeb"])
        await session.close()
        pump.cancel()
        fflush(stderr)
        let captured = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(captured.contains("initialize accepted"), "ログは 1 行だけ出る")
        XCTAssertFalse(captured.contains("sentinel@example.invalid") || captured.contains("424242"))
        for e in await log.all() {
            let text = (e.content ?? "") + (e.metadata?.values.joined() ?? "")
            XCTAssertFalse(text.contains("sentinel@example.invalid") || text.contains("424242"))
        }
    }

    // MARK: 行の停止（実測）

    func testStopBackgroundShellS1() async throws {
        try install(start: startLines("s1-stop-bg-bash"),
                    stops: ["br1svjoeb": stopLines("s1-stop-bg-bash", taskId: "br1svjoeb")])
        let (session, log, pump) = try start()
        try await launch(session, rows: ["br1svjoeb"])
        let request = await stopRequest(session, "br1svjoeb")

        let outcome = await session.stopTask(request)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(stopWrites("br1svjoeb"), 1)
        // 知らせは pump が別のタスクで log に移すので、止まった知らせまで届くのを待ってから読む。
        try await waitFor(5, "row stopped in the log") { [self] in await history(log, "br1svjoeb").last?.state == "stopped" }
        let h = await history(log, "br1svjoeb")
        XCTAssertTrue(h.contains { $0.state == "running" && $0.stoppable == false }, "頼んだ間は stoppable を下ろして送る")
        XCTAssertEqual(h.last?.state, "stopped")
        XCTAssertEqual(h.last?.stoppable, false)
        let events = await log.all()
        XCTAssertFalse(events.contains { $0.type == .error })
        XCTAssertEqual(starts(), 1, "プロセスは止めない")
        await session.close()
        pump.cancel()
    }

    func testStopBackgroundAgentS2() async throws {
        try install(start: startLines("s2-stop-bg-agent"),
                    stops: ["af42a6def78386e01": stopLines("s2-stop-bg-agent", taskId: "af42a6def78386e01")])
        let (session, log, pump) = try start()
        try await launch(session, rows: ["af42a6def78386e01"])

        let outcome = await session.stopTask(await stopRequest(session, "af42a6def78386e01"))
        XCTAssertEqual(outcome, .stopped)
        let r = await row(session, "af42a6def78386e01")
        XCTAssertEqual(r?["state"] as? String, "stopped")
        XCTAssertEqual(r?["stoppable"] as? Bool, false)
        try await waitFor(5, "row stopped in the log") { [self] in await history(log, "af42a6def78386e01").last?.state == "stopped" }
        let h = await history(log, "af42a6def78386e01")
        XCTAssertEqual(h.last?.state, "stopped")
        await session.close()
        pump.cancel()
    }

    /// success でも何も起きない id（s6: CLI は知らない id に success を返す）は、こちらで stopped にする。
    /// 止まった行への 2 回目は not_running。
    func testSuccessWithoutAnyEventClosesTheRowAsStopped() async throws {
        try install(start: startLines("s6-stop-id-variants"),
                    stops: ["bpzp9542e": stopLines("s6-stop-id-variants", taskId: "bpzp9542e")])
        let (session, log, pump) = try start()
        try await launch(session, rows: ["bpzp9542e", "a5a7fe42c3e7ff80f"])

        let shell = await session.stopTask(await stopRequest(session, "bpzp9542e"))
        XCTAssertEqual(shell, .stopped)
        let agentRequest = await stopRequest(session, "a5a7fe42c3e7ff80f")
        let silent = await session.stopTask(agentRequest)
        XCTAssertEqual(silent, .stopped, "CLI が何もしなくても、success なら自分で閉じる")
        let r = await row(session, "a5a7fe42c3e7ff80f")
        XCTAssertEqual(r?["state"] as? String, "stopped")
        let again = await session.stopTask(agentRequest)
        XCTAssertEqual(again, .notRunning)
        try await waitFor(5, "row stopped in the log") { [self] in await history(log, "a5a7fe42c3e7ff80f").last?.state == "stopped" }
        let h = await history(log, "a5a7fe42c3e7ff80f")
        XCTAssertEqual(h.last?.state, "stopped")
        await session.close()
        pump.cancel()
    }

    /// 親のサブエージェントを止めると、その子のシェルも CLI の task_* で閉じる（s15）。
    func testStopParentAgentClosesChildShell() async throws {
        try install(start: startLines("s15-stop-parent-with-bg-child"),
                    stops: ["a9ff03b60381154d4": stopLines("s15-stop-parent-with-bg-child", taskId: "a9ff03b60381154d4")])
        let (session, _, pump) = try start()
        try await launch(session, rows: ["a9ff03b60381154d4", "bvq0ugsjl"])

        let outcome = await session.stopTask(await stopRequest(session, "a9ff03b60381154d4"))
        XCTAssertEqual(outcome, .stopped)
        try await waitFor(5, "child shell stopped") { [self] in await row(session, "bvq0ugsjl")?["state"] as? String == "stopped" }
        let parent = await row(session, "a9ff03b60381154d4")
        XCTAssertEqual(parent?["state"] as? String, "stopped")
        await session.close()
        pump.cancel()
    }

    /// 同じ行への 2 つ目の停止は、新しく書かずに同じ結果を待つ。
    func testConcurrentStopsOfTheSameRowWriteOnce() async throws {
        setenv("FAKE_STOP_DELAY", "0.4", 1)
        try install(start: startLines("s1-stop-bg-bash"),
                    stops: ["br1svjoeb": stopLines("s1-stop-bg-bash", taskId: "br1svjoeb")])
        let (session, _, pump) = try start()
        try await launch(session, rows: ["br1svjoeb"])
        let request = await stopRequest(session, "br1svjoeb")

        async let first = session.stopTask(request)
        try await Task.sleep(nanoseconds: 150_000_000)
        async let second = session.stopTask(request)
        let (a, b) = await (first, second)
        XCTAssertEqual(a, .stopped)
        XCTAssertEqual(b, .stopped)
        XCTAssertEqual(stopWrites("br1svjoeb"), 1)
        await session.close()
        pump.cancel()
    }

    // MARK: 失敗の形

    /// 古い CLI（stop_task を知らない）。全行の手がかりを外して workflow_snapshot を送り、unsupported。
    func testUnsupportedSubtypeErrorTurnsStopOffWithASnapshot() async throws {
        setenv("FAKE_STOP_ERROR", "Unsupported control request subtype: stop_task", 1)
        try install(start: startLines("s1-stop-bg-bash"))
        let (session, log, pump) = try start()
        try await launch(session, rows: ["br1svjoeb"])
        let request = await stopRequest(session, "br1svjoeb")
        // 知らせは pump が別のタスクで log に移す。数える前に、行が止められる知らせまで届くのを待つ。
        try await waitFor(5, "row stoppable in the log") { [self] in await history(log, "br1svjoeb").last?.stoppable == true }
        let before = await payloads(log).count

        let outcome = await session.stopTask(request)
        XCTAssertEqual(outcome, .unsupported(nil))
        try await waitFor(5, "workflow_snapshot in the log") { [self] in
            await payloads(log).dropFirst(before).contains {
                $0["subtype"] as? String == "workflow_snapshot"
                    && ($0["agents"] as? [[String: Any]])?.first?["stoppable"] as? Bool == false
            }
        }
        let after = await payloads(log).dropFirst(before)
        let snapshot = after.last { $0["subtype"] as? String == "workflow_snapshot" }
        XCTAssertNotNil(snapshot, "手がかりを外した全行を送る")
        XCTAssertEqual((snapshot?["agents"] as? [[String: Any]])?.first?["stoppable"] as? Bool, false)
        let again = await session.stopTask(request)
        XCTAssertEqual(again, .unsupported(nil), "この世代では二度と書かない")
        XCTAssertEqual(stopWrites("br1svjoeb"), 1)
        await session.close()
        pump.cancel()
    }

    /// ほかの error は failed（CLI の文つき）。行は stoppable に戻る。
    func testOtherErrorIsFailedAndStoppableComesBack() async throws {
        setenv("FAKE_STOP_ERROR", "boom", 1)
        try install(start: startLines("s1-stop-bg-bash"))
        let (session, log, pump) = try start()
        try await launch(session, rows: ["br1svjoeb"])
        // 知らせは pump が別のタスクで log に移す。数える前に、行が止められる知らせまで届くのを待つ。
        try await waitFor(5, "row stoppable in the log") { [self] in await history(log, "br1svjoeb").last?.stoppable == true }
        let before = await history(log, "br1svjoeb").count

        let outcome = await session.stopTask(await stopRequest(session, "br1svjoeb"))
        XCTAssertEqual(outcome, .failed("boom"))
        let r = await row(session, "br1svjoeb")
        XCTAssertEqual(r?["state"] as? String, "running")
        XCTAssertEqual(r?["stoppable"] as? Bool, true)
        // 下ろした知らせ（false）と、戻した知らせ（true）が届くまで待つ。
        try await waitFor(5, "stoppable back in the log") { [self] in
            let h = await history(log, "br1svjoeb").dropFirst(before)
            return h.contains { $0.stoppable == false } && h.last?.stoppable == true
        }
        let h = await history(log, "br1svjoeb")
        XCTAssertEqual(h.last?.stoppable, true, "戻したことを送る")
        await session.close()
        pump.cancel()
    }

    /// 押した瞬間に行が自然に終わると、CLI は "Task X is not running (status: …)" で断る。失敗ではなく not_running。
    func testErrorForARowThatAlreadyEndedIsNotRunning() async throws {
        setenv("FAKE_STOP_ERROR", "Task br1svjoeb is not running (status: completed)", 1)
        defer { unsetenv("FAKE_STOP_ERROR") }
        try install(start: startLines("s1-stop-bg-bash"))
        let (session, _, pump) = try start()
        try await launch(session, rows: ["br1svjoeb"])
        let outcome = await session.stopTask(await stopRequest(session, "br1svjoeb"))
        XCTAssertEqual(outcome, .notRunning)
        await session.close()
        pump.cancel()
    }

    func testErrorForAWorkflowThatAlreadyEndedIsNotRunning() async throws {
        try install(start: Self.workflowStart,
                    stops: ["wf1": [#"{"type":"control_response","response":{"subtype":"error","request_id":"__RID__","error":"Task wf1 is not running (status: completed)"}}"#]])
        let (session, log, pump) = try start()
        await session.send("go", skills: [], attachments: [])
        try await waitFor(10, "workflow stoppable") { [self] in await workflowCard(log).last?["stoppable"] as? Bool == true }
        let outcome = await session.stopTask(StopTaskRequest(taskId: "wf1"))
        XCTAssertEqual(outcome, .notRunning)
        await session.close()
        pump.cancel()
    }

    /// 返事が来なければ timeout。プロセスは止めず、行は stoppable に戻る。
    func testNoReplyIsTimeoutAndKeepsTheProcess() async throws {
        setenv("FAKE_STOP_SILENT", "1", 1)
        try install(start: startLines("s1-stop-bg-bash"))
        let (session, _, pump) = try start()
        session.stopReplyNanos = 300_000_000
        try await launch(session, rows: ["br1svjoeb"])

        let outcome = await session.stopTask(await stopRequest(session, "br1svjoeb"))
        XCTAssertEqual(outcome, .timeout)
        let r = await row(session, "br1svjoeb")
        XCTAssertEqual(r?["stoppable"] as? Bool, true)
        XCTAssertEqual(starts(), 1)
        await session.close()
        pump.cancel()
    }

    /// 返事を待つ間にプロセスが終わった。not_running（行は終了処理が閉じる）。
    func testProcessExitWhileWaitingIsNotRunning() async throws {
        setenv("FAKE_STOP_EXIT", "1", 1)
        try install(start: startLines("s1-stop-bg-bash"))
        let (session, log, pump) = try start()
        try await launch(session, rows: ["br1svjoeb"])

        let outcome = await session.stopTask(await stopRequest(session, "br1svjoeb"))
        XCTAssertEqual(outcome, .notRunning)
        try await waitFor(5, "row closed") { [self] in await history(log, "br1svjoeb").last?.state == "stopped" }
        await session.close()
        pump.cancel()
    }

    /// initialize を知らない CLI では、行は stoppable にならない。stop_task も書かない。
    func testRefusedInitializeMeansNoStopHandle() async throws {
        setenv("FAKE_CLAUDE_NOINIT", "1", 1)
        try install(start: startLines("s1-stop-bg-bash"))
        let (session, _, pump) = try start()
        await session.send("go", skills: [], attachments: [])
        try await waitFor(10, "row") { [self] in await row(session, "br1svjoeb") != nil }
        let r = await row(session, "br1svjoeb")
        XCTAssertEqual(r?["stoppable"] as? Bool, false)
        let outcome = await session.stopTask(await stopRequest(session, "br1svjoeb"))
        XCTAssertEqual(outcome, .unsupported(nil))
        XCTAssertEqual(stopWrites("br1svjoeb"), 0)
        await session.close()
        pump.cancel()
    }

    func testStaleAndUnknownRows() async throws {
        try install(start: startLines("s1-stop-bg-bash"))
        let (session, _, pump) = try start()
        let none = await session.stopTask(StopTaskRequest(taskId: "subagents", rowId: "br1svjoeb", epoch: "x"))
        XCTAssertEqual(none, .stale, "行が無い")
        try await launch(session, rows: ["br1svjoeb"])
        let wrongEpoch = await session.stopTask(StopTaskRequest(taskId: "subagents", rowId: "br1svjoeb", epoch: "other"))
        XCTAssertEqual(wrongEpoch, .stale)
        let unknown = await session.stopTask(StopTaskRequest(taskId: "subagents", rowId: "nope", epoch: await epoch(session)))
        XCTAssertEqual(unknown, .stale)
        let missing = await session.stopTask(StopTaskRequest(taskId: "subagents", rowId: nil, epoch: nil))
        XCTAssertEqual(missing, .stale)
        let workflow = await session.stopTask(StopTaskRequest(taskId: "unknown-workflow"))
        XCTAssertEqual(workflow, .notRunning)
        XCTAssertEqual(stopWrites("br1svjoeb"), 0)
        await session.close()
        pump.cancel()
    }

    // MARK: dynamic workflow

    private static let workflowStart = [
        #"{"type":"system","subtype":"task_started","task_id":"wf1","task_type":"local_workflow","workflow_name":"review","description":"Review","is_backgrounded":true}"#,
        #"{"type":"system","subtype":"task_progress","task_id":"wf1","workflow_progress":[{"type":"workflow_phase","index":1,"title":"Plan"},{"type":"workflow_agent","index":1,"label":"planner","phaseIndex":1,"phaseTitle":"Plan","state":"progress","startedAt":1760000000000}]}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"started"}"#,
    ]
    private static let workflowEnd = [
        #"{"type":"system","subtype":"task_updated","task_id":"wf1","patch":{"status":"killed","end_time":1760000005000}}"#,
        #"{"type":"system","subtype":"task_notification","task_id":"wf1","status":"stopped","summary":"stopped"}"#,
        #"{"type":"control_response","response":{"subtype":"success","request_id":"__RID__","response":{}}}"#,
    ]

    private func workflowCard(_ log: SpawnEventLog, _ id: String = "wf1") async -> [[String: Any]] {
        await payloads(log).filter { $0["taskId"] as? String == id }
    }

    /// カード全体の停止: 頼んだ間は stoppable を下ろして送り、カードが終われば stopped（failed + outcome stopped）。
    func testStopDynamicWorkflow() async throws {
        try install(start: Self.workflowStart, stops: ["wf1": Self.workflowEnd])
        let (session, log, pump) = try start()
        await session.send("go", skills: [], attachments: [])
        try await waitFor(10, "workflow stoppable") { [self] in await workflowCard(log).last?["stoppable"] as? Bool == true }

        let outcome = await session.stopTask(StopTaskRequest(taskId: "wf1"))
        XCTAssertEqual(outcome, .stopped)
        let cards = await workflowCard(log)
        let stoppables = cards.map { $0["stoppable"] as? Bool }
        XCTAssertTrue(stoppables.contains(false), "頼んだ間は false")
        XCTAssertEqual(cards.last?["status"] as? String, "failed")
        XCTAssertEqual(cards.last?["outcome"] as? String, "stopped")
        XCTAssertEqual(cards.last?["stoppable"] as? Bool, false, "終わったカードは false")
        XCTAssertEqual(stopWrites("wf1"), 1)
        let again = await session.stopTask(StopTaskRequest(taskId: "wf1"))
        XCTAssertEqual(again, .notRunning)
        await session.close()
        pump.cancel()
    }

    /// success の後もカードが終わらなければ、閉じずに workflowStopEnabled を外して failed。以後は unsupported。
    func testWorkflowThatDoesNotEndTurnsWorkflowStopOff() async throws {
        try install(start: Self.workflowStart,
                    stops: ["wf1": [#"{"type":"control_response","response":{"subtype":"success","request_id":"__RID__","response":{}}}"#]])
        let (session, log, pump) = try start()
        session.workflowEndNanos = 300_000_000
        await session.send("go", skills: [], attachments: [])
        try await waitFor(10, "workflow stoppable") { [self] in await workflowCard(log).last?["stoppable"] as? Bool == true }

        let outcome = await session.stopTask(StopTaskRequest(taskId: "wf1"))
        XCTAssertEqual(outcome, .failed(nil))
        let cards = await workflowCard(log)
        XCTAssertEqual(cards.last?["status"] as? String, "running", "閉じない")
        XCTAssertEqual(cards.last?["stoppable"] as? Bool, false)
        let again = await session.stopTask(StopTaskRequest(taskId: "wf1"))
        XCTAssertEqual(again, .unsupported(nil))
        // 行の停止は使える。
        XCTAssertEqual(starts(), 1)
        await session.close()
        pump.cancel()
    }

    /// カードは終わったのに停止の返事が来ない(timeout)。終わったカードに status running を送り直して、実行中に戻さない。
    func testWorkflowEndedBeforeStopTimeoutIsNotReopened() async throws {
        try install(start: Self.workflowStart, stops: ["wf1": Array(Self.workflowEnd.dropLast())])
        let (session, log, pump) = try start()
        session.stopReplyNanos = 300_000_000
        await session.send("go", skills: [], attachments: [])
        try await waitFor(10, "workflow stoppable") { [self] in await workflowCard(log).last?["stoppable"] as? Bool == true }

        let outcome = await session.stopTask(StopTaskRequest(taskId: "wf1"))
        XCTAssertEqual(outcome, .notRunning, "終わったカードは timeout ではなく not_running")
        let cards = await workflowCard(log)
        XCTAssertEqual(cards.last?["status"] as? String, "failed", "終わったカードを running に戻さない")
        XCTAssertEqual(cards.last?["outcome"] as? String, "stopped")
        await session.close()
        pump.cancel()
    }

    /// 閉じる payload（close）は stoppable: false で、phases を持たない。
    func testAbandonedWorkflowPayloadHasNoPhasesAndIsNotStoppable() async throws {
        try install(start: Self.workflowStart)
        let (session, log, pump) = try start()
        await session.send("go", skills: [], attachments: [])
        try await waitFor(10, "workflow stoppable") { [self] in await workflowCard(log).last?["stoppable"] as? Bool == true }
        let running = await workflowCard(log).last
        XCTAssertEqual((running?["phases"] as? [[String: Any]])?.first?["title"] as? String, "Plan")

        await session.close()
        await pump.value
        let closing = await workflowCard(log).last
        XCTAssertEqual(closing?["outcome"] as? String, "stopped")
        XCTAssertEqual(closing?["stoppable"] as? Bool, false)
        XCTAssertNil(closing?["phases"])
    }

    // MARK: phases（workflow-phases の実測）

    private func replayWorkflow(_ name: String) throws -> (lines: [[String: Any]], expected: [[String: Any]]) {
        func load(_ file: String) throws -> [[String: Any]] {
            try String(contentsOf: Self.fixtureDir.appendingPathComponent("workflow-phases/\(file)"), encoding: .utf8)
                .split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        let lines = try load("\(name).workflow-lines.jsonl").filter { $0["subtype"] as? String != "background_tasks_changed" }
        let expected = try load("\(name).payloads.jsonl").compactMap { $0["proposed"] as? [String: Any] }
        return (lines, expected)
    }

    private func payloadsOf(_ lines: [[String: Any]], session: ClaudeCodeSession) -> [[String: Any]] {
        lines.compactMap { Self.obj(session.workflowEventPayload(from: $0)).isEmpty ? nil : Self.obj(session.workflowEventPayload(from: $0)) }
    }

    private func offlineSession() -> ClaudeCodeSession {
        ClaudeCodeSession(agentId: agentId, profile: .claude, initialSessionId: nil, cwd: dir.path,
                          executable: "/usr/bin/false", store: .shared)
    }

    /// W（宣言した 3 段階など）と X（宣言なし・重複・空白・日本語・agents 0）の全部の行を流し、記録した payload と比べる。
    /// 違うのは stoppable（この記録の後に足した）と、空白を整えた title だけ。
    func testPhasesMatchRecordedWorkflowRuns() throws {
        for name in ["W", "X"] {
            let (lines, expected) = try replayWorkflow(name)
            let session = offlineSession()
            var actual: [[String: Any]] = []
            for line in lines {
                let json = session.workflowEventPayload(from: line)
                if let json { actual.append(Self.obj(json)) }
            }
            XCTAssertEqual(actual.count, expected.count, name)
            for (a, e) in zip(actual, expected) {
                var mine = a
                XCTAssertEqual(mine.removeValue(forKey: "stoppable") as? Bool, false, "プロセスが無いので止められない")
                var want = e
                if (want["phases"] as? [[String: Any]])?.contains(where: { ($0["title"] as? String)?.hasPrefix(" ") == true }) == true {
                    want["phases"] = (want["phases"] as? [[String: Any]])?.map { p -> [String: Any] in
                        var q = p
                        q["title"] = (p["title"] as? String)?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        return q
                    }
                }
                XCTAssertEqual(NSDictionary(dictionary: mine), NSDictionary(dictionary: want), "\(name) \(a["subtype"] ?? "")")
            }
        }
    }

    func testPhasesDetails() throws {
        // Probe A: 宣言した 3 つ。進み具合だけの行・task_started・終わりの行には付けない。
        let (lines, _) = try replayWorkflow("W")
        let session = offlineSession()
        let all = lines.compactMap { session.workflowEventPayload(from: $0) }.map(Self.obj)
            .filter { $0["taskId"] as? String == "w10vzbfuf" }
        let withAgents = all.filter { $0["agents"] != nil }
        XCTAssertFalse(withAgents.isEmpty)
        for p in withAgents {
            XCTAssertEqual((p["phases"] as? [[String: Any]])?.compactMap { $0["title"] as? String }.prefix(3), ["Scan", "Fix", "Check"][...])
        }
        XCTAssertTrue(all.filter { $0["agents"] == nil }.allSatisfy { $0["phases"] == nil }, "進み具合だけの行に phases は無い")

        // Probe G: agents 0 でも phases 2。Probe D: 宣言なしは []。
        let (xLines, _) = try replayWorkflow("X")
        let x = xLines.compactMap { session.workflowEventPayload(from: $0) }.map(Self.obj)
        let g = x.last { $0["taskId"] as? String == "w26wnsguu" && $0["agents"] != nil }
        XCTAssertEqual((g?["agents"] as? [Any])?.count, 0)
        XCTAssertEqual((g?["phases"] as? [[String: Any]])?.count, 2)
        let d = x.first { $0["taskId"] as? String == "wvobqintp" && $0["agents"] != nil }
        XCTAssertEqual((d?["phases"] as? [Any])?.count, 0)
        XCTAssertNotNil(d?["phases"])
    }

    func testWorkflowPhasesNormalisation() {
        let progress: [[String: Any]] = [
            ["type": "workflow_phase", "index": 3, "title": "  調査\n  の   結果 "],
            ["type": "workflow_phase", "index": 1, "title": "First"],
            ["type": "workflow_phase", "index": 1, "title": "Dup"],
            ["type": "workflow_phase", "index": 2, "title": "   \n "],
            ["type": "workflow_phase", "index": 4, "title": String(repeating: "あ", count: 100)],
            ["type": "workflow_phase", "title": "no index"],
            ["type": "workflow_phase", "index": 5],
            ["type": "workflow_agent", "index": 6, "title": "agent"],
        ]
        let phases = ClaudeCodeSession.workflowPhases(progress)
        XCTAssertEqual(phases.compactMap { $0["index"] as? Int }, [1, 3, 4])
        XCTAssertEqual(phases.compactMap { $0["title"] as? String }.first, "First")
        XCTAssertEqual(phases[1]["title"] as? String, "調査 の 結果")
        XCTAssertEqual((phases[2]["title"] as? String)?.count, 80)
        XCTAssertEqual(ClaudeCodeSession.workflowPhases([]).count, 0)
    }
}
