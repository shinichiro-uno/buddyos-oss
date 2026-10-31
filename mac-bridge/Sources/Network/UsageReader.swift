import Foundation

// MARK: - Wire model

/// 1 つの利用枠 (5 時間 or 週) の使用率スナップショット。
/// usedPercent は 0–100。resetsAt は ISO8601 文字列（クライアントは相対表示に整形）。
struct UsageWindow: Codable, Sendable {
    let usedPercent: Int
    let resetsAt: String?
    /// 300 = 5h, 10080 = week。任意（Claude エンドポイントは返さないので nil）。
    let windowMinutes: Int?
}

/// 1 プロバイダ分の使用状況。error が非 nil の場合は取得失敗（UI はグレー表示）。
struct ProviderUsage: Codable, Sendable {
    let provider: String          // "claude" | "codex" | "antigravity" | "antigravity:claude"
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDaySonnet: UsageWindow?   // Claude のみ（週・モデル別枠）
    let planType: String?
    /// コンテキスト圧迫率 0-100（context window に対する現在トークン）。取得不能時は nil。
    let contextPressure: Int?
    let error: String?
    /// 同じエージェントで枠が複数ある場合の表示名の補足（例: Antigravity の "Claude / GPT"）。
    var label: String? = nil

    static func failed(_ provider: String, _ message: String) -> ProviderUsage {
        ProviderUsage(provider: provider, fiveHour: nil, sevenDay: nil,
                      sevenDaySonnet: nil, planType: nil, contextPressure: nil, error: message)
    }

    /// データが取得できているか（エラー無し ＆ 何らかの枠がある）。UI の表示判定と同じ。
    var hasData: Bool { error == nil && (fiveHour != nil || sevenDay != nil) }
}

/// サイドバー/設定に出す全プロバイダの使用状況。content に JSON で載せて WS 配信する。
struct UsageReport: Codable, Sendable {
    let providers: [ProviderUsage]
}

// MARK: - Reader

/// Claude / Codex の使用量を「公式に降ってこない」経路から読み取る。
///   - Codex: `~/.codex/sessions/YYYY/MM/DD/*.jsonl` の最新 `token_count` イベントに
///            含まれる `rate_limits`（CLI が API レスポンスから保存している）を tail する。
///   - Claude: keychain (`Claude Code-credentials`) の OAuth トークンで
///            非公式 `api.anthropic.com/api/oauth/usage` を叩く。
/// どちらもサブスク枠の 5 時間 / 週リミットで、ACP 越しには取得できないため別系統で読む。
enum UsageReader {
    /// 使用量を読めるエージェント（id の "-" より前）。readAll に足したらここにも足す。
    static let agentBases: Set<String> = ["claude", "codex", "antigravity", "grok"]

    static func supports(_ agentId: String) -> Bool {
        let base = String(agentId.split(separator: "-").first ?? "")
        // Claude はログイン情報を読んで使用量の API を呼ぶので、BUDDYOS_CLAUDE_USAGE が on のときだけ。
        if base == "claude" { return BridgeConfig.current.claudeUsage.value }
        return agentBases.contains(base)
    }

    static func readAll() async -> UsageReport {
        // Claude の使用量は BUDDYOS_CLAUDE_USAGE（公開版の既定は off）。off ならログイン情報を読まず、API も呼ばない。
        let claudeEnabled = BridgeConfig.current.claudeUsage.value
        async let claude: [ProviderUsage] = claudeEnabled ? [readClaudeUsage()] : []
        let codex = await readCodexUsageLive()
        // agy は未導入・未ログインの Mac が多い。取得できないときは一覧に出さない（エラー行を増やさない）。
        let agy = await readAntigravityUsage().filter { $0.hasData }
        // grok も未ログインの Mac では出さない。
        let grok = await readGrokUsage().filter { $0.hasData }
        return UsageReport(providers: await claude + [codex] + agy + grok)
    }

    // MARK: Grok（ACP の `_x.ai/billing`）

