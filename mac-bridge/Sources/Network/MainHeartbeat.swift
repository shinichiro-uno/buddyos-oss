import Foundation

// メインの定期チェック（heartbeat）。docs/MAIN_HEARTBEAT_2026-10-20.md
//
// mainagent（~/.buddyos/main で開いた会話）が決まった間隔で自分から様子を見に行き、伝えることがあるときだけ
// スマホに知らせる。cron（BridgeCronScheduler）とは別のタイマーで、専用の会話を 1 つ使い回す（resume で開く）。
// その会話には無人（unattended）でも mainagent の道具（buddyos MCP）を渡す（SessionOptions.heartbeat の印）。

// MARK: - 設定

/// `~/.buddyos/heartbeat.json`。画面から変える。無ければ既定。
struct HeartbeatSettings: Codable, Equatable, Sendable {
    struct QuietHours: Codable, Equatable, Sendable {
        var enabled: Bool = true
        var start: String = "22:00"
        var end: String = "08:00"
    }

    var enabled: Bool = true
    var intervalMinutes: Int = 180
    var quietHours = QuietHours()
    var agentId: String = "claude"
    /// 頼む文の本文（空なら既定の文）。頭の「[定期チェック …]」と HEARTBEAT_OK の決まりは Bridge が足す。
    var prompt: String = ""

    static let defaults = HeartbeatSettings()
    static let maxPromptChars = 2000
    static let minIntervalMinutes = 30
    static let maxIntervalMinutes = 1440

    static func clampInterval(_ minutes: Int) -> Int {
        min(maxIntervalMinutes, max(minIntervalMinutes, minutes))
    }

    /// 設定の JSON（一部だけでもよい）を今の値に重ねる。無い項目・形の違う値・読めない時刻は今の値のまま。
    func merged(with patch: [String: Any]) -> HeartbeatSettings {
        var out = self
        if let b = Self.jsonBool(patch["enabled"]) { out.enabled = b }
        if let n = Self.jsonInt(patch["intervalMinutes"]) { out.intervalMinutes = Self.clampInterval(n) }
        if let q = patch["quietHours"] as? [String: Any] {
            if let b = Self.jsonBool(q["enabled"]) { out.quietHours.enabled = b }
            if let s = (q["start"] as? String).flatMap(Self.normalizedClock) { out.quietHours.start = s }
            if let e = (q["end"] as? String).flatMap(Self.normalizedClock) { out.quietHours.end = e }
        }
        if let a = (patch["agentId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            out.agentId = a
        }
        if let p = patch["prompt"] as? String {
            out.prompt = String(p.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxPromptChars))
        }
        out.intervalMinutes = Self.clampInterval(out.intervalMinutes)
        return out
    }

