import Foundation

/// (agentId, sessionId) ごとに AgentSession を保持して event stream を一元的に pump する。
/// 複数 WS が同じ session を購読できるようにすると共に、WS が一切無い間に
/// hermes 生成が完了した場合は assistant_delta を蓄積して done 時に APNs push を飛ばす。
actor SessionHub {
    static let shared = SessionHub()

    /// 進行中ターンのフェーズ。再接続スナップショット(turn_resume)用に pump で追跡する。
    enum Phase: String { case idle, thinking, streaming }

    /// Mac 側予約キューの 1 件。生成中に届いた指示を Bridge が預かり、done 後に自動実行する。
    /// iOS 側キューだと「アプリを閉じたら送られない」ため、実体はこちらに持つ。
    struct QueuedMessage: Sendable {
        let clientMessageId: String
        let content: String
        let skills: [String]
        let attachments: [BridgeAttachment]
        /// 音声会話から積まれた指示か。done 後の自動実行でも音声のターンとして送る（落とすと通常の応え方になる）。
        var voice: VoiceTurn? = nil
        /// 人がペアリング済みの端末の入力欄で打った指示か（.device の WS の queue_user_message）。
        /// mainagent の submitExternal と .local の WS からの予約は false。
        /// ターミナルの claude には、人が打った指示だけを打ち込んで届ける（WebSocketServer.dispatch）。
        var typedByUser = false
    }

    private final class Entry: @unchecked Sendable {
        let agentId: String
        /// 通知のタイトルに出す名前（adapter の displayName）。
        var displayName: String?
        /// 開いたときの作業フォルダ（resume で cwd が渡らなかったものは nil）。mainagent の一覧に出す。
        var cwd: String?
        var sessionId: String?              // sessionStarted 受信後に確定
        let session: AgentSession
        var subscribers: [UUID: @Sendable (SessionEvent) -> Void] = [:]
        /// Mac 側予約キュー（FIFO）。done のたびに先頭から 1 件を自動実行する。
        var messageQueue: [QueuedMessage] = []
        /// このターンの吹き出しの本文（messageId ごと）。done の push に最後の吹き出しを使う。done でリセット。
        var bubbles = TurnBubbles()
        var pumpTask: Task<Void, Never>?
        /// 生成 (assistant 出力 / tool 実行) が進行中か。done で false。
        /// 購読者ゼロでも generating 中は閉じず、done 後 (push 済) に閉じる。
        /// ターンより長く動くバックグラウンドの作業（cards で数える）は含めない。それがある間も閉じない（release / sweep）。
        var generating: Bool = false
        /// 回答を待っている承認・質問の requestId。list_sessions の awaiting に使う（record で更新）。
        var openActionRequestIds: [String] = []
        /// 最後に event を受け取った時刻。generating のままハングしたセッションの
        /// 回収判定 (アイドルタイムアウト) に使う。
        var lastEventAt: Date = Date()
        /// 送った（notePromptSent / 予約の自動実行）が、まだ done も error も返っていないプロンプト数。
        /// done を伴わない error でターンが終わったかの判定に使う。done で 0 に戻す。
        var outstandingPrompts: Int = 0
        /// 送ったプロンプトが全部 error で返ったときの後始末の予約（settleErroredTurn）。done が続けば取り消す。
        var erroredTurnSettle: UUID?
        /// done の時点でバックグラウンドのサブエージェントか workflow が動いていたので出さなかった完了の push の本文。
        /// ふつうはその作業が終わった後の知らせのターンの done が push を引き継ぐ。知らせのターンを出さない CLI（Codex の
        /// multi-agent v2 は子が終わっても親が起きない）と本文の無い知らせのターン（silent の done）では done が push しないので、
        /// 作業が無くなってから owedPushGrace の間に何も始まらなければ、これを push する（settleOwedPush）。
        /// 作業が終わったのを利用者が見たら（見ている間に終わった・終わった後に開いた・done を見た）捨てる。
        var owedPush: String?
        /// owedPush を出すかを決める予約（作業が無くなった時点で置く）。done・新しいターンで取り消す。
        var owedPushSettle: UUID?

        // --- 再接続スナップショット用の進行状態ミラー（pump で更新） ---
        var phase: Phase = .idle
        var currentMessageId: String?       // 進行中 bubble の id（streaming 時）
        var currentBubbleText: String = ""  // 進行中 bubble の現時点テキスト（turn_end でリセット）
        var currentToolUseId: String?
        var currentToolName: String?
        var currentToolKind: String?
        /// 直近で完了したターンの messageId。再接続時に done を能動再送して、
        /// クライアントが done を取りこぼして固着した spinner を解除させるための保険。
        var lastDoneMessageId: String?
        /// workflow_progress のカード（dynamic workflow と subagents）の写し。再接続時に再生し、バックグラウンドの作業が
        /// あるか（閉じない・スリープ抑止・完了の push・一覧の background）の判定に使う。subagents のカードと終わっていない
        /// workflow は done で消さない（ターンより長く動く）。終わった行と workflow は新しいターンの始まりで捨てる。
        var cards = WorkflowCardMirror()
        /// pump が subagents の payload を配った回数。session の全行（subagentSnapshot）を聞いている間に配った行があれば聞き直す。
        var subagentsDelivered = 0

        // --- live delta 同期用 (Windows LiveHistoryIndex 相当) ---
        /// 採番済みイベントのリングバッファ。再接続時の loadHistoryRequest(sinceSeq:) に
        /// 差分 replay で応える（全履歴の再読込より軽い）。
        var recentEvents: [SessionEvent] = []
        /// このセッションで最後に採番した seq（単調増加、1 始まり）。
        var lastSeq: Int = 0
        /// この entry を作った時点の採番（= 作成時の lastSeq）。これ以下の seq はこの entry が振っていない
        /// （前の entry / 前の世代）。前の entry が閉じてからこの entry ができるまでの分（ターミナルで進めた
        /// ターンなど）は hub を通っていないので、差分同期は sinceSeq がこれより大きいときだけ行う。
        var startSeq: Int = 0

        init(agentId: String, sessionId: String?, session: AgentSession) {
            self.agentId = agentId
            self.sessionId = sessionId
            self.session = session
        }
    }

    /// key 形式:
    ///   - 確定済み: "<agentId>:<sessionId>"
    ///   - 未確定:   "<agentId>:pending-<uuid8>"
    private var entries: [String: Entry] = [:]
    /// subscriberId → key の逆引き (WS close 時に確実に release するため)
    private var subscriberKey: [UUID: String] = [:]

    // 処理済み user_message の clientMessageId（再接続の outbox 再送による二重実行を防ぐ）。
    // clientMessageId は UUID なのでセッション横断のグローバル集合で十分。FIFO で上限管理。
    private var processedClientMessageIds: Set<String> = []
    private var processedOrder: [String] = []
    private let maxProcessedClientMessageIds = 2000

    /// key（"<agentId>:<sessionId>"）ごとの最終採番。entry は購読者ゼロで close → 再生成されるので、
    /// Entry の中だけで数えると seq が 1 に戻る。iOS は lastHistorySeq を max で保持するため、
    /// 戻った seq では sinceSeq と食い違って差分同期が欠ける。Bridge プロセス内では key ごとに単調増加させる。
    private var lastSeqByKey: [String: Int] = [:]

    /// seq の起点。Bridge を再起動しても seq が後戻りしないよう、プロセス起動時刻（ms）から振る。
    /// 1 から振り直すと、iOS が max で持つ前世代の lastHistorySeq に新世代の seq が追いついた時点で
    /// 差分同期が新世代の前半を「受信済み」と誤判定して飛ばす。
    static let seqBase = Int(Date().timeIntervalSince1970 * 1000)

    // MARK: - live delta 同期 (Windows LiveHistoryIndex 相当)

    /// 採番・buffering の対象イベント種。Windows bridge の shouldRecord と同一集合。
    /// 応答系 (historyMessage / cronJobItem 等) は再接続 replay の対象外。
    private static let recordedTypes: Set<SessionEventType> = [
        .sessionStarted, .userMessage, .assistantDelta, .activity,
        .toolStart, .toolEnd, .assistantTurnEnd, .done, .error,
        .actionRequest, .planUpdate,
        // 予約実行はユーザーバブル相当。再接続 replay で順序どおり復元させる。
        .queueDispatched,
        // 承認要求の解決。入れないと replay で actionRequest だけが届き、解決済みのカードが戻る。
        .actionResolved
    ]
    /// リングバッファ上限（Windows の maxEntries=1500 と同値）。
    private static let maxRecentEvents = 1500

    /// 対象イベントに seq を採番してバッファへ積み、採番済みイベントを返す。
    /// 対象外はそのまま返す（seq なし）。
    private func record(_ event: SessionEvent, entry: Entry) -> SessionEvent {
        guard Self.recordedTypes.contains(event.type) else { return event }
        noteActionState(event, entry: entry)
        var stamped = event
        entry.lastSeq += 1
        stamped.seq = entry.lastSeq
        if let sid = entry.sessionId { lastSeqByKey["\(entry.agentId):\(sid)"] = entry.lastSeq }
        entry.recentEvents.append(stamped)
        if entry.recentEvents.count > Self.maxRecentEvents {
            entry.recentEvents.removeFirst(entry.recentEvents.count - Self.maxRecentEvents)
        }
        return stamped
    }

    /// 回答待ちの承認・質問を追う。解決したもの、ユーザーが発話したとき、エージェントが先へ進んだとき
    /// （別の端末やターミナルで答えた）に外す。done では外さない（ターンを終えてから文章での回答を待つエージェントがある）。
    private func noteActionState(_ event: SessionEvent, entry: Entry) {
        switch event.type {
        case .actionRequest:
            entry.openActionRequestIds.append(event.messageId ?? "")
        case .actionResolved:
            entry.openActionRequestIds.removeAll { $0 == event.messageId }
        case .userMessage, .queueDispatched, .assistantDelta, .toolStart:
            entry.openActionRequestIds.removeAll()
        default:
            break
        }
    }

    /// WebSocketServer が渡す sid（= session.sessionId）から entry を引く。新規チャットでは
    /// adapter が sid を確定し直した後も hub の key が古いままのことがあるので、key で見つからなければ
    /// 同じ session を持つ entry を探す。
    private func resolveEntry(agentId: String, sessionId: String) -> Entry? {
        guard !sessionId.isEmpty else { return nil }
        if let e = entries["\(agentId):\(sessionId)"] { return e }
        return entries.values.first { $0.agentId == agentId && $0.session.sessionId == sessionId }
    }

    /// iOS から届いた user_message を採番・記録し、その seq を返す（inputAck に載せて
    /// クライアントの lastHistorySeq を送信時点まで進めるため）。session 未登録なら nil。
    func recordUserMessage(agentId: String, sessionId: String, content: String?, messageId: String?) -> Int? {
        guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId) else { return nil }
        let event = SessionEvent(
            type: .userMessage, agentId: agentId, sessionId: sessionId,
            messageId: messageId, toolUseId: nil, content: content,
            toolName: nil, metadata: nil
        )
        return record(event, entry: entry).seq
    }

    /// アイドルで即実行した予約を queue_dispatched として採番し、全購読者へ配る（同じセッションを
    /// 見ている別画面・別端末にもユーザーバブルを出し、再接続 replay でも順序を復元させる）。
    /// 採番した seq を返す。session 未登録なら nil（呼び元が送信元へ直接通知する）。
    func recordQueueDispatched(agentId: String, sessionId: String, clientMessageId: String, content: String) -> Int? {
        guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId) else { return nil }
        let dispatched = record(
            SessionEvent.queueDispatched(
                agentId: agentId, sessionId: entry.sessionId ?? sessionId,
                clientMessageId: clientMessageId, content: content),
            entry: entry
        )
        for s in entry.subscribers.values { s(dispatched) }
        return dispatched.seq
    }

    /// 差分同期の可否判定用。entry が無ければ entryExists=false。
    /// firstBufferedSeq はリングバッファ先頭の seq（空、または sinceSeq がこの entry の作成時点以前で
    /// 続きを保証できないなら nil）。
    func deltaCoverage(agentId: String, sessionId: String, sinceSeq: Int) -> (entryExists: Bool, lastSeq: Int, firstBufferedSeq: Int?) {
        guard let entry = entries["\(agentId):\(sessionId)"] else { return (false, 0, nil) }
        // liveDelta と同じ: 作り直した entry の作成時点以前の sinceSeq からは、その間の分を持っていない。
        guard sinceSeq > entry.startSeq else { return (true, entry.lastSeq, nil) }
        return (true, entry.lastSeq, entry.recentEvents.first?.seq)
    }

    /// sinceSeq より後の採番済みイベント（差分 replay 用）。
    /// 途切れなく続きを返せないときは空を返し、呼び元を全履歴の再読込へ落とす
    /// （欠けたまま replay すると本文・ツール行・承認要求が抜けたまま同期済み扱いになる）。
    /// - バッファ先頭が sinceSeq+1 より新しい: リングバッファから溢れた / 再生成した entry が前の分を持っていない
    /// - sinceSeq がこの entry の作成時点以前: 前の entry が閉じてからこの entry ができるまで（ターミナルで
    ///   進めたターンなど）は hub を通っていない。seq は続き番号なので、先頭の sessionStarted などが
    ///   sinceSeq+1 に並んで途切れていないように見える
    /// - sinceSeq が最新採番より大きい: Bridge 再起動などで採番が振り直された
    func liveDelta(agentId: String, sessionId: String, sinceSeq: Int) -> [SessionEvent] {
        guard let entry = entries["\(agentId):\(sessionId)"] else { return [] }
        guard sinceSeq > entry.startSeq, sinceSeq <= entry.lastSeq,
              let firstSeq = entry.recentEvents.first?.seq, firstSeq <= sinceSeq + 1 else { return [] }
        return entry.recentEvents.filter { ($0.seq ?? 0) > sinceSeq }
    }

    /// このセッションの最新採番（未採番なら nil）。loadHistoryEnd に添える。
    func latestSeq(agentId: String, sessionId: String) -> Int? {
        guard let entry = entries["\(agentId):\(sessionId)"], entry.lastSeq > 0 else { return nil }
        return entry.lastSeq
    }

    /// user_message を受け付けるかの判定（Windows の user_message 処理と同じ順序）。
    enum UserInputDecision: Equatable {
        /// 処理済みの再送。ack だけ返して実行しない。
        case duplicate
        /// baseSeq より後に別の入力がある。input_rejected を返す（処理済みにはしない）。
        case rejected
        /// 受け付けた。seq は記録した user_message の採番（clientMessageId が無い・entry が無ければ nil）。
        case accepted(seq: Int?)
    }

    /// 再送の判定 → baseSeq の競合ガード → 処理済みの印と記録、を actor の中で一度に行う。
    /// - baseSeq: クライアントが最後に受け取った seq。nil（古いアプリ）と 0（live の seq をまだ受けていない）は見ない。
    /// - followUp: 実行中ターンへの注入。わざと前の seq を基準にするのでガードしない。
    func admitUserMessage(agentId: String, sessionId: String, clientMessageId: String?,
                          content: String?, messageId: String?,
                          baseSeq: Int?, followUp: Bool) -> UserInputDecision {
        let cmid = clientMessageId ?? ""
        if !cmid.isEmpty, processedClientMessageIds.contains(cmid) { return .duplicate }
        let entry = resolveEntry(agentId: agentId, sessionId: sessionId)
        if !followUp, let base = baseSeq, base > 0, let entry, Self.hasUserInput(after: base, in: entry.recentEvents) {
            return .rejected
        }
        guard !cmid.isEmpty else { return .accepted(seq: nil) }
        _ = shouldProcessUserMessage(clientMessageId: cmid)
        let seq = recordUserMessage(agentId: agentId, sessionId: sessionId, content: content, messageId: messageId)
        return .accepted(seq: seq)
    }

    /// seq より後に user_message が記録されているか（Windows の hasUserInputAfter と同じ）。
    static func hasUserInput(after seq: Int, in events: [SessionEvent]) -> Bool {
        events.contains { $0.type == .userMessage && ($0.seq ?? 0) > seq }
    }

    /// metadata の baseSeq を読む（Windows の parseOptionalPositiveInt と同じ: 空・負・数でなければ nil）。
    static func parseBaseSeq(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
              let value = Int(raw), value >= 0 else { return nil }
        return value
    }

    /// 初回の user_message なら記録して true、既処理（再送）なら false。
    func shouldProcessUserMessage(clientMessageId: String) -> Bool {
        guard !clientMessageId.isEmpty else { return true }
        if processedClientMessageIds.contains(clientMessageId) { return false }
        processedClientMessageIds.insert(clientMessageId)
        processedOrder.append(clientMessageId)
        if processedOrder.count > maxProcessedClientMessageIds {
            let drop = processedOrder.removeFirst()
            processedClientMessageIds.remove(drop)
        }
        return true
    }

    /// ユーザーがプロンプトを送った瞬間に entry を「考え中」にする。
    /// agent の初回トークンまで時間がかかる（コールド 40〜80s）間に別接続が
    /// cold-resume しても考え中を出せるようにする。pump の初回イベントを待たない。
    func notePromptSent(agentId: String, sessionId: String) {
        guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId) else { return }
        // 送信も活動として数える。長くアイドルだった entry では lastEventAt が前ターンのままなので、
        // 初回イベント前に購読者ゼロになると hung sweep が「30 分無音の生成中」と誤判定して kill する。
        entry.lastEventAt = Date()
        entry.outstandingPrompts += 1
        // 生成中でない送信は新しいターン。前のターンの終わった行と終わった workflow を捨てる（動いているバックグラウンドの
        // 作業は残す。アプリと adapter のトラッカーも同じ時点で捨てる）。生成中の差し込みは今のターンに合流するので捨てない。
        // 前のターンの出さなかった完了の push も捨てる（会話は先へ進んだ。このターンの done が push を決める）。
        if entry.phase == .idle, !entry.generating { startNewTurn(entry) }
        if entry.phase == .idle { entry.phase = .thinking }
        if !entry.generating { entry.generating = true; refreshSleepGuard() }
    }

    // MARK: - Mac 側予約キュー

    /// 生成中なら予約キューへ積んで true。アイドル（積む必要なし）や entry 不在なら false を
    /// 返し、呼び元が通常の即時送信にフォールバックする。同じ clientMessageId の重複投入と、
    /// 既に実行済み（user_message 経路とのレース）のものは弾く。
    func enqueue(agentId: String, sessionId: String, message: QueuedMessage) -> Bool {
        guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId) else { return false }
        guard entry.generating || entry.phase != .idle else { return false }
        guard !entry.messageQueue.contains(where: { $0.clientMessageId == message.clientMessageId }),
              !processedClientMessageIds.contains(message.clientMessageId) else { return true }
        entry.messageQueue.append(message)
        broadcastQueueState(entry)
        WebSocketServer.wslog("queue.enqueue agent=\(agentId) session=\(sessionId) count=\(entry.messageQueue.count)")
        return true
    }

    /// 未実行の予約を取り消す。
    func removeQueued(agentId: String, sessionId: String, clientMessageId: String) {
        guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId) else { return }
        let before = entry.messageQueue.count
        entry.messageQueue.removeAll { $0.clientMessageId == clientMessageId }
        if entry.messageQueue.count != before { broadcastQueueState(entry) }
    }

    private func queueStateEvent(_ entry: Entry) -> SessionEvent? {
        guard let sid = entry.sessionId else { return nil }
        let items: [[String: String]] = entry.messageQueue.map {
            ["clientMessageId": $0.clientMessageId, "content": $0.content]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return .queueState(agentId: entry.agentId, sessionId: sid, itemsJSON: json)
    }

    private func broadcastQueueState(_ entry: Entry) {
        guard let event = queueStateEvent(entry) else { return }
        for s in entry.subscribers.values { s(event) }
    }

    /// 再接続購読者へ現在状態のスナップショットを送る。
    /// - サブエージェントのカード（subagents）は、ターンの状態に関係なく全行で渡す（行はターンを越えて動く）。
    ///   session の全行（subagents。subagentSnapshot で聞いたもの）が無ければミラーから作る。
    /// - 進行中（phase != idle）なら turn_resume と、このターンの dynamic workflow のツリー。
    /// - 完了済み（idle）なら、終わっていない dynamic workflow（ターンが終わった後もバックグラウンドで続く）と、
    ///   直近 done を覚えていれば done を再送して、クライアント側の done 取りこぼしによる固着 spinner を解除させる。
    ///   done ハンドラは状態の解除自体は冪等だが、完了音・未読・予約の自動送信も起こす。iOS は処理済みと同じ messageId の
    ///   done ではそれらを省く。カードは done より先に送る（done の時点でバックグラウンドの作業が動いていると分かるように）。
    private func emitSnapshotIfActive(_ entry: Entry, _ send: @Sendable (SessionEvent) -> Void, subagents: String?) {
        // Mac 側の予約一覧を、空でも進行状態に関わらず同期する。entry の破棄や Bridge 再起動で
        // 消えた予約を iOS が「Mac で預かり中」のまま持ち続け、後続の予約送信まで止めないように。
        if let queueEvent = queueStateEvent(entry) {
            send(queueEvent)
        }
        guard let sid = entry.sessionId else { return }
        // mainagent の子のカードは、ターンが終わっていても渡す（子はターンを越えて動く）。
        emitSessionsCard(entry, send)
        // スナップショット時点の最終採番（actor 区間内で取る）。iOS はこれ以下の seq の同じ bubble の
        // delta を捨てる。値が大きすぎると live の delta まで捨てるので、必ずこの時点の値を使う。
        let snapshotSeq = entry.lastSeq > 0 ? entry.lastSeq : nil
        // 全行で置き換えさせる（いない間に終わった行が「実行中」のまま残らない。行が無くても agents: [] で渡す）。
        if let payload = subagents ?? entry.cards.subagentsSnapshot() {
            send(.workflowProgress(agentId: entry.agentId, sessionId: sid, payloadJSON: payload))
        }
        guard entry.phase != .idle else {
            for payload in entry.cards.workflowSnapshots(unfinishedOnly: true) {
                send(.workflowProgress(agentId: entry.agentId, sessionId: sid, payloadJSON: payload))
            }
            if let mid = entry.lastDoneMessageId {
                send(SessionEvent(
                    type: .done, agentId: entry.agentId, sessionId: sid,
                    messageId: mid, toolUseId: nil, content: nil,
                    toolName: nil, metadata: snapshotSeq.map { ["snapshotSeq": String($0)] }
                ))
            }
            return
        }
        let phaseStr = entry.phase == .streaming ? "streaming" : "thinking"
        send(.turnResume(
            agentId: entry.agentId, sessionId: sid, phase: phaseStr,
            messageId: entry.currentMessageId, textSoFar: entry.currentBubbleText,
            toolUseId: entry.currentToolUseId, toolName: entry.currentToolName,
            toolKind: entry.currentToolKind,
            toolStatus: entry.currentToolUseId != nil ? "in_progress" : nil,
            snapshotSeq: snapshotSeq
        ))
        // 進行中 dynamic workflow のツリーを再生（再接続でも「動いてる」を認知できる）。
        for payload in entry.cards.workflowSnapshots(unfinishedOnly: false) {
            send(.workflowProgress(agentId: entry.agentId, sessionId: sid, payloadJSON: payload))
        }
    }

    /// session のサブエージェントのカードの全行（subagentSnapshot）。トラッカーを持たない session は nil。
    /// 聞いている間に pump が subagents の payload を配ったら聞き直す（配った行より古い全行を後から送って、新しい状態を
    /// 上書きしないように）。ミラーが持っていない世代（作り直した entry・ターミナルのトラッカー）なら、ミラーをそれに合わせる。
    private func sessionSubagentSnapshot(_ entry: Entry) async -> String? {
        var snapshot: String?
        for _ in 0..<3 {
            let delivered = entry.subagentsDelivered
            snapshot = await entry.session.subagentSnapshot()
            if snapshot == nil || entry.subagentsDelivered == delivered { break }
        }
        if let snapshot, let rows = WorkflowCardMirror.rowCounts(snapshot: snapshot),
           !entry.cards.hasSubagents || rows.epoch != entry.cards.subagentsEpoch {
            entry.cards.apply(snapshot)
            noteFinished(entry)
            refreshSleepGuard()
        }
        return snapshot
    }

    /// バックグラウンドの作業（ターンより長く動くサブエージェント・シェル・dynamic workflow）の数。
    /// 行は session の全行（subagentSnapshot）とミラーの多い方で数える（pump がまだ配っていない始まり・終わりの間に、
    /// 動いている作業を閉じない）。dynamic workflow はミラーだけが知っている。
    private func backgroundWork(_ entry: Entry) async -> WorkflowCardMirror.Counts {
        let snapshot = await sessionSubagentSnapshot(entry)
        var counts = entry.cards.counts
        if let snapshot, let rows = WorkflowCardMirror.rowCounts(snapshot: snapshot) {
            counts.agents = max(counts.agents, rows.agents)
            counts.shells = max(counts.shells, rows.shells)
        }
        return counts
    }

    /// クライアントの能動プローブ (turn_status_request) に応答する。
    /// 進行中なら turn_resume、idle で直近 done を覚えていれば done を再送して、
    /// ライブ接続のまま done を取りこぼした固着 spinner を再接続を待たず解除させる。
    /// サブエージェントのカードは、どちらでも全行で渡す（acquire と同じ）。
    /// emitSnapshotIfActive は同じ done の再送・turn_resume・全行とも安全なので連投しても無害。
    func requestTurnStatus(agentId: String, sessionId: String, send: @escaping @Sendable (SessionEvent) -> Void) async {
        guard !sessionId.isEmpty else { return }
        // adapter 側で sid が確定し直した session は hub の key とずれるので、session の id でも引く
        // （ずれただけの生きたターンに下の done を返して誤って解除しない）。
        guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId) else {
            // Entry が無い = 進行中のターンは無い（ターミナルへの引き継ぎ・プロセス死などで done を
            // 出さずに消えた）。Windows と同じく done を返し、120 秒の強制解除を待たせない。
            // アプリが（Bridge の再起動などで）動いたままの古い行を持っていても取り直せるよう、行の無い subagents の
            // 全行を先に送る（停止がずっと not_running になる固着を防ぐ）。
            if let empty = Self.emptySubagentsSnapshot() {
                send(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: empty))
            }
            send(SessionEvent(
                type: .done, agentId: agentId, sessionId: sessionId,
                messageId: nil, toolUseId: nil, content: nil,
                toolName: nil, metadata: nil
            ))
            return
        }
        // 張り直した直後のターミナルの entry や作り直した entry は、idle でも直近 done を覚えていないので
        // スナップショットは予約一覧だけになる。送信中のまま entry が入れ替わった iPhone が 120 秒の強制解除まで
        // 「考え中」のまま残るので、プローブには messageId の無い done を返す（acquire のスナップショットは変えない）。
        // ただしターミナル側がターン中なら返さない（attach 直後で、そのターンの activity がまだ pump を通っていない）。
        var terminalTurn = false
        if entry.phase == .idle, entry.lastDoneMessageId == nil, let sid = entry.sessionId {
            terminalTurn = await ClaudeTerminalRegistry.shared.generatingSessionIds().contains(sid)
        }
        let subagents = await sessionSubagentSnapshot(entry)
        emitSnapshotIfActive(entry, send, subagents: subagents)
        if !terminalTurn, entry.phase == .idle, entry.lastDoneMessageId == nil {
            send(SessionEvent(
                type: .done, agentId: agentId, sessionId: entry.sessionId ?? sessionId,
                messageId: nil, toolUseId: nil, content: nil,
                toolName: nil, metadata: nil
            ))
        }
    }

    /// 行の無い subagents の全行（entry が無いとき turn_status_request に返す）。新しい世代なので、アプリは持っている行を捨てる。
    static func emptySubagentsSnapshot() -> String? {
        let out: [String: Any] = [
            "subtype": "workflow_snapshot", "taskId": WorkflowCardMirror.subagentsTaskId, "kind": "subagents",
            "workflowName": "サブエージェント", "status": "completed",
            "epoch": UUID().uuidString.lowercased(), "agents": [Any](),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 止めた行（カード）の stopped の payload が、接続への配信まで終わるのを待つ（§3.3 の Bridge の規則 8）。
    /// pump はミラーへ重ねるのと配るのを待ち無しで続けて行うので、ミラーが「動いていない」を示せば、その行の payload は
    /// 接続に届いている。entry が無い・行（カード）が無い・世代が違うときは待たない。上限を過ぎても返す（結果を遅らせすぎない）。
    func awaitStopDelivered(agentId: String, sessionId: String, request: StopTaskRequest,
                            timeout: TimeInterval = 0.5, interval: TimeInterval = 0.02) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId),
                  Self.stopTargetStillRunning(entry.cards, request) else { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
        }
    }

    /// ミラーが、止めた行（カード）をまだ動いているとしているか。
    static func stopTargetStillRunning(_ cards: WorkflowCardMirror, _ request: StopTaskRequest) -> Bool {
        guard let card = cards.cards[request.taskId] else { return false }
        if request.taskId == WorkflowCardMirror.subagentsTaskId {
            guard let rowId = request.rowId else { return false }
            if let epoch = request.epoch, let have = card.epoch, epoch != have { return false }
            return card.agents.values.contains { $0["id"] as? String == rowId && $0["state"] as? String == "running" }
        }
        return !card.isFinished
    }

    /// 通知のタイトル。adapter の表示名（"Codex" など）、無ければ agent id。
    static func pushTitle(agentId: String, displayName: String?) -> String {
        guard let name = displayName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return agentId }
        return name
    }

    /// /health の可観測性向上用: 現在生存しているセッション数。
    func aliveCount() -> Int { entries.count }

    /// 生成中のセッション数。/health の可観測性 + スリープ抑止判定に使う。
    func generatingCount() -> Int { entries.values.filter { $0.generating }.count }

    /// 指定 agent で現在生成中の sessionId 集合。list_sessions に running フラグを
    /// 載せ、タスクキル復帰直後（未接続）でもサイドバーに稼働中を出すために使う。
    func generatingSessionIds(agentId: String) -> Set<String> {
        var ids: Set<String> = []
        for entry in entries.values where entry.agentId == agentId && entry.generating {
            if let sid = entry.sessionId { ids.insert(sid) }
        }
        return ids
    }

    /// 指定 agent で、承認や質問への回答を待っている sessionId 集合。list_sessions に awaiting フラグを載せ、
    /// iPhone が開いていないチャットでもサイドバーに「回答待ち」を出すために使う。
    func awaitingSessionIds(agentId: String) -> Set<String> {
        var ids: Set<String> = []
        for entry in entries.values where entry.agentId == agentId && !entry.openActionRequestIds.isEmpty {
            if let sid = entry.sessionId { ids.insert(sid) }
        }
        return ids
    }

    /// 指定 agent で、ターンの後もサブエージェントか終わっていない dynamic workflow が動いている sessionId 集合（ミラーで数える）。
    /// list_sessions に background フラグを載せ、開いていないチャットでもサイドバーで稼働中に見せるために使う。
    /// バックグラウンドのコマンドだけでは数えない（dev サーバーは終わらないので、ずっと稼働中に見えてしまう）。
    func backgroundSessionIds(agentId: String) -> Set<String> {
        var ids: Set<String> = []
        for entry in entries.values where entry.agentId == agentId && entry.cards.counts.agentsOrWorkflows {
            if let sid = entry.sessionId { ids.insert(sid) }
        }
        return ids
    }

    /// テスト用: バックグラウンドのコマンドも含め、何か動いている sessionId 集合（ミラーに届いたかを待つのに使う）。
    func anyBackgroundSessionIdsForTesting(agentId: String) -> Set<String> {
        Set(entries.values.filter { $0.agentId == agentId && $0.cards.counts.any }.compactMap(\.sessionId))
    }

    /// 動いているセッションの一覧（mainagent の list_sessions 用）。
    struct LiveSessionInfo: Sendable {
        let agentId: String
        let sessionId: String
        let cwd: String?
        let displayName: String?
        let generating: Bool
        let phase: String
        let subscriberCount: Int
        let queued: Int
        /// 最後に出来事が届いた時刻（すべての PC の一覧の並び順）。
        var lastEventAt: Date = Date()
        /// 承認・質問の答えを待っているか（すべての PC の一覧の needs_approval）。
        var awaiting: Bool = false
    }

    func snapshot() -> [LiveSessionInfo] {
        entries.values.map { e in
            LiveSessionInfo(
                agentId: e.agentId, sessionId: e.sessionId ?? e.session.sessionId, cwd: e.cwd,
                displayName: e.displayName, generating: e.generating, phase: e.phase.rawValue,
                subscriberCount: e.subscribers.count, queued: e.messageQueue.count,
                lastEventAt: e.lastEventAt, awaiting: !e.openActionRequestIds.isEmpty)
        }
    }

    /// iPhone 以外（mainagent）からの送信の受け付け結果。
    enum ExternalSubmit: Equatable {
        /// アイドルだった。呼び元が session.send する。
        case sendNow
        /// 生成中だったので予約キューへ積んだ（done の後に hub が実行する）。
        case queued
        /// entry が無い。
        case missing
    }

    /// iPhone 以外（mainagent）からの送信を、WebSocket の user_message と同じ順で受け付ける。
    /// 即実行でも予約でも queue_dispatched（ユーザーの吹き出し）を全購読者へ配るので、
    /// 送り主は自分の clientMessageId の queue_dispatched を見て「自分のターンが始まった」とわかる。
    func submitExternal(agentId: String, sessionId: String, clientMessageId: String, content: String) -> ExternalSubmit {
        guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId) else { return .missing }
        if entry.generating || entry.phase != .idle {
            entry.messageQueue.append(QueuedMessage(clientMessageId: clientMessageId, content: content, skills: [], attachments: []))
            broadcastQueueState(entry)
            WebSocketServer.wslog("queue.enqueue(external) agent=\(agentId) session=\(sessionId) count=\(entry.messageQueue.count)")
            return .queued
        }
        _ = shouldProcessUserMessage(clientMessageId: clientMessageId)
        _ = recordQueueDispatched(agentId: agentId, sessionId: sessionId, clientMessageId: clientMessageId, content: content)
        notePromptSent(agentId: agentId, sessionId: sessionId)
        return .sendNow
    }

    // MARK: - mainagent の子のカード（workflow_progress kind = "sessions"）

    /// mainagent のセッション（"agentId:sessionId"）→ 子のカードの最新（全行）。Orchestrator が出す。
    /// entry とは別に持つ: mainagent のチャットはターンの合間に閉じられる（購読者ゼロで entry ごと消える）ので、
    /// 開き直して entry を作り直したときにも、ターンの進み具合（idle かどうか）に関わらず渡せるように。
    /// entry のカードの写し（cards）にも入れない（子はターンを越えて動き、entry より長く覚えておく）。
    private var sessionsCards: [String: String] = [:]
    private var sessionsCardOrder: [String] = []
    private static let maxSessionsCards = 200

    /// 子のカードを覚えて、そのセッションを見ている全員へ配る（採番しない。再接続では acquire のときに最新を渡す）。
    func publishSessionsCard(agentId: String, sessionId: String, payloadJSON: String) {
        let entry = resolveEntry(agentId: agentId, sessionId: sessionId)
        let sid = entry?.sessionId ?? sessionId
        let key = "\(agentId):\(sid)"
        if sessionsCards.updateValue(payloadJSON, forKey: key) == nil {
            sessionsCardOrder.append(key)
            if sessionsCardOrder.count > Self.maxSessionsCards {
                sessionsCards.removeValue(forKey: sessionsCardOrder.removeFirst())
            }
        }
        guard let entry else { return }
        let event = SessionEvent.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: payloadJSON)
        for s in entry.subscribers.values { s(event) }
    }

    /// そのセッションの子のカード（再接続・開き直しで渡す）。
    func sessionsCard(agentId: String, sessionId: String) -> String? {
        sessionsCards["\(agentId):\(sessionId)"]
    }

    private func emitSessionsCard(_ entry: Entry, _ send: @Sendable (SessionEvent) -> Void) {
        guard let sid = entry.sessionId, let payload = sessionsCards["\(entry.agentId):\(sid)"] else { return }
        send(.workflowProgress(agentId: entry.agentId, sessionId: sid, payloadJSON: payload))
    }

    /// Bridge 自身が出す出来事（mainagent の承認カードなど）を、そのセッションを見ている全員へ配る。
    /// 採番して再接続 replay にも載せる。承認要求は誰も見ていなければ push で呼び出す（pump と同じ）。
    func emitExternal(agentId: String, sessionId: String, event: SessionEvent) async {
        guard let entry = resolveEntry(agentId: agentId, sessionId: sessionId) else { return }
        let outbound = record(event, entry: entry)
        let subs = Array(entry.subscribers.values)
        for s in subs { s(outbound) }
        if event.type == .actionRequest && subs.isEmpty {
            await PushService.shared.broadcast(
                title: Self.pushTitle(agentId: entry.agentId, displayName: entry.displayName),
                body: event.metadata?["title"] ?? event.content ?? "承認が必要です",
                payload: [
                    "kind": "approval_request",
                    "agentId": entry.agentId,
                    "sessionId": entry.sessionId ?? "",
                    "requestId": event.messageId ?? "",
                    "bridgeId": KeyStore.loadOrCreateBridgeId()
                ]
            )
        }
    }

    /// 生成中セッションか、バックグラウンドのサブエージェント・dynamic workflow が動いているセッションが 1 つでもあれば
    /// Mac のアイドルスリープを抑止し、無ければ解放する。走行中の run が OS スリープで殺されるのを防ぐ
    /// （generating とミラーの変化時に呼ぶ）。バックグラウンドのコマンドだけでは保たない（dev サーバーで眠れなくなるため）。
    private func refreshSleepGuard() {
        SleepGuard.shared.setActive(entries.values.contains { $0.generating || $0.cards.counts.agentsOrWorkflows })
        // Live Activity の数（§8.2）。生成中は背景のサブエージェントだけ、生成中でなければ動いている行の全部。
        var counts: [String: Int] = [:]
        for (key, entry) in entries {
            let n = Self.liveActivityCount(entry)
            if n > 0 { counts[entry.sessionId ?? "hub:" + key] = n }
        }
        guard counts != lastLiveActivityCounts else { return }
        lastLiveActivityCounts = counts
        if let observer = Self.liveActivityObserver {
            observer.report(counts)
        } else {
            LiveActivityPublisher.report(.hub, counts: counts)
        }
    }

    /// Live Activity への数と終わった数の渡し先を差し替える（テスト用。nil なら LiveActivityPublisher）。
    struct LiveActivityObserver: Sendable {
        var report: @Sendable ([String: Int]) -> Void
        var finished: @Sendable (_ done: Int, _ failed: Int, _ stopped: Int) -> Void
    }
    nonisolated(unsafe) static var liveActivityObserver: LiveActivityObserver?

    private static func reportFinished(done: Int = 0, failed: Int = 0, stopped: Int = 0) {
        if let observer = liveActivityObserver {
            guard done > 0 || failed > 0 || stopped > 0 else { return }
            observer.finished(done, failed, stopped)
        } else {
            LiveActivityPublisher.reportFinished(done: done, failed: failed, stopped: stopped)
        }
    }

    /// 前に渡した Live Activity の数（変わったときだけ渡す）。
    private var lastLiveActivityCounts: [String: Int] = [:]

    private static func liveActivityCount(_ entry: Entry) -> Int {
        let c = entry.cards.counts
        return c.workflows + (entry.generating ? c.backgroundOnlyAgents : c.agents)
    }

    /// apply で終わったもの（lastFinished）を Live Activity の終わりの数に渡す。生成中は background の分だけ。
    private func noteFinished(_ entry: Entry) {
        var done = 0, failed = 0, stopped = 0
        for f in entry.cards.lastFinished where !entry.generating || f.background {
            switch f.state {
            case "failed": failed += 1
            case "stopped": stopped += 1
            default: done += 1
            }
        }
        Self.reportFinished(done: done, failed: failed, stopped: stopped)
    }

    /// entry を外す。その時点で数えていた分は stopped で渡す（close の stopped の payload が先に重なっていれば 0）。
    private func removeEntry(forKey key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        let n = Self.liveActivityCount(entry)
        if n > 0 { Self.reportFinished(stopped: n) }
        refreshSleepGuard()
    }

    /// 取りこぼし保険: release の経路漏れ等で「購読者ゼロ・非生成中」のまま残った
    /// entry を定期回収する。正常系では release / pump 側で即時 close されるので、
    /// ここで回収されるのは異常系のみ (プロセスリーク対策の最後の砦)。
    /// バックグラウンドの作業が残っている entry は、その作業が終わるか、イベントの無いまま backgroundIdleTimeout が過ぎるまで残す。
    private var reaperTask: Task<Void, Never>?

    private func startReaperIfNeeded() {
        guard reaperTask == nil else { return }
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.sweepOrphanedEntries()
            }
        }
    }

    /// generating のまま無音が続いたセッションをハング扱いで回収するまでの時間。
    /// done も release も来ない「永久 generating」がプロセスリークの漏れ口になるため。
    /// 購読者が居る (ユーザーが見ている) 間は手動 interrupt に任せて自動回収しない。
    private static let generatingIdleTimeout: TimeInterval = 30 * 60

    /// バックグラウンドの作業（サブエージェント・シェル・dynamic workflow）が残っている entry を、購読者がいないまま
    /// イベントの無い状態で残しておく上限。終わりの知らせを取りこぼした行や、止まらない dev サーバーで永久に残さない
    /// （閉じるときは session が実行中の行を stopped で閉じる payload を流す）。
    private static let backgroundIdleTimeout: TimeInterval = 6 * 60 * 60

    private func sweepOrphanedEntries() async {
        let orphaned = entries.filter { $0.value.subscribers.isEmpty && !$0.value.generating }
        for (key, entry) in orphaned {
            // バックグラウンドの作業がある間は閉じない（終わった後の知らせのターンの done で push してから閉じる）。
            // ただし、イベントの無いまま backgroundIdleTimeout が過ぎたら閉じる。
            let idleFor = Date().timeIntervalSince(entry.lastEventAt)
            if idleFor < Self.backgroundIdleTimeout, await backgroundWork(entry).any { continue }
            // 聞いている間に購読者が付いた・送信が始まった・外された entry は触らない。
            guard entries[key] === entry, entry.subscribers.isEmpty, !entry.generating else { continue }
            // 預かった完了の push があれば、猶予の後に出してから閉じる（settleOwedPush）。
            if idleFor < Self.backgroundIdleTimeout, holdForOwedPush(entry) { continue }
            removeEntry(forKey: key)
            await entry.session.close()
            let note = entry.cards.counts.any ? " (background idle \(Int(idleFor / 60))min)" : ""
            WebSocketServer.wslog("hub.sweep closed orphaned session key=\(key)\(note)")
        }
        refreshSleepGuard()
        // 購読者ゼロ・generating のままイベントが長時間止まっているセッションはハングと
        // 判断して interrupt → close。done が永遠に来ないと release 経路が全て塞がり、
        // openclaw 等の子プロセスが永久に残るため (取りこぼし保険の generating 版)。
        let hung = entries.filter {
            $0.value.subscribers.isEmpty && $0.value.generating &&
            Date().timeIntervalSince($0.value.lastEventAt) > Self.generatingIdleTimeout
        }
        for (key, entry) in hung {
            removeEntry(forKey: key)
            let idleMin = Int(Date().timeIntervalSince(entry.lastEventAt) / 60)
            WebSocketServer.wslog("hub.sweep closing hung generating session key=\(key) idle=\(idleMin)min")
            await entry.session.interrupt()
            await entry.session.close()
            entry.generating = false
            refreshSleepGuard()
        }
    }

    /// 既にある entry にこの購読者を足して、今の状態のスナップショットを「この購読者だけに」送る。
    /// session の全行（subagentSnapshot）は購読する前に聞き、購読とスナップショットは actor 同期区間内で行うので、
    /// pump の fan-out が先に割り込まない（全行より新しい行を先に受けて、古い全行で上書きされることもない）。
    /// 聞いている間に entry が閉じられた・入れ替わったら false（呼び元が引き直す）。
    private func join(_ entry: Entry, key: String, subscriberId: UUID,
                      send: @escaping @Sendable (SessionEvent) -> Void) async -> Bool {
        let subagents = await sessionSubagentSnapshot(entry)
        guard entries[key] === entry else { return false }
        entry.subscribers[subscriberId] = send
        subscriberKey[subscriberId] = key
        // 作業が終わった後に開いた（終わりを見る）。預かった完了の push はもう要らない。
        if entry.owedPush != nil, !entry.cards.counts.agentsOrWorkflows {
            entry.owedPush = nil
            entry.owedPushSettle = nil
        }
        emitSnapshotIfActive(entry, send, subagents: subagents)
        return true
    }

    /// WS が session を購読する。既存の (agentId, sid) entry があれば再利用し、無ければ adapter.openSession() で新規作成。
    func acquire(agentId: String, sessionId: String?, cwd: String?, adapter: AgentAdapter,
                 subscriberId: UUID, send: @escaping @Sendable (SessionEvent) -> Void,
                 options: SessionOptions? = nil) async -> AgentSession {
        startReaperIfNeeded()
        if let sid = sessionId {
            let key = "\(agentId):\(sid)"
            // 進行状態に関わらず再接続スナップショットを送る（サブエージェントのカードはターンを越えて動く）。
            while let entry = entries[key] {
                if await join(entry, key: key, subscriberId: subscriberId, send: send) { return entry.session }
            }
        }
        let session = await adapter.openSession(sessionId: sessionId, cwd: cwd, options: options)
        // 新しい session のサブエージェントのカード（行が無くても epoch 付き）。アプリが前の世代（閉じた entry・
        // Bridge の再起動前）のまま持っている行を消せるように渡す。entry を作る前に聞く（下の再チェックから
        // entry の登録までを、待ちの無い一続きにするため）。
        let fresh = await session.subagentSnapshot()
        // openSession の await 中に actor が再入し、別の接続が同じ sid を先に確定させている
        // ことがある (iOS はセッションリスト表示で同一 sid を同一秒に一斉 resume する)。
        // ここで再チェックしないと、今作った entry が下の entries[initialKey] 代入で先発を
        // 無言上書きし、先発の session.close() が呼ばれず openclaw 等の子プロセスが orphan 化する。
        if let sid = sessionId {
            let key = "\(agentId):\(sid)"
            while let existing = entries[key] {
                if await join(existing, key: key, subscriberId: subscriberId, send: send) {
                    await session.close()   // 重複して作ってしまった session は破棄
                    return existing.session
                }
            }
        }
        let initialKey: String
        if let sid = sessionId {
            initialKey = "\(agentId):\(sid)"
        } else if !session.sessionId.isEmpty, entries["\(agentId):\(session.sessionId)"] == nil {
            // 新規は session 自身の（pending）ID で key を作る。WebSocketServer の notePromptSent /
            // recordUserMessage / enqueue は session.sessionId で引くので、別の乱数だと初回ターンで
            // entry が見つからず generating が立たない（bootstrap 中の切断で即 close される）。
            initialKey = "\(agentId):\(session.sessionId)"
        } else {
            initialKey = "\(agentId):pending-\(UUID().uuidString.prefix(8))"
        }
        let entry = Entry(agentId: agentId, sessionId: sessionId, session: session)
        entry.displayName = adapter.displayName
        entry.cwd = cwd
        entry.lastSeq = lastSeqByKey[initialKey] ?? Self.seqBase
        entry.startSeq = entry.lastSeq
        // ミラーを session のトラッカーから始める（ターミナルのトラッカーは entry より長く生き、行を持っていることがある）。
        if let fresh { entry.cards.apply(fresh) }
        entry.subscribers[subscriberId] = send
        entries[initialKey] = entry
        subscriberKey[subscriberId] = initialKey
        // 新しく作った entry の予約は空。前の entry（破棄済み / Bridge 再起動前）で預かった予約カードが
        // iOS に残らないよう、既知の sid なら空の一覧を同期する（pending は sid 未確定なので送らない）。
        if let queueEvent = queueStateEvent(entry) { send(queueEvent) }
        // 開き直した mainagent のチャットにも、子のカードを渡す（entry を作り直しても Bridge が覚えている）。
        emitSessionsCard(entry, send)
        if let fresh, let sid = entry.sessionId {
            send(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: fresh))
        }
        refreshSleepGuard()
        let hub = self
        entry.pumpTask = Task { [weak entry] in
            guard let entry else { return }
            await hub.pump(entry: entry, initialKey: initialKey)
        }
        return session
    }

    /// 指定セッションを強制的に閉じる（ターミナル側への引き継ぎ用）。
    ///
    /// Bridge が spawn した claude と、ユーザーがターミナルで開いた claude が同じ
    /// session を同時に持つと、拒否されずに両方動いて会話が二股になる（実測）。
    /// ターミナルの SessionStart は最初のプロンプトより前に発火するので、そこで
    /// spawn 側を止めれば安全に引き継げる。購読者は残し、同じ購読者のままターミナルへ attach し直す。
    /// 生成中でも止める: 二股より中断の方が軽い。
    func closeSession(agentId: String, sessionId: String) async -> Bool {
        let key = "\(agentId):\(sessionId)"
        guard let entry = entries[key] else { return false }
        // spawn 側を止めてターミナルへ引き継ぐときは、見ている iPhone をそのままターミナルへ付け替える
        // （次の送信を待たずにターミナル側の進行が流れる）。閉じるのがターミナルの session
        // （ターミナル終了で取り直す経路）なら張り直さない。
        var terminalLive = false
        if !entry.subscribers.isEmpty, !(entry.session is ClaudeTerminalSession) {
            terminalLive = await ClaudeTerminalRegistry.shared.isLive(sessionId)
            // await の間に他の経路で外された / 張り直された（SessionStart の重複など）なら、そちらに任せる。
            guard entries[key] === entry else { return false }
        }
        removeEntry(forKey: key)
        let reattach = terminalLive && !entry.subscribers.isEmpty
        // 購読者の key 紐付けは外す（張り直す場合は下で新しい entry に付け直す）。張り直さない場合、
        // WS 側は次の userMessage で currentOrAcquireSession → acquire に戻る。
        for subId in entry.subscribers.keys { subscriberKey.removeValue(forKey: subId) }
        // 止めるターンの終わりを購読中の iPhone へ伝える。pump は cancel するので session からの
        // done は届かず、送らないと「考え中」が固着する。
        if entry.generating || entry.phase != .idle {
            let done = record(
                .done(agentId: entry.agentId, sessionId: sessionId,
                      messageId: entry.currentMessageId ?? UUID().uuidString),
                entry: entry
            )
            for s in entry.subscribers.values { s(done) }
            entry.generating = false
            entry.phase = .idle
        }
        // 張り直さないなら、預かっていた予約はこの entry と一緒に消える。予約カードを iOS に残さない。
        if !reattach, !entry.messageQueue.isEmpty {
            entry.messageQueue.removeAll()
            broadcastQueueState(entry)
        }
        var reattached: ClaudeTerminalSession?
        if reattach {
            let terminal = ClaudeTerminalSession(agentId: entry.agentId, sessionId: sessionId)
            let reopened = Entry(agentId: entry.agentId, sessionId: sessionId, session: terminal)
            reopened.displayName = entry.displayName
            reopened.cwd = entry.cwd
            // seq は前の entry の続きから振る（iOS の lastHistorySeq と揃える）。
            reopened.lastSeq = lastSeqByKey[key] ?? Self.seqBase
            // 引き継ぎは購読者ごと hub の中で途切れずに続くので、差分同期の起点は前の entry のものを使う。
            reopened.startSeq = entry.startSeq
            reopened.subscribers = entry.subscribers
            // 預かっていた予約もターミナルへ引き継ぐ（ターミナルの次の done で受け箱へ流れる）。
            reopened.messageQueue = entry.messageQueue
            entry.messageQueue.removeAll()
            entries[key] = reopened
            for subId in reopened.subscribers.keys { subscriberKey[subId] = key }
            if !reopened.messageQueue.isEmpty { broadcastQueueState(reopened) }
            let hub = self
            reopened.pumpTask = Task { [weak reopened] in
                guard let reopened else { return }
                await hub.pump(entry: reopened, initialKey: key)
            }
            reattached = terminal
        }
        entry.pumpTask?.cancel()
        await entry.session.close()
        // await の間に購読者が抜けて閉じられていたら attach しない（閉じた session に backlog を渡さない）。
        if let reattached, let reopened = entries[key], reopened.session === reattached {
            await ClaudeTerminalRegistry.shared.attach(reattached)
            // 引き継いだ購読者のサブエージェントのカードを、ターミナルのトラッカーの全行（行が無くても epoch 付き）に
            // 置き換える。止めた spawn 側の行（pump を止めたので stopped の知らせは届かない）を「実行中」のまま残さない。
            if let snapshot = await sessionSubagentSnapshot(reopened), entries[key] === reopened {
                let event = SessionEvent.workflowProgress(agentId: reopened.agentId, sessionId: sessionId, payloadJSON: snapshot)
                for s in reopened.subscribers.values { s(event) }
            }
        }
        refreshSleepGuard()
        WebSocketServer.wslog("sessionhub.closeSession \(key) (handover to terminal) reattach=\(reattach)")
        return true
    }

    /// この購読者が今もこの session の entry に繋がっているか。pump 終了（プロセス死・
    /// ターミナル終了）や closeSession で外れていたら false → WS 側は acquire し直す。
    func holds(subscriberId: UUID, session: AgentSession) -> Bool {
        guard let key = subscriberKey[subscriberId], let entry = entries[key] else { return false }
        return entry.session === session
    }

    /// WS が閉じた時に呼ぶ。
    /// 生成中 (generating) のセッションは閉じない → hermes 等は走り続け、done 時に
    /// subscribers が無ければ APNs push になる。pump が done 後に閉じる。
    /// バックグラウンドの作業（サブエージェント・シェル・dynamic workflow）が残っているセッションも閉じない
    /// （プロセスごと止めると作業が消え、終わりの知らせも来ない）。作業が終わった後の done か sweep で閉じる。
    /// 生成中でなく購読者も居なくなったセッションは即閉じてプロセス (openclaw 等) を解放する。
    func release(subscriberId: UUID) async {
        guard let key = subscriberKey.removeValue(forKey: subscriberId) else { return }
        guard let entry = entries[key] else { return }
        entry.subscribers.removeValue(forKey: subscriberId)
        if entry.subscribers.isEmpty && !entry.generating {
            if await backgroundWork(entry).any { return }
            // 聞いている間に購読者が付いた・送信が始まった・外された entry は触らない。
            guard entries[key] === entry, entry.subscribers.isEmpty, !entry.generating else { return }
            // 預かった完了の push があれば、猶予の後に出してから閉じる（settleOwedPush）。
            if holdForOwedPush(entry) { return }
            removeEntry(forKey: key)
            await entry.session.close()
        }
    }

    /// Mac 側予約キューの先頭を 1 件実行に移す（ターンの終わりに呼ぶ）。実行に移したら true。
    /// user_message 経路と二重実行にならないよう clientMessageId で冪等化する。
    private func dispatchNextQueued(_ entry: Entry) -> Bool {
        var dispatchedNext = false
        while !entry.messageQueue.isEmpty && !dispatchedNext {
            let next = entry.messageQueue.removeFirst()
            guard shouldProcessUserMessage(clientMessageId: next.clientMessageId) else { continue }
            // 予約の実行も新しいターン。前のターンの終わった行と終わった workflow を捨てる（notePromptSent と同じ）。
            if entry.phase == .idle, !entry.generating { startNewTurn(entry) }
            entry.generating = true
            entry.phase = .thinking
            entry.outstandingPrompts += 1
            refreshSleepGuard()
            if let sid = entry.sessionId {
                // 実行通知 → 予約カードを通常のユーザーバブルへ置き換えさせる。
                // 併せて live buffer に user_message として採番し、再接続 replay でも順序が合うようにする。
                let dispatched = record(
                    SessionEvent.queueDispatched(
                        agentId: entry.agentId, sessionId: sid,
                        clientMessageId: next.clientMessageId, content: next.content),
                    entry: entry
                )
                for s in entry.subscribers.values { s(dispatched) }
                broadcastQueueState(entry)
                WebSocketServer.wslog("queue.dispatch agent=\(entry.agentId) session=\(sid) remaining=\(entry.messageQueue.count)")
            }
            // send はターン完了まで返らないため pump をブロックしない Task で投げる。
            let session = entry.session
            let message = next
            Task {
                await WebSocketServer.dispatch(
                    session, content: message.content, skills: message.skills,
                    attachments: message.attachments, voice: message.voice, typedByUser: message.typedByUser)
            }
            dispatchedNext = true
        }
        return dispatchedNext
    }

    /// 新しいターンの始まり（生成中でない送信・予約の実行・ほかの画面からの発話）。前のターンの終わった行と終わった workflow を
    /// 捨てる（動いているバックグラウンドの作業は残す）。前のターンの出さなかった完了の push も捨てる（会話は先へ進み、
    /// このターンの done が push を決める）。
    private func startNewTurn(_ entry: Entry) {
        entry.cards.pruneFinished()
        entry.owedPush = nil
        entry.owedPushSettle = nil
    }

    // MARK: - 完了の push

    /// バックグラウンドの作業が全部終わってから、知らせのターンを待つ猶予（cron の backgroundSettleGrace と同じ 120 秒）。
    /// 過ぎても何も始まらなければ、出さなかった完了の push（owedPush）を出す。
    private var owedPushGrace: TimeInterval = 120
    /// テスト用: 猶予を短くする。
    func setOwedPushGraceForTesting(_ seconds: TimeInterval) { owedPushGrace = seconds }
    /// テスト用: 完了の push（kind "chat"）を見る。(agentId, sessionId, 本文)。
    nonisolated(unsafe) static var chatPushObserver: (@Sendable (String, String, String) -> Void)?
    private static let defaultPushBody = "新しい応答があります"

    /// 会話ごと（"<agentId>:<sessionId>"）に最後に完了の push を送った時刻。同じ会話へ続けて出さないために使う。
    private var lastChatPushAt: [String: Date] = [:]
    /// 同じ会話へ claude --bg の完了の push を続けて出さない間隔。
    private static let backgroundPushGap: TimeInterval = 60

    private func sendChatPush(_ entry: Entry, body: String) async {
        await deliverChatPush(agentId: entry.agentId, sessionId: entry.sessionId ?? "",
                              title: Self.pushTitle(agentId: entry.agentId, displayName: entry.displayName), body: body)
    }

    private func deliverChatPush(agentId: String, sessionId: String, title: String, body: String) async {
        if !sessionId.isEmpty { lastChatPushAt["\(agentId):\(sessionId)"] = Date() }
        Self.chatPushObserver?(agentId, sessionId, body)
        await PushService.shared.broadcast(
            title: title,
            body: body,
            payload: [
                "kind": "chat",
                "agentId": agentId,
                "sessionId": sessionId,
                // タップで送信元の Mac のその会話を開けるように載せる（承認要求と同じ）。
                "bridgeId": KeyStore.loadOrCreateBridgeId()
            ]
        )
    }

    /// claude --bg のジョブの最初の作業が終わったときの push（BACKGROUND_CONTROL §7.9）。
    /// その会話を開いている人がいる（entry がある）か、同じ会話へ 60 秒以内に出していれば出さない。出したら true。
    @discardableResult
    func pushBackgroundSessionEnded(sessionId: String, body: String, now: Date = Date()) async -> Bool {
        let key = "claude:\(sessionId)"
        guard entries[key] == nil else { return false }
        if let last = lastChatPushAt[key], now.timeIntervalSince(last) < Self.backgroundPushGap { return false }
        await deliverChatPush(agentId: "claude", sessionId: sessionId,
                              title: Self.pushTitle(agentId: "claude", displayName: "Claude Code"), body: body)
        return true
    }

    /// ターンの終わりの done の完了の push（送った発話がまだ残っている done では呼ばない）。
    /// - 誰かが見ていれば出さない（出さなかった push も捨てる。利用者は終わりを見た）。
    /// - バックグラウンドのサブエージェントか workflow が動いていれば出さず、本文を owedPush に預ける（その作業が終わった
    ///   ときの知らせのターンの done が引き継ぐ）。バックグラウンドのコマンドだけなら待たない（dev サーバーは終わらない）。
    /// - 本文の無い知らせのターン（metadata.silent）と、応答の無いまま error で閉じたターン（metadata.errored）は自分の push を
    ///   出さない。預かった push があれば、silent では今出し（作業は全部終わり、もっと良い本文は来ない）、errored では猶予の
    ///   後に出す（settleOwedPush）。
    /// - 本文はこのターンの最後の吹き出しの頭（前置きの「調べます」ではなく結論）。
    private func pushAtDone(_ entry: Entry, metadata: [String: String]?, watched: Bool,
                            background: WorkflowCardMirror.Counts) async {
        // この done が、預かった push を引き継ぐ（出すか預け直すかをここで決める）。
        entry.owedPushSettle = nil
        guard !watched else {
            entry.owedPush = nil
            return
        }
        let quiet = metadata?["silent"] == "1" || metadata?["errored"] == "true"
        let body = quiet ? nil : (entry.bubbles.lastBubble(limit: 180) ?? Self.defaultPushBody)
        if background.agentsOrWorkflows {
            if let body { entry.owedPush = body }
            return
        }
        if let body {
            entry.owedPush = nil
            await sendChatPush(entry, body: body)
        } else if let owed = entry.owedPush, metadata?["silent"] == "1" {
            entry.owedPush = nil
            await sendChatPush(entry, body: owed)
        } else if entry.owedPush != nil {
            armOwedPushSettle(entry)
        }
    }

    /// 送った発話が CLI の待ち行列に残っている間の知らせのターン（metadata.origin = "task-notification"）の done に、
    /// metadata.pending = "1" を付ける。Claude の adapter は自分で付けるが、Codex・OpenCode の知らせのターンは付けないので、
    /// ここで揃える。アプリと差分 replay は、この印だけで「自分のターンはまだ続く」と分かる（判定は done の処理の
    /// promptPending と同じ）。
    static func stampingPending(_ event: SessionEvent, outstandingPrompts: Int) -> SessionEvent {
        guard event.type == .done, outstandingPrompts > 0,
              event.metadata?["origin"] == "task-notification",
              event.metadata?["pending"] != "1" else { return event }
        return event.addingMetadata(["pending": "1"])
    }

    /// 預かった push を出すかを、owedPushGrace の後に決める（もう置いてあれば置き直さない）。
    private func armOwedPushSettle(_ entry: Entry) {
        guard entry.owedPush != nil, entry.owedPushSettle == nil else { return }
        let token = UUID()
        entry.owedPushSettle = token
        let grace = owedPushGrace
        let hub = self
        Task { [weak entry] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            guard let entry else { return }
            await hub.settleOwedPush(entry, token: token)
        }
    }

    /// 預かった push があれば閉じない（猶予の後に settleOwedPush が出してから閉じる）。閉じないなら true。
    private func holdForOwedPush(_ entry: Entry) -> Bool {
        guard entry.owedPush != nil else { return false }
        armOwedPushSettle(entry)
        return true
    }

    /// 作業が無くなってから猶予の間に、知らせのターンが始まらなかった（Codex の multi-agent v2 は子が終わっても親が起きない。
    /// 本文の無い知らせのターンは silent の done で終わる）。預かった完了の push を出し、見る人も作業も無ければ閉じる
    /// （done の後と同じ）。その間にターンが始まっていれば、そのターンの done が引き継ぐ。
    private func settleOwedPush(_ entry: Entry, token: UUID) async {
        guard entry.owedPushSettle == token else { return }
        entry.owedPushSettle = nil
        guard entries.values.contains(where: { $0 === entry }), entry.owedPush != nil,
              !entry.generating, entry.phase == .idle else { return }
        let background = await backgroundWork(entry)
        // 聞いている間に、新しい作業・ターン・done・予約が来ていれば、そちらに任せる。
        guard entry.owedPushSettle == nil, let body = entry.owedPush, !entry.generating, entry.phase == .idle,
              !background.agentsOrWorkflows else { return }
        entry.owedPush = nil
        guard entry.subscribers.isEmpty else { return }
        await sendChatPush(entry, body: body)
        if entry.subscribers.isEmpty, !entry.generating, !background.any {
            await entry.session.close()
        }
    }

    /// 送ったプロンプトが全部 error で返ってから done を待つ猶予（error の直後に done を続ける adapter の分）。
    private static let erroredTurnSettleDelay: UInt64 = 5_000_000_000

    /// done を伴わない error で終わったターンを、done の代わりに片付ける。猶予のうちに done・次の送信・
    /// 続きのイベントが来ていたら何もしない。預かっている予約があれば done と同じく次を実行に移し
    /// （予約カードを「預かり中」のまま残さない）、無くて購読者も居なければ閉じてプロセスを解放する
    /// （バックグラウンドの作業が残っていれば、done の後と同じく閉じない）。
    private func settleErroredTurn(_ entry: Entry, token: UUID) async {
        guard entry.erroredTurnSettle == token else { return }
        entry.erroredTurnSettle = nil
        guard entries.values.contains(where: { $0 === entry }),
              entry.generating, entry.phase == .idle, entry.outstandingPrompts == 0 else { return }
        entry.generating = false
        entry.bubbles.reset()
        refreshSleepGuard()
        if dispatchNextQueued(entry) { return }
        guard entry.subscribers.isEmpty else { return }
        let background = await backgroundWork(entry)
        if !background.any, entry.subscribers.isEmpty, !entry.generating, !holdForOwedPush(entry) {
            await entry.session.close()
        }
    }

    /// pump task: session.events を消費 → 全 subscriber に fan-out、
    /// done で subscriber=0 なら PushService に escalate。
    private func pump(entry: Entry, initialKey: String) async {
        var currentKey = initialKey
        do {
            for try await incoming in entry.session.events {
                // closeSession で止めた session の残り（cancel 後もバッファ済みの分は届く）は流さない。
                // 引き継ぎで送った done の後に古いターンの delta が届くと、iPhone が「考え中」に戻る。
                if Task.isCancelled { break }
                // 送った発話が待ち行列にある間の知らせのターンの done には、記録と配信の前に pending = "1" を付ける。
                let event = Self.stampingPending(incoming, outstandingPrompts: entry.outstandingPrompts)
                // sessionStarted → key を確定 ID に張り替え
                if event.type == .sessionStarted, let sid = event.sessionId, entry.sessionId == nil {
                    let newKey = "\(entry.agentId):\(sid)"
                    if currentKey != newKey {
                        if let dup = entries[newKey], dup !== entry {
                            // 別の pending セッションが先に同じ確定 sid に解決済み。後発の
                            // この entry は重複なので、購読者を既存へ付け替えてから自分を畳む。
                            // close を呼ばず捨てると子プロセスが orphan として残り続ける。
                            for (subId, send) in entry.subscribers {
                                dup.subscribers[subId] = send
                                subscriberKey[subId] = newKey
                            }
                            entry.subscribers.removeAll()
                            entries.removeValue(forKey: currentKey)
                            await entry.session.close()
                            refreshSleepGuard()
                            return
                        }
                        entries.removeValue(forKey: currentKey)
                        entries[newKey] = entry
                        // subscriberKey 内の old key を新 key に置換
                        for (s, k) in subscriberKey where k == currentKey {
                            subscriberKey[s] = newKey
                        }
                        currentKey = newKey
                    }
                    // 新規の key が最初から確定 ID と同じ（BuddySession など）でも sessionId は確定させる。
                    entry.sessionId = sid
                    // 同じ sid を前に採番していれば、その続きから振る（seq を後戻りさせない）。
                    // 前の entry の続きではない（その間の分は hub を通っていない）ので、差分同期の起点もそこへ上げる。
                    if let prev = lastSeqByKey[newKey], prev > entry.lastSeq {
                        entry.lastSeq = prev
                        entry.startSeq = prev
                    }
                }
                // ハングセッション回収 (B3) 用に最終イベント時刻を更新。
                entry.lastEventAt = Date()
                // 進行状態ミラーを fan-out 前に更新（再接続スナップショット用）。
                switch event.type {
                case .assistantDelta:
                    entry.phase = .streaming
                    if event.messageId != entry.currentMessageId {
                        entry.currentMessageId = event.messageId
                        entry.currentBubbleText = ""
                    }
                    entry.currentBubbleText += event.content ?? ""
                    if !entry.generating { entry.generating = true; refreshSleepGuard() }
                case .activity:
                    entry.phase = .thinking
                    if !entry.generating { entry.generating = true; refreshSleepGuard() }
                case .toolStart:
                    entry.phase = .thinking
                    entry.currentToolUseId = event.toolUseId
                    entry.currentToolName = event.toolName
                    entry.currentToolKind = event.metadata?["kind"]
                    if !entry.generating { entry.generating = true; refreshSleepGuard() }
                case .toolEnd:
                    if entry.currentToolUseId == event.toolUseId {
                        entry.currentToolUseId = nil
                        entry.currentToolName = nil
                        entry.currentToolKind = nil
                    }
                    entry.phase = .thinking   // 次の bubble を生成中＝考え中
                case .assistantTurnEnd:
                    entry.phase = .thinking
                    entry.currentMessageId = nil
                    entry.currentBubbleText = ""
                case .workflowProgress:
                    // ミラーへ重ねる。アイドル中（idle）は phase と generating を変えない: 届くのはターンより長く動く作業
                    // （サブエージェント・バックグラウンドのコマンド・dynamic workflow）の進み具合で、考え中に戻すと知らせの
                    // ターンの done まで生成中のまま固まる。スリープ抑止はミラーの動いている作業で保つ。
                    if entry.cards.apply(event.content) == WorkflowCardMirror.subagentsTaskId {
                        entry.subagentsDelivered += 1
                    }
                    if entry.phase != .idle { entry.generating = true }
                    // 外した entry の終わりは removeEntry が stopped で数え終わっている（二重に数えない）。
                    if entries[currentKey] === entry { noteFinished(entry) }
                    refreshSleepGuard()
                    // 完了の push を預かったまま、ターンの外で作業が無くなった。見ている人がいれば終わりを見たので捨て、
                    // いなければ知らせのターンを待つ猶予を置く（来なければ預かった push を出す）。
                    if entry.owedPush != nil, entry.phase == .idle, !entry.generating,
                       !entry.cards.counts.agentsOrWorkflows {
                        if entry.subscribers.isEmpty {
                            armOwedPushSettle(entry)
                        } else {
                            entry.owedPush = nil
                            entry.owedPushSettle = nil
                        }
                    }
                case .userMessage:
                    // ほかの画面（ターミナル・別の端末）からの発話。生成中でなければ新しいターンの始まりなので、
                    // 前のターンの終わった行と終わった workflow を捨てる（notePromptSent と同じ。アプリも同じ時点で捨てる）。
                    if entry.phase == .idle, !entry.generating { startNewTurn(entry) }
                case .error:
                    // error だけでターンを終える adapter がある（spawn 失敗・未認証など、done が来ない）。
                    // notePromptSent で立てた generating / thinking が残ると、再接続のたびに turn_resume で
                    // 「考え中」が復活し、スリープ抑止・release での close・予約の受付も生成中のまま固着する。
                    // 送ったプロンプトが全部返ったときだけ進行状態を戻す（実行中ターンへの同時送信を
                    // 拒否した error など、走っているターンが残る error では戻さない）。
                    // generating はすぐには落とさない。error の後に done を続ける adapter（Codex の
                    // willRetry=false は後から turn/completed で done）で、その間に release / sweep が閉じると
                    // done の push・予約の実行が失われる。猶予のうちに done が来なければ settleErroredTurn が
                    // done の代わりに片付ける（予約の実行・購読者ゼロでの close）。途中経過の error でも、
                    // 続く delta / activity / toolStart で phase は立ち直る。
                    if entry.outstandingPrompts > 0 {
                        entry.outstandingPrompts -= 1
                        if entry.outstandingPrompts == 0 {
                            entry.phase = .idle
                            entry.currentMessageId = nil
                            entry.currentBubbleText = ""
                            entry.currentToolUseId = nil
                            entry.currentToolName = nil
                            entry.currentToolKind = nil
                            // done と同じく、終わった dynamic workflow だけを捨てる（バックグラウンドの作業は残す）。
                            entry.cards.dropFinishedWorkflows()
                            let token = UUID()
                            entry.erroredTurnSettle = token
                            let hub = self
                            Task { [weak entry] in
                                try? await Task.sleep(nanoseconds: Self.erroredTurnSettleDelay)
                                guard let entry else { return }
                                await hub.settleErroredTurn(entry, token: token)
                            }
                        }
                    }
                default:
                    break
                }
                if event.type == .assistantDelta, let c = event.content {
                    entry.bubbles.append(c, messageId: event.messageId)
                }
                // fan-out 前に採番・記録する（全 subscriber が同じ seq を見る）。
                // クライアントはこの seq を lastHistorySeq に取り込み、再接続時の差分同期に使う。
                let outbound = record(event, entry: entry)
                let subs = Array(entry.subscribers.values)
                for s in subs { s(outbound) }

                if event.type == .done {
                    // 送った発話が、まだ CLI の待ち行列に残っている done。その発話には後で自分の done が来る:
                    // - 知らせのターン（バックグラウンドの作業が終わり、CLI が自分から始めたターン。Claude・Codex・OpenCode が
                    //   metadata.origin = "task-notification" を付ける）の done で、その間に送った発話がある（outstandingPrompts > 0）
                    // - adapter が、書いたがまだ始まっていない発話を知らせた（metadata.pending = "1"。最後の文を生成中に差し込んだ
                    //   発話は今のターンに合流せず、result の後に回る。実測 S9）
                    // ここではターンの終わりにしない（generating を落とさず、予約も実行せず、閉じない。閉じるとその発話ごと
                    // プロセスが止まる）。push もしない（待っている発話の done で 1 回。吹き出しもそこまで区切らない）。
                    // どちらの場合も終わった行は捨てない（捨てるのは新しいターンの始まりだけ）。
                    let isNotification = event.metadata?["origin"] == "task-notification"
                    let promptPending = (isNotification && entry.outstandingPrompts > 0) || event.metadata?["pending"] == "1"
                    if promptPending {
                        // このターンの吹き出しは閉じた。次は送った発話の返事を待つ（考え中）。
                        entry.phase = .thinking
                        // 送った発話のターンの done なら、その発話は返った（残りは待ち行列の発話）。
                        if !isNotification, entry.outstandingPrompts > 1 { entry.outstandingPrompts -= 1 }
                    } else {
                        entry.generating = false
                        entry.phase = .idle
                        entry.outstandingPrompts = 0
                        entry.erroredTurnSettle = nil
                    }
                    // 再接続時の done 再送用に、完了ターンの messageId を保持する。
                    entry.lastDoneMessageId = event.messageId
                    entry.currentMessageId = nil
                    entry.currentBubbleText = ""
                    entry.currentToolUseId = nil
                    entry.currentToolName = nil
                    entry.currentToolKind = nil
                    // サブエージェントのカードと、終わっていない dynamic workflow はターンより長く動くので残す
                    // （知らせのターンまで結果をカードに残す。終わった行は次の新しいターンで捨てる）。
                    entry.cards.dropFinishedWorkflows()
                    refreshSleepGuard()
                    // 送った発話が CLI の待ち行列に残っているなら、そのターンがこれから走る。push・予約の実行・閉じるかの判定は、
                    // その発話の done まで待つ。
                    if !promptPending {
                        // バックグラウンドの作業。誰も見ていないときだけ聞き、push と閉じるかの判定に同じ値を使う
                        // （push を待つことにしたのに閉じて、作業も知らせのターンも消す、を起こさない）。
                        var background = WorkflowCardMirror.Counts()
                        if subs.isEmpty || entry.subscribers.isEmpty {
                            background = await backgroundWork(entry)
                        }
                        await pushAtDone(entry, metadata: event.metadata, watched: !subs.isEmpty, background: background)
                        entry.bubbles.reset()
                        // Mac 側予約キューに次の指示があれば自動実行する（アプリが閉じていても届く）。
                        let dispatchedNext = dispatchNextQueued(entry)
                        // 完了済みで購読者が居なければ閉じる → openclaw 等のプロセスを解放。
                        // (購読者が居る間は再利用のため保持。pump はセッション close で自然終了する)
                        // 予約を実行に移した場合と、待つ間に次の送信が始まった場合は次ターンが走るので閉じない。
                        // バックグラウンドの作業（サブエージェント・シェル・終わっていない workflow）が残っている間も閉じない
                        // （プロセスごと止めると作業が消える）。作業が終わった後の done か sweep で閉じる。
                        // 預かった完了の push があれば閉じない（猶予の後に settleOwedPush が出してから閉じる）。
                        if !dispatchedNext, entry.subscribers.isEmpty, !entry.generating, !background.any,
                           entry.owedPush == nil {
                            await entry.session.close()
                        }
                    }
                }

                // 承認要求も、誰も見ていなければ push で呼び出す（外出先で承認を叩けるように）。
                // cron 実行はこの pump を通らない（BridgeCronScheduler が独自の event collector で
                // 消費する）ので、この push パスは cron からは構造上到達しない。
                // approval_policy=never は追加の安全策にすぎない。
                if event.type == .actionRequest && subs.isEmpty {
                    let agentDisplay = Self.pushTitle(agentId: entry.agentId, displayName: entry.displayName)
                    let reqTitle = event.metadata?["title"] ?? event.content ?? "承認が必要です"
                    await PushService.shared.broadcast(
                        title: agentDisplay,
                        body: reqTitle,
                        payload: [
                            "kind": "approval_request",
                            "agentId": entry.agentId,
                            "sessionId": entry.sessionId ?? "",
                            "requestId": event.messageId ?? "",
                            // 平文 push（relay / direct）には送信元 Mac を示す情報が無い。
                            // 複数 Mac のとき、タップで送信元の Mac を開けるように載せる。
                            "bridgeId": KeyStore.loadOrCreateBridgeId()
                        ]
                    )
                }
            }
        } catch {
            // session 終了 (close)。entry を片付けて pump 終了。
        }
        // closeSession / sweep で既に外されていたら触らない（closeSession が同じ key に張り直した
        // 新しい entry を消してしまうため）。
        if entries[currentKey] === entry {
            removeEntry(forKey: currentKey)
            // 預かっていた予約はこの entry と一緒に消える。購読中の iPhone に予約カードを残さない。
            if !entry.messageQueue.isEmpty {
                entry.messageQueue.removeAll()
                broadcastQueueState(entry)
            }
        }
        // stream がエラー/プロセス死で終わった場合に子プロセスを確実に解放する
        // (close 済みなら冪等なので二重呼びは無害)。
        await entry.session.close()
        // 生成中のまま pump が終了（セッション死）した場合に取りこぼさないよう再評価。
        entry.generating = false
        refreshSleepGuard()
    }
}

