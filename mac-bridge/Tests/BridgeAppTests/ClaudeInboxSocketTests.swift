import XCTest
@testable import BridgeApp

/// Claude Code の受け箱（cross-session messaging の Unix ソケット）へ書く形式の確認。
/// 1 行 1 JSON の user メッセージで、認証行（auth）は付けない。
final class ClaudeInboxSocketTests: XCTestCase {

    func testPostsSingleUserLineWithoutAuth() throws {
        let path = "/tmp/buddy-inbox-test-\(UUID().uuidString.prefix(8)).sock"
        let server = try UnixLineServer(path: path)
        defer { server.close() }

        try ClaudeInboxSocket.post(text: "こんにちは\n2 行目", socketPath: path)

        let lines = server.readAll().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1, "auth 行を付けず 1 行だけ送る: \(lines)")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "user")
        let msg = try XCTUnwrap(obj["message"] as? [String: Any])
        XCTAssertEqual(msg["role"] as? String, "user")
        XCTAssertEqual(msg["content"] as? String, "こんにちは\n2 行目")
    }

    func testMissingSocketThrows() {
        XCTAssertThrowsError(try ClaudeInboxSocket.post(text: "x", socketPath: "/tmp/no-such-\(UUID().uuidString).sock"))
    }
}

/// 1 接続だけ受けて、相手が閉じるまで読む最小のサーバ。
private final class UnixLineServer {
    private let fd: Int32
    private let path: String

    init(path: String) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { _ = strncpy($0, path, maxLen - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard rc == 0, listen(fd, 1) == 0 else { throw NSError(domain: "bind", code: Int(errno)) }
    }

    func readAll() -> String {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { return "" }
        defer { Darwin.close(c) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return String(decoding: data, as: UTF8.self)
    }

    func close() {
        Darwin.close(fd)
        unlink(path)
    }
}
