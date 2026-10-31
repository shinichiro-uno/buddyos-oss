import Darwin
import XCTest
@testable import BridgeApp

/// ターミナルの Claude Code の hook → ClaudeTerminalRegistry（知らせのターン・内部の補助・Esc・サブエージェントの hook と
/// 選択肢・吹き出しの突き合わせ・ペインの状態）。実 claude は使わない。hook の形は claude 2.1.300 の実測
/// （docs/BACKGROUND_WORK_2026-10-21.md §1.2）に合わせている。
final class ClaudeTerminalHooksTests: XCTestCase {

    private typealias Events = AsyncThrowingStream<SessionEvent, Error>.Iterator

    /// 台帳に載せて attach した session と、そのイベントの読み口。
    private func open(_ registry: ClaudeTerminalRegistry) async throws
        -> (sid: String, session: ClaudeTerminalSession, events: Events) {
        let sid = "test-hooks-" + UUID().uuidString
        await registry.register(sessionId: sid, cwd: "/tmp", pid: nil, transcriptPath: nil)
        let session = ClaudeTerminalSession(agentId: "claude", sessionId: sid)
        await registry.attach(session)
        var events = session.events.makeAsyncIterator()
        _ = try await events.next()   // sessionStarted
        return (sid, session, events)
    }

    private func hook(_ sid: String, _ event: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var h: [String: Any] = ["session_id": sid, "hook_event_name": event]
        for (k, v) in extra { h[k] = v }
        return h
    }

    /// ここまでに流れたイベント。ingest は attach 中の session へ同期で push するので、印を流してそこまで読む。
    private func drain(_ session: ClaudeTerminalSession, _ events: inout Events) async throws -> [SessionEvent] {
        let mark = "mark-" + UUID().uuidString
        session.push(SessionEvent(type: .activity, agentId: "test", sessionId: session.sessionId, messageId: mark,
                                  toolUseId: nil, content: nil, toolName: nil, metadata: nil))
        var out: [SessionEvent] = []
        while let e = try await events.next(), e.messageId != mark { out.append(e) }
        return out
    }

