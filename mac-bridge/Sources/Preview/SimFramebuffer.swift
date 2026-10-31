import CoreImage
import Foundation
import IOSurface
import ObjectiveC

/// シミュレータの画面の描画面（IOSurface）を CoreSimulator から直接読む。
///
/// `simctl io screenshot` はプロセス起動とファイル入出力で 1 枚 0.5 秒前後かかり、2fps 程度しか出ない。
/// こちらは Xcode が使う非公開の CoreSimulator / SimulatorKit を dlopen し、端末の画面ポートの
/// `framebufferSurface` を読むので、1 枚数 ms で取れる（Simulator.app を開いていなくても取れる。画面収録の許可も要らない）。
/// 非公開 API なので、取れない環境（Xcode の仕様変更など）では nil を返し、呼び出し側は simctl の方式に戻る。
/// 2026-10-10 に Xcode 26 / iOS 26.0 のシミュレータで確認。
final class SimFramebuffer: @unchecked Sendable {
    enum Capture {
        case frame(Data)
        /// 前回から画面が変わっていない（seed が同じ）
        case unchanged
        /// 画面が取れない（シミュレータが止まった等）
        case unavailable
    }

    private let screen: NSObject
    private var lastSeed: UInt32?
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private init(screen: NSObject) {
        self.screen = screen
    }

    /// CoreSimulator / SimulatorKit を読み込めたか（SimHID も使う）。
    static let loaded: Bool = {
        guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil else { return false }
        _ = dlopen(developerDir + "/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW)
        return NSClassFromString("SimServiceContext") != nil
    }()

    static let developerDir: String = {
        if let d = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !d.isEmpty { return d }
        if let out = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 2.0)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty {
            return out
        }
        return "/Applications/Xcode.app/Contents/Developer"
    }()

    /// udid の端末（CoreSimulator の SimDevice）。udid が空なら起動中の最初の 1 台。見つからなければ nil。
    static func device(udid: String) -> NSObject? {
        guard loaded,
              let ctxClass = NSClassFromString("SimServiceContext") as? NSObject.Type,
              let ctx = ctxClass.perform(NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"), with: developerDir, with: nil)?
                .takeUnretainedValue() as? NSObject,
              let set = ctx.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?.takeUnretainedValue() as? NSObject,
              let devices = set.value(forKey: "devices") as? [NSObject]
        else { return nil }
        let target = udid.isEmpty ? nil : udid.uppercased()
        return devices.first(where: { d in
            if let target { return (d.value(forKey: "UDID") as? NSUUID)?.uuidString == target }
            // udid 無し（booted 指定）は起動中の最初の 1 台。state 3 = Booted。
            return (d.value(forKey: "state") as? Int) == 3
        })
    }

    /// udid の端末の画面を開く。取れなければ nil。
    static func open(udid: String) -> SimFramebuffer? {
        guard let device = device(udid: udid),
              let io = device.value(forKey: "io") as? NSObject,
              let ports = io.value(forKey: "ioPorts") as? [NSObject]
        else { return nil }
        // 画面ポートは複数ある（外部ディスプレイ用など）。描画面を持っているものを選ぶ。
        // ポートは別プロセスの代理オブジェクトなので KVC ではなく perform で呼ぶ。
        let fb = NSSelectorFromString("framebufferSurface")
        for port in ports {
            guard let descriptor = port.perform(NSSelectorFromString("descriptor"))?.takeUnretainedValue() as? NSObject,
                  descriptor.responds(to: fb),
                  descriptor.perform(fb) != nil
            else { continue }
            return SimFramebuffer(screen: descriptor)
        }
        return nil
    }

    /// 今の画面を JPEG にする。長辺を maxSide に縮める（0 なら縮めない）。
    func capture(maxSide: Int, quality: Double) -> Capture {
        guard let obj = screen.perform(NSSelectorFromString("framebufferSurface"))?.takeUnretainedValue() else { return .unavailable }
        let surface = unsafeBitCast(obj, to: IOSurface.self)
        let seed = IOSurfaceGetSeed(surface)
        if seed == lastSeed { return .unchanged }
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        guard w > 0, h > 0 else { return .unavailable }
        var image = CIImage(ioSurface: surface)
        let longSide = max(w, h)
        if maxSide > 0, longSide > maxSide {
            let s = CGFloat(maxSide) / CGFloat(longSide)
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        guard let data = Self.ci.jpegRepresentation(of: image, colorSpace: Self.colorSpace, options: options) else { return .unavailable }
        lastSeed = seed
        return .frame(data)
    }
}
