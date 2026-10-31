import Foundation

/// `<agent> acp` を通じて 1 会話を扱う Session 実装。
///
/// Hermes / OpenClaw の両方で使う ACP セッション層。`agentId` / `executable` /
/// `args` / `env` を constructor で受け取り、event 発火時の agentId を切り替える。
///
/// - 初回 send で acp プロセスを spawn → initialize → session/new
/// - 以降の send は同じセッション ID で session/prompt
/// - session/update 通知を SessionEvent に翻訳して continuation に流す
///
/// resume (initialSessionId が非 nil) は session/load 経由で行う。replay 期間の
/// notification は acceptingUpdates フラグでドロップする。
///
/// agent ごとの違い（モードの効かせ方・画像の渡し方など）は AcpSessionTuning で受け取る。
/// 既定値は hermes / openclaw の従来の挙動。
final class AcpSession: AgentSession, SessionOverridable, @unchecked Sendable {
    let agentId: String
    private(set) var sessionId: String
    let events: AsyncThrowingStream<SessionEvent, Error>

    private let executable: String
    private let args: [String]
    private let env: [String: String]
    /// session/load で再開する sid。init 時は resume 指定の sid（新規なら nil）。ACP プロセスが
    /// 落ちて張り直すときは確定済み sid に差し替え、新規チャットでも session/new ではなく
    /// session/load で同じ会話に戻す。lock で保護。
    private var resumeSessionId: String?
    private let cwd: String
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation

    private var client: AcpClient?
    /// bootstrap 中（client 確定前）の AcpClient。close() がこれも kill できるよう保持する。
    private var startingClient: AcpClient?
    private var acpSessionId: String?
    private var didStart: Bool = false
    /// close() 済み。以後 bootstrap を起こさず、session/prompt も送らない。
    private var closed: Bool = false
    private var bootstrapTask: Task<Void, Error>?
    private var didNotifySessionStarted: Bool = false

    // prompt state（lock で保護）。done を「有効な session/prompt が全部戻った時」に 1 回だけ出す。
    // interrupt 済みの prompt（id <= cancelledThrough）の遅れた戻りで後続ターンを閉じないために使う。
    private var promptSeq: Int = 0
    private var inFlightPrompts: Set<Int> = []
    private var cancelledThrough: Int = 0
    private var doneOwed: Bool = false
    /// interrupt の猶予切れで done を補った後や、cancel 済み prompt の戻りを待つ間、遅れて届く旧ターンの更新を捨てる。
    private var discardingStaleUpdates: Bool = false
    /// interrupt 後、cancelled 応答が返らない agent でも待機を解くために done を補うまでの猶予。
    /// 補った done で予約が dispatch されても、session/prompt は waitForCancelledPrompts が旧ターンの戻りまで待たせる。
    private static let interruptDoneGraceNanos: UInt64 = 5_000_000_000
    /// 実行中の prompt を最後に cancel した時刻。cancel 済み prompt の戻りを次の送信が待つ上限の起点。
    private var cancelledAt: Date?
    /// cancel 済みの session/prompt が戻るまで次の session/prompt を送らずに待つ上限（cancelledAt 起点）。
    private static let cancelledPromptWaitLimit: TimeInterval = 30

    // streaming state
    private var currentMessageId: String?
    private var hadToolSinceLastMessage: Bool = false
    private var acceptingUpdates: Bool = false
    private var toolStartTimes: [String: Date] = [:]
    private var toolNames: [String: String] = [:]
    /// 終了を流し済みのツール。grok は tool_call（completed）と tool_call_update（completed）の両方で終わりを知らせるので、
    /// 2 回目は流さない（tool pill の終了が二重になる）。ターンの始めに空にする。lock で保護する。
    private var endedToolIds: Set<String> = []
    /// ターミナル（共有している別の画面）が始めたターンの途中か。lock で保護する。
    private var remoteTurnActive = false
    /// 流し済みのターミナルの発言（prompt id）。同じ発言の通知が何度来ても 1 回だけ流す。lock で保護する。
    private var seenRemotePromptIds: Set<String> = []
    /// サブエージェントへの委任ツール（キーは toolCallId）。lock で保護する。
    private var subagents = SubagentTracker()
    // 非同期の委任の本当の終わり（docs/BACKGROUND_CONTROL_2026-10-21.md §5）。すべて lock で保護する。
    /// 受領票か通知で終わりを待つ行（キーは toolCallId）。動いているかは subagents で見る。
    private var openDelegations: Set<String> = []
    /// Hermes / OpenClaw の台帳の見張り（セッションに 1 つ。最初の台帳の行で作る）。
    private var delegationWatcher: AcpDelegationWatcher?
    /// Grok の背景の spawn（subagent_id は subagent_spawned か受領票で結ぶ）。
    private var grokSpawns: [GrokSpawn] = []
    /// Grok の子のセッション id → 行の鍵。子の tool_call の title を行のいまの作業にする。
    private var grokChildSessions: [String: String] = [:]
    /// 開いている知らせのターン（親が子の完了で自分から始めたターン）。
    private var notificationTurn: NotificationTurn?
    private var seenNotificationPromptIds: Set<String> = []
    /// 下の停止で止めた知らせのターン。Grok が続きを流しても本文にしない（tool の終わりだけ通す）。
    private var cancelledNotificationPromptIds: Set<String> = []
    /// 前景の spawn_subagent の説明。subagent_spawned を背景の行に結ばないために覚える。
    private var foregroundSpawnDescriptions: Set<String> = []

    private struct GrokSpawn {
        let toolCallId: String
        let description: String?
        var subagentId: String?
    }

    private struct NotificationTurn {
        let promptId: String
        /// 空の activity の messageId
        let messageId: String
        /// 本文の吹き出しの messageId（本文が来てから作る）
        var bubbleId: String?
        var text = ""
        var hadBody = false
    }
    private let lock = NSLock()

    /// 回答待ちの session/request_permission（actionRequest の requestId → JSON-RPC の id 等）。lock で保護。
    private var pendingPermissions: [String: (rpcId: Any, optionIds: [String], client: AcpClient, createdAt: Date)] = [:]
    /// Hermes は承認要求を 60 秒で打ち切る。それより古い回答は届けずに捨てる。
    private static let permissionTimeout: TimeInterval = 60

    // transcript state (transcriptDir 非 nil の時のみ使用、lock で保護)
    private let transcriptDir: String?
    private var transcriptBubbleText: String = ""

    // MARK: - opencode config / commands state
    // ACP の session/new・session/load の result.configOptions、および
    // available_commands_update から取り込む。hermes / openclaw は configOptions を
    // 返さないので全て nil / 空のまま（無害）。configLock で保護する。
    private let configLock = NSLock()
    private var modelCurrentValue: String?
    private var modelOptionList: [(value: String, name: String)] = []
    private var modeCurrentValue: String?
    private var effortCurrentValue: String?
    private var effortOptionList: [(value: String, name: String)] = []
    private var availableCommandList: [(name: String, description: String)] = []

    // MARK: - モデル / Effort / モード（BuddyOS の設定を ACP の configOptions へ）
    // configOptions の id は agent ごとに違う（effort は "effort" / "reasoning_effort"）ので、
    // category（model / mode / thought_level）でも拾う。configLock で保護する。
    private var modelConfigId: String?
    private var modeConfigId: String?
    private var effortConfigId: String?
    private var modeOptionList: [(value: String, name: String)] = []
    /// このチャットだけの上書き（SessionOverridable）。次の session/prompt の前に反映する。
    private var overrides = SessionOverrides.none
    private let tuning: AcpSessionTuning
    /// recorder への書き込みを順番どおりにするための直列化。lock で保護。
    private var recordTail: Task<Void, Never>?

    /// available_commands_update がセッション開始後に再発火したときに呼ばれる。
    /// adapter 側で最新コマンドを subscriber へ再 push したい場合に利用する。
    var onCommandsChanged: (@Sendable ([(name: String, description: String)]) -> Void)?

    /// - Parameters:
    ///   - agentId: SessionEvent.agentId に詰める識別子 ("hermes" / "openclaw")
    ///   - initialSessionId: resume したい既存 session ID。nil なら新規。
    ///   - executable: agent CLI のフルパス
    ///   - args: CLI 引数 (デフォルト `["acp"]`)
    ///   - cwd: session の作業ディレクトリ。nil なら $HOME。
    ///   - env: spawn 時に export する env。Hermes は GLM_BASE_URL を渡す。
    ///   - transcriptDir: 非 nil なら user/assistant メッセージを
    ///     `<dir>/<sessionId>.jsonl` に追記する。openclaw は user prompt を自前の
    ///     jsonl に記録しない (履歴が assistant のみ・最新ターンのみになる) ため、
    ///     bridge 側で完全なトランスクリプトを持つ。
    init(
        agentId: String,
        initialSessionId: String?,
        executable: String,
        args: [String] = ["acp"],
        cwd: String?,
        env: [String: String] = [:],
        transcriptDir: String? = nil,
        tuning: AcpSessionTuning = AcpSessionTuning()
    ) {
        self.tuning = tuning
        self.agentId = agentId
        // Orchestrator が子として開いたときの深さ。プロセスは後で起こすので、開いた Task の値をここで覚えておく。
        self.openingDepth = OrchestratorContext.openingDepth
        self.sessionId = initialSessionId ?? "pending-\(UUID().uuidString.prefix(8))"
        self.resumeSessionId = initialSessionId
        self.executable = executable
        self.args = args
        self.env = env
        self.cwd = Self.normalizedCwd(cwd)
        self.transcriptDir = transcriptDir
        var c: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { cont in c = cont }
        self.continuation = c
        if tuning.subscribeOnOpen, let sid = initialSessionId, !sid.isEmpty {
            Task { [weak self] in try? await self?.ensureStarted() }
        }
    }

    /// configOptions / commands を読むために、まだ起動していなければ session を確立する。
    /// モデル一覧・現在値・切替の問い合わせはメッセージ送信前でも呼ばれるため、
    /// send() を待たずにここで spawn → session/new し、result.configOptions を取り込む。
    /// 多重呼び出しは進行中の 1 回の bootstrap に集約する（cold start を二重に走らせない）。
    func ensureStarted() async throws {
        switch planBootstrap() {
        case .closed:
            throw AcpError.processTerminated
        case .alreadyStarted:
            return
        case .awaitExisting(let t):
            try await t.value
        case .ownNew(let t):
            do {
                try await t.value
                setStarted()
            } catch {
                clearBootstrapTask()
                throw error
            }
        }
    }

    private enum BootstrapPlan {
        case closed
        case alreadyStarted
        case awaitExisting(Task<Void, Error>)
        case ownNew(Task<Void, Error>)
    }

    /// ロックは同期区間でのみ保持する（NSLock を await 跨ぎで持たない）。
    /// 進行中の bootstrap があれば await し、無ければ自分が新規に起動する。
    /// close 済みなら新たに spawn しない（close 後にプロセスが残るのを防ぐ）。
    private func planBootstrap() -> BootstrapPlan {
        lock.lock(); defer { lock.unlock() }
        if closed { return .closed }
        if didStart { return .alreadyStarted }
        if let t = bootstrapTask { return .awaitExisting(t) }
        let t = Task { try await self.bootstrap() }
        bootstrapTask = t
        return .ownNew(t)
    }

