import Foundation
import Crypto
import IOKit

enum KeyStore {
    private static var configDir: URL {
        // テスト中は一時フォルダ（BuddyPaths）。本物の device-token / bridge-id を書き換えない。
        let dir = BuddyPaths.root
        // 配下に api-key / e2e-key / device-token などが並ぶので、ディレクトリごと owner-only (0700) にする。
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        _ = configDirRestricted
        return dir
    }

    /// createDirectory の attributes は既存ディレクトリには効かない。過去バージョンが
    /// 0755 で作った ~/.buddyos も、プロセスごとに 1 回だけ 0700 に矯正する。
    private static let configDirRestricted: Void = {
        let dir = BuddyPaths.root
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }()

    private static var apiKeyURL: URL { configDir.appendingPathComponent("api-key") }
    private static var bridgeIdURL: URL { configDir.appendingPathComponent("bridge-id") }
    private static var paseoRelayIdURL: URL { configDir.appendingPathComponent("paseo-relay-id") }
    private static var deviceTokenURL: URL { configDir.appendingPathComponent("device-token") }

    /// App-scoped, per-login identity survives a regenerated bridge ID. Never send
    /// the hardware UUID itself or merge machines merely by their display name.
    /// The salt `cool.buddyos.registry.v1` is a protocol constant shared with the Windows Bridge.
    /// It deliberately does NOT follow `BUDDYOS_ID_PREFIX`: changing it would make every
    /// registered computer look like a new one to the registry.
    static func registryMachineId() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              !value.isEmpty else { return nil }
        return SHA256.hash(data: Data("cool.buddyos.registry.v1:\(value):\(NSUserName())".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func loadOrCreateAPIKey() -> String {
        if let data = try? Data(contentsOf: apiKeyURL),
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            // 過去バージョンが 0644 で書いた鍵ファイルもここで 0600 に矯正する。
            restrictPermissions(at: apiKeyURL)
            return key
        }
        let key = randomToken(bytes: 32)
        try? writeSecret(Data(key.utf8), to: apiKeyURL)
        return key
    }

    /// ローカル鍵を作り直す（移行・「すべての端末を切断」。spec/PROTOCOL-v3.md Appendix A）。
    /// v3 ではこの PC の中のアプリ専用の鍵で、トンネル越しでは使えない。
    @discardableResult
    static func regenerateAPIKey() -> String {
        let key = randomToken(bytes: 32)
        do { try writeSecret(Data(key.utf8), to: apiKeyURL) } catch {
            WebSocketServer.wslog("api-key write FAILED: \(error)")
        }
        return key
    }

    /// owner-only (0600)。apiKey は Bridge への唯一の資格情報なので、
    /// 他ユーザー/同期ツールから読める権限では置かない。
    /// 新規の書き込みは writeSecret が最初から 0600 で作るので、ここは既存ファイルの矯正用。
    static func restrictPermissions(at url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            // 失敗すると 0644 のまま残るので、黙って握り潰さない。
            WebSocketServer.wslog("restrictPermissions FAILED \(url.lastPathComponent): \(error)")
        }
    }

    /// 秘密ファイルを最初から 0600 で書く。Data.write(.atomic) は umask に従った権限
    /// （通常 0644）の新しい inode に置き換えるため、後から chmod するまでの間、同じ Mac の
    /// 他ユーザーに読める窓ができる。同じディレクトリに O_EXCL + 0600 で一時ファイルを作り、
    /// fsync してから rename する（書きかけで e2e-key 等が壊れることもない）。
    static func writeSecret(_ data: Data, to url: URL) throws {
        let tmpPath = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        // O_CLOEXEC: spawn する CLI エージェントに fd を漏らさない。
        let fd = open(tmpPath, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let synced: Bool = data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return fsync(fd) == 0
        }
        let writeErrno = errno
        close(fd)
        guard synced else {
            unlink(tmpPath)
            throw POSIXError(POSIXErrorCode(rawValue: writeErrno) ?? .EIO)
        }
        guard rename(tmpPath, url.path) == 0 else {
            let renameErrno = errno
            unlink(tmpPath)
            throw POSIXError(POSIXErrorCode(rawValue: renameErrno) ?? .EIO)
        }
    }

    static func bridgeId() -> String? {
        if let data = try? Data(contentsOf: bridgeIdURL),
           let id = String(data: data, encoding: .utf8), !id.isEmpty {
            return id
        }
        return nil
    }

