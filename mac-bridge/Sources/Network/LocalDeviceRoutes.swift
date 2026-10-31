import Foundation
import Vapor

/// 端末の管理（spec/PROTOCOL-v3.md Appendix A）。外す・自分で外す・作り直しの後始末をまとめる。
enum DeviceAdmin {
    /// `/local/registry/resume` などで登録し直すときに呼ぶ（BridgeServer が入れる）。
    nonisolated(unsafe) static var requestRegistration: (@Sendable () -> Void)?

    /// PC から外す。行を消して外した印（90 日）を残し、その後でトンネル・プレビューのセッションを閉じる。
    /// push の宛先は DeviceStore.onPushTargetsChanged で登録し直す。
    @discardableResult
    static func revoke(deviceKeyId: String) -> Bool {
        guard DeviceStore.shared.revoke(deviceKeyId: deviceKeyId) else { return false }
        PaseoRelayTunnelService.shared.closeTunnels(deviceKeyId: deviceKeyId)
        PreviewSessionStore.shared.removeAll(creator: deviceKeyId)
        // その端末が開いたターミナルも止める（外した端末に 24 時間シェルを残さない）。
        PtyRegistry.shared.drop(owner: deviceKeyId)
        PaneShareHub.shared.drop(owner: deviceKeyId)
        WebSocketServer.wslog("device revoked \(deviceKeyId.prefix(8))")
        return true
    }

    /// 端末が自分を外す（`/device/unpair`）。受けた時点で `unpairing`、応答の 1 秒後に行を消してトンネルを閉じる。
    static func unpair(deviceKeyId: String) -> Bool {
        guard DeviceStore.shared.beginUnpair(deviceKeyId: deviceKeyId) else { return false }
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            DeviceStore.shared.finishUnpair(deviceKeyId: deviceKeyId)
            PaseoRelayTunnelService.shared.closeTunnels(deviceKeyId: deviceKeyId)
            PreviewSessionStore.shared.removeAll(creator: deviceKeyId)
            PtyRegistry.shared.drop(owner: deviceKeyId)
            PaneShareHub.shared.drop(owner: deviceKeyId)
            WebSocketServer.wslog("device unpaired itself \(deviceKeyId.prefix(8))")
        }
        return true
    }
}

/// Bridge のローカル管理 API（`/local/*`、`.local` ＋管理鍵だけ。spec/PROTOCOL-v3.md Appendix A）と、端末の自己管理 API（`/device/*`、§13.5）。
/// 認証は BridgeAuth の表（middleware）と、各ルートの requireAdmin / requireDevice の両方で確かめる。
enum LocalDeviceRoutes {
    static let maxBody: ByteCount = 4096

