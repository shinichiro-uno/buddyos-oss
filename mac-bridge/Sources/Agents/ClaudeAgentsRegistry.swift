import Foundation
import Darwin

// ---------------------------------------------------------------------------
// claude --bg のセッションの台帳の読み取り（BACKGROUND_CONTROL §7.1〜§7.3、§7.5 の読み取りの部分）。
// ファイルを読んで行を作るだけの純粋な関数。見張り・差分・配信・操作は ClaudeBackgroundJobs。
//   sessions: ~/.claude/sessions/<pid>.json    生きているプロセス（kind が bg のものがワーカー）
//   jobs:     ~/.claude/jobs/<8桁>/state.json   ジョブの記録
//   roster:   ~/.claude/daemon/roster.json     いまのワーカーの一覧（workers のキーだけ読む）
// 状態の導出は CLI の printAgentsJson と同じにして、テストで固定する。
// ---------------------------------------------------------------------------

/// アプリに出す状態（§7.2）。
enum BgState: String, Codable, Sendable {
    case working, blocked, done, failed, stopped

    var isFinished: Bool { self == .done || self == .failed || self == .stopped }
}

/// 一覧の 1 行（§7.7 の bg_session。content の JSON）。pid・respawnFlags・providerEnv・roster の値は入れない。
struct BgRow: Codable, Equatable, Sendable {
    var id: String
    var sessionId: String
    var title: String
    var cwd: String
    var state: BgState
    var live: Bool
    var needs: String?
    var detail: String?
    var shells: Int
    var createdAtMs: Int64

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// 消えたときの変化（§7.7）。
    static func removedJSON(id: String, sessionId: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct Removed: Encodable { let id: String; let sessionId: String; let removed: Bool }
        return (try? encoder.encode(Removed(id: id, sessionId: sessionId, removed: true)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// 台帳の 1 件。行のほかに、見張り・知らせ・会話の振り分けが使う項目を持つ。
struct BgEntry: Sendable, Equatable {
    var row: BgRow
    /// 繰り返しの待ち（一覧には出すが Live Activity には数えない。§7.2 の 4）。
    var recurringWait = false
    /// 生きているワーカーの生の status（busy / shell / idle / waiting など）。生きていなければ nil。
    var workerStatus: String?
    /// 受け箱（/tmp/cc-socks/<pid>.sock）。ワーカーが生きているときだけ。
    var inbox: String?
    /// 生きているワーカーの pid（終了の見張りに使う。アプリには渡さない）。
    var pid: Int32?
    /// 最初の作業が終わった（state.json に firstTerminalAt がある）。
    var firstTerminal = false
    /// 終わった時刻（lastTerminalAt、無ければ updatedAt）。§7.3 の 24 時間に使う。
    var endedAtMs: Int64?
    /// state.json の linkScanPath（transcript）。
    var linkScanPath: String?
}

/// sessions/<pid>.json の 1 件（読み取れた項目だけ）。
struct BgSessionRecord: Sendable, Equatable {
    var pid: Int32
    var sessionId: String?
    var kind: String?
    var jobId: String?
    var parkedJobId: String?
    var name: String?
    var status: String?
    var cwd: String?
    var version: String?
    var startedAt: Double
    var procStart: String?
    var inbox: String?
    /// pid が生きていて、始まった時刻が procStart と合う。
    var alive = false
    /// どこから起こしたか（cli = ターミナル、sdk-cli = ほかのアプリ）。
    var entrypoint: String?
}

/// jobs/<id>/state.json の 1 件（読み取れた項目だけ。respawnFlags と providerEnv は読み捨てる）。
struct BgJobRecord: Sendable, Equatable {
    var state: String?
    var tempo: String?
    var detail: String?
    var needs: String?
    var intent: String?
    var name: String?
    var sessionId: String?
    var cwd: String?
    var cliVersion: String?
    var createdAtMs: Int64?
    var updatedAtMs: Int64?
    var firstTerminalAtMs: Int64?
    var lastTerminalAtMs: Int64?
    var linkScanPath: String?
    /// state.json の template と respawnFlags の数（値は読み捨てる）。孤児の読み替えで exec の扱いを分けるのに使う。
    var template: String?
    var respawnFlagCount: Int?
    /// いま動いている裏のコマンドの数（§7.7）。
    var shells = 0
    /// 繰り返し（§7.2）。
    var recurring = false
    var keptBy = false
}

/// `claude agents --json --all` の kind が background の 1 行。
struct BgCliRow: Sendable, Equatable {
    var id: String
    var sessionId: String
    var cwd: String
    var name: String?
    /// 生きているワーカーの pid（無ければ止まっている）。
    var pid: Int32?
    var status: String?
    var state: String?
    var startedAt: Int64?
}

/// ディスクから読んだ台帳の全部。
struct BgLedgerSnapshot: Sendable {
    var sessions: [BgSessionRecord] = []
    var jobs: [String: BgJobRecord] = [:]
    /// roster の workers のキー。
    var roster: Set<String> = []
    /// sessions の version と state.json の cliVersion（新しい値が出たら CLI と突き合わせ直す）。
    var versions: Set<String> {
        var out = Set<String>()
        for s in sessions { if let v = s.version, !v.isEmpty { out.insert(v) } }
        for j in jobs.values { if let v = j.cliVersion, !v.isEmpty { out.insert(v) } }
        return out
    }
}

enum ClaudeAgentsRegistry {
    static let idPattern = "^[0-9a-f]{8}$"
    static let recentMs: Int64 = 24 * 3600 * 1000
    static let maxRows = 50

    static func isJobId(_ s: String) -> Bool {
        s.range(of: idPattern, options: .regularExpression) != nil
    }

    // MARK: - 寛容な読み方（§7.1 の 1）

    /// 先頭の `{` に対応する `}` までを、文字列の中の括弧を数えずに切り出して読む。後ろのごみは捨てる。
    static func parseTolerantObject(_ data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < bytes.count {
            let c = bytes[i]
            if inString {
                if escaped { escaped = false }
                else if c == UInt8(ascii: "\\") { escaped = true }
                else if c == UInt8(ascii: "\"") { inString = false }
            } else if c == UInt8(ascii: "\"") {
                inString = true
            } else if c == UInt8(ascii: "{") {
                depth += 1
            } else if c == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    let slice = Data(bytes[start...i])
                    return (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any]
                }
            }
            i += 1
        }
        return nil
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// Double を範囲の中のときだけ整数にする（範囲外・巨大な値で落ちないため）。
    private static func int64(_ d: Double?) -> Int64? {
        guard let d else { return nil }
        return Int64(exactly: d.rounded())
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - 生きているか（§7.1 の 2）

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// UTC・C ロケールの `%a %b %e %H:%M:%S %Y`（日が 1 桁なら前を空白で埋める）。
    static func formatProcStart(seconds: Int) -> String {
        var t = time_t(seconds)
        var parts = tm()
        gmtime_r(&t, &parts)
        func two(_ n: Int32) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let day = parts.tm_mday < 10 ? " \(parts.tm_mday)" : "\(parts.tm_mday)"
        return "\(dayNames[Int(parts.tm_wday)]) \(monthNames[Int(parts.tm_mon)]) \(day) "
            + "\(two(parts.tm_hour)):\(two(parts.tm_min)):\(two(parts.tm_sec)) \(Int(parts.tm_year) + 1900)"
    }

    /// proc_pidinfo の pbi_start_tvsec から作った始まった時刻。読めなければ nil。
    /// 1 回の syscall で軽いので覚えない（pid が使い回されても古い時刻を返さない）。
    static func processStartString(pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return formatProcStart(seconds: Int(info.pbi_start_tvsec))
    }

    /// 空白を 1 つに詰める。
    static func collapsingSpaces(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// `kill(pid, 0) == 0`（EPERM は生きていない扱い）で、procStart があれば始まった時刻と一致すること。
    /// ps は起動しない。始まった時刻を読めないときは kill の結果だけで決める。
    static func isProcessAlive(pid: Int32, procStart: String?) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 else { return false }
        guard let procStart, !procStart.isEmpty, let actual = processStartString(pid: pid) else { return true }
        return collapsingSpaces(procStart) == collapsingSpaces(actual)
    }

    // MARK: - sessions / jobs / roster の読み取り

    /// 名前が `^\d+\.json$` のものだけ（`*.key` は開かない）。
    static func isSessionFileName(_ name: String) -> Bool {
        name.range(of: "^\\d+\\.json$", options: .regularExpression) != nil
    }

    static func parseSession(_ data: Data) -> BgSessionRecord? {
        guard let o = parseTolerantObject(data), let pid = number(o["pid"]), pid > 0, pid < Double(Int32.max) else { return nil }
        return BgSessionRecord(
            pid: Int32(pid),
            sessionId: string(o["sessionId"]),
            kind: string(o["kind"]),
            jobId: nonEmpty(string(o["jobId"])),
            parkedJobId: nonEmpty(string(o["parkedJobId"])),
            name: string(o["name"]),
            status: string(o["status"]),
            cwd: string(o["cwd"]),
            version: string(o["version"]),
            startedAt: int64(number(o["startedAt"])).map { Double($0) } ?? 0,
            procStart: string(o["procStart"]),
            inbox: nonEmpty(string(o["messagingSocketPath"])),
            entrypoint: nonEmpty(string(o["entrypoint"]))
        )
    }

    static func readSessions(dir: URL, isAlive: (Int32, String?) -> Bool = isProcessAlive) -> [BgSessionRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [BgSessionRecord] = []
        for name in names.sorted() where isSessionFileName(name) {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)), var record = parseSession(data) else { continue }
            record.alive = isAlive(record.pid, record.procStart)
            out.append(record)
        }
        return out
    }

    private static func isoMs(_ v: Any?) -> Int64? {
        if let d = number(v) { return int64(d) }
        guard let s = v as? String, !s.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: s) ?? plain.date(from: s) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// `fan` があれば kind が shell の数。無ければ `inFlight.kinds` に local_bash があるとき `inFlight.tasks`。
    static func countShells(_ o: [String: Any]) -> Int {
        if let fan = o["fan"] as? [Any] {
            return fan.filter { ($0 as? [String: Any])?["kind"] as? String == "shell" }.count
        }
        let inFlight = o["inFlight"] as? [String: Any] ?? [:]
        let kinds = inFlight["kinds"] as? [Any] ?? []
        if kinds.contains(where: { $0 as? String == "local_bash" }) {
            return max(0, number(inFlight["tasks"]).flatMap { Int(exactly: $0.rounded()) } ?? 0)
        }
        return 0
    }

    /// 繰り返し: routine がある、selfWake が true、inFlight.kinds に session_cron、intent か initialPrompt が /loop で始まる。
    static func isRecurring(_ o: [String: Any]) -> Bool {
        if present(o["routine"]) { return true }
        if let n = o["selfWake"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue { return true }
        let kinds = (o["inFlight"] as? [String: Any])?["kinds"] as? [Any] ?? []
        if kinds.contains(where: { $0 as? String == "session_cron" }) { return true }
        return ["intent", "initialPrompt"].contains { key in
            (o[key] as? String)?.drop(while: { $0.isWhitespace }).hasPrefix("/loop") == true
        }
    }

    static func parseJob(_ data: Data) -> BgJobRecord? {
        guard let o = parseTolerantObject(data) else { return nil }
        return BgJobRecord(
            state: string(o["state"]),
            tempo: string(o["tempo"]),
            detail: string(o["detail"]),
            needs: string(o["needs"]),
            intent: string(o["intent"]),
            name: string(o["name"]),
            sessionId: string(o["sessionId"]),
            cwd: string(o["cwd"]),
            cliVersion: string(o["cliVersion"]),
            createdAtMs: isoMs(o["createdAt"]),
            updatedAtMs: isoMs(o["updatedAt"]),
            firstTerminalAtMs: isoMs(o["firstTerminalAt"]),
            lastTerminalAtMs: isoMs(o["lastTerminalAt"]),
            linkScanPath: nonEmpty(string(o["linkScanPath"])),
            template: string(o["template"]),
            respawnFlagCount: (o["respawnFlags"] as? [Any])?.count,
            shells: countShells(o),
            recurring: isRecurring(o),
            keptBy: present(o["keptBy"])
        )
    }

    private static func present(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        if let s = v as? String { return !s.isEmpty }
        return true
    }

    /// jobs の直下で名前が `^[0-9a-f]{8}$` のディレクトリの state.json だけを読む（pins.json などは見ない）。
    static func readJobs(dir: URL) -> [String: BgJobRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [:] }
        var out: [String: BgJobRecord] = [:]
        for name in names where isJobId(name) {
            let file = dir.appendingPathComponent(name).appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: file), let job = parseJob(data) else { continue }
            out[name] = job
        }
        return out
    }

    /// roster の workers のキーだけ。ほかの値は読まない・記録しない。
    /// ファイルがあるのに読めないとき（書きかけなど）は、前に読めた分を使い続ける。ファイルが無いときだけ空。
    static func readRosterShorts(file: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let o = parseTolerantObject(data), let workers = o["workers"] as? [String: Any] else {
            rosterLock.lock(); defer { rosterLock.unlock() }
            return lastRoster[file.path] ?? []
        }
        let keys = Set(workers.keys)
        rosterLock.lock(); lastRoster[file.path] = keys; rosterLock.unlock()
        return keys
    }

    private static let rosterLock = NSLock()
    nonisolated(unsafe) private static var lastRoster: [String: Set<String>] = [:]

    static func claudeDir(home: URL) -> URL { home.appendingPathComponent(".claude", isDirectory: true) }

    static func readSnapshot(home: URL, isAlive: (Int32, String?) -> Bool = isProcessAlive) -> BgLedgerSnapshot {
        let dir = claudeDir(home: home)
        return BgLedgerSnapshot(
            sessions: readSessions(dir: dir.appendingPathComponent("sessions"), isAlive: isAlive),
            jobs: readJobs(dir: dir.appendingPathComponent("jobs")),
            roster: readRosterShorts(file: dir.appendingPathComponent("daemon/roster.json"))
        )
    }

    /// sessionId に対応する claude 本体の pid と受け箱。生きているものだけ。同じ session を resume した別プロセスがあれば新しい方。
    /// 壊れたファイルでも引ける（ClaudeTerminalRegistry が使う）。
    static func lookupProcess(sessionId: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              isAlive: (Int32, String?) -> Bool = isProcessAlive) -> (pid: Int32, inboxSocket: String?)? {
        let sessions = readSessions(dir: claudeDir(home: home).appendingPathComponent("sessions"), isAlive: isAlive)
        var best: BgSessionRecord?
        for s in sessions where s.sessionId == sessionId && s.alive {
            if let b = best, b.startedAt >= s.startedAt { continue }
            best = s
        }
        return best.map { (pid: $0.pid, inboxSocket: $0.inbox) }
    }

    /// 同じ sessionId を握っている生きている sessions の行（startedAt の新しいもの。§7.8 の 3）。
    /// excluding は数えない pid（ワーカー自身と、Bridge 自身の `-p`）。
    static func holder(sessionId: String, excluding: Set<Int32> = [],
                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       isAlive: (Int32, String?) -> Bool = isProcessAlive) -> BgSessionRecord? {
        let sessions = readSessions(dir: claudeDir(home: home).appendingPathComponent("sessions"), isAlive: isAlive)
        var best: BgSessionRecord?
        for s in sessions where s.sessionId == sessionId && s.alive && !excluding.contains(s.pid) {
            if let b = best, b.startedAt >= s.startedAt { continue }
            best = s
        }
        return best
    }

    /// pid の行を 1 件だけ読む（ClaudeBackgroundSession が握っているプロセスの status を見る）。
    static func readSession(home: URL, pid: Int32) -> BgSessionRecord? {
        let file = claudeDir(home: home).appendingPathComponent("sessions/\(pid).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return parseSession(data)
    }

    // MARK: - 状態の導出（§7.2）

    static func isFinished(state: String?, tempo: String?) -> Bool {
        guard let state, ["done", "failed", "stopped"].contains(state) else { return false }
        return tempo != "active"
    }

    static func isBusy(_ status: String?) -> Bool { status == "busy" || status == "shell" }

    struct Derived: Equatable {
        var state: BgState
        var recurringWait: Bool
    }

    /// shorts = roster のキー ∪ 生きている bg の jobId。
    static func derive(id: String, job: BgJobRecord, workerStatus: String?, shorts: Set<String>, nowMs: Int64) -> Derived {
        var state = job.state
        var tempo = job.tempo
        // 1. 孤児の読み替え
        let kept = job.keptBy && (job.intent ?? "") == "" && job.needs == "send a prompt to start" && tempo == "blocked"
        // createdAt が無い・読めないものは 0 とみなす（CLI と同じ）。
        let created = job.createdAtMs ?? 0
        let execNoResp = job.template == "exec" && (job.respawnFlagCount ?? 0) == 0
        if !isFinished(state: state, tempo: tempo), !shorts.contains(id),
           nowMs - created >= 5000, !kept {
            if state == "blocked", !execNoResp {
                tempo = "blocked"
            } else {
                state = "failed"
                tempo = "idle"
            }
        }
        let busy = isBusy(workerStatus)
        let recurringDone = job.recurring && state == "done"
        let recurringWait = recurringDone && tempo != "active" && !busy
        // 2. アプリに出す state
        let result: BgState
        if busy {
            result = .working
        } else if isFinished(state: state, tempo: tempo), !recurringDone, let s = state.flatMap(BgState.init(rawValue:)) {
            result = s
        } else if tempo == "blocked" || workerStatus == "waiting" {
            result = .blocked
        } else {
            result = .working
        }
        return Derived(state: result, recurringWait: recurringWait)
    }

    private static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n)) }

    private static func title(_ candidates: [String?]) -> String {
        for c in candidates {
            let t = (c ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return clip(t, 80) }
        }
        return ""
    }

    private static func firstLine(_ s: String?) -> String? {
        s?.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init)
    }

    private static func makeEntry(id: String, sessionId: String, cwd: String, state: BgState, recurringWait: Bool,
                                  live: Bool, workerStatus: String?, inbox: String?, pid: Int32?,
                                  job: BgJobRecord?, title: String, createdAtMs: Int64) -> BgEntry {
        var row = BgRow(id: id, sessionId: sessionId, title: title, cwd: cwd, state: state, live: live,
                        needs: nil, detail: nil, shells: live ? (job?.shells ?? 0) : 0, createdAtMs: createdAtMs)
        if state == .blocked, let needs = job?.needs, !needs.isEmpty { row.needs = clip(needs, 400) }
        if state == .failed, let detail = job?.detail, !detail.isEmpty { row.detail = clip(detail, 200) }
        return BgEntry(row: row, recurringWait: recurringWait, workerStatus: live ? workerStatus : nil,
                       inbox: live ? inbox : nil, pid: live ? pid : nil, firstTerminal: job?.firstTerminalAtMs != nil,
                       endedAtMs: job.flatMap { $0.lastTerminalAtMs ?? $0.updatedAtMs }, linkScanPath: job?.linkScanPath)
    }

    /// 台帳（sessions / jobs / roster）から全ジョブの行を作る（§7.3 の絞り込みの前）。
    static func ledgerEntries(_ snapshot: BgLedgerSnapshot, nowMs: Int64, buddyTitle: (String) -> String?) -> [BgEntry] {
        // interactive の行・jobId の無い bg・parkedJobId のある行は入れない。
        var liveByJob: [String: BgSessionRecord] = [:]
        for s in snapshot.sessions where s.alive && s.kind == "bg" && s.jobId != nil && s.parkedJobId == nil {
            if let id = s.jobId, let prev = liveByJob[id], prev.startedAt >= s.startedAt { continue }
            liveByJob[s.jobId!] = s
        }
        let shorts = snapshot.roster.union(liveByJob.keys)
        var out: [BgEntry] = []
        for (id, job) in snapshot.jobs {
            let live = liveByJob[id]
            guard let sessionId = nonEmpty(job.sessionId) ?? nonEmpty(live?.sessionId) else { continue }
            let derived = derive(id: id, job: job, workerStatus: live?.status, shorts: shorts, nowMs: nowMs)
            out.append(makeEntry(
                id: id, sessionId: sessionId, cwd: job.cwd ?? live?.cwd ?? "", state: derived.state,
                recurringWait: derived.recurringWait, live: live != nil, workerStatus: live?.status, inbox: live?.inbox, pid: live?.pid,
                job: job,
                title: title([buddyTitle(sessionId), live?.name, job.name, firstLine(job.intent)]),
                createdAtMs: job.createdAtMs ?? int64(live?.startedAt) ?? 0))
        }
        return out
    }

    // MARK: - CLI 方式（§7.5）

    /// `claude agents --json --all` の標準出力から kind が background の行を取り出す。JSON の配列でなければ nil（失敗として扱う）。
    static func parseAgentsJSON(_ stdout: String) -> [BgCliRow]? {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var value: Any?
        if let data = text.data(using: .utf8) { value = try? JSONSerialization.jsonObject(with: data) }
        if value == nil, let from = text.firstIndex(of: "["), let to = text.lastIndex(of: "]"), from < to {
            value = text[from...to].data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
        guard let array = value as? [Any] else { return nil }
        var rows: [BgCliRow] = []
        for item in array {
            guard let o = item as? [String: Any], o["kind"] as? String == "background",
                  let sessionId = string(o["sessionId"]) else { continue }
            // id の無い行（jobId の無い bg のワーカー）は捨てる。sessionId から偽の id は作らない。
            guard let id = string(o["id"]), isJobId(id) else { continue }
            rows.append(BgCliRow(id: id, sessionId: sessionId, cwd: string(o["cwd"]) ?? "", name: string(o["name"]),
                                 pid: number(o["pid"]).flatMap { Int32(exactly: $0.rounded()) }, status: string(o["status"]),
                                 state: string(o["state"]), startedAt: int64(number(o["startedAt"]))))
        }
        return rows
    }

    /// CLI の行に、読めた分の sessions / state.json を足して 1 件を作る。読めなかった項目は無しのまま。
    /// 生の status が読めないときは、CLI の status が busy で state.json の tempo が active のときだけ busy とみなす。
    static func cliEntry(_ cli: BgCliRow, job: BgJobRecord?, session: BgSessionRecord?, nowMs: Int64,
                         buddyTitle: (String) -> String?) -> BgEntry {
        let live = cli.pid != nil
        let cliBusy = cli.status == "busy" && job?.tempo == "active"
        let workerStatus: String? = live ? (session?.status ?? (cliBusy ? "busy" : (cli.status == "busy" ? "unknown" : cli.status))) : nil
        var state = cli.state.flatMap(BgState.init(rawValue:)) ?? .working
        var recurringWait = false
        if cli.state.flatMap(BgState.init(rawValue:)) == nil, let job {
            let derived = derive(id: cli.id, job: job, workerStatus: workerStatus, shorts: live ? [cli.id] : [], nowMs: nowMs)
            state = derived.state
            recurringWait = derived.recurringWait
        }
        if let job, job.recurring, job.state == "done", job.tempo != "active", !isBusy(workerStatus),
           state != .failed, state != .stopped {
            recurringWait = true
        }
        return makeEntry(
            id: cli.id, sessionId: cli.sessionId, cwd: cli.cwd, state: state, recurringWait: recurringWait,
            live: live, workerStatus: workerStatus, inbox: session?.inbox, pid: cli.pid, job: job,
            title: title([buddyTitle(cli.sessionId), session?.name, job?.name, firstLine(job?.intent), cli.name]),
            createdAtMs: job?.createdAtMs ?? cli.startedAt ?? 0)
    }

    static func cliEntries(_ rows: [BgCliRow], snapshot: BgLedgerSnapshot, nowMs: Int64,
                           buddyTitle: (String) -> String?) -> [BgEntry] {
        var byPid: [Int32: BgSessionRecord] = [:]
        for s in snapshot.sessions { byPid[s.pid] = s }
        return rows.map { cli in
            var session = cli.pid.flatMap { byPid[$0] }
            if let s = session, let sid = s.sessionId, sid != cli.sessionId { session = nil }
            return cliEntry(cli, job: snapshot.jobs[cli.id], session: session, nowMs: nowMs, buddyTitle: buddyTitle)
        }
    }

    /// 台帳から作った行と CLI の行を `id → (state, pid の有無)` で比べる。
    static func ledgerMatchesCli(_ entries: [BgEntry], cli: [BgCliRow]) -> Bool {
        var ledger: [String: String] = [:]
        for e in entries { ledger[e.row.id] = "\(e.row.state.rawValue)/\(e.row.live)" }
        var other: [String: String] = [:]
        for c in cli { other[c.id] = "\(c.state ?? "")/\(c.pid != nil)" }
        return ledger == other
    }

    // MARK: - 一覧に出す行（§7.3）

    /// 出すのは「live、または working / blocked」と「終わってから 24 時間以内」。多くても 50 件。
    static func selectListed(_ entries: [BgEntry], nowMs: Int64) -> [BgEntry] {
        let listed = entries.filter { e in
            if e.row.live || e.row.state == .working || e.row.state == .blocked { return true }
            let ended = e.endedAtMs ?? e.row.createdAtMs
            return nowMs - ended <= recentMs
        }
        return Array(sorted(listed).prefix(maxRows))
    }

    /// blocked → working → ほか。同じ組の中は createdAt の新しい順（同じなら id で安定させる）。
    static func sorted(_ entries: [BgEntry]) -> [BgEntry] {
        func rank(_ s: BgState) -> Int { s == .blocked ? 0 : (s == .working ? 1 : 2) }
        return entries.sorted {
            if rank($0.row.state) != rank($1.row.state) { return rank($0.row.state) < rank($1.row.state) }
            if $0.row.createdAtMs != $1.row.createdAtMs { return $0.row.createdAtMs > $1.row.createdAtMs }
            return $0.row.id < $1.row.id
        }
    }
}