    private func setStarted() {
        lock.lock(); defer { lock.unlock() }
        // bootstrap 末尾の待機中にプロセスが落ちて resetAfterClientDeath 済みなら起動済みにしない
        // （死んだまま didStart=true になると、以後ずっと張り直せなくなる）。
        if client != nil { didStart = true }
    }

    private func clearBootstrapTask() {
        lock.lock(); defer { lock.unlock() }
        bootstrapTask = nil
    }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        do {
            try await ensureStarted()
        } catch {
            yieldError("ACP 起動失敗: \(error.localizedDescription)")
            continuation.finish()
            return
        }
        // 1 本の session/prompt として登録する（bubble 状態のリセットもここ）。
        let prompt = beginPrompt()
        // interrupt 済みの前ターンがまだ戻っていなければ、戻るまで session/prompt を送らない。
        guard await waitForCancelledPrompts(before: prompt) else {
            // 待機中に停止された。送らずに閉じる（done は前ターンの戻りか猶予切れで出る）。
            finishPrompt(prompt, error: nil)
            return
        }
        guard let live = liveClient() else {
            // error だけで done を出さないと hub の generating が固着する。close 済みなら
            // stream は finish 済みで yield は捨てられる（session/prompt は送らない）。
            finishPrompt(prompt, error: "ACP セッション未確立")
            return
        }
        let client = live.client
        let asid = live.sessionId

        // 履歴表示用。添付/skill 装飾前の生テキストに、画像の目印（履歴で実画像へ戻す）を足して記録する。
        let imageMarks = attachments.filter { $0.kind == .image }.map {
            "[image \"\($0.name)\" attached: \($0.mime), \($0.data.count) bytes]"
        }
        appendTranscript(role: "user", content: (imageMarks + [text]).joined(separator: "\n\n"), messageId: UUID().uuidString)

        // チャットで選んだモデル / Effort / モードを、この prompt の前に効かせる。
        await applyConfigForTurn()

        // prompt blocks 構築
        var blocks: [[String: Any]] = []
        var prefixText = text
        if !skills.isEmpty {
            prefixText = "/skill \(skills.joined(separator: ",")) \n" + text
        }
        // モードを prompt の頭の文字で効かせる agent（grok の plan は `/plan `）。
        if let mode = effectiveMode(), let prefix = tuning.modePromptPrefix[mode] {
            prefixText = prefix + prefixText
        }
        var trailingNotes: [String] = []
        for att in attachments {
            switch att.kind {
            case .image where tuning.imagesAsFiles:
                // image block を受けない agent には、ファイルに書き出してパスを渡す（HeadlessCliSession と同じ書き方）。
                var line = "[image \"\(att.name)\" attached: \(att.mime), \(att.data.count) bytes]"
                if let file = await AttachmentStore.shared.exportFile(name: att.name, mime: att.mime, data: att.data) {
                    line += " (file: \(file.path) — open this file to see the image)"
                }
                trailingNotes.append(line)
            case .image:
                let b64 = att.data.base64EncodedString()
                blocks.append([
                    "type": "image",
                    "data": b64,
                    "mimeType": att.mime
                ])
            case .file:
                if let s = String(data: att.data, encoding: .utf8) {
                    trailingNotes.append("<file name=\"\(att.name)\">\n\(s)\n</file>")
                } else {
                    trailingNotes.append("[file \"\(att.name)\" を添付 (binary, \(att.data.count) bytes)]")
                }
            }
        }
        var fullText = prefixText
        if !trailingNotes.isEmpty {
            fullText = trailingNotes.joined(separator: "\n\n") + "\n\n" + prefixText
        }
        blocks.insert(["type": "text", "text": fullText], at: 0)

        do {
            let res = try await client.request("session/prompt", params: [
                "sessionId": asid,
                "prompt": blocks
            ])
            if let err = res["error"] as? [String: Any] {
                let msg = (err["message"] as? String) ?? "unknown error"
                finishPrompt(prompt, error: "session/prompt error: \(msg)")
                return
            }
        } catch {
            // ACP プロセスが落ちた（openclaw gateway の再起動 / hermes の例外等）。死んだ client を
            // 捨て、次の send で確定 sid を session/load して張り直す。通知ループ終了側でも同じ
            // リセットを行うが、直後の send と競合しないようここでも同期的に行う（冪等）。
            if let acpError = error as? AcpError, case .processTerminated = acpError {
                resetAfterClientDeath(client)
            }
            finishPrompt(prompt, error: "session/prompt failed: \(error.localizedDescription)")
            return
        }

