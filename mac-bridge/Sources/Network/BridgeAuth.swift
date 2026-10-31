import Foundation
import Vapor

/// 誰からの要求か（spec/PROTOCOL-v3.md §13.2）。
///   - `.local`: この PC の中から直接（デスクトップ・hook・channel）。ローカル鍵（~/.buddyos/api-key）で認証。
///   - `.device`: Paseo のトンネル経由。その端末の `bdc_` だけで認証。
enum Principal: Equatable {
    case local
    case device(deviceKeyId: String, device: DeviceStore.Device)

    var deviceKeyId: String? {
        if case .device(let id, _) = self { return id }
        return nil
    }
}

/// ローカル鍵（今の `api-key`）。作り直しがあるので起動時の値を閉じ込めず、毎回ここから読む（§13.2）。
final class LocalKey: @unchecked Sendable {
    static let shared = LocalKey()

    private let lock = NSLock()
    private var value: String?

    func current() -> String {
        lock.withLock {
            if let value { return value }
            let v = KeyStore.loadOrCreateAPIKey()
            value = v
            return v
        }
    }

    /// 作り直したローカル鍵に差し替える（resetIdentity）。テストでは決まった値を入れる。
    func replace(_ key: String) { lock.withLock { value = key } }

    /// 次の読み取りでファイルから読み直す。
    func invalidate() { lock.withLock { value = nil } }
}

/// 管理鍵 `bda_…`（spec/PROTOCOL-v3.md Appendix A）。デスクトップが Bridge を起動するたびに stdin で 1 行だけ渡す。
/// どこにも保存しない（メモリだけ）。起動時に 1 回だけ入る。
final class AdminKey: @unchecked Sendable {
    static let shared = AdminKey()

    private let lock = NSLock()
    private var value: String?

    /// `^bda_[A-Za-z0-9_-]{43}$`
    static func isWellFormed(_ s: String) -> Bool {
        guard s.hasPrefix("bda_") else { return false }
        let rest = s.utf8.dropFirst(4)
        return rest.count == 43 && rest.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    /// 1 回だけ入る。形が違えば入れない。
    @discardableResult
    func set(_ key: String) -> Bool {
        guard Self.isWellFormed(key) else { return false }
        return lock.withLock {
            guard value == nil else { return false }
            value = key
            return true
        }
    }

    var isAvailable: Bool { lock.withLock { value != nil } }

    func matches(_ presented: String) -> Bool {
        guard let v = lock.withLock({ value }) else { return false }
        return TunnelV3.constantTimeEquals(v, presented)
    }

    /// テスト用。
    func resetForTesting(_ key: String? = nil) { lock.withLock { value = key } }
}

/// トンネルの中と、この PC の中からの要求の認証（spec/PROTOCOL-v3.md §13）。
enum BridgeAuth {
    /// 要求の出どころ（§13.1）。
    enum Origin: Equatable {
        case local
        case tunnel(TunnelPeers.Peer)
    }

    /// 送り元の住所が 127.0.0.1 でなければ nil（断る）。番号が TunnelPeers にあればトンネル経由。
    static func origin(_ req: Request, peers: TunnelPeers = .shared) -> Origin? {
        guard let remote = req.remoteAddress, remote.ipAddress == "127.0.0.1",
              let port = remote.port, let p = UInt16(exactly: port) else { return nil }
        if let peer = peers.peer(remotePort: p) { return .tunnel(peer) }
        return .local
    }

    /// ルートの種類（§13.3 の表）。
    enum RouteClass: Equatable {
        /// `.local` も `.device` も。`allowQuery` のときは `?apiKey=` も受け付ける。
        case any(allowQuery: Bool)
        case localOnly
        /// `/local/*`: `.local` ＋管理鍵。ヘッダだけ。
        case admin
        case deviceOnly
        /// `/antigravity/hook`: ターンごとのトークン（ルートが確かめる）。トンネル経由は 403。
        case hookToken
        /// `/mcp`: mainagent のセッションごとの合鍵 `bmt_`（McpEndpoint が Orchestrator で確かめる）。
        /// 呼ぶのはこの PC の中の CLI だけなので、トンネル経由は 403。
        case mainAgentToken
        /// プレビューのセッションで認証するルート（ルートが作った Principal と照らし合わせる）。
        case previewSession
    }

