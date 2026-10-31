import Foundation

// ---------------------------------------------------------------------------
// Claude Code の `--permission-prompt-tool stdio`（SDK ホスト用の制御プロトコル）
//
// `claude -p --input-format stream-json` は、このフラグ無しだと承認が要る場面で何も尋ねずに
// 自動拒否する（stdout に system/permission_denied が出るだけ。実測 2026-10-01、2.1.285）。
// 付けると stdout に次の 1 行が出て、返事が来るまで待つ:
//
//   {"type":"control_request","request_id":"<uuid>","request":{"subtype":"can_use_tool",
//     "tool_name":"Bash","input":{...},"permission_suggestions":[...],"tool_use_id":"..."}}
//
// 返事は stdin に 1 行:
//
//   {"type":"control_response","response":{"subtype":"success","request_id":"<uuid>",
//     "response":{"behavior":"allow","updatedInput":{...}}}}      許可（updatedInput は元の input）
//   {"type":"control_response","response":{"subtype":"success","request_id":"<uuid>",
//     "response":{"behavior":"deny","message":"..."}}}            拒否（message は Claude に伝わる）
//
// 許可で実行され、拒否で実行されず理由が Claude に渡ることを実機で確認した。
// `allow` に `updatedPermissions`（permission_suggestions の要素）を付けると同種の操作を続けて許可できる。
// suggestions の destination は既定で localSettings（プロジェクトの settings.local.json に書き込まれる）なので、
// iPhone の「このセッションでは承認」では session に付け替える。
//
// 逆向き（Bridge → claude）の制御要求もある。停止は stdin に次の 1 行を書く（実測 2026-10-21、2.1.300。
// cancel_queued は CLI のスキーマから。知らない版は無視する）:
//
//   {"type":"control_request","request_id":"<uuid>","request":{"subtype":"interrupt","cancel_queued":true}}
//
// stdout に返事が出る。ターン中なら、その後に result{subtype:"error_during_execution"} でターンが閉じ、プロセスは生き続ける:
//
//   {"type":"control_response","response":{"subtype":"success","request_id":"<uuid>","response":{"still_queued":[]}}}
//
// プロセスを起こしたら、最初の user 行より前に initialize を 1 行書く（実測 2026-10-21、2.1.300）。perTaskStopAffordance を
// 宣言すると、interrupt は背景のサブエージェント・コマンド・dynamic workflow を止めなくなり、行ごとの停止（stop_task）が使える。
// 返事は約 21 KB でアカウントのメールと pid を含むので、subtype だけを見て中身はどこにも出さない。古い CLI は error を返す:
//
//   {"type":"control_request","request_id":"<uuid>","request":{"subtype":"initialize","perTaskStopAffordance":true}}
//
// stop_task は task_id の task を 1 つ止める。送る id は task_started の task_id（CLI の内部の id）そのもの。
// 知らない id・止まった後の id にも success を返すので、止まったかは task_updated / task_notification で見る。
// 古い CLI は error「Unsupported control request subtype: stop_task」:
//
//   {"type":"control_request","request_id":"<uuid>","request":{"subtype":"stop_task","task_id":"<task_id>"}}
//   {"type":"control_response","response":{"subtype":"success","request_id":"<uuid>","response":{}}}
// ---------------------------------------------------------------------------
enum ClaudeControlProtocol {
    struct ToolRequest {
        let requestId: String
        let toolName: String
        let input: [String: Any]
        let suggestions: [[String: Any]]
        /// 背景のサブエージェントからの要求なら、その agent_id。main の要求は nil。
        var agentId: String? = nil
    }

    /// こちらが書いた制御要求（interrupt など）への返事。
    struct Response {
        let requestId: String
        /// subtype が success か（error なら要求は通っていない）
        let success: Bool
        let body: [String: Any]
        let error: String?

        /// interrupt の返事: 中断を生き延びて、まだ走る発話の uuid（cancel_queued を知らない古い CLI では待ち行列の全部）。
        var stillQueued: [String] { (body["still_queued"] as? [Any])?.compactMap { $0 as? String } ?? [] }
    }

