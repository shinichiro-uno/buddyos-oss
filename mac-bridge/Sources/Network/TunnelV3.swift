import Foundation
import Crypto

// Paseo トンネル v3（Noise_IKpsk2_25519_ChaChaPoly_SHA256）と、端末認証 v3 のペアリングまわりの規則。
// 仕様は spec/PROTOCOL-v3.md（§4〜§10）。値は shared/e2e-test-vectors.json の
// tunnelV3・pairingV3 で確かめる（TunnelV3Tests・PairingV3VectorTests）。
// iOS の ios/Sources/Core/TunnelV3.swift と中身をそろえる（Noise の部分は §8 のとおり）。

enum TunnelV3Error: Error { case invalidKey, dhZero, decryptionFailed, invalidMessage, randomFailed }

enum TunnelV3 {
    static let protocolName = "Noise_IKpsk2_25519_ChaChaPoly_SHA256"
    static let prologue = Data("buddyos-tunnel-v3".utf8)

    static func sha256(_ parts: Data...) -> Data {
        var h = SHA256(); parts.forEach { h.update(data: $0) }; return Data(h.finalize())
    }
    static func hmac(_ key: Data, _ msg: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }
    /// Noise の HKDF（RFC 5869 と同じ値。空の ikm でも動くよう HMAC で書く）。
    static func noiseHKDF(_ ck: Data, _ ikm: Data, _ count: Int) -> [Data] {
        let t = hmac(ck, ikm)
        let o1 = hmac(t, Data([0x01]))
        let o2 = hmac(t, o1 + Data([0x02]))
        return count == 2 ? [o1, o2] : [o1, o2, hmac(t, o2 + Data([0x03]))]
    }
    /// 新しい X25519 の秘密鍵（raw 32B）。
    static func newPrivateKey() -> Data { Curve25519.KeyAgreement.PrivateKey().rawRepresentation }
    static func publicKey(_ priv: Data) throws -> Data {
        guard let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv) else { throw TunnelV3Error.invalidKey }
        return k.publicKey.rawRepresentation
    }
    static func dh(_ priv: Data, _ peer: Data) throws -> Data {
        guard let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv),
              let p = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer),
              let ss = try? k.sharedSecretFromKeyAgreement(with: p) else { throw TunnelV3Error.invalidKey }
        let out = ss.withUnsafeBytes { Data($0) }
        guard out != Data(count: 32) else { throw TunnelV3Error.dhZero }
        return out
    }
    /// Noise の ChaChaPoly nonce: 0 が 4 バイト + n の 64 ビット little-endian。
    static func noiseNonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        var le = n.littleEndian
        return try! ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: &le) { Data($0) })
    }

    struct Symmetric {
        var ck: Data
        var h: Data
        var k: Data?
        var n: UInt64 = 0
        init() {
            let name = Data(TunnelV3.protocolName.utf8)   // 36 バイト > 32 なので SHA-256
            h = name.count <= 32 ? name + Data(count: 32 - name.count) : TunnelV3.sha256(name)
            ck = h
        }
        mutating func mixHash(_ d: Data) { h = TunnelV3.sha256(h, d) }
        mutating func mixKey(_ ikm: Data) { let o = TunnelV3.noiseHKDF(ck, ikm, 2); ck = o[0]; k = o[1]; n = 0 }
        mutating func mixKeyAndHash(_ ikm: Data) {
            let o = TunnelV3.noiseHKDF(ck, ikm, 3); ck = o[0]; mixHash(o[1]); k = o[2]; n = 0
        }
        mutating func encryptAndHash(_ pt: Data) throws -> Data {
            guard let k else { throw TunnelV3Error.invalidMessage }
            let box = try ChaChaPoly.seal(pt, using: SymmetricKey(data: k), nonce: TunnelV3.noiseNonce(n), authenticating: h)
            let ct = Data(box.ciphertext + box.tag)
            n += 1; mixHash(ct); return ct
        }
        mutating func decryptAndHash(_ ct: Data) throws -> Data {
            guard let k, ct.count >= 16 else { throw TunnelV3Error.decryptionFailed }
            let ct = Data(ct)
            guard let box = try? ChaChaPoly.SealedBox(nonce: TunnelV3.noiseNonce(n), ciphertext: ct.dropLast(16), tag: ct.suffix(16)),
                  let pt = try? ChaChaPoly.open(box, using: SymmetricKey(data: k), authenticating: h) else {
                throw TunnelV3Error.decryptionFailed
            }
            n += 1; mixHash(ct); return pt
        }
        /// (k_c2s, k_s2c)
        func split() -> (Data, Data) { let o = TunnelV3.noiseHKDF(ck, Data(), 2); return (o[0], o[1]) }
    }

    // --- 端末（initiator）。Bridge では使わないが、テストと paseo-health-check の写しのために持つ ---
    struct Initiator {
        var st = Symmetric()
        let sPriv: Data, ePriv: Data, peerStatic: Data, psk: Data
        init(staticPriv: Data, bridgeStaticPub: Data, psk: Data, ephemeralPriv: Data? = nil) throws {
            sPriv = staticPriv; peerStatic = bridgeStaticPub; self.psk = psk
            ePriv = ephemeralPriv ?? Curve25519.KeyAgreement.PrivateKey().rawRepresentation
            st.mixHash(TunnelV3.prologue); st.mixHash(bridgeStaticPub)
        }
        /// msg1 = (e, s, p)。
        mutating func writeMessage1(payload: Data) throws -> (e: Data, s: Data, p: Data) {
            let e = try TunnelV3.publicKey(ePriv)
            st.mixHash(e); st.mixKey(e)
            st.mixKey(try TunnelV3.dh(ePriv, peerStatic))          // es
            let s = try st.encryptAndHash(try TunnelV3.publicKey(sPriv))
            st.mixKey(try TunnelV3.dh(sPriv, peerStatic))          // ss
            let p = try st.encryptAndHash(payload)
            return (e, s, p)
        }
        /// msg2 を読む。戻り値は payload2 と (k_c2s, k_s2c, h)。
        mutating func readMessage2(e: Data, p: Data) throws -> (payload: Data, c2s: Data, s2c: Data, hash: Data) {
            guard e.count == 32 else { throw TunnelV3Error.invalidMessage }
            st.mixHash(e); st.mixKey(e)
            st.mixKey(try TunnelV3.dh(ePriv, e))                    // ee
            st.mixKey(try TunnelV3.dh(sPriv, e))                    // se
            st.mixKeyAndHash(psk)
            let payload = try st.decryptAndHash(p)
            let (c2s, s2c) = st.split()
            return (payload, c2s, s2c, st.h)
        }
    }

    // --- Bridge（responder） ---
    struct Responder {
        var st = Symmetric()
        let sPriv: Data, ePriv: Data
        var peerEphemeral = Data(), peerStatic = Data()
        init(staticPriv: Data, ephemeralPriv: Data? = nil) throws {
            sPriv = staticPriv
            ePriv = ephemeralPriv ?? Curve25519.KeyAgreement.PrivateKey().rawRepresentation
            st.mixHash(TunnelV3.prologue); st.mixHash(try TunnelV3.publicKey(staticPriv))
        }
        /// msg1 を読む。戻り値は (端末の静的公開鍵, payload1)。ここではまだ何も信用しない（§10.1）。
        mutating func readMessage1(e: Data, s: Data, p: Data) throws -> (deviceStaticPub: Data, payload: Data) {
            guard e.count == 32, s.count == 48 else { throw TunnelV3Error.invalidMessage }
            st.mixHash(e); st.mixKey(e)
            st.mixKey(try TunnelV3.dh(sPriv, e))                    // es
            let sPub = try st.decryptAndHash(s)
            st.mixKey(try TunnelV3.dh(sPriv, sPub))                 // ss
            let payload = try st.decryptAndHash(p)
            peerEphemeral = e; peerStatic = sPub
            return (sPub, payload)
        }
        /// msg2 を書く。psk は payload1 を読んでから決める（招待の psk か 0 が 32 バイト）。
        mutating func writeMessage2(payload: Data, psk: Data) throws -> (e: Data, p: Data, c2s: Data, s2c: Data, hash: Data) {
            let e = try TunnelV3.publicKey(ePriv)
            st.mixHash(e); st.mixKey(e)
            st.mixKey(try TunnelV3.dh(ePriv, peerEphemeral))       // ee
            st.mixKey(try TunnelV3.dh(ePriv, peerStatic))          // se
            st.mixKeyAndHash(psk)
            let p = try st.encryptAndHash(payload)
            let (c2s, s2c) = st.split()
            return (e, p, c2s, s2c, st.h)
        }
    }

    // MARK: - BuddyOS の導出（§4・§10.4.2）

    static let zeroPsk = Data(count: 32)

    /// RFC 5869 HKDF-SHA256（salt は長さ 0）。招待の ID と psk に使う。
    static func hkdf(ikm: Data, info: String, length: Int) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: Data(), info: Data(info.utf8), outputByteCount: length
        ).withUnsafeBytes { Data($0) }
    }
    static func inviteId(secret: Data) -> String { b64u(hkdf(ikm: secret, info: "buddyos/v3/invite-id", length: 16)) }
    static func invitePsk(secret: Data) -> Data { hkdf(ikm: secret, info: "buddyos/v3/invite-psk", length: 32) }
    /// `b64u(SHA256(S_d.pub)[0..16])`（22 文字）。
    static func deviceKeyId(devicePub: Data) -> String { b64u(sha256(devicePub).prefix(16)) }
    static func sasCommit(nR: Data) -> Data { sha256(Data("buddyos/v3/sas-commit".utf8), nR) }
    /// 6 桁の確認コード（`uint32_be(d[0..4]) mod 1_000_000`、0 埋め）。
    static func sasCode(handshakeHash: Data, nI: Data, nR: Data) -> String {
        let d = sha256(Data("buddyos/v3/sas".utf8), handshakeHash, nI, nR)
        let v = d.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let s = String(v % 1_000_000)
        return String(repeating: "0", count: 6 - s.count) + s
    }
    /// 端末ごとの資格情報 `bdc_` + b64u(32 バイトの乱数)。
    static func newCredential() throws -> String { "bdc_" + b64u(try randomBytes(32)) }
    /// `credHash` = 資格情報の UTF-8 の SHA-256（16 進）。Bridge はこれだけを保存する。
    static func credentialHash(_ credential: String) -> String {
        sha256(Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// OS の CSPRNG。戻り値を確かめる（§4）。
    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TunnelV3Error.randomFailed }
        return data
    }

    // MARK: - 表記（§5）

    /// base64url（パディングなし）。
    static func b64u(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// §5.1 の厳しい読み方。`[A-Za-z0-9_-]` だけ・長さ % 4 != 1・符号化し直して一致・長さの指定があればちょうど。
    static func b64uDecodeStrict(_ s: String, length: Int? = nil) -> Data? {
        guard s.utf8.allSatisfy({ isB64uByte($0) }), s.utf8.count % 4 != 1 else { return nil }
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if b64.count % 4 != 0 { b64 += String(repeating: "=", count: 4 - b64.count % 4) }
        guard let data = Data(base64Encoded: b64), b64u(data) == s else { return nil }
        if let length, data.count != length { return nil }
        return data
    }

    private static func isB64uByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
    }

    static let deviceNameFallback = "端末"
    static let bridgeNameFallback = "PC"

    /// §5.3 の名前の無害化（Unicode のスカラー値ごと。64 スカラー値で切る。正規化はしない）。
    static func sanitizeName(_ input: String, fallback: String) -> String {
        var mapped = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            let v = scalar.value
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator:
                mapped.append(" ")
                continue
            default:
                break
            }
            if (0x09...0x0D).contains(v) || v == 0x85 {
                mapped.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate:
                continue
            default:
                mapped.append(scalar)
            }
        }
        // 連続する空白を 1 つにし、前後の空白を落とす。
        var collapsed = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in mapped {
            if scalar == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            collapsed.append(scalar)
        }
        let trimmed = trimSpaces(collapsed)
        let cut = trimSpaces(String.UnicodeScalarView(trimmed.prefix(64)))
        return cut.isEmpty ? fallback : String(cut)
    }

    private static func trimSpaces(_ s: String.UnicodeScalarView) -> String.UnicodeScalarView {
        var scalars = Array(s)
        while scalars.first == " " { scalars.removeFirst() }
        while scalars.last == " " { scalars.removeLast() }
        return String.UnicodeScalarView(scalars)
    }

    /// §5.3 の表示名「<名前> · <deviceKeyId の先頭 4 文字>」。
    static func displayName(name: String, deviceKeyId: String) -> String {
        "\(name) \u{00B7} \(deviceKeyId.prefix(4))"
    }

    /// §5.4: `[A-Za-z0-9-._~]` 以外をすべて `%XX`（UTF-8、大文字の 16 進）。`+` は `%2B`、空白は `%20`。
    static func qrEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            let c = Character(Unicode.Scalar(byte))
            if (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E {
                out.append(c)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// §6 の順番のキー。
    static let qrKeys = ["v", "bridgeId", "name", "platform", "relay", "relayId", "key", "secret", "exp"]

    /// §6 のペアリングの URL（キーは §6 の表の順、値は §5.4 で符号化）。足りないキーがあれば nil。
    static func pairURL(fields: [String: String]) -> String? {
        var parts: [String] = []
        for key in qrKeys {
            guard let value = fields[key] else { return nil }
            parts.append("\(key)=\(qrEncode(value))")
        }
        return "buddyos://pair?" + parts.joined(separator: "&")
    }

    /// PC で入力された確認コード（Appendix A）。空白とハイフンを取り除き、ASCII の数字 6 桁だけを通す。
    static func normalizeCode(_ input: String) -> String? {
        let s = String(input.unicodeScalars.filter { $0 != " " && $0 != "-" })
        guard s.utf8.count == 6, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return s
    }

    /// §10.4.2: "213854" → "213 854"
    static func sasDisplay(_ code: String) -> String { "\(code.prefix(3)) \(code.dropFirst(3))" }

    /// 定数時間の比較（長さは漏れてよい値だけに使う）。
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count { diff |= lhs[i] ^ rhs[i] }
        return diff == 0
    }
}

