import Foundation
import Darwin

/// ターミナルで開かれている Grok の会話を見つける。
/// grok は開いている会話を `~/.grok/active_sessions.json`（[{session_id, pid, cwd, opened_at}]）に書く。
/// pid が生きていて、Bridge が起動した ACP（`grok agent …`）でないものをターミナルとみなす。
enum GrokPresence {
    static var path: String { NSHomeDirectory() + "/.grok/active_sessions.json" }

    static func liveSessionIds(path: String = GrokPresence.path,
                               commandOf: (Int32) -> String? = GrokPresence.command(of:)) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: path),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var live = Set<String>()
        for entry in list {
            guard let sid = entry["session_id"] as? String, !sid.isEmpty,
                  let pid = (entry["pid"] as? NSNumber)?.int32Value, pid > 0,
                  kill(pid, 0) == 0 || errno == EPERM else { continue }
            // Bridge が開いている会話（grok agent stdio）はターミナルではない。
            if let cmd = commandOf(pid), cmd.contains(" agent ") || cmd.hasSuffix(" agent") { continue }
            live.insert(sid)
        }
        return live
    }

    static func command(of pid: Int32) -> String? {
        let out = ProcessRunner.run("/bin/ps", ["-o", "command=", "-p", String(pid)], timeout: 2)
        guard let out, out.status == 0 else { return nil }
        let text = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// grok の leader（同じ会話を複数の画面で共有する常駐プロセス）。`grok agent --leader` で乗る。
/// 古い grok には無いので、`grok agent --help` に --leader があるかを一度だけ確かめる。
enum GrokLeader {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    static func isSupported(executable: String) -> Bool {
        if let hit = lock.withLock({ cache[executable] }) { return hit }
        let out = ProcessRunner.run(executable, ["agent", "--help"], timeout: 10)
        let ok = out.map { String(decoding: $0.stdout, as: UTF8.self).contains("--leader") } ?? false
        lock.withLock { cache[executable] = ok }
        return ok
    }
}
