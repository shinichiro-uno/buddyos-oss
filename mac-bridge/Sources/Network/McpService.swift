import Foundation

/// `~/.hermes/config.yaml` の `mcp_servers:` ブロックを読み出して
/// MCP サーバ名 + transport (url / command) を返す軽量サービス。
///
/// 想定する YAML 形式:
/// ```yaml
/// mcp_servers:
///   name1:
///     url: "https://..."
///   name2:
///     command: "/path/to/bin"
///     args: ["mcp-server"]
/// ```
/// 値は二重引用符・単一引用符が剥がされた素の文字列を返す。
enum McpService {
    /// agentId に応じて読むファイルを切り替える:
    /// - Hermes  : `~/.hermes/config.yaml` の `mcp_servers:` ブロック (YAML)
    /// - Codex   : `~/.codex/config.toml` の `[mcp_servers.*]` (TOML)
    /// - OpenClaw: `~/.openclaw/openclaw.json` の `plugins.entries` (OpenClaw では
    ///             MCP に相当する拡張機構を "plugins" と呼ぶ)
    /// - Cursor  : `~/.cursor/mcp.json`、Antigravity: `~/.gemini/config/mcp_config.json`（どちらも mcpServers の JSON）
    /// - Grok    : `~/.grok/config.toml` の `[mcp_servers.*]`（Codex と同じ TOML）
    /// 上記以外の未知の agentId は空（Hermes の設定を他 agent のものとして見せない）。
    static func list(agentId: String? = nil) -> [McpServerSummary] {
        if agentId == "codex" {
            guard let raw = try? String(contentsOfFile: codexHome() + "/config.toml", encoding: .utf8) else { return [] }
            return parseToml(raw)
        }
        if agentId == "openclaw" {
            return listOpenclawPlugins()
        }
        if agentId == "claude" {
            return listClaudeMcpServers()
        }
        if agentId == "opencode" {
            return listOpencodeMcpServers()
        }
        if agentId == "buddy" {
            return listJsonMcpServers(path: buddyConfigPath())
        }
        if agentId == "cursor" {
            return listJsonMcpServers(path: cursorConfigPath())
        }
        if agentId == "antigravity" {
            return listJsonMcpServers(path: antigravityConfigPath())
        }
        if agentId == "grok" {
            let path = NSHomeDirectory() + "/.grok/config.toml"
            guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
            return parseToml(raw)
        }
        // agentId 無指定は従来どおり Hermes（WebSocketServer の既定も "hermes"）
        guard agentId == nil || agentId == "hermes" else { return [] }
        let path = NSHomeDirectory() + "/.hermes/config.yaml"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(raw)
    }

    /// Codex の設定の場所。codex 本体・CodexConfigStore と同じく BUDDYOS_CODEX_HOME → CODEX_HOME → ~/.codex。
    static func codexHome() -> String {
        let env = ProcessInfo.processInfo.environment
        for key in ["BUDDYOS_CODEX_HOME", "CODEX_HOME"] {
            if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return NSHomeDirectory() + "/.codex"
    }

    /// register / delete が書ける agent（設定の持ち主の id）。switch に足したらここにも足す。
    static let registrableAgents: Set<String> = ["claude", "codex", "hermes", "opencode", "buddy", "cursor", "grok", "antigravity"]

    /// その agent 自身の設定へ書けるか。
    static func canRegister(_ agentId: String) -> Bool {
        registrableAgents.contains(agentId)
    }

    /// Claude Code の MCP サーバ一覧。`~/.claude/settings.json` → `settings.local.json`
    /// → `~/.claude.json` の順に各ファイルのトップレベル `mcpServers` を読み、同名は
    /// あとに読んだ方が勝つ。`~/.claude.json` は `claude mcp add --scope user`
    /// （registerClaude）の書き込み先なので最優先。settings 系は後方互換。
    /// transport には url / command だけを使い、headers / env（Bearer トークン等）は返さない。
    private static func listClaudeMcpServers() -> [McpServerSummary] {
        let home = NSHomeDirectory()
        let paths = [
            home + "/.claude/settings.json",
            home + "/.claude/settings.local.json",
            home + "/.claude.json"
        ]
        var merged: [String: McpServerSummary] = [:]
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any] else { continue }
            for (name, raw) in servers {
                let dict = raw as? [String: Any] ?? [:]
                let transport: String
                if let url = dict["url"] as? String, !url.isEmpty {
                    transport = url
                } else if let cmd = dict["command"] as? String, !cmd.isEmpty {
                    let args = (dict["args"] as? [String]) ?? []
                    transport = args.isEmpty ? cmd : "\(cmd) \(args.joined(separator: " "))"
                } else {
                    transport = "(unknown)"
                }
                merged[name] = McpServerSummary(name: name, transport: transport)
            }
        }
        return merged.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// `~/.openclaw/openclaw.json` の `plugins.entries` から enabled なものを返す。
    private static func listOpenclawPlugins() -> [McpServerSummary] {
        guard let entries = OpenclawConfig.load()?.plugins?.entries else { return [] }
        return entries
            .filter { $0.value.enabled == true }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { name, _ in
                McpServerSummary(name: name, transport: "openclaw-plugin")
            }
    }