// MARK: - ワイヤの形（§8.3〜§8.9）

extension TunnelV3 {
    /// TEXT の JSON・制御メッセージの上限（§12）。
    static let maxControlBytes = 4096
    static let maxPayloadBytes = 1024

    /// msg1（端末 → Bridge）。`e`・`s`・`p` は §5.1 の厳しい読み方で 32・48・16 以上。
    struct Message1 {
        let e: Data
        let s: Data
        let p: Data

        enum ParseError: Error { case notInit, version, badMessage }

        /// TEXT 1 通を読む。`buddyos_tunnel_init` でなければ notInit（読み捨てる）、v が 3 でなければ version。
        static func parse(_ text: String) throws -> Message1 {
            guard text.utf8.count <= maxControlBytes,
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  obj["type"] as? String == "buddyos_tunnel_init" else { throw ParseError.notInit }
            guard let v = obj["v"] as? Int, v == 3, !(obj["v"] is Bool) else { throw ParseError.version }
            guard let es = obj["e"] as? String, let e = b64uDecodeStrict(es, length: 32),
                  let ss = obj["s"] as? String, let s = b64uDecodeStrict(ss, length: 48),
                  let ps = obj["p"] as? String, let p = b64uDecodeStrict(ps), p.count >= 16 else {
                throw ParseError.badMessage
            }
            return Message1(e: e, s: s, p: p)
        }
    }

