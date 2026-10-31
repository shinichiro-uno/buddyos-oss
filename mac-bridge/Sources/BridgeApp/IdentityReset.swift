import Foundation

/// 端末認証 v3 の移行・作り直し・アカウントから外されたとき（spec/PROTOCOL-v3.md Appendix A・§15.7）。
/// ファイルはどれも ~/.buddyos（テスト中は BuddyPaths の一時フォルダ）に 0600 で一時ファイル → rename で書く。
extension KeyStore {
    /// `lastReset.reason`。
    enum ResetReason: String, CaseIterable {
        case migrationV3 = "migration_v3"
        case userReset = "user_reset"
        case accountRemoved = "account_removed"
        case revokedByAccount = "revoked_by_account"
        case keyUnreadable = "key_unreadable"
        case machineChanged = "machine_changed"

        /// bridgeId を作り直し、`device-token` を消すか（revoked_by_account は accountRevoked() で済んでいる）。
        var rotatesBridgeId: Bool { self == .accountRemoved || self == .machineChanged }
    }

    /// 起動時の確かめの結果。
    enum IdentityStatus: Equatable {
        case ready
        /// `e2e-key` が権限・I/O の失敗で読めない（作り直さずに待つ）。
        case keyIO
    }

    private static func url(_ name: String) -> URL {
        let dir = BuddyPaths.root
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent(name)
    }

    static var authV3URL: URL { url("auth-v3.json") }
    static var resetPendingURL: URL { url("reset-pending") }
    static var registryHoldURL: URL { url("registry-hold") }
    static var registeredURL: URL { url("registered.json") }

