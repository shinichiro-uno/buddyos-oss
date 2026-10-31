import Foundation

/// この Bridge につないでいる端末の一覧（~/.buddyos/devices.json と devices.json.bak）。旧 `E2EDeviceStore`（e2e-devices.json）を置き換える。
///
/// Vapor の認証（BridgeAuth）から同期で引くため、actor ではなく 1 つの lock を持つ class にする。
/// 変更はどれも lock の中でメモリの値を変えてから、その時点の値を丸ごと書く（古い写しを書き戻さない）。
/// 行の `state`（pendingAck / unpairing）・`version`・`bootId` はメモリだけ。pendingAck の行はファイルに書かない。
final class DeviceStore: @unchecked Sendable {
    static let shared = DeviceStore()

    /// 1 台の Bridge に登録できる端末の数（spec/PROTOCOL-v3.md §12）。
    static let maxDevices = 20
    /// 外した端末の印の寿命（90 日）。
    static let revokedTTLms: Int64 = 90 * 24 * 60 * 60 * 1000
    /// 一度もつながっていない行を消すまでの時間（24 時間）。
    static let neverSeenTTLms: Int64 = 24 * 60 * 60 * 1000
    /// `lastSeenAt` をファイルに書く間隔（5 分に 1 回まで）。
    static let lastSeenWriteIntervalMs: Int64 = 5 * 60 * 1000

    struct Push: Codable, Equatable {
        var token: String
        var env: String
        var locale: String
    }

    struct Device: Codable, Equatable {
        var pub: String
        var clientDeviceId: String
        var name: String
        var label: String?
        var platform: String
        var credHash: String
        var via: String
        var createdAt: Int64
        var lastSeenAt: Int64?
        var push: Push?
        /// スマホで許可してつないだ端末なら、許可したスマホの deviceKeyId（spec/PROTOCOL-v3.md §10.4.1）。
        /// PC で入力したとき・QR のときは nil。古いファイルとの互換のため任意。
        var approvedBy: String? = nil

        /// 表示名（§5.3）。ラベルがあればラベル。
        func display(deviceKeyId: String) -> String {
            TunnelV3.displayName(name: label ?? name, deviceKeyId: deviceKeyId)
        }
    }

    enum RowState: String { case pendingAck, unpairing }

    struct Settings: Codable, Equatable {
        var approvalsEnabled: Bool
        /// スマホからの許可（§10.4.1）。無ければ有効（古いファイルとの互換）。
        var remoteApprovalsEnabled: Bool? = nil
    }

    struct LastReset: Codable, Equatable {
        var at: Int64
        var reason: String
    }

    struct FileModel: Codable, Equatable {
        var v: Int
        var epoch: Int
        var settings: Settings
        var devices: [String: Device]
        var revoked: [String: Int64]
        var lastReset: LastReset?

        static func empty(epoch: Int, lastReset: LastReset?) -> FileModel {
            FileModel(v: 3, epoch: epoch, settings: Settings(approvalsEnabled: true), devices: [:], revoked: [:], lastReset: lastReset)
        }
    }

    /// connect の判定（§10.2 の 1）。
    enum ConnectDecision: Equatable {
        case ok(Device)
        case unknown
        case revoked
        case broken
    }

    /// `register_push_token` の結果（§14.1）。
    enum PushResult: Equatable { case stored, unchanged, conflict, noDevice }

    private let lock = NSLock()
    private let directory: () -> URL
    private let now: () -> Int64
    private var model = FileModel.empty(epoch: 1, lastReset: nil)
    private var states: [String: RowState] = [:]
    private var loaded = false
    private var broken = false
    private var lastSeenWrittenAt: Int64 = 0
    private var _version = 0
    /// Bridge の起動ごとに変わる乱数（b64u 8 バイト）。
    let bootId: String
    /// 最近つないだ端末（メニューバーの「最近追加した端末」）。
    private var _lastAdded: (display: String, at: Int64)?
    /// 変わったときに呼ぶ（push の宛先の登録し直しなど）。lock の外で呼ぶ。
    var onPushTargetsChanged: (@Sendable () -> Void)?

