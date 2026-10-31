import Foundation

/// エージェントなど、Bridge が起動する子プロセスに渡す環境変数の土台。
///
/// Bridge 自身の環境変数には、Clerk のアクセストークン（`BUDDYOS_CLERK_TOKEN`。desktop が渡す）や
/// MCP の合鍵（`BUDDYOS_MCP_*`）が載ることがある。`ProcessInfo.processInfo.environment`
/// を丸ごと渡すと、プロンプトインジェクションを受けたエージェントがそれを読んで `/my-bridges` から
/// 他の Mac の apiKey を取れてしまう。子プロセスの環境は必ずここから作る。
///
/// mainagent の合鍵（`MainAgentWorkspace.tokenEnvVar`）は、渡すセッションの起動側で明示的に足す。
enum ChildEnvironment {
    /// 子プロセスに渡さない環境変数の名前。
    static let strippedNames: Set<String> = [
        "BUDDYOS_CLERK_TOKEN",
        // opencode serve のパスワードは serve にだけ渡す（Bridge の環境に載っていても漏らさない）。
        "OPENCODE_SERVER_PASSWORD",
    ]
    /// 子プロセスに渡さない環境変数の接頭辞。
    static let strippedPrefixes: [String] = [
        "BUDDYOS_MCP_",
    ]

    static func isStripped(_ name: String) -> Bool {
        strippedNames.contains(name) || strippedPrefixes.contains { name.hasPrefix($0) }
    }

    /// Bridge の環境変数から秘密を取り除いたもの。
    static func base() -> [String: String] {
        sanitized(ProcessInfo.processInfo.environment)
    }

    static func sanitized(_ env: [String: String]) -> [String: String] {
        env.filter { !isStripped($0.key) }
    }

    /// base() に extra を上書きで足す（extra 側の秘密は呼び出し側の責任で渡す）。
    static func base(merging extra: [String: String]) -> [String: String] {
        base().merging(extra) { _, new in new }
    }
}
