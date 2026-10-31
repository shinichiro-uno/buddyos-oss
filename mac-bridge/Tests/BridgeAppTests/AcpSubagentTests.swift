import XCTest
import GRDB
@testable import BridgeApp

/// AcpSession の委任（サブエージェント）の行。Hermes / OpenClaw の title は「<tool>: <preview>」、opencode acp は
/// pending の tool_call では title も rawInput も空で、説明は後の更新（in_progress）で届く。ACP を話すフェイクの
/// エージェント（python3）を executable に差して、session/update から行までを確かめる。
final class AcpSubagentTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-subagent-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// session/prompt を受けたら updates（session/update の update の JSON の配列）を順に流す。
    /// waitCancel なら session/cancel が来るまで応答を返さず、来たら stopReason: cancelled で返す。
    private func writeFakeAgent(updates: [[String: Any]], waitCancel: Bool = false) throws -> String {
        let url = tempDir.appendingPathComponent("fake-acp.py")
        let data = try JSONSerialization.data(withJSONObject: updates)
        let updatesPath = tempDir.appendingPathComponent("updates.json")
        try data.write(to: updatesPath)
        let script = """
        #!/usr/bin/env python3
        import json, sys, time
        updates = json.load(open('\(updatesPath.path)'))
        def send(m):
            sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
        pending = None
        for line in sys.stdin:
            m = json.loads(line)
            method = m.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "acp-sub-1"}})
            elif method == "session/prompt":
                pending = m["id"]
                for u in updates:
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "acp-sub-1", "update": u}})
                if not \(waitCancel ? "True" : "False"):
                    time.sleep(0.3)
                    send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "end_turn"}})
            elif method == "session/cancel":
                time.sleep(0.2)
                send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "cancelled"}})
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeSession(_ exe: String) -> AcpSession {
        var tuning = AcpSessionTuning()
        tuning.postSessionDelayNanos = 0
        tuning.loginShell = false
        return AcpSession(agentId: "hermes", initialSessionId: nil, executable: exe, args: [],
                          cwd: tempDir.path, tuning: tuning)
    }

    /// done まで読む。onRunningRow は、実行中の行が初めて流れたときに 1 回だけ呼ぶ（中断の試験用）。
    private func run(_ session: AcpSession, onRunningRow: (@Sendable () async -> Void)? = nil) async -> [SessionEvent] {
        let task = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            var called = false
            for try await e in session.events {
                out.append(e)
                if !called, let onRunningRow, e.type == .workflowProgress, e.content?.contains("\"running\"") == true {
                    called = true
                    await onRunningRow()
                }
                if e.type == .done || e.type == .error { break }
            }
            return out
        }
        await session.send("go", skills: [], attachments: [])
        let events = (try? await task.value) ?? []
        return events
    }

    private func rows(_ events: [SessionEvent], id: String) -> [[String: Any]] {
        events.filter { $0.type == .workflowProgress }.flatMap { e -> [[String: Any]] in
            guard let data = e.content?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (obj["agents"] as? [[String: Any]]) ?? []
        }.filter { $0["id"] as? String == id }
    }

    /// Hermes の delegate_task（title「delegate_task: …」、rawInput 無し）を委任として行にし、ツール名から「:」を外す。
    func testHermesDelegateTaskTitleIsRecognized() async throws {
        let exe = try writeFakeAgent(updates: [
            ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "delegate_task: 3 tasks: a | b | c",
             "kind": "execute", "status": "in_progress"],
            ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed",
             "content": [["type": "content", "content": ["type": "text", "text": "Started 3 tasks"]]]],
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "ok"]],
        ])
        let session = makeSession(exe)
        let events = await run(session)
        await session.close()

        XCTAssertEqual(events.first { $0.type == .toolStart }?.toolName, "delegate_task")
        let all = rows(events, id: "t1")
        XCTAssertEqual(all.first?["label"] as? String, "3 tasks: a | b | c", "title から「<tool>: 」を外す: \(all)")
        XCTAssertEqual(all.first?["state"] as? String, "running")
        XCTAssertEqual(all.last?["state"] as? String, "done")
        XCTAssertEqual(all.last?["result"] as? String, "Started 3 tasks")
    }

    /// opencode acp: pending の tool_call は title「task」・rawInput 空。in_progress の更新で説明と種類を埋め、
    /// 完了の `<task …><task_result>` は中身を結果にする。
    func testOpencodeTaskFillsLabelFromUpdateAndParsesOutput() async throws {
        let exe = try writeFakeAgent(updates: [
            ["sessionUpdate": "tool_call", "toolCallId": "t2", "title": "task", "kind": "think", "status": "pending",
             "rawInput": [String: Any]()],
            ["sessionUpdate": "tool_call_update", "toolCallId": "t2", "status": "in_progress", "title": "List scratch dir",
             "rawInput": ["description": "List scratch dir", "subagent_type": "general", "prompt": "ls"]],
            ["sessionUpdate": "tool_call_update", "toolCallId": "t2", "status": "completed",
             "content": [["type": "content", "content": ["type": "text",
                "text": "<task id=\"ses_c\" state=\"completed\">\n<task_result>\n2\n</task_result>\n</task>"]]]],
        ])
        let session = makeSession(exe)
        let events = await run(session)
        await session.close()

        let all = rows(events, id: "t2")
        guard let last = all.last else { return XCTFail("行が流れていない") }
        XCTAssertEqual(last["label"] as? String, "List scratch dir")
        XCTAssertEqual(last["agentType"] as? String, "general")
        XCTAssertEqual(last["state"] as? String, "done")
        XCTAssertEqual(last["result"] as? String, "2", "囲みのタグを出さない")
    }

    /// 停止（session/cancel）で、実行中の委任の行を stopped で閉じる。
    func testCancelStopsRunningDelegation() async throws {
        let exe = try writeFakeAgent(updates: [
            ["sessionUpdate": "tool_call", "toolCallId": "t3", "title": "sessions_spawn: task: build, agentId: coder",
             "kind": "execute", "status": "in_progress", "rawInput": ["task": "build", "agentId": "coder"]],
        ], waitCancel: true)
        let session = makeSession(exe)
        let events = await run(session, onRunningRow: { await session.interrupt() })
        await session.close()

        let all = rows(events, id: "t3")
        XCTAssertEqual(all.first?["label"] as? String, "build")
        XCTAssertEqual(all.first?["agentType"] as? String, "coder")
        XCTAssertEqual(all.last?["state"] as? String, "stopped", "\(all)")
        XCTAssertTrue(events.contains { $0.type == .done })
    }

    func testExtractToolNameUsesLeadingIdentifier() {
        XCTAssertEqual(AcpSession.extractToolName(title: "delegate_task: 3 tasks: a | b | c", fallback: "x"), "delegate_task")
        XCTAssertEqual(AcpSession.extractToolName(title: "sessions_spawn: task: ビルド, agentId: coder", fallback: "x"),
                       "sessions_spawn")
        XCTAssertEqual(AcpSession.extractToolName(title: "terminal: `ls -la`", fallback: "x"), "terminal",
                       "preview のバッククォートの中をツール名にしない")
        XCTAssertEqual(AcpSession.extractToolName(title: "`ls -la`", fallback: "x"), "ls")
        XCTAssertEqual(AcpSession.extractToolName(title: "Read /tmp/a.txt", fallback: "x"), "Read")
        XCTAssertEqual(AcpSession.extractToolName(title: "", fallback: "think"), "think")
    }
}

/// 実測（shared/fixtures/background-control/acp-delegation）を流して確かめる、ACP の非同期の委任の本当の終わり
/// （docs/BACKGROUND_CONTROL_2026-10-21.md §5）。偽のエージェント（python3）は、記録の `recv` をそのまま順に流し、
/// session/prompt の応答だけ実際の id で返す（応答のあと少し待って、残りを流す。記録に応答が無ければ最後に end_turn で返す）。台帳は一時 SQLite。
final class AcpAsyncDelegationTests: XCTestCase {
    private static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/fixtures/background-control/acp-delegation")
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-async-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: 部品

    private func fixtureLines(_ name: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: Self.fixtureDir.appendingPathComponent("\(name).raw.jsonl"), encoding: .utf8)
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private func writeFakeAgent() throws -> String {
        let url = tempDir.appendingPathComponent("fake-acp.py")
        let script = """
        #!/usr/bin/env python3
        import json, sys, time
        fix = [json.loads(l) for l in open(sys.argv[1])]
        hold = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
        after = float(sys.argv[3]) if len(sys.argv) > 3 else 0.4
        def send(m):
            sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
        prompts = [i for i, o in enumerate(fix) if o["dir"] == "send" and o["msg"].get("method") == "session/prompt"]
        sid = fix[prompts[0]]["msg"]["params"]["sessionId"]
        def recvs(a, b):
            return [o["msg"] for o in fix[a:b] if o["dir"] == "recv"]
        pre = recvs(0, prompts[0])
        bounds = prompts + [len(fix)]
        n = 0
        for line in sys.stdin:
            m = json.loads(line)
            method = m.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": sid}})
                for x in pre:
                    send(x)
            elif method == "session/prompt":
                rid = m["id"]
                msgs = recvs(bounds[n] + 1, bounds[n + 1])
                n += 1
                answered = False
                for x in msgs:
                    if "method" not in x and "result" in x:
                        answered = True
                        # 通知は応答より先に処理し終えてから応答する（実機と同じ）。
                        time.sleep(hold + 0.2)
                        x = dict(x)
                        x["id"] = rid
                        send(x)
                        time.sleep(after)
                    else:
                        send(x)
                if not answered:
                    time.sleep(hold + 0.2)
                    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private enum Flavor { case grok, hermes, openclaw }

    private func makeSession(_ flavor: Flavor, fixture: String, ledger: String? = nil, hold: Double = 0,
                             tune: (inout AcpSessionTuning) -> Void = { _ in }) throws -> AcpSession {
        var tuning = AcpSessionTuning()
        tuning.postSessionDelayNanos = 0
        tuning.loginShell = false
        switch flavor {
        case .grok:
            tuning.xaiNotifications = true
            tuning.statuslessUpdateEndsTool = false
        case .hermes:
            tuning.delegationLedger = .hermes
        case .openclaw:
            tuning.delegationLedger = .openclaw
        }
        tuning.delegationLedgerPath = ledger
        tuning.delegationPollSeconds = 0.05
        tune(&tuning)
        let fixturePath = Self.fixtureDir.appendingPathComponent("\(fixture).raw.jsonl").path
        return AcpSession(agentId: "\(flavor)", initialSessionId: nil, executable: try writeFakeAgent(),
                          args: [fixturePath, String(hold)], cwd: tempDir.path, tuning: tuning)
    }

    /// session.events を読み続けて控える。
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SessionEvent] = []
        private var task: Task<Void, Never>?

        init(_ session: AcpSession) {
            task = Task { [weak self] in
                do { for try await e in session.events { self?.append(e) } } catch {}
            }
        }

        private func append(_ e: SessionEvent) { lock.lock(); items.append(e); lock.unlock() }
        var events: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return items }

        @discardableResult
        func until(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                   _ match: ([SessionEvent]) -> Bool) async throws -> [SessionEvent] {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let now = events
                if match(now) { return now }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("待ちきれなかった: \(what) / 届いた種別 \(events.map(\.type.rawValue))", file: file, line: line)
            return events
        }
    }

    private func rows(_ events: [SessionEvent], id: String) -> [[String: Any]] {
        events.filter { $0.type == .workflowProgress }.flatMap { e -> [[String: Any]] in
            guard let data = e.content?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (obj["agents"] as? [[String: Any]]) ?? []
        }.filter { $0["id"] as? String == id }
    }

    private func isTaskNotification(_ e: SessionEvent) -> Bool {
        e.type == .done && e.metadata?["origin"] == "task-notification"
    }

    private func isSilent(_ e: SessionEvent) -> Bool {
        isTaskNotification(e) && e.metadata?["silent"] == "1"
    }

    /// 記録の中の、親の session/update の agent_message_chunk の本文（promptId の接頭辞で絞れる）。
    private func parentChunks(_ fixture: String, promptPrefix: String? = nil) throws -> String {
        let lines = try fixtureLines(fixture)
        let sid = lines.compactMap { ($0["msg"] as? [String: Any])?["params"] as? [String: Any] }
            .first { ($0["prompt"] as? [Any]) != nil }?["sessionId"] as? String
        return lines.compactMap { $0["msg"] as? [String: Any] }
            .filter { $0["method"] as? String == "session/update" }
            .compactMap { $0["params"] as? [String: Any] }
            .filter { $0["sessionId"] as? String == sid }
            .filter { ($0["update"] as? [String: Any])?["sessionUpdate"] as? String == "agent_message_chunk" }
            .filter { p in
                guard let prefix = promptPrefix else { return true }
                return ((p["_meta"] as? [String: Any])?["promptId"] as? String)?.hasPrefix(prefix) == true
            }
            .compactMap { (($0["update"] as? [String: Any])?["content"] as? [String: Any])?["text"] as? String }
            .joined()
    }

    // MARK: Grok

    private let grokSpawnRow = "call-7ebffa87-781c-4172-bb7c-264e7e212d9e-0"

    /// run1: 背景の spawn は status の無い更新と受領票では閉じない。progress で作業と数が入り、finished で done と output。
    /// 親が起こされたターンは知らせのターン（空の activity → 新しい吹き出し → turn_completed で done origin）。
    func testGrokBackgroundSpawnRunsUntilFinishedAndWakeTurnIsNotification() async throws {
        let session = try makeSession(.grok, fixture: "grok-run1")
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        let events = try await log.until("知らせのターンの done") { $0.contains(where: self.isTaskNotification) }
        await session.close()

        let all = rows(events, id: grokSpawnRow)
        XCTAssertEqual(all.first?["state"] as? String, "running")
        XCTAssertEqual(all.first?["background"] as? Bool, true)
        XCTAssertEqual(all.last?["state"] as? String, "done", "\(all)")
        XCTAssertTrue(all.dropLast().allSatisfy { $0["state"] as? String == "running" }, "status の無い更新・受領票で閉じた: \(all)")
        XCTAssertEqual(all.last?["result"] as? String, "OK")
        XCTAssertEqual(all.last?["durationMs"] as? Int, 25287)
        XCTAssertEqual(all.last?["agentType"] as? String, "general-purpose")
        XCTAssertEqual(all.last?["model"] as? String, "grok-4.7")
        XCTAssertEqual(all.last?["tokens"] as? Int, 10889)
        XCTAssertEqual(all.last?["toolCalls"] as? Int, 1)
        XCTAssertTrue(all.contains { $0["tokens"] as? Int == 1516 }, "subagent_progress の数が入らない: \(all)")

        // tool の行は受領票で閉じる（二重に閉じない）。
        XCTAssertEqual(events.filter { $0.type == .toolEnd && $0.toolUseId == grokSpawnRow }.count, 1)
        XCTAssertTrue(events.filter { $0.type == .userMessage }.isEmpty)

        let dones = events.filter { $0.type == .done }
        XCTAssertEqual(dones.count, 2, "prompt の done と知らせのターンの done: \(dones.map { $0.metadata ?? [:] })")
        let wakeDone = try XCTUnwrap(dones.last)
        XCTAssertTrue(isTaskNotification(wakeDone))
        XCTAssertNil(wakeDone.metadata?["silent"], "本文のある知らせのターンは silent にしない")
        XCTAssertFalse(events.contains(where: isSilent), "will_wake のときは行が閉じても silent の done を出さない")

        // 知らせのターン: prompt の done のあとに、空の activity → 本文（新しい messageId）→ 吹き出しの終わり → done。
        let promptDoneIndex = try XCTUnwrap(events.firstIndex { $0.type == .done })
        let openIndex = try XCTUnwrap(events.firstIndex { $0.type == .activity && ($0.content ?? "").isEmpty })
        XCTAssertGreaterThan(openIndex, promptDoneIndex)
        let wakeDeltas = events[openIndex...].filter { $0.type == .assistantDelta }
        XCTAssertEqual(wakeDeltas.compactMap(\.content).joined(), try parentChunks("grok-run1", promptPrefix: "subagent-completed-"))
        let bubbleId = try XCTUnwrap(wakeDeltas.first?.messageId)
        XCTAssertNotEqual(bubbleId, events[openIndex].messageId)
        XCTAssertTrue(events[openIndex...].contains { $0.type == .assistantTurnEnd && $0.messageId == bubbleId })
        // 起こされたターンの本文を、prompt の返事にしない。
        let first = events[..<promptDoneIndex].filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertEqual(first, try parentChunks("grok-run1", promptPrefix: "c4b5e47c"))
    }

    /// run2: 子のセッションの更新（user_message・吹き出し・available_commands）は、親の出力を変えない。
    /// 子の tool_call の title は、行のいまの作業になる。
    func testGrokChildSessionUpdatesDoNotLeakIntoParent() async throws {
        let session = try makeSession(.grok, fixture: "grok-run2")
        let commandUpdates = Counter()
        session.onCommandsChanged = { _ in commandUpdates.increment() }
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        let events = try await log.until("知らせのターンの done") { $0.contains(where: self.isTaskNotification) }
        await session.close()

        XCTAssertTrue(events.filter { $0.type == .userMessage }.isEmpty, "子の user_message が親に出た")
        XCTAssertEqual(commandUpdates.value, 1, "子の available_commands_update が親のコマンド一覧を書き換えた")
        XCTAssertEqual(events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined(), try parentChunks("grok-run2"),
                       "子の発言が親の吹き出しに混ざった")
        let spawn = "call-8e37557c-b179-4814-8b07-9cc6523ed204-0"
        let all = rows(events, id: spawn)
        XCTAssertTrue(all.contains { $0["resultPreview"] as? String == "run_terminal_command" },
                      "子の tool_call の title が行の作業にならない: \(all.map { $0["resultPreview"] ?? "" })")
        XCTAssertEqual(all.last?["state"] as? String, "done")
    }

    /// run3: 前景の spawn は今まで通り。tool_call_update の completed で、子の出力を持って行が閉じる。
    func testGrokForegroundSpawnClosesOnToolCallUpdate() async throws {
        let session = try makeSession(.grok, fixture: "grok-run3")
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        let events = try await log.until("prompt の done") { $0.contains { $0.type == .done } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let later = log.events
        await session.close()

        let spawn = "call-f0a5c9f4-e034-444e-8909-cc0f2744f4dd-0"
        let all = rows(later, id: spawn)
        XCTAssertEqual(all.first?["state"] as? String, "running")
        XCTAssertEqual(all.last?["state"] as? String, "done", "\(all)")
        XCTAssertTrue(all.dropLast().allSatisfy { $0["state"] as? String == "running" }, "status の無い更新で閉じた: \(all)")
        XCTAssertFalse(all.contains { $0["background"] as? Bool == true })
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1)
        XCTAssertFalse(later.contains(where: isTaskNotification), "前景の委任は知らせのターンも silent の done も出さない")
    }

    // MARK: Hermes

    private func writeLedger(_ name: String, to path: String, rows: [[String: Any]]) throws {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("ledgers.json"))
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let spec = try XCTUnwrap(all[name] as? [String: Any])
        let table = try XCTUnwrap(spec["table"] as? String)
        let columns = try XCTUnwrap(spec["columns"] as? [[String: Any]])
        let names = columns.compactMap { $0["name"] as? String }
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
            let defs = columns.map { "\($0["name"] as! String) \($0["type"] as? String ?? "TEXT")" }.joined(separator: ", ")
            try db.execute(sql: "CREATE TABLE \(table) (\(defs))")
            for row in rows {
                let values: [DatabaseValueConvertible?] = names.map { Self.dbValue(row[$0]) }
                let marks = names.map { _ in "?" }.joined(separator: ", ")
                try db.execute(sql: "INSERT INTO \(table) (\(names.joined(separator: ", "))) VALUES (\(marks))",
                               arguments: StatementArguments(values))
            }
        }
    }

    private static func dbValue(_ any: Any?) -> DatabaseValueConvertible? {
        guard let any, !(any is NSNull) else { return nil }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n.doubleValue == Double(n.int64Value) ? n.int64Value : n.doubleValue
        }
        return any as? String
    }

    private func ledgerRows(_ name: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("ledgers.json"))
        let all = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap((all[name] as? [String: Any])?["rows"] as? [[String: Any]])
    }

    private let hermesRow = "tc-8cc4babe04d6"

    /// run1: 受領票（dispatched）は行を running のまま background にし、台帳の completed で done と summary。
    /// delegate_task: list は行を作らない。最後の行が閉じると、本文の無い知らせのターンの done が 1 回だけ出る。
    func testHermesDispatchedDelegationFollowsTheLedger() async throws {
        let db = tempDir.appendingPathComponent("state.db").path
        let fixtureRows = try ledgerRows("hermes")
        try writeLedger("hermes", to: db, rows: [fixtureRows[0]])
        let session = try makeSession(.hermes, fixture: "hermes-run1", ledger: db)
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])

        let running = try await log.until("running の行") { self.rows($0, id: self.hermesRow).contains { $0["background"] as? Bool == true } }
        let last = try XCTUnwrap(rows(running, id: hermesRow).last)
        XCTAssertEqual(last["state"] as? String, "running")
        XCTAssertEqual(last["taskCount"] as? Int, 1)
        XCTAssertEqual(last["stoppable"] as? Bool, false)
        XCTAssertEqual(running.filter { $0.type == .toolEnd && $0.toolUseId == hermesRow }.count, 1, "tool の行は受領票で閉じる")
        XCTAssertFalse(running.contains(where: isTaskNotification), "動いている間は知らせを出さない")

        try writeLedger("hermes", to: db, rows: [fixtureRows[1]])
        let finished = try await log.until("done の行と silent の done") {
            self.rows($0, id: self.hermesRow).last?["state"] as? String == "done" && $0.contains(where: self.isSilent)
        }
        let done = try XCTUnwrap(rows(finished, id: hermesRow).last)
        XCTAssertEqual(done["result"] as? String, "OK")
        XCTAssertEqual(done["durationMs"] as? Int, 24250)

        // 2 つ目の prompt（delegate_task: list）は行を作らず、silent の done も増やさない。
        await session.send("status", skills: [], attachments: [])
        let after = try await log.until("2 つ目の prompt の done") { $0.filter { $0.type == .done }.count >= 3 }
        try await Task.sleep(nanoseconds: 200_000_000)
        await session.close()
        let listCall = "tc-b5078e40f2c0"
        XCTAssertTrue(after.contains { $0.type == .toolStart && $0.toolUseId == listCall })
        XCTAssertTrue(rows(log.events, id: listCall).isEmpty, "control call が偽の行を作った")
        XCTAssertEqual(log.events.filter(isSilent).count, 1)
        XCTAssertEqual(log.events.filter { $0.type == .done }.count, 3)
    }

    /// 台帳が読めない（30 回続けて失敗）ときは、今まで通り受領票の文を結果にして done。
    func testHermesLedgerFailingThirtyTimesFallsBackToReceipt() async throws {
        let db = tempDir.appendingPathComponent("state.db").path
        try writeLedger("hermes", to: db, rows: try ledgerRows("hermes"))
        var unsafe = Configuration()
        unsafe.allowsUnsafeTransactions = true
        let locker = try DatabaseQueue(path: db, configuration: unsafe)
        try await locker.writeWithoutTransaction { try $0.execute(sql: "BEGIN EXCLUSIVE") }
        let session = try makeSession(.hermes, fixture: "hermes-run1", ledger: db) { $0.delegationPollSeconds = 0.003 }
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        let events = try await log.until("受領票で done") { self.rows($0, id: self.hermesRow).last?["state"] as? String == "done" }
        try await locker.writeWithoutTransaction { try $0.execute(sql: "ROLLBACK") }
        await session.close()

        let done = try XCTUnwrap(rows(events, id: hermesRow).last)
        XCTAssertTrue((done["result"] as? String ?? "").contains("\"status\": \"dispatched\""), "結果は受領票の文: \(done)")
    }

    /// 台帳のファイルが無いときは、1 回目の読み取りで読めないと分かり、受領票で done。
    func testHermesMissingLedgerFileFallsBackToReceiptRightAway() async throws {
        let session = try makeSession(.hermes, fixture: "hermes-run1", ledger: tempDir.appendingPathComponent("none.db").path)
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        let events = try await log.until("受領票で done") { self.rows($0, id: self.hermesRow).last?["state"] as? String == "done" }
        await session.close()
        XCTAssertTrue((rows(events, id: hermesRow).last?["result"] as? String ?? "").contains("dispatched"))
    }

    // MARK: OpenClaw

    private let openclawRow = "call_rq3m76fe"

    private func openclawRunning() throws -> [String: Any] {
        var row = try ledgerRows("openclaw")[0]
        row["status"] = "running"
        row["ended_at"] = NSNull()
        row["progress_summary"] = NSNull()
        row["last_tool_name"] = "exec"
        row["tool_use_count"] = 1
        return row
    }

    /// run3: accepted + mode run + expectsCompletionMessage は非同期。running の間は作業と数、succeeded で done と
    /// progress_summary、最後の行で silent の done。
    func testOpenclawSucceededRunClosesWithProgressSummary() async throws {
        let db = tempDir.appendingPathComponent("openclaw.sqlite").path
        try writeLedger("openclaw", to: db, rows: [try openclawRunning()])
        let session = try makeSession(.openclaw, fixture: "openclaw-run3", ledger: db)
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        let running = try await log.until("作業の入った行") { self.rows($0, id: self.openclawRow).contains { $0["resultPreview"] as? String == "exec" } }
        let mid = try XCTUnwrap(rows(running, id: self.openclawRow).last)
        XCTAssertEqual(mid["state"] as? String, "running")
        XCTAssertEqual(mid["background"] as? Bool, true)
        XCTAssertEqual(mid["toolCalls"] as? Int, 1)

        let all = try ledgerRows("openclaw")
        try writeLedger("openclaw", to: db, rows: all)
        let events = try await log.until("done の行と silent の done") {
            self.rows($0, id: self.openclawRow).last?["state"] as? String == "done" && $0.contains(where: self.isSilent)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        await session.close()
        let done = try XCTUnwrap(rows(events, id: openclawRow).last)
        XCTAssertEqual(done["result"] as? String, "OK")
        XCTAssertEqual(done["durationMs"] as? Int, 10367)
        XCTAssertEqual(log.events.filter(isSilent).count, 1)
    }

    /// cancelled は stopped。
    func testOpenclawCancelledRunClosesAsStopped() async throws {
        let db = tempDir.appendingPathComponent("openclaw.sqlite").path
        var row = try ledgerRows("openclaw")[0]
        row["status"] = "cancelled"
        row["progress_summary"] = NSNull()
        try writeLedger("openclaw", to: db, rows: [row])
        let session = try makeSession(.openclaw, fixture: "openclaw-run3", ledger: db)
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        let events = try await log.until("stopped の行") { self.rows($0, id: self.openclawRow).last?["state"] as? String == "stopped" }
        await session.close()
        XCTAssertEqual(rows(events, id: openclawRow).last?["state"] as? String, "stopped")
    }

    /// prompt の途中で行が閉じたときは、prompt の done がターンの終わりになる（silent の done を足さない）。
    func testNoSilentDoneWhileAPromptIsStillRunning() async throws {
        let db = tempDir.appendingPathComponent("openclaw.sqlite").path
        try writeLedger("openclaw", to: db, rows: try ledgerRows("openclaw"))
        let session = try makeSession(.openclaw, fixture: "openclaw-run3", ledger: db, hold: 0.6)
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        try await Task.sleep(nanoseconds: 300_000_000)
        await session.close()
        let events = log.events
        XCTAssertEqual(rows(events, id: openclawRow).last?["state"] as? String, "done")
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1)
        XCTAssertFalse(events.contains(where: isSilent))
    }

    /// 台帳も CLI も使えない（ファイルが無い）ときは、今まで通り受領票で done。
    func testOpenclawUnreadableLedgerFallsBackToReceipt() async throws {
        let session = try makeSession(.openclaw, fixture: "openclaw-run3", ledger: tempDir.appendingPathComponent("none.sqlite").path)
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        let events = try await log.until("受領票で done") { self.rows($0, id: self.openclawRow).last?["state"] as? String == "done" }
        await session.close()
        XCTAssertTrue((rows(events, id: openclawRow).last?["result"] as? String ?? "").contains("accepted"))
    }

    /// プロセスが死んでも OpenClaw の行は閉じずに台帳を見続ける。
    func testOpenclawRowSurvivesProcessDeathAndKeepsWatching() async throws {
        let db = tempDir.appendingPathComponent("openclaw.sqlite").path
        try writeLedger("openclaw", to: db, rows: [try openclawRunning()])
        let session = try makeSession(.openclaw, fixture: "openclaw-run3", ledger: db, hold: 0)
        let log = EventLog(session)
        await session.send("go", skills: [], attachments: [])
        _ = try await log.until("running") { self.rows($0, id: self.openclawRow).last?["background"] as? Bool == true }
        session.simulateProcessDeathForTesting()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rows(log.events, id: openclawRow).last?["state"] as? String, "running", "プロセスの死で閉じた")
        try writeLedger("openclaw", to: db, rows: try ledgerRows("openclaw"))
        let events = try await log.until("台帳で done") { self.rows($0, id: self.openclawRow).last?["state"] as? String == "done" }
        await session.close()
        XCTAssertEqual(rows(events, id: openclawRow).last?["result"] as? String, "OK")
    }
}

