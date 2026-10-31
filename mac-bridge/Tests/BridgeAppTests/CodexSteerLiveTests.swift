import XCTest
@testable import BridgeApp

/// 生成中の追加送信が turn/steer で同じターンに入るか（実際の Codex で確かめる。手動実行）。
/// `BUDDYOS_LIVE_CODEX=1 swift test --filter CodexSteerLiveTests`
final class CodexSteerLiveTests: XCTestCase {
    func testFollowUpJoinsRunningTurn() async throws {
        guard ProcessInfo.processInfo.environment["BUDDYOS_LIVE_CODEX"] == "1" else {
            throw XCTSkip("BUDDYOS_LIVE_CODEX=1 のときだけ実行")
        }
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("codex-steer-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let session = await CodexHistoryAdapter().openSession(sessionId: nil, cwd: cwd.path)
        XCTAssertTrue(session.supportsMidTurnInjection)

        let collector = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            for try await e in session.events {
                out.append(e)
                if e.type == .done || e.type == .error { break }
            }
            return out
        }
        Task { await session.send("Write the numbers from 1 to 40, one per line, nothing else.", skills: [], attachments: []) }
        // 返事が流れ始めるまで待ってから、同じターンへ追加の指示を送る。
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 250_000_000)
            if collectorHasStarted(session) { break }
        }
        await session.send("After the numbers, write the word BANANA on its own line.", skills: [], attachments: [])
        let events = (try? await collector.value) ?? []
        let text = events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        print("LIVE steer tail:", text.suffix(120))
        print("LIVE steer errors:", events.filter { $0.type == .error }.compactMap(\.content))
        XCTAssertEqual(events.filter { $0.type == .done }.count, 1)
        XCTAssertTrue(text.contains("BANANA"), "追加の指示が同じターンで反映される")
        await session.close()
    }

    /// turn/start の応答（activeTurnId の確定）を待つ目安。delta が来たかは events を共有できないので時間で見る。
    private func collectorHasStarted(_ session: AgentSession) -> Bool {
        session.sessionId.hasPrefix("pending-") == false
    }
}
