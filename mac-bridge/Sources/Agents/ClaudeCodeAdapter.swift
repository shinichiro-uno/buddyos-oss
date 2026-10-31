import Foundation

final class ClaudeCodeAdapter: BridgeCronHosted {
    var id: String { profile.id }
    var displayName: String { profile.displayName }
    var capabilities: AgentCapabilities {
        AgentCapabilities(
            commands: true,
            models: true,
            skills: true,
            mcp: true,
            // 常駐プロセス化により、生成中の送信を予約キューに回さず stdin へ直接流せる。
            injectMidTurn: ClaudeCodeSession.midTurnInjection,
            // ultracode は xhigh + dynamic workflows の合成 tier（送信時に --effort xhigh 等へ展開）。
            efforts: ["low", "medium", "high", "xhigh", "max", "ultracode"],
            modes: ["plan", "edit", "auto", "dangerous"],
            // ターミナルの claude はフックで中継する（ClaudeTerminalRegistry）。
            terminal: true,
            // チャットを開いた時点で claude を起こしておける（ClaudeCodeSession.warm）。
            warm: true,
            // ~/.buddyos/main で開くと mainagent になる（MainAgentWorkspace）。
            orchestrate: true,
            // claude --bg のセッションの一覧・停止・削除（ClaudeBackgroundJobs）。claude の実行ファイルがあるときだけ。
            bgSessions: profile.id == "claude" && FileManager.default.isExecutableFile(atPath: executable)
        )
    }

    let profile: ClaudeProfile
    private let executable: String
    private let store: ClaudeCodeSessionStore

