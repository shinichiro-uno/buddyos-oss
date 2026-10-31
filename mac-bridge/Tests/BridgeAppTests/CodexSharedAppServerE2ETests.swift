import XCTest
@testable import BridgeApp

/// 実 codex の共有 app-server を使う E2E。Codex の利用枠を使うので
/// RUN_CODEX_SHARED_E2E=1 のときだけ走らせる。
///
/// 検証すること: Bridge のセッション（A）と、同じ thread に繋いだ別の接続（B = ターミナル役）が
/// 1 つの app-server を共有し、B が始めたターンが A にユーザー発話つきでリアルタイムに流れる。
/// B は `codex --remote ws://…`（buddy-codex）と同じプロトコルで話す。
final class CodexSharedAppServerE2ETests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUN_CODEX_SHARED_E2E"] == "1"
    }

    func testTurnFromAnotherConnectionReachesBridgeSession() async throws {
        try XCTSkipUnless(enabled, "set RUN_CODEX_SHARED_E2E=1 to run (uses real codex app-server)")

        // ChatGPT アカウントで使えるモデルに固定する（~/.codex/config.toml の既定は使わない）。
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let model = ProcessInfo.processInfo.environment["CODEX_E2E_MODEL"] ?? "gpt-6-astra"
        try "model = \"\(model)\"\nmodel_reasoning_effort = \"low\"\n"
            .write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        setenv("BUDDYOS_CODEX_HOME", home.path, 1)
        defer { unsetenv("BUDDYOS_CODEX_HOME") }

        let executable = CodexLiveSession.locateExecutable()
        let endpoint = await CodexSharedAppServer.shared.ensureRunning(
            executable: executable, environment: CodexAppServerSession.spawnEnvironment())
        let shared = try XCTUnwrap(endpoint, "共有 app-server が起動しない")

        let cwd = home.path
        let a = CodexAppServerSession(agentId: "codex", initialSessionId: nil, cwd: cwd,
                                      executable: executable, shared: shared)
        let collector = EventCollector()
        let pump = Task { for try await e in a.events { await collector.add(e) } }
        defer { pump.cancel() }

        // 1. Bridge 側から 1 ターン（thread を作る）
        await a.send("Reply with exactly: BRIDGE-OK", skills: [], attachments: [])
        try await collector.waitFor(doneCount: 1)
        let threadId = a.sessionId
        XCTAssertFalse(threadId.hasPrefix("pending-"), "thread id が確定している")
        let first = await collector.deltasText()
        XCTAssertTrue(first.contains("BRIDGE-OK"), "Bridge 側の返答: \(first)")

        // 2. 別の接続（ターミナル役）から同じ thread に送る
        let b = CodexAppServerSession(agentId: "codex", initialSessionId: threadId, cwd: cwd,
                                      executable: executable, shared: shared)
        let bPump = Task { for try await _ in b.events {} }
        defer { bPump.cancel() }
        await b.send("Reply with exactly: TERM-OK", skills: [], attachments: [])

        // 3. A にユーザー発話と返答が流れる
        try await collector.waitFor(doneCount: 2)
        let users = await collector.userMessages()
        XCTAssertTrue(users.contains { $0.contains("TERM-OK") }, "ターミナル側の発話が流れる: \(users)")
        let all = await collector.deltasText()
        XCTAssertTrue(all.contains("TERM-OK"), "ターミナル側ターンの返答が流れる: \(all)")
        let errors = await collector.errors()
        XCTAssertTrue(errors.isEmpty, "error が出ない: \(errors)")

        await b.close()
        await a.close()
    }
}

