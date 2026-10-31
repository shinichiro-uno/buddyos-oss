import Foundation

/// デスクトップのアプリ内ターミナルの、ペインごとのエージェントの状態。
///
/// ペインのシェルには BUDDYOS_PANE_ID が入っていて（desktop/src/main/ptyCore.ts）、その中で動く
/// claude の hook（buddy-hook.sh）が X-BuddyOS-Pane で名乗る。ClaudeTerminalRegistry が hook を
/// 処理したときにここへ書き、デスクトップの main が GET /terminal/panes/poll で long-poll して読む。
/// 端末の出力からの推測（出力が止まった = 終わった）ではなく、Claude Code が知らせた状態をそのまま使うため。
///
/// state:
///   working   main のターンが動いている
///   attention 選択肢（許可確認・質問・計画の承認・MCP のリンクを開く確認）が出ている
///   done      ターンが終わった（turn が 1 つ増える。デスクトップは増えたのを見て「終わった」を知らせる）
///   error     API エラーでターンが終わった
///   idle      Esc で中断した・まだ何もしていない
/// バックグラウンドのサブエージェントとコマンドはターンが終わっても動き続ける（終わると CLI が知らせのターンを始める）。
/// state には混ぜず、動いている数を backgroundAgents / backgroundShells で別に持つ（docs/BACKGROUND_WORK_2026-10-21.md §3.4）。
///
/// hook の処理（ClaudeTerminalRegistry）から同期で書けるよう、actor ではなくロックで守る
/// （Task に投げると、続けて来た hook の順番が入れ替わることがある）。
final class TerminalPaneStatus: @unchecked Sendable {
    static let shared = TerminalPaneStatus()
    private let lock = NSLock()

    struct Entry: Sendable {
        let pane: String
        var state: String
        var sessionId: String?
        var cwd: String?
        /// 終わったターンの数。同じ状態が続いても、新しく終わったことが分かるように。ペインごとに増えるだけ
        /// （SessionEnd で entry が消えても、同じペインの次の会話は続きから数える）。
        var turn: Int
        var updatedAt: Date
        /// そのペインで動いているエージェント（claude / codex …）。
        var agent: String = "claude"
        /// 最後に done になったターンの返事の文（replyLimit 字で切る）。done のときだけ持ち、ほかの状態では消す。
        var reply: String?
        /// 動いているバックグラウンドのサブエージェント（workflow・teammate の行を含む）と、バックグラウンドのコマンド
        /// （Monitor を含む）の数。hook のたびに SubagentTracker から書く。
        var backgroundAgents: Int = 0
        var backgroundShells: Int = 0
        /// backgroundAgents のうち、ターンより長く動く作業（background == true の行）だけ。Live Activity が、ターンが動いている間の
        /// 数に使う（前景のサブエージェントを数えない）。hook のたびに書く。
        var backgroundOnlyAgents: Int = 0
    }

    /// Live Activity に渡す数が変わったとき（ロックの外で呼ぶ）。key はペインの sessionId（無ければ "pane:" + pane）、
    /// 数は state が working / attention なら backgroundOnlyAgents、ほかは backgroundAgents。ペインが無くなったら 0。
    /// 数が変わらなければ呼ばない。
    private(set) var onBackgroundChanged: (@Sendable (_ key: String, _ count: Int) -> Void)?

    /// onBackgroundChanged をロックの中で付け、付ける前に溜まっていた 0 より大きい数を一度に渡す
    /// （起動の途中に届いた hook の数を取りこぼさない）。
    func setOnBackgroundChanged(_ handler: (@Sendable (_ key: String, _ count: Int) -> Void)?) {
        lock.lock()
        onBackgroundChanged = handler
        if let handler {
            for (_, r) in reported where r.count > 0 { handler(r.key, r.count) }
        }
        lock.unlock()
    }
    /// 最後に onBackgroundChanged へ渡したペインごとの (key, 数)。
    private var reported: [String: (key: String, count: Int)] = [:]

