import Foundation

/// `~/.hermes/cron/<job_id>/<timestamp>.md` の新規ファイル生成を監視し、
/// 接続中の WS クライアント全員に `.cronOutput` を broadcast するハブ。
actor CronOutputHub {
    static let shared = CronOutputHub()

    private var listeners: [UUID: @Sendable (SessionEvent) -> Void] = [:]
    private var seen: Set<String> = []
    private var watcherStarted = false
    private var watchSources: [DispatchSourceFileSystemObject] = []
    private var watchedJobDirs: Set<String> = []

    func register(send: @escaping @Sendable (SessionEvent) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = send
        return id
    }

    func unregister(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    static var outputRoot: String {
        NSHomeDirectory() + "/.hermes/cron/output"
    }

    /// 監視対象の出力ルート一覧。
    ///   - hermes native cron:  `~/.hermes/cron/output/<jobId>/<ts>.md`
    ///   - Bridge 内蔵 cron:    `~/.buddyos/cron/output/<jobId>/<ts>.md` (claude/codex)
    /// どちらも同じ「job ディレクトリ + タイムスタンプ md」レイアウトを使う。
    static var outputRoots: [String] {
        [outputRoot, BridgeCronScheduler.outputRoot]
    }

    /// push 済みファイルパスの永続化先。再起動や scan 失敗で seen が消えても
    /// 既に push したものを二度と再送しないため。
    private static var seenFile: String {
        NSHomeDirectory() + "/.buddyos/cron_pushed.json"
    }

    /// この秒数より古い出力は（未 push でも）通知しない。スキャン失敗等で
    /// 過去ファイルが「新規」と誤認された時の暴発を防ぐ最後の砦。
    private static let pushMaxAge: TimeInterval = 15 * 60

    func startIfNeeded() {
        guard !watcherStarted else { return }
        watcherStarted = true
        // root が無ければ作っておく (まだ一度も発火してない時)
        for root in Self.outputRoots {
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }
        // 永続化された push 済み集合と、現存ファイルの和集合で初期化する。
        // 現存ファイルを seen に含めることで「起動直後に過去分を一斉 push」を防ぐ。
        seen = Self.loadSeen().union(Self.scanRoots())
        Self.saveSeen(seen)
        for root in Self.outputRoots {
            watchRoot(root)
        }
        Task { await self.pollLoop() }
    }

    private static func scanRoots() -> Set<String> {
        var out: Set<String> = []
        for root in outputRoots {
            out.formUnion(scanAll(under: root))
        }
        return out
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let current = Self.scanRoots()
            let newFiles = current.subtracting(seen)
            // seen は単調増加のみ。scanAll が空/部分結果でも seen を縮めない
            // （= 既存ファイルを「新規」と誤認して再 push する暴発を防ぐ）。
            guard !newFiles.isEmpty else { continue }
            seen.formUnion(current)
            Self.saveSeen(seen)
            for path in newFiles {
                // 鮮度ゲート: 生成から pushMaxAge 以上経った古い出力は通知しない。
                let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                if let ts = Self.parseOutputTimestamp(stem),
                   Date().timeIntervalSince(ts) > Self.pushMaxAge {
                    continue
                }
                // sqlite3 の呼び出しを含むので、協調スレッド（actor の executor）の外で読む。
                if let event = await Self.parseOutputFileOffPool(path: path) {
                    if event.metadata?["silent"] == "1" { continue }
                    let snapshot = listeners.values
                    for l in snapshot { l(event) }
                    // APNs push: open してない iOS にも届ける
                    let title = event.metadata?["jobName"] ?? "Cron"
                    let body = String((event.content ?? "").prefix(200))
                    let jobId = event.sessionId ?? ""
                    let ts = event.metadata?["timestamp"] ?? ""
                    let continuableSessionId = event.metadata?["continuableSessionId"] ?? ""
                    let agentId = event.agentId ?? ""
                    Task {
                        await PushService.shared.broadcast(
                            title: title,
                            body: body,
                            payload: [
                                "kind": "cron_output",
                                "jobId": jobId,
                                "timestamp": ts,
                                "sessionId": continuableSessionId,
                                // タップで送信元の Mac の、その実行の会話（無ければジョブの結果一覧）を開くため。
                                "agentId": agentId,
                                "bridgeId": KeyStore.loadOrCreateBridgeId()
                            ]
                        )
                    }
                }
            }
        }
    }

    private func watchRoot(_ dir: String) {
        // 同じパスを二重に watch しない (FD リーク防止)
        guard watchedJobDirs.insert(dir).inserted else { return }
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            watchedJobDirs.remove(dir)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .global()
        )
        src.setEventHandler { [weak self] in
            Task { await self?.startIfNeeded() }  // 既存 watcher の確認 / poll に任せる
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchSources.append(src)
    }

    private static func loadSeen() -> Set<String> {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: seenFile)),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(arr)
    }

    private static func saveSeen(_ seen: Set<String>) {
        let dir = (seenFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(seen)) {
            try? data.write(to: URL(fileURLWithPath: seenFile))
        }
    }

    private static func scanAll(under root: String) -> Set<String> {
        var out: Set<String> = []
        let fm = FileManager.default
        guard let topItems = try? fm.contentsOfDirectory(atPath: root) else { return out }
        for item in topItems {
            // <root>/<job_id>/ 以下の *.md を回収
            let jobDir = root + "/" + item
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: jobDir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: jobDir) else { continue }
            for f in files where f.hasSuffix(".md") {
                out.insert(jobDir + "/" + f)
            }
        }
        return out
    }

    /// jobId として受け付ける形。出力ルートの下のディレクトリ名と SQL の LIKE に入るので、
    /// 英数字と . _ - だけ（"." / ".." は不可）にする。hermes の jobId は 16 進、Bridge cron は UUID。
    static func isValidJobId(_ jobId: String) -> Bool {
        guard !jobId.isEmpty, jobId.utf8.count <= 128, jobId != ".", jobId != ".." else { return false }
        return jobId.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A)
                || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    /// loadPastOutputs を協調スレッドの外（グローバルキュー）で行う。sqlite3 を待つ間に Swift の
    /// スレッドプールを塞がない。
    static func loadPastOutputsOffPool(jobId: String, limit: Int = 200) async -> [SessionEvent] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: loadPastOutputs(jobId: jobId, limit: limit))
            }
        }
    }

    private static func parseOutputFileOffPool(path: String) async -> SessionEvent? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: parseOutputFile(path: path))
            }
        }
    }

    /// 指定 jobId のすべての出力 (新しい順、最大 limit 件) を SessionEvent に変換して返す。
    /// jobId のディレクトリは hermes / bridge どちらのルートにもあり得るので両方探す。
    /// 形の違う jobId（"../" 等）は何も返さない。
    static func loadPastOutputs(jobId: String, limit: Int = 200) -> [SessionEvent] {
        guard isValidJobId(jobId) else { return [] }
        let fm = FileManager.default
        guard let dir = outputRoots.map({ $0 + "/" + jobId })
            .first(where: { fm.fileExists(atPath: $0) }) else { return [] }
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let mdFiles = files.filter { $0.hasSuffix(".md") }.sorted(by: >)  // 新しい順
        let timestamps = mdFiles.compactMap { parseOutputTimestamp(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) }
        let lower = (timestamps.min()?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) - 12 * 60 * 60
        let upper = (timestamps.max()?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) + 1
        let candidates = loadCronSessionCandidates(jobId: jobId, lowerBound: lower, upperBound: upper)
        var events: [SessionEvent] = []
        for f in mdFiles {
            guard let event = parseOutputFile(path: dir + "/" + f, candidates: candidates),
                  event.metadata?["silent"] != "1" else { continue }
            events.append(event)
            if events.count >= limit { break }
        }
        return events
    }

    private static func parseOutputFile(path: String, candidates: [CronSessionCandidate]? = nil) -> SessionEvent? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // ファイル名: <job_id>/<timestamp>.md
        let url = URL(fileURLWithPath: path)
        let timestamp = url.deletingPathExtension().lastPathComponent
        let jobId = url.deletingLastPathComponent().lastPathComponent
        let isBridgeOutput = path.hasPrefix(BridgeCronScheduler.outputRoot + "/")

        // markdown 先頭の "# <name>" を job name として抽出、本文は "---" 以降。
        // Bridge cron の出力は "# name" の後に "key: value" のヘッダ行
        // (agent / status / session) を持つ。hermes の出力にはヘッダが無い。
        var jobName = jobId
        var body = raw
        var headerAgent: String?
        var headerSession: String?
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, first.hasPrefix("# ") {
            jobName = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if let sepRange = raw.range(of: "\n---\n") {
            let header = String(raw[..<sepRange.lowerBound])
            body = String(raw[sepRange.upperBound...])
            if isBridgeOutput {
                for line in header.split(separator: "\n") {
                    let kv = line.split(separator: ":", maxSplits: 1).map {
                        String($0).trimmingCharacters(in: .whitespaces)
                    }
                    guard kv.count == 2 else { continue }
                    switch kv[0] {
                    case "agent": headerAgent = kv[1]
                    case "session": headerSession = kv[1]
                    default: break
                    }
                }
            }
        }
        // [SILENT] で通知を止めるのは hermes の出力だけ（Bridge cron の claude / codex は止めない）。
        let silent = !isBridgeOutput && isSilentCronOutput(body)
        if isBridgeOutput {
            return .cronOutput(
                agentId: headerAgent ?? "claude",
                jobId: jobId,
                jobName: jobName,
                timestamp: timestamp,
                content: body,
                continuableSessionId: headerSession,
                silent: silent
            )
        }
        return .cronOutput(
            agentId: "hermes",
            jobId: jobId,
            jobName: jobName,
            timestamp: timestamp,
            content: body,
            continuableSessionId: resolveCronSessionId(jobId: jobId, outputTimestamp: timestamp, candidates: candidates),
            silent: silent
        )
    }

    private struct CronSessionCandidate {
        let id: String
        let startedAt: Double
    }

    private static func resolveCronSessionId(jobId: String, outputTimestamp: String, candidates: [CronSessionCandidate]? = nil) -> String? {
        guard let outputDate = parseOutputTimestamp(outputTimestamp) else { return nil }
        let outputEpoch = outputDate.timeIntervalSince1970
        let lowerBound = outputEpoch - 12 * 60 * 60
        if let candidates {
            return candidates.last { candidate in
                candidate.startedAt >= lowerBound && candidate.startedAt <= outputEpoch + 1
            }?.id
        }
        return loadCronSessionCandidates(jobId: jobId, lowerBound: lowerBound, upperBound: outputEpoch + 1).last?.id
    }

    /// 1 回の問い合わせで読む行数の上限（出力が際限なく大きくならないように）。
    private static let sessionCandidateLimit = 500

    private static func loadCronSessionCandidates(jobId: String, lowerBound: Double, upperBound: Double) -> [CronSessionCandidate] {
        guard isValidJobId(jobId) else { return [] }
        // LIKE の _ と % は文字として扱わせる（jobId に _ があっても別の job に当たらないように）。
        let escapedJobId = likeEscape(sqlEscape(jobId))
        let sql = """
        SELECT id, started_at FROM (
          SELECT id, started_at
          FROM sessions
          WHERE source = 'cron'
            AND id LIKE 'cron\\_\(escapedJobId)\\_%' ESCAPE '\\'
            AND message_count > 0
            AND started_at >= \(formatEpoch(lowerBound))
            AND started_at <= \(formatEpoch(upperBound))
          ORDER BY started_at DESC
          LIMIT \(sessionCandidateLimit)
        ) ORDER BY started_at ASC;
        """
        return runSqlite(sql: sql).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let startedAt = Double(parts[1]) else { return nil }
            return CronSessionCandidate(id: parts[0], startedAt: startedAt)
        }
    }

    private static func parseOutputTimestamp(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd_HH-mm-ss", "yyyyMMdd_HHmmss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// sqlite3 を 1 回実行する。出力は ProcessRunner が並行して吸い上げるので、
    /// 64KB を超えてもパイプが詰まって止まらない（旧実装は waitUntilExit の後に読んでいて止まった）。
    /// 5 秒で打ち切る。ブロックするので協調スレッドから直接呼ばない。
    private static func runSqlite(sql: String) -> String {
        guard let r = ProcessRunner.run(
            "/usr/bin/sqlite3",
            ["-noheader", "-separator", "|", NSHomeDirectory() + "/.hermes/state.db", sql],
            timeout: 5.0
        ), !r.timedOut, r.status == 0 else { return "" }
        return String(data: r.stdout, encoding: .utf8) ?? ""
    }

    private static func sqlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func likeEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "%", with: "\\%")
    }

    private static func formatEpoch(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    /// hermes の「通知しない」印か（hermes の gateway/response_filters.py の
    /// is_autonomous_silence_response と同じ判定。hermes が配信を止めた出力だけ止める）。
    /// - 応答（"## Response" より後）が "[SILENT]" で始まる（"[SILENT] 変化なし" も含む）
    /// - 応答の全体・最初の行・最後の行のどれかが、ちょうど印（[SILENT] / SILENT / NO_REPLY / NO REPLY）。
    ///   前後の空白・大文字小文字・端の句読点（*NO_REPLY* など）は問わない
    /// 文の途中に "[SILENT]" が入っているだけ・プロンプトの説明文に含まれるだけでは止めない。
    static func isSilentCronOutput(_ content: String) -> Bool {
        let response: String
        if let range = content.range(of: "## Response") {
            response = String(content[range.upperBound...])
        } else {
            response = content
        }
        let stripped = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }
        if stripped.uppercased().hasPrefix("[SILENT]") { return true }
        let lines = stripped.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return [stripped, lines.first ?? "", lines.last ?? ""].contains(where: isSilenceMarker)
    }

    private static let silenceMarkers: Set<String> = ["[SILENT]", "SILENT", "NO_REPLY", "NO REPLY"]

    /// 印だけの短い文字列か（64 文字まで。端の句読点は外して見るが、[ ] は外さない）。
    private static func isSilenceMarker(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 64 else { return false }
        func canonical(_ t: Substring) -> String {
            t.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func isEdgePunctuation(_ c: Character) -> Bool { c != "[" && c != "]" && c.isPunctuation }
        var trimmed = Substring(s)
        while let c = trimmed.first, isEdgePunctuation(c) { trimmed = trimmed.dropFirst() }
        while let c = trimmed.last, isEdgePunctuation(c) { trimmed = trimmed.dropLast() }
        return silenceMarkers.contains(canonical(Substring(s)))
            || silenceMarkers.contains(canonical(trimmed))
    }
}
