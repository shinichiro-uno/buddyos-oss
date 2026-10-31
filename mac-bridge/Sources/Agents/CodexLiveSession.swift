import Foundation

final class CodexLiveSession: AgentSession {
    private(set) var sessionId: String
    let events: AsyncThrowingStream<SessionEvent, Error>

    private let agentId: String
    private let cwd: String?
    private let executable: String
    private let codexMode: String?
    /// `codex exec` に渡す `-c key=value` 上書き (cron 等の無人実行が sandbox/approval を固定する用)。
    private let configOverrides: [String]
    /// プロセスに足す環境変数（mainagent の合鍵。引数に載せると ps で見える）。
    private let extraEnvironment: [String: String]
    /// codexMode が per-run で明示されたモード (cron) か。true ならグローバル設定の plan に引きずられない。
    private let explicitMode: Bool
    private let config = CodexConfigStore()
    private let continuation: AsyncThrowingStream<SessionEvent, Error>.Continuation
    private var didEmitSessionStarted: Bool
    private var resolvedSessionId: String?
    // codex exec には停止コマンドが無いため、停止はプロセス終了で行う
    // (ClaudeCodeSession と同じ方式)。close() がプロセスを殺さないと orphan が残る。
    private let procLock = NSLock()
    private var currentProcess: Process?
    private var didInterrupt = false

    init(agentId: String, initialSessionId: String?, cwd: String?, executable: String,
         codexMode: String?, configOverrides: [String] = [], explicitMode: Bool = false,
         extraEnvironment: [String: String] = [:]) {
        self.agentId = agentId
        self.cwd = cwd
        self.executable = executable
        self.codexMode = codexMode
        self.configOverrides = configOverrides
        self.extraEnvironment = extraEnvironment
        self.explicitMode = explicitMode
        self.resolvedSessionId = initialSessionId
        self.sessionId = initialSessionId ?? "pending-\(UUID().uuidString.prefix(8))"
        self.didEmitSessionStarted = initialSessionId != nil
        var c: AsyncThrowingStream<SessionEvent, Error>.Continuation!
        self.events = AsyncThrowingStream<SessionEvent, Error> { continuation in
            c = continuation
        }
        self.continuation = c
    }

    func send(_ text: String, skills: [String], attachments: [BridgeAttachment]) async {
        let messageId = UUID().uuidString
        let tmpDir = makeTmpDir()
        defer {
            if let tmpDir {
                try? FileManager.default.removeItem(atPath: tmpDir)
            }
        }

        let prompt = promptText(text: text, skills: skills, attachments: attachments)
        let imageArgs = imageArguments(attachments: attachments, tmpDir: tmpDir)
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        configure(process: process, prompt: prompt, imageArgs: imageArgs)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // 終了は waitUntilExit（スレッドを塞ぐ）ではなく、run() 前に設定した terminationHandler で受ける。
        let exited = OneShotSignal()
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
            // 子プロセスを独自プロセスグループのリーダーにし、codex の子孫ごと kill できるようにする。
            let pid = process.processIdentifier
            if pid > 0 {
                _ = setpgid(pid, pid)
                // SIGKILL で bridge が死んでも次回起動の孤児掃除で回収できるよう記録する。
                SpawnRegistry.register(pid: pid, command: "codex " + (process.arguments ?? []).joined(separator: " "))
            }
            stdin.fileHandleForWriting.closeFile()
            procLock.lock(); currentProcess = process; didInterrupt = false; procLock.unlock()
        } catch {
            continuation.yield(SessionEvent(
                type: .error,
                agentId: agentId,
                sessionId: sessionId,
                messageId: messageId,
                toolUseId: nil,
                content: "Codex spawn failed: \(error.localizedDescription)",
                toolName: nil,
                metadata: nil
            ))
            // .error だけだと SessionHub が生成中のまま戻らない（generating は .done でしか戻らない）。
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
            return
        }

        var assistant = ""