// MARK: - workflow_progress のカードの写し

/// workflow_progress のカード（dynamic workflow と、サブエージェント・バックグラウンドのコマンドの subagents）の写し。
/// taskId 単位で、届いた payload を重ねる。SessionHub は再接続のスナップショットと「バックグラウンドの作業があるか」
/// （閉じない・スリープ抑止・完了の push・一覧の background）に、BridgeCronScheduler は done の後も集め続けるかに使う。
/// 形と規則は docs/BACKGROUND_WORK_2026-10-21.md §3.1・§3.5。値型。呼び出し側の actor の下で使う。
struct WorkflowCardMirror {
    static let subagentsTaskId = SubagentTracker.taskId

    /// カード 1 枚。fields は subtype と agents を除いた最新の項目（kind・epoch・workflowName・status・summary・outcome …）、
    /// agents は index → 最新の行。
    struct Card {
        var fields: [String: Any] = [:]
        var agents: [Int: [String: Any]] = [:]

        var kind: String? { fields["kind"] as? String }
        var epoch: String? { fields["epoch"] as? String }
        var status: String? { fields["status"] as? String }
        /// サブエージェントのカード（kind の無い古い payload も taskId で見分ける）。
        var isSubagents: Bool { kind == "subagents" || fields["taskId"] as? String == WorkflowCardMirror.subagentsTaskId }
        /// mainagent の子のカード（kind "sessions"）。バックグラウンドの作業には数えない。
        var isSessions: Bool { kind == "sessions" }
        /// 終わった dynamic workflow か（status が completed / failed / stopped 等）。status が無ければ動いているとみなす。
        var isFinished: Bool { status.flatMap(SubagentTracker.finalState) != nil }
    }

