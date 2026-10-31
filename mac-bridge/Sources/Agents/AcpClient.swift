import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `<agent> acp` を spawn し、JSON-RPC over stdin/stdout を喋るクライアント。
///
/// Hermes / OpenClaw 共通の ACP 層。`executable` / `args` / `env` を constructor で
/// 受け取り、agent-specific な部分を adapter 側に逃がす。
///
/// 設計:
///  - 1 プロセス = 1 接続。複数 session は ACP の sessionId で多重化。
///  - request(_:params:) は jsonrpc id 付きで送って response を待つ。
///  - notifications は [String: Any] の AsyncSequence（AcpNotificationSequence）。AcpSession 側で
///    `session/update` 等を SessionEvent に翻訳する。
///  - エージェント発のリクエスト（method + id。`session/request_permission` 等）は
///    setRequestHandler(_:) のハンドラへ渡す。ハンドラは notifications を回す consumer 上で
///    通知と到着順に呼ぶ。引き受け手が無ければ -32601 を即返す。
final class AcpClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private let lock = NSLock()
    private var nextId: Int = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var didClose: Bool = false
    private var requestHandler: (@Sendable (AcpIncomingRequest) -> Bool)?
    /// stdin への書き込みはこの直列キューだけで行う（lock は握らない）。
    /// lock を握ったまま大きな行を書くと、エージェントが stdout の書き込みで詰まって stdin を読まない間、
    /// こちらの stdout 読み取り（feedStdout も同じ lock を取る）も止まり、互いに待ち合って固まる。
    /// stdin を閉じるのもこのキューの上で行うので、閉じた handle へ書いて落ちることはない。
    private let writeQueue = DispatchQueue(label: "buddyos.acp.stdin")

    /// 通知とハンドラ付きのエージェント発リクエストを到着順に積む。外へは notifications 経由で出す。
    private let notifContinuation: AsyncStream<[String: Any]>.Continuation
    private let inbound: AsyncStream<[String: Any]>
    /// session/update 等の通知。リクエストはここを回す consumer 上でハンドラへ渡し、要素には出さない。
    var notifications: AcpNotificationSequence { AcpNotificationSequence(base: inbound, client: self) }

    /// - Parameters:
    ///   - executable: agent CLI のフルパス (e.g. `/opt/homebrew/bin/hermes`)
    ///   - args: CLI に渡す引数 (e.g. `["acp"]`、openclaw なら `["acp", "--token-file", ...]`)
    ///   - env: zsh 起動時に export する環境変数 (e.g. Hermes は GLM_BASE_URL を固定)
    ///   - cwd: spawn するプロセスの作業ディレクトリ。nil なら親 (BridgeApp) を継承。
    ///     opencode の `session/list` は「プロセスの spawn cwd」で project scope されるため、
    ///     履歴プローブはここを chat の cwd に合わせる必要がある（既存呼び出しは nil = 無変更）。
    ///   - loginShell: env を渡すとき `zsh -lic` を経由するか。false なら親の環境に env を重ねて直接起動する
    ///     （.zshrc の読み込みで数秒かかるのを避ける。PATH 等を env で渡せる CLI 向け）。
    init(executable: String, args: [String], env: [String: String], cwd: String? = nil, loginShell: Bool = true) {
        var c: AsyncStream<[String: Any]>.Continuation!
        self.inbound = AsyncStream { cont in c = cont }
        self.notifContinuation = c

        // cwd 指定時は spawn プロセスの作業ディレクトリを固定する。
        // 存在しないパスを渡すと Process.run() が throw するため、実在ディレクトリのときだけ設定する。
        let effectiveCwd: String? = {
            guard let cwd, !cwd.isEmpty else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
            return cwd
        }()
        if let effectiveCwd {
            process.currentDirectoryURL = URL(fileURLWithPath: effectiveCwd)
        }

        if env.isEmpty || !loginShell {
            // 余計な `.zshrc` 読込み (数秒〜) を避けるため、env が空のときは直接起動する。
            // 親プロセス (BridgeApp) の env を継承するが、Clerk / MCP のトークンは外す（ChildEnvironment）。
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = ChildEnvironment.base(merging: env)
        } else {
            // env を export する必要があるときだけ zsh wrapper を経由する (Hermes の GLM_BASE_URL など)。
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // 注意: 閉包の戻り値は `-> String` を明示すること。モジュール内の別ファイルが
            // GRDB を import すると、コンパイラのimport漏れ(SR-3908)で文字列補間リテラルが
            // GRDB.SQL に推論され、コマンドが "SQL(elements:...)" になって spawn が壊れる実績あり。
            // `-lic` のログインシェルは profile で cd する場合があるため、cwd 指定時は
            // currentDirectoryURL に加えてコマンド先頭でも明示 cd して確実にする。
            let cdPrefix: String = effectiveCwd.map { c -> String in
                "cd '\(c.replacingOccurrences(of: "'", with: "'\\''"))'; "
            } ?? ""
            let envPrefix: String = env.map { key, value -> String in
                let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
                return "export \(key)='\(escaped)'; "
            }.joined()
            let argsJoined: String = args.map { arg -> String in
                "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }.joined(separator: " ")
            process.arguments = ["-lic", "\(cdPrefix)\(envPrefix)\(executable) \(argsJoined)"]
            process.environment = ChildEnvironment.base()
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    func start() throws {
        // blocking read だと Node.js wrapper との pipe で deadlock するため、readabilityHandler
        // ベースの非同期処理に変更する (kernel が available データを push する都度 callback)。
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                self?.close()
                return
            }
            self?.feedStdout(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let s = String(data: chunk, encoding: .utf8) {
                FileHandle.standardError.write(Data("[acp-stderr] \(s)".utf8))
            }
        }
        try process.run()
        // エージェントが死んだ後の書き込みで SIGPIPE にせず、EPIPE として throw させる。
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // 子プロセスを独自プロセスグループのリーダーにする。これで close 時に
        // グループごと kill すれば、wrapper が spawn した子孫 (openclaw → openclaw-acp 等)
        // も一括で終了でき、セッション切断後の orphan プロセス残留を防げる。
        // (既に execve 済みで失敗しても ESRCH/EACCES になるだけで害はない)
        let pid = process.processIdentifier
        if pid > 0 {
            _ = setpgid(pid, pid)
            // SIGKILL で bridge が死んだ場合に次回起動時の孤児掃除で回収できるよう記録する。
            SpawnRegistry.register(pid: pid, command: executableDescription)
        }
    }

    /// SpawnRegistry の記録用コマンドライン表現 (sweep 時の pid 再利用判定に使う)。
    private var executableDescription: String {
        (([process.executableURL?.path].compactMap { $0 }) + (process.arguments ?? []))
            .joined(separator: " ")
    }

    private var stdoutBuffer = Data()
    /// stdoutBuffer の先頭から、改行が無いと確かめ済みのバイト数。大きな行が細切れに届いたとき、
    /// 毎回先頭から探し直すと行の長さの 2 乗の手間になる（数 MB の行で数秒〜十数秒かかっていた）。
    private var stdoutScanned = 0

    /// 次の改行の位置。lock を握ったまま呼ぶ。
    private func nextStdoutNewline() -> Data.Index? {
        let from = stdoutBuffer.startIndex + stdoutScanned
        guard let index = stdoutBuffer[from...].firstIndex(of: 0x0A) else {
            stdoutScanned = stdoutBuffer.count
            return nil
        }
        return index
    }

    private func feedStdout(_ chunk: Data) {
        lock.lock()
        stdoutBuffer.append(chunk)
        while let nlIndex = nextStdoutNewline() {
            let lineData = stdoutBuffer.prefix(upTo: nlIndex)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nlIndex)
            stdoutScanned = 0
            lock.unlock()
            if !lineData.isEmpty {
                if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    handleMessage(obj)
                } else {
                    FileHandle.standardError.write(Data("[acp] parse fail: \(String(data: lineData, encoding: .utf8) ?? "?")\n".utf8))
                }
            }
            lock.lock()
        }
        lock.unlock()
    }

    // MARK: - JSON-RPC

    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        lock.lock()
        nextId += 1
        let id = nextId
        lock.unlock()

        // openclaw acp は JSON-RPC を line-streaming で読むため、key 順序 (jsonrpc → id →
        // method → params) を probe で動く順番に揃える。JSONSerialization は dict 順序が
        // 不定なので、手動で組み立てる。
        let paramsData = try JSONSerialization.data(withJSONObject: params, options: [])
        let paramsString = String(data: paramsData, encoding: .utf8) ?? "{}"
        let methodEscaped = method.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let lineString = "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(methodEscaped)\",\"params\":\(paramsString)}\n"
        let line = Data(lineString.utf8)

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: Any], Error>) in
            // didClose チェック・pending 登録・書き込みの予約は同一クリティカルセクションで行う
            // （予約の順が id の順になる）。書き込み自体は writeQueue の上で、lock の外で行う。
            // stdin を閉じるのも writeQueue の上なので、閉じた NSFileHandle への write で落ちることはない
            // （2026-06-12 実クラッシュ: _NSFileHandleIsClosed ← AcpClient.request）。
            lock.lock()
            if didClose {
                lock.unlock()
                c.resume(throwing: AcpError.processTerminated)
                return
            }
            pending[id] = c
            enqueueWrite(line) { [weak self] error in
                guard let self else { return }
                self.lock.lock()
                let cont = self.pending.removeValue(forKey: id)
                self.lock.unlock()
                cont?.resume(throwing: error)
            }
            lock.unlock()
        }
    }

    /// stdin への 1 行を writeQueue に積む。閉じた後に積まれた分は書かずに onError を呼ぶ。
    /// 呼び出し元のスレッドは待たせない（ロックを握ったままでも呼べる）。
    private func enqueueWrite(_ line: Data, onError: (@Sendable (Error) -> Void)? = nil) {
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let closed = self.didClose
            self.lock.unlock()
            if closed {
                onError?(AcpError.processTerminated)
                return
            }
            do {
                try handle.write(contentsOf: line)
            } catch {
                onError?(error)
            }
        }
    }

    func notify(_ method: String, params: [String: Any]) throws {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        var line = try JSONSerialization.data(withJSONObject: payload, options: [])
        line.append(0x0A)
        // 閉じた後は投げる。書き込みは request() と同じく writeQueue で行う。
        lock.lock()
        defer { lock.unlock() }
        if didClose { throw AcpError.processTerminated }
        enqueueWrite(line)
    }

    /// エージェント発リクエストのハンドラを登録する。引き受けたら true を返し、後で必ず
    /// respond(to:result:) / respondError(to:code:message:) で応答すること。
    /// notifications を回す consumer 上で、先に届いた通知の処理が済んでから同期で呼ばれる
    /// （承認カードが直前の本文やツールカードより先に出ないように）。ブロックすると後続の通知も
    /// 止まるので重い処理は Task へ。登録したら notifications を必ず回すこと（回さないと応答されない）。
    /// 未登録、または false を返したリクエストには -32601 (Method not found) を返す。
    func setRequestHandler(_ handler: @escaping @Sendable (AcpIncomingRequest) -> Bool) {
        lock.lock()
        requestHandler = handler
        lock.unlock()
    }

    /// エージェント発リクエストへの成功応答。`requestId` は受け取った id（Int / String）をそのまま渡す。
    func respond(to requestId: Any, result: [String: Any]) throws {
        let resultData = try JSONSerialization.data(withJSONObject: result, options: [])
        let body: String = "\"result\":" + String(decoding: resultData, as: UTF8.self)
        try writeResponse(id: requestId, body: body)
    }

    /// エージェント発リクエストへのエラー応答。
    func respondError(to requestId: Any, code: Int, message: String) throws {
        let errorData = try JSONSerialization.data(withJSONObject: ["code": code, "message": message], options: [])
        let body: String = "\"error\":" + String(decoding: errorData, as: UTF8.self)
        try writeResponse(id: requestId, body: body)
    }

    private func writeResponse(id: Any, body: String) throws {
        // id は受け取った型のまま返す（JSON-RPC の id は文字列も許される）。不正な値を
        // JSONSerialization に渡すと ObjC 例外で落ちるので先に検証する。
        guard JSONSerialization.isValidJSONObject([id]) else {
            throw AcpError.invalidResponse("invalid request id")
        }
        let idData = try JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed])
        let lineString: String = "{\"jsonrpc\":\"2.0\",\"id\":" + String(decoding: idData, as: UTF8.self) + "," + body + "}\n"
        let line = Data(lineString.utf8)
        // 閉じた後は投げる。書き込みは request() と同じく writeQueue で行う。
        lock.lock()
        defer { lock.unlock() }
        if didClose { throw AcpError.processTerminated }
        enqueueWrite(line)
    }

    func close() {
        lock.lock()
        if didClose { lock.unlock(); return }
        didClose = true
        let snapshot = pending
        pending.removeAll()
        lock.unlock()

        // stdin は writeQueue の上で閉じる（書きかけの行と競合させない）。書きかけの行が詰まっていても、
        // 下の SIGTERM でエージェントが終われば EPIPE で戻ってから閉じる。
        let stdinHandle = stdinPipe.fileHandleForWriting
        writeQueue.async { try? stdinHandle.close() }
        // プロセスグループ全体に SIGTERM。wrapper の子孫 (openclaw / openclaw-acp 等) も
        // まとめて終了させ orphan を残さない。グループ化に失敗していた場合は ESRCH に
        // なるだけで bridge 本体 (別グループ) には影響しない。
        let pid = process.processIdentifier
        if pid > 0 {
            kill(-pid, SIGTERM)
            SpawnRegistry.unregister(pid: pid)
        }
        if process.isRunning {
            process.terminate()
        }
        notifContinuation.finish()
        for (_, cont) in snapshot {
            cont.resume(throwing: AcpError.processTerminated)
        }
    }

    deinit {
        let pid = process.processIdentifier
        if process.isRunning {
            if pid > 0 { kill(-pid, SIGTERM) }
            process.terminate()
        }
    }

    // MARK: - Message handling

    private func handleMessage(_ msg: [String: Any]) {
        // method の有無で先に振り分ける。method + id はエージェント発のリクエスト、
        // method のみは通知、method 無しで id を持つものだけが自分の request への応答。
        // 旧実装は id があれば応答扱いしており、session/request_permission が黙って捨てられ
        // （Hermes は 60 秒止まって拒否）、エージェント側の採番（0 始まり）が pending 中の
        // session/prompt の id と衝突するとその turn が承認要求で完了扱いになっていた。
        if msg["method"] is String {
            lock.lock()
            let hasHandler = requestHandler != nil
            lock.unlock()
            if let req = AcpIncomingRequest(message: msg), !hasHandler {
                // 引き受け手が無ければ通知の処理を待たずに返す（notifications を回さない client もある）。
                respondMethodNotFound(req)
            } else {
                // リクエストも通知と同じストリームに到着順で積み、consumer 上でハンドラへ渡す。
                // readabilityHandler から直接呼ぶと、同じチャンクで先に届いた session/update
                // （本文やツールカード）より承認要求が先に iOS へ出ることがある。
                notifContinuation.yield(msg)
            }
        } else if let id = msg["id"] as? Int {
            lock.lock()
            let cont = pending.removeValue(forKey: id)
            lock.unlock()
            cont?.resume(returning: msg)
        }
    }

    /// AcpNotificationSequence の next() から、先に届いた通知の処理が済んだ後に呼ばれる。
    fileprivate func handleIncomingRequest(_ req: AcpIncomingRequest) {
        lock.lock()
        let handler = requestHandler
        lock.unlock()
        if let handler, handler(req) { return }
        respondMethodNotFound(req)
    }

    private func respondMethodNotFound(_ req: AcpIncomingRequest) {
        // 引き受け手の無いリクエストには -32601 を即返してエージェントを待たせない。
        // 呼び出し元は readabilityHandler か notifications の consumer なので、stdin への write は別キューで行う。
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.respondError(to: req.id, code: -32601, message: "Method not found: \(req.method)")
        }
    }
}

