import Foundation

final class OpenCodeAdapter: BridgeCronHosted {
    let id = "opencode"
    let displayName = "OpenCode"
    // チャットは opencode serve(HTTP) の1プロセス複数セッション経路(高速・並列)。
    // models/mode/commands は serve セッションの現在値 + 従来の catalog cache(1ショット ACP)。
    // history/list は serve の HTTP API。mcp/skills は ~/.config/opencode/ のファイル読み込み。
    let capabilities = AgentCapabilities(
        chat: true,
        history: true,
        projects: true,
        commands: true,
        models: true,
        skills: true,
        mcp: true,
        attachments: true,
        actions: false,
        // ACP configOptions の mode（option-value をそのまま codexMode で送る）。
        modes: ["build", "plan"],
        // buddy-opencode が Bridge の serve に attach するので、ターミナルとチャットが同じ会話を共有する。
        terminal: true
    )

    init() {
        Self.ensureCacheDir()
    }

    // MARK: - サーバ参照

    private var serve: OpenCodeServeClient { OpenCodeServeClient.shared }

    // MARK: - モデル一覧キャッシュ(従来どおり 1ショット ACP で暖め、プロセス内キャッシュ)
    // チャット本体は serve 経路だが、モデル一覧はプロバイダ設定由来でほぼ不変のため
    // 起動直後の1回の ACP probe で取得してキャッシュする(変更なければ再取得不要)。
    private struct CatalogCache {
        var providers: [ProviderCatalog]
        var currentModel: String?
        var currentMode: String?
    }
    private var catalogCache: CatalogCache?
    private let catalogLock = NSLock()

    private func readCatalogCache() -> CatalogCache? {
        catalogLock.lock(); defer { catalogLock.unlock() }
        return catalogCache
    }
    private func writeCatalogCache(_ c: CatalogCache) {
        catalogLock.lock(); defer { catalogLock.unlock() }
        catalogCache = c
    }

    private func cacheFrom(_ session: AcpSession) {
        let catalog = session.modelCatalog()
        guard !catalog.isEmpty else { return }
        let models = catalog.map { ModelCatalogItem(id: $0.value, label: $0.name, subtitle: nil) }
        writeCatalogCache(CatalogCache(
            providers: [ProviderCatalog(id: "opencode", label: "OpenCode", models: models)],
            currentModel: session.currentModel(),
            currentMode: session.currentMode()
        ))
    }

    /// 起動直後に1度だけ ACP を1ショット起動しモデル一覧をキャッシュする(従来ロジック)。
    /// チャットは別経路(serve)なのでこれは「モデルピッカー用」の暖機のみ。
    func warmModelCatalog() async {
        if let c = readCatalogCache(), !c.providers.isEmpty { return }
        let exe = Self.locateExecutable()
        guard FileManager.default.isExecutableFile(atPath: exe) else { return }
        let session = await openSessionViaAcp(sessionId: nil, cwd: nil)
        guard let acp = session as? AcpSession else { return }
        do {
            try await acp.ensureStarted()
            cacheFrom(acp)
        } catch {
            // 握りつぶす(最初のピッカー開閉時に lazy に再取得される)。
        }
        await acp.close()
    }

    /// serve サーバを起動時プリウォームする。チャット初回のコールドブートを隠す。
    /// BridgeServer.start() のバックグラウンド Task から呼ばれる。失敗は致命でない
    /// (初回チャット時に lazy に ensureServer が走る)。
    func prewarmServer() async {
        _ = await serve.ensureServer()
    }

    // MARK: - openSession (チャット本体 = serve 経路)

