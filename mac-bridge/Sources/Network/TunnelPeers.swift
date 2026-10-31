import Foundation

/// トンネル経由の TCP の出どころの表（spec/PROTOCOL-v3.md §13.1）。
/// Bridge 自身が 127.0.0.1:<待ち受けの番号> へつなぐ TCP の「ローカル側の番号」→ どの端末のトンネルか。
/// Vapor は要求の送り元（`req.remoteAddress` の番号）でこの表を引く。表に無ければ「この PC の中から」。
/// 入れるのは `open` を確かめた後・最初のバイトを流す前、外すのはローカルの TCP を閉じる前。
final class TunnelPeers: @unchecked Sendable {
    static let shared = TunnelPeers()

    /// 認証済みの枠（connect の接続。§12）。
    static let maxTotal = 128
    static let maxPerDevice = 48

    struct Peer: Equatable {
        let deviceKeyId: String
        let connectionId: String
    }

    private let lock = NSLock()
    private var byPort: [UInt16: Peer] = [:]
    /// 枠の予約（TCP をつなぐ前に取る。connectionId → deviceKeyId）。
    private var reserved: [String: String] = [:]

    init() {}

    /// connect の枠を取る（128 本・1 台 48 本）。取れなければ false（開かない）。
    func reserve(connectionId: String, deviceKeyId: String) -> Bool {
        lock.withLock {
            guard reserved[connectionId] == nil else { return true }
            guard reserved.count < Self.maxTotal,
                  reserved.values.filter({ $0 == deviceKeyId }).count < Self.maxPerDevice else { return false }
            reserved[connectionId] = deviceKeyId
            return true
        }
    }

    func release(connectionId: String) {
        lock.withLock { _ = reserved.removeValue(forKey: connectionId) }
    }

    /// 表に入れる。同じ番号が既にあれば（起こらないはずだが）古い方の connectionId を返す（呼び出し側が閉じる）。
    @discardableResult
    func register(localPort: UInt16, peer: Peer) -> Peer? {
        lock.withLock {
            let old = byPort[localPort]
            byPort[localPort] = peer
            return old == peer ? nil : old
        }
    }

    /// 表から外す（その番号がこの接続のものだったときだけ）。
    func remove(localPort: UInt16, connectionId: String) {
        lock.withLock {
            if byPort[localPort]?.connectionId == connectionId { byPort.removeValue(forKey: localPort) }
        }
    }

    /// 送り元の番号で引く。
    func peer(remotePort: UInt16) -> Peer? { lock.withLock { byPort[remotePort] } }

    /// その端末のトンネルが今いくつ開いているか（DevicesView の `online`）。
    func count(deviceKeyId: String) -> Int { lock.withLock { byPort.values.filter { $0.deviceKeyId == deviceKeyId }.count } }

    var total: Int { lock.withLock { byPort.count } }
}
