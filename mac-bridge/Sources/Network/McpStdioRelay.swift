import Foundation

/// stdio の MCP サーバしか受け取れない ACP エージェント（hermes など。initialize で `mcpCapabilities.http` を申告しない）に、
/// mainagent の道具を渡すための中継。Bridge のバイナリを `BridgeApp mcp-stdio-relay` で起こすと、この中継だけが動く
/// （AppKit のアプリも Bridge のサーバも起こさず、`~/.buddyos` にも触らない）。
///
/// - stdin: MCP の stdio（改行区切りの JSON-RPC 1 件ずつ）。1 行ずつ `POST http://127.0.0.1:<port>/mcp` へ送る
///   （McpEndpoint は JSON で返し SSE を使わないので、応答の本文をそのまま 1 行で stdout に書く）。
/// - 通知（id 無し）には何も返さない（Bridge は 202）。クライアントからの応答（method 無し）は送らない（Bridge は要求を出さない）。
/// - Bridge に繋がらない・401（合鍵が無効）などは、要求の id で JSON-RPC の error を返す。
/// - stdin が閉じたら、送りかけの返事を少しだけ待って終わる。
///
/// 合鍵とポートは環境変数で受け取る（ACP の stdio の McpServer の `env`）。引数に載せると `ps` で見えるため。
/// `--terminal` を付けると、アプリ内ターミナルの claude 用に、合鍵（`~/.buddyos/main-mcp-token`）と
/// 待ち受けの番号（`~/.buddyos/bridge.port`）を要求のたびにファイルから読む（Bridge を起動し直しても切れない）。
final class McpStdioRelay: @unchecked Sendable {
    /// `BridgeApp <subcommand>` で中継として動く。
    static let subcommand = "mcp-stdio-relay"
    /// 合鍵（Bearer bmt_…）。Claude CLI に渡すのと同じ名前。
    static let tokenEnvVar = MainAgentWorkspace.tokenEnvVar
    /// Bridge の待ち受けの番号。
    static let portEnvVar = "BUDDYOS_MCP_PORT"
    /// ターミナルの claude 用（`.mcp.json` から起こされる）。
    static let terminalFlag = "--terminal"

    /// Bridge にもエージェントにも無い、中継が自分で返す error の code（JSON-RPC の server error の範囲）。
    static let unreachableCode = -32000
    static let unauthorizedCode = -32001

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// 送り先と合鍵。ターミナルの中継は要求のたびに読み直す（読めなければ nil = Bridge に繋がらない扱い）。
    typealias Target = @Sendable () -> (port: Int, token: String)?

    private let target: Target
    private let transport: Transport
    /// 要求に足すヘッダ（ターミナルの中継は claude の PID）。
    private let extraHeaders: [String: String]
    /// ターミナルの中継か（401 のときの案内を変える）。
    private let terminal: Bool

    init(port: Int, token: String, transport: Transport? = nil) {
        self.target = { (port, token) }
        self.transport = transport ?? Self.urlSessionTransport()
        self.extraHeaders = [:]
        self.terminal = false
    }

    /// ターミナルの中継。合鍵と番号は target が毎回読む。
    init(target: @escaping Target, claudePid: Int32, transport: Transport? = nil) {
        self.target = target
        self.transport = transport ?? Self.urlSessionTransport()
        self.extraHeaders = [MainAgentWorkspace.claudePidHeader: String(claudePid)]
        self.terminal = true
    }

