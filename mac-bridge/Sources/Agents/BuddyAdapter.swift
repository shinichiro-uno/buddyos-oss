import Foundation

/// buddy — MCP 連携と回答速度に特化した、使いやすさ重視の汎用アシスタント。
/// コーディングエージェントではない。bridge 内の一級エージェントとして OpenRouter を直接叩く
/// （高速応答のため ACP プロセスは起動しない）。マネージドプランの OpenRouter キーを流用する。
final class BuddyAdapter: AgentAdapter {
    let id = "buddy"
    let displayName = "Buddy"
    // mcp + actions(承認ゲート) + models。cron/skills/commands は持たない（使いやすさ優先）。
    let capabilities = AgentCapabilities(
        chat: true,
        history: false,
        projects: false,
        commands: false,
        models: true,
        cron: false,
        skills: false,
        mcp: true,
        attachments: true,
        actions: true
    )

    /// OpenRouter のモデル slug。Gemini Flash 系を既定（最速・最安＝クレジット経済が良好）。
    static let defaultModel = "google/gemini-2.0-flash-001"

    private static let systemPrompt = """
    あなたは「Buddy」、ユーザーのスマートフォンに常駐する高速・親切なAIアシスタントです。
    コーディング専用ではなく、日常のあらゆる相談・調べ物・連携ツールの操作を手伝います。
    - 簡潔で分かりやすく、結論から答えます。長い前置きや冗長な定型文は避けます。
    - 接続された MCP ツールがある場合は積極的に活用しますが、ツール実行はユーザーの承認を要します。
    - 日本語で話しかけられたら日本語で、英語なら英語で答えます。
    """

