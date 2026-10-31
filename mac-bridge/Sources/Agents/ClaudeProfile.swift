import Foundation

/// `ClaudeCodeAdapter` の表示名・プロバイダ・モデルカタログ。
struct ClaudeProfile: Sendable {
    let id: String
    let displayName: String
    /// AgentInfo.provider に載せる値。iOS のお気に入りキーやヘッダ表示で使う。
    let provider: String
    /// モデルピッカーに出すカタログ。
    let catalog: [ProviderCatalog]

    /// 素の Claude Code(Anthropic)。`AgentRegistry` の既定。
    static let claude = ClaudeProfile(
        id: "claude",
        displayName: "Claude Code",
        provider: "anthropic",
        catalog: [
            ProviderCatalog(
                id: "anthropic",
                label: "Anthropic",
                models: [
                    ModelCatalogItem(id: "fable",  label: "Fable (alias)",  subtitle: "最新の fable を自動選択"),
                    ModelCatalogItem(id: "opus",   label: "Opus (alias)",   subtitle: "最新の opus を自動選択"),
                    ModelCatalogItem(id: "sonnet", label: "Sonnet (alias)", subtitle: "最新の sonnet を自動選択"),
                    ModelCatalogItem(id: "haiku",  label: "Haiku (alias)",  subtitle: "最新の haiku を自動選択"),
                    ModelCatalogItem(id: "claude-fable-5-1",  label: "Claude Fable 5.1",  subtitle: "最新フラッグシップ"),
                    ModelCatalogItem(id: "claude-opus-5-5",   label: "Claude Opus 5.5",   subtitle: "最高品質"),
                    ModelCatalogItem(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5", subtitle: "バランス型"),
                    ModelCatalogItem(id: "claude-haiku-4-5",  label: "Claude Haiku 4.5",  subtitle: "高速・低コスト")
                ]
            )
        ]
    )
}
