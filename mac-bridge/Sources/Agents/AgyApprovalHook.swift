import Foundation
import Crypto

/// Bridge が起動した agy（Antigravity CLI）の操作の承認を、iPhone の承認カードで受けるための hook。
///
/// agy の headless 実行は、確認が要る操作（コマンド実行）を聞けずに自動で拒否する（hook が allow を
/// 返しても外れない。2026-10-08 実測）。そこで組み込みの確認を `--dangerously-skip-permissions` で外し、
/// 代わりに PreToolUse hook でコマンドを止めて Bridge に問い合わせる。agy の許可リスト
/// （~/.gemini/antigravity-cli/settings.json の permissions.allow）にあるコマンドはそのまま通す。
///
/// 置き場（agy 1.3.5 で確認）:
/// - スクリプト: `~/.buddyos/agy-hooks/buddy-agy-approval.sh`（フォルダ 0500・ファイル 0500）。
/// - 登録: agy の全体設定のプラグイン `~/.gemini/config/plugins/buddyos-approval-<乱数>/`
///   （`plugin.json` と `hooks.json`。フォルダ 0500・ファイル 0400）。`hooks.json` はスクリプトを絶対パスで呼ぶ。
/// - どちらも `--add-dir` には渡さない（agy のワークスペースに入れない）。
///
/// agy が hook を読むのは、ワークスペース（作業フォルダと `--add-dir`）の `.agents/hooks.json` と、
/// 全体設定の `~/.gemini/config/hooks.json`・`~/.gemini/config/plugins/<名前>/hooks.json` だけ。hook の
/// ファイルや設定フォルダを指す引数・環境変数は無い（`agy --help` と本体の文字列で確認）。そこで全体設定の
/// プラグインにする。利用者の `hooks.json` は書き換えない（BuddyOS 専用のフォルダを足すだけ）。
/// - 全体設定なので、ターミナルの agy にも載る。スクリプトは環境変数 BUDDYOS_AGY_HOOK_URL が無ければ何も
///   出さずに終わる（何も出さない = agy の通常の判断。実測）ので、ターミナルの agy の動きは変わらない。
/// - プラグインは置けば有効になる。利用者が `agy plugin disable` で止めると、全体設定の
///   `~/.gemini/config/config.json` の `plugins.<名前>.enabled` が false になり、hook が読まれない（実測）。
///   ターンの開始ごとにこれを確かめ、止まっていれば hook を使わない（= agy の組み込みの確認に任せる）。
/// - 名前の後ろに乱数を付ける。agy は同じ名前の hook を 1 つにまとめ、ワークスペースの設定が全体設定より
///   優先される（実測と agy の説明書き）。決まった名前だと、リポジトリの `.agents/hooks.json` に同じ名前で
///   `"enabled": false` を書くだけで承認を外せてしまう。名前を知られて、ワークスペース（とその親）や全体設定の
///   `hooks.json` に同じ名前を書かれたときは、ターンの開始時に見つけて名前を替える（nameClash）。
///
/// agy 自身が hook を「常に allow」に書き換えられないようにする。
/// - hook 経由の書き込みは AgyApprovalPolicy が作業フォルダの中だけ許し、~/.buddyos・~/.gemini は拒否する。
/// - ファイルとフォルダは読み取り専用にし、ターンの開始ごとに権限と中身の SHA-256 を確かめる（違えば書き直す。
///   書き直せなければ hook を使わない = agy の組み込みの確認に任せる）。
/// - ターンの間はファイルとフォルダを見張り（AgyHookTamperWatch）、書き換え・権限の変更・消去・名前の変更が
///   あればその agy をすぐ止める（ターンの途中で書き換えられた hook を、そのターンの残りで使わせない）。
enum AgyApprovalHook {
    /// iPhone で答えるまで待つ上限（hook の timeout）。Bridge 側はこれより少し短く打ち切る。
    static let timeoutSeconds = 600
    /// プラグインと hook の名前の頭。後ろに 16 桁の乱数（16 進）を付ける。
    static let pluginPrefix = "buddyos-approval-"

