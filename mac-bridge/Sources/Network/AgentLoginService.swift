import Foundation

/// iPhone からエージェントの CLI にログインする（Mac の前にいなくてよい）。
///
/// ブラウザを Mac で開く普通のログインは iPhone から終えられないので、別の端末で認証できる方式を使う:
/// - codex / grok: デバイスコード（`--device-auth`）。URL とコードを iPhone に出し、iPhone のブラウザで入れる。
/// - cursor: 出てきた URL を iPhone で開いて認証すると、CLI が待ち受けて完了する。
/// - claude: 出てきた URL を iPhone で開き、認証後に表示されるコードをアプリに貼ってもらい、標準入力に渡す。
/// 終わったら AgentProbe をやり直し、実際にログインできたか（configured）で成否を決める。
///
/// iPhone はブラウザに切り替えている間に接続が切れることがあるので、知らせは「頼んだ接続」ではなく
/// 購読している接続すべてへ送り、最後の状態（終わったものも）をしばらく覚えておく。戻ってきた
/// iPhone は status で今の状態を問い合わせ直す。
actor AgentLoginService {
    static let shared = AgentLoginService()

    struct Event: Sendable {
        enum Phase: String, Sendable {
            case starting, waiting, verifying, succeeded, failed, cancelled
        }
        let agentId: String
        let phase: Phase
        var url: String?
        var code: String?
        /// 認証のあとに表示されるコードを、アプリから送ってもらう必要がある（claude）。
        var needsCode: Bool = false
        var message: String?
    }

    private struct Spec {
        let args: [String]
        let needsCode: Bool
        var env: [String: String] = [:]
    }

    /// agent id の先頭（"-" より前）ごとのログイン方法。
    private static let specs: [String: Spec] = [
        "codex": Spec(args: ["login", "--device-auth"], needsCode: false),
        "grok": Spec(args: ["login", "--device-auth"], needsCode: false),
        "cursor": Spec(args: ["login"], needsCode: false, env: ["NO_OPEN_BROWSER": "1"]),
        "claude": Spec(args: ["auth", "login"], needsCode: true),
    ]

    /// 待ちの上限（デバイスコードの有効期限 15 分に合わせる）。
    private static let timeout: TimeInterval = 15 * 60

    static func supports(_ agentId: String) -> Bool {
        specs[base(agentId)] != nil
    }

    private static func base(_ agentId: String) -> String {
        String(agentId.split(separator: "-").first ?? Substring(agentId))
    }

    private final class Running: @unchecked Sendable {
        let process: Process
        let stdin: FileHandle
        var output = ""
        var last: Event
        var cancelled = false
        init(process: Process, stdin: FileHandle, last: Event) {
            self.process = process
            self.stdin = stdin
            self.last = last
        }
    }

    private var running: [String: Running] = [:]
    /// 最後に知らせた状態（終わったものも）。iPhone が戻ってきたときの問い合わせに答える。
    private var latest: [String: (event: Event, at: Date)] = [:]
    private static let keepFinished: TimeInterval = 30 * 60
    private var listeners: [UUID: @Sendable (Event) -> Void] = [:]

    func subscribe(_ send: @escaping @Sendable (Event) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = send
        return id
    }

    func unsubscribe(_ id: UUID) {
        listeners[id] = nil
    }

    private func emit(_ e: Event) {
        latest[e.agentId] = (e, Date())
        for send in listeners.values { send(e) }
    }

    /// 今の状態を知らせる（動いていない・覚えていないときは nil）。
    func status(agentId: String) -> Event? {
        if let r = running[agentId] { return r.last }
        guard let hit = latest[agentId], Date().timeIntervalSince(hit.at) < Self.keepFinished else { return nil }
        return hit.event
    }

    /// ログインを始める。進み具合は購読者へ（URL・コードが分かった時点と、終わった時点で）知らせる。
    /// 同じエージェントで動いている途中なら、最後の状態をもう一度知らせるだけにする（iPhone の画面を開き直したとき）。
    func start(agentId: String) async {
        if let r = running[agentId] {
            emit(r.last)
            return
        }
        guard let spec = Self.specs[Self.base(agentId)] else {
            emit(Event(agentId: agentId, phase: .failed, message: "unsupported"))
            return
        }
        let probe = await AgentProbe.shared.probe(id: agentId)
        guard probe.installed, let exe = probe.binaryPath else {
            emit(Event(agentId: agentId, phase: .failed, message: "not-installed"))
            return
        }
        // 確認している間に、別の start が先に始めていたらそれに乗る。
        if let r = running[agentId] {
            emit(r.last)
            return
        }
        launch(agentId: agentId, exe: exe, spec: spec)
    }

    /// テスト用: 実体と引数を指定して始める（AgentLoginServiceTests の偽 CLI）。
    func startForTesting(agentId: String, exe: String, args: [String], needsCode: Bool) {
        launch(agentId: agentId, exe: exe, spec: Spec(args: args, needsCode: needsCode))
    }

    private func launch(agentId: String, exe: String, spec: Spec) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = spec.args
        var env = CodexAppServerSession.spawnEnvironment()
        env["PATH"] = ["\(NSHomeDirectory())/.grok/bin", env["PATH"] ?? ""].joined(separator: ":")
        env["NO_COLOR"] = "1"
        for (k, v) in spec.env { env[k] = v }
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let outPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        proc.standardInput = inPipe
        // waitUntilExit はスレッドを塞ぐので使わない（PipeReading.swift の OneShotSignal を参照）。
        let exited = OneShotSignal()
        proc.terminationHandler = { _ in exited.signal() }

        let first = Event(agentId: agentId, phase: .starting, needsCode: spec.needsCode)
        do {
            try proc.run()
        } catch {
            emit(Event(agentId: agentId, phase: .failed, message: error.localizedDescription))
            return
        }
        let r = Running(process: proc, stdin: inPipe.fileHandleForWriting, last: first)
        running[agentId] = r
        emit(first)

        // 出力を読み、URL とコードが分かったら知らせる。
        let reader = Task { [weak self] in
            for await chunk in PipeChunks.stream(outPipe.fileHandleForReading) {
                await self?.consume(agentId: agentId, chunk: chunk)
            }
        }
        // 上限を過ぎたら止める。終わって見張りを止めたとき（sleep が中断されたとき）は何もしない。
        // try? で中断を捨てて cancel まで進むと、正常に終わったログインがキャンセル扱いになる。
        let watchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.timeout * 1_000_000_000))
            } catch {
                return
            }
            await self?.cancel(agentId: agentId)
        }

        Task { [weak self] in
            await exited.wait()
            watchdog.cancel()
            // 孫プロセスが出力の口を握ったまま残っても待ち続けないよう、読み終わりは少しだけ待つ。
            try? outPipe.fileHandleForWriting.close()
            _ = await withTaskGroup(of: Void.self) { g in
                g.addTask { _ = await reader.value }
                g.addTask { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                await g.next()
                g.cancelAll()
            }
            await self?.finish(agentId: agentId, status: proc.terminationStatus)
        }
    }

    /// iPhone で認証したあとに表示されたコードを渡す（claude）。
    func submitCode(agentId: String, code: String) {
        guard let r = running[agentId] else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = (trimmed + "\n").data(using: .utf8) else { return }
        try? r.stdin.write(contentsOf: data)
    }

    func cancel(agentId: String) {
        guard let r = running[agentId] else { return }
        r.cancelled = true
        if r.process.isRunning {
            r.process.terminate()
            let pid = r.process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }
    }

    private func consume(agentId: String, chunk: Data) {
        guard let r = running[agentId] else { return }
        r.output = String((r.output + String(decoding: chunk, as: UTF8.self)).suffix(16_000))
        let text = Self.stripAnsi(r.output)
        let url = Self.firstURL(in: text)
        let code = Self.deviceCode(in: text)
        guard url != nil, url != r.last.url || code != r.last.code else { return }
        let e = Event(agentId: agentId, phase: .waiting, url: url, code: code, needsCode: r.last.needsCode)
        r.last = e
        emit(e)
    }

    private func finish(agentId: String, status: Int32) async {
        guard let r = running.removeValue(forKey: agentId) else { return }
        try? r.stdin.close()
        if r.cancelled {
            emit(Event(agentId: agentId, phase: .cancelled))
            return
        }
        emit(Event(agentId: agentId, phase: .verifying))
        await AgentProbe.shared.clearCache()
        let st = await AgentProbe.shared.probe(id: agentId)
        if st.configured {
            emit(Event(agentId: agentId, phase: .succeeded))
        } else {
            let tail = Self.stripAnsi(r.output)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .suffix(3).joined(separator: "\n")
            emit(Event(agentId: agentId, phase: .failed, message: tail.isEmpty ? "exit \(status)" : tail))
        }
    }

    // MARK: - 出力の読み取り

    static func stripAnsi(_ s: String) -> String {
        // OSC 8 のリンク（ESC ] 8 ;; URL BEL 表示 ESC ] 8 ;; BEL）は、中の URL ごと消して表示側だけ残す。
        var out = s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        return out
    }

    static func firstURL(in text: String) -> String? {
        guard let range = text.range(of: "https://[^\\s\"'<>]+", options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// デバイスコード（例: KT4R-QOW5Q / R44P-VDZ7）。URL の中のものは除く。
    static func deviceCode(in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.contains("://") { continue }
            if l.range(of: "^[A-Z0-9]{4,5}-[A-Z0-9]{4,6}$", options: .regularExpression) != nil { return l }
        }
        return nil
    }
}
