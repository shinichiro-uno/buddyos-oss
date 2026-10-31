import Foundation
import Network

/// Paseo の中継を BuddyOS の暗号化 TCP トンネルとして使う（トンネル v3。spec/PROTOCOL-v3.md §7・§8）。
///
/// 中継は WebSocket のフレームを透過するだけ。握手は Noise_IKpsk2_25519_ChaChaPoly_SHA256 で、端末の鍵と
/// Bridge の鍵で相互に認証し、一時鍵で前方秘匿性を持たせる。中継に平文で見えるのは一時鍵だけ。
/// **一覧（DeviceStore）に無い端末はトンネルの入口で断る**（TOFU はしない）。v なし・v2 の init は
/// `buddyos_tunnel_error`（version）を返して閉じるだけ（v2 の握手や 401 の受け口は作らない）。
///
/// 1 本のデータ用の接続でできるのは connect（TCP を流す）・pair（QR の招待）・approve（PC で 6 桁を入力）のどれか 1 つ。
/// connect は 127.0.0.1 の Vapor へ TCP をつなぎ、そのローカル側の番号を TunnelPeers に入れる（§13.1）。
final class PaseoRelayTunnelService: @unchecked Sendable {
    static let shared = PaseoRelayTunnelService()

    private struct ControlEvent: Decodable {
        let type: String
        let connectionId: String?
        let connectionIds: [String]?
    }

    enum TunnelError: Error {
        case invalidRelayURL
        case invalidHandshake
        case localConnectionFailed
        case connectionClosed
        case timeout
        case refused
        case keyUnavailable
    }

    /// §12 の時間と枠。
    enum Limits {
        static let preAuthSlots = 16
        static let pairingSlots = 4
        static let msg1Timeout: Double = 5
        static let firstBinaryTimeout: Double = 10
        static let pairAckTimeout: Double = 5
        static let approveAckTimeout: Double = 60
        static let approvalKeepalive: Double = 20
        static let localConnectTimeout: Double = 5
    }

    private let lock = NSLock()
    private var generation = UUID()
    private var controlTask: Task<Void, Never>?
    private var dataTasks: [String: Task<Void, Never>] = [:]
    private var sockets: [UUID: URLSessionWebSocketTask] = [:]
    private var dataSockets: [String: URLSessionWebSocketTask] = [:]
    /// データ用の接続 → 端末（connect は open の後、pair・approve は msg1 の後に入れる）。端末ごとに閉じるのに使う。
    private var connectionDevices: [String: String] = [:]
    private let preAuth = PreAuthSlots()
    private let pairing = PairingSlots()
    private var localPort = 8765
    private var running = false
    private let failures = HandshakeFailureLog()

    private init() {}

    /// 中継の URL（`BUDDYOS_PASEO_RELAY_URL` → 配布物の既定）。nil なら中継につながない（`BridgeConfig.relayHint`）。
    var relayURL: String? { BridgeConfig.current.relayURL.value }

    /// 中継の URL（無ければ空。登録簿と `paired.bridge` に載せる値）。
    var relayURLString: String { relayURL ?? "" }

    /// 中継が無いときの案内を 1 回だけログに出したか。
    private var relayMissingLogged = false

    var serverId: String { KeyStore.loadOrCreatePaseoRelayId() }

    /// いま待ち受けている Bridge の番号（TunnelPeers の条件に使う）。
    var listenPort: Int { lock.withLock { localPort } }

    func start(port: Int) {
        stop()
        lock.lock()
        localPort = port
        running = true
        guard relayURL != nil else {
            // 中継が無い: Bridge は止めずにトンネルだけ張らない（この PC の中の desktop からは使える）。
            let first = !relayMissingLogged
            relayMissingLogged = true
            lock.unlock()
            if first { WebSocketServer.wslog("Paseo relay is off: \(BridgeConfig.relayHint)") }
            return
        }
        let run = UUID()
        generation = run
        controlTask = Task { [weak self] in
            await self?.runControlLoop(generation: run)
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        generation = UUID()
        running = false
        let control = controlTask
        controlTask = nil
        let tasks = Array(dataTasks.values)
        dataTasks.removeAll()
        let activeSockets = Array(sockets.values)
        sockets.removeAll()
        dataSockets.removeAll()
        connectionDevices.removeAll()
        lock.unlock()
        preAuth.clear()
        pairing.clear()
        activeSockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
        control?.cancel()
        tasks.forEach { $0.cancel() }
    }

    /// 作り直し（静的鍵・relayId が変わった）のあとに張り直す。止まっていれば何もしない。
    func restartIfRunning() {
        let (wasRunning, port) = lock.withLock { (running, localPort) }
        guard wasRunning else { return }
        start(port: port)
    }

    /// その端末のトンネルを全部閉じる（外したとき）。
    func closeTunnels(deviceKeyId: String) {
        let ids = lock.withLock { connectionDevices.filter { $0.value == deviceKeyId }.map(\.key) }
        ids.forEach { cancelDataConnection(id: $0) }
    }

    /// データ用の接続を全部閉じる（制御の接続は残す）。
    func closeAll() {
        let ids = lock.withLock { Array(dataTasks.keys) }
        ids.forEach { cancelDataConnection(id: $0) }
    }

    private func track(_ socket: URLSessionWebSocketTask, generation run: UUID, connectionID: String? = nil) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard generation == run else { throw CancellationError() }
        let id = UUID()
        sockets[id] = socket
        if let connectionID { dataSockets[connectionID] = socket }
        return id
    }

    private func untrack(_ id: UUID) {
        lock.lock()
        if let socket = sockets.removeValue(forKey: id) {
            dataSockets = dataSockets.filter { $0.value !== socket }
        }
        lock.unlock()
    }

