import XCTest
@testable import BridgeApp

/// 公開したサイトの一覧（SitesReader）。desktop/src/main/sites.test.ts と同じ例。
final class SitesReaderTests: XCTestCase {
    func testVercelProjectList() throws {
        // 実機 2026-10-20 の形（先頭に案内の行、JSON の後ろは無し）。
        let out = """
        Vercel CLI 56.3.1
        {"projects":[{"name":"pato","latestProductionUrl":"https://timeshare.lat","updatedAt":1792334597615},{"name":"empty","latestProductionUrl":null}],"pagination":{"next":null},"contextName":"team"}
        """
        let j = try XCTUnwrap(SitesReader.parseJsonTail(out, open: "{") as? [String: Any])
        XCTAssertEqual(j["contextName"] as? String, "team")
        let items = SitesReader.vercelItems((j["projects"] as? [[String: Any]]) ?? [])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], SiteItem(host: "vercel", name: "pato", url: "https://timeshare.lat",
                                          updatedAt: SitesReader.iso(Date(timeIntervalSince1970: 1792334597.615))))
        XCTAssertEqual(items[0].updatedAt, "2026-10-18T14:43:17.615Z")
        XCTAssertNil(items[1].url)
        XCTAssertNil(items[1].updatedAt)
        XCTAssertNil(SitesReader.parseJsonTail("no json here", open: "{"))
    }

    func testPagesProjectList() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
        let out = """
        [{"Project Name":"efight","Project Domains":"efight.pages.dev, efight.jp","Git Provider":"No","Last Modified":"6 days ago"},{"Project Name":"plain","Project Domains":"plain.pages.dev","Last Modified":"yesterday"}]
        """
        let j = try XCTUnwrap(SitesReader.parseJsonTail(out, open: "[") as? [[String: Any]])
        let items = SitesReader.pagesItems(j, now: now)
        // 独自ドメインを先に。
        XCTAssertEqual(items[0].url, "https://efight.jp")
        XCTAssertEqual(items[0].updatedAt, "2026-10-14T00:00:00.000Z")
        XCTAssertEqual(items[0].host, "cloudflare")
        XCTAssertEqual(items[1].url, "https://plain.pages.dev")
        XCTAssertNil(items[1].updatedAt)
    }

    func testParseAgo() {
        let now = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
        XCTAssertEqual(SitesReader.parseAgo("a minute ago", now: now), "2026-10-19T23:59:00.000Z")
        XCTAssertEqual(SitesReader.parseAgo("an hour ago", now: now), "2026-10-19T23:00:00.000Z")
        XCTAssertEqual(SitesReader.parseAgo(" 2 Weeks ago ", now: now), "2026-10-06T00:00:00.000Z")
        XCTAssertNil(SitesReader.parseAgo("yesterday", now: now))
        XCTAssertNil(SitesReader.parseAgo("", now: now))
    }

    func testStatusMapping() {
        let missing = SitesReader.RunResult(ok: false, missing: true, out: "", err: "")
        XCTAssertEqual(SitesReader.status(host: "vercel", missing).state, "missing")
        let signedOut = SitesReader.RunResult(ok: false, missing: false, out: "", err: "Error: No existing credentials found. Please run `vercel login`")
        XCTAssertEqual(SitesReader.status(host: "vercel", signedOut).state, "signedOut")
        let other = SitesReader.RunResult(ok: false, missing: false, out: "", err: "a\nb\nc\nd boom")
        let s = SitesReader.status(host: "cloudflare", other)
        XCTAssertEqual(s.state, "error")
        XCTAssertEqual(s.message, "b\nc\nd boom")
    }

    /// 送る JSON の形（nil のキーは載せない）。
    func testReportJsonShape() throws {
        let list = SiteList(hosts: [SiteHostStatus(host: "vercel", state: "ok", account: "team"),
                                    SiteHostStatus(host: "cloudflare", state: "missing")],
                            items: [SiteItem(host: "vercel", name: "pato", url: "https://timeshare.lat")],
                            at: "2026-10-20T00:00:00.000Z")
        let event = SessionEvent.sitesReport(list)
        XCTAssertEqual(event.type.rawValue, "sites_report")
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((event.content ?? "").utf8)) as? [String: Any])
        let hosts = try XCTUnwrap(j["hosts"] as? [[String: Any]])
        XCTAssertEqual(hosts[0]["account"] as? String, "team")
        XCTAssertNil(hosts[1]["account"])
        XCTAssertNil(hosts[1]["message"])
        let item = try XCTUnwrap((j["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["url"] as? String, "https://timeshare.lat")
        XCTAssertNil(item["updatedAt"])
        XCTAssertEqual(j["at"] as? String, "2026-10-20T00:00:00.000Z")
        XCTAssertTrue(AgentCapabilities().sites)
    }

    /// この Mac の CLI で実際に読む。BUDDYOS_LIVE_SITES=1 のときだけ。
    func testLiveReadAll() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BUDDYOS_LIVE_SITES"] == "1")
        let list = await SitesReader.readAll()
        for h in list.hosts { print("LIVE sites host:", h.host, h.state, h.message ?? "") }
        print("LIVE sites vercel=\(list.items.filter { $0.host == "vercel" }.count) cloudflare=\(list.items.filter { $0.host == "cloudflare" }.count)")
    }
}
