import Foundation

/// コネクタ（MCP）とスキルを、エージェント間でそろえる（デスクトップの 設定 / 初回設定 から使う）。
///  - list: どのエージェントに何が登録されているかの表
///  - sync: 足りないものを他のエージェントへ写す（同じ名前があるところは上書きしない）
/// コネクタの秘密の値（ヘッダー・環境変数）は Mac の中だけで写し、表には出さない。
enum ExtensionsShare {
    struct Agent: Codable, Sendable {
        let id: String
        let name: String
    }

    struct Item: Codable, Sendable {
        let kind: String        // "mcp" | "skill"
        let name: String
        let detail: String      // コネクタは URL / コマンド、スキルは説明
        let agents: [String]    // 登録済みのエージェント
    }

    struct Listing: Codable, Sendable {
        let agents: [Agent]
        let items: [Item]
    }

    struct SyncResult: Codable, Sendable {
        var copied: [String] = []    // "mcp:name → codex" など
        var skipped: [String] = []
        var failed: [String] = []
    }

    /// 対象にするエージェント（コネクタとスキルの置き場所が分かっているもの）。設定フォルダがあるものだけ。
    static let known: [(id: String, name: String, dir: String)] = [
        ("claude", "Claude Code", "/.claude"),
        ("codex", "Codex", "/.codex"),
        ("opencode", "OpenCode", "/.config/opencode"),
        ("hermes", "Hermes", "/.hermes")
    ]

    static func installedAgents(home: String = NSHomeDirectory()) -> [Agent] {
        known.filter { FileManager.default.fileExists(atPath: home + $0.dir) }.map { Agent(id: $0.id, name: $0.name) }
    }

    // MARK: スキル

    /// スキルの置き場所（エージェント共通のユーザー単位）。
    static func skillsRoot(agentId: String, home: String = NSHomeDirectory()) -> URL? {
        switch agentId {
        case "claude": return URL(fileURLWithPath: home + "/.claude/skills", isDirectory: true)
        case "codex": return URL(fileURLWithPath: home + "/.codex/skills", isDirectory: true)
        case "opencode": return URL(fileURLWithPath: home + "/.config/opencode/skills", isDirectory: true)
        case "hermes": return URL(fileURLWithPath: home + "/.hermes/skills", isDirectory: true)
        default: return nil
        }
    }

    struct SkillDir: Sendable {
        let name: String
        let dir: URL
        let description: String
    }

    /// `<root>/<name>/SKILL.md` と `<root>/<分類>/<name>/SKILL.md` の両方を拾う。
    /// 名前はフォルダ名（分類は除く）。Codex の組み込み（`.system`）など隠しフォルダは除く。
    static func skills(agentId: String, home: String = NSHomeDirectory()) -> [SkillDir] {
        guard let root = skillsRoot(agentId: agentId, home: home) else { return [] }
        let fm = FileManager.default
        var out: [String: SkillDir] = [:]
        func subdirs(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        func add(_ dir: URL) {
            let file = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: file.path) else { return }
            let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let name = dir.lastPathComponent
            if out[name] == nil {
                out[name] = SkillDir(name: name, dir: dir, description: SkillsService.parseFrontmatterDescription(content) ?? "")
            }
        }
        for d in subdirs(root) {
            if fm.fileExists(atPath: d.appendingPathComponent("SKILL.md").path) { add(d) } else { subdirs(d).forEach(add) }
        }
        return out.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// スキルを写す先。Hermes は分類フォルダが要るので `shared/` の下に置く。
    static func skillTarget(agentId: String, name: String, home: String = NSHomeDirectory()) -> URL? {
        guard let root = skillsRoot(agentId: agentId, home: home),
              !name.isEmpty, !name.contains("/"), !name.contains("..") else { return nil }
        return agentId == "hermes"
            ? root.appendingPathComponent("shared", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            : root.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: 一覧と同期

    static func list(home: String = NSHomeDirectory()) -> Listing {
        let agents = installedAgents(home: home)
        var mcp: [String: (detail: String, agents: [String])] = [:]
        var skill: [String: (detail: String, agents: [String])] = [:]
        for a in agents {
            for s in McpService.fullSpecs(agentId: a.id) {
                mcp[s.name, default: (s.summary, [])].agents.append(a.id)
            }
            for s in skills(agentId: a.id, home: home) {
                skill[s.name, default: (s.description, [])].agents.append(a.id)
            }
        }
        let items = mcp.map { Item(kind: "mcp", name: $0.key, detail: redact($0.value.detail), agents: $0.value.agents) }
            + skill.map { Item(kind: "skill", name: $0.key, detail: $0.value.detail, agents: $0.value.agents) }
        return Listing(
            agents: agents,
            items: items.sorted { ($0.kind, $0.name.lowercased()) < ($1.kind, $1.name.lowercased()) }
        )
    }

    /// URL のクエリ（トークンが入ることがある）は表に出さない。
    static func redact(_ s: String) -> String {
        guard let q = s.firstIndex(of: "?"), s.hasPrefix("http") else { return s }
        return String(s[..<q]) + "?…"
    }

    /// items（"mcp:NAME" / "skill:NAME"）を targets のエージェントへ写す。持っていないところにだけ足す。
    static func sync(items: [String], targets: [String], home: String = NSHomeDirectory()) -> SyncResult {
        var result = SyncResult()
        let agents = installedAgents(home: home).map(\.id)
        let targets = targets.filter { agents.contains($0) }
        for item in items {
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (kind, name) = (parts[0], parts[1])
            if kind == "mcp" {
                // 写す元: 最初に見つかったエージェントの設定
                guard let spec = agents.lazy.compactMap({ a in McpService.fullSpecs(agentId: a).first { $0.name == name } }).first else {
                    result.failed.append("\(item)（元が見つかりません）")
                    continue
                }
                for t in targets {
                    if McpService.fullSpecs(agentId: t).contains(where: { $0.name == name }) || McpService.list(agentId: t).contains(where: { $0.name == name }) {
                        result.skipped.append("\(item) → \(t)")
                        continue
                    }
                    let r = McpService.register(agentId: t, spec: spec.registerSpec)
                    if r.ok { result.copied.append("\(item) → \(t)") } else { result.failed.append("\(item) → \(t): \(r.message ?? "失敗")") }
                }
            } else if kind == "skill" {
                guard let src = agents.lazy.compactMap({ a in skills(agentId: a, home: home).first { $0.name == name } }).first else {
                    result.failed.append("\(item)（元が見つかりません）")
                    continue
                }
                for t in targets {
                    if skills(agentId: t, home: home).contains(where: { $0.name == name }) {
                        result.skipped.append("\(item) → \(t)")
                        continue
                    }
                    guard let dest = skillTarget(agentId: t, name: name, home: home) else {
                        result.failed.append("\(item) → \(t)")
                        continue
                    }
                    do {
                        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: src.dir, to: dest)
                        result.copied.append("\(item) → \(t)")
                    } catch {
                        result.failed.append("\(item) → \(t): \(error.localizedDescription)")
                    }
                }
            }
        }
        return result
    }

    static func json<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