    /// ファイルの中身から読む（壊れていれば既定。足りない項目も既定）。
    static func load(from data: Data?) -> HeartbeatSettings {
        guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return defaults }
        return defaults.merged(with: obj)
    }

    /// "HH:mm" → 0 時からの分。読めなければ nil。
    static func clockMinutes(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    static func normalizedClock(_ s: String) -> String? {
        clockMinutes(s).map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    }

    /// JSONSerialization の数（NSNumber）は Bool にも化けるので、本物の true / false だけを受ける。
    private static func jsonBool(_ v: Any?) -> Bool? {
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func jsonInt(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite else { return nil }
        return Int(d.rounded())
    }
}

// MARK: - 状態

/// `~/.buddyos/heartbeat-state.json`。Bridge が持つ。
struct HeartbeatState: Codable, Equatable, Sendable {
    var sessionId: String?
    var agentId: String?
    var lastRunAt: Date?
    /// ok | reported | skipped | error | running
    var lastResult: String?
    var lastMessage: String?
    var nextRunAt: Date?
}

// MARK: - 決まり（テストできる純粋な部分）

enum HeartbeatRules {
    /// Bridge が起きてから初回までの間（lastRunAt が無いとき）。
    static let firstRunDelay: TimeInterval = 10 * 60
    static let okToken = "HEARTBEAT_OK"
    static let okMaxChars = 40
    static let pushMaxLines = 3
    static let pushMaxChars = 200

    /// 静かな時間か（start > end は日をまたぐ。start == end は静かな時間なし）。
    static func inQuietHours(_ q: HeartbeatSettings.QuietHours, at date: Date, calendar: Calendar = .current) -> Bool {
        guard q.enabled, let s = HeartbeatSettings.clockMinutes(q.start), let e = HeartbeatSettings.clockMinutes(q.end),
              s != e else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return s < e ? (m >= s && m < e) : (m >= s || m < e)
    }

    /// 間隔の上で次に回せる時刻（静かな時間は見ない）。
    static func baseDue(settings: HeartbeatSettings, lastRunAt: Date?, startedAt: Date) -> Date {
        if let last = lastRunAt {
            return last.addingTimeInterval(TimeInterval(HeartbeatSettings.clampInterval(settings.intervalMinutes) * 60))
        }
        return startedAt.addingTimeInterval(firstRunDelay)
    }

    /// 60 秒ごとの見回りで、いま回すか（動いている最中かどうかは呼び元が見る）。
    static func isDue(settings: HeartbeatSettings, lastRunAt: Date?, startedAt: Date, now: Date,
                      calendar: Calendar = .current) -> Bool {
        guard settings.enabled else { return false }
        guard now >= baseDue(settings: settings, lastRunAt: lastRunAt, startedAt: startedAt) else { return false }
        return !inQuietHours(settings.quietHours, at: now, calendar: calendar)
    }

    /// 次に回る見込みの時刻（画面の表示用）。止めていれば nil。静かな時間に当たれば、その終わりにずらす。
    static func nextRunAt(settings: HeartbeatSettings, lastRunAt: Date?, startedAt: Date, now: Date,
                          calendar: Calendar = .current) -> Date? {
        guard settings.enabled else { return nil }
        var t = max(baseDue(settings: settings, lastRunAt: lastRunAt, startedAt: startedAt), now)
        if inQuietHours(settings.quietHours, at: t, calendar: calendar),
           let e = HeartbeatSettings.clockMinutes(settings.quietHours.end),
           var end = calendar.date(bySettingHour: e / 60, minute: e % 60, second: 0, of: t) {
            if end <= t, let next = calendar.date(byAdding: .day, value: 1, to: end) { end = next }
            t = end
        }
        return t
    }

    /// 伝えることが無いという返事か（前後の空白を除いて HEARTBEAT_OK で始まり、40 文字以下）。
    static func isOk(_ reply: String) -> Bool {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix(okToken) && t.count <= okMaxChars
    }

    /// 通知の本文。返事の頭 3 行（空行は数えない）・200 文字まで。
    static func pushBody(_ reply: String) -> String {
        let lines = reply.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let head = lines.prefix(pushMaxLines).joined(separator: "\n")
        guard head.count > pushMaxChars else { return head }
        return String(head.prefix(pushMaxChars - 1)) + "…"
    }

    /// 手元の時刻 `YYYY-MM-DD HH:mm`。
    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 頼む文の本文の既定（設定の prompt が空のとき）。
    static let defaultBody = """
    ~/.buddyos/main/HEARTBEAT.md の項目に沿って、途中で止まっていることや忘れていそうなことが無いかを確かめてください。見るだけにして、作業は頼まないでください（気づいたことを知らせるのが役目です）。
    覚えておくとよいことは save_note で残してください。前に残したことは ~/.buddyos/main/NOTES.md にあります。
    """

    /// 送る文。本文は設定で変えられる。頭（mainagent が定期チェックと見分ける印）と終わり（HEARTBEAT_OK の決まり）は固定。
    static func prompt(at date: Date, body custom: String = "", timeZone: TimeZone = .current) -> String {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        [定期チェック \(stamp(date, timeZone: timeZone))]
        \(trimmed.isEmpty ? defaultBody : trimmed)
        伝えることが無ければ、ほかに何も書かずに HEARTBEAT_OK とだけ返してください。伝えることがあれば、スマホの通知で読める短さ（3 行まで）で書いてください。
        """
    }

    /// heartbeat_status の content。
    static func statusJSON(settings: HeartbeatSettings, state: HeartbeatState) -> String {
        struct Status: Encodable {
            let settings: HeartbeatSettings
            let state: HeartbeatState
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(Status(settings: settings, state: state)) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - メインのメモ（save_note）

enum MainNotes {
    static let maxChars = 500
    private static let lock = NSLock()

    /// NOTES.md に足す 1 行。改行は空白に、500 文字まで。空なら nil。
    static func line(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return "- \(HeartbeatRules.stamp(now, timeZone: timeZone)) \(String(flat.prefix(maxChars)))"
    }

    /// NOTES.md の末尾に 1 行足す（無ければ初期の中身で作る）。足した行を返す。
    @discardableResult
    static func append(_ text: String, now: Date = Date(), url: URL = MainAgentWorkspace.notesURL) throws -> String {
        guard let line = line(text, now: now) else { throw Orchestrator.ToolError("text が空") }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        var body: String
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) else {
                throw Orchestrator.ToolError("NOTES.md を読めない（文字コードが違う等）")
            }
            body = s
        } else {
            body = MainAgentWorkspace.notesInitial
        }
        if !body.isEmpty, !body.hasSuffix("\n") { body += "\n" }
        body += line + "\n"
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url, options: .atomic)
        } catch {
            throw Orchestrator.ToolError("NOTES.md に書けない: \(error.localizedDescription)")
        }
        return line
    }
}

// MARK: - タイマーと実行

actor MainHeartbeat {
    static let shared = MainHeartbeat()

    static let tickSeconds: TimeInterval = 60
    /// 1 回の上限。超えたら止めて error。
    static let runTimeout: TimeInterval = 10 * 60
    /// error だけで終わり done が来ないターンを打ち切るまでの猶予。
    static let errorSettleSeconds: TimeInterval = 10
    /// バックグラウンドの作業の結論を待っている間に作業が全部終わってから、知らせのターンを待つ猶予（cron の
    /// backgroundSettleGrace と同じ 120 秒）。テストでは短くする。
    nonisolated(unsafe) static var backgroundSettleSeconds: TimeInterval = 120
    static let pushTitle = "メイン（定期チェック）"
    /// スマホのセッション一覧に出す名前。
    static let sessionTitle = "定期チェック"

    static var defaultSettingsURL: URL { BuddyPaths.root.appendingPathComponent("heartbeat.json") }
    static var defaultStateURL: URL { BuddyPaths.root.appendingPathComponent("heartbeat-state.json") }

    private let settingsURL: URL
    private let stateURL: URL
    private var listeners: [UUID: @Sendable (SessionEvent) -> Void] = [:]
    private var started = false
    private var startedAt = Date()
    private var running = false
    private var state = HeartbeatState()
    private var tickTask: Task<Void, Never>?

    init(settingsURL: URL = MainHeartbeat.defaultSettingsURL, stateURL: URL = MainHeartbeat.defaultStateURL) {
        self.settingsURL = settingsURL
        self.stateURL = stateURL
        self.state = Self.loadState(at: stateURL)
    }

    // MARK: 口

    func register(send: @escaping @Sendable (SessionEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = send
        return id
    }

    func unregister(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        startedAt = Date()
        // 前の Bridge が回している途中で止まった。
        if state.lastResult == "running" {
            state.lastResult = "error"
            state.lastMessage = "Bridge が止まったので、前の回は途中で終わった"
        }
        saveState()
        let interval = Self.tickSeconds
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.tick()
            }
        }
        WebSocketServer.wslog("[heartbeat] started enabled=\(loadSettings().enabled)")
    }

    func statusEvent() -> SessionEvent {
        let settings = loadSettings()
        var s = state
        s.nextRunAt = HeartbeatRules.nextRunAt(settings: settings, lastRunAt: state.lastRunAt,
                                               startedAt: startedAt, now: Date())
        return .heartbeatStatus(HeartbeatRules.statusJSON(settings: settings, state: s))
    }

    /// heartbeat_set。足りない項目は今の値のまま。mainagent を扱えない agentId は受けない（今の値のまま）。
    func updateSettings(json: String) async -> SessionEvent {
        guard let data = json.data(using: .utf8),
              let patch = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return statusEvent()
        }
        let current = loadSettings()
        var next = current.merged(with: patch)
        if next.agentId != current.agentId, !(await Self.canRun(agentId: next.agentId)) {
            WebSocketServer.wslog("[heartbeat] set: agent \(next.agentId) cannot be the main agent — kept \(current.agentId)")
            next.agentId = current.agentId
        }
        saveSettings(next)
        saveState()
        broadcastStatus()
        return statusEvent()
    }

    /// heartbeat_run_now。間隔と静かな時間を無視してすぐ回す。動いている最中なら何もしない。
    func runNow() async -> SessionEvent {
        guard !running else { return statusEvent() }
        if await sessionBusy() { return statusEvent() }
        guard !running else { return statusEvent() }
        begin(settings: loadSettings())
        return statusEvent()
    }

    // MARK: 見回り

    private func tick() async {
        guard !running else { return }
        let settings = loadSettings()
        guard HeartbeatRules.isDue(settings: settings, lastRunAt: state.lastRunAt, startedAt: startedAt, now: Date()) else {
            return
        }
        if await sessionBusy() {
            // 前の回が終わっていない・承認待ち。lastRunAt は進めない（次の 60 秒でまた見る）。
            if state.lastResult != "skipped" {
                state.lastResult = "skipped"
                state.lastMessage = "定期チェックの会話がまだ動いている（承認待ちを含む）"
                saveState()
                broadcastStatus()
            }
            return
        }
        guard !running else { return }
        begin(settings: settings)
    }

    /// 定期チェックの会話がまだ動いているか（生成中・承認待ち・予約あり）。
    private func sessionBusy() async -> Bool {
        if running { return true }
        guard let sid = state.sessionId, let agent = state.agentId else { return false }
        return await SessionHub.shared.snapshot().contains {
            $0.agentId == agent && $0.sessionId == sid && ($0.generating || $0.awaiting || $0.queued > 0)
        }
    }

    private func begin(settings: HeartbeatSettings) {
        running = true
        let now = Date()
        state.lastRunAt = now
        state.lastResult = "running"
        state.lastMessage = nil
        saveState()
        broadcastStatus()
        let resumeId = state.agentId == settings.agentId ? state.sessionId : nil
        WebSocketServer.wslog("[heartbeat] run agent=\(settings.agentId) resume=\(resumeId?.prefix(8) ?? "new")")
        Task { await self.execute(agentId: settings.agentId, resumeId: resumeId, prompt: HeartbeatRules.prompt(at: now, body: settings.prompt)) }
    }

    // release ビルドの最適化（CopyPropagation）で Swift 6.2 のコンパイラが落ちるため、この関数だけ最適化を外す。
    // 3 時間に 1 回動くだけなので速さには効かない。コンパイラが直ったら外してよい。
    @_optimize(none)
    private func execute(agentId: String, resumeId: String?, prompt: String) async {
        guard let adapter = await AgentRegistry.shared.adapter(for: agentId),
              AgentRegistry.capabilities(of: adapter).orchestrate,
              AgentRegistry.capabilities(of: adapter).chat else {
            finish(agentId: agentId, sessionId: resumeId, result: "error",
                   message: "\(agentId) は定期チェックに使えない（mainagent を扱えるエージェントを選ぶ）", reply: nil)
            return
        }
        var run = await Self.perform(adapter: adapter, agentId: agentId, sessionId: resumeId, prompt: prompt)
        // 続きで開けなかった（会話が消えた等）。新しく作って覚え直す。
        if resumeId != nil, run.errorText != nil, !run.gotOutput, !run.timedOut {
            WebSocketServer.wslog("[heartbeat] resume failed (\(run.errorText ?? "")) → new session")
            run = await Self.perform(adapter: adapter, agentId: agentId, sessionId: nil, prompt: prompt)
        }
        if resumeId != run.sessionId, !run.sessionId.isEmpty, !run.sessionId.hasPrefix("pending") {
            let title = await SessionOverrideStore.shared.customTitle(agentId: agentId, sessionId: run.sessionId)
            if title == nil {
                await SessionOverrideStore.shared.setTitle(agentId: agentId, sessionId: run.sessionId, title: Self.sessionTitle)
            }
        }
        let reply = run.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if run.timedOut {
            finish(agentId: agentId, sessionId: run.sessionId, result: "error",
                   message: "10 分で終わらなかったので止めた", reply: nil)
        } else if let err = run.errorText, reply.isEmpty || !run.done {
            finish(agentId: agentId, sessionId: run.sessionId, result: "error", message: err, reply: nil)
        } else if reply.isEmpty {
            finish(agentId: agentId, sessionId: run.sessionId, result: "error",
                   message: run.errorText ?? "返事が無かった", reply: nil)
        } else if HeartbeatRules.isOk(reply) {
            finish(agentId: agentId, sessionId: run.sessionId, result: "ok", message: reply, reply: nil)
        } else {
            finish(agentId: agentId, sessionId: run.sessionId, result: "reported", message: reply, reply: reply)
        }
    }

    private func finish(agentId: String, sessionId: String?, result: String, message: String, reply: String?) {
        running = false
        state.agentId = agentId
        if let sessionId, !sessionId.isEmpty { state.sessionId = sessionId }
        state.lastResult = result
        state.lastMessage = String(message.prefix(1000))
        saveState()
        broadcastStatus()
        WebSocketServer.wslog("[heartbeat] done result=\(result) chars=\(message.count)")
        guard let reply, let sid = state.sessionId else { return }
        let body = HeartbeatRules.pushBody(reply)
        Task {
            await PushService.shared.broadcast(
                title: Self.pushTitle,
                body: body,
                payload: [
                    "kind": "chat",
                    "agentId": agentId,
                    "sessionId": sid,
                    // タップでその Mac のこの会話を開けるように載せる（SessionHub の chat push と同じ形）。
                    "bridgeId": KeyStore.loadOrCreateBridgeId()
                ]
            )
        }
    }

    static func canRun(agentId: String) async -> Bool {
        guard let adapter = await AgentRegistry.shared.adapter(for: agentId) else { return false }
        let caps = AgentRegistry.capabilities(of: adapter)
        return caps.orchestrate && caps.chat
    }

    // MARK: 1 回分（hub を通して会話を開き、送って、done まで集める）

    struct RunResult: Sendable {
        var sessionId: String
        var reply = ""
        var errorText: String?
        var timedOut = false
        var gotOutput = false
        var done = false
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func perform(adapter: AgentAdapter, agentId: String, sessionId: String?, prompt: String) async -> RunResult {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let subId = UUID()
        let cwd = MainAgentWorkspace.defaultURL.path
        // hub を通して開く（スマホからも同じ会話が見える）。無人だが mainagent の道具は渡す（heartbeat の印）。
        let session = await SessionHub.shared.acquire(
            agentId: agentId, sessionId: sessionId, cwd: cwd, adapter: adapter,
            subscriberId: subId, send: { continuation.yield($0) },
            options: SessionOptions(unattended: true, heartbeat: true))
        var result = RunResult(sessionId: sessionId ?? session.sessionId)
        let cmid = "heartbeat-\(UUID().uuidString)"
        switch await SessionHub.shared.submitExternal(
            agentId: agentId, sessionId: session.sessionId, clientMessageId: cmid, content: prompt) {
        case .sendNow:
            Task { await WebSocketServer.dispatch(session, content: prompt, skills: [], attachments: [], voice: nil) }
        case .queued:
            break
        case .missing:
            continuation.finish()
            await SessionHub.shared.release(subscriberId: subId)
            result.errorText = "会話を開けなかった"
            return result
        }

        let timedOut = Flag()
        let timeout = runTimeout
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            timedOut.set()
            await session.interrupt()
            // interrupt が効かず done が来ないときも、猶予の後に打ち切る。
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            continuation.finish()
        }
        var errorCloser: Task<Void, Never>?

        var mine = false
        var bubble = ""
        var bubbleId: String?
        var bubbleClosed = false
        // 送った指示のターンが done になった後も、バックグラウンドのサブエージェントか workflow が動いていれば、その結論を運ぶ
        // 知らせのターンの done まで集める（cron の TurnCollector と同じ）。返事はそのターンの最後の吹き出し。
        var cards = WorkflowCardMirror()
        var awaitingBackground = false
        var wakeStarted = false
        // 作業が無くなってから backgroundSettleSeconds の間に知らせのターンが始まらなければ（子が終わっても親が起きない CLI）、
        // 今の返事で打ち切る。
        var settle: Task<Void, Never>?
        func rearmSettle() {
            settle?.cancel()
            settle = nil
            guard awaitingBackground, !wakeStarted, !cards.counts.agentsOrWorkflows else { return }
            let grace = backgroundSettleSeconds
            settle = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                continuation.finish()
            }
        }
        loop: for await event in stream {
            if event.type == .sessionStarted, let sid = event.sessionId, !sid.isEmpty {
                result.sessionId = sid
                continue
            }
            if event.type == .queueDispatched, (event.metadata?["clientMessageId"] ?? event.messageId) == cmid {
                mine = true
                continue
            }
            // バックグラウンドの作業の行は、自分の送信の前（購読直後の全行）から重ねる。
            if event.type == .workflowProgress {
                cards.apply(event.content)
                rearmSettle()
                continue
            }
            // 自分の送信が始まるまで（購読直後のスナップショット・前のターンの残り）は見ない。
            guard mine else { continue }
            switch event.type {
            case .activity, .toolStart:
                if awaitingBackground {
                    wakeStarted = true
                    rearmSettle()
                }
            case .assistantDelta:
                if awaitingBackground, !wakeStarted {
                    wakeStarted = true
                    rearmSettle()
                }
                if bubbleClosed || event.messageId != bubbleId {
                    bubble = ""
                    bubbleClosed = false
                    bubbleId = event.messageId
                }
                bubble += event.content ?? ""
                result.gotOutput = true
            case .assistantTurnEnd:
                bubbleClosed = true
            case .error:
                result.errorText = event.content ?? "error"
                // error だけで done が来ない経路（hub は購読者に done を配らない）を打ち切る。
                if errorCloser == nil {
                    let grace = errorSettleSeconds
                    errorCloser = Task {
                        try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        continuation.finish()
                    }
                }
            case .actionRequest:
                await handleAction(event, session: session, agentId: agentId, sessionId: result.sessionId)
            case .done:
                // 結果待ち（送った指示のターンは終わり、バックグラウンドの作業の結論を待っている）の間に閉じたターン
                // （知らせのターン）。本文があればそれが返事（無い・silent なら起動の返事のまま）。作業がまだ残っていれば待ち続ける。
                if awaitingBackground {
                    wakeStarted = false
                    if cards.counts.agentsOrWorkflows {
                        rearmSettle()
                        continue loop
                    }
                    break loop
                }
                // 知らせのターン（バックグラウンドの作業が終わり、エージェントが自分から始めたターン。metadata.origin =
                // "task-notification"）の done は、送った指示の返事ではない（送った指示は待ち行列に残っていて、その done は
                // 後から来る）。そのターンの本文とエラーを捨てて待ち続ける。
                if event.metadata?["origin"] == "task-notification" {
                    bubble = ""
                    bubbleId = nil
                    bubbleClosed = false
                    result.gotOutput = false
                    result.errorText = nil
                    errorCloser?.cancel()
                    errorCloser = nil
                    continue loop
                }
                result.done = true
                if event.metadata?["errored"] == "true", result.errorText == nil {
                    result.errorText = "返事の無いまま終わった"
                }
                // バックグラウンドのサブエージェントか workflow が動いている（Claude の既定のバックグラウンドの
                // サブエージェントなど）。起動の返事で打ち切らず、知らせのターンの結論を待つ（上限は runTimeout）。
                // 待つ間は購読も外さない（hub は見ている人がいるとみなし、自分の push を出さない。push はこの定期チェックが出す）。
                if cards.counts.agentsOrWorkflows {
                    awaitingBackground = true
                    WebSocketServer.wslog("[heartbeat] waiting for background work")
                    continue loop
                }
                break loop
            default:
                break
            }
        }
        deadline.cancel()
        errorCloser?.cancel()
        settle?.cancel()
        continuation.finish()
        await SessionHub.shared.release(subscriberId: subId)
        result.reply = bubble
        result.timedOut = timedOut.isSet
        return result
    }

    /// 定期チェックの会話に届いた承認。
    /// - mainagent の道具の承認（start_session / send_message。requestId が mainagent-）は利用者に任せる。
    ///   この会話を購読しているのが自分だけなら、hub は「見ている人がいる」とみなして通知しないので、ここで承認の通知を送る。
    /// - それ以外（エージェント自身の承認・質問）は答える人がいないので、cron と同じくその場で断る。
    private static func handleAction(_ event: SessionEvent, session: AgentSession, agentId: String, sessionId: String) async {
        let meta = event.metadata ?? [:]
        let requestId = meta["requestId"] ?? event.messageId ?? ""
        guard !requestId.isEmpty else { return }
        if requestId.hasPrefix("mainagent-") {
            let watchers = await SessionHub.shared.snapshot()
                .first { $0.agentId == agentId && $0.sessionId == sessionId }?.subscriberCount ?? 0
            guard watchers <= 1 else { return }
            await PushService.shared.broadcast(
                title: pushTitle,
                body: meta["title"] ?? event.content ?? "承認が必要です",
                payload: [
                    "kind": "approval_request",
                    "agentId": agentId,
                    "sessionId": sessionId,
                    "requestId": requestId,
                    "bridgeId": KeyStore.loadOrCreateBridgeId()
                ]
            )
            return
        }
        await session.respondToAction(requestId: requestId,
                                      decision: BridgeCronScheduler.unattendedDecision(metadata: meta), answers: [:])
    }

    // MARK: 保存

    private func loadSettings() -> HeartbeatSettings {
        HeartbeatSettings.load(from: try? Data(contentsOf: settingsURL))
    }

    private func saveSettings(_ settings: HeartbeatSettings) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: settingsURL, options: .atomic)
    }

    static func loadState(at url: URL) -> HeartbeatState {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let s = try? dec.decode(HeartbeatState.self, from: data) else {
            return HeartbeatState()
        }
        return s
    }

    private func saveState() {
        state.nextRunAt = HeartbeatRules.nextRunAt(settings: loadSettings(), lastRunAt: state.lastRunAt,
                                                   startedAt: startedAt, now: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
        // 返事の頭が入るので、本人だけが読めるようにする。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }

    private func broadcastStatus() {
        let event = statusEvent()
        for send in listeners.values { send(event) }
    }
}
