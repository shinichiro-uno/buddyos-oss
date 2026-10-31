import Foundation

/// Codex の fileChange（`changes: [{path, kind, diff}]`）を、クライアント向けの差分 JSON にする。
/// 大きな差分で WebSocket のフレームを膨らませないよう、合計 40,000 文字で打ち切る。
enum CodexFileChangeDiff {
    static let maxTotal = 40_000

    static func changes(_ item: [String: Any]) -> [[String: Any]] {
        (item["changes"] as? [[String: Any]]) ?? []
    }

    /// "ファイル変更: a.swift, b.swift"（3 件を超えたら件数）。
    static func title(_ item: [String: Any]) -> String? {
        let paths = changes(item).compactMap { $0["path"] as? String }.map { ($0 as NSString).lastPathComponent }
        guard !paths.isEmpty else { return nil }
        let shown = paths.count > 3 ? paths.prefix(3).joined(separator: ", ") + " ほか \(paths.count - 3) 件" : paths.joined(separator: ", ")
        return "ファイル変更: \(shown)"
    }

    static func json(_ item: [String: Any]) -> String? {
        var budget = maxTotal
        var out: [[String: Any]] = []
        for c in changes(item) {
            guard let path = c["path"] as? String else { continue }
            var diff = (c["diff"] as? String) ?? ""
            var truncated = false
            if diff.count > budget {
                diff = String(diff.prefix(max(0, budget)))
                truncated = true
            }
            budget -= diff.count
            let kind = (c["kind"] as? [String: Any])?["type"] as? String ?? (c["kind"] as? String) ?? "update"
            out.append(["path": path, "kind": kind, "diff": diff, "truncated": truncated])
            if budget <= 0 { break }
        }
        guard !out.isEmpty, let data = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
