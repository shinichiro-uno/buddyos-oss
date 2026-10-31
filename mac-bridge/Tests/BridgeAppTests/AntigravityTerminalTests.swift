import XCTest
@testable import BridgeApp

/// ターミナルの agy の会話を流す（記録の追いかけ）と、送る（受け取り箱）。
final class AntigravityTerminalTests: XCTestCase {
    func testEventsFromTranscriptLines() {
        func ev(_ json: String) -> [AntigravityTerminalMirror.Event] {
            AntigravityTerminalMirror.events(fromLine: Data(json.utf8))
        }
        XCTAssertEqual(ev(#"{"type":"USER_INPUT","content":"<USER_REQUEST>\nhi\n</USER_REQUEST>"}"#), [.user("hi")])
        XCTAssertEqual(ev(#"{"type":"PLANNER_RESPONSE","content":"Reading.","tool_calls":[{"name":"view_file"}]}"#),
                       [.assistant("Reading."), .toolStart("view_file")])
        XCTAssertEqual(ev(#"{"type":"GENERIC","content":"result"}"#), [.toolEnd])
        XCTAssertEqual(ev(#"{"type":"PLANNER_RESPONSE","content":"Done."}"#), [.assistant("Done."), .turnEnd], "道具を呼ばない返事でターンが終わる")
    }

    func testMirrorOnlyStreamsAppendedLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-mirror-\(UUID().uuidString.prefix(6))").path
        let cid = UUID().uuidString.lowercased()
        let path = AntigravityTranscript.path(conversationId: cid, root: root)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try (#"{"type":"USER_INPUT","content":"old"}"# + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        var seen: [AntigravityTerminalMirror.Event] = []
        let mirror = AntigravityTerminalMirror(conversationId: cid, root: root) { seen.append($0) }
        mirror.start(interval: 3600)
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data((#"{"type":"USER_INPUT","content":"new"}"# + "\n" + #"{"type":"PLANNER_RESPONSE","content":"ok"#).utf8))
        mirror.poll()
        XCTAssertEqual(seen, [.user("new")], "開く前の分は流さず、書きかけの行は待つ")
        handle.write(Data(("\"}" + "\n").utf8))
        try handle.close()
        mirror.poll()
        mirror.stop()
        XCTAssertEqual(seen, [.user("new"), .assistant("ok"), .turnEnd])
    }

    func testInboxQueuesStepsInOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-inbox-\(UUID().uuidString.prefix(6))").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let cid = UUID().uuidString.lowercased()
        try AgyInbox.enqueue(conversationId: cid, text: "first", directory: dir)
        try AgyInbox.enqueue(conversationId: cid, text: "second", directory: dir)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/\(cid).json"))) as? [String: Any]
        let steps = obj?["injectSteps"] as? [[String: String]]
        XCTAssertEqual(steps?.compactMap { $0["userMessage"] }, ["first", "second"], "hook の出力の形でそのまま並ぶ")
        try AgyInbox.enqueue(conversationId: "../evil", text: "x", directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/../evil.json"), "会話 ID の形でなければ書かない")
    }
}