    /// 制御接続がこの秒数以上生きていたら「確立済み」とみなし、切断時にバックオフを戻す。
    /// heartbeat 周期 15 秒 + pong deadline 10 秒（= ping 不達で切れるまで約 25 秒）より長くし、
    /// 接続直後に close される relay で密な再接続ループにならないようにする。
    private static let controlHealthyUptime: TimeInterval = 60

    private func runControlLoop(generation run: UUID) async {
        var attempt = 0
        while !Task.isCancelled, isCurrent(run) {
            let connectedAt = Date()
            do {
                try await runControlConnection(generation: run)
                attempt = 0
            } catch is CancellationError {
                return
            } catch {
                // runControlConnection は receive の throw でしか抜けないため、長時間健全だった接続の
                // 切断でも attempt が溜まり続け、5 回目以降は毎回 30 秒待たされていた。
                if Date().timeIntervalSince(connectedAt) >= Self.controlHealthyUptime { attempt = 0 }
                attempt += 1
                WebSocketServer.wslog("Paseo relay control disconnected: \(error)")
            }
            guard !Task.isCancelled, isCurrent(run) else { return }
            let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func runControlConnection(generation run: UUID) async throws {
        guard let url = relayURL(role: "server", connectionId: nil) else {
            throw TunnelError.invalidRelayURL
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = 1_048_576
        let socketID = try track(socket, generation: run)
        socket.resume()
        let heartbeat = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                let deadline = Task {
                    do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                    catch { return }
                    socket.cancel(with: .goingAway, reason: nil)
                }
                do {
                    try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                        // pong ハンドラは deadline で socket を cancel した時などに二重に呼ばれることがある
                        // （実測: 2026-09-23 に resume 二重で SIGTRAP ×3）。一回だけ resume する。
                        let lock = NSLock()
                        var done = false
                        socket.sendPing { error in
                            lock.lock(); defer { lock.unlock() }
                            guard !done else { return }
                            done = true
                            if let error { waiter.resume(throwing: error) }
                            else { waiter.resume() }
                        }
                    }
                    deadline.cancel()
                } catch {
                    deadline.cancel()
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer { heartbeat.cancel(); untrack(socketID) }
        WebSocketServer.wslog("Paseo relay control connecting: serverId=\(serverId.prefix(8))…")
        defer { socket.cancel(with: .goingAway, reason: nil) }

        while !Task.isCancelled, isCurrent(run) {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let event = try? JSONDecoder().decode(ControlEvent.self, from: data) else {
                continue
            }
            switch event.type {
            case "connected":
                if let id = event.connectionId { startDataConnection(id: id, generation: run) }
            case "disconnected":
                if let id = event.connectionId { cancelDataConnection(id: id) }
            case "sync":
                for id in event.connectionIds ?? [] { startDataConnection(id: id, generation: run) }
            default:
                break
            }
        }
    }

    private func startDataConnection(id: String, generation run: UUID) {
        lock.lock()
        guard dataTasks[id] == nil, generation == run else {
            lock.unlock()
            return
        }
        let task = Task { [weak self] in
            defer { self?.removeDataConnection(id: id, generation: run) }
            do {
                try await self?.runDataConnection(id: id, generation: run)
            } catch is CancellationError {
                return
            } catch {
                WebSocketServer.wslog("Paseo tunnel \(id.prefix(8)) closed: \(error)")
            }
        }
        dataTasks[id] = task
        lock.unlock()
    }

    private func cancelDataConnection(id: String) {
        lock.lock()
        let task = dataTasks.removeValue(forKey: id)
        let socket = dataSockets.removeValue(forKey: id)
        lock.unlock()
        socket?.cancel(with: .goingAway, reason: nil)
        task?.cancel()
    }

    private func removeDataConnection(id: String, generation run: UUID) {
        lock.lock()
        if generation == run { dataTasks.removeValue(forKey: id) }
        connectionDevices.removeValue(forKey: id)
        lock.unlock()
        preAuth.leave(id)
        pairing.release(id)
    }

    // MARK: - 枠（§12）

    /// 認証前の枠に入れる。満ちていたら一番古い認証前の接続を閉じてから入れる。
    private func admitPreAuth(_ id: String) {
        if let evicted = preAuth.admit(id) { cancelDataConnection(id: evicted) }
    }

    private func leavePreAuth(_ id: String) { preAuth.leave(id) }

    private func acquirePairing(_ id: String, deviceKeyId: String) -> Bool {
        pairing.acquire(id, deviceKeyId: deviceKeyId)
    }

    private func setDevice(_ id: String, _ deviceKeyId: String) {
        lock.withLock { connectionDevices[id] = deviceKeyId }
    }

    // MARK: - データ用の接続

    private func runDataConnection(id: String, generation run: UUID) async throws {
        guard isCurrent(run),
              let url = relayURL(role: "server", connectionId: id) else {
            throw TunnelError.invalidRelayURL
        }
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = E2ECrypto.maxFramePayload + 64
        let socketID = try track(socket, generation: run, connectionID: id)
        defer { untrack(socketID) }
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        admitPreAuth(id)

        let transport = URLSessionTunnelTransport(socket: socket)
        let session = TunnelSession(
            connectionId: id, transport: transport, environment: .live(localPort: listenPort),
            hooks: TunnelSession.Hooks(
                leavePreAuth: { [weak self] in self?.leavePreAuth(id) },
                acquirePairing: { [weak self] key in self?.acquirePairing(id, deviceKeyId: key) ?? false },
                setDevice: { [weak self] key in self?.setDevice(id, key) },
                closeConnection: { [weak self] other in self?.cancelDataConnection(id: other) },
                handshakeFailed: { [weak self] in self?.failures.note() }
            )
        )
        try await session.run()
    }

    private func relayURL(role: String, connectionId: String?) -> URL? {
        guard var components = URLComponents(string: relayURLString) else { return nil }
        var items = components.queryItems ?? []
        // v=2 は Paseo の中継の版（トンネルの v3 とは関係ない。§7.1）。
        items.append(URLQueryItem(name: "v", value: "2"))
        items.append(URLQueryItem(name: "role", value: role))
        items.append(URLQueryItem(name: "serverId", value: serverId))
        if let connectionId {
            items.append(URLQueryItem(name: "connectionId", value: connectionId))
        }
        components.queryItems = items
        return components.url
    }

    private func isCurrent(_ run: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == run
    }
}

/// 認証前の枠（開いてから最初のバイナリが開けるまで。§12）。満ちていたら一番古い接続を返す（呼び出し側が閉じる）。
final class PreAuthSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int = PaseoRelayTunnelService.Limits.preAuthSlots) { self.capacity = capacity }

    func admit(_ id: String) -> String? {
        lock.withLock {
            var evicted: String?
            if order.count >= capacity { evicted = order.removeFirst() }
            order.append(id)
            return evicted
        }
    }
    func leave(_ id: String) { lock.withLock { order.removeAll { $0 == id } } }
    func clear() { lock.withLock { order.removeAll() } }
    var count: Int { lock.withLock { order.count } }
}

/// ペアリングの枠（pair・approve。同時に 4 本・同じ deviceKeyId は 1 本だけ）。取れなければ msg2 で busy。
final class PairingSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [String: String] = [:]
    let capacity: Int

