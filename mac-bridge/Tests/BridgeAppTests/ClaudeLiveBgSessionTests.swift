import XCTest
@testable import BridgeApp

/// 本物の claude --bg で、一覧・会話・受け箱の送信・停止・削除を確かめる手動実行のテスト。
/// `BUDDYOS_LIVE_CLAUDE_BG=1 swift test --filter ClaudeLiveBgSessionTests` のときだけ走る（ログイン済みの Mac で、haiku を使う）。
/// 一時フォルダで `claude --bg` を起こし、最後に `claude rm` と `claude purge -y` で片付ける。
final class ClaudeLiveBgSessionTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["BUDDYOS_LIVE_CLAUDE_BG"] == "1" else {
            throw XCTSkip("BUDDYOS_LIVE_CLAUDE_BG=1 のときだけ実行")
        }
    }

    /// `claude agents --json` から、作業フォルダが cwd のジョブの id を拾う（片付け用）。
    private static func jobIds(exe: String, env: [String: String], cwd: String) -> [String] {
        guard let out = ProcessRunner.run(exe, ["agents", "--json"], timeout: 30, environment: env),
              let list = try? JSONSerialization.jsonObject(with: out.stdout) as? [[String: Any]]
        else { return [] }
        return list.compactMap { job in
            guard job["cwd"] as? String == cwd, let sid = job["sessionId"] as? String else { return nil }
            return (job["id"] as? String) ?? String(sid.prefix(8))
        }
    }

    private func until(_ what: String, timeout: TimeInterval, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTFail("待ちきれなかった: \(what)")
    }

    func testBackgroundSessionLifecycle() async throws {
        try requireLive()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("bg-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        // CLI は実体のパス（/private/var/…）を記録する。resolvingSymlinksInPath は /private を外すので realpath で比べる。
        let cwdPath = realpath(cwd.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? cwd.path

        let jobs = ClaudeBackgroundJobs(config: .live(home: home))
        let exe = ClaudeCodeAdapter.locateExecutable()
        let env = ChildEnvironment.base(merging: ["BUDDYOS_SPAWNED": "1"])
        let started = ProcessRunner.run(
            exe, ["--bg", "--model", "haiku", "--setting-sources", "project,local",
                  "reply with the single word ready, then stop"],
            timeout: 60, environment: env, currentDirectory: cwd.path)
        XCTAssertEqual(started?.status, 0)

        // 一覧: working → done
        var row: BgRow?
        // 一覧に出る前に落ちても片付ける。id が分からなければ CLI の一覧から一時フォルダのジョブを探す。
        defer {
            let ids = row.map { [$0.id] } ?? Self.jobIds(exe: exe, env: env, cwd: cwdPath)
            for id in ids {
                _ = ProcessRunner.run(exe, ["rm", id], timeout: 30, environment: env, currentDirectory: cwd.path)
            }
            _ = ProcessRunner.run(exe, ["purge", "-y", cwdPath], timeout: 30, environment: env, currentDirectory: cwd.path)
        }
        try await until("job listed", timeout: 60) {
            await jobs.refresh()
            row = await jobs.rows().first { $0.cwd == cwdPath }
            return row != nil
        }
        let id = try XCTUnwrap(row?.id), sessionId = try XCTUnwrap(row?.sessionId)
        try await until("first work done", timeout: 120) {
            await jobs.refresh()
            return await jobs.rows().first { $0.id == id }?.state == .done
        }

        // 会話: ワーカーが生きていれば受け箱で続けられる
        let adapter = ClaudeCodeAdapter()
        let opened = await adapter.openBackgroundSession(sessionId: sessionId, jobs: jobs)
        let session = try XCTUnwrap(opened)
        let seen = LockedBox<[SessionEvent]>([])
        Task { do { for try await e in session.events { seen.update { $0.append(e) } } } catch {} }
        await session.send("reply with the single word again", skills: [], attachments: [])
        try await until("done after send", timeout: 120) {
            seen.value.contains { $0.type == .done && $0.metadata?["errored"] == nil }
        }
        XCTAssertTrue(seen.value.contains { $0.type == .assistantDelta })

        // 停止と削除
        let stopped = await jobs.operate(.stop, id: id, sessionId: sessionId)
        XCTAssertTrue(stopped.ok, stopped.text)
        let deleted = await jobs.operate(.delete, id: id, sessionId: sessionId)
        XCTAssertTrue(deleted.ok, deleted.text)
        await session.close()
    }
}
