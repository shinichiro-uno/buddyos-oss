import Foundation
import GRDB

/// ACP の非同期の委任の本当の終わりを知る手がかり（docs/BACKGROUND_CONTROL_2026-10-21.md §5）。
/// Grok は通知（AcpSession の `_x.ai/*`）で終わりが分かる。Hermes と OpenClaw は ACP に何も流れないので、台帳を見張る。
enum DelegationLedgerKind: Sendable {
    case none
    case hermes
    case openclaw
}

/// 台帳の 1 つの鍵（delegation_id / runId）の、いまの状態。
enum AcpLedgerStatus: Equatable, Sendable {
    /// 動いている。text / toolCalls は行のいまの作業（無ければ nil）。
    case running(text: String?, toolCalls: Int?)
    /// 終わった。state は done / failed / stopped。
    case finished(state: String, result: String?, durationMs: Int?)
    /// 台帳に、その鍵の行が無い。
    case missing
    /// 今回は読めなかった（CLI で 1 本ずつ読むとき、読めると分かってからの失敗）。その鍵だけ数えて次の回にやり直す。
    case retry
}

enum AcpLedgerError: Error, Equatable {
    /// 読めない（ファイルが無い・表や列が無い・CLI が使えない）。待っても直らない。
    case unreadable(String)
    /// busy・locked など。次の回にやり直す。
    case transient(String)
}

protocol AcpLedgerReader: AnyObject, Sendable {
    /// 次の読み取りまでの間隔（秒）。
    var pollInterval: TimeInterval { get }
    /// 鍵をまとめて読む。返す表に無い鍵は、今回は何も分からなかったもの（CLI で 1 本ずつ読むとき）。
    func read(keys: [String]) throws -> [String: AcpLedgerStatus]
}

// MARK: - 受領票

/// 委任ツールの tool_call_update（status completed）の本文から、非同期で始めたかと台帳の鍵を読む。
enum AcpDelegationReceipt {
    /// Hermes `delegate_task` の受領票（`status == "dispatched"`）。`action`（list / steer / stop）と `results`（同期の経路）が
    /// あるものは含まない。
    static func hermes(_ update: [String: Any]) -> (delegationId: String, count: Int?)? {
        guard let json = firstText(update["content"]).flatMap(jsonObject) else { return nil }
        guard json["status"] as? String == "dispatched", json["action"] == nil, json["results"] == nil,
              let id = json["delegation_id"] as? String, !id.isEmpty else { return nil }
        return (id, (json["count"] as? NSNumber)?.intValue)
    }

    /// OpenClaw `sessions_spawn` の受領票。`rawOutput.details`（無ければ本文の JSON）が
    /// `accepted` + `mode: run` + `expectsCompletionMessage: true` のときだけ非同期。
    static func openclaw(_ update: [String: Any]) -> String? {
        let details = (update["rawOutput"] as? [String: Any])?["details"] as? [String: Any]
        guard let json = details ?? firstText(update["content"]).flatMap(jsonObject) ?? rawOutputText(update).flatMap(jsonObject)
        else { return nil }
        guard json["status"] as? String == "accepted", json["mode"] as? String == "run",
              json["expectsCompletionMessage"] as? Bool == true,
              let runId = json["runId"] as? String, !runId.isEmpty else { return nil }
        return runId
    }

    /// Grok の背景の spawn（`_meta["x.ai/tool"].name == "spawn_subagent"` で、`_meta.subagentBackground` か
    /// `rawInput.background` が true）。戻り値は説明（subagent_spawned の description と突き合わせる）。
    struct GrokSpawn { let description: String? }

    static func grokBackgroundSpawn(_ update: [String: Any]) -> GrokSpawn? {
        let meta = update["_meta"] as? [String: Any]
        guard (meta?["x.ai/tool"] as? [String: Any])?["name"] as? String == "spawn_subagent" else { return nil }
        let raw = update["rawInput"] as? [String: Any]
        guard meta?["subagentBackground"] as? Bool == true || raw?["background"] as? Bool == true else { return nil }
        return GrokSpawn(description: raw?["description"] as? String)
    }

