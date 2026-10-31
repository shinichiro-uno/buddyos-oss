import Foundation

/// `~/.openclaw/openclaw.json` のスキーマ表現 (read 用)。
///
/// 書き込みは `openclaw config set <key> <value>` CLI 経由で行う。直接 JSON を
/// rewrite すると Codable に書いていない他のキー (gateway.auth, browser, etc.)
/// が消えるため。
struct OpenclawConfig: Codable {
    var agents: Agents?
    var plugins: Plugins?
    var skills: SkillsConfig?
    var models: Models?
    var gateway: Gateway?

    struct Agents: Codable {
        var defaults: AgentDefaults?
        var list: [AgentEntry]?
    }

    struct AgentDefaults: Codable {
        var workspace: String?
        var model: ModelConfig?
        var models: [String: ModelAlias]?
    }

    struct ModelConfig: Codable {
        var primary: String?
        var fallbacks: [String]?
    }

    struct ModelAlias: Codable {
        var alias: String?
    }

    struct AgentEntry: Codable {
        var id: String
        var name: String?
        var workspace: String?
        var agentDir: String?
    }

    struct Plugins: Codable {
        var entries: [String: PluginInfo]?
        var allow: [String]?
    }

    struct PluginInfo: Codable {
        var enabled: Bool?
    }

    struct SkillsConfig: Codable {
        var entries: [String: SkillEntry]?
    }

    struct SkillEntry: Codable {
        var enabled: Bool?
    }

    struct Models: Codable {
        var providers: [String: ProviderInfo]?
    }

    struct ProviderInfo: Codable {
        var baseUrl: String?
        var api: String?
        var models: [ProviderModelEntry]?
    }

    struct ProviderModelEntry: Codable {
        var id: String
        var name: String?
    }

    struct Gateway: Codable {
        var port: Int?
        var mode: String?
    }

    // MARK: - I/O

    static var configPath: String {
        NSHomeDirectory() + "/.openclaw/openclaw.json"
    }

    static func load() -> OpenclawConfig? {
        guard let data = FileManager.default.contents(atPath: configPath) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(OpenclawConfig.self, from: data)
    }

    /// `agents.defaults.model.primary` を `<provider>/<model>` で split する。
    /// スラッシュを含む model id (e.g. "anthropic/claude-3.5-sonnet/v2") に備えて
    /// 最初の "/" でのみ分割する。
    static func splitProviderModel(_ raw: String?) -> (provider: String?, model: String?) {
        guard let raw, !raw.isEmpty else { return (nil, nil) }
        if let slash = raw.firstIndex(of: "/") {
            let provider = String(raw[..<slash])
            let model = String(raw[raw.index(after: slash)...])
            return (provider.isEmpty ? nil : provider, model.isEmpty ? nil : model)
        }
        return (nil, raw)
    }
}
