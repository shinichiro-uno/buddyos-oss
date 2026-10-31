import Foundation

/// cursor-agent / grok など「1ターン = 1プロセスの headless 実行で、行区切り JSON を
/// ストリームする」CLI を BuddyOS エージェントにするための共有アダプタ。
/// 構えは ClaudeCodeAdapter と同じ（store 履歴 / Bridge 内蔵 cron / `~/.buddyos` dotfile
/// 永続化）だが、CLI ごとにフラグ体系とストリーム形式が違うため profile で吸収する。
struct HeadlessCliProfile: Sendable {
    enum Flavor: String, Sendable {
        /// Cursor CLI。`cursor-agent -p --output-format stream-json`。
        /// イベントは Claude Code 互換形（type: system/user/assistant/result）。
        case cursor
        /// Grok Build CLI (xAI)。`grok -p --output-format streaming-json`。
        /// イベントは {type:text|thought|end}（~/.grok/docs/user-guide/14-headless-mode.md）。
        case grok
        /// Antigravity CLI (Google)。`agy -p --output-format stream-json`。
        /// イベントは {event: init|step_update|result}。本文は step_update.text_delta で届く。
        case antigravity
    }

    let flavor: Flavor
    let id: String
    let displayName: String
    /// AgentInfo.provider に載せる値。iOS のお気に入りキーやヘッダ表示で使う。
    let provider: String
    let binEnvKey: String
    let command: String
    let binaryCandidates: [String]
    /// 設定が空のときの表示用フォールバックモデル。spawn 時はユーザーが明示的に
    /// 選んだとき（= dotfile があるとき）だけ `--model` を渡す。
    let defaultModel: String?
    /// 認証前でも出す静的カタログ。認証後は listAvailableModels() が実一覧で置き換える。
    let staticCatalog: [ProviderCatalog]
    /// grok のみ `--effort low|medium|high|xhigh|max` を受ける。
    let supportsEffort: Bool

    /// UI に出す effort の選択肢（capabilities.efforts）。空 = `--effort` を持たない。
    var efforts: [String] {
        switch flavor {
        // grok の ACP の reasoning_effort は low〜xhigh（headless の --effort も同じ値を受ける）。
        case .grok: return ["low", "medium", "high", "xhigh"]
        // agy は 1.3 から low|medium|high|xhigh|max を受ける。
        case .antigravity: return ["low", "medium", "high", "xhigh", "max"]
        // cursor はモデルの変種（"…[effort=high]"）で決まり、別の設定が無い。
        case .cursor: return []
        }
    }

    /// UI に出す権限モード（capabilities.modes）。grok の --permission-mode は claude と同じ語彙、
    /// agy も `--mode accept-edits` を持つので edit を含む 4 種。cursor の headless には edit に当たるものが
    /// 無いが、ACP なら編集の承認だけを Bridge が自動で許可して edit にする（AcpSession.autoPermissionAnswer）。
    var modes: [String] {
        switch flavor {
        case .grok, .antigravity: return ["plan", "edit", "auto", "dangerous"]
        case .cursor: return usesAcp ? ["plan", "edit", "auto", "dangerous"] : ["plan", "auto", "dangerous"]
        }
    }

    /// ACP で動かすときの起動引数。nil = headless 実行だけ（agy は ACP を持たない）。
    var acpArgs: [String]? {
        switch flavor {
        case .cursor: return ["acp"]
        case .grok: return ["agent", "stdio"]
        case .antigravity: return nil
        }
    }

    /// ACP で動かすか（承認・画像・中断・ターミナルで始めた会話の一覧が付く）。
    /// `BUDDYOS_<ID>_HEADLESS=1`（例 BUDDYOS_GROK_HEADLESS=1）で従来の 1 ターン 1 プロセスの実行に戻せる。
    var usesAcp: Bool {
        acpArgs != nil && ProcessInfo.processInfo.environment["BUDDYOS_\(id.uppercased())_HEADLESS"] != "1"
    }

    /// agent_info の supportedReasoningEfforts。
    var supportedEfforts: [String]? { efforts.isEmpty ? nil : efforts }

    static let cursor = HeadlessCliProfile(
        flavor: .cursor,
        id: "cursor",
        displayName: "Cursor CLI",
        provider: "cursor",
        binEnvKey: "CURSOR_AGENT_BIN",
        command: "cursor-agent",
        binaryCandidates: [
            NSHomeDirectory() + "/.local/bin/cursor-agent",
            "/opt/homebrew/bin/cursor-agent",
            "/usr/local/bin/cursor-agent"
        ],
        defaultModel: "auto",
        staticCatalog: [
            ProviderCatalog(
                id: "cursor",
                label: "Cursor",
                models: [
                    ModelCatalogItem(id: "auto", label: "Auto", subtitle: "Cursor が最適なモデルを自動選択")
                ]
            )
        ],
        supportsEffort: false
    )

    static let grok = HeadlessCliProfile(
        flavor: .grok,
        id: "grok",
        displayName: "Grok Build",
        provider: "xai",
        binEnvKey: "GROK_BIN",
        command: "grok",
        binaryCandidates: [
            NSHomeDirectory() + "/.grok/bin/grok",
            NSHomeDirectory() + "/.local/bin/grok",
            "/opt/homebrew/bin/grok",
            "/usr/local/bin/grok"
        ],
        // 認証前のフォールバック表示のみ。認証後は grok CLI のキャッシュ
        // (~/.grok/models_cache.json) と config.toml の既定が正になる。
        // 旧既定 "grok-build" は CLI 0.2.x で提供が終わり実在しない。
        defaultModel: "grok-4.6",
        staticCatalog: [
            ProviderCatalog(
                id: "xai",
                label: "Grok (xAI)",
                models: [
                    ModelCatalogItem(id: "grok-4.6", label: "Grok 4.6", subtitle: "既定のコーディングモデル")
                ]
            )
        ],
        supportsEffort: true
    )

    /// Antigravity CLI (Google)。Gemini CLI の後継で、2026-06-18 に個人向けの
    /// Gemini CLI が停止したあとの Google 純正 CLI。`agy` バイナリ。
    /// Gemini 枠と Claude/GPT 枠でレート制限プールが分かれているのが特徴。
    static let antigravity = HeadlessCliProfile(
        flavor: .antigravity,
        id: "antigravity",
        displayName: "Antigravity",
        provider: "google",
        binEnvKey: "ANTIGRAVITY_BIN",
        command: "agy",
        binaryCandidates: [
            NSHomeDirectory() + "/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ],
        // 認証前のフォールバック表示。認証後は `agy models` の実一覧が正になる。
        defaultModel: "gemini-4-argon-medium",
        staticCatalog: [
            ProviderCatalog(
                id: "google",
                label: "Google",
                models: [
                    ModelCatalogItem(id: "gemini-4-argon-medium", label: "Gemini 4 Argon (Medium)", subtitle: "既定のコーディングモデル"),
                    ModelCatalogItem(id: "gemini-4-argon-high", label: "Gemini 4 Argon (High)", subtitle: "いちばん賢い（使える量の減りが早い）"),
                    ModelCatalogItem(id: "gemini-3.8-flash-medium", label: "Gemini 3.8 Flash (Medium)", subtitle: "軽量・高速")
                ]
            )
        ],
        supportsEffort: true
    )
}

/// Cursor CLI の API キーを解決する。CLI の `cursor-agent login`（ブラウザ OAuth）が
/// 主経路なのでキーは必須ではないが、launchd 起動の bridge でも動くよう
/// env / `~/.buddyos/cursor.token` からの注入も受け付ける。
enum CursorKey {
    static let envKeys = ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"]

