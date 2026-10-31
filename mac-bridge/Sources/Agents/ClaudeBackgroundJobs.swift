import Foundation
import CoreServices

// ---------------------------------------------------------------------------
// claude --bg のセッションの見張り・一覧・差分の配信・停止と削除・完了の知らせ（BACKGROUND_CONTROL §7.4〜§7.7、§7.9）。
// 台帳を読む純粋な関数は ClaudeAgentsRegistry。ここは actor で、次を受け持つ。
//   - FSEvents（~/.claude の sessions/・jobs/・daemon/roster.json だけ）とワーカーの終了で台帳を読み直す
//   - 起動の 10 秒後・version の変化・6 時間ごとに `claude agents --json --all` と突き合わせ、2 回続けて違えば CLI 方式
//   - 行の変化を bg_session_changed で開いている全部の WS 接続へ（採番せず、差分 replay にも載せない）
//   - claude stop / claude rm（id ごとに 1 本ずつ）
//   - 最初の作業が終わったときの push、スリープの抑止（owner "claude-bg"）
// ログには id と state だけを書く。
// ---------------------------------------------------------------------------

struct BgCliResult: Sendable {
    var code: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

enum BgOperation: String, Sendable {
    case stop, delete
}

struct BgOperationResult: Sendable, Equatable {
    var ok: Bool
    var shells: Int
    var text: String
}

/// Live Activity へ渡す口（MAC-9 がつなぐ）。
struct BgActivity: Sendable, Equatable {
    /// sessionId → 1。working / blocked のセッション（繰り返しの待ちは数えない。§8.2）。
    var counts: [String: Int]
    /// この読み取りで終わった遷移（working / blocked から done / failed / stopped。消えたジョブは stopped）。
    var finished: [BgState]
}

struct BgTiming: Sendable {
    /// 変化を拾ってから読み直すまで待つ。続いても最初の変化からこれより長くは待たない。
    var debounce: TimeInterval = 0.15
    var maxDebounce: TimeInterval = 0.5
    /// 保険の読み直し（working / blocked / live のジョブがある間 / 無いとき）。
    var activeSeconds: TimeInterval = 10
    var idleSeconds: TimeInterval = 120
    /// CLI との突き合わせ（起動の後・やり直しの間隔・違ったときの確かめ直し）。
    var firstCrossCheck: TimeInterval = 10
    var crossCheckInterval: TimeInterval = 6 * 3600
    var mismatchRecheck: TimeInterval = 2
    /// CLI 方式で CLI を動かす最短の間隔と、失敗した後の間隔（30 秒 → 5 分）。
    var cliMinGap: TimeInterval = 2
    var cliRetry: [TimeInterval] = [30, 300]
    var listCli: TimeInterval = 20
    var stopCli: TimeInterval = 15
    var deleteCli: TimeInterval = 20
    /// 同じジョブが続けて busy でも、これを過ぎたらスリープの抑止に数えない。
    var busyLimit: TimeInterval = 6 * 3600
    /// ~/.claude が無いとき、できるのを確かめる間隔。
    var waitDir: TimeInterval = 60
}

struct BgJobsConfig: Sendable {
    var home: URL
    var timing = BgTiming()
    /// claude を動かす（引数は配列。シェルを通さない。作業フォルダはホーム）。
    var runCli: @Sendable ([String], TimeInterval) async -> BgCliResult
    var now: @Sendable () -> Date = { Date() }
    /// BuddyOS で付けた会話の名前。
    var buddyTitle: @Sendable (String) async -> String?
    /// 完了の push（sessionId, 本文）。誰かが開いている・60 秒以内かの判定は SessionHub が持つ。
    var push: @Sendable (String, String) async -> Void
    var setSleep: @Sendable (Bool) -> Void
    var isAlive: @Sendable (Int32, String?) -> Bool = { ClaudeAgentsRegistry.isProcessAlive(pid: $0, procStart: $1) }
    var log: @Sendable (String) -> Void = { WebSocketServer.wslog("bg-sessions: \($0)") }

