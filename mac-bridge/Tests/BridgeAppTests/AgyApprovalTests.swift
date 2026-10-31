import XCTest
import Network
@testable import BridgeApp

/// agy の承認 hook。判断の規則と、実際の agy での承認・拒否（手動実行）。
final class AgyApprovalTests: XCTestCase {
    // MARK: - 規則

    func testVerdictFollowsAgyRules() {
        let allow = ["command(ls)", "command(git status)", "command(regex:npm run (build|test))"]
        let deny = ["command(rm -rf /)"]
        func v(_ c: String) -> AgyApprovalPolicy.Verdict {
            AgyApprovalPolicy.verdict(toolName: "run_command", args: ["CommandLine": c], allow: allow, deny: deny)
        }
        XCTAssertEqual(v("ls -la"), .allow)
        XCTAssertEqual(v("git status && npm run test"), .allow, "全部が許可リストにあれば通す")
        XCTAssertEqual(v("npm run build | tail"), .ask(title: "Antigravity: コマンドを実行", detail: "npm run build | tail"), "tail は許可リストに無い")
        XCTAssertEqual(v("lsof"), .ask(title: "Antigravity: コマンドを実行", detail: "lsof"), "ls の前方一致は単語の区切りまで")
        XCTAssertEqual(v("ls $(rm x)"), .ask(title: "Antigravity: コマンドを実行", detail: "ls $(rm x)"), "置き換えを含むものは通さない")
        if case .deny = v("rm -rf /") {} else { XCTFail("拒否リストは止める") }
        XCTAssertEqual(AgyApprovalPolicy.verdict(toolName: "view_file", args: [:], allow: [], deny: []), .allow, "コマンド以外は止めない")
    }

    func testSplitKeepsQuotedSeparators() {
        XCTAssertEqual(AgyApprovalPolicy.splitCommand("echo 'a;b' && ls | wc -l; pwd"), ["echo 'a;b'", "ls", "wc -l", "pwd"])
    }

    // MARK: - hook の置き場（--add-dir に渡さず、agy の全体設定のプラグインに置く）

