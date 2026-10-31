import Foundation

/// `<cwd>/.claude/skills/<name>/SKILL.md` をファイル単位で読み書きするサービス。
/// - skill = ディレクトリ。`SKILL.md` 必須。frontmatter (`---` で挟まれた YAML) から name/description を抜く。
/// - 書き込み時はディレクトリを作成して `SKILL.md` を上書きする。
/// - 削除はディレクトリごと再帰削除。
///
/// cwd が空文字列 / nil の場合は `~/.hermes/skills` を **read-only** で扱う (global)。
/// global は `~/.hermes/skills/<category>/<skill>/SKILL.md` の 2 階層なので、
/// 一覧では `category/skill` の形で平坦化して返す。
enum SkillsService {
    /// project: `<cwd>/<projectSkillsDirectory>`、global: agent ごとの home
    /// (~/.hermes/skills, ~/.codex/skills, ~/.openclaw/skills, ~/.cursor/skills …)。
    static func skillsRoot(cwd: String?, agentId: String? = nil) -> URL? {
        // opencode は cwd に依存せず常に ~/.config/opencode/skills (単一階層・read-only)。
        if agentId == "opencode" {
            return URL(fileURLWithPath: NSHomeDirectory() + "/.config/opencode/skills", isDirectory: true)
        }
        guard let cwd, !cwd.isEmpty else {
            let sub: String
            switch agentId {
            case "codex":    sub = "/.codex/skills"
            case "claude":   sub = "/.claude/skills"
            case "openclaw": sub = "/.openclaw/skills"
            case "cursor":   sub = "/.cursor/skills"
            case "grok":     sub = "/.grok/skills"
            case "antigravity": sub = "/.gemini/antigravity-cli/skills"
            default:         sub = "/.hermes/skills"
            }
            return URL(fileURLWithPath: NSHomeDirectory() + sub, isDirectory: true)
        }
        let expanded = (cwd as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: expanded, isDirectory: true)
        return base.appendingPathComponent(projectSkillsDirectory(agentId: agentId), isDirectory: true)
    }

    /// プロジェクトの skill の置き場（その CLI が読む場所）。
    static func projectSkillsDirectory(agentId: String?) -> String {
        switch agentId {
        case "cursor": return ".cursor/skills"
        case "grok": return ".grok/skills"
        // agy は .agents/skills を読む（.claude は読まない）。
        case "antigravity": return ".agents/skills"
        default: return ".claude/skills"
        }
    }

    /// global (read-only) スコープかどうか。
    static func isGlobal(cwd: String?) -> Bool {
        (cwd ?? "").isEmpty
    }

    /// `<root>/<name>` を返す。name の正規化 (空白除去 + 先頭末尾のスラッシュ除去 + path traversal 拒否)。
    /// 失敗時は nil。
    static func skillDirectory(root: URL, name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty,
              !trimmed.contains(".."),
              !trimmed.contains("/") else { return nil }
        return root.appendingPathComponent(trimmed, isDirectory: true)
    }

