import Foundation

/// Live Activity に出ている値（Apple に平文で渡すのは phase と 2 つの数だけ。docs/BACKGROUND_CONTROL_2026-10-21.md §8.1）。
struct LiveActivityState: Equatable, Sendable {
    /// running / done / failed / stopped
    var phase: String
    var running: Int
    var failed: Int
}

/// Live Activity の送り方の規則（純粋な部分。§8.7）。時計（UNIX 秒）と batch の id は外から渡す。
/// 規則は shared/fixtures/live-activity/publisher-cases.json の同じケースで Windows（liveActivity/rules.ts）と揃える。
/// 登録簿への送信・端末ごとの token・WS への知らせは LiveActivityPublisher が受け持つ。
struct LiveActivityRules {
    static let endGrace = 20
    static let minInterval = 10
    static let keepalive = 600
    static let staleAfter = 1500
    static let dismissDone = 300
    static let dismissFailed = 900
    static let endedMemory = 900
    /// 登録簿が受ける数の上限（running は 1〜999、failed は 0〜999。超えると 400 で何も届かない）。
    static let countCap = 999

    /// 送る push 1 件（宛先は device + activityId。token は publisher が引く）。
    struct Push: Equatable, Sendable {
        var t: Int
        var device: String
        var activityId: String
        /// update / end
        var event: String
        var priority: Int
        var state: LiveActivityState
        var staleAfterSec: Int?
        var dismissAfterSec: Int?
        /// stale-date を延ばすだけの更新（比べない）
        var keepalive = false
    }

    /// background_work_state の中身（rev・boot・push・now は publisher が足す）。
    struct BatchState: Equatable, Sendable {
        var t: Int
        var batch: String?
        var phase: String
        var running: Int
        var failed: Int
        var since: Int?
    }

    private struct Batch {
        var id: String
        var since: Int
        var running: Int
        var done = 0
        var failed = 0
        var stopped = 0
        var endAt: Int?
    }

    private struct Ended {
        var id: String
        var since: Int
        var phase: String
        var failed: Int
        var at: Int
    }

    private struct Target {
        var device: String
        var activityId: String
        var batch: String
        /// LA に出ている数（アプリが始めたときの数か、最後に送った数）
        var shown: (running: Int, failed: Int)
        var lastPushAt: Int?
        var registeredAt: Int
    }

    private let now: () -> Int
    private let newBatchId: () -> String
    private var batch: Batch?
    private var lastEnded: Ended?
    /// 入れた順（同じ秒に何本も終わるとき、push の順番を決める）。
    private var targets: [Target] = []
    private var pushes: [Push] = []
    private var states: [BatchState] = []

    init(now: @escaping () -> Int, newBatchId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.now = now
        self.newBatchId = newBatchId
    }

    // MARK: - 出力

    /// たまった push を取り出す。
    mutating func takePushes() -> [Push] {
        defer { pushes.removeAll() }
        return pushes
    }

    /// たまった状態の変化を取り出す。
    mutating func takeStates() -> [BatchState] {
        defer { states.removeAll() }
        return states
    }

    /// いまの状態（batch の中なら running、終えて 15 分以内ならその終わり、それ以外は idle）。
    var currentState: BatchState {
        let t = now()
        if let b = batch {
            return BatchState(t: t, batch: b.id, phase: "running", running: b.running, failed: b.failed, since: b.since)
        }
        if let e = lastEnded {
            return BatchState(t: t, batch: e.id, phase: e.phase, running: 0, failed: e.failed, since: e.since)
        }
        return BatchState(t: t, batch: nil, phase: "idle", running: 0, failed: 0, since: nil)
    }

    /// batch がある（動いている）か。
    var hasBatch: Bool { batch != nil }
    /// 時計を進める必要があるか（batch・token・覚えている終えた batch のどれかがある）。
    var isActive: Bool { batch != nil || lastEnded != nil || !targets.isEmpty }
    /// 宛先として持っている (device, activityId)。
    func hasTarget(device: String, activityId: String) -> Bool {
        targets.contains { $0.device == device && $0.activityId == activityId }
    }

    // MARK: - 入力

