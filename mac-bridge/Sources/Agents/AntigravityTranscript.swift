import Foundation

/// agy 自身が残す会話の記録。ターミナルで始めた（または続けた）会話は BuddyOS の履歴に無いので、
/// 開いたときにここから本文を読む。
///
/// `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl` の 1 行 = 1 段階:
/// - `USER_EXPLICIT / USER_INPUT`: content が `<USER_REQUEST>…</USER_REQUEST>`（後ろにメタ情報のタグが付くことがある）
/// - `MODEL / PLANNER_RESPONSE`: content が返事の本文（道具だけ呼ぶ段階は content 無し）
/// - `MODEL / GENERIC`（道具の結果）と `SYSTEM / SYSTEM_MESSAGE` は出さない
enum AntigravityTranscript {
    static func path(conversationId: String, root: String = NSHomeDirectory() + "/.gemini/antigravity-cli") -> String {
        root + "/brain/\(conversationId)/.system_generated/logs/transcript.jsonl"
    }

    static func read(conversationId: String, root: String = NSHomeDirectory() + "/.gemini/antigravity-cli") -> [HistoryMessage] {
        // 会話 ID はパスに使うので、UUID の形以外は読まない。
        guard UUID(uuidString: conversationId) != nil,
              let text = try? String(contentsOfFile: path(conversationId: conversationId, root: root), encoding: .utf8)
        else { return [] }
        return parse(text, conversationId: conversationId)
    }

    /// 同じ返事の中で続く本文（道具を挟んだ前後）は 1 つの吹き出しにまとめる。
    static func parse(_ text: String, conversationId: String) -> [HistoryMessage] {
        var out: [HistoryMessage] = []
        var pendingAssistant: [String] = []
        func flushAssistant() {
            guard !pendingAssistant.isEmpty else { return }
            out.append(HistoryMessage(role: "assistant", content: pendingAssistant.joined(separator: "\n\n"),
                                      messageId: "\(conversationId)-\(out.count)"))
            pendingAssistant = []
        }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let content = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            switch obj["type"] as? String {
            case "USER_INPUT":
                flushAssistant()
                out.append(HistoryMessage(role: "user", content: userRequest(content),
                                          messageId: "\(conversationId)-\(out.count)"))
            case "PLANNER_RESPONSE":
                pendingAssistant.append(content)
            default:
                continue
            }
        }
        flushAssistant()
        return out
    }

    /// `<USER_REQUEST>` の中身。タグが無ければ全体。
    static func userRequest(_ content: String) -> String {
        guard let open = content.range(of: "<USER_REQUEST>"),
              let close = content.range(of: "</USER_REQUEST>", range: open.upperBound..<content.endIndex)
        else { return content }
        return String(content[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
