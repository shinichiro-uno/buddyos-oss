import Foundation

// ---------------------------------------------------------------------------
// ターミナルの Codex と iPhone で同じ会話を共有するための、常駐 app-server
//
// Codex の app-server は 1 プロセスに複数の接続がぶら下がれて、同じ thread を
// resume した接続すべてに turn/item/delta の通知が流れる（実測 2026-09-24）。
// ターミナル側は `codex --remote ws://…`（buddy-codex）で、Bridge 側は
// CodexAppServerSession がここへ WebSocket で繋ぐ。どちらから turn/start しても
// 両方にリアルタイムで流れるので、Claude のような hooks + channel は要らない。
//
// - 待ち受けは 127.0.0.1 のみ。capability-token 必須（無いと接続が拒否される。実測）
// - トークンは ~/.buddyos/codex-app-server.token（0600）。buddy-codex も同じものを読む。
//   app-server を起動するたびに作り直す（漏れても次の起動で使えなくなる）
// - 固定ポートなので、先に別のユーザーやアプリが待ち受けていると、トークンと会話が偽のサーバーに渡る。
//   トークンを送る前に、待ち受けているのが自分の uid の app-server（serverPids）かを lsof で確かめる
//   （/readyz は認証なしで誰でも 200 を返せるので、それだけでは信用しない）
// - Bridge の子にはせず nohup で切り離す。Bridge 再起動でターミナル側が切れないように
// - 起動できなければ nil を返し、呼び出し側は従来の stdio app-server に倒す
// - BUDDYOS_CODEX_SHARED=0 で無効化
// - app-server は起動時のモデル一覧を持ち続け、再読込の API も無い（model/list は古いまま。
//   2026-09-25 に gpt-6-luna / gpt-6-sol が増えたのに、前日起動の app-server は 400 を返した）。
//   20 分ごとと「model is not supported」エラー時に `codex debug models` と比べ、増えていれば
//   ターミナル接続も進行中のターンも無いときに再起動する
// - 再起動の条件の「ターミナル接続」は台帳に加えて lsof でソケットを直接見る。Bridge 自身の接続は数えない
//   （意図した停止なので CodexAppServerSession 側で静かに畳み、次の送信で繋ぎ直す）
// - ターンの後も動いているサブエージェント（子 thread）とバックグラウンドの端末がある間も再起動しない（道連れになる）
// - 起動できなかったら 5 分は spawn しない（Codex を開くたびに 10 秒待たせないため）
// ---------------------------------------------------------------------------

struct CodexSharedEndpoint: Sendable {
    let url: URL
    let token: String
}