    /// 一覧。
    /// - project: `<cwd>/.claude/skills/<name>/SKILL.md` (1 階層)
    /// - global : `~/.hermes/skills/<category>/<name>/SKILL.md` または `~/.codex/skills/...` (2 階層、`category/name` で平坦化)
    static func list(cwd: String?, agentId: String? = nil) -> [SkillSummary] {
        guard let root = skillsRoot(cwd: cwd, agentId: agentId) else { return [] }
        // opencode は cwd 無しでも単一階層 (~/.config/opencode/skills/<name>/SKILL.md)。
        // 2 階層歩きの listGlobal を使わず project と同じ 1 階層 walker で読む。
        if isGlobal(cwd: cwd) && agentId != "opencode" {
            return listGlobal(root: root)
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [SkillSummary] = []
        for dir in names {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillFile = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else { continue }
            let content = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
            let desc = parseFrontmatterDescription(content) ?? ""
            result.append(SkillSummary(name: dir.lastPathComponent, description: desc))
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// `~/.hermes/skills/<cat>/<skill>/SKILL.md` を 2 階層歩いて平坦化。
    private static func listGlobal(root: URL) -> [SkillSummary] {
        let fm = FileManager.default
        guard let categories = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [SkillSummary] = []
        for cat in categories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: cat.path, isDirectory: &isDir), isDir.boolValue,
                  !cat.lastPathComponent.hasPrefix(".") else { continue }
            // skills/<cat>/SKILL.md (1 階層もあり得るので拾う)
            let directSkill = cat.appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: directSkill.path) {
                let content = (try? String(contentsOf: directSkill, encoding: .utf8)) ?? ""
                let desc = parseFrontmatterDescription(content) ?? ""
                result.append(SkillSummary(name: cat.lastPathComponent, description: desc))
            }
            // skills/<cat>/<skill>/SKILL.md
            guard let skills = try? fm.contentsOfDirectory(
                at: cat, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for s in skills {
                var sd: ObjCBool = false
                guard fm.fileExists(atPath: s.path, isDirectory: &sd), sd.boolValue else { continue }
                let skillFile = s.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: skillFile.path) else { continue }
                let content = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
                let desc = parseFrontmatterDescription(content) ?? ""
                result.append(SkillSummary(
                    name: "\(cat.lastPathComponent)/\(s.lastPathComponent)",
                    description: desc
                ))
            }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// `SKILL.md` の全文を返す。global では name に "/" を 1 個まで許可。
    static func load(cwd: String?, name: String, agentId: String? = nil) -> String? {
        guard let root = skillsRoot(cwd: cwd, agentId: agentId) else { return nil }
        let dir: URL
        // opencode は単一階層なので global の 2 階層 lookup を使わない。
        if isGlobal(cwd: cwd) && agentId != "opencode" {
            guard let d = globalSkillDirectory(root: root, name: name) else { return nil }
            dir = d
        } else {
            guard let d = skillDirectory(root: root, name: name) else { return nil }
            dir = d
        }
        let file = dir.appendingPathComponent("SKILL.md")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// global はディレクトリ階層が "category/name" のため、"/" を 1 個まで許可。
    static func globalSkillDirectory(root: URL, name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.contains("..") else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 1 && parts.count <= 2 else { return nil }
        var url = root
        for p in parts { url.appendPathComponent(p, isDirectory: true) }
        return url
    }

    /// project のみ書き込み可。global は read-only。
    /// agentId: 一覧と同じ置き場（その CLI が読む場所）に書くため。
    static func save(cwd: String?, name: String, content: String, agentId: String? = nil) -> (Bool, String?) {
        if isGlobal(cwd: cwd) { return (false, "global skills are read-only") }
        guard let root = skillsRoot(cwd: cwd, agentId: agentId) else { return (false, "cwd is empty") }
        guard let dir = skillDirectory(root: root, name: name) else { return (false, "invalid skill name") }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("SKILL.md")
            try content.write(to: file, atomically: true, encoding: .utf8)
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// project のみ削除可。global は read-only。
    static func delete(cwd: String?, name: String, agentId: String? = nil) -> (Bool, String?) {
        if isGlobal(cwd: cwd) { return (false, "global skills are read-only") }
        guard let root = skillsRoot(cwd: cwd, agentId: agentId) else { return (false, "cwd is empty") }
        guard let dir = skillDirectory(root: root, name: name) else { return (false, "invalid skill name") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return (true, nil) }
        do {
            try fm.removeItem(at: dir)
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// frontmatter (`---` ブロック) の `description:` を取り出す。値は単純な 1 行文字列のみ対応。
    /// 引用符 (`"..."` / `'...'`) は剥がす。
    static func parseFrontmatterDescription(_ content: String) -> String? {
        // 先頭が `---` で始まり、次の `---` までを frontmatter とみなす。
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty, lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        var fmBlock: [Substring] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            fmBlock.append(line)
        }
        for line in fmBlock {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("description:") else { continue }
            let raw = trimmed.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
            return stripQuotes(raw)
        }
        return nil
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first, last = s.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