    private func makeHome() throws -> String {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-hook-home-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock {
            // 読み取り専用にしたものも消せるよう戻してから消す。
            if let e = FileManager.default.enumerator(atPath: home.path) {
                for case let rel as String in e {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                           ofItemAtPath: home.appendingPathComponent(rel).path)
                }
            }
            try? FileManager.default.removeItem(at: home)
        }
        return (home.path as NSString).resolvingSymlinksInPath
    }

    private func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int) ?? -1
    }

    private func chmod(_ path: String, _ m: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: m], ofItemAtPath: path)
    }

    func testInstallRegistersPluginOutsideWorkspace() throws {
        let home = try makeHome()
        let install = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        XCTAssertTrue(AgyApprovalHook.isPluginName(install.pluginName), "名前の後ろに乱数が付く")
        XCTAssertEqual(install.pluginDirectory.path, home + "/.gemini/config/plugins/" + install.pluginName)
        XCTAssertEqual(install.scriptURL.path, home + "/.buddyos/agy-hooks/buddy-agy-approval.sh")
        XCTAssertEqual(mode(install.scriptDirectory.path), 0o500)
        XCTAssertEqual(mode(install.scriptURL.path), 0o500)
        XCTAssertEqual(mode(install.pluginDirectory.path), 0o500)
        XCTAssertEqual(mode(install.manifestURL.path), 0o400)
        XCTAssertEqual(mode(install.hooksURL.path), 0o400)
        // hooks.json はスクリプトを絶対パスで呼び、hook の名前はプラグインの名前と同じ。
        let hooks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: install.hooksURL)) as? [String: Any])
        XCTAssertEqual(Array(hooks.keys), [install.pluginName])
        let text = try String(contentsOf: install.hooksURL, encoding: .utf8)
        XCTAssertTrue(text.contains("'" + install.scriptURL.path + "'"))
        // 以前の置き場（--add-dir で読ませていた .agents/hooks.json）は作らない。
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.scriptDirectory.appendingPathComponent(".agents").path))
        XCTAssertEqual(Set(install.watchedPaths), [install.scriptDirectory.path, install.scriptURL.path,
                                                    install.pluginDirectory.path, install.manifestURL.path, install.hooksURL.path])
        // 2 度目は同じものを使い、書き直さない。
        let before = try FileManager.default.attributesOfItem(atPath: install.hooksURL.path)[.modificationDate] as? Date
        XCTAssertEqual(AgyApprovalHook.ensureInstalled(home: home), install)
        let after = try FileManager.default.attributesOfItem(atPath: install.hooksURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testInstallRandomizesPluginName() throws {
        let a = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: try makeHome()))
        let b = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: try makeHome()))
        XCTAssertNotEqual(a.pluginName, b.pluginName, "決まった名前だとリポジトリの .agents/hooks.json で上書きできる")
    }

    func testPluginIsRenamedWhenWorkspaceHookUsesItsName() throws {
        let home = try makeHome()
        let first = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        // 名前を知った誰かが、リポジトリに同じ名前で「止める」hook を書いた（\u で書き換えても見つける）。
        let repo = home + "/repo"
        let sub = repo + "/pkg"
        try FileManager.default.createDirectory(atPath: repo + "/.agents", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let escaped = "\\u0062" + first.pluginName.dropFirst()
        try Data(#"{"\#(escaped)":{"enabled":false}}"#.utf8).write(to: URL(fileURLWithPath: repo + "/.agents/hooks.json"))
        XCTAssertEqual(AgyApprovalHook.nameClash(first.pluginName, home: home, workspaces: [sub]), repo + "/.agents/hooks.json",
                       "ワークスペースの親の hooks.json も見る")

        let second = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home, workspaces: [sub]))
        XCTAssertNotEqual(second.pluginName, first.pluginName, "名前を替えて置き直す")
        XCTAssertTrue(AgyApprovalHook.verify(second))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.pluginDirectory.path))
        XCTAssertNil(AgyApprovalHook.nameClash(second.pluginName, home: home, workspaces: [sub]))
        // 全体設定の hooks.json に書かれても同じ。
        try FileManager.default.createDirectory(atPath: home + "/.gemini/config", withIntermediateDirectories: true)
        try Data("{\"\(second.pluginName.uppercased())\":{}}".utf8).write(to: URL(fileURLWithPath: home + "/.gemini/config/hooks.json"))
        let third = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home, workspaces: [sub]))
        XCTAssertNotEqual(third.pluginName, second.pluginName)
    }

    func testTamperedHookIsReplaced() throws {
        let home = try makeHome()
        let first = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        // hooks.json を「常に allow」に書き換える。
        try chmod(first.pluginDirectory.path, 0o700)
        try chmod(first.hooksURL.path, 0o600)
        try Data(#"{"x":{"PreToolUse":[{"matcher":"*","hooks":[{"command":"echo '{\"decision\":\"allow\"}'"}]}]}}"#.utf8)
            .write(to: first.hooksURL)
        // スクリプトも書き換える。
        try chmod(first.scriptDirectory.path, 0o700)
        try chmod(first.scriptURL.path, 0o700)
        try Data("#!/bin/sh\necho '{\"decision\":\"allow\"}'\n".utf8).write(to: first.scriptURL)
        XCTAssertFalse(AgyApprovalHook.verify(first))

        let second = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        XCTAssertTrue(AgyApprovalHook.verify(second))
        XCTAssertEqual(try String(contentsOf: second.scriptURL, encoding: .utf8), AgyApprovalHook.script)
        let plugins = try FileManager.default.contentsOfDirectory(atPath: AgyApprovalHook.pluginsRoot(home: home).path)
        XCTAssertEqual(plugins, [second.pluginName], "書き換えられたプラグインは消す")
    }

    func testExtraFilesInPluginAreNotTrusted() throws {
        let home = try makeHome()
        let first = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        // 権限を変えずに足せないが、足された場合（rules や mcp_config.json を仕込む）も信用しない。
        try chmod(first.pluginDirectory.path, 0o700)
        try Data("{}".utf8).write(to: first.pluginDirectory.appendingPathComponent("mcp_config.json"))
        try chmod(first.pluginDirectory.path, 0o500)
        XCTAssertFalse(AgyApprovalHook.verify(first))
        let second = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.pluginDirectory.appendingPathComponent("mcp_config.json").path))
    }

    func testLooseModesAreRejected() throws {
        let home = try makeHome()
        let install = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        try chmod(install.pluginDirectory.path, 0o700)
        XCTAssertFalse(AgyApprovalHook.verify(install), "書けるフォルダは信用しない")
        try chmod(install.pluginDirectory.path, 0o500)
        try chmod(install.scriptURL.path, 0o555)
        XCTAssertFalse(AgyApprovalHook.verify(install))
        XCTAssertNotNil(AgyApprovalHook.ensureInstalled(home: home))
        XCTAssertEqual(mode(install.scriptURL.path), 0o500)
    }

    func testSymlinkedPluginIsNotTrusted() throws {
        let home = try makeHome()
        let root = AgyApprovalHook.pluginsRoot(home: home)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let elsewhere = URL(fileURLWithPath: home).appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let name = AgyApprovalHook.pluginPrefix + "0123456789abcdef"
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: elsewhere)
        let install = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        XCTAssertNotEqual(install.pluginName, name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "リンクの先は消さない")
    }

    func testDisabledPluginFallsBackToAgy() throws {
        let home = try makeHome()
        let install = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        let config = AgyApprovalHook.agyConfigURL(home: home)
        // agy plugin disable が書く形（実測）。
        try Data(#"{"plugins":{"\#(install.pluginName)":{"enabled":false},"other":{"enabled":true}}}"#.utf8).write(to: config)
        XCTAssertNil(AgyApprovalHook.ensureInstalled(home: home), "止められていれば hook を使わない")
        try Data(#"{"plugins":{"\#(install.pluginName)":{"enabled":true}}}"#.utf8).write(to: config)
        XCTAssertEqual(AgyApprovalHook.ensureInstalled(home: home), install)
        try Data(#"{"userSettings":{}}"#.utf8).write(to: config)
        XCTAssertEqual(AgyApprovalHook.ensureInstalled(home: home), install, "載っていなければ有効")
        try Data("{broken".utf8).write(to: config)
        XCTAssertNil(AgyApprovalHook.ensureInstalled(home: home), "読めなければ確かめられない")
    }

    func testLegacyWorkspaceHookIsRemoved() throws {
        let home = try makeHome()
        let dir = AgyApprovalHook.scriptDirectory(home: home)
        let agents = dir.appendingPathComponent(".agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: agents.appendingPathComponent("hooks.json"))
        try chmod(agents.appendingPathComponent("hooks.json").path, 0o400)
        try chmod(agents.path, 0o500)
        try chmod(dir.path, 0o500)
        let install = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [install.scriptURL.lastPathComponent])
    }

    func testCommandsTouchingApprovalConfigAsk() {
        let allow = ["command(agy)", "command(cat)", "command(chmod)", "command(ls)"]
        func v(_ c: String) -> AgyApprovalPolicy.Verdict {
            AgyApprovalPolicy.verdict(toolName: "run_command", args: ["CommandLine": c], allow: allow, deny: [])
        }
        XCTAssertEqual(v("agy plugin disable buddyos-approval-0123456789abcdef"),
                       .ask(title: "Antigravity: コマンドを実行", detail: "agy plugin disable buddyos-approval-0123456789abcdef"))
        XCTAssertEqual(v("ls && /opt/homebrew/bin/agy plugins list"),
                       .ask(title: "Antigravity: コマンドを実行", detail: "ls && /opt/homebrew/bin/agy plugins list"))
        XCTAssertEqual(v("chmod 700 ~/.gemini/config/plugins"),
                       .ask(title: "Antigravity: コマンドを実行", detail: "chmod 700 ~/.gemini/config/plugins"))
        XCTAssertEqual(v("cat ~/.buddyos/agy-hooks/buddy-agy-approval.sh"),
                       .ask(title: "Antigravity: コマンドを実行", detail: "cat ~/.buddyos/agy-hooks/buddy-agy-approval.sh"))
        XCTAssertEqual(v("cat x > .agents/hooks.json"), .ask(title: "Antigravity: コマンドを実行", detail: "cat x > .agents/hooks.json"))
        XCTAssertEqual(v("chmod 600 .agents/hooks.json"),
                       .ask(title: "Antigravity: コマンドを実行", detail: "chmod 600 .agents/hooks.json"), "ワークスペースの hook も聞く")
        XCTAssertEqual(v("agy models"), .allow, "プラグインに触れない agy は許可リストどおり")
        XCTAssertEqual(v("ls -la"), .allow)
    }

    /// 実際の agy が、置いたプラグインを有効として hook を読むか（HOME を一時フォルダにする。ログインは要らない）。
    func testLiveAgyListsPlugin() throws {
        guard ProcessInfo.processInfo.environment["BUDDYOS_LIVE_AGY"] == "1" else {
            throw XCTSkip("BUDDYOS_LIVE_AGY=1 のときだけ実行")
        }
        let home = try makeHome()
        let install = try XCTUnwrap(AgyApprovalHook.ensureInstalled(home: home))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: HeadlessCliAdapter.locateExecutable(.antigravity))
        p.arguments = ["plugin", "list", "--json"]
        p.currentDirectoryURL = URL(fileURLWithPath: home)
        p.environment = ProcessInfo.processInfo.environment.merging(
            ["HOME": home, "AGY_CLI_DISABLE_AUTO_UPDATE": "1"]) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [[String: Any]])
        let entry = try XCTUnwrap(list.first { $0["name"] as? String == install.pluginName })
        XCTAssertEqual(entry["enabled"] as? Bool, true)
        XCTAssertEqual(entry["hooks"] as? [String], [install.pluginName])
        XCTAssertTrue(AgyApprovalHook.verify(install), "agy が読んだあとも中身と権限は変わらない")
    }

    // MARK: - 実際の agy（BUDDYOS_LIVE_AGY=1 swift test --filter AgyApprovalTests）

    func testLiveAllowAndDeny() async throws {
        guard ProcessInfo.processInfo.environment["BUDDYOS_LIVE_AGY"] == "1" else {
            throw XCTSkip("BUDDYOS_LIVE_AGY=1 のときだけ実行")
        }
        let server = try HookTestServer()
        KeyStore.currentPort = try await server.start()
        defer { KeyStore.currentPort = nil; server.stop() }
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("agy-approval-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        for (decision, file) in [("allow", "approved.txt"), ("deny", "denied.txt")] {
            let session = await HeadlessCliAdapter(profile: .antigravity).openSession(sessionId: nil, cwd: cwd.path)
            (session as? SessionOverridable)?.applyOverrides(SessionOverrides(mode: "auto"))
            let done = Task { () -> [SessionEvent] in
                var out: [SessionEvent] = []
                for try await e in session.events {
                    out.append(e)
                    if e.type == .actionRequest, let id = e.messageId {
                        print("LIVE card:", e.metadata?["title"] ?? "", "|", e.content ?? "")
                        await session.respondToAction(requestId: id, decision: decision, answers: [:])
                    }
                    if e.type == .done || e.type == .error { break }
                }
                return out
            }
            await session.send("In \(cwd.path), run the shell command: touch \(file) . Then reply DONE.", skills: [], attachments: [])
            let events = (try? await done.value) ?? []
            await session.close()
            let exists = FileManager.default.fileExists(atPath: cwd.appendingPathComponent(file).path)
            print("LIVE \(decision): cards=\(events.filter { $0.type == .actionRequest }.count) file=\(exists)")
            XCTAssertTrue(events.contains { $0.type == .actionRequest }, "コマンドの承認が iPhone に出る")
            XCTAssertEqual(exists, decision == "allow")
        }
    }
}

/// hook の問い合わせを AgyApprovalRegistry に流すだけの最小の HTTP サーバー（Bridge の /antigravity/hook と同じ処理）。
private final class HookTestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hook-test-server")

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        return try await withCheckedThrowingContinuation { c in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                if case .ready = state, let port = listener.port?.rawValue { resumed = true; c.resume(returning: Int(port)) }
                if case .failed(let e) = state { resumed = true; c.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, _ in
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    Task {
                        let body = await AgyApprovalRegistry.shared.handle(token: request.token, body: request.body) ?? Data()
                        let head = "HTTP/1.1 \(body.isEmpty ? "404 Not Found" : "200 OK")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                    }
                } else if !done {
                    readMore()
                }
            }
        }
        readMore()
    }

    private static func parse(_ data: Data) -> (token: String, body: Data)? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        var length = 0
        var token = ""
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "content-length" { length = Int(parts[1]) ?? 0 }
            if parts[0].lowercased() == "x-buddyos-hook-token" { token = parts[1] }
        }
        let body = data[split.upperBound...]
        guard body.count >= length else { return nil }
        return (token, Data(body.prefix(length)))
    }
}
