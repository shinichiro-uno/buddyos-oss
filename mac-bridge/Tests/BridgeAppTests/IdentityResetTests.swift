import XCTest
@testable import BridgeApp

/// 起動時の確かめ・作り直し・アカウントから外されたとき（spec/PROTOCOL-v3.md Appendix A・§15.7）。
/// 本物の ~/.buddyos には触らない（BuddyPaths.setOverride）。
final class IdentityResetTests: XCTestCase {
    private var root: URL!
    private var devices: DeviceStore!

    override func setUpWithError() throws {
        root = try makeTempDir("identity-reset")
        BuddyPaths.setOverride(root)
        let r = root!
        devices = DeviceStore(directory: { r })
        KeyStore.invalidateE2EKeyCache()
    }

    override func tearDownWithError() throws {
        let key = root.appendingPathComponent("e2e-key").path
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key)
        KeyStore.invalidateE2EKeyCache()
        LocalKey.shared.invalidate()
        BuddyPaths.setOverride(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }
    private func text(_ name: String) -> String? { try? String(contentsOf: file(name), encoding: .utf8) }
    private func write(_ name: String, _ s: String) throws { try Data(s.utf8).write(to: file(name)) }
    private func json(_ name: String) -> [String: Any]? {
        (try? Data(contentsOf: file(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func addDevice(_ key: String) {
        let row = DeviceStore.Device(pub: "p", clientDeviceId: "device-test-1", name: "iPhone", label: nil, platform: "ios",
                                     credHash: "h", via: "qr", createdAt: DeviceStore.nowMs(), lastSeenAt: nil, push: nil)
        XCTAssertTrue(devices.insertPending(deviceKeyId: key, device: row, epoch: devices.epoch))
        XCTAssertTrue(devices.confirmPending(deviceKeyId: key, credHash: "h", epoch: devices.epoch))
    }

    /// 初めての v3 は、静的鍵・relayId・ローカル鍵を作り直し、古いファイルを消す。bridgeId と device-token は残す。
    func testMigrationRegeneratesSecretsAndKeepsIdentity() throws {
        let oldKey = Data(repeating: 7, count: 32).base64EncodedString()
        try write("e2e-key", oldKey)
        try write("api-key", "old-api-key")
        try write("paseo-relay-id", "old-relay-id-0000000000")
        try write("bridge-id", "mac-bridge-keep-me")
        try write("device-token", "bdt_keep")
        for name in ["e2e-devices.json", "push_tokens.json", "pairing-qr.png"] { try write(name, "{}") }

        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: String(repeating: "a", count: 64)), .ready)
        XCTAssertNotEqual(text("e2e-key"), oldKey)
        XCTAssertNotEqual(text("api-key"), "old-api-key")
        XCTAssertNotEqual(text("paseo-relay-id"), "old-relay-id-0000000000")
        XCTAssertEqual(text("bridge-id"), "mac-bridge-keep-me")
        XCTAssertEqual(text("device-token"), "bdt_keep")
        for name in ["e2e-devices.json", "push_tokens.json", "pairing-qr.png", "reset-pending"] { XCTAssertFalse(exists(name), name) }
        XCTAssertEqual(json("auth-v3.json")?["machineId"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(devices.lastReset?.reason, "migration_v3")
        XCTAssertEqual(LocalKey.shared.current(), text("api-key"))

        // 2 回目の起動では何も作り直さない。
        let key = text("e2e-key")
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: String(repeating: "a", count: 64)), .ready)
        XCTAssertEqual(text("e2e-key"), key)
    }

    /// reset-pending があれば、その reason で続きから行う。
    func testResumesInterruptedReset() throws {
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        addDevice("K1")
        let key = text("e2e-key")
        try write("reset-pending", #"{"reason":"user_reset","at":1}"#)
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        XCTAssertFalse(exists("reset-pending"))
        XCTAssertNotEqual(text("e2e-key"), key)
        XCTAssertNil(devices.device("K1"))
        XCTAssertEqual(devices.lastReset?.reason, "user_reset")
    }

    /// ~/.buddyos が別の Mac に写った → machine_changed（bridgeId も作り直し、device-token・registered.json を消す）。
    func testMachineChanged() throws {
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: String(repeating: "a", count: 64)), .ready)
        try write("bridge-id", "mac-bridge-old")
        try write("device-token", "bdt_old")
        KeyStore.setRegistered(.init(bridgePub: "x", relayId: "y", relayURL: "z"))
        addDevice("K1")
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: String(repeating: "b", count: 64)), .ready)
        XCTAssertNotEqual(text("bridge-id"), "mac-bridge-old")
        XCTAssertFalse(exists("device-token"))
        XCTAssertFalse(exists("registered.json"))
        XCTAssertFalse(exists("registry-hold"), "machine_changed は registry-hold を置かない")
        XCTAssertNil(devices.device("K1"))
        XCTAssertEqual(json("auth-v3.json")?["machineId"] as? String, String(repeating: "b", count: 64))
        XCTAssertEqual(devices.lastReset?.reason, "machine_changed")
    }

    /// 移行済みなのに devices.json も .bak も無い → 空で作る（devices_missing。鍵は残す）。
    func testDevicesMissingKeepsKeys() throws {
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        let key = text("e2e-key")
        try FileManager.default.removeItem(at: file("devices.json"))
        try FileManager.default.removeItem(at: file("devices.json.bak"))
        let fresh = DeviceStore(directory: { [root] in root! })
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: fresh, machineId: nil), .ready)
        XCTAssertEqual(text("e2e-key"), key)
        XCTAssertEqual(fresh.lastReset?.reason, "devices_missing")
    }

    /// e2e-key が壊れている → 作り直して key_unreadable（端末の一覧も空）。
    func testCorruptKeyIsRecreated() throws {
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        addDevice("K1")
        try write("e2e-key", "not a key")
        KeyStore.invalidateE2EKeyCache()
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        XCTAssertNotEqual(text("e2e-key"), "not a key")
        XCTAssertNil(devices.device("K1"))
        XCTAssertEqual(devices.lastReset?.reason, "key_unreadable")
    }

    /// 権限・I/O の失敗では作り直さない（key_io で待つ）。
    func testUnreadableKeyIsNotRecreated() throws {
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        addDevice("K1")
        let before = text("e2e-key")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file("e2e-key").path)
        KeyStore.invalidateE2EKeyCache()
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .keyIO)
        XCTAssertNil(KeyStore.e2eKey())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file("e2e-key").path)
        XCTAssertEqual(text("e2e-key"), before)
        XCTAssertNotNil(devices.device("K1"), "I/O の失敗で端末の一覧を消さない")
        XCTAssertEqual(KeyStore.checkE2EKey(devices: devices, machineId: nil), .ready)
    }

    /// resetIdentity の順番（reset-pending を最初に書き最後に消す）と、残すファイル・作り直すファイル。
    func testUserResetKeepsBridgeIdAndToken() throws {
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        try write("bridge-id", "mac-bridge-keep")
        try write("device-token", "bdt_keep")
        addDevice("K1")
        let epoch = devices.epoch
        let relay = text("paseo-relay-id")
        final class Flag: @unchecked Sendable { var value = false }
        let sawPending = Flag()
        KeyStore.onIdentityReset = { _ in sawPending.value = FileManager.default.fileExists(atPath: BuddyPaths.root.appendingPathComponent("reset-pending").path) }
        defer { KeyStore.onIdentityReset = nil }
        KeyStore.resetIdentity(.userReset, devices: devices, machineId: nil)
        XCTAssertTrue(sawPending.value, "トンネルを張り直す時点では reset-pending がまだある")
        XCTAssertFalse(exists("reset-pending"))
        XCTAssertEqual(devices.epoch, epoch + 1)
        XCTAssertNil(devices.device("K1"))
        XCTAssertNotEqual(text("paseo-relay-id"), relay)
        XCTAssertEqual(text("bridge-id"), "mac-bridge-keep")
        XCTAssertEqual(text("device-token"), "bdt_keep")
    }

    func testAccountRemovedRotatesBridgeIdAndHolds() throws {
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        try write("bridge-id", "mac-bridge-old")
        try write("device-token", "bdt_old")
        KeyStore.resetIdentity(.accountRemoved, devices: devices, machineId: nil)
        XCTAssertNotEqual(text("bridge-id"), "mac-bridge-old")
        XCTAssertFalse(exists("device-token"))
        XCTAssertEqual(KeyStore.registryHold()?.reason, "account_removed")
    }

    /// accountRevoked() は端末と鍵を消さない。device-token を消し、bridgeId を作り直し、registry-hold を置く。
    func testAccountRevokedKeepsDevicesAndKeys() throws {
        XCTAssertEqual(KeyStore.prepareIdentityV3(devices: devices, machineId: nil), .ready)
        addDevice("K1")
        try write("bridge-id", "mac-bridge-old")
        try write("device-token", "bdt_old")
        let key = text("e2e-key")
        KeyStore.accountRevoked()
        XCTAssertNotNil(devices.device("K1"))
        XCTAssertEqual(text("e2e-key"), key)
        XCTAssertFalse(exists("device-token"))
        XCTAssertNotEqual(text("bridge-id"), "mac-bridge-old")
        XCTAssertEqual(KeyStore.registryHold()?.reason, "revoked_by_account")
        XCTAssertEqual(LocalDeviceRoutes.allowedResetReason("revoked_by_account"), .revokedByAccount)
        KeyStore.clearRegistryHold()
        XCTAssertNil(LocalDeviceRoutes.allowedResetReason("revoked_by_account"), "registry-hold があるときだけ")
        XCTAssertNil(LocalDeviceRoutes.allowedResetReason("migration_v3"))
    }
}
