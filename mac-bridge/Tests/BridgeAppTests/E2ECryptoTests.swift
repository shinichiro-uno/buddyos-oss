import XCTest
@testable import BridgeApp

/// E2E 暗号化コアのテスト。
/// shared/e2e-test-vectors.json は 3 実装(mac/iOS/win)の相互運用の基準値。
/// ベクタは `testGenerateVectors`(E2E_GEN_VECTORS=1 で実行)の出力を固定したもの。
final class E2ECryptoTests: XCTestCase {

    // MARK: - テストベクタ読み込み

    private struct Vectors: Decodable {
        struct Keys: Decodable {
            let bridgePriv: String
            let bridgePub: String
            let devicePriv: String
            let devicePub: String
            let sharedSecret: String
        }
        struct Frame: Decodable {
            let direction: String
            let seq: UInt64
            let plaintext: String
            let frame: String
        }
        struct WS: Decodable {
            let connSalt: String
            let kC2S: String
            let kS2C: String
            let frames: [Frame]
        }
        struct PushVector: Decodable {
            let nonce: String
            let plaintext: String
            let ciphertext: String
        }
        struct Push: Decodable {
            let bridgeId: String
            let deviceId: String
            let kPush: String
            let vectors: [PushVector]
        }
        /// Paseo トンネル v2（connSalt = serverSalt || clientNonce）。windows-bridge / desktop / iOS / Android も同じ値で確かめる。
        struct TunnelV2: Decodable {
            let serverSalt: String
            let clientNonce: String
            let connSalt: String
            let kC2S: String
            let kS2C: String
        }
        let keys: Keys
        let ws: WS
        let tunnelV2: TunnelV2
        let push: Push
    }

    private static let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/e2e-test-vectors.json")

    private func loadVectors() throws -> Vectors {
        let data = try Data(contentsOf: Self.vectorsURL)
        return try JSONDecoder().decode(Vectors.self, from: data)
    }

    // MARK: - 相互運用ベクタ検証

    func testVectorKeyDerivation() throws {
        let v = try loadVectors()
        let bridgePriv = Data(hex: v.keys.bridgePriv)
        let devicePriv = Data(hex: v.keys.devicePriv)
        let bridgePub = Data(hex: v.keys.bridgePub)
        let devicePub = Data(hex: v.keys.devicePub)

        XCTAssertEqual(try E2ECrypto.publicKey(fromPrivateKey: bridgePriv).hex, v.keys.bridgePub)
        XCTAssertEqual(try E2ECrypto.publicKey(fromPrivateKey: devicePriv).hex, v.keys.devicePub)

        // static-static ECDH は両方向から同じ SS に到達する
        XCTAssertEqual(try E2ECrypto.sharedSecret(privateKey: bridgePriv, peerPublicKey: devicePub).hex, v.keys.sharedSecret)
        XCTAssertEqual(try E2ECrypto.sharedSecret(privateKey: devicePriv, peerPublicKey: bridgePub).hex, v.keys.sharedSecret)

        // WS 方向別鍵 — デバイス側/Bridge 側どちらの導出でも一致
        let connSalt = Data(hex: v.ws.connSalt)
        let deviceKeys = try E2ECrypto.deriveWSKeys(privateKey: devicePriv, peerPublicKey: bridgePub, connSalt: connSalt)
        let bridgeKeys = try E2ECrypto.deriveWSKeys(privateKey: bridgePriv, peerPublicKey: devicePub, connSalt: connSalt)
        XCTAssertEqual(deviceKeys.c2s.hex, v.ws.kC2S)
        XCTAssertEqual(deviceKeys.s2c.hex, v.ws.kS2C)
        XCTAssertEqual(bridgeKeys.c2s.hex, v.ws.kC2S)
        XCTAssertEqual(bridgeKeys.s2c.hex, v.ws.kS2C)

        // push 鍵（spec/PROTOCOL-v3.md §14.2）
        let pushKey = try E2ECrypto.derivePushKey(
            privateKey: bridgePriv, peerPublicKey: devicePub,
            bridgeId: v.push.bridgeId, deviceId: v.push.deviceId
        )
        XCTAssertEqual(pushKey.hex, v.push.kPush)
    }

