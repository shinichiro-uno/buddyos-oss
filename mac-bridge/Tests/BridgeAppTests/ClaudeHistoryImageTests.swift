import XCTest
@testable import BridgeApp

final class ClaudeHistoryImageTests: XCTestCase {
    func testUserImageBlocksBecomeAttachments() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "これ見て [Image #2]"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": "AAAA"]],
            ["type": "image", "source": ["type": "url", "url": "https://example.com/a.png"]]
        ]
        let images = ClaudeCodeProjectsScanner.imageAttachments(from: content)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images.first?.mime, "image/jpeg")
        XCTAssertEqual(images.first?.name, "image-1.jpeg")
        XCTAssertEqual(images.first?.b64, "AAAA")
    }

    func testOversizedAndNonArrayContentAreSkipped() {
        let huge = String(repeating: "A", count: ClaudeCodeProjectsScanner.maxHistoryImageB64 + 1)
        let content: [[String: Any]] = [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": huge]]
        ]
        XCTAssertTrue(ClaudeCodeProjectsScanner.imageAttachments(from: content).isEmpty)
        XCTAssertTrue(ClaudeCodeProjectsScanner.imageAttachments(from: "plain text").isEmpty)
    }
}
