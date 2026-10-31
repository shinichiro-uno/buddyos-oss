import Foundation

/// iPhone からターミナルの agy の会話へ送る「受け取り箱」。
/// scripts/install-agy-remote.sh が ~/.gemini/config/hooks.json に入れる PreInvocation hook
/// （buddy-agy-inbox.sh）が、agy がモデルを呼ぶ直前に `<会話ID>.json` を読んで会話に差し込む。
/// ファイルの中身は hook の出力そのもの（`{"injectSteps":[{"userMessage":"…"}]}`）。
enum AgyInbox {
    static var directory: String { NSHomeDirectory() + "/.buddyos/agy-inbox" }
    static var hooksPath: String { NSHomeDirectory() + "/.gemini/config/hooks.json" }
    static var scriptPath: String { NSHomeDirectory() + "/.buddyos/bin/buddy-agy-inbox.sh" }

    /// ターミナル連携で hook を入れてあるか。
    static func isInstalled(hooksPath: String = AgyInbox.hooksPath, scriptPath: String = AgyInbox.scriptPath) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptPath),
              let data = FileManager.default.contents(atPath: hooksPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["buddyos-inbox"] != nil
    }

    /// 送る文を箱に足す（hook がまだ読んでいない分があれば、その後ろに並べる）。
    static func enqueue(conversationId: String, text: String, directory: String = AgyInbox.directory) throws {
        guard UUID(uuidString: conversationId) != nil else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/\(conversationId).json"
        var steps: [[String: Any]] = []
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = obj["injectSteps"] as? [[String: Any]] {
            steps = existing
        }
        steps.append(["userMessage": text])
        let data = try JSONSerialization.data(withJSONObject: ["injectSteps": steps])
        // 一時ファイルに書いて置き換える（hook が書きかけを読まないように）。
        let tmp = path + ".tmp-\(UUID().uuidString.prefix(8))"
        try data.write(to: URL(fileURLWithPath: tmp))
        _ = rename(tmp, path)
    }
}

/// ターミナルで開いている agy の会話を、agy の記録（transcript.jsonl）を追いかけて流す。
/// agy は段階ごとに 1 行ずつ書き足す（実測: 数秒おき）ので、返事は文字ごとではなく段階ごとに届く。
final class AntigravityTerminalMirror: @unchecked Sendable {
    enum Event: Equatable {
        case user(String)
        case assistant(String)
        case toolStart(String)
        case toolEnd
        /// 道具を呼ばない返事 = ターンの終わり。
        case turnEnd
    }

    private let path: String
    private let onEvent: (Event) -> Void
    private let lock = NSLock()
    private var offset: UInt64 = 0
    private var partial = Data()
    private var timer: DispatchSourceTimer?

    init(conversationId: String, root: String = NSHomeDirectory() + "/.gemini/antigravity-cli",
         onEvent: @escaping (Event) -> Void) {
        self.path = AntigravityTranscript.path(conversationId: conversationId, root: root)
        self.onEvent = onEvent
    }

    /// 今ある分は流さず、これから書き足される分だけを流す。
    func start(interval: TimeInterval = 1) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
        lock.withLock { offset = size }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "buddyos.agy.mirror"))
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        lock.withLock { timer = t }
        t.resume()
    }

    func stop() {
        let t = lock.withLock { () -> DispatchSourceTimer? in let t = timer; timer = nil; return t }
        t?.cancel()
    }

    func poll() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let start = lock.withLock { offset }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return }
        var lines: [Data] = []
        lock.withLock {
            offset = start + UInt64(data.count)
            partial.append(data)
            while let nl = partial.firstIndex(of: 0x0A) {
                lines.append(partial[partial.startIndex..<nl])
                partial.removeSubrange(partial.startIndex...nl)
            }
        }
        for line in lines {
            for event in Self.events(fromLine: line) { onEvent(event) }
        }
    }

    /// transcript の 1 行（1 段階）から流すものを取り出す。
    static func events(fromLine line: Data) -> [Event] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        let content = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch obj["type"] as? String {
        case "USER_INPUT":
            return content.isEmpty ? [] : [.user(AntigravityTranscript.userRequest(content))]
        case "PLANNER_RESPONSE":
            var out: [Event] = []
            if !content.isEmpty { out.append(.assistant(content)) }
            let calls = (obj["tool_calls"] as? [[String: Any]]) ?? []
            if calls.isEmpty {
                out.append(.turnEnd)
            } else {
                out += calls.map { .toolStart(($0["name"] as? String) ?? "tool") }
            }
            return out
        case "GENERIC":
            return [.toolEnd]
        default:
            return []
        }
    }
}
