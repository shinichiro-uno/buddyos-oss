import Darwin
import Foundation
import NIOCore
import Vapor
import WebSocketKit
import XCTest
@testable import BridgeApp

/// /terminal/share（開いているペインを別の PC から見る口）を、本物の WebSocket と偽の常駐プロセスで確かめる。
final class TerminalShareRoutesTests: XCTestCase {
    private var app: Application!
    private var port = 0
    private var root: URL!
    private let key = "test-api-key"
    private let deviceKey = "SHARETESTKEY000000000A"
    private let credential = "bdc_share_test_credential"

    override func setUp() async throws {
        root = try makeTempDir("terminal-share")
        BuddyPaths.setOverride(root)
        DeviceStore.shared.load()
        let row = DeviceStore.Device(pub: "p", clientDeviceId: "device-share-1", name: "iPhone", label: nil, platform: "ios",
                                     credHash: TunnelV3.credentialHash(credential), via: "qr",
                                     createdAt: DeviceStore.nowMs(), lastSeenAt: nil, push: nil)
        XCTAssertTrue(DeviceStore.shared.insertPending(deviceKeyId: deviceKey, device: row, epoch: DeviceStore.shared.epoch))
        XCTAssertTrue(DeviceStore.shared.confirmPending(deviceKeyId: deviceKey, credHash: row.credHash, epoch: DeviceStore.shared.epoch))

        app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        LocalKey.shared.replace(key)
        TerminalShareRoutes.register(app: app)
        try await app.server.start()
        port = app.http.server.shared.localAddress?.port ?? 0
        XCTAssertGreaterThan(port, 0)
    }

    override func tearDown() async throws {
        PaneShareHub.shared.drop()
        PaneShareHub.hostWait = 5
        PaneShareHub.attachWait = 15
        LocalKey.shared.invalidate()
        await app.server.shutdown()
        try await app.asyncShutdown()
        BuddyPaths.setOverride(nil)
        try? FileManager.default.removeItem(at: root)
    }

