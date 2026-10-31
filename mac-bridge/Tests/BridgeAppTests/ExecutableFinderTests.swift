import XCTest
@testable import BridgeApp

final class ExecutableFinderTests: XCTestCase {
    func testCandidateDirsIncludeVersionManagers() throws {
        let home = NSTemporaryDirectory() + "ef-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.nvm/versions/node/v20.1.0/bin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home + "/.nvm/versions/node/v22.3.0/bin", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let dirs = ExecutableFinder.candidateDirs(home: home)
        XCTAssertTrue(dirs.contains(home + "/.volta/bin"))
        XCTAssertTrue(dirs.contains(home + "/.bun/bin"))
        let i22 = try XCTUnwrap(dirs.firstIndex(of: home + "/.nvm/versions/node/v22.3.0/bin"))
        let i20 = try XCTUnwrap(dirs.firstIndex(of: home + "/.nvm/versions/node/v20.1.0/bin"))
        XCTAssertLessThan(i22, i20, "新しい Node が先")
    }

    func testFindsShellBinary() {
        XCTAssertNotNil(ExecutableFinder.locate("ls"))
        XCTAssertNil(ExecutableFinder.locate("definitely-not-a-real-binary-xyz"))
        XCTAssertNil(ExecutableFinder.locate("a; rm -rf /"), "コマンド名として不正な文字列は拒否")
    }
}
