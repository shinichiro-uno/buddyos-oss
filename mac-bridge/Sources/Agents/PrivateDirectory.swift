import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 自分だけが使うフォルダ（0700・自分の所有・シンボリックリンクでない）を用意する。
///
/// 実行ファイルや設定を置くキャッシュを、全ユーザーが書ける場所（/tmp など）や他人が先に作った
/// フォルダに置くと、別のユーザーが中身を仕込んで、こちらの権限で実行させられる。
enum PrivateDirectory {
    /// path を 0700 で用意し、使ってよければ true。
    /// 既にあるときは、本物のフォルダ（シンボリックリンクではない）で所有者が自分であることを確かめ、
    /// 他人に開いた権限が付いていれば 0700 に絞る。
    @discardableResult
    static func ensure(_ path: String) -> Bool {
        let fm = FileManager.default
        var st = stat()
        if lstat(path, &st) != 0 {
            guard errno == ENOENT else { return false }
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                return false
            }
            guard lstat(path, &st) == 0 else { return false }
        }
        return isPrivate(path, st)
    }

    /// 既にある path が自分専用のフォルダか（シンボリックリンクでない・所有者が自分）。
    /// グループや他人の権限が付いていれば 0700 に絞る（絞れなければ false）。
    static func isPrivate(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return isPrivate(path, st)
    }

    private static func isPrivate(_ path: String, _ st: stat) -> Bool {
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        if (st.st_mode & 0o077) != 0 {
            guard chmod(path, 0o700) == 0 else { return false }
        }
        return true
    }
}