    init(capacity: Int = PaseoRelayTunnelService.Limits.pairingSlots) { self.capacity = capacity }

    func acquire(_ id: String, deviceKeyId: String) -> Bool {
        lock.withLock {
            guard slots.count < capacity, !slots.values.contains(deviceKeyId) else { return false }
            slots[id] = deviceKeyId
            return true
        }
    }
    func release(_ id: String) { lock.withLock { _ = slots.removeValue(forKey: id) } }
    func clear() { lock.withLock { slots.removeAll() } }
}

/// 握手の失敗は数えるだけ（1 分に 1 回まとめてログに出す）。受け付けを止める仕組みは持たない（§12）。
final class HandshakeFailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var since = Date()

    func note() {
        let line: String? = lock.withLock {
            count += 1
            guard Date().timeIntervalSince(since) >= 60 else { return nil }
            let text = "Paseo tunnel: \(count) handshake failure(s) in the last minute"
            count = 0
            since = Date()
            return text
        }
        if let line { WebSocketServer.wslog(line) }
    }
}

// MARK: - 中継との 1 本の WebSocket（テストでは差し替える）

enum TunnelMessage: Equatable {
    case text(String)
    case binary(Data)
}

protocol TunnelTransport: AnyObject, Sendable {
    func receive() async throws -> TunnelMessage
    func send(_ message: TunnelMessage) async throws
    /// 送り順を守るため、呼んだ順に送り始める（完了は待たない）。
    func sendOrdered(_ message: TunnelMessage, completion: @escaping @Sendable (Error?) -> Void)
    func close(normal: Bool)
}

final class URLSessionTunnelTransport: TunnelTransport, @unchecked Sendable {
    private let socket: URLSessionWebSocketTask
    init(socket: URLSessionWebSocketTask) { self.socket = socket }

    func receive() async throws -> TunnelMessage {
        switch try await socket.receive() {
        case .string(let s): return .text(s)
        case .data(let d): return .binary(d)
        @unknown default: throw PaseoRelayTunnelService.TunnelError.invalidHandshake
        }
    }
    func send(_ message: TunnelMessage) async throws {
        switch message {
        case .text(let s): try await socket.send(.string(s))
        case .binary(let d): try await socket.send(.data(d))
        }
    }
    func sendOrdered(_ message: TunnelMessage, completion: @escaping @Sendable (Error?) -> Void) {
        switch message {
        case .text(let s): socket.send(.string(s), completionHandler: completion)
        case .binary(let d): socket.send(.data(d), completionHandler: completion)
        }
    }
    func close(normal: Bool) {
        socket.cancel(with: normal ? .normalClosure : .goingAway, reason: nil)
    }
}

/// v3 のフレームを順番どおりに送る（seq の採番と送り始めを 1 つの lock の中で行う）。
final class TunnelFrameWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let sender: E2EFrameSender
    private let transport: TunnelTransport

    init(key: Data, transport: TunnelTransport) {
        self.sender = E2EFrameSender(key: key, version: E2ECrypto.frameVersionV3)
        self.transport = transport
    }

    func send(_ plaintext: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            let frame: Data
            do { frame = try sender.seal(plaintext) } catch {
                lock.unlock()
                cont.resume(throwing: error)
                return
            }
            TrafficMeter.shared.record("paseo.out", bytes: frame.count)
            transport.sendOrdered(.binary(frame)) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            lock.unlock()
        }
    }
}

// MARK: - 1 本のデータ用の接続の手順（§10）

/// connect / pair / approve の手順。中継の WebSocket（TunnelTransport）と、DeviceStore などの入れ物を受け取る。
final class TunnelSession: @unchecked Sendable {
    struct Environment {
        var devices: DeviceStore
        var invites: PairingInvites
        var approvals: ApprovalQueue
        var peers: TunnelPeers
        var staticKey: () -> Data?
        var bridge: () -> TunnelV3.PairedBridge
        var localPort: Int
        /// 自分で作る一時鍵・乱数（テストでは固定値）。
        var ephemeralKey: () -> Data? = { nil }
        var random32: () throws -> Data = { try TunnelV3.randomBytes(32) }
        var timeScale: Double = 1
        /// remote の承認待ちを作ったときに、許可できる端末へ pair_request の push を送る（§10.4.1）。
        var notifyApprovers: @Sendable (_ pendingId: String, _ requester: String) -> Void = { _, _ in }

