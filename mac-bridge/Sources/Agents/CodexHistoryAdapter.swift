import Foundation

final class CodexHistoryAdapter: BridgeCronHosted {
    let id = "codex"
    let displayName = "Codex"
    let capabilities = AgentCapabilities(
        commands: true,
        models: true,
        skills: true,
        mcp: true,
        actions: true,
        // 生成中の送信は turn/steer で実行中のターンへ足す（app-server の経路だけ。exec は 1 ターン 1 プロセス）。
        injectMidTurn: ProcessInfo.processInfo.environment["BUDDYOS_CODEX_TRANSPORT"] != "exec",
        // 実際の対応値はモデルごとに違い、agent_info の supportedReasoningEfforts が優先される。
        efforts: ["low", "medium", "high", "xhigh"],
        // ask = workspace-write ＋ on-request（毎回尋ねる）、auto = workspace-write ＋ never（作業フォルダの中は尋ねない）。
        modes: ["plan", "ask", "auto", "dangerous"],
        terminal: true,
        // ~/.buddyos/main で開くと mainagent になる（MainAgentWorkspace）。
        orchestrate: true
    )

    private let history = CodexHistoryStore()
    private let config = CodexConfigStore()
    private let executable = CodexLiveSession.locateExecutable()

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        await openSession(sessionId: sessionId, cwd: cwd, options: nil)
    }

    func openSession(sessionId: String?, cwd: String?, options: SessionOptions?) async -> AgentSession {
        // 無人実行 (cron) のモード上書きは exec transport 固定で `-c` 上書きを併用する。
        // app-server transport は per-run の sandbox/approval 上書きを持たないため。
        // 作業フォルダは `-C` でも明示する（無いと Bridge の作業フォルダ = launchd なら `/` で
        // workspace-write になり、書き込める範囲が広がる）。空欄はホームフォルダ。
        if let mode = options?.permissionMode {
            let runCwd = Self.unattendedCwd(cwd)
            return CodexLiveSession(
                agentId: id,
                initialSessionId: sessionId,
                cwd: runCwd,
                executable: executable,
                codexMode: mode,
                configOverrides: Self.unattendedConfigOverrides(forMode: mode) + ["-C", runCwd],
                explicitMode: true
            )
        }
        let approvalPolicy = config.currentApprovalPolicy()
        let sandboxMode = config.currentSandboxMode()
        // 無人実行（cron）でモード指定が無い（グローバル設定に従う）場合も exec transport にして、
        // 承認だけ never に固定する（sandbox は config.toml のグローバル値のまま）。app-server の
        // approval_policy=on-request のままだと承認待ちで timeout まで止まり、共有 app-server 上では
        // cron のターンがターミナル（buddy-codex）にも見えてしまう。
        // 定期チェック（heartbeat）は無人でも mainagent の道具が要るので、下のふつうの経路（合鍵を渡す）で開く。
        // mainagent のフォルダの Codex は読むだけ・承認は Bridge が出すので、承認待ちで止まらない。
        if options?.unattended == true, options?.heartbeat != true {
            let runCwd = Self.unattendedCwd(cwd)
            return CodexLiveSession(
                agentId: id,
                initialSessionId: sessionId,
                cwd: runCwd,
                executable: executable,
                codexMode: config.currentCodexMode(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode),
                configOverrides: ["-c", "approval_policy=\"never\"", "-C", runCwd]
            )
        }
        // ほかのセッションを操作する MCP の合鍵を渡す。mainagent のフォルダなら読むだけにする
        // （ふつうのセッションは MCP だけ）。
        let grant = await Orchestrator.shared.sessionGrant(agentId: id, sessionId: sessionId,
                                                           cwd: Self.normalizedCwd(cwd), unattended: false)
        let mainToken = grant?.token
        let mainRestricted = grant?.isMain ?? true
        if ProcessInfo.processInfo.environment["BUDDYOS_CODEX_TRANSPORT"] == "exec" {
            let session = CodexLiveSession(
                agentId: id,
                initialSessionId: sessionId,
                cwd: Self.normalizedCwd(cwd),
                executable: executable,
                codexMode: config.currentCodexMode(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode),
                configOverrides: mainToken == nil ? []
                    : mainRestricted ? MainAgentWorkspace.codexExecArgs(port: MainAgentWorkspace.currentPort)
                    : MainAgentWorkspace.codexExecDelegateArgs(port: MainAgentWorkspace.currentPort),
                extraEnvironment: mainToken.map { [MainAgentWorkspace.tokenEnvVar: $0] } ?? [:]
            )
            if let mainToken { await Orchestrator.shared.bind(token: mainToken, session: session) }
            return session
        }
        // ターミナル（buddy-codex）と同じ app-server に乗る。起動できなければ従来の stdio。
        let shared = await CodexSharedAppServer.shared.ensureRunning(
            executable: executable, environment: CodexAppServerSession.spawnEnvironment())
        let session = CodexAppServerSession(
            agentId: id,
            initialSessionId: sessionId,
            cwd: Self.normalizedCwd(cwd),
            executable: executable,
            shared: shared,
            mainToken: mainToken,
            mainRestricted: mainRestricted
        )
        if let mainToken { await Orchestrator.shared.bind(token: mainToken, session: session) }
        return session
    }

    /// 無人実行の作業フォルダ。空欄はホームフォルダ（Bridge の作業フォルダには倒さない）。
    static func unattendedCwd(_ cwd: String?) -> String {
        normalizedCwd(cwd) ?? NSHomeDirectory()
    }

    /// BuddyOS モードラベル → 無人実行用の `codex exec -c` 上書き。
    /// 無人なので approval は常に never (対話 approval は答えられず stall するため)。
    static func unattendedConfigOverrides(forMode mode: String) -> [String] {
        let sandbox: String
        switch mode {
        case "plan": sandbox = "read-only"
        case "dangerous": sandbox = "danger-full-access"
        default: sandbox = "workspace-write"   // "edit" / "ask" / "auto"（無人なので ask も尋ねない）
        }
        return [
            "-c", "sandbox_mode=\"\(sandbox)\"",
            "-c", "approval_policy=\"never\""
        ]
    }


    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] {
        var merged = history.listSessions(limit: limit, cwd: cwd)
        // ターミナル（buddy-codex）で開かれている thread は印を付けて先頭に固定する。
        // 開いた直後でまだ履歴に無い thread は、台帳の情報から行を作って足す。
        let normalized = Self.normalizedCwd(cwd)
        let live = await CodexTerminalRegistry.shared.liveEntries()
            .filter { normalized == nil || Self.normalizedCwd($0.cwd) == normalized }
        guard !live.isEmpty else { return merged }
        let liveIds = Set(live.map(\.threadId))
        var seen = Set(merged.map(\.sessionId))
        for i in merged.indices where liveIds.contains(merged[i].sessionId) {
            merged[i].terminal = true
        }
        for entry in live where seen.insert(entry.threadId).inserted {
            merged.append(SessionSummary(
                sessionId: entry.threadId,
                title: "ターミナル",
                lastActive: ISO8601DateFormatter().string(from: entry.openedAt),
                messageCount: nil,
                cwd: entry.cwd,
                terminal: true
            ))
        }
        let sorted = merged.sorted {
            if $0.terminal != $1.terminal { return $0.terminal }
            return $0.lastActive > $1.lastActive
        }
        return Array(sorted.prefix(max(1, limit)))
    }

    func loadHistory(sessionId: String) async -> [HistoryMessage] {
        history.loadHistory(sessionId: sessionId)
    }

    func listCommands() async -> [CommandInfo] {
        [
            .init(id: "plan", kind: "prompt", title: "plan", subtitle: "Plan first, show options, and wait"),
            .init(id: "options", kind: "prompt", title: "options", subtitle: "Present 2-3 choices with a recommendation"),
            .init(id: "resume", kind: "codex", title: "resume", subtitle: "Resume a Codex thread"),
            .init(id: "fork", kind: "codex", title: "fork", subtitle: "Fork a previous Codex thread"),
            .init(id: "review", kind: "codex", title: "review", subtitle: "Run a Codex code review"),
            .init(id: "model", kind: "codex", title: "model", subtitle: "Change or inspect the active model"),
            .init(id: "help", kind: "codex", title: "help", subtitle: "Show Codex help")
        ]
    }

    func currentInfo() async -> AgentInfo? {
        let approvalPolicy = config.currentApprovalPolicy()
        let sandboxMode = config.currentSandboxMode()
        return AgentInfo(
            model: config.currentModel(),
            provider: "openai",
            supportedReasoningEfforts: config.supportedReasoningEfforts(),
            reasoningEffort: config.currentReasoningEffort(),
            codexMode: config.currentCodexMode(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode),
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
    }

    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?) async throws {
        // 書き込む前に全部検証する。model を書いた後に effort で throw すると、
        // 安全に関わる mode だけ書かれずに残る（同梱送信での部分適用）。
        // effort は新しい model 基準の supportedReasoningEfforts で判定する。
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = try reasoningEffort.map {
            try config.validatedReasoningEffort($0, model: trimmedModel.isEmpty ? nil : trimmedModel)
        }
        let modeValues = try codexMode.map { try config.codexModeValues($0) }
        // 安全に関わる mode を最初に適用する。
        if let modeValues {
            try config.applyCodexMode(modeValues)
        }
        if !trimmedModel.isEmpty {
            try config.setModel(trimmedModel)
        }
        if let effort {
            try config.writeReasoningEffort(effort)
        }
    }

    func listAvailableModels() async -> [ProviderCatalog] {
        if let catalog = config.loadBuddyModelCatalog(), !catalog.isEmpty {
            return catalog
        }
        if let catalog = await CodexModelCatalogLoader.load(executable: executable, currentModel: config.currentModel()) {
            return catalog
        }
        let ids = config.defaultModelIds(recent: [])
        return [
            ProviderCatalog(
                id: "openai",
                label: "OpenAI",
                models: ids.map { ModelCatalogItem(id: $0, label: $0, subtitle: nil) }
            )
        ]
    }

    private static func normalizedCwd(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return (trimmed as NSString).standardizingPath
    }
}
