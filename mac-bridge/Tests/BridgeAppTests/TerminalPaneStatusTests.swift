import XCTest
@testable import BridgeApp

/// アプリ内ターミナルのペインごとの状態（hook → TerminalPaneStatus）。実 claude は使わない。
final class TerminalPaneStatusTests: XCTestCase {

    func testEventsMapToStates() {
        let s = { (e: String, h: [String: Any]) in TerminalPaneStatus.state(event: e, hook: h) }
        XCTAssertEqual(s("UserPromptSubmit", [:]), "working")
        XCTAssertEqual(s("PreToolUse", [:]), "working")
        XCTAssertEqual(s("PermissionRequest", [:]), "attention")
        // 答えるまで止まる確認（許可・MCP の入力・MCP のリンクを開く確認・バックグラウンドの worker の許可）は attention
        for type in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "worker_permission_prompt"] {
            XCTAssertEqual(s("Notification", ["notification_type": type]), "attention", type)
        }
        // 入力待ちの知らせ（60 秒放置）では変えない
        XCTAssertNil(s("Notification", ["notification_type": "idle_prompt"]))
        XCTAssertNil(s("Notification", [:]))
        // main のターンの終わりは、バックグラウンドの作業が残っていても done（残りの数は別に持つ）
        XCTAssertEqual(s("Stop", ["background_tasks": [["id": "a1", "type": "subagent", "status": "running"]]]), "done")
        // Esc の中断は「終わった」にしない
        XCTAssertEqual(s("Stop", ["buddy_interrupted": true]), "idle")
        XCTAssertEqual(s("StopFailure", [:]), "error")
        XCTAssertNil(s("SessionStart", [:]))
    }

    func testDisplayAfterTurnEndKeepsDone() {
        let s = { (e: String, cur: String?) in TerminalPaneStatus.state(event: e, hook: [:], current: cur) }
        // ターンの途中の表示は作業中のまま
        XCTAssertEqual(s("MessageDisplay", "working"), "working")
        XCTAssertEqual(s("MessageDisplay", "attention"), "working")
        // 終わった後の表示（離席中のまとめなど）では作業中に戻さない。サブエージェントの始まり・終わりでは変えない
        for e in ["MessageDisplay", "SubagentStart", "SubagentStop"] {
            XCTAssertNil(s(e, "done"))
            XCTAssertNil(s(e, "idle"))
            XCTAssertNil(s(e, "error"))
            XCTAssertNil(s(e, nil))
        }
        XCTAssertNil(s("SubagentStop", "working"))
        XCTAssertNil(s("SubagentStart", "attention"))
        // 発話・ツールはいつでも作業中
        XCTAssertEqual(s("UserPromptSubmit", "done"), "working")
        XCTAssertEqual(s("PreToolUse", "idle"), "working")
    }

    /// サブエージェントの中の hook（agent_id 付き）はペインの状態を変えない（選択肢の attention を作業中に戻さない）。
    func testSubagentHooksDoNotChangeState() {
        let sub: [String: Any] = ["agent_id": "a1", "agent_type": "general-purpose"]
        for e in ["PreToolUse", "PostToolUse", "PostToolUseFailure", "MessageDisplay", "SubagentStart", "SubagentStop"] {
            XCTAssertNil(TerminalPaneStatus.state(event: e, hook: sub, current: "attention"), e)
            XCTAssertNil(TerminalPaneStatus.state(event: e, hook: sub, current: "done"), e)
        }
        // 選択肢そのものはサブエージェントのものでも attention（答えるまでターミナルが止まる）
        XCTAssertEqual(TerminalPaneStatus.state(event: "PermissionRequest", hook: sub), "attention")
        // agent_id が空なら main のスレッド
        XCTAssertEqual(TerminalPaneStatus.state(event: "PreToolUse", hook: ["agent_id": ""]), "working")
    }

    /// done が続いても、前の done の後に main のスレッドの動き（作業中・本文）があれば 1 回に数える。
    func testDoneAfterDoneCountsOnlyWithActivity() async {
        let st = TerminalPaneStatus()
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil)
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, reply: "起動しました")
        var e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.turn, 1)
        // 動きの無い done の繰り返しは数えない（知らせない）
        let v = await st.poll(since: -1, timeout: 0).version
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, reply: "x")
        let r = await st.poll(since: -1, timeout: 0)
        XCTAssertEqual(r.version, v)
        XCTAssertEqual(r.entries.first?.turn, 1)
        XCTAssertEqual(r.entries.first?.reply, "起動しました")
        // UserPromptSubmit の来ないターン（本文 → Stop）。状態は done のままでも、本文の後の done は数える
        st.note(pane: "p1", sessionId: "s1", activity: true)
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, reply: "終わりました")
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.turn, 2)
        XCTAssertEqual(e?.reply, "終わりました")
        // 中断（idle）の後の動きの無い done は、今までどおり状態が変わったので数える
        st.set(pane: "p1", state: "idle", sessionId: "s1", cwd: nil)
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil)
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.turn, 3)
        // 別の会話の動きは数えない
        st.note(pane: "p1", sessionId: "other", activity: true)
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil)
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.turn, 3)
    }

    /// SessionEnd（/clear など）で entry が消えても、同じペインの次の会話は turn の続きから数える。
    func testTurnStaysMonotonicAcrossRemoval() async {
        let st = TerminalPaneStatus()
        for _ in 0..<3 {
            st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil)
            st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil)
        }
        var e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.turn, 3)
        st.remove(pane: "p1", sessionId: "s1")
        let empty = await st.poll(since: -1, timeout: 0).entries
        XCTAssertTrue(empty.isEmpty)
        st.set(pane: "p1", state: "working", sessionId: "s2", cwd: nil)
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.turn, 3, "作業中では増えない")
        st.set(pane: "p1", state: "done", sessionId: "s2", cwd: nil)
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.turn, 4)
        XCTAssertEqual(e?.sessionId, "s2")
        // 別のペインは 0 から
        st.set(pane: "p2", state: "done", sessionId: "s3", cwd: nil)
        let p2 = await st.poll(since: -1, timeout: 0).entries.first { $0.pane == "p2" }
        XCTAssertEqual(p2?.turn, 1)
    }

    /// 動いているバックグラウンドの作業の数は、状態を変えずに書ける（変わったときだけ知らせる）。
    func testBackgroundCountsAreWrittenWithoutChangingState() async {
        let st = TerminalPaneStatus()
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil, background: (agents: 1, shells: 0))
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, reply: "起動しました", background: (agents: 1, shells: 1))
        var r = await st.poll(since: -1, timeout: 0)
        XCTAssertEqual(r.entries.first?.state, "done")
        XCTAssertEqual(r.entries.first?.backgroundAgents, 1)
        XCTAssertEqual(r.entries.first?.backgroundShells, 1)
        let updatedAt = r.entries.first?.updatedAt
        // サブエージェントが終わった（SubagentStop）。状態・turn・返事はそのまま、数だけ変わる
        st.note(pane: "p1", sessionId: "s1", background: (agents: 0, shells: 1))
        let after = await st.poll(since: r.version, timeout: 0)
        XCTAssertNotEqual(after.version, r.version)
        XCTAssertEqual(after.entries.first?.state, "done")
        XCTAssertEqual(after.entries.first?.turn, 1)
        XCTAssertEqual(after.entries.first?.reply, "起動しました")
        XCTAssertEqual(after.entries.first?.backgroundAgents, 0)
        XCTAssertEqual(after.entries.first?.backgroundShells, 1)
        XCTAssertEqual(after.entries.first?.updatedAt, updatedAt)
        // 同じ数なら知らせない。別の会話のものは書かない
        r = after
        st.note(pane: "p1", sessionId: "s1", background: (agents: 0, shells: 1))
        st.note(pane: "p1", sessionId: "other", background: (agents: 5, shells: 5))
        let same = await st.poll(since: -1, timeout: 0)
        XCTAssertEqual(same.version, r.version)
        XCTAssertEqual(same.entries.first?.backgroundAgents, 0)
        // 同じ状態の繰り返しでも、数が変われば書く。background を渡さなければ数は変えない
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, background: (agents: 0, shells: 0))
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil)
        let last = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(last?.turn, 1)
        XCTAssertEqual(last?.state, "working")
        XCTAssertEqual(last?.backgroundShells, 0)
    }

    func testPaneIdIsValidated() {
        XCTAssertEqual(TerminalPaneStatus.validPane("3F2504E0-4F89-11D3-9A0C-0305E82C3301"), "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        XCTAssertNil(TerminalPaneStatus.validPane(""))
        XCTAssertNil(TerminalPaneStatus.validPane("a b"))
        XCTAssertNil(TerminalPaneStatus.validPane("../x"))
        XCTAssertNil(TerminalPaneStatus.validPane(String(repeating: "a", count: 65)))
        XCTAssertNil(TerminalPaneStatus.validPane(nil))
    }

    func testReplyIsKeptOnlyWhileDone() async {
        let st = TerminalPaneStatus()
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil, reply: "ignored")
        var e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.agent, "claude")
        XCTAssertNil(e?.reply, "done 以外では持たない")
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, reply: "できました")
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.reply, "できました")
        XCTAssertEqual(e?.turn, 1)
        // 次のターンが始まったら前の返事は消す
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil)
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertNil(e?.reply)
        // 新しい返事で終わると turn が増え、返事が入れ替わる。長すぎる返事は切る
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, reply: String(repeating: "あ", count: 20_000))
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertEqual(e?.turn, 2)
        XCTAssertEqual(e?.reply?.count, TerminalPaneStatus.replyLimit)
        // 中断（idle）でも消す
        st.set(pane: "p1", state: "idle", sessionId: "s1", cwd: nil, reply: "x")
        e = await st.poll(since: -1, timeout: 0).entries.first
        XCTAssertNil(e?.reply)
        // 別のエージェント
        st.set(pane: "p2", state: "done", sessionId: nil, cwd: nil, agent: "codex", reply: "ok")
        let p2 = await st.poll(since: -1, timeout: 0).entries.first { $0.pane == "p2" }
        XCTAssertEqual(p2?.agent, "codex")
        XCTAssertEqual(p2?.reply, "ok")
        XCTAssertEqual(p2?.turn, 1)
    }

    func testPaneEventBodyIsValidated() {
        let ok = TerminalPaneStatus.paneEvent(["pane": "pane-1", "agent": "codex", "state": "done", "sessionId": "t1", "cwd": "/tmp", "reply": "hi"])
        XCTAssertEqual(ok, .init(pane: "pane-1", agent: "codex", state: "done", sessionId: "t1", cwd: "/tmp", reply: "hi"))
        // agent が無ければ claude
        XCTAssertEqual(TerminalPaneStatus.paneEvent(["pane": "p", "state": "working"])?.agent, "claude")
        for s in ["working", "attention", "done", "error", "idle"] {
            XCTAssertNotNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": "codex", "state": s]), s)
        }
        XCTAssertNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": "codex", "state": "finished"]))
        XCTAssertNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": "codex"]))
        XCTAssertNil(TerminalPaneStatus.paneEvent(["pane": "../x", "agent": "codex", "state": "done"]))
        XCTAssertNil(TerminalPaneStatus.paneEvent(["agent": "codex", "state": "done"]))
        XCTAssertNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": "Codex", "state": "done"]))
        XCTAssertNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": "a b", "state": "done"]))
        XCTAssertNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": "", "state": "done"]))
        XCTAssertNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": 1, "state": "done"]))
        XCTAssertNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": String(repeating: "a", count: 33), "state": "done"]))
        XCTAssertNotNil(TerminalPaneStatus.paneEvent(["pane": "p", "agent": String(repeating: "a", count: 32), "state": "done"]))
    }

    func testTurnCountsEachCompletionAndPollWakes() async {
        let st = TerminalPaneStatus()
        let start = await st.poll(since: -1, timeout: 0).version
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: "/tmp")
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: "/tmp") // 同じ状態は数えない
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil)
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil) // 中断の見張りと Stop の重複
        var r = await st.poll(since: start, timeout: 0)
        XCTAssertEqual(r.entries.first?.turn, 1)
        XCTAssertEqual(r.entries.first?.state, "done")
        XCTAssertEqual(r.entries.first?.cwd, "/tmp")
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil)
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil)
        r = await st.poll(since: r.version, timeout: 0)
        XCTAssertEqual(r.entries.first?.turn, 2)

        // 変わるまで待ち、変わったら返る
        let v = r.version
        async let waited = st.poll(since: v, timeout: 5)
        try? await Task.sleep(nanoseconds: 300_000_000)
        st.set(pane: "p2", state: "attention", sessionId: "s2", cwd: nil)
        let w = await waited
        XCTAssertNotEqual(w.version, v)
        XCTAssertEqual(Set(w.entries.map(\.pane)), ["p1", "p2"])

        // 別の会話の終わりでは消さない。同じ会話なら消す
        st.remove(pane: "p2", sessionId: "other")
        let kept = await st.poll(since: -1, timeout: 0).entries.count
        XCTAssertEqual(kept, 2)
        st.remove(pane: "p2", sessionId: "s2")
        let left = await st.poll(since: -1, timeout: 0).entries.count
        XCTAssertEqual(left, 1)
    }

    // MARK: - Live Activity の数（onBackgroundChanged。§8.2）

    private func watched() -> (TerminalPaneStatus, LockedBox<[String]>) {
        let st = TerminalPaneStatus()
        let calls = LockedBox<[String]>([])
        st.setOnBackgroundChanged { key, count in calls.update { $0.append("\(key)=\(count)") } }
        return (st, calls)
    }

    /// working / attention の間はターンより長く動く作業だけ、ほかの状態では動いている背景の全部を渡す。
    func testBackgroundCountFollowsStateAndOnlyReportsChanges() async {
        let (st, calls) = watched()
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil, background: (agents: 3, shells: 1), backgroundOnly: 1)
        XCTAssertEqual(calls.value, ["s1=1"], "working の間は backgroundOnlyAgents")
        // 同じ数の hook は呼ばない。
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil, background: (agents: 3, shells: 1), backgroundOnly: 1)
        st.note(pane: "p1", sessionId: "s1", background: (agents: 3, shells: 1), backgroundOnly: 1)
        XCTAssertEqual(calls.value, ["s1=1"])
        // 前景のサブエージェントが増えても（backgroundAgents だけ変わる）、working の間は渡す数が同じなので呼ばない。
        st.note(pane: "p1", sessionId: "s1", background: (agents: 4, shells: 1), backgroundOnly: 1)
        XCTAssertEqual(calls.value, ["s1=1"])
        // done になると backgroundAgents（動いているサブエージェントの全部）。
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, background: (agents: 4, shells: 1), backgroundOnly: 1)
        XCTAssertEqual(calls.value, ["s1=1", "s1=4"])
        st.note(pane: "p1", sessionId: "s1", background: (agents: 2, shells: 1), backgroundOnly: 1)
        XCTAssertEqual(calls.value.last, "s1=2")
        // attention は working と同じ。
        st.set(pane: "p1", state: "attention", sessionId: "s1", cwd: nil, background: (agents: 2, shells: 1), backgroundOnly: 1)
        XCTAssertEqual(calls.value.last, "s1=1")
        let entries = await st.poll(since: -1, timeout: 0).entries
        XCTAssertEqual(entries.first?.backgroundOnlyAgents, 1)
    }

    /// sessionId が分かる前は "pane:<pane>"。分かったら前の key を 0 にして新しい key に移す。外すと 0。
    func testBackgroundKeyMovesFromPaneToSessionAndClearsOnRemove() {
        let (st, calls) = watched()
        st.set(pane: "p1", state: "working", sessionId: nil, cwd: nil, background: (agents: 2, shells: 0), backgroundOnly: 2)
        XCTAssertEqual(calls.value, ["pane:p1=2"])
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil, background: (agents: 2, shells: 0), backgroundOnly: 2)
        XCTAssertEqual(calls.value, ["pane:p1=2", "pane:p1=0", "s1=2"])
        st.remove(pane: "p1", sessionId: "s1")
        XCTAssertEqual(calls.value.last, "s1=0")
        let n = calls.value.count
        st.remove(pane: "p1", sessionId: "s1")
        XCTAssertEqual(calls.value.count, n, "もう無いペインでは呼ばない")
    }

    /// 通知先を付ける前に届いた数は、付けたときに一度渡す（起動の途中の hook を取りこぼさない）。
    func testSetterReplaysCountsReportedBeforeHandlerWasSet() {
        let st = TerminalPaneStatus()
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, background: (agents: 2, shells: 0), backgroundOnly: 0)
        st.set(pane: "p2", state: "done", sessionId: "s2", cwd: nil, background: (agents: 0, shells: 1), backgroundOnly: 0)
        let calls = LockedBox<[String]>([])
        st.setOnBackgroundChanged { key, count in calls.update { $0.append("\(key)=\(count)") } }
        XCTAssertEqual(calls.value, ["s1=2"], "0 のペインは渡さない")
        st.note(pane: "p1", sessionId: "s1", background: (agents: 2, shells: 0), backgroundOnly: 0)
        XCTAssertEqual(calls.value, ["s1=2"], "同じ数は呼ばない")
    }

    func testNoCallbackWhenNothingRunning() {
        let (st, calls) = watched()
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil, background: (agents: 0, shells: 2), backgroundOnly: 0)
        st.set(pane: "p1", state: "done", sessionId: "s1", cwd: nil, background: (agents: 0, shells: 2), backgroundOnly: 0)
        XCTAssertEqual(calls.value, [], "数が 0 のままなら呼ばない")
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil, background: (agents: 1, shells: 2), backgroundOnly: 1)
        st.set(pane: "p1", state: "working", sessionId: "s1", cwd: nil, background: (agents: 0, shells: 2), backgroundOnly: 0)
        XCTAssertEqual(calls.value, ["s1=1", "s1=0"])
    }
}
