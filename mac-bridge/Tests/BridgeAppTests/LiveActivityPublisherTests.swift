import XCTest
@testable import BridgeApp

/// 登録簿への送り口を偽物にした LiveActivityPublisher（docs/BACKGROUND_CONTROL_2026-10-21.md §8.6・§8.7）。
/// 時計は手で進め（autoTick: false）、tick() を直接呼ぶ。
final class LiveActivityPublisherTests: XCTestCase {
    private static let batchId = "0b9e2f4a-1111-4222-8333-444455556666"

    private final class FakeLA: @unchecked Sendable {
        let targetsStatus = LockedBox<Int>(200)
        let sendResult = LockedBox<LiveActivitySendResult>(LiveActivitySendResult(status: 200, sent: true))
        let enabled = LockedBox<Bool>(true)
        let targetCalls = LockedBox<[[String]]>([])
        struct Sent: Equatable {
            var token: String
            var event: String
            var phase: String
            var running: Int
            var stale: Int?
            var dismiss: Int?
        }
        let sent = LockedBox<[Sent]>([])
        /// send の途中で呼ぶ（送信中に別の要求が入る場面を作る）。
        nonisolated(unsafe) var onSend: (@Sendable () async -> Void)?

        var sender: LiveActivitySender {
            LiveActivitySender(
                enabled: { [self] in enabled.value },
                targets: { [self] list in
                    targetCalls.update { $0.append(list.map(\.token)) }
                    return targetsStatus.value
                },
                send: { [self] token, _, event, state, _, stale, dismiss in
                    sent.update { $0.append(Sent(token: token, event: event, phase: state.phase, running: state.running,
                                                 stale: stale, dismiss: dismiss)) }
                    await onSend?()
                    return sendResult.value
                })
        }
    }

    private func check<T: Equatable>(_ actual: @autoclosure () async -> T, _ expected: T, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) async {
        let value = await actual()
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }

    private func token(_ c: Character) -> String { String(repeating: c, count: 64) }

    private func make(_ fake: FakeLA, clock: LockedBox<Double>) -> LiveActivityPublisher {
        LiveActivityPublisher(sender: fake.sender, clock: { clock.value }, newBatchId: { Self.batchId }, autoTick: false)
    }

    private func meta(_ activityId: String, batch: String = LiveActivityPublisherTests.batchId, running: Int = 1) -> [String: String] {
        ["activityId": activityId, "batch": batch, "environment": "production", "running": "\(running)", "failed": "0"]
    }

    /// 同じ key は大きい方、違う key は足す、古い seq は捨てる。
    func testSourcesMergeByKeyMaxAndSum() async {
        let clock = LockedBox<Double>(1000)
        let pub = make(FakeLA(), clock: clock)
        await pub.noteSource(.hub, counts: ["s1": 2, "s2": 1], seq: 1)
        await check(await pub.runningTotal, 3)
        await pub.noteSource(.panes, counts: ["s1": 3], seq: 1)
        await check(await pub.runningTotal, 4, "s1 は大きい方の 3 + s2 の 1")
        await pub.noteSource(.bg, counts: ["s3": 1, "s1": 1], seq: 1)
        await check(await pub.runningTotal, 5)
        await pub.noteSource(.hub, counts: [:], seq: 2)
        await check(await pub.runningTotal, 4)
        await pub.noteSource(.hub, counts: ["s9": 9], seq: 1)
        await check(await pub.runningTotal, 4, "古い seq は捨てる")
    }

