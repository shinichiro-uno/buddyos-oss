import Darwin
import Foundation
import Vapor

/// 別の PC のデスクトップアプリから、この Mac のターミナルを操作するための口（`/terminal/pty`）。
///
/// デスクトップのアプリ内ターミナルは、ふだんは自分の Mac の中で端末を起こす。別の PC を操作しているときは
/// Paseo の中継を通してここへ WebSocket を張り、この Mac の中で端末（ログインシェル）を起こして画面と入力をやり取りする。
///
/// - クエリ: `id`（ペインの id。必須）`cols` `rows` `cwd` `agentId` `resumeSessionId` `command` `attach=1`（つなぎ直しだけ）
/// - 送る: バイナリ = 端末の出力。テキスト = `{"type":"attached","restored":Bool}` / `{"type":"replay","data":String}` /
///   `{"type":"exit","code":Int}` / `{"type":"gone"}`
/// - 受ける: テキスト = `{"type":"input","data":String}` / `{"type":"resize","cols":Int,"rows":Int}` / `{"type":"kill"}`
///
/// 接続が切れても端末は動かし続け（ペインを開き直すと続きから見える）、つながっていない時間が 24 時間を超えたら止める。
/// 端末は開いた端末（Principal）のもの。ほかの端末からはつなげず、その端末を外したら止める（プレビューと同じ）。
/// 出力が中継より速いときは、送りきるまで端末を読むのを止める（Bridge のメモリに積み上げない）。
enum TerminalPtyRoutes {
    static func register(app: Application) {
        app.webSocket("terminal", "pty", maxFrameSize: .init(integerLiteral: 4 * 1024 * 1024), shouldUpgrade: { req in
            req.eventLoop.makeSucceededFuture([:])
        }) { req, ws in
            // ブラウザのページ（プレビュー中の web アプリ・別のサイト）のスクリプトから張られるのを防ぐ（/ws/agent と同じ）。
            // Origin が無いか desktop の画面のものだけ、Host は 127.0.0.1 / localhost / [::1] だけ。
            // 資格情報はトンネル経由なら bdc_、この PC の中からならローカル鍵（BridgeAuth）。
            guard BridgeRequestGuard.passes(req), let principal = BridgeAuth.principal(req) else {
                _ = ws.close(code: .policyViolation)
                return
            }
            guard let id = req.query[String.self, at: "id"], !id.isEmpty, id.count <= 128 else {
                _ = ws.close(code: .policyViolation)
                return
            }
            ws.pingInterval = .seconds(30)
            let qCols = req.query[Int.self, at: "cols"]
            let qRows = req.query[Int.self, at: "rows"]
            let cols = max(2, min(1000, qCols ?? 80))
            let rows = max(2, min(1000, qRows ?? 24))
            let attachOnly = req.query[String.self, at: "attach"] == "1"
            let spec = PtySpawnSpec(
                cwd: req.query[String.self, at: "cwd"],
                agentId: req.query[String.self, at: "agentId"],
                resumeSessionId: req.query[String.self, at: "resumeSessionId"],
                command: req.query[String.self, at: "command"],
                cols: cols,
                rows: rows,
                // つなぎ直しで大きさを付けてこなければ、動いている端末の大きさはそのまま（80×24 で描き直させない）。
                hasSize: qCols != nil && qRows != nil
            )
            // 受け取り口はイベントループの上（ここ）で登録する。端末へは登録表を通して渡す。
            ws.onText { ws, text in PtyRegistry.shared.input(from: ws, text: text) }
            ws.onClose.whenComplete { _ in PtyRegistry.shared.closed(ws) }
            PtyRegistry.shared.connect(id: id, ws: ws, spec: spec, attachOnly: attachOnly, owner: BridgeAuth.creatorName(principal))
        }
    }
}

struct PtySpawnSpec {
    var cwd: String?
    var agentId: String?
    var resumeSessionId: String?
    var command: String?
    var cols: Int
    var rows: Int
    var hasSize = true
}

/// ペインの id ごとの端末。状態の読み書きは queue の上だけで行う。
final class PtyRegistry: @unchecked Sendable {
    static let shared = PtyRegistry()

    private let queue = DispatchQueue(label: "buddyos.pty")
    private var sessions: [String: PtySession] = [:]
    /// つながっている WebSocket → その端末。
    private var bySocket: [ObjectIdentifier: PtySession] = [:]
    private var reaper: DispatchSourceTimer?
    private static let detachedLimit: TimeInterval = 24 * 60 * 60
    /// 1 つの端末（Principal）が同時に持てるターミナルの数。
    static let maxPerOwner = 32

