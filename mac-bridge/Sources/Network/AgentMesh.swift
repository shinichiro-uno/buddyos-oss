import Foundation

/// エージェントどうしで頼み合う（どのセッションからも・別の PC へも）ための小物。
/// 道具の実体は Orchestrator、口は AgentMeshRoutes。
enum OrchestratorContext {
    /// Orchestrator が子のセッションを開くときの子の深さ。SessionHub.acquire → adapter.openSession は
    /// 同じ Task の中で呼ばれるので、adapter はここから深さを読んで合鍵を発行する（nil = 利用者が開いた。深さ 0）。
    @TaskLocal static var openingDepth: Int?
}

/// 「ほかのエージェントに頼めるようにする」。`~/.buddyos/orchestrator-settings.json`（0600）。
/// 無ければ有効。切り替えは次に開くセッションから効く（開いているセッションの合鍵は取り上げない）。
enum OrchestratorSettings {
    static var fileURL: URL { BuddyPaths.root.appendingPathComponent("orchestrator-settings.json") }

    static var allSessions: Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let on = obj["allSessions"] as? Bool else { return true }
        return on
    }

    static func setAllSessions(_ on: Bool) throws {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["allSessions": on], options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// 別の PC 1 台（`PUT /local/remote-pcs` の 1 行）。メモリにだけ持つ（合言葉が入るのでファイルに書かない）。
struct RemotePC: Sendable, Equatable {
    let bridgeId: String
    let name: String
    let platform: String
    /// デスクトップの中継口（PaseoProxy）が 127.0.0.1 で待ち受ける番号。
    let port: Int
    /// 中継口の合言葉（`bdp_…`）。中継口がこれを bdc_ に付け替えて B へ送る。
    let secret: String

    /// `{"pcs":[{"bridgeId","name","platform","port","secret"}]}` を読む。形が違えば nil（まるごと断る）。
    static func parseList(_ body: Any?) -> [RemotePC]? {
        guard let obj = body as? [String: Any], let rows = obj["pcs"] as? [Any] else { return nil }
        var out: [RemotePC] = []
        for raw in rows {
            guard let r = raw as? [String: Any],
                  let id = (r["bridgeId"] as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
                  let name = r["name"] as? String,
                  let port = (r["port"] as? NSNumber)?.intValue, (1...65535).contains(port),
                  let secret = r["secret"] as? String, !secret.isEmpty else { return nil }
            let platform = (r["platform"] as? String) ?? "mac"
            guard !out.contains(where: { $0.bridgeId == id }) else { continue }
            out.append(RemotePC(bridgeId: id, name: name, platform: platform, port: port, secret: secret))
        }
        return out
    }
}

/// Bridge A → デスクトップ A の中継口 → Bridge B の `POST /device/orchestrator/<tool>`。
enum RemoteOrchestratorClient {
    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    /// テストで差し替える（nil = URLSession で送る）。
    nonisolated(unsafe) static var transportOverride: (@Sendable (URLRequest) async throws -> Response)?

    static func post(pc: RemotePC, tool: String, body: [String: Any], timeout: TimeInterval) async throws -> Response {
        guard let url = URL(string: "http://127.0.0.1:\(pc.port)/device/orchestrator/\(tool)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(pc.secret)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        if let override = transportOverride { return try await override(req) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: req)
        return Response(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}
