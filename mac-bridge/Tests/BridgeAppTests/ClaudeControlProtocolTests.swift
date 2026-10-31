import XCTest
@testable import BridgeApp

/// Claude Code の制御プロトコル（承認・質問）と画像ブロックの変換。実 claude は使わない。
/// 入力の JSON は実機（claude 2.1.285、2026-10-01）の stdout をそのまま使っている。
final class ClaudeControlProtocolTests: XCTestCase {

    private let bashRequest = """
    {"type":"control_request","request_id":"dd7e27d0-8478-4460-8fae-933cd8ac6b90","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"echo approved > approved.txt","description":"Write approved"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"echo approved *"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/tmp/x"],"destination":"session"}],"tool_use_id":"toolu_1"}}
    """

    func testParsesCanUseToolRequest() throws {
        guard case .canUseTool(let r)? = ClaudeControlProtocol.parse(bashRequest) else {
            return XCTFail("can_use_tool として読めない")
        }
        XCTAssertEqual(r.requestId, "dd7e27d0-8478-4460-8fae-933cd8ac6b90")
        XCTAssertEqual(r.toolName, "Bash")
        XCTAssertEqual(r.input["command"] as? String, "echo approved > approved.txt")
        XCTAssertEqual(r.suggestions.count, 2)
    }

