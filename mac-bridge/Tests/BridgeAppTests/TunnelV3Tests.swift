import XCTest
@testable import BridgeApp

/// トンネル v3（Noise_IKpsk2）を shared/e2e-test-vectors.json の tunnelV3 で確かめる
/// （spec/PROTOCOL-v3.md §8・§9・§18）。
final class TunnelV3Tests: XCTestCase {
    private var keys: [String: String] = [:]
    private var tv: [String: Any] = [:]

    override func setUpWithError() throws {
        keys = try V3Vectors.keys()
        tv = try V3Vectors.tunnel()
    }

    private func mode(_ name: String) throws -> [String: Any] { try XCTUnwrap(tv[name] as? [String: Any]) }
    private func str(_ o: [String: Any], _ k: String) throws -> String { try XCTUnwrap(o[k] as? String) }
    private func b64u(_ s: String) throws -> Data { try XCTUnwrap(TunnelV3.b64uDecodeStrict(s)) }

    private var bridgePriv: Data { Data(v3hex: keys["bridgePriv"]!) }
    private var bridgePub: Data { Data(v3hex: keys["bridgePub"]!) }
    private var devicePriv: Data { Data(v3hex: keys["devicePriv"]!) }
    private var devicePub: Data { Data(v3hex: keys["devicePub"]!) }
    private var eI: Data { get throws { Data(v3hex: try str(tv, "deviceEphemeralPriv")) } }
    private var eR: Data { get throws { Data(v3hex: try str(tv, "bridgeEphemeralPriv")) } }

    func testConstants() throws {
        XCTAssertEqual(try str(tv, "protocolName"), TunnelV3.protocolName)
        XCTAssertEqual(try str(tv, "prologue"), String(decoding: TunnelV3.prologue, as: UTF8.self))
        XCTAssertEqual(TunnelV3.deviceKeyId(devicePub: devicePub), try str(tv, "deviceKeyId"))
    }

    /// ①固定の一時鍵で両側を動かし、init / hello / handshakeHash / kC2S / kS2C / frames が一致する
    /// ②responder が init から payload1 と devicePub を取り出せる ③initiator が hello から payload2 を取り出せる。
    func testHandshakeVectorsAllModes() throws {
        for name in ["connect", "pair", "approve"] {
            let m = try mode(name)
            let psk = Data(v3hex: try str(m, "psk"))
            let p1 = Data(try str(m, "payload1").utf8)
            let p2 = Data(try str(m, "payload2").utf8)
            let initObj = try XCTUnwrap(m["init"] as? [String: Any])
            let helloObj = try XCTUnwrap(m["hello"] as? [String: Any])

            var ini = try TunnelV3.Initiator(staticPriv: devicePriv, bridgeStaticPub: bridgePub, psk: psk, ephemeralPriv: try eI)
            let w1 = try ini.writeMessage1(payload: p1)
            XCTAssertEqual(TunnelV3.b64u(w1.e), try str(initObj, "e"), name)
            XCTAssertEqual(TunnelV3.b64u(w1.s), try str(initObj, "s"), name)
            XCTAssertEqual(TunnelV3.b64u(w1.p), try str(initObj, "p"), name)

            // Bridge の側は TEXT の msg1 を読むところから。
            let text = "{\"type\":\"buddyos_tunnel_init\",\"v\":3,\"e\":\"\(try str(initObj, "e"))\",\"s\":\"\(try str(initObj, "s"))\",\"p\":\"\(try str(initObj, "p"))\"}"
            let m1 = try TunnelV3.Message1.parse(text)
            var res = try TunnelV3.Responder(staticPriv: bridgePriv, ephemeralPriv: try eR)
            let r1 = try res.readMessage1(e: m1.e, s: m1.s, p: m1.p)
            XCTAssertEqual(r1.deviceStaticPub, devicePub, name)
            XCTAssertEqual(r1.payload, p1, name)
            let w2 = try res.writeMessage2(payload: p2, psk: psk)
            XCTAssertEqual(TunnelV3.b64u(w2.e), try str(helloObj, "e"), name)
            XCTAssertEqual(TunnelV3.b64u(w2.p), try str(helloObj, "p"), name)
            XCTAssertEqual(w2.hash.v3hex, try str(m, "handshakeHash"), name)
            XCTAssertEqual(w2.c2s.v3hex, try str(m, "kC2S"), name)
            XCTAssertEqual(w2.s2c.v3hex, try str(m, "kS2C"), name)
            XCTAssertEqual(TunnelV3.helloText(e: w2.e, p: w2.p),
                           "{\"type\":\"buddyos_tunnel_hello\",\"v\":3,\"e\":\"\(try str(helloObj, "e"))\",\"p\":\"\(try str(helloObj, "p"))\"}")

            let r2 = try ini.readMessage2(e: try b64u(try str(helloObj, "e")), p: try b64u(try str(helloObj, "p")))
            XCTAssertEqual(r2.payload, p2, name)
            XCTAssertEqual(r2.hash.v3hex, try str(m, "handshakeHash"), name)

            let frames = try XCTUnwrap(m["frames"] as? [[String: Any]])
            let c2sSender = E2EFrameSender(key: w2.c2s, version: 0x03)
            let s2cSender = E2EFrameSender(key: w2.s2c, version: 0x03)
            let c2sReceiver = E2EFrameReceiver(key: w2.c2s, version: 0x03)
            let s2cReceiver = E2EFrameReceiver(key: w2.s2c, version: 0x03)
            for f in frames {
                let dir = try str(f, "direction")
                let pt = Data(try str(f, "plaintext").utf8)
                let expected = try str(f, "frame")
                let sender = dir == "c2s" ? c2sSender : s2cSender
                let receiver = dir == "c2s" ? c2sReceiver : s2cReceiver
                XCTAssertEqual(try sender.seal(pt).v3hex, expected, "\(name) \(dir) \(f["seq"] ?? "")")
                XCTAssertEqual(try receiver.open(Data(v3hex: expected)), pt)
            }
        }
    }