    static func resolve() -> (key: String, envKey: String)? {
        let env = ProcessInfo.processInfo.environment
        for key in envKeys {
            if let v = nonEmpty(env[key]) { return (v, key) }
        }
        if let v = nonEmpty(try? String(contentsOfFile: NSHomeDirectory() + "/.buddyos/cursor.token", encoding: .utf8)) {
            return (v, "CURSOR_API_KEY")
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Grok Build CLI の認証状態。`grok login`（~/.grok/auth.json）が主経路。
/// CI 向けの XAI_API_KEY / `~/.buddyos/grok.token` も受け付ける。
enum GrokAuth {
    static func resolveApiKey() -> String? {
        if let v = nonEmpty(ProcessInfo.processInfo.environment["XAI_API_KEY"]) { return v }
        return nonEmpty(try? String(contentsOfFile: NSHomeDirectory() + "/.buddyos/grok.token", encoding: .utf8))
    }

    /// 未認証の grok は headless で終了せずハングするため、spawn 前ガードと
    /// AgentProbe の configured 判定の両方でこれを使う。
    static var isConfigured: Bool {
        if resolveApiKey() != nil { return true }
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.grok/auth.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return !obj.isEmpty
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Antigravity CLI の認証状態。実体は Antigravity IDE と共有の keychain 資格情報で、
/// ファイルパスが公開されていないため `agy models` が実モデル一覧を返せるかで判定する。
/// CLI 状態ディレクトリ (~/.gemini/antigravity-cli) は失敗した実行でも作られるため、
/// 存在チェックだけでは「認証済み」の根拠にならない。
enum AntigravityAuth {
    /// `agy models` はサブプロセス + ネットワークで数秒かかる。ガードは毎ターンの
    /// send() と AgentProbe の両方から呼ばれるため、結果を executable ごとにキャッシュする。
    /// 認証済み(true)は失効が稀なので長め、未認証(false)はサインイン直後に待たされないよう短め。
    private static let positiveTTL: TimeInterval = 30 * 60
    private static let negativeTTL: TimeInterval = 60
    private static let lock = NSLock()
    private static var cache: [String: (ok: Bool, at: Date)] = [:]

    /// AgentProbe / spawn 前ガードの両方から使う。
    static func isConfigured(executable: String) -> Bool {
        let now = Date()
        if let hit = lock.withLock({ cache[executable] }) {
            let ttl = hit.ok ? positiveTTL : negativeTTL
            if now.timeIntervalSince(hit.at) < ttl { return hit.ok }
        }
        let ok = HeadlessCliAdapter.antigravityModelsOutput(executable: executable)?
            .contains("gemini-") ?? false
        lock.withLock { cache[executable] = (ok, now) }
        return ok
    }

    /// テストや「サインインし直した」フローから明示的に捨てるため。
    static func invalidateCache() {
        lock.withLock { cache.removeAll() }
    }
}

final class HeadlessCliAdapter: BridgeCronHosted {
    var id: String { profile.id }
    var displayName: String { profile.displayName }
    var capabilities: AgentCapabilities {
        AgentCapabilities(
            commands: true,
            models: true,
            skills: true,
            mcp: true,
            efforts: profile.efforts,
            modes: profile.modes,
            // grok は leader で同じ会話をターミナルと共有できる（ターミナル連携で use_leader を入れたとき）。
            // agy はターミナル連携の hook（受け取り箱）を入れてあれば、記録を流しつつ送れる。
            terminal: (profile.flavor == .grok && profile.usesAcp && GrokLeader.isSupported(executable: executable))
                || (profile.flavor == .antigravity && AgyInbox.isInstalled())
        )
    }

    let profile: HeadlessCliProfile
    private let executable: String
    private let store: ClaudeCodeSessionStore

    init(
        profile: HeadlessCliProfile,
        executable: String? = nil,
        store: ClaudeCodeSessionStore = .shared
    ) {
        self.profile = profile
        self.executable = executable ?? Self.locateExecutable(profile)
        self.store = store
    }

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        await openSession(sessionId: sessionId, cwd: cwd, options: nil)
    }

    func openSession(sessionId: String?, cwd: String?, options: SessionOptions?) async -> AgentSession {
        if profile.usesAcp, var args = profile.acpArgs {
            // grok は共有の leader に乗る（ターミナルの grok も leader なら、同じ会話を両方で見られる）。
            if profile.flavor == .grok, GrokLeader.isSupported(executable: executable) {
                args = ["agent", "--leader", "stdio"]
            }
            // 既存の会話は CLI が記録している作業フォルダで開く（grok はパスが一字違うと会話を見つけられない）。
            var cwd = cwd
            if let sid = sessionId, let recorded = await acpSessions(args: profile.acpArgs ?? args)
                .first(where: { $0.sessionId == sid })?.cwd, !recorded.isEmpty {
                cwd = recorded
            }
            return AcpSession(
                agentId: id,
                initialSessionId: sessionId,
                executable: executable,
                args: args,
                cwd: Self.normalizedCwd(cwd),
                env: Self.processEnvironment(for: profile),
                tuning: acpTuning(cwd: Self.normalizedCwd(cwd), sessionId: sessionId, options: options)
            )
        }
        // Antigravity（agy）: 会話ごとの MCP は、--add-dir で読ませるフォルダの .agents/mcp_config.json（stdio の中継）で渡す。
        // 合鍵は agy の環境変数（中継が引き継ぐ）。
        var grant: Orchestrator.SessionGrant?
        var mcpDir: String?
        if profile.flavor == .antigravity, let relay = McpStdioRelay.currentExecutable {
            grant = await Orchestrator.shared.sessionGrant(agentId: id, sessionId: sessionId, cwd: Self.normalizedCwd(cwd),
                                                           unattended: options?.unattended == true,
                                                           heartbeat: options?.heartbeat == true)
            if let g = grant {
                mcpDir = MainAgentWorkspace.ensureAgyMcpConfig(executable: relay)
                if mcpDir == nil {
                    await Orchestrator.shared.revoke(token: g.token)
                    grant = nil
                }
            }
        }
        let session = HeadlessCliSession(
            profile: profile,
            initialSessionId: sessionId,
            cwd: Self.normalizedCwd(cwd),
            executable: executable,
            store: store,
            permissionOverride: options?.permissionMode,
            unattended: options?.unattended ?? false,
            mcpToken: grant?.token,
            mcpDir: mcpDir
        )
        if let g = grant { await Orchestrator.shared.bind(token: g.token, session: session) }
        return session
    }

    // MARK: - ACP（cursor / grok）

    /// AcpSession に渡す、この CLI ならではの違い。
    private func acpTuning(cwd: String?, sessionId: String? = nil, options: SessionOptions?) -> AcpSessionTuning {
        var t = AcpSessionTuning()
        // OpenClaw のような起動直後の取りこぼしは無い。PATH 等は env で渡すので login shell も要らない。
        t.postSessionDelayNanos = 0
        t.loginShell = false
        // 新しいチャットの初期値は、モデル設定で「既定にする」を押したときの値（~/.buddyos/<id>.*）。
        t.defaults = SessionOverrides(
            model: Self.configuredModel(for: profile),
            reasoningEffort: profile.supportsEffort ? Self.readEffort(for: profile) : nil,
            mode: Self.readMode(for: profile)
        )
        t.unattended = options?.unattended ?? false
        t.permissionMode = options?.permissionMode
        switch profile.flavor {
        case .cursor:
            // cursor の mode 設定は agent / plan / ask。BuddyOS の plan 以外は agent（承認は Bridge が答える）。
            t.modeConfigValues = ["plan": "plan", "*": "agent"]
        case .grok:
            // grok の ACP には mode の設定が無い。plan は `/plan` コマンドで入る。画像は image block を受けない。
            t.modePromptPrefix = ["plan": "/plan "]
            // ターミナルで開いている会話は、開いた時点から購読してターミナルのターンも流す。
            if GrokLeader.isSupported(executable: executable) {
                t.remoteTurns = true
                if let sid = sessionId, GrokPresence.liveSessionIds().contains(sid) { t.subscribeOnOpen = true }
            }
            t.imagesAsFiles = true
            // 背景のサブエージェントの終わりと、親が自分から始める知らせのターンを `_x.ai/*` で知る。
            // status の無い tool_call_update は子が始まる前にも来るので、tool の終わりとみなさない。
            t.xaiNotifications = true
            t.statuslessUpdateEndsTool = false
        case .antigravity:
            break
        }
        // BuddyOS の履歴にも残す（一覧をすぐ出すため・CLI 側の記録が読めないときの控え）。
        let store = self.store
        let agentId = id
        t.recorder = { role, content, messageId, sessionId in
            await store.ensureSession(agentId: agentId, sessionId: sessionId, cwd: cwd)
            await store.appendMessage(agentId: agentId, sessionId: sessionId, role: role,
                                      content: content, cwd: cwd, messageId: messageId)
        }
        return t
    }

    /// CLI の `session/list`（ターミナルで始めた会話も入る）。一覧は頻繁に読まれるので少しの間覚えておく。
    private static let acpListCache = AcpListCache()

    private func acpSessions(args: [String]) async -> [SessionSummary] {
        if let hit = await Self.acpListCache.get(id) { return hit }
        let list = (try? await withTimeout(seconds: 20) { [executable, profile] in
            try await AcpSession.listSessionsViaAcp(
                executable: executable, cwd: nil, args: args,
                env: Self.processEnvironment(for: profile), loginShell: false)
        }) ?? []
        await Self.acpListCache.put(id, list)
        return list
    }

    /// BuddyOS の履歴と CLI の一覧を合わせる。同じ会話は BuddyOS 側の件数・場所を使い、名前は CLI が付けたものを優先する。
    private func mergedAcpSessions(limit: Int, cwd: String?, args: [String]) async -> [SessionSummary] {
        let scope = Self.normalizedCwd(cwd)
        var byId: [String: SessionSummary] = [:]
        for s in await store.list(agentId: id, limit: 500, cwd: scope) { byId[s.sessionId] = s }
        for s in await acpSessions(args: args) {
            if let scope, let c = s.cwd, Self.normalizedCwd(c) != scope { continue }
            if let known = byId[s.sessionId] {
                let title = s.title == s.sessionId ? known.title : s.title
                byId[s.sessionId] = SessionSummary(sessionId: known.sessionId, title: title,
                                                   lastActive: Self.later(known.lastActive, s.lastActive),
                                                   messageCount: known.messageCount, cwd: known.cwd ?? s.cwd,
                                                   terminal: known.terminal)
            } else {
                byId[s.sessionId] = s
            }
        }
        // ターミナルで今開いている会話に印を付ける（grok は active_sessions.json で分かる）。
        if profile.flavor == .grok {
            for sid in GrokPresence.liveSessionIds() { byId[sid]?.terminal = true }
        }
        return byId.values
            .sorted { (Self.date($0.lastActive) ?? .distantPast) > (Self.date($1.lastActive) ?? .distantPast) }
            .prefix(max(1, limit))
            .map { $0 }
    }

    private static func date(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    private static func later(_ a: String, _ b: String) -> String {
        (date(a) ?? .distantPast) >= (date(b) ?? .distantPast) ? a : b
    }

    // MARK: - Sessions

    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] {
        if profile.usesAcp, let args = profile.acpArgs {
            return await mergedAcpSessions(limit: limit, cwd: cwd, args: args)
        }
        let sessions = await store.list(agentId: id, limit: limit, cwd: Self.normalizedCwd(cwd))
        guard profile.id == "antigravity" else { return sessions }
        // ターミナルの agy で今開かれている会話に緑の印を付ける。BuddyOS の履歴に無い会話
        // （ターミナルで始めたもの）は一覧に足す。cwd で絞り込み中は足さない（場所が分からない）。
        let live = AntigravityPresence.liveConversationIds()
        // agy が自動で付けた会話名があれば、BuddyOS の履歴の名前（最初の発言）より優先する。
        let summaries = AntigravitySummaries.read()
        var out = sessions.map { s -> SessionSummary in
            var s = s
            if live.contains(s.sessionId) { s.terminal = true }
            if let t = summaries[s.sessionId]?.title, !t.isEmpty {
                s = SessionSummary(sessionId: s.sessionId, title: t, lastActive: s.lastActive,
                                   messageCount: s.messageCount, cwd: s.cwd, terminal: s.terminal)
            }
            return s
        }
        if Self.nonEmpty(cwd) == nil {
            let known = Set(out.map(\.sessionId))
            let now = ISO8601DateFormatter().string(from: Date())
            for cid in live.subtracting(known).sorted() {
                let info = summaries[cid]
                let name = [info?.title, info?.preview].compactMap { $0 }.first { !$0.isEmpty } ?? "Antigravity（ターミナル）"
                var s = SessionSummary(sessionId: cid, title: name, lastActive: now,
                                       messageCount: nil, cwd: info?.cwd)
                s.terminal = true
                out.append(s)
            }
        }
        return out
    }

    func loadHistory(sessionId: String) async -> [HistoryMessage] {
        let stored = await store.history(agentId: id, sessionId: sessionId)
        // ACP の CLI は自分の記録を session/load で流し直せる（ターミナルで続けた分も入る）。長い方を出す。
        if profile.usesAcp, let args = profile.acpArgs {
            let cwd = await acpSessions(args: args).first { $0.sessionId == sessionId }?.cwd
            let loaded = (try? await withTimeout(seconds: 30) { [executable, profile] in
                try await AcpSession.loadHistoryViaAcp(
                    executable: executable, cwd: cwd, sessionId: sessionId, args: args,
                    env: Self.processEnvironment(for: profile), loginShell: false)
            }) ?? []
            return loaded.count > stored.count ? loaded : stored
        }
        // ターミナルの agy で始めた・続けた会話は BuddyOS の履歴に無い（足りない）。agy 自身の記録の方が
        // 長ければそちらを出す。
        if profile.flavor == .antigravity {
            let transcript = AntigravityTranscript.read(conversationId: sessionId)
            if transcript.count > stored.count { return transcript }
        }
        return stored
    }

    func listCommands() async -> [CommandInfo] {
        var commands: [CommandInfo] = [
            .init(id: "plan", kind: "prompt", title: "plan", subtitle: "Plan first, show options, and wait"),
            .init(id: "options", kind: "prompt", title: "options", subtitle: "Present 2-3 choices with a recommendation"),
            .init(id: "model", kind: "ui", title: "model", subtitle: "モデル設定を開く"),
            .init(id: "mode", kind: "ui", title: "mode", subtitle: "権限モード（Plan/Auto/Dangerous）")
        ]
        if profile.supportsEffort {
            commands.insert(
                .init(id: "effort", kind: "ui", title: "effort", subtitle: "推論の強さ"),
                at: 3
            )
        }
        return commands
    }

    /// ACP で開いている会話なら、CLI が知らせてきたスラッシュコマンド（grok の /compact など）も並べる。
    /// 選ぶと「/名前 」が入力欄に入り、そのまま CLI に届く。
    func listCommands(session: AgentSession?) async -> [CommandInfo] {
        var commands = await listCommands()
        guard let acp = session as? AcpSession else { return commands }
        let known = Set(commands.map(\.id))
        for c in acp.availableCommands() where !known.contains(c.name) {
            commands.append(.init(id: c.name, kind: "command", title: c.name, subtitle: c.description.isEmpty ? nil : c.description))
        }
        return commands
    }

    // MARK: - Model / effort / mode
    // モデルの既定: agy は CLI 自身の settings.json、cursor / grok は `~/.buddyos/<id>.model`。
    // effort / mode の既定は CLI の設定に置き場が無いので `~/.buddyos/<id>.{effort,mode}`。

    /// stream で判明した実モデル ID のキャッシュ（cursor の init/assistant 行が model を運ぶ）。
    private static let resolvedModelLock = NSLock()
    nonisolated(unsafe) private static var _resolvedModel: [String: String] = [:]
    static func resolvedModel(for agentId: String) -> String? {
        resolvedModelLock.withLock { _resolvedModel[agentId] }
    }
    static func setResolvedModel(_ model: String?, for agentId: String) {
        resolvedModelLock.withLock { _resolvedModel[agentId] = model }
    }

    static let validModes: Set<String> = ["plan", "edit", "auto", "dangerous"]
    static let validEfforts: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    /// env で固定されたモデル（`BUDDYOS_<ID>_MODEL`）。
    static func envModel(for profile: HeadlessCliProfile) -> String? {
        nonEmpty(ProcessInfo.processInfo.environment["BUDDYOS_\(profile.id.uppercased())_MODEL"])
    }

    /// 既定のモデル。env > CLI 自身の設定（agy）> `~/.buddyos/<id>.model`（cursor / grok）。
    static func configuredModel(for profile: HeadlessCliProfile) -> String? {
        if let env = envModel(for: profile) { return env }
        if profile.flavor == .antigravity { return antigravitySettingsModel() }
        return ClaudeCodeAdapter.readModelDotfile(profile.id + ".model")
    }

    // MARK: agy の既定モデル（~/.gemini/antigravity-cli/settings.json）
    //
    // agy は settings.json の "model" に表示名（例 "Gemini 3.8 Flash (High)"）を書く。
    // `--model` とカタログは ID（例 gemini-3.8-flash-high）なので、`agy models` の一覧で相互に変換する。

    static let antigravitySettingsPath = ".gemini/antigravity-cli/settings.json"

    /// 既定モデルの ID。一覧がまだ取れていなければ表示名のまま返す（表示用。--model には渡さない）。
    static func antigravitySettingsModel() -> String? {
        guard let label = nonEmpty(JsonSettingsFile.read(antigravitySettingsPath)?["model"] as? String) else { return nil }
        let items = (cachedCatalog(for: HeadlessCliProfile.antigravity.id, maxAge: nil) ?? []).flatMap(\.models)
        return items.first { $0.label == label }?.id ?? label
    }

    /// 既定モデルを agy の settings.json に表示名で書く（ターミナルの agy と既定を共有する）。
    private func writeAntigravityDefaultModel(_ modelId: String) throws {
        let items = defaultCatalogItems()
        guard let label = items.first(where: { $0.id == modelId || $0.label == modelId })?.label else {
            throw JsonSettingsFile.WriteError(message: "agy のモデル一覧に \(modelId) が見つからないため、既定を保存しませんでした。モデル一覧を開き直してください")
        }
        try JsonSettingsFile.update(Self.antigravitySettingsPath) { $0["model"] = label }
    }

    private func defaultCatalogItems() -> [ModelCatalogItem] {
        if let hit = Self.cachedCatalog(for: id, maxAge: nil) { return hit.flatMap(\.models) }
        guard let dynamic = fetchDynamicCatalog() else { return [] }
        Self.storeCatalog(dynamic, for: id)
        return dynamic.flatMap(\.models)
    }

    static func readMode(for profile: HeadlessCliProfile) -> String? {
        guard let v = ClaudeCodeAdapter.readModelDotfile(profile.id + ".mode") else { return nil }
        return validModes.contains(v) ? v : nil
    }

    static func readEffort(for profile: HeadlessCliProfile) -> String? {
        guard profile.supportsEffort,
              let v = ClaudeCodeAdapter.readModelDotfile(profile.id + ".effort") else { return nil }
        return validEfforts.contains(v) ? v : nil
    }

    func currentInfo() async -> AgentInfo? {
        AgentInfo(
            model: Self.resolvedModel(for: id)
                ?? Self.configuredModel(for: profile)
                ?? Self.cliDefaultModel(flavor: profile.flavor)
                ?? profile.defaultModel,
            provider: profile.provider,
            supportedReasoningEfforts: profile.supportedEfforts,
            reasoningEffort: profile.supportsEffort ? (Self.readEffort(for: profile) ?? "high") : nil,
            codexMode: Self.readMode(for: profile) ?? "auto"
        )
    }

    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?) async throws {
        if profile.supportsEffort, let effort = reasoningEffort, Self.validEfforts.contains(effort) {
            ClaudeCodeAdapter.writeModelDotfile(profile.id + ".effort", effort)
        }
        if let codexMode, Self.validModes.contains(codexMode.lowercased()) {
            ClaudeCodeAdapter.writeModelDotfile(profile.id + ".mode", codexMode.lowercased())
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if profile.flavor == .antigravity {
            try writeAntigravityDefaultModel(trimmed)
        } else {
            ClaudeCodeAdapter.writeModelDotfile(profile.id + ".model", trimmed)
        }
        Self.setResolvedModel(nil, for: id)
    }

    // MARK: - モデル一覧（認証済みなら CLI から動的取得、失敗時は静的カタログ）

    private static let modelsCacheLock = NSLock()
    nonisolated(unsafe) private static var _modelsCache: [String: (at: Date, catalog: [ProviderCatalog])] = [:]

    /// - Parameter maxAge: nil なら古くても返す（表示名 ↔ ID の変換など、一覧が少し古くても困らない用途）。
    private static func cachedCatalog(for agentId: String, maxAge: TimeInterval? = 300) -> [ProviderCatalog]? {
        modelsCacheLock.withLock {
            guard let hit = _modelsCache[agentId] else { return nil }
            if let maxAge, Date().timeIntervalSince(hit.at) >= maxAge { return nil }
            return hit.catalog
        }
    }

    private static func storeCatalog(_ catalog: [ProviderCatalog], for agentId: String) {
        modelsCacheLock.withLock { _modelsCache[agentId] = (Date(), catalog) }
    }

    func listAvailableModels() async -> [ProviderCatalog] {
        if let hit = Self.cachedCatalog(for: id) { return hit }
        let dynamic = fetchDynamicCatalog()
        if let dynamic {
            Self.storeCatalog(dynamic, for: id)
            return dynamic
        }
        return profile.staticCatalog
    }

    private func fetchDynamicCatalog() -> [ProviderCatalog]? {
        switch profile.flavor {
        case .grok:
            return Self.grokCatalogFromCache()
        case .cursor:
            return Self.cursorCatalogFromCli(executable: executable)
        case .antigravity:
            return Self.antigravityCatalogFromCli(executable: executable)
        }
    }

    /// `agy models` の出力（"<id>\t<label>" 行）をプロバイダ別カタログに畳む。
    /// Antigravity は Gemini 枠と Claude/GPT 枠でレート制限プールが別なので、
    /// UI でも同じ粒度で分けて見せる。
    static func antigravityCatalogFromCli(executable: String) -> [ProviderCatalog]? {
        guard let out = antigravityModelsOutput(executable: executable) else { return nil }
        var groups: [(id: String, label: String, items: [ModelCatalogItem])] = [
            ("google", "Google (Gemini 枠)", []),
            ("anthropic", "Anthropic (Claude/GPT 枠)", []),
            ("openai", "OpenAI (Claude/GPT 枠)", [])
        ]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].contains(" ") else { continue }
            let modelId = parts[0]
            let item = ModelCatalogItem(id: modelId, label: parts[1], subtitle: nil)
            if modelId.hasPrefix("gemini-") {
                groups[0].items.append(item)
            } else if modelId.hasPrefix("claude-") {
                groups[1].items.append(item)
            } else {
                groups[2].items.append(item)
            }
        }
        let catalogs = groups
            .filter { !$0.items.isEmpty }
            .map { ProviderCatalog(id: $0.id, label: $0.label, models: $0.items) }
        return catalogs.isEmpty ? nil : catalogs
    }

    /// `agy models` の生 stdout。認証判定とカタログ生成で共有する。
    static func antigravityModelsOutput(executable: String) -> String? {
        runForOutput(executable, ["models"], timeout: 12.0)
    }

    /// grok CLI 自身が認証時に書くモデルキャッシュ（~/.grok/models_cache.json）を読む。
    /// ネットワーク不要で launchd でも安全。hidden なモデルは出さない。
    static func grokCatalogFromCache(home: String = NSHomeDirectory()) -> [ProviderCatalog]? {
        guard let data = FileManager.default.contents(atPath: home + "/.grok/models_cache.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [String: Any], !models.isEmpty else { return nil }
        var items: [ModelCatalogItem] = []
        for (modelId, value) in models {
            let info = (value as? [String: Any])?["info"] as? [String: Any] ?? [:]
            if (info["hidden"] as? Bool) == true { continue }
            items.append(ModelCatalogItem(
                id: modelId,
                label: (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? modelId,
                subtitle: info["description"] as? String
            ))
        }
        guard !items.isEmpty else { return nil }
        // CLI 側の既定モデル (config.toml の [models] default) を先頭へ、
        // それ以外は id 順で安定させる。
        let defaultId = grokCliDefaultModel(home: home) ?? "grok-build"
        items.sort { a, b in
            if a.id == defaultId { return true }
            if b.id == defaultId { return false }
            return a.id < b.id
        }
        return [ProviderCatalog(id: "xai", label: "Grok (xAI)", models: items)]
    }

    /// `~/.grok/config.toml` の `[models] default` を読む。既定モデル名を BuddyOS 側で
    /// ハードコードすると、xAI 側の改名 (grok-build → grok-4.5 等) で実在しないモデルを
    /// 既定表示してしまうため、CLI 自身の設定を正とする。無ければ nil。
    static func grokCliDefaultModel(home: String = NSHomeDirectory()) -> String? {
        guard let raw = try? String(contentsOfFile: home + "/.grok/config.toml", encoding: .utf8) else {
            return nil
        }
        var inModels = false
        for line in raw.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                inModels = (t == "[models]")
                continue
            }
            guard inModels, let eq = t.firstIndex(of: "=") else { continue }
            guard t[..<eq].trimmingCharacters(in: .whitespaces) == "default" else { continue }
            let value = t[t.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `cursor-agent --list-models` から一覧を取る（要ログイン。未ログインは exit≠0 → nil）。
    static func cursorCatalogFromCli(executable: String) -> [ProviderCatalog]? {
        guard let out = runForOutput(executable, ["--list-models"], timeout: 10),
              !out.isEmpty else { return nil }
        return cursorCatalogFromListOutput(out)
    }

    /// `--list-models` 出力のパース本体。素の id 一覧(旧形式)と `id - 表示名` 形式
    /// (例: "gpt-5.3-codex - Codex 5.3") の両対応。旧実装は「スペースを含む行を除外」
    /// していたため新形式では全行が弾かれ、静的カタログ(auto のみ)へ落ちる
    /// =「モデルが取得できない」不具合だった。
    static func cursorCatalogFromListOutput(_ out: String, home: String = NSHomeDirectory()) -> [ProviderCatalog]? {
        var items: [ModelCatalogItem] = []
        var markedDefault: String?
        for raw in out.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*-• "))
            guard !line.isEmpty else { continue }
            var label: String?
            if let sep = line.range(of: " - ") {
                label = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                line = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            // モデル ID らしい行だけ拾う（"Available models" 等の案内文を除外）。
            guard !line.contains(" "), line.count < 64,
                  line.range(of: "^[A-Za-z0-9][A-Za-z0-9._\\[\\]=,-]*$", options: .regularExpression) != nil
            else { continue }
            if let l = label, l.lowercased().contains("(default)") {
                markedDefault = line
            }
            let clean = label?
                .replacingOccurrences(of: "(default)", with: "")
                .trimmingCharacters(in: .whitespaces)
            items.append(ModelCatalogItem(
                id: line,
                label: (clean?.isEmpty == false) ? clean! : line,
                subtitle: nil
            ))
        }
        guard !items.isEmpty else { return nil }
        // 既定を先頭へ: ユーザーが CLI 側で選んだモデル (cli-config.json) > "(default)" 印。
        // それ以外は CLI の出力順(モデルファミリ順)を保つ。
        if let pin = cursorCliDefaultModel(home: home) ?? markedDefault,
           let idx = items.firstIndex(where: { $0.id == pin }), idx > 0 {
            items.insert(items.remove(at: idx), at: 0)
        }
        return [ProviderCatalog(id: "cursor", label: "Cursor", models: items)]
    }

    /// `~/.cursor/cli-config.json` の `model.modelId` を読む。cursor-agent が `--model`
    /// 無しのとき実際に使う既定モデルはこれ (grok の config.toml と同じ構図で、
    /// CLI 側の設定を正とする)。無ければ nil。
    static func cursorCliDefaultModel(home: String = NSHomeDirectory()) -> String? {
        guard let data = FileManager.default.contents(atPath: home + "/.cursor/cli-config.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let modelId = ((obj["model"] as? [String: Any])?["modelId"] as? String)
            ?? ((obj["selectedModel"] as? [String: Any])?["modelId"] as? String)
        guard let modelId, !modelId.isEmpty else { return nil }
        return modelId
    }

    /// CLI 側の設定に書かれた既定モデル (BuddyOS の dotfile 未設定時の表示用)。
    static func cliDefaultModel(flavor: HeadlessCliProfile.Flavor) -> String? {
        switch flavor {
        case .grok: return grokCliDefaultModel()
        case .cursor: return cursorCliDefaultModel()
        // agy の既定は configuredModel が settings.json から読む（ここまで来るのは未設定のとき）。
        case .antigravity: return nil
        }
    }

    /// exit 0 のときだけ stdout を返す簡易ランナー（モデル一覧の動的取得用）。
    /// ProcessRunner 経由 (waitUntilExit のスレッド滞留 → fd リーク → EBADF 障害の再発防止)。
    private static func runForOutput(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let (exe, argv): (String, [String]) = path.hasPrefix("/")
            ? (path, args)
            : ("/usr/bin/env", [path] + args)
        guard let r = ProcessRunner.run(exe, argv, timeout: timeout),
              !r.timedOut, r.status == 0 else { return nil }
        return String(data: r.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func locateExecutable(_ profile: HeadlessCliProfile) -> String {
        if let override = nonEmpty(ProcessInfo.processInfo.environment[profile.binEnvKey]) {
            return override
        }
        return profile.binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? profile.command
    }

    private static func normalizedCwd(_ cwd: String?) -> String? {
        guard let cwd = nonEmpty(cwd) else { return nil }
        let home = NSHomeDirectory()
        if cwd == "~" { return home }
        if cwd.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        // /private/var → /var のように「/private」を落とさない（grok は会話を作業フォルダのパスそのものごとに持つ）。
        let standardized = (cwd as NSString).standardizingPath
        if cwd.hasPrefix("/private/"), "/private" + standardized == cwd { return cwd }
        return standardized
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class HeadlessCliSession: AgentSession, SessionOverridable {
    private(set) var sessionId: String
    let events: AsyncThrowingStream<SessionEvent, Error>

    private let profile: HeadlessCliProfile
    private var agentId: String { profile.id }
    private let cwd: String?
    private let executable: String
    private let store: ClaudeCodeSessionStore
    private let permissionOverride: String?
    /// 無人実行（cron）。答える人がいないので、agy の承認 hook は使わない（従来どおり agy が自動で拒否する）。
    private let unattended: Bool
    /// Bridge の MCP の合鍵（agy だけ。Orchestrator）。あれば mcpDir を --add-dir で読ませ、合鍵と番号を環境変数で渡す。
    /// 閉じたら無効にする。
    let mcpToken: String?
    /// agy に読ませる MCP の設定のフォルダ（.agents/mcp_config.json。合鍵は含まない）。
    private let mcpDir: String?
    /// このターンの agy の承認 hook のトークン（AgyApprovalRegistry）。procLock で保護。
    private var hookToken: String?
    /// このターンの hook の置き場（見張りに使う）。procLock で保護。
    private var hookInstall: AgyApprovalHook.Installation?
    /// このターンの agy の許可・拒否リスト。ターンの開始時に一度だけ読む（ターンの途中で agy が
    /// settings.json を書き換えても、そのターンの判断は変わらない）。procLock で保護。
    private var hookRules: (allow: [String], deny: [String]) = ([], [])
    /// iPhone の答えを待っている承認（requestId → 再開）。procLock で保護。
    private var pendingApprovals: [String: CheckedContinuation<Bool, Never>] = [:]
    /// ターミナルで開いている agy の会話を流す（antigravity のみ）。procLock で保護。
    private var terminalMirror: AntigravityTerminalMirror?
    /// 受け取り箱経由でターミナルの agy に送った文（記録に戻ってきたときに二重に流さない）。procLock で保護。
    private var sentToTerminal: [String] = []
    /// 流し中の道具（記録では結果が順に来るので、来た順に閉じる）。procLock で保護。
    private var mirrorTools: [(id: String, name: String)] = []
    /// ターミナルのターンの途中か（終わりで done を出す）。procLock で保護。
    private var mirrorTurnActive = false
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private var didEmitSessionStarted: Bool
    private var resolvedSessionId: String?
    /// grok のセッションが CLI 側にもうあるか。grok 1.0 の `-s` は新規作成専用（既存 ID はエラー）なので、
    /// あるなら `-r` で再開する。開き直し（resume）は最初からある扱い。
    private var grokSessionExists: Bool
    private let procLock = NSLock()
    private var currentProcess: Process?
    private var didInterrupt = false
    /// watchdog 用。ストリームから 1 バイトでも出力を観測したら true。
    private var sawAnyOutput = false
    /// サブエージェントの進行（Cursor の Task・Grok の task）。セッションに 1 つ持つ（ターンごとに作り直すと index が
    /// 0 から振り直しになる）。1 ターン 1 プロセスなので、プロセスが終わったら実行中の行は閉じる。procLock で保護する。
    private var subagents = SubagentTracker()
    /// このチャットだけのモデル / Effort / モード。ターンごとの起動引数にだけ使う。procLock で保護する。
    private var overrides = SessionOverrides.none

    func applyOverrides(_ overrides: SessionOverrides) {
        procLock.withLock { self.overrides = overrides }
    }

    private var currentOverrides: SessionOverrides { procLock.withLock { overrides } }

    /// `--model` に渡すモデル。チャットの上書き > 既定。
    /// agy の既定は CLI が自分の settings.json から読むので、env で固定したときだけ明示する。
    private func effectiveModel() -> String? {
        if let m = currentOverrides.model { return m }
        if profile.flavor == .antigravity { return HeadlessCliAdapter.envModel(for: profile) }
        return HeadlessCliAdapter.configuredModel(for: profile)
    }

    private func effectiveEffort() -> String? {
        guard profile.supportsEffort else { return nil }
        if let e = currentOverrides.reasoningEffort, HeadlessCliAdapter.validEfforts.contains(e) { return e }
        return HeadlessCliAdapter.readEffort(for: profile)
    }

    private func effectiveMode() -> String? {
        if let m = currentOverrides.mode, HeadlessCliAdapter.validModes.contains(m) { return m }
        return HeadlessCliAdapter.readMode(for: profile)
    }

    init(
        profile: HeadlessCliProfile,
        initialSessionId: String?,
        cwd: String?,
        executable: String,
        store: ClaudeCodeSessionStore,
        permissionOverride: String? = nil,
        unattended: Bool = false,
        mcpToken: String? = nil,
        mcpDir: String? = nil
    ) {
        self.unattended = unattended
        self.mcpToken = mcpToken
        self.mcpDir = mcpDir
        self.profile = profile
        self.cwd = cwd
        self.executable = executable
        self.store = store
        self.permissionOverride = permissionOverride
        switch profile.flavor {
        case .grok:
            // 新規でもこちらで ID を採番し、初回は `-s <id>` で作らせる（stream からの解決待ち不要）。
            self.resolvedSessionId = initialSessionId ?? UUID().uuidString.lowercased()
            self.sessionId = self.resolvedSessionId!
        case .cursor, .antigravity:
            // cursor の chatId / agy の conversation_id は CLI が採番する。
            // 初回は stream の init/result 行で解決する。
            self.resolvedSessionId = initialSessionId
            self.sessionId = initialSessionId ?? "pending-\(UUID().uuidString.prefix(8))"
        }
        self.didEmitSessionStarted = initialSessionId != nil
        self.grokSessionExists = initialSessionId != nil

        var continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { c in
            continuation = c
        }
        self.continuation = continuation
        // ターミナルの agy で開いている会話は、開いた時点からターミナルのターンを流す。
        if profile.flavor == .antigravity, let sid = initialSessionId,
           AntigravityPresence.liveConversationIds().contains(sid) {
            startTerminalMirror(conversationId: sid)
        }
    }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        // ターミナルの agy で開いている会話には、別の agy を起動せず受け取り箱で渡す（ターミナル連携の hook が要る）。
        if profile.flavor == .antigravity, let sid = resolvedSessionId, isUUID(sid),
           AgyInbox.isInstalled(), AntigravityPresence.liveConversationIds().contains(sid) {
            await sendToTerminal(text: text, skills: skills, attachments: attachments, conversationId: sid)
            return
        }
        let busy = procLock.withLock { currentProcess != nil }
        if busy {
            WebSocketServer.wslog("\(agentId) refused concurrent send (turn in flight) session=\(sessionId)")
            // 黙って捨てると、実行されていないメッセージが送信済みに見えたままになるので通知だけ流す。
            // user_message は send の前に inputAck 済み（iOS の送信表示は解除済み）なので、⚠・再送導線は出せない。
            // error は iOS でターン終端として扱われ、実行中ターンを表示している全購読者の画面を idle に
            // 戻してしまうため、ターン状態に触れない proactive で知らせる。
            continuation.yield(SessionEvent(
                type: .proactive,
                agentId: agentId,
                sessionId: sessionId,
                messageId: UUID().uuidString,
                toolUseId: nil,
                content: "\(profile.displayName) は前のターンを実行中のため、直前に送ったメッセージは実行されませんでした。完了後にもう一度送ってください。",
                toolName: nil,
                metadata: nil
            ))
            return
        }

        let messageId = UUID().uuidString
        // 新しいターン。終わった行を忘れる（アプリも送信で終わった行を捨てる）。
        procLock.withLock { subagents.pruneFinished() }

        // 未認証の agy は認証フローに入ろうとして headless で止まるため、spawn 前に弾く。
        if profile.flavor == .antigravity, !AntigravityAuth.isConfigured(executable: executable) {
            emitTurnError(
                "Antigravity CLI が未認証です。ターミナルで `agy` を一度起動して Google アカウントでサインインしてください（Antigravity IDE にサインイン済みなら資格情報が共有されます）。",
                messageId: messageId
            )
            return
        }

        // 未認証の grok は headless で終了せず無応答のままハングするため、spawn 前に弾く。
        if profile.flavor == .grok, !GrokAuth.isConfigured {
            emitTurnError("Grok CLI が未認証です。ターミナルで `grok login` を実行するか、~/.buddyos/grok.token に API キーを置いてください。", messageId: messageId)
            return
        }

        // 画像はファイルに書き出してパスを渡す（headless 実行には画像を渡す口が無い）。
        var imageFiles: [URL?] = []
        for attachment in attachments {
            imageFiles.append(attachment.kind == .image
                ? await AttachmentStore.shared.exportFile(name: attachment.name, mime: attachment.mime, data: attachment.data)
                : nil)
        }
        let prompt = promptText(text: text, skills: skills, attachments: attachments, files: imageFiles)
        let extraDirs = imageFiles.contains { $0 != nil } ? [AttachmentStore.exportDirectory.path] : []
        await store.ensureSession(agentId: agentId, sessionId: sessionId, cwd: cwd)
        await store.appendMessage(agentId: agentId, sessionId: sessionId, role: "user", content: prompt, cwd: cwd)

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        // agy の承認を iPhone で受ける（auto / edit のとき）。hook は agy の全体設定のプラグインから読まれるので、
        // hook の置き場は作業フォルダ（--add-dir）に足さない（エージェントが自分で書き換えられないように）。
        let hookEnv = await beginApprovalHookIfNeeded(workspaces: [cwd ?? FileManager.default.currentDirectoryPath] + extraDirs)
        defer { endApprovalHook() }
        configure(process: process, prompt: prompt, extraDirs: extraDirs, extraEnv: hookEnv)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // stdout / stderr は readabilityHandler で吸い上げる（PipeLineReader 参照）。
        let reader = PipeLineReader(
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading,
            onOutput: { [weak self] in self?.markOutputSeen() }
        )
        // 終了検知は terminationHandler で受ける（waitUntilExit で cooperative スレッドを塞がない）。
        // run() より前に張らないと、即終了する CLI の終了通知を取りこぼす。
        process.terminationHandler = { [weak reader] _ in reader?.processDidExit() }

        do {
            try process.run()
            // 子プロセスを独自プロセスグループのリーダーにし、interrupt/close で
            // 子孫ごと kill できるようにする（ClaudeCodeSession と同じ方式）。
            let pid = process.processIdentifier
            if pid > 0 {
                _ = setpgid(pid, pid)
                SpawnRegistry.register(pid: pid, command: profile.command + " " + (process.arguments ?? []).joined(separator: " "))
            }
            stdin.fileHandleForWriting.closeFile()
            procLock.withLock { currentProcess = process; didInterrupt = false; sawAnyOutput = false }
        } catch {
            emitTurnError("\(profile.displayName) spawn failed: \(error.localizedDescription)", messageId: messageId)
            return
        }
        // 承認 hook を使うターンは、hook のファイルを見張る。ターンの途中で書き換えられたら（agy 自身が
        // 承認を外そうとした恐れ）、そのターンの残りを書き換え後の hook で動かさないよう、すぐ止める。
        let install = procLock.withLock { hookInstall }
        let hookWatch: AgyHookTamperWatch? = hookEnv.isEmpty ? nil
            // 置き場が分からなければ見張れない（下で isComplete が false になり、止める）。
            : AgyHookTamperWatch(paths: install?.watchedPaths ?? [], executables: install?.executables ?? []) { [weak self] in
            WebSocketServer.wslog("[agy-hook] hook files changed during a turn → stopping agy")
            Self.terminateProcessGroup(self?.procLock.withLock { self?.currentProcess })
        }
        if let hookWatch, !hookWatch.isComplete || install == nil {
            // ensureInstalled の直後なので通常は起きない。見張れないまま続けない。
            hookWatch.cancel()
            Self.terminateProcessGroup(process)
            emitTurnError("承認の仕組みのファイルを確かめられなかったため、Antigravity を止めました。もう一度送ってください。", messageId: messageId)
            procLock.withLock { currentProcess = nil }
            return
        }
        defer { hookWatch?.cancel() }

        // 読み取りは run() 成功後に登録する（無効 fd へ dispatch source を張らないため）。
        reader.start()

        // 認証切れ等で CLI が無出力のままハングするのを検知する watchdog。
        // 90 秒間 stdout / stderr が 1 バイトも出なければ打ち切る
        // （正常時は thought/text/ログが早々に流れるので誤爆しない）。
        let watchdog = Task { [weak self] () -> Bool in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled, let self else { return false }
            let (quiet, p) = self.procLock.withLock { (!self.sawAnyOutput, self.currentProcess) }
            if quiet, let p, p.isRunning {
                Self.terminateProcessGroup(p)
                return true
            }
            return false
        }

        // reader.lines は CLI 本体の終了後、stdout/stderr の EOF（または猶予切れ）で終わる。
        // AsyncStream は消費側タスクのキャンセルで打ち切られるため、呼び出し元のキャンセルに
        // 引きずられず従来どおりプロセス終了まで読み切るよう、非構造化 Task で回す。
        let pump = Task { () -> (assistant: String, stdoutError: String?) in
            var assistant = ""
            var sawTextDelta = false
            var stdoutError: String?
            for await rawLine in reader.lines {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                for p in self.procLock.withLock({ self.subagentPayloads(line, tracker: &self.subagents) }) {
                    self.continuation.yield(.workflowProgress(agentId: self.agentId, sessionId: self.sessionId, payloadJSON: p))
                }
                if let data = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["type"] as? String == "error",
                   let message = object["message"] as? String {
                    stdoutError = message
                    continue
                }
                let parsed = self.parseLine(line, sawTextDelta: sawTextDelta)
                if let sid = parsed.sessionId {
                    await self.updateSessionIdIfNeeded(sid)
                }
                // チャットでモデルを上書きしているときは、エージェント既定の表示を書き換えない。
                if let model = parsed.model, !model.isEmpty, self.currentOverrides.model == nil,
                   HeadlessCliAdapter.resolvedModel(for: self.agentId) != model {
                    HeadlessCliAdapter.setResolvedModel(model, for: self.agentId)
                    // iOS は agentInfoResult を全置換のスナップショットとして扱うので、currentInfo() と同じ
                    // effort / mode も載せる（載せないと mode と effort の表示が消える）。
                    self.continuation.yield(.agentInfoResult(
                        agentId: self.agentId,
                        model: model,
                        provider: self.profile.provider,
                        supportedReasoningEfforts: self.profile.supportedEfforts,
                        reasoningEffort: self.profile.supportsEffort
                            ? (HeadlessCliAdapter.readEffort(for: self.profile) ?? "high") : nil,
                        codexMode: HeadlessCliAdapter.readMode(for: self.profile) ?? "auto"
                    ))
                }
                if let delta = parsed.text, !delta.isEmpty {
                    self.emitSessionStartedIfNeeded()
                    sawTextDelta = true
                    assistant += delta
                    self.continuation.yield(.assistantDelta(delta, agentId: self.agentId, sessionId: self.sessionId, messageId: messageId))
                } else if parsed.sessionId != nil {
                    self.emitSessionStartedIfNeeded()
                }
            }
            return (assistant, stdoutError)
        }
        let (pumpedText, stdoutError) = await pump.value
        var assistant = pumpedText
        // watchdog の sleep がターン完了後も残らないようキャンセルする。
        watchdog.cancel()
        let watchdogTripped = await watchdog.value
        let stderrText = reader.stderrText

        let wasInterrupted = procLock.withLock { currentProcess = nil; return didInterrupt }
        // 1 ターン 1 プロセスなので、プロセスが終わった後に行の終わりの知らせは来ない。どの終わり方でも、まだ実行中の
        // 行を done / error より先に閉じる（止めた・正常に終わったなら stopped、異常終了なら failed）。
        let abnormal = !wasInterrupted && hookWatch?.tripped != true
            && (watchdogTripped || stdoutError != nil || process.terminationStatus != 0)
        abandonSubagents(state: abnormal ? "failed" : "stopped")
        if hookWatch?.tripped == true {
            emitTurnError("承認の仕組みのファイルがターンの途中で書き換えられたため、Antigravity を止めました。"
                          + "次の送信の前に Bridge が元に戻します。", messageId: messageId)
            return
        }
        if wasInterrupted {
            if !assistant.isEmpty {
                await store.appendMessage(
                    agentId: agentId, sessionId: sessionId, role: "assistant",
                    content: assistant, cwd: cwd, messageId: messageId
                )
            }
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
            return
        }

        if watchdogTripped {
            let hint = profile.flavor == .grok
                ? "Grok CLI が応答しません。認証が切れている可能性があります。ターミナルで `grok login` を実行してください。"
                : "\(profile.displayName) が応答しません。ターミナルで `\(profile.command)` を一度起動して状態を確認してください。"
            emitTurnError(hint, messageId: messageId)
            return
        }

        if let stdoutError {
            emitTurnError(stdoutError, messageId: messageId)
            return
        }
        if process.terminationStatus != 0 {
            let errText = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            // 「既に使われている ID」で失敗したなら、CLI 側にはもうある。次の送信から -r で再開する。
            if profile.flavor == .grok, errText.contains("already in use") { grokSessionExists = true }
            emitTurnError(errText.isEmpty ? "\(profile.displayName) exited \(process.terminationStatus)" : errText, messageId: messageId)
            return
        }

        emitSessionStartedIfNeeded()
        if profile.flavor == .grok { grokSessionExists = true }
        // agy の headless は、確認が要る道具を聞けずに自動で拒否し、空の返事のまま成功で終わる。
        // 何も出ないと壊れて見えるので、理由と抜け道を返事として出す。
        if assistant.isEmpty, profile.flavor == .antigravity, stderrText.contains("auto-denied") {
            assistant = "Antigravity が操作の許可を求めましたが、このモードでは答えられないため自動で拒否されました。権限モードを Edit か Full Access にして送り直してください。"
            continuation.yield(.assistantDelta(assistant, agentId: agentId, sessionId: sessionId, messageId: messageId))
        }
        if assistant.isEmpty {
            continuation.yield(.assistantDelta("", agentId: agentId, sessionId: sessionId, messageId: messageId))
        } else {
            await store.appendMessage(
                agentId: agentId,
                sessionId: sessionId,
                role: "assistant",
                content: assistant,
                cwd: cwd,
                messageId: messageId
            )
        }
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
    }

    func interrupt() async {
        let p = procLock.withLock { didInterrupt = true; return currentProcess }
        resolveAllApprovals(allow: false)
        Self.terminateProcessGroup(p)
    }

    func close() async {
        let p = procLock.withLock { let p = currentProcess; currentProcess = nil; return p }
        let mirror = procLock.withLock { () -> AntigravityTerminalMirror? in let m = terminalMirror; terminalMirror = nil; return m }
        mirror?.stop()
        resolveAllApprovals(allow: false)
        Self.terminateProcessGroup(p)
        // プロセスを止めたので、実行中の行は stopped で閉じる（send の後片付けは stream を閉じた後になる）。
        abandonSubagents(state: "stopped")
        continuation.finish()
        if let mcpToken { await Orchestrator.shared.revoke(token: mcpToken) }
    }

    /// サブエージェントのカードの全行（workflow_snapshot。行が無くても agents: []）。agy は行を作らないので nil。
    func subagentSnapshot() async -> String? {
        guard profile.flavor != .antigravity else { return nil }
        return procLock.withLock { subagents.snapshot(includeEmpty: true) }
    }

    /// 実行中の行を閉じて流す（プロセスが終わった・止めた）。
    private func abandonSubagents(state: String) {
        guard let p = procLock.withLock({ subagents.abandonRunning(state: state) }) else { return }
        continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: p))
    }

    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {
        resolveApproval(requestId, allow: decision == "allow")
    }

    // MARK: - ターミナルの agy（AntigravityTerminalMirror / AgyInbox）

    private func startTerminalMirror(conversationId: String) {
        let mirror = AntigravityTerminalMirror(conversationId: conversationId) { [weak self] event in
            self?.handleMirror(event)
        }
        let started = procLock.withLock { () -> Bool in
            guard terminalMirror == nil else { return false }
            terminalMirror = mirror
            return true
        }
        if started { mirror.start() }
    }

    /// ターミナルのターンを iPhone 向けのイベントにする。Bridge 自身が agy を動かしている間は、
    /// そのターンを send() が流しているので記録からは流さない。
    private func handleMirror(_ event: AntigravityTerminalMirror.Event) {
        if procLock.withLock({ currentProcess != nil }) { return }
        switch event {
        case .user(let text):
            let mine = procLock.withLock { () -> Bool in
                mirrorTurnActive = true
                guard let i = sentToTerminal.firstIndex(where: { text.contains($0) || $0.contains(text) }) else { return false }
                sentToTerminal.remove(at: i)
                return true
            }
            if !mine { continuation.yield(.userMessage(text, agentId: agentId, sessionId: sessionId)) }
        case .assistant(let text):
            procLock.withLock { mirrorTurnActive = true }
            let mid = UUID().uuidString
            continuation.yield(.assistantDelta(text, agentId: agentId, sessionId: sessionId, messageId: mid))
            continuation.yield(.assistantTurnEnd(agentId: agentId, sessionId: sessionId, messageId: mid))
        case .toolStart(let name):
            let id = UUID().uuidString
            procLock.withLock { mirrorTurnActive = true; mirrorTools.append((id, name)) }
            continuation.yield(.toolStart(agentId: agentId, sessionId: sessionId, toolUseId: id,
                                          toolName: name, title: name, kind: "other"))
        case .toolEnd:
            guard let tool = procLock.withLock({ mirrorTools.isEmpty ? nil : mirrorTools.removeFirst() }) else { return }
            continuation.yield(.toolEnd(agentId: agentId, sessionId: sessionId, toolUseId: tool.id,
                                        toolName: tool.name, status: "completed", summary: nil, durationMs: nil))
        case .turnEnd:
            let wasActive = procLock.withLock { () -> Bool in let a = mirrorTurnActive; mirrorTurnActive = false; mirrorTools.removeAll(); return a }
            if wasActive { continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString)) }
        }
    }

    /// 受け取り箱へ置く。agy が次にモデルを呼ぶときに hook が会話へ入れ、その後の返事は記録から流れる。
    private func sendToTerminal(text: String, skills: [String], attachments: [BridgeAttachment], conversationId: String) async {
        let messageId = UUID().uuidString
        let prompt = promptText(text: text, skills: skills, attachments: attachments)
        do {
            try AgyInbox.enqueue(conversationId: conversationId, text: prompt)
        } catch {
            emitTurnError("ターミナルの Antigravity に渡せませんでした: \(error.localizedDescription)", messageId: messageId)
            return
        }
        procLock.withLock { sentToTerminal.append(prompt) }
        startTerminalMirror(conversationId: conversationId)
        await store.ensureSession(agentId: agentId, sessionId: sessionId, cwd: cwd)
        await store.appendMessage(agentId: agentId, sessionId: sessionId, role: "user", content: prompt, cwd: cwd)
        continuation.yield(SessionEvent(
            type: .proactive, agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString,
            toolUseId: nil,
            content: "ターミナルの Antigravity に渡しました。agy が次に考え始めるときに入ります（入力待ちで止まっているときは、ターミナルで何か送るまで届きません）。",
            toolName: nil, metadata: nil
        ))
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
    }

    // MARK: - agy の承認（AgyApprovalHook）

    /// auto / edit のターンだけ hook を有効にし、agy に渡す環境変数を返す（使わないときは空）。
    /// workspaces: このターンの agy のワークスペース（同じ名前の hook で上書きされていないかを確かめる）。
    private func beginApprovalHookIfNeeded(workspaces: [String]) async -> [String: String] {
        guard profile.flavor == .antigravity, !unattended, permissionOverride == nil else { return [:] }
        let mode = effectiveMode() ?? "auto"
        guard mode == "auto" || mode == "edit", let port = KeyStore.currentPort,
              let install = AgyApprovalHook.ensureInstalled(workspaces: workspaces) else { return [:] }
        let token = await AgyApprovalRegistry.shared.register { [weak self] body in
            guard let self else { return Self.hookReply(["decision": "deny", "reason": "BuddyOS のチャットが閉じられました。"]) }
            return await self.handleApprovalHook(body)
        }
        let rules = AgyApprovalPolicy.loadRules()
        procLock.withLock { hookToken = token; hookRules = rules; hookInstall = install }
        return [
            "BUDDYOS_AGY_HOOK_URL": "http://127.0.0.1:\(port)/antigravity/hook",
            "BUDDYOS_AGY_HOOK_TOKEN": token
        ]
    }

    private func endApprovalHook() {
        let token = procLock.withLock { () -> String? in let t = hookToken; hookToken = nil; hookInstall = nil; return t }
        resolveAllApprovals(allow: false)
        if let token { Task { await AgyApprovalRegistry.shared.unregister(token) } }
    }

    private var approvalHookActive: Bool { procLock.withLock { hookToken != nil } }

    /// hook の問い合わせ 1 件。読み取り専用の道具と作業フォルダの中の書き込みは通し、
    /// コマンド実行は許可リストに無ければ、それ以外の道具は常に iPhone に聞く（AgyApprovalPolicy）。
    private func handleApprovalHook(_ body: Data) async -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Self.hookReply(["decision": "deny", "reason": "承認の問い合わせを読めませんでした。"])
        }
        let call = obj["toolCall"] as? [String: Any] ?? [:]
        let args = call["args"] as? [String: Any] ?? [:]
        let rules = procLock.withLock { hookRules }
        let out: [String: Any]
        switch AgyApprovalPolicy.verdict(toolName: call["name"] as? String ?? "", args: args,
                                         allow: rules.allow, deny: rules.deny, cwd: cwd, bridgeMcp: mcpToken != nil) {
        case .allow:
            out = ["decision": "allow"]
        case .deny(let reason):
            out = ["decision": "deny", "reason": reason]
        case .ask(let title, let detail):
            let ok = await askOnPhone(title: title, detail: detail)
            out = ok ? ["decision": "allow"] : ["decision": "deny", "reason": "ユーザーが iPhone で拒否しました。"]
        }
        return Self.hookReply(out)
    }

    private func askOnPhone(title: String, detail: String?) async -> Bool {
        let requestId = UUID().uuidString
        let meta: [String: String] = [
            "requestId": requestId,
            "kind": "approval",
            "option_count": "2",
            "option_0_title": "許可",
            "option_0_value": "allow",
            "option_1_title": "拒否",
            "option_1_value": "deny",
            "allowsOther": "0"
        ]
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            procLock.withLock { pendingApprovals[requestId] = c }
            continuation.yield(.actionRequest(agentId: agentId, sessionId: sessionId, messageId: requestId,
                                              title: title, subtitle: detail, metadata: meta))
            // 答えが来なければ、hook が打ち切られる前に拒否で返す。
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(AgyApprovalHook.timeoutSeconds - 30) * 1_000_000_000)
                self?.resolveApproval(requestId, allow: false)
            }
        }
    }

