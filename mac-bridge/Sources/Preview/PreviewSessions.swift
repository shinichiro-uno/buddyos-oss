import Foundation
import Crypto

/// プレビューで表示するもの。`/preview/session` の `target`（"sim:<udid>" / "web:<port>"）。
enum PreviewTarget: Equatable, Sendable {
    case sim(udid: String)
    case web(port: Int)

    /// "sim:<udid>"（udid は UUID の形）/ "web:<port>"（1〜65535）だけを受け付ける。udid は大文字にそろえる。
    init?(param raw: String) {
        if raw.hasPrefix("sim:") {
            guard let udid = SimController.normalizedUDID(String(raw.dropFirst("sim:".count))) else { return nil }
            self = .sim(udid: udid)
        } else if raw.hasPrefix("web:") {
            let digits = raw.dropFirst("web:".count)
            guard !digits.isEmpty, digits.count <= 5, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let port = Int(digits), port > 0, port < 65536 else { return nil }
            self = .web(port: port)
        } else {
            return nil
        }
    }

    var param: String {
        switch self {
        case .sim(let udid): return "sim:\(udid)"
        case .web(let port): return "web:\(port)"
        }
    }
}

/// プレビューのセッション。apiKey とは別の、1 つの表示対象だけに効く合言葉。
/// Bridge のメモリにだけ持つ。使うたびに延び、使わずに idleTTL、作ってから absoluteTTL で無効になる。
final class PreviewSessionStore: @unchecked Sendable {
    static let shared = PreviewSessionStore()

    /// 使わずにこの秒数たったら無効。プレビューを開いたまま置いておいても、戻って触れる長さにする。
    static let idleTTL: TimeInterval = 2 * 60 * 60
    static let absoluteTTL: TimeInterval = 12 * 60 * 60
    static let maxSessions = 64

    private struct Entry {
        let target: PreviewTarget
        /// 作った Principal（"local" か deviceKeyId）。
        let creator: String
        let createdAt: Date
        var lastUsedAt: Date
    }

    private let lock = NSLock()
    /// キーはセッションの SHA-256（16 進）。照合で値そのものを比べない（時間差で当てられないように）。
    private var entries: [String: Entry] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 新しいセッションを作る。返り値は base64url の 43 文字。
    func create(target: PreviewTarget, creator: String = "local") -> String {
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Base64URL.encode(Data($0)) }
        let t = now()
        lock.withLock {
            purgeLocked(at: t)
            if entries.count >= Self.maxSessions,
               let oldest = entries.min(by: { $0.value.lastUsedAt < $1.value.lastUsedAt })?.key {
                entries.removeValue(forKey: oldest)
            }
            entries[Self.digest(token)] = Entry(target: target, creator: creator, createdAt: t, lastUsedAt: t)
        }
        return token
    }

    /// セッションが生きていれば、その表示対象を返す（使った時刻を更新する）。
    /// `creator` を渡したときは、要求の出どころ（TunnelPeers で引いた deviceKeyId、無ければ "local"）が
    /// セッションを作った Principal と同じときだけ返す。
    func target(for token: String?, creator: String?) -> PreviewTarget? {
        guard let creator else { return nil }
        return target(for: token, matching: creator)
    }

    func target(for token: String?) -> PreviewTarget? { target(for: token, matching: nil) }

    private func target(for token: String?, matching creator: String?) -> PreviewTarget? {
        guard let token, Self.isWellFormed(token) else { return nil }
        let t = now()
        return lock.withLock {
            let key = Self.digest(token)
            guard var e = entries[key] else { return nil }
            if let creator, e.creator != creator { return nil }
            guard t.timeIntervalSince(e.lastUsedAt) <= Self.idleTTL,
                  t.timeIntervalSince(e.createdAt) <= Self.absoluteTTL else {
                entries.removeValue(forKey: key)
                return nil
            }
            e.lastUsedAt = t
            entries[key] = e
            return e.target
        }
    }

    var count: Int { lock.withLock { entries.count } }

    /// 端末を外したら、その端末のセッションを全部捨てる。
    func removeAll(creator: String) {
        lock.withLock { entries = entries.filter { $0.value.creator != creator } }
    }

    /// 「すべての端末を切断」では全部捨てる。
    func removeAll() {
        lock.withLock { entries.removeAll() }
    }

    private func purgeLocked(at t: Date) {
        entries = entries.filter {
            t.timeIntervalSince($0.value.lastUsedAt) <= Self.idleTTL
                && t.timeIntervalSince($0.value.createdAt) <= Self.absoluteTTL
        }
    }

    /// base64url の 43 文字だけ（パスやクエリに紛れた別の文字列を照合に回さない）。
    static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == 43 && token.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
