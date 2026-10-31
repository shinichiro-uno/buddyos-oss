import Foundation
import NIOWebSocket
import Vapor

/// この PC のデスクトップでいま開いているアプリ内ターミナルのペインを、別の PC のデスクトップから見て打つための口
/// （docs/PANE_SHARE_2026-10-25.md）。
///
/// ペインはこの PC の常駐プロセス（desktop の ptyHost.ts）が持っている。常駐プロセスがここへ WebSocket を 1 本張り
/// （`/terminal/share/host`）、Bridge は見ている人（`/terminal/share`）ごとに sid を振って、そのあいだを中継する。
///
/// - `/terminal/share/host?client=<name>`: この PC の中だけ（ローカル鍵）。client ごとに 1 本（開発版と製品版が並んで動くため）。
///   同じ client の新しい接続が来たら古い方を 4000 で閉じ、古い方につながっていた見ている人も切る。
/// - `/terminal/share?pane=<id>&cols=&rows=`: `/terminal/pty` と同じ認証・Origin / Host の確認。送り受けの形も `/terminal/pty` にそろえる。
/// - `GET /terminal/share/panes`: すべての常駐プロセスのペインをまとめた一覧。
enum TerminalShareRoutes {
    static func register(app: Application) {
        app.webSocket("terminal", "share", "host", maxFrameSize: .init(integerLiteral: 16 * 1024 * 1024), shouldUpgrade: { req in
            req.eventLoop.makeSucceededFuture([:])
        }) { req, ws in
            // この PC の中から、ローカル鍵でだけ（トンネル経由の端末は通さない）。
            guard BridgeRequestGuard.passes(req), BridgeAuth.denial(req, .localOnly) == nil,
                  BridgeAuth.principal(req) == .local else {
                _ = ws.close(code: .policyViolation)
                return
            }
            let raw = req.query[String.self, at: "client"]
            guard let client = PaneShareHub.validClient(raw) else {
                _ = ws.close(code: .policyViolation)
                return
            }
            ws.pingInterval = .seconds(30)
            ws.onText { ws, text in PaneShareHub.shared.hostText(from: ws, text: text) }
            ws.onClose.whenComplete { _ in PaneShareHub.shared.hostClosed(ws) }
            PaneShareHub.shared.connectHost(ws, client: client)
        }

        app.webSocket("terminal", "share", maxFrameSize: .init(integerLiteral: 4 * 1024 * 1024), shouldUpgrade: { req in
            req.eventLoop.makeSucceededFuture([:])
        }) { req, ws in
            // /terminal/pty と同じ（ブラウザのページからは張らせない。資格情報はトンネル経由なら bdc_、この PC の中ならローカル鍵）。
            guard BridgeRequestGuard.passes(req), let principal = BridgeAuth.principal(req) else {
                _ = ws.close(code: .policyViolation)
                return
            }
            guard let pane = req.query[String.self, at: "pane"], !pane.isEmpty, pane.count <= 128 else {
                _ = ws.close(code: .policyViolation)
                return
            }
            ws.pingInterval = .seconds(30)
            let cols = req.query[Int.self, at: "cols"].map(PaneShareHub.clamp)
            let rows = req.query[Int.self, at: "rows"].map(PaneShareHub.clamp)
            ws.onText { ws, text in PaneShareHub.shared.viewerText(from: ws, text: text) }
            ws.onClose.whenComplete { _ in PaneShareHub.shared.viewerClosed(ws) }
            // 見ている端末の名前（この PC の画面に「○○ が見ています」と出す）。この PC の中からなら無し。
            var name: String?
            if case let .device(id, device) = principal { name = device.display(deviceKeyId: id) }
            PaneShareHub.shared.connectViewer(ws, pane: pane, cols: cols, rows: rows, owner: BridgeAuth.creatorName(principal), name: name)
        }

        // 見られるペインの一覧。{"available":Bool,"panes":[{"id","agentId"?,"cwd"?,"cols","rows","viewers","state"?}]}
        app.get("terminal", "share", "panes") { req async throws -> Response in
            try BridgeAuth.requireAny(req, allowQuery: false)
            let list = await PaneShareHub.shared.list()
            // ペインの状態（/terminal/panes/poll と同じもの）は、分かるときだけ付ける。
            let states = await TerminalPaneStatus.shared.poll(since: -1, timeout: 0).entries
            var byPane: [String: String] = [:]
            for e in states { byPane[e.pane] = e.state }
            let panes: [[String: Any]] = list.panes.map { p in
                var o: [String: Any] = ["id": p.info.id, "cols": p.info.cols, "rows": p.info.rows, "viewers": p.viewers]
                if let a = p.info.agentId { o["agentId"] = a }
                if let c = p.info.cwd { o["cwd"] = c }
                if let s = byPane[p.info.id] { o["state"] = s }
                return o
            }
            let data = try JSONSerialization.data(withJSONObject: ["available": list.available, "panes": panes])
            var headers = HTTPHeaders(); headers.contentType = .json
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }
    }
}