    /// PaseoRelayTunnel の v2 と同じ組み立て（salt(32B) || clientNonce(32B)）で、ベクタの鍵になるか。
    func testVectorTunnelV2() throws {
        let v = try loadVectors()
        let t = v.tunnelV2
        let connSalt = Data(hex: t.serverSalt) + Data(hex: t.clientNonce)
        XCTAssertEqual(connSalt.hex, t.connSalt)
        let bridgeKeys = try E2ECrypto.deriveWSKeys(
            privateKey: Data(hex: v.keys.bridgePriv), peerPublicKey: Data(hex: v.keys.devicePub), connSalt: connSalt
        )
        let deviceKeys = try E2ECrypto.deriveWSKeys(
            privateKey: Data(hex: v.keys.devicePriv), peerPublicKey: Data(hex: v.keys.bridgePub), connSalt: connSalt
        )
        XCTAssertEqual(bridgeKeys.c2s.hex, t.kC2S)
        XCTAssertEqual(bridgeKeys.s2c.hex, t.kS2C)
        XCTAssertEqual(deviceKeys.c2s.hex, t.kC2S)
        XCTAssertEqual(deviceKeys.s2c.hex, t.kS2C)
        // clientNonce を混ぜると、同じ serverSalt でも v1（salt のみ）の鍵とは別になる。
        XCTAssertNotEqual(t.kC2S, v.ws.kC2S)
    }

    func testVectorSharedSecretMatchesRFC7748() throws {
        // 鍵ペアは RFC 7748 §6.1 のもの(bridge=Alice, device=Bob)なので SS は既知値
        let v = try loadVectors()
        XCTAssertEqual(v.keys.sharedSecret, "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    }

    func testVectorWSFrames() throws {
        let v = try loadVectors()
        for f in v.ws.frames {
            let key = Data(hex: f.direction == "c2s" ? v.ws.kC2S : v.ws.kS2C)
            let plaintext = Data(f.plaintext.utf8)

            // encode が期待暗号文と一致(counter nonce なので決定論的)
            let frame = try E2ECrypto.encodeFrame(plaintext: plaintext, seq: f.seq, key: key)
            XCTAssertEqual(frame.hex, f.frame, "encode mismatch: \(f.direction) seq=\(f.seq)")

            // decode が seq と平文を復元
            let (seq, opened) = try E2ECrypto.decodeFrame(Data(hex: f.frame), key: key)
            XCTAssertEqual(seq, f.seq)
            XCTAssertEqual(String(data: opened, encoding: .utf8), f.plaintext)
        }
    }

    func testVectorPush() throws {
        let v = try loadVectors()
        let key = Data(hex: v.push.kPush)
        for p in v.push.vectors {
            let sealed = try E2ECrypto.sealPush(plaintext: Data(p.plaintext.utf8), key: key, nonce: Data(hex: p.nonce))
            XCTAssertEqual(sealed.nonce.hex, p.nonce)
            XCTAssertEqual(sealed.ciphertext.hex, p.ciphertext)

            let opened = try E2ECrypto.openPush(ciphertext: Data(hex: p.ciphertext), nonce: Data(hex: p.nonce), key: key)
            XCTAssertEqual(String(data: opened, encoding: .utf8), p.plaintext)
        }
    }

    // MARK: - seal/open ラウンドトリップ

    func testSenderReceiverRoundTrip() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let sender = E2EFrameSender(key: key)
        let receiver = E2EFrameReceiver(key: key)

        for i in 1...5 {
            let plaintext = Data("{\"type\":\"assistant_delta\",\"content\":\"token \(i)\"}".utf8)
            let frame = try sender.seal(plaintext)
            XCTAssertEqual(try receiver.open(frame), plaintext)
        }
        XCTAssertEqual(sender.nextSeq, 6)
        XCTAssertEqual(receiver.lastSeq, 5)
    }

    func testPushRoundTripWithRandomNonce() throws {
        let key = Data((0..<32).map { UInt8($0 &* 3) })
        let plaintext = Data("{\"title\":\"BuddyOS\",\"body\":\"通知テスト\"}".utf8)
        let sealed = try E2ECrypto.sealPush(plaintext: plaintext, key: key)
        XCTAssertEqual(sealed.nonce.count, 12)
        XCTAssertEqual(try E2ECrypto.openPush(ciphertext: sealed.ciphertext, nonce: sealed.nonce, key: key), plaintext)
    }

    // MARK: - seq 検証(リプレイ/並べ替え)

    func testReplayedFrameRejected() throws {
        let key = Data(repeating: 0x42, count: 32)
        let sender = E2EFrameSender(key: key)
        let receiver = E2EFrameReceiver(key: key)

        let frame = try sender.seal(Data("hello".utf8))
        _ = try receiver.open(frame)
        // 同一フレームの再送(seq 重複)は拒否
        XCTAssertThrowsError(try receiver.open(frame)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .sequenceViolation)
        }
    }