    /// msg2 の TEXT（`buddyos_tunnel_hello`）。
    static func helloText(e: Data, p: Data) -> String {
        "{\"type\":\"buddyos_tunnel_hello\",\"v\":3,\"e\":\"\(b64u(e))\",\"p\":\"\(b64u(p))\"}"
    }

    /// msg2 を送れないときの平文のエラー（§8.9。認証されていない）。
    enum PlainError: String { case version, inviteInvalid = "invite_invalid", badMessage = "bad_message", rateLimited = "rate_limited" }
    static func errorText(_ code: PlainError) -> String {
        "{\"type\":\"buddyos_tunnel_error\",\"v\":3,\"code\":\"\(code.rawValue)\"}"
    }

    enum Mode: String { case connect, pair, approve }

    /// payload1（§8.6）。
    struct Payload1: Equatable {
        let mode: Mode
        let deviceId: String
        let name: String?
        let platform: String
        let app: String?
        let invite: String?

        static let platforms: Set<String> = ["ios", "android", "mac", "windows"]

        /// 形が違えば nil（`bad_request`）。名前はここでは無害化しない（Bridge が §5.3 で行う）。
        static func parse(_ data: Data) -> Payload1? {
            guard data.count <= maxPayloadBytes,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modeRaw = obj["mode"] as? String, let mode = Mode(rawValue: modeRaw),
                  let deviceId = obj["deviceId"] as? String, isClientDeviceId(deviceId),
                  let platform = obj["platform"] as? String, platforms.contains(platform) else { return nil }
            let name = obj["name"] as? String
            let app = (obj["app"] as? String).map { String($0.prefix(32)) }
            let invite = obj["invite"] as? String
            if mode == .pair || mode == .approve { guard name != nil else { return nil } }
            if mode == .pair {
                guard let invite, invite.utf8.count == 22, b64uDecodeStrict(invite, length: 16) != nil else { return nil }
            }
            return Payload1(mode: mode, deviceId: deviceId, name: name, platform: platform, app: app, invite: invite)
        }

