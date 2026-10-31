import XCTest
@testable import BridgeApp

/// ClaudeTurnRouter（常駐の claude の stdout の行と、ターン＝発話・知らせの結び付け）を、実測の行の並びで確かめる
/// （docs/BACKGROUND_WORK_2026-10-21.md §3.3。claude 2.1.300、probe-uuid の U1〜U3、probe-stream の S1・S3r・S9・S11・S6a・S13）。
/// 行はルーターの判断に関わる項目だけを残したもの（並びと種類は実測のまま）。`>send <uuid>` は stdin に user 行を書いた時点
/// （uuid を付けていない probe は仮の id）、`>interrupt <id>` は停止の制御要求を書いた時点。
final class ClaudeTurnRouterTests: XCTestCase {

    /// 知らせのターンの id を N1, N2 … と振る（テストで名指しできるように）。
    private final class Ids {
        private var n = 0
        func next() -> String { n += 1; return "N\(n)" }
    }

    /// アダプター（ClaudeCodeSession）と同じ帳簿で行を流した結果。どのターンに本文が流れ、どう閉じたか。
    private struct Replay {
        var router: ClaudeTurnRouter
        /// messageId → 流れた本文
        var texts: [String: String] = [:]
        var closures: [ClaudeTurnRouter.Closure] = []
        var switches: [[String]] = []
        var opened: [String] = []
        var swallowed = 0
        /// 停止を書いたときのターン（アダプターの PendingInterrupt.targets）
        var targets: Set<String> = []
        var stillQueued: [String] = []
    }

    /// 発話の messageId（Turn.messageId は UUID().uuidString なので大文字。stdin の uuid はその小文字）。
    private func mid(_ uuid: String) -> String { uuid.uppercased() }

    private func obj(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    private func replay(_ fixture: String) -> Replay {
        let ids = Ids()
        var r = Replay(router: ClaudeTurnRouter(makeId: ids.next))
        for raw in fixture.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(">send ") {
                let id = mid(String(line.dropFirst(6)))
                r.router.register(messageId: id)
                r.texts[id] = ""
                continue
            }
            if line.hasPrefix(">interrupt") {
                r.targets = Set(r.router.registered.map(\.messageId) + [r.router.notificationId].compactMap { $0 })
                continue
            }
            let o = obj(line)
            if o["type"] as? String == "control_response" {
                let c = r.router.acknowledgeInterrupt(targets: r.targets, stillQueued: r.stillQueued)
                if !c.isEmpty { r.closures.append(c) }
                continue
            }
            let step = r.router.ingest(o)
            if let n = step.openedNotification {
                r.opened.append(n)
                r.texts[n] = ""
            }
            if let from = step.switchedFrom, let to = r.router.current { r.switches.append([from, to]) }
            if step.swallowed { r.swallowed += 1 }
            if !step.swallowed, let target = step.output, ClaudeTurnRouter.isTextDelta(o),
               let text = ((o["event"] as? [String: Any])?["delta"] as? [String: Any])?["text"] as? String {
                r.texts[target, default: ""] += text
            }
            if let c = step.closure { r.closures.append(c) }
        }
        return r
    }

    private func closure(_ ids: [String], notification: String? = nil, interrupted: Bool = false) -> ClaudeTurnRouter.Closure {
        var c = ClaudeTurnRouter.Closure()
        c.messageIds = ids
        c.notificationId = notification
        c.interrupted = interrupted
        return c
    }

    // MARK: - uuid を返す CLI（2.1.300）

    /// U1: バックグラウンドの Bash → result で発話 A を閉じる → シェルが終わって知らせのターン（uuid の無い status・
    /// origin 付きの result）→ 次の発話 B。知らせのターンの本文は A にも B にも混ざらず、done は知らせのターンだけで出る。
    func testU1NotificationTurnBetweenUserTurns() {
        let a = mid("aaaaaaaa-0000-4000-8000-000000000001"), b = mid("aaaaaaaa-0000-4000-8000-000000000002")
        let r = replay(Probe.u1)
        XCTAssertEqual(r.closures, [closure([a]), closure([], notification: "N1"), closure([b])])
        XCTAssertTrue(r.closures[1].notificationOnly, "知らせのターンだけを閉じる done（origin = task-notification）")
        XCTAssertEqual(r.texts[a], "started")
        XCTAssertEqual(r.texts["N1"], "The background `sleep 12; echo done` command finished with exit code 0.")
        XCTAssertEqual(r.texts[b], "7")
        XCTAssertEqual(r.opened, ["N1"])
        XCTAssertTrue(r.switches.isEmpty)
        XCTAssertTrue(r.router.registered.isEmpty, "閉じ残しが無い")
        XCTAssertTrue(r.router.isIdle)
    }

