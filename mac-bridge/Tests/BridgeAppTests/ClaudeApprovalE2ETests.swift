import XCTest
@testable import BridgeApp

/// 実 claude（haiku）で、iPhone から見た承認・質問・画像の流れを通す E2E。
/// claude の利用枠を少し使うので RUN_CLAUDE_E2E=1 のときだけ走らせる。
///
/// 通常の iPhone セッションと同じ ClaudeCodeSession を使い、承認カード（actionRequest）が出て、
/// respondToAction の返事で実際にコマンドが実行される／されないことを、ファイルの有無で確かめる。
/// 履歴はテスト用の一時フォルダ（BuddyPaths）に書かれ、本物の ~/.buddyos の一覧には増えない。
final class ClaudeApprovalE2ETests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUN_CLAUDE_E2E"] == "1"
    }

    private var workDir: URL!
    private var session: ClaudeCodeSession!
    private var log: ClaudeEventLog!
    private var pump: Task<Void, Never>?

    override func setUpWithError() throws {
        try XCTSkipUnless(enabled, "set RUN_CLAUDE_E2E=1 to run (uses real claude, haiku)")
        setenv("BUDDYOS_CLAUDE_MODEL", "haiku", 1)
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        log = ClaudeEventLog()
        // 承認は iPhone に尋ねる + 権限モードは default（Bash は承認が要る）。ユーザーの claude.mode には依存しない。
        session = ClaudeCodeSession(
            agentId: "claude", profile: .claude, initialSessionId: nil, cwd: workDir.path,
            executable: ClaudeCodeAdapter.locateExecutable(), store: .shared,
            permissionOverride: "auto", permissionPrompts: true)
        let events = session.events
        let log = self.log!
        pump = Task { do { for try await e in events { await log.add(e) } } catch {} }
    }

    override func tearDown() async throws {
        pump?.cancel()
        if let session { await session.close() }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        unsetenv("BUDDYOS_CLAUDE_MODEL")
    }

    private func file(_ name: String) -> URL { workDir.appendingPathComponent(name) }

    private func ask(_ prompt: String) {
        let s = session!
        Task { await s.send(prompt, skills: [], attachments: []) }
    }

    func testAllowRunsTheCommand() async throws {
        ask("Use the Bash tool to run exactly: echo approved > approved.txt   Then reply DONE.")
        let card = try await log.waitForCard(timeout: 120)
        XCTAssertEqual(card.metadata?["kind"], "approval")
        XCTAssertTrue((card.metadata?["title"] ?? "").contains("Bash"), "ツール名が出る: \(card.metadata ?? [:])")
        XCTAssertTrue((card.metadata?["subtitle"] ?? "").contains("echo approved"), "コマンドが出る")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("approved.txt").path), "返事の前は実行されない")

        await session.respondToAction(requestId: card.messageId ?? "", decision: "allow", answers: [:])
        try await log.waitForDone(count: 1, timeout: 120)
        XCTAssertEqual(try? String(contentsOf: file("approved.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "approved", "許可したので実行された")
        let resolved = await log.resolvedIds()
        XCTAssertTrue(resolved.contains(card.messageId ?? ""), "返事のあと action_resolved が出る")
    }

    func testDenyBlocksTheCommand() async throws {
        ask("Use the Bash tool to run exactly: echo approved > approved.txt   Then reply DONE.")
        let card = try await log.waitForCard(timeout: 120)
        await session.respondToAction(requestId: card.messageId ?? "", decision: "deny", answers: [:])
        try await log.waitForDone(count: 1, timeout: 120)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("approved.txt").path), "拒否したので実行されない")
        let errors = await log.errors()
        XCTAssertTrue(errors.isEmpty, "拒否はエラーにならない: \(errors)")
    }

    func testAllowForSessionSkipsTheNextPrompt() async throws {
        // `>` でファイルに書く操作は別の種類の承認が要り、毎回聞かれる（claude の仕様）。
        // ここでは書き込み系で承認が要るが、リダイレクトを使わない mkdir を使う。
        ask("Use the Bash tool to run exactly: mkdir d1   Then reply DONE.")
        let card = try await log.waitForCard(timeout: 120)
        XCTAssertEqual(card.metadata?["option_1_value"], "allowForSession", "同種の操作を続けて許可する選択肢が出る")
        await session.respondToAction(requestId: card.messageId ?? "", decision: "allowForSession", answers: [:])
        try await log.waitForDone(count: 1, timeout: 120)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file("d1").path))
        let cardsAfterFirst = await log.cardCount()

        // 同じ種類の操作は、もう尋ねられずに実行される。
        ask("Use the Bash tool to run exactly: mkdir d2   Then reply DONE.")
        try await log.waitForDone(count: 2, timeout: 120)
        let cardsAfterSecond = await log.cardCount()
        XCTAssertEqual(cardsAfterSecond, cardsAfterFirst, "2 回目は承認カードが出ない")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file("d2").path), "2 回目も実行された")
        // 許可が session 止まりで、プロジェクトの設定ファイルに残っていない
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.appendingPathComponent(".claude/settings.local.json").path),
                       "settings.local.json に許可が書かれていない")
    }

    /// 比較用: 「承認」（一度だけ）なら、同種の 2 回目もまた尋ねられる。
    func testAllowOnceAsksAgainNextTime() async throws {
        ask("Use the Bash tool to run exactly: mkdir d1   Then reply DONE.")
        let first = try await log.waitForCard(timeout: 120)
        await session.respondToAction(requestId: first.messageId ?? "", decision: "allow", answers: [:])
        try await log.waitForDone(count: 1, timeout: 120)

        ask("Use the Bash tool to run exactly: mkdir d2   Then reply DONE.")
        let deadline = Date().addingTimeInterval(120)
        while await log.cardCount() < 2, Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        let cards = await log.cardCount()
        XCTAssertEqual(cards, 2, "一度だけの許可なので、2 回目もカードが出る")
        let second = await log.cards().last
        await session.respondToAction(requestId: second?.messageId ?? "", decision: "deny", answers: [:])
        try await log.waitForDone(count: 2, timeout: 120)
    }

    /// Claude が選択肢つきで質問してきたら、iPhone の選択（または自由記述）が答えとして届く。
    func testQuestionAnswerReachesClaude() async throws {
        ask("Use the AskUserQuestion tool to ask me whether I prefer option Alpha or option Beta (give both as options). After I answer, reply with exactly: CHOSEN=<my answer>")
        let card = try await log.waitForCard(timeout: 120)
        XCTAssertEqual(card.metadata?["kind"], "userInput")
        XCTAssertEqual(card.metadata?["option_count"], "2")
        let beta = [card.metadata?["option_0_value"], card.metadata?["option_1_value"]].compactMap { $0 }.first { $0.contains("Beta") }
        await session.respondToAction(requestId: card.messageId ?? "", decision: beta ?? "Beta", answers: [:])
        try await log.waitForDone(count: 1, timeout: 120)
        let text = await log.assistantText()
        XCTAssertTrue(text.contains("Beta"), "選んだ答えが Claude に届く: \(text)")
    }

    func testImageReachesTheModel() async throws {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAS0lEQVR42u3PQQkAAAgAsetfWiP4FgYrsKZeS0BAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEDgsqnc8OJg6Ln3AAAAAElFTkSuQmCC")!
        // 名前に色を入れない（ファイル名から答えを推測されないように）
        let image = BridgeAttachment(kind: .image, name: "photo.png", mime: "image/png", data: png)
        await session.send("What single color fills this image? Answer with just the color name.",
                           skills: [], attachments: [image])
        try await log.waitForDone(count: 1, timeout: 120)
        let text = await log.assistantText().lowercased()
        XCTAssertTrue(text.contains("red"), "画像の中身（赤）が答えに出る: \(text)")
    }
}

private actor ClaudeEventLog {
    private var events: [SessionEvent] = []

    func add(_ e: SessionEvent) { events.append(e) }

    func cardCount() -> Int { events.filter { $0.type == .actionRequest }.count }
    func cards() -> [SessionEvent] { events.filter { $0.type == .actionRequest } }
    func resolvedIds() -> [String] { events.filter { $0.type == .actionResolved }.compactMap(\.messageId) }
    func errors() -> [String] { events.filter { $0.type == .error }.compactMap(\.content) }
    func assistantText() -> String { events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined() }
    private func doneCount() -> Int { events.filter { $0.type == .done }.count }

    func waitForCard(timeout: TimeInterval) async throws -> SessionEvent {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let card = events.first(where: { $0.type == .actionRequest }) { return card }
            if let err = events.first(where: { $0.type == .error }) {
                XCTFail("error が先に出た: \(err.content ?? "")"); throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("承認カードが来ない（events: \(events.map { $0.type.rawValue })）")
        throw CancellationError()
    }

    func waitForDone(count n: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if doneCount() >= n { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("done が \(n) 回来ない（\(doneCount()) 回。events: \(events.map { $0.type.rawValue })）")
    }
}
