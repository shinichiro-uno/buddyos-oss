import Foundation

// ---------------------------------------------------------------------------
// ターミナルで動いている Claude Code セッションを BuddyOS に「attach」する
//
// Claude Code のプロセスモデルは 2 つある。
//   spawn: Bridge が `claude -p --input-format stream-json` を自前で起こす（ClaudeCodeSession）
//   attach: ユーザーがターミナルで開いた対話セッションに、後から繋ぐ（ここ）
//
// 自分が起こしていないプロセスの PTY は覗けないし、対話 TUI のプロセスに横から
// JSON を流し込む口も無い。代わりに Claude Code 公式の 2 つの機構を使う。
//   - hooks: SessionStart / UserPromptSubmit / MessageDisplay / PreToolUse /
//            PostToolUse / Stop / SessionEnd が、そのセッションで起きたことを
//            http POST で Bridge に届ける（本文は MessageDisplay の delta で
//            行バッチ単位に流れてくる）→ 「見る」
//   - channel: Bridge が MCP channel サーバとして振る舞い、
//            notifications/claude/channel でセッションに発話を入れる → 「送る」
//            （channel 側は別ファイル。ここは台帳と「見る」を担う）
//
// 結合キーは session_id 一本。hook も channel サーバも環境変数
// CLAUDE_CODE_SESSION_ID を持ち、PPID は claude 本体の pid（実測）。
//
// 重要な制約（実測）: 常駐 spawn が保持している S を、別プロセスで --resume すると
// 拒否されずに両方動き、会話が静かに二股になる。S を持つプロセスは常に 1 つでなければ
// ならない。ターミナルの SessionStart（最初のプロンプトより前に発火）で spawn 側を
// 止めるのが引き継ぎの唯一安全な順序。
// ---------------------------------------------------------------------------

