import XCTest
@testable import BridgeApp

/// mainagent の道具（Orchestrator）と `/mcp` の JSON-RPC、mainagent のフォルダ・起動引数を確かめる。
/// 子のセッションは SessionProtocolTests の ScriptedAdapter / ScriptedSession で作り、本番と同じく SessionHub を通す。
final class OrchestratorTests: XCTestCase {
    private func uniq(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())" }
    private let caller = Orchestrator.Caller(token: "test", agentId: "claude", parentSessionId: nil)

    override func tearDown() async throws {
        await Orchestrator.shared.setBackgroundSettleSecondsForTesting(120)
    }

    /// 新規は仮 ID で開き、最初の送信で確定 ID を知らせてから "echo: <本文>" を返す adapter。
    /// gate を渡すと、返事の途中（delta の後）で止まる。approval を渡すと承認の要求を出して止まる。
    private func scripted(_ agentId: String, realId: String, gate: Gate? = nil, approval: Bool = false) async -> ScriptedAdapter {
        let adapter = ScriptedAdapter(id: agentId) { sid in
            let s = ScriptedSession(agentId: agentId, sessionId: sid ?? "pending-\(UUID().uuidString.prefix(8))")
            s.onSend = { s, text, n in
                if n == 1, sid == nil { s.emit(.sessionStarted(agentId: agentId, sessionId: realId)) }
                let mid = "m-\(n)"
                if approval, n == 1 {
                    s.emit(.actionRequest(agentId: agentId, sessionId: realId, messageId: "req-1",
                                          title: "Bash: rm -rf build", subtitle: nil, metadata: [:]))
                }
                s.emit(.assistantDelta("echo: \(text)", agentId: agentId, sessionId: realId, messageId: mid))
                if n == 1, let gate { await gate.wait() }
                s.emit(.done(agentId: agentId, sessionId: realId, messageId: mid))
            }
            return s
        }
        await AgentRegistry.shared.register(adapter)
        return adapter
    }

    /// mainagent 役のセッション（iPhone 1 台が見ている）と、その合鍵。承認カードはこの接続に届く。
    private func mainagent() async -> (Orchestrator.Caller, TestConnection) {
        let (caller, conn, _) = await mainagentWithAdapter()
        return (caller, conn)
    }

    private func mainagentWithAdapter() async -> (Orchestrator.Caller, TestConnection, ScriptedAdapter) {
        let agent = uniq("main")
        let sid = uniq("msid")
        let adapter = ScriptedAdapter(id: agent) { s in ScriptedSession(agentId: agent, sessionId: s ?? sid) }
        let conn = await TestConnection.open(adapter, sessionId: sid)
        let token = await Orchestrator.shared.issueToken(agentId: agent, parentSessionId: sid)
        return (Orchestrator.Caller(token: token, agentId: agent, parentSessionId: sid), conn, adapter)
    }

    /// n 枚目（0 始まり）の承認カードに答える。
    @discardableResult
    private func answerNth(_ conn: TestConnection, _ caller: Orchestrator.Caller, _ n: Int, _ decision: String) async throws -> SessionEvent {
        _ = try await conn.until("\(n + 1) 枚目の承認カード") { _ in conn.events.filter { $0.type == .actionRequest }.count > n }
        let card = conn.events.filter { $0.type == .actionRequest }[n]
        let id = card.messageId ?? ""
        await conn.send(["type": "action_response", "agentId": caller.agentId, "sessionId": caller.parentSessionId ?? "",
                         "messageId": id, "content": decision, "metadata": ["requestId": id, "decision": decision]])
        return card
    }

    /// 最初の送信で承認を出して止まる子。答え（respondToAction）が届いたら "answered: <答え>" を返して終わる。
    private func approvingChild(_ agentId: String, realId: String, options: [(String, String)]) async -> ScriptedBox {
        let box = ScriptedBox()
        let adapter = ScriptedAdapter(id: agentId) { sid in
            let s = ScriptedSession(agentId: agentId, sessionId: sid ?? "pending-\(UUID().uuidString.prefix(8))")
            box.session = s
            s.onSend = { s, _, n in
                if n == 1, sid == nil { s.emit(.sessionStarted(agentId: agentId, sessionId: realId)) }
                var meta: [String: String] = ["requestId": "req-\(n)", "kind": "approval", "allowsOther": "0",
                                              "option_count": String(options.count)]
                for (i, o) in options.enumerated() {
                    meta["option_\(i)_value"] = o.0
                    meta["option_\(i)_title"] = o.1
                }
                s.emit(.actionRequest(agentId: agentId, sessionId: realId, messageId: "req-\(n)",
                                      title: "「Bash」を実行しますか？", subtitle: "npm test", metadata: meta))
            }
            s.onAnswer = { s, requestId, decision in
                s.emit(.assistantDelta("answered: \(decision)", agentId: agentId, sessionId: realId, messageId: "a-\(requestId)"))
                s.emit(.done(agentId: agentId, sessionId: realId, messageId: "a-\(requestId)"))
            }
            return s
        }
        await AgentRegistry.shared.register(adapter)
        return box
    }

    /// 届いた子のカード（workflow_progress kind = "sessions"）。
    private func sessionsCards(_ conn: TestConnection) -> [[String: Any]] {
        conn.events.filter { $0.type == .workflowProgress }.compactMap { e in
            e.content.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }.filter { $0["kind"] as? String == "sessions" }
    }

    private func sessionsRow(_ e: SessionEvent, agent: String) -> [String: Any]? {
        guard e.type == .workflowProgress, let d = e.content?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              obj["kind"] as? String == "sessions" else { return nil }
        return (obj["agents"] as? [[String: Any]])?.first { $0["agentId"] as? String == agent }
    }

    /// 次の承認カードに、iPhone と同じ action_response で答える。カードを返す。
    @discardableResult
    private func answer(_ conn: TestConnection, _ caller: Orchestrator.Caller, _ decision: String) async throws -> SessionEvent {
        let card = try await conn.until("承認カード") { $0.type == .actionRequest }
        let id = card.messageId ?? ""
        await conn.send(["type": "action_response", "agentId": caller.agentId, "sessionId": caller.parentSessionId ?? "",
                         "messageId": id, "content": decision, "metadata": ["requestId": id, "decision": decision]])
        return card
    }

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(uniq("orch"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 道具

    func testStartSessionThenGetReply() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        _ = await scripted(agent, realId: real)
        let dir = try tmpDir()

        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "hello")
        let card = try await answer(conn, caller, "allow")
        XCTAssertEqual(card.metadata?["kind"], "approval")
        XCTAssertTrue((card.metadata?["subtitle"] ?? "").contains("hello"), "頼む文がカードに出る")
        let started = try await starting
        XCTAssertEqual(started["session_id"] as? String, real, "確定した ID を返す")
        _ = try await conn.until("カードを閉じる") { $0.type == .actionResolved && $0.messageId == card.messageId }
        XCTAssertEqual(started["confirmed"] as? Bool, true)

        let reply = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(reply["status"] as? String, "done")
        XCTAssertEqual(reply["reply"] as? String, "echo: hello")

        let rows = await Orchestrator.shared.listSessions(caller: caller).filter { $0["agent"] as? String == agent }
        XCTAssertEqual(rows.first?["session_id"] as? String, real)
        XCTAssertEqual(rows.first?["last_request"] as? String, "hello")
    }

