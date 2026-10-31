import XCTest
@testable import BridgeApp

/// devices.json（端末の一覧の保存）。
final class DeviceStoreTests: XCTestCase {
    private var dir: URL!
    private var now: Int64 = 1_789_000_000_000
    private var store: DeviceStore!

    override func setUpWithError() throws {
        dir = try makeTempDir("device-store")
        let d = dir!
        store = DeviceStore(directory: { d }, now: { [unowned self] in self.now })
        store.load()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func row(_ cid: String = "device-test-1", name: String = "iPhone", cred: String = "bdc_a", via: String = "qr") -> DeviceStore.Device {
        DeviceStore.Device(pub: "pub", clientDeviceId: cid, name: name, label: nil, platform: "ios",
                           credHash: TunnelV3.credentialHash(cred), via: via, createdAt: now, lastSeenAt: nil, push: nil)
    }

    private func addConfirmed(_ id: String, _ r: DeviceStore.Device) {
        XCTAssertTrue(store.insertPending(deviceKeyId: id, device: r, epoch: store.epoch))
        XCTAssertTrue(store.confirmPending(deviceKeyId: id, credHash: r.credHash, epoch: store.epoch))
    }

    func testMissingFileStartsEmptyAndWritesBackup() throws {
        XCTAssertEqual(store.lastReset?.reason, "devices_missing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("devices.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("devices.json.bak").path))
    }

    func testAddConfirmVerifyAndPendingNotWritten() throws {
        let r = row()
        XCTAssertTrue(store.insertPending(deviceKeyId: "K1", device: r, epoch: store.epoch))
        // pendingAck の行は資格情報が通らず、ファイルにも書かない。
        XCTAssertNil(store.verify(deviceKeyId: "K1", credential: "bdc_a"))
        XCTAssertEqual(store.connectDecision(deviceKeyId: "K1", clientDeviceId: "device-test-1"), .unknown)
        let reread = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        reread.load()
        XCTAssertNil(reread.device("K1"))

        XCTAssertTrue(store.confirmPending(deviceKeyId: "K1", credHash: r.credHash, epoch: store.epoch))
        XCTAssertNotNil(store.verify(deviceKeyId: "K1", credential: "bdc_a"))
        XCTAssertNil(store.verify(deviceKeyId: "K1", credential: "bdc_b"))
        XCTAssertNil(store.verify(deviceKeyId: "K1", credential: TunnelV3.credentialHash("bdc_a")), "bdc_ で始まらないものは通さない")
        XCTAssertEqual(store.connectDecision(deviceKeyId: "K1", clientDeviceId: "device-test-1"), .ok(r))
        XCTAssertEqual(store.connectDecision(deviceKeyId: "K1", clientDeviceId: "device-test-2"), .unknown)
        let reread2 = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        reread2.load()
        XCTAssertNotNil(reread2.device("K1"))
    }

    func testEpochMismatchWritesNothing() {
        let e = store.epoch
        store.resetAll(reason: "user_reset")
        XCTAssertEqual(store.epoch, e + 1)
        XCTAssertFalse(store.insertPending(deviceKeyId: "K1", device: row(), epoch: e))
        XCTAssertNil(store.device("K1"))
    }

    func testReplaceRevokeAndNinetyDays() {
        addConfirmed("K1", row(cred: "bdc_a"))
        // 同じ deviceKeyId のペアリングし直しは置き換え（古い資格情報は通らなくなる）。
        addConfirmed("K1", row(cred: "bdc_b"))
        XCTAssertNil(store.verify(deviceKeyId: "K1", credential: "bdc_a"))
        XCTAssertNotNil(store.verify(deviceKeyId: "K1", credential: "bdc_b"))

        XCTAssertTrue(store.revoke(deviceKeyId: "K1"))
        XCTAssertFalse(store.revoke(deviceKeyId: "K1"))
        XCTAssertEqual(store.connectDecision(deviceKeyId: "K1", clientDeviceId: "device-test-1"), .revoked)
        XCTAssertTrue(store.isRevoked("K1"))
        // 承認（via=approval）では外した印は消えない。QR（via=qr）で消える。
        addConfirmed("K1", row(cred: "bdc_c", via: "approval"))
        XCTAssertTrue(store.isRevoked("K1"))
        XCTAssertTrue(store.revoke(deviceKeyId: "K1"))
        addConfirmed("K1", row(cred: "bdc_d", via: "qr"))
        XCTAssertFalse(store.isRevoked("K1"))

        XCTAssertTrue(store.revoke(deviceKeyId: "K1"))
        now += DeviceStore.revokedTTLms + 1
        XCTAssertFalse(store.isRevoked("K1"), "90 日で印は消える")
        XCTAssertEqual(store.connectDecision(deviceKeyId: "K1", clientDeviceId: "device-test-1"), .unknown)
    }

