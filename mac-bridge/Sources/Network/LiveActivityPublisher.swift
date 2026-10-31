import Foundation

/// LiveActivityPublisher が使う送り口（登録簿への HTTP）。テストでは偽物に差し替える。
struct LiveActivitySender: Sendable {
    /// pushMode が none でなく、端末トークン（bdt_）と登録簿のサイトがあるか。
    var enabled: @Sendable () -> Bool
    /// `/v3/live-activity-targets` に登録する。戻り値は HTTP の状態（通信の失敗は 0）。
    var targets: @Sendable ([(token: String, env: String)]) async -> Int
    /// `/v3/live-activity` に 1 件送る。
    var send: @Sendable (_ token: String, _ env: String, _ event: String, _ state: LiveActivityState,
                         _ timestamp: Int, _ staleAfterSec: Int?, _ dismissAfterSec: Int?) async -> LiveActivitySendResult

    static let live = LiveActivitySender(
        enabled: {
            BridgeConfig.current.pushMode.value != .none && KeyStore.deviceToken() != nil && PushService.convexSite() != nil
        },
        targets: { await PushService.shared.liveActivityTargets($0) },
        send: { token, env, event, state, timestamp, stale, dismiss in
            await PushService.shared.sendLiveActivity(token: token, env: env, event: event, state: state,
                                                      timestamp: timestamp, staleAfterSec: stale, dismissAfterSec: dismiss)
        }
    )
}

