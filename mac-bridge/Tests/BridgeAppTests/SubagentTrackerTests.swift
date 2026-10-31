import XCTest
@testable import BridgeApp

/// 行は claude の実出力から必要な分だけ抜いたもの。2.1.280（Explore サブエージェントを 1 つ起動）と、
/// 2.1.300 の実測（docs/BACKGROUND_WORK_2026-10-21.md §1。probe-stream の S1〜S14、probe-hooks の A〜G）。
final class SubagentTrackerTests: XCTestCase {
    private func obj(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func row(_ payload: String?) -> [String: Any]? {
        guard let payload else { return nil }
        let o = obj(payload)
        XCTAssertEqual(o["taskId"] as? String, "subagents")
        return (o["agents"] as? [[String: Any]])?.first
    }

    private func rows(_ payload: String?) -> [[String: Any]] {
        guard let payload else { return [] }
        return (obj(payload)["agents"] as? [[String: Any]]) ?? []
    }

    private func status(_ payload: String?) -> String? {
        payload.map { obj($0)["status"] as? String } ?? nil
    }

    private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    func testStreamJsonLifecycle() {
        var t = SubagentTracker()
        let started = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"toolu_P","description":"JSONファイル探索","subagent_type":"Explore","is_backgrounded":true,"task_type":"local_agent"}
        """))
        XCTAssertEqual(row(started)?["label"] as? String, "JSONファイル探索")
        XCTAssertEqual(row(started)?["agentType"] as? String, "Explore")
        XCTAssertEqual(row(started)?["state"] as? String, "running")
        XCTAssertEqual(row(started)?["id"] as? String, "a1")
        XCTAssertEqual(status(started), "running")

        let tool = t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":"toolu_P","message":{"model":"claude-haiku-4-5-20251001","content":[{"type":"tool_use","id":"toolu_G","name":"Glob","input":{"pattern":"*.json"}}]}}
        """))
        XCTAssertEqual(row(tool)?["model"] as? String, "claude-haiku-4-5-20251001")
        XCTAssertEqual(row(tool)?["resultPreview"] as? String, "Glob: *.json")

        let progress = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_progress","task_id":"a1","tool_use_id":"toolu_P","description":"Finding *.json","usage":{"total_tokens":12449,"tool_uses":1,"duration_ms":3434},"last_tool_name":"Glob"}
        """))
        XCTAssertEqual(row(progress)?["toolCalls"] as? Int, 1)
        XCTAssertEqual(row(progress)?["tokens"] as? Int, 12449)
        XCTAssertEqual(row(progress)?["resultPreview"] as? String, "Finding *.json")

        let done = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"a1","tool_use_id":"toolu_P","status":"completed","summary":"見つかったJSONファイル：\\n\\n- **settings.json**","usage":{"total_tokens":13525,"tool_uses":1,"duration_ms":5000}}
        """))
        XCTAssertEqual(row(done)?["state"] as? String, "done")
        XCTAssertEqual(row(done)?["resultPreview"] as? String, "見つかったJSONファイル： - **settings.json**")
        XCTAssertEqual(row(done)?["result"] as? String, "見つかったJSONファイル：\n\n- **settings.json**")
        XCTAssertEqual(row(done)?["durationMs"] as? Int, 5000)
        XCTAssertNotNil(row(done)?["endedAtMs"] as? Int)
        XCTAssertEqual(status(done), "completed")

        t.pruneFinished()
        XCTAssertTrue(t.isEmpty)
    }

    func testIgnoresWorkflows() {
        var t = SubagentTracker()
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"w","task_type":"local_workflow","workflow_name":"review"}
        """)))
        XCTAssertTrue(t.isWorkflowTask("w"))
        // task_notification は task_type も workflow_name も持たない。覚えた id で見分け、行にしない。
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"w","status":"completed","summary":"Workflow review finished"}
        """)))
        // background_tasks_changed に載った workflow も行にしない。
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"w2","run_id":"r","task_type":"local_workflow","description":"review"}]}
        """)))
        XCTAssertTrue(t.isWorkflowTask("w2"))
        XCTAssertFalse(t.isWorkflowTask("a1"))
        // 親の行（parent_tool_use_id が null）はサブエージェントではない。
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}
        """)))
        XCTAssertTrue(t.isEmpty)
    }

    /// バックグラウンドのシェルも行に出す（rowKind = shell）。サブエージェントとは数え分ける。
    func testStreamJsonBackgroundShell() {
        var t = SubagentTracker()
        let started = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"b","task_type":"local_bash","description":"npm run dev"}
        """))
        XCTAssertEqual(row(started)?["label"] as? String, "npm run dev")
        XCTAssertEqual(row(started)?["rowKind"] as? String, "shell")
        XCTAssertNotNil(row(started)?["startedAtMs"] as? Int)
        XCTAssertTrue(t.hasRunning)
        XCTAssertFalse(t.hasRunningAgents)
        XCTAssertEqual(t.runningShellCount, 1)
        let done = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"b","status":"killed","summary":"stopped"}
        """))
        // 止めたものは失敗ではない。
        XCTAssertEqual(row(done)?["state"] as? String, "stopped")
        XCTAssertEqual(status(done), "completed")
    }

    // MARK: - claude 2.1.300 の stream-json

    /// S1: バックグラウンドのサブエージェント。background_tasks_changed が task_started より先に来る。
    /// 終わりは task_updated（end_time）→ task_notification（usage）→ background_tasks_changed []。
    func testBackgroundSubagentLifecycle() {
        var t = SubagentTracker()
        let listed = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","task_type":"local_agent","subagent_type":"general-purpose","description":"sleep probe"}],"uuid":"u1","session_id":"s"}
        """))
        XCTAssertEqual(row(listed)?["id"] as? String, "a57c174413ad17401")
        XCTAssertEqual(row(listed)?["label"] as? String, "sleep probe")
        XCTAssertEqual(row(listed)?["labelIsFallback"] as? Bool, false)
        XCTAssertEqual(row(listed)?["agentType"] as? String, "general-purpose")
        XCTAssertEqual(row(listed)?["rowKind"] as? String, "agent")
        XCTAssertEqual(row(listed)?["background"] as? Bool, true)
        XCTAssertEqual(obj(listed!)["epoch"] as? String, t.epoch)
        XCTAssertEqual(obj(listed!)["kind"] as? String, "subagents")

        let started = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","description":"sleep probe","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent","prompt":"Run the Bash command `sleep 20; echo hi` and report its output exactly as returned."}
        """))
        // 同じ run_id なので再開ではなく、同じ行の続き。
        XCTAssertEqual(row(started)?["index"] as? Int, 0)
        XCTAssertEqual(row(started)?["state"] as? String, "running")
        XCTAssertEqual(rows(t.snapshot()).count, 1)

        let launched = t.ingestStreamLine(obj("""
        {"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","content":"Async agent launched successfully."}]},"tool_use_result":{"isAsync":true,"status":"async_launched","agentId":"a57c174413ad17401","description":"sleep probe","resolvedModel":"claude-haiku-5-5","canReadOutputFile":true,"canContinueAgent":true}}
        """))
        XCTAssertEqual(row(launched)?["model"] as? String, "claude-haiku-5-5")
        XCTAssertEqual(row(launched)?["background"] as? Bool, true)
        XCTAssertEqual(t.runningAgentCount, 1)

        let tool = t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_01NLgsBJ9DMyxtTkphdRxbJJ","name":"Bash","input":{"command":"sleep 20; echo hi","description":"Sleep 20 seconds then echo hi"}}]}}
        """))
        XCTAssertEqual(row(tool)?["resultPreview"] as? String, "Bash: Sleep 20 seconds then echo hi")
        let progress = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_progress","task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","description":"Running Sleep 20 seconds then echo hi","subagent_type":"general-purpose","usage":{"total_tokens":9792,"tool_uses":1,"duration_ms":1987},"last_tool_name":"Bash"}
        """))
        XCTAssertEqual(row(progress)?["resultPreview"] as? String, "Running Sleep 20 seconds then echo hi")
        XCTAssertEqual(row(progress)?["tokens"] as? Int, 9792)

        // サブエージェントの中の前景の Bash（owned_by_subagent、is_backgrounded:false）は行にしない。
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"bew97awf2","run_id":"0mvgqsjr3-d44d1ef2","owned_by_subagent":true,"tool_use_id":"toolu_01NLgsBJ9DMyxtTkphdRxbJJ","description":"Sleep 20 seconds then echo hi","is_backgrounded":false,"parent_task_id":"a57c174413ad17401","task_type":"local_bash"}
        """)))
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"bew97awf2","run_id":"0mvgqsjr3-d44d1ef2","tool_use_id":"toolu_01NLgsBJ9DMyxtTkphdRxbJJ","status":"completed","output_file":"","summary":"Sleep 20 seconds then echo hi"}
        """)))
        XCTAssertEqual(rows(t.snapshot()).count, 1)

        // end_time は今から 1.5 秒後にする（行の開始は今）。所要時間は end_time − 開始で上書きする。
        let end = nowMs() + 1500
        let updated = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_updated","task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","patch":{"status":"completed","end_time":\(end)}}
        """))
        XCTAssertEqual(row(updated)?["state"] as? String, "done")
        XCTAssertEqual(row(updated)?["endedAtMs"] as? Int, end)
        // 実行中の「いまの作業」は結果ではない（空で送り、アプリに残った作業の文を消す）。
        XCTAssertEqual(row(updated)?["resultPreview"] as? String, "")
        let duration = row(updated)?["durationMs"] as? Int ?? -1
        XCTAssertTrue((1300...1800).contains(duration), "durationMs = \(duration)")

        let notified = t.ingestStreamLine(obj(#"""
        {"type":"system","subtype":"task_notification","task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","status":"completed","output_file":"/tmp/tasks/a57c174413ad17401.output","summary":"The command returned:\n\n```\nhi\n```","usage":{"total_tokens":10483,"tool_uses":1,"duration_ms":24486}}
        """#))
        XCTAssertEqual(row(notified)?["resultPreview"] as? String, "The command returned: ``` hi ```")
        XCTAssertEqual(row(notified)?["result"] as? String, "The command returned:\n\n```\nhi\n```")
        // usage の duration_ms を優先する。
        XCTAssertEqual(row(notified)?["durationMs"] as? Int, 24486)
        XCTAssertEqual(row(notified)?["tokens"] as? Int, 10483)
        XCTAssertEqual(row(notified)?["toolCalls"] as? Int, 1)
        XCTAssertEqual(row(notified)?["endedAtMs"] as? Int, end)
        XCTAssertEqual(status(notified), "completed")

        // 終われば []。閉じる行はもう無い。
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[]}
        """)))
        XCTAssertFalse(t.hasRunning)
    }

    /// S8: 2〜5 秒を超えた前景の Bash もタスクになるが、行にはしない（ツールの行と二重になる）。
    func testForegroundBashIsNotARow() {
        var t = SubagentTracker()
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_01MpLdfbFUH6GTKbfAtxTgV7","name":"Bash","input":{"command":"sleep 10; echo fg","description":"Sleep 10 seconds then echo fg"}}]}}
        """)))
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"b9bxo2mkw","run_id":"0mvgr1z4g-fcdbce7b","tool_use_id":"toolu_01MpLdfbFUH6GTKbfAtxTgV7","description":"Sleep 10 seconds then echo fg","is_backgrounded":false,"task_type":"local_bash"}
        """)))
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"b9bxo2mkw","run_id":"0mvgr1z4g-fcdbce7b","tool_use_id":"toolu_01MpLdfbFUH6GTKbfAtxTgV7","status":"completed","output_file":"","summary":"Sleep 10 seconds then echo fg"}
        """)))
        XCTAssertTrue(t.isEmpty)

        // 前景で始まったシェルが後から裏に回されたら（task_updated の is_backgrounded）、その時点で行にする。
        _ = t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"toolu_dev","name":"Bash","input":{"command":"npm run dev","description":"Start dev server"}}]}}
        """))
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"bdev","run_id":"r1","tool_use_id":"toolu_dev","description":"Start dev server","is_backgrounded":false,"task_type":"local_bash"}
        """)))
        let promoted = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_updated","task_id":"bdev","run_id":"r1","patch":{"is_backgrounded":true}}
        """))
        XCTAssertEqual(row(promoted)?["rowKind"] as? String, "shell")
        XCTAssertEqual(row(promoted)?["background"] as? Bool, true)
        XCTAssertEqual(row(promoted)?["tool"] as? String, "Bash")
        XCTAssertEqual(row(promoted)?["command"] as? String, "npm run dev")
    }

    /// S3r / S14: run_in_background の Bash は行になる（tool と command は main の tool_use から）。
    /// exit code ≠ 0 の本当の失敗だけが failed。理由は summary。
    func testBackgroundBashRowAndRealFailure() {
        var t = SubagentTracker()
        _ = t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_01DJZLdsqwDVu7vtcG1JRFuK","name":"Bash","input":{"command":"sleep 4; echo bad; exit 3","description":"Run sleep-and-echo command in background","run_in_background":true}}]}}
        """))
        _ = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bu2tmpln2","run_id":"0mvgr5vn0-f3e30550","task_type":"local_bash","description":"Run sleep-and-echo command in background"}]}
        """))
        let started = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"bu2tmpln2","run_id":"0mvgr5vn0-f3e30550","tool_use_id":"toolu_01DJZLdsqwDVu7vtcG1JRFuK","description":"Run sleep-and-echo command in background","is_backgrounded":true,"task_type":"local_bash"}
        """))
        XCTAssertEqual(row(started)?["rowKind"] as? String, "shell")
        XCTAssertEqual(row(started)?["tool"] as? String, "Bash")
        XCTAssertEqual(row(started)?["command"] as? String, "sleep 4; echo bad; exit 3")
        XCTAssertEqual(row(started)?["background"] as? Bool, true)
        XCTAssertEqual(t.runningShellCount, 1)
        XCTAssertFalse(t.hasRunningAgents)

        let updated = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_updated","task_id":"bu2tmpln2","run_id":"0mvgr5vn0-f3e30550","patch":{"status":"failed","end_time":\(nowMs())}}
        """))
        XCTAssertEqual(row(updated)?["state"] as? String, "failed")
        let notified = t.ingestStreamLine(obj(#"""
        {"type":"system","subtype":"task_notification","task_id":"bu2tmpln2","run_id":"0mvgr5vn0-f3e30550","tool_use_id":"toolu_01DJZLdsqwDVu7vtcG1JRFuK","status":"failed","output_file":"/tmp/tasks/bu2tmpln2.output","summary":"Background command \"Run sleep-and-echo command in background\" failed with exit code 3"}
        """#))
        XCTAssertEqual(row(notified)?["state"] as? String, "failed")
        XCTAssertEqual(row(notified)?["resultPreview"] as? String,
                       "Background command \"Run sleep-and-echo command in background\" failed with exit code 3")
        XCTAssertEqual(status(notified), "failed")
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[]}
        """)))
    }

    /// S4: Monitor は task_type が local_bash（monitor_* ではない）。main の tool_use の名前で見分ける。
    func testMonitorIsRecognisedFromToolUse() {
        var t = SubagentTracker()
        _ = t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_017t2KGSedEbo8zEHZcmrjaW","name":"Monitor","input":{"command":"for i in 1 2 3; do echo tick $i; sleep 6; done","description":"tick probe","timeout_ms":60000}}]}}
        """))
        let listed = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bjx7sds73","run_id":"0mvgqsig5-a17e9012","task_type":"local_bash","description":"tick probe"}]}
        """))
        XCTAssertEqual(row(listed)?["label"] as? String, "tick probe")
        let started = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"bjx7sds73","run_id":"0mvgqsig5-a17e9012","tool_use_id":"toolu_017t2KGSedEbo8zEHZcmrjaW","description":"tick probe","is_backgrounded":true,"task_type":"local_bash"}
        """))
        XCTAssertEqual(row(started)?["tool"] as? String, "Monitor")
        XCTAssertEqual(row(started)?["command"] as? String, "for i in 1 2 3; do echo tick $i; sleep 6; done")
        XCTAssertEqual(row(started)?["rowKind"] as? String, "shell")
        XCTAssertEqual(row(started)?["index"] as? Int, 0)
        _ = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_updated","task_id":"bjx7sds73","run_id":"0mvgqsig5-a17e9012","patch":{"status":"completed","end_time":\(nowMs())}}
        """))
        let done = t.ingestStreamLine(obj(#"""
        {"type":"system","subtype":"task_notification","task_id":"bjx7sds73","run_id":"0mvgqsig5-a17e9012","tool_use_id":"toolu_017t2KGSedEbo8zEHZcmrjaW","status":"completed","output_file":"/tmp/tasks/bjx7sds73.output","summary":"Monitor \"tick probe\" stream ended"}
        """#))
        XCTAssertEqual(row(done)?["state"] as? String, "done")
        XCTAssertEqual(row(done)?["resultPreview"] as? String, "Monitor \"tick probe\" stream ended")
    }

    /// S5a / S6c: TaskStop・interrupt・SIGINT・後片付けは task_updated killed / task_notification stopped。
    /// 失敗ではなく stopped。summary は説明そのままなので結果にしない。
    func testKilledIsStoppedNotFailed() {
        var t = SubagentTracker()
        _ = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"bqyx93sk0","run_id":"0mvgr1yqk-bf76503d","tool_use_id":"toolu_01TRtrHQBdMRhVyUHNsnNpYv","description":"Sleep 61 seconds then echo late","is_backgrounded":true,"task_type":"local_bash"}
        """))
        let killed = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_updated","task_id":"bqyx93sk0","run_id":"0mvgr1yqk-bf76503d","patch":{"status":"killed","end_time":\(nowMs())}}
        """))
        XCTAssertEqual(row(killed)?["state"] as? String, "stopped")
        // 古いアプリ向けの要約では stopped は失敗に数えない。
        XCTAssertEqual(status(killed), "completed")
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"bqyx93sk0","run_id":"0mvgr1yqk-bf76503d","tool_use_id":"toolu_01TRtrHQBdMRhVyUHNsnNpYv","status":"stopped","output_file":"/tmp/tasks/bqyx93sk0.output","summary":"Sleep 61 seconds then echo late"}
        """)))
        // 同じ実行の中では、あとから completed が来ても done に戻らない。
        XCTAssertNil(t.finish(key: "bqyx93sk0", state: "done", result: "late"))
        let first = rows(t.snapshot()).first
        XCTAssertEqual(first?["state"] as? String, "stopped")
        XCTAssertEqual(first?["result"] as? String, "")

        // S6c（SIGINT）: notification が updated より先に来る。end_time は後からでも反映する。
        _ = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"brkso4yke","run_id":"0mvgr23y0-61a359ee","owned_by_subagent":true,"tool_use_id":"toolu_01EaYd5Pneqmb9hRw6z8N1M5","description":"Sleep 27 seconds then echo hi","is_backgrounded":true,"parent_task_id":"aa7b6ff1a6cd9e144","task_type":"local_bash"}
        """))
        let stopped = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"brkso4yke","run_id":"0mvgr23y0-61a359ee","tool_use_id":"toolu_01EaYd5Pneqmb9hRw6z8N1M5","status":"stopped","output_file":"","summary":"Sleep 27 seconds then echo hi"}
        """))
        XCTAssertEqual(row(stopped)?["state"] as? String, "stopped")
        XCTAssertEqual(row(stopped)?["parentId"] as? String, "aa7b6ff1a6cd9e144")
        let end = nowMs() + 2000
        let updated = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_updated","task_id":"brkso4yke","run_id":"0mvgr23y0-61a359ee","patch":{"status":"killed","end_time":\(end)}}
        """))
        XCTAssertEqual(row(updated)?["endedAtMs"] as? Int, end)
        XCTAssertEqual(row(updated)?["state"] as? String, "stopped")
    }

    /// S7: 終わったサブエージェントが、同じ task_id・新しい run_id で再開する。行を実行中に戻してやり直し、
    /// 前の実行の遅れて届いた行は捨てる。
    func testRestartWithNewRunIdReopens() {
        var t = SubagentTracker()
        _ = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqsgen-7a08e34c","tool_use_id":"toolu_01VzL1Mfsd2NNKScsRqdVLit","description":"followup probe","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent"}
        """))
        _ = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_updated","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqsgen-7a08e34c","patch":{"status":"completed","end_time":\(nowMs())}}
        """))
        let first = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqsgen-7a08e34c","tool_use_id":"toolu_01VzL1Mfsd2NNKScsRqdVLit","status":"completed","summary":"The foreground run was blocked, so I started it in the background.","usage":{"total_tokens":11200,"tool_uses":2,"duration_ms":8400}}
        """))
        XCTAssertEqual(row(first)?["state"] as? String, "done")
        XCTAssertEqual(row(first)?["durationMs"] as? Int, 8400)

        // 再開は background_tasks_changed（新しい run_id）が task_started より先に来る。
        let reopened = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"aaa2e86b2db1ba716","run_id":"0mvgqtd1y-c82e5ef4","task_type":"local_agent","subagent_type":"general-purpose","description":"followup probe"}]}
        """))
        XCTAssertEqual(row(reopened)?["state"] as? String, "running")
        XCTAssertEqual(row(reopened)?["index"] as? Int, 0)
        XCTAssertNil(row(reopened)?["durationMs"])
        XCTAssertEqual(row(reopened)?["resultPreview"] as? String, "")
        XCTAssertNil(row(reopened)?["result"])
        XCTAssertNil(row(reopened)?["endedAtMs"])
        // 同じ run_id の task_started は二重にやり直さない。
        let started = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqtd1y-c82e5ef4","tool_use_id":"toolu_01VzL1Mfsd2NNKScsRqdVLit","description":"followup probe","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent","prompt":"<task-notification>…"}
        """))
        XCTAssertEqual(row(started)?["startedAtMs"] as? Int, row(reopened)?["startedAtMs"] as? Int)
        // 前の実行の遅れて届いた知らせは捨てる。
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_notification","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqsgen-7a08e34c","status":"completed","summary":"old"}
        """)))
        let progress = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_progress","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqtd1y-c82e5ef4","description":"Reading bzihmbpeo","subagent_type":"general-purpose","usage":{"total_tokens":11865,"tool_uses":3,"duration_ms":43806},"last_tool_name":"Read"}
        """))
        XCTAssertEqual(row(progress)?["resultPreview"] as? String, "Reading bzihmbpeo")
        let done = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_updated","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqtd1y-c82e5ef4","patch":{"status":"completed","end_time":\(nowMs())}}
        """))
        XCTAssertEqual(row(done)?["state"] as? String, "done")
        // background_tasks_changed を取りこぼしても、終わった行への task_started で再開する。
        let again = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"aaa2e86b2db1ba716","run_id":"third","tool_use_id":"toolu_01VzL1Mfsd2NNKScsRqdVLit","description":"followup probe","subagent_type":"general-purpose","is_backgrounded":true,"task_type":"local_agent"}
        """))
        XCTAssertEqual(row(again)?["state"] as? String, "running")
        XCTAssertEqual(rows(t.snapshot()).count, 1)
    }

    /// S2: background_tasks_changed に載っていない background の行（サブエージェントが起こしたシェル）は done で閉じるが、
    /// 前景のサブエージェント（is_backgrounded:false。一覧には載らない）は閉じない。
    func testBackgroundTasksChangedClosesOnlyBackgroundRows() {
        var t = SubagentTracker()
        let b = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"a79ab777d21c0dcd9","run_id":"0mvgqsh4q-0d8ebd56","tool_use_id":"toolu_016ogRUek8Agmdc4CARfVpLg","description":"probe B","subagent_type":"general-purpose","is_backgrounded":false,"spawn_depth":1,"task_type":"local_agent"}
        """))
        XCTAssertEqual(row(b)?["background"] as? Bool, false)
        _ = t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":"toolu_016ogRUek8Agmdc4CARfVpLg","message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_01JeTqykjewGCFtrNqr69MUt","name":"Bash","input":{"command":"sleep 31; echo B","description":"Sleep 31 seconds then echo B","run_in_background":true}}]}}
        """))
        _ = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bnebie9kn","run_id":"0mvgqskoi-f48d5ae7","task_type":"local_bash","description":"Sleep 31 seconds then echo B","parent_task_id":"a79ab777d21c0dcd9"}]}
        """))
        let shell = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"bnebie9kn","run_id":"0mvgqskoi-f48d5ae7","owned_by_subagent":true,"tool_use_id":"toolu_01JeTqykjewGCFtrNqr69MUt","description":"Sleep 31 seconds then echo B","is_backgrounded":true,"parent_task_id":"a79ab777d21c0dcd9","task_type":"local_bash"}
        """))
        XCTAssertEqual(row(shell)?["parentId"] as? String, "a79ab777d21c0dcd9")
        XCTAssertEqual(row(shell)?["tool"] as? String, "Bash")
        XCTAssertEqual(row(shell)?["command"] as? String, "sleep 31; echo B")
        // 前景のサブエージェントの中の前景の Bash は行にしない。
        XCTAssertNil(t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"bn40n3gxw","run_id":"0mvgqsmxb-5f9f4650","owned_by_subagent":true,"tool_use_id":"toolu_011CjR3w6nnmYNWTBjFyF8Uo","description":"Sleep 16 seconds then echo A","is_backgrounded":false,"parent_task_id":"afb1dfb27dee16255","task_type":"local_bash"}
        """)))
        // シェルの終わりを取りこぼしても、一覧から消えたら閉じる。前景のサブエージェントはそのまま。
        let closed = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[]}
        """))
        XCTAssertEqual(rows(closed).compactMap { $0["id"] as? String }, ["bnebie9kn"])
        XCTAssertEqual(row(closed)?["state"] as? String, "done")
        XCTAssertTrue(t.hasRunningAgents)
        XCTAssertEqual(t.runningShellCount, 0)
        // hooks の Stop（closeForeground 既定 true）なら前景の行も閉じる。
        XCTAssertEqual(row(t.reconcile(backgroundTasks: [[String: Any]]()))?["id"] as? String, "a79ab777d21c0dcd9")
        XCTAssertFalse(t.hasRunning)
    }

    // MARK: - hooks（ターミナル）

    func testHooksLifecycle() {
        var t = SubagentTracker()
        // 親の PreToolUse(Agent) → SubagentStart → サブエージェント内の PreToolUse → SubagentStop
        t.noteLaunch(toolName: "Agent", input: ["description": "JSONファイル探索", "subagent_type": "Explore", "prompt": "…"])
        let started = t.hookStart(agentId: "a1", agentType: "Explore")
        XCTAssertEqual(row(started)?["label"] as? String, "JSONファイル探索")

        let tool = t.hookTool(agentId: "a1", agentType: "Explore", toolName: "Glob", input: ["pattern": "*.json"])
        XCTAssertEqual(row(tool)?["toolCalls"] as? Int, 1)
        XCTAssertEqual(row(tool)?["resultPreview"] as? String, "Glob: *.json")
        XCTAssertTrue(t.hasRunning)

        let stopped = t.hookStop(agentId: "a1", agentType: "Explore", lastMessage: "settings.json のみ")
        XCTAssertEqual(row(stopped)?["state"] as? String, "done")
        XCTAssertEqual(row(stopped)?["resultPreview"] as? String, "settings.json のみ")
        XCTAssertEqual(row(stopped)?["result"] as? String, "settings.json のみ")
        XCTAssertFalse(t.hasRunning)
    }

    func testParallelHookLaunchesMatchByType() {
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Agent", input: ["description": "調査A", "subagent_type": "Explore"])
        t.noteLaunch(toolName: "Agent", input: ["description": "計画B", "subagent_type": "Plan"])
        t.noteLaunch(toolName: "Read", input: ["file_path": "/x"])   // Agent 以外は無視
        XCTAssertEqual(row(t.hookStart(agentId: "p", agentType: "Plan"))?["label"] as? String, "計画B")
        XCTAssertEqual(row(t.hookStart(agentId: "e", agentType: "Explore"))?["label"] as? String, "調査A")
        // SubagentStart を受けていないサブエージェントのツールは行を作らない（呼び出し側が親のツール行に出す）。
        XCTAssertNil(t.hookTool(agentId: "z", agentType: "general-purpose", toolName: "Bash", input: nil))
        XCTAssertFalse(t.contains("z"))
        // 説明が空なら種類名を出す（既定文。新しいアプリは labelIsFallback を見て自分の言語で出す）。
        t.noteLaunch(toolName: "Agent", input: ["subagent_type": "general-purpose"])
        let fallback = row(t.hookStart(agentId: "z", agentType: "general-purpose"))
        XCTAssertEqual(fallback?["label"] as? String, "general-purpose")
        XCTAssertEqual(fallback?["labelIsFallback"] as? Bool, true)
        // 実行中のものは pruneFinished で消えない。
        t.pruneFinished()
        XCTAssertFalse(t.isEmpty)
        let snap = obj(t.snapshot()!)
        XCTAssertEqual((snap["agents"] as? [[String: Any]])?.compactMap { $0["index"] as? Int }, [0, 1, 2])
    }

    /// 内部の補助（agent_type が空か無い SubagentStart）は行にしない。結果が「そのまま続けて」のような発話の
    /// 「サブエージェント」行が出ていた。
    func testSubagentStartWithoutLaunchIsIgnored() {
        var t = SubagentTracker()
        XCTAssertNil(t.hookStart(agentId: "s1", agentType: ""))
        XCTAssertTrue(t.isIgnored("s1"))
        XCTAssertNil(t.hookStop(agentId: "s1", agentType: "", lastMessage: "そのまま続けて"))
        XCTAssertTrue(t.isEmpty)
        // SendMessage で話しかけ直したサブエージェントは出す。
        t.noteLaunch(toolName: "SendMessage", input: ["to": "a1", "message": "続きを調べて", "summary": "続きの調査"])
        XCTAssertEqual(row(t.hookStart(agentId: "a1", agentType: "general-purpose"))?["label"] as? String, "続きの調査")
    }

    /// 2.1.300: Stop のたびに来る次の発話の候補づくり（SubagentStop の agent_type: ""）と、バックグラウンドの
    /// エージェントの要約（PreToolUse に agent_type キーが無い）は内部の補助。
    func testInternalHelperDetection() {
        let suggestion = obj("""
        {"agent_id":"ad7946b3eb4bb42a7","agent_type":"","hook_event_name":"SubagentStop","stop_hook_active":false,"last_assistant_message":"check on sleeper A","background_tasks":[{"id":"adecffdf418d355ef","type":"subagent","status":"running","description":"probe sleeper A","agent_type":"general-purpose"}],"session_crons":[]}
        """)
        XCTAssertTrue(SubagentTracker.isInternalHelper(agentId: suggestion["agent_id"] as? String,
                                                       agentType: suggestion["agent_type"]))
        let summarizer = obj("""
        {"agent_id":"a9ffe224a77f5eda2","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ping -c 40 127.0.0.1 > /dev/null; echo hi"},"tool_use_id":"toolu_01F6CFcapFeqbUriAzCy4vdW"}
        """)
        XCTAssertTrue(SubagentTracker.isInternalHelper(agentId: summarizer["agent_id"] as? String,
                                                       agentType: summarizer["agent_type"]))
        XCTAssertTrue(SubagentTracker.isInternalHelper(agentId: "a1", agentType: NSNull()))
        XCTAssertFalse(SubagentTracker.isInternalHelper(agentId: "adecffdf418d355ef", agentType: "general-purpose"))
        // main のスレッドの hook（agent_id が無い）は補助ではない。
        XCTAssertFalse(SubagentTracker.isInternalHelper(agentId: nil, agentType: nil))

        // 補助の SubagentStart は起動待ちを使わない（本物の SubagentStart が説明を受け取る）。
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Agent", input: ["description": "probe sleeper A", "subagent_type": "general-purpose"])
        XCTAssertNil(t.hookStart(agentId: "ad7946b3eb4bb42a7", agentType: ""))
        XCTAssertEqual(row(t.hookStart(agentId: "adecffdf418d355ef", agentType: "general-purpose"))?["label"] as? String,
                       "probe sleeper A")
    }

    /// PostToolUse(Agent) の async_launched と agentId で、説明をその id の行に結び付ける。SubagentStart より
    /// 先に来ることがある（probe-hooks C / C2）。後から来た SubagentStart は起動待ちを使わずに同じ行の続きにする。
    func testPostToolUseAgentBeforeSubagentStart() {
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Agent", input: ["description": "probe sleeper C", "subagent_type": "general-purpose",
                                                "prompt": "Run the Bash command `sleep 45; echo hi`"],
                     toolUseId: "toolu_01SQpCCyhZTNaC2GguVSTXPN")
        let hook = obj("""
        {"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"probe sleeper C","prompt":"Run the Bash command `sleep 45; echo hi`","subagent_type":"general-purpose"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"ae2e9cbe3e734c8cb","description":"probe sleeper C","resolvedModel":"claude-haiku-5-5","outputFile":"/tmp/tasks/ae2e9cbe3e734c8cb.output","canReadOutputFile":true,"canContinueAgent":true},"tool_use_id":"toolu_01SQpCCyhZTNaC2GguVSTXPN","duration_ms":13}
        """)
        let bound = t.hookToolResult(toolUseId: hook["tool_use_id"] as? String, toolName: "Agent",
                                     input: hook["tool_input"], response: hook["tool_response"])
        XCTAssertEqual(row(bound)?["id"] as? String, "ae2e9cbe3e734c8cb")
        XCTAssertEqual(row(bound)?["label"] as? String, "probe sleeper C")
        XCTAssertEqual(row(bound)?["agentType"] as? String, "general-purpose")
        XCTAssertEqual(row(bound)?["background"] as? Bool, true)
        XCTAssertEqual(row(bound)?["model"] as? String, "claude-haiku-5-5")

        t.noteLaunch(toolName: "Agent", input: ["description": "next one", "subagent_type": "general-purpose"],
                     toolUseId: "toolu_next")
        let started = t.hookStart(agentId: "ae2e9cbe3e734c8cb", agentType: "general-purpose")
        XCTAssertEqual(row(started)?["index"] as? Int, 0)
        XCTAssertEqual(row(started)?["label"] as? String, "probe sleeper C")
        // 起動待ちは残っているので、次のサブエージェントが自分の説明を受け取る。
        XCTAssertEqual(row(t.hookStart(agentId: "a2", agentType: "general-purpose"))?["label"] as? String, "next one")
    }

    /// SubagentStart が先に来たとき（probe-hooks A）。PostToolUse(Agent) で background を付ける。
    /// 並列の同じ種類で SubagentStart の順がずれても、PostToolUse(Agent) で正しい説明に直る。
    func testPostToolUseAgentAfterSubagentStart() {
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Agent", input: ["description": "probe sleeper A", "subagent_type": "general-purpose"],
                     toolUseId: "toolu_01RkBL9LaBTzzECsVUukefrE")
        XCTAssertNil(row(t.hookStart(agentId: "adecffdf418d355ef", agentType: "general-purpose"))?["background"])
        let bound = t.hookToolResult(
            toolUseId: "toolu_01RkBL9LaBTzzECsVUukefrE", toolName: "Agent",
            input: ["description": "probe sleeper A", "subagent_type": "general-purpose"],
            response: ["isAsync": true, "status": "async_launched", "agentId": "adecffdf418d355ef",
                       "description": "probe sleeper A", "resolvedModel": "claude-haiku-5-5"])
        XCTAssertEqual(row(bound)?["background"] as? Bool, true)
        XCTAssertEqual(row(bound)?["label"] as? String, "probe sleeper A")
        XCTAssertEqual(rows(t.snapshot()).count, 1)

        t.noteLaunch(toolName: "Agent", input: ["description": "A1", "subagent_type": "Explore"], toolUseId: "t1")
        t.noteLaunch(toolName: "Agent", input: ["description": "A2", "subagent_type": "Explore"], toolUseId: "t2")
        // x は本当は A2（t2）だが、順番どおり A1 を受け取る。
        XCTAssertEqual(row(t.hookStart(agentId: "x", agentType: "Explore"))?["label"] as? String, "A1")
        let fixed = t.hookToolResult(toolUseId: "t2", toolName: "Agent", input: ["description": "A2", "subagent_type": "Explore"],
                                     response: ["status": "async_launched", "agentId": "x"])
        XCTAssertEqual(row(fixed)?["label"] as? String, "A2")
        // t1 は x が使い、t2 は PostToolUse で消えたので、y の SubagentStart には起動待ちが無い。
        XCTAssertNil(t.hookStart(agentId: "y", agentType: "Explore"))
        XCTAssertTrue(t.isIgnored("y"))
        let y = t.hookToolResult(toolUseId: "t1", toolName: "Agent", input: ["description": "A1", "subagent_type": "Explore"],
                                 response: ["status": "async_launched", "agentId": "y"])
        XCTAssertEqual(row(y)?["label"] as? String, "A1")
        XCTAssertFalse(t.isIgnored("y"))
    }

    /// SendMessage は宛先（to）の id とだけ突き合わせる。動いている相手への SendMessage は積まない。
    func testSendMessageMatchesOnlyItsTarget() {
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Agent", input: ["description": "依存関係を調べる", "subagent_type": "Explore"], toolUseId: "tA")
        _ = t.hookStart(agentId: "a1", agentType: "Explore")
        // 動いている a1 への SendMessage は次のツールの区切りで届くだけ（SubagentStart は来ない）。
        t.noteLaunch(toolName: "SendMessage", input: ["to": "a1", "message": "ついでに", "summary": "追加の依頼"])
        // 止まった a9 への SendMessage は、a9 の SubagentStart とだけ突き合わせる。
        t.noteLaunch(toolName: "SendMessage", input: ["to": "a9", "message": "続きを調べて", "summary": "続きの調査"])
        t.noteLaunch(toolName: "Agent", input: ["description": "設定を調べる", "subagent_type": "Explore"], toolUseId: "tB")
        XCTAssertEqual(row(t.hookStart(agentId: "b2", agentType: "Explore"))?["label"] as? String, "設定を調べる")
        XCTAssertEqual(row(t.hookStart(agentId: "a9", agentType: "general-purpose"))?["label"] as? String, "続きの調査")
        // 知っている行の SubagentStart は、起動待ちを使わずに再開する。
        _ = t.hookStop(agentId: "a1", agentType: "Explore", lastMessage: "done")
        let resumed = t.hookStart(agentId: "a1", agentType: "Explore")
        XCTAssertEqual(row(resumed)?["state"] as? String, "running")
        XCTAssertEqual(row(resumed)?["label"] as? String, "依存関係を調べる")
        XCTAssertNil(row(resumed)?["result"])
    }

    /// run_in_background の Bash は PostToolUse の backgroundTaskId で行になり、完了の知らせで閉じる。
    func testHooksBackgroundShellLifecycle() {
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Bash", input: ["command": "for i in $(seq 1 60); do dig …; done",
                                               "description": "DNS の反映を待つ", "run_in_background": true],
                     toolUseId: "toolu_B")
        let started = t.hookToolResult(toolUseId: "toolu_B", toolName: "Bash", input: nil,
                                       response: ["stdout": "", "backgroundTaskId": "b0fz5vnji"])
        XCTAssertEqual(row(started)?["label"] as? String, "DNS の反映を待つ")
        XCTAssertEqual(row(started)?["rowKind"] as? String, "shell")
        XCTAssertEqual(row(started)?["tool"] as? String, "Bash")
        XCTAssertEqual(row(started)?["background"] as? Bool, true)
        // 前景の Bash（backgroundTaskId が無い）は行にしない。
        XCTAssertNil(t.hookToolResult(toolUseId: "toolu_C", toolName: "Bash", input: nil, response: ["stdout": "ok"]))
        // Esc の中断ではシェルは閉じない。
        XCTAssertNil(t.abandonRunning(includeShells: false))
        let text = """
        <task-notification>
        <task-id>b0fz5vnji</task-id>
        <tool-use-id>toolu_B</tool-use-id>
        <status>completed</status>
        <summary>Background command "DNS の反映を待つ" completed (exit code 0)</summary>
        </task-notification>
        """
        let done = t.ingestNotifications(text)
        XCTAssertEqual(done.count, 1)
        XCTAssertEqual(row(done.first)?["state"] as? String, "done")
        XCTAssertEqual(row(done.first)?["resultPreview"] as? String,
                       "Background command \"DNS の反映を待つ\" completed (exit code 0)")
        XCTAssertEqual(SubagentTracker.stripNotifications(text + "\n続けて"), "続けて")
    }

    /// PostToolUse(TaskStop) の tool_response.task_id の行は、すぐ stopped で閉じる（止めたシェルには知らせが来ない。
    /// probe-hooks G）。Monitor の PostToolUse は tool_response.taskId で行にする。
    func testTaskStopHookClosesRowAsStopped() {
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Bash", input: ["command": "ping 127.0.0.1 > /dev/null", "run_in_background": true],
                     toolUseId: "toolu_G")
        let started = t.hookToolResult(toolUseId: "toolu_G", toolName: "Bash",
                                       input: ["command": "ping 127.0.0.1 > /dev/null", "run_in_background": true],
                                       response: ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": "bc3mclkys"])
        XCTAssertEqual(row(started)?["command"] as? String, "ping 127.0.0.1 > /dev/null")
        let hook = obj("""
        {"hook_event_name":"PostToolUse","tool_name":"TaskStop","tool_input":{"task_id":"bc3mclkys"},"tool_response":{"message":"Successfully stopped task: bc3mclkys (ping 127.0.0.1 > /dev/null)","task_id":"bc3mclkys","task_type":"local_bash","command":"ping 127.0.0.1 > /dev/null"},"tool_use_id":"toolu_017vzJEvJeao6HGgVVYzRtUg","duration_ms":108}
        """)
        let stopped = t.hookToolResult(toolUseId: hook["tool_use_id"] as? String, toolName: "TaskStop",
                                       input: hook["tool_input"], response: hook["tool_response"])
        XCTAssertEqual(row(stopped)?["state"] as? String, "stopped")
        XCTAssertNotNil(row(stopped)?["endedAtMs"] as? Int)
        XCTAssertEqual(status(stopped), "completed")
        // 次の Stop（一覧は空）でも done に変わらない。
        XCTAssertNil(t.reconcile(backgroundTasks: [[String: Any]]()))
        XCTAssertEqual(rows(t.snapshot()).first?["state"] as? String, "stopped")

        let monitor = t.hookToolResult(toolUseId: "toolu_M", toolName: "Monitor",
                                       input: ["command": "tail -f app.log", "description": "watch app log"],
                                       response: ["taskId": "bm1", "timeoutMs": 60000, "persistent": false])
        XCTAssertEqual(row(monitor)?["tool"] as? String, "Monitor")
        XCTAssertEqual(row(monitor)?["label"] as? String, "watch app log")
        XCTAssertEqual(row(monitor)?["rowKind"] as? String, "shell")
    }

    /// task-notification の XML（probe-hooks A）は <result> を結果に、<usage> を数値にする。
    /// <summary> の決まり文句（Agent "…" finished）で、既に結果のある終わった行を上書きしない。
    func testNotificationXmlWithResultAndUsage() {
        let text = #"""
        <task-notification>
        <task-id>adecffdf418d355ef</task-id>
        <tool-use-id>toolu_01RkBL9LaBTzzECsVUukefrE</tool-use-id>
        <output-file>/tmp/tasks/adecffdf418d355ef.output</output-file>
        <status>completed</status>
        <summary>Agent "probe sleeper A" finished</summary>
        <note>A task-notification fires each time this agent stops with no live background children of its own. The user can send it another message and resume it, so the same task-id may notify more than once.</note>
        <result>hi</result>
        <usage><subagent_tokens>24570</subagent_tokens><tool_uses>1</tool_uses><duration_ms>24935</duration_ms></usage>
        </task-notification>
        """#
        XCTAssertEqual(SubagentTracker.taskNotifications(in: text), [
            SubagentTracker.TaskNotification(taskId: "adecffdf418d355ef", status: "completed",
                                             summary: "Agent \"probe sleeper A\" finished", result: "hi",
                                             tokens: 24570, toolUses: 1, durationMs: 24935),
        ])

        var t = SubagentTracker()
        t.noteLaunch(toolName: "Agent", input: ["description": "probe sleeper A", "subagent_type": "general-purpose"])
        _ = t.hookStart(agentId: "adecffdf418d355ef", agentType: "general-purpose")
        XCTAssertEqual(row(t.hookStop(agentId: "adecffdf418d355ef", agentType: "general-purpose", lastMessage: "hi"))?["state"]
                       as? String, "done")
        let p = t.ingestNotifications(text)
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(row(p.first)?["resultPreview"] as? String, "hi")
        XCTAssertEqual(row(p.first)?["tokens"] as? Int, 24570)
        XCTAssertEqual(row(p.first)?["toolCalls"] as? Int, 1)
        XCTAssertEqual(row(p.first)?["durationMs"] as? Int, 24935)

        // 同じ task-id がもう一度届いても、<result> が無ければ決まり文句で上書きしない。
        let again = t.ingestNotifications("""
        <task-notification><task-id>adecffdf418d355ef</task-id><status>completed</status><summary>Agent "probe sleeper A" finished</summary></task-notification>
        """)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(rows(t.snapshot()).first?["resultPreview"] as? String, "hi")

        // 結果の本文にタグの文字があっても切らない。<usage> はその後ろから読む。
        let tricky = SubagentTracker.taskNotifications(in: "<task-notification><task-id>x</task-id><status>failed</status>"
            + "<result>use </result> literally</result><usage><total_tokens>5</total_tokens><tool_uses>2</tool_uses></usage>"
            + "</task-notification>")
        XCTAssertEqual(tricky.first?.result, "use </result> literally")
        XCTAssertEqual(tricky.first?.toolUses, 2)
        XCTAssertEqual(tricky.first?.tokens, 5)
        XCTAssertEqual(tricky.first?.status, "failed")
    }

    /// Stop hook の background_tasks と突き合わせる（古い内部名も受ける）。知らないものは行を作り、一覧から消えた行は閉じる。
    func testReconcileWithStopBackgroundTasks() {
        var t = SubagentTracker()
        let added = t.reconcile(backgroundTasks: [
            ["id": "b1", "type": "local_bash", "status": "running", "description": "npm run dev", "command": "npm run dev"],
            ["id": "a1", "type": "local_agent", "status": "running", "description": "調査", "agent_type": "Explore"],
        ])
        let rows = added.map { obj($0)["agents"] as? [[String: Any]] } ?? nil
        XCTAssertEqual(rows?.compactMap { $0["rowKind"] as? String }, ["shell", "agent"])
        let closed = t.reconcile(backgroundTasks: [
            ["id": "a1", "type": "local_agent", "status": "running", "description": "調査"],
        ])
        XCTAssertEqual(row(closed)?["state"] as? String, "done")
        XCTAssertEqual(row(closed)?["label"] as? String, "npm run dev")
        XCTAssertTrue(t.hasRunningAgents)
        XCTAssertNil(t.reconcile(backgroundTasks: nil))
    }

    /// 2.1.300 の Stop の background_tasks の type は表示名。完全一致で振り分け、dream などの内部の作業は出さない。
    /// 一覧に無い実行中の行は、サブエージェントもシェルも閉じる（終わりを取りこぼしてもペインが working のまま残らない）。
    func testHooksReconcileByDisplayNames() {
        var t = SubagentTracker()
        let added = t.reconcile(backgroundTasks: [
            ["id": "adecffdf418d355ef", "type": "subagent", "status": "running", "description": "probe sleeper A",
             "agent_type": "general-purpose"],
            ["id": "b5x8zhq6o", "type": "shell", "status": "running", "description": "probe bg shell B",
             "command": "sleep 25; echo done"],
            ["id": "w1", "type": "workflow", "status": "running", "description": "review the repo", "name": "review"],
            ["id": "r1", "type": "cloud session", "status": "running", "description": "remote fix"],
            ["id": "tm1", "type": "teammate", "status": "pending", "description": "researcher"],
            ["id": "m1", "type": "monitor", "status": "running", "description": "watch logs"],
            ["id": "mcp1", "type": "MCP task", "status": "running", "description": "export", "server": "figma",
             "tool": "export_frames"],
            ["id": "d1", "type": "dream", "status": "running", "description": "dreaming"],
            ["id": "s1", "type": "auto-mode scan", "status": "running", "description": "scanning for auto-mode setup"],
            ["id": "i1", "type": "memory import", "status": "running", "description": "importing memories"],
        ])
        var byId: [String: [String: Any]] = [:]
        for r in rows(added) { byId[r["id"] as? String ?? ""] = r }
        XCTAssertEqual(Set(byId.keys), ["adecffdf418d355ef", "b5x8zhq6o", "w1", "r1", "tm1", "m1", "mcp1"])
        XCTAssertEqual(byId["adecffdf418d355ef"]?["rowKind"] as? String, "agent")
        XCTAssertEqual(byId["adecffdf418d355ef"]?["agentType"] as? String, "general-purpose")
        XCTAssertEqual(byId["b5x8zhq6o"]?["rowKind"] as? String, "shell")
        XCTAssertEqual(byId["b5x8zhq6o"]?["command"] as? String, "sleep 25; echo done")
        XCTAssertEqual(byId["b5x8zhq6o"]?["background"] as? Bool, true)
        XCTAssertEqual(byId["w1"]?["rowKind"] as? String, "agent")
        XCTAssertEqual(byId["w1"]?["agentType"] as? String, "workflow")
        XCTAssertEqual(byId["w1"]?["label"] as? String, "review the repo")
        XCTAssertEqual(byId["r1"]?["rowKind"] as? String, "agent")
        XCTAssertEqual(byId["r1"]?["agentType"] as? String, "cloud session")
        XCTAssertEqual(byId["tm1"]?["agentType"] as? String, "teammate")
        XCTAssertEqual(byId["m1"]?["rowKind"] as? String, "shell")
        XCTAssertEqual(byId["m1"]?["tool"] as? String, "Monitor")
        XCTAssertEqual(byId["mcp1"]?["rowKind"] as? String, "shell")
        XCTAssertEqual(t.runningAgentCount, 4)
        XCTAssertEqual(t.runningShellCount, 3)

        let closed = t.reconcile(backgroundTasks: [
            ["id": "b5x8zhq6o", "type": "shell", "status": "running", "description": "probe bg shell B"],
        ])
        XCTAssertEqual(rows(closed).count, 6)
        XCTAssertTrue(rows(closed).allSatisfy { $0["state"] as? String == "done" })
        XCTAssertFalse(t.hasRunningAgents)
        XCTAssertEqual(t.runningShellCount, 1)
    }

    /// Esc の中断（合成の Stop）で閉じるのは background != true の実行中の agent 行だけ（stopped）。
    /// バックグラウンドのサブエージェントは Esc では止まらない（probe-hooks C）。止めた行は、あとの SubagentStop で
    /// done に戻らない。プロセスの異常終了だけが failed。
    func testEscAbandonClosesOnlyForegroundAgents() {
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Agent", input: ["description": "裏の調査", "subagent_type": "Explore"], toolUseId: "tb")
        _ = t.hookStart(agentId: "bg", agentType: "Explore")
        _ = t.hookToolResult(toolUseId: "tb", toolName: "Agent", input: ["description": "裏の調査"],
                             response: ["status": "async_launched", "agentId": "bg"])
        t.noteLaunch(toolName: "Agent", input: ["description": "前の調査", "subagent_type": "Plan"], toolUseId: "tf")
        _ = t.hookStart(agentId: "fg", agentType: "Plan")
        _ = t.hookToolResult(toolUseId: "tsh", toolName: "Bash", input: ["command": "npm run dev"],
                             response: ["backgroundTaskId": "sh"])
        let p = t.abandonRunning(includeShells: false, onlyForeground: true)
        XCTAssertEqual(rows(p).compactMap { $0["id"] as? String }, ["fg"])
        XCTAssertEqual(row(p)?["state"] as? String, "stopped")
        XCTAssertEqual(t.runningAgentCount, 1)
        XCTAssertEqual(t.runningShellCount, 1)
        XCTAssertNil(t.hookStop(agentId: "fg", agentType: "Plan", lastMessage: "途中まで"))

        let crashed = t.abandonRunning(state: "failed")
        XCTAssertEqual(rows(crashed).compactMap { $0["id"] as? String }, ["bg", "sh"])
        XCTAssertEqual(rows(crashed).compactMap { $0["state"] as? String }, ["failed", "failed"])
    }

    /// 中断・プロセス終了・close では、実行中の行だけを閉じる（既定は stopped）。終わった行と index はそのまま。
    func testAbandonRunningClosesOnlyRunningRows() {
        var t = SubagentTracker()
        t.noteLaunch(toolName: "Agent", input: ["subagent_type": "Explore"])
        t.noteLaunch(toolName: "Agent", input: ["subagent_type": "Plan"])
        _ = t.hookStart(agentId: "a", agentType: "Explore")
        _ = t.hookStart(agentId: "b", agentType: "Plan")
        _ = t.hookStop(agentId: "a", agentType: "Explore", lastMessage: "done")
        let p = t.abandonRunning()
        XCTAssertEqual(row(p)?["index"] as? Int, 1)
        XCTAssertEqual(row(p)?["state"] as? String, "stopped")
        XCTAssertFalse(t.hasRunning)
        XCTAssertNil(t.abandonRunning())
        let rows = obj(t.snapshot()!)["agents"] as? [[String: Any]]
        XCTAssertEqual(rows?.compactMap { $0["state"] as? String }, ["done", "stopped"])
    }

    func testSnapshotIncludeEmpty() {
        var t = SubagentTracker()
        XCTAssertNil(t.snapshot())
        let empty = obj(t.snapshot(includeEmpty: true)!)
        XCTAssertEqual(empty["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(empty["kind"] as? String, "subagents")
        XCTAssertEqual(empty["taskId"] as? String, "subagents")
        XCTAssertEqual(empty["epoch"] as? String, t.epoch)
        XCTAssertEqual(empty["status"] as? String, "completed")
        XCTAssertEqual((empty["agents"] as? [Any])?.count, 0)
        XCTAssertEqual(t.epoch, t.epoch.lowercased())
        XCTAssertNotNil(UUID(uuidString: t.epoch))
        // 作り直すと世代が変わる。
        XCTAssertNotEqual(SubagentTracker().epoch, t.epoch)

        _ = t.begin(key: "a", label: "x")
        _ = t.begin(key: "b", label: nil, rowKind: "shell")
        let snap = obj(t.snapshot()!)
        XCTAssertEqual(snap["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(snap["epoch"] as? String, t.epoch)
        let all = snap["agents"] as? [[String: Any]]
        XCTAssertEqual(all?.compactMap { $0["id"] as? String }, ["a", "b"])
        XCTAssertEqual(all?.last?["label"] as? String, "バックグラウンドのコマンド")
        XCTAssertEqual(all?.last?["labelIsFallback"] as? Bool, true)
        XCTAssertEqual(all?.first?["labelIsFallback"] as? Bool, false)
        // ふだんの変化は task_progress（変わった行だけ）。
        let changed = obj(t.activity(key: "a", text: "Read: /x")!)
        XCTAssertEqual(changed["subtype"] as? String, "task_progress")
        XCTAssertEqual((changed["agents"] as? [[String: Any]])?.count, 1)
    }

    func testGenericBeginActivityFinishAndReopen() {
        var t = SubagentTracker()
        XCTAssertEqual(row(t.begin(key: "th1", label: "ファイル一覧を調べて\n詳しく", model: "gpt-5"))?["label"] as? String,
                       "ファイル一覧を調べて 詳しく")
        XCTAssertEqual(row(t.activity(key: "th1", text: "command: ls", toolCall: true))?["toolCalls"] as? Int, 1)
        XCTAssertNil(t.activity(key: "unknown", text: "x"))
        XCTAssertEqual(row(t.finish(key: "th1", failed: false, result: "3 files"))?["state"] as? String, "done")
        // 同じ状態で結果も無い finish は送らない（Codex の agentsStates は何度も届く）。
        XCTAssertNil(t.finish(key: "th1", failed: false, result: nil))
        // 終わった行の作業の文は送らない。
        XCTAssertNil(t.activity(key: "th1", text: "late"))
        // 話しかけ直された（sendInput）ら実行中に戻る。結果と所要時間はやり直す。
        let reopened = row(t.begin(key: "th1", label: nil))
        XCTAssertEqual(reopened?["state"] as? String, "running")
        XCTAssertEqual(reopened?["resultPreview"] as? String, "")
        XCTAssertNil(reopened?["result"])
        XCTAssertNil(reopened?["durationMs"])
        XCTAssertEqual(reopened?["model"] as? String, "gpt-5")

        // 中断・失敗は同じ実行の中で done に戻らない（Codex の completed が interrupted の後に来る等）。
        _ = t.begin(key: "th2", label: "子")
        XCTAssertEqual(row(t.finish(key: "th2", state: "interrupted", result: nil))?["state"] as? String, "stopped")
        XCTAssertNil(t.finish(key: "th2", state: "done", result: "完了"))
        XCTAssertNil(t.finish(key: "th2", failed: true, result: nil))
        _ = t.begin(key: "th3", label: "子 3")
        XCTAssertEqual(row(t.finish(key: "th3", state: "failed", result: "rate limited"))?["resultPreview"] as? String,
                       "rate limited")
        XCTAssertNil(t.finish(key: "th3", failed: false, result: "ok"))
        // done の後に届いた失敗は受ける（reconcile で閉じた後の失敗の知らせ等）。
        _ = t.begin(key: "th4", label: "子 4")
        _ = t.finish(key: "th4", state: "done", result: nil)
        XCTAssertEqual(row(t.finish(key: "th4", state: "failed", result: "exit code 1"))?["state"] as? String, "failed")
        // 結果の本文は 2000 字まで、冒頭は 1 行で 160 字まで。
        _ = t.begin(key: "th5", label: "長い")
        let long = row(t.finish(key: "th5", state: "done", result: String(repeating: "あ", count: 2500)))
        XCTAssertEqual((long?["result"] as? String)?.count, 2001)
        XCTAssertEqual((long?["resultPreview"] as? String)?.count, 161)
    }

    /// CLI が知らせた開始時刻（begin の startedAt）と所要時間（finish の durationMs）を、計算した値の代わりに使う
    /// （Codex の裏の端末は、行にするのがターンの終わりなので、item の startedAtMs / durationMs で正しくする）。
    func testBeginStartedAtAndFinishDurationOverride() {
        var t = SubagentTracker()
        let started = Date(timeIntervalSince1970: 1_792_507_417.938)
        let begun = row(t.begin(key: "exec-1", label: "npm run dev", background: true, rowKind: "shell",
                                tool: "exec", command: "npm run dev", startedAt: started))
        XCTAssertEqual(begun?["startedAtMs"] as? Int, 1_792_507_417_938)
        // 既にある実行中の行には startedAt を使わない（開始時刻は作る・開き直すときだけ）。
        let later = Date(timeIntervalSince1970: 1_792_507_500)
        XCTAssertEqual(row(t.begin(key: "exec-1", label: nil, startedAt: later))?["startedAtMs"] as? Int, 1_792_507_417_938)
        let closed = row(t.finish(key: "exec-1", state: "done", result: "ok", durationMs: 5873))
        XCTAssertEqual(closed?["state"] as? String, "done")
        XCTAssertEqual(closed?["durationMs"] as? Int, 5873)
        // 開き直すときは渡した開始時刻からやり直す。
        let reopened = row(t.begin(key: "exec-1", label: nil, startedAt: later))
        XCTAssertEqual(reopened?["state"] as? String, "running")
        XCTAssertEqual(reopened?["startedAtMs"] as? Int, 1_792_507_500_000)
        XCTAssertNil(reopened?["durationMs"])
        // 渡さなければ今までどおり（今の時刻と、そこからの所要時間）。
        let before = nowMs()
        let plain = row(t.begin(key: "a", label: "子"))
        XCTAssertGreaterThanOrEqual(plain?["startedAtMs"] as? Int ?? 0, before)
        let done = row(t.finish(key: "a", state: "done", result: nil))
        XCTAssertLessThan(done?["durationMs"] as? Int ?? .max, 60_000)
    }

    func testFinalStateVocabulary() {
        for s in ["completed", "done", "success"] { XCTAssertEqual(SubagentTracker.finalState(s), "done", s) }
        for s in ["failed", "error"] { XCTAssertEqual(SubagentTracker.finalState(s), "failed", s) }
        for s in ["killed", "stopped", "cancelled", "canceled", "interrupted", "aborted"] {
            XCTAssertEqual(SubagentTracker.finalState(s), "stopped", s)
        }
        for s in ["running", "pending", "started", ""] { XCTAssertNil(SubagentTracker.finalState(s), s) }
    }

    func testDelegationDetection() {
        XCTAssertEqual(SubagentTracker.delegation(toolName: "delegate_task", title: nil, input: ["goal": "要約"])?.label, "要約")
        XCTAssertEqual(SubagentTracker.delegation(toolName: "sessions_spawn", title: nil, input: ["task": "ビルド", "agentId": "coder"])?.agentType, "coder")
        XCTAssertNil(SubagentTracker.delegation(toolName: "read_file", title: nil, input: ["path": "/x"]))
        // claude-code-acp はタイトルに説明が入るので subagent_type で見分ける。
        XCTAssertEqual(SubagentTracker.delegation(toolName: "調査", title: "調査", input: ["subagent_type": "Explore"])?.agentType, "Explore")
        // 説明の無いタスクの配列は既定文（件数付き）。
        let tasks = SubagentTracker.delegation(toolName: "delegate_task", title: nil, input: ["tasks": [["goal": "a"], ["goal": "b"]]])
        XCTAssertEqual(tasks?.label, "2 件のタスク")
        XCTAssertEqual(tasks?.labelIsFallback, true)
        XCTAssertEqual(tasks?.taskCount, 2)
        var t = SubagentTracker()
        let p = t.begin(key: "h", label: tasks?.label, labelIsFallback: tasks?.labelIsFallback, taskCount: tasks?.taskCount)
        XCTAssertEqual(row(p)?["label"] as? String, "2 件のタスク")
        XCTAssertEqual(row(p)?["labelIsFallback"] as? Bool, true)
        XCTAssertEqual(row(p)?["taskCount"] as? Int, 2)
        // 既定文は説明で上書きし、説明は既定文で上書きしない。
        XCTAssertEqual(row(t.begin(key: "h", label: "3 つのファイルを調べる"))?["labelIsFallback"] as? Bool, false)
        XCTAssertEqual(row(t.begin(key: "h", label: "2 件のタスク", labelIsFallback: true))?["label"] as? String,
                       "3 つのファイルを調べる")
    }

    /// ACP の title は「<tool>: <中身>」（Hermes / OpenClaw）。名前は先頭の識別子にし、説明からは「<tool>: 」を外す。
    func testNormalizedToolNameAndAcpTitles() {
        XCTAssertEqual(SubagentTracker.normalizedToolName("delegate_task: 3 tasks: a | b | c"), "delegate_task")
        XCTAssertEqual(SubagentTracker.normalizedToolName("sessions_spawn: task: ビルドして, agentId: coder"), "sessions_spawn")
        XCTAssertEqual(SubagentTracker.normalizedToolName("  read_file: /tmp/x"), "read_file")
        XCTAssertEqual(SubagentTracker.normalizedToolName("mcp.server-tool(x)"), "mcp.server-tool")
        XCTAssertEqual(SubagentTracker.normalizedToolName("delegate_task"), "delegate_task")
        XCTAssertEqual(SubagentTracker.normalizedToolName("調査 する"), "調査")

        // Hermes は delegate_task の rawInput を送らない。title の残りが説明になる。
        let hermes = SubagentTracker.delegation(toolName: "delegate_task:", title: "delegate_task: 3 tasks: a | b | c", input: nil)
        XCTAssertEqual(hermes?.label, "3 tasks: a | b | c")
        XCTAssertEqual(hermes?.labelIsFallback, false)
        let openclaw = SubagentTracker.delegation(toolName: "sessions_spawn:", title: "sessions_spawn: task: ビルドして, agentId: coder",
                                                  input: ["task": "ビルドして", "agentId": "coder"])
        XCTAssertEqual(openclaw?.label, "ビルドして")
        XCTAssertEqual(openclaw?.agentType, "coder")

        var t = SubagentTracker()
        let h = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "h1", "title": "delegate_task: 3 tasks: a | b | c",
                                   "kind": "execute", "status": "in_progress"])
        XCTAssertEqual(row(h)?["label"] as? String, "3 tasks: a | b | c")
        // opencode acp: pending の tool_call は title が task だけで rawInput が空。in_progress の更新で説明が届く。
        let pending = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "o1", "title": "task", "kind": "think",
                                         "rawInput": [String: Any](), "status": "pending"])
        XCTAssertEqual(row(pending)?["label"] as? String, "サブエージェント")
        XCTAssertEqual(row(pending)?["labelIsFallback"] as? Bool, true)
        let filled = t.ingestAcpUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "o1", "title": "List scratch dir",
                                        "status": "in_progress",
                                        "rawInput": ["description": "List scratch dir", "prompt": "…", "subagent_type": "general"]])
        XCTAssertEqual(row(filled)?["label"] as? String, "List scratch dir")
        XCTAssertEqual(row(filled)?["agentType"] as? String, "general")
        XCTAssertEqual(row(filled)?["labelIsFallback"] as? Bool, false)
        let done = t.ingestAcpUpdate([
            "sessionUpdate": "tool_call_update", "toolCallId": "o1", "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text":
                "<task id=\"ses_ea64d4d99ffe0NI5OBH0EOs20r\" state=\"completed\">\n<task_result>\n2\n</task_result>\n</task>"]]],
        ])
        XCTAssertEqual(row(done)?["state"] as? String, "done")
        XCTAssertEqual(row(done)?["resultPreview"] as? String, "2")
    }

    /// OpenCode 1.18 の task の出力（<task id=… state=…>）と、古い形（<task_metadata>）。
    func testParseTaskOutput() {
        let done = SubagentTracker.parseTaskOutput(
            "<task id=\"ses_ea64d4d99ffe0NI5OBH0EOs20r\" state=\"completed\">\n<task_result>\n2\n</task_result>\n</task>")
        XCTAssertEqual(done.state, "completed")
        XCTAssertNil(done.summary)
        XCTAssertEqual(done.result, "2")
        let background = SubagentTracker.parseTaskOutput(
            "<task id=\"ses_C\" state=\"running\">\n<summary>Background task started</summary>\n<task_result>\n"
            + "The task is working in the background.\n</task_result>\n</task>")
        XCTAssertEqual(background.state, "running")
        XCTAssertEqual(background.summary, "Background task started")
        XCTAssertEqual(background.result, "The task is working in the background.")
        let failed = SubagentTracker.parseTaskOutput(
            "<task id=\"ses_E\" state=\"error\">\n<task_error>\nprovider rejected the request\n</task_error>\n</task>")
        XCTAssertEqual(failed.state, "error")
        XCTAssertEqual(failed.result, "provider rejected the request")
        XCTAssertEqual(SubagentTracker.finalState(failed.state ?? ""), "failed")
        let legacy = SubagentTracker.parseTaskOutput("見つかったファイルは 3 つ\n\n<task_metadata>\nsession_id: ses_old\n</task_metadata>")
        XCTAssertNil(legacy.state)
        XCTAssertEqual(legacy.result, "見つかったファイルは 3 つ")
        let plain = SubagentTracker.parseTaskOutput("ただの返事")
        XCTAssertNil(plain.state)
        XCTAssertNil(plain.summary)
        XCTAssertNil(plain.result)
    }

    /// opencode acp のバックグラウンドの task（OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS）は、出力が state="running" ですぐ
    /// completed になる。ACP には子の完了も親への知らせも流れてこない（§4）ので、起動の知らせ（summary）を結果にして done で
    /// 閉じる（実行中のまま残すと、カード・SessionHub の「閉じない」・スリープ抑止・push の保留が中断か close まで続く）。
    func testAcpBackgroundTaskClosesAtLaunch() {
        var t = SubagentTracker()
        _ = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "o1", "title": "task", "kind": "think",
                               "rawInput": [String: Any](), "status": "pending"])
        _ = t.ingestAcpUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "o1", "title": "Watch the build",
                               "status": "in_progress",
                               "rawInput": ["description": "Watch the build", "prompt": "…", "subagent_type": "general",
                                            "background": true]])
        let launched = t.ingestAcpUpdate([
            "sessionUpdate": "tool_call_update", "toolCallId": "o1", "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text":
                "<task id=\"ses_C\" state=\"running\">\n<summary>Background task started</summary>\n<task_result>\n"
                + "The task is working in the background.\n</task_result>\n</task>"]]],
        ])
        XCTAssertEqual(row(launched)?["state"] as? String, "done")
        XCTAssertEqual(row(launched)?["resultPreview"] as? String, "Background task started")
        XCTAssertFalse(t.hasRunning, "起動しただけの task を実行中のまま残した")
        t.pruneFinished()
        XCTAssertTrue(t.isEmpty)
    }

    /// 結果の無いまま閉じた行（abandonRunning・reconcile・結果の無い子のターン）は、resultPreview と result を空文字で送る。
    /// アプリは届いた項目だけを重ねるので、送らないと実行中の作業の文が残り、失敗の理由や「→ 結果」に見える。
    /// 再開した行（実行中）も resultPreview を空で送る（前の実行の結果を「いまの作業」に見せない）。
    func testRowsWithoutResultSendBlankPreviewAndResult() {
        var t = SubagentTracker()
        _ = t.begin(key: "c1", label: "npm test", background: true, rowKind: "shell", tool: "Bash")
        XCTAssertEqual(row(t.activity(key: "c1", text: "Bash: npm test", toolCall: true))?["resultPreview"] as? String,
                       "Bash: npm test")
        let failed = row(t.abandonRunning(state: "failed"))
        XCTAssertEqual(failed?["state"] as? String, "failed")
        XCTAssertEqual(failed?["resultPreview"] as? String, "", "最後の作業の文を失敗の理由に残した")
        XCTAssertEqual(failed?["result"] as? String, "")

        _ = t.begin(key: "a1", label: "調査")
        _ = t.activity(key: "a1", text: "Grep: token")
        let closed = row(t.reconcile(backgroundTasks: [[String: Any]]()))
        XCTAssertEqual(closed?["state"] as? String, "done")
        XCTAssertEqual(closed?["resultPreview"] as? String, "", "最後の作業の文を「→ 結果」に残した")
        XCTAssertEqual(closed?["result"] as? String, "")

        _ = t.finish(key: "a1", state: "done", result: "1 回目の結果")
        let reopened = row(t.begin(key: "a1", label: nil))
        XCTAssertEqual(reopened?["state"] as? String, "running")
        XCTAssertEqual(reopened?["resultPreview"] as? String, "")
        XCTAssertNil(reopened?["result"])
    }

    func testAcpUpdates() {
        var t = SubagentTracker()
        let start = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "delegate_task",
                                       "rawInput": ["goal": "README を要約"], "status": "in_progress"])
        XCTAssertEqual(row(start)?["label"] as? String, "README を要約")
        let end = t.ingestAcpUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed",
                                     "content": [["type": "content", "content": ["type": "text", "text": "要約しました"]]]])
        XCTAssertEqual(row(end)?["resultPreview"] as? String, "要約しました")
        XCTAssertNil(t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "c2", "title": "read_file"]))
    }

    func testClaudeCompatibleToolUseLines() {
        var t = SubagentTracker()
        let started = t.ingestToolUseLine(obj("""
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Task","input":{"description":"調査","subagent_type":"general-purpose"}}]}}
        """))
        XCTAssertEqual(row(started.first)?["agentType"] as? String, "general-purpose")
        // 子の行は parent_tool_use_id で引き当てる。
        XCTAssertEqual(row(t.ingestStreamLine(obj("""
        {"type":"assistant","parent_tool_use_id":"tu1","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a.txt"}}]}}
        """)))?["resultPreview"] as? String, "Read: /a.txt")
        let ended = t.ingestToolUseLine(obj("""
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"終わり"}]}}
        """))
        XCTAssertEqual(row(ended.first)?["state"] as? String, "done")
    }
}

/// 行ごとの停止・ACP の変更・背景だけの数（docs/BACKGROUND_CONTROL_2026-10-21.md §3.7・§5.1・§5.2・§8.2）。
final class SubagentTrackerStopTests: XCTestCase {
    private func obj(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func rows(_ payload: String?) -> [[String: Any]] {
        guard let payload else { return [] }
        return (obj(payload)["agents"] as? [[String: Any]]) ?? []
    }

    private func stoppable(_ payload: String?, id: String? = nil) -> Bool? {
        let all = rows(payload)
        let r = id.map { id in all.first { $0["id"] as? String == id } } ?? all.first
        return r?["stoppable"] as? Bool
    }

    private func start(_ t: inout SubagentTracker, _ id: String, type: String, background: Bool = true) -> String? {
        t.ingestStreamLine(obj("""
        {"type":"system","subtype":"task_started","task_id":"\(id)","description":"d-\(id)","task_type":"\(type)","is_backgrounded":\(background)\(type == "local_agent" ? ",\"subagent_type\":\"Explore\"" : "")}
        """))
    }

    func testStoppableIsAlwaysPresentAndFalseWithoutHandle() {
        var t = SubagentTracker()
        let p = start(&t, "a1", type: "local_agent")
        XCTAssertEqual(stoppable(p), false)
        XCTAssertNotNil(rows(p).first?["stoppable"])
        let done = t.finish(key: "a1", state: "done", result: "x")
        XCTAssertEqual(stoppable(done), false)
        XCTAssertNotNil(rows(done).first?["stoppable"])
    }

    func testClaudeStopTaskRaisesOnlyLocalAgentAndLocalBash() {
        var t = SubagentTracker()
        _ = t.setClaudeStopTask(true)
        XCTAssertEqual(stoppable(start(&t, "a1", type: "local_agent")), true)
        XCTAssertEqual(stoppable(start(&t, "b1", type: "local_bash")), true)
        XCTAssertEqual(stoppable(start(&t, "m1", type: "monitor_mcp")), false)
        XCTAssertEqual(stoppable(start(&t, "m2", type: "mcp_task")), false)
        // teammate は background_tasks_changed の一覧から。
        let listed = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"t1","task_type":"in_process_teammate","description":"mate"}]}
        """))
        XCTAssertEqual(stoppable(listed, id: "t1"), false)
        // hooks の行（task_type が無い）は立たない。
        _ = t.hookStart(agentId: "h1", agentType: "x")
        _ = t.noteLaunch(toolName: "Agent", input: ["description": "h"])
        let hook = t.begin(key: "hook-row", label: "h")
        XCTAssertEqual(stoppable(hook), false)
    }

    func testBackgroundTasksChangedListsTaskType() {
        var t = SubagentTracker()
        _ = t.setClaudeStopTask(true)
        let p = t.ingestStreamLine(obj("""
        {"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"s1","task_type":"local_bash","command":"sleep 9"},{"task_id":"s2","task_type":"local_agent","description":"x"}]}
        """))
        XCTAssertEqual(stoppable(p, id: "s1"), true)
        XCTAssertEqual(stoppable(p, id: "s2"), true)
    }

    func testHooksReconcileNeverGetsHandle() {
        var t = SubagentTracker()
        _ = t.setClaudeStopTask(true)
        let p = t.reconcile(backgroundTasks: [["id": "z1", "type": "shell", "command": "sleep 5"]])
        XCTAssertEqual(stoppable(p), false)
    }

    func testChangingClaudeStopTaskRecomputesAndReturnsSnapshot() {
        var t = SubagentTracker()
        _ = start(&t, "a1", type: "local_agent")
        XCTAssertNil(t.setClaudeStopTask(false))
        let on = t.setClaudeStopTask(true)
        XCTAssertEqual(obj(on!)["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(stoppable(on), true)
        XCTAssertNil(t.setClaudeStopTask(true))
        let off = t.setClaudeStopTask(false)
        XCTAssertEqual(stoppable(off), false)
        // 代入でも同じ。
        t.claudeStopTask = true
        XCTAssertEqual(stoppable(t.snapshot()), true)
    }

    func testBeginStopFourOutcomesAndEndStop() {
        var t = SubagentTracker()
        _ = t.setClaudeStopTask(true)
        _ = start(&t, "a1", type: "local_agent")
        _ = start(&t, "m1", type: "monitor_mcp")
        XCTAssertEqual(t.beginStop(key: "nope"), .notRunning)
        XCTAssertEqual(t.beginStop(key: "m1"), .unsupported)
        guard case .ok(let kind, let payload) = t.beginStop(key: "a1") else { return XCTFail("ok のはず") }
        XCTAssertEqual(kind, "agent")
        XCTAssertEqual(stoppable(payload), false)
        XCTAssertTrue(t.isStopRequested(key: "a1"))
        XCTAssertEqual(t.beginStop(key: "a1"), .inFlight)
        let back = t.endStop(key: "a1")
        XCTAssertEqual(stoppable(back), true)
        XCTAssertFalse(t.isStopRequested(key: "a1"))
        XCTAssertNil(t.endStop(key: "a1"))
        _ = t.finish(key: "a1", state: "stopped", result: nil)
        XCTAssertEqual(t.beginStop(key: "a1"), .notRunning)
        XCTAssertFalse(t.isRunning(key: "a1"))
        XCTAssertTrue(t.isRunning(key: "m1"))
    }

    func testRestartClearsPendingStopButKeepsHandle() {
        var t = SubagentTracker()
        _ = t.setStopHandle(key: "c1", on: true)
        _ = t.begin(key: "c1", label: "child")
        XCTAssertEqual(stoppable(t.setStopHandle(key: "c1", on: true) ?? t.snapshot()), true)
        _ = t.beginStop(key: "c1")
        XCTAssertTrue(t.isStopRequested(key: "c1"))
        _ = t.finish(key: "c1", state: "stopped", result: nil)
        let again = t.begin(key: "c1", label: "child")
        XCTAssertFalse(t.isStopRequested(key: "c1"))
        XCTAssertEqual(stoppable(again), true)
    }

    func testSetStopHandleOnlyReturnsPayloadOnChange() {
        var t = SubagentTracker()
        XCTAssertNil(t.setStopHandle(key: "x", on: true))
        _ = t.begin(key: "x", label: "x")
        let p = t.setStopHandle(key: "x", on: true)
        XCTAssertEqual(stoppable(p), true)
        XCTAssertNil(t.setStopHandle(key: "x", on: true))
        XCTAssertEqual(stoppable(t.setStopHandle(key: "x", on: false)), false)
    }

    func testStoppedRowIsNotChangedByLaterFailed() {
        var t = SubagentTracker()
        _ = start(&t, "a1", type: "local_agent")
        _ = t.finish(key: "a1", state: "stopped", result: nil)
        XCTAssertNil(t.finish(key: "a1", state: "failed", result: "boom"))
        XCTAssertEqual(rows(t.snapshot()).first?["state"] as? String, "stopped")
    }

    func testStatuslessAcpUpdateDoesNotCloseRow() {
        var t = SubagentTracker()
        _ = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "g1", "title": "delegate_task", "status": "pending"])
        let p = t.ingestAcpUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "g1",
                                   "title": "delegate_task: 2 tasks: a | b"])
        XCTAssertEqual(rows(p).first?["state"] as? String, "running")
        XCTAssertTrue(t.isRunning(key: "g1"))
        let closed = t.ingestAcpUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "g1", "status": "completed"])
        XCTAssertEqual(rows(closed).first?["state"] as? String, "done")
    }

    func testAcpBackgroundReceiptKeepsRowRunning() {
        var t = SubagentTracker()
        _ = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "g2", "title": "delegate_task: 1 tasks: a"])
        let p = t.ingestAcpUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "g2", "status": "completed"],
                                  background: true)
        XCTAssertEqual(rows(p).first?["state"] as? String, "running")
        XCTAssertEqual(rows(p).first?["background"] as? Bool, true)
        XCTAssertEqual(rows(p).first?["stoppable"] as? Bool, false)
    }

    func testDelegateControlCallsDoNotMakeRows() {
        XCTAssertNil(SubagentTracker.delegation(toolName: "delegate_task", title: nil, input: ["action": "list"]))
        XCTAssertNil(SubagentTracker.delegation(toolName: "delegate_task", title: nil, input: ["action": "steer"]))
        XCTAssertNil(SubagentTracker.delegation(toolName: "delegate_task", title: nil, input: ["action": "stop"]))
        for title in ["delegate_task: list", "delegate_task: steer abc", "delegate_task: stop: x", "delegate_task:stop"] {
            XCTAssertNil(SubagentTracker.delegation(toolName: title, title: title, input: nil), title)
        }
        let real = "delegate_task: 1 tasks: list the files"
        XCTAssertNotNil(SubagentTracker.delegation(toolName: real, title: real, input: nil))
        let word = "delegate_task: listing files"
        XCTAssertNotNil(SubagentTracker.delegation(toolName: word, title: word, input: nil))
        XCTAssertNotNil(SubagentTracker.delegation(toolName: "delegate_task", title: nil, input: ["goal": "x"]))
        var t = SubagentTracker()
        XCTAssertNil(t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "c", "title": "delegate_task: list"]))
        XCTAssertTrue(t.isEmpty)
    }

    func testAbandonRunningExcept() {
        var t = SubagentTracker()
        _ = t.begin(key: "keep", label: "keep", background: true)
        _ = t.begin(key: "drop", label: "drop", background: true)
        let p = t.abandonRunning(state: "failed", except: ["keep"])
        XCTAssertEqual(rows(p).map { $0["id"] as? String }, ["drop"])
        XCTAssertTrue(t.isRunning(key: "keep"))
        XCTAssertNil(t.abandonRunning(state: "failed", except: ["keep"]))
    }

    /// 非同期の委任の受領票の count: 1 件は説明のまま、複数なら「{n} 件のタスク」（既定文）にする。
    func testSetTaskCountNamesMultipleTasksAsFallback() {
        var t = SubagentTracker()
        _ = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "delegate_task: 1 tasks: run sleep"])
        let one = rows(t.setTaskCount(key: "c1", count: 1)).first
        XCTAssertEqual(one?["taskCount"] as? Int, 1)
        XCTAssertEqual(one?["label"] as? String, "1 tasks: run sleep")
        _ = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "c3", "title": "delegate_task: 3 tasks: a | b | c"])
        let three = rows(t.setTaskCount(key: "c3", count: 3)).first
        XCTAssertEqual(three?["taskCount"] as? Int, 3)
        XCTAssertEqual(three?["label"] as? String, "3 件のタスク")
        XCTAssertEqual(three?["labelIsFallback"] as? Bool, true)
        XCTAssertNil(t.setTaskCount(key: "c3", count: 3), "変化が無ければ流さない")
        _ = t.finish(key: "c3", state: "done", result: nil)
        XCTAssertNil(t.setTaskCount(key: "c3", count: 4), "終わった行は変えない")
        XCTAssertNil(t.setTaskCount(key: "none", count: 2))
    }

    /// 受領票（background: true の completed）は行を running のまま background にし、status の無い更新では閉じない。
    func testAcpReceiptKeepsRowRunning() {
        var t = SubagentTracker()
        _ = t.ingestAcpUpdate(["sessionUpdate": "tool_call", "toolCallId": "c1", "title": "delegate_task: 1 tasks: x"])
        _ = t.ingestAcpUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "c1"])
        XCTAssertTrue(t.isRunning(key: "c1"), "status の無い更新で閉じた")
        let p = t.ingestAcpUpdate(["sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed"], background: true)
        XCTAssertEqual(rows(p).first?["background"] as? Bool, true)
        XCTAssertTrue(t.isRunning(key: "c1"))
    }

    func testRunningBackgroundOnlyAgentCount() {
        var t = SubagentTracker()
        XCTAssertEqual(t.runningBackgroundOnlyAgentCount, 0)
        _ = t.begin(key: "bg", label: "bg", background: true)
        _ = t.begin(key: "fg", label: "fg", background: false)
        _ = t.begin(key: "unk", label: "unknown")
        _ = t.begin(key: "sh", label: "sh", background: true, rowKind: "shell")
        XCTAssertEqual(t.runningBackgroundOnlyAgentCount, 1)
        _ = t.finish(key: "bg", state: "done", result: nil)
        XCTAssertEqual(t.runningBackgroundOnlyAgentCount, 0)
    }
}