    static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> BgJobsConfig {
        BgJobsConfig(
            home: home,
            runCli: { args, timeout in await ClaudeBackgroundJobs.runClaude(args, timeout: timeout, home: home) },
            buddyTitle: { await SessionOverrideStore.shared.customTitle(agentId: "claude", sessionId: $0) },
            push: { sessionId, body in
                await SessionHub.shared.pushBackgroundSessionEnded(sessionId: sessionId, body: body)
            },
            setSleep: { SleepGuard.shared.setActive($0, owner: "claude-bg", reason: "BuddyOS: claude --bg running") })
    }
}

actor ClaudeBackgroundJobs {
    static let shared = ClaudeBackgroundJobs()

    enum Mode: Equatable { case registry, cli }

    static let notFoundText = "このセッションは見つかりません（もう消えています）"

    private var config: BgJobsConfig
    /// ClaudeBackgroundSession が transcript を探すホーム（BgSessionHost）。
    nonisolated let homeDir: URL
    private(set) var mode: Mode = .registry

    private var senders: [UUID: @Sendable (SessionEvent) -> Void] = [:]
    private var activityListeners: [UUID: @Sendable (BgActivity) -> Void] = [:]
    private var entryListeners: [UUID: (sessionId: String, listener: @Sendable (BgEntry?) -> Void)] = [:]
    /// 台帳の全部（§7.3 の絞り込みの前）。id → 1 件。
    private var ledger: [String: BgEntry] = [:]
    private var listed: [BgEntry] = []
    /// 配信済みの行（sessionId → 行）。
    private var sent: [String: BgRow] = [:]
    private var initialized = false
    private var knownVersions: Set<String> = []
    private var lastActivityCounts: [String: Int]?

    private var inflight: Task<Void, Never>?
    private var again = false
    private var dirtyFirst: Date?
    private var dirtyLast: Date?
    private var debounceTask: Task<Void, Never>?

    private var started = false
    private var tasks: [Task<Void, Never>] = []
    private var fsWatcher: BgFSEventWatcher?
    private var watchRoots: [String] = []
    private var exitSources: [Int32: DispatchSourceProcess] = [:]

    private var lastCliRows: [BgCliRow]?
    private var lastCliAt: Date = .distantPast
    private var nextCliAt: Date = .distantPast
    private var cliFailures = 0
    private var crossChecking = false

    private var operations: [String: Task<Void, Never>] = [:]
    private var busySince: [String: Date] = [:]
    private var busyLogged: Set<String> = []
    private var sleeping = false

    init(config: BgJobsConfig = .live()) {
        self.config = config
        self.homeDir = config.home
    }

    var isCliMode: Bool { mode == .cli }

    // MARK: - 開始・終了

    func start() {
        guard !started else { return }
        started = true
        tasks.append(Task { [weak self] in await self?.periodicLoop() })
        tasks.append(Task { [weak self] in await self?.crossCheckLoop() })
        tasks.append(Task { [weak self] in await self?.watchLoop() })
    }

    func stop() {
        started = false
        for t in tasks { t.cancel() }
        tasks = []
        debounceTask?.cancel()
        debounceTask = nil
        fsWatcher?.stop()
        fsWatcher = nil
        for s in exitSources.values { s.cancel() }
        exitSources = [:]
        if sleeping { config.setSleep(false) }
        sleeping = false
    }

    /// 接続のたびに登録する（UsageHub と同じ場所）。閉じたら unregister。
    func register(send: @escaping @Sendable (SessionEvent) -> Void) -> UUID {
        let id = UUID()
        senders[id] = send
        return id
    }

    func unregister(_ id: UUID) {
        senders.removeValue(forKey: id)
    }

    /// Live Activity が数と終わった遷移を受ける（MAC-9）。数が変わったときと、終わった遷移があったときに呼ぶ。
    func onActivity(_ listener: @escaping @Sendable (BgActivity) -> Void) -> UUID {
        let id = UUID()
        activityListeners[id] = listener
        return id
    }

    func removeActivityListener(_ id: UUID) {
        activityListeners.removeValue(forKey: id)
    }

    /// いまの数（sessionId → 1）。
    func activityCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        if cliUnavailable { return counts }
        for e in ledger.values where Self.isRunning(e) { counts[e.row.sessionId] = 1 }
        return counts
    }

