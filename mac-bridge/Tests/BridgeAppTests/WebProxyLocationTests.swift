import XCTest
@testable import BridgeApp

final class WebProxyLocationTests: XCTestCase {
    private let origin = "http://127.0.0.1:40123"

    func testRootAbsoluteAndSamePortLocal() {
        XCTAssertEqual(WebProxy.rewriteLocation("/login?next=%2F", port: 5173, prefix: "/preview/web/5173"), "/preview/web/5173/login?next=%2F")
        XCTAssertEqual(WebProxy.rewriteLocation("http://localhost:5173/a?b=1#c", port: 5173, prefix: "/preview/web/5173"), "/preview/web/5173/a?b=1#c")
        XCTAssertEqual(WebProxy.rewriteLocation("http://127.0.0.1:3000/", port: 5173, prefix: "/preview/web/5173"), "http://127.0.0.1:3000/")
        XCTAssertEqual(WebProxy.rewriteLocation("//cdn.example.com/x", port: 5173, prefix: "/preview/web/5173"), "//cdn.example.com/x")
    }

    /// Clerk の handshake（実際の dev サーバーが返した形）。戻り先が端末から辿れる URL になる。
    func testExternalRedirectURLParamPointsBackThroughProxy() {
        let location = "https://eminent-mouse-3337.clerk.accounts.dev/v1/client/handshake?redirect_url=http%3A%2F%2F127.0.0.1%3A5173%2Fitems%3Fq%3Da%26p%3D2&__clerk_api_version=2026-05-12&format=nonce"
        let out = WebProxy.rewriteLocation(location, port: 5173, prefix: "/preview/web/5173", origin: origin)
        let comps = URLComponents(string: out)!
        XCTAssertEqual(comps.host, "eminent-mouse-3337.clerk.accounts.dev")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "redirect_url" }?.value,
                       "http://127.0.0.1:40123/preview/web/5173/items?q=a&p=2")
        XCTAssertEqual(comps.queryItems?.first { $0.name == "format" }?.value, "nonce")
        XCTAssertEqual(comps.queryItems?.count, 3)
    }

    /// プレビューのセッション経由なら、戻り先もセッションの入口になる。別のポートへの戻り先は触らない。
    func testSessionPrefixAndOtherPortRedirect() {
        let prefix = "/preview/w/abc"
        XCTAssertEqual(WebProxy.rewriteLocation("/login", port: 5173, prefix: prefix), "/preview/w/abc/login")
        XCTAssertEqual(WebProxy.rewriteLocation("/preview/w/abc/x", port: 5173, prefix: prefix), "/preview/w/abc/x")
        let back = "https://auth.example.com/?redirect_url=http%3A%2F%2F127.0.0.1%3A5173%2Fdone"
        let out = URLComponents(string: WebProxy.rewriteLocation(back, port: 5173, prefix: prefix, origin: origin))!
        XCTAssertEqual(out.queryItems?.first?.value, "http://127.0.0.1:40123/preview/w/abc/done")
        let other = "https://auth.example.com/?redirect_url=http%3A%2F%2F127.0.0.1%3A3000%2F"
        XCTAssertEqual(WebProxy.rewriteLocation(other, port: 5173, prefix: prefix, origin: origin), other)
    }

    func testExternalWithoutLocalParamOrOriginIsUntouched() {
        let plain = "https://accounts.example.com/login?redirect_url=https%3A%2F%2Fapp.example.com%2F"
        XCTAssertEqual(WebProxy.rewriteLocation(plain, port: 5173, prefix: "/preview/web/5173", origin: origin), plain)
        let local = "https://accounts.example.com/login?redirect_url=http%3A%2F%2Flocalhost%3A5173%2F"
        XCTAssertEqual(WebProxy.rewriteLocation(local, port: 5173, prefix: "/preview/web/5173"), local)
    }
}