    func testRegisterValidatesShape() async {
        let clock = LockedBox<Double>(1000)
        let pub = make(FakeLA(), clock: clock)
        let none = await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1"))
        XCTAssertEqual(none, .rejected("unknown batch"), "batch が無い間は受けない")
        await pub.noteSource(.hub, counts: ["s": 1], seq: 1)
        let batch = await pub.currentBatch
        XCTAssertEqual(batch, Self.batchId)

        await check(await pub.register(deviceKeyId: "d1", token: String(repeating: "A", count: 64), metadata: meta("act1")),
                       .accepted, "大文字は小文字にする")
        await check(await pub.register(deviceKeyId: "d1", token: String(repeating: "a", count: 63), metadata: meta("act2")),
                       .rejected("token"))
        await check(await pub.register(deviceKeyId: "d1", token: "zz" + String(repeating: "a", count: 62), metadata: meta("act2")),
                       .rejected("token"))
        await check(await pub.register(deviceKeyId: "d1", token: token("b"), metadata: meta("act 2")), .rejected("activityId"))
        await check(await pub.register(deviceKeyId: "d1", token: token("b"), metadata: meta("act2", batch: "not-a-uuid")),
                       .rejected("batch"))
        await check(await pub.register(deviceKeyId: "d1", token: token("b"),
                                          metadata: meta("act2", batch: Self.batchId.uppercased())), .rejected("batch"))
        await check(await pub.register(deviceKeyId: "d1", token: token("b"),
                                          metadata: meta("act2", batch: "99999999-1111-4222-8333-444455556666")),
                       .rejected("unknown batch"))
        await check(await pub.tokenCount, 1)
        let has = await pub.hasToken(deviceKeyId: "d1", activityId: "act1")
        XCTAssertTrue(has)
    }

    func testFifthTokenOfADeviceDropsTheOldestAndTotalIsCapped() async {
        let clock = LockedBox<Double>(1000)
        let pub = make(FakeLA(), clock: clock)
        await pub.noteSource(.hub, counts: ["s": 1], seq: 1)
        for (i, c) in "abcde".enumerated() {
            clock.value += 1
            await check(await pub.register(deviceKeyId: "d1", token: token(c), metadata: meta("act\(i)")), .accepted)
        }
        await check(await pub.tokenCount, 4)
        let oldest = await pub.hasToken(deviceKeyId: "d1", activityId: "act0")
        let newest = await pub.hasToken(deviceKeyId: "d1", activityId: "act4")
        XCTAssertFalse(oldest)
        XCTAssertTrue(newest)
        // 別の端末を足していくと全体は 8 件まで。
        for i in 0..<6 {
            clock.value += 1
            await pub.register(deviceKeyId: "d\(i + 2)", token: token(Character(String(i + 1))), metadata: meta("x\(i)"))
        }
        await check(await pub.tokenCount, 8)
        // 同じ key の新しい token は置き換える。
        await pub.register(deviceKeyId: "d1", token: token("f"), metadata: meta("act4"))
        await check(await pub.tokenCount, 8)
    }

    func testNothingIsSentWhileNotReady() async {
        let fake = FakeLA()
        fake.targetsStatus.value = 404
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        await pub.noteSource(.hub, counts: ["s": 3], seq: 1)
        await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1", running: 3))
        await pub.registryReady()
        await check(await pub.ready, false)
        let delay = await pub.recheckDelay
        XCTAssertEqual(delay, 3600, "404 は 1 時間後に確かめ直す")
        clock.value += 12
        await pub.noteSource(.hub, counts: ["s": 1], seq: 2)
        clock.value += 15
        await pub.tick()
        XCTAssertTrue(fake.sent.value.isEmpty, "ready が false の間は何も送らない")

        fake.enabled.value = false
        await pub.registryReady()
        await check(await pub.ready, false, "pushMode none（enabled が false）なら ready にしない")
        XCTAssertTrue(fake.sent.value.isEmpty)

        fake.enabled.value = true
        fake.targetsStatus.value = 200
        await pub.registryReady()
        await check(await pub.ready, true)
        await pub.tick()
        XCTAssertEqual(fake.sent.value.map(\.event), ["update"], "ready になったら、待たせていた最新の値を送る")
        XCTAssertEqual(fake.sent.value.first?.running, 1)
        XCTAssertEqual(fake.sent.value.first?.stale, 1500)
    }

    func testRetryDelaysFollowTheRegistryTable() async {
        for (status, delay) in [(429, 300.0), (500, 300.0), (0, 300.0)] {
            let fake = FakeLA()
            fake.targetsStatus.value = status
            let pub = make(fake, clock: LockedBox<Double>(1000))
            await pub.registryReady()
            let ready = await pub.ready
            let recheck = await pub.recheckDelay
            XCTAssertFalse(ready, "\(status)")
            XCTAssertEqual(recheck, delay, "\(status) は 5 分後に確かめ直す")
        }
        let fake = FakeLA()
        fake.targetsStatus.value = 401
        let pub = make(fake, clock: LockedBox<Double>(1000))
        await pub.registryReady()
        await check(await pub.ready, false)
    }