    /// grok の使用率は ACP の独自メソッド `_x.ai/billing` が返す（モデルは呼ばない）。
    /// 例: {"config":{"creditUsagePercent":3.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"…"}},"subscription_tier":"X Premium"}
    nonisolated(unsafe) private static var grokCache: (at: Date, value: [ProviderUsage])?
    private static let grokLock = NSLock()
    private static let grokTTL: TimeInterval = 5 * 60

    static func readGrokUsage() async -> [ProviderUsage] {
        if let c = grokLock.withLock({ grokCache }), Date().timeIntervalSince(c.at) < grokTTL { return c.value }
        let exe = HeadlessCliAdapter.locateExecutable(.grok)
        guard exe.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: exe) else { return [] }
        let client = AcpClient(executable: exe, args: ["agent", "stdio"],
                               env: HeadlessCliAdapter.processEnvironment(for: .grok), loginShell: false)
        var value: [ProviderUsage] = []
        do {
            try client.start()
            defer { client.close() }
            _ = try await withTimeout(seconds: 20) {
                try await client.request("initialize", params: [
                    "protocolVersion": 1,
                    "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
                    "clientInfo": ["name": "BuddyOS-Bridge", "version": "0.1"]
                ])
            }
            let res = try await withTimeout(seconds: 20) { try await client.request("_x.ai/billing", params: [:]) }
            if let result = res["result"] as? [String: Any], let usage = parseGrokBilling(result) { value = [usage] }
        } catch {
            value = []
        }
        grokLock.withLock { grokCache = (Date(), value) }
        return value
    }

    /// 期間の種類（週・月・日）に合わせて枠に入れる。BuddyOS の表示は 5 時間と週の 2 枠なので、週以外も週の欄に出す。
    static func parseGrokBilling(_ result: [String: Any]) -> ProviderUsage? {
        guard let config = result["config"] as? [String: Any],
              let percent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue else { return nil }
        let period = config["currentPeriod"] as? [String: Any]
        let resetsAt = (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        let minutes: Int? = {
            switch period?["type"] as? String {
            case "USAGE_PERIOD_TYPE_WEEKLY": return 10_080
            case "USAGE_PERIOD_TYPE_DAILY": return 1_440
            default: return nil
            }
        }()
        let window = UsageWindow(usedPercent: Int(percent.rounded()), resetsAt: resetsAt, windowMinutes: minutes)
        return ProviderUsage(provider: "grok", fiveHour: nil, sevenDay: window, sevenDaySonnet: nil,
                             planType: result["subscription_tier"] as? String, contextPressure: nil, error: nil)
    }

    // MARK: Antigravity (`agy -p "/usage"`)

    /// 直近の取得結果。agy は起動にネットワークを使うので、60 秒ごとの poll では 5 分に 1 回しか呼ばない。
    /// 失敗もキャッシュする。agy はトークンが使えないとブラウザで OAuth を開き、タイムアウトで止めてもタブが残る。
    /// 失敗を覚えないと poll のたびにタブが 1 枚ずつ増える。
    nonisolated(unsafe) private static var agyCache: (at: Date, ttl: TimeInterval, value: [ProviderUsage])?
    private static let agyLock = NSLock()
    private static let agyTTL: TimeInterval = 5 * 60
    private static let agyFailureTTL: TimeInterval = 30 * 60
    /// タイムアウトはブラウザでのログイン待ちとみなし、長めに止める。
    private static let agyTimeoutTTL: TimeInterval = 3 * 60 * 60

    /// Antigravity のクォータは 2 つの枠（Gemini 系 / Claude・GPT 系）が別々で、それぞれ 5 時間と週の上限がある。
    /// 公開 API が無いため、CLI 自身の `/usage`（モデルを呼ばない）の出力を読む。
    static func readAntigravityUsage() async -> [ProviderUsage] {
        if let cached = agyLock.withLock({ agyCache.flatMap { Date().timeIntervalSince($0.at) < $0.ttl ? $0.value : nil } }) {
            return cached
        }

        guard let exe = antigravityExecutable() else { return [] }
        let tmp = NSTemporaryDirectory()
        // 最長 40 秒かかるので協調スレッドの外で待つ。
        let out = await ProcessRunner.runAsync(exe, ["--add-dir", tmp, "-p", "/usage"], timeout: 40, currentDirectory: tmp)
        let value: [ProviderUsage]
        let ttl: TimeInterval
        if let out, out.timedOut {
            value = []; ttl = agyTimeoutTTL
        } else if let out, out.status == 0 {
            value = parseAntigravityUsage(String(decoding: out.stdout, as: UTF8.self))
            ttl = value.isEmpty ? agyFailureTTL : agyTTL
        } else {
            value = []; ttl = agyFailureTTL
        }
        agyLock.withLock { agyCache = (Date(), ttl, value) }
        return value
    }

    private static func antigravityExecutable() -> String? {
        let candidates = [NSHomeDirectory() + "/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 行の形式（タブ区切り）: `Gemini Models\tWeekly Limit Remaining\t100%\t2026-10-10T13:54:09Z`
    /// 「残り」なので使用率は 100 から引く。
    static func parseAntigravityUsage(_ text: String) -> [ProviderUsage] {
        var pools: [String: (five: UsageWindow?, week: UsageWindow?)] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3, let remaining = Int(cols[2].replacingOccurrences(of: "%", with: "")) else { continue }
            let kind = cols[1].lowercased()
            let isWeek = kind.contains("weekly")
            guard isWeek || kind.contains("five hour") else { continue }
            let window = UsageWindow(usedPercent: max(0, min(100, 100 - remaining)),
                                     resetsAt: cols.count > 3 && !cols[3].isEmpty ? cols[3] : nil,
                                     windowMinutes: isWeek ? 10080 : 300)
            if pools[cols[0]] == nil { order.append(cols[0]) }
            var e = pools[cols[0]] ?? (nil, nil)
            if isWeek { e.week = window } else { e.five = window }
            pools[cols[0]] = e
        }
        return order.compactMap { name in
            guard let e = pools[name] else { return nil }
            let pool = antigravityPool(name)
            return ProviderUsage(provider: pool.provider,
                                 fiveHour: e.five, sevenDay: e.week, sevenDaySonnet: nil,
                                 planType: nil, contextPressure: nil, error: nil,
                                 label: pool.label)
        }
    }

    /// 枠の名前 → provider と表示名。共通の 2 つ（Gemini 系 / Claude・GPT 系）のほかに、
    /// モデル専用の枠（例: "Gemini 4 Argon" の週の上限）があるので、それは名前をそのまま出す（「Gemini」と取り違えない）。
    static func antigravityPool(_ name: String) -> (provider: String, label: String) {
        let n = name.lowercased()
        if n == "gemini models" { return ("antigravity", "Gemini") }
        if n.contains("claude") || n.contains("gpt") { return ("antigravity:claude", "Claude / GPT") }
        let slug = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        return ("antigravity:" + slug, name)
    }

    // MARK: Codex (live: app-server の account/rateLimits/read)

    private static let codexLiveLock = NSLock()
    nonisolated(unsafe) private static var codexLiveCache: (at: Date, value: ProviderUsage)?
    private static let codexLiveTTL: TimeInterval = 120

    /// Codex の使用量。まず `codex app-server` に今の値を直接尋ねる（`account/rateLimits/read`）。
    /// セッションのファイルは Codex を使ったときにしか書かれないので、しばらく使っていないと値が古く、
    /// 7 日以上使わないと一覧から消えていた（不安定の原因）。取れなければ従来のファイルを読む。
    static func readCodexUsageLive() async -> ProviderUsage {
        // セッションのファイルを読むのも同期の I/O なので、協調スレッドの外で読む。
        let file = await ProcessRunner.offload { readCodexUsage() }
        codexLiveLock.lock()
        if let c = codexLiveCache, Date().timeIntervalSince(c.at) < codexLiveTTL {
            codexLiveLock.unlock()
            return withContext(c.value, from: file)
        }
        codexLiveLock.unlock()
        let live: ProviderUsage? = await ProcessRunner.offload { fetchCodexRateLimits(timeout: 10) }
        guard let live else { return file }
        codexLiveLock.lock(); codexLiveCache = (Date(), live); codexLiveLock.unlock()
        return withContext(live, from: file)
    }

    /// 直近のセッションから取れるコンテキスト圧迫率は、live の値に引き継ぐ。
    private static func withContext(_ live: ProviderUsage, from file: ProviderUsage) -> ProviderUsage {
        guard let pressure = file.contextPressure else { return live }
        return ProviderUsage(provider: live.provider, fiveHour: live.fiveHour, sevenDay: live.sevenDay,
                             sevenDaySonnet: nil, planType: live.planType, contextPressure: pressure, error: nil)
    }

    /// `codex app-server`（stdio）を一時的に起動し、initialize → account/rateLimits/read の結果を返す。
    /// 未ログイン・未導入・タイムアウトは nil（呼び出し側がファイルに戻る）。
    static func fetchCodexRateLimits(timeout: TimeInterval) -> ProviderUsage? {
        guard let exe = ExecutableFinder.locate("codex") else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["app-server"]
        // Clerk のトークンは渡さない（他の codex の起動と同じ環境。ChildEnvironment）。
        proc.environment = CodexAppServerSession.spawnEnvironment()
        let inPipe = Pipe(), outPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        defer {
            try? inPipe.fileHandleForWriting.close()
            if proc.isRunning { proc.terminate() }
            try? outPipe.fileHandleForReading.close()
        }
        // codex がすぐ終了すると（設定エラー・node が見つからない等）書き込みが EPIPE になる。
        // 例外を投げる `write(_:)` だと Bridge ごと落ちるので、throws 版で nil に戻す。
        func send(_ obj: [String: Any]) -> Bool {
            guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
            do { try inPipe.fileHandleForWriting.write(contentsOf: d + Data([0x0A])); return true } catch { return false }
        }
        guard send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "buddyos-usage", "version": "1"]]]),
              send(["method": "initialized"]),
              send(["id": 2, "method": "account/rateLimits/read"]) else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        let fd = outPipe.fileHandleForReading.fileDescriptor
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (obj["id"] as? NSNumber)?.intValue == 2 else { continue }
                guard let result = obj["result"] as? [String: Any] else { return nil }
                return parseCodexRateLimits(result)
            }
        }
        return nil
    }

    /// `account/rateLimits/read` の result を ProviderUsage にする。epoch は秒。
    static func parseCodexRateLimits(_ result: [String: Any]) -> ProviderUsage? {
        guard let rl = result["rateLimits"] as? [String: Any] else { return nil }
        func window(_ raw: Any?) -> UsageWindow? {
            guard let w = raw as? [String: Any], let pct = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            var used = Int(pct.rounded())
            var resets: String?
            if let epoch = (w["resetsAt"] as? NSNumber)?.doubleValue {
                let d = Date(timeIntervalSince1970: epoch)
                if d > Date() { resets = iso8601(d) } else { used = 0 }
            }
            return UsageWindow(usedPercent: used, resetsAt: resets, windowMinutes: (w["windowDurationMins"] as? NSNumber)?.intValue)
        }
        let windows = codexWindows(primary: window(rl["primary"]), secondary: window(rl["secondary"]))
        guard windows.fiveHour != nil || windows.sevenDay != nil else { return nil }
        return ProviderUsage(provider: "codex", fiveHour: windows.fiveHour, sevenDay: windows.sevenDay, sevenDaySonnet: nil,
                             planType: rl["planType"] as? String, contextPressure: nil, error: nil)
    }

    // MARK: Codex (file tail)

    static func readCodexUsage() -> ProviderUsage {
        let sessionsDir = NSHomeDirectory() + "/.codex/sessions"
        guard FileManager.default.fileExists(atPath: sessionsDir) else {
            return .failed("codex", "Codex sessions directory not found")
        }
        let files = recentSessionFiles(sessionsDir: sessionsDir, maxDays: 7)
        guard !files.isEmpty else {
            return .failed("codex", "No recent Codex sessions found")
        }
        // 新しいファイルから順に、末尾の rate_limits を持つ token_count を探す。
        for path in files {
            if let usage = latestRateLimits(filePath: path) {
                return usage
            }
        }
        return .failed("codex", "No rate limit data found in recent Codex sessions")
    }

    /// sessions/YYYY/MM/DD/*.jsonl を更新時刻の新しい順に列挙（直近 maxDays 日）。
    private static func recentSessionFiles(sessionsDir: String, maxDays: Int) -> [String] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(maxDays) * 86_400)
        var found: [(path: String, mtime: Date)] = []
        func numeric(_ s: String, _ len: Int) -> Bool {
            s.count == len && s.allSatisfy(\.isNumber)
        }
        for year in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] where numeric(year, 4) {
            let yearDir = sessionsDir + "/" + year
            for month in (try? fm.contentsOfDirectory(atPath: yearDir)) ?? [] where numeric(month, 2) {
                let monthDir = yearDir + "/" + month
                for day in (try? fm.contentsOfDirectory(atPath: monthDir)) ?? [] where numeric(day, 2) {
                    let dayDir = monthDir + "/" + day
                    for entry in (try? fm.contentsOfDirectory(atPath: dayDir)) ?? [] where entry.hasSuffix(".jsonl") {
                        let p = dayDir + "/" + entry
                        guard let attrs = try? fm.attributesOfItem(atPath: p),
                              let mtime = attrs[.modificationDate] as? Date,
                              mtime >= cutoff else { continue }
                        found.append((p, mtime))
                    }
                }
            }
        }
        return found.sorted { $0.mtime > $1.mtime }.map(\.path)
    }

    /// JSONL を末尾から走査し、最新の token_count イベントの rate_limits を ProviderUsage に変換。
    private static func latestRateLimits(filePath: String) -> ProviderUsage? {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.contains("rate_limits"), line.contains("token_count") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            // token_count payload.info から context window と直近ターンのトークン数を拾い圧迫率を計算。
            // model_context_window はプラン毎（Plus=258400 等）。info は null のことがある（初回イベント等）→ nil（非表示）。
            // total_token_usage はセッション累計なので使わず、last_token_usage.total_tokens を現在のコンテキスト量とする
            // （cached_input_tokens は input_tokens の内数なので足さない）。payload 直下は旧形式のフォールバック。
            let info = payload["info"] as? [String: Any]
            let ctxWindow = (info?["model_context_window"] as? NSNumber)?.intValue
                ?? (payload["model_context_window"] as? NSNumber)?.intValue
                ?? (payload["context_limit"] as? NSNumber)?.intValue
            let lastUsage = info?["last_token_usage"] as? [String: Any]
            let totalTokens = (lastUsage?["total_tokens"] as? NSNumber)?.intValue
                ?? (payload["total_tokens"] as? NSNumber)?.intValue
            let windows = codexWindows(primary: codexWindow(rl["primary"]),
                                       secondary: codexWindow(rl["secondary"]))
            return ProviderUsage(
                provider: "codex",
                fiveHour: windows.fiveHour,
                sevenDay: windows.sevenDay,
                sevenDaySonnet: nil,
                planType: rl["plan_type"] as? String,
                contextPressure: Self.contextPressure(total: totalTokens, window: ctxWindow),
                error: nil
            )
        }
        return nil
    }

    private static func codexWindow(_ raw: Any?) -> UsageWindow? {
        guard let w = raw as? [String: Any], let pct = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        var usedPercent = Int(pct.rounded())
        var resetsAt: String?
        if let epoch = (w["resets_at"] as? NSNumber)?.doubleValue {
            let resetDate = Date(timeIntervalSince1970: epoch)
            if resetDate > Date() {
                resetsAt = iso8601(resetDate)
            } else {
                // token_count は Codex を使ったときにしか書かれないので、しばらく使っていないと
                // リセット済みの枠の古い % が残る。リセット時刻を過ぎていれば 0%・次回リセット時刻不明とする。
                usedPercent = 0
            }
        }
        let windowMinutes = (w["window_minutes"] as? NSNumber)?.intValue
        return UsageWindow(usedPercent: usedPercent, resetsAt: resetsAt, windowMinutes: windowMinutes)
    }

    /// primary / secondary を window_minutes で 5h / 週に振り分ける。プランによっては primary が
    /// 週枠（10080）で secondary が無い（prolite 等）ため、順序だけでは決められない。
    /// 1 日以下を 5h 側、それより長い枠を週側とみなす。window_minutes が無い枠は相手の逆側、
    /// 相手も不明なら従来どおり primary→5h / secondary→週。両方が同じ側に判定されたら従来の順序に戻す。
    private static func codexWindows(primary: UsageWindow?, secondary: UsageWindow?)
        -> (fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        func isWeekly(_ w: UsageWindow?) -> Bool? {
            guard let m = w?.windowMinutes, m > 0 else { return nil }
            return m > 24 * 60
        }
        let primaryKnown = isWeekly(primary)
        let secondaryKnown = isWeekly(secondary)
        let primaryWeekly = primaryKnown ?? secondaryKnown.map { !$0 } ?? false
        let secondaryWeekly = secondaryKnown ?? primaryKnown.map { !$0 } ?? true
        if primary != nil, secondary != nil, primaryWeekly == secondaryWeekly {
            return (primary, secondary)
        }
        var fiveHour: UsageWindow?
        var sevenDay: UsageWindow?
        if let primary {
            if primaryWeekly { sevenDay = primary } else { fiveHour = primary }
        }
        if let secondary {
            if secondaryWeekly { sevenDay = secondary } else { fiveHour = secondary }
        }
        return (fiveHour, sevenDay)
    }

    // MARK: Claude (oauth/usage endpoint)

    static func readClaudeUsage() async -> ProviderUsage {
        // トークンとプランは同じ資格情報から読む（keychain を読むたびに `security` が起動するので 1 回にまとめる）。
        // Keychain（security コマンド）とファイルの読み取りは同期なので、協調スレッドの外で読む。
        let oauth = await ProcessRunner.offload { bestClaudeOauth() }
        guard let token = oauth?["accessToken"] as? String, !token.isEmpty else {
            NSLog("[usage] claude: oauth token unavailable")
            return .failed("claude", "Claude OAuth token unavailable")
        }
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .failed("claude", "bad url")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                // 401 = トークン期限切れ（claude 利用時に keychain が更新されるので一時的）。
                // 429 = レート制限。UsageHub が前回成功値で埋めるので UI 上は問題ない。
                NSLog("[usage] claude: HTTP %d", code)
                return .failed("claude", "usage endpoint HTTP \(code)")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[usage] claude: usage decode failed")
                return .failed("claude", "usage decode failed")
            }
            return ProviderUsage(
                provider: "claude",
                fiveHour: claudeWindow(obj["five_hour"], windowMinutes: 300),
                sevenDay: claudeWindow(obj["seven_day"], windowMinutes: 10_080),
                sevenDaySonnet: claudeWindow(obj["seven_day_sonnet"], windowMinutes: 10_080),
                planType: oauth?["subscriptionType"] as? String,
                contextPressure: await ProcessRunner.offload { readClaudeContextPressure() },
                error: nil
            )
        } catch {
            NSLog("[usage] claude: %@", error.localizedDescription)
            return .failed("claude", error.localizedDescription)
        }
    }

    /// Claude エンドポイントの枠は `{utilization: Double, resets_at: ISO8601 String}`。
    private static func claudeWindow(_ raw: Any?, windowMinutes: Int) -> UsageWindow? {
        guard let w = raw as? [String: Any],
              let util = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = w["resets_at"] as? String
        return UsageWindow(usedPercent: Int(util.rounded()), resetsAt: resetsAt, windowMinutes: windowMinutes)
    }

    /// OAuth トークンを取得する。file と keychain の両方を読み、失効していない・
    /// expiresAt が新しい方を選ぶ。片方に古いトークンが残留していても（例: keychain 運用の
    /// Mac に昔の ~/.claude/.credentials.json が残るケース）、生きている方を使う。
    /// 失効トークンで毎分叩き続けると 401 に加え WAF のレート制限で 429 が連発し、
    /// Claude 使用量が永久に表示されなくなる実害があった（2026-07-06 実機で確認）。
    /// file / keychain 双方の claudeAiOauth を比較し、最も信頼できる方を返す。
    /// 優先順位: 未失効（expiresAt が先のもの優先）＞ expiresAt 不明 ＞ 失効済み。
    private static func bestClaudeOauth() -> [String: Any]? {
        let sources: [String?] = [
            try? String(contentsOfFile: NSHomeDirectory() + "/.claude/.credentials.json", encoding: .utf8),
            keychainCredentials(),
        ]
        let nowMillis = Date().timeIntervalSince1970 * 1000
        var best: [String: Any]?
        var bestScore = -Double.infinity
        for raw in sources {
            guard let raw, let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = obj["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { continue }
            let score: Double
            if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
                // 失効済みは大きく劣後（全ソース失効時のみ最後の手段として使う）
                score = expiresAt >= nowMillis ? expiresAt : expiresAt - 1e15
            } else {
                score = nowMillis  // 期限不明: 有効扱いだが、期限が明確に先のものを優先
            }
            if score > bestScore {
                bestScore = score
                best = oauth
            }
        }
        return best
    }

    /// macOS keychain から claude の認証情報 JSON を取り出す。
    /// launchd 配下では item ACL により拒否/プロンプトの可能性があり、失敗時は nil。
    /// 許可のダイアログが出たまま誰も押さないと security は戻らないので、5 秒で打ち切る
    /// （打ち切らないと UsageHub の refreshing が立ったままになり、使用量の更新が止まる）。
    private static func keychainCredentials() -> String? {
        #if os(macOS)
        guard let r = ProcessRunner.run(
            "/usr/bin/security", ["find-generic-password", "-w", "-s", "Claude Code-credentials"],
            timeout: keychainTimeout),
              !r.timedOut, r.status == 0 else { return nil }
        let s = String(data: r.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
        #else
        return nil
        #endif
    }

    static let keychainTimeout: TimeInterval = 5

    // MARK: Context pressure (近似)

    /// Claude Code の ~/.claude/projects 配下の最新 jsonl から直近 assistant 行の usage トークン積算と
    /// モデル別 context window（ハードコード）でコンテキスト圧迫率を近似する。
    /// jsonl は context window を記録しないため正確ではない（identity が [1m] か 200k 超なら 1M、それ以外は不明で nil）。
    /// usage / model は行トップではなく `message` の下にある。
    private static func readClaudeContextPressure() -> Int? {
        let projectsDir = NSHomeDirectory() + "/.claude/projects"
        guard let latest = mostRecentJsonl(in: projectsDir) else { return nil }
        // セッション jsonl は数十 MB になり得るので、毎分の poll では末尾だけ読む。
        guard let content = readTail(path: latest, maxBytes: 1_024 * 1_024) else { return nil }
        var totalTokens: Int?
        var model: String?
        for line in content.split(separator: "\n").reversed() {
            // "<synthetic>" は API エラー時の合成メッセージで usage が 0 なので飛ばす。
            guard line.contains("\"usage\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  (obj["isSidechain"] as? Bool) != true,
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let mdl = message["model"] as? String, mdl != "<synthetic>" else { continue }
            let input = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
            let cacheCreate = (usage["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
            totalTokens = input + cacheRead + cacheCreate + output
            model = mdl
            break
        }
        guard let total = totalTokens, let mdl = model,
              let window = claudeContextWindow(model: mdl) else { return nil }
        // 1M context でも message.model には "[1m]" が付かない（"claude-opus-5-5" のまま）ので、
        // identity 行の modelId（"claude-opus-5-5[1m]"）で判定する。セッション開始時の identity は
        // ファイル先頭にあるので、末尾に無ければ先頭も見る。途中で別モデルに切り替えた後の identity が
        // 読み範囲に無いと古いものを拾うので、直近の message.model と同じモデルのときだけ使う。
        let modelId = lastIdentityModelId(in: content)
            ?? readHead(path: latest, maxBytes: 256 * 1_024).flatMap { lastIdentityModelId(in: $0) }
        let is1M = modelId.map {
            $0.lowercased().contains("[1m]")
                && $0.replacingOccurrences(of: "[1m]", with: "", options: .caseInsensitive) == mdl
        } ?? false
        // 200k を超えていれば 1M 枠とみなす（200k 固定のままだと 100% に張り付く）。
        // それ以外は判定できない。"[1m]" が無くても 200k とは限らず（claude-fable-5-1 等は [1m] 無しで 1M）、
        // 200k 基準にすると 1M のセッションを最大 5 倍に過大表示して誤警告になるので非表示にする。
        guard is1M || total > window else { return nil }
        return contextPressure(total: total, window: 1_000_000)
    }

    /// jsonl の identity 行（attachment.type == "model"。セッション開始時とモデル切替時に書かれる）のうち
    /// 最後のものの modelId を返す。1M context なら "claude-opus-5-5[1m]" のように "[1m]" が付く。
    private static func lastIdentityModelId(in content: String) -> String? {
        for line in content.split(separator: "\n").reversed() {
            guard line.contains("\"identity\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["type"] as? String) == "attachment",
                  (obj["isSidechain"] as? Bool) != true,
                  let attachment = obj["attachment"] as? [String: Any],
                  (attachment["type"] as? String) == "model",
                  let identity = attachment["identity"] as? [String: Any],
                  let modelId = identity["modelId"] as? String else { continue }
            return modelId
        }
        return nil
    }

    /// Claude モデル名から context window を推定。claude-* 系は 200k、それ以外（GLM 等）は不明。
    private static func claudeContextWindow(model: String) -> Int? {
        let m = model.lowercased()
        if m.contains("claude") || m.contains("sonnet") || m.contains("opus") || m.contains("haiku") {
            return 200_000
        }
        return nil
    }

    /// 0-100 に切り詰めた圧迫率。total/window が nil または window<=0 なら nil。
    private static func contextPressure(total: Int?, window: Int?) -> Int? {
        guard let total = total, let window = window, window > 0 else { return nil }
        return min(100, total * 100 / window)
    }

    /// ディレクトリ階層配下の .jsonl を最新 mtime 順で1つ返す。
    private static func mostRecentJsonl(in root: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root) else { return nil }
        var found: [(path: String, mtime: Date)] = []
        guard let enumerator = fm.enumerator(atPath: root) else { return nil }
        while let entry = enumerator.nextObject() as? String {
            // サブエージェントの transcript（<session>/subagents/**）はメインのチャットではないので除外。
            if (entry as NSString).lastPathComponent == "subagents" {
                enumerator.skipDescendants()
                continue
            }
            guard entry.hasSuffix(".jsonl") else { continue }
            let p = root + "/" + entry
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let mtime = attrs[.modificationDate] as? Date {
                found.append((p, mtime))
            }
        }
        return found.sorted { $0.mtime > $1.mtime }.first?.path
    }

    // MARK: Helpers

    /// ファイル末尾の最大 maxBytes を文字列で返す。途中から読んだ場合、先頭の切れた行は捨てる。
    private static func readTail(path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd() else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            guard offset > 0 else { return text }
            guard let newline = text.firstIndex(of: "\n") else { return nil }
            return String(text[text.index(after: newline)...])
        } catch {
            return nil
        }
    }

    /// ファイル先頭の最大 maxBytes を文字列で返す。途中で切れた場合、末尾の切れた行は捨てる。
    private static func readHead(path: String, maxBytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard data.count >= maxBytes else { return text }
        guard let newline = text.lastIndex(of: "\n") else { return nil }
        return String(text[..<newline])
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