    /// api-key と同様に、無ければ生成して永続化する。
    /// これが無いと desktop 側の computePairings が bridgeId 欠如で空を返し、
    /// ペアリング QR が一切出ない（新規インストール時に bridge-id が作られず
    /// "unknown" になっていた実機バグの修正）。
    static func loadOrCreateBridgeId() -> String {
        if let id = bridgeId() { return id }
        let id = "mac-bridge-\(UUID().uuidString.lowercased())"
        // ここを通る＝既存の ID を読めなかった、ということ。1台の Mac に対し
        // 117 行が溜まったときは、この分岐が間欠的に発火していながら記録が
        // 一切残らず、原因を特定できなかった。次に起きたら即座に分かるよう、
        // 読めなかった事実とファイルの状態を必ず残す。
        let path = bridgeIdURL.path
        let exists = FileManager.default.fileExists(atPath: path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        WebSocketServer.wslog(
            "bridge-id regenerated (existing unreadable): exists=\(exists) size=\(size.map(String.init) ?? "nil") new=\(id.prefix(24))…"
        )
        setBridgeId(id)
        return id
    }

    static func setBridgeId(_ id: String) {
        do {
            try writeSecret(Data(id.utf8), to: bridgeIdURL)
        } catch {
            // 書けなければ次回も新しい ID を振ることになり、登録行が増え続ける。
            // 黙って失敗させない。
            WebSocketServer.wslog("bridge-id write FAILED: \(error)")
            return
        }
        // 書けたつもりで書けていない状態を残さないよう、読み戻して確認する。
        if bridgeId() != id {
            WebSocketServer.wslog("bridge-id write verify FAILED (read-back mismatch)")
        }
    }

    /// Long-lived heartbeat credential, minted once by /device-token while the
    /// user is signed in. It is what keeps this Mac discoverable after the Clerk
    /// session lapses, so it is the bridge's most sensitive file after api-key:
    /// owner-only, and cleared the moment the server says it is no longer valid.
    static func deviceToken() -> String? {
        guard let data = try? Data(contentsOf: deviceTokenURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        restrictPermissions(at: deviceTokenURL)
        return token
    }

    /// 書けたかを返す。ローテーションで受け取った新トークンを保存できなかったのに
    /// 「更新した」とみなすと、旧トークンの猶予が切れた時点で 401 になるため。
    @discardableResult
    static func setDeviceToken(_ token: String) -> Bool {
        do {
            try writeSecret(Data(token.utf8), to: deviceTokenURL)
            return true
        } catch {
            WebSocketServer.wslog("device-token write FAILED: \(error)")
            return false
        }
    }

    /// Drop a token the server rejected. Registration then falls back to the
    /// Clerk path and mints a fresh one, rather than retrying a dead credential.
    static func clearDeviceToken() {
        try? FileManager.default.removeItem(at: deviceTokenURL)
    }

    /// Paseo relay が Mac の control socket と iPhone の client socket を結び付ける
    /// 不透明な serverId。資格情報そのものではないが、推測不能な値を永続化して
    /// Bridge 再起動後も既存 QR がそのまま使えるようにする。
    static func loadOrCreatePaseoRelayId() -> String {
        if let data = try? Data(contentsOf: paseoRelayIdURL),
           let text = String(data: data, encoding: .utf8) {
            let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return createPaseoRelayId() }
            restrictPermissions(at: paseoRelayIdURL)
            return id
        }
        return createPaseoRelayId()
    }

    private static func createPaseoRelayId() -> String {
        let id = randomToken(bytes: 32)
        try? writeSecret(Data(id.utf8), to: paseoRelayIdURL)
        return id
    }

    /// 中継の ID を作り直す（静的鍵と同じとき。spec/PROTOCOL-v3.md §4）。
    @discardableResult
    static func regeneratePaseoRelayId() -> String { createPaseoRelayId() }

    /// bridgeId を作り直す（account_removed・machine_changed・アカウントから外されたとき・409）。
    @discardableResult
    static func regenerateBridgeId() -> String {
        let id = "mac-bridge-\(UUID().uuidString.lowercased())"
        setBridgeId(id)
        return id
    }

    /// 実効リスニングポートを ~/.buddyos/bridge.port に書き出す（発見用）。
    /// dev(8764)/prod(8765) が分離済みでも、退避やカスタム env で実ポートが変わりうるため、
    /// クライアント/ツールが「今どのポートか」を1ファイルで引けるようにする。
    private static var bridgePortURL: URL { configDir.appendingPathComponent("bridge.port") }
    /// この Bridge が待ち受けている番号（writeBridgePort で覚える）。Bridge が起動した CLI の hook の宛先に使う。
    nonisolated(unsafe) static var currentPort: Int?
    static func writeBridgePort(_ port: Int) {
        currentPort = port
        try? String(port).data(using: .utf8)?.write(to: bridgePortURL, options: [.atomic])
    }
    static func clearBridgePort() {
        try? FileManager.default.removeItem(at: bridgePortURL)
    }
    /// 中身が指定ポートのときだけ消す。~/.buddyos は dev(8764)/prod(8765) 等の別インスタンスと
    /// 共有なので、無条件に消すと生きている相手が書いたポートまで失われ、hook が死んだポートへ向かう。
    static func clearBridgePort(ifEquals port: Int) {
        guard let s = try? String(contentsOf: bridgePortURL, encoding: .utf8),
              Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) == port else { return }
        try? FileManager.default.removeItem(at: bridgePortURL)
    }

    /// Bridge を 1 つだけにする鍵のファイル（InstanceLock が flock する）。
    static var instanceLockURL: URL { configDir.appendingPathComponent("bridge.lock") }