    /// 登録が済むまで push を待たせる。更新・終わり・dismissAfterSec は規則どおり。
    func testUpdateAndEndFlowThroughTheRegistry() async {
        let fake = FakeLA()
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        await pub.registryReady()
        await pub.noteSource(.hub, counts: ["s": 3], seq: 1)
        await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1", running: 3))
        XCTAssertEqual(fake.targetCalls.value.last, [token("a")], "token が増えたらすぐ宛先を登録する")
        clock.value += 20
        await pub.noteSource(.hub, counts: ["s": 2], seq: 2)
        XCTAssertEqual(fake.sent.value.map(\.event), ["update"])
        XCTAssertEqual(fake.sent.value.last?.running, 2)
        // 数が 0 になって 20 秒たつと終わり。
        clock.value += 5
        await pub.noteFinished(done: 3)
        await pub.noteSource(.hub, counts: [:], seq: 3)
        clock.value += 19
        await pub.tick()
        XCTAssertEqual(fake.sent.value.count, 1, "END_GRACE の間は送らない")
        clock.value += 1
        await pub.tick()
        XCTAssertEqual(fake.sent.value.map(\.event), ["update", "end"])
        XCTAssertEqual(fake.sent.value.last?.phase, "done")
        XCTAssertEqual(fake.sent.value.last?.dismiss, 300)
        let gone = await pub.hasToken(deviceKeyId: "d1", activityId: "act1")
        XCTAssertFalse(gone, "終わりを送ったら token を捨てる")
    }

    /// 登録簿は running 1〜999・failed 0〜999 しか受けない。超える数は 999 にして送る。
    func testCountsAreCappedAt999() async {
        let fake = FakeLA()
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        await pub.registryReady()
        await pub.noteSource(.hub, counts: ["a": 600, "b": 700], seq: 1)
        await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1", running: 999))
        clock.value += 20
        await pub.noteSource(.hub, counts: ["a": 600, "b": 800], seq: 2)
        await pub.noteFinished(failed: 2000)
        await pub.tick()
        XCTAssertTrue(fake.sent.value.allSatisfy { $0.running <= 999 })
        let state = await pub.currentBatch
        XCTAssertNotNil(state)
    }

    /// 400 は何度送っても通らない。30 秒・2 分で送り直さず捨てる。
    func testBadRequestIsNotRetried() async {
        let fake = FakeLA()
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        await pub.registryReady()
        await pub.noteSource(.hub, counts: ["s": 3], seq: 1)
        await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1", running: 3))
        fake.sendResult.value = LiveActivitySendResult(status: 400, error: "bad_request")
        clock.value += 20
        await pub.noteSource(.hub, counts: ["s": 2], seq: 2)
        XCTAssertEqual(fake.sent.value.count, 1)
        for _ in 0..<4 {
            clock.value += 130   // keepalive（600 秒）の前に、30 秒・2 分の送り直しの時刻を過ぎる
            await pub.tick()
        }
        XCTAssertEqual(fake.sent.value.count, 1, "捨てたので送り直さない")
    }

    /// 更新が失敗し続けても、終わりは数え直して送る（更新の失敗の回数を終わりに持ち越さない）。
    func testEndIsRetriedFromScratchAfterFailedUpdates() async {
        let fake = FakeLA()
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        await pub.registryReady()
        await pub.noteSource(.hub, counts: ["s": 9], seq: 1)
        await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1", running: 9))
        fake.sendResult.value = LiveActivitySendResult(status: 502)
        var seq: UInt64 = 1
        for n in stride(from: 8, through: 3, by: -1) {
            clock.value += 130
            seq += 1
            await pub.noteSource(.hub, counts: ["s": n], seq: seq)
            await pub.tick()
        }
        let updates = fake.sent.value.count
        XCTAssertGreaterThanOrEqual(updates, 5)
        seq += 1
        await pub.noteSource(.hub, counts: [:], seq: seq)
        clock.value += 20
        await pub.tick()
        let ends = { fake.sent.value.filter { $0.event == "end" }.count }
        XCTAssertEqual(ends(), 1)
        for _ in 0..<3 {
            clock.value += 130
            await pub.tick()
        }
        XCTAssertGreaterThanOrEqual(ends(), 2, "失敗した終わりは送り直す")
    }