    enum Line {
        case canUseTool(ToolRequest)
        /// Claude 側が要求を取り下げた（ツール呼び出しが中断された等）。カードを閉じる。
        case cancel(requestId: String)
        /// 対応していない制御要求。返事をしないと Claude が待ち続けるので、エラーで返す。
        case unsupported(requestId: String, subtype: String)
        /// こちらが書いた制御要求への返事。
        case response(Response)
    }

    /// stdout の 1 行が制御行ならパースして返す。普通の行（本文の差分など）は JSON を読まずに nil。
    static func parse(_ line: String) -> Line? {
        guard line.contains("\"control_request\"") || line.contains("\"control_cancel_request\"")
                || line.contains("\"control_response\"") else { return nil }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        if type == "control_response" {
            // request_id は response の中にある。
            guard let r = obj["response"] as? [String: Any], let requestId = r["request_id"] as? String else { return nil }
            return .response(Response(
                requestId: requestId,
                success: r["subtype"] as? String == "success",
                body: r["response"] as? [String: Any] ?? [:],
                error: r["error"] as? String
            ))
        }
        guard let requestId = obj["request_id"] as? String else { return nil }
        switch type {
        case "control_cancel_request":
            return .cancel(requestId: requestId)
        case "control_request":
            let request = obj["request"] as? [String: Any] ?? [:]
            let subtype = request["subtype"] as? String ?? ""
            guard subtype == "can_use_tool", let tool = request["tool_name"] as? String else {
                return .unsupported(requestId: requestId, subtype: subtype)
            }
            return .canUseTool(ToolRequest(
                requestId: requestId,
                toolName: tool,
                input: request["input"] as? [String: Any] ?? [:],
                suggestions: request["permission_suggestions"] as? [[String: Any]] ?? [],
                agentId: (request["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ))
        default:
            return nil
        }
    }

    // MARK: - iPhone に出すカード

    /// 承認カード。選択肢の value は respondToAction の decision に入ってくる。
    static func approvalCard(_ r: ToolRequest, agentId: String, sessionId: String) -> SessionEvent {
        var meta: [String: String] = [
            "requestId": r.requestId,
            "kind": "approval",
            "allowsOther": "0",
        ]
        var options: [(title: String, subtitle: String, value: String)] = [
            ("承認", "一度だけ許可", "allow")
        ]
        // 同種の操作を続けて許可できるのは、Claude が候補（permission_suggestions）を出したときだけ。
        if !r.suggestions.isEmpty {
            options.append(("このセッションでは承認", "同種の操作を続けて許可", "allowForSession"))
        }
        options.append(("非承認", "実行しない", "deny"))
        meta["option_count"] = String(options.count)
        for (i, o) in options.enumerated() {
            meta["option_\(i)_title"] = o.title
            meta["option_\(i)_subtitle"] = o.subtitle
            meta["option_\(i)_value"] = o.value
        }
        return .actionRequest(
            agentId: agentId, sessionId: sessionId, messageId: r.requestId,
            title: "「\(r.toolName)」を実行しますか？",
            subtitle: summary(toolName: r.toolName, input: r.input),
            metadata: meta
        )
    }

    /// AskUserQuestion（Claude が選択肢つきで質問してくる）。
    /// 全部の質問は questions_json で渡す（新しい iOS / デスクトップは全問・複数選択を出す）。
    /// option_N_* は最初の質問だけ（全問を出せない古いクライアント向け）。
    static func questionCard(_ r: ToolRequest, agentId: String, sessionId: String) -> SessionEvent? {
        let qs = questions(in: r.input)
        guard !qs.isEmpty else { return nil }
        var meta = questionMetadata(qs)
        meta["requestId"] = r.requestId
        return .actionRequest(
            agentId: agentId, sessionId: sessionId, messageId: r.requestId,
            title: (qs[0]["header"] as? String) ?? "選択してください",
            subtitle: qs[0]["question"] as? String,
            metadata: meta
        )
    }

    /// ExitPlanMode（計画を見せて、実装に進んでよいか聞いてくる）。計画は全文を plan に載せる。
    /// 「直してほしい」は自由記述（Other）で受け、その文を添えて差し戻す。
    static func planCard(_ r: ToolRequest, agentId: String, sessionId: String) -> SessionEvent {
        let plan = (r.input["plan"] as? String) ?? ""
        var meta: [String: String] = [
            "requestId": r.requestId,
            "kind": "plan",
            "plan": plan,
            "allowsOther": "1",
            "otherPlaceholder": "直してほしいところ",
        ]
        let options: [(String, String, String)] = [
            ("この計画で進める", "計画を承認して実装に進みます", "allow"),
            ("計画を続ける", "まだ実装に進みません", "deny"),
        ]
        meta["option_count"] = String(options.count)
        for (i, o) in options.enumerated() {
            meta["option_\(i)_title"] = o.0
            meta["option_\(i)_subtitle"] = o.1
            meta["option_\(i)_value"] = o.2
        }
        return .actionRequest(
            agentId: agentId, sessionId: sessionId, messageId: r.requestId,
            title: "この計画で進めますか？",
            subtitle: summary(toolName: "ExitPlanMode", input: r.input),
            metadata: meta
        )
    }

    static func questions(in input: [String: Any]) -> [[String: Any]] {
        input["questions"] as? [[String: Any]] ?? []
    }

    /// 質問カードの metadata（kind / allowsOther / questions_json / 最初の質問の option_N_*）。
    /// requestId は呼び元が足す。Claude の AskUserQuestion と Codex の requestUserInput で共通。
    static func questionMetadata(_ qs: [[String: Any]], allowsOther: Bool = true) -> [String: String] {
        var meta: [String: String] = [
            "kind": "userInput",
            "allowsOther": allowsOther ? "1" : "0",
            "questions_json": questionsJSON(qs),
        ]
        let first = qs.first ?? [:]
        let options = (first["options"] as? [[String: Any]]) ?? []
        meta["option_count"] = String(options.count)
        if (first["multiSelect"] as? Bool) == true { meta["multiSelect"] = "1" }
        for (i, option) in options.enumerated() {
            let label = (option["label"] as? String) ?? "Option \(i + 1)"
            meta["option_\(i)_title"] = label
            meta["option_\(i)_subtitle"] = (option["description"] as? String) ?? ""
            meta["option_\(i)_value"] = label
        }
        return meta
    }

    /// 全部の質問をクライアント向けの形（id / question / header / multiSelect / options[label, description]）に揃えた JSON。
    /// id は答えのキー（Claude は質問文、Codex は質問 id）。
    static func questionsJSON(_ qs: [[String: Any]]) -> String {
        let out: [[String: Any]] = qs.enumerated().map { i, q in
            let question = (q["question"] as? String) ?? ""
            let options: [[String: Any]] = ((q["options"] as? [[String: Any]]) ?? []).enumerated().map { j, o in
                ["label": (o["label"] as? String) ?? "Option \(j + 1)", "description": (o["description"] as? String) ?? ""]
            }
            return [
                "id": (q["id"] as? String) ?? (question.isEmpty ? "q\(i)" : question),
                "question": question,
                "header": (q["header"] as? String) ?? "",
                "multiSelect": (q["multiSelect"] as? Bool) ?? false,
                "options": options,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// クライアントが返した answers_json（{ 質問 id: 文字列 | [文字列] }）。複数選択は ", " でつなぐ
    /// （Claude Code のターミナルが答えを見せる形と同じ）。無ければ空。
    static func parsedAnswers(_ meta: [String: String]) -> [String: String] {
        guard let raw = meta["answers_json"], let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let a = v as? [Any] { out[k] = a.compactMap { $0 as? String }.joined(separator: ", ") }
        }
        return out
    }

    /// 質問の答え。キーは質問文（SDK の AskUserQuestion の形式）。
    /// answers_json（全問の答え）→ 質問文をキーにした explicit（旧クライアントの Other）→ decision の順に使う。
    static func answers(for questions: [[String: Any]], decision: String, explicit: [String: String]) -> [String: String] {
        let all = parsedAnswers(explicit)
        var out: [String: String] = [:]
        for q in questions {
            let key = (q["question"] as? String) ?? (q["header"] as? String) ?? "answer"
            out[key] = all[key] ?? explicit[key] ?? decision
        }
        return out
    }

    /// カードの 2 行目に出す、何を実行しようとしているかの要約。
    static func summary(toolName: String, input: [String: Any], limit: Int = 300) -> String {
        func str(_ key: String) -> String? {
            guard let s = input[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        let text: String
        switch toolName {
        case "Bash":
            text = str("command") ?? "シェルコマンドを実行"
        case "Write", "Edit", "MultiEdit", "Read", "NotebookEdit":
            text = str("file_path") ?? str("path") ?? str("notebook_path") ?? jsonText(input)
        case "WebFetch":
            text = str("url") ?? jsonText(input)
        case "WebSearch":
            text = str("query") ?? jsonText(input)
        case "ExitPlanMode":
            text = str("plan") ?? "計画を承認して実装に進みます"
        default:
            text = jsonText(input)
        }
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func jsonText(_ input: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: - Claude への返事（stdin に 1 行で書く）

    static func allowResponse(requestId: String, input: [String: Any], updatedPermissions: [[String: Any]]? = nil) -> [String: Any] {
        var body: [String: Any] = ["behavior": "allow", "updatedInput": input]
        if let updatedPermissions, !updatedPermissions.isEmpty { body["updatedPermissions"] = updatedPermissions }
        return success(requestId: requestId, body)
    }

    static func denyResponse(requestId: String, message: String) -> [String: Any] {
        success(requestId: requestId, ["behavior": "deny", "message": message])
    }

    static func errorResponse(requestId: String, message: String) -> [String: Any] {
        ["type": "control_response", "response": ["subtype": "error", "request_id": requestId, "error": message]]
    }

    /// 今のターンを止める（プロセスは残す）。iPhone の停止は全部を止めるので、待ち行列の発話も取り消す
    /// （cancel_queued。取り消した発話には command_lifecycle cancelled が出る。知らない古い CLI は無視して still_queued に残す）。
    static func interruptRequest(requestId: String) -> [String: Any] {
        ["type": "control_request", "request_id": requestId,
         "request": ["subtype": "interrupt", "cancel_queued": true] as [String: Any]]
    }

    /// プロセスを起こした直後に 1 度だけ書く。行ごとの停止（stop_task）を使うことを CLI に宣言する。
    static func initializeRequest(requestId: String) -> [String: Any] {
        ["type": "control_request", "request_id": requestId,
         "request": ["subtype": "initialize", "perTaskStopAffordance": true] as [String: Any]]
    }

    /// task を 1 つ止める（サブエージェント・背景のシェル・dynamic workflow）。taskId は CLI の task_id。
    static func stopTaskRequest(requestId: String, taskId: String) -> [String: Any] {
        ["type": "control_request", "request_id": requestId,
         "request": ["subtype": "stop_task", "task_id": taskId] as [String: Any]]
    }

    private static func success(requestId: String, _ body: [String: Any]) -> [String: Any] {
        ["type": "control_response", "response": ["subtype": "success", "request_id": requestId, "response": body]]
    }

    /// 「このセッションでは承認」用。候補の保存先を session に付け替える
    /// （既定の localSettings だと、プロジェクトの .claude/settings.local.json に許可が残ってしまう）。
    static func sessionScoped(_ suggestions: [[String: Any]]) -> [[String: Any]] {
        suggestions.map { s in
            var copy = s
            copy["destination"] = "session"
            return copy
        }
    }
}
