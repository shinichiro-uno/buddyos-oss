import Foundation

// MARK: - Schedule parsing

/// 5 フィールド cron 式 (`minute hour day-of-month month day-of-week`)。
/// `*` / 単一値 / `*/step` / `a-b` / `a,b,c` をサポートする (vixie-cron 互換の最小実装)。
/// day-of-week は 0 or 7 = 日曜。day-of-month と day-of-week の両方が制約されている場合は
/// vixie 同様「どちらかが一致すれば日が一致」とみなす。
struct CronExpression: Sendable, Equatable {
    let minutes: [Int]      // 0-59 (昇順)
    let hours: [Int]        // 0-23 (昇順)
    let days: [Int]         // 1-31 (昇順)
    let months: Set<Int>    // 1-12
    let weekdays: Set<Int>  // 0-6 (0=日)
    let dayRestricted: Bool
    let weekdayRestricted: Bool

    static func parse(_ raw: String) -> CronExpression? {
        let fields = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count == 5 else { return nil }
        guard let minutes = parseField(fields[0], min: 0, max: 59),
              let hours = parseField(fields[1], min: 0, max: 23),
              let days = parseField(fields[2], min: 1, max: 31),
              let months = parseField(fields[3], min: 1, max: 12),
              let weekdaysRaw = parseField(fields[4], min: 0, max: 7) else { return nil }
        // 7 = 日曜 → 0 に正規化
        let weekdays = Set(weekdaysRaw.map { $0 == 7 ? 0 : $0 })
        return CronExpression(
            minutes: minutes.sorted(),
            hours: hours.sorted(),
            days: days.sorted(),
            months: Set(months),
            weekdays: weekdays,
            dayRestricted: fields[2] != "*",
            weekdayRestricted: fields[4] != "*"
        )
    }

    /// 1 フィールドを展開。`L` / `W` / 名前エイリアスは非対応 (nil を返す)。
    private static func parseField(_ field: String, min: Int, max: Int) -> [Int]? {
        var out: Set<Int> = []
        for part in field.split(separator: ",").map(String.init) {
            // "<base>/<step>"
            let stepSplit = part.split(separator: "/", maxSplits: 1).map(String.init)
            let base = stepSplit[0]
            let step: Int
            if stepSplit.count == 2 {
                guard let s = Int(stepSplit[1]), s > 0 else { return nil }
                step = s
            } else {
                step = 1
            }
            let lo: Int
            let hi: Int
            if base == "*" {
                lo = min; hi = max
            } else if base.contains("-") {
                let r = base.split(separator: "-", maxSplits: 1).map(String.init)
                guard r.count == 2, let a = Int(r[0]), let b = Int(r[1]), a <= b else { return nil }
                lo = a; hi = b
            } else {
                guard let v = Int(base) else { return nil }
                // 単一値 + step ("5/15") は vixie 互換で "5-max/15"
                lo = v; hi = stepSplit.count == 2 ? max : v
            }
            guard lo >= min, hi <= max else { return nil }
            var v = lo
            while v <= hi {
                out.insert(v)
                v += step
            }
        }
        return out.isEmpty ? nil : Array(out)
    }

    /// `after` より後の最初の一致時刻 (ローカルタイムゾーン)。最大 366 日先まで探索。
    func next(after: Date, calendar: Calendar = .current) -> Date? {
        // 分単位に切り上げ
        var cursor = calendar.date(
            bySetting: .second, value: 0,
            of: after.addingTimeInterval(60)
        ) ?? after.addingTimeInterval(60)
        if cursor <= after { cursor = cursor.addingTimeInterval(60) }

        let startDay = calendar.startOfDay(for: cursor)
        for dayOffset in 0..<366 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startDay) else { continue }
            let comps = calendar.dateComponents([.month, .day, .weekday], from: day)
            guard let month = comps.month, let dom = comps.day, let wd = comps.weekday else { continue }
            guard months.contains(month) else { continue }
            let weekday = wd - 1  // Calendar: 1=日 → cron: 0=日
            let domMatch = days.contains(dom)
            let dowMatch = weekdays.contains(weekday)
            let dayMatch: Bool
            if dayRestricted && weekdayRestricted {
                dayMatch = domMatch || dowMatch
            } else {
                dayMatch = (!dayRestricted || domMatch) && (!weekdayRestricted || dowMatch)
            }
            guard dayMatch else { continue }
            for hour in hours {
                for minute in minutes {
                    guard let candidate = calendar.date(
                        bySettingHour: hour, minute: minute, second: 0, of: day
                    ) else { continue }
                    if candidate > after { return candidate }
                }
            }
        }
        return nil
    }
}

