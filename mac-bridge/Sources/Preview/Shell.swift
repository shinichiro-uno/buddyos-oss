import Foundation

/// Minimal blocking-Process runner for the Preview routes.
///
/// All methods run the child process on a global dispatch queue with a hard
/// timeout, so they must be invoked off the Vapor event loop. `runAsync` /
/// `runFull` bridge the blocking work into Swift concurrency via
/// `withCheckedContinuation` on a detached background queue.
enum Shell {
    struct Output: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Blocking. stdout only, or nil on launch failure / timeout. (sync helper)
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> String? {
        let r = runBlocking(launchPath, args, timeout: timeout)
        guard let r, r.exitCode == 0 else { return nil }
        return r.stdout
    }

    /// Async stdout-or-nil convenience.
    static func runAsync(_ launchPath: String, _ args: [String], timeout: TimeInterval) async -> String? {
        let r = await runFull(launchPath, args, timeout: timeout)
        guard r.exitCode == 0 else { return nil }
        return r.stdout
    }

    /// Async full result (exit code + stdout + stderr). Runs off the event loop.
    static func runFull(_ launchPath: String, _ args: [String], timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = runBlocking(launchPath, args, timeout: timeout)
                    ?? Output(exitCode: -1, stdout: "", stderr: "launch failed: \(launchPath)")
                cont.resume(returning: r)
            }
        }
    }

    /// The actual blocking call. Returns nil only if the process fails to launch.
    /// ProcessRunner 経由 (waitUntilExit のスレッド滞留 → fd リーク → EBADF 障害の再発防止)。
    private static func runBlocking(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> Output? {
        guard let r = ProcessRunner.run(launchPath, args, timeout: timeout) else { return nil }
        if r.timedOut {
            return Output(exitCode: -2, stdout: "", stderr: "timeout after \(timeout)s")
        }
        return Output(
            exitCode: r.status,
            stdout: String(data: r.stdout, encoding: .utf8) ?? "",
            stderr: String(data: r.stderr, encoding: .utf8) ?? ""
        )
    }
}