    private func resolveApproval(_ requestId: String, allow: Bool) {
        let c = procLock.withLock { pendingApprovals.removeValue(forKey: requestId) }
        c?.resume(returning: allow)
    }

    private func resolveAllApprovals(allow: Bool) {
        let all = procLock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            let v = Array(pendingApprovals.values); pendingApprovals.removeAll(); return v
        }
        for c in all { c.resume(returning: allow) }
    }

    private static func hookReply(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data(#"{"decision":"deny"}"#.utf8)
    }

    private func markOutputSeen() {
        procLock.lock()
        sawAnyOutput = true
        procLock.unlock()
    }

    private func emitError(_ message: String, messageId: String) {
        continuation.yield(SessionEvent(
            type: .error,
            agentId: agentId,
            sessionId: sessionId,
            messageId: messageId,
            toolUseId: nil,
            content: message,
            toolName: nil,
            metadata: nil
        ))
    }

    /// ターンをエラーで終える。.error だけだと SessionHub で予約の実行・購読者ゼロでの close・push が
    /// 走らないので、同じ messageId の done を続けて流す（BuddySession.emitError と同じ error→done）。
    /// 前のターンが走っている間の同時送信の拒否には使わない（走っているターンが残っているのに idle になる）。
    private func emitTurnError(_ message: String, messageId: String) {
        emitError(message, messageId: messageId)
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
    }

    private static func terminateProcessGroup(_ p: Process?) {
        guard let p else { return }
        let pid = p.processIdentifier
        // 本体が終了済みでも、パイプを握った子孫（MCP サーバ等）がグループに残っていれば
        // kill(-pid) で届く。メンバーが残っている間は pgid は再利用されず、誰もいなければ
        // ESRCH になるだけ（currentProcess は send 完了で nil に戻るので古い pid には撃たない）。
        if pid > 0 {
            kill(-pid, SIGTERM)
            SpawnRegistry.unregister(pid: pid)
        }
        if p.isRunning {
            p.terminate()
        }
    }

    private func configure(process: Process, prompt: String, extraDirs: [String] = [], extraEnv: [String: String] = [:]) {
        let args = argsForPrompt(prompt, extraDirs: extraDirs)
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
        }
        process.environment = turnEnvironment(extraEnv: extraEnv)
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
    }

