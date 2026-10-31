import XCTest
@testable import BridgeApp

/// SessionHub のカードの写し（WorkflowCardMirror）、完了の push の本文（TurnBubbles）、定期実行の集め方
/// （BridgeCronScheduler.TurnCollector）。規則は docs/BACKGROUND_WORK_2026-10-21.md §3.1・§3.5。
/// subagents の payload は本物の SubagentTracker で作る。
final class WorkflowCardMirrorTests: XCTestCase {
    private func obj(_ json: String?) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data((json ?? "{}").utf8))) as? [String: Any] ?? [:]
    }

    private func rows(_ json: String?) -> [[String: Any]] { (obj(json)["agents"] as? [[String: Any]]) ?? [] }

    private func ids(_ json: String?) -> [String] { rows(json).compactMap { $0["id"] as? String } }

    // MARK: - 動いている数

    func testCountsAgentsShellsAndUnfinishedWorkflows() {
        var t = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(t.begin(key: "a1", label: "Explore auth", agentType: "Explore", background: true))
        m.apply(t.begin(key: "b1", label: "npm run dev", background: true, rowKind: "shell", tool: "Bash",
                        command: "npm run dev"))
        m.apply(#"{"subtype":"task_started","taskId":"wf1","workflowName":"review","status":"running"}"#)
        XCTAssertEqual(m.counts, WorkflowCardMirror.Counts(agents: 1, shells: 1, workflows: 1, backgroundOnlyAgents: 1))
        XCTAssertTrue(m.counts.agentsOrWorkflows)

        m.apply(t.finish(key: "a1", state: "done", result: "見つかりました"))
        m.apply(#"{"subtype":"task_notification","taskId":"wf1","status":"completed"}"#)
        XCTAssertEqual(m.counts, WorkflowCardMirror.Counts(agents: 0, shells: 1, workflows: 0))
        XCTAssertTrue(m.counts.any, "バックグラウンドのコマンドだけでも閉じない")
        XCTAssertFalse(m.counts.agentsOrWorkflows, "コマンドだけではスリープ抑止・push 待ちにしない")
    }

    func testStoppedWorkflowIsFinishedAndKeepsOutcome() {
        var m = WorkflowCardMirror()
        m.apply(#"{"subtype":"task_started","taskId":"wf","workflowName":"review","status":"running"}"#)
        XCTAssertEqual(m.counts.workflows, 1)
        m.apply(#"{"subtype":"task_updated","taskId":"wf","status":"failed","outcome":"stopped"}"#)
        XCTAssertEqual(m.counts.workflows, 0)
        XCTAssertEqual(obj(m.snapshotJSON(taskId: "wf"))["outcome"] as? String, "stopped")
        XCTAssertEqual(obj(m.snapshotJSON(taskId: "wf"))["workflowName"] as? String, "review")
    }

    func testWorkflowWithoutStatusCountsAsRunningAndRowsMerge() {
        var m = WorkflowCardMirror()
        m.apply(#"{"subtype":"task_progress","taskId":"wf","agents":[{"index":0,"label":"phase 1","state":"running","model":"haiku"}]}"#)
        m.apply(#"{"subtype":"task_progress","taskId":"wf","agents":[{"index":0,"state":"done"}]}"#)
        XCTAssertEqual(m.counts.workflows, 1, "status の無い workflow は動いているとみなす")
        let row = rows(m.snapshotJSON(taskId: "wf")).first
        XCTAssertEqual(row?["label"] as? String, "phase 1", "epoch の無い行は届いた項目だけを上書きする")
        XCTAssertEqual(row?["state"] as? String, "done")
        XCTAssertEqual(row?["model"] as? String, "haiku")
    }

    /// phases と stoppable は最上位の知らない項目としてそのまま残り、workflow_snapshot に載る。
    /// それを運ばない後の行（進み具合だけ）では消えない。閉じる payload の stoppable: false は上書きする。
    func testPhasesAndStoppableSurviveInTheSnapshot() {
        var m = WorkflowCardMirror()
        m.apply(#"{"subtype":"task_progress","taskId":"wf","status":"running","workflowName":"review","stoppable":true,"agents":[{"index":1,"label":"scan","state":"running"}],"phases":[{"index":1,"title":"Scan"},{"index":2,"title":"Fix"}]}"#)
        m.apply(#"{"subtype":"task_progress","taskId":"wf","status":"running","description":"Scan: scan"}"#)
        var card = obj(m.snapshotJSON(taskId: "wf"))
        XCTAssertEqual((card["phases"] as? [[String: Any]])?.compactMap { $0["title"] as? String }, ["Scan", "Fix"])
        XCTAssertEqual(card["stoppable"] as? Bool, true)

        m.apply(#"{"subtype":"task_progress","taskId":"wf","status":"running","stoppable":false}"#)
        card = obj(m.snapshotJSON(taskId: "wf"))
        XCTAssertEqual(card["stoppable"] as? Bool, false, "停止を頼んでいる間は false で上書きする")
        XCTAssertEqual((card["phases"] as? [Any])?.count, 2)

        m.apply(#"{"subtype":"task_notification","taskId":"wf","status":"failed","outcome":"stopped","stoppable":false}"#)
        card = obj(m.snapshotJSON(taskId: "wf"))
        XCTAssertEqual(card["stoppable"] as? Bool, false)
        XCTAssertEqual((card["phases"] as? [Any])?.count, 2, "閉じる payload は phases を運ばないので、前の値が残る")
        XCTAssertEqual(rows(m.snapshotJSON(taskId: "wf")).first?["label"] as? String, "scan")
    }

    // MARK: - Live Activity（backgroundOnlyAgents・lastFinished。§8.2）

    private func finished(_ m: WorkflowCardMirror) -> [String] {
        m.lastFinished.map { "\($0.state)/\($0.background ? "bg" : "fg")" }
    }

    func testBackgroundOnlyAgentsCountsOnlyBackgroundAgentRows() {
        var t = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(t.begin(key: "a1", label: "背景", background: true))
        m.apply(t.begin(key: "a2", label: "前景", background: false))
        m.apply(t.begin(key: "b1", label: "dev", background: true, rowKind: "shell", tool: "Bash", command: "npm run dev"))
        XCTAssertEqual(m.counts.agents, 2)
        XCTAssertEqual(m.counts.backgroundOnlyAgents, 1, "前景の行とシェルは入らない")
        m.apply(t.finish(key: "a1", state: "done", result: nil))
        XCTAssertEqual(m.counts.backgroundOnlyAgents, 0)
    }

    func testLastFinishedHasRunningToFailedOnTheSameIndex() {
        var t = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(t.begin(key: "a1", label: "x", background: true))
        m.apply(t.begin(key: "a2", label: "y", background: false))
        XCTAssertTrue(m.lastFinished.isEmpty)
        m.apply(t.finish(key: "a1", state: "failed", result: "boom"))
        XCTAssertEqual(finished(m), ["failed/bg"])
        // 次の apply で上書きする。
        m.apply(t.finish(key: "a2", state: "done", result: "ok"))
        XCTAssertEqual(finished(m), ["done/fg"])
        m.apply(t.finish(key: "a2", state: "done", result: "ok"))
        XCTAssertTrue(m.lastFinished.isEmpty, "もう終わっている行は入らない")
    }

    func testEpochChangeStopsRunningRows() {
        var old = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(old.begin(key: "a1", label: "1", background: true))
        m.apply(old.begin(key: "a2", label: "2", background: false))
        m.apply(old.finish(key: "a2", state: "done", result: nil))
        var fresh = SubagentTracker()
        m.apply(fresh.begin(key: "n1", label: "new", background: true))
        XCTAssertEqual(finished(m), ["stopped/bg"], "前の世代の running だけが stopped（終わっていた行は入らない）")
    }

    func testSnapshotDropsRunningRowsAsStopped() {
        var t = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(t.begin(key: "a1", label: "x", background: true))
        m.apply(#"{"subtype":"workflow_snapshot","taskId":"subagents","kind":"subagents","epoch":"\#(t.epoch)","agents":[]}"#)
        XCTAssertEqual(finished(m), ["stopped/bg"])
        XCTAssertEqual(m.counts.agents, 0)
    }

    func testShellRowsAreNotFinished() {
        var t = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(t.begin(key: "b1", label: "dev", background: true, rowKind: "shell", tool: "Bash", command: "npm run dev"))
        m.apply(t.finish(key: "b1", state: "done", result: nil))
        XCTAssertTrue(m.lastFinished.isEmpty)
        var fresh = SubagentTracker()
        m.apply(t.begin(key: "b2", label: "dev", background: true, rowKind: "shell", tool: "Bash", command: "npm run dev"))
        m.apply(fresh.begin(key: "n1", label: "new", background: true))
        XCTAssertTrue(m.lastFinished.isEmpty, "世代が変わっても running の shell は stopped に入れない")
    }

    func testWorkflowFinishedCountsOnceWithOutcome() {
        var m = WorkflowCardMirror()
        m.apply(#"{"subtype":"task_started","taskId":"wf1","workflowName":"a","status":"running"}"#)
        m.apply(#"{"subtype":"task_started","taskId":"wf2","workflowName":"b","status":"running"}"#)
        m.apply(#"{"subtype":"task_started","taskId":"wf3","workflowName":"c","status":"running"}"#)
        XCTAssertTrue(m.lastFinished.isEmpty)
        m.apply(#"{"subtype":"task_notification","taskId":"wf1","status":"completed"}"#)
        XCTAssertEqual(finished(m), ["done/bg"])
        m.apply(#"{"subtype":"task_notification","taskId":"wf1","status":"completed"}"#)
        XCTAssertTrue(m.lastFinished.isEmpty, "終わっていたカードが重ねて届いても数えない")
        m.apply(#"{"subtype":"task_updated","taskId":"wf2","status":"failed","outcome":"stopped"}"#)
        XCTAssertEqual(finished(m), ["stopped/bg"], "outcome が stopped なら stopped")
        m.apply(#"{"subtype":"task_updated","taskId":"wf3","status":"failed"}"#)
        XCTAssertEqual(finished(m), ["failed/bg"])
    }

    // MARK: - 世代と全行

    func testEpochChangeDropsOldRowsAndSnapshotReplacesRows() {
        var old = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(old.begin(key: "a1", label: "old 1", background: true))
        m.apply(old.begin(key: "a2", label: "old 2", background: true))
        XCTAssertEqual(m.counts.agents, 2)

        // 作り直したトラッカー（epoch が違う）の index 0 は、前の世代の index 0 と混ぜない。
        var fresh = SubagentTracker()
        m.apply(fresh.begin(key: "n1", label: "new", background: true))
        XCTAssertEqual(m.subagentsEpoch, fresh.epoch)
        XCTAssertEqual(ids(m.subagentsSnapshot()), ["n1"])
        XCTAssertEqual(m.counts.agents, 1)

        // workflow_snapshot は行を丸ごと置き換える（agents: [] なら行が無い）。
        _ = fresh.finish(key: "n1", state: "stopped", result: nil)
        fresh.pruneFinished()
        m.apply(fresh.snapshot(includeEmpty: true))
        XCTAssertTrue(m.hasSubagents)
        XCTAssertEqual(ids(m.subagentsSnapshot()), [])
        XCTAssertEqual(m.counts, WorkflowCardMirror.Counts())
    }

    func testSubagentRowsAreReplacedOnRestart() {
        var t = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(t.begin(key: "a1", label: "x", background: true))
        m.apply(t.finish(key: "a1", state: "done", result: "1 回目の結果"))
        XCTAssertEqual(rows(m.subagentsSnapshot()).first?["result"] as? String, "1 回目の結果")
        // 再開（同じ key の begin）。行は毎回全項目なので置き換え、前の実行の結果を残さない。
        m.apply(t.begin(key: "a1", label: "x", background: true))
        let row = rows(m.subagentsSnapshot()).first
        XCTAssertEqual(row?["state"] as? String, "running")
        XCTAssertNil(row?["result"])
        XCTAssertNil(row?["endedAtMs"])
    }

    func testSnapshotCarriesKindEpochAndRecountedStatus() {
        var t = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(t.begin(key: "a1", label: "x", background: true))
        m.apply(t.finish(key: "a1", state: "failed", result: "exit code 3"))
        let snap = obj(m.subagentsSnapshot())
        XCTAssertEqual(snap["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(snap["taskId"] as? String, "subagents")
        XCTAssertEqual(snap["kind"] as? String, "subagents")
        XCTAssertEqual(snap["epoch"] as? String, t.epoch)
        XCTAssertEqual(snap["status"] as? String, "failed")

        // 古い Bridge の payload（kind も epoch も無い）も taskId で subagents とみなし、kind を入れて再生する。
        var legacy = WorkflowCardMirror()
        legacy.apply(#"{"subtype":"task_progress","taskId":"subagents","status":"running","agents":[{"index":0,"label":"x","state":"running"}]}"#)
        XCTAssertEqual(obj(legacy.subagentsSnapshot())["kind"] as? String, "subagents")
        XCTAssertEqual(legacy.counts.agents, 1)
        XCTAssertEqual(legacy.workflowSnapshots(unfinishedOnly: false), [], "subagents は workflow として再生しない")
    }

    // MARK: - ターンの区切り

    func testDoneKeepsSubagentsAndUnfinishedWorkflowsAndNewTurnPrunesFinished() {
        var t = SubagentTracker()
        var m = WorkflowCardMirror()
        m.apply(t.begin(key: "a1", label: "動いている", background: true))
        m.apply(t.begin(key: "a2", label: "終わった", background: true))
        m.apply(t.finish(key: "a2", state: "done", result: "ok"))
        m.apply(#"{"subtype":"task_started","taskId":"wf-done","workflowName":"a"}"#)
        m.apply(#"{"subtype":"task_notification","taskId":"wf-done","status":"completed"}"#)
        m.apply(#"{"subtype":"task_started","taskId":"wf-live","workflowName":"b"}"#)

        // ターンの終わり（done）: 終わった workflow だけを捨てる。subagents の終わった行は知らせのターンまで残す。
        m.dropFinishedWorkflows()
        XCTAssertEqual(ids(m.subagentsSnapshot()), ["a1", "a2"])
        XCTAssertEqual(m.workflowSnapshots(unfinishedOnly: false).map { obj($0)["taskId"] as? String }, ["wf-live"])

        // 新しいターン: 終わった行を捨て、動いている行と終わっていない workflow は残す。
        m.pruneFinished()
        XCTAssertEqual(ids(m.subagentsSnapshot()), ["a1"])
        XCTAssertEqual(m.workflowSnapshots(unfinishedOnly: true).map { obj($0)["taskId"] as? String }, ["wf-live"])
        XCTAssertEqual(m.counts, WorkflowCardMirror.Counts(agents: 1, shells: 0, workflows: 1, backgroundOnlyAgents: 1))
    }

    func testIdleReplaysOnlyUnfinishedWorkflows() {
        var m = WorkflowCardMirror()
        m.apply(#"{"subtype":"task_started","taskId":"wf-a","workflowName":"a"}"#)
        m.apply(#"{"subtype":"task_started","taskId":"wf-b","workflowName":"b"}"#)
        m.apply(#"{"subtype":"task_notification","taskId":"wf-a","status":"completed"}"#)
        XCTAssertEqual(m.workflowSnapshots(unfinishedOnly: true).map { obj($0)["taskId"] as? String }, ["wf-b"])
        XCTAssertEqual(m.workflowSnapshots(unfinishedOnly: false).map { obj($0)["taskId"] as? String }, ["wf-a", "wf-b"])
        XCTAssertEqual(obj(m.snapshotJSON(taskId: "wf-b"))["subtype"] as? String, "workflow_snapshot")
    }

    func testRowCountsFromSessionSnapshot() throws {
        var t = SubagentTracker()
        _ = t.begin(key: "a1", label: "x", background: true)
        _ = t.begin(key: "s1", label: "dev", background: true, rowKind: "shell")
        _ = t.begin(key: "a2", label: "y", background: true)
        _ = t.finish(key: "a2", state: "done", result: nil)
        let counts = try XCTUnwrap(WorkflowCardMirror.rowCounts(snapshot: try XCTUnwrap(t.snapshot(includeEmpty: true))))
        XCTAssertEqual(counts.epoch, t.epoch)
        XCTAssertEqual(counts.agents, 1)
        XCTAssertEqual(counts.shells, 1)
        XCTAssertNil(WorkflowCardMirror.rowCounts(snapshot: #"{"subtype":"workflow_snapshot","taskId":"wf","agents":[]}"#))
        XCTAssertNil(WorkflowCardMirror.rowCounts(snapshot: "not json"))
    }

    // MARK: - 完了の push の本文

    func testPushBodyIsHeadOfLastNonEmptyBubble() {
        var b = TurnBubbles()
        XCTAssertNil(b.lastBubble())
        b.append("Explore エージェントで", messageId: "m1")
        b.append("関連ファイルを調べます。", messageId: "m1")
        b.append("\n原因は X でした。修正案: …", messageId: "m2")
        b.append(" \n ", messageId: "m3")   // 空白だけの吹き出しは飛ばす
        XCTAssertEqual(b.lastBubble(), "原因は X でした。修正案: …")

        b.append(String(repeating: "あ", count: 300), messageId: "m4")
        XCTAssertEqual(b.lastBubble(limit: 180), String(repeating: "あ", count: 180))

        b.reset()
        XCTAssertNil(b.lastBubble())
        b.append("messageId の無い本文", messageId: nil)
        XCTAssertEqual(b.lastBubble(), "messageId の無い本文")
    }

    func testBubbleKeepsOnlyBoundedText() {
        var b = TurnBubbles()
        let chunk = String(repeating: "a", count: 1000)
        for _ in 0..<50 { b.append(chunk, messageId: "m1") }
        XCTAssertEqual(b.lastBubble(limit: 10), "aaaaaaaaaa")
        XCTAssertLessThan(b.lastBubble(limit: .max)?.utf8.count ?? 0, TurnBubbles.keepBytes + chunk.utf8.count + 1)
    }

    // MARK: - 定期実行の集め方

    private func progress(_ payload: String?) -> SessionEvent {
        .workflowProgress(agentId: "claude", sessionId: "s", payloadJSON: payload ?? "{}")
    }

    private func delta(_ text: String, _ mid: String) -> SessionEvent {
        .assistantDelta(text, agentId: "claude", sessionId: "s", messageId: mid)
    }

    private func done(_ mid: String) -> SessionEvent { .done(agentId: "claude", sessionId: "s", messageId: mid) }

    /// 知らせのターンの done（metadata.origin = "task-notification"）。
    private func notificationDone(_ mid: String) -> SessionEvent {
        done(mid).addingMetadata(["origin": "task-notification"])
    }

    /// 送った指示のターンが終わる前に閉じた知らせのターンは、指示の返事ではない（本文を捨てて、指示のターンの done を待つ）。
    /// 指示のターンが終わった後の知らせのターンは、今までどおり結果のターンに数える。
    func testCronIgnoresNotificationTurnBeforeOwnTurnEnds() {
        var t = SubagentTracker()
        var c = BridgeCronScheduler.TurnCollector()
        XCTAssertFalse(c.ingest(delta("前の作業が終わりました。", "n1")))
        XCTAssertFalse(c.ingest(notificationDone("n1")), "指示のターンが終わる前の知らせのターンで集め終えた")
        XCTAssertFalse(c.ownTurnEnded)
        XCTAssertFalse(c.waitingForBackground, "指示のターンを待っているのでバックグラウンド待ちにしない")
        XCTAssertFalse(c.turnStarted)
        XCTAssertEqual(c.text, "")

        XCTAssertFalse(c.ingest(delta("調べています。", "m1")))
        XCTAssertFalse(c.ingest(progress(t.begin(key: "a1", label: "調査", background: true))))
        XCTAssertFalse(c.ingest(done("m1")))
        XCTAssertTrue(c.ownTurnEnded)
        XCTAssertTrue(c.waitingForBackground)
        XCTAssertEqual(c.text, "調べています。")

        XCTAssertFalse(c.ingest(progress(t.finish(key: "a1", state: "done", result: "3 件"))))
        XCTAssertFalse(c.ingest(delta("結果: 3 件でした。", "n2")))
        XCTAssertTrue(c.ingest(notificationDone("n2")), "指示のターンの後の知らせのターンは結果のターン")
        XCTAssertEqual(c.text, "結果: 3 件でした。")
    }

    func testCronWaitsForBackgroundAgentAndUsesFinalTurnText() {
        var t = SubagentTracker()
        var c = BridgeCronScheduler.TurnCollector()
        XCTAssertFalse(c.ingest(delta("サブエージェントで調べています。", "m1")))
        XCTAssertFalse(c.ingest(progress(t.begin(key: "a1", label: "調査", background: true))))
        // 最初の done ではまだ動いている → 集め続ける
        XCTAssertFalse(c.ingest(done("m1")))
        XCTAssertTrue(c.waitingForBackground)
        XCTAssertTrue(c.backgroundRunning)
        XCTAssertFalse(c.turnStarted)

        XCTAssertFalse(c.ingest(progress(t.finish(key: "a1", state: "done", result: "3 件"))))
        XCTAssertFalse(c.backgroundRunning)
        // 知らせのターン
        XCTAssertFalse(c.ingest(delta("結果: 問題は 3 件でした。", "m2")))
        XCTAssertTrue(c.turnStarted)
        XCTAssertTrue(c.ingest(done("m2")))
        XCTAssertEqual(c.text, "結果: 問題は 3 件でした。")
    }

    func testCronWaitsForUnfinishedWorkflow() {
        var c = BridgeCronScheduler.TurnCollector()
        XCTAssertFalse(c.ingest(progress(#"{"subtype":"task_started","taskId":"wf","workflowName":"review"}"#)))
        XCTAssertFalse(c.ingest(delta("Workflow launched in background.", "m1")))
        XCTAssertFalse(c.ingest(done("m1")))
        XCTAssertFalse(c.ingest(progress(#"{"subtype":"task_notification","taskId":"wf","status":"completed"}"#)))
        XCTAssertFalse(c.ingest(delta("レビューの結果です。", "m2")))
        XCTAssertTrue(c.ingest(done("m2")))
        XCTAssertEqual(c.text, "レビューの結果です。")
    }

    func testCronDoesNotWaitForBackgroundShellsOnly() {
        var t = SubagentTracker()
        var c = BridgeCronScheduler.TurnCollector()
        XCTAssertFalse(c.ingest(progress(t.begin(key: "b1", label: "dev", background: true, rowKind: "shell"))))
        XCTAssertFalse(c.ingest(delta("起動しました", "m1")))
        XCTAssertTrue(c.ingest(done("m1")))
        XCTAssertEqual(c.text, "起動しました")
    }

    func testCronKeepsEarlierTextWhenFinalTurnIsEmptyAndPartialOnStreamEnd() {
        var t = SubagentTracker()
        var c = BridgeCronScheduler.TurnCollector()
        _ = c.ingest(delta("first", "m1"))
        _ = c.ingest(progress(t.begin(key: "a1", label: "x", background: true)))
        XCTAssertFalse(c.ingest(done("m1")))
        _ = c.ingest(progress(t.finish(key: "a1", state: "stopped", result: nil)))
        XCTAssertTrue(c.ingest(done("m2")), "本文の無い知らせのターンでも、動いているものが無ければ終わる")
        XCTAssertEqual(c.text, "first")

        var partial = BridgeCronScheduler.TurnCollector()
        _ = partial.ingest(delta("途中まで", "m1"))
        partial.finishStream()
        XCTAssertEqual(partial.text, "途中まで")
    }
}
