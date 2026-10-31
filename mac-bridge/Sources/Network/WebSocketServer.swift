import Vapor
import WebSocketKit
import Crypto

enum WebSocketServer {
    /// プロセス開始時刻。/health の uptimeSeconds 算出に使う (可観測性)。
    static let startedAt = Date()
    /// 最後にネット変化を検知してエンドポイント再公開した時刻。/status に載せて
    /// 「Bridge がネット切替に追従したか」をリモートから切り分けられるようにする (可観測性)。
    private static let netRefreshLock = NSLock()
    private static var _lastNetworkRefreshAt: Date?
    static func noteNetworkRefresh() {
        netRefreshLock.lock()
        _lastNetworkRefreshAt = Date()
        netRefreshLock.unlock()
    }
    static var lastNetworkRefreshAt: Date? {
        netRefreshLock.lock()
        defer { netRefreshLock.unlock() }
        return _lastNetworkRefreshAt
    }
    private static let logQueue = DispatchQueue(label: "ws.log")
    /// ログは ~/Library/Logs/BuddyOS（0700）の下に 0600 で書く。/tmp の決め打ちパスは、別のユーザーが先に
    /// シンボリックリンクやファイルを置けば、その先へ書かされたり中身を読まれたりする。
    static let logDirectory = NSHomeDirectory() + "/Library/Logs/BuddyOS"
    private static let logPath = logDirectory + "/bridge-ws.log"
    private static let logMaxBytes = 5 * 1024 * 1024   // 5MB を超えたら rotate (合計 ~10MB に抑える)
    private static var logLineCount = 0
    private static var logDirectoryReady = false
    static func wslog(_ msg: String) {
        let line = "[WS \(Date())] \(msg)\n"
        logQueue.sync {
            fputs(line, stderr)
            fflush(stderr)
            if !logDirectoryReady { logDirectoryReady = prepareLogDirectory(logDirectory) }
            guard logDirectoryReady else { return }
            // 256 行ごとにサイズを確認し、肥大していたら .1 へ退避して新規作成。
            // (無制限追記でディスクが埋まり Bridge が起動不能になるのを防ぐ)
            logLineCount += 1
            if logLineCount % 256 == 0 {
                var st = stat()
                if lstat(logPath, &st) == 0, st.st_size > off_t(logMaxBytes) {
                    _ = rename(logPath, logPath + ".1")
                }
            }
            _ = appendLogLine(line, toFile: logPath)
        }
    }

    /// ログのフォルダを 0700 で用意する。既にあるなら、自分の持ち物の（シンボリックリンクでない）フォルダであること。
    static func prepareLogDirectory(_ dir: String) -> Bool {
        if mkdir(dir, 0o700) != 0, errno != EEXIST {
            // ~/Library/Logs が無い環境（テストの HOME 差し替えなど）では親から作る。
            guard (try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        var st = stat()
        guard lstat(dir, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o077 != 0 { _ = chmod(dir, 0o700) }
        return true
    }

    /// 1 行を追記する。O_NOFOLLOW で開き（シンボリックリンクはたどらない）、無ければ 0600 で作る。
    /// 既にあるものは、自分の持ち物の通常ファイルのときだけ書き、0600 より広ければ絞る。
    static func appendLogLine(_ line: String, toFile path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o077 != 0 { _ = fchmod(fd, 0o600) }
        let bytes = Array(line.utf8)
        return bytes.withUnsafeBytes { buf in
            Darwin.write(fd, buf.baseAddress, buf.count) == buf.count
        }
    }

    static func register(app: Application, agentRegistry: AgentRegistry) {
        wslog("register handler")
        // 全ルート・全 WebSocket の upgrade に Origin / Host の関門をかける（本文を読む前に走る）。
        // 約束は Windows の originGuard.ts・desktop と同じ。
        app.middleware.use(BridgeRequestGuard.Middleware())
        // その後ろに認証の表（spec/PROTOCOL-v3.md §13.3）。表に無いルートは 404、
        // トンネル経由は bdc_ だけ・この PC の中からはローカル鍵だけ。ルートの中でも同じ確かめをもう一度行う。
        app.middleware.use(BridgeAuth.Middleware())
        app.get("health") { req async throws -> BridgeHealthResponse in
            // インストール済みエージェント等の内部情報を含むため /push-test と同じく要認証。
            try BridgeAuth.requireAny(req)
            let descriptors = await agentRegistry.descriptors()
            // installed/configured/version を付与（AgentProbe は 15s キャッシュなので
            // /health 連打でもプロセス起動は増えない）。iOS が未設定エージェントを
            // グレーアウト＝開けない表示にするのに使う。
            var agents: [AgentDescriptor] = []
            for d in descriptors {
                let p = await AgentProbe.shared.probe(id: d.id)
                agents.append(AgentDescriptor(
                    id: d.id,
                    displayName: d.displayName,
                    capabilities: d.capabilities,
                    installed: p.installed,
                    configured: p.configured,
                    version: p.version
                ))
            }
            let aliveSessions = await SessionHub.shared.aliveCount()
            let response = healthResponse(
                agents: agents, aliveSessions: aliveSessions,
                bridgeId: KeyStore.loadOrCreateBridgeId(), e2ePub: KeyStore.e2ePublicKeyBase64URL(),
                relay: PaseoRelayTunnelService.shared.relayURL == nil
                    ? RelayHealthInfo(configured: false, hint: BridgeConfig.relayHint) : nil
            )
            if let data = try? JSONEncoder().encode(response) {
                TrafficMeter.shared.record("http.health.out", bytes: data.count)
            }
            return response
        }

        // Deeper, probed setup status (installed / configured / version) for the
        // SuperDOS desktop dashboard. Falls back gracefully per-agent.
        app.get("status") { req async throws -> BridgeStatusResponse in
            // binaryPath 等のホスト情報を漏らさないよう要認証。
            try BridgeAuth.requireAny(req)
            // インストール/再起動直後は desktop が `?fresh=1` を付けて即時再検出を要求する。
            // これで AgentProbe の 15s キャッシュ待ちを潰し「入れたのに認識しない」を解消。
            if let fresh = try? req.query.get(String.self, at: "fresh"), fresh == "1" || fresh == "true" {
                await AgentProbe.shared.clearCache()
            }
            let descriptors = await agentRegistry.descriptors()
            var items: [AgentStatusItem] = []
            for d in descriptors {
                let p = await AgentProbe.shared.probe(id: d.id)
                items.append(
                    AgentStatusItem(
                        id: d.id,
                        displayName: d.displayName,
                        capabilities: d.capabilities,
                        installed: p.installed,
                        binaryPath: p.binaryPath,
                        configured: p.configured,
                        version: p.version
                    )
                )
            }
            let response = BridgeStatusResponse(
                ok: true,
                bridgeId: KeyStore.loadOrCreateBridgeId(),
                agents: items,
                lastNetworkRefreshAt: lastNetworkRefreshAt.map { ISO8601DateFormatter().string(from: $0) }
            )
            if let data = try? JSONEncoder().encode(response) {
                TrafficMeter.shared.record("http.status.out", bytes: data.count)
            }
            return response
        }

        // Transport measurement endpoints. They expose aggregate counts only;
        // no payload text, URL, key, token, or filename is retained.
        app.get("traffic") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            let data = try JSONEncoder().encode(TrafficMeter.shared.snapshot())
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                body: .init(data: data)
            )
        }
        app.post("traffic", "reset") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            let data = try JSONEncoder().encode(TrafficMeter.shared.reset())
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                body: .init(data: data)
            )
        }

