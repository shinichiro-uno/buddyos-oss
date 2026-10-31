import Foundation
import XCTest
@testable import BridgeApp

/// アプリ内ターミナルで開いた mainagent の claude に道具を渡す仕組み（`.mcp.json` の中継・ターミナル用の合鍵）を確かめる。
final class TerminalMainAgentMcpTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddyos-terminal-mcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        BuddyPaths.setOverride(nil)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: - ターミナル用の合鍵

    func testTerminalTokenIsCreatedPrivateAndNeverOverwritten() throws {
        let url = root.appendingPathComponent("main-mcp-token")
        let first = try XCTUnwrap(MainAgentWorkspace.ensureTerminalToken(url: url))
        XCTAssertTrue(first.hasPrefix("bmt_"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600, "合鍵のファイルは本人だけが読める")
        XCTAssertEqual(MainAgentWorkspace.ensureTerminalToken(url: url), first, "あれば作り直さない（動いている claude が使い続ける）")
        XCTAssertEqual(MainAgentWorkspace.terminalToken(url: url), first)
    }

    // MARK: - .mcp.json と settings.json

    func testTerminalMcpMergesAndKeepsOtherEntries() throws {
        let main = root.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: main.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"other":{"type":"stdio","command":"/bin/echo"}}}"#.utf8)
            .write(to: main.appendingPathComponent(".mcp.json"))
        try Data(#"{"model":"opus","enabledMcpjsonServers":["other"]}"#.utf8)
            .write(to: main.appendingPathComponent(".claude/settings.json"))

        MainAgentWorkspace.ensureTerminalMcp(root: main, executable: "/Applications/BuddyOS.app/bin/BridgeApp")

        let mcp = try json(main.appendingPathComponent(".mcp.json"))
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"], "ほかのサーバは残す")
        let buddy = try XCTUnwrap(servers["buddyos"] as? [String: Any])
        XCTAssertEqual(buddy["type"] as? String, "stdio")
        XCTAssertEqual(buddy["command"] as? String, "/Applications/BuddyOS.app/bin/BridgeApp")
        XCTAssertEqual(buddy["args"] as? [String], ["mcp-stdio-relay", "--terminal"])
        XCTAssertNil(buddy["env"], "合鍵はファイルに書かない（中継が自分で読む）")

        let settings = try json(main.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(settings["model"] as? String, "opus", "ほかの設定は残す")
        XCTAssertEqual(settings["enabledMcpjsonServers"] as? [String], ["other", "buddyos"])

        // 2 回目は中身が同じなので書かない。
        let before = try FileManager.default.attributesOfItem(atPath: main.appendingPathComponent(".mcp.json").path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.05)
        MainAgentWorkspace.ensureTerminalMcp(root: main, executable: "/Applications/BuddyOS.app/bin/BridgeApp")
        let after = try FileManager.default.attributesOfItem(atPath: main.appendingPathComponent(".mcp.json").path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertEqual(try json(main.appendingPathComponent(".claude/settings.json"))["enabledMcpjsonServers"] as? [String],
                       ["other", "buddyos"], "重ねて足さない")
    }

    func testTerminalMcpLeavesNonJsonFilesAlone() throws {
        let main = root.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        let broken = Data("not json {".utf8)
        try broken.write(to: main.appendingPathComponent(".mcp.json"))
        MainAgentWorkspace.ensureTerminalMcp(root: main, executable: "/x/BridgeApp")
        XCTAssertEqual(try Data(contentsOf: main.appendingPathComponent(".mcp.json")), broken)
    }

    func testTerminalMcpNeedsExecutable() {
        let main = root.appendingPathComponent("main", isDirectory: true)
        MainAgentWorkspace.ensureTerminalMcp(root: main, executable: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: main.appendingPathComponent(".mcp.json").path))
    }

    // MARK: - 中継（--terminal）

    func testTerminalRelayReadsTokenAndPortPerRequestAndSendsPid() async throws {
        try Data("bmt_term\n".utf8).write(to: root.appendingPathComponent("main-mcp-token"))
        try Data("9101\n".utf8).write(to: root.appendingPathComponent("bridge.port"))
        let lock = NSLock()
        nonisolated(unsafe) var seen: [URLRequest] = []
        let transport: McpStdioRelay.Transport = { req in
            lock.lock(); seen.append(req); lock.unlock()
            let body = Data(#"{"id":1,"jsonrpc":"2.0","result":{}}"#.utf8)
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
        let dir = root!
        let relay = McpStdioRelay(target: McpStdioRelay.fileTarget(root: { dir }), claudePid: 4242, transport: transport)
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        _ = await relay.handle(line: line)
        // Bridge が起動し直して番号が変わった。
        try Data("9102".utf8).write(to: root.appendingPathComponent("bridge.port"))
        _ = await relay.handle(line: line)

        lock.lock(); let reqs = seen; lock.unlock()
        XCTAssertEqual(reqs.map { $0.url?.absoluteString }, ["http://127.0.0.1:9101/mcp", "http://127.0.0.1:9102/mcp"])
        XCTAssertEqual(reqs.first?.value(forHTTPHeaderField: "Authorization"), "Bearer bmt_term")
        XCTAssertEqual(reqs.first?.value(forHTTPHeaderField: MainAgentWorkspace.claudePidHeader), "4242")
    }

    func testTerminalRelayWithoutFilesAnswersError() async throws {
        let dir = root!
        let relay = McpStdioRelay(target: McpStdioRelay.fileTarget(root: { dir }), claudePid: 1,
                                  transport: { _ in XCTFail("送らない"); throw URLError(.badURL) })
        let reply = await relay.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#)
        let out = try XCTUnwrap(reply)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual((obj["error"] as? [String: Any])?["code"] as? Int, McpStdioRelay.unreachableCode)
        XCTAssertEqual(obj["id"] as? Int, 7)
    }

    // MARK: - Orchestrator がターミナル用の合鍵を受け付ける

    func testOrchestratorAcceptsTerminalTokenAndRejectsOthers() async throws {
        BuddyPaths.setOverride(root)
        let token = try XCTUnwrap(MainAgentWorkspace.ensureTerminalToken())
        let c = await Orchestrator.shared.caller(token: token, claudePid: 999_999)
        let caller = try XCTUnwrap(c, "ターミナル用の合鍵は通す")
        XCTAssertTrue(caller.terminal)
        XCTAssertTrue(caller.isMain)
        XCTAssertEqual(caller.agentId, "claude")
        XCTAssertEqual(caller.depth, 0)
        XCTAssertNotEqual(caller.token, token, "PID ごとの Grant のキーで動く")
        let again = await Orchestrator.shared.caller(token: token, claudePid: 999_999)
        XCTAssertEqual(again?.token, caller.token, "同じ claude なら同じ Grant")

        let wrong = await Orchestrator.shared.caller(token: token + "x", claudePid: 999_999)
        XCTAssertNil(wrong)
        let pidOnly = await Orchestrator.shared.caller(token: "#999999", claudePid: 999_999)
        XCTAssertNil(pidOnly)
    }
}
