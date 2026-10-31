import XCTest
@testable import BridgeApp

final class VoiceTurnTests: XCTestCase {
    func testMetadataMarker() {
        XCTAssertNil(VoiceTurn(metadata: nil))
        XCTAssertNil(VoiceTurn(metadata: ["voiceSpoken": "こんにちは"]), "voice=1 が無ければ通常ターン")
        XCTAssertEqual(VoiceTurn(metadata: ["voice": "1"]), VoiceTurn(spoken: nil))
        XCTAssertEqual(VoiceTurn(metadata: ["voice": "1", "voiceSpoken": "  "]), VoiceTurn(spoken: nil))
        XCTAssertEqual(VoiceTurn(metadata: ["voice": "1", "voiceSpoken": " 途中まで "])?.spoken, "途中まで")
        let long = String(repeating: "あ", count: 400) + "末尾"
        XCTAssertEqual(VoiceTurn(metadata: ["voice": "1", "voiceSpoken": long])?.spoken?.count, VoiceTurn.maxSpokenLength)
        XCTAssertTrue(VoiceTurn(metadata: ["voice": "1", "voiceSpoken": long])?.spoken?.hasSuffix("末尾") == true)
    }

    func testContextBlock() {
        // 遮られていない音声ターン: system prompt 側で指示を渡せるなら何も付けない。
        XCTAssertNil(VoiceTurn().contextBlock(includeDirective: false))
        XCTAssertEqual(VoiceTurn().appended(to: "やあ", includeDirective: false), "やあ")
        // フォールバック: 指示を本文末尾に。
        let fallback = VoiceTurn().appended(to: "やあ", includeDirective: true)
        XCTAssertTrue(fallback.hasPrefix("やあ\n\n<voice-context>\n" + VoiceTurn.directive))
        XCTAssertTrue(fallback.hasSuffix("</voice-context>"))
        // 遮られた注記。
        let note = VoiceTurn(spoken: "明日は晴れ").appended(to: "じゃあ傘は？", includeDirective: false)
        XCTAssertTrue(note.contains("\"明日は晴れ\""))
        XCTAssertFalse(note.contains(VoiceTurn.directive))
        XCTAssertTrue(note.hasPrefix("じゃあ傘は？"))
    }

    func testStripContext() {
        let both = VoiceTurn(spoken: "途中").appended(to: "本文\n二行目", includeDirective: true)
        XCTAssertEqual(VoiceTurn.stripContext(both), "本文\n二行目")
        XCTAssertEqual(VoiceTurn.stripContext("タグ無し"), "タグ無し")
        // 一覧タイトルのように閉じタグの前で切れたもの。
        XCTAssertEqual(VoiceTurn.stripContext(String(both.prefix(30))), "本文\n二行目")
        // 開きタグの途中で切れたもの（一覧のタイトルは 77 文字で切って「...」を付ける）。
        XCTAssertEqual(VoiceTurn.stripContext("本文 <voice-con..."), "本文")
        XCTAssertEqual(VoiceTurn.stripContext("本文 <v..."), "本文")
        XCTAssertEqual(VoiceTurn.stripContext("a <b> と <video> の違い"), "a <b> と <video> の違い")
        // 先頭に付けていた頃の形も剥がせる。
        XCTAssertEqual(VoiceTurn.stripContext("<voice-context>\n指示\n</voice-context>\n\n本文"), "本文")
    }

