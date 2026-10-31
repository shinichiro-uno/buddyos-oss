import Foundation
import Vapor
import XCTest
@testable import BridgeApp

/// 偽の中継（FakeTunnelTransport）で connect / pair / approve を通す
/// （spec/PROTOCOL-v3.md §10）。
final class TunnelFlowTests: XCTestCase {
    private var dir: URL!
    private var devices: DeviceStore!
    private var invites: PairingInvites!
    private var approvals: ApprovalQueue!
    private var peers: TunnelPeers!
    private var slots: PairingSlots!
    private var bridgePriv = Data()
    private var bridgePub = Data()
    private var devicePriv = Data()
    private var localPort = 1
    private var timeScale: Double = 1
    private let notified = Notified()

    /// remote の承認待ちで送った pair_request（pendingId・表示名）。
    private final class Notified: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(String, String)] = []
        func add(_ id: String, _ display: String) { lock.withLock { _calls.append((id, display)) } }
        var calls: [(String, String)] { lock.withLock { _calls } }
    }
    private let bridge = TunnelV3.PairedBridge(bridgeId: "bridge-test-1", name: "Test Mac", platform: "mac",
                                               relayId: "4OHi4-Tl5ufo6err7O3u7_Dx8vP09fb3-Pn6-_z9_v8",
                                               relayURL: "wss://relay.example.com/ws")

    override func setUpWithError() throws {
        let keys = try V3Vectors.keys()
        bridgePriv = Data(v3hex: keys["bridgePriv"]!)
        bridgePub = Data(v3hex: keys["bridgePub"]!)
        devicePriv = Data(v3hex: keys["devicePriv"]!)
        dir = try makeTempDir("tunnel-flow")
        let d = dir!
        devices = DeviceStore(directory: { d })
        devices.load()
        invites = PairingInvites()
        approvals = ApprovalQueue()
        peers = TunnelPeers()
        slots = PairingSlots()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - 道具

    private func environment() -> TunnelSession.Environment {
        let priv = bridgePriv
        let b = bridge
        var env = TunnelSession.Environment(devices: devices, invites: invites, approvals: approvals, peers: peers,
                                            staticKey: { priv }, bridge: { b }, localPort: localPort)
        env.timeScale = timeScale
        let notified = self.notified
        env.notifyApprovers = { notified.add($0, $1) }
        return env
    }

    /// Bridge の側を 1 本動かす。
    @discardableResult
    private func startSession(_ transport: FakeTunnelTransport, id: String = UUID().uuidString) -> Task<Void, Never> {
        let slots = self.slots!
        let session = TunnelSession(connectionId: id, transport: transport, environment: environment(),
                                    hooks: .init(acquirePairing: { slots.acquire(id, deviceKeyId: $0) }))
        return Task {
            try? await session.run()
            slots.release(id)
            transport.close(normal: false)
        }
    }

    /// 端末の側。
    private struct Device {
        var ini: TunnelV3.Initiator
        var keys: (c2s: Data, s2c: Data, hash: Data)?
        var sender: E2EFrameSender?
        var receiver: E2EFrameReceiver?
        let pub: Data
        var deviceKeyId: String { TunnelV3.deviceKeyId(devicePub: pub) }
    }

    private func device(priv: Data? = nil, psk: Data = TunnelV3.zeroPsk) throws -> Device {
        let p = priv ?? devicePriv
        return Device(ini: try TunnelV3.Initiator(staticPriv: p, bridgeStaticPub: bridgePub, psk: psk),
                      pub: try TunnelV3.publicKey(p))
    }

    private func payload1(_ mode: String, deviceId: String = "device-test-1", invite: String? = nil) -> Data {
        var o: [String: Any] = ["mode": mode, "deviceId": deviceId, "platform": "ios", "name": "Test iPhone", "app": "131"]
        if let invite { o["invite"] = invite }
        return try! JSONSerialization.data(withJSONObject: o)
    }

    private func sendMsg1(_ d: inout Device, _ t: FakeTunnelTransport, payload: Data) throws {
        let m = try d.ini.writeMessage1(payload: payload)
        t.push(.text("{\"type\":\"buddyos_tunnel_init\",\"v\":3,\"e\":\"\(TunnelV3.b64u(m.e))\",\"s\":\"\(TunnelV3.b64u(m.s))\",\"p\":\"\(TunnelV3.b64u(m.p))\"}"))
    }

    /// msg2 を読む。開けなければ投げる。
    private func readHello(_ d: inout Device, _ t: FakeTunnelTransport, index: Int = 0) async throws -> [String: Any] {
        guard case .text(let text) = try await t.sent(index) else { throw FakeTunnelTransport.Closed() }
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        guard obj["type"] as? String == "buddyos_tunnel_hello" else { return obj }
        let e = try XCTUnwrap(TunnelV3.b64uDecodeStrict(obj["e"] as! String))
        let p = try XCTUnwrap(TunnelV3.b64uDecodeStrict(obj["p"] as! String))
        let r = try d.ini.readMessage2(e: e, p: p)
        d.keys = (r.c2s, r.s2c, r.hash)
        d.sender = E2EFrameSender(key: r.c2s, version: 0x03)
        d.receiver = E2EFrameReceiver(key: r.s2c, version: 0x03)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: r.payload) as? [String: Any])
    }

    private func sendControl(_ d: Device, _ t: FakeTunnelTransport, _ json: String) throws {
        t.push(.binary(try d.sender!.seal(Data(json.utf8))))
    }

    private func readControl(_ d: Device, _ t: FakeTunnelTransport, index: Int) async throws -> [String: Any] {
        guard case .binary(let frame) = try await t.sent(index) else { throw FakeTunnelTransport.Closed() }
        let pt = try d.receiver!.open(frame)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: pt) as? [String: Any])
    }

    private func confirmedRow(_ key: String, cid: String = "device-test-1", cred: String = "bdc_known") {
        let row = DeviceStore.Device(pub: "p", clientDeviceId: cid, name: "iPhone", label: nil, platform: "ios",
                                     credHash: TunnelV3.credentialHash(cred), via: "qr", createdAt: DeviceStore.nowMs(),
                                     lastSeenAt: nil, push: nil)
        XCTAssertTrue(devices.insertPending(deviceKeyId: key, device: row, epoch: devices.epoch))
        XCTAssertTrue(devices.confirmPending(deviceKeyId: key, credHash: row.credHash, epoch: devices.epoch))
    }

    // MARK: - v2・形の違い

    func testV2InitGetsVersionError() async throws {
        let t = FakeTunnelTransport()
        startSession(t)
        t.push(.text(#"{"type":"buddyos_tunnel_init","deviceId":"device-test-1","devicePub":"x","v":2,"clientNonce":"y"}"#))
        guard case .text(let text) = try await t.sent(0) else { return XCTFail() }
        XCTAssertEqual(text, #"{"type":"buddyos_tunnel_error","v":3,"code":"version"}"#)
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
    }

    // MARK: - connect

    func testConnectUnknownDevice() async throws {
        let t = FakeTunnelTransport()
        startSession(t)
        var d = try device()
        try sendMsg1(&d, t, payload: payload1("connect"))
        let p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["ok"] as? Bool, false)
        XCTAssertEqual(p2["error"] as? String, "unknown_device")
    }

    /// /device/unpair の直後（1 秒以内）の connect は revoked。
    func testConnectWhileUnpairingIsRevoked() async throws {
        let d0 = try device()
        confirmedRow(d0.deviceKeyId)
        XCTAssertTrue(devices.beginUnpair(deviceKeyId: d0.deviceKeyId))
        let t = FakeTunnelTransport()
        startSession(t)
        var d = d0
        try sendMsg1(&d, t, payload: payload1("connect"))
        let p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["error"] as? String, "revoked")
    }

    func testConnectWrongClientDeviceIdIsUnknown() async throws {
        let d0 = try device()
        confirmedRow(d0.deviceKeyId, cid: "device-other-1")
        let t = FakeTunnelTransport()
        startSession(t)
        var d = d0
        try sendMsg1(&d, t, payload: payload1("connect"))
        let p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["error"] as? String, "unknown_device")
    }

    /// open を処理している間にその端末を外すと、流さずに閉じる。
    func testConnectClosesWhenDeviceRemovedBeforeOpen() async throws {
        let d0 = try device()
        confirmedRow(d0.deviceKeyId)
        let t = FakeTunnelTransport()
        startSession(t)
        var d = d0
        try sendMsg1(&d, t, payload: payload1("connect"))
        let p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["ok"] as? Bool, true)
        XCTAssertEqual(p2["deviceKeyId"] as? String, d.deviceKeyId)
        XCTAssertTrue(devices.revoke(deviceKeyId: d.deviceKeyId))
        try sendControl(d, t, #"{"type":"open"}"#)
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
        XCTAssertEqual(peers.total, 0)
    }

    /// connect を最後まで: open → 127.0.0.1 の Bridge へ TCP。TunnelPeers に入り、要求はトンネル経由に見える。
    func testConnectStreamsToLocalServerAndRegistersPeer() async throws {
        let app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        let peers = self.peers!
        app.get("whoami") { req -> String in
            switch BridgeAuth.origin(req, peers: peers) {
            case .tunnel(let p): return "tunnel:\(p.deviceKeyId)"
            case .local: return "local"
            case nil: return "none"
            }
        }
        try await app.server.start()
        defer { Task { await app.server.shutdown(); try? await app.asyncShutdown() } }
        localPort = app.http.server.shared.localAddress?.port ?? 0

        let d0 = try device()
        confirmedRow(d0.deviceKeyId)
        let t = FakeTunnelTransport()
        let task = startSession(t)
        var d = d0
        try sendMsg1(&d, t, payload: payload1("connect"))
        let p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["ok"] as? Bool, true)
        try sendControl(d, t, #"{"type":"open"}"#)
        // TEXT の再送が混ざっても、最初のバイナリまでは読み捨てる（ここではもう後なので送らない）。
        try sendControl(d, t, "GET /whoami HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        var response = Data()
        var idx = 1
        while !String(decoding: response, as: UTF8.self).contains("tunnel:") && idx < 20 {
            guard case .binary(let frame) = try await t.sent(idx) else { break }
            response += try d.receiver!.open(frame)
            idx += 1
        }
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("tunnel:\(d.deviceKeyId)"))
        XCTAssertNotNil(devices.device(d.deviceKeyId)?.lastSeenAt)
        t.close(normal: false)
        await task.value
        XCTAssertEqual(peers.total, 0, "閉じたら TunnelPeers から外す")
    }

    /// つないだ先の番号が待ち受けの番号と違う／ローカルの住所が ::1 なら流さない。
    func testPeerEndpointConditions() {
        let ok = TunnelSession.acceptablePeerPort(local: .hostPort(host: "127.0.0.1", port: 50000),
                                                  remote: .hostPort(host: "127.0.0.1", port: 8765), listenPort: 8765)
        XCTAssertEqual(ok, 50000)
        XCTAssertNil(TunnelSession.acceptablePeerPort(local: .hostPort(host: "127.0.0.1", port: 50000),
                                                      remote: .hostPort(host: "127.0.0.1", port: 8766), listenPort: 8765))
        XCTAssertNil(TunnelSession.acceptablePeerPort(local: .hostPort(host: "::1", port: 50000),
                                                      remote: .hostPort(host: "::1", port: 8765), listenPort: 8765))
        XCTAssertNil(TunnelSession.acceptablePeerPort(local: nil, remote: nil, listenPort: 8765))
    }

    // MARK: - pair

    private func runPair(invite: PairingInvites.Created, priv: Data? = nil, ack: Bool = true) async throws -> (FakeTunnelTransport, [String: Any]?) {
        let t = FakeTunnelTransport()
        startSession(t)
        var d = try device(priv: priv, psk: TunnelV3.invitePsk(secret: invite.secret))
        try sendMsg1(&d, t, payload: payload1("pair", invite: invite.inviteId))
        let p2 = try await readHello(&d, t)
        guard p2["ok"] as? Bool == true else { return (t, p2) }
        try sendControl(d, t, #"{"type":"pair_confirm"}"#)
        let paired = try await readControl(d, t, index: 1)
        if ack { try sendControl(d, t, #"{"type":"paired_ack"}"#) }
        return (t, paired)
    }

    func testPairFlowStoresDevice() async throws {
        let inv = try invites.create()
        let (t, paired) = try await runPair(invite: inv)
        XCTAssertEqual(paired?["type"] as? String, "paired")
        let cred = try XCTUnwrap(paired?["credential"] as? String)
        XCTAssertTrue(cred.hasPrefix("bdc_"))
        let b = try XCTUnwrap(paired?["bridge"] as? [String: String])
        XCTAssertEqual(b["relayURL"], "wss://relay.example.com/ws")
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
        XCTAssertEqual(t.closedNormally, true)
        let key = TunnelV3.deviceKeyId(devicePub: try TunnelV3.publicKey(devicePriv))
        XCTAssertNotNil(devices.verify(deviceKeyId: key, credential: cred))
        XCTAssertEqual(devices.device(key)?.via, "qr")
        XCTAssertEqual(devices.device(key)?.name, "Test iPhone")
        XCTAssertEqual(invites.invite(inv.inviteId)?.usedBy?.deviceKeyId, key)
    }

    /// spec/PROTOCOL-v3.md §18.2 の 8: msg2 の後に開けないバイナリを 10 回入れても、招待は有効なまま。正しい pair_confirm で通る。
    func testGarbageAfterHelloDoesNotBurnInvite() async throws {
        let inv = try invites.create()
        for _ in 0..<10 {
            let t = FakeTunnelTransport()
            startSession(t)
            var d = try device(psk: TunnelV3.invitePsk(secret: inv.secret))
            try sendMsg1(&d, t, payload: payload1("pair", invite: inv.inviteId))
            _ = try await readHello(&d, t)
            t.push(.binary(Data(repeating: 0x03, count: 40)))
            let closed = await t.waitClosed()
            XCTAssertTrue(closed)
        }
        XCTAssertNil(invites.invite(inv.inviteId)?.usedBy)
        let (_, paired) = try await runPair(invite: inv)
        XCTAssertEqual(paired?["type"] as? String, "paired")
    }

    /// spec/PROTOCOL-v3.md §18.2 の 9: 使われた招待を、別の鍵の端末が使う → invite_invalid。同じ鍵の端末はやり直せる（bdc_ が置き換わる）。
    func testUsedInviteRejectsOtherKeyButAllowsSameKey() async throws {
        let inv = try invites.create()
        let (t1, first) = try await runPair(invite: inv)
        _ = await t1.waitClosed()
        let cred1 = try XCTUnwrap(first?["credential"] as? String)

        let t = FakeTunnelTransport()
        startSession(t)
        var other = try device(priv: TunnelV3.newPrivateKey(), psk: TunnelV3.invitePsk(secret: inv.secret))
        try sendMsg1(&other, t, payload: payload1("pair", deviceId: "device-other-1", invite: inv.inviteId))
        guard case .text(let text) = try await t.sent(0) else { return XCTFail() }
        XCTAssertEqual(text, #"{"type":"buddyos_tunnel_error","v":3,"code":"invite_invalid"}"#)

        let (t2, again) = try await runPair(invite: inv)
        _ = await t2.waitClosed()
        let cred2 = try XCTUnwrap(again?["credential"] as? String)
        XCTAssertNotEqual(cred1, cred2)
        let key = TunnelV3.deviceKeyId(devicePub: try TunnelV3.publicKey(devicePriv))
        XCTAssertNil(devices.verify(deviceKeyId: key, credential: cred1))
        XCTAssertNotNil(devices.verify(deviceKeyId: key, credential: cred2))
    }

    /// 形の違う payload1（spec/PROTOCOL-v3.md §8.10）: pair で招待が使えるなら、その招待の psk で bad_request を返す
    /// （端末が読める。Windows の Bridge と同じ）。招待は使われたことにならない。
    func testMalformedPairWithUsableInviteGetsReadableBadRequest() async throws {
        let inv = try invites.create()
        let t = FakeTunnelTransport()
        startSession(t)
        var d = try device(psk: TunnelV3.invitePsk(secret: inv.secret))
        let bad: [String: Any] = ["mode": "pair", "deviceId": "device-test-1", "platform": "toaster",
                                  "name": "Test iPhone", "invite": inv.inviteId]
        try sendMsg1(&d, t, payload: try JSONSerialization.data(withJSONObject: bad))
        let p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["ok"] as? Bool, false)
        XCTAssertEqual(p2["error"] as? String, "bad_request")
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
        XCTAssertNil(invites.invite(inv.inviteId)?.usedBy)
    }

    /// 形の違う pair で招待が無い・使えない: msg2 は送れないので平文の invite_invalid。
    func testMalformedPairWithoutUsableInviteGetsInviteInvalid() async throws {
        let t = FakeTunnelTransport()
        startSession(t)
        var d = try device()
        let bad: [String: Any] = ["mode": "pair", "deviceId": "device-test-1", "platform": "ios",
                                  "invite": TunnelV3.b64u(Data(repeating: 7, count: 16))]
        try sendMsg1(&d, t, payload: try JSONSerialization.data(withJSONObject: bad))
        guard case .text(let text) = try await t.sent(0) else { return XCTFail() }
        XCTAssertEqual(text, #"{"type":"buddyos_tunnel_error","v":3,"code":"invite_invalid"}"#)
    }

    /// 形の違う connect は、今までどおりゼロの psk で bad_request。
    func testMalformedConnectGetsBadRequest() async throws {
        let t = FakeTunnelTransport()
        startSession(t)
        var d = try device()
        let bad: [String: Any] = ["mode": "connect", "deviceId": "x", "platform": "ios"]
        try sendMsg1(&d, t, payload: try JSONSerialization.data(withJSONObject: bad))
        let p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["ok"] as? Bool, false)
        XCTAssertEqual(p2["error"] as? String, "bad_request")
    }

    /// paired の後に paired_ack が来ないと、時間がたつと行が消える。
    func testPairWithoutAckRemovesRow() async throws {
        timeScale = 0.05
        let inv = try invites.create()
        let (t, paired) = try await runPair(invite: inv, ack: false)
        XCTAssertEqual(paired?["type"] as? String, "paired")
        let key = TunnelV3.deviceKeyId(devicePub: try TunnelV3.publicKey(devicePriv))
        XCTAssertEqual(devices.state(key), .pendingAck)
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(devices.device(key))
    }

    /// 同じ deviceKeyId で pair を 2 本同時に始めると、2 本目は busy。
    func testConcurrentPairSameDeviceIsBusy() async throws {
        let inv = try invites.create()
        let psk = TunnelV3.invitePsk(secret: inv.secret)
        let t1 = FakeTunnelTransport()
        startSession(t1, id: "c1")
        var d1 = try device(psk: psk)
        try sendMsg1(&d1, t1, payload: payload1("pair", invite: inv.inviteId))
        let first = try await readHello(&d1, t1)
        XCTAssertEqual(first["ok"] as? Bool, true)

        let t2 = FakeTunnelTransport()
        startSession(t2, id: "c2")
        var d2 = try device(psk: psk)
        try sendMsg1(&d2, t2, payload: payload1("pair", invite: inv.inviteId))
        let second = try await readHello(&d2, t2)
        XCTAssertEqual(second["error"] as? String, "busy")
        t1.close(normal: false)
    }

    // MARK: - approve

    func testApproveRefusals() async throws {
        // 窓が閉じている → approval_unavailable。
        var t = FakeTunnelTransport()
        startSession(t)
        var d = try device()
        try sendMsg1(&d, t, payload: payload1("approve"))
        var p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["error"] as? String, "approval_unavailable")

        // 外した印がある鍵 → revoked。
        approvals.openWindow()
        confirmedRow(d.deviceKeyId)
        XCTAssertTrue(devices.revoke(deviceKeyId: d.deviceKeyId))
        t = FakeTunnelTransport()
        startSession(t)
        d = try device()
        try sendMsg1(&d, t, payload: payload1("approve"))
        p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["error"] as? String, "revoked")
    }

    private func startApprove(openWindow: Bool = true) async throws -> (FakeTunnelTransport, Device, String) {
        if openWindow { approvals.openWindow() }
        let t = FakeTunnelTransport()
        startSession(t)
        var d = try device()
        try sendMsg1(&d, t, payload: payload1("approve"))
        let p2 = try await readHello(&d, t)
        XCTAssertEqual(p2["ok"] as? Bool, true)
        let commit = try XCTUnwrap(TunnelV3.b64uDecodeStrict(p2["commit"] as! String, length: 32))
        let nD = try TunnelV3.randomBytes(32)
        try sendControl(d, t, "{\"type\":\"approve_nonce\",\"n\":\"\(TunnelV3.b64u(nD))\"}")
        let reveal = try await readControl(d, t, index: 1)
        XCTAssertEqual(reveal["type"] as? String, "approve_reveal")
        let nR = try XCTUnwrap(TunnelV3.b64uDecodeStrict(reveal["n"] as! String, length: 32))
        XCTAssertEqual(TunnelV3.sasCommit(nR: nR), commit, "端末は commit を確かめる")
        let code = TunnelV3.sasCode(handshakeHash: d.keys!.hash, nI: nD, nR: nR)
        return (t, d, code)
    }

    func testApproveFlowWithCodeEnteredOnPC() async throws {
        let (t, d, code) = try await startApprove()
        XCTAssertEqual(approvals.views().count, 1)
        let r = await approvals.submit(code: code)
        guard case .ok(let key, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(key, d.deviceKeyId)
        let paired = try await readControl(d, t, index: 2)
        XCTAssertEqual(paired["type"] as? String, "paired")
        try sendControl(d, t, #"{"type":"paired_ack"}"#)
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
        XCTAssertEqual(devices.device(d.deviceKeyId)?.via, "approval")
        XCTAssertNil(devices.state(d.deviceKeyId))
    }

    /// `paired` の送り終わりの知らせより先に端末の paired_ack が届いても、確定する
    /// （以前は「承認待ちの間の知らないフレーム」として閉じ、行が pendingAck のまま残った）。
    func testApproveAckArrivingBeforeSendCompletionConfirms() async throws {
        let (t, d, code) = try await startApprove()
        t.sendCompletionDelay = 300_000_000
        let approvals = self.approvals!
        let submit = Task { await approvals.submit(code: code) }
        let paired = try await readControl(d, t, index: 2)
        XCTAssertEqual(paired["type"] as? String, "paired")
        try sendControl(d, t, #"{"type":"paired_ack"}"#)
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
        XCTAssertEqual(t.closedNormally, true)
        guard case .ok = await submit.value else { return XCTFail("submit") }
        XCTAssertEqual(devices.device(d.deviceKeyId)?.via, "approval")
        XCTAssertNil(devices.state(d.deviceKeyId), "確定して pendingAck が残らない")
    }

    /// approve の途中で「すべての端末を切断」→ pair_rejected（reset）、行は入らない。
    func testApproveResetMidway() async throws {
        let (t, d, _) = try await startApprove()
        approvals.resetAll()
        let rejected = try await readControl(d, t, index: 2)
        XCTAssertEqual(rejected["type"] as? String, "pair_rejected")
        XCTAssertEqual(rejected["reason"] as? String, "reset")
        XCTAssertNil(devices.device(d.deviceKeyId))
    }

    /// spec/PROTOCOL-v3.md §18.2 の 10: 同じ msg1 を送り直しても回数は減らない（approve_nonce を受けたときだけ数える）。
    func testApproveMsg1AloneDoesNotCount() async throws {
        approvals.openWindow()
        for _ in 0..<10 {
            let t = FakeTunnelTransport()
            startSession(t)
            var d = try device()
            try sendMsg1(&d, t, payload: payload1("approve"))
            _ = try await readHello(&d, t)
            t.close(normal: false)
        }
        XCTAssertTrue(approvals.countAttempt(deviceKeyId: try device().deviceKeyId))
    }

    func testApproveCancelledByDevice() async throws {
        let (t, d, code) = try await startApprove()
        try sendControl(d, t, #"{"type":"pair_cancel"}"#)
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(approvals.views().isEmpty, "端末が取り消したら承認待ちも消える")
        let r = await approvals.submit(code: code)
        XCTAssertEqual(r, .noPending)
    }

    // MARK: - スマホで許可する（spec/PROTOCOL-v3.md §10.4.1）

    /// 窓が閉じていても、許可できる端末に push の宛先があれば remote として受け付け、push を 1 回送る。
    /// スマホで入力して確定した行には approvedBy が残る。
    func testRemoteApproveWithPhone() async throws {
        confirmedRow("PHONEKEY", cid: "phone-1", cred: "bdc_phone")
        XCTAssertEqual(devices.setPush(deviceKeyId: "PHONEKEY", token: String(repeating: "c", count: 64),
                                       env: "development", locale: "ja"), .stored)
        let (t, d, code) = try await startApprove(openWindow: false)
        let pending = try XCTUnwrap(approvals.views().first)
        XCTAssertTrue(pending.remote)
        XCTAssertEqual(notified.calls.map(\.0), [pending.pendingId])
        XCTAssertEqual(notified.calls.first?.1, pending.display)
        let r = await approvals.submit(code: code, approvedBy: "PHONEKEY")
        guard case .ok(let key, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(key, d.deviceKeyId)
        let paired = try await readControl(d, t, index: 2)
        XCTAssertEqual(paired["type"] as? String, "paired")
        try sendControl(d, t, #"{"type":"paired_ack"}"#)
        let closed = await t.waitClosed()
        XCTAssertTrue(closed)
        XCTAssertNil(devices.state(d.deviceKeyId))
        XCTAssertEqual(devices.device(d.deviceKeyId)?.approvedBy, "PHONEKEY")
    }

    /// 窓が開いているときの申し込みは remote にならず、push も送らない。PC で入力すれば approvedBy は付かない。
    func testWindowApproveDoesNotNotify() async throws {
        confirmedRow("PHONEKEY", cid: "phone-1", cred: "bdc_phone")
        XCTAssertEqual(devices.setPush(deviceKeyId: "PHONEKEY", token: String(repeating: "c", count: 64),
                                       env: "development", locale: "ja"), .stored)
        let (t, d, code) = try await startApprove()
        XCTAssertEqual(approvals.views().first?.remote, false)
        XCTAssertTrue(notified.calls.isEmpty)
        _ = await approvals.submit(code: code)
        _ = try await readControl(d, t, index: 2)
        try sendControl(d, t, #"{"type":"paired_ack"}"#)
        _ = await t.waitClosed()
        XCTAssertNil(devices.device(d.deviceKeyId)?.approvedBy)
    }

    /// 窓が閉じていて、許可できる端末に push の宛先が無い・設定で切れている → approval_unavailable。
    func testRemoteApproveUnavailable() async throws {
        let mac = DeviceStore.Device(pub: "p", clientDeviceId: "mac-1", name: "Mac", label: nil, platform: "mac",
                                     credHash: TunnelV3.credentialHash("bdc_mac"), via: "approval",
                                     createdAt: DeviceStore.nowMs(), lastSeenAt: nil, push: nil)
        XCTAssertTrue(devices.insertPending(deviceKeyId: "MACKEY", device: mac, epoch: devices.epoch))
        XCTAssertTrue(devices.confirmPending(deviceKeyId: "MACKEY", credHash: mac.credHash, epoch: devices.epoch))
        XCTAssertEqual(devices.setPush(deviceKeyId: "MACKEY", token: String(repeating: "d", count: 64),
                                       env: "development", locale: "ja"), .stored)
        for disable in [false, true] {
            if disable {
                confirmedRow("PHONEKEY", cid: "phone-1", cred: "bdc_phone")
                _ = devices.setPush(deviceKeyId: "PHONEKEY", token: String(repeating: "c", count: 64), env: "development", locale: "ja")
                devices.setRemoteApprovalsEnabled(false)
            }
            let t = FakeTunnelTransport()
            startSession(t)
            var d = try device()
            try sendMsg1(&d, t, payload: payload1("approve"))
            let p2 = try await readHello(&d, t)
            XCTAssertEqual(p2["error"] as? String, "approval_unavailable", "disable=\(disable)")
        }
    }
}
