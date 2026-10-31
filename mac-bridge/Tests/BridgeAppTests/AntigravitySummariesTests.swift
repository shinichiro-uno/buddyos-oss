import XCTest
@testable import BridgeApp

final class AntigravitySummariesTests: XCTestCase {
    func testWorkspaceFromJson() {
        XCTAssertEqual(AntigravitySummaries.firstWorkspace(#"["file:///tmp/agytest"]"#), "/tmp/agytest")
        XCTAssertNil(AntigravitySummaries.firstWorkspace(#"["file:///"]"#), "ルートは場所として使わない")
        XCTAssertNil(AntigravitySummaries.firstWorkspace("not json"))
    }

    func testReadsRealDatabaseShape() throws {
        let path = NSTemporaryDirectory() + "sum-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = Process()
        r.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        r.arguments = [path, "create table conversation_summaries(conversation_id text, title text, preview text, workspace_uris text);" +
            "insert into conversation_summaries values('c1','自動の題名','最初の発言','[\"file:///work/x\"]'),('c2','','preview only','[]');"]
        try r.run(); r.waitUntilExit()
        let m = AntigravitySummaries.read(path: path)
        XCTAssertEqual(m["c1"], .init(title: "自動の題名", preview: "最初の発言", cwd: "/work/x"))
        XCTAssertEqual(m["c2"]?.title, "")
        XCTAssertEqual(m["c2"]?.preview, "preview only")
        XCTAssertTrue(AntigravitySummaries.read(path: "/nonexistent.db").isEmpty)
    }
}
