import Darwin
import Foundation
import Vapor
import XCTest
@testable import BridgeApp

/// スマホで許可して PC 同士をつなぐ（spec/PROTOCOL-v3.md §10.4.1・§13.5）。
/// 端末用の `/device/approvals*`（許可できる端末だけ・設定で切れる）と、DevicesView に足した項目。
final class PhoneApprovalTests: XCTestCase {
    private var app: Application!
    private var port = 0
    private var root: URL!
    private let localKey = "local-key-0123456789"
    private let adminKey = "bda_" + String(repeating: "B", count: 43)
    private let phoneKey = "PHONEAPPROVERKEY00000A"
    private let phoneCred = "bdc_phone_approver"
    private let macKey = "MACNOTAPPROVERKEY0000A"
    private let macCred = "bdc_mac_not_approver"
    private let approvals = Approved()

    /// 番号が合ったときに渡された approvedBy。
    private final class Approved: @unchecked Sendable {
        private let lock = NSLock()
        private var _by: [String?] = []
        func add(_ by: String?) { lock.withLock { _by.append(by) } }
        var by: [String?] { lock.withLock { _by } }
    }

    override func setUp() async throws {
        root = try makeTempDir("phone-approval")
        BuddyPaths.setOverride(root)
        DeviceStore.shared.load()
        LocalKey.shared.replace(localKey)
        AdminKey.shared.resetForTesting(adminKey)
        addConfirmed(phoneKey, platform: "ios", cred: phoneCred)
        addConfirmed(macKey, platform: "mac", cred: macCred)

        app = try await Application.make(.testing)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.middleware.use(BridgeRequestGuard.Middleware())
        app.middleware.use(BridgeAuth.Middleware())
        LocalDeviceRoutes.register(app: app)
        try await app.server.start()
        port = app.http.server.shared.localAddress?.port ?? 0
        XCTAssertGreaterThan(port, 0)
    }

    override func tearDown() async throws {
        ApprovalQueue.shared.resetAll()
        ApprovalQueue.shared.closeWindow()
        await app.server.shutdown()
        try await app.asyncShutdown()
        AdminKey.shared.resetForTesting(nil)
        LocalKey.shared.invalidate()
        BuddyPaths.setOverride(nil)
        try? FileManager.default.removeItem(at: root)
    }

    private func addConfirmed(_ key: String, platform: String, cred: String, store: DeviceStore = .shared,
                              name: String = "Device", approvedBy: String? = nil) {
        var row = DeviceStore.Device(pub: "p", clientDeviceId: "cid-\(key)", name: name, label: nil, platform: platform,
                                     credHash: TunnelV3.credentialHash(cred), via: "qr",
                                     createdAt: DeviceStore.nowMs(), lastSeenAt: nil, push: nil)
        row.approvedBy = approvedBy
        XCTAssertTrue(store.insertPending(deviceKeyId: key, device: row, epoch: store.epoch))
        XCTAssertTrue(store.confirmPending(deviceKeyId: key, credHash: row.credHash, epoch: store.epoch))
    }

    /// remote の承認待ちを 1 件入れる。番号が合ったら、渡された approvedBy を覚える。
    @discardableResult
    private func addRemote(_ key: String, code: String) -> ApprovalQueue.Pending? {
        ApprovalQueue.shared.add(
            deviceKeyId: key, display: "MacBook Air · \(key.prefix(4))", name: "MacBook Air", platform: "mac",
            sameNameExists: false, remote: true, code: code,
            approve: { [approvals] by in
                approvals.add(by)
                return .ok(display: "MacBook Air · \(key.prefix(4))")
            },
            end: { _ in })
    }