        // 読み取りは協調スレッドプールを塞がないよう readabilityHandler（GCD）で受け、Data のまま
        // 改行で切ってから行単位でデコードする。stderr は常時読んで末尾だけ保持する
        // （終了時にしか読まないとパイプ容量で codex が詰まる）。
        let chunks = PipeChunks.stream(stdout.fileHandleForReading)
        let stderrTail = PipeTailBuffer()
        stderrTail.start(stderr.fileHandleForReading)
        var splitter = PipeLineSplitter()
        for await chunk in chunks {
            for rawLine in splitter.feed(chunk) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                let parsed = parseLine(line)
                if let sid = parsed.sessionId {
                    updateSessionIdIfNeeded(sid)
                    emitSessionStartedIfNeeded()
                }
                if let delta = parsed.text, !delta.isEmpty {
                    emitSessionStartedIfNeeded()
                    assistant += delta
                    continuation.yield(.assistantDelta(delta, agentId: agentId, sessionId: sessionId, messageId: messageId))
                }
            }
        }
        await exited.wait()

        procLock.lock(); currentProcess = nil; let wasInterrupted = didInterrupt; procLock.unlock()
        if wasInterrupted {
            // 停止要求による終了。途中までの出力を確定して done。
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
            return
        }

        if process.terminationStatus != 0 {
            await stderrTail.waitForEOF()
            let errText = stderrTail.text.trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.yield(SessionEvent(
                type: .error,
                agentId: agentId,
                sessionId: sessionId,
                messageId: messageId,
                toolUseId: nil,
                content: errText.isEmpty ? "Codex exited \(process.terminationStatus)" : errText,
                toolName: nil,
                metadata: nil
            ))
            continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
            return
        }

        emitSessionStartedIfNeeded()
        if assistant.isEmpty {
            continuation.yield(.assistantDelta("", agentId: agentId, sessionId: sessionId, messageId: messageId))
        }
        continuation.yield(.done(agentId: agentId, sessionId: sessionId, messageId: messageId))
    }

    func interrupt() async {
        procLock.lock()
        didInterrupt = true
        let p = currentProcess
        procLock.unlock()
        Self.terminateProcessGroup(p)
    }

    func close() async {
        procLock.lock()
        let p = currentProcess
        currentProcess = nil
        procLock.unlock()
        Self.terminateProcessGroup(p)
        continuation.finish()
    }

    /// プロセスグループ全体に SIGTERM → codex の子孫もまとめて終了させる。
    private static func terminateProcessGroup(_ p: Process?) {
        guard let p, p.isRunning else { return }
        let pid = p.processIdentifier
        if pid > 0 {
            kill(-pid, SIGTERM)
            SpawnRegistry.unregister(pid: pid)
        }
        if p.isRunning {
            p.terminate()
        }
    }

    static func locateExecutable() -> String {
        if let override = nonEmpty(ProcessInfo.processInfo.environment["CODEX_BIN"]) {
            return override
        }
        return ExecutableFinder.locate("codex") ?? "codex"
    }

    private func configure(process: Process, prompt: String, imageArgs: [String]) {
        let args = argsForPrompt(prompt, imageArgs: imageArgs)
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
        }
        process.environment = environment()
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
    }

    private func argsForPrompt(_ prompt: String, imageArgs: [String]) -> [String] {
        // 位置引数の前に `--` を置く。無いと「-」で始まるプロンプト（箇条書き等）が unexpected argument で弾かれ、
        // 複数値を取る `-i` がプロンプトまで画像パスとして飲み込む（codex-cli 0.156.1 で実測）。
        if let sid = resolvedSessionId, !sid.isEmpty, !sid.hasPrefix("pending-") {
            return ["exec", "resume", "--json", "--skip-git-repo-check"] + configOverrides + imageArgs + ["--", sid, prompt]
        }
        return ["exec", "--json", "--skip-git-repo-check"] + configOverrides + imageArgs + ["--", prompt]
    }

    private func promptText(text: String, skills: [String], attachments: [BridgeAttachment]) -> String {
        var sections: [String] = []
        if !skills.isEmpty {
            sections.append("/skill \(skills.joined(separator: ","))")
        }
        for attachment in attachments where attachment.kind == .file {
            if let decoded = String(data: attachment.data, encoding: .utf8) {
                sections.append("<file name=\"\(attachment.name)\">\n\(decoded)\n</file>")
            } else {
                sections.append("[file \"\(attachment.name)\" attached: \(attachment.mime), \(attachment.data.count) bytes]")
            }
        }
        // 実画像は -i 入力でモデルへ届くが rollout(履歴)には残らないため、Claude と同じ
        // placeholder を本文に入れて enrichHistory が AttachmentStore から復元できるようにする。
        for attachment in attachments where attachment.kind == .image {
            sections.append("[image \"\(attachment.name)\" attached: \(attachment.mime), \(attachment.data.count) bytes]")
        }
        sections.append(planModePrefixIfNeeded(for: text) + text)
        return sections.joined(separator: "\n\n")
    }

    private func planModePrefixIfNeeded(for text: String) -> String {
        if explicitMode {
            // cron で明示したモード (edit 等) は、グローバルが plan でもそれだけで判定する。
            guard codexMode == "plan" else { return "" }
        } else {
            let approvalPolicy = config.currentApprovalPolicy()
            let sandboxMode = config.currentSandboxMode()
            let currentMode = config.currentCodexMode(approvalPolicy: approvalPolicy, sandboxMode: sandboxMode)
            guard currentMode == "plan" || codexMode == "plan" else { return "" }
        }
        if text.contains("BuddyOS Plan Mode") { return "" }
        return """
        BuddyOS Plan Mode

        計画だけを返してください。まだ実装・ファイル編集・破壊的操作はしないでください。
        具体的な手順を短く出し、判断が分かれる場合は 2-3 個の番号付き選択肢を提示してください。
        その中で推奨案を 1 つ明示し、最後にユーザーの選択または実行許可を待ってください。

        ユーザー入力:

        """
    }

    private func imageArguments(attachments: [BridgeAttachment], tmpDir: String?) -> [String] {
        guard let tmpDir else { return [] }
        var args: [String] = []
        for attachment in attachments where attachment.kind == .image {
            let ext = filenameExtension(forMime: attachment.mime, fallbackName: attachment.name)
            let filename = "\(UUID().uuidString)\(ext.isEmpty ? "" : ".\(ext)")"
            let path = (tmpDir as NSString).appendingPathComponent(filename)
            do {
                try attachment.data.write(to: URL(fileURLWithPath: path))
                args += ["-i", path]
            } catch {
                continue
            }
        }
        return args
    }

    private func parseLine(_ line: String) -> (text: String?, sessionId: String?) {
        guard line != "Reading additional input from stdin..." else {
            return (nil, nil)
        }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        if string(object["type"]) == "thread.started" {
            return (nil, string(object["thread_id"]))
        }
        if string(object["type"]) == "item.completed",
           let item = object["item"] as? [String: Any],
           string(item["type"]) == "agent_message",
           let text = string(item["text"]) {
            return (text, nil)
        }
        return (nil, nil)
    }

    private func updateSessionIdIfNeeded(_ sid: String) {
        guard !sid.isEmpty, sid != sessionId else { return }
        resolvedSessionId = sid
        sessionId = sid
    }

    private func emitSessionStartedIfNeeded() {
        guard !didEmitSessionStarted else { return }
        didEmitSessionStarted = true
        continuation.yield(.sessionStarted(agentId: agentId, sessionId: sessionId))
    }

    private func makeTmpDir() -> String? {
        // テスト中は BuddyPaths が一時フォルダを返すので、本物の ~/.buddyos/tmp を汚さない。
        let base = BuddyPaths.root.appendingPathComponent("tmp/\(UUID().uuidString)", isDirectory: true).path
        do {
            try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            return base
        } catch {
            return nil
        }
    }

    private func filenameExtension(forMime mime: String, fallbackName: String) -> String {
        let ext = (fallbackName as NSString).pathExtension
        if !ext.isEmpty { return ext }
        switch mime {
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        default: return "jpg"
        }
    }

    private func environment() -> [String: String] {
        var env = ChildEnvironment.base()
        let additions = [
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.petclaw/node/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin"
        ]
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (additions + [current]).joined(separator: ":")
        for (k, v) in extraEnvironment { env[k] = v }
        return env
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func string(_ value: Any?) -> String? {
        value as? String
    }
}