    static func register(app: Application) {
        let local = app.grouped("local")

        local.on(.POST, "pairing", "invites", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            // 中継が無いと、QR を読んだ端末がつなぎに行く先が無い（Windows と同じ 503）。
            guard PaseoRelayTunnelService.shared.relayURL != nil else { return error(.serviceUnavailable, "relay_not_configured") }
            let invite = try PairingInvites.shared.create()
            WebSocketServer.wslog("pairing invite created via desktop")
            return json(.created, ["inviteId": invite.inviteId, "url": pairURL(for: invite), "expiresAt": invite.expiresAt])
        }
        local.on(.DELETE, "pairing", "invites", ":inviteId") { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            guard let id = req.parameters.get("inviteId"), PairingInvites.shared.cancel(inviteId: id) else {
                return error(.notFound, "not_found")
            }
            return Response(status: .noContent)
        }
        local.get("devices") { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            return json(.ok, devicesView())
        }
        local.get("devices", "events") { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            let since = try? req.query.get(Int.self, at: "since")
            let boot = try? req.query.get(String.self, at: "boot")
            await DeviceStore.shared.waitForChange(since: since, boot: boot, timeout: 25)
            return json(.ok, devicesView())
        }
        local.on(.POST, "devices", ":deviceKeyId", "revoke", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            guard let id = req.parameters.get("deviceKeyId"), DeviceAdmin.revoke(deviceKeyId: id) else {
                return error(.notFound, "not_found")
            }
            return json(.ok, ["ok": true])
        }
        local.on(.POST, "devices", ":deviceKeyId", "rename", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            let name = (bodyObject(req)?["name"] as? String) ?? ""
            guard let id = req.parameters.get("deviceKeyId"),
                  let display = DeviceStore.shared.rename(deviceKeyId: id, label: name) else {
                return error(.notFound, "not_found")
            }
            return json(.ok, ["ok": true, "display": display])
        }
        local.on(.POST, "approvals", "open", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            guard DeviceStore.shared.approvalsEnabled else { return error(.conflict, "approvals_disabled") }
            return json(.ok, ["until": ApprovalQueue.shared.openWindow()])
        }
        local.on(.POST, "approvals", "close", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            ApprovalQueue.shared.closeWindow(reason: .closed)
            return Response(status: .noContent)
        }
        local.on(.POST, "devices", "pending", "approve", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            let code = (bodyObject(req)?["code"] as? String) ?? ""
            switch await ApprovalQueue.shared.submit(code: code) {
            case .ok(let deviceKeyId, let display):
                return json(.ok, ["ok": true, "deviceKeyId": deviceKeyId, "display": display])
            case .mismatch(let remaining):
                return json(.badRequest, ["error": "code_mismatch", "remaining": remaining])
            case .badCode:
                return error(.badRequest, "bad_code")
            case .noPending:
                return error(.notFound, "no_pending")
            case .deviceGone:
                return error(.gone, "device_gone")
            }
        }
        local.on(.POST, "devices", "pending", ":pendingId", "reject", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            guard let id = req.parameters.get("pendingId"), ApprovalQueue.shared.reject(pendingId: id) else {
                return error(.notFound, "not_found")
            }
            return json(.ok, ["ok": true])
        }
        local.on(.POST, "devices", "reset", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            let raw = (bodyObject(req)?["reason"] as? String) ?? ""
            guard let reason = allowedResetReason(raw) else { return error(.badRequest, "bad_reason") }
            KeyStore.resetIdentity(reason)
            DeviceAdmin.requestRegistration?()
            return json(.ok, ["ok": true, "bridgeId": KeyStore.loadOrCreateBridgeId()])
        }
        local.on(.POST, "devices", "settings", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            let body = bodyObject(req)
            if let on = body?["approvalsEnabled"] as? Bool {
                DeviceStore.shared.setApprovalsEnabled(on)
                if !on {
                    ApprovalQueue.shared.closeWindow(reason: .closed)
                    ApprovalQueue.shared.closeRemote(reason: .closed)
                }
            }
            // スマホからの許可（spec/PROTOCOL-v3.md §10.4.1）。切ったら remote の申し込みを全部取り下げる。
            if let on = body?["remoteApprovalsEnabled"] as? Bool {
                DeviceStore.shared.setRemoteApprovalsEnabled(on)
                if !on { ApprovalQueue.shared.closeRemote(reason: .closed) }
            }
            return json(.ok, ["ok": true])
        }
        local.on(.POST, "registry", "resume", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            KeyStore.clearRegistryHold()
            DeviceAdmin.requestRegistration?()
            return json(.ok, ["ok": true])
        }
        local.on(.POST, "registry", "previous", "dismiss", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            RegistryStatus.clearPrevious()
            DeviceStore.shared.bumpVersion()
            return Response(status: .noContent)
        }

        let device = app.grouped("device")
        device.get("self") { req async throws -> Response in
            let (id, row) = try BridgeAuth.requireDevice(req)
            return json(.ok, ["deviceKeyId": id, "display": row.display(deviceKeyId: id),
                              "platform": row.platform, "createdAt": row.createdAt])
        }
        device.on(.POST, "unpair", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            let (id, _) = try BridgeAuth.requireDevice(req)
            guard DeviceAdmin.unpair(deviceKeyId: id) else { return error(.unauthorized, "unauthorized") }
            return json(.ok, ["ok": true])
        }

        // スマホで許可する（spec/PROTOCOL-v3.md §10.4.1・§13.5）。トンネルからの bdc_ で、許可できる端末だけ。
        device.get("approvals") { req async throws -> Response in
            let (id, _) = try BridgeAuth.requireDevice(req)
            guard DeviceStore.shared.isApprover(id) else { return error(.forbidden, "not_approver") }
            return json(.ok, approvalsView())
        }
        device.on(.POST, "approvals", "approve", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            let (id, _) = try BridgeAuth.requireDevice(req)
            guard DeviceStore.shared.isApprover(id) else { return error(.forbidden, "not_approver") }
            guard DeviceStore.shared.remoteApprovalsEnabled else { return error(.conflict, "disabled") }
            let code = (bodyObject(req)?["code"] as? String) ?? ""
            let result = await ApprovalQueue.shared.submit(code: code, approvedBy: id)
            switch result {
            case .ok(let deviceKeyId, let display):
                WebSocketServer.wslog("device approval by \(id.prefix(8)): approved \(deviceKeyId.prefix(8))")
                return json(.ok, ["ok": true, "deviceKeyId": deviceKeyId, "display": display])
            case .mismatch(let remaining):
                WebSocketServer.wslog("device approval by \(id.prefix(8)): code_mismatch remaining=\(remaining)")
                return json(.badRequest, ["error": "code_mismatch", "remaining": remaining])
            case .badCode:
                return error(.badRequest, "bad_code")
            case .noPending:
                return error(.notFound, "no_pending")
            case .deviceGone:
                return error(.gone, "device_gone")
            }
        }
        device.on(.POST, "approvals", ":pendingId", "reject", body: .collect(maxSize: maxBody)) { req async throws -> Response in
            let (id, _) = try BridgeAuth.requireDevice(req)
            guard DeviceStore.shared.isApprover(id) else { return error(.forbidden, "not_approver") }
            guard DeviceStore.shared.remoteApprovalsEnabled else { return error(.conflict, "disabled") }
            guard let pendingId = req.parameters.get("pendingId"), ApprovalQueue.shared.reject(pendingId: pendingId) else {
                return error(.notFound, "not_found")
            }
            WebSocketServer.wslog("device approval by \(id.prefix(8)): rejected")
            return json(.ok, ["ok": true])
        }
    }