    func testOrdinaryLinesAreNotControl() {
        XCTAssertNil(ClaudeControlProtocol.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#))
        // 本文にその語が出ても制御行にはならない
        XCTAssertNil(ClaudeControlProtocol.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"the control_request type"}]}}"#))
        XCTAssertNil(ClaudeControlProtocol.parse("not json"))
    }

    func testParsesCancelAndUnsupported() {
        guard case .cancel(let id)? = ClaudeControlProtocol.parse(#"{"type":"control_cancel_request","request_id":"r1"}"#) else {
            return XCTFail("cancel として読めない")
        }
        XCTAssertEqual(id, "r1")
        guard case .unsupported(let id2, let sub)? = ClaudeControlProtocol.parse(
            #"{"type":"control_request","request_id":"r2","request":{"subtype":"hook_callback"}}"#) else {
            return XCTFail("unsupported として読めない")
        }
        XCTAssertEqual(id2, "r2")
        XCTAssertEqual(sub, "hook_callback")
    }

    func testApprovalCardOffersSessionOptionOnlyWhenClaudeSuggestsIt() throws {
        guard case .canUseTool(let withSuggestions)? = ClaudeControlProtocol.parse(bashRequest) else { return XCTFail() }
        let card = ClaudeControlProtocol.approvalCard(withSuggestions, agentId: "claude", sessionId: "s")
        let m = try XCTUnwrap(card.metadata)
        XCTAssertEqual(m["kind"], "approval")
        XCTAssertEqual(m["option_count"], "3")
        XCTAssertEqual([m["option_0_value"], m["option_1_value"], m["option_2_value"]], ["allow", "allowForSession", "deny"])
        XCTAssertEqual(m["requestId"], withSuggestions.requestId)
        XCTAssertEqual(card.messageId, withSuggestions.requestId)
        XCTAssertEqual(m["subtitle"], "echo approved > approved.txt")

        let bare = ClaudeControlProtocol.ToolRequest(requestId: "r", toolName: "Bash", input: ["command": "ls"], suggestions: [])
        let m2 = try XCTUnwrap(ClaudeControlProtocol.approvalCard(bare, agentId: "claude", sessionId: "s").metadata)
        XCTAssertEqual(m2["option_count"], "2")
        XCTAssertEqual([m2["option_0_value"], m2["option_1_value"]], ["allow", "deny"])
    }

    func testQuestionCardAndAnswers() throws {
        let input: [String: Any] = ["questions": [[
            "question": "どちらにしますか？", "header": "方式",
            "options": [["label": "A", "description": "速い"], ["label": "B", "description": "安全"]],
        ]]]
        let r = ClaudeControlProtocol.ToolRequest(requestId: "q1", toolName: "AskUserQuestion", input: input, suggestions: [])
        let card = try XCTUnwrap(ClaudeControlProtocol.questionCard(r, agentId: "claude", sessionId: "s"))
        let m = try XCTUnwrap(card.metadata)
        XCTAssertEqual(m["kind"], "userInput")
        XCTAssertEqual(m["option_count"], "2")
        XCTAssertEqual(m["option_1_value"], "B")
        XCTAssertEqual(m["allowsOther"], "1")
        XCTAssertEqual(m["title"], "方式")

        let qs = ClaudeControlProtocol.questions(in: input)
        XCTAssertEqual(ClaudeControlProtocol.answers(for: qs, decision: "A", explicit: [:]), ["どちらにしますか？": "A"])
        XCTAssertEqual(ClaudeControlProtocol.answers(for: qs, decision: "A", explicit: ["どちらにしますか？": "自由記述"]),
                       ["どちらにしますか？": "自由記述"])
    }

    func testResponsesHaveTheWireShapeClaudeExpects() throws {
        let allow = ClaudeControlProtocol.allowResponse(requestId: "r", input: ["command": "ls"])
        let body = try XCTUnwrap((allow["response"] as? [String: Any])?["response"] as? [String: Any])
        XCTAssertEqual(allow["type"] as? String, "control_response")
        XCTAssertEqual((allow["response"] as? [String: Any])?["subtype"] as? String, "success")
        XCTAssertEqual((allow["response"] as? [String: Any])?["request_id"] as? String, "r")
        XCTAssertEqual(body["behavior"] as? String, "allow")
        XCTAssertEqual((body["updatedInput"] as? [String: Any])?["command"] as? String, "ls")
        XCTAssertNil(body["updatedPermissions"])

        let deny = ClaudeControlProtocol.denyResponse(requestId: "r", message: "no")
        let denyBody = try XCTUnwrap((deny["response"] as? [String: Any])?["response"] as? [String: Any])
        XCTAssertEqual(denyBody["behavior"] as? String, "deny")
        XCTAssertEqual(denyBody["message"] as? String, "no")

        let err = ClaudeControlProtocol.errorResponse(requestId: "r", message: "x")
        XCTAssertEqual((err["response"] as? [String: Any])?["subtype"] as? String, "error")
    }

    func testSessionScopedRewritesDestination() {
        let scoped = ClaudeControlProtocol.sessionScoped([
            ["type": "addRules", "behavior": "allow", "destination": "localSettings"],
            ["type": "addDirectories", "destination": "session"],
        ])
        XCTAssertEqual(scoped.map { $0["destination"] as? String }, ["session", "session"])
        // 元の候補の他の項目は保たれる
        XCTAssertEqual(scoped[0]["type"] as? String, "addRules")
    }

    func testSummaryPerTool() {
        XCTAssertEqual(ClaudeControlProtocol.summary(toolName: "Bash", input: ["command": "ls -la"]), "ls -la")
        XCTAssertEqual(ClaudeControlProtocol.summary(toolName: "Write", input: ["file_path": "/a/b.txt", "content": "x"]), "/a/b.txt")
        XCTAssertEqual(ClaudeControlProtocol.summary(toolName: "WebFetch", input: ["url": "https://e.com"]), "https://e.com")
        let long = String(repeating: "a", count: 500)
        let s = ClaudeControlProtocol.summary(toolName: "Bash", input: ["command": long])
        XCTAssertEqual(s.count, 301)
        XCTAssertTrue(s.hasSuffix("…"))
    }

    // MARK: - 画像

    func testImageBlocksCarryTheRealBytes() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let png = BridgeAttachment(kind: .image, name: "a.png", mime: "image/png", data: bytes)
        let jpg = BridgeAttachment(kind: .image, name: "b.jpg", mime: "image/jpg", data: Data([0xFF, 0xD8]))
        let heic = BridgeAttachment(kind: .image, name: "c.heic", mime: "image/heic", data: Data([1]))
        let file = BridgeAttachment(kind: .file, name: "n.txt", mime: "text/plain", data: Data("x".utf8))

        let inline = ClaudeCodeSession.inlineImages([png, jpg, heic, file])
        XCTAssertEqual(inline.map(\.name), ["a.png", "b.jpg"], "Claude が受け付けない形式（heic）とファイルは対象外")

        let blocks = ClaudeCodeSession.contentBlocks(text: "これは何？", images: inline)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0]["type"] as? String, "image", "画像が先")
        let src = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        XCTAssertEqual(src["type"] as? String, "base64")
        XCTAssertEqual(src["media_type"] as? String, "image/png")
        XCTAssertEqual(src["data"] as? String, bytes.base64EncodedString())
        XCTAssertEqual((blocks[1]["source"] as? [String: Any])?["media_type"] as? String, "image/jpeg", "image/jpg は image/jpeg に正規化")
        XCTAssertEqual(blocks[2]["type"] as? String, "text")
        XCTAssertEqual(blocks[2]["text"] as? String, "これは何？")
    }

    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// プロセスを起こした直後の宣言と、行を 1 つ止める要求（1 行の JSON）。
    func testInitializeAndStopTaskRequests() throws {
        XCTAssertEqual(
            try line(ClaudeControlProtocol.initializeRequest(requestId: "r1")),
            #"{"request":{"perTaskStopAffordance":true,"subtype":"initialize"},"request_id":"r1","type":"control_request"}"#)
        XCTAssertEqual(
            try line(ClaudeControlProtocol.stopTaskRequest(requestId: "r2", taskId: "br1svjoeb")),
            #"{"request":{"subtype":"stop_task","task_id":"br1svjoeb"},"request_id":"r2","type":"control_request"}"#)
    }
}
