import Foundation
import Vapor
import XCTest
@testable import BridgeApp

/// stdio → `/mcp` の中継（McpStdioRelay）と、ACP の mainagent がそれを選ぶところを確かめる。
/// 中継の中身は台本の transport で、Bridge との通しは本物の McpEndpoint（BridgeRequestGuard / BridgeAuth 付き）で見る。
/// 最後に、組み上がった BridgeApp を `mcp-stdio-relay` で起こして stdin / stdout で話す（バイナリが無ければ飛ばす）。
final class McpStdioRelayTests: XCTestCase {

    /// 送られた要求を覚え、決まった応答（または失敗）を返す transport。
    private final class StubTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
        let reply: @Sendable (URLRequest) throws -> (Int, Data)

        init(reply: @escaping @Sendable (URLRequest) throws -> (Int, Data)) { self.reply = reply }

        private func record(_ req: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(req)
        }

        var transport: McpStdioRelay.Transport {
            { [self] req in
                record(req)
                let (status, body) = try reply(req)
                return (body, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
        }
    }

    private func object(_ line: String?) throws -> [String: Any] {
        let s = try XCTUnwrap(line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    private func errorCode(_ line: String?) throws -> Int? {
        ((try object(line))["error"] as? [String: Any])?["code"] as? Int
    }

    // MARK: - 1 行の中継（台本の transport）

    func testForwardsRequestWithBearerAndWritesResponseAsOneLine() async throws {
        let stub = StubTransport { _ in (200, Data(#"{"id":1,"jsonrpc":"2.0","result":{"tools":[]}}"#.utf8)) }
        let relay = McpStdioRelay(port: 9999, token: "bmt_secret", transport: stub.transport)
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let out = await relay.handle(line: line)
        XCTAssertEqual(out, #"{"id":1,"jsonrpc":"2.0","result":{"tools":[]}}"#, "Bridge の本文をそのまま 1 行で返す")

        let req = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:9999/mcp")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer bmt_secret")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "Origin"), "Origin を付けると BridgeRequestGuard に断られる")
        XCTAssertEqual(req.httpBody, Data(line.utf8))
    }

    func testMultiLineBodyIsCompactedToOneLine() async throws {
        let stub = StubTransport { _ in (200, Data("{\n  \"id\": 7,\n  \"jsonrpc\": \"2.0\",\n  \"result\": {}\n}".utf8)) }
        let relay = McpStdioRelay(port: 9999, token: "bmt_x", transport: stub.transport)
        let reply = await relay.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        let out = try XCTUnwrap(reply)
        XCTAssertFalse(out.contains("\n"))
        XCTAssertEqual(try object(out)["id"] as? Int, 7)
    }

    func testNotificationIsForwardedButGetsNoResponse() async throws {
        let stub = StubTransport { _ in (202, Data()) }
        let relay = McpStdioRelay(port: 9999, token: "bmt_x", transport: stub.transport)
        let out = await relay.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(out)
        XCTAssertEqual(stub.requests.count, 1, "通知も Bridge へ送る")
    }

    func testClientResponsesAndBlankLinesAreNotForwarded() async throws {
        let stub = StubTransport { _ in (200, Data("{}".utf8)) }
        let relay = McpStdioRelay(port: 9999, token: "bmt_x", transport: stub.transport)
        let a = await relay.handle(line: #"{"jsonrpc":"2.0","id":3,"result":{}}"#)
        let b = await relay.handle(line: "   ")
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testMalformedInputGetsJsonRpcError() async throws {
        let stub = StubTransport { _ in (200, Data("{}".utf8)) }
        let relay = McpStdioRelay(port: 9999, token: "bmt_x", transport: stub.transport)
        let parse = try object(await relay.handle(line: "{not json"))
        XCTAssertTrue(parse["id"] is NSNull)
        XCTAssertEqual((parse["error"] as? [String: Any])?["code"] as? Int, -32700)
        let batch = await relay.handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual(try errorCode(batch), -32600)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testUnauthorizedBecomesJsonRpcErrorWithSameId() async throws {
        let stub = StubTransport { _ in (401, Data()) }
        let relay = McpStdioRelay(port: 9999, token: "bmt_revoked", transport: stub.transport)
        let out = try object(await relay.handle(line: #"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#))
        XCTAssertEqual(out["id"] as? String, "abc")
        let error = try XCTUnwrap(out["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, McpStdioRelay.unauthorizedCode)
        XCTAssertFalse((error["message"] as? String ?? "").contains("bmt_revoked"), "合鍵を出さない")
        let note = await relay.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(note, "通知には失敗でも返さない")
    }

    func testBridgeDownAndHttpErrorsBecomeJsonRpcErrors() async throws {
        struct Down: Error {}
        let down = McpStdioRelay(port: 9999, token: "bmt_x", transport: StubTransport { _ in throw Down() }.transport)
        let a = await down.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        XCTAssertEqual(try errorCode(a), McpStdioRelay.unreachableCode)
        let n = await down.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(n)

        let forbidden = McpStdioRelay(port: 9999, token: "bmt_x", transport: StubTransport { _ in (403, Data()) }.transport)
        let b = await forbidden.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        XCTAssertEqual(try errorCode(b), McpStdioRelay.unreachableCode)

        let html = McpStdioRelay(port: 9999, token: "bmt_x", transport: StubTransport { _ in (200, Data("<html>".utf8)) }.transport)
        let c = await html.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        XCTAssertEqual(try errorCode(c), -32603)
    }

    // MARK: - ACP の mainagent が選ぶ渡し方

    func testAcpChoosesHttpWhenAdvertisedAndStdioRelayOtherwise() {
        let http: [String: Any] = ["result": ["agentCapabilities": ["mcpCapabilities": ["http": true, "sse": true]]]]
        XCTAssertEqual(AcpSession.mainagentMcpTransport(initialize: http, relayExecutable: "/x/BridgeApp"), .http)

        // hermes 0.21 は mcpCapabilities を申告しない。
        let noMcp: [String: Any] = ["result": ["agentCapabilities": ["loadSession": true]]]
        XCTAssertEqual(AcpSession.mainagentMcpTransport(initialize: noMcp, relayExecutable: "/x/BridgeApp"),
                       .stdioRelay(executable: "/x/BridgeApp"))
        let httpFalse: [String: Any] = ["result": ["agentCapabilities": ["mcpCapabilities": ["http": false]]]]
        XCTAssertEqual(AcpSession.mainagentMcpTransport(initialize: httpFalse, relayExecutable: "/x/BridgeApp"),
                       .stdioRelay(executable: "/x/BridgeApp"))

        XCTAssertNil(AcpSession.mainagentMcpTransport(initialize: noMcp, relayExecutable: nil), "中継のバイナリが分からなければ渡さない")
        XCTAssertNil(AcpSession.mainagentMcpTransport(initialize: ["error": ["code": -1]], relayExecutable: "/x/BridgeApp"))
    }

    func testStdioRelayEntryKeepsTokenOutOfArgs() throws {
        let e = AcpSession.mainagentMcpServer(.stdioRelay(executable: "/Apps/BuddyOS.app/bin/BridgeApp"), token: "bmt_secret", port: 8765)
        XCTAssertNil(e["type"], "ACP の stdio の McpServer は type を持たない")
        XCTAssertEqual(e["name"] as? String, "buddyos")
        XCTAssertEqual(e["command"] as? String, "/Apps/BuddyOS.app/bin/BridgeApp")
        let args = try XCTUnwrap(e["args"] as? [String])
        XCTAssertEqual(args, ["mcp-stdio-relay"])
        XCTAssertFalse(args.joined().contains("bmt_"), "合鍵は ps で見える引数に載せない")
        let env = try XCTUnwrap(e["env"] as? [[String: String]])
        XCTAssertEqual(env.first { $0["name"] == "BUDDYOS_MCP_TOKEN" }?["value"], "bmt_secret")
        XCTAssertEqual(env.first { $0["name"] == "BUDDYOS_MCP_PORT" }?["value"], "8765")

        let http = AcpSession.mainagentMcpServer(.http, token: "bmt_secret", port: 8765)
        XCTAssertEqual(http["type"] as? String, "http", "HTTP を申告するエージェントは今まで通り")
    }

    // MARK: - 本物の /mcp と通す

    /// Bridge と同じ middleware（Host / Origin の関門と BridgeAuth）を付けた `/mcp`。
    private func startMcpServer() async throws -> (Application, Int) {
        let app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.middleware.use(BridgeRequestGuard.Middleware())
        app.middleware.use(BridgeAuth.Middleware())
        McpEndpoint.register(app: app)
        try await app.server.start()
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        return (app, port)
    }

    func testRelaysThroughRealMcpEndpointAndGuards() async throws {
        let (app, port) = try await startMcpServer()
        let token = await Orchestrator.shared.issueToken(agentId: "relay-test", parentSessionId: nil)

        let relay = McpStdioRelay(port: port, token: token)
        let initialize = try object(await relay.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#))
        XCTAssertEqual(((initialize["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "buddyos",
                       "Host: 127.0.0.1:<port>・Origin 無しで BridgeRequestGuard を通る: \(initialize)")
        let note = await relay.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(note)
        let list = try object(await relay.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(Set(names), Set(MainAgentWorkspace.toolNames))

        let wrong = McpStdioRelay(port: port, token: "bmt_not-issued")
        let denied = await wrong.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        XCTAssertEqual(try errorCode(denied), McpStdioRelay.unauthorizedCode)

        await Orchestrator.shared.revoke(token: token)
        let revoked = await relay.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#)
        XCTAssertEqual(try errorCode(revoked), McpStdioRelay.unauthorizedCode, "閉じたセッションの合鍵は通らない")

        await app.server.shutdown()
        try await app.asyncShutdown()
        let gone = await relay.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)
        XCTAssertEqual(try errorCode(gone), McpStdioRelay.unreachableCode)
    }

    // MARK: - BridgeApp mcp-stdio-relay（組み上がったバイナリ）

    /// テストと同じ場所に組み上がる BridgeApp（swift test は実行ファイルも組む）。
    private func builtBridgeApp() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("BridgeApp")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: url.path), "BridgeApp が無い: \(url.path)")
        return url
    }

    private func runRelay(_ exe: URL, env: [String: String], input: String) throws -> (status: Int32, stdout: String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = [McpStdioRelay.subcommand]
        p.environment = env
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()   // stdin を閉じたら終わる
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: out, encoding: .utf8) ?? "")
    }

    func testBinarySubcommandRelaysOverStdioAndExitsOnEOF() async throws {
        let exe = try builtBridgeApp()
        let (app, port) = try await startMcpServer()
        let token = await Orchestrator.shared.issueToken(agentId: "relay-bin-test", parentSessionId: nil)
        defer { Task { await Orchestrator.shared.revoke(token: token) } }

        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        ].joined(separator: "\n") + "\n"
        let env = ["BUDDYOS_MCP_TOKEN": token, "BUDDYOS_MCP_PORT": String(port)]
        let started = Date()
        let r = try await Task.detached { try self.runRelay(exe, env: env, input: input) }.value
        XCTAssertEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "stdin が閉じたら終わる")
        let lines = r.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "要求 2 件にだけ返す（通知には返さない）: \(r.stdout)")
        let ids = Set(try lines.map { try object($0)["id"] as? Int })
        XCTAssertEqual(ids, [1, 2])

        // 合鍵が無ければ使い方の誤り（64）で終わる。
        let bad = try await Task.detached { try self.runRelay(exe, env: ["BUDDYOS_MCP_PORT": String(port)], input: "") }.value
        XCTAssertEqual(bad.status, 64)

        await app.server.shutdown()
        try await app.asyncShutdown()
    }

    // MARK: - 実 hermes（stdio の MCP しか申告しない ACP エージェント）

    /// 実 hermes を mainagent のフォルダ（テスト用に差し替え）で開き、中継越しに list_agents を呼ばせる。
    /// hermes の利用枠を少し使うので RUN_HERMES_E2E=1 のときだけ走らせる。~/.buddyos には触らない。
    func testHermesMainagentUsesToolsThroughStdioRelay() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_HERMES_E2E"] == "1",
                          "set RUN_HERMES_E2E=1 to run (uses real hermes)")
        let exe = try builtBridgeApp()
        let (app, port) = try await startMcpServer()
        let savedPort = KeyStore.currentPort
        KeyStore.currentPort = port
        McpStdioRelay.executableOverride = exe.path
        let mainDir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-e2e-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)
        MainAgentWorkspace.rootOverride = mainDir
        defer {
            KeyStore.currentPort = savedPort
            McpStdioRelay.executableOverride = nil
            MainAgentWorkspace.rootOverride = nil
            try? FileManager.default.removeItem(at: mainDir)
        }
        // list_agents に出る目印（hermes が道具を呼ばなければ知りようがない名前）。
        let marker = "relayprobe\(UUID().uuidString.prefix(6).lowercased())"
        await AgentRegistry.shared.register(ScriptedAdapter(id: marker) { sid in
            ScriptedSession(agentId: marker, sessionId: sid ?? "pending-\(UUID().uuidString.prefix(6))")
        })

        let session = await HermesAdapter().openSession(sessionId: nil, cwd: mainDir.path)
        XCTAssertTrue(session is AcpSession)
        let collect = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            for try await e in session.events {
                out.append(e)
                if e.type == .done || e.type == .error { break }
            }
            return out
        }
        await session.send("Call the MCP tool list_agents of the buddyos server, then reply with only the agent ids it returned, comma separated.",
                           skills: [], attachments: [])
        let events = (try? await collect.value) ?? []
        await session.close()
        await app.server.shutdown()
        try await app.asyncShutdown()

        let text = events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        print("HERMES relay reply:", text)
        print("HERMES relay events:", events.map { "\($0.type)" }.joined(separator: ","))
        print("HERMES relay errors:", events.filter { $0.type == .error }.compactMap(\.content))
        XCTAssertTrue(text.contains(marker), "中継越しの list_agents の結果が返事に入る: \(text)")
    }
}
