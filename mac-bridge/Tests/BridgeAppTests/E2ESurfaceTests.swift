import XCTest
@testable import BridgeApp

/// E2E surface (デバイス登録簿 / push token migration / b64url) のテスト
/// （spec/PROTOCOL-v3.md §14）。
/// 実ホームの ~/.buddyos を汚さないよう、ファイルは全て一時ディレクトリに置く。
final class E2ESurfaceTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-surface-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Base64URL

    func testBase64URLRoundTrip() {
        let data = Data((0..<32).map { UInt8($0) })
        let encoded = Base64URL.encode(data)
        // b64url: padding なし + URL-safe 文字のみ (QR に percent-encode なしで載せる前提)
        XCTAssertFalse(encoded.contains("="))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(Base64URL.decode(encoded), data)
    }

    func testBase64URLDecodeRejectsGarbage() {
        XCTAssertNil(Base64URL.decode("!!!not-base64!!!"))
    }

    // MARK: - push（v3。spec/PROTOCOL-v3.md §14.1・§15.6）
    // 旧 E2EDeviceStore（e2e-devices.json）と push_tokens.json は DeviceStore（devices.json）に置き換えた（DeviceStoreTests）。

    /// /v3/push の本文: token は 1 件、title / body を含めない（平文の本文を送らない）。
    func testRelayBodyCarriesNoPlaintext() throws {
        let box = PushService.E2EBox(v: 1, bid: "mac-bridge-1", kid: "0011223344556677", n: "bm9uY2U=", c: "Y2lwaGVy")
        let body = PushService.relayBody(token: String(repeating: "ab", count: 32), env: "development", locale: "en", box: box)
        XCTAssertEqual(body["token"] as? String, String(repeating: "ab", count: 32))
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertEqual(body["placeholder"] as? String, "en")
        XCTAssertNil(body["notification"])
        XCTAssertNil(body["tokens"])
        XCTAssertNil(body["title"])
        XCTAssertNil(body["body"])
        let e2e = try XCTUnwrap(body["e2e"] as? [String: Any])
        XCTAssertEqual(e2e["bid"] as? String, "mac-bridge-1")
        XCTAssertEqual(e2e["kid"] as? String, "0011223344556677")
    }

    /// 長い承認要求の本文でも、封をした `e2e.c` が Convex の上限（base64 で 4096 文字）に収まる。
    func testPlaintextIsBoundedForConvexPushLimit() throws {
        let payload = ["kind": "approval_request", "agentId": "claude", "sessionId": UUID().uuidString,
                       "requestId": UUID().uuidString, "bridgeId": "mac-bridge-" + String(repeating: "x", count: 60)]
        // JSON で 6 バイトに膨らむ制御文字と、4 バイトの絵文字で最悪に近い形にする。
        let plaintext = try XCTUnwrap(PushService.plaintext(
            title: String(repeating: "😀", count: 500), body: String(repeating: "\u{0001}", count: 5000), payload: payload))
        let sealed = try E2ECrypto.sealPush(plaintext: plaintext, key: Data(repeating: 7, count: 32))
        XCTAssertLessThanOrEqual(sealed.ciphertext.base64EncodedString().count, 4096)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertEqual((obj["title"] as? String)?.unicodeScalars.count, PushService.maxTitleScalars)
        XCTAssertEqual((obj["body"] as? String)?.unicodeScalars.count, PushService.maxBodyScalars)
        XCTAssertEqual(obj["payload"] as? [String: String], payload)
    }

    func testPlaceholdersAndTokenRules() {
        XCTAssertEqual(PushService.placeholder(locale: "ja").body, "新しい通知があります")
        XCTAssertEqual(PushService.placeholder(locale: "en").body, "You have a new notification")
        XCTAssertTrue(PushService.isValidToken(String(repeating: "a", count: 64)))
        XCTAssertFalse(PushService.isValidToken(String(repeating: "A", count: 64)), "小文字にしてから確かめる")
        XCTAssertFalse(PushService.isValidToken(String(repeating: "a", count: 63)))
        XCTAssertFalse(PushService.isValidToken(String(repeating: "a", count: 201)))
        XCTAssertEqual(PushService.tokenHash("ABCD"), PushService.tokenHash("abcd"))
        XCTAssertEqual(PushService.convexEnv("development"), "sandbox")
        XCTAssertEqual(PushService.convexEnv("production"), "production")
    }

    /// /v3/push-targets: 同じトークンは 1 件、20 件まで、tokenHash は小文字の 16 進の SHA-256。
    func testTargetsBody() throws {
        var pushes = (0..<25).map { DeviceStore.Push(token: String(format: "%064x", $0), env: "production", locale: "ja") }
        pushes.append(pushes[0])
        let body = PushService.targetsBody(pushes)
        let targets = try XCTUnwrap(body["targets"] as? [[String: String]])
        XCTAssertEqual(targets.count, 20)
        XCTAssertEqual(Set(targets.map { $0["tokenHash"]! }).count, 20)
        XCTAssertEqual(targets[0]["tokenHash"]?.count, 64)
    }
}