    func testInvalidTokenIsDroppedAndUnknownTokenResyncs() async {
        let fake = FakeLA()
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        await pub.registryReady()
        await pub.noteSource(.hub, counts: ["s": 3], seq: 1)
        await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1", running: 3))
        fake.sendResult.value = LiveActivitySendResult(status: 403, error: "unknown_token")
        clock.value += 20
        await pub.noteSource(.hub, counts: ["s": 2], seq: 2)
        XCTAssertEqual(fake.sent.value.count, 1)
        XCTAssertEqual(fake.targetCalls.value.count, 2, "ready の確かめ + 登録（token が無い間は空の再送をしない）")
        fake.sendResult.value = LiveActivitySendResult(status: 200, sent: false, invalid: true)
        await pub.tick()
        XCTAssertEqual(fake.sent.value.count, 2, "登録し直した後に 1 回だけ送り直す")
        let has = await pub.hasToken(deviceKeyId: "d1", activityId: "act1")
        XCTAssertFalse(has, "invalid は token を捨てる")
    }

    /// 401 で ready を落としたあと、次に登録簿へ登録できたときに registryReadyIfNeeded が確かめ直す。
    func testReadyComesBackAfter401WhenRegistryRegistersAgain() async {
        let fake = FakeLA()
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        await pub.registryReadyIfNeeded()
        await check(await pub.ready, true)
        await pub.registryReadyIfNeeded()
        XCTAssertEqual(fake.targetCalls.value.count, 1, "ready のあとは確かめない")
        await pub.noteSource(.hub, counts: ["s": 1], seq: 1)
        await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1"))
        fake.sendResult.value = LiveActivitySendResult(status: 401)
        clock.value += 20
        await pub.noteSource(.hub, counts: ["s": 2], seq: 2)
        await check(await pub.ready, false, "401 で ready を落とす")
        await check(await pub.needsRegistryCheck, true)
        clock.value += 61
        fake.sendResult.value = LiveActivitySendResult(status: 200, sent: true)
        await pub.registryReadyIfNeeded()
        await check(await pub.ready, true, "登録簿への登録が通れば戻る")
    }

    /// 送っている間に token が替わったら、invalid の応答で新しい token を消さない。
    func testInvalidResponseKeepsReplacedToken() async {
        let fake = FakeLA()
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        await pub.registryReady()
        await pub.noteSource(.hub, counts: ["s": 3], seq: 1)
        await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1", running: 3))
        fake.sendResult.value = LiveActivitySendResult(status: 200, sent: false, invalid: true)
        // 送信の await の間に register が token を替える。
        fake.onSend = { [pub] in
            Task { await pub.register(deviceKeyId: "d1", token: self.token("b"), metadata: self.meta("act1", running: 2)) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        clock.value += 20
        await pub.noteSource(.hub, counts: ["s": 2], seq: 2)
        let has = await pub.hasToken(deviceKeyId: "d1", activityId: "act1")
        XCTAssertTrue(has, "新しい token は残る")
    }

    /// 先に届いた register が clear の後に動いても、古い要求は捨てる。
    func testStaleRegisterAfterClearIsDropped() async {
        let clock = LockedBox<Double>(1000)
        let pub = make(FakeLA(), clock: clock)
        await pub.noteSource(.hub, counts: ["s": 1], seq: 1)
        await pub.clear(deviceKeyId: "d1", activityId: "act1", order: 2)
        let r = await pub.register(deviceKeyId: "d1", token: token("a"), metadata: meta("act1"), order: 1)
        XCTAssertEqual(r, .rejected("stale"))
        let has = await pub.hasToken(deviceKeyId: "d1", activityId: "act1")
        XCTAssertFalse(has)
    }

    func testBackgroundWorkStateIsSentOnRegisterAndOnChange() async throws {
        let fake = FakeLA()
        let clock = LockedBox<Double>(1000)
        let pub = make(fake, clock: clock)
        let events = LockedBox<[SessionEvent]>([])
        let id = await pub.register(send: { e in events.update { $0.append(e) } })
        func json(_ e: SessionEvent) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data((e.content ?? "").utf8)) as? [String: Any])
        }
        XCTAssertEqual(events.value.count, 1, "登録したときに今の値を 1 回")
        let first = try json(events.value[0])
        XCTAssertEqual(events.value[0].type, .backgroundWorkState)
        XCTAssertEqual(first["v"] as? Int, 1)
        XCTAssertEqual(first["phase"] as? String, "idle")
        XCTAssertEqual(first["push"] as? Bool, false)
        XCTAssertTrue(first["batch"] is NSNull)
        XCTAssertNotNil(first["boot"] as? String)

