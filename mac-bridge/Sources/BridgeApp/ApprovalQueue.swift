import Foundation

/// アカウントで見つけた PC への承認（spec/PROTOCOL-v3.md §10.4・Appendix A）。
/// 「端末を追加」の窓（10 分。開き直すと延びる）、承認待ち（同時 3 件・1 台 1 件・5 分）、回数（approve_nonce で数える。
/// 1 台 1 時間 3 回・全体 1 時間 20 回）、拒否した端末（24 時間）、PC での番号の照合と間違いの数（窓 1 回で 3 回）。
/// どれもメモリだけ。確認コードは承認待ちの中にだけ持ち、一覧（DevicesView）には出さない。
///
/// スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）: 窓が閉じていても、スマホでの許可が使えるなら
/// 受け付ける（remote の申し込み）。remote は全体で 1 時間 6 件まで。窓を閉じても取り下げない（5 分・入力・拒否・切断・reset で終わる）。
final class ApprovalQueue: @unchecked Sendable {
    static let shared = ApprovalQueue()

    static let windowMs: Int64 = 10 * 60 * 1000
    static let pendingLifetimeMs: Int64 = 5 * 60 * 1000
    static let maxPending = 3
    static let perDevicePerHour = 3
    static let globalPerHour = 20
    static let rejectedMs: Int64 = 24 * 60 * 60 * 1000
    static let maxMismatches = 3
    /// remote の申し込みだけの上限（全体で 1 時間。approve_nonce で数える）。
    static let remoteGlobalPerHour = 6
    private static let hourMs: Int64 = 60 * 60 * 1000

    /// 承認待ちが終わった理由（`pair_rejected.reason`）。
    enum EndReason: String { case rejected, timeout, codeMismatch = "code_mismatch", closed, reset }

    /// PC で番号が一致したときに、トンネル側が `paired` を送れたか。
    enum ApproveOutcome: Equatable { case ok(display: String), deviceGone }

    /// msg1 を受け付けるか。窓が開いていれば `window`、窓が閉じていてスマホでの許可で受け付けるなら `remote`。
    enum Admission: Equatable {
        case window
        case remote
        case refused(TunnelV3.Refusal)
    }

    final class Pending: @unchecked Sendable {
        let pendingId: String
        let deviceKeyId: String
        let display: String
        let name: String
        let platform: String
        let requestedAt: Int64
        let expiresAt: Int64
        let sameNameExists: Bool
        /// 窓が閉じていて、スマホでの許可で受け付けた申し込み（窓を閉じても取り下げない）。
        let remote: Bool
        fileprivate let code: String
        /// 番号が合ったときに呼ぶ（行を pendingAck で入れて `paired` を送る）。引数は入力した端末の deviceKeyId（PC なら nil）。
        let approve: @Sendable (_ approvedBy: String?) async -> ApproveOutcome
        /// 取り下げのときに呼ぶ（トンネルは `pair_rejected` を送って閉じる）。
        let end: @Sendable (EndReason) -> Void

        init(pendingId: String, deviceKeyId: String, display: String, name: String, platform: String,
             requestedAt: Int64, expiresAt: Int64, sameNameExists: Bool, remote: Bool, code: String,
             approve: @escaping @Sendable (String?) async -> ApproveOutcome, end: @escaping @Sendable (EndReason) -> Void) {
            self.pendingId = pendingId; self.deviceKeyId = deviceKeyId; self.display = display; self.name = name
            self.platform = platform; self.requestedAt = requestedAt; self.expiresAt = expiresAt
            self.sameNameExists = sameNameExists; self.remote = remote; self.code = code; self.approve = approve; self.end = end
        }
    }

    enum SubmitResult: Equatable {
        case ok(deviceKeyId: String, display: String)
        case mismatch(remaining: Int)
        case badCode
        case noPending
        case deviceGone
    }

