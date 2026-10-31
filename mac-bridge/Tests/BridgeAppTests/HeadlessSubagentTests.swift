import XCTest
@testable import BridgeApp

/// headless の cursor（BUDDYOS_CURSOR_HEADLESS=1。1 ターン 1 プロセス）のサブエージェントの行。
/// トラッカーはセッションに 1 つ持ち（index と epoch をターンの間で続ける）、プロセスが終わったら実行中の行を閉じる
/// （正常に終わった・止めたなら stopped、異常終了なら failed）。docs/BACKGROUND_WORK_2026-10-21.md §3.6。
final class HeadlessSubagentTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        setenv("BUDDYOS_CURSOR_HEADLESS", "1", 1)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-subagent-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("BUDDYOS_CURSOR_HEADLESS")
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Task の tool_use を出したまま、tool_result を出さずに終わるフェイク cursor。1 回目は exit 0、2 回目は exit 3。
    private func writeFakeCursor() throws -> String {
        let chatId = "01234567-89ab-cdef-0123-456789abcdef"
        let counter = tempDir.appendingPathComponent("count").path
        let url = tempDir.appendingPathComponent("fake-cursor-task.sh")
        let body = """
        #!/bin/bash
        n=$(cat '\(counter)' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(counter)'
        echo '{"type":"system","subtype":"init","sessionId":"\(chatId)","model":"auto"}'
        echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_'$n'","name":"Task","input":{"description":"Explore auth '$n'","subagent_type":"explore"}}]},"session_id":"\(chatId)"}'
        if [ "$n" = "1" ]; then
          echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]},"session_id":"\(chatId)"}'
          echo '{"type":"result","subtype":"success","result":"ok","session_id":"\(chatId)"}'
          exit 0
        fi
        echo "boom" >&2
        exit 3
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func payloads(_ events: [SessionEvent]) -> [[String: Any]] {
        events.filter { $0.type == .workflowProgress }.compactMap { e in
            e.content.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
    }

    func testRowsCloseAtEveryEndingAndTrackerSpansTurns() async throws {
        let adapter = HeadlessCliAdapter(profile: .cursor, executable: try writeFakeCursor())
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let collector = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            var dones = 0
            for try await e in session.events {
                out.append(e)
                if e.type == .done { dones += 1; if dones == 2 { break } }
            }
            return out
        }
        await session.send("one", skills: [], attachments: [])
        await session.send("two", skills: [], attachments: [])
        let events = (try? await collector.value) ?? []
        let snapshot = await (session as? HeadlessCliSession)?.subagentSnapshot()
        await session.close()

        let doneIdx = events.indices.filter { events[$0].type == .done }
        guard doneIdx.count == 2 else { return XCTFail("done は 2 回: \(doneIdx.count)") }
        let all = payloads(events)
        let rows = all.flatMap { ($0["agents"] as? [[String: Any]]) ?? [] }
        let first = rows.filter { $0["id"] as? String == "tu_1" }
        let second = rows.filter { $0["id"] as? String == "tu_2" }
        XCTAssertEqual(first.first?["state"] as? String, "running")
        XCTAssertEqual(first.last?["state"] as? String, "stopped", "正常に終わったプロセスの実行中の行は stopped: \(first)")
        XCTAssertEqual(second.last?["state"] as? String, "failed", "異常終了の行は failed: \(second)")
        XCTAssertEqual(first.first?["index"] as? Int, 0)
        XCTAssertEqual(second.first?["index"] as? Int, 1, "index はターンの間で続ける")
        XCTAssertEqual(Set(all.compactMap { $0["epoch"] as? String }).count, 1, "トラッカーはセッションに 1 つ")

        // 行を閉じてから done（error）を出す。
        let lastFirst = events.lastIndex { $0.type == .workflowProgress && $0.content?.contains("\"tu_1\"") == true } ?? 0
        XCTAssertLessThan(lastFirst, doneIdx[0])

        // 2 回目の送信で、1 回目の終わった行は忘れている。
        let snap = snapshot.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let snapIds = ((snap?["agents"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        XCTAssertEqual(snap?["subtype"] as? String, "workflow_snapshot")
        XCTAssertEqual(snapIds, ["tu_2"])
    }
}