    /// ④inviteId / psk / deviceKeyId / credentialHash / commit / sas。
    func testDerivations() throws {
        let pair = try mode("pair")
        let secret = Data(v3hex: try str(pair, "inviteSecret"))
        XCTAssertEqual(TunnelV3.b64u(secret), try str(pair, "inviteSecretB64u"))
        XCTAssertEqual(TunnelV3.inviteId(secret: secret), try str(pair, "inviteId"))
        XCTAssertEqual(TunnelV3.invitePsk(secret: secret).v3hex, try str(pair, "psk"))
        XCTAssertEqual(TunnelV3.credentialHash(try str(pair, "credential")), try str(pair, "credentialHash"))

        let approve = try mode("approve")
        let nI = Data(v3hex: try str(approve, "nI"))
        let nR = Data(v3hex: try str(approve, "nR"))
        XCTAssertEqual(TunnelV3.sasCommit(nR: nR).v3hex, try str(approve, "commit"))
        XCTAssertEqual(TunnelV3.sasCode(handshakeHash: Data(v3hex: try str(approve, "handshakeHash")), nI: nI, nR: nR),
                       try str(approve, "sas"))
        XCTAssertEqual(String(try TunnelV3.newCredential().prefix(4)), "bdc_")
        XCTAssertEqual(try TunnelV3.newCredential().count, 47)
    }