/// Grok の起こされた（知らせの）ターンと背景の spawn を、止めたとき・2 つ続いたときの動き。実測の記録には無い場面なので、
/// 偽のエージェント（python3）に決まった順で流させる。
final class AcpGrokSyntheticTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-grok-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var cancelLog: URL { tempDir.appendingPathComponent("cancel.log") }

    private func makeSession(scenario: String) throws -> AcpSession {
        let url = tempDir.appendingPathComponent("fake-grok.py")
        let script = """
        #!/usr/bin/env python3
        import json, sys, time, threading
        scenario = sys.argv[1]
        sid = "sid-synth"
        A = "subagent-completed-A"
        B = "subagent-completed-B"
        out = threading.Lock()
        cancelled = threading.Event()
        def send(m):
            with out:
                sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
        def upd(u, prompt):
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": u, "_meta": {"promptId": prompt}}})
        def chunk(text, prompt):
            upd({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}, prompt)
        def note(u):
            send({"jsonrpc": "2.0", "method": "_x.ai/session_notification", "params": {"sessionId": sid, "update": u}})
        def queue(pid):
            send({"jsonrpc": "2.0", "method": "_x.ai/queue/changed", "params": {"sessionId": sid, "entries": [], "runningPromptId": pid, "runningText": "x"}})
        def done(pid):
            note({"sessionUpdate": "turn_completed", "prompt_id": pid})
        def woken_stop():
            time.sleep(0.3); queue(A); chunk("first", A)
            time.sleep(1.5); chunk("late", A); done(A)
        def woken_two():
            time.sleep(0.3); queue(A); chunk("a-text", A)
            queue(B); chunk("b-text", B)
            done(A); done(B)
        def spawn_wait(rid):
            upd({"sessionUpdate": "tool_call", "toolCallId": "tc1", "title": "spawn_subagent",
                 "rawInput": {"description": "bg job", "prompt": "x", "background": True},
                 "_meta": {"x.ai/tool": {"name": "spawn_subagent"}, "subagentBackground": True}}, "p1")
            cancelled.wait(10); time.sleep(0.2)
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
        for line in sys.stdin:
            m = json.loads(line)
            method = m.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": sid}})
            elif method == "session/prompt":
                if scenario == "spawn_wait":
                    threading.Thread(target=spawn_wait, args=(m["id"],), daemon=True).start()
                else:
                    send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
                    threading.Thread(target=woken_stop if scenario == "woken_stop" else woken_two, daemon=True).start()
            elif method == "session/cancel":
                open(sys.argv[2], "a").write("cancel\\n")
                cancelled.set()
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        var tuning = AcpSessionTuning()
        tuning.postSessionDelayNanos = 0
        tuning.loginShell = false
        tuning.xaiNotifications = true
        tuning.statuslessUpdateEndsTool = false
        return AcpSession(agentId: "grok", initialSessionId: nil, executable: url.path,
                          args: [scenario, cancelLog.path], cwd: tempDir.path, tuning: tuning)
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SessionEvent] = []
        init(_ session: AcpSession) {
            Task { [weak self] in
                do { for try await e in session.events { self?.append(e) } } catch {}
            }
        }
        private func append(_ e: SessionEvent) { lock.lock(); items.append(e); lock.unlock() }
        var events: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return items }
        func until(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                   _ match: ([SessionEvent]) -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if match(events) { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTFail("待ちきれなかった: \(what) / \(events.map(\.type.rawValue))", file: file, line: line)
        }
    }

    private func isTaskNotification(_ e: SessionEvent) -> Bool {
        e.type == .done && e.metadata?["origin"] == "task-notification"
    }

    private func rows(_ events: [SessionEvent], id: String) -> [[String: Any]] {
        events.filter { $0.type == .workflowProgress }.flatMap { e -> [[String: Any]] in
            guard let data = e.content?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return (obj["agents"] as? [[String: Any]]) ?? []
        }.filter { $0["id"] as? String == id }
    }

    /// 下の停止は、起こされたターンも止める。session/cancel を送り、知らせのターンの done を 1 回出し、続きの本文は捨てる。
    func testBottomStopStopsAWokenTurn() async throws {
        let session = try makeSession(scenario: "woken_stop")
        let log = Log(session)
        Task { await session.send("go", skills: [], attachments: []) }
        try await log.until("起こされたターンの本文") { $0.contains { $0.type == .assistantDelta && $0.content == "first" } }
        await session.interrupt()
        try await Task.sleep(nanoseconds: 2_200_000_000)
        let events = log.events
        await session.close()

        XCTAssertFalse(events.contains { $0.type == .assistantDelta && $0.content == "late" }, "停止のあとに本文が続いた")
        XCTAssertEqual(events.filter(isTaskNotification).count, 1, "\(events.map { $0.metadata ?? [:] })")
        XCTAssertEqual(events.filter { $0.type == .done }.count, 2, "prompt の done と知らせのターンの done だけ")
        let cancels = (try? String(contentsOf: cancelLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(cancels.contains("cancel"), "session/cancel を送っていない")
    }

    /// 前のターンの turn_completed より先に次の通知が来ても、次のターンを落とさない（本文は次の吹き出しになる）。
    func testSecondWokenTurnIsNotLostWhenItStartsBeforeTheFirstEnds() async throws {
        let session = try makeSession(scenario: "woken_two")
        let log = Log(session)
        Task { await session.send("go", skills: [], attachments: []) }
        try await log.until("2 つの知らせのターンの done") { $0.filter(self.isTaskNotification).count == 2 }
        let events = log.events
        await session.close()

        let a = try XCTUnwrap(events.first { $0.type == .assistantDelta && $0.content == "a-text" })
        let b = try XCTUnwrap(events.first { $0.type == .assistantDelta && $0.content == "b-text" })
        XCTAssertNotEqual(a.messageId, b.messageId)
        XCTAssertEqual(events.filter { $0.type == .done }.count, 3, "prompt の done と知らせのターン 2 つ")
        // b-text は prompt の返事に混ざらない（prompt の done より後）。
        let promptDone = try XCTUnwrap(events.firstIndex { $0.type == .done })
        let bIndex = try XCTUnwrap(events.firstIndex { $0.type == .assistantDelta && $0.content == "b-text" })
        XCTAssertGreaterThan(bIndex, promptDone)
    }

    /// 承認待ちのまま止めた背景の spawn は、running のまま残らず stopped で閉じる。
    func testStoppedBackgroundSpawnWithoutReceiptClosesAsStopped() async throws {
        let session = try makeSession(scenario: "spawn_wait")
        let log = Log(session)
        Task { await session.send("go", skills: [], attachments: []) }
        try await log.until("running の行") { !self.rows($0, id: "tc1").isEmpty }
        XCTAssertEqual(rows(log.events, id: "tc1").first?["background"] as? Bool, true)
        await session.interrupt()
        try await log.until("prompt の done") { $0.contains { $0.type == .done } }
        let events = log.events
        await session.close()

        XCTAssertEqual(rows(events, id: "tc1").last?["state"] as? String, "stopped", "\(rows(events, id: "tc1"))")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
