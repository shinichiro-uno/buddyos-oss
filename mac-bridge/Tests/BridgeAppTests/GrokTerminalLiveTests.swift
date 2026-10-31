import XCTest
@testable import BridgeApp

/// ターミナルの grok（leader に乗る設定）の会話を、Bridge が開いてリアルタイムに受け取れるか（手動実行）。
/// 事前に scripts/install-grok-remote.sh で use_leader を入れておく。
/// `BUDDYOS_LIVE_GROK_TERMINAL=1 swift test --filter GrokTerminalLiveTests`
final class GrokTerminalLiveTests: XCTestCase {
    func testTerminalTurnReachesBridge() async throws {
        guard ProcessInfo.processInfo.environment["BUDDYOS_LIVE_GROK_TERMINAL"] == "1" else {
            throw XCTSkip("BUDDYOS_LIVE_GROK_TERMINAL=1 のときだけ実行")
        }
        // grok は実体のパス（/private/var/…）で会話を記録するので、作業フォルダも実体のパスで渡す。
        let tmp = FileManager.default.temporaryDirectory.path
        let cwd = URL(fileURLWithPath: (tmp.hasPrefix("/var/") ? "/private" + tmp : tmp) + "/grok-term-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let exe = HeadlessCliAdapter.locateExecutable(.grok)

        // ターミナルの grok（TUI）を疑似端末で動かす。script(1) が pty を用意し、stdin を端末への入力として渡す。
        let tui = Process()
        tui.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        tui.arguments = ["-q", "/dev/null", exe]
        tui.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        tui.environment = env
        let input = Pipe()
        tui.standardInput = input
        tui.standardOutput = FileHandle.nullDevice
        tui.standardError = FileHandle.nullDevice
        try tui.run()
        defer { tui.terminate() }
        func type(_ text: String) async throws {
            for ch in text { input.fileHandleForWriting.write(Data(String(ch).utf8)); try await Task.sleep(nanoseconds: 20_000_000) }
            try await Task.sleep(nanoseconds: 500_000_000)
            input.fileHandleForWriting.write(Data("\r".utf8))
        }
        try await Task.sleep(nanoseconds: 12_000_000_000)
        try await type("Reply with exactly: TUI_ONE")
        try await Task.sleep(nanoseconds: 25_000_000_000)

        // ターミナルで開いている会話を探す（一覧の terminal 印）。
        let adapter = HeadlessCliAdapter(profile: .grok)
        XCTAssertTrue(adapter.capabilities.terminal, "leader のある grok はターミナル連携を申告する")
        let live = GrokPresence.liveSessionIds()
        let list = await adapter.listSessions(limit: 50, cwd: cwd.path)
        print("LIVE list:", list.map { "\($0.sessionId.prefix(8)) terminal=\($0.terminal) \($0.title)" }, "presence:", live.count)
        let sid = try XCTUnwrap(list.first?.sessionId)
        XCTAssertTrue(live.contains(sid), "ターミナルの grok が開いている会話として見つかる")

        let session = await adapter.openSession(sessionId: sid, cwd: cwd.path)
        let collector = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            for try await e in session.events {
                out.append(e)
                if e.type == .done { break }
            }
            return out
        }
        try await Task.sleep(nanoseconds: 6_000_000_000)
        try await type("Reply with exactly: TUI_TWO")
        let events: [SessionEvent]
        do {
            events = try await withTimeout(seconds: 90) { (try? await collector.value) ?? [] }
        } catch {
            await session.close()
            let partial = (try? await collector.value) ?? []
            print("LIVE partial:", partial.map { "\($0.type):\(($0.content ?? "").prefix(30))" })
            throw error
        }
        let users = events.filter { $0.type == .userMessage }.compactMap(\.content)
        let text = events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        print("LIVE users:", users, "text:", text.suffix(40))
        XCTAssertTrue(users.contains { $0.contains("TUI_TWO") }, "ターミナルで打った発言が届く")
        XCTAssertTrue(text.contains("TUI_TWO"), "ターミナルのターンの返事が届く")
        await session.close()
    }
}
