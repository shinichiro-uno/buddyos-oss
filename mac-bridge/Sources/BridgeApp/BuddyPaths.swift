import Foundation

/// BuddyOS のファイルの置き場所（既定は ~/.buddyos）。
/// api-key / bridge-id / device-token / e2e-key や会話の台帳など、動いている Bridge が使うファイルが並ぶ。
///
/// テスト（XCTest を読み込んだプロセス）では、プロセスごとの一時フォルダに切り替える。
/// 本物の ~/.buddyos を書き換えると、同じ Mac で動いている Bridge の device-token や bridge-id を
/// 壊してしまうため（`HOME` を変えても NSHomeDirectory は追従しないので、HOME では隔離できない）。
/// 1 つのテストだけ別の場所を使いたいときは `setOverride(_:)` で差し替え、終わったら nil に戻す。
///
/// ~/.buddyos を直接組み立てている箇所はまだ残っている。テストが書き込むものから順にここへ寄せる。
enum BuddyPaths {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrideRoot: URL?

    /// ~/.buddyos（テスト中は一時フォルダ）。
    static var root: URL {
        lock.lock()
        let override = overrideRoot
        lock.unlock()
        if let override { return override }
        if isTesting { return testRoot }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buddyos", isDirectory: true)
    }

    /// テスト用の差し替え。nil で既定に戻す。
    static func setOverride(_ url: URL?) {
        lock.lock()
        overrideRoot = url
        lock.unlock()
    }

    /// Bridge 本体は XCTest を読み込まない。読み込まれていればテストの中で動いている。
    static let isTesting: Bool = NSClassFromString("XCTestCase") != nil

    /// テストの間だけ使うフォルダ。プロセスが終わるときに消す。
    private static let testRoot: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddyos-tests-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        atexit { try? FileManager.default.removeItem(at: BuddyPaths.testRoot) }
        return dir
    }()
}