    /// Codex の TOML から `[mcp_servers.NAME]` ブロックだけを拾う。
    /// サブテーブル (例: `[mcp_servers.foo.tools.bar]`) は無視する。
    static func parseToml(_ raw: String) -> [McpServerSummary] {
        var current: (name: String, url: String?, command: String?, args: [String], type: String?)? = nil
        var result: [McpServerSummary] = []

        func flush() {
            guard let c = current else { return }
            let transport: String
            if let u = c.url, !u.isEmpty {
                transport = u
            } else if let cmd = c.command, !cmd.isEmpty {
                transport = c.args.isEmpty ? cmd : "\(cmd) \(c.args.joined(separator: " "))"
            } else if let t = c.type, !t.isEmpty {
                transport = t
            } else {
                transport = "(unknown)"
            }
            result.append(McpServerSummary(name: c.name, transport: transport))
            current = nil
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // ヘッダは削除と同じ tomlHeaderKeys で読む（行末コメント・クォート付きでドットを含む名前）。
            // サブテーブル（.env / .tools）や別のテーブルに入ったら、その後の行を前のサーバに付けない。
            if let keys = tomlHeaderKeys(line) {
                flush()
                if !line.hasPrefix("[["), keys.count == 2, keys[0] == "mcp_servers" {
                    current = (keys[1], nil, nil, [], nil)
                }
                continue
            }

            guard current != nil else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let stripped = stripQuotes(value)
            switch key {
            case "url":
                current?.url = stripped
            case "command":
                current?.command = stripped
            case "args":
                current?.args = parseInlineList(value)
            case "type":
                current?.type = stripped
            default:
                break
            }
        }
        flush()
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    static func parse(_ raw: String) -> [McpServerSummary] {
        var inMcpBlock = false
        // indent of "name:" line under mcp_servers
        var nameIndent: Int? = nil
        var current: (name: String, url: String?, command: String?, args: [String])? = nil
        var result: [McpServerSummary] = []

        func flush() {
            guard let c = current else { return }
            let transport: String
            if let u = c.url, !u.isEmpty {
                transport = u
            } else if let cmd = c.command, !cmd.isEmpty {
                if c.args.isEmpty {
                    transport = cmd
                } else {
                    transport = "\(cmd) \(c.args.joined(separator: " "))"
                }
            } else {
                transport = "(unknown)"
            }
            result.append(McpServerSummary(name: c.name, transport: transport))
            current = nil
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // skip comment / blank
            let trimmedWhole = line.trimmingCharacters(in: .whitespaces)
            if trimmedWhole.isEmpty || trimmedWhole.hasPrefix("#") { continue }

            let leading = line.prefix(while: { $0 == " " })
            let indent = leading.count
            let body = String(line.dropFirst(indent))

            if indent == 0 {
                // top-level key: 別ブロックへ
                flush()
                inMcpBlock = body.hasPrefix("mcp_servers:")
                nameIndent = nil
                continue
            }
            guard inMcpBlock else { continue }

            // 最初のネスト = name 行のインデント
            if nameIndent == nil {
                nameIndent = indent
            }

            if indent == nameIndent {
                // name: の行
                flush()
                let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard let raw = parts.first.map(String.init) else { continue }
                let name = raw.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                current = (name: name, url: nil, command: nil, args: [])
            } else if indent > (nameIndent ?? 0) {
                // 子要素 (url:, command:, args:, …)
                let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                let stripped = stripQuotes(value)
                switch key {
                case "url":
                    current?.url = stripped
                case "command":
                    current?.command = stripped
                case "args":
                    current?.args = parseInlineList(value)
                default:
                    break
                }
            }
        }
        flush()
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    /// `["a", "b"]` 形式のインライン YAML/JSON list を粗くパース。
    private static func parseInlineList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return [] }
        let inner = String(trimmed.dropFirst().dropLast())
        return inner.split(separator: ",").map {
            stripQuotes($0.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first, last = s.last
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Write path

    /// MCP server を 1 件追加する。書き込みは各 agent の CLI を第一選択にし、
    /// Codex（config.toml）と Hermes（config.yaml）は設定ファイルへの surgical 追記で行う（CLI 非依存）。
    static func register(agentId: String, spec: McpRegisterSpec) -> (ok: Bool, message: String?) {
        let name = spec.serverName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return (false, "サーバ名が空です") }
        if agentId == "openclaw" {
            return (false, "OpenCLAW は MCP の追加に未対応です")
        }
        // 重複チェック（既存 config を読む）。
        if list(agentId: agentId).contains(where: { $0.name == name }) {
            return (false, "\(name) は既に接続済みです")
        }
        switch agentId {
        case "claude":   return registerClaude(name: name, spec: spec)
        case "codex":    return registerCodex(name: name, spec: spec)
        case "hermes":   return registerHermes(name: name, spec: spec)
        case "opencode": return registerOpencode(name: name, spec: spec)
        case "buddy":    return registerJsonMcp(path: buddyConfigPath(), name: name, spec: spec, markEnabled: true)
        case "cursor":   return registerJsonMcp(path: cursorConfigPath(), name: name, spec: spec, markEnabled: false)
        case "antigravity": return registerViaCli("agy", name: name, spec: spec)
        case "grok":     return registerViaCli("grok", name: name, spec: spec)
        default:         return (false, "\(agentId) は MCP の追加に未対応です")
        }
    }

    static func delete(agentId: String, serverName: String) -> (ok: Bool, message: String?) {
        let name = serverName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return (false, "サーバ名が空です") }
        switch agentId {
        case "openclaw":
            return (false, "OpenCLAW は未対応です")
        case "opencode":
            return deleteOpencode(name: name)
        case "buddy":
            return deleteJsonMcp(path: buddyConfigPath(), name: name)
        case "cursor":
            return deleteJsonMcp(path: cursorConfigPath(), name: name)
        case "antigravity", "grok":
            let cli = agentId == "grok" ? "grok" : "agy"
            guard isInstalled(cli) else { return (false, "\(cli) が見つかりません") }
            let r = runLoginShell("\(cli) mcp remove \(shellQuote(name))")
            return r.status == 0 ? (true, "ok") : (false, cleanErr(r.stderr, r.stdout))
        case "codex":
            return deleteCodex(name: name)
        case "claude":
            guard isInstalled("claude") else { return (false, "claude が見つかりません") }
            // user scope（register と対）→ 見つからなければ旧 local scope 登録も試す
            let r = runLoginShell("claude mcp remove --scope user \(shellQuote(name))")
            if r.status == 0 { return (true, "ok") }
            let r2 = runLoginShell("claude mcp remove \(shellQuote(name))")
            guard r2.status == 0 else { return (false, cleanErr(r2.stderr, r2.stdout)) }
            return (true, "ok")
        case "hermes":
            guard isInstalled("hermes") else { return (false, "hermes が見つかりません") }
            let r = runLoginShell("hermes mcp remove \(shellQuote(name))")
            return r.status == 0 ? (true, "ok") : (false, cleanErr(r.stderr, r.stdout))
        default:
            return (false, "\(agentId) は MCP の削除に未対応です")
        }
    }

    // MARK: register 実装 (agent 別)

    private static func registerClaude(name: String, spec: McpRegisterSpec) -> (Bool, String?) {
        guard isInstalled("claude") else { return (false, "claude がインストールされていません") }
        var parts: [String]
        // --scope user: 既定の local scope は「add を実行した cwd のプロジェクト」限定に
        // なる（bridge の cwd に紐づき、チャットの作業ディレクトリからは見えない）。
        // MCP サーバはプロジェクト横断で使うものなので user scope に登録する。
        if spec.transportKind == "url", let url = spec.url, !url.isEmpty {
            parts = ["claude", "mcp", "add", "--scope", "user", "--transport", "http", shellQuote(name), shellQuote(url)]
            // 認証ヘッダ（例 Authorization: Bearer <token>）を注入する
            for (k, v) in spec.env.sorted(by: { $0.key < $1.key }) {
                parts.append("--header")
                parts.append(shellQuote("\(k): \(v)"))
            }
        } else if let cmd = spec.command, !cmd.isEmpty {
            parts = ["claude", "mcp", "add", "--scope", "user", shellQuote(name)]
            for (k, v) in spec.env {
                parts.append("--env")
                parts.append(shellQuote("\(k)=\(v)"))
            }
            parts.append("--")
            parts.append(shellQuote(cmd))
            for a in spec.args { parts.append(shellQuote(a)) }
        } else {
            return (false, "transport が不正です")
        }
        let r = runLoginShell(parts.joined(separator: " "))
        return r.status == 0 ? (true, "ok") : (false, cleanErr(r.stderr, r.stdout))
    }

    /// Hermes は `~/.hermes/config.yaml` の `mcp_servers:` にサーバを 1 件追記する（CLI 非依存）。
    /// url 型は url と headers、コマンド型は command / args / env を書く（hermesFullSpecs が読む形と同じ）。
    /// `hermes mcp add` は対話式（認証の有無・トークン入力・接続失敗時の保存確認・ツール選択を
    /// input() で尋ねる）で、stdin が EOF だと保存せずに exit 0 で戻るため使わない。
    /// Codex の config.toml と同じく行単位の surgical 編集で、他のキー・コメント・既存サーバには触れない。
    /// home はテスト用（既定は本当のホーム。差し替えたときは hermes の有無を見ない）。
    static func registerHermes(name: String, spec: McpRegisterSpec, home: String = NSHomeDirectory()) -> (Bool, String?) {
        guard home != NSHomeDirectory() || isInstalled("hermes") else { return (false, "hermes がインストールされていません") }
        let url = spec.transportKind == "url" ? (spec.url ?? "") : ""
        let command = spec.transportKind == "command" ? (spec.command ?? "") : ""
        guard !url.isEmpty || !command.isEmpty else {
            return (false, "Hermes に追加する MCP の url かコマンドがありません")
        }
        let dir = home + "/.hermes"
        let path = dir + "/config.yaml"
        var raw = ""
        if FileManager.default.fileExists(atPath: path) {
            // 読めないまま書くと model / provider 等の設定が全部消えるので中止する
            guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
                return (false, "Hermes の config.yaml を読めないため追加できません")
            }
            raw = s
        }
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }   // 末尾改行
        func isContent(_ l: String) -> Bool {
            let t = l.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        func indentOf(_ l: String) -> Int { l.prefix(while: { $0 == " " }).count }

        var nameIndent = 2
        var insertAt = lines.count
        if let header = lines.firstIndex(where: { $0.hasPrefix("mcp_servers:") }) {
            // `mcp_servers:` の後ろは空（ブロック）か空の値だけ受ける。インラインの {a: ...} は行編集できない
            let value = lines[header].dropFirst("mcp_servers:".count)
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard ["", "{}", "null", "~"].contains(value) else {
                return (false, "Hermes の config.yaml の mcp_servers を解析できないため追加できません")
            }
            lines[header] = "mcp_servers:"
            // ブロックは次の top-level キー（インデント 0 の行）の手前まで。コメント・空行は境界にしない
            let end = lines[(header + 1)...].firstIndex(where: { isContent($0) && indentOf($0) == 0 }) ?? lines.count
            let body = lines[(header + 1)..<end].indices.filter { isContent(lines[$0]) }
            // 中身が list（`- ...`）なら mapping として追記できない
            let firstItem = body.first ?? (value.isEmpty && end < lines.count ? end : nil)
            if let f = firstItem, lines[f].trimmingCharacters(in: .whitespaces).hasPrefix("-") {
                return (false, "Hermes の config.yaml の mcp_servers を解析できないため追加できません")
            }
            if let first = body.first { nameIndent = indentOf(lines[first]) }
            let exists = body.contains { i in
                guard indentOf(lines[i]) == nameIndent else { return false }
                let key = lines[i].split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
                return stripQuotes(key.trimmingCharacters(in: .whitespaces)) == name
            }
            if exists { return (false, "\(name) は既に接続済みです") }
            insertAt = (body.last ?? header) + 1
        } else {
            lines.append("mcp_servers:")
            insertAt = lines.count
        }

        let pad = String(repeating: " ", count: nameIndent)
        var entry: [String] = ["\(pad)\(yamlKey(name)):"]
        if !url.isEmpty {
            entry.append("\(pad)  url: \(yamlQuote(url))")
            if !spec.env.isEmpty {
                // 認証ヘッダ（例 Authorization: Bearer <token>）。hermes は headers をそのまま送る
                entry.append("\(pad)  headers:")
                for (k, v) in spec.env.sorted(by: { $0.key < $1.key }) {
                    entry.append("\(pad)    \(yamlKey(k)): \(yamlQuote(v))")
                }
            }
        } else {
            // コマンド型（npx で起こす filesystem / playwright 等）。env には API キーが入ることがある
            entry.append("\(pad)  command: \(yamlQuote(command))")
            if !spec.args.isEmpty {
                entry.append("\(pad)  args:")
                for a in spec.args { entry.append("\(pad)    - \(yamlQuote(a))") }
            }
            if !spec.env.isEmpty {
                entry.append("\(pad)  env:")
                for (k, v) in spec.env.sorted(by: { $0.key < $1.key }) {
                    entry.append("\(pad)    \(yamlKey(k)): \(yamlQuote(v))")
                }
            }
        }
        entry.append("\(pad)  enabled: true")
        lines.insert(contentsOf: entry, at: insertAt)

        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // headers / env にトークンが平文で入るので最初から 0600 で書く（hermes 自身も config.yaml を 0600 にする）
            try KeyStore.writeSecret(Data((lines.joined(separator: "\n") + "\n").utf8), to: URL(fileURLWithPath: path))
            return (true, "ok")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Codex は config.toml に `[mcp_servers.NAME]` ブロックを追記する（CLI 非依存）。
    private static func registerCodex(name: String, spec: McpRegisterSpec) -> (Bool, String?) {
        let dir = codexHome()
        let path = dir + "/config.toml"
        var raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        var block = "[mcp_servers.\(tomlKey(name))]\n"
        if spec.transportKind == "url", let url = spec.url, !url.isEmpty {
            block += "url = \"\(escapeToml(url))\"\n"
        } else if let cmd = spec.command, !cmd.isEmpty {
            block += "command = \"\(escapeToml(cmd))\"\n"
            if !spec.args.isEmpty {
                // `-> String` 明示: 別ファイルの import GRDB が漏れると補間リテラルが
                // GRDB.SQL に推論される実績あり (AcpClient で発生)。
                let arr = spec.args.map { arg -> String in "\"\(escapeToml(arg))\"" }.joined(separator: ", ")
                block += "args = [\(arr)]\n"
            }
            // env は stdio サーバの起動環境変数（url 型には無意味なので command branch のみ）
            if !spec.env.isEmpty {
                let pairs = spec.env
                    .sorted { $0.key < $1.key }
                    .map { pair -> String in "\(tomlKey(pair.key)) = \"\(escapeToml(pair.value))\"" }
                    .joined(separator: ", ")
                block += "env = { \(pairs) }\n"
            }
        } else {
            return (false, "transport が不正です")
        }

        if !raw.isEmpty && !raw.hasSuffix("\n") { raw += "\n" }
        if !raw.isEmpty { raw += "\n" }
        raw += block

        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // env にトークンが平文で入りうるので最初から 0600 で書く（既存の 0644 もこれで 0600 になる）。
            try KeyStore.writeSecret(Data(raw.utf8), to: URL(fileURLWithPath: path))
            return (true, "ok")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// config.toml から `[mcp_servers.NAME]` ブロックと、そのサブテーブル
    /// （`[mcp_servers.NAME.env]` / `[[mcp_servers.NAME.tools.x]]` 等。離れた位置にあっても）
    /// を除去する。各ブロックは次の（別の）table 開始まで。
    static func deleteCodex(name: String) -> (Bool, String?) {
        let path = codexHome() + "/config.toml"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return (true, "ok") }
        var out: [String] = []
        var skipping = false
        var removed = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let keys = tomlHeaderKeys(line) {
                // サブテーブルだけ残すと transport の無い mcp_servers.NAME になり codex が起動できない
                skipping = keys.count >= 2 && keys[0] == "mcp_servers" && keys[1] == name
                if skipping {
                    removed = true
                    continue
                }
            } else if skipping {
                continue           // ブロック内の行を捨てる
            }
            out.append(line)
        }
        if !removed { return (true, "ok") }
        do {
            // 残る他のサーバーの env にトークンが入りうるので 0600 で書く。
            try KeyStore.writeSecret(Data(out.joined(separator: "\n").utf8), to: URL(fileURLWithPath: path))
            return (true, "ok")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// TOML のテーブルヘッダ行（`[a.b]` / `[[a.b]]`）をドット区切りのキー列に分解する。
    /// 括弧内の空白・クォート付きキー（"..." / '...'）・行末コメントを許す。ヘッダでなければ nil
    /// （例: 複数行配列の途中の `["a", "b"],` は閉じ括弧のあとに `,` が残るので nil）。
    private static func tomlHeaderKeys(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("[") else { return nil }
        let isArray = t.hasPrefix("[[")
        var chars = Substring(t.dropFirst(isArray ? 2 : 1))
        var keys: [String] = []
        var cur = ""
        var quote: Character? = nil
        var closed = false
        while let c = chars.first {
            chars = chars.dropFirst()
            if let q = quote {
                if q == "\"", c == "\\", let next = chars.first {
                    cur.append(next)   // basic string のエスケープ（tomlKey の逆）
                    chars = chars.dropFirst()
                } else if c == q {
                    quote = nil
                } else {
                    cur.append(c)
                }
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case ".": keys.append(cur); cur = ""
            case "]": closed = true
            case " ", "\t": break
            default: cur.append(c)
            }
            if closed { break }
        }
        guard closed else { return nil }
        keys.append(cur)
        if isArray {
            guard chars.first == "]" else { return nil }
            chars = chars.dropFirst()
        }
        let rest = chars.trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") else { return nil }
        return keys
    }

    // MARK: - opencode (~/.config/opencode/opencode.json "mcp")

    private static func opencodeConfigPath() -> String {
        NSHomeDirectory() + "/.config/opencode/opencode.json"
    }

    /// opencode.json の root object を読む。ファイルが無い／空なら空 object、中身があるのに
    /// object として読めなければ nil（呼び出し側は書き込まない）。opencode 本体は JSONC
    /// （コメント・末尾カンマ可）を許すので一覧表示は `jsonc: true`（JSON5 として読む）。
    /// 書き戻すとコメントが消えるため、書き込み系は厳密な JSON として読めたときだけ行う。
    private static func loadOpencodeRoot(path: String, jsonc: Bool = false) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        let options: JSONSerialization.ReadingOptions = jsonc ? [.json5Allowed] : []
        return (try? JSONSerialization.jsonObject(with: data, options: options)) as? [String: Any]
    }

    /// opencode.json の top-level "mcp" object を読んで MCP サーバ一覧を返す。
    /// transport は remote なら url、local なら command.join(" ")。
    private static func listOpencodeMcpServers() -> [McpServerSummary] {
        guard let root = loadOpencodeRoot(path: opencodeConfigPath(), jsonc: true),
              let mcp = root["mcp"] as? [String: Any] else { return [] }
        var result: [McpServerSummary] = []
        for (name, raw) in mcp {
            let dict = raw as? [String: Any] ?? [:]
            let transport: String
            if let url = dict["url"] as? String, !url.isEmpty {
                transport = url
            } else if let cmd = dict["command"] as? [String], !cmd.isEmpty {
                transport = cmd.joined(separator: " ")
            } else {
                transport = "(unknown)"
            }
            result.append(McpServerSummary(name: name, transport: transport))
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// opencode.json の "mcp" object に 1 件追加する（read-modify-write、他キーは保持）。
    private static func registerOpencode(name: String, spec: McpRegisterSpec) -> (Bool, String?) {
        let path = opencodeConfigPath()
        // 読めないまま [:] から書き戻すと provider / model / 既存 mcp が全部消えるので中止する
        guard var root = loadOpencodeRoot(path: path) else {
            return (false, "opencode.json を解析できないため追加できません（コメント等を含む場合は手動で追加してください）")
        }
        var mcp = (root["mcp"] as? [String: Any]) ?? [:]

        var entry: [String: Any] = ["enabled": true]
        if spec.transportKind == "url", let url = spec.url, !url.isEmpty {
            entry["type"] = "remote"
            entry["url"] = url
            if !spec.env.isEmpty {
                // auth ヘッダ等がある場合は headers として保存する。
                entry["headers"] = spec.env
            }
        } else if let cmd = spec.command, !cmd.isEmpty {
            entry["type"] = "local"
            entry["command"] = [cmd] + spec.args
            if !spec.env.isEmpty {
                entry["environment"] = spec.env
            }
        } else {
            return (false, "transport が不正です")
        }

        mcp[name] = entry
        root["mcp"] = mcp
        return writeOpencodeConfig(root, path: path)
    }

    /// opencode.json の "mcp" object から 1 件削除する。
    private static func deleteOpencode(name: String) -> (Bool, String?) {
        let path = opencodeConfigPath()
        // ファイル無し／空 = [:] = 既に存在しない。読めないときは成功と偽らずエラーにする
        guard var root = loadOpencodeRoot(path: path) else {
            return (false, "opencode.json を解析できないため削除できません")
        }
        guard var mcp = root["mcp"] as? [String: Any] else { return (true, "ok") }
        mcp.removeValue(forKey: name)
        root["mcp"] = mcp   // 空でも "mcp": {} を残す
        return writeOpencodeConfig(root, path: path)
    }

    /// 2-space indent + 末尾改行で opencode.json を書き出す。
    private static func writeOpencodeConfig(_ root: [String: Any], path: String) -> (Bool, String?) {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            data.append(0x0A)   // trailing newline
            // headers / environment にトークン等が平文で入るので、最初から本人のみ読める 0600 で書く
            // （.atomic は umask に従った 0644 の新しい inode に置き換わり、後から chmod するまで他ユーザーに
            // 読める窓が残る。既存の 0644 ファイルもこの置き換えで 0600 になる）
            try KeyStore.writeSecret(data, to: URL(fileURLWithPath: path))
            return (true, "ok")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: mcpServers 形式の JSON（buddy / Cursor / Antigravity。Claude Code と同じ形）

    private static func buddyConfigPath() -> String {
        NSHomeDirectory() + "/.buddyos/buddy-mcp.json"
    }

    private static func cursorConfigPath() -> String {
        NSHomeDirectory() + "/.cursor/mcp.json"
    }

    /// agy が読む MCP 設定（`agy mcp add` の書き込み先。http のサーバは serverUrl で持つ）。
    private static func antigravityConfigPath() -> String {
        NSHomeDirectory() + "/.gemini/config/mcp_config.json"
    }

    static func listJsonMcpServers(path: String) -> [McpServerSummary] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        var result: [McpServerSummary] = []
        for (name, raw) in servers {
            let dict = raw as? [String: Any] ?? [:]
            if let enabled = dict["enabled"] as? Bool, enabled == false { continue }
            if let disabled = dict["disabled"] as? Bool, disabled { continue }
            let transport: String
            // CLI ごとに URL のキー名が違う（Claude / Cursor: url、agy: serverUrl、Gemini 系: httpUrl）。
            if let url = ["url", "serverUrl", "httpUrl"].lazy.compactMap({ dict[$0] as? String }).first(where: { !$0.isEmpty }) {
                transport = url
            } else if let cmd = dict["command"] as? String, !cmd.isEmpty {
                let args = (dict["args"] as? [String]) ?? []
                transport = args.isEmpty ? cmd : "\(cmd) \(args.joined(separator: " "))"
            } else {
                transport = "(unknown)"
            }
            result.append(McpServerSummary(name: name, transport: transport))
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// "mcpServers" に 1 件追加する（read-modify-write、他キー保持）。
    /// markEnabled: BuddyOS 独自の "enabled" を付けるか（buddy だけ。CLI の設定には知らないキーを足さない）。
    private static func registerJsonMcp(path: String, name: String, spec: McpRegisterSpec, markEnabled: Bool) -> (Bool, String?) {
        var root: [String: Any] = {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }()
        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]

        var entry: [String: Any] = markEnabled ? ["enabled": true] : [:]
        if spec.transportKind == "url", let url = spec.url, !url.isEmpty {
            entry["url"] = url
            if !spec.env.isEmpty { entry["headers"] = spec.env }
        } else if let cmd = spec.command, !cmd.isEmpty {
            entry["command"] = cmd
            if !spec.args.isEmpty { entry["args"] = spec.args }
            if !spec.env.isEmpty { entry["env"] = spec.env }
        } else {
            return (false, "transport が不正です")
        }

        servers[name] = entry
        root["mcpServers"] = servers
        return writeJsonConfig(root, path: path)
    }

    private static func deleteJsonMcp(path: String, name: String) -> (Bool, String?) {
        guard let data = FileManager.default.contents(atPath: path),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (true, "ok")
        }
        guard var servers = root["mcpServers"] as? [String: Any] else { return (true, "ok") }
        servers.removeValue(forKey: name)
        root["mcpServers"] = servers
        return writeJsonConfig(root, path: path)
    }

    private static func writeJsonConfig(_ root: [String: Any], path: String) -> (Bool, String?) {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            // headers / env にトークンが平文で入るので 0600 で書く（cursor / antigravity の mcp.json）。
            try KeyStore.writeSecret(data, to: URL(fileURLWithPath: path))
            return (true, "ok")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: `<cli> mcp add` 型（agy / grok）

    /// フラグは名前より前に置く（agy は名前の後のフラグを拒否する）。http(s) の URL は CLI が判定する。
    /// コマンドは `--` の後ろに置き、`-y` などの引数を CLI のフラグと取り違えさせない。
    private static func registerViaCli(_ cli: String, name: String, spec: McpRegisterSpec) -> (Bool, String?) {
        guard isInstalled(cli) else { return (false, "\(cli) がインストールされていません") }
        var parts = [cli, "mcp", "add"]
        if spec.transportKind == "url", let url = spec.url, !url.isEmpty {
            for (k, v) in spec.env.sorted(by: { $0.key < $1.key }) {
                parts += ["--header", shellQuote("\(k): \(v)")]
            }
            parts += [shellQuote(name), shellQuote(url)]
        } else if let cmd = spec.command, !cmd.isEmpty {
            for (k, v) in spec.env.sorted(by: { $0.key < $1.key }) {
                parts += ["--env", shellQuote("\(k)=\(v)")]
            }
            parts += [shellQuote(name), "--", shellQuote(cmd)] + spec.args.map(shellQuote)
        } else {
            return (false, "transport が不正です")
        }
        let r = runLoginShell(parts.joined(separator: " "))
        return r.status == 0 ? (true, "ok") : (false, cleanErr(r.stderr, r.stdout))
    }

    // MARK: ヘルパ

    private static func runLoginShell(_ command: String) -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", command]
        p.environment = ChildEnvironment.base()
        // 対話式 CLI（hermes mcp remove の確認等）が Bridge の stdin を読んで待ち続けないよう、常に EOF を渡す
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return (-1, "", "spawn failed: \(error.localizedDescription)")
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    private static func isInstalled(_ cmd: String) -> Bool {
        let r = runLoginShell("command -v \(shellQuote(cmd)) >/dev/null 2>&1 && echo yes")
        return r.stdout.contains("yes")
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// YAML の double-quoted scalar（PyYAML でも読めるよう \ " と改行類だけエスケープする）。
    private static func yamlQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// YAML の mapping キー。英字始まりの英数・_・- なら bare（一覧の parse がクォートを剥がさないため）、
    /// それ以外と YAML 1.1 で bool / null に化ける語はクォートする。
    private static func yamlKey(_ s: String) -> String {
        let bare = s.first?.isLetter == true
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            && !["y", "n", "yes", "no", "on", "off", "true", "false", "null"].contains(s.lowercased())
        return bare ? s : yamlQuote(s)
    }

    private static func escapeToml(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// bare key にできなければ basic string でクォート。
    private static func tomlKey(_ s: String) -> String {
        let bare = s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return bare && !s.isEmpty ? s : "\"\(escapeToml(s))\""
    }

    /// CLI のエラー出力から最後の意味ある 1 行を抜き出す（長さ制限つき）。
    private static func cleanErr(_ stderr: String, _ stdout: String) -> String {
        let combined = (stderr.isEmpty ? stdout : stderr)
        let line = combined
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? "コマンドが失敗しました"
        return String(line.prefix(200))
    }
}

/// register リクエストの解決済みパラメータ。
struct McpRegisterSpec {
    let serverName: String
    let transportKind: String   // "url" | "command"
    let url: String?
    let command: String?
    let args: [String]
    let env: [String: String]
}

struct McpServerSummary: Codable, Equatable, Sendable {
    let name: String
    /// 表示用: url がある場合は url、command の場合は "command args..."。
    let transport: String
}

// MARK: - エージェント間でコネクタを写すための読み出し（ExtensionsShare から使う）

/// 写すための全情報。env は URL 型ならヘッダー、コマンド型なら環境変数（秘密の値を含むので Mac の外へ出さない）。
struct McpFullSpec: Sendable {
    let name: String
    let kind: String          // "url" | "command"
    let url: String?
    let command: String?
    let args: [String]
    let env: [String: String]

    /// 画面に出す要約（秘密の値は含めない）。引数にトークンを渡す使い方もあるので、
    /// コマンドと最初の（フラグでない）引数だけを出す。
    var summary: String {
        if kind == "url" { return url ?? "" }
        let first = args.first { !$0.hasPrefix("-") }
        return [command ?? "", first ?? ""].filter { !$0.isEmpty }.joined(separator: " ") + (args.count > 1 ? " …" : "")
    }

    var registerSpec: McpRegisterSpec {
        McpRegisterSpec(serverName: name, transportKind: kind, url: url, command: command, args: args, env: env)
    }
}

extension McpService {
    /// エージェントの設定ファイルから、コネクタを写せる形で全部読む。読めないものは飛ばす。
    static func fullSpecs(agentId: String) -> [McpFullSpec] {
        switch agentId {
        case "claude": return claudeFullSpecs()
        case "codex": return codexFullSpecs()
        case "opencode": return opencodeFullSpecs()
        case "hermes": return hermesFullSpecs()
        default: return []
        }
    }

    private static func stringMap(_ any: Any?) -> [String: String] {
        guard let dict = any as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict { if let s = v as? String { out[k] = s } else if let n = v as? NSNumber { out[k] = n.stringValue } }
        return out
    }

    private static func claudeFullSpecs() -> [McpFullSpec] {
        let home = NSHomeDirectory()
        var merged: [String: McpFullSpec] = [:]
        for path in [home + "/.claude/settings.json", home + "/.claude/settings.local.json", home + "/.claude.json"] {
            guard let data = FileManager.default.contents(atPath: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any] else { continue }
            for (name, raw) in servers {
                let d = raw as? [String: Any] ?? [:]
                if let url = d["url"] as? String, !url.isEmpty {
                    merged[name] = McpFullSpec(name: name, kind: "url", url: url, command: nil, args: [], env: stringMap(d["headers"]))
                } else if let cmd = d["command"] as? String, !cmd.isEmpty {
                    merged[name] = McpFullSpec(name: name, kind: "command", url: nil, command: cmd,
                                               args: (d["args"] as? [String]) ?? [], env: stringMap(d["env"]))
                }
            }
        }
        return merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func opencodeFullSpecs() -> [McpFullSpec] {
        guard let root = loadOpencodeRoot(path: opencodeConfigPath(), jsonc: true),
              let mcp = root["mcp"] as? [String: Any] else { return [] }
        var out: [McpFullSpec] = []
        for (name, raw) in mcp {
            let d = raw as? [String: Any] ?? [:]
            if (d["enabled"] as? Bool) == false { continue }
            if let url = d["url"] as? String, !url.isEmpty {
                out.append(McpFullSpec(name: name, kind: "url", url: url, command: nil, args: [], env: stringMap(d["headers"])))
            } else if let cmd = d["command"] as? [String], let first = cmd.first, !first.isEmpty {
                out.append(McpFullSpec(name: name, kind: "command", url: nil, command: first, args: Array(cmd.dropFirst()),
                                       env: stringMap(d["environment"])))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `~/.codex/config.toml` の `[mcp_servers.NAME]`。env / http_headers は
    /// インライン表（`env = { A = "b" }`）と下位の表（`[mcp_servers.NAME.env]`）の両方を読む。
    private static func codexFullSpecs() -> [McpFullSpec] {
        guard let raw = try? String(contentsOfFile: codexHome() + "/config.toml", encoding: .utf8) else { return [] }
        struct Acc { var url: String?; var command: String?; var args: [String] = []; var env: [String: String] = [:]; var headers: [String: String] = [:] }
        var acc: [String: Acc] = [:]
        var order: [String] = []
        var current: String?
        var sub: String?   // "env" | "http_headers" | nil
        func inlineTable(_ v: String) -> [String: String] {
            var t = v.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), t.hasSuffix("}") else { return [:] }
            t = String(t.dropFirst().dropLast())
            var out: [String: String] = [:]
            for pair in t.split(separator: ",") {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let k = stripQuotes(String(pair[..<eq]).trimmingCharacters(in: .whitespaces))
                let v = stripQuotes(String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
                if !k.isEmpty { out[k] = v }
            }
            return out
        }
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let keys = tomlHeaderKeys(line) {
                current = nil; sub = nil
                guard !line.hasPrefix("[["), keys.count >= 2, keys[0] == "mcp_servers" else { continue }
                let name = keys[1]
                if keys.count == 2 {
                    current = name
                    if acc[name] == nil { acc[name] = Acc(); order.append(name) }
                } else if keys.count == 3, keys[2] == "env" || keys[2] == "http_headers" {
                    current = name; sub = keys[2]
                    if acc[name] == nil { acc[name] = Acc(); order.append(name) }
                }
                continue
            }
            guard let name = current, let eq = line.firstIndex(of: "=") else { continue }
            let key = stripQuotes(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if let s = sub {
                if s == "env" { acc[name]?.env[key] = stripQuotes(value) } else { acc[name]?.headers[key] = stripQuotes(value) }
                continue
            }
            switch key {
            case "url": acc[name]?.url = stripQuotes(value)
            case "command": acc[name]?.command = stripQuotes(value)
            case "args": acc[name]?.args = parseInlineList(value)
            case "env": acc[name]?.env.merge(inlineTable(value)) { _, b in b }
            case "http_headers": acc[name]?.headers.merge(inlineTable(value)) { _, b in b }
            default: break
            }
        }
        return order.compactMap { name -> McpFullSpec? in
            guard let a = acc[name] else { return nil }
            if let u = a.url, !u.isEmpty { return McpFullSpec(name: name, kind: "url", url: u, command: nil, args: [], env: a.headers) }
            if let c = a.command, !c.isEmpty { return McpFullSpec(name: name, kind: "command", url: nil, command: c, args: a.args, env: a.env) }
            return nil
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `~/.hermes/config.yaml` の `mcp_servers:`。name の下の url / command / args（インライン or `- 項目`）
    /// と env / headers（1 段下の `key: value`）を読む。
    static func hermesFullSpecs(home: String = NSHomeDirectory()) -> [McpFullSpec] {
        guard let raw = try? String(contentsOfFile: home + "/.hermes/config.yaml", encoding: .utf8) else { return [] }
        struct Acc { var url: String?; var command: String?; var args: [String] = []; var env: [String: String] = [:]; var headers: [String: String] = [:] }
        func indent(_ s: Substring) -> Int { s.prefix { $0 == " " }.count }
        var inBlock = false
        var nameIndent: Int?
        var current: String?
        var acc: [String: Acc] = [:]
        var order: [String] = []
        var sub: String?      // "env" | "headers" | "args"
        var subIndent = 0
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let ind = indent(rawLine)
            if ind == 0 {
                inBlock = trimmed.hasPrefix("mcp_servers:")
                current = nil; sub = nil; nameIndent = nil
                continue
            }
            guard inBlock else { continue }
            if nameIndent == nil { nameIndent = ind }
            if ind == nameIndent, trimmed.hasSuffix(":") {
                let name = stripQuotes(String(trimmed.dropLast()))
                current = name; sub = nil
                if acc[name] == nil { acc[name] = Acc(); order.append(name) }
                continue
            }
            guard let name = current else { continue }
            if let s = sub, ind > subIndent {
                if s == "args", trimmed.hasPrefix("- ") {
                    acc[name]?.args.append(stripQuotes(String(trimmed.dropFirst(2))))
                } else if let c = trimmed.firstIndex(of: ":") {
                    let k = stripQuotes(String(trimmed[..<c]).trimmingCharacters(in: .whitespaces))
                    let v = stripQuotes(String(trimmed[trimmed.index(after: c)...]).trimmingCharacters(in: .whitespaces))
                    if s == "env" { acc[name]?.env[k] = v } else if s == "headers" { acc[name]?.headers[k] = v }
                }
                continue
            }
            sub = nil
            guard let c = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<c]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "url": acc[name]?.url = stripQuotes(value)
            case "command": acc[name]?.command = stripQuotes(value)
            case "args":
                if value.isEmpty { sub = "args"; subIndent = ind } else { acc[name]?.args = parseInlineList(value) }
            case "env", "headers":
                if value.isEmpty { sub = key; subIndent = ind }
            default: break
            }
        }
        return order.compactMap { name -> McpFullSpec? in
            guard let a = acc[name] else { return nil }
            if let u = a.url, !u.isEmpty { return McpFullSpec(name: name, kind: "url", url: u, command: nil, args: [], env: a.headers) }
            if let c = a.command, !c.isEmpty { return McpFullSpec(name: name, kind: "command", url: nil, command: c, args: a.args, env: a.env) }
            return nil
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