        static func live(localPort: Int) -> Environment {
            Environment(
                devices: .shared, invites: .shared, approvals: .shared, peers: .shared,
                staticKey: { KeyStore.e2eKey() },
                bridge: { BridgeIdentityInfo.paired() },
                localPort: localPort,
                notifyApprovers: { pendingId, requester in
                    Task {
                        await PushService.shared.sendPairRequest(pendingId: pendingId, requester: requester,
                                                                 bridgeName: BridgeIdentityInfo.machineName)
                    }
                }
            )
        }
    }

    struct Hooks {
        var leavePreAuth: @Sendable () -> Void = {}
        var acquirePairing: @Sendable (String) -> Bool = { _ in true }
        var setDevice: @Sendable (String) -> Void = { _ in }
        var closeConnection: @Sendable (String) -> Void = { _ in }
        var handshakeFailed: @Sendable () -> Void = {}
    }

    typealias Limits = PaseoRelayTunnelService.Limits
    typealias TunnelError = PaseoRelayTunnelService.TunnelError

    let connectionId: String
    let transport: TunnelTransport
    let env: Environment
    let hooks: Hooks

    init(connectionId: String, transport: TunnelTransport, environment: Environment, hooks: Hooks = Hooks()) {
        self.connectionId = connectionId
        self.transport = transport
        self.env = environment
        self.hooks = hooks
    }

    private func seconds(_ s: Double) -> Double { s * env.timeScale }

    func run() async throws {
        // msg1 を 5 秒待つ（来なければ閉じる。§12）。
        let m1 = try await withTimeout(seconds(Limits.msg1Timeout)) { try await self.receiveMessage1() }
        guard let staticKey = env.staticKey() else { throw TunnelError.keyUnavailable }
        var responder = try TunnelV3.Responder(staticPriv: staticKey, ephemeralPriv: env.ephemeralKey())
        let devicePub: Data
        let payload1Data: Data
        do {
            (devicePub, payload1Data) = try responder.readMessage1(e: m1.e, s: m1.s, p: m1.p)
        } catch {
            hooks.handshakeFailed()
            try? await transport.send(.text(TunnelV3.errorText(.badMessage)))
            throw TunnelError.invalidHandshake
        }
        let deviceKeyId = TunnelV3.deviceKeyId(devicePub: devicePub)
        // msg1 を読んだときの epoch。pair_confirm・番号の一致・paired_ack・open で lock の中で照らし合わせる。
        let epoch = env.devices.epoch
        guard let p1 = TunnelV3.Payload1.parse(payload1Data) else {
            try await refuseMalformed(&responder, payload1Data, deviceKeyId: deviceKeyId)
            return
        }
        switch p1.mode {
        case .connect:
            try await runConnect(&responder, p1: p1, deviceKeyId: deviceKeyId, epoch: epoch)
        case .pair:
            hooks.setDevice(deviceKeyId)
            try await runPair(&responder, p1: p1, devicePub: devicePub, deviceKeyId: deviceKeyId, epoch: epoch)
        case .approve:
            hooks.setDevice(deviceKeyId)
            try await runApprove(&responder, p1: p1, devicePub: devicePub, deviceKeyId: deviceKeyId, epoch: epoch)
        }
    }

    // MARK: msg1・msg2

    /// 最初に正しく読めた msg1 だけを使う。init でない TEXT は読み捨て、v が 3 でなければ version を返して閉じる。
    private func receiveMessage1() async throws -> TunnelV3.Message1 {
        while true {
            switch try await transport.receive() {
            case .binary:
                throw TunnelError.invalidHandshake
            case .text(let text):
                guard text.utf8.count <= TunnelV3.maxControlBytes else { throw TunnelError.invalidHandshake }
                do {
                    return try TunnelV3.Message1.parse(text)
                } catch TunnelV3.Message1.ParseError.notInit {
                    continue
                } catch TunnelV3.Message1.ParseError.version {
                    try? await transport.send(.text(TunnelV3.errorText(.version)))
                    throw TunnelError.refused
                } catch {
                    hooks.handshakeFailed()
                    try? await transport.send(.text(TunnelV3.errorText(.badMessage)))
                    throw TunnelError.invalidHandshake
                }
            }
        }
    }

    private struct Keys {
        let c2s: Data
        let s2c: Data
        let hash: Data
    }

    private func sendHello(_ responder: inout TunnelV3.Responder, payload: Data, psk: Data) async throws -> Keys {
        let w = try responder.writeMessage2(payload: payload, psk: psk)
        try await transport.send(.text(TunnelV3.helloText(e: w.e, p: w.p)))
        return Keys(c2s: w.c2s, s2c: w.s2c, hash: w.hash)
    }

    /// 形の違う payload1 への返事（spec/PROTOCOL-v3.md §8.10）。pair なら、招待が使えればその psk で `bad_request`
    /// （端末が読める）、使えなければ平文の `invite_invalid`。それ以外の mode はゼロの psk で `bad_request`。
    private func refuseMalformed(_ responder: inout TunnelV3.Responder, _ payload1: Data, deviceKeyId: String) async throws {
        guard let pairInvite = TunnelV3.Payload1.pairInviteOfMalformed(payload1) else {
            return try await refuse(&responder, .badRequest, psk: TunnelV3.zeroPsk)
        }
        guard let inviteId = pairInvite, let psk = env.invites.psk(inviteId: inviteId, deviceKeyId: deviceKeyId) else {
            try? await transport.send(.text(TunnelV3.errorText(.inviteInvalid)))
            transport.close(normal: true)
            return
        }
        try await refuse(&responder, .badRequest, psk: psk)
    }

