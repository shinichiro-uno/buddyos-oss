import Foundation
import GRDB

final class HermesAdapter: AgentAdapter {
    let id = "hermes"
    let displayName = "Hermes"
    let capabilities = AgentCapabilities(
        commands: true,
        models: true,
        cron: true,
        skills: true,
        mcp: true,
        // legacy -Q 経路（HermesSession）は止められない。ACP は session/cancel で止まる。
        interrupt: !HermesAdapter.usesLegacyChatTransport
    )

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        let exe = HermesAdapter.locateExecutable()
        // BUDDYOS_NO_ACP=1 で legacy -Q 経路を強制 (デバッグ/緊急 fallback 用)
        if Self.usesLegacyChatTransport {
            return HermesSession(initialSessionId: sessionId, executable: exe)
        }
        // delegate_task の非同期の委任は ACP に何も流れないので、~/.hermes/state.db の台帳を見張って本当の終わりを知る。
        var tuning = AcpSessionTuning()
        tuning.delegationLedger = .hermes
        return AcpSession(
            agentId: "hermes",
            initialSessionId: sessionId,
            executable: exe,
            args: ["acp"],
            cwd: cwd,
            env: ["GLM_BASE_URL": "https://api.z.ai/api/coding/paas/v4"],
            tuning: tuning
        )
    }

    /// SQLite から現在の transport に対応する session 一覧を取得。
    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] {
        let source = Self.usesLegacyChatTransport ? "cli" : "acp"
        let normalizedCwd = Self.normalizedCwd(cwd)
        let cwdSql = "COALESCE(CASE WHEN json_valid(s.model_config) THEN json_extract(s.model_config, '$.cwd') END, '')"
        // session_id, started_at, message_count, title/最初の user message を 1 クエリで取る。
        // ACP mode で cli session を返すと session/load が見つからず、選択後の送信が空振りする。
        var sql = """
        SELECT s.id AS id, s.started_at AS started_at, s.message_count AS message_count,
               \(cwdSql) AS cwd,
               COALESCE(NULLIF(s.title, ''),
                        (SELECT m.content FROM messages m
                         WHERE m.session_id = s.id AND m.role = 'user'
                         ORDER BY m.timestamp LIMIT 1),
                        '') AS display_title
        FROM sessions s
        WHERE s.source = :source
          AND s.message_count > 0
        """
        var args: [String: (any DatabaseValueConvertible)?] = [
            "source": source,
            "limit": max(1, limit)
        ]
        if !Self.usesLegacyChatTransport, let normalizedCwd {
            sql += "\n  AND \(cwdSql) = :cwd"
            args["cwd"] = normalizedCwd
        }
        sql += "\nORDER BY s.started_at DESC\nLIMIT :limit"

        let rows = Self.fetchRows(sql: sql, arguments: StatementArguments(args))
        let iso = ISO8601DateFormatter()
        return rows.compactMap { row -> SessionSummary? in
            guard let sid: String = row["id"] else { return nil }
            let startedAt: Double = row["started_at"] ?? 0
            let count: Int? = row["message_count"]
            let cwd: String? = {
                let value: String = row["cwd"] ?? ""
                return value.isEmpty ? nil : value
            }()
            let display: String = row["display_title"] ?? ""
            let preview = display.replacingOccurrences(of: "\n", with: " ").prefix(60)
            let title = preview.isEmpty ? "(no messages)" : String(preview)
            let lastActive = iso.string(from: Date(timeIntervalSince1970: startedAt))
            return SessionSummary(sessionId: sid, title: title, lastActive: lastActive, messageCount: count, cwd: cwd)
        }
    }

    func loadHistory(sessionId: String) async -> [HistoryMessage] {
        // messages.id は INTEGER。GRDB は型変換に厳格で String 取得が fatalError になるため
        // SQL 側で TEXT に揃える。
        let sql = """
        SELECT CAST(id AS TEXT) AS id, role, COALESCE(content, '') AS content
        FROM messages
        WHERE session_id = :sessionId AND role IN ('user', 'assistant')
        ORDER BY timestamp
        """
        let rows = Self.fetchRows(sql: sql, arguments: ["sessionId": sessionId])
        return rows.compactMap { row -> HistoryMessage? in
            guard let mid: String = row["id"], let role: String = row["role"] else { return nil }
            let content: String = row["content"] ?? ""
            guard !content.isEmpty else { return nil }
            return HistoryMessage(role: role, content: content, messageId: mid)
        }
    }

    /// ~/.hermes/state.db を read-only で開いてクエリする。
    /// バインドパラメータを使う (文字列補間 SQL は cwd / sessionId 経由のインジェクション余地があった)。
    private static func fetchRows(sql: String, arguments: StatementArguments) -> [Row] {
        let dbPath = NSHomeDirectory() + "/.hermes/state.db"
        var config = Configuration()
        config.readonly = true
        guard let db = try? DatabaseQueue(path: dbPath, configuration: config) else { return [] }
        do {
            return try db.read { try Row.fetchAll($0, sql: sql, arguments: arguments) }
        } catch {
            FileHandle.standardError.write(Data("[hermes.db] query failed: \(error)\n".utf8))
            return []
        }
    }

    private static func locateExecutable() -> String {
        if let override = ProcessInfo.processInfo.environment["HERMES_BIN"] {
            return override
        }
        let candidates = [
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            "\(NSHomeDirectory())/.local/bin/hermes"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "hermes"
    }

    private static func normalizedCwd(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            let rest = String(trimmed.dropFirst(2))
            return (home as NSString).appendingPathComponent(rest)
        }
        return (trimmed as NSString).standardizingPath
    }

    private static var usesLegacyChatTransport: Bool {
        ProcessInfo.processInfo.environment["BUDDYOS_NO_ACP"] == "1"
    }

    // MARK: - Cron

    private static var jobsFilePath: String {
        NSHomeDirectory() + "/.hermes/cron/jobs.json"
    }

    func listCronJobs() async -> [CronJobSummary] {
        let path = HermesAdapter.jobsFilePath
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        // hermes は { "jobs": [...] } の形で書き込む
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["jobs"] as? [[String: Any]] else { return [] }
        return raw.compactMap { dict -> CronJobSummary? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            let prompt = (dict["prompt"] as? String) ?? ""
            let scheduleDisplay = (dict["schedule_display"] as? String)
                ?? ((dict["schedule"] as? [String: Any])?["display"] as? String)
                ?? "(unknown)"
            let deliver = (dict["deliver"] as? String) ?? "local"
            let enabled = (dict["enabled"] as? Bool) ?? true
            let state = (dict["state"] as? String) ?? "scheduled"
            return CronJobSummary(
                id: id,
                name: name,
                prompt: prompt,
                scheduleDisplay: scheduleDisplay,
                deliver: deliver,
                enabled: enabled,
                state: state,
                nextRunAt: dict["next_run_at"] as? String,
                lastRunAt: dict["last_run_at"] as? String,
                lastStatus: dict["last_status"] as? String
            )
        }
    }

    func createCronJob(spec: CronCreateSpec) async throws -> String {
        var args: [String] = ["cron", "create"]
        if let name = spec.name, !name.isEmpty { args += ["--name", name] }
        if let deliver = spec.deliver, !deliver.isEmpty { args += ["--deliver", deliver] }
        if let r = spec.repeatCount, r > 0 { args += ["--repeat", String(r)] }
        args.append(spec.schedule)
        args.append(spec.prompt)
        let (status, stdout, stderr) = await HermesAdapter.runHermes(args: args)
        guard status == 0 else {
            throw NSError(domain: "HermesCron", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr])
        }
        // jobs.json から作成直後の最新エントリの id を引き当てる
        if let jobs = try? await listCronJobs(), let newest = jobs.last {
            return newest.id
        }
        return "unknown"
    }

    func deleteCronJob(jobId: String) async throws {
        let (status, stdout, stderr) = await HermesAdapter.runHermes(args: ["cron", "remove", jobId])
        guard status == 0 else {
            throw NSError(domain: "HermesCron", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr])
        }
    }

    func pauseCronJob(jobId: String) async throws {
        let (status, stdout, stderr) = await HermesAdapter.runHermes(args: ["cron", "pause", jobId])
        guard status == 0 else {
            throw NSError(domain: "HermesCron", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr])
        }
    }

    func resumeCronJob(jobId: String) async throws {
        let (status, stdout, stderr) = await HermesAdapter.runHermes(args: ["cron", "resume", jobId])
        guard status == 0 else {
            throw NSError(domain: "HermesCron", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr])
        }
    }

    // MARK: - Commands (skills)

    /// hermes chat REPL の built-in slash command を冒頭に、skill を後段に並べて返す。
    /// skill は ~/.hermes/.skills_prompt_snapshot.json から (table パースだと name が truncate されるため)。
    func listCommands() async -> [CommandInfo] {
        // hermes REPL の built-in slash command (/new, /help 等) は Bridge が hermes を
        // 非対話モード (chat -Q -q) で呼ぶため使えない。skill のみ返す。
        var result: [CommandInfo] = []
        let path = NSHomeDirectory() + "/.hermes/.skills_prompt_snapshot.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skills = root["skills"] as? [[String: Any]]
        else { return result }
        let skillInfos: [CommandInfo] = skills.compactMap { dict in
            guard let name = dict["skill_name"] as? String else { return nil }
            let category = dict["category"] as? String
            let desc = dict["description"] as? String
            let subtitle: String? = {
                if let d = desc, !d.isEmpty { return d }
                if let c = category, !c.isEmpty { return c }
                return nil
            }()
            return CommandInfo(id: name, kind: "skill", title: name, subtitle: subtitle)
        }
        result.append(contentsOf: skillInfos)
        return result
    }

    /// ~/.hermes/config.yaml から `model.default` と `model.provider` を抜き出す。
    /// 軽量 YAML パース (key: value 行のみ対応、ネストは "  default: xxx" のインデントで判別)。
    func currentInfo() async -> AgentInfo? {
        let path = NSHomeDirectory() + "/.hermes/config.yaml"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var model: String? = nil
        var provider: String? = nil
        var inModelBlock = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLead = line.drop(while: { $0 == " " })
            let indent = line.count - trimmedLead.count
            if indent == 0 {
                inModelBlock = trimmedLead.hasPrefix("model:")
                continue
            }
            guard inModelBlock else { continue }
            let parts = trimmedLead.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key == "default" { model = value }
            else if key == "provider" { provider = value }
        }
        if model == nil && provider == nil { return nil }
        return AgentInfo(model: model, provider: provider)
    }

    /// `hermes config set model.default <model>` と `hermes config set model.provider <provider>` を実行。
    /// 既に実行中の hermes プロセスには影響しない (次回起動から反映)。
    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?) async throws {
        let bin = HermesAdapter.locateExecutable()
        try await Self.runConfigSet(bin: bin, key: "model.default", value: model)
        if let p = provider, !p.isEmpty {
            try await Self.runConfigSet(bin: bin, key: "model.provider", value: p)
        }
    }

    func listAvailableModels() async -> [ProviderCatalog] {
        await ModelCatalogLoader.load(agentId: "hermes")
    }

    /// `hermes config set`。協調スレッドの外で待ち、30 秒で打ち切る。
    private static func runConfigSet(bin: String, key: String, value: String) async throws {
        guard let r = await ProcessRunner.runAsync(bin, ["config", "set", key, value], timeout: 30,
                                                   environment: ChildEnvironment.base()) else {
            throw NSError(domain: "HermesAdapter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "config set \(key) failed: could not start \(bin)"])
        }
        if r.timedOut || r.status != 0 {
            let stderr = r.timedOut ? "timed out" : String(decoding: r.stderr, as: UTF8.self)
            throw NSError(
                domain: "HermesAdapter", code: Int(r.status),
                userInfo: [NSLocalizedDescriptionKey: "config set \(key)=\(value) failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"]
            )
        }
    }

    /// hermes chat REPL の built-in slash commands。
    private static let builtinSlashCommands: [CommandInfo] = [
        .init(id: "new",     kind: "hermes", title: "new",     subtitle: "Start a new session (fresh session ID + history)"),
        .init(id: "reset",   kind: "hermes", title: "reset",   subtitle: "Alias for /new"),
        .init(id: "clear",   kind: "hermes", title: "clear",   subtitle: "Clear screen and start a new session"),
        .init(id: "redraw",  kind: "hermes", title: "redraw",  subtitle: "Force a full UI repaint"),
        .init(id: "history", kind: "hermes", title: "history", subtitle: "Show conversation history"),
        .init(id: "save",    kind: "hermes", title: "save",    subtitle: "Save the current conversation"),
        .init(id: "retry",   kind: "hermes", title: "retry",   subtitle: "Retry the last message (resend to agent)"),
        .init(id: "undo",    kind: "hermes", title: "undo",    subtitle: "Remove the last user/assistant exchange"),
        .init(id: "title",   kind: "hermes", title: "title",   subtitle: "Set a title for the current session"),
        .init(id: "handoff", kind: "hermes", title: "handoff", subtitle: "Hand off this session to a messaging platform"),
        .init(id: "branch",  kind: "hermes", title: "branch",  subtitle: "Branch the current session (explore a different path)"),
        .init(id: "fork",    kind: "hermes", title: "fork",    subtitle: "Alias for /branch"),
        .init(id: "resume",  kind: "hermes", title: "resume",  subtitle: "Resume an existing session by id or title")
    ]

    /// hermes CLI を叩く (cron CRUD 用)。協調スレッドの外で待ち、60 秒で打ち切る
    /// （waitUntilExit で待つとスレッドをふさぎ、出力が 64KB を超えると戻らなかった）。
    private static func runHermes(args: [String]) async -> (Int32, String, String) {
        let bin = locateExecutable()
        let quoted = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        guard let r = await ProcessRunner.runAsync("/bin/zsh", ["-lic", "\(bin) \(quoted)"], timeout: 60,
                                                   environment: ChildEnvironment.base()) else {
            return (-1, "", "spawn failed: \(bin)")
        }
        let stdout = String(decoding: r.stdout, as: UTF8.self)
        let stderr = r.timedOut ? "hermes \(args.first ?? "") timed out" : String(decoding: r.stderr, as: UTF8.self)
        return (r.timedOut ? -1 : r.status, stdout, stderr)
    }
}