    init(directory: @escaping () -> URL = { BuddyPaths.root }, now: @escaping () -> Int64 = DeviceStore.nowMs) {
        self.directory = directory
        self.now = now
        self.bootId = TunnelV3.b64u((try? TunnelV3.randomBytes(8)) ?? Data(UUID().uuidString.utf8.prefix(8)))
    }

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    var fileURL: URL { directory().appendingPathComponent("devices.json") }
    var backupURL: URL { directory().appendingPathComponent("devices.json.bak") }

    // MARK: - 読み込み

    enum LoadOutcome: Equatable {
        case loaded
        /// `devices.json` が無く `.bak` から戻した、または読めず `.bak` から戻した。
        case restored
        /// `devices.json` も `.bak` も無い（空で作った）。
        case missing
        /// どちらも読めない（上書きしない）。
        case broken
    }

    /// 起動時に読む。`devices.json` → `.bak` の順。どちらも読めなければ「壊れている」にして上書きしない。
    @discardableResult
    func load() -> LoadOutcome {
        lock.lock(); defer { lock.unlock() }
        loaded = true
        broken = false
        states.removeAll()
        let fm = FileManager.default
        let mainExists = fm.fileExists(atPath: fileURL.path)
        if mainExists, let m = Self.read(fileURL) {
            model = m
            return .loaded
        }
        let bakExists = fm.fileExists(atPath: backupURL.path)
        if bakExists, var m = Self.read(backupURL) {
            m.lastReset = LastReset(at: now(), reason: "devices_restored")
            model = m
            writeLocked()
            return .restored
        }
        if !mainExists && !bakExists {
            model = .empty(epoch: 1, lastReset: LastReset(at: now(), reason: "devices_missing"))
            writeLocked()
            return .missing
        }
        broken = true
        model = .empty(epoch: 1, lastReset: nil)
        return .broken
    }

    private static func read(_ url: URL) -> FileModel? {
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(FileModel.self, from: data), m.v == 3 else { return nil }
        return m
    }

    /// 移行・作り直しで空の一覧を作る。`epoch` は 1 増やす。壊れたファイルは脇へよける。
    func resetAll(reason: String) {
        // 起動時の作り直し（reset-pending の続き・machine_changed）はまだ読んでいないことがある。
        // 先に読み、設定（approvalsEnabled）と epoch を引き継ぐ。壊れていればここで脇へよける。
        lockLoaded()
        if broken {
            let fm = FileManager.default
            let stamp = now()
            try? fm.moveItem(at: fileURL, to: directory().appendingPathComponent("devices.json.broken-\(stamp)"))
        }
        broken = false
        let nextEpoch = model.epoch + 1
        let settings = model.settings
        model = .empty(epoch: nextEpoch, lastReset: LastReset(at: now(), reason: reason))
        model.settings = settings
        states.removeAll()
        _version += 1
        writeLocked()
        let notify = onPushTargetsChanged
        lock.unlock()
        notify?()
    }

    /// 移行のときの初めの一覧（epoch 1）。
    func createInitial(reason: String) {
        lock.lock()
        loaded = true
        broken = false
        model = .empty(epoch: 1, lastReset: LastReset(at: now(), reason: reason))
        states.removeAll()
        _version += 1
        writeLocked()
        lock.unlock()
    }

    private func ensureLoadedLocked() {
        guard !loaded else { return }
        lock.unlock()
        load()
        lock.lock()
    }

    private func writeLocked() {
        guard !broken else { return }
        var out = model
        // pendingAck の行は確定してから書く。
        out.devices = model.devices.filter { states[$0.key] != .pendingAck }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(out) else { return }
        do {
            try FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try KeyStore.writeSecret(data, to: fileURL)
            try KeyStore.writeSecret(data, to: backupURL)
        } catch {
            WebSocketServer.wslog("devices.json write FAILED: \(error)")
        }
    }

    // MARK: - 状態

    var epoch: Int { withLock { model.epoch } }
    var version: Int { withLock { _version } }
    var isBroken: Bool { withLock { broken } }
    var lastReset: LastReset? { withLock { model.lastReset } }
    var lastAdded: (display: String, at: Int64)? { withLock { _lastAdded } }
    var approvalsEnabled: Bool { withLock { model.settings.approvalsEnabled } }

