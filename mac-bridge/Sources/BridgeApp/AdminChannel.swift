import Darwin
import Foundation

/// 管理鍵の受け取り（spec/PROTOCOL-v3.md Appendix A）。
///
/// デスクトップの supervisor は Bridge を `stdio[0] = "pipe"` で起こし、起こした直後に 1 行
/// `{"adminKey":"bda_…"}\n` を書く。stdin は Bridge が終わるまで閉じない（閉じたら「デスクトップがいなくなった」）。
/// 管理鍵は環境変数・引数・ファイル・ログでは渡さない（Bridge の環境変数は子のエージェントにそのまま引き継がれるため）。
///
/// 子に渡さないため、読み始める前にパイプを CLOEXEC 付きの別の番号へ移し、fd 0 を /dev/null にする。
/// これで Bridge が起こす子プロセス（Process・posix_spawn・forkpty）は、標準入力を指定していなくても
/// /dev/null を受け継ぐ（起こしている箇所を 1 つずつ直すより確実）。
enum AdminChannel {
    static let maxLineBytes = 256
    static let readTimeout: TimeInterval = 5

    /// 起動時に 1 回だけ呼ぶ。stdin が TTY なら読まない（手で起こした・SUPERDOS_ATTACH）。
    /// LaunchAgent（stdin が /dev/null）はすぐ EOF になり、管理鍵なしで動く（/local/* は 403 admin_unavailable）。
    @discardableResult
    static func start(fd: Int32 = STDIN_FILENO, adminKey: AdminKey = .shared,
                      onEOF: @escaping @Sendable () -> Void) -> Bool {
        guard isatty(fd) == 0 else {
            WebSocketServer.wslog("admin key: stdin is a TTY — running without one")
            return false
        }
        // パイプを CLOEXEC の別の番号へ移し、fd 0 を /dev/null にする（子プロセスに渡さない）。
        let pipeFD = fcntl(fd, F_DUPFD_CLOEXEC, 3)
        if fd == STDIN_FILENO {
            let devNull = open("/dev/null", O_RDONLY)
            // fd 0 が閉じていた場合は open がそのまま 0 を返す。そのときは閉じない（閉じると fd 0 が空き、
            // 次に開いたファイルが子プロセスの標準入力になってしまう）。
            if devNull > STDIN_FILENO {
                _ = dup2(devNull, STDIN_FILENO)
                close(devNull)
            }
        }
        guard pipeFD >= 0 else { return false }
        let key = readAdminKey(fd: pipeFD, timeout: readTimeout)
        let accepted = key.map { adminKey.set($0) } ?? false
        WebSocketServer.wslog(accepted ? "admin key: received" : "admin key: none — /local/* will answer admin_unavailable")
        watchEOF(fd: pipeFD, onEOF: onEOF)
        return accepted
    }

    /// 1 行（`maxLineBytes` まで）を `timeout` 秒だけ待って読み、`{"adminKey":"bda_…"}` の値を返す。形が違えば nil。
    static func readAdminKey(fd: Int32, timeout: TimeInterval) -> String? {
        guard let line = readLine(fd: fd, timeout: timeout) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let key = obj["adminKey"] as? String, AdminKey.isWellFormed(key) else { return nil }
        return key
    }

    static func readLine(fd: Int32, timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8]()
        var byte: UInt8 = 0
        while buf.count <= maxLineBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, Int32(max(1, remaining * 1000)))
            if r < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if r == 0 { return nil }
            let n = read(fd, &byte, 1)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return nil }   // EOF（行の前）
            if byte == 0x0A { return String(decoding: buf, as: UTF8.self) }
            buf.append(byte)
        }
        return nil
    }

    /// その後も stdin を読み続け、EOF（デスクトップがいなくなった）で `onEOF` を呼ぶ。
    static func watchEOF(fd: Int32, onEOF: @escaping @Sendable () -> Void) {
        let thread = Thread {
            var chunk = [UInt8](repeating: 0, count: 256)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
            }
            close(fd)
            WebSocketServer.wslog("admin key: stdin closed — closing the Add a device window")
            onEOF()
        }
        thread.name = "buddyos.admin-stdin"
        thread.start()
    }
}