    /// 生の HTTP/1.1 を 1 本送る。`device` があれば、この接続のローカル側の番号をその端末として TunnelPeers に入れる。
    private func request(_ path: String, method: String = "GET", headers: [(String, String)] = [],
                         body: String? = nil, device: String? = nil) async throws -> (status: Int, json: [String: Any]) {
        let port = self.port
        return try await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard rc == 0 else { throw POSIXError(.ECONNREFUSED) }
            var local = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            let localPort = UInt16(bigEndian: local.sin_port)
            let connId = UUID().uuidString
            if let device { TunnelPeers.shared.register(localPort: localPort, peer: .init(deviceKeyId: device, connectionId: connId)) }
            defer { if device != nil { TunnelPeers.shared.remove(localPort: localPort, connectionId: connId) } }
            var lines = ["\(method) \(path) HTTP/1.1", "Host: 127.0.0.1:\(port)", "Connection: close"]
            for (k, v) in headers { lines.append("\(k): \(v)") }
            let payload = body ?? ""
            if method == "POST" {
                lines.append("Content-Type: application/json")
                lines.append("Content-Length: \(payload.utf8.count)")
            }
            let req = lines.joined(separator: "\r\n") + "\r\n\r\n" + payload
            _ = req.withCString { send(fd, $0, strlen($0), 0) }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
            }
            let text = String(decoding: out, as: UTF8.self)
            let status = Int(text.split(separator: " ").dropFirst().first ?? "") ?? 0
            let bodyText = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
            let json = (try? JSONSerialization.jsonObject(with: Data(bodyText.utf8))) as? [String: Any] ?? [:]
            return (status, json)
        }.value
    }

    private func bearer(_ v: String) -> (String, String) { ("Authorization", "Bearer \(v)") }
    private var admin: [(String, String)] { [bearer(localKey), ("X-BuddyOS-Admin", adminKey)] }

    // MARK: - 端末用の API（spec/PROTOCOL-v3.md §13.5）

    func testApprovalsListOnlyForApprovers() async throws {
        let p = try XCTUnwrap(addRemote("REQKEY0001", code: "213854"))
        var r = try await request("/device/approvals", headers: [bearer(phoneCred)], device: phoneKey)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json["enabled"] as? Bool, true)
        let rows = try XCTUnwrap(r.json["pending"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["pendingId"] as? String, p.pendingId)
        XCTAssertEqual(rows.first?["remote"] as? Bool, true)
        XCTAssertEqual(Set(rows.first!.keys),
                       ["pendingId", "display", "platform", "requestedAt", "expiresAt", "sameNameExists", "remote"],
                       "番号は入れない")

        r = try await request("/device/approvals", headers: [bearer(macCred)], device: macKey)
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(r.json["error"] as? String, "not_approver", "デスクトップは許可できない")
        r = try await request("/device/approvals", headers: [bearer(localKey)])
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(r.json["error"] as? String, "device_only", "この PC の中からは使えない")
        r = try await request("/device/approvals", headers: [bearer("bdc_wrong")], device: phoneKey)
        XCTAssertEqual(r.status, 401)
    }

    func testApproveFromPhone() async throws {
        addRemote("REQKEY0001", code: "213854")
        var r = try await request("/device/approvals/approve", method: "POST", headers: [bearer(macCred)],
                                  body: #"{"code":"213854"}"#, device: macKey)
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(r.json["error"] as? String, "not_approver")

        r = try await request("/device/approvals/approve", method: "POST", headers: [bearer(phoneCred)],
                              body: #"{"code":"000000"}"#, device: phoneKey)
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(r.json["error"] as? String, "code_mismatch")
        XCTAssertEqual(r.json["remaining"] as? Int, 2)
        r = try await request("/device/approvals/approve", method: "POST", headers: [bearer(phoneCred)],
                              body: #"{"code":"12"}"#, device: phoneKey)
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(r.json["error"] as? String, "bad_code")

        r = try await request("/device/approvals/approve", method: "POST", headers: [bearer(phoneCred)],
                              body: #"{"code":"213-854"}"#, device: phoneKey)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json["ok"] as? Bool, true)
        XCTAssertEqual(r.json["deviceKeyId"] as? String, "REQKEY0001")
        XCTAssertEqual(r.json["display"] as? String, "MacBook Air · REQK")
        XCTAssertEqual(approvals.by, [phoneKey], "入力した端末の deviceKeyId が渡る")

        r = try await request("/device/approvals/approve", method: "POST", headers: [bearer(phoneCred)],
                              body: #"{"code":"213854"}"#, device: phoneKey)
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.json["error"] as? String, "no_pending")
    }

    func testRejectFromPhone() async throws {
        let p = try XCTUnwrap(addRemote("REQKEY0002", code: "111111"))
        var r = try await request("/device/approvals/\(p.pendingId)/reject", method: "POST", headers: [bearer(macCred)],
                                  body: "{}", device: macKey)
        XCTAssertEqual(r.status, 403)
        r = try await request("/device/approvals/\(p.pendingId)/reject", method: "POST", headers: [bearer(phoneCred)],
                              body: "{}", device: phoneKey)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json["ok"] as? Bool, true)
        XCTAssertTrue(ApprovalQueue.shared.isRejected("REQKEY0002"), "24 時間断る")
        r = try await request("/device/approvals/\(p.pendingId)/reject", method: "POST", headers: [bearer(phoneCred)],
                              body: "{}", device: phoneKey)
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.json["error"] as? String, "not_found")
    }

    /// 設定で切れていれば、一覧は enabled:false と空、approve・reject は 409 disabled。
    /// `/local/devices/settings` で切ると remote の申し込みは closed で取り下がる。
    func testDisabledBySetting() async throws {
        let p = try XCTUnwrap(addRemote("REQKEY0003", code: "222222"))
        var r = try await request("/local/devices/settings", method: "POST", headers: admin,
                                  body: #"{"remoteApprovalsEnabled":false}"#)
        XCTAssertEqual(r.status, 200)
        XCTAssertFalse(DeviceStore.shared.remoteApprovalsEnabled)
        XCTAssertFalse(ApprovalQueue.shared.contains(pendingId: p.pendingId), "remote の申し込みは取り下げる")

        r = try await request("/device/approvals", headers: [bearer(phoneCred)], device: phoneKey)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json["enabled"] as? Bool, false)
        XCTAssertEqual((r.json["pending"] as? [Any])?.count, 0)
        r = try await request("/device/approvals/approve", method: "POST", headers: [bearer(phoneCred)],
                              body: #"{"code":"222222"}"#, device: phoneKey)
        XCTAssertEqual(r.status, 409)
        XCTAssertEqual(r.json["error"] as? String, "disabled")
        r = try await request("/device/approvals/p_x/reject", method: "POST", headers: [bearer(phoneCred)],
                              body: "{}", device: phoneKey)
        XCTAssertEqual(r.status, 409)

        r = try await request("/local/devices", headers: admin)
        XCTAssertEqual(r.json["remoteApprovalsEnabled"] as? Bool, false)
        r = try await request("/local/devices/settings", method: "POST", headers: admin,
                              body: #"{"remoteApprovalsEnabled":true}"#)
        XCTAssertTrue(DeviceStore.shared.remoteApprovalsEnabled)
    }

    // MARK: - DevicesView

    func testDevicesViewFields() throws {
        let dir = try makeTempDir("phone-approval-view")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DeviceStore(directory: { dir })
        store.load()
        addConfirmed("PHONE1", platform: "ios", cred: "bdc_1", store: store, name: "iPhone")
        addConfirmed("DESK01", platform: "mac", cred: "bdc_2", store: store, name: "MacBook", approvedBy: "PHONE1")
        addConfirmed("DESK02", platform: "windows", cred: "bdc_3", store: store, name: "PC", approvedBy: "GONEKEY9")
        let q = ApprovalQueue()
        _ = q.add(deviceKeyId: "REQ", display: "Mac · REQ", name: "Mac", platform: "mac", sameNameExists: false,
                  remote: true, code: "333333", approve: { _ in .deviceGone }, end: { _ in })

        var view = LocalDeviceRoutes.devicesView(devices: store, approvals: q, invites: PairingInvites(), peers: TunnelPeers())
        XCTAssertEqual(view["remoteApprovalsEnabled"] as? Bool, true)
        XCTAssertEqual(view["remoteApprovalsAvailable"] as? Bool, false, "push の宛先がある許可できる端末が無い")
        let rows = try XCTUnwrap(view["devices"] as? [[String: Any]])
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0["deviceKeyId"] as! String, $0) })
        XCTAssertTrue(byKey["PHONE1"]?["approvedBy"] is NSNull)
        XCTAssertEqual(byKey["DESK01"]?["approvedBy"] as? String, store.device("PHONE1")?.display(deviceKeyId: "PHONE1"))
        XCTAssertEqual(byKey["DESK02"]?["approvedBy"] as? String, "GONE", "消えていれば先頭 4 文字")
        XCTAssertEqual((view["pending"] as? [[String: Any]])?.first?["remote"] as? Bool, true)

        XCTAssertEqual(store.setPush(deviceKeyId: "PHONE1", token: String(repeating: "e", count: 64),
                                     env: "development", locale: "ja"), .stored)
        store.setRemoteApprovalsEnabled(false)
        view = LocalDeviceRoutes.devicesView(devices: store, approvals: q, invites: PairingInvites(), peers: TunnelPeers())
        XCTAssertEqual(view["remoteApprovalsAvailable"] as? Bool, true)
        XCTAssertEqual(view["remoteApprovalsEnabled"] as? Bool, false)
    }

    /// pair_request の本文（spec/PROTOCOL-v3.md §10.4.1）。
    func testPairRequestBody() {
        XCTAssertEqual(PushService.pairRequestBody(locale: "ja", bridgeName: "Studio"),
                       "この PC（Studio）につなごうとしています。許可するには、その端末に出ている 6 桁を入力してください。")
        XCTAssertTrue(PushService.pairRequestBody(locale: "en", bridgeName: "Studio").contains("(Studio)"))
    }
}
