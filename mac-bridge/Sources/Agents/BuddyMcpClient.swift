import Foundation

/// buddy エージェント専用の MCP クライアント。
///
/// buddy は ACP プロセスを起動せず bridge 内で完結する「一級エージェント」のため、
/// MCP サーバとの通信もここで自前に行う（他エージェントは CLI が MCP を喋る）。
///
/// 接続先は `~/.buddyos/buddy-mcp.json` の `mcpServers`（Claude Code と同じ形式）。
/// ```json
/// { "mcpServers": {
///     "github": { "url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization":"Bearer ..."} },
///     "fs":     { "command": "npx", "args": ["-y","@modelcontextprotocol/server-filesystem","/tmp"] }
/// } }
/// ```
/// transport は url（Streamable HTTP）と command（stdio）の両対応。
///
/// MVP では tools/list と tools/call のみ使う（resources/prompts は未対応）。接続は
/// lazy に張り、セッション内で使い回す（buddy は「速度」が売りのため毎回 spawn しない）。
actor BuddyMcpClient {
    static let configPath = NSHomeDirectory() + "/.buddyos/buddy-mcp.json"

    struct Tool: Sendable {
        let name: String          // OpenRouter に渡す関数名（serverName を prefix して衝突回避）
        let rawName: String       // MCP サーバ上の素のツール名
        let serverName: String
        let description: String
        /// JSON Schema を JSON 文字列で保持（[String: Any] は Sendable でないため）。
        let inputSchemaJSON: String
    }

    private var connections: [String: BuddyMcpConnection] = [:]
    /// サーバ名 → ツール一覧。取得に成功したサーバだけを入れる（失敗したサーバは次の turn で取り直す）。
    private var toolCache: [String: [Tool]] = [:]

    /// 設定済みサーバ定義を読む。
    private static func loadServerDefs() -> [(name: String, def: [String: Any])] {
        guard let data = FileManager.default.contents(atPath: configPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { name, raw in
            guard let def = raw as? [String: Any] else { return nil }
            // enabled:false は除外（連携トグル OFF）。キー無しは有効扱い。
            if let enabled = def["enabled"] as? Bool, enabled == false { return nil }
            return (name, def)
        }.sorted { $0.name < $1.name }
    }

    private func connection(for serverName: String) -> BuddyMcpConnection? {
        if let c = connections[serverName] { return c }
        let defs = Self.loadServerDefs()
        guard let entry = defs.first(where: { $0.name == serverName }) else { return nil }
        let c = BuddyMcpConnection(serverName: serverName, def: entry.def)
        connections[serverName] = c
        return c
    }

    /// 全サーバの tools/list を集約して OpenRouter の tools 形式の素材を返す。
    /// 1 つでも応答すれば返す（落ちたサーバは黙ってスキップ）。サーバ単位でキャッシュあり。
    func listTools() async -> [Tool] {
        var all: [Tool] = []
        for entry in Self.loadServerDefs() {
            if let cached = toolCache[entry.name] { all += cached; continue }
            // interrupt / close 後は未取得のサーバを spawn しない。
            if Task.isCancelled { continue }
            let conn = connection(for: entry.name)
            guard let conn else { continue }
            // 失敗（タイムアウト・起動失敗・interrupt）したサーバはキャッシュせず、次の turn で取り直す。
            guard let tools = try? await conn.listTools() else { continue }
            var serverTools: [Tool] = []
            for t in tools {
                // 関数名は OpenRouter の `^[a-zA-Z0-9_-]+$` 制約に合わせ sanitize。
                let safe = Self.sanitize("\(entry.name)__\(t.name)")
                let schemaJSON = (try? JSONSerialization.data(withJSONObject: t.inputSchema))
                    .flatMap { String(data: $0, encoding: .utf8) }
                    ?? "{\"type\":\"object\",\"properties\":{}}"
                serverTools.append(Tool(
                    name: safe,
                    rawName: t.name,
                    serverName: entry.name,
                    description: t.description,
                    inputSchemaJSON: schemaJSON
                ))
            }
            toolCache[entry.name] = serverTools
            all += serverTools
        }
        return all
    }

    /// OpenRouter から来た関数名（serverName__rawName）でツールを実行する。
    func callTool(functionName: String, argumentsJSON: String) async -> (text: String, isError: Bool) {
        // 名前解決は取得済みのキャッシュから引く（listTools を呼ぶと、取得に失敗しているサーバを
        // ツール実行のたびに取り直してしまう）。キャッシュが空のときだけ取得する。
        var tools = toolCache.sorted { $0.key < $1.key }.flatMap { $0.value }
        if tools.isEmpty { tools = await listTools() }
        guard let tool = tools.first(where: { $0.name == functionName }) else {
            return ("ツール '\(functionName)' は見つかりませんでした。", true)
        }
        guard let conn = connection(for: tool.serverName) else {
            return ("MCP サーバ '\(tool.serverName)' に接続できません。", true)
        }
        let args: [String: Any] = {
            guard let data = argumentsJSON.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }()
        do {
            return try await conn.callTool(name: tool.rawName, arguments: args)
        } catch {
            return ("ツール実行に失敗しました: \(error.localizedDescription)", true)
        }
    }

    func shutdown() async {
        for (_, c) in connections { await c.close() }
        connections = [:]
        toolCache = [:]
    }

    private static func sanitize(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let mapped = s.map { allowed.contains($0) ? $0 : "_" }
        return String(mapped.prefix(60))
    }
}

/// 1 つの MCP サーバへの接続（stdio または Streamable HTTP）。
/// JSON-RPC 2.0。stdio は改行区切り JSON、HTTP は POST + (json | text/event-stream)。
actor BuddyMcpConnection {
    struct RawTool { let name: String; let description: String; let inputSchema: [String: Any] }

    private let serverName: String
    private let def: [String: Any]
    private var nextId = 1
    private var initialized = false

    // stdio
    private var process: Process?
    private var stdin: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var readSource: DispatchSourceRead?
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    /// spawn / 後始末のたびに進める世代番号。古いプロセスの残りチャンクや EOF 通知を無視するために使う。
    private var generation = 0

    // http
    private var httpSessionId: String?

    private var isHTTP: Bool { (def["url"] as? String)?.isEmpty == false }

    init(serverName: String, def: [String: Any]) {
        self.serverName = serverName
        self.def = def
    }

    func listTools() async throws -> [RawTool] {
        try await ensureInitialized()
        let result = try await request(method: "tools/list", params: [:])
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let desc = (t["description"] as? String) ?? ""
            let schema = (t["inputSchema"] as? [String: Any]) ?? ["type": "object", "properties": [:]]
            return RawTool(name: name, description: desc, inputSchema: schema)
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> (text: String, isError: Bool) {
        try await ensureInitialized()
        let result = try await request(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])
        let isError = (result["isError"] as? Bool) ?? false
        // content[] の text を連結。画像等は MVP では概要のみ。
        var text = ""
        if let content = result["content"] as? [[String: Any]] {
            for block in content {
                if let t = block["text"] as? String {
                    text += t
                } else if let type = block["type"] as? String {
                    text += "[\(type)]"
                }
            }
        }
        if text.isEmpty { text = isError ? "(error)" : "(no output)" }
        return (text, isError)
    }

    // MARK: - initialize

    private func ensureInitialized() async throws {
        // stdio: EOF を検知する前にプロセスが死んでいたら後始末し、再 spawn + initialize させる。
        if !isHTTP, let p = process, !p.isRunning { teardownStdio(error: BuddyMcpError.closed) }
        if initialized { return }
        let params: [String: Any] = [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "buddyos-bridge", "version": "1.0"]
        ]
        do {
            _ = try await request(method: "initialize", params: params)
            // initialized 通知（応答不要）
            try await notify(method: "notifications/initialized", params: [:])
        } catch {
            // initialize は 1 プロセスにつき 1 回だけ。stdio で失敗（タイムアウト・interrupt 含む）したら
            // プロセスごと捨て、次の試行は再 spawn から始める（同じプロセスへ 2 回目の initialize を送らない）。
            if !isHTTP { teardownStdio(error: BuddyMcpError.closed) }
            throw error
        }
        initialized = true
    }

    // MARK: - request dispatch

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextId; nextId += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        if isHTTP {
            return try await httpRequest(body: body, expectResult: true)
        } else {
            return try await stdioRequest(id: id, method: method, body: body)
        }
    }

    private func notify(method: String, params: [String: Any]) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if isHTTP {
            _ = try? await httpRequest(body: body, expectResult: false)
        } else {
            try writeStdio(body)
        }
    }

    // MARK: - HTTP (Streamable)

    private func httpRequest(body: [String: Any], expectResult: Bool) async throws -> [String: Any] {
        guard let urlStr = def["url"] as? String, let url = URL(string: urlStr) else {
            throw BuddyMcpError.badConfig("url 不正")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sid = httpSessionId { req.setValue(sid, forHTTPHeaderField: "Mcp-Session-Id") }
        if let headers = def["headers"] as? [String: String] {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { httpSessionId = sid }
            guard (200..<300).contains(http.statusCode) else {
                throw BuddyMcpError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
            let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if !expectResult { return [:] }
            if ctype.contains("text/event-stream") {
                return try Self.parseSSEResult(data)
            }
            return try Self.parseJSONResult(data)
        }
        if !expectResult { return [:] }
        return try Self.parseJSONResult(data)
    }

    private static func parseJSONResult(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BuddyMcpError.protocolError("JSON 解析失敗")
        }
        if let err = obj["error"] as? [String: Any] {
            throw BuddyMcpError.rpc((err["message"] as? String) ?? "RPC error")
        }
        return (obj["result"] as? [String: Any]) ?? [:]
    }

    /// SSE ボディから最後の data: 行（JSON-RPC レスポンス）を取り出す。
    private static func parseSSEResult(_ data: Data) throws -> [String: Any] {
        let text = String(data: data, encoding: .utf8) ?? ""
        var lastResult: [String: Any] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("data:") else { continue }
            let payload = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]",
                  let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw BuddyMcpError.rpc((err["message"] as? String) ?? "RPC error")
            }
            if let result = obj["result"] as? [String: Any] { lastResult = result }
        }
        return lastResult
    }

    // MARK: - stdio

    private func ensureProcess() throws {
        if process != nil { return }
        guard let cmd = def["command"] as? String, !cmd.isEmpty else {
            throw BuddyMcpError.badConfig("command 不正")
        }
        let args = (def["args"] as? [String]) ?? []
        let p = Process()
        // login shell 経由で PATH 解決（npx 等の解決のため）。
        let full = ([cmd] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", full]
        var env = ChildEnvironment.base()
        if let extra = def["env"] as? [String: String] { for (k, v) in extra { env[k] = v } }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // stderr は読まないので捨てる（読まない Pipe だと 64KB で詰まり、サーバが書き込みでブロックする）。
        p.standardError = FileHandle.nullDevice
        try p.run()
        let writer = inPipe.fileHandleForWriting
        // サーバ終了後の書き込みで SIGPIPE（Bridge ごと終了）にならず、EPIPE として throw させる。
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        generation += 1
        let gen = generation
        process = p
        stdin = writer
        stdoutBuffer = Data()

        // 改行区切り JSON を読み取り、id で pending を解決。
        // チャンクは 1 本の Task で到着順に ingest し、EOF の後始末は最後のチャンクの後に回す。
        let (stream, streamCont) = AsyncStream.makeStream(of: Data.self)
        stdoutContinuation = streamCont
        let fh = outPipe.fileHandleForReading
        let src = DispatchSource.makeReadSource(fileDescriptor: fh.fileDescriptor, queue: DispatchQueue.global())
        src.setEventHandler {
            let chunk = fh.availableData
            guard !chunk.isEmpty else {
                // EOF: 読める状態のまま発火し続けるので、ここで cancel して空転を止める。
                src.cancel()
                streamCont.finish()
                return
            }
            streamCont.yield(chunk)
        }
        src.resume()
        readSource = src
        Task { [weak self] in
            for await chunk in stream { await self?.ingest(chunk, generation: gen) }
            await self?.stdioDidClose(generation: gen)
        }
    }

    /// stdout の EOF（サーバ終了）。待機中の request を失敗させ、次回は再 spawn させる。
    private func stdioDidClose(generation gen: Int) {
        guard gen == generation else { return }
        teardownStdio(error: BuddyMcpError.closed)
    }

    /// stdio 接続の後始末（EOF・プロセス死亡・close 共通、何度呼んでも安全）。
    /// pending は取り出して空にしてから resume する（二重 resume 防止）。
    private func teardownStdio(error: Error) {
        generation += 1
        readSource?.cancel()
        readSource = nil
        stdoutContinuation?.finish()
        stdoutContinuation = nil
        try? stdin?.close()
        stdin = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        stdoutBuffer = Data()
        initialized = false
        let conts = pending
        pending = [:]
        for (_, c) in conts { c.resume(throwing: error) }
    }

    private func ingest(_ chunk: Data, generation gen: Int) {
        guard gen == generation else { return }  // 後始末済みの古いプロセスの残りは捨てる
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard let idNum = obj["id"] as? Int else { continue }  // 通知は無視
            guard let cont = pending.removeValue(forKey: idNum) else { continue }
            if let err = obj["error"] as? [String: Any] {
                cont.resume(throwing: BuddyMcpError.rpc((err["message"] as? String) ?? "RPC error"))
            } else {
                cont.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
            }
        }
    }

    /// stdio request の応答待ち上限（秒）。initialize は npx の初回取得、tools/call はツール実行時間を見込んで長め。
    private static func stdioTimeout(for method: String) -> TimeInterval {
        switch method {
        case "initialize": return 60
        case "tools/call": return 180
        default: return 30
        }
    }

    private func stdioRequest(id: Int, method: String, body: [String: Any]) async throws -> [String: Any] {
        // キャンセル済みなら spawn しない（interrupt / close の後に誰も閉じないプロセスを残さない）。
        try Task.checkCancellation()
        try ensureProcess()
        // 応答が来ないまま永久に待たないよう、interrupt（Task.cancel）でも解放できるようにする。
        return try await withTaskCancellationHandler {
            try await awaitStdioResponse(id: id, method: method, body: body)
        } onCancel: {
            Task { [weak self] in await self?.failPending(id: id, error: CancellationError()) }
        }
    }

    private func awaitStdioResponse(id: Int, method: String, body: [String: Any]) async throws -> [String: Any] {
        let timeout = Self.stdioTimeout(for: method)
        return try await withCheckedThrowingContinuation { cont in
            if Task.isCancelled {
                cont.resume(throwing: CancellationError())
                return
            }
            pending[id] = cont
            do {
                try writeStdio(body)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.failPending(id: id, error: BuddyMcpError.timeout(method))
            }
        }
    }

    /// タイムアウト・キャンセル時に該当 id だけ失敗させる（応答済みなら何もしない）。
    private func failPending(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func writeStdio(_ body: [String: Any]) throws {
        // spawn は stdioRequest 側だけで行う（後始末後に initialize 抜きで新プロセスへ書かないため）。
        guard let stdin = self.stdin else { throw BuddyMcpError.closed }
        var data = try JSONSerialization.data(withJSONObject: body)
        data.append(0x0A)
        // 旧 API の write(_:) は EPIPE で ObjC 例外になり catch できないため、throw 版を使う。
        try stdin.write(contentsOf: data)
    }

    func close() {
        teardownStdio(error: BuddyMcpError.closed)
    }
}

enum BuddyMcpError: Error, LocalizedError {
    case badConfig(String)
    case http(Int, String)
    case rpc(String)
    case protocolError(String)
    case closed
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .badConfig(let m): return "MCP 設定エラー: \(m)"
        case .http(let code, _): return "MCP HTTP \(code)"
        case .rpc(let m): return m
        case .protocolError(let m): return m
        case .closed: return "接続が閉じられました"
        case .timeout(let m): return "MCP サーバの応答がタイムアウトしました（\(m)）"
        }
    }
}
