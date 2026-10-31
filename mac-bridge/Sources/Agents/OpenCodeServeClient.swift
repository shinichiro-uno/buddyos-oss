import Foundation
import Security
#if canImport(Darwin)
import Darwin
#endif

// opencode の「常駐サーバ」(`opencode serve`) を1プロセス起動し、HTTP + SSE で
// 複数セッションを1プロセス上に多重化するクライアント。
//
// 従来の `opencode acp`(stdio) は 1プロセス=1セッションで、チャットを開くたびに
// コールド bootstrap(initialize 6s + session/new で launchd 配下 ~13-23s)が乗った。
// 一方 `opencode serve`(HTTP) は TUI と同じく 1プロセスで N セッションを並行に持てる。
// サーバ bootstrap は1回(起動時プリウォーム)で済み、以降のセッション生成は
// `POST /session`(ミリ秒)。ストリーミングは `GET /global/event`(SSE) を1本開き、
// 各イベントの properties.sessionID でセッション毎にデマルチプレクスする。
// (`GET /event` は instance(directory) 単位のストリームなので、セッションを directory 付きで
// 作ると serve の cwd 以外のセッションのイベントが届かない。)
// → hermes/openclaw が使う AcpSession/AcpClient(stdio 共有ベース) は一切触らない。

/// opencode serve サーバの生存 + HTTP/SSE を管理するシングルトン的クライアント。
/// OpenCodeAdapter が1インスタンス持ち、全 OpenCodeServeSession がこれを共有する。
final class OpenCodeServeClient {
    static let shared = OpenCodeServeClient()

    private let lock = NSLock()
    private var process: Process?
    private var baseURL: URL?
    // serve の Basic 認証。起動のたびに乱数で作り、OPENCODE_SERVER_PASSWORD として serve に渡す。
    // 認証が無いと、DNS rebinding した Web ページや同じ Mac の別ユーザー・サンドボックス内のアプリが
    // 127.0.0.1 の serve を丸ごと操作できる(/pty や /file/content もある)。全リクエスト(SSE も)に付ける。
    private var password: String?
    static let username = "opencode"
    private var startTask: Task<Void, Never>?
    // 起動失敗(バイナリ無し/実行失敗/listening 前に終了/startupHardLimit 超過)の時刻。
    // startRetryInterval の間は起動し直さず nil を返し(ACP へフォールバック)、過ぎたら次の
    // ensureServer で再試行する。起動直後に落ちた場合もここに記録し、spawn の連打を防ぐ。
    private var startFailedAt: Date?
    private var serverReadyAt: Date?
    private static let startRetryInterval: TimeInterval = 60
    // listening を待つ上限。ensureServer の timeoutSeconds を超えた起動は kill せず裏で待ち続け、
    // これを超えて初めて起動失敗として片付ける(コールドスタートが毎回 timeoutSeconds を超える
    // 環境で、再試行のたびに listening の手前で殺し続けないように)。
    private static let startupHardLimit: TimeInterval = 300

    // SSE ポンプが生存中か
    private var eventTask: Task<Void, Never>?
    private var eventSession: URLSession?
    private var didStartEventStream = false

