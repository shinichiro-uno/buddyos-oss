import XCTest
@testable import BridgeApp

/// cursor / grok を ACP で動かすときの AcpSession の振る舞い（モデル・モードの反映、承認の自動回答）。
/// ACP を話すフェイクのエージェント（python3）を executable に差して確かめる。
final class AcpCliTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-cli-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 受け取った要求を log に 1 行ずつ書く。session/prompt では編集の承認を 1 回求め、答えを log に書いてから返事する。
    private func writeFakeAgent(log: String) throws -> String {
        let url = tempDir.appendingPathComponent("fake-acp.py")
        let script = """
        #!/usr/bin/env python3
        import json, sys
        log = open('\(log)', 'a')
        def send(m):
            sys.stdout.write(json.dumps(m) + "\\n"); sys.stdout.flush()
        def config(model, mode):
            return [
              {"id": "mode", "category": "mode", "currentValue": mode, "options": [{"value": "agent", "name": "Agent"}, {"value": "plan", "name": "Plan"}]},
              {"id": "model", "category": "model", "currentValue": model, "options": [{"value": "default[]", "name": "Auto"}, {"value": "composer-2.5[fast=true]", "name": "composer-2.5"}]}]
        state = {"model": "default[]", "mode": "plan"}
        pending = None
        for line in sys.stdin:
            m = json.loads(line)
            method = m.get("method")
            if method:
                log.write(json.dumps({"method": method, "params": m.get("params")}) + "\\n"); log.flush()
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "11111111-2222-3333-4444-555555555555", "configOptions": config(state["model"], state["mode"])}})
            elif method == "session/set_config_option":
                state[m["params"]["configId"]] = m["params"]["value"]
                send({"jsonrpc": "2.0", "id": m["id"], "result": {"configOptions": config(state["model"], state["mode"])}})
            elif method == "session/prompt":
                pending = m["id"]
                send({"jsonrpc": "2.0", "id": 900, "method": "session/request_permission", "params": {
                    "sessionId": "s", "toolCall": {"toolCallId": "t1", "title": "Edit a.txt", "kind": "edit"},
                    "options": [{"optionId": "ok", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
            elif "result" in m and m.get("id") == 900:
                log.write(json.dumps({"permission": m["result"]}) + "\\n"); log.flush()
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "11111111-2222-3333-4444-555555555555", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "done!"}}}})
                # 通知と応答は別の経路で処理されるので、実機と同じく返事の本文を先に流し終えてから応答する。
                import time; time.sleep(0.3)
                send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "end_turn"}})
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testAppliesModelAndModeAndAutoAllowsEditsInEditMode() async throws {
        let log = tempDir.appendingPathComponent("log.jsonl").path
        let exe = try writeFakeAgent(log: log)
        var tuning = AcpSessionTuning()
        tuning.postSessionDelayNanos = 0
        tuning.loginShell = false
        tuning.modeConfigValues = ["plan": "plan", "*": "agent"]
        // 既定は Auto のまま、チャットでモデルとモード（edit）を選んだ。
        tuning.defaults = SessionOverrides(model: "auto", mode: "plan")
        let session = AcpSession(agentId: "cursor", initialSessionId: nil, executable: exe, args: [],
                                 cwd: tempDir.path, tuning: tuning)
        session.applyOverrides(SessionOverrides(model: "composer-2.5", mode: "edit"))

        let task = Task { () -> [SessionEvent] in
            var out: [SessionEvent] = []
            for try await e in session.events {
                out.append(e)
                if e.type == .done || e.type == .error { break }
            }
            return out
        }
        await session.send("edit it", skills: [], attachments: [])
        let events = (try? await task.value) ?? []
        await session.close()

        let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let sets = lines.filter { $0["method"] as? String == "session/set_config_option" }
            .compactMap { $0["params"] as? [String: Any] }
            .map { "\($0["configId"] ?? "")=\($0["value"] ?? "")" }
        XCTAssertTrue(sets.contains("model=composer-2.5[fast=true]"), "変種の付かない名前を選択肢の値に合わせる: \(sets)")
        XCTAssertTrue(sets.contains("mode=agent"), "edit は cursor の agent: \(sets)")
        let permission = lines.first { $0["permission"] != nil }?["permission"] as? [String: Any]
        let outcome = permission?["outcome"] as? [String: Any]
        XCTAssertEqual(outcome?["optionId"] as? String, "ok", "edit モードでは編集の承認を自動で許可する")
        XCTAssertFalse(events.contains { $0.type == .actionRequest }, "自動で答えた承認は iPhone に出さない")
        XCTAssertEqual(events.filter { $0.type == .assistantDelta }.compactMap(\.content).joined(), "done!")
        XCTAssertTrue(events.contains { $0.type == .done })
    }

    func testAutoPermissionAnswer() {
        let options: [(id: String, kind: String)] = [("a", "allow_once"), ("r", "reject_once")]
        XCTAssertEqual(AcpSession.autoPermissionAnswer(mode: "dangerous", toolKind: "execute", unattended: false, options: options), "a")
        XCTAssertEqual(AcpSession.autoPermissionAnswer(mode: "edit", toolKind: "edit", unattended: false, options: options), "a")
        XCTAssertNil(AcpSession.autoPermissionAnswer(mode: "edit", toolKind: "execute", unattended: false, options: options), "コマンドは聞く")
        XCTAssertNil(AcpSession.autoPermissionAnswer(mode: "auto", toolKind: "edit", unattended: false, options: options))
        XCTAssertEqual(AcpSession.autoPermissionAnswer(mode: "auto", toolKind: "execute", unattended: true, options: options), "r", "無人実行は拒否")
        XCTAssertEqual(AcpSession.autoPermissionAnswer(mode: nil, toolKind: nil, unattended: true, options: []), "", "拒否の選択肢が無ければ取り消す")
    }

    func testMatchOption() {
        let options: [(value: String, name: String)] = [("default[]", "Auto"), ("composer-2.5[fast=true]", "composer-2.5"), ("grok-4.7", "Grok 4.7")]
        XCTAssertEqual(AcpSession.matchOption("grok-4.7", in: options), "grok-4.7")
        XCTAssertEqual(AcpSession.matchOption("composer-2.5", in: options), "composer-2.5[fast=true]")
        XCTAssertEqual(AcpSession.matchOption("auto", in: options), "default[]")
        XCTAssertNil(AcpSession.matchOption("gpt-9", in: options))
    }
}