    /// 受け取ったものを順に貯める（JSON は "type" か "t" で引く。バイナリは出力として足す）。
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var events: [[String: Any]] = []
        func add(output: String) { lock.withLock { text += output } }
        func add(event: [String: Any]) { lock.withLock { events.append(event) } }
        var output: String { lock.withLock { text } }
        var all: [[String: Any]] { lock.withLock { events } }
        func kinds() -> [String] { all.compactMap { ($0["type"] ?? $0["t"]) as? String } }
        func event(_ kind: String) -> [String: Any]? { all.first { ($0["type"] ?? $0["t"]) as? String == kind } }
        func events(_ kind: String) -> [[String: Any]] { all.filter { ($0["type"] ?? $0["t"]) as? String == kind } }
    }

    private func connect(_ path: String) async throws -> (WebSocket, Inbox) {
        let inbox = Inbox()
        let url = "ws://127.0.0.1:\(port)\(path)\(path.contains("?") ? "&" : "?")apiKey=\(key)"
        let promise = app.eventLoopGroup.next().makePromise(of: WebSocket.self)
        WebSocket.connect(to: url, on: app.eventLoopGroup) { ws in
            ws.onBinary { _, buf in inbox.add(output: String(decoding: Data(buffer: buf), as: UTF8.self)) }
            ws.onText { _, text in
                guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
                inbox.add(event: obj)
            }
            promise.succeed(ws)
        }.whenFailure { promise.fail($0) }
        return (try await promise.futureResult.get(), inbox)
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    private func send(_ ws: WebSocket, _ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await ws.send(String(decoding: data, as: UTF8.self))
    }

    /// 偽の常駐プロセスをつなぎ、ペインの一覧を送って、一覧に載るまで待つ。
    private func host(client: String, panes: [String]) async throws -> (WebSocket, Inbox) {
        let (ws, inbox) = try await connect("/terminal/share/host?client=\(client)")
        try await send(ws, ["t": "panes", "panes": panes.map { ["id": $0, "agentId": "claude", "cwd": "/tmp", "cols": 100, "rows": 30] }])
        for p in panes {
            var listed = false
            let end = Date().addingTimeInterval(10)
            while Date() < end {
                if await PaneShareHub.shared.list().panes.contains(where: { $0.info.id == p }) { listed = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(listed, p)
        }
        return (ws, inbox)
    }

    private func getPanes() async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/terminal/share/panes")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, res) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((res as? HTTPURLResponse)?.statusCode, 200)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func testClassify() {
        XCTAssertEqual(BridgeAuth.classify("/terminal/share"), .any(allowQuery: true))
        XCTAssertEqual(BridgeAuth.classify("/terminal/share?pane=x&apiKey=y"), .any(allowQuery: true))
        XCTAssertEqual(BridgeAuth.classify("/terminal/share/panes"), .any(allowQuery: false))
        XCTAssertEqual(BridgeAuth.classify("/terminal/share/host"), .localOnly)
        XCTAssertNil(BridgeAuth.classify("/terminal/share/other"))
        XCTAssertEqual(PaneShareHub.validClient(nil), "default")
        XCTAssertEqual(PaneShareHub.validClient("dev.build_1-x"), "dev.build_1-x")
        XCTAssertNil(PaneShareHub.validClient("a b"))
        XCTAssertNil(PaneShareHub.validClient(String(repeating: "a", count: 65)))
    }

    /// attach → attached / replay / size が届き、入力・大きさは sid 付きで常駐プロセスへ、出力はバイナリで、exit で閉じる。
    func testRelaysBetweenHostAndViewer() async throws {
        let pane = "pane-\(UUID().uuidString)"
        let (hws, hin) = try await host(client: "relay-\(UUID().uuidString.prefix(8))", panes: [pane])
        let (vws, vin) = try await connect("/terminal/share?pane=\(pane)&cols=90&rows=20")

        let gotAttach = await waitUntil { hin.event("attach") != nil }
        XCTAssertTrue(gotAttach)
        let attach = try XCTUnwrap(hin.event("attach"))
        let sid = try XCTUnwrap(attach["sid"] as? String)
        XCTAssertTrue(sid.hasPrefix("v"))
        XCTAssertEqual(attach["id"] as? String, pane)
        XCTAssertNil(attach["name"], "この PC の中からなら名前は付けない")
        XCTAssertEqual(attach["cols"] as? Int, 90)
        XCTAssertEqual(attach["rows"] as? Int, 20)

        try await send(hws, ["t": "attached", "sid": sid, "cols": 100, "rows": 30, "snapshot": "HELLO"])
        let gotSize = await waitUntil { vin.event("size") != nil }
        XCTAssertTrue(gotSize)
        XCTAssertEqual(vin.kinds(), ["attached", "replay", "size"])
        XCTAssertEqual(vin.event("attached")?["restored"] as? Bool, true)
        XCTAssertEqual(vin.event("replay")?["data"] as? String, "HELLO")
        XCTAssertEqual(vin.event("size")?["cols"] as? Int, 100)
        XCTAssertEqual(vin.event("size")?["rows"] as? Int, 30)

        // 一覧に見ている数が出る。
        let list = try await getPanes()
        XCTAssertEqual(list["available"] as? Bool, true)
        let row = (list["panes"] as? [[String: Any]])?.first { $0["id"] as? String == pane }
        XCTAssertEqual(row?["viewers"] as? Int, 1)
        XCTAssertEqual(row?["agentId"] as? String, "claude")

        // kill は捨てる。入力・大きさは sid 付きで届く（大きさは 2〜1000 に収める）。
        try await send(vws, ["type": "kill"])
        try await send(vws, ["type": "input", "data": "ls\r"])
        try await send(vws, ["type": "resize", "cols": 5000, "rows": 1])
        let gotResize = await waitUntil { hin.event("resize") != nil }
        XCTAssertTrue(gotResize)
        XCTAssertEqual(hin.kinds(), ["attach", "input", "resize"])
        XCTAssertEqual(hin.event("input")?["sid"] as? String, sid)
        XCTAssertEqual(hin.event("input")?["data"] as? String, "ls\r")
        XCTAssertEqual(hin.event("resize")?["cols"] as? Int, 1000)
        XCTAssertEqual(hin.event("resize")?["rows"] as? Int, 2)

        // 出力はバイナリ（UTF-8）で届く。知らない sid の出力は捨てる。
        try await send(hws, ["t": "data", "sid": "v-unknown", "data": "NOPE"])
        try await send(hws, ["t": "data", "sid": sid, "data": "あいう"])
        let gotData = await waitUntil { vin.output.contains("あいう") }
        XCTAssertTrue(gotData)
        XCTAssertFalse(vin.output.contains("NOPE"))

        try await send(hws, ["t": "size", "sid": sid, "cols": 120, "rows": 40])
        let resized = await waitUntil { vin.events("size").count == 2 }
        XCTAssertTrue(resized)
        XCTAssertEqual(vin.events("size").last?["cols"] as? Int, 120)

        // replay（resync の答え）は写しと大きさで届く。
        try await send(hws, ["t": "replay", "sid": sid, "cols": 120, "rows": 40, "snapshot": "AGAIN"])
        let replayed = await waitUntil { vin.events("replay").count == 2 }
        XCTAssertTrue(replayed)
        XCTAssertEqual(vin.events("replay").last?["data"] as? String, "AGAIN")

        try await send(hws, ["t": "exit", "sid": sid, "code": 3])
        let closed = await waitUntil { vws.isClosed }
        XCTAssertTrue(closed)
        XCTAssertEqual(vin.event("exit")?["code"] as? Int, 3)
        XCTAssertEqual(PaneShareHub.shared.viewerCount(), 0)
        try await hws.close()
    }

    /// A が閉じたら detach。B の端末は止めない（kill は送らない）。
    func testViewerCloseSendsDetach() async throws {
        let pane = "pane-\(UUID().uuidString)"
        let (hws, hin) = try await host(client: "detach-\(UUID().uuidString.prefix(8))", panes: [pane])
        let (vws, _) = try await connect("/terminal/share?pane=\(pane)")
        _ = await waitUntil { hin.event("attach") != nil }
        let sid = try XCTUnwrap(hin.event("attach")?["sid"] as? String)
        XCTAssertNil(hin.event("attach")?["cols"], "大きさを付けてこなければ載せない")
        try await vws.close()
        let detached = await waitUntil { hin.event("detach") != nil }
        XCTAssertTrue(detached)
        XCTAssertEqual(hin.event("detach")?["sid"] as? String, sid)
        try await hws.close()
    }

    /// どの常駐プロセスもそのペインを持っていなければ、待ってから gone で閉じる。
    func testNoHostSendsGone() async throws {
        PaneShareHub.hostWait = 1
        let (vws, vin) = try await connect("/terminal/share?pane=missing-\(UUID().uuidString)")
        let gone = await waitUntil(5) { vin.event("gone") != nil && vws.isClosed }
        XCTAssertTrue(gone)
    }

    /// 先につないだ人は、ペインの一覧が届いた時点でつながる。
    func testViewerWaitsForPanes() async throws {
        let pane = "pane-\(UUID().uuidString)"
        let (hws, hin) = try await connect("/terminal/share/host?client=wait-\(UUID().uuidString.prefix(8))")
        let (_, vin) = try await connect("/terminal/share?pane=\(pane)")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(hin.event("attach"))
        try await send(hws, ["t": "panes", "panes": [["id": pane, "cols": 80, "rows": 24]]])
        let attached = await waitUntil(4) { hin.event("attach") != nil }
        XCTAssertTrue(attached)
        let sid = try XCTUnwrap(hin.event("attach")?["sid"] as? String)
        try await send(hws, ["t": "gone", "sid": sid])
        let gone = await waitUntil { vin.event("gone") != nil }
        XCTAssertTrue(gone)
        try await hws.close()
    }

    /// attach に答えが無ければ閉じ、常駐プロセスには detach を送る。
    func testAttachTimeoutCloses() async throws {
        PaneShareHub.attachWait = 1
        let pane = "pane-\(UUID().uuidString)"
        let (hws, hin) = try await host(client: "timeout-\(UUID().uuidString.prefix(8))", panes: [pane])
        let (vws, vin) = try await connect("/terminal/share?pane=\(pane)")
        let closed = await waitUntil(5) { vws.isClosed }
        XCTAssertTrue(closed)
        XCTAssertNil(vin.event("gone"), "つなぎ直してもらうので gone は送らない")
        let detached = await waitUntil { hin.event("detach") != nil }
        XCTAssertTrue(detached)
        try await hws.close()
    }

    /// 同じ client の新しい接続は古い方（4000）とその見ている人を閉じる。違う client は並んでつながる。常駐プロセスが切れたら見ている人も閉じる。
    func testHostReplacementAndClose() async throws {
        let client = "repl-\(UUID().uuidString.prefix(8))"
        let pane = "pane-\(UUID().uuidString)"
        let before = PaneShareHub.shared.hostCount
        let (old, oldIn) = try await host(client: client, panes: [pane])
        let (vws, _) = try await connect("/terminal/share?pane=\(pane)")
        _ = await waitUntil { oldIn.event("attach") != nil }

        let other = "other-\(UUID().uuidString.prefix(8))"
        let pane2 = "pane-\(UUID().uuidString)"
        let (ows, oin) = try await host(client: other, panes: [pane2])
        XCTAssertEqual(PaneShareHub.shared.hostCount, before + 2)

        let (new, _) = try await host(client: client, panes: [pane])
        let replaced = await waitUntil { old.isClosed && vws.isClosed }
        XCTAssertTrue(replaced)
        XCTAssertEqual(old.closeCode, .unknown(4000))
        XCTAssertEqual(PaneShareHub.shared.hostCount, before + 2)

        // 別の client の見ている人は、その常駐プロセスが切れたら閉じる。
        let (v2, _) = try await connect("/terminal/share?pane=\(pane2)")
        _ = await waitUntil { oin.event("attach") != nil }
        try await ows.close()
        let closed = await waitUntil { v2.isClosed }
        XCTAssertTrue(closed)
        _ = await waitUntil { PaneShareHub.shared.hostCount == before + 1 }
        XCTAssertEqual(PaneShareHub.shared.hostCount, before + 1)
        try await new.close()
        _ = await waitUntil { PaneShareHub.shared.hostCount == before }
    }

    /// 端末を外したら、その端末が見ているものは閉じる（常駐プロセスには detach）。
    func testDropClosesOwnersViewers() async throws {
        let pane = "pane-\(UUID().uuidString)"
        let (hws, hin) = try await host(client: "drop-\(UUID().uuidString.prefix(8))", panes: [pane])
        let (vws, vin) = try await connect("/terminal/share?pane=\(pane)")
        _ = await waitUntil { hin.event("attach") != nil }
        XCTAssertEqual(PaneShareHub.shared.viewerCount(owner: "local"), 1)
        PaneShareHub.shared.drop(owner: "someone-else")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(vws.isClosed)
        PaneShareHub.shared.drop(owner: "local")
        let closed = await waitUntil { vws.isClosed }
        XCTAssertTrue(closed)
        XCTAssertEqual(vin.event("exit")?["code"] as? Int, -1)
        let detached = await waitUntil { hin.event("detach") != nil }
        XCTAssertTrue(detached)
        XCTAssertFalse(hws.isClosed, "常駐プロセスの接続は残す")
        try await hws.close()
    }

    /// 常駐プロセスの口は、トンネル経由の端末（bdc_）からは開けない。
    func testHostRejectsTunnelPrincipal() async throws {
        let before = PaneShareHub.shared.hostCount
        for cred in [credential, key] {
            let reply = try await rawUpgrade("/terminal/share/host?client=tunnel", bearer: cred, tunnel: true)
            // 開いてすぐ 1008（policyViolation）で閉じられる。
            XCTAssertTrue(reply.starts(with: Array("HTTP/1.1 101".utf8)), String(decoding: reply.prefix(40), as: UTF8.self))
            XCTAssertNotNil(reply.firstRange(of: [0x88, 0x02, 0x03, 0xF0]), cred)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(PaneShareHub.shared.hostCount, before)
    }

    /// WebSocket の upgrade を生の TCP で送る。tunnel なら、この接続のローカル側の番号を TunnelPeers に入れる。
    private func rawUpgrade(_ path: String, bearer: String, tunnel: Bool) async throws -> [UInt8] {
        let port = self.port
        let deviceKey = self.deviceKey
        return try await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
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
            let lines = [
                "GET \(path) HTTP/1.1", "Host: 127.0.0.1:\(port)", "Upgrade: websocket", "Connection: Upgrade",
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version: 13", "Authorization: Bearer \(bearer)",
            ]
            let req = lines.joined(separator: "\r\n") + "\r\n\r\n"
            _ = req.withCString { Darwin.send(fd, $0, strlen($0), 0) }
            var out: [UInt8] = []
            var buf = [UInt8](repeating: 0, count: 4096)
            while out.firstRange(of: [0x88, 0x02]) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            // 閉じる枠の残り（番号の 2 バイト）まで読む。
            if let r = out.firstRange(of: [0x88, 0x02]), out.count < r.upperBound + 2 {
                let n = recv(fd, &buf, buf.count, 0)
                if n > 0 { out.append(contentsOf: buf[0..<n]) }
            }
            return out
        }.value
    }
}