    // プロンプト送信専用の URLSession。POST /session/{id}/message はターン完了まで
    // 応答を返さないので、無通信タイムアウト(http() の 120s)を掛けると長いターンが
    // 途中で「The request timed out.」になり、error+done で打ち切られる。ターンの長さに
    // 上限は無いのでタイムアウトは実質掛けない(中断は abort で行う)。1ターンが1接続を
    // 占有するため、並行するターンぶん接続を張れるよう上限も広げる。
    private let promptSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: config)
    }()

    // セッション毎のイベントルータ。sessionId -> 弱参照ハンドラの配列。
    // OpenCodeServeSession が register/unregister で自身を差し込む。同じ sid を同時に
    // resume すると一時的に同じ sid のセッションが複数でき(SessionHub が重複側を close する)、
    // 1枠だと上書き/削除で使い続ける側にイベントが届かなくなるため、sid ごとに複数持つ。
    private var routes: [String: [WeakSession]] = [:]
    private struct WeakSession { weak var ref: OpenCodeServeSession? }
    // 子セッション(task ツールのサブエージェント) sid -> 親 sid。session.created / updated の
    // info.parentID から作る。子の承認/質問を親へ回さないと、誰も答えずにターンが止まる。
    private var childParents: [String: String] = [:]
    private static let maxChildParents = 2000
    // 子セッションで起きても親セッションへ回すイベント(応答 API は requestID だけで決まる)。
    private static let parentForwardedTypes: Set<String> = [
        "permission.asked", "question.asked",
        "permission.replied", "question.replied", "question.rejected"
    ]
    // 子セッションの進み具合。親セッションの handleChildEvent へ回し、task(サブエージェント)の行の
    // 作業の文・ツール回数・トークン・モデルと、background の task の終わり(子の idle)にだけ使う
    // (opencode 1.18 は task の part に子の進み具合を載せない)。親の本文やターンには混ぜない。
    private static let childProgressTypes: Set<String> = [
        "message.part.updated", "message.updated", "session.status", "session.idle", "session.error"
    ]

    // query の directory 値に使う文字集合。opencode は URLSearchParams.get で読むので、
    // "+" が空白に化けないよう "+&=?#" もエスケープする(Session の応答 API でも共用)。
    static let directoryQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "+&=?#")
        return set
    }()

    private init() {}

    // MARK: - サーバライフサイクル

    /// `opencode serve` を起動し、baseURL を確定する。idempotent(2回目以降は即復帰)。
    /// 起動失敗(バイナリ無し/タイムアウト)は baseURL=nil のまま復帰し、呼び出し側が
    /// フォールバック(従来 ACP 経路) を取れるようにする。timeoutSeconds を超えた起動は
    /// nil で復帰するが serve は殺さず裏で listening を待ち、確定した時点で baseURL が載る。
    /// serve が後で落ちた場合は terminationHandler が状態を戻すので、次の呼び出しで起動し直す(ポートは変わる)。
    func ensureServer(timeoutSeconds: TimeInterval = 30) async -> URL? {
        lock.lock()
        if let url = baseURL { lock.unlock(); return url }
        if let failedAt = startFailedAt, Date().timeIntervalSince(failedAt) < Self.startRetryInterval {
            lock.unlock(); return nil
        }
        if let task = startTask {
            lock.unlock()
            await task.value
            return serverURL
        }
        // 裏で listening を待っている serve がいる(process あり・baseURL なし)間は、二重に spawn せず
        // 待たずに nil を返す(ACP へフォールバック)。
        if process != nil { lock.unlock(); return nil }
        let exe = OpenCodeAdapter.locateExecutable()
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            startFailedAt = Date(); lock.unlock(); return nil
        }
        startFailedAt = nil
        let task = Task { await self.startServer(executable: exe, timeoutSeconds: timeoutSeconds) }
        startTask = task
        lock.unlock()
        await task.value

        lock.lock()
        let url = baseURL
        // 失敗した task は外す(残すと再試行時も完了済み task を await して nil を返し続ける)。
        if url == nil, startTask == task { startTask = nil }
        lock.unlock()

        // 起動できたら即イベントストリームを開く(セッション生成前に catalog 一連を
        // 流し切っておく)。失敗は致命ではない(初回 send 前に開き直す)。
        if url != nil {
            startEventStream()
        }
        return url
    }

    private func startServer(executable exe: String, timeoutSeconds: TimeInterval) async {
        // XDG_CACHE_HOME は ~/.cache(未マウント SSD symlink) での mkdir クラッシュ回避で必須
        // (OpenCodeAdapter.cacheHome と同一理由。自分専用の 0700 フォルダ)。
        // --port 0 でOSに空きポートを選ばせ、stderr の "listening on http://..:PORT"
        // 行から実際のポートを拾う。
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["serve", "--port", "0", "--hostname", "127.0.0.1"]
        let secret = Self.makePassword()
        var env = ChildEnvironment.base(merging: OpenCodeAdapter.cacheEnvironment)
        // パスワードは引数(ps で見える)ではなく環境変数で渡す。
        env["OPENCODE_SERVER_PASSWORD"] = secret
        env["OPENCODE_SERVER_USERNAME"] = Self.username
        proc.environment = env

        // opencode は "listening on http://127.0.0.1:NNNN" を **stdout** に出す
        // (Warning 行は stderr)。両パイプを共有バッファへ貯め、ポート検出と stderr の
        // ドレイン(バッファ満杯によるブロック防止)を兼ねる。
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let portBox = DispatchSemaphore(value: 0)
        var resolvedPort: Int?
        let boxLock = NSLock()
        var seen = Data()

        // 常に availableData を読んでドレイン(パイプバッファ満杯によるブロック防止)。
        // ポート確定前は内容を seen に追記して "listening on" を探す。確定後は読み捨てる
        // のみ(seen はこれ以上膨らまない)。
        let install: (FileHandle) -> Void = { handle in
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                // EOF(serve 終了)。handler を外さないと EOF の fd で呼ばれ続け CPU を空転する。
                guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
                boxLock.lock()
                if resolvedPort == nil {
                    seen.append(chunk)
                    let s = String(data: seen, encoding: .utf8) ?? ""
                    if let r = s.range(of: "listening on http://127.0.0.1:") {
                        let digits = String(s[r.upperBound...].prefix { $0.isNumber })
                        if let p = Int(digits), p > 0 {
                            resolvedPort = p
                            portBox.signal()
                        }
                    }
                }
                boxLock.unlock()
            }
        }
        install(outPipe.fileHandleForReading)
        install(errPipe.fileHandleForReading)

        // 終了監視。ポート確定前に落ちたら待ちを即座に解き(resolvedPort=nil → 起動失敗)、
        // 起動後に落ちたら状態を戻して次の ensureServer で起動し直せるようにする。
        proc.terminationHandler = { [weak self] p in
            portBox.signal()
            self?.handleServerExit(p)
        }

        do {
            try proc.run()
        } catch {
            FileHandle.standardError.write(Data("[opencode.serve] run failed: \(error)\n".utf8))
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); startFailedAt = Date(); lock.unlock()
            return
        }
        // 独自プロセスグループにして SpawnRegistry に記録する。Bridge が SIGTERM で止まれば
        // killAllRegistered が、SIGKILL/クラッシュで死んでも次回起動時の sweep が serve を
        // 回収する(記録しないと Bridge の再起動ごとに serve が PPID=1 の孤児として溜まる)。
        let pid = proc.processIdentifier
        if pid > 0 {
            _ = setpgid(pid, pid)
            SpawnRegistry.register(pid: pid, command: ([exe] + (proc.arguments ?? [])).joined(separator: " "))
        }
        lock.lock(); self.process = proc; self.password = secret; lock.unlock()

        // ポート確定 or タイムアウト。最長 timeoutSeconds 待つので、協調スレッドの外で待つ。
        let firstWait = await ProcessRunner.offload { portBox.wait(timeout: .now() + timeoutSeconds) }
        if firstWait == .timedOut {
            // コールドスタートが timeoutSeconds を超えた。ここで kill すると、毎回それを超える環境
            // (launchd 配下の重い bootstrap・初回の DB 移行やプラグイン取得等)では再試行のたびに
            // listening の手前で殺し続け、serve 経路がずっと使えない(再試行ごとに呼び出し側も
            // timeoutSeconds ブロックされる)。プロセスは生かしたまま裏で startupHardLimit まで
            // listening を待ち、確定したらその時点で baseURL を載せる。
            FileHandle.standardError.write(Data("[opencode.serve] startup slow, waiting in background\n".utf8))
            let remaining = max(0, Self.startupHardLimit - timeoutSeconds)
            DispatchQueue.global().async { [weak self] in
                let timedOut = portBox.wait(timeout: .now() + remaining) == .timedOut
                boxLock.lock(); let port = resolvedPort; boxLock.unlock()
                guard let self else { return }
                if self.finishStart(proc, port: port, timedOut: timedOut, pipes: [outPipe, errPipe]) {
                    self.startEventStream()
                }
            }
            return
        }
        boxLock.lock(); let port = resolvedPort; boxLock.unlock()
        finishStart(proc, port: port, timedOut: false, pipes: [outPipe, errPipe])
    }

    /// listening 待ちの決着をつける。port が取れていて serve が生きていれば baseURL を載せて true。
    /// 取れない(listening 前に終了 / startupHardLimit 超過)・直後に落ちた場合は片付けて起動失敗にする。
    @discardableResult
    private func finishStart(_ proc: Process, port: Int?, timedOut: Bool, pipes: [Pipe]) -> Bool {
        guard let port else {
            let reason = timedOut ? "startup timeout" : "exited before listening"
            FileHandle.standardError.write(Data("[opencode.serve] \(reason)\n".utf8))
            abandonServer(proc, pipes: pipes)
            lock.lock(); startFailedAt = Date(); lock.unlock()
            return false
        }
        let url = URL(string: "http://127.0.0.1:\(port)")!
        lock.lock()
        // ポート確定直後に落ちていたら死んだ URL を載せない(process 登録前に落ちると
        // terminationHandler が素通りするので isRunning も見る)。
        guard self.process === proc, proc.isRunning else {
            lock.unlock()
            abandonServer(proc, pipes: pipes)
            lock.lock(); startFailedAt = Date(); lock.unlock()
            return false
        }
        self.baseURL = url
        self.serverReadyAt = Date()
        let secret = self.password
        lock.unlock()
        FileHandle.standardError.write(Data("[opencode.serve] ready \(url.absoluteString)\n".utf8))
        OpenCodeTerminals.publishServer(url: url, pid: proc.processIdentifier, password: secret)
        return true
    }

    /// 起動に失敗した serve を片付ける(孤児として残さない)。SIGTERM で終わらなければ SIGKILL。
    private func abandonServer(_ proc: Process, pipes: [Pipe]) {
        for p in pipes { p.fileHandleForReading.readabilityHandler = nil }
        lock.lock(); if process === proc { process = nil }; lock.unlock()
        let pid = proc.processIdentifier
        guard pid > 0 else { return }
        SpawnRegistry.unregister(pid: pid)
        guard proc.isRunning else { return }
        kill(-pid, SIGTERM)
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }

    /// serve プロセスの終了通知(terminationHandler)。現在の serve が落ちたときだけ
    /// baseURL/startTask/SSE を戻し、次の ensureServer で起動し直せるようにする。
    /// shutdown() 済み・起動失敗で片付け済み・別の serve に張り替わった後の古い通知は無視する。
    private func handleServerExit(_ proc: Process) {
        lock.lock()
        guard proc === process else { lock.unlock(); return }
        let wasReady = baseURL != nil
        if wasReady { OpenCodeTerminals.unpublishServer() }
        process = nil
        baseURL = nil
        password = nil
        if wasReady {
            // ポート確定前の終了は startServer 側が起動失敗として処理する。
            startTask = nil
            // 起動直後に落ちるのを繰り返す場合に spawn を連打しないよう、少し待たせる。
            if let readyAt = serverReadyAt, Date().timeIntervalSince(readyAt) < Self.startRetryInterval {
                startFailedAt = Date()
            }
        }
        serverReadyAt = nil
        let es = eventSession
        eventSession = nil
        didStartEventStream = false
        let live: [OpenCodeServeSession] = wasReady ? routes.values.flatMap { list in list.compactMap { $0.ref } } : []
        lock.unlock()
        // SSE の再接続ループは eventSession の張り替えで止まり、再起動時に ensureServer が開き直す。
        es?.invalidateAndCancel()
        SpawnRegistry.unregister(pid: proc.processIdentifier)
        FileHandle.standardError.write(Data("[opencode.serve] exited (status \(proc.terminationStatus))\n".utf8))
        // serve と一緒に子セッション(サブエージェント)も止まった。終わりの知らせはもう来ないので、
        // 各セッションに実行中の行を閉じさせる。
        for session in live { session.serverDidExit() }
    }

    var serverURL: URL? { lock.lock(); defer { lock.unlock() }; return baseURL }

    /// serve へのリクエストに付ける Authorization ヘッダの値(serve 未起動なら nil)。
    var authorizationHeader: String? {
        lock.lock(); defer { lock.unlock() }
        return password.map { Self.basicAuthorization(username: Self.username, password: $0) }
    }

    /// req に serve の Basic 認証を付ける。serve に送る全リクエストで必ず通す。
    func authorize(_ req: inout URLRequest) {
        if let value = authorizationHeader { req.setValue(value, forHTTPHeaderField: "Authorization") }
    }

    static func basicAuthorization(username: String, password: String) -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// 起動ごとの乱数パスワード(32 バイト、URL / シェルで扱いやすい 16 進)。
    static func makePassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// サーバを完全に停止する(テスト/シャットダウン用)。通常運用では呼ばない。
    func shutdown() {
        lock.lock()
        let p = process; process = nil; baseURL = nil; password = nil; startFailedAt = nil; startTask = nil
        serverReadyAt = nil
        let et = eventTask; eventTask = nil
        let es = eventSession; eventSession = nil
        didStartEventStream = false
        lock.unlock()
        et?.cancel()
        es?.invalidateAndCancel()
        guard let p else { return }
        let pid = p.processIdentifier
        if pid > 0 {
            kill(-pid, SIGTERM)
            SpawnRegistry.unregister(pid: pid)
        }
        if p.isRunning { p.terminate() }
    }

    // MARK: - HTTP

    /// longRunning=true はターン完了まで応答しない送信用。promptSession(タイムアウト無し)を使い、
    /// リクエスト側にも十分大きい timeoutInterval(7日)を明示する(URLRequest の既定 60s と session 設定の
    /// どちらが優先されても、ターンが無通信タイムアウトで打ち切られないように)。
    /// directory は `?directory=` で渡す(opencode はこれでリクエストを instance に振り分ける)。
    /// path に "?" を混ぜると appendingPathComponent が %3F にエスケープして壊れるので、必ずここで付ける。
    private func http(_ method: String, _ path: String, body: Any? = nil, directory: String? = nil,
                      longRunning: Bool = false, timeout: TimeInterval = 120) async throws -> Any {
        guard let base = serverURL,
              var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw NSError(domain: "OpenCodeServe", code: 1, userInfo: [NSLocalizedDescriptionKey: "server not running"])
        }
        if let dir = directory, !dir.isEmpty,
           let encoded = dir.addingPercentEncoding(withAllowedCharacters: Self.directoryQueryAllowed) {
            comps.percentEncodedQueryItems = [URLQueryItem(name: "directory", value: encoded)]
        }
        guard let url = comps.url else {
            throw NSError(domain: "OpenCodeServe", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid url for \(path)"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = longRunning ? 7 * 24 * 3600 : timeout
        authorize(&req)
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await (longRunning ? promptSession : URLSession.shared).data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw NSError(domain: "OpenCodeServe", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(code) \(method) \(path): \(snippet)"
            ])
        }
        if data.isEmpty { return NSNull() }
        return try Self.decodeBody(data)
    }

    /// 応答の本文を読む。abort などは本文が `true` だけで返る(トップレベルの値)ので、fragments を許す。
    static func decodeBody(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    /// 新規セッション作成。サーバは Bridge の cwd で起動済みなので、チャットの作業ディレクトリは
    /// directory で渡す(nil ならサーバの cwd を project root とみなす)。returns sessionId。
    func createSession(directory: String? = nil) async throws -> String {
        let res = try await http("POST", "session", body: [String: Any](), directory: directory)
        guard let dict = res as? [String: Any], let id = dict["id"] as? String else {
            throw NSError(domain: "OpenCodeServe", code: 3, userInfo: [NSLocalizedDescriptionKey: "no session id"])
        }
        return id
    }

    /// 1セッションの情報(directory 等)。サーバは id だけで引くので directory は不要。
    func getSession(_ sid: String) async throws -> [String: Any] {
        let res = try await http("GET", "session/\(sid)")
        guard let dict = res as? [String: Any] else {
            throw NSError(domain: "OpenCodeServe", code: 3, userInfo: [NSLocalizedDescriptionKey: "no session \(sid)"])
        }
        return dict
    }

    /// directory 指定時はその directory のセッションだけ。nil はプロジェクト横断の一覧
    /// (`GET /experimental/session`: updated 降順・既定 100 件)。directory なしの `GET /session` は
    /// serve の cwd のプロジェクト分しか返さないので、横断一覧が取れないときの控えにだけ使う。
    func listSessions(directory: String? = nil) async throws -> [[String: Any]] {
        if let directory, !directory.isEmpty {
            let res = try await http("GET", "session", directory: directory)
            return (res as? [[String: Any]]) ?? []
        }
        if let res = try? await http("GET", "experimental/session"), let list = res as? [[String: Any]] {
            return list
        }
        let res = try await http("GET", "session")
        return (res as? [[String: Any]]) ?? []
    }

    /// 指定セッションのメッセージ一覧(履歴)。時系列順の message オブジェクト配列。
    func history(_ sid: String) async throws -> [[String: Any]] {
        let res = try await http("GET", "session/\(sid)/message")
        // レスポンス形状は {info, messages?} の場合と配列の場合があるので両対応。
        if let arr = res as? [[String: Any]] { return arr }
        if let dict = res as? [String: Any], let arr = dict["messages"] as? [[String: Any]] { return arr }
        return []
    }

    /// 接続済みのプロバイダとモデル（`GET /config/providers`）。モデルピッカー用。
    /// `default` は provider ごとの既定モデル。
    func providers() async throws -> (providers: [[String: Any]], defaults: [String: String]) {
        let res = try await http("GET", "config/providers")
        guard let dict = res as? [String: Any] else { return ([], [:]) }
        return ((dict["providers"] as? [[String: Any]]) ?? [], (dict["default"] as? [String: String]) ?? [:])
    }

    /// プロンプト送信。POST はターン完了までブロックするが、ストリーミング差分は
    /// 並行して SSE で届く。呼び出し側は await せず fire-and-forget で投げ、SSE 主導で
    /// UI を更新する。エラー時は SSE の session.error で通知される。
    /// - Parameter model: このチャットだけのモデル（provider, model）。nil なら既定（opencode.json の model）。
    /// agent: opencode の agent（build / plan）。チャットで選んだモード。nil = opencode の既定（build）。
    /// variant: モデルの思考の強さ（BuddyOS の Effort）。nil = モデルの既定。
    func sendMessage(_ sid: String, directory: String? = nil, text: String, attachments: [BridgeAttachment],
                     model: (provider: String, model: String)? = nil, agent: String? = nil,
                     variant: String? = nil) async throws {
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for a in attachments where a.kind == .image {
            // opencode の FilePartInput は {type:"file", mime, filename?, url(必須)}。画像は
            // data URL で渡す({name, source:{type:"base64"}} はスキーマ不一致で 400 になり、
            // 同じリクエストのテキストごと拒否される)。
            let mime = a.mime.isEmpty ? "image/png" : a.mime
            parts.append([
                "type": "file",
                "mime": mime,
                "filename": a.name,
                "url": "data:\(mime);base64,\(a.data.base64EncodedString())"
            ])
        }
        // serve が落ちていたら起動し直す(既存セッションの送信が "server not running" で
        // 失敗し続けないように)。sid は opencode 側に永続化されているので新サーバでも続けられる。
        _ = await ensureServer()
        var body: [String: Any] = ["parts": parts]
        // アプリで選んだモデルがあれば、このメッセージのモデルとして指定する（無ければ opencode の設定どおり）。
        if let m = model ?? OpenCodeAdapter.selectedModel() { body["model"] = ["providerID": m.provider, "modelID": m.model] }
        if let agent { body["agent"] = agent }
        if let variant { body["variant"] = variant }
        _ = try await http("POST", "session/\(sid)/message", body: body, directory: directory, longRunning: true)
    }

    /// 実行中のターンを持つ instance(directory) に届かないと効かないので、directory を渡す。
    func abort(_ sid: String, directory: String? = nil) async {
        if let hook = abortHook { _ = await hook(sid, directory); return }
        _ = try? await http("POST", "session/\(sid)/abort", body: [String: Any](), directory: directory)
    }

    /// テスト用: abortChecked の代わりに呼ぶ(サーバーを起こさずに行の停止を試す)。
    var abortHook: ((_ sid: String, _ directory: String?) async -> Bool)?

    /// 子セッションだけを止める(行ごとの停止)。応答は 2xx なら true(終わった子・無い id でも 200 `true` が返るので、
    /// 止まったことの保証ではない)。2xx でなければ・つながらなければ false。10 秒で切る。
    func abortChecked(_ sid: String, directory: String? = nil) async -> Bool {
        if let hook = abortHook { return await hook(sid, directory) }
        return (try? await http("POST", "session/\(sid)/abort", body: [String: Any](), directory: directory, timeout: 10)) != nil
    }

    /// sid が ancestor の子孫(子・孫…)か。子セッションの親は session.created / updated と task の part から覚えている。
    func isDescendant(_ sid: String, of ancestor: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var current = sid
        for _ in 0..<8 {
            guard let parent = childParents[current] else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    func deleteSession(_ sid: String, directory: String? = nil) async {
        _ = try? await http("DELETE", "session/\(sid)", body: [String: Any](), directory: directory)
    }

    // MARK: - SSE イベントストリーム

    /// `GET /global/event` を `Accept: text/event-stream` で開き、`data:` フレームを順次パースして
    /// 該当セッションへルーティングする。1本しか開かない(全セッション共有)。
    /// `/event` は instance(directory) 単位なので、directory 付きで作ったセッションのイベントが届かない。
    func startEventStream() {
        lock.lock()
        if didStartEventStream { lock.unlock(); return }
        guard let base = baseURL else { lock.unlock(); return }
        didStartEventStream = true
        lock.unlock()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        config.shouldUseExtendedBackgroundIdleMode = false
        let session = URLSession(configuration: config, delegate: SSEDelegate(client: self), delegateQueue: nil)
        lock.lock(); self.eventSession = session; lock.unlock()

        var req = URLRequest(url: base.appendingPathComponent("global/event"))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&req)
        let task = session.dataTask(with: req)
        task.resume()
        // URLSession が稼働中の dataTask を保持する。イベントは delegate で受ける。
    }

    func register(_ sid: String, _ session: OpenCodeServeSession) {
        lock.lock()
        var list = (routes[sid] ?? []).filter { $0.ref != nil && $0.ref !== session }
        list.append(WeakSession(ref: session))
        routes[sid] = list
        lock.unlock()
    }

    /// session を渡すとそのハンドラだけを外す(同じ sid の別セッションは巻き込まない)。
    /// 省略時は解放済みの弱参照だけを掃除する。
    func unregister(_ sid: String, _ session: OpenCodeServeSession? = nil) {
        lock.lock()
        let list = (routes[sid] ?? []).filter { w in
            guard let ref = w.ref else { return false }
            return ref !== session
        }
        routes[sid] = list.isEmpty ? nil : list
        lock.unlock()
    }

    /// task の part の metadata(sessionId = 子、parentSessionId = 親)から子セッションの親を覚える。
    /// session.created を取りこぼしても(SSE の張り直し・Bridge の再起動)、子の進み具合を親へ回せるように。
    func linkChild(_ childId: String, toParent parentId: String) {
        guard !childId.isEmpty, !parentId.isEmpty, childId != parentId else { return }
        lock.lock()
        if childParents[childId] != parentId {
            if childParents.count >= Self.maxChildParents { childParents.removeAll() }
            childParents[childId] = parentId
        }
        lock.unlock()
    }

    /// SSE パーサから呼ばれる。1イベント(JSON)をデコードし sessionID でルーティング。
    /// `/global/event` のフレームは `{directory, project?, workspace?, payload:{id?, type, properties}}`。
    /// 旧 `/event` 形式(`{type, properties}`)もそのまま読む。
    func dispatchEvent(_ jsonData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }
        let ev = (obj["payload"] as? [String: Any]) ?? obj
        let type = (ev["type"] as? String) ?? ""
        guard let props = ev["properties"] as? [String: Any] else { return }
        // 子セッション(サブエージェント)の親を覚える。session.* は sessionID を持たない形もある。
        if type == "session.created" || type == "session.updated",
           let info = props["info"] as? [String: Any],
           let childId = info["id"] as? String, !childId.isEmpty,
           let parentId = info["parentID"] as? String, !parentId.isEmpty {
            lock.lock()
            if childParents.count >= Self.maxChildParents { childParents.removeAll() }
            childParents[childId] = parentId
            lock.unlock()
        } else if type == "session.deleted",
                  let info = props["info"] as? [String: Any], let id = info["id"] as? String {
            lock.lock(); childParents.removeValue(forKey: id); lock.unlock()
        }
        let sid = (props["sessionID"] as? String) ?? ""
        // sessionID を持たないグローバルイベント(catalog.updated, server.*, plugin.*)は無視。
        guard !sid.isEmpty else { return }
        // 同じ sid の生きているセッション全員に配る。close 済みの側は stream を finish 済み
        // なので、配っても二重表示にはならない。子セッションの承認/質問と進み具合は、ルートを持つ
        // 祖先(iPhone が見ている親)まで辿って配る。
        let sessions: [OpenCodeServeSession]
        let progress = Self.childProgressTypes.contains(type)
        // 辿ったときの、祖先の直下の子(その子が祖先の task の行。孫のイベントもその行に数える)。
        var child: String?
        lock.lock()
        var target = sid
        if progress || Self.parentForwardedTypes.contains(type) {
            var hops = 0
            while (routes[target] ?? []).allSatisfy({ $0.ref == nil }),
                  let parent = childParents[target], hops < 8 {
                child = target
                target = parent
                hops += 1
            }
        }
        sessions = (routes[target] ?? []).compactMap { $0.ref }
        lock.unlock()
        for session in sessions {
            if progress, let child {
                session.handleChildEvent(childSessionId: child, originSessionId: sid, type: type, properties: props)
            } else {
                session.handleServeEvent(type: type, properties: props)
            }
        }
    }

    /// 現在登録されているセッション(モデル一覧のキャッシュ暖機等で使う)。
    func anySession() -> OpenCodeServeSession? {
        lock.lock(); defer { lock.unlock() }
        for list in routes.values {
            for w in list {
                if let s = w.ref { return s }
            }
        }
        return nil
    }
}