    /// extraDirs: 作業フォルダの外で読ませたい場所（添付画像の置き場）。対応する CLI にだけ渡す。
    func argsForPrompt(_ prompt: String, extraDirs: [String] = []) -> [String] {
        let mode = permissionOverride ?? effectiveMode()
        switch profile.flavor {
        case .cursor:
            var args = [
                "-p", prompt,
                "--output-format", "stream-json",
                // ワークスペース信頼のプロンプトで headless がブロックされるのを防ぐ。
                "--trust"
            ]
            // chatId は CLI 採番なので、解決済み（= 実 ID）のときだけ resume する。
            if let sid = resolvedSessionId, isUUID(sid) {
                args += ["--resume", sid]
            }
            if let model = effectiveModel() {
                args += ["--model", model]
            }
            switch mode {
            case "plan": args += ["--mode", "plan"]
            case "dangerous": args += ["--force"]
            default: break   // auto/edit = CLI 既定の承認挙動
            }
            return args
        case .grok:
            var args = [
                "-p", prompt,
                "--output-format", "streaming-json",
                "--no-auto-update"
            ]
            if let sid = resolvedSessionId {
                args += [grokSessionExists ? "-r" : "-s", sid]
            }
            if let model = effectiveModel() {
                args += ["-m", model]
            }
            if let effort = effectiveEffort() {
                args += ["--effort", effort]
            }
            // BuddyOS モード → grok --permission-mode（claude と同じ語彙）。
            switch mode {
            case "plan": args += ["--permission-mode", "plan"]
            case "edit": args += ["--permission-mode", "acceptEdits"]
            case "auto": args += ["--permission-mode", "default"]
            case "dangerous": args += ["--permission-mode", "bypassPermissions"]
            default: break
            }
            return args
        case .antigravity:
            var args = [
                "-p", prompt,
                "--output-format", "stream-json"
            ]
            // agy は headless でシェルの cwd を引き継がない。--add-dir を渡さないと
            // 「ワークスペースが設定されていない」となりファイル操作が一切できない。
            if let cwd {
                args += ["--add-dir", cwd]
            }
            for dir in extraDirs {
                args += ["--add-dir", dir]
            }
            // Bridge の MCP（stdio の中継）の設定を置いたフォルダ。合鍵は環境変数（configure）で渡す。
            if let dir = activeMcpDir {
                args += ["--add-dir", dir]
            }
            // conversation_id は CLI 採番なので、解決済み（= 実 ID）のときだけ再開する。
            if let sid = resolvedSessionId, isUUID(sid) {
                args += ["--conversation", sid]
            }
            if let model = effectiveModel() {
                args += ["--model", model]
            }
            if let effort = effectiveEffort(), profile.efforts.contains(effort) {
                args += ["--effort", effort]
            }
            switch mode {
            case "plan": args += ["--mode", "plan"]
            case "edit": args += ["--mode", "accept-edits"]
            case "dangerous": args += ["--dangerously-skip-permissions"]
            default: break   // auto = ~/.gemini/antigravity-cli/settings.json の allow ルールに従う
            }
            // 承認 hook を使うターンは、組み込みの確認（headless では聞けずに自動で拒否される）を外し、
            // コマンド実行の可否は hook（iPhone）が決める。
            if approvalHookActive, mode != "dangerous", mode != "plan" {
                args += ["--dangerously-skip-permissions"]
            }
            return args
        }
    }

