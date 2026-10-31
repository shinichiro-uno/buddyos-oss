import XCTest
@testable import BridgeApp

/// list_sessions の各項目に、ターンの後もバックグラウンドで作業が動いている session だけ background を載せる
/// （running / awaiting と同じく metadata の "1"。docs/BACKGROUND_WORK_2026-10-21.md §3.5）。
/// 接続は SessionProtocolTests の TestConnection（本番と同じ WebSocketServer.bindSession の配線）。
final class SessionListBackgroundTests: XCTestCase {
    private func uniq(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())" }

    func testListSessionsMarksSessionsWithBackgroundWork() async throws {
        let agent = uniq("bglist")
        let busy = uniq("busy")
        let quiet = uniq("quiet")
        let adapter = BackgroundWorkAdapter(id: agent)
        adapter.listed = [
            SessionSummary(sessionId: busy, title: "busy", lastActive: "", messageCount: nil, cwd: nil),
            SessionSummary(sessionId: quiet, title: "quiet", lastActive: "", messageCount: nil, cwd: nil),
        ]
        let client = await TestConnection.open(adapter, sessionId: busy)
        let session = try XCTUnwrap(adapter.sessions.first)
        session.track { $0.begin(key: "a1", label: "調査", background: true) }
        try await client.until("row") { $0.type == .workflowProgress && $0.content?.contains("\"a1\"") == true }

        client.clear()
        await client.send(["type": "list_sessions_request", "agentId": agent])
        try await client.until("list end") { $0.type == .sessionListEnd }
        let items = client.events.filter { $0.type == .sessionListItem }
        XCTAssertEqual(items.first { $0.sessionId == busy }?.metadata?["background"], "1")
        XCTAssertNil(items.first { $0.sessionId == busy }?.metadata?["running"], "バックグラウンドの作業は running とは別")
        XCTAssertNil(items.first { $0.sessionId == quiet }?.metadata?["background"])

        // 後片付け: 作業を終わらせてから離れる（動いている間は hub が閉じない）。
        session.track { $0.finish(key: "a1", state: "done", result: nil) }
        try await client.until("row done") { $0.type == .workflowProgress && $0.content?.contains("\"done\"") == true }
        await client.close()
    }
}