/// 常駐プロセスと見ている人のあいだの中継。状態の読み書きは queue の上だけで行う。
final class PaneShareHub: @unchecked Sendable {
    static let shared = PaneShareHub()

    struct PaneInfo {
        let id: String
        let agentId: String?
        let cwd: String?
        let cols: Int
        let rows: Int
    }

    /// 常駐プロセスの接続（client ごとに 1 本）。
    final class HostLink {
        let client: String
        let ws: WebSocket
        var panes: [PaneInfo] = []
        init(client: String, ws: WebSocket) {
            self.client = client
            self.ws = ws
        }
        func has(pane: String) -> Bool { panes.contains { $0.id == pane } }
    }

    final class Viewer {
        enum State { case waitingHost, attaching, live, closed }
        let sid: String
        let owner: String
        /// 見ている端末の表示名（この PC の中からなら nil）。
        let name: String?
        let pane: String
        let ws: WebSocket
        var cols: Int?
        var rows: Int?
        var state = State.waitingHost
        /// attach を送った常駐プロセス。
        var host: HostLink?
        /// 送りきれていないバイト数。
        var inFlight = 0
        /// 送りが追いつかず data を捨てている（resync の答えの replay が届くまで）。
        var lagging = false
        var resyncSent = false
        init(sid: String, owner: String, name: String?, pane: String, ws: WebSocket, cols: Int?, rows: Int?) {
            self.sid = sid
            self.owner = owner
            self.name = name
            self.pane = pane
            self.ws = ws
            self.cols = cols
            self.rows = rows
        }
    }

    private let queue = DispatchQueue(label: "buddyos.pane-share")
    private var hosts: [String: HostLink] = [:]
    private var hostBySocket: [ObjectIdentifier: HostLink] = [:]
    private var viewers: [String: Viewer] = [:]
    private var viewerBySocket: [ObjectIdentifier: Viewer] = [:]
    private var nextSid = 0

    /// 1 つの端末（Principal）が同時に見られる数。
    static let maxPerOwner = 32
    /// 送りきれていない出力がこれを超えたら data を捨て、LOW を切ったら写しを送り直してもらう。
    static let sendHigh = 1024 * 1024
    static let sendLow = 256 * 1024
    /// 常駐プロセスがペインを持っていなかったとき、出てくるのを待つ秒数。
    static var hostWait: TimeInterval = 5
    /// attach の答えを待つ秒数。
    static var attachWait: TimeInterval = 15
    /// 同じ client の新しい接続に入れ替えたとき、古い方を閉じる番号。
    static let replacedCode: WebSocketErrorCode = .unknown(4000)

    static func clamp(_ n: Int) -> Int { max(2, min(1000, n)) }

