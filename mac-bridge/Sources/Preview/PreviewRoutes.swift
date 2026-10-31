import Vapor
import NIOCore
import Foundation

/// Live Preview HTTP routes, registered on the same Vapor app / port 8765 as
/// the WebSocket + /health endpoints.
///
/// 認証は次のとおり。`?apiKey=` のクエリはどのルートでも受け付けない。
///   - Bearer ヘッダ専用（Origin の関門あり）: /preview/session, /preview/targets, /preview/sim/{frame,home,text},
///     /preview/web/:port/**
///   - プレビューのセッション（`s=` / パス）: /preview/ui, /preview/sim/{stream,tap,swipe}, /preview/w/:session/**
///
/// This is a direct port of /tmp/simstream.mjs into Vapor:
///   - POST /preview/session    -> 1 つの表示対象だけに効くセッションを作る
///   - GET /preview/sim/stream  -> event-driven MJPEG (multipart/x-mixed-replace)
///   - GET /preview/sim/frame   -> latest single JPEG
///   - GET /preview/sim/tap|swipe|home|text -> SimHID（SimulatorKit へ直接）
///   - GET /preview/ui          -> the hosted interactive control page (sim or web)
///   - GET /preview/targets     -> booted sims + listening localhost web ports
///   - ALL /preview/w/:session/** -> reverse proxy to 127.0.0.1:<セッションのポート>（sandbox の iframe 用）
///   - ALL /preview/web/:port/** -> reverse proxy to 127.0.0.1:<port>（Bearer 直）
enum PreviewRoutes {
    static func register(app: Application) {
        let preview = app.grouped("preview")

        // 0) セッションを作る ------------------------------------------------
        // 本文は認証を通ってから読む（.stream で受けて 4KB まで collect）。
        preview.on(.POST, "session", body: .stream) { req async throws -> Response in
            if let denied = bearerDenial(req) { return jsonError(denied.status, denied.code) }
            _ = try await req.body.collect(max: sessionRequestMaxBytes).get()
            let raw = req.body.data.flatMap { buf -> String? in
                guard let obj = try? JSONSerialization.jsonObject(with: Data(buffer: buf)) as? [String: Any] else { return nil }
                return obj["target"] as? String
            } ?? ""
            guard let target = PreviewTarget(param: raw) else { return jsonError(.badRequest, "invalid_target") }
            if case .web(let port) = target {
                guard await allowedWebPorts(req).contains(port) else { return jsonError(.forbidden, "port_not_allowed") }
            }
            // 作った Principal を覚え、セッションで開くときに出どころと照らし合わせる。
            let creator = BridgeAuth.principal(req, allowQuery: false).map(BridgeAuth.creatorName) ?? "local"
            let session = PreviewSessionStore.shared.create(target: target, creator: creator)
            let payload: [String: Any] = [
                "session": session,
                "url": "/preview/ui?s=\(session)",
                "target": target.param,
                "expiresIn": Int(PreviewSessionStore.idleTTL),
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            TrafficMeter.shared.record("preview.session.out", bytes: data.count)
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                body: .init(data: data)
            )
        }

        // 1) Targets discovery -----------------------------------------------
        preview.get("targets") { req async throws -> Response in
            try requireBearer(req)
            let payload = await discoverTargets(req)
            let data = try JSONEncoder().encode(payload)
            TrafficMeter.shared.record("preview.targets.out", bytes: data.count)
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                body: .init(data: data)
            )
        }

