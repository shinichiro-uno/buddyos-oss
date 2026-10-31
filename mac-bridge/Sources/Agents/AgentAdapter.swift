import Foundation

protocol AgentAdapter: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: AgentCapabilities { get }

    /// sessionId が nil なら新規セッションを採番（adapter 側で確定して sessionStarted を送る責務）。
    func openSession(sessionId: String?, cwd: String?) async -> AgentSession

    /// オプション付きセッション開始。cron 等の無人実行がパーミッションモードを
    /// per-run で上書きするために使う。非対応 adapter は options を無視してよい。
    func openSession(sessionId: String?, cwd: String?, options: SessionOptions?) async -> AgentSession

    /// 過去 session の一覧。新しい順、最大 `limit` 件。
    func listSessions(limit: Int, cwd: String?) async -> [SessionSummary]

    /// 指定 session の全メッセージを時系列順に返す。
    func loadHistory(sessionId: String) async -> [HistoryMessage]

    /// 登録済み cron job 一覧。
    func listCronJobs() async -> [CronJobSummary]

    /// cron job 作成。成功時は job id、失敗時は throw。
    func createCronJob(spec: CronCreateSpec) async throws -> String

    /// cron job 削除。
    func deleteCronJob(jobId: String) async throws

    /// cron job 一時停止 / 再開。
    func pauseCronJob(jobId: String) async throws
    func resumeCronJob(jobId: String) async throws

    /// `/` パレットに出す skill / command 一覧。
    func listCommands() async -> [CommandInfo]

    /// 現在使用中のモデル/プロバイダ。chat header 左に表示する。
    /// 取れない adapter は nil を返してよい。
    func currentInfo() async -> AgentInfo?

    /// モデル/プロバイダを切り替える。non-supporting adapter は throw。
    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?) async throws

    /// この agent で選択可能なプロバイダ + モデル一覧。設定ファイルから読む実装が標準。
    /// 何も返せない adapter は [] を返す。
    func listAvailableModels() async -> [ProviderCatalog]

    // ── 接続セッション付きの問い合わせ ───────────────────────────────────
    // opencode のように「現在のチャットの live ACP セッション」から model/mode/
    // commands を読む adapter は、シングルトン adapter 上の共有スロットではなく
    // 問い合わせ元コネクションの session を使う必要がある（共有スロットは別接続の
    // openSession で上書き → その session が解放されると nil になり、モデル一覧が
    // 取れなくなる）。session を使わない adapter (claude/codex/hermes/openclaw) は
    // default 実装が session を無視して既存の引数なし版に委譲するため影響なし。
    func currentInfo(session: AgentSession?) async -> AgentInfo?
    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?, session: AgentSession?) async throws
    func listAvailableModels(session: AgentSession?) async -> [ProviderCatalog]
    func listCommands(session: AgentSession?) async -> [CommandInfo]
}