/// ロック画面と Dynamic Island の「バックグラウンドで n 件実行中」を動かす（docs/BACKGROUND_CONTROL_2026-10-21.md §8）。
/// 3 つの出どころの数を合わせて batch を作り（規則は LiveActivityRules）、`background_work_state` を .device の WS へ送り、
/// アプリが始めた LA の token へ登録簿（Convex）経由で更新と終わりを送る。名前・本文・session id は Apple に渡さない。
actor LiveActivityPublisher {
    static let shared = LiveActivityPublisher()

    enum Source: Int, Sendable { case hub, panes, bg }

    /// background_work_state をまとめる間隔（秒）。
    static let wsCoalesce = 1.0
    static let tokenLifetime = 12.0 * 3600
    static let perDeviceLimit = 4
    static let totalLimit = 8
    static let activityIdPattern = "^[A-Za-z0-9-]{1,64}$"
    static let tokenPattern = "^[0-9a-f]{64,400}$"
    static let batchPattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

    enum RegisterResult: Equatable, Sendable {
        case accepted
        case rejected(String)
    }

    private struct Key: Hashable {
        var device: String
        var activityId: String
    }

    private struct TokenInfo {
        var token: String
        var env: String
        var order: Int
        var registeredAt: Double
    }

    private struct Pending {
        var push: LiveActivityRules.Push
        var id: Int
        var createdAt: Double
        var notBefore: Double
        var tries = 0
        var unknownRetried = false
    }

    /// WS に送る値のうち、変わったら rev を進める項目。
    private struct Payload: Equatable {
        var push: Bool
        var batch: String?
        var phase: String
        var running: Int
        var failed: Int
        var since: Int?
    }

    private let sender: LiveActivitySender
    private let clock: @Sendable () -> Double
    private let autoTick: Bool
    private let boot = UUID().uuidString.lowercased()
    private var rules: LiveActivityRules

    private var sources: [Source: (seq: UInt64, counts: [String: Int])] = [:]
    private var listeners: [UUID: @Sendable (SessionEvent) -> Void] = [:]
    private var rev = 0
    private var lastPayload = Payload(push: false, batch: nil, phase: "idle", running: 0, failed: 0, since: nil)
    private var lastBroadcastAt = 0.0
    private var loggedBatch: String?

    private var tokens: [Key: TokenInfo] = [:]
    private var tokenOrder = 0
    private var outbox: [Key: Pending] = [:]
    private var pendingId = 0

    private(set) var ready = false
    private var holdUntil = 0.0
    private var flushing = false
    private var syncedHashes: Set<String> = []
    private var syncing = false
    private var syncDirty = false
    private var syncNotBefore = 0.0
    private var syncFailures = 0
    private var recheckTask: Task<Void, Never>?
    /// 登録簿の確かめ直しを予約した秒数（テスト用の記録。autoTick が false のときは予約だけ記録して待たない）。
    private(set) var recheckDelay: Double?
    /// 登録簿への登録が通ったときに registryReady で確かめ直す必要があるか（初めと、401 / 403 で ready を落としたあと）。
    private(set) var needsRegistryCheck = true
    private var registryChecking = false
    private var lastRegistryCheckAt = -Double.infinity
    private var tickTask: Task<Void, Never>?

    init(sender: LiveActivitySender = .live, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         newBatchId: @escaping () -> String = { UUID().uuidString.lowercased() }, autoTick: Bool = true) {
        self.sender = sender
        self.clock = clock
        self.autoTick = autoTick
        self.rules = LiveActivityRules(now: { Int(clock()) }, newBatchId: newBatchId)
    }

    // MARK: - 入力

    /// 出どころごとの最新の数（key → 数）。古い seq は捨てる。同じ key は出どころをまたいで大きい方を取り、key ごとを足す。
    func noteSource(_ source: Source, counts: [String: Int], seq: UInt64) async {
        if let current = sources[source], seq <= current.seq { return }
        sources[source] = (seq, counts)
        rules.counts(runningTotal)
        afterRules()
        await pump()
    }

    /// 終わった数（SessionHub の lastFinished・bg の見張りの遷移・外した entry の分）。
    func noteFinished(done: Int = 0, failed: Int = 0, stopped: Int = 0) async {
        guard done > 0 || failed > 0 || stopped > 0 else { return }
        rules.finished(done: done, failed: failed, stopped: stopped)
        afterRules()
        await pump()
    }

    /// `register_activity_token`（.device の WS から。§8.6）。形が合わなければ捨ててログに出す。
    @discardableResult
    func register(deviceKeyId: String, token rawToken: String, metadata: [String: String], order: UInt64? = nil) async -> RegisterResult {
        let token = rawToken.lowercased()
        let reject = { (reason: String) -> RegisterResult in
            WebSocketServer.wslog("[LiveActivity] register rejected reason=\(reason) token=\(rawToken.prefix(8))…")
            return .rejected(reason)
        }
        guard !deviceKeyId.isEmpty else { return reject("device") }
        guard Self.matches(token, Self.tokenPattern) else { return reject("token") }
        guard let activityId = metadata["activityId"], Self.matches(activityId, Self.activityIdPattern) else { return reject("activityId") }
        guard let batch = metadata["batch"], Self.matches(batch, Self.batchPattern) else { return reject("batch") }
        let env = metadata["environment"]?.lowercased() == "production" ? "production" : "development"
        let key = Key(device: deviceKeyId, activityId: activityId)
        // 届いた順より後に処理される古い要求（先に来た register が clear の後に動く）は捨てる。
        guard acceptOrder(order, key: key) else { return reject("stale") }
        guard rules.register(device: deviceKeyId, activityId: activityId, batch: batch,
                             shownRunning: Self.count(metadata["running"]), shownFailed: Self.count(metadata["failed"])) else {
            return reject("unknown batch")
        }
        let now = clock()
        let changed = tokens[key]?.token != token
        tokenOrder += 1
        tokens[key] = TokenInfo(token: token, env: env, order: tokenOrder, registeredAt: now)
        evictOverLimits(keeping: key)
        if changed { markSync(immediate: true) }
        afterRules()
        await pump()
        return .accepted
    }

    /// key ごとに、いちばん新しく処理した要求の番号（`nextSeq()` で届いた順に振ったもの）。それ以前の要求は捨てる。
    private var lastOrder: [Key: UInt64] = [:]

    private func acceptOrder(_ order: UInt64?, key: Key) -> Bool {
        guard let order else { return true }
        if let last = lastOrder[key], order <= last { return false }
        lastOrder[key] = order
        if lastOrder.count > 4 * Self.totalLimit {
            lastOrder = lastOrder.filter { tokens[$0.key] != nil || $0.key == key }
        }
        return true
    }

    /// LA が外れた（アプリが終えた・利用者が消した）。以後その token には何も送らない。
    func clear(deviceKeyId: String, activityId: String, order: UInt64? = nil) async {
        let key = Key(device: deviceKeyId, activityId: activityId)
        guard acceptOrder(order, key: key) else { return }
        rules.clear(device: deviceKeyId, activityId: activityId)
        outbox.removeValue(forKey: key)
        if tokens.removeValue(forKey: key) != nil { markSync(immediate: false) }
        afterRules()
        await pump()
    }

    /// 登録簿への登録が通るたびに呼ぶ。ready でなく、確かめが要るときだけ registryReady を（1 つずつ、60 秒空けて）実行する。
    func registryReadyIfNeeded() async {
        guard needsRegistryCheck, !ready, !registryChecking, clock() - lastRegistryCheckAt >= 60 else { return }
        registryChecking = true
        lastRegistryCheckAt = clock()
        await registryReady()
        registryChecking = false
    }

    /// 登録簿への登録が初めて成功したとき。`{"targets":[]}` で確かめ、通れば ready にして token を登録し直す。
    func registryReady() async {
        guard sender.enabled() else { return setReady(false) }
        let status = await sender.targets([])
        switch status {
        case 200:
            setReady(true)
            recheckTask?.cancel()
            recheckDelay = nil
            needsRegistryCheck = false
            syncedHashes = []
            syncFailures = 0
            // token が無ければ、確かめの {targets:[]} が同期の代わりになる。
            if !tokens.isEmpty { markSync(immediate: true) }
            await pump()
        case 404:
            needsRegistryCheck = false
            setReady(false)
            scheduleRecheck(3600)
        case 429, 500...599, 0:
            needsRegistryCheck = false
            setReady(false)
            scheduleRecheck(300)
        case 401, 403:
            // bdt_ の期限切れなど。次に登録簿へ登録できたときに確かめ直す。
            needsRegistryCheck = true
            setReady(false)
        default:
            needsRegistryCheck = false
            setReady(false)
            scheduleRecheck(3600)
        }
    }

    // MARK: - WS

    /// .device の WS が background_work_state を受ける。登録したときに今の値を 1 回送る。
    func register(send: @escaping @Sendable (SessionEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = send
        send(stateEvent())
        return id
    }

    func unregister(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func stateEvent() -> SessionEvent {
        let p = lastPayload
        let obj: [String: Any] = [
            "v": 1, "boot": boot, "rev": rev, "push": p.push,
            "batch": p.batch.map { $0 as Any } ?? NSNull(), "phase": p.phase, "running": p.running, "failed": p.failed,
            "since": p.since.map { $0 as Any } ?? NSNull(), "now": Int(clock()),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return .backgroundWorkState(String(data: data, encoding: .utf8) ?? "{}")
    }

    /// 値が変わっていれば送る。batch の始まりと終わり・push の切り替えはすぐ、数の変化は 1 秒まとめる。
    private func broadcastIfNeeded() {
        let cur = currentPayload
        guard cur != lastPayload else { return }
        let now = clock()
        let urgent = cur.batch != lastPayload.batch || cur.phase != lastPayload.phase || cur.push != lastPayload.push
        guard urgent || now - lastBroadcastAt >= Self.wsCoalesce else { return }
        rev += 1
        lastPayload = cur
        lastBroadcastAt = now
        let event = stateEvent()
        for send in listeners.values { send(event) }
    }

    private func setReady(_ value: Bool) {
        guard ready != value else { return }
        ready = value
        WebSocketServer.wslog("[LiveActivity] ready=\(value)")
        broadcastIfNeeded()
    }

    // MARK: - 数

    /// 3 つの出どころの合計（同じ key は大きい方）。
    var runningTotal: Int {
        var merged: [String: Int] = [:]
        for source in sources.values {
            for (key, n) in source.counts where n > 0 { merged[key] = max(merged[key] ?? 0, n) }
        }
        return merged.values.reduce(0, +)
    }

    // MARK: - 規則の出力

    private func afterRules() {
        let now = clock()
        for p in rules.takePushes() { enqueue(p, now: now) }
        for s in rules.takeStates() { logBatch(s) }
        broadcastIfNeeded()
        ensureTicking()
    }

    private func logBatch(_ s: LiveActivityRules.BatchState) {
        if s.phase == "running", let id = s.batch, id != loggedBatch {
            loggedBatch = id
            WebSocketServer.wslog("[LiveActivity] batch start id=\(id.prefix(8)) running=\(s.running) phase=\(s.phase)")
        } else if s.phase != "running", s.phase != "idle", let id = s.batch, id == loggedBatch {
            loggedBatch = nil
            WebSocketServer.wslog("[LiveActivity] batch end id=\(id.prefix(8)) running=\(s.running) phase=\(s.phase)")
        }
    }

    private func enqueue(_ p: LiveActivityRules.Push, now: Double) {
        let key = Key(device: p.device, activityId: p.activityId)
        guard tokens[key] != nil else { return }
        let existing = outbox[key]
        // 終わりを待っているところへ、後から更新は重ねない。
        if existing?.push.event == "end", p.event == "update" { return }
        pendingId += 1
        outbox[key] = Pending(push: p, id: pendingId, createdAt: existing?.createdAt ?? now,
                              notBefore: p.event == "end" ? now : (existing?.notBefore ?? now))
    }

    // MARK: - token

    private func evictOverLimits(keeping keep: Key) {
        func drop(_ key: Key) {
            rules.clear(device: key.device, activityId: key.activityId)
            outbox.removeValue(forKey: key)
            tokens.removeValue(forKey: key)
            markSync(immediate: false)
        }
        let mine = tokens.filter { $0.key.device == keep.device }.sorted { $0.value.order < $1.value.order }
        for (key, _) in mine.prefix(max(0, mine.count - Self.perDeviceLimit)) { drop(key) }
        let all = tokens.sorted { $0.value.order < $1.value.order }
        for (key, _) in all.prefix(max(0, all.count - Self.totalLimit)) { drop(key) }
    }

    private func prune(now: Double) {
        for (key, info) in tokens {
            let expired = now - info.registeredAt >= Self.tokenLifetime
            let orphan = !rules.hasTarget(device: key.device, activityId: key.activityId) && outbox[key] == nil
            if expired || orphan {
                if expired { rules.clear(device: key.device, activityId: key.activityId) }
                outbox.removeValue(forKey: key)
                tokens.removeValue(forKey: key)
                markSync(immediate: false)
            }
        }
        for (key, p) in outbox where now - p.createdAt >= Double(LiveActivityRules.endedMemory) {
            outbox.removeValue(forKey: key)
            if !rules.hasTarget(device: key.device, activityId: key.activityId) {
                tokens.removeValue(forKey: key)
                markSync(immediate: false)
            }
        }
    }

    // MARK: - 宛先の登録

    private func markSync(immediate: Bool) {
        let now = clock()
        if immediate {
            syncNotBefore = now
        } else if !syncDirty {
            syncNotBefore = now + 2
        }
        syncDirty = true
    }

    private func runSync() async {
        let now = clock()
        guard ready, !syncing, syncDirty, now >= syncNotBefore else { return }
        syncing = true
        syncDirty = false
        let list = tokens.values.sorted { $0.order > $1.order }.prefix(Self.totalLimit).map { (token: $0.token, env: $0.env) }
        let hashes = Set(list.map { PushService.tokenHash($0.token) })
        let status = await sender.targets(list)
        syncing = false
        switch status {
        case 200:
            syncedHashes = hashes
            syncFailures = 0
        case 401, 403:
            needsRegistryCheck = true
            setReady(false)
            syncDirty = true
        case 404:
            setReady(false)
            scheduleRecheck(3600)
            syncDirty = true
        default:
            let delays: [Double] = [5, 30, 120]
            syncNotBefore = clock() + delays[min(syncFailures, delays.count - 1)]
            syncFailures += 1
            syncDirty = true
        }
    }

    // MARK: - 送信

    private func pump() async {
        await runSync()
        await flush()
    }

    private func nextSendable(now: Double) -> (Key, Pending, TokenInfo)? {
        guard ready, now >= holdUntil else { return nil }
        for (key, p) in outbox.sorted(by: { $0.value.id < $1.value.id }) where p.notBefore <= now {
            guard let info = tokens[key] else {
                outbox.removeValue(forKey: key)
                continue
            }
            // 登録簿への登録が済むまで待たせる。
            guard syncedHashes.contains(PushService.tokenHash(info.token)) else { continue }
            return (key, p, info)
        }
        return nil
    }

    private func flush() async {
        guard ready, !flushing else { return }
        flushing = true
        defer { flushing = false }
        while let (key, pending, info) = nextSendable(now: clock()) {
            let push = pending.push
            let result = await sender.send(info.token, info.env, push.event, push.state, Int(clock()),
                                           push.staleAfterSec, push.dismissAfterSec)
            handle(result, key: key, pending: pending, info: info)
        }
    }

    /// 登録簿の応答（§8.7 の表）。
    private func handle(_ r: LiveActivitySendResult, key: Key, pending: Pending, info: TokenInfo) {
        let now = clock()
        // 送っている間に新しい値が入っていたら、そちらを残す。
        let current = outbox[key]?.id == pending.id
        func retry(after seconds: Double) {
            guard current else { return }
            outbox[key]?.tries = pending.tries + 1
            outbox[key]?.notBefore = now + seconds
        }
        func drop() {
            guard current else { return }
            outbox.removeValue(forKey: key)
            if pending.push.event == "end" {
                tokens.removeValue(forKey: key)
                markSync(immediate: false)
            }
        }
        switch r.status {
        case 200:
            if r.invalid {
                // 送っている間に token が替わっていたら、新しい token と宛先は残す。
                guard tokens[key]?.token == info.token else {
                    if current { outbox.removeValue(forKey: key) }
                    break
                }
                outbox.removeValue(forKey: key)
                rules.clear(device: key.device, activityId: key.activityId)
                tokens.removeValue(forKey: key)
                markSync(immediate: false)
            } else if r.sent {
                drop()
            } else if pending.push.event == "end" {
                let delays: [Double] = [30, 120, 600]
                if pending.tries < delays.count { retry(after: delays[pending.tries]) } else { drop() }
            } else {
                retry(after: 60)
            }
        case 403 where r.error == "unknown_token":
            if !pending.unknownRetried, current {
                outbox[key]?.unknownRetried = true
                syncedHashes.remove(PushService.tokenHash(info.token))
                markSync(immediate: true)
            } else {
                retry(after: 120)
            }
        case 401, 403:
            needsRegistryCheck = true
            setReady(false)
        case 404:
            setReady(false)
            scheduleRecheck(3600)
        case 429:
            holdUntil = now + (r.retryAfter ?? 60)
        case 400:
            // 形が合わない要求は何度送っても通らない。続けて送らず捨てる（数が変われば新しい要求が入る）。
            WebSocketServer.wslog("[LiveActivity] bad_request event=\(pending.push.event) dropped")
            drop()
        default:
            let delays: [Double] = [30, 120]
            retry(after: delays[min(pending.tries, delays.count - 1)])
        }
    }

    // MARK: - 時計

    private func scheduleRecheck(_ seconds: Double) {
        recheckDelay = seconds
        guard autoTick else { return }
        recheckTask?.cancel()
        recheckTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.registryReady()
        }
    }

    /// 1 秒ごとに呼ぶ。batch・token・送るものが無くなったら false（時計を止める）。
    @discardableResult
    func tick() async -> Bool {
        let now = clock()
        rules.tick()
        afterRules()
        prune(now: now)
        await pump()
        let busy = rules.isActive || !outbox.isEmpty || lastPayload != currentPayload || (ready && syncDirty)
        if !busy { tickTask = nil }
        return busy
    }

    private var currentPayload: Payload {
        let s = rules.currentState
        return Payload(push: ready, batch: s.batch, phase: s.phase, running: s.running, failed: s.failed, since: s.since)
    }

    private func ensureTicking() {
        guard autoTick, tickTask == nil, rules.isActive || !outbox.isEmpty || (ready && syncDirty) else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, await self.tick() else { return }
            }
        }
    }

    // MARK: - 状態の確認

    /// 持っている token の数。
    var tokenCount: Int { tokens.count }

    func hasToken(deviceKeyId: String, activityId: String) -> Bool {
        tokens[Key(device: deviceKeyId, activityId: activityId)] != nil
    }

    /// いまの batch か、終えて 15 分以内の batch の id。
    var currentBatch: String? { rules.currentState.batch }

    // MARK: - 補助

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    /// 0〜999（読めなければ 0）。
    private static func count(_ s: String?) -> Int {
        guard let s, let n = Int(s) else { return 0 }
        return min(max(n, 0), 999)
    }

    // MARK: - 呼び出し口（actor の外から。順番は seq で守る）

    private static let seqLock = NSLock()
    nonisolated(unsafe) private static var seqValue: UInt64 = 0

    /// noteSource に付ける番号。Task で渡すと順番が入れ替わりうるので、呼び出した順に振る。
    static func nextSeq() -> UInt64 {
        seqLock.lock(); defer { seqLock.unlock() }
        seqValue += 1
        return seqValue
    }

    /// 出どころの数を渡す（呼び出し側が actor でも同期で呼べる）。
    static func report(_ source: Source, counts: [String: Int]) {
        let seq = nextSeq()
        Task { await shared.noteSource(source, counts: counts, seq: seq) }
    }

    /// 終わった数を渡す。
    static func reportFinished(done: Int = 0, failed: Int = 0, stopped: Int = 0) {
        guard done > 0 || failed > 0 || stopped > 0 else { return }
        Task { await shared.noteFinished(done: done, failed: failed, stopped: stopped) }
    }

    /// アプリ内ターミナルのペインごとの数（key は sessionId か "pane:<pane>"）。変わったペインだけを渡され、全体にまとめて .panes にする。
    private static let paneLock = NSLock()
    nonisolated(unsafe) private static var paneCounts: [String: Int] = [:]

    static func notePane(key: String, count: Int) {
        paneLock.lock()
        if count > 0 { paneCounts[key] = count } else { paneCounts.removeValue(forKey: key) }
        let snapshot = paneCounts
        // 番号はロックの中で振る（スナップショットを作った順と番号の順を揃える）。
        let seq = nextSeq()
        paneLock.unlock()
        Task { await shared.noteSource(.panes, counts: snapshot, seq: seq) }
    }
}
