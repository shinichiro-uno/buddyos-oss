import Foundation
import Crypto

// NOTE: ios/Sources/E2E/E2ECrypto.swift に同一実装のコピーがある(差分は import のみ)。
// ワイヤ互換を壊さないため、変更は必ず両ファイルに反映すること。

/// E2E 暗号化の失敗理由。WS フレームの検証失敗は呼び出し側で close(1008) すること。
enum E2ECryptoError: Error, Equatable {
    /// ヘッダ不足・version 不一致など、フレームとして解釈できない
    case invalidFrame
    /// seq の逆行・重複・欠番(リプレイ/並べ替え/フレーム破棄の疑い)
    case sequenceViolation
    /// AEAD 検証失敗(改竄または鍵不一致)
    case decryptionFailed
    /// 鍵素材の長さ不正など
    case invalidKey
}

/// アプリ層 E2E 暗号化コア: X25519 + HKDF-SHA256 + ChaCha20-Poly1305（spec/PROTOCOL-v3.md §13.6・§14）。
/// mac-bridge / iOS / windows-bridge の 3 実装が同一ワイヤ形式で相互運用するため、
/// info/salt 文字列とフレームレイアウトは**絶対に変更しない**こと(shared/e2e-test-vectors.json で固定)。
///
/// WS フレーム（spec/PROTOCOL-v3.md §9・§13.6、バイナリ）:
/// ```
/// offset 0      : uint8  version = 0x01
/// offset 1      : uint8  flags   = 0x00 (予約)
/// offset 2..9   : uint64 BE seq  (方向ごとに 1 から単調増加)
/// offset 10..   : ChaChaPoly ciphertext || tag(16B)
/// nonce = 0x00000000 || seq(8B BE)   // 方向は鍵で分離済みなので nonce は counter のみ
/// AAD   = ヘッダ 10 バイト
/// ```
enum E2ECrypto {
    static let frameVersion: UInt8 = 0x01
    /// トンネル v3（spec/PROTOCOL-v3.md §9）のフレーム。形は v1 と同じで先頭だけ 0x03。
    static let frameVersionV3: UInt8 = 0x03
    static let headerLength = 10
    static let tagLength = 16
    /// ヘッダ + tag。暗号化フレームはこれ以上の長さを持つ
    static let frameOverhead = headerLength + tagLength
    /// フレームの本文の上限（16 MiB）。これを超えるフレームは復号せずに断る（§9 の 1）。
    static let maxFramePayload = 16 * 1024 * 1024

    // 経路別の鍵導出ラベル（§13.6 / §4 の k_push）。3 実装で共通。変更禁止。
    private static let infoC2S = Data("buddyos/ws/v1/c2s".utf8)
    private static let infoS2C = Data("buddyos/ws/v1/s2c".utf8)
    private static let pushSalt = Data("buddyos/push/v1".utf8)

    // MARK: - 鍵導出

