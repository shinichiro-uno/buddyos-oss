import Foundation
import Vapor
import XCTest
@testable import BridgeApp

/// Origin / Host の関門と、プレビューのセッションを確かめる。
/// 本物の Vapor サーバーに生の HTTP を送る（URLSession は Host / Origin を好きに付けられないため）。
final class BridgeRequestGuardTests: XCTestCase {
    // MARK: - 判定の関数

    func testAllowedHost() {
        XCTAssertTrue(BridgeRequestGuard.allowedHost(["127.0.0.1:8765"]))
        XCTAssertTrue(BridgeRequestGuard.allowedHost(["localhost:51234"]))
        XCTAssertTrue(BridgeRequestGuard.allowedHost(["LOCALHOST"]))
        XCTAssertTrue(BridgeRequestGuard.allowedHost(["[::1]:8765"]))
        XCTAssertTrue(BridgeRequestGuard.allowedHost(["127.0.0.1"]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost([]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost(["evil.example:8765"]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost(["127.0.0.1.evil.example:8765"]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost(["localhost.:8765"]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost(["127.0.0.1:99999"]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost(["127.0.0.1:"]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost(["127.0.0.1:80:80"]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost(["[::2]:8765"]))
        XCTAssertFalse(BridgeRequestGuard.allowedHost(["127.0.0.1:8765", "evil.example"]))
    }

    func testAllowedOrigin() {
        XCTAssertTrue(BridgeRequestGuard.allowedOrigin([]))
        XCTAssertTrue(BridgeRequestGuard.allowedOrigin(["buddyos-desktop://app"]))
        XCTAssertFalse(BridgeRequestGuard.allowedOrigin(["null"]))
        XCTAssertFalse(BridgeRequestGuard.allowedOrigin(["http://localhost:8765"]))
        XCTAssertFalse(BridgeRequestGuard.allowedOrigin(["http://127.0.0.1:8765"]))
        XCTAssertFalse(BridgeRequestGuard.allowedOrigin(["file://"]))
        XCTAssertFalse(BridgeRequestGuard.allowedOrigin(["buddyos-desktop://app/"]))
        XCTAssertFalse(BridgeRequestGuard.allowedOrigin(["BUDDYOS-DESKTOP://APP"]))
        XCTAssertFalse(BridgeRequestGuard.allowedOrigin(["buddyos-desktop://app", "null"]))
    }

    func testPreviewSessionPaths() {
        XCTAssertTrue(BridgeRequestGuard.isPreviewSessionPath("/preview/ui"))
        XCTAssertTrue(BridgeRequestGuard.isPreviewSessionPath("/preview/sim/stream"))
        XCTAssertTrue(BridgeRequestGuard.isPreviewSessionPath("/preview/sim/tap"))
        XCTAssertTrue(BridgeRequestGuard.isPreviewSessionPath("/preview/sim/swipe"))
        XCTAssertTrue(BridgeRequestGuard.isPreviewSessionPath("/preview/w/abc/assets/app.js"))
        XCTAssertTrue(BridgeRequestGuard.isPreviewSessionPath("/%70review/w/abc"))
        // Bearer 専用のプレビューのルートと、それ以外は Origin の関門をかける。
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/preview/session"))
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/preview/targets"))
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/preview/sim/frame"))
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/preview/sim/text"))
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/preview/web/5173/"))
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/preview/w"))
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/ws/agent/claude"))
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/terminal/pty"))
        XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath("/xpreview/ui"))
    }

    // MARK: - 本物のサーバー

    private var app: Application!
    private var upstream: Application!
    private var port = 0
    private var upstreamPort = 0
    private let key = "test-api-key-0123456789"

    override func setUp() async throws {
        upstream = try await Application.make(.testing)
        upstream.http.server.configuration.hostname = "127.0.0.1"
        upstream.http.server.configuration.port = 0
        upstream.get { _ -> Response in
            Response(status: .ok,
                     headers: ["Content-Type": "text/html; charset=utf-8", "X-Frame-Options": "DENY",
                               "Access-Control-Allow-Origin": "http://localhost:5173"],
                     body: .init(string: "<html><head><title>dev</title></head><body><script src=\"/app.js\"></script></body></html>"))
        }
        upstream.get("echo-origin") { req -> String in req.headers.first(name: .origin) ?? "-" }
        try await upstream.server.start()
        upstreamPort = upstream.http.server.shared.localAddress?.port ?? 0

        app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.middleware.use(BridgeRequestGuard.Middleware())
        app.get("ping") { _ in "pong" }
        let key = self.key
        // 資格情報は BridgeAuth（この PC の中からはローカル鍵）。テストではローカル鍵を決まった値にする。
        LocalKey.shared.replace(key)
        app.on(.POST, "claude", "hook", body: .stream) { req async throws -> Response in
            try BridgeAuth.requireLocal(req)
            return Response(status: .ok)
        }
        PreviewRoutes.register(app: app)
        TerminalPtyRoutes.register(app: app)
        try await app.server.start()
        port = app.http.server.shared.localAddress?.port ?? 0
        XCTAssertGreaterThan(port, 0)
        XCTAssertGreaterThan(upstreamPort, 0)
        setenv("BUDDYOS_PREVIEW_WEB_PORTS", "\(upstreamPort),\(port)", 1)
    }

    override func tearDown() async throws {
        unsetenv("BUDDYOS_PREVIEW_WEB_PORTS")
        LocalKey.shared.invalidate()
        await app.server.shutdown()
        try await app.asyncShutdown()
        await upstream.server.shutdown()
        try await upstream.asyncShutdown()
    }

    private struct RawResponse {
        let status: Int
        let head: String
        let body: String
        func header(_ name: String) -> [String] {
            head.split(separator: "\r\n").compactMap { line in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == name.lowercased() else { return nil }
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
    }

    /// 生の HTTP/1.1 を 1 本送って、応答を読み切る（upgrade のときは頭だけ）。
    private func raw(_ path: String, method: String = "GET", headers: [(String, String)] = [],
                     host: String? = nil, body: String = "", upgrade: Bool = false) async throws -> RawResponse {
        let port = self.port
        return try await Task.detached {
            var lines = ["\(method) \(path) HTTP/1.1"]
            lines.append("Host: \(host ?? "127.0.0.1:\(port)")")
            for (k, v) in headers { lines.append("\(k): \(v)") }
            if !upgrade { lines.append("Connection: close") }
            if !body.isEmpty || method == "POST" { lines.append("Content-Length: \(body.utf8.count)") }
            let request = lines.joined(separator: "\r\n") + "\r\n\r\n" + body
            let text = try Self.exchange(port: port, request: request, headOnly: upgrade)
            let split = text.range(of: "\r\n\r\n")
            let head = split.map { String(text[..<$0.lowerBound]) } ?? text
            let rest = split.map { String(text[$0.upperBound...]) } ?? ""
            let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
            return RawResponse(status: status, head: head, body: rest)
        }.value
    }

    private static func exchange(port: Int, request: String, headOnly: Bool) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }
        let bytes = Array(request.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), bytes.count - sent) }
            guard n > 0 else { throw POSIXError(.EIO) }
            sent += n
        }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if headOnly, out.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func expectStatus(_ expected: Int, _ r: RawResponse, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.status, expected, r.head, file: file, line: line)
    }

    private func createSession(_ target: String, origin: String? = nil) async throws -> RawResponse {
        var headers = [("Authorization", "Bearer \(key)"), ("Content-Type", "application/json")]
        if let origin { headers.append(("Origin", origin)) }
        return try await raw("/preview/session", method: "POST", headers: headers, body: "{\"target\":\"\(target)\"}")
    }

    private func sessionToken(_ r: RawResponse) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(r.body.utf8)) as? [String: Any] else { return nil }
        return obj["session"] as? String
    }

    // MARK: Origin / Host

    func testOriginRuleOnPlainRoutes() async throws {
        try await expectStatus(200, raw("/ping"))
        try await expectStatus(200, raw("/ping", headers: [("Origin", "buddyos-desktop://app")]))
        for origin in ["null", "http://localhost:\(port)", "http://127.0.0.1:\(port)", "file://", "https://evil.example"] {
            let r = try await raw("/ping", headers: [("Origin", origin)])
            XCTAssertEqual(r.status, 403, origin)
            XCTAssertTrue(r.body.contains("forbidden_origin"), origin)
        }
        // DNS rebinding（別の名前の Host）は 403。番号は見ない（Paseo の中継は端末の中の番号で来る）。
        try await expectStatus(403, raw("/ping", host: "evil.example:\(port)"))
        try await expectStatus(200, raw("/ping", host: "localhost:1"))
        try await expectStatus(200, raw("/ping", host: "[::1]:\(port)"))
    }

    func testRejectsBeforeReadingBody() async throws {
        // 認証より前に Origin で 403（本文を読む前に返す）。
        let big = String(repeating: "x", count: 64 * 1024)
        let r = try await raw("/claude/hook", method: "POST", headers: [("Origin", "null"), ("Authorization", "Bearer \(key)")], body: big)
        XCTAssertEqual(r.status, 403)
        // Origin が無ければ認証へ進む。
        try await expectStatus(401, raw("/claude/hook", method: "POST", body: "{}"))
        try await expectStatus(200, raw("/claude/hook", method: "POST", headers: [("Authorization", "Bearer \(key)")], body: "{}"))
    }

    func testWebSocketUpgradeRejectsBrowserOrigins() async throws {
        let wsHeaders: [(String, String)] = [
            ("Upgrade", "websocket"), ("Connection", "Upgrade"),
            ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ=="), ("Sec-WebSocket-Version", "13"),
        ]
        let path = "/terminal/pty?id=guard-test&apiKey=\(key)&attach=1"
        let rejected = try await raw(path, headers: wsHeaders + [("Origin", "null")], upgrade: true)
        XCTAssertEqual(rejected.status, 403)
        let localhost = try await raw(path, headers: wsHeaders + [("Origin", "http://localhost:\(port)")], upgrade: true)
        XCTAssertEqual(localhost.status, 403)
        let native = try await raw(path, headers: wsHeaders, upgrade: true)
        XCTAssertEqual(native.status, 101)
        let desktop = try await raw(path, headers: wsHeaders + [("Origin", "buddyos-desktop://app")], upgrade: true)
        XCTAssertEqual(desktop.status, 101)
    }

    // MARK: プレビュー

    func testPreviewRejectsApiKeyQuery() async throws {
        // 以前の開き方（URL に apiKey）は通らない。
        let ui = try await raw("/preview/ui?target=web:\(upstreamPort)&apiKey=\(key)")
        XCTAssertEqual(ui.status, 401)
        XCTAssertFalse(ui.body.contains(key))
        try await expectStatus(401, raw("/preview/targets?apiKey=\(key)"))
        try await expectStatus(401, raw("/preview/web/\(upstreamPort)/?apiKey=\(key)"))
        try await expectStatus(401, raw("/preview/sim/frame?udid=7F3C2A10-1B2C-4D5E-8F90-0123456789AB&apiKey=\(key)"))
        // Bearer 専用のルートは Origin の関門もかかる。
        try await expectStatus(403, raw("/preview/targets", headers: [("Authorization", "Bearer \(key)"), ("Origin", "null")]))
    }

    func testSessionCreationValidatesTarget() async throws {
        try await expectStatus(401, raw("/preview/session", method: "POST", body: "{\"target\":\"web:\(upstreamPort)\"}"))
        try await expectStatus(403, createSession("web:\(upstreamPort)", origin: "null"))
        try await expectStatus(400, createSession("sim:../../etc"))
        try await expectStatus(400, createSession("sim:--help"))
        try await expectStatus(400, createSession("web:0"))
        try await expectStatus(400, createSession("web:abc"))
        // Bridge 自身の番号は、候補に入っていても中継しない。
        let own = try await createSession("web:\(port)")
        XCTAssertEqual(own.status, 403)
        XCTAssertTrue(own.body.contains("port_not_allowed"))
        // 候補にも開発サーバーにも無いポート。
        try await expectStatus(403, createSession("web:1"))

        let sim = try await createSession("sim:7f3c2a10-1b2c-4d5e-8f90-0123456789ab")
        XCTAssertEqual(sim.status, 200)
        XCTAssertTrue(sim.body.contains("sim:7F3C2A10-1B2C-4D5E-8F90-0123456789AB"))
    }

    func testWebPreviewSessionFlow() async throws {
        let created = try await createSession("web:\(upstreamPort)")
        XCTAssertEqual(created.status, 200)
        let s = try XCTUnwrap(sessionToken(created))
        XCTAssertFalse(created.body.contains(key))

        // ページ: apiKey を含まず、sandbox の iframe で /preview/w/<s>/ を開く。
        let ui = try await raw("/preview/ui?s=\(s)")
        XCTAssertEqual(ui.status, 200)
        XCTAssertFalse(ui.body.contains(key))
        XCTAssertFalse(ui.body.contains("apiKey"))
        XCTAssertTrue(ui.body.contains("src=\"/preview/w/\(s)/\""))
        XCTAssertTrue(ui.body.contains("sandbox=\"allow-scripts allow-forms allow-popups allow-modals allow-downloads\""))
        XCTAssertFalse(ui.body.contains("allow-same-origin"))
        XCTAssertEqual(ui.header("Referrer-Policy").first, "no-referrer")
        XCTAssertFalse(ui.header("Content-Security-Policy").isEmpty)

        // 中継: Origin: null（sandbox の iframe）でも通り、CSP sandbox と CORS が付く。
        let page = try await raw("/preview/w/\(s)/", headers: [("Origin", "null")])
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.header("Content-Security-Policy").contains(WebProxy.sandboxPolicy))
        XCTAssertEqual(page.header("Access-Control-Allow-Origin"), ["*"])
        XCTAssertEqual(page.header("X-Frame-Options"), ["SAMEORIGIN"])
        XCTAssertTrue(page.body.contains("<base href=\"/preview/w/\(s)/\">"))
        XCTAssertTrue(page.body.contains("src=\"/preview/w/\(s)/app.js\""))

        // 上流へは Origin を渡さない。
        let echo = try await raw("/preview/w/\(s)/echo-origin", headers: [("Origin", "null")])
        XCTAssertEqual(echo.body, "-")

        // CORS の preflight は Bridge が答える。
        let pre = try await raw("/preview/w/\(s)/api", method: "OPTIONS", headers: [
            ("Origin", "null"), ("Access-Control-Request-Method", "POST"), ("Access-Control-Request-Headers", "content-type"),
        ])
        XCTAssertEqual(pre.status, 204)
        XCTAssertEqual(pre.header("Access-Control-Allow-Headers"), ["content-type"])

        // セッションはその表示対象だけ。sim のルートや別の値では通らない。
        try await expectStatus(401, raw("/preview/sim/tap?s=\(s)&x=0.5&y=0.5"))
        try await expectStatus(401, raw("/preview/w/\(String(repeating: "A", count: 43))/"))
        try await expectStatus(401, raw("/preview/ui?s=nope"))

        // セッションの中継でも、別の名前の Host は断る。
        try await expectStatus(403, raw("/preview/w/\(s)/", host: "evil.example"))
    }

    func testBearerProxyDoesNotRelaxFraming() async throws {
        let r = try await raw("/preview/web/\(upstreamPort)/", headers: [("Authorization", "Bearer \(key)")])
        XCTAssertEqual(r.status, 200)
        // sandbox を付けない中継では X-Frame-Options を書き換えず、CORS も開けない。
        XCTAssertEqual(r.header("X-Frame-Options"), ["DENY"])
        XCTAssertEqual(r.header("Access-Control-Allow-Origin"), ["http://localhost:5173"])
        XCTAssertTrue(r.body.contains("<base href=\"/preview/web/\(upstreamPort)/\">"))
        // Bridge 自身には中継しない。
        try await expectStatus(403, raw("/preview/web/\(port)/ping", headers: [("Authorization", "Bearer \(key)")]))
    }

    func testSimPageUsesSessionNotApiKey() async throws {
        let created = try await createSession("sim:7F3C2A10-1B2C-4D5E-8F90-0123456789AB")
        let s = try XCTUnwrap(sessionToken(created))
        let ui = try await raw("/preview/ui?s=\(s)")
        XCTAssertEqual(ui.status, 200)
        XCTAssertFalse(ui.body.contains(key))
        XCTAssertTrue(ui.body.contains("const SESSION='\(s)'"))
        // udid が合わなければ断る。
        try await expectStatus(403, raw("/preview/sim/tap?s=\(s)&udid=00000000-0000-0000-0000-000000000000&x=0&y=0"))
        // Bearer でも udid の形は確かめる。
        try await expectStatus(400, raw("/preview/sim/home?udid=--help", headers: [("Authorization", "Bearer \(key)")]))
    }

    // MARK: - 部品

    func testSessionStoreExpiry() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = PreviewSessionStore(now: { now })
        let s = store.create(target: .web(port: 5173))
        XCTAssertEqual(s.count, 43)
        XCTAssertEqual(store.target(for: s), .web(port: 5173))
        now += PreviewSessionStore.idleTTL - 1
        XCTAssertEqual(store.target(for: s), .web(port: 5173))   // 使うと延びる
        now += PreviewSessionStore.idleTTL + 1
        XCTAssertNil(store.target(for: s))

        let t = store.create(target: .sim(udid: "7F3C2A10-1B2C-4D5E-8F90-0123456789AB"))
        for _ in 0..<50 {
            now += PreviewSessionStore.idleTTL / 2
            _ = store.target(for: t)
        }
        XCTAssertNil(store.target(for: t))   // 12 時間で必ず切れる

        for _ in 0..<(PreviewSessionStore.maxSessions + 10) { _ = store.create(target: .web(port: 3000)) }
        XCTAssertLessThanOrEqual(store.count, PreviewSessionStore.maxSessions)
    }

