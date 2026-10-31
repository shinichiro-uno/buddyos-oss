import Foundation

/// `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` を走査して
/// Claude Code CLI のネイティブセッション履歴を返す。
/// ClaudeCodeSessionStore (= BuddyOS 経由のセッション) と並列に扱われ、
/// ClaudeCodeAdapter で merge される。
actor ClaudeCodeProjectsScanner {
    static let shared = ClaudeCodeProjectsScanner()

    private static var projectsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    /// 新しい順、最大 `limit` 件。`cwd` を渡すと完全一致 filter。
    ///
    /// 旧実装は呼ばれる度に全 jsonl (~316 本 / 1.4GB) を丸読みしていて履歴表示が詰まった。
    /// 改善: ①mtime で並べて新しい方から limit 件埋まるまでだけパース ②mtime+size cache で
    /// 変化していないセッションは再パースしない ③巨大ファイルは 1 行ずつ stream 読み。
    func listSessions(limit: Int, cwd: String?) -> [SessionSummary] {
        let normalized = normalize(cwd)
        let maxCount = max(1, limit)
        var result: [SessionSummary] = []
        for entry in sessionFiles() {
            guard let scanned = cachedSummary(url: entry.url, modified: entry.modified, size: entry.size) else { continue }
            if let normalized, scanned.cwd != normalized { continue }
            result.append(scanned.summary)
            if result.count >= maxCount { break }
        }
        return result
    }

    /// UUID で指定された jsonl から会話履歴を取り出す。見つからない場合は nil。
    func loadHistory(sessionId: String) -> [HistoryMessage]? {
        loadHistoryRead(sessionId: sessionId)?.messages
    }

    /// loadHistory と、読み終えた位置（最後の改行まで）。claude --bg の会話が、同じ行を履歴と live の両方に出さないために使う。
    func loadHistoryRead(sessionId: String) -> (messages: [HistoryMessage], file: String, end: UInt64)? {
        guard let url = findSessionFile(sessionId: sessionId) else { return nil }
        let (messages, end) = parseHistoryTracking(at: url)
        return (messages, url.path, end)
    }

    /// transcript に記録された cwd を返す。`claude --resume` はセッション作成時と同じ
    /// cwd でないとセッションを解決できないため、cwd 未指定の resume で spawn ディレクトリを
    /// 作成時と一致させるのに使う。
    func cwd(forSessionId sessionId: String) -> String? {
        guard let url = findSessionFile(sessionId: sessionId) else { return nil }
        var found: String?
        var lineBudget = 0
        Self.forEachLine(file: url) { line in
            lineBudget += 1
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let c = obj["cwd"] as? String, !c.isEmpty {
                found = c
                return false
            }
            return lineBudget < 5000
        }
        return found
    }

    // MARK: - Internal

    private struct ScannedSession {
        let sessionId: String
        let cwd: String?
        let gitBranch: String?
        let title: String
        let lastActive: String
        let messageCount: Int?

        var summary: SessionSummary {
            SessionSummary(
                sessionId: sessionId,
                title: title,
                lastActive: lastActive,
                messageCount: messageCount,
                cwd: cwd
            )
        }
    }

    /// 全プロジェクト配下の jsonl を (url, mtime, size) で集めて mtime 降順に並べる。
    /// パースはせず stat だけなので軽い。listSessions はこの順で必要数だけパースする。
    private func sessionFiles() -> [(url: URL, modified: Date, size: Int)] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: Self.projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }
        var files: [(url: URL, modified: Date, size: Int)] = []
        for projectDir in projectDirs {
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }
            for file in entries where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                files.append((file, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
            }
        }
        return files.sorted { $0.modified > $1.modified }
    }

    // 要約結果を path → (mtime,size) で cache。actor isolation なので lock 不要。
    private var summaryCache: [String: (mtime: Date, size: Int, parsed: ScannedSession?)] = [:]

    private func cachedSummary(url: URL, modified: Date, size: Int) -> ScannedSession? {
        let key = url.path
        if let hit = summaryCache[key], hit.mtime == modified, hit.size == size {
            return hit.parsed
        }
        let parsed = parseSummary(at: url, mtime: modified)
        summaryCache[key] = (modified, size, parsed)
        return parsed
    }

    private func parseSummary(at url: URL, mtime: Date) -> ScannedSession? {
        let sessionId = url.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: sessionId) != nil else { return nil }

        var firstUserText: String?
        var cwd: String?
        var gitBranch: String?
        var sawAnyLine = false
        var lineBudget = 0

        // タイトル(=最初の有効な user 発言) と cwd が揃えば即打ち切る。巨大セッションを
        // 件数集計のため全行 JSON パースすると 1 本で数分かかるので件数は数えない。
        Self.forEachLine(file: url) { line in
            sawAnyLine = true
            lineBudget += 1
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return lineBudget < 5000 }

            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if gitBranch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { gitBranch = b }

            let type = obj["type"] as? String
            if firstUserText == nil, type == "user",
               let message = obj["message"] as? [String: Any] {
                let raw = Self.extractText(from: message["content"])
                if let cleaned = Self.titleCandidate(raw) {
                    firstUserText = cleaned
                }
            }
            if cwd != nil, firstUserText != nil { return false }
            return lineBudget < 5000
        }
        guard sawAnyLine else { return nil }

        let lastActive = ISO8601DateFormatter().string(from: mtime)
        // Claude Code 自身の題名を優先: /rename の名前 > 自動要約 > 最初のユーザー発言。
        // 題名の行は会話が進んでから追記されるので、先頭ではなくファイル末尾から探す。
        let claudeTitle = Self.readTail(url: url, maxBytes: 512 * 1024).flatMap { Self.latestClaudeTitle(in: $0) }

        return ScannedSession(
            sessionId: sessionId,
            cwd: cwd,
            gitBranch: gitBranch,
            title: claudeTitle.map { Self.preview($0) } ?? Self.preview(firstUserText ?? ""),
            lastActive: lastActive,
            messageCount: nil
        )
    }

    /// 末尾の最大 maxBytes を文字列で返す（途中から読んだ場合、先頭の切れた行は捨てる）。
    static func readTail(url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard offset > 0 else { return text }
        guard let nl = text.firstIndex(of: "\n") else { return nil }
        return String(text[text.index(after: nl)...])
    }

    /// jsonl の題名行から Claude Code の題名を取り出す。同じ種類は後の行が優先。
    /// `/rename` の `custom-title`（customTitle）が自動要約 `ai-title`（aiTitle）より優先。
    static func latestClaudeTitle(in text: String) -> String? {
        var custom: String?
        var ai: String?
        for line in text.split(separator: "\n") where line.hasPrefix("{\"type\":\"custom-title\"") || line.hasPrefix("{\"type\":\"ai-title\"") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let clean: (Any?) -> String? = { v in
                guard let t = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                return t
            }
            switch obj["type"] as? String {
            case "custom-title": if let t = clean(obj["customTitle"]) { custom = t }
            case "ai-title": if let t = clean(obj["aiTitle"]) { ai = t }
            default: break
            }
        }
        return custom ?? ai
    }

    /// 巨大ファイルを 1 本の String に展開せず 1 MB チャンクで読み、改行区切りで
    /// `body` に 1 行ずつ渡す。`body` が false を返すと打ち切る。
    static func forEachLine(file: URL, _ body: (String) -> Bool) {
        _ = forEachLineTracking(file: file, body)
    }

    /// forEachLine と同じで、読み終えた位置（最後の改行の次。改行で終わらない最後の行は含めない）を返す。
    @discardableResult
    static func forEachLineTracking(file: URL, _ body: (String) -> Bool) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { try? handle.close() }
        var buffer = Data()
        let newline: UInt8 = 0x0A
        var stop = false
        var totalRead: UInt64 = 0
        var consumed: UInt64 = 0
        while !stop {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            totalRead += UInt64(chunk.count)
            buffer.append(chunk)
            var searchStart = buffer.startIndex
            while let nl = buffer[searchStart...].firstIndex(of: newline) {
                if nl > searchStart {
                    let lineData = buffer.subdata(in: searchStart..<nl)
                    if let s = String(data: lineData, encoding: .utf8), !s.isEmpty, !body(s) {
                        stop = true
                        break
                    }
                }
                searchStart = buffer.index(after: nl)
            }
            if stop { break }
            if searchStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<searchStart)
            }
            consumed = totalRead - UInt64(buffer.count)
        }
        if !stop, !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8), !s.isEmpty {
            _ = body(s)
        }
        return consumed
    }

    private func findSessionFile(sessionId: String) -> URL? {
        guard UUID(uuidString: sessionId) != nil else { return nil }
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: Self.projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return nil
        }
        for projectDir in projectDirs {
            let candidate = projectDir.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func parseHistoryTracking(at url: URL) -> (messages: [HistoryMessage], end: UInt64) {
        var messages: [HistoryMessage] = []
        let end = Self.forEachLineTracking(file: url) { line in
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return true }
            let type = obj["type"] as? String
            guard type == "user" || type == "assistant" else { return true }
            // システム注入された user メッセージは会話本文ではないので除外する。
            //  - isMeta: スキル / スラッシュコマンドの展開プロンプト（数万〜十数万字になる）
            //  - isCompactSummary / isVisibleInTranscriptOnly: compaction 継続の要約
            // これらを出すと「サブエージェントに送るプロンプトまで表示される」症状になる。
            if (obj["isMeta"] as? Bool) == true
                || (obj["isCompactSummary"] as? Bool) == true
                || (obj["isVisibleInTranscriptOnly"] as? Bool) == true { return true }
            guard let message = obj["message"] as? [String: Any] else { return true }
            let role = (message["role"] as? String) ?? type ?? "user"
            let messageId = (obj["uuid"] as? String) ?? UUID().uuidString
            // 会話ビュー用: ユーザーの発言と assistant のテキスト返信だけを出す。
            // tool_use / tool_result（"[tool_use: Bash]" や "Command running..." 等の
            // ツール実行・結果）やシステム注入（caveat / system-reminder）は除外する。
            // 受け箱（ほかの Claude セッション）から届いた発話は、枠を外した本文を出す。
            let isPeer = type == "user" && Self.isPeer(obj)
            let content = isPeer
                ? Self.conversationText(from: Self.stripPeerFrame(Self.rawText(from: message["content"])))
                : Self.conversationText(from: message["content"])
            // ユーザーが貼った写真（スマホから送った画像を含む）は image ブロックで残っている。
            // 以前は文字だけを拾っていたため、履歴を開き直すと写真が消えていた。
            let images = role == "user" ? Self.imageAttachments(from: message["content"]) : []
            guard !content.isEmpty || !images.isEmpty else { return true }
            messages.append(HistoryMessage(role: role, content: content, messageId: messageId, attachments: images))
            return true
        }
        return (messages, end)
    }

    /// user 行が受け箱（cross-session messaging）から届いた発話か。
    static func isPeer(_ obj: [String: Any]) -> Bool {
        (obj["origin"] as? [String: Any])?["kind"] as? String == "peer"
    }

    /// content の text を連結しただけの本文（包みは外さない）。
    static func rawText(from content: Any?) -> String {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return "" }
        return arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    /// 受け箱から届いた発話の枠を外す。1 行目（`Another Claude session sent a message:`）を落とし、
    /// 最後の `\n\nThis came from another Claude session` から後ろを落とす。見つからなければ 1 行目だけ落とす。
    static func stripPeerFrame(_ text: String) -> String {
        let rest: Substring
        if let nl = text.firstIndex(of: "\n") { rest = text[text.index(after: nl)...] } else { rest = "" }
        if let cut = rest.range(of: "\n\nThis came from another Claude session", options: .backwards) {
            return String(rest[..<cut.lowerBound])
        }
        return String(rest)
    }

    private func normalize(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if cwd == "~" { return home }
        if cwd.hasPrefix("~/") {
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        return (cwd as NSString).standardizingPath
    }

    /// 会話ビュー用のテキスト抽出。`extractText` と違い tool_use / tool_result /
    /// thinking を含めず、純粋な発言テキストだけを返す。文字列はシステム包装
    /// (caveat / system-reminder / command 系) を剥がし、残らなければ空を返す
    /// (= 呼び出し側で skip され、ツール結果だけの user turn 等は表示されない)。
    static func conversationText(from content: Any?) -> String {
        if let s = content as? String {
            return stripSystemWrappers(s)
        }
        if let arr = content as? [[String: Any]] {
            let parts = arr.compactMap { block -> String? in
                guard (block["type"] as? String) == "text", let t = block["text"] as? String else { return nil }
                // 画像の位置を示すだけの "[Image #3]" は、写真そのものを出すので本文から外す。
                let cleaned = stripSystemWrappers(t)
                    .replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
            return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// 1 枚あたりの上限（base64 の文字数）。巨大な画像で履歴の転送が詰まらないようにする。
    static let maxHistoryImageB64 = 4 * 1024 * 1024

    /// user メッセージの image ブロック（base64）を添付に変換する。tool_result 内の画像
    /// （スクリーンショット等のツール出力）は会話の発言ではないので含めない。
    static func imageAttachments(from content: Any?) -> [HistoryAttachment] {
        guard let arr = content as? [[String: Any]] else { return [] }
        var out: [HistoryAttachment] = []
        for block in arr where (block["type"] as? String) == "image" {
            guard let source = block["source"] as? [String: Any],
                  (source["type"] as? String) == "base64",
                  let data = source["data"] as? String, !data.isEmpty,
                  data.count <= maxHistoryImageB64
            else { continue }
            let mime = (source["media_type"] as? String) ?? "image/png"
            let ext = mime.split(separator: "/").last.map(String.init) ?? "png"
            out.append(HistoryAttachment(kind: "image", name: "image-\(out.count + 1).\(ext)", mime: mime, b64: data))
        }
        return out
    }

    private static func extractText(from content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { block -> String? in
                let type = block["type"] as? String
                if type == "text", let text = block["text"] as? String { return text }
                if type == "thinking", let text = block["thinking"] as? String { return text }
                if type == "tool_use", let name = block["name"] as? String {
                    return "[tool_use: \(name)]"
                }
                if type == "tool_result" {
                    if let s = block["content"] as? String { return s }
                    if let blocks = block["content"] as? [[String: Any]] {
                        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    }
                }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func preview(_ content: String) -> String {
        let compact = content
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return "(no messages)" }
        return compact.count > 80 ? String(compact.prefix(77)) + "..." : compact
    }

    /// `<local-command-caveat>` / `<local-command-stdout>` の 1 行だけのメッセージは
    /// タイトルに使わない (= nil)。`<command-name>/foo</command-name>` は "/foo" を返す。
    /// 通常テキストは <system-reminder> や caveat 群を剥がした残りを返す。
    private static func titleCandidate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // <command-name>/foo</command-name> → "/foo"
        if let name = firstMatch(in: trimmed, pattern: #"<command-name>([^<]+)</command-name>"#) {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { return n }
        }

        // 完全に caveat / stdout / system-reminder だけのメッセージはスキップ
        let stripped = stripSystemWrappers(trimmed)
        if stripped.isEmpty { return nil }
        return stripped
    }

    static func stripSystemWrappers(_ s: String) -> String {
        var current = s
        // <local-command-caveat>...</local-command-caveat>
        // <local-command-stdout>...</local-command-stdout>
        // <system-reminder>...</system-reminder>
        // <command-message>...</command-message>
        // <command-args>...</command-args>
        let patterns = [
            #"<local-command-caveat>[\s\S]*?</local-command-caveat>"#,
            #"<local-command-stdout>[\s\S]*?</local-command-stdout>"#,
            #"<system-reminder>[\s\S]*?</system-reminder>"#,
            #"<command-name>[\s\S]*?</command-name>"#,
            #"<command-message>[\s\S]*?</command-message>"#,
            #"<command-args>[\s\S]*?</command-args>"#,
            // サブエージェント / バックグラウンドタスクの完了通知（システム注入、長大）
            #"<task-notification>[\s\S]*?</task-notification>"#
        ]
        for p in patterns {
            current = current.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return current.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstMatch(in s: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let match = regex.firstMatch(in: s, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