    /// ターミナルの中継の target（BuddyPaths.root の main-mcp-token と bridge.port）。
    static func fileTarget(root: @escaping @Sendable () -> URL = { BuddyPaths.root }) -> Target {
        {
            let dir = root()
            guard let token = MainAgentWorkspace.terminalToken(url: dir.appendingPathComponent("main-mcp-token")),
                  let raw = try? String(contentsOf: dir.appendingPathComponent("bridge.port"), encoding: .utf8),
                  let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), (1...65535).contains(port)
            else { return nil }
            return (port, token)
        }
    }

    /// 道具の呼び出しは承認（5 分）と返事（5 分）を待つので、Bridge が黙っている間に切らない長さにする。
    private static func urlSessionTransport() -> Transport {
        let config = URLSessionConfiguration.ephemeral
        let limit = TimeInterval(MainAgentWorkspace.toolTimeoutSeconds + 60)
        config.timeoutIntervalForRequest = limit
        config.timeoutIntervalForResource = limit
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        return { req in try await session.data(for: req) }
    }

    // MARK: - 1 行の中継

    /// stdin の 1 行を Bridge へ送り、stdout に書く 1 行（改行は含まない）を返す。書くものが無ければ nil。
    func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let body = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: body) else {
            return Self.errorLine(id: NSNull(), code: -32700, message: "parse error")
        }
        // バッチ（配列）は MCP 2025-06-18 で無くなり、Bridge も受けない。
        guard let msg = parsed as? [String: Any] else {
            return Self.errorLine(id: NSNull(), code: -32600, message: "invalid request")
        }
        guard msg["method"] is String else { return nil }
        let id: Any? = msg["id"].flatMap { $0 is NSNull ? nil : $0 }

        guard let (port, token) = target() else {
            Self.log("合鍵か待ち受けの番号が読めない（BuddyOS が起動していない）")
            guard let id else { return nil }
            return Self.errorLine(id: id, code: Self.unreachableCode,
                                  message: "BuddyOS の Bridge が見つからない。BuddyOS のアプリが起動しているか確かめてください")
        }
        let endpoint = URL(string: MainAgentWorkspace.mcpURL(port: port))!
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let status: Int
        do {
            let (d, resp) = try await transport(req)
            data = d
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            Self.log("Bridge に繋がらない: \(error.localizedDescription)")
            guard let id else { return nil }
            return Self.errorLine(id: id, code: Self.unreachableCode,
                                  message: "BuddyOS の Bridge（\(endpoint.host ?? ""):\(endpoint.port ?? 0)）に繋がらない。Bridge が動いているか確かめてください")
        }

        switch status {
        case 200..<300:
            guard let id else { return nil }
            if let line = Self.oneLine(data) { return line }
            Self.log("Bridge の応答が JSON ではない（HTTP \(status)、\(data.count) バイト）")
            return Self.errorLine(id: id, code: -32603, message: "Bridge の応答が JSON ではない（HTTP \(status)）")
        case 401:
            Self.log("Bridge が合鍵を受け付けない（401）")
            guard let id else { return nil }
            return Self.errorLine(id: id, code: Self.unauthorizedCode,
                                  message: terminal
                                      ? "BuddyOS の Bridge が合鍵を受け付けない（401）。BuddyOS のアプリを起動し直してください"
                                      : "BuddyOS の Bridge が合鍵を受け付けない（401）。mainagent のセッションを開き直してください")
        default:
            Self.log("Bridge が HTTP \(status) を返した")
            guard let id else { return nil }
            return Self.errorLine(id: id, code: Self.unreachableCode, message: "BuddyOS の Bridge が HTTP \(status) を返した")
        }
    }

    /// 応答の本文を 1 行にする。JSON でなければ nil。改行を含まなければそのまま（含むなら詰めて書き直す）。
    static func oneLine(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if !data.contains(0x0A), !data.contains(0x0D), let s = String(data: data, encoding: .utf8) { return s }
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func errorLine(id: Any, code: Int, message: String) -> String {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else {
            return #"{"error":{"code":-32603,"message":"internal error"},"id":null,"jsonrpc":"2.0"}"#
        }
        return s
    }

    /// stderr へ（エージェントのログに残る）。合鍵は書かない。
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[buddyos-mcp-relay] \(message)\n".utf8))
    }

    // MARK: - ACP の McpServer（stdio）

    /// この Bridge のバイナリの場所（中継として起こす command）。テストは差し替える。
    nonisolated(unsafe) static var executableOverride: String?

    static var currentExecutable: String? {
        if let executableOverride { return executableOverride }
        guard let path = Bundle.main.executablePath else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// ACP の session/new・load の `mcpServers` の 1 件（stdio の形：name / command / args / env）。
    /// 合鍵とポートは `env` に入れ、`args` には載せない。
    static func acpServer(token: String, port: Int, executable: String) -> [String: Any] {
        [
            "name": MainAgentWorkspace.mcpServerName,
            "command": executable,
            "args": [subcommand],
            "env": [
                ["name": tokenEnvVar, "value": token],
                ["name": portEnvVar, "value": String(port)]
            ]
        ]
    }

    // MARK: - 中継として動く（BridgeApp の入口から）

    static func isInvocation(_ arguments: [String]) -> Bool {
        arguments.count >= 2 && arguments[1] == subcommand
    }

    /// stdin が閉じるまで中継して終わる。合鍵かポートが無ければ 64（EX_USAGE）で終わる。
    static func runAndExit(arguments: [String] = CommandLine.arguments,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
        // クライアントが先に消えても SIGPIPE で落ちず、書き込みの失敗として扱う。
        signal(SIGPIPE, SIG_IGN)
        if arguments.dropFirst(2).contains(terminalFlag) {
            // 親 = この中継を起こした claude（stdio の MCP は claude が直に起こす）。
            run(McpStdioRelay(target: fileTarget(), claudePid: getppid()))
        }
        guard let token = environment[tokenEnvVar], !token.isEmpty else {
            log("\(tokenEnvVar) が無い")
            exit(64)
        }
        guard let port = environment[portEnvVar].flatMap({ Int($0) }), (1...65535).contains(port) else {
            log("\(portEnvVar) が無いか正しくない")
            exit(64)
        }
        run(McpStdioRelay(port: port, token: token))
    }

    private static func run(_ relay: McpStdioRelay) -> Never {
        let out = LineWriter()
        let inFlight = DispatchGroup()
        // 要求は並べて送る（長い tools/call の間にも ping などへ答える）。JSON-RPC は id で対応するので順は問わない。
        while let line = readLine(strippingNewline: true) {
            inFlight.enter()
            Task.detached {
                if let reply = await relay.handle(line: line) { out.write(reply) }
                inFlight.leave()
            }
        }
        // stdin が閉じた = クライアントが終わった。送りかけの返事だけ少し待つ。
        _ = inFlight.wait(timeout: .now() + 5)
        exit(0)
    }

    /// stdout に 1 行ずつ書く（並べて動く返事が混ざらないように lock で守る）。書けなければクライアントはもういない。
    private final class LineWriter: @unchecked Sendable {
        private let lock = NSLock()

        func write(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            do {
                try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
            } catch {
                exit(0)
            }
        }
    }
}