/// MVP Hermes セッション。
/// - 初回 send: sessionId nil → hermes が新規採番 → 出力先頭の `session_id: <id>` を parse して sessionStarted 発火
/// - 2 回目以降 / resume: `--resume <id>` で同 session を継続
final class HermesSession: AgentSession {
    /// 読み手（SessionHub 等）と send の読み取りループが別スレッドから触るので lock で守る。
    var sessionId: String { lock.withLock { sessionIdStorage } }
    let events: AsyncThrowingStream<SessionEvent, Error>

    private let executable: String
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private let lock = NSLock()
    private var sessionIdStorage: String
    private var resolvedSessionId: String?  // hermes 側 ID 確定後にセット。lock で保護する
    // hermes chat は 1 送信 1 プロセス。停止コマンドが無いので、interrupt / close はプロセスグループごと止める
    // （止めないと、閉じたチャットの hermes が最後まで走り続ける）。以下は lock で保護する。
    private var currentProcess: Process?
    private var didInterrupt = false
    private var closed = false
    /// send を呼び出し順に 1 本ずつ流す鎖の末尾。並行に流すと、新規会話で sessionId が決まる前の
    /// 2 通目が別の会話として始まり、出力も混ざる。
    private var sendTail: OneShotSignal?

    init(initialSessionId: String?, executable: String) {
        // 新規 session の場合は placeholder。確定後 sessionStarted で iOS に通知。
        self.sessionIdStorage = initialSessionId ?? "pending-\(UUID().uuidString.prefix(8))"
        self.resolvedSessionId = initialSessionId
        self.executable = executable

        var continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { c in
            continuation = c
        }
        self.continuation = continuation
    }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        // 前の送信が終わるまで待つ（busy ガード）。終わったら次へ譲る。
        let finished = OneShotSignal()
        let previous: OneShotSignal? = lock.withLock {
            let prev = sendTail
            sendTail = finished
            return prev
        }
        defer {
            lock.withLock { if sendTail === finished { sendTail = nil } }
            finished.signal()
        }
        await previous?.wait()
        guard !lock.withLock({ closed }) else { return }
        await runTurn(text, skills: skills, attachments: attachments)
    }

    private func runTurn(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        let messageId = UUID().uuidString
        let resumeFlag: [String]
        if let rid = lock.withLock({ resolvedSessionId }) {
            resumeFlag = ["--resume", rid]
        } else {
            resumeFlag = []
        }
        let skillsFlag: [String] = skills.isEmpty ? [] : ["--skills", skills.joined(separator: ",")]

        // 添付処理:
        //  - .image は最初の 1 枚だけ tmp dir に書き出して --image PATH を付与 (Hermes 制約)
        //  - .file は utf8 decode できれば <file name="..."> として prompt 先頭に prepend
        //  - 2 枚目以降の image は注記としてテキストに残す
        let tmpDir = makeTmpDir()
        var imageFlag: [String] = []
        var promptBody = text
        var prefixSections: [String] = []
        var imagesUsed = 0

        for att in attachments {
            switch att.kind {
            case .image:
                // 履歴復元用に Claude と同じ placeholder を本文へ（loadHistory→enrichHistory が
                // AttachmentStore と突合して実画像に戻す。表示時に placeholder 行は除去される）。
                prefixSections.append("[image \"\(att.name)\" attached: \(att.mime), \(att.data.count) bytes]")
                if imagesUsed == 0 {
                    let ext = filenameExtension(forMime: att.mime, fallbackName: att.name)
                    let path = (tmpDir as NSString).appendingPathComponent("\(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")")
                    do {
                        try att.data.write(to: URL(fileURLWithPath: path))
                        imageFlag = ["--image", path]
                        imagesUsed += 1
                    } catch {
                        // モデルへは渡せなくても placeholder は残るのでアプリ上では復元できる。
                        prefixSections.append("[画像 \"\(att.name)\" を tmp 書き込み失敗: \(error.localizedDescription)]")
                    }
                } else {
                    prefixSections.append("[画像 \"\(att.name)\" は今回のメッセージで処理されません (Hermes は 1 枚のみ対応)]")
                }
            case .file:
                if let str = String(data: att.data, encoding: .utf8) {
                    prefixSections.append("<file name=\"\(att.name)\">\n\(str)\n</file>")
                } else {
                    prefixSections.append("[file \"\(att.name)\" を添付 (binary, \(att.data.count) bytes)]")
                }
            }
        }
        if !prefixSections.isEmpty {
            promptBody = prefixSections.joined(separator: "\n\n") + "\n\n" + text
        }

        defer {
            // tmp ファイル後始末
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let args = (["chat", "-Q", "-q", promptBody] + resumeFlag + skillsFlag + imageFlag).map { quote($0) }.joined(separator: " ")
        // GLM_BASE_URL を固定して Z.AI endpoint probe（~12s）をスキップ。
        let envPrefix = "export GLM_BASE_URL='https://api.z.ai/api/coding/paas/v4'; "
        process.arguments = ["-lic", "\(envPrefix)\(executable) \(args)"]
        process.environment = ChildEnvironment.base()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // 終了は waitUntilExit（スレッドを塞ぐ）ではなく、run() 前に設定した terminationHandler で受ける。
        let exited = OneShotSignal()
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
            // 独自のプロセスグループにして、hermes の子孫ごと止められるようにする。
            // Bridge が SIGKILL で落ちても次回起動の掃除で回収できるよう記録する。
            let pid = process.processIdentifier
            if pid > 0 {
                _ = setpgid(pid, pid)
                SpawnRegistry.register(pid: pid, command: "hermes chat")
            }
            let closedNow: Bool = lock.withLock {
                currentProcess = process
                didInterrupt = false
                return closed
            }
            // run() と登録の間に close() が来ていたら、ここで止める。
            if closedNow { Self.terminateProcessGroup(process) }
        } catch {
            continuation.yield(SessionEvent(
                type: .error, agentId: "hermes", sessionId: sessionId,
                messageId: messageId, toolUseId: nil,
                content: "failed to spawn hermes: \(error.localizedDescription)",
                toolName: nil, metadata: nil
            ))
            // .error だけだと SessionHub の generating / phase が固着する（非 0 終了の経路と同じ error→done）。
            continuation.yield(.done(agentId: "hermes", sessionId: sessionId, messageId: messageId))
            return
        }
        // 読み取りは協調スレッドプールを塞がないよう readabilityHandler（GCD）で受ける。
        // stderr は常時読んで末尾だけ保持する（終了時にしか読まないとパイプ容量で hermes が詰まる）。
        let chunks = PipeChunks.stream(stdout.fileHandleForReading)
        let stderrTail = PipeTailBuffer()
        stderrTail.start(stderr.fileHandleForReading)

        // hermes chat の stdout 先頭には以下のヘッダが出る:
        //   - 新規 session: `session_id: <id>\n`
        //   - --resume:     `🔄 Resumed session <id> (... messages)\n`
        // 本文に混入させないため、最初の本文行が来るまでヘッダ行を逐次剥がす。

        // 本文は行単位ではなく生テキストを逐次流すので、chunk の末尾で切れた多バイト文字は
        // 次の chunk へ持ち越してデコードする（chunk ごとの String(data:encoding:) は、切れた
        // chunk が nil になって丸ごと失われる）。
        var decoder = IncrementalUTF8Decoder()
        var leftover = ""
        var headerStripped = false
        for await chunk in chunks {
            let text = decoder.decode(chunk)
            if text.isEmpty { continue }

            var body = text
            if !headerStripped {
                leftover += text
                body = ""
                while let nlRange = leftover.range(of: "\n") {
                    let line = String(leftover[..<nlRange.lowerBound])
                    leftover = String(leftover[nlRange.upperBound...])
                    if line.hasPrefix("session_id: ") {
                        let sid = String(line.dropFirst("session_id: ".count))
                            .trimmingCharacters(in: .whitespaces)
                        lock.withLock {
                            self.resolvedSessionId = sid
                            self.sessionIdStorage = sid
                        }
                        continuation.yield(.sessionStarted(agentId: "hermes", sessionId: sid))
                    } else if line.contains("Resumed session") {
                        // emoji prefix の有無に依存せず "Resumed session" 部分文字列で判定
                        continue
                    } else {
                        // ヘッダではない最初の行 → 以降は本文
                        body = line + "\n" + leftover
                        leftover = ""
                        headerStripped = true
                        break
                    }
                }
                // 改行未到達ならヘッダ判定継続
                if !headerStripped { continue }
            }

            if !body.isEmpty {
                continuation.yield(.assistantDelta(body, agentId: "hermes", sessionId: self.sessionId, messageId: messageId))
            }
        }
        // 持ち越したまま終わった断片（不完全な UTF-8）は U+FFFD にして出す。
        let tail = decoder.flush()
        if headerStripped, !tail.isEmpty {
            continuation.yield(.assistantDelta(tail, agentId: "hermes", sessionId: self.sessionId, messageId: messageId))
        }
        await exited.wait()
        // 残りの stderr が届くのを短時間だけ待ってから、handler を外して fd を閉じる（ProcessRunner と同じ後始末）。
        // zsh の初期化や hermes が起動した子孫プロセスが stderr の書き込み端を握って生き残ると EOF が来ず、
        // 外さないと dispatch source と読み取り fd が送信のたびに残る。
        await stderrTail.waitForEOF()
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stderr.fileHandleForReading.close()

        let wasInterrupted: Bool = lock.withLock {
            if currentProcess === process { currentProcess = nil }
            return didInterrupt
        }
        if process.processIdentifier > 0 { SpawnRegistry.unregister(pid: process.processIdentifier) }
        if wasInterrupted {
            // 停止要求による終了。途中までの出力で done にする（エラーにはしない）。
            continuation.yield(.done(agentId: "hermes", sessionId: sessionId, messageId: messageId))
            return
        }

        if process.terminationStatus != 0 {
            let errText = stderrTail.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "hermes exited \(process.terminationStatus)"
                : stderrTail.text
            continuation.yield(SessionEvent(
                type: .error, agentId: "hermes", sessionId: sessionId,
                messageId: messageId, toolUseId: nil,
                content: errText, toolName: nil, metadata: nil
            ))
        }

        continuation.yield(.done(agentId: "hermes", sessionId: sessionId, messageId: messageId))
    }

    func interrupt() async {
        let p: Process? = lock.withLock {
            didInterrupt = true
            return currentProcess
        }
        Self.terminateProcessGroup(p)
    }

    func close() async {
        let p: Process? = lock.withLock {
            closed = true
            didInterrupt = true
            return currentProcess
        }
        Self.terminateProcessGroup(p)
        continuation.finish()
    }

    /// プロセスグループ全体に SIGTERM（zsh の下の hermes と、その子孫もまとめて止める）。
    private static func terminateProcessGroup(_ p: Process?) {
        guard let p, p.isRunning else { return }
        let pid = p.processIdentifier
        if pid > 0 {
            kill(-pid, SIGTERM)
            SpawnRegistry.unregister(pid: pid)
        }
        if p.isRunning { p.terminate() }
    }

    private func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 1 送信ごとの一時 dir。送信完了後に defer で消す。
    private func makeTmpDir() -> String {
        // テスト中は BuddyPaths が一時フォルダを返すので、本物の ~/.buddyos/tmp を汚さない。
        let base = BuddyPaths.root.appendingPathComponent("tmp/\(UUID().uuidString)", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        return base
    }

    /// MIME から拡張子を推定。失敗時は name の拡張子を使う。
    private func filenameExtension(forMime mime: String, fallbackName: String) -> String {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default:
            return (fallbackName as NSString).pathExtension
        }
    }
}
