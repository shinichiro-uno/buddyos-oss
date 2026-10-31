import XCTest
@testable import BridgeApp

/// ターミナルの agy（TUI）の会話を Bridge が流せるか、iPhone から送った文が入るか（手動実行）。
/// 事前に scripts/install-agy-remote.sh で受け取り箱の hook を入れておく。
/// `BUDDYOS_LIVE_AGY_TERMINAL=1 swift test --filter AntigravityTerminalLiveTests`
final class AntigravityTerminalLiveTests: XCTestCase {
    func testTerminalTurnsAndInbox() async throws {
        guard ProcessInfo.processInfo.environment["BUDDYOS_LIVE_AGY_TERMINAL"] == "1" else {
            throw XCTSkip("BUDDYOS_LIVE_AGY_TERMINAL=1 のときだけ実行")
        }
        XCTAssertTrue(AgyInbox.isInstalled(), "ターミナル連携の hook が入っている")
        let tmp = FileManager.default.temporaryDirectory.path
        let cwd = URL(fileURLWithPath: (tmp.hasPrefix("/var/") ? "/private" + tmp : tmp) + "/agy-term-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let before = AntigravityPresence.liveConversationIds()

        let screen = cwd.appendingPathComponent("screen.txt").path
        let tui = Process()
        tui.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        tui.arguments = ["-q", screen, HeadlessCliAdapter.locateExecutable(.antigravity), "--add-dir", cwd.path]
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
        try await type("Reply with exactly: AGY_ONE")
        try await Task.sleep(nanoseconds: 30_000_000_000)

        let opened = AntigravityPresence.liveConversationIds().subtracting(before)
        print("LIVE new terminal conversations:", opened)
        let cid = try XCTUnwrap(opened.first, "ターミナルの agy の会話が見つかる")
        let session = await HeadlessCliAdapter(profile: .antigravity).openSession(sessionId: cid, cwd: cwd.path)
        let log = EventLog()
        let pump = Task { do { for try await e in session.events { await log.add(e) } } catch {} }

        // 1) ターミナルで打ったターンが流れる。
        try await type("Reply with exactly: AGY_TWO")
        try await log.waitForDone(count: 1, timeout: 90)
        // 2) iPhone から送る → ターミナルで次に打ったときに入る。
        await session.send("Also include the word FROM_PHONE in your next reply.", skills: [], attachments: [])
        try await log.waitForDone(count: 2, timeout: 10)   // 受け取り箱に置いた時点で完了を返す
        try await type("Reply with exactly: AGY_THREE")
        try await log.waitForDone(count: 3, timeout: 120)
        let events = await log.events
        let users = events.filter { $0.type == .userMessage }.compactMap(\.content)
        let text = events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined(separator: " | ")
        print("LIVE users:", users)
        print("LIVE assistant:", text)
        XCTAssertTrue(users.contains { $0.contains("AGY_TWO") })
        XCTAssertTrue(text.contains("AGY_TWO"))
        XCTAssertTrue(text.contains("FROM_PHONE"), "iPhone から送った文が会話に入る")
        pump.cancel()
        await session.close()
    }
}

private actor EventLog {
    private(set) var events: [SessionEvent] = []
    func add(_ e: SessionEvent) { events.append(e) }
    func doneCount() -> Int { events.filter { $0.type == .done }.count }
    func waitForDone(count: Int, timeout: TimeInterval) async throws {
        let end = Date().addingTimeInterval(timeout)
        while doneCount() < count {
            if Date() > end { throw NSError(domain: "live", code: 1, userInfo: [NSLocalizedDescriptionKey: "done \(count) not reached: \(events.map { "\($0.type)" })"]) }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