actor CodexSharedAppServer {
    static let shared = CodexSharedAppServer()

    static let port = 47620
    static let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".buddyos/codex-app-server.token")
    static let logPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".buddyos/codex-app-server.log").path

    private var starting: Task<CodexSharedEndpoint?, Never>?
    private var executable: String?
    private var environment: [String: String]?
    private var watchTask: Task<Void, Never>?
    private var checking = false
    private static let freshnessInterval: UInt64 = 20 * 60 * 1_000_000_000
    /// 最初の確認までの待ち。ターミナル台帳は中継の送り直し（15 秒ごと）でしか埋まらないので、
    /// Bridge 再起動直後は台帳の TTL（45 秒）が過ぎるまで空でも信用しない。
    private static let startupDelay: UInt64 = 50 * 1_000_000_000
    private static let registrySettle: TimeInterval = 45
    /// この actor の生成時刻。最初の Codex セッションを開いた時刻なので、Bridge の起動より後。
    private let createdAt = Date()
    /// 起動できなかった時刻と、そのときの executable。この間は spawn もポーリングもしない。
    private var lastFailure: (at: Date, executable: String)?
    private static let failureCooldown: TimeInterval = 5 * 60
    /// 起動し直しても app-server が知らないままだったモデル。同じ差分で再起動を繰り返さない
    /// （`codex debug models` と model/list で名前が違うモデルなど。20 分ごとに接続を切り続けないように）。
    /// 起動直後の一覧の取得失敗など一時的な理由のこともあるので、記録した時刻から期限付きで覚える。
    /// 実際に弾かれた（model not supported）ときは短い期限で試し直す。
    private var unresolvedModels: (ids: Set<String>, at: Date) = ([], .distantPast)
    private static let unresolvedTTL: TimeInterval = 3 * 60 * 60
    private static let unresolvedRejectedTTL: TimeInterval = 10 * 60

    /// Bridge が意図して共有 app-server を止めた時刻（モデル一覧の鮮度のための再起動）。
    private static let stopLock = NSLock()
    nonisolated(unsafe) private static var lastIntentionalStop: Date?

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["BUDDYOS_CODEX_SHARED"] != "0"
    }

    /// 直近（30 秒以内）に Bridge が意図して共有 app-server を止めたか。CodexAppServerSession が
    /// 共有サーバーとの切断を、エラーとして iPhone に出さずに静かに畳むかどうかの判定に使う。
    static func stoppedIntentionallyRecently() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard let at = lastIntentionalStop else { return false }
        return Date().timeIntervalSince(at) < 30
    }

    private static func markIntentionalStop() {
        stopLock.lock()
        lastIntentionalStop = Date()
        stopLock.unlock()
    }

    /// 動いていればそのまま、止まっていれば起動して返す。起動できなければ nil。
    func ensureRunning(executable: String, environment: [String: String]) async -> CodexSharedEndpoint? {
        guard Self.isEnabled else { return nil }
        self.executable = executable
        self.environment = environment
        startWatchIfNeeded()
        if let task = starting {
            // 進行中の起動・再起動を待つ。
            return await task.value
        }
        // 直近に起動できなかったなら、しばらくは spawn も 10 秒のポーリングもせずに stdio に倒す。
        // 手で起動した・buddy-codex が起動した app-server はすぐ使えるよう、ready かどうかだけは見る。
        // codex を差し替えた（executable が変わった）ときは待たずに試し直す。
        if let failure = lastFailure, failure.executable == executable,
           Date().timeIntervalSince(failure.at) < Self.failureCooldown {
            guard await Self.isOwnServerReady(), let token = Self.loadOrCreateToken() else { return nil }
            lastFailure = nil
            return CodexSharedEndpoint(url: URL(string: "ws://127.0.0.1:\(Self.port)")!, token: token)
        }
        let task = Task { await Self.start(executable: executable, environment: environment) }
        starting = task
        let result = await task.value
        starting = nil
        lastFailure = result == nil ? (at: Date(), executable: executable) : nil
        return result
    }

    private static func start(executable: String, environment: [String: String]) async -> CodexSharedEndpoint? {
        if await isReady() {
            // 動いている。自分の app-server でなければトークンを渡さない（stdio に倒す）。
            guard listenerIsOwn() else {
                WebSocketServer.wslog("codex-shared port \(port) is held by another process; not sending the token")
                return nil
            }
            guard let token = loadOrCreateToken() else { return nil }
            return CodexSharedEndpoint(url: URL(string: "ws://127.0.0.1:\(port)")!, token: token)
        }
        // これから起動する app-server 用に、トークンを作り直す（起動ごとに変える）。
        guard let token = rotateToken() else { return nil }
        var endpoint = CodexSharedEndpoint(url: URL(string: "ws://127.0.0.1:\(port)")!, token: token)

        // nohup + & で Bridge から切り離す。ポートを他が取っていれば bind に失敗して終わるだけ。
        // $! で pid を受け取り、落ちたら（bind 失敗・--ws-auth 非対応など）ポーリングを打ち切る。
        let cmd = "nohup \(shellQuote(executable)) app-server --listen ws://127.0.0.1:\(port)"
            + " --ws-auth capability-token --ws-token-file \(shellQuote(tokenURL.path))"
            + " >> \(shellQuote(logPath)) 2>&1 < /dev/null & echo $!"
        guard let r = ProcessRunner.run("/bin/sh", ["-c", cmd], timeout: 5, environment: environment,
                                        currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path),
              !r.timedOut, r.status == 0 else {
            WebSocketServer.wslog("codex-shared spawn failed")
            return nil
        }
        let pid = Int32(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))

        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if await isReady() {
                guard listenerIsOwn() else {
                    WebSocketServer.wslog("codex-shared port \(port) is held by another process; not sending the token")
                    return nil
                }
                WebSocketServer.wslog("codex-shared app-server started on :\(port)")
                // 同時に buddy-codex が作り直していることがあるので、使うのはファイルの最新の値。
                if let current = loadOrCreateToken() { endpoint = CodexSharedEndpoint(url: endpoint.url, token: current) }
                return endpoint
            }
            if let pid, kill(pid, 0) != 0 {
                // 自分の app-server は落ちた。同時に別の起動（buddy-codex）が上がっていればそれを使う。
                if await isOwnServerReady(), let current = loadOrCreateToken() {
                    return CodexSharedEndpoint(url: endpoint.url, token: current)
                }
                break
            }
        }
        WebSocketServer.wslog("codex-shared app-server did not become ready (log: \(logPath))")
        return nil
    }

    /// 止めて起動し直す。起動と同じ枠（starting）に載せ、その間に来た ensureRunning は完了を待たせる。
    private func restart(executable: String) async -> CodexSharedEndpoint? {
        guard starting == nil else { return nil }
        let task = Task { () -> CodexSharedEndpoint? in
            Self.markIntentionalStop()
            Self.stopServer()
            for _ in 0..<20 {
                if await !Self.isReady() { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return await Self.start(executable: executable, environment: CodexAppServerSession.spawnEnvironment())
        }
        starting = task
        let result = await task.value
        starting = nil
        lastFailure = result == nil ? (at: Date(), executable: executable) : nil
        return result
    }

    /// 再起動すると切れる相手がいれば、その内訳を返す（nil なら再起動してよい）。
    /// Bridge 自身の接続は数えない（切れても CodexAppServerSession が静かに畳み、次の送信で繋ぎ直す）。
    /// ターンの後も動いているサブエージェント（子 thread）とバックグラウンドの端末は数える（再起動すると道連れになる）。
    private func restartBlocker() async -> String? {
        let terminals = await CodexTerminalRegistry.shared.liveEntries().count
        let generating = await SessionHub.shared.generatingSessionIds(agentId: "codex").count
        let background = CodexAppServerSession.sharedBackgroundWork()
        let clients = Self.externalClientCount()
        // lsof で見られなければ台帳だけが頼り。Bridge 起動直後の空の台帳は信用しない。
        let settled = clients != nil || Date().timeIntervalSince(createdAt) >= Self.registrySettle
        if terminals == 0, generating == 0, background.agents == 0, background.shells == 0,
           (clients ?? 0) == 0, settled { return nil }
        return "terminals=\(terminals) clients=\(clients.map { "\($0)" } ?? "?") generating=\(generating)"
            + " subagents=\(background.agents) shells=\(background.shells)"
    }

    // MARK: - モデル一覧の鮮度

    private func startWatchIfNeeded() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            // 最初の 1 回は起動直後に（Bridge より前から動いている app-server が古いことがある）。
            try? await Task.sleep(nanoseconds: Self.startupDelay)
            await self?.checkFreshness(reason: "startup")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.freshnessInterval)
                await self?.checkFreshness(reason: "periodic")
            }
        }
    }

    /// 新しいモデルが出ていて、共有 app-server がまだ知らなければ再起動する。
    /// ターミナル（buddy-codex）が繋がっている間・Bridge のターンが進行中・子 thread や裏の端末が動いている間は
    /// 再起動しない（切れるため）。
    func checkFreshness(reason: String) async {
        guard !checking, let executable, let environment else { return }
        checking = true
        defer { checking = false }
        guard await Self.isOwnServerReady(), let token = Self.loadOrCreateToken() else { return }
        let fresh = Self.freshModelIds(executable: executable, environment: environment)
        guard !fresh.isEmpty else { return }
        let endpoint = CodexSharedEndpoint(url: URL(string: "ws://127.0.0.1:\(Self.port)")!, token: token)
        guard let served = await Self.serverModelIds(endpoint) else { return }
        let ttl = reason == "model not supported" ? Self.unresolvedRejectedTTL : Self.unresolvedTTL
        let unresolved = Date().timeIntervalSince(unresolvedModels.at) < ttl ? unresolvedModels.ids : []
        let missing = fresh.subtracting(served).subtracting(unresolved)
        guard !missing.isEmpty else { return }

        if let blocker = await restartBlocker() {
            WebSocketServer.wslog("codex-shared stale models \(missing.sorted()) (\(reason)); restart deferred \(blocker)")
            return
        }
        guard starting == nil else { return }
        WebSocketServer.wslog("codex-shared restarting for new models \(missing.sorted()) (\(reason))")
        guard let restarted = await restart(executable: executable),
              let after = await Self.serverModelIds(restarted) else { return }
        unresolvedModels = (fresh.subtracting(after), Date())
        if !unresolvedModels.ids.isEmpty {
            WebSocketServer.wslog("codex-shared models still missing after restart \(unresolvedModels.ids.sorted()); not retrying for these for a while")
        }
    }

    /// `codex debug models` の slug 一覧（ログイン中のアカウントで今使えるもの）。
    static func freshModelIds(executable: String, environment: [String: String]) -> Set<String> {
        let args = ["debug", "models"]
        let r = executable.hasPrefix("/")
            ? ProcessRunner.run(executable, args, timeout: 10, environment: environment)
            : ProcessRunner.run("/usr/bin/env", [executable] + args, timeout: 10, environment: environment)
        guard let r, !r.timedOut, r.status == 0,
              let root = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return [] }
        return Set(rows.compactMap { ($0["slug"] as? String) ?? ($0["id"] as? String) })
    }

    /// 動いている app-server が知っているモデル（model/list, hidden 込み）。
    static func serverModelIds(_ endpoint: CodexSharedEndpoint) async -> Set<String>? {
        var req = URLRequest(url: endpoint.url)
        req.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: req)
        ws.maximumMessageSize = 16 * 1024 * 1024
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        func call(_ id: Int, _ method: String, _ params: [String: Any]) async throws -> [String: Any]? {
            let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
            try await ws.send(.string(String(decoding: data, as: UTF8.self)))
            while true {
                let msg = try await ws.receive()
                guard case .string(let text) = msg,
                      let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                if (obj["id"] as? Int) == id { return obj["result"] as? [String: Any] }
            }
        }

        let work = Task { () -> Set<String>? in
            _ = try await call(1, "initialize", [
                "clientInfo": ["name": "buddyos-probe", "title": "BuddyOS", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try await ws.send(.string("{\"method\":\"initialized\"}"))
            let result = try await call(2, "model/list", ["includeHidden": true])
            let rows = result?["data"] as? [[String: Any]] ?? []
            return Set(rows.compactMap { $0["id"] as? String })
        }
        let timeout = Task { try? await Task.sleep(nanoseconds: 8_000_000_000); work.cancel(); ws.cancel() }
        defer { timeout.cancel() }
        return try? await work.value
    }

    /// 待ち受けている app-server（node ラッパーと本体の両方）を止める。
    private static func stopServer() {
        for pid in serverPids() {
            kill(pid, SIGTERM)
        }
    }

    /// 待ち受けている app-server（node ラッパーと本体の両方）の pid。自分の uid のものだけ
    /// （別のユーザーのプロセスを止めたり、自分のものと取り違えたりしない）。
    private static func serverPids() -> [Int32] {
        guard let r = ProcessRunner.run("/usr/bin/pgrep", ["-U", "\(getuid())", "-f", "app-server --listen ws://127.0.0.1:\(port)"], timeout: 3),
              let out = String(data: r.stdout, encoding: .utf8) else { return [] }
        return out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    /// ポートを待ち受けているのが、自分の uid で動く app-server（serverPids）だけか。lsof で確かめられなければ false。
    static func listenerIsOwn() -> Bool {
        guard let r = ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpu"], timeout: 5),
              !r.timedOut, r.status == 0 else { return false }
        let listeners = parseListeners(String(decoding: r.stdout, as: UTF8.self))
        return listenersAreOwn(listeners, uid: getuid(), serverPids: Set(serverPids()))
    }

    /// `lsof -Fpu` の出力（p<pid> と u<uid> の行）を (pid, uid) の組にする。
    static func parseListeners(_ output: String) -> [(pid: Int32, uid: uid_t?)] {
        var out: [(pid: Int32, uid: uid_t?)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            if line.first == "p", let pid = Int32(line.dropFirst()) {
                out.append((pid, nil))
            } else if line.first == "u", let uid = uid_t(line.dropFirst()), !out.isEmpty {
                out[out.count - 1].uid = uid
            }
        }
        return out
    }

    static func listenersAreOwn(_ listeners: [(pid: Int32, uid: uid_t?)], uid: uid_t, serverPids: Set<Int32>) -> Bool {
        !listeners.isEmpty && listeners.allSatisfy { $0.uid == uid && serverPids.contains($0.pid) }
    }

    /// /readyz が通り、待ち受けているのが自分の app-server か。
    private static func isOwnServerReady() async -> Bool {
        guard await isReady() else { return false }
        return listenerIsOwn()
    }

    /// 共有 app-server に繋がっている、Bridge と app-server 以外のプロセス（TUI・中継）の数。lsof が使えなければ nil。
    /// 台帳（CodexTerminalRegistry）は Bridge 再起動直後・thread を開く前の TUI・中継を挟めなかった
    /// buddy-codex を数えられないので、ソケットを直接見る。
    private static func externalClientCount() -> Int? {
        guard let r = ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:ESTABLISHED", "-Fp"], timeout: 5),
              !r.timedOut else { return nil }
        let out = String(decoding: r.stdout, as: UTF8.self)
        // 該当なしは exit 1（出力なし）。それ以外の失敗は分からないものとして扱う。
        guard r.status == 0 || (r.status == 1 && out.isEmpty && r.stderr.isEmpty) else { return nil }
        let own = Set(serverPids()).union([getpid()])
        let pids = out.split(whereSeparator: \.isNewline).compactMap { $0.first == "p" ? Int32($0.dropFirst()) : nil }
        return Set(pids).subtracting(own).count
    }

    /// /readyz は認証なしで 200 を返す（実測）。
    private static func isReady() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/readyz")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private static func loadOrCreateToken() -> String? {
        if let s = try? String(contentsOf: tokenURL, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return rotateToken()
    }

    /// 新しいトークンを作って 0600 で書く（app-server を起動する直前に呼ぶ）。
    private static func rotateToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        do {
            try KeyStore.writeSecret(Data(token.utf8), to: tokenURL)
        } catch {
            return nil
        }
        return token
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// ターミナル（buddy-codex）でいま開いている Codex の thread。一覧の緑の印に使う。
///
/// app-server からは「どの接続がどの thread を開いているか」が取れない（thread/loaded/list は
/// 接続が切れても残る。実測）。そこで buddy-codex が TUI と app-server の間に挟む中継
/// （buddy-codex-proxy.mjs）が、thread/start・resume の応答から thread id を拾って
/// POST /codex/terminal で知らせる。中継は 15 秒ごとに送り直すので、Bridge が再起動しても戻る。
actor CodexTerminalRegistry {
    static let shared = CodexTerminalRegistry()

    struct Entry {
        let threadId: String
        var cwd: String?
        var lastSeen: Date
        let openedAt: Date
    }

    /// 送り直しが途絶えてから落とすまで（中継の送り直しは 15 秒間隔）。
    private static let ttl: TimeInterval = 45
    private var entries: [String: Entry] = [:]

    func open(threadId: String, cwd: String?) {
        if var e = entries[threadId] {
            e.lastSeen = Date()
            if let cwd { e.cwd = cwd }
            entries[threadId] = e
        } else {
            entries[threadId] = Entry(threadId: threadId, cwd: cwd, lastSeen: Date(), openedAt: Date())
            WebSocketServer.wslog("codex-terminal open thread=\(threadId.prefix(8))…")
        }
    }

    func close(threadId: String) {
        if entries.removeValue(forKey: threadId) != nil {
            WebSocketServer.wslog("codex-terminal closed thread=\(threadId.prefix(8))…")
        }
    }

    func liveEntries() -> [Entry] {
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeen) < Self.ttl }
        return Array(entries.values)
    }
}