    /// 音声で始めた Codex の作業の一覧タイトルに、話した言葉が残る（指示だけで埋まって空にならない）。
    func testVoiceStartedSessionTitleKeepsUserText() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("buddyos-voice-title-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent(".codex/sessions/2026/10/11")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment["BUDDYOS_CODEX_HOME"]
        setenv("BUDDYOS_CODEX_HOME", tmp.appendingPathComponent(".codex").path, 1)
        defer {
            if let saved { setenv("BUDDYOS_CODEX_HOME", saved, 1) } else { unsetenv("BUDDYOS_CODEX_HOME") }
            try? FileManager.default.removeItem(at: tmp)
        }
        let sid = "0199a1b2-0000-7000-8000-0000000000aa"
        let first = VoiceTurn().appended(to: "明日の天気を教えて", includeDirective: true)
        func line(_ o: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        }
        let lines = [
            try line(["timestamp": "2026-10-11T09:00:00.000Z", "type": "session_meta",
                      "payload": ["id": sid, "timestamp": "2026-10-11T09:00:00.000Z", "cwd": "/tmp/voice",
                                  "originator": "codex_cli_rs", "cli_version": "0.50.0", "source": "cli", "model_provider": "openai"]]),
            try line(["timestamp": "2026-10-11T09:00:01.000Z", "type": "response_item",
                      "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": first]]]]),
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("rollout-2026-10-11T09-00-00-\(sid).jsonl"), atomically: true, encoding: .utf8)
        let list = await CodexHistoryAdapter().listSessions(limit: 10, cwd: nil)
        let title = try XCTUnwrap(list.first { $0.sessionId == sid }).title
        XCTAssertEqual(VoiceTurn.stripContext(title), "明日の天気を教えて")
    }

    func testClaudeVoiceTurnDoesNotChangeSpawnSettings() {
        let session = ClaudeCodeSession(
            agentId: "claude", profile: .claude, initialSessionId: nil, cwd: nil,
            executable: "claude", store: .shared)
        let signature = session.configSignature()
        let args = session.sessionArgs()
        // 音声の指示は本文の <voice-context> で渡す。起動引数には入れない（切り替えで起こし直さない）。
        XCTAssertFalse(args.joined(separator: " ").contains(VoiceTurn.directive))
        XCTAssertFalse(signature.contains("voice"))
        let appended = args.firstIndex(of: "--append-system-prompt").map { args[$0 + 1] } ?? ""
        XCTAssertTrue(appended.contains(ClaudeCodeAdapter.clientDirective))
        let block = VoiceTurn().contextBlock(includeDirective: true) ?? ""
        XCTAssertTrue(block.contains(VoiceTurn.directive))
    }

    func testInterruptWithoutTurnIsNotActive() {
        let session = ClaudeCodeSession(
            agentId: "claude", profile: .claude, initialSessionId: nil, cwd: nil,
            executable: "claude", store: .shared)
        XCTAssertFalse(session.hasActiveTurn, "送っていなければ止めるターンは無い（interrupt でプロセスを殺さない）")
    }

    func testQueuedMessageKeepsVoice() {
        let plain = SessionHub.QueuedMessage(clientMessageId: "a", content: "x", skills: [], attachments: [])
        XCTAssertNil(plain.voice)
        let voiced = SessionHub.QueuedMessage(clientMessageId: "b", content: "x", skills: [], attachments: [], voice: VoiceTurn())
        XCTAssertEqual(voiced.voice, VoiceTurn())
    }

    func testApplyEffortUpdatesPerModelWhenModelUnknown() {
        var obj: [String: Any] = ["effortLevel": "medium", "model": "opus",
                                  "modelSettings": ["claude-opus-5-5": ["effortLevel": "high"], "claude-sonnet-5-5": ["x": 1]]]
        XCTAssertEqual(ClaudeCodeAdapter.defaultModelKey(in: obj), "claude-opus-5-5")
        ClaudeCodeAdapter.applyEffort("low", model: nil, to: &obj)
        let all = obj["modelSettings"] as? [String: Any]
        XCTAssertEqual(obj["effortLevel"] as? String, "low")
        XCTAssertEqual((all?["claude-opus-5-5"] as? [String: Any])?["effortLevel"] as? String, "low")
        XCTAssertNil((all?["claude-sonnet-5-5"] as? [String: Any])?["effortLevel"], "無かったモデル別の値は足さない")

        var known: [String: Any] = ["modelSettings": ["a": ["effortLevel": "high"], "b": ["effortLevel": "high"]]]
        ClaudeCodeAdapter.applyEffort("max", model: "a", to: &known)
        let k = known["modelSettings"] as? [String: Any]
        XCTAssertEqual((k?["a"] as? [String: Any])?["effortLevel"] as? String, "max")
        XCTAssertEqual((k?["b"] as? [String: Any])?["effortLevel"] as? String, "high")
    }

    func testSpawnSummary() {
        XCTAssertEqual(
            ClaudeCodeSession.spawnSummary(args: ["-p", "--resume", "x", "--model", "opus", "--effort", "high"]),
            "model=opus effort=high mode=- resume=1")
        XCTAssertEqual(ClaudeCodeSession.spawnSummary(args: ["-p", "--model"]), "model=- effort=- mode=- resume=0")
    }
}