    /// いまの running（3 つの出どころを合わせた数）。
    mutating func counts(_ running: Int) {
        let running = min(running, Self.countCap)
        let t = now()
        guard var b = batch else {
            if running <= 0 { return tick() }
            batch = Batch(id: newBatchId(), since: t, running: running)
            lastEnded = nil
            publish()
            return tick()
        }
        if b.running != running {
            b.running = running
            if running > 0 {
                b.endAt = nil
            } else if b.endAt == nil {
                b.endAt = t + Self.endGrace
            }
            batch = b
            publish()
        }
        tick()
    }

    /// 終わった数（batch の外では捨てる）。
    mutating func finished(done: Int = 0, failed: Int = 0, stopped: Int = 0) {
        guard batch != nil else { return tick() }
        batch?.done += done
        if let current = batch?.failed { batch?.failed = min(current + failed, Self.countCap) }
        batch?.stopped += stopped
        if failed > 0 { publish() }
        tick()
    }

    /// アプリが始めた LA の token。今の batch か覚えている終えた batch のものでなければ受けない（false）。
    @discardableResult
    mutating func register(device: String, activityId: String, batch id: String, shownRunning: Int, shownFailed: Int) -> Bool {
        let known = batch?.id == id || lastEnded?.id == id
        guard known else {
            tick()
            return false
        }
        let t = now()
        if let i = targets.firstIndex(where: { $0.device == device && $0.activityId == activityId }) {
            targets[i].batch = id
            targets[i].registeredAt = t
        } else {
            targets.append(Target(device: device, activityId: activityId, batch: id,
                                  shown: (shownRunning, shownFailed), lastPushAt: nil, registeredAt: t))
        }
        tick()
        return true
    }

    mutating func clear(device: String, activityId: String) {
        targets.removeAll { $0.device == device && $0.activityId == activityId }
        tick()
    }

    // MARK: - 時計

    mutating func tick() {
        let t = now()
        if let b = batch, b.running == 0, let endAt = b.endAt, t >= endAt {
            let phase = b.failed > 0 ? "failed" : (b.stopped > 0 && b.done == 0 ? "stopped" : "done")
            lastEnded = Ended(id: b.id, since: b.since, phase: phase, failed: b.failed, at: t)
            batch = nil
            publish()
        }
        // 終えた batch の token には、すぐ終わりを送る。
        if let e = lastEnded {
            let state = LiveActivityState(phase: e.phase, running: 0, failed: e.failed)
            let dismiss = e.phase == "failed" ? Self.dismissFailed : Self.dismissDone
            for tg in targets where tg.batch == e.id {
                pushes.append(Push(t: t, device: tg.device, activityId: tg.activityId, event: "end", priority: 10,
                                   state: state, staleAfterSec: nil, dismissAfterSec: dismiss))
            }
            targets.removeAll { $0.batch == e.id }
            if t - e.at >= Self.endedMemory, batch == nil {
                lastEnded = nil
                publish()
            }
        }
        // 実行中の更新
        if let cur = batch, cur.running > 0 {
            let want = LiveActivityState(phase: "running", running: cur.running, failed: cur.failed)
            for i in targets.indices where targets[i].batch == cur.id {
                let tg = targets[i]
                if tg.shown.running != want.running {
                    if tg.lastPushAt == nil || t - tg.lastPushAt! >= Self.minInterval {
                        emitUpdate(i, want, keepalive: false, t)
                    }
                } else if t - (tg.lastPushAt ?? tg.registeredAt) >= Self.keepalive {
                    emitUpdate(i, want, keepalive: true, t)
                }
            }
        }
        // 知らない batch の token は捨てる（その LA はアプリが自分で終える）。
        targets.removeAll { tg in !(tg.batch == batch?.id || tg.batch == lastEnded?.id) }
    }

    private mutating func emitUpdate(_ i: Int, _ state: LiveActivityState, keepalive: Bool, _ t: Int) {
        pushes.append(Push(t: t, device: targets[i].device, activityId: targets[i].activityId, event: "update", priority: 5,
                           state: state, staleAfterSec: Self.staleAfter, dismissAfterSec: nil, keepalive: keepalive))
        targets[i].shown = (state.running, state.failed)
        targets[i].lastPushAt = t
    }

    private mutating func publish() {
        states.append(currentState)
    }
}
