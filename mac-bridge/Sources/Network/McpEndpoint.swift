import Foundation
import Vapor

/// mainagent に渡す MCP サーバ（Streamable HTTP の最小構成）。`POST /mcp` に JSON-RPC を 1 件ずつ受け、
/// JSON で返す（SSE は使わない。GET は 405）。認証は Orchestrator の合鍵（Bearer）だけ。
/// 道具の実体は Orchestrator。
enum McpEndpoint {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func register(app: Application) {
        app.on(.POST, "mcp", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            let claudePid = req.headers.first(name: MainAgentWorkspace.claudePidHeader).flatMap { Int32($0) }
            guard let token = req.headers.bearerAuthorization?.token,
                  let caller = await Orchestrator.shared.caller(token: token, claudePid: claudePid) else {
                throw Abort(.unauthorized)
            }
            guard let buffer = req.body.data else { throw Abort(.badRequest) }
            guard let out = await respond(to: Data(buffer: buffer), caller: caller) else {
                return Response(status: .accepted)
            }
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: out))
        }
        app.on(.GET, "mcp") { _ async throws -> Response in Response(status: .methodNotAllowed) }
        app.on(.DELETE, "mcp") { _ async throws -> Response in Response(status: .methodNotAllowed) }
    }

    /// JSON-RPC 1 件への応答。通知（id 無し）なら nil（HTTP は 202）。
    static func respond(to body: Data, caller: Orchestrator.Caller) async -> Data? {
        guard let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = msg["method"] as? String else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        guard let id = msg["id"], !(id is NSNull) else { return nil }
        let params = msg["params"] as? [String: Any] ?? [:]
        func result(_ r: Any) -> Data? { encode(["jsonrpc": "2.0", "id": id, "result": r]) }
        func failure(_ code: Int, _ message: String) -> Data? {
            encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return result([
                "protocolVersion": asked.flatMap { protocolVersions.contains($0) ? $0 : nil } ?? protocolVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": MainAgentWorkspace.mcpServerName, "version": "1"],
                "instructions": "BuddyOS の Bridge が持つセッションを操作する道具。作業は start_session / send_message で頼み、get_reply で返事を受け取る。子が承認待ち（needs_approval）なら answer_approval で答えられる。別の PC のセッションは list_pcs で PC を選び、道具に pc を付けて扱う。覚えておくことは save_note で NOTES.md に残す。"
            ])
        case "ping":
            return result([String: Any]())
        case "tools/list":
            return result(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return failure(-32602, "name が無い") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let value = try await call(name, args: args, caller: caller)
                return result(["content": [["type": "text", "text": text(value)]], "isError": false])
            } catch let e as Orchestrator.ToolError {
                return result(["content": [["type": "text", "text": e.description]], "isError": true])
            } catch {
                return result(["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            return failure(-32601, "method not found: \(method)")
        }
    }

    static func call(_ name: String, args: [String: Any], caller: Orchestrator.Caller) async throws -> Any {
        let o = Orchestrator.shared
        func str(_ key: String) throws -> String {
            guard let v = args[key] as? String, !v.isEmpty else { throw Orchestrator.ToolError("\(key) が無い") }
            return v
        }
        func number(_ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
        if name == "list_pcs" {
            guard caller.remote == nil else { throw Orchestrator.ToolError("知らない道具: \(name)") }
            return await o.listPCs()
        }
        if name == "save_note" {
            // メインのメモ（~/.buddyos/main/NOTES.md）に 1 行足す。承認は要らない。別の PC・ふつうのセッションからは使えない。
            guard caller.remote == nil, caller.isMain else { throw Orchestrator.ToolError("save_note は mainagent のセッションだけが使える") }
            let line = try MainNotes.append(args["text"] as? String ?? "")
            return ["saved": line, "file": MainAgentWorkspace.notesURL.path]
        }
        // 別の PC。別の PC から頼まれた側（B）は、さらに別の PC へは回さない。
        if caller.remote == nil, Orchestrator.remoteToolNames.contains(name),
           let pc = try await o.resolvePC(args["pc"] as? String) {
            return try await o.callRemote(name, args: args, pc: pc, caller: caller)
        }
        switch name {
        case "list_projects":
            return await o.listProjects()
        case "list_agents":
            return await o.listAgents()
        case "list_sessions":
            return await o.listSessions(caller: caller)
        case "start_session":
            return try await o.startSession(caller: caller, agentId: (args["agent"] as? String) ?? "claude",
                                            cwd: try str("cwd"), prompt: try str("prompt"),
                                            mode: args["mode"] as? String, waitSeconds: number("wait_seconds") ?? 0)
        case "send_message":
            return try await o.sendMessage(caller: caller, agentId: try str("agent"),
                                           sessionId: try str("session_id"), text: try str("text"),
                                           waitSeconds: number("wait_seconds") ?? 0)
        case "get_reply":
            let wait = number("wait_seconds") ?? 60
            return try await o.getReplyChecked(caller: caller, agentId: try str("agent"),
                                               sessionId: try str("session_id"), waitSeconds: wait)
        case "answer_approval":
            return try await o.answerApproval(caller: caller, agentId: try str("agent"),
                                              sessionId: try str("session_id"), requestId: try str("request_id"),
                                              decision: try str("decision"))
        default:
            throw Orchestrator.ToolError("知らない道具: \(name)")
        }
    }

    // MARK: - 道具の定義

    /// `pc`（別の PC へ回す）を足した引数の形。list_pcs 以外の 7 つの道具に付く。
    private static func schema(_ props: [String: [String: Any]], required: [String]) -> [String: Any] {
        var all = props
        all["pc"] = ["type": "string",
                     "description": "別の PC で扱うときの PC（list_pcs の pc か name）。省略するとこの PC"]
        return ["type": "object", "properties": all, "required": required, "additionalProperties": false]
    }

    static let tools: [[String: Any]] = [
        [
            "name": "list_projects",
            "description": "登録されているプロジェクト（作業フォルダ）の名前とパス。どのプロジェクトの話かを決めるのに使う。",
            "inputSchema": schema([:], required: [])
        ],
        [
            "name": "list_agents",
            "description": "使えるエージェント（claude / codex / opencode など）と、入っているか・設定済みか。",
            "inputSchema": schema([:], required: [])
        ],
        [
            "name": "list_sessions",
            "description": "動いているセッションの一覧。agent / session_id / cwd / project / state（working=作業中、idle=待機、closed=閉じたが送れば開き直す）/ source（bridge=BuddyOS が起こした、terminal=ターミナルの Claude）。頼んだセッションには last_request / last_request_state（queued / running / needs_approval / done / error）と、承認待ちなら pending_approvals が付く。",
            "inputSchema": schema([:], required: [])
        ],
        [
            "name": "start_session",
            "description": "プロジェクトのフォルダで新しいセッションを起こし、最初の指示を送る。送る前にユーザーの承認を取る。返事は wait_seconds で待つか、get_reply で受け取る。",
            "inputSchema": schema([
                "agent": ["type": "string", "description": "エージェント ID（list_agents の agent）。省略時は claude"],
                "cwd": ["type": "string", "description": "作業フォルダの絶対パス（list_projects の path）"],
                "prompt": ["type": "string", "description": "最初の指示。目的・やること・やらないこと・終わりの条件・報告の形を書く"],
                "mode": ["type": "string", "enum": ["plan", "ask", "edit", "auto", "dangerous"],
                         "description": "子の権限モード（その agent での意味。claude の auto と codex の ask は毎回尋ねる、codex の auto は作業フォルダに尋ねずに書く）。mainagent のチャットで選んだモード（無ければ「毎回尋ねる」）より強くはならず、上限以下のモードを持たない agent は起こせない。省略時は上限以下で一番強いもの"],
                "wait_seconds": ["type": "number", "description": "そのまま返事を待つ秒数（0〜300、既定 0 = 待たない）"]
            ], required: ["cwd", "prompt"])
        ],
        [
            "name": "send_message",
            "description": "既存のセッションに指示を送る。送る前にユーザーの承認を取る。相手のモードが mainagent の上限より強ければ送らない。作業中なら今のターンの後に実行される。返事は wait_seconds で待つか、get_reply で受け取る。",
            "inputSchema": schema([
                "agent": ["type": "string"],
                "session_id": ["type": "string"],
                "text": ["type": "string", "description": "送る指示"],
                "wait_seconds": ["type": "number", "description": "そのまま返事を待つ秒数（0〜300、既定 0 = 待たない）"]
            ], required: ["agent", "session_id", "text"])
        ],
        [
            "name": "get_reply",
            "description": "セッションの返事を待って受け取る。status: running（作業中）/ queued（順番待ち）/ needs_approval（承認待ち。approval に request_id・title・summary・choices が付く。answer_approval で答えるか、ユーザーに開いてもらう）/ done / error / idle。reply が最後の返事。",
            "inputSchema": schema([
                "agent": ["type": "string"],
                "session_id": ["type": "string"],
                "wait_seconds": ["type": "number", "description": "終わるまで待つ秒数（0〜300、既定 60）。0 なら今の状態だけ見る"]
            ], required: ["agent", "session_id"])
        ],
        [
            "name": "list_pcs",
            "description": "頼める PC の一覧。self=true がこの PC、ほかは BuddyOS のデスクトップでつないでいる別の PC。ほかの道具に pc（pc か name）を付けると、その PC のプロジェクト・セッションを扱える（頼むときは承認カードに「PC: 名前」が出る）。",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String](), "additionalProperties": false]
        ],
        [
            "name": "answer_approval",
            "description": "子のセッションが待っている承認（get_reply の approval）に答える。deny はすぐ答える。allow / allow_for_session は、その前に BuddyOS がユーザーに承認を取る。mainagent のチャットのモードが上限で、計画（読むだけ）なら許可できない・allow_for_session は「編集は尋ねない」以上のときだけ・相手のモードが上限より強ければ答えない。何を許すのか分からないときは、答えずにユーザーに聞く。",
            "inputSchema": schema([
                "agent": ["type": "string"],
                "session_id": ["type": "string"],
                "request_id": ["type": "string", "description": "get_reply の approval.request_id"],
                "decision": ["type": "string", "enum": ["allow", "allow_for_session", "deny"],
                             "description": "allow = 一度だけ許可、allow_for_session = このセッションでは同種の操作を許可（選べるのは approval.choices にあるものだけ）、deny = 断る"]
            ], required: ["agent", "session_id", "request_id", "decision"])
        ],
        [
            "name": "save_note",
            "description": "覚えておくとよいこと（利用者の好み・続いている作業・決まったこと）を、メインのメモ（~/.buddyos/main/NOTES.md）の末尾に 1 行で残す。承認は要らない。前に残したことは NOTES.md を読めばわかる。",
            "inputSchema": [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "残すこと（\(MainNotes.maxChars) 文字まで。改行は空白になる）"]],
                "required": ["text"],
                "additionalProperties": false
            ] as [String: Any]
        ]
    ]

    // MARK: -

    private static func encode(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private static func text(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "\(value)" }
        return s
    }
}
