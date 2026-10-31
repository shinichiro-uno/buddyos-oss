import Foundation
import NIOCore
import Vapor
import WebSocketKit
import XCTest
@testable import BridgeApp

/// /terminal/pty を本物の WebSocket と本物のシェルで確かめる（別の PC のデスクトップから操作するときの口）。
final class TerminalPtyRoutesTests: XCTestCase {
    private var app: Application!
    private var port = 0
    private let key = "test-api-key"

    override func setUp() async throws {
        app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        LocalKey.shared.replace(key)
        TerminalPtyRoutes.register(app: app)
        try await app.server.start()
        port = app.http.server.shared.localAddress?.port ?? 0
        XCTAssertGreaterThan(port, 0)
    }

    override func tearDown() async throws {
        LocalKey.shared.invalidate()
        await app.server.shutdown()
        try await app.asyncShutdown()
    }

    /// つないだ WebSocket の受け取ったものを貯める。
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var events: [[String: Any]] = []
        func add(output: String) { lock.withLock { text += output } }
        func add(event: [String: Any]) { lock.withLock { events.append(event) } }
        var output: String { lock.withLock { text } }
        func event(_ type: String) -> [String: Any]? { lock.withLock { events.first { $0["type"] as? String == type } } }
    }

    private func connect(_ query: String, apiKey: String? = nil, headers: HTTPHeaders = [:]) async throws -> (WebSocket, Inbox) {
        let inbox = Inbox()
        let url = "ws://127.0.0.1:\(port)/terminal/pty?\(query)&apiKey=\(apiKey ?? key)"
        let promise = app.eventLoopGroup.next().makePromise(of: WebSocket.self)
        WebSocket.connect(to: url, headers: headers, on: app.eventLoopGroup) { ws in
            ws.onBinary { _, buf in inbox.add(output: String(decoding: Data(buffer: buf), as: UTF8.self)) }
            ws.onText { _, text in
                guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
                inbox.add(event: obj)
                if obj["type"] as? String == "replay", let d = obj["data"] as? String { inbox.add(output: d) }
            }
            promise.succeed(ws)
        }.whenFailure { promise.fail($0) }
        return (try await promise.futureResult.get(), inbox)
    }

    private func waitUntil(_ timeout: TimeInterval = 20, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }

    private func send(_ ws: WebSocket, _ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await ws.send(String(decoding: data, as: UTF8.self))
    }

    func testShellRunsReattachesAndCloses() async throws {
        let id = "test-\(UUID().uuidString)"
        let (ws, inbox) = try await connect("id=\(id)&cols=100&rows=30")
        let attached = await waitUntil { inbox.event("attached") != nil }
        XCTAssertTrue(attached)
        XCTAssertEqual(inbox.event("attached")?["restored"] as? Bool, false)

        // 入力が端末に届き、出力が返ってくる（$((40+2)) はシェルが計算するので、打った文字のこだまとは区別できる）。
        try await send(ws, ["type": "input", "data": "echo BUDDY_$((40+2))\r"])
        let ran = await waitUntil { inbox.output.contains("BUDDY_42") }
        XCTAssertTrue(ran, "output: \(inbox.output.suffix(400))")

        // 大きさを変えると、シェルからも見える。
        try await send(ws, ["type": "resize", "cols": 123, "rows": 40])
        try await send(ws, ["type": "input", "data": "echo COLS_$(tput cols)\r"])
        let resized = await waitUntil { inbox.output.contains("COLS_123") }
        XCTAssertTrue(resized, "output: \(inbox.output.suffix(400))")

        // 切っても端末は残り、つなぎ直すと前の出力が送り直される。
        try await ws.close()
        let (ws2, inbox2) = try await connect("id=\(id)&cols=100&rows=30&attach=1")
        let reattached = await waitUntil { inbox2.event("attached") != nil }
        XCTAssertTrue(reattached)
        XCTAssertEqual(inbox2.event("attached")?["restored"] as? Bool, true)
        XCTAssertTrue(inbox2.output.contains("BUDDY_42"))

        // 閉じると、終わったことが届く。
        try await send(ws2, ["type": "kill"])
        let exited = await waitUntil(10) { inbox2.event("exit") != nil }
        XCTAssertTrue(exited)

        // 終わったペインにつなぎ直そうとすると gone。
        let (_, inbox3) = try await connect("id=\(id)&attach=1")
        let gone = await waitUntil(5) { inbox3.event("gone") != nil }
        XCTAssertTrue(gone)
    }

    /// ブラウザのページ（Origin: null の sandbox iframe・localhost のページ）からは、鍵が合っていても開かない。
    func testRejectsBrowserOrigins() async throws {
        for origin in ["null", "http://localhost:\(port)", "http://127.0.0.1:\(port)"] {
            let (ws, inbox) = try await connect("id=origin-\(UUID().uuidString)", headers: ["Origin": origin])
            let closed = await waitUntil(5) { ws.isClosed }
            XCTAssertTrue(closed, origin)
            XCTAssertNil(inbox.event("attached"), origin)
        }
        // desktop の画面の Origin は通す。
        let id = "origin-ok-\(UUID().uuidString)"
        let (ws, inbox) = try await connect("id=\(id)", headers: ["Origin": "buddyos-desktop://app"])
        let attached = await waitUntil { inbox.event("attached") != nil }
        XCTAssertTrue(attached)
        try await send(ws, ["type": "kill"])
        _ = await waitUntil(10) { inbox.event("exit") != nil }
    }

    /// 大きな貼り付けで端末の受け口が詰まっても、全ペインの queue を空回りで塞がない。
    /// 別のペインはすぐ開け、kill もすぐ届く。
    func testLargePasteDoesNotBlockOtherPanesOrKill() async throws {
        let id = "paste-\(UUID().uuidString)"
        let (ws, inbox) = try await connect("id=\(id)&cols=80&rows=24")
        let attached = await waitUntil { inbox.event("attached") != nil }
        XCTAssertTrue(attached)
        try await send(ws, ["type": "input", "data": String(repeating: "a", count: 2 * 1024 * 1024)])
        try await send(ws, ["type": "input", "data": "\u{03}"])

        // 同じ queue を使う別のペインが、貼り付けの書き込みを待たずに開ける。
        let other = "other-\(UUID().uuidString)"
        let started = Date()
        let (ws2, inbox2) = try await connect("id=\(other)")
        let otherAttached = await waitUntil(5) { inbox2.event("attached") != nil }
        XCTAssertTrue(otherAttached)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try await send(ws2, ["type": "kill"])

        // 詰まったままのペインにも kill が届く。
        try await send(ws, ["type": "input", "data": String(repeating: "b", count: 2 * 1024 * 1024)])
        try await send(ws, ["type": "kill"])
        let exited = await waitUntil(15) { inbox.event("exit") != nil }
        XCTAssertTrue(exited)
        _ = await waitUntil(10) { inbox2.event("exit") != nil }
    }

    func testChildEnvironmentDropsTokens() async throws {
        setenv("BUDDYOS_CLERK_TOKEN", "clerk-secret-for-test", 1)
        setenv("BUDDYOS_MCP_GITHUB", "mcp-secret-for-test", 1)
        defer {
            unsetenv("BUDDYOS_CLERK_TOKEN")
            unsetenv("BUDDYOS_MCP_GITHUB")
        }
        let id = "env-\(UUID().uuidString)"
        let (ws, inbox) = try await connect("id=\(id)")
        _ = await waitUntil { inbox.event("attached") != nil }
        try await send(ws, ["type": "input", "data": "echo ENV_[${BUDDYOS_CLERK_TOKEN:-none}][${BUDDYOS_MCP_GITHUB:-none}]\r"])
        let ran = await waitUntil { inbox.output.contains("ENV_[none][none]") }
        XCTAssertTrue(ran, "output: \(inbox.output.suffix(300))")
        XCTAssertFalse(inbox.output.contains("secret-for-test"))
        try await send(ws, ["type": "kill"])
        _ = await waitUntil(10) { inbox.event("exit") != nil }
    }

    /// 大量の出力でも、送りきるのを待って読みを止め・再開し、最後まで届く（固まらない）。
    func testHeavyOutputIsDeliveredWithBackpressure() async throws {
        let id = "heavy-\(UUID().uuidString)"
        let (ws, inbox) = try await connect("id=\(id)")
        _ = await waitUntil { inbox.event("attached") != nil }
        try await send(ws, ["type": "input", "data": "head -c 8000000 /dev/zero | tr '\\0' a; echo; echo HEAVY_$((40+2))\r"])
        let done = await waitUntil(60) { inbox.output.contains("HEAVY_42") }
        XCTAssertTrue(done, "output tail: \(inbox.output.suffix(200))")
        try await send(ws, ["type": "kill"])
        _ = await waitUntil(10) { inbox.event("exit") != nil }
    }

    /// 端末を外したら、その端末が開いたターミナルは止まり、つなぎ直しても gone。
    func testDropStopsOwnersTerminals() async throws {
        let id = "drop-\(UUID().uuidString)"
        let (_, inbox) = try await connect("id=\(id)")
        let attached = await waitUntil { inbox.event("attached") != nil }
        XCTAssertTrue(attached)
        XCTAssertGreaterThan(PtyRegistry.shared.count(owner: "local"), 0)
        PtyRegistry.shared.drop(owner: "local")
        let exited = await waitUntil(10) { inbox.event("exit") != nil }
        XCTAssertTrue(exited)
        let (_, inbox2) = try await connect("id=\(id)&attach=1")
        let gone = await waitUntil(5) { inbox2.event("gone") != nil }
        XCTAssertTrue(gone)
    }

    /// 直近の出力は UTF-8 の文字の途中で切らず、送り直すときは切った行の残りと、終わっていない文字を分ける。
    func testScrollbackTrimAndReplay() {
        let a = Array("あ".utf8)  // 3 バイト
        let cut = PtySession.trimmed(Data(a + a), limit: 5)
        XCTAssertEqual(String(decoding: cut, as: UTF8.self), "あ")

        let (text, tail) = PtySession.replay(Data(Array("前の行の残り\n次の行".utf8) + a.prefix(2)), trimmed: true)
        XCTAssertEqual(text, "次の行")
        XCTAssertEqual(Array(tail), Array(a.prefix(2)))

        let (whole, none) = PtySession.replay(Data("一行目\n二行目".utf8), trimmed: false)
        XCTAssertEqual(whole, "一行目\n二行目")
        XCTAssertTrue(none.isEmpty)
    }

    func testRejectsWrongApiKey() async throws {
        let (ws, inbox) = try await connect("id=x", apiKey: "wrong")
        let closed = await waitUntil(5) { ws.isClosed }
        XCTAssertTrue(closed)
        XCTAssertNil(inbox.event("attached"))
    }
}