/// 生きているターミナルセッションの台帳。hook の POST を受け取り、attach 済みの
/// ClaudeTerminalSession があればそこへ、無ければ短いバッファに溜める。
actor ClaudeTerminalRegistry {
    static let shared = ClaudeTerminalRegistry()

    struct Live {
        let sessionId: String
        let cwd: String?
        let pid: Int32?
        let transcriptPath: String?
        let startedAt: Date
        /// Claude Code の cross-session messaging の受け箱（/tmp/cc-socks/<pid>.sock）。
        /// 普通に起動した claude にもあり、書けば待機中なら即ターンが始まる。
        var inboxSocket: String? = nil
        /// attach 中の session。同じ sid を同時に開くと一時的に複数になる（SessionHub が重複分を
        /// close する。どちらが採用されるかはここからは分からない）ので、全員に配り、detach は自分だけ外す。
        var sessions: [ClaudeTerminalSession] = []
        /// attach 前に届いた、進行中ターンのイベント。iPhone が開いた瞬間に流し直す。
        /// 完了したターンは transcript に入っていて履歴で読めるので、Stop で捨てる（流すと二重表示になる）。
        /// 進行中ターンの発話と本文も transcript に書かれていくので、取っておくのはツールの進行と通知だけ。
        var backlog: [SessionEvent] = []
        /// 進行中ターンで attach 中の session に配ったもののうち、流し直す分（最初に流した backlog を含む）。
        /// 並走して後から attach した session にも同じものを渡す。
        var delivered: [SessionEvent] = []
        /// MessageDisplay の message 識別子 → iOS 側 messageId。1 メッセージ 1 バブル。
        var messageIds: [String: String] = [:]
        /// 現在のターンの messageId（Stop の done に使う）。
        var currentMessageId: String?
        /// ターミナル側でターン進行中（UserPromptSubmit 〜 Stop）。list_sessions の running に使う。
        var generating: Bool = false
        /// サブエージェントの進行（SubagentStart / SubagentStop と agent_id 付きの PreToolUse）。
        /// バックグラウンドのサブエージェントは Stop の後も動くので、ターンとは別に持つ。
        var subagents = SubagentTracker()
        /// ターミナルに出ている選択肢（許可確認・質問・計画の承認）。iPhone / デスクトップにカードで出している。
        var prompts: [TerminalPrompt] = []
        /// デスクトップのアプリ内ターミナルで動いているなら、そのペイン（hook の X-BuddyOS-Pane）。
        var pane: String? = nil
        /// 今のターンが知らせのターン（バックグラウンドの作業が終わって CLI が自分から始めたターン。prompt は
        /// <task-notification> の塊だけ）か。done の metadata に origin = task-notification を付ける。
        var notificationTurn = false
        /// 今のターンで toolStart を出し、まだ toolEnd を出していない main のツール（出した順）。
        /// 中断されたツールには PostToolUse も PostToolUseFailure も来ない（実測）ので、Stop で閉じる。
        var openTools: [(id: String, name: String)] = []
        /// 今のターンの本文（MessageDisplay の message 識別子 → 届いた delta を届いた順に）と、最後に本文が届いたメッセージ。
        /// Stop の last_assistant_message と突き合わせ、足りない分を流す。
        var chunks: [String: [String]] = [:]
        var lastMessageKey: String?
        /// 終わったターンの最後のメッセージ。Stop の後に遅れて届いた、その MessageDisplay を捨てる。
        var settled: SettledMessage?
        /// SubagentStart を受けたことがあるか。無ければ hook が古い install（SubagentStart を入れていない）とみなし、
        /// 知らない agent_id のツールを今までどおり親のツール行に出す。
        var sawSubagentStart = false
    }

    /// Stop の last_assistant_message で流し終えた、ターンの最後のメッセージ。
    struct SettledMessage {
        let text: String
        /// そのメッセージの MessageDisplay の識別子（Stop までに届いていたもの・後から届いて捨てたもの）。
        var keys: Set<String>
        let at: Date
    }

    /// ターミナルに出ている選択肢 1 つ分。
    struct TerminalPrompt {
        let requestId: String
        /// approval / userInput / plan / held（受け箱に送った発話をターミナルが保留した）
        let kind: String
        let toolName: String
        let input: [String: Any]
        let hasSuggestions: Bool
        /// 答え方。channel（許可の中継）/ pty（デスクトップのターミナルへキー入力）/ none（ターミナルで選ぶしかない）
        let via: String
        /// PermissionRequest hook から作ったか（false = channel の依頼だけで作った）。重複カードを出さない判定に使う。
        let fromHook: Bool
        let createdAt: Date
        /// channel の依頼 id（5 文字）。届く前に答えが来たら verdict に取っておき、届いたら送る。
        var channelRequestId: String?
        var verdict: String?
        var answered = false
        /// サブエージェントの選択肢なら、その agent_id（main は nil）。閉じるのは同じ agent_id の hook だけ
        /// （並んで動くサブエージェントの同じ名前のツールで、親の選択肢を閉じない）。
        var agentId: String? = nil
    }

    private var live: [String: Live]
    private static let backlogLimit = 200

    /// claude --bg のワーカーか（hooks で載ったワーカーは承認に答えられず、返事だけも止められない。§7.8）。テストが差し替える。
    private var isBackgroundWorker: @Sendable (String) async -> Bool = { await ClaudeBackgroundJobs.shared.isBackgroundWorker(sessionId: $0) }

    func setBackgroundWorkerCheck(_ check: @escaping @Sendable (String) async -> Bool) {
        isBackgroundWorker = check
    }

    /// Bridge が再起動（クラッシュ含む）しても台帳を失わないための保存先。
    /// 復元は pid が生きている entry だけ（hook だけで登録された pid 無しの entry は次の hook で戻る）。
    private static var persistURL: URL { BuddyPaths.root.appendingPathComponent("claude-terminals.json") }

    private struct Persisted: Codable {
        let sessionId: String
        let cwd: String?
        let pid: Int32?
        let transcriptPath: String?
        let startedAt: Date
        var inboxSocket: String?
    }

    init() {
        live = Self.restoreFromDisk()
        if !live.isEmpty {
            WebSocketServer.wslog("claude-terminal restored \(live.count) session(s) from disk")
        }
    }

    private static func restoreFromDisk() -> [String: Live] {
        guard let data = try? Data(contentsOf: persistURL),
              let entries = try? JSONDecoder().decode([Persisted].self, from: data) else { return [:] }
        var out: [String: Live] = [:]
        for e in entries {
            guard let pid = e.pid, kill(pid, 0) == 0 || errno != ESRCH else { continue }
            out[e.sessionId] = Live(sessionId: e.sessionId, cwd: e.cwd, pid: pid,
                                    transcriptPath: e.transcriptPath, startedAt: e.startedAt,
                                    inboxSocket: e.inboxSocket)
        }
        return out
    }

    private func persist() {
        let entries = live.values.map {
            Persisted(sessionId: $0.sessionId, cwd: $0.cwd, pid: $0.pid,
                      transcriptPath: $0.transcriptPath, startedAt: $0.startedAt,
                      inboxSocket: $0.inboxSocket)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.persistURL, options: .atomic)
    }

    // MARK: - 台帳

    func register(sessionId: String, cwd: String?, pid: Int32?, transcriptPath: String?,
                  inboxSocket: String? = nil) {
        var pid = pid ?? live[sessionId]?.pid
        var inboxSocket = inboxSocket
        // hook が申告する transcript_path は、その session の transcript（<session_id>.jsonl）だけ受け付ける
        // （任意のファイルを読ませて iPhone に流させない）。
        let transcript = Self.validTranscriptPath(transcriptPath, sessionId: sessionId)
        let found = (pid == nil || inboxSocket != nil) ? Self.lookupClaudeProcess(sessionId: sessionId) : nil
        // 受け箱のソケットは hook の申告をそのまま使わず、Claude Code 自身が書く sessions/<pid>.json の
        // 値と同じときだけ使う（任意のソケットへ iPhone の発話を書かせない）。まだ書かれていなければ、
        // 送るときに inboxSocket(for:) が引き直す。
        if let claimed = inboxSocket, found?.inboxSocket != claimed {
            WebSocketServer.wslog("claude-terminal inbox_socket ignored (not in sessions/<pid>.json) session=\(sessionId.prefix(8))…")
            inboxSocket = nil
        }
        // pid 無し（SessionStart の登録に失敗して hook だけで載った / 親たどりで claude が
        // 見つからなかった）だと死活確認が効かず、ウィンドウを閉じても台帳に残り続ける。
        // Claude Code 自身が書いている実行中セッションの情報から補う。
        if pid == nil, let found {
            pid = found.pid
            if inboxSocket == nil, live[sessionId]?.inboxSocket == nil { inboxSocket = found.inboxSocket }
        }
        if var l = live[sessionId] {
            // 再登録（resume / clear）。attach 済みの session は維持する。
            l = Live(sessionId: sessionId, cwd: cwd ?? l.cwd, pid: pid,
                     transcriptPath: transcript ?? l.transcriptPath, startedAt: l.startedAt,
                     inboxSocket: inboxSocket ?? l.inboxSocket, sessions: l.sessions, backlog: l.backlog,
                     delivered: l.delivered, messageIds: l.messageIds,
                     currentMessageId: l.currentMessageId, generating: l.generating,
                     subagents: l.subagents, prompts: l.prompts, pane: l.pane,
                     notificationTurn: l.notificationTurn, openTools: l.openTools, chunks: l.chunks,
                     lastMessageKey: l.lastMessageKey, settled: l.settled, sawSubagentStart: l.sawSubagentStart)
            live[sessionId] = l
        } else {
            live[sessionId] = Live(sessionId: sessionId, cwd: cwd, pid: pid,
                                   transcriptPath: transcript, startedAt: Date(),
                                   inboxSocket: inboxSocket)
        }
        WebSocketServer.wslog("claude-terminal registered session=\(sessionId.prefix(8))… pid=\(pid.map(String.init) ?? "?") cwd=\(cwd ?? "?")")
        persist()
    }

    func unregister(sessionId: String) {
        guard var l = live.removeValue(forKey: sessionId) else { return }
        WebSocketServer.wslog("claude-terminal unregistered session=\(sessionId.prefix(8))…")
        if let pane = l.pane { TerminalPaneStatus.shared.remove(pane: pane, sessionId: sessionId) }
        persist()
        inboxPending.removeValue(forKey: sessionId)
        inboxPendingText.removeValue(forKey: sessionId)
        typedPending.removeValue(forKey: sessionId)
        typingTail.removeValue(forKey: sessionId)
        tailOffsets.removeValue(forKey: sessionId)
        tailIdleSince.removeValue(forKey: sessionId)
        interruptedTurns.removeValue(forKey: sessionId)
        // claude が終わると、バックグラウンドのサブエージェントとコマンドも一緒に止まり、終わりの知らせはもう来ない。
        // 見ている session には、実行中の行を stopped で閉じる payload を先に流す（カードに「実行中」を残さない）。
        if let p = l.subagents.abandonRunning(state: "stopped") {
            for s in l.sessions { s.push(.workflowProgress(agentId: "claude", sessionId: sessionId, payloadJSON: p)) }
        }
        for s in l.sessions { s.terminalEnded() }
        Task { await ClaudeChannelInbox.shared.forget(sessionId) }
    }

    func isLive(_ sessionId: String) -> Bool {
        fillMissingPid(sessionId)
        guard let l = live[sessionId] else { return false }
        // プロセスが消えていれば台帳から落とす（SessionEnd を取りこぼした場合の保険）。
        // ターミナルのウィンドウを閉じると claude は SessionEnd を出さずに死ぬ（実測）。
        if let pid = l.pid, kill(pid, 0) != 0, errno == ESRCH {
            unregister(sessionId: sessionId)
            return false
        }
        return true
    }

    func liveSessionIds() -> [String] { Array(live.keys) }

    /// 台帳に載っているか（生存確認や掃除はしない）。channel の poll が forget 済みの sid に
    /// 張り直したときに待たせないための問い合わせ。
    func contains(sessionId: String) -> Bool { live[sessionId] != nil }

    /// iPhone から channel で送った。UserPromptSubmit が来ない場合もあるので、ここでターンを始める。
    func noteChannelPrompt(sessionId: String) {
        guard var l = live[sessionId] else { return }
        Self.startTurn(&l, notification: false)
        live[sessionId] = l
        watchInterrupt(sessionId: sessionId)
    }

    /// 一覧用。プロセスが消えた session は落としてから返す（SessionEnd 取りこぼしの保険）。
    func liveEntries() -> [(sessionId: String, cwd: String?, startedAt: Date)] {
        for (sid, l) in live {
            if l.pid == nil { fillMissingPid(sid) }
            if let pid = live[sid]?.pid, kill(pid, 0) != 0, errno == ESRCH { unregister(sessionId: sid) }
        }
        return live.values.map { ($0.sessionId, $0.cwd, $0.startedAt) }
    }

    /// 登録した時点では pid が引けなかった entry（Claude Code がまだ実行中セッションの情報を
    /// 書いていなかった等）を、死活確認のたびに補う。引けなければ従来どおり live 扱い
    /// （生きているターミナルを落とすと spawn が同じ session を持ち、会話が二股になる）。
    private func fillMissingPid(_ sessionId: String) {
        guard let l = live[sessionId], l.pid == nil,
              let found = Self.lookupClaudeProcess(sessionId: sessionId) else { return }
        register(sessionId: sessionId, cwd: nil, pid: found.pid, transcriptPath: nil,
                 inboxSocket: l.inboxSocket == nil ? found.inboxSocket : nil)
    }

    /// claude の PID（とその 2 代上まで）から、生きているターミナルのセッションを引く。
    /// `.mcp.json` の中継は claude が直に起こすが、シェルを挟む版があっても引けるよう親もたどる。
    func sessionId(forPid pid: Int32, ancestors: Int = 2) -> String? {
        var cur = pid
        for _ in 0...ancestors {
            guard cur > 1 else { return nil }
            if let l = live.values.first(where: { $0.pid == cur }) { return l.sessionId }
            guard let parent = Self.parentPid(of: cur) else { return nil }
            cur = parent
        }
        return nil
    }

    private static func parentPid(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let ppid = Int32(info.pbi_ppid)
        return ppid > 0 ? ppid : nil
    }

    /// ターミナル側でターン進行中の session。SessionHub の generating と合わせて running にする。
    func generatingSessionIds() -> Set<String> {
        sessionIds { $0.generating }
    }

    /// ターミナルに選択肢（許可確認・質問・計画の承認）が出たままの session。list_sessions の awaiting に使う。
    func awaitingSessionIds() -> Set<String> {
        sessionIds { $0.prompts.contains { !$0.answered } }
    }

    /// バックグラウンドのサブエージェントが動いている session（バックグラウンドのコマンドだけでは数えない）。
    /// list_sessions の background に使う。
    func backgroundSessionIds() -> Set<String> {
        sessionIds { $0.subagents.hasRunningAgents }
    }

    /// 条件に合う session。プロセスが消えたもの（SessionEnd を出さずに claude が終わった: ウィンドウを閉じた・落ちた・
    /// kill された）は台帳から落としてから返す（落とさないと running / awaiting とペインの状態が残り続ける）。
    private func sessionIds(where match: (Live) -> Bool) -> Set<String> {
        for sid in live.values.filter(match).map(\.sessionId) {
            if live[sid]?.pid == nil { fillMissingPid(sid) }
            if let pid = live[sid]?.pid, kill(pid, 0) != 0, errno == ESRCH { unregister(sessionId: sid) }
        }
        return Set(live.values.filter(match).map(\.sessionId))
    }

    /// サブエージェントのカードの全行（workflow_progress の JSON。subtype "workflow_snapshot"、kind "subagents"、epoch 付き）。
    /// 行が無くても agents: [] で返す（アプリが持っている幽霊行を消せるように）。台帳に無ければ nil。
    func subagentSnapshot(sessionId: String) -> String? {
        live[sessionId]?.subagents.snapshot(includeEmpty: true)
    }

    func cwd(for sessionId: String) -> String? { live[sessionId]?.cwd }

    func inboxSocket(for sessionId: String) -> String? {
        guard var l = live[sessionId] else { return nil }
        if let s = l.inboxSocket, !s.isEmpty { return s }
        // 登録時に sessions/<pid>.json がまだ無かった。いま引けたら覚える。
        guard let s = Self.lookupClaudeProcess(sessionId: sessionId)?.inboxSocket, !s.isEmpty else { return nil }
        l.inboxSocket = s
        live[sessionId] = l
        return s
    }

    /// hook の transcript_path が、その session の transcript（`<session_id>.jsonl`。ホームの中・シンボリック
    /// リンクでない自分のファイル）か。違えば nil（その session の transcript は読まない）。
    static func validTranscriptPath(_ raw: String?, sessionId: String, home: String = NSHomeDirectory()) -> String? {
        guard let raw, raw.hasPrefix("/"), !sessionId.isEmpty else { return nil }
        let path = (raw as NSString).standardizingPath
        guard (path as NSString).lastPathComponent == sessionId + ".jsonl",
              path.hasPrefix((home as NSString).standardizingPath + "/") else { return nil }
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return nil }
        }
        return path
    }

    /// 受け箱経由で送った発話とアプリ内ターミナルに打ち込んだ発話。UserPromptSubmit で同じ文が戻ってきたら二重表示しない。
    private var inboxSent: [String: [String]] = [:]
    /// アプリ内ターミナルに打ち込んだが、まだ UserPromptSubmit が来ていない送信（session ごとに最新の 1 件）。
    private var typedPending: [String: UUID] = [:]
    /// 打ち込んだ発話が届くのを待つ秒数。届かないのは、デスクトップが打ち込まなかった（claude が前面にいない）か、
    /// 入力欄が別の画面（/model の一覧など）になっていたとき。
    private static let typedDeliveryTimeout: UInt64 = 20
    /// ターミナル側のターンが終わるのを待ってから打ち込む上限の秒数。テストが短くする。
    private var typingBusyWait: TimeInterval = 900
    /// session ごとの打ち込みの列の末尾。前の発話が届く（UserPromptSubmit）か、届かないと決まるまで次を打たない
    /// （続けて送った発話の順が入れ替わったり、前の発話のターンで出た選択肢を次の Enter で選んだりしないように）。
    private var typingTail: [String: Task<Void, Never>] = [:]
    /// sessions/<pid>.json の status を読む。テストが差し替える。
    private var readStatus: @Sendable (Int32, String) -> String? = { pid, sid in
        ClaudeTerminalRegistry.claudeStatus(pid: pid, sessionId: sid)
    }

    func setTypingBusyWait(_ seconds: TimeInterval) {
        typingBusyWait = seconds
    }

    func setStatusReader(_ reader: @escaping @Sendable (Int32, String) -> String?) {
        readStatus = reader
    }
    /// 受け箱に置いたが、まだ UserPromptSubmit が来ていない送信（session ごとに最新の 1 件）。
    private var inboxPending: [String: UUID] = [:]
    /// inboxPending の本文（保留のカードに出す）。
    private var inboxPendingText: [String: String] = [:]
    /// 受け箱の発話が届くのを待つ秒数。受け手の設定で承認待ち・拒否になると hook が一切来ない。
    private static let inboxDeliveryTimeout: UInt64 = 30
    /// ターミナルの保留ダイアログが自動で取り消されるまでの秒数（Claude Code の既定 5 分）に余裕を足したもの。
    /// これを過ぎても届かなければ、時間切れかターミナルで Deny されたとみなしてカードを閉じる。
    private static let heldExpiry: UInt64 = 315

    /// transcript の今の末尾。受け箱に書く前に取り、保留の印（すぐ書かれる）を読み落とさないようにする。
    func transcriptEnd(sessionId: String) -> UInt64? {
        guard let path = live[sessionId]?.transcriptPath else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
    }

    /// 受け箱は受け手の設定で承認待ち・拒否になりうるので、ここではターンを始めない
    /// （届けば UserPromptSubmit が来て、そこで始まる）。
    /// YOLO（bypassPermissions）のターミナルは、送り主の権限モードを名乗らない発話を保留する（Claude Code の
    /// cross-session messaging の安全機構）。保留は transcript に「Held peer message」と書かれるので、それを見張る。
    func noteInboxPrompt(sessionId: String, text: String, transcriptOffset: UInt64?) {
        var sent = inboxSent[sessionId, default: []]
        // 受け手が前後の空白・改行を詰めて hook に渡しても照合できるよう、詰めた形で覚える。
        sent.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if sent.count > 20 { sent.removeFirst() }
        inboxSent[sessionId] = sent
        let token = UUID()
        inboxPending[sessionId] = token
        inboxPendingText[sessionId] = text
        ensureTail(sessionId: sessionId, from: transcriptOffset)
        Task { [weak self] in await self?.watchInboxDelivery(sessionId: sessionId, token: token) }
    }

    /// 受け箱の発話が届かないまま時間が経ったら、送った側（WS の notePromptSent）が立てた
    /// 「考え中」を error + done で戻す。ターミナルで別のターンが進行中の間は、その終了まで
    /// 待たされるので計時を延ばす。
    private func watchInboxDelivery(sessionId: String, token: UUID) async {
        while true {
            try? await Task.sleep(nanoseconds: Self.inboxDeliveryTimeout * 1_000_000_000)
            guard inboxPending[sessionId] == token, var l = live[sessionId] else { return }
            if l.generating { continue }
            inboxPending.removeValue(forKey: sessionId)
            inboxPendingText.removeValue(forKey: sessionId)
            l.sessions.removeAll { $0.isClosed }
            live[sessionId] = l
            let mid = UUID().uuidString
            // 保留なら transcript の印で先にカードになっている。ここに来るのは、保留の印も UserPromptSubmit も
            // 無いまま時間が経ったとき（受け手が crossSessionInbound = refuse、受け箱が詰まっている等）。
            for s in l.sessions {
                s.push(SessionEvent(
                    type: .error, agentId: "claude", sessionId: sessionId, messageId: mid, toolUseId: nil,
                    content: "ターミナルの Claude Code がこの発話を受け付けませんでした（\(Self.inboxDeliveryTimeout) 秒たっても反応がありません）。ターミナルを確かめてください。届かないときは、ターミナルで直接入力するか、`buddy-claude --resume \(sessionId)` で起動し直すと iPhone から確実に届きます。",
                    toolName: nil, metadata: nil))
                // 応答の無い done。SessionHub は購読者ゼロでも応答の通知を送らない。
                s.push(SessionEvent(
                    type: .done, agentId: "claude", sessionId: sessionId, messageId: mid, toolUseId: nil,
                    content: nil, toolName: nil, metadata: ["errored": "true"]))
            }
            WebSocketServer.wslog("claude-inbox not delivered within \(Self.inboxDeliveryTimeout)s session=\(sessionId.prefix(8))…")
            return
        }
    }

    private func consumeInboxEcho(sessionId: String, prompt: String) -> Bool {
        guard var sent = inboxSent[sessionId],
              let i = sent.firstIndex(where: { !$0.isEmpty && prompt.contains($0) }) else { return false }
        sent.remove(at: i)
        inboxSent[sessionId] = sent
        return true
    }

    // MARK: - アプリ内ターミナルへの打ち込み

    enum TypingOutcome: Equatable {
        /// 打ち込んだ。届けば UserPromptSubmit が来る。来なければ typedDeliveryTimeout 秒でエラーを返す。
        case typed
        /// ターミナルに選択肢（許可確認・質問・計画の承認・保留）か一覧（/model など）が出ている。打った Enter で選んで
        /// しまうので打たない。
        case dialogOpen
        /// ターミナル側のターンが typingBusyWait 秒たっても終わらない。
        case busy
        /// 打ち込めない（アプリ内ターミナルではない・デスクトップが古い・文が空か長すぎる・sessions のファイルで
        /// その claude だと確かめられない）。呼び元は channel・受け箱へ。
        case unavailable
    }

    /// 人がペアリング済みの端末の入力欄で打った発話を、デスクトップのアプリ内ターミナルで動く claude に打ち込む。
    /// キーボードで打ったのと同じ発話になる（受け箱だと「別のセッションからの依頼」として届き、承認や設定の変更が通らない）。
    /// 同じ session への打ち込みは 1 件ずつ、前の発話が届いてから順に行う（typingTail）。
    /// echo は UserPromptSubmit で戻ってきたときに照合する本文（二重表示しない）。
    func typePrompt(sessionId sid: String, text: String, echo: String) async -> TypingOutcome {
        let previous = typingTail[sid]
        let attempt = Task { () -> TypingOutcome in
            await previous?.value
            return await self.typeNow(sessionId: sid, text: text, echo: echo)
        }
        typingTail[sid] = Task {
            if await attempt.value == .typed { await self.waitTypedSettled(sessionId: sid) }
        }
        return await attempt.value
    }

    /// ターンの途中は許可確認などの選択肢がいつ出てもおかしくない（打ち込んだ Enter で選んでしまう）ので、終わるまで待つ。
    private func typeNow(sessionId sid: String, text: String, echo: String) async -> TypingOutcome {
        guard let keys = TerminalKeyPlan.typing(text) else { return .unavailable }
        let started = Date()
        while true {
            guard let pid = live[sid]?.pid,
                  let pty = await TerminalKeyRouter.shared.typingOwner(of: pid) else { return .unavailable }
            // 上の await の間に台帳が変わっていれば読み直す。
            guard let l = live[sid], l.pid == pid else { return .unavailable }
            // 状態は Claude Code が書く sessions/<pid>.json を正とする（質問の選択肢が出ている間も busy、/model などの
            // 一覧が開いている間は waiting）。この session のファイルで確かめられない（pid の使い回し・古い claude）なら
            // 打たない（台帳の pid が別のプロセスになっていても、そこへ打ち込まない）。
            guard let status = readStatus(pid, sid) else { return .unavailable }
            if l.prompts.contains(where: { !$0.answered }) || status == "waiting" { return .dialogOpen }
            switch status {
            // shell は、返事の後に裏のコマンド（dev サーバーなど）だけが動いている状態。入力欄は空いている
            // （docs/BACKGROUND_CONTROL_2026-10-21.md）。
            case "idle", "shell":
                // 打ち込むのと同じように整えた文で照合する（\r\n は \n になって戻ってくる）。
                let echoText = TerminalKeyPlan.sanitizedForTyping(echo).trimmingCharacters(in: .whitespacesAndNewlines)
                var sent = inboxSent[sid, default: []]
                sent.append(echoText)
                if sent.count > 20 { sent.removeFirst() }
                inboxSent[sid] = sent
                let token = UUID()
                typedPending[sid] = token
                await TerminalKeyRouter.shared.enqueue(.init(pid: pty, keys: keys, gapMs: TerminalKeyPlan.typingGapMs,
                                                             expectPid: pid, expectSession: sid))
                let command = Self.slashCommand(text)
                let keyCount = keys.count
                Task { [weak self] in
                    await self?.watchTypedDelivery(sessionId: sid, token: token, command: command, echo: echoText, keyCount: keyCount)
                }
                return .typed
            case "busy":
                break
            default:
                // 打ってよいか分からない状態（知らない値）。
                return .unavailable
            }
            if Date().timeIntervalSince(started) >= typingBusyWait { return .busy }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// 打ち込んだ発話が届く（UserPromptSubmit・PreToolUse・Stop）か、届かないと決まる（watchTypedDelivery）まで待つ。
    private func waitTypedSettled(sessionId sid: String) async {
        let started = Date()
        while typedPending[sid] != nil, Date().timeIntervalSince(started) < typingBusyWait {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// 先頭がコマンド名（`/compact` など）なら、その名前。`/Users/…` のようなパスはコマンドではない（普通の発話として届く）。
    static func slashCommand(_ text: String) -> String? {
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return first.range(of: "^/[A-Za-z0-9][A-Za-z0-9:_-]*$", options: .regularExpression) != nil ? first : nil
    }

    /// Claude Code が書く ~/.claude/sessions/<pid>.json の status（idle / busy / waiting / shell）。読めない・別の session の
    /// ファイル（pid の使い回し）のときは nil。claude 2.1.300 で実測: 許可確認と /model などの一覧の間は waiting
    /// （waitingFor が permission prompt・dialog open）、AskUserQuestion の選択肢の間は busy。入力欄の打ちかけ・`!` の
    /// bash モードでは idle のまま。
    private static func claudeStatus(pid: Int32, sessionId: String) -> String? {
        guard let r = ClaudeAgentsRegistry.readSession(home: FileManager.default.homeDirectoryForCurrentUser, pid: pid),
              r.sessionId == sessionId else { return nil }
        return r.status
    }

    /// 打ち込んだ発話が届かないまま時間が経ったら、送った側（WS の notePromptSent）が立てた「考え中」を戻す。
    /// ターミナルで別のターンが進んでいる間は、その後ろで待っているので計時を延ばす。
    /// コマンド（`/compact`・`/model` など）は発話にならず UserPromptSubmit が来ないので、短く待って打ち込んだことだけ伝える。
    /// デスクトップは 1 操作ずつ間をあけて書くので、操作の数だけ秒を足す（長い文を分けた貼り付けで早まって失敗にしない）。
    /// 届かなかった分の照合の文（echo）は消す（残すと、後でターミナルで打った同じ文を自分の送信と取り違えて隠す）。
    private func watchTypedDelivery(sessionId: String, token: UUID, command: String?, echo: String, keyCount: Int) async {
        let wait: UInt64 = (command == nil ? Self.typedDeliveryTimeout : 5) + UInt64(max(0, keyCount))
        while true {
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            guard typedPending[sessionId] == token, var l = live[sessionId] else { return }
            if l.generating { continue }
            typedPending.removeValue(forKey: sessionId)
            if let i = inboxSent[sessionId]?.firstIndex(of: echo) { inboxSent[sessionId]?.remove(at: i) }
            l.sessions.removeAll { $0.isClosed }
            live[sessionId] = l
            let mid = UUID().uuidString
            for s in l.sessions {
                if let command {
                    s.push(.assistantDelta("ターミナルに `\(command)` を打ち込みました。結果はターミナルに出ます。",
                                           agentId: "claude", sessionId: sessionId, messageId: mid))
                    s.push(.done(agentId: "claude", sessionId: sessionId, messageId: mid))
                } else {
                    s.push(SessionEvent(
                        type: .error, agentId: "claude", sessionId: sessionId, messageId: mid, toolUseId: nil,
                        content: "アプリ内ターミナルに打ち込もうとしましたが、Claude Code が受け付けませんでした（\(wait) 秒たっても反応がありません）。ターミナルの画面を確かめてください（Claude Code が終わっている、打ち込む途中で許可の確認や一覧が開いた、など。途中まで貼った文が入力欄に残っていることがあります）。",
                        toolName: nil, metadata: nil))
                    s.push(SessionEvent(
                        type: .done, agentId: "claude", sessionId: sessionId, messageId: mid, toolUseId: nil,
                        content: nil, toolName: nil, metadata: ["errored": "true"]))
                }
            }
            WebSocketServer.wslog("claude-pty no prompt within \(wait)s session=\(sessionId.prefix(8))… command=\(command ?? "-")")
            return
        }
    }

    /// iPhone がこの session を開いた。以後の hook イベントは直接この session へ。
    /// 溜まっていた backlog を先に流す。すでに別の session が attach 中なら、そちらに配った
    /// 進行中ターンの分を渡す（backlog を受け取った側が重複として捨てられても取りこぼさない）。
    func attach(_ session: ClaudeTerminalSession) {
        guard var l = live[session.sessionId] else { return }
        l.sessions.removeAll { $0.isClosed }
        let pending: [SessionEvent]
        if l.sessions.isEmpty {
            pending = l.backlog
            l.backlog.removeAll()
            l.delivered = pending
        } else {
            pending = l.delivered
        }
        l.sessions.append(session)
        live[session.sessionId] = l
        // 発話と本文は流し直さない（iPhone は開いた直後に transcript の全履歴を読む）ので、
        // ターンが進行中であることは本文の無い activity で伝える（考え中を出す）。
        if l.generating {
            session.push(.activity(agentId: "claude", sessionId: session.sessionId,
                                   messageId: l.currentMessageId ?? "system", text: ""))
        }
        for e in pending { session.push(e) }
        // サブエージェントのカードは backlog に残らない（Stop の後も動き、終わった結果も次の発話まで残す）ので、
        // 行があれば（動いているかに関係なく）今の全行を渡す。
        if !l.subagents.isEmpty, let snap = l.subagents.snapshot() {
            session.push(.workflowProgress(agentId: "claude", sessionId: session.sessionId, payloadJSON: snap))
        }
    }

    /// この session だけを外す。同じ sid に後から attach した別の session は外さない。
    func detach(_ session: ClaudeTerminalSession) {
        guard var l = live[session.sessionId] else { return }
        l.sessions.removeAll { $0 === session || $0.isClosed }
        if l.sessions.isEmpty { l.delivered.removeAll() }
        live[session.sessionId] = l
    }

    // MARK: - hook → SessionEvent

    /// Claude Code の http hook（POST body の JSON）を受け取り、SessionEvent に変換して流す。
    /// 返り値は処理したかどうか（未対応イベントは false。ログ用）。
    func ingest(_ hook: [String: Any], pane: String? = nil) -> Bool {
        guard let sid = Self.string(hook["session_id"]), !sid.isEmpty,
              let event = Self.string(hook["hook_event_name"]) else { return false }
        // サブエージェントの中の hook（main のスレッドは nil）。
        let subagentId = Self.subagentId(hook)
        // 内部の補助（Stop のたびの次の発話の候補づくり・バックグラウンドのエージェントの要約。agent_id があり、agent_type が
        // 空か無い）は最初に捨てる。行にも親のツール行にもペインの状態にも、受け箱の保留にも使わない。
        if SubagentTracker.isInternalHelper(agentId: subagentId, agentType: hook["agent_type"]) { return true }
        guard var l = live[sid] else {
            // SessionStart が先に来ていない（hook だけ設定されている等）。台帳に載せてから処理する。
            register(sessionId: sid, cwd: Self.string(hook["cwd"]), pid: nil,
                     transcriptPath: Self.string(hook["transcript_path"]))
            return ingest(hook, pane: pane)
        }
        if let pane { l.pane = pane }
        let agentId = "claude"
        var out: [SessionEvent] = []

        // ツールが実行された・ターンが終わった・次の発話が来た = ターミナルの選択肢は（どこかで）答えられた。
        // 閉じるのは同じスレッド（agent_id が同じ。main は nil）の選択肢だけ（並んで動くサブエージェントのツールで、
        // 親の選択肢を閉じない）。ツールの実行は同じツールの選択肢だけを閉じる。PreToolUse は選択肢より前に来るので数えない。
        var resolved: [SessionEvent] = []
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            resolved = resolvePrompts(&l, sessionId: sid, toolName: Self.string(hook["tool_name"]) ?? "", agentId: subagentId)
        case "SubagentStop":
            // 終わったサブエージェントの選択肢は、もう答えられない。
            if let subagentId { resolved = resolvePrompts(&l, sessionId: sid, agentId: subagentId) }
        case "Stop", "StopFailure", "UserPromptSubmit":
            // 保留のカードは閉じない（ターミナルのダイアログはターンとは別に残る。届いたら下で閉じる）。
            resolved = resolvePrompts(&l, sessionId: sid, agentId: nil)
        default:
            break
        }
        out.append(contentsOf: resolved)

        switch event {
        case "UserPromptSubmit":
            // ターミナルで打った発話か、知らせのターン（バックグラウンドの作業が終わって CLI が自分から始めたターン。
            // prompt は <task-notification> の塊だけ）。どちらも新しいターンの始まり。
            let text = Self.string(hook["prompt"]) ?? ""
            let shown = SubagentTracker.stripNotifications(text)
            let notification = text.contains("<task-notification>") && shown.isEmpty
            // 前のターンで閉じていないツール行（Stop が来ずに終わった分）は、中断として閉じる。
            out.append(contentsOf: Self.closeOpenTools(&l, sessionId: sid, status: "interrupted"))
            Self.startTurn(&l, notification: notification)
            // バックグラウンドの作業の完了の知らせは発話として届く。行を閉じ、吹き出しには出さない。
            for p in l.subagents.ingestNotifications(text) {
                out.append(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: p))
            }
            // 終わった行は新しいターンで捨てる（クライアントも送信で捨てる）。知らせのターンでは捨てない
            // （終わった結果をカードに残す。頼んだ人はまだ見ていない）。知らせを取り込んだ後に捨てる: SessionHub とアプリは、
            // 上の行の payload の後に届く下の user_message で捨てるので、同じ行が残る（先に捨てると、この発話で閉じた行が
            // トラッカーにだけ残り、接続のたびの subagentSnapshot がアプリの捨てた行を戻す）。
            if !notification { l.subagents.pruneFinished() }
            // iPhone から channel で送った分は、送った側が既に表示しているので流さない。
            if shown.contains("<channel source=\"buddy\"") {
                // 何もしない
            } else if consumeInboxEcho(sessionId: sid, prompt: shown) {
                // 受け箱の発話が届いた。保留のカードを出していれば閉じる。
                out.append(contentsOf: resolveHeld(&l, sessionId: sid))
            } else if !shown.isEmpty {
                out.append(.userMessage(shown, agentId: agentId, sessionId: sid))
            }

        case "MessageDisplay":
            // 行バッチ単位の本文。message 識別子ごとに 1 バブル。サブエージェントの本文は親の吹き出しに混ぜない。
            guard subagentId == nil else { break }
            let delta = Self.string(hook["delta"]) ?? ""
            let key = Self.string(hook["message_id"]) ?? Self.string(hook["messageId"])
                ?? Self.string(hook["turn_id"]) ?? l.currentMessageId ?? "turn"
            // 終わったターンの最後のメッセージが Stop より遅れて届いた（Stop の last_assistant_message で流し終えている）。
            if Self.isLateSettled(&l, key: key, delta: delta) {
                live[sid] = l
                return true
            }
            let mid: String
            if let existing = l.messageIds[key] { mid = existing }
            else {
                mid = l.currentMessageId.map { l.messageIds.isEmpty ? $0 : UUID().uuidString } ?? UUID().uuidString
                l.messageIds[key] = mid
                if l.currentMessageId == nil { l.currentMessageId = mid }
            }
            if !delta.isEmpty {
                l.chunks[key, default: []].append(delta)
                l.lastMessageKey = key
                out.append(.assistantDelta(delta, agentId: agentId, sessionId: sid, messageId: mid))
            }

        case "PreToolUse":
            let name = Self.string(hook["tool_name"]) ?? "tool"
            if let subagentId {
                // サブエージェントの中のツールは親のツール行に混ぜず、サブエージェントの行に出す。
                if l.subagents.contains(subagentId) {
                    if let p = l.subagents.hookTool(agentId: subagentId, agentType: Self.string(hook["agent_type"]),
                                                    toolName: name, input: hook["tool_input"]) {
                        out.append(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: p))
                    }
                    break
                }
                // 行にしていないもの（起動の PreToolUse を伴わない SubagentStart・知らない agent_id）は出さない。
                // SubagentStart を一度も受けていない（hook が古い install）ときだけ、今までどおり親のツール行に出す。
                if l.subagents.isIgnored(subagentId) || l.sawSubagentStart { break }
            } else {
                l.subagents.noteLaunch(toolName: name, input: hook["tool_input"],
                                       toolUseId: Self.string(hook["tool_use_id"]))
            }
            let id = Self.string(hook["tool_use_id"]) ?? UUID().uuidString
            let title = Self.toolTitle(name: name, input: hook["tool_input"])
            out.append(.toolStart(agentId: agentId, sessionId: sid, toolUseId: id,
                                  toolName: name, title: title, kind: "tool"))
            if subagentId == nil { l.openTools.append((id: id, name: name)) }

        case "PostToolUse", "PostToolUseFailure":
            let name = Self.string(hook["tool_name"]) ?? "tool"
            let toolUseId = Self.string(hook["tool_use_id"])
            let failed = event == "PostToolUseFailure"
            if let subagentId {
                // サブエージェントの中のツールは toolStart を出していない。ただ、起動（Agent の async_launched）と停止（TaskStop）は
                // tool_response に相手の id が入っているので、どのスレッドのものでもその行に効かせる。
                if !failed, SubagentTracker.isAgentTool(name) || name == "TaskStop" || name == "KillShell",
                   let p = l.subagents.hookToolResult(toolUseId: toolUseId, toolName: name,
                                                      input: hook["tool_input"], response: hook["tool_response"]) {
                    out.append(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: p))
                }
                if l.subagents.contains(subagentId) || l.subagents.isIgnored(subagentId) || l.sawSubagentStart { break }
            }
            let id = toolUseId ?? UUID().uuidString
            let summary = Self.preview(hook["tool_response"] ?? hook["error"], limit: 200)
            out.append(.toolEnd(agentId: agentId, sessionId: sid, toolUseId: id, toolName: name,
                                status: failed ? "failed" : "completed", summary: summary, durationMs: nil))
            guard subagentId == nil else { break }
            l.openTools.removeAll { $0.id == id }
            // バックグラウンドで起動したもの（run_in_background の Bash・Monitor・Agent の async_launched）は、終わるまで
            // カードの行で見せる。TaskStop は止めた行をすぐ stopped で閉じる（止めたシェルには完了の知らせが来ない）。
            if !failed, let p = l.subagents.hookToolResult(toolUseId: toolUseId, toolName: name,
                                                           input: hook["tool_input"], response: hook["tool_response"]) {
                out.append(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: p))
                ensureTail(sessionId: sid, from: nil)
            }

        case "SubagentStart":
            guard let subagentId else { break }
            l.sawSubagentStart = true
            if let p = l.subagents.hookStart(agentId: subagentId, agentType: Self.string(hook["agent_type"])) {
                out.append(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: p))
            }

        case "SubagentStop":
            // SubagentStop の background_tasks は、終わったサブエージェント自身を running のまま含むので照合に使わない
            // （照合は Stop の一覧だけ）。
            guard let subagentId else { break }
            if let p = l.subagents.hookStop(agentId: subagentId, agentType: Self.string(hook["agent_type"]),
                                            lastMessage: Self.string(hook["last_assistant_message"])) {
                out.append(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: p))
            }

        case "Stop", "StopFailure":
            // ターン完了。SessionHub はこれで generating を落とす。
            // StopFailure は API エラーでターンが終わったとき（このときは Stop が来ない）。
            let mid = l.currentMessageId ?? UUID().uuidString
            let interrupted = hook["buddy_interrupted"] as? Bool == true
            // Esc で中断したとき（pollInterrupt が送る）。前景のサブエージェントには SubagentStop が来ないので、ここで閉じる
            // （閉じないと行が「実行中」のまま残り、開き直すたびに考え中に戻る）。バックグラウンドのサブエージェントと
            // シェルは Esc では止まらない（実測。後から SubagentStop と知らせのターンが来る）ので閉じない。
            if interrupted, let p = l.subagents.abandonRunning(state: "stopped", includeShells: false, onlyForeground: true) {
                out.append(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: p))
            }
            // Stop hook はその時点で動いているバックグラウンドの作業の一覧を持つ。行の状態を合わせる。
            if let p = l.subagents.reconcile(backgroundTasks: hook["background_tasks"]) {
                out.append(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: p))
            }
            // 開いたままのツール行を閉じる（中断されたツールには PostToolUse も PostToolUseFailure も来ない）。
            let toolStatus = interrupted ? "interrupted" : (event == "StopFailure" ? "failed" : "completed")
            out.append(contentsOf: Self.closeOpenTools(&l, sessionId: sid, status: toolStatus))
            // 吹き出しの本文を last_assistant_message で確かめ、足りない分を done の前に流す
            // （最後の MessageDisplay は Stop より遅れて届くことがある）。
            if !interrupted, let last = Self.string(hook["last_assistant_message"]) {
                out.append(contentsOf: Self.settleLastMessage(&l, sessionId: sid, text: last, turnMessageId: mid))
            }
            if event == "StopFailure" {
                let detail = Self.preview(hook["error_details"] ?? hook["error"], limit: 200) ?? ""
                out.append(SessionEvent(
                    type: .error, agentId: agentId, sessionId: sid, messageId: mid, toolUseId: nil,
                    content: "ターミナルの Claude Code のターンがエラーで終了しました" + (detail.isEmpty ? "" : "（\(detail)）"),
                    toolName: nil, metadata: nil))
            }
            var done = SessionEvent.done(agentId: agentId, sessionId: sid, messageId: mid)
            // 知らせのターンの done（誰も頼んでいないターン。SessionHub はバックグラウンドの作業の完了として扱う）。
            if l.notificationTurn { done = done.addingMetadata(["origin": "task-notification"]) }
            out.append(done)
            l.currentMessageId = nil
            l.messageIds.removeAll()
            l.chunks.removeAll()
            l.lastMessageKey = nil
            l.generating = false
            l.notificationTurn = false

        case "PermissionRequest", "Notification":
            // 選択肢そのものは ingestPermission がカードにする（/claude/hook がそちらへ回す）。
            // 「許可が要ります」の知らせはカードと重なるので流さない。それ以外の知らせは表示だけ。
            if Self.string(hook["notification_type"]) == "permission_prompt" || event == "PermissionRequest" { break }
            if let msg = Self.string(hook["message"]) ?? Self.string(hook["title"]) {
                out.append(.activity(agentId: agentId, sessionId: sid,
                                     messageId: l.currentMessageId ?? "system", text: msg))
            }

        case "SessionEnd":
            live[sid] = l
            unregister(sessionId: sid)
            return true

        default:
            live[sid] = l
            return false
        }

        // ターンが動いている印（main のスレッドの発話・ツール・Stop）があれば、受け箱の発話・打ち込んだ発話は届いた
        // （かターミナル側のターンの後ろで待っている）。どちらでも Stop の done で送った側の「考え中」は戻る。
        // サブエージェントの hook（ターンの外でも動く）と、本文・承認待ちの通知は数えない。
        if subagentId == nil, event == "UserPromptSubmit" || event == "PreToolUse" || event == "Stop" {
            inboxPending.removeValue(forKey: sid)
            typedPending.removeValue(forKey: sid)
        }

        distribute(out, to: &l)
        live[sid] = l
        if event == "UserPromptSubmit" { watchInterrupt(sessionId: sid) }
        if l.subagents.hasRunning { ensureTail(sessionId: sid, from: nil) }
        notePaneState(l, event: event, hook: hook, resolvedPrompt: !resolved.isEmpty)
        return true
    }

    // MARK: - ターミナルの選択肢（許可確認・質問・計画の承認）

    /// PermissionRequest hook。ターミナルに選択肢が出た。iPhone / デスクトップにカードで出す。
    /// 答え方は先に調べる（channel が繋がっているか・デスクトップのターミナルで動いているか）。
    /// hook には何も返さない（返すとターミナルの選択肢が出なくなる）。ターミナルでも iPhone でも選べ、先に選んだ方が効く。
    func ingestPermission(_ hook: [String: Any], pane: String? = nil) async -> Bool {
        guard let sid = Self.string(hook["session_id"]), !sid.isEmpty else { return false }
        if live[sid] == nil {
            register(sessionId: sid, cwd: Self.string(hook["cwd"]), pid: nil,
                     transcriptPath: Self.string(hook["transcript_path"]))
        }
        if let pane { live[sid]?.pane = pane }
        if let l = live[sid] { notePaneState(l, event: "PermissionRequest", hook: hook) }
        // claude --bg のワーカーの承認には答えられない。カードも push も出さない（一覧と会話のカードの「承認待ち」で見せる）。
        if await isBackgroundWorker(sid) { return true }
        let pty = await TerminalKeyRouter.shared.ptyOwner(of: live[sid]?.pid)
        let channel = await ClaudeChannelInbox.shared.isConnected(sid)
        guard var l = live[sid] else { return false }

        let name = Self.string(hook["tool_name"]) ?? "tool"
        let input = hook["tool_input"] as? [String: Any] ?? [:]
        let suggestions = hook["permission_suggestions"] as? [[String: Any]] ?? []
        // サブエージェントの選択肢なら、その agent_id（main は nil）。
        let subagentId = Self.subagentId(hook)
        // channel の依頼で先にカードを出していれば重ねない（同じ選択肢が 2 つの口から届く）。
        if l.prompts.contains(where: { !$0.fromHook && !$0.answered && $0.toolName == name
                                       && Date().timeIntervalSince($0.createdAt) < 10 }) {
            return true
        }
        // 同じスレッドの前の選択肢は答えられている（次の選択肢が出た）。
        var out = resolvePrompts(&l, sessionId: sid, agentId: subagentId)
        let isQuestion = name == "AskUserQuestion" && !ClaudeControlProtocol.questions(in: input).isEmpty
        let kind = isQuestion ? "userInput" : (name == "ExitPlanMode" ? "plan" : "approval")
        // 質問と計画は channel では答えられない（許可の中継は許可確認だけ）。
        let via = pty != nil ? "pty" : (kind == "approval" && channel ? "channel" : "none")
        var prompt = TerminalPrompt(
            requestId: "term-" + String(UUID().uuidString.prefix(8)).lowercased(), kind: kind, toolName: name,
            input: input, hasSuggestions: !suggestions.isEmpty, via: via, fromHook: true, createdAt: Date())
        prompt.agentId = subagentId
        l.prompts.append(prompt)
        out.append(Self.card(for: prompt, sessionId: sid, description: nil))
        distribute(out, to: &l)
        let watched = !l.sessions.isEmpty
        live[sid] = l
        WebSocketServer.wslog("claude-terminal prompt \(prompt.requestId) tool=\(name) via=\(via) session=\(sid.prefix(8))…")
        if !watched { await Self.pushPrompt(prompt, sessionId: sid) }
        return true
    }

    /// channel（buddy-channel.py）が受けた許可の依頼。PermissionRequest hook のカードに依頼 id を結びつける。
    /// hook が入っていない（古い hooks 設定）ときは、channel の情報だけでカードを出す。
    func channelPermission(sessionId sid: String, requestId: String, toolName: String,
                           description: String?, inputPreview: String?) async {
        guard var l = live[sid] else { return }
        // 結び付けるのは、同じツールで、少し前に出した、引数の要約が食い違わないカードだけ（ツール名だけで結ぶと、
        // 前のカードへの答えが後から来た別の依頼に使われる）。先に答えた verdict は、引数の要約が一致したときに 1 回だけ使う。
        let now = Date()
        if let i = l.prompts.lastIndex(where: { $0.kind == "approval" && $0.toolName == toolName
                                                && $0.channelRequestId == nil
                                                && now.timeIntervalSince($0.createdAt) < Self.channelBindWindow
                                                && Self.inputPreviewMatches($0.input, inputPreview) != false }) {
            let verdict = l.prompts[i].verdict
            if verdict == nil || Self.inputPreviewMatches(l.prompts[i].input, inputPreview) == true {
                l.prompts[i].channelRequestId = requestId
                l.prompts[i].verdict = nil
                live[sid] = l
                if let verdict {
                    await ClaudeChannelInbox.shared.postPermission(sessionId: sid, requestId: requestId, behavior: verdict)
                }
                return
            }
            // 答えを確かめられない古い verdict は捨て、この依頼は改めてカードで聞く。
            l.prompts[i].verdict = nil
        }
        var out = resolvePrompts(&l, sessionId: sid, agentId: nil)
        var prompt = TerminalPrompt(
            requestId: "term-" + String(UUID().uuidString.prefix(8)).lowercased(), kind: "approval", toolName: toolName,
            input: [:], hasSuggestions: false, via: "channel", fromHook: false, createdAt: Date())
        prompt.channelRequestId = requestId
        l.prompts.append(prompt)
        let detail = [description, inputPreview].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        out.append(Self.card(for: prompt, sessionId: sid, description: detail))
        distribute(out, to: &l)
        let watched = !l.sessions.isEmpty
        live[sid] = l
        if !watched { await Self.pushPrompt(prompt, sessionId: sid) }
    }

    /// hook のカードと channel の依頼を結び付けてよい時間（これより古いカードには結び付けない）。
    static let channelBindWindow: TimeInterval = 30

    /// channel の input_preview（引数の JSON を途中で切ったもの）が hook の tool_input と食い違わないか。
    /// 一致 = true、食い違い = false、どちらかが無くて確かめられない = nil。
    /// Swift の辞書はキーの順を持たないので、preview のキーを順に読み、そのキーの値の JSON と前から比べる。
    static func inputPreviewMatches(_ input: [String: Any], _ preview: String?) -> Bool? {
        func compact(_ s: String) -> String { String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init)) }
        var want = compact(preview ?? "")
        for suffix in ["…", "..."] where want.hasSuffix(suffix) { want = String(want.dropLast(suffix.count)) }
        guard !want.isEmpty, !input.isEmpty else { return nil }
        var rest = Substring(want)
        guard rest.first == "{" else { return nil }
        rest = rest.dropFirst()
        var compared = 0
        while !rest.isEmpty, compared < 160 {
            // "key":
            guard rest.first == "\"" else { return false }
            var key = ""
            var idx = rest.index(after: rest.startIndex)
            var closed = false
            while idx < rest.endIndex {
                let c = rest[idx]
                if c == "\\" {
                    let next = rest.index(after: idx)
                    guard next < rest.endIndex else { break }
                    key.append(rest[next])
                    idx = rest.index(after: next)
                    continue
                }
                if c == "\"" { closed = true; break }
                key.append(c)
                idx = rest.index(after: idx)
            }
            guard closed else { break }   // キーの途中で切れている
            rest = rest[rest.index(after: idx)...]
            guard rest.first == ":" else { break }
            rest = rest.dropFirst()
            guard !rest.isEmpty else { break }
            guard let value = input[key],
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                  let json = String(data: data, encoding: .utf8) else { return false }
            let have = compact(json)
            let n = min(rest.count, have.count)
            guard n > 0, rest.prefix(n) == Substring(have.prefix(n)) else { return false }
            compared += n
            rest = rest.dropFirst(n)
            guard n == have.count, rest.first == "," else { break }
            rest = rest.dropFirst()
        }
        return compared > 0 ? true : nil
    }

    /// iPhone / デスクトップで選んだ答え。channel かキー入力でターミナルへ届ける。
    /// 返り値は届けられなかったときの理由（nil = 届けた / もう答えられている）。
    func answer(sessionId sid: String, requestId: String, decision: String, meta: [String: String]) async -> String? {
        guard var l = live[sid], let i = l.prompts.firstIndex(where: { $0.requestId == requestId }) else { return nil }
        let prompt = l.prompts[i]
        guard !prompt.answered else { return nil }
        switch prompt.via {
        case "channel":
            let behavior = decision.hasPrefix("allow") ? "allow" : "deny"
            l.prompts[i].answered = true
            if prompt.channelRequestId == nil { l.prompts[i].verdict = behavior }
            live[sid] = l
            if let rid = prompt.channelRequestId {
                await ClaudeChannelInbox.shared.postPermission(sessionId: sid, requestId: rid, behavior: behavior)
            }
            return nil
        case "pty":
            guard let pty = await TerminalKeyRouter.shared.ptyOwner(of: live[sid]?.pid) else {
                return "デスクトップのターミナルに届けられませんでした。ターミナルで選んでください。"
            }
            let keys: [String]?
            switch prompt.kind {
            case "held":
                keys = TerminalKeyPlan.held(decision: decision)
            case "userInput":
                let qs = ClaudeControlProtocol.questions(in: prompt.input)
                keys = TerminalKeyPlan.questions(qs, answers: TerminalKeyPlan.answerLists(meta, fallback: decision, questions: qs))
            case "plan":
                keys = TerminalKeyPlan.plan(decision: decision)
            default:
                keys = TerminalKeyPlan.approval(decision: decision, hasSuggestions: prompt.hasSuggestions)
            }
            guard let keys else { return "すべての質問に答えてください。" }
            guard var cur = live[sid], let j = cur.prompts.firstIndex(where: { $0.requestId == requestId }),
                  !cur.prompts[j].answered else { return nil }
            cur.prompts[j].answered = true
            // 取り消しは hook が来ないので、ここでカードを閉じる（届けるなら UserPromptSubmit で閉じる）。
            if prompt.kind == "held" && !decision.hasPrefix("allow") {
                cur.prompts.remove(at: j)
                distribute([.actionResolved(agentId: "claude", sessionId: sid, requestId: requestId)], to: &cur)
            }
            live[sid] = cur
            await TerminalKeyRouter.shared.enqueue(.init(pid: pty, keys: keys, gapMs: 800))
            WebSocketServer.wslog("claude-terminal answer \(requestId) via pty keys=\(keys.count) session=\(sid.prefix(8))…")
            return nil
        default:
            return "この選択肢はターミナルで選んでください。"
        }
    }

    /// Esc を送ったターン（session → currentMessageId）。同じターンに 2 回送らないため。
    private var interruptedTurns: [String: String] = [:]

    /// iPhone / デスクトップの停止。デスクトップのアプリ内ターミナルで動いていれば、そのペインに Esc を送る
    /// （ターミナルで Esc を押したのと同じ）。ターンを閉じるのは、transcript の中断の印を見る watchInterrupt。
    /// Esc を 2 回続けると Claude Code は巻き戻しの画面を開くので、1 つのターンには 1 回だけ送る。
    /// 返り値は届けられなかったときの理由（nil = 送った / 止めるターンが無い）。
    func interrupt(sessionId sid: String) async -> String? {
        if await isBackgroundWorker(sid) { return ClaudeBackgroundSession.interruptText }
        guard let l = live[sid], l.generating, let turn = l.currentMessageId else { return nil }
        guard interruptedTurns[sid] != turn else { return nil }
        guard let pty = await TerminalKeyRouter.shared.ptyOwner(of: l.pid) else {
            return "デスクトップのターミナルで動いていないため、ここからは止められません。ターミナルで Esc を押してください。"
        }
        interruptedTurns[sid] = turn
        await TerminalKeyRouter.shared.enqueue(.init(pid: pty, keys: [TerminalKeyPlan.esc], gapMs: 0))
        WebSocketServer.wslog("claude-terminal interrupt via pty session=\(sid.prefix(8))…")
        return nil
    }

    /// iPhone / デスクトップの /new。デスクトップのアプリ内ターミナルで動いていれば、そのペインに `/clear` と Enter を
    /// キー入力で送る（ターミナルで打ったのと同じ。Claude Code は新しい session_id で始め直し、今の session は SessionEnd で閉じる）。
    /// 受け箱・channel で送ると Claude への文になるだけで、ターミナルのコマンドとしては動かない。
    /// 返り値は届けられなかったときの理由（nil = 送った）。
    func startNewConversation(sessionId sid: String) async -> String? {
        guard let l = live[sid] else { return "ターミナルの Claude Code が見つかりません。" }
        // 作業中・選択肢が出ている間に打つと、入力欄ではなく選択肢や次の発話の予約に入ってしまう。
        if l.generating { return "ターミナルの Claude Code が作業中です。止めてから /new を送ってください。" }
        if l.prompts.contains(where: { !$0.answered }) {
            return "ターミナルに選択肢が出ています。答えてから /new を送ってください。"
        }
        guard let pty = await TerminalKeyRouter.shared.ptyOwner(of: l.pid) else {
            return "デスクトップのターミナルで動いていないため、ここからは新しい会話にできません。ターミナルで /clear を打ってください。"
        }
        await TerminalKeyRouter.shared.enqueue(.init(pid: pty, keys: TerminalKeyPlan.newConversation, gapMs: 800))
        WebSocketServer.wslog("claude-terminal new conversation via pty session=\(sid.prefix(8))…")
        return nil
    }

    /// 出しているカードのうち、agentId のスレッド（main は nil）のものを閉じる（toolName を渡すとそのツールの分だけ）。
    /// 保留のカードは resolveHeld で閉じる。
    private func resolvePrompts(_ l: inout Live, sessionId sid: String, toolName: String? = nil,
                                agentId: String?) -> [SessionEvent] {
        let matches: (TerminalPrompt) -> Bool = {
            $0.kind != "held" && $0.agentId == agentId && (toolName == nil || $0.toolName == toolName)
        }
        let closing = l.prompts.filter(matches)
        guard !closing.isEmpty else { return [] }
        l.prompts.removeAll(where: matches)
        return closing.map { .actionResolved(agentId: "claude", sessionId: sid, requestId: $0.requestId) }
    }

    /// 保留のカードを閉じる（発話が届いた・時間切れ）。
    private func resolveHeld(_ l: inout Live, sessionId sid: String) -> [SessionEvent] {
        let closing = l.prompts.filter { $0.kind == "held" }
        guard !closing.isEmpty else { return [] }
        l.prompts.removeAll { $0.kind == "held" }
        return closing.map { .actionResolved(agentId: "claude", sessionId: sid, requestId: $0.requestId) }
    }

    // MARK: - transcript の見張り（受け箱の保留・バックグラウンドの作業の完了）

    /// 見張っている session → 次に読む位置。
    private var tailOffsets: [String: UInt64] = [:]
    /// 見張る理由（受け箱の保留・動いている行）が無くなった時刻。tailGrace 秒たったら見張りを終える。
    private var tailIdleSince: [String: Date] = [:]
    private static let tailInterval: UInt64 = 1
    /// 最後の行が閉じた後も読み続ける秒数。Stop の reconcile が結果なしで閉じた行の、後から積まれる知らせ
    /// （失敗・終了コード）を落とさないため。
    private static let tailGrace: TimeInterval = 10

    /// transcript の見張りを始める（動いていれば、読む位置を from まで戻すだけ）。
    /// 見張るのは、受け箱の発話の行方が分からない間と、バックグラウンドの作業が動いている間だけ。
    private func ensureTail(sessionId sid: String, from offset: UInt64?) {
        guard let path = live[sid]?.transcriptPath else { return }
        if let cur = tailOffsets[sid] {
            if let offset, offset < cur { tailOffsets[sid] = offset }
            return
        }
        let start = offset ?? (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        tailOffsets[sid] = start
        Task { [weak self] in await self?.tail(sessionId: sid, path: path) }
    }

    private func tail(sessionId sid: String, path: String) async {
        while true {
            try? await Task.sleep(nanoseconds: Self.tailInterval * 1_000_000_000)
            // 保留のカードの答え方（キー入力で答えられるか）は先に調べる（以降は await を挟まずに台帳を書き換える）。
            let pty = inboxPending[sid] != nil ? await TerminalKeyRouter.shared.ptyOwner(of: live[sid]?.pid) : nil
            guard let offset = tailOffsets[sid], var l = live[sid], l.transcriptPath == path, keepTailing(sid, l) else {
                tailOffsets.removeValue(forKey: sid)
                tailIdleSince.removeValue(forKey: sid)
                return
            }
            let (lines, next) = Self.readLines(path: path, from: offset)
            tailOffsets[sid] = next
            var out: [SessionEvent] = []
            for obj in lines {
                let type = obj["type"] as? String
                if type == "system", let text = obj["content"] as? String, text.hasPrefix("Held peer message"),
                   inboxPending[sid] != nil {
                    out.append(contentsOf: held(&l, sessionId: sid, pty: pty))
                } else if type == "queue-operation", obj["operation"] as? String == "enqueue",
                          let text = obj["content"] as? String {
                    // バックグラウンドの作業の完了の知らせ。積まれた時点で書かれる（発話として届くのはターンの後）。
                    for p in l.subagents.ingestNotifications(text) {
                        out.append(.workflowProgress(agentId: "claude", sessionId: sid, payloadJSON: p))
                    }
                }
            }
            guard !out.isEmpty else { continue }
            distribute(out, to: &l)
            live[sid] = l
            notePaneBackground(l)
        }
    }

    /// 見張りを続けるか。受け箱の発話の行方が分からない間と、バックグラウンドの作業が動いている間。
    /// どちらも無くなってからも tailGrace 秒は読む。
    private func keepTailing(_ sid: String, _ l: Live) -> Bool {
        if inboxPending[sid] != nil || l.subagents.hasRunning {
            tailIdleSince.removeValue(forKey: sid)
            return true
        }
        guard let since = tailIdleSince[sid] else {
            tailIdleSince[sid] = Date()
            return true
        }
        return Date().timeIntervalSince(since) < Self.tailGrace
    }

    /// 受け箱の発話がターミナルで保留された。iPhone の「考え中」を終わらせ、保留のカードを出す。
    /// デスクトップのアプリ内ターミナルなら、カードから Deliver / Deny をキー入力で選べる。
    private func held(_ l: inout Live, sessionId sid: String, pty: Int32?) -> [SessionEvent] {
        let text = inboxPendingText.removeValue(forKey: sid) ?? ""
        inboxPending.removeValue(forKey: sid)
        var out = resolveHeld(&l, sessionId: sid)
        let prompt = TerminalPrompt(
            requestId: "held-" + String(UUID().uuidString.prefix(8)).lowercased(), kind: "held",
            toolName: "BuddyOS", input: ["text": text], hasSuggestions: false, via: pty != nil ? "pty" : "none",
            fromHook: true, createdAt: Date())
        l.prompts.append(prompt)
        // 送った側が立てた「考え中」を戻す。応答の通知は送らない。
        out.append(SessionEvent(type: .done, agentId: "claude", sessionId: sid, messageId: UUID().uuidString,
                                toolUseId: nil, content: nil, toolName: nil, metadata: ["errored": "true"]))
        out.append(Self.heldCard(prompt, sessionId: sid, text: text))
        WebSocketServer.wslog("claude-inbox held by terminal \(prompt.requestId) via=\(prompt.via) session=\(sid.prefix(8))…")
        if l.sessions.allSatisfy({ $0.isClosed }) {
            let body = "ターミナルの Claude Code が iPhone からの発話を保留しています。ターミナルで「Deliver」を選ぶと届きます"
            let payload = ["kind": "approval_request", "agentId": "claude", "sessionId": sid,
                           "requestId": prompt.requestId, "bridgeId": KeyStore.loadOrCreateBridgeId()]
            Task { await PushService.shared.broadcast(title: "claude", body: body, payload: payload) }
        }
        let requestId = prompt.requestId
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.heldExpiry * 1_000_000_000)
            await self?.expireHeld(sessionId: sid, requestId: requestId)
        }
        return out
    }

    /// 保留のカードが出たまま時間が経った。ターミナル側で時間切れになったか、Deny されている。
    private func expireHeld(sessionId sid: String, requestId: String) {
        guard var l = live[sid], let i = l.prompts.firstIndex(where: { $0.requestId == requestId }) else { return }
        l.prompts.remove(at: i)
        distribute([
            .actionResolved(agentId: "claude", sessionId: sid, requestId: requestId),
            SessionEvent(type: .error, agentId: "claude", sessionId: sid, messageId: UUID().uuidString, toolUseId: nil,
                         content: "ターミナルで保留されていた発話は届きませんでした（時間切れか、ターミナルで Deny されました）。もう一度送ってください。",
                         toolName: nil, metadata: nil),
        ], to: &l)
        live[sid] = l
    }

    /// 保留のカード。キー入力で答えられるなら 届ける / 取り消す、答えられないなら見せるだけ。
    private static func heldCard(_ p: TerminalPrompt, sessionId sid: String, text: String) -> SessionEvent {
        let fix = "毎回止まらないようにするには、ターミナルの Claude Code を `buddy-claude` で起動します（`buddy-claude --resume \(sid)` で続きから）。"
        let subtitle: String
        if p.via == "pty" {
            subtitle = "このターミナルは許可の確認を省くモード（bypassPermissions）なので、ほかから届いた発話を保留しています。届けるとこのまま Claude に渡ります。\n\n" + fix
        } else {
            subtitle = "このターミナルは許可の確認を省くモード（bypassPermissions）なので、ほかから届いた発話を保留しています。ターミナルで「Deliver this message to Claude」を選ぶと届きます（5 分で自動的に取り消されます）。\n\n" + fix
        }
        var meta: [String: String] = [
            "requestId": p.requestId, "kind": "approval", "allowsOther": "0",
            "source": "terminal", "toolName": p.toolName, "answerVia": p.via,
            "answerable": p.via == "none" ? "0" : "1",
        ]
        let options: [(String, String, String)] = [
            ("届ける", "この発話を Claude に渡します", "allow"),
            ("取り消す", "届けずに捨てます", "deny"),
        ]
        meta["option_count"] = String(options.count)
        for (i, o) in options.enumerated() {
            meta["option_\(i)_title"] = o.0
            meta["option_\(i)_subtitle"] = o.1
            meta["option_\(i)_value"] = o.2
        }
        let quoted = SubagentTracker.toolActivity(name: "", input: ["description": text])
            .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        return .actionRequest(agentId: "claude", sessionId: sid, messageId: p.requestId,
                              title: "ターミナルで保留されています" + (quoted.isEmpty ? "" : "：「\(quoted)」"),
                              subtitle: subtitle, metadata: meta)
    }

    /// path の offset 以降の、書き終わった行（JSON）と、次に読む位置。
    private static func readLines(path: String, from offset: UInt64) -> (lines: [[String: Any]], next: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], offset) }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return ([], offset) }
        // 縮んだ（作り直された）ら末尾から読み直す。
        guard end >= offset else { return ([], end) }
        guard end > offset, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(end - offset)),
              let lastNewline = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let complete = data[data.startIndex...lastNewline]
        let lines = complete.split(separator: 0x0A).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
        return (lines, offset + UInt64(complete.count))
    }

    /// 選択肢 → カード。source=terminal と答え方（answerVia / answerable）を metadata に足す。
    private static func card(for p: TerminalPrompt, sessionId sid: String, description: String?) -> SessionEvent {
        let req = ClaudeControlProtocol.ToolRequest(
            requestId: p.requestId, toolName: p.toolName, input: p.input,
            suggestions: p.hasSuggestions ? [["type": "addRules"]] : [])
        var base: SessionEvent
        switch p.kind {
        case "userInput":
            base = ClaudeControlProtocol.questionCard(req, agentId: "claude", sessionId: sid)
                ?? ClaudeControlProtocol.approvalCard(req, agentId: "claude", sessionId: sid)
        case "plan":
            base = ClaudeControlProtocol.planCard(req, agentId: "claude", sessionId: sid)
        default:
            base = ClaudeControlProtocol.approvalCard(req, agentId: "claude", sessionId: sid)
        }
        var meta = base.metadata ?? [:]
        meta["source"] = "terminal"
        meta["toolName"] = p.toolName
        meta["answerVia"] = p.via
        meta["answerable"] = p.via == "none" ? "0" : "1"
        if let description, !description.isEmpty { meta["subtitle"] = description }
        if p.kind == "plan" {
            // ターミナルの計画の承認は 3 択（自動で編集 / 1 つずつ承認 / 計画を続ける）。
            let options: [(String, String, String)] = [
                ("自動で編集して進める", "ファイルの編集は確認せずに進めます", "allowAuto"),
                ("1 つずつ確認して進める", "編集のたびに確認します", "allow"),
                ("計画を続ける", "まだ実装に進みません", "deny"),
            ]
            for k in meta.keys where k.hasPrefix("option_") { meta.removeValue(forKey: k) }
            meta["option_count"] = String(options.count)
            for (i, o) in options.enumerated() {
                meta["option_\(i)_title"] = o.0
                meta["option_\(i)_subtitle"] = o.1
                meta["option_\(i)_value"] = o.2
            }
        }
        if p.kind == "approval" && p.via == "channel" {
            // 許可の中継は 許可 / 拒否 の 2 つだけ（「このセッションでは承認」は届けられない）。
            let options: [(String, String, String)] = [("承認", "一度だけ許可", "allow"), ("非承認", "実行しない", "deny")]
            for k in meta.keys where k.hasPrefix("option_") { meta.removeValue(forKey: k) }
            meta["option_count"] = String(options.count)
            for (i, o) in options.enumerated() {
                meta["option_\(i)_title"] = o.0
                meta["option_\(i)_subtitle"] = o.1
                meta["option_\(i)_value"] = o.2
            }
        }
        if p.via == "none" { meta["allowsOther"] = "0" }
        return SessionEvent(type: .actionRequest, agentId: "claude", sessionId: sid, messageId: p.requestId,
                            toolUseId: nil, content: base.content, toolName: p.toolName, metadata: meta)
    }

    /// 誰もこの会話を開いていないときは、通知で呼び出す（SessionHub の承認要求の通知と同じ形）。
    private static func pushPrompt(_ p: TerminalPrompt, sessionId sid: String) async {
        let body: String
        switch p.kind {
        case "userInput": body = "ターミナルの Claude Code が質問しています"
        case "plan": body = "ターミナルの Claude Code が計画の承認を待っています"
        default: body = "ターミナルの Claude Code が「\(p.toolName)」の許可を待っています"
        }
        await PushService.shared.broadcast(
            title: "claude", body: body,
            payload: ["kind": "approval_request", "agentId": "claude", "sessionId": sid,
                      "requestId": p.requestId, "bridgeId": KeyStore.loadOrCreateBridgeId()])
    }

    /// attach 中の session へ配る。誰も見ていなければ、進行中ターンの分だけ backlog に取っておく。
    private func distribute(_ out: [SessionEvent], to l: inout Live) {
        // 流し直し用に取っておくのは進行中ターンの分だけ（Stop 後は generating=false で捨てる）。
        // 発話と本文は除く。transcript に書かれていて、開いた直後の全履歴は live の行と突き合わせない
        // ので、流すと同じ質問と回答が二重に並ぶ（UserPromptSubmit の発話は attach 中の session にだけ配る）。
        let replay = out.filter { $0.type != .userMessage && $0.type != .assistantDelta }
        l.sessions.removeAll { $0.isClosed }
        if l.sessions.isEmpty {
            l.delivered.removeAll()
            if l.generating {
                l.backlog.append(contentsOf: replay)
                if l.backlog.count > Self.backlogLimit {
                    l.backlog.removeFirst(l.backlog.count - Self.backlogLimit)
                }
            } else {
                l.backlog.removeAll()
            }
        } else {
            for s in l.sessions {
                for e in out { s.push(e) }
            }
            if l.generating {
                l.delivered.append(contentsOf: replay)
                if l.delivered.count > Self.backlogLimit {
                    l.delivered.removeFirst(l.delivered.count - Self.backlogLimit)
                }
            } else {
                l.delivered.removeAll()
            }
        }
    }

    /// デスクトップのアプリ内ターミナルで動いているなら、ペインの状態（TerminalPaneStatus）を書く。
    /// 動いているバックグラウンドの作業の数は、状態が変わらない hook でも毎回書く。
    /// resolvedPrompt: この hook で選択肢を閉じた（サブエージェントの選択肢は、そのサブエージェントのツールの実行・終わりで閉じる）。
    private func notePaneState(_ l: Live, event: String, hook: [String: Any], resolvedPrompt: Bool = false) {
        guard let pane = l.pane else { return }
        let status = TerminalPaneStatus.shared
        let background = (agents: l.subagents.runningAgentCount, shells: l.subagents.runningShellCount)
        let backgroundOnly = l.subagents.runningBackgroundOnlyAgentCount
        let current = status.state(pane: pane, sessionId: l.sessionId)
        var state = TerminalPaneStatus.state(event: event, hook: hook, current: current)
        // サブエージェントの hook は状態を変えないが、その選択肢が閉じてほかに出ていなければ attention を外す
        // （main のターンが動いていれば作業中、終わっていれば idle。終わった 1 回には数えない）。
        if state == nil, resolvedPrompt, current == "attention", !l.prompts.contains(where: { $0.kind != "held" }) {
            state = l.generating ? "working" : "idle"
        }
        guard let state else {
            // main の本文はターンの動きとして覚える（UserPromptSubmit の来ないターンも、次の Stop の done で 1 回に数える）。
            status.note(pane: pane, sessionId: l.sessionId,
                        activity: event == "MessageDisplay" && Self.subagentId(hook) == nil, background: background,
                        backgroundOnly: backgroundOnly)
            return
        }
        // 返事が終わった（done）ときだけ、その返事の文を持たせる（デスクトップの音声会話が読み上げる）。
        let reply = state == "done" && event == "Stop" ? Self.string(hook["last_assistant_message"]) : nil
        status.set(pane: pane, state: state, sessionId: l.sessionId, cwd: l.cwd, agent: "claude", reply: reply,
                   background: background, backgroundOnly: backgroundOnly)
    }

    /// 動いているバックグラウンドの作業の数だけをペインに書く（transcript の知らせで行が閉じたとき）。
    private func notePaneBackground(_ l: Live) {
        guard let pane = l.pane else { return }
        TerminalPaneStatus.shared.note(pane: pane, sessionId: l.sessionId,
                                       background: (agents: l.subagents.runningAgentCount,
                                                    shells: l.subagents.runningShellCount),
                                       backgroundOnly: l.subagents.runningBackgroundOnlyAgentCount)
    }

    // MARK: - ターン

    /// 新しいターンを始める（UserPromptSubmit・channel の送信）。前のターンの吹き出しと、流し直しの分を捨てる
    /// （前のターンの残り（Stop が来ずに終わった分）は transcript にあるので流し直さない）。
    private static func startTurn(_ l: inout Live, notification: Bool) {
        l.currentMessageId = UUID().uuidString
        l.messageIds.removeAll()
        l.chunks.removeAll()
        l.lastMessageKey = nil
        l.settled = nil
        l.backlog.removeAll()
        l.delivered.removeAll()
        l.generating = true
        l.notificationTurn = notification
    }

    /// 今のターンで toolStart を出したまま toolEnd の来ていない main のツール行を閉じる（status は completed /
    /// interrupted / failed）。中断されたツールには PostToolUse も PostToolUseFailure も来ない（実測）。
    private static func closeOpenTools(_ l: inout Live, sessionId sid: String, status: String) -> [SessionEvent] {
        let open = l.openTools
        l.openTools.removeAll()
        return open.map {
            .toolEnd(agentId: "claude", sessionId: sid, toolUseId: $0.id, toolName: $0.name,
                     status: status, summary: nil, durationMs: nil)
        }
    }

    /// Stop の後に遅れて届いた MessageDisplay を捨ててよい秒数（実測は Stop の 0〜0.2 秒後）。
    private static let lateDisplayWindow: TimeInterval = 3

    /// Stop の last_assistant_message（ターンの最後のメッセージの本文）で吹き出しを確かめ、足りない分の delta を返す。
    /// 最後の MessageDisplay は Stop より遅れて届くことがある（実測 18 回中 5 回）。
    ///   - 最後に本文が届いた吹き出しの行バッチが、どれもそのメッセージの一部 → 同じメッセージ。頭の部分なら残りを流す
    ///     （届いた順が入れ替わっていたら、足しても直らないので流さない）
    ///   - そうでない（まだ 1 つも届いていない）→ 新しい吹き出し（ターンの最初の吹き出しならターンの messageId）で全部を流す
    /// どちらも、そのメッセージの MessageDisplay が後から届いたら捨てる（settled）。
    private static func settleLastMessage(_ l: inout Live, sessionId sid: String, text: String,
                                          turnMessageId: String) -> [SessionEvent] {
        guard !text.isEmpty else { return [] }
        // 同じメッセージの Stop が重ねて届いた（その後に本文が 1 つも来ていない）。流し直さない。
        if l.lastMessageKey == nil, l.settled?.text == text { return [] }
        var keys: Set<String> = []
        var out: [SessionEvent] = []
        if let key = l.lastMessageKey, let received = l.chunks[key], let mid = l.messageIds[key],
           received.allSatisfy({ chunk in
               let t = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
               return t.isEmpty || text.contains(t)
           }) {
            keys.insert(key)
            let streamed = received.joined()
            if text.count > streamed.count, text.hasPrefix(streamed) {
                out.append(.assistantDelta(String(text.dropFirst(streamed.count)), agentId: "claude", sessionId: sid,
                                           messageId: mid))
            }
        } else {
            let mid = l.messageIds.isEmpty ? turnMessageId : UUID().uuidString
            out.append(.assistantDelta(text, agentId: "claude", sessionId: sid, messageId: mid))
        }
        l.settled = SettledMessage(text: text, keys: keys, at: Date())
        return out
    }

    /// Stop の後に遅れて届いた、終わったターンの最後のメッセージの MessageDisplay か（Stop の last_assistant_message で
    /// 流し終えている）。次のターンが始まる前の lateDisplayWindow 秒の間で、識別子を知っているもの、または
    /// まだ見ていないメッセージで本文がそのメッセージの一部のもの。
    private static func isLateSettled(_ l: inout Live, key: String, delta: String) -> Bool {
        guard var s = l.settled, !l.generating, Date().timeIntervalSince(s.at) < lateDisplayWindow else { return false }
        if s.keys.contains(key) { return true }
        let t = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard l.messageIds[key] == nil, !t.isEmpty, s.text.contains(t) else { return false }
        s.keys.insert(key)
        l.settled = s
        return true
    }

    /// transcript を見に行く間隔（秒）。ターン中だけ。
    private static let interruptPollInterval: UInt64 = 3

    /// Esc で中断したターンには Stop も StopFailure も来ない（Claude Code の仕様）。中断すると
    /// transcript に「[Request interrupted by user…]」の user 行が書かれるので、ターン中はそれを
    /// 見張り、書かれたら Stop と同じくターンを閉じる（generating と送った側の「考え中」を戻す）。
    /// 見るのはターン開始時点より後ろだけ（前のターンの中断を拾わない）。
    private func watchInterrupt(sessionId: String) {
        guard let l = live[sessionId], let path = l.transcriptPath, let turn = l.currentMessageId else { return }
        let offset = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        Task { [weak self] in await self?.pollInterrupt(sessionId: sessionId, turn: turn, path: path, offset: offset) }
    }

    private func pollInterrupt(sessionId: String, turn: String, path: String, offset: UInt64) async {
        var offset = offset
        while true {
            try? await Task.sleep(nanoseconds: Self.interruptPollInterval * 1_000_000_000)
            // Stop / 次のターンの開始 / 台帳から外れた、のどれかなら見張りは終わり。
            guard let l = live[sessionId], l.generating, l.currentMessageId == turn else { return }
            let (interrupted, next) = Self.scanInterrupt(path: path, from: offset)
            offset = next
            guard interrupted else { continue }
            WebSocketServer.wslog("claude-terminal turn interrupted (transcript) session=\(sessionId.prefix(8))…")
            _ = ingest(["session_id": sessionId, "hook_event_name": "Stop", "buddy_interrupted": true])
            return
        }
    }

    /// transcript の offset 以降（書き終わった行だけ）に Esc 中断の印の user 行があるか。
    /// next は次に読み始める位置。
    private static func scanInterrupt(path: String, from offset: UInt64) -> (interrupted: Bool, next: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (false, offset) }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return (false, offset) }
        guard end > offset else { return (false, end) }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(end - offset)),
              let lastNewline = data.lastIndex(of: 0x0A) else { return (false, offset) }
        let complete = data[data.startIndex...lastNewline]
        let next = offset + UInt64(complete.count)
        for line in complete.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "user", obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any] else { continue }
            if isInterruptMarker(message["content"]) { return (true, next) }
        }
        return (false, next)
    }

    /// Claude Code が中断時に書く user 行（本文が「[Request interrupted by user]」または
    /// 「[Request interrupted by user for tool use]」）か。ツール結果の中身は見ない。
    private static func isInterruptMarker(_ content: Any?) -> Bool {
        let marker = "[Request interrupted by user"
        if let s = content as? String { return s.hasPrefix(marker) }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { ($0["type"] as? String) == "text" && (($0["text"] as? String)?.hasPrefix(marker) ?? false) }
    }

    // MARK: - helpers

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// サブエージェントの中の hook なら、その agent_id（main のスレッドは nil）。
    private static func subagentId(_ hook: [String: Any]) -> String? {
        guard let id = string(hook["agent_id"]), !id.isEmpty else { return nil }
        return id
    }

    /// Claude Code が実行中の対話セッションごとに書く ~/.claude/sessions/<pid>.json から、
    /// session_id に対応する claude 本体の pid と受け箱を引く。無い（古い Claude Code）・
    /// 読めない場合は nil（従来どおり pid 無しで載せる）。*.key は読まない。
    private static func lookupClaudeProcess(sessionId: String) -> (pid: Int32, inboxSocket: String?)? {
        // 壊れたファイル（末尾に } が余るなど）も読め、異常終了で残ったファイル・pid が別のプロセスに使い回されたファイルは除く
        // （BACKGROUND_CONTROL §7.1）。同じ session を resume した別プロセスがあれば新しい方。
        ClaudeAgentsRegistry.lookupProcess(sessionId: sessionId)
    }

    /// tool_input から 1 行の見出しを作る（コマンドやパスを優先）。
    static func toolTitle(name: String, input: Any?) -> String {
        guard let dict = input as? [String: Any] else { return name }
        for k in ["command", "file_path", "path", "pattern", "url", "query", "prompt", "description"] {
            if let v = dict[k] as? String, !v.isEmpty { return preview(v, limit: 120) ?? name }
        }
        return name
    }

    static func preview(_ v: Any?, limit: Int) -> String? {
        guard let v else { return nil }
        let s: String
        if let str = v as? String { s = str }
        else if let data = try? JSONSerialization.data(withJSONObject: v), let str = String(data: data, encoding: .utf8) { s = str }
        else { s = String(describing: v) }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}

