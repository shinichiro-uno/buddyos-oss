import Vapor
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// プロジェクト（作業フォルダ）の中の画像ファイルを端末へ返す。
///
///   GET /files/image?path=<絶対 or 作業フォルダからの相対パス>&cwd=<作業フォルダ>&max=<長辺 px>
///
/// エージェントの返事に出てくる `docs/shot.png` のようなパスを、チャットの中でそのまま見るためのもの。
/// 認証は他の HTTP と同じ（BridgeAuth の Principal。Bearer か ?apiKey=）。経路は Paseo の中継（E2E）だけ。
/// 返すのは次をすべて満たすときだけ:
///   - 登録済みのプロジェクト（~/.buddyos/projects.json）か、渡された cwd の中にある（シンボリックリンクは解決してから判定）
///   - cwd・プロジェクトは「/」やホームそのもの、システムのフォルダではない
///   - 中身の先頭のバイトが画像（拡張子だけでは信じない）で、大きさが上限以下
/// `max` を付けると長辺をその大きさまで縮めて返す（サムネイル用。中継の量を減らす）。
/// HEIC / AVIF は古い Android で読めないので、常に JPEG / PNG に変えて返す。
enum ProjectFileRoutes {
    static func register(app: Application) {
        app.get("files", "image") { req async throws -> Response in
            try BridgeAuth.requireAny(req)
            let path = (try? req.query.get(String.self, at: "path")) ?? ""
            let cwd = try? req.query.get(String.self, at: "cwd")
            let maxPixels = (try? req.query.get(Int.self, at: "max")).map { min(max($0, 32), 4096) }
            let projects = ProjectRegistry.list().map(\.path)

            let result = await Task.detached(priority: .userInitiated) {
                ProjectFileAccess.loadImage(path: path, cwd: cwd, projects: projects, maxPixels: maxPixels)
            }.value
            switch result {
            case .success(let image):
                TrafficMeter.shared.record("files.image.out", bytes: image.data.count)
                var headers: HTTPHeaders = [
                    "Content-Type": image.mime,
                    "Cache-Control": "private, max-age=60",
                    "X-Content-Type-Options": "nosniff",
                    ProjectFileAccess.markerHeader: "1",
                ]
                if image.mime == "image/svg+xml" {
                    // SVG は文書なので、万一ブラウザで開かれてもスクリプトや外部の読み込みを動かさない。
                    headers.add(name: "Content-Security-Policy", value: "default-src 'none'; style-src 'unsafe-inline'; sandbox")
                }
                return Response(status: .ok, headers: headers, body: .init(data: image.data))
            case .failure(let failure):
                // 端末はこのヘッダの有無で「ファイルが無い」と「Bridge が古くてこの入口が無い」を見分ける。
                let body = #"{"error":"\#(failure.rawValue)"}"#
                return Response(
                    status: failure.status,
                    headers: ["Content-Type": "application/json", "Cache-Control": "no-store", ProjectFileAccess.markerHeader: "1"],
                    body: .init(string: body)
                )
            }
        }
    }
}

/// パスの判定と画像の読み出し（HTTP から切り離してテストできるようにしてある）。
enum ProjectFileAccess {
    static let markerHeader = "X-BuddyOS-Files"
    /// 元のファイルの上限。中継を通すので、写真の原寸程度までにする。
    static let maxFileBytes = 30 * 1024 * 1024

    enum Failure: String, Error, Equatable {
        case badPath = "bad_path"
        case outsideProject = "outside_project"
        case notFound = "not_found"
        case tooLarge = "too_large"
        case notImage = "not_image"

        var status: HTTPResponseStatus {
            switch self {
            case .badPath: return .badRequest
            case .outsideProject: return .forbidden
            case .notFound: return .notFound
            case .tooLarge: return .payloadTooLarge
            case .notImage: return .unsupportedMediaType
            }
        }
    }

    struct Image: Equatable {
        let data: Data
        let mime: String
    }

