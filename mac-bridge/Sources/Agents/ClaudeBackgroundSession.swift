import Foundation

// ---------------------------------------------------------------------------
// claude --bg のワーカーの会話（BACKGROUND_CONTROL §7.8）。見るのは transcript、送るのは受け箱。
//   worker: ワーカーが生きている。生の status でターンを開け閉めし、受け箱で送る。
//   elsewhere: ほかのプロセスが同じ sessionId を握っている。見るだけで、送信は断る。
// ---------------------------------------------------------------------------

/// ClaudeBackgroundJobs のうち、この会話が使う口。
protocol BgSessionHost: Sendable {
    var homeDir: URL { get }
    func entryFor(sessionId: String) async -> BgEntry?
    func watchEntry(sessionId: String, _ listener: @escaping @Sendable (BgEntry?) -> Void) async -> UUID
    func unwatchEntry(_ id: UUID) async
}

extension ClaudeBackgroundJobs: BgSessionHost {}

/// loadHistory が会話を読み終えた位置。ClaudeBackgroundSession が同じ行を履歴と live の両方に出さないために使う。
final class BgHistoryFeed: @unchecked Sendable {
    static let shared = BgHistoryFeed()

    struct Read: Sendable, Equatable {
        var file: String?
        var end: UInt64
        /// 読んだ時刻。古い読み取りは「いま開き直した会話の履歴」の読み終わりとは見ない。
        var at: Date = Date()
    }

    private let lock = NSLock()
    private var reads: [String: Read] = [:]
    private var listeners: [UUID: (sessionId: String, handler: @Sendable (Read) -> Void)] = [:]

    func note(sessionId: String, file: String?, end: UInt64) {
        let read = Read(file: file, end: end)
        lock.lock()
        reads[sessionId] = read
        let targets = listeners.values.filter { $0.sessionId == sessionId }
        lock.unlock()
        for t in targets { t.handler(read) }
    }

    func lastRead(sessionId: String) -> Read? {
        lock.lock(); defer { lock.unlock() }
        return reads[sessionId]
    }

    func onRead(sessionId: String, _ handler: @escaping @Sendable (Read) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = (sessionId, handler); lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock(); listeners.removeValue(forKey: id); lock.unlock()
    }
}

/// Bridge 自身の `claude -p` の pid。elsewhere の判定で数えない（§7.8 の 3）。
enum BridgeSpawnedClaude {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids = Set<Int32>()

    static func add(_ pid: Int32) { lock.lock(); pids.insert(pid); lock.unlock() }
    static func remove(_ pid: Int32) { lock.lock(); pids.remove(pid); lock.unlock() }
    static var all: Set<Int32> { lock.lock(); defer { lock.unlock() }; return pids }
}

