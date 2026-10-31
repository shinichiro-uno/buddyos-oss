import Foundation

/// 常駐の claude（-p --input-format stream-json）の stdout の行が、どのターンのものかを決める。
/// 規則は docs/BACKGROUND_WORK_2026-10-21.md §3.3（実測: probe-uuid の U1〜U3、probe-stream の S1・S3r・S9・S11。claude 2.1.300）。
///
/// - stdin の user 行には uuid（Turn.messageId の小文字）を付ける。CLI は command_lifecycle（queued / started / completed）を出し、
///   system/status の user_message_uuids、最初の stream_event と assistant、result の user_message_uuid(s) にその uuid を返す。
/// - 出力の宛先は 3 つ: なし / 発話のターン（messageId の列）/ 知らせのターン（合成の messageId）。
///   知らせのターンは、バックグラウンドの作業が終わったときに CLI が自分から始めるターン。stdout に user 行は出ず、
///   status にも result にも uuid が無い（result には origin = task-notification が付く）。待つ人はいない。
/// - 生成中に差し込んだ発話は今のターンに合流し、result は 2 通分で 1 つ（U2）。差し込んだ発話が始まったら、以後の本文は
///   その発話の messageId で流す（差し込んだ発話の下の新しい吹き出し）。result が覆うターンは全部閉じる。
/// - command_lifecycle を一度も見ていない（uuid を返さない古い CLI）ときだけ、今までどおり先頭のターンへ結ぶ（FIFO）。
/// - interrupt の返事（control_response）で閉じたターンの残り（中断の result まで）は捨てる。
///
/// 値型。呼び出し側のロック（procLock）の下で使う。プロセス（世代）ごとに 1 つ持つ。
struct ClaudeTurnRouter {
    /// stdin に書いた発話のターン。
    struct Registered: Equatable {
        let messageId: String
        /// stdin の user 行に付けた uuid（messageId の小文字）
        let uuid: String
        /// CLI がこの発話のターンを始めた（command_lifecycle started か、行の uuid で見た）
        var started = false
    }

    /// 閉じるターン。done は doneMessageId で 1 回だけ出す。
    struct Closure: Equatable {
        /// 閉じる発話のターン（stdin に書いた順）
        var messageIds: [String] = []
        /// 閉じる知らせのターン
        var notificationId: String?
        /// 中断で閉じる（result error_during_execution・interrupt の返事・cancelled）。エラーにはしない。
        var interrupted = false
        /// done を出すか。false は、ほかのターンが出力している間に、始まっていない発話だけを静かに閉じるとき。
        var emitsDone = true

        var isEmpty: Bool { messageIds.isEmpty && notificationId == nil }
        /// done を出すターン（最後の発話。無ければ知らせのターン）
        var doneMessageId: String? { messageIds.last ?? notificationId }
        /// 知らせのターンだけを閉じる（done に origin = task-notification を付ける）
        var notificationOnly: Bool { messageIds.isEmpty && notificationId != nil }
    }

    /// 1 行を読んだ結果。
    struct Step: Equatable {
        /// 出力の行なら、本文を流す先のターンの messageId
        var output: String?
        /// 出力の宛先が替わった（差し込んだ発話が始まった・知らせのターンに発話が合流した）。直前の宛先の messageId
        /// （呼び出し側は吹き出しを区切る）
        var switchedFrom: String?
        /// この行で開いた知らせのターンの messageId
        var openedNotification: String?
        /// 閉じるターン
        var closure: Closure?
        /// 閉じたターンの残り（中断の後の行・閉じた発話の uuid の行）。本文にも done にも使わない
        var swallowed = false
        /// result の行か
        var isResult = false
    }

    /// 閉じた発話の uuid を覚えておく数（後から届いた、そのターンの行を見分ける）。
    static let closedMemory = 64

    private(set) var registered: [Registered] = []
    /// 出力の宛先の発話のターン（始まった順。差し込んだ発話が合流すると増える。本文は最後のものへ流す）
    private(set) var outputTurns: [String] = []
    /// 出力の宛先の知らせのターン
    private(set) var notificationId: String?
    /// command_lifecycle を一度でも見たか（見ていなければ uuid を返さない古い CLI として FIFO で結ぶ）
    private(set) var sawLifecycle = false
    /// 今の CLI のターンで本文の差分（text_delta）を見たか。見ていなければ result の本文を本文にする。
    private(set) var sawTextDelta = false
    /// interrupt の返事でターンを閉じた後。中断した CLI のターンの残りを、その result（か次のターンの始まり）まで捨てる。
    private(set) var draining = false
    private var closedUuids: [String] = []
    private let makeId: () -> String

    init(makeId: @escaping () -> String = { UUID().uuidString }) {
        self.makeId = makeId
    }