    /// X25519 秘密鍵(raw 32B)から公開鍵(raw 32B)を得る。QR / register_e2e_key 用。
    static func publicKey(fromPrivateKey privateKey: Data) throws -> Data {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            throw E2ECryptoError.invalidKey
        }
        return key.publicKey.rawRepresentation
    }

    /// SS = X25519(static, static)。ディスクに書かないこと。
    static func sharedSecret(privateKey: Data, peerPublicKey: Data) throws -> Data {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) else {
            throw E2ECryptoError.invalidKey
        }
        guard let ss = try? priv.sharedSecretFromKeyAgreement(with: pub) else {
            throw E2ECryptoError.invalidKey
        }
        return ss.withUnsafeBytes { Data($0) }
    }

    /// WS 方向別鍵（§13.6）。connSalt は接続ごとに Bridge が生成する 32B 乱数
    /// (接続ごとの鍵分離 — 1 接続の鍵漏洩の影響を局所化)。
    ///
    /// ```
    /// k_c2s = HKDF-SHA256(ikm=SS, salt=connSalt, info="buddyos/ws/v1/c2s", L=32)
    /// k_s2c = HKDF-SHA256(ikm=SS, salt=connSalt, info="buddyos/ws/v1/s2c", L=32)
    /// ```
    static func deriveWSKeys(privateKey: Data, peerPublicKey: Data, connSalt: Data) throws -> (c2s: Data, s2c: Data) {
        let ss = try sharedSecret(privateKey: privateKey, peerPublicKey: peerPublicKey)
        return (
            hkdf(ikm: ss, salt: connSalt, info: infoC2S),
            hkdf(ikm: ss, salt: connSalt, info: infoS2C)
        )
    }

    /// push 用鍵（§4 の k_push）。生きたセッションなしで両端が同じ鍵に到達できるよう、salt/info は静的。
    ///
    /// ```
    /// k_push = HKDF-SHA256(ikm=SS, salt="buddyos/push/v1", info=bridgeId+"|"+deviceId, L=32)
    /// ```
    static func derivePushKey(privateKey: Data, peerPublicKey: Data, bridgeId: String, deviceId: String) throws -> Data {
        let ss = try sharedSecret(privateKey: privateKey, peerPublicKey: peerPublicKey)
        return hkdf(ikm: ss, salt: pushSalt, info: Data("\(bridgeId)|\(deviceId)".utf8))
    }

    // MARK: - WS フレーム encode/decode

    /// 平文(SessionEvent JSON UTF-8)を暗号化フレームにする。seq は方向ごとに 1 から単調増加。
    /// `version` は先頭の 1 バイト（v1 の WS は 0x01、トンネル v3 は 0x03）。
    static func encodeFrame(plaintext: Data, seq: UInt64, key: Data, version: UInt8 = 0x01) throws -> Data {
        let symKey = try symmetricKey(key)
        var header = Data([version, 0x00])
        header.append(seqBytes(seq))
        do {
            let box = try ChaChaPoly.seal(plaintext, using: symKey, nonce: nonce(forSeq: seq), authenticating: header)
            return header + box.ciphertext + box.tag
        } catch {
            throw E2ECryptoError.decryptionFailed
        }
    }

    /// 暗号化フレームを開く。seq の単調性検証は呼び出し側(E2EFrameReceiver)の責務。
    /// 復号の前に、長さ（26 バイト以上・16 MiB + 26 バイト以下）・version・flags（0 だけ）を確かめる
    /// （spec/PROTOCOL-v3.md §9 の 1〜3。外れたものは invalidFrame で、復号しない）。
    static func decodeFrame(_ frame: Data, key: Data, version: UInt8 = 0x01) throws -> (seq: UInt64, plaintext: Data) {
        let symKey = try symmetricKey(key)
        let frame = Data(frame)  // スライス由来の index ずれを防ぐ
        try checkHeader(frame, version: version)
        let seq = headerSeq(frame)
        let header = frame.prefix(headerLength)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce(forSeq: seq),
                ciphertext: frame[headerLength..<(frame.count - tagLength)],
                tag: frame.suffix(tagLength)
            )
            let plaintext = try ChaChaPoly.open(box, using: symKey, authenticating: header)
            return (seq, plaintext)
        } catch {
            throw E2ECryptoError.decryptionFailed
        }
    }

    /// §9 の 1〜3（長さ・version・flags）。flags は将来のための予約で、0 以外は閉じる。
    static func checkHeader(_ frame: Data, version: UInt8) throws {
        guard frame.count >= frameOverhead, frame.count <= maxFramePayload + frameOverhead else {
            throw E2ECryptoError.invalidFrame
        }
        let start = frame.startIndex
        guard frame[start] == version, frame[start + 1] == 0x00 else { throw E2ECryptoError.invalidFrame }
    }

    /// ヘッダの seq（offset 2..9、BE）。長さは checkHeader で確かめてから呼ぶ。
    static func headerSeq(_ frame: Data) -> UInt64 {
        let start = frame.startIndex
        return frame[(start + 2)..<(start + headerLength)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    // MARK: - push seal/open

    /// push ペイロードの暗号化（§14.2）。nonce 省略時はランダム 12B
    /// (push は低頻度なので誕生日限界 2^32 に遠く及ばない)。戻り値は (n, c) = (12B nonce, ct||tag)。
    static func sealPush(plaintext: Data, key: Data, nonce nonceData: Data? = nil) throws -> (nonce: Data, ciphertext: Data) {
        let symKey = try symmetricKey(key)
        let nonce: ChaChaPoly.Nonce
        if let nonceData {
            guard let fixed = try? ChaChaPoly.Nonce(data: nonceData) else { throw E2ECryptoError.invalidFrame }
            nonce = fixed
        } else {
            nonce = ChaChaPoly.Nonce()
        }
        do {
            let box = try ChaChaPoly.seal(plaintext, using: symKey, nonce: nonce)
            // box.ciphertext はスライスで startIndex が 0 でないことがあるため Data() で 0 起点に正規化
            return (nonce.withUnsafeBytes { Data($0) }, Data(box.ciphertext + box.tag))
        } catch {
            throw E2ECryptoError.decryptionFailed
        }
    }

    /// push ペイロードの復号(iOS NSE 用)。失敗時はプレースホルダ表示に落とすこと（§14.3）。
    static func openPush(ciphertext: Data, nonce nonceData: Data, key: Data) throws -> Data {
        let symKey = try symmetricKey(key)
        let ciphertext = Data(ciphertext)
        guard ciphertext.count >= tagLength, let nonce = try? ChaChaPoly.Nonce(data: nonceData) else {
            throw E2ECryptoError.invalidFrame
        }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext.dropLast(tagLength),
                tag: ciphertext.suffix(tagLength)
            )
            return try ChaChaPoly.open(box, using: symKey)
        } catch {
            throw E2ECryptoError.decryptionFailed
        }
    }

    // MARK: - private

    private static func symmetricKey(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw E2ECryptoError.invalidKey }
        return SymmetricKey(data: data)
    }

    private static func hkdf(ikm: Data, salt: Data, info: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private static func seqBytes(_ seq: UInt64) -> Data {
        var be = seq.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    private static func nonce(forSeq seq: UInt64) throws -> ChaChaPoly.Nonce {
        // 方向は鍵で分離済みなので nonce は counter のみで衝突しない（§9）
        try ChaChaPoly.Nonce(data: Data(count: 4) + seqBytes(seq))
    }
}

/// WS 送信側: 方向鍵を保持し、seq を 1 から自動採番して seal する（§9）。
/// `version` は先頭の 1 バイト（既定 0x01。トンネル v3 は 0x03）。
final class E2EFrameSender {
    private let key: Data
    private let version: UInt8
    private(set) var nextSeq: UInt64 = 1

    init(key: Data, version: UInt8 = 0x01) {
        self.key = key
        self.version = version
    }

    func seal(_ plaintext: Data) throws -> Data {
        // 2^64 - 1 に達したら送らない（呼び出し側は閉じる。§9 の 4）。
        guard nextSeq < UInt64.max else { throw E2ECryptoError.sequenceViolation }
        let frame = try E2ECrypto.encodeFrame(plaintext: plaintext, seq: nextSeq, key: key, version: version)
        nextSeq += 1
        return frame
    }
}

/// WS 受信側: seq が欠番なしの連番(lastSeq + 1)であることを検証して open する。
/// E2ECryptoError が投げられたら呼び出し側は close(1008) すること — WS は TCP 順序保証が
/// あるため、これだけでリプレイ/並べ替え/途中フレームの破棄を検知できる（§9）。
/// 末尾フレームを落としてから切断する攻撃は、認証付き close フレームがないため検知できない。
final class E2EFrameReceiver {
    private let key: Data
    private let version: UInt8
    private(set) var lastSeq: UInt64 = 0

    init(key: Data, version: UInt8 = 0x01) {
        self.key = key
        self.version = version
    }

    func open(_ frame: Data) throws -> Data {
        // 復号の前に長さ・version・flags・seq を確かめる（§9 の 1〜4）。seq は 1 から 1 ずつ。
        // 送信側は必ず +1 で採番するので、欠番は relay による選択的な破棄とみなして拒否する
        let frame = Data(frame)
        try E2ECrypto.checkHeader(frame, version: version)
        guard lastSeq < UInt64.max, E2ECrypto.headerSeq(frame) == lastSeq + 1 else {
            throw E2ECryptoError.sequenceViolation
        }
        let (seq, plaintext) = try E2ECrypto.decodeFrame(frame, key: key, version: version)
        // 改竄フレームで seq を進められないよう、open 成功後に更新する。
        lastSeq = seq
        return plaintext
    }
}