    /// パスから表の行を引く。表に無いルートは nil（404）。
    static func classify(_ path: String) -> RouteClass? {
        let raw = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let c = raw.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let first = c.first else { return nil }
        switch first {
        case "health", "status":
            return c.count == 1 ? .any(allowQuery: true) : nil
        case "ws":
            return c.count == 3 && c[1] == "agent" ? .any(allowQuery: true) : nil
        case "terminal":
            if c.count == 2 && c[1] == "pty" { return .any(allowQuery: true) }
            // 開いているペインを見る口（docs/PANE_SHARE_2026-10-25.md）。host は常駐プロセスがつなぐ口なので、この PC の中だけ。
            if c.count == 2 && c[1] == "share" { return .any(allowQuery: true) }
            if c.count == 3 && c[1] == "share" && c[2] == "panes" { return .any(allowQuery: false) }
            if c.count == 3 && c[1] == "share" && c[2] == "host" { return .localOnly }
            if c.count == 3 && (c[1] == "keys" || c[1] == "panes") && c[2] == "poll" { return .localOnly }
            if c.count == 2 && c[1] == "pane-event" { return .localOnly }
            return nil
        case "files":
            return c.count >= 2 ? .any(allowQuery: true) : nil
        case "preview":
            guard c.count >= 2 else { return nil }
            switch c[1] {
            case "session", "targets": return c.count == 2 ? .any(allowQuery: false) : nil
            case "ui": return c.count == 2 ? .previewSession : nil
            case "sim":
                guard c.count == 3 else { return nil }
                if ["stream", "tap", "swipe"].contains(c[2]) { return .previewSession }
                if ["frame", "home", "text"].contains(c[2]) { return .any(allowQuery: false) }
                return nil
            case "w": return c.count >= 3 ? .previewSession : nil
            case "web": return c.count >= 3 ? .any(allowQuery: false) : nil
            default: return nil
            }
        case "livez", "push-test":
            return c.count == 1 ? .localOnly : nil
        case "traffic":
            return c.count == 1 || (c.count == 2 && c[1] == "reset") ? .localOnly : nil
        case "claude":
            return c.count >= 2 ? .localOnly : nil
        case "codex":
            return c.count == 2 && c[1] == "terminal" ? .localOnly : nil
        case "antigravity":
            return c.count == 2 && c[1] == "hook" ? .hookToken : nil
        case "mcp":
            return c.count == 1 ? .mainAgentToken : nil
        case "local":
            return c.count >= 2 ? .admin : nil
        case "device":
            return c.count >= 2 ? .deviceOnly : nil
        default:
            return nil
        }
    }

    /// 断る理由と本文（§13.4。理由は細かく出さない）。
    enum Denial: Error, Equatable {
        case unauthorized, localOnly, deviceOnly, forbidden, adminUnavailable, notFound

        var status: HTTPResponseStatus {
            switch self {
            case .unauthorized: return .unauthorized
            case .notFound: return .notFound
            default: return .forbidden
            }
        }
        var code: String {
            switch self {
            case .unauthorized: return "unauthorized"
            case .localOnly: return "local_only"
            case .deviceOnly: return "device_only"
            case .forbidden: return "forbidden"
            case .adminUnavailable: return "admin_unavailable"
            case .notFound: return "not_found"
            }
        }
        var response: Response {
            Response(status: status,
                     headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                     body: .init(string: "{\"error\":\"\(code)\"}"))
        }
    }

    /// 提示された資格情報（`Authorization: Bearer` と、許すときは `?apiKey=`）。両方あって値が違えば mismatch。
    static func credential(_ req: Request, allowQuery: Bool) -> (value: String?, mismatch: Bool) {
        let header = req.headers.bearerAuthorization?.token
        guard allowQuery, let query = try? req.query.get(String.self, at: "apiKey") else { return (header, false) }
        if let header { return (header, header != query) }
        return (query, false)
    }

