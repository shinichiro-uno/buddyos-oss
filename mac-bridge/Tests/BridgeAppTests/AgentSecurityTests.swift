import XCTest
@testable import BridgeApp

/// エージェントまわりの安全策（子プロセスの環境変数・専用フォルダ・opencode serve の認証・agy と Buddy の承認・
/// Codex 共有 app-server・定期実行の作業フォルダ・許可の中継・hook の transcript_path）。
/// どれも実際の ~/.buddyos やエージェントには触らない。
final class AgentSecurityTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-sec-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // /var → /private/var のリンクを解いた形にそろえる（AgyApprovalPolicy.normalize と同じ）。
        tmp = URL(fileURLWithPath: (tmp.path as NSString).resolvingSymlinksInPath, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - 子プロセスの環境変数

    func testChildEnvironmentStripsSecrets() {
        let env = ChildEnvironment.sanitized([
            "PATH": "/usr/bin",
            "BUDDYOS_CLERK_TOKEN": "x",
            "BUDDYOS_MCP_GITHUB": "y",
            "OPENCODE_SERVER_PASSWORD": "z",
            "BUDDYOS_SPAWNED": "1"
        ])
        XCTAssertEqual(env, ["PATH": "/usr/bin", "BUDDYOS_SPAWNED": "1"])
        XCTAssertNil(ChildEnvironment.base()["BUDDYOS_CLERK_TOKEN"])
    }

    // MARK: - 自分専用のフォルダ

    func testPrivateDirectoryCreatesAndTightens() throws {
        let dir = tmp.appendingPathComponent("cache").path
        XCTAssertTrue(PrivateDirectory.ensure(dir))
        XCTAssertEqual(try mode(dir), 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        XCTAssertTrue(PrivateDirectory.ensure(dir), "他人に開いた権限は絞って使う")
        XCTAssertEqual(try mode(dir), 0o700)
    }

    func testPrivateDirectoryRejectsSymlink() throws {
        let target = tmp.appendingPathComponent("real").path
        let link = tmp.appendingPathComponent("link").path
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertFalse(PrivateDirectory.ensure(link))
    }

    func testOpenCodeCacheIsNotSharedTmp() {
        XCTAssertFalse(OpenCodeAdapter.cacheHome.hasPrefix("/tmp"))
        XCTAssertFalse(OpenCodeAdapter.cacheHome.hasPrefix("/private/tmp"))
        XCTAssertEqual(OpenCodeAdapter.cacheEnvironment["XDG_CACHE_HOME"], OpenCodeAdapter.cacheHome)
        XCTAssertTrue(PrivateDirectory.isPrivate(OpenCodeAdapter.cacheHome))
    }

    // MARK: - opencode serve の Basic 認証

    func testOpenCodeServePasswordAndAuthorization() {
        let a = OpenCodeServeClient.makePassword()
        let b = OpenCodeServeClient.makePassword()
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, b, "起動ごとに変わる")
        XCTAssertEqual(OpenCodeServeClient.basicAuthorization(username: "opencode", password: "pw"),
                       "Basic " + Data("opencode:pw".utf8).base64EncodedString())
    }

    // MARK: - agy の承認

    private func agy(_ tool: String, _ args: [String: Any], allow: [String] = ["command(ls)", "command(find)", "command(cat)"],
                     cwd: String? = nil) -> AgyApprovalPolicy.Verdict {
        AgyApprovalPolicy.verdict(toolName: tool, args: args, allow: allow, deny: [],
                                  cwd: cwd ?? tmp.appendingPathComponent("proj").path, home: tmp.path)
    }

    private func isAsk(_ v: AgyApprovalPolicy.Verdict) -> Bool { if case .ask = v { return true }; return false }
    private func isDeny(_ v: AgyApprovalPolicy.Verdict) -> Bool { if case .deny = v { return true }; return false }

    func testAgyDefaultsToAskForUnknownTools() {
        XCTAssertTrue(isAsk(agy("mcp_github_create_issue", ["title": "x"])), "知らない道具は聞く")
        XCTAssertTrue(isAsk(agy("read_url_content", ["Url": "https://example.com"])))
        XCTAssertEqual(agy("view_file", ["AbsolutePath": tmp.appendingPathComponent("proj/a.txt").path]), .allow)
        XCTAssertEqual(agy("list_dir", ["DirectoryPath": "/usr"]), .allow)
    }

    func testAgyReadOfSecretsAsks() {
        XCTAssertTrue(isAsk(agy("view_file", ["AbsolutePath": tmp.appendingPathComponent(".buddyos/api-key").path])))
    }

    func testAgyWritesOnlyInsideCwd() throws {
        let proj = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        XCTAssertEqual(agy("write_to_file", ["TargetFile": proj.appendingPathComponent("src/a.swift").path]), .allow)
        XCTAssertEqual(agy("replace_file_content", ["TargetFile": "src/b.swift"]), .allow, "相対パスは作業フォルダから")
        XCTAssertTrue(isAsk(agy("write_to_file", ["TargetFile": tmp.appendingPathComponent("other/a.txt").path])))
        XCTAssertTrue(isAsk(agy("write_to_file", ["TargetFile": proj.appendingPathComponent("../other/a.txt").path])))
        XCTAssertTrue(isAsk(agy("write_to_file", ["Content": "x"])), "書き先が分からなければ聞く")
        XCTAssertTrue(isAsk(AgyApprovalPolicy.verdict(toolName: "write_to_file", args: ["TargetFile": proj.appendingPathComponent("a").path],
                                                      allow: [], deny: [], cwd: nil, home: tmp.path)), "作業フォルダが無ければ聞く")
    }

    /// 作業フォルダの中でも、agy の hook（.agents/hooks.json）や git の hook・設定は承認なしに書かせない。
    func testAgyWritesToHookConfigInsideCwdAsk() throws {
        let proj = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        XCTAssertTrue(isAsk(agy("write_to_file", ["TargetFile": proj.appendingPathComponent(".agents/hooks.json").path])))
        XCTAssertTrue(isAsk(agy("write_to_file", ["TargetFile": ".git/hooks/pre-commit"])))
        XCTAssertTrue(isAsk(agy("replace_file_content", ["TargetFile": proj.appendingPathComponent(".git/config").path])))
        XCTAssertTrue(isAsk(agy("write_to_file", ["TargetFile": proj.appendingPathComponent("sub/.gemini/settings.json").path])))
        XCTAssertEqual(agy("write_to_file", ["TargetFile": proj.appendingPathComponent(".github/workflows/ci.yml").path]), .allow)
        XCTAssertEqual(agy("write_to_file", ["TargetFile": proj.appendingPathComponent(".gitignore").path]), .allow)
    }

    func testAgyProtectedWritesAreDenied() throws {
        XCTAssertTrue(isDeny(agy("write_to_file", ["TargetFile": tmp.appendingPathComponent(".buddyos/agy-hooks/buddy-agy-approval.sh").path])))
        XCTAssertTrue(isDeny(agy("write_to_file", ["TargetFile": tmp.appendingPathComponent(".gemini/antigravity-cli/settings.json").path])))
        XCTAssertTrue(isDeny(agy("write_to_file", ["TargetFile": "~/.zshrc"])))
        XCTAssertTrue(isDeny(agy("write_to_file", ["TargetFile": tmp.appendingPathComponent("Library/LaunchAgents/x.plist").path])))
        // 作業フォルダがホームでも、シェルの設定ファイルは書かせない。
        XCTAssertTrue(isDeny(agy("write_to_file", ["TargetFile": tmp.appendingPathComponent(".zprofile").path], cwd: tmp.path)))
    }

    func testAgySymlinkInsideCwdToProtectedIsDenied() throws {
        let proj = tmp.appendingPathComponent("proj")
        let hooks = tmp.appendingPathComponent(".buddyos/agy-hooks")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: proj.appendingPathComponent("h"), withDestinationURL: hooks)
        XCTAssertTrue(isDeny(agy("write_to_file", ["TargetFile": proj.appendingPathComponent("h/buddy-agy-approval.sh").path])))
    }

    func testAgyAllowlistDoesNotCoverRedirectsOrExec() {
        func cmd(_ c: String) -> AgyApprovalPolicy.Verdict { agy("run_command", ["CommandLine": c]) }
        XCTAssertEqual(cmd("ls -la"), .allow)
        XCTAssertTrue(isAsk(cmd("ls > ~/.zshrc")), "リダイレクトは許可リストでは通さない")
        XCTAssertTrue(isAsk(cmd("cat < /etc/passwd")))
        XCTAssertTrue(isAsk(cmd("find . -exec rm {} \\;")), "find の -exec は通さない")
        XCTAssertTrue(isAsk(cmd("find . -delete")))
        XCTAssertTrue(isAsk(agy("run_command", ["CommandLine": "ls", "Cwd": tmp.appendingPathComponent(".buddyos").path])))
    }

    // MARK: - Buddy の MCP 承認

    func testBuddyApprovalIsFailClosed() {
        XCTAssertTrue(BuddySession.isApproved("accept"))
        XCTAssertTrue(BuddySession.isApproved("acceptForSession"))
        XCTAssertFalse(BuddySession.isApproved("decline"))
        XCTAssertFalse(BuddySession.isApproved(""))
        XCTAssertFalse(BuddySession.isApproved("allow_always"))
    }

    // MARK: - Codex 共有 app-server の待ち受けの確認

    func testCodexListenerOwnership() {
        let parsed = CodexSharedAppServer.parseListeners("p100\nu501\nf12\np200\nu501\nf13\n")
        XCTAssertEqual(parsed.map(\.pid), [100, 200])
        XCTAssertEqual(parsed.map(\.uid), [501, 501])
        XCTAssertTrue(CodexSharedAppServer.listenersAreOwn(parsed, uid: 501, serverPids: [100, 200]))
        XCTAssertFalse(CodexSharedAppServer.listenersAreOwn(parsed, uid: 502, serverPids: [100, 200]), "別のユーザー")
        XCTAssertFalse(CodexSharedAppServer.listenersAreOwn(parsed, uid: 501, serverPids: [100]), "app-server ではないプロセス")
        XCTAssertFalse(CodexSharedAppServer.listenersAreOwn([], uid: 501, serverPids: [100]), "確かめられない")
    }

    // MARK: - 定期実行の作業フォルダ

    func testCronCwdNormalization() throws {
        let home = tmp.appendingPathComponent("home").path
        let bin = tmp.appendingPathComponent("bin").path
        try FileManager.default.createDirectory(atPath: home + "/proj", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: bin + "/sub", withIntermediateDirectories: true)
        func n(_ raw: String?) throws -> String { try BridgeCronScheduler.normalizeCwd(raw, home: home, bridgeDirectory: bin) }
        XCTAssertEqual(try n(nil), home, "空欄はホーム")
        XCTAssertEqual(try n("  "), home)
        XCTAssertEqual(try n("~/proj"), home + "/proj")
        XCTAssertThrowsError(try n("/"))
        XCTAssertThrowsError(try n("/System"))
        XCTAssertThrowsError(try n(bin), "Bridge のバイナリのあるフォルダ")
        XCTAssertThrowsError(try n(bin + "/sub"))
        XCTAssertThrowsError(try n(home + "/missing"))
        XCTAssertThrowsError(try n("relative/path"))
    }

    func testCodexUnattendedCwdDefaultsToHome() {
        XCTAssertEqual(CodexHistoryAdapter.unattendedCwd(nil), NSHomeDirectory())
        XCTAssertEqual(CodexHistoryAdapter.unattendedCwd("/tmp/x"), "/tmp/x")
    }

    // MARK: - 許可の中継の結び付け

    func testInputPreviewMatching() {
        XCTAssertEqual(ClaudeTerminalRegistry.inputPreviewMatches(["command": "ls -la"], #"{"command": "ls -la"}"#), true)
        XCTAssertEqual(ClaudeTerminalRegistry.inputPreviewMatches(["command": "ls -la /very/long"], #"{"command":"ls -la…"#), true)
        XCTAssertEqual(ClaudeTerminalRegistry.inputPreviewMatches(["command": "ls"], #"{"command":"rm x"}"#), false)
        XCTAssertNil(ClaudeTerminalRegistry.inputPreviewMatches(["command": "ls"], nil))
        XCTAssertNil(ClaudeTerminalRegistry.inputPreviewMatches([:], #"{"command":"ls"}"#))
        // キーの順は問わない（Swift の辞書は順を持たない）。
        let edit: [String: Any] = ["new_string": "b", "file_path": "/p/a.swift", "old_string": "a"]
        XCTAssertEqual(ClaudeTerminalRegistry.inputPreviewMatches(edit, #"{"file_path":"/p/a.swift","old_string":"a","new_string":"b"}"#), true)
        XCTAssertEqual(ClaudeTerminalRegistry.inputPreviewMatches(edit, #"{"file_path":"/p/other.swift","old_str…"#), false)
        XCTAssertEqual(ClaudeTerminalRegistry.inputPreviewMatches(edit, #"{"unknown":"x"}"#), false)
    }

    // MARK: - hook の transcript_path

    func testTranscriptPathValidation() throws {
        let home = tmp.path
        let sid = "11111111-2222-3333-4444-555555555555"
        let good = home + "/.claude/projects/-p/\(sid).jsonl"
        XCTAssertEqual(ClaudeTerminalRegistry.validTranscriptPath(good, sessionId: sid, home: home), good)
        XCTAssertNil(ClaudeTerminalRegistry.validTranscriptPath(home + "/.ssh/id_ed25519", sessionId: sid, home: home))
        XCTAssertNil(ClaudeTerminalRegistry.validTranscriptPath("/etc/\(sid).jsonl", sessionId: sid, home: home), "ホームの外")
        XCTAssertNil(ClaudeTerminalRegistry.validTranscriptPath(home + "/.claude/projects/-p/other.jsonl", sessionId: sid, home: home))
        XCTAssertNil(ClaudeTerminalRegistry.validTranscriptPath("relative/\(sid).jsonl", sessionId: sid, home: home))
        // シンボリックリンクは読まない。
        let dir = home + "/.claude/projects/-q"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: dir + "/\(sid).jsonl", withDestinationPath: "/etc/hosts")
        XCTAssertNil(ClaudeTerminalRegistry.validTranscriptPath(dir + "/\(sid).jsonl", sessionId: sid, home: home))
    }

    private func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
