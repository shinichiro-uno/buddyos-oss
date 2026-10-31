import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import BridgeApp

final class ProjectFileAccessTests: XCTestCase {
    private var base: URL!
    private var home: String!
    private var project: URL!
    private var outside: URL!

    /// 1x1 の PNG。
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("pfa-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = base.appendingPathComponent("home").path
        project = base.appendingPathComponent("home/proj")
        outside = base.appendingPathComponent("home/other")
        for dir: URL in [project.appendingPathComponent("docs"), outside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try png.write(to: project.appendingPathComponent("docs/shot.png"))
        try png.write(to: outside.appendingPathComponent("secret.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testRelativeAndAbsoluteInsideCwd() throws {
        let rel = try ProjectFileAccess.resolve(path: "docs/shot.png", cwd: project.path, projects: [], home: home).get()
        XCTAssertEqual(rel.path, project.appendingPathComponent("docs/shot.png").path)
        let abs = try ProjectFileAccess.resolve(path: project.path + "/docs/shot.png", cwd: project.path, projects: [], home: home).get()
        XCTAssertEqual(abs, rel)
        // file:// と ./ も受け付ける
        XCTAssertNoThrow(try ProjectFileAccess.resolve(path: "file://" + rel.path, cwd: nil, projects: [project.path], home: home).get())
        XCTAssertNoThrow(try ProjectFileAccess.resolve(path: "./docs/shot.png", cwd: project.path, projects: [], home: home).get())
    }

    func testRejectsOutsideAndTraversal() {
        XCTAssertEqual(ProjectFileAccess.resolve(path: "../other/secret.png", cwd: project.path, projects: [], home: home), .failure(.outsideProject))
        XCTAssertEqual(ProjectFileAccess.resolve(path: outside.path + "/secret.png", cwd: project.path, projects: [], home: home), .failure(.outsideProject))
        // 相対パスは cwd が無いと解決しない
        XCTAssertEqual(ProjectFileAccess.resolve(path: "docs/shot.png", cwd: nil, projects: [project.path], home: home), .failure(.badPath))
        XCTAssertEqual(ProjectFileAccess.resolve(path: "docs/none.png", cwd: project.path, projects: [], home: home), .failure(.notFound))
    }

    func testSymlinkPointingOutsideIsRejected() throws {
        let link = project.appendingPathComponent("docs/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("secret.png"))
        XCTAssertEqual(ProjectFileAccess.resolve(path: "docs/link.png", cwd: project.path, projects: [], home: home), .failure(.outsideProject))
    }

    func testHomeAndRootAreNotProjects() {
        XCTAssertNil(ProjectFileAccess.acceptableRoot(home, home: home))
        XCTAssertNil(ProjectFileAccess.acceptableRoot("/", home: home))
        XCTAssertNil(ProjectFileAccess.acceptableRoot(base.path, home: home))  // ホームより上
        XCTAssertNil(ProjectFileAccess.acceptableRoot("/System/Library", home: home))
        XCTAssertNil(ProjectFileAccess.acceptableRoot("relative/dir", home: home))
        XCTAssertNotNil(ProjectFileAccess.acceptableRoot(project.path, home: home))
        // cwd にホームを渡しても、ホーム直下の別フォルダは読めない
        XCTAssertEqual(ProjectFileAccess.resolve(path: outside.path + "/secret.png", cwd: home, projects: [], home: home), .failure(.outsideProject))
    }

    func testOnlyRealImagesAreReturned() throws {
        try Data("not an image".utf8).write(to: project.appendingPathComponent("docs/fake.png"))
        try Data("hello".utf8).write(to: project.appendingPathComponent("docs/notes.txt"))
        XCTAssertEqual(ProjectFileAccess.loadImage(path: "docs/fake.png", cwd: project.path, projects: [], maxPixels: nil, home: home), .failure(.notImage))
        XCTAssertEqual(ProjectFileAccess.loadImage(path: "docs/notes.txt", cwd: project.path, projects: [], maxPixels: nil, home: home), .failure(.notImage))
        let ok = try ProjectFileAccess.loadImage(path: "docs/shot.png", cwd: project.path, projects: [], maxPixels: nil, home: home).get()
        XCTAssertEqual(ok.mime, "image/png")
        XCTAssertEqual(ok.data, png)
    }

    func testSniff() {
        XCTAssertEqual(ProjectFileAccess.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0]), ext: "jpg"), "image/jpeg")
        XCTAssertEqual(ProjectFileAccess.sniff(Data("GIF89a".utf8), ext: "gif"), "image/gif")
        XCTAssertEqual(ProjectFileAccess.sniff(Data("RIFF\0\0\0\0WEBPVP8 ".utf8), ext: "webp"), "image/webp")
        XCTAssertEqual(ProjectFileAccess.sniff(Data("\0\0\0\u{18}ftypheic".utf8), ext: "heic"), "image/heic")
        XCTAssertEqual(ProjectFileAccess.sniff(Data("<?xml version=\"1.0\"?><svg xmlns=\"\"/>".utf8), ext: "svg"), "image/svg+xml")
        XCTAssertNil(ProjectFileAccess.sniff(Data("<svg/>".utf8), ext: "png"))
    }

    func testDownscalesLargeImages() throws {
        let big = try makePNG(width: 800, height: 400)
        let out = ProjectFileAccess.transcodeIfNeeded(.init(data: big, mime: "image/png"), maxPixels: 200)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(out.data as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 200)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 100)
        // 小さいものはそのまま
        XCTAssertEqual(ProjectFileAccess.transcodeIfNeeded(.init(data: png, mime: "image/png"), maxPixels: 200).data, png)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }
}
