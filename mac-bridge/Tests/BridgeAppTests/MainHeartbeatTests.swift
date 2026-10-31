import XCTest
@testable import BridgeApp

/// メインの定期チェック（docs/MAIN_HEARTBEAT_2026-10-20.md）の決まり。
final class MainHeartbeatTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Tokyo")!
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func at(_ h: Int, _ m: Int, day: Int = 20) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    private func tmpDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - 設定

    func testDefaultsAndLoad() {
        let d = HeartbeatSettings.defaults
        XCTAssertTrue(d.enabled)
        XCTAssertEqual(d.intervalMinutes, 180)
        XCTAssertEqual(d.quietHours, .init(enabled: true, start: "22:00", end: "08:00"))
        XCTAssertEqual(d.agentId, "claude")
        XCTAssertEqual(HeartbeatSettings.load(from: nil), d, "ファイルが無ければ既定")
        XCTAssertEqual(HeartbeatSettings.load(from: Data("not json".utf8)), d, "壊れていれば既定")
        let partial = HeartbeatSettings.load(from: Data(#"{"intervalMinutes":60}"#.utf8))
        XCTAssertEqual(partial.intervalMinutes, 60)
        XCTAssertEqual(partial.quietHours, d.quietHours, "足りない項目は既定")
    }

    func testMergeKeepsMissingAndClamps() {
        var s = HeartbeatSettings.defaults
        s.agentId = "codex"
        let m = s.merged(with: ["enabled": false, "quietHours": ["start": "23:30"]])
        XCTAssertFalse(m.enabled)
        XCTAssertEqual(m.quietHours.start, "23:30")
        XCTAssertEqual(m.quietHours.end, "08:00", "一部だけなら残りは今の値")
        XCTAssertTrue(m.quietHours.enabled)
        XCTAssertEqual(m.agentId, "codex")
        XCTAssertEqual(m.intervalMinutes, 180)

        XCTAssertEqual(s.merged(with: ["intervalMinutes": 5]).intervalMinutes, 30)
        XCTAssertEqual(s.merged(with: ["intervalMinutes": 99999]).intervalMinutes, 1440)
        XCTAssertEqual(s.merged(with: ["intervalMinutes": 360]).intervalMinutes, 360)
        XCTAssertEqual(HeartbeatSettings.clampInterval(29), 30)
        XCTAssertEqual(HeartbeatSettings.clampInterval(1441), 1440)

        // 形の違う値・読めない時刻・空の agentId は今のまま。
        let bad = s.merged(with: ["enabled": 0, "intervalMinutes": true, "agentId": "  ",
                                  "quietHours": ["start": "25:00", "end": "x", "enabled": "no"]])
        XCTAssertEqual(bad, s)
        XCTAssertEqual(s.merged(with: ["quietHours": ["end": "7:5"]]).quietHours.end, "07:05")
    }

    func testMergeFromJSONText() throws {
        let patch = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(#"{"enabled":true,"intervalMinutes":720,"quietHours":{"enabled":false}}"#.utf8)) as? [String: Any])
        var s = HeartbeatSettings.defaults
        s.enabled = false
        let m = s.merged(with: patch)
        XCTAssertTrue(m.enabled)
        XCTAssertEqual(m.intervalMinutes, 720)
        XCTAssertFalse(m.quietHours.enabled)
    }

    // MARK: - 静かな時間・回すかどうか

    func testQuietHoursWrapsMidnight() {
        let q = HeartbeatSettings.QuietHours(enabled: true, start: "22:00", end: "08:00")
        XCTAssertTrue(HeartbeatRules.inQuietHours(q, at: at(22, 0), calendar: cal))
        XCTAssertTrue(HeartbeatRules.inQuietHours(q, at: at(23, 59), calendar: cal))
        XCTAssertTrue(HeartbeatRules.inQuietHours(q, at: at(0, 0), calendar: cal))
        XCTAssertTrue(HeartbeatRules.inQuietHours(q, at: at(7, 59), calendar: cal))
        XCTAssertFalse(HeartbeatRules.inQuietHours(q, at: at(8, 0), calendar: cal))
        XCTAssertFalse(HeartbeatRules.inQuietHours(q, at: at(21, 59), calendar: cal))
        XCTAssertFalse(HeartbeatRules.inQuietHours(q, at: at(12, 0), calendar: cal))

        let day = HeartbeatSettings.QuietHours(enabled: true, start: "13:00", end: "14:00")
        XCTAssertTrue(HeartbeatRules.inQuietHours(day, at: at(13, 30), calendar: cal))
        XCTAssertFalse(HeartbeatRules.inQuietHours(day, at: at(14, 0), calendar: cal))
        XCTAssertFalse(HeartbeatRules.inQuietHours(day, at: at(12, 59), calendar: cal))

        var off = q
        off.enabled = false
        XCTAssertFalse(HeartbeatRules.inQuietHours(off, at: at(23, 0), calendar: cal))
        XCTAssertFalse(HeartbeatRules.inQuietHours(.init(enabled: true, start: "10:00", end: "10:00"), at: at(10, 0), calendar: cal),
                       "start == end は静かな時間なし")
    }

    func testIsDue() {
        let s = HeartbeatSettings.defaults   // 180 分、22〜8 時は止める
        let started = at(12, 0)
        // 初めて: 起きてから 10 分後。
        XCTAssertFalse(HeartbeatRules.isDue(settings: s, lastRunAt: nil, startedAt: started, now: at(12, 9), calendar: cal))
        XCTAssertTrue(HeartbeatRules.isDue(settings: s, lastRunAt: nil, startedAt: started, now: at(12, 10), calendar: cal))
        // 前回の開始から間隔。
        XCTAssertFalse(HeartbeatRules.isDue(settings: s, lastRunAt: at(13, 0), startedAt: started, now: at(15, 59), calendar: cal))
        XCTAssertTrue(HeartbeatRules.isDue(settings: s, lastRunAt: at(13, 0), startedAt: started, now: at(16, 0), calendar: cal))
        // 静かな時間は回さない。
        XCTAssertFalse(HeartbeatRules.isDue(settings: s, lastRunAt: at(19, 0), startedAt: started, now: at(23, 0), calendar: cal))
        var noQuiet = s
        noQuiet.quietHours.enabled = false
        XCTAssertTrue(HeartbeatRules.isDue(settings: noQuiet, lastRunAt: at(19, 0), startedAt: started, now: at(23, 0), calendar: cal))
        // 止めていれば回さない。
        var off = s
        off.enabled = false
        XCTAssertFalse(HeartbeatRules.isDue(settings: off, lastRunAt: at(1, 0), startedAt: started, now: at(16, 0), calendar: cal))
    }

    func testNextRunAt() {
        let s = HeartbeatSettings.defaults
        let started = at(12, 0)
        XCTAssertEqual(HeartbeatRules.nextRunAt(settings: s, lastRunAt: at(13, 0), startedAt: started, now: at(14, 0), calendar: cal),
                       at(16, 0))
        XCTAssertEqual(HeartbeatRules.nextRunAt(settings: s, lastRunAt: nil, startedAt: started, now: at(12, 1), calendar: cal),
                       at(12, 10))
        // 静かな時間に当たれば、その終わり（翌朝 8 時）。
        XCTAssertEqual(HeartbeatRules.nextRunAt(settings: s, lastRunAt: at(20, 0), startedAt: started, now: at(20, 30), calendar: cal),
                       at(8, 0, day: 21))
        // 日付が変わってからの静かな時間（同じ日の 8 時）。
        XCTAssertEqual(HeartbeatRules.nextRunAt(settings: s, lastRunAt: at(0, 0, day: 21), startedAt: started, now: at(1, 0, day: 21),
                                                calendar: cal),
                       at(8, 0, day: 21))
        // 過ぎていれば今。
        XCTAssertEqual(HeartbeatRules.nextRunAt(settings: s, lastRunAt: at(9, 0), startedAt: started, now: at(18, 0), calendar: cal),
                       at(18, 0))
        var off = s
        off.enabled = false
        XCTAssertNil(HeartbeatRules.nextRunAt(settings: off, lastRunAt: nil, startedAt: started, now: at(12, 0), calendar: cal))
    }

    // MARK: - 返事

    func testHeartbeatOkDetection() {
        XCTAssertTrue(HeartbeatRules.isOk("HEARTBEAT_OK"))
        XCTAssertTrue(HeartbeatRules.isOk("  HEARTBEAT_OK\n"))
        XCTAssertTrue(HeartbeatRules.isOk("HEARTBEAT_OK 異常なし"))
        XCTAssertTrue(HeartbeatRules.isOk("HEARTBEAT_OK" + String(repeating: "a", count: 28)), "40 文字ちょうど")
        XCTAssertFalse(HeartbeatRules.isOk("HEARTBEAT_OK" + String(repeating: "a", count: 29)), "41 文字")
        XCTAssertFalse(HeartbeatRules.isOk("異常なし。HEARTBEAT_OK"))
        XCTAssertFalse(HeartbeatRules.isOk(""))
    }

    func testPushBodyTruncation() {
        XCTAssertEqual(HeartbeatRules.pushBody("一\n\n二\n三\n四\n五"), "一\n二\n三")
        XCTAssertEqual(HeartbeatRules.pushBody("  承認待ちが 1 件  \n"), "承認待ちが 1 件")
        let long = HeartbeatRules.pushBody(String(repeating: "あ", count: 500))
        XCTAssertEqual(long.count, 200)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(HeartbeatRules.pushBody(String(repeating: "x", count: 200)).count, 200)
    }

    func testPromptIsFixedText() {
        let p = HeartbeatRules.prompt(at: at(9, 5), timeZone: tz)
        XCTAssertTrue(p.hasPrefix("[定期チェック 2026-10-20 09:05]\n"))
        XCTAssertTrue(p.contains("~/.buddyos/main/HEARTBEAT.md の項目に沿って"))
        XCTAssertTrue(p.contains("save_note"))
        XCTAssertTrue(p.contains("HEARTBEAT_OK とだけ返してください"))
        XCTAssertEqual(p.split(separator: "\n").count, 4)
    }

    func testPromptBodyCanBeChanged() {
        let p = HeartbeatRules.prompt(at: at(9, 5), body: "  承認待ちだけ見てください  ", timeZone: tz)
        XCTAssertTrue(p.hasPrefix("[定期チェック 2026-10-20 09:05]\n承認待ちだけ見てください\n"))
        XCTAssertFalse(p.contains("HEARTBEAT.md"))
        XCTAssertTrue(p.contains("HEARTBEAT_OK とだけ返してください"))
        XCTAssertEqual(HeartbeatRules.prompt(at: at(9, 5), body: "  ", timeZone: tz),
                       HeartbeatRules.prompt(at: at(9, 5), timeZone: tz))
        let s = HeartbeatSettings.defaults
        XCTAssertEqual(s.merged(with: ["prompt": "  x  "]).prompt, "x")
        XCTAssertEqual(s.merged(with: ["prompt": 1]).prompt, "")
        XCTAssertEqual(s.merged(with: ["prompt": String(repeating: "あ", count: 3000)]).prompt.count, 2000)
    }

    func testStatusJSON() throws {
        var state = HeartbeatState()
        state.sessionId = "s1"
        state.lastResult = "ok"
        state.lastRunAt = Date(timeIntervalSince1970: 0)
        let json = HeartbeatRules.statusJSON(settings: .defaults, state: state)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let settings = try XCTUnwrap(obj["settings"] as? [String: Any])
        XCTAssertEqual(settings["intervalMinutes"] as? Int, 180)
        XCTAssertEqual((settings["quietHours"] as? [String: Any])?["start"] as? String, "22:00")
        let st = try XCTUnwrap(obj["state"] as? [String: Any])
        XCTAssertEqual(st["sessionId"] as? String, "s1")
        XCTAssertEqual(st["lastRunAt"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertNil(st["lastMessage"], "無い項目は載せない")
    }

    func testStateRoundTrip() throws {
        let url = try tmpDir().appendingPathComponent("heartbeat-state.json")
        XCTAssertEqual(MainHeartbeat.loadState(at: url), HeartbeatState())
        var s = HeartbeatState()
        s.sessionId = "abc"
        s.agentId = "claude"
        s.lastRunAt = Date(timeIntervalSince1970: 1_800_000_000)
        s.lastResult = "reported"
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(s).write(to: url)
        XCTAssertEqual(MainHeartbeat.loadState(at: url), s)
    }

    // MARK: - メモ（save_note）

    func testNoteLine() {
        let now = at(10, 30)
        XCTAssertEqual(MainNotes.line("好み:\n短く", now: now, timeZone: tz), "- 2026-10-20 10:30 好み: 短く")
        XCTAssertNil(MainNotes.line(" \n ", now: now, timeZone: tz))
        let long = MainNotes.line(String(repeating: "x", count: 900), now: now, timeZone: tz)!
        XCTAssertEqual(long.count, "- 2026-10-20 10:30 ".count + 500)
    }

    func testNoteAppend() throws {
        let url = try tmpDir().appendingPathComponent("NOTES.md")
        try MainNotes.append("一つ目", url: url)
        var body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix(MainAgentWorkspace.notesInitial), "無ければ初期の中身で作る")
        XCTAssertTrue(body.hasSuffix(" 一つ目\n"))

        try Data("# 手で直した".utf8).write(to: url)   // 末尾に改行なし
        try MainNotes.append("二つ目", url: url)
        body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.hasPrefix("# 手で直した\n- "))
        XCTAssertTrue(body.hasSuffix(" 二つ目\n"))
        XCTAssertThrowsError(try MainNotes.append("   ", url: url))
    }

    func testSaveNoteTool() async throws {
        let root = try tmpDir().appendingPathComponent("main")
        MainAgentWorkspace.rootOverride = root
        defer { MainAgentWorkspace.rootOverride = nil }
        let main = Orchestrator.Caller(token: "t", agentId: "claude", parentSessionId: "p")
        let out = try await McpEndpoint.call("save_note", args: ["text": "覚えておく"], caller: main) as? [String: Any]
        XCTAssertTrue((out?["saved"] as? String)?.hasSuffix(" 覚えておく") ?? false)
        let body = try String(contentsOf: root.appendingPathComponent("NOTES.md"), encoding: .utf8)
        XCTAssertTrue(body.contains(" 覚えておく\n"))

        var delegate = main
        delegate.isMain = false
        do {
            _ = try await McpEndpoint.call("save_note", args: ["text": "x"], caller: delegate)
            XCTFail("ふつうのセッションは使えない")
        } catch {}
        XCTAssertTrue(McpEndpoint.tools.contains { $0["name"] as? String == "save_note" })
        XCTAssertTrue(MainAgentWorkspace.toolNames.contains("save_note"))
    }

    // MARK: - mainagent のフォルダ

    func testEnsureCreatesHeartbeatFilesOnlyIfMissing() throws {
        let base = try tmpDir()
        let root = base.appendingPathComponent("main")
        let projects = base.appendingPathComponent("projects.json")
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        let hb = root.appendingPathComponent("HEARTBEAT.md")
        let notes = root.appendingPathComponent("NOTES.md")
        XCTAssertEqual(try String(contentsOf: hb, encoding: .utf8), MainAgentWorkspace.heartbeatInitial)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), MainAgentWorkspace.notesInitial)
        XCTAssertTrue(MainAgentWorkspace.heartbeatInitial.contains("- 承認を待って止まっている会話はないか"))

        try Data("mine".utf8).write(to: hb)
        try Data("my notes".utf8).write(to: notes)
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        XCTAssertEqual(try String(contentsOf: hb, encoding: .utf8), "mine", "利用者のものは書き換えない")
        try Data(MainAgentWorkspace.legacyHeartbeatInitials[0].utf8).write(to: hb)
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        XCTAssertEqual(try String(contentsOf: hb, encoding: .utf8), MainAgentWorkspace.heartbeatInitial, "前の版のままなら今の版に")
        try Data("mine".utf8).write(to: hb)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "my notes")
    }

    func testManagedV2BlockIsUpgradedToV3() throws {
        let base = try tmpDir()
        let root = base.appendingPathComponent("main")
        let projects = base.appendingPathComponent("projects.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let old = "頭に足した文\n\(MainAgentWorkspace.managedBegin) v2 — 古い -->\n古い決まり\n\(MainAgentWorkspace.managedEnd)\n後ろに足した文\n"
        let claudeMd = root.appendingPathComponent("CLAUDE.md")
        try Data(old.utf8).write(to: claudeMd)
        MainAgentWorkspace.ensure(root: root, projectsURL: projects)
        let now = try String(contentsOf: claudeMd, encoding: .utf8)
        XCTAssertEqual(MainAgentWorkspace.managedVersion, 3)
        XCTAssertTrue(now.contains("\(MainAgentWorkspace.managedBegin) v3"))
        XCTAssertFalse(now.contains("古い決まり"))
        XCTAssertTrue(now.contains("定期チェック（[定期チェック …] で始まる依頼）では、HEARTBEAT.md に沿って見るだけにし"))
        XCTAssertTrue(now.hasPrefix("頭に足した文\n"))
        XCTAssertTrue(now.hasSuffix("後ろに足した文\n"))
    }

    // MARK: - 合鍵（無人でも定期チェックには渡す）

    func testGrantForHeartbeatOnlyInMainWorkspace() async throws {
        let base = try tmpDir()
        let root = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        MainAgentWorkspace.rootOverride = root
        defer { MainAgentWorkspace.rootOverride = nil }
        let o = Orchestrator()
        let cron = await o.sessionGrant(agentId: "claude", sessionId: nil, cwd: root.path, unattended: true)
        XCTAssertNil(cron, "無人（cron）には渡さない")
        let hb = await o.sessionGrant(agentId: "claude", sessionId: nil, cwd: root.path, unattended: true, heartbeat: true)
        XCTAssertEqual(hb?.isMain, true, "定期チェックには mainagent の道具を渡す")
        let elsewhere = await o.sessionGrant(agentId: "claude", sessionId: nil, cwd: base.path, unattended: true, heartbeat: true)
        XCTAssertNil(elsewhere, "mainagent のフォルダ以外では渡さない")
        if let t = hb?.token {
            let caller = await o.caller(token: t)
            XCTAssertEqual(caller?.isMain, true)
            await o.revoke(token: t)
        }
    }

    // MARK: - 1 回分の集め方

    /// 送った指示が待ち行列にある間に先に閉じた知らせのターン（バックグラウンドの作業の完了。done の metadata.origin =
    /// "task-notification"）は、指示の返事にしない。そのターンの本文もエラーも捨てて、指示のターンの done まで集める。
    func testPerformIgnoresNotificationTurnBeforeTheReply() async throws {
        let agent = "hb-\(UUID().uuidString.prefix(8).lowercased())"
        let adapter = ScriptedAdapter(id: agent) { sid in
            let s = ScriptedSession(agentId: agent, sessionId: sid ?? "\(agent)-s")
            s.onSend = { s, _, _ in
                let sid = s.sessionId
                s.emit(.assistantDelta("前の作業が終わりました。", agentId: agent, sessionId: sid, messageId: "n-1"))
                s.emit(SessionEvent(type: .error, agentId: agent, sessionId: sid, messageId: "n-1", toolUseId: nil,
                                    content: "知らせのターンのエラー", toolName: nil, metadata: nil))
                s.emit(SessionEvent.done(agentId: agent, sessionId: sid, messageId: "n-1")
                    .addingMetadata(["origin": "task-notification"]))
                s.emit(.assistantDelta("HEARTBEAT_OK", agentId: agent, sessionId: sid, messageId: "m-1"))
                s.emit(.done(agentId: agent, sessionId: sid, messageId: "m-1"))
            }
            return s
        }
        let run = await MainHeartbeat.perform(adapter: adapter, agentId: agent, sessionId: nil, prompt: "check")
        XCTAssertTrue(run.done)
        XCTAssertEqual(run.reply, "HEARTBEAT_OK", "知らせのターンの本文を返事にした")
        XCTAssertNil(run.errorText, "知らせのターンのエラーを指示の結果にした")
        XCTAssertTrue(run.gotOutput)
        XCTAssertFalse(run.timedOut)
    }

    /// 送った指示のターンがバックグラウンドのサブエージェントを起こしただけで done になる（Claude 2.1.300 の既定。実測 S1）。
    /// wakeTurn が true なら作業が終わった後に知らせのターン（結論）が来る。false なら来ない（子が終わっても親が起きない CLI）。
    private func backgroundAdapter(_ agent: String, wakeTurn: Bool) -> ScriptedAdapter {
        var tracker = SubagentTracker()
        let begin = tracker.begin(key: "a1", label: "調査", agentType: "Explore", background: true) ?? ""
        let finish = tracker.finish(key: "a1", state: "done", result: "原因は X") ?? ""
        return ScriptedAdapter(id: agent) { sid in
            let s = ScriptedSession(agentId: agent, sessionId: sid ?? "\(agent)-s")
            s.onSend = { s, _, _ in
                let sid = s.sessionId
                s.emit(.workflowProgress(agentId: agent, sessionId: sid, payloadJSON: begin))
                s.emit(.assistantDelta("Explore で調べています。", agentId: agent, sessionId: sid, messageId: "m-1"))
                s.emit(.done(agentId: agent, sessionId: sid, messageId: "m-1"))
                try? await Task.sleep(nanoseconds: 200_000_000)
                s.emit(.workflowProgress(agentId: agent, sessionId: sid, payloadJSON: finish))
                guard wakeTurn else { return }
                s.emit(.activity(agentId: agent, sessionId: sid, messageId: "n-1", text: ""))
                s.emit(.assistantDelta("原因は X でした。", agentId: agent, sessionId: sid, messageId: "n-1"))
                s.emit(SessionEvent.done(agentId: agent, sessionId: sid, messageId: "n-1")
                    .addingMetadata(["origin": "task-notification"]))
            }
            return s
        }
    }

    /// 送った指示のターンが done になっても、バックグラウンドのサブエージェントが動いている間は集め続ける。返事は、
    /// 結論を運ぶ知らせのターンの最後の吹き出し（起動の文を「報告」にしない）。
    func testPerformWaitsForBackgroundWorkAndReportsTheConclusion() async throws {
        let agent = "hb-\(UUID().uuidString.prefix(8).lowercased())"
        let run = await MainHeartbeat.perform(adapter: backgroundAdapter(agent, wakeTurn: true), agentId: agent,
                                              sessionId: nil, prompt: "check")
        XCTAssertTrue(run.done)
        XCTAssertEqual(run.reply, "原因は X でした。", "起動の文を返事にした")
        XCTAssertNil(run.errorText)
        XCTAssertFalse(run.timedOut)
    }

    /// 作業が終わっても知らせのターンが来ないなら、猶予の後に起動の返事で打ち切る（runTimeout まで待たせない）。
    func testPerformSettlesWhenBackgroundEndsWithoutWakeTurn() async throws {
        let saved = MainHeartbeat.backgroundSettleSeconds
        MainHeartbeat.backgroundSettleSeconds = 0.3
        defer { MainHeartbeat.backgroundSettleSeconds = saved }
        let agent = "hb-\(UUID().uuidString.prefix(8).lowercased())"
        let started = Date()
        let run = await MainHeartbeat.perform(adapter: backgroundAdapter(agent, wakeTurn: false), agentId: agent,
                                              sessionId: nil, prompt: "check")
        XCTAssertTrue(run.done)
        XCTAssertEqual(run.reply, "Explore で調べています。")
        XCTAssertFalse(run.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 30)
    }

    func testCapabilityAndHealthFeature() {
        XCTAssertTrue(AgentCapabilities().heartbeat)
        let h = WebSocketServer.healthResponse(agents: [], aliveSessions: 0, bridgeId: "b", e2ePub: "p")
        XCTAssertTrue(h.features.contains("heartbeat"))
        XCTAssertEqual(SessionEventType(rawValue: "heartbeat_run_now"), .heartbeatRunNow)
        XCTAssertEqual(SessionEvent.heartbeatStatus("{}").type.rawValue, "heartbeat_status")
    }
}
