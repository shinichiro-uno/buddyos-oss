import Foundation

/// 公開したサイトの一覧（iPhone / Android の「サイト」）。`sites_request` に `sites_report` で答える。
/// この Mac でログインしている CLI から読む（鍵は BuddyOS で預からない）。desktop/src/main/sites.ts の移植。
/// - Vercel: `vercel project ls --format json`（名前・本番の URL・更新日時。20 件ずつなので数ページ読む）
/// - Cloudflare Pages: `wrangler pages project list --json`（wrangler が無ければ npx で動かす）
/// Cloudflare Workers は CLI に一覧が無いので、まだ出さない。
struct SiteHostStatus: Codable, Sendable, Equatable {
    let host: String          // "vercel" | "cloudflare"
    let state: String         // "ok" | "missing" | "signedOut" | "error"
    var account: String? = nil
    var message: String? = nil
}

struct SiteItem: Codable, Sendable, Equatable {
    let host: String
    let name: String
    var url: String? = nil
    var updatedAt: String? = nil   // ISO8601
}

struct SiteList: Codable, Sendable {
    let hosts: [SiteHostStatus]
    let items: [SiteItem]
    let at: String
}

enum SitesReader {
    static let maxVercelPages = 5

    struct RunResult: Sendable {
        let ok: Bool
        let missing: Bool
        let out: String
        let err: String
    }

    // MARK: - 読み取り（純粋な関数。テストする）

