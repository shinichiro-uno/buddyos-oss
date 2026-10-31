import Foundation

final class CodexHistoryStore {
    private struct ParsedSession {
        let sessionId: String
        let cwd: String
        let created: String
        let modified: String
        let firstPrompt: String
        let lastPrompt: String
        let lastAssistant: String
        let messageCount: Int?
    }

    private struct ParsedMessage {
        let role: String
        let content: String
        let timestamp: String?
    }

    private let fileManager = FileManager.default

    // 一覧用の要約パース結果を (path → mtime+size) でキャッシュする。
    // codex のセッションは作業中のものが数百 MB に膨れるため、履歴を開く度に
    // 全ファイルを丸読みすると詰まる。変化していないファイルは再パースしない。
    private let cacheLock = NSLock()
    private var sessionCache: [String: (mtime: Date, size: Int, parsed: ParsedSession?)] = [:]

    private func cachedSession(url: URL, modified: Date, size: Int) -> ParsedSession? {
        let key = url.path
        cacheLock.lock()
        if let hit = sessionCache[key], hit.mtime == modified, hit.size == size {
            cacheLock.unlock()
            return hit.parsed
        }
        cacheLock.unlock()
        let parsed = parseSession(file: url, mtime: modified)
        cacheLock.lock()
        sessionCache[key] = (modified, size, parsed)
        cacheLock.unlock()
        return parsed
    }

