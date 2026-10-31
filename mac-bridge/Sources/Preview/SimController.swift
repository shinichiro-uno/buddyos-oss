import Foundation

/// One booted iOS simulator as reported by `xcrun simctl list devices booted`.
struct SimDevice: Sendable {
    let udid: String
    let name: String
}

/// Owns all simulator interaction for the Live Preview feature:
///   - `SimFramebuffer`（CoreSimulator の描画面を直接読む）で画面を取る。取れない環境では `xcrun simctl` の screenshot
///   - `xcrun simctl` for enumeration
///   - `SimHID`（SimulatorKit へ HID のメッセージを直接送る）で tap / swipe / home / text
///   - `sips -Z` downscaling
///
/// A single shared instance runs at most one capture loop per booted udid.
/// Loops are ref-counted by active MJPEG stream subscribers and torn down
/// when the last subscriber goes away (mirrors simstream.mjs's EventEmitter bus).
///
/// All `Process` calls are blocking, so they are dispatched off the Vapor
/// event loop onto a global queue and bridged back to async — calling them
/// directly on the event loop would stall the whole bridge.
actor SimController {
    static let shared = SimController()

    /// 送る画像の長辺（px）。0 なら縮めない。(env SCALE_W, default 1000)
    /// 3 倍の画面で拡大してもぼやけにくく、リレー越しでも重すぎない大きさ（JPEG で 1 枚 70KB 前後）。
    private static let scaleW: Int = {
        if let v = ProcessInfo.processInfo.environment["SCALE_W"], let n = Int(v) { return n }
        return 1000
    }()

    /// 描画面から取るときの上限 fps。画面が変わらない間は送らないので、静止画面では帯域を使わない。(env SIM_FPS, default 24)
    private static let fps: Int = {
        if let v = ProcessInfo.processInfo.environment["SIM_FPS"], let n = Int(v), n > 0 { return min(n, 60) }
        return 24
    }()
    private static let jpegQuality = 0.6

    // MARK: udid の検証

    /// udid は UUID の形（8-4-4-4-12 の 16 進）だけを受け付け、大文字にそろえて返す。
    /// 一時ファイルのパスや simctl の引数に入るので、"-" で始まる値や "../" を通さない。
    nonisolated static func normalizedUDID(_ raw: String) -> String? {
        guard raw.utf8.count == 36, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString
    }

    // MARK: HID（画面の大きさと入力）

    /// udid ごとの HID のつなぎ口。送れなくなったら（sim の再起動など）捨てて開き直す。
    private var hids: [String: SimHID] = [:]

    private func hid(_ udid: String) async -> SimHID? {
        if let h = hids[udid] { return h }
        let h = await Self.offActor { SimHID.open(udid: udid) }
        if let h { hids[udid] = h }
        return h
    }

    /// 画面の大きさ（ポイント）。取れなければ 390x844。
    func describe(udid raw: String) async -> (wPts: Int, hPts: Int) {
        guard let udid = Self.normalizedUDID(raw), let h = await hid(udid) else { return (390, 844) }
        return (h.points.w, h.points.h)
    }

    // MARK: enumeration

    /// Parse `xcrun simctl list devices booted` for booted UDID + name.
    /// Lines look like:  "    iPhone 16e (71E1E41C-...-...) (Booted)"
    func bootedDevices() async -> [SimDevice] {
        guard let out = await Shell.runAsync(
            "/usr/bin/xcrun", ["simctl", "list", "devices", "booted"], timeout: 5.0
        ) else { return [] }
        var devices: [SimDevice] = []
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.contains("(Booted)") else { continue }
            // name is everything before the last "(<udid>)" group.
            guard let raw = firstCapture(s, pattern: #"\(([0-9A-Fa-f-]{36})\)\s*\(Booted\)"#),
                  let udid = Self.normalizedUDID(raw) else { continue }
            var name = s
            if let r = name.range(of: " (\(raw))") { name = String(name[..<r.lowerBound]) }
            devices.append(SimDevice(udid: udid, name: name.trimmingCharacters(in: .whitespaces)))
        }
        return devices
    }

    // MARK: input injection（座標は画面に対する割合 0〜1）

    func tap(udid: String, x: Double, y: Double) async -> (ok: Bool, err: String) {
        await withHID(udid) { $0.tap(x: x, y: y) }
    }

    func swipe(udid: String, x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) async -> (ok: Bool, err: String) {
        await withHID(udid) { $0.swipe(x1: x1, y1: y1, x2: x2, y2: y2, duration: duration) }
    }

    func home(udid: String) async -> (ok: Bool, err: String) {
        await withHID(udid) { $0.home() }
    }

    /// 文字はキーを 1 つずつ打たず、シミュレータのクリップボードに入れて ⌘V で貼る
    /// （キーで打つと日本語のキーボードのときに「あbc」と変換され、日本語そのものは打てない）。
    /// 改行は Return キーにする。シミュレータのクリップボードは入力した文字に置き換わる。
    func text(udid raw: String, _ value: String) async -> (ok: Bool, err: String) {
        guard let udid = Self.normalizedUDID(raw) else { return (false, "invalid udid") }
        for (i, line) in value.components(separatedBy: "\n").enumerated() {
            if i > 0 {
                let r = await withHID(udid) { $0.key(SimHID.keyReturn) }
                guard r.ok else { return r }
            }
            guard !line.isEmpty else { continue }
            guard await Self.setPasteboard(udid: udid, line) else { return (false, "simctl pbcopy failed") }
            let r = await withHID(udid) { $0.key(SimHID.keyV, modifiers: [SimHID.keyLeftCommand]) }
            guard r.ok else { return r }
        }
        return (true, "")
    }

    /// HID で 1 つ操作する。送れなければつなぎ口を開き直して 1 回だけやり直す（sim を再起動した後など）。
    private func withHID(_ raw: String, _ action: @escaping @Sendable (SimHID) -> Bool) async -> (ok: Bool, err: String) {
        guard let udid = Self.normalizedUDID(raw) else { return (false, "invalid udid") }
        for attempt in 0..<2 {
            guard let h = await hid(udid) else { return (false, "simulator not available (Xcode の SimulatorKit を開けないか、起動していない)") }
            if await Self.offActor({ action(h) }) { return (true, "") }
            hids.removeValue(forKey: udid)
            if attempt == 0 { print("[SimController] HID send failed for \(udid); reopening") }
        }
        return (false, "simulator input failed")
    }

    /// `xcrun simctl pbcopy <udid>` へ文字を渡す（標準入力はファイルから読ませる）。
    private static func setPasteboard(udid: String, _ value: String) async -> Bool {
        let file = NSTemporaryDirectory() + "buddyos-pb-\(UUID().uuidString).txt"
        guard FileManager.default.createFile(atPath: file, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
        defer { try? FileManager.default.removeItem(atPath: file) }
        let r = await Shell.runFull("/bin/sh", ["-c", "exec /usr/bin/xcrun simctl pbcopy \"$1\" < \"$2\"", "sh", udid, file], timeout: 10.0)
        return r.exitCode == 0
    }

    /// 止まる処理（CoreSimulator の呼び出し・HID の送信）を actor の外で行う。
    private static func offActor<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: work()) }
        }
    }

    // MARK: capture loop + frame broadcast (ref-counted per udid)

    private final class Subscriber {
        let id = UUID()
        let continuation: AsyncStream<Data>.Continuation
        init(_ c: AsyncStream<Data>.Continuation) { continuation = c }
    }

    private struct Loop {
        var task: Task<Void, Never>
        var subscribers: [UUID: Subscriber] = [:]
        var latest: Data?
    }

    private var loops: [String: Loop] = [:]

    /// Latest captured (downscaled) JPEG for `udid`, or nil if no frame yet.
    /// Used by iOS "Send screen to agent". If no loop is running, kicks one
    /// transiently and waits briefly for a single frame.
    func latestFrame(udid raw: String) async -> Data? {
        guard let udid = Self.normalizedUDID(raw) else { return nil }
        if let f = loops[udid]?.latest { return f }
        // No active stream — capture one frame on demand.
        return await captureOnce(udid: udid)
    }

    /// Subscribe to the MJPEG frame stream for `udid`. Starts the capture loop
    /// lazily and ref-counts; the loop stops when the last subscriber finishes.
    /// The returned stream yields the latest frame immediately if available.
    /// 送信が遅い回線で未送信フレームが溜まり遅延・メモリが際限なく増えないよう、
    /// バッファは最新 1 フレームだけ保持する（MJPEG は各フレーム独立なので間引いても崩れない）。
    func subscribe(udid raw: String) -> AsyncStream<Data> {
        AsyncStream<Data>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // 形の違う udid では capture loop を起こさない（すぐ終わるストリームを返す）。
            guard let udid = Self.normalizedUDID(raw) else {
                continuation.finish()
                return
            }
            let sub = Subscriber(continuation)
            self.attach(udid: udid, sub: sub)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.detach(udid: udid, subId: sub.id) }
            }
        }
    }

    private func attach(udid: String, sub: Subscriber) {
        if var loop = loops[udid] {
            loop.subscribers[sub.id] = sub
            if let latest = loop.latest { sub.continuation.yield(latest) }
            loops[udid] = loop
        } else {
            let task = Task { [weak self] () -> Void in
                guard let self else { return }
                await self.runCaptureLoop(udid: udid)
            }
            var loop = Loop(task: task)
            loop.subscribers[sub.id] = sub
            loops[udid] = loop
        }
    }

    private func detach(udid: String, subId: UUID) {
        guard var loop = loops[udid] else { return }
        loop.subscribers.removeValue(forKey: subId)
        if loop.subscribers.isEmpty {
            loop.task.cancel()
            loops.removeValue(forKey: udid)
        } else {
            loops[udid] = loop
        }
    }

    private func broadcast(udid: String, frame: Data) {
        guard var loop = loops[udid] else { return }
        loop.latest = frame
        loops[udid] = loop
        for sub in loop.subscribers.values {
            sub.continuation.yield(frame)
        }
    }

    /// Continuous: 描画面を直接読む（速い）。取れなければ simctl screenshot -> (sips downscale) -> read -> broadcast.
    private func runCaptureLoop(udid: String) async {
        let raw = NSTemporaryDirectory() + "sf_\(ProcessInfo.processInfo.processIdentifier)_\(udid)_r.jpg"
        let scaled = NSTemporaryDirectory() + "sf_\(ProcessInfo.processInfo.processIdentifier)_\(udid)_s.jpg"
        // 取れない間（sim 停止中・起動待ち）は間隔を 200ms から倍々に最大 3 秒まで空け、視聴者が
        // 繋がっている間の xcrun の spawn を抑える。取れたら 200ms に戻す。
        var failureDelay: UInt64 = 200_000_000
        while !Task.isCancelled {
            // 描画面が開ければそちらで流し続ける。取れなくなったら（sim 停止等）抜けて、間を空けて開き直す。
            if let fb = await Self.openFramebuffer(udid: udid) {
                if await runFramebufferLoop(udid: udid, fb: fb) { failureDelay = 200_000_000 }
                try? await Task.sleep(nanoseconds: failureDelay)
                failureDelay = min(failureDelay * 2, 3_000_000_000)
                continue
            }
            if let data = await Self.captureFrame(udid: udid, raw: raw, scaled: scaled) {
                broadcast(udid: udid, frame: data)
                failureDelay = 200_000_000
            } else {
                try? await Task.sleep(nanoseconds: failureDelay)
                failureDelay = min(failureDelay * 2, 3_000_000_000)
            }
        }
        try? FileManager.default.removeItem(atPath: raw)
        try? FileManager.default.removeItem(atPath: scaled)
    }

    /// 描画面から上限 fps で取り続ける。画面が変わったときだけ送る。1 枚でも送れたら true。
    private func runFramebufferLoop(udid: String, fb: SimFramebuffer) async -> Bool {
        let interval = 1.0 / Double(Self.fps)
        var produced = false
        var unavailableSince: Date?
        while !Task.isCancelled {
            let start = Date()
            switch await Self.grab(fb) {
            case .frame(let data):
                broadcast(udid: udid, frame: data)
                produced = true
                unavailableSince = nil
            case .unchanged:
                unavailableSince = nil
            case .unavailable:
                let since = unavailableSince ?? start
                unavailableSince = since
                if start.timeIntervalSince(since) > 1.0 { return produced }
            }
            let wait = interval - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        return produced
    }

    // 描画面の読み出し・JPEG 化（数 ms〜十数 ms）は actor の外で行う。
    private static func openFramebuffer(udid: String) async -> SimFramebuffer? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: SimFramebuffer.open(udid: udid)) }
        }
    }

    private static func grab(_ fb: SimFramebuffer) async -> SimFramebuffer.Capture {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: fb.capture(maxSide: scaleW, quality: jpegQuality))
            }
        }
    }

    /// One-shot capture without a running loop (for latestFrame fallback).
    private func captureOnce(udid: String) async -> Data? {
        if let fb = await Self.openFramebuffer(udid: udid), case .frame(let data) = await Self.grab(fb) { return data }
        let raw = NSTemporaryDirectory() + "sf_once_\(udid)_r.jpg"
        let scaled = NSTemporaryDirectory() + "sf_once_\(udid)_s.jpg"
        let data = await Self.captureFrame(udid: udid, raw: raw, scaled: scaled)
        try? FileManager.default.removeItem(atPath: raw)
        try? FileManager.default.removeItem(atPath: scaled)
        return data
    }

    private static func captureFrame(udid: String, raw: String, scaled: String) async -> Data? {
        try? FileManager.default.removeItem(atPath: raw)
        let shot = await Shell.runFull(
            "/usr/bin/xcrun",
            ["simctl", "io", udid, "screenshot", "--type=jpeg", raw],
            timeout: 8.0
        )
        guard shot.exitCode == 0, FileManager.default.fileExists(atPath: raw) else { return nil }
        var file = raw
        if scaleW > 0 {
            let r = await Shell.runFull("/usr/bin/sips", ["-Z", String(scaleW), raw, "--out", scaled], timeout: 5.0)
            if r.exitCode == 0, FileManager.default.fileExists(atPath: scaled) { file = scaled }
        }
        return try? Data(contentsOf: URL(fileURLWithPath: file))
    }

    // MARK: helpers

    private func firstCapture(_ s: String, pattern: String) -> String? {
        Self.firstCaptureStatic(s, pattern: pattern)
    }

    nonisolated private static func firstCaptureStatic(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }
}
