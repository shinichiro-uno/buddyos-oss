import Darwin
import XCTest
@testable import BridgeApp

/// 待ち受けの番号を探す処理（ほかのアプリが使っている番号を避ける）。
final class PortPickerTests: XCTestCase {
    /// ポートを開いて持っておく（ほかのアプリの役）。
    private func occupy(_ port: Int, host: in_addr_t = INADDR_ANY) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: host.bigEndian)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        Darwin.listen(fd, 1)
        return fd
    }

    func testBusyPortIsSkipped() throws {
        // 使われていなさそうな番号の並びで試す
        let base = 47_710
        guard PortPicker.isFree(base), PortPicker.isFree(base + 1) else { throw XCTSkip("test ports in use") }
        let fd = occupy(base)
        defer { close(fd) }
        XCTAssertFalse(PortPicker.isFree(base))
        XCTAssertEqual(PortPicker.firstFree(from: base, count: 4), base + 1)
    }

    /// 127.0.0.1 だけで待ち受けるアプリ（開発用の http-server など）も使用中と見る。
    func testLoopbackOnlyListenerIsBusy() throws {
        let base = 47_730
        guard PortPicker.isFree(base) else { throw XCTSkip("test port in use") }
        let fd = occupy(base, host: INADDR_LOOPBACK)
        defer { close(fd) }
        XCTAssertFalse(PortPicker.isFree(base))
    }

    func testFreePortIsReturnedAsIs() throws {
        let base = 47_720
        guard PortPicker.isFree(base) else { throw XCTSkip("test port in use") }
        XCTAssertEqual(PortPicker.firstFree(from: base, count: 4), base)
    }
}