    /// `GET /device/approvals` の本文（番号は入れない）。スマホからの許可が切れていれば `enabled:false` と空の一覧。
    static func approvalsView(devices store: DeviceStore = .shared, approvals: ApprovalQueue = .shared) -> [String: Any] {
        guard store.remoteApprovalsEnabled else { return ["pending": [[String: Any]](), "enabled": false] }
        return ["pending": approvals.views().map(pendingView), "enabled": true]
    }

    /// 承認待ちの 1 件（DevicesView と `/device/approvals` で同じ形）。
    static func pendingView(_ p: ApprovalQueue.Pending) -> [String: Any] {
        ["pendingId": p.pendingId, "display": p.display, "platform": p.platform,
         "requestedAt": p.requestedAt, "expiresAt": p.expiresAt, "sameNameExists": p.sameNameExists, "remote": p.remote]
    }

    /// `revoked_by_account` は registry-hold の理由が revoked_by_account のときだけ（「すべて切断」のとき）。
    static func allowedResetReason(_ raw: String) -> KeyStore.ResetReason? {
        switch raw {
        case "user_reset": return .userReset
        case "account_removed": return .accountRemoved
        case "revoked_by_account":
            return KeyStore.registryHold()?.reason == KeyStore.ResetReason.revokedByAccount.rawValue ? .revokedByAccount : nil
        default: return nil
        }
    }