    /// U2: 生成中に差し込んだ B が A のターンに合流し、result は 2 通分で 1 つ。B が始まった後の本文は B に流し、
    /// result で A と B を両方閉じる（done は B で 1 回）。command_lifecycle completed(B) は result より先に来るが、
    /// 始まった B は閉じない。
    func testU2InjectedMessageJoinsTheTurnAndOneResultClosesBoth() {
        let a = mid("bbbbbbbb-0000-4000-8000-000000000001"), b = mid("bbbbbbbb-0000-4000-8000-000000000002")
        let r = replay(Probe.u2)
        XCTAssertEqual(r.closures, [closure([a, b])])
        XCTAssertEqual(r.closures.first?.doneMessageId, b)
        XCTAssertEqual(r.switches, [[a, b]], "B が始まったところで吹き出しを区切る")
        XCTAssertEqual(r.texts[a], "")
        XCTAssertEqual(r.texts[b], "first\n\nBANANA")
        XCTAssertTrue(r.router.registered.isEmpty, "B が閉じ残らない（次の発話の返事が B に入らない）")
    }

    /// U3: 続けて書いた 2 通は順に処理され、それぞれの result で閉じる。
    func testU3BackToBackMessagesCloseInOrder() {
        let one = mid("cccccccc-0000-4000-8000-000000000001"), two = mid("cccccccc-0000-4000-8000-000000000002")
        let r = replay(Probe.u3)
        XCTAssertEqual(r.closures, [closure([one]), closure([two])])
        XCTAssertEqual(r.texts[one], "one")
        XCTAssertEqual(r.texts[two], "two")
        XCTAssertTrue(r.switches.isEmpty)
    }

    // MARK: - uuid を返さない古い CLI（command_lifecycle を見ていない → FIFO）

    /// S1: バックグラウンドのサブエージェント。サブエージェントの行（parent_tool_use_id 付き）と task_* はターンの
    /// 出力ではない。登録の無いときの出力は知らせのターン、登録があれば先頭の発話へ。
    func testS1BackgroundSubagentWithOldCli() {
        let r = replay(Probe.s1)
        XCTAssertEqual(r.closures, [closure(["S1-1"]), closure([], notification: "N1"), closure(["S1-2"])])
        XCTAssertTrue((r.texts["S1-1"] ?? "").hasPrefix("The sleep probe subagent is running in the background"))
        XCTAssertEqual(r.texts["N1"], "The sleep probe reported `hi`. The subagent ran `sleep 20; echo hi` once and returned that output.")
        XCTAssertEqual(r.texts["S1-2"], "It reported `hi`.")
        XCTAssertFalse(r.router.sawLifecycle)
    }

    /// S3r: ターンより長く動くバックグラウンドの Bash。終わると知らせのターン。
    func testS3rBackgroundShellWithOldCli() {
        let r = replay(Probe.s3r)
        XCTAssertEqual(r.closures, [closure(["S3R-1"]), closure([], notification: "N1"), closure(["S3R-2"])])
        XCTAssertEqual(r.texts["S3R-1"], "started")
        XCTAssertEqual(r.texts["N1"], "The background command finished with exit code 0. Its output was `done`.")
        XCTAssertEqual(r.texts["S3R-2"], "Yes, it finished with exit code 0 and printed \"done\".")
    }

    /// S9: 知らせのターンの途中（status の後）に発話 U を書いた。知らせのターンの本文と result は U に入れず、
    /// U はその後の CLI のターンで返事を受ける（今までの FIFO では U が知らせの本文で閉じ、本当の返事が捨てられた）。
    func testS9MessageWrittenDuringANotificationTurn() {
        let r = replay(Probe.s9)
        XCTAssertEqual(r.closures, [closure(["S9-1"]), closure([], notification: "N1"), closure(["S9-2"])])
        XCTAssertEqual(r.texts["N1"], "The background command finished with exit code 0. Its output was `done`.")
        XCTAssertEqual(r.texts["S9-2"], "6")
    }

