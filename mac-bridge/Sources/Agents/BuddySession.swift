import Foundation

/// buddy の 1 セッション。OpenRouter chat completions（ストリーミング + tools）を回し、
/// MCP ツール呼び出しは **default-deny の承認ゲート**を通してから実行する。
///
/// 高速応答が売りのため ACP プロセスは起動せず、bridge 内で OpenRouter を直接叩く。
final class BuddySession: AgentSession {
    let sessionId: String
    let events: AsyncThrowingStream<SessionEvent, Error>

    private let agentId = "buddy"
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private let model: String
    private let apiKey: String
    private let mcp = BuddyMcpClient()

    private let lock = NSLock()
    /// OpenRouter 形式の会話履歴（[role, content, tool_calls, tool_call_id ...]）。
    private var messages: [[String: Any]] = []
    private var didEmitSessionStarted: Bool
    /// 承認待ちの解決先（requestId → decision を返す continuation）。
    private var pendingApprovals: [String: CheckedContinuation<String, Never>] = [:]
    /// このセッションで「続けて許可」されたツール関数名。
    private var sessionAllowed: Set<String> = []
    /// turn を直列化するためのチェーン末尾と、中断用の現在 turn。
    private var tail: Task<Void, Never>?
    private var currentTurn: Task<Void, Never>?

    private let maxToolRounds = 8
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(sessionId: String?, model: String, apiKey: String, systemPrompt: String) {
        self.sessionId = sessionId ?? UUID().uuidString
        self.model = model
        self.apiKey = apiKey
        self.didEmitSessionStarted = sessionId != nil
        var cont: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { c in cont = c }
        self.continuation = cont
        if !systemPrompt.isEmpty {
            self.messages.append(["role": "system", "content": systemPrompt])
        }
        // 再接続（sessionId 指定）なら保存済みの会話を読み戻して文脈を引き継ぐ。
        // system prompt は常に最新を先頭に置き、その後ろに保存済みの会話を続ける。
        if let sessionId {
            self.messages.append(contentsOf: BuddyHistoryStore.load(sessionId: sessionId))
        }
    }

