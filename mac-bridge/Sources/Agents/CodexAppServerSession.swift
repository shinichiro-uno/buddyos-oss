import Foundation

struct CodexAppServerError: Error, LocalizedError {
    let message: String
    var timedOut = false
    var errorDescription: String? { message }
}

final class CodexAppServerSession: AgentSession, SessionOverridable {
    /// 生成中に届いた send は turn/steer で実行中の自分のターンへ足す（新しいターンを始めない）。
    var supportsMidTurnInjection: Bool { true }

    /// 受信タスク（通知の振り分け）と send タスク（thread/start の応答）が同時に触るので stateQueue で守る。
    /// stateQueue.sync の中からは読まないこと（シリアルキューなので再入するとデッドロックする）。
    var sessionId: String { stateQueue.sync { sessionIdStorage } }
    let events: AsyncThrowingStream<SessionEvent, Error>

    private let agentId: String
    private let cwd: String?
    /// mainagent の合鍵（Orchestrator）。あれば Bridge の MCP を thread の config で渡す。
    let mainToken: String?
    /// mainagent のフォルダのセッションか。true なら読むだけ（sandbox read-only・承認 never）にする。
    let mainRestricted: Bool
    private let executable: String
    private let config = CodexConfigStore()
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private let stateQueue = DispatchQueue(label: "buddyos.codex.appserver.state")
    private let pendingQueue = DispatchQueue(label: "buddyos.codex.appserver.pending")

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    /// 共有 app-server（CodexSharedAppServer）に繋ぐ場合の接続先。nil なら自前の stdio プロセス。
    private let shared: CodexSharedEndpoint?
    private var wsTask: URLSessionWebSocketTask?
    private var wsReceiveTask: Task<Void, Never>?
    /// 自分が turn/start を投げて、まだ応答も turn/started も来ていない（turn/started が応答より先に来る場合の判定用）。
    /// 実行中のターンへの steer になると turn/started は来ないので、応答（または失敗）で必ず落とす。
    private var localTurnPending = false
    /// turn/start の応答で得た自分の turn id。turn/started が応答より後に来ても自分のターンと分かるように。
    private var localTurnIds: Set<String> = []
    /// turn/start に付けた clientUserMessageId。userMessage の clientId と照合して、iPhone から送った発話を
    /// iPhone に流し直さない（ターミナル側ターンへの steer になると、そのターンの中で届くため）。
    private var ownClientMessageIds: Set<String> = []
    /// 他の接続（ターミナル）が始めた turn。ユーザー発話を iPhone に流すのに使う。
    private var remoteTurnIds: Set<String> = []
    /// ターミナルで開いたばかりで 1 ターンもしていない thread は rollout が無く、thread/resume が
    /// 「no rollout found」で断られる。共有 app-server 上には載っているので turn/start は通り、
    /// その直後なら resume できる（実測: 0.1 秒で成功し、返答は最初から全部届く）。
    private var needsResumeAfterTurnStart = false
    private var didStart = false
    /// プロセス死/EOF の terminal 処理を1回だけ実行するためのガード。
    private var didHandleExit = false
    private var didInitialize = false
    private var didOpenThread = false
    /// iPhone から一度でも send したか。先行購読（subscribeWhileTerminalOpen）だけで繋いでいる間の切断は、
    /// 送ってもいない会話にエラーを出さないよう静かに畳む（handleProcessExit 参照）。
    private var didSend = false
    private var didEmitSessionStarted: Bool
    private var sessionIdStorage: String
    private var resolvedSessionIdStorage: String?
    private var resolvedSessionId: String? { stateQueue.sync { resolvedSessionIdStorage } }
    private var activeModel: String?
    private var activeReasoningEffort: String?
    /// このチャットだけのモデル / Effort / モード。turn/start の引数にだけ使い、config.toml には書かない。
    /// stateQueue の中から読まれうるので専用ロックで守る。
    private let overridesLock = NSLock()
    private var overrides = SessionOverrides.none
    private var nextRequestId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var activeMessageByTurnId: [String: String] = [:]
    private var lastMessageByTurnId: [String: String] = [:]
    /// 現在進行中の turn の id。stop（turn/interrupt）と turn/steer の宛先に使う。
    private var activeTurnId: String?
    private var deltaItems: Set<String> = []
    private var pendingActionKinds: [String: String] = [:]
    /// サブエージェント（子 thread。キーは子 thread id）とバックグラウンドの端末（キーは commandExecution の item id）。
    /// セッションに 1 つ持つ（ターンごとに作らない）。stateQueue で保護する。
    private var work = CodexBackgroundWork()
    /// turn/interrupt を送った turn id（親も子も）。同じ turn に 2 回送らない（2 回目は返事が来ず待たされる。codex 0.162.1 の実測）。
    /// その turn の turn/completed で消す。stateQueue で保護する。
    private var interruptedTurnIds: Set<String> = []
    /// 子の turn/interrupt が時間切れだった turn id（届いたか分からない。interruptedTurnIds にも残し、送り直さない）。
    /// 次の停止で行が閉じなければ、stopped と言わず timeout を返す（Windows の timedOutChildTurnIds と同じ）。
    /// その turn の turn/completed か、次の停止で行が閉じたときに消す。stateQueue で保護する。
    private var timedOutChildTurnIds: Set<String> = []
    /// 行ごとの停止（stopTask）の返事待ち。キーは行のキー。同じ行を 2 つの端末が同時に止めたとき、後からのは結果を待つ。stateQueue で保護する。
    private var stopWaiters: [String: [CheckedContinuation<StopTaskOutcome, Never>]] = [:]
    /// 停止の要求（terminate・turn/interrupt）の返事を待つ秒数と、子の turn/completed を待つ秒数。テストが縮める。
    var stopRequestSeconds: TimeInterval = 5
    var stopSettleSeconds: TimeInterval = 5
    /// テスト用: app-server に書かずに request の返事を差し替える。
    var requestHook: ((String, [String: Any]) async throws -> [String: Any])?
    /// stdio: 自分の thread の turn/completed で app-server を止めるのを、実行中の行（子 thread・裏の端末）が
    /// 終わるまで延ばしている（止めると子も裏の端末も道連れになる）。行が無くなったら止める（stopDeferredAppServerIfIdle）。
    private var deferredStop = false
    /// 途中の send()（ensureThread・入力の用意・turn/start の応答待ち）の数。この間は app-server を止めない
    /// （止めると、これから turn/start を書く相手が消え、初期化していない新しいプロセスに書いて送信が失敗する）。
    private var sendsInFlight = 0
    /// 自分が始めていないターンのうち、発話（ターミナルの発話か、そこへ steer した自分の発話）があったもの。
    /// 発話の無いターンは、子の完了などで親が自分から起きた知らせのターンとして、done に origin を付ける。
    private var turnsWithUtterance: Set<String> = []
    /// requestUserInput の質問 id（先頭が iPhone に出した質問、残りは空の回答で返す分）。
    private var pendingActionQuestionIds: [String: [String]] = [:]
    /// `error` 通知（willRetry=false）で .error を流済みの turn。turn/completed(failed) で二重に出さない。
    private var erroredTurnIds: Set<String> = []
    /// thread を開く処理（initialize → thread/start・resume）の直列化用。先行購読と send が
    /// 同時に走っても initialize / thread/resume を二重に送らないよう、前の処理の完了を待たせる。
    private var openChain: Task<Void, Never>?

    init(agentId: String, initialSessionId: String?, cwd: String?, executable: String,
         shared: CodexSharedEndpoint? = nil, mainToken: String? = nil, mainRestricted: Bool = true) {
        self.agentId = agentId
        self.mainToken = mainToken
        self.mainRestricted = mainRestricted
        self.cwd = cwd
        self.executable = executable
        self.shared = shared
        self.resolvedSessionIdStorage = initialSessionId
        self.sessionIdStorage = initialSessionId ?? "pending-\(UUID().uuidString.prefix(8))"
        self.didEmitSessionStarted = initialSessionId != nil
        var c: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { continuation in
            c = continuation
        }
        self.continuation = c
        // 共有サーバーの再起動の判定（restartBlocker）が、このセッションの動いている子 thread と裏の端末を数える。
        if shared != nil { Self.registerShared(self) }
        // ターミナルで開いている thread は、iPhone から送る前からターミナル側のターンを流す。
        if shared != nil, let sid = initialSessionId, !sid.isEmpty, !sid.hasPrefix("pending-") {
            Task { [weak self] in await self?.subscribeWhileTerminalOpen(threadId: sid) }
        }
    }

    deinit {
        Self.unregisterShared(ObjectIdentifier(self))
    }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        // ensureThread より前に立てる（送信中の切断は、スピナーを解くため error → done を流す）。
        stateQueue.sync { didSend = true }
        // 送り終えるまで、延ばしていた app-server の停止をしない（ensureThread の後に止められると turn/start が失敗する）。
        noteSendStarted()
        defer { noteSendFinished() }
        let localMessageId = UUID().uuidString
        let tmpDir = makeTmpDir()
        defer {
            if let tmpDir {
                try? FileManager.default.removeItem(atPath: tmpDir)
            }
        }

