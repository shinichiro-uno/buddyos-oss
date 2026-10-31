import XCTest
@testable import BridgeApp

/// 承認（PC で 6 桁を入力。spec/PROTOCOL-v3.md §10.4・Appendix A）。
final class ApprovalQueueTests: XCTestCase {
    private var now: Int64 = 1_789_000_000_000

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _ended: [String: ApprovalQueue.EndReason] = [:]
        private var _approved: [String] = []
        private var _approvedBy: [String: String?] = [:]
        func end(_ id: String, _ r: ApprovalQueue.EndReason) { lock.withLock { _ended[id] = r } }
        func approve(_ id: String, by: String?) { lock.withLock { _approved.append(id); _approvedBy[id] = by } }
        var ended: [String: ApprovalQueue.EndReason] { lock.withLock { _ended } }
        var approved: [String] { lock.withLock { _approved } }
        var approvedBy: [String: String?] { lock.withLock { _approvedBy } }
    }

    private func make() -> ApprovalQueue { ApprovalQueue(now: { [unowned self] in self.now }) }

    @discardableResult
    private func add(_ q: ApprovalQueue, _ key: String, code: String, box: Box, remote: Bool = false,
                     outcome: ApprovalQueue.ApproveOutcome = .ok(display: "d")) -> ApprovalQueue.Pending? {
        q.add(deviceKeyId: key, display: "\(key) · xxxx", name: "iPhone", platform: "ios", sameNameExists: false,
              remote: remote, code: code, approve: { box.approve(key, by: $0); return outcome }, end: { box.end(key, $0) })
    }

    func testWindowGatesRequests() {
        let q = make()
        XCTAssertEqual(q.precheck(deviceKeyId: "K1", approvalsEnabled: true), .approvalUnavailable, "窓が閉じている")
        let until = q.openWindow()
        XCTAssertEqual(until, now + ApprovalQueue.windowMs)
        XCTAssertNil(q.precheck(deviceKeyId: "K1", approvalsEnabled: true))
        XCTAssertEqual(q.precheck(deviceKeyId: "K1", approvalsEnabled: false), .approvalUnavailable, "承認の設定（approvalsEnabled）が切れている")
        now += 5 * 60 * 1000
        XCTAssertEqual(q.openWindow(), now + ApprovalQueue.windowMs, "開き直すと延びる")
        now += ApprovalQueue.windowMs
        XCTAssertEqual(q.precheck(deviceKeyId: "K1", approvalsEnabled: true), .approvalUnavailable)
    }

    func testThreePendingAndOnePerDevice() {
        let q = make(); q.openWindow()
        let box = Box()
        XCTAssertNotNil(add(q, "K1", code: "111111", box: box))
        XCTAssertEqual(q.precheck(deviceKeyId: "K1", approvalsEnabled: true), .busy)
        XCTAssertNil(add(q, "K1", code: "111112", box: box))
        XCTAssertNotNil(add(q, "K2", code: "222222", box: box))
        XCTAssertNotNil(add(q, "K3", code: "333333", box: box))
        XCTAssertEqual(q.precheck(deviceKeyId: "K4", approvalsEnabled: true), .busy)
        XCTAssertNil(add(q, "K4", code: "444444", box: box))
    }

    /// 回数は approve_nonce で数える（1 台 1 時間 3 回・全体 1 時間 20 回）。precheck は数えない。
    func testRateLimitCountsOnlyNonces() {
        let q = make(); q.openWindow()
        for _ in 0..<10 { XCTAssertNil(q.precheck(deviceKeyId: "K1", approvalsEnabled: true)) }
        XCTAssertTrue(q.countAttempt(deviceKeyId: "K1"))
        XCTAssertTrue(q.countAttempt(deviceKeyId: "K1"))
        XCTAssertTrue(q.countAttempt(deviceKeyId: "K1"))
        XCTAssertFalse(q.countAttempt(deviceKeyId: "K1"))
        XCTAssertEqual(q.precheck(deviceKeyId: "K1", approvalsEnabled: true), .rateLimited)
        for i in 0..<17 { XCTAssertTrue(q.countAttempt(deviceKeyId: "G\(i)")) }
        XCTAssertFalse(q.countAttempt(deviceKeyId: "G-new"), "全体で 1 時間 20 回")
        now += 60 * 60 * 1000
        XCTAssertTrue(q.countAttempt(deviceKeyId: "K1"))
    }

    /// 承認待ちが 2 件あるときに片方の番号を入力 → その 1 件だけが許可される。
    func testMatchingCodeApprovesOnlyThatRequest() async {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "111111", box: box)
        add(q, "K2", code: "222222", box: box)
        let r = await q.submit(code: "222 222")
        XCTAssertEqual(r, .ok(deviceKeyId: "K2", display: "d"))
        XCTAssertEqual(box.approved, ["K2"])
        XCTAssertEqual(q.views().map(\.deviceKeyId), ["K1"])
        XCTAssertTrue(box.ended.isEmpty)
    }

    /// 違う番号を 3 回 → 3 回目で全部 code_mismatch で取り下げ、窓が閉じる。remaining は 2・1。
    func testThreeMismatchesCancelAll() async {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "111111", box: box)
        add(q, "K2", code: "222222", box: box)
        let a = await q.submit(code: "000000")
        let b = await q.submit(code: "000001")
        XCTAssertEqual(a, .mismatch(remaining: 2))
        XCTAssertEqual(b, .mismatch(remaining: 1))
        let bad = await q.submit(code: "２１３８５４")
        XCTAssertEqual(bad, .badCode, "6 桁の数字でないものは間違いに数えない")
        let c = await q.submit(code: "000002")
        XCTAssertEqual(c, .mismatch(remaining: 0))
        XCTAssertEqual(box.ended, ["K1": .codeMismatch, "K2": .codeMismatch])
        XCTAssertNil(q.windowOpenUntil)
        let none = await q.submit(code: "111111")
        XCTAssertEqual(none, .noPending)
    }

    func testRejectBlocksDeviceFor24h() {
        let q = make(); q.openWindow()
        let box = Box()
        let p = add(q, "K1", code: "111111", box: box)!
        XCTAssertTrue(q.reject(pendingId: p.pendingId))
        XCTAssertEqual(box.ended["K1"], .rejected)
        XCTAssertEqual(q.precheck(deviceKeyId: "K1", approvalsEnabled: true), .rateLimited)
        now += ApprovalQueue.rejectedMs
        q.openWindow()
        XCTAssertNil(q.precheck(deviceKeyId: "K1", approvalsEnabled: true))
    }

    /// 途中で「すべての端末を切断」→ reset で取り下げ。
    func testResetCancelsPending() {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "111111", box: box)
        q.resetAll()
        XCTAssertEqual(box.ended["K1"], .reset)
        XCTAssertTrue(q.views().isEmpty)
    }

    func testCloseWindowAndTimeout() {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "111111", box: box)
        now += ApprovalQueue.pendingLifetimeMs
        q.expire()
        XCTAssertEqual(box.ended["K1"], .timeout)
        add(q, "K2", code: "222222", box: box)
        q.closeWindow()
        XCTAssertEqual(box.ended["K2"], .closed)
    }

    func testDeviceGoneIsReported() async {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "111111", box: box, outcome: .deviceGone)
        let r = await q.submit(code: "111111")
        XCTAssertEqual(r, .deviceGone)
    }

    /// DevicesView の JSON に確認コード（6 桁）がどこにも入っていない。
    func testDevicesViewHasNoCode() throws {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "987654", box: box)
        let dir = try makeTempDir("devices-view")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceStore(directory: { dir })
        store.load()
        let view = LocalDeviceRoutes.devicesView(devices: store, approvals: q, invites: PairingInvites(), peers: TunnelPeers())
        let data = try JSONSerialization.data(withJSONObject: view)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("987654"))
        XCTAssertFalse(text.contains("987 654"))
        XCTAssertEqual((view["pending"] as? [[String: Any]])?.count, 1)
        XCTAssertNotNil(view["bootId"] as? String)
    }

    // MARK: - スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）

    /// 窓が閉じていても、スマホでの許可が使えれば remote として受け付ける。使えなければ approval_unavailable。
    func testRemoteAdmissionWhenWindowClosed() {
        let q = make()
        XCTAssertEqual(q.admit(deviceKeyId: "K1", approvalsEnabled: true, remoteAvailable: false), .refused(.approvalUnavailable))
        XCTAssertEqual(q.admit(deviceKeyId: "K1", approvalsEnabled: true, remoteAvailable: true), .remote)
        XCTAssertNil(q.precheck(deviceKeyId: "K1", approvalsEnabled: true, remoteAvailable: true))
        XCTAssertEqual(q.admit(deviceKeyId: "K1", approvalsEnabled: false, remoteAvailable: true), .refused(.approvalUnavailable),
                       "承認の設定（approvalsEnabled）が切れていればスマホでも受け付けない")
        q.openWindow()
        XCTAssertEqual(q.admit(deviceKeyId: "K1", approvalsEnabled: true, remoteAvailable: true), .window, "窓が開いていれば今までどおり")
        q.closeWindow()
        let box = Box()
        XCTAssertNil(add(q, "K1", code: "111111", box: box), "窓が閉じていれば remote でない申し込みは作れない")
        XCTAssertEqual(add(q, "K1", code: "111111", box: box, remote: true)?.remote, true)
    }

    /// remote は全体で 1 時間 6 件まで（approve_nonce で数える）。窓の申し込みはこの数に入らない。
    func testRemoteGlobalLimit() {
        let q = make()
        for i in 0..<ApprovalQueue.remoteGlobalPerHour { XCTAssertTrue(q.countAttempt(deviceKeyId: "R\(i)", remote: true)) }
        XCTAssertFalse(q.countAttempt(deviceKeyId: "R-new", remote: true))
        XCTAssertEqual(q.admit(deviceKeyId: "R-new", approvalsEnabled: true, remoteAvailable: true), .refused(.rateLimited))
        q.openWindow()
        XCTAssertEqual(q.admit(deviceKeyId: "R-new", approvalsEnabled: true, remoteAvailable: true), .window)
        XCTAssertTrue(q.countAttempt(deviceKeyId: "R-new"), "窓の申し込みは remote の上限に入らない")
        now += 60 * 60 * 1000
        XCTAssertTrue(q.countAttempt(deviceKeyId: "R-later", remote: true))
    }

    /// 窓を閉じて取り下げるのは remote でない申し込みだけ。remote は期限で終わる。
    func testCloseWindowKeepsRemote() {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "111111", box: box)
        add(q, "K2", code: "222222", box: box, remote: true)
        q.closeWindow()
        XCTAssertEqual(box.ended, ["K1": .closed])
        XCTAssertEqual(q.views().map(\.deviceKeyId), ["K2"])
        XCTAssertEqual(q.views().first?.remote, true)
        now += ApprovalQueue.pendingLifetimeMs
        q.expire()
        XCTAssertEqual(box.ended["K2"], .timeout)
    }

    /// スマホからの許可を切った: remote の申し込みだけ closed で取り下げる。
    func testCloseRemoteEndsOnlyRemote() {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "111111", box: box)
        add(q, "K2", code: "222222", box: box, remote: true)
        q.closeRemote()
        XCTAssertEqual(box.ended, ["K2": .closed])
        XCTAssertEqual(q.views().map(\.deviceKeyId), ["K1"])
    }

    /// 窓が閉じているときの間違いの数: 承認待ちが 0 件になったら 0 に戻る。3 回で全部 code_mismatch。
    func testRemoteMismatchCounter() async {
        let q = make()
        let box = Box()
        add(q, "K1", code: "111111", box: box, remote: true)
        let a = await q.submit(code: "000000", approvedBy: "PHONE")
        let b = await q.submit(code: "000001")
        XCTAssertEqual(a, .mismatch(remaining: 2))
        XCTAssertEqual(b, .mismatch(remaining: 1), "PC とスマホの入力は同じ数に入る")
        // 1 件が終わって承認待ちが 0 件 → 数が 0 に戻る。
        now += ApprovalQueue.pendingLifetimeMs
        q.expire()
        add(q, "K2", code: "222222", box: box, remote: true)
        add(q, "K3", code: "333333", box: box, remote: true)
        let c = await q.submit(code: "000002")
        XCTAssertEqual(c, .mismatch(remaining: 2))
        _ = await q.submit(code: "000003")
        let d = await q.submit(code: "000004")
        XCTAssertEqual(d, .mismatch(remaining: 0))
        XCTAssertEqual(box.ended["K2"], .codeMismatch)
        XCTAssertEqual(box.ended["K3"], .codeMismatch)
        XCTAssertTrue(q.views().isEmpty)
    }

    /// 窓が閉じても remote の承認待ちが残っていれば、間違いの数は続く。
    func testCloseWindowKeepsCounterWhileRemoteRemains() async {
        let q = make(); q.openWindow()
        let box = Box()
        add(q, "K1", code: "111111", box: box, remote: true)
        _ = await q.submit(code: "000000")
        q.closeWindow()
        let r = await q.submit(code: "000001")
        XCTAssertEqual(r, .mismatch(remaining: 1))
    }

    /// スマホで入力したときは approvedBy が承認の処理に渡る。PC なら nil。
    func testSubmitPassesApprovedBy() async {
        let q = make()
        let box = Box()
        add(q, "K1", code: "111111", box: box, remote: true)
        add(q, "K2", code: "222222", box: box, remote: true)
        let r1 = await q.submit(code: "111111", approvedBy: "PHONE")
        XCTAssertEqual(r1, .ok(deviceKeyId: "K1", display: "d"))
        let r2 = await q.submit(code: "222222")
        XCTAssertEqual(r2, .ok(deviceKeyId: "K2", display: "d"))
        XCTAssertEqual(box.approvedBy["K1"], .some("PHONE"))
        XCTAssertEqual(box.approvedBy["K2"], .some(nil))
    }
}
