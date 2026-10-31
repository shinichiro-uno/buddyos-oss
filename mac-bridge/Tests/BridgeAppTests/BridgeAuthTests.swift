import Darwin
import Foundation
import Vapor
import XCTest
@testable import BridgeApp

/// トンネルの中の認証（spec/PROTOCOL-v3.md §13）。
/// TunnelPeers に有る / 無い × ローカル鍵 / bdc_ / 違う bdc_ / state 付きの行、ルートごとの local_only / device_only。
final class BridgeAuthTests: XCTestCase {
    private var app: Application!
    private var port = 0
    private var root: URL!
    private let localKey = "local-key-0123456789"
    private let adminKey = "bda_" + String(repeating: "A", count: 43)
    private let deviceKey = "AUTHTESTKEY0000000000A"
    private let credential = "bdc_auth_test_credential"

    override func setUp() async throws {
        root = try makeTempDir("bridge-auth")
        BuddyPaths.setOverride(root)
        DeviceStore.shared.load()
        LocalKey.shared.replace(localKey)
        AdminKey.shared.resetForTesting(adminKey)
        let row = DeviceStore.Device(pub: "p", clientDeviceId: "device-test-1", name: "iPhone", label: nil, platform: "ios",
                                     credHash: TunnelV3.credentialHash(credential), via: "qr",
                                     createdAt: DeviceStore.nowMs(), lastSeenAt: nil, push: nil)
        XCTAssertTrue(DeviceStore.shared.insertPending(deviceKeyId: deviceKey, device: row, epoch: DeviceStore.shared.epoch))
        XCTAssertTrue(DeviceStore.shared.confirmPending(deviceKeyId: deviceKey, credHash: row.credHash, epoch: DeviceStore.shared.epoch))

        app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.middleware.use(BridgeRequestGuard.Middleware())
        app.middleware.use(BridgeAuth.Middleware())
        app.get("health") { req -> String in
            switch try BridgeAuth.requireAny(req) {
            case .local: return "local"
            case .device(let id, _): return "device:\(id)"
            }
        }
        app.get("livez") { req -> String in try BridgeAuth.requireLocal(req); return "ok" }
        app.get("local", "devices") { req -> String in try BridgeAuth.requireAdmin(req); return "admin" }
        app.get("device", "self") { req -> String in _ = try BridgeAuth.requireDevice(req); return "self" }
        app.on(.POST, "antigravity", "hook") { _ -> String in "hook" }
        McpEndpoint.register(app: app)
        try await app.server.start()
        port = app.http.server.shared.localAddress?.port ?? 0
        XCTAssertGreaterThan(port, 0)
    }

    override func tearDown() async throws {
        await app.server.shutdown()
        try await app.asyncShutdown()
        AdminKey.shared.resetForTesting(nil)
        LocalKey.shared.invalidate()
        BuddyPaths.setOverride(nil)
        try? FileManager.default.removeItem(at: root)
    }