    /// owner は BridgeAuth.creatorName（deviceKeyId か "local"）。
    func connect(id: String, ws: WebSocket, spec: PtySpawnSpec, attachOnly: Bool, owner: String) {
        queue.async {
            // 登録より先に閉じていた（closed が先に走った）。端末を起こしても、つながる先が無い。
            if ws.isClosed { return }
            if let s = self.sessions[id], s.alive {
                // ほかの端末が開いたターミナルにはつながない（その id は無いのと同じに扱う）。
                guard s.owner == owner else {
                    PtySession.sendJSON(ws, ["type": "gone"])
                    _ = ws.close(code: .normalClosure)
                    return
                }
                self.bySocket[ObjectIdentifier(ws)] = s
                s.attach(ws, cols: spec.cols, rows: spec.rows, restored: true, resize: spec.hasSize)
                return
            }
            if attachOnly {
                PtySession.sendJSON(ws, ["type": "gone"])
                _ = ws.close(code: .normalClosure)
                return
            }
            if self.sessions.values.filter({ $0.owner == owner && $0.alive }).count >= Self.maxPerOwner {
                PtySession.sendJSON(ws, [
                    "type": "exit", "code": -1,
                    "message": "ターミナルが多すぎます（\(Self.maxPerOwner) 個まで）。使っていないターミナルを閉じてください",
                ])
                _ = ws.close(code: .normalClosure)
                return
            }
            do {
                let s = try PtySession(id: id, owner: owner, spec: spec, queue: self.queue) { [weak self] ended in
                    // 同じ id で新しく開き直したものは消さない。
                    if self?.sessions[ended.id] === ended { self?.sessions[ended.id] = nil }
                }
                self.sessions[id] = s
                self.bySocket[ObjectIdentifier(ws)] = s
                s.attach(ws, cols: spec.cols, rows: spec.rows, restored: false)
                self.startReaper()
            } catch {
                PtySession.sendJSON(ws, ["type": "exit", "code": -1, "message": "\(error)"])
                _ = ws.close(code: .normalClosure)
            }
        }
    }

    func input(from ws: WebSocket, text: String) {
        queue.async { self.bySocket[ObjectIdentifier(ws)]?.handle(text, from: ws) }
    }

    func closed(_ ws: WebSocket) {
        queue.async { self.bySocket.removeValue(forKey: ObjectIdentifier(ws))?.detach(ws) }
    }

    /// 端末を外した・すべての端末を切断したときに、その端末が開いたターミナルを止める（owner を省くと全部）。
    func drop(owner: String? = nil) {
        queue.async {
            for s in self.sessions.values where owner == nil || s.owner == owner {
                self.sessions[s.id] = nil
                if let ws = s.client { self.bySocket[ObjectIdentifier(ws)] = nil }
                s.revoke()
            }
        }
    }

    /// 動いているターミナルの数（テスト用）。
    func count(owner: String) -> Int {
        queue.sync { sessions.values.filter { $0.owner == owner && $0.alive }.count }
    }

    private func startReaper() {
        guard reaper == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 600, repeating: 600)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for s in self.sessions.values where s.client == nil {
                if now.timeIntervalSince(s.detachedAt) > Self.detachedLimit { s.terminate() }
            }
        }
        t.resume()
        reaper = t
    }
}

enum PtyError: Error, CustomStringConvertible {
    case spawnFailed(Int32)
    var description: String {
        switch self {
        case .spawnFailed(let e): return "ターミナルを起動できませんでした（errno \(e)）"
        }
    }
}

/// 端末の fd。読み書きの source が両方とも cancel を終えてから閉じる（libdispatch の決まり。
/// 先に閉じると、同じ番号を使い回した別の source が動かなくなることがある）。queue の上だけで触る。
private final class PtyFd {
    let fd: Int32
    private var refs = 0
    init(_ fd: Int32) { self.fd = fd }
    func retain() { refs += 1 }
    func release() {
        refs -= 1
        if refs == 0 { close(fd) }
    }
}