        finishPrompt(prompt, error: nil)
    }

    func interrupt() async {
        // ACP の session/cancel 通知を送る。agent は進行中 turn を停止し、
        // session/prompt の応答（stopReason: cancelled）が返ってくる。done はその戻りで出す
        // （ここでも出すと cancelled 応答の done と二重になり、遅れた 2 回目が後続ターンの途中で
        // hub/iOS を完了扱いにして予約キューを並行 dispatch してしまう）。
        // 回答待ちの承認は cancelled で返す（ACP 仕様: session/cancel の前に保留中の
        // session/request_permission へ cancelled を応答する）。
        cancelPendingPermissions()
        // 起こされた（知らせの）ターンの途中なら、それも止める。止めないと返事が流れ続けて停止が効かなかったように見える。
        let stoppedWoken = cancelNotificationTurnIfOpen()
        guard let target = markInterrupted() else {
            // 知らせのターンを閉じた done（origin = task-notification）が、アプリの生成中を解く。
            if stoppedWoken { return }
            // done を出し終えている（実行中の prompt が無い / 猶予切れで補った）。最後の chunk が
            // session/prompt の応答より後に通知ループで処理されると、done の後に新しい bubble の delta が
            // 流れて hub/iOS が「考え中」に戻る。停止でその固着を解けるよう、session/cancel は送らずに
            // bubble を閉じて done だけ出す（agent は idle なので、これで予約が dispatch されても安全）。
            let idle = settleIdleInterrupt()
            guard idle.settle else { return }
            emitBubbleEnd(idle.bubble)
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString))
            return
        }
        if let c = target.client, let asid = target.sessionId {
            try? c.notify("session/cancel", params: ["sessionId": asid])
        }
        // 止めたターンの委任は stopped で閉じる（猶予切れの後は更新を捨てるので、終わりの知らせで閉じられない）。
        abandonSubagents(state: "stopped", onlyForeground: true)
        // 現在の bubble は即閉じる。
        endCurrentBubbleIfAny()
        // cancel に応じない / 応答が遅い agent でも待機が解けるよう、猶予後に done を補う。
        let seq = target.seq
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: AcpSession.interruptDoneGraceNanos)
            self?.finishInterruptedIfStuck(seq: seq)
        }
    }

    /// 開いている知らせのターンに session/cancel を送って閉じる。閉じたら true。
    /// そのターンの以後の更新は捨てる（cancelledNotificationPromptIds）。
    private func cancelNotificationTurnIfOpen() -> Bool {
        lock.lock()
        guard !closed, let turn = notificationTurn else { lock.unlock(); return false }
        cancelledNotificationPromptIds.insert(turn.promptId)
        let c = client, asid = acpSessionId
        lock.unlock()
        if let c, let asid { try? c.notify("session/cancel", params: ["sessionId": asid]) }
        closeNotificationTurn(silent: !turn.hadBody)
        return true
    }

    func close() async {
        let clients = markClosed()
        if let token = takeMainToken() { await Orchestrator.shared.revoke(token: token) }
        clients.live?.close()
        // bootstrap 中の client も kill する。AcpClient.request はキャンセルでは起きないので、
        // close で pending を processTerminated にして bootstrap を既存の catch 経路で畳ませる。
        clients.starting?.close()
        // プロセスごと閉じたので、実行中の委任の行は stopped で閉じる（stream を閉じる前に流す）。
        abandonSubagents(state: "stopped", onlyForeground: false)
        stopDelegationWatching()
        closeNotificationTurn()
        continuation.finish()
    }

    // MARK: - mainagent・ふつうのセッション（Bridge の MCP を渡す）

    /// mainagent の合鍵（Orchestrator）。プロセスを張り直すたびに発行し直す。lock で保護する。
    private var mainToken: String?
    /// Orchestrator が子として開いたときの深さ（nil = 利用者が開いた）。
    private let openingDepth: Int?

    private func takeMainToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        let t = mainToken
        mainToken = nil
        return t
    }

    /// mainagent のフォルダ（または設定 allSessions が有効ならどのフォルダでも）のとき、Bridge の MCP を渡す。
    /// ACP は書く道具を外せないので、mainagent の決まりは AGENTS.md だけ。
    private func mainagentMcpServers(initialize res: [String: Any], resumeSid: String?) async -> [[String: Any]] {
        guard let transport = Self.mainagentMcpTransport(initialize: res, relayExecutable: McpStdioRelay.currentExecutable)
        else { return [] }
        if let old = takeMainToken() { await Orchestrator.shared.revoke(token: old) }
        guard let grant = await Orchestrator.shared.sessionGrant(agentId: agentId, sessionId: resumeSid, cwd: cwd,
                                                                 unattended: tuning.unattended, depth: openingDepth ?? 0)
        else { return [] }
        let token = grant.token
        await Orchestrator.shared.bind(token: token, session: self)
        lock.lock(); mainToken = token; lock.unlock()
        return [Self.mainagentMcpServer(transport, token: token, port: MainAgentWorkspace.currentPort)]
    }

    /// mainagent の MCP の渡し方。
    enum MainAgentMcpTransport: Equatable {
        /// `/mcp` を直接（initialize の `agentCapabilities.mcpCapabilities.http` が true）。
        case http
        /// stdio の中継（`<Bridge のバイナリ> mcp-stdio-relay`）。stdio は ACP のエージェントが必ず受け取れる形。
        case stdioRelay(executable: String)
    }

    /// initialize の応答から渡し方を決める。応答に result が無い・中継のバイナリが分からないときは渡さない（nil）。
    static func mainagentMcpTransport(initialize res: [String: Any], relayExecutable: String?) -> MainAgentMcpTransport? {
        guard let result = res["result"] as? [String: Any] else { return nil }
        let mcp = (result["agentCapabilities"] as? [String: Any])?["mcpCapabilities"] as? [String: Any]
        if mcp?["http"] as? Bool == true { return .http }
        return relayExecutable.map { .stdioRelay(executable: $0) }
    }

    /// session/new・load の `mcpServers` の 1 件。stdio の中継には合鍵を `env` で渡す（引数は ps で見える）。
    static func mainagentMcpServer(_ transport: MainAgentMcpTransport, token: String, port: Int) -> [String: Any] {
        switch transport {
        case .http:
            return MainAgentWorkspace.acpServer(token: token, port: port)
        case .stdioRelay(let executable):
            return McpStdioRelay.acpServer(token: token, port: port, executable: executable)
        }
    }

    private func markClosed() -> (live: AcpClient?, starting: AcpClient?) {
        lock.lock(); defer { lock.unlock() }
        closed = true
        // プロセスごと閉じるので応答は不要。表だけ空にする。
        pendingPermissions.removeAll()
        return (client, startingClient)
    }

    // MARK: - 承認要求（session/request_permission）

    /// session/request_permission を actionRequest に翻訳する。Hermes はこの tool_call を
    /// session/update として送らないので、title / subtitle は params.toolCall から作る。
    private func handlePermissionRequest(_ req: AcpIncomingRequest, client: AcpClient) {
        let params = req.params
        let toolCall = (params["toolCall"] as? [String: Any]) ?? [:]
        let rawInput = (toolCall["rawInput"] as? [String: Any]) ?? [:]
        let options: [(id: String, name: String)] = ((params["options"] as? [[String: Any]]) ?? []).compactMap { o -> (id: String, name: String)? in
            guard let oid = o["optionId"] as? String, !oid.isEmpty else { return nil }
            return (oid, (o["name"] as? String) ?? oid)
        }
        guard !options.isEmpty else {
            // 選べる選択肢が無ければ待たせずに取り消す。
            DispatchQueue.global(qos: .utility).async {
                try? client.respond(to: req.id, result: ["outcome": ["outcome": "cancelled"]])
            }
            return
        }
        // モードで決まっている答え（Full Access は全部許可・Edit は編集だけ許可・無人実行は拒否）は
        // iPhone に出さずにその場で返す。
        let kinds: [(id: String, kind: String)] = ((params["options"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let oid = o["optionId"] as? String, !oid.isEmpty else { return nil }
            return (oid, (o["kind"] as? String) ?? "")
        }
        if let decided = Self.autoPermissionAnswer(mode: effectiveMode(), toolKind: toolCall["kind"] as? String,
                                                   unattended: tuning.unattended, options: kinds) {
            let outcome: [String: Any] = decided.isEmpty
                ? ["outcome": "cancelled"] : ["outcome": "selected", "optionId": decided]
            DispatchQueue.global(qos: .utility).async {
                try? client.respond(to: req.id, result: ["outcome": outcome])
            }
            return
        }
        let requestId = UUID().uuidString
        let title = (toolCall["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(agentId) の承認"
        let subtitle = rawInput["command"] as? String
        var meta: [String: String] = [
            "requestId": requestId,
            "kind": "approval",
            "option_count": String(options.count),
            "allowsOther": "0"
        ]
        for (index, option) in options.enumerated() {
            meta["option_\(index)_title"] = option.name
            meta["option_\(index)_value"] = option.id
        }
        lock.lock()
        pendingPermissions[requestId] = (rpcId: req.id, optionIds: options.map { $0.id }, client: client, createdAt: Date())
        lock.unlock()
        continuation.yield(.actionRequest(
            agentId: agentId,
            sessionId: sessionId,
            messageId: requestId,
            title: title,
            subtitle: subtitle,
            metadata: meta
        ))
    }

    /// モードで答えが決まる承認要求の選択肢 id。nil = iPhone に出して待つ。"" = 取り消す。
    /// - dangerous: 許可（一度だけ）
    /// - edit: 編集系（ACP の tool kind が edit / delete / move）だけ許可
    /// - 無人実行（cron）: 答える人がいないので拒否
    static func autoPermissionAnswer(mode: String?, toolKind: String?, unattended: Bool,
                                     options: [(id: String, kind: String)]) -> String? {
        func pick(_ wanted: [String]) -> String? {
            for kind in wanted { if let o = options.first(where: { $0.kind == kind }) { return o.id } }
            return nil
        }
        if mode == "dangerous", let allow = pick(["allow_once", "allow_always"]) { return allow }
        if mode == "edit", let kind = toolKind, ["edit", "delete", "move"].contains(kind),
           let allow = pick(["allow_once", "allow_always"]) { return allow }
        if unattended { return pick(["reject_once", "reject_always"]) ?? "" }
        return nil
    }

    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {
        lock.lock()
        let pending = pendingPermissions.removeValue(forKey: requestId)
        lock.unlock()
        guard let pending else { return }
        // 打ち切り済みの要求に答えても届かない（エージェントはもう次へ進んでいる）。
        guard Date().timeIntervalSince(pending.createdAt) <= Self.permissionTimeout else { return }
        let outcome: [String: Any] = pending.optionIds.contains(decision)
            ? ["outcome": "selected", "optionId": decision]
            : ["outcome": "cancelled"]
        try? pending.client.respond(to: pending.rpcId, result: ["outcome": outcome])
    }

    /// 回答待ちの承認をすべて cancelled で返し、表を空にする。
    private func cancelPendingPermissions() {
        lock.lock()
        let all = Array(pendingPermissions.values)
        pendingPermissions.removeAll()
        lock.unlock()
        for pending in all {
            try? pending.client.respond(to: pending.rpcId, result: ["outcome": ["outcome": "cancelled"]])
        }
    }

    // MARK: - prompt / turn state

    /// 実行中の prompt を全て interrupt 済みにする。done を出し終えていれば nil（cancel するものは無い）。
    /// doneOwed は cancel されていない prompt が実行中なら必ず true。
    private func markInterrupted() -> (seq: Int, client: AcpClient?, sessionId: String?)? {
        lock.lock(); defer { lock.unlock() }
        guard doneOwed else { return nil }
        // 新たに cancel する prompt がある時だけ、戻りを待つ上限の起点を更新する。
        if promptSeq > cancelledThrough { cancelledAt = Date() }
        cancelledThrough = promptSeq
        return (promptSeq, closed ? nil : client, acpSessionId)
    }

    /// done を出し終えた後の interrupt 用。bootstrap 中でなければ開いている bubble を取り出し、done を
    /// 出してよい（true）と返す。bootstrap 中は send が beginPrompt の前で待っているので出さない
    /// （出すと hub が予約を dispatch し、その後に送られる prompt と並行する）。
    private func settleIdleInterrupt() -> (settle: Bool, bubble: (messageId: String, text: String)?) {
        lock.lock(); defer { lock.unlock() }
        guard !doneOwed, !closed, didStart || bootstrapTask == nil else { return (false, nil) }
        return (true, takeCurrentBubbleLocked())
    }

    /// interrupt 済みの session/prompt がまだ戻っていなければ、戻るまで次の session/prompt を送らずに待つ
    /// （cancelledAt から cancelledPromptWaitLimit まで）。hermes は実行中に届いた prompt をキューに積んで
    /// 即 end_turn を返し、旧ターンの後で勝手に実行するので、並行して送るとその応答が done の後に流れる。
    /// 猶予切れの done で予約が dispatch された時や、停止直後の送信で効く。待機中に自分も interrupt されたら false。
    private func waitForCancelledPrompts(before id: Int) async -> Bool {
        while true {
            lock.lock()
            if id <= cancelledThrough { lock.unlock(); return false }
            let waiting = !closed && !Task.isCancelled
                && inFlightPrompts.contains { $0 <= cancelledThrough }
                && Date().timeIntervalSince(cancelledAt ?? .distantPast) < Self.cancelledPromptWaitLimit
            // 送る直前に、beginPrompt から続けていた旧ターンの出力の破棄を解く。
            if !waiting { discardingStaleUpdates = false }
            lock.unlock()
            if !waiting { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func beginPrompt() -> Int {
        lock.lock(); defer { lock.unlock() }
        promptSeq += 1
        inFlightPrompts.insert(promptSeq)
        doneOwed = true
        // interrupt 済みの prompt がまだ走っていれば、その残りの出力をこのターンに混ぜないよう
        // session/prompt を送るまで捨て続ける（waitForCancelledPrompts で解く）。
        discardingStaleUpdates = inFlightPrompts.contains { $0 <= cancelledThrough }
        // 一旦リセット
        currentMessageId = nil
        hadToolSinceLastMessage = false
        subagents.pruneFinished()
        endedToolIds.removeAll()
        return promptSeq
    }

    /// session/prompt 1 本の終了。done は「有効な prompt が残っていない」時に 1 回だけ出す。
    /// interrupt 済みの prompt は error を出さず、全 prompt が戻った時だけ done を出す
    /// （後続ターンの bubble を閉じたり、その途中で done を出したりしない）。
    /// error 時も done を出して hub の generating / 予約キューを解放する。
    private func finishPrompt(_ id: Int, error: String?) {
        lock.lock()
        inFlightPrompts.remove(id)
        let cancelled = id <= cancelledThrough
        let settled = cancelled
            ? inFlightPrompts.isEmpty
            : !inFlightPrompts.contains { $0 > cancelledThrough }
        let shouldFinish = doneOwed && settled
        if shouldFinish { doneOwed = false }
        let bubble = shouldFinish ? takeCurrentBubbleLocked() : nil
        lock.unlock()
        // 失敗で終わったターンの委任には、もう終わりの知らせが来ない。
        if shouldFinish, error != nil, !cancelled { abandonSubagents(state: "failed", onlyForeground: true) }
        // 止めたターンで承認待ちのまま取り消された背景の spawn には、受領票も終わりの知らせも来ない。
        if shouldFinish, cancelled { closeUnboundGrokSpawns() }
        if let error, !cancelled { yieldError(error) }
        if shouldFinish {
            emitBubbleEnd(bubble)
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString))
        }
    }

    /// interrupt の猶予切れ。その後に新しい prompt が始まっていれば、そちらの完了で done が出るので何もしない。
    private func finishInterruptedIfStuck(seq: Int) {
        lock.lock()
        guard doneOwed, promptSeq == seq else { lock.unlock(); return }
        doneOwed = false
        // cancel に応じなかった agent が done の後に delta/activity を流すと、hub/iOS が
        // 「考え中」に戻り、以降 done が来ずに固着する。停止済みターンの残りなので捨てる。
        discardingStaleUpdates = true
        let bubble = takeCurrentBubbleLocked()
        lock.unlock()
        // 以後の更新は捨てるので、cancel の後に始まった委任もここで閉じる。
        abandonSubagents(state: "stopped", onlyForeground: true)
        closeUnboundGrokSpawns()
        emitBubbleEnd(bubble)
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString))
    }

    private func isDiscardingStaleUpdates() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return discardingStaleUpdates
    }

    /// close 済みでなく session が確立していれば (client, sid) を返す。
    private func liveClient() -> (client: AcpClient, sessionId: String)? {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let c = client, let sid = acpSessionId else { return nil }
        return (c, sid)
    }

    /// ACP プロセスが落ちた client を捨て、次の ensureStarted で張り直せるよう起動状態を戻す。
    /// 確定済み sid を resumeSessionId に残すので、新規チャットでも session/load で同じ会話に戻る
    /// （sessionStarted は didNotifySessionStarted により再送しない → hub の key 張り替えは起きない）。
    /// 古い client の後始末が張り直し後の client を壊さないよう、同一性で判定する。
    private func resetAfterClientDeath(_ dead: AcpClient) {
        lock.lock()
        guard !closed, client === dead else { lock.unlock(); return }
        if let sid = acpSessionId { resumeSessionId = sid }
        client = nil
        acpSessionId = nil
        didStart = false
        bootstrapTask = nil
        lock.unlock()
        FileHandle.standardError.write(Data("[acp] \(agentId) process terminated; will reload session on next send\n".utf8))
        // プロセスと一緒に委任の先も止まった（Hermes・Grok の子はプロセスの中で動く）。異常終了なので failed で閉じる。
        // OpenClaw の子は gateway で動き続けるので、台帳を見ている行は閉じずに見続ける。
        let keep = tuning.delegationLedger == .openclaw ? watchedDelegationKeys() : []
        abandonSubagents(state: "failed", onlyForeground: false, except: keep)
        if tuning.delegationLedger != .openclaw { stopDelegationWatching() }
        resetGrokDelegations()
        closeNotificationTurn()
    }

    // MARK: - opencode config accessors

    func currentModel() -> String? {
        configLock.lock(); defer { configLock.unlock() }
        return modelCurrentValue
    }

    func currentMode() -> String? {
        configLock.lock(); defer { configLock.unlock() }
        return modeCurrentValue
    }

    func currentEffort() -> String? {
        configLock.lock(); defer { configLock.unlock() }
        return effortCurrentValue
    }

    func modelCatalog() -> [(value: String, name: String)] {
        configLock.lock(); defer { configLock.unlock() }
        return modelOptionList
    }

    /// effort configOption が存在するかどうか（存在しないモデルでは nil を返すため）。
    func hasEffortOption() -> Bool {
        configLock.lock(); defer { configLock.unlock() }
        return !effortOptionList.isEmpty || effortCurrentValue != nil
    }

    func availableCommands() -> [(name: String, description: String)] {
        configLock.lock(); defer { configLock.unlock() }
        return availableCommandList
    }

    /// session/set_config_option を呼んで configId に value をセットし、
    /// 返ってきた configOptions で現在値を更新する。live client/session が無ければ throw。
    func setConfigOption(configId: String, value: String) async throws {
        guard let client = client, let asid = acpSessionId else {
            throw AcpError.invalidResponse("no live ACP session for set_config_option")
        }
        let res = try await client.request("session/set_config_option", params: [
            "sessionId": asid,
            "configId": configId,
            "value": value
        ])
        if let err = res["error"] as? [String: Any] {
            let msg = (err["message"] as? String) ?? "unknown error"
            throw AcpError.invalidResponse("set_config_option error: \(msg)")
        }
        if let result = res["result"] as? [String: Any] {
            parseConfigOptions(result["configOptions"])
        }
    }

    /// result.configOptions（配列 of {id,category,type,currentValue,options:[{value,name}]}）を
    /// 取り込んで model/mode/effort の現在値と選択肢を更新する。
    private func parseConfigOptions(_ raw: Any?) {
        guard let options = raw as? [[String: Any]] else { return }
        configLock.lock(); defer { configLock.unlock() }
        for opt in options {
            guard let id = opt["id"] as? String else { continue }
            let current = opt["currentValue"] as? String
            let choices: [(value: String, name: String)] = (opt["options"] as? [[String: Any]] ?? []).compactMap { o in
                guard let v = o["value"] as? String else { return nil }
                let n = (o["name"] as? String) ?? v
                return (value: v, name: n)
            }
            let category = opt["category"] as? String
            if id == "model" || category == "model" {
                modelConfigId = id
                modelCurrentValue = current
                modelOptionList = choices
            } else if id == "mode" || category == "mode" {
                modeConfigId = id
                modeCurrentValue = current
                modeOptionList = choices
            } else if id == "effort" || id == "reasoning_effort" || category == "thought_level" {
                effortConfigId = id
                effortCurrentValue = current
                effortOptionList = choices
            }
        }
    }

    /// effort の選択肢（agent_info の supportedReasoningEfforts に出す）。
    func effortChoices() -> [String] {
        configLock.lock(); defer { configLock.unlock() }
        return effortOptionList.map(\.value)
    }

    // MARK: - チャットの上書き（SessionOverridable）

    func applyOverrides(_ overrides: SessionOverrides) {
        configLock.lock(); defer { configLock.unlock() }
        self.overrides = overrides
    }

    /// チャットの上書き > 無人実行の指定 > エージェント既定。
    func effectiveMode() -> String? {
        configLock.lock(); defer { configLock.unlock() }
        return overrides.mode ?? tuning.permissionMode ?? tuning.defaults.mode
    }

    /// 上書き・既定のモデル / Effort / モードのうち、今の値と違うものを session/set_config_option で切り替える。
    /// その agent が持っていない項目・選択肢に無い値は送らない（送ると prompt ごと失敗する agent がある）。
    private func applyConfigForTurn() async {
        configLock.lock()
        let wantModel = overrides.model ?? tuning.defaults.model
        let wantEffort = overrides.reasoningEffort ?? tuning.defaults.reasoningEffort
        let wantMode = overrides.mode ?? tuning.permissionMode ?? tuning.defaults.mode
        var changes: [(id: String, value: String)] = []
        if let id = modelConfigId, let want = wantModel,
           let value = Self.matchOption(want, in: modelOptionList), value != modelCurrentValue {
            changes.append((id, value))
        }
        if let id = effortConfigId, let want = wantEffort,
           let value = Self.matchOption(want, in: effortOptionList), value != effortCurrentValue {
            changes.append((id, value))
        }
        if let id = modeConfigId, let map = tuning.modeConfigValues, let mode = wantMode,
           let value = map[mode] ?? map["*"], modeOptionList.contains(where: { $0.value == value }),
           value != modeCurrentValue {
            changes.append((id, value))
        }
        configLock.unlock()
        for change in changes {
            do {
                try await setConfigOption(configId: change.id, value: change.value)
            } catch {
                FileHandle.standardError.write(Data("[acp] \(agentId) set \(change.id)=\(change.value) failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// BuddyOS 側の値（"auto" / "composer-2.5" など）を agent の選択肢の値に合わせる。
    /// 完全一致 → 変種の付かない名前（cursor は "composer-2.5[fast=true]" の形）→ 表示名の順に探す。
    static func matchOption(_ wanted: String, in options: [(value: String, name: String)]) -> String? {
        if options.contains(where: { $0.value == wanted }) { return wanted }
        if let o = options.first(where: { $0.value.split(separator: "[").first.map(String.init) == wanted }) { return o.value }
        if let o = options.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return o.value }
        return nil
    }

    // MARK: - private

    private func bootstrap() async throws {
        let t0 = Date()
        func mark(_ label: String) {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            FileHandle.standardError.write(Data("[acp.bootstrap] \(agentId) +\(ms)ms \(label)\n".utf8))
        }
        let c = AcpClient(executable: executable, args: args, env: env, loginShell: tuning.loginShell)
        // エージェント発の承認要求（Hermes のコマンド実行承認など）を iOS のピッカーへ出す。
        // 未登録だと -32601 で即拒否され、承認が要る操作が常に失敗する。c を強参照で捕まえると
        // 循環参照になるので weak。下の通知 consumer 上で通知と到着順に同期で呼ばれるのでブロックしない。
        c.setRequestHandler { [weak self, weak c] req in
            guard req.method == "session/request_permission", let self, let c else { return false }
            self.handlePermissionRequest(req, client: c)
            return true
        }
        try c.start()
        mark("spawned")
        // close() が bootstrap 中でもこの client を kill できるよう登録する（client は末尾まで nil のため、
        // 未登録だと bootstrap 中の close が no-op になり、その後に確立したプロセスが誰にも閉じられず残る）。
        let reg = registerStartingClient(c)
        guard reg.registered else {
            c.close()
            throw AcpError.processTerminated
        }
        let resumeSid = reg.resumeSid
        // 通知 consumer は session/load より前に起動すること。後に起動すると、
        // ACP 仕様で session/load 中に流れてくる履歴 replay (agent_message_chunk) が
        // AsyncStream にバッファされたまま acceptingUpdates=true 後に消費され、
        // resume 直後に直前の assistant 応答が二重表示される（読み上げも重複する）。
        Task.detached { [weak self] in
            guard let self else { return }
            for await msg in c.notifications {
                self.handleNotification(msg)
            }
            // stream 終了 = client が close された（プロセス死 / close() / bootstrap 失敗）。
            // 確立済みセッションのプロセスが落ちた場合だけ、次の send で張り直せるよう状態を戻す。
            self.resetAfterClientDeath(c)
        }
        var resolvedSid = ""

        do {
            // launchd 配下のコールドスタートは zsh -lic + Python venv 起動で initialize 応答まで
            // 実測 23 秒かかる (2026-06-11)。8 秒だと冷間時に必ず "acp failed to initialize" になる。
            let initRes = try await withTimeout(seconds: 60) {
                try await c.request("initialize", params: [
                    "protocolVersion": 1,
                    "clientCapabilities": [
                        "fs": ["readTextFile": false, "writeTextFile": false]
                    ],
                    "clientInfo": ["name": "BuddyOS-Bridge", "version": "0.1"]
                ])
            }
            mark("initialized")
            let mcpServers = await mainagentMcpServers(initialize: initRes, resumeSid: resumeSid)

            // session/load・session/new も無応答だと永久に待つのでタイムアウトを掛ける
            // （session/prompt は長時間実行が正常なので掛けない）。load は履歴 replay を含むので長めに取る。
            let res: [String: Any]
            if let sid = resumeSid, !sid.isEmpty, !sid.hasPrefix("pending-") {
                self.acceptingUpdates = false
                res = try await withTimeout(seconds: 120) {
                    try await c.request("session/load", params: [
                        "sessionId": sid,
                        "cwd": self.cwd,
                        "mcpServers": mcpServers
                    ])
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.acceptingUpdates = true
            } else {
                res = try await withTimeout(seconds: 60) {
                    try await c.request("session/new", params: [
                        "cwd": self.cwd,
                        "mcpServers": mcpServers
                    ])
                }
                self.acceptingUpdates = true
            }

            guard let result = res["result"] as? [String: Any] else {
                let detail = ((res["error"] as? [String: Any])?["message"] as? String).map { ": \($0)" } ?? ""
                throw AcpError.invalidResponse((resumeSid == nil ? "no result in session/new" : "session/load failed (cwd=\(self.cwd))") + detail)
            }
            if resumeSid != nil && result.isEmpty {
                throw AcpError.invalidResponse("session/load returned no session state; session may not exist in ACP storage")
            }
            // opencode の configOptions (model/mode/effort) を取り込む。
            // session/new と session/load の両方で result に入る。hermes/openclaw は
            // configOptions を返さないので no-op。
            parseConfigOptions(result["configOptions"])
            let sid: String = (result["sessionId"] as? String) ?? (resumeSid ?? "")
            if sid.isEmpty {
                throw AcpError.invalidResponse("no sessionId")
            }
            resolvedSid = sid
            // closed の確認と client の確定は同じロック区間で行う（close() が client==nil を読んだ
            // 直後に代入されると、誰にも閉じられない client が残る）。closed なら catch で c.close()。
            guard commitClient(c, sid: sid) else {
                throw AcpError.processTerminated
            }
            mark("session ready sid=\(sid.prefix(8))")
        } catch {
            mark("FAILED: \(error.localizedDescription)")
            clearStartingClient(c)
            c.close()
            self.acceptingUpdates = false
            throw error
        }

        if !didNotifySessionStarted {
            continuation.yield(.sessionStarted(agentId: agentId, sessionId: resolvedSid))
            didNotifySessionStarted = true
        }

        // OpenClaw は session/new 応答直後に session_info_update / available_commands_update を
        // 連投し、その後 channel binding 等の内部初期化を行う。早すぎる session/prompt は
        // 取りこぼされて応答が来なくなるので、待ってから次のリクエストを受け付ける（既定 2 秒）。
        if tuning.postSessionDelayNanos > 0 {
            try? await Task.sleep(nanoseconds: tuning.postSessionDelayNanos)
        }
    }

    /// bootstrap 中の client を登録し、session/load に使う sid を返す。close 済みなら登録しない。
    private func registerStartingClient(_ c: AcpClient) -> (registered: Bool, resumeSid: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return (false, nil) }
        startingClient = c
        return (true, resumeSessionId)
    }

    /// closed でなければ client を確定する。close 済みなら false（呼び出し側で c.close() する）。
    private func commitClient(_ c: AcpClient, sid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        acpSessionId = sid
        sessionId = sid
        client = c
        startingClient = nil
        return true
    }

    private func clearStartingClient(_ c: AcpClient) {
        lock.lock(); defer { lock.unlock() }
        if startingClient === c { startingClient = nil }
    }

    private func handleNotification(_ msg: [String: Any]) {
        let method = msg["method"] as? String
        let params = msg["params"] as? [String: Any] ?? [:]
        // 親のセッションと違う会話（Grok の子のセッション）の通知は、親の出力にしない。session/new の返事の前は絞らない。
        if let notifiedSid = params["sessionId"] as? String, let parentSid = currentAcpSessionId(), notifiedSid != parentSid {
            handleChildSessionNotification(method: method, params: params)
            return
        }
        if let method, method.hasPrefix("_x.ai/") {
            guard tuning.remoteTurns || tuning.xaiNotifications, acceptingUpdates else { return }
            switch method {
            case "_x.ai/queue/changed":
                if tuning.xaiNotifications { openNotificationTurnIfNeeded(params) }
                if tuning.remoteTurns { handleRemoteQueue(params) }
            case "_x.ai/session_notification":
                if tuning.xaiNotifications { handleXaiNotification(params) }
            // 共有している別の画面には turn_completed が来ない。完了はこちらで知る。
            case "_x.ai/session/prompt_complete":
                if tuning.remoteTurns { finishRemoteTurnIfAny() }
            default:
                break
            }
            return
        }
        guard method == "session/update",
              let update = params["update"] as? [String: Any]
        else { return }

        let kind = (update["sessionUpdate"] as? String) ?? ""
        let sid = self.sessionId

        // available_commands_update は acceptingUpdates のゲートを通さず無条件で取り込む。
        // session/load の replay 期間 (acceptingUpdates=false) に発火することがあり、
        // ここで弾くと resume 後にコマンド一覧が空のままになるため。
        if kind == "available_commands_update" {
            handleAvailableCommandsUpdate(update: update)
            return
        }

        // 以降は transcript を生成する kind のみ。replay 期間中はドロップする
        // （再接続直後に直前の assistant 応答が二重表示されるのを防ぐ）。
        guard acceptingUpdates else { return }
        // 知らせのターンの本文は、止めたターンの残りを捨てている間も捨てない。
        if tuning.xaiNotifications, routeNotificationTurnUpdate(kind: kind, update: update, params: params, sid: sid) { return }
        guard !isDiscardingStaleUpdates() else { return }

        switch kind {
        case "agent_message_chunk":
            handleAgentMessageChunk(update: update, sid: sid)
        case "agent_thought_chunk":
            handleAgentThoughtChunk(update: update, sid: sid)
        case "tool_call":
            handleToolCall(update: update, sid: sid)
        case "tool_call_update":
            handleToolCallUpdate(update: update, sid: sid)
        case "plan":
            handlePlan(update: update, sid: sid)
        case "turn_completed" where tuning.remoteTurns:
            finishRemoteTurnIfAny()
        default:
            break
        }
    }

    /// テスト用: ACP プロセスが落ちたことにする（通知の stream が閉じ、resetAfterClientDeath が走る）。
    func simulateProcessDeathForTesting() {
        let c = lock.withLock { client }
        c?.close()
    }

    private func currentAcpSessionId() -> String? {
        lock.lock(); defer { lock.unlock() }
        return acpSessionId
    }

    /// 子のセッションの通知。Grok の子（child_session_id を覚えたもの）の tool_call の title だけを、その行のいまの作業にする。
    /// ほかは捨てる（子の発言・user_message・available_commands を親に混ぜない）。
    private func handleChildSessionNotification(method: String?, params: [String: Any]) {
        guard tuning.xaiNotifications, method == "session/update",
              let childSid = params["sessionId"] as? String,
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "tool_call",
              let title = update["title"] as? String, !title.isEmpty else { return }
        lock.lock()
        let key = grokChildSessions[childSid]
        let p = key.flatMap { subagents.activity(key: $0, text: title) }
        lock.unlock()
        yieldSubagent(p, sid: sessionId)
    }

    // MARK: - 別の画面（ターミナル）が始めたターン

    /// 実行が始まった発言（runningText）が自分の送ったものでなければ、ターミナルで打たれた発言として流す。
    /// 自分の session/prompt は beginPrompt で doneOwed を立ててから送るので、その間に来たものは自分のもの。
    private func handleRemoteQueue(_ params: [String: Any]) {
        // 実行中の発言が無くなった = ターンが終わった（prompt_complete を取りこぼしたときの控え）。
        if params["runningPromptId"] == nil {
            finishRemoteTurnIfAny()
            return
        }
        guard (params["runningKind"] as? String ?? "prompt") == "prompt",
              let promptId = params["runningPromptId"] as? String, !promptId.isEmpty,
              !Self.isNotificationPrompt(promptId),
              let text = params["runningText"] as? String, !text.isEmpty else { return }
        lock.lock()
        let isRemote = !doneOwed && !closed && seenRemotePromptIds.insert(promptId).inserted
        if isRemote {
            remoteTurnActive = true
            currentMessageId = nil
            hadToolSinceLastMessage = false
            // ほかの画面の発言も新しいターン。終わった委任の行を忘れる（アプリも同じ時点で捨てる）。
            subagents.pruneFinished()
        }
        lock.unlock()
        guard isRemote else { return }
        appendTranscript(role: "user", content: text, messageId: promptId)
        continuation.yield(.userMessage(text, agentId: agentId, sessionId: sessionId))
    }

    /// ターミナルのターンが終わったら、開いている吹き出しを閉じて完了を流す（iPhone の「考え中」を解く）。
    private func finishRemoteTurnIfAny() {
        lock.lock()
        guard remoteTurnActive, !doneOwed else { lock.unlock(); return }
        remoteTurnActive = false
        let bubble = takeCurrentBubbleLocked()
        lock.unlock()
        emitBubbleEnd(bubble)
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString))
    }

    /// ACP の `plan` セッション更新を全置換スナップショットとして流す（hermes/openclaw/opencode 共通）。
    /// update.entries は ACP 仕様で `[{content, priority?, status}]`。status は pending|in_progress|completed で
    /// BuddyOS の plan_update と一致するため、`{entries:[{content,status,activeForm?}]}` へ正規化する
    /// （ACP plan に activeForm は無いので省略）。
    private func handlePlan(update: [String: Any], sid: String) {
        guard let rawEntries = update["entries"] as? [[String: Any]] else { return }
        let entries: [[String: String]] = rawEntries.compactMap { e in
            guard let content = e["content"] as? String, !content.isEmpty else { return nil }
            let status = (e["status"] as? String) ?? "pending"
            return ["content": content, "status": status]
        }
        guard !entries.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["entries": entries]),
              let json = String(data: data, encoding: .utf8) else { return }
        continuation.yield(.planUpdate(agentId: agentId, sessionId: sid, entriesJSON: json))
    }

    /// available_commands_update を取り込む。update.availableCommands は
    /// `[{name, description, input?}]`。常に全置換し、onCommandsChanged を呼ぶ。
    private func handleAvailableCommandsUpdate(update: [String: Any]) {
        guard let cmds = update["availableCommands"] as? [[String: Any]] else { return }
        let parsed: [(name: String, description: String)] = cmds.compactMap { c in
            guard let name = c["name"] as? String, !name.isEmpty else { return nil }
            let desc = (c["description"] as? String) ?? ""
            return (name: name, description: desc)
        }
        configLock.lock()
        availableCommandList = parsed
        configLock.unlock()
        onCommandsChanged?(parsed)
    }

    private static func normalizedCwd(_ cwd: String?) -> String {
        let home = NSHomeDirectory()
        guard let cwd else { return home }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return home }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") {
            let rest = String(trimmed.dropFirst(2))
            return (home as NSString).appendingPathComponent(rest)
        }
        // standardizingPath は /private/var → /var のように「/private」を落とす。grok は会話を作業フォルダの
        // パスそのものごとに保存するので、落とすと同じ会話を見つけられない。それ以外の整形（.. など）はする。
        let standardized = (trimmed as NSString).standardizingPath
        if trimmed.hasPrefix("/private/"), "/private" + standardized == trimmed { return trimmed }
        return standardized
    }

    private func handleAgentMessageChunk(update: [String: Any], sid: String) {
        guard let text = extractText(update["content"]) else { return }

        lock.lock()
        var transcriptFlush: (text: String, messageId: String)?
        if hadToolSinceLastMessage, let prev = currentMessageId {
            continuation.yield(.assistantTurnEnd(agentId: agentId, sessionId: sid, messageId: prev))
            currentMessageId = nil
            if !transcriptBubbleText.isEmpty {
                transcriptFlush = (transcriptBubbleText, prev)
                transcriptBubbleText = ""
            }
        }
        hadToolSinceLastMessage = false
        if currentMessageId == nil {
            currentMessageId = UUID().uuidString
        }
        let mid = currentMessageId!
        if transcriptDir != nil || tuning.recorder != nil {
            transcriptBubbleText += text
        }
        lock.unlock()

        if let flush = transcriptFlush {
            appendTranscript(role: "assistant", content: flush.text, messageId: flush.messageId)
        }
        continuation.yield(.assistantDelta(text, agentId: agentId, sessionId: sid, messageId: mid))
    }

    private func handleAgentThoughtChunk(update: [String: Any], sid: String) {
        guard let text = extractText(update["content"]) else { return }
        let mid: String
        lock.lock()
        mid = currentMessageId ?? "pending-thought"
        lock.unlock()
        continuation.yield(.activity(agentId: agentId, sessionId: sid, messageId: mid, text: text))
    }

    private func handleToolCall(update: [String: Any], sid: String) {
        let toolId = (update["toolCallId"] as? String) ?? UUID().uuidString
        let title = (update["title"] as? String) ?? ""
        let toolKind = (update["kind"] as? String) ?? "other"
        let toolName = Self.extractToolName(title: title, fallback: toolKind)

        lock.lock()
        hadToolSinceLastMessage = true
        toolStartTimes[toolId] = Date()
        toolNames[toolId] = toolName
        var transcriptFlush: (text: String, messageId: String)?
        if let prev = currentMessageId {
            continuation.yield(.assistantTurnEnd(agentId: agentId, sessionId: sid, messageId: prev))
            currentMessageId = nil
            if !transcriptBubbleText.isEmpty {
                transcriptFlush = (transcriptBubbleText, prev)
                transcriptBubbleText = ""
            }
        }
        lock.unlock()
        if let flush = transcriptFlush {
            appendTranscript(role: "assistant", content: flush.text, messageId: flush.messageId)
        }

        continuation.yield(.toolStart(
            agentId: agentId, sessionId: sid,
            toolUseId: toolId, toolName: toolName,
            title: title, kind: toolKind
        ))

        // サブエージェントへの委任（Task / delegate_task / sessions_spawn 等）はカードにも出す。
        // tool_call が completed / failed で来る agent（grok）は、ここで行も閉じる。
        // Grok の背景の spawn は、終わりの通知まで running のまま background の行にする。
        var background: Bool?
        if tuning.xaiNotifications, let spawn = AcpDelegationReceipt.grokBackgroundSpawn(update) {
            background = true
            lock.lock()
            grokSpawns.append(GrokSpawn(toolCallId: toolId, description: spawn.description, subagentId: nil))
            openDelegations.insert(toolId)
            lock.unlock()
        } else if tuning.xaiNotifications, let description = AcpDelegationReceipt.grokForegroundSpawnDescription(update) {
            lock.withLock { _ = foregroundSpawnDescriptions.insert(description) }
        }
        ingestSubagentUpdate(update, sid: sid, background: background)

        if let status = update["status"] as? String,
           status == "completed" || status == "failed" {
            let summary = extractToolSummary(update["content"])
            emitToolEnd(toolId: toolId, toolName: toolName, status: status, summary: summary, sid: sid)
        }
    }

    /// 委任の行（キーは toolCallId）。委任かどうか（title の「<tool>: …」は先頭の識別子にそろえる）、後の更新で届く
    /// 説明と種類の埋め直し（opencode acp は pending の tool_call では title も rawInput も空）、opencode の
    /// `<task …>` の出力の取り出しは SubagentTracker.ingestAcpUpdate に任せる。
    /// 非同期の委任（Hermes delegate_task・OpenClaw sessions_spawn・Grok task・opencode のバックグラウンドの task
    /// （state="running"））の本当の終わりは追わない（起動の呼び出しが戻った時点で閉じる。docs/BACKGROUND_WORK_2026-10-21.md §4）。
    private func ingestSubagentUpdate(_ update: [String: Any], sid: String, background: Bool? = nil) {
        lock.lock()
        let p = subagents.ingestAcpUpdate(update, background: background)
        lock.unlock()
        yieldSubagent(p, sid: sid)
    }

    private func yieldSubagent(_ payload: String?, sid: String) {
        guard let payload else { return }
        continuation.yield(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: payload))
    }

    /// 実行中の委任の行を閉じて流す。もう終わりの知らせが来ない（中断・猶予切れ・プロセスの死・close）。
    /// onlyForeground = true では、裏で動いていると分かっている行（background）を残す。
    private func abandonSubagents(state: String, onlyForeground: Bool, except: Set<String> = []) {
        lock.lock()
        let p = subagents.abandonRunning(state: state, onlyForeground: onlyForeground, except: except)
        lock.unlock()
        yieldSubagent(p, sid: sessionId)
    }

    /// サブエージェントのカードの全行（workflow_snapshot。行が無くても agents: []）。接続したときと
    /// turn_status_request のときに SessionHub が送る。
    func subagentSnapshot() async -> String? {
        lock.withLock { subagents.snapshot(includeEmpty: true) }
    }

    private func handleToolCallUpdate(update: [String: Any], sid: String) {
        let toolId = (update["toolCallId"] as? String) ?? ""
        guard !toolId.isEmpty else { return }
        let rawStatus = update["status"] as? String
        // 委任の行は終わりでない更新（in_progress の title / rawInput）も見る。status の無い更新では行を閉じない
        // （title・rawInput の埋め直しだけ）。tool の行は、status の無い更新を終わりとみなす agent（既定）だけ閉じる。
        // 非同期で始めた委任の受領票は、行を running のまま残す（tool の行は閉じる。起動の呼び出しは終わっている）。
        let receipt = delegationReceipt(update, toolId: toolId, status: rawStatus)
        ingestSubagentUpdate(update, sid: sid, background: receipt == nil ? nil : true)
        if let receipt { watchDelegation(receipt, toolId: toolId, update: update, sid: sid) }
        guard let status = rawStatus ?? (tuning.statuslessUpdateEndsTool ? "completed" : nil),
              status == "completed" || status == "failed" else { return }
        let summary = extractToolSummary(update["content"])
        lock.lock()
        let toolName = toolNames[toolId] ?? ""
        lock.unlock()
        emitToolEnd(toolId: toolId, toolName: toolName, status: status, summary: summary, sid: sid)
    }

    private func emitToolEnd(toolId: String, toolName: String, status: String, summary: String?, sid: String) {
        lock.lock()
        guard endedToolIds.insert(toolId).inserted else { lock.unlock(); return }
        let durationMs: Int? = toolStartTimes[toolId].map { Int(Date().timeIntervalSince($0) * 1000) }
        toolStartTimes.removeValue(forKey: toolId)
        toolNames.removeValue(forKey: toolId)
        lock.unlock()
        continuation.yield(.toolEnd(
            agentId: agentId, sessionId: sid,
            toolUseId: toolId, toolName: toolName,
            status: status, summary: summary, durationMs: durationMs
        ))
    }

    private func endCurrentBubbleIfAny() {
        lock.lock()
        let bubble = takeCurrentBubbleLocked()
        lock.unlock()
        emitBubbleEnd(bubble)
    }

    /// lock 保持中に呼ぶ。現在の bubble を取り出して streaming state をリセットする。
    /// done の判定と同じロック区間で取り出し、後続ターンの bubble を閉じないようにするため分けている。
    private func takeCurrentBubbleLocked() -> (messageId: String, text: String)? {
        let mid = currentMessageId
        currentMessageId = nil
        hadToolSinceLastMessage = false
        let transcriptText = transcriptBubbleText
        transcriptBubbleText = ""
        return mid.map { (messageId: $0, text: transcriptText) }
    }

    private func emitBubbleEnd(_ bubble: (messageId: String, text: String)?) {
        guard let bubble else { return }
        continuation.yield(.assistantTurnEnd(agentId: agentId, sessionId: sessionId, messageId: bubble.messageId))
        if !bubble.text.isEmpty {
            appendTranscript(role: "assistant", content: bubble.text, messageId: bubble.messageId)
        }
    }

    // MARK: - 非同期の委任の本当の終わり（docs/BACKGROUND_CONTROL_2026-10-21.md §5）

    private enum DelegationReceipt {
        case hermes(delegationId: String, count: Int?)
        case openclaw(runId: String)
        case grok(subagentId: String)
    }

    /// 委任ツールの tool_call_update（status completed）が、非同期で始めたことを示す受領票なら、その鍵。
    private func delegationReceipt(_ update: [String: Any], toolId: String, status: String?) -> DelegationReceipt? {
        guard status == "completed" else { return nil }
        switch tuning.delegationLedger {
        case .hermes:
            guard lock.withLock({ subagents.contains(toolId) }),
                  let r = AcpDelegationReceipt.hermes(update) else { return nil }
            return .hermes(delegationId: r.delegationId, count: r.count)
        case .openclaw:
            guard lock.withLock({ subagents.contains(toolId) }),
                  let runId = AcpDelegationReceipt.openclaw(update) else { return nil }
            return .openclaw(runId: runId)
        case .none:
            guard tuning.xaiNotifications, lock.withLock({ grokSpawns.contains { $0.toolCallId == toolId } }),
                  let id = AcpDelegationReceipt.grokSubagentId(SubagentTracker.acpText(update["content"])) else { return nil }
            return .grok(subagentId: id)
        }
    }

    /// 受領票の行を、終わりの知らせ（Grok）か台帳（Hermes / OpenClaw）に結ぶ。行は running のまま background になる。
    private func watchDelegation(_ receipt: DelegationReceipt, toolId: String, update: [String: Any], sid: String) {
        switch receipt {
        case .grok(let subagentId):
            lock.lock()
            if let i = grokSpawns.firstIndex(where: { $0.toolCallId == toolId }), grokSpawns[i].subagentId == nil {
                grokSpawns[i].subagentId = subagentId
            }
            lock.unlock()
        case .hermes(let delegationId, let count):
            if let count {
                lock.lock()
                let p = subagents.setTaskCount(key: toolId, count: count)
                lock.unlock()
                yieldSubagent(p, sid: sid)
            }
            addToWatcher(toolId: toolId, ledgerKey: delegationId, update: update)
        case .openclaw(let runId):
            addToWatcher(toolId: toolId, ledgerKey: runId, update: update)
        }
    }

    private func addToWatcher(toolId: String, ledgerKey: String, update: [String: Any]) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        openDelegations.insert(toolId)
        let watcher: AcpDelegationWatcher
        if let existing = delegationWatcher {
            watcher = existing
        } else {
            let reader: AcpLedgerReader
            let interval = tuning.delegationPollSeconds
            if tuning.delegationLedger == .hermes {
                reader = HermesLedger(path: tuning.delegationLedgerPath, pollInterval: interval ?? 2)
            } else {
                reader = OpenclawLedger(path: tuning.delegationLedgerPath, cli: tuning.delegationCli,
                                        databaseInterval: interval ?? 3, cliInterval: interval ?? 10)
            }
            watcher = AcpDelegationWatcher(reader: reader, failureLimit: tuning.delegationFailureLimit) { [weak self] changes in
                self?.applyLedgerChanges(changes)
            }
            delegationWatcher = watcher
        }
        lock.unlock()
        watcher.add(AcpDelegationWatcher.Entry(rowKey: toolId, ledgerKey: ledgerKey,
                                               receiptText: SubagentTracker.acpText(update["content"])))
    }

    private func applyLedgerChanges(_ changes: [AcpDelegationWatcher.Change]) {
        for change in changes {
            switch change {
            case .activity(let key, let text, let toolCalls):
                lock.lock()
                let p = subagents.activity(key: key, text: text, toolCalls: toolCalls)
                lock.unlock()
                yieldSubagent(p, sid: sessionId)
            case .finished(let key, let state, let result, let durationMs):
                settleDelegation(key: key, state: state, result: result, durationMs: durationMs, wakes: false)
            case .unreadable(let key, let receiptText):
                // 台帳が読めない。今まで通り、受領票の文を結果にして done で閉じる。
                settleDelegation(key: key, state: "done", result: receiptText, durationMs: nil, wakes: false)
            }
        }
    }

    /// 背景の委任の行を閉じる。それが最後の背景の委任の行で、起こされたターンも来ず（wakes == false）、実行中の
    /// session/prompt・知らせのターン・ターミナルのターンも無ければ、本文の無い知らせのターンの done を 1 つ出す
    /// （SessionHub が預かった push を出し、アプリが生成中を解く）。activity は出さない。
    private func settleDelegation(key: String, activity: (text: String?, toolCalls: Int?, tokens: Int?)? = nil,
                                  state: String, result: String?, durationMs: Int?, wakes: Bool) {
        lock.lock()
        var payloads: [String] = []
        if let activity,
           let p = subagents.activity(key: key, text: activity.text, toolCalls: activity.toolCalls, tokens: activity.tokens) {
            payloads.append(p)
        }
        let closedPayload = subagents.finish(key: key, state: state, result: result, durationMs: durationMs)
        if let closedPayload { payloads.append(closedPayload) }
        let last = closedPayload != nil && !wakes && !closed && !doneOwed && notificationTurn == nil && !remoteTurnActive
            && !openDelegations.contains { subagents.isRunning(key: $0) }
        lock.unlock()
        for p in payloads { yieldSubagent(p, sid: sessionId) }
        if last {
            continuation.yield(SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString)
                .addingMetadata(["origin": "task-notification", "silent": "1"]))
        }
    }

    private func watchedDelegationKeys() -> Set<String> {
        lock.withLock { delegationWatcher }?.watchedRowKeys ?? []
    }

    private func stopDelegationWatching() {
        lock.lock()
        let watcher = delegationWatcher
        delegationWatcher = nil
        lock.unlock()
        watcher?.stop()
    }

    // MARK: Grok（_x.ai/session_notification と知らせのターン）

    private static let notificationPromptPrefixes = ["subagent-completed-", "task-completed-"]

    static func isNotificationPrompt(_ promptId: String) -> Bool {
        notificationPromptPrefixes.contains { promptId.hasPrefix($0) }
    }

    private func handleXaiNotification(_ params: [String: Any]) {
        guard let update = params["update"] as? [String: Any], let kind = update["sessionUpdate"] as? String else { return }
        switch kind {
        case "subagent_spawned": grokSubagentSpawned(update)
        case "subagent_progress": grokSubagentProgress(update)
        case "subagent_finished": grokSubagentFinished(update)
        case "turn_completed": finishNotificationTurn(promptId: update["prompt_id"] as? String)
        default: break
        }
    }

    /// 通知の subagent_id に結んだ行。受領票より先に来るので、鍵の無い背景の spawn の行のうち description が一致する最も古い行
    /// （無ければ鍵の無い最も古い行）に結ぶ。lock を持って呼ぶ。
    private func grokRowKeyLocked(subagentId: String, description: String? = nil, bind: Bool = false) -> String? {
        if let spawn = grokSpawns.first(where: { $0.subagentId == subagentId }) { return spawn.toolCallId }
        guard bind else { return nil }
        let unbound = grokSpawns.indices.filter { grokSpawns[$0].subagentId == nil && subagents.isRunning(key: grokSpawns[$0].toolCallId) }
        var pick = unbound.first { description != nil && grokSpawns[$0].description == description }
        if pick == nil {
            // 前景の spawn の通知は、背景の行に結ばない。
            if let description, foregroundSpawnDescriptions.contains(description) { return nil }
            pick = unbound.first
        }
        guard let i = pick else { return nil }
        grokSpawns[i].subagentId = subagentId
        return grokSpawns[i].toolCallId
    }

    private func grokSubagentSpawned(_ update: [String: Any]) {
        guard let subagentId = update["subagent_id"] as? String, !subagentId.isEmpty else { return }
        lock.lock()
        let key = grokRowKeyLocked(subagentId: subagentId, description: update["description"] as? String, bind: true)
        if let key, let child = update["child_session_id"] as? String, !child.isEmpty { grokChildSessions[child] = key }
        let p = key.flatMap { k -> String? in
            guard subagents.isRunning(key: k) else { return nil }
            return subagents.begin(key: k, label: nil, agentType: update["subagent_type"] as? String,
                                   model: update["model"] as? String, background: true)
        }
        lock.unlock()
        yieldSubagent(p, sid: sessionId)
    }

    private func grokSubagentProgress(_ update: [String: Any]) {
        guard let subagentId = update["subagent_id"] as? String else { return }
        lock.lock()
        let p = grokRowKeyLocked(subagentId: subagentId).flatMap {
            subagents.activity(key: $0, text: (update["tools_used"] as? [Any])?.last as? String,
                               toolCalls: Self.int(update["tool_call_count"]), tokens: Self.int(update["tokens_used"]))
        }
        lock.unlock()
        yieldSubagent(p, sid: sessionId)
    }

    private func grokSubagentFinished(_ update: [String: Any]) {
        guard let subagentId = update["subagent_id"] as? String else { return }
        lock.lock()
        let key = grokRowKeyLocked(subagentId: subagentId)
        lock.unlock()
        // 前景の spawn（grokSpawns に無い）は tool_call_update の completed が閉じる。
        guard let key else { return }
        // completed → done、failed / error → failed、cancelled / killed / stopped / interrupted → stopped、ほか → failed。
        let state = SubagentTracker.finalState(update["status"] as? String ?? "") ?? "failed"
        settleDelegation(key: key,
                         activity: (text: nil, toolCalls: Self.int(update["tool_calls"]), tokens: Self.int(update["tokens_used"])),
                         state: state, result: update["output"] as? String, durationMs: Self.int(update["duration_ms"]),
                         wakes: update["will_wake"] as? Bool == true)
    }

    private static func int(_ any: Any?) -> Int? {
        (any as? NSNumber)?.intValue
    }

    /// 受領票が来ていない（subagent_id が結ばれていない）背景の spawn の行を stopped で閉じて取り除く。
    /// 承認待ちの間に止めて spawn が起きなかった行が、running のまま残らないようにする。
    private func closeUnboundGrokSpawns() {
        lock.lock()
        var payloads: [String] = []
        for spawn in grokSpawns where spawn.subagentId == nil {
            openDelegations.remove(spawn.toolCallId)
            if subagents.isRunning(key: spawn.toolCallId),
               let p = subagents.finish(key: spawn.toolCallId, state: "stopped", result: nil) { payloads.append(p) }
        }
        grokSpawns.removeAll { $0.subagentId == nil }
        lock.unlock()
        for p in payloads { yieldSubagent(p, sid: sessionId) }
    }

    private func resetGrokDelegations() {
        lock.lock()
        foregroundSpawnDescriptions.removeAll()
        grokSpawns.removeAll()
        grokChildSessions.removeAll()
        lock.unlock()
    }

    /// 親が子の完了で自分から始めたターンを開く（`_x.ai/queue/changed` の runningPromptId が subagent-completed- か
    /// task-completed- で始まり、初めて見る id）。runningText（`<system-reminder>…`）は発言にしない。
    /// 空の activity で、SessionHub とアプリに生成中を知らせる。
    private func openNotificationTurnIfNeeded(_ params: [String: Any]) {
        guard (params["runningKind"] as? String ?? "prompt") == "prompt",
              let promptId = params["runningPromptId"] as? String, Self.isNotificationPrompt(promptId) else { return }
        openNotificationTurn(promptId: promptId)
    }

    /// 知らせのターンを開く。初めて見る id だけ。別のターンが開いたままなら、先にそれを閉じる
    /// （2 つ続けて起こされたとき、前の turn_completed より先に次の通知が来ても落とさない）。開いたら true。
    @discardableResult
    private func openNotificationTurn(promptId: String) -> Bool {
        lock.lock()
        guard !closed, seenNotificationPromptIds.insert(promptId).inserted else { lock.unlock(); return false }
        let open = notificationTurn
        lock.unlock()
        if let open { closeNotificationTurn(silent: !open.hadBody) }
        lock.lock()
        guard !closed, notificationTurn == nil else { lock.unlock(); return false }
        let turn = NotificationTurn(promptId: promptId, messageId: UUID().uuidString)
        notificationTurn = turn
        lock.unlock()
        continuation.yield(.activity(agentId: agentId, sessionId: sessionId, messageId: turn.messageId, text: ""))
        return true
    }

    /// 知らせのターンの session/update（`params._meta.promptId` がそのターンのもの）。本文は新しい messageId の吹き出しにする。
    /// tool は今までどおりの経路で流す（止めたターンの残りを捨てている間も）。扱ったら true。
    private func routeNotificationTurnUpdate(kind: String, update: [String: Any], params: [String: Any], sid: String) -> Bool {
        let promptId = (params["_meta"] as? [String: Any])?["promptId"] as? String
        lock.lock()
        var isTurn = promptId != nil && notificationTurn?.promptId == promptId
        let cancelled = promptId.map { cancelledNotificationPromptIds.contains($0) } ?? false
        lock.unlock()
        if cancelled {
            // 下の停止で止めたターンの続き。tool の終わりだけ通し、本文・考え・新しい tool は捨てる。
            if kind == "tool_call_update" { handleToolCallUpdate(update: update, sid: sid) }
            return kind != "plan"
        }
        // queue/changed より先に更新が届いたら、ここで開く。
        if !isTurn, let promptId, Self.isNotificationPrompt(promptId), openNotificationTurn(promptId: promptId) {
            isTurn = true
        }
        guard isTurn else { return false }
        switch kind {
        case "agent_message_chunk":
            guard let text = extractText(update["content"]) else { return true }
            lock.lock()
            guard var turn = notificationTurn, turn.promptId == promptId else { lock.unlock(); return true }
            let bubbleId = turn.bubbleId ?? UUID().uuidString
            turn.bubbleId = bubbleId
            turn.hadBody = true
            turn.text += text
            notificationTurn = turn
            lock.unlock()
            continuation.yield(.assistantDelta(text, agentId: agentId, sessionId: sid, messageId: bubbleId))
            return true
        case "agent_thought_chunk":
            guard let text = extractText(update["content"]) else { return true }
            let mid = lock.withLock { notificationTurn?.bubbleId ?? notificationTurn?.messageId } ?? "pending-thought"
            continuation.yield(.activity(agentId: agentId, sessionId: sid, messageId: mid, text: text))
            return true
        case "tool_call":
            emitBubbleEnd(takeNotificationBubble())
            handleToolCall(update: update, sid: sid)
            return true
        case "tool_call_update":
            handleToolCallUpdate(update: update, sid: sid)
            return true
        default:
            return false
        }
    }

    private func takeNotificationBubble() -> (messageId: String, text: String)? {
        lock.lock(); defer { lock.unlock() }
        guard var turn = notificationTurn, let id = turn.bubbleId else { return nil }
        let text = turn.text
        turn.bubbleId = nil
        turn.text = ""
        notificationTurn = turn
        return (id, text)
    }

    /// `turn_completed`（prompt_id が一致したとき）で知らせのターンを閉じる。吹き出しを閉じて履歴に残し、done に
    /// origin = task-notification を付ける。本文が無ければ silent。
    private func finishNotificationTurn(promptId: String?) {
        lock.lock()
        guard let turn = notificationTurn else { lock.unlock(); return }
        // 別の知らせのターンの終わりが先に来たなら、開いたままのターンの終わりは来ない。保険として閉じる。
        let stale = turn.promptId != promptId && promptId.map { Self.isNotificationPrompt($0) && !seenNotificationPromptIds.contains($0) } == true
        if stale { seenNotificationPromptIds.insert(promptId!) }
        lock.unlock()
        guard turn.promptId == promptId || stale else { return }
        closeNotificationTurn(silent: !turn.hadBody)
    }

    /// 開いている知らせのターンを閉じる（無ければ何もしない）。プロセスの終了・close のときは silent で閉じる。
    private func closeNotificationTurn(silent: Bool = true) {
        let bubble = takeNotificationBubble()
        lock.lock()
        let had = notificationTurn != nil
        notificationTurn = nil
        lock.unlock()
        guard had else { return }
        emitBubbleEnd(bubble)
        var metadata = ["origin": "task-notification"]
        if silent { metadata["silent"] = "1" }
        continuation.yield(SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString)
            .addingMetadata(metadata))
    }

    // MARK: - transcript

    /// `<transcriptDir>/<sessionId>.jsonl` に 1 行 JSON でメッセージを追記する。
    /// sessionId が未確定 (pending) の間は書かない (bootstrap 前に send は来ないので実害なし)。
    private func appendTranscript(role: String, content: String, messageId: String) {
        guard !content.isEmpty else { return }
        let sid = sessionId
        guard !sid.isEmpty, !sid.hasPrefix("pending-") else { return }
        if let recorder = tuning.recorder {
            // 書き込みは到着順に 1 本ずつ（user → assistant の順が入れ替わらないように）。
            lock.lock()
            let previous = recordTail
            recordTail = Task { await previous?.value; await recorder(role, content, messageId, sid) }
            lock.unlock()
        }
        guard let dir = transcriptDir else { return }
        let path = dir + "/\(Self.sanitizeFileName(sid)).jsonl"
        let record: [String: Any] = [
            "role": role,
            "content": content,
            "messageId": messageId,
            "ts": Date().timeIntervalSince1970
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: record) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// sessionId をファイル名に安全な形へ ("/" などを除去)
    static func sanitizeFileName(_ raw: String) -> String {
        String(raw.map { c in
            c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." ? c : "_"
        })
    }

    private func yieldError(_ msg: String) {
        continuation.yield(SessionEvent(
            type: .error, agentId: agentId, sessionId: sessionId,
            messageId: UUID().uuidString, toolUseId: nil,
            content: msg, toolName: nil, metadata: nil
        ))
    }

    private func extractText(_ raw: Any?) -> String? {
        if let dict = raw as? [String: Any], let s = dict["text"] as? String {
            return s
        }
        if let arr = raw as? [[String: Any]] {
            let parts = arr.compactMap { $0["text"] as? String }
            if !parts.isEmpty { return parts.joined() }
        }
        return nil
    }

    private func extractToolSummary(_ raw: Any?) -> String? {
        var text: String? = nil
        if let arr = raw as? [[String: Any]] {
            for item in arr {
                if let inner = item["content"] as? [String: Any], let s = inner["text"] as? String {
                    text = (text ?? "") + s
                } else if let s = item["text"] as? String {
                    text = (text ?? "") + s
                }
            }
        } else if let dict = raw as? [String: Any] {
            text = dict["text"] as? String
        }
        guard let t = text else { return nil }
        if t.count > 400 {
            return String(t.prefix(400)) + "…"
        }
        return t
    }

    static func extractToolName(title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        // Hermes / OpenClaw の「<tool>: <preview>」。preview のバッククォートより先に、先頭の識別子をツール名にする
        // （「delegate_task:」のように記号を残すと、委任と認識できない）。
        let head = SubagentTracker.normalizedToolName(trimmed)
        if !head.isEmpty, trimmed.dropFirst(head.count).first == ":" { return head }
        if let r1 = trimmed.range(of: "`"), let r2 = trimmed.range(of: "`", range: r1.upperBound..<trimmed.endIndex) {
            let inner = String(trimmed[r1.upperBound..<r2.lowerBound])
            let firstWord = inner.split(separator: " ").first.map(String.init) ?? inner
            if !firstWord.isEmpty { return firstWord }
        }
        var s = trimmed
        while let first = s.unicodeScalars.first, !first.properties.isAlphabetic && first != "_" {
            s.removeFirst()
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if let firstWord = s.split(separator: " ").first {
            return SubagentTracker.normalizedToolName(String(firstWord))
        }
        return fallback
    }

    // MARK: - short-lived ACP probes (opencode history)

    /// live session を持たずに `session/list` を 1 回叩いて履歴一覧を取る。
    /// 既定の args / env は opencode 用（env には自分専用の XDG_CACHE_HOME を必ず渡す。OpenCodeAdapter.cacheHome）。
    static func listSessionsViaAcp(executable: String, cwd: String?,
                                   args: [String] = ["acp"],
                                   env: [String: String] = OpenCodeAdapter.cacheEnvironment,
                                   loginShell: Bool = true) async throws -> [SessionSummary] {
        // opencode の session/list は spawn cwd で project scope される。chat と同じ cwd で
        // spawn しないと別 project のセッションが返る（live session は session/new の
        // param.cwd で保存されるので、それに合わせた cwd でプローブする）。
        let resolvedCwd = normalizedCwd(cwd)
        let client = AcpClient(executable: executable, args: args, env: env, cwd: resolvedCwd, loginShell: loginShell)
        try client.start()
        defer { client.close() }
        _ = try await withTimeout(seconds: 60) {
            try await client.request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
                "clientInfo": ["name": "BuddyOS-Bridge", "version": "0.1"]
            ])
        }
        // session/list は params オブジェクト必須（no-params -> -32602）。空 {} を送る。
        let res = try await withTimeout(seconds: 30) {
            try await client.request("session/list", params: [:])
        }
        guard let result = res["result"] as? [String: Any],
              let sessions = result["sessions"] as? [[String: Any]] else {
            return []
        }
        var summaries: [SessionSummary] = []
        for s in sessions {
            guard let sid = s["sessionId"] as? String, !sid.isEmpty else { continue }
            let title = (s["title"] as? String) ?? sid
            let updated = (s["updatedAt"] as? String) ?? ""
            let sessionCwd = s["cwd"] as? String
            summaries.append(SessionSummary(
                sessionId: sid,
                title: title,
                lastActive: updated,
                messageCount: nil,
                cwd: sessionCwd
            ))
        }
        // 新しい順（updatedAt ISO 文字列の降順）。
        summaries.sort { $0.lastActive > $1.lastActive }
        return summaries
    }

    /// live session を持たずに `session/load` を 1 回叩いて履歴トランスクリプトを取る。
    /// replay で流れてくる user_message_chunk / agent_message_chunk を
    /// 同一ロールの連続を 1 メッセージに畳んで返す。既定の args / env は opencode 用。
    static func loadHistoryViaAcp(executable: String, cwd: String?, sessionId: String,
                                  args: [String] = ["acp"],
                                  env: [String: String] = OpenCodeAdapter.cacheEnvironment,
                                  loginShell: Bool = true) async throws -> [HistoryMessage] {
        let resolvedCwd = normalizedCwd(cwd)
        // session/load は sessionId 指定なので project scope に依存しないが、cwd を spawn にも
        // 揃えておくことで session/load の param.cwd と整合させる（list と同じ方針）。
        let client = AcpClient(executable: executable, args: args, env: env, cwd: resolvedCwd, loginShell: loginShell)

        // replay 通知を集める collector。session/load の result が返る前に流れてくる。
        let collector = HistoryCollector()
        try client.start()
        defer { client.close() }
        let consumeTask = Task.detached {
            for await msg in client.notifications {
                collector.ingest(msg)
            }
        }
        defer { consumeTask.cancel() }

        _ = try await withTimeout(seconds: 60) {
            try await client.request("initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
                "clientInfo": ["name": "BuddyOS-Bridge", "version": "0.1"]
            ])
        }
        _ = try await withTimeout(seconds: 60) {
            try await client.request("session/load", params: [
                "sessionId": sessionId,
                "cwd": resolvedCwd,
                "mcpServers": []
            ])
        }
        // replay 通知は result の前後で前後するため、result 後に少し待って取りこぼしを防ぐ。
        try? await Task.sleep(nanoseconds: 300_000_000)
        return collector.snapshot()
    }
}

