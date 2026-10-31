import XCTest
@testable import BridgeApp

/// shared/fixtures/codex（windows-bridge と共有する Codex の履歴・config.toml のテストデータ）を読む。
/// windows-bridge/src/agents/codexFixtures.test.ts と同じ筋書き。書き込むので一時ディレクトリへ写し、
/// BUDDYOS_CODEX_HOME をそこへ向ける。
final class CodexFixtureTests: XCTestCase {
    private static let fixtureDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/fixtures/codex")

    private var tmp: URL!
    private var savedCodexHome: String?

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("buddyos-mb-codex-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedCodexHome = ProcessInfo.processInfo.environment["BUDDYOS_CODEX_HOME"]
    }

    override func tearDownWithError() throws {
        if let savedCodexHome { setenv("BUDDYOS_CODEX_HOME", savedCodexHome, 1) } else { unsetenv("BUDDYOS_CODEX_HOME") }
        try? FileManager.default.removeItem(at: tmp)
    }

    /// fixture の home/.codex を写して BUDDYOS_CODEX_HOME にする。写した .codex を返す。
    private func freshCodexHome(_ label: String) throws -> URL {
        let home = tmp.appendingPathComponent(label)
        try FileManager.default.copyItem(at: Self.fixtureDir.appendingPathComponent("home"), to: home)
        let codex = home.appendingPathComponent(".codex")
        setenv("BUDDYOS_CODEX_HOME", codex.path, 1)
        return codex
    }

    private func expected() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("expected.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtureDir.appendingPathComponent(name), encoding: .utf8)
    }

    /// expected に書いたキーだけ比べる（metadata は 1 段下まで）。
    private func assertPartial(_ event: SessionEvent, _ want: [String: Any], _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        for (key, value) in want {
            if let inner = value as? [String: Any] {
                let got = actual[key] as? [String: Any]
                XCTAssertNotNil(got, "\(label): \(key) が無い", file: file, line: line)
                for (k, v) in inner {
                    XCTAssertEqual(got?[k] as? String, v as? String, "\(label): \(key).\(k)", file: file, line: line)
                }
            } else {
                XCTAssertEqual(actual[key] as? String, value as? String, "\(label): \(key)", file: file, line: line)
            }
        }
    }

    func testListSessions() async throws {
        _ = try freshCodexHome("list")
        let exp = try XCTUnwrap(try expected()["listSessions"] as? [String: Any])
        let want = try XCTUnwrap(exp["events"] as? [[String: Any]])
            .sorted { ($0["sessionId"] as? String ?? "") < ($1["sessionId"] as? String ?? "") }
        let adapter = CodexHistoryAdapter()
        let events = await adapter.listSessions(limit: 50, cwd: nil)
            .map { SessionEvent.sessionListItem(agentId: "codex", summary: $0) }
            .sorted { ($0.sessionId ?? "") < ($1.sessionId ?? "") }
        XCTAssertEqual(events.map(\.sessionId), want.map { $0["sessionId"] as? String })
        for (i, e) in events.enumerated() where i < want.count {
            // messageCount は mac が出さない（一覧は先頭だけ読んで打ち切るため数えられない）。
            // mac に残る既知のずれ。
            var w = want[i]
            if var meta = w["metadata"] as? [String: Any] { meta["messageCount"] = nil; w["metadata"] = meta }
            try assertPartial(e, w, "session_list_item[\(i)]")
            XCTAssertNil(e.metadata?["messageCount"])
        }

        let byCwd = try XCTUnwrap(try expected()["listSessionsByCwd"] as? [String: Any])
        let filtered = await adapter.listSessions(limit: 50, cwd: byCwd["cwd"] as? String)
        XCTAssertEqual(filtered.map(\.sessionId), byCwd["sessionIds"] as? [String])
    }

    func testLoadHistory() async throws {
        _ = try freshCodexHome("history")
        let exp = try XCTUnwrap(try expected()["loadHistory"] as? [String: Any])
        let sid = try XCTUnwrap(exp["sessionId"] as? String)
        let want = try XCTUnwrap(exp["events"] as? [[String: Any]])
        let events = await CodexHistoryAdapter().loadHistory(sessionId: sid).map {
            SessionEvent.historyMessage(agentId: "codex", sessionId: sid, role: $0.role, content: $0.content, messageId: $0.messageId)
        }
        XCTAssertEqual(events.count, want.count)
        for (i, e) in events.enumerated() where i < want.count {
            try assertPartial(e, want[i], "history_message[\(i)]")
        }
    }

    func testMcpList() throws {
        _ = try freshCodexHome("mcp-list")
        let exp = try XCTUnwrap(try expected()["mcpList"] as? [String: Any])
        let want = try XCTUnwrap(exp["items"] as? [[String: String]])
        let items = McpService.list(agentId: "codex").map { ["name": $0.name, "transport": $0.transport] }
        XCTAssertEqual(items, want)
    }

    func testMcpRegisterAppendsAndKeepsExistingLines() throws {
        let codex = try freshCodexHome("mcp-register")
        let exp = try XCTUnwrap(try expected()["mcpRegister"] as? [String: Any])
        for raw in try XCTUnwrap(exp["specs"] as? [[String: Any]]) {
            let spec = McpRegisterSpec(
                serverName: raw["serverName"] as? String ?? "",
                transportKind: raw["transportKind"] as? String ?? "",
                url: raw["url"] as? String,
                command: raw["command"] as? String,
                args: raw["args"] as? [String] ?? [],
                env: raw["env"] as? [String: String] ?? [:]
            )
            let r = McpService.register(agentId: "codex", spec: spec)
            XCTAssertTrue(r.ok, "\(spec.serverName): \(r.message ?? "")")
            XCTAssertEqual(r.message, "ok")
        }
        let actual = try String(contentsOf: codex.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertEqual(actual, try fixtureText(try XCTUnwrap(exp["expectedFile"] as? String)))
    }

    func testMcpDeleteRemovesDistantSubtablesAndKeepsComments() throws {
        let codex = try freshCodexHome("mcp-delete")
        let exp = try XCTUnwrap(try expected()["mcpDelete"] as? [String: Any])
        let r = McpService.deleteCodex(name: try XCTUnwrap(exp["serverName"] as? String))
        XCTAssertTrue(r.0)
        XCTAssertEqual(r.1, "ok")
        let actual = try String(contentsOf: codex.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertEqual(actual, try fixtureText(try XCTUnwrap(exp["expectedFile"] as? String)))
    }
}
