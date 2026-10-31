import Foundation
import Security

/// mainagent（窓口のエージェント）の作業フォルダ `~/.buddyos/main/`。
///
/// このフォルダで開いた Claude Code のセッションだけに、Bridge の MCP（`POST /mcp`、Orchestrator）を差し込み、
/// 自分ではコードを書かせない。役割とスキルはフォルダに置いたファイルで渡す（CLAUDE.md / AGENTS.md /
/// `.claude/skills/`）。iPhone とデスクトップは、共有のプロジェクト一覧に出る「メイン」で開くだけでよい。
/// ほかのフォルダのセッションにも、設定 allSessions が有効なら MCP だけを渡す（書く道具は外さない。
/// `claudeDelegateArgs` などの delegate 版）。
enum MainAgentWorkspace {
    static let projectName = "メイン"
    /// Claude に渡す MCP サーバの名前。道具は `mcp__buddyos__<tool>` で見える。
    static let mcpServerName = "buddyos"

    /// テスト用の差し替え（本物の ~/.buddyos/main を作らずに mainagent を起こす）。
    nonisolated(unsafe) static var rootOverride: URL?

    static var defaultURL: URL {
        rootOverride ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".buddyos")
            .appendingPathComponent("main")
    }

    /// このフォルダか（パスを標準化して比べる。シンボリックリンクも解く）。
    static func isMainWorkspace(_ cwd: String?, root: URL = defaultURL) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        return canonical(cwd) == canonical(root.path)
    }

    private static func canonical(_ path: String) -> String {
        let p = ProjectRegistry.normalize(path)
        return ProjectRegistry.normalize(URL(fileURLWithPath: p).resolvingSymlinksInPath().path)
    }

    /// フォルダとファイルを用意する。Bridge の決まりは「Bridge が書き換える範囲」（managedBegin〜managedEnd）に入れ、
    /// 起動のたびにその範囲だけを今の版へ書き直す（ユーザーが範囲の外に足した文は残す）。
    /// 範囲の印が無いファイルは、前の版の Bridge が書いたまま（手を入れていない）なら今の版に置き換え、
    /// 手で書き換えたものは触らない。
    /// 「メイン」はプロジェクト一覧から消せない。一覧に無ければ（古い版で消した・projects.json を手で直した）足し直す。
    static func ensure(root: URL = defaultURL, projectsURL: URL = ProjectRegistry.fileURL) {
        let fm = FileManager.default
        for file in files {
            let url = root.appendingPathComponent(file.path)
            let current = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
            if current == nil, fm.fileExists(atPath: url.path) { continue }   // 読めない（文字コードが違う等）なら触らない
            guard let next = updatedContent(current, file: file), next != current else { continue }
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(next.utf8).write(to: url, options: [.atomic])
        }
        // 定期チェックで見ること・メインのメモ。無いときだけ作る（あとは利用者のもの。書き換えない）。
        // ただし前の版のまま手を入れていなければ、今の版に置き換える。
        for file in userFiles {
            let url = root.appendingPathComponent(file.path)
            if file.path == heartbeatFileName,
               let current = (try? Data(contentsOf: url)).flatMap({ String(data: $0, encoding: .utf8) }),
               legacyHeartbeatInitials.contains(current) {
                try? Data(file.body.utf8).write(to: url, options: [.atomic])
                continue
            }
            guard !fm.fileExists(atPath: url.path) else { continue }
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            try? Data(file.body.utf8).write(to: url, options: [.withoutOverwriting])
        }
        if !ProjectRegistry.list(at: projectsURL).contains(where: { isMainWorkspace($0.path, root: root) }) {
            ProjectRegistry.add(path: root.path, name: projectName, at: projectsURL)
        }
    }

    // MARK: - Bridge が書き換える範囲

    /// Bridge が置くファイル 1 つ。frontmatter（スキルの `---` で囲んだ頭）は範囲の前に置き、範囲と一緒に書き換える
    /// （Claude Code は frontmatter がファイルの先頭にあるときだけ読む）。
    struct ManagedFile {
        let path: String
        let frontmatter: String?
        let body: String
        /// 前の版の Bridge が範囲の印なしで書いた中身。これと同じならユーザーは手を入れていない。
        let legacy: [String]
    }

    static let managedVersion = 3
    static let managedBegin = "<!-- buddyos:managed:begin"
    static let managedEnd = "<!-- buddyos:managed:end -->"

    static func rendered(_ file: ManagedFile) -> String {
        var out = ""
        if let fm = file.frontmatter { out += fm + "\n\n" }
        out += "\(managedBegin) v\(managedVersion) — この印の間は BuddyOS の Bridge が起動のたびに書き直します。足したい決まりは印の外に書いてください -->\n"
        out += file.body
        if !file.body.hasSuffix("\n") { out += "\n" }
        out += managedEnd + "\n"
        return out
    }

    /// 今のファイルの中身から、書くべき中身を作る。nil なら触らない。
    static func updatedContent(_ current: String?, file: ManagedFile) -> String? {
        let fresh = rendered(file)
        guard let current else { return fresh }
        if let begin = current.range(of: managedBegin),
           let end = current.range(of: managedEnd, range: begin.upperBound..<current.endIndex) {
            // 範囲の後ろ（ユーザーが足した文）は残す。改行 1 つは範囲の一部として扱う。
            var after = current[end.upperBound...]
            if after.hasPrefix("\n") { after = after.dropFirst() }
            if file.frontmatter != nil {
                // スキル: 頭から範囲の終わりまでが Bridge のもの（frontmatter を含む）。
                return fresh + after
            }
            // CLAUDE.md / AGENTS.md: 範囲の前（ユーザーが頭に足した文）も残す。
            let before = current[..<begin.lowerBound]
            return String(before) + fresh + after
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if file.legacy.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }) {
            return fresh
        }
        return nil
    }

    // MARK: - エージェントへの渡し方

    /// 道具の名前（McpEndpoint.tools と同じ）。承認は Bridge が出すので、エージェント側では尋ねさせない。
    static let toolNames = ["list_projects", "list_agents", "list_sessions", "start_session", "send_message", "get_reply",
                            "answer_approval", "list_pcs", "save_note"]
    /// mainagent（と定期チェック）に尋ねずに使わせる、読むだけの道具（claude.ai の Gmail / Google ドライブのコネクタ）。
    /// 定期チェックで「返事をしていないメール・進んでいない文書」を知らせるため。つないでいなければ無いだけ。
    /// 送る・消す・書き換える道具は入れない（使おうとすればふつうに承認を尋ねる）。
    static let readOnlyConnectorTools = [
        "mcp__claude_ai_Gmail__search_threads", "mcp__claude_ai_Gmail__get_thread", "mcp__claude_ai_Gmail__get_message",
        "mcp__claude_ai_Gmail__list_labels", "mcp__claude_ai_Gmail__list_drafts", "mcp__claude_ai_Gmail__get_draft",
        "mcp__claude_ai_Google_Drive__search_files", "mcp__claude_ai_Google_Drive__list_recent_files",
        "mcp__claude_ai_Google_Drive__get_file_metadata", "mcp__claude_ai_Google_Drive__read_file_content"
    ]
    /// mainagent に使わせない道具（コードを書かない・コマンドを打たない）。
    static let deniedTools = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Bash"]
    /// 合鍵を渡す環境変数（Claude CLI）。引数に載せると ps で見えるので、ヘッダは ${…} で展開させる。
    static let tokenEnvVar = "BUDDYOS_MCP_TOKEN"
    /// 道具の呼び出しを待つ上限（承認 5 分 + 返事 5 分を待てる長さ）。Codex の既定は 60 秒で足りない。
    static let toolTimeoutSeconds = 900

    static func mcpURL(port: Int) -> String { "http://127.0.0.1:\(port)/mcp" }
    static var currentPort: Int { KeyStore.currentPort ?? 8765 }

    /// Claude CLI（ClaudeCodeSession）に足す引数。権限モードは default に固定する（書く道具は外してある）。
    static func claudeArgs(port: Int) -> [String] {
        let config: [String: Any] = [
            "mcpServers": [
                mcpServerName: [
                    "type": "http",
                    "url": mcpURL(port: port),
                    "headers": ["Authorization": "Bearer ${\(tokenEnvVar)}"]
                ]
            ]
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return [
            "--mcp-config", json,
            "--allowedTools", (buddyosToolIds + readOnlyConnectorTools).joined(separator: ","),
            "--disallowedTools", deniedTools.joined(separator: ","),
            "--permission-mode", "default"
        ]
    }

    private static var buddyosToolIds: [String] { toolNames.map { "mcp__\(mcpServerName)__\($0)" } }

    /// ふつうのセッション（mainagent のフォルダ以外）の Claude CLI に足す引数。
    /// MCP と、buddyos の道具を尋ねさせない指定だけ。書く道具は外さず、権限モードもそのセッションの設定のまま
    /// （Gmail / ドライブの読む道具は mainagent だけ）。
    static func claudeDelegateArgs(port: Int) -> [String] {
        let args = claudeArgs(port: port)
        guard let i = args.firstIndex(of: "--mcp-config") else { return [] }
        return [args[i], args[i + 1], "--allowedTools", buddyosToolIds.joined(separator: ",")]
    }

    /// Codex app-server の thread/start・resume の `config`（-c と同じ点区切りのキー）。
    static func codexConfig(token: String, port: Int) -> [String: Any] {
        let key = "mcp_servers.\(mcpServerName)"
        return [
            "\(key).url": mcpURL(port: port),
            "\(key).http_headers": ["Authorization": "Bearer \(token)"],
            "\(key).tool_timeout_sec": toolTimeoutSeconds,
            "\(key).default_tools_approval_mode": "approve"
        ]
    }

    /// `codex exec` に足す -c（TOML の値）。合鍵は引数に載せず、環境変数 `tokenEnvVar` を codex に読ませる。
    static func codexExecArgs(port: Int) -> [String] {
        let key = "mcp_servers.\(mcpServerName)"
        return [
            "-c", "\(key).url=\"\(mcpURL(port: port))\"",
            "-c", "\(key).bearer_token_env_var=\"\(tokenEnvVar)\"",
            "-c", "\(key).tool_timeout_sec=\(toolTimeoutSeconds)",
            "-c", "\(key).default_tools_approval_mode=\"approve\"",
            "-c", "sandbox_mode=\"read-only\"",
            "-c", "approval_policy=\"never\""
        ]
    }

    /// ふつうのセッションの `codex exec` に足す -c（sandbox と承認はそのセッションの設定のまま）。
    static func codexExecDelegateArgs(port: Int) -> [String] {
        Array(codexExecArgs(port: port).dropLast(4))
    }

    // MARK: Antigravity（agy）への渡し方
    //
    // agy には会話ごとに MCP を渡す引数が無い（`agy mcp add` は全体の ~/.gemini/config/mcp_config.json に書く）。ただし
    // `--add-dir` で足したフォルダの `.agents/mcp_config.json` も読み、その stdio のサーバは agy の環境変数を引き継ぐ
    // （2026-10-18 に agy 1.4.2 で確かめた。mac でも同じ）。そこで、合鍵を含まない設定（stdio の中継 = 動いている Bridge を
    // mcp-stdio-relay で起こす）を BuddyOS 専用のフォルダに置き、合鍵を渡すセッションの agy にだけ `--add-dir` で読ませる。
    // 合鍵と番号は agy の環境変数（BUDDYOS_MCP_TOKEN / BUDDYOS_MCP_PORT）で渡し、引数・ファイルには載せない。
    // 中身は windows-bridge の agyMcpConfig と同じ。

    /// agy に --add-dir で読ませるフォルダ（~/.buddyos/agy-mcp。.agents/mcp_config.json を置く）。
    static var agyMcpDirectory: URL { BuddyPaths.root.appendingPathComponent("agy-mcp", isDirectory: true) }

    /// agy の mcp_config.json の中身（合鍵を含まない）。
    static func agyMcpConfig(executable: String) -> [String: Any] {
        ["mcpServers": [mcpServerName: ["command": executable, "args": [McpStdioRelay.subcommand]]]]
    }

    /// agy の設定を置く（中身と権限が同じなら書かない）。置けたらフォルダのパス、置けなければ nil（agy には渡さない）。
    /// フォルダは 0700（agy が中に入れるように）、ファイルは 0600。
    static func ensureAgyMcpConfig(executable: String, dir: URL = agyMcpDirectory) -> String? {
        let fm = FileManager.default
        let agents = dir.appendingPathComponent(".agents", isDirectory: true)
        let file = agents.appendingPathComponent("mcp_config.json")
        guard let data = try? JSONSerialization.data(withJSONObject: agyMcpConfig(executable: executable),
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        let body = data + Data("\n".utf8)
        do {
            for d in [dir, agents] {
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
            }
            if (try? Data(contentsOf: file)) != body {
                try body.write(to: file, options: .atomic)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return dir.path
        } catch {
            WebSocketServer.wslog("mainagent could not write the agy MCP config: \(error.localizedDescription)")
            return nil
        }
    }

    /// ACP の session/new・load の `mcpServers` の 1 件（http の形）。エージェントが mcpCapabilities.http を申告したときに使う。
    /// 申告しないエージェントには stdio の中継（`McpStdioRelay.acpServer`、`<Bridge> mcp-stdio-relay`）を渡す。
    static func acpServer(token: String, port: Int) -> [String: Any] {
        [
            "type": "http",
            "name": mcpServerName,
            "url": mcpURL(port: port),
            "headers": [["name": "Authorization", "value": "Bearer \(token)"]]
        ]
    }

    // MARK: - フォルダに置くファイル

    static let files: [ManagedFile] = [
        ManagedFile(path: "CLAUDE.md", frontmatter: nil, body: roleText, legacy: [legacyRoleTextV1]),
        ManagedFile(path: "AGENTS.md", frontmatter: nil, body: roleText, legacy: [legacyRoleTextV1]),
        ManagedFile(path: ".claude/skills/dispatch/SKILL.md", frontmatter: dispatchFrontmatter, body: dispatchSkill,
                    legacy: [legacyDispatchSkillV1]),
        ManagedFile(path: ".claude/skills/status/SKILL.md", frontmatter: statusFrontmatter, body: statusSkill,
                    legacy: [legacyStatusSkillV1])
    ]

    /// 無いときだけ置くファイル（利用者が自由に直す。Bridge は書き換えない。NOTES.md の末尾には save_note が足す）。
    static let heartbeatFileName = "HEARTBEAT.md"
    static let notesFileName = "NOTES.md"
    static let userFiles: [(path: String, body: String)] = [
        (heartbeatFileName, heartbeatInitial),
        (notesFileName, notesInitial)
    ]

    static let heartbeatInitial = """
    # 定期チェックで見ること

    メインが定期チェックのたびに読みます。自由に書き足したり消したりしてください。

    - 承認を待って止まっている会話はないか
    - 途中で止まったままの作業はないか（最後の返事が質問・確認・「残りは…」で終わっている、しばらく動いていない）
    - 失敗したままの作業はないか
    - 長く動き続けている作業はないか
    - Gmail / Google ドライブを見る道具があれば：返事をしていないメール、しばらく進んでいない文書

    伝えるときは、何が・どこで止まっていて・次に何をすればよいかを 1 行ずつ。作業は頼まない（気づいたことを知らせるだけ）。

    """

    /// 前の版の HEARTBEAT.md（このままなら今の版に置き換える）。
    static let legacyHeartbeatInitials = [
        """
        # 定期チェックで見ること

        メインが定期チェックのたびに読みます。自由に書き足したり消したりしてください。

        - 承認を待って止まっている会話はないか
        - 終わった作業・失敗した作業はないか（終わったものは要点だけ）
        - 長く動き続けている作業はないか

        """
    ]

    static let notesInitial = """
    # メインのメモ

    メインが覚えておくことです。自由に直したり消したりしてください。

    """

    static var notesURL: URL { defaultURL.appendingPathComponent(notesFileName) }

    static let roleText = """
    # mainagent

    あなたは BuddyOS の mainagent（窓口）です。ユーザーとはここだけで話し、実際の作業はほかのセッションに任せます。

    ## 決まり
    - 自分ではコードを書かない。ファイルも編集しない。コマンドも打たない（使えないようにしてある）。
    - 仕事は `buddyos` の道具（MCP）だけで進める。
      - `list_projects` / `list_agents` / `list_sessions` / `get_reply` / `list_pcs` / `save_note` は、いつ使ってもよい。
      - `start_session` / `send_message` は作業を頼む道具。呼ぶと BuddyOS がユーザーに承認を尋ねる（断られたら頼まない）。
      - `list_pcs` は頼める PC の一覧（この PC と、つないでいる別の PC）。どの道具にも `pc`（`list_pcs` の pc か name）を付けると、
        その PC のプロジェクト・セッションを扱う。付けなければこの PC。別の PC へ頼むときも承認カード（「PC: 名前」付き）が出る。
        別の PC のセッションの返事・承認も、同じ `pc` を付けた `get_reply` / `answer_approval` で扱う。
      - `start_session` の `mode` で子の権限モードを選べる（plan / ask / edit / auto）。このチャットで選んだモードより強くはならない。
      - `send_message` は、相手のセッションのモードがこのチャットのモードより強いと断られる（エラーに「…より強いので送らない」と出る）。
        そのときは勝手に別のセッションを起こさず、ユーザーに「相手のチャットのモードを下げるか、このチャットのモードを上げるか」を聞く。
      - `wait_seconds` を付けると、送ったまま返事を待てる（最大 300 秒）。
      - `answer_approval` は、子が承認待ち（`needs_approval`）のときに代わりに答える道具。
        - `deny` はすぐ答える。`allow` / `allow_for_session` は、BuddyOS がユーザーに承認を尋ねてから答える。
        - このチャットのモードが計画（plan）なら許可できない。`allow_for_session` は「編集は尋ねない」以上のときだけ。
        - 何を許すのか（`approval` の `title` / `summary`）が依頼の範囲か確かめてから答える。範囲の外・分からないものは答えずにユーザーに聞く。
        - `choices` に無い答えは使えない。質問（答えられないと書いてあるもの）は、ユーザーにそのセッションを開いてもらう。
    - 1 つの作業は 1 つのセッションに頼む。同じプロジェクトを 2 つのセッションに同時に触らせない。
    - 頼む文には、目的・やってほしいこと・やってはいけないこと・終わりの条件・報告の形を書く。
      commit / push / デプロイ / 削除は、ユーザーが頼んだときだけ指示に入れる。

    ## 案件の回し方
    1. どのプロジェクトの話かを決める（`list_projects`）。わからなければユーザーに聞く。
       別の PC の話なら `list_pcs` で PC を決め、以後の道具に `pc` を付ける。
    2. そのプロジェクトで動いているセッションを探す（`list_sessions` の cwd で見る）。
       - あれば `send_message` で送る。断られたら上の決まりのとおりユーザーに聞く。
       - 無ければ `start_session` で起こす。エージェントの指定が無ければ claude を使う。
    3. `get_reply` で返事を待つ。`running` のあいだは、待つか、ユーザーに途中経過を伝える。
       - `needs_approval` なら、どのセッションが何の承認で止まっているかをユーザーに伝える。
         依頼の範囲の操作なら `answer_approval` で答えてよいか聞く（ユーザーが「許可して」と言えば `allow`）。
         答えられないもの・迷うものは、そのセッションを開いてもらう。
    4. 返事を短くまとめて答える：結果 / 止まっている点 / ユーザーの判断が必要な点。

    ## 定期チェックとメモ
    定期チェック（[定期チェック …] で始まる依頼）では、HEARTBEAT.md に沿って見るだけにし、伝えることが無ければ HEARTBEAT_OK とだけ返す。覚えておくとよいこと（利用者の好み・続いている作業・決まったこと）は save_note で残す。前に残したことは NOTES.md にある。

    ## 話し方
    - ユーザーへの返事は日本語。短く、結論から。
    - セッションは「プロジェクト名 + エージェント名」で呼ぶ（ID は必要なときだけ）。
    - 任せたセッションの進み具合は、BuddyOS がこのチャットにカードで出す。同じ内容を長々と繰り返さない。
    """

    static let dispatchFrontmatter = """
    ---
    name: dispatch
    description: ユーザーの依頼を、担当のプロジェクトのセッションに回して結果をまとめる。「〇〇を直して」「〇〇で△△して」と頼まれたときに使う。
    ---
    """

    static let dispatchSkill = """
    # 依頼を回す

    1. `list_projects` で、依頼がどのプロジェクトのものかを決める。候補が複数ならユーザーに聞く。
       - 別の PC のプロジェクトなら、`list_pcs` で PC を選び、以後の道具すべてに同じ `pc` を付ける。
    2. `list_sessions` で、そのプロジェクト（cwd が一致）のセッションを探す。
       - 作業中（state=working）のセッションに送ると、今のターンの後に実行される（予約）。急ぎなら新しく起こす。
    3. 指示文を書く。目的 / やること / やらないこと / 終わりの条件 / 報告の形（変更したファイル・確認結果・残課題）。
    4. 既存のセッションなら `send_message`、無ければ `start_session`（agent は指定が無ければ claude）。
       - `send_message` が「モードが上限より強い」で断られたら、別のセッションを起こさずユーザーに聞く。
    5. 送るときに wait_seconds=120 を付けて返事を待つ。`running` なら `get_reply` でもう一度待つか、ユーザーに「作業中」と伝えて戻る。
       - 調べるだけの依頼は mode=plan で起こす。
    6. `needs_approval` なら、`approval` の title / summary を見て、依頼の範囲の操作かを確かめる。
       - 範囲の中で、ユーザーが許可すると言っていれば `answer_approval`（decision=allow）。BuddyOS が承認を尋ねる。
       - 範囲の外・分からないもの・`choices` が無いものは答えず、ユーザーに伝える。
    7. 返事をまとめる：結果 / 止まっている点 / ユーザーの判断が必要な点。
    """

    static let statusFrontmatter = """
    ---
    name: status
    description: 動いているセッションの状況をまとめる。「今どうなってる？」「みんな何してる？」と聞かれたときに使う。
    ---
    """

    static let statusSkill = """
    # 状況をまとめる

    1. `list_sessions` で動いているセッションを取る。
       - 別の PC も聞かれたら、`list_pcs` の PC ごとに `pc` を付けて `list_sessions` を呼ぶ。
    2. 気になるもの（作業中・承認待ち・最近動いたもの）だけ `get_reply`（wait_seconds=0）で最新の返事を見る。
       - 承認待ちは `pending_approvals`（list_sessions）か `approval`（get_reply）に、何の承認かが出る。
    3. プロジェクトごとに 1 行でまとめる：エージェント / 状態（作業中・待機・承認待ち）/ 直近の内容。
    4. ユーザーの判断が必要なもの（承認待ちを含む）を最後に挙げる。承認は `answer_approval` で代わりに答えられると添える。
    """

    // MARK: - 前の版（範囲の印なしで書いていたもの。手を入れていなければ今の版に置き換える）

    static let legacyRoleTextV1 = """
    # mainagent

    あなたは BuddyOS の mainagent（窓口）です。ユーザーとはここだけで話し、実際の作業はほかのセッションに任せます。

    ## 決まり
    - 自分ではコードを書かない。ファイルも編集しない。コマンドも打たない（使えないようにしてある）。
    - 仕事は `buddyos` の道具（MCP）だけで進める。
      - `list_projects` / `list_agents` / `list_sessions` / `get_reply` は、いつ使ってもよい。
      - `start_session` / `send_message` は作業を頼む道具。呼ぶと BuddyOS がユーザーに承認を尋ねる（断られたら頼まない）。
      - `start_session` の `mode` で子の権限モードを選べる（plan / edit / auto）。このチャットで選んだモードより強くはならない。
      - `send_message` は、相手のセッションのモードがこのチャットのモードより強いと断られる。そのときはユーザーに伝える。
      - `wait_seconds` を付けると、送ったまま返事を待てる（最大 300 秒）。
    - 1 つの作業は 1 つのセッションに頼む。同じプロジェクトを 2 つのセッションに同時に触らせない。
    - 頼む文には、目的・やってほしいこと・やってはいけないこと・終わりの条件・報告の形を書く。
      commit / push / デプロイ / 削除は、ユーザーが頼んだときだけ指示に入れる。

    ## 案件の回し方
    1. どのプロジェクトの話かを決める（`list_projects`）。わからなければユーザーに聞く。
    2. そのプロジェクトで動いているセッションを探す（`list_sessions` の cwd で見る）。
       - あれば `send_message` で送る。
       - 無ければ `start_session` で起こす。エージェントの指定が無ければ claude を使う。
    3. `get_reply` で返事を待つ。`running` のあいだは、待つか、ユーザーに途中経過を伝える。
       - `needs_approval` なら、どのセッションが何の承認で止まっているかをユーザーに伝え、そのセッションを開いてもらう。
    4. 返事を短くまとめて答える：結果 / 止まっている点 / ユーザーの判断が必要な点。

    ## 話し方
    - ユーザーへの返事は日本語。短く、結論から。
    - セッションは「プロジェクト名 + エージェント名」で呼ぶ（ID は必要なときだけ）。
    """

    static let legacyDispatchSkillV1 = """
    ---
    name: dispatch
    description: ユーザーの依頼を、担当のプロジェクトのセッションに回して結果をまとめる。「〇〇を直して」「〇〇で△△して」と頼まれたときに使う。
    ---

    # 依頼を回す

    1. `list_projects` で、依頼がどのプロジェクトのものかを決める。候補が複数ならユーザーに聞く。
    2. `list_sessions` で、そのプロジェクト（cwd が一致）のセッションを探す。
       - 生成中（generating=true）のセッションに送ると、今のターンの後に実行される（予約）。急ぎなら新しく起こす。
    3. 指示文を書く。目的 / やること / やらないこと / 終わりの条件 / 報告の形（変更したファイル・確認結果・残課題）。
    4. 既存のセッションなら `send_message`、無ければ `start_session`（agent は指定が無ければ claude）。
    5. 送るときに wait_seconds=120 を付けて返事を待つ。`running` なら `get_reply` でもう一度待つか、ユーザーに「作業中」と伝えて戻る。
       - 調べるだけの依頼は mode=plan で起こす。
    6. 返事をまとめる：結果 / 止まっている点 / ユーザーの判断が必要な点。
    """

    static let legacyStatusSkillV1 = """
    ---
    name: status
    description: 動いているセッションの状況をまとめる。「今どうなってる？」「みんな何してる？」と聞かれたときに使う。
    ---

    # 状況をまとめる

    1. `list_sessions` で動いているセッションを取る。
    2. 気になるもの（生成中・承認待ち・最近動いたもの）だけ `get_reply`（wait_seconds=0）で最新の返事を見る。
    3. プロジェクトごとに 1 行でまとめる：エージェント / 状態（作業中・待機・承認待ち）/ 直近の内容。
    4. ユーザーの判断が必要なものを最後に挙げる。
    """
}

// MARK: - ターミナルで開いた mainagent（アプリ内ターミナルの `claude`）

/// アプリ内ターミナルで `~/.buddyos/main` の claude を開くと、Bridge が起こしていないので `--mcp-config` も合鍵も渡らない
/// （起動時の復元・「ターミナルで続ける」の `claude --resume` もこれ）。そこでフォルダの `.mcp.json` に
/// stdio の中継（`<Bridge> mcp-stdio-relay --terminal`）を置き、中継はターミナル用の合鍵（`~/.buddyos/main-mcp-token`）と
/// 今の待ち受けの番号（`bridge.port`）を要求のたびに読む。Bridge が起こす claude は `--mcp-config` の同じ名前が優先される
/// （`.mcp.json` の buddyos は使われない）ので、これまでどおりセッションごとの合鍵で動く。
extension MainAgentWorkspace {
    /// ターミナル用の合鍵。Bridge を起動し直しても変えない（動いているターミナルの claude がそのまま使い続けられる）。
    static var terminalTokenURL: URL { BuddyPaths.root.appendingPathComponent("main-mcp-token") }
    /// 中継が付ける、自分を起こした claude の PID（どのターミナルのセッションからの呼び出しかを Bridge が引く）。
    static let claudePidHeader = "X-BuddyOS-Claude-Pid"
    /// `.mcp.json` の中継の引数。
    static let terminalRelayArgs = [McpStdioRelay.subcommand, McpStdioRelay.terminalFlag]

    /// ターミナル用の合鍵を読む（無ければ nil）。
    static func terminalToken(url: URL = terminalTokenURL) -> String? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// ターミナル用の合鍵を用意する（無いときだけ作る。あれば書き換えない）。ファイルは 0600。
    @discardableResult
    static func ensureTerminalToken(url: URL = terminalTokenURL) -> String? {
        if let existing = terminalToken(url: url) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = "bmt_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 0600 で作ってから書く（一瞬でも他人に読める権限で置かない）。
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
        do {
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.write(contentsOf: Data((token + "\n").utf8))
        } catch {
            return nil
        }
        return terminalToken(url: url)
    }

    /// mainagent のフォルダの `.mcp.json` に中継を置き、`.claude/settings.json` で有効にする（ターミナルの claude が
    /// 尋ねずに読み込むように）。ほかのサーバ・ほかの設定は残す。中身が変わらなければ書かない。
    /// 読めない・JSON ではないファイルは触らない（利用者が手で書いたものを壊さない）。
    static func ensureTerminalMcp(root: URL = defaultURL, executable: String?) {
        guard let executable, !executable.isEmpty else { return }
        let server: [String: Any] = ["type": "stdio", "command": executable, "args": terminalRelayArgs]
        mergeJSON(at: root.appendingPathComponent(".mcp.json")) { obj in
            var servers = obj["mcpServers"] as? [String: Any] ?? [:]
            servers[mcpServerName] = server
            obj["mcpServers"] = servers
        }
        mergeJSON(at: root.appendingPathComponent(".claude").appendingPathComponent("settings.json")) { obj in
            var enabled = obj["enabledMcpjsonServers"] as? [String] ?? []
            if !enabled.contains(mcpServerName) { enabled.append(mcpServerName) }
            obj["enabledMcpjsonServers"] = enabled
        }
    }

    /// JSON のオブジェクトを読み、手を入れて、変わったときだけ書く。無ければ空から作る。
    private static func mergeJSON(at url: URL, _ edit: (inout [String: Any]) -> Void) {
        let fm = FileManager.default
        var obj: [String: Any] = [:]
        var original: Any?
        if fm.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else { return }
            if !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                obj = parsed
                original = parsed
            }
        }
        edit(&obj)
        if let original = original as? [String: Any], NSDictionary(dictionary: original).isEqual(to: obj) { return }
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (out + Data("\n".utf8)).write(to: url, options: [.atomic])
    }
}
