import Foundation

/// Real per-agent availability probe backing the `/status` endpoint.
///
/// `/health` only reports *declared* capabilities; this probes whether each
/// agent's CLI is actually installed, configured, and (best-effort) its version
/// — so the desktop dashboard can show a truthful "setup" state.
///
/// Results are cached briefly because the desktop polls on an interval and
/// version probing shells out.
actor AgentProbe {
    static let shared = AgentProbe()

    struct Result: Sendable {
        let installed: Bool
        let binaryPath: String?
        let configured: Bool
        let version: String?
    }

    private var cache: [String: Result] = [:]
    private var cachedAt: Date = .distantPast
    private let ttl: TimeInterval = 15

    func probe(id: String) async -> Result {
        if Date().timeIntervalSince(cachedAt) > ttl {
            cache = [:]
            cachedAt = Date()
        }
        if let hit = cache[id] { return hit }
        let result = Self.compute(id: id)
        cache[id] = result
        return result
    }

    /// 全キャッシュを破棄し、次回 probe で必ずディスク/PATH から再計算させる。
    /// CLI インストール直後に desktop が `/status?fresh=1` で呼ぶ。これが無いと
    /// 「入れたのに最大 15s 認識されない」体感になる（別プロセスの bust では届かない）。
    func clearCache() {
        cache = [:]
        cachedAt = .distantPast
        Self.bustWhichCache()
        Self.bustSpawnCaches()
    }

    private static func home() -> String { NSHomeDirectory() }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) || FileManager.default.fileExists(atPath: $0) }
    }

    /// Resolve a binary from an env override, a known-path list, then $PATH.
    private static func locate(envKey: String, candidates: [String], command: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[envKey], !env.isEmpty,
           FileManager.default.fileExists(atPath: env) {
            return env
        }
        // 明示候補 → 各種バージョンマネージャ/独自 prefix の候補 → ログインシェル解決。
        // 明示候補を先頭に保つことで version 表示のピン留め（codex 等）は退行しない。
        if let hit = firstExisting(candidates + extraCandidates(command)) { return hit }
        return whichResolve(command)
    }

    /// npm の独自 prefix（`npm config set prefix` / `NPM_CONFIG_PREFIX`）や Volta / Bun /
    /// pnpm / Yarn など、ハードコード候補から漏れがちなグローバル bin を補う。
    /// ログインシェルの `command -v` でも拾えるが、bridge が最小 PATH で起動された
    /// 場合（shell 解決が空振り）の保険として明示パスでも当てにいく。
    private static func extraCandidates(_ command: String) -> [String] {
        var out: [String] = []
        let env = ProcessInfo.processInfo.environment
        for key in ["NPM_CONFIG_PREFIX", "npm_config_prefix", "PREFIX"] {
            if let p = env[key], !p.isEmpty { out.append(p + "/bin/" + command) }
        }
        let h = home()
        out.append(h + "/.volta/bin/" + command)
        out.append(h + "/.bun/bin/" + command)
        out.append(h + "/Library/pnpm/" + command)
        out.append(h + "/.yarn/bin/" + command)
        out.append(h + "/.config/yarn/global/node_modules/.bin/" + command)
        return out
    }

    /// ログインシェル解決の結果キャッシュ。`zsh -lic` は重く(数百ms〜数秒)、probe の
    /// 15s TTL ごとに全コマンドで叩き直すとシェル起動が積み上がるため、コマンド単位で
    /// 5 分キャッシュする(「見つからない」も含む)。CLI インストール直後は desktop が
    /// `/status?fresh=1` → clearCache() を呼ぶので、そこで即時破棄される。
    private static let whichLock = NSLock()
    private static var whichCache: [String: (path: String?, at: Date)] = [:]
    private static let whichTTL: TimeInterval = 300

    static func bustWhichCache() {
        whichLock.lock()
        whichCache = [:]
        whichLock.unlock()
    }

    private static func whichResolve(_ command: String) -> String? {
        whichLock.lock()
        if let hit = whichCache[command], Date().timeIntervalSince(hit.at) < whichTTL {
            whichLock.unlock()
            return hit.path
        }
        whichLock.unlock()
        let resolved = whichResolveUncached(command)
        whichLock.lock()
        whichCache[command] = (resolved, Date())
        whichLock.unlock()
        return resolved
    }

    /// `$PATH` からコマンドを解決する。
    ///
    /// GUI/launchd 起動のブリッジは最小 PATH しか持たず、nvm / Volta / fnm / カスタム
    /// npm prefix 配下の CLI が `/usr/bin/which` に引っかからない（=「未インストール」誤表示）。
    /// desktop の `prereqs.ts` と同じく**ログイン＋対話シェルで実 PATH を引く**のが正解。
    /// `.zshrc` のノイズ出力を弾くため、出力の各行から最初に「実行可能ファイルとして実在する」
    /// ものを採用する。シェル起動に失敗した場合は従来の `/usr/bin/which` にフォールバック
    /// して現行動作を退行させない。
    private static func whichResolveUncached(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let out = run(shell, ["-lic", "command -v \(command)"], timeout: 4.0) {
            for raw in out.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty, FileManager.default.isExecutableFile(atPath: line) {
                    return line
                }
            }
        }
        // フォールバック: 最小 PATH での which（シェル解決が空/失敗した場合の保険）。
        guard let out = run("/usr/bin/which", [command], timeout: 1.0)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty,
            FileManager.default.fileExists(atPath: out) else { return nil }
        return out
    }

    private static func configured(_ relativePaths: [String]) -> Bool {
        relativePaths.contains { FileManager.default.fileExists(atPath: home() + "/" + $0) }
    }

    /// claude が使える状態か。設定ファイルがある（従来の判定）か、`claude auth login` 済み
    /// （`~/.claude.json` の oauthAccount）か、ANTHROPIC_API_KEY があるか。ログインしただけでは
    /// settings.json が作られないので、アプリ内のログイン後に「要認証」のまま残らないようにする。
    private static func claudeConfigured() -> Bool {
        if configured([".claude/settings.json", ".claude/settings.local.json"]) { return true }
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let data = FileManager.default.contents(atPath: home() + "/.claude.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else {
            return false
        }
        return !account.isEmpty
    }

    /// codex が「実際に認証済み」か。`~/.codex/auth.json` を読み、ChatGPT サブスクの
    /// `tokens`（非空）か `OPENAI_API_KEY`（非空）を要求する。env の OPENAI_API_KEY 運用も可。
    /// config.toml の存在は認証ではないので見ない（未ログイン誤緑の原因）。
    private static func codexAuthed() -> Bool {
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let data = FileManager.default.contents(atPath: home() + "/.codex/auth.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if let key = obj["OPENAI_API_KEY"] as? String,
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let tokens = obj["tokens"] as? [String: Any], !tokens.isEmpty {
            return true
        }
        return false
    }

    private static func compute(id: String) -> Result {
        switch id {
        case "claude":
            let bin = locate(
                envKey: "CLAUDE_BIN",
                candidates: [
                    home() + "/.npm-global/bin/claude",
                    "/opt/homebrew/bin/claude",
                    "/usr/local/bin/claude",
                    home() + "/.local/bin/claude"
                ],
                command: "claude"
            )
            return Result(
                installed: bin != nil,
                binaryPath: bin,
                configured: claudeConfigured(),
                version: bin.flatMap { version($0) }
            )
        case "codex":
            // CodexHistoryAdapter.locateExecutable() と完全一致（候補ドリフト防止）。
            // `~/.npm-global/bin/codex` を先頭にしないと、古い `/opt/homebrew/bin/codex`
            // （例: 0.23.0）が優先され /status の表示だけ古い版を指す誤表示になる。
            let bin = locate(
                envKey: "CODEX_BIN",
                candidates: [
                    home() + "/.npm-global/bin/codex",
                    "/opt/homebrew/bin/codex",
                    "/usr/local/bin/codex",
                    home() + "/.local/bin/codex"
                ],
                command: "codex"
            )
            // config.toml の存在だけだと「インストール直後（未ログイン）でも ✓」の誤緑になる。
            // codex は初回起動で config.toml を書くが、それは認証ではない。実際にチャットを通すには
            // ChatGPT サブスク認証（auth.json の tokens）か API キー認証が要る。hermes / openclaw /
            // opencode と同じく「認証実体」まで確認する（auth.json を読んで tokens か
            // OPENAI_API_KEY の実体を要求。環境変数 OPENAI_API_KEY での運用も認める）。
            return Result(
                installed: bin != nil,
                binaryPath: bin,
                configured: codexAuthed(),
                version: bin.flatMap { version($0) }
            )
        case "hermes":
            let bin = locate(
                envKey: "HERMES_BIN",
                candidates: [
                    home() + "/.npm-global/bin/hermes",
                    "/opt/homebrew/bin/hermes",
                    "/usr/local/bin/hermes",
                    home() + "/.local/bin/hermes"
                ],
                command: "hermes"
            )
            // config.yaml の存在だけだと「API キー無しでも ✓」の誤緑になるため、
            // 認証実体（.env のキー or auth.json の credential）も要求する。
            let hermesAuthed: Bool = {
                if let env = try? String(contentsOfFile: home() + "/.hermes/.env", encoding: .utf8),
                   env.range(
                       of: "(?m)^(GLM_API_KEY|ZAI_API_KEY|Z_AI_API_KEY|ANTHROPIC_API_KEY|OPENAI_API_KEY)=.+",
                       options: .regularExpression
                   ) != nil {
                    return true
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: home() + "/.hermes/auth.json"),
                   let size = attrs[.size] as? Int, size > 2 {
                    return true
                }
                return false
            }()
            return Result(
                installed: bin != nil,
                binaryPath: bin,
                configured: configured([".hermes/config.yaml"]) && hermesAuthed,
                version: bin.flatMap { version($0) }
            )
        case "openclaw":
            let bin = locate(
                envKey: "OPENCLAW_BIN",
                candidates: [
                    home() + "/.npm-global/bin/openclaw",
                    "/opt/homebrew/bin/openclaw",
                    "/usr/local/bin/openclaw",
                    home() + "/.local/bin/openclaw"
                ],
                command: "openclaw"
            )
            // openclaw.json の存在だけだと「onboard 未実行（token/モデル無し）でも ✓」
            // になり、チャットは gateway 不在で失敗する誤緑。gateway.auth.token と
            // agents.defaults.model.primary の実体まで確認する（JSON5 のため json5Allowed）。
            let openclawReady: Bool = {
                guard let data = FileManager.default.contents(atPath: home() + "/.openclaw/openclaw.json"),
                      let obj = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
                    return false
                }
                let token = ((obj["gateway"] as? [String: Any])?["auth"] as? [String: Any])?["token"] as? String
                let primary = ((((obj["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"]
                    as? [String: Any])?["primary"]) as? String
                return (token?.isEmpty == false) && (primary?.isEmpty == false)
            }()
            return Result(
                installed: bin != nil,
                binaryPath: bin,
                configured: openclawReady,
                version: bin.flatMap { openclawVersion($0) }
            )
        case "opencode":
            let bin = locate(
                envKey: "OPENCODE_BIN",
                candidates: [
                    home() + "/.npm-global/bin/opencode",
                    "/opt/homebrew/bin/opencode",
                    "/usr/local/bin/opencode",
                    home() + "/.local/bin/opencode"
                ],
                command: "opencode"
            )
            let opencodeReady: Bool = {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: home() + "/.local/share/opencode/auth.json"),
                   let size = attrs[.size] as? Int, size > 2 {
                    return true
                }
                return configured([".config/opencode/opencode.json"])
            }()
            return Result(
                installed: bin != nil,
                binaryPath: bin,
                configured: opencodeReady,
                version: bin.flatMap { version($0) }
            )
        case "cursor":
            // Cursor CLI (cursor-agent)。configured は API キー（env / ~/.buddyos/cursor.token）
            // か `cursor-agent status` のログイン状態で判定する（ログイン実体は CLI 管理で
            // ファイルパスが公開されていないため、status に聞くのが確実）。
            let bin = locate(
                envKey: "CURSOR_AGENT_BIN",
                candidates: [
                    home() + "/.local/bin/cursor-agent",
                    "/opt/homebrew/bin/cursor-agent",
                    "/usr/local/bin/cursor-agent"
                ],
                command: "cursor-agent"
            )
            let authed: Bool = {
                if CursorKey.resolve() != nil { return true }
                guard let bin else { return false }
                return cursorLoggedIn(bin)
            }()
            return Result(
                installed: bin != nil,
                binaryPath: bin,
                configured: authed,
                version: bin.flatMap { version($0) }
            )
        case "grok":
            // Grok Build CLI (xAI)。configured は XAI_API_KEY / ~/.buddyos/grok.token /
            // `grok login` の ~/.grok/auth.json のいずれか。
            let bin = locate(
                envKey: "GROK_BIN",
                candidates: [
                    home() + "/.grok/bin/grok",
                    home() + "/.local/bin/grok",
                    "/opt/homebrew/bin/grok",
                    "/usr/local/bin/grok"
                ],
                command: "grok"
            )
            return Result(
                installed: bin != nil,
                binaryPath: bin,
                configured: GrokAuth.isConfigured,
                version: bin.flatMap { version($0) }
            )
        case "antigravity":
            // Antigravity CLI (agy)。認証は Antigravity IDE と共有の keychain のため
            // ファイルでは判定できず、`agy models` が実一覧を返すかで configured を決める。
            let bin = locate(
                envKey: "ANTIGRAVITY_BIN",
                candidates: [
                    home() + "/.local/bin/agy",
                    "/opt/homebrew/bin/agy",
                    "/usr/local/bin/agy"
                ],
                command: "agy"
            )
            return Result(
                installed: bin != nil,
                binaryPath: bin,
                configured: bin.map { AntigravityAuth.isConfigured(executable: $0) } ?? false,
                version: bin.flatMap { version($0) }
            )
        case "buddy":
            // 内蔵エージェント（バイナリ不要）。設定済み = マネージドの OpenRouter キーがある。
            return Result(
                installed: true,
                binaryPath: nil,
                configured: BuddyAdapter.isConfigured(),
                version: "1.0"
            )
        case "echo":
            // Built-in stub adapter; always available.
            return Result(installed: true, binaryPath: nil, configured: true, version: nil)
        default:
            return Result(installed: false, binaryPath: nil, configured: false, version: nil)
        }
    }

    private static func openclawVersion(_ path: String) -> String? {
        // The npm launcher can take seconds to load (or resolve a different
        // Node through launchd's PATH). Read the installed package it points to.
        let manifest = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: manifest),
           let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           package["name"] as? String == "openclaw",
           let version = package["version"] as? String, !version.isEmpty {
            return "OpenClaw \(version)"
        }
        return version(path)
    }

    // MARK: プロセスを起動して調べる結果のキャッシュ
    //
    // desktop は 3 秒ごとに /health と /status を叩くので、上の 15s キャッシュが切れるたびに
    // 全エージェントの `--version` と `cursor-agent status` が起動していた（node / bun 製の CLI は
    // 1 回で 1 コアを 0.5〜1 秒使う。CLI を多く入れている Mac ほど常に重くなる）。
    // 版は実体ファイルが変わらない限り同じなので、実体パスと更新日時で覚えておく。

    private static let spawnLock = NSLock()
    private static var versionCache: [String: (key: String, value: String?, at: Date)] = [:]
    /// 版が取れなかった（タイムアウト等）ときは、この間をおいてから取り直す。
    private static let versionFailureTTL: TimeInterval = 300
    private static var cursorStatusCache: [String: (ok: Bool, at: Date)] = [:]
    /// `cursor-agent status` の結果。ログイン済みは長め、未ログインはログイン直後に待たせないよう短め。
    private static let cursorPositiveTTL: TimeInterval = 10 * 60
    private static let cursorNegativeTTL: TimeInterval = 60

    static func bustSpawnCaches() {
        spawnLock.withLock {
            versionCache = [:]
            cursorStatusCache = [:]
        }
    }

    /// 実体ファイル（シンボリックリンクの先）のパスと更新日時。CLI を更新するとどちらかが変わる。
    private static func fileIdentity(_ path: String) -> String {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: real))?[.modificationDate] as? Date
        return "\(real)@\(mtime?.timeIntervalSince1970 ?? 0)"
    }

    private static func version(_ path: String) -> String? {
        let key = fileIdentity(path)
        if let hit = spawnLock.withLock({ versionCache[path] }), hit.key == key,
           hit.value != nil || Date().timeIntervalSince(hit.at) < versionFailureTTL {
            return hit.value
        }
        let value = run(path, ["--version"], timeout: 1.5)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first.map(String.init) // Keep it short: first line only.
        spawnLock.withLock { versionCache[path] = (key, value, Date()) }
        return value
    }

    private static func cursorLoggedIn(_ bin: String) -> Bool {
        if let hit = spawnLock.withLock({ cursorStatusCache[bin] }),
           Date().timeIntervalSince(hit.at) < (hit.ok ? cursorPositiveTTL : cursorNegativeTTL) {
            return hit.ok
        }
        let out = run(bin, ["status"], timeout: 5.0)?.lowercased() ?? ""
        let ok = !out.isEmpty && !out.contains("not logged in")
        spawnLock.withLock { cursorStatusCache[bin] = (ok, Date()) }
        return ok
    }

    /// Run a command with a hard timeout. Returns stdout, or nil on failure/timeout.
    /// ProcessRunner 経由 (waitUntilExit のスレッド滞留 → fd リーク → EBADF 障害の再発防止)。
    private static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval) -> String? {
        ProcessRunner.runForString(launchPath, args, timeout: timeout)
    }
}