    private static func readJSON(_ u: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func writeJSON(_ obj: [String: Any], to u: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        do { try writeSecret(data, to: u) } catch { WebSocketServer.wslog("\(u.lastPathComponent) write FAILED: \(error)") }
    }

    private static func remove(_ u: URL) { try? FileManager.default.removeItem(at: u) }

    // MARK: - registry-hold・registered.json

    struct RegistryHold: Equatable {
        let since: Int64
        let reason: String
    }

    /// ある間は `bdt_` を発行し直さず、登録もしない（デスクトップで明示的にサインインし直すまで）。
    static func registryHold() -> RegistryHold? {
        guard let o = readJSON(registryHoldURL), let reason = o["reason"] as? String else { return nil }
        return RegistryHold(since: (o["since"] as? NSNumber)?.int64Value ?? 0, reason: reason)
    }

    static func setRegistryHold(reason: String) {
        writeJSON(["since": DeviceStore.nowMs(), "reason": reason], to: registryHoldURL)
    }

    static func clearRegistryHold() { remove(registryHoldURL) }

    struct Registered: Equatable {
        let bridgePub: String
        let relayId: String
        let relayURL: String
    }

    /// 最後に Convex に登録できた値（次に送る値と違えば keyRotation を付ける。§15.5）。
    static func registered() -> Registered? {
        guard let o = readJSON(registeredURL), let pub = o["bridgePub"] as? String,
              let rid = o["relayId"] as? String, let rurl = o["relayURL"] as? String else { return nil }
        return Registered(bridgePub: pub, relayId: rid, relayURL: rurl)
    }

    static func setRegistered(_ r: Registered) {
        writeJSON(["bridgePub": r.bridgePub, "relayId": r.relayId, "relayURL": r.relayURL], to: registeredURL)
    }

    static func clearRegistered() { remove(registeredURL) }

    // MARK: - 起動時の確かめ

    /// ルートを登録する前に呼ぶ。1 reset-pending → 2 移行 → 3 machineId → 4・5 devices.json → 6 e2e-key。
    @discardableResult
    static func prepareIdentityV3(devices: DeviceStore = .shared, machineId: String? = KeyStore.registryMachineId()) -> IdentityStatus {
        // 1. 作り直しの途中で落ちていたら、その理由で 2 から続ける。
        if let o = readJSON(resetPendingURL), let raw = o["reason"] as? String, let reason = ResetReason(rawValue: raw) {
            WebSocketServer.wslog("identity: resuming reset (\(raw))")
            resetIdentity(reason, devices: devices, machineId: machineId)
        } else if readJSON(authV3URL) == nil {
            // 2. 初めての v3。古い値は QR・登録簿・iPhone・別の PC に出回っているので作り直す。
            WebSocketServer.wslog("identity: migrating to v3")
            resetIdentity(.migrationV3, devices: devices, machineId: machineId)
        } else if let saved = readJSON(authV3URL)?["machineId"] as? String, let machineId, saved != machineId {
            // 3. ~/.buddyos が別の Mac に写った（Time Machine・移行アシスタント）。
            WebSocketServer.wslog("identity: machine changed")
            resetIdentity(.machineChanged, devices: devices, machineId: machineId)
        }
        // 4・5. devices.json（無い → .bak / 空、読めない → .bak / 壊れている）。
        switch devices.load() {
        case .loaded: break
        case .restored: WebSocketServer.wslog("identity: devices.json restored from .bak")
        case .missing: WebSocketServer.wslog("identity: devices.json missing — started an empty list")
        case .broken: WebSocketServer.wslog("identity: devices.json unreadable — not overwriting (bridge_error)")
        }
        // 6. e2e-key（無い・壊れている → 作り直して端末の一覧も空に。I/O の失敗 → 作り直さずに待つ）。
        return checkE2EKey(devices: devices, machineId: machineId)
    }

    /// `e2e-key` の原因の分け方。key_io の間は 30 秒ごとにこれを呼び直す。
    static func checkE2EKey(devices: DeviceStore = .shared, machineId: String? = KeyStore.registryMachineId()) -> IdentityStatus {
        invalidateE2EKeyCache()
        switch readE2EKey() {
        case .ok:
            _ = e2eKey()
            return .ready
        case .missing, .corrupt:
            WebSocketServer.wslog("identity: e2e-key missing or corrupt — recreating (key_unreadable)")
            resetIdentity(.keyUnreadable, devices: devices, machineId: machineId)
            return e2eKey() == nil ? .keyIO : .ready
        case .io(let err):
            WebSocketServer.wslog("identity: e2e-key unreadable (errno \(err)) — waiting, not recreating")
            return .keyIO
        }
    }

    // MARK: - 作り直し（Appendix A の reset）

    /// 作り直しが終わったときに呼ぶ（中継のトンネルを張り直す・登録し直す）。BridgeServer が入れる。
    nonisolated(unsafe) static var onIdentityReset: (@Sendable (ResetReason) -> Void)?

    /// Mac・Windows で同じ順番で行う。1 reset-pending を書く → 2 端末と承認待ちを空に（epoch + 1）→
    /// 3 静的鍵・relayId・ローカル鍵を作り直す → 4 トンネルを張り直す → 5 reset-pending を消す。
    static func resetIdentity(_ reason: ResetReason, devices: DeviceStore = .shared,
                              machineId: String? = KeyStore.registryMachineId()) {
        // 1.
        writeJSON(["reason": reason.rawValue, "at": DeviceStore.nowMs()], to: resetPendingURL)
        // 2. 先に消すので、途中で落ちても古い端末が残らない。
        if reason == .migrationV3 {
            devices.createInitial(reason: reason.rawValue)
        } else {
            devices.resetAll(reason: reason.rawValue)
        }
        PairingInvites.shared.clear()
        ApprovalQueue.shared.resetAll()
        PreviewSessionStore.shared.removeAll()
        PtyRegistry.shared.drop()
        // 開いているペインを見ている人も全部切る（常駐プロセスの接続は残す）。
        PaneShareHub.shared.drop()
        // 3.
        do { try regenerateE2EKey() } catch { WebSocketServer.wslog("identity: e2e-key write FAILED: \(error)") }
        regeneratePaseoRelayId()
        LocalKey.shared.replace(regenerateAPIKey())
        if reason.rotatesBridgeId {
            regenerateBridgeId()
            clearDeviceToken()
            clearRegistered()
        }
        if reason == .accountRemoved { setRegistryHold(reason: ResetReason.accountRemoved.rawValue) }
        if reason == .migrationV3 {
            for name in ["e2e-devices.json", "push_tokens.json", "pairing-qr.png"] {
                remove(BuddyPaths.root.appendingPathComponent(name))
            }
        }
        if reason == .migrationV3 || reason == .machineChanged {
            var auth: [String: Any] = ["migratedAt": DeviceStore.nowMs()]
            auth["machineId"] = machineId ?? NSNull()
            if reason == .machineChanged, let prev = readJSON(authV3URL)?["migratedAt"] { auth["migratedAt"] = prev }
            writeJSON(auth, to: authV3URL)
        }
        // 4.
        onIdentityReset?(reason)
        // 5.
        remove(resetPendingURL)
        WebSocketServer.wslog("identity: reset done (\(reason.rawValue))")
    }

    // MARK: - アカウントから外されたとき（§15.7）

    /// 登録で 403 revoked を受けた。`device-token` を消し、bridgeId を作り直し、`registry-hold` を置く。
    /// 端末の一覧と鍵はここでは消さない（Clerk のトークンだけで全ペアリングを消させないため。利用者が選ぶ）。
    static func accountRevoked() {
        clearDeviceToken()
        regenerateBridgeId()
        clearRegistered()
        setRegistryHold(reason: ResetReason.revokedByAccount.rawValue)
        WebSocketServer.wslog("identity: removed from account — bridgeId rotated, registry on hold")
    }
}
