import Foundation

/// CLI エージェントの実体を絶対パスで探す共通処理。
/// 固定の置き場所 → nvm / volta / fnm / bun / pnpm / asdf の置き場所 → ログインシェルの `command -v` の順。
/// デスクトップアプリの「検出」（ログインシェル）と起動の食い違いで「検出されたのに起動できない」を防ぐ。
enum ExecutableFinder {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func locate(_ name: String) -> String? {
        lock.lock()
        if let hit = cache[name], FileManager.default.isExecutableFile(atPath: hit) { lock.unlock(); return hit }
        lock.unlock()
        guard let found = search(name) else { return nil }
        lock.lock(); cache[name] = found; lock.unlock()
        return found
    }

    static func candidateDirs(home: String = NSHomeDirectory()) -> [String] {
        var dirs = [
            "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/Library/pnpm", "\(home)/.local/share/pnpm",
            "\(home)/.asdf/shims", "\(home)/.fnm/aliases/default/bin",
        ]
        // nvm: 入っている Node のバージョンごとの bin（新しい順）。
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        return dirs
    }

    private static func search(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in candidateDirs() {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        // 最後にログインシェル（.zprofile / .zshrc の PATH を反映）。
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = ProcessRunner.run(shell, ["-lic", "command -v \(name)"], timeout: 4) , !out.timedOut else { return nil }
        for raw in String(decoding: out.stdout, as: UTF8.self).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("/"), fm.isExecutableFile(atPath: line) { return line }
        }
        return nil
    }
}