    /// 生の HTTP/1.1 を 1 本送る。`tunnel` なら送る前にこの接続のローカル側の番号を TunnelPeers に入れる。
    private func request(_ path: String, method: String = "GET", headers: [(String, String)] = [],
                         tunnel: Bool = false) async throws -> (status: Int, body: String) {
        let port = self.port
        let deviceKey = self.deviceKey
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
            if tunnel { TunnelPeers.shared.register(localPort: localPort, peer: .init(deviceKeyId: deviceKey, connectionId: connId)) }
            defer { if tunnel { TunnelPeers.shared.remove(localPort: localPort, connectionId: connId) } }
            var lines = ["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:\(port)", "Connection: close"]
            for (k, v) in headers { lines.append("\(k): \(v)") }
            if method == "POST" { lines.append("Content-Length: 0") }
            let req = lines.joined(separator: "\r\n") + "\r\n\r\n"
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
            let body = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
            return (status, body)
        }.value
    }

    private func bearer(_ v: String) -> (String, String) { ("Authorization", "Bearer \(v)") }

    func testPrincipalTable() async throws {
        // この PC の中から: ローカル鍵だけ。
        var r = try await request("/health", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 200); XCTAssertEqual(r.body, "local")
        r = try await request("/health", headers: [bearer(credential)])
        XCTAssertEqual(r.status, 401, "bdc_ はこの PC の中からは通らない")
        // トンネル経由: その端末の bdc_ だけ。
        r = try await request("/health", headers: [bearer(credential)], tunnel: true)
        XCTAssertEqual(r.status, 200); XCTAssertEqual(r.body, "device:\(deviceKey)")
        r = try await request("/health", headers: [bearer(localKey)], tunnel: true)
        XCTAssertEqual(r.status, 401, "ローカル鍵はトンネル越しでは使えない")
        r = try await request("/health", headers: [bearer("bdc_wrong")], tunnel: true)
        XCTAssertEqual(r.status, 401)
        // state の付いた行（unpairing）は通らない。
        XCTAssertTrue(DeviceStore.shared.beginUnpair(deviceKeyId: deviceKey))
        r = try await request("/health", headers: [bearer(credential)], tunnel: true)
        XCTAssertEqual(r.status, 401)
    }

    func testRouteClasses() async throws {
        var r = try await request("/livez", headers: [bearer(credential)], tunnel: true)
        XCTAssertEqual(r.status, 403); XCTAssertEqual(r.body, #"{"error":"local_only"}"#)
        r = try await request("/livez", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 200)
        r = try await request("/device/self", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 403); XCTAssertEqual(r.body, #"{"error":"device_only"}"#)
        r = try await request("/device/self", headers: [bearer(credential)], tunnel: true)
        XCTAssertEqual(r.status, 200)
        r = try await request("/antigravity/hook", method: "POST", tunnel: true)
        XCTAssertEqual(r.status, 403, "ターンごとのトークンの hook もトンネル経由は 403")
        r = try await request("/local/devices", headers: [bearer(credential), ("X-BuddyOS-Admin", adminKey)], tunnel: true)
        XCTAssertEqual(r.status, 403)
    }

    /// mainagent の `/mcp`: 合鍵（bmt_）だけで通り、トンネル経由・ブラウザの Origin・?apiKey= は断る。
    func testMainAgentMcpGuards() async throws {
        let token = await Orchestrator.shared.issueToken(agentId: "claude", parentSessionId: nil)
        defer { Task { await Orchestrator.shared.revoke(token: token) } }
        var r = try await request("/mcp", method: "POST")
        XCTAssertEqual(r.status, 401, "合鍵なし")
        r = try await request("/mcp", method: "POST", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 401, "ローカル鍵では通らない（合鍵だけ）")
        r = try await request("/mcp", method: "POST", headers: [bearer(token)])
        XCTAssertEqual(r.status, 400, "合鍵があれば認証は通る（本文が空なので 400）")
        r = try await request("/mcp", method: "POST", headers: [bearer(token)], tunnel: true)
        XCTAssertEqual(r.status, 403); XCTAssertEqual(r.body, #"{"error":"local_only"}"#)
        r = try await request("/mcp", method: "POST", headers: [bearer(token), ("Origin", "http://localhost:3000")])
        XCTAssertEqual(r.status, 403); XCTAssertEqual(r.body, #"{"error":"forbidden_origin"}"#)
        r = try await request("/mcp", method: "POST", headers: [bearer(token), ("Origin", "null")])
        XCTAssertEqual(r.status, 403)
        r = try await request("/mcp?apiKey=\(token)", method: "POST")
        XCTAssertEqual(r.status, 401)
    }

    /// spec/PROTOCOL-v3.md §18.2 の 11: Authorization と ?apiKey= が違う・/local/* に ?apiKey= だけ・Origin 付き・管理鍵なし・表に無いルート。
    func testCredentialRules() async throws {
        var r = try await request("/health?apiKey=\(localKey)x", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 401)
        r = try await request("/health?apiKey=\(localKey)")
        XCTAssertEqual(r.status, 200, "ヘッダが無ければクエリも受け付ける")
        r = try await request("/local/devices?apiKey=\(localKey)", headers: [("X-BuddyOS-Admin", adminKey)])
        XCTAssertEqual(r.status, 401)
        r = try await request("/local/devices", headers: [bearer(localKey), ("X-BuddyOS-Admin", adminKey), ("Origin", "buddyos-desktop://app")])
        XCTAssertEqual(r.status, 403); XCTAssertEqual(r.body, #"{"error":"forbidden"}"#)
        r = try await request("/local/devices", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 401)
        r = try await request("/local/devices", headers: [bearer(localKey), ("X-BuddyOS-Admin", adminKey)])
        XCTAssertEqual(r.status, 200); XCTAssertEqual(r.body, "admin")
        r = try await request("/nope", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 404); XCTAssertEqual(r.body, #"{"error":"not_found"}"#)
        AdminKey.shared.resetForTesting(nil)
        r = try await request("/local/devices", headers: [bearer(localKey), ("X-BuddyOS-Admin", adminKey)])
        XCTAssertEqual(r.status, 403); XCTAssertEqual(r.body, #"{"error":"admin_unavailable"}"#)
    }

    func testClassifyTable() {
        XCTAssertEqual(BridgeAuth.classify("/health"), .any(allowQuery: true))
        XCTAssertEqual(BridgeAuth.classify("/ws/agent/claude"), .any(allowQuery: true))
        XCTAssertEqual(BridgeAuth.classify("/terminal/pty"), .any(allowQuery: true))
        XCTAssertEqual(BridgeAuth.classify("/files/image"), .any(allowQuery: true))
        XCTAssertEqual(BridgeAuth.classify("/preview/session"), .any(allowQuery: false))
        XCTAssertEqual(BridgeAuth.classify("/preview/web/3000/x/y"), .any(allowQuery: false))
        XCTAssertEqual(BridgeAuth.classify("/preview/ui"), .previewSession)
        XCTAssertEqual(BridgeAuth.classify("/preview/w/abc/index.html"), .previewSession)
        XCTAssertEqual(BridgeAuth.classify("/preview/sim/stream"), .previewSession)
        XCTAssertEqual(BridgeAuth.classify("/preview/sim/frame"), .any(allowQuery: false))
        XCTAssertEqual(BridgeAuth.classify("/traffic/reset"), .localOnly)
        XCTAssertEqual(BridgeAuth.classify("/push-test"), .localOnly)
        XCTAssertEqual(BridgeAuth.classify("/claude/hook"), .localOnly)
        XCTAssertEqual(BridgeAuth.classify("/claude/channel/poll"), .localOnly)
        XCTAssertEqual(BridgeAuth.classify("/codex/terminal"), .localOnly)
        XCTAssertEqual(BridgeAuth.classify("/terminal/keys/poll"), .localOnly)
        XCTAssertEqual(BridgeAuth.classify("/terminal/panes/poll"), .localOnly)
        XCTAssertEqual(BridgeAuth.classify("/terminal/pane-event"), .localOnly)
        XCTAssertEqual(BridgeAuth.classify("/antigravity/hook"), .hookToken)
        XCTAssertEqual(BridgeAuth.classify("/mcp"), .mainAgentToken)
        XCTAssertNil(BridgeAuth.classify("/mcp/extra"))
        XCTAssertEqual(BridgeAuth.classify("/local/devices/reset"), .admin)
        XCTAssertEqual(BridgeAuth.classify("/device/unpair"), .deviceOnly)
        XCTAssertNil(BridgeAuth.classify("/"))
        XCTAssertNil(BridgeAuth.classify("/health/extra"))
        XCTAssertNil(BridgeAuth.classify("/register-bridge"))
    }
}
