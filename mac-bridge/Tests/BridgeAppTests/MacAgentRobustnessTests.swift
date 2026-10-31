import XCTest
@testable import BridgeApp

/// Mac 側の不具合（jobs.json・無人実行の承認・同期ブロック・AcpClient の stdin・hook の見張り・Hermes）の回帰テスト。
final class MacAgentRobustnessTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-robust-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 読み取り専用にしたものも消せるよう戻してから消す。
        if let e = FileManager.default.enumerator(atPath: tmp.path) {
            for case let rel as String in e {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.appendingPathComponent(rel).path)
            }
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - jobs.json

    private func job(_ id: String) -> [String: Any] {
        ["id": id, "agentId": "claude", "name": "n-\(id)", "prompt": "p", "schedule": "30m",
         "deliver": "local", "enabled": true, "createdAt": "2026-10-01T00:00:00Z", "runsCompleted": 0]
    }

    private func write(_ object: Any, to path: String) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: path))
    }

    private func backups(of path: String) -> [String] {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(name + ".broken-") }
    }

    func testMissingJobsFileIsEmptyAndSavable() {
        let r = BridgeCronScheduler.loadJobs(at: tmp.appendingPathComponent("none.json").path)
        XCTAssertTrue(r.jobs.isEmpty)
        XCTAssertNil(r.backupPath)
        XCTAssertFalse(r.saveBlocked)
    }

    func testValidJobsLoadWithoutBackup() throws {
        let path = tmp.appendingPathComponent("jobs.json").path
        try write([job("aaaaaaaa"), job("bbbbbbbb")], to: path)
        let r = BridgeCronScheduler.loadJobs(at: path)
        XCTAssertEqual(r.jobs.map(\.id), ["aaaaaaaa", "bbbbbbbb"])
        XCTAssertNil(r.backupPath)
        XCTAssertTrue(backups(of: path).isEmpty)
    }

    /// 1 件壊れていても残りは使い、元のファイルは退避する（次の保存で壊れた 1 件を失わないように）。
    func testBrokenElementKeepsOthersAndBacksUp() throws {
        let path = tmp.appendingPathComponent("jobs.json").path
        var broken = job("cccccccc")
        broken.removeValue(forKey: "prompt")
        try write([job("aaaaaaaa"), broken, job("bbbbbbbb")], to: path)
        let r = BridgeCronScheduler.loadJobs(at: path)
        XCTAssertEqual(r.jobs.map(\.id), ["aaaaaaaa", "bbbbbbbb"])
        XCTAssertFalse(r.saveBlocked)
        let backup = try XCTUnwrap(r.backupPath)
        XCTAssertEqual(FileManager.default.contents(atPath: backup), FileManager.default.contents(atPath: path))
    }

    func testUnparsableFileIsBackedUp() throws {
        let path = tmp.appendingPathComponent("jobs.json").path
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        let r = BridgeCronScheduler.loadJobs(at: path)
        XCTAssertTrue(r.jobs.isEmpty)
        XCTAssertFalse(r.saveBlocked)
        XCTAssertEqual(backups(of: path).count, 1)
    }

    /// 読めず、退避もできなければ保存を止める（元のファイルを上書きしない）。
    func testUnreadableAndUnbackupableBlocksSaving() throws {
        let dir = tmp.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("jobs.json").path
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        let r = BridgeCronScheduler.loadJobs(at: path)
        XCTAssertTrue(r.jobs.isEmpty)
        XCTAssertTrue(r.saveBlocked)
    }

    // MARK: - 無人実行の承認

    func testUnattendedDecisionPicksDenyOption() {
        let claude: [String: String] = ["kind": "approval", "option_count": "2",
                                        "option_0_value": "allow", "option_1_value": "deny"]
        XCTAssertEqual(BridgeCronScheduler.unattendedDecision(metadata: claude), "deny")
        let codex: [String: String] = ["kind": "approval", "option_count": "3", "option_0_value": "accept",
                                       "option_1_value": "acceptForSession", "option_2_value": "decline"]
        XCTAssertEqual(BridgeCronScheduler.unattendedDecision(metadata: codex), "decline")
        let opencode: [String: String] = ["option_count": "3", "option_0_value": "once",
                                          "option_1_value": "always", "option_2_value": "reject"]
        XCTAssertEqual(BridgeCronScheduler.unattendedDecision(metadata: opencode), "reject")
    }

    /// 質問や「断る」選択肢の無いカードには、答える人が居ないことを伝える文で返す。
    func testUnattendedDecisionForQuestionsIsNotice() {
        let question: [String: String] = ["kind": "userInput", "option_count": "2",
                                          "option_0_value": "A", "option_1_value": "deny"]
        XCTAssertEqual(BridgeCronScheduler.unattendedDecision(metadata: question), BridgeCronScheduler.unattendedNotice)
        let acp: [String: String] = ["kind": "approval", "option_count": "1", "option_0_value": "proceed_once"]
        XCTAssertEqual(BridgeCronScheduler.unattendedDecision(metadata: acp), BridgeCronScheduler.unattendedNotice)
    }

    /// 権限が「エージェント設定に従う」（permissionMode = nil）の定期実行でも、claude に iPhone へ尋ねさせない。
    func testClaudeUnattendedDoesNotUsePromptTool() async throws {
        let adapter = ClaudeCodeAdapter(executable: "/usr/bin/false")
        let cron = await adapter.openSession(sessionId: nil, cwd: tmp.path,
                                             options: SessionOptions(permissionMode: nil, unattended: true))
        let cronArgs = try XCTUnwrap(cron as? ClaudeCodeSession).sessionArgs()
        XCTAssertFalse(cronArgs.contains("--permission-prompt-tool"))
        let chat = await adapter.openSession(sessionId: nil, cwd: tmp.path, options: nil)
        let chatArgs = try XCTUnwrap(chat as? ClaudeCodeSession).sessionArgs()
        if ProcessInfo.processInfo.environment["BUDDYOS_CLAUDE_PERMISSION_PROMPTS"] != "0" {
            XCTAssertTrue(chatArgs.contains("--permission-prompt-tool"), "チャットは従来どおり尋ねる")
        }
        await cron.close()
        await chat.close()
    }

    /// cron の無人実行で ACP が承認を求めても、iPhone に出さずに拒否で即答する。
    func testAcpUnattendedRejectsWithoutAsking() {
        let options: [(id: String, kind: String)] = [("a", "allow_once"), ("r", "reject_once")]
        XCTAssertEqual(AcpSession.autoPermissionAnswer(mode: nil, toolKind: "execute", unattended: true, options: options), "r")
        XCTAssertNil(AcpSession.autoPermissionAnswer(mode: nil, toolKind: "execute", unattended: false, options: options))
    }

    // MARK: - 同期ブロック

    func testRunAsyncAndOffload() async {
        let r = await ProcessRunner.runAsync("/bin/sh", ["-c", "echo hi"], timeout: 5)
        XCTAssertEqual(r.map { String(decoding: $0.stdout, as: UTF8.self) }, "hi\n")
        let v = await ProcessRunner.offload { 21 * 2 }
        XCTAssertEqual(v, 42)
    }

    func testGitBranchAsync() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { throw XCTSkip("git がない") }
        let repo = tmp.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let r = ProcessRunner.run("/usr/bin/git", ["-C", repo, "init", "-q", "-b", "buddy-test"], timeout: 20)
        let c = ProcessRunner.run("/usr/bin/git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com",
                                                   "commit", "-q", "--allow-empty", "-m", "x"], timeout: 20)
        guard r?.status == 0, c?.status == 0 else { throw XCTSkip("git が使えない") }
        let branch = await GitInfoReader.branch(cwd: repo)
        XCTAssertEqual(branch, "buddy-test")
        let none = await GitInfoReader.branch(cwd: tmp.appendingPathComponent("missing").path)
        XCTAssertNil(none)
    }

    // MARK: - AcpClient の stdin 書き込み

    /// 大きな行を書いている間も stdout を読み続ける（lock を握ったまま書くと、cat のように
    /// 読んだ分を書き返す相手と互いに待ち合って止まる）。
    func testLargeRequestDoesNotDeadlock() async throws {
        let client = AcpClient(executable: "/bin/cat", args: [], env: [:])
        try client.start()
        defer { client.close() }
        let big = String(repeating: "x", count: 2_000_000)
        // cat は request をそのまま返す → method 付きなので「Method not found」を書き返す → それが応答になる。
        let result = try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { try await client.request("test/echo", params: ["blob": big]) }
            group.addTask { try await Task.sleep(nanoseconds: 15_000_000_000); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let response = try XCTUnwrap(result, "15 秒以内に戻らなかった（stdin と stdout が待ち合っている）")
        XCTAssertNotNil(response["error"])
    }

    func testRequestAfterCloseFails() async throws {
        let client = AcpClient(executable: "/bin/cat", args: [], env: [:])
        try client.start()
        client.close()
        do {
            _ = try await client.request("x", params: [:])
            XCTFail("閉じた後は失敗するはず")
        } catch {}
    }

    // MARK: - hook の見張り

    private func makeHookFiles() throws -> [String] {
        let dir = tmp.appendingPathComponent("hooks", isDirectory: true)
        let agents = dir.appendingPathComponent(".agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("hook.sh")
        let config = agents.appendingPathComponent("hooks.json")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
        try Data("{}".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: script.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: config.path)
        return [dir.path, agents.path, script.path, config.path]
    }

    private func waitTripped(_ watch: AgyHookTamperWatch, seconds: Double = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if watch.tripped { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return watch.tripped
    }

    func testHookWatchIgnoresReadsAndRuns() async throws {
        let paths = try makeHookFiles()
        let watch = AgyHookTamperWatch(paths: paths, executables: [paths[2]]) {}
        defer { watch.cancel() }
        XCTAssertTrue(watch.isComplete)
        _ = FileManager.default.contents(atPath: paths[3])
        _ = try FileManager.default.contentsOfDirectory(atPath: paths[0])
        _ = ProcessRunner.run(paths[2], [], timeout: 5)
        let tripped = await waitTripped(watch, seconds: 0.5)
        XCTAssertFalse(tripped, "読む・実行するだけでは止めない")
    }

    func testHookWatchTripsOnChmod() async throws {
        let paths = try makeHookFiles()
        let fired = expectation(description: "onChange")
        let watch = AgyHookTamperWatch(paths: paths, executables: [paths[2]]) { fired.fulfill() }
        defer { watch.cancel() }
        // hook のフォルダを書けるようにする（差し替えの前段）。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths[0])
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertTrue(watch.tripped)
    }

    /// スクリプトの中身の書き換え（属性の変化を見ないスクリプトでも、書き込みで見つける）。
    func testHookWatchTripsOnScriptWrite() async throws {
        let paths = try makeHookFiles()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths[2])
        let watch = AgyHookTamperWatch(paths: paths, executables: [paths[2]]) {}
        defer { watch.cancel() }
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: paths[2]))
        try h.write(contentsOf: Data("#!/bin/sh\necho '{\"decision\":\"allow\"}'\n".utf8))
        try h.close()
        let tripped = await waitTripped(watch)
        XCTAssertTrue(tripped)
    }

    func testHookWatchTripsOnConfigChmod() async throws {
        let paths = try makeHookFiles()
        let watch = AgyHookTamperWatch(paths: paths, executables: [paths[2]]) {}
        defer { watch.cancel() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths[3])
        let tripped = await waitTripped(watch)
        XCTAssertTrue(tripped)
    }

    func testHookWatchIncompleteWhenMissing() throws {
        let watch = AgyHookTamperWatch(paths: [tmp.appendingPathComponent("nope").path]) {}
        defer { watch.cancel() }
        XCTAssertFalse(watch.isComplete)
    }

    // MARK: - Hermes

    /// interrupt で hermes（zsh の下の子孫ごと）を止め、エラーではなく done で畳む。
    func testHermesInterruptStopsProcess() async throws {
        let fake = tmp.appendingPathComponent("fake-hermes")
        let marker = tmp.appendingPathComponent("alive").path
        try Data("#!/bin/sh\necho 'session_id: 20261015_000000_abcd'\necho started\nwhile true; do touch '\(marker)'; sleep 0.2; done\n".utf8)
            .write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let session = HermesSession(initialSessionId: nil, executable: fake.path)
        let collected = Task { () -> [SessionEventType] in
            var types: [SessionEventType] = []
            for try await e in session.events {
                types.append(e.type)
                if e.type == .done { break }
            }
            return types
        }
        let sender = Task { await session.send("hi", skills: []) }
        // 出力が届くまで待つ（zsh -l の起動に数秒かかることがある）。
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker), "fake hermes が起動しなかった")
        XCTAssertEqual(session.sessionId, "20261015_000000_abcd")
        await session.interrupt()
        await sender.value
        let types = try await collected.value
        XCTAssertEqual(types.last, .done)
        XCTAssertFalse(types.contains(.error), "停止はエラーにしない")
        // 子孫（while ループ）も止まっている。
        try FileManager.default.removeItem(atPath: marker)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "子孫が生き残っている")
        await session.close()
    }
}
