import Foundation

/// QR・リンクに載せる 1 回きりの招待（spec/PROTOCOL-v3.md §4・§6・§10.3）。
/// Bridge のメモリにだけ持つ（再起動で消える）。10 分・同時に 3 つまで（4 つ目で一番古いものを捨てる）。
/// 使われたら、その端末（deviceKeyId）のやり直しにだけ使える。失敗の回数では消さない（§12）。
final class PairingInvites: @unchecked Sendable {
    static let shared = PairingInvites()

    static let lifetimeMs: Int64 = 10 * 60 * 1000
    static let maxInvites = 3

    struct UsedBy: Equatable {
        let deviceKeyId: String
        let display: String
        let at: Int64
    }

    struct Invite {
        let inviteId: String
        let secret: Data
        let psk: Data
        let createdAt: Int64
        let expiresAt: Int64
        var usedBy: UsedBy?
    }

    struct Created: Equatable {
        let inviteId: String
        let secret: Data
        let expiresAt: Int64
    }

    private let lock = NSLock()
    private var invites: [String: Invite] = [:]
    private let now: () -> Int64
    /// 招待が変わったときに呼ぶ（DevicesView の version を進める）。
    var onChange: (@Sendable () -> Void)?

    init(now: @escaping () -> Int64 = DeviceStore.nowMs) {
        self.now = now
    }

    /// 新しい招待を作る。4 つ目なら一番古いものを捨てる。
    func create() throws -> Created {
        let secret = try TunnelV3.randomBytes(32)
        let t = now()
        let id = TunnelV3.inviteId(secret: secret)
        let invite = Invite(inviteId: id, secret: secret, psk: TunnelV3.invitePsk(secret: secret),
                            createdAt: t, expiresAt: t + Self.lifetimeMs, usedBy: nil)
        lock.withLock {
            purgeLocked(at: t)
            while invites.count >= Self.maxInvites,
                  let oldest = invites.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                invites.removeValue(forKey: oldest)
            }
            invites[id] = invite
        }
        onChange?()
        return Created(inviteId: id, secret: secret, expiresAt: invite.expiresAt)
    }

    /// pair の msg1 で招待を引く。期限内で、まだ使われていないか、この deviceKeyId が使ったものなら psk を返す。
    func psk(inviteId: String, deviceKeyId: String) -> Data? {
        let t = now()
        return lock.withLock {
            guard let inv = invites[inviteId], t < inv.expiresAt else { return nil }
            if let used = inv.usedBy, used.deviceKeyId != deviceKeyId { return nil }
            return inv.psk
        }
    }

    /// `pair_confirm` を受けたとき（lock の中で確かめ直す）。招待に「この deviceKeyId が使った・時刻」を記録する。
    func markUsed(inviteId: String, deviceKeyId: String, display: String) -> Bool {
        let t = now()
        let ok: Bool = lock.withLock {
            guard var inv = invites[inviteId], t < inv.expiresAt else { return false }
            if let used = inv.usedBy, used.deviceKeyId != deviceKeyId { return false }
            inv.usedBy = UsedBy(deviceKeyId: deviceKeyId, display: display, at: t)
            invites[inviteId] = inv
            return true
        }
        if ok { onChange?() }
        return ok
    }

    /// 取り消す（`DELETE /local/pairing/invites/:id`、メニューバーで QR を隠したとき）。
    @discardableResult
    func cancel(inviteId: String) -> Bool {
        let removed = lock.withLock { invites.removeValue(forKey: inviteId) != nil }
        if removed { onChange?() }
        return removed
    }

    /// 全部捨てる（「すべての端末を切断」など）。
    func clear() {
        let had = lock.withLock { () -> Bool in
            let had = !invites.isEmpty
            invites.removeAll()
            return had
        }
        if had { onChange?() }
    }

    func invite(_ inviteId: String) -> Invite? { lock.withLock { invites[inviteId] } }

    /// 期限内の招待（作った順）。
    func active() -> [Invite] {
        let t = now()
        return lock.withLock {
            purgeLocked(at: t)
            return invites.values.sorted { $0.createdAt < $1.createdAt }
        }
    }

    private func purgeLocked(at t: Int64) {
        invites = invites.filter { t < $0.value.expiresAt }
    }

    /// §6 の URL。値は §5.4 で符号化し、キーは表の順。`exp` は UNIX 秒。
    static func pairURL(bridgeId: String, name: String, platform: String, relayURL: String, relayId: String,
                        bridgePub: String, secret: Data, expiresAtMs: Int64) -> String {
        TunnelV3.pairURL(fields: [
            "v": "3",
            "bridgeId": bridgeId,
            "name": name,
            "platform": platform,
            "relay": relayURL,
            "relayId": relayId,
            "key": bridgePub,
            "secret": TunnelV3.b64u(secret),
            "exp": String(expiresAtMs / 1000),
        ])!
    }
}
