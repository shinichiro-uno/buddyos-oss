import Darwin
import XCTest
@testable import BridgeApp

/// 人が打った発話を、デスクトップのアプリ内ターミナルの claude に打ち込む流れ（docs/PTY_TYPING_2026-10-23.md）。実 claude は使わない。
/// デスクトップの pty はテストの親プロセスの pid で名乗る（TerminalPromptTests が自分の pid で名乗る分と混ざらないように）。
final class TerminalTypingTests: XCTestCase {

    private let start = TerminalKeyPlan.pasteStart
    private let end = TerminalKeyPlan.pasteEnd

    // MARK: - キーの列

    func testTypingPastesThenPressesEnter() {
        XCTAssertEqual(TerminalKeyPlan.typing("こんにちは\n二行目"), [start + "こんにちは\n二行目" + end, "\r"])
    }

    /// ESC で貼り付けを閉じて続きをキー操作として打たせない。\r は Enter になってしまうので \n にそろえる。
    func testTypingDropsControlCharacters() throws {
        let keys = try XCTUnwrap(TerminalKeyPlan.typing("a\u{1b}[201~\rrm -rf ~\r\nb\u{7}\u{9b}c\td\u{7f}"))
        XCTAssertEqual(keys, [start + "a[201~\nrm -rf ~\nbc\td" + end, "\r"])
        let body = keys[0].dropFirst(start.count).dropLast(end.count)
        XCTAssertFalse(body.contains("\u{1b}"))
        XCTAssertFalse(body.contains("\r"))
    }

    /// 先頭が ! だと Claude Code はシェルのコマンドとしてすぐ実行する。空白を付けて普通の発話にする。
    func testTypingKeepsBangFromRunningAsShellCommand() {
        XCTAssertEqual(TerminalKeyPlan.typing("!git status")?.first, start + " !git status" + end)
        XCTAssertEqual(TerminalKeyPlan.typing("見て !important")?.first, start + "見て !important" + end)
    }

    func testTypingNothingIsNil() {
        XCTAssertNil(TerminalKeyPlan.typing(""))
        XCTAssertNil(TerminalKeyPlan.typing(" \n\t "))
        XCTAssertNil(TerminalKeyPlan.typing("\u{1b}\u{7}"))
    }