        // --- ターミナルの Claude Code セッションを attach するための受け口 --------------
        // Claude Code の hooks（~/.claude/settings.json）がここへ POST する。
        //   SessionStart（command hook, buddy-register.py）→ /claude/session-start : 台帳に載せ、spawn 側を引き継ぐ
        //   それ以外（command hook, buddy-hook.sh）        → /claude/hook           : SessionEvent に変換して流す
        //   SessionEnd（command hook, buddy-hook.sh）      → /claude/session-end   : 台帳から外す
        // command hook（~/.buddyos/bin/buddy-hook.sh）は実行時に ~/.buddyos の api-key / bridge.port を
        // 読んで POST する。BUDDYOS_SPAWNED=1（Bridge 自身が起動した claude）なら送らない。
        // すべて 127.0.0.1 からの呼び出しで、Bearer にローカル鍵を要求する（トンネル経由は 403 local_only）。
        // 古い hook 設定からの送信に備え、X-Buddy-Spawned: 1 の hook もターミナル扱いしない。
        @Sendable func isSpawnedHook(_ req: Request) -> Bool {
            req.headers.first(name: "X-Buddy-Spawned") == "1"
        }
        app.post("claude", "session-start") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            if isSpawnedHook(req) { return Response(status: .accepted) }
            let body = (try? req.content.decode([String: AnyCodableValue].self)) ?? [:]
            guard let sid = body["session_id"]?.stringValue, !sid.isEmpty else { throw Abort(.badRequest) }
            let pid = body["pid"]?.stringValue.flatMap { Int32($0) }
            // 登録前から台帳に載っている = 同じターミナルの再発火（compact / resume / /buddy 再実行）。
            // この sid の hub entry は iPhone が attach 中の ClaudeTerminalSession なので閉じない
            // （閉じると以後の hook が backlog に溜まるだけになり、iPhone の表示が止まる）。
            let wasLive = await ClaudeTerminalRegistry.shared.isLive(sid)
            await ClaudeTerminalRegistry.shared.register(
                sessionId: sid, cwd: body["cwd"]?.stringValue, pid: pid,
                transcriptPath: body["transcript_path"]?.stringValue,
                inboxSocket: body["inbox_socket"]?.stringValue)
            // 引き継ぎ: Bridge が同じ session を spawn していたら止める（二股防止）。
            var handedOver = false
            if !wasLive {
                handedOver = await SessionHub.shared.closeSession(agentId: "claude", sessionId: sid)
            }
            return try await Response(status: .ok, body: .init(string: "{\"ok\":true,\"handedOver\":\(handedOver)}")).encodeResponse(for: req)
        }
        // buddy-codex の中継（scripts/buddy-codex-proxy.mjs）が、TUI が開いている thread を知らせる。
        //   {"thread_id": "...", "cwd": "...", "state": "open" | "closed"}
        // Bridge が起動した agy の PreToolUse hook（~/.buddyos/agy-hooks）からの承認の問い合わせ。
        // 認証はターンごとのトークン（AgyApprovalRegistry）。iPhone で答えるまで応答を返さない。
        // 本文は .stream で受け、トークンが付いていることを確かめてから読む。
        app.on(.POST, "antigravity", "hook", body: .stream) { req async throws -> Response in
            // トンネル経由は 403（§13.3。ターンごとのトークンはこの PC の中の hook だけが持つ）。
            if case .tunnel = BridgeAuth.origin(req) { throw Abort(.forbidden, reason: "local_only") }
            guard let token = req.headers.first(name: "X-BuddyOS-Hook-Token"), !token.isEmpty else { throw Abort(.badRequest) }
            guard let buffer = try await req.body.collect(max: 2 * 1024 * 1024).get() else { throw Abort(.badRequest) }
            guard let out = await AgyApprovalRegistry.shared.handle(token: token, body: Data(buffer: buffer)) else {
                throw Abort(.notFound)
            }
            var headers = HTTPHeaders()
            headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: out))
        }
        app.post("codex", "terminal") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            let body = (try? req.content.decode([String: AnyCodableValue].self)) ?? [:]
            guard let tid = body["thread_id"]?.stringValue, !tid.isEmpty else { throw Abort(.badRequest) }
            if body["state"]?.stringValue == "closed" {
                await CodexTerminalRegistry.shared.close(threadId: tid)
            } else {
                await CodexTerminalRegistry.shared.open(threadId: tid, cwd: body["cwd"]?.stringValue)
            }
            return Response(status: .ok)
        }
        // PostToolUse は tool_input / tool_response を丸ごと載せる（Read の本文・Bash 出力・Task 結果）ため、
        // 既定の 16KB では 413 で落ちて toolEnd が出ず、iPhone の tool pill が回り続ける。ルート単位で上限を上げる。
        // 本文は .stream で受け、認証を通ってから上限付きで読む（未認証の要求で 8MB を溜めない）。
        app.on(.POST, "claude", "hook", body: .stream) { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            if isSpawnedHook(req) { return Response(status: .accepted) }
            guard let data = try await req.body.collect(max: 8 * 1024 * 1024).get(), let obj = try? JSONSerialization.jsonObject(with: Data(buffer: data)) as? [String: Any] else {
                throw Abort(.badRequest)
            }
            // デスクトップのアプリ内ターミナルで動いている claude は、ペインを名乗る（buddy-hook.sh）。
            let pane = TerminalPaneStatus.validPane(req.headers.first(name: "X-BuddyOS-Pane"))
            // 許可の依頼（PermissionRequest）は答え方を調べてからカードにするので別の入口。
            let handled = (obj["hook_event_name"] as? String) == "PermissionRequest"
                ? await ClaudeTerminalRegistry.shared.ingestPermission(obj, pane: pane)
                : await ClaudeTerminalRegistry.shared.ingest(obj, pane: pane)
            // hook は空応答で十分。JSON を返すと Claude Code が出力として解釈しうる
            // （PermissionRequest に decision を返すとターミナルの選択肢が出なくなる）。
            return Response(status: handled ? .ok : .accepted)
        }
        // channel サーバ（scripts/buddy-channel.py）の long-poll。iPhone からの送信を渡す。
        app.get("claude", "channel", "poll") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            guard let sid = try? req.query.get(String.self, at: "session"), !sid.isEmpty else { throw Abort(.badRequest) }
            // 台帳から外れた（SessionEnd で forget 済みの）sid には long-poll せずに空を返す。poll すると lastSeen が
            // 更新され、pid ファイルの書き換えが遅れて channel が古い sid に張り直したときに、
            // isConnected が true に戻ってしまう（channel 側は空がすぐ返ると 1 秒待って引き直す）。
            // ただし返す前に 2 秒待つ（lastSeen は更新しない）。~/.buddyos/bin の channel は手で入れ直すまで旧版の
            // ままで、旧版は空応答で待たずに張り直すため、即答すると python と Bridge が空転する。起動直後の
            // SessionStart 登録待ちもここで吸収し、待つ間に台帳に載ればそのまま long-poll に入る。
            var registered = await ClaudeTerminalRegistry.shared.contains(sessionId: sid)
            if !registered {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                registered = await ClaudeTerminalRegistry.shared.contains(sessionId: sid)
            }
            guard registered else {
                let data = try JSONSerialization.data(withJSONObject: ["messages": [String]()])
                var headers = HTTPHeaders(); headers.contentType = .json
                return Response(status: .ok, headers: headers, body: .init(data: data))
            }
            let items = await ClaudeChannelInbox.shared.poll(sessionId: sid, timeout: 25)
            var messages: [String] = []
            var permissions: [[String: String]] = []
            for item in items {
                switch item {
                case .text(let t): messages.append(t)
                case .permission(let rid, let behavior): permissions.append(["request_id": rid, "behavior": behavior])
                }
            }
            let data = try JSONSerialization.data(withJSONObject: ["messages": messages, "permissions": permissions])
            var headers = HTTPHeaders(); headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }
        // channel サーバが受けた許可の依頼（notifications/claude/channel/permission_request）。
        //   {"session": "...", "request_id": "abcde", "tool_name": "Bash", "description": "...", "input_preview": "..."}
        // 答えは上の poll の permissions で返る。
        app.post("claude", "channel", "permission") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            guard let data = req.body.data, let obj = try? JSONSerialization.jsonObject(with: Data(buffer: data)) as? [String: Any],
                  let sid = obj["session"] as? String, !sid.isEmpty,
                  let rid = obj["request_id"] as? String, !rid.isEmpty else { throw Abort(.badRequest) }
            await ClaudeTerminalRegistry.shared.channelPermission(
                sessionId: sid, requestId: rid, toolName: (obj["tool_name"] as? String) ?? "tool",
                description: obj["description"] as? String, inputPreview: obj["input_preview"] as? String)
            return Response(status: .ok)
        }
        // デスクトップアプリ（main プロセス）の long-poll。開いている pty の pid を名乗り、
        // ターミナルの選択肢へのキー入力と、人が打った発話の打ち込みを受け取る（TerminalKeys.swift）。
        //   GET /terminal/keys/poll?client=<名前>&pids=123,456&typing=1 → {"items":[{"pid":123,"keys":["1"],"gapMs":800}]}
        //   typing=1 は打ち込みを受け付けるデスクトップ（書く前に expectPid の claude が生きていて前面にいるかと、
        //   sessions/<expectPid>.json が expectSession の idle かを確かめる）。打ち込みの item には expectPid と expectSession が付く。
        app.get("terminal", "keys", "poll") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            let raw = (try? req.query.get(String.self, at: "pids")) ?? ""
            let pids = raw.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            let client = (try? req.query.get(String.self, at: "client")) ?? "default"
            let canType = (try? req.query.get(String.self, at: "typing")) == "1"
            let items = await TerminalKeyRouter.shared.poll(client: client, pids: pids, canType: canType, timeout: 25)
            let data = try JSONSerialization.data(withJSONObject: [
                "items": items.map { d -> [String: Any] in
                    var o: [String: Any] = ["pid": Int(d.pid), "keys": d.keys, "gapMs": d.gapMs]
                    if let expect = d.expectPid { o["expectPid"] = Int(expect) }
                    if let session = d.expectSession { o["expectSession"] = session }
                    return o
                }
            ])
            var headers = HTTPHeaders(); headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }
        // デスクトップアプリ（main プロセス）の long-poll。アプリ内ターミナルのペインごとのエージェントの状態
        // （TerminalPaneStatus）を、変わったら返す。
        //   GET /terminal/panes/poll?since=<version> → {"version":N,"panes":[{"pane","agent","state","turn","sessionId","cwd","reply",
        //                                              "backgroundAgents","backgroundShells","updatedAt"}]}
        //   reply は done のペインで、返事の文があるときだけ。backgroundAgents / backgroundShells はターンの後も動いている
        //   サブエージェント・バックグラウンドのコマンドの数（docs/BACKGROUND_WORK_2026-10-21.md §3.4）。
        app.get("terminal", "panes", "poll") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            let since = (try? req.query.get(Int.self, at: "since")) ?? -1
            let r = await TerminalPaneStatus.shared.poll(since: since, timeout: 25)
            let panes: [[String: Any]] = r.entries.map { e in
                var o: [String: Any] = ["pane": e.pane, "agent": e.agent, "state": e.state, "turn": e.turn,
                                        "backgroundAgents": e.backgroundAgents, "backgroundShells": e.backgroundShells,
                                        "updatedAt": Int(e.updatedAt.timeIntervalSince1970 * 1000)]
                if let sid = e.sessionId { o["sessionId"] = sid }
                if let cwd = e.cwd { o["cwd"] = cwd }
                if let reply = e.reply { o["reply"] = reply }
                return o
            }
            let data = try JSONSerialization.data(withJSONObject: ["version": r.version, "panes": panes])
            var headers = HTTPHeaders(); headers.contentType = .json
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }
        // hook を使わないエージェント（Codex の proxy など）が、アプリ内ターミナルのペインの状態を知らせる。
        //   POST /terminal/pane-event {"pane","agent","state":"working|attention|done|error|idle","sessionId"?,"cwd"?,"reply"?}
        // 本文は .stream で受け、認証を通ってから 64KB まで読む。
        app.on(.POST, "terminal", "pane-event", body: .stream) { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            guard let data = try await req.body.collect(max: 64 * 1024).get(),
                  let obj = try? JSONSerialization.jsonObject(with: Data(buffer: data)) as? [String: Any],
                  let ev = TerminalPaneStatus.paneEvent(obj) else { throw Abort(.badRequest) }
            TerminalPaneStatus.shared.set(pane: ev.pane, state: ev.state, sessionId: ev.sessionId, cwd: ev.cwd,
                                          agent: ev.agent, reply: ev.reply)
            return Response(status: .ok)
        }
        app.post("claude", "session-end") { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            if isSpawnedHook(req) { return Response(status: .accepted) }
            guard let data = req.body.data, let obj = try? JSONSerialization.jsonObject(with: Data(buffer: data)) as? [String: Any],
                  let sid = obj["session_id"] as? String else { throw Abort(.badRequest) }
            await ClaudeTerminalRegistry.shared.unregister(sessionId: sid)
            return Response(status: .ok)
        }

        // プッシュ通知の疎通検証用（この PC の中から、ローカル鍵で）。登録済みの端末にテスト通知を E2E で送る。
        //   curl -H "Authorization: Bearer $(cat ~/.buddyos/api-key)" http://127.0.0.1:8765/push-test
        app.get("push-test") { req async throws -> PushTestResponse in
            try BridgeAuth.requireLocal(req)
            let r = await PushService.shared.sendTest()
            return PushTestResponse(ok: r.error == nil && r.registered > 0, registered: r.registered, remaining: r.remaining, error: r.error)
        }

        // 画像添付 (1600px JPEG, base64 inline) + テキストファイル数本でも余裕を持たせるため 10MB。
        app.webSocket("ws", "agent", ":agentId", maxFrameSize: .init(integerLiteral: 10 * 1024 * 1024), shouldUpgrade: { req in
            return req.eventLoop.makeSucceededFuture([:])
        }) { req, ws in
            let peer = req.remoteAddress?.description ?? "?"
            // ブラウザのページ（プレビュー中の web アプリ・別のサイト）のスクリプトから /ws/agent を張られて
            // 操作されるのを防ぐ。middleware でも断っているが、ここでも見る（Origin が無いか desktop の画面だけ）。
            if !BridgeRequestGuard.passes(req) {
                wslog("rejected browser upgrade peer=\(peer)")
                _ = ws.close(code: .policyViolation)
                return
            }
            // トンネル経由なら端末の bdc_、この PC の中からならローカル鍵（spec/PROTOCOL-v3.md §13.2）。
            guard let principal = BridgeAuth.principal(req) else {
                wslog("auth failed peer=\(peer)")
                _ = ws.close(code: .policyViolation)
                return
            }

            // サーバ発 keepalive。死接続 (iOS 強制終了 / 電池切れ / 圏外) を検知して close させ、
            // onClose → SessionHub.release でセッションを掃除する。NAT/proxy のアイドル切断も防ぐ。
            // WebSocketKit は次の ping 時刻までに pong が無ければ 1006 で close するため、
            // これ 1 行で ping 送信と idle timeout (~2×interval) の両方が効く。
            ws.pingInterval = .seconds(30)

            let agentId = req.parameters.get("agentId") ?? "hermes"
            // クエリで sessionId が来ていれば resume、なければ新規 (adapter が確定)
            let querySessionId: String? = try? req.query.get(String.self, at: "sessionId")
            let queryCwd: String? = try? req.query.get(String.self, at: "cwd")
            let connectionTag = (querySessionId ?? UUID().uuidString).prefix(8)
            let eventLoop = ws.eventLoop
            wslog("open peer=\(peer) agent=\(agentId) session=\(connectionTag) resume=\(querySessionId != nil) cwd=\(queryCwd ?? "-")")
            ws.onClose.whenComplete { _ in
                wslog("close peer=\(peer) session=\(connectionTag)")
            }

            // e2e=v1&deviceId=... で E2E モード（spec/PROTOCOL-v3.md §13.6）。クエリなし = 従来の平文経路そのまま。
            // モード確定 (hello 送信 or unknown_device フォールバック) までの送信イベントは
            // e2eState が溜める — 「open 成功まで暗号化データを送らない」ゲート（§13.6）も同じ機構。
            let queryE2E: String? = try? req.query.get(String.self, at: "e2e")
            let queryDeviceId: String? = try? req.query.get(String.self, at: "deviceId")
            let e2eState = E2EChannelState()
            // 内側の E2E（v1）は .device(D) の WS だけ。.local の WS では e2e のクエリを無視する（平文のまま。§13.6）。
            let e2eDevice: DeviceStore.Device? = {
                if case .device(_, let row) = principal { return row }
                return nil
            }()
            let wantsE2E = e2eDevice != nil && queryE2E == "v1" && !(queryDeviceId ?? "").isEmpty
            if wantsE2E { e2eState.mode = .negotiating }

            let send: @Sendable (SessionEvent) -> Void = { event in
                guard let data = try? JSONEncoder().encode(event) else { return }
                eventLoop.execute {
                    e2eState.sendOrBuffer(data, eventType: event.type.rawValue, over: ws)
                }
            }

            // SessionHub の購読者として live で届けた採番済みイベントを控える。resume 接続は acquire の
            // 時点で fan-out に加わるので、loadHistoryRequest(sinceSeq) までに届いた分を差分 replay で再送しない。
            let liveDelivered = LiveDeliveredEvents()
            let hubSend: @Sendable (SessionEvent) -> Void = { event in
                liveDelivered.note(event)
                send(event)
            }

            let inbox = SessionInbox(liveDelivered: liveDelivered, principal: principal)
            let subscriberId = UUID()

            // 受信フレームは 1 本の consumer で到着順に inbox へ渡す。フレームごとに Task を切ると
            // actor への到着順が保証されず、先に送ったメッセージが後続に追い越されうる。
            let (inboundTexts, inboundSink) = AsyncStream.makeStream(of: String.self)
            Task {
                for await text in inboundTexts { await inbox.deliver(text: text) }
            }
            ws.onClose.whenComplete { _ in
                inboundSink.finish()
                // 閉じた接続への送信は捨てる（negotiating / 鍵確認前のまま閉じると pending に溜まり続ける）。
                e2eState.close()
            }

            ws.onText { ws, text in
                // E2E 確立後の平文フレームはフレーム単位ダウングレード攻撃の疑い → 即 close（§13.6）
                if case .established = e2eState.mode {
                    wslog("e2e violation: plaintext frame on encrypted connection session=\(connectionTag)")
                    _ = ws.close(code: .policyViolation)
                    return
                }
                let type = Self.eventType(in: Data(text.utf8))
                TrafficMeter.shared.record("ws.in.\(type)", bytes: text.utf8.count)
                inboundSink.yield(text)
            }

            ws.onBinary { ws, buffer in
                // E2E 未確立の接続でバイナリは解釈できない (平文接続にバイナリを送る正当な経路はない)
                guard case .established(let e2eSession) = e2eState.mode else {
                    wslog("e2e violation: binary frame before e2e established session=\(connectionTag)")
                    _ = ws.close(code: .policyViolation)
                    return
                }
                do {
                    let wireData = Data(buffer.readableBytesView)
                    let plaintext = try e2eSession.receiver.open(wireData)
                    if !e2eSession.confirmed {
                        // 最初の open 成功 = クライアントが鍵を持つ確認（§13.6）。溜めた送信を流す。
                        // 端末の鍵はペアリングで確かめ済みなので、Bridge の側で「confirmed」を記録することはもう無い。
                        e2eState.markConfirmed(over: ws)
                    }
                    guard let text = String(data: plaintext, encoding: .utf8) else { return }
                    let type = Self.eventType(in: plaintext)
                    TrafficMeter.shared.record("ws.in.\(type)", bytes: wireData.count)
                    inboundSink.yield(text)
                } catch {
                    // seq 逆行/改竄/鍵不一致 — リプレイ・並べ替え防止のため即 close（§9）
                    wslog("e2e open failed session=\(connectionTag) error=\(error) — closing 1008")
                    _ = ws.close(code: .policyViolation)
                }
            }

            if wantsE2E, let deviceId = queryDeviceId, let device = e2eDevice {
                // 鍵の導出には、トンネルで認証した端末 D の公開鍵を使う（§13.6）。モード確定は eventLoop 上で反映する。
                // クライアントは hello 受信まで暗号化フレームを送らないため、この間の取りこぼしはない。
                Task {
                    // connSalt = 接続ごとの 32B 乱数。1 接続の鍵漏洩の影響を局所化する（§13.6）
                    let connSalt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    guard TunnelV3.constantTimeEquals(deviceId, device.clientDeviceId),
                          let devicePub = TunnelV3.b64uDecodeStrict(device.pub, length: 32),
                          let bridgeKey = KeyStore.e2eKey(),
                          let keys = try? E2ECrypto.deriveWSKeys(
                              privateKey: bridgeKey,
                              peerPublicKey: devicePub,
                              connSalt: connSalt
                          )
                    else {
                        // deviceId が D の clientDeviceId と違う → e2e_error を返して 1008 で閉じる（平文に落とさない）。
                        wslog("e2e device mismatch session=\(connectionTag) → closing 1008")
                        eventLoop.execute {
                            let event = SessionEvent(
                                type: .e2eError, agentId: agentId, sessionId: nil,
                                messageId: nil, toolUseId: nil, content: nil,
                                toolName: nil, metadata: ["reason": "unknown_device"]
                            )
                            if let data = try? JSONEncoder().encode(event),
                               let json = String(data: data, encoding: .utf8) {
                                ws.send(json)
                                TrafficMeter.shared.record("ws.out.\(event.type.rawValue)", bytes: data.count)
                            }
                            e2eState.close()
                            _ = ws.close(code: .policyViolation)
                        }
                        return
                    }
                    eventLoop.execute {
                        e2eState.mode = .established(E2EWSSession(
                            deviceId: deviceId, sendKey: keys.s2c, receiveKey: keys.c2s
                        ))
                        // hello は E2E 接続で唯一の平文 TEXT（§13.6）。SessionEvent 互換形なので
                        // 万一旧クライアントが受けても前方互換 decode で unsupported に落ちて無害。
                        let hello = SessionEvent(
                            type: .e2eHello, agentId: agentId, sessionId: nil,
                            messageId: nil, toolUseId: nil, content: nil,
                            toolName: nil,
                            metadata: ["v": "1", "salt": Base64URL.encode(connSalt), "kid": KeyStore.e2eKid()]
                        )
                        if let data = try? JSONEncoder().encode(hello),
                           let json = String(data: data, encoding: .utf8) {
                            ws.send(json)
                            TrafficMeter.shared.record("ws.out.\(hello.type.rawValue)", bytes: data.count)
                        }
                        wslog("e2e hello sent device=\(deviceId.prefix(8))… session=\(connectionTag)")
                    }
                }
            }

            // cron 出力 broadcast に参加
            Task {
                await CronOutputHub.shared.startIfNeeded()
                let token = await CronOutputHub.shared.register(send: send)
                ws.onClose.whenComplete { _ in
                    Task { await CronOutputHub.shared.unregister(token) }
                    Task { await SessionHub.shared.release(subscriberId: subscriberId) }
                    Task { await inbox.close() }
                }
            }

            // メインの定期チェックの状態（回し始め・終わり）の知らせに参加。
            Task {
                let hbToken = await MainHeartbeat.shared.register(send: send)
                ws.onClose.whenComplete { _ in
                    Task { await MainHeartbeat.shared.unregister(hbToken) }
                }
            }

            // バックグラウンドの作業の状態 (background_work_state) は .device の WS だけが受ける（Live Activity。§8.3）。
            if case .device = principal {
                Task {
                    let laToken = await LiveActivityPublisher.shared.register(send: send)
                    ws.onClose.whenComplete { _ in
                        Task { await LiveActivityPublisher.shared.unregister(laToken) }
                    }
                }
            }

            // claude --bg の行の変化 (bg_session_changed) を受ける。エージェントに関係なく全接続へ送る。
            Task {
                let bgToken = await ClaudeBackgroundJobs.shared.register(send: send)
                ws.onClose.whenComplete { _ in
                    Task { await ClaudeBackgroundJobs.shared.unregister(bgToken) }
                }
            }

            // 使用量 (5h/週リミット %) broadcast に参加。register 時に直近キャッシュが即届く。
            Task {
                await UsageHub.shared.startIfNeeded()
                let usageToken = await UsageHub.shared.register(send: send)
                ws.onClose.whenComplete { _ in
                    Task { await UsageHub.shared.unregister(usageToken) }
                }
            }

            Task {
                guard let adapter = await agentRegistry.adapter(for: agentId) else {
                    send(.unsupported(rawType: "unknown_agent:\(agentId)"))
                    eventLoop.execute { _ = ws.close(code: .unacceptableData) }
                    return
                }

                // SessionHub が events pump を一元化し、購読者が居ない時の done を APNs push に escalate する。
                await bindSession(
                    inbox: inbox, adapter: adapter, agentId: agentId,
                    sessionId: querySessionId, cwd: queryCwd, options: nil,
                    subscriberId: subscriberId, send: send, hubSend: hubSend
                )
            }
        }
    }

    /// 接続 1 本を agent の session に結ぶ。resume（sessionId あり）は即 acquire、新規は最初の
    /// user_message まで openSession を遅らせる。hubSend は SessionHub の購読者として届ける送信
    /// （live で届けた採番済みイベントを控える）、send はこの接続だけへの送信。
    static func bindSession(inbox: SessionInbox, adapter: AgentAdapter, agentId: String,
                            sessionId querySessionId: String?, cwd queryCwd: String?, options: SessionOptions?,
                            subscriberId: UUID,
                            send: @escaping @Sendable (SessionEvent) -> Void,
                            hubSend: @escaping @Sendable (SessionEvent) -> Void) async {
        if let qid = querySessionId {
            // resume: 既存 session を即 acquire（turn_resume / sessionStarted 即返しに必要）。
            let session = await SessionHub.shared.acquire(
                agentId: agentId, sessionId: qid, cwd: queryCwd, adapter: adapter,
                subscriberId: subscriberId, send: hubSend, options: options
            )
            send(.sessionStarted(agentId: agentId, sessionId: qid))
            let attached = await inbox.attach(
                session: session, adapter: adapter, agentId: agentId, cwd: queryCwd, send: send,
                subscriberId: subscriberId,
                // ターミナル終了などで session が死んだら、同じ sid で取り直す（spawn --resume）。
                provider: { _ in
                    await SessionHub.shared.acquire(
                        agentId: agentId, sessionId: qid, cwd: queryCwd, adapter: adapter,
                        subscriberId: subscriberId, send: hubSend, options: options
                    )
                }
            )
            if !attached {
                // acquire（openSession）中に WS が閉じていた。onClose の release は購読者登録前に
                // 空振りしているので、ここで外さないと死んだ購読者が entry に残り続ける。
                await SessionHub.shared.release(subscriberId: subscriberId)
            }
        } else {
            // 新規: 最初の userMessage まで openSession を遅延 (B1)。list/history/model 問い合わせ
            // だけの接続では子プロセスを spawn しない。provider は acquire を1回だけ実行する。
            // 取り直し時は確定済みの sid が渡る（nil で acquire すると文脈の無い新規会話に化ける）。
            await inbox.attachLazy(
                adapter: adapter, agentId: agentId, cwd: queryCwd, subscriberId: subscriberId, send: send,
                provider: { sid in
                    await SessionHub.shared.acquire(
                        agentId: agentId, sessionId: sid, cwd: queryCwd, adapter: adapter,
                        subscriberId: subscriberId, send: hubSend, options: options
                    )
                }
            )
        }
    }

    /// GET /health の本体。適合テスト（shared/protocol.json の health.required）からも組み立てる。
    static func healthResponse(agents: [AgentDescriptor], aliveSessions: Int, bridgeId: String, e2ePub: String,
                               relay: RelayHealthInfo? = nil) -> BridgeHealthResponse {
        BridgeHealthResponse(
            ok: true,
            bridgeId: bridgeId,
            adapters: agents.map(\.id),
            agents: agents,
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt)),
            aliveSessions: aliveSessions,
            e2e: E2EHealthInfo(v: 1, pub: e2ePub),
            // "auth-v3" = 端末認証 v3（spec/PROTOCOL-v3.md §13.7。デスクトップが見分ける）。
            // "sites" = sites_request に答える（公開したサイトの一覧）。
            // "heartbeat" = メインの定期チェック（heartbeat_get / heartbeat_set / heartbeat_run_now）に答える。
            // "terminal-share" = /terminal/share（この PC のデスクトップで開いているペインを見られる）。
            features: ["terminal", "auth-v3", "sites", "heartbeat", "terminal-share"],
            relay: relay
        )
    }

    /// 添付サイズの上限。frame cap (10MB) とは別に、デコード後バイト数で多重防御する。
    /// 悪意/バグで巨大 base64 が来ても無制限デコードでメモリを食い潰さないようにする。
    private static let attachmentMaxFileBytes = 5 * 1024 * 1024       // 1 ファイル 5MB
    private static let attachmentMaxTotalBytes = 50 * 1024 * 1024     // 1 メッセージ累計 50MB
    private static let attachmentMaxCount = 20                        // 添付点数の上限

    /// iOS が userMessage の metadata に inline した添付 (attachment_count, attachment_<i>_kind/name/mime/b64)
    /// を BridgeAttachment 配列に復元する。
    /// 上限超過の添付は graceful に skip + log する (decode 自体は中断しない)。
    static func decodeAttachments(metadata: [String: String]?) -> [BridgeAttachment] {
        guard let meta = metadata,
              let rawCount = Int(meta["attachment_count"] ?? ""), rawCount > 0 else { return [] }
        let count = min(rawCount, attachmentMaxCount)
        if rawCount > attachmentMaxCount {
            wslog("attachment count capped \(rawCount) -> \(attachmentMaxCount)")
        }
        var result: [BridgeAttachment] = []
        result.reserveCapacity(count)
        var totalBytes = 0
        for i in 0..<count {
            guard let kindRaw = meta["attachment_\(i)_kind"],
                  let kind = BridgeAttachment.Kind(rawValue: kindRaw),
                  let name = meta["attachment_\(i)_name"],
                  let mime = meta["attachment_\(i)_mime"],
                  let b64 = meta["attachment_\(i)_b64"],
                  let data = Data(base64Encoded: b64) else {
                wslog("attachment decode skipped i=\(i)")
                continue
            }
            if data.count > attachmentMaxFileBytes {
                wslog("attachment skipped i=\(i) oversized bytes=\(data.count) limit=\(attachmentMaxFileBytes)")
                continue
            }
            if totalBytes + data.count > attachmentMaxTotalBytes {
                wslog("attachment skipped i=\(i) cumulative limit exceeded total=\(totalBytes) add=\(data.count) limit=\(attachmentMaxTotalBytes)")
                continue
            }
            totalBytes += data.count
            result.append(BridgeAttachment(kind: kind, name: name, mime: mime, data: data))
        }
        return result
    }

    /// stopTask と上限の時計を競わせ、先に決まった方を返す。
    /// stopTask が取り消しを無視しても上限で返せるよう、構造化しない Task で動かす（withTaskGroup は子を待つ）。
    static func raceStopTask(session: AgentSession, request: StopTaskRequest,
                             timeout: TimeInterval) async -> StopTaskOutcome {
        let race = StopTaskRace()
        return await withCheckedContinuation { (cont: CheckedContinuation<StopTaskOutcome, Never>) in
            race.install(cont)
            let work = Task { race.finish(await session.stopTask(request)) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if race.finish(.timeout) { work.cancel() }
            }
        }
    }

    /// stop_task_request の本体。session が無ければ not_running、15 秒を超えたら timeout。
    /// not_running / stale のときは、返事の前に turn_status_request と同じ応答を同じ接続へ送る。
    static func runStopTask(agentId: String, sessionId: String, requestId: String, request: StopTaskRequest,
                            session: AgentSession?, send: @escaping @Sendable (SessionEvent) -> Void,
                            timeout: TimeInterval = 15) async {
        let started = Date()
        let outcome: StopTaskOutcome
        if let session {
            outcome = await raceStopTask(session: session, request: request, timeout: timeout)
        } else {
            outcome = .notRunning
        }
        // stopped の行（カード）の payload は、返事より先に接続へ届ける（§3.3 の規則 8）。pump が配り終えるまで待つ。
        if outcome == .stopped, !sessionId.isEmpty {
            await SessionHub.shared.awaitStopDelivered(agentId: agentId, sessionId: sessionId, request: request)
        }
        if outcome == .notRunning || outcome == .stale, !sessionId.isEmpty {
            await SessionHub.shared.requestTurnStatus(agentId: agentId, sessionId: sessionId, send: send)
        }
        send(.stopTaskResult(agentId: agentId, sessionId: sessionId, requestId: requestId,
                             taskId: request.taskId, rowId: request.rowId, outcome: outcome))
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        wslog("stop-task agent=\(agentId) row=\(request.rowId ?? request.taskId) reason=\(outcome.reason) ms=\(ms)")
    }

    /// ユーザーの送信をセッションに渡す。音声会話モードの指定を自分で扱えないセッションには、
    /// 応え方の指示と注記を本文末尾の `<voice-context>` で渡す（履歴では enrichHistory が剥がす）。
    /// typedByUser は人がペアリング済みの端末の入力欄で打った発話（.device の WS の user_message と、その予約）。
    /// ターミナルの claude には打ち込んで届ける（ClaudeTerminalSession）。mainagent・定期の見回りの文と、.local の WS
    /// （この PC の api-key を持つプロセス）からの発話は false のまま（受け箱で届く）。
    static func dispatch(_ session: AgentSession, content: String, skills: [String],
                         attachments: [BridgeAttachment], voice: VoiceTurn?, typedByUser: Bool = false) async {
        if let aware = session as? VoiceTurnAware {
            await aware.send(content, skills: skills, attachments: attachments, voice: voice)
        } else if typedByUser, let terminal = session as? ClaudeTerminalSession {
            let body = voice.map { $0.appended(to: content, includeDirective: true) } ?? content
            await terminal.send(body, skills: skills, attachments: attachments, typedByUser: true)
        } else if let voice {
            await session.send(voice.appended(to: content, includeDirective: true), skills: skills, attachments: attachments)
        } else {
            await session.send(content, skills: skills, attachments: attachments)
        }
    }

    /// 履歴メッセージ本文の画像 placeholder を、保管済み実画像へ戻す。
    /// Claude Code は `[image "<name>" attached: <mime>, <N> bytes]` を本文に書くため、
    /// AttachmentStore と突き合わせて attachments へ変換し、placeholder 行は本文から除く。
    /// 既に attachments を持つ場合（opencode の実画像 replay 等）はそのまま返す。
    static func enrichHistory(message m: HistoryMessage) async -> HistoryMessage {
        // 音声会話モードでモデルにだけ渡した `<voice-context>` はユーザーに見せない。
        let m = m.role == "user" && m.content.contains("<v")
            ? HistoryMessage(role: m.role, content: VoiceTurn.stripContext(m.content),
                             messageId: m.messageId, attachments: m.attachments)
            : m
        guard m.attachments.isEmpty else { return m }
        guard let regex = try? NSRegularExpression(
            // 末尾の「(file: …)」は、画像をファイルで渡す CLI 向けに足したパス（HeadlessCliSession）。一緒に消す。
            pattern: #"\[image "([^"]+)" attached: ([^,]+), (\d+) bytes\](?: \(file: [^)\n]*\))?"#
        ) else { return m }
        let ns = m.content as NSString
        let matches = regex.matches(in: m.content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return m }

        var found: [HistoryAttachment] = []
        for match in matches where match.numberOfRanges == 4 {
            let name = ns.substring(with: match.range(at: 1))
            let mime = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard let size = Int(ns.substring(with: match.range(at: 3))),
                  let data = await AttachmentStore.shared.lookup(name: name, byteCount: size, mime: mime)
            else { continue }
            found.append(HistoryAttachment(kind: "image", name: name, mime: mime, b64: data.base64EncodedString()))
        }
        guard !found.isEmpty else { return m }

        // 復元できた placeholder 行を本文から除去（前後の空白/改行を整える）。
        let stripped = regex
            .stringByReplacingMatches(in: m.content, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return HistoryMessage(role: m.role, content: stripped, messageId: m.messageId, attachments: found)
    }

    // 認証は BridgeAuth（spec/PROTOCOL-v3.md §13）。apiKey を閉じ込めた authorize(req:expected:) は廃止。

    private static func eventType(in data: Data) -> String {
        InboundFrame.meterType(data)
    }

}