    private let lock = NSLock()
    private let now: () -> Int64
    private var openUntil: Int64?
    private var mismatches = 0
    private var pendings: [String: Pending] = [:]
    private var attempts: [String: [Int64]] = [:]
    private var globalAttempts: [Int64] = []
    private var remoteAttempts: [Int64] = []
    private var rejected: [String: Int64] = [:]
    /// 窓・承認待ちが変わったときに呼ぶ（DevicesView の version を進める）。
    var onChange: (@Sendable () -> Void)?

    init(now: @escaping () -> Int64 = DeviceStore.nowMs) {
        self.now = now
    }

    // MARK: - 窓

    /// 「端末を追加」の窓を開く（開いていれば今から 10 分に延ばす）。戻り値は閉じる時刻（ms）。
    @discardableResult
    func openWindow() -> Int64 {
        let t = now()
        let until = lock.withLock { () -> Int64 in
            if !isOpenLocked(at: t) { mismatches = 0 }
            openUntil = t + Self.windowMs
            return openUntil!
        }
        onChange?()
        return until
    }

    /// 窓を閉じ、窓の申し込み（remote でないもの）を `reason` で全部取り下げる（`/local/approvals/close`・管理鍵のパイプが閉じた）。
    /// remote の申し込みは残す（5 分の期限か、入力・拒否・切断・reset で終わる）。間違いの数は、残った承認待ちが無ければ 0 に戻す。
    func closeWindow(reason: EndReason = .closed) {
        let t = now()
        let ended = lock.withLock { () -> [Pending] in
            openUntil = nil
            let local = pendings.values.filter { !$0.remote }
            for p in local { pendings.removeValue(forKey: p.pendingId) }
            settleLocked(at: t)
            return Array(local)
        }
        ended.forEach { $0.end(reason) }
        onChange?()
    }

    /// remote の申し込みを全部 `reason` で取り下げる（スマホからの許可を切った・スマホからの許可の設定を切った）。
    func closeRemote(reason: EndReason = .closed) {
        let t = now()
        let ended = lock.withLock { () -> [Pending] in
            let remote = pendings.values.filter(\.remote)
            for p in remote { pendings.removeValue(forKey: p.pendingId) }
            settleLocked(at: t)
            return Array(remote)
        }
        guard !ended.isEmpty else { return }
        ended.forEach { $0.end(reason) }
        onChange?()
    }

    /// 窓が閉じる時刻（開いていなければ nil）。
    var windowOpenUntil: Int64? {
        let t = now()
        return lock.withLock { isOpenLocked(at: t) ? openUntil : nil }
    }

    private func isOpenLocked(at t: Int64) -> Bool {
        guard let until = openUntil else { return false }
        return t < until
    }

    /// 窓が閉じていて承認待ちが 0 件になったら、間違いの数を 0 に戻す（§10.4.1）。
    /// 窓が開いている間は今までどおり窓ごとに数える。
    private func settleLocked(at t: Int64) {
        if pendings.isEmpty && !isOpenLocked(at: t) { mismatches = 0 }
    }

    // MARK: - 申し込み（§10.4 の approve）

    /// msg1 を読んだときの確かめ（状態を変えない）。通るなら nil。
    /// 外した印・20 台・壊れた一覧はトンネルの側で DeviceStore を見る。
    /// `remoteAvailable` = スマホでの許可が使える（設定が有効で、許可できる端末に push の宛先がある。§10.4.1）。
    func precheck(deviceKeyId: String, approvalsEnabled: Bool, remoteAvailable: Bool = false) -> TunnelV3.Refusal? {
        if case .refused(let r) = admit(deviceKeyId: deviceKeyId, approvalsEnabled: approvalsEnabled,
                                        remoteAvailable: remoteAvailable) { return r }
        return nil
    }

