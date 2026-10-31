import Foundation

/// Claude / Codex の使用量を定期取得し、接続中の WS クライアント全員に
/// `.usageReport` を broadcast するハブ。CronOutputHub と同じ購読モデル。
///
/// セッション非アクティブでもサイドバーに % を出したいので、ACP 接続とは独立した
/// ポーラーとして動かす（UsageReader が file tail + HTTP で読む）。
actor UsageHub {
    static let shared = UsageHub()

    private var listeners: [UUID: @Sendable (SessionEvent) -> Void] = [:]
    private var started = false
    private var cached: UsageReport?
    private var refreshing = false
    /// provider ごとの直近の成功値と取得時刻。429 等の一時失敗時に再利用する。
    private var lastGood: [String: (ProviderUsage, Date)] = [:]
    /// ポーリング間隔。サブスク枠の % は分単位でしか動かないので 60s で十分。
    private static let pollIntervalNanos: UInt64 = 60 * 1_000_000_000
    /// 一時失敗時に前回成功値を使い続ける最大時間。% は分単位でしか動かないので
    /// 30 分以内の古い値でも実用上問題ない。これを超えると失敗を隠さず伝える。
    private static let staleTTLSeconds: TimeInterval = 30 * 60

    func register(send: @escaping @Sendable (SessionEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = send
        // 接続直後にキャッシュ済みレポートを即返す（次の poll を待たせない）。
        if let cached, let event = Self.event(from: cached) {
            send(event)
        }
        return id
    }

    func unregister(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        Task { await pollLoop() }
    }

    /// iOS からの手動リフレッシュ（pull-to-refresh 等）。即時取得して broadcast。
    func requestRefresh() async {
        await refresh()
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
        }
    }

    private func refresh() async {
        // 取得は数秒かかり得るので、多重 poll を 1 本に間引く。
        guard !refreshing else { return }
        refreshing = true
        let fresh = await UsageReader.readAll()
        refreshing = false
        // oauth/usage は厳しいレート制限があり、他ポーラー（CLI・重複 bridge）と
        // 衝突すると 429 が返る。1 回の 429 で provider が UI から消えるのを防ぐため、
        // 直近の成功値を保持して差し替える。
        let report = mergedKeepingLastGood(fresh)
        cached = report
        guard let event = Self.event(from: report) else { return }
        for send in listeners.values { send(event) }
    }

    /// 一時的な取得失敗（429 等）でも provider が UI から消えないよう、
    /// 成功実績があれば TTL 内は前回値で埋める。一度も成功していなければ隠したまま。
    private func mergedKeepingLastGood(_ fresh: UsageReport) -> UsageReport {
        let now = Date()
        var out: [ProviderUsage] = []
        for p in fresh.providers {
            if p.hasData {
                lastGood[p.provider] = (p, now)
                out.append(p)
            } else if let (prev, when) = lastGood[p.provider],
                      now.timeIntervalSince(when) < Self.staleTTLSeconds {
                // 一時失敗。直前の成功値を維持して UI から消さない。
                out.append(prev)
            } else {
                out.append(p)
            }
        }
        return UsageReport(providers: out)
    }

    private static func event(from report: UsageReport) -> SessionEvent? {
        guard let data = try? JSONEncoder().encode(report),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return SessionEvent(
            type: .usageReport, agentId: nil, sessionId: nil,
            messageId: nil, toolUseId: nil, content: json,
            toolName: nil, metadata: nil
        )
    }
}