extension AgentAdapter {
    // Echo など 非対応 adapter のためのデフォルト
    func openSession(sessionId: String?) async -> AgentSession {
        await openSession(sessionId: sessionId, cwd: nil)
    }
    func openSession(sessionId: String?, cwd: String?, options: SessionOptions?) async -> AgentSession {
        await openSession(sessionId: sessionId, cwd: cwd)
    }
    func listSessions(limit: Int) async -> [SessionSummary] {
        await listSessions(limit: limit, cwd: nil)
    }
    func listCommands() async -> [CommandInfo] { [] }
    func listCronJobs() async -> [CronJobSummary] { [] }
    func createCronJob(spec: CronCreateSpec) async throws -> String {
        throw NSError(domain: "AgentAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "cron not supported"])
    }
    func deleteCronJob(jobId: String) async throws {
        throw NSError(domain: "AgentAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "cron not supported"])
    }
    func pauseCronJob(jobId: String) async throws {
        throw NSError(domain: "AgentAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "cron not supported"])
    }
    func resumeCronJob(jobId: String) async throws {
        throw NSError(domain: "AgentAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "cron not supported"])
    }
    func currentInfo() async -> AgentInfo? { nil }
    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?) async throws {
        throw NSError(domain: "AgentAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "set model not supported"])
    }
    func listAvailableModels() async -> [ProviderCatalog] { [] }

    // session を使わない adapter 向けの default: 既存の引数なし版へ委譲する。
    func currentInfo(session: AgentSession?) async -> AgentInfo? { await currentInfo() }
    func setModel(model: String, provider: String?, reasoningEffort: String?, codexMode: String?, session: AgentSession?) async throws {
        try await setModel(model: model, provider: provider, reasoningEffort: reasoningEffort, codexMode: codexMode)
    }
    func listAvailableModels(session: AgentSession?) async -> [ProviderCatalog] { await listAvailableModels() }
    func listCommands(session: AgentSession?) async -> [CommandInfo] { await listCommands() }

    var capabilities: AgentCapabilities {
        AgentCapabilities()
    }
}

/// 定期実行を Bridge 内蔵スケジューラ (BridgeCronScheduler) で動かす adapter。
/// 適合するだけで cron 一式が付き、作業フォルダと権限モードを job ごとに指定できる
/// （AgentRegistry が capabilities.cron / cronOptions を立てる）。CLI 自身の cron を使う
/// hermes / openclaw は適合しない。
protocol BridgeCronHosted: AgentAdapter {}

extension BridgeCronHosted {
    func listCronJobs() async -> [CronJobSummary] {
        await BridgeCronScheduler.shared.list(agentId: id)
    }
    func createCronJob(spec: CronCreateSpec) async throws -> String {
        try await BridgeCronScheduler.shared.create(agentId: id, spec: spec)
    }
    func deleteCronJob(jobId: String) async throws {
        try await BridgeCronScheduler.shared.delete(agentId: id, jobId: jobId)
    }
    func pauseCronJob(jobId: String) async throws {
        try await BridgeCronScheduler.shared.pause(agentId: id, jobId: jobId)
    }
    func resumeCronJob(jobId: String) async throws {
        try await BridgeCronScheduler.shared.resume(agentId: id, jobId: jobId)
    }
}

/// クライアント（iPhone / デスクトップ）が UI の出し分けに使う能力。agent id で分岐させず、
/// ここに載っているかどうかだけで表示を決める。新しい項目は既定値つきで末尾に足す
/// （古いクライアントは知らない項目を無視し、新しいクライアントは欠けた項目を旧既定で補う）。
struct AgentCapabilities: Codable, Sendable {
    var chat: Bool = true
    var history: Bool = true
    var projects: Bool = true
    var commands: Bool = false
    var models: Bool = false
    var cron: Bool = false
    var skills: Bool = false
    var mcp: Bool = false
    var attachments: Bool = true
    var actions: Bool = false
    /// true なら生成中の送信を実行中ターンへ「フォローアップ」として注入できる
    /// （常駐プロセスの Claude Code など）。false のクライアントは送信予約(queue-as-new-turn)へフォールバック。
    var injectMidTurn: Bool = false
    /// 選べる effort。空 = effort を持たない。モデルで対応値が変わる agent（Codex）は
    /// agent_info の supportedReasoningEfforts がこれより優先される。
    var efforts: [String] = []
    /// 選べる権限モード（BuddyOS の語彙: plan / edit / auto / dangerous / build）。空 = 持たない。
    var modes: [String] = []
    /// 定期実行で作業フォルダと権限モードを job ごとに指定できる（BridgeCronHosted）。
    var cronOptions: Bool = false
    /// iPhone からログインできる（AgentLoginService に手順がある）。
    var login: Bool = false
    /// 上限に対する使用率を読める（UsageReader が読む）。
    var usage: Bool = false
    /// ターミナルで開いた会話を iPhone から見る・送れる。
    var terminal: Bool = false
    /// MCP サーバをこの agent の設定へ追加・削除できる。
    var mcpRegister: Bool = false
    /// 生成中のターンを止められる（session の interrupt() が実装されている）。古いクライアントは無ければ true とみなす。
    var interrupt: Bool = true
    /// チャットを開いたときに session_warm を受けて、送る前に裏の CLI を起こしておける（session の warm() がある）。
    /// 無ければアプリは送らない（古い Bridge は知らない種別に unsupported を返し、iPhone に吹き出しが出るため）。
    var warm: Bool = false
    /// mainagent（窓口）になれる。`~/.buddyos/main/` で開くと Bridge の MCP（ほかのセッションを操作する道具）が渡る。
    var orchestrate: Bool = false
    /// 公開したサイトの一覧（sites_request）に答えられる。agent ではなく Bridge の機能なので、どの agent でも true。
    var sites: Bool = true
    /// メインの定期チェック（heartbeat_get / heartbeat_set / heartbeat_run_now）に答えられる。Bridge の機能なので、どの agent でも true。
    var heartbeat: Bool = true
    /// claude --bg のセッションの一覧・停止・削除に答えられる（claude だけ true になりうる）。
    var bgSessions: Bool = false
}

struct AgentDescriptor: Codable, Sendable {
    let id: String
    let displayName: String
    let capabilities: AgentCapabilities
    // /health で probe 結果を載せる（iOS が「Mac に実際入って設定済みか」を判定して
    // 未設定エージェントをグレーアウト/開けない表示にするため）。古いクライアント互換で optional。
    var installed: Bool? = nil
    var configured: Bool? = nil
    var version: String? = nil
}

struct AgentInfo: Sendable {
    let model: String?
    let provider: String?
    let supportedReasoningEfforts: [String]?
    let reasoningEffort: String?
    let codexMode: String?
    let approvalPolicy: String?
    let sandboxMode: String?

    init(
        model: String?,
        provider: String?,
        supportedReasoningEfforts: [String]? = nil,
        reasoningEffort: String? = nil,
        codexMode: String? = nil,
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil
    ) {
        self.model = model
        self.provider = provider
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.reasoningEffort = reasoningEffort
        self.codexMode = codexMode
        self.approvalPolicy = approvalPolicy
        self.sandboxMode = sandboxMode
    }
}

struct CronCreateSpec: Sendable {
    let name: String?
    let schedule: String     // "30m" / "0 9 * * *" / "every 2h"
    let prompt: String
    let deliver: String?     // nil → デフォルト ("local")
    let repeatCount: Int?
    /// Bridge 内蔵 cron (claude/codex) 用。hermes / openclaw の native cron は無視する。
    var cwd: String? = nil
    /// BuddyOS モードラベル ("plan"/"edit"/"auto"/"dangerous")。nil = グローバル設定に従う。
    var permissionMode: String? = nil
}

/// セッション開始時の per-run オプション (現状は無人実行のパーミッション上書きのみ)。
struct SessionOptions: Sendable {
    var permissionMode: String?
    /// 無人実行（cron）か。permissionMode が nil（グローバル設定に従う）でも、答えられない
    /// 承認で止まらないよう adapter が承認をその場で断る（Codex は承認を never に固定、Claude CLI は
    /// iPhone に尋ねない、ACP / OpenCode は拒否で即答）。取りこぼした承認は
    /// BridgeCronScheduler が断る。
    var unattended: Bool = false
    /// メインの定期チェック（MainHeartbeat）の会話か。無人（unattended）でも、mainagent のフォルダなら
    /// Bridge の MCP（mainagent の道具）を渡す印。cron には付けない。
    var heartbeat: Bool = false
}

protocol AgentSession: AnyObject {
    var sessionId: String { get }
    var events: AsyncThrowingStream<SessionEvent, Error> { get }
    /// true なら、生成中に届いた send をそのまま実行中ターンへフォローアップ注入できる
    /// （常駐プロセスの Claude Code セッション）。false の adapter は1ターン1プロセス。
    var supportsMidTurnInjection: Bool { get }

    /// `skills` は Hermes の `--skills` に渡される skill 名の配列 (空可)。
    /// `attachments` は画像 / テキストファイル添付 (空可)。adapter 側で利用方法を決める。
    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async
    func respondToAction(requestId: String, decision: String, answers: [String: String]) async
    /// 進行中の応答（turn）を中断する。対応しない実装は default の no-op のまま。
    func interrupt() async
    /// 送る前に裏の CLI を起こしておく（チャットを開いたとき）。対応しない実装は default の no-op。
    func warm() async
    /// サブエージェントのカードの全行（workflow_progress の JSON。subtype "workflow_snapshot"、kind "subagents"、epoch 付き）。
    /// トラッカーを持たない実装は nil。行が無くてもトラッカーがあれば agents: [] で返す。
    /// SessionHub が接続したとき（acquire）と turn_status_request のときに、ターンの状態に関係なく送る
    /// （docs/BACKGROUND_WORK_2026-10-21.md §3.5）。
    func subagentSnapshot() async -> String?
    /// 行（カード）ごとの停止（stop_task_request）。持たない実装は extension の既定（unsupported）。
    func stopTask(_ request: StopTaskRequest) async -> StopTaskOutcome
    func close() async
}

extension AgentSession {
    /// 既存呼出元との互換のため。attachments なし呼出を維持する場合の default。
    func send(_ text: String, skills: [String]) async {
        await send(text, skills: skills, attachments: [])
    }

    func respondToAction(requestId: String, decision: String, answers: [String: String]) async {}

    func interrupt() async {}

    func warm() async {}

    func subagentSnapshot() async -> String? { nil }

    func stopTask(_ request: StopTaskRequest) async -> StopTaskOutcome { .unsupported(nil) }

    var supportsMidTurnInjection: Bool { false }
}

/// stop_task_request の中身（docs/BACKGROUND_CONTROL_2026-10-21.md §3.3）。
/// taskId が "subagents" なら rowId と epoch で行を指す。dynamic workflow のカード全体は taskId がカードの taskId。
struct StopTaskRequest: Equatable, Sendable {
    var taskId: String
    var rowId: String?
    var epoch: String?
}

/// stop_task_result の reason・ok・message に対応する結果。
enum StopTaskOutcome: Equatable, Sendable {
    case stopped
    case notRunning
    case stale
    case unsupported(String?)
    case failed(String?)
    case timeout

    var reason: String {
        switch self {
        case .stopped: return "stopped"
        case .notRunning: return "not_running"
        case .stale: return "stale"
        case .unsupported: return "unsupported"
        case .failed: return "failed"
        case .timeout: return "timeout"
        }
    }

    var ok: Bool {
        switch self {
        case .stopped, .notRunning, .stale: return true
        case .unsupported, .failed, .timeout: return false
        }
    }

    var message: String? {
        switch self {
        case .unsupported(let m), .failed(let m): return m
        default: return nil
        }
    }
}

/// iOS から WS metadata に inline されてくる添付ファイルを Bridge 内部表現に変換したもの。
struct BridgeAttachment: Sendable {
    enum Kind: String, Sendable {
        case image
        case file
    }
    let kind: Kind
    let name: String
    let mime: String
    let data: Data
}

/// チャット単位のモデル / Effort / 権限モードの上書き。
/// iOS が user_message の metadata（chatModel / chatProvider / chatEffort / chatMode）に毎回載せて送る。
/// nil の項目はエージェントの既定（`setModel` で保存されたグローバル設定）に従う。
/// 上書きはそのチャットのプロセスにだけ効き、他のチャットや CLI 本体の設定には書き込まない。
struct SessionOverrides: Equatable, Sendable {
    var model: String?
    var provider: String?
    var reasoningEffort: String?
    var mode: String?

    static let none = SessionOverrides()

    init(model: String? = nil, provider: String? = nil, reasoningEffort: String? = nil, mode: String? = nil) {
        self.model = model
        self.provider = provider
        self.reasoningEffort = reasoningEffort
        self.mode = mode
    }

    /// metadata から読む。`chatOverrides=1` の印が無い送信（古いアプリ・デスクトップ等）は nil を返し、
    /// セッションの上書きを触らない。印があって項目が無ければ全項目 nil = 既定に戻す。
    init?(metadata: [String: String]?) {
        guard metadata?["chatOverrides"] == "1" else { return nil }
        func value(_ key: String) -> String? {
            guard let v = metadata?[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        self.init(model: value("chatModel"), provider: value("chatProvider"),
                  reasoningEffort: value("chatEffort"), mode: value("chatMode")?.lowercased())
    }
}

/// チャット単位の上書きを受け付けるセッション。WebSocketServer が送信の直前に呼ぶ。
/// 反映のタイミング（次の spawn / 次のターン）は実装に任せる。
protocol SessionOverridable: AnyObject {
    func applyOverrides(_ overrides: SessionOverrides)
}