    func testPreviewTargetParsing() {
        XCTAssertEqual(PreviewTarget(param: "web:5173"), .web(port: 5173))
        XCTAssertNil(PreviewTarget(param: "web:65536"))
        XCTAssertNil(PreviewTarget(param: "web:-1"))
        XCTAssertNil(PreviewTarget(param: "web:+80"))
        XCTAssertNil(PreviewTarget(param: "5173"))
        XCTAssertEqual(PreviewTarget(param: "sim:7f3c2a10-1b2c-4d5e-8f90-0123456789ab"),
                       .sim(udid: "7F3C2A10-1B2C-4D5E-8F90-0123456789AB"))
        XCTAssertNil(PreviewTarget(param: "sim:booted"))
    }

    func testUDIDValidation() {
        XCTAssertNil(SimController.normalizedUDID("../../tmp/x"))
        XCTAssertNil(SimController.normalizedUDID("--help"))
        XCTAssertNil(SimController.normalizedUDID(""))
        XCTAssertNil(SimController.normalizedUDID("7F3C2A101B2C4D5E8F900123456789AB"))
        XCTAssertEqual(SimController.normalizedUDID("7f3c2a10-1b2c-4d5e-8f90-0123456789ab"),
                       "7F3C2A10-1B2C-4D5E-8F90-0123456789AB")
    }

    func testDevServerPortParsing() {
        let out = """
        p100
        R1
        cnode
        n127.0.0.1:5173
        n[::1]:5173
        p200
        R1
        cpostgres
        n127.0.0.1:5432
        p300
        R4242
        cnode
        n127.0.0.1:7000
        p4242
        R1
        cBridgeApp
        n127.0.0.1:8765
        p400
        R1
        cPython
        n*:8000
        p500
        R1
        cnode
        n127.0.0.1:80
        """
        XCTAssertEqual(DevServerPorts.parse(lsofOutput: out, selfPid: 4242), [5173, 8000])
    }
}