    /// そのセッションのジョブの変化（行・生の status・受け箱のどれか。消えたときは nil）を受ける。
    /// 開いている ClaudeBackgroundSession が生の status でターンを開け閉めするのに使う（MAC-8）。
    func watchEntry(sessionId: String, _ listener: @escaping @Sendable (BgEntry?) -> Void) -> UUID {
        let id = UUID()
        entryListeners[id] = (sessionId, listener)
        return id
    }

    func unwatchEntry(_ id: UUID) {
        entryListeners.removeValue(forKey: id)
    }

    // MARK: - 一覧

    /// 最初の読み取りが終わるまで待つ。
    func ready() async {
        guard !initialized else { return }
        // 読み取り中なら、それが終わるのを待つ（refresh() だと終わった後にもう 1 回読み直す）。
        if let current = inflight { await current.value }
        if !initialized { await refresh() }
    }

    /// 一覧の行（blocked → working → ほか）。CLI が失敗し続けているときは空。
    func rows() -> [BgRow] {
        if cliUnavailable { return [] }
        return listed.map(\.row)
    }

    /// CLI 方式で `claude agents` が 3 回続けて失敗している。一覧・変化の配信・Live Activity の数はその間 0 件にそろえる。
    private var cliUnavailable: Bool { mode == .cli && cliFailures >= 3 }

    /// 台帳にあるジョブ（§7.3 の絞り込みの前）を sessionId で引く。
    func entryFor(sessionId: String) -> BgEntry? {
        ledger.values.first { $0.row.sessionId == sessionId }
    }

    /// ワーカー以外で同じ sessionId を握っている生きているプロセス（ClaudeCodeAdapter.openSession の elsewhere。§7.8 の 3）。
    func holder(sessionId: String, excluding: Set<Int32>) -> BgSessionRecord? {
        ClaudeAgentsRegistry.holder(sessionId: sessionId, excluding: excluding, home: config.home, isAlive: config.isAlive)
    }

    func isBackgroundWorker(sessionId: String) -> Bool {
        entryFor(sessionId: sessionId)?.row.live == true
    }

    // MARK: - 読み直し

    /// 読み直す。読み取り中なら終わってからもう 1 回だけ読む。
    func refresh() async {
        if let current = inflight {
            again = true
            await current.value
            return
        }
        let task = Task { await self.readLoop() }
        inflight = task
        await task.value
    }

    private func readLoop() async {
        repeat {
            again = false
            await read()
        } while again
        inflight = nil
    }

    private func nowMs() -> Int64 { Int64((config.now().timeIntervalSince1970 * 1000).rounded()) }

    private func loadTitles(_ sessionIds: [String]) async -> [String: String] {
        var out: [String: String] = [:]
        for sid in Set(sessionIds) {
            if let t = await config.buddyTitle(sid), !t.isEmpty { out[sid] = t }
        }
        return out
    }

    private func readSnapshot() async -> BgLedgerSnapshot {
        let cfg = config
        return await ProcessRunner.offload { ClaudeAgentsRegistry.readSnapshot(home: cfg.home, isAlive: cfg.isAlive) }
    }

