import Foundation

/// 短命な子プロセスを「タイムアウト付き・GCD スレッド非占有」で同期実行する共通ランナー。
///
/// 旧来の各所にあった `DispatchQueue.global().async { proc.waitUntilExit() }` +
/// `DispatchGroup.wait` パターンは、子が SIGTERM を無視して居座る(対話 zsh 等)と
/// worker スレッドを 1 本ずつ潰し、グローバルプール上限 (64) で飽和する。飽和後は
/// waitUntilExit クロージャがキューに滞留したまま Process と Pipe (fd 4 本) を永久保持し、
/// fd テーブルが満杯になった時点で全エージェントの spawn が EBADF
/// ("Bad file descriptor") で失敗する障害を起こした。
///
/// 本ランナーの保証:
/// - 終了検知は terminationHandler で受け、待機スレッドを一切追加しない
///   (ブロックするのは呼び出し元スレッドだけ。旧実装と同じ)。
/// - timeout 時は SIGTERM → 2 秒猶予 → SIGKILL とエスカレーションし、子の残留を許さない。
/// - stdout/stderr は readabilityHandler で吸い上げ、終了後に必ず fd を close する。
///   孫プロセスがパイプの書き込み端を握ったまま生き残っても EOF 待ちでハングしない。
enum ProcessRunner {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
    }

    /// 起動失敗時のみ nil。タイムアウト時は `timedOut = true`(それまでの部分出力付き)。
    static func run(
        _ executable: String,
        _ args: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) -> Output? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        // 指定が無くても Bridge の環境変数を丸ごとは渡さない（Clerk / MCP のトークンを外す）。
        proc.environment = environment ?? ChildEnvironment.base()
        if let currentDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory, isDirectory: true)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // 対話シェル等が stdin を待って居座らないよう、常に EOF を与える。
        proc.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }

        do {
            try proc.run()
        } catch {
            // fd 枯渇時は Pipe() 自体が無効 fd を抱えるため、握った端は明示的に手放す。
            try? outPipe.fileHandleForReading.close()
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForWriting.close()
            return nil
        }

        // 読み取りは run() 成功後に登録する(無効 fd へ dispatch source を張らないため)。
        // 登録前に届いた分はパイプバッファに溜まり、初回の availableData で読める。
        let stdoutBuf = drain(outPipe.fileHandleForReading)
        let stderrBuf = drain(errPipe.fileHandleForReading)

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            let pid = proc.processIdentifier
            proc.terminate()
            // 対話 zsh などは SIGTERM を無視するため、猶予後に SIGKILL で確実に落とす。
            if exited.wait(timeout: .now() + 2.0) == .timedOut, pid > 0 {
                kill(pid, SIGKILL)
                _ = exited.wait(timeout: .now() + 2.0)
            }
        }

        // 残りの出力が流れ切る (EOF) のを短時間だけ待つ。孫プロセスが書き込み端を
        // 握っていて EOF が来ないケースでも 1 秒で見切り、部分出力で返す。
        _ = stdoutBuf.eof.wait(timeout: .now() + 1.0)
        _ = stderrBuf.eof.wait(timeout: .now() + 1.0)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        // SIGKILL 後も万一終了通知が来ていない場合、terminationStatus は例外を投げるので触らない。
        let status: Int32 = proc.isRunning ? -1 : proc.terminationStatus
        return Output(status: status, stdout: stdoutBuf.data, stderr: stderrBuf.data, timedOut: timedOut)
    }

    /// async 版。待つのは Swift の協調スレッドではなく専用キューのスレッド。
    /// async の文脈から同期版を直接呼ぶと、タイムアウトまで協調スレッドを 1 本ふさぐ（数が少ないので全体が止まる）。
    static func runAsync(
        _ executable: String,
        _ args: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil,
        currentDirectory: String? = nil
    ) async -> Output? {
        await offload {
            run(executable, args, timeout: timeout, environment: environment, currentDirectory: currentDirectory)
        }
    }

    /// ブロックする処理（子プロセスの待ち・セマフォ・Keychain 等）を協調スレッドの外で動かして結果を待つ。
    /// 処理そのものは呼び出し側で有限時間に収めること（ここでは打ち切らない）。
    static func offload<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            blockingQueue.async { cont.resume(returning: work()) }
        }
    }

    private static let blockingQueue = DispatchQueue(
        label: "buddyos.process-runner.blocking", qos: .utility, attributes: .concurrent)

    /// stdout を文字列で返す簡易版。起動失敗・タイムアウトは nil(終了コードは見ない)。
    static func runForString(
        _ executable: String,
        _ args: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) -> String? {
        guard let r = run(executable, args, timeout: timeout, environment: environment),
              !r.timedOut else { return nil }
        return String(data: r.stdout, encoding: .utf8)
    }

    // MARK: - private

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        let eof = DispatchSemaphore(value: 0)
        func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private static func drain(_ handle: FileHandle) -> Buffer {
        let buf = Buffer()
        handle.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty {
                h.readabilityHandler = nil
                buf.eof.signal()
            } else {
                buf.append(d)
            }
        }
        return buf
    }
}