    /// 長い文は 1 つの貼り付けのまま途中で分ける。文字（絵文字のサロゲート）の途中では分けない。
    func testTypingSplitsLongTextInsideOnePaste() throws {
        let text = String(repeating: "a", count: 7995) + String(repeating: "😀", count: 10) + String(repeating: "あ", count: 9000)
        let keys = try XCTUnwrap(TerminalKeyPlan.typing(text))
        XCTAssertGreaterThanOrEqual(keys.count, 3)
        XCTAssertEqual(keys.last, "\r")
        let chunks = keys.dropLast()
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= TerminalKeyPlan.typingChunk })
        XCTAssertEqual(chunks.joined(), start + text + end)
        XCTAssertTrue(chunks.first!.hasPrefix(start))
        XCTAssertTrue(chunks.last!.hasSuffix(end))
        XCTAssertEqual(chunks.filter { $0.contains(start) }.count, 1)
    }

    /// デスクトップが 1 回で受け付ける操作の数を超えるなら打ち込まない（呼び元は受け箱へ）。
    func testTypingTooLongIsNil() {
        XCTAssertNil(TerminalKeyPlan.typing(String(repeating: "x", count: TerminalKeyPlan.typingChunk * TerminalKeyPlan.relayMaxKeys)))
    }

    func testSlashCommandName() {
        XCTAssertEqual(ClaudeTerminalRegistry.slashCommand("/compact"), "/compact")
        XCTAssertEqual(ClaudeTerminalRegistry.slashCommand("  /model sonnet"), "/model")
        XCTAssertEqual(ClaudeTerminalRegistry.slashCommand("/plugin:cmd 引数"), "/plugin:cmd")
        XCTAssertNil(ClaudeTerminalRegistry.slashCommand("/Users/me/bar を見て"))
        XCTAssertNil(ClaudeTerminalRegistry.slashCommand("見て /compact"))
    }

    // MARK: - 宛先

    /// 打ち込みは、expectPid を確かめてから書くデスクトップ（typing=1）にだけ送る。古いデスクトップには選択肢の答えだけ。
    func testTypingOwnerNeedsTypingDesktop() async throws {
        let parent = getppid()
        let legacy = Task { await TerminalKeyRouter.shared.poll(client: "typing-legacy", pids: [parent], timeout: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        // 選択肢の答えは送れる（TerminalPromptTests が自分の pid で名乗った分が残っていれば、そちらが見つかる）。
        let any = await TerminalKeyRouter.shared.ptyOwner(of: getpid())
        let typing = await TerminalKeyRouter.shared.typingOwner(of: getpid())
        XCTAssertNotNil(any)
        XCTAssertNil(typing)
        _ = await legacy.value
        // 同じデスクトップが typing=1 で名乗り直せば打ち込める。
        let modern = Task { await TerminalKeyRouter.shared.poll(client: "typing-legacy", pids: [parent], canType: true, timeout: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let typingNow = await TerminalKeyRouter.shared.typingOwner(of: getpid())
        XCTAssertEqual(typingNow, parent)
        _ = await modern.value
        // 片付け: 打ち込めないデスクトップとして名乗っておく（後のテストに残さない）。
        _ = await TerminalKeyRouter.shared.poll(client: "typing-legacy", pids: [], timeout: 0.01)
    }

    // MARK: - 打ち込み

    func testTypePromptSendsKeysWithExpectedClaude() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-typing-" + UUID().uuidString
        let me = getpid()
        let parent = getppid()
        let poller = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop", pids: [parent], canType: true, timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await registry.register(sessionId: sid, cwd: "/tmp", pid: me, transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        await registry.setStatusReader { _, _ in "idle" }

        let outcome = await registry.typePrompt(sessionId: sid, text: "テストを実行して", echo: "テストを実行して")
        XCTAssertEqual(outcome, .typed)
        let delivered = await poller.value
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.pid, parent)
        XCTAssertEqual(delivered.first?.expectPid, me)
        XCTAssertEqual(delivered.first?.expectSession, sid)
        XCTAssertEqual(delivered.first?.gapMs, TerminalKeyPlan.typingGapMs)
        XCTAssertEqual(delivered.first?.keys, TerminalKeyPlan.typing("テストを実行して"))
        await releaseDesktop("typing-desktop")
    }

    func testTypePromptIsUnavailableWithoutTypingDesktop() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-typing-" + UUID().uuidString
        await registry.register(sessionId: sid, cwd: "/tmp", pid: getpid(), transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        let poller = Task { await TerminalKeyRouter.shared.poll(client: "typing-old-desktop", pids: [getppid()], timeout: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let outcome = await registry.typePrompt(sessionId: sid, text: "こんにちは", echo: "こんにちは")
        XCTAssertEqual(outcome, .unavailable)
        _ = await poller.value
        await releaseDesktop("typing-old-desktop")
    }

    /// 選択肢が出ている間は、打った Enter で選んでしまうので打たない。
    func testTypePromptRefusesWhileChoiceIsOpen() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-typing-" + UUID().uuidString
        let poller = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop-2", pids: [getppid()], canType: true, timeout: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await registry.register(sessionId: sid, cwd: "/tmp", pid: getpid(), transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        // 見ている画面があることにする（無いと選択肢の push を送りに行く）。
        let session = ClaudeTerminalSession(agentId: "claude", sessionId: sid)
        await registry.attach(session)
        await registry.setStatusReader { _, _ in "idle" }
        let handled = await registry.ingestPermission([
            "session_id": sid, "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": ["command": "rm -rf build", "description": "clean"],
        ])
        XCTAssertTrue(handled)
        let outcome = await registry.typePrompt(sessionId: sid, text: "続けて", echo: "続けて")
        XCTAssertEqual(outcome, .dialogOpen)
        let delivered = await poller.value
        XCTAssertTrue(delivered.isEmpty)
        await releaseDesktop("typing-desktop-2")
    }

    /// ターミナル側のターンの途中は打たず、終わってから打つ。
    func testTypePromptWaitsForTurnToEnd() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-typing-" + UUID().uuidString
        await registry.register(sessionId: sid, cwd: "/tmp", pid: getpid(), transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        let status = StatusBox("busy")
        await registry.setStatusReader { _, _ in status.get() }
        _ = await registry.ingest(["session_id": sid, "hook_event_name": "UserPromptSubmit", "prompt": "ターミナルで打った依頼"])
        let poller = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop-3", pids: [getppid()], canType: true, timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)

        let typing = Task { await registry.typePrompt(sessionId: sid, text: "次はこれ", echo: "次はこれ") }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        status.set("idle")
        _ = await registry.ingest(["session_id": sid, "hook_event_name": "Stop", "last_assistant_message": "終わりました"])
        let outcome = await typing.value
        XCTAssertEqual(outcome, .typed)
        let delivered = await poller.value
        XCTAssertEqual(delivered.first?.keys, TerminalKeyPlan.typing("次はこれ"))
        await releaseDesktop("typing-desktop-3")
    }

    func testTypePromptGivesUpWhenTurnDoesNotEnd() async throws {
        let registry = ClaudeTerminalRegistry()
        await registry.setTypingBusyWait(1)
        let sid = "test-typing-" + UUID().uuidString
        await registry.register(sessionId: sid, cwd: "/tmp", pid: getpid(), transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        await registry.setStatusReader { _, _ in "busy" }
        _ = await registry.ingest(["session_id": sid, "hook_event_name": "UserPromptSubmit", "prompt": "長い作業"])
        let poller = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop-4", pids: [getppid()], canType: true, timeout: 3) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let outcome = await registry.typePrompt(sessionId: sid, text: "割り込み", echo: "割り込み")
        XCTAssertEqual(outcome, .busy)
        let delivered = await poller.value
        XCTAssertTrue(delivered.isEmpty)
        await releaseDesktop("typing-desktop-4")
    }

    /// /model などの一覧が開いている間（sessions の status が waiting）も打たない。
    func testTypePromptRefusesWhileListIsOpen() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-typing-" + UUID().uuidString
        let poller = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop-6", pids: [getppid()], canType: true, timeout: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await registry.register(sessionId: sid, cwd: "/tmp", pid: getpid(), transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        await registry.setStatusReader { _, _ in "waiting" }
        let outcome = await registry.typePrompt(sessionId: sid, text: "続けて", echo: "続けて")
        XCTAssertEqual(outcome, .dialogOpen)
        let delivered = await poller.value
        XCTAssertTrue(delivered.isEmpty)
        await releaseDesktop("typing-desktop-6")
    }

    /// sessions のファイルでその claude だと確かめられない（pid の使い回し・古い claude）か、知らない状態なら
    /// 打たない（呼び元は受け箱へ）。shell（返事の後に裏のコマンドだけが動いている）は入力欄が空いているので打つ。
    func testTypePromptNeedsConfirmedIdleSession() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-typing-" + UUID().uuidString
        let poller = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop-7", pids: [getppid()], canType: true, timeout: 1) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await registry.register(sessionId: sid, cwd: "/tmp", pid: getpid(), transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }
        await registry.setStatusReader { _, _ in nil }
        let unknown = await registry.typePrompt(sessionId: sid, text: "こんにちは", echo: "こんにちは")
        XCTAssertEqual(unknown, .unavailable)
        await registry.setStatusReader { _, _ in "starting" }
        let strange = await registry.typePrompt(sessionId: sid, text: "こんにちは", echo: "こんにちは")
        XCTAssertEqual(strange, .unavailable)
        let delivered = await poller.value
        XCTAssertTrue(delivered.isEmpty)
        await releaseDesktop("typing-desktop-7")

        let shellPoller = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop-8", pids: [getppid()], canType: true, timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await registry.setStatusReader { _, _ in "shell" }
        let shell = await registry.typePrompt(sessionId: sid, text: "dev サーバーの様子を見て", echo: "dev サーバーの様子を見て")
        XCTAssertEqual(shell, .typed)
        let typed = await shellPoller.value
        XCTAssertEqual(typed.first?.keys, TerminalKeyPlan.typing("dev サーバーの様子を見て"))
        await releaseDesktop("typing-desktop-8")
    }

    /// 続けて送った発話は、前の発話が届いて（UserPromptSubmit）そのターンが終わるまで打たない（順が入れ替わらない。
    /// 前の発話のターンで出た選択肢を、次の Enter で選ばない）。
    func testTypePromptTypesOneAtATime() async throws {
        let registry = ClaudeTerminalRegistry()
        let sid = "test-typing-" + UUID().uuidString
        let status = StatusBox("idle")
        await registry.setStatusReader { _, _ in status.get() }
        let first = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop-5", pids: [getppid()], canType: true, timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await registry.register(sessionId: sid, cwd: "/tmp", pid: getpid(), transcriptPath: nil)
        defer { Task { await registry.unregister(sessionId: sid) } }

        let one = await registry.typePrompt(sessionId: sid, text: "一つ目", echo: "一つ目")
        XCTAssertEqual(one, .typed)
        let delivered1 = await first.value
        XCTAssertEqual(delivered1.first?.keys, TerminalKeyPlan.typing("一つ目"))

        let second = Task { await TerminalKeyRouter.shared.poll(client: "typing-desktop-5", pids: [getppid()], canType: true, timeout: 10) }
        let finished = StatusBox(nil)
        let two = Task { () -> ClaudeTerminalRegistry.TypingOutcome in
            let outcome = await registry.typePrompt(sessionId: sid, text: "二つ目", echo: "二つ目")
            finished.set("done")
            return outcome
        }
        // 一つ目がまだ届いていない（sessions は idle のまま）間は打たない。
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertNil(finished.get())
        // 一つ目が届いてターンが始まる。
        status.set("busy")
        _ = await registry.ingest(["session_id": sid, "hook_event_name": "UserPromptSubmit", "prompt": "一つ目"])
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(finished.get())
        // ターンが終われば打つ。
        status.set("idle")
        _ = await registry.ingest(["session_id": sid, "hook_event_name": "Stop", "last_assistant_message": "OK"])
        let outcomeTwo = await two.value
        XCTAssertEqual(outcomeTwo, .typed)
        let delivered2 = await second.value
        XCTAssertEqual(delivered2.first?.keys, TerminalKeyPlan.typing("二つ目"))
        await releaseDesktop("typing-desktop-5")
    }

    /// ターミナルに打ち込む文は skill の行を / で始めない（Claude Code が `/skill` をコマンドとして読む）。
    func testTypedPromptDoesNotStartWithSkillCommand() {
        let typed = ClaudeTerminalSession.promptText(text: "見て", skills: ["a", "b"], attachments: [], typed: true)
        XCTAssertEqual(typed, "Use these skills: a, b\n\n見て")
        XCTAssertNil(ClaudeTerminalRegistry.slashCommand(typed))
        // 受け箱・channel へ送る文は今までどおり。
        XCTAssertEqual(ClaudeTerminalSession.promptText(text: "見て", skills: ["a"], attachments: []), "/skill a\n\n見て")
    }

    /// 後のテストに「打ち込めるデスクトップ」を残さない（持っている pty を空で名乗り直す）。
    private func releaseDesktop(_ client: String) async {
        _ = await TerminalKeyRouter.shared.poll(client: client, pids: [], timeout: 0.01)
    }
}

/// テストで sessions のファイルの status の代わりに返す値。
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    func set(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