    /// msg2（ok=false）で断って閉じる。
    private func refuse(_ responder: inout TunnelV3.Responder, _ error: TunnelV3.Refusal, psk: Data) async throws {
        _ = try await sendHello(&responder, payload: TunnelV3.payload2Refusal(error), psk: psk)
        transport.close(normal: true)
    }

    /// msg2 の後、最初のバイナリが届くまでの TEXT は読み捨てる（msg1 の再送など）。
    private func receiveFirstBinary() async throws -> Data {
        while true {
            switch try await transport.receive() {
            case .binary(let d): return d
            case .text(let t):
                guard t.utf8.count <= TunnelV3.maxControlBytes else { throw TunnelError.invalidHandshake }
                continue
            }
        }
    }

    /// 最初のバイナリの後は、両方向ともバイナリだけ（TEXT が来たら閉じる）。
    private func receiveFrame(_ receiver: E2EFrameReceiver) async throws -> Data {
        switch try await transport.receive() {
        case .binary(let d):
            TrafficMeter.shared.record("paseo.in", bytes: d.count)
            return try receiver.open(d)
        case .text:
            throw TunnelError.invalidHandshake
        }
    }

    private func bridgePayload2(deviceKeyId: String, commit: Data? = nil) -> Data {
        let b = env.bridge()
        return TunnelV3.payload2OK(bridgeId: b.bridgeId, name: b.name, platform: b.platform, deviceKeyId: deviceKeyId, commit: commit)
    }

    // MARK: connect