    /// files: attachments と同じ並びで、画像を書き出したファイル（無ければ nil）。
    /// 画像は履歴の復元に使う placeholder の後ろに「(file: パス)」を付ける（WebSocketServer.enrichHistory が一緒に消す）。
    private func promptText(text: String, skills: [String] = [], attachments: [BridgeAttachment], files: [URL?] = []) -> String {
        var sections: [String] = []
        // 選んだ skill は claude / codex と同じ書き方で頭に付ける。
        if !skills.isEmpty {
            sections.append("/skill \(skills.joined(separator: ","))")
        }
        for (index, attachment) in attachments.enumerated() {
            switch attachment.kind {
            case .file:
                if let decoded = String(data: attachment.data, encoding: .utf8) {
                    sections.append("<file name=\"\(attachment.name)\">\n\(decoded)\n</file>")
                } else {
                    sections.append("[file \"\(attachment.name)\" attached: \(attachment.mime), \(attachment.data.count) bytes]")
                }
            case .image:
                var line = "[image \"\(attachment.name)\" attached: \(attachment.mime), \(attachment.data.count) bytes]"
                if index < files.count, let file = files[index] {
                    line += " (file: \(file.path) — open this file to see the image)"
                }
                sections.append(line)
            }
        }
        sections.append(text)
        return sections.joined(separator: "\n\n")
    }

