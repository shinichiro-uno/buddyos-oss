import XCTest
@testable import BridgeApp

final class TrafficMeterTests: XCTestCase {
    func testRecordsAndResetsAggregatePayloadOnly() {
        let meter = TrafficMeter.shared
        _ = meter.reset()

        meter.record("ws.in.user_message", bytes: 120)
        meter.record("ws.in.user_message", bytes: 80)
        meter.record("ws.out.assistant_delta", bytes: 64, messages: 2)

        let snapshot = meter.snapshot()
        XCTAssertEqual(snapshot.totalMessages, 4)
        XCTAssertEqual(snapshot.totalBytes, 264)
        XCTAssertEqual(snapshot.buckets["ws.in.user_message"], .init(messages: 2, bytes: 200))
        XCTAssertEqual(snapshot.buckets["ws.out.assistant_delta"], .init(messages: 2, bytes: 64))

        let reset = meter.reset()
        XCTAssertEqual(reset.totalMessages, 0)
        XCTAssertEqual(reset.totalBytes, 0)
        XCTAssertTrue(reset.buckets.isEmpty)
    }

    func testRejectsNegativeMeasurements() {
        let meter = TrafficMeter.shared
        _ = meter.reset()

        meter.record("bad", bytes: -1)
        meter.record("bad", bytes: 1, messages: -1)

        XCTAssertTrue(meter.snapshot().buckets.isEmpty)
    }
}