    /// 出力の宛先が無い（CLI のターンの外）
    var isIdle: Bool { outputTurns.isEmpty && notificationId == nil }
    /// 本文を流す先（最後に始まった発話。無ければ知らせのターン）
    var current: String? { outputTurns.last ?? notificationId }

    // MARK: - stdin に書いた発話

    /// stdin に書く前に呼ぶ（書いてから登録すると、速い応答の行を取りこぼす）。
    mutating func register(messageId: String) {
        let uuid = messageId.lowercased()
        guard !registered.contains(where: { $0.uuid == uuid }) else { return }
        registered.append(Registered(messageId: messageId, uuid: uuid))
    }

    /// stdin に書けなかった発話を外す。
    mutating func unregister(messageId: String) {
        registered.removeAll { $0.messageId == messageId }
        outputTurns.removeAll { $0 == messageId }
    }

    // MARK: - stdout の行

    /// stdout の 1 行（JSON）を読む。ターンの出力でない行（system/init・task_*・background_tasks_changed・
    /// サブエージェントの行・hook の行など）は空の Step を返す。
    mutating func ingest(_ obj: [String: Any]) -> Step {
        switch obj["type"] as? String {
        case "command_lifecycle":
            return lifecycle(obj)
        case "result":
            return result(obj)
        case "system":
            switch obj["subtype"] as? String {
            case "init":
                // CLI のターンはどれも init から始まる。中断したターンの残りはもう来ない。
                draining = false
                return Step()
            case "status":
                // API を呼ぶたびに出る（status: requesting）。null は待ちの終わりなので出力ではない。
                guard let s = obj["status"] as? String, !s.isEmpty else { return Step() }
                return output(obj)
            default:
                return Step()
            }
        case "stream_event", "assistant", "user":
            // サブエージェントの行（parent_tool_use_id に親の tool_use id）はターンの出力ではない
            // （メインの行は null = NSNull）。
            guard !(obj["parent_tool_use_id"] is String) else { return Step() }
            return output(obj)
        default:
            return Step()
        }
    }

    /// JSON でない行（壊れた出力など）。今の宛先へ流す。宛先が無ければ、古い CLI のときだけ先頭の発話へ。
    mutating func routeRawText() -> Step {
        var step = Step()
        if draining { step.swallowed = true; return step }
        if isIdle, !sawLifecycle, let i = registered.indices.first {
            join(i)
        }
        step.output = current
        return step
    }

    /// interrupt の返事（control_response）。止めると決めたとき（interrupt を書いたとき）にあったターン（targets）を
    /// 中断として閉じる。stillQueued（中断を生き延びて、まだ走る発話の uuid。cancel_queued を知らない古い CLI）は閉じない。
    /// CLI のターンが動いていたら、その残り（中断の result まで）を捨てる。
    mutating func acknowledgeInterrupt(targets: Set<String>, stillQueued: [String]) -> Closure {
        let survivors = Set(stillQueued.map { $0.lowercased() })
        // 生き延びた発話はまだ走っていない（走り出す前の待ち行列）。宛先から外して、始まりを待ち直す。
        for i in registered.indices where survivors.contains(registered[i].uuid) {
            outputTurns.removeAll { $0 == registered[i].messageId }
            registered[i].started = false
        }
        let ids = registered.filter { targets.contains($0.messageId) && !survivors.contains($0.uuid) }.map(\.messageId)
        let closesNotification = notificationId.map { targets.contains($0) } ?? false
        let closure = close(ids, notification: closesNotification, interrupted: true)
        if !closure.isEmpty {
            draining = true
            sawTextDelta = false
        }
        return closure
    }

    // MARK: - 中身

    private mutating func lifecycle(_ obj: [String: Any]) -> Step {
        sawLifecycle = true
        var step = Step()
        guard let uuid = (obj["command_uuid"] as? String)?.lowercased(),
              let i = registered.firstIndex(where: { $0.uuid == uuid }) else { return step }
        switch obj["state"] as? String {
        case "started":
            draining = false
            let before = current
            join(i)
            if let before, before != current { step.switchedFrom = before }
        case "completed":
            // 取りこぼしの保険: 始まってもいないのに終わった発話だけを閉じる（始まったものは result で閉じる）。
            // ほかのターンが出力している間は done を出さない（done はターンの終わりの印。今のターンを終わらせない）。
            guard !registered[i].started else { break }
            step.closure = close([registered[i].messageId], notification: false, interrupted: false, emitsDone: isIdle)
        case "cancelled", "canceled":
            // interrupt の cancel_queued などで取り消された（走らない）。
            let id = registered[i].messageId
            outputTurns.removeAll { $0 == id }
            step.closure = close([id], notification: false, interrupted: true, emitsDone: isIdle)
        default:
            break
        }
        return step
    }

