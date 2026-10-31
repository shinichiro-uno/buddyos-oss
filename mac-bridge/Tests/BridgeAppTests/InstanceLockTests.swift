import Foundation
import XCTest
@testable import BridgeApp

/// Bridge を 1 つだけにする鍵（別のプロセスが持っていたら取れない／持ち主が終われば取れる）。
final class InstanceLockTests: XCTestCase {
    private func tempLockPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("buddyos-lock-\(UUID().uuidString)").path
    }

    /// 別のプロセスに鍵を持たせる（python の fcntl.flock は Bridge と同じ flock）。
    private func holdInOtherProcess(_ path: String) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", """
            import fcntl, sys, time
            f = open(sys.argv[1], "a")
            fcntl.flock(f, fcntl.LOCK_EX)
            print("locked", flush=True)
            time.sleep(30)
            """, path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        _ = out.fileHandleForReading.availableData   // "locked" が出るまで待つ
        return p
    }

    func testHeldByAnotherProcessThenFreedWhenItExits() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("python3 not available") }
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let holder = try holdInOtherProcess(path)
        XCTAssertEqual(InstanceLock.tryLock(path: path), .held)

        holder.terminate()
        holder.waitUntilExit()
        guard case .acquired(let fd) = InstanceLock.tryLock(path: path) else {
            return XCTFail("lock should be free after the holder exits")
        }
        close(fd)
    }

    func testSecondAcquireInSameProcessIsHeld() {
        let path = tempLockPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        guard case .acquired(let fd) = InstanceLock.tryLock(path: path) else { return XCTFail("first lock") }
        XCTAssertEqual(InstanceLock.tryLock(path: path), .held)
        close(fd)
        guard case .acquired(let again) = InstanceLock.tryLock(path: path) else { return XCTFail("relock") }
        close(again)
    }
}