    func testUnpairStateThenRemovalWithoutMark() {
        addConfirmed("K1", row())
        XCTAssertTrue(store.beginUnpair(deviceKeyId: "K1"))
        XCTAssertEqual(store.connectDecision(deviceKeyId: "K1", clientDeviceId: "device-test-1"), .revoked)
        XCTAssertNil(store.verify(deviceKeyId: "K1", credential: "bdc_a"))
        store.finishUnpair(deviceKeyId: "K1")
        XCTAssertNil(store.device("K1"))
        XCTAssertFalse(store.isRevoked("K1"), "自分で外した端末に印は残さない")
    }

    func testMaxDevices() {
        for i in 0..<DeviceStore.maxDevices { addConfirmed("K\(i)", row(cred: "bdc_\(i)")) }
        XCTAssertTrue(store.isFull(excluding: "NEW"))
        XCTAssertFalse(store.isFull(excluding: "K0"))
        XCTAssertFalse(store.insertPending(deviceKeyId: "NEW", device: row(), epoch: store.epoch))
    }

    /// 別の端末の行に同じトークンがあり、clientDeviceId が違えば、どちらの行も変わらない。
    func testPushTokenConflictLeavesBothRows() {
        addConfirmed("A", row("device-aaaa-1", cred: "bdc_a"))
        addConfirmed("B", row("device-bbbb-1", cred: "bdc_b"))
        let token = String(repeating: "ab", count: 32)
        XCTAssertEqual(store.setPush(deviceKeyId: "A", token: token, env: "production", locale: "ja"), .stored)
        XCTAssertEqual(store.setPush(deviceKeyId: "A", token: token, env: "production", locale: "ja"), .unchanged)
        XCTAssertEqual(store.setPush(deviceKeyId: "B", token: token, env: "production", locale: "en"), .conflict)
        XCTAssertEqual(store.device("A")?.push?.token, token)
        XCTAssertNil(store.device("B")?.push)
        // 同じ clientDeviceId の別の行（入れ直したアプリなど）からは移せる。
        addConfirmed("C", row("device-aaaa-1", cred: "bdc_c"))
        XCTAssertEqual(store.setPush(deviceKeyId: "C", token: token, env: "development", locale: "en"), .stored)
        XCTAssertNil(store.device("A")?.push)
        XCTAssertEqual(store.pushTargets().map { $0.deviceKeyId }, ["C"])
        store.clearPush(token: token)
        XCTAssertTrue(store.pushTargets().isEmpty)
    }

    /// lastSeenAt は行があるときだけ。消えた行を生き返らせない。
    func testTouchDoesNotResurrect() {
        addConfirmed("K1", row())
        store.touch(deviceKeyId: "K1")
        XCTAssertEqual(store.device("K1")?.lastSeenAt, now)
        XCTAssertTrue(store.revoke(deviceKeyId: "K1"))
        store.touch(deviceKeyId: "K1")
        XCTAssertNil(store.device("K1"))
    }

    /// 初めてつながった時刻は 5 分の間隔を待たずに書く（再起動のあと 24 時間の掃除で消されないように）。
    func testFirstTouchIsWrittenEvenWithinInterval() {
        addConfirmed("A", row(cred: "bdc_a"))
        addConfirmed("B", row("device-test-2", cred: "bdc_b"))
        store.touch(deviceKeyId: "A")
        now += 1000
        store.touch(deviceKeyId: "B")
        let reread = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        reread.load()
        XCTAssertNotNil(reread.device("A")?.lastSeenAt)
        XCTAssertEqual(reread.device("B")?.lastSeenAt, now)
    }

    /// 起動時の作り直し（まだ読んでいない一覧）でも、設定と epoch をファイルから引き継ぐ。
    func testResetAllBeforeLoadKeepsSettingsAndEpoch() {
        store.setApprovalsEnabled(false)
        store.resetAll(reason: "user_reset")
        let e = store.epoch
        let fresh = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        fresh.resetAll(reason: "machine_changed")
        XCTAssertFalse(fresh.approvalsEnabled)
        XCTAssertEqual(fresh.epoch, e + 1)
    }

    func testNeverSeenRowsPurgedAfter24h() {
        addConfirmed("seen", row(cred: "bdc_s"))
        store.touch(deviceKeyId: "seen")
        addConfirmed("never", row(cred: "bdc_n"))
        now += DeviceStore.neverSeenTTLms - 1
        XCTAssertTrue(store.purgeNeverSeen().isEmpty)
        now += 2
        XCTAssertEqual(store.purgeNeverSeen(), ["never"])
        XCTAssertNotNil(store.device("seen"))
    }