/// session/load replay の user_message_chunk / agent_message_chunk を時系列で集めて
/// 同一ロールの連続を 1 メッセージに畳む collector。スレッドセーフ。
private final class HistoryCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [HistoryMessage] = []
    private var lastRole: String?
    private var buffer: String = ""
    private var bufferAttachments: [HistoryAttachment] = []

    func ingest(_ msg: [String: Any]) {
        guard (msg["method"] as? String) == "session/update",
              let params = msg["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else { return }
        let kind = (update["sessionUpdate"] as? String) ?? ""
        let role: String
        switch kind {
        case "user_message_chunk":  role = "user"
        case "agent_message_chunk": role = "assistant"
        default: return
        }
        let text = Self.extractText(update["content"])
        let images = Self.extractImages(update["content"])
        guard text != nil || !images.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if lastRole != nil && lastRole != role {
            flushLocked()
        }
        lastRole = role
        if let text { buffer += text }
        bufferAttachments.append(contentsOf: images)
    }

    func snapshot() -> [HistoryMessage] {
        lock.lock(); defer { lock.unlock() }
        flushLocked()
        return messages
    }

    private func flushLocked() {
        guard let role = lastRole, !buffer.isEmpty || !bufferAttachments.isEmpty else {
            buffer = ""; bufferAttachments = []; lastRole = nil; return
        }
        messages.append(HistoryMessage(
            role: role, content: buffer, messageId: UUID().uuidString, attachments: bufferAttachments
        ))
        buffer = ""
        bufferAttachments = []
        lastRole = nil
    }

    private static func extractText(_ raw: Any?) -> String? {
        if let dict = raw as? [String: Any], let s = dict["text"] as? String { return s }
        if let arr = raw as? [[String: Any]] {
            let parts = arr.compactMap { $0["text"] as? String }
            if !parts.isEmpty { return parts.joined() }
        }
        if let s = raw as? String { return s }
        return nil
    }

    /// ACP content block の image variant ({type:"image", data:<b64>, mimeType:...}) を拾う。
    private static func extractImages(_ raw: Any?) -> [HistoryAttachment] {
        func toAttachment(_ d: [String: Any]) -> HistoryAttachment? {
            guard (d["type"] as? String) == "image",
                  let b64 = d["data"] as? String, !b64.isEmpty else { return nil }
            let mime = (d["mimeType"] as? String) ?? "image/png"
            return HistoryAttachment(kind: "image", name: "image", mime: mime, b64: b64)
        }
        if let dict = raw as? [String: Any], let a = toAttachment(dict) { return [a] }
        if let arr = raw as? [[String: Any]] { return arr.compactMap(toAttachment) }
        return []
    }
}

