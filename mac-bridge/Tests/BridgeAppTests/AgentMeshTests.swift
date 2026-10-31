import Darwin
import Foundation
import Vapor
import XCTest
@testable import BridgeApp

/// エージェントどうしで頼み合う。
/// どのセッションからも頼める（設定・深さ・鎖）、別の PC に頼む（A 側の転送・B 側の口）、すべての PC の一覧。
/// 子のセッションは OrchestratorTests と同じく ScriptedAdapter で作り、本番と同じ SessionHub を通す。
final class AgentMeshTests: XCTestCase {
    private var app: Application!
    private var port = 0
    private var root: URL!
    private let localKey = "local-key-0123456789"
    private let adminKey = "bda_" + String(repeating: "C", count: 43)
    private let phoneKey = "MESHPHONEKEY000000000A"
    private let phoneCred = "bdc_mesh_phone"
    private let otherKey = "MESHOTHERKEY000000000A"
    private let otherCred = "bdc_mesh_other"

    override func setUp() async throws {
        root = try makeTempDir("agent-mesh")
        BuddyPaths.setOverride(root)
        DeviceStore.shared.load()
        LocalKey.shared.replace(localKey)
        AdminKey.shared.resetForTesting(adminKey)
        addConfirmed(phoneKey, cred: phoneCred)
        addConfirmed(otherKey, cred: otherCred)

        app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.middleware.use(BridgeRequestGuard.Middleware())
        app.middleware.use(BridgeAuth.Middleware())
        AgentMeshRoutes.register(app: app)
        try await app.server.start()
        port = app.http.server.shared.localAddress?.port ?? 0
        XCTAssertGreaterThan(port, 0)
    }

