import XCTest
@testable import BridgeApp

/// ClaudeCodeAdapter.resolveSessionCwd の解決順を検証する。
/// cwd 未指定セッションが bridge プロセスの cwd（インストール版ではアプリバンドル内）に
/// 落ちて `/resume` から見えなくなる問題の再発防止。
final class ClaudeSessionCwdTests: XCTestCase {

    func testExplicitCwdWins() async {
        let resolved = await ClaudeCodeAdapter.resolveSessionCwd("/tmp/proj", resumingSessionId: nil)
        XCTAssertEqual(resolved, "/tmp/proj")
    }

    func testTildeIsExpanded() async {
        let resolved = await ClaudeCodeAdapter.resolveSessionCwd("~/develope", resumingSessionId: nil)
        XCTAssertEqual(resolved, (NSHomeDirectory() as NSString).appendingPathComponent("develope"))
    }

    func testNilCwdNewSessionFallsBackToHome() async {
        let resolved = await ClaudeCodeAdapter.resolveSessionCwd(nil, resumingSessionId: nil)
        XCTAssertEqual(resolved, NSHomeDirectory())
    }

    func testNilCwdResumeOfUnknownSessionFallsBackToHome() async {
        // transcript が存在しない UUID → scanner 逆引きは失敗し home に落ちる。
        let resolved = await ClaudeCodeAdapter.resolveSessionCwd(
            nil, resumingSessionId: "00000000-0000-4000-8000-000000000000"
        )
        XCTAssertEqual(resolved, NSHomeDirectory())
    }

    func testNilCwdResumeUsesTranscriptRecordedCwd() async throws {
        // ~/.claude/projects/<slug>/<uuid>.jsonl に cwd 記録付きの transcript を置き、
        // scanner 逆引きでその cwd が返ることを確認する。実 HOME を汚すため
        // 終了時に必ず削除する（既存 slug と衝突しないランダム名を使う）。
        let sessionId = UUID().uuidString.lowercased()
        let slug = "buddyos-tests-\(UUID().uuidString.prefix(8))"
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcript = """
        {"type":"queue-operation","operation":"enqueue","sessionId":"\(sessionId)"}
        {"type":"user","cwd":"/tmp/recorded-project","message":{"content":"hello"}}
        """
        try transcript.write(
            to: dir.appendingPathComponent("\(sessionId).jsonl"),
            atomically: true, encoding: .utf8
        )

        let resolved = await ClaudeCodeAdapter.resolveSessionCwd(nil, resumingSessionId: sessionId)
        XCTAssertEqual(resolved, "/tmp/recorded-project")
    }
}
