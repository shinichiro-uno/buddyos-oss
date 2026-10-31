import Foundation

actor AgentRegistry {
    static let shared = AgentRegistry()

    private var adapters: [String: any AgentAdapter] = [:]

    init() {
        let hermes = HermesAdapter()
        adapters[hermes.id] = hermes
        let codex = CodexHistoryAdapter()
        adapters[codex.id] = codex
        let claude = ClaudeCodeAdapter()
        adapters[claude.id] = claude
        // Cursor CLI / Grok Build CLI（headless stream-json 実行）。beta トグル配下。
        let cursor = HeadlessCliAdapter(profile: .cursor)
        adapters[cursor.id] = cursor
        let grok = HeadlessCliAdapter(profile: .grok)
        adapters[grok.id] = grok
        // Antigravity CLI (Google)。Gemini CLI の後継。beta ではなく通常表示。
        let antigravity = HeadlessCliAdapter(profile: .antigravity)
        adapters[antigravity.id] = antigravity
        let openclaw = OpenclawAdapter()
        adapters[openclaw.id] = openclaw
        let opencode = OpenCodeAdapter()
        adapters[opencode.id] = opencode
        let buddy = BuddyAdapter()
        adapters[buddy.id] = buddy
        let echo = EchoAdapter()
        adapters[echo.id] = echo
    }

    func adapter(for id: String) -> (any AgentAdapter)? {
        adapters[id]
    }

    func descriptors() -> [AgentDescriptor] {
        adapters.values
            .map {
                AgentDescriptor(
                    id: $0.id,
                    displayName: $0.displayName,
                    capabilities: Self.capabilities(of: $0)
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// adapter の申告に、Bridge 側のサービスが持っている事実（cron の仕組み・ログイン手順・
    /// 使用量の読み取り）を足す。それぞれの真実は 1 か所にだけ置き、ここで合流させる。
    static func capabilities(of adapter: any AgentAdapter) -> AgentCapabilities {
        var caps = adapter.capabilities
        if adapter is any BridgeCronHosted {
            caps.cron = true
            caps.cronOptions = true
        }
        caps.login = AgentLoginService.supports(adapter.id)
        caps.usage = UsageReader.supports(adapter.id)
        caps.mcpRegister = McpService.canRegister(adapter.id)
        return caps
    }

    func register(_ adapter: any AgentAdapter) {
        adapters[adapter.id] = adapter
    }
}
