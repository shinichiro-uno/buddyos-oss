import AppKit
import CoreImage
import EFQRCode
import Foundation

enum QRCodeGenerator {
    static func make(payload: String) -> NSImage? {
        guard let cg = EFQRCode.generate(for: payload) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 320, height: 320))
    }

    static func ascii(payload: String) -> String? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        let w = cg.width, h = cg.height
        guard let provider = cg.dataProvider,
              let cfdata = provider.data,
              let ptr = CFDataGetBytePtr(cfdata) else { return nil }
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        var out = ""
        for y in stride(from: 0, to: h, by: 2) {
            for x in 0..<w {
                let topDark = ptr[y * bpr + x * bpp] < 128
                let botDark = y + 1 < h ? ptr[(y + 1) * bpr + x * bpp] < 128 : false
                switch (topDark, botDark) {
                case (true, true):  out += "\u{2588}"
                case (true, false): out += "\u{2580}"
                case (false, true): out += "\u{2584}"
                case (false, false): out += " "
                }
            }
            out += "\n"
        }
        return out
    }

    /// v3 では ~/.buddyos/pairing-qr.png を書かない（QR は 10 分・1 回きりの招待で、画面にだけ出す。
    /// spec/PROTOCOL-v3.md §6）。起動時に古い PNG（apiKey 入り）を消す。
    static func removePNG(filename: String = "pairing-qr.png") {
        try? FileManager.default.removeItem(at: BuddyPaths.root.appendingPathComponent(filename))
    }
}