/// WS 接続 1 本分の E2E 暗号化状態（spec/PROTOCOL-v3.md §13.6）。
/// 全フィールドは ws.eventLoop 上でのみ触ること — seq 採番と pending flush の直列化を
/// eventLoop に委ねているため @unchecked Sendable にしている (lock は持たない)。
final class E2EChannelState: @unchecked Sendable {
    enum Mode {
        /// e2e クエリなしの従来接続、または unknown_device フォールバック後
        case plaintext
        /// e2e=v1 でデバイス照会/鍵導出が未完 (この間の送信イベントは pending に溜める)
        case negotiating
        /// hello 送信済み。以降の送信は seal してバイナリフレーム
        case established(E2EWSSession)
    }
    var mode: Mode = .plaintext
    /// negotiating 中 + 鍵確認前の送信待ちイベント (encode 済み SessionEvent JSON)
    private struct PendingEvent {
        let data: Data
        let eventType: String
    }
    private var pending: [PendingEvent] = []
    /// WS が閉じた。以後の送信は溜めずに捨てる。
    private var closed = false

    /// onClose から呼ぶ。negotiating / 鍵確認前のまま閉じた接続に、購読が残った送信元から
    /// イベントが届き続けても pending が無制限に伸びないようにする。
    func close() {
        closed = true
        pending.removeAll()
    }

