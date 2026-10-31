import Foundation

/// Last known outcome of the registry heartbeat, written to
/// `~/.buddyos/registry-status.json` so the desktop can answer the one question
/// a user actually has: "can my phone find this Mac right now?"
///
/// WHY THIS EXISTS: registration used to fail silently. The refresh error was
/// swallowed with a comment calling it non-fatal, which stopped being true once
/// discovery began hiding registrations older than two hours — a Mac could sit
/// undiscoverable for six days with nothing on screen saying so, while the phone
/// showed only a generic "could not connect to server". The file is the source
/// of truth for that state; it holds no credentials, only an outcome.
enum RegistryStatus {
    /// Mirrors the file's JSON. `auth` says WHICH credential carried the last
    /// success, so "signed out but still reachable" is a legible state rather
    /// than a contradiction.
    struct Snapshot {
        var lastSuccessAt: Double?
        var lastAttemptAt: Double
        var auth: String?          // "device" | "clerk"
        var hasDeviceToken: Bool
        var lastError: String?
        /// Convex の 409 で bridgeId を作り直したときの古い bridgeId（spec/PROTOCOL-v3.md §15.4。デスクトップは案内を出す）。
        var registryPrevious: Previous? = nil
    }

    /// `registryPrevious`（時刻は UNIX ミリ秒）。
    struct Previous: Equatable {
        var bridgeId: String
        var since: Int64
    }

    /// v3 で増えた失敗の理由。
    /// revoked = アカウントから外された、key_changed = 登録簿の鍵と食い違い（409）、hold = registry-hold の間、
    /// rate_limited = 429、key_io = e2e-key を読めない。
    enum Reason {
        static let revoked = "revoked"
        static let keyChanged = "key_changed"
        static let hold = "hold"
        static let rateLimited = "rate_limited"
        static let keyIO = "key_io"
        static let signinRequired = "signin-required"
    }

    private static var fileURL: URL {
        BuddyPaths.root.appendingPathComponent("registry-status.json")
    }

    static func recordSuccess(usedDeviceToken: Bool) {
        let now = Date().timeIntervalSince1970
        write(Snapshot(
            lastSuccessAt: now,
            lastAttemptAt: now,
            auth: usedDeviceToken ? "device" : "clerk",
            hasDeviceToken: KeyStore.deviceToken() != nil,
            lastError: nil,
            registryPrevious: read()?.registryPrevious
        ))
    }

    /// 409 で bridgeId を作り直す前の bridgeId を控える。
    static func recordPrevious(bridgeId: String) {
        var s = read() ?? Snapshot(lastSuccessAt: nil, lastAttemptAt: Date().timeIntervalSince1970, auth: nil,
                                   hasDeviceToken: KeyStore.deviceToken() != nil, lastError: nil)
        s.registryPrevious = Previous(bridgeId: bridgeId, since: Int64(Date().timeIntervalSince1970 * 1000))
        write(s)
    }

    /// `/local/registry/previous/dismiss`。
    static func clearPrevious() {
        guard var s = read(), s.registryPrevious != nil else { return }
        s.registryPrevious = nil
        write(s)
    }

    static func recordFailure(_ reason: String) {
        // Keep the previous success timestamp: "last seen 4 minutes ago" and
        // "last seen 6 days ago" call for very different words on screen.
        let previous = read()
        write(Snapshot(
            lastSuccessAt: previous?.lastSuccessAt,
            lastAttemptAt: Date().timeIntervalSince1970,
            auth: previous?.auth,
            hasDeviceToken: KeyStore.deviceToken() != nil,
            lastError: reason,
            registryPrevious: previous?.registryPrevious
        ))
    }

    static func read() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Snapshot(
            lastSuccessAt: json["lastSuccessAt"] as? Double,
            lastAttemptAt: json["lastAttemptAt"] as? Double ?? 0,
            auth: json["auth"] as? String,
            hasDeviceToken: json["hasDeviceToken"] as? Bool ?? false,
            lastError: json["lastError"] as? String,
            registryPrevious: (json["registryPrevious"] as? [String: Any]).flatMap { p in
                (p["bridgeId"] as? String).map {
                    Previous(bridgeId: $0, since: (p["since"] as? NSNumber)?.int64Value ?? 0)
                }
            }
        )
    }

    private static func write(_ snapshot: Snapshot) {
        var json: [String: Any] = [
            "lastAttemptAt": snapshot.lastAttemptAt,
            "hasDeviceToken": snapshot.hasDeviceToken,
        ]
        if let v = snapshot.lastSuccessAt { json["lastSuccessAt"] = v }
        if let v = snapshot.auth { json["auth"] = v }
        if let v = snapshot.lastError { json["lastError"] = v }
        if let p = snapshot.registryPrevious { json["registryPrevious"] = ["bridgeId": p.bridgeId, "since": p.since] }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