/// ジョブのスケジュール表現。iOS からは "every 30m" / "2h" のような interval 表記か
/// 5 フィールド cron 式が来る。interval は最終実行時刻からの相対で次回を決める。
enum BridgeCronSchedule: Sendable, Equatable {
    case interval(TimeInterval)
    case cron(CronExpression)

    static func parse(_ raw: String) -> BridgeCronSchedule? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = parseInterval(trimmed) {
            return .interval(max(60, seconds))
        }
        if let cron = CronExpression.parse(trimmed) {
            return .cron(cron)
        }
        return nil
    }

    /// "every 30m" / "every 2 h" / "30m" / "2h" / "1d" / "90s" → 秒数。
    private static func parseInterval(_ raw: String) -> TimeInterval? {
        var s = raw.lowercased()
        if s.hasPrefix("every ") { s = String(s.dropFirst(6)) }
        s = s.replacingOccurrences(of: " ", with: "")
        guard let unit = s.last, "smhd".contains(unit) else { return nil }
        guard let amount = Int(s.dropLast()), amount > 0 else { return nil }
        switch unit {
        case "s": return TimeInterval(amount)
        case "m": return TimeInterval(amount * 60)
        case "h": return TimeInterval(amount * 3600)
        case "d": return TimeInterval(amount * 86400)
        default: return nil
        }
    }

    func next(after: Date) -> Date? {
        switch self {
        case .interval(let seconds):
            return after.addingTimeInterval(seconds)
        case .cron(let expr):
            return expr.next(after: after)
        }
    }
}

// MARK: - Job model

/// Bridge 自前スケジューラのジョブ 1 件。`~/.buddyos/cron/jobs.json` に永続化される。
struct BridgeCronJob: Codable, Sendable {
    let id: String              // 8 桁 hex
    let agentId: String         // "claude" / "codex" 等
    var name: String
    var prompt: String
    var schedule: String        // ユーザー入力そのまま (表示用 + 再パース元)
    var cwd: String?
    /// BuddyOS モードラベル ("plan"/"edit"/"auto"/"dangerous")。nil = エージェントのグローバル設定に従う。
    var permissionMode: String?
    var deliver: String
    var enabled: Bool
    var createdAt: Date
    var lastRunAt: Date?
    var lastStatus: String?     // "ok" / "error" / "timeout"
    var repeatCount: Int?       // 発火回数の上限。nil = 無制限
    var runsCompleted: Int
    /// 前回の実行の会話。一覧から開くのに使う（前の版で作ったジョブは出力ファイルの `session:` から読む）。
    var lastSessionId: String? = nil

    var parsedSchedule: BridgeCronSchedule? {
        BridgeCronSchedule.parse(schedule)
    }
}

// MARK: - Scheduler

