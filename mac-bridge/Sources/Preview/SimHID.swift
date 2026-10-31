import CoreGraphics
import Foundation
import ObjectiveC

/// シミュレータへタッチ・ボタン・キーを直接送る（idb を使わない）。
///
/// Simulator.app と同じく、SimulatorKit の `SimDeviceLegacyHIDClient` に Indigo の HID メッセージを渡す。
/// メッセージは SimulatorKit の `IndigoHIDMessageFor...` で作る。タッチの座標の欄だけは、Xcode 26 の
/// `IndigoHIDMessageForMouseNSEvent` が正しく埋めないので書き直す（idb と同じやり方）。
/// 非公開 API なので、形が合わない環境（Xcode の仕様変更など）では送らずに失敗を返す。
/// 2026-10-20 に Xcode 26.0.1 / iOS 26 の iPhone 17 Pro で確認。
final class SimHID: @unchecked Sendable {
    private typealias ButtonFn = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer?
    private typealias MouseFn = @convention(c) (UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGPoint>?, Int32, Int32, Bool) -> UnsafeMutableRawPointer?
    private typealias KeyFn = @convention(c) (Int32, Int32) -> UnsafeMutableRawPointer?
    private typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    private typealias SendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue?, (@convention(block) (NSError?) -> Void)?) -> Void

    private struct API {
        let button: ButtonFn
        let mouse: MouseFn
        let key: KeyFn
        let cls: AnyClass
        let initImp: InitFn
        let sendImp: SendFn
    }

    private static let initSel = NSSelectorFromString("initWithDevice:error:")
    private static let sendSel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")

    private static let api: API? = {
        guard SimFramebuffer.loaded,
              let sk = dlopen(SimFramebuffer.developerDir + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW),
              let button = dlsym(sk, "IndigoHIDMessageForButton"),
              let mouse = dlsym(sk, "IndigoHIDMessageForMouseNSEvent"),
              let key = dlsym(sk, "IndigoHIDMessageForKeyboardArbitrary"),
              let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") ?? NSClassFromString("SimDeviceLegacyHIDClient"),
              let initImp = class_getMethodImplementation(cls, initSel),
              let sendImp = class_getMethodImplementation(cls, sendSel),
              class_getInstanceMethod(cls, initSel) != nil,
              class_getInstanceMethod(cls, sendSel) != nil
        else { return nil }
        return API(
            button: unsafeBitCast(button, to: ButtonFn.self),
            mouse: unsafeBitCast(mouse, to: MouseFn.self),
            key: unsafeBitCast(key, to: KeyFn.self),
            cls: cls,
            initImp: unsafeBitCast(initImp, to: InitFn.self),
            sendImp: unsafeBitCast(sendImp, to: SendFn.self)
        )
    }()

    // Indigo の値（idb の FBSimulatorIndigoHID と同じ）。
    private static let down: Int32 = 1
    private static let up: Int32 = 2
    private static let targetTouchScreen: Int32 = 0x32
    private static let targetHardware: Int32 = 0x33
    private static let buttonHome: Int32 = 0
    /// HID の Keyboard ページの使用番号。
    static let keyReturn: Int32 = 0x28
    static let keyLeftCommand: Int32 = 0xE3
    static let keyV: Int32 = 0x19

    // タッチのメッセージの形（Xcode 26）。見出し 0x20 バイトの後に 0xA0 バイトの組が 2 つ並び、
    // それぞれの x / y の割合（double）が組の 0x1C / 0x24 にある。
    private static let touchInnerSize: UInt32 = 0xA0
    private static let touchEventType: UInt8 = 2
    private static let touchRatioOffsets = [0x3C, 0xDC]

    private let client: AnyObject
    private let queue = DispatchQueue(label: "buddyos.simhid")
    /// 画面の大きさ（ポイント）。
    let points: (w: Int, h: Int)

    private init(client: AnyObject, points: (w: Int, h: Int)) {
        self.client = client
        self.points = points
    }

    /// udid の端末に HID のつなぎ口を開く。開けなければ nil（呼び出し側は失敗として返す）。
    static func open(udid: String) -> SimHID? {
        guard let api, let device = SimFramebuffer.device(udid: udid),
              (device.value(forKey: "state") as? Int) == 3,
              let alloc = (api.cls as? NSObject.Type)?.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }
        var error: NSError?
        guard let client = api.initImp(alloc, initSel, device, &error) else {
            print("[SimHID] open failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        return SimHID(client: client, points: screenPoints(device) ?? (390, 844))
    }

    /// 端末の種類から画面の大きさ（ポイント）を出す（ピクセル ÷ 倍率）。
    private static func screenPoints(_ device: NSObject) -> (w: Int, h: Int)? {
        guard let type = device.value(forKey: "deviceType") as? NSObject,
              let size = (type.value(forKey: "mainScreenSize") as? NSValue)?.sizeValue,
              let scale = (type.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue, scale > 0
        else { return nil }
        let w = Int((size.width / scale).rounded())
        let h = Int((size.height / scale).rounded())
        return w > 0 && h > 0 ? (w, h) : nil
    }

    // MARK: 操作（どれも呼んだスレッドを止める。actor やイベントループの外で呼ぶ）

    /// x / y は画面に対する割合（0〜1）。
    func tap(x: Double, y: Double) -> Bool {
        touch(Self.down, x, y) && pause(0.06) && touch(Self.up, x, y)
    }

    /// 始点から終点まで duration 秒かけて指を動かす。
    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) -> Bool {
        let steps = max(4, Int(duration / 0.016))
        guard touch(Self.down, x1, y1) else { return false }
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            // 押したまま動かす（指を置いたまま座標だけ変えたタッチを送る）。
            guard pause(duration / Double(steps)), touch(Self.down, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t) else {
                _ = touch(Self.up, x2, y2)
                return false
            }
        }
        return touch(Self.up, x2, y2)
    }

    func home() -> Bool {
        guard let api = Self.api else { return false }
        return send(api.button(Self.buttonHome, Self.down, Self.targetHardware))
            && pause(0.05)
            && send(api.button(Self.buttonHome, Self.up, Self.targetHardware))
    }

    /// キーを押して離す。modifiers は押している間ずっと押さえておくキー（⌘ など）。
    func key(_ code: Int32, modifiers: [Int32] = []) -> Bool {
        guard let api = Self.api else { return false }
        for m in modifiers { guard send(api.key(m, Self.down)), pause(0.02) else { return false } }
        let ok = send(api.key(code, Self.down)) && pause(0.02) && send(api.key(code, Self.up))
        for m in modifiers.reversed() { _ = pause(0.02); _ = send(api.key(m, Self.up)) }
        return ok
    }

    private func touch(_ direction: Int32, _ x: Double, _ y: Double) -> Bool {
        guard let api = Self.api else { return false }
        var point = CGPoint(x: x, y: y)
        guard let message = api.mouse(&point, nil, Self.targetTouchScreen, direction, false) else { return false }
        // 形が想定と違えば（Xcode の仕様変更）座標を書かずに捨てる。違う場所へ書くと壊れたメッセージを送ってしまう。
        guard malloc_size(message) >= Self.touchRatioOffsets.last! + 16,
              message.load(fromByteOffset: 0x18, as: UInt32.self) == Self.touchInnerSize,
              message.load(fromByteOffset: 0x1C, as: UInt8.self) == Self.touchEventType
        else {
            print("[SimHID] unexpected touch message layout; not sending")
            free(message)
            return false
        }
        for offset in Self.touchRatioOffsets {
            Self.write(x, to: message + offset)
            Self.write(y, to: message + offset + 8)
        }
        return send(message)
    }

    /// 4 バイト境界にしか揃っていない場所へ double を書く。
    private static func write(_ value: Double, to pointer: UnsafeMutableRawPointer) {
        var v = value
        withUnsafeBytes(of: &v) { pointer.copyMemory(from: $0.baseAddress!, byteCount: 8) }
    }

    /// メッセージを送り、届くまで待つ（最大 2 秒）。メッセージは送ったあと SimulatorKit が解放する。
    private func send(_ message: UnsafeMutableRawPointer?) -> Bool {
        guard let api = Self.api, let message else { return false }
        let done = DispatchSemaphore(value: 0)
        let failed = ErrorBox()
        api.sendImp(client, Self.sendSel, message, true, queue, { error in
            if let error { failed.set(error) }
            done.signal()
        })
        guard done.wait(timeout: .now() + 2) == .success else {
            print("[SimHID] send timed out")
            return false
        }
        if let error = failed.get() {
            print("[SimHID] send failed: \(error.localizedDescription)")
            return false
        }
        return true
    }

    private func pause(_ seconds: Double) -> Bool {
        if seconds > 0 { usleep(useconds_t(seconds * 1_000_000)) }
        return true
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: NSError?
        func set(_ e: NSError) { lock.lock(); error = e; lock.unlock() }
        func get() -> NSError? { lock.lock(); defer { lock.unlock() }; return error }
    }
}