    /// CLI ごとのストリーム 1 行から、サブエージェントの進行を取り出す。
    private func subagentPayloads(_ line: String, tracker: inout SubagentTracker) -> [String] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch profile.flavor {
        case .cursor:
            // Claude 互換の Task / Agent ツールと、Cursor 独自の tool_call 行
            // （{"type":"tool_call","subtype":"started|completed","call_id",
            //   "tool_call":{"<name>ToolCall":{"args":{...},"result":{...}}}}）の両方を見る。
            var out = tracker.ingestToolUseLine(object)
            if let p = tracker.ingestStreamLine(object) { out.append(p) }
            if string(object["type"]) == "tool_call", let id = string(object["call_id"]),
               let call = object["tool_call"] as? [String: Any], let (key, raw) = call.first {
                let inner = raw as? [String: Any]
                let name = key.hasSuffix("ToolCall") ? String(key.dropLast("ToolCall".count)) : key
                switch string(object["subtype"]) {
                case "started":
                    if let d = SubagentTracker.delegation(toolName: name, title: nil, input: inner?["args"]),
                       let p = tracker.begin(key: id, label: d.label, agentType: d.agentType) { out.append(p) }
                case "completed":
                    guard tracker.contains(id) else { break }
                    let result = inner?["result"] as? [String: Any]
                    let failed = result?["error"] != nil || result?["failure"] != nil
                    let success = result?["success"] as? [String: Any]
                    let text = string(success?["content"]) ?? string(success?["output"]) ?? string(success?["summary"])
                    if let p = tracker.finish(key: id, failed: failed, result: text) { out.append(p) }
                default:
                    break
                }
            }
            return out
        case .grok:
            // ACP の session/update（NDJSON 単体と JSON-RPC の封筒の両方）。
            let params = object["params"] as? [String: Any] ?? object
            let update = params["update"] as? [String: Any] ?? params
            return tracker.ingestAcpUpdate(update).map { [$0] } ?? []
        case .antigravity:
            return []
        }
    }

    /// CLI ごとのストリーム 1 行を (text, sessionId, model) に正規化する。
    private func parseLine(_ line: String, sawTextDelta: Bool) -> (text: String?, sessionId: String?, model: String?) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // JSON でない行（生エラー等）は、まだ本文が無ければそのまま見せる。
            return sawTextDelta ? (nil, nil, nil) : (line + "\n", nil, nil)
        }

        switch profile.flavor {
        case .grok:
            // Grok 1.x emits native ACP session updates. Accept both the
            // standalone NDJSON update and the JSON-RPC notification envelope.
            let params = object["params"] as? [String: Any] ?? object
            let update = params["update"] as? [String: Any] ?? params
            if string(update["sessionUpdate"]) == "agent_message_chunk",
               let content = update["content"] as? [String: Any],
               string(content["type"]) == "text" {
                return (string(content["text"]), string(params["sessionId"]), nil)
            }
            // {"type":"text","data":"..."} / {"type":"thought",...} / {"type":"end","sessionId":...}
            switch string(object["type"]) {
            case "text":
                return (string(object["data"]), nil, nil)
            case "end":
                return (nil, string(object["sessionId"]), nil)
            default:
                return (nil, nil, nil)
            }
        case .cursor:
            // Claude Code 互換形: type = system(init) / user / assistant / result。
            let sid = string(object["session_id"]) ?? string(object["sessionId"])
                ?? string(object["chatId"]) ?? string(object["chat_id"])
            // サブエージェント（Task 等）の行は parent_tool_use_id に親の tool_use id を持つ
            // （メインの行は null = NSNull なので as? String で判定する）。そのモデルを表示に混ぜない。
            let isSubagent = string(object["parent_tool_use_id"]) != nil
            let model = isSubagent
                ? nil
                : string(object["model"]) ?? string((object["message"] as? [String: Any])?["model"])
            switch string(object["type"]) {
            case "assistant":
                if let message = object["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    let text = content
                        .compactMap { block in string(block["type"]) == "text" ? string(block["text"]) : nil }
                        .joined()
                    if !text.isEmpty { return (text, sid, model) }
                }
                return (nil, sid, model)
            case "result":
                // assistant 行を一度も見ていないときだけ最終テキストを採用（二重出力防止）。
                if !sawTextDelta, let result = string(object["result"]) {
                    return (result, sid, model)
                }
                return (nil, sid, model)
            default:
                return (nil, sid, model)
            }
        case .antigravity:
            // {"event":"init"|"step_update"|"result", conversation_id:..., <event>:{...}}
            let sid = string(object["conversation_id"])
            switch string(object["event"]) {
            case "init":
                let info = object["init"] as? [String: Any]
                return (nil, sid, string(info?["model"]))
            case "step_update":
                let step = object["step_update"] as? [String: Any] ?? [:]
                let stepSid = sid ?? string(step["conversation_id"])
                // 本文は agent_response の text_delta で逐次届く。
                if string(step["step_type"]) == "agent_response",
                   let delta = string(step["text_delta"]), !delta.isEmpty {
                    return (delta, stepSid, nil)
                }
                return (nil, stepSid, nil)
            case "result":
                let result = object["result"] as? [String: Any] ?? [:]
                let resultSid = sid ?? string(result["conversation_id"])
                // text_delta を一度も見ていないときだけ最終本文を採用（二重出力防止）。
                if !sawTextDelta, let response = string(result["response"]) {
                    return (response, resultSid, nil)
                }
                return (nil, resultSid, nil)
            default:
                return (nil, sid, nil)
            }
        }
    }

    private func updateSessionIdIfNeeded(_ sid: String) async {
        guard !sid.isEmpty, sid != sessionId else { return }
        let old = sessionId
        resolvedSessionId = sid
        sessionId = sid
        await store.replaceSessionId(agentId: agentId, oldSessionId: old, newSessionId: sid, cwd: cwd)
    }

    private func emitSessionStartedIfNeeded() {
        guard !didEmitSessionStarted else { return }
        didEmitSessionStarted = true
        continuation.yield(.sessionStarted(agentId: agentId, sessionId: sessionId))
    }

    private func environment() -> [String: String] {
        HeadlessCliAdapter.processEnvironment(for: profile)
    }

    /// 1 ターンの CLI の環境。agy の stdio の MCP サーバ（中継）は agy の環境変数を引き継ぐので、
    /// 合鍵と番号はここで渡す（引数・ファイルに載せない）。
    func turnEnvironment(extraEnv: [String: String] = [:]) -> [String: String] {
        var env = environment().merging(extraEnv) { _, new in new }
        if let token = mcpToken, activeMcpDir != nil {
            env[McpStdioRelay.tokenEnvVar] = token
            env[McpStdioRelay.portEnvVar] = String(MainAgentWorkspace.currentPort)
        }
        return env
    }

    /// このターンで agy に読ませる MCP の設定のフォルダ。ターンごとに中身を確かめ直す（書き換えられていたら直す。
    /// 直せなければ渡さない）。合鍵が無いセッションは nil。
    private var activeMcpDir: String? {
        guard mcpToken != nil, let dir = mcpDir, let relay = McpStdioRelay.currentExecutable else { return nil }
        return MainAgentWorkspace.ensureAgyMcpConfig(executable: relay, dir: URL(fileURLWithPath: dir, isDirectory: true))
    }
}

