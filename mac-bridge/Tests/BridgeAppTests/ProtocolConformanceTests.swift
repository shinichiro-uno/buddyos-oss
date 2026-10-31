import XCTest
@testable import BridgeApp

/// shared/protocol.json（種別の正本）と mac-bridge のコードが一致しているかを見る。
/// ずれたら protocol.json も直す。
final class ProtocolConformanceTests: XCTestCase {
    private static let protocolURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // BridgeAppTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mac-bridge/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("shared/protocol.json")

    private func loadProtocol() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.protocolURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// platforms に "mac" を含むキーの集合。
    private func macKeys(_ table: [String: Any]?) -> Set<String> {
        var out: Set<String> = []
        for (key, value) in table ?? [:] {
            guard let entry = value as? [String: Any],
                  let platforms = entry["platforms"] as? [String], platforms.contains("mac") else { continue }
            out.insert(key)
        }
        return out
    }

    private func assertSame(_ actual: Set<String>, _ expected: Set<String>, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let missing = expected.subtracting(actual).sorted()
        let extra = actual.subtracting(expected).sorted()
        XCTAssertTrue(missing.isEmpty && extra.isEmpty,
                      "\(what): mac に無い = \(missing)、protocol.json に mac が無い = \(extra)", file: file, line: line)
    }

    func testEventTypesMatchProtocol() throws {
        let proto = try loadProtocol()
        let expected = macKeys(proto["eventTypes"] as? [String: Any])
        let actual = Set(SessionEventType.allCases.map(\.rawValue))
        XCTAssertFalse(expected.isEmpty)
        assertSame(actual, expected, "eventTypes")
    }

    func testHealthHasRequiredKeys() throws {
        let proto = try loadProtocol()
        let health = try XCTUnwrap(proto["health"] as? [String: Any])
        let required = try XCTUnwrap(health["required"] as? [String])
        let agent = AgentDescriptor(id: "echo", displayName: "Echo", capabilities: AgentCapabilities(),
                                    installed: true, configured: true, version: nil)
        let response = WebSocketServer.healthResponse(agents: [agent], aliveSessions: 0, bridgeId: "test-bridge", e2ePub: "pub",
                                                      relay: RelayHealthInfo(configured: false, hint: BridgeConfig.relayHint))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        let keys = Set(json.keys)
        XCTAssertTrue(Set(required).isSubset(of: keys), "足りない: \(Set(required).subtracting(keys).sorted())")
        // 任意のキーは mac が送ると書いたものだけ。
        let optional = macKeys(health["optional"] as? [String: Any])
        assertSame(keys.subtracting(required), optional, "health.optional")
        // agents[] の要素のキー。
        let agentJSON = try XCTUnwrap((json["agents"] as? [[String: Any]])?.first)
        let agentFields = macKeys(health["agentFields"] as? [String: Any])
        XCTAssertTrue(Set(agentJSON.keys).isSubset(of: agentFields),
                      "agentFields に無い: \(Set(agentJSON.keys).subtracting(agentFields).sorted())")
    }

    func testCapabilityKeysMatchProtocol() throws {
        let proto = try loadProtocol()
        let caps = try XCTUnwrap(proto["capabilities"] as? [String: Any])
        let expected = macKeys(caps["keys"] as? [String: Any])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AgentCapabilities())) as? [String: Any])
        assertSame(Set(json.keys), expected, "capabilities.keys")
    }

    /// 送る前に起こせる adapter（Claude Code）だけが warm を申告する。申告の無い agent にアプリは session_warm を送らない。
    func testWarmCapability() {
        XCTAssertTrue(AgentRegistry.capabilities(of: ClaudeCodeAdapter()).warm)
        XCTAssertFalse(AgentRegistry.capabilities(of: EchoAdapter()).warm)
        XCTAssertFalse(AgentRegistry.capabilities(of: CodexHistoryAdapter()).warm)
    }

    /// 止められる adapter だけが interrupt を申告する（Windows の supportsInterrupt と同じ考え）。
    func testInterruptCapability() {
        XCTAssertTrue(AgentRegistry.capabilities(of: ClaudeCodeAdapter()).interrupt)
        XCTAssertTrue(AgentRegistry.capabilities(of: CodexHistoryAdapter()).interrupt)
        XCTAssertTrue(AgentRegistry.capabilities(of: HeadlessCliAdapter(profile: .cursor, executable: "/usr/bin/true")).interrupt)
        XCTAssertFalse(AgentRegistry.capabilities(of: EchoAdapter()).interrupt, "EchoSession は interrupt() を持たない")
    }
}
