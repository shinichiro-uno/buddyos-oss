import Foundation

/// `~/.buddyos/session-overrides.json` を読み書きする小さなストア。
/// agentId / sessionId のペアごとにユーザがリネームしたタイトルを保持する。
/// hermes の state.db には書き込まず、Bridge 応答時に merge する形で適用する。
actor SessionOverrideStore {
    static let shared = SessionOverrideStore()

    private struct Entry: Codable {
        var title: String?
    }

    /// key = "<agentId>:<sessionId>"
    private var entries: [String: Entry] = [:]
    private var loaded = false

    private var fileURL: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".buddyos")
        return dir.appendingPathComponent("session-overrides.json")
    }

    func customTitle(agentId: String, sessionId: String) -> String? {
        ensureLoaded()
        return entries["\(agentId):\(sessionId)"]?.title
    }

    /// title が空文字 / nil なら override を削除する。
    func setTitle(agentId: String, sessionId: String, title: String?) {
        ensureLoaded()
        let key = "\(agentId):\(sessionId)"
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = trimmed, !t.isEmpty {
            var e = entries[key] ?? Entry()
            e.title = t
            entries[key] = e
        } else {
            entries.removeValue(forKey: key)
        }
        save()
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        // ~/.buddyos は秘密ファイルを置く場所。KeyStore より先に呼ばれても 0755 で作らない。
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