/// 指定秒数で TimeoutError を投げる helper
///
/// operation は非構造化 Task で走らせ、先に決着した方（結果 / タイムアウト / 呼び出し元のキャンセル）で
/// 即座に戻る。TaskGroup で競わせると throw 後も group が子の完了を待つため、キャンセルに反応しない
/// AcpClient.request（withCheckedThrowingContinuation）が無応答だと、タイムアウトしても永久に戻らなかった。
/// 取り残された request は、呼び出し側の catch / defer の client.close() で processTerminated になって片付く。
func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            race.install(cont)
            let op = Task {
                do {
                    let value = try await operation()
                    race.finish(.success(value))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                race.finish(.failure(AcpError.startTimeout))
            }
            race.onFinish {
                op.cancel()
                timer.cancel()
            }
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// withTimeout 用: continuation を 1 回だけ resume し、決着後に残りの Task を片付ける。スレッドセーフ。
private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var cleanup: (() -> Void)?
    private var finished = false

    func install(_ c: CheckedContinuation<T, Error>) {
        lock.lock()
        // 呼び出し元が既にキャンセル済みだと onCancel が install より先に走る → 保留した結果で即 resume。
        if let pendingResult {
            lock.unlock()
            c.resume(with: pendingResult)
            return
        }
        continuation = c
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        if c == nil { pendingResult = result }
        let done = cleanup
        cleanup = nil
        lock.unlock()
        c?.resume(with: result)
        done?()
    }

    func onFinish(_ f: @escaping () -> Void) {
        lock.lock()
        if finished { lock.unlock(); f(); return }
        cleanup = f
        lock.unlock()
    }
}