    func setApprovalsEnabled(_ on: Bool) {
        withLock {
            guard model.settings.approvalsEnabled != on else { return }
            model.settings.approvalsEnabled = on
            _version += 1
            writeLocked()
        }
    }

    /// スマホからの許可を受け付けるか（設定が無ければ有効）。
    var remoteApprovalsEnabled: Bool { withLock { model.settings.remoteApprovalsEnabled ?? true } }

    func setRemoteApprovalsEnabled(_ on: Bool) {
        withLock {
            guard model.settings.remoteApprovalsEnabled != on else { return }
            model.settings.remoteApprovalsEnabled = on
            _version += 1
            writeLocked()
        }
    }

    /// 招待・承認待ち・窓が変わったときに呼ぶ（`/local/devices/events` の長いポーリングを起こす）。
    func bumpVersion() { withLock { _version += 1 } }

    func device(_ deviceKeyId: String) -> Device? { withLock { model.devices[deviceKeyId] } }
    func state(_ deviceKeyId: String) -> RowState? { withLock { states[deviceKeyId] } }
    func isRevoked(_ deviceKeyId: String) -> Bool { withLock { revokedLocked(deviceKeyId) } }

    private func revokedLocked(_ deviceKeyId: String) -> Bool {
        guard let at = model.revoked[deviceKeyId] else { return false }
        return now() - at < Self.revokedTTLms
    }

    /// 確定済みの行の一覧（キーの順）。
    func confirmedDevices() -> [(deviceKeyId: String, device: Device)] {
        withLock {
            model.devices.filter { states[$0.key] == nil }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }
    }

    /// 許可できる端末（§10.4.1）。確定済みで、platform が ios か android の行。
    /// デスクトップ（別の PC）は許可できない（PC の連鎖で増やせないように）。
    static func isApproverPlatform(_ platform: String) -> Bool { platform == "ios" || platform == "android" }

    func isApprover(_ deviceKeyId: String) -> Bool {
        withLock {
            guard states[deviceKeyId] == nil, let d = model.devices[deviceKeyId] else { return false }
            return Self.isApproverPlatform(d.platform)
        }
    }

    /// 許可できる端末のうち push の宛先があるもの（pair_request の送り先）。
    func approverPushTargets() -> [(deviceKeyId: String, device: Device, push: Push)] {
        pushTargets().filter { Self.isApproverPlatform($0.device.platform) }
    }

    /// スマホでの許可が使える端末があるか（許可できる端末で push の宛先があるものが 1 台以上）。
    var hasApproverWithPush: Bool { !approverPushTargets().isEmpty }

    /// 20 台に達していて、この deviceKeyId がまだ一覧に無いか。
    func isFull(excluding deviceKeyId: String) -> Bool {
        withLock { model.devices[deviceKeyId] == nil && model.devices.count >= Self.maxDevices }
    }

    /// 同じ名前（ラベルが無いとき）の端末の数。
    func sameNameCount(_ name: String) -> Int {
        withLock { model.devices.values.filter { $0.label == nil && $0.name == name }.count }
    }

    // MARK: - connect（§10.2）

    func connectDecision(deviceKeyId: String, clientDeviceId: String) -> ConnectDecision {
        withLock {
            if broken { return .broken }
            guard let row = model.devices[deviceKeyId] else {
                return revokedLocked(deviceKeyId) ? .revoked : .unknown
            }
            switch states[deviceKeyId] {
            case .pendingAck: return .unknown
            case .unpairing: return .revoked
            case nil: break
            }
            guard TunnelV3.constantTimeEquals(row.clientDeviceId, clientDeviceId) else { return .unknown }
            return .ok(row)
        }
    }

    /// `epoch` と行（確定済み）がまだあるか。TunnelPeers に入れる前と後に lock の中で確かめる。
    func isLive(deviceKeyId: String, epoch: Int) -> Bool {
        withLock { model.epoch == epoch && model.devices[deviceKeyId] != nil && states[deviceKeyId] == nil && !broken }
    }

