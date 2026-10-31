import XCTest
@testable import BridgeApp

/// HeadlessCliAdapter (cursor / grok) のストリーム解析とエラー経路のスモーク。
/// 実 CLI は認証が要るため、ドキュメント通りのストリームを吐くフェイク CLI
/// スクリプトを executable に差して spawn 経路ごと検証する。
/// ClaudeCodeSessionStore の claude-sessions.json は、テスト中は BuddyPaths の一時フォルダに
/// 書かれる（本物の ~/.buddyos には触らない）。
final class HeadlessCliAdapterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        // ここのフェイク CLI は headless 実行（1 ターン 1 プロセス）の出力を真似る。ACP 経路は AcpCliTests。
        setenv("BUDDYOS_CURSOR_HEADLESS", "1", 1)
        setenv("BUDDYOS_GROK_HEADLESS", "1", 1)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-cli-tests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("BUDDYOS_CURSOR_HEADLESS")
        unsetenv("BUDDYOS_GROK_HEADLESS")
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeScript(_ name: String, _ body: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// events ストリームを done / error まで読み、観測したイベント列を返す。
    /// send() はターン完了（done/error yield 後）まで戻らない実装なので、
    /// send 完了後の task.value 待ちはすぐ解ける。
    private func collectEvents(_ session: AgentSession, send text: String) async -> [SessionEvent] {
        let task = Task {
            var out: [SessionEvent] = []
            for try await event in session.events {
                out.append(event)
                if event.type == .done || event.type == .error { break }
            }
            return out
        }
        await session.send(text, skills: [], attachments: [])
        let seen = (try? await task.value) ?? []
        await session.close()
        return seen
    }

    // MARK: - grok

    func testGrokReportsJSONAuthenticationError() async throws {
        let script = try writeScript("fake-grok-auth.sh", """
        echo '{"type":"error","message":"Not signed in. Run grok login --device-code"}'
        exit 1
        """)
        let previous = ProcessInfo.processInfo.environment["XAI_API_KEY"]
        setenv("XAI_API_KEY", "test-key", 1)
        defer {
            if let previous { setenv("XAI_API_KEY", previous, 1) }
            else { unsetenv("XAI_API_KEY") }
        }
        let adapter = HeadlessCliAdapter(profile: .grok, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "hi")
        XCTAssertTrue(events.contains { $0.type == .error && $0.content?.contains("grok login") == true })
        XCTAssertFalse(events.contains { $0.type == .assistantDelta })
    }

    func testGrokACPChunksIgnoreThoughtsAndTools() async throws {
        let script = try writeScript("fake-grok-acp.sh", """
        echo '{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"private thinking"}}'
        echo '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hel"}}'
        echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"grok-acp-test","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"lo"}}}}'
        echo '{"sessionUpdate":"tool_call","title":"do not render"}'
        """)
        let previous = ProcessInfo.processInfo.environment["XAI_API_KEY"]
        setenv("XAI_API_KEY", "test-key", 1)
        defer {
            if let previous { setenv("XAI_API_KEY", previous, 1) }
            else { unsetenv("XAI_API_KEY") }
        }
        let adapter = HeadlessCliAdapter(profile: .grok, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "hi")
        XCTAssertEqual(events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined(), "Hello")
        XCTAssertEqual(session.sessionId, "grok-acp-test")
        XCTAssertTrue(events.contains { $0.type == .done })
    }

    func testGrokStreamParsingAndSessionId() async throws {
        // grok streaming-json（14-headless-mode.md 記載の形）を吐くフェイク CLI。
        // `-s <id>` で渡ったセッション ID を end イベントへエコーする。
        let script = try writeScript("fake-grok.sh", """
        SID=""
        prev=""
        for a in "$@"; do
          if [ "$prev" = "-s" ]; then SID="$a"; fi
          prev="$a"
        done
        echo '{"type":"thought","data":"thinking..."}'
        echo '{"type":"text","data":"Hel"}'
        echo '{"type":"text","data":"lo"}'
        echo "{\\"type\\":\\"end\\",\\"stopReason\\":\\"EndTurn\\",\\"sessionId\\":\\"$SID\\",\\"requestId\\":\\"r1\\"}"
        exit 0
        """)

        // 未認証ガードを通すため、一時 HOME でない場合でも env キーで configured にする。
        setenv("XAI_API_KEY", "test-key", 1)
        defer { unsetenv("XAI_API_KEY") }

        let adapter = HeadlessCliAdapter(profile: .grok, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "say hi")

        let deltas = events.filter { $0.type == .assistantDelta }.compactMap(\.content)
        XCTAssertEqual(deltas.joined(), "Hello", "text イベントが順に deltas になる（thought は無視）")
        XCTAssertTrue(events.contains { $0.type == .sessionStarted }, "新規セッションは sessionStarted を送る")
        XCTAssertTrue(events.contains { $0.type == .done }, "正常終了で done")
        XCTAssertFalse(events.contains { $0.type == .error })
        // grok は adapter 側で採番した UUID を -s で渡す。end のエコーと一致し安定する。
        XCTAssertNotNil(UUID(uuidString: session.sessionId), "セッション ID は adapter 採番の UUID")
    }

    func testGrokCreatesWithSThenResumesWithR() async throws {
        // grok 1.0 の -s は新規作成専用。2 ターン目以降と開き直しは -r で再開する。
        // 引数: -p <prompt> --output-format streaming-json --no-auto-update <-s|-r> <id> ...
        let script = try writeScript("fake-grok-flags.sh", """
        echo "{\\"type\\":\\"text\\",\\"data\\":\\"flags: $6 $7\\"}"
        echo '{"type":"end","stopReason":"EndTurn"}'
        exit 0
        """)
        setenv("XAI_API_KEY", "test-key", 1)
        defer { unsetenv("XAI_API_KEY") }
        let adapter = HeadlessCliAdapter(profile: .grok, executable: script)

        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        func turn() async -> String {
            let task = Task { () -> String in
                var text = ""
                for try await event in session.events {
                    if event.type == .assistantDelta { text += event.content ?? "" }
                    if event.type == .done || event.type == .error { break }
                }
                return text
            }
            await session.send("hi", skills: [], attachments: [])
            return (try? await task.value) ?? ""
        }
        let first = await turn()
        let second = await turn()
        await session.close()
        XCTAssertTrue(first.contains("-s \(session.sessionId)"), first)
        XCTAssertTrue(second.contains("-r \(session.sessionId)"), second)

        let reopened = await adapter.openSession(sessionId: session.sessionId, cwd: tempDir.path)
        let text = await collectEvents(reopened, send: "again")
            .filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertTrue(text.contains("-r \(session.sessionId)"), text)
    }

    func testGrokUnauthenticatedGuard() async throws {
        // XAI_API_KEY 等が無く ~/.grok/auth.json も無ければ、spawn せずエラーを返す
        // （未認証の grok はハングするため）。fake HOME で認証なし状態を作る。
        let fakeHome = tempDir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
        let savedHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", fakeHome.path, 1)
        defer { if let savedHome { setenv("HOME", savedHome, 1) } }
        unsetenv("XAI_API_KEY")

        guard !GrokAuth.isConfigured else {
            throw XCTSkip("実 HOME の grok 認証が見えている環境ではスキップ")
        }

        let script = try writeScript("fake-grok-hang.sh", "sleep 300\n")
        let adapter = HeadlessCliAdapter(profile: .grok, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "hi")

        let error = events.first { $0.type == .error }
        XCTAssertNotNil(error, "未認証 grok は spawn 前にエラーを返す")
        XCTAssertTrue(error?.content?.contains("grok login") == true)
    }

    // MARK: - cursor

    func testCursorStreamParsingResolvesChatId() async throws {
        let chatId = "01234567-89ab-cdef-0123-456789abcdef"
        // cursor stream-json（Claude Code 互換形）を吐くフェイク CLI。
        let script = try writeScript("fake-cursor.sh", """
        echo '{"type":"system","subtype":"init","sessionId":"\(chatId)","model":"auto"}'
        echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]},"session_id":"\(chatId)"}'
        echo '{"type":"result","subtype":"success","result":"Hello","session_id":"\(chatId)"}'
        exit 0
        """)

        let adapter = HeadlessCliAdapter(profile: .cursor, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "say hi")

        let deltas = events.filter { $0.type == .assistantDelta }.compactMap(\.content)
        XCTAssertEqual(deltas.joined(), "Hello", "assistant 本文を一度だけ出す（result で二重にしない）")
        XCTAssertEqual(session.sessionId, chatId, "CLI 採番の chatId へ解決される")
        XCTAssertTrue(events.contains { $0.type == .done })
        XCTAssertFalse(events.contains { $0.type == .error })
    }

    func testCursorNonZeroExitSurfacesStderr() async throws {
        // 未認証の実 cursor-agent と同じ「stderr にエラー + exit 1」経路。
        let script = try writeScript("fake-cursor-autherr.sh", """
        echo "Error: Authentication required. Please run 'agent login' first." >&2
        exit 1
        """)

        let adapter = HeadlessCliAdapter(profile: .cursor, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "hi")

        let error = events.first { $0.type == .error }
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.content?.contains("Authentication required") == true, "stderr がそのままエラーとして出る")
    }

    func testCursorResumePassedOnlyForRealChatIds() async throws {
        // 引数を stdout にエコーして確認するフェイク CLI。
        let script = try writeScript("fake-cursor-args.sh", """
        printf '%s\\n' "{\\"type\\":\\"result\\",\\"result\\":\\"args: $*\\"}"
        exit 0
        """)

        let adapter = HeadlessCliAdapter(profile: .cursor, executable: script)

        // 新規（pending id）→ --resume が付かない
        let fresh = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let freshEvents = await collectEvents(fresh, send: "hi")
        let freshText = freshEvents.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertFalse(freshText.contains("--resume"), "未解決の pending id では --resume しない")

        // 実 chatId (UUID) → --resume が付く
        let chatId = "fedcba98-7654-3210-fedc-ba9876543210"
        let resumed = await adapter.openSession(sessionId: chatId, cwd: tempDir.path)
        let resumedEvents = await collectEvents(resumed, send: "hi")
        let resumedText = resumedEvents.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertTrue(resumedText.contains("--resume \(chatId)"), "UUID の chatId は --resume で再開する")
    }

    func testCursorFinishesWhenDescendantHoldsPipe() async throws {
        // パイプの書き込み端を継承したバックグラウンドの子を残して本体が exit 0 しても、
        // EOF を待ち続けずに数秒でターンが終わること。
        let pidFile = tempDir.appendingPathComponent("bg.pid").path
        let script = try writeScript("fake-cursor-bg.sh", """
        sleep 30 &
        echo $! > '\(pidFile)'
        echo '{"type":"result","subtype":"success","result":"done"}'
        exit 0
        """)
        defer {
            if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
        }

        let adapter = HeadlessCliAdapter(profile: .cursor, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let started = Date()
        let events = await collectEvents(session, send: "hi")

        XCTAssertTrue(events.contains { $0.type == .done })
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "子孫が握るパイプの EOF を待ち続けない")
    }

    func testCursorMultibyteSplitAcrossChunksIsDecoded() async throws {
        // 3 バイト文字「あ」(e3 81 82) の途中で書き込みを分けても、chunk 単位のデコードで
        // 失われずに 1 文字として届くこと。
        let script = try writeScript("fake-cursor-split.sh", """
        printf '{"type":"assistant","message":{"content":[{"type":"text","text":"\\xe3\\x81'
        sleep 0.2
        printf '\\x82"}]}}\\n'
        exit 0
        """)

        let adapter = HeadlessCliAdapter(profile: .cursor, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "hi")

        let deltas = events.filter { $0.type == .assistantDelta }.compactMap(\.content)
        XCTAssertEqual(deltas.joined(), "あ")
    }

    // MARK: - antigravity (Antigravity CLI / agy)

    /// `agy models` に応答するフェイク。spawn 前の認証ガードがこれを見るため、
    /// ストリーム系のフェイクにも必ず models 分岐を持たせる。
    private var antigravityModelsBranch: String {
        """
        if [ "$1" = "models" ]; then
          printf 'gemini-3.1-pro-high\\tGemini 3.1 Pro (High)\\n'
          printf 'claude-opus-4-6-thinking\\tClaude Opus 4.6 (Thinking)\\n'
          printf 'gpt-oss-120b-medium\\tGPT-OSS 120B (Medium)\\n'
          exit 0
        fi
        """
    }

    func testAntigravityStreamParsingResolvesConversationId() async throws {
        let convId = "751876fb-ee7e-4225-a89b-f274861385ea"
        // 実 agy の stream-json（event: init / step_update / result）を再現する。
        let script = try writeScript("fake-agy.sh", """
        \(antigravityModelsBranch)
        echo '{"event":"init","conversation_id":"\(convId)","init":{"model":"gemini-3.1-pro-high","cwd":"/tmp"}}'
        echo '{"event":"step_update","step_update":{"conversation_id":"\(convId)","step_index":0,"state":"DONE","step_type":"user_input"}}'
        echo '{"event":"step_update","step_update":{"conversation_id":"\(convId)","step_index":1,"state":"ACTIVE","step_type":"tool","tool_name":"view_file","tool_info":{"name":"view_file","parameters":{}}}}'
        echo '{"event":"step_update","step_update":{"conversation_id":"\(convId)","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"Hel"}}'
        echo '{"event":"step_update","step_update":{"conversation_id":"\(convId)","step_index":2,"state":"DONE","step_type":"agent_response","text_delta":"lo"}}'
        echo '{"event":"result","result":{"conversation_id":"\(convId)","status":"SUCCESS","response":"Hello","num_turns":1}}'
        exit 0
        """)

        let adapter = HeadlessCliAdapter(profile: .antigravity, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "say hi")

        let deltas = events.filter { $0.type == .assistantDelta }.compactMap(\.content)
        XCTAssertEqual(deltas.joined(), "Hello", "text_delta を連結する（result で二重にしない）")
        XCTAssertEqual(session.sessionId, convId, "CLI 採番の conversation_id へ解決される")
        XCTAssertTrue(events.contains { $0.type == .sessionStarted })
        XCTAssertTrue(events.contains { $0.type == .done })
        XCTAssertFalse(events.contains { $0.type == .error })
    }

    func testAntigravityPassesAddDirAndResumesOnlyRealConversationIds() async throws {
        // 引数を result.response にエコーして確認するフェイク。
        let script = try writeScript("fake-agy-args.sh", """
        \(antigravityModelsBranch)
        printf '%s\\n' "{\\"event\\":\\"result\\",\\"result\\":{\\"response\\":\\"args: $*\\"}}"
        exit 0
        """)

        let adapter = HeadlessCliAdapter(profile: .antigravity, executable: script)

        // 新規（pending id）→ --conversation は付かないが --add-dir は必ず付く。
        let fresh = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let freshText = await collectEvents(fresh, send: "hi")
            .filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertTrue(
            freshText.contains("--add-dir \(tempDir.path)"),
            "agy は cwd を引き継がないので --add-dir が必須"
        )
        XCTAssertFalse(freshText.contains("--conversation"), "未解決の pending id では再開しない")

        // 実 conversation_id (UUID) → --conversation で再開する。
        let convId = "fedcba98-7654-3210-fedc-ba9876543210"
        let resumed = await adapter.openSession(sessionId: convId, cwd: tempDir.path)
        let resumedText = await collectEvents(resumed, send: "hi")
            .filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertTrue(resumedText.contains("--conversation \(convId)"))
    }

    func testAntigravityImageIsPassedAsFile() async throws {
        // プロンプトに引用符が入るので、引数は JSON に埋めずファイルへ 1 行ずつ書き出す。
        let argsFile = tempDir.appendingPathComponent("args.txt").path
        let script = try writeScript("fake-agy-image.sh", """
        \(antigravityModelsBranch)
        printf '%s\\n' "$@" > '\(argsFile)'
        echo '{"event":"result","result":{"response":"ok"}}'
        exit 0
        """)
        let adapter = HeadlessCliAdapter(profile: .antigravity, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let image = BridgeAttachment(kind: .image, name: "pic.png", mime: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47, 0x01]))
        let task = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            for try await event in session.events {
                out.append(event)
                if event.type == .done || event.type == .error { break }
            }
            return out
        }
        await session.send("what is this", skills: [], attachments: [image])
        _ = try? await task.value
        await session.close()

        let args = try String(contentsOfFile: argsFile, encoding: .utf8)
        let dir = AttachmentStore.exportDirectory.path
        XCTAssertTrue(args.contains("--add-dir\n\(dir)\n"), "画像の置き場をワークスペースに足す（agy は外を読めない）")
        XCTAssertTrue(args.contains("[image \"pic.png\" attached: image/png, 5 bytes] (file: \(dir)/"), "placeholder の後ろにパスを付ける")
        let path = try XCTUnwrap(args.range(of: #"\(file: ([^ ]+\.png)"#, options: .regularExpression).map { String(args[$0].dropFirst(7)) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "書き出したファイルが実在する")
    }

    func testAntigravityAutoDeniedTurnExplainsInsteadOfEmptyReply() async throws {
        let script = try writeScript("fake-agy-denied.sh", """
        \(antigravityModelsBranch)
        echo 'jetski: no output produced — a tool required the "command" permission that headless mode cannot prompt for, so it was auto-denied' >&2
        echo '{"event":"result","result":{"status":"SUCCESS","response":""}}'
        exit 0
        """)
        let adapter = HeadlessCliAdapter(profile: .antigravity, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "run ls")
        let text = events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined()
        XCTAssertTrue(text.contains("自動で拒否"), "空の返事にせず、拒否された理由を出す")
        XCTAssertTrue(events.contains { $0.type == .done })
    }

    func testAntigravityUnauthenticatedGuard() async throws {
        // 未認証の agy は `agy models` が空/非 0 で返る。spawn 前に弾く。
        let script = try writeScript("fake-agy-noauth.sh", """
        exit 1
        """)

        let adapter = HeadlessCliAdapter(profile: .antigravity, executable: script)
        let session = await adapter.openSession(sessionId: nil, cwd: tempDir.path)
        let events = await collectEvents(session, send: "hi")

        let error = events.first { $0.type == .error }
        XCTAssertNotNil(error, "未認証 agy は spawn 前にエラーを返す")
        XCTAssertTrue(error?.content?.contains("Antigravity CLI") == true)
    }

    func testAntigravityCatalogGroupsByRateLimitPool() throws {
        // Antigravity は Gemini 枠と Claude/GPT 枠でレート制限プールが別なので、
        // カタログもその粒度で分かれることを担保する。
        let script = try writeScript("fake-agy-models.sh", """
        \(antigravityModelsBranch)
        exit 0
        """)

        let catalogs = HeadlessCliAdapter.antigravityCatalogFromCli(executable: script)
        XCTAssertEqual(catalogs?.count, 3)
        XCTAssertEqual(catalogs?[0].id, "google")
        XCTAssertEqual(catalogs?[0].models.map(\.id), ["gemini-3.1-pro-high"])
        XCTAssertEqual(catalogs?[1].models.map(\.id), ["claude-opus-4-6-thinking"])
        XCTAssertEqual(catalogs?[2].models.map(\.id), ["gpt-oss-120b-medium"])
    }

    // MARK: - probe/カタログ補助

    func testGrokCatalogParsesModelsCache() throws {
        // ~/.grok/models_cache.json 形式のフィクスチャを fake HOME に置いて読む。
        let fakeHome = tempDir.appendingPathComponent("home2")
        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        let fixture = """
        {"models": {
          "grok-build": {"info": {"name": "Grok Build", "description": "default", "hidden": false}},
          "grok-secret": {"info": {"name": "Secret", "hidden": true}}
        }}
        """
        try fixture.write(
            to: fakeHome.appendingPathComponent(".grok/models_cache.json"),
            atomically: true, encoding: .utf8)

        // NSHomeDirectory() は setenv("HOME") に追従しないため、home をパス注入する。
        let catalog = HeadlessCliAdapter.grokCatalogFromCache(home: fakeHome.path)
        XCTAssertEqual(catalog?.count, 1)
        XCTAssertEqual(catalog?.first?.models.map(\.id), ["grok-build"], "hidden モデルは出さない")
        XCTAssertEqual(catalog?.first?.models.first?.label, "Grok Build")
    }

    func testGrokCliDefaultModelPinsCatalogOrder() throws {
        // config.toml の [models] default を読み、カタログ先頭へピン留めする。
        let fakeHome = tempDir.appendingPathComponent("home3")
        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        try """
        [ui]
        fork_secondary_model = "grok-build"

        [models]
        default = "grok-4.5"
        default_reasoning_effort = "xhigh"
        """.write(
            to: fakeHome.appendingPathComponent(".grok/config.toml"),
            atomically: true, encoding: .utf8)
        try """
        {"models": {
          "grok-build": {"info": {"name": "Grok Build", "hidden": false}},
          "grok-4.5": {"info": {"name": "Grok 4.5", "hidden": false}}
        }}
        """.write(
            to: fakeHome.appendingPathComponent(".grok/models_cache.json"),
            atomically: true, encoding: .utf8)

        XCTAssertEqual(HeadlessCliAdapter.grokCliDefaultModel(home: fakeHome.path), "grok-4.5")
        let catalog = HeadlessCliAdapter.grokCatalogFromCache(home: fakeHome.path)
        XCTAssertEqual(
            catalog?.first?.models.map(\.id), ["grok-4.5", "grok-build"],
            "CLI の既定モデルを先頭に置く（default_reasoning_effort を誤読しない）")
    }

    func testCursorCatalogParsesIdDashLabelFormat() throws {
        // cursor-agent 現行の "id - 表示名" 形式。cli-config.json の既定モデルを先頭へ。
        let fakeHome = tempDir.appendingPathComponent("home4")
        try FileManager.default.createDirectory(
            at: fakeHome.appendingPathComponent(".cursor"), withIntermediateDirectories: true)
        try """
        {"version": 1, "model": {"modelId": "composer-2.5", "displayName": "Composer 2.5 Fast"}}
        """.write(
            to: fakeHome.appendingPathComponent(".cursor/cli-config.json"),
            atomically: true, encoding: .utf8)
        let out = """
        Available models

        auto - Auto (default)
        gpt-5.3-codex - Codex 5.3
        composer-2.5 - Composer 2.5 Fast
        """
        let catalog = HeadlessCliAdapter.cursorCatalogFromListOutput(out, home: fakeHome.path)
        XCTAssertEqual(
            catalog?.first?.models.map(\.id), ["composer-2.5", "auto", "gpt-5.3-codex"],
            "CLI 設定の既定モデルを先頭へ、他は出力順を保つ")
        XCTAssertEqual(catalog?.first?.models.first?.label, "Composer 2.5 Fast")
        XCTAssertEqual(
            catalog?.first?.models.map(\.label), ["Composer 2.5 Fast", "Auto", "Codex 5.3"],
            "(default) 印はラベルから除去し、ヘッダ行は無視する")
    }

    func testCursorCatalogLegacyPlainIdFormat() {
        // 旧形式（素の id 一覧）も引き続き読めること。config 無しなら出力順を保つ。
        let catalog = HeadlessCliAdapter.cursorCatalogFromListOutput(
            "auto\ngpt-4o\n", home: "/nonexistent")
        XCTAssertEqual(catalog?.first?.models.map(\.id), ["auto", "gpt-4o"])
    }
}