    // MARK: - AgentSession

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        // turn を直列実行（前の turn 完了を待ってから走る）。
        let prev = tail
        let task = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            let turn = Task { await self.runTurn(text: text, attachments: attachments) }
            self.lock.lock(); self.currentTurn = turn; self.lock.unlock()
            await turn.value
        }
        lock.lock(); tail = task; lock.unlock()
    }

    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {
        lock.lock()
        let cont = pendingApprovals.removeValue(forKey: requestId)
        lock.unlock()
        cont?.resume(returning: decision)
    }

    func interrupt() async {
        lock.lock()
        let turn = currentTurn
        lock.unlock()
        // 先に cancel してから承認待ちを解放する。逆順だと再開した runTurn が isCancelled を
        // すり抜けて次の tool_call の approve() に入り、空にした後の pendingApprovals で永久に待つ。
        turn?.cancel()
        // 承認待ちを全て decline で解放してループを抜けさせる。
        lock.lock()
        let conts = Array(pendingApprovals.values)
        pendingApprovals = [:]
        lock.unlock()
        for c in conts { c.resume(returning: "decline") }
    }

    func close() async {
        await interrupt()
        await mcp.shutdown()
        continuation.finish()
    }

    // MARK: - Agent loop

    private func runTurn(text: String, attachments: [BridgeAttachment]) async {
        emitSessionStartedIfNeeded()
        // done はターンにつき必ず 1 回だけ出す。中断で途中終了した経路でも出さないと hub が
        // generating のまま残り、2 回出すと hub が予約キューを余分に dispatch してしまう。
        var doneEmitted = false
        defer {
            if !doneEmitted {
                continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: UUID().uuidString))
            }
        }
        guard !apiKey.isEmpty else {
            emitError("OpenRouter API キーが未設定です。BuddyOS プランに登録するか ~/.hermes/.env に OPENROUTER_API_KEY を設定してください。")
            doneEmitted = true
            return
        }

        appendMessage(["role": "user", "content": text])

        // MCP ツールを OpenRouter の tools 形式へ。
        let mcpTools = await mcp.listTools()
        let toolsPayload: [[String: Any]] = mcpTools.map { t in
            let parameters: [String: Any] = (t.inputSchemaJSON.data(using: .utf8))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                ?? ["type": "object", "properties": [:]]
            return [
                "type": "function",
                "function": [
                    "name": t.name,
                    "description": t.description,
                    "parameters": parameters
                ]
            ]
        }

        var round = 0
        while round < maxToolRounds {
            if Task.isCancelled { break }
            round += 1
            let messageId = UUID().uuidString
            let result: StreamResult
            do {
                result = try await streamCompletion(tools: toolsPayload, messageId: messageId)
            } catch let cancelled as StreamCancelled {
                // 表示済みの途中までの本文は（tool_calls を付けずに）履歴へ残す。残さないと
                // 中断後に「続けて」と送ってもモデルが自分の途中の回答を知らない。
                if !cancelled.partialText.isEmpty {
                    appendMessage(["role": "assistant", "content": cancelled.partialText])
                }
                break
            } catch {
                // 中断によるキャンセルはエラー表示せず、defer の done で静かに終える。
                if Self.isCancellation(error) {
                    break
                }
                emitError("応答の取得に失敗しました: \(error.localizedDescription)")
                doneEmitted = true
                break
            }

            if result.toolCalls.isEmpty {
                // 最終応答。
                appendMessage(["role": "assistant", "content": result.text])
                // done より前に保存する（SessionHub は done の時点で購読者が 0 なら即 close する）。
                // snapshotMessages() は lock 下でコピーを返すので、ファイル I/O は lock の外。
                BuddyHistoryStore.save(snapshotMessages(), sessionId: sessionId)
                continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
                doneEmitted = true
                return
            }

            // assistant の tool_calls メッセージを履歴へ。
            appendMessage([
                "role": "assistant",
                "content": result.text,
                "tool_calls": result.toolCalls.map { tc in
                    [
                        "id": tc.id,
                        "type": "function",
                        "function": ["name": tc.name, "arguments": tc.arguments]
                    ]
                }
            ])

            // 各ツールを承認ゲート経由で実行。
            for (i, tc) in result.toolCalls.enumerated() {
                if Task.isCancelled {
                    appendInterruptedToolResults(result.toolCalls[i...].map { $0.id })
                    break
                }
                let decision = await approve(toolFunctionName: tc.name, arguments: tc.arguments)
                // 承認待ち中の中断（decline で解放される）や承認直後の中断では実行しない。
                if Task.isCancelled {
                    appendInterruptedToolResults(result.toolCalls[i...].map { $0.id })
                    break
                }
                let toolUseId = tc.id
                continuation.yield(.toolStart(
                    agentId: agentId, sessionId: sessionId, toolUseId: toolUseId,
                    toolName: tc.name, title: tc.name, kind: "other"
                ))
                let toolOutput: String
                let status: String
                // 承認（accept / acceptForSession）のときだけ実行する。知らない値や空は拒否扱い（fail-closed）。
                if !Self.isApproved(decision) {
                    toolOutput = "ユーザーがこの操作の実行を拒否しました。"
                    status = "failed"
                } else {
                    let (txt, isErr) = await mcp.callTool(functionName: tc.name, argumentsJSON: tc.arguments)
                    toolOutput = txt
                    status = isErr ? "failed" : "completed"
                }
                continuation.yield(.toolEnd(
                    agentId: agentId, sessionId: sessionId, toolUseId: toolUseId,
                    toolName: tc.name, status: status,
                    summary: String(toolOutput.prefix(120)), durationMs: nil
                ))
                appendMessage([
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "content": toolOutput
                ])
            }
            // 次ラウンドへ（ツール結果を踏まえて再度モデルに問う）。
        }

        if round >= maxToolRounds && !doneEmitted && !Task.isCancelled {
            let mid = UUID().uuidString
            continuation.yield(.assistantDelta("（ツール呼び出しの上限に達しました）", agentId: agentId, sessionId: sessionId, messageId: mid))
            BuddyHistoryStore.save(snapshotMessages(), sessionId: sessionId)
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: mid))
            doneEmitted = true
        }
    }

    /// 中断で実行しなかった tool_call にも tool メッセージを返す。OpenAI 互換 API は
    /// 全 tool_call_id への応答を要求するため、欠けると以降のリクエストが全て 400 になる。
    private func appendInterruptedToolResults(_ toolCallIds: [String]) {
        for id in toolCallIds {
            appendMessage([
                "role": "tool",
                "tool_call_id": id,
                "content": "ユーザーが中断したため実行しませんでした。"
            ])
        }
    }

    // MARK: - Approval gate (default-deny)

    /// iPhone の答えが「実行してよい」か。accept / acceptForSession 以外（decline・空・未知の値）は実行しない。
    static func isApproved(_ decision: String) -> Bool {
        decision == "accept" || decision == "acceptForSession"
    }

    private func approve(toolFunctionName: String, arguments: String) async -> String {
        lock.lock()
        if sessionAllowed.contains(toolFunctionName) {
            lock.unlock()
            return "accept"
        }
        lock.unlock()

        let requestId = UUID().uuidString
        let meta: [String: String] = [
            "requestId": requestId,
            "kind": "toolApproval",
            "option_count": "3",
            "option_0_title": "承認",
            "option_0_subtitle": "一度だけ許可",
            "option_0_value": "accept",
            "option_1_title": "このセッションでは承認",
            "option_1_subtitle": "同じツールを続けて許可",
            "option_1_value": "acceptForSession",
            "option_2_title": "非承認",
            "option_2_subtitle": "実行しない",
            "option_2_value": "decline",
            "allowsOther": "0"
        ]
        let argPreview = arguments.count > 160 ? String(arguments.prefix(160)) + "…" : arguments
        continuation.yield(.actionRequest(
            agentId: agentId,
            sessionId: sessionId,
            messageId: requestId,
            title: "ツール「\(toolFunctionName)」を実行しますか",
            subtitle: argPreview.isEmpty ? nil : argPreview,
            metadata: meta
        ))

        let decision = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            lock.lock()
            // withCheckedContinuation はキャンセルに反応しない。interrupt() が pendingApprovals を
            // 空にした後に登録すると永久に待つため、lock 下で中断済みなら即 decline で返す。
            if Task.isCancelled {
                lock.unlock()
                cont.resume(returning: "decline")
                return
            }
            pendingApprovals[requestId] = cont
            lock.unlock()
        }
        if decision == "acceptForSession" {
            lock.lock(); sessionAllowed.insert(toolFunctionName); lock.unlock()
        }
        return decision
    }

    // MARK: - OpenRouter streaming

    private struct ToolCallAccum {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""
    }
    private struct StreamResult {
        let text: String
        let toolCalls: [(id: String, name: String, arguments: String)]
    }
    /// ストリーム受信中の中断。それまでに受信した本文（tool_calls は含めない）を運ぶ。
    private struct StreamCancelled: Error {
        let partialText: String
    }

    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func streamCompletion(tools: [[String: Any]], messageId: String) async throws -> StreamResult {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Referer は配布物の既定か BUDDYOS_OPENROUTER_REFERER（無ければ付けない）。
        if let referer = BridgeConfig.current.openRouterReferer.value {
            req.setValue(referer, forHTTPHeaderField: "HTTP-Referer")
        }
        req.setValue("BuddyOS", forHTTPHeaderField: "X-Title")

        var body: [String: Any] = [
            "model": model,
            "messages": snapshotMessages(),
            "stream": true
        ]
        if !tools.isEmpty { body["tools"] = tools }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // エラーボディを読み切る。
            var errText = ""
            for try await line in bytes.lines { errText += line }
            throw BuddyMcpError.http(http.statusCode, errText)
        }

        var text = ""
        var toolAccum: [Int: ToolCallAccum] = [:]

        do {
            for try await line in bytes.lines {
                // 中断時は break で途中までの tool_calls（arguments が壊れている）を返さず throw する。
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let choice = choices.first,
                      let delta = choice["delta"] as? [String: Any] else { continue }

                if let chunk = delta["content"] as? String, !chunk.isEmpty {
                    text += chunk
                    continuation.yield(.assistantDelta(chunk, agentId: agentId, sessionId: sessionId, messageId: messageId))
                }
                if let tcs = delta["tool_calls"] as? [[String: Any]] {
                    for tc in tcs {
                        let idx = (tc["index"] as? Int) ?? 0
                        var acc = toolAccum[idx] ?? ToolCallAccum()
                        if let id = tc["id"] as? String, !id.isEmpty { acc.id = id }
                        if let fn = tc["function"] as? [String: Any] {
                            if let name = fn["name"] as? String, !name.isEmpty { acc.name = name }
                            if let args = fn["arguments"] as? String { acc.arguments += args }
                        }
                        toolAccum[idx] = acc
                    }
                }
            }
        } catch {
            // 中断（checkCancellation / 受信待ち中の URLError.cancelled）では tool_calls だけ捨て、
            // iOS に表示済みの本文は呼び出し側が履歴に残せるよう StreamCancelled で運ぶ。
            if Self.isCancellation(error) { throw StreamCancelled(partialText: text) }
            throw error
        }

        let toolCalls = toolAccum
            .sorted { $0.key < $1.key }
            .map { $0.value }
            .filter { !$0.name.isEmpty }
            .map { (id: $0.id.isEmpty ? UUID().uuidString : $0.id, name: $0.name, arguments: $0.arguments.isEmpty ? "{}" : $0.arguments) }

        return StreamResult(text: text, toolCalls: toolCalls)
    }

    // MARK: - State helpers

    private func appendMessage(_ m: [String: Any]) {
        lock.lock(); messages.append(m); lock.unlock()
    }
    private func snapshotMessages() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
    private func emitSessionStartedIfNeeded() {
        lock.lock()
        let need = !didEmitSessionStarted
        didEmitSessionStarted = true
        lock.unlock()
        if need {
            continuation.yield(.sessionStarted(agentId: agentId, sessionId: sessionId))
        }
    }
    private func emitError(_ message: String) {
        let mid = UUID().uuidString
        continuation.yield(SessionEvent(
            type: .error, agentId: agentId, sessionId: sessionId,
            messageId: mid, toolUseId: nil, content: message, toolName: nil, metadata: nil
        ))
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: mid))
    }
}