    /// 巨大ファイルを 1 本の String に展開せず、1 MB チャンクで読みながら
    /// 改行区切りで 1 行ずつ `body` に渡す。`body` が false を返すと打ち切る。
    /// バッファのコンパクトは 1 チャンクにつき 1 回だけ行い O(n) を保つ。
    private func forEachLine(file: URL, _ body: (String) -> Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        let newline: UInt8 = 0x0A
        var stop = false
        while !stop {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
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
        }
        if !stop, !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8), !s.isEmpty {
            _ = body(s)
        }
    }

    func listSessions(limit: Int, cwd: String?) -> [SessionSummary] {
        let names = loadSessionNames()
        let normalizedFilter = normalizePath(cwd)
        let maxCount = max(1, limit)
        var result: [SessionSummary] = []

        for entry in codexSessionFiles() {
            guard let parsed = cachedSession(url: entry.url, modified: entry.modified, size: entry.size) else { continue }
            if let normalizedFilter, normalizePath(parsed.cwd) != normalizedFilter {
                continue
            }

            let title = nonEmpty(names[parsed.sessionId])
                ?? preview(parsed.firstPrompt)
                ?? preview(parsed.lastAssistant)
                ?? parsed.sessionId

            result.append(SessionSummary(
                sessionId: parsed.sessionId,
                title: title,
                lastActive: parsed.modified,
                messageCount: parsed.messageCount,
                cwd: parsed.cwd
            ))

            if result.count >= maxCount { break }
        }

        return result
    }

    func loadHistory(sessionId: String) -> [HistoryMessage] {
        guard let file = findSessionFile(sessionId: sessionId) else { return [] }
        return parseMessages(file: file).enumerated().map { index, message in
            HistoryMessage(
                role: message.role,
                content: message.content,
                messageId: "\(sessionId)-\(index)"
            )
        }
    }

    private func codexRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let explicit = nonEmpty(env["BUDDYOS_CODEX_HOME"]) ?? nonEmpty(env["CODEX_HOME"]) {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private func codexSessionFiles() -> [(url: URL, modified: Date, size: Int)] {
        let root = codexRoot().appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modified: Date, size: Int)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
        }
        return files.sorted { $0.modified > $1.modified }
    }

    private func findSessionFile(sessionId: String) -> URL? {
        let files = codexSessionFiles()
        if let byName = files.first(where: { $0.url.deletingPathExtension().lastPathComponent.contains(sessionId) }) {
            return byName.url
        }
        return files.first { cachedSession(url: $0.url, modified: $0.modified, size: $0.size)?.sessionId == sessionId }?.url
    }

    /// 一覧用の要約パース。タイトル(=最初のユーザー発言) と cwd が揃った時点で
    /// 即打ち切る。巨大セッション (数百 MB) で全行を JSON パースすると 1 本で 3 分かかる
    /// ため、メッセージ件数は数えない (messageCount = nil)。lastActive はファイル mtime。
    /// `lineBudget` は user 発言が現れない pathological ファイルの暴走を防ぐ保険。
    private func parseSession(file: URL, mtime: Date) -> ParsedSession? {
        var sessionId = fallbackSessionId(file: file)
        var cwd = ""
        var created = ""
        var firstPrompt = ""
        var firstAssistant = ""
        var skip = false
        var sawAnyLine = false
        var sawMessage = false
        var lineBudget = 0

        forEachLine(file: file) { line in
            sawAnyLine = true
            lineBudget += 1
            guard let entry = parseJSONLine(line) else {
                return lineBudget < 5000
            }
            if created.isEmpty, let ts = string(entry["timestamp"]) { created = ts }

            switch string(entry["type"]) {
            case "session_meta":
                if let payload = dictionary(entry["payload"]) {
                    if isInternalSessionSource(payload["source"]) { skip = true }
                    if let id = nonEmpty(string(payload["id"])) { sessionId = id }
                    if let payloadCwd = nonEmpty(string(payload["cwd"])) { cwd = payloadCwd }
                }
            case "turn_context":
                if cwd.isEmpty, let payload = dictionary(entry["payload"]),
                   let payloadCwd = nonEmpty(string(payload["cwd"])) {
                    cwd = payloadCwd
                }
            case "event_msg":
                if let payload = dictionary(entry["payload"]) {
                    if string(payload["type"]) == "user_message",
                       let text = nonEmpty(string(payload["message"]).map(CodexInjectedContext.strippingImageTags)), !isInjectedUserContext(text) {
                        sawMessage = true
                        if firstPrompt.isEmpty { firstPrompt = text }
                    } else if string(payload["type"]) == "agent_message",
                              let text = nonEmpty(string(payload["message"])) {
                        sawMessage = true
                        if firstAssistant.isEmpty { firstAssistant = text }
                    }
                }
            case "response_item":
                if let payload = dictionary(entry["payload"]), string(payload["type"]) == "message" {
                    let role = string(payload["role"])
                    if role == "assistant", let text = nonEmpty(messageText(payload: payload, itemType: "output_text")) {
                        sawMessage = true
                        if firstAssistant.isEmpty { firstAssistant = text }
                    } else if role == "user", let text = nonEmpty(messageText(payload: payload, itemType: "input_text")),
                              !isInjectedUserContext(text) {
                        sawMessage = true
                        if firstPrompt.isEmpty { firstPrompt = text }
                    }
                }
            default:
                break
            }
            // タイトル候補 + cwd が揃えば打ち切り。保険として line 上限も。
            if !cwd.isEmpty && !firstPrompt.isEmpty { return false }
            return lineBudget < 5000
        }

        guard sawAnyLine, !skip, !cwd.isEmpty, sawMessage else { return nil }
        // 最終更新は最後の行の timestamp（Windows と同じ）。ファイルの更新時刻は写し直しで変わる。
        let modified = lastTimestamp(file: file) ?? isoString(mtime)
        if created.isEmpty { created = modified }
        return ParsedSession(
            sessionId: sessionId,
            cwd: cwd,
            created: created,
            modified: modified,
            firstPrompt: firstPrompt,
            lastPrompt: firstPrompt,
            lastAssistant: firstAssistant,
            messageCount: nil
        )
    }

    /// ファイル末尾（最大 64KB）から最後の timestamp を読む。一覧は先頭だけ読んで打ち切るので、
    /// 数百 MB の会話でも全体は読まない。
    private func lastTimestamp(file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let tail: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            if let entry = parseJSONLine(String(line)), let ts = nonEmpty(string(entry["timestamp"])) { return ts }
        }
        return nil
    }

    private func parseMessages(file: URL) -> [ParsedMessage] {
        var result: [ParsedMessage] = []

        forEachLine(file: file) { line in
            guard let entry = parseJSONLine(line) else { return true }
            let timestamp = string(entry["timestamp"])

            switch string(entry["type"]) {
            case "event_msg":
                guard let payload = dictionary(entry["payload"]) else { return true }
                if string(payload["type"]) == "user_message",
                   let text = nonEmpty(string(payload["message"]).map(CodexInjectedContext.strippingImageTags)),
                   !isInjectedUserContext(text) {
                    appendMessage(role: "user", content: text, timestamp: timestamp, to: &result)
                } else if string(payload["type"]) == "agent_message",
                          let text = nonEmpty(string(payload["message"])) {
                    appendMessage(role: "assistant", content: text, timestamp: timestamp, to: &result)
                }
            case "response_item":
                guard let payload = dictionary(entry["payload"]),
                      string(payload["type"]) == "message" else { return true }
                if string(payload["role"]) == "assistant" {
                    let text = messageText(payload: payload, itemType: "output_text")
                    if let text = nonEmpty(text) {
                        appendMessage(role: "assistant", content: text, timestamp: timestamp, to: &result)
                    }
                } else if string(payload["role"]) == "user" {
                    let text = messageText(payload: payload, itemType: "input_text")
                    if let text = nonEmpty(text), !isInjectedUserContext(text) {
                        appendMessage(role: "user", content: text, timestamp: timestamp, to: &result)
                    }
                }
            default:
                return true
            }
            return true
        }

        return result
    }

    private func loadSessionNames() -> [String: String] {
        let file = codexRoot().appendingPathComponent("session_index.jsonl")
        guard let lines = readLines(file: file) else { return [:] }
        var names: [String: String] = [:]
        for line in lines {
            guard let entry = parseJSONLine(line),
                  let id = nonEmpty(string(entry["id"])) else { continue }
            names[id] = nonEmpty(string(entry["thread_name"])) ?? ""
        }
        return names
    }

    private func readLines(file: URL) -> [String]? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func parseJSONLine(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func messageText(payload: [String: Any], itemType: String) -> String {
        guard let content = payload["content"] as? [[String: Any]] else { return "" }
        let text = content
            .filter { string($0["type"]) == itemType }
            .compactMap { string($0["text"]) }
            .joined(separator: "\n")
        return itemType == "input_text" ? CodexInjectedContext.strippingImageTags(text) : text
    }

    @discardableResult
    private func appendMessage(role: String, content: String, timestamp: String?, to result: inout [ParsedMessage]) -> Bool {
        let normalized = compact(content)
        guard !normalized.isEmpty else { return false }
        if let last = result.last, last.role == role, compact(last.content) == normalized {
            return false
        }
        result.append(ParsedMessage(role: role, content: content, timestamp: timestamp))
        return true
    }

    private func isInternalSessionSource(_ value: Any?) -> Bool {
        guard let source = dictionary(value) else { return false }
        return source["subagent"] != nil
    }

    private func isInjectedUserContext(_ text: String) -> Bool {
        CodexInjectedContext.isInjected(text)
    }

    private func fallbackSessionId(file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        if let match = name.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#, options: .regularExpression) {
            return String(name[match])
        }
        return name
    }

    private func normalizePath(_ path: String?) -> String? {
        guard let path = nonEmpty(path) else { return nil }
        var value = NSString(string: path).standardizingPath
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private func fileModificationDate(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func preview(_ text: String) -> String? {
        let compacted = compact(text)
        guard !compacted.isEmpty else { return nil }
        if compacted.count <= 80 { return compacted }
        return String(compacted.prefix(77)) + "..."
    }

    private func compact(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }

    private func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}