    init(
        profile: ClaudeProfile = .claude,
        executable: String = ClaudeCodeAdapter.locateExecutable(),
        store: ClaudeCodeSessionStore = .shared
    ) {
        self.profile = profile
        self.executable = executable
        self.store = store
    }

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        await openSession(sessionId: sessionId, cwd: cwd, options: nil)
    }

    func openSession(sessionId: String?, cwd: String?, options: SessionOptions?) async -> AgentSession {
        // その session がターミナルで生きていれば、自前で spawn せずそこへ attach する。
        // 同じ session を 2 プロセスで持つと会話が静かに二股になる（実測）ので、
        // 生きている側を優先し、Bridge は spawn しない。
        if let sid = sessionId, await ClaudeTerminalRegistry.shared.isLive(sid) {
            let session = ClaudeTerminalSession(agentId: id, sessionId: sid)
            await ClaudeTerminalRegistry.shared.attach(session)
            WebSocketServer.wslog("claude-code openSession → attach terminal session=\(sid.prefix(8))…")
            return session
        }
        // claude --bg のジョブの会話は、ワーカーが生きていれば受け箱で続け、ほかのプロセスが握っていれば見るだけにする
        // （BACKGROUND_CONTROL §7.8。どちらでもなければ下の -p --resume）。
        if profile.id == "claude", let sid = sessionId, let session = await openBackgroundSession(sessionId: sid) {
            return session
        }
        let resolvedCwd = await Self.resolveSessionCwd(cwd, resumingSessionId: sessionId)
        // ほかのセッションを操作する MCP の合鍵を渡す（mainagent のフォルダ、または設定 allSessions が有効なら
        // どのフォルダでも。無人実行には渡さない）。
        let grant = await Orchestrator.shared.sessionGrant(agentId: id, sessionId: sessionId, cwd: resolvedCwd,
                                                           unattended: options?.unattended == true,
                                                           heartbeat: options?.heartbeat == true)
        let mainToken = grant?.token
        let session = ClaudeCodeSession(
            agentId: id,
            profile: profile,
            initialSessionId: sessionId,
            cwd: resolvedCwd,
            executable: executable,
            store: store,
            permissionOverride: options?.permissionMode,
            // 無人実行（cron）は、job の権限が「エージェント設定に従う」（permissionMode = nil）でも
            // iPhone に尋ねない。尋ねると答える人が居ないまま 30 分止まる。尋ねなければ claude は
            // 許可されていない操作をその場で断り、ターンは最後まで進む。
            permissionPrompts: options?.unattended == true ? false : nil,
            mainToken: mainToken,
            mainRestricted: grant?.isMain ?? true
        )
        if let mainToken { await Orchestrator.shared.bind(token: mainToken, session: session) }
        return session
    }

    /// bg のジョブの sessionId なら、ワーカーの会話（worker）か、ほかのプロセスが握っている会話（elsewhere）を返す。
    /// どちらでもなければ nil。Bridge 自身の `-p`（BridgeSpawnedClaude）は握っているとは数えない。
    func openBackgroundSession(sessionId sid: String, jobs: ClaudeBackgroundJobs = .shared) async -> ClaudeBackgroundSession? {
        await jobs.ready()
        guard var entry = await jobs.entryFor(sessionId: sid) else { return nil }
        var mode: ClaudeBackgroundSession.Mode
        var holder: ClaudeBackgroundSession.Holder?
        if entry.row.live {
            mode = .worker
        } else {
            var excluded = BridgeSpawnedClaude.all
            if let pid = entry.pid { excluded.insert(pid) }
            guard let other = await jobs.holder(sessionId: sid, excluding: excluded) else { return nil }
            mode = .elsewhere
            holder = .init(pid: other.pid, entrypoint: other.entrypoint, status: other.status, procStart: other.procStart)
            // 握っているのが bg のワーカー自身なら、台帳が古いだけ（PC で respawn した直後）。読み直して worker にする
            // （「別の Claude Code で開かれています」で送信を断り続けない）。
            if other.kind == "bg" {
                await jobs.refresh()
                if let fresh = await jobs.entryFor(sessionId: sid), fresh.row.live {
                    entry = fresh
                    mode = .worker
                    holder = nil
                }
            }
        }
        let session = ClaudeBackgroundSession(agentId: id, sessionId: sid, mode: mode, host: jobs, holder: holder)
        await session.start()
        WebSocketServer.wslog("claude-code openSession → bg \(mode == .worker ? "worker" : "elsewhere") session=\(sid.prefix(8))…")
        return session
    }

    /// spawn 用 cwd の解決。未指定のまま spawn すると bridge プロセスの cwd（インストール版では
    /// アプリバンドル内の bin ディレクトリ）を継承し、履歴が `~/.claude/projects` の誰も開かない
    /// スラグに紐づいてターミナル側の /resume に出なくなる。新規セッションはホームに固定し、
    /// resume は transcript に記録された cwd に合わせる（--resume は cwd 不一致だと解決できない）。
    static func resolveSessionCwd(_ cwd: String?, resumingSessionId: String?) async -> String {
        if let normalized = normalizedCwd(cwd) { return normalized }
        if let sid = resumingSessionId,
           let recorded = await ClaudeCodeProjectsScanner.shared.cwd(forSessionId: sid) {
            return recorded
        }
        return NSHomeDirectory()
    }

    // MARK: - Cron (BridgeCronHosted: Bridge 内蔵スケジューラへ委譲)
    //
    // claude CLI は常駐スケジューラを持たない (公式の Desktop 定期タスク / Routines も
    // 「常駐プロセスが発火ごとに新規セッションを起動する」方式)。BuddyOS では launchd
    // 常駐の Bridge がその役を担う。


    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] {
        let normalized = Self.normalizedCwd(cwd)
        let fromScanner = await ClaudeCodeProjectsScanner.shared.listSessions(limit: limit, cwd: normalized)
        let fromStore = await store.list(agentId: id, limit: limit, cwd: normalized)

        var seen = Set<String>()
        var merged: [SessionSummary] = []
        for summary in fromScanner where seen.insert(summary.sessionId).inserted {
            merged.append(summary)
        }
        for summary in fromStore where seen.insert(summary.sessionId).inserted {
            merged.append(summary)
        }
        // ターミナルで開かれている session は印を付けて先頭に固定する。開いた直後で transcript が
        // まだ無い session は一覧に居ないので、台帳の情報から行を作って足す。
        if id == "claude" {
            let liveEntries = await ClaudeTerminalRegistry.shared.liveEntries()
                .filter { normalized == nil || Self.normalizedCwd($0.cwd) == normalized }
            let liveIds = Set(liveEntries.map(\.sessionId))
            for i in merged.indices where liveIds.contains(merged[i].sessionId) {
                merged[i].terminal = true
            }
            for entry in liveEntries where seen.insert(entry.sessionId).inserted {
                merged.append(SessionSummary(
                    sessionId: entry.sessionId,
                    title: "ターミナル",
                    lastActive: ISO8601DateFormatter().string(from: entry.startedAt),
                    messageCount: nil,
                    cwd: entry.cwd,
                    terminal: true
                ))
            }
        }
        let sorted = merged.sorted {
            if $0.terminal != $1.terminal { return $0.terminal }
            return $0.lastActive > $1.lastActive
        }
        return Array(sorted.prefix(max(1, limit)))
    }

    func loadHistory(sessionId: String) async -> [HistoryMessage] {
        // claude --bg のジョブなら、読み終えた位置を会話に渡す（同じ行を履歴と live の両方に出さない。§7.8）。
        if profile.id == "claude", await ClaudeBackgroundJobs.shared.entryFor(sessionId: sessionId) != nil,
           let read = await ClaudeCodeProjectsScanner.shared.loadHistoryRead(sessionId: sessionId) {
            BgHistoryFeed.shared.note(sessionId: sessionId, file: read.file, end: read.end)
            if !read.messages.isEmpty { return read.messages }
            return await store.history(agentId: id, sessionId: sessionId)
        }
        if let fromScanner = await ClaudeCodeProjectsScanner.shared.loadHistory(sessionId: sessionId),
           !fromScanner.isEmpty {
            return fromScanner
        }
        return await store.history(agentId: id, sessionId: sessionId)
    }

    func listCommands() async -> [CommandInfo] {
        // 1) クライアント側で実際に動くもの。
        //    plan/options は専用プロンプトへ変換、model/effort/mode は BuddyOS の UI を開く。
        //    （`-p` では /model・/effort 等のビルトインは "not available" になり生テキストでは効かない）
        var commands: [CommandInfo] = [
            .init(id: "plan", kind: "prompt", title: "plan", subtitle: "Plan first, show options, and wait"),
            .init(id: "options", kind: "prompt", title: "options", subtitle: "Present 2-3 choices with a recommendation"),
            .init(id: "model", kind: "ui", title: "model", subtitle: "モデル設定を開く"),
            .init(id: "effort", kind: "ui", title: "effort", subtitle: "推論の強さ（Ultracode 等）"),
            .init(id: "mode", kind: "ui", title: "mode", subtitle: "権限モード（Plan/Edit/Auto/Dangerous）")
        ]
        // 2) エージェントが実際に公開する slash command（init の slash_commands）。
        //    goal / loop 系 / 各 skill・plugin を含む。SKILL.md を持つものは skill 扱い（トグル）、
        //    それ以外は command 扱い（/id をそのまま送る＝-p で実行される）。
        let skillCmds = ClaudeSkillsScanner.listSkillCommands()
        let skillIds = Set(skillCmds.map { $0.id })
        let descById = Dictionary(skillCmds.compactMap { c in c.subtitle.map { (c.id, $0) } },
                                  uniquingKeysWith: { a, _ in a })
        if let names = Self.resolvedSlashCommands, !names.isEmpty {
            for name in names.sorted() {
                commands.append(CommandInfo(
                    id: name,
                    kind: skillIds.contains(name) ? "skill" : "command",
                    title: name,
                    subtitle: descById[name]
                ))
            }
        } else {
            // init 未取得（このセッションでまだ起動していない）時は disk スキャンの skill のみ。
            commands.append(contentsOf: skillCmds)
        }
        return commands
    }

    /// claude の stream-json init で判明した解決済みモデル ID (例 "claude-opus-5-5")。
    /// settings.json の alias "opus" でなく、実際に使われたモデルを表示するためのキャッシュ。
    /// ClaudeCodeSession が stream から検出して更新する。
    /// 複数セッションの読み取り task と currentInfo() から並行アクセスされるためロックで保護。
    private static let resolvedModelLock = NSLock()
    // agentId ごとに分離する。
    nonisolated(unsafe) private static var _resolvedModel: [String: String] = [:]
    static func resolvedModel(for agentId: String) -> String? {
        resolvedModelLock.withLock { _resolvedModel[agentId] }
    }
    static func setResolvedModel(_ model: String?, for agentId: String) {
        resolvedModelLock.withLock { _resolvedModel[agentId] = model }
    }

    /// stream-json init の `slash_commands`（エージェントが実際に公開する全コマンド
    /// = skill / plugin / goal / loop 等）。コマンドパレットの正規ソース。
    /// セッション起動の init 行で更新され、listCommands() が参照する。
    nonisolated(unsafe) private static var _resolvedSlashCommands: [String]?
    static var resolvedSlashCommands: [String]? {
        get { resolvedModelLock.withLock { _resolvedSlashCommands } }
        set { resolvedModelLock.withLock { _resolvedSlashCommands = newValue } }
    }

    /// 「設定されたモデル」を返す。`~/.claude/settings.json` を読み、
    /// env `BUDDYOS_CLAUDE_MODEL` があればそれを最優先する。
    static func configuredModel() -> String? {
        if let env = nonEmpty(ProcessInfo.processInfo.environment["BUDDYOS_CLAUDE_MODEL"]) {
            return env
        }
        return readModelFromSettings()
    }

    private static func modelDotfileURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".buddyos")
            .appendingPathComponent(name)
    }

    static func readModelDotfile(_ name: String) -> String? {
        guard let s = try? String(contentsOf: modelDotfileURL(name), encoding: .utf8) else { return nil }
        return nonEmpty(s)
    }

    static func writeModelDotfile(_ name: String, _ model: String) {
        guard let v = nonEmpty(model) else { return }
        let url = modelDotfileURL(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? v.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    func currentInfo() async -> AgentInfo? {
        // 実際に解決されたモデル(例 claude-opus-5-5)を最優先で表示する。
        // alias("opus")しか無い設定より、実 stream で判明した実 ID を出す。
        return AgentInfo(
            model: Self.resolvedModel(for: id) ?? Self.configuredModel(),
            provider: profile.provider,
            // 既定は ~/.claude/settings.json の effortLevel（モデル別 > 全体）。無ければ CLI の既定 high。
            reasoningEffort: Self.readEffort(model: Self.resolvedModel(for: id)) ?? "high",
            // Permission mode (Plan/Edit/Auto/Dangerous). Default "auto" = `--permission-mode default`.
            codexMode: Self.readMode() ?? "auto"
        )
    }

    /// BuddyOS effort tiers for Claude Code. low/medium/high/xhigh/max map 1:1 to
    /// `claude --effort`. "ultracode" is a BuddyOS composite (xhigh + dynamic
    /// workflow orchestration) reproduced at spawn time — the CLI rejects
    /// "ultracode" as an --effort value, so it is translated in argsForPrompt().
    static let validEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max", "ultracode"]

    /// `claude --effort` が実際に受け付ける値（init での検証: low/medium/high/xhigh/max）。
    /// BuddyOS tier の "ultracode" はこの集合に含まれない。
    static let cliEffortValues: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// BuddyOS の effort tier を実際の `claude --effort` 値へ変換する。
    /// "ultracode" は CLI に無いので xhigh へ落とし、workflow 有効化
    /// (environment() の CLAUDE_CODE_WORKFLOWS=1) と指示文の付与
    /// (argsForPrompt() の --append-system-prompt) で composite を再現する。
    static func cliEffort(for tier: String) -> String {
        tier == "ultracode" ? "xhigh" : tier
    }

    /// 対話モードの `/effort ultracode` が注入する「常時 Workflow 活用」姿勢を、
    /// 非対話 (`-p`) spawn でも再現するための追記システムプロンプト。
    static let ultracodeDirective = """
    Ultracode mode is on. Optimize for the most exhaustive, correct result over speed or cost. For every substantive task, use the Workflow tool to orchestrate multiple subagents — decompose and fan out in parallel, verify findings adversarially, then synthesize. Work solo only on trivial or purely conversational turns.
    """

    /// BuddyOS のアプリから使われていることを伝える追記システムプロンプト。
    /// アプリは返事の中の画像パスを画像として表示し（今は Android。iOS は未対応）、localhost の URL はプレビューで開ける。
    // 画像のパスを画像として出すのは Android だけ（iOS とデスクトップには /files/image の表示が無い）。
    // プロセスはどの端末から送られるか分からないので、「表示される」とは言わず、パスを書くことだけを頼む。
    static let clientDirective = """
    You are being used through the BuddyOS mobile app, not a plain terminal. The app renders your replies as Markdown and turns references into previews:
    - When the user wants to see an image file, write its path (absolute, ~/..., or relative to the working directory), e.g. `docs/screenshot.png`, instead of saying images cannot be displayed. Some versions of the app show such paths as images, but not all of them do, so do not claim the image is displayed.
    - localhost URLs (e.g. http://localhost:3000) open as a live preview of the dev server on this Mac.
    """

    static let settingsPath = ".claude/settings.json"

    /// `~/.buddyos/claude.effort`。CLI に無い "ultracode" を既定にしたときだけ使う（BuddyOS 独自の tier）。
    private static func effortURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".buddyos")
            .appendingPathComponent("claude.effort")
    }

    private static func ultracodeIsDefault() -> Bool {
        guard let s = try? String(contentsOf: effortURL(), encoding: .utf8) else { return false }
        return s.trimmingCharacters(in: .whitespacesAndNewlines) == "ultracode"
    }

    /// 既定の effort。`~/.claude/settings.json` の `modelSettings.<model>.effortLevel` → `effortLevel`
    /// （CLI と同じ優先順）。ultracode を既定にしていればそれ。
    /// - Parameter model: 解決済みのモデル ID（例 claude-opus-5-5）。nil なら claude の解決済みモデル。
    static func readEffort(model: String? = nil) -> String? {
        if ultracodeIsDefault() { return "ultracode" }
        guard let obj = JsonSettingsFile.read(settingsPath) else { return nil }
        let modelId = model ?? resolvedModel(for: "claude") ?? defaultModelKey(in: obj)
        if let modelId,
           let perModel = (obj["modelSettings"] as? [String: Any])?[modelId] as? [String: Any],
           let v = perModel["effortLevel"] as? String, cliEffortValues.contains(v) {
            return v
        }
        if let v = obj["effortLevel"] as? String, cliEffortValues.contains(v) { return v }
        return nil
    }

    /// 既定の effort を `~/.claude/settings.json` に書く（ターミナルの Claude Code と共通の既定）。
    /// モデル別の effortLevel があると top-level が負けるので、そちらも揃える。
    /// ultracode は CLI に無いので settings には xhigh を書き、BuddyOS の印を別に残す。
    static func writeEffort(_ effort: String) throws {
        let v = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validEfforts.contains(v) else { return }
        let cli = cliEffort(for: v)
        let modelId = resolvedModel(for: "claude")
        try JsonSettingsFile.update(settingsPath) { obj in
            applyEffort(cli, model: modelId, to: &obj)
        }
        if v == "ultracode" {
            let url = effortURL()
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? v.data(using: .utf8)?.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: effortURL())
        }
    }

    /// まだ応答が無くモデルが分からないとき、settings.json の `model`（例 "opus"）に当たるモデル別の項目。
    /// 1 つに絞れたときだけ返す（CLI はそのモデル別の値を使うので、表示も合わせる）。
    static func defaultModelKey(in obj: [String: Any]) -> String? {
        guard let alias = (obj["model"] as? String)?.lowercased(), !alias.isEmpty,
              let all = obj["modelSettings"] as? [String: Any] else { return nil }
        if all[alias] != nil { return alias }
        let hits = all.keys.filter { $0.lowercased().contains(alias) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// settings.json の中身に既定の effort を書く。今のモデルが分かればそのモデル別の値だけを、
    /// 分からなければ（Bridge の起動直後でまだ一度も応答していないなど）モデル別の値を全部揃える。
    /// 分からないときに top-level だけを書くと、CLI はモデル別の値（例 claude-opus-5-5 = high）を使い、
    /// 画面の表示だけが変わって実際の effort は変わらなかった。
    static func applyEffort(_ cli: String, model modelId: String?, to obj: inout [String: Any]) {
        obj["effortLevel"] = cli
        guard var all = obj["modelSettings"] as? [String: Any] else { return }
        for (key, value) in all {
            guard modelId == nil || key == modelId,
                  var perModel = value as? [String: Any], perModel["effortLevel"] != nil else { continue }
            perModel["effortLevel"] = cli
            all[key] = perModel
        }
        obj["modelSettings"] = all
    }

    // MARK: - Permission mode (Plan / Edit / Auto / Dangerous)
    //
    // 既定は `~/.claude/settings.json` の `permissions.defaultMode`（ターミナルの Claude Code と共通）。
    // BuddyOS の UI ラベルと CLI の値を相互に変換する。
    // Codex の plan/auto/dangerous とは別物（Claude Code 固有の権限モード）。
    static let validModes: Set<String> = ["plan", "edit", "auto", "dangerous"]

    /// CLI の defaultMode → BuddyOS のラベル。CLI の "auto"（自動判定）と "default" はどちらも Auto に寄せる。
    static func modeLabel(forCliMode value: String?) -> String? {
        switch value {
        case "plan": return "plan"
        case "acceptEdits": return "edit"
        case "default", "auto": return "auto"
        case "bypassPermissions": return "dangerous"
        default: return nil
        }
    }

    static func readMode() -> String? {
        let perms = JsonSettingsFile.read(settingsPath)?["permissions"] as? [String: Any]
        return modeLabel(forCliMode: perms?["defaultMode"] as? String)
    }

    /// 既定の権限モードを `permissions.defaultMode` に書く。今の値が同じラベルに当たるなら書き換えない
    /// （CLI の "auto" を BuddyOS の Auto＝"default" で上書きしない）。
    static func writeMode(_ mode: String) throws {
        let v = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard validModes.contains(v), readMode() != v, let cli = permissionFlag(forMode: v) else { return }
        try JsonSettingsFile.update(settingsPath) { obj in
            var perms = obj["permissions"] as? [String: Any] ?? [:]
            perms["defaultMode"] = cli
            obj["permissions"] = perms
        }
    }

    /// BuddyOS のモードラベルを `claude --permission-mode` の実値へ変換する。
    static func permissionFlag(forMode mode: String?) -> String? {
        switch mode {
        case "plan": return "plan"
        case "edit": return "acceptEdits"
        case "auto": return "default"
        case "dangerous": return "bypassPermissions"
        default: return nil
        }
    }

    /// Claude Code の設定ファイル群を優先順位付きで走査し、最初に見つかった
    /// `"model"` を返す。alias ("opus" / "sonnet" / "haiku") もそのまま返す。
    ///
    /// 走査順:
    ///   1. `~/.claude/settings.json`       — メイン
    ///   2. `~/.claude/settings.local.json` — ユーザーローカル override
    ///   3. `~/.claude.json`                — root config (古い CLI ver)
    /// 各ファイルで top-level `"model"` → `"defaultModel"` → `"user.model"` を試行。
    /// 失敗内容は stderr に診断ログを書き出す。
    static func readModelFromSettings() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            (home as NSString).appendingPathComponent(".claude/settings.json"),
            (home as NSString).appendingPathComponent(".claude/settings.local.json"),
            (home as NSString).appendingPathComponent(".claude.json")
        ]
        for path in candidates {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                FileHandle.standardError.write(Data("[claude.currentInfo] parse fail: \(path)\n".utf8))
                continue
            }
            if let m = nonEmpty(obj["model"] as? String) {
                FileHandle.standardError.write(Data("[claude.currentInfo] model=\(m) (from \(path) top-level)\n".utf8))
                return m
            }
            if let m = nonEmpty(obj["defaultModel"] as? String) {
                FileHandle.standardError.write(Data("[claude.currentInfo] model=\(m) (from \(path) defaultModel)\n".utf8))
                return m
            }
            if let user = obj["user"] as? [String: Any], let m = nonEmpty(user["model"] as? String) {
                FileHandle.standardError.write(Data("[claude.currentInfo] model=\(m) (from \(path) user.model)\n".utf8))
                return m
            }
        }
        FileHandle.standardError.write(Data("[claude.currentInfo] no model key found in any settings file\n".utf8))
        return nil
    }

    func listAvailableModels() async -> [ProviderCatalog] {
        profile.catalog
    }

    /// 既定のモデル/effort/mode を保存する。claude CLI 自身の `~/.claude/settings.json` に書くので、
    /// ターミナルの Claude Code と既定を共有する（チャット単位の変更は SessionOverrides 側で、ここは通らない）。
    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?) async throws {
        if let effort = reasoningEffort, Self.validEfforts.contains(effort) {
            try Self.writeEffort(effort)
        }
        if let codexMode, Self.validModes.contains(codexMode.lowercased()) {
            try Self.writeMode(codexMode)
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try JsonSettingsFile.update(Self.settingsPath) { $0["model"] = trimmed }
        // 保存できた時だけ解決済みキャッシュをクリアする。失敗時に消すと、モデルは変わっていないのに
        // currentInfo() が（壊れた settings.json を読み飛ばして）別の値や空を返す。
        Self.setResolvedModel(nil, for: id)
    }

    static func locateExecutable() -> String {
        if let override = nonEmpty(ProcessInfo.processInfo.environment["CLAUDE_BIN"]) {
            return override
        }
        return ExecutableFinder.locate("claude") ?? "claude"
    }

    private static func normalizedCwd(_ cwd: String?) -> String? {
        guard let cwd = nonEmpty(cwd) else { return nil }
        let home = NSHomeDirectory()
        if cwd == "~" { return home }
        if cwd.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        return (cwd as NSString).standardizingPath
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class ClaudeCodeSession: AgentSession, SessionOverridable, VoiceTurnAware {
    private(set) var sessionId: String
    let events: AsyncThrowingStream<SessionEvent, Error>

    private let agentId: String
    private let profile: ClaudeProfile
    private let cwd: String?
    private let executable: String
    private let store: ClaudeCodeSessionStore
    /// per-run のモード上書き (cron 等の無人実行)。nil なら `~/.buddyos/claude.mode` を読む。
    private let permissionOverride: String?
    /// 承認が要る操作を iPhone に尋ねるか。無人実行（permissionOverride あり）は答える人が居ないので既定で false。
    private let permissionPrompts: Bool
    /// mainagent の合鍵（Orchestrator）。あれば Bridge の MCP を渡す。閉じたら無効にする。
    let mainToken: String?
    /// mainagent のフォルダのセッションか。true なら書く道具を外し、権限モードを default に固定する。
    /// ふつうのセッション（false）は MCP だけを足す。
    let mainRestricted: Bool
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private var didEmitSessionStarted: Bool
    private var resolvedSessionId: String?
    // セッション 1 本につき claude プロセスを 1 つ常駐させる。
    //
    // 以前は send() のたびに `claude -p <prompt> --resume <sid>` を起動して終了まで
    // 待つ使い捨て方式だった。会話の文脈は transcript 経由で繋がるが、プロセスは
    // 毎回生まれて死ぬので「いま動いている場所」が存在せず、iPhone とデスクトップの
    // 2 画面で同じセッションを見ても、それぞれが自分の送信分しか目撃できなかった。
    //
    // `-p --input-format stream-json` は stdin から user メッセージを 1 行ずつ受け取り、
    // プロセスを生かしたまま複数ターンを続ける（実測: 2 ターン送って result 2 行、
    // session_id は 1 種類）。stdout のリーダーをプロセス寿命で 1 本回し、その出力を
    // continuation に流せば、SessionHub が既に持つ fan-out で全購読者に届く。
    //
    // 停止: stdin に制御要求（control_request の interrupt）を書くと、ターンだけが
    // result error_during_execution で閉じ、プロセスは生き続ける（実測 2.1.300。SIGINT ではプロセスごと終わる）。
    // プロセスを起こすたびに initialize{perTaskStopAffordance:true} を宣言する。宣言した CLI の interrupt は
    // 背景のサブエージェント・コマンド・dynamic workflow を止めない（行ごとの停止は stopTask の stop_task）。
    // 返事が来なければ、背景の作業が動いている間はプロセスを残してターンだけ閉じ（2 回続けたら止める）、
    // 動いていなければ今までどおりプロセスグループを止め、次の send() で `--resume <sid>` を付けて再起動する。
    // 文脈は transcript が保つ。
    private let procLock = NSLock()
    private var process: Process?
    /// 現行 process の世代。spawn ごとに +1。ターンと stdout の行を「どのプロセスのものか」で
    /// 照合し、終了途中の旧プロセスの出力や終了処理が新しいプロセスのターンを畳まないようにする。
    private var processGeneration = 0
    private var stdinWriter: FileHandle?
    private var readerTask: Task<Void, Never>?
    /// interrupt() でシグナルを送った世代。その終了はエラーではなく done で畳む。
    private var interruptedGenerations = Set<Int>()
    /// 起動済みで終了処理（handleProcessExit）をまだ終えていない世代。
    /// 終了処理済みの世代に書いたターンは誰も畳まないので、send() は登録しない。
    private var liveGenerations = Set<Int>()
    /// interrupt() で外した終了待ちの旧プロセス。次の spawn はこれの終了を待つ。
    private var dyingProcess: Process?
    private var closed = false
    /// 起こしている間にワーカーが起きた（stderr の running in the background）。procLock で守る。
    private var backgroundUnusable = false
    /// 未完了のターン（stdin に流した発話と、CLI が自分から始めた知らせのターン）。stdout の行がどのターンのものかは
    /// 世代ごとの ClaudeTurnRouter が決める（stdin の user 行に付けた uuid で結ぶ。docs/BACKGROUND_WORK_2026-10-21.md §3.3）。
    /// 発話 1 つに result 1 つとは限らない（知らせのターン・生成中の差し込みの合流）ので、FIFO では数えない。
    private struct Turn {
        let messageId: String
        let generation: Int
        var assistant = ""
        var sawTextDelta = false
        /// 送った時刻（最初の文字・完了までの時間をログに出す）。
        var sentAt = Date()
        var waiter: CheckedContinuation<Void, Never>?
        /// 知らせのターン（バックグラウンドの作業が終わって CLI が始めた。発話も、待つ人もいない）
        var notification = false
    }
    private var turns: [Turn] = []
    /// プロセスの世代ごとの、stdout の行とターンの結び付け。procLock で保護する。
    private var routers: [Int: ClaudeTurnRouter] = [:]
    /// send() の前半（store 記録・プロセス起動・ターン登録と stdin 書き込み）を呼び出し順に直列化する
    /// 鎖の末尾。内部の await で並行 send が追い越すと、claude に届く発話の順序が入れ替わる。
    /// ターンの result を待つのは鎖の外（生成中の注入を止めない）。procLock で保護する。
    private var writeTail: OneShotSignal?
    /// チェックリスト進捗の蓄積状態。TaskCreate で作成順に 1-indexed の id を振り、
    /// TaskUpdate で status を更新、TodoWrite なら全置換。procLock で保護する
    /// （read ループが更新し、send() がアイドルからの新しいターンでだけ作り直す）。
    private struct PlanTask { let id: String; var subject: String; var activeForm: String?; var status: String }
    private var planTasks: [PlanTask] = []
    /// サブエージェントとバックグラウンドのコマンドの進行（taskId "subagents" のカード）。procLock で保護する。
    private var subagents = SubagentTracker()
    /// dynamic workflow（task_id → 名前と最後の行）。終わっていない間は設定の変化での起こし直しを延ばし、
    /// プロセスが終わったとき・close で閉じる payload を出す。終わったものも、後の知らせに名前を載せるために
    /// 次の新しいターン（アイドルからの送信）まで覚えておく。procLock で保護する。
    private struct WorkflowCard {
        var name: String?
        var agents: [[String: Any]] = []
        /// 宣言された phase（{index, title}）。workflow_progress を運んだ行で作り直す。
        var phases: [[String: Any]] = []
        var finished = false
        /// カード全体の停止を CLI に頼んで返事を待っている
        var stopRequested = false
    }
    private var workflows: [String: WorkflowCard] = [:]
    /// 終わっていない dynamic workflow があるか。procLock を持って呼ぶ。
    private var hasUnfinishedWorkflowLocked: Bool { workflows.values.contains { !$0.finished } }
    /// interrupt() が書いた停止の制御要求。返事（control_response）か中断の result が来るまで持つ。procLock で保護する。
    private struct PendingInterrupt {
        let requestId: String
        let generation: Int
        /// 止めると決めたときにあったターン（発話と知らせ）。後から送った発話は閉じない。
        let targets: Set<String>
        /// 中断の result などで、止めるターンを done で畳んだ
        var settled = false
        /// 返事がエラーだった（今までどおりプロセスを止める）
        var refused = false
    }
    private var pendingInterrupt: PendingInterrupt?
    /// 停止の返事を待つ時間。来なければ、背景の作業が無いときは今までどおりプロセスグループを止める。
    static let interruptGraceNanos: UInt64 = 3_000_000_000
    /// 返事の来なかった interrupt の回数（世代ごと。返事が来たら戻す）。2 回続いたら背景の作業があっても止める。procLock で保護する。
    private var unackedInterrupts: [Int: Int] = [:]
    /// 返事が来ないままプロセスを残した interrupt の request_id → 世代。遅れて返事が来たら CLI は生きていたので数え直す。procLock で保護する。
    private var keptInterruptIds: [String: Int] = [:]
    /// 起動時に書いた initialize の request_id → 世代。返事は subtype だけを見る。procLock で保護する。
    private var pendingInitialize: [String: Int] = [:]
    /// initialize が success だった世代。行の停止（stop_task）が使える。procLock で保護する。
    private var stopTaskGenerations = Set<Int>()
    /// dynamic workflow のカード全体の停止が使える世代（止まらなかったら外す）。procLock で保護する。
    private var workflowStopGenerations = Set<Int>()
    /// CLI に頼んだ stop_task（request_id → 行かカード・世代・待っている呼び出し）。procLock で保護する。
    private var pendingStops: [String: PendingStop] = [:]
    /// stop_task の control_response を待つ時間。
    var stopReplyNanos: UInt64 = 5_000_000_000
    /// dynamic workflow の停止の後、カードが終わるのを待つ時間。
    var workflowEndNanos: UInt64 = 5_000_000_000

    private enum StopTarget: Equatable {
        case row(String)
        case workflow(String)
    }

    private enum StopReply {
        case success
        case error(String)
        case timeout
        /// 返事を待つ間にプロセスが終わった（書けなかった場合を含む）
        case exited
    }

    private final class PendingStop {
        let target: StopTarget
        let generation: Int
        var reply: StopReply?
        var owner: CheckedContinuation<StopReply, Never>?
        /// 同じ行（カード）への 2 つ目以降の停止。持ち主の結果を待つ。
        var joiners: [CheckedContinuation<StopTaskOutcome, Never>] = []

        init(target: StopTarget, generation: Int) {
            self.target = target
            self.generation = generation
        }
    }
    /// iPhone の返事待ちの承認・質問（requestId → 内容）。procLock で保護する。
    /// 返事は stdin に control_response で書く（ClaudeControlProtocol）。プロセスが替われば無効。
    private struct PendingAction {
        let generation: Int
        let request: ClaudeControlProtocol.ToolRequest
        let isQuestion: Bool
    }
    private var pendingActions: [String: PendingAction] = [:]
    /// send() を呼んだ回数。warm() で起こしたプロセスが、その後に使われたかを見る。procLock で保護する。
    private var sendCount = 0
    /// 書き込み（ターンの登録）がまだ済んでいない send の数。interrupt() が「止めるターンが無い」と
    /// 誤って判断しないよう、登録前の送信もターン中として数える。procLock で保護する。
    private var sendsInFlight = 0
    /// 最後に done で畳んだターンの messageId。止めるターンが無い interrupt に同じ done を返す。procLock で保護する。
    private var lastFinishedMessageId: String?
    /// warm() で起こしたまま送られなければ、この時間で畳む（次の send() がまた起こす）。
    static let warmIdleNanos: UInt64 = 5 * 60 * 1_000_000_000
    /// stdin への書き込みを 1 行ずつ直列化する。send()（生成中の注入を含む）と承認の返事が
    /// 並行に書くと、長い行が途中で混ざって壊れる。
    private let stdinWriteLock = NSLock()
    /// このチャットだけのモデル / Effort / モード（iOS が送信ごとに渡す）。procLock で保護する。
    private var overrides = SessionOverrides.none
    /// 現行プロセスを起動したときの設定（configSignature）。設定が変わったら次の送信で起こし直す。procLock で保護する。
    private var spawnedSignature: String?

    init(
        agentId: String,
        profile: ClaudeProfile,
        initialSessionId: String?,
        cwd: String?,
        executable: String,
        store: ClaudeCodeSessionStore,
        permissionOverride: String? = nil,
        permissionPrompts: Bool? = nil,
        mainToken: String? = nil,
        mainRestricted: Bool = true
    ) {
        self.agentId = agentId
        self.mainToken = mainToken
        self.mainRestricted = mainRestricted
        self.profile = profile
        self.cwd = cwd
        self.executable = executable
        self.store = store
        self.permissionOverride = permissionOverride
        self.permissionPrompts = permissionPrompts ?? (permissionOverride == nil)
        self.resolvedSessionId = initialSessionId
        self.sessionId = initialSessionId ?? "pending-\(UUID().uuidString.prefix(8))"
        self.didEmitSessionStarted = initialSessionId != nil

        var continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { c in
            continuation = c
        }
        self.continuation = continuation
    }

    /// 生成中に届いた send を、現ターンを止めずに stdin へ流す。
    /// 実測: 長いターンの 6 秒後に 2 通目を流すと、1 通目は最後まで完走し、2 通目は
    /// その直後にフォローアップとして処理された（result 2 行、session_id 1 種類）。
    /// 2.1.300 ではツールの区切りで今のターンに合流し、result は 2 通分で 1 つになる（probe-uuid U2。
    /// ClaudeTurnRouter が両方のターンを閉じる）。
    /// iOS の「注入対応 = 現ターンを止めずフォローアップとして即送信」と一致する。
    static let midTurnInjection = true
    var supportsMidTurnInjection: Bool { Self.midTurnInjection }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        await send(text, skills: skills, attachments: attachments, voice: nil)
    }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment], voice: VoiceTurn?) async {
        let messageId = UUID().uuidString
        procLock.withLock { sendCount += 1; sendsInFlight += 1 }
        // 履歴・表示用の本文。画像は「attached」の目印だけが残る（実画像は AttachmentStore 側が保持）。
        let prompt = promptText(text: text, skills: skills, attachments: attachments)
        // 音声会話の応え方の指示と遮られた注記は、このターンのモデル入力の末尾にだけ付ける。
        // 起動引数（system prompt / effort）には入れない。入れると通常と音声が切り替わるたびに
        // claude を起こし直し（実測 4〜5.6 秒）、プロンプトのキャッシュも効かなくなる。
        let voiceSuffix = voice?.contextBlock(includeDirective: true) ?? ""
        // モデルには画像ブロックで実画像を渡す（目印の文字だけだと Claude は画像を見られない。実測）。
        let inlineImages = Self.inlineImages(attachments)
        let content: Any = inlineImages.isEmpty
            ? prompt + voiceSuffix
            : Self.contentBlocks(
                text: promptText(text: text, skills: skills, attachments: attachments, inlinedImages: inlineImages) + voiceSuffix,
                images: inlineImages)
        // 先行する send の書き込みが終わるまで待つ（呼び出し順に直列化）。
        let written = OneShotSignal()
        // 書き込みが済んだ（または書けなかった）時点で後続の send を通し、登録前の数から外す。
        let delivered = { [self] in
            procLock.withLock { sendsInFlight -= 1 }
            written.signal()
        }
        procLock.lock()
        let previousWrite = writeTail
        writeTail = written
        procLock.unlock()
        await previousWrite?.wait()
        retireProcessIfConfigChanged()
        await store.ensureSession(agentId: agentId, sessionId: sessionId, cwd: cwd)
        await store.appendMessage(agentId: agentId, sessionId: sessionId, role: "user", content: prompt, cwd: cwd)

        // 生きているプロセスがあればそれに流す。無ければ（初回 / interrupt 後 / 異常終了後）
        // ここで起動する。--resume を付けるので文脈は前回までの transcript から復元される。
        let target: (writer: FileHandle, generation: Int)
        let genBefore = procLock.withLock { process != nil ? processGeneration : -1 }
        do {
            target = try await ensureProcess()
            WebSocketServer.wslog("claude-code turn send voice=\(voice != nil ? 1 : 0) process=\(target.generation == genBefore ? "reuse" : "spawn") gen=\(target.generation) session=\(sessionId)")
        } catch {
            delivered()
            emitTurnError(messageId: messageId, "Claude Code spawn failed: \(error.localizedDescription)")
            return
        }

        // stream-json 入力の 1 行。改行区切りで 1 メッセージ。
        // uuid を付けると、CLI が command_lifecycle と user_message_uuid(s) でこの発話のターンを名指しする（§3.3）。
        let envelope: [String: Any] = [
            "type": "user",
            "uuid": messageId.lowercased(),
            "message": ["role": "user", "content": content],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            delivered()
            emitTurnError(messageId: messageId, "Claude Code stdin unavailable")
            return
        }

        // ターンを登録してから書く。書いてから登録すると、応答が速い場合に
        // リーダー側が対応するターンを見つけられない。
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            // 書き込みが済んだ（または書けなかった）時点で後続の send を通す。
            defer { delivered() }
            procLock.lock()
            // 書き込み先のプロセスが既に終了処理を済ませていれば、登録しても誰も畳まない。
            guard liveGenerations.contains(target.generation) else {
                procLock.unlock()
                emitTurnError(messageId: messageId, "Claude Code exited before the message was delivered")
                waiter.resume()
                return
            }
            // アイドルからの新しいターンだけチェックリストを作り直し、終わった行を捨てる（アプリの新しいターンと同じ時点）。
            // 生成中の注入（中断していないターン・知らせのターンが残っている）では消さない。知らせのターンは開いた時点で
            // 空の activity を出すので、本文の前でも SessionHub とアプリには生成中に見えている（どちらもこの送信で捨てない）。
            if !turns.contains(where: { !interruptedGenerations.contains($0.generation) }) {
                planTasks.removeAll()
                subagents.pruneFinished()
                workflows = workflows.filter { !$0.value.finished }
            }
            turns.append(Turn(messageId: messageId, generation: target.generation, waiter: waiter))
            routers[target.generation, default: ClaudeTurnRouter()].register(messageId: messageId)
            procLock.unlock()
            do {
                try writeLine(data, to: target.writer)
            } catch {
                // 書けない = プロセスが死んでいる。ターンをエラーで畳んで待機を解く。
                // 終了処理が先に畳んでいれば、そちらが done と待機解除を済ませている（二重 resume しない）。
                procLock.lock()
                let removed = turns.firstIndex { $0.messageId == messageId }.map { turns.remove(at: $0) }
                routers[target.generation]?.unregister(messageId: messageId)
                procLock.unlock()
                guard removed != nil else { return }
                emitTurnError(messageId: messageId, "Claude Code stdin write failed: \(error.localizedDescription)")
                waiter.resume()
            }
        }
        // ここに戻るのは、このターンの result（または interrupt / 異常終了）をリーダーが処理した後。
    }

    /// ターンをエラーで終える。.error だけだと SessionHub の generating / phase が戻らず
    /// 「考え中」が固着するので、同じ messageId の done を続けて流す（BuddySession.emitError と同じ）。
    private func emitTurnError(messageId: String, _ message: String) {
        continuation.yield(SessionEvent(
            type: .error, agentId: agentId, sessionId: sessionId, messageId: messageId,
            toolUseId: nil, content: message, toolName: nil, metadata: nil
        ))
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
    }

    /// 常駐プロセスを起動し、stdout リーダーをプロセス寿命で 1 本回す。既に生きていればそれを返す。
    /// 戻り値は書き込み先の stdin と、そのプロセスの世代。
    private func ensureProcess() async throws -> (writer: FileHandle, generation: Int) {
        // interrupt() で外した旧プロセスが終了処理中なら、transcript を書き終えるのを待ってから
        // --resume で起こし直す（同じ jsonl に 2 プロセスが同時に書かないように）。
        await waitForDyingProcess()

        // 生きているプロセスがあれば、起動の準備（ファイル読み・Pipe 作成）をせずにそれへ流す。
        // 常駐プロセスへの注入や通常の続き送信は毎回ここを通る。
        procLock.lock()
        if !closed, let p = process, p.isRunning, let writer = stdinWriter {
            let gen = processGeneration
            procLock.unlock()
            return (writer, gen)
        }
        procLock.unlock()

        // 起動の準備（sessionArgs はファイルを読む）はロックの外で済ませる。
        // 準備中に並行する send() が先に起動していれば、この Process は run せずに捨てるだけ。
        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let signature = configSignature()
        configure(process: proc)
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr
        // 終了は waitUntilExit（スレッドを塞ぐ）ではなく、run() 前に設定した terminationHandler で受ける。
        let exited = OneShotSignal()
        proc.terminationHandler = { _ in exited.signal() }

        // 確認から起動・代入までを 1 つの排他区間にする。分けると並行する send() が
        // 両方とも「プロセス無し」を見て claude を 2 本起動し、先の 1 本が誰にも閉じられず残る。
        procLock.lock()
        if closed {
            procLock.unlock()
            throw NSError(domain: "ClaudeCodeSession", code: 1, userInfo: [NSLocalizedDescriptionKey: "session closed"])
        }
        if let p = process, p.isRunning, let writer = stdinWriter {
            let gen = processGeneration
            procLock.unlock()
            return (writer, gen)
        }
        do {
            try proc.run()
        } catch {
            procLock.unlock()
            throw error
        }

        // 子プロセスを独自プロセスグループのリーダーにする (AcpClient と同じ方式)。
        // claude が spawn した子孫もグループごと kill でき、interrupt/close 後の
        // orphan プロセス残留を防ぐ。失敗しても ESRCH/EACCES になるだけで害はない。
        // SpawnRegistry は自前のロックだけを使うので procLock の中で呼んでよい（終了処理の unregister より必ず先に登録する）。
        let pid = proc.processIdentifier
        if pid > 0 {
            _ = setpgid(pid, pid)
            SpawnRegistry.register(pid: pid, command: "claude " + (proc.arguments ?? []).joined(separator: " "))
            BridgeSpawnedClaude.add(pid)
        }
        let writer = stdin.fileHandleForWriting
        // 終了済みプロセスへの書き込みで SIGPIPE（Bridge ごと終了）にならず、EPIPE として throw させる。
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        processGeneration += 1
        let gen = processGeneration
        process = proc
        stdinWriter = writer
        spawnedSignature = signature
        liveGenerations.insert(gen)
        routers[gen] = ClaudeTurnRouter()
        // 行ごとの停止の宣言。最初の user 行より前に書く（返事は待たない。warm・--resume でも）。返事が来るまで停止は使えない。
        _ = subagents.setClaudeStopTask(false)
        let initializeId = UUID().uuidString.lowercased()
        pendingInitialize[initializeId] = gen
        if let data = try? JSONSerialization.data(withJSONObject: ClaudeControlProtocol.initializeRequest(requestId: initializeId)) {
            try? writeLine(data, to: writer)
        }

        // 読み取りは協調スレッドプールを塞がないよう readabilityHandler（GCD）で受ける。
        // availableData のブロッキング読みを Task 上で回すと、常駐セッション数がコア数に
        // 達した時点で Bridge 全体の async 処理（WS / HTTP / SessionHub）が止まる。
        // run() 成功後に登録する（無効 fd へ dispatch source を張らないため）。
        let chunks = PipeChunks.stream(stdout.fileHandleForReading)
        // stderr は常時読んで末尾だけ保持する（終了時にしか読まないと、長時間の常駐で
        // パイプ容量を超えたところで claude 側の write がブロックする）。
        let stderrTail = PipeTailBuffer()
        stderrTail.start(stderr.fileHandleForReading)
        readerTask = Task { [weak self] in
            await self?.readLoop(chunks: chunks, stderr: stderrTail, exited: exited, process: proc, generation: gen)
        }
        procLock.unlock()

        WebSocketServer.wslog("claude-code session process started pid=\(pid) gen=\(gen) session=\(sessionId) \(Self.spawnSummary(args: proc.arguments ?? [])) settingsEffort=\(ClaudeCodeAdapter.readEffort() ?? "-")")
        return (writer, gen)
    }

    /// interrupt() でシグナルを送った旧プロセスの終了を短時間待つ。落ちなければ SIGKILL。
    private func waitForDyingProcess() async {
        procLock.lock()
        let dying = dyingProcess
        procLock.unlock()
        guard let dying else { return }
        for _ in 0..<30 where dying.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let pid = dying.processIdentifier
        if dying.isRunning, pid > 0 {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        procLock.lock()
        if dyingProcess === dying { dyingProcess = nil }
        procLock.unlock()
    }

    /// stdout を行単位で読み、イベントに変換して流す。プロセスが終わるまで戻らない。
    /// chunk の境界は UTF-8 の文字境界と一致しないので、Data のまま改行で切ってから行単位でデコードする。
    private func readLoop(
        chunks: AsyncStream<Data>,
        stderr: PipeTailBuffer,
        exited: OneShotSignal,
        process proc: Process,
        generation gen: Int
    ) async {
        var splitter = PipeLineSplitter()
        for await chunk in chunks {
            for rawLine in splitter.feed(chunk) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { await handleLine(line, generation: gen) }
            }
        }
        // 改行で終わらない末尾（書き込み途中で死んだ行）は壊れた JSON なので捨てる。
        await exited.wait()
        await handleProcessExit(proc, stderr: stderr, generation: gen)
    }

    private func handleLine(_ line: String, generation gen: Int) async {
        // 承認・質問の制御行（--permission-prompt-tool stdio）と、こちらが書いた制御要求（停止）への返事。
        // 本文ではないので parseLine には渡さない。
        if let control = ClaudeControlProtocol.parse(line) {
            if case .response(let response) = control {
                await handleControlResponse(response, generation: gen)
            } else {
                handleControl(control, generation: gen)
            }
            return
        }
        let obj = line.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        procLock.lock()
        let idle = !turns.contains { $0.generation == gen } && (routers[gen]?.isIdle ?? true)
        procLock.unlock()
        // warm() で送る前に起こしたプロセスは、起動してすぐ SessionStart の hook の行（session_id 付き）を出す。
        // まだ発話が無く transcript も作られていないので、ここで session を確定（session_started）させない
        // （覚えた ID で --resume すると「会話が無い」で失敗する）。確定は最初の発話の後の行で行う。
        if idle, Self.isHookLine(line) { return }

        // どのターンの行かを決める。発話のターンは uuid で結び、発話の無い出力は知らせのターンとして開く。
        procLock.lock()
        let sawTextDelta = routers[gen]?.sawTextDelta ?? false
        let step: ClaudeTurnRouter.Step
        if let obj {
            step = routers[gen, default: ClaudeTurnRouter()].ingest(obj)
        } else {
            step = routers[gen, default: ClaudeTurnRouter()].routeRawText()
        }
        if let id = step.openedNotification {
            turns.append(Turn(messageId: id, generation: gen, notification: true))
        }
        let switchedFromText = step.switchedFrom.map { prev in
            turns.contains { $0.messageId == prev && !$0.assistant.isEmpty }
        } ?? false
        procLock.unlock()
        if let id = step.openedNotification {
            WebSocketServer.wslog("claude-code notification turn started gen=\(gen) session=\(sessionId)")
            // 最初の本文が来るまで（1〜数秒。thinking やツールが先に走ればもっと長い）、SessionHub とアプリには何も届かず
            // アイドルに見える。その間に解放・sweep で閉じられると CLI ごと止まり、報告も done も push も消える。
            // 空の activity で生成中にする（終わりは必ず done。本文の無い知らせのターンは silent の done）。
            continuation.yield(.activity(agentId: agentId, sessionId: sessionId, messageId: id, text: ""))
        }
        if let prev = step.switchedFrom, switchedFromText {
            // 差し込んだ発話（か、知らせのターンに合流した発話）が始まった。ここまでの吹き出しを区切り、
            // 以後の本文はその発話の下の新しい吹き出しに出す（アプリは次の差分を新しい吹き出しにする）。
            continuation.yield(.assistantTurnEnd(agentId: agentId, sessionId: sessionId, messageId: prev))
        }

        let parsed = parseLine(obj, line: line, sawTextDelta: sawTextDelta)
        if let sid = parsed.sessionId {
            await updateSessionIdIfNeeded(sid)
        }
        // 解決済みモデルを検出したらキャッシュ更新＋クライアントへ通知 → モデル表示が自動で実IDになる。
        // iOS は agentInfoResult を全置換のスナップショットとして扱うので、currentInfo() と同じ
        // effort / mode も載せる（載せないと mode 表示が auto に化け、effort が消える）。
        // チャットでモデルを上書きしているときは、エージェント既定の表示を書き換えない。
        if let model = parsed.model, !model.isEmpty, currentOverrides.model == nil,
           ClaudeCodeAdapter.resolvedModel(for: agentId) != model {
            ClaudeCodeAdapter.setResolvedModel(model, for: agentId)
            continuation.yield(.agentInfoResult(
                agentId: agentId,
                model: model,
                provider: profile.provider,
                reasoningEffort: ClaudeCodeAdapter.readEffort(model: model) ?? "high",
                codexMode: ClaudeCodeAdapter.readMode() ?? "auto"
            ))
        }

        // CLI のターンの終わり。stream-json では `type: "result"` の行がターン境界。
        // 1 つの result が、合流した差し込みの発話を含む複数のターンと、開いている知らせのターンを閉じる。
        if step.isResult {
            // ターンが終わったのに返事待ちが残っていれば、もう誰も待っていない。カードを閉じる。
            // 背景のサブエージェントの承認は、その子がまだ待っているので閉じない。
            resolvePendingActions(generation: gen, mainOnly: true)
            // ターンが普通に終わった（CLI は生きている）。interrupt に返事が無かった数を戻す。
            procLock.withLock {
                unackedInterrupts.removeValue(forKey: gen)
                keptInterruptIds = keptInterruptIds.filter { $0.value != gen }
            }
            // 中断した後の残り・閉じるターンの無い result は、本文にも done にも使わない。
            guard let closure = step.closure else { return }
            // 部分メッセージを受けていない場合、parseLine は result 本文を text として返す。
            // その最終テキストを done を出すターンに反映してから畳む。
            if !sawTextDelta, let delta = parsed.text, !delta.isEmpty, let mid = closure.doneMessageId {
                _ = appendText(delta, to: mid, markDelta: false)
                emitSessionStartedIfNeeded()
                continuation.yield(.assistantDelta(delta, agentId: agentId, sessionId: sessionId, messageId: mid))
            }
            await closeTurns(closure, generation: gen)
            return
        }
        // command_lifecycle で閉じるターン（始まる前に終わった・取り消された発話）。
        if let closure = step.closure {
            await closeTurns(closure, generation: gen)
        }

        if let delta = parsed.text, !delta.isEmpty {
            emitSessionStartedIfNeeded()
            if !step.swallowed, let mid = step.output {
                if let ms = appendText(delta, to: mid, markDelta: true) {
                    WebSocketServer.wslog("claude-code turn first-delta ms=\(ms) session=\(sessionId)")
                }
                continuation.yield(.assistantDelta(delta, agentId: agentId, sessionId: sessionId, messageId: mid))
            }
        } else if parsed.sessionId != nil {
            emitSessionStartedIfNeeded()
        }
        guard let obj else { return }
        // dynamic workflow (system/task_*) の進捗を正規化してクライアントへ。
        if let wfPayload = workflowEventPayload(from: obj) {
            continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: wfPayload))
        }
        // サブエージェントとバックグラウンドのコマンドの進行も workflow カードとして送る。
        if let saPayload = subagentPayload(from: obj) {
            continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: saPayload))
        }
        // チェックリスト進捗（TaskCreate/TaskUpdate/TodoWrite）を全置換スナップショットで送る。
        if let planPayload = planSnapshotPayload(from: obj) {
            continuation.yield(.planUpdate(agentId: agentId, sessionId: sessionId, entriesJSON: planPayload))
        }
    }

    /// SessionStart などの hook の進み具合の行（type: system, subtype: hook_started / hook_response）。
    static func isHookLine(_ line: String) -> Bool {
        guard line.contains("\"hook_"), let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "system" else { return false }
        return (obj["subtype"] as? String)?.hasPrefix("hook_") == true
    }

    /// ターンに本文を足す。発話のターンで最初の差分なら、送ってからの時間（ms）を返す（ログ用）。
    private func appendText(_ text: String, to messageId: String, markDelta: Bool) -> Int? {
        procLock.lock(); defer { procLock.unlock() }
        guard let idx = turns.firstIndex(where: { $0.messageId == messageId }) else { return nil }
        let first = markDelta && !turns[idx].sawTextDelta && !turns[idx].notification
        turns[idx].assistant += text
        if markDelta { turns[idx].sawTextDelta = true }
        return first ? Int(Date().timeIntervalSince(turns[idx].sentAt) * 1000) : nil
    }

    /// ルーターが閉じると決めたターンを畳む。各ターンの本文を store に残して send() の待機を解き、
    /// done は最後のターンの messageId で 1 回だけ出す（知らせのターンだけなら metadata.origin = "task-notification"）。
    /// 知らせのターンは終わった行を捨てない（pruneFinished は送信のときだけ）。
    /// - 本文の無い知らせのターンも done で閉じる（開いたときの activity で生成中になっているので、閉じないと SessionHub と
    ///   アプリの生成中が残る）。見せるものは無いので metadata.silent = "1" を付ける（SessionHub はこの done で push しない）。
    /// - まだ終わっていない発話（stdin に書いたが CLI が始めていない・書く前の送信）が残っていれば、metadata.pending = "1"
    ///   を付ける。その発話の done は後から来るので、SessionHub はこの done でターンを終わりにしない（閉じると発話ごと止まる）。
    private func closeTurns(_ closure: ClaudeTurnRouter.Closure, generation gen: Int) async {
        let ids = closure.messageIds + (closure.notificationId.map { [$0] } ?? [])
        procLock.lock()
        var closed: [Turn] = []
        for id in ids {
            if let idx = turns.firstIndex(where: { $0.messageId == id && $0.generation == gen }) {
                closed.append(turns.remove(at: idx))
            }
        }
        let hasText = closed.contains { !$0.assistant.isEmpty }
        let doneTurn: Turn? = closure.emitsDone
            ? (closed.first { $0.messageId == closure.doneMessageId } ?? closed.last) : nil
        let silent = doneTurn.map { $0.notification && !hasText } ?? false
        let promptPending = doneTurn != nil && (sendsInFlight > 0 || turns.contains { !$0.notification })
        if let t = doneTurn, !silent { lastFinishedMessageId = t.messageId }
        // 止めると決めたターンを畳んだら、停止は済んだ（interrupt() はプロセスを止めない）。
        if doneTurn != nil, var pending = pendingInterrupt, pending.generation == gen,
           closed.contains(where: { pending.targets.contains($0.messageId) }) {
            pending.settled = true
            pendingInterrupt = pending
        }
        procLock.unlock()
        guard !closed.isEmpty else { return }
        let main = doneTurn ?? closed[closed.count - 1]
        WebSocketServer.wslog("claude-code turn done ms=\(Int(Date().timeIntervalSince(main.sentAt) * 1000)) turns=\(closed.count) notification=\(closure.notificationId != nil) interrupted=\(closure.interrupted) done=\(doneTurn != nil) silent=\(silent) pending=\(promptPending) session=\(sessionId)")

        if doneTurn != nil { emitSessionStartedIfNeeded() }
        for turn in closed where !turn.assistant.isEmpty {
            await store.appendMessage(
                agentId: agentId, sessionId: sessionId, role: "assistant",
                content: turn.assistant, cwd: cwd, messageId: turn.messageId
            )
        }
        if let doneTurn {
            // 本文の無い発話のターンには今までどおり空の差分を流す（本文の無い知らせのターンには流さない。見せるものが無い）。
            if !hasText, !closure.interrupted, !silent {
                continuation.yield(.assistantDelta("", agentId: agentId, sessionId: sessionId, messageId: doneTurn.messageId))
            }
            var metadata: [String: String] = [:]
            if closure.notificationOnly { metadata["origin"] = "task-notification" }
            if silent { metadata["silent"] = "1" }
            if promptPending { metadata["pending"] = "1" }
            let done = SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: doneTurn.messageId)
            continuation.yield(metadata.isEmpty ? done : done.addingMetadata(metadata))
        }
        for turn in closed { turn.waiter?.resume() }
    }

    /// この世代の残りのターンを全部畳む（プロセスが終わった）。done は最後のターンで 1 回。
    private func closeRemainingTurns(generation gen: Int, interrupted: Bool) async {
        procLock.lock()
        let remaining = turns.filter { $0.generation == gen }
        procLock.unlock()
        var closure = ClaudeTurnRouter.Closure()
        closure.messageIds = remaining.filter { !$0.notification }.map(\.messageId)
        closure.notificationId = remaining.last { $0.notification }?.messageId
        closure.interrupted = interrupted
        await closeTurns(closure, generation: gen)
        // 知らせのターンが 2 つ残ることは無いが、残っていれば待機の無いまま捨てる。
        procLock.lock()
        turns.removeAll { $0.generation == gen && $0.notification }
        procLock.unlock()
    }

    /// プロセス終了。自分で止めた（interrupt・設定の変化・close）なら進行中ターンを done で畳み、そうでなければエラー。
    /// このプロセス（世代）の未処理ターンが残っていれば全部畳んで send() の待機を解く（リークさせない）。
    /// 別の世代のターン（interrupt 後に起動し直した新しいプロセス宛て）には触れない。
    private func handleProcessExit(_ proc: Process, stderr: PipeTailBuffer, generation gen: Int) async {
        procLock.lock()
        let wasInterrupted = interruptedGenerations.remove(gen) != nil
        liveGenerations.remove(gen)
        routers.removeValue(forKey: gen)
        if pendingInterrupt?.generation == gen { pendingInterrupt = nil }
        unackedInterrupts.removeValue(forKey: gen)
        keptInterruptIds = keptInterruptIds.filter { $0.value != gen }
        pendingInitialize = pendingInitialize.filter { $0.value != gen }
        stopTaskGenerations.remove(gen)
        workflowStopGenerations.remove(gen)
        // 待っている停止は、プロセスが終わったので not_running。
        var stopOwners: [(CheckedContinuation<StopReply, Never>)] = []
        for entry in pendingStops.values where entry.generation == gen && entry.reply == nil {
            entry.reply = .exited
            if let owner = entry.owner { stopOwners.append(owner); entry.owner = nil }
        }
        if process === proc { process = nil; stdinWriter = nil }
        if dyingProcess === proc { dyingProcess = nil }
        let pid = proc.processIdentifier
        let stoppedByUs = wasInterrupted || closed
        // プロセスと一緒にバックグラウンドのサブエージェント・コマンド・dynamic workflow も終わる。終わりの知らせ
        // （task_notification）はもう来ないので、実行中の行と終わっていない workflow を閉じる（閉じないとカードが
        // 「実行中」のまま残る）。自分で止めた・正常に終わったなら stopped、異常終了だけ failed。
        let crashed = !stoppedByUs && proc.terminationStatus != 0
        let abandoned = subagents.abandonRunning(state: crashed ? "failed" : "stopped")
        let closings = abandonWorkflowsLocked(state: crashed ? "failed" : "stopped")
        procLock.unlock()
        for owner in stopOwners { owner.resume(returning: .exited) }
        if pid > 0 { SpawnRegistry.unregister(pid: pid); BridgeSpawnedClaude.remove(pid) }
        WebSocketServer.wslog("claude-code session process exited status=\(proc.terminationStatus) interrupted=\(wasInterrupted) gen=\(gen) session=\(sessionId)")
        resolvePendingActions(generation: gen)
        if let abandoned {
            continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: abandoned))
        }
        for payload in closings {
            continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: payload))
        }

        if stoppedByUs {
            // ユーザーが停止した（か close した）。エラー扱いにせず、途中までの出力を確定して done。
            await closeRemainingTurns(generation: gen, interrupted: true)
            return
        }

        // stderr は別スレッドで読んでいるので、最後の出力が届くのを短時間だけ待つ。
        await stderr.waitForEOF()
        let errText = stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 起こした間にワーカーが起きていた（claude --bg のジョブ）。stderr をそのまま出さず、次に送ると受け箱へ届くようにする。
        if let jobId = Self.backgroundJobId(inStderr: errText) {
            procLock.withLock { backgroundUnusable = true }
            let message = "この会話は PC のバックグラウンド（\(jobId)）でまた動き始めました。もう一度送ると、そちらに届けます。"
            while true {
                procLock.lock()
                guard let idx = turns.firstIndex(where: { $0.generation == gen }) else { procLock.unlock(); break }
                let turn = turns.remove(at: idx)
                procLock.unlock()
                emitTurnError(messageId: turn.messageId, message)
                turn.waiter?.resume()
            }
            WebSocketServer.wslog("claude-code session saw running in the background job=\(jobId) session=\(sessionId)")
            Task { await Self.refreshBackgroundJobs() }
            return
        }

        if proc.terminationStatus != 0 {
            let message = errText.isEmpty ? "Claude Code exited \(proc.terminationStatus)" : errText
            // 進行中ターンにはエラー（＋ done）を返し、待機を解く。
            while true {
                procLock.lock()
                guard let idx = turns.firstIndex(where: { $0.generation == gen }) else { procLock.unlock(); break }
                let turn = turns.remove(at: idx)
                procLock.unlock()
                emitTurnError(messageId: turn.messageId, message)
                turn.waiter?.resume()
            }
            return
        }

        // 正常終了（stdin が閉じられた等）。未完了ターンが残っていれば done で畳む。
        await closeRemainingTurns(generation: gen, interrupted: false)
    }

    func interrupt() async {
        // 送ったばかりで stdin に書く前の発話しか無ければ、登録を少しだけ待つ（止める相手を決めてから書く）。
        for _ in 0..<20 {
            let unregistered = procLock.withLock {
                sendsInFlight > 0 && !turns.contains { !interruptedGenerations.contains($0.generation) }
            }
            guard unregistered else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        procLock.lock()
        let p = process
        // 止めるターン（発話か知らせのターン）が無ければプロセスを残し、制御要求も書かない（アイドル中の interrupt は
        // バックグラウンドのサブエージェントまで止める。実測 S6e）。kill すると次の送信が冷えた起動（--resume）になり、
        // 4〜5 秒待たせる（音声会話で読み上げ中に話しかけたときなど、done の後の停止で起きていた）。
        if p != nil, !hasActiveTurnLocked() {
            let lastDone = lastFinishedMessageId
            procLock.unlock()
            WebSocketServer.wslog("claude-code interrupt ignored (no active turn) session=\(sessionId)")
            // 止めた側の「生成中」を必ず解く（直近の done と同じ id なので、完了音などは繰り返されない）。
            continuation.yield(SessionEvent(
                type: .done, agentId: agentId, sessionId: sessionId, messageId: lastDone,
                toolUseId: nil, content: nil, toolName: nil, metadata: nil))
            return
        }
        // 生きているプロセスには制御要求で止める。ターンだけが中断で閉じ、プロセスは残る。initialize で
        // perTaskStopAffordance を宣言した CLI は、背景のサブエージェント・コマンド・dynamic workflow も止めない
        // （行ごとの停止は stopTask）。宣言できなかった古い CLI は、背景のサブエージェントも止め、killed / stopped の行が出る。
        if let p, p.isRunning, stdinWriter != nil {
            let gen = processGeneration
            if let pending = pendingInterrupt, pending.generation == gen, !pending.settled, !pending.refused {
                // 前の停止の返事を待っている。重ねて書かずに、同じ返事を待つ。
                procLock.unlock()
                await awaitInterrupt(requestId: pending.requestId, process: p, generation: gen)
                return
            }
            let targets = Set(turns.filter { $0.generation == gen }.map(\.messageId))
            guard !targets.isEmpty else {
                // 止める相手がまだ CLI に居ない（書く前の発話だけ）。アイドル中の interrupt はバックグラウンドの
                // サブエージェントまで止めるので書かない。止めた側の「生成中」だけ解く。
                let lastDone = lastFinishedMessageId
                procLock.unlock()
                WebSocketServer.wslog("claude-code interrupt ignored (message not written yet) session=\(sessionId)")
                continuation.yield(SessionEvent(
                    type: .done, agentId: agentId, sessionId: sessionId, messageId: lastDone,
                    toolUseId: nil, content: nil, toolName: nil, metadata: nil))
                return
            }
            let requestId = UUID().uuidString.lowercased()
            pendingInterrupt = PendingInterrupt(requestId: requestId, generation: gen, targets: targets)
            procLock.unlock()
            WebSocketServer.wslog("claude-code interrupt requested turns=\(targets.count) gen=\(gen) session=\(sessionId)")
            if writeControl(ClaudeControlProtocol.interruptRequest(requestId: requestId), generation: gen) {
                await awaitInterrupt(requestId: requestId, process: p, generation: gen)
            } else {
                await terminateForInterrupt(requestId: requestId, process: p, generation: gen)
            }
            return
        }
        var orphaned: [Turn] = []
        if p != nil {
            // シグナル済みのプロセスは再利用しない。外しておけば次の send() は必ず新しいプロセスを
            // 起こし、旧プロセスの終了処理は自分の世代のターンだけを done で畳む。
            interruptedGenerations.insert(processGeneration)
            process = nil
            stdinWriter = nil
            dyingProcess = p
        } else {
            // プロセスが既に無い（異常終了の直後など）。終了処理に拾われずに残ったターンがあれば、
            // 止めた側が done で閉じる（何も出さないと「考え中」が残る）。
            orphaned = turns.filter { !liveGenerations.contains($0.generation) }
            turns.removeAll { !liveGenerations.contains($0.generation) }
        }
        procLock.unlock()
        // 止めたプロセスへの返事は届かない。iPhone に残った承認カードを閉じる。
        resolvePendingActions(generation: nil)
        for turn in orphaned {
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: turn.messageId))
            turn.waiter?.resume()
        }
        // 終わりかけのプロセス。次の send() が --resume で再起動する。文脈は transcript が保つ。
        Self.terminateProcessGroup(p)
    }

    /// 停止の返事（か中断の result）を interruptGraceNanos まで待つ。来なければ（返事がエラーでも）今までどおり
    /// プロセスグループを止める。
    private func awaitInterrupt(requestId: String, process p: Process, generation gen: Int) async {
        let steps = max(1, Int(Self.interruptGraceNanos / 100_000_000))
        for _ in 0..<steps {
            // 返事が来た・プロセスが終わった・別の停止に替わった。
            guard let state = procLock.withLock({ pendingInterrupt }), state.requestId == requestId else { return }
            if state.refused { break }
            if state.settled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await terminateForInterrupt(requestId: requestId, process: p, generation: gen)
    }

    /// 制御要求で止められなかった。今までどおりプロセスグループを止め、終了処理が進行中のターンを中断として畳む
    /// （実行中の行は stopped）。次の send() が --resume で起こし直す。
    private func terminateForInterrupt(requestId: String, process p: Process, generation gen: Int) async {
        procLock.lock()
        guard let pending = pendingInterrupt, pending.requestId == requestId else { procLock.unlock(); return }
        // 背景の作業（動いている行・終わっていない workflow）があるときは、プロセスを止めない（止めると消える）。
        // 止めると決めたターンを中断として自分で閉じる。同じ世代で 2 回続けて返事が無ければ、CLI が固まっているので止める。
        if process === p, processGeneration == gen, subagents.hasRunning || hasUnfinishedWorkflowLocked,
           (unackedInterrupts[gen] ?? 0) == 0 {
            unackedInterrupts[gen] = 1
            keptInterruptIds[requestId] = gen
            pendingInterrupt = nil
            let closure = routers[gen]?.acknowledgeInterrupt(targets: pending.targets, stillQueued: []) ?? ClaudeTurnRouter.Closure()
            let lastDone = lastFinishedMessageId
            procLock.unlock()
            WebSocketServer.wslog("claude-code interrupt not acknowledged; kept process for background work gen=\(gen) session=\(sessionId)")
            if !closure.isEmpty {
                // CLI はまだそのターンを中断していないかもしれない。main の承認は拒否を書いて閉じる。
                resolvePendingActions(generation: gen, mainOnly: true, denyMain: true)
                await closeTurns(closure, generation: gen)
            } else if !pending.settled {
                continuation.yield(SessionEvent(
                    type: .done, agentId: agentId, sessionId: sessionId, messageId: lastDone,
                    toolUseId: nil, content: nil, toolName: nil, metadata: nil))
            }
            return
        }
        pendingInterrupt = nil
        // シグナル済みのプロセスは再利用しない。外しておけば次の send() は必ず新しいプロセスを起こし、
        // 旧プロセスの終了処理は自分の世代のターンだけを done で畳む。
        guard process === p, processGeneration == gen else { procLock.unlock(); return }
        interruptedGenerations.insert(gen)
        process = nil
        stdinWriter = nil
        dyingProcess = p
        procLock.unlock()
        WebSocketServer.wslog("claude-code interrupt not acknowledged, terminating gen=\(gen) session=\(sessionId)")
        // 止めたプロセスへの返事は届かない。iPhone に残った承認カードを閉じる。
        resolvePendingActions(generation: nil)
        Self.terminateProcessGroup(p)
    }

    /// こちらが書いた制御要求への返事。initialize と stop_task は request_id で見分け、返事の中身は読まない
    /// （initialize の返事はアカウントのメールと pid を含む）。interrupt は、止めると決めたときのターンを中断として閉じ、
    /// プロセスは残す。中断したターンの残り（result まで）はルーターが捨てる。
    private func handleControlResponse(_ response: ClaudeControlProtocol.Response, generation gen: Int) async {
        procLock.lock()
        if let initGen = pendingInitialize.removeValue(forKey: response.requestId) {
            var snapshot: String?
            if initGen == gen, processGeneration == gen {
                if response.success {
                    stopTaskGenerations.insert(gen)
                    workflowStopGenerations.insert(gen)
                    snapshot = subagents.setClaudeStopTask(true)
                } else {
                    snapshot = subagents.setClaudeStopTask(false)
                }
            }
            procLock.unlock()
            WebSocketServer.wslog("claude-code initialize \(response.success ? "accepted" : "refused") gen=\(gen) session=\(sessionId)")
            if let snapshot {
                continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: snapshot))
            }
            return
        }
        if pendingStops[response.requestId] != nil {
            procLock.unlock()
            deliverStopReply(requestId: response.requestId, response.success ? .success : .error(response.error ?? ""))
            return
        }
        if let keptGen = keptInterruptIds.removeValue(forKey: response.requestId) {
            // 残した interrupt の返事が遅れて届いた。CLI は生きているので、続けて返事が無かった数を戻す。
            unackedInterrupts.removeValue(forKey: keptGen)
        }
        guard var pending = pendingInterrupt, pending.requestId == response.requestId, pending.generation == gen else {
            procLock.unlock()
            return
        }
        guard response.success else {
            // 受け付けられなかった。awaitInterrupt が今までどおりプロセスを止める。
            pending.refused = true
            pendingInterrupt = pending
            procLock.unlock()
            WebSocketServer.wslog("claude-code interrupt refused: \(response.error ?? "-") session=\(sessionId)")
            return
        }
        pendingInterrupt = nil
        unackedInterrupts.removeValue(forKey: gen)
        let closure = routers[gen]?.acknowledgeInterrupt(targets: pending.targets, stillQueued: response.stillQueued)
            ?? ClaudeTurnRouter.Closure()
        let lastDone = lastFinishedMessageId
        procLock.unlock()
        WebSocketServer.wslog("claude-code interrupt acknowledged turns=\(closure.messageIds.count + (closure.notificationId == nil ? 0 : 1)) still_queued=\(response.stillQueued.count) session=\(sessionId)")
        if !closure.isEmpty {
            // 止めたターンの返事待ちは、もう誰も待っていない。背景のサブエージェントの承認は残す。
            resolvePendingActions(generation: gen, mainOnly: true)
            await closeTurns(closure, generation: gen)
        } else if !pending.settled {
            // 止めるターンは返事の前に終わっていた。止めた側の「生成中」を必ず解く（直近の done と同じ id）。
            continuation.yield(SessionEvent(
                type: .done, agentId: agentId, sessionId: sessionId, messageId: lastDone,
                toolUseId: nil, content: nil, toolName: nil, metadata: nil))
        }
    }

    /// 起動ログに出す設定の要約（model / effort / mode / resume）。付けていない値は "-"（CLI が settings.json から読む）。
    static func spawnSummary(args: [String]) -> String {
        func value(_ flag: String) -> String {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "-"
        }
        return "model=\(value("--model")) effort=\(value("--effort")) mode=\(value("--permission-mode")) resume=\(args.contains("--resume") ? 1 : 0)"
    }

    /// 止めるべきターンがあるか（登録前の送信を含む）。procLock を持って呼ぶ。
    private func hasActiveTurnLocked() -> Bool {
        sendsInFlight > 0 || turns.contains { !interruptedGenerations.contains($0.generation) }
    }

    /// claude --bg のジョブか（台帳にあるか）。テストが差し替える。
    nonisolated(unsafe) static var isBackgroundJob: @Sendable (String) async -> Bool = {
        await ClaudeBackgroundJobs.shared.entryFor(sessionId: $0) != nil
    }
    /// ClaudeBackgroundJobs に読み直しを頼む。テストが差し替える。
    nonisolated(unsafe) static var refreshBackgroundJobs: @Sendable () async -> Void = {
        await ClaudeBackgroundJobs.shared.refresh()
    }

    /// 起こしたプロセスが stderr に出す `running in the background (<8 桁>)` のジョブ id。
    static func backgroundJobId(inStderr text: String) -> String? {
        guard let r = text.range(of: #"running in the background \(([0-9a-f]{8})\)"#, options: .regularExpression) else { return nil }
        let hit = String(text[r])
        return String(hit[hit.index(hit.endIndex, offsetBy: -9)..<hit.index(before: hit.endIndex)])
    }

    /// バックグラウンドでまた動き始めた会話。生成中でなければ WS 側が取り直す（WebSocketServer.isStillUsable）。
    var isStaleForBackground: Bool {
        procLock.withLock { backgroundUnusable && !hasActiveTurnLocked() }
    }

    /// テスト用: 止めるターンがあるか。
    var hasActiveTurn: Bool { procLock.withLock { hasActiveTurnLocked() } }

    func close() async {
        procLock.lock()
        closed = true
        let p = process
        let dying = dyingProcess
        process = nil
        stdinWriter = nil
        let reader = readerTask
        // バックグラウンドの作業はプロセスと一緒に止まり、終わりの知らせはもう来ない。continuation を閉じる前に、
        // 実行中の行と終わっていない dynamic workflow を stopped で閉じる payload を流す（自分で止めた）。
        let abandoned = subagents.abandonRunning(state: "stopped")
        let closings = abandonWorkflowsLocked(state: "stopped")
        procLock.unlock()
        if let abandoned {
            continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: abandoned))
        }
        for payload in closings {
            continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: payload))
        }
        Self.terminateProcessGroup(p)
        Self.terminateProcessGroup(dying)   // interrupt 済みでまだ終わっていない旧プロセスも確実に止める
        reader?.cancel()
        resolvePendingActions(generation: nil)
        continuation.finish()
        if let mainToken { await Orchestrator.shared.revoke(token: mainToken) }
    }

    // MARK: - 行ごとの停止（stop_task。docs/BACKGROUND_CONTROL_2026-10-21.md §3.4）

    func stopTask(_ request: StopTaskRequest) async -> StopTaskOutcome {
        request.taskId == "subagents" ? await stopRow(request) : await stopWorkflow(request)
    }

    private func emitProgress(_ payloads: [String]) {
        for payload in payloads {
            continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: payload))
        }
    }

    /// サブエージェントと背景のシェルの行を 1 つ止める。
    private func stopRow(_ request: StopTaskRequest) async -> StopTaskOutcome {
        guard let rowId = request.rowId, let epoch = request.epoch else { return .stale }
        procLock.lock()
        guard epoch == subagents.epoch, subagents.contains(rowId) else { procLock.unlock(); return .stale }
        guard subagents.isRunning(key: rowId) else { procLock.unlock(); return .notRunning }
        guard !closed, let p = process, p.isRunning, stdinWriter != nil else { procLock.unlock(); return .notRunning }
        let gen = processGeneration
        guard stopTaskGenerations.contains(gen) else { procLock.unlock(); return .unsupported(nil) }
        let requestId = UUID().uuidString.lowercased()
        switch subagents.beginStop(key: rowId) {
        case .notRunning:
            procLock.unlock()
            return .notRunning
        case .unsupported:
            procLock.unlock()
            return .unsupported(nil)
        case .inFlight:
            procLock.unlock()
            return await joinPendingStop(.row(rowId), generation: gen)
        case .ok(_, let payload):
            pendingStops[requestId] = PendingStop(target: .row(rowId), generation: gen)
            procLock.unlock()
            emitProgress([payload].compactMap { $0 })
        }

        // CLI は返事より先に task_updated / task_notification / background_tasks_changed を出す（今のトラッカーが行を閉じる）。
        let reply = await sendStop(requestId: requestId, taskId: rowId, generation: gen)
        var emit: [String] = []
        let outcome: StopTaskOutcome
        procLock.lock()
        switch reply {
        case .success:
            switch subagents.state(key: rowId) {
            case "running":
                // CLI はその task を動かしていなかった。こちらで閉じる。
                if let payload = subagents.finish(key: rowId, state: "stopped", result: nil) { emit.append(payload) }
                outcome = .stopped
            case "stopped": outcome = .stopped
            default: outcome = .notRunning
            }
        case .error(let message):
            let ended = subagents.endStop(key: rowId)
            if message.contains("Unsupported control request subtype") {
                stopTaskGenerations.remove(gen)
                workflowStopGenerations.remove(gen)
                if let snapshot = subagents.setClaudeStopTask(false) { emit.append(snapshot) } else if let ended { emit.append(ended) }
                emit.append(contentsOf: unfinishedWorkflowPayloadsLocked())
                outcome = .unsupported(nil)
            } else {
                if let ended { emit.append(ended) }
                // 押した瞬間に行が自然に終わった（CLI は "Task X is not running (status: …)" で断る）。失敗ではなく not_running。
                outcome = Self.stopRefusedBecauseEnded(message) || subagents.state(key: rowId) != "running"
                    ? .notRunning : .failed(Self.stopMessage(message))
            }
        case .timeout:
            if let ended = subagents.endStop(key: rowId) { emit.append(ended) }
            outcome = .timeout
        case .exited:
            // stdin へ書けなかっただけでプロセスが生きているなら、始めに送った stoppable:false を戻す（行が止められないまま残らない）。
            if let ended = subagents.endStop(key: rowId) { emit.append(ended) }
            outcome = .notRunning
        }
        procLock.unlock()
        emitProgress(emit)
        finishStop(requestId: requestId, outcome)
        return outcome
    }

    /// dynamic workflow のカード全体を止める。task_id を stop_task に渡し、カードが終わるのを待つ。
    private func stopWorkflow(_ request: StopTaskRequest) async -> StopTaskOutcome {
        let taskId = request.taskId
        procLock.lock()
        guard let card = workflows[taskId], !card.finished else { procLock.unlock(); return .notRunning }
        guard !closed, let p = process, p.isRunning, stdinWriter != nil else { procLock.unlock(); return .notRunning }
        let gen = processGeneration
        guard stopTaskGenerations.contains(gen), workflowStopGenerations.contains(gen) else {
            procLock.unlock()
            return .unsupported(nil)
        }
        if card.stopRequested {
            procLock.unlock()
            return await joinPendingStop(.workflow(taskId), generation: gen)
        }
        let requestId = UUID().uuidString.lowercased()
        workflows[taskId]?.stopRequested = true
        pendingStops[requestId] = PendingStop(target: .workflow(taskId), generation: gen)
        let begun = workflowStatePayloadLocked(taskId)
        procLock.unlock()
        emitProgress([begun].compactMap { $0 })

        let reply = await sendStop(requestId: requestId, taskId: taskId, generation: gen)
        var outcome: StopTaskOutcome
        var emit: [String] = []
        switch reply {
        case .success:
            // 返事の後、カードが終わる（task_updated killed か task_notification stopped）のをさらに待つ。
            let deadline = Date().addingTimeInterval(Double(workflowEndNanos) / 1_000_000_000)
            var ended = false
            var alive = true
            while true {
                procLock.lock()
                ended = workflows[taskId]?.finished ?? true
                alive = !closed && processGeneration == gen && process?.isRunning == true
                procLock.unlock()
                if ended || !alive || Date() >= deadline || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if Task.isCancelled, !ended, alive {
                // 15 秒の上限で打ち切られた。印だけ戻す（この世代の止める手段は残す）。
                procLock.lock()
                workflows[taskId]?.stopRequested = false
                if let payload = workflowStatePayloadLocked(taskId) { emit.append(payload) }
                procLock.unlock()
                outcome = .timeout
            } else if ended {
                outcome = alive ? .stopped : .notRunning
            } else if !alive {
                outcome = .notRunning
            } else {
                // 終わらなかった。カードは閉じない（まだ動いているかもしれない）。この世代では止められないことにする。
                procLock.lock()
                workflowStopGenerations.remove(gen)
                workflows[taskId]?.stopRequested = false
                if let payload = workflowStatePayloadLocked(taskId) { emit.append(payload) }
                procLock.unlock()
                outcome = .failed(nil)
            }
        case .error(let message):
            procLock.lock()
            workflows[taskId]?.stopRequested = false
            if message.contains("Unsupported control request subtype") {
                stopTaskGenerations.remove(gen)
                workflowStopGenerations.remove(gen)
                if let snapshot = subagents.setClaudeStopTask(false) { emit.append(snapshot) }
                outcome = .unsupported(nil)
            } else {
                // 押した瞬間にカードが終わった。失敗ではなく not_running。
                outcome = Self.stopRefusedBecauseEnded(message) || (workflows[taskId]?.finished ?? true)
                    ? .notRunning : .failed(Self.stopMessage(message))
            }
            if let payload = workflowStatePayloadLocked(taskId) { emit.append(payload) }
            if case .unsupported = outcome {
                // ほかの終わっていないカードも、止められないことを送り直す。
                emit.append(contentsOf: unfinishedWorkflowPayloadsLocked().filter { $0 != emit.last })
            }
            procLock.unlock()
        case .timeout:
            procLock.lock()
            workflows[taskId]?.stopRequested = false
            if let payload = workflowStatePayloadLocked(taskId) { emit.append(payload) }
            let ended = workflows[taskId]?.finished ?? true
            procLock.unlock()
            outcome = ended ? .notRunning : .timeout
        case .exited:
            // stdin へ書けなかっただけでプロセスが生きているなら、stoppable:false を戻す（終わったカードには送らない）。
            procLock.lock()
            workflows[taskId]?.stopRequested = false
            if let payload = workflowStatePayloadLocked(taskId) { emit.append(payload) }
            procLock.unlock()
            outcome = .notRunning
        }
        emitProgress(emit)
        finishStop(requestId: requestId, outcome)
        return outcome
    }

    /// stop_task の error が「もう動いていない」だったか（CLI の文は "Task <id> is not running (status: completed)"）。
    static func stopRefusedBecauseEnded(_ message: String) -> Bool {
        message.contains("is not running")
    }

    /// CLI の文を 200 字までにする。空なら nil。
    private static func stopMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }

    /// stop_task を書き、同じ request_id の control_response を stopReplyNanos まで待つ。pendingStops に入れてから呼ぶ。
    private func sendStop(requestId: String, taskId: String, generation gen: Int) async -> StopReply {
        guard writeControl(ClaudeControlProtocol.stopTaskRequest(requestId: requestId, taskId: taskId), generation: gen) else {
            return .exited
        }
        let nanos = stopReplyNanos
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            self?.deliverStopReply(requestId: requestId, .timeout)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { c in
            procLock.lock()
            guard let entry = pendingStops[requestId] else { procLock.unlock(); c.resume(returning: .exited); return }
            if let reply = entry.reply {
                procLock.unlock()
                c.resume(returning: reply)
            } else {
                entry.owner = c
                procLock.unlock()
            }
        }
    }

    /// 返事（か時間切れ）を持ち主に渡す。最初の 1 つだけが効く。
    private func deliverStopReply(requestId: String, _ reply: StopReply) {
        procLock.lock()
        guard let entry = pendingStops[requestId], entry.reply == nil else { procLock.unlock(); return }
        entry.reply = reply
        let owner = entry.owner
        entry.owner = nil
        procLock.unlock()
        owner?.resume(returning: reply)
    }

    /// 同じ行（カード）への 2 つ目の停止は、先に頼んだ停止の結果を待って同じ結果を返す。
    private func joinPendingStop(_ target: StopTarget, generation gen: Int) async -> StopTaskOutcome {
        await withCheckedContinuation { c in
            procLock.lock()
            if let entry = pendingStops.values.first(where: { $0.target == target && $0.generation == gen }) {
                entry.joiners.append(c)
                procLock.unlock()
            } else {
                procLock.unlock()
                c.resume(returning: .notRunning)
            }
        }
    }

    /// 持ち主の結果が決まった。待たせていた 2 つ目以降に同じ結果を返す。
    private func finishStop(requestId: String, _ outcome: StopTaskOutcome) {
        procLock.lock()
        let joiners = pendingStops.removeValue(forKey: requestId)?.joiners ?? []
        procLock.unlock()
        for joiner in joiners { joiner.resume(returning: outcome) }
    }

    // MARK: - 承認・質問（iPhone ⇄ claude の制御プロトコル）

    private func handleControl(_ line: ClaudeControlProtocol.Line, generation gen: Int) {
        switch line {
        case .canUseTool(let request):
            let card: SessionEvent?
            let isQuestion = request.toolName == "AskUserQuestion"
                && !ClaudeControlProtocol.questions(in: request.input).isEmpty
            if isQuestion {
                card = ClaudeControlProtocol.questionCard(request, agentId: agentId, sessionId: sessionId)
            } else if request.toolName == "ExitPlanMode" {
                card = ClaudeControlProtocol.planCard(request, agentId: agentId, sessionId: sessionId)
            } else {
                card = ClaudeControlProtocol.approvalCard(request, agentId: agentId, sessionId: sessionId)
            }
            guard let card else {
                // 出せる質問が無い。待たせずに元の入力のまま通す（AskUserQuestion の形が想定外のとき）。
                _ = writeControl(ClaudeControlProtocol.allowResponse(requestId: request.requestId, input: request.input), generation: gen)
                return
            }
            procLock.lock()
            pendingActions[request.requestId] = PendingAction(generation: gen, request: request, isQuestion: isQuestion)
            procLock.unlock()
            emitSessionStartedIfNeeded()
            continuation.yield(card)
        case .cancel(let requestId):
            procLock.lock()
            let removed = pendingActions.removeValue(forKey: requestId)
            procLock.unlock()
            if removed != nil {
                continuation.yield(.actionResolved(agentId: agentId, sessionId: sessionId, requestId: requestId))
            }
        case .unsupported(let requestId, let subtype):
            // 返事をしないと claude はその要求で待ち続ける。
            _ = writeControl(
                ClaudeControlProtocol.errorResponse(requestId: requestId, message: "unsupported control request: \(subtype)"),
                generation: gen)
        case .response:
            // こちらの制御要求への返事は handleControlResponse が受ける。
            break
        }
    }

    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {
        procLock.lock()
        let pending = pendingActions.removeValue(forKey: requestId)
        procLock.unlock()
        // 応答済み・プロセス交代後など、もう待っていない要求には書かない（iPhone に残った古いカード対策）。
        guard let pending else { return }
        let request = pending.request
        let response: [String: Any]
        if pending.isQuestion {
            var input = request.input
            input["answers"] = ClaudeControlProtocol.answers(
                for: ClaudeControlProtocol.questions(in: request.input), decision: decision, explicit: answers)
            response = ClaudeControlProtocol.allowResponse(requestId: requestId, input: input)
        } else {
            switch decision {
            case "allow":
                response = ClaudeControlProtocol.allowResponse(requestId: requestId, input: request.input)
            case "allowForSession":
                response = ClaudeControlProtocol.allowResponse(
                    requestId: requestId, input: request.input,
                    updatedPermissions: ClaudeControlProtocol.sessionScoped(request.suggestions))
            case "deny" where request.toolName == "ExitPlanMode":
                response = ClaudeControlProtocol.denyResponse(
                    requestId: requestId,
                    message: "The user wants to keep planning. Do not start implementing yet; ask what they would like to change.")
            case "deny":
                response = ClaudeControlProtocol.denyResponse(
                    requestId: requestId,
                    message: "The user denied this tool call from their phone. Do not retry it; ask what they would like instead.")
            default:
                // 選択肢以外の文（計画への注文・断る理由）。その文を添えて差し戻す。
                response = ClaudeControlProtocol.denyResponse(
                    requestId: requestId,
                    message: request.toolName == "ExitPlanMode"
                        ? "The user wants changes to the plan before implementing: \(decision)\nRevise the plan and call ExitPlanMode again."
                        : "The user denied this tool call from their phone and said: \(decision)")
            }
        }
        _ = writeControl(response, generation: pending.generation)
        // 他の画面（デスクトップ等）に残っているカードも閉じさせる。
        continuation.yield(.actionResolved(agentId: agentId, sessionId: sessionId, requestId: requestId))
    }

    /// 返事待ちを全部取り下げ、iPhone のカードを閉じさせる。generation が nil なら全プロセス分。
    /// mainOnly なら main の承認だけ閉じる。背景のサブエージェントの承認は CLI の control_cancel_request か
    /// プロセスの終わりで閉じる（CLI は interrupt でその子を止めないので、閉じると答えられなくなる）。
    /// denyMain なら、閉じる main の承認に拒否を書く（CLI がまだそのターンで返事を待っているとき）。
    private func resolvePendingActions(generation gen: Int?, mainOnly: Bool = false, denyMain: Bool = false) {
        procLock.lock()
        let matched = pendingActions.filter {
            (gen == nil || $0.value.generation == gen) && (!mainOnly || $0.value.request.agentId == nil)
        }
        for id in matched.keys { pendingActions.removeValue(forKey: id) }
        procLock.unlock()
        for (id, pending) in matched {
            if denyMain, pending.request.agentId == nil {
                _ = writeControl(
                    ClaudeControlProtocol.denyResponse(
                        requestId: id, message: "The user interrupted this turn. Do not retry this tool call."),
                    generation: pending.generation)
            }
            continuation.yield(.actionResolved(agentId: agentId, sessionId: sessionId, requestId: id))
        }
    }

    /// 指定の世代のプロセスの stdin に制御行を書く。そのプロセスがもう居なければ false。
    private func writeControl(_ object: [String: Any], generation gen: Int) -> Bool {
        procLock.lock()
        let writer: FileHandle? = (!closed && processGeneration == gen && process?.isRunning == true) ? stdinWriter : nil
        procLock.unlock()
        guard let writer, let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        do {
            try writeLine(data, to: writer)
            return true
        } catch {
            return false
        }
    }

    private func writeLine(_ data: Data, to writer: FileHandle) throws {
        stdinWriteLock.lock()
        defer { stdinWriteLock.unlock() }
        try writer.write(contentsOf: data)
        try writer.write(contentsOf: Data([0x0A]))
    }

    /// プロセスグループ全体に SIGTERM → claude の子孫もまとめて終了させる。
    /// グループ化に失敗していた場合は ESRCH になるだけなので、保険で terminate() も呼ぶ。
    private static func terminateProcessGroup(_ p: Process?) {
        guard let p, p.isRunning else { return }
        let pid = p.processIdentifier
        if pid > 0 {
            kill(-pid, SIGTERM)
            SpawnRegistry.unregister(pid: pid)
        }
        if p.isRunning {
            p.terminate()
        }
    }

    // MARK: - チャット単位の設定

    func applyOverrides(_ overrides: SessionOverrides) {
        procLock.withLock { self.overrides = overrides }
    }

    private var currentOverrides: SessionOverrides { procLock.withLock { overrides } }

    /// このチャットで使うモデル。チャットの上書き > プロファイルの既定。
    private func effectiveModel() -> String? {
        currentOverrides.model ?? ClaudeCodeAdapter.configuredModel()
    }

    /// `--effort` に明示する tier（ultracode を含む BuddyOS の語彙）。チャットの上書き > env > 既定の ultracode。
    /// nil なら付けず、CLI が ~/.claude/settings.json の effortLevel（モデル別 > 全体）を自分で読む。
    private func explicitEffort() -> String? {
        if let e = currentOverrides.reasoningEffort, ClaudeCodeAdapter.validEfforts.contains(e) { return e }
        if let env = nonEmpty(ProcessInfo.processInfo.environment["BUDDYOS_CLAUDE_EFFORT"]) { return env }
        return ClaudeCodeAdapter.readEffort() == "ultracode" ? "ultracode" : nil
    }

    /// `--permission-mode` に明示する BuddyOS モード。チャットの上書きだけ。
    /// nil なら付けず、CLI が settings.json の permissions.defaultMode を自分で読む。
    private func explicitMode() -> String? {
        if let m = currentOverrides.mode, ClaudeCodeAdapter.validModes.contains(m) { return m }
        return nil
    }

    /// プロセス起動時に効く設定の要約。既定（settings.json）の変化でも起こし直すよう、明示しない値も含める。
    /// --resume の有無は含めない（sid 確定で起こし直さないため）。
    func configSignature() -> String {
        [effectiveModel() ?? "",
         explicitEffort() ?? ClaudeCodeAdapter.readEffort() ?? "",
         permissionOverride ?? explicitMode() ?? ClaudeCodeAdapter.readMode() ?? ""]
            .joined(separator: "|")
    }

    /// 送る前に claude を起こしておく（チャットを開いたとき）。起動と SessionStart の hook を先に済ませ、
    /// 1 通目の待ち時間を縮める（実測: 送ってから init まで 1.1〜1.8 秒 → 0.1〜0.2 秒）。
    /// ここで起こしたプロセスが warmIdleNanos のあいだ使われなければ畳む（開いただけのチャットで残さない）。
    /// 前から動いているプロセスには触らない。
    func warm() async {
        // claude --bg のジョブの会話は起こさない（開いただけで 5 分握ると、PC の claude respawn / attach が断られる。§7.8）。
        if await Self.isBackgroundJob(sessionId) { return }
        retireProcessIfConfigChanged()
        let (before, sends) = procLock.withLock { (processGeneration, sendCount) }
        guard (try? await ensureProcess()) != nil else { return }
        let gen = procLock.withLock { processGeneration }
        guard gen != before else { return }
        WebSocketServer.wslog("claude-code session warmed gen=\(gen) session=\(sessionId)")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.warmIdleNanos)
            self?.retireUnusedWarmProcess(generation: gen, sends: sends)
        }
    }

    /// warm() で起こしたプロセスが、その後一度も使われていなければ畳む。
    private func retireUnusedWarmProcess(generation gen: Int, sends: Int) {
        procLock.lock()
        guard sendCount == sends, processGeneration == gen, let p = process, p.isRunning,
              turns.isEmpty, pendingActions.isEmpty else {
            procLock.unlock()
            return
        }
        interruptedGenerations.insert(gen)
        process = nil
        stdinWriter = nil
        dyingProcess = p
        procLock.unlock()
        WebSocketServer.wslog("claude-code warmed process unused, retiring session=\(sessionId)")
        Self.terminateProcessGroup(p)
    }

    /// 設定（チャットの上書き・既定）が起動時から変わっていて、ターンも承認待ちも無ければ、
    /// 常駐プロセスを畳む。次の ensureProcess が新しい設定と --resume で起こし直す（文脈は transcript が保つ）。
    /// 生成中（フォローアップ注入・知らせのターン）は畳まず、次にアイドルで送るときに反映する。
    /// バックグラウンドの作業（動いているサブエージェント・コマンドの行、終わっていない dynamic workflow）がある間も
    /// 延ばす（プロセスと一緒に止まり、終わりの知らせも来なくなる）。
    private func retireProcessIfConfigChanged() {
        let signature = configSignature()
        procLock.lock()
        guard let p = process, p.isRunning, let spawned = spawnedSignature, spawned != signature,
              !turns.contains(where: { !interruptedGenerations.contains($0.generation) }),
              pendingActions.isEmpty, !subagents.hasRunning, !hasUnfinishedWorkflowLocked else {
            procLock.unlock()
            return
        }
        interruptedGenerations.insert(processGeneration)
        process = nil
        stdinWriter = nil
        dyingProcess = p
        procLock.unlock()
        WebSocketServer.wslog("claude-code session settings changed, respawning session=\(sessionId)")
        Self.terminateProcessGroup(p)
    }

    private func configure(process: Process) {
        let args = sessionArgs()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
        }
        process.environment = environment()
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
    }

    func sessionArgs() -> [String] {
        var args = [
            // プロンプトは引数ではなく stdin から stream-json で流す。
            // これでプロセスがターンをまたいで生き続ける。
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages"
        ]
        if let sessionId = resolvedSessionId, isUUID(sessionId) {
            args += ["--resume", sessionId]
        }
        let env = ProcessInfo.processInfo.environment
        // per-run 上書き (cron 等) > チャットの上書き（Plan/Edit/Auto/Dangerous）
        // > 環境変数の生値、の優先順。どれも無ければ付けず、CLI が settings.json の defaultMode を使う。
        if mainToken != nil, mainRestricted {
            // mainagent: Bridge の MCP を渡し、書く道具を外す。権限モードは default に固定する
            // （送る・起こすの承認を iPhone に尋ねるため。チャットで Auto などを選んでいても使わない）。
            // 合鍵は環境変数で渡す（environment()）。引数に載せると ps で見える。
            args += MainAgentWorkspace.claudeArgs(port: MainAgentWorkspace.currentPort)
        } else if let permission = ClaudeCodeAdapter.permissionFlag(forMode: permissionOverride)
            ?? ClaudeCodeAdapter.permissionFlag(forMode: explicitMode())
            ?? nonEmpty(env["BUDDYOS_CLAUDE_PERMISSION_MODE"]) {
            args += ["--permission-mode", permission]
        }
        if mainToken != nil, !mainRestricted {
            // ふつうのセッション: Bridge の MCP だけを足す（書く道具も権限モードもそのセッションのまま）。
            args += MainAgentWorkspace.claudeDelegateArgs(port: MainAgentWorkspace.currentPort)
        }
        // 承認が要る操作を iPhone に尋ねる。付けないと claude は何も尋ねずに自動拒否する（実測）。
        // 無人実行（cron: permissionOverride あり）は答える人が居ないので付けない。
        // BUDDYOS_CLAUDE_PERMISSION_PROMPTS=0 で無効化できる。
        if permissionPrompts, env["BUDDYOS_CLAUDE_PERMISSION_PROMPTS"] != "0" {
            args += ["--permission-prompt-tool", "stdio"]
        }
        if let model = effectiveModel() {
            args += ["--model", model]
        }
        // 端末のアプリから使われていることを伝える（伝えないと「ターミナルなので画像は出せない」と答える）。
        var appended = [ClaudeCodeAdapter.clientDirective]
        if let tier = explicitEffort() {
            // ultracode は `--effort` では弾かれるため xhigh へ変換し、
            // 「常時 Workflow 活用」姿勢を --append-system-prompt で再現する。
            // dynamic workflows 本体は environment() の CLAUDE_CODE_WORKFLOWS=1 で担保。
            args += ["--effort", ClaudeCodeAdapter.cliEffort(for: tier)]
            if tier == "ultracode" {
                appended.append(ClaudeCodeAdapter.ultracodeDirective)
            }
        }
        args += ["--append-system-prompt", appended.joined(separator: "\n\n")]
        return args
    }

    /// 画像ブロックで渡せる画像（Claude が受け付ける形式のものだけ）。
    static let inlineImageMimes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    static func normalizedImageMime(_ mime: String) -> String {
        let m = mime.lowercased()
        return m == "image/jpg" ? "image/jpeg" : m
    }

    static func inlineImages(_ attachments: [BridgeAttachment]) -> [BridgeAttachment] {
        attachments.filter { $0.kind == .image && inlineImageMimes.contains(normalizedImageMime($0.mime)) }
    }

    /// stream-json の user メッセージの content。画像ブロック（base64）を先に、本文を後に並べる。
    static func contentBlocks(text: String, images: [BridgeAttachment]) -> [[String: Any]] {
        var blocks: [[String: Any]] = images.map { image in
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": normalizedImageMime(image.mime),
                    "data": image.data.base64EncodedString(),
                ] as [String: Any],
            ]
        }
        blocks.append(["type": "text", "text": text])
        return blocks
    }

    /// `inlinedImages` に含まれる画像は画像ブロックで渡すので、本文には目印を入れない。
    func promptText(text: String, skills: [String], attachments: [BridgeAttachment], inlinedImages: [BridgeAttachment] = []) -> String {
        var sections: [String] = []
        if !skills.isEmpty {
            sections.append("/skill \(skills.joined(separator: ","))")
        }
        for attachment in attachments {
            switch attachment.kind {
            case .file:
                if let decoded = String(data: attachment.data, encoding: .utf8) {
                    sections.append("<file name=\"\(attachment.name)\">\n\(decoded)\n</file>")
                } else {
                    sections.append("[file \"\(attachment.name)\" attached: \(attachment.mime), \(attachment.data.count) bytes]")
                }
            case .image:
                // 画像ブロックで渡す分は本文に目印を入れない（モデルが「ファイルが見つからない」と探しに行く）。
                if !inlinedImages.contains(where: { $0.name == attachment.name && $0.data == attachment.data }) {
                    sections.append("[image \"\(attachment.name)\" attached: \(attachment.mime), \(attachment.data.count) bytes]")
                }
            }
        }
        sections.append(text)
        return sections.joined(separator: "\n\n")
    }

    /// claude stream-json の dynamic workflow のライフサイクル行（system/task_*）を、クライアント向けの正規化 JSON へ
    /// 変換する。workflow の行でなければ nil（docs/BACKGROUND_WORK_2026-10-21.md §3.3）。
    /// - workflow かどうかは行の印（task_type = local_workflow・workflow_name・workflow_progress）と、task_started で覚えた
    ///   task_id（SubagentTracker.isWorkflowTask）で決める。task_notification は task_type も名前も持たないので id で見分け、
    ///   summary の文字では決めない（サブエージェントやコマンドの結果に workflow という語が入ると取り違える）。
    /// - 行の state は running / done / failed / stopped に、カードの status は running / completed / failed にそろえる
    ///   （止まった workflow は failed に outcome: "stopped" を添える。古いアプリの spinner が止まるように）。
    /// - workflow は覚えておき（終わったものは後の知らせに名前を載せるため、次の新しいターンまで）、終わっていないものは
    ///   プロセスが終わったとき・close で閉じる（abandonWorkflowsLocked）。
    /// テストからも呼ぶ。
    func workflowEventPayload(from obj: [String: Any]) -> String? {
        guard string(obj["type"]) == "system", let subtype = string(obj["subtype"]),
              ["task_started", "task_progress", "task_updated", "task_notification"].contains(subtype),
              let taskId = string(obj["task_id"]), !taskId.isEmpty else { return nil }
        let progress = obj["workflow_progress"] as? [[String: Any]]
        procLock.lock(); defer { procLock.unlock() }
        guard string(obj["task_type"]) == "local_workflow" || string(obj["workflow_name"]) != nil
                || progress != nil || subagents.isWorkflowTask(taskId) || workflows[taskId] != nil else { return nil }

        // 終わり方: task_updated は patch.status（completed / failed / killed）、task_notification は status
        // （completed / failed / stopped）。task_started / task_progress は動いている。
        let final: String?
        switch subtype {
        case "task_updated":
            let status = string((obj["patch"] as? [String: Any])?["status"])
            // 状態も進み具合も無い更新（裏に回った印など）は出さない。
            if status == nil, progress == nil { return nil }
            final = status.flatMap(SubagentTracker.finalState)
        case "task_notification":
            final = SubagentTracker.finalState(string(obj["status"]) ?? "completed") ?? "done"
        default:
            final = nil
        }
        var card = workflows[taskId] ?? WorkflowCard()
        if subtype == "task_started" {
            card.finished = false
        } else if card.finished, final == nil {
            // 終わった後に遅れて届いた進み具合では、実行中に戻さない（やり直しは task_started で来る）。
            return nil
        }
        if let name = string(obj["workflow_name"]) { card.name = name }
        if let progress {
            card.agents = Self.workflowRows(progress)
            card.phases = Self.workflowPhases(progress)
        }
        if final != nil { card.finished = true }
        workflows[taskId] = card

        var out: [String: Any] = ["subtype": subtype, "taskId": taskId]
        switch final {
        case nil: out["status"] = "running"
        case "done": out["status"] = "completed"
        case "stopped": out["status"] = "failed"; out["outcome"] = "stopped"
        default: out["status"] = "failed"
        }
        if let name = card.name { out["workflowName"] = name }
        for key in ["description", "summary"] {
            if let v = string(obj[key]) { out[key] = v }
        }
        if progress != nil {
            out["agents"] = card.agents
            out["phases"] = card.phases
        }
        out["stoppable"] = workflowStoppableLocked(card)
        return Self.jsonString(out)
    }

    /// dynamic workflow のカード全体を今止められるか。procLock を持って呼ぶ。
    private func workflowStoppableLocked(_ card: WorkflowCard) -> Bool {
        guard !card.finished, !card.stopRequested, process?.isRunning == true else { return false }
        return stopTaskGenerations.contains(processGeneration) && workflowStopGenerations.contains(processGeneration)
    }

    /// 進み具合を運ばない、カードの状態だけの payload（停止を頼んだ・止まらなかったときの stoppable の送り直し）。procLock を持って呼ぶ。
    private func workflowStatePayloadLocked(_ taskId: String) -> String? {
        // 終わったカードには送らない（status running で実行中に戻してしまう）。
        guard let card = workflows[taskId], !card.finished else { return nil }
        var out: [String: Any] = ["subtype": "task_progress", "taskId": taskId, "status": "running"]
        if let name = card.name { out["workflowName"] = name }
        out["stoppable"] = workflowStoppableLocked(card)
        return Self.jsonString(out)
    }

    /// 終わっていない dynamic workflow のカードすべての状態 payload（stoppable の送り直し）。procLock を持って呼ぶ。
    private func unfinishedWorkflowPayloadsLocked() -> [String] {
        workflows.keys.sorted().compactMap { workflowStatePayloadLocked($0) }
    }

    /// workflow_progress の type = workflow_phase の要素を {index, title} にする。title は改行を空白に、前後の空白を除き、
    /// 続く空白を 1 つにして 80 字で切り、空は捨てる。index が同じものは最初の 1 つ。index の昇順。
    static func workflowPhases(_ progress: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<Int>()
        var phases: [(index: Int, title: String)] = []
        for a in progress where a["type"] as? String == "workflow_phase" {
            guard let index = (a["index"] as? NSNumber)?.intValue, let raw = a["title"] as? String else { continue }
            let title = String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
            guard !title.isEmpty, seen.insert(index).inserted else { continue }
            phases.append((index, title))
        }
        return phases.sorted { $0.index < $1.index }.map { ["index": $0.index, "title": $0.title] }
    }

    /// workflow_progress の要素を行にする。phase の見出し（type = workflow_phase）は行にしない。
    /// state は running / done / failed / stopped にそろえ（CLI は start / progress / done / error）、失敗の理由（error）は
    /// resultPreview に出す（アプリは失敗の行の 2 段目に resultPreview を出す）。
    static func workflowRows(_ progress: [[String: Any]]) -> [[String: Any]] {
        progress.compactMap { a -> [String: Any]? in
            if let type = a["type"] as? String, type == "workflow_phase" || type == "workflow_log" { return nil }
            var e: [String: Any] = [:]
            for k in ["index", "label", "phaseIndex", "phaseTitle", "agentType",
                      "model", "tokens", "toolCalls", "durationMs", "resultPreview"] {
                if let v = a[k], !(v is NSNull) { e[k] = v }
            }
            let state = workflowRowState(a["state"] as? String)
            if let state { e["state"] = state }
            if state == "failed", e["resultPreview"] == nil, let error = a["error"] as? String, !error.isEmpty {
                e["resultPreview"] = error
            }
            if let started = a["startedAt"] as? Double { e["startedAtMs"] = Int(started) }
            return e
        }
    }

    /// dynamic workflow の行の状態をそろえる。start / progress / running → running、done / completed → done、
    /// error / failed → failed、killed / stopped / cancelled → stopped。知らない語はそのまま。
    static func workflowRowState(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw {
        case "start", "progress", "running": return "running"
        default: return SubagentTracker.finalState(raw) ?? raw
        }
    }

    /// 終わっていない dynamic workflow を閉じる payload（プロセスが終わった・close）。CLI の終わりの知らせはもう来ない。
    /// 動いていた行も同じ状態で閉じる。state は stopped（自分で止めた）か failed（異常終了）。procLock を持って呼ぶ。
    private func abandonWorkflowsLocked(state: String) -> [String] {
        let open = workflows.filter { !$0.value.finished }.sorted { $0.key < $1.key }
        for entry in open { workflows[entry.key]?.finished = true }
        return open.compactMap { entry -> String? in
            let card = entry.value
            var out: [String: Any] = ["subtype": "task_notification", "taskId": entry.key, "status": "failed", "stoppable": false]
            if state == "stopped" { out["outcome"] = "stopped" }
            if let name = card.name { out["workflowName"] = name }
            if !card.agents.isEmpty {
                out["agents"] = card.agents.map { row -> [String: Any] in
                    var r = row
                    if r["state"] as? String == "running" { r["state"] = state }
                    return r
                }
            }
            return Self.jsonString(out)
        }
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// サブエージェントとバックグラウンドのコマンドの進行（system/task_*・background_tasks_changed・assistant 行の
    /// tool_use・Agent の async_launched）を workflowProgress の payload にする。変化が無ければ nil。
    private func subagentPayload(from obj: [String: Any]) -> String? {
        // 大半の行（stream_event）は関係ない。
        guard let type = string(obj["type"]), type == "system" || type == "assistant" || type == "user" else { return nil }
        procLock.lock(); defer { procLock.unlock() }
        return subagents.ingestStreamLine(obj)
    }

    /// サブエージェントのカードの全行（workflow_snapshot、epoch 付き。行が無くても agents: []）。
    /// SessionHub が接続したときと turn_status_request のときに、ターンの状態に関係なく送る（§3.5）。
    func subagentSnapshot() async -> String? {
        procLock.withLock { subagents.snapshot(includeEmpty: true) }
    }

    /// claude stream-json の consolidated assistant 行から、チェックリスト系ツールの
    /// tool_use を反映し、現在の全タスクを正規化スナップショット JSON で返す。
    /// チェックリストに変化が無ければ nil。
    /// - TaskCreate {subject, activeForm?} → 作成順に 1-indexed の id を振って追加（status=pending）
    /// - TaskUpdate {taskId, status}      → 該当 id の status を更新
    /// - TodoWrite  {todos:[{content,status,activeForm}]} → 全置換（別 CLI 版/構成向けの保険）
    /// 出力: { "entries": [ { "content", "status", "activeForm"? } ] }（全置換スナップショット）。
    /// 部分ストリーム（input_json_delta）は type!="assistant" なので拾わず、二重計上しない。
    private func planSnapshotPayload(from obj: [String: Any]) -> String? {
        guard string(obj["type"]) == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        // サブエージェント（Task / Explore 等）の行は parent_tool_use_id を持つ（メインは null = NSNull）。
        // TodoWrite はエージェントごとのリストなので親のチェックリストに混ぜない。TaskCreate/TaskUpdate は
        // セッション共有の連番を消費しうるため除外しない（除外すると親の taskId と番号がずれる）。
        let isSubagent = string(obj["parent_tool_use_id"]) != nil
        // send() も planTasks を触るのでロック下で更新し、スナップショットを取ってから JSON 化する。
        procLock.lock()
        var changed = false
        for block in content where string(block["type"]) == "tool_use" {
            let name = string(block["name"])
            guard let input = block["input"] as? [String: Any] else { continue }
            switch name {
            case "TaskCreate":
                guard let subject = string(input["subject"]) ?? string(input["content"]),
                      !subject.isEmpty else { continue }
                let af = string(input["activeForm"])
                planTasks.append(PlanTask(
                    id: String(planTasks.count + 1),
                    subject: subject,
                    activeForm: (af?.isEmpty == false) ? af : nil,
                    status: "pending"))
                changed = true
            case "TaskUpdate":
                guard let taskId = string(input["taskId"]) ?? string(input["id"]),
                      let status = string(input["status"]),
                      let idx = planTasks.firstIndex(where: { $0.id == taskId }) else { continue }
                planTasks[idx].status = status
                changed = true
            case "TodoWrite":
                guard !isSubagent, let todos = input["todos"] as? [[String: Any]] else { continue }
                planTasks = todos.enumerated().compactMap { (i, t) in
                    guard let c = string(t["content"]), !c.isEmpty else { return nil }
                    let af = string(t["activeForm"])
                    return PlanTask(
                        id: String(i + 1),
                        subject: c,
                        activeForm: (af?.isEmpty == false) ? af : nil,
                        status: string(t["status"]) ?? "pending")
                }
                changed = true
            default:
                continue
            }
        }
        let snapshot = changed ? planTasks : []
        procLock.unlock()
        guard !snapshot.isEmpty else { return nil }
        let entries: [[String: String]] = snapshot.map { t in
            var e: [String: String] = ["content": t.subject, "status": t.status]
            if let af = t.activeForm { e["activeForm"] = af }
            return e
        }
        guard let outData = try? JSONSerialization.data(withJSONObject: ["entries": entries]),
              let json = String(data: outData, encoding: .utf8) else { return nil }
        return json
    }

    private func parseLine(_ parsed: [String: Any]?, line: String, sawTextDelta: Bool) -> (text: String?, sessionId: String?, model: String?) {
        guard let object = parsed else {
            return sawTextDelta ? (nil, nil, nil) : (line + "\n", nil, nil)
        }

        let sid = string(object["session_id"]) ?? string(object["sessionId"])
        // サブエージェント（Task / Explore 等）の行は parent_tool_use_id に親の tool_use id を持つ
        // （メインの行は null = NSNull なので as? String で判定する）。そのモデルや本文を親ターンに混ぜない。
        let isSubagent = string(object["parent_tool_use_id"]) != nil
        // claude が解決した実モデル ID (例 "claude-opus-5-5")。
        // init(system) 行は top-level、assistant 行は message 配下に入る。
        let model: String? = isSubagent
            ? nil
            : string(object["model"]) ?? string((object["message"] as? [String: Any])?["model"])
        // init 行の slash_commands をキャッシュ（コマンドパレットの正規ソース）。
        if let sc = object["slash_commands"] as? [String], !sc.isEmpty {
            // parseLine は ClaudeCodeSession 内なので Self は Session を指す。
            // static の在処は ClaudeCodeAdapter（resolvedModel と同じ）。明示参照する。
            ClaudeCodeAdapter.resolvedSlashCommands = sc
        }
        if !isSubagent,
           let event = object["event"] as? [String: Any],
           let delta = event["delta"] as? [String: Any],
           string(delta["type"]) == "text_delta",
           let text = string(delta["text"]) {
            return (text, sid, model)
        }
        if !isSubagent,
           let delta = object["delta"] as? [String: Any],
           string(delta["type"]) == "text_delta",
           let text = string(delta["text"]) {
            return (text, sid, model)
        }
        if !sawTextDelta, let result = string(object["result"]) {
            return (result, sid, model)
        }
        return (nil, sid, model)
    }

    private func updateSessionIdIfNeeded(_ sid: String) async {
        guard !sid.isEmpty, sid != sessionId else { return }
        let old = sessionId
        resolvedSessionId = sid
        sessionId = sid
        if let mainToken { await Orchestrator.shared.setParentSessionId(token: mainToken, sessionId: sid) }
        await store.replaceSessionId(agentId: agentId, oldSessionId: old, newSessionId: sid, cwd: cwd)
    }

    private func emitSessionStartedIfNeeded() {
        guard !didEmitSessionStarted else { return }
        didEmitSessionStarted = true
        continuation.yield(.sessionStarted(agentId: agentId, sessionId: sessionId))
    }

    private func environment() -> [String: String] {
        var env = ChildEnvironment.base()
        // Bridge が起動した claude の目印。~/.claude/settings.json の BuddyOS hooks はこれを
        // ヘッダで送り返し、Bridge は「ターミナルのセッション」と取り違えずに無視する。
        env["BUDDYOS_SPAWNED"] = "1"
        if let mainToken { env[MainAgentWorkspace.tokenEnvVar] = mainToken }
        let additions = [
            "\(NSHomeDirectory())/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin"
        ]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (additions + [current]).joined(separator: ":")
        // ultracode tier では dynamic workflow orchestration を保証する。
        // workflows は非 pro で default-on だが、pro プランや明示 off 環境でも
        // 確実に有効化するため CLAUDE_CODE_WORKFLOWS=1 を立てる（effort とは直交）。
        if explicitEffort() == "ultracode" {
            env["CLAUDE_CODE_WORKFLOWS"] = "1"
        }
        return env
    }

    private func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }
}