    /// 動いているものの数。
    struct Counts: Equatable {
        /// subagents のカードの running の行のうちサブエージェント（rowKind が agent。workflow・teammate の行も含む）
        var agents = 0
        /// subagents のカードの running の行のうちバックグラウンドのコマンド（rowKind が shell。Monitor を含む）
        var shells = 0
        /// 終わっていない dynamic workflow のカード
        var workflows = 0
        /// agents のうち background == true の行（Live Activity 用。生成中は前景のサブエージェントを数えない）
        var backgroundOnlyAgents = 0

        /// 何か動いている（閉じない・list_sessions の background）。
        var any: Bool { agents + shells + workflows > 0 }
        /// サブエージェントか workflow が動いている（スリープ抑止・完了の push を待つ・cron が待つ）。
        /// バックグラウンドのコマンドだけでは数えない（dev サーバーは終わらないので、眠れない・知らせが来ないままになる）。
        var agentsOrWorkflows: Bool { agents + workflows > 0 }
    }

    private(set) var cards: [String: Card] = [:]
    /// 届いた順の taskId（再生の順）。
    private(set) var order: [String] = []
    /// 直近の apply で終わったもの（state は done / failed / stopped。Live Activity の終わりの数に使う。apply のたびに上書き）。
    /// agent 行（shell は含めない）が running から終わった、世代が変わる・workflow_snapshot で消えたは stopped、
    /// 終わっていなかった dynamic workflow が終わったら 1 つ（いつも background）。
    private(set) var lastFinished: [(state: String, background: Bool)] = []