extension HeadlessCliAdapter {
    /// CLI を起動するときの環境（PATH の補い・API キーの注入）。headless 実行と ACP の両方で使う。
    static func processEnvironment(for profile: HeadlessCliProfile) -> [String: String] {
        var env = ChildEnvironment.base()
        let additions = [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.grok/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (additions + [current]).joined(separator: ":")
        switch profile.flavor {
        case .cursor:
            // CLI ログイン（keychain/設定）が主経路。env / token ファイルがあれば注入する。
            if let (key, envKey) = CursorKey.resolve(), env[envKey] == nil {
                env[envKey] = key
            }
        case .grok:
            if let key = GrokAuth.resolveApiKey(), env["XAI_API_KEY"] == nil {
                env["XAI_API_KEY"] = key
            }
            // update チェックのノイズを止める（stdout は streaming-json 専用に保つ）。
            env["GROK_DISABLE_UPDATE_CHECK"] = "1"
        case .antigravity:
            // 認証は Antigravity IDE と共有の keychain。env 注入は不要。
            break
        }
        return env
    }
}

extension HeadlessCliSession {
    private func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }
}

/// HeadlessCliSession の stdout / stderr を readabilityHandler で吸い上げる
/// （ProcessRunner / AcpClient と同じ方式）。
/// - stdout は Data のまま溜めて改行 (0x0A) で行を切り出し、行ごとに UTF-8 デコードする。
///   chunk ごとにデコードすると、多バイト文字の途中で切れた chunk が nil になって丸ごと
///   失われ、行が壊れた JSON 断片として本文に出てしまうため。不正なバイトは U+FFFD に置換して捨てない。
/// - blocking な availableData ループは EOF まで cooperative スレッドを占有するうえ、CLI が
///   起動した子孫（MCP stdio サーバ、バックグラウンド実行したコマンド等）が書き込み端を
///   握ったままだと EOF が来ず、ターンが永久に終わらない。CLI 本体の終了後は exitGrace だけ
///   EOF を待ち、来なければ読み取りを打ち切る。
private final class PipeLineReader: @unchecked Sendable {
    /// CLI 本体の終了後に、子孫が握るパイプの EOF を待つ猶予。
    private static let exitGrace: TimeInterval = 2

