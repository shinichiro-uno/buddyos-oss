import Darwin
import Foundation

/// Bridge を 1 台の Mac で 1 つだけにする鍵。
///
/// 以前は待ち受けの番号（8765）が鍵の代わりだった。番号を固定しない（ふさがっていれば別の番号で
/// 起動する）ようにしたので、同じ ~/.buddyos の鍵を使う Bridge が 2 つ動いて iPhone の接続や
/// 子プロセスを奪い合わないよう、~/.buddyos/bridge.lock を flock で押さえる。
/// 持ち主のプロセスが終われば（落ちても）OS が外すので、残骸のせいで起動できなくなることはない。
enum InstanceLock {
    /// 鍵を持ち続けるためのファイル記述子（プロセスが終わるまで閉じない）。
    nonisolated(unsafe) private static var heldFD: Int32 = -1

    /// 鍵を取る。ほかの Bridge が持っていれば false。
    /// 鍵のファイルを作れないとき（権限など）は、起動を止めないよう true を返す。
    static func acquire() -> Bool {
        switch tryLock(path: KeyStore.instanceLockURL.path) {
        case .held: return false
        case .unavailable: return true
        case .acquired(let fd):
            heldFD = fd
            KeyStore.writeBridgePid(getpid())
            return true
        }
    }

    enum Result: Equatable {
        case acquired(fd: Int32)
        case held
        case unavailable
    }

    /// path を flock で押さえる。取れたらそのファイル記述子（閉じると鍵が外れる）。
    static func tryLock(path: String) -> Result {
        let fd = open(path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return .unavailable }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return .held
        }
        // 調べやすいように、鍵のファイルにも持ち主の pid を書いておく。
        let line = "\(getpid())\n"
        ftruncate(fd, 0)
        _ = line.withCString { write(fd, $0, strlen($0)) }
        return .acquired(fd: fd)
    }
}