    /// `lastSeenAt` を更新する（行がまだあるときだけ。ファイルは 5 分に 1 回まで）。
    func touch(deviceKeyId: String) {
        withLock {
            guard model.devices[deviceKeyId] != nil, states[deviceKeyId] == nil else { return }
            let t = now()
            // 初めてつながった時刻はすぐ書く（書かないまま再起動すると、24 時間の掃除で「一度もつながっていない」と消えるため）。
            let first = model.devices[deviceKeyId]?.lastSeenAt == nil
            model.devices[deviceKeyId]?.lastSeenAt = t
            if first || t - lastSeenWrittenAt >= Self.lastSeenWriteIntervalMs {
                lastSeenWrittenAt = t
                writeLocked()
            }
        }
    }

    // MARK: - ペアリング（§10.3 の pair・§10.4 の approve）

    /// 行を `pendingAck` で入れる（同じ deviceKeyId の行があれば置き換える）。`epoch` が違えば何もしない。
    /// QR（via=qr）のときだけ外した印を消す。戻り値は入れられたか。
    func insertPending(deviceKeyId: String, device: Device, epoch: Int) -> Bool {
        withLock {
            guard !broken, model.epoch == epoch else { return false }
            if model.devices[deviceKeyId] == nil && model.devices.count >= Self.maxDevices { return false }
            if device.via == "qr" { model.revoked.removeValue(forKey: deviceKeyId) }
            model.devices[deviceKeyId] = device
            states[deviceKeyId] = .pendingAck
            _version += 1
            return true
        }
    }

    /// `paired_ack` を受けたら確定する（行の `credHash` が同じで `epoch` も同じとき）。
    func confirmPending(deviceKeyId: String, credHash: String, epoch: Int) -> Bool {
        lockLoaded()
        guard !broken, model.epoch == epoch, states[deviceKeyId] == .pendingAck,
              model.devices[deviceKeyId]?.credHash == credHash else {
            lock.unlock()
            return false
        }
        states.removeValue(forKey: deviceKeyId)
        if let d = model.devices[deviceKeyId] { _lastAdded = (d.display(deviceKeyId: deviceKeyId), now()) }
        _version += 1
        writeLocked()
        let notify = onPushTargetsChanged
        lock.unlock()
        notify?()
        return true
    }

    /// 確定しなかった `pendingAck` の行を消す（同じ資格情報の行のときだけ）。
    func removePending(deviceKeyId: String, credHash: String) {
        withLock {
            guard states[deviceKeyId] == .pendingAck, model.devices[deviceKeyId]?.credHash == credHash else { return }
            model.devices.removeValue(forKey: deviceKeyId)
            states.removeValue(forKey: deviceKeyId)
            _version += 1
            writeLocked()
        }
    }

    // MARK: - 外す（Appendix A の revoke）

    /// PC から外す。行を消して外した印（90 日）を残す。戻り値は行があったか。
    @discardableResult
    func revoke(deviceKeyId: String) -> Bool {
        lockLoaded()
        guard model.devices.removeValue(forKey: deviceKeyId) != nil else {
            lock.unlock()
            return false
        }
        states.removeValue(forKey: deviceKeyId)
        model.revoked[deviceKeyId] = now()
        pruneRevokedLocked()
        _version += 1
        writeLocked()
        let notify = onPushTargetsChanged
        lock.unlock()
        notify?()
        return true
    }

    /// 端末から自分を外す（受けた時点で `unpairing`）。
    func beginUnpair(deviceKeyId: String) -> Bool {
        withLock {
            guard model.devices[deviceKeyId] != nil, states[deviceKeyId] == nil else { return false }
            states[deviceKeyId] = .unpairing
            _version += 1
            return true
        }
    }

    /// `unpairing` の行を消す（外した印は残さない）。
    func finishUnpair(deviceKeyId: String) {
        lockLoaded()
        guard states[deviceKeyId] == .unpairing else {
            lock.unlock()
            return
        }
        model.devices.removeValue(forKey: deviceKeyId)
        states.removeValue(forKey: deviceKeyId)
        _version += 1
        writeLocked()
        let notify = onPushTargetsChanged
        lock.unlock()
        notify?()
    }

    private func pruneRevokedLocked() {
        let t = now()
        model.revoked = model.revoked.filter { t - $0.value < Self.revokedTTLms }
    }

