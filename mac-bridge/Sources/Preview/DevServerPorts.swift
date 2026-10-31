import Foundation

/// この Mac で、このユーザーの開発サーバーらしいプロセスが待ち受けている TCP のポート。
/// Web プレビューの中継先を、ここで見つかったものと既定の候補だけに絞る。
///
/// `lsof -nP -iTCP -sTCP:LISTEN -a -u <uid>` の結果から、コマンド名が開発サーバーらしいもの
/// （node / bun / python など）だけを拾う。Bridge 自身と、Bridge が直接起こした子プロセス
/// （opencode serve・sidecar 等）のポートは除く。1024 未満は拾わない。
enum DevServerPorts {
    /// コマンド名の前方一致（小文字で比べる）。
    static let devCommandPrefixes = [
        "node", "bun", "deno", "python", "ruby", "php", "java", "hugo", "next-server", "esbuild",
        "dotnet", "puma", "uvicorn", "gunicorn", "vite", "astro", "expo", "caddy",
    ]

    /// 短い間に何度も lsof を起こさない（/preview/targets と /preview/session が続けて来る）。
    private static let cacheTTL: TimeInterval = 3
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (at: Date, ports: Set<Int>)?

    static func listening() async -> Set<Int> {
        if let hit = lock.withLock({ cached }), Date().timeIntervalSince(hit.at) < cacheTTL { return hit.ports }
        let uid = getuid()
        let out = await Shell.runAsync(
            "/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", String(uid), "+c", "0", "-F", "pRcn"],
            timeout: 3.0
        ) ?? ""
        let ports = parse(lsofOutput: out, selfPid: getpid())
        lock.withLock { cached = (Date(), ports) }
        return ports
    }

    /// `lsof -F pRcn` の出力を読む。p=pid, R=親の pid, c=コマンド名, n=アドレス（"127.0.0.1:5173" / "*:3000" / "[::1]:5173"）。
    static func parse(lsofOutput: String, selfPid: Int32) -> Set<Int> {
        var ports: Set<Int> = []
        var pid: Int32 = 0
        var ppid: Int32 = 0
        var command = ""
        for line in lsofOutput.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                pid = Int32(value) ?? 0
                ppid = 0
                command = ""
            case "R":
                ppid = Int32(value) ?? 0
            case "c":
                command = value.lowercased()
            case "n":
                guard pid != selfPid, ppid != selfPid,
                      devCommandPrefixes.contains(where: { command.hasPrefix($0) }),
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]),
                      port >= 1024, port < 65536 else { continue }
                ports.insert(port)
            default:
                continue
            }
        }
        return ports
    }
}