extension CodexSharedAppServerE2ETests {
    /// 共有 app-server が知らないモデルが `codex debug models` に出ていたら、再起動で追いつく。
    func testStaleServerCatchesUpWithNewModels() async throws {
        try XCTSkipUnless(enabled, "set RUN_CODEX_SHARED_E2E=1 to run (uses real codex app-server)")
        let executable = CodexLiveSession.locateExecutable()
        let env = CodexAppServerSession.spawnEnvironment()
        let running = await CodexSharedAppServer.shared.ensureRunning(executable: executable, environment: env)
        let endpoint = try XCTUnwrap(running)

        let fresh = CodexSharedAppServer.freshModelIds(executable: executable, environment: env)
        XCTAssertFalse(fresh.isEmpty, "codex debug models が読める")
        await CodexSharedAppServer.shared.checkFreshness(reason: "test")

        let listed = await CodexSharedAppServer.serverModelIds(endpoint)
        let served = try XCTUnwrap(listed, "app-server の model/list が読める")
        XCTAssertTrue(fresh.isSubset(of: served), "足りないモデル: \(fresh.subtracting(served).sorted())")
    }
}

extension CodexSharedAppServerE2ETests {
    /// ターミナルで開いたばかり（1 ターンもしていない = rollout 無し）の thread に、iPhone から送れる。
    func testSendToFreshTerminalThreadWithoutRollout() async throws {
        try XCTSkipUnless(enabled, "set RUN_CODEX_SHARED_E2E=1 to run (uses real codex app-server)")
        let executable = CodexLiveSession.locateExecutable()
        let running = await CodexSharedAppServer.shared.ensureRunning(
            executable: executable, environment: CodexAppServerSession.spawnEnvironment())
        let shared = try XCTUnwrap(running)

        // ターミナル役: thread/start だけして何も送らない（TUI を開いた直後と同じ状態）。
        var req = URLRequest(url: shared.url)
        req.setValue("Bearer \(shared.token)", forHTTPHeaderField: "Authorization")
        let term = URLSession.shared.webSocketTask(with: req)
        term.resume()
        defer { term.cancel(with: .normalClosure, reason: nil) }
        func call(_ id: Int, _ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            try await term.send(.string(String(decoding: data, as: UTF8.self)))
            while true {
                guard case .string(let t) = try await term.receive(),
                      let o = try JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else { continue }
                if (o["id"] as? Int) == id { return o }
            }
        }
        _ = try await call(1, "initialize", ["clientInfo": ["name": "t", "title": "t", "version": "0"],
                                             "capabilities": ["experimentalApi": true]])
        try await term.send(.string("{\"method\":\"initialized\"}"))
        let home = FileManager.default.temporaryDirectory.path
        let started = try await call(2, "thread/start", ["cwd": home, "approvalPolicy": "never", "sandbox": "read-only"])
        let tid = try XCTUnwrap(((started["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String)

        let model = ProcessInfo.processInfo.environment["CODEX_E2E_MODEL"] ?? "gpt-6-astra"
        let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent("codex-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try "model = \"\(model)\"\nmodel_reasoning_effort = \"low\"\n"
            .write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        setenv("BUDDYOS_CODEX_HOME", codexHome.path, 1)
        defer { unsetenv("BUDDYOS_CODEX_HOME") }

        // iPhone 側: その thread を開いて送る。
        let b = CodexAppServerSession(agentId: "codex", initialSessionId: tid, cwd: home,
                                      executable: executable, shared: shared)
        let collector = EventCollector()
        let pump = Task { for try await e in b.events { await collector.add(e) } }
        defer { pump.cancel() }
        await b.send("Reply with exactly: FRESH-OK", skills: [], attachments: [])
        try await collector.waitFor(doneCount: 1)
        let text = await collector.deltasText()
        XCTAssertTrue(text.contains("FRESH-OK"), "返答が届く: \(text)")
        let errors = await collector.errors()
        XCTAssertTrue(errors.isEmpty, "error が出ない: \(errors)")
        await b.close()
    }
}

private actor EventCollector {
    private var events: [SessionEvent] = []

    func add(_ e: SessionEvent) { events.append(e) }

    func deltasText() -> String {
        events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
    }

    func userMessages() -> [String] {
        events.filter { $0.type == .userMessage }.compactMap(\.content)
    }

    func errors() -> [String] {
        events.filter { $0.type == .error }.compactMap(\.content)
    }

    func doneCount() -> Int { events.filter { $0.type == .done }.count }

    func waitFor(doneCount n: Int, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if doneCount() >= n { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTFail("done が \(n) 回来ない（\(doneCount()) 回）")
    }
}
