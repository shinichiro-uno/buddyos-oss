import XCTest
@testable import BridgeApp

/// ProcessRunner の回帰テスト。
/// 旧 `DispatchQueue.global().async { waitUntilExit }` パターンが SIGTERM を無視する
/// 子プロセスで worker スレッドを食い潰し、fd リーク → 全 spawn EBADF
/// ("Bad file descriptor") に至った障害の再発防止。
final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdoutStderrAndStatus() {
        let r = ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 5)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.status, 3)
        XCTAssertEqual(String(data: r?.stdout ?? Data(), encoding: .utf8), "out\n")
        XCTAssertEqual(String(data: r?.stderr ?? Data(), encoding: .utf8), "err\n")
        XCTAssertEqual(r?.timedOut, false)
    }

    func testLaunchFailureReturnsNil() {
        XCTAssertNil(ProcessRunner.run("/nonexistent/bin", [], timeout: 1))
    }

    /// SIGTERM を無視する子 (障害の起点だった対話 zsh 相当) でも SIGKILL で回収し、
    /// timeout + 猶予 + ドレイン見切りの範囲内で必ず戻ってくること。
    /// (`sleep` の孫プロセスがパイプ書き込み端を握ったまま残るケースも兼ねて検証。)
    func testSigtermIgnoringChildIsKilled() {
        let start = Date()
        let r = ProcessRunner.run("/bin/sh", ["-c", "trap '' TERM; sleep 30"], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(r?.timedOut, true)
        // timeout(1s) + SIGTERM 猶予(2s) + SIGKILL 確認(≤2s) + EOF 見切り(≤2s) + マージン
        XCTAssertLessThan(elapsed, 10)
    }

    /// 大量に回しても fd が増えないこと (パイプ close 漏れの検出)。
    func testNoFdLeakAcrossManyRuns() {
        func openFdCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        // dispatch source 等の初期割り当てを済ませてから測る。
        for _ in 0..<3 { _ = ProcessRunner.run("/bin/echo", ["x"], timeout: 5) }
        let before = openFdCount()
        for _ in 0..<40 { _ = ProcessRunner.run("/bin/echo", ["x"], timeout: 5) }
        let after = openFdCount()
        XCTAssertLessThanOrEqual(after, before + 4, "fd count grew: \(before) -> \(after)")
    }
}