    /// stdout の行（改行は含まない）。CLI 本体の終了後、stdout/stderr の EOF か猶予切れで終わる。
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let onOutput: () -> Void
    private let lock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrData = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var exited = false
    private var finished = false

    init(stdout: FileHandle, stderr: FileHandle, onOutput: @escaping () -> Void) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.lines = stream
        self.continuation = continuation
        stdoutHandle = stdout
        stderrHandle = stderr
        self.onOutput = onOutput
    }

    /// process.run() 成功後に呼ぶ。登録前に届いた分はパイプバッファに溜まり、初回に読める。
    func start() {
        stdoutHandle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else {
                h.readabilityHandler = nil
                self?.markEOF(stdout: true)
                return
            }
            self?.onOutput()
            self?.feedStdout(chunk)
        }
        stderrHandle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else {
                h.readabilityHandler = nil
                self?.markEOF(stdout: false)
                return
            }
            self?.onOutput()
            self?.appendStderr(chunk)
        }
    }

    /// process.terminationHandler から呼ぶ。
    func processDidExit() {
        lock.withLock { exited = true }
        finishIfDrained()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.exitGrace) { [weak self] in
            self?.finish()
        }
    }

    /// stderr 全体。chunk の切れ目で多バイト文字が欠けないよう、最後にまとめてデコードする。
    var stderrText: String {
        lock.withLock { String(decoding: stderrData, as: UTF8.self) }
    }

    private func feedStdout(_ chunk: Data) {
        // finish() の末尾行 flush と順序が入れ替わらないよう、yield もロック内で行う
        // （AsyncStream の yield は非ブロッキング）。
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            continuation.yield(String(decoding: stdoutBuffer[stdoutBuffer.startIndex..<nl], as: UTF8.self))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
        }
    }

    private func appendStderr(_ chunk: Data) {
        lock.withLock { stderrData.append(chunk) }
    }

    private func markEOF(stdout: Bool) {
        lock.withLock {
            if stdout { stdoutEOF = true } else { stderrEOF = true }
        }
        finishIfDrained()
    }

    private func finishIfDrained() {
        let ready = lock.withLock { exited && stdoutEOF && stderrEOF }
        if ready { finish() }
    }

    /// 改行で終わらない末尾行を 1 行として流し、lines を閉じる。猶予切れで呼ばれたときは
    /// ハンドラを外して読み取りを打ち切る。fd は Pipe の解放時に close される
    /// （実行中のハンドラは FileHandle を保持しているので、読み取り中に close されない）。
    private func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        if !stdoutBuffer.isEmpty {
            continuation.yield(String(decoding: stdoutBuffer, as: UTF8.self))
            stdoutBuffer.removeAll()
        }
        continuation.finish()
        let (outEOF, errEOF) = (stdoutEOF, stderrEOF)
        lock.unlock()
        if !outEOF { stdoutHandle.readabilityHandler = nil }
        if !errEOF { stderrHandle.readabilityHandler = nil }
    }
}

/// session/list の結果を少しの間だけ覚える（一覧を出すたびに CLI を起動しない）。
actor AcpListCache {
    private var entries: [String: (at: Date, list: [SessionSummary])] = [:]
    private let ttl: TimeInterval = 15

    func get(_ key: String) -> [SessionSummary]? {
        guard let e = entries[key], Date().timeIntervalSince(e.at) < ttl else { return nil }
        return e.list
    }

    func put(_ key: String, _ list: [SessionSummary]) {
        entries[key] = (Date(), list)
    }
}