    /// 出力の先頭にある案内の行を飛ばして、最初の { か [ から JSON として読む。
    static func parseJsonTail(_ out: String, open: Character) -> Any? {
        guard let i = out.firstIndex(of: open) else { return nil }
        guard let data = String(out[i...]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// JS の toISOString と同じ形（ミリ秒つき・UTC の Z）。
    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    static func vercelItems(_ projects: [[String: Any]]) -> [SiteItem] {
        projects.compactMap { p in
            guard let name = p["name"] as? String else { return nil }
            let url = (p["latestProductionUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let updatedAt = (p["updatedAt"] as? NSNumber).map { iso(Date(timeIntervalSince1970: $0.doubleValue / 1000)) }
            return SiteItem(host: "vercel", name: name, url: url, updatedAt: updatedAt)
        }
    }

    private static let unitSeconds: [String: TimeInterval] = [
        "second": 1, "minute": 60, "hour": 3_600, "day": 86_400,
        "week": 7 * 86_400, "month": 30 * 86_400, "year": 365 * 86_400,
    ]

    /// wrangler の「6 days ago」「a minute ago」をおおよその日時にする（Vercel と並べて新しい順にするため）。読めなければ nil。
    static func parseAgo(_ text: String, now: Date = Date()) -> String? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(
            pattern: "^(\\d+|an?)\\s+(second|minute|hour|day|week|month|year)s?\\s+ago$", options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
              let unit = unitSeconds[s[r2].lowercased()] else { return nil }
        let n = Double(s[r1]) ?? 1
        return iso(now.addingTimeInterval(-n * unit))
    }

    static func pagesItems(_ projects: [[String: Any]], now: Date = Date()) -> [SiteItem] {
        projects.compactMap { p in
            guard let name = p["Project Name"] as? String else { return nil }
            let domains = ((p["Project Domains"] as? String) ?? "")
                .components(separatedBy: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
                .filter { !$0.isEmpty }
            // 自分のドメインがあればそちらを先に（*.pages.dev は後ろ）。
            let main = domains.first { !$0.hasSuffix(".pages.dev") } ?? domains.first
            let url = main.map { $0.hasPrefix("http") ? $0 : "https://\($0)" }
            return SiteItem(host: "cloudflare", name: name, url: url,
                            updatedAt: parseAgo((p["Last Modified"] as? String) ?? "", now: now))
        }
    }

    /// ログインしていないときの CLI の言い方。
    static func notLoggedIn(_ err: String) -> Bool {
        err.range(of: "not (be )?(logged|authenticated)|log ?in|credentials|authenticate",
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func status(host: String, _ r: RunResult) -> SiteHostStatus {
        if r.missing { return SiteHostStatus(host: host, state: "missing") }
        if notLoggedIn(r.err) { return SiteHostStatus(host: host, state: "signedOut") }
        let tail = r.err.split(separator: "\n", omittingEmptySubsequences: false).suffix(3).joined(separator: "\n")
        return SiteHostStatus(host: host, state: "error", message: String(tail.prefix(400)))
    }

    // MARK: - CLI を動かす

    /// launchd の Bridge は PATH が狭いので、agent の CLI と同じ置き場所（ExecutableFinder）を足す。
    /// 対話の入力待ち（ログイン・確認）で止まらないよう CI=1。
    private static func environment(executable: String) -> [String: String] {
        var env = ChildEnvironment.base()
        var parts = [(executable as NSString).deletingLastPathComponent] + ExecutableFinder.candidateDirs()
        parts.append(env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["PATH"] = parts.joined(separator: ":")
        env["CI"] = "1"
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        return env
    }

    /// 協調スレッドをふさがないよう、探す（ログインシェルを起こすことがある）のも動かすのも専用キューで。
    static func run(_ name: String, _ args: [String], timeout: TimeInterval) async -> RunResult {
        await ProcessRunner.offload {
            guard let exe = ExecutableFinder.locate(name) else {
                return RunResult(ok: false, missing: true, out: "", err: "\(name): not found")
            }
            // 作業のフォルダにある vercel.json / wrangler.toml を拾わないよう、一時フォルダで動かす。
            guard let o = ProcessRunner.run(exe, args, timeout: timeout, environment: environment(executable: exe),
                                            currentDirectory: FileManager.default.temporaryDirectory.path) else {
                return RunResult(ok: false, missing: false, out: "", err: "\(name): failed to launch")
            }
            let out = String(decoding: o.stdout, as: UTF8.self)
            var err = String(decoding: o.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if o.timedOut { err = (err.isEmpty ? "" : err + "\n") + "\(name): timed out" }
            else if o.status != 0, err.isEmpty { err = "\(name): exit \(o.status)" }
            return RunResult(ok: !o.timedOut && o.status == 0, missing: false, out: out, err: err)
        }
    }

    /// 古い vercel が --format を知らないときの言い方（39.0.4 で確認）。
    static func tooOldVercel(_ err: String) -> Bool {
        err.range(of: "unknown or unexpected option", options: .caseInsensitive) != nil
    }

    static func readVercel() async -> (status: SiteHostStatus, items: [SiteItem]) {
        var items: [SiteItem] = []
        var next: Int64?
        var account: String?
        // 古い vercel（39.x など）は --format json を知らない。そのときは新しい版を npx で動かす。
        var viaNpx = false
        for page in 0..<maxVercelPages {
            var args = ["project", "ls", "--format", "json"]
            if let next { args += ["--next", String(next)] }
            var r = viaNpx ? await run("npx", ["--yes", "vercel@latest"] + args, timeout: 120) : await run("vercel", args, timeout: 45)
            if !viaNpx, !r.ok, tooOldVercel(r.err) {
                viaNpx = true
                r = await run("npx", ["--yes", "vercel@latest"] + args, timeout: 120)
            }
            guard r.ok, let j = parseJsonTail(r.out, open: "{") as? [String: Any] else {
                return page == 0 ? (status(host: "vercel", r), [])
                                 : (SiteHostStatus(host: "vercel", state: "ok", account: account), items)
            }
            if account == nil { account = j["contextName"] as? String }
            items += vercelItems((j["projects"] as? [[String: Any]]) ?? [])
            next = ((j["pagination"] as? [String: Any])?["next"] as? NSNumber)?.int64Value
            if next == nil || next == 0 { break }
        }
        return (SiteHostStatus(host: "vercel", state: "ok", account: account), items)
    }

    static func readCloudflare() async -> (status: SiteHostStatus, items: [SiteItem]) {
        let args = ["pages", "project", "list", "--json"]
        var r = await run("wrangler", args, timeout: 60)
        // wrangler を入れていない PC が多い。ログイン済みなら npx で動かせば読める（初回はダウンロードで時間がかかる）。
        if r.missing { r = await run("npx", ["--yes", "wrangler@4"] + args, timeout: 120) }
        guard r.ok, let j = parseJsonTail(r.out, open: "[") as? [[String: Any]] else {
            return (status(host: "cloudflare", r), [])
        }
        return (SiteHostStatus(host: "cloudflare", state: "ok"), pagesItems(j))
    }

    static func readAll() async -> SiteList {
        async let vercel = readVercel()
        async let cloudflare = readCloudflare()
        let (v, c) = await (vercel, cloudflare)
        return SiteList(hosts: [v.status, c.status], items: v.items + c.items, at: iso(Date()))
    }

    static func json(_ list: SiteList) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return (try? enc.encode(list)).map { String(decoding: $0, as: UTF8.self) } ?? "{\"hosts\":[],\"items\":[]}"
    }
}

/// 一覧を 5 分覚えておく（CLI は 1 回に数秒〜数十秒かかる）。同時の要求は 1 回の読み取りにまとめる。
actor SitesHub {
    static let shared = SitesHub()
    private static let cacheSeconds: TimeInterval = 5 * 60

    private var cache: (at: Date, value: SiteList)?
    private var inflight: Task<SiteList, Never>?

    /// force = true ならキャッシュを使わない（読み取り中のものがあればそれを待つ）。
    func list(force: Bool = false) async -> SiteList {
        if !force, let cache, Date().timeIntervalSince(cache.at) < Self.cacheSeconds { return cache.value }
        if let inflight { return await inflight.value }
        let task = Task { await SitesReader.readAll() }
        inflight = task
        let value = await task.value
        inflight = nil
        cache = (Date(), value)
        return value
    }
}