    /// S11: S9 に --replay-user-messages（再送の user 行は出力の行として今の宛先に入る）。
    func testS11ReplayLinesDoNotChangeTheRouting() {
        let r = replay(Probe.s11)
        XCTAssertEqual(r.closures, [closure(["S11-1"]), closure([], notification: "N1"), closure(["S11-2"])])
        XCTAssertEqual(r.texts["S11-1"], "started")
        XCTAssertEqual(r.texts["S11-2"], "6")
    }

    // MARK: - 停止（control_request の interrupt）

    /// S6a: ターン中の停止。返事（control_response）で発話を中断として閉じ、中断したターンの残り（status・
    /// [Request interrupted by user]・result error_during_execution）は捨てる。プロセスは生きていて、次の発話は普通に答える。
    func testS6aInterruptClosesTheTurnAndSwallowsItsTail() {
        let r = replay(Probe.s6a)
        XCTAssertEqual(r.closures, [closure(["S6A-1"], interrupted: true), closure(["S6A-2"])])
        XCTAssertEqual(r.swallowed, 3)
        XCTAssertTrue(r.opened.isEmpty, "中断の残りで知らせのターンを開かない")
        XCTAssertEqual(r.texts["S6A-2"], "alive")
    }

    /// S13: 前景の Bash の途中で停止。中断の result は捨て、残ったバックグラウンドのシェルが終わったときの知らせのターンは
    /// 普通に出す。
    func testS13InterruptThenNotificationTurn() {
        let r = replay(Probe.s13)
        XCTAssertEqual(r.closures, [
            closure(["S13-1"], interrupted: true), closure([], notification: "N1"), closure(["S13-2"]),
        ])
        XCTAssertEqual(r.swallowed, 3)
        XCTAssertTrue((r.texts["N1"] ?? "").hasPrefix("The background step finished (`sleep 19; echo q`, exit 0)."))
        XCTAssertEqual(r.texts["S13-2"], "alive")
    }

    // MARK: - 規則ごと

    private func line(_ json: String) -> [String: Any] { obj(json) }

    /// 知らせのターンに発話が合流したら、その発話へ切り替え、result で両方閉じる（done は発話）。
    func testMessageJoiningANotificationTurn() {
        let ids = Ids()
        var router = ClaudeTurnRouter(makeId: ids.next)
        let opened = router.ingest(line(#"{"type":"system","subtype":"status","status":"requesting"}"#))
        XCTAssertEqual(opened.openedNotification, "N1")
        router.register(messageId: "X1")
        let started = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"x1","state":"started"}"#))
        XCTAssertEqual(started.switchedFrom, "N1")
        XCTAssertEqual(router.current, "X1")
        let done = router.ingest(line(#"{"type":"result","subtype":"success","user_message_uuids":["x1"],"origin":{"kind":"task-notification"}}"#))
        XCTAssertEqual(done.closure, closure(["X1"], notification: "N1"))
        XCTAssertEqual(done.closure?.doneMessageId, "X1")
        XCTAssertEqual(done.closure?.notificationOnly, false)
    }

    /// command_lifecycle completed が、始まっていない発話に来たら閉じる（取りこぼしの保険）。ほかのターンが出力して
    /// いる間は done を出さない。
    func testCompletedBeforeStartedClosesQuietlyWhileAnotherTurnStreams() {
        var router = ClaudeTurnRouter()
        router.register(messageId: "A")
        router.register(messageId: "B")
        _ = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"a","state":"started"}"#))
        let quiet = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"b","state":"completed"}"#))
        XCTAssertEqual(quiet.closure?.messageIds, ["B"])
        XCTAssertEqual(quiet.closure?.emitsDone, false)
        // 始まった発話の completed では閉じない（result で閉じる）。
        XCTAssertNil(router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"a","state":"completed"}"#)).closure)
        XCTAssertEqual(router.registered.map(\.messageId), ["A"])
    }

    /// cancel_queued で取り消された発話（command_lifecycle cancelled）は中断として閉じる。
    func testCancelledLifecycleClosesAsInterrupted() {
        var router = ClaudeTurnRouter()
        router.register(messageId: "A")
        let step = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"a","state":"cancelled"}"#))
        XCTAssertEqual(step.closure, closure(["A"], interrupted: true))
        XCTAssertEqual(step.closure?.emitsDone, true)
    }

