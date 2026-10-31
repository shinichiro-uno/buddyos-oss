import Foundation
import IOKit.pwr_mgt

/// エージェントの run（生成）が進行中の間だけ、Mac のアイドルスリープを抑止する。
///
/// 背景: ブリッジ上のエージェントプロセスはスマホ切断後も走り続ける設計だが、
/// その間に Mac がアイドルスリープすると OS がプロセスを止め、run も完了プッシュも
/// 死ぬ。launchd の KeepAlive は「復帰後の再起動」しかしないので、走行中は
/// そもそも寝かせないのが正しい（競合の ccpocket はこれを実装していない）。
///
/// `kIOPMAssertionTypePreventUserIdleSystemSleep` を生成中だけ保持し、全 run が
/// 終わったら解放する。電源アサーションはプロセス終了時に OS が自動解放する。
final class SleepGuard: @unchecked Sendable {
    static let shared = SleepGuard()

    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0
    private var held = false
    /// アサーション希望中のオーナー集合。SessionHub ("sessions") と
    /// BridgeCronScheduler ("cron") が独立に setActive を呼んでも互いを解放しないための参照管理。
    private var owners: Set<String> = []

    private init() {}

    /// active=true でオーナーを登録、false で解除。オーナーが 1 つでも残っていれば
    /// アサーションを保持し続ける。冪等。
    func setActive(_ active: Bool, owner: String = "sessions",
                   reason: String = "BuddyOS: agent run in progress") {
        lock.lock()
        defer { lock.unlock() }
        if active {
            owners.insert(owner)
        } else {
            owners.remove(owner)
        }
        let wantHeld = !owners.isEmpty
        if wantHeld && !held {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionID = id
                held = true
                WebSocketServer.wslog("[SleepGuard] sleep prevented (owners=\(owners.sorted().joined(separator: ",")))")
            } else {
                WebSocketServer.wslog("[SleepGuard] assertion failed rc=\(result)")
            }
        } else if !wantHeld && held {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            held = false
            WebSocketServer.wslog("[SleepGuard] sleep allowed (idle)")
        }
    }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return held
    }
}