/// AcpClient.notifications の実体。通知はそのまま返し、エージェント発リクエストは次の要素を
/// 待つ前にハンドラへ渡して読み飛ばす。consumer が直前の通知を処理し終えてから next() が
/// 呼ばれるので、承認要求と先行する session/update の順序が保たれる。
struct AcpNotificationSequence: AsyncSequence {
    typealias Element = [String: Any]

    let base: AsyncStream<[String: Any]>
    let client: AcpClient

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncStream<[String: Any]>.Iterator
        let client: AcpClient

        mutating func next() async -> [String: Any]? {
            while let msg = await base.next() {
                guard let req = AcpIncomingRequest(message: msg) else { return msg }
                client.handleIncomingRequest(req)
            }
            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator(), client: client)
    }
}

/// エージェント → クライアント方向の JSON-RPC リクエスト（`session/request_permission` 等）。
/// `id` は Int / String どちらもありうるので、受け取った値のまま respond 系に渡して返す。
struct AcpIncomingRequest: @unchecked Sendable {
    let id: Any
    let method: String
    let params: [String: Any]
}

extension AcpIncomingRequest {
    /// method と（null 以外の）id を持つメッセージだけをリクエストとみなす。method のみは通知。
    init?(message msg: [String: Any]) {
        guard let method = msg["method"] as? String,
              let rawId = msg["id"], !(rawId is NSNull) else { return nil }
        self.init(id: rawId, method: method, params: (msg["params"] as? [String: Any]) ?? [:])
    }
}

enum AcpError: Error, LocalizedError {
    case processTerminated
    case invalidResponse(String)
    case rpcError(code: Int, message: String)
    case startTimeout

    var errorDescription: String? {
        switch self {
        case .processTerminated: return "acp process terminated"
        case .invalidResponse(let s): return "invalid acp response: \(s)"
        case .rpcError(let code, let msg): return "acp error \(code): \(msg)"
        case .startTimeout: return "acp failed to initialize"
        }
    }
}
