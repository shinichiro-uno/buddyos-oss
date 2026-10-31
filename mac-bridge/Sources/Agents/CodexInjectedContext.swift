import Foundation

/// Codex が会話の先頭などに user ロールで差し込む、ユーザーが打っていない文脈（AGENTS.md の中身、環境情報など）。
/// 一覧の題名・履歴・ターミナルの発話の表示から外す。
enum CodexInjectedContext {
    static func isInjected(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            // Codex のバージョンによって "# AGENTS.md instructions for <dir>" と "# AGENTS.md instructions" の両方がある。
            "# AGENTS.md instructions",
            "<INSTRUCTIONS>",
            "<user_instructions>",
            "<environment_context>",
            "<permissions instructions>",
            "<collaboration_mode>",
            "<personality_spec>",
            "<skills_instructions>",
            "<plugins_instructions>",
            "<skill>",
            // サブエージェントの完了の知らせ。Codex が親の次の要求に差し込み、rollout にも user の発話として残る。
            "<subagent_notification>"
        ]
        return prefixes.contains { trimmed.hasPrefix($0) }
    }

    /// 画像を付けた発話は `<image name=[Image #1] path="…">` と `</image>` で画像を挟む。
    /// 写真は別に出すので、題名や本文からはこの囲みを外す（Claude の "[Image #3]" と同じ扱い）。
    static func strippingImageTags(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"</?image\b[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
