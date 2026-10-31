import XCTest
@testable import BridgeApp

/// Live Activity の規則（LiveActivityRules）を、Windows と共有する shared/fixtures/live-activity/publisher-cases.json の
/// 12 ケースで確かめる（docs/BACKGROUND_CONTROL_2026-10-21.md §8.7）。0 秒から T 秒まで 1 秒ずつ進め、その秒の steps を順に入れて tick する。
final class LiveActivityRulesTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/fixtures/live-activity/publisher-cases.json")

    private func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    private func pushLine(_ p: LiveActivityRules.Push) -> String {
        "t=\(p.t) \(p.device)/\(p.activityId) \(p.event) p\(p.priority) \(p.state.phase) running=\(p.state.running) failed=\(p.state.failed) stale=\(p.staleAfterSec.map(String.init) ?? "-") dismiss=\(p.dismissAfterSec.map(String.init) ?? "-")"
    }

    private func pushLine(json p: [String: Any]) -> String {
        let s = p["state"] as? [String: Any] ?? [:]
        return "t=\(int(p["t"]) ?? -1) \(p["device"] as? String ?? "")/\(p["activityId"] as? String ?? "") \(p["event"] as? String ?? "") p\(int(p["priority"]) ?? -1) \(s["phase"] as? String ?? "") running=\(int(s["running"]) ?? -1) failed=\(int(s["failed"]) ?? -1) stale=\(int(p["staleAfterSec"]).map(String.init) ?? "-") dismiss=\(int(p["dismissAfterSec"]).map(String.init) ?? "-")"
    }

    private func stateLine(_ s: LiveActivityRules.BatchState) -> String {
        "t=\(s.t) \(s.batch ?? "nil") \(s.phase) running=\(s.running) failed=\(s.failed) since=\(s.since.map(String.init) ?? "nil")"
    }

    private func stateLine(json s: [String: Any]) -> String {
        "t=\(int(s["t"]) ?? -1) \(s["batch"] as? String ?? "nil") \(s["phase"] as? String ?? "") running=\(int(s["running"]) ?? -1) failed=\(int(s["failed"]) ?? -1) since=\(int(s["since"]).map(String.init) ?? "nil")"
    }

    func testConfigMatchesTheFixture() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL)) as? [String: Any])
        let cfg = try XCTUnwrap(root["cfg"] as? [String: Any])
        XCTAssertEqual(int(cfg["END_GRACE"]), LiveActivityRules.endGrace)
        XCTAssertEqual(int(cfg["MIN_INTERVAL"]), LiveActivityRules.minInterval)
        XCTAssertEqual(int(cfg["KEEPALIVE"]), LiveActivityRules.keepalive)
        XCTAssertEqual(int(cfg["STALE_AFTER"]), LiveActivityRules.staleAfter)
        XCTAssertEqual(int(cfg["DISMISS_DONE"]), LiveActivityRules.dismissDone)
        XCTAssertEqual(int(cfg["DISMISS_FAILED"]), LiveActivityRules.dismissFailed)
        XCTAssertEqual(int(cfg["ENDED_MEMORY"]), LiveActivityRules.endedMemory)
    }

    func testSharedPublisherCases() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 12)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let total = int(c["T"]) ?? 0
            var ids = (c["ids"] as? [String]) ?? []
            let clock = LockedBox<Int>(0)
            var rules = LiveActivityRules(now: { clock.value }, newBatchId: { ids.isEmpty ? "?" : ids.removeFirst() })
            var steps: [Int: [[String: Any]]] = [:]
            for s in (c["steps"] as? [[String: Any]]) ?? [] { steps[int(s["t"]) ?? 0, default: []].append(s) }
            var pushes: [String] = []
            var states: [String] = []
            for t in 0...total {
                clock.value = t
                for s in steps[t] ?? [] {
                    let arg = s["arg"]
                    let a = arg as? [String: Any] ?? [:]
                    switch s["op"] as? String {
                    case "counts": rules.counts(int(arg) ?? 0)
                    case "finished": rules.finished(done: int(a["done"]) ?? 0, failed: int(a["failed"]) ?? 0, stopped: int(a["stopped"]) ?? 0)
                    case "register":
                        rules.register(device: a["device"] as? String ?? "", activityId: a["activityId"] as? String ?? "",
                                       batch: a["batch"] as? String ?? "", shownRunning: int(a["shownRunning"]) ?? 0,
                                       shownFailed: int(a["shownFailed"]) ?? 0)
                    case "clear": rules.clear(device: a["device"] as? String ?? "", activityId: a["activityId"] as? String ?? "")
                    default: XCTFail("\(name): 知らない op")
                    }
                }
                rules.tick()
                pushes += rules.takePushes().map(pushLine)
                states += rules.takeStates().map(stateLine)
            }
            let expectPushes = ((c["expectPushes"] as? [[String: Any]]) ?? []).map { pushLine(json: $0) }
            let expectStates = ((c["expectStates"] as? [[String: Any]]) ?? []).map { stateLine(json: $0) }
            XCTAssertEqual(pushes, expectPushes, "\(name): push")
            XCTAssertEqual(states, expectStates, "\(name): state")
        }
    }

    func testUnknownBatchIsRefusedAndPriority10IsEndOnly() {
        let clock = LockedBox<Int>(0)
        var rules = LiveActivityRules(now: { clock.value }, newBatchId: { "b1" })
        XCTAssertFalse(rules.register(device: "d", activityId: "a", batch: "nope", shownRunning: 1, shownFailed: 0))
        rules.counts(1)
        XCTAssertTrue(rules.register(device: "d", activityId: "a", batch: "b1", shownRunning: 1, shownFailed: 0))
        clock.value = 15
        rules.counts(2)
        clock.value = 30
        rules.counts(0)
        clock.value = 60
        rules.tick()
        let pushes = rules.takePushes()
        XCTAssertEqual(pushes.filter { $0.priority == 10 }.map(\.event), ["end"])
        XCTAssertTrue(pushes.filter { $0.event == "update" }.allSatisfy { $0.priority == 5 })
    }
}