    private let configPath = NSHomeDirectory() + "/.buddyos/buddy.json"

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        BuddySession(
            sessionId: sessionId,
            model: resolveModel(),
            apiKey: Self.resolveApiKey(),
            systemPrompt: Self.systemPrompt
        )
    }

    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] { [] }
    func loadHistory(sessionId: String) async -> [HistoryMessage] { [] }

    // MARK: - Models

    func currentInfo() async -> AgentInfo? {
        // provider は listAvailableModels の ProviderCatalog.id ("buddy") と一致させる。
        AgentInfo(model: resolveModel(), provider: "buddy")
    }

    func listAvailableModels() async -> [ProviderCatalog] {
        let models = [
            ModelCatalogItem(id: "google/gemini-2.0-flash-001", label: "Gemini 2.0 Flash", subtitle: "最速・最安（既定）"),
            ModelCatalogItem(id: "google/gemini-flash-1.5", label: "Gemini 1.5 Flash", subtitle: "軽量"),
            ModelCatalogItem(id: "anthropic/claude-3.5-haiku", label: "Claude 3.5 Haiku", subtitle: "ツール呼び出しが安定"),
            ModelCatalogItem(id: "z-ai/glm-4.7", label: "GLM-4.7", subtitle: "Hermes と統一")
        ]
        return [ProviderCatalog(id: "buddy", label: "Buddy", models: models)]
    }

    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?) async throws {
        let m = model.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else {
            throw NSError(domain: "BuddyAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "モデルが空です"])
        }
        var root: [String: Any] = {
            guard let data = FileManager.default.contents(atPath: configPath),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }()
        root["model"] = m
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
    }

    // MARK: - Resolution

    private func resolveModel() -> String {
        if let env = ProcessInfo.processInfo.environment["BUDDY_MODEL"], !env.isEmpty { return env }
        if let data = FileManager.default.contents(atPath: configPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = obj["model"] as? String, !m.isEmpty {
            return m
        }
        return Self.defaultModel
    }

    /// マネージドプランの OpenRouter キーを流用する。env override → ~/.hermes/.env の順。
    static func resolveApiKey() -> String {
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !env.isEmpty { return env }
        let envPath = NSHomeDirectory() + "/.hermes/.env"
        guard let raw = try? String(contentsOfFile: envPath, encoding: .utf8) else { return "" }
        for line in raw.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("OPENROUTER_API_KEY=") else { continue }
            var value = String(s.dropFirst("OPENROUTER_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return ""
    }

    /// buddy が「設定済み」か（= OpenRouter キーがあるか）。AgentProbe から使う。
    static func isConfigured() -> Bool {
        !resolveApiKey().isEmpty
    }
}

/// buddy の会話履歴（OpenRouter 形式の messages）を `~/.buddyos/buddy-sessions/<sessionId>.json` に永続化する。
/// SessionHub は購読者が居なくなると session を close するため、WS 再接続や Bridge 再起動のたびに
/// 新しい BuddySession が作られる。ここから読み戻して文脈を引き継ぐ。
/// - system prompt は保存しない（復元時は常に最新の systemPrompt を先頭に置く）。
/// - MCP ツール出力を含み得るので dir 0700 / file 0600、書き込みは atomic。
/// - tool_calls と tool 応答の対応が崩れた組は捨てる（崩れたまま送ると OpenRouter が 400 を返す）。
/// - 「このセッションでは承認」は永続化しない（再接続後は default-deny に戻す）。
/// - 削除 API が無く iOS 側も一覧を持たないため、save のたびに古いファイルを掃除する（prune）。
enum BuddyHistoryStore {
    /// 保存する最大メッセージ数と合計サイズ。超えたら古い方からターン単位で切り詰める。
    private static let maxMessages = 120
    private static let maxBytes = 400_000
    /// 1 メッセージの content 上限（大きな MCP ツール出力で肥大化させない）。
    private static let maxContentChars = 16_000
    /// 履歴ファイルの保持期間（最終更新から）と保持件数（新しい順）。超えた分は削除する。
    private static let retention: TimeInterval = 30 * 24 * 60 * 60
    private static let maxFiles = 200

    private static let directory = NSHomeDirectory() + "/.buddyos/buddy-sessions"

    /// sessionId はクライアント由来なので UUID に限定し、正規形をファイル名にする（パス・トラバーサル防止）。
    private static func fileURL(sessionId: String) -> URL? {
        guard let uuid = UUID(uuidString: sessionId) else { return nil }
        return URL(fileURLWithPath: directory).appendingPathComponent(uuid.uuidString + ".json")
    }

    /// 保存済みの履歴（system を除く）。無い・壊れている場合は空。
    static func load(sessionId: String) -> [[String: Any]] {
        guard let url = fileURL(sessionId: sessionId),
              let data = try? Data(contentsOf: url),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return sanitize(arr)
    }

    /// ターン完了時（done の直前）に呼ぶ。messages は lock 下で取ったスナップショットを渡すこと。
    static func save(_ messages: [[String: Any]], sessionId: String) {
        guard let url = fileURL(sessionId: sessionId) else { return }
        var msgs = sanitize(messages).map(capContent)
        var sizes = msgs.map { (try? JSONSerialization.data(withJSONObject: $0).count) ?? 0 }
        var total = sizes.reduce(0, +)
        // 上限超過分は古い方から次の user 境界まで落とす（tool_calls と tool 応答の組を割らない）。最後のターンは残す。
        while msgs.count > maxMessages || total > maxBytes {
            guard let next = msgs.dropFirst().firstIndex(where: { ($0["role"] as? String) == "user" }) else { break }
            total -= sizes[..<next].reduce(0, +)
            msgs.removeFirst(next)
            sizes.removeFirst(next)
        }
        guard !msgs.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: msgs) else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            prune(keeping: url)
        } catch {
            // 保存失敗で会話は止めない（次のターン完了時に再度書く）。
        }
    }

    /// 最終更新が retention より古いファイルと、新しい順で maxFiles 件を超えた分を消す。
    /// 対象は `<UUID>.json` だけ（atomic 書き込みの一時ファイル等には触れない）。今保存したファイルは残す。
    private static func prune(keeping current: URL) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: directory),
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        let files = urls
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != current.lastPathComponent
                && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        let cutoff = Date().addingTimeInterval(-retention)
        // current が 1 件分を使うので、他のファイルは maxFiles - 1 件まで残す。
        for (i, (url, modified)) in files.enumerated() where i >= maxFiles - 1 || modified < cutoff {
            try? fm.removeItem(at: url)
        }
    }

    /// system・不明な role・対応の崩れた tool_calls 組を除き、user から始まる列に整える。
    /// interrupt / close で途中終了したターンは tool 応答が欠けたまま残るので、ここで落とす。
    private static func sanitize(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var i = 0
        while i < messages.count {
            let m = messages[i]
            let role = m["role"] as? String
            i += 1
            guard JSONSerialization.isValidJSONObject(m) else { continue }
            if role == "assistant", let calls = m["tool_calls"] as? [[String: Any]], !calls.isEmpty {
                // 直後に続く tool 応答を集め、全 tool_call_id が揃っている組だけ残す。
                let ids = calls.compactMap { $0["id"] as? String }
                var replies: [String: [String: Any]] = [:]
                while i < messages.count, (messages[i]["role"] as? String) == "tool" {
                    let reply = messages[i]
                    if let id = reply["tool_call_id"] as? String, ids.contains(id), replies[id] == nil,
                       JSONSerialization.isValidJSONObject(reply) {
                        replies[id] = reply
                    }
                    i += 1
                }
                guard ids.count == calls.count, Set(ids).count == ids.count,
                      ids.allSatisfy({ replies[$0] != nil }) else { continue }
                out.append(m)
                out.append(contentsOf: ids.compactMap { replies[$0] })
            } else if role == "user" || role == "assistant" {
                out.append(m)
            }
            // system / 親を失った tool / 不明な role は捨てる。
        }
        guard let first = out.firstIndex(where: { ($0["role"] as? String) == "user" }) else { return [] }
        return Array(out[first...])
    }

    private static func capContent(_ m: [String: Any]) -> [String: Any] {
        guard let c = m["content"] as? String, c.count > maxContentChars else { return m }
        var out = m
        out["content"] = String(c.prefix(maxContentChars)) + "\n…（長いため以降を省略）"
        return out
    }
}