/// iPhone → ターミナルの Claude Code への受け箱。
///
/// ターミナルの claude が起動した channel サーバ（scripts/buddy-channel.py）が
/// `GET /claude/channel/poll` で long-poll して取りに来る。poll が来ている間だけ
/// 「送信できる」とみなす（channel フラグ無しで起動された claude は poll しない）。
actor ClaudeChannelInbox {
    static let shared = ClaudeChannelInbox()

    /// channel に渡すもの。発話（text）か、許可の中継の答え（permission）。
    enum Item: Sendable {
        case text(String)
        case permission(requestId: String, behavior: String)
    }

    private var queues: [String: [Item]] = [:]
    private var waiters: [String: (token: UUID, continuation: CheckedContinuation<[Item], Never>)] = [:]
    private var lastSeen: [String: Date] = [:]

    /// channel サーバが直近で取りに来ているか。poll は返った直後に張り直すので隙間は短い。
    /// 長く取ると、閉じたターミナル宛てに送った発話が受け箱に入ったまま消える。
    func isConnected(_ sessionId: String) -> Bool {
        if waiters[sessionId] != nil { return true }
        guard let t = lastSeen[sessionId] else { return false }
        return Date().timeIntervalSince(t) < 10
    }

    /// ターミナル終了。待っている poll は空で返し、未配達分は捨てる（以後は spawn が受ける）。
    func forget(_ sessionId: String) {
        if let w = waiters.removeValue(forKey: sessionId) { w.continuation.resume(returning: []) }
        queues.removeValue(forKey: sessionId)
        lastSeen.removeValue(forKey: sessionId)
    }

    func post(sessionId: String, text: String) {
        enqueue(sessionId: sessionId, .text(text))
    }

    /// 許可の中継の答え（behavior = allow / deny）。channel が notifications/claude/channel/permission で返す。
    func postPermission(sessionId: String, requestId: String, behavior: String) {
        enqueue(sessionId: sessionId, .permission(requestId: requestId, behavior: behavior))
    }

    private func enqueue(sessionId: String, _ item: Item) {
        if let w = waiters.removeValue(forKey: sessionId) {
            w.continuation.resume(returning: [item])
        } else {
            queues[sessionId, default: []].append(item)
        }
    }

    /// 溜まっていれば即返す。無ければ timeout 秒まで待つ（空配列で返る）。
    func poll(sessionId: String, timeout: TimeInterval) async -> [Item] {
        lastSeen[sessionId] = Date()
        if let q = queues.removeValue(forKey: sessionId), !q.isEmpty { return q }
        // 同じ session の古い poll が残っていれば空で返して入れ替える。
        if let old = waiters.removeValue(forKey: sessionId) { old.continuation.resume(returning: []) }
        let token = UUID()
        let result = await withCheckedContinuation { (c: CheckedContinuation<[Item], Never>) in
            waiters[sessionId] = (token, c)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(sessionId: sessionId, token: token)
            }
        }
        lastSeen[sessionId] = Date()
        return result
    }

    private func expire(sessionId: String, token: UUID) {
        guard let w = waiters[sessionId], w.token == token else { return }
        waiters.removeValue(forKey: sessionId)
        w.continuation.resume(returning: [])
    }
}