    private func runConnect(_ responder: inout TunnelV3.Responder, p1: TunnelV3.Payload1, deviceKeyId: String, epoch: Int) async throws {
        switch env.devices.connectDecision(deviceKeyId: deviceKeyId, clientDeviceId: p1.deviceId) {
        case .unknown:
            WebSocketServer.wslog("Paseo tunnel \(connectionId.prefix(8)): unknown device \(deviceKeyId.prefix(8))")
            return try await refuse(&responder, .unknownDevice, psk: TunnelV3.zeroPsk)
        case .revoked:
            return try await refuse(&responder, .revoked, psk: TunnelV3.zeroPsk)
        case .broken:
            return try await refuse(&responder, .bridgeError, psk: TunnelV3.zeroPsk)
        case .ok:
            break
        }
        let keys = try await sendHello(&responder, payload: bridgePayload2(deviceKeyId: deviceKeyId), psk: TunnelV3.zeroPsk)
        let receiver = E2EFrameReceiver(key: keys.c2s, version: E2ECrypto.frameVersionV3)
        let writer = TunnelFrameWriter(key: keys.s2c, transport: transport)
        let first = try await withTimeout(seconds(Limits.firstBinaryTimeout)) { try await self.receiveFirstBinary() }
        guard let opened = try? receiver.open(first), TunnelV3.Control.parse(opened) == .open else {
            hooks.handshakeFailed()
            throw TunnelError.invalidHandshake
        }
        // ここで初めて相手を信じる（§10.1 の共通の規則）。認証前の枠から認証済みの枠へ。
        hooks.leavePreAuth()
        guard env.peers.reserve(connectionId: connectionId, deviceKeyId: deviceKeyId) else {
            WebSocketServer.wslog("Paseo tunnel \(connectionId.prefix(8)): connection limit reached")
            throw TunnelError.refused
        }
        defer { env.peers.release(connectionId: connectionId) }
        hooks.setDevice(deviceKeyId)
        guard env.devices.isLive(deviceKeyId: deviceKeyId, epoch: epoch) else { throw TunnelError.refused }

        let local = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: UInt16(env.localPort))!,
            using: .tcp
        )
        // TunnelPeers から外すのはローカルの TCP を閉じる前（defer は後に書いたものが先に走る）。
        defer { local.cancel() }
        try await withTimeout(seconds(Limits.localConnectTimeout), onTimeout: { local.cancel() }) {
            try await local.startAndWait()
        }
        guard let localPortNumber = Self.acceptablePeerPort(local: local.currentPath?.localEndpoint,
                                                            remote: local.currentPath?.remoteEndpoint,
                                                            listenPort: env.localPort) else {
            WebSocketServer.wslog("Paseo tunnel \(connectionId.prefix(8)): local endpoint check failed")
            throw TunnelError.localConnectionFailed
        }
        let peer = TunnelPeers.Peer(deviceKeyId: deviceKeyId, connectionId: connectionId)
        if let old = env.peers.register(localPort: localPortNumber, peer: peer) {
            hooks.closeConnection(old.connectionId)
        }
        defer { env.peers.remove(localPort: localPortNumber, connectionId: connectionId) }
        // 入れた後にもう一度、行がまだあるかを確かめてから流し始める（§10.2 の 4）。
        guard env.devices.isLive(deviceKeyId: deviceKeyId, epoch: epoch) else { throw TunnelError.refused }
        env.devices.touch(deviceKeyId: deviceKeyId)
        WebSocketServer.wslog("Paseo tunnel \(connectionId.prefix(8)) opened for \(deviceKeyId.prefix(8))")

        let transport = self.transport
        let peers = env.peers
        let connectionId = self.connectionId
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Cancel the underlying I/O before the group waits for its other child.
            // Task cancellation alone cannot wake a pending Network receive callback.
            // TunnelPeers から外すのはローカルの TCP を閉じる前（§13.1。外した後の番号が「この PC の中から」に見えないように）。
            defer {
                group.cancelAll()
                peers.remove(localPort: localPortNumber, connectionId: connectionId)
                transport.close(normal: false)
                local.cancel()
            }
            group.addTask {
                while !Task.isCancelled {
                    let plaintext = try await self.receiveFrame(receiver)
                    try await local.sendAsync(plaintext)
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    let chunk = try await local.receiveAsync()
                    try await writer.send(chunk)
                }
            }
            _ = try await group.next()
        }
    }

    /// §13.1 の条件: ローカル側の番号が取れる・ローカル側の住所が IPv4 の 127.0.0.1・つないだ先が待ち受けの番号。
    /// どれかが外れたら nil（流さずに閉じる。通すと、その要求が「この PC の中から」に見えるため）。
    static func acceptablePeerPort(local: NWEndpoint?, remote: NWEndpoint?, listenPort: Int) -> UInt16? {
        guard case .hostPort(let lhost, let lport)? = local,
              case .ipv4(let addr) = lhost, addr == IPv4Address.loopback,
              case .hostPort(_, let rport)? = remote, Int(rport.rawValue) == listenPort,
              lport.rawValue != 0 else { return nil }
        return lport.rawValue
    }

    // MARK: pair

    private func runPair(_ responder: inout TunnelV3.Responder, p1: TunnelV3.Payload1, devicePub: Data,
                         deviceKeyId: String, epoch: Int) async throws {
        guard let inviteId = p1.invite, let psk = env.invites.psk(inviteId: inviteId, deviceKeyId: deviceKeyId) else {
            // psk が分からないので msg2 は送れない。平文のエラーで知らせて閉じる（§8.9）。
            try? await transport.send(.text(TunnelV3.errorText(.inviteInvalid)))
            transport.close(normal: true)
            return
        }
        if env.devices.isBroken { return try await refuse(&responder, .bridgeError, psk: psk) }
        if env.devices.isFull(excluding: deviceKeyId) { return try await refuse(&responder, .tooManyDevices, psk: psk) }
        guard hooks.acquirePairing(deviceKeyId) else { return try await refuse(&responder, .busy, psk: psk) }

        let keys = try await sendHello(&responder, payload: bridgePayload2(deviceKeyId: deviceKeyId), psk: psk)
        let receiver = E2EFrameReceiver(key: keys.c2s, version: E2ECrypto.frameVersionV3)
        let writer = TunnelFrameWriter(key: keys.s2c, transport: transport)
        let first = try await withTimeout(seconds(Limits.firstBinaryTimeout)) { try await self.receiveFirstBinary() }
        // 開けない・pair_confirm でない: 閉じる。招待は変えず、回数も数えない（§10.3 の 4）。
        guard let opened = try? receiver.open(first), TunnelV3.Control.parse(opened) == .pairConfirm else {
            throw TunnelError.invalidHandshake
        }
        hooks.leavePreAuth()

        let name = TunnelV3.sanitizeName(p1.name ?? "", fallback: TunnelV3.deviceNameFallback)
        let display = TunnelV3.displayName(name: name, deviceKeyId: deviceKeyId)
        guard env.devices.epoch == epoch,
              env.invites.markUsed(inviteId: inviteId, deviceKeyId: deviceKeyId, display: display) else {
            throw TunnelError.refused
        }
        let credential = try TunnelV3.newCredential()
        let credHash = TunnelV3.credentialHash(credential)
        let row = DeviceStore.Device(
            pub: TunnelV3.b64u(devicePub), clientDeviceId: p1.deviceId, name: name,
            label: env.devices.device(deviceKeyId)?.label, platform: p1.platform, credHash: credHash,
            via: "qr", createdAt: DeviceStore.nowMs(), lastSeenAt: nil, push: nil
        )
        guard env.devices.insertPending(deviceKeyId: deviceKeyId, device: row, epoch: epoch) else {
            try? await writer.send(TunnelV3.pairRejected("reset"))
            throw TunnelError.refused
        }
        var confirmed = false
        defer { if !confirmed { env.devices.removePending(deviceKeyId: deviceKeyId, credHash: credHash) } }
        try await writer.send(TunnelV3.paired(deviceKeyId: deviceKeyId, credential: credential, bridge: env.bridge()))
        // 5 秒以内に paired_ack が来たら確定（§10.3 の 6）。
        let ack = try await withTimeout(seconds(Limits.pairAckTimeout)) { try await self.receiveFrame(receiver) }
        guard TunnelV3.Control.parse(ack) == .pairedAck,
              env.devices.confirmPending(deviceKeyId: deviceKeyId, credHash: credHash, epoch: epoch) else {
            throw TunnelError.refused
        }
        confirmed = true
        WebSocketServer.wslog("Paseo tunnel: paired \(deviceKeyId.prefix(8)) via qr")
        transport.close(normal: true)
    }

    // MARK: approve

    private enum ApproveEvent {
        case frame(Data)
        case closed
        case tick
        case ended(ApprovalQueue.EndReason)
        case pairedSent(credHash: String)
    }

    private func runApprove(_ responder: inout TunnelV3.Responder, p1: TunnelV3.Payload1, devicePub: Data,
                            deviceKeyId: String, epoch: Int) async throws {
        let zero = TunnelV3.zeroPsk
        // 状態を変えずに受け付けられるかを確かめる（§10.4 の 1。§10.4.1 のスマホでの許可を含む）。
        // 窓が閉じていても、スマホでの許可が使えるなら remote の申し込みとして受け付ける。
        let remoteAvailable = env.devices.remoteApprovalsEnabled && env.devices.hasApproverWithPush
        let admission = env.approvals.admit(deviceKeyId: deviceKeyId, approvalsEnabled: env.devices.approvalsEnabled,
                                            remoteAvailable: remoteAvailable)
        if admission == .refused(.approvalUnavailable) { return try await refuse(&responder, .approvalUnavailable, psk: zero) }
        if env.devices.isRevoked(deviceKeyId) { return try await refuse(&responder, .revoked, psk: zero) }
        if case .refused(let pre) = admission { return try await refuse(&responder, pre, psk: zero) }
        let remote = admission == .remote
        if env.devices.isFull(excluding: deviceKeyId) { return try await refuse(&responder, .tooManyDevices, psk: zero) }
        if env.devices.isBroken { return try await refuse(&responder, .bridgeError, psk: zero) }
        guard hooks.acquirePairing(deviceKeyId) else { return try await refuse(&responder, .busy, psk: zero) }

        let nR = try env.random32()
        let keys = try await sendHello(&responder, payload: bridgePayload2(deviceKeyId: deviceKeyId, commit: TunnelV3.sasCommit(nR: nR)), psk: zero)
        let receiver = E2EFrameReceiver(key: keys.c2s, version: E2ECrypto.frameVersionV3)
        let writer = TunnelFrameWriter(key: keys.s2c, transport: transport)
        let first = try await withTimeout(seconds(Limits.firstBinaryTimeout)) { try await self.receiveFirstBinary() }
        guard let opened = try? receiver.open(first), case .approveNonce(let nD)? = TunnelV3.Control.parse(opened) else {
            throw TunnelError.invalidHandshake
        }
        hooks.leavePreAuth()
        // ここで回数を数える（msg1 だけでは数えない。§18.2 の 10）。
        guard env.approvals.countAttempt(deviceKeyId: deviceKeyId, remote: remote) else {
            try? await writer.send(TunnelV3.pairRejected("rate_limited"))
            transport.close(normal: true)
            return
        }
        let code = TunnelV3.sasCode(handshakeHash: keys.hash, nI: nD, nR: nR)
        let name = TunnelV3.sanitizeName(p1.name ?? "", fallback: TunnelV3.deviceNameFallback)
        let display = TunnelV3.displayName(name: name, deviceKeyId: deviceKeyId)

        let (events, sink) = AsyncStream.makeStream(of: ApproveEvent.self)
        let closedFlag = ClosedFlag()
        let transport = self.transport
        let devices = env.devices
        let bridge = env.bridge
        let deviceRow = DeviceStore.Device(
            pub: TunnelV3.b64u(devicePub), clientDeviceId: p1.deviceId, name: name,
            label: devices.device(deviceKeyId)?.label, platform: p1.platform, credHash: "",
            via: "approval", createdAt: DeviceStore.nowMs(), lastSeenAt: nil, push: nil
        )
        // PC かスマホで番号が合ったとき（§10.4）。この端末のトンネルがまだ開いていることを確かめる。
        // スマホで入力したときは、その端末の deviceKeyId を行に残す（§10.4.1 の approvedBy）。
        let approve: @Sendable (String?) async -> ApprovalQueue.ApproveOutcome = { approvedBy in
            guard !closedFlag.isClosed, let credential = try? TunnelV3.newCredential() else { return .deviceGone }
            let credHash = TunnelV3.credentialHash(credential)
            var row = deviceRow
            row.credHash = credHash
            row.approvedBy = approvedBy
            guard devices.insertPending(deviceKeyId: deviceKeyId, device: row, epoch: epoch) else { return .deviceGone }
            // `paired` を送る前に知らせる。送り終わりの通知より先に端末の paired_ack が届いても、
            // 承認待ちの間の知らないフレームとして閉じてしまわないように（届く順は AsyncStream が守る）。
            sink.yield(.pairedSent(credHash: credHash))
            do {
                guard !closedFlag.isClosed else { throw PaseoRelayTunnelService.TunnelError.connectionClosed }
                try await writer.send(TunnelV3.paired(deviceKeyId: deviceKeyId, credential: credential, bridge: bridge()))
            } catch {
                devices.removePending(deviceKeyId: deviceKeyId, credHash: credHash)
                transport.close(normal: false)
                return .deviceGone
            }
            // 送っている間にトンネルが閉じていたら、仮の行を残さない（その間に paired_ack で確定していれば、そのまま）。
            if closedFlag.isClosed,
               !(devices.state(deviceKeyId) == nil && devices.device(deviceKeyId)?.credHash == credHash) {
                devices.removePending(deviceKeyId: deviceKeyId, credHash: credHash)
                return .deviceGone
            }
            return .ok(display: display)
        }
        guard let pending = env.approvals.add(
            deviceKeyId: deviceKeyId, display: display, name: name, platform: p1.platform,
            sameNameExists: devices.sameNameCount(name) > 0, remote: remote, code: code,
            approve: approve, end: { reason in sink.yield(.ended(reason)) }
        ) else {
            try? await writer.send(TunnelV3.pairRejected("busy"))
            transport.close(normal: true)
            return
        }
        var pairedCredHash: String?
        var finished = false
        defer {
            closedFlag.close()
            env.approvals.remove(pendingId: pending.pendingId)
            if !finished, let h = pairedCredHash { devices.removePending(deviceKeyId: deviceKeyId, credHash: h) }
        }
        try await writer.send(TunnelV3.approveReveal(nR: nR))
        // remote の申し込みだけ、許可できる端末に知らせる（窓が開いているときは PC の前に人がいるので送らない）。
        if remote {
            WebSocketServer.wslog("Paseo tunnel: remote approval pending for \(deviceKeyId.prefix(8))")
            env.notifyApprovers(pending.pendingId, display)
        }

        let reader = Task {
            do {
                while !Task.isCancelled { sink.yield(.frame(try await self.receiveFrame(receiver))) }
            } catch {
                sink.yield(.closed)
            }
        }
        let tickInterval = seconds(Limits.approvalKeepalive)
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tickInterval * 1_000_000_000))
                if Task.isCancelled { return }
                sink.yield(.tick)
            }
        }
        // paired_ack を待つ 60 秒（§12）。keepalive の 20 秒の刻みを待たずに、ちょうどの時刻に確かめる。
        var ackTimer: Task<Void, Never>?
        defer {
            reader.cancel()
            ticker.cancel()
            ackTimer?.cancel()
            sink.finish()
        }
        let pendingDeadline = Date().addingTimeInterval(seconds(Double(ApprovalQueue.pendingLifetimeMs) / 1000))
        var ackDeadline: Date?

        for await event in events {
            switch event {
            case .tick:
                if let ackDeadline {
                    if Date() >= ackDeadline { break }
                } else if Date() >= pendingDeadline {
                    env.approvals.remove(pendingId: pending.pendingId)
                    try? await writer.send(TunnelV3.pairRejected(ApprovalQueue.EndReason.timeout.rawValue))
                    transport.close(normal: true)
                    return
                }
                try? await writer.send(TunnelV3.approvalWaiting)
                continue
            case .ended(let reason):
                guard pairedCredHash == nil else { continue }
                try? await writer.send(TunnelV3.pairRejected(reason.rawValue))
                transport.close(normal: true)
                return
            case .pairedSent(let credHash):
                pairedCredHash = credHash
                let wait = seconds(Limits.approveAckTimeout)
                ackDeadline = Date().addingTimeInterval(wait)
                ackTimer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 1_000_000)
                    if !Task.isCancelled { sink.yield(.tick) }
                }
                continue
            case .closed:
                return
            case .frame(let pt):
                let control = TunnelV3.Control.parse(pt)
                if let credHash = pairedCredHash {
                    // paired の後: paired_ack（確定）か pair_cancel（取り消し）。
                    if control == .pairedAck, devices.confirmPending(deviceKeyId: deviceKeyId, credHash: credHash, epoch: epoch) {
                        finished = true
                        WebSocketServer.wslog("Paseo tunnel: paired \(deviceKeyId.prefix(8)) via approval")
                    }
                    transport.close(normal: finished)
                    return
                }
                // 承認待ちの間に来てよいのは pair_cancel だけ。
                transport.close(normal: control == .pairCancel)
                return
            }
            // ackDeadline を過ぎた（.tick から break で来る）。
            if let ackDeadline, Date() >= ackDeadline {
                transport.close(normal: false)
                return
            }
        }
    }

    /// トンネルが閉じたか（承認の HTTP から見る）。
    private final class ClosedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        var isClosed: Bool { lock.withLock { closed } }
        func close() { lock.withLock { closed = true } }
    }

    // MARK: timeout

    /// `operation` を `seconds` 秒だけ待つ。時間切れなら `onTimeout`（既定は中継の接続を閉じる）を呼んで投げる。
    /// URLSession の receive や NWConnection の待ちは Task の cancel では起きないので、I/O を閉じて起こす。
    private func withTimeout<T: Sendable>(_ seconds: Double, onTimeout: (@Sendable () -> Void)? = nil,
                                          _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let transport = self.transport
        let fire: @Sendable () -> Void = onTimeout ?? { transport.close(normal: false) }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw TunnelError.timeout }
                if let value = first { return value }
            } catch {
                // 外から cancel された（端末を外した・中継が切れた）。待っている I/O も閉じる。
                fire()
                throw error
            }
            fire()
            throw TunnelError.timeout
        }
    }
}

