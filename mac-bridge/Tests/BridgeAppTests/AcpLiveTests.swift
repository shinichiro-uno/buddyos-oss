import XCTest
@testable import BridgeApp

/// 実際の CLI を ACP で動かす確認（ログイン済みの Mac で手動実行する）。
/// `BUDDYOS_LIVE_ACP=grok swift test --filter AcpLiveTests` のように、確かめる agent を指定したときだけ走る。
/// 画像の確認は `BUDDYOS_LIVE_ACP_IMAGE=<PNG のパス>` を足したときだけ。
final class AcpLiveTests: XCTestCase {
    private func liveProfile() throws -> HeadlessCliProfile {
        switch ProcessInfo.processInfo.environment["BUDDYOS_LIVE_ACP"] {
        case "grok": return .grok
        case "cursor": return .cursor
        default: throw XCTSkip("BUDDYOS_LIVE_ACP=grok|cursor のときだけ実行")
        }
    }

    private func run(_ session: AgentSession, _ text: String, attachments: [BridgeAttachment] = []) async -> [SessionEvent] {
        let task = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            for try await e in session.events {
                out.append(e)
                if e.type == .done || e.type == .error { break }
            }
            return out
        }
        await session.send(text, skills: [], attachments: attachments)
        return (try? await task.value) ?? []
    }

    func testReplyImageListAndHistory() async throws {
        let profile = try liveProfile()
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("acp-live-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let adapter = HeadlessCliAdapter(profile: profile)
        let session = await adapter.openSession(sessionId: nil, cwd: cwd.path)
        XCTAssertTrue(session is AcpSession, "cursor / grok は ACP で開く")

        let first = await run(session, "Reply with exactly the word: pong")
        let text = first.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        print("LIVE reply:", text, first.filter { $0.type == .error }.compactMap(\.content))
        XCTAssertTrue(text.lowercased().contains("pong"))

        // 画像の確認は BUDDYOS_LIVE_ACP_IMAGE（ChatGPT のホーム画面を写した PNG のパス）があるときだけ。
        var turns = 1
        if let imagePath = ProcessInfo.processInfo.environment["BUDDYOS_LIVE_ACP_IMAGE"], !imagePath.isEmpty {
            let png = try Data(contentsOf: URL(fileURLWithPath: imagePath))
            let second = await run(session, "画像に写っているサービス名を一言で答えて",
                                   attachments: [BridgeAttachment(kind: .image, name: "home.png", mime: "image/png", data: png)])
            let answer = second.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
            print("LIVE image:", answer)
            XCTAssertTrue(answer.lowercased().contains("chatgpt"))
            turns += 1
        } else {
            print("LIVE image: skipped (set BUDDYOS_LIVE_ACP_IMAGE to a PNG of the ChatGPT home screen)")
        }
        let sid = session.sessionId
        await session.close()

        let list = await adapter.listSessions(limit: 50, cwd: cwd.path)
        print("LIVE list:", list.map { "\($0.sessionId.prefix(8)) \($0.title)" })
        XCTAssertTrue(list.contains { $0.sessionId == sid })
        let history = await adapter.loadHistory(sessionId: sid)
        print("LIVE history:", history.map { "\($0.role): \($0.content.prefix(60))" })
        XCTAssertGreaterThanOrEqual(history.count, turns * 2)
    }

    /// Plan モードではファイルを作らない（grok は `/plan`、cursor は mode=plan）。計画の承認は iPhone に出る。
    func testPlanModeDoesNotEdit() async throws {
        let profile = try liveProfile()
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("acp-plan-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let session = await HeadlessCliAdapter(profile: profile).openSession(sessionId: nil, cwd: cwd.path)
        (session as? SessionOverridable)?.applyOverrides(SessionOverrides(mode: "plan"))
        let events = await run(session, "Create a file named hello.txt containing hi.")
        await session.close()
        print("LIVE plan events:", events.map { "\($0.type)" }.joined(separator: ","))
        print("LIVE plan actions:", events.filter { $0.type == .actionRequest }.compactMap(\.content))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cwd.path)) ?? []
        print("LIVE plan files:", files)
        XCTAssertFalse(files.contains("hello.txt"), "Plan モードでは書かない")
    }
}