/// ターミナルで動いているセッションへの attach。events は hook 由来。
///
/// send() は channel 実装が入るまで届け先が無い。黙って捨てるとユーザーには
/// 「送ったのに何も起きない」に見えるので、明示的にエラーを返す。
final class ClaudeTerminalSession: AgentSession, @unchecked Sendable {
    private(set) var sessionId: String
    let events: AsyncThrowingStream<SessionEvent, Error>
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private let agentId: String
    private var didEmitStarted = false
    private let lock = NSLock()
    private var closed = false

    var supportsMidTurnInjection: Bool { false }

    init(agentId: String, sessionId: String) {
        self.agentId = agentId
        self.sessionId = sessionId
        var c: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { c = $0 }
        self.continuation = c
        // SessionHub は sessionStarted で key を確定させる。attach は既知の id なので即出す。
        continuation.yield(.sessionStarted(agentId: agentId, sessionId: sessionId))
        didEmitStarted = true
    }

    func push(_ event: SessionEvent) {
        lock.lock(); let isClosed = closed; lock.unlock()
        guard !isClosed else { return }
        continuation.yield(event)
    }

    /// 送れなかったことを伝え、送った側（WS の notePromptSent）が立てた「考え中」を戻す。
    private func fail(_ message: String) {
        let mid = UUID().uuidString
        continuation.yield(SessionEvent(type: .error, agentId: agentId, sessionId: sessionId, messageId: mid,
                                        toolUseId: nil, content: message, toolName: nil, metadata: nil))
        continuation.yield(SessionEvent(type: .done, agentId: agentId, sessionId: sessionId, messageId: mid,
                                        toolUseId: nil, content: nil, toolName: nil, metadata: ["errored": "true"]))
    }