actor ClaudeBackgroundSession: AgentSession {
    enum Mode: Sendable, Equatable { case worker, elsewhere }

    /// elsewhere: 握っているプロセス。
    struct Holder: Sendable, Equatable {
        var pid: Int32
        var entrypoint: String?
        var status: String?
        var procStart: String?
    }

    struct Timing: Sendable {
        /// ターンが開いている間・送った発話の行方が分からない間の読み取りの間隔。
        var fast: TimeInterval = 1
        var slow: TimeInterval = 5
        /// 最初の読み取りが履歴を読み終えるのを待つ時間。
        var historyWait: TimeInterval = 3
        /// 送った発話が transcript に出るのを待つ時間（status が idle / shell のまま）。
        var ack: TimeInterval = 30
    }

    static let interruptText = "このセッションは PC のバックグラウンドで動いています。返事だけを止めることはできません。止めるときは、会話のメニューの「停止」を使ってください（セッションごと止まります）。"
    private static let sentLimit = 20
    private static let summaryLimit = 200

    nonisolated let sessionId: String
    nonisolated let events: AsyncThrowingStream<SessionEvent, Error>
    nonisolated var supportsMidTurnInjection: Bool { true }
    nonisolated let mode: Mode

    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private let agentId: String
    private let host: any BgSessionHost
    private let home: URL
    private let holder: Holder?
    private let feed: BgHistoryFeed
    private let timing: Timing
    private let now: @Sendable () -> Date
    private let isAlive: @Sendable (Int32, String?) -> Bool
    private let post: @Sendable (String, String) async throws -> Void

    private var sent: [String] = []
    private var toolNames: [String: String] = [:]
    private var turn: Turn?
    private var status: String?
    private var alive = true
    private var unusable = false
    private var closed = false
    private var file: String?
    private var offset: UInt64?
    private var historyEnd: UInt64?
    private var historyWaitUntil: Date?
    private let createdAt: Date
    private var ackSince: Date?
    private var timer: Task<Void, Never>?
    private var watchId: UUID?
    private var entryTask: Task<Void, Never>?
    private var historyListener: UUID?

    private struct Turn {
        var messageId: String
        /// message.id → 吹き出しの messageId。
        var bubbles: [String: String] = [:]
        /// 状態の変化なしに transcript だけで始まった（PC で attach して打った）ターン。
        var implicit: Bool
    }

    init(agentId: String, sessionId: String, mode: Mode, host: any BgSessionHost, holder: Holder? = nil,
         feed: BgHistoryFeed = .shared, timing: Timing = Timing(),
         now: @escaping @Sendable () -> Date = { Date() },
         isAlive: @escaping @Sendable (Int32, String?) -> Bool = { ClaudeAgentsRegistry.isProcessAlive(pid: $0, procStart: $1) },
         post: @escaping @Sendable (String, String) async throws -> Void = { text, socket in
             try await Task.detached { try ClaudeInboxSocket.post(text: text, socketPath: socket) }.value
         }) {
        self.agentId = agentId
        self.sessionId = sessionId
        self.mode = mode
        self.host = host
        self.home = host.homeDir
        self.holder = holder
        self.feed = feed
        self.timing = timing
        self.now = now
        self.isAlive = isAlive
        self.post = post
        self.createdAt = now()
        var c: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { c = $0 }
        self.continuation = c
        // SessionHub は sessionStarted で key を確定させる。開くのは既知の id なので即出す。
        c.yield(.sessionStarted(agentId: agentId, sessionId: sessionId))
    }

    // MARK: - 開始・終了

    /// 作ったあとに 1 回呼ぶ（台帳の購読と読み取りの開始）。
    func start() async {
        let entry = await host.entryFor(sessionId: sessionId)
        findTranscript(entry)
        if let file { offset = Self.fileSize(file) }
        if file != nil {
            // 開き直しでも、これから来る loadHistory の読み終わりを受ける（再接続で何度来ても max で合わせる）。
            historyListener = feed.onRead(sessionId: sessionId) { [weak self] read in
                Task { await self?.historyRead(read) }
            }
        }
        let last = feed.lastRead(sessionId: sessionId)
        // 前の回の読み終わりは下限にだけ使う。
        if let last { noteHistory(last) }
        // 開いたあとの読み取りでなければ古い（前の回の終わりがいまの大きさと同じでも、そのあと書き進んだ分を履歴と
        // live の両方に出さないよう）。新しい履歴を待つ。
        if file != nil, last.map({ $0.at < createdAt }) ?? true { waitForHistory() }
        if mode == .worker {
            let (stream, cont) = AsyncStream<BgEntry?>.makeStream()
            watchId = await host.watchEntry(sessionId: sessionId) { cont.yield($0) }
            entryTask = Task { [weak self] in
                for await e in stream { await self?.onEntry(e) }
            }
            syncStatus(entry?.workerStatus, alive: entry?.row.live == true, entry: entry)
        } else {
            syncStatus(holder?.status, alive: true, entry: entry)
        }
        arm()
    }

    func close() async {
        closed = true
        timer?.cancel(); timer = nil
        entryTask?.cancel(); entryTask = nil
        if let id = watchId { watchId = nil; await host.unwatchEntry(id) }
        if let id = historyListener { historyListener = nil; feed.remove(id) }
        continuation.finish()
    }

    /// 握っていたプロセスが生きていて、「使えない」印が付いていないか（WebSocketServer.isStillUsable）。
    func isUsable() async -> Bool {
        if unusable || closed { return false }
        if mode == .elsewhere {
            guard let holder, isAlive(holder.pid, holder.procStart) else { return false }
            // 握っていた人が閉じて、ワーカーが起きた。作り直して worker にする。
            return await host.entryFor(sessionId: sessionId)?.row.live != true
        }
        return await host.entryFor(sessionId: sessionId)?.row.live == true
    }

    // MARK: - transcript

    /// 履歴を読み終えるか 3 秒たつまで最初の読み取りを待つ（同じ行を履歴と live の両方に出さない）。
    private func waitForHistory() {
        historyWaitUntil = createdAt.addingTimeInterval(timing.historyWait)
    }

    private var isWaitingForHistory: Bool {
        guard let until = historyWaitUntil else { return false }
        return now() < until
    }

    private func historyRead(_ read: BgHistoryFeed.Read) {
        noteHistory(read)
        historyWaitUntil = nil
        arm(0)
    }

    private func noteHistory(_ read: BgHistoryFeed.Read) {
        if let f = read.file, let mine = file, (f as NSString).standardizingPath != (mine as NSString).standardizingPath { return }
        historyEnd = read.end
        if let o = offset { offset = max(o, read.end) }
    }

    private func findTranscript(_ entry: BgEntry?) {
        if file != nil { return }
        var found = ClaudeTerminalRegistry.validTranscriptPath(entry?.linkScanPath, sessionId: sessionId, home: home.path)
        if found == nil {
            let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
            for d in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                let candidate = root.appendingPathComponent(d).appendingPathComponent("\(sessionId).jsonl").path
                if let ok = ClaudeTerminalRegistry.validTranscriptPath(candidate, sessionId: sessionId, home: home.path),
                   FileManager.default.fileExists(atPath: ok) {
                    found = ok
                    break
                }
            }
        }
        guard let found else { return }
        file = found
        if offset == nil { offset = historyEnd ?? 0 }
    }

    private static func fileSize(_ path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - 見張り

    private func arm(_ delay: TimeInterval? = nil) {
        guard !closed else { return }
        timer?.cancel()
        let fast = turn != nil || !sent.isEmpty
        let seconds = delay ?? (fast ? timing.fast : timing.slow)
        timer = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.tick()
        }
    }

    private func tick() async {
        guard !closed else { return }
        await step()
        arm()
    }

    private func step() async {
        let entry = await host.entryFor(sessionId: sessionId)
        if mode == .elsewhere {
            var holderAlive = false
            var st: String?
            if let holder {
                holderAlive = isAlive(holder.pid, holder.procStart)
                if holderAlive { st = ClaudeAgentsRegistry.readSession(home: home, pid: holder.pid)?.status ?? holder.status }
            }
            syncStatus(st, alive: holderAlive, entry: entry)
        } else {
            syncStatus(entry?.workerStatus, alive: entry?.row.live == true, entry: entry)
        }
        if let until = historyWaitUntil {
            if now() < until { return }
            historyWaitUntil = nil
        }
        drain(entry)
        checkAck()
        // 状態が変わらないまま transcript だけ動いた（PC で attach して打った）ターンは、動きが止まっていれば閉じる。
        if turn?.implicit == true, !Self.isBusy(status), sent.isEmpty { closeTurn(entry) }
    }

    private func onEntry(_ entry: BgEntry?) {
        guard !closed else { return }
        syncStatus(entry?.workerStatus, alive: entry?.row.live == true, entry: entry)
        arm(0)
    }

    private static func isBusy(_ status: String?) -> Bool { status == "busy" }
    private static func isQuiet(_ status: String?) -> Bool { status == "idle" || status == "waiting" || status == "shell" }

    /// ワーカーの生の status の変化をターンに映す。
    private func syncStatus(_ status: String?, alive: Bool, entry: BgEntry?) {
        if let entry { cachedJobId = entry.row.id }
        let wasAlive = self.alive
        self.alive = alive
        self.status = status
        if !alive {
            // 送った発話が transcript に出ていないかを先に見る（届いていれば sent から外れる）。
            if !sent.isEmpty, !isWaitingForHistory { drain(entry) }
            if !sent.isEmpty {
                // 発話を受け取る前にワーカーが消えた。待ち続けず、失敗で閉じる。
                sent.removeAll()
                ackSince = nil
                let message = "PC のバックグラウンドのセッションが、この発話を受け取る前に止まりました。"
                if turn != nil {
                    emit(errorEvent(message))
                    closeTurn(entry, errored: true)
                } else {
                    publishFailure(message)
                }
            } else if wasAlive || turn != nil {
                closeTurn(entry)
            }
            return
        }
        if Self.isBusy(status) {
            if turn == nil { openTurn(implicit: false) } else { turn?.implicit = false }
        } else if Self.isQuiet(status), turn != nil {
            closeTurn(entry)
        }
    }

    @discardableResult
    private func openTurn(implicit: Bool) -> String {
        let t = Turn(messageId: UUID().uuidString, implicit: implicit)
        turn = t
        // 本文の無い activity（hub とアプリが生成中とみなす）。
        emit(.activity(agentId: agentId, sessionId: sessionId, messageId: t.messageId, text: ""))
        return t.messageId
    }

    /// transcript を最後まで読んでから done で閉じる。ワーカーが消えて失敗なら、先に error を流して done を errored にする。
    private func closeTurn(_ entry: BgEntry?, errored: Bool = false) {
        guard let t = turn else { return }
        // 履歴を待つ間は読まない（loadHistory が読む行と重なるため）。
        if !isWaitingForHistory { drain(entry) }
        turn = nil
        toolNames.removeAll()
        let state = entry?.row.state
        if !alive, state == .failed {
            emit(errorEvent("PC のバックグラウンドのセッションが止まりました（失敗）"))
            emit(SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: t.messageId).addingMetadata(["errored": "true"]))
            return
        }
        let done = SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: t.messageId)
        if errored { emit(done.addingMetadata(["errored": "true"])); return }
        emit(sent.isEmpty ? done : done.addingMetadata(["pending": "1"]))
    }

    private func drain(_ entry: BgEntry? = nil) {
        if file == nil { findTranscript(entry) }
        guard let file else { return }
        let (lines, next) = Self.readLines(path: file, from: offset ?? 0)
        offset = next
        for line in lines { ingest(line) }
    }

    /// from から最後の改行までの JSON 行。ファイルが縮んでいたら末尾から読み直す。
    static func readLines(path: String, from offset: UInt64, maxBytes: Int = 32 << 20) -> (lines: [[String: Any]], next: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], offset) }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return ([], offset) }
        if end < offset { return ([], end) }
        guard end > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(min(end - offset, UInt64(maxBytes)))) else { return ([], offset) }
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            // 上限まで読んでも改行が無い巨大な 1 行。その分は捨てて先へ進む（残りは JSON にならず読み飛ばされる）。
            return ([], data.count >= maxBytes ? offset + UInt64(data.count) : offset)
        }
        let complete = data[data.startIndex...lastNewline]
        var out: [[String: Any]] = []
        for line in complete.split(separator: 0x0A) {
            if let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { out.append(o) }
        }
        return (out, offset + UInt64(complete.count))
    }

    // MARK: - transcript の行 → イベント（§7.8 の表）

    private func ingest(_ o: [String: Any]) {
        if o["isSidechain"] as? Bool == true || o["isMeta"] as? Bool == true
            || o["isCompactSummary"] as? Bool == true || o["isVisibleInTranscriptOnly"] as? Bool == true { return }
        switch o["type"] as? String {
        case "assistant": ingestAssistant(o)
        case "user": ingestUser(o)
        case "system": ingestSystem(o)
        default: break
        }
    }

    private func ingestAssistant(_ o: [String: Any]) {
        guard let message = o["message"] as? [String: Any] else { return }
        let content = message["content"]
        let blocks: [[String: Any]]
        if let s = content as? String { blocks = [["type": "text", "text": s]] } else { blocks = content as? [[String: Any]] ?? [] }
        let key = (message["id"] as? String) ?? (o["uuid"] as? String) ?? ""
        for block in blocks {
            if block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty {
                if turn == nil { openTurn(implicit: true) }
                guard var t = turn else { continue }
                let mid: String
                if let existing = t.bubbles[key] {
                    mid = existing
                } else {
                    mid = t.bubbles.isEmpty ? t.messageId : UUID().uuidString
                    t.bubbles[key] = mid
                    turn = t
                }
                emit(.assistantDelta(text, agentId: agentId, sessionId: sessionId, messageId: mid))
            } else if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                let name = (block["name"] as? String) ?? "tool"
                if turn == nil { openTurn(implicit: true) }
                toolNames[id] = name
                emit(.toolStart(agentId: agentId, sessionId: sessionId, toolUseId: id, toolName: name,
                                title: ClaudeTerminalRegistry.toolTitle(name: name, input: block["input"]), kind: "tool"))
            }
        }
    }

    private func ingestUser(_ o: [String: Any]) {
        guard let message = o["message"] as? [String: Any] else { return }
        let content = message["content"]
        if let blocks = content as? [[String: Any]] {
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                let name = toolNames.removeValue(forKey: id) ?? "tool"
                let summary = String(Self.resultText(block["content"]).prefix(Self.summaryLimit))
                emit(.toolEnd(agentId: agentId, sessionId: sessionId, toolUseId: id, toolName: name,
                              status: block["is_error"] as? Bool == true ? "failed" : "completed",
                              summary: summary.isEmpty ? nil : summary, durationMs: nil))
            }
        }
        let raw = ClaudeCodeProjectsScanner.rawText(from: content)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if ClaudeCodeProjectsScanner.isPeer(o) {
            let body = ClaudeCodeProjectsScanner.stripPeerFrame(raw)
            if let i = sent.firstIndex(where: { !$0.isEmpty && body.contains($0) }) {
                // 送った発話が届いた。アプリは表示済み。
                sent.remove(at: i)
                ackSince = nil
                if turn == nil { openTurn(implicit: false) }
                return
            }
            let shown = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shown.isEmpty { emit(.userMessage(shown, agentId: agentId, sessionId: sessionId)) }
            return
        }
        let shown = ClaudeCodeProjectsScanner.conversationText(from: content)
        if !shown.isEmpty { emit(.userMessage(shown, agentId: agentId, sessionId: sessionId)) }
    }

    private func ingestSystem(_ o: [String: Any]) {
        let text = (o["content"] as? String) ?? ((o["message"] as? [String: Any])?["content"] as? String)
        guard let text, text.hasPrefix("Held peer message"), !sent.isEmpty else { return }
        sent.removeFirst()
        ackSince = nil
        publishFailure("PC のバックグラウンドのセッションが、この発話を保留しました。PC で `claude attach \(jobId())` を開いて「Deliver」を選ぶと届きます。")
    }

    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// 送った発話が 30 秒たっても transcript に出ない（status が idle / shell のまま）。busy の間は数えない。
    private func checkAck() {
        guard !sent.isEmpty else { ackSince = nil; return }
        if !alive { sent.removeAll(); ackSince = nil; return }
        if Self.isBusy(status) { ackSince = nil; return }
        let t = now()
        if ackSince == nil { ackSince = t }
        guard t.timeIntervalSince(ackSince!) >= timing.ack else { return }
        sent.removeFirst()
        ackSince = sent.isEmpty ? nil : t
        publishFailure("PC のバックグラウンドのセッションが、この発話を受け付けませんでした（30 秒たっても反応がありません）。")
    }

    private func publishFailure(_ message: String) {
        emit(errorEvent(message))
        // 失敗は送った発話のもので、動いているターンのものではない。ターンが開いていれば新しい messageId の pending な done にして、
        // 動いているターンを終わらせない（同じ messageId の done だとアプリがそのターンを閉じる）。
        let done = SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString)
        emit(done.addingMetadata(turn != nil ? ["errored": "true", "pending": "1"] : ["errored": "true"]))
    }

    private var cachedJobId: String?
    private func jobId() -> String { cachedJobId ?? String(sessionId.prefix(8)) }

    private func errorEvent(_ message: String) -> SessionEvent {
        SessionEvent(type: .error, agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString,
                     toolUseId: nil, content: message, toolName: nil, metadata: nil)
    }

    private func emit(_ event: SessionEvent) {
        guard !closed else { return }
        continuation.yield(event)
    }

    // MARK: - AgentSession

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        func fail(_ message: String) {
            emit(errorEvent(message))
            emit(SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString)
                .addingMetadata(["errored": "true"]))
        }
        if mode == .elsewhere {
            let where_ = holder?.entrypoint == "cli" ? "ターミナル" : "ほかのアプリ"
            return fail("この会話は PC の別の Claude Code（\(where_)、pid \(holder?.pid ?? 0)）で開かれています。そちらを閉じてから送ってください。")
        }
        let entry = await host.entryFor(sessionId: sessionId)
        guard let entry, entry.row.live else {
            unusable = true
            return fail("PC のバックグラウンドのセッションが止まりました。もう一度送ると、BuddyOS で続きから再開します。")
        }
        if entry.row.state == .blocked {
            return fail("PC で承認を待っています。PC で `claude attach \(entry.row.id)` を開いて答えてから、もう一度送ってください。")
        }
        // 添付と skill は本文に展開する。画像は本文に載せられないので、ファイルに書き出してパスを添える。
        var imageFiles: [URL?] = []
        for attachment in attachments {
            imageFiles.append(attachment.kind == .image
                ? await AttachmentStore.shared.exportFile(name: attachment.name, mime: attachment.mime, data: attachment.data)
                : nil)
        }
        let prompt = ClaudeTerminalSession.promptText(text: text, skills: skills, attachments: attachments, files: imageFiles)
        guard let inbox = entry.inbox else {
            return fail("PC のバックグラウンドのセッションに届けられませんでした（受け箱が見つかりません）。")
        }
        do {
            try await post(prompt, inbox)
        } catch {
            let reason = (error as? ClaudeInboxSocket.PostError)?.description ?? "\(error)"
            return fail("PC のバックグラウンドのセッションに届けられませんでした（\(reason)）。")
        }
        sent.append(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        while sent.count > Self.sentLimit { sent.removeFirst() }
        ackSince = nil
        WebSocketServer.wslog("bg-sessions: posted session=\(sessionId.prefix(8))… chars=\(prompt.count)")
        arm(0)
    }

    /// 返事だけは止められない。
    func interrupt() async {
        emit(errorEvent(Self.interruptText))
    }

    func warm() async {}

    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {}

    func subagentSnapshot() async -> String? { nil }
}
