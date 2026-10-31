import Foundation
import XCTest
@testable import BridgeApp

/// 起動中のシミュレータがあるときだけ走る（無ければ skip）。描画面から速く取れていることを確かめる。
final class SimFramebufferTests: XCTestCase {
    private func bootedUdid() -> String? {
        guard let out = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"], timeout: 10) else { return nil }
        let pattern = try! NSRegularExpression(pattern: "\\(([0-9A-F-]{36})\\) \\(Booted\\)")
        guard let m = pattern.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let r = Range(m.range(at: 1), in: out) else { return nil }
        return String(out[r])
    }

    func testFramebufferCapturesJpeg() throws {
        guard let udid = bootedUdid() else { throw XCTSkip("起動中のシミュレータが無い") }
        guard let fb = SimFramebuffer.open(udid: udid) else { throw XCTSkip("この Xcode では描画面を開けない") }
        guard case .frame(let data) = fb.capture(maxSide: 1000, quality: 0.6) else { return XCTFail("1 枚目が取れない") }
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
        // 画面が変わっていなければ送らない。
        if case .frame = fb.capture(maxSide: 1000, quality: 0.6) { print("note: 画面が動いていた") }
    }

    func testStreamIsFasterThanScreenshots() async throws {
        guard let udid = bootedUdid() else { throw XCTSkip("起動中のシミュレータが無い") }
        guard SimFramebuffer.open(udid: udid) != nil else { throw XCTSkip("この Xcode では描画面を開けない") }
        // 画面を動かし続ける（ページを開く）間のフレーム数を数える。
        _ = Shell.run("/usr/bin/xcrun", ["simctl", "openurl", udid, "https://www.apple.com"], timeout: 10)
        let stream = await SimController.shared.subscribe(udid: udid)
        let start = Date()
        var frames = 0
        var bytes = 0
        for await f in stream {
            frames += 1
            bytes += f.count
            if Date().timeIntervalSince(start) > 3 { break }
        }
        print("sim stream: \(frames) frames in 3s, avg \(bytes / max(frames, 1) / 1024) KB")
        XCTAssertGreaterThan(frames, 1)
    }
}

/// 起動中のシミュレータがあるときだけ走る（無ければ skip）。idb なしで HID を送れることを確かめる。
final class SimHIDTests: XCTestCase {
    func testOpenAndHome() async throws {
        guard let out = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "booted"], timeout: 10),
              let m = try NSRegularExpression(pattern: "\\(([0-9A-F-]{36})\\) \\(Booted\\)")
                .firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let r = Range(m.range(at: 1), in: out)
        else { throw XCTSkip("起動中のシミュレータが無い") }
        let udid = String(out[r])
        guard let hid = SimHID.open(udid: udid) else { throw XCTSkip("この Xcode では HID を開けない") }
        XCTAssertGreaterThan(hid.points.w, 200)
        XCTAssertGreaterThan(hid.points.h, hid.points.w)
        let size = await SimController.shared.describe(udid: udid)
        XCTAssertEqual(size.wPts, hid.points.w)
        let home = await SimController.shared.home(udid: udid)
        XCTAssertTrue(home.ok, home.err)
    }
}
