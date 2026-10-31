import Foundation

/// iPhone アプリとデスクトップで共有するプロジェクト（作業フォルダ）の登録。
/// `~/.buddyos/projects.json` に置き、どちらから足しても消しても同じ一覧になる。
/// 並び順は配列の順（iPhone の並べ替えで決まる）。エージェントには依らない。
struct SharedProject: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let addedAt: Double
}

enum ProjectRegistry {
    private static let lock = NSLock()

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".buddyos")
            .appendingPathComponent("projects.json")
    }

    /// Bridge が返す cwd と文字列で突き合わせるため、末尾の / を落として標準化する。
    static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Windows のパス（C:\ や UNC）は触らない。
        if trimmed.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil || trimmed.hasPrefix("\\\\") {
            return trimmed
        }
        let standardized = (trimmed as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    static func displayName(for path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? path : last
    }

    static func list(at url: URL = fileURL) -> [SharedProject] {
        lock.lock()
        defer { lock.unlock() }
        return read(url)
    }

    /// 追加（既にあれば名前だけ更新し、位置は変えない）。新しいものは先頭に足す。
    @discardableResult
    static func add(path: String, name: String?, at url: URL = fileURL) -> [SharedProject] {
        let p = normalize(path)
        guard !p.isEmpty else { return list(at: url) }
        let n = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? displayName(for: p)
        return mutate(url) { items in
            if let i = items.firstIndex(where: { $0.path == p }) {
                items[i] = SharedProject(path: p, name: n, addedAt: items[i].addedAt)
            } else {
                items.insert(SharedProject(path: p, name: n, addedAt: Date().timeIntervalSince1970), at: 0)
            }
        }
    }

    @discardableResult
    static func remove(path: String, at url: URL = fileURL) -> [SharedProject] {
        let p = normalize(path)
        return mutate(url) { items in items.removeAll { $0.path == p } }
    }

    /// 並べ替え。渡された順に並べ、渡されなかったものは後ろに元の順で残す。
    @discardableResult
    static func reorder(paths: [String], at url: URL = fileURL) -> [SharedProject] {
        let order = paths.map(normalize)
        return mutate(url) { items in
            let byPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            var next: [SharedProject] = []
            for p in order { if let item = byPath[p], !next.contains(item) { next.append(item) } }
            for item in items where !next.contains(item) { next.append(item) }
            items = next
        }
    }

    // MARK: - ファイル

    private static func mutate(_ url: URL, _ body: (inout [SharedProject]) -> Void) -> [SharedProject] {
        lock.lock()
        defer { lock.unlock() }
        var items = read(url)
        body(&items)
        write(items, to: url)
        return items
    }

    private static func read(_ url: URL) -> [SharedProject] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([SharedProject].self, from: data)
        else { return [] }
        return items
    }

    private static func write(_ items: [SharedProject], to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