    func testBackupRestoreAndBrokenFiles() throws {
        addConfirmed("K1", row())
        let main = dir.appendingPathComponent("devices.json")
        let bak = dir.appendingPathComponent("devices.json.bak")
        // devices.json が壊れていたら .bak から戻す（devices_restored）。
        try Data("{broken".utf8).write(to: main)
        let a = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        XCTAssertEqual(a.load(), .restored)
        XCTAssertNotNil(a.device("K1"))
        XCTAssertEqual(a.lastReset?.reason, "devices_restored")
        // どちらも壊れていたら上書きせず、壊れている状態（bridge_error）。
        try Data("{broken".utf8).write(to: main)
        try Data("{broken".utf8).write(to: bak)
        let b = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        XCTAssertEqual(b.load(), .broken)
        XCTAssertTrue(b.isBroken)
        XCTAssertEqual(b.connectDecision(deviceKeyId: "K1", clientDeviceId: "device-test-1"), .broken)
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "{broken")
        // リセットで古いファイルを脇へよけて作り直す。
        b.resetAll(reason: "user_reset")
        XCTAssertFalse(b.isBroken)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("devices.json.broken-") })
    }

    func testRenameAndSameName() {
        addConfirmed("AAAA1", row("device-aaaa-1", cred: "bdc_a"))
        addConfirmed("BBBB1", row("device-bbbb-1", cred: "bdc_b"))
        XCTAssertEqual(store.sameNameCount("iPhone"), 2)
        XCTAssertEqual(store.rename(deviceKeyId: "AAAA1", label: "  仕事用\u{202E}  "), "仕事用 · AAAA")
        XCTAssertEqual(store.sameNameCount("iPhone"), 1)
        XCTAssertEqual(store.rename(deviceKeyId: "AAAA1", label: ""), "iPhone · AAAA")
        XCTAssertNil(store.rename(deviceKeyId: "nope", label: "x"))
    }

    func testVersionAdvancesAndWaitReturns() async {
        let v = store.version
        addConfirmed("K1", row())
        XCTAssertGreaterThan(store.version, v)
        let start = Date()
        await store.waitForChange(since: store.version, boot: "other-boot", timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "bootId が違えばすぐ返す")
    }

    // MARK: - スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）

    /// 古い devices.json（remoteApprovalsEnabled・approvedBy が無い）も読め、無ければ有効として扱う。
    func testOldFileWithoutRemoteSettingsDecodes() throws {
        let old = """
        {"devices":{"K1":{"clientDeviceId":"c1","createdAt":1,"credHash":"h","name":"iPhone","platform":"ios","pub":"p","via":"qr"}},\
        "epoch":2,"revoked":{},"settings":{"approvalsEnabled":true},"v":3}
        """
        try Data(old.utf8).write(to: dir.appendingPathComponent("devices.json"))
        let s = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        XCTAssertEqual(s.load(), .loaded)
        XCTAssertTrue(s.remoteApprovalsEnabled, "設定が無ければ有効")
        XCTAssertNil(s.device("K1")?.approvedBy)
        XCTAssertEqual(s.epoch, 2)

        s.setRemoteApprovalsEnabled(false)
        let reread = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        reread.load()
        XCTAssertFalse(reread.remoteApprovalsEnabled)
        XCTAssertTrue(reread.approvalsEnabled)
    }

    func testApprovedByIsPersisted() {
        var r = row(cred: "bdc_x")
        r.approvedBy = "PHONEKEY"
        addConfirmed("K1", r)
        let reread = DeviceStore(directory: { [dir] in dir! }, now: { [unowned self] in self.now })
        reread.load()
        XCTAssertEqual(reread.device("K1")?.approvedBy, "PHONEKEY")
    }

    /// 許可できる端末は確定済みの ios / android だけ。スマホでの許可が使えるのは、そのうち push の宛先があるとき。
    func testApprovers() {
        var mac = row("c-mac", cred: "bdc_m"); mac.platform = "mac"
        var android = row("c-and", cred: "bdc_a2"); android.platform = "android"
        addConfirmed("IOS", row("c-ios", cred: "bdc_i"))
        addConfirmed("MAC", mac)
        addConfirmed("AND", android)
        let pending = row("c-p", cred: "bdc_p")
        XCTAssertTrue(store.insertPending(deviceKeyId: "PEND", device: pending, epoch: store.epoch))
        XCTAssertTrue(store.isApprover("IOS"))
        XCTAssertTrue(store.isApprover("AND"))
        XCTAssertFalse(store.isApprover("MAC"), "デスクトップは許可できない")
        XCTAssertFalse(store.isApprover("PEND"), "pendingAck の行は許可できない")
        XCTAssertFalse(store.isApprover("NONE"))
        XCTAssertFalse(store.hasApproverWithPush)
        XCTAssertEqual(store.setPush(deviceKeyId: "MAC", token: String(repeating: "a", count: 64), env: "development", locale: "ja"), .stored)
        XCTAssertFalse(store.hasApproverWithPush, "デスクトップの宛先は数えない")
        XCTAssertEqual(store.setPush(deviceKeyId: "IOS", token: String(repeating: "b", count: 64), env: "development", locale: "en"), .stored)
        XCTAssertTrue(store.hasApproverWithPush)
        XCTAssertEqual(store.approverPushTargets().map(\.deviceKeyId), ["IOS"])
        XCTAssertTrue(store.beginUnpair(deviceKeyId: "IOS"))
        XCTAssertFalse(store.isApprover("IOS"), "unpairing の行は許可できない")
        XCTAssertFalse(store.hasApproverWithPush)
    }
}