    /// reply の上限（字数）。
    static let replyLimit = 16_000
    /// POST /terminal/pane-event で受け付ける state。
    static let states: Set<String> = ["working", "attention", "done", "error", "idle"]
    /// attention にする Notification の notification_type（どれも、答えるまでセッションが止まる確認）。
    static let attentionNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "worker_permission_prompt",
    ]
    /// turnFloor に残すペインの数の上限。
    private static let turnFloorLimit = 512

    /// POST /terminal/pane-event の本文（hook を使わないエージェント。Codex の proxy など）。
    struct PaneEvent: Equatable {
        let pane: String
        let agent: String
        let state: String
        let sessionId: String?
        let cwd: String?
        let reply: String?
    }

    private var entries: [String: Entry] = [:]
    // Bridge を起こし直しても、前の番号を持ったままのデスクトップが待ち続けないように、適当な番号から始める。
    private var version = Int.random(in: 1_000...1_000_000_000)
    /// 前の done の後に main のスレッドの動き（作業中・本文）があったペイン。done が続いても、動きがあれば 1 回に数える。
    private var active: Set<String> = []
    /// entry を消したペインの turn。同じペインで次に動く会話（/clear の後など）は、ここから数える
    /// （デスクトップは turn が増えたのを見て「終わった」を知らせ、音声会話は返事を読む。0 に戻すと前の回数を超えるまで黙る）。
    private var turnFloor: [String: Int] = [:]

    /// ペイン ID として受け付ける形（UUID 等）。ヘッダから来るので形を確かめる。
    static func validPane(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.count <= 64,
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return s
    }

    /// エージェント名として受け付ける形（小文字・数字・ハイフン、32 字まで）。
    static func validAgent(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.count <= 32,
              s.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { return nil }
        return s
    }

    /// POST /terminal/pane-event の本文を確かめる。形が違えば nil（400）。agent が無ければ claude。
    static func paneEvent(_ obj: [String: Any]) -> PaneEvent? {
        guard let pane = validPane(obj["pane"] as? String),
              let state = obj["state"] as? String, states.contains(state) else { return nil }
        let agent: String
        if let raw = obj["agent"] {
            guard let a = validAgent(raw as? String) else { return nil }
            agent = a
        } else {
            agent = "claude"
        }
        let text = { (k: String) -> String? in
            guard let v = obj[k] as? String, !v.isEmpty else { return nil }
            return v
        }
        return PaneEvent(pane: pane, agent: agent, state: state, sessionId: text("sessionId"), cwd: text("cwd"), reply: text("reply"))
    }

    /// hook のイベントから、ペインの状態を決める。変えないイベントなら nil。
    /// current: そのペインの今の状態（同じ会話のもの。無ければ nil）。
    /// サブエージェントの中の hook（agent_id 付き）は状態を変えない。バックグラウンドのサブエージェントはターンの外でも動き、
    /// 選択肢が出ている間（attention）に届いても作業中に戻さない。選択肢そのもの（許可の確認・確認の知らせ）だけは
    /// サブエージェントのものでも attention にする（答えるまでターミナルが止まる）。
    static func state(event: String, hook: [String: Any], current: String? = nil) -> String? {
        let fromSubagent = (hook["agent_id"] as? String).map { !$0.isEmpty } ?? false
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
            return fromSubagent ? nil : "working"
        case "MessageDisplay":
            // ターンの途中でだけ「作業中」を続ける。終わった後にも届く（離席中のまとめ（recap）の表示など）が、
            // その後に Stop は来ないので、ここで作業中に戻すと終わっても作業中のまま残る。
            guard !fromSubagent else { return nil }
            return current == "working" || current == "attention" ? "working" : nil
        case "PermissionRequest":
            return "attention"
        case "Notification":
            // 許可・確認の知らせは PermissionRequest と同じ扱い。入力待ち（idle_prompt）などでは変えない。
            guard let type = hook["notification_type"] as? String else { return nil }
            return attentionNotifications.contains(type) ? "attention" : nil
        case "Stop":
            // Esc で中断した（ClaudeTerminalRegistry の見張りが送る）。見ていたはずなので「終わった」にしない。
            if hook["buddy_interrupted"] as? Bool == true { return "idle" }
            // main のターンが終わった。バックグラウンドの作業が残っていても done にする（返事を読み上げ、話しかけられるように。
            // 残っている作業は backgroundAgents / backgroundShells で別に知らせる）。
            return "done"
        case "StopFailure":
            return "error"
        default:
            // SubagentStart / SubagentStop（サブエージェントの始まり・終わり）などでは変えない。
            return nil
        }
    }

    /// reply は state が done のときだけ使う（ほかの状態では前の返事を消す）。
    /// turn は done になったときに 1 つ増やす。done が続いても、前の done の後に main のスレッドの動き（作業中・本文）が
    /// あれば数える（UserPromptSubmit の来ないターン）。動きの無い done の繰り返しは数えない。
    /// background: 動いているバックグラウンドのサブエージェントとコマンドの数（nil なら変えない）。
    func set(pane: String, state: String, sessionId: String?, cwd: String?, agent: String = "claude", reply: String? = nil,
             background: (agents: Int, shells: Int)? = nil, backgroundOnly: Int? = nil) {
        lock.lock()
        let changes = setLocked(pane: pane, state: state, sessionId: sessionId, cwd: cwd, agent: agent, reply: reply,
                                background: background, backgroundOnly: backgroundOnly)
        // 通知はロックの中で呼ぶ（別のスレッドの変化と順が入れ替わらないように）。受け側はここへ戻ってこない。
        for c in changes { onBackgroundChanged?(c.key, c.count) }
        lock.unlock()
    }

    private func setLocked(pane: String, state: String, sessionId: String?, cwd: String?, agent: String, reply: String?,
                           background: (agents: Int, shells: Int)?, backgroundOnly: Int?) -> [(key: String, count: Int)] {
        var e = entries[pane] ?? Entry(pane: pane, state: "idle", sessionId: nil, cwd: nil, turn: turnFloor[pane] ?? 0,
                                       updatedAt: Date())
        let finished = state == "done" && (e.state != "done" || active.contains(pane))
        if state == "working" {
            active.insert(pane)
        } else if state != "attention" {
            active.remove(pane)
        }
        let counts = background ?? (agents: e.backgroundAgents, shells: e.backgroundShells)
        let only = backgroundOnly ?? e.backgroundOnlyAgents
        let countsChanged = counts.agents != e.backgroundAgents || counts.shells != e.backgroundShells
            || only != e.backgroundOnlyAgents
        // 同じ状態の繰り返し（ツールごとの working、動きの無い done の重複）は知らせない。
        let same = e.state == state && e.sessionId == sessionId && e.agent == agent && !finished
        guard !same || countsChanged else { return [] }
        if !same {
            if finished { e.turn += 1 }
            e.state = state
            e.sessionId = sessionId
            e.agent = agent
            e.reply = state == "done" ? reply.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.replyLimit)) } : nil
            if let cwd { e.cwd = cwd }
            e.updatedAt = Date()
        }
        e.backgroundAgents = counts.agents
        e.backgroundShells = counts.shells
        e.backgroundOnlyAgents = only
        entries[pane] = e
        turnFloor.removeValue(forKey: pane)
        version += 1
        return reportLocked(e)
    }

    /// 状態は変えずに書く（同じ会話のペインだけ）。activity: main のスレッドの動き（本文だけのターンも、次の Stop の done を
    /// 1 回に数える）。background: 動いているバックグラウンドの作業の数（変わったときだけ知らせる）。
    func note(pane: String, sessionId: String?, activity: Bool = false, background: (agents: Int, shells: Int)? = nil,
              backgroundOnly: Int? = nil) {
        lock.lock()
        let changes = noteLocked(pane: pane, sessionId: sessionId, activity: activity, background: background,
                                 backgroundOnly: backgroundOnly)
        // 通知はロックの中で呼ぶ（別のスレッドの変化と順が入れ替わらないように）。受け側はここへ戻ってこない。
        for c in changes { onBackgroundChanged?(c.key, c.count) }
        lock.unlock()
    }

    private func noteLocked(pane: String, sessionId: String?, activity: Bool, background: (agents: Int, shells: Int)?,
                            backgroundOnly: Int?) -> [(key: String, count: Int)] {
        guard var e = entries[pane], e.sessionId == sessionId else { return [] }
        if activity { active.insert(pane) }
        guard let background else { return [] }
        let only = backgroundOnly ?? e.backgroundOnlyAgents
        guard background.agents != e.backgroundAgents || background.shells != e.backgroundShells
                || only != e.backgroundOnlyAgents else { return [] }
        e.backgroundAgents = background.agents
        e.backgroundShells = background.shells
        e.backgroundOnlyAgents = only
        entries[pane] = e
        version += 1
        return reportLocked(e)
    }

    /// Live Activity に渡す数（key, 数）。前に渡した値と同じなら空。key が替わったとき（sessionId が分かった）は前の key を 0 にする。
    private func reportLocked(_ e: Entry) -> [(key: String, count: Int)] {
        let key = e.sessionId ?? "pane:" + e.pane
        let count = e.state == "working" || e.state == "attention" ? e.backgroundOnlyAgents : e.backgroundAgents
        let previous = reported[e.pane]
        reported[e.pane] = (key, count)
        if previous == nil, count == 0 { return [] }
        guard previous?.key != key || previous?.count != count else { return [] }
        var out: [(key: String, count: Int)] = []
        if let previous, previous.key != key, previous.count != 0 { out.append((previous.key, 0)) }
        out.append((key, count))
        return out
    }

    /// そのペインの今の状態。別の会話のものなら nil。
    func state(pane: String, sessionId: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[pane], e.sessionId == sessionId else { return nil }
        return e.state
    }

    /// claude が終わった（SessionEnd / プロセスが消えた）。そのペインはただのシェルに戻る。turn は残し、
    /// 同じペインで次に動く会話はその続きから数える。
    func remove(pane: String, sessionId: String) {
        lock.lock()
        let changes = removeLocked(pane: pane, sessionId: sessionId)
        // 通知はロックの中で呼ぶ（別のスレッドの変化と順が入れ替わらないように）。受け側はここへ戻ってこない。
        for c in changes { onBackgroundChanged?(c.key, c.count) }
        lock.unlock()
    }

    private func removeLocked(pane: String, sessionId: String) -> [(key: String, count: Int)] {
        guard let e = entries[pane], e.sessionId == sessionId else { return [] }
        entries.removeValue(forKey: pane)
        active.remove(pane)
        turnFloor[pane] = e.turn
        if turnFloor.count > Self.turnFloorLimit, let old = turnFloor.keys.first(where: { $0 != pane }) {
            turnFloor.removeValue(forKey: old)
        }
        version += 1
        guard let previous = reported.removeValue(forKey: pane), previous.count != 0 else { return [] }
        return [(previous.key, 0)]
    }

    /// version が since から変わるまで待つ（最長 timeout 秒）。変わらなければ今の一覧をそのまま返す。
    func poll(since: Int, timeout: TimeInterval) async -> (version: Int, entries: [Entry]) {
        let deadline = Date().addingTimeInterval(timeout)
        while current().version == since && Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return current()
    }

    private func current() -> (version: Int, entries: [Entry]) {
        lock.lock(); defer { lock.unlock() }
        return (version, Array(entries.values))
    }
}
