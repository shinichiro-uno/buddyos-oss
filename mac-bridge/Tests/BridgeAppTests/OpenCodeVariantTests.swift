import XCTest
@testable import BridgeApp

/// opencode の variant（モデルごとの思考の強さ）を Effort として扱う。
final class OpenCodeVariantTests: XCTestCase {
    func testVariantsAreRememberedPerModelInEffortOrder() {
        OpenCodeAdapter.rememberVariants(providers: [
            ["id": "zai-coding-plan", "models": [
                "glm-5.3-flash": ["id": "glm-5.3-flash", "variants": ["max": [:], "low": [:], "high": [:]]],
                "glm-plain": ["id": "glm-plain"]
            ]]
        ])
        XCTAssertEqual(OpenCodeAdapter.variants(provider: "zai-coding-plan", model: "glm-5.3-flash"), ["low", "high", "max"])
        XCTAssertEqual(OpenCodeAdapter.variants(provider: "zai-coding-plan", model: "glm-plain"), [], "variant の無いモデルは Effort を出さない")
    }
}
