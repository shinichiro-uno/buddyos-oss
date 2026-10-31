import Foundation
import SQLite3

/// agy が自動で付ける会話名。`~/.gemini/antigravity-cli/conversation_summaries.db` の
/// `conversation_summaries`（title は自動要約、まだ無いときは空で preview に最初の発言が入る）を読む。
enum AntigravitySummaries {
    struct Entry: Equatable {
        let title: String
        let preview: String
        let cwd: String?
    }

    static var path: String { NSHomeDirectory() + "/.gemini/antigravity-cli/conversation_summaries.db" }

    static func read(path: String = AntigravitySummaries.path) -> [String: Entry] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        var db: OpaquePointer?
        // 読み取り専用。agy が WAL で書いている最中でも読める。
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [:] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        var stmt: OpaquePointer?
        let sql = "SELECT conversation_id, title, preview, workspace_uris FROM conversation_summaries"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        func text(_ i: Int32) -> String {
            sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
        }
        var out: [String: Entry] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(0)
            guard !id.isEmpty else { continue }
            out[id] = Entry(title: text(1).trimmingCharacters(in: .whitespacesAndNewlines),
                            preview: text(2).trimmingCharacters(in: .whitespacesAndNewlines),
                            cwd: firstWorkspace(text(3)))
        }
        return out
    }

    /// `["file:///a/b"]` の最初の要素をパスにする。
    static func firstWorkspace(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
              let first = arr.first, let url = URL(string: first), url.isFileURL else { return nil }
        let p = url.path
        return p.isEmpty || p == "/" ? nil : p
    }
}