    /// 停止の返事は、止めると決めたときのターンだけを閉じる。後から送った発話と、まだ走る発話（still_queued）は残す。
    func testInterruptReceiptClosesOnlyTargetsAndKeepsSurvivors() {
        var router = ClaudeTurnRouter()
        router.register(messageId: "A")
        router.register(messageId: "Q")
        _ = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"a","state":"started"}"#))
        let targets: Set<String> = ["A", "Q"]
        router.register(messageId: "LATE")
        let c = router.acknowledgeInterrupt(targets: targets, stillQueued: ["q"])
        XCTAssertEqual(c, closure(["A"], interrupted: true))
        XCTAssertEqual(router.registered.map(\.messageId), ["Q", "LATE"])
        XCTAssertTrue(router.draining)
        // 中断したターンの result は捨て、生き延びた Q が始まれば普通に流す。
        XCTAssertTrue(router.ingest(line(#"{"type":"result","subtype":"error_during_execution","user_message_uuids":["a"]}"#)).swallowed)
        _ = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"q","state":"started"}"#))
        XCTAssertEqual(router.ingest(line(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"q"}}}"#)).output, "Q")
    }

    /// 停止の返事の前に、止めるターンが result で終わっていたら、返事では何も閉じず、残りも捨てない。
    func testInterruptReceiptAfterTheTurnEnded() {
        var router = ClaudeTurnRouter()
        router.register(messageId: "A")
        _ = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"a","state":"started"}"#))
        XCTAssertEqual(router.ingest(line(#"{"type":"result","subtype":"success","user_message_uuids":["a"]}"#)).closure, closure(["A"]))
        let c = router.acknowledgeInterrupt(targets: ["A"], stillQueued: [])
        XCTAssertTrue(c.isEmpty)
        XCTAssertFalse(router.draining)
        XCTAssertEqual(router.ingest(line(#"{"type":"system","subtype":"status","status":"requesting"}"#)).openedNotification?.isEmpty, false)
    }

    /// 閉じた発話の uuid を持つ行（中断の後の残りなど）は、知らせのターンを開かずに捨てる。CLI の内部の uuid（知らない
    /// もの）の行は、知らせのターンとして開いて閉じる。
    func testLinesOfClosedAndUnknownUuids() {
        var router = ClaudeTurnRouter()
        router.register(messageId: "A")
        _ = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"a","state":"started"}"#))
        _ = router.ingest(line(#"{"type":"result","subtype":"success","user_message_uuids":["a"]}"#))
        XCTAssertTrue(router.ingest(line(#"{"type":"system","subtype":"status","status":"requesting","user_message_uuids":["a"]}"#)).swallowed)
        XCTAssertTrue(router.ingest(line(#"{"type":"result","subtype":"success","user_message_uuids":["a"]}"#)).swallowed)
        let internalTurn = router.ingest(line(#"{"type":"system","subtype":"status","status":"requesting","user_message_uuids":["cron-1"]}"#))
        XCTAssertNotNil(internalTurn.openedNotification)
        XCTAssertEqual(router.ingest(line(#"{"type":"result","subtype":"success","user_message_uuids":["cron-1"]}"#)).closure?.notificationOnly, true)
    }

    /// サブエージェントの行・task_*・status: null・init は出力ではない（知らせのターンを開かない）。
    func testNonOutputLines() {
        var router = ClaudeTurnRouter()
        for json in [
            #"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"content":[{"type":"text","text":"sub"}]}}"#,
            #"{"type":"user","parent_tool_use_id":"toolu_1"}"#,
            #"{"type":"system","subtype":"task_started","task_id":"t1","task_type":"local_agent"}"#,
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#,
            #"{"type":"system","subtype":"status","status":null}"#,
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"system","subtype":"hook_started"}"#,
            #"{"type":"rate_limit_event"}"#,
        ] {
            XCTAssertEqual(router.ingest(line(json)), ClaudeTurnRouter.Step(), json)
        }
        XCTAssertTrue(router.isIdle)
    }

    /// 本文の差分を見なかった CLI のターンは、result の本文を本文にする（呼び出し側が result の前に sawTextDelta を読む）。
    func testSawTextDeltaIsPerCliTurn() {
        var router = ClaudeTurnRouter()
        router.register(messageId: "A")
        _ = router.ingest(line(#"{"type":"command_lifecycle","command_uuid":"a","state":"started"}"#))
        _ = router.ingest(line(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}}"#))
        XCTAssertTrue(router.sawTextDelta)
        _ = router.ingest(line(#"{"type":"result","subtype":"success","user_message_uuids":["a"]}"#))
        XCTAssertFalse(router.sawTextDelta, "次のターンは数え直す")
    }

    /// 停止の制御要求と、その返事（実測 S6a の形。request_id は response の中）。
    func testInterruptRequestAndResponseLines() {
        let request = ClaudeControlProtocol.interruptRequest(requestId: "r-1")
        XCTAssertEqual(request["type"] as? String, "control_request")
        XCTAssertEqual(request["request_id"] as? String, "r-1")
        XCTAssertEqual((request["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
        XCTAssertEqual((request["request"] as? [String: Any])?["cancel_queued"] as? Bool, true)

        let ok = ClaudeControlProtocol.parse(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"probe-1","response":{"still_queued":["a"]}}}"#)
        guard case .response(let r)? = ok else { return XCTFail("control_response を読む") }
        XCTAssertEqual(r.requestId, "probe-1")
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.stillQueued, ["a"])

        let refused = ClaudeControlProtocol.parse(
            #"{"type":"control_response","response":{"subtype":"error","request_id":"probe-2","error":"nothing to interrupt"}}"#)
        guard case .response(let e)? = refused else { return XCTFail("エラーの返事も読む") }
        XCTAssertFalse(e.success)
        XCTAssertEqual(e.error, "nothing to interrupt")
        XCTAssertNil(ClaudeControlProtocol.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"the control_response type"}]}}"#))
    }

    /// 古い CLI で書けなかった発話を外すと、次の出力は残りの先頭へ。
    func testUnregisterRemovesTheTurn() {
        var router = ClaudeTurnRouter()
        router.register(messageId: "A")
        router.register(messageId: "B")
        router.unregister(messageId: "A")
        XCTAssertEqual(router.ingest(line(#"{"type":"system","subtype":"status","status":"requesting"}"#)).output, "B")
    }
}

/// 実測の行の並び（ルーターの判断に関わる項目だけを残した）。
private enum Probe {
    static let u1 = #"""
    >send aaaaaaaa-0000-4000-8000-000000000001
    {"type":"command_lifecycle","command_uuid":"aaaaaaaa-0000-4000-8000-000000000001","state":"queued"}
    {"type":"command_lifecycle","command_uuid":"aaaaaaaa-0000-4000-8000-000000000001","state":"started"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000001"]}
    {"type":"stream_event","user_message_uuid":"aaaaaaaa-0000-4000-8000-000000000001","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000001"],"event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","user_message_uuid":"aaaaaaaa-0000-4000-8000-000000000001","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000001"],"message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_01QwZioMM3wQMAAbpXyi4kRo"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"task_started","task_id":"b0pg8yn6s","task_type":"local_bash","is_backgrounded":true}
    {"type":"user"}
    {"type":"system","subtype":"status","status":"requesting","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000001"]}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"started"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"started"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","user_message_uuid":"aaaaaaaa-0000-4000-8000-000000000001","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000001"],"is_error":false,"result":"started"}
    {"type":"command_lifecycle","command_uuid":"aaaaaaaa-0000-4000-8000-000000000001","state":"completed"}
    {"type":"system","subtype":"task_updated","task_id":"b0pg8yn6s","patch":{"status":"completed"}}
    {"type":"system","subtype":"task_notification","status":"completed","task_id":"b0pg8yn6s"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The background `"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sleep 12;"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" echo done` command finished with"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" exit code 0."}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The background `sleep 12; echo done` com"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","origin":{"kind":"task-notification","producer":"session-task","runId":"0mvgtiebl-d2ad42b7"},"is_error":false,"result":"The background `sleep 12; echo done` command finished with exit code 0."}
    >send aaaaaaaa-0000-4000-8000-000000000002
    {"type":"command_lifecycle","command_uuid":"aaaaaaaa-0000-4000-8000-000000000002","state":"queued"}
    {"type":"command_lifecycle","command_uuid":"aaaaaaaa-0000-4000-8000-000000000002","state":"started"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000002"]}
    {"type":"stream_event","user_message_uuid":"aaaaaaaa-0000-4000-8000-000000000002","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000002"],"event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"7"}}}
    {"type":"assistant","user_message_uuid":"aaaaaaaa-0000-4000-8000-000000000002","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000002"],"message":{"content":[{"type":"text","text":"7"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","user_message_uuid":"aaaaaaaa-0000-4000-8000-000000000002","user_message_uuids":["aaaaaaaa-0000-4000-8000-000000000002"],"is_error":false,"result":"7"}
    {"type":"command_lifecycle","command_uuid":"aaaaaaaa-0000-4000-8000-000000000002","state":"completed"}
    """#

    static let u2 = #"""
    >send bbbbbbbb-0000-4000-8000-000000000001
    {"type":"command_lifecycle","command_uuid":"bbbbbbbb-0000-4000-8000-000000000001","state":"queued"}
    {"type":"command_lifecycle","command_uuid":"bbbbbbbb-0000-4000-8000-000000000001","state":"started"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting","user_message_uuids":["bbbbbbbb-0000-4000-8000-000000000001"]}
    {"type":"stream_event","user_message_uuid":"bbbbbbbb-0000-4000-8000-000000000001","user_message_uuids":["bbbbbbbb-0000-4000-8000-000000000001"],"event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","user_message_uuid":"bbbbbbbb-0000-4000-8000-000000000001","user_message_uuids":["bbbbbbbb-0000-4000-8000-000000000001"],"message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_01HbsptbsMSmLVoDAteWRo8r"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    >send bbbbbbbb-0000-4000-8000-000000000002
    {"type":"command_lifecycle","command_uuid":"bbbbbbbb-0000-4000-8000-000000000002","state":"queued"}
    {"type":"system","subtype":"task_started","task_id":"bnfo427p8","task_type":"local_bash","is_backgrounded":false}
    {"type":"system","subtype":"task_notification","status":"completed","task_id":"bnfo427p8"}
    {"type":"user"}
    {"type":"command_lifecycle","command_uuid":"bbbbbbbb-0000-4000-8000-000000000002","state":"started"}
    {"type":"system","subtype":"status","status":"requesting","user_message_uuids":["bbbbbbbb-0000-4000-8000-000000000001","bbbbbbbb-0000-4000-8000-000000000002"]}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"first\n\nB"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ANANA"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"first\n\nBANANA"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"command_lifecycle","command_uuid":"bbbbbbbb-0000-4000-8000-000000000002","state":"completed"}
    {"type":"result","subtype":"success","user_message_uuid":"bbbbbbbb-0000-4000-8000-000000000001","user_message_uuids":["bbbbbbbb-0000-4000-8000-000000000001","bbbbbbbb-0000-4000-8000-000000000002"],"is_error":false,"result":"first\n\nBANANA"}
    {"type":"command_lifecycle","command_uuid":"bbbbbbbb-0000-4000-8000-000000000001","state":"completed"}
    """#

    static let u3 = #"""
    >send cccccccc-0000-4000-8000-000000000001
    >send cccccccc-0000-4000-8000-000000000002
    {"type":"command_lifecycle","command_uuid":"cccccccc-0000-4000-8000-000000000001","state":"queued"}
    {"type":"command_lifecycle","command_uuid":"cccccccc-0000-4000-8000-000000000001","state":"started"}
    {"type":"command_lifecycle","command_uuid":"cccccccc-0000-4000-8000-000000000002","state":"queued"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting","user_message_uuids":["cccccccc-0000-4000-8000-000000000001"]}
    {"type":"stream_event","user_message_uuid":"cccccccc-0000-4000-8000-000000000001","user_message_uuids":["cccccccc-0000-4000-8000-000000000001"],"event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"one"}}}
    {"type":"assistant","user_message_uuid":"cccccccc-0000-4000-8000-000000000001","user_message_uuids":["cccccccc-0000-4000-8000-000000000001"],"message":{"content":[{"type":"text","text":"one"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"result","subtype":"success","user_message_uuid":"cccccccc-0000-4000-8000-000000000001","user_message_uuids":["cccccccc-0000-4000-8000-000000000001"],"is_error":false,"result":"one"}
    {"type":"command_lifecycle","command_uuid":"cccccccc-0000-4000-8000-000000000001","state":"completed"}
    {"type":"command_lifecycle","command_uuid":"cccccccc-0000-4000-8000-000000000002","state":"started"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting","user_message_uuids":["cccccccc-0000-4000-8000-000000000002"]}
    {"type":"stream_event","user_message_uuid":"cccccccc-0000-4000-8000-000000000002","user_message_uuids":["cccccccc-0000-4000-8000-000000000002"],"event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"two"}}}
    {"type":"assistant","user_message_uuid":"cccccccc-0000-4000-8000-000000000002","user_message_uuids":["cccccccc-0000-4000-8000-000000000002"],"message":{"content":[{"type":"text","text":"two"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","user_message_uuid":"cccccccc-0000-4000-8000-000000000002","user_message_uuids":["cccccccc-0000-4000-8000-000000000002"],"is_error":false,"result":"two"}
    {"type":"command_lifecycle","command_uuid":"cccccccc-0000-4000-8000-000000000002","state":"completed"}
    """#

    static let s1 = #"""
    >send S1-1
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"task_started","task_id":"a57c174413ad17401","task_type":"local_agent","is_backgrounded":true}
    {"type":"user"}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"assistant","parent_tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_01NLgsBJ9DMyxtTkphdRxbJJ"}]}}
    {"type":"system","subtype":"task_progress","task_id":"a57c174413ad17401"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"system","subtype":"thinking_tokens"}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta"}}}
    {"type":"system","subtype":"thinking_tokens"}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"thinking"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The s"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"leep probe sub"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"agent is running"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" in"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" the background,"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" so I don"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"'t have its output"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" yet. It was"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" launched as"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" a"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" general-purpose agent with"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" the"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" instruction to run `sle"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ep 20; echo hi"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"`"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" and report the result"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" ex"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"actly as"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" returned. I'll report what"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" it says"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" when"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" its completion not"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ification arrives."}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The sleep probe subagent is running in t"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"The sleep probe subagent is running in the background, so I don't have its output yet. It was launched as a general-purpose agent with the instruction to run `sleep 20; echo hi` and report the result exactly as returned. I'll report what it says when its completion notification arrives."}
    {"type":"system","subtype":"task_started","task_id":"bew97awf2","task_type":"local_bash","is_backgrounded":false}
    {"type":"system","subtype":"task_notification","status":"completed","task_id":"bew97awf2"}
    {"type":"user","parent_tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK"}
    {"type":"assistant","parent_tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","message":{"content":[{"type":"text","text":"The command returned:\n\n```\nhi\n```"}]}}
    {"type":"system","subtype":"task_updated","task_id":"a57c174413ad17401","patch":{"status":"completed"}}
    {"type":"system","subtype":"task_notification","status":"completed","task_id":"a57c174413ad17401"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The sleep probe re"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ported `"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi`. The sub"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"agent ran `sleep"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" 20; echo hi`"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" once"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" and"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" returned that"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" output."}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The sleep probe reported `hi`. The subag"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","origin":{"kind":"task-notification","producer":"session-task","runId":"0mvgqsf7a-a06fabb6"},"is_error":false,"result":"The sleep probe reported `hi`. The subagent ran `sleep 20; echo hi` once and returned that output."}
    >send S1-2
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"It"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" reported `hi`."}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"It reported `hi`."}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"It reported `hi`."}
    """#

    static let s3r = #"""
    >send S3r-1
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_0165CjdKDVYnyqwfjjSbKWTE"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"task_started","task_id":"b2xl9jxgm","task_type":"local_bash","is_backgrounded":true}
    {"type":"user"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"started"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"started"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"started"}
    {"type":"system","subtype":"task_updated","task_id":"b2xl9jxgm","patch":{"status":"completed"}}
    {"type":"system","subtype":"task_notification","status":"completed","task_id":"b2xl9jxgm"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The background command"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" finished with"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" exit code 0. Its"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" output was `"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"done`."}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The background command finished with exi"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","origin":{"kind":"task-notification","producer":"session-task","runId":"0mvgr1xfp-12a6293b"},"is_error":false,"result":"The background command finished with exit code 0. Its output was `done`."}
    >send S3r-2
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Yes, it finished with"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" exit code 0 and print"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ed \""}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"done\"."}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"Yes, it finished with exit code 0 and pr"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"result","subtype":"success","is_error":false,"result":"Yes, it finished with exit code 0 and printed \"done\"."}
    """#

    static let s9 = #"""
    >send S9-1
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_01Jj15HTgWjF9pAjhwDCKLLE"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"task_started","task_id":"b1gjn7uhu","task_type":"local_bash","is_backgrounded":true}
    {"type":"user"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"started"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"started"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"started"}
    {"type":"system","subtype":"task_updated","task_id":"b1gjn7uhu","patch":{"status":"completed"}}
    {"type":"system","subtype":"task_notification","status":"completed","task_id":"b1gjn7uhu"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    >send S9-2
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The background command"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" finished with"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" exit code 0."}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" Its output was `done`."}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The background command finished with exi"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","origin":{"kind":"task-notification","producer":"session-task","runId":"0mvgr1y1c-2a982f6d"},"is_error":false,"result":"The background command finished with exit code 0. Its output was `done`."}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"6"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"6"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"6"}
    """#

    static let s11 = #"""
    >send S11-1
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"user","isReplay":true}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_019MK2NZ99svDb3cyhuhD61P"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"task_started","task_id":"bedifh69o","task_type":"local_bash","is_backgrounded":true}
    {"type":"user"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"started"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"started"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"started"}
    {"type":"system","subtype":"task_updated","task_id":"bedifh69o","patch":{"status":"completed"}}
    {"type":"system","subtype":"task_notification","status":"completed","task_id":"bedifh69o"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    >send S11-2
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The background command"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" finished with"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" exit code 0. It was"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" the"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" `sleep 15; ech"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"o done` check"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" you asked for, so there"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"'s nothing else to do."}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The background command finished with exi"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","origin":{"kind":"task-notification","producer":"session-task","runId":"0mvgr5e7r-c9d9f623"},"is_error":false,"result":"The background command finished with exit code 0. It was the `sleep 15; echo done` check you asked for, so there's nothing else to do."}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"user","isReplay":true}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"6"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"6"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"6"}
    """#

    static let s6a = #"""
    >send S6a-1
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"system","subtype":"thinking_tokens"}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta"}}}
    {"type":"system","subtype":"thinking_tokens"}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"thinking"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","id":"toolu_01Krdao7deuMy7VFG9tZABSm"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"task_started","task_id":"ad89290d7c628b4e5","task_type":"local_agent","is_backgrounded":true}
    >interrupt probe-1
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"user"}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"system","subtype":"task_updated","task_id":"ad89290d7c628b4e5","patch":{"status":"killed"}}
    {"type":"system","subtype":"task_notification","status":"stopped","task_id":"ad89290d7c628b4e5"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"control_response","response":{"subtype":"success","request_id":"probe-1","response":{"still_queued":[]}}}
    {"type":"user","parent_tool_use_id":"toolu_01Krdao7deuMy7VFG9tZABSm"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"user"}
    {"type":"result","subtype":"error_during_execution","is_error":true}
    >send S6a-2
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"alive"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"alive"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"result","subtype":"success","is_error":false,"result":"alive"}
    """#

    static let s13 = #"""
    >send S13-1
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_01FpkDx9mJGDo2hmfjFJXvie"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"rate_limit_event"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"task_started","task_id":"bqcgu5eyg","task_type":"local_bash","is_backgrounded":true}
    {"type":"user"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","id":"toolu_012ke7WSRZm2xnMaXE8pBeHr"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    >interrupt probe-4
    {"type":"control_response","response":{"subtype":"success","request_id":"probe-4","response":{"still_queued":[]}}}
    {"type":"user"}
    {"type":"user"}
    {"type":"result","subtype":"error_during_execution","is_error":true}
    {"type":"system","subtype":"task_updated","task_id":"bqcgu5eyg","patch":{"status":"completed"}}
    {"type":"system","subtype":"task_notification","status":"completed","task_id":"bqcgu5eyg"}
    {"type":"system","subtype":"background_tasks_changed"}
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"system","subtype":"thinking_tokens"}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta"}}}
    {"type":"system","subtype":"thinking_tokens"}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"signature_delta"}}}
    {"type":"assistant","message":{"content":[{"type":"thinking"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"The"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" background step finished ("}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"`"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"sleep 19; echo"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" q`"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":", exit "}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"0). I stopped before step"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" 2: you"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" interrupted the foreground"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" `sleep 12; ech"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"o fg2`"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":", so I haven't run it"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":". I"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"'m not s"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ending \""}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"done\" because"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" step"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" 2 didn't complete"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":". Should I run the"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" foreground command"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" now,"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" or st"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"op here"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"?"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"The background step finished (`sleep 19;"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","origin":{"kind":"task-notification","producer":"session-task","runId":"0mvgr5cxx-f7894e7b"},"is_error":false,"result":"The background step finished (`sleep 19; echo q`, exit 0). I stopped before step 2: you interrupted the foreground `sleep 12; echo fg2`, so I haven't run it. I'm not sending \"done\" because step 2 didn't complete. Should I run the foreground command now, or stop here?"}
    >send S13-2
    {"type":"system","subtype":"init"}
    {"type":"system","subtype":"status","status":"requesting"}
    {"type":"stream_event","event":{"type":"message_start"}}
    {"type":"stream_event","event":{"type":"content_block_start"}}
    {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"alive"}}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"alive"}]}}
    {"type":"stream_event","event":{"type":"content_block_stop"}}
    {"type":"stream_event","event":{"type":"message_delta","delta":{}}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"alive"}
    """#

}
