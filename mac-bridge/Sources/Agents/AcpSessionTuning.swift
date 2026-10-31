import Foundation

/// AcpSession の agent ごとの違い。既定値は hermes / openclaw の従来の挙動
/// （どの adapter も、違うところだけを書き換えて渡す）。
struct AcpSessionTuning: Sendable {
    /// session/new の応答のあと、最初の prompt まで待つ時間。OpenClaw は内部の初期化が
    /// 終わる前の prompt を取りこぼすので 2 秒待つ。待つ必要のない agent は 0。
    var postSessionDelayNanos: UInt64 = 2_000_000_000
    /// env を渡すとき `zsh -lic` を経由するか（AcpClient）。PATH を env で渡せるなら false で速く起動できる。
    var loginShell: Bool = true
    /// BuddyOS のモード → ACP の mode 設定（configOptions）の値。"*" はそれ以外のモード。nil = 使わない。
    /// 例: cursor は plan → "plan"、それ以外 → "agent"。
    var modeConfigValues: [String: String]? = nil
    /// BuddyOS のモード → prompt の頭に付ける文字。例: grok の plan は `/plan `（設定項目に plan が無いため）。
    var modePromptPrefix: [String: String] = [:]
    /// ACP の image block を受けない agent（grok）は、画像をファイルに書き出してパスを渡す。
    var imagesAsFiles: Bool = false
    /// エージェント既定（新しいチャットの初期値）。チャットの上書きが無い項目に使う。
    var defaults: SessionOverrides = .none
    /// 無人実行（cron）。答えられない承認要求は拒否で返す。
    var unattended: Bool = false
    /// 無人実行の権限モード（cron の job ごとの指定）。チャットの上書きより弱く、既定より強い。
    var permissionMode: String? = nil
    /// 開いたらすぐ会話を読み込んで購読する（ターミナルで開いている会話を、送る前から iPhone に流すため）。
    var subscribeOnOpen: Bool = false
    /// 同じ会話を共有する別の画面（ターミナル）が始めたターンも流す。grok の leader で使う
    /// （`_x.ai/queue/changed` の runningText をユーザーの発言に、`turn_completed` を完了にする）。
    var remoteTurns: Bool = false
    /// `_x.ai/session_notification`（subagent_spawned / progress / finished / turn_completed）と、親が自分から
    /// 始める知らせのターン（`_x.ai/queue/changed` の subagent-completed- / task-completed-）を扱う。grok だけ。
    var xaiNotifications: Bool = false
    /// status の無い tool_call_update を tool の終わりとみなすか。grok は子が始まる前に status の無い更新を流すので false。
    var statuslessUpdateEndsTool: Bool = true
    /// 非同期の委任の本当の終わりを知る台帳（受領票の読み取りと見張り）。grok は台帳ではなく通知で知るので .none。
    var delegationLedger: DelegationLedgerKind = .none
    /// 台帳のファイル（テスト用の差し替え）。nil なら Hermes は ~/.hermes/state.db、OpenClaw は
    /// ${OPENCLAW_STATE_DIR:-~/.openclaw}/state/openclaw.sqlite。
    var delegationLedgerPath: String? = nil
    /// 台帳を読む間隔（秒。テスト用の差し替え）。nil なら Hermes 2 秒、OpenClaw 3 秒（CLI 経由は 10 秒）。
    var delegationPollSeconds: Double? = nil
    /// 台帳の読み取りが何回続けて失敗したら、読めないとみなすか。
    var delegationFailureLimit: Int = 30
    /// OpenClaw の DB が読めないときの代わり。`openclaw tasks show <runId> --json` の標準出力を返す（失敗は nil）。
    var delegationCli: (@Sendable (_ runId: String) -> String?)? = nil
    /// user / assistant の本文の記録先（BuddyOS の履歴に残す adapter が渡す）。sessionId は確定後の値。
    var recorder: (@Sendable (_ role: String, _ content: String, _ messageId: String, _ sessionId: String) async -> Void)? = nil
}