    /// 置いた hook の場所。ensureInstalled がターンの開始ごとに返す。
    struct Installation: Equatable {
        let home: String
        /// プラグインの名前（= フォルダ名 = hooks.json の hook の名前）。
        let pluginName: String

        var scriptDirectory: URL { AgyApprovalHook.scriptDirectory(home: home) }
        var scriptURL: URL { AgyApprovalHook.scriptURL(home: home) }
        var pluginDirectory: URL {
            AgyApprovalHook.pluginsRoot(home: home).appendingPathComponent(pluginName, isDirectory: true)
        }
        var manifestURL: URL { pluginDirectory.appendingPathComponent("plugin.json") }
        var hooksURL: URL { pluginDirectory.appendingPathComponent("hooks.json") }

        /// ターンの間に見張るもの（フォルダ 2 つとファイル 3 つ）。
        var watchedPaths: [String] {
            [scriptDirectory.path, scriptURL.path, pluginDirectory.path, manifestURL.path, hooksURL.path]
        }
        /// 実行されるファイル（AgyHookTamperWatch は属性の変化を見ない）。
        var executables: Set<String> { [scriptURL.path] }
    }

    static func scriptDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".buddyos/agy-hooks", isDirectory: true)
    }
    static func scriptURL(home: String = NSHomeDirectory()) -> URL {
        scriptDirectory(home: home).appendingPathComponent("buddy-agy-approval.sh")
    }
    /// agy の全体設定のプラグインの置き場。
    static func pluginsRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".gemini/config/plugins", isDirectory: true)
    }
    /// プラグインの有効・無効を agy が記録するファイル。
    static func agyConfigURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".gemini/config/config.json")
    }

    static let script = """
    #!/bin/sh
    # BuddyOS: Bridge が起動した agy の操作の承認を iPhone で受ける（PreToolUse hook）。
    # Bridge から起動されていなければ何も出さない（agy の通常の判断に任せる）。
    [ -n "$BUDDYOS_AGY_HOOK_URL" ] || exit 0
    out=$(/usr/bin/curl -sf --max-time 590 -H "X-BuddyOS-Hook-Token: $BUDDYOS_AGY_HOOK_TOKEN" \\
      -H "Content-Type: application/json" --data-binary @- "$BUDDYOS_AGY_HOOK_URL") || out=''
    if [ -n "$out" ]; then
      printf '%s\\n' "$out"
    else
      echo '{"decision":"deny","reason":"BuddyOS の Bridge に承認を問い合わせられませんでした。"}'
    fi

    """

    /// プラグインの hooks.json。スクリプトは絶対パスで呼ぶ（作業フォルダは hooks.json のあるフォルダになる）。
    static func hooksConfig(pluginName: String, scriptPath: String) -> String {
        let command = "'" + scriptPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return json([
            pluginName: [
                "PreToolUse": [[
                    "matcher": "*",
                    "hooks": [["type": "command", "command": command, "timeout": timeoutSeconds]]
                ]]
            ]
        ])
    }

    static func manifest(pluginName: String) -> String {
        json(["name": pluginName])
    }

    private static func json(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 同じ Bridge の複数のチャットが同時にターンを始めても、置き直しが重ならないようにする。
    private static let installLock = NSLock()

    /// hook を置き、権限と中身を確かめる（同じなら書かない）。置けない・確かめられない・利用者がプラグインを
    /// 止めているときは nil（承認は従来どおり agy 任せ）。
    /// - workspaces: このターンの agy のワークスペース（作業フォルダと `--add-dir`）。ここの `.agents/hooks.json`
    ///   などにプラグインと同じ名前があれば（名前を知られて、同じ名前の hook で上書きされうる）、名前を替えて置き直す。
    static func ensureInstalled(home: String = NSHomeDirectory(), workspaces: [String] = []) -> Installation? {
        installLock.withLock {
            do {
                try removeLegacy(home: home)
                if !verifyScript(home: home) { try installScript(home: home) }
                var install = try ensurePlugin(home: home)
                if let clash = nameClash(install.pluginName, home: home, workspaces: workspaces) {
                    FileHandle.standardError.write(Data("[agy-hook] plugin name found in \(clash); renaming the plugin\n".utf8))
                    try remove(install.pluginDirectory)
                    install = try ensurePlugin(home: home)
                    if nameClash(install.pluginName, home: home, workspaces: workspaces) != nil { return nil }
                }
                guard isPluginEnabled(install.pluginName, home: home) else {
                    FileHandle.standardError.write(Data("[agy-hook] plugin \(install.pluginName) is disabled in agy; approvals fall back to agy\n".utf8))
                    return nil
                }
                return verify(install) ? install : nil
            } catch {
                FileHandle.standardError.write(Data("[agy-hook] install failed: \(error.localizedDescription)\n".utf8))
                return nil
            }
        }
    }

    /// 置いてある hook が Bridge の書いたものと同じか（権限と SHA-256）。シンボリックリンクは認めない。
    static func verify(_ install: Installation) -> Bool {
        verifyScript(home: install.home) && verifyPlugin(install)
    }

    /// agy の全体設定でプラグインが止められていないか。config.json が無い・名前が載っていなければ有効
    /// （置いたプラグインは既定で有効。実測）。読めない・壊れていれば確かめられないので false。
    static func isPluginEnabled(_ name: String, home: String = NSHomeDirectory()) -> Bool {
        let url = agyConfigURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        guard let data = FileManager.default.contents(atPath: url.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let plugins = obj["plugins"] else { return true }
        guard let map = plugins as? [String: Any] else { return false }
        guard let entry = map[name] else { return true }
        guard let fields = entry as? [String: Any] else { return false }
        return (fields["enabled"] as? Bool) ?? true
    }

    // MARK: - スクリプト

    private static func verifyScript(home: String) -> Bool {
        isReadOnlyDirectory(scriptDirectory(home: home).path, entries: [scriptURL(home: home).lastPathComponent])
            && isFile(scriptURL(home: home).path, mode: 0o500, contents: script)
    }

    private static func installScript(home: String) throws {
        let dir = scriptDirectory(home: home)
        try makeWritable(dir)
        guard PrivateDirectory.ensure(dir.path) else { throw CocoaError(.fileWriteNoPermission) }
        // スクリプトのほかに置かれたものは消す（フォルダの中身はスクリプトだけ）。
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name != scriptURL(home: home).lastPathComponent {
            try remove(dir.appendingPathComponent(name))
        }
        try write(script, to: scriptURL(home: home), mode: 0o500)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    }

    /// 以前の置き場（`~/.buddyos/agy-hooks/.agents/hooks.json`。`--add-dir` で読ませていた）を消す。
    private static func removeLegacy(home: String) throws {
        let dir = scriptDirectory(home: home)
        let legacy = dir.appendingPathComponent(".agents", isDirectory: true)
        var st = stat()
        guard lstat(legacy.path, &st) == 0 else { return }
        try makeWritable(dir)
        try remove(legacy)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    }

    // MARK: - プラグイン

    /// 置いてあるプラグインのうち中身が正しいものを使う。無ければ新しい名前で置き直す。
    /// 正しくないもの・2 つ目以降は消す（同じ hook が 2 度走らないように）。
    private static func ensurePlugin(home: String) throws -> Installation {
        let root = pluginsRoot(home: home)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter(isPluginName).sorted()
        var chosen: Installation?
        for name in names {
            let candidate = Installation(home: home, pluginName: name)
            if chosen == nil, verifyPlugin(candidate) {
                chosen = candidate
            } else {
                try remove(candidate.pluginDirectory)
            }
        }
        if let chosen { return chosen }

        let install = Installation(home: home, pluginName: pluginPrefix + randomSuffix())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = install.pluginDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try write(manifest(pluginName: install.pluginName), to: install.manifestURL, mode: 0o400)
        try write(hooksConfig(pluginName: install.pluginName, scriptPath: install.scriptURL.path),
                  to: install.hooksURL, mode: 0o400)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        return install
    }

    private static func verifyPlugin(_ install: Installation) -> Bool {
        isReadOnlyDirectory(install.pluginDirectory.path, entries: ["plugin.json", "hooks.json"])
            && isFile(install.manifestURL.path, mode: 0o400, contents: manifest(pluginName: install.pluginName))
            && isFile(install.hooksURL.path, mode: 0o400,
                      contents: hooksConfig(pluginName: install.pluginName, scriptPath: install.scriptURL.path))
    }

    /// プラグインのほかに agy が hook を読む場所（ワークスペースとその親の `.agents/hooks.json`、全体設定の
    /// `hooks.json`、ほかのプラグインの `hooks.json`）に、この名前が書かれているか。あればそのファイルの場所。
    /// JSON として読めればキーと文字列を（`\u` の書き換えも解いて）、読めなければ文字のまま、大文字小文字を区別せずに比べる。
    static func nameClash(_ name: String, home: String, workspaces: [String]) -> String? {
        var files: [String] = []
        for w in workspaces where !w.isEmpty {
            var dir = (w as NSString).standardizingPath
            while true {
                files.append((dir as NSString).appendingPathComponent(".agents/hooks.json"))
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir || parent.isEmpty { break }
                dir = parent
            }
        }
        files.append(URL(fileURLWithPath: home).appendingPathComponent(".gemini/config/hooks.json").path)
        let root = pluginsRoot(home: home)
        for other in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where other != name {
            files.append(root.appendingPathComponent(other).appendingPathComponent("hooks.json").path)
        }
        let needle = name.lowercased()
        var seen = Set<String>()
        for file in files where seen.insert(file).inserted {
            guard let data = FileManager.default.contents(atPath: file) else { continue }
            if mentions(data, needle) { return file }
        }
        return nil
    }

    private static func mentions(_ data: Data, _ needle: String) -> Bool {
        if let text = String(data: data, encoding: .utf8), text.lowercased().contains(needle) { return true }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return false }
        func visit(_ v: Any) -> Bool {
            if let s = v as? String { return s.lowercased().contains(needle) }
            if let d = v as? [String: Any] {
                return d.contains { $0.key.lowercased().contains(needle) || visit($0.value) }
            }
            if let a = v as? [Any] { return a.contains(where: visit) }
            return false
        }
        return visit(obj)
    }

    static func isPluginName(_ name: String) -> Bool {
        guard name.hasPrefix(pluginPrefix) else { return false }
        let suffix = name.dropFirst(pluginPrefix.count)
        return suffix.count == 16 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func randomSuffix() -> String {
        SymmetricKey(size: SymmetricKeySize(bitCount: 64)).withUnsafeBytes { Data($0) }
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ファイルの確かめと書き込み

    /// 自分の持ち物の本物のフォルダ（リンクでない）で、権限がちょうど 0500、中身が entries だけか。
    private static func isReadOnlyDirectory(_ path: String, entries: Set<String>) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(),
              (st.st_mode & 0o7777) == 0o500,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return Set(names) == entries
    }

    /// 自分の持ち物の普通のファイル（リンクでない）で、権限がちょうど mode、SHA-256 が contents と同じか。
    private static func isFile(_ path: String, mode: mode_t, contents: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              (st.st_mode & 0o7777) == mode,
              let data = FileManager.default.contents(atPath: path) else { return false }
        return sha256(data) == sha256(Data(contents.utf8))
    }

    private static func write(_ text: String, to url: URL, mode: Int) throws {
        let fm = FileManager.default
        var st = stat()
        if lstat(url.path, &st) == 0 { try fm.removeItem(at: url) }
        guard fm.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// 読み取り専用にしてあるフォルダを、書き直す間だけ書けるようにする（リンクならそのものは触らない）。
    private static func makeWritable(_ dir: URL) throws {
        var st = stat()
        guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// 読み取り専用のフォルダごと消す（中のフォルダも書けるようにしてから）。リンクはリンクだけ消す。
    private static func remove(_ url: URL) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            try makeWritable(url)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                let child = url.appendingPathComponent(name)
                var cst = stat()
                if lstat(child.path, &cst) == 0, (cst.st_mode & S_IFMT) == S_IFDIR { try remove(child) }
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// ターンの間、hook のファイルとフォルダを見張る。書き込み・権限の変更・消去・名前の変更・
/// リンクの変化のどれかがあれば onChange を 1 度だけ呼ぶ（読むだけでは呼ばない）。
/// 見張りを付けられないもの（無い・開けない）があれば isComplete が false になる。
final class AgyHookTamperWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fired = false
    private(set) var isComplete = true

    /// - executables: 実行されるファイル（hook のスクリプト）。実行するだけで属性の変化（ATTRIB）が届く
    ///   （実測）ので、これだけは属性の変化を見ない。中身の書き換えは write / extend で、権限を変えてからの
    ///   差し替え・消去は、フォルダの属性の変化（chmod）と書き込みで見つかる。
    init(paths: [String],
         executables: Set<String> = [],
         onChange: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "buddyos.agy-hook.watch")
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { isComplete = false; continue }
            var mask: DispatchSource.FileSystemEvent = [.write, .extend, .attrib, .delete, .rename, .link, .revoke]
            if executables.contains(path) { mask.remove(.attrib) }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: mask, queue: queue)
            source.setEventHandler { [weak self] in self?.trip(onChange) }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    /// 書き換えを見つけたか。
    var tripped: Bool { lock.withLock { fired } }

    private func trip(_ onChange: @Sendable () -> Void) {
        let first = lock.withLock { () -> Bool in
            if fired { return false }
            fired = true
            return true
        }
        if first { onChange() }
    }

    func cancel() {
        let all = lock.withLock { () -> [DispatchSourceFileSystemObject] in
            let v = sources; sources = []; return v
        }
        all.forEach { $0.cancel() }
    }

    deinit { cancel() }
}

/// hook に返す判断。
///
/// 既定は「iPhone に聞く」。名前で列挙した読み取り専用の道具だけをそのまま通し、書き込みは作業フォルダの
/// 中だけ通す（作業フォルダの `.agents` / `.gemini` / `.git` は hook や設定の置き場なので聞く）。~/.buddyos（hook のスクリプト）・~/.gemini（許可リストと hook を登録するプラグイン）・~/Library・シェルの設定ファイルなどへの
/// 書き込みは、作業フォルダの中にあっても拒否する（agy 自身が承認の仕組みを書き換えられないように）。
enum AgyApprovalPolicy {
    enum Verdict: Equatable {
        case allow
        case deny(String)
        /// iPhone に聞く。title / detail は承認カードの見出しと本文。
        case ask(title: String, detail: String?)
    }

    /// 中身を読むだけ・agy の中だけで完結する道具（ファイルの場所は下の確認を通す）。
    static let readOnlyTools: Set<String> = [
        "view_file", "view_file_outline", "view_code_item", "list_dir", "find_by_name", "grep_search",
        "codebase_search", "search_web", "command_status", "read_terminal", "manage_task"
    ]
    /// ファイルを書き換える道具。作業フォルダの中だけ通す。
    static let writeTools: Set<String> = [
        "write_to_file", "replace_file_content", "multi_replace_file_content",
        "write_file", "edit_file", "create_file", "delete_file"
    ]

    /// ホームの中で、書き込みを必ず拒否する場所（ホームからの相対）。
    static let protectedHomePaths = [
        ".buddyos", ".gemini", "Library", ".ssh", ".claude", ".codex", ".local/bin",
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout",
        ".bashrc", ".bash_profile", ".bash_login", ".profile"
    ]

    /// - Parameters:
    ///   - allow / deny: agy の許可・拒否リスト（ターンの開始時に一度だけ読んだもの）。
    ///   - cwd: このチャットの作業フォルダ。書き込みはこの中だけ通す（nil なら聞く）。
    ///   - bridgeMcp: このセッションに Bridge の MCP（buddyos）を渡しているか。渡していれば buddyos の道具の呼び出しと、
    ///     agy がその道具の説明を読むこと（~/.gemini/antigravity-cli/mcp/buddyos/ の中）は通す。頼む道具は Bridge が
    ///     呼んだ側のチャットに承認カードを出すので、ここで重ねて聞かない。
    static func verdict(toolName: String, args: [String: Any], allow: [String], deny: [String],
                        cwd: String? = nil, home: String = NSHomeDirectory(), bridgeMcp: Bool = false) -> Verdict {
        if bridgeMcp {
            // agy 1.4.2 の MCP の呼び出しは `call_mcp_tool`（args の ServerName / ToolName）。2026-10-18 実測。
            if toolName == "call_mcp_tool", args["ServerName"] as? String == MainAgentWorkspace.mcpServerName {
                return .allow
            }
            if readOnlyTools.contains(toolName) {
                let schemas = normalize(home, cwd: nil, home: home) + "/.gemini/antigravity-cli/mcp/" + MainAgentWorkspace.mcpServerName
                let paths = candidatePaths(in: args, cwd: cwd, home: home)
                if !paths.isEmpty, paths.allSatisfy({ isInside($0, root: schemas) }) { return .allow }
            }
        }
        if toolName == "run_command" {
            return commandVerdict(args: args, allow: allow, deny: deny, cwd: cwd, home: home)
        }
        let paths = candidatePaths(in: args, cwd: cwd, home: home)
        if readOnlyTools.contains(toolName) {
            // 鍵や設定（~/.buddyos 等）を読むときは聞く（読んだ中身を外へ送られうる）。
            if let p = paths.first(where: { isProtected($0, home: home) }) {
                return .ask(title: "Antigravity: 設定ファイルを読む", detail: p)
            }
            return .allow
        }
        if writeTools.contains(toolName) {
            if let p = paths.first(where: { isProtected($0, home: home) }) {
                return .deny("BuddyOS の設定や鍵・シェルの設定ファイルは書き換えられません（\(p)）。")
            }
            if let root = cwd.map({ normalize($0, cwd: nil, home: home) }), !paths.isEmpty,
               paths.allSatisfy({ isInside($0, root: root) && !touchesAutoRunConfig($0, root: root) }) {
                return .allow
            }
            return .ask(title: "Antigravity: ファイルを書き換え",
                        detail: paths.isEmpty ? summarize(args) : paths.joined(separator: "\n"))
        }
        // 知らない道具（MCP など）は聞く。
        return .ask(title: "Antigravity: \(toolName.isEmpty ? "操作" : toolName)", detail: summarize(args))
    }

    /// コマンド実行。許可リストにあるものは通し、拒否リストにあるものは止める。それ以外は iPhone に聞く。
    private static func commandVerdict(args: [String: Any], allow: [String], deny: [String],
                                       cwd: String?, home: String) -> Verdict {
        let command = (args["CommandLine"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .allow }
        let segments = splitCommand(command)
        if segments.contains(where: { matches($0, rules: deny) }) {
            return .deny("agy の拒否リストにあるコマンドです。")
        }
        let ask = Verdict.ask(title: "Antigravity: コマンドを実行", detail: command)
        // 置き換え（$( ) や ``）・リダイレクト（> <）・find の -exec などを含むと、許可リストの
        // 前方一致では何が書き換わるか分からないので、許可リストでは通さない。
        guard !hasUncheckedEffects(command) else { return ask }
        // 承認の hook や agy の設定に触れるコマンド（`agy plugin disable` 等）は、許可リストにあっても聞く。
        guard !touchesApprovalConfig(command) else { return ask }
        // 鍵や設定の場所で走らせるコマンドも通さない。
        if let runIn = args["Cwd"] as? String, !runIn.isEmpty,
           isProtected(normalize(runIn, cwd: cwd, home: home), home: home) {
            return ask
        }
        if !segments.isEmpty, segments.allSatisfy({ matches($0, rules: allow) }) {
            return .allow
        }
        return ask
    }

    /// 許可リストの前方一致では判断できない書き方を含むか。
    static func hasUncheckedEffects(_ command: String) -> Bool {
        if command.contains("$(") || command.contains("`") || command.contains(">") || command.contains("<") {
            return true
        }
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let risky: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprintf", "-fls"]
        return words.contains { risky.contains($0) }
    }

    /// 承認の hook（~/.buddyos/agy-hooks・~/.gemini/config/plugins）や agy の設定を書き換えうるコマンドか。
    /// プラグインを止める `agy plugin …`、置き場を名指しするもの、hook の名前を含むもの、
    /// ワークスペースの hook（`.agents/hooks.json`。同じ名前の hook でプラグインを上書きできる）に触れるもの。
    static func touchesApprovalConfig(_ command: String) -> Bool {
        let lower = command.lowercased()
        let needles = [".gemini", ".buddyos", ".agents", "hooks.json", AgyApprovalHook.pluginPrefix]
        if needles.contains(where: { lower.contains($0) }) { return true }
        return splitCommand(command).contains { segment in
            let words = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let i = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "agy" }) else { return false }
            return words.dropFirst(i + 1).first.map { ["plugin", "plugins", "install", "update"].contains($0) } ?? false
        }
    }

    /// args の中のファイルの場所らしい値（キーに path / file / dir / uri を含む、または / ~ file:// で始まる文字列）。
    static func candidatePaths(in args: [String: Any], cwd: String?, home: String) -> [String] {
        var out: [String] = []
        func visit(_ key: String, _ value: Any) {
            if let s = value as? String {
                let k = key.lowercased()
                let looksLikePath = s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("file://")
                let pathKey = ["path", "file", "dir", "uri"].contains { k.contains($0) }
                if !s.isEmpty, looksLikePath || pathKey, !s.contains("\n") {
                    out.append(normalize(s, cwd: cwd, home: home))
                }
            } else if let d = value as? [String: Any] {
                for (k, v) in d { visit(k, v) }
            } else if let a = value as? [Any] {
                for v in a { visit(key, v) }
            }
        }
        for (k, v) in args { visit(k, v) }
        return out
    }

    /// ~ と file:// と相対パスを解き、.. とシンボリックリンクを畳んだ絶対パスにする
    /// （作業フォルダの中のリンクで ~/.buddyos を指す、のような抜け道を塞ぐ）。
    static func normalize(_ raw: String, cwd: String?, home: String) -> String {
        var p = raw
        if p.hasPrefix("file://"), let url = URL(string: p) { p = url.path }
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        if !p.hasPrefix("/") { p = ((cwd ?? home) as NSString).appendingPathComponent(p) }
        p = (p as NSString).standardizingPath
        // 存在する一番深い親までシンボリックリンクを解き、残りを足し直す。
        var existing = p
        var rest: [String] = []
        let fm = FileManager.default
        while existing != "/", !fm.fileExists(atPath: existing) {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var resolved = (existing as NSString).resolvingSymlinksInPath
        for part in rest { resolved = (resolved as NSString).appendingPathComponent(part) }
        return resolved
    }

    /// 作業フォルダの中でも、書くと承認を経ずに後で動くもの（agy が読む `.agents/hooks.json`、
    /// `.gemini` の設定、git の hook や設定）の置き場。ここへの書き込みは通さず iPhone に聞く。
    static let autoRunConfigDirs: Set<String> = [".agents", ".gemini", ".git"]

    /// root（作業フォルダ）からの相対の途中に autoRunConfigDirs のフォルダがあるか。
    static func touchesAutoRunConfig(_ path: String, root: String) -> Bool {
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(r + "/") else { return false }
        return path.dropFirst(r.count + 1).split(separator: "/").contains { autoRunConfigDirs.contains(String($0)) }
    }

    static func isInside(_ path: String, root: String) -> Bool {
        let r = root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == r || path.hasPrefix(r + "/")
    }

    static func isProtected(_ path: String, home: String) -> Bool {
        let h = normalize(home, cwd: nil, home: home)
        return protectedHomePaths.contains { isInside(path, root: (h as NSString).appendingPathComponent($0)) }
    }

    private static func summarize(_ args: [String: Any]) -> String? {
        guard !args.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.count > 600 ? String(text.prefix(600)) + "…" : text
    }

    /// `a && b | c; d` を個々のコマンドに分ける（引用符の中の区切りは分けない）。
    static func splitCommand(_ command: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        let chars = Array(command)
        var i = 0
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                cur.append(c)
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
                cur.append(c)
            } else if c == ";" || c == "\n" {
                flush()
            } else if c == "&" || c == "|" {
                // && / || / | を区切りにする（& 単体の背景実行も区切り）。
                if i + 1 < chars.count, chars[i + 1] == c { i += 1 }
                flush()
            } else {
                cur.append(c)
            }
            i += 1
        }
        flush()
        return out
    }

    /// agy の規則（`command(ls)`、`command(git status)`、`command(regex:npm run (build|test))`）に合うか。
    /// 規則の値は「そのコマンドで始まる」（単語の区切りまで）、`regex:` は先頭から一致。
    static func matches(_ command: String, rules: [String]) -> Bool {
        for rule in rules {
            guard rule.hasPrefix("command("), rule.hasSuffix(")") else { continue }
            let body = String(rule.dropFirst("command(".count).dropLast())
            if body == "*" { return true }
            if body.hasPrefix("regex:") {
                let pattern = "^(?:" + String(body.dropFirst("regex:".count)) + ")"
                if command.range(of: pattern, options: .regularExpression) != nil { return true }
            } else if command == body || command.hasPrefix(body + " ") {
                return true
            }
        }
        return false
    }

    /// agy の許可・拒否リスト。読めなければ空（= すべて iPhone に聞く）。
    static func loadRules(path: String = NSHomeDirectory() + "/.gemini/antigravity-cli/settings.json") -> (allow: [String], deny: [String]) {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let perms = obj["permissions"] as? [String: Any] else { return ([], []) }
        return ((perms["allow"] as? [String]) ?? [], (perms["deny"] as? [String]) ?? [])
    }
}

/// hook の問い合わせ（トークン → その agy を起動したセッション）。トークンはターンごとに作り、終われば消す。
actor AgyApprovalRegistry {
    static let shared = AgyApprovalRegistry()

    typealias Handler = @Sendable (Data) async -> Data

    private var handlers: [String: Handler] = [:]

    func register(_ handler: @escaping Handler) -> String {
        let token = UUID().uuidString + UUID().uuidString
        handlers[token] = handler
        return token
    }

    func unregister(_ token: String) {
        handlers.removeValue(forKey: token)
    }

    /// 知らないトークンなら nil（404）。
    func handle(token: String, body: Data) async -> Data? {
        guard let handler = handlers[token] else { return nil }
        return await handler(body)
    }
}