final class PtySession {
    let id: String
    /// 開いた端末（BridgeAuth.creatorName）。
    let owner: String
    private let queue: DispatchQueue
    private let fdBox: PtyFd
    private let master: Int32
    private let pid: pid_t
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    /// 端末へまだ書けていない入力。pty が詰まって EAGAIN になったら、ここに積んで書けるようになってから流す
    /// （queue を空回りで塞がない。塞ぐと kill や他のペインの入力まで止まる）。
    private var pendingInput: [UInt8] = []
    private var pendingOffset = 0
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    /// 積んでおける入力の上限。超えた分は捨てる（巨大な貼り付けでメモリを食い潰さない）。
    static let pendingInputLimit = 16 * 1024 * 1024
    private var scrollback = Data()
    private static let scrollbackLimit = 256 * 1024
    /// 上限を超えて先頭を切ったことがある（送り直すときは、切った行の残りを飛ばす）。
    private var scrollbackTrimmed = false
    /// 送りきれていない出力のバイト数と、どの接続に向けたものか（つなぎ替えたら数え直す）。
    private var inFlight = 0
    private var sendGen = 0
    private var readPaused = false
    /// 送りきれていない出力がこれを超えたら、端末を読むのを止める。LOW まで減ったら再開する。
    static let sendHigh = 1024 * 1024
    static let sendLow = 256 * 1024
    private let onEnd: (PtySession) -> Void
    private(set) var client: WebSocket?
    private(set) var detachedAt = Date()
    private(set) var alive = true