    private func read() async {
        let snapshot = await readSnapshot()
        let now = nowMs()
        var cliRows: [BgCliRow]?
        if mode == .cli { cliRows = await cliRowsForRead() }
        var sessionIds = snapshot.jobs.values.compactMap(\.sessionId)
        if let cliRows { sessionIds += cliRows.map(\.sessionId) }
        let titles = await loadTitles(sessionIds)
        let titleOf: (String) -> String? = { titles[$0] }

        let entries: [BgEntry]
        if mode == .cli, let cliRows {
            entries = ClaudeAgentsRegistry.cliEntries(cliRows, snapshot: snapshot, nowMs: now, buddyTitle: titleOf)
        } else {
            entries = ClaudeAgentsRegistry.ledgerEntries(snapshot, nowMs: now, buddyTitle: titleOf)
        }
        var next: [String: BgEntry] = [:]
        for e in entries { next[e.row.id] = e }
        let selected = ClaudeAgentsRegistry.selectListed(entries, nowMs: now)

        let previous = ledger
        ledger = next
        listed = selected

        deliver(cliUnavailable ? [] : selected)
        var finished: [BgState] = []
        if initialized {
            finished = Self.finishedTransitions(previous: previous, next: next)
            notifyEnded(previous: previous, next: next)
        }
        notifyEntryListeners(previous: previous)
        updateSleep(next)
        syncExitSources(next)
        emitActivity(finished: finished)

        if initialized {
            let newVersion = !snapshot.versions.subtracting(knownVersions).isEmpty
            knownVersions.formUnion(snapshot.versions)
            if newVersion { scheduleCrossCheck(after: 0) }
        } else {
            knownVersions = snapshot.versions
        }
        initialized = true
    }

    /// CLI 方式の読み取り。失敗は前の結果を保ち、30 秒 → 5 分と間を空ける。
    private func cliRowsForRead() async -> [BgCliRow]? {
        let now = config.now()
        if now >= nextCliAt, now.timeIntervalSince(lastCliAt) >= config.timing.cliMinGap || lastCliRows == nil {
            lastCliAt = now
            let rows = await runList()
            // 最短の間隔は CLI が終わった時刻から数える（遅い実行が続けて走らないように）。
            lastCliAt = config.now()
            if let rows {
                lastCliRows = rows
                cliFailures = 0
            } else {
                cliFailures += 1
                let retry = config.timing.cliRetry
                nextCliAt = config.now().addingTimeInterval(retry[min(cliFailures - 1, retry.count - 1)])
                config.log("cli list failed (\(cliFailures))")
            }
        }
        return lastCliRows
    }

    private func runList() async -> [BgCliRow]? {
        let result = await config.runCli(["agents", "--json", "--all"], config.timing.listCli)
        guard result.code == 0, !result.timedOut else { return nil }
        return ClaudeAgentsRegistry.parseAgentsJSON(result.stdout)
    }

    // MARK: - 差分と配信（§7.6）

    private func deliver(_ listed: [BgEntry]) {
        var next: [String: BgRow] = [:]
        for e in listed { next[e.row.sessionId] = e.row }
        for e in listed where sent[e.row.sessionId] != e.row {
            broadcast(.bgSessionChanged(json: e.row.json, sessionId: e.row.sessionId))
        }
        for (sessionId, row) in sent where next[sessionId] == nil {
            broadcast(.bgSessionChanged(json: BgRow.removedJSON(id: row.id, sessionId: sessionId), sessionId: sessionId))
        }
        sent = next
    }

    private func broadcast(_ event: SessionEvent) {
        for send in senders.values { send(event) }
    }

    private func notifyEntryListeners(previous: [String: BgEntry]) {
        guard !entryListeners.isEmpty else { return }
        var before: [String: BgEntry] = [:]
        for e in previous.values { before[e.row.sessionId] = e }
        var after: [String: BgEntry] = [:]
        for e in ledger.values { after[e.row.sessionId] = e }
        for (_, item) in entryListeners where before[item.sessionId] != after[item.sessionId] {
            item.listener(after[item.sessionId])
        }
    }

    // MARK: - Live Activity（§8.2）

    static func isRunning(_ e: BgEntry) -> Bool {
        (e.row.state == .working || e.row.state == .blocked) && !e.recurringWait
    }

    static func finishedTransitions(previous: [String: BgEntry], next: [String: BgEntry]) -> [BgState] {
        var out: [BgState] = []
        for (id, before) in previous where isRunning(before) {
            if let after = next[id] {
                if after.row.state.isFinished { out.append(after.row.state) }
            } else {
                out.append(.stopped)
            }
        }
        return out
    }