    /// 出力の行（system/status・メインの stream_event / assistant / user）。
    private mutating func output(_ obj: [String: Any]) -> Step {
        var step = Step()
        let names = Self.uuids(obj)
        let named = registered.indices.filter { names.contains(registered[$0].uuid) }
        let before = current
        if !named.isEmpty {
            // この行が名指しする発話を始める（status / 最初の stream_event と assistant が uuid を持つ）。
            draining = false
            for i in named { join(i) }
        } else if !names.isEmpty, names.allSatisfy({ closedUuids.contains($0) }) {
            // 閉じた発話のターンの行（中断した後の残りなど）
            step.swallowed = true
            return step
        } else if draining {
            step.swallowed = true
            return step
        }
        if isIdle {
            if !sawLifecycle, let i = registered.indices.first {
                // 古い CLI: 今までどおり先頭の発話へ
                join(i)
            } else {
                // 発話の無いターン = 知らせのターン（待つ人はいない）
                let id = makeId()
                notificationId = id
                step.openedNotification = id
            }
        }
        if let before, let now = current, before != now { step.switchedFrom = before }
        step.output = current
        if Self.isTextDelta(obj) { sawTextDelta = true }
        return step
    }

    /// result。閉じるターンは次の順に決める（§3.3）。
    /// 1. result.user_message_uuids（無ければ user_message_uuid）にある登録済みの発話
    /// 2. 宛先の発話（合流した差し込みを含む。1 に足す）
    /// 3. どれも無く、宛先も無く、command_lifecycle を見ていない → 先頭の発話（古い CLI）
    /// 4. 開いている知らせのターン
    /// 名指しした発話が全部閉じたものなら、そのターンの result（中断の後など）なので何も閉じない。
    private mutating func result(_ obj: [String: Any]) -> Step {
        var step = Step()
        step.isResult = true
        defer { sawTextDelta = false }
        let names = Self.uuids(obj)
        let named = registered.filter { names.contains($0.uuid) }.map(\.messageId)
        if draining {
            draining = false
            // 中断したターンの result。閉じてある。
            if named.isEmpty {
                step.swallowed = true
                return step
            }
        }
        if named.isEmpty, !names.isEmpty, names.allSatisfy({ closedUuids.contains($0) }) {
            step.swallowed = true
            return step
        }
        var ids = named
        for id in outputTurns where !ids.contains(id) { ids.append(id) }
        if ids.isEmpty, isIdle, !sawLifecycle, let first = registered.first {
            ids = [first.messageId]
        }
        let interrupted = obj["subtype"] as? String == "error_during_execution"
        let closure = close(ids, notification: true, interrupted: interrupted)
        step.closure = closure.isEmpty ? nil : closure
        return step
    }

    /// 発話を出力の宛先に入れる（始まった印を付ける）。既に宛先にあれば何もしない。
    private mutating func join(_ i: Int) {
        registered[i].started = true
        let id = registered[i].messageId
        if !outputTurns.contains(id) { outputTurns.append(id) }
    }

    private mutating func close(_ ids: [String], notification: Bool, interrupted: Bool,
                                emitsDone: Bool = true) -> Closure {
        var closure = Closure()
        closure.interrupted = interrupted
        closure.emitsDone = emitsDone
        let closing = registered.filter { ids.contains($0.messageId) }
        closure.messageIds = closing.map(\.messageId)
        for r in closing { remember(r.uuid) }
        registered.removeAll { ids.contains($0.messageId) }
        outputTurns.removeAll { ids.contains($0) }
        if notification, let id = notificationId {
            closure.notificationId = id
            notificationId = nil
        }
        return closure
    }

    private mutating func remember(_ uuid: String) {
        closedUuids.removeAll { $0 == uuid }
        closedUuids.append(uuid)
        if closedUuids.count > Self.closedMemory { closedUuids.removeFirst(closedUuids.count - Self.closedMemory) }
    }

    /// 行が名指しする発話の uuid（user_message_uuids と user_message_uuid。小文字）。
    static func uuids(_ obj: [String: Any]) -> [String] {
        var out: [String] = []
        for v in (obj["user_message_uuids"] as? [Any]) ?? [] {
            if let s = (v as? String)?.lowercased(), !s.isEmpty, !out.contains(s) { out.append(s) }
        }
        if let s = (obj["user_message_uuid"] as? String)?.lowercased(), !s.isEmpty, !out.contains(s) { out.append(s) }
        return out
    }

    /// 本文の差分の行か（--include-partial-messages の stream_event text_delta）。
    static func isTextDelta(_ obj: [String: Any]) -> Bool {
        let delta = ((obj["event"] as? [String: Any])?["delta"] as? [String: Any]) ?? (obj["delta"] as? [String: Any])
        return delta?["type"] as? String == "text_delta"
    }
}
