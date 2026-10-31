import XCTest
@testable import BridgeApp

/// ターミナルの Claude Code（cross-session の受け箱・channel）へ送る本文の添付の書き方。
/// 本文しか届かないので、画像は書き出したファイルのパスを添える（以前は目印だけで中身が落ちていた）。
final class ClaudeTerminalAttachmentTests: XCTestCase {
    func testImageCarriesExportedFilePath() {
        let image = BridgeAttachment(kind: .image, name: "shot.jpg", mime: "image/jpeg", data: Data(count: 3))
        let file = URL(fileURLWithPath: "/tmp/buddyos-test/shot.jpg")
        let prompt = ClaudeTerminalSession.promptText(text: "これ見て", skills: [], attachments: [image], files: [file])
        XCTAssertEqual(prompt, """
        [image "shot.jpg" attached: image/jpeg, 3 bytes] (file: /tmp/buddyos-test/shot.jpg — open this file to see the image)

        これ見て
        """)
    }

    func testImageWithoutFileKeepsPlaceholderOnly() {
        let image = BridgeAttachment(kind: .image, name: "shot.jpg", mime: "image/jpeg", data: Data(count: 3))
        let prompt = ClaudeTerminalSession.promptText(text: "", skills: [], attachments: [image], files: [nil])
        XCTAssertEqual(prompt, "[image \"shot.jpg\" attached: image/jpeg, 3 bytes]")
    }

    /// 履歴では「(file: …)」ごと消えて実画像に戻る（WebSocketServer.enrichHistory の正規表現に合う形）。
    func testPathSuffixMatchesHistoryPattern() throws {
        let image = BridgeAttachment(kind: .image, name: "a.png", mime: "image/png", data: Data(count: 1))
        let prompt = ClaudeTerminalSession.promptText(text: "x", skills: [], attachments: [image],
                                                      files: [URL(fileURLWithPath: "/tmp/a.png")])
        let regex = try NSRegularExpression(pattern: #"\[image "([^"]+)" attached: ([^,]+), (\d+) bytes\](?: \(file: [^)\n]*\))?"#)
        let stripped = regex.stringByReplacingMatches(in: prompt, range: NSRange(location: 0, length: (prompt as NSString).length), withTemplate: "")
        XCTAssertEqual(stripped.trimmingCharacters(in: .whitespacesAndNewlines), "x")
    }
}
