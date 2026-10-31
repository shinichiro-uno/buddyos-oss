import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Bridge が setpgid で独立グループ化した子プロセス (acp / claude / codex) の pid を
/// `~/.buddyos/spawned_pgids.json` に記録し、BridgeApp の次回起動時に前回の残骸
/// (孤児プロセス) をグループ SIGTERM で回収する。
///
/// 背景: setpgid(pid, pid) は close 時のグループ kill に必須だが、副作用として
/// BridgeApp が SIGKILL (launchctl kickstart -k 等) で死ぬと子が親グループから
/// 切り離されているため道連れにならず、PPID=1 の孤児として残り続ける。SIGKILL では
/// 終了フックが走らないので、「spawn 時に記録 → 次回起動時に掃除」が唯一確実な経路。
enum SpawnRegistry {
    private static var path: String { BuddyPaths.root.appendingPathComponent("spawned_pgids.json").path }
    private static let lock = NSLock()

    private struct Record: Codable {
        let command: String
        let spawnedAt: Date
    }

    static func register(pid: Int32, command: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = load()
        // 死んだ pid の記録は都度間引く (一回完了型の claude/codex を毎プロンプト
        // 記録するため、放置するとファイルが無制限に伸びる)
        records = records.filter { key, _ in
            Int32(key).map { kill($0, 0) == 0 || errno == EPERM } ?? false
        }
        records["\(pid)"] = Record(command: String(command.prefix(300)), spawnedAt: Date())
        save(records)
    }

    static func unregister(pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        var records = load()
        guard records.removeValue(forKey: "\(pid)") != nil else { return }
        save(records)
    }

    /// BridgeApp 起動時に呼ぶ。前回起動の記録のうち、まだ生きていて自分のグループの
    /// リーダーであり、かつコマンドラインが当時の記録と同種 (acp/openclaw/hermes/
    /// claude/codex/opencode を含む) のものだけをグループ SIGTERM で回収する。
    /// pid 再利用で無関係なプロセスを誤殺しないよう、3 条件すべての一致を要求する。
    static func sweepStaleProcesses() {
        lock.lock()
        let records = load()
        save([:])   // 掃除結果に関わらず前回分の記録はクリア (生き残りは下で kill 済み)
        lock.unlock()
        guard !records.isEmpty else { return }

        // opencode: OpenCodeServeClient が常駐させる `<exe>/opencode serve ...`（acp を含まない）。
        let markers = ["acp", "openclaw", "hermes", "claude", "codex", "opencode"]
        var swept = 0
        for (key, record) in records {
            guard let pid = Int32(key), pid > 1 else { continue }
            guard kill(pid, 0) == 0 else { continue }               // 既に死んでいる
            guard getpgid(pid) == pid else { continue }             // 我々が作ったグループリーダーか
            let liveCommand = currentCommand(pid: pid)
            let recordedMarkers = markers.filter { record.command.localizedCaseInsensitiveContains($0) }
            guard !recordedMarkers.isEmpty,
                  recordedMarkers.contains(where: { liveCommand.localizedCaseInsensitiveContains($0) }) else {
                continue                                            // pid 再利用 (別物) と判断
            }
            kill(-pid, SIGTERM)
            swept += 1
            FileHandle.standardError.write(Data(
                "[spawn-registry] swept orphan pgid=\(pid) cmd=\(liveCommand.prefix(120))\n".utf8))
        }
        if swept > 0 {
            FileHandle.standardError.write(Data("[spawn-registry] swept \(swept) orphan group(s) from previous run\n".utf8))
        }
    }

    /// 終了シグナル受信時のベストエフォート掃除 (SIGTERM 経由の停止用。SIGKILL では走らない)。
    static func killAllRegistered() {
        lock.lock()
        let records = load()
        save([:])
        lock.unlock()
        for key in records.keys {
            guard let pid = Int32(key), pid > 1, getpgid(pid) == pid else { continue }
            kill(-pid, SIGTERM)
        }
    }

    // MARK: - private

    private static func currentCommand(pid: Int32) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "command=", "-p", "\(pid)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func load() -> [String: Record] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    private static func save(_ records: [String: Record]) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
