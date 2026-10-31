import Foundation

/// `~/.claude/skills/<name>/SKILL.md` と
/// `~/.claude/plugins/cache/<source>/<plugin>/<version>/skills/<name>/SKILL.md` を
/// 走査して Claude Code の slash command (= skill) 一覧を返す。
///
/// プラグイン由来の skill は `<plugin>:<name>` の id で返す
/// (terminal の `/<plugin>:<name>` 入力と一致させる目的)。
enum ClaudeSkillsScanner {
    /// User + plugin skills を結合して返す。重複名は user > plugin の優先順で 1 件のみ採用。
    /// プロジェクト固有 (`<cwd>/.claude/skills/`) は scope が project だがここでは扱わない。
    static func listSkillCommands() -> [CommandInfo] {
        var seen = Set<String>()
        var result: [CommandInfo] = []

        for skill in scanUserSkills() {
            if seen.insert(skill.id).inserted { result.append(skill) }
        }
        for skill in scanPluginSkills() {
            if seen.insert(skill.id).inserted { result.append(skill) }
        }

        result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return result
    }

    // MARK: - User skills (~/.claude/skills)

    private static var userSkillsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
    }

    private static func scanUserSkills() -> [CommandInfo] {
        scanSkillDirectory(at: userSkillsRoot, namespacePrefix: nil)
    }

    // MARK: - Plugin skills (~/.claude/plugins/cache/<source>/<plugin>/<version>/skills)

    private static var pluginCacheRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("plugins")
            .appendingPathComponent("cache")
    }

    private static func scanPluginSkills() -> [CommandInfo] {
        let fm = FileManager.default
        guard let sources = try? fm.contentsOfDirectory(
            at: pluginCacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let installPaths = loadInstalledPluginPaths()
        var result: [CommandInfo] = []
        for source in sources {
            guard isDirectory(source, fm: fm) else { continue }
            guard let plugins = try? fm.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for plugin in plugins {
                guard isDirectory(plugin, fm: fm) else { continue }
                let pluginName = plugin.lastPathComponent
                // cache/<source>/<plugin> は installed_plugins.json の "<plugin>@<source>" に対応する。
                // 載っていて実在すればその版だけを見る（skills/ が無ければ旧版にも戻らない）。
                let installPath = installPaths["\(pluginName)@\(source.lastPathComponent)"]
                let skillsDir: URL?
                if let installed = installedVersionDir(installPath: installPath, fm: fm) {
                    skillsDir = skillsDirIfExists(in: installed, fm: fm)
                } else {
                    skillsDir = latestVersionSkillsDir(under: plugin, fm: fm)
                }
                if let dir = skillsDir {
                    result.append(contentsOf: scanSkillDirectory(at: dir, namespacePrefix: pluginName))
                }
            }
        }
        return result
    }

    private static var installedPluginsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("plugins")
            .appendingPathComponent("installed_plugins.json")
    }

    /// `~/.claude/plugins/installed_plugins.json` から "<plugin>@<marketplace>" → installPath を読む。
    /// v2 は値がエントリ配列（scope=user / project が並ぶことがある）、v1 は単一オブジェクト。
    /// スキャナは cwd を知らないので scope=user を優先し、無ければ先頭のエントリを採る。
    private static func loadInstalledPluginPaths() -> [String: String] {
        guard let data = try? Data(contentsOf: installedPluginsFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for (key, value) in plugins {
            let entries: [[String: Any]]
            if let arr = value as? [[String: Any]] {
                entries = arr
            } else if let obj = value as? [String: Any] {
                entries = [obj]
            } else {
                continue
            }
            let entry = entries.first { ($0["scope"] as? String) == "user" } ?? entries.first
            if let path = entry?["installPath"] as? String, !path.isEmpty {
                map[key] = path
            }
        }
        return map
    }

    /// installed_plugins.json が指す版のディレクトリを返す。
    /// installPath が無い・実在しない場合は nil（呼び出し側でキャッシュ走査にフォールバック）。
    private static func installedVersionDir(installPath: String?, fm: FileManager) -> URL? {
        guard let installPath else { return nil }
        let dir = URL(fileURLWithPath: installPath, isDirectory: true)
        return isDirectory(dir, fm: fm) ? dir : nil
    }

    private static func skillsDirIfExists(in versionDir: URL, fm: FileManager) -> URL? {
        let skills = versionDir.appendingPathComponent("skills", isDirectory: true)
        return fm.fileExists(atPath: skills.path) ? skills : nil
    }

    /// installed_plugins.json に載っていない時のフォールバック。
    /// `<plugin>/<version>/skills` のうち最新と推定される version を返す。
    /// - シンボリックリンクの版は実体に解決して重複を除く（リンク自身の日時は実体と異なる）。
    /// - `.orphaned_at` の付いた旧版は、他に候補がある限り除外する。
    /// - 名前が全て semver 風（"1.10.0"）なら数値比較、git SHA 等を含むなら作成日時（無ければ更新日時）で比較。
    private static func latestVersionSkillsDir(under plugin: URL, fm: FileManager) -> URL? {
        guard let versions = try? fm.contentsOfDirectory(
            at: plugin,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var seenPaths = Set<String>()
        var versionDirs: [URL] = []
        for version in versions where isDirectory(version, fm: fm) {
            let resolved = version.resolvingSymlinksInPath()
            if seenPaths.insert(resolved.path).inserted { versionDirs.append(resolved) }
        }
        let live = versionDirs.filter {
            !fm.fileExists(atPath: $0.appendingPathComponent(".orphaned_at").path)
        }
        if !live.isEmpty { versionDirs = live }
        guard !versionDirs.isEmpty else { return nil }

        func isVersionLike(_ name: String) -> Bool {
            name.first?.isNumber == true && name.contains(".")
        }
        func timestamp(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
        }
        let allVersionLike = versionDirs.allSatisfy { isVersionLike($0.lastPathComponent) }
        let latest = versionDirs.max { a, b in
            if allVersionLike {
                return a.lastPathComponent.compare(b.lastPathComponent, options: .numeric) == .orderedAscending
            }
            return timestamp(a) < timestamp(b)
        }!
        return skillsDirIfExists(in: latest, fm: fm)
    }

    // MARK: - Common scanning logic

    private static func scanSkillDirectory(at root: URL, namespacePrefix: String?) -> [CommandInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [CommandInfo] = []
        for entry in entries {
            guard isDirectory(entry, fm: fm) else { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else { continue }
            let name = entry.lastPathComponent
            let qualified: String
            if let prefix = namespacePrefix {
                qualified = "\(prefix):\(name)"
            } else {
                qualified = name
            }
            let description = parseDescription(at: skillFile)
            result.append(CommandInfo(
                id: qualified,
                kind: "skill",
                title: qualified,
                subtitle: description
            ))
        }
        return result
    }

    private static func isDirectory(_ url: URL, fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func parseDescription(at url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return SkillsService.parseFrontmatterDescription(content)
    }
}
