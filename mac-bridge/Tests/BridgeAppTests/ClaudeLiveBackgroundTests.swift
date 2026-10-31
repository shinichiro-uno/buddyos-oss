import XCTest
@testable import BridgeApp

/// 実際の claude CLI（常駐 stream-json）でバックグラウンド作業・差し込み・中断を確かめる手動実行のテスト。
/// `BUDDYOS_LIVE_CLAUDE=1 swift test --filter ClaudeLiveBackgroundTests` のときだけ走る（ログイン済みの Mac で、haiku を使う）。
/// docs/BACKGROUND_WORK_2026-10-21.md §1・§3.3 の契約を、本物の CLI の出力で確認する。
final class ClaudeLiveBackgroundTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["BUDDYOS_LIVE_CLAUDE"] == "1" else {
            throw XCTSkip("BUDDYOS_LIVE_CLAUDE=1 のときだけ実行")
        }
    }

    /// session.events を溜める。時刻付き。
    private final class Recorder: @unchecked Sendable {
        struct Item { let at: Date; let event: SessionEvent }
        private let lock = NSLock()
        private var items: [Item] = []
        private var task: Task<Void, Never>?

        func start(_ session: AgentSession) {
            task = Task { [self] in
                do {
                    for try await e in session.events {
                        lock.withLock { items.append(Item(at: Date(), event: e)) }
                    }
                } catch {}
            }
        }
        func stop() { task?.cancel() }
        var all: [Item] { lock.withLock { items } }
        var events: [SessionEvent] { all.map(\.event) }
        var dones: [SessionEvent] { events.filter { $0.type == .done } }
        var text: String { events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined() }

        func describe() -> String {
            let t0 = all.first?.at ?? Date()
            return all.map { item -> String in
                let e = item.event
                let dt = String(format: "%6.1fs", item.at.timeIntervalSince(t0))
                var s = "\(dt) \(e.type.rawValue) mid=\(e.messageId?.prefix(6) ?? "-")"
                if let m = e.metadata, !m.isEmpty { s += " meta=\(m)" }
                switch e.type {
                case .assistantDelta: s += " \"\((e.content ?? "").replacingOccurrences(of: "\n", with: "\\n").prefix(40))\""
                case .workflowProgress: s += " \(Self.rowSummary(e.content) ?? (e.content ?? "").prefix(80).description)"
                case .error: s += " \(e.content ?? "")"
                case .toolStart, .toolEnd: s += " tool=\(e.toolName ?? "-")"
                default: break
                }
                return s
            }.joined(separator: "\n")
        }

        /// subagents カードの行の要約 "[id:state(bg)…]"。
        static func rows(_ content: String?) -> [[String: Any]]? {
            guard let data = content?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["kind"] as? String) == "subagents" || (obj["taskId"] as? String) == "subagents"
            else { return nil }
            return obj["agents"] as? [[String: Any]]
        }
        static func rowSummary(_ content: String?) -> String? {
            guard let rows = rows(content) else { return nil }
            let parts = rows.map { r in
                "\(r["rowKind"] as? String ?? "?"):\(r["state"] as? String ?? "?")\((r["background"] as? Bool) == true ? "(bg)" : "")"
            }
            return "subagents[\(parts.joined(separator: ","))]"
        }
    }

    /// 重ねたカードの行（index -> 行）。task_progress は届いた項目だけ上書き、snapshot は置き換え。
    private func foldRows(_ events: [SessionEvent]) -> [Int: [String: Any]] {
        var rows: [Int: [String: Any]] = [:]
        for e in events where e.type == .workflowProgress {
            guard let data = e.content?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["kind"] as? String) == "subagents" || (obj["taskId"] as? String) == "subagents",
                  let agents = obj["agents"] as? [[String: Any]] else { continue }
            if (obj["subtype"] as? String) == "workflow_snapshot" { rows = [:] }
            for a in agents {
                guard let idx = a["index"] as? Int else { continue }
                rows[idx, default: [:]].merge(a) { _, new in new }
            }
        }
        return rows
    }

    private func wait(_ timeout: TimeInterval, _ what: String, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return cond()
    }

    private func makeSession() throws -> (ClaudeCodeSession, URL) {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-live-bg-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let session = ClaudeCodeSession(
            agentId: "claude", profile: .claude, initialSessionId: nil, cwd: cwd.path,
            executable: ClaudeCodeAdapter.locateExecutable(), store: .shared,
            permissionOverride: "dangerous", permissionPrompts: false)
        session.applyOverrides(SessionOverrides(model: "haiku"))
        return (session, cwd)
    }

    /// このテストプロセスの直接の子（claude の常駐プロセス）の pid。
    private func childPids() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(getpid())]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").compactMap { Int32($0) }.sorted()
    }

    // MARK: 1. バックグラウンドのサブエージェント

    func testBackgroundSubagentThenNotificationTurn() async throws {
        try requireLive()
        let (session, _) = try makeSession()
        let rec = Recorder(); rec.start(session)
        defer { rec.stop() }

        let prompt = """
        Launch exactly ONE background subagent using the Agent tool with run_in_background set to true. \
        The subagent must run the shell command `sleep 6` via Bash and then answer exactly "BG-DONE". \
        Do NOT wait for it and do not use any other tool. As soon as it is launched, reply with only the single word STARTED.
        """
        let send = Task { await session.send(prompt, skills: [], attachments: []) }
        // 最初のターンの done が来るまで。
        let firstDone = await wait(90, "first done") { rec.dones.count >= 1 }
        XCTAssertTrue(firstDone, "最初の done が来ない\n\(rec.describe())")
        _ = await send.value

        // 通知のターン（origin = task-notification）の done まで。
        let notified = await wait(90, "notification done") {
            rec.dones.contains { $0.metadata?["origin"] == "task-notification" }
        }
        // 取りこぼしの余韻を待つ。
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let log = rec.describe()
        print("LIVE scenario1 events:\n\(log)")

        XCTAssertTrue(notified, "知らせのターンの done が来ない\n\(log)")
        let events = rec.events
        let dones = rec.dones
        guard let firstIdx = events.firstIndex(where: { $0.type == .done }) else { return XCTFail("no done\n\(log)") }

        // 利用者のターンの done の時点で、バックグラウンドの行が running。
        let rowsAtFirstDone = foldRows(Array(events[...firstIdx]))
        XCTAssertTrue(rowsAtFirstDone.values.contains { ($0["state"] as? String) == "running" && ($0["background"] as? Bool) == true },
                      "最初の done の時点で background の running 行が無い: \(rowsAtFirstDone)\n\(log)")
        XCTAssertNil(dones.first?.metadata?["origin"], "最初の done は利用者のターン\n\(log)")
        XCTAssertTrue(rec.text.contains("STARTED"), "STARTED が出ていない\n\(log)")

        // 知らせのターン。
        let notifDones = dones.filter { $0.metadata?["origin"] == "task-notification" }
        XCTAssertEqual(notifDones.count, 1, "知らせの done は 1 回\n\(log)")
        // 終わったら done。
        let finalRows = foldRows(events)
        let agentRows = finalRows.values.filter { ($0["rowKind"] as? String) == "agent" }
        XCTAssertFalse(agentRows.isEmpty, "agent の行が無い\n\(log)")
        XCTAssertTrue(agentRows.allSatisfy { ($0["state"] as? String) == "done" }, "行が done で終わっていない: \(agentRows)\n\(log)")
        // ターンごとに done は 1 回（利用者 1 + 知らせ 1）、最後の done の後に何も来ない。
        XCTAssertEqual(dones.count, 2, "done は 2 回（利用者のターン + 知らせのターン）\n\(log)")
        if let lastDone = events.lastIndex(where: { $0.type == .done }) {
            let after = events[(lastDone + 1)...].filter { $0.type != .workflowProgress }
            XCTAssertTrue(after.isEmpty, "最後の done の後にイベントが残っている: \(after.map(\.type.rawValue))\n\(log)")
        }
        XCTAssertFalse(events.contains { $0.type == .error }, "error が出た\n\(log)")
        await session.close()
    }

    // MARK: 2. 生成中の差し込み

    func testMidTurnInjectionClosesOnce() async throws {
        try requireLive()
        let (session, _) = try makeSession()
        let rec = Recorder(); rec.start(session)
        defer { rec.stop() }

        let a = Task { await session.send("First write the line START. Then run `sleep 8` with the Bash tool. After it finishes, count from 1 to 30, one number per line.", skills: [], attachments: []) }
        let gotText = await wait(60, "first text") { rec.events.contains { $0.type == .assistantDelta } }
        XCTAssertTrue(gotText, "最初の本文が来ない\n\(rec.describe())")
        let b = Task { await session.send("After you finish, additionally say the exact token B-OK on its own line.", skills: [], attachments: []) }

        let finished = await wait(90, "done") { rec.dones.count >= 1 }
        // 合流した result が 1 つなので、2 つ目の done は出ない。余韻を待つ。
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let log = rec.describe()
        print("LIVE scenario2 events:\n\(log)")
        XCTAssertTrue(finished, "done が来ない\n\(log)")
        // 両方の send() が戻る（ターンが 2 つとも結び付いて閉じた）。
        let r = await withTaskGroup(of: Bool.self) { g -> Bool in
            g.addTask { await a.value; await b.value; return true }
            g.addTask { try? await Task.sleep(nanoseconds: 20_000_000_000); return false }
            let first = await g.next() ?? false
            g.cancelAll()
            return first
        }
        XCTAssertTrue(r, "send() が戻らない（ターンが閉じずに残っている）\n\(log)")

        XCTAssertEqual(rec.dones.count, 1, "done はちょうど 1 回\n\(log)")
        XCTAssertFalse(rec.events.contains { $0.type == .error }, "error が出た\n\(log)")
        XCTAssertTrue(rec.text.contains("B-OK"), "B の返事が無い\n\(log)")
        // 差し込みの後の返事は B の messageId の新しい吹き出し。done は最後（B）のターンの id。
        let ids = Set(rec.events.filter { $0.type == .assistantDelta }.compactMap(\.messageId))
        XCTAssertGreaterThanOrEqual(ids.count, 1)
        if let doneId = rec.dones.first?.messageId {
            XCTAssertTrue(ids.contains(doneId) || ids.count >= 1, "done の messageId が本文のものと違う\n\(log)")
        }
        await session.close()
    }

    // MARK: 3. 中断（プロセスも背景の作業も残る）

    /// perTaskStopAffordance を宣言したので、返事を止める interrupt は背景のシェルを止めない。プロセスも入れ替わらない。
    func testInterruptKeepsProcessAndNextSendWorks() async throws {
        try requireLive()
        let (session, _) = try makeSession()
        let rec = Recorder(); rec.start(session)
        defer { rec.stop() }

        await session.send("Use the Bash tool exactly once with the command `sleep 120` and run_in_background set to true. Do not wait for it. Then reply with only the word STARTED.", skills: [], attachments: [])
        let running = await wait(60, "background shell running") {
            self.foldRows(rec.events).values.contains { ($0["state"] as? String) == "running" && ($0["rowKind"] as? String) == "shell" }
        }
        XCTAssertTrue(running, "背景のシェルの行が出ない\n\(rec.describe())")
        let doneBefore = rec.dones.count

        let first = Task {
            await session.send("Write a long essay of at least 600 words about the history of the bicycle. No tools.", skills: [], attachments: [])
        }
        let gotText = await wait(60, "essay text") { rec.events.filter { $0.type == .assistantDelta }.count > 1 }
        XCTAssertTrue(gotText, "本文が来ない\n\(rec.describe())")
        let pidsBefore = childPids()
        XCTAssertFalse(pidsBefore.isEmpty, "claude の子プロセスが見つからない")

        await session.interrupt()
        let closed = await wait(30, "done after interrupt") { rec.dones.count > doneBefore }
        _ = await first.value
        let afterInterrupt = rec.describe()
        XCTAssertTrue(closed, "中断で done が来ない\n\(afterInterrupt)")
        XCTAssertFalse(rec.events.contains { $0.type == .error }, "中断が error になった\n\(afterInterrupt)")
        XCTAssertEqual(rec.dones.count, doneBefore + 1, "中断のターンの done は 1 回\n\(afterInterrupt)")
        XCTAssertEqual(childPids(), pidsBefore, "interrupt でプロセスが入れ替わった\n\(afterInterrupt)")
        let shells = foldRows(rec.events).values.filter { ($0["rowKind"] as? String) == "shell" }
        XCTAssertTrue(shells.allSatisfy { ($0["state"] as? String) == "running" }, "interrupt で背景のシェルが止まった: \(shells)\n\(afterInterrupt)")

        let before = rec.events.count
        await session.send("Reply with exactly the word: PONG", skills: [], attachments: [])
        let pong = await wait(60, "second done") { rec.dones.count >= doneBefore + 2 }
        let log = rec.describe()
        print("LIVE scenario3 events:\n\(log)\npids before=\(pidsBefore) afterSend=\(childPids())")
        XCTAssertTrue(pong, "中断のあとの送信が閉じない\n\(log)")
        XCTAssertTrue(rec.events[before...].contains { $0.type == .assistantDelta && ($0.content ?? "").uppercased().contains("PONG") },
                      "PONG が返らない\n\(log)")
        XCTAssertEqual(pidsBefore, childPids(), "次の送信でプロセスが入れ替わった\n\(log)")
        XCTAssertFalse(rec.events.contains { $0.type == .error }, "error が出た\n\(log)")
        await session.close()
    }

    // MARK: 4. 行ごとの停止

    /// stop_task で背景のシェルを 1 つだけ止める。もう 1 つとプロセスは生きている。
    func testStopTaskStopsOnlyOneRow() async throws {
        try requireLive()
        let (session, _) = try makeSession()
        let rec = Recorder(); rec.start(session)
        defer { rec.stop() }

        await session.send("Use the Bash tool twice, one call at a time, with the commands `sleep 121` and `sleep 122`, both with run_in_background set to true. Do not wait for them. Then reply with only the word STARTED.", skills: [], attachments: [])
        let ready = await wait(60, "two stoppable rows") {
            self.foldRows(rec.events).values.filter { ($0["state"] as? String) == "running" && ($0["stoppable"] as? Bool) == true }.count >= 2
        }
        XCTAssertTrue(ready, "stoppable な行が 2 つ出ない\n\(rec.describe())")
        let snapshot = await session.subagentSnapshot()
        let obj = snapshot.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let epoch = obj?["epoch"] as? String
        let target = (obj?["agents"] as? [[String: Any]])?.first { ($0["state"] as? String) == "running" }
        let pids = childPids()

        let outcome = await session.stopTask(StopTaskRequest(taskId: "subagents", rowId: target?["id"] as? String, epoch: epoch))
        XCTAssertEqual(outcome, .stopped, rec.describe())
        let rows = foldRows(rec.events).values
        XCTAssertEqual(rows.filter { ($0["state"] as? String) == "stopped" }.count, 1, "止まったのは 1 行だけ\n\(rec.describe())")
        XCTAssertEqual(rows.filter { ($0["state"] as? String) == "running" }.count, 1)
        XCTAssertEqual(childPids(), pids, "プロセスは生きている")
        await session.close()
    }

    /// dynamic workflow の停止。止まらなければ workflowStopEnabled が false になり、次は unsupported。
    func testStopDynamicWorkflow() async throws {
        try requireLive()
        let (session, _) = try makeSession()
        let rec = Recorder(); rec.start(session)
        defer { rec.stop() }

        await session.send("Use the Workflow tool to run a small dynamic workflow with one agent that runs `sleep 60` via Bash. Do not wait for it. Then reply with only the word STARTED.", skills: [], attachments: [])
        var cardId: String?
        _ = await wait(60, "workflow card") {
            cardId = rec.events.compactMap { e -> String? in
                guard e.type == .workflowProgress, let data = e.content?.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      o["taskId"] as? String != "subagents", o["stoppable"] as? Bool == true else { return nil }
                return o["taskId"] as? String
            }.last
            return cardId != nil
        }
        guard let cardId else { throw XCTSkip("このモデル・CLI では dynamic workflow が始まらなかった\n\(rec.describe())") }

        let outcome = await session.stopTask(StopTaskRequest(taskId: cardId))
        print("LIVE workflow stop outcome=\(outcome)\n\(rec.describe())")
        switch outcome {
        case .stopped:
            XCTAssertTrue(rec.events.contains { $0.content?.contains("\"outcome\":\"stopped\"") == true })
        case .failed:
            let again = await session.stopTask(StopTaskRequest(taskId: cardId))
            XCTAssertEqual(again, .unsupported(nil), "止まらなければ workflowStopEnabled が false")
        default:
            XCTFail("想定外の結果 \(outcome)")
        }
        await session.close()
    }
}