actor ClaudeCodeSessionStore {
    static let shared = ClaudeCodeSessionStore()

    private struct Root: Codable {
        var sessions: [StoredSession] = []
    }

    private struct StoredSession: Codable {
        var agentId: String
        var sessionId: String
        var title: String
        var cwd: String?
        var createdAt: String
        var lastActive: String
        var messages: [StoredMessage]
    }

    private struct StoredMessage: Codable {
        var role: String
        var content: String
        var messageId: String
        var createdAt: String
    }

    private var root: Root

    private init() {
        self.root = Self.load()
    }

    func list(agentId: String, limit: Int, cwd: String?) -> [SessionSummary] {
        root.sessions
            .filter { $0.agentId == agentId }
            .filter { cwd == nil || $0.cwd == cwd }
            .sorted { $0.lastActive > $1.lastActive }
            .prefix(max(1, limit))
            .map {
                SessionSummary(
                    sessionId: $0.sessionId,
                    title: $0.title.isEmpty ? "(no messages)" : $0.title,
                    lastActive: $0.lastActive,
                    messageCount: $0.messages.count,
                    cwd: $0.cwd
                )
            }
    }

    func history(agentId: String, sessionId: String) -> [HistoryMessage] {
        guard let session = root.sessions.first(where: { $0.agentId == agentId && $0.sessionId == sessionId }) else {
            return []
        }
        return session.messages.map {
            HistoryMessage(role: $0.role, content: $0.content, messageId: $0.messageId)
        }
    }

    func ensureSession(agentId: String, sessionId: String, cwd: String?, title: String = "(no messages)") {
        _ = ensure(agentId: agentId, sessionId: sessionId, cwd: cwd, title: title)
        save()
    }

    func appendMessage(
        agentId: String,
        sessionId: String,
        role: String,
        content: String,
        cwd: String?,
        messageId: String = UUID().uuidString
    ) {
        let now = isoNow()
        let index = ensureIndex(agentId: agentId, sessionId: sessionId, cwd: cwd)
        root.sessions[index].cwd = cwd ?? root.sessions[index].cwd
        root.sessions[index].lastActive = now
        if role == "user", root.sessions[index].title == "(no messages)" {
            root.sessions[index].title = preview(content)
        }
        root.sessions[index].messages.append(StoredMessage(
            role: role,
            content: content,
            messageId: messageId,
            createdAt: now
        ))
        save()
    }

    func replaceSessionId(agentId: String, oldSessionId: String, newSessionId: String, cwd: String?) {
        guard oldSessionId != newSessionId else { return }
        let oldIndex = root.sessions.firstIndex { $0.agentId == agentId && $0.sessionId == oldSessionId }
        let newIndex = root.sessions.firstIndex { $0.agentId == agentId && $0.sessionId == newSessionId }

        switch (oldIndex, newIndex) {
        case let (.some(old), .some(new)):
            let oldSession = root.sessions[old]
            let existingIds = Set(root.sessions[new].messages.map(\.messageId))
            root.sessions[new].messages.append(contentsOf: oldSession.messages.filter { !existingIds.contains($0.messageId) })
            if root.sessions[new].title == "(no messages)" {
                root.sessions[new].title = oldSession.title
            }
            root.sessions[new].lastActive = max(root.sessions[new].lastActive, oldSession.lastActive)
            root.sessions[new].cwd = root.sessions[new].cwd ?? oldSession.cwd ?? cwd
            root.sessions.remove(at: old)
        case let (.some(old), .none):
            root.sessions[old].sessionId = newSessionId
            root.sessions[old].cwd = root.sessions[old].cwd ?? cwd
        case (.none, .some):
            break
        case (.none, .none):
            _ = ensure(agentId: agentId, sessionId: newSessionId, cwd: cwd)
        }
        save()
    }

    private func ensureIndex(agentId: String, sessionId: String, cwd: String?) -> Int {
        if let index = root.sessions.firstIndex(where: { $0.agentId == agentId && $0.sessionId == sessionId }) {
            return index
        }
        let created = ensure(agentId: agentId, sessionId: sessionId, cwd: cwd)
        return root.sessions.firstIndex(where: { $0.agentId == created.agentId && $0.sessionId == created.sessionId })!
    }

    @discardableResult
    private func ensure(agentId: String, sessionId: String, cwd: String?, title: String = "(no messages)") -> StoredSession {
        if let found = root.sessions.first(where: { $0.agentId == agentId && $0.sessionId == sessionId }) {
            return found
        }
        let now = isoNow()
        let session = StoredSession(
            agentId: agentId,
            sessionId: sessionId,
            title: title,
            cwd: cwd,
            createdAt: now,
            lastActive: now,
            messages: []
        )
        root.sessions.append(session)
        return session
    }

    private func save() {
        let url = Self.fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(root)
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[ClaudeCodeSessionStore] save failed: \(error.localizedDescription)\n".utf8))
        }
    }

    private static func load() -> Root {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(Root.self, from: data)
        } catch {
            return Root()
        }
    }

    private static var fileURL: URL {
        BuddyPaths.root.appendingPathComponent("claude-sessions.json")
    }

    private func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private func preview(_ content: String) -> String {
        let compact = content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "(no messages)" }
        return compact.count > 80 ? String(compact.prefix(77)) + "..." : compact
    }
}
