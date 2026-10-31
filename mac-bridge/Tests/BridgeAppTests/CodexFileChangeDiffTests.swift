import XCTest
@testable import BridgeApp

final class CodexFileChangeDiffTests: XCTestCase {
    func testTitleAndJson() throws {
        let item: [String: Any] = ["changes": [
            ["path": "/repo/a.swift", "kind": ["type": "update"], "diff": "@@ -1 +1 @@\n-old\n+new\n"],
            ["path": "/repo/b.swift", "kind": ["type": "add"], "diff": "+hello\n"],
        ]]
        XCTAssertEqual(CodexFileChangeDiff.title(item), "ファイル変更: a.swift, b.swift")
        let json = try XCTUnwrap(CodexFileChangeDiff.json(item))
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0]["path"] as? String, "/repo/a.swift")
        XCTAssertEqual(arr[0]["kind"] as? String, "update")
        XCTAssertEqual(arr[1]["kind"] as? String, "add")
        XCTAssertNil(CodexFileChangeDiff.json(["changes": [Any]()]))
    }

    func testTruncatesLargeDiffs() throws {
        let big = String(repeating: "+x\n", count: 30_000)
        let json = try XCTUnwrap(CodexFileChangeDiff.json(["changes": [["path": "a", "diff": big], ["path": "b", "diff": big]]]))
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let total = arr.compactMap { ($0["diff"] as? String)?.count }.reduce(0, +)
        XCTAssertLessThanOrEqual(total, CodexFileChangeDiff.maxTotal)
        XCTAssertEqual(arr.first?["truncated"] as? Bool, true)
    }

    func testAddingMetadataKeepsFields() {
        let e = SessionEvent.toolStart(agentId: "codex", sessionId: "s", toolUseId: "t", toolName: "file_change", title: "x", kind: "edit")
            .addingMetadata(["diff": "[]"])
        XCTAssertEqual(e.metadata?["kind"], "edit")
        XCTAssertEqual(e.metadata?["diff"], "[]")
        XCTAssertEqual(e.toolUseId, "t")
    }
}
