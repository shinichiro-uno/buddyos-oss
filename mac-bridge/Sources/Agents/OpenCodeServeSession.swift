import Foundation

/// `opencode serve`(HTTP) 上の1論理セッション。`AgentSession` に準拠。
///
/// プロセスは OpenCodeServeClient が1本(常駐サーバ)だけ持ち、このクラスはその上の
/// 1セッション(sessionId)に対応する。ストリーミングイベントはクライアントの SSE ポンプ
/// (`GET /global/event`) から `handleServeEvent` へルーティングされ、ここで opencode の
/// part ベースのイベントを BuddyOS の SessionEvent に翻訳して continuation に流す。
///
/// send() は `POST /session/{id}/message` を **await せず** 投げる(同 POST はターン完了
/// までブロックするが、差分は並行して SSE で届くため)。ターンの終端は SSE の
/// `session.idle` と POST の復帰の早い方で判定し .done を出す。どちらも前ターンの
/// 遅れた分が次ターンを閉じないよう、世代番号と「現ターンの user message を観測したか」で絞る。
///
/// 自分が送っていない新しい user message（同じ serve に繋いだ TUI の発言、裏で動いていたサブエージェントの
/// 結果を opencode が差し込んだ synthetic な発言）は、別のターンとして開いて本文と done を流す。
/// サブエージェント（task）の行は docs/BACKGROUND_WORK_2026-10-21.md §3.6。
final class OpenCodeServeSession: AgentSession, @unchecked Sendable, SessionOverridable {
    let agentId = "opencode"
    let sessionId: String
    let events: AsyncThrowingStream<SessionEvent, Error>

    private weak var client: OpenCodeServeClient?
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private let lock = NSLock()
    // セッションの作業ディレクトリ。opencode はセッションの実行・中断・保留中の承認/質問を
    // ディレクトリ毎のインスタンスで持つため、送信/中断/応答 API に `?directory=` として渡す
    // (nil はサーバの cwd)。
    let directory: String?

    // 現在のアシスタントテキストバブル(1ターン内で tool を挟むと分割される)
    private var currentBubbleId: String?
    /// 無人実行（cron）での承認要求への自動回答（"once" / "reject"）。nil = iPhone に出して待つ。
    /// 答える人がいないので、出したままだとターンが終わらない。
    var unattendedReply: String?
    private var hadToolSinceLastMessage = false
    // ターンを閉じたか(done を出した)。始めは閉じている(自分の send() か、ほかの画面の発言で開く)。
    private var didYieldDone = true

    // ターン世代。send()/interrupt()/ほかの画面のターンで進める。POST の完了ハンドラは送信時の世代が
    // 現在と一致するときだけターンを閉じる(前ターンの遅い POST 復帰が次ターンを閉じないように)。
    private var turnGen = 0
    // 投げた POST のうち、まだ自分の user message を観測していないものの世代(古い順)。ターンを閉じた後に
    // 届いた新しい user message が、中断した自分の送信のものか、ほかの画面の発言かを見分ける。
    private var postsAwaitingUser: [Int] = []
    // 自分が送っていない発言で開いたターン(ほかの画面の発言・synthetic な差し込み)の user messageID。
    // 自分のターンなら nil。
    private var remoteUserMessageId: String?
    // そのターンの発言を流したか(ほかの画面の発言は 1 回だけ流す)。
    private var remoteTurnEchoed = false
    // そのターンが、裏で動いていたサブエージェントの結果の差し込みで始まった(知らせのターン)。
    private var remoteTurnIsNotification = false
    // ほかの画面のターンとして開く発言の新しさ。これより前に作られた発言の再 publish(summary の更新等)は開かない。
    private static let remoteTurnFreshness: TimeInterval = 120
    // messageID -> role("user"/"assistant")、assistant messageID -> parentID(応答元の user messageID)。
    // part / session.idle / session.error が現ターンのものかの判定に使う(ターンを跨いで保持)。
    private var messageRoles: [String: String] = [:]
    private var messageParents: [String: String] = [:]
    // 現世代(send〜次の send/interrupt)に観測した user messageID。send() 後に SSE で新しい
    // user message を観測した時点で入る。ターン途中に opencode が合成の user message を足す
    // (plan_exit の "Execute the plan"・自動 compaction の継続等)ことがあり、元の user に紐づく
    // assistant の残りの part も現ターンとして通すため集合で持つ。
    // 空の間に届く session.idle / error は前ターン(中断含む)の遅延分として捨てる。
    private var turnUserMessageIds: Set<String> = []

    // partID -> part.type(テキスト差分が assistant 文か reasoning かの切替に使う)
    private var partTypes: [String: String] = [:]
    // partID -> これまでに出したテキスト(delta の累積)。text-end / reasoning-end の
    // part.updated は全文で届くため、出した分を除いた続きだけを出して二重表示を防ぐ。
    private var partTexts: [String: String] = [:]
    // 承認待ちの要求(permission.asked / question.asked の requestID)。question は質問一覧も保持。
    private var pendingPermissions: Set<String> = []
    private var pendingQuestions: [String: [[String: Any]]] = [:]
    // 保留中の要求(requestID)が起きたセッション(properties.sessionID。子や孫のこともある)。行ごとの停止で、
    // 止める子と子孫の要求だけをサーバー側で断るのに使う。lock で保護する。
    private var requestSessions: [String: String] = [:]
    // 行ごとの停止の返事待ち(キーは task の callID)。同じ行を 2 つの端末が同時に止めたとき、後からのは結果を待つ。lock で保護する。
    private var stopWaiters: [String: [CheckedContinuation<StopTaskOutcome, Never>]] = [:]
    /// 子の行が閉じるのを待つ秒数。テストが縮める。
    var stopSettleSeconds: TimeInterval = 5
    /// テスト用: サーバーへの応答 API(承認・質問の断り)の代わりに呼ぶ。
    var postHook: ((_ path: String, _ body: [String: Any]) async -> Void)?
    // iOS は承認/質問カードを 1 件しか持てず、後の actionRequest が先の要求を上書きして答えられなく
    // なる。並列の tool 呼び出し等で同時に来た要求は到着順に積み、shownActionId(iOS に出している
    // 1 件)が片付いたら次を出す。
    private var actionQueue: [(requestId: String, event: SessionEvent)] = []
    private var shownActionId: String?
    // tool callID -> (toolName, startTime, didEmitStart)
    private var tools: [String: (name: String, start: Date, didStart: Bool)] = [:]
    /// サブエージェント（task ツール。キーは callID）。セッションに 1 つ。lock で保護する。
    private var subagents = SubagentTracker()
    /// 子セッション（task の metadata.sessionId）ごとの覚え書き。子のイベントを行に結び付ける。lock で保護する。
    private struct Child {
        let callID: String
        /// 子のツール呼び出し（callID）。数えたものは数えない。
        var toolCalls: Set<String> = []
        /// 最後に送った作業の文
        var lastActivity: String?
        /// assistant messageID → そのメッセージのトークン数（合計を行のトークン数にする）
        var tokensByMessage: [String: Int] = [:]
        var lastTokens: Int?
        var model: String?
        /// 子の最後の返事（background の task を子の idle で閉じるときの結果）。子の assistant の発言の本文だけを見る。
        var lastText: String?
        var assistantMessages: Set<String> = []
        /// 子の最後の assistant の error（中断なら stopped、ほかは failed とその理由）
        var end: (state: String, message: String?)?
    }
    private var children: [String: Child] = [:]
    /// metadata.background == true の task（親のターンより長く動く）の callID。lock で保護する。
    private var backgroundTasks: Set<String> = []
    // 現在モデル(currentInfo 用)
    private var currentModel: String?
    private var currentProvider: String?
    private var currentMode: String?
    /// このチャットだけのモデル（provider と組で指定されたときだけ使う）。lock で保護する。
    private var overrides = SessionOverrides.none