        /// 形の違う payload1 でも mode が pair と読めるなら、その招待 ID（16 バイトの b64u でなければ nil）。
        /// pair でなければ nil（外側の nil）。招待が使えればその psk で `bad_request` を返し、使えなければ平文の
        /// `invite_invalid` にする（spec/PROTOCOL-v3.md §8.10。Windows の Bridge と同じ）。
        static func pairInviteOfMalformed(_ data: Data) -> String?? {
            guard data.count <= maxPayloadBytes,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["mode"] as? String == Mode.pair.rawValue else { return nil }
            guard let invite = obj["invite"] as? String, invite.utf8.count == 22,
                  b64uDecodeStrict(invite, length: 16) != nil else { return .some(nil) }
            return .some(invite)
        }

        /// `^[A-Za-z0-9._-]{8,80}$`
        static func isClientDeviceId(_ s: String) -> Bool {
            let n = s.utf8.count
            return n >= 8 && n <= 80 && s.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                    || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
            }
        }
    }

    /// payload2 の `error`（§8.8）。
    enum Refusal: String {
        case unknownDevice = "unknown_device", revoked, badRequest = "bad_request"
        case approvalUnavailable = "approval_unavailable", busy, rateLimited = "rate_limited"
        case tooManyDevices = "too_many_devices", bridgeError = "bridge_error"
    }

    /// payload2（Bridge → 端末）。キーの順はベクタと同じ（ok・bridgeId・name・platform・deviceKeyId・commit）。
    static func payload2OK(bridgeId: String, name: String, platform: String, deviceKeyId: String, commit: Data? = nil) -> Data {
        var parts = ["\"ok\":true", "\"bridgeId\":\(jsonString(bridgeId))", "\"name\":\(jsonString(name))",
                     "\"platform\":\(jsonString(platform))", "\"deviceKeyId\":\(jsonString(deviceKeyId))"]
        if let commit { parts.append("\"commit\":\"\(b64u(commit))\"") }
        return Data(("{" + parts.joined(separator: ",") + "}").utf8)
    }
    static func payload2Refusal(_ error: Refusal) -> Data {
        Data("{\"ok\":false,\"error\":\"\(error.rawValue)\"}".utf8)
    }

    /// JSON の文字列リテラル（JSONSerialization で 1 つだけ符号化する）。
    static func jsonString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    /// トンネルの中の制御メッセージ（§10.1.1 の表）。知らない `type` は読めない扱い。
    enum Control: Equatable {
        case open
        case pairConfirm
        case approveNonce(Data)
        case pairedAck
        case pairCancel

        /// c2s の制御メッセージを読む。JSON でない・4096 バイトを超える・知らない type・`n` が 32 バイトでないものは nil。
        static func parse(_ data: Data) -> Control? {
            guard data.count <= maxControlBytes,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { return nil }
            switch type {
            case "open": return .open
            case "pair_confirm": return .pairConfirm
            case "paired_ack": return .pairedAck
            case "pair_cancel": return .pairCancel
            case "approve_nonce":
                guard let n = obj["n"] as? String, let nd = b64uDecodeStrict(n, length: 32) else { return nil }
                return .approveNonce(nd)
            default: return nil
            }
        }
    }

    /// s2c の制御メッセージ。
    static func approveReveal(nR: Data) -> Data { Data("{\"type\":\"approve_reveal\",\"n\":\"\(b64u(nR))\"}".utf8) }
    static let approvalWaiting = Data("{\"type\":\"approval_waiting\"}".utf8)
    static func pairRejected(_ reason: String) -> Data { Data("{\"type\":\"pair_rejected\",\"reason\":\"\(reason)\"}".utf8) }

    struct PairedBridge {
        let bridgeId: String
        let name: String
        let platform: String
        let relayId: String
        let relayURL: String
    }
    /// `paired`（キーの順はベクタと同じ）。
    static func paired(deviceKeyId: String, credential: String, bridge: PairedBridge) -> Data {
        let b = "{\"bridgeId\":\(jsonString(bridge.bridgeId)),\"name\":\(jsonString(bridge.name)),\"platform\":\(jsonString(bridge.platform)),\"relayId\":\(jsonString(bridge.relayId)),\"relayURL\":\(jsonString(bridge.relayURL))}"
        return Data("{\"type\":\"paired\",\"deviceKeyId\":\(jsonString(deviceKeyId)),\"credential\":\(jsonString(credential)),\"bridge\":\(b)}".utf8)
    }
}