    /// 画像として扱う拡張子。中身の確認（sniff）と両方を通ったものだけ返す。
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "avif", "svg"]

    /// システムのフォルダ。ここをプロジェクトとして扱わない。
    private static let systemPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/dev", "/cores"]

    static func loadImage(path: String, cwd: String?, projects: [String], maxPixels: Int?,
                          home: String = NSHomeDirectory()) -> Result<Image, Failure> {
        let url: URL
        switch resolve(path: path, cwd: cwd, projects: projects, home: home) {
        case .success(let u): url = u
        case .failure(let f): return .failure(f)
        }
        let ext = url.pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { return .failure(.notImage) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return .failure(.notFound) }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxFileBytes else { return .failure(.tooLarge) }
        guard let data = try? Data(contentsOf: url) else { return .failure(.notFound) }
        guard let mime = sniff(data, ext: ext) else { return .failure(.notImage) }
        return .success(transcodeIfNeeded(Image(data: data, mime: mime), maxPixels: maxPixels))
    }

    /// `path`（絶対・~・cwd からの相対）を実体のパスに直し、許された場所の中にあるかを確かめる。
    static func resolve(path rawPath: String, cwd: String?, projects: [String],
                        home: String = NSHomeDirectory()) -> Result<URL, Failure> {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("file://") {
            path = URL(string: path)?.path ?? String(path.dropFirst("file://".count))
        }
        guard !path.isEmpty, !path.contains("\0") else { return .failure(.badPath) }
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        }

        let roots = ([cwd].compactMap { $0 } + projects).compactMap { acceptableRoot($0, home: home) }
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            // 相対パスは渡された cwd を基準にする（cwd が使えないなら解決できない）。
            guard let cwd, let base = acceptableRoot(cwd, home: home) else { return .failure(.badPath) }
            candidate = base.appendingPathComponent(path)
        }
        let standardized = candidate.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else { return .failure(.notFound) }
        let target = standardized.resolvingSymlinksInPath()
        guard roots.contains(where: { isInside(target.path, root: $0.path) }) else { return .failure(.outsideProject) }
        return .success(target)
    }

    /// プロジェクトとして扱ってよいフォルダなら、シンボリックリンクを解決した URL を返す。
    /// 「/」・ホームそのもの・ホームより上・システムのフォルダ・ボリュームの直下は認めない。
    static func acceptableRoot(_ raw: String, home: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return nil }
        let expanded = trimmed.hasPrefix("~/") ? home + trimmed.dropFirst() : trimmed
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let p = url.path
        let homeResolved = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        if p == "/" || p == homeResolved || isInside(homeResolved, root: p) { return nil }
        if systemPrefixes.contains(where: { p == $0 || isInside(p, root: $0) }) { return nil }
        let components = url.pathComponents  // ["/", "Users", "me", "proj"]
        if components.count < 3 { return nil }
        if components.count >= 2, components[1] == "Volumes", components.count < 4 { return nil }
        return url
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// 先頭のバイトから画像の種類を決める。画像でなければ nil。
    static func sniff(_ data: Data, ext: String) -> String? {
        let b = [UInt8](data.prefix(16))
        func starts(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + sig.count && Array(b[offset..<offset + sig.count]) == sig
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if starts(Array("GIF8".utf8)) { return "image/gif" }
        if starts(Array("RIFF".utf8)), starts(Array("WEBP".utf8), at: 8) { return "image/webp" }
        if starts(Array("BM".utf8)) { return "image/bmp" }
        if starts(Array("ftyp".utf8), at: 4), b.count >= 12 {
            let brand = String(decoding: b[8..<12], as: UTF8.self)
            if ["avif", "avis"].contains(brand) { return "image/avif" }
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"].contains(brand) { return "image/heic" }
        }
        if ext == "svg" {
            let head = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
            if head.contains("<svg") { return "image/svg+xml" }
        }
        return nil
    }

    /// `maxPixels` より大きいラスター画像は縮め、HEIC / AVIF は JPEG / PNG に変える。
    /// 変換できなければ元のまま返す。
    static func transcodeIfNeeded(_ image: Image, maxPixels: Int?) -> Image {
        let mustConvert = image.mime == "image/heic" || image.mime == "image/avif"
        guard image.mime != "image/svg+xml", mustConvert || maxPixels != nil else { return image }
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return image }
        let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let longest = max(width, height)
        let limit = maxPixels ?? 4096
        // 縮める必要がなく、そのまま読める形式なら元のファイルを返す（GIF のアニメもそのまま）。
        if !mustConvert, longest > 0, longest <= limit { return image }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(limit, longest > 0 ? longest : limit),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return image }
        let hasAlpha: Bool = {
            switch cg.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return image }
        CGImageDestinationAddImage(dest, cg, hasAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return image }
        return Image(data: out as Data, mime: hasAlpha ? "image/png" : "image/jpeg")
    }
}