    init(sessionId: String, client: OpenCodeServeClient, directory: String? = nil) {
        self.sessionId = sessionId
        self.client = client
        self.directory = directory
        var c: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { cont in c = cont }
        self.continuation = c
        client.register(sessionId, self)
    }

    /// セッションをイベントストリーム上で有効化。SessionHub が entry の pending キーを
    /// 確定 real sid へ張り替えるための .sessionStarted を出す。real sid は生成時点で
    /// 確定しているので即座に送る(AsyncThrowingStream が pump 開始までバッファする)。
    func emitStarted() {
        continuation.yield(.sessionStarted(agentId: agentId, sessionId: sessionId))
    }

    // MARK: - AgentSession

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        // ターン状態リセット
        let gen = beginTurn()

        // skills: opencode の /skill 経由(ACP と同様に prefix)。file 添付はテキストに展開。
        var prefix = text
        if !skills.isEmpty {
            prefix = "/skill \(skills.joined(separator: ",")) \n" + text
        }
        var notes: [String] = []
        var images: [BridgeAttachment] = []
        for att in attachments {
            switch att.kind {
            case .image:
                images.append(att)
            case .file:
                if let s = String(data: att.data, encoding: .utf8) {
                    notes.append("<file name=\"\(att.name)\">\n\(s)\n</file>")
                } else {
                    notes.append("[file \"\(att.name)\" を添付 (binary, \(att.data.count) bytes)]")
                }
            }
        }
        var full = prefix
        if !notes.isEmpty {
            full = notes.joined(separator: "\n\n") + "\n\n" + prefix
        }