    /// 動いている Bridge のプロセス番号（~/.buddyos/bridge.pid）。デスクトップアプリが
    /// 「すでに動いている Bridge」を見つけるのに使う（番号は bridge.port）。
    private static var bridgePidURL: URL { configDir.appendingPathComponent("bridge.pid") }
    static func writeBridgePid(_ pid: Int32) {
        try? String(pid).data(using: .utf8)?.write(to: bridgePidURL, options: [.atomic])
    }
    /// 中身が自分のときだけ消す（鍵を取れなかった 2 つ目の Bridge が、持ち主の分を消さないように）。
    static func clearBridgePid(ifEquals pid: Int32) {
        guard let s = try? String(contentsOf: bridgePidURL, encoding: .utf8),
              Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) == pid else { return }
        try? FileManager.default.removeItem(at: bridgePidURL)
    }

    private static func randomToken(bytes: Int) -> String {
        // SecRandomCopyBytes の戻り値を確かめる。失敗したら CryptoKit の乱数（OS の CSPRNG）で作る。
        let data = (try? TunnelV3.randomBytes(bytes))
            ?? SymmetricKey(size: SymmetricKeySize(bitCount: bytes * 8)).withUnsafeBytes { Data($0) }
        return TunnelV3.b64u(data)
    }

    // MARK: - E2E 暗号化（spec/PROTOCOL-v3.md §4）

    static var e2eKeyURL: URL { configDir.appendingPathComponent("e2e-key") }

    /// `e2e-key` の読み取りの結果。
    /// 無い・壊れているときだけ作り直してよい。権限・I/O の失敗では作り直さない。
    enum E2EKeyRead: Equatable {
        case ok(Data)
        case missing
        case corrupt
        case io(Int32)
    }

    static func readE2EKey(at url: URL? = nil) -> E2EKeyRead {
        let path = (url ?? e2eKeyURL).path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            let err = errno
            return err == ENOENT ? .missing : .io(err)
        }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let n = read(fd, &bytes, bytes.count)
            if n < 0 {
                if errno == EINTR { continue }
                let err = errno
                close(fd)
                return .io(err)
            }
            if n == 0 { break }
            data.append(contentsOf: bytes[0..<n])
            if data.count > 4096 { break }
        }
        close(fd)
        guard let text = String(data: data, encoding: .utf8),
              let key = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.count == 32,
              (try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: key)) != nil else { return .corrupt }
        restrictPermissions(at: url ?? e2eKeyURL)
        return .ok(key)
    }

    private static let e2eKeyLock = NSLock()
    nonisolated(unsafe) private static var cachedE2EKey: Data?

    /// Bridge の静的 X25519 秘密鍵（raw 32B）。起動時の確かめ（prepareIdentityV3）か作り直しが入れた値。
    /// 読めない間（key_io）は nil で、トンネルは張らない。ここでは作り直さない。
    static func e2eKey() -> Data? {
        e2eKeyLock.lock()
        defer { e2eKeyLock.unlock() }
        if let cachedE2EKey { return cachedE2EKey }
        if case .ok(let key) = readE2EKey() {
            cachedE2EKey = key
            return key
        }
        return nil
    }

    /// 静的鍵を作り直して書く（移行・作り直し・無い / 壊れているとき）。キャッシュも差し替える。
    @discardableResult
    static func regenerateE2EKey() throws -> Data {
        let key = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        try writeSecret(Data(key.base64EncodedString().utf8), to: e2eKeyURL)
        e2eKeyLock.lock()
        cachedE2EKey = key
        e2eKeyLock.unlock()
        return key
    }

    /// キャッシュを捨てる（テスト・読み直し）。
    static func invalidateE2EKeyCache() {
        e2eKeyLock.lock()
        cachedE2EKey = nil
        e2eKeyLock.unlock()
    }

    /// QR / health / registry に載せる Bridge 公開鍵 (b64url, padding なし)。鍵が読めなければ空文字。
    static func e2ePublicKeyBase64URL() -> String {
        guard let priv = e2eKey(), let pub = try? E2ECrypto.publicKey(fromPrivateKey: priv) else { return "" }
        return Base64URL.encode(pub)
    }

    /// kid = SHA256(bridge_pub) 先頭 8 バイト hex（spec/PROTOCOL-v3.md §4）。NSE は kid と bid の両方で鍵を引く。
    static func e2eKid() -> String {
        guard let priv = e2eKey(), let pub = try? E2ECrypto.publicKey(fromPrivateKey: priv) else { return "" }
        return SHA256.hash(data: pub).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// base64url (RFC 4648 §5、padding なし) の encode/decode。
/// QR / register_e2e_key の公開鍵表現は 3 実装ともこの形式で統一する（spec/PROTOCOL-v3.md §5.1）。
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var b64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 標準 base64 の padding を復元してから decode する
        if b64.count % 4 != 0 {
            b64 += String(repeating: "=", count: 4 - b64.count % 4)
        }
        return Data(base64Encoded: b64)
    }
}
