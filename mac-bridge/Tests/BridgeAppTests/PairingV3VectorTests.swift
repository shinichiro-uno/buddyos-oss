import XCTest
@testable import BridgeApp

/// ペアリングまわりの規則を shared/e2e-test-vectors.json の pairingV3 で確かめる（spec/PROTOCOL-v3.md §18）。
final class PairingV3VectorTests: XCTestCase {
    private var pv: [String: Any] = [:]

    override func setUpWithError() throws {
        pv = try V3Vectors.pairing()
    }

    func testNameSanitize() throws {
        let ns = try XCTUnwrap(pv["nameSanitize"] as? [String: Any])
        let fallback = try XCTUnwrap(ns["deviceFallback"] as? String)
        XCTAssertEqual(fallback, TunnelV3.deviceNameFallback)
        XCTAssertEqual(ns["bridgeFallback"] as? String, TunnelV3.bridgeNameFallback)
        for c in try XCTUnwrap(ns["cases"] as? [[String: String]]) {
            XCTAssertEqual(TunnelV3.sanitizeName(c["in"]!, fallback: fallback), c["out"]!, "in=\(c["in"]!.debugDescription)")
        }
    }

    func testDisplayName() throws {
        for d in try XCTUnwrap(pv["displayName"] as? [[String: String]]) {
            XCTAssertEqual(TunnelV3.displayName(name: d["name"]!, deviceKeyId: d["deviceKeyId"]!), d["display"]!)
        }
    }

    func testStrictB64u() throws {
        for b in try XCTUnwrap(pv["b64u"] as? [[String: Any]]) {
            let input = try XCTUnwrap(b["in"] as? String)
            let out = TunnelV3.b64uDecodeStrict(input)
            if let hex = b["hex"] as? String {
                XCTAssertEqual(out?.v3hex, hex, "in=\(input)")
            } else {
                XCTAssertNil(out, "in=\(input) は拒否する")
            }
        }
        // 長さの指定（鍵 32 バイト）。
        XCTAssertNil(TunnelV3.b64uDecodeStrict("AAECAw", length: 32))
    }

    func testQrEncodingAndURL() throws {
        let qrName = try XCTUnwrap(pv["qrName"] as? [String: String])
        XCTAssertEqual(TunnelV3.qrEncode(qrName["in"]!), qrName["encoded"]!)
        let qrUrl = try XCTUnwrap(pv["qrUrl"] as? [String: Any])
        let fields = try XCTUnwrap(qrUrl["fields"] as? [String: String])
        XCTAssertEqual(TunnelV3.pairURL(fields: fields), qrUrl["url"] as? String)
        // Bridge の作り方（PairingInvites.pairURL）でも同じ文字列。exp は UNIX 秒。
        let secret = try XCTUnwrap(TunnelV3.b64uDecodeStrict(fields["secret"]!, length: 32))
        let url = PairingInvites.pairURL(bridgeId: fields["bridgeId"]!, name: fields["name"]!, platform: fields["platform"]!,
                                         relayURL: fields["relay"]!, relayId: fields["relayId"]!, bridgePub: fields["key"]!,
                                         secret: secret, expiresAtMs: Int64(fields["exp"]!)! * 1000 + 999)
        XCTAssertEqual(url, qrUrl["url"] as? String)
        // key は keys.bridgePub の b64u、secret は tunnelV3.pair.inviteSecretB64u。
        let keys = try V3Vectors.keys()
        XCTAssertEqual(fields["key"], TunnelV3.b64u(Data(v3hex: keys["bridgePub"]!)))
        let pair = try XCTUnwrap(try V3Vectors.tunnel()["pair"] as? [String: Any])
        XCTAssertEqual(fields["secret"], pair["inviteSecretB64u"] as? String)
        // Bridge は + を出さない（どちらの読み方でも同じ値になる）。
        XCTAssertFalse(TunnelV3.qrEncode("a+b c").contains("+"))
    }

    func testSasDisplayAndCodeInput() throws {
        let sas = try XCTUnwrap(pv["sasDisplay"] as? [String: String])
        XCTAssertEqual(TunnelV3.sasDisplay(sas["code"]!), sas["display"]!)
        for c in try XCTUnwrap(pv["codeInput"] as? [[String: Any]]) {
            let input = try XCTUnwrap(c["in"] as? String)
            XCTAssertEqual(TunnelV3.normalizeCode(input), c["normalized"] as? String, "in=\(input)")
        }
    }
}