        var turnRequested = false
        do {
            try await ensureThread()
            let prompt = promptText(text: text, skills: skills, attachments: attachments)
            let inputs = try userInputs(prompt: prompt, attachments: attachments, tmpDir: tmpDir)
            // 自分のターンが走っていれば、止めずにそのターンへ足す。完了（done）は元のターンの 1 回だけ出る。
            // 間に合わなかった（直前に終わった・別のターンになった）ときは、新しいターンとして始める。
            if let running = stateQueue.sync(execute: { activeTurnId.flatMap { activeMessageByTurnId[$0] != nil ? $0 : nil } }) {
                stateQueue.sync { _ = ownClientMessageIds.insert(localMessageId) }
                do {
                    _ = try await request(method: "turn/steer", params: [
                        "threadId": sessionId,
                        "expectedTurnId": running,
                        "input": inputs,
                        "clientUserMessageId": localMessageId
                    ])
                    return
                } catch {
                    WebSocketServer.wslog("codex turn/steer fell back to turn/start: \(error.localizedDescription)")
                }
            }
            let model = currentModel()
            let effort = currentReasoningEffort()
            let approvalPolicy = currentApprovalPolicy()
            let sandboxMode = currentSandboxMode()
            let mode = config.currentCodexMode(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode) == "plan" ? "plan" : "default"
            var params: [String: Any] = [
                "threadId": sessionId,
                "input": inputs,
                "approvalPolicy": approvalPolicy,
                "sandboxPolicy": sandboxPolicy(for: sandboxMode),
                "model": model,
                "effort": effort,
                "collaborationMode": [
                    "mode": mode,
                    "settings": [
                        "model": model,
                        "reasoning_effort": effort,
                        "developer_instructions": NSNull()
                    ]
                ]
            ]
            if let cwd {
                params["cwd"] = cwd
                params["runtimeWorkspaceRoots"] = [cwd]
            }
            params["clientUserMessageId"] = localMessageId
            stateQueue.sync {
                localTurnPending = true
                ownClientMessageIds.insert(localMessageId)
                work.pruneFinished()
            }
            turnRequested = true
            let response = try await request(method: "turn/start", params: params)
            let turnId = dictionary(response["turn"]).flatMap { string($0["id"]) }
            stateQueue.sync {
                localTurnPending = false
                guard let turnId else { return }
                localTurnIds.insert(turnId)
                // ターミナル側のターンが進行中なら、この turn/start はそのターンへの steer になっている
                // （新しいターンは始まらず turn/started も来ない）。停止の宛先と done の messageId は上書きしない。
                let steered = remoteTurnIds.contains(turnId)
                    || (activeTurnId.map { $0 != turnId && remoteTurnIds.contains($0) } ?? false)
                if steered {
                    // 自分の発話が入ったターンは、知らせのターン（発話の無いターン）ではない。
                    turnsWithUtterance.insert(remoteTurnIds.contains(turnId) ? turnId : (activeTurnId ?? turnId))
                }
                guard !steered else { return }
                activeMessageByTurnId[turnId] = localMessageId
                activeTurnId = turnId
            }
            if stateQueue.sync(execute: { needsResumeAfterTurnStart }) {
                await resumeAfterTurnStart(messageId: localMessageId)
            }
        } catch {
            // .error だけだと SessionHub が「考え中」のまま戻らない（generating/phase は .done でしか戻らない）。
            // プロセス死・close で既に error → done を流している場合は何もしない（二重表示を防ぐ）。
            let exited = stateQueue.sync { () -> Bool in
                if turnRequested {
                    localTurnPending = false
                    ownClientMessageIds.remove(localMessageId)
                }
                return didHandleExit
            }
            guard !exited else { return }
            continuation.yield(SessionEvent(
                type: .error,
                agentId: agentId,
                sessionId: sessionId,
                messageId: localMessageId,
                toolUseId: nil,
                content: error.localizedDescription,
                toolName: nil,
                metadata: nil
            ))
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: localMessageId))
        }
    }

    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {
        // 応答済み・プロセス死後など、もう待っていない要求には書かない（iPhone に残った古いカード対策）。
        guard let kind = stateQueue.sync(execute: { pendingActionKinds[requestId] }) else { return }
        let result: [String: Any]
        switch kind {
        case "userInput":
            // v2 ToolRequestUserInputResponse = { answers: { [questionId]: { answers: string[] } } }
            // 新しいクライアントは全問の答えを answers_json（質問 id → 文字列 | 配列）で返す。
            // 古いクライアントは最初の質問だけを decision で返すので、残りは空の回答にする。
            let questionIds = stateQueue.sync { pendingActionQuestionIds[requestId] } ?? []
            let all = Self.answerArrays(answers["answers_json"])
            var answersById: [String: Any] = [:]
            for (i, qid) in questionIds.enumerated() {
                let picked = all[qid] ?? (i == 0 && all.isEmpty ? [decision] : [])
                answersById[qid] = ["answers": picked]
            }
            if questionIds.isEmpty { answersById["answer"] = ["answers": [decision]] }
            result = ["answers": answersById]
        case "legacyApproval":
            // v1 の execCommandApproval / applyPatchApproval は ReviewDecision で返す。
            let map = ["accept": "approved", "acceptForSession": "approved_for_session", "decline": "denied"]
            result = ["decision": map[decision] ?? "denied"]
        case "elicitation":
            // v2 McpServerElicitationRequestResponse = { action, content, _meta }（decision 形式ではない）。
            // 「このセッションでは承認」は _meta.persist = "session" で同種のツール呼び出しを続けて許可する。
            switch decision {
            case "accept":
                result = ["action": "accept", "content": [String: Any](), "_meta": NSNull()]
            case "acceptForSession":
                result = ["action": "accept", "content": [String: Any](), "_meta": ["persist": "session"]]
            default:
                result = ["action": "decline", "content": NSNull(), "_meta": NSNull()]
            }
        default:
            result = ["decision": decision]
        }
        do {
            let responseId: Any
            if let numericId = Int(requestId) {
                responseId = numericId
            } else {
                responseId = requestId
            }
            try writeJSON(["id": responseId, "result": result])
            stateQueue.sync {
                pendingActionKinds.removeValue(forKey: requestId)
                pendingActionQuestionIds.removeValue(forKey: requestId)
            }
        } catch {
            continuation.yield(SessionEvent(
                type: .error,
                agentId: agentId,
                sessionId: sessionId,
                messageId: requestId,
                toolUseId: nil,
                content: "Codex action response failed: \(error.localizedDescription)",
                toolName: nil,
                metadata: nil
            ))
        }
    }

    /// 進行中のターンをクリーンに停止する。プロセスは殺さず `turn/interrupt` を送り、
    /// app-server が返す `turn/completed (status: interrupted)` 通知で .done が流れる。
    func interrupt() async {
        let (tid, hasProc) = stateQueue.sync { (activeTurnId, process != nil || wsTask != nil || requestHook != nil) }
        guard let tid, hasProc else { return }
        // 同じ turn に 2 回送らない（2 回目は返事が来ない）。送った turn は turn/completed まで覚える。
        guard stateQueue.sync(execute: { interruptedTurnIds.insert(tid).inserted }) else { return }
        do {
            _ = try await request(method: "turn/interrupt", params: [
                "threadId": sessionId,
                "turnId": tid
            ], timeout: stopRequestSeconds)
        } catch {
            // 断られた（もう終わっていた等）。やり直せるように覚えを消す。返事が無かったときは残す（2 回目も返事が来ない）。
            if (error as? CodexAppServerError)?.timedOut != true { _ = stateQueue.sync { interruptedTurnIds.remove(tid) } }
        }
    }

    // MARK: - 行ごとの停止（stop_task。docs/BACKGROUND_CONTROL_2026-10-21.md §3.5）

    private enum StopStart {
        case shell(processId: String)
        case agent(turnId: String)
        case end(StopTaskOutcome)
        case join
    }

    /// shell 行は thread/backgroundTerminals/terminate、agent 行は子への turn/interrupt で止める。親には何も送らない。
    func stopTask(_ request: StopTaskRequest) async -> StopTaskOutcome {
        guard request.taskId == "subagents" else { return .unsupported(nil) }
        guard let key = request.rowId, let epoch = request.epoch else { return .stale }
        let sid = sessionId   // stateQueue の中では読めない
        let start = stateQueue.sync { () -> StopStart in
            guard epoch == work.tracker.epoch, work.tracker.contains(key) else { return .end(.stale) }
            guard work.tracker.isRunning(key: key), process != nil || wsTask != nil || requestHook != nil else {
                return .end(.notRunning)
            }
            switch work.beginStop(key: key) {
            case .notRunning: return .end(.notRunning)
            case .unsupported: return .end(.unsupported(nil))
            case .inFlight: return .join
            case .ok(let rowKind, let payload):
                stopWaiters[key] = []
                if let payload { continuation.yield(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: payload)) }
                if rowKind == "shell", let processId = work.processId(forExec: key) { return .shell(processId: processId) }
                if let turnId = work.childTurns[key] { return .agent(turnId: turnId) }
                // 手がかりが消えていた。頼まずに戻し、行は止められないことにして送り直す（押すたびに unsupported にしない）。
                work.dropStopHandle(key)
                if let ended = work.endStop(key: key) {
                    continuation.yield(.workflowProgress(agentId: agentId, sessionId: sid, payloadJSON: ended))
                }
                stopWaiters.removeValue(forKey: key)
                return .end(.unsupported(nil))
            }
        }
        let outcome: StopTaskOutcome
        switch start {
        case .end(let result): return result
        case .join:
            return await withCheckedContinuation { c in
                stateQueue.sync {
                    if stopWaiters[key] != nil { stopWaiters[key]?.append(c) } else { c.resume(returning: .notRunning) }
                }
            }
        case .shell(let processId): outcome = await stopShell(key: key, processId: processId)
        case .agent(let turnId): outcome = await stopAgent(key: key, turnId: turnId)
        }
        let waiters = stateQueue.sync { stopWaiters.removeValue(forKey: key) ?? [] }
        waiters.forEach { $0.resume(returning: outcome) }
        return outcome
    }

    private func stopShell(key: String, processId: String) async -> StopTaskOutcome {
        do {
            let result = try await request(method: "thread/backgroundTerminals/terminate",
                                           params: ["threadId": sessionId, "processId": processId],
                                           timeout: stopRequestSeconds)
            let terminated = result["terminated"] as? Bool ?? false
            let payload = stateQueue.sync { () -> String? in
                if terminated { work.noteStoppedExec(key) }
                // 返事は item/completed より先に来る。まだ running の行はこちらで閉じる。
                return work.tracker.isRunning(key: key) ? work.finishStopped(key) : nil
            }
            yieldSubagents(payload.map { [$0] } ?? [])
            return terminated ? .stopped : .notRunning
        } catch {
            let message = (error as? CodexAppServerError)?.message ?? error.localizedDescription
            if message.contains("requires experimentalApi capability") || message.contains("unknown variant") {
                let payloads = stateQueue.sync { () -> [String] in
                    var out = work.disableTerminalStop()
                    if let ended = work.endStop(key: key) { out.append(ended) }
                    return out
                }
                yieldSubagents(payloads)
                return .unsupported(nil)
            }
            yieldSubagents(stateQueue.sync { work.endStop(key: key) }.map { [$0] } ?? [])
            if (error as? CodexAppServerError)?.timedOut == true { return .timeout }
            return .failed(Self.stopMessage(message))
        }
    }

    private func stopAgent(key: String, turnId: String) async -> StopTaskOutcome {
        // 同じ turn に 2 回送らない。送ってあれば（親の interrupt や、前の押下が時間切れだったとき）、行が閉じるのを待つだけにする。
        let (send, afterTimeout) = stateQueue.sync { () -> (Bool, Bool) in
            let send = interruptedTurnIds.insert(turnId).inserted
            return (send, !send && timedOutChildTurnIds.contains(turnId))
        }
        if send {
            do {
                _ = try await request(method: "turn/interrupt", params: ["threadId": key, "turnId": turnId],
                                      timeout: stopRequestSeconds)
            } catch {
                let message = (error as? CodexAppServerError)?.message ?? error.localizedDescription
                let gone = ["no active turn to interrupt", "expected active turn id", "thread not found"]
                    .contains { message.contains($0) }
                let timedOut = (error as? CodexAppServerError)?.timedOut == true
                let payload = stateQueue.sync { () -> String? in
                    // timeout のときは送った覚えを残す（2 回目の turn/interrupt を送らない。親の interrupt と同じ）。
                    // 届いたか分からないので、時間切れだった印も残す（次の押下で行が閉じなければ、stopped と言わない）。
                    if timedOut { timedOutChildTurnIds.insert(turnId) } else { interruptedTurnIds.remove(turnId) }
                    // 子の今の turn はもう無い。手がかりを外して、同じ失敗を繰り返させない。
                    if gone { work.dropChildTurnHandle(key) }
                    return work.endStop(key: key)
                }
                yieldSubagents(payload.map { [$0] } ?? [])
                if gone { return .notRunning }
                if timedOut { return .timeout }
                return .failed(Self.stopMessage(message))
            }
        }
        // 子の turn/completed(interrupted) が行を stopped にする。今回の turn/interrupt が通ったのに来なければ、こちらで閉じる。
        let deadline = Date().addingTimeInterval(stopSettleSeconds)
        while stateQueue.sync(execute: { work.tracker.isRunning(key: key) }), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let (state, payload, unconfirmed) = stateQueue.sync { () -> (String?, String?, Bool) in
            // 前の turn/interrupt が時間切れのまま行が閉じないなら、止まったか分からない（子はまだ動いているかもしれない）。
            // stopped と言わず、押し直せるように stoppable を戻して timeout を返す。時間切れの印は残す（Windows と同じ）。
            if afterTimeout, work.tracker.isRunning(key: key) { return (nil, work.endStop(key: key), true) }
            timedOutChildTurnIds.remove(turnId)
            let closed = work.tracker.isRunning(key: key)
                ? work.finishStopped(key) : nil
            return (work.tracker.state(key: key), closed, false)
        }
        yieldSubagents(payload.map { [$0] } ?? [])
        if unconfirmed { return .timeout }
        // 子の端末は子を止めても残る。片付けは返事を待たない（前の押下が時間切れで、今回の待ちの間に行が閉じたときも送る）。
        if send || afterTimeout {
            Task { [weak self] in
                // app-server が先に止まっていたら送らない（送ると起こし直してしまう）。止まれば子の端末も一緒に消える。
                guard let self, self.stateQueue.sync(execute: { self.process != nil || self.wsTask != nil || self.requestHook != nil })
                else { return }
                _ = try? await self.request(method: "thread/backgroundTerminals/clean", params: ["threadId": key],
                                            timeout: self.stopRequestSeconds)
            }
        }
        return state == "stopped" ? .stopped : .notRunning
    }

    private static func stopMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
    }

    func close() async {
        // 意図的な終了。terminate() が誘発する terminationHandler / EOF が
        // handleProcessExit でエラーを撒かないよう先にガードを立てる。
        // stdin は nil にしてから閉じる（閉じた FileHandle へ書くと例外で Bridge ごと落ちるため）。
        let stdin = stateQueue.sync { () -> FileHandle? in
            didHandleExit = true
            let handle = stdinHandle
            stdinHandle = nil
            return handle
        }
        stdoutTask?.cancel()
        stderrTask?.cancel()
        try? stdin?.close()
        process?.terminate()
        // 共有サーバーは他の接続（ターミナル）も使っているので、自分の接続だけ閉じる。
        wsReceiveTask?.cancel()
        wsTask?.cancel(with: .normalClosure, reason: nil)
        // もう子の thread も裏の端末も追えない（stdio はプロセスごと止まる）。実行中の行は止めたものとして閉じる。
        yieldSubagent(stateQueue.sync { work.abandonRunning(state: "stopped") })
        Self.unregisterShared(ObjectIdentifier(self))
        continuation.finish()
        if let mainToken { await Orchestrator.shared.revoke(token: mainToken) }
    }

    /// app-server プロセスが死んだ（EOF / 異常終了）時の後始末。1回だけ実行する。
    /// 待機中の request を全失敗させ、進行中ターンに terminal イベント（.error → .done）を
    /// 発行してから stream を finish する。これにより:
    ///  - iOS の awaitingResponse が解除されspinner固着が解ける
    ///  - 購読者ゼロ（バックグラウンド）時は SessionHub.pump の done 経路で APNs が飛ぶ
    ///  - stream finish で SessionHub が entry を破棄し、次の send で新プロセスが再生成される
    private func handleProcessExit(_ reason: String) {
        // 共有 app-server を Bridge が意図して止めた直後（鮮度・MCP トークンの入れ替え）で、進行中の
        // ターンが無ければ、エラーを出さずに静かに畳む。畳めば SessionHub が entry を捨て、次の send で
        // openSession → ensureRunning が新しいサーバーに繋ぎ直して thread/resume する。
        // ターンが進行中なら、スピナーを解くため従来どおり error → done を流す。
        if shared != nil, CodexSharedAppServer.stoppedIntentionallyRecently(),
           stateQueue.sync(execute: { activeTurnId == nil && !localTurnPending }) {
            finishQuietly(reason, note: "intentional restart", rowState: "stopped")
            return
        }
        // 先行購読（subscribeWhileTerminalOpen）だけで繋いでいて iPhone から一度も送っておらず、ターミナル側の
        // ターンも進行中でなければ、原因（app-server のクラッシュ・更新など）を問わず静かに畳む。送ってもいない
        // 会話に「接続が切れました」を出さない。次に開いたとき（acquire → openSession）に購読し直す。
        if shared != nil,
           stateQueue.sync(execute: { !didSend && activeTurnId == nil && !localTurnPending }) {
            finishQuietly(reason, note: "subscribe only", rowState: "failed")
            return
        }
        let shouldHandle = stateQueue.sync { () -> Bool in
            if didHandleExit { return false }
            didHandleExit = true
            return true
        }
        guard shouldHandle else { return }

        // 1. 待機中の request を全て失敗させる（awaiting している initialize/turn-start 等を即解放）。
        let drained = pendingQueue.sync { () -> [CheckedContinuation<[String: Any], Error>] in
            let conts = Array(pending.values)
            pending.removeAll()
            return conts
        }
        for c in drained {
            c.resume(throwing: CodexAppServerError(message: reason))
        }

        // 2. 進行中ターンへ terminal イベントを発行（finish より前に必ず届ける）。
        //    死んだ stdin と、もう答えられない承認待ちも捨てる（残ったカードからの書き込みで落ちないように）。
        let (activeMsg, stdin, resolvedActions) = stateQueue.sync { () -> (String?, FileHandle?, [String]) in
            let mid = activeTurnId.flatMap { activeMessageByTurnId[$0] }
            activeMessageByTurnId.removeAll()
            lastMessageByTurnId.removeAll()
            activeTurnId = nil
            let actions = Array(pendingActionKinds.keys)
            pendingActionKinds.removeAll()
            pendingActionQuestionIds.removeAll()
            let handle = stdinHandle
            stdinHandle = nil
            return (mid, handle, actions)
        }
        try? stdin?.close()
        // もう答えられない承認カードを iPhone から閉じさせる。
        yieldActionsResolved(resolvedActions)
        // app-server が落ちた（共有サーバーとの接続が切れた）ので、子の thread と裏の端末はもう追えない。失敗として閉じる。
        yieldSubagent(stateQueue.sync { work.abandonRunning(state: "failed") })
        let messageId = activeMsg ?? UUID().uuidString
        continuation.yield(SessionEvent(
            type: .error,
            agentId: agentId,
            sessionId: sessionId,
            messageId: messageId,
            toolUseId: nil,
            content: reason,
            toolName: nil,
            metadata: nil
        ))
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))

        // 3. stream 終了 → SessionHub が entry を破棄 → 次の send で新プロセス再生成。
        continuation.finish()
    }

    /// 進行中のターンが無いときの切断を、error / done を出さずに畳む（handleProcessExit 参照）。
    /// 実行中の行は rowState で閉じる（Bridge が止めた再起動なら stopped、それ以外の切断は failed）。
    private func finishQuietly(_ reason: String, note: String, rowState: String) {
        let resolvedActions = stateQueue.sync { () -> [String]? in
            if didHandleExit { return nil }
            didHandleExit = true
            let actions = Array(pendingActionKinds.keys)
            pendingActionKinds.removeAll()
            pendingActionQuestionIds.removeAll()
            return actions
        }
        guard let resolvedActions else { return }
        let drained = pendingQueue.sync { () -> [CheckedContinuation<[String: Any], Error>] in
            let conts = Array(pending.values)
            pending.removeAll()
            return conts
        }
        for c in drained {
            c.resume(throwing: CodexAppServerError(message: reason))
        }
        yieldActionsResolved(resolvedActions)
        yieldSubagent(stateQueue.sync { work.abandonRunning(state: rowState) })
        WebSocketServer.wslog("codex-shared: \(reason) (\(note)) — closing session quietly")
        continuation.finish()
    }

    /// 解決済み（もう待っていない）承認要求を iPhone に伝え、カードを閉じさせる。
    private func yieldActionsResolved(_ requestIds: [String]) {
        for requestId in requestIds {
            continuation.yield(.actionResolved(agentId: agentId, sessionId: sessionId, requestId: requestId))
        }
    }

    /// thread を開く。先行購読（subscribeWhileTerminalOpen）と send が同時に来ても、
    /// 前の呼び出しの完了を待ってから走らせる（didInitialize / didOpenThread の確認は await をまたぐため）。
    private func ensureThread(subscribeOnly: Bool = false) async throws {
        let task = stateQueue.sync { () -> Task<Void, Error> in
            let previous = openChain
            let task = Task<Void, Error> {
                await previous?.value
                try await self.openThread(subscribeOnly: subscribeOnly)
            }
            openChain = Task { _ = try? await task.value }
            return task
        }
        try await task.value
    }

    /// 共有モードで、ターミナル（buddy-codex）が開いている thread を send より前に購読する。
    /// 購読は send → ensureThread でしか始まらず、iPhone から 1 回送るまでターミナル側のターンが流れなかった。
    /// - SessionHub.acquire は同じ sid で重複して作った session を即 close するので、少し待ってから始める
    /// - 開いている thread だけに絞る（一覧表示などで無関係な thread を app-server に読み込ませない）
    /// - rollout がまだ無い thread（ターミナルで開いた直後）は購読できないので、開いている間は再試行する
    /// - 失敗は静かに諦める（send 時に改めて開く）
    private func subscribeWhileTerminalOpen(threadId: String) async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        while true {
            let (closed, opened) = stateQueue.sync { (didHandleExit, didOpenThread) }
            if closed || opened { return }
            let live = await CodexTerminalRegistry.shared.liveEntries().contains { $0.threadId == threadId }
            guard live else { return }
            do {
                try await ensureThread(subscribeOnly: true)
                return
            } catch let error as CodexAppServerError where error.message.contains("no rollout found") {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                FileHandle.standardError.write(Data("[codex.appserver] early subscribe failed: \(error.localizedDescription)\n".utf8))
                return
            }
        }
    }

    private func openThread(subscribeOnly: Bool) async throws {
        try await initializeIfNeeded()
        let shouldOpen = stateQueue.sync { !didOpenThread }
        guard shouldOpen else { return }

        let approvalPolicy = currentApprovalPolicy()
        let sandboxMode = currentSandboxMode()
        var params: [String: Any] = [
            "approvalPolicy": approvalPolicy,
            "sandbox": sandboxMode,
            "persistExtendedHistory": false
        ]
        if let cwd {
            params["cwd"] = cwd
            params["runtimeWorkspaceRoots"] = [cwd]
        }
        if let model = currentOverrides.model ?? config.currentModel() {
            params["model"] = model
        }
        if let mainToken {
            // mainagent: Bridge の MCP（点区切りのキーで -c と同じ上書き）。承認は Bridge が尋ねる。
            params["config"] = MainAgentWorkspace.codexConfig(token: mainToken, port: MainAgentWorkspace.currentPort)
        }

        let response: [String: Any]
        if subscribeOnly, let sid = resolvedSessionId {
            // 見るだけなので threadId と excludeTurns だけ（ターミナル側の thread 設定を上書きしない）。
            response = try await request(method: "thread/resume",
                                         params: ["threadId": sid, "excludeTurns": true])
        } else if let sid = resolvedSessionId, !sid.isEmpty, !sid.hasPrefix("pending-") {
            params["threadId"] = sid
            params["excludeTurns"] = true
            do {
                response = try await request(method: "thread/resume", params: params)
            } catch let error as CodexAppServerError where shared != nil && error.message.contains("no rollout found") {
                stateQueue.sync {
                    didOpenThread = true
                    needsResumeAfterTurnStart = true
                }
                emitSessionStartedIfNeeded()
                return
            }
        } else {
            params["experimentalRawEvents"] = false
            params["sessionStartSource"] = "startup"
            params["threadSource"] = "user"
            response = try await request(method: "thread/start", params: params)
        }

        if let thread = dictionary(response["thread"]),
           let sid = string(thread["id"]) ?? string(thread["sessionId"]) {
            updateSessionIdIfNeeded(sid)
        }
        if let model = string(response["model"]) {
            activeModel = model
        }
        if let effort = string(response["reasoningEffort"]) {
            activeReasoningEffort = effort
        }
        stateQueue.sync { didOpenThread = true }
        emitSessionStartedIfNeeded()
    }

    /// rollout の無い thread に turn/start した直後に購読する。turn/started は取りこぼすので
    /// 自分のターンとして扱いを揃える（localTurnPending を落とす）。
    private func resumeAfterTurnStart(messageId: String) async {
        // 1 回の request は応答が無いと 90 秒待つので、回数だけでなく全体の期限でも打ち切る。
        let deadline = Date().addingTimeInterval(10)
        for _ in 0..<40 {
            if (try? await request(method: "thread/resume",
                                   params: ["threadId": sessionId, "excludeTurns": true])) != nil {
                stateQueue.sync {
                    needsResumeAfterTurnStart = false
                    localTurnPending = false
                }
                return
            }
            if Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // 購読できないと turn/completed も届かず、SessionHub が生成中のまま戻らない。
        // 送った側のバブルに error → done を流し、誰も見ていないターンは止める。
        // needsResumeAfterTurnStart は残し、次の send で購読をやり直す。
        let turnId = stateQueue.sync { () -> String? in
            let tid = activeTurnId
            if let tid {
                activeMessageByTurnId.removeValue(forKey: tid)
                lastMessageByTurnId.removeValue(forKey: tid)
            }
            activeTurnId = nil
            localTurnPending = false
            return tid
        }
        continuation.yield(SessionEvent(
            type: .error, agentId: agentId, sessionId: sessionId, messageId: messageId,
            toolUseId: nil, content: "Codex: ターミナルで開いた会話に繋げませんでした。ターミナル側で一度やり取りしてから開き直してください。",
            toolName: nil, metadata: nil))
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
        if let turnId {
            _ = try? await request(method: "turn/interrupt", params: ["threadId": sessionId, "turnId": turnId])
        }
    }

    private func initializeIfNeeded() async throws {
        try startIfNeeded()
        let shouldInitialize = stateQueue.sync { !didInitialize }
        guard shouldInitialize else { return }
        _ = try await request(method: "initialize", params: [
            "clientInfo": [
                "name": "buddyos",
                "title": "BuddyOS",
                "version": "0.1.0"
            ],
            "capabilities": [
                "experimentalApi": true,
                "requestAttestation": false
            ]
        ])
        try notify(method: "initialized")
        stateQueue.sync { didInitialize = true }
    }

    private func startIfNeeded() throws {
        let shouldStart = stateQueue.sync { () -> Bool in
            // close 後（接続・プロセスが死んだ後も）は作り直さない。先行購読が close と競合しても繋ぎっぱなしにしない。
            if didStart || didHandleExit { return false }
            didStart = true
            return true
        }
        guard shouldStart else { return }
        if let shared {
            startWebSocket(shared)
            return
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["app-server", "--listen", "stdio://"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable, "app-server", "--listen", "stdio://"]
        }
        process.environment = environment()
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // プロセス異常終了の検知（EOF と二重で発火し得るが handleProcessExit が冪等）。
        process.terminationHandler = { [weak self] proc in
            self?.handleProcessExit("Codex app-server が終了しました (exit \(proc.terminationStatus))")
        }
        try process.run()

        let writer = stdin.fileHandleForWriting
        // app-server が死んだ後の書き込みで SIGPIPE（Bridge ごと終了）にならず、EPIPE として throw させる。
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        stateQueue.sync {
            self.process = process
            self.stdinHandle = writer
        }
        // 読み取りは協調スレッドプールを塞がないよう readabilityHandler（GCD）で受ける
        // （Task 上で availableData を回すと、その間スレッドを 1 本占有し続ける）。
        let stdoutChunks = PipeChunks.stream(stdout.fileHandleForReading)
        let stderrChunks = PipeChunks.stream(stderr.fileHandleForReading)
        self.stdoutTask = Task { [weak self] in
            await self?.readLines(from: stdoutChunks, handler: { [weak self] line in
                self?.handleLine(line)
            })
            // readLines が EOF で抜けた = stdout が閉じた = プロセス死。
            // close() による cancel で抜けた場合は意図的終了なので handleProcessExit は冪等ガードで no-op。
            if !Task.isCancelled {
                self?.handleProcessExit("Codex app-server の出力が途切れました")
            }
        }
        self.stderrTask = Task {
            // 捨てずに err.log へ転送する (acp-stderr と同様)。app-server が起動に失敗した時の
            // 唯一の手がかりがここに出る。
            for await chunk in stderrChunks {
                let s = String(decoding: chunk, as: UTF8.self)
                if !s.isEmpty {
                    FileHandle.standardError.write(Data("[codex-stderr] \(s)".utf8))
                }
            }
        }
    }

    private func request(method: String, params: [String: Any], timeout: TimeInterval = 90) async throws -> [String: Any] {
        if let requestHook { return try await requestHook(method, params) }
        try startIfNeeded()
        let id = stateQueue.sync { () -> Int in
            let id = nextRequestId
            nextRequestId += 1
            return id
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingQueue.sync {
                pending[id] = continuation
            }
            // バックストップ: app-server が生きたまま応答しない（hung）場合の保険。
            // turn/start 等は数秒で応答が返る（生成完了は通知で来る別経路）ので 90s は安全。停止の要求は 5 秒で切る。
            // removeValue が原子的なので、正常応答 / プロセス死 / timeout の二重 resume は起きない。
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                let removed = self.pendingQueue.sync { self.pending.removeValue(forKey: id) }
                removed?.resume(throwing: CodexAppServerError(message: "Codex app-server request timed out: \(method)", timedOut: true))
            }
            do {
                try writeJSON(["id": id, "method": method, "params": params])
            } catch {
                let removed = pendingQueue.sync { pending.removeValue(forKey: id) }
                removed?.resume(throwing: error)
            }
        }
    }

    private func notify(method: String) throws {
        try writeJSON(["method": method])
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerError(message: "invalid app-server json")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        if shared != nil {
            guard let ws = stateQueue.sync(execute: { wsTask }),
                  let text = String(data: data, encoding: .utf8) else {
                throw CodexAppServerError(message: "Codex 共有サーバーに接続していません")
            }
            ws.send(.string(text)) { [weak self] error in
                if let error { self?.handleProcessExit("Codex 共有サーバーへの送信に失敗しました: \(error.localizedDescription)") }
            }
            return
        }
        guard let newline = "\n".data(using: .utf8),
              let handle = stateQueue.sync(execute: { stdinHandle }) else {
            throw CodexAppServerError(message: "app-server stdin is unavailable")
        }
        // 例外を投げない write(_:) は、閉じた FileHandle で NSException になり Bridge ごと落ちる。
        try handle.write(contentsOf: data + newline)
    }

    /// 共有 app-server へ WebSocket で繋ぐ。1 フレーム = 1 JSON-RPC メッセージ。
    private func startWebSocket(_ endpoint: CodexSharedEndpoint) {
        var req = URLRequest(url: endpoint.url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: req)
        ws.maximumMessageSize = 64 * 1024 * 1024
        // close と競合したら繋がない（close 側が wsTask を見る前に代入すると cancel されずに残るため）。
        let closed = stateQueue.sync { () -> Bool in
            if didHandleExit { return true }
            wsTask = ws
            return false
        }
        guard !closed else { return }
        ws.resume()
        wsReceiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await ws.receive()
                    switch message {
                    case .string(let text): self?.handleLine(text)
                    case .data(let data): if let text = String(data: data, encoding: .utf8) { self?.handleLine(text) }
                    @unknown default: break
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.handleProcessExit("Codex 共有サーバーとの接続が切れました")
                    }
                    return
                }
            }
        }
    }

    /// chunk は Data のまま改行で切ってから行単位でデコードする（chunk ごとのデコードは、
    /// 多バイト文字の途中で切れた chunk を丸ごと失う）。EOF か Task の cancel で戻る。
    private func readLines(from chunks: AsyncStream<Data>, handler: @escaping (String) -> Void) async {
        var splitter = PipeLineSplitter()
        for await chunk in chunks {
            for rawLine in splitter.feed(chunk) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    handler(line)
                }
            }
        }
    }

    /// app-server からの 1 行（1 JSON-RPC メッセージ）。テストからも呼ぶ（記録した通知の行をそのまま流す）。
    func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let id = int(object["id"]), hasPending(id: id) {
            completePending(id: id, object: object)
            return
        }
        guard let method = string(object["method"]) else { return }
        let params = dictionary(object["params"]) ?? [:]
        if let id = int(object["id"]) {
            handleServerRequest(method: method, id: id, params: params)
        } else {
            handleNotification(method: method, params: params)
        }
    }

    private func hasPending(id: Int) -> Bool {
        pendingQueue.sync { pending[id] != nil }
    }

    private func completePending(id: Int, object: [String: Any]) {
        let continuation = pendingQueue.sync { pending.removeValue(forKey: id) }
        guard let continuation else { return }
        if let error = dictionary(object["error"]) {
            let message = string(error["message"]) ?? "Codex app-server request failed"
            continuation.resume(throwing: CodexAppServerError(message: message))
            return
        }
        continuation.resume(returning: dictionary(object["result"]) ?? [:])
    }

    private func handleNotification(method: String, params: [String: Any]) {
        // 他の thread の通知も来うる（共有サーバーの他接続、stdio でもサブエージェント等の子 thread）。
        // 自分の thread 以外は捨てる。thread id は thread/start・resume の応答で確定させ、
        // thread/started 通知は信用しない（子 thread の id で sessionId が上書きされるため）。
        let tid = string(params["threadId"]) ?? string(dictionary(params["thread"])?["id"])
        if method == "thread/started" {
            noteSubagentThreadStarted(params)
            return
        }
        if let tid, tid != resolvedSessionId {
            // 自分の thread が spawn したサブエージェントの thread なら、その進行だけ拾う
            // （子 thread の通知は、購読していない接続にも届く。0.162.1 の実測）。
            if stateQueue.sync(execute: { work.isChildThread(tid) }) {
                // 子の承認・質問（このセッションのカードとして出したもの）が片付いた知らせは、自分の thread と同じに扱う。
                if method == "serverRequest/resolved" {
                    resolveServerRequest(params)
                    return
                }
                handleSubagentThreadNotification(method: method, params: params, threadId: tid)
            }
            return
        }
        switch method {
        case "turn/started":
            let turnId = string(params["turnId"]) ?? string(dictionary(params["turn"])?["id"])
            stateQueue.sync {
                // 自分のターン = 応答で得た id か、応答より先に turn/started が来た（turn/start の応答待ち）もの。
                let own = turnId.map { localTurnIds.remove($0) != nil } ?? false
                if own || localTurnPending {
                    localTurnPending = false
                    if own { activeTurnId = turnId }
                } else if let turnId { remoteTurnIds.insert(turnId) }
                // iPhone の停止ボタンでターミナル側のターンも止められるように。
                if activeTurnId == nil { activeTurnId = turnId }
            }
        case "item/agentMessage/delta", "item/plan/delta":
            guard let delta = string(params["delta"]), !delta.isEmpty else { return }
            let itemId = string(params["itemId"]) ?? UUID().uuidString
            let turnId = string(params["turnId"])
            stateQueue.sync {
                deltaItems.insert(itemId)
                if let turnId {
                    lastMessageByTurnId[turnId] = itemId
                }
            }
            emitSessionStartedIfNeeded()
            continuation.yield(.assistantDelta(delta, agentId: agentId, sessionId: sessionId, messageId: itemId))
        case "item/started":
            guard let item = dictionary(params["item"]) else { return }
            // ターミナルで打った発話。iPhone から送った分は送った側が表示済みなので流さない
            // （ターミナル側ターンへの steer になった分もそのターンの中で届くので、clientId で見分ける）。
            if string(item["type"]) == "userMessage" {
                let clientId = string(item["clientId"])
                let turnId = string(params["turnId"])
                let isRemote = stateQueue.sync { () -> Bool in
                    if let clientId, ownClientMessageIds.remove(clientId) != nil {
                        // 自分の発話が、自分の始めていないターンへ steer された（知らせのターンではない）。
                        if let turnId, remoteTurnIds.contains(turnId) { turnsWithUtterance.insert(turnId) }
                        return false
                    }
                    return turnId.map { remoteTurnIds.contains($0) } ?? false
                }
                guard isRemote else { return }
                let text = CodexInjectedContext.strippingImageTags((item["content"] as? [[String: Any]] ?? [])
                    .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n"))
                // 差し込まれた文脈（AGENTS.md・<subagent_notification> 等）は発話ではない（知らせのターンのまま）。
                guard !CodexInjectedContext.isInjected(text) else { return }
                let first = stateQueue.sync { turnId.map { turnsWithUtterance.insert($0).inserted } ?? false }
                guard !text.isEmpty else { return }
                // ほかの画面（ターミナル）の発話で始まった新しいターンなら、終わった行を捨てる（アプリも user_message で
                // 捨てる）。同じターンへの 2 つ目からの発話（steer）では捨てない。
                if first { stateQueue.sync { work.pruneFinished() } }
                continuation.yield(.userMessage(text, agentId: agentId, sessionId: sessionId))
                return
            }
            handleItemStarted(item: item, startedAtMs: int(params["startedAtMs"]))
        case "item/completed":
            guard let item = dictionary(params["item"]) else { return }
            handleItemCompleted(item: item, params: params)
        case "turn/completed":
            let turn = dictionary(params["turn"])
            let turnId = string(params["turnId"]) ?? string(turn?["id"])
            let (mid, alreadyErrored, isNotification, shells) = stateQueue.sync { () -> (String?, Bool, Bool, [String]) in
                (turnId.flatMap { lastMessageByTurnId[$0] ?? activeMessageByTurnId[$0] },
                 turnId.map { erroredTurnIds.remove($0) != nil } ?? false,
                 // 自分が始めておらず発話も無いターン = 子の完了などで親が自分から起きた知らせのターン。
                 turnId.map { remoteTurnIds.contains($0) && !turnsWithUtterance.contains($0) } ?? false,
                 // ターンより長く動く端末（processId 付きで、まだ閉じていない commandExecution）を shell の行にする。
                 work.ownTurnCompleted())
            }
            // done より先に流す（done を受けた SessionHub が、バックグラウンドの作業があると分かるように）。
            yieldSubagents(shells)
            let messageId = mid ?? UUID().uuidString
            // 失敗したターンは、直前の error 通知で出していなければここでエラーを出す。
            if string(turn?["status"]) == "failed", !alreadyErrored {
                continuation.yield(SessionEvent(
                    type: .error, agentId: agentId, sessionId: sessionId,
                    messageId: messageId, toolUseId: nil,
                    content: string(dictionary(turn?["error"])?["message"]) ?? "Codex turn failed",
                    toolName: nil, metadata: nil
                ))
            }
            let done = SessionEvent.done(agentId: agentId, sessionId: sessionId, messageId: messageId)
            continuation.yield(isNotification ? done.addingMetadata(["origin": "task-notification"]) : done)
            if let turnId {
                stateQueue.sync {
                    activeMessageByTurnId.removeValue(forKey: turnId)
                    lastMessageByTurnId.removeValue(forKey: turnId)
                    remoteTurnIds.remove(turnId)
                    turnsWithUtterance.remove(turnId)
                    localTurnIds.remove(turnId)
                    interruptedTurnIds.remove(turnId)
                    if activeTurnId == turnId { activeTurnId = nil }
                    // 送った発話の userMessage はターンの中で届き済み（clientId が返らない版で溜め続けない）。
                    if !localTurnPending { ownClientMessageIds.removeAll() }
                }
            }
            // 共有サーバーは止めない（ターミナル側のターンも見続けるため接続も残す）。
            // stdio は、子の thread か裏の端末が動いている間は止めない（止めると道連れになる）。行が無くなったら止める。
            // 途中の send() があるときも止めない（次のターンをこのプロセスで始める。送り終えたら止めるかを見直す）。
            if shared == nil {
                let keep = stateQueue.sync { () -> Bool in
                    deferredStop = work.tracker.hasRunning || sendsInFlight > 0
                    return deferredStop
                }
                if !keep { stopAppServerProcess() }
            }
        case "error":
            // v2 ErrorNotification = { error, willRetry, threadId, turnId }。
            // willRetry=true は再接続中（"Reconnecting... 1/5"）でターンは続くので、終わらせずに進捗として見せる。
            // willRetry=false でも後から turn/completed(status=failed) が来るので、done はそちらで 1 回だけ出す。
            let message = string(dictionary(params["error"])?["message"])
                ?? string(params["message"])
                ?? "Codex turn failed"
            let turnId = string(params["turnId"]).flatMap { $0.isEmpty ? nil : $0 }
            let willRetry = (params["willRetry"] as? Bool) == true
            FileHandle.standardError.write(Data("[codex.appserver] error(willRetry=\(willRetry)): \(message)\n".utf8))
            if willRetry {
                let mid = stateQueue.sync {
                    turnId.flatMap { lastMessageByTurnId[$0] ?? activeMessageByTurnId[$0] }
                } ?? "pending-thought"
                continuation.yield(.activity(agentId: agentId, sessionId: sessionId, messageId: mid, text: message + "\n"))
                return
            }
            // 共有 app-server は起動時のモデル一覧を持ち続ける。新しいモデルが弾かれたら入れ替えを試す。
            if shared != nil, message.contains("is not supported") {
                Task { await CodexSharedAppServer.shared.checkFreshness(reason: "model not supported") }
            }
            let (mid, willComplete) = stateQueue.sync { () -> (String?, Bool) in
                let mid = turnId.flatMap { lastMessageByTurnId[$0] ?? activeMessageByTurnId[$0] }
                // turn/completed が後から来るターン（自分・ターミナルの進行中ターン、turn/started 待ち）か。
                let known = turnId.map {
                    activeTurnId == $0 || activeMessageByTurnId[$0] != nil || remoteTurnIds.contains($0)
                } ?? false
                let willComplete = known || localTurnPending
                if willComplete, let turnId { erroredTurnIds.insert(turnId) }
                return (mid, willComplete)
            }
            let messageId = mid ?? UUID().uuidString
            continuation.yield(SessionEvent(
                type: .error, agentId: agentId, sessionId: sessionId,
                messageId: messageId, toolUseId: nil,
                content: message, toolName: nil, metadata: nil
            ))
            // どのターンにも結び付かない error は turn/completed が来ないので、従来どおり done で spinner を解除する。
            if !willComplete {
                continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
            }
        case "turn/failed", "thread/error":
            // codex 0.160.1・0.162.1 には無い method（失敗は上の error と turn/completed(failed) で届く）。古い版向けに残す。
            // ターン失敗を無視すると iOS 側が永久に待ち続ける（応答も done も来ない）ため、
            // error + done を必ず流して spinner を解除させる。
            let turn = dictionary(params["turn"])
            let message = string(dictionary(turn?["error"])?["message"])
                ?? string(dictionary(params["error"])?["message"])
                ?? string(params["message"])
                ?? "Codex turn failed"
            let turnId = string(params["turnId"]) ?? string(turn?["id"])
            let messageId = stateQueue.sync {
                turnId.flatMap { lastMessageByTurnId[$0] ?? activeMessageByTurnId[$0] }
            } ?? UUID().uuidString
            FileHandle.standardError.write(Data("[codex.appserver] \(method): \(message)\n".utf8))
            // 共有 app-server は起動時のモデル一覧を持ち続ける。新しいモデルが弾かれたら入れ替えを試す。
            if shared != nil, message.contains("is not supported") {
                Task { await CodexSharedAppServer.shared.checkFreshness(reason: "model not supported") }
            }
            continuation.yield(SessionEvent(
                type: .error, agentId: agentId, sessionId: sessionId,
                messageId: messageId, toolUseId: nil,
                content: message, toolName: nil, metadata: nil
            ))
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
            if let turnId {
                stateQueue.sync {
                    activeMessageByTurnId.removeValue(forKey: turnId)
                    lastMessageByTurnId.removeValue(forKey: turnId)
                    if activeTurnId == turnId { activeTurnId = nil }
                }
            }
        case "serverRequest/resolved":
            resolveServerRequest(params)
        case "thread/tokenUsage/updated":
            guard let usage = dictionary(params["tokenUsage"]),
                  let total = dictionary(usage["total"]) else { return }
            var meta: [String: String] = [:]
            for key in ["totalTokens", "inputTokens", "outputTokens", "reasoningOutputTokens"] {
                if let n = total[key] {
                    meta[key] = "\(n)"
                }
            }
            continuation.yield(SessionEvent(
                type: .usageUpdate,
                agentId: agentId,
                sessionId: sessionId,
                messageId: string(params["turnId"]),
                toolUseId: nil,
                content: nil,
                toolName: nil,
                metadata: meta
            ))
        case "thread/status/changed":
            // 自分の thread の状態（active / idle）は turn/started・turn/completed で足りる。子 thread の分は
            // handleSubagentThreadNotification が見る（systemError で失敗にする）。
            break
        default:
            // 未対応 method の診断ログ。プロトコルドリフト (codex CLI 更新) で
            // 重要通知を取りこぼした時に err.log から原因を特定できるようにする。
            // mcpServer 系と hook 系は大量に出るので除外。
            if !method.hasPrefix("mcpServer/"), !method.hasPrefix("hook/"),
               !method.hasPrefix("account/"), method != "remoteControl/status/changed" {
                FileHandle.standardError.write(Data("[codex.appserver] unhandled: \(method)\n".utf8))
            }
        }
    }

    /// v2 ServerRequestResolvedNotification = { threadId, requestId }。ターミナル側が先に答えた・
    /// ターンの中断や終了で片付いた要求は、もう答えられないので待ちから外す（残ったカードから後で押しても書かない）。
    /// 自分で答えた分にも来るが、既に消してあるので二重に消しても害はない。
    /// requestId は数値・文字列のどちらもあり得るので、yieldApprovalRequest と同じ String(id) に揃える。
    private func resolveServerRequest(_ params: [String: Any]) {
        guard let requestId = int(params["requestId"]).map({ String($0) }) ?? string(params["requestId"]) else { return }
        let wasPending = stateQueue.sync { () -> Bool in
            pendingActionQuestionIds.removeValue(forKey: requestId)
            return pendingActionKinds.removeValue(forKey: requestId) != nil
        }
        // まだ待っていた要求（ターミナル側が答えた・中断で片付いた）なら、iPhone のカードを閉じさせる。
        if wasPending {
            yieldActionsResolved([requestId])
        }
    }

    private func handleServerRequest(method: String, id: Int, params: [String: Any]) {
        // 共有 app-server では、他の thread（ターミナルや別の会話）の要求もこの接続に届く。
        // その要求のカードをこの会話に出すと取り違えるので出さない（その thread を開いている側が答える）。
        // 自分の thread が spawn したサブエージェントの thread の要求は通す（子は親の承認の設定を受け継ぐ。答えないと
        // 子は止まったままで、行が「実行中」のまま残る。Windows と同じ）。
        if shared != nil, let mine = resolvedSessionId,
           let tid = string(params["threadId"]) ?? string(params["conversationId"]), tid != mine,
           !stateQueue.sync(execute: { work.isChildThread(tid) }) {
            return
        }
        switch method {
        case "item/commandExecution/requestApproval":
            let command = string(params["command"]) ?? "command"
            let reason = string(params["reason"])
            let cwd = string(params["cwd"])
            var subtitle = reason ?? command
            if let cwd, !cwd.isEmpty {
                subtitle += "\n\(cwd)"
            }
            yieldApprovalRequest(
                requestId: String(id),
                kind: "commandApproval",
                title: "コマンド実行を承認しますか",
                subtitle: subtitle
            )
        case "item/fileChange/requestApproval":
            yieldApprovalRequest(
                requestId: String(id),
                kind: "fileApproval",
                title: "ファイル変更を承認しますか",
                subtitle: string(params["reason"]) ?? string(params["grantRoot"])
            )
        case "item/permissions/requestApproval":
            yieldApprovalRequest(
                requestId: String(id),
                kind: "permissionsApproval",
                title: "権限変更を承認しますか",
                subtitle: string(params["reason"])
            )
        case "execCommandApproval":
            // 旧形式（v1）の承認要求。応答しないとターンが止まるので、新形式と同じカードで答える。
            let command = (params["command"] as? [String])?.joined(separator: " ") ?? string(params["command"]) ?? "command"
            yieldApprovalRequest(
                requestId: String(id), kind: "commandApproval", title: "コマンド実行を承認しますか",
                subtitle: string(params["reason"]) ?? command, pendingKind: "legacyApproval")
        case "applyPatchApproval":
            yieldApprovalRequest(
                requestId: String(id), kind: "fileApproval", title: "ファイル変更を承認しますか",
                subtitle: string(params["reason"]) ?? string(params["grantRoot"]), pendingKind: "legacyApproval")
        case "item/tool/requestUserInput":
            if let questions = params["questions"] as? [[String: Any]], !questions.isEmpty {
                yieldUserInputRequest(requestId: String(id), params: params)
            } else {
                // 質問の無い要求にも応答しないと、app-server が待ち続けてターンが止まる。
                respondAutomatically(id: id, params: params, ["result": ["answers": [String: Any]()]])
            }
        case "mcpServer/elicitation/request":
            let meta = dictionary(params["_meta"])
            if string(meta?["codex_approval_kind"]) == "mcp_tool_call" {
                // MCP ツール呼び出しの承認は elicitation で来る（専用の approval 要求は無い）。
                // 応答は decision ではなく action 形式なので、respondToAction で "elicitation" として返す。
                let subtitle = [string(params["message"]), string(params["serverName"])]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                yieldApprovalRequest(
                    requestId: String(id),
                    kind: "mcpToolApproval",
                    title: "MCP ツールの実行を承認しますか",
                    subtitle: subtitle.isEmpty ? nil : subtitle,
                    pendingKind: "elicitation"
                )
            } else {
                // フォーム入力・URL を開く要求は iPhone で扱えないので断る（応答しないとツール呼び出しが止まる）。
                respondAutomatically(id: id, params: params,
                                     ["result": ["action": "decline", "content": NSNull(), "_meta": NSNull()]])
            }
        default:
            // 未対応の要求にも必ずエラーで応答する。応答しないと app-server が待ち続けてターンが止まる。
            FileHandle.standardError.write(Data("[codex.appserver] unsupported server request: \(method)\n".utf8))
            respondAutomatically(id: id, params: params,
                                 ["error": ["code": -32601, "message": "BuddyOS does not support \(method)"]])
        }
    }

    /// 承認 UI を介さずにその場で応答する（未対応の要求への断りなど）。
    /// 共有 app-server ではターミナル（buddy-codex）にも同じ要求が届いているので、他の thread の要求や
    /// ターミナルで開いている thread の要求には返さない（先に断ってターミナル側の UI を潰さないため）。
    private func respondAutomatically(id: Int, params: [String: Any], _ payload: [String: Any]) {
        let tid = string(params["threadId"])
        let mine = resolvedSessionId
        // 自分の thread が spawn したサブエージェントの要求は、自分の thread の要求として扱う（ターミナルで開いているかは親で見る）。
        let child = tid.map { t in t != mine && stateQueue.sync { work.isChildThread(t) } } ?? false
        if shared != nil, let tid, tid != mine, !child { return }
        let owner = child ? mine : tid
        Task { [weak self] in
            guard let self else { return }
            if self.shared != nil, let owner,
               await CodexTerminalRegistry.shared.liveEntries().contains(where: { $0.threadId == owner }) {
                return
            }
            var message = payload
            message["id"] = id
            do {
                try self.writeJSON(message)
            } catch {
                FileHandle.standardError.write(Data("[codex.appserver] auto response failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    private func yieldApprovalRequest(requestId: String, kind: String, title: String, subtitle: String?,
                                      pendingKind: String = "approval") {
        stateQueue.sync {
            pendingActionKinds[requestId] = pendingKind
        }
        let meta: [String: String] = [
            "requestId": requestId,
            "kind": kind,
            "option_count": "3",
            "option_0_title": "承認",
            "option_0_subtitle": "一度だけ許可",
            "option_0_value": "accept",
            "option_1_title": "このセッションでは承認",
            "option_1_subtitle": "同種の操作を続けて許可",
            "option_1_value": "acceptForSession",
            "option_2_title": "非承認",
            "option_2_subtitle": "実行しない",
            "option_2_value": "decline",
            "allowsOther": "0"
        ]
        continuation.yield(.actionRequest(
            agentId: agentId,
            sessionId: sessionId,
            messageId: requestId,
            title: title,
            subtitle: subtitle,
            metadata: meta
        ))
    }

    private func yieldUserInputRequest(requestId: String, params: [String: Any]) {
        guard let questions = params["questions"] as? [[String: Any]],
              let question = questions.first else { return }
        // 全部の質問を出す（questions_json）。答えのキーは質問 id。
        // 選択肢に無い答え（その他）を受けるのは、Codex が isOther を付けた質問があるときだけ。
        let qs: [[String: Any]] = questions.enumerated().map { i, q in
            var out = q
            out["id"] = string(q["id"]) ?? "q\(i)"
            out["multiSelect"] = false
            return out
        }
        let allowsOther = questions.contains { ($0["isOther"] as? Bool) == true || ($0["options"] as? [Any])?.isEmpty != false }
        var meta = ClaudeControlProtocol.questionMetadata(qs, allowsOther: allowsOther)
        meta["requestId"] = requestId
        let questionId = string(question["id"]) ?? "q0"
        let otherQuestionIds = qs.dropFirst().compactMap { string($0["id"]) }
        stateQueue.sync {
            pendingActionKinds[requestId] = "userInput"
            pendingActionQuestionIds[requestId] = [questionId] + otherQuestionIds
        }
        continuation.yield(.actionRequest(
            agentId: agentId,
            sessionId: sessionId,
            messageId: requestId,
            title: string(question["header"]) ?? "選択してください",
            subtitle: string(question["question"]),
            metadata: meta
        ))
    }

    /// answers_json（{ 質問 id: 文字列 | [文字列] }）→ 質問 id → 答えの配列。
    static func answerArrays(_ raw: String?) -> [String: [String]] {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: [String]] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = [s] }
            else if let a = v as? [Any] { out[k] = a.compactMap { $0 as? String } }
        }
        return out
    }

    private func handleItemStarted(item: [String: Any], startedAtMs: Int? = nil) {
        guard let type = string(item["type"]),
              let id = string(item["id"]) else { return }
        // サブエージェントの item（collabAgentToolCall・subAgentActivity）と、ターンより長く動きうる端末の覚え書き
        // （開始時刻は通知の startedAtMs）。
        yieldSubagents(stateQueue.sync { work.ownItemStarted(item, startedAtMs: startedAtMs) })
        switch type {
        case "commandExecution":
            let command = string(item["command"]) ?? "command"
            continuation.yield(.toolStart(
                agentId: agentId,
                sessionId: sessionId,
                toolUseId: id,
                toolName: "command",
                title: command,
                kind: "execute"
            ))
        case "mcpToolCall":
            let server = string(item["server"]) ?? "mcp"
            let tool = string(item["tool"]) ?? "tool"
            continuation.yield(.toolStart(
                agentId: agentId,
                sessionId: sessionId,
                toolUseId: id,
                toolName: "\(server).\(tool)",
                title: "\(server).\(tool)",
                kind: "other"
            ))
        case "fileChange":
            // 変更の差分（unified diff）を metadata に載せる。デスクトップはツール行を開くと差分を出す。
            // iOS は未知の metadata を無視する。
            let event = SessionEvent.toolStart(
                agentId: agentId,
                sessionId: sessionId,
                toolUseId: id,
                toolName: "file_change",
                title: CodexFileChangeDiff.title(item) ?? "ファイル変更",
                kind: "edit"
            )
            continuation.yield(CodexFileChangeDiff.json(item).map { event.addingMetadata(["diff": $0]) } ?? event)
        default:
            break
        }
    }

    // MARK: - サブエージェント（multi_agent / collab）とバックグラウンドの端末

    /// 自分の thread が spawn した子 thread の開始（thread/started）。0.162.1 の子 thread には来ないが、来る版のために残す。
    private func noteSubagentThreadStarted(_ params: [String: Any]) {
        guard let thread = dictionary(params["thread"]) else { return }
        let own = resolvedSessionId
        yieldSubagents(stateQueue.sync { work.threadStarted(thread, ownThreadId: own) })
    }

    /// サブエージェントの子 thread の通知。ツールの開始をいまの作業に、ターンの終わり方を行の状態にする。
    private func handleSubagentThreadNotification(method: String, params: [String: Any], threadId tid: String) {
        if method == "turn/completed", let turnId = string(dictionary(params["turn"])?["id"]) ?? string(params["turnId"]) {
            stateQueue.sync {
                interruptedTurnIds.remove(turnId)
                timedOutChildTurnIds.remove(turnId)
            }
        }
        yieldSubagents(stateQueue.sync { work.childNotification(method: method, params: params, threadId: tid) })
    }

    /// 行の payload を 1 つ流す。close・異常終了・app-server の停止の後片付けはこちらを使う（延ばした停止は見ない）。
    private func yieldSubagent(_ payload: String?) {
        guard let payload else { return }
        continuation.yield(.workflowProgress(agentId: agentId, sessionId: sessionId, payloadJSON: payload))
    }

    /// 行の変化を流す。stdio で app-server を止めるのを延ばしていて、行が無くなったら止める。
    private func yieldSubagents(_ payloads: [String]) {
        guard !payloads.isEmpty else { return }
        payloads.forEach(yieldSubagent)
        stopDeferredAppServerIfIdle()
    }

    /// stdio: 延ばしていた app-server の停止を、実行中の行が無くなり、進行中のターンも途中の send() も無ければ行う。
    private func stopDeferredAppServerIfIdle() {
        guard shared == nil else { return }
        stopAppServerProcess(onlyIfIdle: true)
    }

    /// send() の始まり。終わるまで、延ばしていた app-server の停止をしない。
    func noteSendStarted() {
        stateQueue.sync { sendsInFlight += 1 }
    }

    /// send() の終わり。延ばしていた停止を見直す（ターンが始まっていれば、そのターンの終わりまで延ばしたまま）。
    func noteSendFinished() {
        stateQueue.sync { sendsInFlight = max(0, sendsInFlight - 1) }
        stopDeferredAppServerIfIdle()
    }

    /// サブエージェントのカードの全行（workflow_progress の JSON。subtype "workflow_snapshot"、kind "subagents"、epoch 付き）。
    /// 接続したときと turn_status_request のときに SessionHub が送る。行が無くても agents: [] で返す（§3.5）。
    func subagentSnapshot() async -> String? {
        stateQueue.sync { work.tracker.snapshot(includeEmpty: true) }
    }

    /// テスト用: stdio の app-server を止めるのを、実行中の行が終わるまで延ばしているか。
    var isAppServerStopDeferred: Bool { stateQueue.sync { deferredStop } }

    // MARK: - 共有 app-server の上で動いている作業（再起動の判定）

    private struct WeakSession { weak var session: CodexAppServerSession? }
    /// 共有 app-server に繋いでいるセッション。restartBlocker が、動いている子 thread と裏の端末を数えるのに使う
    /// （共有サーバーを再起動すると、どちらも道連れになる）。
    private static let sharedSessionsLock = NSLock()
    nonisolated(unsafe) private static var sharedSessions: [ObjectIdentifier: WeakSession] = [:]

    private static func registerShared(_ session: CodexAppServerSession) {
        sharedSessionsLock.withLock { sharedSessions[ObjectIdentifier(session)] = WeakSession(session: session) }
    }

    private static func unregisterShared(_ id: ObjectIdentifier) {
        _ = sharedSessionsLock.withLock { sharedSessions.removeValue(forKey: id) }
    }

    /// 共有 app-server の上でいま動いている、サブエージェント（子 thread）とバックグラウンドの端末の数（全セッションの合計）。
    static func sharedBackgroundWork() -> (agents: Int, shells: Int) {
        let sessions = sharedSessionsLock.withLock { sharedSessions.values.compactMap(\.session) }
        var agents = 0
        var shells = 0
        for session in sessions {
            let counts = session.stateQueue.sync { (session.work.tracker.runningAgentCount, session.work.tracker.runningShellCount) }
            agents += counts.0
            shells += counts.1
        }
        return (agents, shells)
    }

    /// Codex の plan アイテム（update_plan）から全置換スナップショット JSON を作る。
    /// rollout 実測の形は `plan: [{ step, status }]`（status=pending|in_progress|completed で BuddyOS と一致）。
    /// app-server のフィールド名差に備え plan/steps/entries・step/content/text/title を順に探す。
    /// 構造化 plan が無ければ nil（呼び出し側はテキスト表示にフォールバック）。
    private func codexPlanSnapshot(from item: [String: Any]) -> String? {
        let raw = (item["plan"] as? [[String: Any]])
            ?? (item["steps"] as? [[String: Any]])
            ?? (item["entries"] as? [[String: Any]])
        guard let steps = raw else { return nil }
        let entries: [[String: String]] = steps.compactMap { s in
            guard let label = string(s["step"]) ?? string(s["content"]) ?? string(s["text"]) ?? string(s["title"]),
                  !label.isEmpty else { return nil }
            let status = string(s["status"]) ?? "pending"
            return ["content": label, "status": status]
        }
        guard !entries.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["entries": entries]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private func handleItemCompleted(item: [String: Any], params: [String: Any]) {
        guard let type = string(item["type"]),
              let id = string(item["id"]) else { return }
        // サブエージェントの item と、ターンの後に閉じた裏の端末（exitCode で done / failed）。
        // 止めた端末（アプリの停止で終わった）の tool_end は interrupted にする（赤くしない）。
        let stopped = stateQueue.sync { work.isStopped(execItem: item) }
        yieldSubagents(stateQueue.sync { work.ownItemCompleted(item) })
        switch type {
        case "agentMessage":
            let alreadyStreamed = stateQueue.sync { deltaItems.contains(id) }
            if !alreadyStreamed, let text = string(item["text"]), !text.isEmpty {
                continuation.yield(.assistantDelta(text, agentId: agentId, sessionId: sessionId, messageId: id))
            }
        case "plan":
            // 構造化 plan（update_plan のステップ配列）があればチェックリスト進捗として流す。
            // 取れなければ従来通りテキストとして流す（フィールド名の版差に対するフォールバック）。
            if let json = codexPlanSnapshot(from: item) {
                continuation.yield(.planUpdate(agentId: agentId, sessionId: sessionId, entriesJSON: json))
            } else {
                let alreadyStreamed = stateQueue.sync { deltaItems.contains(id) }
                if !alreadyStreamed, let text = string(item["text"]), !text.isEmpty {
                    continuation.yield(.assistantDelta(text, agentId: agentId, sessionId: sessionId, messageId: id))
                }
            }
        case "commandExecution":
            // 非承認（declined）は実行されていない。iOS は failed 以外を完了（チェック）で描くので failed に寄せる。
            let status = stopped ? "interrupted"
                : ["failed", "declined"].contains(string(item["status"]) ?? "") ? "failed" : "completed"
            continuation.yield(.toolEnd(
                agentId: agentId,
                sessionId: sessionId,
                toolUseId: id,
                toolName: "command",
                status: status,
                summary: string(item["aggregatedOutput"]).map(truncateToolSummary),
                durationMs: int(item["durationMs"])
            ))
        case "mcpToolCall":
            let status = string(item["status"]) == "failed" ? "failed" : "completed"
            let server = string(item["server"]) ?? "mcp"
            let tool = string(item["tool"]) ?? "tool"
            continuation.yield(.toolEnd(
                agentId: agentId,
                sessionId: sessionId,
                toolUseId: id,
                toolName: "\(server).\(tool)",
                status: status,
                summary: nil,
                durationMs: int(item["durationMs"])
            ))
        case "fileChange":
            // PatchApplyStatus も inProgress|completed|failed|declined。commandExecution と同じく揃える。
            // completedAtMs は完了時刻（エポックミリ秒）で所要時間ではないので渡さない。
            let status = ["failed", "declined"].contains(string(item["status"]) ?? "") ? "failed" : "completed"
            let event = SessionEvent.toolEnd(
                agentId: agentId,
                sessionId: sessionId,
                toolUseId: id,
                toolName: "file_change",
                status: status,
                summary: nil,
                durationMs: nil
            )
            // 完了時点の差分（開始時に無かった・変わった場合のため、こちらでも送る）。
            continuation.yield(CodexFileChangeDiff.json(item).map { event.addingMetadata(["diff": $0]) } ?? event)
        default:
            break
        }
    }

    private func promptText(text: String, skills: [String], attachments: [BridgeAttachment]) -> String {
        var sections: [String] = []
        if !skills.isEmpty {
            sections.append("/skill \(skills.joined(separator: ","))")
        }
        for attachment in attachments where attachment.kind == .file {
            if let decoded = String(data: attachment.data, encoding: .utf8) {
                sections.append("<file name=\"\(attachment.name)\">\n\(decoded)\n</file>")
            } else {
                sections.append("[file \"\(attachment.name)\" attached: \(attachment.mime), \(attachment.data.count) bytes]")
            }
        }
        // 実画像は localImage 入力でモデルへ届くが、rollout(履歴)には残らない。
        // Claude と同じ placeholder を本文に入れておくと、loadHistory→enrichHistory が
        // AttachmentStore と突合して実画像を復元できる（本文表示時に placeholder は除去される）。
        for attachment in attachments where attachment.kind == .image {
            sections.append("[image \"\(attachment.name)\" attached: \(attachment.mime), \(attachment.data.count) bytes]")
        }
        sections.append(text)
        return sections.joined(separator: "\n\n")
    }

    private func userInputs(prompt: String, attachments: [BridgeAttachment], tmpDir: String?) throws -> [[String: Any]] {
        var inputs: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt,
                "text_elements": []
            ]
        ]
        guard let tmpDir else { return inputs }
        for attachment in attachments where attachment.kind == .image {
            let ext = filenameExtension(forMime: attachment.mime, fallbackName: attachment.name)
            let filename = "\(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")"
            let path = (tmpDir as NSString).appendingPathComponent(filename)
            try attachment.data.write(to: URL(fileURLWithPath: path))
            inputs.append([
                "type": "localImage",
                "path": path
            ])
        }
        return inputs
    }

    private func updateSessionIdIfNeeded(_ sid: String) {
        guard !sid.isEmpty else { return }
        stateQueue.sync {
            guard sid != sessionIdStorage else { return }
            resolvedSessionIdStorage = sid
            sessionIdStorage = sid
        }
    }

    /// send タスクと受信タスクの両方から呼ばれるので、確認と更新を stateQueue でまとめて行う（二重送出しない）。
    private func emitSessionStartedIfNeeded() {
        let shouldEmit = stateQueue.sync { () -> Bool in
            if didEmitSessionStarted { return false }
            didEmitSessionStarted = true
            return true
        }
        guard shouldEmit else { return }
        continuation.yield(.sessionStarted(agentId: agentId, sessionId: sessionId))
    }

    func applyOverrides(_ overrides: SessionOverrides) {
        overridesLock.withLock { self.overrides = overrides }
    }

    private var currentOverrides: SessionOverrides { overridesLock.withLock { overrides } }

    /// チャットで選んだモード（plan/auto/dangerous）の sandbox / approval。未指定・不正なら nil。
    private var overrideModeValues: (sandbox: String, approval: String)? {
        guard let mode = currentOverrides.mode else { return nil }
        return try? config.codexModeValues(mode)
    }

    private func currentModel() -> String {
        currentOverrides.model ?? config.currentModel() ?? activeModel ?? "gpt-5.5"
    }

    private func currentReasoningEffort() -> String {
        // モデルが対応しない effort（モデルだけ変えた等）は捨てて既定に戻す。
        if let effort = currentOverrides.reasoningEffort,
           let valid = try? config.validatedReasoningEffort(effort, model: currentModel()) {
            return valid
        }
        return config.currentReasoningEffort() ?? activeReasoningEffort ?? "high"
    }

    private func currentApprovalPolicy() -> String {
        // mainagent は書かない（読むだけ）ので、尋ねることも無い。
        if mainToken != nil, mainRestricted { return "never" }
        return overrideModeValues?.approval ?? config.currentApprovalPolicy() ?? "on-request"
    }

    private func currentSandboxMode() -> String {
        if mainToken != nil, mainRestricted { return "read-only" }
        return overrideModeValues?.sandbox ?? config.currentSandboxMode() ?? "workspace-write"
    }

    private func sandboxPolicy(for mode: String) -> [String: Any] {
        switch mode {
        case "read-only":
            return ["type": "readOnly", "networkAccess": false]
        case "danger-full-access":
            return ["type": "dangerFullAccess"]
        default:
            return [
                "type": "workspaceWrite",
                "writableRoots": [],
                "networkAccess": false,
                "excludeTmpdirEnvVar": false,
                "excludeSlashTmp": false
            ]
        }
    }

    private func makeTmpDir() -> String? {
        // テスト中は BuddyPaths が一時フォルダを返すので、本物の ~/.buddyos/tmp を汚さない。
        let base = BuddyPaths.root.appendingPathComponent("tmp/\(UUID().uuidString)", isDirectory: true).path
        do {
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            return base
        } catch {
            return nil
        }
    }

    private func filenameExtension(forMime mime: String, fallbackName: String) -> String {
        let ext = (fallbackName as NSString).pathExtension
        if !ext.isEmpty { return ext }
        switch mime {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return "jpg"
        }
    }

    private func environment() -> [String: String] { Self.spawnEnvironment() }

    static func spawnEnvironment() -> [String: String] {
        var env = ChildEnvironment.base()
        let additions = [
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.petclaw/node/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin"
        ]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (additions + [current]).joined(separator: ":")
        return env
    }

    private func truncateToolSummary(_ text: String) -> String {
        if text.count <= 1200 { return text }
        return String(text.prefix(1200)) + "\n..."
    }

    /// onlyIfIdle: 延ばしていた停止。止める理由が残っていれば（実行中の行・ターン・途中の send()）止めない。判定と片付けを
    /// 1 つの排他区間で行う（判定の後に send() が ensureThread を済ませ、止めたプロセスへ turn/start を書かないように）。
    private func stopAppServerProcess(onlyIfIdle: Bool = false) {
        var resolvedActions: [String] = []
        var abandoned: String?
        let teardown = stateQueue.sync { () -> (Process?, FileHandle?, Task<Void, Never>?, Task<Void, Never>?)? in
            if onlyIfIdle {
                guard deferredStop, !work.tracker.hasRunning, activeTurnId == nil, !localTurnPending,
                      sendsInFlight == 0 else { return nil }
            }
            let current = (process, stdinHandle, stdoutTask, stderrTask)
            process = nil
            stdinHandle = nil
            stdoutTask = nil
            stderrTask = nil
            didStart = false
            didInitialize = false
            didOpenThread = false
            deferredStop = false
            activeMessageByTurnId.removeAll()
            lastMessageByTurnId.removeAll()
            activeTurnId = nil
            interruptedTurnIds.removeAll()
            timedOutChildTurnIds.removeAll()
            deltaItems.removeAll()
            localTurnIds.removeAll()
            ownClientMessageIds.removeAll()
            // プロセスを止めると承認待ちにはもう答えられない（残ったカードから閉じた stdin へ書かないように）。
            resolvedActions = Array(pendingActionKinds.keys)
            pendingActionKinds.removeAll()
            pendingActionQuestionIds.removeAll()
            // 子の thread と裏の端末もプロセスと一緒に止まる（実行中の行があるうちは止めないので、ふつうは何も無い）。
            abandoned = work.abandonRunning(state: "stopped")
            return current
        }
        guard let teardown else { return }
        yieldSubagent(abandoned)
        // 待っている request は捨てずに失敗で resume する（捨てると await した側が永久に戻らない）。
        let drained = pendingQueue.sync { () -> [CheckedContinuation<[String: Any], Error>] in
            let conts = Array(pending.values)
            pending.removeAll()
            return conts
        }
        for c in drained {
            c.resume(throwing: CodexAppServerError(message: "codex app-server stopped"))
        }
        yieldActionsResolved(resolvedActions)
        // ターン完了後の意図的な teardown（次の send で新プロセスを respawn する設計）。
        // terminate() が誘発する stdout EOF / terminationHandler を handleProcessExit が
        // クラッシュと誤認し「出力が途切れました」エラーを撒くため、先に読み取りタスクを
        // cancel し terminationHandler を外して、両方の検知経路を黙らせてから終了する。
        teardown.2?.cancel()
        teardown.3?.cancel()
        teardown.0?.terminationHandler = nil
        try? teardown.1?.close()
        if teardown.0?.isRunning == true {
            teardown.0?.terminate()
        }
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func int(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}

// MARK: - サブエージェントとバックグラウンドの端末の行

/// Codex の子 thread（サブエージェント）とバックグラウンドの端末を、SubagentTracker の行にする。
/// 規則は docs/BACKGROUND_WORK_2026-10-21.md §3.6（codex 0.162.1 の実測）。
/// - 子の開始: subAgentActivity started（multi-agent v2。いまの既定のモデルはこちらで、model・reasoningEffort が付く）、
///   collabAgentToolCall spawnAgent（v1。receiverThreadIds・prompt・model）、thread/started（0.162.1 の子には来ない）。
///   行のキーは子 thread id
/// - 子の進行と終わりは子 thread の通知で見る。turn/completed は completed → done（最後の発言を結果に）、
///   interrupted → stopped、failed → failed（turn.error か、子の error 通知の文を結果に）。
///   error（willRetry=false）と thread/status/changed の systemError も failed
/// - subAgentActivity の interacted（send_message・followup_task）は作業の文だけ変える（send_message は子のターンを
///   起こさない）。実行中に戻すのは子の turn/started。interrupted → stopped、completed → done
///   （子の turn/completed の後に来る。failed / stopped の行は上書きしない＝SubagentTracker が受けない）
/// - バックグラウンドの端末: 自分の thread の turn/completed の時点で閉じていない commandExecution（processId あり）を
///   shell の行（tool "exec"）にし、後から届く item/completed の exitCode で done / failed にする。行のキーは item id
/// 値型。CodexAppServerSession の stateQueue の下で使う。
struct CodexBackgroundWork {
    private(set) var tracker = SubagentTracker()
    /// 自分の thread で始まり、まだ item/completed の来ていない commandExecution（processId あり）。始まった順。
    /// startedAt は item/started の startedAtMs（行にするのはターンの終わりなので、本当の開始時刻を覚えておく）。
    private var openExecs: [(id: String, processId: String, command: String, startedAt: Date?)] = []
    /// 子 thread の今の turn id（turn/started で入れ、turn/completed で消す）。行を止める手がかり。
    private(set) var childTurns: [String: String] = [:]
    /// アプリの停止で終わらせた端末の item id。後から届く item/completed（failed / -1）を stopped と読む。上限つき。
    private var stoppedExecs: [String] = []
    /// thread/backgroundTerminals/terminate が使えるか。使えない版（experimentalApi が要る・知らない method）だと false にし、手がかりを外す。
    private(set) var terminalStopSupported = true
    /// 子 thread の最後の発言（turn/completed の items に無いときの結果）。
    private var lastMessages: [String: String] = [:]
    /// 子 thread の error の文（turn/completed の turn.error が無いときの結果）。
    private var errors: [String: String] = [:]
    /// 一度でも行にした子 thread（id → 行の見出し・種類・モデル）。新しいターンの pruneFinished で終わった行を忘れても残す。
    /// 後のターンで話しかけ直された子（followup_task・sendInput・resumeAgent）の通知と承認の要求を見分け（isChildThread）、
    /// 子の turn/started で行を作り直すため。上限つき（古いものから忘れる）。
    private var knownChildren: [String: (label: String?, agentType: String?, model: String?)] = [:]
    private var knownOrder: [String] = []
    static let knownChildLimit = 128

    /// interacted のときの作業の文（v2 の item は、送った中身を持たない）。
    static let interactedActivity = "message from parent"

    /// 自分の thread が spawn した子 thread か（知らない thread の通知は捨てる）。終わって行を忘れた子も含む。
    func isChildThread(_ threadId: String) -> Bool { tracker.contains(threadId) || knownChildren[threadId] != nil }

    /// 新しいターンを始める前に、終わった行を忘れる（動いているものは残す）。
    mutating func pruneFinished() { tracker.pruneFinished() }

    /// close・異常終了・app-server の停止で、もう終わりの知らせが来ない実行中の行を閉じる
    /// （止めたなら stopped、落ちたなら failed）。閉じた行があれば payload を返す。
    mutating func abandonRunning(state: String) -> String? {
        openExecs.removeAll()
        childTurns.removeAll()
        lastMessages.removeAll()
        errors.removeAll()
        return tracker.abandonRunning(state: state)
    }

    /// 自分の thread の item/started。サブエージェントの item は行に、processId 付きの端末は覚えておく。
    /// startedAtMs は通知の params の開始時刻（端末を行にするときの開始時刻）。
    mutating func ownItemStarted(_ item: [String: Any], startedAtMs: Int? = nil) -> [String] {
        switch item["type"] as? String {
        case "subAgentActivity", "collabAgentToolCall":
            return subagentItem(item)
        case "commandExecution":
            // processId 付き（unified exec の端末）は、ツールの呼び出しやターンが終わっても動き続けることがある。
            guard let id = Self.string(item["id"]), let processId = Self.processId(item),
                  !openExecs.contains(where: { $0.id == id }) else { return [] }
            openExecs.append((id: id, processId: processId, command: Self.execCommand(item) ?? "command",
                              startedAt: startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }))
            if openExecs.count > 64 { openExecs.removeFirst() }
            return []
        default:
            return []
        }
    }

    /// 自分の thread の item/completed。
    mutating func ownItemCompleted(_ item: [String: Any]) -> [String] {
        switch item["type"] as? String {
        case "subAgentActivity", "collabAgentToolCall":
            return subagentItem(item)
        case "commandExecution":
            guard let id = Self.string(item["id"]) else { return [] }
            let stopped = isStopped(execItem: item)
            openExecs.removeAll { $0.id == id }
            // ターンの後も動いていた端末が閉じた（turnId は終わったターンのまま届く）。所要時間は item の durationMs。
            guard tracker.contains(id) else { return [] }
            return Self.list(tracker.finish(key: id, state: Self.execState(item, stopped: stopped),
                                            result: Self.outputTail(item["aggregatedOutput"]),
                                            durationMs: Self.int(item["durationMs"])))
        default:
            return []
        }
    }

    /// 自分の thread の turn/completed。まだ閉じていない端末を shell の行にする（バックグラウンドの端末を示す
    /// 明示のイベントは無い。目印は、ターンが終わっても開いたままの processId 付きの commandExecution）。
    mutating func ownTurnCompleted() -> [String] {
        var out: [String] = []
        for exec in openExecs where !tracker.contains(exec.id) {
            if let p = tracker.begin(key: exec.id, label: exec.command, background: true, rowKind: "shell",
                                     tool: "exec", command: exec.command, startedAt: exec.startedAt) {
                // 止める手がかり（processId）がある。立てた後の payload が、begin の payload に代わる。
                out.append(terminalStopSupported ? (tracker.setStopHandle(key: exec.id, on: true) ?? p) : p)
            }
        }
        return out
    }

    /// 閉じた端末の item が、アプリの停止で終わったもの（返事待ちか、止め終えた端末で、exitCode が -1）か。
    func isStopped(execItem item: [String: Any]) -> Bool {
        guard let id = Self.string(item["id"]), Self.int(item["exitCode"]) == -1 else { return false }
        return stoppedExecs.contains(id) || tracker.isStopRequested(key: id)
    }

    /// 停止を頼む前後の行の印（SubagentTracker.beginStop / endStop）と、頼んだ側で閉じるときの stopped。
    mutating func beginStop(key: String) -> SubagentTracker.BeginStop { tracker.beginStop(key: key) }
    mutating func endStop(key: String) -> String? { tracker.endStop(key: key) }
    mutating func finishStopped(_ key: String) -> String? { tracker.finish(key: key, state: "stopped", result: nil) }

    /// 止める shell 行の processId（まだ item/completed の来ていない端末）。
    func processId(forExec id: String) -> String? { openExecs.first { $0.id == id }?.processId }

    /// 端末を止め終えた（terminated: true）。
    mutating func noteStoppedExec(_ id: String) {
        guard !stoppedExecs.contains(id) else { return }
        stoppedExecs.append(id)
        if stoppedExecs.count > 64 { stoppedExecs.removeFirst() }
    }

    /// terminate が使えない版と分かった。全 shell 行の手がかりを外す（変わった行の payload を返す）。
    mutating func disableTerminalStop() -> [String] {
        terminalStopSupported = false
        return openExecs.compactMap { tracker.setStopHandle(key: $0.id, on: false) }
    }

    /// 子の turn を覚えている間は、その行を止める手がかりがある。
    private mutating func noteChildTurn(_ tid: String, _ turnId: String?, startPayloads: [String]) -> [String] {
        guard let turnId else { return startPayloads }
        childTurns[tid] = turnId
        guard let handle = tracker.setStopHandle(key: tid, on: true) else { return startPayloads }
        // 立てた後の payload が、行を始めた payload に代わる。
        return startPayloads.isEmpty ? [handle] : Array(startPayloads.dropLast()) + [handle]
    }

    /// 行を止める手がかりが消えていた。外して、変わった行の payload は endStop が返す。
    mutating func dropStopHandle(_ key: String) {
        _ = tracker.setStopHandle(key: key, on: false)
    }

    /// 子の今の turn が無かった（手がかりが古い）。外して、変わった行の payload は endStop が返す。
    mutating func dropChildTurnHandle(_ tid: String) {
        childTurns.removeValue(forKey: tid)
        _ = tracker.setStopHandle(key: tid, on: false)
    }

    /// 子の turn が終わった（手がかりを外す）。外した payload と、行を終わらせた payload の両方は要らないので、終わらせた方を優先する。
    private mutating func dropChildTurn(_ tid: String, state: String, result: String?) -> [String] {
        childTurns.removeValue(forKey: tid)
        let dropped = tracker.setStopHandle(key: tid, on: false)
        return Self.list(tracker.finish(key: tid, state: state, result: result) ?? dropped)
    }

    /// thread/started（parentThreadId が自分の子 thread）。役割・ニックネームを種類にする。
    mutating func threadStarted(_ thread: [String: Any], ownThreadId: String?) -> [String] {
        guard let id = Self.string(thread["id"]), let parent = Self.string(thread["parentThreadId"]),
              parent == ownThreadId else { return [] }
        let type = Self.string(thread["agentRole"]) ?? Self.string(thread["agentNickname"])
        return beginChild(id, label: nil, agentType: type, model: nil)
    }

    /// 子 thread の行を始め、その子を覚えておく（行を忘れた後に話しかけ直されたときのため）。
    private mutating func beginChild(_ tid: String, label: String?, agentType: String?, model: String?) -> [String] {
        let known = knownChildren[tid]
        if known == nil {
            knownOrder.append(tid)
            if knownOrder.count > Self.knownChildLimit { knownChildren.removeValue(forKey: knownOrder.removeFirst()) }
        }
        knownChildren[tid] = (label ?? known?.label, agentType ?? known?.agentType, model ?? known?.model)
        return Self.list(tracker.begin(key: tid, label: label, agentType: agentType, model: model))
    }

    /// 子 thread の通知。行にしていない thread のものは捨てる。
    mutating func childNotification(method: String, params: [String: Any], threadId tid: String) -> [String] {
        guard tracker.contains(tid) else {
            // 終わって行を忘れた子（新しいターンの pruneFinished の後）が、後のターンで話しかけ直された（followup_task・
            // sendInput・resumeAgent）。子の turn/started で行を作り直す（見出し・種類・モデルは覚えておいたもの）。
            // 作り直さないと、カードにも SessionHub の「動いている作業」にも出ず、stdio では親の turn/completed で止めてしまう。
            guard method == "turn/started", let known = knownChildren[tid] else { return [] }
            return noteChildTurn(tid, Self.turnId(params),
                                 startPayloads: beginChild(tid, label: known.label, agentType: known.agentType, model: known.model))
        }
        let item = params["item"] as? [String: Any]
        switch method {
        case "item/started":
            guard let item else { return [] }
            switch Self.string(item["type"]) {
            case "commandExecution":
                return Self.list(tracker.activity(key: tid, text: "command: " + (Self.execCommand(item) ?? ""), toolCall: true))
            case "mcpToolCall":
                let name = [Self.string(item["server"]), Self.string(item["tool"])].compactMap { $0 }.joined(separator: ".")
                return Self.list(tracker.activity(key: tid, text: name, toolCall: true))
            case "fileChange":
                return Self.list(tracker.activity(key: tid, text: CodexFileChangeDiff.title(item) ?? "ファイル変更", toolCall: true))
            case "webSearch":
                return Self.list(tracker.activity(key: tid, text: "web search", toolCall: true))
            default:
                return []
            }
        case "item/completed":
            guard let item, Self.string(item["type"]) == "agentMessage", let text = Self.string(item["text"]) else { return [] }
            lastMessages[tid] = text
            return Self.list(tracker.activity(key: tid, text: text))
        case "thread/tokenUsage/updated":
            let total = (params["tokenUsage"] as? [String: Any])?["total"] as? [String: Any]
            return Self.list(tracker.activity(key: tid, text: nil, tokens: Self.int(total?["totalTokens"])))
        case "thread/status/changed":
            // systemError は子のターンの失敗（理由は直後の error と turn/completed(failed) で届く）。
            guard Self.string((params["status"] as? [String: Any])?["type"]) == "systemError" else { return [] }
            return Self.list(tracker.finish(key: tid, state: "failed", result: errors[tid]))
        case "error":
            let message = Self.string((params["error"] as? [String: Any])?["message"]) ?? Self.string(params["message"])
            // willRetry=true は再接続中（ターンは続く）。いまの作業として見せる。
            if params["willRetry"] as? Bool == true { return Self.list(tracker.activity(key: tid, text: message)) }
            if let message { errors[tid] = message }
            return Self.list(tracker.finish(key: tid, state: "failed", result: message))
        case "turn/started":
            // 話しかけ直された（followup_task 等）子は実行中に戻す。
            lastMessages[tid] = nil
            errors[tid] = nil
            return noteChildTurn(tid, Self.turnId(params), startPayloads: Self.list(tracker.begin(key: tid, label: nil)))
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let message = Self.lastAgentMessage(turn?["items"]) ?? lastMessages[tid]
            let error = Self.string((turn?["error"] as? [String: Any])?["message"]) ?? errors[tid]
            lastMessages[tid] = nil
            errors[tid] = nil
            switch Self.string(turn?["status"]) {
            case "failed": return dropChildTurn(tid, state: "failed", result: error)
            case "interrupted": return dropChildTurn(tid, state: "stopped", result: nil)
            default: return dropChildTurn(tid, state: "done", result: message)
            }
        default:
            return []
        }
    }

    /// collabAgentToolCall（v1: spawnAgent / wait 等）と subAgentActivity（v2: started / interacted / interrupted / completed）。
    /// collabAgentToolCall = { tool, status, receiverThreadIds, prompt, model, agentsStates: { threadId: { status, message } } }
    /// subAgentActivity    = { kind, agentThreadId, agentPath, model, reasoningEffort }（model と reasoningEffort は
    ///                       0.162.1 で増えた。started のときだけ入る）
    private mutating func subagentItem(_ item: [String: Any]) -> [String] {
        if item["type"] as? String == "subAgentActivity" {
            guard let tid = Self.string(item["agentThreadId"]) else { return [] }
            let path = Self.string(item["agentPath"]).flatMap { $0.split(separator: "/").last.map(String.init) }
            switch item["kind"] as? String {
            case "started":
                let model = Self.modelLabel(model: Self.string(item["model"]), effort: Self.string(item["reasoningEffort"]))
                return beginChild(tid, label: nil, agentType: path, model: model)
            case "interacted":
                // send_message（子のターンを起こさない）と followup_task の両方で来る。実行中には戻さない。
                return Self.list(tracker.activity(key: tid, text: Self.interactedActivity))
            case "interrupted":
                return Self.list(tracker.finish(key: tid, state: "stopped", result: nil))
            case "completed":
                return Self.list(tracker.finish(key: tid, state: "done", result: nil))
            default:
                return []
            }
        }
        var out: [String?] = []
        let receivers = (item["receiverThreadIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        switch Self.string(item["tool"]) {
        case "spawnAgent":
            for tid in receivers {
                out.append(beginChild(tid, label: Self.string(item["prompt"]), agentType: nil, model: Self.string(item["model"])).first)
            }
        case "wait":
            for tid in receivers { out.append(tracker.activity(key: tid, text: nil)) }
        default:
            break
        }
        for (tid, raw) in item["agentsStates"] as? [String: Any] ?? [:] {
            guard let state = raw as? [String: Any], tracker.contains(tid) else { continue }
            let message = Self.string(state["message"])
            switch Self.string(state["status"]) {
            case "completed", "shutdown":
                out.append(tracker.finish(key: tid, state: "done", result: message))
            case "interrupted":
                out.append(tracker.finish(key: tid, state: "stopped", result: message))
            case "errored", "notFound":
                out.append(tracker.finish(key: tid, state: "failed", result: message))
            default:
                if let message { out.append(tracker.activity(key: tid, text: message)) }
            }
        }
        return out.compactMap { $0 }
    }

    /// 行のモデル。reasoningEffort があれば「gpt-6-luna (medium)」の形で添える（行に努力度の項目は無い）。
    static func modelLabel(model: String?, effort: String?) -> String? {
        guard let model, !model.isEmpty else { return nil }
        guard let effort, !effort.isEmpty else { return model }
        return "\(model) (\(effort))"
    }

    /// 端末のコマンド。command はシェルの包み（/bin/zsh -lc '…'）付きなので、生のコマンド（commandActions[0].command）を優先する。
    static func execCommand(_ item: [String: Any]) -> String? {
        let raw = (item["commandActions"] as? [[String: Any]])?.first.flatMap { string($0["command"]) }
        return raw ?? string(item["command"])
    }

    /// 子 thread の今の turn id（turn/started の params.turn.id。無ければ params.turnId）。
    static func turnId(_ params: [String: Any]) -> String? {
        string((params["turn"] as? [String: Any])?["id"]) ?? string(params["turnId"])
    }

    /// 閉じた端末の行の状態。exitCode が 0 なら done、それ以外は failed（exitCode が無ければ status で決める）。
    /// stopped = アプリの停止で終わらせた端末（exitCode -1）は stopped。
    static func execState(_ item: [String: Any], stopped: Bool = false) -> String {
        if stopped { return "stopped" }
        if let code = int(item["exitCode"]) { return code == 0 ? "done" : "failed" }
        return ["failed", "declined"].contains(string(item["status"]) ?? "") ? "failed" : "done"
    }

    /// 端末の出力の終わりの方（行の結果。長い出力は頭より終わりの方が役に立つ）。SubagentTracker の上限（2000 字）に収める。
    static func outputTail(_ raw: Any?, limit: Int = 1990) -> String? {
        guard let s = raw as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > limit ? "…" + String(t.suffix(limit)) : t
    }

    private static func lastAgentMessage(_ raw: Any?) -> String? {
        let items = raw as? [[String: Any]] ?? []
        return items.last(where: { $0["type"] as? String == "agentMessage" }).flatMap { string($0["text"]) }
    }

    private static func processId(_ item: [String: Any]) -> String? {
        string(item["processId"]) ?? int(item["processId"]).map(String.init)
    }

    private static func list(_ payload: String?) -> [String] { payload.map { [$0] } ?? [] }

    /// 空でない文字列。
    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}