        // 2) Hosted interactive control page ---------------------------------
        preview.get("ui") { req async throws -> Response in
            // ページの URL（?s=...）が Referer として漏れないよう、meta タグに加えてヘッダでも指定する。
            var headers: HTTPHeaders = [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
                "Referrer-Policy": "no-referrer",
                "Content-Security-Policy": pageContentSecurityPolicy,
            ]
            let session = try? req.query.get(String.self, at: "s")
            guard let session, let target = PreviewSessionStore.shared.target(for: session, creator: BridgeAuth.previewCreator(req)) else {
                headers.replaceOrAdd(name: "Content-Security-Policy", value: "default-src 'none'; style-src 'unsafe-inline'")
                return Response(status: .unauthorized, headers: headers, body: .init(string: expiredPageHTML))
            }
            // sim ターゲットは端末の論理サイズ比（wPts:hPts）を HTML へ渡す。
            // MJPEG の <img> は WKWebView 上で naturalWidth/Height が取れないことがあり、
            // ページ内のレターボックス計算が NaN になってタップ座標が崩れる。bridge が
            // 把握している実寸比を fallback として注入することで、タップ操作を安定させる。
            var aspect: Double? = nil
            if case .sim(let udid) = target {
                let (w, h) = await SimController.shared.describe(udid: udid)
                if w > 0, h > 0 { aspect = Double(w) / Double(h) }
            }
            let html = previewPageHTML(target: target, session: session, aspect: aspect)
            TrafficMeter.shared.record("preview.ui.out", bytes: html.utf8.count)
            return Response(status: .ok, headers: headers, body: .init(string: html))
        }

