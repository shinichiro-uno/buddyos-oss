import XCTest
@testable import BridgeApp

final class CodexReasoningOptionsTests: XCTestCase {
    func testUsesSelectedModelsVendorCapabilities() {
        let data = Data(#"{"models":[{"slug":"advanced","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"},{"effort":"ultra"}]},{"slug":"small","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}"#.utf8)
        XCTAssertEqual(CodexReasoningOptions.parse(data, model: "advanced"), ["low", "max", "ultra"])
        XCTAssertEqual(CodexReasoningOptions.parse(data, model: "small"), ["low", "high"])
        XCTAssertEqual(CodexReasoningOptions.parse(data, model: "unknown"), ["low", "medium", "high", "xhigh"])
    }

    func testMalformedCacheDoesNotInventMaxOrUltraSupport() {
        XCTAssertEqual(CodexReasoningOptions.parse(Data("invalid".utf8), model: "advanced"), ["low", "medium", "high", "xhigh"])
    }

    func testEffortsTravelInAgentInfoMetadata() {
        let event = SessionEvent.agentInfoResult(agentId: "codex", model: "advanced", provider: "openai", supportedReasoningEfforts: ["low", "max", "ultra"], reasoningEffort: "ultra")
        XCTAssertEqual(event.metadata?["supportedReasoningEfforts"], "low,max,ultra")
        XCTAssertEqual(event.metadata?["reasoningEffort"], "ultra")
    }
}