    /// send クロージャ本体。モードに応じて平文 TEXT / 溜め / 暗号化バイナリを選ぶ。
    func sendOrBuffer(_ data: Data, eventType: String, over ws: WebSocket) {
        guard !closed else { return }
        switch mode {
        case .plaintext:
            guard let json = String(data: data, encoding: .utf8) else { return }
            ws.send(json)
            TrafficMeter.shared.record("ws.out.\(eventType)", bytes: data.count)
        case .negotiating:
            pending.append(PendingEvent(data: data, eventType: eventType))
        case .established(let session):
            guard session.confirmed else {
                // 鍵確認 (クライアントの最初のフレーム open 成功) まで暗号化データを送らない（§13.6）
                pending.append(PendingEvent(data: data, eventType: eventType))
                return
            }
            sendSealed(data, eventType: eventType, session: session, over: ws)
        }
    }

    /// unknown_device フォールバック。溜めたイベントを平文で流す — 旧経路と同等の動作。
    func fallBackToPlaintext(over ws: WebSocket) {
        mode = .plaintext
        let queued = pending
        pending.removeAll()
        for item in queued {
            sendOrBuffer(item.data, eventType: item.eventType, over: ws)
        }
    }

    /// 鍵確認成立（§13.6）。溜めたイベントを暗号化して流す。
    func markConfirmed(over ws: WebSocket) {
        guard case .established(let session) = mode else { return }
        session.confirmed = true
        let queued = pending
        pending.removeAll()
        for item in queued {
            sendSealed(item.data, eventType: item.eventType, session: session, over: ws)
        }
    }

    private func sendSealed(_ data: Data, eventType: String, session: E2EWSSession, over ws: WebSocket) {
        guard let frame = try? session.sender.seal(data) else {
            // seal 失敗は鍵長不正など回復不能な内部エラー。以降を平文で漏らさないため close する
            _ = ws.close(code: .policyViolation)
            return
        }
        ws.send(frame)
        TrafficMeter.shared.record("ws.out.\(eventType)", bytes: frame.count)
    }
}

/// 確立済み E2E 接続の方向別鍵と seq 状態。E2EChannelState と同じく eventLoop 直列化前提。
final class E2EWSSession: @unchecked Sendable {
    let deviceId: String
    let sender: E2EFrameSender     // k_s2c
    let receiver: E2EFrameReceiver // k_c2s
    /// クライアントの最初のフレーム open 成功 = 鍵確認（§13.6）
    var confirmed = false

    init(deviceId: String, sendKey: Data, receiveKey: Data) {
        self.deviceId = deviceId
        self.sender = E2EFrameSender(key: sendKey)
        self.receiver = E2EFrameReceiver(key: receiveKey)
    }
}

struct BridgeHealthResponse: Content {
    let ok: Bool
    let bridgeId: String
    let adapters: [String]
    let agents: [AgentDescriptor]
    /// 可観測性: プロセス起動からの経過秒数。iOS の未知キーは無視されるので後方互換。
    let uptimeSeconds: Int
    /// 可観測性: 現在生存しているセッション数。
    let aliveSessions: Int
    /// E2E 能力広告（§13.7）。既存ペアリングはこれを見て QR 再スキャンなしに E2E へ自動アップグレードする。
    let e2e: E2EHealthInfo
    /// できること。"terminal" = /terminal/pty（別の PC のデスクトップからターミナルを操作できる）。
    /// "terminal-share" = /terminal/share（この PC のデスクトップで開いているペインを、別の PC から見て打てる）。
    let features: [String]
    /// 中継が無いときだけ載せる（`{"configured":false,"hint":"…"}`。Windows と同じ形）。中継があれば載せない。
    let relay: RelayHealthInfo?
}

/// /health の `relay`（中継が無いときの案内）。
struct RelayHealthInfo: Content {
    let configured: Bool
    let hint: String
}

/// /health の E2E 能力広告。v はプロトコルバージョン、pub は bridge_pub (b64url)。
struct E2EHealthInfo: Content {
    let v: Int
    let pub: String
}

/// /push-test の結果。registered=0 はトークン未登録、registered>remaining は無効トークン除去あり。
private struct PushTestResponse: Content {
    let ok: Bool
    let registered: Int
    let remaining: Int
    let error: String?
}

