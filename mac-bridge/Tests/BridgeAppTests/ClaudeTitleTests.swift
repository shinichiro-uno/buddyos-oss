import XCTest
@testable import BridgeApp

final class ClaudeTitleTests: XCTestCase {
    func testPrefersCustomThenLatestAi() {
        let ai = """
        {"type":"user","message":{"content":"hello"}}
        {"type":"ai-title","aiTitle":"古い題名","sessionId":"s"}
        {"type":"assistant","message":{}}
        {"type":"ai-title","aiTitle":"新しい題名","sessionId":"s"}
        """
        XCTAssertEqual(ClaudeCodeProjectsScanner.latestClaudeTitle(in: ai), "新しい題名")
        let both = ai + "\n{\"type\":\"custom-title\",\"customTitle\":\"手動の名前\",\"sessionId\":\"s\"}\n{\"type\":\"ai-title\",\"aiTitle\":\"さらに新しい\"}"
        XCTAssertEqual(ClaudeCodeProjectsScanner.latestClaudeTitle(in: both), "手動の名前", "/rename が優先")
        XCTAssertNil(ClaudeCodeProjectsScanner.latestClaudeTitle(in: "{\"type\":\"user\"}\n{\"type\":\"ai-title\",\"aiTitle\":\"  \"}"))
    }

    func testTailReadDropsPartialFirstLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = String(repeating: "x", count: 5000) + "\n{\"type\":\"ai-title\",\"aiTitle\":\"末尾\"}\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let tail = try XCTUnwrap(ClaudeCodeProjectsScanner.readTail(url: url, maxBytes: 200))
        XCTAssertEqual(ClaudeCodeProjectsScanner.latestClaudeTitle(in: tail), "末尾")
    }
}
