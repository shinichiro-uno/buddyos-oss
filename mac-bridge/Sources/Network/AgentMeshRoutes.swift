import Foundation
import Vapor

/// エージェントどうしで頼み合う口。
/// - `/local/orchestrator/settings`・`/local/remote-pcs`: デスクトップから（`.local` ＋管理鍵）
/// - `/device/orchestrator/<tool>`・`/device/sessions/summary`: 別の PC・iPhone から（トンネルの bdc_ だけ）
/// 認証は BridgeAuth の表（middleware）と、各ルートの requireAdmin / requireDevice の両方で確かめる。
enum AgentMeshRoutes {
    static let maxSettingsBody: ByteCount = 4096
    static let maxRemotePCsBody: ByteCount = "64kb"
    static let maxToolBody: ByteCount = "1mb"

    static func register(app: Application) {
        let local = app.grouped("local")
        local.get("orchestrator", "settings") { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            return LocalDeviceRoutes.json(.ok, ["allSessions": OrchestratorSettings.allSessions])
        }
        local.on(.POST, "orchestrator", "settings", body: .collect(maxSize: maxSettingsBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            guard let on = (bodyJSON(req) as? [String: Any])?["allSessions"] as? Bool else {
                return LocalDeviceRoutes.error(.badRequest, "bad_request")
            }
            do {
                try OrchestratorSettings.setAllSessions(on)
            } catch {
                return LocalDeviceRoutes.error(.internalServerError, "write_failed")
            }
            WebSocketServer.wslog("mesh.settings allSessions=\(on)")
            return LocalDeviceRoutes.json(.ok, ["ok": true])
        }
        local.on(.PUT, "remote-pcs", body: .collect(maxSize: maxRemotePCsBody)) { req async throws -> Response in
            try BridgeAuth.requireAdmin(req)
            guard let pcs = RemotePC.parseList(bodyJSON(req)) else {
                return LocalDeviceRoutes.error(.badRequest, "bad_request")
            }
            await Orchestrator.shared.setRemotePCs(pcs)
            return Response(status: .noContent)
        }

        let device = app.grouped("device")
        device.on(.POST, "orchestrator", ":tool", body: .collect(maxSize: maxToolBody)) { req async throws -> Response in
            let (deviceKeyId, _) = try BridgeAuth.requireDevice(req)
            let tool = req.parameters.get("tool") ?? ""
            guard Orchestrator.remoteToolNames.contains(tool) else {
                return LocalDeviceRoutes.error(.notFound, "unknown_tool")
            }
            let parsed = bodyJSON(req)
            guard req.body.data == nil || parsed is [String: Any] else {
                return LocalDeviceRoutes.error(.badRequest, "bad_request")
            }
            // 本文は出さない（端末の先頭 8 文字と道具の名前だけ）。
            WebSocketServer.wslog("mesh.device-call device=\(deviceKeyId.prefix(8)) tool=\(tool)")
            let (status, value) = await handleDeviceCall(tool: tool, body: parsed as? [String: Any] ?? [:],
                                                         deviceKeyId: deviceKeyId)
            return jsonResponse(status, value)
        }
        device.get("sessions", "summary") { req async throws -> Response in
            _ = try BridgeAuth.requireDevice(req)
            return LocalDeviceRoutes.json(.ok, await Orchestrator.shared.sessionsSummary())
        }
    }

    /// B 側で道具を呼ぶ（承認カードは出さない。上限・深さ・mainagent のフォルダ・自分自身は Orchestrator が確かめる）。
    /// 返すのは (HTTP の状態, 本文)。道具の失敗は 422 `{"error": 種類, "message": 文}`。
    static func handleDeviceCall(tool: String, body: [String: Any], deviceKeyId: String) async -> (HTTPResponseStatus, Any) {
        var args = body
        let capMode = (args.removeValue(forKey: "capMode") as? NSNumber)?.intValue ?? Orchestrator.defaultCeiling
        let depth = max(0, (args.removeValue(forKey: "depth") as? NSNumber)?.intValue ?? 0)
        let from = args.removeValue(forKey: "caller") as? [String: Any]
        args.removeValue(forKey: "pc")
        let caller = Orchestrator.Caller(
            token: "device:\(deviceKeyId)", agentId: "remote", parentSessionId: nil, depth: depth,
            remote: Orchestrator.RemoteCaller(deviceKeyId: deviceKeyId, capMode: capMode,
                                              bridgeId: from?["bridgeId"] as? String, name: from?["name"] as? String))
        do {
            let value = try await McpEndpoint.call(tool, args: args, caller: caller)
            return (.ok, value)
        } catch let e as Orchestrator.ToolError {
            return (.unprocessableEntity, ["error": e.code, "message": e.description])
        } catch {
            return (.unprocessableEntity, ["error": "tool_error", "message": "\(error)"])
        }
    }

    private static func bodyJSON(_ req: Request) -> Any? {
        guard let buf = req.body.data else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(buffer: buf))
    }

    /// 道具の結果は配列のこともあるので、LocalDeviceRoutes.json（辞書だけ）とは別に組む。
    private static func jsonResponse(_ status: HTTPResponseStatus, _ value: Any) -> Response {
        let data = JSONSerialization.isValidJSONObject(value)
            ? (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
            : Data("{}".utf8)
        return Response(status: status,
                        headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                        body: .init(data: data))
    }
}