/// Claude Code / Codex のような「CLI 側に常駐スケジューラを持たない」エージェントのための
/// Bridge 内蔵 cron スケジューラ。
///
/// 方式は Claude Code Desktop / Codex アプリの定期実行と同じ
/// 「常駐プロセスが定期チェック → 発火ごとに新規セッションをヘッドレス起動 → 結果を受信箱へ」。
/// Bridge は launchd 常駐なので、両者と違い専用アプリを開いておく必要がない。
///
/// - 発火 = `adapter.openSession() → session.send(prompt)`。通常チャットと同じ経路なので
///   モデル設定・settings.json の allow ルール等がそのまま効く。
/// - 結果は `~/.buddyos/cron/output/<jobId>/<ts>.md` に書き、CronOutputHub が検知して
///   WS broadcast + APNs push する (hermes cron と同じ配信経路)。
/// - キャッチアップ: next は lastRunAt 基準で計算するので、スリープ等で逃した分は
///   復帰後の最初の tick で「1 回だけ」発火する (Claude Desktop と同じ挙動)。
/// - ジッター: 同時刻の API 集中を避けるため jobId から決定的に導出した 0-90 秒を加算。
actor BridgeCronScheduler {
    static let shared = BridgeCronScheduler()

    private var jobs: [BridgeCronJob] = []
    private var runningIds: Set<String> = []
    private var timedOutIds: Set<String> = []
    private var started = false
    private var tickTask: Task<Void, Never>?

    /// 1 run の最長時間。超えたら interrupt して "timeout" として記録する。
    private let runTimeout: TimeInterval = 30 * 60
    private let tickInterval: TimeInterval = 30
    /// done の後に待っていたバックグラウンドの作業が終わってから、知らせのターン（その done）が始まるのを待つ上限。
    /// 始まらない（知らせのターンを持たない adapter）ときは、runTimeout まで待たずにここで打ち切る。
    private static let backgroundSettleGrace: TimeInterval = 120

    static var jobsFile: String {
        BuddyPaths.root.appendingPathComponent("cron/jobs.json").path
    }

    /// jobs.json を読めなかったうえに退避もできなかったとき true。保存すると元のファイルを
    /// 上書きして全ジョブを失うので、この間は保存しない（直して Bridge を再起動すれば戻る）。
    private var saveBlocked = false

    static var outputRoot: String {
        NSHomeDirectory() + "/.buddyos/cron/output"
    }

    // MARK: 作業フォルダ

    /// 定期実行の作業フォルダを決める。空欄はホームフォルダ。存在するフォルダであることを確かめ、
    /// `/`・システムのフォルダ・アプリの中（Bridge のバイナリのあるフォルダを含む）は断る。
    /// 空欄のまま渡すと、エージェントは Bridge の作業フォルダ（launchd なら `/`、デスクトップなら
    /// バイナリのあるフォルダ）で動き、無人実行の書き込みできる範囲がそこまで広がるため。
    static func normalizeCwd(_ raw: String?, home: String = NSHomeDirectory(),
                             bridgeDirectory: String? = Bundle.main.executableURL?.deletingLastPathComponent().path) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var path = trimmed.isEmpty ? home : trimmed
        if path == "~" { path = home } else if path.hasPrefix("~/") { path = home + String(path.dropFirst(1)) }
        guard path.hasPrefix("/") else {
            throw cwdError("作業フォルダは / から始まるフルパスで指定してください（\(trimmed)）。")
        }
        path = ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw cwdError("作業フォルダが見つかりません（\(path)）。")
        }
        func inside(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        let systemRoots = ["/System", "/usr", "/bin", "/sbin", "/Library", "/Applications", "/private/etc", "/private/var/root", "/cores", "/dev", "/opt"]
        let bridgeRoot = bridgeDirectory.map { (($0 as NSString).standardizingPath as NSString).resolvingSymlinksInPath }
        if path == "/" || systemRoots.contains(where: inside)
            || path.contains(".app/") || path.hasSuffix(".app")
            || (bridgeRoot.map(inside) ?? false) {
            throw cwdError("このフォルダでは定期実行を動かせません（\(path)）。プロジェクトのフォルダを指定してください。")
        }
        return path
    }

    private static func cwdError(_ message: String) -> NSError {
        NSError(domain: "BridgeCron", code: 4, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Lifecycle

    func startIfNeeded() {
        guard !started else { return }
        started = true
        let loaded = Self.loadJobs(at: Self.jobsFile)
        jobs = loaded.jobs
        saveBlocked = loaded.saveBlocked
        try? FileManager.default.createDirectory(
            atPath: Self.outputRoot, withIntermediateDirectories: true
        )
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        WebSocketServer.wslog("[bridge-cron] started jobs=\(jobs.count)")
    }

    // MARK: CRUD (adapter から委譲される)

    func list(agentId: String) -> [CronJobSummary] {
        jobs.filter { $0.agentId == agentId }.map { summary(for: $0) }
    }

    func create(agentId: String, spec: CronCreateSpec) throws -> String {
        guard BridgeCronSchedule.parse(spec.schedule) != nil else {
            throw NSError(domain: "BridgeCron", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "unsupported schedule: \(spec.schedule)"
            ])
        }
        guard !spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "BridgeCron", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "prompt is required"
            ])
        }
        let cwd = try Self.normalizeCwd(spec.cwd)
        let id = Self.newJobId()
        let job = BridgeCronJob(
            id: id,
            agentId: agentId,
            name: (spec.name?.isEmpty == false ? spec.name! : "job-\(id)"),
            prompt: spec.prompt,
            schedule: spec.schedule.trimmingCharacters(in: .whitespacesAndNewlines),
            cwd: cwd,
            permissionMode: spec.permissionMode,
            deliver: spec.deliver ?? "local",
            enabled: true,
            createdAt: Date(),
            lastRunAt: nil,
            lastStatus: nil,
            repeatCount: spec.repeatCount,
            runsCompleted: 0
        )
        jobs.append(job)
        save()
        WebSocketServer.wslog("[bridge-cron] create id=\(id) agent=\(agentId) schedule='\(job.schedule)'")
        return id
    }

    func delete(agentId: String, jobId: String) throws {
        guard let idx = jobs.firstIndex(where: { $0.id == jobId && $0.agentId == agentId }) else {
            throw NSError(domain: "BridgeCron", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "job not found: \(jobId)"
            ])
        }
        jobs.remove(at: idx)
        save()
        WebSocketServer.wslog("[bridge-cron] delete id=\(jobId)")
    }

    func pause(agentId: String, jobId: String) throws {
        try setEnabled(false, agentId: agentId, jobId: jobId)
    }

    func resume(agentId: String, jobId: String) throws {
        try setEnabled(true, agentId: agentId, jobId: jobId)
    }

    private func setEnabled(_ enabled: Bool, agentId: String, jobId: String) throws {
        guard let idx = jobs.firstIndex(where: { $0.id == jobId && $0.agentId == agentId }) else {
            throw NSError(domain: "BridgeCron", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "job not found: \(jobId)"
            ])
        }
        jobs[idx].enabled = enabled
        if enabled {
            // 一時停止中に過ぎたスケジュールを再開直後に発火させない:
            // 次回が過去なら基準を「いま」に進める (run としては数えない)。
            if let due = nextFire(jobs[idx]), due <= Date() {
                jobs[idx].lastRunAt = Date()
            }
        }
        save()
        WebSocketServer.wslog("[bridge-cron] \(enabled ? "resume" : "pause") id=\(jobId)")
    }

    // MARK: Tick

    private func tick() async {
        let now = Date()
        for job in jobs where job.enabled && !runningIds.contains(job.id) {
            guard let due = nextFire(job), due <= now else { continue }
            runningIds.insert(job.id)
            SleepGuard.shared.setActive(true, owner: "cron")
            let jobId = job.id
            Task { [weak self] in
                await self?.executeRun(jobId: jobId)
            }
        }
    }

    /// 次回発火時刻。lastRunAt (未実行なら createdAt) を基準に算出するので、
    /// Mac のスリープ等で逃した分は復帰後に 1 回だけキャッチアップ発火される。
    private func nextFire(_ job: BridgeCronJob) -> Date? {
        guard let schedule = job.parsedSchedule else { return nil }
        let baseline = job.lastRunAt ?? job.createdAt
        guard let next = schedule.next(after: baseline) else { return nil }
        return next.addingTimeInterval(Self.jitter(jobId: job.id, schedule: schedule))
    }

    /// jobId から決定的に導出するジッター。interval の 1/10 か 90 秒の小さい方を上限とする。
    static func jitter(jobId: String, schedule: BridgeCronSchedule) -> TimeInterval {
        var hash: UInt64 = 14_695_981_039_346_656_037  // FNV-1a
        for byte in jobId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        let cap: TimeInterval
        switch schedule {
        case .interval(let s): cap = min(90, max(0, s / 10))
        case .cron: cap = 90
        }
        guard cap >= 1 else { return 0 }
        return TimeInterval(hash % UInt64(cap))
    }

    // MARK: Run execution

    private struct RunResult {
        var text: String = ""
        var sessionId: String?
        var errorText: String?
        /// 無人実行なので答えられず、その場で断った承認・質問（タイトル）。
        var declinedActions: [String] = []
    }

    /// 1 回分の本文と、バックグラウンドの作業を集める（executeRun の collector が使う）。
    /// 結果は最後の空でないターンの本文。done の後もバックグラウンドのサブエージェントか workflow が動いていれば
    /// （workflow_progress から数える）、終わった後の知らせのターンの done まで集め続ける。claude は stdin を開いたままだと
    /// 最初の result がバックグラウンドの作業を待たないので、最初の done で閉じると作業ごと止まり、起動の報告だけが
    /// 結果になる（docs/BACKGROUND_WORK_2026-10-21.md §1.1）。バックグラウンドのコマンドだけなら待たない（dev サーバーは終わらない）。
    struct TurnCollector {
        /// 結果の本文（最後の空でないターン）。
        private(set) var text = ""
        /// 今のターンの本文（done で区切る）。
        private var turnText = ""
        /// workflow_progress のカード（動いているサブエージェント・workflow を数える）。
        private var cards = WorkflowCardMirror()
        /// done の後、バックグラウンドの作業の終わり（知らせのターンの done）を待っている。
        private(set) var waitingForBackground = false
        /// 最後の done の後に、ターンの出力（本文・考え中・ツール）が届いた（知らせのターンが始まった）。
        private(set) var turnStarted = false
        /// 送った指示（job の prompt）のターンが終わった。知らせのターン（done の metadata.origin = "task-notification"）を
        /// 結果のターンに数えるのは、この後だけ。
        private(set) var ownTurnEnded = false

        /// バックグラウンドのサブエージェントか workflow が動いている。
        var backgroundRunning: Bool { cards.counts.agentsOrWorkflows }

        /// 出来事を 1 つ受ける。集め終わった（バックグラウンドの作業が残っていない done）なら true。
        mutating func ingest(_ event: SessionEvent) -> Bool {
            switch event.type {
            case .assistantDelta:
                turnStarted = true
                turnText += event.content ?? ""
            case .activity, .toolStart:
                turnStarted = true
            case .workflowProgress:
                cards.apply(event.content)
            case .done:
                // 送った指示のターンが終わる前に閉じた知らせのターン（指示が CLI の待ち行列に残っている間に、CLI が自分から
                // 始めたもの）は、指示の返事ではない。その本文を捨て、指示のターンの done を待ち続ける。
                if event.metadata?["origin"] == "task-notification", !ownTurnEnded {
                    turnText = ""
                    turnStarted = false
                    return false
                }
                ownTurnEnded = true
                closeTurn()
                turnStarted = false
                waitingForBackground = backgroundRunning
                return !waitingForBackground
            default:
                break
            }
            return false
        }

        /// stream が終わった（close・プロセス死・打ち切り）。途中のターンの本文も結果に入れる。
        mutating func finishStream() { closeTurn() }

        private mutating func closeTurn() {
            if !turnText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = turnText }
            turnText = ""
        }
    }

    /// 無人実行で届いた承認・質問への答え。答える人が居ないので、待たずにすぐ断る
    /// （待つと runTimeout の 30 分まで止まる）。選択肢に「断る」系の値があればそれを、
    /// 無ければ（質問・自由記述）エージェントへの説明文を返す。各 adapter は選択肢に無い値を拒否として扱う。
    static func unattendedDecision(metadata: [String: String]) -> String {
        let count = Int(metadata["option_count"] ?? "") ?? 0
        let values = (0..<count).compactMap { metadata["option_\($0)_value"] }
        let denyValues = ["deny", "decline", "reject", "reject_once", "reject_always", "denied", "cancel", "abort"]
        if metadata["kind"] != "userInput", let deny = denyValues.first(where: values.contains) {
            return deny
        }
        return unattendedNotice
    }

    static let unattendedNotice =
        "This is a scheduled run and nobody is available to answer. Do not wait for approval or retry this; "
        + "finish what you can without it and say clearly what still needs the user's approval."

    private func executeRun(jobId: String) async {
        defer {
            runningIds.remove(jobId)
            if runningIds.isEmpty {
                SleepGuard.shared.setActive(false, owner: "cron")
            }
        }
        guard let job = jobs.first(where: { $0.id == jobId }) else { return }
        WebSocketServer.wslog("[bridge-cron] fire id=\(job.id) agent=\(job.agentId) name=\(job.name)")

        guard let adapter = await AgentRegistry.shared.adapter(for: job.agentId) else {
            finishRun(jobId: jobId, status: "error", result: RunResult(errorText: "agent adapter not found"))
            return
        }
        // 前の版で作ったジョブ（作業フォルダが空欄のまま保存されている）もここで正規化する。
        let cwd: String
        do {
            cwd = try Self.normalizeCwd(job.cwd)
        } catch {
            finishRun(jobId: jobId, status: "error", result: RunResult(errorText: error.localizedDescription))
            return
        }

        let session = await adapter.openSession(
            sessionId: nil,
            cwd: cwd,
            options: SessionOptions(permissionMode: job.permissionMode, unattended: true)
        )

        // events の購読を send より先に開始する。スポーン失敗等で done が来ない経路が
        // あるため、collector は done で抜けるか stream の finish (close) で抜ける。
        // done の後もバックグラウンドのサブエージェントか workflow が動いていれば、終わった後の知らせのターンの done まで
        // 抜けない（runTimeout の範囲で。TurnCollector）。結果はその最後のターンの本文。
        // error を受けたことは errorSignals で後段の猶予付き close に知らせる。
        let (errorSignals, errorSink) = AsyncStream.makeStream(of: Void.self)
        let collector = Task { () -> RunResult in
            defer { errorSink.finish() }
            var result = RunResult()
            var turns = TurnCollector()
            // 待っていたバックグラウンドの作業が終わったのに、知らせのターンが始まらないときの打ち切り
            // （close で stream が finish し、ここを抜ける）。
            var settle: Task<Void, Never>?
            defer { settle?.cancel() }
            do {
                for try await event in session.events {
                    switch event.type {
                    case .sessionStarted:
                        if let sid = event.sessionId { result.sessionId = sid }
                    case .error:
                        result.errorText = event.content ?? "unknown error"
                        errorSink.yield(())
                    case .actionRequest:
                        // 無人実行の設定でも承認・質問が来た経路（adapter の取りこぼし）。待たずに断る。
                        let meta = event.metadata ?? [:]
                        if let requestId = meta["requestId"] ?? event.messageId {
                            result.declinedActions.append(meta["title"] ?? event.content ?? requestId)
                            await session.respondToAction(
                                requestId: requestId, decision: Self.unattendedDecision(metadata: meta), answers: [:])
                        }
                    default:
                        break
                    }
                    if turns.ingest(event) {
                        result.text = turns.text
                        return result
                    }
                    if event.type == .done, turns.waitingForBackground {
                        WebSocketServer.wslog("[bridge-cron] id=\(jobId) waiting for background work")
                    }
                    if turns.waitingForBackground, !turns.backgroundRunning, !turns.turnStarted {
                        if settle == nil {
                            settle = Task {
                                try? await Task.sleep(nanoseconds: UInt64(Self.backgroundSettleGrace * 1_000_000_000))
                                guard !Task.isCancelled else { return }
                                await session.close()
                            }
                        }
                    } else {
                        settle?.cancel()
                        settle = nil
                    }
                }
            } catch {
                // stream 終了 (close / プロセス死)
            }
            turns.finishStream()
            result.text = turns.text
            return result
        }

        let sender = Task {
            await session.send(job.prompt, skills: [], attachments: [])
        }

        // タイムアウト監視: 超過したら interrupt → CLI プロセスグループが SIGTERM され
        // (app-server は turn/interrupt)、途中までの出力で done が来る。interrupt が効かず
        // send / done が戻らない異常経路でもハングしないよう、interrupt 後に有限のグレース期間を
        // 置いて強制 close する。
        // この強制 close は sender.value など「ハングしうる await」に依存させない。
        let timeout = runTimeout
        let forceCloseGrace: TimeInterval = 10
        let deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.markTimedOut(jobId: jobId)
            await session.interrupt()
            // interrupt が効かず send が戻らない場合に備え、グレース期間後に強制 close。
            // close で stream が finish し、collector / sender が確実に解放される。
            try? await Task.sleep(nanoseconds: UInt64(forceCloseGrace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await session.close()
        }

        // send の戻りはターンの完了を意味しない。exec 系 (claude / codex exec / HeadlessCli) は
        // ターン終了まで戻らないが、Codex app-server (permissionMode 未指定時の既定) は
        // turn/start の応答で戻り、ターン本体は後から turn/completed → done で終わる。
        // send 直後に close するとターン開始直後に切断され、出力なしの "ok" が記録されるため、
        // send の完了に加えて collector の終了 (done か stream の finish) を待ってから close する。
        // この間も deadline は有効なままにし、done が来ない経路は timeout (interrupt → 強制 close) で打ち切る。
        await sender.value
        // error だけ出して done を出さない経路 (HeadlessCli の失敗など) で
        // deadline まで待たないよう、send 完了後に error を受けていれば短い猶予の後に close して
        // stream を finish させる (app-server の error は猶予内に turn/completed → done が来る)。
        // AsyncThrowingStream は finish 前に yield 済みのイベントを先に配るので出力は失われない。
        let errorDoneGrace: TimeInterval = 10
        let errorCloser = Task {
            var signals = errorSignals.makeAsyncIterator()
            guard await signals.next() != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(errorDoneGrace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await session.close()
        }
        let result = await collector.value
        errorCloser.cancel()
        deadline.cancel()
        // 正常完了時もここで close する (常駐の claude / app-server 接続の後始末)。
        await session.close()

        let status: String
        if timedOutIds.remove(jobId) != nil {
            status = "timeout"
        } else if result.errorText != nil {
            status = "error"
        } else {
            status = "ok"
        }
        finishRun(jobId: jobId, status: status, result: result)
    }

    private func markTimedOut(jobId: String) {
        timedOutIds.insert(jobId)
        WebSocketServer.wslog("[bridge-cron] timeout id=\(jobId) → interrupt")
    }

    private func finishRun(jobId: String, status: String, result: RunResult) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[idx].lastRunAt = Date()
        jobs[idx].lastStatus = status
        jobs[idx].runsCompleted += 1
        if let sid = result.sessionId, !sid.isEmpty { jobs[idx].lastSessionId = sid }
        if let cap = jobs[idx].repeatCount, jobs[idx].runsCompleted >= cap {
            jobs[idx].enabled = false
            WebSocketServer.wslog("[bridge-cron] id=\(jobId) reached repeat cap \(cap) → disabled")
        }
        save()
        writeOutput(job: jobs[idx], status: status, result: result)
        WebSocketServer.wslog("[bridge-cron] done id=\(jobId) status=\(status) chars=\(result.text.count)")
    }

    /// 結果を `<outputRoot>/<jobId>/<ts>.md` に書く。CronOutputHub がこのファイルを検知して
    /// WS broadcast + push する (hermes cron と同じ受信箱フロー)。
    private func writeOutput(job: BridgeCronJob, status: String, result: RunResult) {
        let dir = Self.outputRoot + "/" + job.id
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ts = formatter.string(from: Date())

        var body = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = result.errorText {
            body += (body.isEmpty ? "" : "\n\n") + "[error] \(err)"
        }
        if !result.declinedActions.isEmpty {
            let list = result.declinedActions.map { "- \($0)" }.joined(separator: "\n")
            body += (body.isEmpty ? "" : "\n\n")
                + "[承認が必要な操作] 定期実行では答える人がいないため、次の操作は断りました。"
                + "必要なら、この定期実行の権限を変えてください。\n\(list)"
        }
        if body.isEmpty {
            body = "(出力なし)"
        }
        var header = "# \(job.name)\nagent: \(job.agentId)\nstatus: \(status)\n"
        if let sid = result.sessionId, !sid.isEmpty {
            header += "session: \(sid)\n"
        }
        let content = header + "---\n" + body + "\n"
        try? content.data(using: .utf8)?.write(
            to: URL(fileURLWithPath: dir + "/" + ts + ".md"), options: .atomic
        )
    }

    // MARK: Summary mapping

    private func summary(for job: BridgeCronJob) -> CronJobSummary {
        let state: String
        if runningIds.contains(job.id) {
            state = "running"
        } else if !job.enabled {
            state = "paused"
        } else {
            state = "scheduled"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return CronJobSummary(
            id: job.id,
            name: job.name,
            prompt: job.prompt,
            scheduleDisplay: job.schedule,
            deliver: job.deliver,
            enabled: job.enabled,
            state: state,
            nextRunAt: job.enabled ? nextFire(job).map { formatter.string(from: $0) } : nil,
            lastRunAt: job.lastRunAt.map { formatter.string(from: $0) },
            lastStatus: job.lastStatus,
            lastSessionId: job.lastSessionId ?? Self.latestOutputSessionId(jobId: job.id)
        )
    }

    /// いちばん新しい出力ファイルの `session:` 行（lastSessionId を持たない前の版のジョブ用）。
    static func latestOutputSessionId(jobId: String, root: String = outputRoot) -> String? {
        let dir = root + "/" + jobId
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir),
              let latest = files.filter({ $0.hasSuffix(".md") }).max(),
              let text = try? String(contentsOfFile: dir + "/" + latest, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").prefix(8) where line.hasPrefix("session: ") {
            let sid = line.dropFirst("session: ".count).trimmingCharacters(in: .whitespaces)
            return sid.isEmpty ? nil : sid
        }
        return nil
    }

    // MARK: Persistence

    struct LoadResult {
        var jobs: [BridgeCronJob]
        /// 読めない部分があったときの退避先。nil = 退避していない（全部読めた / ファイルが無い）。
        var backupPath: String?
        /// 読めなかったのに退避もできなかった。保存すると元のファイルを壊すので止める。
        var saveBlocked: Bool
    }

    /// 1 件ずつ読む（1 件壊れていても残りは使う）。読めない部分があれば、上書きで失わないよう
    /// 元のファイルを `jobs.json.broken-<日時>` へ写してから使う。写せなければ保存を止める。
    static func loadJobs(at path: String) -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return LoadResult(jobs: [], backupPath: nil, saveBlocked: false) }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            WebSocketServer.wslog("[bridge-cron] jobs.json read failed: \(error.localizedDescription)")
            return backedUp(path: path, jobs: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let elements = try? decoder.decode([LenientJob].self, from: data) else {
            WebSocketServer.wslog("[bridge-cron] jobs.json is not a job list")
            return backedUp(path: path, jobs: [])
        }
        let jobs = elements.compactMap(\.job)
        guard jobs.count == elements.count else {
            WebSocketServer.wslog("[bridge-cron] jobs.json: \(elements.count - jobs.count) of \(elements.count) jobs unreadable")
            return backedUp(path: path, jobs: jobs)
        }
        return LoadResult(jobs: jobs, backupPath: nil, saveBlocked: false)
    }

    /// 配列の 1 要素。デコードに失敗しても配列全体を失敗させない。
    private struct LenientJob: Decodable {
        let job: BridgeCronJob?
        init(from decoder: Decoder) throws {
            job = try? BridgeCronJob(from: decoder)
        }
    }

    private static func backedUp(path: String, jobs: [BridgeCronJob]) -> LoadResult {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = path + ".broken-" + formatter.string(from: Date())
        do {
            try FileManager.default.copyItem(atPath: path, toPath: backup)
            WebSocketServer.wslog("[bridge-cron] backed up unreadable jobs.json → \(backup)")
            return LoadResult(jobs: jobs, backupPath: backup, saveBlocked: false)
        } catch {
            WebSocketServer.wslog("[bridge-cron] could not back up jobs.json (\(error.localizedDescription)) → saving disabled")
            return LoadResult(jobs: jobs, backupPath: nil, saveBlocked: true)
        }
    }

    private func save() {
        guard !saveBlocked else {
            WebSocketServer.wslog("[bridge-cron] save skipped: jobs.json could not be read or backed up")
            return
        }
        let dir = (Self.jobsFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(jobs) {
            try? data.write(to: URL(fileURLWithPath: Self.jobsFile), options: .atomic)
        }
    }

    private static func newJobId() -> String {
        let chars = "0123456789abcdef"
        return String((0..<8).map { _ in chars.randomElement()! })
    }
}