    /// workflow_progress の payload の行（id → 行。同じ行が何度も来たら最後のもの）。
    private func rows(_ events: [SessionEvent]) -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for e in events where e.type == .workflowProgress {
            guard let data = e.content?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for a in obj["agents"] as? [[String: Any]] ?? [] {
                if let id = a["id"] as? String { out[id] = a }
            }
        }
        return out
    }

    /// トラッカーの全行（subagentSnapshot）。
    private func snapshotRows(_ registry: ClaudeTerminalRegistry, _ sid: String) async throws -> [String: [String: Any]] {
        let raw = await registry.subagentSnapshot(sessionId: sid)
        let json = try XCTUnwrap(raw)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(obj["kind"] as? String, "subagents")
        var out: [String: [String: Any]] = [:]
        for a in obj["agents"] as? [[String: Any]] ?? [] {
            if let id = a["id"] as? String { out[id] = a }
        }
        return out
    }

    private func paneEntry(_ pane: String) async -> TerminalPaneStatus.Entry? {
        await TerminalPaneStatus.shared.poll(since: -1, timeout: 0).entries.first { $0.pane == pane }
    }

    /// バックグラウンドで起動したサブエージェント（PreToolUse(Agent) → SubagentStart → PostToolUse の async_launched）。
    private func launchBackgroundAgent(_ registry: ClaudeTerminalRegistry, _ sid: String, id: String, toolUseId: String,
                                       description: String, type: String = "general-purpose", pane: String? = nil) async {
        let input: [String: Any] = ["description": description, "subagent_type": type, "prompt": "sleep"]
        _ = await registry.ingest(hook(sid, "PreToolUse", ["tool_name": "Agent", "tool_use_id": toolUseId,
                                                          "tool_input": input]), pane: pane)
        _ = await registry.ingest(hook(sid, "SubagentStart", ["agent_id": id, "agent_type": type]), pane: pane)
        _ = await registry.ingest(hook(sid, "PostToolUse", [
            "tool_name": "Agent", "tool_use_id": toolUseId, "tool_input": input,
            "tool_response": ["isAsync": true, "status": "async_launched", "agentId": id, "description": description],
        ]), pane: pane)
    }

    // MARK: - 知らせのターン

    /// 知らせのターン（バックグラウンドのサブエージェントが終わって CLI が自分から始めたターン。UserPromptSubmit の prompt は
    /// <task-notification> だけ）。終わった行を捨てず、吹き出しに出さず、done に origin を付ける。
    func testNotificationTurnKeepsFinishedRowsAndMarksDone() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events

        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "サブエージェントで調べて"]))
        await launchBackgroundAgent(registry, o.sid, id: "a1", toolUseId: "toolu_A", description: "probe sleeper A")
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m1", "index": 0, "final": true,
                                                                "delta": "launched"]))
        _ = await registry.ingest(hook(o.sid, "Stop", [
            "last_assistant_message": "launched",
            "background_tasks": [["id": "a1", "type": "subagent", "status": "running", "description": "probe sleeper A",
                                  "agent_type": "general-purpose"]],
        ]))
        var seen = try await drain(o.session, &events)
        XCTAssertEqual(seen.filter { $0.type == .done }.count, 1)
        XCTAssertNil(seen.last { $0.type == .done }?.metadata?["origin"], "頼んだターンの done には付けない")
        XCTAssertEqual(seen.filter { $0.type == .assistantDelta }.compactMap(\.content), ["launched"])
        XCTAssertEqual(rows(seen)["a1"]?["state"] as? String, "running")
        XCTAssertEqual(rows(seen)["a1"]?["background"] as? Bool, true)

        // サブエージェントが終わる。Stop のたびの次の発話の候補づくり（agent_type ""）は行にしない
        _ = await registry.ingest(hook(o.sid, "SubagentStop", ["agent_id": "a1", "agent_type": "general-purpose",
                                                              "last_assistant_message": "hi"]))
        _ = await registry.ingest(hook(o.sid, "SubagentStop", ["agent_id": "h1", "agent_type": "",
                                                              "last_assistant_message": "check on sleeper A"]))
        seen = try await drain(o.session, &events)
        XCTAssertEqual(rows(seen)["a1"]?["state"] as? String, "done")
        XCTAssertNil(rows(seen)["h1"])

        let notification = """
        <task-notification>
        <task-id>a1</task-id>
        <tool-use-id>toolu_A</tool-use-id>
        <status>completed</status>
        <summary>Agent "probe sleeper A" finished</summary>
        <result>hi</result>
        <usage><subagent_tokens>24570</subagent_tokens><tool_uses>1</tool_uses><duration_ms>24935</duration_ms></usage>
        </task-notification>
        """
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": notification]))
        let generating = await registry.generatingSessionIds()
        XCTAssertTrue(generating.contains(o.sid), "知らせのターンもターン（CLI は作業中）")
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m2", "index": 0, "final": true,
                                                                "delta": "The background subagent finished."]))
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "The background subagent finished.",
                                                      "background_tasks": [[String: Any]]()]))
        seen = try await drain(o.session, &events)
        XCTAssertFalse(seen.contains { $0.type == .userMessage }, "知らせは吹き出しに出さない")
        XCTAssertEqual(seen.last { $0.type == .done }?.metadata?["origin"], "task-notification")
        // 終わった行は知らせのターンでも捨てない（知らせの usage も入る）
        let snap = try await snapshotRows(registry, o.sid)
        XCTAssertEqual(snap["a1"]?["state"] as? String, "done")
        XCTAssertEqual(snap["a1"]?["result"] as? String, "hi")
        XCTAssertEqual(snap["a1"]?["tokens"] as? Int, 24570)

        // 次に頼んだターンで終わった行を捨てる。done に origin は付かない
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "ありがとう"]))
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "どういたしまして"]))
        seen = try await drain(o.session, &events)
        XCTAssertNil(seen.last { $0.type == .done }?.metadata?["origin"])
        let pruned = try await snapshotRows(registry, o.sid)
        XCTAssertTrue(pruned.isEmpty, "行が無くても agents: [] で返す")
        await registry.unregister(sessionId: o.sid)
    }

    // MARK: - 内部の補助

    /// 内部の補助（agent_id があり agent_type が空・無い）は最初に捨てる。行にも親のツール行にもペインの状態にもしない。
    func testInternalHelpersAreDroppedFirst() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events
        let pane = "test-pane-" + UUID().uuidString
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "やって"]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "やりました"]), pane: pane)
        _ = try await drain(o.session, &events)
        XCTAssertEqual(TerminalPaneStatus.shared.state(pane: pane, sessionId: o.sid), "done")

        // 次の発話の候補づくり（SubagentStop の agent_type ""。SubagentStart は来ない）
        let handled = await registry.ingest(hook(o.sid, "SubagentStop", ["agent_id": "h1", "agent_type": "",
                                                                        "last_assistant_message": "next?"]), pane: pane)
        XCTAssertTrue(handled)
        // バックグラウンドのエージェントの要約（PreToolUse に agent_type キーが無い。PostToolUse は来ない）
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["agent_id": "h2", "tool_name": "Bash", "tool_use_id": "toolu_h",
                                                            "tool_input": ["command": "ping -c 30 127.0.0.1"]]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "SubagentStart", ["agent_id": "h3", "agent_type": ""]), pane: pane)
        let seen = try await drain(o.session, &events)
        XCTAssertTrue(seen.isEmpty, "\(seen.map(\.type))")
        XCTAssertEqual(TerminalPaneStatus.shared.state(pane: pane, sessionId: o.sid), "done", "作業中に戻さない")
        let snap = try await snapshotRows(registry, o.sid)
        XCTAssertTrue(snap.isEmpty)
        // 次のターンの Stop で閉じる親のツール行も無い
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "次"]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "はい"]), pane: pane)
        let next = try await drain(o.session, &events)
        XCTAssertFalse(next.contains { $0.type == .toolEnd })
        await registry.unregister(sessionId: o.sid)
    }

    // MARK: - Esc

    /// Esc の中断（見張りの合成 Stop）。前景のサブエージェントと開いたままのツール行だけを閉じる。
    /// バックグラウンドのサブエージェントは Esc では止まらない（実測。後から SubagentStop と知らせのターンが来る）。
    func testEscClosesOnlyForegroundAgentsAndOpenTools() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events
        let pane = "test-pane-" + UUID().uuidString
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "調べて"]), pane: pane)
        await launchBackgroundAgent(registry, o.sid, id: "abg", toolUseId: "toolu_bg", description: "probe pinger C",
                                    pane: pane)
        // 前景のサブエージェント（終わるまで PostToolUse が来ない）
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["tool_name": "Agent", "tool_use_id": "toolu_fg",
                                                            "tool_input": ["description": "probe fg", "subagent_type": "Explore"]]),
                                  pane: pane)
        _ = await registry.ingest(hook(o.sid, "SubagentStart", ["agent_id": "afg", "agent_type": "Explore"]), pane: pane)
        // 親の前景の Bash（中断されると PostToolUse も PostToolUseFailure も来ない）
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_ping",
                                                            "tool_input": ["command": "ping -c 30 127.0.0.1"]]), pane: pane)
        _ = try await drain(o.session, &events)

        _ = await registry.ingest(["session_id": o.sid, "hook_event_name": "Stop", "buddy_interrupted": true])
        let seen = try await drain(o.session, &events)
        XCTAssertEqual(rows(seen)["afg"]?["state"] as? String, "stopped")
        XCTAssertNil(rows(seen)["abg"], "バックグラウンドの行は閉じない")
        let ends = seen.filter { $0.type == .toolEnd }
        XCTAssertEqual(Set(ends.compactMap(\.toolUseId)), ["toolu_ping", "toolu_fg"])
        XCTAssertTrue(ends.allSatisfy { $0.metadata?["status"] == "interrupted" })
        XCTAssertEqual(seen.last?.type, .done)
        let snap = try await snapshotRows(registry, o.sid)
        XCTAssertEqual(snap["abg"]?["state"] as? String, "running")
        var entry = await paneEntry(pane)
        XCTAssertEqual(entry?.state, "idle")
        XCTAssertEqual(entry?.backgroundAgents, 1)
        let generating = await registry.generatingSessionIds()
        XCTAssertFalse(generating.contains(o.sid))
        let background = await registry.backgroundSessionIds()
        XCTAssertTrue(background.contains(o.sid))

        // バックグラウンドのサブエージェントは後から終わる。そのツールは親のツール行にもペインの状態にも混ざらない
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["agent_id": "abg", "agent_type": "general-purpose",
                                                            "tool_name": "Bash", "tool_use_id": "toolu_sub",
                                                            "tool_input": ["command": "ping -c 40 127.0.0.1"]]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "PostToolUse", ["agent_id": "abg", "agent_type": "general-purpose",
                                                             "tool_name": "Bash", "tool_use_id": "toolu_sub",
                                                             "tool_input": ["command": "ping -c 40 127.0.0.1"],
                                                             "tool_response": ["stdout": "hi"]]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "SubagentStop", ["agent_id": "abg", "agent_type": "general-purpose",
                                                              "last_assistant_message": "hi"]), pane: pane)
        let late = try await drain(o.session, &events)
        XCTAssertFalse(late.contains { $0.type == .toolEnd || $0.type == .toolStart })
        XCTAssertEqual(rows(late)["abg"]?["state"] as? String, "done")
        entry = await paneEntry(pane)
        XCTAssertEqual(entry?.state, "idle")
        XCTAssertEqual(entry?.backgroundAgents, 0)
        let none = await registry.backgroundSessionIds()
        XCTAssertFalse(none.contains(o.sid))
        await registry.unregister(sessionId: o.sid)
    }

    // MARK: - サブエージェントの hook と選択肢

    /// サブエージェントの hook は、親の選択肢を閉じず、ペインの attention を作業中に戻さない。
    func testSubagentHooksKeepParentPromptAndAttention() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events
        let pane = "test-pane-" + UUID().uuidString
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "調べてから直して"]), pane: pane)
        await launchBackgroundAgent(registry, o.sid, id: "a1", toolUseId: "toolu_A", description: "Explore", type: "Explore",
                                    pane: pane)
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_main",
                                                            "tool_input": ["command": "rm -rf build"]]), pane: pane)
        let handled = await registry.ingestPermission(hook(o.sid, "PermissionRequest", [
            "tool_name": "Bash", "tool_input": ["command": "rm -rf build"],
        ]), pane: pane)
        XCTAssertTrue(handled)
        var seen = try await drain(o.session, &events)
        let card = try XCTUnwrap(seen.last { $0.type == .actionRequest })
        XCTAssertEqual(TerminalPaneStatus.shared.state(pane: pane, sessionId: o.sid), "attention")

        // 並んで動くサブエージェントが、同じ名前のツールを使う
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["agent_id": "a1", "agent_type": "Explore", "tool_name": "Bash",
                                                            "tool_use_id": "toolu_sub", "tool_input": ["command": "ls"]]),
                                  pane: pane)
        _ = await registry.ingest(hook(o.sid, "PostToolUse", ["agent_id": "a1", "agent_type": "Explore", "tool_name": "Bash",
                                                             "tool_use_id": "toolu_sub", "tool_input": ["command": "ls"],
                                                             "tool_response": ["stdout": "a"]]), pane: pane)
        seen = try await drain(o.session, &events)
        XCTAssertFalse(seen.contains { $0.type == .actionResolved }, "親の選択肢を閉じない")
        XCTAssertFalse(seen.contains { $0.type == .toolStart || $0.type == .toolEnd }, "親のツール行に混ぜない")
        XCTAssertEqual(TerminalPaneStatus.shared.state(pane: pane, sessionId: o.sid), "attention")
        let waiting = await registry.awaitingSessionIds()
        XCTAssertTrue(waiting.contains(o.sid))

        // 親のツールが実行されたら閉じる
        _ = await registry.ingest(hook(o.sid, "PostToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_main",
                                                             "tool_input": ["command": "rm -rf build"],
                                                             "tool_response": ["stdout": ""]]), pane: pane)
        seen = try await drain(o.session, &events)
        XCTAssertEqual(seen.first { $0.type == .actionResolved }?.messageId, card.messageId)
        XCTAssertEqual(TerminalPaneStatus.shared.state(pane: pane, sessionId: o.sid), "working")
        await registry.unregister(sessionId: o.sid)
    }

    /// サブエージェントの選択肢は、親の発話や Stop では閉じず、そのサブエージェントのツールの実行・終わりで閉じる。
    /// ほかに選択肢が無ければ、ペインの attention を外す（親のターンが終わっていれば idle。終わった 1 回には数えない）。
    func testSubagentPromptIsResolvedOnlyBySameAgent() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events
        let pane = "test-pane-" + UUID().uuidString
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "裏で調べて"]), pane: pane)
        await launchBackgroundAgent(registry, o.sid, id: "a1", toolUseId: "toolu_A", description: "Explore", type: "Explore",
                                    pane: pane)
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "調べています",
                                                      "background_tasks": [["id": "a1", "type": "subagent",
                                                                            "status": "running", "agent_type": "Explore"]]]),
                                  pane: pane)
        _ = try await drain(o.session, &events)

        // サブエージェントの許可の確認
        _ = await registry.ingestPermission(hook(o.sid, "PermissionRequest", [
            "agent_id": "a1", "agent_type": "Explore", "tool_name": "WebFetch", "tool_input": ["url": "https://example.com"],
        ]), pane: pane)
        var seen = try await drain(o.session, &events)
        let card = try XCTUnwrap(seen.last { $0.type == .actionRequest })
        // 親の発話と Stop では閉じない
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "まだ？"]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "まだです"]), pane: pane)
        seen = try await drain(o.session, &events)
        XCTAssertFalse(seen.contains { $0.type == .actionResolved && $0.messageId == card.messageId })
        // そのサブエージェントの同じツールが実行されたら閉じる
        _ = await registry.ingest(hook(o.sid, "PostToolUse", ["agent_id": "a1", "agent_type": "Explore", "tool_name": "WebFetch",
                                                             "tool_use_id": "toolu_w", "tool_input": ["url": "https://example.com"],
                                                             "tool_response": "ok"]), pane: pane)
        seen = try await drain(o.session, &events)
        XCTAssertEqual(seen.first { $0.type == .actionResolved }?.messageId, card.messageId)

        // 親のターンが終わった後の、サブエージェントの選択肢。サブエージェントが終われば閉じ、attention を外す
        let before = await paneEntry(pane)
        _ = await registry.ingestPermission(hook(o.sid, "PermissionRequest", [
            "agent_id": "a1", "agent_type": "Explore", "tool_name": "Bash", "tool_input": ["command": "curl x"],
        ]), pane: pane)
        seen = try await drain(o.session, &events)
        let second = try XCTUnwrap(seen.last { $0.type == .actionRequest })
        XCTAssertEqual(TerminalPaneStatus.shared.state(pane: pane, sessionId: o.sid), "attention")
        _ = await registry.ingest(hook(o.sid, "SubagentStop", ["agent_id": "a1", "agent_type": "Explore",
                                                              "last_assistant_message": "done"]), pane: pane)
        seen = try await drain(o.session, &events)
        XCTAssertEqual(seen.first { $0.type == .actionResolved }?.messageId, second.messageId)
        let after = await paneEntry(pane)
        XCTAssertEqual(after?.state, "idle")
        XCTAssertEqual(after?.turn, before?.turn, "終わった 1 回には数えない")
        let waiting = await registry.awaitingSessionIds()
        XCTAssertFalse(waiting.contains(o.sid))
        await registry.unregister(sessionId: o.sid)
    }

    // MARK: - 吹き出しの突き合わせ

    /// Stop の last_assistant_message で吹き出しを確かめ、足りない分を done の前に流す。遅れて届いた MessageDisplay は捨てる。
    func testStopFlushesMissingTextAndDropsLateDisplay() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events

        // 1) 最後の行バッチが Stop より遅れた（頭の部分は届いている）
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "q1"]))
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m1", "index": 0, "final": false,
                                                                "delta": "First line.\n\n"]))
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "First line.\n\nSecond line."]))
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m1", "index": 1, "final": true,
                                                                "delta": "Second line."]))
        var seen = try await drain(o.session, &events)
        var deltas = seen.filter { $0.type == .assistantDelta }
        XCTAssertEqual(deltas.compactMap(\.content), ["First line.\n\n", "Second line."])
        XCTAssertEqual(Set(deltas.compactMap(\.messageId)).count, 1, "同じ吹き出しに足す")
        XCTAssertEqual(seen.last?.type, .done, "遅れた本文を done の後に流さない")

        // 2) 本文が丸ごと Stop より遅れた（短い返事は final の 1 つに全部入る）
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "q2"]))
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "launched"]))
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m2", "index": 0, "final": true,
                                                                "delta": "launched"]))
        seen = try await drain(o.session, &events)
        deltas = seen.filter { $0.type == .assistantDelta }
        XCTAssertEqual(deltas.compactMap(\.content), ["launched"])
        let done = try XCTUnwrap(seen.last)
        XCTAssertEqual(done.type, .done)
        XCTAssertEqual(deltas.first?.messageId, done.messageId, "ターンの最初の吹き出し")

        // 3) ツールの前の前置きは届いたが、最後のメッセージがまだ → 新しい吹き出しで全部を流す
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "q3"]))
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m3", "index": 0, "final": true,
                                                                "delta": "Let me check."]))
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["tool_name": "Read", "tool_use_id": "toolu_r",
                                                            "tool_input": ["file_path": "/tmp/a"]]))
        _ = await registry.ingest(hook(o.sid, "PostToolUse", ["tool_name": "Read", "tool_use_id": "toolu_r",
                                                             "tool_input": ["file_path": "/tmp/a"], "tool_response": "ok"]))
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "All good."]))
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m4", "index": 0, "final": true,
                                                                "delta": "All good."]))
        seen = try await drain(o.session, &events)
        deltas = seen.filter { $0.type == .assistantDelta }
        XCTAssertEqual(deltas.compactMap(\.content), ["Let me check.", "All good."])
        XCTAssertNotEqual(deltas.first?.messageId, deltas.last?.messageId)
        XCTAssertEqual(seen.last?.type, .done)

        // 4) 全部届いていれば何も足さない。同じ Stop が重ねて届いても流し直さない
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "q4"]))
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m5", "index": 0, "final": true,
                                                                "delta": "Done."]))
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "Done."]))
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "Done."]))
        seen = try await drain(o.session, &events)
        XCTAssertEqual(seen.filter { $0.type == .assistantDelta }.compactMap(\.content), ["Done."])
        await registry.unregister(sessionId: o.sid)
    }

    // MARK: - ペインの turn とバックグラウンドの数

    /// ペインの turn は、main のスレッドが動いた後の Stop ごとに増える（バックグラウンドの作業が残っていても、知らせのターンでも、
    /// 本文だけのターンでも）。動いている数は backgroundAgents / backgroundShells で別に持つ。
    /// SessionEnd の後も、同じペインの turn は続きから数える。
    func testPaneTurnsAndBackgroundCounts() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        let pane = "test-pane-" + UUID().uuidString
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "裏で 2 つ"]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "PreToolUse", [
            "tool_name": "Bash", "tool_use_id": "toolu_B",
            "tool_input": ["command": "sleep 40; echo done", "description": "probe bg shell E", "run_in_background": true],
        ]), pane: pane)
        await launchBackgroundAgent(registry, o.sid, id: "aE", toolUseId: "toolu_A", description: "probe sleeper E", pane: pane)
        _ = await registry.ingest(hook(o.sid, "PostToolUse", [
            "tool_name": "Bash", "tool_use_id": "toolu_B",
            "tool_input": ["command": "sleep 40; echo done", "description": "probe bg shell E", "run_in_background": true],
            "tool_response": ["stdout": "", "backgroundTaskId": "bE"],
        ]), pane: pane)
        var e = await paneEntry(pane)
        XCTAssertEqual(e?.state, "working")
        XCTAssertEqual(e?.backgroundAgents, 1)
        XCTAssertEqual(e?.backgroundShells, 1)
        let start = e?.turn ?? 0

        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m1", "final": true, "delta": "both"]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "Stop", [
            "last_assistant_message": "both",
            "background_tasks": [
                ["id": "aE", "type": "subagent", "status": "running", "description": "probe sleeper E",
                 "agent_type": "general-purpose"],
                ["id": "bE", "type": "shell", "status": "running", "description": "probe bg shell E",
                 "command": "sleep 40; echo done"],
            ],
        ]), pane: pane)
        e = await paneEntry(pane)
        XCTAssertEqual(e?.state, "done", "main のターンは終わった（返事を読み上げる）")
        XCTAssertEqual(e?.turn, start + 1)
        XCTAssertEqual(e?.reply, "both")
        XCTAssertEqual(e?.backgroundAgents, 1)
        XCTAssertEqual(e?.backgroundShells, 1)

        // サブエージェントが終わる。状態と turn はそのまま、数だけ変わる
        _ = await registry.ingest(hook(o.sid, "SubagentStop", ["agent_id": "aE", "agent_type": "general-purpose",
                                                              "last_assistant_message": "hi"]), pane: pane)
        e = await paneEntry(pane)
        XCTAssertEqual(e?.state, "done")
        XCTAssertEqual(e?.turn, start + 1)
        XCTAssertEqual(e?.backgroundAgents, 0)

        // 知らせのターン（サブエージェント）。シェルが残ったまま終わる
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", [
            "prompt": "<task-notification>\n<task-id>aE</task-id>\n<status>completed</status>\n<summary>Agent \"probe sleeper E\" finished</summary>\n<result>hi</result>\n</task-notification>",
        ]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "Stop", [
            "last_assistant_message": "The agent finished; the shell is still running.",
            "background_tasks": [["id": "bE", "type": "shell", "status": "running", "description": "probe bg shell E"]],
        ]), pane: pane)
        e = await paneEntry(pane)
        XCTAssertEqual(e?.turn, start + 2)
        XCTAssertEqual(e?.backgroundShells, 1)

        // 本文だけで終わるターン（UserPromptSubmit の来ない古い形）。done → done でも数える
        _ = await registry.ingest(hook(o.sid, "MessageDisplay", ["message_id": "m3", "final": true,
                                                                "delta": "The shell finished."]), pane: pane)
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "The shell finished.",
                                                      "background_tasks": [[String: Any]]()]), pane: pane)
        e = await paneEntry(pane)
        XCTAssertEqual(e?.state, "done")
        XCTAssertEqual(e?.turn, start + 3)
        XCTAssertEqual(e?.reply, "The shell finished.")
        XCTAssertEqual(e?.backgroundShells, 0, "Stop の一覧に無いシェルは閉じる")
        // 動きの無い Stop の重複は数えない
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "The shell finished."]), pane: pane)
        e = await paneEntry(pane)
        XCTAssertEqual(e?.turn, start + 3)

        // SessionEnd（/clear）の後、同じペインの新しい会話は続きから数える
        _ = await registry.ingest(hook(o.sid, "SessionEnd", ["reason": "clear"]), pane: pane)
        let removed = await paneEntry(pane)
        XCTAssertNil(removed)
        let sid2 = "test-hooks-" + UUID().uuidString
        await registry.register(sessionId: sid2, cwd: "/tmp", pid: nil, transcriptPath: nil)
        _ = await registry.ingest(hook(sid2, "UserPromptSubmit", ["prompt": "新しい会話"]), pane: pane)
        _ = await registry.ingest(hook(sid2, "Stop", ["last_assistant_message": "はい"]), pane: pane)
        e = await paneEntry(pane)
        XCTAssertEqual(e?.sessionId, sid2)
        XCTAssertEqual(e?.turn, start + 4)
        await registry.unregister(sessionId: sid2)
    }

    // MARK: - トラッカーへの PostToolUse

    /// TaskStop は止めた行をすぐ stopped で閉じる（止めたシェルには完了の知らせが来ない）。サブエージェントの中の Agent の
    /// 起動（async_launched）も、tool_response の agentId で行にする。
    func testTaskStopAndNestedLaunchReachTracker() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events
        let bash: [String: Any] = ["command": "ping 127.0.0.1 > /dev/null", "description": "probe endless G",
                                   "run_in_background": true]
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "ping を裏で"]))
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_G", "tool_input": bash]))
        _ = await registry.ingest(hook(o.sid, "PostToolUse", ["tool_name": "Bash", "tool_use_id": "toolu_G", "tool_input": bash,
                                                             "tool_response": ["stdout": "", "backgroundTaskId": "bG"]]))
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "started", "background_tasks": [
            ["id": "bG", "type": "shell", "status": "running", "description": "probe endless G"],
        ]]))
        var seen = try await drain(o.session, &events)
        XCTAssertEqual(rows(seen)["bG"]?["state"] as? String, "running")
        XCTAssertEqual(rows(seen)["bG"]?["rowKind"] as? String, "shell")

        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "止めて"]))
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["tool_name": "TaskStop", "tool_use_id": "toolu_S",
                                                            "tool_input": ["task_id": "bG"]]))
        _ = await registry.ingest(hook(o.sid, "PostToolUse", [
            "tool_name": "TaskStop", "tool_use_id": "toolu_S", "tool_input": ["task_id": "bG"],
            "tool_response": ["message": "Successfully stopped task: bG", "task_id": "bG", "task_type": "local_bash"],
        ]))
        seen = try await drain(o.session, &events)
        XCTAssertEqual(rows(seen)["bG"]?["state"] as? String, "stopped")
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "stopped",
                                                      "background_tasks": [[String: Any]]()]))
        var snap = try await snapshotRows(registry, o.sid)
        XCTAssertEqual(snap["bG"]?["state"] as? String, "stopped", "Stop の照合で done に戻さない")

        // サブエージェントの中から、さらにバックグラウンドのエージェントを起動する
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "入れ子で"]))
        await launchBackgroundAgent(registry, o.sid, id: "aO", toolUseId: "toolu_O", description: "outer")
        let inner: [String: Any] = ["description": "inner", "subagent_type": "Explore", "prompt": "look"]
        _ = await registry.ingest(hook(o.sid, "PreToolUse", ["agent_id": "aO", "agent_type": "general-purpose",
                                                            "tool_name": "Agent", "tool_use_id": "toolu_N", "tool_input": inner]))
        _ = await registry.ingest(hook(o.sid, "SubagentStart", ["agent_id": "aN", "agent_type": "Explore"]))
        _ = await registry.ingest(hook(o.sid, "PostToolUse", [
            "agent_id": "aO", "agent_type": "general-purpose", "tool_name": "Agent", "tool_use_id": "toolu_N",
            "tool_input": inner, "tool_response": ["status": "async_launched", "agentId": "aN"],
        ]))
        seen = try await drain(o.session, &events)
        XCTAssertFalse(seen.contains { $0.toolUseId == "toolu_N" }, "サブエージェントのツールは親のツール行に出さない")
        snap = try await snapshotRows(registry, o.sid)
        XCTAssertEqual(snap["aN"]?["state"] as? String, "running")
        XCTAssertEqual(snap["aN"]?["label"] as? String, "inner")
        XCTAssertEqual(snap["aN"]?["background"] as? Bool, true)
        await registry.unregister(sessionId: o.sid)
    }

    // MARK: - 台帳

    /// attach したとき、行があれば（動いていなくても）全行を渡す。
    func testAttachSendsSnapshotWhenRowsExist() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-hooks-" + UUID().uuidString
        await registry.register(sessionId: sid, cwd: "/tmp", pid: nil, transcriptPath: nil)
        let empty = await registry.subagentSnapshot(sessionId: sid)
        XCTAssertTrue(empty?.contains("\"agents\":[]") == true, "行が無くても agents: [] で返す")
        let unknown = await registry.subagentSnapshot(sessionId: "missing-" + UUID().uuidString)
        XCTAssertNil(unknown)
        // 誰も見ていない間に、サブエージェントが起動して終わった
        _ = await registry.ingest(hook(sid, "UserPromptSubmit", ["prompt": "調べて"]))
        await launchBackgroundAgent(registry, sid, id: "a1", toolUseId: "toolu_A", description: "probe")
        _ = await registry.ingest(hook(sid, "Stop", ["last_assistant_message": "launched", "background_tasks": [
            ["id": "a1", "type": "subagent", "status": "running", "agent_type": "general-purpose"],
        ]]))
        _ = await registry.ingest(hook(sid, "SubagentStop", ["agent_id": "a1", "agent_type": "general-purpose",
                                                            "last_assistant_message": "hi"]))
        let session = ClaudeTerminalSession(agentId: "claude", sessionId: sid)
        await registry.attach(session)
        var events = session.events.makeAsyncIterator()
        _ = try await events.next()   // sessionStarted
        let seen = try await drain(session, &events)
        let snap = try XCTUnwrap(seen.first { $0.type == .workflowProgress })
        XCTAssertTrue(snap.content?.contains("\"workflow_snapshot\"") == true)
        XCTAssertEqual(rows(seen)["a1"]?["state"] as? String, "done")
        await registry.unregister(sessionId: sid)
    }

    /// 知らせと発話が 1 つの UserPromptSubmit に混ざった（ターン中に打った発話と、その間に終わった作業の知らせ）。知らせで
    /// 行を閉じ（payload）、その後に発話（user_message）を流す。行は知らせを取り込んだ後に捨てる（SessionHub とアプリは
    /// payload の後の user_message で捨てるので、トラッカーにだけ残って、接続のたびの全行で戻ることが無い）。
    func testMixedNotificationAndUtterancePrunesAfterClosingRows() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "調べて"]))
        await launchBackgroundAgent(registry, o.sid, id: "a1", toolUseId: "toolu_A", description: "probe")
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "launched", "background_tasks": [
            ["id": "a1", "type": "subagent", "status": "running", "agent_type": "general-purpose"],
        ]]))
        _ = try await drain(o.session, &events)
        let prompt = "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n"
            + "<summary>Agent \"probe\" finished</summary>\n<result>見つかりました</result>\n</task-notification>\n次はこれを直して"
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": prompt]))
        let seen = try await drain(o.session, &events)
        XCTAssertEqual(rows(seen)["a1"]?["state"] as? String, "done")
        let rowIndex = try XCTUnwrap(seen.firstIndex { $0.type == .workflowProgress })
        let userIndex = try XCTUnwrap(seen.firstIndex { $0.type == .userMessage })
        XCTAssertLessThan(rowIndex, userIndex, "行を閉じてから発話を流す")
        XCTAssertEqual(seen[userIndex].content, "次はこれを直して")
        let snapshot = try await snapshotRows(registry, o.sid)
        XCTAssertNil(snapshot["a1"], "この発話で閉じた行がトラッカーにだけ残った")
        await registry.unregister(sessionId: o.sid)
    }

    /// claude が終わる（SessionEnd）と、バックグラウンドの作業も止まり、終わりの知らせはもう来ない。見ている session には
    /// 実行中の行を stopped で閉じる payload を、終わりの done より先に流す（カードに「実行中」を残さない）。
    func testSessionEndStopsRunningRowsBeforeDone() async throws {
        let registry = ClaudeTerminalRegistry()
        let o = try await open(registry)
        var events = o.events
        _ = await registry.ingest(hook(o.sid, "UserPromptSubmit", ["prompt": "調べて"]))
        await launchBackgroundAgent(registry, o.sid, id: "a1", toolUseId: "toolu_A", description: "probe")
        _ = await registry.ingest(hook(o.sid, "Stop", ["last_assistant_message": "launched", "background_tasks": [
            ["id": "a1", "type": "subagent", "status": "running", "agent_type": "general-purpose"],
        ]]))
        let before = try await drain(o.session, &events)
        XCTAssertEqual(rows(before)["a1"]?["state"] as? String, "running")
        _ = await registry.ingest(hook(o.sid, "SessionEnd", ["reason": "prompt_input_exit"]))
        var after: [SessionEvent] = []
        while let e = try await events.next() { after.append(e) }
        XCTAssertEqual(rows(after)["a1"]?["state"] as? String, "stopped", "実行中の行を残した")
        let rowIndex = try XCTUnwrap(after.firstIndex { $0.type == .workflowProgress })
        let doneIndex = try XCTUnwrap(after.firstIndex { $0.type == .done })
        XCTAssertLessThan(rowIndex, doneIndex, "行を閉じてから done")
    }

    /// SessionEnd を出さずに claude が終わった（ウィンドウを閉じた・落ちた）session は、running / background に残さない。
    func testDeadSessionsAreDroppedFromLists() async throws {
        let registry = ClaudeTerminalRegistry()
        let dead = "test-dead-" + UUID().uuidString
        let alive = "test-alive-" + UUID().uuidString
        await registry.register(sessionId: dead, cwd: "/tmp", pid: 1_000_000, transcriptPath: nil)   // 無い pid
        await registry.register(sessionId: alive, cwd: "/tmp", pid: getpid(), transcriptPath: nil)
        for sid in [dead, alive] {
            _ = await registry.ingest(hook(sid, "UserPromptSubmit", ["prompt": "x"]))
        }
        let generating = await registry.generatingSessionIds()
        XCTAssertFalse(generating.contains(dead))
        XCTAssertTrue(generating.contains(alive))
        let stillListed = await registry.contains(sessionId: dead)
        XCTAssertFalse(stillListed, "台帳から落とす")
        await registry.unregister(sessionId: alive)
    }

    // MARK: - claude --bg のワーカー（hooks で載ったもの。BACKGROUND_CONTROL §7.8）

    /// 答えられないので、カードも push も出さない（prompts に積まない = awaiting にも出ない）。
    func testBackgroundWorkerPermissionMakesNoCard() async throws {
        let registry = ClaudeTerminalRegistry()
        await registry.setBackgroundWorkerCheck { _ in true }
        var o = try await open(registry)
        let handled = await registry.ingestPermission(hook(o.sid, "PermissionRequest", [
            "tool_name": "Bash", "tool_input": ["command": "rm x"]]))
        XCTAssertTrue(handled)
        let events = try await drain(o.session, &o.events)
        XCTAssertFalse(events.contains { $0.type == .actionRequest })
        let waiting = await registry.awaitingSessionIds()
        XCTAssertFalse(waiting.contains(o.sid))
        await registry.unregister(sessionId: o.sid)
    }

    func testOrdinaryTerminalPermissionStillMakesCard() async throws {
        let registry = ClaudeTerminalRegistry()
        await registry.setBackgroundWorkerCheck { _ in false }
        var o = try await open(registry)
        _ = await registry.ingestPermission(hook(o.sid, "PermissionRequest", [
            "tool_name": "Bash", "tool_input": ["command": "rm x"]]))
        let events = try await drain(o.session, &o.events)
        XCTAssertTrue(events.contains { $0.type == .actionRequest })
        await registry.unregister(sessionId: o.sid)
    }

    func testBackgroundWorkerInterruptSaysUseStop() async throws {
        let registry = ClaudeTerminalRegistry()
        await registry.setBackgroundWorkerCheck { _ in true }
        let o = try await open(registry)
        let problem = await registry.interrupt(sessionId: o.sid)
        XCTAssertEqual(problem, ClaudeBackgroundSession.interruptText)
        await registry.unregister(sessionId: o.sid)
    }
}