    /// precheck と同じ確かめをして、窓の申し込みか remote の申し込みかを返す（状態を変えない）。
    func admit(deviceKeyId: String, approvalsEnabled: Bool, remoteAvailable: Bool) -> Admission {
        let t = now()
        return lock.withLock {
            guard approvalsEnabled else { return .refused(.approvalUnavailable) }
            let remote = !isOpenLocked(at: t)
            if remote && !remoteAvailable { return .refused(.approvalUnavailable) }
            if let at = rejected[deviceKeyId], t - at < Self.rejectedMs { return .refused(.rateLimited) }
            pruneAttemptsLocked(at: t)
            if (attempts[deviceKeyId]?.count ?? 0) >= Self.perDevicePerHour || globalAttempts.count >= Self.globalPerHour
                || (remote && remoteAttempts.count >= Self.remoteGlobalPerHour) {
                return .refused(.rateLimited)
            }
            if pendings.count >= Self.maxPending || pendings.values.contains(where: { $0.deviceKeyId == deviceKeyId }) {
                return .refused(.busy)
            }
            return remote ? .remote : .window
        }
    }

    /// 端末で 24 時間以内に拒否したか（approve の msg1 の判定用）。
    func isRejected(_ deviceKeyId: String) -> Bool {
        let t = now()
        return lock.withLock { rejected[deviceKeyId].map { t - $0 < Self.rejectedMs } ?? false }
    }

    /// `approve_nonce` を受けたときに数える（その deviceKeyId と全体の両方。remote なら remote の全体も）。上限を超えたら false。
    func countAttempt(deviceKeyId: String, remote: Bool = false) -> Bool {
        let t = now()
        return lock.withLock {
            pruneAttemptsLocked(at: t)
            guard (attempts[deviceKeyId]?.count ?? 0) < Self.perDevicePerHour, globalAttempts.count < Self.globalPerHour,
                  !remote || remoteAttempts.count < Self.remoteGlobalPerHour else {
                return false
            }
            attempts[deviceKeyId, default: []].append(t)
            globalAttempts.append(t)
            if remote { remoteAttempts.append(t) }
            return true
        }
    }

    private func pruneAttemptsLocked(at t: Int64) {
        globalAttempts.removeAll { t - $0 >= Self.hourMs }
        remoteAttempts.removeAll { t - $0 >= Self.hourMs }
        for (k, v) in attempts {
            let kept = v.filter { t - $0 < Self.hourMs }
            attempts[k] = kept.isEmpty ? nil : kept
        }
        rejected = rejected.filter { t - $0.value < Self.rejectedMs }
    }

    /// 承認待ちを作る（lock の中でもう一度、数と同じ端末を確かめる）。だめなら nil（`busy`）。
    /// `remote` の申し込みは窓が閉じていても作れる。
    func add(deviceKeyId: String, display: String, name: String, platform: String, sameNameExists: Bool,
             remote: Bool = false, code: String, approve: @escaping @Sendable (String?) async -> ApproveOutcome,
             end: @escaping @Sendable (EndReason) -> Void) -> Pending? {
        let t = now()
        guard let rand = try? TunnelV3.randomBytes(9) else { return nil }
        let pending = Pending(pendingId: "p_" + TunnelV3.b64u(rand), deviceKeyId: deviceKeyId, display: display,
                              name: name, platform: platform, requestedAt: t, expiresAt: t + Self.pendingLifetimeMs,
                              sameNameExists: sameNameExists, remote: remote, code: code, approve: approve, end: end)
        let added: Bool = lock.withLock {
            guard remote || isOpenLocked(at: t), pendings.count < Self.maxPending,
                  !pendings.values.contains(where: { $0.deviceKeyId == deviceKeyId }) else { return false }
            pendings[pending.pendingId] = pending
            return true
        }
        guard added else { return nil }
        onChange?()
        return pending
    }