    /// mainagent・定期の見回り・定期実行の文。受け箱で送り、Claude Code に「別のセッションから」と分かる形で届ける
    /// （本人の承認としては扱わせない）。
    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        await send(text, skills: skills, attachments: attachments, typedByUser: false)
    }

    /// typedByUser: 人がペアリング済みの端末（iPhone など）の入力欄で打った発話（WebSocketServer.dispatch が渡す）。デスクトップの
    /// アプリ内ターミナルで動いていれば、受け箱ではなくターミナルに打ち込む（キーボードで打ったのと同じ発話になる）。
    func send(_ text: String, skills: [String], attachments: [BridgeAttachment], typedByUser: Bool) async {
        // /new（/clear・/reset）は発話として送っても効かないので、キー入力で打つ。
        if skills.isEmpty, attachments.isEmpty, Self.isNewConversationCommand(text) {
            let mid = UUID().uuidString
            if let problem = await ClaudeTerminalRegistry.shared.startNewConversation(sessionId: sessionId) {
                continuation.yield(SessionEvent(type: .error, agentId: agentId, sessionId: sessionId, messageId: mid,
                                                toolUseId: nil, content: problem, toolName: nil, metadata: nil))
                continuation.yield(SessionEvent(type: .done, agentId: agentId, sessionId: sessionId, messageId: mid,
                                                toolUseId: nil, content: nil, toolName: nil, metadata: ["errored": "true"]))
            } else {
                continuation.yield(.assistantDelta(
                    "ターミナルで新しい会話を始めました。続きは、会話の一覧に出る新しい会話から開いてください。",
                    agentId: agentId, sessionId: sessionId, messageId: mid))
                continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: mid))
            }
            return
        }
        // ターミナルには本文しか届かないので、添付と skill はここで本文に展開する（黙って落とさない）。
        // 画像は本文に載せられないので、ファイルに書き出してパスを添える（受け手の Claude が開いて見る）。
        var imageFiles: [URL?] = []
        for attachment in attachments {
            imageFiles.append(attachment.kind == .image
                ? await AttachmentStore.shared.exportFile(name: attachment.name, mime: attachment.mime, data: attachment.data)
                : nil)
        }
        let prompt = Self.promptText(text: text, skills: skills, attachments: attachments, files: imageFiles)
        // 人が打った発話で、デスクトップのアプリ内ターミナルなら打ち込む。ターン完了は Stop hook の done で伝わる。
        if typedByUser {
            let typed = Self.promptText(text: text, skills: skills, attachments: attachments, files: imageFiles, typed: true)
            // エコー判定は contains なので、本文があれば元の本文で照合する（添付だけなら展開後）。
            switch await ClaudeTerminalRegistry.shared.typePrompt(sessionId: sessionId, text: typed, echo: text.isEmpty ? typed : text) {
            case .typed:
                WebSocketServer.wslog("claude-pty typed session=\(sessionId.prefix(8))… chars=\(typed.count)")
                return
            case .dialogOpen:
                fail("ターミナルに選択肢か一覧（許可の確認・質問・/model など）が出ているので、打ち込みませんでした。カードかターミナルで答えるか閉じてから、もう一度送ってください。")
                return
            case .busy:
                fail("ターミナルの Claude Code が作業を続けているので、打ち込みませんでした。終わってから、もう一度送ってください。")
                return
            case .unavailable:
                break
            }
        }
        // channel サーバが取りに来ていれば受け箱に置く。ターン完了は Stop hook の done で伝わる。
        if await ClaudeChannelInbox.shared.isConnected(sessionId) {
            await ClaudeTerminalRegistry.shared.noteChannelPrompt(sessionId: sessionId)
            await ClaudeChannelInbox.shared.post(sessionId: sessionId, text: prompt)
            WebSocketServer.wslog("claude-channel queued session=\(sessionId.prefix(8))… chars=\(prompt.count)")
            return
        }
        // 普通に起動した claude でも cross-session messaging の受け箱には送れる。
        // 別セッションからのメッセージとして扱われ、受け手の設定（crossSessionInbound /
        // 権限モード）で届く・承認待ち・拒否が決まる。YOLO のセッションでは承認待ちになる。
        if let sock = await ClaudeTerminalRegistry.shared.inboxSocket(for: sessionId) {
            // 保留の印は書いた直後に transcript に載るので、書く前の末尾から見張る。
            let offset = await ClaudeTerminalRegistry.shared.transcriptEnd(sessionId: sessionId)
            do {
                try ClaudeInboxSocket.post(text: prompt, socketPath: sock)
                // エコー判定は contains なので、本文があれば元の本文で照合する（添付だけなら展開後）。
                await ClaudeTerminalRegistry.shared.noteInboxPrompt(sessionId: sessionId, text: text.isEmpty ? prompt : text,
                                                                    transcriptOffset: offset)
                WebSocketServer.wslog("claude-inbox posted session=\(sessionId.prefix(8))… chars=\(prompt.count)")
                return
            } catch {
                WebSocketServer.wslog("claude-inbox post failed session=\(sessionId.prefix(8))…: \(error)")
            }
        }
        // 送った側（WS の notePromptSent）が「考え中」を立てているので、done で戻す。
        // 応答の無い done なので、SessionHub が購読者ゼロで応答の通知を送らないよう印を付ける。
        let mid = UUID().uuidString
        continuation.yield(SessionEvent(
            type: .error, agentId: agentId, sessionId: sessionId, messageId: mid,
            toolUseId: nil,
            content: "このセッションはターミナルで開かれていて、いまは閲覧のみです。iPhone から送るには、ターミナルの Claude Code を `buddy-claude` で起動し直すか（`buddy-claude --resume \(sessionId)` で続きから）、ターミナルで `/buddy` を実行してください。",
            toolName: nil, metadata: nil
        ))
        continuation.yield(SessionEvent(
            type: .done, agentId: agentId, sessionId: sessionId, messageId: mid, toolUseId: nil,
            content: nil, toolName: nil, metadata: ["errored": "true"]
        ))
    }

    /// 新しい会話を始めるコマンドか（Claude Code では /new・/reset は /clear の別名）。
    static func isNewConversationCommand(_ text: String) -> Bool {
        ["/new", "/clear", "/reset"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// 添付と skill を本文に展開する（spawn 側 ClaudeCodeSession.promptText と同じ整形）。
    /// files: attachments と同じ並びで、画像を書き出したファイル（無ければ nil）。画像の目印の後ろに
    /// 「(file: パス)」を付ける（HeadlessCliSession と同じ。WebSocketServer.enrichHistory が履歴で一緒に消す）。
    /// typed: ターミナルに打ち込む文。skill の行を `/` で始めない（Claude Code が `/skill` をコマンドとして読み、
    /// 「Unknown command: /skill」になる。2.1.300 で実測）。
    static func promptText(text: String, skills: [String], attachments: [BridgeAttachment], files: [URL?] = [],
                           typed: Bool = false) -> String {
        var sections: [String] = []
        if !skills.isEmpty {
            sections.append(typed ? "Use these skills: \(skills.joined(separator: ", "))" : "/skill \(skills.joined(separator: ","))")
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
        // 本文が空（添付・skill だけ）なら空の節を足さない（末尾が空行で終わり、エコー照合がずれる）。
        if !text.isEmpty { sections.append(text) }
        return sections.joined(separator: "\n\n")
    }

    /// デスクトップのアプリ内ターミナルで動いていれば Esc で止める。それ以外のターミナルには届かない。
    func interrupt() async {
        guard let problem = await ClaudeTerminalRegistry.shared.interrupt(sessionId: sessionId) else { return }
        push(SessionEvent(type: .error, agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString,
                          toolUseId: nil, content: problem, toolName: nil, metadata: nil))
    }

    /// ターミナルに出ている選択肢への答え（channel の許可中継か、デスクトップのターミナルへのキー入力で届ける）。
    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {
        guard let problem = await ClaudeTerminalRegistry.shared.answer(
            sessionId: sessionId, requestId: requestId, decision: decision, meta: answers) else { return }
        push(SessionEvent(type: .error, agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString,
                          toolUseId: nil, content: problem, toolName: nil, metadata: nil))
    }

    /// サブエージェントのカードの全行（subtype "workflow_snapshot"。行が無くても agents: []）。SessionHub が接続のたびと
    /// turn_status_request で送る。ターミナルの台帳から外れていれば nil。
    func subagentSnapshot() async -> String? {
        await ClaudeTerminalRegistry.shared.subagentSnapshot(sessionId: sessionId)
    }

    /// ターミナルがまだ生きているか。false なら WS 側はこの session を捨てて spawn で取り直す。
    func isTerminalAlive() async -> Bool {
        if isClosed { return false }
        return await ClaudeTerminalRegistry.shared.isLive(sessionId)
    }

    fileprivate var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// ターミナル側が終了した（SessionEnd）。購読者には done を出して、以後は spawn へ。
    func terminalEnded() {
        lock.lock(); let isClosed = closed; lock.unlock()
        guard !isClosed else { return }
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString))
        continuation.finish()
        lock.lock(); closed = true; lock.unlock()
    }

    func close() async {
        lock.lock(); let was = closed; closed = true; lock.unlock()
        if !was { continuation.finish() }
        await ClaudeTerminalRegistry.shared.detach(self)
    }
}

