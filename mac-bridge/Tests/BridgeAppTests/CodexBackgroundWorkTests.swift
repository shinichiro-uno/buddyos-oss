import XCTest
@testable import BridgeApp

/// Codex の子 thread（サブエージェント）とバックグラウンドの端末を、サブエージェントのカードの行にする
/// （CodexAppServerSession / CodexBackgroundWork。docs/BACKGROUND_WORK_2026-10-21.md §3.6）。
/// セッションの試験は、codex 0.162.1 の app-server を実際に動かして記録した通知の行（CodexProbe）を
/// handleLine にそのまま流す。プロセスは起こさない（send しない）ので、親のターンはどれも「自分が始めていないターン」になる。
final class CodexBackgroundWorkTests: XCTestCase {
    private func obj(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func rows(_ payload: String?) -> [[String: Any]] {
        guard let payload else { return [] }
        return (obj(payload)["agents"] as? [[String: Any]]) ?? []
    }

    /// 流れた workflow_progress の行を、届いた順に全部。
    private func progressRows(_ events: [SessionEvent]) -> [[String: Any]] {
        events.filter { $0.type == .workflowProgress }.flatMap { rows($0.content) }
    }

    /// id の行の、最後に届いた形。
    private func last(_ id: String, in events: [SessionEvent]) -> [String: Any]? {
        progressRows(events).last { $0["id"] as? String == id }
    }

    /// id の行の state の移り変わり。
    private func states(_ id: String, in events: [SessionEvent]) -> [String] {
        progressRows(events).filter { $0["id"] as? String == id }.compactMap { $0["state"] as? String }
    }

    /// stdio（共有サーバーなし）のセッション。
    private func session(_ threadId: String) -> CodexAppServerSession {
        CodexAppServerSession(agentId: "codex", initialSessionId: threadId, cwd: nil, executable: "/usr/bin/false")
    }

    /// close して stream を閉じ、それまでに流れたイベントを全部回収する。
    private func drain(_ session: CodexAppServerSession) async -> [SessionEvent] {
        await session.close()
        var out: [SessionEvent] = []
        do {
            for try await event in session.events { out.append(event) }
        } catch {}
        return out
    }

    // MARK: - 記録した通知（セッション）

    /// cx-run3: v2 の spawn。親のターンは子を待たずに終わり、子は後から完了する。行は model・reasoningEffort 付きで始まり、
    /// 子の turn/completed で done（結果は子の最後の発言）。後から親に届く subAgentActivity completed では変わらない。
    /// stdio の app-server は、子が動いている間は止めず、子が終わったら止める。
    func testSpawnV2RowOutlivesParentTurnAndClosesWithResult() async throws {
        let s = session(CodexProbe.spawnV2Parent)
        let parentDone = 14
        for line in CodexProbe.spawnV2[...parentDone] { s.handleLine(line) }
        XCTAssertTrue(s.isAppServerStopDeferred, "子が動いている間は stdio の app-server を止めない")
        let mid = await s.subagentSnapshot()
        let midSnapshot = try obj(XCTUnwrap(mid))
        XCTAssertEqual(midSnapshot["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(rows(mid).count, 1)
        XCTAssertEqual(rows(mid).first?["state"] as? String, "running")

        for line in CodexProbe.spawnV2[(parentDone + 1)...] { s.handleLine(line) }
        XCTAssertFalse(s.isAppServerStopDeferred, "子が終わったら止める")
        let events = await drain(s)
        let child = CodexProbe.spawnV2Child
        let first = try XCTUnwrap(progressRows(events).first { $0["id"] as? String == child })
        XCTAssertEqual(first["state"] as? String, "running")
        XCTAssertEqual(first["model"] as? String, "gpt-6-luna (medium)")
        let row = try XCTUnwrap(last(child, in: events))
        XCTAssertEqual(row["state"] as? String, "done")
        XCTAssertEqual(row["result"] as? String, "child done")
        XCTAssertEqual(row["resultPreview"] as? String, "child done")
        XCTAssertEqual(row["agentType"] as? String, "probe_child")
        XCTAssertEqual(row["label"] as? String, "probe_child")
        XCTAssertEqual(row["labelIsFallback"] as? Bool, true)
        XCTAssertEqual(row["model"] as? String, "gpt-6-luna (medium)")
        XCTAssertEqual(row["rowKind"] as? String, "agent")
        XCTAssertEqual(row["tokens"] as? Int, 30)
        XCTAssertNotNil(row["endedAtMs"] as? Int)
        XCTAssertFalse(states(child, in: events).contains("failed"))
        // 親のターンには発話があった（ほかの画面のターン）ので、知らせのターンではない。
        let dones = events.filter { $0.type == .done }
        XCTAssertEqual(dones.count, 1)
        XCTAssertNil(dones.first?.metadata?["origin"])
    }

    /// cx-run6: 子が失敗する（systemError → error → turn/completed failed）。行は failed で、error の文が結果になる。
    func testFailedChildKeepsTheErrorAsResult() async throws {
        let s = session(CodexProbe.failedChildParent)
        CodexProbe.failedChild.forEach(s.handleLine)
        let events = await drain(s)
        let child = CodexProbe.failedChildThread
        let row = try XCTUnwrap(last(child, in: events))
        let message = "Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying."
        XCTAssertEqual(row["state"] as? String, "failed")
        XCTAssertEqual(row["result"] as? String, message)
        XCTAssertEqual(row["resultPreview"] as? String, message)
        XCTAssertFalse(states(child, in: events).contains("done"))
        // 子の失敗はセッションのエラーにしない（親のターンは成功している）。
        XCTAssertTrue(events.filter { $0.type == .error }.isEmpty)
    }

    /// cx-run7: 親が interrupt_agent で子を止める。subAgentActivity interrupted で stopped になり、後から届く子の
    /// turn/completed(interrupted) で done に変わらない。
    func testInterruptedChildIsStoppedNotDone() async throws {
        let s = session(CodexProbe.interruptedChildParent)
        CodexProbe.interruptedChild.forEach(s.handleLine)
        let events = await drain(s)
        let child = CodexProbe.interruptedChildThread
        XCTAssertEqual(states(child, in: events).last, "stopped")
        XCTAssertFalse(states(child, in: events).contains("done"))
        XCTAssertFalse(states(child, in: events).contains("failed"))
        XCTAssertEqual(last(child, in: events)?["result"] as? String, "", "結果の無い終わった行は空で送る")
    }

    /// cx-run5: メインのターンで起こした unified exec の端末が、ターンより長く動く。親の turn/completed で shell の行
    /// （tool "exec"、command は commandActions[0].command、background）になり、done より先に流れる。
    /// 後から届く item/completed の exitCode 0 で done（結果は出力の終わり）。それまで stdio の app-server は止めない。
    func testBackgroundTerminalBecomesShellRowUntilItExits() async throws {
        let s = session(CodexProbe.backgroundTerminalParent)
        let parentDone = 10
        for line in CodexProbe.backgroundTerminal[...parentDone] { s.handleLine(line) }
        XCTAssertTrue(s.isAppServerStopDeferred, "裏の端末が動いている間は stdio の app-server を止めない")
        for line in CodexProbe.backgroundTerminal[(parentDone + 1)...] { s.handleLine(line) }
        XCTAssertFalse(s.isAppServerStopDeferred)
        let events = await drain(s)
        let exec = CodexProbe.backgroundTerminalItem
        let shellRows = progressRows(events).filter { $0["id"] as? String == exec }
        let first = try XCTUnwrap(shellRows.first)
        XCTAssertEqual(first["rowKind"] as? String, "shell")
        XCTAssertEqual(first["tool"] as? String, "exec")
        XCTAssertEqual(first["command"] as? String, "sleep 6; echo bg-done")
        XCTAssertEqual(first["label"] as? String, "sleep 6; echo bg-done")
        XCTAssertEqual(first["background"] as? Bool, true)
        XCTAssertEqual(first["state"] as? String, "running")
        // 行にするのは親のターンの終わりでも、開始時刻は端末の item/started の startedAtMs。
        XCTAssertEqual(first["startedAtMs"] as? Int, 1792507417938)
        let rowIndex = try XCTUnwrap(events.firstIndex(where: { event in
            event.type == .workflowProgress && rows(event.content).contains { $0["id"] as? String == exec }
        }))
        let doneIndex = try XCTUnwrap(events.firstIndex(where: { $0.type == .done }))
        XCTAssertLessThan(rowIndex, doneIndex, "shell の行は親のターンの done より先に流れる")
        let row = try XCTUnwrap(shellRows.last)
        XCTAssertEqual(row["state"] as? String, "done")
        XCTAssertEqual(row["result"] as? String, "bg-done")
        // 所要時間は item/completed の durationMs（計算した値ではない）。
        XCTAssertEqual(row["durationMs"] as? Int, 5873)
        XCTAssertEqual(row["startedAtMs"] as? Int, 1792507417938)
        // ツール行の終わりも今までどおり流れる。
        XCTAssertTrue(events.contains { $0.type == .toolEnd && $0.toolUseId == exec && $0.metadata?["status"] == "completed" })
    }

    /// 自分の thread で、自分が始めておらず発話も無いターン（子の完了などで親が自分から起きた）は、知らせのターンとして
    /// 本文と done（metadata.origin = "task-notification"）を流す。差し込まれた <subagent_notification> は発話に数えない。
    func testParentTurnWithoutUtteranceIsNotificationTurn() async throws {
        let s = session("thread-P")
        let lines = [
            #"{"method":"turn/started","params":{"threadId":"thread-P","turn":{"id":"turn-N","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"item/started","params":{"threadId":"thread-P","turnId":"turn-N","item":{"type":"userMessage","id":"u1","clientId":null,"content":[{"type":"text","text":"<subagent_notification>{\"agent_path\":\"/root/worker\",\"status\":\"completed\"}</subagent_notification>","text_elements":[]}]}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"threadId":"thread-P","turnId":"turn-N","itemId":"msg_N","delta":"子の報告です"}}"#,
            #"{"method":"item/completed","params":{"threadId":"thread-P","turnId":"turn-N","item":{"type":"agentMessage","id":"msg_N","text":"子の報告です"}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"thread-P","turn":{"id":"turn-N","items":[],"status":"completed","error":null}}}"#,
        ]
        lines.forEach(s.handleLine)
        let events = await drain(s)
        XCTAssertEqual(events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined(), "子の報告です")
        XCTAssertTrue(events.filter { $0.type == .userMessage }.isEmpty, "差し込まれた知らせは発話として出さない")
        let done = try XCTUnwrap(events.first { $0.type == .done })
        XCTAssertEqual(done.metadata?["origin"], "task-notification")
        XCTAssertEqual(done.messageId, "msg_N")
    }

    /// ターミナルの発話が画像だけ（本文は画像の囲みだけ）でも発話として数え、知らせのターンにしない。
    func testImageOnlyTerminalUtteranceIsNotNotificationTurn() async throws {
        let s = session("thread-P")
        let lines = [
            #"{"method":"turn/started","params":{"threadId":"thread-P","turn":{"id":"turn-I","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"item/started","params":{"threadId":"thread-P","turnId":"turn-I","item":{"type":"userMessage","id":"u2","clientId":null,"content":[{"type":"text","text":"<image name=[Image #1] path=\"/tmp/a.png\">\n</image>","text_elements":[]}]}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"thread-P","turn":{"id":"turn-I","items":[],"status":"completed","error":null}}}"#,
        ]
        lines.forEach(s.handleLine)
        let events = await drain(s)
        let done = try XCTUnwrap(events.first { $0.type == .done })
        XCTAssertNil(done.metadata?["origin"])
        XCTAssertTrue(events.filter { $0.type == .userMessage }.isEmpty)
    }

    /// close は実行中の行を stopped で閉じる。スナップショットは全行の置き換え（epoch 付き）。
    func testCloseStopsRunningRowsAndSnapshotReplacesAll() async throws {
        let s = session(CodexProbe.spawnV2Parent)
        for line in CodexProbe.spawnV2[...9] { s.handleLine(line) }   // 子の turn/started まで
        let snapshot = await s.subagentSnapshot()
        let snap = try obj(XCTUnwrap(snapshot))
        XCTAssertEqual(snap["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(snap["kind"] as? String, "subagents")
        XCTAssertEqual(snap["taskId"] as? String, "subagents")
        let epoch = try XCTUnwrap(snap["epoch"] as? String)
        XCTAssertFalse(epoch.isEmpty)
        XCTAssertEqual(rows(snapshot).first?["state"] as? String, "running")
        let events = await drain(s)
        XCTAssertEqual(last(CodexProbe.spawnV2Child, in: events)?["state"] as? String, "stopped")
        let progress = try XCTUnwrap(events.first { $0.type == .workflowProgress }?.content)
        XCTAssertEqual(obj(progress)["epoch"] as? String, epoch, "行の payload とスナップショットは同じ世代")
        let after = await s.subagentSnapshot()
        XCTAssertEqual(rows(after).first?["state"] as? String, "stopped")
    }

    /// 行が無くてもトラッカーがあれば agents: [] のスナップショットを返す（アプリが持っている幽霊行を消せるように）。
    func testSnapshotWithoutRowsIsEmptyReplaceAll() async throws {
        let s = session("thread-empty")
        let snapshot = await s.subagentSnapshot()
        let snap = try obj(XCTUnwrap(snapshot))
        XCTAssertEqual(snap["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual((snap["agents"] as? [[String: Any]])?.count, 0)
        await s.close()
    }

    /// 共有サーバーの再起動の判定は、共有サーバーに繋いだセッションの動いている行だけを数える。
    func testSharedBackgroundWorkCountsOnlySharedSessions() async throws {
        let before = CodexAppServerSession.sharedBackgroundWork()
        let endpoint = CodexSharedEndpoint(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9")), token: "test")
        let shared = CodexAppServerSession(agentId: "codex", initialSessionId: CodexProbe.spawnV2Parent, cwd: nil,
                                           executable: "/usr/bin/false", shared: endpoint)
        for line in CodexProbe.spawnV2[...14] { shared.handleLine(line) }
        let local = session(CodexProbe.backgroundTerminalParent)
        for line in CodexProbe.backgroundTerminal[...10] { local.handleLine(line) }
        let during = CodexAppServerSession.sharedBackgroundWork()
        XCTAssertEqual(during.agents - before.agents, 1, "共有サーバーの上の子 thread")
        XCTAssertEqual(during.shells - before.shells, 0, "stdio のセッションの裏の端末は数えない")
        await shared.close()
        await local.close()
        let after = CodexAppServerSession.sharedBackgroundWork()
        XCTAssertEqual(after.agents, before.agents)
        XCTAssertEqual(after.shells, before.shells)
    }

    // MARK: - CodexBackgroundWork

    private let startedC1 = #"{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"high","id":"call_1","kind":"started","agentThreadId":"C1","agentPath":"/root/worker"}"#
    private let interactedC1 = #"{"type":"subAgentActivity","model":null,"reasoningEffort":null,"id":"call_2","kind":"interacted","agentThreadId":"C1","agentPath":"/root/worker"}"#
    private let execStarted = #"{"type":"commandExecution","id":"exec-1","command":"/bin/zsh -lc 'npm run dev'","processId":"77","source":"unifiedExecStartup","status":"inProgress","commandActions":[{"type":"unknown","command":"npm run dev"}],"aggregatedOutput":null,"exitCode":null,"durationMs":null}"#

    /// interacted（send_message・followup_task）は作業の文だけ変え、終わった行を実行中に戻さない。
    /// 戻すのは子の turn/started（followup_task で子のターンが起きたとき）。
    func testInteractedOnlyUpdatesActivityAndNeverReopens() {
        var w = CodexBackgroundWork()
        XCTAssertEqual(rows(w.ownItemStarted(obj(startedC1)).last).first?["state"] as? String, "running")
        let running = rows(w.ownItemCompleted(obj(interactedC1)).last).first
        XCTAssertEqual(running?["state"] as? String, "running")
        XCTAssertEqual(running?["resultPreview"] as? String, CodexBackgroundWork.interactedActivity)

        _ = w.childNotification(method: "turn/completed", params: obj(#"{"threadId":"C1","turn":{"id":"t1","items":[{"type":"agentMessage","id":"m","text":"finished"}],"status":"completed","error":null}}"#), threadId: "C1")
        XCTAssertTrue(w.ownItemCompleted(obj(interactedC1)).isEmpty, "send_message では子のターンは起きない")
        let done = rows(w.tracker.snapshot()).first
        XCTAssertEqual(done?["state"] as? String, "done")
        XCTAssertEqual(done?["result"] as? String, "finished")

        let reopened = w.childNotification(method: "turn/started", params: obj(#"{"threadId":"C1","turn":{"id":"t2","status":"inProgress"}}"#), threadId: "C1")
        XCTAssertEqual(rows(reopened.last).first?["state"] as? String, "running")
    }

    /// 終わって行を忘れた子（新しいターンの pruneFinished の後）が、後のターンで話しかけ直された（followup_task）。
    /// 子の通知を捨てず（isChildThread）、子の turn/started で行を作り直す（種類とモデルは覚えておいたもの）。
    /// interacted（send_message は子を起こさない）では行を作らない。
    func testPrunedChildIsTrackedAgainWhenResumed() {
        var w = CodexBackgroundWork()
        _ = w.ownItemStarted(obj(startedC1))
        _ = w.childNotification(method: "turn/completed", params: obj(#"{"threadId":"C1","turn":{"id":"t1","items":[{"type":"agentMessage","id":"m","text":"first run"}],"status":"completed","error":null}}"#), threadId: "C1")
        w.pruneFinished()
        XCTAssertTrue(w.tracker.isEmpty)
        XCTAssertTrue(w.isChildThread("C1"), "終わって忘れた子の通知を捨てる")
        XCTAssertFalse(w.isChildThread("C9"))
        XCTAssertTrue(w.ownItemCompleted(obj(interactedC1)).isEmpty, "interacted では行を作らない")
        XCTAssertTrue(w.childNotification(method: "item/started", params: [:], threadId: "C1").isEmpty)

        let resumed = rows(w.childNotification(method: "turn/started", params: obj(#"{"threadId":"C1","turn":{"id":"t2","status":"inProgress"}}"#), threadId: "C1").last).first
        XCTAssertEqual(resumed?["state"] as? String, "running")
        XCTAssertEqual(resumed?["agentType"] as? String, "worker")
        XCTAssertEqual(resumed?["model"] as? String, "gpt-6-luna (high)")
        XCTAssertTrue(w.tracker.hasRunning)
        let done = rows(w.childNotification(method: "turn/completed", params: obj(#"{"threadId":"C1","turn":{"id":"t2","items":[{"type":"agentMessage","id":"m2","text":"second run"}],"status":"completed","error":null}}"#), threadId: "C1").last).first
        XCTAssertEqual(done?["state"] as? String, "done")
        XCTAssertEqual(done?["result"] as? String, "second run")
    }

    /// セッションでも同じ: 後のターン（ほかの画面の発話で始まり、終わった行を捨てた）で followup_task された子は、
    /// 子の turn/started でカードに戻り、stdio の app-server は親の turn/completed で止めない（止めると子が道連れになる）。
    func testResumedChildAfterPruneKeepsStdioAppServer() async throws {
        let s = session("thread-P")
        let lines = [
            #"{"method":"turn/started","params":{"threadId":"thread-P","turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"item/started","params":{"threadId":"thread-P","turnId":"turn-1","item":{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"high","id":"call_1","kind":"started","agentThreadId":"C1","agentPath":"/root/worker"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"C1","turn":{"id":"tc1","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"C1","turn":{"id":"tc1","items":[{"type":"agentMessage","id":"m1","text":"first run"}],"status":"completed","error":null}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"thread-P","turn":{"id":"turn-1","items":[],"status":"completed","error":null}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-P","turn":{"id":"turn-2","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"item/started","params":{"threadId":"thread-P","turnId":"turn-2","item":{"type":"userMessage","id":"u2","clientId":null,"content":[{"type":"text","text":"続きを頼んで","text_elements":[]}]}}}"#,
            #"{"method":"item/started","params":{"threadId":"thread-P","turnId":"turn-2","item":{"type":"subAgentActivity","model":null,"reasoningEffort":null,"id":"call_2","kind":"interacted","agentThreadId":"C1","agentPath":"/root/worker"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"C1","turn":{"id":"tc2","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"thread-P","turn":{"id":"turn-2","items":[],"status":"completed","error":null}}}"#,
        ]
        lines.forEach(s.handleLine)
        XCTAssertTrue(s.isAppServerStopDeferred, "話しかけ直された子が動いているのに、stdio の app-server を止めた")
        let snapshot = await s.subagentSnapshot()
        XCTAssertEqual(rows(snapshot).map { $0["state"] as? String }, ["running"])
        let events = await drain(s)
        let seen = states("C1", in: events)
        let firstDone = try XCTUnwrap(seen.firstIndex(of: "done"))
        XCTAssertEqual(seen.dropFirst(firstDone + 1).first, "running", "話しかけ直された子をカードに戻していない: \(seen)")
        XCTAssertEqual(last("C1", in: events)?["agentType"] as? String, "worker")
    }

    /// 共有 app-server（Mac の既定）では、自分の thread が spawn した子 thread の承認の要求もカードにして答えられるようにする
    /// （子は親の承認の設定を受け継ぐ。答えないと止まったままで、行が「実行中」のまま残る。Windows と同じ）。
    /// 子の要求が片付いた知らせ（serverRequest/resolved）でカードを閉じる。ほかの thread の要求は出さない。
    func testSharedSessionShowsChildThreadApprovalRequests() async throws {
        let endpoint = CodexSharedEndpoint(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:9")), token: "test")
        let s = CodexAppServerSession(agentId: "codex", initialSessionId: "thread-P", cwd: nil,
                                      executable: "/usr/bin/false", shared: endpoint)
        let lines = [
            #"{"method":"turn/started","params":{"threadId":"thread-P","turn":{"id":"turn-1","items":[],"status":"inProgress","error":null}}}"#,
            #"{"method":"item/started","params":{"threadId":"thread-P","turnId":"turn-1","item":{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"high","id":"call_1","kind":"started","agentThreadId":"C1","agentPath":"/root/worker"}}}"#,
            #"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"C1","turnId":"tc1","itemId":"x1","command":"curl https://example.com","reason":"network access","cwd":"/tmp/w"}}"#,
            #"{"id":8,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-other","turnId":"tz","itemId":"x2","command":"ls","cwd":"/tmp/w"}}"#,
            #"{"method":"serverRequest/resolved","params":{"threadId":"C1","requestId":7}}"#,
        ]
        lines.forEach(s.handleLine)
        let events = await drain(s)
        let requests = events.filter { $0.type == .actionRequest }
        XCTAssertEqual(requests.map(\.messageId), ["7"], "子 thread の承認を出していない（か、ほかの thread の要求を出した）")
        XCTAssertEqual(requests.first?.metadata?["kind"], "commandApproval")
        XCTAssertTrue(events.contains { $0.type == .actionResolved && $0.messageId == "7" }, "片付いた子の要求のカードを閉じていない")
    }

    /// stdio: 延ばしていた app-server の停止は、途中の send()（ensureThread を済ませ、turn/start を書く前）の間はしない
    /// （止めると turn/start が初期化していない新しいプロセスへ行き、送信が失敗する）。送り終えたら止める。
    func testDeferredStopWaitsForSendInFlight() async throws {
        let s = session(CodexProbe.spawnV2Parent)
        let parentDone = 14
        for line in CodexProbe.spawnV2[...parentDone] { s.handleLine(line) }
        XCTAssertTrue(s.isAppServerStopDeferred)
        s.noteSendStarted()
        for line in CodexProbe.spawnV2[(parentDone + 1)...] { s.handleLine(line) }
        XCTAssertTrue(s.isAppServerStopDeferred, "送っている途中で app-server を止めた")
        s.noteSendFinished()
        XCTAssertFalse(s.isAppServerStopDeferred, "送り終えたのに止めていない")
        await s.close()
    }

    /// 後から届く subAgentActivity completed と子の turn/completed(completed) は、failed / stopped の行を上書きしない。
    func testCompletedDoesNotOverrideFailedOrStopped() {
        var w = CodexBackgroundWork()
        _ = w.ownItemStarted(obj(#"{"type":"subAgentActivity","id":"s1","kind":"started","agentThreadId":"C1","agentPath":"/root/a"}"#))
        _ = w.ownItemStarted(obj(#"{"type":"subAgentActivity","id":"s2","kind":"started","agentThreadId":"C2","agentPath":"/root/b"}"#))
        _ = w.childNotification(method: "thread/status/changed", params: obj(#"{"threadId":"C1","status":{"type":"systemError"}}"#), threadId: "C1")
        _ = w.ownItemCompleted(obj(#"{"type":"subAgentActivity","id":"i2","kind":"interrupted","agentThreadId":"C2","agentPath":"/root/b"}"#))
        XCTAssertTrue(w.ownItemCompleted(obj(#"{"type":"subAgentActivity","id":"c1","kind":"completed","agentThreadId":"C1","agentPath":"/root/a"}"#)).isEmpty)
        XCTAssertTrue(w.ownItemCompleted(obj(#"{"type":"subAgentActivity","id":"c2","kind":"completed","agentThreadId":"C2","agentPath":"/root/b"}"#)).isEmpty)
        XCTAssertTrue(w.childNotification(method: "turn/completed", params: obj(#"{"threadId":"C2","turn":{"id":"t","items":[],"status":"completed","error":null}}"#), threadId: "C2").isEmpty)
        let byId = Dictionary(uniqueKeysWithValues: rows(w.tracker.snapshot()).map { ($0["id"] as? String ?? "", $0) })
        XCTAssertEqual(byId["C1"]?["state"] as? String, "failed")
        XCTAssertEqual(byId["C2"]?["state"] as? String, "stopped")
    }

    /// v1（collabAgentToolCall）の agentsStates: completed / shutdown → done、interrupted → stopped、errored → failed。
    func testV1CollabStatesMapToDoneStoppedFailed() {
        var w = CodexBackgroundWork()
        let spawn = obj(#"{"type":"collabAgentToolCall","id":"call_s","tool":"spawnAgent","status":"completed","receiverThreadIds":["C1","C2","C3"],"prompt":"audit auth","model":"gpt-5.6-luna","agentsStates":{}}"#)
        XCTAssertEqual(w.ownItemCompleted(spawn).count, 3)
        let wait = obj(#"{"type":"collabAgentToolCall","id":"call_w","tool":"wait","status":"completed","receiverThreadIds":[],"agentsStates":{"C1":{"status":"completed","message":"ok"},"C2":{"status":"interrupted","message":null},"C3":{"status":"errored","message":"boom"}}}"#)
        _ = w.ownItemCompleted(wait)
        let byId = Dictionary(uniqueKeysWithValues: rows(w.tracker.snapshot()).map { ($0["id"] as? String ?? "", $0) })
        XCTAssertEqual(byId["C1"]?["state"] as? String, "done")
        XCTAssertEqual(byId["C1"]?["result"] as? String, "ok")
        XCTAssertEqual(byId["C1"]?["label"] as? String, "audit auth")
        XCTAssertEqual(byId["C1"]?["model"] as? String, "gpt-5.6-luna")
        XCTAssertEqual(byId["C2"]?["state"] as? String, "stopped")
        XCTAssertEqual(byId["C3"]?["state"] as? String, "failed")
        XCTAssertEqual(byId["C3"]?["result"] as? String, "boom")
    }

    /// 子の error（willRetry=true）は再接続中なので失敗にせず、いまの作業として見せる。
    func testChildRetryIsActivityNotFailure() {
        var w = CodexBackgroundWork()
        _ = w.ownItemStarted(obj(startedC1))
        let retry = rows(w.childNotification(method: "error", params: obj(#"{"error":{"message":"Reconnecting... 1/5","codexErrorInfo":null},"willRetry":true,"threadId":"C1","turnId":"t"}"#), threadId: "C1").last).first
        XCTAssertEqual(retry?["state"] as? String, "running")
        XCTAssertEqual(retry?["resultPreview"] as? String, "Reconnecting... 1/5")
        XCTAssertTrue(w.childNotification(method: "turn/started", params: [:], threadId: "unknown").isEmpty, "知らない thread は捨てる")
    }

    /// ターンの中で閉じた端末と、processId の無いコマンドは行にしない。
    func testExecThatClosesWithinTheTurnIsNotARow() {
        var w = CodexBackgroundWork()
        XCTAssertTrue(w.ownItemStarted(obj(execStarted)).isEmpty)
        XCTAssertTrue(w.ownItemCompleted(obj(#"{"type":"commandExecution","id":"exec-1","processId":"77","status":"completed","commandActions":[],"aggregatedOutput":"ok\n","exitCode":0}"#)).isEmpty)
        XCTAssertTrue(w.ownTurnCompleted().isEmpty)
        _ = w.ownItemStarted(obj(#"{"type":"commandExecution","id":"exec-2","command":"sleep 1","processId":null,"source":"agent","status":"inProgress","commandActions":[]}"#))
        XCTAssertTrue(w.ownTurnCompleted().isEmpty)
        XCTAssertTrue(w.tracker.isEmpty)
    }

    /// 裏の端末が 0 以外で終わったら failed（結果は出力の終わり）。行は 1 度だけ作る。
    func testBackgroundTerminalNonZeroExitIsFailed() {
        var w = CodexBackgroundWork()
        _ = w.ownItemStarted(obj(execStarted))
        XCTAssertEqual(w.ownTurnCompleted().count, 1)
        XCTAssertTrue(w.ownTurnCompleted().isEmpty, "次のターンの終わりで作り直さない")
        XCTAssertEqual(w.tracker.runningShellCount, 1)
        let closed = rows(w.ownItemCompleted(obj(#"{"type":"commandExecution","id":"exec-1","processId":"77","status":"failed","commandActions":[{"type":"unknown","command":"npm run dev"}],"aggregatedOutput":"Error: port 3000 is in use\n","exitCode":1}"#)).last).first
        XCTAssertEqual(closed?["state"] as? String, "failed")
        XCTAssertEqual(closed?["result"] as? String, "Error: port 3000 is in use")
        XCTAssertEqual(closed?["command"] as? String, "npm run dev")
    }

    /// 異常終了は動いている行（サブエージェントもシェルも）を failed で閉じる。閉じた後は何もしない。
    func testAbandonRunningClosesAgentsAndShells() {
        var w = CodexBackgroundWork()
        _ = w.ownItemStarted(obj(startedC1))
        _ = w.ownItemStarted(obj(execStarted))
        _ = w.ownTurnCompleted()
        XCTAssertEqual(w.tracker.runningAgentCount, 1)
        XCTAssertEqual(w.tracker.runningShellCount, 1)
        let closed = rows(w.abandonRunning(state: "failed"))
        XCTAssertEqual(closed.count, 2)
        XCTAssertTrue(closed.allSatisfy { $0["state"] as? String == "failed" })
        XCTAssertFalse(w.tracker.hasRunning)
        XCTAssertNil(w.abandonRunning(state: "stopped"))
    }

    func testHelpers() throws {
        XCTAssertEqual(CodexBackgroundWork.modelLabel(model: "gpt-6-luna", effort: "medium"), "gpt-6-luna (medium)")
        XCTAssertEqual(CodexBackgroundWork.modelLabel(model: "gpt-6-luna", effort: nil), "gpt-6-luna")
        XCTAssertNil(CodexBackgroundWork.modelLabel(model: nil, effort: "high"))
        XCTAssertEqual(CodexBackgroundWork.execCommand(obj(execStarted)), "npm run dev")
        XCTAssertEqual(CodexBackgroundWork.execCommand(obj(#"{"command":"/bin/zsh -lc ls","commandActions":[]}"#)), "/bin/zsh -lc ls")
        XCTAssertEqual(CodexBackgroundWork.execState(obj(#"{"status":"completed","exitCode":0}"#)), "done")
        XCTAssertEqual(CodexBackgroundWork.execState(obj(#"{"status":"failed","exitCode":143}"#)), "failed")
        XCTAssertEqual(CodexBackgroundWork.execState(obj(#"{"status":"declined","exitCode":null}"#)), "failed")
        XCTAssertEqual(CodexBackgroundWork.execState(obj(#"{"status":"completed","exitCode":null}"#)), "done")
        let long = (1...600).map { "line \($0)" }.joined(separator: "\n")
        let tail = try XCTUnwrap(CodexBackgroundWork.outputTail(long))
        XCTAssertTrue(tail.hasPrefix("…"))
        XCTAssertTrue(tail.hasSuffix("line 600"))
        XCTAssertLessThanOrEqual(tail.count, 2000)
        XCTAssertNil(CodexBackgroundWork.outputTail("  \n"))
    }

    /// サブエージェントの完了の知らせ（<subagent_notification>）は、ユーザーの発話として出さない（履歴・ターミナルのターン）。
    func testSubagentNotificationIsInjectedContext() {
        XCTAssertTrue(CodexInjectedContext.isInjected("<subagent_notification>\n{\"agent_path\":\"/root/a\",\"status\":\"completed\"}\n</subagent_notification>"))
        XCTAssertFalse(CodexInjectedContext.isInjected("subagent_notification とは何？"))
    }
}

/// codex 0.162.1 の app-server（stdio。CODEX_HOME を隔離し、モデルは 127.0.0.1 のモック）で記録した通知。
/// probe の wire.jsonl から account/rateLimits/updated と親の thread/started を除き、cwd を "/tmp/w" に縮めた。
private enum CodexProbe {
    /// cx-run3: v2 の spawn。親は子を待たずに終わり（14）、子は 3 秒 sleep して 'child done'（22）、
    /// 親に subAgentActivity completed（23・24。turnId は終わった親のターン）。
    static let spawnV2Parent = "01a159c1-17f0-7a03-b8bc-468dec521b66"
    static let spawnV2Child = "01a159c1-18e7-75e2-b3f7-07bff18af412"
    /// cx-run5: メインのターンで unified exec の端末を起こし、閉じる前にターンが終わる（10）。5 秒後に exitCode 0（12）。
    static let backgroundTerminalParent = "01a159c4-9345-7d91-948e-aedd17cccfa0"
    static let backgroundTerminalItem = "exec-170d2c38-fc2a-457f-a102-478c88c4b5de"
    /// cx-run6: 子が contextWindowExceeded で失敗（systemError → error → turn/completed failed）。親には何も来ない。
    static let failedChildParent = "01a159c5-43ed-7501-b28f-2a40ebc72360"
    static let failedChildThread = "01a159c5-44e3-7e62-9923-d5b2e7abb41b"
    /// cx-run7: 親が interrupt_agent で子を止める（subAgentActivity interrupted → 子の turn/completed interrupted）。
    static let interruptedChildParent = "01a159c5-845d-7413-9bd6-4ec50887b9ab"
    static let interruptedChildThread = "01a159c5-8541-7673-b8b7-0620fc133902"

    static let spawnV2: [String] = [
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","status":{"type":"active","activeFlags":[]}},"emittedAtMs":1792507189253}"#,
        #"{"method":"turn/started","params":{"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turn":{"id":"01a159c1-1800-7383-a57b-c0adc1a48562","rootTurnId":"01a159c1-1800-7383-a57b-c0adc1a48562","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":1792507189,"completedAt":null,"durationMs":null}},"emittedAtMs":1792507189253}"#,
        #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"01a159c1-1806-78d0-bcff-37fc5075b438","clientId":null,"content":[{"type":"text","text":"PARENT_PROBE_PROMPT: spawn one sub-agent","text_elements":[]}]},"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","startedAtMs":1792507189254},"emittedAtMs":1792507189254}"#,
        #"{"method":"item/completed","params":{"item":{"type":"userMessage","id":"01a159c1-1806-78d0-bcff-37fc5075b438","clientId":null,"content":[{"type":"text","text":"PARENT_PROBE_PROMPT: spawn one sub-agent","text_elements":[]}]},"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","completedAtMs":1792507189254},"emittedAtMs":1792507189254}"#,
        #"{"method":"item/started","params":{"item":{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"medium","id":"call_spawn_1","kind":"started","agentThreadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","agentPath":"/root/probe_child"},"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","startedAtMs":1792507189482},"emittedAtMs":1792507189484}"#,
        #"{"method":"item/completed","params":{"item":{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"medium","id":"call_spawn_1","kind":"started","agentThreadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","agentPath":"/root/probe_child"},"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","completedAtMs":1792507189483},"emittedAtMs":1792507189484}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","status":{"type":"idle"}},"emittedAtMs":1792507189484}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","tokenUsage":{"total":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507189484}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","status":{"type":"active","activeFlags":[]}},"emittedAtMs":1792507189487}"#,
        #"{"method":"turn/started","params":{"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","turn":{"id":"01a159c1-18ea-7243-96ef-15a4a6c6880d","rootTurnId":"01a159c1-1800-7383-a57b-c0adc1a48562","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":1792507189,"completedAt":null,"durationMs":null}},"emittedAtMs":1792507189487}"#,
        #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_3","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","startedAtMs":1792507189703},"emittedAtMs":1792507189703}"#,
        #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_3","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","completedAtMs":1792507189703},"emittedAtMs":1792507189703}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","tokenUsage":{"total":{"totalTokens":30,"inputTokens":20,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":10,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507189703}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","status":{"type":"idle"}},"emittedAtMs":1792507189703}"#,
        #"{"method":"turn/completed","params":{"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turn":{"id":"01a159c1-1800-7383-a57b-c0adc1a48562","rootTurnId":"01a159c1-1800-7383-a57b-c0adc1a48562","items":[{"type":"agentMessage","id":"msg_3","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null}],"itemsView":"summary","status":"completed","error":null,"startedAt":1792507189,"completedAt":1792507189,"durationMs":452}},"emittedAtMs":1792507189703}"#,
        #"{"method":"item/started","params":{"item":{"type":"sleep","id":"call_sleep_child_1","durationMs":3000},"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","turnId":"01a159c1-18ea-7243-96ef-15a4a6c6880d","startedAtMs":1792507189704},"emittedAtMs":1792507189704}"#,
        #"{"method":"item/completed","params":{"item":{"type":"sleep","id":"call_sleep_child_1","durationMs":3000},"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","turnId":"01a159c1-18ea-7243-96ef-15a4a6c6880d","completedAtMs":1792507192708},"emittedAtMs":1792507192709}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","turnId":"01a159c1-18ea-7243-96ef-15a4a6c6880d","tokenUsage":{"total":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507192709}"#,
        #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_5","text":"child done","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","turnId":"01a159c1-18ea-7243-96ef-15a4a6c6880d","startedAtMs":1792507193723},"emittedAtMs":1792507193723}"#,
        #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_5","text":"child done","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","turnId":"01a159c1-18ea-7243-96ef-15a4a6c6880d","completedAtMs":1792507193723},"emittedAtMs":1792507193723}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","turnId":"01a159c1-18ea-7243-96ef-15a4a6c6880d","tokenUsage":{"total":{"totalTokens":30,"inputTokens":20,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":10,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507193723}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","status":{"type":"idle"}},"emittedAtMs":1792507193724}"#,
        #"{"method":"turn/completed","params":{"threadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","turn":{"id":"01a159c1-18ea-7243-96ef-15a4a6c6880d","rootTurnId":"01a159c1-1800-7383-a57b-c0adc1a48562","items":[{"type":"agentMessage","id":"msg_5","text":"child done","phase":null,"memoryCitation":null,"delivery":null,"questions":null}],"itemsView":"summary","status":"completed","error":null,"startedAt":1792507189,"completedAt":1792507193,"durationMs":4240}},"emittedAtMs":1792507193724}"#,
        #"{"method":"item/started","params":{"item":{"type":"subAgentActivity","model":null,"reasoningEffort":null,"id":"subagent-completed-01a159c1-18ea-7243-96ef-15a4a6c6880d","kind":"completed","agentThreadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","agentPath":"/root/probe_child"},"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","startedAtMs":1792507193724},"emittedAtMs":1792507193724}"#,
        #"{"method":"item/completed","params":{"item":{"type":"subAgentActivity","model":null,"reasoningEffort":null,"id":"subagent-completed-01a159c1-18ea-7243-96ef-15a4a6c6880d","kind":"completed","agentThreadId":"01a159c1-18e7-75e2-b3f7-07bff18af412","agentPath":"/root/probe_child"},"threadId":"01a159c1-17f0-7a03-b8bc-468dec521b66","turnId":"01a159c1-1800-7383-a57b-c0adc1a48562","completedAtMs":1792507193724},"emittedAtMs":1792507193724}"#,
    ]

    static let backgroundTerminal: [String] = [
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","status":{"type":"active","activeFlags":[]}},"emittedAtMs":1792507417426}"#,
        #"{"method":"turn/started","params":{"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turn":{"id":"01a159c4-934e-7b10-88c2-33df68b50555","rootTurnId":"01a159c4-934e-7b10-88c2-33df68b50555","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":1792507417,"completedAt":null,"durationMs":null}},"emittedAtMs":1792507417426}"#,
        #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"01a159c4-9353-7e83-b27b-d7fabb3dd097","clientId":null,"content":[{"type":"text","text":"PARENT_PROBE_PROMPT: spawn one sub-agent","text_elements":[]}]},"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","startedAtMs":1792507417427},"emittedAtMs":1792507417427}"#,
        #"{"method":"item/completed","params":{"item":{"type":"userMessage","id":"01a159c4-9353-7e83-b27b-d7fabb3dd097","clientId":null,"content":[{"type":"text","text":"PARENT_PROBE_PROMPT: spawn one sub-agent","text_elements":[]}]},"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","completedAtMs":1792507417427},"emittedAtMs":1792507417427}"#,
        #"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-170d2c38-fc2a-457f-a102-478c88c4b5de","pluginId":null,"scriptPath":null,"command":"/bin/zsh -lc 'sleep 6; echo bg-done'","cwd":"/tmp/w","processId":"4376","source":"unifiedExecStartup","status":"inProgress","commandActions":[{"type":"unknown","command":"sleep 6; echo bg-done"}],"aggregatedOutput":null,"exitCode":null,"durationMs":null},"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","startedAtMs":1792507417938},"emittedAtMs":1792507417940}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","tokenUsage":{"total":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507418445}"#,
        #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_3","text":"parent done, command left running","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","startedAtMs":1792507418649},"emittedAtMs":1792507418649}"#,
        #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_3","text":"parent done, command left running","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","completedAtMs":1792507418649},"emittedAtMs":1792507418649}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","tokenUsage":{"total":{"totalTokens":30,"inputTokens":20,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":10,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507418649}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","status":{"type":"idle"}},"emittedAtMs":1792507418649}"#,
        #"{"method":"turn/completed","params":{"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turn":{"id":"01a159c4-934e-7b10-88c2-33df68b50555","rootTurnId":"01a159c4-934e-7b10-88c2-33df68b50555","items":[{"type":"agentMessage","id":"msg_3","text":"parent done, command left running","phase":null,"memoryCitation":null,"delivery":null,"questions":null}],"itemsView":"summary","status":"completed","error":null,"startedAt":1792507417,"completedAt":1792507418,"durationMs":1225}},"emittedAtMs":1792507418649}"#,
        #"{"method":"item/commandExecution/outputDelta","params":{"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","itemId":"exec-170d2c38-fc2a-457f-a102-478c88c4b5de","delta":"bg-done\n"},"emittedAtMs":1792507423812}"#,
        #"{"method":"item/completed","params":{"item":{"type":"commandExecution","id":"exec-170d2c38-fc2a-457f-a102-478c88c4b5de","pluginId":null,"scriptPath":null,"command":"/bin/zsh -lc 'sleep 6; echo bg-done'","cwd":"/tmp/w","processId":"4376","source":"unifiedExecStartup","status":"completed","commandActions":[{"type":"unknown","command":"sleep 6; echo bg-done"}],"aggregatedOutput":"bg-done\n","exitCode":0,"durationMs":5873},"threadId":"01a159c4-9345-7d91-948e-aedd17cccfa0","turnId":"01a159c4-934e-7b10-88c2-33df68b50555","completedAtMs":1792507423812},"emittedAtMs":1792507423812}"#,
    ]

    static let failedChild: [String] = [
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","status":{"type":"active","activeFlags":[]}},"emittedAtMs":1792507462667}"#,
        #"{"method":"turn/started","params":{"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turn":{"id":"01a159c5-4404-7763-9777-a90be9c482a8","rootTurnId":"01a159c5-4404-7763-9777-a90be9c482a8","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":1792507462,"completedAt":null,"durationMs":null}},"emittedAtMs":1792507462667}"#,
        #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"01a159c5-440c-7f20-832a-8dabbe4781df","clientId":null,"content":[{"type":"text","text":"PARENT_PROBE_PROMPT: spawn one sub-agent","text_elements":[]}]},"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turnId":"01a159c5-4404-7763-9777-a90be9c482a8","startedAtMs":1792507462668},"emittedAtMs":1792507462669}"#,
        #"{"method":"item/completed","params":{"item":{"type":"userMessage","id":"01a159c5-440c-7f20-832a-8dabbe4781df","clientId":null,"content":[{"type":"text","text":"PARENT_PROBE_PROMPT: spawn one sub-agent","text_elements":[]}]},"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turnId":"01a159c5-4404-7763-9777-a90be9c482a8","completedAtMs":1792507462668},"emittedAtMs":1792507462669}"#,
        #"{"method":"item/started","params":{"item":{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"medium","id":"call_spawn_1","kind":"started","agentThreadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","agentPath":"/root/probe_child"},"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turnId":"01a159c5-4404-7763-9777-a90be9c482a8","startedAtMs":1792507462886},"emittedAtMs":1792507462887}"#,
        #"{"method":"item/completed","params":{"item":{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"medium","id":"call_spawn_1","kind":"started","agentThreadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","agentPath":"/root/probe_child"},"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turnId":"01a159c5-4404-7763-9777-a90be9c482a8","completedAtMs":1792507462886},"emittedAtMs":1792507462887}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","status":{"type":"idle"}},"emittedAtMs":1792507462887}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turnId":"01a159c5-4404-7763-9777-a90be9c482a8","tokenUsage":{"total":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507462887}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","status":{"type":"active","activeFlags":[]}},"emittedAtMs":1792507462890}"#,
        #"{"method":"turn/started","params":{"threadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","turn":{"id":"01a159c5-44e6-7863-9029-c9586e1bb26c","rootTurnId":"01a159c5-4404-7763-9777-a90be9c482a8","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":1792507462,"completedAt":null,"durationMs":null}},"emittedAtMs":1792507462890}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","turnId":"01a159c5-44e6-7863-9029-c9586e1bb26c","tokenUsage":{"total":{"totalTokens":258400,"inputTokens":0,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0},"last":{"totalTokens":258400,"inputTokens":0,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":0,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507462897}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","status":{"type":"systemError"}},"emittedAtMs":1792507462897}"#,
        #"{"method":"error","params":{"error":{"message":"Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying.","codexErrorInfo":"contextWindowExceeded","additionalDetails":null,"misalignment":null},"willRetry":false,"threadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","turnId":"01a159c5-44e6-7863-9029-c9586e1bb26c"},"emittedAtMs":1792507462897}"#,
        #"{"method":"turn/completed","params":{"threadId":"01a159c5-44e3-7e62-9923-d5b2e7abb41b","turn":{"id":"01a159c5-44e6-7863-9029-c9586e1bb26c","rootTurnId":"01a159c5-4404-7763-9777-a90be9c482a8","items":[],"itemsView":"notLoaded","status":"failed","error":{"message":"Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying.","codexErrorInfo":"contextWindowExceeded","additionalDetails":null,"misalignment":null},"startedAt":1792507462,"completedAt":1792507462,"durationMs":9}},"emittedAtMs":1792507462897}"#,
        #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_3","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turnId":"01a159c5-4404-7763-9777-a90be9c482a8","startedAtMs":1792507463106},"emittedAtMs":1792507463106}"#,
        #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_3","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turnId":"01a159c5-4404-7763-9777-a90be9c482a8","completedAtMs":1792507463106},"emittedAtMs":1792507463106}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turnId":"01a159c5-4404-7763-9777-a90be9c482a8","tokenUsage":{"total":{"totalTokens":30,"inputTokens":20,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":10,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507463106}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","status":{"type":"idle"}},"emittedAtMs":1792507463106}"#,
        #"{"method":"turn/completed","params":{"threadId":"01a159c5-43ed-7501-b28f-2a40ebc72360","turn":{"id":"01a159c5-4404-7763-9777-a90be9c482a8","rootTurnId":"01a159c5-4404-7763-9777-a90be9c482a8","items":[{"type":"agentMessage","id":"msg_3","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null}],"itemsView":"summary","status":"completed","error":null,"startedAt":1792507462,"completedAt":1792507463,"durationMs":442}},"emittedAtMs":1792507463106}"#,
    ]

    static let interruptedChild: [String] = [
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","status":{"type":"active","activeFlags":[]}},"emittedAtMs":1792507479145}"#,
        #"{"method":"turn/started","params":{"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turn":{"id":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","rootTurnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":1792507479,"completedAt":null,"durationMs":null}},"emittedAtMs":1792507479145}"#,
        #"{"method":"item/started","params":{"item":{"type":"userMessage","id":"01a159c5-846a-7141-9acf-e3bc3c2717e7","clientId":null,"content":[{"type":"text","text":"PARENT_PROBE_PROMPT: spawn one sub-agent","text_elements":[]}]},"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","startedAtMs":1792507479146},"emittedAtMs":1792507479146}"#,
        #"{"method":"item/completed","params":{"item":{"type":"userMessage","id":"01a159c5-846a-7141-9acf-e3bc3c2717e7","clientId":null,"content":[{"type":"text","text":"PARENT_PROBE_PROMPT: spawn one sub-agent","text_elements":[]}]},"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","completedAtMs":1792507479146},"emittedAtMs":1792507479146}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-8541-7673-b8b7-0620fc133902","status":{"type":"idle"}},"emittedAtMs":1792507479362}"#,
        #"{"method":"item/started","params":{"item":{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"medium","id":"call_spawn_1","kind":"started","agentThreadId":"01a159c5-8541-7673-b8b7-0620fc133902","agentPath":"/root/probe_child"},"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","startedAtMs":1792507479362},"emittedAtMs":1792507479362}"#,
        #"{"method":"item/completed","params":{"item":{"type":"subAgentActivity","model":"gpt-6-luna","reasoningEffort":"medium","id":"call_spawn_1","kind":"started","agentThreadId":"01a159c5-8541-7673-b8b7-0620fc133902","agentPath":"/root/probe_child"},"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","completedAtMs":1792507479362},"emittedAtMs":1792507479362}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","tokenUsage":{"total":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507479362}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-8541-7673-b8b7-0620fc133902","status":{"type":"active","activeFlags":[]}},"emittedAtMs":1792507479362}"#,
        #"{"method":"turn/started","params":{"threadId":"01a159c5-8541-7673-b8b7-0620fc133902","turn":{"id":"01a159c5-8542-7360-9543-18dc43b5875b","rootTurnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","items":[],"itemsView":"notLoaded","status":"inProgress","error":null,"startedAt":1792507479,"completedAt":null,"durationMs":null}},"emittedAtMs":1792507479362}"#,
        #"{"method":"item/started","params":{"item":{"type":"sleep","id":"call_sleep_child_1","durationMs":8000},"threadId":"01a159c5-8541-7673-b8b7-0620fc133902","turnId":"01a159c5-8542-7360-9543-18dc43b5875b","startedAtMs":1792507479574},"emittedAtMs":1792507479575}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c5-8541-7673-b8b7-0620fc133902","turnId":"01a159c5-8542-7360-9543-18dc43b5875b","tokenUsage":{"total":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507480375}"#,
        #"{"method":"item/started","params":{"item":{"type":"subAgentActivity","model":null,"reasoningEffort":null,"id":"call_interrupt_1","kind":"interrupted","agentThreadId":"01a159c5-8541-7673-b8b7-0620fc133902","agentPath":"/root/probe_child"},"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","startedAtMs":1792507480374},"emittedAtMs":1792507480375}"#,
        #"{"method":"item/completed","params":{"item":{"type":"subAgentActivity","model":null,"reasoningEffort":null,"id":"call_interrupt_1","kind":"interrupted","agentThreadId":"01a159c5-8541-7673-b8b7-0620fc133902","agentPath":"/root/probe_child"},"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","completedAtMs":1792507480374},"emittedAtMs":1792507480375}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","tokenUsage":{"total":{"totalTokens":30,"inputTokens":20,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":10,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507480375}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-8541-7673-b8b7-0620fc133902","status":{"type":"idle"}},"emittedAtMs":1792507480375}"#,
        #"{"method":"turn/completed","params":{"threadId":"01a159c5-8541-7673-b8b7-0620fc133902","turn":{"id":"01a159c5-8542-7360-9543-18dc43b5875b","rootTurnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","items":[],"itemsView":"notLoaded","status":"interrupted","error":null,"startedAt":1792507479,"completedAt":1792507480,"durationMs":1012}},"emittedAtMs":1792507480375}"#,
        #"{"method":"item/started","params":{"item":{"type":"agentMessage","id":"msg_5","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","startedAtMs":1792507480588},"emittedAtMs":1792507480588}"#,
        #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_5","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null},"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","completedAtMs":1792507480588},"emittedAtMs":1792507480588}"#,
        #"{"method":"thread/tokenUsage/updated","params":{"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","tokenUsage":{"total":{"totalTokens":45,"inputTokens":30,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":15,"reasoningOutputTokens":0},"last":{"totalTokens":15,"inputTokens":10,"cachedInputTokens":0,"cacheWriteInputTokens":0,"outputTokens":5,"reasoningOutputTokens":0},"modelContextWindow":258400}},"emittedAtMs":1792507480588}"#,
        #"{"method":"thread/status/changed","params":{"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","status":{"type":"idle"}},"emittedAtMs":1792507480588}"#,
        #"{"method":"turn/completed","params":{"threadId":"01a159c5-845d-7413-9bd6-4ec50887b9ab","turn":{"id":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","rootTurnId":"01a159c5-8466-7ad0-bc3b-71c0c4cbefb8","items":[{"type":"agentMessage","id":"msg_5","text":"parent done without waiting","phase":null,"memoryCitation":null,"delivery":null,"questions":null}],"itemsView":"summary","status":"completed","error":null,"startedAt":1792507479,"completedAt":1792507480,"durationMs":1444}},"emittedAtMs":1792507480588}"#,
    ]
}

// MARK: - 行ごとの停止（docs/BACKGROUND_CONTROL_2026-10-21.md §3.5）

/// shared/fixtures/background-control/codex-stop（codex 0.162.1 の app-server の記録。`{i, t, dir: note|out|in, msg}`）。
private struct CodexStopFixture {
    let records: [[String: Any]]

    init(_ name: String) throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BridgeAppTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // mac-bridge/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("shared/fixtures/background-control/codex-stop")
        let text = try String(contentsOf: dir.appendingPathComponent("\(name).jsonl"), encoding: .utf8)
        records = text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private func index(_ r: [String: Any]) -> Int { r["i"] as? Int ?? -1 }
    private func msg(_ r: [String: Any]) -> [String: Any] { r["msg"] as? [String: Any] ?? [:] }

    /// i の範囲（半開）の、app-server から届いた通知（id の無い method）。
    func notifications(_ range: Range<Int>) -> [String] {
        records.filter { r in
            let m = msg(r)
            return r["dir"] as? String == "in" && m["method"] != nil && m["id"] == nil && range.contains(index(r))
        }.map { String(decoding: try! JSONSerialization.data(withJSONObject: msg($0)), as: UTF8.self) }
    }

    /// 通知のうち method が合う最初のものの i（条件に params.turn.id か item.id を指定できる）。
    func firstIndex(method: String, where match: ([String: Any]) -> Bool = { _ in true }) -> Int {
        records.first { r in
            let m = msg(r)
            return r["dir"] as? String == "in" && m["method"] as? String == method && match(m["params"] as? [String: Any] ?? [:])
        }.map(index) ?? -1
    }

    /// こちらが送った要求（method と threadId が合う最初のもの）の i。
    func outIndex(method: String, threadId: String) -> Int {
        records.first { r in
            let m = msg(r)
            return r["dir"] as? String == "out" && m["method"] as? String == method
                && (m["params"] as? [String: Any])?["threadId"] as? String == threadId
        }.map(index) ?? -1
    }

    /// i の次に出たこちらの要求の i（無ければ最後まで）。
    func nextOutIndex(after i: Int) -> Int {
        records.first { index($0) > i && $0["dir"] as? String == "out" }.map(index) ?? Int.max
    }

    func errorMessage(prefix: String) -> String? {
        records.compactMap { (msg($0)["error"] as? [String: Any])?["message"] as? String }.first { $0.hasPrefix(prefix) }
    }
}

private final class CodexCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(method: String, params: [String: Any])] = []
    var calls: [(method: String, params: [String: Any])] { lock.withLock { storage } }
    func methods() -> [String] { calls.map(\.method) }
    func add(_ method: String, _ params: [String: Any]) { lock.withLock { storage.append((method, params)) } }
}

private struct CodexStopError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class CodexStopTaskTests: XCTestCase {
    private func obj(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func progressRows(_ events: [SessionEvent]) -> [[String: Any]] {
        events.filter { $0.type == .workflowProgress }.flatMap {
            ($0.content.map(obj)?["agents"] as? [[String: Any]]) ?? []
        }
    }

    private func rowHistory(_ id: String, _ events: [SessionEvent]) -> [[String: Any]] {
        progressRows(events).filter { $0["id"] as? String == id }
    }

    private func session(_ threadId: String) -> CodexAppServerSession {
        let s = CodexAppServerSession(agentId: "codex", initialSessionId: threadId, cwd: nil, executable: "/usr/bin/false")
        s.stopSettleSeconds = 0.3
        return s
    }

    private func drain(_ session: CodexAppServerSession) async -> [SessionEvent] {
        await session.close()
        var out: [SessionEvent] = []
        do { for try await event in session.events { out.append(event) } } catch {}
        return out
    }

    private func request(_ s: CodexAppServerSession, _ key: String) async -> StopTaskRequest {
        let snapshot = await s.subagentSnapshot()
        let epoch = snapshot.map(obj)?["epoch"] as? String
        return StopTaskRequest(taskId: "subagents", rowId: key, epoch: epoch)
    }

    private func stop(_ s: CodexAppServerSession, _ key: String) async -> StopTaskOutcome {
        await s.stopTask(request(s, key))
    }

    private func row(_ s: CodexAppServerSession, _ key: String) async throws -> [String: Any] {
        let found = await snapshotRow(s, key)
        return try XCTUnwrap(found)
    }

    private func snapshotRow(_ s: CodexAppServerSession, _ key: String) async -> [String: Any]? {
        let snapshot = await s.subagentSnapshot()
        return (snapshot.map(obj)?["agents"] as? [[String: Any]])?.first { $0["id"] as? String == key }
    }

    private let s1aThread = "01a15e36-69f7-7850-821c-e8e9f6fe89d7"
    private let s1aExec = "exec-0fa47f37-965d-4f5c-b33e-b492fd839ebc"

    /// s1a: 親のターンが終わった後も動く端末は shell の行で、processId を手がかりに terminate で止める。
    /// terminated: true で行は stopped になり、後から届く item/completed（failed / -1）は failed にならず、tool_end は interrupted。
    func testTerminateStopsShellRowAndLateCompletionIsInterrupted() async throws {
        let f = try CodexStopFixture("s1a-terminal")
        let s = session(s1aThread)
        f.notifications(0..<48).forEach(s.handleLine)
        let before = try await row(s, s1aExec)
        XCTAssertEqual(before["state"] as? String, "running")
        XCTAssertEqual(before["stoppable"] as? Bool, true)

        let rec = CodexCallRecorder()
        s.requestHook = { method, params in
            rec.add(method, params)
            return ["terminated": true]
        }
        let outcome = await stop(s, s1aExec)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(rec.methods(), ["thread/backgroundTerminals/terminate"])
        XCTAssertEqual(rec.calls.first?.params["threadId"] as? String, s1aThread)
        XCTAssertEqual(rec.calls.first?.params["processId"] as? String, "93607")
        let stopped = try await row(s, s1aExec)
        XCTAssertEqual(stopped["state"] as? String, "stopped")
        XCTAssertEqual(stopped["stoppable"] as? Bool, false)

        f.notifications(55..<56).forEach(s.handleLine)
        let events = await drain(s)
        let history = rowHistory(s1aExec, events)
        XCTAssertEqual(history.compactMap { $0["state"] as? String }.last, "stopped")
        XCTAssertFalse(history.contains { $0["state"] as? String == "failed" })
        // 頼んだ間は stoppable が false で届き、終わった後も true には戻らない。
        let flags = history.compactMap { $0["stoppable"] as? Bool }
        XCTAssertEqual(flags.first, true)
        XCTAssertEqual(flags.last, false)
        let end = try XCTUnwrap(events.first { $0.type == .toolEnd && $0.toolUseId == s1aExec })
        XCTAssertEqual(end.metadata?["status"], "interrupted")
    }

    /// 返事より先に item/completed（failed / -1）が来ても、返事待ちの行は stopped と読む。
    func testCompletionBeforeTheReplyIsStoppedToo() async throws {
        let f = try CodexStopFixture("s1a-terminal")
        let s = session(s1aThread)
        f.notifications(0..<48).forEach(s.handleLine)
        let late = f.notifications(55..<56)
        s.requestHook = { _, _ in
            late.forEach(s.handleLine)
            return ["terminated": true]
        }
        let outcome = await stop(s, s1aExec)
        XCTAssertEqual(outcome, .stopped)
        let events = await drain(s)
        XCTAssertEqual(rowHistory(s1aExec, events).compactMap { $0["state"] as? String }.last, "stopped")
        XCTAssertEqual(events.first { $0.type == .toolEnd && $0.toolUseId == s1aExec }?.metadata?["status"], "interrupted")
    }

    /// s1b: 2 つの端末のうち 1 つだけ止める。もう片方は running のまま、stoppable も true のまま。
    func testStoppingOneOfTwoTerminalsLeavesTheOther() async throws {
        let f = try CodexStopFixture("s1b-two-terminals")
        let thread = "01a15e39-0f57-7372-bab3-80be67d2b07e"
        let first = "exec-e88b110d-cbb4-442b-a110-6f8d1b3d9ddf"
        let second = "exec-6c08ab86-7c87-4247-8496-434c84961492"
        let s = session(thread)
        f.notifications(0..<83).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in
            rec.add(method, params)
            return ["terminated": true]
        }
        let outcome = await stop(s, first)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(rec.calls.first?.params["processId"] as? String, "15559")
        let a = try await row(s, first)
        let b = try await row(s, second)
        XCTAssertEqual(a["state"] as? String, "stopped")
        XCTAssertEqual(b["state"] as? String, "running")
        XCTAssertEqual(b["stoppable"] as? Bool, true)
        // もう片方の item/completed（failed / -1）は、止めていないので failed のまま。
        f.notifications(108..<109).forEach(s.handleLine)
        let events = await drain(s)
        XCTAssertEqual(rowHistory(second, events).compactMap { $0["state"] as? String }.last, "failed")
        XCTAssertNil(events.first { $0.type == .toolEnd && $0.toolUseId == second && $0.metadata?["status"] == "interrupted" })
    }

    /// s1a: すでに終わった端末（terminated: false）は not_running で、行は stopped で閉じる。
    func testTerminateFalseIsNotRunningAndClosesRow() async throws {
        let f = try CodexStopFixture("s1a-terminal")
        let s = session(s1aThread)
        f.notifications(0..<48).forEach(s.handleLine)
        s.requestHook = { _, _ in ["terminated": false] }
        let outcome = await stop(s, s1aExec)
        XCTAssertEqual(outcome, .notRunning)
        let row = try await row(s, s1aExec)
        XCTAssertEqual(row["state"] as? String, "stopped")
        _ = await drain(s)
    }

    /// 古い epoch と、行の無いキーは stale。止められない行（手がかりの無い行）は unsupported で、何も送らない。
    func testStaleAndUnknownRowsSendNothing() async throws {
        let f = try CodexStopFixture("s1a-terminal")
        let s = session(s1aThread)
        f.notifications(0..<48).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in rec.add(method, params); return [:] }
        var stale = await request(s, s1aExec)
        stale.epoch = "old"
        let a = await s.stopTask(stale)
        let b = await s.stopTask(StopTaskRequest(taskId: "subagents", rowId: "nope", epoch: await request(s, s1aExec).epoch))
        XCTAssertEqual(a, .stale)
        XCTAssertEqual(b, .stale)
        XCTAssertTrue(rec.calls.isEmpty)
        _ = await drain(s)
    }

    /// s9: terminate が使えない版（知らない method）。unsupported を返し、全 shell 行の stoppable を false にして送り直す。
    /// 以降の停止は何も送らず unsupported。
    func testUnknownVariantDisablesTerminalStop() async throws {
        let f = try CodexStopFixture("s1a-terminal")
        let nine = try CodexStopFixture("s9-errors")
        let message = try XCTUnwrap(nine.errorMessage(prefix: "Invalid request: unknown variant"))
        let s = session(s1aThread)
        f.notifications(0..<48).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in
            rec.add(method, params)
            throw CodexStopError(message: message)
        }
        let outcome = await stop(s, s1aExec)
        XCTAssertEqual(outcome, .unsupported(nil))
        let row = try await row(s, s1aExec)
        XCTAssertEqual(row["state"] as? String, "running")
        XCTAssertEqual(row["stoppable"] as? Bool, false)
        let again = await stop(s, s1aExec)
        XCTAssertEqual(again, .unsupported(nil))
        XCTAssertEqual(rec.calls.count, 1)
        _ = await drain(s)
    }

    /// s9: experimentalApi が要るという文も unsupported。ほかの断り（thread id の不正）は failed で文を付け、行は止められるまま。
    func testErrorTextsAreTold() async throws {
        let f = try CodexStopFixture("s1a-terminal")
        let nine = try CodexStopFixture("s9-errors")
        let s = session(s1aThread)
        f.notifications(0..<48).forEach(s.handleLine)
        let bad = try XCTUnwrap(nine.errorMessage(prefix: "invalid thread id"))
        s.requestHook = { _, _ in throw CodexStopError(message: bad) }
        let failed = await stop(s, s1aExec)
        XCTAssertEqual(failed, .failed(bad))
        let row = try await row(s, s1aExec)
        XCTAssertEqual(row["stoppable"] as? Bool, true)
        s.requestHook = { _, _ in throw CodexStopError(message: "thread/backgroundTerminals/terminate requires experimentalApi capability") }
        let unsupported = await stop(s, s1aExec)
        XCTAssertEqual(unsupported, .unsupported(nil))
        _ = await drain(s)
    }

    /// 同じ行への 2 つ目の停止は新しく書かず、1 つ目の結果を待って同じ結果を返す。
    func testSecondStopOnSameRowJoinsTheFirst() async throws {
        let f = try CodexStopFixture("s1a-terminal")
        let s = session(s1aThread)
        f.notifications(0..<48).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in
            rec.add(method, params)
            try? await Task.sleep(nanoseconds: 150_000_000)
            return ["terminated": true]
        }
        let req = await request(s, s1aExec)
        async let first = s.stopTask(req)
        try await Task.sleep(nanoseconds: 40_000_000)
        async let second = s.stopTask(req)
        let (a, b) = await (first, second)
        XCTAssertEqual(a, .stopped)
        XCTAssertEqual(b, .stopped)
        XCTAssertEqual(rec.calls.count, 1)
        _ = await drain(s)
    }

    private let s2aThread = "01a15e3d-7f7f-7131-9a9f-49d57dadc779"
    private let s2aChild = "01a15e3d-9b92-7281-b27f-3875d636a6af"
    private let s2aChildTurn = "01a15e3d-9c24-73d2-a896-752f41891d1a"

    /// s2a: 子の turn/started で手がかりが立つ。turn/interrupt（子の thread と今の turn id）を送り、子の
    /// turn/completed(interrupted) で行が stopped になる。続けて子の端末の clean を送る。親には何も送らない。
    func testStopAgentInterruptsChildAndCleansItsTerminals() async throws {
        let f = try CodexStopFixture("s2a-subagent-after")
        let s = session(s2aThread)
        let outI = f.outIndex(method: "turn/interrupt", threadId: s2aChild)
        f.notifications(0..<outI).forEach(s.handleLine)
        let before = try await row(s, s2aChild)
        XCTAssertEqual(before["rowKind"] as? String, "agent")
        XCTAssertEqual(before["stoppable"] as? Bool, true)

        let rec = CodexCallRecorder()
        let reply = f.notifications(outI..<f.nextOutIndex(after: outI))
        XCTAssertFalse(reply.isEmpty)
        s.requestHook = { method, params in
            rec.add(method, params)
            if method == "turn/interrupt" { reply.forEach(s.handleLine) }
            return [:]
        }
        let outcome = await stop(s, s2aChild)
        XCTAssertEqual(outcome, .stopped)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rec.methods(), ["turn/interrupt", "thread/backgroundTerminals/clean"])
        XCTAssertEqual(rec.calls[0].params["threadId"] as? String, s2aChild)
        XCTAssertEqual(rec.calls[0].params["turnId"] as? String, s2aChildTurn)
        XCTAssertEqual(rec.calls[1].params["threadId"] as? String, s2aChild)
        XCTAssertFalse(rec.methods().contains("turn/steer"))
        let events = await drain(s)
        let history = rowHistory(s2aChild, events)
        XCTAssertEqual(history.compactMap { $0["state"] as? String }.last, "stopped")
        XCTAssertEqual(history.compactMap { $0["stoppable"] as? Bool }.last, false)
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1, "親のターンの done だけ")
    }

    /// s2c: 子の turn/completed が来なければ、5 秒（テストでは短く）待ってこちらで stopped にする。
    func testStopAgentClosesRowItselfWhenCompletionNeverComes() async throws {
        let f = try CodexStopFixture("s2c-child-cleanup")
        let thread = "01a15e42-7c28-7932-92f1-10eb6f74ebf8"
        let child = "01a15e42-9015-7b23-a680-9dbc1d156c97"
        let s = session(thread)
        let outI = f.outIndex(method: "turn/interrupt", threadId: child)
        f.notifications(0..<outI).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in rec.add(method, params); return [:] }
        let outcome = await stop(s, child)
        XCTAssertEqual(outcome, .stopped)
        XCTAssertEqual(rec.calls.first?.params["turnId"] as? String, "01a15e42-9075-7e51-b186-a19c9f6c1224")
        let row = try await row(s, child)
        XCTAssertEqual(row["state"] as? String, "stopped")
        _ = await drain(s)
    }

    /// s5・s9: 子の turn がもう無い（expected active turn id / thread not found / no active turn）は not_running。
    /// 手がかりを外して stoppable を false で送り直し、同じ失敗を繰り返さない。
    func testStaleChildTurnIsNotRunning() async throws {
        let f = try CodexStopFixture("s2a-subagent-after")
        for message in ["expected active turn id A but found B", "thread not found: x", "no active turn to interrupt"] {
            let s = session(s2aThread)
            f.notifications(0..<f.outIndex(method: "turn/interrupt", threadId: s2aChild)).forEach(s.handleLine)
            s.requestHook = { _, _ in throw CodexStopError(message: message) }
            let outcome = await stop(s, s2aChild)
            XCTAssertEqual(outcome, .notRunning, message)
            let row = try await row(s, s2aChild)
            XCTAssertEqual(row["state"] as? String, "running")
            XCTAssertEqual(row["stoppable"] as? Bool, false)
            _ = await drain(s)
        }
        // ほかの断りは failed で、行は止められるまま。
        let s = session(s2aThread)
        f.notifications(0..<f.outIndex(method: "turn/interrupt", threadId: s2aChild)).forEach(s.handleLine)
        s.requestHook = { _, _ in throw CodexStopError(message: "boom") }
        let outcome = await stop(s, s2aChild)
        XCTAssertEqual(outcome, .failed("boom"))
        let row = try await row(s, s2aChild)
        XCTAssertEqual(row["stoppable"] as? Bool, true)
        _ = await drain(s)
    }

    /// s5: 同じ turn に 2 回 turn/interrupt を送らない。親の interrupt() が先に送っていれば、子の停止は送らずに行を待つ。
    func testChildStopDoesNotSendASecondInterruptToTheSameTurn() async throws {
        let f = try CodexStopFixture("s2a-subagent-after")
        let s = session(s2aThread)
        let outI = f.outIndex(method: "turn/interrupt", threadId: s2aChild)
        f.notifications(0..<outI).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in rec.add(method, params); return [:] }
        // 1 回目: 返事は来るが turn/completed は来ない（行はこちらで閉じる）。
        let first = await stop(s, s2aChild)
        XCTAssertEqual(first, .stopped)
        XCTAssertEqual(rec.methods().filter { $0 == "turn/interrupt" }.count, 1)
        _ = await drain(s)
    }

    /// s12: 親の interrupt() は同じ turn に 2 回送らない（2 回目は返事が来ず待たされる）。turn/completed の後の新しい turn には送る。
    func testParentInterruptIsNotSentTwiceForTheSameTurn() async throws {
        let f = try CodexStopFixture("s12-parent-double-interrupt")
        let thread = "01a15e62-42a0-7e93-91ec-26501a1ce2c1"
        let turn = "01a15e62-45a1-7512-9c66-27e61d4a28f8"
        let s = session(thread)
        let started = f.firstIndex(method: "turn/started")
        f.notifications(0..<(started + 1)).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in rec.add(method, params); return [:] }
        await s.interrupt()
        await s.interrupt()
        await s.interrupt()
        XCTAssertEqual(rec.methods(), ["turn/interrupt"])
        XCTAssertEqual(rec.calls.first?.params["turnId"] as? String, turn)
        // 終わった turn の後の、新しい turn には送れる。
        let completed = f.firstIndex(method: "turn/completed")
        f.notifications(completed..<(completed + 1)).forEach(s.handleLine)
        let next = #"{"method":"turn/started","params":{"threadId":"\#(thread)","turn":{"id":"turn-2","status":"inProgress"}}}"#
        s.handleLine(next)
        await s.interrupt()
        XCTAssertEqual(rec.methods(), ["turn/interrupt", "turn/interrupt"])
        XCTAssertEqual(rec.calls.last?.params["turnId"] as? String, "turn-2")
        _ = await drain(s)
    }

    /// 断られた（終わっていた等）親の interrupt は、覚えを消して次に送れる。
    func testRejectedParentInterruptCanBeRetried() async throws {
        let f = try CodexStopFixture("s12-parent-double-interrupt")
        let s = session("01a15e62-42a0-7e93-91ec-26501a1ce2c1")
        f.notifications(0..<(f.firstIndex(method: "turn/started") + 1)).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in rec.add(method, params); throw CodexStopError(message: "no active turn to interrupt") }
        await s.interrupt()
        await s.interrupt()
        XCTAssertEqual(rec.calls.count, 2)
        _ = await drain(s)
    }

    /// turn/interrupt が timeout した子の行は、覚えを残す。押し直しても同じ turn に 2 回目を送らない（2 回目には返事が来ない）。
    /// 送らずに行が閉じるのを待ち、閉じなければ stopped にせず timeout を返して、行は stoppable に戻る（子はまだ動いているかもしれない）。
    func testChildStopTimeoutKeepsTheTurnMarkAndDoesNotResend() async throws {
        let f = try CodexStopFixture("s2a-subagent-after")
        let s = session(s2aThread)
        let outI = f.outIndex(method: "turn/interrupt", threadId: s2aChild)
        f.notifications(0..<outI).forEach(s.handleLine)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in
            rec.add(method, params)
            throw CodexAppServerError(message: "request timed out", timedOut: true)
        }
        let first = await stop(s, s2aChild)
        XCTAssertEqual(first, .timeout)
        let afterFirst = try await row(s, s2aChild)
        XCTAssertEqual(afterFirst["state"] as? String, "running")
        XCTAssertEqual(afterFirst["stoppable"] as? Bool, true)
        // 何度押し直しても、送らない・閉じなければ stopped にしない・押し直せる。
        for _ in 0..<2 {
            let again = await stop(s, s2aChild)
            XCTAssertEqual(again, .timeout, "閉じなければ stopped と言わず timeout")
            let r = try await row(s, s2aChild)
            XCTAssertEqual(r["state"] as? String, "running", "こちらで閉じない")
            XCTAssertEqual(r["stoppable"] as? Bool, true, "押し直せる")
        }
        XCTAssertEqual(rec.methods(), ["turn/interrupt"], "2 回目以降は turn/interrupt も clean も送らない")
        let events = await drain(s)
        // 押すたびに、頼んでいる間は stoppable が false で、終わったら true に戻して送り直す（最後の 1 つは close の片付け）。
        let flags = rowHistory(s2aChild, events).dropLast().compactMap { $0["stoppable"] as? Bool }
        XCTAssertEqual(Array(flags.suffix(6)), [false, true, false, true, false, true])
    }

    /// 前の turn/interrupt が timeout でも、2 回目の待ちの間に子の turn/completed(interrupted) が届けば、送り直さず stopped で終わる。
    /// 子の端末の clean は、行が閉じたこのときに送る。
    func testChildStopAfterTimeoutIsStoppedWhenCompletionArrivesLate() async throws {
        let f = try CodexStopFixture("s2a-subagent-after")
        let s = session(s2aThread)
        let outI = f.outIndex(method: "turn/interrupt", threadId: s2aChild)
        f.notifications(0..<outI).forEach(s.handleLine)
        let late = f.notifications(outI..<f.nextOutIndex(after: outI))
        XCTAssertFalse(late.isEmpty)
        let rec = CodexCallRecorder()
        s.requestHook = { method, params in
            rec.add(method, params)
            if method == "turn/interrupt" { throw CodexAppServerError(message: "request timed out", timedOut: true) }
            return [:]
        }
        let first = await stop(s, s2aChild)
        XCTAssertEqual(first, .timeout)
        async let second = stop(s, s2aChild)
        // 2 回目の押下が始まる（stoppable が false になる）のを待ってから、遅れた知らせを届ける。
        for _ in 0..<100 {
            if try await row(s, s2aChild)["stoppable"] as? Bool == false { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        late.forEach(s.handleLine)
        let outcome = await second
        XCTAssertEqual(outcome, .stopped)
        let closed = try await row(s, s2aChild)
        XCTAssertEqual(closed["state"] as? String, "stopped")
        XCTAssertEqual(closed["stoppable"] as? Bool, false)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rec.methods(), ["turn/interrupt", "thread/backgroundTerminals/clean"], "turn/interrupt は 1 回だけ")
        XCTAssertEqual(rec.calls[1].params["threadId"] as? String, s2aChild)
        _ = await drain(s)
    }
}
