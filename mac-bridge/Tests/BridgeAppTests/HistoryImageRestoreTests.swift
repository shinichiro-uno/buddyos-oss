import XCTest
@testable import BridgeApp

/// 履歴の画像復元（Claude placeholder → 実画像）と AttachmentStore 往復の検証。
final class HistoryImageRestoreTests: XCTestCase {

    func testEnrichRestoresClaudePlaceholderImage() async throws {
        let bytes = Data((0..<64).map { UInt8($0) })
        let name = "img-\(UUID().uuidString).jpg"
        let mime = "image/jpeg"
        await AttachmentStore.shared.put(name: name, mime: mime, data: bytes)

        let content = "これ見て\n\n[image \"\(name)\" attached: \(mime), \(bytes.count) bytes]"
        let m = HistoryMessage(role: "user", content: content, messageId: "m1")
        let enriched = await WebSocketServer.enrichHistory(message: m)

        XCTAssertEqual(enriched.attachments.count, 1)
        XCTAssertEqual(enriched.attachments.first?.kind, "image")
        XCTAssertEqual(enriched.attachments.first?.mime, mime)
        XCTAssertEqual(enriched.attachments.first?.b64, bytes.base64EncodedString())
        // placeholder 行は本文から除かれ、ユーザーが打った文だけ残る。
        XCTAssertEqual(enriched.content, "これ見て")
    }

    func testEnrichLeavesUnknownPlaceholderUntouched() async {
        // 保管が無い placeholder は復元できない → 本文は壊さずそのまま。
        let content = "[image \"missing-\(UUID().uuidString).jpg\" attached: image/jpeg, 9999 bytes]"
        let m = HistoryMessage(role: "user", content: content, messageId: "m2")
        let enriched = await WebSocketServer.enrichHistory(message: m)
        XCTAssertTrue(enriched.attachments.isEmpty)
        XCTAssertEqual(enriched.content, content)
    }

    func testEnrichRestoresMultipleImages() async {
        // Codex は 1 メッセージに複数画像を添付できる。すべて復元され本文はテキストだけ残る。
        let a = Data((0..<32).map { UInt8($0) })
        let b = Data((40..<90).map { UInt8($0) })
        let nameA = "a-\(UUID().uuidString).png"
        let nameB = "b-\(UUID().uuidString).jpg"
        await AttachmentStore.shared.put(name: nameA, mime: "image/png", data: a)
        await AttachmentStore.shared.put(name: nameB, mime: "image/jpeg", data: b)

        let content = """
        [image "\(nameA)" attached: image/png, \(a.count) bytes]

        [image "\(nameB)" attached: image/jpeg, \(b.count) bytes]

        2枚あるよ
        """
        let enriched = await WebSocketServer.enrichHistory(
            message: HistoryMessage(role: "user", content: content, messageId: "multi")
        )
        XCTAssertEqual(enriched.attachments.count, 2)
        XCTAssertEqual(enriched.content, "2枚あるよ")
    }

    func testEnrichImageOnlyMessageBecomesEmptyText() async {
        let bytes = Data((0..<48).map { UInt8($0) })
        let name = "only-\(UUID().uuidString).jpg"
        await AttachmentStore.shared.put(name: name, mime: "image/jpeg", data: bytes)
        let content = "[image \"\(name)\" attached: image/jpeg, \(bytes.count) bytes]"
        let enriched = await WebSocketServer.enrichHistory(
            message: HistoryMessage(role: "user", content: content, messageId: "only")
        )
        XCTAssertEqual(enriched.attachments.count, 1)
        XCTAssertEqual(enriched.content, "")
    }

    func testEnrichKeepsExistingAttachments() async {
        // opencode の実画像 replay 等で既に attachments を持つメッセージは触らない。
        let att = HistoryAttachment(kind: "image", name: "x", mime: "image/png", b64: "AAEC")
        let m = HistoryMessage(role: "assistant", content: "図です", messageId: "m3", attachments: [att])
        let enriched = await WebSocketServer.enrichHistory(message: m)
        XCTAssertEqual(enriched.attachments.count, 1)
        XCTAssertEqual(enriched.content, "図です")
    }

    func testAttachmentStoreRoundTrip() async {
        let bytes = Data((0..<128).map { _ in UInt8.random(in: 0...255) })
        let name = "rt-\(UUID().uuidString).png"
        let mime = "image/png"
        await AttachmentStore.shared.put(name: name, mime: mime, data: bytes)
        let got = await AttachmentStore.shared.lookup(name: name, byteCount: bytes.count, mime: mime)
        XCTAssertEqual(got, bytes)
        // 別サイズでは引けない（キーに byteCount を含むため）。
        let miss = await AttachmentStore.shared.lookup(name: name, byteCount: bytes.count + 1, mime: mime)
        XCTAssertNil(miss)
    }
}
