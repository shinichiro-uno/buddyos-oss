import XCTest
@testable import BridgeApp

final class ProjectRegistryTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    func testAddKeepsPositionAndNormalizes() {
        ProjectRegistry.add(path: "/tmp/a/", name: nil, at: url)
        ProjectRegistry.add(path: "/tmp/b", name: "B", at: url)
        // 既にあるものは名前だけ変え、位置は動かさない
        let items = ProjectRegistry.add(path: "/tmp/a", name: "A2", at: url)
        XCTAssertEqual(items.map(\.path), ["/tmp/b", "/tmp/a"])
        XCTAssertEqual(items.last?.name, "A2")
        XCTAssertEqual(ProjectRegistry.list(at: url).first?.name, "B")
    }

    func testRemoveAndReorder() {
        for p in ["/x/1", "/x/2", "/x/3"] { ProjectRegistry.add(path: p, name: nil, at: url) }
        XCTAssertEqual(ProjectRegistry.list(at: url).map(\.path), ["/x/3", "/x/2", "/x/1"])
        // 渡さなかったものは後ろに残る
        XCTAssertEqual(ProjectRegistry.reorder(paths: ["/x/1"], at: url).map(\.path), ["/x/1", "/x/3", "/x/2"])
        XCTAssertEqual(ProjectRegistry.remove(path: "/x/3/", at: url).map(\.path), ["/x/1", "/x/2"])
        XCTAssertEqual(ProjectRegistry.list(at: url).first?.name, "1")
    }

    func testWindowsPathsAreKept() {
        XCTAssertEqual(ProjectRegistry.normalize("C:\\work\\app"), "C:\\work\\app")
    }
}
