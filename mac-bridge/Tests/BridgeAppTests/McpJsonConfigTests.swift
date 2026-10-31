import XCTest
@testable import BridgeApp

/// mcpServers 形式の JSON（buddy / Cursor / Antigravity）の読み取り。
final class McpJsonConfigTests: XCTestCase {
    func testReadsUrlKeysOfEachCliAndSkipsDisabled() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let json = #"""
        {"mcpServers":{
          "stitch":{"serverUrl":"https://stitch.example/mcp","headers":{"X":"y"}},
          "cursorish":{"url":"https://c.example/mcp"},
          "local":{"command":"npx","args":["-y","pkg"]},
          "off":{"command":"x","disabled":true}
        }}
        """#
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        let list = McpService.listJsonMcpServers(path: path)
        XCTAssertEqual(list.map(\.name), ["cursorish", "local", "stitch"])
        XCTAssertEqual(list.first { $0.name == "stitch" }?.transport, "https://stitch.example/mcp", "agy は serverUrl")
        XCTAssertEqual(list.first { $0.name == "local" }?.transport, "npx -y pkg")
    }
}