    private func emitActivity(finished: [BgState]) {
        let counts = activityCounts()
        guard counts != lastActivityCounts || !finished.isEmpty else { return }
        lastActivityCounts = counts
        let activity = BgActivity(counts: counts, finished: finished)
        for l in activityListeners.values { l(activity) }
    }

    // MARK: - 知らせ（§7.9）

    private func notifyEnded(previous: [String: BgEntry], next: [String: BgEntry]) {
        for (id, entry) in next {
            guard let before = previous[id] else { continue }
            guard before.row.state == .working || before.row.state == .blocked else { continue }
            guard !before.firstTerminal, entry.firstTerminal else { continue }
            guard entry.row.state == .done || entry.row.state == .failed else { continue }
            let cfg = config
            Task { [self] in
                let body = await Self.endedBody(entry, home: cfg.home)
                config.log("ended \(entry.row.id) \(entry.row.state.rawValue)")
                await cfg.push(entry.row.sessionId, body)
            }
        }
    }

    /// done は transcript の末尾 512 KB の最後の assistant の text の頭 180 字。failed は detail の頭 120 字を足す。
    static func endedBody(_ entry: BgEntry, home: URL) async -> String {
        if entry.row.state == .failed {
            let detail = String((entry.row.detail ?? "").prefix(120))
            return "バックグラウンドのセッションが失敗しました" + (detail.isEmpty ? "" : "（\(detail)）")
        }
        let sessionId = entry.row.sessionId
        let linkScanPath = entry.linkScanPath
        let text = await ProcessRunner.offload { lastAssistantText(path: linkScanPath, sessionId: sessionId, home: home) }
        if let text, !text.isEmpty { return String(text.prefix(180)) }
        return "バックグラウンドのセッションが終わりました"
    }

    // MARK: - transcript の末尾

    private static let tailBytes = 512 * 1024