        await pub.noteSource(.hub, counts: ["s": 2], seq: 1)
        XCTAssertEqual(events.value.count, 2, "batch の始まりはすぐ")
        let started = try json(events.value[1])
        XCTAssertEqual(started["phase"] as? String, "running")
        XCTAssertEqual(started["running"] as? Int, 2)
        XCTAssertEqual(started["batch"] as? String, Self.batchId)
        XCTAssertEqual(started["since"] as? Int, 1000)
        XCTAssertEqual(started["rev"] as? Int, (first["rev"] as? Int ?? 0) + 1)

        // 数の変化は 1 秒まとめる。
        clock.value += 0.2
        await pub.noteSource(.hub, counts: ["s": 3], seq: 2)
        XCTAssertEqual(events.value.count, 2)
        clock.value += 1
        await pub.tick()
        XCTAssertEqual(events.value.count, 3)
        XCTAssertEqual(try json(events.value[2])["running"] as? Int, 3)

        await pub.unregister(id)
        clock.value += 2
        await pub.noteSource(.hub, counts: ["s": 1], seq: 3)
        XCTAssertEqual(events.value.count, 3, "外した後は送らない")
        _ = fake
    }

    func testRequestBodiesCarryOnlyTheAllowedFields() {
        let body = PushService.liveActivityBody(token: token("a"), env: "development", event: "update",
                                                state: LiveActivityState(phase: "running", running: 3, failed: 1),
                                                timestamp: 1_792_540_805, staleAfterSec: 1500, dismissAfterSec: 300)
        XCTAssertEqual(Set(body.keys), ["environment", "token", "event", "timestamp", "state", "staleAfterSec"])
        XCTAssertEqual(body["environment"] as? String, "sandbox")
        XCTAssertEqual(body["state"] as? [String: AnyHashable], ["phase": "running", "running": 3, "failed": 1])
        let end = PushService.liveActivityBody(token: token("a"), env: "production", event: "end",
                                               state: LiveActivityState(phase: "done", running: 0, failed: 0),
                                               timestamp: 1, staleAfterSec: 1500, dismissAfterSec: 300)
        XCTAssertEqual(Set(end.keys), ["environment", "token", "event", "timestamp", "state", "dismissAfterSec"])
        XCTAssertEqual(end["environment"] as? String, "production")
    }

    func testTargetsBodyAndResponseParsing() {
        let tokens = (0..<10).map { i in (token: String(repeating: String(i), count: 64), env: i == 0 ? "development" : "production") }
        let body = PushService.liveActivityTargetsBody(tokens + [tokens[1]])
        let list = body["targets"] as? [[String: String]]
        XCTAssertEqual(list?.count, 8, "8 件まで")
        XCTAssertEqual(list?.first?["tokenHash"], PushService.tokenHash(tokens[0].token))
        XCTAssertEqual(list?.first?["env"], "sandbox")
        XCTAssertEqual(list?[1]["env"], "production")
        XCTAssertEqual((PushService.liveActivityTargetsBody([])["targets"] as? [Any])?.count, 0)

        let ok = PushService.liveActivityResult(status: 200, data: Data(#"{"ok":true,"sent":true,"invalid":false}"#.utf8), retryAfter: nil)
        XCTAssertEqual(ok, LiveActivitySendResult(status: 200, sent: true))
        let invalid = PushService.liveActivityResult(status: 200, data: Data(#"{"ok":true,"sent":false,"invalid":true}"#.utf8), retryAfter: nil)
        XCTAssertTrue(invalid.invalid)
        let unknown = PushService.liveActivityResult(status: 403, data: Data(#"{"error":"unknown_token"}"#.utf8), retryAfter: nil)
        XCTAssertEqual(unknown.error, "unknown_token")
        let limited = PushService.liveActivityResult(status: 429, data: Data(), retryAfter: 42)
        XCTAssertEqual(limited.retryAfter, 42)
        XCTAssertFalse(limited.sent)
    }
}