    /// ラベルを付ける（§5.3 で無害化。空ならラベルを外す）。戻り値は表示名（行が無ければ nil）。
    func rename(deviceKeyId: String, label raw: String) -> String? {
        withLock {
            guard model.devices[deviceKeyId] != nil else { return nil }
            let cleaned = TunnelV3.sanitizeName(raw, fallback: "")
            model.devices[deviceKeyId]?.label = cleaned.isEmpty ? nil : cleaned
            _version += 1
            writeLocked()
            return model.devices[deviceKeyId]?.display(deviceKeyId: deviceKeyId)
        }
    }

    /// 一度もつながっていない行を 24 時間で消す（起動時と 1 時間ごと）。消した deviceKeyId を返す。
    @discardableResult
    func purgeNeverSeen() -> [String] {
        lockLoaded()
        let t = now()
        let stale = model.devices.filter { $0.value.lastSeenAt == nil && states[$0.key] == nil && t - $0.value.createdAt >= Self.neverSeenTTLms }.map(\.key)
        pruneRevokedLocked()
        guard !stale.isEmpty else {
            lock.unlock()
            return []
        }
        for k in stale { model.devices.removeValue(forKey: k) }
        _version += 1
        writeLocked()
        let notify = onPushTargetsChanged
        lock.unlock()
        notify?()
        return stale
    }

    // MARK: - 資格情報（§13.2）

    /// 提示された `bdc_` がこの端末の `credHash` と一致し、行に `state` が無いときだけ行を返す（定数時間）。
    func verify(deviceKeyId: String, credential: String) -> Device? {
        guard credential.hasPrefix("bdc_") else { return nil }
        let hash = TunnelV3.credentialHash(credential)
        return withLock {
            guard let row = model.devices[deviceKeyId], states[deviceKeyId] == nil,
                  TunnelV3.constantTimeEquals(row.credHash, hash) else { return nil }
            return row
        }
    }

    // MARK: - push の宛先（§14.1）

    /// 端末 D の行に push の宛先を入れる。同じトークンが別の行にあり、その行の clientDeviceId が D と同じなら移す。
    /// 違えば何も変えずに断る（悪い端末が他の端末の通知を止められないように）。
    func setPush(deviceKeyId: String, token: String, env: String, locale: String) -> PushResult {
        lockLoaded()
        guard let row = model.devices[deviceKeyId], states[deviceKeyId] == nil else {
            lock.unlock()
            return .noDevice
        }
        let push = Push(token: token, env: env, locale: locale)
        if row.push == push {
            lock.unlock()
            return .unchanged
        }
        for (other, d) in model.devices where other != deviceKeyId && d.push?.token == token {
            guard d.clientDeviceId == row.clientDeviceId else {
                lock.unlock()
                return .conflict
            }
        }
        for (other, d) in model.devices where other != deviceKeyId && d.push?.token == token {
            model.devices[other]?.push = nil
        }
        model.devices[deviceKeyId]?.push = push
        _version += 1
        writeLocked()
        let notify = onPushTargetsChanged
        lock.unlock()
        notify?()
        return .stored
    }

    /// APNs が無効と答えたトークンを外す。
    func clearPush(token: String) {
        lockLoaded()
        var changed = false
        for (k, d) in model.devices where d.push?.token == token {
            model.devices[k]?.push = nil
            changed = true
        }
        if changed {
            _version += 1
            writeLocked()
        }
        let notify = changed ? onPushTargetsChanged : nil
        lock.unlock()
        notify?()
    }

    /// push を送れる端末（確定済みで宛先がある行）。
    func pushTargets() -> [(deviceKeyId: String, device: Device, push: Push)] {
        withLock {
            model.devices.compactMap { k, d in
                guard states[k] == nil, let p = d.push else { return nil }
                return (k, d, p)
            }.sorted { $0.deviceKeyId < $1.deviceKeyId }
        }
    }

    // MARK: - 長いポーリング（`/local/devices/events`）

    /// `since` か `boot` が今の値と違えばすぐ、そうでなければ変わるか `timeout` 秒たつまで待つ。
    func waitForChange(since: Int?, boot: String?, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            if since != version || boot != bootId { return }
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func lockLoaded() {
        lock.lock()
        ensureLoadedLocked()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lockLoaded()
        defer { lock.unlock() }
        return body()
    }
}