/// Per-agent probed availability for the desktop dashboard `/status` endpoint.
struct AgentStatusItem: Content {
    let id: String
    let displayName: String
    let capabilities: AgentCapabilities
    let installed: Bool
    let binaryPath: String?
    let configured: Bool
    let version: String?
}

private struct BridgeStatusResponse: Content {
    let ok: Bool
    let bridgeId: String
    let agents: [AgentStatusItem]
    /// 最後にネット変化で再公開した時刻 (ISO8601)。未発生なら nil。既存クライアントは未知キーを無視する。
    let lastNetworkRefreshAt: String?
}

/// WS 接続 1 本分の「SessionHub から live で届けた採番済みイベント」の控え。
/// 差分 replay（liveDelta）は sinceSeq より後を全部返すので、acquire 後にこの接続へ live で
/// 届けた分も含まれ、同じ delta / done が二重に届く（本文の二重追記・完了処理の再実行）。
/// 採番済みイベントの fan-out は SessionHub の actor 内で記録と同期に行われるため、liveDelta が
/// 返った時点で届け済みの分はすべてここに載っている。SessionHub と replay の Task から触るので lock で守る。
final class LiveDeliveredEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []
    private var order: [String] = []
    /// live buffer（1500 件）を覆える分だけ保持する。
    private static let maxKeys = 2000
    /// SessionHub から届いた最新の sessionStarted の sid（adapter が sid を確定した証拠）。
    private var startedSid: String?

    private static func key(_ event: SessionEvent) -> String? {
        guard let seq = event.seq else { return nil }
        return "\(event.sessionId ?? ""):\(seq):\(event.type.rawValue)"
    }

    /// この接続で sessionStarted を受けて確定した sid（まだなら nil）。session 取り直し時の resume に使う。
    var startedSessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return startedSid
    }

    func note(_ event: SessionEvent) {
        if event.type == .sessionStarted, let sid = event.sessionId, !sid.isEmpty {
            lock.lock(); startedSid = sid; lock.unlock()
        }
        guard let key = Self.key(event) else { return }
        lock.lock(); defer { lock.unlock() }
        guard keys.insert(key).inserted else { return }
        order.append(key)
        if order.count > Self.maxKeys {
            keys.remove(order.removeFirst())
        }
    }

    func contains(_ event: SessionEvent) -> Bool {
        guard let key = Self.key(event) else { return false }
        lock.lock(); defer { lock.unlock() }
        return keys.contains(key)
    }
}

