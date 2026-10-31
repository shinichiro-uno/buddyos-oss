import AppKit
import Foundation

/// macOS sleep/wake events are not guaranteed to produce a distinct NWPath
/// signature. Listen to workspace power notifications so the bridge can refresh
/// advertisements and verify the local listener after the lid opens.
final class PowerEventMonitor {
    private let onWillSleep: () -> Void
    private let onDidWake: () -> Void
    private var tokens: [NSObjectProtocol] = []

    init(onWillSleep: @escaping () -> Void, onDidWake: @escaping () -> Void) {
        self.onWillSleep = onWillSleep
        self.onDidWake = onDidWake
    }

    func start() {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onWillSleep()
            }
        )
        tokens.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onDidWake()
            }
        )
        tokens.append(
            center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onDidWake()
            }
        )
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }

    deinit {
        stop()
    }
}
