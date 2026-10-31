import Foundation
import Vapor
import XCTest
@testable import BridgeApp

/// 実 claude（haiku）を mainagent として起こし、`/mcp` の道具で子のセッションに頼んで返事を受け取るまでを通す E2E。
/// claude の利用枠を少し使うので RUN_CLAUDE_E2E=1 のときだけ走らせる。
///
/// 本番と同じく SessionHub を通して mainagent のフォルダ（テスト用に差し替え）で開き、
/// 送る・起こすの承認カードは Bridge が mainagent の画面へ出す。子は台本の adapter（"echo: <本文>" を返す）。
final class MainAgentE2ETests: XCTestCase {
    private var enabled: Bool { ProcessInfo.processInfo.environment["RUN_CLAUDE_E2E"] == "1" }

    func testClaudeCliMainagentDelegatesThroughMcp() async throws {
        try await run(adapter: ClaudeCodeAdapter())
    }

    private func run(adapter: AgentAdapter) async throws {
        try XCTSkipUnless(enabled, "set RUN_CLAUDE_E2E=1 to run (uses real claude, haiku)")
        setenv("BUDDYOS_CLAUDE_MODEL", "haiku", 1)
        defer { unsetenv("BUDDYOS_CLAUDE_MODEL") }

        let app = try await Application.make(.testing)
        // 本番（WebSocketServer.register）と同じ順で、Host / Origin の確認と認証（/mcp は .mainAgentToken）を通す。
        app.middleware.use(BridgeRequestGuard.Middleware())
        app.middleware.use(BridgeAuth.Middleware())
        McpEndpoint.register(app: app)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        try await app.server.start()
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        let savedPort = KeyStore.currentPort
        KeyStore.currentPort = port

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mainagent-e2e-\(UUID().uuidString)")
        let mainDir = base.appendingPathComponent("main")
        let work = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        MainAgentWorkspace.rootOverride = mainDir

        let child = "e2e-child-\(UUID().uuidString.prefix(6).lowercased())"
        let childSid = "child-\(UUID().uuidString.prefix(6).lowercased())"
        await AgentRegistry.shared.register(ScriptedAdapter(id: child) { sid in
            let s = ScriptedSession(agentId: child, sessionId: sid ?? "pending-\(UUID().uuidString.prefix(6))")
            s.onSend = { s, text, n in
                if n == 1, sid == nil { s.emit(.sessionStarted(agentId: child, sessionId: childSid)) }
                s.emit(.assistantDelta("echo: \(text)", agentId: child, sessionId: childSid, messageId: "m\(n)"))
                s.emit(.done(agentId: child, sessionId: childSid, messageId: "m\(n)"))
            }
            return s
        })

        // iPhone 1 台が mainagent のチャットを開いている状態（hub の購読者）。
        let collected = EventBox()
        let subscriber = UUID()
        let session = await SessionHub.shared.acquire(
            agentId: adapter.id, sessionId: nil, cwd: mainDir.path, adapter: adapter,
            subscriberId: subscriber, send: { collected.add($0) })
        defer {
            KeyStore.currentPort = savedPort
            MainAgentWorkspace.rootOverride = nil
            try? FileManager.default.removeItem(at: base)
        }

        let prompt = """
        Use the buddyos MCP tools. 1) Call start_session with agent "\(child)", cwd "\(work.path)", prompt "ping-42", wait_seconds 10. \
        2) Answer with only the reply text you got.
        """
        await SessionHub.shared.notePromptSent(agentId: adapter.id, sessionId: session.sessionId)
        Task { await session.send(prompt, skills: [], attachments: []) }

        // start_session は Bridge が承認カードを出す（Claude 側の承認ではない）。iPhone と同じく許可して進める。
        let card = try await collected.wait(timeout: 180) { $0.type == .actionRequest }
        XCTAssertTrue((card.metadata?["requestId"] ?? "").hasPrefix("mainagent-"), "Bridge のカード: \(card.metadata ?? [:])")
        XCTAssertTrue((card.metadata?["subtitle"] ?? "").contains("ping-42"), "頼む文がカードに出る")
        let resolved = await Orchestrator.shared.resolveApproval(requestId: card.messageId ?? "", decision: "allow")
        XCTAssertTrue(resolved)

        _ = try await collected.wait(timeout: 180) { $0.type == .done }
        let text = collected.events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertTrue(text.contains("echo: ping-42"), "子の返事が mainagent まで届く: \(text)")
        XCTAssertEqual(collected.events.filter { $0.type == .actionRequest }.count, 1, "承認は Bridge の 1 枚だけ")
        // 任せた子の進み具合が、mainagent のチャットにカード（workflow_progress kind = "sessions"）で届く。
        let card2 = try await collected.wait(timeout: 10) {
            $0.type == .workflowProgress && ($0.content ?? "").contains("\"kind\":\"sessions\"")
                && ($0.content ?? "").contains("\"status\":\"done\"") && ($0.content ?? "").contains(child)
        }
        XCTAssertTrue((card2.content ?? "").contains("echo: ping-42"), card2.content ?? "")

        await SessionHub.shared.release(subscriberId: subscriber)
        await session.close()
        await app.server.shutdown()
        try await app.asyncShutdown()
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SessionEvent] = []
    var events: [SessionEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func add(_ e: SessionEvent) { lock.lock(); _events.append(e); lock.unlock() }

    func wait(timeout: TimeInterval, _ match: (SessionEvent) -> Bool) async throws -> SessionEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = events.first(where: match) { return hit }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("待ちきれなかった。届いた種別: \(events.map(\.type.rawValue)) / error: \(events.filter { $0.type == .error }.compactMap(\.content)) / 本文: \(events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined())")
        throw CancellationError()
    }
}
