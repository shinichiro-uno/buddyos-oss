import Foundation

/// 音声会話モードから送られたターンの指定。
/// アプリが user_message の metadata に `voice=1`（と、遮られたときだけ `voiceSpoken`）を載せて送る。
/// 状態はアプリに持たせず、メッセージごとの印で決める（印の無い通常メッセージが来れば通常の設定に戻る）。
struct VoiceTurn: Equatable, Sendable {
    /// 直前のアシスタント応答のうち、ユーザーに遮られるまでに読み上げ終えた部分。遮られていなければ nil。
    var spoken: String?

    /// 読み上げ済み部分として受け付ける最大文字数（アプリは末尾 300 文字を送る）。
    static let maxSpokenLength = 300

    init(spoken: String? = nil) {
        self.spoken = spoken
    }

    /// metadata から読む。`voice=1` が無ければ nil（通常ターン）。
    init?(metadata: [String: String]?) {
        guard metadata?["voice"] == "1" else { return nil }
        let spoken = metadata?["voiceSpoken"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(spoken: spoken.isEmpty ? nil : String(spoken.suffix(Self.maxSpokenLength)))
    }

    /// 音声会話中の応え方。どのエージェントでも本文末尾の `<voice-context>` に入れる
    /// （起動引数に入れると、通常と音声が切り替わるたびに CLI を起こし直すことになる）。
    static let directive = """
    The user is talking to you by voice right now: their messages come from speech recognition and your reply will be read aloud by text-to-speech.
    - Reply in the user's language, conversationally, in one to three short sentences. Lead with the answer.
    - Do not use Markdown, bullet points, tables, code blocks, URLs, or file paths in what you say. Describe them in plain words instead.
    - Speech recognition may mishear words. Infer the most likely intent rather than asking about obvious typos.
    - When real work is needed (editing files, running commands), say in one short sentence what you will do, do it, then report the result in one or two sentences.
    - If you need to ask something, ask only one question at a time.
    """

    /// 遮られたときの注記。そのターンのモデル入力にだけ付ける。
    var interruptionNote: String? {
        guard let spoken, !spoken.isEmpty else { return nil }
        return """
        Your previous reply was interrupted while it was being read aloud. The user only heard it up to: "\(spoken)"
        The rest of that reply was not heard. Do not assume the user knows it; repeat anything important only if it is still relevant.
        """
    }

    /// モデル入力の末尾に付ける `<voice-context>` ブロック（前に空行込み）。付けるものが無ければ nil。
    /// 末尾に置くのは、一覧のタイトル（本文の先頭数十文字）にユーザーの言葉を残すため。
    /// `includeDirective` が false なら遮られた注記だけを付ける。
    func contextBlock(includeDirective: Bool) -> String? {
        let parts = [includeDirective ? Self.directive : nil, interruptionNote].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "\n\n<voice-context>\n\(parts.joined(separator: "\n\n"))\n</voice-context>"
    }

    /// 本文の末尾に `<voice-context>` を付ける。付けるものが無ければそのまま返す。
    func appended(to text: String, includeDirective: Bool) -> String {
        guard let block = contextBlock(includeDirective: includeDirective) else { return text }
        return text + block
    }

    /// 履歴・一覧の本文から `<voice-context>` を剥がす（ユーザーには見せない）。
    static func stripContext(_ text: String) -> String {
        guard text.contains("<v") else { return text }
        return text
            .replacingOccurrences(of: #"\s*<voice-context>[\s\S]*?</voice-context>\s*"#, with: "", options: .regularExpression)
            // 一覧のタイトル（先頭数十文字）で閉じタグまで届かず切れたもの。
            .replacingOccurrences(of: #"\s*<voice-context>[\s\S]*$"#, with: "", options: .regularExpression)
            // 開きタグの途中で切れたもの（「…<voice-con...」）。
            .replacingOccurrences(of: partialOpenTag, with: "", options: .regularExpression)
    }

    /// 末尾の `<v` 〜 `<voice-context` と、切ったときに付く「...」。
    private static let partialOpenTag = #"\s*<v(?:o(?:i(?:c(?:e(?:-(?:c(?:o(?:n(?:t(?:e(?:x(?:t>?)?)?)?)?)?)?)?)?)?)?)?)?(?:\.\.\.|…)?$"#
}

/// 音声ターンの指定を自分で扱えるセッション（system prompt や effort を起動引数で変えられるもの）。
/// 持たないセッションには WebSocketServer が本文末尾の `<voice-context>` で指示を渡す。
protocol VoiceTurnAware: AnyObject {
    /// `voice` が nil なら通常ターン。
    func send(_ text: String, skills: [String], attachments: [BridgeAttachment], voice: VoiceTurn?) async
}