/// Buffers inbound WS text frames until the agent session is attached,
/// then forwards them to the session or to adapter-level list/history queries.
actor SessionInbox {
    /// この接続へ SessionHub から live で届け済みの採番済みイベント（差分 replay の重複除去用）。
    private let liveDelivered: LiveDeliveredEvents
    private var pendingText: [String] = []
    private var session: AgentSession?
    private var adapter: AgentAdapter?
    private var agentId: String?
    private var cwd: String?
    private var send: (@Sendable (SessionEvent) -> Void)?
    private var closed = false
    /// 遅延 acquire 用 (新規セッション接続)。最初の userMessage まで openSession しない。
    /// list/history/model 問い合わせだけの接続でプロセスを spawn しないためのリーク対策 (B1)。
    /// 引数は取り直し時の確定済み sid（初回や未確定のまま落ちた場合は nil）。
    private var sessionProvider: ((String?) async -> AgentSession)?
    private var acquireTask: Task<AgentSession, Never>?
    private var subscriberId: UUID?
    /// user_message / queue_user_message の送信前処理（acquire・ack・添付退避・notePromptSent）を
    /// 受信順に直列化する鎖の末尾。添付の退避待ちの間に後続メッセージが先に送られないようにする。
    private var outboundTail: Task<Void, Never>?
    /// iPhone からのログイン（AgentLoginService）の知らせを受ける登録。最初の agent_login_request で登録する。
    private var loginToken: UUID?
    /// この WS の Principal（register_push_token は .device だけ。spec/PROTOCOL-v3.md §14.1）。
    private let principal: Principal?

    init(liveDelivered: LiveDeliveredEvents = LiveDeliveredEvents(), principal: Principal? = nil) {
        self.liveDelivered = liveDelivered
        self.principal = principal
    }

    /// ペアリング済みの端末（.device の WS）からの発話か。アプリ内ターミナルの claude に本人の入力として打ち込むのは、
    /// これだけ（WebSocketServer.dispatch の typedByUser）。.local（この PC の api-key を持つプロセス）からの発話は
    /// 今までどおり受け箱で送る（PC の中の別のプロセスが、本人の入力として claude を動かせないように）。
    private var fromPairedDevice: Bool {
        if case .device = principal { return true }
        return false
    }

    /// - Returns: false なら既に close 済み（acquire 中に WS が閉じた）。呼び元は購読を release する。
    @discardableResult
    func attach(session: AgentSession, adapter: AgentAdapter, agentId: String, cwd: String?,
                send: @escaping @Sendable (SessionEvent) -> Void,
                subscriberId: UUID? = nil, provider: ((String?) async -> AgentSession)? = nil) -> Bool {
        guard !closed else { return false }
        self.session = session
        self.subscriberId = subscriberId
        self.sessionProvider = provider
        self.adapter = adapter
        self.agentId = agentId
        self.cwd = cwd
        self.send = send
        let queued = pendingText
        pendingText.removeAll()
        for text in queued {
            handle(text)
        }
        return true
    }

    /// sessionId 無し接続用。session を即 open せず、list/history/model 等の adapter 直呼びだけ
    /// 受け付ける。最初の userMessage が来た時に provider で acquire する。
    /// (セッション一覧/履歴の問い合わせ接続のたびに openclaw 等のプロセスが起動するのを防ぐ)
    func attachLazy(adapter: AgentAdapter, agentId: String, cwd: String?, subscriberId: UUID,
                    send: @escaping @Sendable (SessionEvent) -> Void,
                    provider: @escaping (String?) async -> AgentSession) {
        guard !closed else { return }
        self.adapter = adapter
        self.agentId = agentId
        self.cwd = cwd
        self.send = send
        self.subscriberId = subscriberId
        self.sessionProvider = provider
        let queued = pendingText
        pendingText.removeAll()
        for text in queued {
            handle(text)
        }
    }

    func deliver(text: String) {
        // adapter も session も未設定 = attach/attachLazy 前なのでキュー。以降は handle へ。
        if adapter == nil && session == nil {
            pendingText.append(text)
        } else {
            handle(text)
        }
    }

    func close() async {
        closed = true
        // session 本体は SessionHub が所有しているのでここでは閉じない。
        // hermes は WS 切断後も走り続け、done で subscribers=0 なら APNs push に escalate される。
        //
        // acquire が走行中に WS が閉じた場合、onClose の SessionHub.release が
        // subscriber 登録前に空振りして entry が残る可能性がある。遅延 acquire は完了を待ち、
        // resume 接続（acquire は WS ハンドラ側で走り acquireTask に載らない）も attach 済みなら
        // subscriberId を持っているので、ここで release し直す (release は冪等なので二重呼びは無害)。
        if let task = acquireTask {
            _ = await task.value
        }
        if let sid = subscriberId {
            await SessionHub.shared.release(subscriberId: sid)
        }
        if let token = loginToken {
            loginToken = nil
            await AgentLoginService.shared.unsubscribe(token)
        }
        session = nil
    }

    private func handleAgentLogin(_ event: SessionEvent, send: @escaping @Sendable (SessionEvent) -> Void) async {
        guard let target = event.agentId, !target.isEmpty else { return }
        if loginToken == nil, !closed {
            loginToken = await AgentLoginService.shared.subscribe { send(.agentLoginStatus($0)) }
        }
        let service = AgentLoginService.shared
        switch event.metadata?["op"] ?? "status" {
        case "start":
            await service.start(agentId: target)
        case "code":
            await service.submitCode(agentId: target, code: event.content ?? "")
        case "cancel":
            await service.cancel(agentId: target)
        default:
            if let e = await service.status(agentId: target) {
                send(.agentLoginStatus(e))
            } else {
                send(.agentLoginIdle(agentId: target))
            }
        }
    }

    /// 確立済み session を返す。遅延 acquire 中ならその完了を待つ。無ければ nil
    /// (interrupt 等のために新規プロセスを起動はしない)。
    private func existingSession() async -> AgentSession? {
        if let session { return session }
        if let task = acquireTask {
            let s = await task.value
            session = s
            return s
        }
        return nil
    }

    /// userMessage 用: session が無ければ provider で acquire する。
    /// 並行 userMessage が二重 spawn しないよう acquireTask に一本化する。
    private func currentOrAcquireSession() async -> AgentSession? {
        var confirmedSid: String?
        if let s = await existingSession() {
            if await isStillUsable(s) { return s }
            // 取り直しは確定済みの sid で行う（ターミナル引き継ぎ・プロセス死の後も同じ会話を続ける）。
            // 確定したかは sessionStarted が届いたかで見る（仮 ID は pending- など adapter ごとに
            // 違い、接頭辞では見分けられない）。届く前に落ちた場合だけ新規として作り直す。
            confirmedSid = liveDelivered.startedSessionId
            session = nil
            acquireTask = nil
        }
        guard !closed, let provider = sessionProvider else { return nil }
        let task = Task { [confirmedSid] in await provider(confirmedSid) }
        acquireTask = task
        let s = await task.value
        session = s
        return s
    }

    /// 握っている session がまだ使えるか。ターミナルを閉じた attach や、pump が終わった
    /// session に送ると誰にも届かず無反応になるので、その場合は取り直す。
    private func isStillUsable(_ s: AgentSession) async -> Bool {
        guard sessionProvider != nil, let subId = subscriberId else { return true }
        if let t = s as? ClaudeTerminalSession, await !t.isTerminalAlive() {
            // pump が entry を片付けるより先に acquire すると死んだ entry を再利用してしまう。
            _ = await SessionHub.shared.closeSession(agentId: agentId ?? "claude", sessionId: t.sessionId)
            WebSocketServer.wslog("inbox: terminal session=\(t.sessionId.prefix(8))… ended → reacquire")
            return false
        }
        // claude --bg の会話は、握っていたプロセスが消えた・「使えない」印が付いたら取り直す（BACKGROUND_CONTROL §7.8）。
        if let b = s as? ClaudeBackgroundSession, await !b.isUsable() {
            _ = await SessionHub.shared.closeSession(agentId: agentId ?? "claude", sessionId: b.sessionId)
            WebSocketServer.wslog("inbox: bg session=\(b.sessionId.prefix(8))… unusable → reacquire")
            return false
        }
        // 起こしている間にワーカーが起きた -p の会話（生成中は取り直さない）。
        if let c = s as? ClaudeCodeSession, c.isStaleForBackground {
            _ = await SessionHub.shared.closeSession(agentId: agentId ?? "claude", sessionId: c.sessionId)
            WebSocketServer.wslog("inbox: session=\(c.sessionId.prefix(8))… started in the background → reacquire")
            return false
        }
        return await SessionHub.shared.holds(subscriberId: subId, session: s)
    }

    /// 送信系メッセージの前処理を、先行分が終わってから順に実行する。
    /// session.send はターン完了まで返らないので work の中では待たないこと（生成中の注入が止まる）。
    private func enqueueOutbound(_ work: @escaping () async -> Void) {
        let previous = outboundTail
        outboundTail = Task {
            _ = await previous?.value
            await work()
        }
    }

    /// metadata に JSON 文字列で入った配列をデコード。失敗時は空。
    static func decodeJsonArray(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }

    /// metadata に JSON 文字列で入ったオブジェクトをデコード。失敗時は空。
    static func decodeJsonObject(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }

    private func handle(_ text: String) {
        guard let send else { return }
        guard let data = text.data(using: .utf8) else { return }
        let event: SessionEvent
        switch InboundFrame.parse(data) {
        case .event(let decoded):
            event = decoded
        case .unknownType(let raw):
            // 新しいアプリ → 古い Bridge。Windows と同じく元の type 名を返し、原因が分かるようにする。
            let name = String(raw.prefix(64))
            if InboundFrame.shouldLogUnknown(name) {
                WebSocketServer.wslog("unknown message type=\(name)")
            }
            send(.unsupported(rawType: name))
            return
        case .malformed:
            // auth-failure と同様、握り潰さずに最小限の手がかりを残す。
            // 生 JSON は秘匿情報を含みうるので先頭 256 文字に切り詰めて記録する。
            let preview = text.count > 256 ? String(text.prefix(256)) + "…" : text
            let redacted = preview.replacingOccurrences(of: "\n", with: " ")
            WebSocketServer.wslog("decode failed len=\(text.count) raw=\(redacted)")
            send(.unsupported(rawType: "decode_failed"))
            return
        }
        let agentId = self.agentId ?? "hermes"
        let sessionId = session?.sessionId ?? ""
        switch event.type {
        case .userMessage:
            if let content = event.content {
                let skills = (event.metadata?["skills"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let attachments = WebSocketServer.decodeAttachments(metadata: event.metadata)
                // 音声会話モードからの送信か（応え方の指示・low effort・遮られた位置の注記）。
                let voice = VoiceTurn(metadata: event.metadata)
                let clientMessageId = event.metadata?["clientMessageId"] ?? event.messageId
                // 送った端末が最後に受け取った seq。古いアプリは送らない（nil = ガードしない）。
                let baseSeq = SessionHub.parseBaseSeq(event.metadata?["baseSeq"])
                let followUp = event.metadata?["followUp"] == "true"
                let typedByUser = fromPairedDevice
                enqueueOutbound {
                    // 新規接続は最初の userMessage まで openSession を遅延している (B1)。
                    // ここで初めて acquire し、以降の sid 算出/ack/notePromptSent はその session 基準。
                    // nil = 先行分を待つ間に WS が閉じた。ID を処理済みにせず抜け、再接続後の outbox 再送で実行させる
                    // （ここで ack・記録まで進めると、閉じた WS に ack を捨てたうえ再送を重複として弾いてしまう）。
                    guard let session = await self.currentOrAcquireSession() else { return }
                    // チャット単位のモデル / Effort / モード。送信より先に渡し、このターンから効かせる。
                    if let overrides = SessionOverrides(metadata: event.metadata) {
                        (session as? SessionOverridable)?.applyOverrides(overrides)
                        // mainagent なら、ここで選んだモードが子のセッションの上限になる。
                        await Orchestrator.shared.noteChatMode(agentId: agentId, sessionId: session.sessionId, mode: overrides.mode)
                    }
                    let sidForHub = session.sessionId
                    // 受領確認を必ず返す → iOS の outbox が消え、再接続での再送が止まる。
                    // 重複（再接続前に届いていた再送）は ack だけ返して実行はスキップ → 二重実行防止。
                    // 初回のみ live buffer に採番・記録し、その seq を ack に載せる
                    // → iOS の lastHistorySeq が送信時点まで進み、差分同期の基準になる。
                    // baseSeq より後に別の端末・ターミナルの入力があれば実行せず input_rejected を返す
                    // （Windows と同じ。クライアントは差分同期してから送り直す。処理済みにはしない）。
                    let decision = await SessionHub.shared.admitUserMessage(
                        agentId: agentId, sessionId: sidForHub, clientMessageId: clientMessageId,
                        content: event.content, messageId: event.messageId,
                        baseSeq: baseSeq, followUp: followUp)
                    switch decision {
                    case .rejected:
                        WebSocketServer.wslog("user_message rejected (conflict) agent=\(agentId) session=\(sidForHub.prefix(8)) baseSeq=\(baseSeq ?? -1)")
                        send(.inputRejected(agentId: agentId, sessionId: sidForHub, clientMessageId: clientMessageId, reason: "conflict"))
                        return
                    case .duplicate:
                        if let cmid = clientMessageId { send(.inputAck(agentId: agentId, sessionId: sidForHub, clientMessageId: cmid)) }
                        return
                    case .accepted(let userSeq):
                        if let cmid = clientMessageId, !cmid.isEmpty {
                            send(.inputAck(agentId: agentId, sessionId: sidForHub, clientMessageId: cmid, seq: userSeq))
                        }
                    }
                    // 履歴復元用に画像バイトを退避（Claude 等はモデルへ placeholder しか渡さず
                    // 履歴がテキスト化するため、ここで実画像を保管し loadHistory で戻す）。
                    for att in attachments where att.kind == .image {
                        await AttachmentStore.shared.put(name: att.name, mime: att.mime, data: att.data)
                    }
                    // プロンプト送信で即「考え中」にする（cold-resume が初回トークン前でも考え中を出せる）。
                    if !sidForHub.isEmpty {
                        await SessionHub.shared.notePromptSent(agentId: agentId, sessionId: sidForHub)
                    }
                    // send はターン完了まで返らないので待たず、起動だけ受信順に行う。
                    Task { await WebSocketServer.dispatch(session, content: content, skills: skills, attachments: attachments, voice: voice, typedByUser: typedByUser) }
                }
            }
        case .queueUserMessage:
            // Mac 側予約キュー: 生成中に積まれた指示を Bridge が預かり、done 後に自動実行する。
            // アイドルだった場合（積む直前に done していたレース）は通常送信へフォールバック。
            if let content = event.content {
                let skills = (event.metadata?["skills"] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let attachments = WebSocketServer.decodeAttachments(metadata: event.metadata)
                // 予約に積んだ分も done 後に音声のターンとして実行する。
                let voice = VoiceTurn(metadata: event.metadata)
                let clientMessageId = event.metadata?["clientMessageId"] ?? event.messageId ?? UUID().uuidString
                let typedByUser = fromPairedDevice
                enqueueOutbound {
                    // nil = WS が閉じた（user_message と同じ）。予約も即実行もせず、再接続後の再送に任せる。
                    guard let session = await self.currentOrAcquireSession() else { return }
                    // 予約分も同じチャットの設定で実行する（反映は各セッションが次のターン / 次の起動で行う）。
                    if let overrides = SessionOverrides(metadata: event.metadata) {
                        (session as? SessionOverridable)?.applyOverrides(overrides)
                        // mainagent なら、ここで選んだモードが子のセッションの上限になる。
                        await Orchestrator.shared.noteChatMode(agentId: agentId, sessionId: session.sessionId, mode: overrides.mode)
                    }
                    let sidForHub = session.sessionId
                    for att in attachments where att.kind == .image {
                        await AttachmentStore.shared.put(name: att.name, mime: att.mime, data: att.data)
                    }
                    let queued = await SessionHub.shared.enqueue(
                        agentId: agentId, sessionId: sidForHub,
                        message: SessionHub.QueuedMessage(
                            clientMessageId: clientMessageId, content: content,
                            skills: skills, attachments: attachments, voice: voice, typedByUser: typedByUser))
                    if queued {
                        send(.queueAck(agentId: agentId, sessionId: sidForHub, clientMessageId: clientMessageId))
                        return
                    }
                    // アイドル → user_message と同じ流れで即実行（冪等化も同じ）。
                    // 既に実行済み（同じ ID の user_message が先に届いた）なら ack だけ返す。
                    guard await SessionHub.shared.shouldProcessUserMessage(clientMessageId: clientMessageId) else {
                        send(.inputAck(agentId: agentId, sessionId: sidForHub, clientMessageId: clientMessageId))
                        return
                    }
                    // 予約として届いたので、Mac 側で実行に移したことを通知して予約カードをユーザーバブルへ
                    // 置き換えさせる（inputAck だけだと旧クライアントは予約を残し、done 後に同じ指示を再送する）。
                    // done 後の自動実行と同じく queue_dispatched として採番し、全購読者へ配る（同じセッションを
                    // 見ている別画面・別端末にもユーザーバブルを出し、replay でも順序を復元させる）。
                    // この接続も購読者なので fan-out で届く。live buffer への記録はこの 1 件だけ。
                    let userSeq = await SessionHub.shared.recordQueueDispatched(
                        agentId: agentId, sessionId: sidForHub,
                        clientMessageId: clientMessageId, content: content)
                    if userSeq == nil {
                        send(.queueDispatched(agentId: agentId, sessionId: sidForHub, clientMessageId: clientMessageId, content: content))
                    }
                    send(.inputAck(agentId: agentId, sessionId: sidForHub, clientMessageId: clientMessageId, seq: userSeq))
                    if !sidForHub.isEmpty {
                        await SessionHub.shared.notePromptSent(agentId: agentId, sessionId: sidForHub)
                    }
                    // send はターン完了まで返らないので待たず、起動だけ受信順に行う。
                    Task { await WebSocketServer.dispatch(session, content: content, skills: skills, attachments: attachments, voice: voice, typedByUser: typedByUser) }
                }
            }
        case .queueRemove:
            if let cmid = event.metadata?["clientMessageId"], !cmid.isEmpty {
                let sid = self.session?.sessionId ?? sessionId
                Task { await SessionHub.shared.removeQueued(agentId: agentId, sessionId: sid, clientMessageId: cmid) }
            }
        case .sessionWarm:
            // チャットを開いた。送る前に裏の CLI を起こしておく（capabilities.warm の agent だけが送ってくる）。
            // 新規接続でもここで acquire する（B1 の「一覧・履歴だけの接続では spawn しない」は変わらない）。
            // user_message と同じ鎖に載せ、直後の送信と 2 本起動しないようにする。上書きは送信と同じく先に渡す。
            let overrides = SessionOverrides(metadata: event.metadata)
            enqueueOutbound {
                guard let session = await self.currentOrAcquireSession() else { return }
                if let overrides { (session as? SessionOverridable)?.applyOverrides(overrides) }
                await session.warm()
            }
        case .interrupt:
            // 遅延 acquire 前なら走っている turn は無いので何もしない (spawn しない)。
            Task { await self.existingSession()?.interrupt() }
        case .stopTaskRequest:
            // 行（カード）ごとの停止（BACKGROUND_CONTROL §3.3）。requestId・taskId が無ければ捨てる。error / unsupported_message は返さない。
            guard let requestId = event.metadata?["requestId"], !requestId.isEmpty,
                  let taskId = event.metadata?["taskId"], !taskId.isEmpty else { break }
            let request = StopTaskRequest(taskId: taskId,
                                          rowId: event.metadata?["rowId"].flatMap { $0.isEmpty ? nil : $0 },
                                          epoch: event.metadata?["epoch"].flatMap { $0.isEmpty ? nil : $0 })
            let sid = self.session?.sessionId ?? event.sessionId ?? sessionId
            Task {
                await WebSocketServer.runStopTask(agentId: agentId, sessionId: sid, requestId: requestId, request: request,
                                                  session: await self.existingSession(), send: send)
            }
        case .listBgSessionsRequest:
            // claude --bg のセッションの一覧（BACKGROUND_CONTROL §7.7）。agentId は見ない（Bridge 全体のもの）。
            Task {
                let jobs = ClaudeBackgroundJobs.shared
                await jobs.ready()
                let rows = await jobs.rows()
                for row in rows { send(.bgSessionItem(json: row.json, sessionId: row.sessionId)) }
                send(.bgSessionListEnd(count: rows.count))
            }
        case .stopBgSessionRequest, .deleteBgSessionRequest:
            // 停止と削除。要求した接続にだけ bg_session_result を返す。
            let op: BgOperation = event.type == .stopBgSessionRequest ? .stop : .delete
            let id = event.metadata?["id"] ?? ""
            let requested = event.sessionId
            Task {
                let result = await ClaudeBackgroundJobs.shared.operate(op, id: id, sessionId: requested)
                send(.bgSessionResult(op: op.rawValue, ok: result.ok, id: id, shells: result.shells,
                                      sessionId: requested, content: result.text))
            }
        case .registerActivityToken:
            // Live Activity の push token（§8.6）。.device の WS からだけ受ける（.local は捨てる）。
            guard case .device(let deviceKeyId, _) = principal else { break }
            let meta = event.metadata ?? [:]
            // 別々の Task で渡すと順が入れ替わりうるので、届いた順の番号を先に振る。
            let order = LiveActivityPublisher.nextSeq()
            if meta["clear"] == "1" {
                let activityId = meta["activityId"] ?? ""
                Task { await LiveActivityPublisher.shared.clear(deviceKeyId: deviceKeyId, activityId: activityId, order: order) }
            } else {
                let token = event.content ?? ""
                Task { await LiveActivityPublisher.shared.register(deviceKeyId: deviceKeyId, token: token, metadata: meta, order: order) }
            }
        case .turnStatusRequest:
            // 生成中固着の能動プローブ。現在のターン状態を再送して、ライブ接続のまま
            // done を取りこぼした spinner を解除させる（idle なら done、進行中なら turn_resume）。
            let sid = self.session?.sessionId ?? event.sessionId ?? sessionId
            if !sid.isEmpty {
                Task { await SessionHub.shared.requestTurnStatus(agentId: agentId, sessionId: sid, send: send) }
            }
        case .listCommandsRequest:
            let adapter = self.adapter
            let session = self.session
            Task {
                guard let adapter else {
                    send(.commandsEnd(agentId: agentId))
                    return
                }
                let commands = await adapter.listCommands(session: session)
                for c in commands {
                    send(.commandItem(agentId: agentId, command: c))
                }
                send(.commandsEnd(agentId: agentId))
            }
        case .agentInfoRequest:
            let adapter = self.adapter
            let session = self.session
            let infoCwd = event.metadata?["cwd"] ?? self.cwd
            Task {
                guard let adapter else { return }
                let info = await adapter.currentInfo(session: session)
                // cwd の git ブランチを引いて相乗りで返す（iOS 最下部バー用）。git 管理外は nil。
                let branch = await GitInfoReader.branch(cwd: infoCwd)
                send(.agentInfoResult(
                    agentId: agentId,
                    model: info?.model,
                    provider: info?.provider,
                    supportedReasoningEfforts: info?.supportedReasoningEfforts,
                    reasoningEffort: info?.reasoningEffort,
                    codexMode: info?.codexMode,
                    approvalPolicy: info?.approvalPolicy,
                    sandboxMode: info?.sandboxMode,
                    gitBranch: branch,
                    cwd: infoCwd
                ))
            }
        case .setModelRequest:
            let adapter = self.adapter
            let session = self.session
            let model = event.metadata?["model"] ?? ""
            let provider = event.metadata?["provider"]
            let reasoningEffort = event.metadata?["reasoningEffort"] ?? event.metadata?["effort"]
            let codexMode = event.metadata?["codexMode"] ?? event.metadata?["mode"]
            Task {
                guard let adapter else {
                    send(.setModelResult(agentId: agentId, ok: false, message: "adapter unavailable"))
                    return
                }
                do {
                    try await adapter.setModel(model: model, provider: provider, reasoningEffort: reasoningEffort, codexMode: codexMode, session: session)
                    send(.setModelResult(agentId: agentId, ok: true, message: nil))
                    let info = await adapter.currentInfo(session: session)
                    send(.agentInfoResult(
                        agentId: agentId,
                        model: info?.model,
                        provider: info?.provider,
                        supportedReasoningEfforts: info?.supportedReasoningEfforts,
                        reasoningEffort: info?.reasoningEffort,
                        codexMode: info?.codexMode,
                        approvalPolicy: info?.approvalPolicy,
                        sandboxMode: info?.sandboxMode
                    ))
                } catch {
                    send(.setModelResult(agentId: agentId, ok: false, message: "\(error)"))
                }
            }
        case .actionResponse:
            let requestId = event.metadata?["requestId"] ?? event.messageId ?? ""
            let decision = event.metadata?["decision"] ?? event.content ?? ""
            guard !requestId.isEmpty else {
                send(.unsupported(rawType: "action_response_missing_request_id"))
                return
            }
            let answers = event.metadata ?? [:]
            let session = self.session
            Task {
                // mainagent の承認カード（Bridge が出したもの）への返事は Orchestrator が受け取る。
                if await Orchestrator.shared.resolveApproval(requestId: requestId, decision: decision) { return }
                await session?.respondToAction(requestId: requestId, decision: decision, answers: answers)
                // mainagent が頼んだ子の承認なら、mainagent 側の「承認待ち」も外す。
                await Orchestrator.shared.noteApprovalAnswered(agentId: agentId, requestId: requestId)
            }
        case .listModelsRequest:
            let adapter = self.adapter
            let session = self.session
            Task {
                guard let adapter else {
                    send(.modelsEnd(agentId: agentId))
                    return
                }
                let providers = await adapter.listAvailableModels(session: session)
                for p in providers {
                    send(.modelProviderItem(agentId: agentId, provider: p))
                }
                send(.modelsEnd(agentId: agentId))
                // 一覧取得で session が確立した場合（opencode は listAvailableModels 内で
                // bootstrap する）、現在モデルが読めるようになる。header の選択中バッジを
                // 更新するため agentInfo を再送する。
                let info = await adapter.currentInfo(session: session)
                send(.agentInfoResult(
                    agentId: agentId,
                    model: info?.model,
                    provider: info?.provider,
                    supportedReasoningEfforts: info?.supportedReasoningEfforts,
                    reasoningEffort: info?.reasoningEffort,
                    codexMode: info?.codexMode,
                    approvalPolicy: info?.approvalPolicy,
                    sandboxMode: info?.sandboxMode
                ))
            }
        case .ping:
            send(SessionEvent(
                type: .pong, agentId: agentId, sessionId: sessionId,
                messageId: nil, toolUseId: nil, content: nil,
                toolName: nil, metadata: nil
            ))
        case .listSessionsRequest:
            let limit = Int(event.metadata?["limit"] ?? "") ?? 50
            let cwd = event.metadata?["cwd"] ?? self.cwd
            let adapter = self.adapter
            Task {
                guard let adapter else {
                    send(.sessionListEnd(agentId: agentId))
                    return
                }
                let sessions = await adapter.listSessions(limit: limit, cwd: cwd)
                // 現在生成中の session を1回だけ引き、各 item に running フラグを載せる。
                var generating = await SessionHub.shared.generatingSessionIds(agentId: agentId)
                // ターミナル側でターン進行中の session も running（hook の UserPromptSubmit〜Stop）。
                // 承認や質問への回答待ち（選択肢を出して止まっている）session には awaiting を載せる。
                var awaitingIds = await SessionHub.shared.awaitingSessionIds(agentId: agentId)
                // ターンの後もサブエージェントか dynamic workflow が動いている session には background を載せる
                // （開いていないチャットでもサイドバーで稼働中に見せる。running とは別。コマンドだけでは載せない）。
                var backgroundIds = await SessionHub.shared.backgroundSessionIds(agentId: agentId)
                if agentId == "claude" {
                    generating.formUnion(await ClaudeTerminalRegistry.shared.generatingSessionIds())
                    awaitingIds.formUnion(await ClaudeTerminalRegistry.shared.awaitingSessionIds())
                    backgroundIds.formUnion(await ClaudeTerminalRegistry.shared.backgroundSessionIds())
                }
                for var summary in sessions {
                    let running = generating.contains(summary.sessionId)
                    let awaiting = awaitingIds.contains(summary.sessionId)
                    // metadata["background"] = "1"（running / awaiting と同じ書き方）。
                    let background: [String: String] = backgroundIds.contains(summary.sessionId) ? ["background": "1"] : [:]
                    // 音声会話モードのフォールバック（本文末尾の `<voice-context>`）が一覧のタイトルに残った場合。
                    if summary.title.contains("<v") {
                        summary = SessionSummary(
                            sessionId: summary.sessionId,
                            title: VoiceTurn.stripContext(summary.title),
                            lastActive: summary.lastActive,
                            messageCount: summary.messageCount,
                            cwd: summary.cwd,
                            terminal: summary.terminal
                        )
                    }
                    // override されたタイトルがあれば差し替えてから送る
                    if let custom = await SessionOverrideStore.shared.customTitle(
                        agentId: agentId, sessionId: summary.sessionId
                    ) {
                        let patched = SessionSummary(
                            sessionId: summary.sessionId,
                            title: custom,
                            lastActive: summary.lastActive,
                            messageCount: summary.messageCount,
                            cwd: summary.cwd,
                            terminal: summary.terminal
                        )
                        send(.sessionListItem(agentId: agentId, summary: patched, running: running, awaiting: awaiting)
                                .addingMetadata(background))
                    } else {
                        send(.sessionListItem(agentId: agentId, summary: summary, running: running, awaiting: awaiting)
                                .addingMetadata(background))
                    }
                }
                send(.sessionListEnd(agentId: agentId))
            }
        case .renameSessionRequest:
            guard let sid = event.sessionId else {
                send(.unsupported(rawType: "rename_missing_session_id"))
                return
            }
            let newTitle = event.content ?? ""
            Task {
                await SessionOverrideStore.shared.setTitle(
                    agentId: agentId, sessionId: sid, title: newTitle.isEmpty ? nil : newTitle
                )
                let resolved = (await SessionOverrideStore.shared.customTitle(
                    agentId: agentId, sessionId: sid
                )) ?? ""
                send(.renameSessionResult(agentId: agentId, sessionId: sid, title: resolved, ok: true))
                // claude --bg の行の title に使われるので、読み直して変化を送る（§7.6 の 3）。
                if agentId == "claude" { await ClaudeBackgroundJobs.shared.refresh() }
            }
        case .loadHistoryRequest:
            guard let sid = event.sessionId else {
                send(.unsupported(rawType: "load_history_missing_session_id"))
                return
            }
            let adapter = self.adapter
            let liveDelivered = self.liveDelivered
            let sinceSeq = Int(event.metadata?["sinceSeq"] ?? "")
            Task {
                guard let adapter else {
                    send(.loadHistoryEnd(agentId: agentId, sessionId: sid))
                    return
                }
                // 差分同期 (Windows の liveHistory.delta と同形): クライアントが
                // sinceSeq を知っていて live buffer に続きがあれば、採番済みイベントを
                // そのまま replay して全履歴の再読込を省く。buffer が途切れていたら
                // （古すぎ/プロセス再起動後）従来の全履歴 + クライアント側 dedup に落ちる。
                if let since = sinceSeq {
                    let delta = await SessionHub.shared.liveDelta(agentId: agentId, sessionId: sid, sinceSeq: since)
                    if !delta.isEmpty {
                        // acquire 後にこの接続へ live で届け済みの分は再送しない（delta の二重追記・done の再処理を防ぐ）。
                        for ev in delta where !liveDelivered.contains(ev) { send(ev) }
                        let latest = await SessionHub.shared.latestSeq(agentId: agentId, sessionId: sid)
                        send(.loadHistoryEnd(agentId: agentId, sessionId: sid, latestSeq: latest))
                        return
                    }
                    // 差分が空: 今の entry が sinceSeq の時点から見続けていて（バッファが sinceSeq を含む）、
                    // sinceSeq が最新採番と一致するなら新着は無い。全履歴を送るとライブで受け取り済みの
                    // 発言が末尾に重複するので、終端だけ返す。entry が無い・作り直された（sinceSeq がこの entry の
                    // 作成時点以前。seq は続き番号だが、その間にターミナル等で進んだ分は hub を通っていない）・
                    // seq が巻き戻った（sinceSeq > lastSeq）場合は下の全履歴へ落とす。
                    let coverage = await SessionHub.shared.deltaCoverage(agentId: agentId, sessionId: sid, sinceSeq: since)
                    if coverage.entryExists, since == coverage.lastSeq,
                       let first = coverage.firstBufferedSeq, first <= since + 1 {
                        send(.loadHistoryEnd(agentId: agentId, sessionId: sid, latestSeq: coverage.lastSeq))
                        return
                    }
                }
                let messages = await adapter.loadHistory(sessionId: sid)
                // 履歴が長すぎると読み取り時に重く/クラッシュするため、末尾(最新)N件だけ送る。
                // metadata.maxMessages で上書き可能（0 で無制限）。
                let maxMessages = Int(event.metadata?["maxMessages"] ?? "") ?? 100
                let limited = (maxMessages > 0 && messages.count > maxMessages)
                    ? Array(messages.suffix(maxMessages))
                    : messages
                for m in limited {
                    let enriched = await WebSocketServer.enrichHistory(message: m)
                    send(.historyMessage(
                        agentId: agentId, sessionId: sid,
                        role: enriched.role, content: enriched.content,
                        messageId: enriched.messageId, attachments: enriched.attachments
                    ))
                }
                let latest = await SessionHub.shared.latestSeq(agentId: agentId, sessionId: sid)
                send(.loadHistoryEnd(agentId: agentId, sessionId: sid, latestSeq: latest))
            }
        case .listCronJobsRequest:
            let adapter = self.adapter
            WebSocketServer.wslog("cron.list request agent=\(agentId)")
            Task {
                guard let adapter else {
                    WebSocketServer.wslog("cron.list no_adapter")
                    send(.cronJobListEnd(agentId: agentId))
                    return
                }
                let jobs = await adapter.listCronJobs()
                WebSocketServer.wslog("cron.list response count=\(jobs.count)")
                for job in jobs {
                    send(.cronJobItem(agentId: agentId, job: job))
                }
                send(.cronJobListEnd(agentId: agentId))
            }
        case .createCronRequest:
            let adapter = self.adapter
            let meta = event.metadata ?? [:]
            let spec = CronCreateSpec(
                name: meta["name"],
                schedule: meta["schedule"] ?? "",
                prompt: event.content ?? "",
                deliver: meta["deliver"],
                repeatCount: meta["repeat"].flatMap { Int($0) },
                // Bridge 内蔵 cron (claude/codex) 用。未指定なら接続中の作業フォルダを引き継ぐ。
                cwd: meta["cwd"] ?? self.cwd,
                permissionMode: meta["permissionMode"]
            )
            WebSocketServer.wslog("cron.create name=\(spec.name ?? "-") schedule='\(spec.schedule)' prompt.len=\(spec.prompt.count) deliver=\(spec.deliver ?? "-") repeat=\(spec.repeatCount.map(String.init) ?? "-")")
            Task {
                guard let adapter else {
                    WebSocketServer.wslog("cron.create no_adapter")
                    send(.cronJobResult(agentId: agentId, op: "create", jobId: nil, ok: false, message: "adapter unavailable"))
                    return
                }
                if spec.schedule.isEmpty {
                    WebSocketServer.wslog("cron.create reject empty_schedule")
                    send(.cronJobResult(agentId: agentId, op: "create", jobId: nil, ok: false, message: "schedule is required"))
                    return
                }
                do {
                    let jid = try await adapter.createCronJob(spec: spec)
                    WebSocketServer.wslog("cron.create ok id=\(jid)")
                    send(.cronJobResult(agentId: agentId, op: "create", jobId: jid, ok: true, message: "ok"))
                } catch {
                    WebSocketServer.wslog("cron.create FAIL: \(error.localizedDescription)")
                    send(.cronJobResult(agentId: agentId, op: "create", jobId: nil, ok: false, message: error.localizedDescription))
                }
            }
        case .deleteCronRequest:
            let adapter = self.adapter
            guard let jid = event.sessionId else {
                send(.cronJobResult(agentId: agentId, op: "delete", jobId: nil, ok: false, message: "jobId is required"))
                return
            }
            Task {
                guard let adapter else {
                    send(.cronJobResult(agentId: agentId, op: "delete", jobId: jid, ok: false, message: "adapter unavailable"))
                    return
                }
                do {
                    try await adapter.deleteCronJob(jobId: jid)
                    send(.cronJobResult(agentId: agentId, op: "delete", jobId: jid, ok: true, message: "ok"))
                } catch {
                    send(.cronJobResult(agentId: agentId, op: "delete", jobId: jid, ok: false, message: error.localizedDescription))
                }
            }
        case .registerPushToken:
            // 宛先は「その端末」の行に入れる（.device(D) の WS からだけ。.local からは無視。§14.1）。
            // metadata.deviceId は読まない（端末はトンネルの鍵で決まっている）。
            if let token = event.content, case .device(let deviceKeyId, _) = principal {
                let environment = event.metadata?["environment"] ?? "development"
                let locale = event.metadata?["locale"] ?? "ja"
                Task { _ = await PushService.shared.registerToken(token, environment: environment, locale: locale, deviceKeyId: deviceKeyId) }
            }
        case .registerE2EKey:
            // v3 では受け付けない。端末の鍵はペアリングでしか決まらない（§13.6）。
            send(SessionEvent(
                type: .e2eRegisterResult, agentId: agentId, sessionId: nil,
                messageId: nil, toolUseId: nil, content: nil,
                toolName: nil, metadata: ["ok": "0", "reason": "unsupported"]
            ))
        case .e2eConfirm:
            // 鍵確認専用フレーム（§13.6）。open 成功自体が確認なので応答は不要。
            break
        case .usageRequest:
            // iOS の手動リフレッシュ。取得後 broadcast されるので追加の送信は不要。
            Task { await UsageHub.shared.requestRefresh() }
        case .sitesRequest:
            // 要求した端末にだけ返す。CLI は数秒〜数十秒かかるので読み取りは別のタスクで（受信を止めない）。
            let force = event.metadata?["force"] == "1"
            Task {
                let list = await SitesHub.shared.list(force: force)
                send(.sitesReport(list))
            }
        case .heartbeatGet:
            Task { send(await MainHeartbeat.shared.statusEvent()) }
        case .heartbeatSet:
            // 足りない項目は今の値のまま。返事（と全クライアントへの知らせ）は MainHeartbeat が出す。
            let patch = event.content ?? "{}"
            Task { send(await MainHeartbeat.shared.updateSettings(json: patch)) }
        case .heartbeatRunNow:
            Task { send(await MainHeartbeat.shared.runNow()) }
        case .cronOutputsRequest:
            guard let jid = event.sessionId else {
                send(.unsupported(rawType: "cron_outputs_missing_job_id"))
                return
            }
            // jobId はディレクトリ名と SQL に入るので形を確かめる（../ や ' を通さない）。
            guard CronOutputHub.isValidJobId(jid) else {
                send(.unsupported(rawType: "cron_outputs_invalid_job_id"))
                return
            }
            let limit = max(1, min(500, Int(event.metadata?["limit"] ?? "") ?? 200))
            Task {
                let outputs = await CronOutputHub.loadPastOutputsOffPool(jobId: jid, limit: limit)
                for e in outputs { send(e) }
                send(.cronOutputsEnd(agentId: agentId, jobId: jid))
            }
        case .listSkillsRequest:
            let cwd = event.metadata?["cwd"] ?? self.cwd
            Task {
                let items = SkillsService.list(cwd: cwd, agentId: agentId)
                for s in items {
                    send(.skillItem(agentId: agentId, summary: s))
                }
                send(.skillsEnd(agentId: agentId))
            }
        case .loadSkillRequest:
            let cwd = event.metadata?["cwd"] ?? self.cwd
            let name = event.metadata?["name"] ?? ""
            Task {
                let content = SkillsService.load(cwd: cwd, name: name, agentId: agentId) ?? ""
                send(.skillContent(agentId: agentId, name: name, content: content))
            }
        case .saveSkillRequest:
            let cwd = event.metadata?["cwd"] ?? self.cwd
            let name = event.metadata?["name"] ?? ""
            let body = event.content ?? ""
            // opencode skills は read-only。
            if agentId == "opencode" {
                send(.skillOpResult(agentId: agentId, op: "save", name: name, ok: false, message: "opencode skills are read-only"))
                return
            }
            Task {
                let (ok, msg) = SkillsService.save(cwd: cwd, name: name, content: body, agentId: agentId)
                send(.skillOpResult(agentId: agentId, op: "save", name: name, ok: ok, message: msg))
                if ok {
                    // 保存後に最新リストを返してクライアントが diff せずに済むようにする
                    let items = SkillsService.list(cwd: cwd, agentId: agentId)
                    for s in items {
                        send(.skillItem(agentId: agentId, summary: s))
                    }
                    send(.skillsEnd(agentId: agentId))
                }
            }
        case .deleteSkillRequest:
            let cwd = event.metadata?["cwd"] ?? self.cwd
            let name = event.metadata?["name"] ?? ""
            // opencode skills は read-only。
            if agentId == "opencode" {
                send(.skillOpResult(agentId: agentId, op: "delete", name: name, ok: false, message: "opencode skills are read-only"))
                return
            }
            Task {
                let (ok, msg) = SkillsService.delete(cwd: cwd, name: name, agentId: agentId)
                send(.skillOpResult(agentId: agentId, op: "delete", name: name, ok: ok, message: msg))
            }
        case .agentLoginRequest:
            Task { await self.handleAgentLogin(event, send: send) }
        case .extensionsShareRequest:
            let meta = event.metadata ?? [:]
            Task {
                let content: String
                if meta["op"] == "sync" {
                    let r = ExtensionsShare.sync(items: Self.decodeJsonArray(meta["items"]), targets: Self.decodeJsonArray(meta["targets"]))
                    content = ExtensionsShare.json(r)
                } else {
                    content = ExtensionsShare.json(ExtensionsShare.list())
                }
                send(SessionEvent(
                    type: .extensionsShareResult, agentId: agentId, sessionId: nil,
                    messageId: nil, toolUseId: nil, content: content,
                    toolName: nil, metadata: ["op": meta["op"] ?? "list"]
                ))
            }
        case .listProjectsRequest, .addProjectRequest, .removeProjectRequest, .reorderProjectsRequest:
            let meta = event.metadata ?? [:]
            let type = event.type
            Task {
                let items: [SharedProject]
                switch type {
                case .addProjectRequest: items = ProjectRegistry.add(path: meta["path"] ?? "", name: meta["name"])
                case .removeProjectRequest:
                    // 「メイン」（mainagent のフォルダ）は消せない。今の一覧を返して、画面を元に戻させる。
                    items = MainAgentWorkspace.isMainWorkspace(meta["path"])
                        ? ProjectRegistry.list() : ProjectRegistry.remove(path: meta["path"] ?? "")
                case .reorderProjectsRequest: items = ProjectRegistry.reorder(paths: Self.decodeJsonArray(meta["paths"]))
                default: items = ProjectRegistry.list()
                }
                for p in items { send(.projectItem(agentId: agentId, project: p)) }
                send(.projectsEnd(agentId: agentId))
            }
        case .listMcpServersRequest:
            Task {
                let items = McpService.list(agentId: agentId)
                for m in items {
                    send(.mcpServerItem(agentId: agentId, summary: m))
                }
                send(.mcpServersEnd(agentId: agentId))
            }
        case .registerMcpServerRequest:
            let meta = event.metadata ?? [:]
            let serverName = meta["serverName"] ?? ""
            let spec = McpRegisterSpec(
                serverName: serverName,
                transportKind: meta["transportKind"] ?? "url",
                url: meta["url"],
                command: meta["command"],
                args: Self.decodeJsonArray(meta["args"]),
                env: Self.decodeJsonObject(meta["env"])
            )
            Task {
                let (ok, msg) = McpService.register(agentId: agentId, spec: spec)
                send(.mcpServerOpResult(agentId: agentId, op: "register", serverName: serverName, ok: ok, message: msg))
                if ok {
                    let items = McpService.list(agentId: agentId)
                    for m in items { send(.mcpServerItem(agentId: agentId, summary: m)) }
                    send(.mcpServersEnd(agentId: agentId))
                }
            }
        case .deleteMcpServerRequest:
            let serverName = event.metadata?["serverName"] ?? ""
            Task {
                let (ok, msg) = McpService.delete(agentId: agentId, serverName: serverName)
                send(.mcpServerOpResult(agentId: agentId, op: "delete", serverName: serverName, ok: ok, message: msg))
                if ok {
                    let items = McpService.list(agentId: agentId)
                    for m in items { send(.mcpServerItem(agentId: agentId, summary: m)) }
                    send(.mcpServersEnd(agentId: agentId))
                }
            }
        case .pauseCronRequest, .resumeCronRequest:
            let adapter = self.adapter
            let op = event.type == .pauseCronRequest ? "pause" : "resume"
            guard let jid = event.sessionId else {
                send(.cronJobResult(agentId: agentId, op: op, jobId: nil, ok: false, message: "jobId is required"))
                return
            }
            Task {
                // 結果を返さないと iOS が楽観的に変えた一時停止表示が戻らない（create/delete と同じ扱い）。
                guard let adapter else {
                    send(.cronJobResult(agentId: agentId, op: op, jobId: jid, ok: false, message: "adapter unavailable"))
                    return
                }
                do {
                    if op == "pause" { try await adapter.pauseCronJob(jobId: jid) }
                    else { try await adapter.resumeCronJob(jobId: jid) }
                    send(.cronJobResult(agentId: agentId, op: op, jobId: jid, ok: true, message: "ok"))
                } catch {
                    send(.cronJobResult(agentId: agentId, op: op, jobId: jid, ok: false, message: error.localizedDescription))
                }
            }
        default:
            send(.unsupported(rawType: event.type.rawValue))
        }
    }
}


/// hook / curl からの小さな JSON を型に縛らず受けるための最小デコーダ。
struct AnyCodableValue: Decodable {
    let stringValue: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { stringValue = s }
        else if let i = try? c.decode(Int.self) { stringValue = String(i) }
        else if let d = try? c.decode(Double.self) { stringValue = String(d) }
        else if let b = try? c.decode(Bool.self) { stringValue = String(b) }
        else { stringValue = nil }
    }
}

/// 結果を一度だけ渡す箱。先に finish した方が continuation を resume する。
private final class StopTaskRace: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<StopTaskOutcome, Never>?
    private var done = false

    func install(_ c: CheckedContinuation<StopTaskOutcome, Never>) {
        lock.lock(); cont = c; lock.unlock()
    }

    @discardableResult
    func finish(_ outcome: StopTaskOutcome) -> Bool {
        lock.lock()
        if done { lock.unlock(); return false }
        done = true
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: outcome)
        return true
    }
}