        guard let client = client else { return }
        notePostSent(gen)
        // POST は完了までブロックするがストリーミングは SSE で並行到着するため await しない。
        // エラー/完了時に SSE の idle を逃した場合の控えとして done を整合する。
        // 復帰が遅れて次ターン(または中断後)になっていたら何もしない(世代で判定)。
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await client.sendMessage(self.sessionId, directory: self.directory, text: full, attachments: images,
                                             model: self.overrideModel(), agent: self.overrideAgent(),
                                             variant: self.chosenVariant())
                self.notePostReturned(gen)
                // POST が戻った = サーバ側でターン完了。SSE の idle が来ていなければここで done。
                self.finishTurnIfNotDone(gen: gen)
            } catch {
                self.notePostReturned(gen)
                guard self.isCurrentGen(gen) else { return }
                // 承認待ちのまま失敗(タイムアウト等)したら拒否しておく。残すと次の送信も詰まる。
                await self.rejectPendingRequests()
                // 送信に失敗したターンの前景の task は続かない(background の task は子の idle で閉じる)。
                self.abandonSubagents(state: "failed", onlyForeground: true)
                self.yieldError(Self.attributed("送信エラー: \(error.localizedDescription)"))
                self.finishTurnIfNotDone(gen: gen)
            }
        }
    }

    /// POST を投げる。その user message をまだ見ていない(中断した後に届いても、ほかの画面の発言と取り違えない)。
    /// POST を投げずに送信を再現できるよう internal にしている(単体テスト用)。
    func notePostSent(_ gen: Int) {
        lock.withLock { postsAwaitingUser.append(gen) }
    }

    /// POST が戻った(成功・失敗)。その user message を見ないまま戻ったなら(拒否された等)、待つのをやめる。
    private func notePostReturned(_ gen: Int) {
        lock.lock(); defer { lock.unlock() }
        if let i = postsAwaitingUser.firstIndex(of: gen) { postsAwaitingUser.remove(at: i) }
    }

    /// permission.asked / question.asked から出した actionRequest への回答を opencode へ返す。
    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {
        lock.lock()
        let isPermission = pendingPermissions.remove(requestId) != nil
        let questions = pendingQuestions.removeValue(forKey: requestId)
        requestSessions.removeValue(forKey: requestId)
        lock.unlock()
        // 応答を返し終えてから次の 1 件を出す(reject / always で opencode がまとめて片付けた分は、
        // 先に届く permission.replied で外れるので出さずに済む)。
        defer { dequeueActions([requestId], notify: false) }
        if isPermission {
            // 選択肢の value(once / always / reject)をそのまま返す。想定外の値は拒否扱い。
            let reply = ["once", "always", "reject"].contains(decision) ? decision : "reject"
            await postToServer("permission/\(requestId)/reply", body: ["reply": reply])
        } else if let questions {
            let text = decision.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                await postToServer("question/\(requestId)/reject", body: [:])
                return
            }
            // iOS の userInput は複数選択を ", " 連結で返す。選択肢ラベルに一致すればそれを、
            // 一致しなければ自由記述(Other)として返す。2問目以降は iOS に出していないので空回答。
            let first = questions.first ?? [:]
            let labels = ((first["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
            let picked = labels.contains(text) ? [text] : text.components(separatedBy: ", ").filter { labels.contains($0) }
            var answer = picked.isEmpty ? [text] : picked
            if (first["multiple"] as? Bool) != true { answer = Array(answer.prefix(1)) }
            let all: [[String]] = [answer] + Array(repeating: [String](), count: max(0, questions.count - 1))
            await postToServer("question/\(requestId)/reply", body: ["answers": all])
        }
    }

    func interrupt() async {
        // 中断したターンの POST 復帰や abort 由来の session.error / idle が、この後の
        // 次ターンに作用しないよう世代を進め、現ターンの開始観測も外す。
        lock.lock()
        let closed = didYieldDone
        if !closed {
            turnGen += 1
            turnUserMessageIds.removeAll()
        }
        lock.unlock()
        if closed {
            // ターンが動いていないときの abort は、止める相手がおらず、動いている背景の子まで止めてしまう(実測 e11)。
            // abort せず、止まったことだけ伝え直す。
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString))
            return
        }
        // abort は保留中の承認・質問をサーバー側から消さない(実測 e9b2)。アプリのカードは先に閉じ、abort の後に断る。
        let dropped = dropAllActions()
        await client?.abort(sessionId, directory: directory)
        await rejectRequests(permissions: dropped.permissions, questions: dropped.questions)
        // 前景の task は abort で子ごと止まる(親のターンより長く動かない)。後から届く task の part は
        // 知っている行にだけ反映する。background の task は abort でサーバーが止めるが、行は子の
        // session.error / idle で閉じるので残す。
        abandonSubagents(state: "stopped", onlyForeground: true)
        endBubbleIfAny()
        finishTurnIfNotDone()
    }

    // MARK: - 行ごとの停止(stop_task。docs/BACKGROUND_CONTROL_2026-10-21.md §3.6)

    /// task の行を 1 つ止める。子のセッションだけに abort を送り、その子と子孫の保留中の承認・質問を断る。
    /// 親のターンには触らない(親は「Task cancelled」を受けて次のステップへ進む)。
    func stopTask(_ request: StopTaskRequest) async -> StopTaskOutcome {
        guard request.taskId == "subagents" else { return .unsupported(nil) }
        guard let key = request.rowId, let epoch = request.epoch else { return .stale }
        lock.lock()
        guard epoch == subagents.epoch, subagents.contains(key) else { lock.unlock(); return .stale }
        guard let client, subagents.isRunning(key: key) else { lock.unlock(); return .notRunning }
        let begin = subagents.beginStop(key: key)
        let child = children.first { $0.value.callID == key }?.key
        var payload: String?
        switch begin {
        case .notRunning: lock.unlock(); return .notRunning
        case .unsupported: lock.unlock(); return .unsupported(nil)
        case .inFlight:
            lock.unlock()
            return await withCheckedContinuation { c in
                lock.lock()
                if stopWaiters[key] != nil { stopWaiters[key]?.append(c); lock.unlock() } else { lock.unlock(); c.resume(returning: .notRunning) }
            }
        case .ok(_, let p):
            payload = p
            stopWaiters[key] = []
        }
        lock.unlock()
        yieldSubagents([payload])
        guard let child else {
            // 手がかりが消えていた(起きないはず)。頼まずに戻す。
            // 行は止められないことにして送り直す(押すたびに unsupported にしない)。
            lock.lock()
            _ = subagents.setStopHandle(key: key, on: false)
            let ended = subagents.endStop(key: key)
            lock.unlock()
            yieldSubagents([ended])
            return finishStop(key, .unsupported(nil))
        }

        // 1. 子だけを止める。2xx でなければ止められていない。
        guard await client.abortChecked(child, directory: directory) else {
            lock.lock(); let ended = subagents.endStop(key: key); lock.unlock()
            yieldSubagents([ended])
            return finishStop(key, .failed(nil))
        }
        // 2. abort は保留中の承認・質問を消さない(実測 e9b2)。子と子孫のものをサーバー側で断る。
        //    断ると permission.replied が届き、今の処理がカードを閉じる。
        lock.lock()
        let asked = requestSessions
        let permissions = pendingPermissions.filter { rid in asked[rid].map { $0 == child || client.isDescendant($0, of: child) } ?? false }
        let questions = pendingQuestions.keys.filter { rid in asked[rid].map { $0 == child || client.isDescendant($0, of: child) } ?? false }
        lock.unlock()
        await rejectRequests(permissions: permissions, questions: Array(questions), timeout: 5)
        // 3. 行が閉じるのを待つ。閉じなければ(abort の true は何も保証しない)自分では閉じない。
        let deadline = Date().addingTimeInterval(stopSettleSeconds)
        while Date() < deadline {
            lock.lock(); let running = subagents.isRunning(key: key); lock.unlock()
            if !running || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        lock.lock()
        let state = subagents.isRunning(key: key) ? nil : subagents.state(key: key)
        let ended = state == nil ? subagents.endStop(key: key) : nil
        lock.unlock()
        yieldSubagents([ended])
        switch state {
        case "stopped": return finishStop(key, .stopped)
        case nil: return finishStop(key, .failed(nil))
        default: return finishStop(key, .notRunning)   // 先に終わった(done / failed)
        }
    }

    /// 返事待ちの端末に同じ結果を返す。
    private func finishStop(_ key: String, _ outcome: StopTaskOutcome) -> StopTaskOutcome {
        lock.lock()
        let waiters = stopWaiters.removeValue(forKey: key) ?? []
        lock.unlock()
        waiters.forEach { $0.resume(returning: outcome) }
        return outcome
    }

    func close() async {
        // 承認待ちを残すとサーバ側のターンが止まったままになるので拒否してから閉じる。
        await rejectPendingRequests()
        // 閉じた後は終わりの知らせを受けられないので、実行中の行を stopped で閉じる(裏で動く子も。
        // serve は共有なので子は止めない)。stream を閉じる前に流す。
        abandonSubagents(state: "stopped", onlyForeground: false)
        // サーバ(共有)は殺さない。自分のルートだけを client から外し(同じ sid の別セッションは
        // 巻き込まない)、stream を閉じる。
        client?.unregister(sessionId, self)
        continuation.finish()
    }

    /// サブエージェントのカードの全行(workflow_snapshot。行が無くても agents: [])。接続したときと
    /// turn_status_request のときに SessionHub が送る(ターンの後も動いている task を後から開いた画面に出す)。
    func subagentSnapshot() async -> String? {
        lock.withLock { subagents.snapshot(includeEmpty: true) }
    }

    /// serve が終了した(OpenCodeServeClient から)。子セッションも一緒に止まり、終わりの知らせはもう来ないので、
    /// 実行中の行を failed で閉じる。自分の送信のターンは POST の失敗で閉じるが、ほかの画面の発言で開いた
    /// ターンは閉じる手段が無くなるので、ここで閉じる。
    func serverDidExit() {
        abandonSubagents(state: "failed", onlyForeground: false)
        lock.lock()
        let remote = !didYieldDone && remoteUserMessageId != nil
        lock.unlock()
        if remote { finishTurnIfNotDone() }
    }

    /// 実行中の行を閉じて流す(中断・送信の失敗・close・serve の終了)。onlyForeground なら background の
    /// task は残す(親のターンより長く動き、子の idle か差し込まれた結果で閉じる)。
    private func abandonSubagents(state: String, onlyForeground: Bool) {
        lock.lock()
        let p = subagents.abandonRunning(state: state, onlyForeground: onlyForeground)
        lock.unlock()
        yieldSubagents([p])
    }

    private func yieldSubagents(_ payloads: [String?]) {
        for p in payloads.compactMap({ $0 }) {
            continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: p))
        }
    }

    // MARK: - opencode イベント → SessionEvent 翻訳(クライアントの SSE ポンプから呼ばれる)

    func handleServeEvent(type: String, properties: [String: Any]) {
        // ターンを閉じた後(done 済み)に遅れて届くストリーミング系イベントは捨てる。
        // 特に reasoning の part.updated / delta が done の後に到着すると iOS 側で
        // .activity → thinking が再点灯し、以降 done が来ないため「考え中」が固着する。
        // session.idle / error / model.switched は閉じても処理して良い。
        // part.updated は、知っている task(サブエージェント)の行と、差し込まれた子の結果にだけ反映する
        // (中断の後の task の error や、裏で動いていた子の結果)。
        if isTurnClosed() {
            switch type {
            case "message.part.updated":
                if let part = properties["part"] as? [String: Any] { handleLatePart(part) }
                return
            case "message.part.delta":
                return
            default:
                break
            }
        }
        switch type {
        case "message.updated":
            handleMessageUpdated(properties)
        case "message.part.updated":
            handlePartUpdated(properties)
        case "message.part.delta":
            handlePartDelta(properties)
        case "session.idle", "idle":
            // idle は sessionID しか持たない。現ターンの開始を観測する前の idle は前ターンの遅延分。
            guard isTurnStarted() else { return }
            finishTurnIfNotDone()
        case "session.error":
            guard isTurnStarted() else { return }
            let msg = errorMessage(properties)
            yieldError(Self.attributed(msg))
            finishTurnIfNotDone()
        case "permission.asked":
            handlePermissionAsked(properties)
        case "question.asked":
            handleQuestionAsked(properties)
        case "permission.replied", "question.replied", "question.rejected":
            // 他クライアント(TUI 等)の応答や、reject / always で opencode がまとめて片付けた要求を
            // 保留から外し、iOS に出していればカードを閉じさせて次を出す。自分が回答中の要求は
            // respondToAction が先に保留から外しているので、ここでは触らない。
            if let rid = properties["requestID"] as? String {
                lock.lock()
                let wasPermission = pendingPermissions.remove(rid) != nil
                let wasQuestion = pendingQuestions.removeValue(forKey: rid) != nil
                requestSessions.removeValue(forKey: rid)
                lock.unlock()
                if wasPermission || wasQuestion { dequeueActions([rid], notify: true) }
            }
        case "session.next.model.switched":
            if let m = properties["model"] as? [String: Any] {
                lock.lock()
                currentModel = (m["id"] as? String) ?? currentModel
                currentProvider = (m["providerID"] as? String) ?? currentProvider
                lock.unlock()
            }
        default:
            break  // catalog.*/server.*/busy/session.diff/reference.* 等は無視
        }
    }

    /// 現在モデル/プロバイダ/モード(currentInfo 用)。message.updated の info から更新。
    /// あわせて messageID の role / parentID を記録し、現ターンの user message を確定する。
    private func handleMessageUpdated(_ props: [String: Any]) {
        guard let info = props["info"] as? [String: Any] else { return }
        lock.lock()
        if let mid = info["id"] as? String, let role = info["role"] as? String {
            let isNew = messageRoles[mid] == nil
            messageRoles[mid] = role
            if role == "user" {
                // 新しい user message = 現ターンの発言か、ほかの画面・差し込みの発言(別のターンとして開く)。
                // 既知 ID の再 publish(summary 更新等)は前ターンのものなので無視。
                if isNew { noteNewUserMessageLocked(mid, created: Self.createdAt(info)) }
            } else if let parent = info["parentID"] as? String, !parent.isEmpty {
                messageParents[mid] = parent
                // user の message.updated を取りこぼした場合の控え: 未知の parent は新しい発言。
                if messageRoles[parent] == nil {
                    messageRoles[parent] = "user"
                    noteNewUserMessageLocked(parent, created: Self.createdAt(info))
                }
            }
        }
        if let m = info["modelID"] as? String { currentModel = m }
        if let p = info["providerID"] as? String { currentProvider = p }
        if let mode = info["mode"] as? String { currentMode = mode }
        lock.unlock()
        // トークン使用量(任意表示)
        if let tokens = info["tokens"] as? [String: Any] {
            emitUsage(tokens: tokens, cost: info["cost"] as? Double)
        }
    }

    /// 新しい user message。開いているターンなら現ターンの発言(自分の送信と、ターン途中に opencode が足す
    /// 合成の発言)。閉じていれば、発言をまだ見ていない自分の送信(中断したもの。開かない)か、自分が送っていない
    /// 発言(ターミナルの TUI・裏で動いていた子の結果の差し込み)で、後者は別のターンとして開く。lock 保持中に呼ぶ。
    private func noteNewUserMessageLocked(_ mid: String, created: Date?) {
        if !didYieldDone {
            turnUserMessageIds.insert(mid)
            if !postsAwaitingUser.isEmpty { postsAwaitingUser.removeFirst() }
            return
        }
        if !postsAwaitingUser.isEmpty {
            // 中断した自分の送信の発言。その返事は前のターンの遅れた分として捨てる。
            postsAwaitingUser.removeFirst()
            return
        }
        // 前からある発言の再 publish は開かない(終わらないターンが残る)。
        if let created, Date().timeIntervalSince(created) > Self.remoteTurnFreshness { return }
        // ほかの画面の発言・差し込みで opencode がターンを始めた。自分のターンと同じく本文と done を流す。
        // 世代を進める(前の POST の遅れた戻りでこのターンを閉じないように)。
        turnGen += 1
        didYieldDone = false
        turnUserMessageIds = [mid]
        remoteUserMessageId = mid
        remoteTurnEchoed = false
        remoteTurnIsNotification = false
        currentBubbleId = nil
        hadToolSinceLastMessage = false
        partTypes.removeAll()
        partTexts.removeAll()
    }

    /// message の info.time.created(epoch ms)。無ければ nil。
    private static func createdAt(_ info: [String: Any]) -> Date? {
        guard let time = info["time"] as? [String: Any], let ms = (time["created"] as? NSNumber)?.doubleValue,
              ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private func handlePartUpdated(_ props: [String: Any]) {
        guard let part = props["part"] as? [String: Any] else { return }
        // ユーザー発言の part(POST 後に updatePart で publish される)や前ターンの遅延 part は、本文やツールの行に
        // 出さない(差し込まれた子の結果・ほかの画面の発言・知っている task の行だけ扱う)。
        guard isCurrentTurnPart(messageId: part["messageID"] as? String) else {
            handleLatePart(part)
            return
        }
        let pid = (part["id"] as? String) ?? ""
        let ptype = (part["type"] as? String) ?? ""
        if !pid.isEmpty {
            lock.lock(); partTypes[pid] = ptype; lock.unlock()
        }

        switch ptype {
        case "reasoning":
            // reasoning の全文(part.updated)。差分は delta で別途到着するので、
            // delta で出していない分(delta が無かった時は全文)だけを activity に出す。
            if let text = part["text"] as? String, let rest = unsentText(pid: pid, full: text) {
                yieldActivity(rest)
            }
        case "text":
            // 完成テキスト(text-end で全文が届く)。差分(delta)で既にストリーム済みの分は除き、
            // 続きだけを出す。バブルが未開始ならここで開始して確実に出す。
            if let text = part["text"] as? String, let rest = unsentText(pid: pid, full: text) {
                endBubbleIfAnyHadTool()
                let mid = ensureBubble()
                yieldAssistantDelta(rest, messageId: mid)
            }
        case "tool":
            handleToolPart(part)
        case "step-finish":
            // 1ステップ(サブターン)終端。現在のテキストバブルを閉じる。
            if let tokens = part["tokens"] as? [String: Any] {
                emitUsage(tokens: tokens, cost: part["cost"] as? Double)
            }
            endBubbleIfAny()
        case "step-start":
            break  // 新しいステップの開始マーカ(特に出さない)
        default:
            break
        }
    }

    private func handlePartDelta(_ props: [String: Any]) {
        guard (props["field"] as? String) == "text",
              let delta = props["delta"] as? String,
              !delta.isEmpty,
              let pid = props["partID"] as? String else { return }
        guard isCurrentTurnPart(messageId: props["messageID"] as? String) else { return }
        lock.lock()
        let ptype = partTypes[pid]
        partTexts[pid, default: ""] += delta
        lock.unlock()
        if ptype == "reasoning" {
            yieldActivity(delta)
        } else {
            // text part(または未知)。アシスタント発話として蓄積。
            endBubbleIfAnyHadTool()
            let mid = ensureBubble()
            yieldAssistantDelta(delta, messageId: mid)
        }
    }

    // MARK: - tool

    private func handleToolPart(_ part: [String: Any]) {
        guard let callID = part["callID"] as? String, !callID.isEmpty else { return }
        let toolName = (part["tool"] as? String) ?? "tool"
        let state = (part["state"] as? [String: Any]) ?? [:]
        let status = (state["status"] as? String) ?? ""
        if toolName == "task" { yieldSubagents(taskPayloads(callID: callID, state: state, status: status, late: false)) }

        lock.lock()
        var entry = tools[callID] ?? (name: toolName, start: Date(), didStart: false)
        entry.name = toolName
        let didStart = entry.didStart
        let start = entry.start
        tools[callID] = entry
        lock.unlock()

        if (status == "pending" || status == "running") && !didStart {
            lock.lock()
            hadToolSinceLastMessage = true
            tools[callID] = (name: toolName, start: start, didStart: true)
            lock.unlock()
            // テキストバブルがあれば閉じて tool 行へ
            endBubbleIfAny()
            let title = toolTitle(name: toolName, input: state["input"])
            continuation.yield(.toolStart(
                agentId: agentId, sessionId: sessionId,
                toolUseId: callID, toolName: toolName,
                title: title, kind: toolKind(name: toolName)
            ))
        } else if status == "completed" || status == "error" {
            let summary = toolSummary(state: state)
            let durMs = Int(Date().timeIntervalSince(start) * 1000)
            lock.lock(); tools.removeValue(forKey: callID); lock.unlock()
            // 中断で止まったもの(「Task cancelled」「Tool execution aborted」)は失敗ではない(赤くしない)。
            let ended = status != "error" ? "completed" : Self.isAbortError(state["error"] as? String) ? "interrupted" : "failed"
            continuation.yield(.toolEnd(
                agentId: agentId, sessionId: sessionId,
                toolUseId: callID, toolName: toolName,
                status: ended,
                summary: summary, durationMs: durMs
            ))
        }
    }

    /// task ツール = サブエージェント。input = { description, prompt, subagent_type, background? }。
    /// running の metadata は { parentSessionId, sessionId(子セッション), model, background? }(1.18。1.17 以前は
    /// 子のツールの一覧 summary)。子の進み具合は子セッションのイベントで届く(handleChildEvent)。
    /// 出力は `<task id=子 state=completed|running|error>`(SubagentTracker.parseTaskOutput)。running は終わりではない。
    /// background の task はすぐ completed(state="running")になるので行は実行中のまま持ち、子の idle か、
    /// 差し込まれた `<task id=子 state=…>` で閉じる。
    /// late = 閉じたターン・前のターンの part。知っている行の終わりだけを反映する(止めた行を実行中に戻さない)。
    private func taskPayloads(callID: String, state: [String: Any], status: String, late: Bool) -> [String?] {
        let input = state["input"] as? [String: Any]
        let metadata = state["metadata"] as? [String: Any]
        let child = (metadata?["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let parent = (metadata?["parentSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sessionId
        let model = (metadata?["model"] as? [String: Any])?["modelID"] as? String
        let summary = metadata?["summary"] as? [[String: Any]]
        var payloads: [String?] = []
        lock.lock()
        let known = subagents.contains(callID)
        guard known || !late else { lock.unlock(); return [] }
        if let child, children[child]?.callID != callID { children[child] = Child(callID: callID) }
        if metadata?["background"] as? Bool == true || input?["background"] as? Bool == true {
            backgroundTasks.insert(callID)
        }
        let background: Bool? = backgroundTasks.contains(callID) ? true : (metadata == nil ? nil : false)
        if !late, !known || status == "pending" || status == "running" {
            payloads.append(subagents.begin(
                key: callID,
                label: (input?["description"] as? String) ?? (state["title"] as? String),
                agentType: input?["subagent_type"] as? String,
                model: model,
                background: background))
        }
        switch status {
        case "completed":
            let out = (state["output"] as? String) ?? ""
            let task = SubagentTracker.parseTaskOutput(out)
            if task.state == "running" {
                // 裏で動き出した(background か、前景から移された)。終わりにせず、子の idle か差し込みを待つ。
                backgroundTasks.insert(callID)
                if subagents.activity(key: callID, text: task.summary) != nil {
                    payloads.append(subagents.begin(key: callID, label: nil, background: true))
                }
            } else {
                let outcome = task.state.flatMap(SubagentTracker.finalState) ?? "done"
                let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
                payloads.append(subagents.finish(key: callID, state: outcome,
                                                 result: task.result ?? task.summary ?? (text.isEmpty ? nil : text)))
            }
        case "error":
            // 中断で止まったもの(「Task cancelled」「Tool execution aborted」)は失敗ではない。
            let error = state["error"] as? String
            payloads.append(subagents.finish(key: callID, state: Self.isAbortError(error) ? "stopped" : "failed",
                                             result: error))
        default:
            if !late, let summary, !summary.isEmpty {
                let last = summary.last
                let title = ((last?["state"] as? [String: Any])?["title"] as? String) ?? (last?["tool"] as? String)
                payloads.append(subagents.activity(key: callID, text: title, toolCalls: summary.count))
            }
        }
        // 子のセッション id が分かった行は止められる(子だけに abort を送る)。終わった行には立てない。
        if child != nil, subagents.isRunning(key: callID) {
            payloads.append(subagents.setStopHandle(key: callID, on: true))
        }
        lock.unlock()
        // session.created を取りこぼしても(SSE の張り直し等)、子のイベントをこのセッションへ回せるように。
        if let child { client?.linkChild(child, toParent: parent) }
        return payloads
    }

    /// 中断で止まった task のエラーか(「Task cancelled」「Tool execution aborted」等)。
    private static func isAbortError(_ text: String?) -> Bool {
        guard let t = text?.lowercased() else { return false }
        return t.contains("cancel") || t.contains("abort")
    }

    /// 閉じたターン・前のターン・発言(user)の part。本文とツールの行には出さず、差し込まれた子の結果と
    /// ほかの画面の発言、知っている task の行だけを扱う。
    private func handleLatePart(_ part: [String: Any]) {
        switch part["type"] as? String {
        case "text":
            // 前のターンの assistant の本文は捨てる(発言と、所属の分からない差し込みだけ)。
            guard messageRole(part["messageID"] as? String) != "assistant" else { return }
            handleUserTextPart(part)
        case "tool":
            guard part["tool"] as? String == "task", let callID = part["callID"] as? String, !callID.isEmpty else { return }
            let state = (part["state"] as? [String: Any]) ?? [:]
            yieldSubagents(taskPayloads(callID: callID, state: state, status: (state["status"] as? String) ?? "",
                                        late: true))
        default:
            break
        }
    }

    /// 発言(user)のテキスト part。自分の送信はアプリが出しているので流さない。
    /// - synthetic な `<task id=子 state=…>`: 裏で動いていたサブエージェントの結果の差し込み。その task の行を閉じ、
    ///   それで開いたターンは知らせのターンにする(done に origin を付ける)。
    /// - ほかの画面(ターミナルの TUI)の発言で開いたターン: 発言を 1 回だけ流す(新しいターンなので終わった行を捨てる)。
    private func handleUserTextPart(_ part: [String: Any]) {
        guard let text = part["text"] as? String, !text.isEmpty else { return }
        let mid = part["messageID"] as? String
        if part["synthetic"] as? Bool == true {
            guard let child = Self.taskOutputSessionId(text) else { return }
            let task = SubagentTracker.parseTaskOutput(text)
            var payload: String?
            lock.lock()
            if mid != nil, mid == remoteUserMessageId { remoteTurnIsNotification = true }
            if task.state != "running", let callID = children[child]?.callID {
                payload = subagents.finish(key: callID, state: task.state.flatMap(SubagentTracker.finalState) ?? "done",
                                           result: task.result ?? task.summary)
            }
            lock.unlock()
            yieldSubagents([payload])
            return
        }
        lock.lock()
        let echo = mid != nil && mid == remoteUserMessageId && !remoteTurnEchoed && !didYieldDone
        if echo {
            remoteTurnEchoed = true
            pruneFinishedLocked()
        }
        lock.unlock()
        if echo { continuation.yield(.userMessage(text, agentId: agentId, sessionId: sessionId)) }
    }

    /// task の出力(とその差し込み)の `<task id="…"` の id(子セッション)。無ければ nil。
    static func taskOutputSessionId(_ text: String) -> String? {
        guard let open = text.range(of: "<task "),
              let end = text[open.upperBound...].range(of: ">") else { return nil }
        let attrs = text[open.upperBound..<end.lowerBound]
        guard let s = attrs.range(of: "id=\""), s.lowerBound == attrs.startIndex || attrs[attrs.index(before: s.lowerBound)] == " ",
              let e = attrs[s.upperBound...].range(of: "\"") else { return nil }
        let id = String(attrs[s.upperBound..<e.lowerBound])
        return id.isEmpty ? nil : id
    }

    // MARK: - 子セッション(task のサブエージェント)

    /// 子セッションのイベント。OpenCodeServeClient が、ルートを持つ祖先(このセッション)へ回す。
    /// childSessionId はこのセッションの直下の子(task の行の子)、originSessionId は実際に起きたセッション(孫のこともある)。
    /// ツールの title を行の作業の文とツール回数に、assistant の tokens・modelID を行に入れ、background の task は
    /// 子の idle で閉じる。本文やターンには混ぜない。
    func handleChildEvent(childSessionId: String, originSessionId: String, type: String, properties: [String: Any]) {
        var payload: String?
        lock.lock()
        guard var c = children[childSessionId], subagents.contains(c.callID) else { lock.unlock(); return }
        let direct = originSessionId == childSessionId
        switch type {
        case "message.part.updated":
            guard let part = properties["part"] as? [String: Any] else { break }
            switch part["type"] as? String {
            case "tool":
                let state = (part["state"] as? [String: Any]) ?? [:]
                let name = (part["tool"] as? String) ?? "tool"
                let key = (part["callID"] as? String) ?? (part["id"] as? String) ?? ""
                let first = !key.isEmpty && c.toolCalls.insert(key).inserted
                let title = (state["title"] as? String).flatMap { $0.isEmpty ? nil : "\(name): \($0)" }
                let text = title ?? SubagentTracker.toolActivity(name: name, input: state["input"])
                // 実行中の出力の更新(metadata.output が伸びるたびに届く)は、文が変わらなければ送らない。
                guard first || text != c.lastActivity else { break }
                c.lastActivity = text
                payload = subagents.activity(key: c.callID, text: text, toolCall: first)
            case "text" where direct:
                // 子への依頼(user の発言)ではなく、子の返事の本文だけ。
                if let mid = part["messageID"] as? String, c.assistantMessages.contains(mid),
                   let t = part["text"] as? String, !t.isEmpty { c.lastText = t }
            default:
                break
            }
        case "message.updated":
            guard direct, let info = properties["info"] as? [String: Any], info["role"] as? String == "assistant" else { break }
            let mid = info["id"] as? String
            let isNewMessage = mid.map { c.assistantMessages.insert($0).inserted } ?? false
            if let err = info["error"] as? [String: Any] {
                c.end = Self.childEnd(err)
            } else if isNewMessage {
                c.end = nil   // エラーの後に新しい返事を始めた(再試行等)
            }
            if let mid, let tokens = info["tokens"] as? [String: Any], let total = Self.totalTokens(tokens), total > 0 {
                c.tokensByMessage[mid] = total
            }
            let sum = c.tokensByMessage.isEmpty ? nil : c.tokensByMessage.values.reduce(0, +)
            let model = (info["modelID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if sum != c.lastTokens || (model != nil && model != c.model) {
                c.lastTokens = sum
                if let model { c.model = model }
                payload = subagents.activity(key: c.callID, text: nil, tokens: sum, model: model)
            }
        case "session.error":
            if direct, c.end == nil { c.end = Self.childEnd(properties["error"]) }
        case "session.idle", "session.status":
            // 前景の task は親の task の part の終わりで閉じる。background の task だけ、子の idle で閉じる。
            guard direct, backgroundTasks.contains(c.callID) else { break }
            if type == "session.status", (properties["status"] as? [String: Any])?["type"] as? String != "idle" { break }
            payload = subagents.finish(key: c.callID, state: c.end?.state ?? "done", result: c.end?.message ?? c.lastText)
        default:
            break
        }
        children[childSessionId] = c
        lock.unlock()
        yieldSubagents([payload])
    }

    /// 子の error。MessageAbortedError(中断)は stopped、ほかは failed とその理由。
    private static func childEnd(_ raw: Any?) -> (state: String, message: String?)? {
        guard let err = raw as? [String: Any] else { return nil }
        if err["name"] as? String == "MessageAbortedError" { return ("stopped", nil) }
        return ("failed", describeError(["error": err]))
    }

    /// assistant の tokens({total?, input, output, reasoning, cache: {read, write}})の合計。
    private static func totalTokens(_ t: [String: Any]) -> Int? {
        func n(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        if let total = n(t["total"]) { return total }
        let cache = t["cache"] as? [String: Any]
        let parts = [n(t["input"]), n(t["output"]), n(t["reasoning"]), n(cache?["read"]), n(cache?["write"])].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    // MARK: - 承認 / 質問(permission.asked / question.asked)

    /// opencode 既定で ask になる操作(.env の読み取り・プロジェクト外のパス・doom_loop 等)の
    /// 承認要求。応答するまで opencode はターンを止めて待つので、iOS に actionRequest として出す。
    private func handlePermissionAsked(_ props: [String: Any]) {
        guard let rid = props["id"] as? String, !rid.isEmpty else { return }
        // ターンを閉じた後の要求は結果を届けられないので拒否して詰まらせない。
        if isTurnClosed() {
            Task { await postToServer("permission/\(rid)/reply", body: ["reply": "reject"]) }
            return
        }
        if let reply = unattendedReply {
            Task { await postToServer("permission/\(rid)/reply", body: ["reply": reply]) }
            return
        }
        let permission = (props["permission"] as? String) ?? "permission"
        let patterns = (props["patterns"] as? [String]) ?? []
        lock.lock()
        pendingPermissions.insert(rid)
        if let sid = props["sessionID"] as? String, !sid.isEmpty { requestSessions[rid] = sid }
        lock.unlock()
        let meta: [String: String] = [
            "requestId": rid,
            "kind": "permission",
            "option_count": "3",
            "option_0_title": "承認",
            "option_0_subtitle": "一度だけ許可",
            "option_0_value": "once",
            "option_1_title": "常に承認",
            "option_1_subtitle": "同じパターンは以後確認しない",
            "option_1_value": "always",
            "option_2_title": "拒否",
            "option_2_subtitle": "実行しない",
            "option_2_value": "reject",
            "allowsOther": "0"
        ]
        enqueueAction(requestId: rid, event: .actionRequest(
            agentId: agentId,
            sessionId: sessionId,
            messageId: rid,
            title: "OpenCode の承認: \(permission)",
            subtitle: patterns.isEmpty ? nil : patterns.joined(separator: ", "),
            metadata: meta
        ))
    }

    /// question ツールの質問。permission と同じく回答まで止まるので、1問目を選択肢として出す。
    private func handleQuestionAsked(_ props: [String: Any]) {
        guard let rid = props["id"] as? String, !rid.isEmpty else { return }
        let questions = (props["questions"] as? [[String: Any]]) ?? []
        guard !isTurnClosed(), unattendedReply == nil, let question = questions.first else {
            Task { await postToServer("question/\(rid)/reject", body: [:]) }
            return
        }
        let options = (question["options"] as? [[String: Any]]) ?? []
        var meta: [String: String] = [
            "requestId": rid,
            "kind": "userInput",
            "option_count": String(options.count),
            // custom(自由記述)は opencode 既定で許可
            "allowsOther": (question["custom"] as? Bool) == false ? "0" : "1"
        ]
        for (index, option) in options.enumerated() {
            let label = (option["label"] as? String) ?? "Option \(index + 1)"
            meta["option_\(index)_title"] = label
            meta["option_\(index)_subtitle"] = option["description"] as? String
            meta["option_\(index)_value"] = label
        }
        lock.lock()
        pendingQuestions[rid] = questions
        if let sid = props["sessionID"] as? String, !sid.isEmpty { requestSessions[rid] = sid }
        lock.unlock()
        enqueueAction(requestId: rid, event: .actionRequest(
            agentId: agentId,
            sessionId: sessionId,
            messageId: rid,
            title: (question["header"] as? String) ?? "選択してください",
            subtitle: question["question"] as? String,
            metadata: meta
        ))
    }

    /// 承認/質問を FIFO に積み、iOS に何も出していなければ出す。
    private func enqueueAction(requestId: String, event: SessionEvent) {
        lock.lock()
        actionQueue.append((requestId: requestId, event: event))
        let show = shownActionId == nil
        if show { shownActionId = requestId }
        lock.unlock()
        if show { continuation.yield(event) }
    }

    /// 片付いた要求を FIFO から外す。iOS に出していた要求なら次の 1 件を出す。iOS 以外で片付いた
    /// とき(notify)は、先に .actionResolved でカードを閉じさせる(押しても何も起きないカードを残さない)。
    private func dequeueActions(_ requestIds: Set<String>, notify: Bool) {
        lock.lock()
        actionQueue.removeAll { requestIds.contains($0.requestId) }
        var resolved: String?
        var next: SessionEvent?
        if let shown = shownActionId, requestIds.contains(shown) {
            resolved = shown
            shownActionId = actionQueue.first?.requestId
            next = actionQueue.first?.event
        }
        lock.unlock()
        if notify, let resolved {
            continuation.yield(.actionResolved(agentId: agentId, sessionId: sessionId, requestId: resolved))
        }
        if let next { continuation.yield(next) }
    }

    /// 保留中の承認/質問と FIFO をまとめて捨て、iOS に出していたカードを閉じさせる
    /// (中断・送信失敗・close 時)。捨てた permission / question の requestID を返す。
    private func dropAllActions() -> (permissions: Set<String>, questions: [String]) {
        lock.lock()
        let permissions = pendingPermissions
        let questions = Array(pendingQuestions.keys)
        pendingPermissions.removeAll()
        pendingQuestions.removeAll()
        requestSessions.removeAll()
        let shown = shownActionId
        actionQueue.removeAll()
        shownActionId = nil
        lock.unlock()
        if let shown {
            continuation.yield(.actionResolved(agentId: agentId, sessionId: sessionId, requestId: shown))
        }
        return (permissions, questions)
    }

    /// 保留中の承認/質問をすべて拒否する(送信失敗・close 時。残すとサーバ側のターンが止まったまま)。
    private func rejectPendingRequests() async {
        let (permissions, questions) = dropAllActions()
        await rejectRequests(permissions: permissions, questions: questions)
    }

    /// 並べて送る。行の停止では短い timeout を渡し、遅いサーバーで 15 秒の上限を超えないようにする。
    private func rejectRequests(permissions: Set<String>, questions: [String], timeout: TimeInterval = 30) async {
        await withTaskGroup(of: Void.self) { group in
            for rid in permissions {
                group.addTask { await self.postToServer("permission/\(rid)/reply", body: ["reply": "reject"], timeout: timeout) }
            }
            for rid in questions {
                group.addTask { await self.postToServer("question/\(rid)/reject", body: [:], timeout: timeout) }
            }
        }
    }

    /// opencode serve の応答 API(`POST /permission/{id}/reply` 等)を叩く。失敗はログのみ。
    private func postToServer(_ path: String, body: [String: Any], timeout: TimeInterval = 30) async {
        if let postHook { await postHook(path, body); return }
        guard let base = client?.serverURL,
              var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return }
        // queryItems は "+" をエスケープせず opencode 側で空白に化けるので、client.http() と同じ文字集合で符号化する。
        if let directory = directory, !directory.isEmpty,
           let encoded = directory.addingPercentEncoding(withAllowedCharacters: OpenCodeServeClient.directoryQueryAllowed) {
            comps.percentEncodedQueryItems = [URLQueryItem(name: "directory", value: encoded)]
        }
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = timeout
        client?.authorize(&req)
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                FileHandle.standardError.write(Data("[opencode.serve] POST \(path) failed: HTTP \(http.statusCode)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("[opencode.serve] POST \(path) failed: \(error.localizedDescription)\n".utf8))
        }
    }

    // MARK: - bubble 制御(AcpSession と同様のターン内分割)

    private func ensureBubble() -> String {
        lock.lock(); defer { lock.unlock() }
        if currentBubbleId == nil { currentBubbleId = UUID().uuidString }
        return currentBubbleId!
    }

    /// tool 前にテキストがあったら閉じる(連続するテキスト差分は同じバブルに蓄積)。
    private func endBubbleIfAnyHadTool() {
        lock.lock(); let had = hadToolSinceLastMessage; lock.unlock()
        if had { endBubbleIfAny() }
    }

    private func endBubbleIfAny() {
        lock.lock()
        let mid = currentBubbleId
        currentBubbleId = nil
        hadToolSinceLastMessage = false
        lock.unlock()
        if let mid = mid {
            continuation.yield(.assistantTurnEnd(agentId: agentId, sessionId: sessionId, messageId: mid))
        }
    }

    /// ターン状態をリセットして世代を進め、新しい世代を返す(send() の冒頭)。
    /// POST を投げずにターン切替を再現できるよう internal にしている(単体テスト用)。
    @discardableResult
    func beginTurn() -> Int {
        lock.lock(); defer { lock.unlock() }
        currentBubbleId = nil
        hadToolSinceLastMessage = false
        didYieldDone = false
        turnGen += 1
        turnUserMessageIds.removeAll()
        remoteUserMessageId = nil
        remoteTurnIsNotification = false
        partTypes.removeAll()
        partTexts.removeAll()
        pruneFinishedLocked()
        return turnGen
    }

    /// 新しいターン(自分の送信・ほかの画面の発言)で、終わった行を忘れる(裏で動き続けている task は残す。
    /// 知らせのターンでは呼ばない)。lock 保持中に呼ぶ。
    private func pruneFinishedLocked() {
        subagents.pruneFinished()
        children = children.filter { subagents.contains($0.value.callID) }
        backgroundTasks = backgroundTasks.filter { subagents.contains($0) }
    }

    /// ターンが既に done を出して閉じているか。done 後の遅延イベント破棄判定に使う。
    private func isTurnClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return didYieldDone
    }

    /// 現ターンの user message を SSE で観測済みか(= 以降の idle / error は現ターンのもの)。
    private func isTurnStarted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !turnUserMessageIds.isEmpty
    }

    private func isCurrentGen(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == turnGen
    }

    /// part(の messageID)が現ターンのアシスタント応答に属するか。user message の part と、
    /// 前ターンの assistant message の part は false。message.updated を取りこぼして
    /// 所属が分からないものは従来どおり通す。
    private func isCurrentTurnPart(messageId: String?) -> Bool {
        guard let mid = messageId, !mid.isEmpty else { return true }
        lock.lock(); defer { lock.unlock() }
        let role = messageRoles[mid]
        if role == "user" { return false }
        if role == "assistant", let parent = messageParents[mid] { return turnUserMessageIds.contains(parent) }
        return true
    }

    /// 記録した message の role(知らなければ nil)。
    private func messageRole(_ messageId: String?) -> String? {
        guard let mid = messageId, !mid.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return messageRoles[mid]
    }

    /// part.updated の全文のうち、まだ出していない続きを返す(無ければ nil)。delta を一度も
    /// 受けていない part は全文。出した分で始まらない(text-end で experimental.text.complete
    /// プラグインが書き換えた等)場合は、出した分を取り消せないので何も出さない。
    private func unsentText(pid: String, full: String) -> String? {
        guard !full.isEmpty else { return nil }
        guard !pid.isEmpty else { return full }
        lock.lock(); defer { lock.unlock() }
        guard let sent = partTexts[pid] else {
            partTexts[pid] = full
            return full
        }
        guard full.utf8.count > sent.utf8.count, full.utf8.starts(with: sent.utf8) else { return nil }
        partTexts[pid] = full
        return String(decoding: full.utf8.dropFirst(sent.utf8.count), as: UTF8.self)
    }

    /// gen 指定時は、その世代が現在のターンと一致するときだけ閉じる(POST 復帰用)。
    private func finishTurnIfNotDone(gen: Int? = nil) {
        lock.lock()
        if let gen, gen != turnGen { lock.unlock(); return }
        guard !didYieldDone else { lock.unlock(); return }
        didYieldDone = true
        let mid = currentBubbleId
        currentBubbleId = nil
        hadToolSinceLastMessage = false
        let notification = remoteUserMessageId != nil && remoteTurnIsNotification
        remoteUserMessageId = nil
        remoteTurnIsNotification = false
        lock.unlock()
        if let mid = mid {
            continuation.yield(.assistantTurnEnd(agentId: agentId, sessionId: sessionId, messageId: mid))
        }
        var done = SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString)
        // 裏で動いていたサブエージェントの結果の差し込みで opencode が始めたターン(知らせのターン)。
        if notification { done = done.addingMetadata(["origin": "task-notification"]) }
        continuation.yield(done)
    }

    // MARK: - 小出力ヘルパ

    private func yieldAssistantDelta(_ text: String, messageId: String) {
        continuation.yield(.assistantDelta(text, agentId: agentId, sessionId: sessionId, messageId: messageId))
    }

    private func yieldActivity(_ text: String) {
        lock.lock()
        let mid = currentBubbleId ?? "pending-thought"
        lock.unlock()
        continuation.yield(.activity(agentId: agentId, sessionId: sessionId, messageId: mid, text: text))
    }

    private func emitUsage(tokens: [String: Any], cost: Double?) {
        let input = (tokens["input"] as? Int) ?? (tokens["input"] as? Double).map { Int($0) }
        let output = (tokens["output"] as? Int) ?? (tokens["output"] as? Double).map { Int($0) }
        let total = (tokens["total"] as? Int) ?? (tokens["total"] as? Double).map { Int($0) }
        var meta: [String: String] = [:]
        if let input { meta["input"] = String(input) }
        if let output { meta["output"] = String(output) }
        if let total { meta["total"] = String(total) }
        if let cost { meta["cost"] = String(cost) }
        guard !meta.isEmpty else { return }
        let ev = SessionEvent(type: .usageUpdate, agentId: agentId, sessionId: sessionId,
                              messageId: nil, toolUseId: nil, content: nil, toolName: nil, metadata: meta)
        continuation.yield(ev)
    }

    private func yieldError(_ msg: String) {
        continuation.yield(SessionEvent(type: .error, agentId: agentId, sessionId: sessionId,
                                        messageId: UUID().uuidString, toolUseId: nil,
                                        content: msg, toolName: nil, metadata: nil))
    }

    // MARK: - 抽出ヘルパ

    /// ユーザーに「これは BuddyOS ではなく OpenCode 側のエラー」と伝える注記をつける。
    static func attributed(_ detail: String) -> String {
        "OpenCode 側のエラー: \(detail)\n（BuddyOS の不具合ではなく、OpenCode からの応答です。OpenCode を最新版に更新すると直ることがあります。）"
    }

    private func errorMessage(_ props: [String: Any]) -> String {
        Self.describeError(props)
    }

    /// session.error の中身から、原因が分かる文を作る。opencode のエラーは
    /// `{name: "ProviderAuthError", data: {providerID, message}}` の形で、message が `data` の下にある。
    /// 名前だけでも出す（未ログイン・モデル未設定などは名前で原因が分かる）。
    static func describeError(_ props: [String: Any]) -> String {
        guard let err = props["error"] as? [String: Any] else { return "opencode セッションエラー" }
        let name = err["name"] as? String
        let data = err["data"] as? [String: Any]
        let message = (data?["message"] as? String) ?? (err["message"] as? String)
        switch (name, message) {
        case let (n?, m?) where !m.isEmpty: return "\(n): \(m)"
        case let (_, m?) where !m.isEmpty: return m
        case let (n?, _): return "opencode エラー（\(n)）。opencode にログインしているか、モデルが設定されているかを確認してください。"
        default: return "opencode セッションエラー"
        }
    }

    private func toolTitle(name: String, input: Any?) -> String {
        if let input = input as? [String: Any] {
            if let fp = input["filePath"] as? String { return "\(name) `\(fp)`" }
            if let cmd = input["command"] as? String { return "\(name) `\(cmd)`" }
        }
        return name
    }

    private func toolSummary(state: [String: Any]) -> String? {
        if let err = state["error"] as? String, !err.isEmpty { return String(err.prefix(400)) }
        if let out = state["output"] as? [String: Any], let s = out["content"] as? String { return String(s.prefix(400)) }
        return nil
    }

    private func toolKind(name: String) -> String {
        switch name {
        case "read", "ls", "grep", "glob": return "read"
        case "edit", "write", "remove", "move", "bash": return "execute"
        case "fetch", "webfetch", "search": return "fetch"
        default: return "other"
        }
    }

    /// アプリで選んだモデルを、表示用の現在値にも反映する（次のメッセージから使われる）。
    func noteSelectedModel(provider: String, model: String) {
        lock.lock(); defer { lock.unlock() }
        currentModel = model
        currentProvider = provider
    }

    func applyOverrides(_ overrides: SessionOverrides) {
        lock.lock(); defer { lock.unlock() }
        self.overrides = overrides
    }

    /// このメッセージで使う variant（Effort）。チャットの上書き > BuddyOS の既定。送るモデルが持っていない値は送らない
    /// （送ると opencode がメッセージごと拒否する）。
    private func chosenVariant() -> String? {
        lock.lock()
        let wanted = overrides.reasoningEffort
        let snapshot = (currentProvider, currentModel)
        lock.unlock()
        guard let variant = wanted ?? OpenCodeAdapter.defaultVariant() else { return nil }
        let model = overrideModel() ?? OpenCodeAdapter.selectedModel()
            ?? snapshot.0.flatMap { p in snapshot.1.map { (p, $0) } }
        guard let model, OpenCodeAdapter.variants(provider: model.0, model: model.1).contains(variant) else { return nil }
        return variant
    }

    /// チャットで選んだモード（capabilities.modes の build / plan = opencode の agent 名）。
    private func overrideAgent() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let mode = overrides.mode, ["build", "plan"].contains(mode) else { return nil }
        return mode
    }

    /// チャットで選んだモデル。opencode はモデル指定に provider が要るので、両方揃ったときだけ返す。
    private func overrideModel() -> (provider: String, model: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let model = overrides.model, let provider = overrides.provider, provider != "opencode" else { return nil }
        return (provider, model)
    }

    // currentInfo 用アクセサ(OpenCodeAdapter から)
    func infoSnapshot() -> (model: String?, provider: String?, mode: String?) {
        lock.lock(); defer { lock.unlock() }
        return (currentModel, currentProvider, currentMode)
    }
}