    var isEmpty: Bool { cards.isEmpty }
    var hasSubagents: Bool { cards[Self.subagentsTaskId] != nil }
    /// subagents のカードの世代（SubagentTracker の epoch）。
    var subagentsEpoch: String? { cards[Self.subagentsTaskId]?.epoch }

    /// payload（workflow_progress の content の JSON）を重ねる。重ねたカードの taskId を返す（読めなければ nil）。
    @discardableResult
    mutating func apply(_ json: String?) -> String? {
        guard let data = json?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastFinished = []
            return nil
        }
        return apply(obj)
    }

    /// - epoch が持っているものと違えば、行を全部捨ててから重ねる（作り直したトラッカーの行と混ぜない）。
    /// - subtype が workflow_snapshot なら、行を丸ごと置き換える（agents: [] なら行が無い）。
    /// - ほかは index ごとに重ねる。epoch 付きの行（SubagentTracker。毎回全項目を入れる）は置き換え、epoch の無い行
    ///   （dynamic workflow・古い Bridge）は届いた項目だけを上書きする。
    @discardableResult
    mutating func apply(_ obj: [String: Any]) -> String? {
        lastFinished = []
        guard let taskId = obj["taskId"] as? String, !taskId.isEmpty else { return nil }
        let before = cards[taskId]
        if before == nil { order.append(taskId) }
        var card = before ?? Card()
        let subtype = obj["subtype"] as? String
        let epoch = obj["epoch"] as? String
        let epochChanged = epoch != nil && card.epoch != epoch
        if epochChanged { card.agents.removeAll() }
        if subtype == "workflow_snapshot" { card.agents.removeAll() }
        for (k, v) in obj where k != "subtype" && k != "agents" { card.fields[k] = v }
        // outcome（止めた workflow の印）は status に添えて届く。status だけが届いたら前の印を残さない。
        if obj["status"] != nil, obj["outcome"] == nil { card.fields.removeValue(forKey: "outcome") }
        // taskId "subagents" は kind が無くても subagents のカード（再生する全行に kind を入れる）。
        if taskId == Self.subagentsTaskId, card.kind == nil { card.fields["kind"] = "subagents" }
        if card.status == nil {
            if subtype == "task_started" { card.fields["status"] = "running" }
            if subtype == "task_notification" { card.fields["status"] = "completed" }
        }
        for a in obj["agents"] as? [[String: Any]] ?? [] {
            guard let idx = Self.int(a["index"]) else { continue }
            if epoch != nil {
                card.agents[idx] = a
            } else {
                var merged = card.agents[idx] ?? [:]
                for (k, v) in a { merged[k] = v }
                card.agents[idx] = merged
            }
        }
        cards[taskId] = card
        lastFinished = Self.finished(before: before, after: card, epochChanged: epochChanged)
        return taskId
    }

    /// apply の前後で終わったもの（lastFinished）。
    private static func finished(before: Card?, after: Card, epochChanged: Bool) -> [(state: String, background: Bool)] {
        guard let before, !after.isSessions else { return [] }
        if after.isSubagents {
            var out: [(state: String, background: Bool)] = []
            for (index, old) in before.agents.sorted(by: { $0.key < $1.key }) where isRunning(old) && old["rowKind"] as? String != "shell" {
                let background = old["background"] as? Bool == true
                if !epochChanged, let row = after.agents[index] {
                    if let state = row["state"] as? String, ["done", "failed", "stopped"].contains(state) {
                        out.append((state, row["background"] as? Bool ?? background))
                    }
                } else {
                    out.append(("stopped", background))
                }
            }
            return out
        }
        guard !before.isFinished, after.isFinished, let status = after.status else { return [] }
        if after.fields["outcome"] as? String == "stopped" { return [("stopped", true)] }
        return [(SubagentTracker.finalState(status) ?? "done", true)]
    }

    /// 新しいターン（生成中でない送信・予約の実行・ほかの画面からの発話）: subagents のカードの終わった行と、終わった
    /// dynamic workflow を捨てる。動いているもの（ターンより長く動く作業）は残す。アプリと adapter のトラッカー
    /// （SubagentTracker.pruneFinished）も同じ時点で捨てる。
    mutating func pruneFinished() {
        for (taskId, card) in cards {
            if card.isSubagents {
                cards[taskId]?.agents = card.agents.filter { Self.isRunning($0.value) }
            } else if !card.isSessions, card.isFinished {
                cards.removeValue(forKey: taskId)
            }
        }
        order.removeAll { cards[$0] == nil }
    }

    /// ターンの終わり（done・error で閉じた）: 終わった dynamic workflow だけを捨てる。subagents のカード（終わった行も、
    /// 知らせのターンまで結果を残す）と、終わっていない workflow（バックグラウンドで続く）は残す。
    mutating func dropFinishedWorkflows() {
        for (taskId, card) in cards where !card.isSubagents && !card.isSessions && card.isFinished {
            cards.removeValue(forKey: taskId)
        }
        order.removeAll { cards[$0] == nil }
    }

    /// 動いているものの数。
    var counts: Counts {
        var c = Counts()
        for card in cards.values {
            if card.isSubagents {
                for row in card.agents.values where Self.isRunning(row) {
                    if row["rowKind"] as? String == "shell" {
                        c.shells += 1
                    } else {
                        c.agents += 1
                        if row["background"] as? Bool == true { c.backgroundOnlyAgents += 1 }
                    }
                }
            } else if !card.isSessions, !card.isFinished {
                c.workflows += 1
            }
        }
        return c
    }

    /// subagents のカードの全行（workflow_snapshot。kind・epoch 付き）。カードが無ければ nil。
    func subagentsSnapshot() -> String? { snapshotJSON(taskId: Self.subagentsTaskId) }

    /// subagents 以外のカード（dynamic workflow）の全行を届いた順に。unfinishedOnly なら終わっていないものだけ
    /// （ターンが終わった後もバックグラウンドで続くもの）。
    func workflowSnapshots(unfinishedOnly: Bool) -> [String] {
        order.compactMap { taskId in
            guard let card = cards[taskId], !card.isSubagents, !(unfinishedOnly && card.isFinished) else { return nil }
            return snapshotJSON(taskId: taskId)
        }
    }

    /// 1 枚のカードの全行（subtype = workflow_snapshot。アプリは行を丸ごと置き換える）。subagents のカードの status
    /// （古いアプリ向けの要約）は行から数え直す（終わった行を捨てた後にも合うように。SubagentTracker と同じ規則）。
    func snapshotJSON(taskId: String) -> String? {
        guard let card = cards[taskId] else { return nil }
        var out = card.fields
        let rows = card.agents.keys.sorted().compactMap { card.agents[$0] }
        out["subtype"] = "workflow_snapshot"
        out["taskId"] = taskId
        out["agents"] = rows
        if card.isSubagents {
            out["kind"] = "subagents"
            let states = rows.map { $0["state"] as? String ?? "" }
            out["status"] = states.contains("running") ? "running"
                : !states.isEmpty && states.allSatisfy { $0 == "failed" } ? "failed" : "completed"
        }
        guard JSONSerialization.isValidJSONObject(out),
              let data = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// subagents の全行（session の subagentSnapshot など）から、世代と動いている行の数を読む。subagents のカードでなければ nil。
    static func rowCounts(snapshot json: String) -> (epoch: String?, agents: Int, shells: Int)? {
        var mirror = WorkflowCardMirror()
        guard let taskId = mirror.apply(json), let card = mirror.cards[taskId], card.isSubagents else { return nil }
        let c = mirror.counts
        return (card.epoch, c.agents, c.shells)
    }

    private static func isRunning(_ row: [String: Any]) -> Bool { row["state"] as? String == "running" }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        return nil
    }
}

// MARK: - 完了の push の本文

/// ターンの吹き出しの本文（messageId ごと、出た順）。完了の push には最後の空でない吹き出しの頭を使う
/// （前置きの「調べます」ではなく結論。MainHeartbeat と同じ規則）。
struct TurnBubbles {
    /// 吹き出し 1 つに覚える上限（UTF-8 のバイト数）。push に使うのは頭だけなので、長い本文を抱え込まない。
    static let keepBytes = 8 * 1024

    private var order: [String] = []
    private var texts: [String: String] = [:]

    mutating func append(_ text: String, messageId: String?) {
        let id = messageId ?? ""
        if texts[id] == nil {
            order.append(id)
            texts[id] = ""
        }
        guard texts[id, default: ""].utf8.count < Self.keepBytes else { return }
        texts[id, default: ""] += text
    }

    /// 最後の空でない吹き出しの頭（前後の空白を詰めて limit 字まで）。無ければ nil。
    func lastBubble(limit: Int = 180) -> String? {
        for id in order.reversed() {
            let text = (texts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(limit)) }
        }
        return nil
    }

    mutating func reset() {
        order.removeAll()
        texts.removeAll()
    }
}
