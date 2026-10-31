import Foundation
import Security

/// mainagent（窓口のエージェント）が、Bridge の持つほかのセッションを操作するための中身。
/// 口は `POST /mcp`（McpEndpoint）で、道具の実体はここにある。
///
/// - 合鍵: mainagent のセッションを開くたびに使い捨ての合鍵を発行し、`/mcp` はこれだけを受け付ける
///   （中継からも届く口なので api-key は使わない）。親のセッションが閉じたら無効。
/// - 子: 頼んだセッションは SessionHub を通して購読する（iPhone からも同じセッションが見える）。
///   自分の送信は queue_dispatched の clientMessageId で見分け、そこから done までを 1 ターンとして集める。
actor Orchestrator {
    static let shared = Orchestrator()

    /// 返事を受け取った後も、続けて頼めるように子を開いたままにしておく時間。過ぎたら購読を外す
    /// （ほかに誰も見ていなければ hub が閉じる。次に送るときは resume で開き直す）。
    var idleReleaseSeconds: TimeInterval = 10 * 60
    /// 結果待ち（子のバックグラウンドの作業の結論を待つ）のターンで、作業が全部終わってから知らせのターンを待つ猶予
    /// （cron の backgroundSettleGrace と同じ 120 秒）。過ぎても始まらなければ（子が終わっても親が起きない CLI）done にする。
    var backgroundSettleSeconds: TimeInterval = 120
    /// テスト用: backgroundSettleSeconds を変える。
    func setBackgroundSettleSecondsForTesting(_ seconds: TimeInterval) { backgroundSettleSeconds = seconds }
    /// 結果待ちのまま出来事が無い時間の上限（hub の backgroundIdleTimeout と同じ 6 時間。終わりの知らせを取りこぼした行で
    /// 永久に待たない）。
    static let backgroundWaitMaxSeconds: TimeInterval = 6 * 60 * 60
    /// error だけで終わり done が来ないターンを、error 扱いにするまでの猶予（hub の settleErroredTurn と同じ考え方）。
    static let erroredTurnSettleSeconds: TimeInterval = 6
    static let maxReplyChars = 6000

    // MARK: - 保存（Bridge を再起動しても、頼んだ相手と最後の返事を忘れない）

    static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".buddyos/mainagent-tracks.json")
    }

    private var storeURL: URL?
    private var saveTask: Task<Void, Never>?

    private struct StoredTurn: Codable {
        let clientMessageId: String
        let prompt: String
        let state: String
        let sentAt: Date
        let startedAt: Date?
        let finishedAt: Date?
        let lastBubble: String
        let full: String
        let errorText: String?
        /// 別の PC の端末から頼まれたターン（"device:<deviceKeyId>"）。その端末だけが get_reply / answer_approval で触れる。
        var requestedBy: String?
    }

    private struct StoredTrack: Codable {
        let agentId: String
        let sessionId: String
        let aliases: [String]
        let cwd: String?
        let confirmed: Bool
        let childMode: String?
        let touchedAt: Date
        let turns: [StoredTurn]
        // 子のカード（workflow_progress kind = "sessions"）用。前の版のファイルには無い。
        var parentAgentId: String?
        var parentSessionId: String?
        var cardIndex: Int?
        var createdAt: Date?
        var project: String?
        var agentName: String?
        /// 子の深さ。開き直しでも同じ深さの合鍵にする。
        var depth: Int?
    }

    /// 保存先を決め、前回の分を読み込む。作業中だったターンは、再起動で止まったものとして error にする。
    /// 読み込んだ子のカードは hub に預け直す（mainagent のチャットを開き直したときに出せるように）。
    func enablePersistence(at url: URL) {
        storeURL = url
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredTrack].self, from: data) else { return }
        for s in stored where !tracks.contains(where: { $0.agentId == s.agentId && $0.aliases.contains(s.sessionId) }) {
            let t = Track(agentId: s.agentId, sessionId: s.sessionId, cwd: s.cwd, confirmed: s.confirmed)
            t.aliases = Set(s.aliases)
            t.childMode = s.childMode
            t.touchedAt = s.touchedAt
            t.parentAgentId = s.parentAgentId
            t.parentSessionId = s.parentSessionId
            t.cardIndex = s.cardIndex ?? 0
            t.createdAt = s.createdAt ?? s.touchedAt
            t.project = s.project
            t.agentName = s.agentName
            t.depth = s.depth
            t.turns = s.turns.map { st in
                var turn = Turn(clientMessageId: st.clientMessageId, prompt: st.prompt, sentAt: st.sentAt)
                turn.state = TurnState(rawValue: st.state) ?? .error
                turn.startedAt = st.startedAt
                turn.finishedAt = st.finishedAt
                turn.lastBubble = st.lastBubble
                turn.full = st.full
                turn.errorText = st.errorText
                turn.requestedBy = st.requestedBy
                if turn.state == .queued || turn.state == .running {
                    turn.state = .error
                    turn.finishedAt = turn.finishedAt ?? Date()
                    turn.errorText = "Bridge が再起動したので、このターンは途中で止まった。続きは send_message で頼み直す"
                }
                return turn
            }
            tracks.append(t)
        }
        trimTracks()
        var parents = Set<String>()
        for t in tracks {
            guard let pa = t.parentAgentId, let ps = t.parentSessionId, parents.insert("\(pa):\(ps)").inserted else { continue }
            t.cardSignature = cardSignature(t)
            publishCard(parentAgentId: pa, parentSessionId: ps)
        }
    }

    /// 出来事のたびに呼ばれるので、まとめて 1 秒後に書く。
    private func scheduleSave() {
        guard storeURL != nil, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.saveNow()
        }
    }

    func saveNow() {
        saveTask = nil
        guard let url = storeURL else { return }
        // 別の PC の子（remoteBridgeId あり）は保存しない（別の PC の一覧もメモリだけ）。
        let stored = tracks.filter { !$0.sessionId.isEmpty && $0.remoteBridgeId == nil }.map { t in
            StoredTrack(agentId: t.agentId, sessionId: t.sessionId, aliases: Array(t.aliases), cwd: t.cwd,
                        confirmed: t.confirmed, childMode: t.childMode, touchedAt: t.touchedAt,
                        turns: t.turns.map { turn in
                            StoredTurn(clientMessageId: turn.clientMessageId, prompt: turn.prompt, state: turn.state.rawValue,
                                       sentAt: turn.sentAt, startedAt: turn.startedAt, finishedAt: turn.finishedAt,
                                       lastBubble: Self.tail(turn.lastBubble, Self.maxReplyChars),
                                       full: Self.tail(turn.full, Self.maxReplyChars), errorText: turn.errorText,
                                       requestedBy: turn.requestedBy)
                        },
                        parentAgentId: t.parentAgentId, parentSessionId: t.parentSessionId,
                        cardIndex: t.cardIndex, createdAt: t.createdAt, project: t.project, agentName: t.agentName,
                        depth: t.depth)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // 頼んだ文と返事が入るので、本人だけが読めるようにする。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - 合鍵

    struct Caller: Sendable {
        let token: String
        let agentId: String
        let parentSessionId: String?
        /// 合鍵の深さ（利用者が開いたセッションは 0。子は呼んだ側の深さ + 1）。
        var depth: Int = 0
        /// 別の PC から `/device/orchestrator` で頼まれたとき（B 側）。承認カードは出さない（A で承認済み）。
        var remote: RemoteCaller? = nil
        /// mainagent のフォルダのセッションの合鍵か（ふつうのセッションは false）。save_note はこれだけが使える。
        var isMain: Bool = true
        /// アプリ内ターミナルの claude（`.mcp.json` の中継、ターミナル用の合鍵）からの呼び出し。
        /// 送る・起こすの承認はターミナルの claude 自身の確認に任せ、Bridge の承認カードは出さない。
        var terminal: Bool = false

        /// B 側で、どの端末から頼まれたターンかの印（Turn.requestedBy）。
        var requester: String? { remote.map { "device:\($0.deviceKeyId)" } }
    }

    /// 別の PC（A）の Bridge から、A のデスクトップの端末の資格情報（bdc_）で頼まれた。
    struct RemoteCaller: Sendable {
        let deviceKeyId: String
        /// A の呼んだ側のチャットのモード（上限）の段。無ければ段 1（毎回尋ねる）。
        let capMode: Int
        /// A の PC（ログと表示用）。
        let bridgeId: String?
        let name: String?
    }

    /// 合鍵を渡せる深さの上限。子（深さ 1）は孫に頼めるが、孫（深さ 2）にはもう渡さない。
    static let maxDepth = 2

    /// adapter がセッションを開くときに受け取るもの。isMain なら mainagent の決まり（書く道具を外す・Codex は読むだけ・
    /// 権限モードは default）を足す。ふつうのセッションは MCP だけを足す。
    struct SessionGrant: Sendable {
        let token: String
        let isMain: Bool
        let depth: Int
    }

    private final class Grant {
        let agentId: String
        /// mainagent のフォルダのセッションか（ふつうのセッションは false）。
        var isMain = true
        var depth = 0
        /// 合鍵を渡した mainagent のセッション。確定前の ID（pending）から確定 ID に変わるので、毎回ここから読む。
        weak var session: AgentSession?
        var bound = false
        var parentSessionId: String?
        /// mainagent のチャットで選んだ権限モード。子のセッションはこれより強くしない（nil = 既定の上限）。
        var chatMode: String?
        /// 「このセッションでは承認」を選んだら、以後の送る・起こすは尋ねない。
        var autoApprove = false
        init(agentId: String, parentSessionId: String?) {
            self.agentId = agentId
            self.parentSessionId = parentSessionId
        }
        var currentParentSessionId: String? { session?.sessionId ?? parentSessionId }
    }

    private var grants: [String: Grant] = [:]

    /// セッションを開くときに、合鍵と MCP を渡すかを決める。
    /// - 無人実行（cron）には渡さない。ただし定期チェック（heartbeat）の会話は、mainagent のフォルダなら無人でも渡す。
    /// - mainagent のフォルダなら今までどおり渡す（深さ 0）。
    /// - それ以外は設定 allSessions が有効なときだけ。深さは Orchestrator が子を開くときの値（無ければ 0）で、
    ///   上限（maxDepth）に届いたら渡さない。
    func sessionGrant(agentId: String, sessionId: String?, cwd: String?, unattended: Bool,
                      heartbeat: Bool = false, depth explicit: Int? = nil) -> SessionGrant? {
        guard !unattended || (heartbeat && MainAgentWorkspace.isMainWorkspace(cwd)) else { return nil }
        if MainAgentWorkspace.isMainWorkspace(cwd) {
            return SessionGrant(token: issueToken(agentId: agentId, parentSessionId: sessionId), isMain: true, depth: 0)
        }
        guard OrchestratorSettings.allSessions else { return nil }
        let depth = max(0, explicit ?? OrchestratorContext.openingDepth ?? 0)
        guard depth < Self.maxDepth else { return nil }
        let token = issueToken(agentId: agentId, parentSessionId: sessionId, isMain: false, depth: depth)
        return SessionGrant(token: token, isMain: false, depth: depth)
    }

    func issueToken(agentId: String, parentSessionId: String?, isMain: Bool = true, depth: Int = 0) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = "bmt_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let g = Grant(agentId: agentId, parentSessionId: parentSessionId)
        g.isMain = isMain
        g.depth = depth
        grants[token] = g
        return token
    }

    /// 合鍵を mainagent のセッションに結びつける。セッションが無くなったら合鍵も使えなくなる（閉じ忘れの保険）。
    func bind(token: String, session: AgentSession) {
        guard let g = grants[token] else { return }
        g.session = session
        g.bound = true
    }

    func setParentSessionId(token: String, sessionId: String) {
        grants[token]?.parentSessionId = sessionId
    }

    func revoke(token: String) {
        grants.removeValue(forKey: token)
        for (id, p) in pendingApprovals where p.token == token {
            pendingApprovals.removeValue(forKey: id)
            p.continuation.resume(returning: "deny")
        }
    }

    func caller(token: String, claudePid: Int32? = nil) async -> Caller? {
        if let terminalToken = currentTerminalToken(), Self.constantTimeEquals(token, terminalToken) {
            return await terminalCaller(terminalToken: terminalToken, claudePid: claudePid)
        }
        guard let g = grants[token] else { return nil }
        if g.bound, g.session == nil {
            grants.removeValue(forKey: token)
            return nil
        }
        return Caller(token: token, agentId: g.agentId, parentSessionId: g.currentParentSessionId, depth: g.depth,
                      isMain: g.isMain)
    }

    // MARK: - ターミナルの mainagent

    private var terminalTokenCache: (token: String, modified: Date?)?

    /// ターミナル用の合鍵（`~/.buddyos/main-mcp-token`）。ファイルの更新時刻が変わったら読み直す。
    private func currentTerminalToken() -> String? {
        let url = MainAgentWorkspace.terminalTokenURL
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let c = terminalTokenCache, c.modified == modified { return c.token }
        guard let t = MainAgentWorkspace.terminalToken(url: url) else {
            terminalTokenCache = nil
            return nil
        }
        terminalTokenCache = (t, modified)
        return t
    }

    /// ターミナルの claude ごと（PID ごと）の Grant を持つ。キーには合鍵を含める（Bearer に PID だけ書いても通らない）。
    /// 呼んだ側のセッションは、ターミナルの台帳で PID（と 2 代上まで）から引く。引けなければ未確定のまま動く。
    private func terminalCaller(terminalToken: String, claudePid: Int32?) async -> Caller {
        let pid = claudePid ?? 0
        let sid = pid > 0 ? await ClaudeTerminalRegistry.shared.sessionId(forPid: pid) : nil
        let key = "\(terminalToken)#\(pid)"
        let g: Grant
        if let existing = grants[key] {
            g = existing
        } else {
            g = Grant(agentId: "claude", parentSessionId: sid)
            grants[key] = g
        }
        if let sid { g.parentSessionId = sid }
        return Caller(token: key, agentId: g.agentId, parentSessionId: g.currentParentSessionId, depth: 0,
                      isMain: true, terminal: true)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// チャットで権限モードが選ばれた（iPhone の送信ごとに届く。nil = 既定に戻した）。
    /// 合鍵を持つセッション（mainagent・ふつうのセッション）なら、それが子の上限になる。
    /// どのセッションでも覚える（既にあるセッションへ送るとき、相手のモードを確かめるため）。
    func noteChatMode(agentId: String, sessionId: String, mode: String?) {
        for g in grants.values where g.agentId == agentId && g.currentParentSessionId == sessionId {
            g.chatMode = mode
        }
        sessionModes["\(agentId):\(sessionId)"] = mode
    }

    // MARK: - 承認（送る・起こすの前に、mainagent の画面へ承認カードを出す）

    /// エージェントの種類に依らず Bridge が尋ねる（Claude の承認確認に頼らない）。
    static let approvalTimeoutSeconds: TimeInterval = 5 * 60

    private struct PendingApproval {
        let token: String
        let agentId: String
        let sessionId: String
        let continuation: CheckedContinuation<String, Never>
    }

    private var pendingApprovals: [String: PendingApproval] = [:]

    /// iPhone の action_response が mainagent の承認への返事なら受け取って true。
    func resolveApproval(requestId: String, decision: String) -> Bool {
        guard let p = pendingApprovals.removeValue(forKey: requestId) else { return false }
        p.continuation.resume(returning: decision)
        return true
    }

    /// - honorAutoApprove: false なら「このセッションでは承認」を選んでいても尋ねる（子の承認に答えるとき、上限が低い場合）。
    /// - offerSessionOption: false ならカードに「このセッションでは承認」を出さない。
    private func requireApproval(_ caller: Caller, title: String, subtitle: String,
                                 honorAutoApprove: Bool = true, offerSessionOption: Bool = true) async throws {
        // 別の PC から頼まれた（B 側）。頼んだ PC（A）が、呼んだ側のチャットで承認を取ってから送ってくる。
        if caller.remote != nil { return }
        // ターミナルの claude: 道具を使う前に claude 自身が利用者に確かめる（Bridge のカードは見ている人がいない）。
        if caller.terminal { return }
        guard let g = grants[caller.token] else { throw ToolError("合鍵が無効") }
        if g.autoApprove, honorAutoApprove { return }
        guard let parentSid = caller.parentSessionId else { throw ToolError("承認を出せない（mainagent のセッションが未確定）") }
        let requestId = "mainagent-\(UUID().uuidString)"
        var meta: [String: String] = ["requestId": requestId, "kind": "approval", "allowsOther": "0"]
        var options = [("承認", "一度だけ許可", "allow")]
        if offerSessionOption { options.append(("このセッションでは承認", "以後の依頼は尋ねない", "allowForSession")) }
        options.append(("非承認", "頼まない", "deny"))
        meta["option_count"] = String(options.count)
        for (i, o) in options.enumerated() {
            meta["option_\(i)_title"] = o.0
            meta["option_\(i)_subtitle"] = o.1
            meta["option_\(i)_value"] = o.2
        }
        let card = SessionEvent.actionRequest(agentId: caller.agentId, sessionId: parentSid, messageId: requestId,
                                              title: title, subtitle: subtitle, metadata: meta)
        let token = caller.token
        let decision: String = await withCheckedContinuation { c in
            pendingApprovals[requestId] = PendingApproval(token: token, agentId: caller.agentId, sessionId: parentSid, continuation: c)
            Task {
                await SessionHub.shared.emitExternal(agentId: caller.agentId, sessionId: parentSid, event: card)
                try? await Task.sleep(nanoseconds: UInt64(Self.approvalTimeoutSeconds * 1_000_000_000))
                _ = await self.resolveApproval(requestId: requestId, decision: "timeout")
            }
        }
        await SessionHub.shared.emitExternal(
            agentId: caller.agentId, sessionId: parentSid,
            event: .actionResolved(agentId: caller.agentId, sessionId: parentSid, requestId: requestId))
        switch decision {
        case "allow":
            return
        case "allowForSession" where offerSessionOption:
            grants[token]?.autoApprove = true
        case "timeout":
            throw ToolError("ユーザーの承認が \(Int(Self.approvalTimeoutSeconds / 60)) 分以内に無かった。頼むならもう一度呼ぶ")
        default:
            throw ToolError("ユーザーが承認しなかった")
        }
    }

    // MARK: - 子の権限モード（親より強くしない）

    /// 権限の強さ。T3 Code の runtimeMode の 4 段（approval-required / auto-accept-edits / auto / full-access）の
    /// 下に「計画（読むだけ）」を足した 5 段。モードの名前は agent ごとに意味が違う（claude の auto は毎回尋ねる、
    /// codex の auto は作業フォルダに尋ねずに書く）ので、名前ではなくこの段で比べる。
    static let strengthNames = ["計画（読むだけ）", "毎回尋ねる", "編集は尋ねない", "作業フォルダの中は尋ねない", "全権"]

    /// その agent でのモード名の強さ。知らない名前は nil。
    static func strength(of mode: String, agentId: String) -> Int? {
        switch mode {
        case "plan": return 0
        case "ask": return 1                               // codex: workspace-write ＋ on-request（毎回尋ねる）
        case "auto": return agentId == "codex" ? 3 : 1   // codex: workspace-write ＋ never / ほか: CLI 既定の承認
        case "edit": return 2                              // acceptEdits / accept-edits
        case "build": return 3                             // opencode の build は既定で書く・実行するを尋ねない
        case "dangerous": return 4
        default: return nil
        }
    }

    /// codex の実際の設定（sandbox と approval）の強さ。
    static func codexStrength(sandbox: String?, approval: String?) -> Int? {
        switch sandbox {
        case "read-only": return 0
        case "danger-full-access": return 4
        case "workspace-write": return approval == "never" ? 3 : 1
        default: return nil
        }
    }

    /// mainagent のチャットでモードを選んでいないときの上限（毎回尋ねる）。
    static let defaultCeiling = 1

    /// 子に使わせるモード。要求（無ければ上限）を上限以下に抑え、その agent が持つモードのうち、
    /// それ以下で一番強いものを選ぶ。agent がモードを持たなければ nil（その agent の設定のまま）。
    /// 上限以下のモードを持たなければ断る（強い既定のまま動かさない）。
    static func childMode(requested: String?, agentId: String, supported: [String], ceiling: Int) throws -> String? {
        let options = supported.compactMap { m in strength(of: m, agentId: agentId).map { (m, $0) } }
        guard !options.isEmpty else { return nil }
        let want = min(requested.flatMap { strength(of: $0, agentId: agentId) } ?? ceiling, ceiling)
        guard let pick = options.filter({ $0.1 <= want }).max(by: { $0.1 < $1.1 }) else {
            throw ToolError("\(agentId) には「\(strengthNames[max(0, want)])」以下のモードが無いので起こせない（上限: \(strengthNames[ceiling])）")
        }
        return pick.0
    }

    /// 呼んだ側の子への上限。チャットで選んだモードを、呼んだ側の agent での意味で測る（mainagent でも、ふつうのセッションでも）。
    /// 別の PC から頼まれたときは、A が送ってきた段（capMode）。
    func ceiling(_ caller: Caller) -> Int {
        if let r = caller.remote { return min(max(r.capMode, 0), Self.strengthNames.count - 1) }
        guard let g = grants[caller.token], let mode = g.chatMode else { return Self.defaultCeiling }
        return Self.strength(of: mode, agentId: g.agentId) ?? Self.defaultCeiling
    }

    // MARK: - 深さと鎖

    /// 呼んだ側の深さ。合鍵の深さに加え、呼んだ側のセッションが今だれかに頼まれた仕事をしている（その子として作業中）なら、
    /// その鎖での深さも見る（利用者が開いた深さ 0 のセッションに頼んでも、鎖が 2 を超えないように）。
    func effectiveDepth(_ caller: Caller) -> Int {
        if caller.remote != nil { return max(0, caller.depth) }
        var d = caller.depth
        if let sid = caller.parentSessionId, let t = track(agentId: caller.agentId, sessionId: sid), t.busy {
            d = max(d, t.depth ?? 1)
        }
        return d
    }

    /// 頼む（起こす・送る）前に、子の深さが上限を超えないか確かめる。
    private func checkDepth(_ caller: Caller) throws -> Int {
        let child = effectiveDepth(caller) + 1
        guard child <= Self.maxDepth else {
            throw ToolError(code: "depth", "頼めるのは \(Self.maxDepth) 段まで（このセッションは既にほかのエージェントから頼まれた仕事の \(child - 1) 段目）。"
                            + "これ以上は頼まず、自分で答えるか、頼んだ側に返す")
        }
        return child
    }

    /// 呼んだ側と、その祖先（今作業中の鎖で、頼んできたセッションをたどったもの）。自分を含む。
    private func chain(of caller: Caller) -> Set<String> {
        guard caller.remote == nil, let sid = caller.parentSessionId else { return [] }
        var out: Set<String> = ["\(caller.agentId):\(sid)"]
        var cur = track(agentId: caller.agentId, sessionId: sid)
        while let t = cur, t.busy, let pa = t.parentAgentId, let ps = t.parentSessionId, out.count < 16 {
            guard out.insert("\(pa):\(ps)").inserted else { break }
            cur = track(agentId: pa, sessionId: ps)
        }
        return out
    }

    /// 自分自身・自分の祖先への send_message は断る（頼み合いが輪になって止まらなくなるため）。
    private func checkCycle(_ caller: Caller, agentId: String, sessionId: String) throws {
        let links = chain(of: caller)
        let aliases = track(agentId: agentId, sessionId: sessionId)?.aliases ?? [sessionId]
        if aliases.contains(where: { links.contains("\(agentId):\($0)") }) {
            throw ToolError(code: "cycle", "そのセッションは、このセッションに仕事を頼んだ側（同じ鎖の中）なので送れない。頼まれた仕事の答えは、返事として返す")
        }
    }

    /// B 側で、A から自分自身（同じ Bridge）へ回ってきた依頼は断る。
    private func checkRemoteSelf(_ caller: Caller) throws {
        if let id = caller.remote?.bridgeId, id == KeyStore.loadOrCreateBridgeId() {
            throw ToolError(code: "self", "自分の PC からの依頼は、別の PC として受け付けない")
        }
    }

    /// iPhone のチャットや mainagent が選んだ、セッションごとのモード（"agentId:sessionId" → モード名）。
    private var sessionModes: [String: String] = [:]

    /// 開いているセッションの今の強さ。チャットで選んだモード、無ければその agent の既定の設定。分からなければ nil。
    private func currentStrength(agentId: String, sessionId: String) -> Int? {
        if let mode = sessionModes["\(agentId):\(sessionId)"] ?? track(agentId: agentId, sessionId: sessionId)?.childMode {
            return Self.strength(of: mode, agentId: agentId)
        }
        switch agentId {
        case "claude":
            return ClaudeCodeAdapter.readMode().flatMap { Self.strength(of: $0, agentId: agentId) }
        case "codex":
            let c = CodexConfigStore()
            return Self.codexStrength(sandbox: c.currentSandboxMode() ?? "workspace-write",
                                      approval: c.currentApprovalPolicy() ?? "on-request")
        default:
            return nil
        }
    }

    /// 既にあるセッションへ送る前に、相手のモードが上限を超えていないか確かめる（T3 と同じく、超えていれば送らない）。
    private func checkTargetMode(_ caller: Caller, agentId: String, sessionId: String) throws -> Int? {
        let cap = ceiling(caller)
        guard let now = currentStrength(agentId: agentId, sessionId: sessionId) else { return nil }
        if now > cap {
            throw ToolError("相手のセッションは「\(Self.strengthNames[now])」で動いていて、mainagent の上限「\(Self.strengthNames[cap])」より強いので送らない。"
                            + "相手のチャットでモードを下げるか、mainagent のチャットのモードを上げてからもう一度呼ぶ")
        }
        return now
    }

    // MARK: - 子のセッション

    enum TurnState: String { case queued, running, done, error }

    /// 子のターンで回答を待っている承認・質問（子の action_request）。
    struct Approval {
        let requestId: String
        let title: String
        /// 何を許すのか（action_request の subtitle。コマンドやファイル名など）。
        var summary: String?
        var kind: String?
        /// カードの選択肢（value は子の respondToAction に渡す値）。
        var options: [(value: String, title: String)] = []
        /// mainagent が answer_approval で答えられるか（質問・ターミナルへの発話の保留などは答えない）。
        var answerable = false
        var receivedAt = Date()

        /// answer_approval の decision ごとに、子のどの選択肢を選ぶか。
        var choices: [(choice: ApprovalChoice, value: String)] {
            var out: [(ApprovalChoice, String)] = []
            for c in ApprovalChoice.allCases {
                if let o = options.first(where: { Orchestrator.approvalChoice(value: $0.value, title: $0.title) == c }) {
                    out.append((c, o.value))
                }
            }
            return out
        }
    }

    /// answer_approval で選べる答え（子の選択肢の名前は agent ごとに違うので、この 3 つにそろえる）。
    enum ApprovalChoice: String, CaseIterable {
        case allow
        case allowForSession = "allow_for_session"
        case deny
    }

    /// 子のカードの選択肢 1 つが、どの答えにあたるか。分からなければ nil（選ばせない）。
    /// claude: allow / allowForSession / deny、codex: accept / acceptForSession / decline、
    /// opencode: once / always / reject、ACP: optionId（allow_once / allow_always / reject_once / proceed_always など）。
    static func approvalChoice(value: String, title: String) -> ApprovalChoice? {
        func classify(_ raw: String) -> ApprovalChoice? {
            let v = raw.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            if ["deny", "denied", "decline", "reject", "cancel", "abort", "no"].contains(where: { v.hasPrefix($0) || v.contains("_\($0)") }) {
                return .deny
            }
            if v.contains("always") || v.contains("forsession") || v.contains("for_session") || v.contains("session") {
                return .allowForSession
            }
            if ["allow", "accept", "approve", "proceed", "once", "yes"].contains(where: { v.hasPrefix($0) }) {
                return .allow
            }
            return nil
        }
        return classify(value) ?? classify(title)
    }

    struct Turn {
        let clientMessageId: String
        let prompt: String
        var state: TurnState = .queued
        var sentAt = Date()
        var startedAt: Date?
        var finishedAt: Date?
        var lastEventAt = Date()
        var currentMessageId: String?
        var bubbleClosed = false
        var lastBubble = ""
        var full = ""
        /// 回答待ちの承認・質問（届いた順）。並べて出す agent があるので複数持つ。
        var approvals: [Approval] = []
        var errorText: String?
        /// 別の PC の端末から頼まれたターン（Caller.requester）。nil はこの PC の中から頼んだもの。
        var requestedBy: String?
        /// 頼んだ発話のターンは done になったが、子のバックグラウンドの作業（サブエージェント・workflow）がまだ動いている。
        /// 結論は後の知らせのターンで届くので、それまで done にしない（返事はそのターンの本文。cron の TurnCollector と同じ）。
        var awaitingBackground = false
        /// awaitingBackground の間に、子のターン（知らせのターン）が動き出した（作業が無くなった後の猶予では終わらせない）。
        var wakeStarted = false
    }

    final class Track {
        let id = UUID()
        let agentId: String
        var sessionId: String
        var aliases: Set<String>
        var cwd: String?
        var confirmed: Bool
        var subscriberId: UUID?
        var session: AgentSession?
        var continuation: AsyncStream<SessionEvent>.Continuation?
        var consumer: Task<Void, Never>?
        var releaseTask: Task<Void, Never>?
        var turns: [Turn] = []
        var touchedAt = Date()
        /// start_session で渡したモード（送り直すときの確認に使う。iPhone で変えればそちらが優先）。
        var childMode: String?
        /// 最後に頼んだ mainagent のセッション。子のカード（workflow_progress kind = "sessions"）はここへ出す。
        var parentAgentId: String?
        var parentSessionId: String?
        /// カードの行番号（agents[].index）。同じ mainagent のチャットの中で重ならない。
        var cardIndex = 0
        var createdAt = Date()
        var project: String?
        var agentName: String?
        /// 最後にカードへ出した行（updatedAtMs を除く）。変わったときだけ出し直す。
        var cardSignature: String?
        var cardUpdatedAt = Date()
        /// 子の深さ（呼んだ側の深さ + 1）。開き直すときも同じ深さの合鍵にする。
        var depth: Int?
        /// 別の PC の子（A 側）。購読はせず、B から受けた結果（start_session / send_message / get_reply）で行を作る。
        var remoteBridgeId: String?
        var remotePcName: String?
        /// 子の workflow_progress のカード（サブエージェント・dynamic workflow）の写し。ターンの外でも重ね、頼んだ発話の
        /// done の時点でバックグラウンドの作業が動いているか（返事を待ち続けるか）の判断に使う。
        var cards = WorkflowCardMirror()
        /// 結果待ちのターンで作業が無くなってから、知らせのターンを待つ猶予（過ぎたら done にする）。
        var backgroundSettle: Task<Void, Never>?

        init(agentId: String, sessionId: String, cwd: String?, confirmed: Bool) {
            self.agentId = agentId
            self.sessionId = sessionId
            self.aliases = [sessionId]
            self.cwd = cwd
            self.confirmed = confirmed
        }

        var busy: Bool { turns.contains { $0.state == .queued || $0.state == .running } }
    }

    private var tracks: [Track] = []
    private static let maxTracks = 50
    private static let maxTurnsPerTrack = 5

    /// この PC の子。別の PC の子は remoteTrack で引く。
    private func track(agentId: String, sessionId: String) -> Track? {
        tracks.first { $0.remoteBridgeId == nil && $0.agentId == agentId && $0.aliases.contains(sessionId) }
    }

    private func remoteTrack(bridgeId: String, agentId: String, sessionId: String) -> Track? {
        tracks.first { $0.remoteBridgeId == bridgeId && $0.agentId == agentId && $0.aliases.contains(sessionId) }
    }

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        /// 別の PC へ返すときの種類（`/device/orchestrator` の error）。`unknown_pc` / `pc_unreachable` / `depth` / `cycle` など。
        var code = "tool_error"
        init(_ d: String) { description = d }
        /// 種類を文の頭にも付ける（エージェントが見分けられるように）。
        init(code: String, _ d: String) {
            self.code = code
            description = "\(code): \(d)"
        }
        /// 別の PC が返した失敗を、そのまま伝える。
        init(passing message: String, code: String) {
            self.code = code
            description = message
        }
    }

    // MARK: - 道具

    func listProjects() -> [[String: Any]] {
        ProjectRegistry.list()
            .filter { !MainAgentWorkspace.isMainWorkspace($0.path) }
            .map { ["name": $0.name, "path": $0.path] }
    }

    func listAgents() async -> [[String: Any]] {
        var out: [[String: Any]] = []
        for d in await AgentRegistry.shared.descriptors() where d.capabilities.chat && d.id != "echo" {
            let p = await AgentProbe.shared.probe(id: d.id)
            out.append([
                "agent": d.id, "name": d.displayName,
                "installed": p.installed, "configured": p.configured
            ])
        }
        return out
    }

    func listSessions(caller: Caller) async -> [[String: Any]] {
        let projects = ProjectRegistry.list()
        let live = await SessionHub.shared.snapshot()
        let terminal = await ClaudeTerminalRegistry.shared.liveEntries()
        let terminalGenerating = await ClaudeTerminalRegistry.shared.generatingSessionIds()
        let terminalCwd = Dictionary(terminal.map { ($0.sessionId, $0.cwd) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [[String: Any]] = []

        func row(agent: String, sid: String, cwd: String?, state: String, source: String) -> [String: Any] {
            var r: [String: Any] = ["agent": agent, "session_id": sid, "state": state, "source": source]
            if let cwd {
                r["cwd"] = cwd
                if let p = projects.first(where: { ProjectRegistry.normalize($0.path) == ProjectRegistry.normalize(cwd) }) {
                    r["project"] = p.name
                }
            }
            if let t = track(agentId: agent, sessionId: sid), let last = t.turns.last {
                r["last_request"] = String(last.prompt.prefix(120))
                r["last_request_state"] = Self.status(of: last)
                if last.state == .running, !last.approvals.isEmpty {
                    r["pending_approvals"] = last.approvals.map { Self.approvalInfo($0) }
                }
            }
            return r
        }

        for info in live {
            let cwd = info.cwd ?? track(agentId: info.agentId, sessionId: info.sessionId)?.cwd
                ?? (info.agentId == "claude" ? terminalCwd[info.sessionId] ?? nil : nil)
            if isSelf(caller, agentId: info.agentId, sessionId: info.sessionId) || MainAgentWorkspace.isMainWorkspace(cwd) { continue }
            seen.insert("\(info.agentId):\(info.sessionId)")
            var r = row(agent: info.agentId, sid: info.sessionId, cwd: cwd,
                        state: info.generating ? "working" : "idle",
                        source: terminalCwd.keys.contains(info.sessionId) ? "terminal" : "bridge")
            if info.queued > 0 { r["queued"] = info.queued }
            out.append(r)
        }
        for t in terminal where !seen.contains("claude:\(t.sessionId)") {
            if isSelf(caller, agentId: "claude", sessionId: t.sessionId) || MainAgentWorkspace.isMainWorkspace(t.cwd) { continue }
            seen.insert("claude:\(t.sessionId)")
            out.append(row(agent: "claude", sid: t.sessionId, cwd: t.cwd,
                           state: terminalGenerating.contains(t.sessionId) ? "working" : "idle", source: "terminal"))
        }
        // 頼んだことがあり、今は閉じているもの（send_message で開き直せる）。
        for t in tracks where t.remoteBridgeId == nil && !t.aliases.contains(where: { seen.contains("\(t.agentId):\($0)") }) {
            out.append(row(agent: t.agentId, sid: t.sessionId, cwd: t.cwd, state: "closed", source: "mainagent"))
        }
        return out
    }

    func startSession(caller: Caller, agentId: String, cwd: String, prompt: String,
                      mode: String? = nil, waitSeconds: Double = 0) async throws -> [String: Any] {
        let dir = ProjectRegistry.normalize((cwd as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard !dir.isEmpty, FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("cwd が見つからない: \(cwd)")
        }
        guard !MainAgentWorkspace.isMainWorkspace(dir) else {
            throw ToolError("mainagent のフォルダではセッションを起こせない")
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("prompt が空") }
        try checkRemoteSelf(caller)
        let childDepth = try checkDepth(caller)
        let adapter = try await chatAdapter(agentId)
        if let mode, Self.strength(of: mode, agentId: agentId) == nil {
            throw ToolError("知らない mode: \(mode)（plan / edit / auto / dangerous）")
        }
        let childMode = try Self.childMode(requested: mode, agentId: agentId,
                                           supported: AgentRegistry.capabilities(of: adapter).modes,
                                           ceiling: ceiling(caller))
        let project = ProjectRegistry.list().first { ProjectRegistry.normalize($0.path) == dir }?.name
            ?? (dir as NSString).lastPathComponent
        try await requireApproval(
            caller,
            title: "\(project) で \(adapter.displayName) を起こして頼みますか？",
            subtitle: Self.approvalSubtitle(prompt: text, mode: childMode))

        let track = Track(agentId: agentId, sessionId: "", cwd: dir, confirmed: false)
        track.depth = childDepth
        let session = await subscribe(track, adapter: adapter, sessionId: nil)
        // iPhone のチャットでモードを選ぶのと同じ経路で渡す（承認は今までどおり iPhone に尋ねる）。
        if let childMode { (session as? SessionOverridable)?.applyOverrides(SessionOverrides(mode: childMode)) }
        track.childMode = childMode
        track.sessionId = session.sessionId
        track.aliases.insert(session.sessionId)
        track.project = project
        track.agentName = adapter.displayName
        tracks.append(track)
        attach(track, to: caller)
        trimTracks()
        try await submit(track, text: text, requestedBy: caller.requester)

        // 確定した ID を返したいので、sessionStarted を少し待つ（返事そのものは get_reply で待つ）。
        let deadline = Date().addingTimeInterval(30)
        while !track.confirmed, Date() < deadline, track.turns.last?.state != .error, track.turns.last?.state != .done {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        var out: [String: Any] = [
            "agent": agentId, "session_id": track.sessionId, "cwd": dir,
            "state": track.turns.last?.state.rawValue ?? "queued",
            "confirmed": track.confirmed,
            "mode": childMode ?? "（このエージェントの設定のまま）"
        ]
        return await withReply(out: &out, caller: caller, agentId: agentId, sessionId: track.sessionId, waitSeconds: waitSeconds)
    }

    func sendMessage(caller: Caller, agentId: String, sessionId: String, text raw: String,
                     waitSeconds: Double = 0) async throws -> [String: Any] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError("text が空") }
        guard !isSelf(caller, agentId: agentId, sessionId: sessionId) else { throw ToolError("自分自身には送れない") }
        try checkRemoteSelf(caller)
        try checkCycle(caller, agentId: agentId, sessionId: sessionId)
        let childDepth = try checkDepth(caller)
        let adapter = try await chatAdapter(agentId)
        let existing = track(agentId: agentId, sessionId: sessionId)
        let liveCwd = await SessionHub.shared.snapshot()
            .first { $0.agentId == agentId && $0.sessionId == sessionId }?.cwd
        if MainAgentWorkspace.isMainWorkspace(liveCwd ?? existing?.cwd) {
            throw ToolError("mainagent のセッションには送れない")
        }
        let where_ = (liveCwd ?? existing?.cwd).map { ProjectRegistry.normalize($0) }
        let project = where_.flatMap { cwd in ProjectRegistry.list().first { ProjectRegistry.normalize($0.path) == cwd }?.name }
            ?? where_.map { ($0 as NSString).lastPathComponent } ?? sessionId.prefix(8).description
        let level = try checkTargetMode(caller, agentId: agentId, sessionId: sessionId)
        try await requireApproval(
            caller,
            title: "\(project) の \(adapter.displayName) に送りますか？",
            subtitle: Self.approvalSubtitle(prompt: text, mode: level.map { Self.strengthNames[$0] } ?? "不明"))
        // 承認を待つ間に相手のモードが上がっていないか、送る直前にもう一度確かめる。
        _ = try checkTargetMode(caller, agentId: agentId, sessionId: sessionId)
        let track = existing ?? {
            let t = Track(agentId: agentId, sessionId: sessionId, cwd: liveCwd, confirmed: true)
            tracks.append(t)
            trimTracks()
            return t
        }()
        if track.cwd == nil { track.cwd = liveCwd }
        if where_ != nil { track.project = project }
        track.agentName = adapter.displayName
        track.depth = childDepth
        attach(track, to: caller)
        if let s = track.session, let sub = track.subscriberId, await SessionHub.shared.holds(subscriberId: sub, session: s) {
            // 購読中のまま使う。
        } else {
            await unsubscribe(track)
            _ = await subscribe(track, adapter: adapter, sessionId: track.sessionId)
        }
        try await submit(track, text: text, requestedBy: caller.requester)
        var out: [String: Any] = [
            "agent": agentId, "session_id": track.sessionId,
            "state": track.turns.last?.state.rawValue ?? "queued"
        ]
        return await withReply(out: &out, caller: caller, agentId: agentId, sessionId: track.sessionId, waitSeconds: waitSeconds)
    }

    /// wait_seconds があれば、その間返事を待って結果に足す。
    private func withReply(out: inout [String: Any], caller: Caller, agentId: String, sessionId: String,
                           waitSeconds: Double) async -> [String: Any] {
        guard waitSeconds > 0 else {
            out["next"] = "get_reply で返事を待つ"
            return out
        }
        let reply = await getReply(caller: caller, agentId: agentId, sessionId: sessionId, waitSeconds: waitSeconds)
        for (k, v) in reply where out[k] == nil || k == "session_id" { out[k] = v }
        out.removeValue(forKey: "state")
        return out
    }

    private static func approvalSubtitle(prompt: String, mode: String?) -> String {
        let body = prompt.count > 400 ? String(prompt.prefix(400)) + "…" : prompt
        return mode.map { "モード: \($0)\n\(body)" } ?? body
    }

    /// 道具の口（/mcp・/device/orchestrator）から呼ぶ get_reply。別の PC の端末は、その端末から頼んだターンだけ見られる。
    func getReplyChecked(caller: Caller, agentId: String, sessionId: String, waitSeconds: Double) async throws -> [String: Any] {
        if let req = caller.requester {
            guard let t = track(agentId: agentId, sessionId: sessionId), t.turns.contains(where: { $0.requestedBy == req }) else {
                throw ToolError(code: "not_requested", "そのセッションに、この PC から頼んだターンが無い")
            }
        }
        return await getReply(caller: caller, agentId: agentId, sessionId: sessionId, waitSeconds: waitSeconds)
    }

    func getReply(caller: Caller, agentId: String, sessionId: String, waitSeconds: Double) async -> [String: Any] {
        let wait = max(0, min(waitSeconds, 300))
        let deadline = Date().addingTimeInterval(wait)
        while true {
            guard let track = track(agentId: agentId, sessionId: sessionId), !track.turns.isEmpty else {
                return await untrackedStatus(agentId: agentId, sessionId: sessionId)
            }
            // 別の PC の端末には、その端末から頼んだ最後のターンを見せる。
            let mine = caller.requester.flatMap { req in track.turns.lastIndex { $0.requestedBy == req } }
            let idx = mine ?? track.turns.count - 1
            settleIfErrored(track, index: idx)
            settleIfBackgroundStale(track, index: idx)
            let turn = track.turns[idx]
            let status = Self.status(of: turn)
            if status != "running" && status != "queued" || Date() >= deadline {
                return describe(track, turn: turn, status: status)
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// 子のセッションの承認に、mainagent が代わりに答える。
    /// - 答えられるのは、mainagent が頼んだターンで待っている承認だけ（get_reply / list_sessions の request_id）。
    ///   質問（userInput）や、ターミナルへの発話の保留は答えない。
    /// - deny はいつでも答えられる（ユーザーにも尋ねない）。
    /// - allow は上限が「毎回尋ねる」以上、allow_for_session は「編集は尋ねない」以上のときだけ。
    ///   相手のセッションのモードが上限より強ければ答えない（send_message と同じ）。
    /// - 許可するときは、Bridge が mainagent の画面に承認カードを出す。「このセッションでは承認」を選んでいても、
    ///   上限が「作業フォルダの中は尋ねない」より低ければ毎回尋ねる（「毎回尋ねる」の上限で、尋ねずに許可させない）。
    func answerApproval(caller: Caller, agentId: String, sessionId: String, requestId: String,
                        decision raw: String) async throws -> [String: Any] {
        guard let choice = ApprovalChoice(rawValue: raw) else {
            throw ToolError("decision は allow / allow_for_session / deny のどれか")
        }
        guard !isSelf(caller, agentId: agentId, sessionId: sessionId) else { throw ToolError("自分自身の承認には答えられない") }
        func pending() throws -> (Track, Approval) {
            let req = caller.requester
            guard let t = self.track(agentId: agentId, sessionId: sessionId),
                  let turn = t.turns.last(where: { $0.state == .running && (req == nil || $0.requestedBy == req) }),
                  let a = turn.approvals.first(where: { $0.requestId == requestId }) else {
                throw ToolError("その承認は待っていない（もう答えられたか、mainagent が頼んだターンではない）。get_reply で今の承認を見る")
            }
            return (t, a)
        }
        let (track, approval) = try pending()
        guard approval.answerable else {
            throw ToolError("この確認（\(approval.kind ?? "不明")）には mainagent から答えられない。ユーザーにこのセッションを BuddyOS で開いて答えてもらう")
        }
        guard let value = approval.choices.first(where: { $0.choice == choice })?.value else {
            let can = approval.choices.map(\.choice.rawValue).joined(separator: " / ")
            throw ToolError("この承認には \(choice.rawValue) にあたる選択肢が無い（選べるもの: \(can.isEmpty ? "なし" : can)）")
        }
        if choice != .deny {
            let cap = ceiling(caller)
            guard cap >= 1 else {
                throw ToolError("mainagent の上限が「\(Self.strengthNames[cap])」なので、子の承認に許可で答えられない。"
                                + "ユーザーにこのセッションを開いて答えてもらうか、mainagent のチャットのモードを上げてもらう")
            }
            if choice == .allowForSession, cap < 2 {
                throw ToolError("「このセッションでは許可」は、mainagent の上限が「編集は尋ねない」以上のときだけ使える（今は「\(Self.strengthNames[cap])」）。"
                                + "allow で一度だけ許可する")
            }
            let level = try checkTargetMode(caller, agentId: agentId, sessionId: sessionId)
            let name = track.agentName ?? agentId
            let place = track.project ?? track.cwd.map { ($0 as NSString).lastPathComponent } ?? String(sessionId.prefix(8))
            var lines = ["答え: \(choice == .allow ? "一度だけ許可" : "このセッションでは許可")",
                         "モード: \(level.map { Self.strengthNames[$0] } ?? "不明")",
                         "確認: \(approval.title)"]
            if let s = approval.summary, !s.isEmpty { lines.append(s.count > 400 ? String(s.prefix(400)) + "…" : s) }
            try await requireApproval(
                caller,
                title: "\(place) の \(name) の承認に、mainagent が許可で答えますか？",
                subtitle: lines.joined(separator: "\n"),
                honorAutoApprove: cap >= 3, offerSessionOption: cap >= 3)
            // カードを出している間に、別の端末で答えられた・相手のモードが上がったことがある。
            _ = try checkTargetMode(caller, agentId: agentId, sessionId: sessionId)
            _ = try pending()
        }
        guard let session = track.session else {
            throw ToolError("セッションが閉じていて答えられない。ユーザーにこのセッションを開いてもらう")
        }
        for i in track.turns.indices { track.turns[i].approvals.removeAll { $0.requestId == requestId } }
        await session.respondToAction(requestId: requestId, decision: value, answers: [:])
        // 子のチャットを見ている iPhone のカードも閉じる（答えたことを知らせない adapter がある）。
        await SessionHub.shared.emitExternal(agentId: track.agentId, sessionId: track.sessionId,
                                            event: .actionResolved(agentId: track.agentId, sessionId: track.sessionId, requestId: requestId))
        publishIfChanged(track)
        scheduleSave()
        WebSocketServer.wslog("mainagent.answer agent=\(agentId) session=\(sessionId.prefix(8)) decision=\(choice.rawValue)")
        return [
            "agent": agentId, "session_id": track.sessionId, "request_id": requestId,
            "answered": choice.rawValue,
            "next": "get_reply で続きを待つ"
        ]
    }

    // MARK: - 中身

    /// 子の承認 1 件を、mainagent に見せる形にする（get_reply / list_sessions）。
    static func approvalInfo(_ a: Approval) -> [String: Any] {
        var r: [String: Any] = ["request_id": a.requestId, "title": a.title]
        if let s = a.summary, !s.isEmpty { r["summary"] = s.count > 600 ? String(s.prefix(600)) + "…" : s }
        if let k = a.kind { r["kind"] = k }
        if a.answerable {
            r["choices"] = a.choices.map(\.choice.rawValue)
            r["hint"] = "answer_approval で答えられる（許可はユーザーの承認が要る）。何を許すのか分からなければユーザーに聞く"
        } else {
            r["hint"] = "mainagent からは答えられない。このセッションを BuddyOS で開いて答えてもらう"
        }
        return r
    }

    /// 頼んだ mainagent のチャットを覚える（子のカードはそこへ出す）。別の mainagent から頼まれたら移す。
    private func attach(_ track: Track, to caller: Caller) {
        guard let parentSid = caller.parentSessionId else { return }
        if track.parentAgentId == caller.agentId, track.parentSessionId == parentSid { return }
        let old = track.parentAgentId.flatMap { a in track.parentSessionId.map { (a, $0) } }
        track.parentAgentId = caller.agentId
        track.parentSessionId = parentSid
        track.cardIndex = (tracks.filter { $0 !== track && $0.parentAgentId == caller.agentId && $0.parentSessionId == parentSid }
            .map(\.cardIndex).max() ?? -1) + 1
        track.cardSignature = nil
        if let old { publishCard(parentAgentId: old.0, parentSessionId: old.1) }
    }

    private func isSelf(_ caller: Caller, agentId: String, sessionId: String) -> Bool {
        guard let parent = caller.parentSessionId else { return false }
        return agentId == caller.agentId && sessionId == parent
    }

    private func chatAdapter(_ agentId: String) async throws -> AgentAdapter {
        guard let adapter = await AgentRegistry.shared.adapter(for: agentId) else {
            throw ToolError("知らないエージェント: \(agentId)（list_agents で確かめる）")
        }
        guard AgentRegistry.capabilities(of: adapter).chat else { throw ToolError("\(agentId) はチャットできない") }
        return adapter
    }

    /// hub を購読する。届いた出来事は順番どおりに ingest へ流す。
    private func subscribe(_ track: Track, adapter: AgentAdapter, sessionId: String?) async -> AgentSession {
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let subId = UUID()
        track.subscriberId = subId
        track.continuation = continuation
        let trackId = track.id
        track.consumer = Task { [weak self] in
            for await event in stream {
                await self?.ingest(trackId: trackId, event: event)
            }
        }
        let agentId = track.agentId
        let cwd = track.cwd
        // 開くのが新しいプロセスなら、adapter はこの深さで合鍵を発行する（深さ 2 なら渡さない）。
        let session = await OrchestratorContext.$openingDepth.withValue(track.depth ?? 1) {
            await SessionHub.shared.acquire(
                agentId: agentId, sessionId: sessionId, cwd: cwd, adapter: adapter,
                subscriberId: subId, send: { continuation.yield($0) }, options: SessionOptions())
        }
        track.session = session
        return session
    }

    private func unsubscribe(_ track: Track) async {
        track.releaseTask?.cancel()
        track.releaseTask = nil
        if let sub = track.subscriberId { await SessionHub.shared.release(subscriberId: sub) }
        track.subscriberId = nil
        track.session = nil
        track.continuation?.finish()
        track.continuation = nil
        track.consumer = nil
    }

    private func submit(_ track: Track, text: String, requestedBy: String? = nil) async throws {
        guard let session = track.session else { throw ToolError("セッションを開けなかった") }
        track.releaseTask?.cancel()
        track.releaseTask = nil
        track.touchedAt = Date()
        let cmid = "mainagent-\(UUID().uuidString)"
        var turn = Turn(clientMessageId: cmid, prompt: text)
        turn.requestedBy = requestedBy
        track.turns.append(turn)
        if track.turns.count > Self.maxTurnsPerTrack { track.turns.removeFirst(track.turns.count - Self.maxTurnsPerTrack) }
        switch await SessionHub.shared.submitExternal(
            agentId: track.agentId, sessionId: session.sessionId, clientMessageId: cmid, content: text) {
        case .sendNow:
            Task { await WebSocketServer.dispatch(session, content: text, skills: [], attachments: [], voice: nil) }
        case .queued:
            break
        case .missing:
            track.turns.removeLast()
            throw ToolError("セッションが閉じていた。もう一度送る")
        }
        publishIfChanged(track)
        scheduleSave()
        WebSocketServer.wslog("mainagent.submit agent=\(track.agentId) session=\(session.sessionId.prefix(8)) chars=\(text.count)")
    }

    private func ingest(trackId: UUID, event: SessionEvent) {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return }
        defer { scheduleSave() }
        if event.type == .sessionStarted, let sid = event.sessionId, !sid.isEmpty {
            track.aliases.insert(sid)
            track.sessionId = sid
            track.confirmed = true
            publishIfChanged(track)
            return
        }
        if event.type == .queueDispatched, let cmid = event.metadata?["clientMessageId"] ?? event.messageId,
           let i = track.turns.firstIndex(where: { $0.clientMessageId == cmid && $0.state == .queued }) {
            // 前のターンが結果待ちのまま、次に頼んだ発話が始まった。前のターンは今の返事で done にする
            // （以後の出来事は新しいターンのもの）。
            for j in track.turns.indices where j != i && track.turns[j].state == .running && track.turns[j].awaitingBackground {
                finishTurn(track, index: j)
            }
            track.turns[i].state = .running
            track.turns[i].startedAt = Date()
            track.turns[i].lastEventAt = Date()
            publishIfChanged(track)
            return
        }
        // 子のバックグラウンドの作業の行は、ターンの外でも写しに重ねる（頼んだ発話の done で、結論を待ち続けるかの判断に使う）。
        if event.type == .workflowProgress {
            track.cards.apply(event.content)
            if let i = track.turns.lastIndex(where: { $0.state == .running && $0.awaitingBackground }) {
                track.turns[i].lastEventAt = Date()
            }
            watchBackground(track)
            return
        }
        // 自分の送信が始まるまでの出来事（購読直後のスナップショット・前のターンの残り）は見ない。
        guard let i = track.turns.lastIndex(where: { $0.state == .running }) else { return }
        track.turns[i].lastEventAt = Date()
        switch event.type {
        case .activity, .toolStart:
            // 結果待ちの間に子のターン（知らせのターン）が動き出した。作業が無くなった後の猶予では終わらせない。
            if track.turns[i].awaitingBackground { track.turns[i].wakeStarted = true }
        case .assistantDelta:
            if track.turns[i].awaitingBackground { track.turns[i].wakeStarted = true }
            let chunk = event.content ?? ""
            if track.turns[i].bubbleClosed || event.messageId != track.turns[i].currentMessageId {
                if !track.turns[i].lastBubble.isEmpty { track.turns[i].full += "\n\n" }
                track.turns[i].lastBubble = ""
                track.turns[i].bubbleClosed = false
                track.turns[i].currentMessageId = event.messageId
            }
            track.turns[i].lastBubble += chunk
            track.turns[i].full += chunk
        case .assistantTurnEnd:
            track.turns[i].bubbleClosed = true
        case .actionRequest:
            let a = Self.approval(from: event)
            track.turns[i].approvals.removeAll { $0.requestId == a.requestId }
            track.turns[i].approvals.append(a)
            publishIfChanged(track)
        case .actionResolved:
            track.turns[i].approvals.removeAll { $0.requestId == event.messageId }
            publishIfChanged(track)
        case .error:
            track.turns[i].errorText = event.content ?? "error"
        case .done:
            // 結果待ち（頼んだ発話のターンは終わり、子のバックグラウンドの作業の結論を待っている）の間に閉じたターン
            // （知らせのターン）。その本文が返事（吹き出しは続けて積んである。前の本文は earlier になる）。作業がまだ
            // 残っていれば待ち続ける。
            if track.turns[i].awaitingBackground {
                track.turns[i].wakeStarted = false
                if track.cards.counts.agentsOrWorkflows {
                    watchBackground(track)
                    publishIfChanged(track)
                } else {
                    finishTurn(track, index: i)
                }
                break
            }
            // 知らせのターン（バックグラウンドの作業が終わり、子が自分から始めたターン。metadata.origin =
            // "task-notification"）の done は、頼んだ発話の返事ではない。頼んだ発話は子の待ち行列に残っていて、その返事と
            // done は後から来る（頼んだ発話のターンが始まった後に、知らせのターンだけが閉じることは無い）。
            // それまでにこのターンへ積んだ本文・承認・エラーは知らせのターンのものなので捨てて、待ち続ける。
            if event.metadata?["origin"] == "task-notification" {
                track.turns[i].full = ""
                track.turns[i].lastBubble = ""
                track.turns[i].currentMessageId = nil
                track.turns[i].bubbleClosed = false
                track.turns[i].approvals.removeAll()
                track.turns[i].errorText = nil
                publishIfChanged(track)
                break
            }
            // 子がバックグラウンドで作業を続けている（Claude の既定のバックグラウンドのサブエージェントなど）。起動の返事で
            // 終わりにせず、知らせのターンの結論を待つ（待つ間は購読も外さない）。シェルだけなら待たない（dev サーバーは終わらない）。
            if track.cards.counts.agentsOrWorkflows {
                track.turns[i].awaitingBackground = true
                track.turns[i].wakeStarted = false
                track.turns[i].approvals.removeAll()
                publishIfChanged(track)
                break
            }
            finishTurn(track, index: i)
        default:
            break
        }
    }

    /// 頼んだ発話のターンを done にする（結果待ちの猶予も外す）。
    private func finishTurn(_ track: Track, index i: Int) {
        track.backgroundSettle?.cancel()
        track.backgroundSettle = nil
        track.turns[i].awaitingBackground = false
        track.turns[i].wakeStarted = false
        track.turns[i].state = .done
        track.turns[i].finishedAt = Date()
        track.turns[i].approvals.removeAll()
        scheduleReleaseIfIdle(track)
        publishIfChanged(track)
    }

    /// 結果待ちのターンがあり、作業の行が無くなったら、知らせのターンを待つ猶予を数え始める（その間に知らせのターンの
    /// done が来れば、そちらで終わる。子のターンが動き出していれば、猶予が過ぎても終わらせない）。
    private func watchBackground(_ track: Track) {
        track.backgroundSettle?.cancel()
        track.backgroundSettle = nil
        guard let i = track.turns.lastIndex(where: { $0.state == .running }), track.turns[i].awaitingBackground,
              !track.cards.counts.agentsOrWorkflows else { return }
        let trackId = track.id
        let clientMessageId = track.turns[i].clientMessageId
        let delay = backgroundSettleSeconds
        track.backgroundSettle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.settleBackground(trackId: trackId, clientMessageId: clientMessageId)
        }
    }

    /// 作業が無くなってから猶予の間に知らせのターンが来なかった（子が終わっても親が起きない CLI。Codex の multi-agent v2 など）。
    /// 今の返事で done にする。
    private func settleBackground(trackId: UUID, clientMessageId: String) {
        guard let track = tracks.first(where: { $0.id == trackId }),
              let i = track.turns.firstIndex(where: { $0.clientMessageId == clientMessageId }),
              track.turns[i].state == .running, track.turns[i].awaitingBackground,
              !track.turns[i].wakeStarted, !track.cards.counts.agentsOrWorkflows else { return }
        track.backgroundSettle = nil
        finishTurn(track, index: i)
        scheduleSave()
    }

    /// 結果待ちのまま出来事が無い時間が上限を過ぎたら done にする（終わりの知らせを取りこぼした行で永久に待たない）。
    private func settleIfBackgroundStale(_ track: Track, index i: Int) {
        let t = track.turns[i]
        guard t.state == .running, t.awaitingBackground,
              Date().timeIntervalSince(t.lastEventAt) > Self.backgroundWaitMaxSeconds else { return }
        finishTurn(track, index: i)
        scheduleSave()
    }

    /// iPhone が子のチャットで承認に答えた（WebSocketServer の action_response）。答えたことを知らせない adapter
    /// （ACP など）があるので、ここで待ちから外す（外さないと mainagent に needs_approval が残る）。
    func noteApprovalAnswered(agentId: String, requestId: String) {
        for t in tracks where t.agentId == agentId {
            var changed = false
            for i in t.turns.indices where t.turns[i].approvals.contains(where: { $0.requestId == requestId }) {
                t.turns[i].approvals.removeAll { $0.requestId == requestId }
                changed = true
            }
            if changed { publishIfChanged(t) }
        }
    }

    /// 子の action_request を、mainagent が読める承認にする。
    static func approval(from event: SessionEvent) -> Approval {
        let meta = event.metadata ?? [:]
        let requestId = meta["requestId"] ?? event.messageId ?? ""
        let count = Int(meta["option_count"] ?? "") ?? 0
        let options: [(value: String, title: String)] = (0..<count).compactMap { i in
            guard let v = meta["option_\(i)_value"], !v.isEmpty else { return nil }
            return (v, meta["option_\(i)_title"] ?? v)
        }
        let kind = meta["kind"]
        // 答えられないもの: 質問（選択肢が答えそのもの）、答える口の無いカード、ターミナルへの発話の保留
        // （許可の確認を省くターミナルへ、mainagent が自分の発話を通すことになる）。
        let answerable = !options.isEmpty
            && kind != "userInput" && kind != "question"
            && meta["answerable"] != "0"
            && !requestId.hasPrefix("held-")
            // 子がさらに頼もうとして出た Bridge の承認カード（ふつうのセッションからも頼めるため）。
            // 答えは子の respondToAction ではなく Orchestrator が受けるので、上からは答えさせない。
            && !requestId.hasPrefix("mainagent-")
        return Approval(requestId: requestId,
                        title: meta["title"] ?? event.content ?? "承認が必要",
                        summary: meta["subtitle"], kind: kind, options: options, answerable: answerable)
    }

    private func settleIfErrored(_ track: Track, index i: Int) {
        let t = track.turns[i]
        // 結果待ちのターンは done を受けている（error だけで終わったのではない）。
        guard t.state == .running, t.errorText != nil, !t.awaitingBackground,
              Date().timeIntervalSince(t.lastEventAt) > Self.erroredTurnSettleSeconds else { return }
        track.turns[i].state = .error
        track.turns[i].finishedAt = Date()
        track.turns[i].approvals.removeAll()
        scheduleReleaseIfIdle(track)
        publishIfChanged(track)
        scheduleSave()
    }

    private func scheduleReleaseIfIdle(_ track: Track) {
        guard !track.busy else { return }
        track.releaseTask?.cancel()
        let trackId = track.id
        let delay = idleReleaseSeconds
        track.releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.releaseIfIdle(trackId: trackId)
        }
    }

    private func releaseIfIdle(trackId: UUID) async {
        guard let track = tracks.first(where: { $0.id == trackId }), !track.busy else { return }
        await unsubscribe(track)
        WebSocketServer.wslog("mainagent.release agent=\(track.agentId) session=\(track.sessionId.prefix(8))")
    }

    private func trimTracks() {
        guard tracks.count > Self.maxTracks else { return }
        let removable = tracks.filter { $0.subscriberId == nil && !$0.busy }.sorted { $0.touchedAt < $1.touchedAt }
        for t in removable.prefix(tracks.count - Self.maxTracks) {
            tracks.removeAll { $0 === t }
        }
    }

    static func status(of turn: Turn) -> String {
        switch turn.state {
        case .queued: return "queued"
        case .running: return turn.approvals.isEmpty ? "running" : "needs_approval"
        case .done: return turn.full.isEmpty && turn.errorText != nil ? "error" : "done"
        case .error: return "error"
        }
    }

    private func describe(_ track: Track, turn: Turn, status: String) -> [String: Any] {
        var r: [String: Any] = [
            "agent": track.agentId, "session_id": track.sessionId, "status": status,
            "request": String(turn.prompt.prefix(200)),
            "elapsed_seconds": Int((turn.finishedAt ?? Date()).timeIntervalSince(turn.sentAt))
        ]
        if let cwd = track.cwd { r["cwd"] = cwd }
        let reply = turn.lastBubble.isEmpty ? turn.full : turn.lastBubble
        if !reply.isEmpty { r["reply"] = Self.tail(reply, Self.maxReplyChars) }
        let earlier = turn.full.count > reply.count ? String(turn.full.dropLast(reply.count)) : ""
        if !earlier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, status != "running" {
            r["earlier"] = Self.tail(earlier, 2000)
        }
        if turn.state == .running, let first = turn.approvals.first {
            // approval は最初の 1 件（前の版と同じキー）、approvals は待っているもの全部。
            r["approval"] = Self.approvalInfo(first)
            if turn.approvals.count > 1 { r["approvals"] = turn.approvals.map { Self.approvalInfo($0) } }
        }
        if let e = turn.errorText { r["error"] = String(e.prefix(500)) }
        if status == "running" || status == "queued" {
            r["hint"] = turn.awaitingBackground
                ? "バックグラウンドの作業の結果待ち（reply は起動の返事）。少し待ってもう一度 get_reply を呼ぶ"
                : "まだ作業中。少し待ってもう一度 get_reply を呼ぶ"
        }
        return r
    }

    /// 頼んでいないセッション（ユーザーが開いたもの）の状況。最後の返事は履歴から読む。
    private func untrackedStatus(agentId: String, sessionId: String) async -> [String: Any] {
        let live = await SessionHub.shared.snapshot().first { $0.agentId == agentId && $0.sessionId == sessionId }
        var terminalWorking = false
        if agentId == "claude" {
            terminalWorking = await ClaudeTerminalRegistry.shared.generatingSessionIds().contains(sessionId)
        }
        var r: [String: Any] = [
            "agent": agentId, "session_id": sessionId,
            "status": (live?.generating ?? false) || terminalWorking ? "running" : "idle"
        ]
        if let cwd = live?.cwd { r["cwd"] = cwd }
        if let adapter = await AgentRegistry.shared.adapter(for: agentId) {
            let history = await adapter.loadHistory(sessionId: sessionId)
            if let last = history.last(where: { $0.role == "assistant" }) {
                r["last_reply"] = Self.tail(last.content, Self.maxReplyChars)
            }
            if let lastUser = history.last(where: { $0.role == "user" }) {
                r["last_request"] = String(lastUser.content.prefix(200))
            }
        }
        return r
    }

    private static func tail(_ s: String, _ n: Int) -> String {
        s.count > n ? "…" + String(s.suffix(n)) : s
    }

    // MARK: - 別の PC に頼む（A 側）

    /// デスクトップが渡した別の PC の一覧（`PUT /local/remote-pcs`）。メモリだけ（合言葉が入る）。
    private var remotePCs: [RemotePC] = []

    /// 毎回まるごと置き換える。デスクトップがいなくなった（管理鍵のパイプが閉じた）ら空にする。
    func setRemotePCs(_ pcs: [RemotePC]) {
        remotePCs = pcs
        WebSocketServer.wslog("mesh.remote-pcs count=\(pcs.count)")
    }

    func remotePCList() -> [RemotePC] { remotePCs }

    /// `pc` を付けられる道具（別の PC へ回せるもの）。
    static let remoteToolNames: Set<String> = ["list_projects", "list_agents", "list_sessions", "start_session",
                                               "send_message", "get_reply", "answer_approval"]

    /// この PC（list_pcs の先頭・別の PC へ送る caller）。
    static func selfPC() -> (bridgeId: String, name: String, platform: String) {
        (KeyStore.loadOrCreateBridgeId(), BridgeIdentityInfo.machineName, "mac")
    }

    /// `list_pcs`: 自分の PC を先頭に、次に別の PC。
    func listPCs() -> [String: Any] {
        let me = Self.selfPC()
        var rows: [[String: Any]] = [["pc": me.bridgeId, "name": me.name, "platform": me.platform, "self": true]]
        for p in remotePCs {
            rows.append(["pc": p.bridgeId, "name": p.name, "platform": p.platform, "self": false])
        }
        return ["pcs": rows]
    }

    /// 道具の `pc`（bridgeId か、名前と完全に一致する文字列）を引く。無い・自分の PC なら nil（この PC で扱う）。
    func resolvePC(_ raw: String?) throws -> RemotePC? {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        let me = Self.selfPC()
        if key == me.bridgeId || key == me.name { return nil }
        if let p = remotePCs.first(where: { $0.bridgeId == key }) ?? remotePCs.first(where: { $0.name == key }) {
            return p
        }
        throw ToolError(code: "unknown_pc", "知らない PC: \(key)（list_pcs で確かめる）")
    }

    /// 別の PC へ道具を回す。頼む道具（start_session / send_message / answer_approval の許可）は、
    /// 先にこの PC で呼んだ側のチャットへ承認カード（「PC: 名前」付き）を出し、断られたら送らない。
    /// 結果は B が返した JSON をそのまま返し、頼んだ子は呼んだ側の子のカードに行として出す（B の子は購読しない）。
    func callRemote(_ tool: String, args: [String: Any], pc: RemotePC, caller: Caller) async throws -> Any {
        guard Self.remoteToolNames.contains(tool) else { throw ToolError("\(tool) は別の PC では使えない") }
        func str(_ key: String) throws -> String {
            guard let v = args[key] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolError("\(key) が無い")
            }
            return v
        }
        func seconds(_ key: String, _ fallback: Double) -> Double {
            max(0, min((args[key] as? NSNumber)?.doubleValue ?? fallback, 300))
        }
        let cap = ceiling(caller)
        var timeout: TimeInterval = 30
        switch tool {
        case "start_session":
            _ = try checkDepth(caller)
            let agent = (args["agent"] as? String) ?? "claude"
            let cwd = try str("cwd")
            let prompt = try str("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
            let place = (cwd as NSString).lastPathComponent
            let mode = (args["mode"] as? String).map { "\($0)（上限「\(Self.strengthNames[cap])」以下に絞る）" }
                ?? "上限「\(Self.strengthNames[cap])」以下"
            try await requireApproval(
                caller,
                title: "\(pc.name) の \(place) で \(agent) を起こして頼みますか？",
                subtitle: "PC: \(pc.name)\n" + Self.approvalSubtitle(prompt: prompt, mode: mode))
            // B は確定した ID を最大 30 秒待ってから、wait_seconds の間返事を待つ。
            timeout = seconds("wait_seconds", 0) + 60
        case "send_message":
            _ = try checkDepth(caller)
            let agent = try str("agent")
            let sid = try str("session_id")
            let text = try str("text").trimmingCharacters(in: .whitespacesAndNewlines)
            let t = remoteTrack(bridgeId: pc.bridgeId, agentId: agent, sessionId: sid)
            let place = t?.project ?? t?.cwd.map { ($0 as NSString).lastPathComponent } ?? String(sid.prefix(8))
            try await requireApproval(
                caller,
                title: "\(pc.name) の \(place) の \(t?.agentName ?? agent) に送りますか？",
                subtitle: "PC: \(pc.name)\n" + Self.approvalSubtitle(prompt: text, mode: "相手の PC で上限「\(Self.strengthNames[cap])」と比べる"))
            timeout = seconds("wait_seconds", 0) + 30
        case "get_reply":
            timeout = seconds("wait_seconds", 60) + 30
        case "answer_approval":
            guard let choice = ApprovalChoice(rawValue: try str("decision")) else {
                throw ToolError("decision は allow / allow_for_session / deny のどれか")
            }
            if choice != .deny {
                guard cap >= 1 else {
                    throw ToolError("上限が「\(Self.strengthNames[cap])」なので、子の承認に許可で答えられない。ユーザーにそのセッションを開いて答えてもらう")
                }
                if choice == .allowForSession, cap < 2 {
                    throw ToolError("「このセッションでは許可」は、上限が「編集は尋ねない」以上のときだけ使える（今は「\(Self.strengthNames[cap])」）。allow で一度だけ許可する")
                }
                let agent = try str("agent")
                let sid = try str("session_id")
                let rid = try str("request_id")
                let t = remoteTrack(bridgeId: pc.bridgeId, agentId: agent, sessionId: sid)
                let pending = t?.turns.last?.approvals.first { $0.requestId == rid }
                let place = t?.project ?? t?.cwd.map { ($0 as NSString).lastPathComponent } ?? String(sid.prefix(8))
                var lines = ["PC: \(pc.name)", "答え: \(choice == .allow ? "一度だけ許可" : "このセッションでは許可")"]
                if let a = pending {
                    lines.append("確認: \(a.title)")
                    if let s = a.summary, !s.isEmpty { lines.append(s.count > 400 ? String(s.prefix(400)) + "…" : s) }
                }
                try await requireApproval(
                    caller,
                    title: "\(pc.name) の \(place) の \(t?.agentName ?? agent) の承認に、許可で答えますか？",
                    subtitle: lines.joined(separator: "\n"),
                    honorAutoApprove: cap >= 3, offerSessionOption: cap >= 3)
            }
        default:
            break
        }
        var body = args
        body.removeValue(forKey: "pc")
        body["capMode"] = cap
        body["depth"] = effectiveDepth(caller)
        let me = Self.selfPC()
        body["caller"] = ["bridgeId": me.bridgeId, "name": me.name]
        let res: RemoteOrchestratorClient.Response
        do {
            res = try await RemoteOrchestratorClient.post(pc: pc, tool: tool, body: body, timeout: timeout)
        } catch {
            throw ToolError(code: "pc_unreachable", "\(pc.name) に届かない（\(error.localizedDescription)）")
        }
        WebSocketServer.wslog("mesh.forward pc=\(pc.bridgeId.prefix(8)) tool=\(tool) status=\(res.status)")
        let json = try? JSONSerialization.jsonObject(with: res.body, options: [.fragmentsAllowed])
        let obj = json as? [String: Any]
        switch res.status {
        case 200:
            guard let json else { throw ToolError(code: "pc_unreachable", "\(pc.name) の応答が読めない") }
            noteRemoteResult(tool, args: args, result: json, pc: pc, caller: caller)
            return json
        case 422:
            let message = (obj?["message"] as? String) ?? "失敗した"
            throw ToolError(passing: "\(pc.name): \(message)", code: (obj?["error"] as? String) ?? "tool_error")
        case 404 where obj?["error"] as? String == "unknown_tool":
            throw ToolError("\(pc.name) はこの道具を知らない: \(tool)")
        case 404:
            throw ToolError(code: "pc_unreachable", "\(pc.name) の BuddyOS が古い（別の PC から頼まれる口が無い）")
        case 401, 403:
            throw ToolError(code: "pc_unreachable", "\(pc.name) に断られた（HTTP \(res.status)。ペアリングか中継口を確かめる）")
        default:
            throw ToolError(code: "pc_unreachable", "\(pc.name) から応答が無い（HTTP \(res.status)）")
        }
    }

    /// B から受けた結果で、別の PC の子の行を作る・直す（start_session / send_message / get_reply / answer_approval）。
    private func noteRemoteResult(_ tool: String, args: [String: Any], result: Any, pc: RemotePC, caller: Caller) {
        guard let r = result as? [String: Any], let sid = r["session_id"] as? String, !sid.isEmpty else { return }
        let agent = (r["agent"] as? String) ?? (args["agent"] as? String) ?? "claude"
        // start_session の ID は確定前の仮 ID のことがある。get_reply で確定 ID が返ったら同じ行の ID を変える。
        var found = remoteTrack(bridgeId: pc.bridgeId, agentId: agent, sessionId: sid)
        if found == nil, let asked = args["session_id"] as? String {
            found = remoteTrack(bridgeId: pc.bridgeId, agentId: agent, sessionId: asked)
        }
        if let t = found, t.sessionId != sid {
            t.aliases.insert(sid)
            t.sessionId = sid
            t.confirmed = true
        }
        switch tool {
        case "start_session", "send_message":
            let t = found ?? {
                let cwd = (r["cwd"] as? String) ?? (args["cwd"] as? String)
                let nt = Track(agentId: agent, sessionId: sid, cwd: cwd, confirmed: (r["confirmed"] as? Bool) ?? true)
                nt.remoteBridgeId = pc.bridgeId
                nt.remotePcName = pc.name
                nt.agentName = agent
                nt.project = cwd.map { ($0 as NSString).lastPathComponent }
                tracks.append(nt)
                trimTracks()
                return nt
            }()
            if let confirmed = r["confirmed"] as? Bool { t.confirmed = confirmed }
            if let m = r["mode"] as? String, Self.strength(of: m, agentId: agent) != nil { t.childMode = m }
            let prompt = (args[tool == "start_session" ? "prompt" : "text"] as? String) ?? ""
            var turn = Turn(clientMessageId: "remote-\(UUID().uuidString)", prompt: prompt)
            if let state = (r["state"] as? String).flatMap(TurnState.init(rawValue:)) { turn.state = state }
            if turn.state == .running { turn.startedAt = Date() }
            t.turns.append(turn)
            if t.turns.count > Self.maxTurnsPerTrack { t.turns.removeFirst(t.turns.count - Self.maxTurnsPerTrack) }
            t.depth = effectiveDepth(caller) + 1
            t.touchedAt = Date()
            attach(t, to: caller)
            applyRemoteStatus(t, r)
            publishIfChanged(t)
        case "get_reply":
            guard let t = found else { return }
            applyRemoteStatus(t, r)
            publishIfChanged(t)
        case "answer_approval":
            guard let t = found, let rid = r["request_id"] as? String else { return }
            for i in t.turns.indices { t.turns[i].approvals.removeAll { $0.requestId == rid } }
            publishIfChanged(t)
        default:
            break
        }
    }

    /// get_reply の形（status / reply / approval / approvals / error）を、別の PC の子の最後のターンに写す。
    private func applyRemoteStatus(_ t: Track, _ r: [String: Any]) {
        guard let status = r["status"] as? String, let i = t.turns.indices.last else { return }
        var turn = t.turns[i]
        if let reply = r["reply"] as? String {
            turn.lastBubble = reply
            turn.full = reply
        }
        func approval(_ a: [String: Any]) -> Approval? {
            guard let id = a["request_id"] as? String else { return nil }
            let choices = (a["choices"] as? [String]) ?? []
            return Approval(requestId: id, title: (a["title"] as? String) ?? "承認が必要",
                            summary: a["summary"] as? String, kind: a["kind"] as? String,
                            options: choices.map { (value: $0, title: $0) }, answerable: !choices.isEmpty)
        }
        switch status {
        case "queued":
            turn.state = .queued
        case "running":
            turn.state = .running
            turn.startedAt = turn.startedAt ?? Date()
            turn.approvals = []
        case "needs_approval":
            turn.state = .running
            turn.startedAt = turn.startedAt ?? Date()
            let all = (r["approvals"] as? [[String: Any]]) ?? (r["approval"] as? [String: Any]).map { [$0] } ?? []
            turn.approvals = all.compactMap(approval)
        case "done":
            turn.state = .done
            turn.finishedAt = turn.finishedAt ?? Date()
            turn.approvals = []
        case "error":
            turn.state = .error
            turn.finishedAt = turn.finishedAt ?? Date()
            turn.errorText = (r["error"] as? String) ?? "エラーで止まった"
            turn.approvals = []
        default:
            break
        }
        t.turns[i] = turn
        t.touchedAt = Date()
    }

    // MARK: - 全部の PC の一覧（B の口 `GET /device/sessions/summary`）

    /// cwd → (ブランチ, 読んだ時刻)。git を毎回起こさないよう 30 秒覚える。
    private var branchCache: [String: (branch: String?, at: Date)] = [:]
    static let branchCacheSeconds: TimeInterval = 30
    static let summaryLimit = 50

    private func branch(cwd: String) async -> String? {
        if let c = branchCache[cwd], Date().timeIntervalSince(c.at) < Self.branchCacheSeconds { return c.branch }
        let b = await GitInfoReader.branch(cwd: cwd)
        branchCache[cwd] = (b, Date())
        if branchCache.count > 200 {
            let old = Date().addingTimeInterval(-Self.branchCacheSeconds)
            branchCache = branchCache.filter { $0.value.at > old }
        }
        return b
    }

    /// list_sessions と同じ集め方（hub の entry・ターミナルの Claude。閉じた子は除く）。mainagent のフォルダのものも含める。
    func sessionsSummary() async -> [String: Any] {
        let projects = ProjectRegistry.list()
        let live = await SessionHub.shared.snapshot()
        let terminal = await ClaudeTerminalRegistry.shared.liveEntries()
        let terminalGenerating = await ClaudeTerminalRegistry.shared.generatingSessionIds()
        let terminalCwd = Dictionary(terminal.map { ($0.sessionId, $0.cwd) }, uniquingKeysWith: { a, _ in a })

        struct Row {
            let agentId: String
            let sessionId: String
            let cwd: String?
            let displayName: String?
            let generating: Bool
            let awaiting: Bool
            let updatedAt: Date
        }
        var rows: [Row] = []
        var seen = Set<String>()
        for info in live where seen.insert("\(info.agentId):\(info.sessionId)").inserted {
            let cwd = info.cwd ?? track(agentId: info.agentId, sessionId: info.sessionId)?.cwd
                ?? (info.agentId == "claude" ? terminalCwd[info.sessionId] ?? nil : nil)
            rows.append(Row(agentId: info.agentId, sessionId: info.sessionId, cwd: cwd, displayName: info.displayName,
                            generating: info.generating || (info.agentId == "claude" && terminalGenerating.contains(info.sessionId)),
                            awaiting: info.awaiting, updatedAt: info.lastEventAt))
        }
        for t in terminal where seen.insert("claude:\(t.sessionId)").inserted {
            rows.append(Row(agentId: "claude", sessionId: t.sessionId, cwd: t.cwd, displayName: nil,
                            generating: terminalGenerating.contains(t.sessionId), awaiting: false, updatedAt: t.startedAt))
        }

        var out: [(Date, [String: Any])] = []
        var names: [String: String] = [:]
        for r in rows {
            let tracked = track(agentId: r.agentId, sessionId: r.sessionId)
            let last = tracked?.turns.last
            var updated = r.updatedAt
            for d in [last?.sentAt, last?.startedAt, last?.finishedAt].compactMap({ $0 }) where d > updated { updated = d }
            let pendingApproval = last.map { $0.state == .running && !$0.approvals.isEmpty } ?? false
            let status = r.awaiting || pendingApproval ? "needs_approval" : (r.generating ? "running" : "idle")
            if names[r.agentId] == nil {
                let adapter = await AgentRegistry.shared.adapter(for: r.agentId)
                names[r.agentId] = adapter?.displayName ?? (r.agentId == "claude" ? "Claude Code" : r.agentId)
            }
            var row: [String: Any] = [
                "agentId": r.agentId, "agentName": r.displayName ?? names[r.agentId] ?? r.agentId,
                "sessionId": r.sessionId, "status": status, "updatedAtMs": Self.ms(updated),
                "cwd": r.cwd ?? NSNull(), "project": NSNull(), "branch": NSNull(), "title": NSNull()
            ]
            if let cwd = r.cwd {
                if MainAgentWorkspace.isMainWorkspace(cwd) {
                    row["project"] = MainAgentWorkspace.projectName
                } else if let p = projects.first(where: { ProjectRegistry.normalize($0.path) == ProjectRegistry.normalize(cwd) }) {
                    row["project"] = p.name
                }
            }
            if let last { row["title"] = Self.oneLine(last.prompt, 60) }
            out.append((updated, row))
        }
        out.sort { $0.0 > $1.0 }
        var sessions = out.prefix(Self.summaryLimit).map(\.1)
        for i in sessions.indices {
            if let cwd = sessions[i]["cwd"] as? String, let b = await branch(cwd: cwd) { sessions[i]["branch"] = b }
        }
        let me = Self.selfPC()
        return ["pc": ["bridgeId": me.bridgeId, "name": me.name, "platform": me.platform], "sessions": sessions]
    }

    // MARK: - 子のカード（mainagent のチャットに出す workflow_progress kind = "sessions"）

    /// カードの taskId。mainagent のチャット 1 つにつき 1 枚。
    static let sessionsTaskId = "mainagent-sessions"
    static let sessionsCardName = "任せたセッション"

    private static func ms(_ d: Date) -> Int { Int(d.timeIntervalSince1970 * 1000) }

    private static func oneLine(_ s: String, _ n: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    /// 子 1 つの行。形は shared/protocol.json の payloads.workflow_progress.sessions。
    /// updatedAtMs は入れない（変わったかどうかの比較に使うため。publishCard で足す）。
    private func cardRow(_ t: Track) -> [String: Any] {
        let turn = t.turns.last
        let status = turn.map(Self.status(of:)) ?? "idle"
        var row: [String: Any] = [
            "index": t.cardIndex,
            "rowKind": "session",
            "agentId": t.agentId,
            "sessionId": t.sessionId,
            "confirmed": t.confirmed,
            "status": status,
            "createdAtMs": Self.ms(t.createdAt)
        ]
        // 古いアプリ（dynamic workflow のカードとして出す）向けの state / label / resultPreview。
        switch status {
        case "done": row["state"] = "done"
        case "error": row["state"] = "failed"
        case "idle": row["state"] = "done"
        default: row["state"] = "running"
        }
        let name = t.agentName ?? t.agentId
        let place = t.project ?? t.cwd.map { ($0 as NSString).lastPathComponent }
        row["agentName"] = name
        row["label"] = place.map { "\($0) · \(name)" } ?? name
        if let cwd = t.cwd { row["cwd"] = cwd }
        if let p = t.project { row["project"] = p }
        if let m = t.childMode { row["mode"] = m }
        // 別の PC の子。行のタップでその PC に切り替えてから子のチャットを開く。
        if let b = t.remoteBridgeId {
            row["bridgeId"] = b
            if let n = t.remotePcName {
                row["pcName"] = n
                row["label"] = "\(n) · " + (row["label"] as? String ?? name)
            }
        }
        guard let turn else { return row }
        row["title"] = Self.oneLine(turn.prompt, 60)
        row["startedAtMs"] = Self.ms(turn.sentAt)
        if let f = turn.finishedAt, turn.state == .done || turn.state == .error {
            row["finishedAtMs"] = Self.ms(f)
            row["durationMs"] = max(0, Self.ms(f) - Self.ms(turn.sentAt))
        }
        var summary: String?
        switch status {
        case "needs_approval":
            if let a = turn.approvals.first {
                summary = "承認待ち: " + Self.oneLine(a.title, 80)
                var info: [String: Any] = ["requestId": a.requestId, "title": a.title,
                                           "answerable": a.answerable, "count": turn.approvals.count]
                if let s = a.summary, !s.isEmpty { info["summary"] = Self.oneLine(s, 200) }
                if let k = a.kind { info["kind"] = k }
                row["approval"] = info
            }
        case "done":
            let reply = turn.lastBubble.isEmpty ? turn.full : turn.lastBubble
            if !reply.isEmpty { summary = Self.oneLine(String(reply.suffix(400)), 160) }
        case "error":
            summary = Self.oneLine(turn.errorText ?? "エラーで止まった", 160)
        default:
            break
        }
        if let summary {
            row["summary"] = summary
            row["resultPreview"] = summary
        }
        return row
    }

    private func cardSignature(_ t: Track) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: cardRow(t), options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 行が変わっていれば、その mainagent のチャットへカードを出し直す。
    private func publishIfChanged(_ track: Track) {
        guard let pa = track.parentAgentId, let ps = track.parentSessionId else { return }
        let sig = cardSignature(track)
        guard sig != track.cardSignature else { return }
        track.cardSignature = sig
        track.cardUpdatedAt = Date()
        publishCard(parentAgentId: pa, parentSessionId: ps)
    }

    /// カード全体（その mainagent が頼んだ子の全行）。行が無ければ nil。
    func sessionsCardJSON(parentAgentId: String, parentSessionId: String) -> String? {
        let mine = tracks.filter { $0.parentAgentId == parentAgentId && $0.parentSessionId == parentSessionId }
            .sorted { $0.cardIndex < $1.cardIndex }
        guard !mine.isEmpty else { return nil }
        var rows: [[String: Any]] = []
        var active = false
        for t in mine {
            var row = cardRow(t)
            row["updatedAtMs"] = Self.ms(t.cardUpdatedAt)
            if let s = row["status"] as? String, ["queued", "running", "needs_approval"].contains(s) { active = true }
            rows.append(row)
        }
        let out: [String: Any] = [
            "subtype": "task_progress",
            "taskId": Self.sessionsTaskId,
            "kind": "sessions",
            "workflowName": Self.sessionsCardName,
            "status": active ? "running" : "completed",
            "updatedAtMs": Self.ms(mine.map(\.cardUpdatedAt).max() ?? Date()),
            "agents": rows
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// hub へは届いた順に渡す（Task を投げっぱなしにすると、古い状態が後から届いて上書きすることがある）。
    private var cardQueue: AsyncStream<(String, String, String)>.Continuation?

    private func publishCard(parentAgentId: String, parentSessionId: String) {
        let json = sessionsCardJSON(parentAgentId: parentAgentId, parentSessionId: parentSessionId)
            ?? Self.emptySessionsCardJSON
        if cardQueue == nil {
            let (stream, continuation) = AsyncStream<(String, String, String)>.makeStream(bufferingPolicy: .unbounded)
            cardQueue = continuation
            Task {
                for await (agentId, sessionId, payload) in stream {
                    await SessionHub.shared.publishSessionsCard(agentId: agentId, sessionId: sessionId, payloadJSON: payload)
                }
            }
        }
        cardQueue?.yield((parentAgentId, parentSessionId, json))
    }

    /// 行がすべて別の mainagent へ移ったときのカード（行は消せないので、カードを終わったことにするだけ）。
    private static let emptySessionsCardJSON =
        #"{"agents":[],"kind":"sessions","status":"completed","subtype":"task_progress","taskId":"mainagent-sessions","workflowName":"任せたセッション"}"#
}