    /// 定期実行（BridgeCronHosted）からの無人実行。モードは build / plan しか無いので plan だけを効かせ、
    /// 承認要求は Full Access なら許可・それ以外は拒否で自動回答する（答える人がいないため）。
    func openSession(sessionId: String?, cwd: String?, options: SessionOptions?) async -> AgentSession {
        let session = await openSession(sessionId: sessionId, cwd: cwd, cronOptions: options?.unattended == true ? options : nil)
        guard let options, options.unattended else { return session }
        if let serve = session as? OpenCodeServeSession {
            serve.unattendedReply = options.permissionMode == "dangerous" ? "once" : "reject"
        }
        if options.permissionMode == "plan", let overridable = session as? SessionOverridable {
            overridable.applyOverrides(SessionOverrides(mode: "plan"))
        }
        return session
    }

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        await openSession(sessionId: sessionId, cwd: cwd, cronOptions: nil)
    }

    /// `cronOptions` は無人実行（cron）のオプション。ACP 経路へ落ちたときも、承認要求をその場で断らせる
    /// （渡さないと ACP は承認を iPhone に出して待ち、定期実行が 30 分止まる）。
    private func openSession(sessionId: String?, cwd: String?, cronOptions: SessionOptions?) async -> AgentSession {
        // serve サーバを確保(起動済みなら即復帰)。失敗時は従来 ACP 経路へフォールバック。
        if let _ = await serve.ensureServer() {
            do {
                let resolved = try await resolveOrCreateSession(requested: sessionId, cwd: cwd)
                let session = OpenCodeServeSession(sessionId: resolved.id, client: serve, directory: resolved.directory)
                session.emitStarted()
                return session
            } catch {
                FileHandle.standardError.write(Data("[opencode.serve] openSession failed, fallback to ACP: \(error.localizedDescription)\n".utf8))
            }
        }
        return await openSessionViaAcp(sessionId: sessionId, cwd: cwd, cronOptions: cronOptions)
    }

    /// serve は Bridge の cwd(launchd 下では "/")で起動済みなので、チャットの作業ディレクトリは
    /// リクエスト毎の directory で opencode に渡す(渡さないと "/" をプロジェクトルートとして動く)。
    /// resume(sessionId 非 nil)ならそのまま sid を使い、directory はセッション作成時のものを優先
    /// (iOS から cwd が来ない/違う場合でも元のプロジェクトで続ける)。取れなければ cwd。
    /// 新規(nil)なら cwd を directory にして POST /session で採番。
    private func resolveOrCreateSession(requested: String?, cwd: String?) async throws -> (id: String, directory: String) {
        let directory = Self.normalizedCwd(cwd)
        if let sid = requested, !sid.isEmpty {
            if let stored = (try? await serve.getSession(sid))?["directory"] as? String, !stored.isEmpty {
                return (sid, stored)
            }
            return (sid, directory)
        }
        return (try await serve.createSession(directory: directory), directory)
    }

    /// 従来の stdio ACP 経路(fallback / catalog 暖機用)。チャット通常時は使われない。
    private func openSessionViaAcp(sessionId: String?, cwd: String?, cronOptions: SessionOptions? = nil) async -> AgentSession {
        Self.ensureCacheDir()
        var tuning = AcpSessionTuning()
        if let cronOptions {
            tuning.unattended = true
            tuning.permissionMode = cronOptions.permissionMode
        }
        return AcpSession(
            agentId: "opencode",
            initialSessionId: sessionId,
            executable: Self.locateExecutable(),
            args: ["acp"],
            cwd: cwd,
            env: Self.cacheEnvironment,
            tuning: tuning
        )
    }

    // MARK: - History / Sessions (serve HTTP)

    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] {
        guard (await serve.ensureServer()) != nil else { return [] }
        // cwd 指定時はその directory のセッションだけを問い合わせる。nil/空は全体一覧
        // (ClaudeCodeAdapter と同じ扱い)。
        let directory: String? = Self.nonEmpty(cwd) == nil ? nil : Self.normalizedCwd(cwd)
        guard let list = try? await serve.listSessions(directory: directory) else { return [] }
        let terminalIds = OpenCodeTerminals.terminalSessionIds(in: list)
        // opencode の題名は、AI 要約が付くまで "New session - <日時>" の仮名のまま残る。
        // 一度も使われていない空のセッションは一覧から外し、使われたのに仮名のままのものは最初の発言を名前にする。
        var rows: [(dict: [String: Any], title: String)] = []
        for dict in list {
            let raw = (dict["title"] as? String) ?? (dict["slug"] as? String) ?? "OpenCode session"
            if Self.isPlaceholderTitle(raw) {
                let time = dict["time"] as? [String: Any]
                let created = (time?["created"] as? NSNumber)?.doubleValue ?? 0
                let updated = (time?["updated"] as? NSNumber)?.doubleValue ?? 0
                if updated <= created { continue }   // 触られていない空のセッション
            }
            rows.append((dict, raw))
            if rows.count >= max(1, limit) { break }
        }
        var titles: [String] = []
        for row in rows {
            guard Self.isPlaceholderTitle(row.title), let id = row.dict["id"] as? String else { titles.append(row.title); continue }
            titles.append(await firstPromptTitle(sessionId: id) ?? row.title)
        }
        return zip(rows, titles).map { row, title in
            let dict = row.dict
            let id = (dict["id"] as? String) ?? ""
            let dir = (dict["directory"] as? String) ?? directory
            let last = Self.lastActiveISO(dict["time"] as? [String: Any])
            return SessionSummary(sessionId: id, title: title, lastActive: last, messageCount: nil, cwd: dir,
                                  terminal: terminalIds.contains(id))
        }
    }

    /// "New session - 2026-10-02T17:23:28.276Z" / "Child session - …" の仮名か。
    static func isPlaceholderTitle(_ t: String) -> Bool {
        t.range(of: #"^(New|Child) session - \d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil
    }

    private var firstPromptCache: [String: String] = [:]
    private let firstPromptLock = NSLock()

    /// セッションの最初のユーザー発言（80 文字まで）。最初の発言は変わらないので結果を覚える。
    private func firstPromptTitle(sessionId: String) async -> String? {
        if let hit = firstPromptLock.withLock({ firstPromptCache[sessionId] }) { return hit }
        guard let msgs = try? await serve.history(sessionId) else { return nil }
        for msg in msgs {
            guard ((msg["info"] as? [String: Any])?["role"] as? String) == "user" else { continue }
            let text = ((msg["parts"] as? [[String: Any]]) ?? [])
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let title = text.count > 80 ? String(text.prefix(77)) + "..." : text
            firstPromptLock.withLock { firstPromptCache[sessionId] = title }
            return title
        }
        return nil
    }

    func loadHistory(sessionId: String) async -> [HistoryMessage] {
        guard (await serve.ensureServer()) != nil else { return [] }
        guard let msgs = try? await serve.history(sessionId) else { return [] }
        return msgs.compactMap { msg -> HistoryMessage? in
            let info = (msg["info"] as? [String: Any]) ?? [:]
            let role = (info["role"] as? String) ?? "assistant"
            let mid = (info["id"] as? String) ?? UUID().uuidString
            let parts = (msg["parts"] as? [[String: Any]]) ?? []
            // text 系パートを結合。tool/reasoning/step-* は履歴 preview から外す。
            let texts = parts.compactMap { p -> String? in
                guard (p["type"] as? String) == "text" else { return nil }
                return (p["text"] as? String) ?? ""
            }.filter { !$0.isEmpty }
            guard let content = texts.joined(separator: "\n").nilIfEmpty else { return nil }
            return HistoryMessage(role: role == "user" ? "user" : "assistant",
                                  content: content, messageId: mid)
        }
    }

    // MARK: - Models / current info

    func currentInfo(session: AgentSession?) async -> AgentInfo? {
        await ensureVariants()
        // serve セッションの現在値を最優先。
        if let s = session as? OpenCodeServeSession {
            let snap = s.infoSnapshot()
            if let sel = Self.selectedModel() {
                return withEffort(AgentInfo(model: sel.model, provider: sel.provider, reasoningEffort: nil, codexMode: snap.mode))
            }
            if snap.model != nil {
                return withEffort(AgentInfo(model: snap.model, provider: snap.provider ?? "opencode",
                                            reasoningEffort: nil, codexMode: snap.mode))
            }
        }
        // 未確定なら catalog cache の暖機時既定値。
        if let sel = Self.selectedModel() { return withEffort(AgentInfo(model: sel.model, provider: sel.provider, reasoningEffort: nil, codexMode: nil)) }
        let cached = readCatalogCache()
        return AgentInfo(model: cached?.currentModel, provider: "opencode",
                         reasoningEffort: nil, codexMode: cached?.currentMode)
    }

    func listAvailableModels(session: AgentSession?) async -> [ProviderCatalog] {
        // serve の接続済みプロバイダ（provider ごとに分けて、プロバイダ名とモデルを出す）。
        if let live = await serveCatalog(), !live.isEmpty { return live }
        // catalog cache があれば即返す(コールド ACP probe ~13s を回避)。
        if let cached = readCatalogCache(), !cached.providers.isEmpty { return cached.providers }
        // 無ければ1ショット ACP で暖めてキャッシュ。
        await warmModelCatalog()
        return readCatalogCache()?.providers ?? []
    }

    /// serve の `/config/providers` から、ピッカー用の一覧を作る。取れなければ nil（従来の ACP の一覧に戻る）。
    private func serveCatalog() async -> [ProviderCatalog]? {
        guard (await serve.ensureServer()) != nil, let res = try? await serve.providers() else { return nil }
        Self.rememberVariants(providers: res.providers)
        return Self.buildCatalog(providers: res.providers)
    }

    // MARK: - Effort（opencode の variant）
    // opencode はモデルごとに思考の強さの変種（variant: low / high / max …）を持つ。これを BuddyOS の Effort として出す。
    // 既定は opencode の設定に置き場が無いので ~/.buddyos/opencode.effort に持つ（cursor / grok と同じ流儀）。

    private static let variantsLock = NSLock()
    nonisolated(unsafe) private static var variantsByModel: [String: [String]] = [:]
    private static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func rememberVariants(providers: [[String: Any]]) {
        var map: [String: [String]] = [:]
        for p in providers {
            guard let pid = p["id"] as? String, let models = p["models"] as? [String: Any] else { continue }
            for (key, raw) in models {
                guard let m = raw as? [String: Any], let variants = m["variants"] as? [String: Any], !variants.isEmpty else { continue }
                let mid = (m["id"] as? String) ?? key
                map["\(pid)/\(mid)"] = variants.keys.sorted {
                    let a = effortOrder.firstIndex(of: $0) ?? Int.max, b = effortOrder.firstIndex(of: $1) ?? Int.max
                    return a != b ? a < b : $0 < $1
                }
            }
        }
        variantsLock.withLock { variantsByModel = map }
    }

    static func variants(provider: String, model: String) -> [String] {
        variantsLock.withLock { variantsByModel["\(provider)/\(model)"] ?? [] }
    }

    private static var effortPath: String { NSHomeDirectory() + "/.buddyos/opencode.effort" }

    static func defaultVariant() -> String? {
        let v = (try? String(contentsOfFile: effortPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    static func setDefaultVariant(_ value: String?) {
        if let value, !value.isEmpty {
            try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.buddyos", withIntermediateDirectories: true)
            try? value.write(toFile: effortPath, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: effortPath)
        }
    }

    /// 一覧をまだ読んでいなければ読む（variant の対応を知るため）。
    private func ensureVariants() async {
        let empty = Self.variantsLock.withLock { Self.variantsByModel.isEmpty }
        guard empty, (await serve.ensureServer()) != nil, let res = try? await serve.providers() else { return }
        Self.rememberVariants(providers: res.providers)
    }

    /// AgentInfo に effort（このモデルの variant と既定）を足す。
    private func withEffort(_ info: AgentInfo) -> AgentInfo {
        guard let model = info.model, let provider = info.provider else { return info }
        let variants = Self.variants(provider: provider, model: model)
        guard !variants.isEmpty else { return info }
        let current = Self.defaultVariant().flatMap { variants.contains($0) ? $0 : nil }
        return AgentInfo(model: info.model, provider: info.provider, supportedReasoningEfforts: variants,
                         reasoningEffort: current, codexMode: info.codexMode,
                         approvalPolicy: info.approvalPolicy, sandboxMode: info.sandboxMode)
    }

    static func buildCatalog(providers: [[String: Any]]) -> [ProviderCatalog] {
        providers.compactMap { p -> ProviderCatalog? in
            guard let pid = p["id"] as? String, let models = p["models"] as? [String: Any], !models.isEmpty else { return nil }
            let items = models.compactMap { key, value -> ModelCatalogItem? in
                let m = value as? [String: Any]
                return ModelCatalogItem(id: (m?["id"] as? String) ?? key, label: (m?["name"] as? String) ?? key, subtitle: nil)
            }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            return ProviderCatalog(id: pid, label: (p["name"] as? String) ?? pid, models: items)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// opencode 自身の設定。ターミナルの opencode と既定を共有する。
    static let settingsPath = ".config/opencode/opencode.json"

    /// 既定のモデル（opencode.json の "model" = "providerID/modelID"）。
    /// serve は起動時に設定を読むので、起動後に変わった既定も効くよう送信ごとに明示する。
    static func selectedModel() -> (provider: String, model: String)? {
        guard let raw = (JsonSettingsFile.read(settingsPath)?["model"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let slash = raw.firstIndex(of: "/") else { return nil }
        let provider = String(raw[..<slash]), model = String(raw[raw.index(after: slash)...])
        return provider.isEmpty || model.isEmpty ? nil : (provider, model)
    }

    // MARK: - Set model / mode / effort

    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?, session: AgentSession?) async throws {
        // effort（variant）の既定は BuddyOS 側に持つ。mode の既定は持たない（チャットごとに選ぶ）。
        if let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines), !effort.isEmpty {
            Self.setDefaultVariant(effort)
        }
        // モデルが空なら書くものが無い（"provider/" を書かない）。
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        // 既定のモデルを opencode.json に保存し、以降のメッセージに model として付ける（OpenCodeServeClient.sendMessage）。
        // provider はピッカーのプロバイダ id。無い（古いアプリ）ときは、現在のプロバイダを使う。
        let providerId = Self.nonEmpty(provider) ?? (session as? OpenCodeServeSession)?.infoSnapshot().provider
        guard let providerId, providerId != "opencode" else {
            throw NSError(domain: "OpenCodeAdapter", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "プロバイダを特定できません。モデル一覧を開き直してください"
            ])
        }
        try JsonSettingsFile.update(Self.settingsPath) { $0["model"] = "\(providerId)/\(model)" }
        (session as? OpenCodeServeSession)?.noteSelectedModel(provider: providerId, model: model)
    }

    // MARK: - Commands (slash palette)

    /// serve 経路では live ACP セッションがないためコマンド一覧は取れない。skills は
    /// ディレクトリから読めるのでそちらは Skills タブで出す。palette は空で返す。
    /// 将来 serve の command API(session/{id}/command) を叩いて充実させる余地あり。
    func listCommands(session: AgentSession?) async -> [CommandInfo] {
        return []
    }

    // MARK: - Executable / cache

    /// opencode は ~/.cache(未マウント SSD symlink) を避けるため XDG_CACHE_HOME を固定する。
    /// 置き場所は自分専用のフォルダ(~/Library/Caches/BuddyOS/opencode-cache、0700)。
    /// 全ユーザー共有の /tmp に置くと、別のユーザーが opencode/bin(rg 等)・models.json・node_modules を
    /// 仕込んで、こちらの権限で実行させられる。所有者やシンボリックリンクで確かめられないときは、
    /// ユーザーごとの一時フォルダ(NSTemporaryDirectory)へ逃がす。OpenCodeServeClient / AcpSession と共有。
    static let cacheHome: String = {
        let preferred = NSHomeDirectory() + "/Library/Caches/BuddyOS/opencode-cache"
        if PrivateDirectory.ensure((preferred as NSString).deletingLastPathComponent),
           PrivateDirectory.ensure(preferred) {
            return preferred
        }
        let fallback = (NSTemporaryDirectory() as NSString).appendingPathComponent("buddyos-opencode-cache")
        if !PrivateDirectory.ensure(fallback) {
            FileHandle.standardError.write(Data("[opencode] cache dir is not private: \(fallback)\n".utf8))
        }
        return fallback
    }()

    /// opencode を起動するときに必ず渡す環境変数(XDG_CACHE_HOME)。bin ディレクトリも用意する。
    static var cacheEnvironment: [String: String] {
        ensureCacheDir()
        return ["XDG_CACHE_HOME": cacheHome]
    }

    /// その bin ディレクトリを事前に作る(cacheHome は自分専用なので、下は普通に作ってよい)。
    static func ensureCacheDir() {
        guard PrivateDirectory.isPrivate(cacheHome) || PrivateDirectory.ensure(cacheHome) else { return }
        try? FileManager.default.createDirectory(
            atPath: cacheHome + "/opencode/bin",
            withIntermediateDirectories: true
        )
    }

    static func locateExecutable() -> String {
        if let override = ProcessInfo.processInfo.environment["OPENCODE_BIN"], !override.isEmpty {
            return override
        }
        let candidates = [
            "\(NSHomeDirectory())/.npm-global/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
            "\(NSHomeDirectory())/.local/bin/opencode"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "opencode"
    }

    // MARK: - helpers

    /// cwd を AcpSession と同じ規則で正規化する(nil/空 → $HOME、~ 展開、standardizingPath)。
    private static func normalizedCwd(_ cwd: String?) -> String {
        let home = NSHomeDirectory()
        guard let trimmed = nonEmpty(cwd) else { return home }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return (trimmed as NSString).standardizingPath
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// time 辞書(created/updated は ms epoch)を RFC3339 文字列へ。
    private static func lastActiveISO(_ time: [String: Any]?) -> String {
        guard let time, let ms = (time["updated"] as? Double) ?? (time["updated"] as? Int).map(Double.init) else {
            return ""
        }
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
