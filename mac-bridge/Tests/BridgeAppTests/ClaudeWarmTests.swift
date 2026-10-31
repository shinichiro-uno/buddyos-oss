import XCTest
@testable import BridgeApp

/// チャットを開いたときの session_warm（ClaudeCodeSession.warm）。偽物の claude で、送る前に
/// プロセスを 1 本だけ起こし、SessionStart の hook の行で session を確定させないことを確かめる。
/// 送信は試さない（warm の確認に必要なのは起動まで）。
final class ClaudeWarmTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        unsetenv("FAKE_CLAUDE_STARTS")
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// 起動のたびに 1 行書き、起動直後に hook の行を出して stdin を待つ偽物の claude。
    private func fakeClaude() throws -> String {
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        echo start >> "$FAKE_CLAUDE_STARTS"
        echo '{"type":"system","subtype":"hook_started","hook_event":"SessionStart","session_id":"11111111-1111-4111-8111-111111111111"}'
        while IFS= read -r line; do :; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func starts(_ file: URL) -> Int {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    func testWarmStartsOnceAndDoesNotStartTheSession() async throws {
        let count = dir.appendingPathComponent("starts")
        setenv("FAKE_CLAUDE_STARTS", count.path, 1)
        let session = ClaudeCodeSession(
            agentId: "fake-warm", profile: .claude, initialSessionId: nil, cwd: dir.path,
            executable: try fakeClaude(), store: .shared)
        let seen = WarmEventLog()
        let events = session.events
        let pump = Task { do { for try await e in events { await seen.add(e) } } catch {} }

        await session.warm()
        await session.warm()
        // 偽物が hook の行を出し終えるまで待つ。
        for _ in 0..<50 where starts(count) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(starts(count), 1, "2 回呼んでも起動は 1 本")
        let types = await seen.types()
        XCTAssertFalse(types.contains(.sessionStarted), "送る前の hook の行では session を確定させない")
        XCTAssertTrue(session.sessionId.hasPrefix("pending-"), "ID も hook の行のものにしない")

        await session.close()
        pump.cancel()
    }

    func testHookLine() {
        XCTAssertTrue(ClaudeCodeSession.isHookLine(#"{"type":"system","subtype":"hook_started","session_id":"x"}"#))
        XCTAssertTrue(ClaudeCodeSession.isHookLine(#"{"type":"system","subtype":"hook_response","session_id":"x"}"#))
        XCTAssertFalse(ClaudeCodeSession.isHookLine(#"{"type":"system","subtype":"init","session_id":"x"}"#))
        XCTAssertFalse(ClaudeCodeSession.isHookLine(#"{"type":"assistant","message":{"content":"hook_started"}}"#))
    }
}

private actor WarmEventLog {
    private var events: [SessionEvent] = []
    func add(_ e: SessionEvent) { events.append(e) }
    func types() -> [SessionEventType] { events.map(\.type) }
}