    func testSendWhileWorkingIsQueuedAndRunsAfterDone() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        let gate = Gate()
        _ = await scripted(agent, realId: real, gate: gate)
        let dir = try tmpDir()

        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "first")
        try await answer(conn, caller, "allowForSession")
        _ = try await starting
        let running = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 0)
        XCTAssertEqual(running["status"] as? String, "running")

        // 「このセッションでは承認」の後は尋ねない。
        let sent = try await Orchestrator.shared.sendMessage(caller: caller, agentId: agent, sessionId: real, text: "second")
        XCTAssertEqual(sent["state"] as? String, "queued", "作業中は予約に積む")
        XCTAssertEqual(conn.events.filter { $0.type == .actionRequest }.count, 1)

        gate.open()
        let reply = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(reply["status"] as? String, "done")
        XCTAssertEqual(reply["reply"] as? String, "echo: second", "後から送った分の返事")
    }

    /// 頼んだ発話が子の待ち行列にある間に、子が自分から始めた知らせのターン（バックグラウンドの作業の完了。done の
    /// metadata.origin = "task-notification"）が先に終わっても、それを頼んだ発話の返事にしない。返事は後から来る発話のターンのもの。
    func testNotificationTurnBeforeTheReplyIsNotTheReply() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        let adapter = ScriptedAdapter(id: agent) { sid in
            let s = ScriptedSession(agentId: agent, sessionId: sid ?? "pending-\(UUID().uuidString.prefix(8))")
            s.onSend = { s, text, n in
                if n == 1, sid == nil { s.emit(.sessionStarted(agentId: agent, sessionId: real)) }
                if n == 2 {
                    s.emit(.assistantDelta("調査が終わりました。", agentId: agent, sessionId: real, messageId: "n-1"))
                    s.emit(SessionEvent.done(agentId: agent, sessionId: real, messageId: "n-1")
                        .addingMetadata(["origin": "task-notification"]))
                }
                s.emit(.assistantDelta("echo: \(text)", agentId: agent, sessionId: real, messageId: "m-\(n)"))
                s.emit(.done(agentId: agent, sessionId: real, messageId: "m-\(n)"))
            }
            return s
        }
        await AgentRegistry.shared.register(adapter)
        let dir = try tmpDir()

        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "first")
        try await answer(conn, caller, "allowForSession")
        _ = try await starting
        let first = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(first["reply"] as? String, "echo: first")

        _ = try await Orchestrator.shared.sendMessage(caller: caller, agentId: agent, sessionId: real, text: "second")
        let reply = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(reply["status"] as? String, "done")
        XCTAssertEqual(reply["reply"] as? String, "echo: second", "知らせのターンの本文を返事にした")
        XCTAssertNil(reply["earlier"], "知らせのターンの本文が返事に混ざった")
    }

    /// 起動だけのターン（バックグラウンドのサブエージェントを起こした）で、子の done が先に来る（Claude 2.1.300 の既定。
    /// 実測 S1）。最初の送信では行を始めて起動の文と done を出し、follow で作業の終わり方を選ぶ子。
    private func backgroundChild(_ agentId: String, realId: String) async -> ScriptedBox {
        var tracker = SubagentTracker()
        let begin = tracker.begin(key: "a1", label: "調査", agentType: "Explore", background: true) ?? ""
        let box = ScriptedBox()
        let adapter = ScriptedAdapter(id: agentId) { sid in
            let s = ScriptedSession(agentId: agentId, sessionId: sid ?? "pending-\(UUID().uuidString.prefix(8))")
            box.session = s
            s.onSend = { s, _, n in
                if n == 1, sid == nil { s.emit(.sessionStarted(agentId: agentId, sessionId: realId)) }
                s.emit(.workflowProgress(agentId: agentId, sessionId: realId, payloadJSON: begin))
                s.emit(.assistantDelta("Explore で調べています。", agentId: agentId, sessionId: realId, messageId: "m-\(n)"))
                s.emit(.done(agentId: agentId, sessionId: realId, messageId: "m-\(n)"))
            }
            return s
        }
        box.finishPayload = tracker.finish(key: "a1", state: "done", result: "原因は X")
        await AgentRegistry.shared.register(adapter)
        return box
    }

    /// 子のバックグラウンドの作業が動いている間は、起動の返事で done にしない（status は running。結果待ちの hint）。
    /// 結論を運ぶ知らせのターンの本文を返事にする（起動の返事は earlier）。待つ間は購読も外さない。
    func testReplyWaitsForBackgroundWorkAndUsesTheNotificationTurn() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        let box = await backgroundChild(agent, realId: real)
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "調べて")
        try await answer(conn, caller, "allowForSession")
        _ = try await starting

        let waiting = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 1)
        XCTAssertEqual(waiting["status"] as? String, "running", "起動の返事で done にした")
        XCTAssertEqual(waiting["reply"] as? String, "Explore で調べています。")
        XCTAssertTrue((waiting["hint"] as? String ?? "").contains("結果待ち"))

        let s = try XCTUnwrap(box.session)
        s.emit(.workflowProgress(agentId: agent, sessionId: real, payloadJSON: try XCTUnwrap(box.finishPayload)))
        s.emit(.activity(agentId: agent, sessionId: real, messageId: "n-1", text: ""))
        s.emit(.assistantDelta("原因は X でした。", agentId: agent, sessionId: real, messageId: "n-1"))
        s.emit(SessionEvent.done(agentId: agent, sessionId: real, messageId: "n-1").addingMetadata(["origin": "task-notification"]))
        let reply = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(reply["status"] as? String, "done")
        XCTAssertEqual(reply["reply"] as? String, "原因は X でした。", "知らせのターンの結論を返事にしていない")
        XCTAssertEqual((reply["earlier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "Explore で調べています。")
    }

    /// 作業が終わっても知らせのターンが来ない（子が終わっても親が起きない CLI。Codex の multi-agent v2）。猶予の後に、
    /// 起動の返事のまま done にする（永久に running で待たせない）。
    func testReplySettlesWhenBackgroundEndsWithoutWakeTurn() async throws {
        await Orchestrator.shared.setBackgroundSettleSecondsForTesting(0.3)
        let agent = uniq("agent")
        let real = uniq("sid")
        let box = await backgroundChild(agent, realId: real)
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "調べて")
        try await answer(conn, caller, "allowForSession")
        _ = try await starting
        let waiting = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 1)
        XCTAssertEqual(waiting["status"] as? String, "running")

        let s = try XCTUnwrap(box.session)
        s.emit(.workflowProgress(agentId: agent, sessionId: real, payloadJSON: try XCTUnwrap(box.finishPayload)))
        let reply = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(reply["status"] as? String, "done")
        XCTAssertEqual(reply["reply"] as? String, "Explore で調べています。")
    }

    func testApprovalIsReportedAsNeedsApproval() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        let gate = Gate()
        _ = await scripted(agent, realId: real, gate: gate, approval: true)
        let dir = try tmpDir()

        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "clean")
        try await answer(conn, caller, "allow")
        _ = try await starting
        let waiting = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(waiting["status"] as? String, "needs_approval")
        XCTAssertEqual((waiting["approval"] as? [String: Any])?["title"] as? String, "Bash: rm -rf build")
        // 承認待ちは待たずにすぐ返す（mainagent がユーザーに伝えるため）。続きは done が届くまで聞き直す。
        gate.open()
        var status: String?
        for _ in 0..<50 {
            status = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 0)["status"] as? String
            if status == "done" { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(status, "done")
    }

    func testDeniedRequestIsNotSent() async throws {
        let agent = uniq("agent")
        let adapter = ScriptedAdapter(id: agent) { sid in ScriptedSession(agentId: agent, sessionId: sid ?? "pending-x") }
        await AgentRegistry.shared.register(adapter)
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "delete build")
        try await answer(conn, caller, "deny")
        do {
            _ = try await starting
            XCTFail("断ったら頼まない")
        } catch {
            XCTAssertTrue("\(error)".contains("承認しなかった"), "\(error)")
        }
        let rows = await Orchestrator.shared.listSessions(caller: caller).filter { $0["agent"] as? String == agent }
        XCTAssertTrue(rows.isEmpty, "セッションも起こさない")
    }

    func testWaitSecondsReturnsReplyWithTheRequest() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        _ = await scripted(agent, realId: real)
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path,
                                                              prompt: "now", waitSeconds: 5)
        try await answer(conn, caller, "allow")
        let r = try await starting
        XCTAssertEqual(r["status"] as? String, "done")
        XCTAssertEqual(r["reply"] as? String, "echo: now")
        XCTAssertEqual(r["session_id"] as? String, real)
    }

    func testRevokeAnswersPendingApprovalWithDeny() async throws {
        let agent = uniq("agent")
        _ = await scripted(agent, realId: uniq("sid"))
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "x")
        _ = try await conn.until("承認カード") { $0.type == .actionRequest }
        await Orchestrator.shared.revoke(token: caller.token)
        do { _ = try await starting; XCTFail("親が閉じたら頼まない") } catch {}
    }

    func testChildModeNeverExceedsTheCeiling() throws {
        let claude = ["plan", "edit", "auto", "dangerous"]
        let codex = ["plan", "ask", "auto", "dangerous"]
        let oldCodex = ["plan", "auto", "dangerous"]
        let ask = Orchestrator.defaultCeiling
        func child(_ requested: String?, _ agent: String, _ modes: [String], _ cap: Int) throws -> String? {
            try Orchestrator.childMode(requested: requested, agentId: agent, supported: modes, ceiling: cap)
        }
        XCTAssertEqual(try child(nil, "claude", claude, ask), "auto", "既定の上限は「毎回尋ねる」= claude の auto")
        XCTAssertEqual(try child("edit", "claude", claude, ask), "auto", "claude の edit は auto より強い")
        XCTAssertEqual(try child("dangerous", "claude", claude, ask), "auto")
        XCTAssertEqual(try child("plan", "claude", claude, ask), "plan")
        let edit = try XCTUnwrap(Orchestrator.strength(of: "edit", agentId: "claude"))
        XCTAssertEqual(try child(nil, "claude", claude, edit), "edit")
        XCTAssertEqual(try child("auto", "claude", claude, edit), "auto")
        // codex の auto は尋ねずに書くので、claude の auto や edit を上限にしても使わせない（毎回尋ねる ask にする）。
        XCTAssertEqual(try child(nil, "codex", codex, ask), "ask", "上限が「毎回尋ねる」なら codex は ask")
        XCTAssertEqual(try child("auto", "codex", codex, edit), "ask")
        XCTAssertEqual(try child("plan", "codex", codex, ask), "plan")
        XCTAssertEqual(try child(nil, "codex", oldCodex, ask), "plan", "ask を持たない codex（古い申告）は plan")
        XCTAssertEqual(try child(nil, "codex", codex, 4), "dangerous", "チャットで dangerous を選べば使える")
        XCTAssertEqual(try child(nil, "codex", codex, 3), "auto")
        XCTAssertThrowsError(try child(nil, "opencode", ["build"], ask), "上限以下のモードが無ければ強い既定のまま起こさない")
        XCTAssertNil(try child(nil, "x", [], ask), "モードを持たない agent は絞れない")
    }

    func testStrengthFollowsEachAgentsMeaning() {
        XCTAssertLessThan(Orchestrator.strength(of: "auto", agentId: "claude")!, Orchestrator.strength(of: "edit", agentId: "claude")!)
        XCTAssertGreaterThan(Orchestrator.strength(of: "auto", agentId: "codex")!, Orchestrator.strength(of: "edit", agentId: "claude")!)
        XCTAssertEqual(Orchestrator.codexStrength(sandbox: "workspace-write", approval: "on-request"), 1)
        XCTAssertEqual(Orchestrator.codexStrength(sandbox: "workspace-write", approval: "never"), 3)
        XCTAssertEqual(Orchestrator.codexStrength(sandbox: "read-only", approval: "never"), 0)
        XCTAssertNil(Orchestrator.strength(of: "yolo", agentId: "claude"))
    }

    func testSendMessageRefusesSessionStrongerThanCeiling() async throws {
        // 相手のチャットで dangerous を選んでいると、mainagent（上限: 毎回尋ねる）からは送れない。下げれば送れる。
        let agent = uniq("agent")
        let adapter = ScriptedAdapter(id: agent) { sid in
            let s = ScriptedSession(agentId: agent, sessionId: sid ?? "x")
            s.onSend = { s, text, n in
                s.emit(.assistantDelta("echo: \(text)", agentId: agent, sessionId: s.sessionId, messageId: "m\(n)"))
                s.emit(.done(agentId: agent, sessionId: s.sessionId, messageId: "m\(n)"))
            }
            return s
        }
        await AgentRegistry.shared.register(adapter)
        let target = uniq("target")
        let other = await TestConnection.open(adapter, sessionId: target)
        defer { Task { await other.close() } }
        let (caller, conn) = await mainagent()

        await Orchestrator.shared.noteChatMode(agentId: agent, sessionId: target, mode: "dangerous")
        do {
            _ = try await Orchestrator.shared.sendMessage(caller: caller, agentId: agent, sessionId: target, text: "hi")
            XCTFail("上限より強いセッションには送らない")
        } catch {
            XCTAssertTrue("\(error)".contains("全権"), "\(error)")
        }
        XCTAssertTrue(conn.events.filter { $0.type == .actionRequest }.isEmpty, "断るときは承認も尋ねない")

        await Orchestrator.shared.noteChatMode(agentId: agent, sessionId: target, mode: "plan")
        async let sending = Orchestrator.shared.sendMessage(caller: caller, agentId: agent, sessionId: target, text: "hi", waitSeconds: 5)
        let card = try await answer(conn, caller, "allow")
        XCTAssertTrue((card.metadata?["subtitle"] ?? "").hasPrefix("モード: 計画"), card.metadata?["subtitle"] ?? "")
        let r = try await sending
        XCTAssertEqual(r["reply"] as? String, "echo: hi")
    }

    func testChatModeOfMainagentBecomesTheCeiling() async throws {
        // mainagent のチャットで plan を選ぶと、子は plan より強くならない（承認カードにモードが出る）。
        let agent = uniq("agent")
        let adapter = await scripted(agent, realId: uniq("sid"))
        adapter.modesForTesting = ["plan", "edit", "auto"]
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        await Orchestrator.shared.noteChatMode(agentId: caller.agentId, sessionId: caller.parentSessionId ?? "", mode: "plan")
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path,
                                                              prompt: "look", mode: "auto")
        let card = try await answer(conn, caller, "allow")
        XCTAssertTrue((card.metadata?["subtitle"] ?? "").hasPrefix("モード: plan"), card.metadata?["subtitle"] ?? "")
        let r = try await starting
        XCTAssertEqual(r["mode"] as? String, "plan")
    }

    func testTracksSurviveBridgeRestart() async throws {
        // 頼んだ相手と最後の返事は保存され、作り直した Orchestrator（= Bridge の再起動）でも読める。
        // 作業中だったターンは、再起動で止まったものとして error になる。
        let store = try tmpDir().appendingPathComponent("tracks.json")
        let before = Orchestrator()
        await before.enablePersistence(at: store)

        let agent = uniq("agent")
        let done = uniq("sid")
        let busy = uniq("sid")
        let gate = Gate()
        _ = await scripted(agent, realId: done)
        let busyAgent = uniq("agent")
        _ = await scripted(busyAgent, realId: busy, gate: gate)
        let dir = try tmpDir()

        let (shared, conn) = await mainagent()
        let token = await before.issueToken(agentId: shared.agentId, parentSessionId: shared.parentSessionId)
        let caller = Orchestrator.Caller(token: token, agentId: shared.agentId, parentSessionId: shared.parentSessionId)
        func allowNext(_ seen: Int) async throws {
            _ = try await conn.until("承認カード") { _ in conn.events.filter { $0.type == .actionRequest }.count > seen }
            let id = conn.events.filter { $0.type == .actionRequest }[seen].messageId ?? ""
            _ = await before.resolveApproval(requestId: id, decision: "allow")
        }
        async let first = before.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "hello", waitSeconds: 5)
        try await allowNext(0)
        let firstResult = try await first
        XCTAssertEqual(firstResult["reply"] as? String, "echo: hello")
        async let second = before.startSession(caller: caller, agentId: busyAgent, cwd: dir.path, prompt: "long")
        try await allowNext(1)
        _ = try await second
        await before.saveNow()
        gate.open()

        let after = Orchestrator()
        await after.enablePersistence(at: store)
        let r = await after.getReply(caller: caller, agentId: agent, sessionId: done, waitSeconds: 0)
        XCTAssertEqual(r["status"] as? String, "done")
        XCTAssertEqual(r["reply"] as? String, "echo: hello")
        XCTAssertEqual(r["cwd"] as? String, ProjectRegistry.normalize(dir.path))
        let stopped = await after.getReply(caller: caller, agentId: busyAgent, sessionId: busy, waitSeconds: 0)
        XCTAssertEqual(stopped["status"] as? String, "error")
        XCTAssertTrue((stopped["error"] as? String ?? "").contains("再起動"), "\(stopped)")
        // 子のカードも読み直した分から作り直せる（mainagent のチャットを開き直したときに出す）。
        let cardJSON = await after.sessionsCardJSON(parentAgentId: caller.agentId, parentSessionId: caller.parentSessionId ?? "")
        XCTAssertTrue((cardJSON ?? "").contains(done) && (cardJSON ?? "").contains(busy), cardJSON ?? "nil")
        XCTAssertTrue((cardJSON ?? "").contains("\"status\":\"error\""), "止まったターンは error の行")
        let attrs = try FileManager.default.attributesOfItem(atPath: store.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "本人だけが読める")
    }

    func testListSessionsSkipsCallerItself() async throws {
        let agent = uniq("agent")
        let adapter = ScriptedAdapter(id: agent) { sid in ScriptedSession(agentId: agent, sessionId: sid ?? "x") }
        await AgentRegistry.shared.register(adapter)
        let mine = uniq("main")
        let other = uniq("other")
        let a = await TestConnection.open(adapter, sessionId: mine)
        let b = await TestConnection.open(adapter, sessionId: other)
        defer { Task { await a.close(); await b.close() } }

        let me = Orchestrator.Caller(token: "t", agentId: agent, parentSessionId: mine)
        let ids = await Orchestrator.shared.listSessions(caller: me)
            .filter { $0["agent"] as? String == agent }.compactMap { $0["session_id"] as? String }
        XCTAssertEqual(ids, [other])
        do {
            _ = try await Orchestrator.shared.sendMessage(caller: me, agentId: agent, sessionId: mine, text: "hi")
            XCTFail("自分自身には送れない")
        } catch {}
    }

    func testStartSessionRejectsMissingFolderAndUnknownAgent() async throws {
        do {
            _ = try await Orchestrator.shared.startSession(caller: caller, agentId: "claude", cwd: "/no/such/dir", prompt: "x")
            XCTFail("無いフォルダ")
        } catch {}
        let dir = try tmpDir()
        do {
            _ = try await Orchestrator.shared.startSession(caller: caller, agentId: uniq("nobody"), cwd: dir.path, prompt: "x")
            XCTFail("知らないエージェント")
        } catch {}
    }

    // MARK: - 合鍵と /mcp

    func testTokenIsValidUntilRevoked() async {
        let token = await Orchestrator.shared.issueToken(agentId: "claude", parentSessionId: nil)
        XCTAssertTrue(token.hasPrefix("bmt_"))
        await Orchestrator.shared.setParentSessionId(token: token, sessionId: "abc")
        let c = await Orchestrator.shared.caller(token: token)
        XCTAssertEqual(c?.parentSessionId, "abc")
        await Orchestrator.shared.revoke(token: token)
        let gone = await Orchestrator.shared.caller(token: token)
        XCTAssertNil(gone)
        let unknown = await Orchestrator.shared.caller(token: "bmt_nope")
        XCTAssertNil(unknown)
    }

    private func rpc(_ obj: [String: Any]) async throws -> [String: Any]? {
        let body = try JSONSerialization.data(withJSONObject: obj)
        guard let out = await McpEndpoint.respond(to: body, caller: caller) else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
    }

    func testMcpInitializeToolsAndNotifications() async throws {
        let ini = try await rpc(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                 "params": ["protocolVersion": "2025-03-26"]])
        let result = try XCTUnwrap(ini?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])

        let note = try await rpc(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(note, "通知には返さない（HTTP は 202）")

        let list = try await rpc(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names ?? []), ["list_projects", "list_agents", "list_sessions", "start_session", "send_message", "get_reply",
                                          "answer_approval", "list_pcs", "save_note"])
        // 承認なしで使える道具は、すべて実在する。
        XCTAssertEqual(Set(MainAgentWorkspace.toolNames), Set(names ?? []), "エージェントに許す道具の名前と一致する")

        let bad = try await rpc(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                 "params": ["name": "send_message", "arguments": ["agent": "claude"]]])
        let r = try XCTUnwrap(bad?["result"] as? [String: Any])
        XCTAssertEqual(r["isError"] as? Bool, true, "引数が足りなければ道具の失敗として返す")

        let unknown = try await rpc(["jsonrpc": "2.0", "id": 4, "method": "resources/list"])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    // MARK: - mainagent のフォルダと起動引数

    func testEnsureWritesFilesOnceAndRegistersProject() throws {
        let base = try tmpDir()
        let root = base.appendingPathComponent("main")
        let projects = base.appendingPathComponent("projects.json")
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        for file in MainAgentWorkspace.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file.path).path), file.path)
        }
        XCTAssertEqual(ProjectRegistry.list(at: projects).map(\.name), [MainAgentWorkspace.projectName])

        // 手で直したファイルは上書きしない。一覧から消えていたら足し直す（「メイン」は消せない）。二重には足さない。
        let claudeMd = root.appendingPathComponent("CLAUDE.md")
        try Data("custom".utf8).write(to: claudeMd)
        ProjectRegistry.remove(path: root.path, at: projects)
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        XCTAssertEqual(try String(contentsOf: claudeMd, encoding: .utf8), "custom")
        XCTAssertEqual(ProjectRegistry.list(at: projects).map(\.name), [MainAgentWorkspace.projectName])
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        XCTAssertEqual(ProjectRegistry.list(at: projects).count, 1)

        XCTAssertTrue(MainAgentWorkspace.isMainWorkspace(root.path + "/", root: root))
        XCTAssertFalse(MainAgentWorkspace.isMainWorkspace(base.path, root: root))
        XCTAssertFalse(MainAgentWorkspace.isMainWorkspace(nil, root: root))
    }

    func testClaudeArgsOnlyForMainagent() throws {
        let main = ClaudeCodeSession(agentId: "claude", profile: .claude, initialSessionId: nil, cwd: nil,
                                     executable: "claude", store: .shared, mainToken: "bmt_secret")
        let args = main.sessionArgs()
        let config = try XCTUnwrap(args.firstIndex(of: "--mcp-config").map { args[$0 + 1] })
        XCTAssertTrue(config.contains("/mcp"))
        XCTAssertTrue(config.contains("Bearer ${BUDDYOS_MCP_TOKEN}"), "合鍵は環境変数で渡す")
        XCTAssertFalse(args.joined(separator: " ").contains("bmt_secret"), "引数に合鍵を載せない（ps で見える）")
        XCTAssertEqual(args.firstIndex(of: "--permission-mode").map { args[$0 + 1] }, "default")
        XCTAssertEqual(args.filter { $0 == "--permission-mode" }.count, 1)
        XCTAssertTrue(args.firstIndex(of: "--disallowedTools").map { args[$0 + 1] }?.contains("Edit") ?? false)
        // 送る・起こす・承認に答えるの確認は Bridge が出すので、Claude 側では道具を全部尋ねさせない。
        XCTAssertEqual(args.firstIndex(of: "--allowedTools").map { args[$0 + 1] }?.split(separator: ",").count,
                       MainAgentWorkspace.toolNames.count + MainAgentWorkspace.readOnlyConnectorTools.count)
        // Gmail / ドライブは読む道具だけ。送る・消す道具は入れない。
        let allowedMain = args.firstIndex(of: "--allowedTools").map { args[$0 + 1] } ?? ""
        XCTAssertTrue(allowedMain.contains("mcp__claude_ai_Gmail__search_threads"))
        XCTAssertFalse(allowedMain.contains("Gmail__send") || allowedMain.contains("Gmail__forward") || allowedMain.contains("Gmail__reply"))
        XCTAssertFalse(allowedMain.contains("Gmail__trash") || allowedMain.contains("Drive__trash"))
        XCTAssertTrue(args.firstIndex(of: "--allowedTools").map { args[$0 + 1] }?.contains("mcp__buddyos__answer_approval") ?? false)

        // ふつうのセッション: MCP と道具の許可だけ。書く道具も権限モードもそのまま。
        let delegate = ClaudeCodeSession(agentId: "claude", profile: .claude, initialSessionId: nil, cwd: nil,
                                         executable: "claude", store: .shared, mainToken: "bmt_secret", mainRestricted: false)
        let dargs = delegate.sessionArgs()
        XCTAssertTrue(dargs.contains("--mcp-config"))
        XCTAssertFalse(dargs.contains("--disallowedTools"), "書く道具は外さない")
        XCTAssertTrue(dargs.firstIndex(of: "--allowedTools").map { dargs[$0 + 1] }?.contains("mcp__buddyos__list_pcs") ?? false)
        XCTAssertFalse(dargs.firstIndex(of: "--allowedTools").map { dargs[$0 + 1] }?.contains("Gmail") ?? true,
                       "Gmail / ドライブの読む道具は mainagent だけ")
        XCTAssertNotEqual(dargs.firstIndex(of: "--permission-mode").map { dargs[$0 + 1] }, "default", "権限モードを固定しない")
        XCTAssertFalse(dargs.joined(separator: " ").contains("bmt_secret"))
        let dexec = MainAgentWorkspace.codexExecDelegateArgs(port: 9999).joined(separator: " ")
        XCTAssertFalse(dexec.contains("sandbox_mode"), "Codex も読むだけにしない")
        XCTAssertTrue(dexec.contains("bearer_token_env_var"))

        let normal = ClaudeCodeSession(agentId: "claude", profile: .claude, initialSessionId: nil, cwd: nil,
                                       executable: "claude", store: .shared)
        let plain = normal.sessionArgs()
        XCTAssertFalse(plain.contains("--mcp-config"))
        XCTAssertFalse(plain.contains("--disallowedTools"))
    }

    func testOrchestrateCapability() {
        XCTAssertTrue(AgentRegistry.capabilities(of: ClaudeCodeAdapter()).orchestrate)
        XCTAssertTrue(AgentRegistry.capabilities(of: CodexHistoryAdapter()).orchestrate)
        XCTAssertFalse(AgentRegistry.capabilities(of: EchoAdapter()).orchestrate)
    }

    func testCodexConfigUsesDottedOverridesAndAutoApproves() {
        let c = MainAgentWorkspace.codexConfig(token: "bmt_x", port: 9999)
        XCTAssertEqual(c["mcp_servers.buddyos.url"] as? String, "http://127.0.0.1:9999/mcp")
        XCTAssertEqual((c["mcp_servers.buddyos.http_headers"] as? [String: String])?["Authorization"], "Bearer bmt_x")
        XCTAssertEqual(c["mcp_servers.buddyos.default_tools_approval_mode"] as? String, "approve", "承認は Bridge が出す")
        XCTAssertEqual(c["mcp_servers.buddyos.tool_timeout_sec"] as? Int, MainAgentWorkspace.toolTimeoutSeconds)
        let exec = MainAgentWorkspace.codexExecArgs(port: 9999).joined(separator: " ")
        XCTAssertTrue(exec.contains("sandbox_mode=\"read-only\""))
        XCTAssertTrue(exec.contains("bearer_token_env_var=\"BUDDYOS_MCP_TOKEN\""))
        XCTAssertFalse(exec.contains("Bearer"), "合鍵を引数に載せない")
    }

    func testAcpServerEntryShape() {
        let e = MainAgentWorkspace.acpServer(token: "bmt_x", port: 9999)
        XCTAssertEqual(e["type"] as? String, "http")
        XCTAssertEqual(e["name"] as? String, "buddyos")
        XCTAssertEqual((e["headers"] as? [[String: String]])?.first?["value"], "Bearer bmt_x")
    }

    // MARK: - 子の承認に答える（answer_approval）

    func testAnswerApprovalAsksUserEveryTimeUnderAskCeiling() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        let box = await approvingChild(agent, realId: real, options: [
            ("allow", "承認"), ("allowForSession", "このセッションでは承認"), ("deny", "非承認")
        ])
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "run tests")
        try await answerNth(conn, caller, 0, "allowForSession")   // 以後の依頼は尋ねない
        _ = try await starting

        let waiting = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(waiting["status"] as? String, "needs_approval")
        let approval = try XCTUnwrap(waiting["approval"] as? [String: Any])
        XCTAssertEqual(approval["request_id"] as? String, "req-1")
        XCTAssertEqual(approval["summary"] as? String, "npm test", "何を許すのかが見える")
        XCTAssertEqual(approval["choices"] as? [String], ["allow", "allow_for_session", "deny"])
        let listed = await Orchestrator.shared.listSessions(caller: caller).first { $0["agent"] as? String == agent }
        XCTAssertEqual(listed?["last_request_state"] as? String, "needs_approval")
        XCTAssertEqual((listed?["pending_approvals"] as? [[String: Any]])?.first?["request_id"] as? String, "req-1")

        // 上限が「毎回尋ねる」なので、このセッションでは許可（続けて尋ねない）は使えない。
        do {
            _ = try await Orchestrator.shared.answerApproval(caller: caller, agentId: agent, sessionId: real,
                                                             requestId: "req-1", decision: "allow_for_session")
            XCTFail("上限より強い答えは使えない")
        } catch {
            XCTAssertTrue("\(error)".contains("編集は尋ねない"), "\(error)")
        }
        XCTAssertEqual(conn.events.filter { $0.type == .actionRequest }.count, 1, "断るときは尋ねない")

        // 「このセッションでは承認」を選んでいても、上限が低いので許可は毎回ユーザーに尋ねる。
        async let answering = Orchestrator.shared.answerApproval(caller: caller, agentId: agent, sessionId: real,
                                                                 requestId: "req-1", decision: "allow")
        let card = try await answerNth(conn, caller, 1, "allow")
        XCTAssertEqual(card.metadata?["option_count"], "2", "「このセッションでは承認」は出さない")
        XCTAssertTrue((card.metadata?["subtitle"] ?? "").contains("npm test"), card.metadata?["subtitle"] ?? "")
        let answered = try await answering
        XCTAssertEqual(answered["answered"] as? String, "allow")
        XCTAssertEqual(box.session?.answers.map(\.decision), ["allow"], "子の選択肢の値で答える")

        let done = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(done["status"] as? String, "done")
        XCTAssertEqual(done["reply"] as? String, "answered: allow")
        do {
            _ = try await Orchestrator.shared.answerApproval(caller: caller, agentId: agent, sessionId: real,
                                                             requestId: "req-1", decision: "deny")
            XCTFail("もう待っていない承認には答えない")
        } catch {}
    }

    func testAnswerApprovalDenyNeedsNoCardAndPlanCeilingCannotAllow() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        // Codex と同じ値の選択肢（accept / acceptForSession / decline）。
        let box = await approvingChild(agent, realId: real, options: [
            ("accept", "承認"), ("acceptForSession", "このセッションでは承認"), ("decline", "非承認")
        ])
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        await Orchestrator.shared.noteChatMode(agentId: caller.agentId, sessionId: caller.parentSessionId ?? "", mode: "plan")
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "look")
        try await answerNth(conn, caller, 0, "allow")
        _ = try await starting
        let waiting = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(waiting["status"] as? String, "needs_approval")

        do {
            _ = try await Orchestrator.shared.answerApproval(caller: caller, agentId: agent, sessionId: real,
                                                             requestId: "req-1", decision: "allow")
            XCTFail("上限が計画なら許可できない")
        } catch {
            XCTAssertTrue("\(error)".contains("計画"), "\(error)")
        }
        let r = try await Orchestrator.shared.answerApproval(caller: caller, agentId: agent, sessionId: real,
                                                             requestId: "req-1", decision: "deny")
        XCTAssertEqual(r["answered"] as? String, "deny")
        XCTAssertEqual(conn.events.filter { $0.type == .actionRequest }.count, 1, "断るのはユーザーに尋ねない")
        XCTAssertEqual(box.session?.answers.map(\.decision), ["decline"], "Codex の値で答える")
        do {
            _ = try await Orchestrator.shared.answerApproval(caller: caller, agentId: agent, sessionId: real,
                                                             requestId: "req-1", decision: "maybe")
            XCTFail("知らない答え")
        } catch {}
    }

    func testAnswerFromThePhoneClearsThePendingApproval() async throws {
        // 子のチャットを開いた iPhone が答えたら、答えたことを知らせない adapter でも mainagent 側の承認待ちを外す。
        let agent = uniq("agent")
        let real = uniq("sid")
        let box = await approvingChild(agent, realId: real, options: [("allow", "承認"), ("deny", "非承認")])
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "x")
        try await answerNth(conn, caller, 0, "allow")
        _ = try await starting
        let waiting = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 5)
        XCTAssertEqual(waiting["status"] as? String, "needs_approval")
        box.session?.onAnswer = nil   // 答えても何も出さない（actionResolved も done も無い）
        let found = await AgentRegistry.shared.adapter(for: agent)
        let adapter = try XCTUnwrap(found)
        let phone = await TestConnection.open(adapter, sessionId: real)
        defer { Task { await phone.close() } }
        await phone.send(["type": "action_response", "agentId": agent, "sessionId": real, "messageId": "req-1",
                          "content": "allow", "metadata": ["requestId": "req-1", "decision": "allow"]])
        var status: String?
        for _ in 0..<50 {
            status = await Orchestrator.shared.getReply(caller: caller, agentId: agent, sessionId: real, waitSeconds: 0)["status"] as? String
            if status == "running" { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(status, "running")
        XCTAssertEqual(box.session?.answers.map(\.decision), ["allow"])
    }

    func testApprovalChoiceMapsEachAgentsOptions() {
        func c(_ v: String, _ t: String = "") -> Orchestrator.ApprovalChoice? { Orchestrator.approvalChoice(value: v, title: t) }
        // claude / headless
        XCTAssertEqual(c("allow"), .allow)
        XCTAssertEqual(c("allowForSession"), .allowForSession)
        XCTAssertEqual(c("deny"), .deny)
        // codex
        XCTAssertEqual(c("accept"), .allow)
        XCTAssertEqual(c("acceptForSession"), .allowForSession)
        XCTAssertEqual(c("decline"), .deny)
        // opencode
        XCTAssertEqual(c("once"), .allow)
        XCTAssertEqual(c("always"), .allowForSession)
        XCTAssertEqual(c("reject"), .deny)
        // ACP の optionId（名前は agent ごと）と、id で分からないときの表示名
        XCTAssertEqual(c("allow_once"), .allow)
        XCTAssertEqual(c("allow_always"), .allowForSession)
        XCTAssertEqual(c("reject_once"), .deny)
        XCTAssertEqual(c("reject_always"), .deny, "always でも断る側は deny")
        XCTAssertEqual(c("proceed_always"), .allowForSession)
        XCTAssertEqual(c("opt-1", "Allow"), .allow)
        XCTAssertEqual(c("opt-3", "Reject"), .deny)
        XCTAssertNil(c("opt-9", "Something else"), "分からない選択肢は選ばせない")
    }

    func testQuestionsAndHeldMessagesAreNotAnswerable() {
        func card(_ meta: [String: String], id: String = "r") -> Orchestrator.Approval {
            Orchestrator.approval(from: .actionRequest(agentId: "a", sessionId: "s", messageId: id, title: "t",
                                                       subtitle: nil, metadata: meta))
        }
        let opts = ["option_count": "2", "option_0_value": "allow", "option_1_value": "deny"]
        XCTAssertTrue(card(opts.merging(["kind": "approval"]) { a, _ in a }).answerable)
        XCTAssertTrue(card(opts.merging(["kind": "plan"]) { a, _ in a }).answerable, "計画の承認は答えられる（上限で絞る）")
        XCTAssertFalse(card(opts.merging(["kind": "userInput"]) { a, _ in a }).answerable, "質問は答えない")
        XCTAssertFalse(card(opts.merging(["kind": "approval", "answerable": "0"]) { a, _ in a }).answerable)
        XCTAssertFalse(card(opts.merging(["kind": "approval"]) { a, _ in a }, id: "held-1234").answerable,
                       "ターミナルへの発話の保留は通さない")
        XCTAssertFalse(card(["kind": "approval"]).answerable, "選択肢が無いものは答えない")
    }

    // MARK: - 子のカード（workflow_progress kind = "sessions"）

    func testSessionsCardFollowsTheChildAndIsReplayedOnReopen() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        let gate = Gate()
        _ = await scripted(agent, realId: real, gate: gate)
        let dir = try tmpDir()
        let (caller, conn, mainAdapter) = await mainagentWithAdapter()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path,
                                                              prompt: "check git status\nand report")
        try await answerNth(conn, caller, 0, "allow")
        _ = try await starting

        // 最初の行は仮の ID のことがある（確定したら同じ index の行の sessionId が変わる）。
        let running = try await conn.until("running の行") {
            let r = self.sessionsRow($0, agent: agent)
            return r?["status"] as? String == "running" && r?["sessionId"] as? String == real
        }
        let row = try XCTUnwrap(sessionsRow(running, agent: agent))
        XCTAssertEqual(row["sessionId"] as? String, real)
        XCTAssertEqual(row["cwd"] as? String, ProjectRegistry.normalize(dir.path))
        XCTAssertEqual(row["title"] as? String, "check git status and report")
        XCTAssertEqual(row["state"] as? String, "running", "古いアプリ向けの state")
        XCTAssertEqual(row["index"] as? Int, 0)
        XCTAssertNotNil(row["startedAtMs"] as? Int)
        XCTAssertNotNil(row["updatedAtMs"] as? Int)
        XCTAssertNil(row["finishedAtMs"])
        let card = try XCTUnwrap(sessionsCards(conn).last)
        XCTAssertEqual(card["taskId"] as? String, Orchestrator.sessionsTaskId)
        XCTAssertEqual(card["subtype"] as? String, "task_progress")
        XCTAssertEqual(card["status"] as? String, "running")

        gate.open()
        let doneEvent = try await conn.until("done の行") { self.sessionsRow($0, agent: agent)?["status"] as? String == "done" }
        let done = try XCTUnwrap(sessionsRow(doneEvent, agent: agent))
        XCTAssertEqual(done["summary"] as? String, "echo: check git status and report")
        XCTAssertEqual(done["state"] as? String, "done")
        XCTAssertNotNil(done["finishedAtMs"] as? Int)
        XCTAssertEqual(sessionsCards(conn).last?["status"] as? String, "completed")
        // 状態が変わったときだけ出す（同じ状態を何度も送らない）。
        XCTAssertLessThanOrEqual(sessionsCards(conn).count, 4, "\(sessionsCards(conn).count) 回")

        // 開き直した iPhone（別の購読者）にも、ターンが終わっていても最新のカードが届く。
        let again = await TestConnection.open(mainAdapter, sessionId: caller.parentSessionId)
        _ = try await again.until("開き直しでカード") { self.sessionsRow($0, agent: agent)?["status"] as? String == "done" }
        // 誰も見なくなって entry が閉じた後に開き直しても届く（Bridge が覚えている）。
        await conn.close()
        await again.close()
        let third = await TestConnection.open(mainAdapter, sessionId: caller.parentSessionId)
        defer { Task { await third.close() } }
        _ = try await third.until("閉じた後の開き直しでカード") { self.sessionsRow($0, agent: agent)?["status"] as? String == "done" }
        let stored = await SessionHub.shared.sessionsCard(agentId: caller.agentId, sessionId: caller.parentSessionId ?? "")
        XCTAssertNotNil(stored)
    }

    func testSessionsCardShowsPendingApproval() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        _ = await approvingChild(agent, realId: real, options: [("allow", "承認"), ("deny", "非承認")])
        let dir = try tmpDir()
        let (caller, conn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "test")
        try await answerNth(conn, caller, 0, "allow")
        _ = try await starting
        let e = try await conn.until("承認待ちの行") { self.sessionsRow($0, agent: agent)?["status"] as? String == "needs_approval" }
        let row = try XCTUnwrap(sessionsRow(e, agent: agent))
        let approval = try XCTUnwrap(row["approval"] as? [String: Any])
        XCTAssertEqual(approval["requestId"] as? String, "req-1")
        XCTAssertEqual(approval["answerable"] as? Bool, true)
        XCTAssertEqual(row["summary"] as? String, "承認待ち: 「Bash」を実行しますか？")
        XCTAssertEqual(row["state"] as? String, "running")
        _ = try await Orchestrator.shared.answerApproval(caller: caller, agentId: agent, sessionId: real, requestId: "req-1", decision: "deny")
        _ = try await conn.until("答えた後は done") { self.sessionsRow($0, agent: agent)?["status"] as? String == "done" }
    }

    // MARK: - mainagent のフォルダの決まりの書き直し

    func testEnsureRefreshesManagedBlockAndKeepsUserText() throws {
        let base = try tmpDir()
        let root = base.appendingPathComponent("main")
        let projects = base.appendingPathComponent("projects.json")
        let claudeMd = root.appendingPathComponent("CLAUDE.md")
        let dispatch = root.appendingPathComponent(".claude/skills/dispatch/SKILL.md")
        try FileManager.default.createDirectory(at: dispatch.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 前の版の Bridge が書いたまま（範囲の印なし・手を入れていない）なら、今の版に置き換わる。
        try Data(MainAgentWorkspace.legacyRoleTextV1.utf8).write(to: claudeMd)
        try Data(MainAgentWorkspace.legacyDispatchSkillV1.utf8).write(to: dispatch)
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        var text = try String(contentsOf: claudeMd, encoding: .utf8)
        XCTAssertTrue(text.contains(MainAgentWorkspace.managedBegin))
        XCTAssertTrue(text.contains("answer_approval"))
        let skill = try String(contentsOf: dispatch, encoding: .utf8)
        XCTAssertTrue(skill.hasPrefix("---\nname: dispatch\n"), "frontmatter はファイルの先頭のまま")
        XCTAssertTrue(skill.contains("answer_approval"))

        // ユーザーが範囲の外に足した文は残り、範囲の中（古い決まり）だけ書き直す。
        text = "# 自分のメモ\n- 朝は短く\n\n"
            + text.replacingOccurrences(of: "answer_approval", with: "OLD_TOOL")
            + "\n## 追加の決まり\n- 返事は 3 行まで\n"
        try Data(text.utf8).write(to: claudeMd)
        try Data((skill + "\n追記: 急ぎは codex に回す\n").utf8).write(to: dispatch)
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        let refreshed = try String(contentsOf: claudeMd, encoding: .utf8)
        XCTAssertTrue(refreshed.hasPrefix("# 自分のメモ\n- 朝は短く\n"), refreshed)
        XCTAssertTrue(refreshed.contains("## 追加の決まり\n- 返事は 3 行まで"))
        XCTAssertTrue(refreshed.contains("answer_approval"))
        XCTAssertFalse(refreshed.contains("OLD_TOOL"))
        XCTAssertEqual(refreshed.components(separatedBy: MainAgentWorkspace.managedEnd).count, 2, "範囲は 1 つのまま")
        let refreshedSkill = try String(contentsOf: dispatch, encoding: .utf8)
        XCTAssertTrue(refreshedSkill.hasSuffix("追記: 急ぎは codex に回す\n"))
        XCTAssertTrue(refreshedSkill.hasPrefix("---\nname: dispatch\n"))

        // もう一度呼んでも変わらない。
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        XCTAssertEqual(try String(contentsOf: claudeMd, encoding: .utf8), refreshed)
    }

    // MARK: - codex の「毎回尋ねる」

    func testCodexAskModeIsWorkspaceWriteOnRequest() throws {
        let c = CodexConfigStore()
        let values = try c.codexModeValues("ask")
        XCTAssertEqual(values.sandbox, "workspace-write")
        XCTAssertEqual(values.approval, "on-request")
        XCTAssertEqual(c.currentCodexMode(approvalPolicy: "on-request", sandboxMode: "workspace-write"), "ask")
        XCTAssertEqual(c.currentCodexMode(approvalPolicy: "never", sandboxMode: "workspace-write"), "auto")
        XCTAssertEqual(AgentRegistry.capabilities(of: CodexHistoryAdapter()).modes, ["plan", "ask", "auto", "dangerous"])
        XCTAssertEqual(Orchestrator.strength(of: "ask", agentId: "codex"), Orchestrator.defaultCeiling)
        XCTAssertEqual(Orchestrator.codexStrength(sandbox: values.sandbox, approval: values.approval),
                       Orchestrator.strength(of: "ask", agentId: "codex"), "名前と実際の設定の強さがそろう")
    }
}

/// 台本の adapter が作ったセッションを、テストから触るための入れ物。
final class ScriptedBox: @unchecked Sendable {
    var session: ScriptedSession?
    /// バックグラウンドの作業を終える行の payload（backgroundChild）。
    var finishPayload: String?
}
