import XCTest
@testable import BridgeApp

/// iPhone からのログイン（AgentLoginService）の流れ: 起動 → URL とコードを知らせる → 貼ったコードを
/// 標準入力へ渡す → 終わったら確かめ直す。偽の CLI（シェルスクリプト）で動かす。
final class AgentLoginServiceTests: XCTestCase {
    /// 届いた順に同期で積む。`Task { await actor.add }` だと Task の実行順が保証されず、
    /// 負荷が高いと先に送った waiting が cancelled の後ろに並ぶことがある。
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AgentLoginService.Event] = []
        var events: [AgentLoginService.Event] { lock.lock(); defer { lock.unlock() }; return stored }
        func add(_ e: AgentLoginService.Event) { lock.lock(); stored.append(e); lock.unlock() }
    }

    private func waitFor(_ c: Collected, timeout: TimeInterval = 10, _ cond: @escaping ([AgentLoginService.Event]) -> Bool) async -> [AgentLoginService.Event] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ev = c.events
            if cond(ev) { return ev }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return c.events
    }

    func testFlowWithPastedCode() async throws {
        let script = NSTemporaryDirectory() + "fake-login-\(UUID().uuidString).sh"
        try """
        #!/bin/sh
        printf '\\033[94mOpen https://example.com/device\\033[0m\\n'
        printf '   ABCD-EFGH\\n'
        read code
        echo "got:$code"
        exit 0
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let service = AgentLoginService()
        let c = Collected()
        let token = await service.subscribe { e in c.add(e) }
        defer { Task { await service.unsubscribe(token) } }

        let agent = "fake-\(UUID().uuidString.prefix(6))"
        await service.startForTesting(agentId: agent, exe: script, args: [], needsCode: true)
        let waiting = await waitFor(c) { $0.contains { $0.phase == .waiting } }
        let w = try XCTUnwrap(waiting.first { $0.phase == .waiting })
        XCTAssertEqual(w.url, "https://example.com/device")
        XCTAssertEqual(w.code, "ABCD-EFGH")
        XCTAssertTrue(w.needsCode)

        // 戻ってきた iPhone の問い合わせには、動いている途中の状態を返す。
        let mid = await service.status(agentId: agent)
        XCTAssertEqual(mid?.phase, .waiting)

        await service.submitCode(agentId: agent, code: "  pasted#state \n")
        // 偽のエージェントは AgentProbe で configured にならないので failed で終わる。出力の末尾を添える。
        let end = await waitFor(c) { $0.contains { $0.phase == .failed || $0.phase == .succeeded } }
        let last = try XCTUnwrap(end.last)
        XCTAssertEqual(last.phase, .failed)
        XCTAssertTrue(last.message?.contains("got:pasted#state") == true, last.message ?? "nil")
        XCTAssertTrue(end.contains { $0.phase == .verifying })
        // 終わったあとも、しばらくは最後の状態を返す。
        let after = await service.status(agentId: agent)
        XCTAssertEqual(after?.phase, .failed)
    }

    func testCancel() async throws {
        let script = NSTemporaryDirectory() + "fake-login-\(UUID().uuidString).sh"
        try "#!/bin/sh\necho https://example.com/x\nsleep 60\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let service = AgentLoginService()
        let c = Collected()
        _ = await service.subscribe { e in c.add(e) }
        let agent = "fake-\(UUID().uuidString.prefix(6))"
        await service.startForTesting(agentId: agent, exe: script, args: [], needsCode: false)
        _ = await waitFor(c) { $0.contains { $0.phase == .waiting } }
        await service.cancel(agentId: agent)
        let end = await waitFor(c) { $0.contains { $0.phase == .cancelled } }
        XCTAssertEqual(end.last?.phase, .cancelled)
    }
}
