import Foundation

/// OpenClaw エージェント用の AgentAdapter 実装。
///
/// OpenClaw は Peter Steinberger 作の OSS 汎用 AI エージェント
/// (https://github.com/openclaw/openclaw)。Hermes と同じく ACP (Agent Client
/// Protocol) を `openclaw acp` コマンド経由で stdio 越しに喋れるので、AcpClient /
/// AcpSession 共通層を流用する。
///
/// 前提:
///  - `openclaw` CLI が PATH 上または `OPENCLAW_BIN` env で指された場所にある
///  - Gateway daemon (`openclaw daemon` / `openclaw onboard --install-daemon`)
///    が port 18789 で動いている (これがないと `openclaw acp` は接続を拒否する)
final class OpenclawAdapter: AgentAdapter {
    let id = "openclaw"
    let displayName = "OpenClaw"
    let capabilities = AgentCapabilities(
        commands: true,
        models: true,
        cron: true,
        skills: true,
        mcp: true
    )

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        // Swift Process から `openclaw acp` を直接 spawn すると session/prompt の応答が
        // 不安定。Node.js spawn 経由なら常に応答が返るので、軽量な Node.js wrapper を
        // 経由する形にして安定化させる (probe 検証済み)。
        let openclawBin = Self.locateExecutable()
        let nodeBin = Self.locateNode()
        let wrapperPath = Self.ensureWrapperScript()
        let openclawAgent = OpenclawConfig.load()?.agents?.list?.first?.id ?? "main"
        // session key は openclaw 側で lowercased canonical 化される。mac-bridge では
        // UUID().uuidString が大文字なので、ここで小文字化しないと sessions.json の
        // entry lookup が外れて kind=none (silent return) で応答が来なくなる。
        let randomTail = UUID().uuidString.prefix(8).lowercased()
        let sessionKey = "agent:\(openclawAgent):\(sessionId ?? "buddyos-\(randomTail)")"
        let token = Self.readGatewayToken() ?? ""
        // sessions_spawn の非同期の委任は ACP に何も流れないので、task_runs の台帳を見張って本当の終わりを知る。
        // DB が読めないときは `openclaw tasks show` を代わりに叩く。
        var tuning = AcpSessionTuning()
        tuning.delegationLedger = .openclaw
        tuning.delegationCli = { runId in Self.tasksShow(runId: runId, bin: openclawBin) }
        return AcpSession(
            agentId: "openclaw",
            initialSessionId: sessionId,
            executable: nodeBin,
            args: [wrapperPath, openclawBin, sessionKey, token],
            cwd: cwd,
            env: [:],
            // openclaw は user prompt を自前 jsonl に記録せず、resume のたびに内部
            // セッションが切り替わって履歴が最新ターン分だけになる。bridge 側で
            // 完全なトランスクリプトを持ち、loadHistory はこちらを優先する。
            transcriptDir: Self.transcriptDir,
            tuning: tuning
        )
    }

    /// `openclaw tasks show <runId> --json` の標準出力（10 秒で打ち切る。失敗は nil）。
    /// runId は台帳の鍵として受領票から来るので、シェルに渡す前に形を確かめる。
    private static func tasksShow(runId: String, bin: String) -> String? {
        guard !runId.isEmpty, runId.allSatisfy({ $0.isLetter || $0.isNumber || "-_.:".contains($0) }) else { return nil }
        let (status, stdout, _) = runOpenclaw(bin: bin, args: ["tasks", "show", runId, "--json"], timeout: 10)
        return status == 0 ? stdout : nil
    }

    /// bridge 管理のトランスクリプト置き場 (`<dir>/<sessionId>.jsonl`)
    static var transcriptDir: String {
        NSHomeDirectory() + "/.buddyos/transcripts/openclaw"
    }

    /// `~/.openclaw/agents/<id>/sessions/sessions.json` を読み、BuddyOS が作った
    /// session key (`agent:<id>:buddyos-*`) の entry を新しい順に最大 `limit` 件返す。
    /// title は jsonl の最初の **trusted** user message (Sender metadata を除く) から
    /// 抽出する。
    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] {
        let openclawAgent = OpenclawConfig.load()?.agents?.list?.first?.id ?? "main"
        let path = NSHomeDirectory() + "/.openclaw/agents/\(openclawAgent)/sessions/sessions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let prefix = "agent:\(openclawAgent):buddyos-"
        let iso = ISO8601DateFormatter()
        let entries: [(key: String, dict: [String: Any], updatedMs: Double)] = root.compactMap { (key, value) in
            guard key.hasPrefix(prefix),
                  let dict = value as? [String: Any],
                  let updatedMs = (dict["updatedAt"] as? Double) ?? (dict["updatedAt"] as? Int).map(Double.init)
            else { return nil }
            return (key, dict, updatedMs)
        }.sorted { $0.updatedMs > $1.updatedMs }

        var result: [SessionSummary] = []
        for entry in entries.prefix(max(1, limit)) {
            let sessionId = (entry.dict["sessionId"] as? String) ?? entry.key
            let sessionFile = entry.dict["sessionFile"] as? String
            // タイトルは bridge transcript の最初の user prompt が最良 (openclaw 自前の
            // jsonl には user prompt が残らないので従来は assistant 応答で代用していた)
            let title = Self.transcriptTitle(sessionId: sessionId, agent: openclawAgent)
                ?? Self.readSessionTitle(sessionFile: sessionFile)
                ?? entry.key.replacingOccurrences(of: prefix, with: "")
            let lastActive = iso.string(from: Date(timeIntervalSince1970: entry.updatedMs / 1000.0))
            result.append(SessionSummary(
                sessionId: sessionId,
                title: title,
                lastActive: lastActive,
                messageCount: nil,
                cwd: entry.dict["cwd"] as? String
            ))
        }
        return result
    }

    func loadHistory(sessionId: String) async -> [HistoryMessage] {
        let openclawAgent = OpenclawConfig.load()?.agents?.list?.first?.id ?? "main"
        // bridge 管理のトランスクリプトがあれば最優先。openclaw 自前の jsonl は
        // user prompt が記録されず、resume を跨ぐと最新ターン分しか残らないため、
        // トランスクリプトが存在する (= この bridge 経由で会話した) セッションでは
        // 常にこちらが完全。
        let transcript = Self.loadTranscript(sessionId: sessionId, agent: openclawAgent)
        if !transcript.isEmpty { return transcript }

        let dir = NSHomeDirectory() + "/.openclaw/agents/\(openclawAgent)/sessions"
        var path = dir + "/\(sessionId).jsonl"
        // ACP 経由で作られたセッションは jsonl ファイル名が openclaw 内部 sessionId になる
        // (sessions.json の "agent:<agent>:<acpSessionId>" キーが内部 ID へのマップ)。
        // 直接ファイルが無ければマップを引いて内部 ID の jsonl を読む。これを怠ると
        // live で作った会話を resume した時に履歴が常に 0 件になる。
        if !FileManager.default.fileExists(atPath: path),
           let internalId = Self.resolveInternalSessionId(acpSessionId: sessionId, agent: openclawAgent) {
            path = dir + "/\(internalId).jsonl"
        }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var result: [HistoryMessage] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "message",
                  let msg = obj["message"] as? [String: Any],
                  let role = msg["role"] as? String,
                  role == "user" || role == "assistant",
                  let text = Self.extractMessageText(msg["content"]),
                  !Self.isSenderMetadata(text) else { continue }
            let id = (obj["id"] as? String) ?? UUID().uuidString
            // openclaw が user prompt の先頭に付ける "[Working directory: ...]" の
            // コンテキスト行は表示ノイズなので履歴では取り除く。
            let display = role == "user" ? Self.stripWorkingDirectoryPrefix(text) : text
            result.append(HistoryMessage(role: role, content: display, messageId: id))
        }
        return result
    }

    /// "[Working directory: ~]\n\n本文" → "本文"。プレフィックスが無ければそのまま返す。
    private static func stripWorkingDirectoryPrefix(_ text: String) -> String {
        guard text.hasPrefix("[Working directory:") else { return text }
        guard let close = text.range(of: "]") else { return text }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// sessions.json の "agent:<agent>:<acpSessionId>" エントリから openclaw 内部 sessionId を引く。
    private static func resolveInternalSessionId(acpSessionId: String, agent: String) -> String? {
        let path = NSHomeDirectory() + "/.openclaw/agents/\(agent)/sessions/sessions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["agent:\(agent):\(acpSessionId)"] as? [String: Any],
              let sid = entry["sessionId"] as? String, !sid.isEmpty else { return nil }
        return sid
    }

    /// 内部 sessionId から ACP 側 sessionId (sessions.json キーの末尾) を逆引きする。
    /// (セッションリストは内部 ID を返すが、transcript は ACP ID で保存されているため)
    private static func resolveAcpSessionId(internalId: String, agent: String) -> String? {
        let path = NSHomeDirectory() + "/.openclaw/agents/\(agent)/sessions/sessions.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keyPrefix = "agent:\(agent):"
        for (key, value) in root {
            guard key.hasPrefix(keyPrefix),
                  let dict = value as? [String: Any],
                  (dict["sessionId"] as? String) == internalId else { continue }
            return String(key.dropFirst(keyPrefix.count))
        }
        return nil
    }

    /// bridge 管理の transcript を探して読む。client が内部 ID / ACP ID のどちらで
    /// 来ても見つかるよう、sessions.json のマップで双方向に解決して両方試す。
    static func loadTranscript(sessionId: String, agent: String) -> [HistoryMessage] {
        var candidates = [sessionId]
        if let internalId = resolveInternalSessionId(acpSessionId: sessionId, agent: agent) {
            candidates.append(internalId)
        }
        if let acpId = resolveAcpSessionId(internalId: sessionId, agent: agent) {
            candidates.append(acpId)
        }
        for sid in candidates {
            let path = transcriptDir + "/\(AcpSession.sanitizeFileName(sid)).jsonl"
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var result: [HistoryMessage] = []
            for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let role = obj["role"] as? String,
                      let content = obj["content"] as? String, !content.isEmpty else { continue }
                let id = (obj["messageId"] as? String) ?? UUID().uuidString
                result.append(HistoryMessage(role: role, content: content, messageId: id))
            }
            if !result.isEmpty { return result }
        }
        return []
    }

    /// transcript の最初の user message をセッションタイトルとして使う (60 文字)。
    static func transcriptTitle(sessionId: String, agent: String) -> String? {
        let messages = loadTranscript(sessionId: sessionId, agent: agent)
        guard let first = messages.first(where: { $0.role == "user" }) else { return nil }
        let cleaned = first.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(60))
    }

    /// jsonl から title を抽出する。OpenClaw の user message は実際は ACP メタデータの
    /// `Sender (untrusted metadata):` のみで、実 prompt は記録されない。代わりに **最初の
    /// assistant 応答** を title にする (公式 CLI の sessions list も同じ挙動)。
    private static func readSessionTitle(sessionFile: String?) -> String? {
        guard let sessionFile else { return nil }
        // 最初の assistant メッセージが見つかれば即打ち切る (全文を読み込まない)。
        var title: String?
        forEachLine(path: sessionFile) { line in
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "message",
                  let msg = obj["message"] as? [String: Any],
                  (msg["role"] as? String) == "assistant",
                  let text = extractMessageText(msg["content"]),
                  !text.isEmpty else { return true }
            let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            title = String(cleaned.prefix(60))
            return false  // stop at first assistant message
        }
        return title
    }

    /// 巨大ファイルを 1 本の String に展開せず 1 MB チャンクで読み、改行区切りで
    /// `body` に 1 行ずつ渡す。`body` が false を返すと打ち切る。
    private static func forEachLine(path: String, _ body: (String) -> Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        let newline: UInt8 = 0x0A
        var stop = false
        while !stop {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            buffer.append(chunk)
            var searchStart = buffer.startIndex
            while let nl = buffer[searchStart...].firstIndex(of: newline) {
                if nl > searchStart {
                    let lineData = buffer.subdata(in: searchStart..<nl)
                    if let s = String(data: lineData, encoding: .utf8), !s.isEmpty, !body(s) {
                        stop = true
                        break
                    }
                }
                searchStart = buffer.index(after: nl)
            }
            if stop { break }
            if searchStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<searchStart)
            }
        }
        if !stop, !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8), !s.isEmpty {
            _ = body(s)
        }
    }

    private static func extractMessageText(_ raw: Any?) -> String? {
        if let arr = raw as? [[String: Any]] {
            let parts = arr.compactMap { $0["text"] as? String }
            return parts.isEmpty ? nil : parts.joined()
        }
        if let s = raw as? String { return s }
        return nil
    }

    private static func isSenderMetadata(_ text: String) -> Bool {
        text.hasPrefix("Sender (")
    }

    // MARK: - Commands (slash palette)

    /// OpenClaw の `/` パレットに出すコマンド。組み込み slash command と
    /// `~/.openclaw/skills/<name>/SKILL.md` から拾った skill 一覧を返す。
    func listCommands() async -> [CommandInfo] {
        var result: [CommandInfo] = [
            .init(id: "plan",    kind: "openclaw", title: "plan",    subtitle: "Plan the next steps"),
            .init(id: "options", kind: "openclaw", title: "options", subtitle: "Show OpenClaw options"),
            .init(id: "resume",  kind: "openclaw", title: "resume",  subtitle: "Resume an existing session"),
            .init(id: "review",  kind: "openclaw", title: "review",  subtitle: "Ask OpenClaw to review the work"),
            .init(id: "model",   kind: "openclaw", title: "model",   subtitle: "Change OpenClaw model"),
            .init(id: "help",    kind: "openclaw", title: "help",    subtitle: "Show OpenClaw help")
        ]
        let skills = SkillsService.list(cwd: nil, agentId: "openclaw")
        result.append(contentsOf: skills.map { s in
            CommandInfo(id: s.name, kind: "skill", title: s.name, subtitle: s.description.isEmpty ? nil : s.description)
        })
        return result
    }

    // MARK: - Cron

    /// `openclaw cron list --all --json` を実行して JSON をパースする。
    /// Gateway daemon に依存するため失敗時は `~/.openclaw/cron/jobs.json` を直読みする fallback。
    func listCronJobs() async -> [CronJobSummary] {
        let bin = Self.locateExecutable()
        let (status, stdout, _) = Self.runOpenclaw(bin: bin, args: ["cron", "list", "--all", "--json"])
        let jobsArray: [[String: Any]]
        if status == 0,
           let data = stdout.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = root["jobs"] as? [[String: Any]] {
            jobsArray = arr
        } else {
            let path = NSHomeDirectory() + "/.openclaw/cron/jobs.json"
            guard let data = FileManager.default.contents(atPath: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = root["jobs"] as? [[String: Any]] else {
                return []
            }
            jobsArray = arr
        }
        return jobsArray.compactMap(Self.parseCronJob(_:))
    }

    func createCronJob(spec: CronCreateSpec) async throws -> String {
        let bin = Self.locateExecutable()
        var args: [String] = ["cron", "add", "--json"]
        if let name = spec.name, !name.isEmpty {
            args += ["--description", name]
        }
        // schedule の形式を openclaw CLI 引数に変換:
        //   "every X" / 単独 duration ("30m") → --every X
        //   "+X"                              → --at +X (one-shot)
        //   "0 9 * * *" のような cron 式      → --cron "..."
        let schedule = spec.schedule.trimmingCharacters(in: .whitespaces)
        if schedule.hasPrefix("every ") {
            let dur = String(schedule.dropFirst("every ".count)).trimmingCharacters(in: .whitespaces)
            args += ["--every", dur]
        } else if schedule.hasPrefix("+") {
            args += ["--at", schedule]
        } else if schedule.contains(" ") {
            args += ["--cron", schedule]
        } else {
            args += ["--every", schedule]
        }
        if let deliver = spec.deliver, deliver == "announce" {
            args += ["--announce"]
        }
        if let r = spec.repeatCount, r == 1 {
            args += ["--delete-after-run"]
        }
        args.append(spec.prompt)

        let (status, stdout, stderr) = Self.runOpenclaw(bin: bin, args: args)
        guard status == 0 else {
            throw NSError(domain: "OpenclawCron", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr])
        }
        if let data = stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let id = obj["id"] as? String { return id }
            if let job = obj["job"] as? [String: Any], let id = job["id"] as? String { return id }
        }
        // フォールバック: 最新エントリの id
        if let newest = (await listCronJobs()).max(by: { ($0.id) < ($1.id) }) {
            return newest.id
        }
        return "unknown"
    }

    func deleteCronJob(jobId: String) async throws {
        try Self.runOpenclawCronOp(args: ["cron", "rm", jobId])
    }

    func pauseCronJob(jobId: String) async throws {
        try Self.runOpenclawCronOp(args: ["cron", "disable", jobId])
    }

    func resumeCronJob(jobId: String) async throws {
        try Self.runOpenclawCronOp(args: ["cron", "enable", jobId])
    }

    private static func runOpenclawCronOp(args: [String]) throws {
        let bin = locateExecutable()
        let (status, stdout, stderr) = runOpenclaw(bin: bin, args: args)
        guard status == 0 else {
            throw NSError(domain: "OpenclawCron", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr])
        }
    }

    /// OpenClaw の cron job JSON 1 件を BuddyOS の CronJobSummary に変換する。
    private static func parseCronJob(_ dict: [String: Any]) -> CronJobSummary? {
        guard let id = dict["id"] as? String else { return nil }
        let name = (dict["name"] as? String) ?? (dict["description"] as? String) ?? id
        let payload = (dict["payload"] as? [String: Any]) ?? [:]
        let prompt = (payload["message"] as? String) ?? ""
        let schedule = (dict["schedule"] as? [String: Any]) ?? [:]
        let scheduleDisplay = formatSchedule(schedule)
        let delivery = (dict["delivery"] as? [String: Any]) ?? [:]
        let deliver = (delivery["mode"] as? String) ?? "local"
        let enabled = (dict["enabled"] as? Bool) ?? true
        let state = (dict["state"] as? [String: Any]) ?? [:]
        let lastStatus = state["lastStatus"] as? String ?? state["lastRunStatus"] as? String
        let nextRunAt = isoFromMillis(state["nextRunAtMs"])
        let lastRunAt = isoFromMillis(state["lastRunAtMs"])
        // BridgeCronScheduler.summary と同じ表記（"paused"）にそろえ、既存 iOS でも「再開」ボタンを出す。
        let stateLabel: String = enabled ? "scheduled" : "paused"
        return CronJobSummary(
            id: id,
            name: name,
            prompt: prompt,
            scheduleDisplay: scheduleDisplay,
            deliver: deliver,
            enabled: enabled,
            state: stateLabel,
            nextRunAt: nextRunAt,
            lastRunAt: lastRunAt,
            lastStatus: lastStatus
        )
    }

    private static func formatSchedule(_ schedule: [String: Any]) -> String {
        let kind = (schedule["kind"] as? String) ?? ""
        switch kind {
        case "every":
            if let ms = schedule["everyMs"] as? Int {
                return "every \(formatDuration(ms: ms))"
            }
            return "every"
        case "cron":
            let expr = (schedule["expr"] as? String) ?? "(?)"
            return "cron \(expr)"
        case "at":
            if let ms = schedule["atMs"] as? Int, let iso = isoFromMillis(ms) {
                return "at \(iso)"
            }
            return "at (unknown)"
        default:
            return kind.isEmpty ? "(unknown)" : kind
        }
    }

    private static func formatDuration(ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return "\(days)d"
    }

    private static func isoFromMillis(_ raw: Any?) -> String? {
        guard let ms = raw as? Int else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        return ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Model info / catalog

    func currentInfo() async -> AgentInfo? {
        guard let config = OpenclawConfig.load() else { return nil }
        let primary = config.agents?.defaults?.model?.primary
        let (provider, splitModel) = OpenclawConfig.splitProviderModel(primary)
        var model = splitModel
        // 旧 setModel が書いた二重プレフィックス（"zai/zai/glm-5.1"）は OpenClaw が解決できず失敗し続ける。
        // 表示だけ直すと切り替わったように見えてしまうので、config set で補正できたときだけ直した値を返す。
        if let p = provider, let m = model {
            let fixed = Self.stripLegacyProviderPrefix(model: m, provider: p)
            if fixed != m,
               (try? Self.runConfigSet(bin: Self.locateExecutable(), key: "agents.defaults.model.primary", value: "\(p)/\(fixed)")) != nil {
                model = fixed
            }
        }
        if model == nil && provider == nil { return nil }
        return AgentInfo(model: model, provider: provider)
    }

    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?) async throws {
        let value: String
        if let provider, !provider.isEmpty {
            value = "\(provider)/\(Self.stripLegacyProviderPrefix(model: model, provider: provider))"
        } else {
            value = model
        }
        let bin = Self.locateExecutable()
        try Self.runConfigSet(bin: bin, key: "agents.defaults.model.primary", value: value)
    }

    /// 旧カタログ id（"<provider>/<model>"）で来た model から自 provider プレフィックスを外す。
    /// iOS のお気に入りには旧形式が残っているため、そのまま組み立てると "zai/zai/glm-5.1"
    /// のように二重になる。ただし "openrouter/auto" のように provider 名と同じプレフィックスを
    /// 持つ正当な model id もあるので、カタログに外した形だけが実在する場合に限って外す。
    private static func stripLegacyProviderPrefix(model: String, provider: String) -> String {
        let prefix = provider + "/"
        guard model.lowercased().hasPrefix(prefix.lowercased()) else { return model }
        let stripped = String(model.dropFirst(prefix.count))
        let ids = (OpenclawConfig.load()?.models?.providers?[provider]?.models ?? []).map(\.id)
        return (!ids.contains(model) && ids.contains(stripped)) ? stripped : model
    }

    func listAvailableModels() async -> [ProviderCatalog] {
        guard let providers = OpenclawConfig.load()?.models?.providers, !providers.isEmpty else {
            return []
        }
        return providers
            .sorted { $0.key < $1.key }
            .map { providerId, info in
                // id は provider を付けない entry.id。iOS は provider を別フィールドで送り、
                // setModel が "<provider>/<model>" を組み立てる。currentInfo の分割結果とも揃う。
                let modelItems: [ModelCatalogItem] = (info.models ?? []).map { entry in
                    ModelCatalogItem(
                        id: entry.id,
                        label: entry.name ?? entry.id,
                        subtitle: nil
                    )
                }
                return ProviderCatalog(id: providerId, label: providerId, models: modelItems)
            }
    }

    // MARK: - Executable locator

    // MARK: - Node.js wrapper

    /// OpenClaw が要求する最低 Node.js バージョン (major, minor)。
    /// これ未満だと `openclaw acp` が "Node.js vX is required" で即終了し、
    /// ブリッジ側は ACP 初期化タイムアウト＝起動失敗に見える。
    private static let minNode = (major: 22, minor: 19)

    /// Node.js 実行ファイルを探す。OpenClaw は Node >= 22.19 を要求するため、
    /// 候補を実際に実行してバージョンを確認し、要件を満たす中で **最新** を選ぶ。
    /// `~/.petclaw/node`(古いことがある) を盲目的に最優先しない。
    /// `OPENCLAW_NODE_BIN` env で明示上書き可能。
    private static func locateNode() -> String {
        if let override = ProcessInfo.processInfo.environment["OPENCLAW_NODE_BIN"], !override.isEmpty {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.petclaw/node/bin/node",
            "\(home)/.npm-global/bin/node"
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }

        var best: (path: String, v: (Int, Int, Int))? = nil
        for path in candidates {
            guard let v = nodeVersion(path) else { continue }
            let satisfies = v.0 > minNode.major || (v.0 == minNode.major && v.1 >= minNode.minor)
            guard satisfies else { continue }
            if best == nil || v > best!.v { best = (path, v) }
        }
        if let best { return best.path }
        // 要件を満たす node が無い場合は最初の存在候補を返す（openclaw が自前の
        // バージョンエラーを出すので、ログで原因が分かる）。
        return candidates.first ?? "node"
    }

    /// `<node> -p process.versions.node` を 2 秒以内で実行し (major, minor, patch) を返す。
    private static func nodeVersion(_ path: String) -> (Int, Int, Int)? {
        guard let r = ProcessRunner.run(path, ["-p", "process.versions.node"], timeout: 2.0),
              !r.timedOut, r.status == 0 else { return nil }
        let s = (String(data: r.stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1], parts.count > 2 ? parts[2] : 0)
    }

    /// Node.js wrapper script を `~/.buddyos/openclaw_wrapper.mjs` に書き出して返す。
    /// 既存ファイルが最新なら上書きはスキップ。
    private static func ensureWrapperScript() -> String {
        let home = NSHomeDirectory()
        let dir = home + "/.buddyos"
        let path = dir + "/openclaw_wrapper.mjs"
        if FileManager.default.fileExists(atPath: path) {
            if let existing = try? String(contentsOfFile: path, encoding: .utf8), existing == wrapperSource {
                return path
            }
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? wrapperSource.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Node.js wrapper の中身。openclaw acp を spawn し、stdin/stdout を pipe する。
    /// Swift Process 直起動だと session/prompt の応答が不安定だが、この wrapper 経由なら
    /// Node.js spawn の挙動になって安定する (詳細は OpenclawAdapter.openSession のコメント)。
    private static let wrapperSource: String = """
    // BuddyOS - openclaw acp wrapper (auto-generated; do not edit by hand)
    // argv: [openclawBin, sessionKey, token]
    //
    // Swift Process から openclaw acp を直接 spawn すると stdin pipe の挙動で
    // session/prompt が応答しないことがあるため、Node.js wrapper を挟む。
    // session key は呼び出し側で小文字化済み前提 (openclaw 側で canonical key が
    // 小文字化されるため、UUID 由来の大文字を混ぜると session lookup が外れる)。
    import { spawn } from "node:child_process";

    const openclawBin = process.argv[2];
    const sessionKey  = process.argv[3];
    const token       = process.argv[4] ?? "";

    const args = ["acp", "--session", sessionKey];
    if (token) args.push("--token", token);

    // openclaw を「この wrapper を起動した node (process.execPath)」と同じ Node.js で
    // 実行する。openclaw の "#!/usr/bin/env node" シェバンに任せると PATH 上の古い node
    // (例: ~/.petclaw/node v22.14) に解決され "Node >=22.19 required" で即死するため、
    // ブリッジが選んだ node (>=22.19) で直接走らせる。
    const proc = spawn(process.execPath, [openclawBin, ...args], { stdio: ["pipe", "pipe", "pipe"] });

    process.stdin.on("data", (chunk) => proc.stdin.write(chunk));
    process.stdin.on("end",  () => proc.stdin.end());
    proc.stdout.on("data", (chunk) => process.stdout.write(chunk));
    proc.stderr.on("data", (chunk) => process.stderr.write(chunk));
    process.stdin.resume();

    proc.on("exit", (code) => process.exit(code ?? 0));
    process.on("SIGTERM", () => proc.kill("SIGTERM"));
    process.on("SIGINT",  () => proc.kill("SIGINT"));
    """

    /// `~/.openclaw/openclaw.json` から `gateway.auth.token` を取得する。
    private static func readGatewayToken() -> String? {
        let path = NSHomeDirectory() + "/.openclaw/openclaw.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = root["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String,
              !token.isEmpty else { return nil }
        return token
    }

    private static func locateExecutable() -> String {
        if let override = ProcessInfo.processInfo.environment["OPENCLAW_BIN"], !override.isEmpty {
            return override
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.npm-global/bin/openclaw",
            "/opt/homebrew/bin/openclaw",
            "/usr/local/bin/openclaw",
            "\(home)/.local/bin/openclaw"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "openclaw"
    }

    /// `openclaw config set <key> <value>` を同期で実行。
    private static func runConfigSet(bin: String, key: String, value: String) throws {
        let (status, stdout, stderr) = runOpenclaw(bin: bin, args: ["config", "set", key, value])
        guard status == 0 else {
            throw NSError(
                domain: "OpenclawAdapter", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "config set \(key)=\(value) failed: \((stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines))"]
            )
        }
    }

    /// openclaw CLI を同期で叩く汎用ヘルパー。 (status, stdout, stderr) を返す。
    fileprivate static func runOpenclaw(bin: String, args: [String], timeout: TimeInterval = 30) -> (Int32, String, String) {
        // openclaw の "#!/usr/bin/env node" シェバンに任せると PATH 上の古い node
        // (例: ~/.petclaw/node v22.14) に解決され "Node >=22.19 required" で即死するため、
        // ブリッジが選んだ node (>=22.19) で openclaw スクリプトを直接実行する。
        // (ACP 起動経路の wrapper と同じ理屈。cron list/add/rm・config set 全てに効く)
        let node = locateNode()
        let quoted = ([node, bin] + args)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        // 対話 zsh (-i) は SIGTERM を無視して居座り得るため、旧実装の「タイムアウト無し
        // waitUntilExit」をやめ、上限付き + SIGKILL エスカレーションの ProcessRunner で叩く。
        guard let r = ProcessRunner.run("/bin/zsh", ["-lic", quoted], timeout: timeout) else {
            return (-1, "", "spawn failed")
        }
        let stdout = String(data: r.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: r.stderr, encoding: .utf8) ?? ""
        if r.timedOut {
            return (-1, stdout, stderr.isEmpty ? "timeout after \(Int(timeout))s" : stderr)
        }
        return (r.status, stdout, stderr)
    }
}