    func testRegressedSequenceRejected() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = E2EFrameReceiver(key: key)

        let frame1 = try E2ECrypto.encodeFrame(plaintext: Data("one".utf8), seq: 1, key: key)
        let frame2 = try E2ECrypto.encodeFrame(plaintext: Data("two".utf8), seq: 2, key: key)
        _ = try receiver.open(frame1)
        _ = try receiver.open(frame2)
        // seq 逆行(並べ替え)は拒否
        XCTAssertThrowsError(try receiver.open(frame1)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .sequenceViolation)
        }
        XCTAssertEqual(receiver.lastSeq, 2)
    }

    func testSkippedSequenceRejected() throws {
        let key = Data(repeating: 0x42, count: 32)
        let receiver = E2EFrameReceiver(key: key)

        let frame1 = try E2ECrypto.encodeFrame(plaintext: Data("one".utf8), seq: 1, key: key)
        let frame3 = try E2ECrypto.encodeFrame(plaintext: Data("three".utf8), seq: 3, key: key)
        _ = try receiver.open(frame1)
        // 欠番(途中フレームの破棄)は拒否し、lastSeq は進めない
        XCTAssertThrowsError(try receiver.open(frame3)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .sequenceViolation)
        }
        XCTAssertEqual(receiver.lastSeq, 1)
        // 先頭が 1 以外(seq=2 から始まる)も欠番として拒否
        let fresh = E2EFrameReceiver(key: key)
        let frame2 = try E2ECrypto.encodeFrame(plaintext: Data("two".utf8), seq: 2, key: key)
        XCTAssertThrowsError(try fresh.open(frame2)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .sequenceViolation)
        }
        XCTAssertEqual(fresh.lastSeq, 0)
    }

    // MARK: - 改竄検知

    func testTamperedCiphertextRejected() throws {
        let key = Data(repeating: 0x11, count: 32)
        var frame = try E2ECrypto.encodeFrame(plaintext: Data("secret".utf8), seq: 1, key: key)
        frame[E2ECrypto.headerLength] ^= 0xFF
        XCTAssertThrowsError(try E2ECrypto.decodeFrame(frame, key: key)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .decryptionFailed)
        }
    }

    func testTamperedHeaderRejected() throws {
        // flags は予約で 0 だけ。0 以外は復号の前に invalidFrame で断る（spec/PROTOCOL-v3.md §9）。
        let key = Data(repeating: 0x11, count: 32)
        var frame = try E2ECrypto.encodeFrame(plaintext: Data("secret".utf8), seq: 1, key: key)
        frame[1] = 0x80
        XCTAssertThrowsError(try E2ECrypto.decodeFrame(frame, key: key)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .invalidFrame)
        }
        // seq（ヘッダの一部 = AAD）を書き換えると AEAD 検証が落ちる。
        var seqTampered = try E2ECrypto.encodeFrame(plaintext: Data("secret".utf8), seq: 1, key: key)
        seqTampered[9] = 0x02
        XCTAssertThrowsError(try E2ECrypto.decodeFrame(seqTampered, key: key)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .decryptionFailed)
        }
    }

    /// v3 のフレーム（先頭 0x03）。v1 の受け側は受け付けず、v3 の受け側は v1 を受け付けない。
    func testVersionedFrames() throws {
        let key = Data(repeating: 0x33, count: 32)
        let v3 = E2EFrameSender(key: key, version: 0x03)
        let frame = try v3.seal(Data("hello".utf8))
        XCTAssertEqual(frame[0], 0x03)
        XCTAssertEqual(try E2EFrameReceiver(key: key, version: 0x03).open(frame), Data("hello".utf8))
        XCTAssertThrowsError(try E2EFrameReceiver(key: key).open(frame)) { XCTAssertEqual($0 as? E2ECryptoError, .invalidFrame) }
        let v1 = try E2EFrameSender(key: key).seal(Data("hello".utf8))
        XCTAssertThrowsError(try E2EFrameReceiver(key: key, version: 0x03).open(v1)) { XCTAssertEqual($0 as? E2ECryptoError, .invalidFrame) }
        // 16 MiB + 26 バイトを超えるフレームは復号せずに断る。
        var big = Data([0x03, 0x00, 0, 0, 0, 0, 0, 0, 0, 1])
        big.append(Data(count: E2ECrypto.maxFramePayload + 17))
        XCTAssertThrowsError(try E2EFrameReceiver(key: key, version: 0x03).open(big)) { XCTAssertEqual($0 as? E2ECryptoError, .invalidFrame) }
    }

    func testTamperedPushRejected() throws {
        let key = Data(repeating: 0x22, count: 32)
        let sealed = try E2ECrypto.sealPush(plaintext: Data("payload".utf8), key: key)
        var tampered = sealed.ciphertext
        tampered[0] ^= 0x01
        XCTAssertThrowsError(try E2ECrypto.openPush(ciphertext: tampered, nonce: sealed.nonce, key: key)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .decryptionFailed)
        }
    }

    func testWrongKeyRejected() throws {
        let frame = try E2ECrypto.encodeFrame(plaintext: Data("secret".utf8), seq: 1, key: Data(repeating: 0x01, count: 32))
        XCTAssertThrowsError(try E2ECrypto.decodeFrame(frame, key: Data(repeating: 0x02, count: 32))) { error in
            XCTAssertEqual(error as? E2ECryptoError, .decryptionFailed)
        }
    }

    // MARK: - 不正フレーム

    func testUnknownVersionRejected() throws {
        let key = Data(repeating: 0x11, count: 32)
        var frame = try E2ECrypto.encodeFrame(plaintext: Data("x".utf8), seq: 1, key: key)
        frame[0] = 0x02
        XCTAssertThrowsError(try E2ECrypto.decodeFrame(frame, key: key)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .invalidFrame)
        }
    }

    func testTruncatedFrameRejected() throws {
        let key = Data(repeating: 0x11, count: 32)
        XCTAssertThrowsError(try E2ECrypto.decodeFrame(Data([0x01, 0x00, 0x00]), key: key)) { error in
            XCTAssertEqual(error as? E2ECryptoError, .invalidFrame)
        }
    }

    func testInvalidKeyLengthRejected() {
        XCTAssertThrowsError(try E2ECrypto.encodeFrame(plaintext: Data("x".utf8), seq: 1, key: Data(repeating: 0, count: 16))) { error in
            XCTAssertEqual(error as? E2ECryptoError, .invalidKey)
        }
    }

    // MARK: - ベクタ生成ヘルパ

    /// shared/e2e-test-vectors.json の生成元。`E2E_GEN_VECTORS=1 swift test --filter testGenerateVectors`
    /// で実行し、出力をそのまま JSON に固定する(counter nonce + 固定鍵なので決定論的)。
    func testGenerateVectors() throws {
        guard ProcessInfo.processInfo.environment["E2E_GEN_VECTORS"] == "1" else {
            throw XCTSkip("E2E_GEN_VECTORS=1 のときのみ実行(ベクタ再生成用)")
        }

        // RFC 7748 §6.1 の鍵ペア(bridge=Alice, device=Bob)— SS の既知値でクロスチェック可能
        let bridgePriv = Data(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        let devicePriv = Data(hex: "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
        let bridgePub = try E2ECrypto.publicKey(fromPrivateKey: bridgePriv)
        let devicePub = try E2ECrypto.publicKey(fromPrivateKey: devicePriv)
        let ss = try E2ECrypto.sharedSecret(privateKey: bridgePriv, peerPublicKey: devicePub)

        let connSalt = Data((0..<32).map { UInt8($0) })
        let wsKeys = try E2ECrypto.deriveWSKeys(privateKey: devicePriv, peerPublicKey: bridgePub, connSalt: connSalt)

        let bridgeId = "bridge-test-1"
        let deviceId = "device-test-1"
        let pushKey = try E2ECrypto.derivePushKey(privateKey: bridgePriv, peerPublicKey: devicePub, bridgeId: bridgeId, deviceId: deviceId)

        // WS フレーム: seq=1,2 / s2c / 大きい seq(2^32+1、上位バイトの BE エンコード確認)
        let frames: [(direction: String, seq: UInt64, plaintext: String)] = [
            ("c2s", 1, #"{"type":"e2e_confirm"}"#),
            ("c2s", 2, #"{"type":"user_message","content":"こんにちは"}"#),
            ("s2c", 1, #"{"type":"assistant_delta","content":"Hello"}"#),
            ("c2s", 4_294_967_297, #"{"type":"ping"}"#)
        ]
        var frameJSON: [String] = []
        for f in frames {
            let key = f.direction == "c2s" ? wsKeys.c2s : wsKeys.s2c
            let frame = try E2ECrypto.encodeFrame(plaintext: Data(f.plaintext.utf8), seq: f.seq, key: key)
            frameJSON.append("""
                  {"direction": "\(f.direction)", "seq": \(f.seq), "plaintext": \(jsonString(f.plaintext)), "frame": "\(frame.hex)"}
            """)
        }

        let pushNonce = Data(hex: "000102030405060708090a0b")
        let pushPlaintext = #"{"title":"BuddyOS","body":"応答が完了しました","payload":{"kind":"done","sessionId":"s-1"}}"#
        let sealed = try E2ECrypto.sealPush(plaintext: Data(pushPlaintext.utf8), key: pushKey, nonce: pushNonce)

        let json = """
        {
          "comment": "BuddyOS E2E 相互運用テストベクタ (docs/E2E_ENCRYPTION_DESIGN.md §3-4)。鍵ペアは RFC 7748 §6.1 (bridge=Alice, device=Bob)。生成元: mac-bridge/Tests/BridgeAppTests/E2ECryptoTests.swift testGenerateVectors",
          "keys": {
            "bridgePriv": "\(bridgePriv.hex)",
            "bridgePub": "\(bridgePub.hex)",
            "devicePriv": "\(devicePriv.hex)",
            "devicePub": "\(devicePub.hex)",
            "sharedSecret": "\(ss.hex)"
          },
          "ws": {
            "connSalt": "\(connSalt.hex)",
            "kC2S": "\(wsKeys.c2s.hex)",
            "kS2C": "\(wsKeys.s2c.hex)",
            "frames": [
        \(frameJSON.joined(separator: ",\n"))
            ]
          },
          "push": {
            "bridgeId": "\(bridgeId)",
            "deviceId": "\(deviceId)",
            "kPush": "\(pushKey.hex)",
            "vectors": [
              {"nonce": "\(pushNonce.hex)", "plaintext": \(jsonString(pushPlaintext)), "ciphertext": "\(sealed.ciphertext.hex)"}
            ]
          }
        }
        """
        // 知らないトップレベルのキーは残して書く。tunnelV2 は別に計算して手で追記したもの、
        // tunnelV3・pairingV3 は固定値（spec/PROTOCOL-v3.md §18）。消さない
        // （確かめ役は shared/tools/check-tunnel-v3.mts）。
        var merged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        if let existing = try? JSONSerialization.jsonObject(with: Data(contentsOf: Self.vectorsURL)) as? [String: Any] {
            for (k, v) in existing where merged[k] == nil { merged[k] = v }
            if let comment = existing["comment"] { merged["comment"] = comment }
        }
        let out = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print("=== E2E_TEST_VECTORS_BEGIN ===")
        print(String(decoding: out, as: UTF8.self))
        print("=== E2E_TEST_VECTORS_END ===")
    }

    private func jsonString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

// MARK: - hex ヘルパ

private extension Data {
    init(hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
