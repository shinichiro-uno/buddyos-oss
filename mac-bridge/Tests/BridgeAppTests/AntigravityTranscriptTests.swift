import XCTest
@testable import BridgeApp

/// ターミナルで始めた agy の会話を、agy 自身の transcript.jsonl から読む。
final class AntigravityTranscriptTests: XCTestCase {
    func testParsesUserRequestsAndMergesResponses() {
        let lines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nfix the bug\n</USER_REQUEST>\n<ADDITIONAL_METADATA>cwd</ADDITIONAL_METADATA>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Looking at it.","tool_calls":[{"name":"view_file"}]}"#,
            #"{"step_index":2,"source":"MODEL","type":"GENERIC","status":"DONE","content":"Created At: …\nfile body"}"#,
            #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"edit"}]}"#,
            #"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"Fixed."}"#,
            #"{"step_index":5,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"internal"}"#,
            #"{"step_index":6,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"thanks"}"#,
        ].joined(separator: "\n")
        let messages = AntigravityTranscript.parse(lines, conversationId: "c")
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(messages[0].content, "fix the bug", "USER_REQUEST の中身だけ")
        XCTAssertEqual(messages[1].content, "Looking at it.\n\nFixed.", "道具の結果を除き、同じ返事の本文はまとめる")
        XCTAssertEqual(messages[2].content, "thanks", "タグが無ければ全体")
    }

    func testRejectsNonUUIDConversationId() {
        XCTAssertEqual(AntigravityTranscript.read(conversationId: "../../etc", root: "/tmp").count, 0)
    }
}