    /// 名前が `<sessionId>.jsonl`、ホームの中、自分の普通のファイル（シンボリックリンクは読まない）。
    static func validTranscript(_ path: String?, sessionId: String, home: URL) -> URL? {
        guard let path, !path.isEmpty, (path as NSString).lastPathComponent == "\(sessionId).jsonl" else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let root = home.standardizedFileURL.path
        guard url.path.hasPrefix(root + "/") else { return nil }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return nil }
        return url
    }

    static func findTranscript(sessionId: String, home: URL) -> URL? {
        let projects = ClaudeAgentsRegistry.claudeDir(home: home).appendingPathComponent("projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { return nil }
        for d in dirs {
            let p = projects.appendingPathComponent(d).appendingPathComponent("\(sessionId).jsonl").path
            if let url = validTranscript(p, sessionId: sessionId, home: home) { return url }
        }
        return nil
    }

    /// transcript の末尾 512 KB にある main の最後の assistant の text。
    static func lastAssistantText(path: String?, sessionId: String, home: URL) -> String? {
        guard let url = validTranscript(path, sessionId: sessionId, home: home) ?? findTranscript(sessionId: sessionId, home: home),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  o["type"] as? String == "assistant", o["isSidechain"] as? Bool != true,
                  let message = o["message"] as? [String: Any] else { continue }
            let text: String
            if let s = message["content"] as? String {
                text = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - スリープの抑止（§7.9）

    /// 生きているワーカーのどれかの生の status が busy の間だけ保つ。shell は数えない。同じジョブが 6 時間続けて busy なら数えない。
    private func updateSleep(_ ledger: [String: BgEntry]) {
        let now = config.now()
        var busyIds = Set<String>()
        var count = 0
        for (id, e) in ledger where e.row.live && e.workerStatus == "busy" {
            busyIds.insert(id)
            let since = busySince[id] ?? now
            busySince[id] = since
            if now.timeIntervalSince(since) >= config.timing.busyLimit {
                if busyLogged.insert(id).inserted { config.log("job \(id) busy for 6h, not holding sleep") }
                continue
            }
            count += 1
        }
        for id in Array(busySince.keys) where !busyIds.contains(id) {
            busySince.removeValue(forKey: id)
            busyLogged.remove(id)
        }
        let active = count > 0
        if active != sleeping {
            sleeping = active
            config.setSleep(active)
        }
    }

    // MARK: - ワーカーの終了（§7.4 の 4）

    private func syncExitSources(_ ledger: [String: BgEntry]) {
        guard started else { return }
        let pids = Set(ledger.values.compactMap { $0.row.live ? $0.pid : nil })
        for (pid, source) in exitSources where !pids.contains(pid) {
            source.cancel()
            exitSources.removeValue(forKey: pid)
        }
        for pid in pids where exitSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
            source.setEventHandler { [weak self] in
                Task { await self?.workerExited(pid) }
            }
            source.resume()
            exitSources[pid] = source
        }
    }

    private func workerExited(_ pid: Int32) async {
        exitSources[pid]?.cancel()
        exitSources.removeValue(forKey: pid)
        await refresh()
    }

    // MARK: - 見張り（§7.4）

    /// 拾うのは sessions/・jobs/・daemon/roster.json の変化だけ（*.key と state.json.tmp.* は無視）。
    /// roots は見ているフォルダの元のパスと実体のパス（~/.claude がシンボリックリンクだと FSEvents は実体で知らせる）。
    static func isRelevantChange(_ path: String, roots: [String] = []) -> Bool {
        var relative: Substring?
        for root in roots where path.hasPrefix(root + "/") { relative = path.dropFirst(root.count + 1); break }
        if relative == nil, let range = path.range(of: "/.claude/") { relative = path[range.upperBound...] }
        guard let rel = relative else { return false }
        let parts = rel.split(separator: "/").map(String.init)
        guard let first = parts.first, let last = parts.last else { return false }
        if last.hasSuffix(".key") || last.contains(".tmp.") { return false }
        switch first {
        case "sessions", "jobs": return true
        case "daemon": return parts.count == 2 && last == "roster.json"
        default: return false
        }
    }

    /// overflow: イベントの取りこぼし（MustScanSubDirs など）。パスを見ずに読み直す。
    func trigger(paths: [String], overflow: Bool = false) {
        guard overflow || paths.contains(where: { Self.isRelevantChange($0, roots: watchRoots) }) else { return }
        markDirty()
    }

    /// 変化を拾った。150 ミリ秒待ってから読み直す（続いても 500 ミリ秒より長くは待たない）。CLI 方式は最短 2 秒おき。
    func markDirty() {
        let now = Date()
        dirtyFirst = dirtyFirst ?? now
        dirtyLast = now
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in await self?.debounceLoop() }
    }

    private func debounceLoop() async {
        while !Task.isCancelled {
            guard let first = dirtyFirst, let last = dirtyLast else { break }
            let t = config.timing
            var due = min(last.addingTimeInterval(t.debounce), first.addingTimeInterval(t.maxDebounce))
            if mode == .cli { due = max(due, lastCliAt.addingTimeInterval(t.cliMinGap)) }
            let wait = due.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            break
        }
        dirtyFirst = nil
        dirtyLast = nil
        debounceTask = nil
        if !Task.isCancelled { await refresh() }
    }

    private func hasActive() -> Bool {
        ledger.values.contains { $0.row.live || $0.row.state == .working || $0.row.state == .blocked }
    }

    /// 保険の読み直し。working / blocked / live のジョブがある間は 10 秒ごと、無ければ 120 秒ごと。
    private func periodicLoop() async {
        await refresh()
        while !Task.isCancelled {
            let seconds = hasActive() ? config.timing.activeSeconds : config.timing.idleSeconds
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { break }
            await refresh()
        }
    }

    /// ~/.claude を FSEvents で見る。無ければ 60 秒ごとに確かめる。
    private func watchLoop() async {
        while !Task.isCancelled {
            if fsWatcher == nil {
                let dir = ClaudeAgentsRegistry.claudeDir(home: config.home)
                if FileManager.default.fileExists(atPath: dir.path) {
                    let real = dir.resolvingSymlinksInPath().path
                    watchRoots = real == dir.path ? [dir.path] : [dir.path, real]
                    fsWatcher = BgFSEventWatcher(path: dir.path) { [weak self] paths, overflow in
                        Task { await self?.trigger(paths: paths, overflow: overflow) }
                    }
                    if fsWatcher != nil { markDirty() }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(config.timing.waitDir * 1_000_000_000))
        }
    }

    // MARK: - CLI との突き合わせ（§7.5）

    private func crossCheckLoop() async {
        try? await Task.sleep(nanoseconds: UInt64(config.timing.firstCrossCheck * 1_000_000_000))
        while !Task.isCancelled {
            await crossCheck()
            try? await Task.sleep(nanoseconds: UInt64(config.timing.crossCheckInterval * 1_000_000_000))
        }
    }

    private func scheduleCrossCheck(after seconds: TimeInterval) {
        guard started, !crossChecking else { return }
        Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await self?.crossCheck()
        }
    }

    /// 台帳から作った結果と `claude agents --json --all` を id → (state, pid の有無) で比べる。
    /// 違えば 2 秒後にもう 1 回比べ、2 回続けて違えば CLI 方式にする。一致すれば台帳の方式に戻す。
    /// CLI が失敗したときは何も変えない。
    func crossCheck() async {
        guard !crossChecking else { return }
        crossChecking = true
        defer { crossChecking = false }
        guard let first = await compareOnce() else { return }
        if first.match {
            await switchMode(to: .registry)
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(config.timing.mismatchRecheck * 1_000_000_000))
        guard let second = await compareOnce() else { return }
        if second.match {
            await switchMode(to: .registry)
            return
        }
        lastCliRows = second.cli
        lastCliAt = config.now()
        cliFailures = 0
        nextCliAt = .distantPast
        await switchMode(to: .cli, detail: second.detail)
    }

    private func switchMode(to new: Mode, detail: String = "") async {
        guard mode != new else { return }
        mode = new
        config.log(new == .cli ? "registry mismatch → cli mode \(detail)" : "registry matches cli → registry mode")
        await refresh()
    }

    private func compareOnce() async -> (match: Bool, cli: [BgCliRow], detail: String)? {
        guard let cli = await runList() else { return nil }
        let snapshot = await readSnapshot()
        let entries = ClaudeAgentsRegistry.ledgerEntries(snapshot, nowMs: nowMs(), buddyTitle: { _ in nil })
        let match = ClaudeAgentsRegistry.ledgerMatchesCli(entries, cli: cli)
        var detail = ""
        if !match {
            var ours: [String: String] = [:]
            for e in entries { ours[e.row.id] = e.row.state.rawValue + (e.row.live ? "+pid" : "") }
            var diffs: [String] = []
            for c in cli {
                let theirs = (c.state ?? "?") + (c.pid != nil ? "+pid" : "")
                if ours[c.id] != theirs { diffs.append("\(c.id):\(ours[c.id] ?? "none")/\(theirs)") }
            }
            for id in ours.keys where !cli.contains(where: { $0.id == id }) { diffs.append("\(id):\(ours[id] ?? "")/none") }
            detail = "(" + diffs.sorted().prefix(5).joined(separator: ", ") + ")"
        }
        return (match, cli, detail)
    }

    // MARK: - 操作（§7.7）

    /// claude stop / claude rm。同じ id への操作は 1 本ずつ（後の要求は前の結果を待ってから走る）。
    func operate(_ op: BgOperation, id: String, sessionId: String?) async -> BgOperationResult {
        let previous = operations[id]
        let run = Task { () -> BgOperationResult in
            await previous?.value
            return await self.runOperation(op, id: id, sessionId: sessionId)
        }
        let tail = Task { _ = await run.value }
        operations[id] = tail
        let result = await run.value
        if operations[id] == tail { operations.removeValue(forKey: id) }
        return result
    }

    private func runOperation(_ op: BgOperation, id: String, sessionId: String?) async -> BgOperationResult {
        // 1. id の形・台帳にあり sessionId が一致すること（7.3 の絞り込みの前の台帳）
        guard ClaudeAgentsRegistry.isJobId(id), let entry = ledger[id], entry.row.sessionId == sessionId else {
            return BgOperationResult(ok: false, shells: 0, text: Self.notFoundText)
        }
        // 3. そのときの shells を覚える
        let shells = entry.row.shells
        let timeout = op == .stop ? config.timing.stopCli : config.timing.deleteCli
        let result = await config.runCli([op == .stop ? "stop" : "rm", id], timeout)
        let outcome = Self.judge(op, id: id, result: result, timeout: timeout)
        config.log("\(op.rawValue) \(id) ok=\(outcome.ok ? 1 : 0)")
        // 6. すぐ台帳を読み直す（CLI 方式でも古い結果を使い回さない）。結果は待たない。
        //    読み直しが遅くてもアプリの 25 秒を超えないよう、変化は bg_session_changed で届ける。
        lastCliAt = .distantPast
        Task { await self.refresh() }
        guard outcome.ok else { return BgOperationResult(ok: false, shells: shells, text: outcome.text) }
        let text = shells > 0
            ? "\(op == .stop ? "止めました" : "削除しました")。裏で動いていたコマンド \(shells) 件は PC で動いたままです。"
            : ""
        return BgOperationResult(ok: true, shells: shells, text: text)
    }

    /// 5. の判定。
    static func judge(_ op: BgOperation, id: String, result: BgCliResult, timeout: TimeInterval) -> (ok: Bool, text: String) {
        if result.timedOut {
            let seconds = Int(timeout.rounded())
            return (false, op == .stop
                ? "PC で止められませんでした（\(seconds)秒たっても終わりません）"
                : "PC で削除できませんでした（\(seconds)秒たっても終わりません）")
        }
        let word = op == .stop ? "stopped" : "removed"
        if result.code == 0,
           result.stdout.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == "\(word) \(id)" }) {
            return (true, "")
        }
        if result.code == 1, result.stderr.contains("No job matching") {
            return op == .stop ? (false, notFoundText) : (true, "")
        }
        let last = lastLines(result.stderr)
        return (false, last.isEmpty ? (op == .stop ? "PC で止められませんでした" : "PC で削除できませんでした") : last)
    }

    /// stderr の最後の 3 行（400 字まで）。
    static func lastLines(_ text: String, lines: Int = 3, limit: Int = 400) -> String {
        let joined = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
        return joined.count > limit ? String(joined.suffix(limit)) : joined
    }

    // MARK: - claude の実行

    /// シェルを通さず、環境は ChildEnvironment.base(merging: ["BUDDYOS_SPAWNED": "1"])、作業フォルダはホーム。
    static func runClaude(_ args: [String], timeout: TimeInterval, home: URL) async -> BgCliResult {
        await ProcessRunner.offload {
            let exe = ClaudeCodeAdapter.locateExecutable()
            guard let out = ProcessRunner.run(
                exe, args, timeout: timeout,
                environment: ChildEnvironment.base(merging: ["BUDDYOS_SPAWNED": "1"]),
                currentDirectory: home.path) else {
                return BgCliResult(code: -1, stdout: "", stderr: "claude を起動できません", timedOut: false)
            }
            return BgCliResult(code: out.status, stdout: String(decoding: out.stdout, as: UTF8.self),
                               stderr: String(decoding: out.stderr, as: UTF8.self), timedOut: out.timedOut)
        }
    }
}

/// FSEvents（kFSEventStreamCreateFlagFileEvents、latency 0.1 秒）で 1 つのフォルダを見る。
final class BgFSEventWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String], Bool) -> Void
    private let queue = DispatchQueue(label: "buddyos.claude-bg.fsevents", qos: .utility)

    init?(path: String, handler: @escaping @Sendable ([String], Bool) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info, count > 0 else { return }
            let me = Unmanaged<BgFSEventWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                                               | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            var overflow = false
            for i in 0..<count where eventFlags[i] & lost != 0 { overflow = true }
            me.handler(paths, overflow)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
