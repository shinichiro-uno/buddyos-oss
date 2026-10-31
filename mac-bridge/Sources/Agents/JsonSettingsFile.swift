import Foundation

/// 各 CLI 自身の設定 JSON（`~/.claude/settings.json` / `~/.gemini/antigravity-cli/settings.json` /
/// `~/.config/opencode/opencode.json`）を BuddyOS の既定として読み書きする。
/// 書き込みは触るキー以外（hooks・permissions・env・mcp 等）をそのまま残す。
enum JsonSettingsFile {
    struct WriteError: LocalizedError, CustomStringConvertible {
        let message: String
        var errorDescription: String? { message }
        var description: String { message }
    }

    /// `~` からの相対パス。dotfiles 管理で symlink になっていても実体を読み書きする
    /// （.atomic の rename でリンクを実ファイルに置き換えない）。
    static func url(_ relativePath: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
    }

    static func read(_ relativePath: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url(relativePath)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 読んで `mutate` を当てて書き戻す。存在するのに読めない / JSON として壊れている時は書かない
    /// （空辞書から書き直すと設定全体が失われる）。0 バイト・空白だけ・無いファイルは空辞書から書く。
    static func update(_ relativePath: String, _ mutate: (inout [String: Any]) -> Void) throws {
        let url = url(relativePath)
        var obj: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try? Data(contentsOf: url)
            let isBlank = data.map {
                String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ?? false
            if !isBlank {
                guard let data,
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw WriteError(
                        message: "~/\(relativePath) を読めないか JSON として不正なため、既定を保存しませんでした。ファイルを直してから再度お試しください"
                    )
                }
                obj = parsed
            }
        }
        mutate(&obj)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try out.write(to: url, options: .atomic)
    }
}