/// Claude Code の cross-session messaging の受け箱（Unix ソケット）へ 1 通書く。
/// 形式は Claude Code 本体のヘルプの例どおり 1 行 1 JSON。認証行は付けない
/// （他セッションからの投稿として受け手の inbound 制御に従わせる）。
enum ClaudeInboxSocket {
    struct PostError: Error, CustomStringConvertible {
        let description: String
    }

    static func post(text: String, socketPath: String) throws {
        var payload = try JSONSerialization.data(withJSONObject: [
            "type": "user", "message": ["role": "user", "content": text]
        ] as [String: Any])
        payload.append(0x0A)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PostError(description: "socket() failed errno=\(errno)") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else { throw PostError(description: "socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { _ = strncpy($0, socketPath, maxLen - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else { throw PostError(description: "connect failed errno=\(errno)") }
        // 受け箱の相手が自分の uid のプロセスかを確かめる（別のユーザーが置いたソケットに書かない）。
        var cred = xucred()
        var credLen = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLen) == 0,
              cred.cr_version == XUCRED_VERSION else {
            throw PostError(description: "peer credentials unavailable errno=\(errno)")
        }
        guard cred.cr_uid == getuid() else { throw PostError(description: "peer uid mismatch") }
        try payload.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { throw PostError(description: "write failed errno=\(errno)") }
                off += n
            }
        }
    }
}
