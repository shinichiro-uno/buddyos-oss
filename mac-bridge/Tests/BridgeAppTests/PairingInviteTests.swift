import XCTest
@testable import BridgeApp

/// 1 回きりの招待（spec/PROTOCOL-v3.md §6・§10.3）。
final class PairingInviteTests: XCTestCase {
    private var now: Int64 = 1_789_000_000_000

    private func make() -> PairingInvites { PairingInvites(now: { [unowned self] in self.now }) }

    func testExpiresAfterTenMinutes() throws {
        let invites = make()
        let inv = try invites.create()
        XCTAssertEqual(inv.expiresAt, now + 10 * 60 * 1000)
        XCTAssertEqual(inv.inviteId, TunnelV3.inviteId(secret: inv.secret))
        XCTAssertEqual(invites.psk(inviteId: inv.inviteId, deviceKeyId: "K1"), TunnelV3.invitePsk(secret: inv.secret))
        now += 10 * 60 * 1000
        XCTAssertNil(invites.psk(inviteId: inv.inviteId, deviceKeyId: "K1"))
        XCTAssertFalse(invites.markUsed(inviteId: inv.inviteId, deviceKeyId: "K1", display: "x"))
    }

    /// spec/PROTOCOL-v3.md §18.2 の 9: 使われた招待は、別の鍵の端末には使えない。同じ鍵の端末はやり直せる。
    func testUsedInviteOnlyForSameDevice() throws {
        let invites = make()
        let inv = try invites.create()
        XCTAssertTrue(invites.markUsed(inviteId: inv.inviteId, deviceKeyId: "K1", display: "iPhone · K1"))
        XCTAssertNil(invites.psk(inviteId: inv.inviteId, deviceKeyId: "K2"))
        XCTAssertFalse(invites.markUsed(inviteId: inv.inviteId, deviceKeyId: "K2", display: "x"))
        XCTAssertNotNil(invites.psk(inviteId: inv.inviteId, deviceKeyId: "K1"))
        XCTAssertTrue(invites.markUsed(inviteId: inv.inviteId, deviceKeyId: "K1", display: "iPhone · K1"))
        XCTAssertEqual(invites.invite(inv.inviteId)?.usedBy?.display, "iPhone · K1")
        XCTAssertEqual(invites.invite(inv.inviteId)?.usedBy?.at, now)
    }

    /// 同時に 3 つまで。4 つ目で一番古いものを捨てる。
    func testAtMostThree() throws {
        let invites = make()
        let first = try invites.create()
        now += 1
        _ = try invites.create(); now += 1
        _ = try invites.create(); now += 1
        _ = try invites.create()
        XCTAssertEqual(invites.active().count, 3)
        XCTAssertNil(invites.psk(inviteId: first.inviteId, deviceKeyId: "K1"))
    }

    /// 失敗の回数では消さない（psk を引くだけでは何も変わらない）。
    func testFailuresDoNotConsume() throws {
        let invites = make()
        let inv = try invites.create()
        for _ in 0..<10 { _ = invites.psk(inviteId: inv.inviteId, deviceKeyId: "attacker-\(UUID())") }
        XCTAssertNil(invites.invite(inv.inviteId)?.usedBy)
        XCTAssertNotNil(invites.psk(inviteId: inv.inviteId, deviceKeyId: "K1"))
    }

    func testCancelAndClear() throws {
        let invites = make()
        let a = try invites.create()
        XCTAssertTrue(invites.cancel(inviteId: a.inviteId))
        XCTAssertFalse(invites.cancel(inviteId: a.inviteId))
        _ = try invites.create()
        invites.clear()
        XCTAssertTrue(invites.active().isEmpty)
    }

    func testURLShape() throws {
        let invites = make()
        let inv = try invites.create()
        let url = PairingInvites.pairURL(bridgeId: "bridge-test-1", name: "Test Mac + 2", platform: "mac",
                                         relayURL: "wss://relay.example.com/ws", relayId: "4OHi4-Tl5ufo6err7O3u7_Dx8vP09fb3-Pn6-_z9_v8",
                                         bridgePub: "hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo",
                                         secret: inv.secret, expiresAtMs: inv.expiresAt)
        XCTAssertTrue(url.hasPrefix("buddyos://pair?v=3&bridgeId=bridge-test-1&name=Test%20Mac%20%2B%202&platform=mac&"))
        XCTAssertTrue(url.hasSuffix("&exp=\(inv.expiresAt / 1000)"))
        XCTAssertFalse(url.contains("apiKey"))
        XCTAssertTrue(url.contains("&secret=\(TunnelV3.b64u(inv.secret))&"))
    }
}