    static func pairURL(for invite: PairingInvites.Created) -> String {
        let b = BridgeIdentityInfo.paired()
        return PairingInvites.pairURL(bridgeId: b.bridgeId, name: b.name, platform: b.platform, relayURL: b.relayURL,
                                      relayId: b.relayId, bridgePub: KeyStore.e2ePublicKeyBase64URL(),
                                      secret: invite.secret, expiresAtMs: invite.expiresAt)
    }

    /// DevicesView（Appendix A。時刻はすべて UNIX ミリ秒）。確認コードはどこにも入れない。
    static func devicesView(devices store: DeviceStore = .shared, approvals: ApprovalQueue = .shared,
                            invites: PairingInvites = .shared, peers: TunnelPeers = .shared) -> [String: Any] {
        let rows = store.confirmedDevices()
        var nameCounts: [String: Int] = [:]
        for r in rows where r.device.label == nil { nameCounts[r.device.name, default: 0] += 1 }
        let displays = Dictionary(uniqueKeysWithValues: rows.map { ($0.deviceKeyId, $0.device.display(deviceKeyId: $0.deviceKeyId)) })
        // 許可した端末の表示名。消えていれば deviceKeyId の先頭 4 文字。
        func approver(_ id: String?) -> Any {
            guard let id else { return NSNull() }
            return displays[id] ?? String(id.prefix(4))
        }
        let devices: [[String: Any]] = rows.map { r in
            [
                "deviceKeyId": r.deviceKeyId,
                "name": r.device.name,
                "label": r.device.label ?? NSNull(),
                "display": r.device.display(deviceKeyId: r.deviceKeyId),
                "platform": r.device.platform,
                "via": r.device.via,
                "createdAt": r.device.createdAt,
                "lastSeenAt": r.device.lastSeenAt.map { $0 as Any } ?? NSNull(),
                "online": peers.count(deviceKeyId: r.deviceKeyId) > 0,
                "push": r.device.push != nil,
                "sameNameCount": r.device.label == nil ? (nameCounts[r.device.name] ?? 1) : 1,
                "approvedBy": approver(r.device.approvedBy),
            ]
        }
        let pending: [[String: Any]] = approvals.views().map(pendingView)
        let inviteViews: [[String: Any]] = invites.active().map { inv in
            var o: [String: Any] = ["inviteId": inv.inviteId, "expiresAt": inv.expiresAt]
            if let u = inv.usedBy { o["usedBy"] = ["display": u.display, "at": u.at] }
            return o
        }
        var view: [String: Any] = [
            "bootId": store.bootId,
            "version": store.version,
            "broken": store.isBroken,
            "approvalsEnabled": store.approvalsEnabled,
            "remoteApprovalsEnabled": store.remoteApprovalsEnabled,
            "remoteApprovalsAvailable": store.hasApproverWithPush,
            "approvalsOpenUntil": approvals.windowOpenUntil.map { $0 as Any } ?? NSNull(),
            "devices": devices,
            "pending": pending,
            "invites": inviteViews,
            "lastReset": store.lastReset.map { ["at": $0.at, "reason": $0.reason] as [String: Any] } ?? NSNull(),
            "registryPrevious": NSNull(),
        ]
        if let prev = RegistryStatus.read()?.registryPrevious {
            view["registryPrevious"] = ["bridgeId": prev.bridgeId, "since": prev.since]
        }
        return view
    }

    private static func bodyObject(_ req: Request) -> [String: Any]? {
        guard let buf = req.body.data else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(buffer: buf)) as? [String: Any]
    }

    static func json(_ status: HTTPResponseStatus, _ obj: [String: Any]) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Response(status: status,
                        headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                        body: .init(data: data))
    }

    static func error(_ status: HTTPResponseStatus, _ code: String) -> Response {
        json(status, ["error": code])
    }
}
