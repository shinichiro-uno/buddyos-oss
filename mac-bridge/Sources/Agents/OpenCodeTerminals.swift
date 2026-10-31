import Foundation

/// ターミナルの OpenCode（`buddy-opencode`）と Bridge の serve を共有するための台帳。
///
/// - Bridge は serve を起動したら `~/.buddyos/opencode-serve.json`（url と pid と password。0600）を書く。
///   `buddy-opencode` はこれを読んで `opencode attach <url>` で同じ serve に繋ぐ（パスワードは
///   OPENCODE_SERVER_PASSWORD で渡す。serve は起動ごとのパスワードで Basic 認証を掛けている）。同じ serve なので、どちらから送っても
///   SSE で両方にリアルタイムで流れる（iPhone で開いたセッションは OpenCodeServeSession が受ける）。
/// - `buddy-opencode` は起動中、`~/.buddyos/opencode-terminals/<pid>.json`（cwd）を置く。
///   そのディレクトリの「いちばん最近更新されたセッション」を、一覧で「ターミナル」として印を付ける。
///   TUI がどのセッションを開いているかは serve から分からないための近似。
enum OpenCodeTerminals {
    private static var home: String { NSHomeDirectory() + "/.buddyos" }
    static var serverFile: String { home + "/opencode-serve.json" }
    static var terminalsDir: String { home + "/opencode-terminals" }

    static func publishServer(url: URL, pid: Int32, password: String?) {
        var obj: [String: Any] = ["url": url.absoluteString, "pid": Int(pid)]
        if let password { obj["password"] = password }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // パスワードを含むので最初から 0600 で書く（createFile は作成後に権限を付ける窓が残る）。
        do {
            try KeyStore.writeSecret(data, to: URL(fileURLWithPath: serverFile))
        } catch {
            FileHandle.standardError.write(Data("[opencode.serve] publish failed: \(error)\n".utf8))
        }
    }

    static func unpublishServer() {
        try? FileManager.default.removeItem(atPath: serverFile)
    }

    /// 生きている `buddy-opencode` の cwd。pid が死んでいる台帳は掃除する。
    static func liveDirectories() -> Set<String> {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: terminalsDir) else { return [] }
        var dirs = Set<String>()
        for name in names where name.hasSuffix(".json") {
            let path = terminalsDir + "/" + name
            guard let pid = Int32(name.dropLast(5)) else { try? fm.removeItem(atPath: path); continue }
            if kill(pid, 0) != 0 && errno != EPERM { try? fm.removeItem(atPath: path); continue }
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            dirs.insert((cwd as NSString).standardizingPath)
        }
        return dirs
    }

    /// 一覧（opencode の session オブジェクト）から、各ライブ cwd で最も新しく更新されたセッションの id。
    static func terminalSessionIds(in list: [[String: Any]]) -> Set<String> {
        terminalSessionIds(in: list, liveDirs: liveDirectories())
    }

    static func terminalSessionIds(in list: [[String: Any]], liveDirs: Set<String>) -> Set<String> {
        guard !liveDirs.isEmpty else { return [] }
        var newest: [String: (id: String, updated: Double)] = [:]
        for dict in list {
            guard let id = dict["id"] as? String,
                  (dict["parentID"] as? String)?.isEmpty != false,   // サブエージェントのセッションは除く
                  let dir = (dict["directory"] as? String).map({ ($0 as NSString).standardizingPath }),
                  liveDirs.contains(dir) else { continue }
            let updated = ((dict["time"] as? [String: Any])?["updated"] as? NSNumber)?.doubleValue ?? 0
            if updated >= (newest[dir]?.updated ?? -1) { newest[dir] = (id, updated) }
        }
        return Set(newest.values.map(\.id))
    }
}