    /// 端末が先に切った・`pair_cancel`・トンネルの時間切れなど、トンネルの側で終わったとき。
    func remove(pendingId: String) {
        let t = now()
        let removed = lock.withLock { () -> Bool in
            guard pendings.removeValue(forKey: pendingId) != nil else { return false }
            settleLocked(at: t)
            return true
        }
        if removed { onChange?() }
    }

    /// まだ待っているか（トンネルの側の時間切れの判定用）。
    func contains(pendingId: String) -> Bool { lock.withLock { pendings[pendingId] != nil } }

    /// 5 分たった承認待ちを `timeout` で取り下げる。
    func expire() {
        let t = now()
        let ended = lock.withLock { () -> [Pending] in
            let old = pendings.values.filter { t >= $0.expiresAt }
            for p in old { pendings.removeValue(forKey: p.pendingId) }
            if !old.isEmpty { settleLocked(at: t) }
            return Array(old)
        }
        guard !ended.isEmpty else { return }
        ended.forEach { $0.end(.timeout) }
        onChange?()
    }

    // MARK: - PC・スマホでの操作（Appendix A・§13.5）

    /// 入力された番号を、待っている承認待ち（最大 3 件）と 1 件ずつ定数時間で比べ、一致したものだけを許可する。
    /// `approvedBy` はスマホで入力したときのその端末の deviceKeyId（PC なら nil）。間違いの数は PC とスマホで同じ数に入れる。
    func submit(code input: String, approvedBy: String? = nil) async -> SubmitResult {
        guard let code = TunnelV3.normalizeCode(input) else { return .badCode }
        let t = now()
        enum Step { case none, match(Pending), mismatch(Int, [Pending]) }
        let step: Step = lock.withLock {
            let live = pendings.values.filter { t < $0.expiresAt }
            guard !live.isEmpty else { return .none }
            var found: Pending?
            for p in live.sorted(by: { $0.requestedAt < $1.requestedAt }) {
                if TunnelV3.constantTimeEquals(p.code, code), found == nil { found = p }
            }
            if let found {
                pendings.removeValue(forKey: found.pendingId)
                settleLocked(at: t)
                return .match(found)
            }
            mismatches += 1
            let remaining = max(0, Self.maxMismatches - mismatches)
            guard remaining == 0 else { return .mismatch(remaining, []) }
            let all = Array(pendings.values)
            pendings.removeAll()
            openUntil = nil
            mismatches = 0
            return .mismatch(0, all)
        }
        switch step {
        case .none:
            return .noPending
        case .mismatch(let remaining, let ended):
            ended.forEach { $0.end(.codeMismatch) }
            onChange?()
            return .mismatch(remaining: remaining)
        case .match(let p):
            onChange?()
            switch await p.approve(approvedBy) {
            case .ok(let display): return .ok(deviceKeyId: p.deviceKeyId, display: display)
            case .deviceGone: return .deviceGone
            }
        }
    }

    /// PC で拒否する。その deviceKeyId を 24 時間断る。
    func reject(pendingId: String) -> Bool {
        let t = now()
        let p: Pending? = lock.withLock {
            guard let p = pendings.removeValue(forKey: pendingId) else { return nil }
            rejected[p.deviceKeyId] = t
            settleLocked(at: t)
            return p
        }
        guard let p else { return false }
        p.end(.rejected)
        onChange?()
        return true
    }

    /// 「すべての端末を切断」などで `epoch` が変わった（§10.1）。
    func resetAll() {
        let t = now()
        let ended = lock.withLock { () -> [Pending] in
            let all = Array(pendings.values)
            pendings.removeAll()
            settleLocked(at: t)
            return all
        }
        ended.forEach { $0.end(.reset) }
        if !ended.isEmpty { onChange?() }
    }

    /// DevicesView の `pending`（番号は入れない）。
    func views() -> [Pending] {
        let t = now()
        return lock.withLock { pendings.values.filter { t < $0.expiresAt }.sorted { $0.requestedAt < $1.requestedAt } }
    }
}
