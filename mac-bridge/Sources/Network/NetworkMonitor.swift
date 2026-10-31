import Foundation
import Network

/// ネットワーク経路の変化 (Wi-Fi↔有線、ネット切替、スリープ復帰など) を監視し、
/// 実質的な変化があったらコールバックする。
///
/// Bridge が起動時に張った古い経路の relay 接続を持ち続け、iOS から
/// 「応答しない、Bridge 再起動で治る」状態になるのを防ぐための土台。
final class NetworkMonitor {
    /// 経路変化から onChange を呼ぶまでの待ち (debounce)。onChange は最後の変化からこの秒数後に届く。
    static let debounceInterval: TimeInterval = 2.0

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "buddyos.network-monitor")
    private let onChange: () -> Void
    private var lastSignature: String?
    private var debounce: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // 経路の指紋 (満足状態 + 利用可能 interface 種別)。実質的な変化のみ拾う。
            let sig = "\(path.status)|"
                + path.availableInterfaces.map { "\($0.type)" }.sorted().joined(separator: ",")
            guard sig != self.lastSignature else { return }
            let isInitial = self.lastSignature == nil
            self.lastSignature = sig
            // 開始直後の初回通知は変化ではない。起動時（wake 復旧の stop→start 後も）の relay 起動・
            // 登録・QR 更新は BridgeServer.start() が済ませているので、ここで relay を張り直させない。
            // 初回が unsatisfied でも署名は記録するので、その後 satisfied になれば従来どおり発火する。
            guard !isInitial else { return }
            // 切替直後は IP が安定しないので少し待ってから発火する (debounce)。
            self.debounce?.cancel()
            // オフライン (unsatisfied) 中の republish は古い広告を撒き直すだけで無意味。
            // 経路が satisfied になった時のみ発火する (unsatisfied→satisfied 復帰は
            // signature が変わるので取りこぼさない)。
            guard path.status == .satisfied else { return }
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            self.debounce = work
            self.queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        monitor.cancel()
    }
}
