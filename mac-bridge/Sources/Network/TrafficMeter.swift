import Foundation

/// iPhone ↔ Bridge transport traffic meter.
///
/// Only aggregate payload byte counts and message/request counts are retained.
/// User text, filenames, URLs, API keys, device tokens, and other payload content
/// are never stored. WebSocket protocol/TCP/TLS header overhead is intentionally
/// excluded, so `bytes` means application payload bytes that a relay would carry.
final class TrafficMeter: @unchecked Sendable {
    static let shared = TrafficMeter()

    struct Bucket: Codable, Equatable {
        var messages: Int = 0
        var bytes: Int64 = 0
    }

    struct Snapshot: Codable, Equatable {
        let startedAt: String
        let elapsedSeconds: Double
        let totalMessages: Int
        let totalBytes: Int64
        let buckets: [String: Bucket]
    }

    private let queue = DispatchQueue(label: "buddyos.traffic-meter")
    private var startedAt = Date()
    private var buckets: [String: Bucket] = [:]

    private init() {}

    func record(_ bucket: String, bytes: Int, messages: Int = 1) {
        guard bytes >= 0, messages >= 0 else { return }
        queue.sync {
            var current = buckets[bucket] ?? Bucket()
            current.messages += messages
            current.bytes += Int64(bytes)
            buckets[bucket] = current
        }
    }

    @discardableResult
    func reset() -> Snapshot {
        queue.sync {
            startedAt = Date()
            buckets.removeAll(keepingCapacity: true)
            return makeSnapshot(now: startedAt)
        }
    }

    func snapshot() -> Snapshot {
        queue.sync { makeSnapshot(now: Date()) }
    }

    private func makeSnapshot(now: Date) -> Snapshot {
        let totals = buckets.values.reduce(into: (messages: 0, bytes: Int64(0))) { partial, bucket in
            partial.messages += bucket.messages
            partial.bytes += bucket.bytes
        }
        return Snapshot(
            startedAt: ISO8601DateFormatter().string(from: startedAt),
            elapsedSeconds: max(0, now.timeIntervalSince(startedAt)),
            totalMessages: totals.messages,
            totalBytes: totals.bytes,
            buckets: buckets
        )
    }
}
