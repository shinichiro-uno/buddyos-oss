import Darwin
import XCTest
@testable import BridgeApp

/// 管理鍵の受け取り（spec/PROTOCOL-v3.md Appendix A）。stdin の 1 行・形が違う・TTY・EOF で窓が閉じる。
final class AdminKeyTests: XCTestCase {
    private let key = "bda_" + String(repeating: "x", count: 43)

    private func pipeFDs() throws -> (r: Int32, w: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EIO) }
        return (fds[0], fds[1])
    }

    private func write(_ fd: Int32, _ s: String) {
        _ = s.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    func testReadsOneLine() throws {
        let (r, w) = try pipeFDs()
        defer { close(r); close(w) }
        write(w, "{\"adminKey\":\"\(key)\"}\n")
        XCTAssertEqual(AdminChannel.readAdminKey(fd: r, timeout: 2), key)
    }

    func testRejectsMalformed() throws {
        for line in ["{\"adminKey\":\"bda_short\"}\n", "{\"adminKey\":\"xyz_\(String(repeating: "x", count: 43))\"}\n",
                     "not json\n", String(repeating: "a", count: 300) + "\n"] {
            let (r, w) = try pipeFDs()
            write(w, line)
            XCTAssertNil(AdminChannel.readAdminKey(fd: r, timeout: 1), line)
            close(r); close(w)
        }
    }

    func testTimesOutWithoutLine() throws {
        let (r, w) = try pipeFDs()
        defer { close(r); close(w) }
        let start = Date()
        XCTAssertNil(AdminChannel.readAdminKey(fd: r, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testEOFBeforeLine() throws {
        let (r, w) = try pipeFDs()
        close(w)
        defer { close(r) }
        XCTAssertNil(AdminChannel.readAdminKey(fd: r, timeout: 1))
    }

    func testEOFClosesWindow() throws {
        let (r, w) = try pipeFDs()
        let closed = expectation(description: "EOF")
        let q = ApprovalQueue()
        q.openWindow()
        AdminChannel.watchEOF(fd: r) {
            q.closeWindow(reason: .closed)
            closed.fulfill()
        }
        write(w, "keepalive\n")
        close(w)
        wait(for: [closed], timeout: 3)
        XCTAssertNil(q.windowOpenUntil)
    }

    func testAdminKeySetOnceAndShape() {
        let a = AdminKey()
        XCTAssertFalse(a.isAvailable)
        XCTAssertFalse(a.set("bda_short"))
        XCTAssertTrue(a.set(key))
        XCTAssertFalse(a.set("bda_" + String(repeating: "y", count: 43)), "1 回だけ入る")
        XCTAssertTrue(a.matches(key))
        XCTAssertFalse(a.matches("bda_" + String(repeating: "y", count: 43)))
    }

    /// TTY なら読まない（手で起こした Bridge）。
    func testTTYIsNotRead() throws {
        var master: Int32 = 0, slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw XCTSkip("openpty unavailable") }
        defer { close(master); close(slave) }
        XCTAssertEqual(isatty(slave), 1)
        let admin = AdminKey()
        write(master, "{\"adminKey\":\"\(key)\"}\n")
        XCTAssertFalse(AdminChannel.start(fd: slave, adminKey: admin, onEOF: {}))
        XCTAssertFalse(admin.isAvailable)
    }

    func testStartWithPipeSetsKey() throws {
        let (r, w) = try pipeFDs()
        defer { close(r); close(w) }
        write(w, "{\"adminKey\":\"\(key)\"}\n")
        let admin = AdminKey()
        XCTAssertTrue(AdminChannel.start(fd: r, adminKey: admin, onEOF: {}))
        XCTAssertTrue(admin.matches(key))
    }
}