    override func tearDown() async throws {
        await Orchestrator.shared.setRemotePCs([])
        RemoteOrchestratorClient.transportOverride = nil
        await app.server.shutdown()
        try await app.asyncShutdown()
        AdminKey.shared.resetForTesting(nil)
        LocalKey.shared.invalidate()
        BuddyPaths.setOverride(nil)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 道具立て

    private func uniq(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())" }

    private func addConfirmed(_ key: String, cred: String) {
        let row = DeviceStore.Device(pub: "p", clientDeviceId: "cid-\(key)", name: "Device", label: nil, platform: "mac",
                                     credHash: TunnelV3.credentialHash(cred), via: "qr",
                                     createdAt: DeviceStore.nowMs(), lastSeenAt: nil, push: nil)
        XCTAssertTrue(DeviceStore.shared.insertPending(deviceKeyId: key, device: row, epoch: DeviceStore.shared.epoch))
        XCTAssertTrue(DeviceStore.shared.confirmPending(deviceKeyId: key, credHash: row.credHash, epoch: DeviceStore.shared.epoch))
    }

    private func tmpDir() throws -> URL { try makeTempDir(uniq("mesh")) }

    /// 生の HTTP/1.1 を 1 本送る（PhoneApprovalTests と同じ）。`device` があれば、この接続をその端末のトンネルとして扱う。
    private func request(_ path: String, method: String = "GET", headers: [(String, String)] = [],
                         body: Any? = nil, device: String? = nil) async throws -> (status: Int, json: Any?) {
        let port = self.port
        let payload = try body.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) } ?? ""
        return try await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
            var local = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            let localPort = UInt16(bigEndian: local.sin_port)
            let connId = UUID().uuidString
            if let device { TunnelPeers.shared.register(localPort: localPort, peer: .init(deviceKeyId: device, connectionId: connId)) }
            defer { if device != nil { TunnelPeers.shared.remove(localPort: localPort, connectionId: connId) } }
            var lines = ["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:\(port)", "Connection: close"]
            for (k, v) in headers { lines.append("\(k): \(v)") }
            if method != "GET" {
                lines.append("Content-Type: application/json")
                lines.append("Content-Length: \(payload.utf8.count)")
            }
            let req = lines.joined(separator: "\r\n") + "\r\n\r\n" + payload
            _ = req.withCString { send(fd, $0, strlen($0), 0) }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            let text = String(decoding: out, as: UTF8.self)
            let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
            let bodyText = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
            return (status, try? JSONSerialization.jsonObject(with: Data(bodyText.utf8)))
        }.value
    }

    private func bearer(_ v: String) -> (String, String) { ("Authorization", "Bearer \(v)") }
    private var admin: [(String, String)] { [bearer(localKey), ("X-BuddyOS-Admin", adminKey)] }

    /// mainagent 役（iPhone 1 台が見ている）と、その合鍵。承認カードはこの接続に届く。
    private func mainagent() async -> (Orchestrator.Caller, TestConnection) {
        let agent = uniq("main")
        let sid = uniq("msid")
        let adapter = ScriptedAdapter(id: agent) { s in ScriptedSession(agentId: agent, sessionId: s ?? sid) }
        await AgentRegistry.shared.register(adapter)
        let conn = await TestConnection.open(adapter, sessionId: sid)
        let token = await Orchestrator.shared.issueToken(agentId: agent, parentSessionId: sid)
        return (Orchestrator.Caller(token: token, agentId: agent, parentSessionId: sid), conn)
    }

    /// 開かれたときの OrchestratorContext.openingDepth を控え、"echo: <本文>" を返す台本。gate があれば最初の返事の途中で止まる。
    private func scripted(_ agentId: String, realId: String, gate: Gate? = nil, depths: DepthBox? = nil,
                          modes: [String] = []) async -> ScriptedAdapter {
        let adapter = ScriptedAdapter(id: agentId) { sid in
            depths?.add(OrchestratorContext.openingDepth)
            let s = ScriptedSession(agentId: agentId, sessionId: sid ?? "pending-\(UUID().uuidString.prefix(8))")
            s.onSend = { s, text, n in
                if n == 1, sid == nil { s.emit(.sessionStarted(agentId: agentId, sessionId: realId)) }
                s.emit(.assistantDelta("echo: \(text)", agentId: agentId, sessionId: realId, messageId: "m-\(n)"))
                if n == 1, let gate { await gate.wait() }
                s.emit(.done(agentId: agentId, sessionId: realId, messageId: "m-\(n)"))
            }
            return s
        }
        adapter.modesForTesting = modes
        await AgentRegistry.shared.register(adapter)
        return adapter
    }

    final class DepthBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Int?] = []
        func add(_ v: Int?) { lock.withLock { _values.append(v) } }
        var values: [Int?] { lock.withLock { _values } }
    }

    private func sessionsRow(_ e: SessionEvent, agent: String) -> [String: Any]? {
        guard e.type == .workflowProgress, let d = e.content?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              obj["kind"] as? String == "sessions" else { return nil }
        return (obj["agents"] as? [[String: Any]])?.first { $0["agentId"] as? String == agent }
    }

    /// n 枚目（0 始まり）の承認カードに、iPhone と同じ action_response で答える。
    @discardableResult
    private func answerNth(_ conn: TestConnection, _ caller: Orchestrator.Caller, _ n: Int, _ decision: String) async throws -> SessionEvent {
        _ = try await conn.until("\(n + 1) 枚目の承認カード") { _ in conn.events.filter { $0.type == .actionRequest }.count > n }
        let card = conn.events.filter { $0.type == .actionRequest }[n]
        let id = card.messageId ?? ""
        await conn.send(["type": "action_response", "agentId": caller.agentId, "sessionId": caller.parentSessionId ?? "",
                         "messageId": id, "content": decision, "metadata": ["requestId": id, "decision": decision]])
        return card
    }

    private func toolCall(_ name: String, _ args: [String: Any], _ caller: Orchestrator.Caller) async -> (value: Any?, error: Orchestrator.ToolError?) {
        do { return (try await McpEndpoint.call(name, args: args, caller: caller), nil) } catch let e as Orchestrator.ToolError {
            return (nil, e)
        } catch {
            return (nil, Orchestrator.ToolError("\(error)"))
        }
    }

    // MARK: - 設定と合鍵

    func testSettingsDefaultOnAndGrantFollowsIt() async throws {
        let dir = try tmpDir()
        XCTAssertTrue(OrchestratorSettings.allSessions, "ファイルが無ければ有効")
        let grant = await Orchestrator.shared.sessionGrant(agentId: "claude", sessionId: nil, cwd: dir.path, unattended: false)
        XCTAssertEqual(grant?.isMain, false, "ふつうのセッションにも渡す（書く道具は外さない）")
        XCTAssertEqual(grant?.depth, 0)
        if let t = grant?.token { await Orchestrator.shared.revoke(token: t) }
        let cron = await Orchestrator.shared.sessionGrant(agentId: "claude", sessionId: nil, cwd: dir.path, unattended: true)
        XCTAssertNil(cron, "無人実行には渡さない")

        try OrchestratorSettings.setAllSessions(false)
        XCTAssertFalse(OrchestratorSettings.allSessions)
        let attrs = try FileManager.default.attributesOfItem(atPath: OrchestratorSettings.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let off = await Orchestrator.shared.sessionGrant(agentId: "claude", sessionId: nil, cwd: dir.path, unattended: false)
        XCTAssertNil(off, "切ったらふつうのセッションには渡さない")
        let main = await Orchestrator.shared.sessionGrant(agentId: "claude", sessionId: nil,
                                                         cwd: MainAgentWorkspace.defaultURL.path, unattended: false)
        XCTAssertEqual(main?.isMain, true, "mainagent のフォルダは設定に関わらず今までどおり")
        if let t = main?.token { await Orchestrator.shared.revoke(token: t) }

        // 管理鍵の口。
        var r = try await request("/local/orchestrator/settings", headers: admin)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual((r.json as? [String: Any])?["allSessions"] as? Bool, false)
        r = try await request("/local/orchestrator/settings", method: "POST", headers: admin, body: ["allSessions": true])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual((r.json as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertTrue(OrchestratorSettings.allSessions)
        r = try await request("/local/orchestrator/settings", method: "POST", headers: admin, body: ["allSessions": "yes"])
        XCTAssertEqual(r.status, 400)
        r = try await request("/local/orchestrator/settings", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 401, "ローカル鍵だけでは触れない")
    }

    func testGrantDepthComesFromTheOpeningChild() async throws {
        let dir = try tmpDir()
        let o = Orchestrator.shared
        let one = await OrchestratorContext.$openingDepth.withValue(1) {
            await o.sessionGrant(agentId: "codex", sessionId: nil, cwd: dir.path, unattended: false)
        }
        XCTAssertEqual(one?.depth, 1, "子は深さ 1 の合鍵")
        let caller = await o.caller(token: one?.token ?? "")
        XCTAssertEqual(caller?.depth, 1)
        let two = await OrchestratorContext.$openingDepth.withValue(2) {
            await o.sessionGrant(agentId: "codex", sessionId: nil, cwd: dir.path, unattended: false)
        }
        XCTAssertNil(two, "孫（深さ 2）には渡さない")
        let explicit = await o.sessionGrant(agentId: "codex", sessionId: nil, cwd: dir.path, unattended: false, depth: 2)
        XCTAssertNil(explicit)
        if let t = one?.token { await o.revoke(token: t) }
    }

    // MARK: - ふつうのセッションから頼む・深さ・鎖

    func testOrdinarySessionDelegatesWithItsOwnCapAndDepthAndCycleIsRefused() async throws {
        let dir = try tmpDir()
        let childAgent = uniq("child")
        let childReal = uniq("csid")
        let grandAgent = uniq("grand")
        let grandReal = uniq("gsid")
        let gate = Gate()
        let childDepths = DepthBox()
        let grandDepths = DepthBox()
        let childAdapter = await scripted(childAgent, realId: childReal, gate: gate, depths: childDepths)
        _ = await scripted(grandAgent, realId: grandReal, depths: grandDepths, modes: ["plan", "edit", "auto"])

        // mainagent が子を起こす。子は深さ 1 で開かれる（adapter はこの深さで合鍵を発行する）。
        let (main, mainConn) = await mainagent()
        async let starting = Orchestrator.shared.startSession(caller: main, agentId: childAgent, cwd: dir.path, prompt: "work")
        try await answerNth(mainConn, main, 0, "allow")
        _ = try await starting
        XCTAssertEqual(childDepths.values, [1])

        // 子（ふつうのセッション、深さ 1 の合鍵）が、頼まれた仕事の途中でさらに頼む。
        let childToken = await Orchestrator.shared.issueToken(agentId: childAgent, parentSessionId: childReal,
                                                              isMain: false, depth: 1)
        let childCaller = await Orchestrator.shared.caller(token: childToken)
        let child = try XCTUnwrap(childCaller)

        // 自分に頼んだ mainagent（同じ鎖の祖先）へは送れない。
        do {
            _ = try await Orchestrator.shared.sendMessage(caller: child, agentId: main.agentId,
                                                          sessionId: main.parentSessionId ?? "", text: "loop")
            XCTFail("祖先には送らない")
        } catch {
            XCTAssertTrue("\(error)".hasPrefix("cycle:"), "\(error)")
        }

        // 承認カードは子のチャットに出る。上限は子のチャットで選んだモード（plan）。
        await Orchestrator.shared.noteChatMode(agentId: childAgent, sessionId: childReal, mode: "plan")
        let phone = await TestConnection.open(childAdapter, sessionId: childReal)
        defer { Task { await phone.close() } }
        async let grandStart = Orchestrator.shared.startSession(caller: child, agentId: grandAgent, cwd: dir.path,
                                                                prompt: "look", mode: "auto")
        let card = try await phone.until("子のチャットの承認カード") {
            $0.type == .actionRequest && ($0.messageId ?? "").hasPrefix("mainagent-")
        }
        XCTAssertTrue((card.metadata?["subtitle"] ?? "").hasPrefix("モード: plan"), card.metadata?["subtitle"] ?? "")
        // mainagent からは、子が出した Bridge のカードに答えられない（ユーザーが子のチャットで答える）。
        let seen = await Orchestrator.shared.getReply(caller: main, agentId: childAgent, sessionId: childReal, waitSeconds: 0)
        if let a = seen["approval"] as? [String: Any] { XCTAssertNil(a["choices"], "\(a)") }
        _ = await Orchestrator.shared.resolveApproval(requestId: card.messageId ?? "", decision: "allow")
        let g = try await grandStart
        XCTAssertEqual(g["mode"] as? String, "plan")
        XCTAssertEqual(grandDepths.values, [2], "孫は深さ 2 で開かれる（合鍵は渡らない）")

        // 深さ 2 の呼び手（利用者が開いたが、鎖の 2 段目として作業中のものを含む）はもう頼めない。
        let deep = Orchestrator.Caller(token: "none", agentId: grandAgent, parentSessionId: grandReal, depth: 2)
        do {
            _ = try await Orchestrator.shared.startSession(caller: deep, agentId: grandAgent, cwd: dir.path, prompt: "x")
            XCTFail("深さ 2 からは頼めない")
        } catch {
            XCTAssertTrue("\(error)".hasPrefix("depth:"), "\(error)")
        }
        gate.open()
        await Orchestrator.shared.revoke(token: childToken)
    }

    func testDepthIsPersistedWithTheTrack() async throws {
        let store = try tmpDir().appendingPathComponent("tracks.json")
        let before = Orchestrator()
        await before.enablePersistence(at: store)
        let agent = uniq("agent")
        let real = uniq("sid")
        _ = await scripted(agent, realId: real)
        let dir = try tmpDir()
        let (shared, conn) = await mainagent()
        let token = await before.issueToken(agentId: shared.agentId, parentSessionId: shared.parentSessionId,
                                            isMain: false, depth: 1)
        let found = await before.caller(token: token)
        let caller = try XCTUnwrap(found)
        async let starting = before.startSession(caller: caller, agentId: agent, cwd: dir.path, prompt: "hi", waitSeconds: 5)
        _ = try await conn.until("承認カード") { $0.type == .actionRequest }
        let id = conn.events.first { $0.type == .actionRequest }?.messageId ?? ""
        _ = await before.resolveApproval(requestId: id, decision: "allow")
        _ = try await starting
        await before.saveNow()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store)) as? [[String: Any]])
        XCTAssertEqual(saved.first { $0["sessionId"] as? String == real }?["depth"] as? Int, 2, "呼んだ側の深さ + 1")
    }

    // MARK: - 別の PC に頼む（A 側）

    /// B の代わり（デスクトップの中継口 → B）。合言葉を確かめ、届いた道具と本文を控えて、決まった結果を返す。
    private final class StubB: @unchecked Sendable {
        let lock = NSLock()
        var calls: [(tool: String, body: [String: Any], auth: String?)] = []
        func add(_ t: String, _ b: [String: Any], _ a: String?) { lock.withLock { calls.append((t, b, a)) } }
        var all: [(tool: String, body: [String: Any], auth: String?)] { lock.withLock { calls } }
    }

    private func startStubB(_ stub: StubB, secret: String) async throws -> (Application, Int) {
        let b = try await Application.make(.testing)
        b.http.server.configuration.hostname = "127.0.0.1"
        b.http.server.configuration.port = 0
        b.on(.POST, "device", "orchestrator", ":tool", body: .collect(maxSize: "1mb")) { req async throws -> Response in
            let tool = req.parameters.get("tool") ?? ""
            let auth = req.headers.bearerAuthorization?.token
            let body = req.body.data.flatMap { try? JSONSerialization.jsonObject(with: Data(buffer: $0)) as? [String: Any] } ?? [:]
            stub.add(tool, body, auth)
            func reply(_ status: HTTPResponseStatus, _ obj: Any) -> Response {
                Response(status: status, headers: ["Content-Type": "application/json"],
                         body: .init(data: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()))
            }
            guard auth == secret else { return reply(.unauthorized, ["error": "unauthorized"]) }
            switch tool {
            case "list_projects":
                return reply(.ok, [["name": "Remote", "path": "/remote/proj"]])
            case "start_session":
                return reply(.ok, ["agent": "claude", "session_id": "r-1", "cwd": "/remote/proj", "state": "running",
                                   "confirmed": true, "mode": "auto", "next": "get_reply で返事を待つ"])
            case "get_reply":
                return reply(.ok, ["agent": "claude", "session_id": "r-1", "status": "needs_approval", "request": "fix",
                                   "approval": ["request_id": "q1", "title": "「Bash」を実行しますか？",
                                                "choices": ["allow", "deny"], "hint": "…"]])
            case "send_message":
                return reply(.unprocessableEntity, ["error": "depth", "message": "depth: 頼めるのは 2 段まで"])
            default:
                return reply(.notFound, ["error": "unknown_tool"])
            }
        }
        try await b.server.start()
        return (b, b.http.server.shared.localAddress?.port ?? 0)
    }

    func testRemoteToolsAreForwardedAfterApprovalAndRowsCarryThePc() async throws {
        let stub = StubB()
        let (b, bPort) = try await startStubB(stub, secret: "bdp_test")
        defer { Task { await b.server.shutdown(); try? await b.asyncShutdown() } }
        await Orchestrator.shared.setRemotePCs([
            RemotePC(bridgeId: "remote-b", name: "Studio", platform: "windows", port: bPort, secret: "bdp_test")
        ])
        let (caller, conn) = await mainagent()
        let me = KeyStore.loadOrCreateBridgeId()

        // list_pcs: 自分を先頭に、次に別の PC。
        let listed = await toolCall("list_pcs", [:], caller)
        let pcs = try XCTUnwrap(listed.value as? [String: Any])["pcs"] as? [[String: Any]]
        XCTAssertEqual(pcs?.first?["pc"] as? String, me)
        XCTAssertEqual(pcs?.first?["self"] as? Bool, true)
        XCTAssertEqual(pcs?.last?["pc"] as? String, "remote-b")
        XCTAssertEqual(pcs?.last?["name"] as? String, "Studio")
        XCTAssertEqual(pcs?.last?["self"] as? Bool, false)

        let unknown = await toolCall("list_projects", ["pc": "Nowhere"], caller)
        XCTAssertEqual(unknown.error?.code, "unknown_pc")

        // 名前でも引ける。承認の要らない道具はそのまま送る。本文に上限・深さ・呼んだ PC を足す。
        let projects = await toolCall("list_projects", ["pc": "Studio"], caller)
        XCTAssertEqual((projects.value as? [[String: Any]])?.first?["name"] as? String, "Remote")
        let first = try XCTUnwrap(stub.all.last)
        XCTAssertEqual(first.auth, "bdp_test", "合言葉を Bearer で付ける")
        XCTAssertNil(first.body["pc"], "pc は B へ送らない")
        XCTAssertEqual(first.body["capMode"] as? Int, 1, "上限を選んでいなければ段 1")
        XCTAssertEqual(first.body["depth"] as? Int, 0)
        XCTAssertEqual((first.body["caller"] as? [String: Any])?["bridgeId"] as? String, me)

        // 頼む道具は、この PC で承認カード（PC: 名前）を出してから送る。断れば送らない。
        let sent = stub.all.count
        async let denied = toolCall("start_session", ["pc": "remote-b", "cwd": "/remote/proj", "prompt": "fix"], caller)
        let card0 = try await answerNth(conn, caller, 0, "deny")
        XCTAssertTrue((card0.metadata?["subtitle"] ?? "").hasPrefix("PC: Studio"), card0.metadata?["subtitle"] ?? "")
        let deniedResult = await denied
        XCTAssertNotNil(deniedResult.error)
        XCTAssertEqual(stub.all.count, sent, "断ったら B へ送らない")

        async let started = toolCall("start_session", ["pc": "remote-b", "cwd": "/remote/proj", "prompt": "fix"], caller)
        try await answerNth(conn, caller, 1, "allow")
        let startedResult = await started
        let s = try XCTUnwrap(startedResult.value as? [String: Any])
        XCTAssertEqual(s["session_id"] as? String, "r-1", "B の結果をそのまま返す")
        XCTAssertEqual(stub.all.last?.tool, "start_session")
        XCTAssertEqual(stub.all.last?.body["prompt"] as? String, "fix")

        // 子のカードの行に、別の PC の印（bridgeId / pcName）が付く。get_reply の結果で行が変わる。
        let row = try await conn.until("別の PC の子の行") { self.sessionsRow($0, agent: "claude")?["bridgeId"] as? String == "remote-b" }
        XCTAssertEqual(sessionsRow(row, agent: "claude")?["pcName"] as? String, "Studio")
        XCTAssertEqual(sessionsRow(row, agent: "claude")?["sessionId"] as? String, "r-1")
        _ = await toolCall("get_reply", ["pc": "remote-b", "agent": "claude", "session_id": "r-1", "wait_seconds": 0], caller)
        let waiting = try await conn.until("承認待ちの行") { self.sessionsRow($0, agent: "claude")?["status"] as? String == "needs_approval" }
        XCTAssertEqual((sessionsRow(waiting, agent: "claude")?["approval"] as? [String: Any])?["requestId"] as? String, "q1")

        // B が断った（深さなど）ときは、その文と種類をそのまま返す。
        async let sending = toolCall("send_message", ["pc": "remote-b", "agent": "claude", "session_id": "r-1", "text": "more"], caller)
        let card2 = try await answerNth(conn, caller, 2, "allow")
        XCTAssertTrue((card2.metadata?["subtitle"] ?? "").hasPrefix("PC: Studio"))
        let failed = await sending.error
        XCTAssertEqual(failed?.code, "depth")
        XCTAssertTrue(failed?.description.contains("Studio") ?? false, failed?.description ?? "")

        // つながらない（中継口が無い）は pc_unreachable。
        await Orchestrator.shared.setRemotePCs([RemotePC(bridgeId: "gone", name: "Gone", platform: "mac", port: 1, secret: "bdp_x")])
        let unreachable = await toolCall("list_agents", ["pc": "gone"], caller)
        XCTAssertEqual(unreachable.error?.code, "pc_unreachable", unreachable.error?.description ?? "")
    }

    func testRemotePcsRouteReplacesTheListAndNeedsTheAdminKey() async throws {
        let body: [String: Any] = ["pcs": [["bridgeId": "b1", "name": "Studio", "platform": "mac", "port": 50123, "secret": "bdp_s"]]]
        var r = try await request("/local/remote-pcs", method: "PUT", headers: [bearer(localKey)], body: body)
        XCTAssertEqual(r.status, 401, "管理鍵が要る")
        r = try await request("/local/remote-pcs", method: "PUT", headers: admin, body: body)
        XCTAssertEqual(r.status, 204)
        let list = await Orchestrator.shared.remotePCList()
        XCTAssertEqual(list.map(\.bridgeId), ["b1"])
        XCTAssertEqual(list.first?.port, 50123)
        r = try await request("/local/remote-pcs", method: "PUT", headers: admin, body: ["pcs": [["bridgeId": "b2", "port": 0]]])
        XCTAssertEqual(r.status, 400)
        let kept = await Orchestrator.shared.remotePCList()
        XCTAssertEqual(kept.map(\.bridgeId), ["b1"], "形が違えば置き換えない")
        r = try await request("/local/remote-pcs", method: "PUT", headers: admin, body: ["pcs": [Any]()])
        XCTAssertEqual(r.status, 204)
        let emptied = await Orchestrator.shared.remotePCList()
        XCTAssertTrue(emptied.isEmpty, "毎回まるごと置き換える")
    }

    // MARK: - B の口

    func testDeviceOrchestratorAcceptsOnlyTunnelCredentialsAndEnforcesLimits() async throws {
        let agent = uniq("agent")
        let real = uniq("sid")
        let depths = DepthBox()
        _ = await scripted(agent, realId: real, depths: depths, modes: ["plan", "edit", "auto"])
        let dir = try tmpDir()

        var r = try await request("/device/orchestrator/list_agents", method: "POST", headers: [bearer(localKey)], body: [:])
        XCTAssertEqual(r.status, 403, "この PC の中からは使えない")
        XCTAssertEqual((r.json as? [String: Any])?["error"] as? String, "device_only")
        r = try await request("/device/orchestrator/list_agents", method: "POST", headers: [bearer("bdc_wrong")], body: [:], device: phoneKey)
        XCTAssertEqual(r.status, 401)
        r = try await request("/device/orchestrator/list_agents", method: "POST", headers: [bearer(phoneCred)], body: [:], device: phoneKey)
        XCTAssertEqual(r.status, 200)
        XCTAssertNotNil(r.json as? [[String: Any]], "道具の結果（配列）をそのまま返す")
        r = try await request("/device/orchestrator/list_pcs", method: "POST", headers: [bearer(phoneCred)], body: [:], device: phoneKey)
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual((r.json as? [String: Any])?["error"] as? String, "unknown_tool")

        // 承認カードは出さずに起こす。上限は capMode（段 0 = 計画）。子は depth + 1 で開く。
        let caller: [String: Any] = ["bridgeId": "pc-a", "name": "MacBook"]
        r = try await request("/device/orchestrator/start_session", method: "POST", headers: [bearer(phoneCred)],
                              body: ["agent": agent, "cwd": dir.path, "prompt": "hi", "mode": "auto", "wait_seconds": 5,
                                     "capMode": 0, "depth": 0, "caller": caller, "pc": "ignored"], device: phoneKey)
        XCTAssertEqual(r.status, 200, "\(String(describing: r.json))")
        let started = try XCTUnwrap(r.json as? [String: Any])
        XCTAssertEqual(started["mode"] as? String, "plan")
        XCTAssertEqual(started["reply"] as? String, "echo: hi")
        XCTAssertEqual(depths.values, [1])

        // get_reply は、その端末から頼んだターンだけ。
        r = try await request("/device/orchestrator/get_reply", method: "POST", headers: [bearer(otherCred)],
                              body: ["agent": agent, "session_id": real, "wait_seconds": 0], device: otherKey)
        XCTAssertEqual(r.status, 422)
        XCTAssertEqual((r.json as? [String: Any])?["error"] as? String, "not_requested")
        r = try await request("/device/orchestrator/get_reply", method: "POST", headers: [bearer(phoneCred)],
                              body: ["agent": agent, "session_id": real, "wait_seconds": 0], device: phoneKey)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual((r.json as? [String: Any])?["status"] as? String, "done")

        // 深さ・mainagent のフォルダ・自分自身は B でも確かめる。
        r = try await request("/device/orchestrator/send_message", method: "POST", headers: [bearer(phoneCred)],
                              body: ["agent": agent, "session_id": real, "text": "x", "depth": 2], device: phoneKey)
        XCTAssertEqual(r.status, 422)
        XCTAssertEqual((r.json as? [String: Any])?["error"] as? String, "depth")
        r = try await request("/device/orchestrator/start_session", method: "POST", headers: [bearer(phoneCred)],
                              body: ["agent": agent, "cwd": MainAgentWorkspace.defaultURL.path, "prompt": "x"], device: phoneKey)
        XCTAssertEqual(r.status, 422)
        r = try await request("/device/orchestrator/start_session", method: "POST", headers: [bearer(phoneCred)],
                              body: ["agent": agent, "cwd": dir.path, "prompt": "x",
                                     "caller": ["bridgeId": KeyStore.loadOrCreateBridgeId(), "name": "me"]], device: phoneKey)
        XCTAssertEqual(r.status, 422)
        XCTAssertEqual((r.json as? [String: Any])?["error"] as? String, "self")
    }

    // MARK: - Antigravity（agy）

    func testAntigravityGetsMcpViaAddDirConfigWithoutTheToken() throws {
        let dir = try tmpDir().appendingPathComponent("agy-mcp", isDirectory: true)
        let relay = "/Applications/BuddyOS.app/Contents/Resources/bin/BridgeApp"
        XCTAssertEqual(MainAgentWorkspace.ensureAgyMcpConfig(executable: relay, dir: dir), dir.path)
        let file = dir.appendingPathComponent(".agents/mcp_config.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let server = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["buddyos"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, relay, "stdio の中継（動いている Bridge）")
        XCTAssertEqual(server["args"] as? [String], ["mcp-stdio-relay"])
        XCTAssertEqual(Set(server.keys), ["command", "args"], "合鍵も番号もファイルに書かない（agy の環境変数で渡す）")
        XCTAssertFalse(text.contains("bmt_"))
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.intValue, 0o700)
        // 書き換えられていたら直す。
        try Data("{\"mcpServers\":{\"buddyos\":{\"command\":\"/tmp/evil\"}}}".utf8).write(to: file)
        _ = MainAgentWorkspace.ensureAgyMcpConfig(executable: relay, dir: dir)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)

        // 合鍵を渡したセッションの agy だけ、そのフォルダを --add-dir で読ませ、合鍵と番号を環境変数で渡す。
        let session = HeadlessCliSession(profile: .antigravity, initialSessionId: nil, cwd: "/tmp", executable: "agy",
                                         store: .shared, mcpToken: "bmt_secret", mcpDir: dir.path)
        let args = session.argsForPrompt("hi")
        let i = try XCTUnwrap(args.lastIndex(of: dir.path))
        XCTAssertEqual(args[i - 1], "--add-dir")
        XCTAssertFalse(args.joined(separator: " ").contains("bmt_secret"), "引数に合鍵を載せない（ps で見える）")
        let env = session.turnEnvironment()
        XCTAssertEqual(env["BUDDYOS_MCP_TOKEN"], "bmt_secret")
        XCTAssertNotNil(env["BUDDYOS_MCP_PORT"])
        let plain = HeadlessCliSession(profile: .antigravity, initialSessionId: nil, cwd: "/tmp", executable: "agy", store: .shared)
        XCTAssertFalse(plain.argsForPrompt("hi").contains(dir.path))
        XCTAssertNil(plain.turnEnvironment()["BUDDYOS_MCP_TOKEN"])

        // 承認 hook: buddyos の道具の呼び出しと、その説明を読むのは通す（頼む道具は Bridge のカードが関門）。
        let home = NSHomeDirectory()
        func v(_ name: String, _ a: [String: Any], _ mcp: Bool) -> AgyApprovalPolicy.Verdict {
            AgyApprovalPolicy.verdict(toolName: name, args: a, allow: [], deny: [], cwd: "/tmp", bridgeMcp: mcp)
        }
        let call: [String: Any] = ["ServerName": "buddyos", "ToolName": "start_session", "Arguments": [:]]
        XCTAssertEqual(v("call_mcp_tool", call, true), .allow)
        if case .ask = v("call_mcp_tool", call, false) {} else { XCTFail("合鍵が無いセッションは今までどおり聞く") }
        if case .ask = v("call_mcp_tool", ["ServerName": "other", "ToolName": "x"], true) {} else { XCTFail("ほかの MCP は聞く") }
        let schema = ["AbsolutePath": home + "/.gemini/antigravity-cli/mcp/buddyos/start_session.json"]
        XCTAssertEqual(v("view_file", schema, true), .allow)
        if case .ask = v("view_file", ["AbsolutePath": home + "/.gemini/antigravity-cli/settings.json"], true) {} else {
            XCTFail("ほかの設定を読むのは今までどおり聞く")
        }
    }

    // MARK: - すべての PC の一覧

    func testSessionsSummaryShape() async throws {
        let agent = uniq("agent")
        let sid = uniq("sid")
        let adapter = ScriptedAdapter(id: agent, displayName: "Scripted Agent") { s in ScriptedSession(agentId: agent, sessionId: s ?? sid) }
        await AgentRegistry.shared.register(adapter)
        let conn = await TestConnection.open(adapter, sessionId: sid)
        defer { Task { await conn.close() } }

        var r = try await request("/device/sessions/summary", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 403, "トンネルからの bdc_ だけ")
        r = try await request("/device/sessions/summary", headers: [bearer(phoneCred)], device: phoneKey)
        XCTAssertEqual(r.status, 200)
        let body = try XCTUnwrap(r.json as? [String: Any])
        let pc = try XCTUnwrap(body["pc"] as? [String: Any])
        XCTAssertEqual(pc["bridgeId"] as? String, KeyStore.loadOrCreateBridgeId())
        XCTAssertEqual(pc["platform"] as? String, "mac")
        XCTAssertNotNil(pc["name"] as? String)
        let sessions = try XCTUnwrap(body["sessions"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(sessions.count, Orchestrator.summaryLimit)
        let row = try XCTUnwrap(sessions.first { $0["sessionId"] as? String == sid })
        XCTAssertEqual(row["agentId"] as? String, agent)
        XCTAssertEqual(row["agentName"] as? String, "Scripted Agent")
        XCTAssertEqual(row["status"] as? String, "idle")
        XCTAssertNotNil(row["updatedAtMs"] as? Int)
        for key in ["cwd", "project", "branch", "title"] { XCTAssertTrue(row.keys.contains(key), "\(key) は null でも入れる") }
        let times = sessions.compactMap { $0["updatedAtMs"] as? Int }
        XCTAssertEqual(times, times.sorted(by: >), "新しい順")
    }
}