        // 3) MJPEG stream -----------------------------------------------------
        preview.get("sim", "stream") { req -> Response in
            let udid = try simAuth(req)
            // セッションで見ている間は、映像が流れているだけでもセッションを延ばす（つなぎ直しで切れないように）。
            let sessionToken = try? req.query.get(String.self, at: "s")
            let streamCreator = BridgeAuth.previewCreator(req)
            let response = Response(status: .ok)
            response.headers.replaceOrAdd(name: .contentType, value: "multipart/x-mixed-replace; boundary=frame")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            response.headers.replaceOrAdd(name: .connection, value: "close")
            response.body = .init(stream: { writer in
                Task {
                    let frames = await SimController.shared.subscribe(udid: udid)
                    // 切断は write の失敗でしか分からないので、フレームが途絶える（sim 停止・
                    // 古い UDID）と iOS が閉じても検知できず capture loop が回り続ける。
                    // フレームと 1 秒ごとの tick を 1 本のイベント列に束ね、write はこの Task
                    // だけで行う（別 Task から write すると multipart のパートが混ざる）。
                    let (events, sink) = AsyncStream.makeStream(
                        of: SimStreamEvent.self, bufferingPolicy: .bufferingNewest(2)
                    )
                    let pump = Task {
                        for await frame in frames { sink.yield(.frame(frame)) }
                        sink.finish()
                    }
                    let ticker = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            sink.yield(.tick)
                        }
                    }
                    let startedAt = ProcessInfo.processInfo.systemUptime
                    var lastWriteAt = startedAt
                    var lastFrame: Data? = nil
                    loop: for await event in events {
                        let frame: Data
                        switch event {
                        case .frame(let f):
                            frame = f
                            lastFrame = f
                        case .tick:
                            if let sessionToken { _ = PreviewSessionStore.shared.target(for: sessionToken, creator: streamCreator) }
                            let now = ProcessInfo.processInfo.systemUptime
                            guard now - lastWriteAt >= simKeepaliveInterval else { continue }
                            if let f = lastFrame {
                                // keepalive: 直前フレームを丸ごと再送する（空パートや余分な
                                // バイトは <img> の表示を壊す）。書けなければ切断とみなす。
                                frame = f
                            } else if now - startedAt >= simNoFrameTimeout {
                                // 一度もフレームが取れない。再送するものが無く切断も検知
                                // できないので、ストリームを閉じて capture loop を解放する。
                                break loop
                            } else {
                                continue
                            }
                        }
                        let header = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n"
                        var buf = ByteBufferAllocator().buffer(capacity: header.utf8.count + frame.count + 2)
                        buf.writeString(header)
                        buf.writeBytes(frame)
                        buf.writeString("\r\n")
                        TrafficMeter.shared.record(
                            "preview.sim.stream.out",
                            bytes: header.utf8.count + frame.count + 2
                        )
                        do {
                            try await writer.write(.buffer(buf)).get()
                        } catch {
                            // Client disconnected: AsyncStream termination handler
                            // (onTermination) decrements the ref-count and tears
                            // down the capture loop when the last subscriber leaves.
                            break loop
                        }
                        lastWriteAt = ProcessInfo.processInfo.systemUptime
                    }
                    // pump を止めると frames の購読が終わり（onTermination → detach）、
                    // 最後の購読者なら capture loop も止まる。
                    pump.cancel()
                    ticker.cancel()
                    _ = try? await writer.write(.end).get()
                }
            })
            return response
        }

        // 4) Latest single frame (used by iOS "Send screen to agent") --------
        preview.get("sim", "frame") { req async throws -> Response in
            try requireBearer(req)
            let udid = try queryUDID(req)
            guard let data = await SimController.shared.latestFrame(udid: udid) else {
                return Response(status: .serviceUnavailable,
                                headers: ["Content-Type": "text/plain"],
                                body: .init(string: "no frame"))
            }
            TrafficMeter.shared.record("preview.sim.frame.out", bytes: data.count)
            return Response(
                status: .ok,
                headers: ["Content-Type": "image/jpeg", "Cache-Control": "no-store"],
                body: .init(data: data)
            )
        }

        // 5-8) Control: tap / swipe / home / text ----------------------------
        preview.get("sim", "tap") { req async throws -> Response in
            let udid = try simAuth(req)
            recordControlInput(req)
            let x = clamp01(queryDouble(req, "x"))
            let y = clamp01(queryDouble(req, "y"))
            let r = await SimController.shared.tap(udid: udid, x: x, y: y)
            return controlResponse(ok: r.ok, body: r.ok ? "tap" : r.err)
        }

        preview.get("sim", "swipe") { req async throws -> Response in
            let udid = try simAuth(req)
            recordControlInput(req)
            let x1 = clamp01(queryDouble(req, "x1"))
            let y1 = clamp01(queryDouble(req, "y1"))
            let x2 = clamp01(queryDouble(req, "x2"))
            let y2 = clamp01(queryDouble(req, "y2"))
            let d = min(2.0, max(0.05, queryDouble(req, "d", fallback: 0.3)))
            let r = await SimController.shared.swipe(udid: udid, x1: x1, y1: y1, x2: x2, y2: y2, duration: d)
            return controlResponse(ok: r.ok, body: r.ok ? "swipe" : r.err)
        }

        preview.get("sim", "home") { req async throws -> Response in
            try requireBearer(req)
            recordControlInput(req)
            let udid = try queryUDID(req)
            let r = await SimController.shared.home(udid: udid)
            return controlResponse(ok: r.ok, body: r.ok ? "home" : r.err)
        }

        preview.get("sim", "text") { req async throws -> Response in
            try requireBearer(req)
            recordControlInput(req)
            let udid = try queryUDID(req)
            let q = (try? req.query.get(String.self, at: "q")) ?? ""
            let r = await SimController.shared.text(udid: udid, q)
            return controlResponse(ok: r.ok, body: r.ok ? "text" : r.err)
        }

        // 9) Web reverse-proxy (catch-all) -----------------------------------
        // dev アプリの fetch / フォームは GET 以外も使うので残りのメソッドも中継する
        // （HEAD は Vapor が GET ルートへ回す）。本文は .collect だと未認証でも上限まで
        // メモリに溜まるため .stream で受け、認証後に読む。
        // 9a) sandbox の iframe 用。中継先のポートはセッションが決める。
        for method in [HTTPMethod.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS] {
            preview.on(method, "w", ":session", "**", body: .stream) { req async throws -> Response in
                try await sessionProxy(req)
            }
            preview.on(method, "w", ":session", body: .stream) { req async throws -> Response in
                try await sessionProxy(req)
            }
        }
        // 9b) Bearer 直（ネイティブ・ツール用）。検出した開発サーバーのポートだけ。
        for method in [HTTPMethod.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS] {
            preview.on(method, "web", ":port", "**", body: .stream) { req async throws -> Response in
                try await bearerProxy(req)
            }
            preview.on(method, "web", ":port", body: .stream) { req async throws -> Response in
                try await bearerProxy(req)
            }
        }

        // 10) Web snapshot — not implemented server-side in v1; iOS uses
        // WKWebView.takeSnapshot natively. Return 501 for discoverability.
        preview.get("web", ":port", "snapshot") { req async throws -> Response in
            try requireBearer(req)
            return Response(status: .notImplemented,
                            headers: ["Content-Type": "text/plain"],
                            body: .init(string: "web snapshot is handled natively on iOS (WKWebView.takeSnapshot)"))
        }
    }

    // MARK: - auth

    /// Bearer ヘッダ専用のルートの確認。Origin / Host の関門（middleware と同じ）もここで見る
    /// （PreviewRoutes だけを載せたアプリでも抜けないように）。`?apiKey=` のクエリは受け付けない。
    static func requireBearer(_ req: Request) throws {
        if let denied = bearerDenial(req) { throw Abort(denied.status, reason: denied.code) }
    }

    /// 資格情報は Principal（トンネル経由なら bdc_、この PC の中からならローカル鍵。spec/PROTOCOL-v3.md §13）。
    private static func bearerDenial(_ req: Request) -> (status: HTTPResponseStatus, code: String)? {
        if !BridgeRequestGuard.passesHost(req) { return (.forbidden, "forbidden_host") }
        if !BridgeRequestGuard.allowedOrigin(req.headers[.origin]) { return (.forbidden, "forbidden_origin") }
        if let d = BridgeAuth.denial(req, .any(allowQuery: false)) { return (d.status, d.code) }
        return nil
    }

    /// `udid` クエリ（UUID の形）。違えば 400。
    private static func queryUDID(_ req: Request) throws -> String {
        guard let raw = try? req.query.get(String.self, at: "udid"),
              let udid = SimController.normalizedUDID(raw) else {
            throw Abort(.badRequest, reason: "invalid udid")
        }
        return udid
    }

    /// sim の stream / tap / swipe。プレビューのセッション（`s=`、sim のもの）か Bearer ヘッダ。
    /// セッションならその udid を使い、`udid` クエリが付いていれば同じであること。
    private static func simAuth(_ req: Request) throws -> String {
        if !BridgeRequestGuard.passesHost(req) { throw Abort(.forbidden, reason: "forbidden_host") }
        if let s = try? req.query.get(String.self, at: "s") {
            guard case .sim(let udid) = PreviewSessionStore.shared.target(for: s, creator: BridgeAuth.previewCreator(req)) else {
                throw Abort(.unauthorized)
            }
            if let raw = try? req.query.get(String.self, at: "udid"), SimController.normalizedUDID(raw) != udid {
                throw Abort(.forbidden, reason: "udid mismatch")
            }
            return udid
        }
        try requireBearer(req)
        return try queryUDID(req)
    }

    // MARK: - proxy

    private static func sessionProxy(_ req: Request) async throws -> Response {
        if !BridgeRequestGuard.passesHost(req) { throw Abort(.forbidden, reason: "forbidden_host") }
        guard let session = req.parameters.get("session"),
              case .web(let port) = PreviewSessionStore.shared.target(for: session, creator: BridgeAuth.previewCreator(req)) else {
            throw Abort(.unauthorized)
        }
        // 作った時点でポートは確かめ済み。Bridge 自身の番号でないことだけ毎回見る。
        guard !bridgePorts(req).contains(port) else { throw Abort(.forbidden, reason: "port_not_allowed") }
        return try await proxy(req, port: port, prefix: "/preview/w/\(session)", sandboxed: true)
    }

    private static func bearerProxy(_ req: Request) async throws -> Response {
        try requireBearer(req)
        guard let port = req.parameters.get("port").flatMap({ Int($0) }), port > 0, port < 65536 else {
            throw Abort(.badRequest, reason: "invalid port")
        }
        guard await allowedWebPorts(req).contains(port) else { throw Abort(.forbidden, reason: "port_not_allowed") }
        return try await proxy(req, port: port, prefix: "/preview/web/\(port)", sandboxed: false)
    }

    private static func proxy(_ req: Request, port: Int, prefix: String, sandboxed: Bool) async throws -> Response {
        // GET 以外は .stream で受けているので、認証を通ってから上限付きで本文を読む
        // （collect 後は req.body.data で読めるので WebProxy はそのまま使える）。
        if req.method != .GET, req.method != .HEAD {
            _ = try await req.body.collect(max: webProxyMaxBodyBytes).get()
        }
        if let body = req.body.data {
            TrafficMeter.shared.record("preview.web.in", bytes: body.readableBytes)
        } else {
            TrafficMeter.shared.record("preview.web.in", bytes: 0)
        }
        let response = try await WebProxy.handle(req, port: port, prefix: prefix, sandboxed: sandboxed)
        TrafficMeter.shared.record("preview.web.out", bytes: response.body.data?.count ?? 0)
        return response
    }

    private static func jsonError(_ status: HTTPResponseStatus, _ error: String) -> Response {
        Response(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
            body: .init(string: "{\"error\":\"\(error)\"}")
        )
    }

    // MARK: - MJPEG keepalive

    /// この秒数 write が無ければ直前フレームを再送して切断を検知する。
    private static let simKeepaliveInterval: TimeInterval = 5
    /// 一度もフレームが取れないままこの秒数経ったらストリームを閉じる。
    private static let simNoFrameTimeout: TimeInterval = 20

    private enum SimStreamEvent: Sendable {
        case frame(Data)
        case tick
    }

    /// プロキシ本文（POST/PUT 等）の上限。WebProxy は本文も応答も全量バッファするので現実的な値に留める。
    private static let webProxyMaxBodyBytes = 32 * 1024 * 1024
    /// POST /preview/session の本文の上限。
    private static let sessionRequestMaxBytes = 4 * 1024

    // MARK: - targets discovery

    private static func discoverTargets(_ req: Request) async -> PreviewTargets {
        async let simsTask = simTargets()
        async let webTask = webTargets(req)
        let sims = await simsTask
        let web = await webTask
        return PreviewTargets(sim: sims, web: web)
    }

    private static func simTargets() async -> [SimTarget] {
        let devices = await SimController.shared.bootedDevices()
        var out: [SimTarget] = []
        for d in devices {
            let (w, h) = await SimController.shared.describe(udid: d.udid)
            out.append(SimTarget(udid: d.udid, name: d.name, state: "Booted", wPts: w, hPts: h))
        }
        return out
    }

    private static func webTargets(_ req: Request) async -> [WebTarget] {
        let candidates = await allowedWebPorts(req).sorted()
        let probed = await withTaskGroup(of: (Int, Bool, String?).self) { group in
            for port in candidates {
                group.addTask {
                    let (reachable, title) = await probeWeb(port: port)
                    return (port, reachable, title)
                }
            }
            var out: [(Int, Bool, String?)] = []
            for await r in group { out.append(r) }
            return out
        }
        return probed.filter { $0.1 }.sorted { $0.0 < $1.0 }
            .map { WebTarget(port: $0.0, reachable: true, title: $0.2) }
    }

    // MARK: - 中継してよいポート

    /// 既定の候補（BUDDYOS_PREVIEW_WEB_PORTS で置き換えられる）。
    static func candidateWebPorts() -> Set<Int> {
        let env = ProcessInfo.processInfo.environment["BUDDYOS_PREVIEW_WEB_PORTS"]
        let portsStr = (env?.isEmpty == false ? env! : "3000,5173,8080,4321,19006,8081")
        return Set(portsStr.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 && $0 < 65536 })
    }

    /// Bridge 自身の待ち受けの番号（設定値と実際に bind した番号）。
    static func bridgePorts(_ req: Request) -> Set<Int> {
        var out: Set<Int> = [req.application.http.server.configuration.port]
        if let p = req.application.http.server.shared.localAddress?.port { out.insert(p) }
        if let p = KeyStore.currentPort { out.insert(p) }
        // 同じ Mac で並んで動いている別の Bridge（~/.buddyos/bridge.port に書いた番号）も除く。
        if let text = try? String(contentsOfFile: NSHomeDirectory() + "/.buddyos/bridge.port", encoding: .utf8),
           let p = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) { out.insert(p) }
        return out
    }

    /// 中継してよいポート = 既定の候補 ∪ このユーザーの開発サーバーらしいプロセスが待ち受けているポート − Bridge 自身。
    static func allowedWebPorts(_ req: Request) async -> Set<Int> {
        let listening = await DevServerPorts.listening()
        return candidateWebPorts().union(listening).subtracting(bridgePorts(req))
    }

    /// Quick loopback check to see if a dev server is listening. Title is parsed
    /// from <title> if cheaply available.
    /// 待ち受けていなければすぐ false。待ち受けていれば GET して題名を読む。SSR の dev サーバーは
    /// 初回や再ビルド直後に数秒かかることがあり、時間切れで「動いていない」にすると一覧から出たり
    /// 消えたりするので、時間切れは「動いている（題名なし）」とする。接続を切られた・HTTP でない
    /// などの失敗だけ false。
    private static func probeWeb(port: Int) async -> (Bool, String?) {
        guard isListening(port: port) else { return (false, nil) }
        return await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
            DispatchQueue.global().async {
                guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
                    cont.resume(returning: (false, nil)); return
                }
                var req = URLRequest(url: url)
                req.timeoutInterval = probeTimeout
                req.httpMethod = "GET"
                let sem = DispatchSemaphore(value: 0)
                var reachable = false
                var title: String? = nil
                let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
                    if let http = resp as? HTTPURLResponse, http.statusCode > 0 {
                        reachable = true
                        if let data, let body = String(data: data.prefix(8192), encoding: .utf8),
                           let r = body.range(of: "<title>", options: .caseInsensitive),
                           let end = body.range(of: "</title>", options: .caseInsensitive,
                                                 range: r.upperBound..<body.endIndex) {
                            title = String(body[r.upperBound..<end.lowerBound])
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    sem.signal()
                }
                task.resume()
                if sem.wait(timeout: .now() + probeTimeout + 0.1) == .timedOut {
                    task.cancel()
                    cont.resume(returning: (true, nil))
                    return
                }
                cont.resume(returning: (reachable, title))
            }
        }
    }

    private static let probeTimeout: TimeInterval = 2.0

    /// 127.0.0.1:<port> で待ち受けているか（ループバックの connect はすぐ結果が出る）。
    private static func isListening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - helpers

    private static func queryDouble(_ req: Request, _ key: String, fallback: Double = 0) -> Double {
        (try? req.query.get(Double.self, at: key)) ?? fallback
    }

    private static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }

    private static func recordControlInput(_ req: Request) {
        TrafficMeter.shared.record(
            "preview.sim.control.in",
            bytes: req.url.query?.utf8.count ?? 0
        )
    }

    private static func controlResponse(ok: Bool, body: String) -> Response {
        TrafficMeter.shared.record("preview.sim.control.out", bytes: body.utf8.count)
        return Response(status: ok ? .ok : .internalServerError,
                        headers: ["Content-Type": "text/plain; charset=utf-8"],
                        body: .init(string: body))
    }
}

// MARK: - JSON models

struct PreviewTargets: Content {
    let sim: [SimTarget]
    let web: [WebTarget]
}

struct SimTarget: Content {
    let udid: String
    let name: String
    let state: String
    let wPts: Int
    let hPts: Int
}

struct WebTarget: Content {
    let port: Int
    let reachable: Bool
    let title: String?
}
