import Foundation
import Darwin

/// ターミナルで開かれている Antigravity（agy）の会話を見つける。
/// agy は TUI を開いている間だけ `~/.gemini/antigravity-cli/presence/<会話ID>.lock` を flock する
/// （実機で確認: 起動中は排他ロックが取れず、終了すると取れる）。ロックを一瞬取れるか試して判定する。
enum AntigravityPresence {
    static var directory: String { NSHomeDirectory() + "/.gemini/antigravity-cli/presence" }

    static func liveConversationIds(directory: String = AntigravityPresence.directory) -> Set<String> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var live = Set<String>()
        for name in names where name.hasSuffix(".lock") {
            if isHeld(path: directory + "/" + name) { live.insert(String(name.dropLast(5))) }
        }
        return live
    }

    /// 他のプロセスが排他ロックを持っているか。読み取りで開くだけでファイルは変更しない。
    static func isHeld(path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
