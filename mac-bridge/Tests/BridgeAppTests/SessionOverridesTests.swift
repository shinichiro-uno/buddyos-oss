import XCTest
@testable import BridgeApp

final class SessionOverridesTests: XCTestCase {
    func testWithoutMarkerLeavesSessionUntouched() {
        // 印の無い送信（古いアプリ・デスクトップ）は上書きを触らない。
        XCTAssertNil(SessionOverrides(metadata: nil))
        XCTAssertNil(SessionOverrides(metadata: ["chatModel": "opus"]))
    }

    func testMarkerWithoutValuesResetsToDefault() {
        XCTAssertEqual(SessionOverrides(metadata: ["chatOverrides": "1"]), SessionOverrides.none)
    }

    func testReadsValuesAndNormalizesMode() {
        let o = SessionOverrides(metadata: [
            "chatOverrides": "1",
            "chatModel": " claude-opus-5-5 ",
            "chatProvider": "anthropic",
            "chatEffort": "xhigh",
            "chatMode": "Plan",
            "chatEmpty": "",
        ])
        XCTAssertEqual(o, SessionOverrides(model: "claude-opus-5-5", provider: "anthropic",
                                           reasoningEffort: "xhigh", mode: "plan"))
    }
}

final class ClaudeSettingsModeTests: XCTestCase {
    func testCliDefaultModeMapsToBuddyLabels() {
        XCTAssertEqual(ClaudeCodeAdapter.modeLabel(forCliMode: "plan"), "plan")
        XCTAssertEqual(ClaudeCodeAdapter.modeLabel(forCliMode: "acceptEdits"), "edit")
        XCTAssertEqual(ClaudeCodeAdapter.modeLabel(forCliMode: "default"), "auto")
        XCTAssertEqual(ClaudeCodeAdapter.modeLabel(forCliMode: "auto"), "auto")
        XCTAssertEqual(ClaudeCodeAdapter.modeLabel(forCliMode: "bypassPermissions"), "dangerous")
        XCTAssertNil(ClaudeCodeAdapter.modeLabel(forCliMode: nil))
    }

    func testBuddyLabelsRoundTripThroughCliFlag() {
        for label in ClaudeCodeAdapter.validModes {
            XCTAssertEqual(ClaudeCodeAdapter.modeLabel(forCliMode: ClaudeCodeAdapter.permissionFlag(forMode: label)), label)
        }
    }
}