    /// client の名前（64 字まで・[A-Za-z0-9._-]）。無ければ "default"。形が違えば nil。
    static func validClient(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return "default" }
        guard s.count <= 64, s.unicodeScalars.allSatisfy({
            ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "." || $0 == "_" || $0 == "-"
        }) else { return nil }
        return s
    }

    // MARK: - 常駐プロセス

    func connectHost(_ ws: WebSocket, client: String) {
        queue.async {
            if ws.isClosed { return }
            if let old = self.hosts[client] {
                // 同じ client の古い接続は閉じ、それにつながっていた見ている人も切る（A はつなぎ直す）。
                self.removeHost(old)
                _ = old.ws.close(code: Self.replacedCode)
            }
            let link = HostLink(client: client, ws: ws)
            self.hosts[client] = link
            self.hostBySocket[ObjectIdentifier(ws)] = link
        }
    }

    func hostClosed(_ ws: WebSocket) {
        queue.async {
            guard let link = self.hostBySocket[ObjectIdentifier(ws)] else { return }
            self.removeHost(link)
        }
    }

    /// その常駐プロセスを外し、つながっていた見ている人を閉じる（queue の上で呼ぶ）。
    private func removeHost(_ link: HostLink) {
        hostBySocket[ObjectIdentifier(link.ws)] = nil
        if hosts[link.client] === link { hosts[link.client] = nil }
        for v in viewers.values where v.host === link {
            close(v, code: .goingAway, detach: false)
        }
    }

    func hostText(from ws: WebSocket, text: String) {
        queue.async {
            guard let link = self.hostBySocket[ObjectIdentifier(ws)],
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let t = obj["t"] as? String else { return }
            if t == "panes" {
                link.panes = Self.parsePanes(obj["panes"])
                // ペインが出てくるのを待っている人を、持っている常駐プロセスへつなぐ。
                for v in self.viewers.values where v.state == .waitingHost && link.has(pane: v.pane) {
                    self.attach(v, to: link)
                }
                return
            }
            // 知らない sid・ほかの常駐プロセスの sid は捨てる。
            guard let sid = obj["sid"] as? String, let v = self.viewers[sid], v.host === link else { return }
            switch t {
            case "attached":
                guard v.state == .attaching else { return }
                v.state = .live
                self.sendJSON(v, ["type": "attached", "restored": true])
                if let snap = obj["snapshot"] as? String, !snap.isEmpty { self.sendJSON(v, ["type": "replay", "data": snap]) }
                self.sendSize(v, obj)
            case "replay":
                guard v.state == .live else { return }
                self.sendJSON(v, ["type": "replay", "data": obj["snapshot"] as? String ?? ""])
                self.sendSize(v, obj)
                v.lagging = false
                v.resyncSent = false
            case "data":
                guard v.state == .live, !v.lagging, let d = obj["data"] as? String, !d.isEmpty else { return }
                // 送りきれていない分が多い。溜めずに捨て、追いついたら写しを送り直してもらう。
                if v.inFlight > Self.sendHigh {
                    v.lagging = true
                    return
                }
                self.send(v, Data(d.utf8), opcode: .binary)
            case "size":
                guard v.state == .live else { return }
                self.sendSize(v, obj)
            case "exit":
                self.sendJSON(v, ["type": "exit", "code": obj["code"] as? Int ?? -1])
                self.close(v, code: .normalClosure, detach: false)
            case "gone":
                self.sendJSON(v, ["type": "gone"])
                self.close(v, code: .normalClosure, detach: false)
            default:
                break
            }
        }
    }

    // MARK: - 見ている人

    func connectViewer(_ ws: WebSocket, pane: String, cols: Int?, rows: Int?, owner: String, name: String? = nil) {
        queue.async {
            if ws.isClosed { return }
            if self.viewers.values.filter({ $0.owner == owner }).count >= Self.maxPerOwner {
                PtySession.sendJSON(ws, [
                    "type": "exit", "code": -1,
                    "message": "見ているターミナルが多すぎます（\(Self.maxPerOwner) 個まで）。使っていないターミナルを閉じてください",
                ])
                _ = ws.close(code: .normalClosure)
                return
            }
            self.nextSid += 1
            let v = Viewer(sid: "v\(self.nextSid)", owner: owner, name: name, pane: pane, ws: ws, cols: cols, rows: rows)
            self.viewers[v.sid] = v
            self.viewerBySocket[ObjectIdentifier(ws)] = v
            if let link = self.hosts.values.first(where: { $0.has(pane: pane) }) {
                self.attach(v, to: link)
                return
            }
            // まだどの常駐プロセスも持っていない。panes が届くのを待ち、来なければ gone。
            self.queue.asyncAfter(deadline: .now() + Self.hostWait) { [weak self, weak v] in
                guard let self, let v, v.state == .waitingHost else { return }
                self.sendJSON(v, ["type": "gone"])
                self.close(v, code: .normalClosure, detach: false)
            }
        }
    }

    func viewerText(from ws: WebSocket, text: String) {
        queue.async {
            guard let v = self.viewerBySocket[ObjectIdentifier(ws)],
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            switch type {
            case "input":
                guard let data = obj["data"] as? String, let link = v.host else { return }
                self.sendHost(link, ["t": "input", "sid": v.sid, "data": data])
            case "resize":
                guard let c = obj["cols"] as? Int, let r = obj["rows"] as? Int else { return }
                v.cols = Self.clamp(c)
                v.rows = Self.clamp(r)
                // attach の前なら、attach に載せる大きさだけ変える。
                if let link = v.host { self.sendHost(link, ["t": "resize", "sid": v.sid, "cols": v.cols!, "rows": v.rows!]) }
            default:
                // kill も含めて、ほかは捨てる（A で閉じても B の端末は止めない）。
                break
            }
        }
    }

    func viewerClosed(_ ws: WebSocket) {
        queue.async {
            guard let v = self.viewerBySocket[ObjectIdentifier(ws)] else { return }
            self.close(v, code: .normalClosure, detach: true)
        }
    }

    /// 端末を外した・PC を初期化したときに、その端末が見ているものを切る（owner を省くと全部）。常駐プロセスの接続は残す。
    func drop(owner: String? = nil) {
        queue.async {
            for v in self.viewers.values where owner == nil || v.owner == owner {
                PtySession.sendJSON(v.ws, ["type": "exit", "code": -1])
                self.close(v, code: .normalClosure, detach: true)
            }
        }
    }

    /// すべての常駐プロセスのペインと、それぞれを見ている数。
    func list() async -> (available: Bool, panes: [(info: PaneInfo, viewers: Int)]) {
        await withCheckedContinuation { cont in
            queue.async {
                var out: [(info: PaneInfo, viewers: Int)] = []
                for link in self.hosts.values.sorted(by: { $0.client < $1.client }) {
                    for p in link.panes {
                        let n = self.viewers.values.filter { $0.host === link && $0.pane == p.id }.count
                        out.append((p, n))
                    }
                }
                cont.resume(returning: (!self.hosts.isEmpty, out))
            }
        }
    }

    /// 見ている人の数（テスト用）。
    func viewerCount(owner: String? = nil) -> Int {
        queue.sync { viewers.values.filter { owner == nil || $0.owner == owner }.count }
    }

    /// つながっている常駐プロセスの数（テスト用）。
    var hostCount: Int { queue.sync { hosts.count } }

    // MARK: - 補助（queue の上で呼ぶ）

    private func attach(_ v: Viewer, to link: HostLink) {
        v.state = .attaching
        v.host = link
        var msg: [String: Any] = ["t": "attach", "sid": v.sid, "id": v.pane]
        if let name = v.name { msg["name"] = name }
        if let c = v.cols, let r = v.rows {
            msg["cols"] = c
            msg["rows"] = r
        }
        sendHost(link, msg)
        // 答えが無ければ閉じる（A がつなぎ直す）。
        queue.asyncAfter(deadline: .now() + Self.attachWait) { [weak self, weak v] in
            guard let self, let v, v.state == .attaching else { return }
            self.close(v, code: .goingAway, detach: true)
        }
    }

    /// 見ている人を外して閉じる。detach なら常駐プロセスにも伝える。
    private func close(_ v: Viewer, code: WebSocketErrorCode, detach: Bool) {
        guard v.state != .closed else { return }
        let attached = v.state == .attaching || v.state == .live
        v.state = .closed
        viewers[v.sid] = nil
        viewerBySocket[ObjectIdentifier(v.ws)] = nil
        if detach, attached, let link = v.host, hosts[link.client] === link {
            sendHost(link, ["t": "detach", "sid": v.sid])
        }
        v.host = nil
        if !v.ws.isClosed { _ = v.ws.close(code: code) }
    }

    private func sendSize(_ v: Viewer, _ obj: [String: Any]) {
        guard let c = obj["cols"] as? Int, let r = obj["rows"] as? Int else { return }
        sendJSON(v, ["type": "size", "cols": c, "rows": r])
    }

    private func sendJSON(_ v: Viewer, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        send(v, data, opcode: .text)
    }

    /// 見ている人へ送る。送り終わったら数を減らし、捨てていた分の写しを 1 度だけ頼む。
    private func send(_ v: Viewer, _ data: Data, opcode: WebSocketOpcode) {
        let n = data.count
        v.inFlight += n
        let promise = v.ws.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self, weak v] _ in
            guard let self else { return }
            self.queue.async {
                guard let v, v.state != .closed else { return }
                v.inFlight -= n
                if v.lagging, !v.resyncSent, v.inFlight < Self.sendLow, let link = v.host {
                    v.resyncSent = true
                    self.sendHost(link, ["t": "resync", "sid": v.sid])
                }
            }
        }
        v.ws.send(raw: data, opcode: opcode, promise: promise)
    }

    private func sendHost(_ link: HostLink, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        link.ws.send(text)
    }

    /// panes の一覧。id が無い・長すぎるものは捨てる。
    static func parsePanes(_ raw: Any?) -> [PaneInfo] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { p in
            guard let id = p["id"] as? String, !id.isEmpty, id.count <= 128 else { return nil }
            return PaneInfo(id: id, agentId: p["agentId"] as? String, cwd: p["cwd"] as? String,
                            cols: p["cols"] as? Int ?? 80, rows: p["rows"] as? Int ?? 24)
        }
    }
}