/// payload2 と `paired.bridge` に載せる、この Bridge の値。
enum BridgeIdentityInfo {
    /// PC の名前（§5.3 で無害化。Host.current() は遅いことがあるので 1 回だけ引く）。
    static let machineName: String = TunnelV3.sanitizeName(
        Host.current().localizedName ?? "Mac", fallback: TunnelV3.bridgeNameFallback)

    static func paired() -> TunnelV3.PairedBridge {
        TunnelV3.PairedBridge(
            bridgeId: KeyStore.loadOrCreateBridgeId(),
            name: machineName,
            platform: "mac",
            relayId: KeyStore.loadOrCreatePaseoRelayId(),
            relayURL: PaseoRelayTunnelService.shared.relayURLString
        )
    }
}

extension NWConnection {
    /// `.ready` まで待つ。`.waiting` は失敗として扱う（つながらないまま待ち続けない）。
    /// 呼んだ Task が cancel されたら接続も閉じる。
    func startAndWait() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = NSLock()
                var done = false
                stateUpdateHandler = { [weak self] state in
                    resumed.lock()
                    defer { resumed.unlock() }
                    guard !done else { return }
                    switch state {
                    case .ready:
                        done = true
                        continuation.resume()
                    case .failed(let error):
                        done = true
                        continuation.resume(throwing: error)
                    case .waiting(let error):
                        done = true
                        self?.cancel()
                        continuation.resume(throwing: error)
                    case .cancelled:
                        done = true
                        continuation.resume(throwing: PaseoRelayTunnelService.TunnelError.connectionClosed)
                    default:
                        break
                    }
                }
                start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            self.cancel()
        }
    }

    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receiveAsync() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error); return }
                if let data, !data.isEmpty { continuation.resume(returning: data); return }
                if complete { continuation.resume(throwing: PaseoRelayTunnelService.TunnelError.connectionClosed); return }
                continuation.resume(throwing: PaseoRelayTunnelService.TunnelError.connectionClosed)
            }
        }
    }
}
