import Foundation
import XCTest
@testable import BridgeApp

/// shared/preview-auth-vectors.json（プレビューの認証の約束を値で固定したもの）と同じ答えになるか。
/// windows-bridge（previewAuthVectors.test.ts）と desktop（previewAuthVectors.test.ts）も同じファイルを読む。
final class PreviewAuthVectorTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Lists: Decodable {
            let allow: [[String]]
            let deny: [[String]]
        }
        struct Paths: Decodable {
            let sessionAuth: [String]
            let guarded: [String]
        }
        struct ValidTarget: Decodable {
            let raw: String
            let param: String
        }
        struct Targets: Decodable {
            let valid: [ValidTarget]
            let invalid: [String]
        }
        struct Session: Decodable {
            let tokenLength: Int
            let idleTTLSeconds: Int
            let absoluteTTLSeconds: Int
            let maxSessions: Int
            let wellFormed: [String]
            let malformed: [String]
        }
        struct Location: Decodable {
            let location: String
            let port: Int
            let prefix: String
            let expected: String
        }
        let desktopOrigin: String
        let host: Lists
        let origin: Lists
        let paths: Paths
        let targets: Targets
        let session: Session
        let iframeSandbox: String
        let proxySandboxPolicy: String
        let pageContentSecurityPolicy: String
        let defaultWebPorts: [Int]
        let locationRewrite: [Location]
    }

    private static let vectorsURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/preview-auth-vectors.json")

    private func load() throws -> Vectors {
        try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.vectorsURL))
    }

    func testHostAndOrigin() throws {
        let v = try load()
        XCTAssertEqual(BridgeRequestGuard.desktopOrigin, v.desktopOrigin)
        for h in v.host.allow { XCTAssertTrue(BridgeRequestGuard.allowedHost(h), "\(h)") }
        for h in v.host.deny { XCTAssertFalse(BridgeRequestGuard.allowedHost(h), "\(h)") }
        for o in v.origin.allow { XCTAssertTrue(BridgeRequestGuard.allowedOrigin(o), "\(o)") }
        for o in v.origin.deny { XCTAssertFalse(BridgeRequestGuard.allowedOrigin(o), "\(o)") }
    }

    func testSessionAuthPaths() throws {
        let v = try load()
        for p in v.paths.sessionAuth { XCTAssertTrue(BridgeRequestGuard.isPreviewSessionPath(p), p) }
        for p in v.paths.guarded { XCTAssertFalse(BridgeRequestGuard.isPreviewSessionPath(p), p) }
    }

    func testTargets() throws {
        let v = try load()
        for t in v.targets.valid { XCTAssertEqual(PreviewTarget(param: t.raw)?.param, t.param, t.raw) }
        for raw in v.targets.invalid { XCTAssertNil(PreviewTarget(param: raw), raw) }
    }

    func testSessionLimitsAndTokenShape() throws {
        let v = try load()
        XCTAssertEqual(Int(PreviewSessionStore.idleTTL), v.session.idleTTLSeconds)
        XCTAssertEqual(Int(PreviewSessionStore.absoluteTTL), v.session.absoluteTTLSeconds)
        XCTAssertEqual(PreviewSessionStore.maxSessions, v.session.maxSessions)
        XCTAssertEqual(PreviewSessionStore().create(target: .web(port: 5173)).count, v.session.tokenLength)
        for t in v.session.wellFormed { XCTAssertTrue(PreviewSessionStore.isWellFormed(t), t) }
        for t in v.session.malformed { XCTAssertFalse(PreviewSessionStore.isWellFormed(t), t) }
    }

    func testPolicies() throws {
        let v = try load()
        XCTAssertEqual(PreviewRoutes.webIframeSandbox, v.iframeSandbox)
        XCTAssertEqual(WebProxy.sandboxPolicy, v.proxySandboxPolicy)
        XCTAssertEqual(PreviewRoutes.pageContentSecurityPolicy, v.pageContentSecurityPolicy)
    }

    func testDefaultWebPorts() throws {
        let v = try load()
        let saved = ProcessInfo.processInfo.environment["BUDDYOS_PREVIEW_WEB_PORTS"]
        unsetenv("BUDDYOS_PREVIEW_WEB_PORTS")
        defer { if let saved { setenv("BUDDYOS_PREVIEW_WEB_PORTS", saved, 1) } }
        XCTAssertEqual(PreviewRoutes.candidateWebPorts(), Set(v.defaultWebPorts))
    }

    func testLocationRewrite() throws {
        let v = try load()
        for c in v.locationRewrite {
            XCTAssertEqual(WebProxy.rewriteLocation(c.location, port: c.port, prefix: c.prefix), c.expected, c.location)
        }
    }
}
