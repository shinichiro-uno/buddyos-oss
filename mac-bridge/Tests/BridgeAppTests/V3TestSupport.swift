import Foundation
import XCTest
@testable import BridgeApp

/// 端末認証 v3 のテストで共通に使うもの（shared/e2e-test-vectors.json の tunnelV3・pairingV3 と、偽の中継）。
enum V3Vectors {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/e2e-test-vectors.json")

    static func load() throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func keys() throws -> [String: String] {
        try XCTUnwrap(try load()["keys"] as? [String: String])
    }
    static func tunnel() throws -> [String: Any] {
        try XCTUnwrap(try load()["tunnelV3"] as? [String: Any])
    }
    static func pairing() throws -> [String: Any] {
        try XCTUnwrap(try load()["pairingV3"] as? [String: Any])
    }
}

extension Data {
    init(v3hex hex: String) {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
    var v3hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// メモリの中だけの中継の WebSocket。テストが端末の側になって TEXT / バイナリを流し込む。
final class FakeTunnelTransport: TunnelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [TunnelMessage] = []
    private var waiters: [CheckedContinuation<TunnelMessage, Error>] = []
    private var outbound: [TunnelMessage] = []
    private(set) var closed = false
    private(set) var closedNormally: Bool?
    /// sendOrdered の完了の知らせを遅らせる（ナノ秒）。本物の中継では、送り終わりの知らせより先に
    /// 相手の返事が届くことがある（その順番のテスト用）。
    var sendCompletionDelay: UInt64 = 0

    struct Closed: Error {}

    // MARK: 端末の側
    func push(_ m: TunnelMessage) {
        lock.lock()
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            lock.unlock()
            w.resume(returning: m)
            return
        }
        inbound.append(m)
        lock.unlock()
    }

    /// Bridge が送った n 番目（0 から）のメッセージを待つ。閉じたか時間切れなら投げる。
    func sent(_ index: Int, timeout: TimeInterval = 5) async throws -> TunnelMessage {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let m: TunnelMessage? = lock.withLock { index < outbound.count ? outbound[index] : nil }
            if let m { return m }
            if lock.withLock({ closed }) { throw Closed() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Closed()
    }

    var sentCount: Int { lock.withLock { outbound.count } }

    // MARK: TunnelTransport（Bridge の側）
    func receive() async throws -> TunnelMessage {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbound.isEmpty {
                let m = inbound.removeFirst()
                lock.unlock()
                c.resume(returning: m)
                return
            }
            if closed {
                lock.unlock()
                c.resume(throwing: Closed())
                return
            }
            waiters.append(c)
            lock.unlock()
        }
    }

    func send(_ message: TunnelMessage) async throws {
        try record(message)
    }

    func sendOrdered(_ message: TunnelMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let result: Error?
        do { try record(message); result = nil } catch { result = error }
        let delay = sendCompletionDelay
        guard delay > 0 else { return completion(result) }
        Task {
            try? await Task.sleep(nanoseconds: delay)
            completion(result)
        }
    }

    private func record(_ message: TunnelMessage) throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            throw Closed()
        }
        outbound.append(message)
        lock.unlock()
    }

    func close(normal: Bool) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        closedNormally = normal
        let ws = waiters
        waiters.removeAll()
        lock.unlock()
        ws.forEach { $0.resume(throwing: Closed()) }
    }

    func waitClosed(timeout: TimeInterval = 5) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if lock.withLock({ closed }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return lock.withLock { closed }
    }
}

/// テスト用の一時フォルダ。
func makeTempDir(_ prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