    /// Bridge が組み立てる payload2 と paired が、ベクタのバイト列と同じ。
    func testBridgeMessagesMatchVectorBytes() throws {
        let connect = try mode("connect")
        XCTAssertEqual(String(decoding: TunnelV3.payload2OK(bridgeId: "bridge-test-1", name: "Test Mac", platform: "mac",
                                                            deviceKeyId: "815WFhYKML88bnn6c8V21A"), as: UTF8.self),
                       try str(connect, "payload2"))
        let approve = try mode("approve")
        XCTAssertEqual(String(decoding: TunnelV3.payload2OK(bridgeId: "bridge-test-1", name: "Test Mac", platform: "mac",
                                                            deviceKeyId: "815WFhYKML88bnn6c8V21A",
                                                            commit: Data(v3hex: try str(approve, "commit"))), as: UTF8.self),
                       try str(approve, "payload2"))
        let pair = try mode("pair")
        let pairedFrame = try XCTUnwrap((pair["frames"] as? [[String: Any]])?.first { $0["direction"] as? String == "s2c" })
        // 中継の URL はベクタの値をそのまま使う（ベクタは全アプリで共通。ここに書き写さない）。
        let vectorPaired = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try str(pairedFrame, "plaintext").utf8)) as? [String: Any])
        let vectorRelayURL = try XCTUnwrap((vectorPaired["bridge"] as? [String: Any])?["relayURL"] as? String)
        let paired = TunnelV3.paired(deviceKeyId: "815WFhYKML88bnn6c8V21A", credential: try str(pair, "credential"),
                                     bridge: .init(bridgeId: "bridge-test-1", name: "Test Mac", platform: "mac",
                                                   relayId: "4OHi4-Tl5ufo6err7O3u7_Dx8vP09fb3-Pn6-_z9_v8",
                                                   relayURL: vectorRelayURL))
        XCTAssertEqual(String(decoding: paired, as: UTF8.self), try str(pairedFrame, "plaintext"))
        let revealFrame = try XCTUnwrap((approve["frames"] as? [[String: Any]])?.first { $0["direction"] as? String == "s2c" })
        XCTAssertEqual(String(decoding: TunnelV3.approveReveal(nR: Data(v3hex: try str(approve, "nR"))), as: UTF8.self),
                       try str(revealFrame, "plaintext"))
    }

    /// 端末の制御メッセージの読み方（知らない type・形の違う n は読めない）。
    func testControlParsing() throws {
        let approve = try mode("approve")
        let nonce = try XCTUnwrap((approve["frames"] as? [[String: Any]])?.first)
        XCTAssertEqual(TunnelV3.Control.parse(Data(try str(nonce, "plaintext").utf8)),
                       .approveNonce(Data(v3hex: try str(approve, "nI"))))
        XCTAssertEqual(TunnelV3.Control.parse(Data(#"{"type":"open"}"#.utf8)), .open)
        XCTAssertEqual(TunnelV3.Control.parse(Data(#"{"type":"pair_confirm"}"#.utf8)), .pairConfirm)
        XCTAssertEqual(TunnelV3.Control.parse(Data(#"{"type":"paired_ack"}"#.utf8)), .pairedAck)
        XCTAssertEqual(TunnelV3.Control.parse(Data(#"{"type":"pair_cancel"}"#.utf8)), .pairCancel)
        XCTAssertNil(TunnelV3.Control.parse(Data(#"{"type":"approve_reveal","n":"x"}"#.utf8)))
        XCTAssertNil(TunnelV3.Control.parse(Data(#"{"type":"approve_nonce","n":"AAEC"}"#.utf8)))
        XCTAssertNil(TunnelV3.Control.parse(Data("not json".utf8)))
        XCTAssertNil(TunnelV3.Control.parse(Data(repeating: 0x20, count: 4097)))
    }

    /// msg1 の形（v なし・v2 は version、e/s/p の長さ違いは bad_message、init でない TEXT は読み捨て）。
    func testMessage1Parsing() throws {
        XCTAssertThrowsError(try TunnelV3.Message1.parse(#"{"type":"buddyos_tunnel_init","deviceId":"x","devicePub":"y"}"#)) {
            XCTAssertEqual($0 as? TunnelV3.Message1.ParseError, .version)
        }
        XCTAssertThrowsError(try TunnelV3.Message1.parse(#"{"type":"buddyos_tunnel_init","v":2,"e":"","s":"","p":""}"#)) {
            XCTAssertEqual($0 as? TunnelV3.Message1.ParseError, .version)
        }
        XCTAssertThrowsError(try TunnelV3.Message1.parse(#"{"type":"buddyos_tunnel_init","v":3,"e":"AAAA","s":"AAAA","p":"AAAA"}"#)) {
            XCTAssertEqual($0 as? TunnelV3.Message1.ParseError, .badMessage)
        }
        XCTAssertThrowsError(try TunnelV3.Message1.parse(#"{"type":"something_else"}"#)) {
            XCTAssertEqual($0 as? TunnelV3.Message1.ParseError, .notInit)
        }
        XCTAssertEqual(TunnelV3.errorText(.version), #"{"type":"buddyos_tunnel_error","v":3,"code":"version"}"#)
    }

    func testPayload1Parsing() {
        XCTAssertEqual(TunnelV3.Payload1.parse(Data(#"{"mode":"connect","deviceId":"device-test-1","platform":"ios"}"#.utf8))?.mode, .connect)
        XCTAssertNil(TunnelV3.Payload1.parse(Data(#"{"mode":"connect","deviceId":"short","platform":"ios"}"#.utf8)))
        XCTAssertNil(TunnelV3.Payload1.parse(Data(#"{"mode":"connect","deviceId":"device-test-1","platform":"linux"}"#.utf8)))
        XCTAssertNil(TunnelV3.Payload1.parse(Data(#"{"mode":"pair","deviceId":"device-test-1","platform":"ios","name":"x"}"#.utf8)),
                     "pair は invite が要る")
        XCTAssertNil(TunnelV3.Payload1.parse(Data(#"{"mode":"approve","deviceId":"device-test-1","platform":"ios"}"#.utf8)),
                     "approve は name が要る")
        XCTAssertNil(TunnelV3.Payload1.parse(Data(#"{"mode":"hack","deviceId":"device-test-1","platform":"ios"}"#.utf8)))
    }

    // MARK: - 失敗のテスト（spec/PROTOCOL-v3.md §18.2）

    /// §18.2 の 1: pair の hello を、psk を 0 埋めにした initiator で読むと復号失敗。
    func testZeroPskCannotOpenPairHello() throws {
        let pair = try mode("pair")
        let hello = try XCTUnwrap(pair["hello"] as? [String: Any])
        var ini = try TunnelV3.Initiator(staticPriv: devicePriv, bridgeStaticPub: bridgePub, psk: TunnelV3.zeroPsk, ephemeralPriv: try eI)
        _ = try ini.writeMessage1(payload: Data(try str(pair, "payload1").utf8))
        XCTAssertThrowsError(try ini.readMessage2(e: try b64u(try str(hello, "e")), p: try b64u(try str(hello, "p")))) {
            XCTAssertEqual($0 as? TunnelV3Error, .decryptionFailed)
        }
    }

    private func readConnectInit(flip key: String?, staticPriv: Data? = nil) throws {
        let connect = try mode("connect")
        let initObj = try XCTUnwrap(connect["init"] as? [String: Any])
        var e = try b64u(try str(initObj, "e")), s = try b64u(try str(initObj, "s")), p = try b64u(try str(initObj, "p"))
        if key == "s" { s[s.startIndex] ^= 0x01 }
        if key == "p" { p[p.startIndex] ^= 0x01 }
        if key == "e" { e = Data(count: 32) }
        var res = try TunnelV3.Responder(staticPriv: staticPriv ?? bridgePriv, ephemeralPriv: try eR)
        _ = try res.readMessage1(e: e, s: s, p: p)
    }

    /// §18.2 の 2: init.s / init.p の 1 ビットを反転すると復号失敗。
    func testFlippedInitFailsToDecrypt() throws {
        XCTAssertThrowsError(try readConnectInit(flip: "s")) { XCTAssertEqual($0 as? TunnelV3Error, .decryptionFailed) }
        XCTAssertThrowsError(try readConnectInit(flip: "p")) { XCTAssertEqual($0 as? TunnelV3Error, .decryptionFailed) }
        XCTAssertNoThrow(try readConnectInit(flip: nil))
    }

    /// §18.2 の 3: responder の静的鍵を別の鍵にすると init.s の復号に失敗する。
    func testWrongResponderKeyFails() throws {
        XCTAssertThrowsError(try readConnectInit(flip: nil, staticPriv: devicePriv)) {
            XCTAssertEqual($0 as? TunnelV3Error, .decryptionFailed)
        }
    }

    /// §18.2 の 4: init.e に 0 が 32 バイトの公開鍵 → DH の失敗。
    func testZeroEphemeralRejected() throws {
        XCTAssertThrowsError(try readConnectInit(flip: "e")) { error in
            let e = error as? TunnelV3Error
            XCTAssertTrue(e == .dhZero || e == .invalidKey, "\(error)")
        }
    }

    /// §18.2 の 5: v3 のフレームの受け側は、復号の前に version・seq・flags・長さを確かめる。
    func testFrameReceiverChecksBeforeDecrypting() throws {
        let connect = try mode("connect")
        let k = Data(v3hex: try str(connect, "kC2S"))
        let frames = try XCTUnwrap(connect["frames"] as? [[String: Any]])
        let good = Data(v3hex: try str(frames[0], "frame"))

        var v1 = good; v1[0] = 0x01
        XCTAssertThrowsError(try E2EFrameReceiver(key: k, version: 0x03).open(v1)) {
            XCTAssertEqual($0 as? E2ECryptoError, .invalidFrame)
        }
        XCTAssertThrowsError(try E2EFrameReceiver(key: k, version: 0x03).open(Data(v3hex: try str(frames[1], "frame")))) {
            XCTAssertEqual($0 as? E2ECryptoError, .sequenceViolation)
        }
        var flagged = good; flagged[1] = 0x01
        XCTAssertThrowsError(try E2EFrameReceiver(key: k, version: 0x03).open(flagged)) {
            XCTAssertEqual($0 as? E2ECryptoError, .invalidFrame)
        }
        let seq0 = try E2ECrypto.encodeFrame(plaintext: Data("x".utf8), seq: 0, key: k, version: 0x03)
        XCTAssertThrowsError(try E2EFrameReceiver(key: k, version: 0x03).open(seq0))
        XCTAssertThrowsError(try E2EFrameReceiver(key: k, version: 0x03).open(good.prefix(25))) {
            XCTAssertEqual($0 as? E2ECryptoError, .invalidFrame)
        }
        // 正しいフレームは通る。v1 の受け側は v3 のフレームを受け付けない。
        XCTAssertNoThrow(try E2EFrameReceiver(key: k, version: 0x03).open(good))
        XCTAssertThrowsError(try E2EFrameReceiver(key: k).open(good)) { XCTAssertEqual($0 as? E2ECryptoError, .invalidFrame) }
    }
}
