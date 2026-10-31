import Foundation

/// 作業ディレクトリの git ブランチ名を読む（iOS の最下部バー表示用）。
/// git 管理外・git 不在・失敗はすべて nil を返す（静かに失敗）。
enum GitInfoReader {
    private static let candidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git"
    ]

    /// これを超えたら諦めて nil（ネットワークドライブや巨大なリポジトリで git が戻らないことがある）。
    static let timeout: TimeInterval = 5

    /// `git -C <cwd> rev-parse --abbrev-ref HEAD` のブランチ名。detached HEAD は "HEAD"。
    /// 子プロセスの待ちは協調スレッドの外で行い、timeout で打ち切る。
    static func branch(cwd: String?) async -> String? {
        guard let cwd, !cwd.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: cwd) else { return nil }
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        guard let r = await ProcessRunner.runAsync(bin, ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"], timeout: timeout),
              !r.timedOut, r.status == 0,
              let raw = String(data: r.stdout, encoding: .utf8) else { return nil }
        let branch = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }
}
