import XCTest
@testable import BridgeApp

final class AntigravityPresenceTests: XCTestCase {
    func testDetectsHeldLockOnly() throws {
        let dir = NSTemporaryDirectory() + "presence-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let held = dir + "/live-1.lock", free = dir + "/dead-2.lock"
        FileManager.default.createFile(atPath: held, contents: nil)
        FileManager.default.createFile(atPath: free, contents: nil)

        XCTAssertTrue(AntigravityPresence.liveConversationIds(directory: dir).isEmpty, "誰も持っていなければ空")

        // 別プロセス（python）にロックを持たせる。同一プロセスの flock は排他にならないため。
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import fcntl,sys,time;f=open(sys.argv[1]);fcntl.flock(f,fcntl.LOCK_EX);print('ok',flush=True);time.sleep(30)", held]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        defer { p.terminate() }
        _ = out.fileHandleForReading.availableData   // 'ok' を待つ
        XCTAssertEqual(AntigravityPresence.liveConversationIds(directory: dir), ["live-1"])
        p.terminate(); p.waitUntilExit()
        XCTAssertTrue(AntigravityPresence.liveConversationIds(directory: dir).isEmpty, "終了後は空に戻る")
    }
}