    init(id: String, owner: String, spec: PtySpawnSpec, queue: DispatchQueue, onEnd: @escaping (PtySession) -> Void) throws {
        self.id = id
        self.owner = owner
        self.queue = queue
        self.onEnd = onEnd

        let shell = PtySession.loginShell()
        let cwd = PtySession.directory(spec.cwd)
        // Clerk のトークン・MCP のトークンは渡さない（ChildEnvironment）。
        var env = ChildEnvironment.base()
        // Bridge の中で動いている Claude Code 等の印を、中で起こすシェルに持ち込まない。
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("ELECTRON_") || k == "BUDDYOS_BRIDGE_PORT" {
            env[k] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "BuddyOS"
        env["BUDDYOS_PANE_ID"] = id
        if env["LANG"] == nil { env["LANG"] = "ja_JP.UTF-8" }
        env["SHELL"] = shell

        // fork の後の子では Swift の確保をしないよう、exec に渡すものはすべて先に C の文字列にしておく。
        let argv = PtySession.cArray([shell, "-l"])
        let envp = PtySession.cArray(env.map { "\($0.key)=\($0.value)" })
        let cShell = strdup(shell)!
        let cCwd = strdup(cwd)!
        defer {
            PtySession.freeCArray(argv)
            PtySession.freeCArray(envp)
            free(cShell)
            free(cCwd)
        }

        var win = winsize(ws_row: UInt16(spec.rows), ws_col: UInt16(spec.cols), ws_xpixel: 0, ws_ypixel: 0)
        var masterFd: Int32 = -1
        let child = forkpty(&masterFd, nil, nil, &win)
        if child < 0 { throw PtyError.spawnFailed(errno) }
        if child == 0 {
            // 子: Bridge が開いている接続（待ち受けや中継の socket など）をシェルに引き継がない。
            var fd: Int32 = 3
            while fd < 4096 {
                close(fd)
                fd += 1
            }
            _ = chdir(cCwd)
            execve(cShell, argv, envp)
            _exit(127)
        }
        master = masterFd
        pid = child
        fdBox = PtyFd(masterFd)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        let box = fdBox
        box.retain()
        rs.setCancelHandler { box.release() }
        rs.resume()
        readSource = rs
        let es = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        es.setEventHandler { [weak self] in self?.finish() }
        es.resume()
        exitSource = es

        if let start = PtySession.startCommand(spec) { write(start + "\r") }
    }

    // MARK: - つなぐ・切る（queue の上で呼ぶ）

    func attach(_ ws: WebSocket, cols: Int, rows: Int, restored: Bool, resize doResize: Bool = true) {
        // 後から来た接続を正とする（同じペインを 2 か所で開いたら、前の方は閉じる）。
        if let old = client, old !== ws { _ = old.close(code: .goingAway) }
        client = ws
        // 前の接続に送りきれていない分は数えない（止めていたら読むのを再開する）。
        restartSending()
        if doResize { resize(cols: cols, rows: rows) }
        PtySession.sendJSON(ws, ["type": "attached", "restored": restored])
        if restored {
            let (text, tail) = PtySession.replay(scrollback, trimmed: scrollbackTrimmed)
            if !text.isEmpty { PtySession.sendJSON(ws, ["type": "replay", "data": text]) }
            // 終わっていない文字（UTF-8 の途中）はバイナリで送り、続きのバイトと一緒に読んでもらう。
            if !tail.isEmpty { ws.send(raw: tail, opcode: .binary) }
        }
    }

    /// WebSocket が切れた。端末は動かし続ける。
    func detach(_ ws: WebSocket) {
        guard client === ws else { return }
        client = nil
        detachedAt = Date()
        restartSending()
    }

    /// 端末を外したので止める（つないでいる接続には終わったと伝えて閉じる）。
    func revoke() {
        if let ws = client {
            PtySession.sendJSON(ws, ["type": "exit", "code": -1])
            _ = ws.close(code: .normalClosure)
        }
        client = nil
        terminate()
    }

    private func restartSending() {
        sendGen += 1
        inFlight = 0
        resumeReading()
    }

    private func pauseReading() {
        guard !readPaused else { return }
        readPaused = true
        readSource?.suspend()
    }

    private func resumeReading() {
        guard readPaused else { return }
        readPaused = false
        readSource?.resume()
    }

    /// 出力を送る。送り終わったら数を減らし、止めていた読みを再開する。
    private func send(_ chunk: Data, to ws: WebSocket) {
        let n = chunk.count
        let gen = sendGen
        inFlight += n
        let promise = ws.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard gen == self.sendGen else { return }
                self.inFlight -= n
                if self.inFlight <= PtySession.sendLow { self.resumeReading() }
            }
        }
        ws.send(raw: chunk, opcode: .binary, promise: promise)
    }

    func handle(_ text: String, from ws: WebSocket) {
        guard ws === client, alive,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "input":
            if let data = obj["data"] as? String {
                // Ctrl-C（ETX）は、積んである貼り付けの残りより先に届ける（残りは捨てる）。
                if data.utf8.contains(0x03) { discardPendingInput() }
                write(data)
            }
        case "resize":
            if let c = obj["cols"] as? Int, let r = obj["rows"] as? Int { resize(cols: c, rows: r) }
        case "kill":
            terminate()
        default:
            break
        }
    }

    // MARK: - 端末

    /// 入力を積んで、書けるだけ書く。残りは DispatchSourceWrite で書けるようになってから流す。
    private func write(_ text: String) {
        guard alive else { return }
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        if pendingInput.count - pendingOffset + bytes.count > PtySession.pendingInputLimit { return }
        pendingInput.append(contentsOf: bytes)
        flushInput()
    }

    private func flushInput() {
        while pendingOffset < pendingInput.count {
            let n = pendingInput.withUnsafeBytes { buf in
                Darwin.write(master, buf.baseAddress!.advanced(by: pendingOffset), buf.count - pendingOffset)
            }
            if n > 0 {
                pendingOffset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                // 端末の受け口がいっぱい。書けるようになったら続きを流す。
                startWriteSource()
                return
            } else {
                // 端末が閉じた等。残りは捨てる。
                discardPendingInput()
                return
            }
        }
        pendingInput.removeAll(keepingCapacity: pendingInput.count <= 64 * 1024)
        pendingOffset = 0
        stopWriteSource()
    }

    private func discardPendingInput() {
        pendingInput.removeAll()
        pendingOffset = 0
        stopWriteSource()
    }

    private func startWriteSource() {
        if writeSource == nil {
            let ws = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
            ws.setEventHandler { [weak self] in self?.flushInput() }
            let box = fdBox
            box.retain()
            ws.setCancelHandler { box.release() }
            writeSource = ws
        }
        guard !writeSourceActive else { return }
        writeSourceActive = true
        writeSource?.resume()
    }

    private func stopWriteSource() {
        guard writeSourceActive else { return }
        writeSourceActive = false
        writeSource?.suspend()
    }

    /// 積んである入力のバイト数（テスト用）。
    var pendingInputCount: Int { pendingInput.count - pendingOffset }

    private func resize(cols: Int, rows: Int) {
        guard alive else { return }
        var win = winsize(
            ws_row: UInt16(max(2, min(1000, rows))),
            ws_col: UInt16(max(2, min(1000, cols))),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        // TIOCSWINSZ（Swift にはマクロとして入ってこない）
        _ = withUnsafeMutablePointer(to: &win) { ioctl(master, UInt(0x8008_7467), $0) }
    }

    /// force = 終わるときの読み切り（送りきれていなくても読む）。
    private func readAvailable(force: Bool = false) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            // 送りきれていない出力が多い（中継が遅い）。送れるまで端末を読まない（シェルの側が書くのを待つ）。
            if !force, client != nil, inFlight > PtySession.sendHigh {
                pauseReading()
                return
            }
            let n = read(master, &buf, buf.count)
            if n > 0 {
                let chunk = Data(buf[0..<n])
                scrollback.append(chunk)
                if scrollback.count > PtySession.scrollbackLimit {
                    scrollback = PtySession.trimmed(scrollback, limit: PtySession.scrollbackLimit)
                    scrollbackTrimmed = true
                }
                if let ws = client { send(chunk, to: ws) }
            } else {
                // 0 = 相手（シェル）が閉じた。EAGAIN = いま読めるものは読み切った。
                return
            }
        }
    }

    /// 止める（「閉じる」・24 時間つながらなかったとき）。終わったら finish が呼ばれる。
    func terminate() {
        guard alive else { return }
        kill(pid, SIGHUP)
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.alive else { return }
            kill(self.pid, SIGKILL)
        }
    }

    private func finish() {
        guard alive else { return }
        readAvailable(force: true)
        alive = false
        var status: Int32 = 0
        // 終わったと知らされてから呼ぶので、待たずに返る（WNOHANG だと、まれに 0 が返って終了コードを取り損ねる）。
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        // 止めてある（suspend 中の）source は resume してから cancel する。fd は両方の cancel が済んでから閉じる（PtyFd）。
        if readPaused {
            readPaused = false
            readSource?.resume()
        }
        readSource?.cancel()
        exitSource?.cancel()
        // 止めてある（suspend 中の）source は resume してから cancel する（そのまま解放するとクラッシュする）。
        pendingInput.removeAll()
        pendingOffset = 0
        if let ws = writeSource {
            if !writeSourceActive { ws.resume() }
            ws.cancel()
            writeSource = nil
            writeSourceActive = false
        }
        if let ws = client {
            PtySession.sendJSON(ws, ["type": "exit", "code": Int(code)])
            _ = ws.close(code: .normalClosure)
        }
        client = nil
        onEnd(self)
    }

    // MARK: - 補助

    /// 先頭を切って limit バイトに収める。UTF-8 の文字の途中では切らない。
    static func trimmed(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        var cut = data.startIndex + (data.count - limit)
        while cut < data.endIndex, data[cut] & 0xC0 == 0x80 { cut += 1 }
        return Data(data[cut...])
    }

    /// 送り直す出力。先頭を切ったことがあれば、切った行の残りを飛ばす（行やエスケープの途中から描き始めない）。
    /// 末尾の終わっていない文字（UTF-8 の途中）は tail に分ける。
    static func replay(_ data: Data, trimmed: Bool) -> (text: String, tail: Data) {
        var body = data[...]
        if trimmed, let nl = body.prefix(4096).firstIndex(of: 0x0A) { body = body[body.index(after: nl)...] }
        var end = body.endIndex
        var i = body.endIndex
        var back = 0
        while i > body.startIndex, back < 4 {
            i = body.index(before: i)
            back += 1
            let b = body[i]
            if b & 0xC0 == 0x80 { continue }
            let need = b < 0x80 ? 1 : b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if need > back { end = i }
            break
        }
        return (String(decoding: body[..<end], as: UTF8.self), Data(body[end...]))
    }

    static func sendJSON(_ ws: WebSocket, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(text)
    }

    private static func loginShell() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], s.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: s) {
            return s
        }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return "/bin/zsh"
    }

    private static func directory(_ path: String?) -> String {
        let home = NSHomeDirectory()
        guard var p = path, !p.isEmpty else { return home }
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst() }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue ? p : home
    }

    /// 起動するエージェントのコマンド。デスクトップの agentCommand.ts と同じ（buddy-codex 等はこの Mac にあれば使う）。
    static func startCommand(_ spec: PtySpawnSpec) -> String? {
        if let c = spec.command?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty, !c.contains("\n"), !c.contains("\r") {
            return c
        }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        func wrapper(_ name: String, _ fallback: String) -> String {
            let p = NSHomeDirectory() + "/.local/bin/" + name
            return FileManager.default.isExecutableFile(atPath: p) ? q(p) : fallback
        }
        if let sid = spec.resumeSessionId, sid.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil {
            switch spec.agentId {
            case "claude": return "claude --resume \(q(sid))"
            case "codex": return "\(wrapper("buddy-codex", "codex")) resume \(q(sid))"
            case "opencode": return "\(wrapper("buddy-opencode", "opencode")) --session \(q(sid))"
            default: break
            }
        }
        switch spec.agentId {
        case "claude": return "claude"
        case "codex": return wrapper("buddy-codex", "codex")
        case "opencode": return wrapper("buddy-opencode", "opencode")
        case "antigravity": return "agy"
        default: return nil
        }
    }

    private static func cArray(_ items: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let arr = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: items.count + 1)
        for (i, s) in items.enumerated() { arr[i] = strdup(s) }
        arr[items.count] = nil
        return arr
    }

    private static func freeCArray(_ arr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var i = 0
        while let p = arr[i] {
            free(p)
            i += 1
        }
        arr.deallocate()
    }
}