    /// 前景の spawn_subagent（背景の印が無いもの）の説明。subagent_spawned を背景の行に結ばないために使う。
    static func grokForegroundSpawnDescription(_ update: [String: Any]) -> String? {
        let meta = update["_meta"] as? [String: Any]
        guard (meta?["x.ai/tool"] as? [String: Any])?["name"] as? String == "spawn_subagent",
              grokBackgroundSpawn(update) == nil else { return nil }
        return (update["rawInput"] as? [String: Any])?["description"] as? String
    }

    /// Grok の受領票の本文 `Subagent started in background.\nsubagent_id: <id>\n…` の id。
    static func grokSubagentId(_ text: String?) -> String? {
        guard let text, let range = text.range(of: #"subagent_id: (\S+)"#, options: .regularExpression) else { return nil }
        let id = text[range].dropFirst("subagent_id: ".count)
        return id.isEmpty ? nil : String(id)
    }

    /// content の最初の項目の本文（`content[0].content.text`）。
    private static func firstText(_ raw: Any?) -> String? {
        guard let first = (raw as? [[String: Any]])?.first else { return nil }
        return (first["content"] as? [String: Any])?["text"] as? String ?? first["text"] as? String
    }

    private static func rawOutputText(_ update: [String: Any]) -> String? {
        ((update["rawOutput"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - 台帳（読み取り専用）

/// 台帳の数値を Int にする。inf / nan や Int に収まらない値でも落ちない（他のアプリのファイルは信用しない）。
func ledgerSafeInt(_ value: Double) -> Int? {
    value.isFinite && abs(value) < 9e15 ? Int(value) : nil
}

/// GRDB の列の値を、型が違っても落ちずに取り出す（`row[…] as String?` は INTEGER で fatalError になる）。
private enum LedgerValue {
    static func string(_ row: Row, _ column: String) -> String? {
        guard row.hasColumn(column) else { return nil }
        switch (row[column] as DatabaseValue).storage {
        case .string(let s): return s
        case .int64(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }

    static func double(_ row: Row, _ column: String) -> Double? {
        guard row.hasColumn(column) else { return nil }
        switch (row[column] as DatabaseValue).storage {
        case .int64(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }
}

/// DB を毎回開いて閉じる読み取り専用の問い合わせ。busy / locked / I/O は transient、ほか（ファイルが無い・表や列が無い）は
/// unreadable。
private func readLedgerRows(path: String, sql: String, arguments: StatementArguments) throws -> [Row] {
    guard FileManager.default.fileExists(atPath: path) else { throw AcpLedgerError.unreadable("no file: \(path)") }
    var config = Configuration()
    config.readonly = true
    do {
        let queue = try DatabaseQueue(path: path, configuration: config)
        return try queue.read { try Row.fetchAll($0, sql: sql, arguments: arguments) }
    } catch let error as DatabaseError {
        switch error.extendedResultCode.primaryResultCode {
        case .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_IOERR, .SQLITE_PROTOCOL:
            throw AcpLedgerError.transient("\(error)")
        default:
            throw AcpLedgerError.unreadable("\(error)")
        }
    } catch {
        throw AcpLedgerError.unreadable("\(error)")
    }
}

/// Hermes の `~/.hermes/state.db` の `async_delegations`。
final class HermesLedger: AcpLedgerReader, @unchecked Sendable {
    static var defaultPath: String { NSHomeDirectory() + "/.hermes/state.db" }

    private let path: String
    let pollInterval: TimeInterval

    init(path: String? = nil, pollInterval: TimeInterval = 2) {
        self.path = path ?? Self.defaultPath
        self.pollInterval = pollInterval
    }

    func read(keys: [String]) throws -> [String: AcpLedgerStatus] {
        guard !keys.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let sql = "SELECT delegation_id, state, completed_at, event_json FROM async_delegations WHERE delegation_id IN (\(marks))"
        let rows = try readLedgerRows(path: path, sql: sql, arguments: StatementArguments(keys))
        var out: [String: AcpLedgerStatus] = Dictionary(uniqueKeysWithValues: keys.map { ($0, .missing) })
        for row in rows {
            guard let id = LedgerValue.string(row, "delegation_id") else { continue }
            out[id] = Self.status(state: LedgerValue.string(row, "state"), eventJSON: LedgerValue.string(row, "event_json"),
                                  completedAt: LedgerValue.double(row, "completed_at"))
        }
        return out
    }

    /// state の対応: running / stalling / finalizing → 動いている、completed → done、error / stalled / unknown → failed、
    /// interrupted / cancelled → stopped、ほか → 終わった印（completed_at）があれば failed、無ければ動いている。
    static func status(state: String?, eventJSON: String?, completedAt: Double? = nil) -> AcpLedgerStatus {
        let name = (state ?? "").lowercased()
        switch name {
        case "running", "stalling", "finalizing":
            return .running(text: nil, toolCalls: nil)
        default:
            break
        }
        let final: String
        switch name {
        case "completed": final = "done"
        case "interrupted", "cancelled": final = "stopped"
        case "error", "stalled", "unknown": final = "failed"
        default:
            // 知らない状態は、終わった印があれば失敗、無ければ動いているとみなす（将来の版で状態が増えても赤で閉じない）。
            if completedAt == nil { return .running(text: nil, toolCalls: nil) }
            final = "failed"
        }
        let event = eventJSON.flatMap { $0.data(using: .utf8) }
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        return .finished(state: final, result: result(event), durationMs: durationMs(event))
    }

    /// `results[*].summary`（無ければ `error`）を空行でつなぐ。`results` の無い形は `summary` / `error`。
    private static func result(_ event: [String: Any]?) -> String? {
        guard let event else { return nil }
        func text(_ any: Any?) -> String? {
            guard let s = any as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        if let results = event["results"] as? [[String: Any]] {
            let parts = results.compactMap { text($0["summary"]) ?? text($0["error"]) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        return text(event["summary"]) ?? text(event["error"])
    }

    /// 所要時間。`total_duration_seconds`（無ければ `duration_seconds`）× 1000。
    private static func durationMs(_ event: [String: Any]?) -> Int? {
        guard let event else { return nil }
        for key in ["total_duration_seconds", "duration_seconds"] {
            if let seconds = (event[key] as? NSNumber)?.doubleValue, seconds >= 0 { return ledgerSafeInt((seconds * 1000).rounded()) }
        }
        return nil
    }
}

/// OpenClaw の `${OPENCLAW_STATE_DIR:-~/.openclaw}/state/openclaw.sqlite` の `task_runs`。DB が読めないときは
/// `openclaw tasks show <runId> --json` を 1 本ずつ読む。
final class OpenclawLedger: AcpLedgerReader, @unchecked Sendable {
    static var defaultPath: String {
        let dir = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.openclaw"
        return dir + "/state/openclaw.sqlite"
    }

    private let path: String
    private let cli: (@Sendable (String) -> String?)?
    private let databaseInterval: TimeInterval
    private let cliInterval: TimeInterval
    private let lock = NSLock()
    private var usingCli = false
    private var cliCursor = 0
    private var cliEverWorked = false

    init(path: String? = nil, cli: (@Sendable (String) -> String?)? = nil,
         databaseInterval: TimeInterval = 3, cliInterval: TimeInterval = 10) {
        self.path = path ?? Self.defaultPath
        self.cli = cli
        self.databaseInterval = databaseInterval
        self.cliInterval = cliInterval
    }

    var pollInterval: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return usingCli ? cliInterval : databaseInterval
    }

    func read(keys: [String]) throws -> [String: AcpLedgerStatus] {
        guard !keys.isEmpty else { return [:] }
        do {
            let out = try readDatabase(keys)
            lock.lock(); usingCli = false; lock.unlock()
            return out
        } catch AcpLedgerError.unreadable(let reason) {
            guard let cli else { throw AcpLedgerError.unreadable(reason) }
            return try readCli(keys, cli)
        }
    }

    private func readDatabase(_ keys: [String]) throws -> [String: AcpLedgerStatus] {
        let marks = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let sql = """
            SELECT run_id, status, ended_at, progress_summary, error, terminal_outcome, tool_use_count, last_tool_name, started_at \
            FROM task_runs WHERE run_id IN (\(marks))
            """
        // started_at は所要時間のため。無い版では所要時間を出さないだけにする。
        let rows: [Row]
        do {
            rows = try readLedgerRows(path: path, sql: sql, arguments: StatementArguments(keys))
        } catch AcpLedgerError.unreadable {
            let plain = sql.replacingOccurrences(of: ", started_at ", with: " ")
            rows = try readLedgerRows(path: path, sql: plain, arguments: StatementArguments(keys))
        }
        var out: [String: AcpLedgerStatus] = Dictionary(uniqueKeysWithValues: keys.map { ($0, .missing) })
        for row in rows {
            guard let id = LedgerValue.string(row, "run_id") else { continue }
            out[id] = Self.status(
                status: LedgerValue.string(row, "status"), endedAt: LedgerValue.double(row, "ended_at"),
                startedAt: LedgerValue.double(row, "started_at"), progress: LedgerValue.string(row, "progress_summary"),
                error: LedgerValue.string(row, "error"), terminalOutcome: LedgerValue.string(row, "terminal_outcome"),
                toolUseCount: LedgerValue.double(row, "tool_use_count").flatMap(ledgerSafeInt),
                lastToolName: LedgerValue.string(row, "last_tool_name"))
        }
        return out
    }

    /// DB が読めないとき。鍵を 1 本ずつ順に読む（1 回約 3 秒かかるので、まとめて何本も叩かない）。
    private func readCli(_ keys: [String], _ cli: @Sendable (String) -> String?) throws -> [String: AcpLedgerStatus] {
        lock.lock()
        usingCli = true
        let key = keys[cliCursor % keys.count]
        cliCursor += 1
        let worked = cliEverWorked
        lock.unlock()
        guard let output = cli(key), let fields = Self.cliFields(output) else {
            // 1 回も読めないうちは、読めないとみなす（読めると分かってからの失敗は、その鍵だけ数えて次の回にやり直す）。
            if worked { return [key: .retry] }
            throw AcpLedgerError.unreadable("tasks show failed")
        }
        lock.lock(); cliEverWorked = true; lock.unlock()
        let status = Self.status(
            status: fields["status"] as? String, endedAt: (fields["ended_at"] as? NSNumber)?.doubleValue,
            startedAt: (fields["started_at"] as? NSNumber)?.doubleValue, progress: fields["progress_summary"] as? String,
            error: fields["error"] as? String, terminalOutcome: fields["terminal_outcome"] as? String,
            toolUseCount: (fields["tool_use_count"] as? NSNumber).flatMap { ledgerSafeInt($0.doubleValue) }, lastToolName: fields["last_tool_name"] as? String)
        return [key: status]
    }

    /// `tasks show --json` の出力（`task` に入っていても、そのままでもよい。camelCase も受ける）を snake_case の表にする。
    static func cliFields(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let body = (json["task"] as? [String: Any]) ?? json
        var out: [String: Any] = [:]
        for (key, value) in body {
            var snake = ""
            for c in key {
                if c.isUppercase { snake += "_" + c.lowercased() } else { snake.append(c) }
            }
            out[snake] = value
        }
        return out["status"] is String ? out : nil
    }

    /// status の対応: queued / running → 動いている（最後のツール名とツールの回数）、succeeded → done（結果は progress_summary =
    /// 子の最後の返事）、failed / timed_out / lost → failed（結果は error）、cancelled → stopped、terminal_outcome が blocked → failed。
    static func status(status: String?, endedAt: Double?, startedAt: Double?, progress: String?, error: String?,
                       terminalOutcome: String?, toolUseCount: Int?, lastToolName: String?) -> AcpLedgerStatus {
        let name = (status ?? "").lowercased()
        let duration: Int? = {
            guard let endedAt, let startedAt, endedAt >= startedAt else { return nil }
            return ledgerSafeInt((endedAt - startedAt).rounded())
        }()
        switch name {
        case "queued", "running":
            return .running(text: lastToolName, toolCalls: toolUseCount)
        case "succeeded":
            if terminalOutcome?.lowercased() == "blocked" {
                return .finished(state: "failed", result: error ?? progress, durationMs: duration)
            }
            return .finished(state: "done", result: progress, durationMs: duration)
        case "cancelled":
            return .finished(state: "stopped", result: nil, durationMs: duration)
        case "failed", "timed_out", "lost":
            return .finished(state: "failed", result: error ?? progress, durationMs: duration)
        default:
            // 知らない状態は、終わった印（ended_at）があれば失敗、無ければ動いているとみなす。
            if endedAt != nil { return .finished(state: "failed", result: error ?? progress, durationMs: duration) }
            return .running(text: lastToolName, toolCalls: toolUseCount)
        }
    }
}

// MARK: - 見張り

/// 台帳の見張り（セッションに 1 つ）。台帳の行が全部終わったら止まり、新しい行で起き直す。
/// 前の読み取りが終わるまで次を始めず、動いている鍵を全部まとめて読み、毎回 DB を閉じ、変化だけを知らせる。
final class AcpDelegationWatcher: @unchecked Sendable {
    struct Entry: Sendable {
        /// 行の鍵（tool_call の toolCallId）
        let rowKey: String
        /// 台帳の鍵（delegation_id / runId）
        let ledgerKey: String
        /// 読めないときに、結果にする受領票の文
        let receiptText: String?
    }

    enum Change: Equatable, Sendable {
        case activity(rowKey: String, text: String?, toolCalls: Int?)
        case finished(rowKey: String, state: String, result: String?, durationMs: Int?)
        /// 台帳が読めない（今まで通り、受領票の文で done にする）
        case unreadable(rowKey: String, receiptText: String?)
    }

    private let reader: AcpLedgerReader
    private let intervalOverride: TimeInterval?
    private let failureLimit: Int
    private let onChange: @Sendable ([Change]) -> Void
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var sent: [String: String] = [:]
    private var failures = 0
    /// 台帳で一度でも読めた行（running / finished）。読めたあとの失敗は、すぐ諦めずに数える。
    private var confirmed: Set<String> = []
    /// 行ごとの失敗の回数（CLI で鍵ごとに失敗するとき・読めた行が台帳から消えたとき）。
    private var strikes: [String: Int] = [:]
    private var task: Task<Void, Never>?
    private var stopped = false

    init(reader: AcpLedgerReader, intervalOverride: TimeInterval? = nil, failureLimit: Int = 30,
         onChange: @escaping @Sendable ([Change]) -> Void) {
        self.reader = reader
        self.intervalOverride = intervalOverride
        self.failureLimit = max(1, failureLimit)
        self.onChange = onChange
    }

    /// 見張る行を足す。止まっていれば、すぐ 1 回目を読んで起き直す。
    func add(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        entries.removeAll { $0.rowKey == entry.rowKey }
        confirmed.remove(entry.rowKey)
        strikes.removeValue(forKey: entry.rowKey)
        entries.append(entry)
        if task == nil { task = Task.detached { [weak self] in await self?.loop() } }
    }

    /// 見張る行のうち、行の鍵が条件に合うものを外す（読み取りの結果は捨てる）。
    func remove(where predicate: (String) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { predicate($0.rowKey) }
        confirmed = confirmed.filter { key in entries.contains { $0.rowKey == key } }
        strikes = strikes.filter { key, _ in entries.contains { $0.rowKey == key } }
    }

    var watchedRowKeys: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.map(\.rowKey))
    }

    func stop() {
        lock.lock()
        stopped = true
        entries.removeAll()
        confirmed.removeAll()
        strikes.removeAll()
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
    }

    private func loop() async {
        while !Task.isCancelled {
            let snapshot: [Entry] = lock.withLock {
                if entries.isEmpty {
                    task = nil
                    failures = 0
                }
                return entries
            }
            if snapshot.isEmpty { return }

            let keys = Array(Set(snapshot.map(\.ledgerKey)))
            let result: Result<[String: AcpLedgerStatus], Error> = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .utility).async { [reader] in
                    cont.resume(returning: Result { try reader.read(keys: keys) })
                }
            }
            if Task.isCancelled { return }
            let changes = apply(result, snapshot: snapshot)
            if !changes.isEmpty { onChange(changes) }

            let interval = intervalOverride ?? reader.pollInterval
            try? await Task.sleep(nanoseconds: UInt64(max(0.001, interval) * 1_000_000_000))
        }
    }

    private func apply(_ result: Result<[String: AcpLedgerStatus], Error>, snapshot: [Entry]) -> [Change] {
        lock.lock(); defer { lock.unlock() }
        // 読んでいる間に外された行は捨てる。
        let live = snapshot.filter { s in entries.contains { $0.rowKey == s.rowKey } }
        var changes: [Change] = []
        func giveUp(_ targets: [Entry]) {
            for e in targets {
                entries.removeAll { $0.rowKey == e.rowKey }
                sent.removeValue(forKey: e.rowKey)
                confirmed.remove(e.rowKey)
                strikes.removeValue(forKey: e.rowKey)
                changes.append(.unreadable(rowKey: e.rowKey, receiptText: e.receiptText))
            }
        }
        /// 行ごとの失敗を 1 つ数える。上限に届いたら諦める。
        func strike(_ e: Entry) {
            let n = (strikes[e.rowKey] ?? 0) + 1
            strikes[e.rowKey] = n
            if n >= failureLimit { giveUp([e]) }
        }
        switch result {
        case .failure(let error):
            // 一度も読めていない行は、読めないとすぐ諦める。読めた行は、台帳が差し替わる間などの一時的な失敗かもしれない。
            var retryable = false
            if case AcpLedgerError.transient = error { retryable = true } else {
                giveUp(live.filter { !confirmed.contains($0.rowKey) })
                retryable = live.contains { confirmed.contains($0.rowKey) }
            }
            if retryable {
                failures += 1
                if failures >= failureLimit { giveUp(live) }
            }
        case .success(let statuses):
            failures = 0
            for e in live {
                guard let status = statuses[e.ledgerKey] else { continue }
                switch status {
                case .retry:
                    strike(e)
                case .running(let text, let toolCalls):
                    confirmed.insert(e.rowKey)
                    strikes.removeValue(forKey: e.rowKey)
                    let signature = "\(text ?? "")\u{1}\(toolCalls.map(String.init) ?? "")"
                    guard (text != nil || toolCalls != nil), sent[e.rowKey] != signature else { continue }
                    sent[e.rowKey] = signature
                    changes.append(.activity(rowKey: e.rowKey, text: text, toolCalls: toolCalls))
                case .finished(let state, let result, let durationMs):
                    entries.removeAll { $0.rowKey == e.rowKey }
                    sent.removeValue(forKey: e.rowKey)
                    confirmed.remove(e.rowKey)
                    strikes.removeValue(forKey: e.rowKey)
                    changes.append(.finished(rowKey: e.rowKey, state: state, result: result, durationMs: durationMs))
                case .missing:
                    // 読めた行が台帳から消えたときは、数回は待つ（差し替え中かもしれない）。読めていない行はすぐ諦める。
                    if confirmed.contains(e.rowKey) { strike(e) } else { giveUp([e]) }
                }
            }
        }
        return changes
    }
}