// MARK: - SSE URLSession delegate

private final class SSEDelegate: NSObject, URLSessionDataDelegate {
    weak var client: OpenCodeServeClient?
    private var buffer = Data()
    private let bufLock = NSLock()

    init(client: OpenCodeServeClient) { self.client = client }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let client else { return }
        bufLock.lock(); buffer.append(data)
        // SSE フレームは "\n\n" 区切り。切り出せるだけ切り出して dispatch。
        while let sep = buffer.range(of: Data([0x0A, 0x0A])) {
            let frame = buffer.subdata(in: 0..<sep.lowerBound)
            buffer.removeSubrange(0..<sep.upperBound)
            bufLock.unlock()
            processFrame(frame, client: client)
            bufLock.lock()
        }
        bufLock.unlock()
    }

    private func processFrame(_ frame: Data, client: OpenCodeServeClient) {
        guard let text = String(data: frame, encoding: .utf8) else { return }
        // 各行 "data: <json>" を結合(複数行データは稀だが仕様上ありうる)
        var jsonParts: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(line)
            if l.hasPrefix("data:") {
                jsonParts.append(String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let json = jsonParts.joined(separator: "\n").data(using: .utf8), !json.isEmpty else { return }
        client.dispatchEvent(json)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // SSE が切れたらしばらくして開き直す(サーバは生きているはず)。
        guard let client else { return }
        if let error {
            FileHandle.standardError.write(Data("[opencode.sse] closed: \(error.localizedDescription)\n".utf8))
        }
        // 再接続は少し待ってから(バックオフ)。didStartEventStream をリセットして再開。
        // serve の再起動などで既に別の SSE に張り替わっていたら何もしない(新しい方を殺さない)。
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            guard client.resetEventStreamForReconnect(ifCurrent: session) else { return }
            client.startEventStream()
        }
    }
}

extension OpenCodeServeClient {
    fileprivate func resetEventStreamForReconnect(ifCurrent session: URLSession) -> Bool {
        lock.lock()
        guard eventSession === session else { lock.unlock(); return false }
        didStartEventStream = false
        eventSession?.invalidateAndCancel()
        eventSession = nil
        lock.unlock()
        return true
    }
}