    /// §13.2 の principal(req)。
    static func principal(_ req: Request, allowQuery: Bool = true, peers: TunnelPeers = .shared,
                          devices: DeviceStore = .shared, localKey: LocalKey = .shared) -> Principal? {
        guard let origin = origin(req, peers: peers) else { return nil }
        let (cred, mismatch) = credential(req, allowQuery: allowQuery)
        guard !mismatch, let cred, !cred.isEmpty else { return nil }
        switch origin {
        case .tunnel(let peer):
            guard let row = devices.verify(deviceKeyId: peer.deviceKeyId, credential: cred) else { return nil }
            return .device(deviceKeyId: peer.deviceKeyId, device: row)
        case .local:
            guard !cred.hasPrefix("bdc_"), TunnelV3.constantTimeEquals(cred, localKey.current()) else { return nil }
            return .local
        }
    }

    /// 表の行ごとの確かめ。通るなら nil。
    static func denial(_ req: Request, _ cls: RouteClass, peers: TunnelPeers = .shared,
                       devices: DeviceStore = .shared, localKey: LocalKey = .shared, admin: AdminKey = .shared) -> Denial? {
        guard let origin = origin(req, peers: peers) else { return .unauthorized }
        switch cls {
        case .any(let allowQuery):
            return principal(req, allowQuery: allowQuery, peers: peers, devices: devices, localKey: localKey) == nil ? .unauthorized : nil
        case .localOnly:
            if case .tunnel = origin { return .localOnly }
            return principal(req, allowQuery: true, peers: peers, devices: devices, localKey: localKey) == nil ? .unauthorized : nil
        case .deviceOnly:
            if case .local = origin { return .deviceOnly }
            return principal(req, allowQuery: true, peers: peers, devices: devices, localKey: localKey) == nil ? .unauthorized : nil
        case .admin:
            if case .tunnel = origin { return .localOnly }
            if !req.headers[.origin].isEmpty { return .forbidden }
            if (try? req.query.get(String.self, at: "apiKey")) != nil { return .unauthorized }
            guard principal(req, allowQuery: false, peers: peers, devices: devices, localKey: localKey) == .local else {
                return .unauthorized
            }
            guard admin.isAvailable else { return .adminUnavailable }
            guard let presented = req.headers.first(name: "X-BuddyOS-Admin"), admin.matches(presented) else {
                return .unauthorized
            }
            return nil
        case .hookToken:
            if case .tunnel = origin { return .localOnly }
            return nil
        case .mainAgentToken:
            if case .tunnel = origin { return .localOnly }
            // 合鍵はヘッダ（Authorization: Bearer）だけ。?apiKey= は受けない（ログや履歴に残る）。
            if (try? req.query.get(String.self, at: "apiKey")) != nil { return .unauthorized }
            return nil
        case .previewSession:
            return nil
        }
    }

    // MARK: - ルートの中で使う

    @discardableResult
    static func requireAny(_ req: Request, allowQuery: Bool = true) throws -> Principal {
        if let d = denial(req, .any(allowQuery: allowQuery)) { throw Abort(d.status, reason: d.code) }
        guard let p = principal(req, allowQuery: allowQuery) else { throw Abort(.unauthorized, reason: "unauthorized") }
        return p
    }

    static func requireLocal(_ req: Request) throws {
        if let d = denial(req, .localOnly) { throw Abort(d.status, reason: d.code) }
    }

    static func requireAdmin(_ req: Request) throws {
        if let d = denial(req, .admin) { throw Abort(d.status, reason: d.code) }
    }

    static func requireDevice(_ req: Request) throws -> (deviceKeyId: String, device: DeviceStore.Device) {
        if let d = denial(req, .deviceOnly) { throw Abort(d.status, reason: d.code) }
        guard case .device(let id, let row) = principal(req) else { throw Abort(.unauthorized, reason: "unauthorized") }
        return (id, row)
    }

    /// プレビューのセッションの照合に使う出どころの名前（`local` か deviceKeyId）。
    static func previewCreator(_ req: Request) -> String? {
        switch origin(req) {
        case .local: return "local"
        case .tunnel(let peer): return peer.deviceKeyId
        case nil: return nil
        }
    }

    static func creatorName(_ p: Principal) -> String { p.deviceKeyId ?? "local" }

    /// アプリ全体にかける middleware。BridgeRequestGuard の後ろに置く。表に無いルートは認証の前に 404。
    struct Middleware: AsyncMiddleware {
        func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
            guard let cls = BridgeAuth.classify(request.url.path) else { return Denial.notFound.response }
            if let d = BridgeAuth.denial(request, cls) { return d.response }
            return try await next.respond(to: request)
        }
    }
}
