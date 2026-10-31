import Foundation

/// 開発用のスタブ。受け取ったテキストを assistantDelta で逆順に返してから done。
/// Hermes 認証が通っていない段階でも iOS のラウンドトリップを検証できる。
/// MVP では履歴永続化なし。
final class EchoAdapter: AgentAdapter {
    let id = "echo"
    let displayName = "Echo"
    // Echo は history を空配列で返し、cwd(projects) を無視するため両方 false を明示する。
    let capabilities = AgentCapabilities(
        chat: true,
        history: false,
        projects: false,
        commands: false,
        models: false,
        cron: false,
        skills: false,
        mcp: false,
        attachments: true,
        actions: false,
        // EchoSession は interrupt() を持たない。
        interrupt: false
    )

    func openSession(sessionId: String?, cwd: String?) async -> AgentSession {
        EchoSession(sessionId: sessionId ?? UUID().uuidString)
    }

    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary] { [] }
    func loadHistory(sessionId: String) async -> [HistoryMessage] { [] }
}

final class EchoSession: AgentSession {
    let sessionId: String
    let events: AsyncThrowingStream<SessionEvent, Error>
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation

    init(sessionId: String) {
        self.sessionId = sessionId
        var cont: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { c in cont = c }
        self.continuation = cont
    }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        let messageId = UUID().uuidString
        let prefix = skills.isEmpty ? "" : "[skills:\(skills.joined(separator: ","))] "
        let attachNote = attachments.isEmpty ? "" : "[attachments:\(attachments.count)] "
        let reply = "echo: \(prefix)\(attachNote)\(text)"
        for ch in reply {
            continuation.yield(.assistantDelta(String(ch), agentId: "echo", sessionId: sessionId, messageId: messageId))
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        continuation.yield(.done(agentId: "echo", sessionId: sessionId, messageId: messageId))
    }

    func close() async {
        continuation.finish()
    }
}
