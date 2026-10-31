import XCTest
@testable import BridgeApp

final class OpenCodeTerminalsTests: XCTestCase {
    func testMarksNewestRootSessionPerLiveDirectory() {
        func s(_ id: String, _ dir: String, _ updated: Double, parent: String? = nil) -> [String: Any] {
            var d: [String: Any] = ["id": id, "directory": dir, "time": ["updated": updated]]
            if let parent { d["parentID"] = parent }
            return d
        }
        let list = [
            s("a-old", "/work/a", 100), s("a-new", "/work/a", 200), s("a-child", "/work/a", 300, parent: "a-new"),
            s("b-only", "/work/b", 50), s("c-live-less", "/work/c", 999),
        ]
        let ids = OpenCodeTerminals.terminalSessionIds(in: list, liveDirs: ["/work/a", "/work/b"])
        XCTAssertEqual(ids, ["a-new", "b-only"], "サブエージェントと、ターミナルの無いディレクトリは対象外")
        XCTAssertTrue(OpenCodeTerminals.terminalSessionIds(in: list, liveDirs: []).isEmpty)
    }
}

final class OpenCodeTitleTests: XCTestCase {
    func testPlaceholderTitles() {
        XCTAssertTrue(OpenCodeAdapter.isPlaceholderTitle("New session - 2026-10-02T17:23:28.276Z"))
        XCTAssertTrue(OpenCodeAdapter.isPlaceholderTitle("Child session - 2026-10-02T17:23:28.276Z"))
        XCTAssertFalse(OpenCodeAdapter.isPlaceholderTitle("New session ideas for the landing page"))
        XCTAssertFalse(OpenCodeAdapter.isPlaceholderTitle("FINAL"))
    }
}

final class CodexInjectedContextTests: XCTestCase {
    func testFiltersBothAgentsMdHeaderForms() {
        XCTAssertTrue(CodexInjectedContext.isInjected("# AGENTS.md instructions\n\n<INSTRUCTIONS>\n定型は Luna…"))
        XCTAssertTrue(CodexInjectedContext.isInjected("# AGENTS.md instructions for /Users/me/proj\n\n<INSTRUCTIONS>"))
        XCTAssertTrue(CodexInjectedContext.isInjected("  <environment_context>\n<cwd>/x</cwd>"))
        XCTAssertFalse(CodexInjectedContext.isInjected("AGENTS.md の書き方を教えて"))
        XCTAssertFalse(CodexInjectedContext.isInjected("こんにちは"))
    }

    func testStripsImageTagsFromPrompt() {
        let raw = "<image name=[Image #1] path=\"/Users/me/日常/a.png\">\n</image>\nこの絵を描き直して"
        XCTAssertEqual(CodexInjectedContext.strippingImageTags(raw), "この絵を描き直して")
        XCTAssertEqual(CodexInjectedContext.strippingImageTags("<image name=[Image #1] path=\"/x.png\">\n</image>"), "")
        XCTAssertEqual(CodexInjectedContext.strippingImageTags("<images> の要素を使う"), "<images> の要素を使う")
    }
}

final class OpenCodeErrorTextTests: XCTestCase {
    func testShowsNameAndNestedMessage() {
        let e: [String: Any] = ["error": ["name": "ProviderAuthError", "data": ["providerID": "x", "message": "API key missing"]]]
        XCTAssertEqual(OpenCodeServeSession.describeError(e), "ProviderAuthError: API key missing")
        XCTAssertEqual(OpenCodeServeSession.describeError(["error": ["message": "boom"]]), "boom")
        XCTAssertTrue(OpenCodeServeSession.describeError(["error": ["name": "UnknownError"]]).contains("UnknownError"))
        XCTAssertEqual(OpenCodeServeSession.describeError([:]), "opencode セッションエラー")
    }
}

final class OpenCodeModelPickerTests: XCTestCase {
    func testBuildsCatalogPerProviderSorted() {
        let providers: [[String: Any]] = [
            ["id": "zai-coding-plan", "name": "Z.AI Coding Plan", "models": [
                "glm-5.3-flash": ["id": "glm-5.3-flash", "name": "GLM-5.3-Flash"],
                "glm-5.3-air": ["id": "glm-5.3-air", "name": "GLM-5.3-Air"]]],
            ["id": "opencode", "name": "OpenCode Zen", "models": ["big-pickle": ["id": "big-pickle", "name": "Big Pickle"]]],
            ["id": "empty", "name": "Empty", "models": [String: Any]()],
        ]
        let c = OpenCodeAdapter.buildCatalog(providers: providers)
        XCTAssertEqual(c.map(\.id), ["opencode", "zai-coding-plan"], "モデルが無いプロバイダは除く。名前順")
        XCTAssertEqual(c[1].models.map(\.id), ["glm-5.3-air", "glm-5.3-flash"])
        XCTAssertEqual(c[1].models.first?.label, "GLM-5.3-Air")
    }

    func testErrorIsAttributedToOpenCode() {
        let t = OpenCodeServeSession.attributed("boom")
        XCTAssertTrue(t.contains("OpenCode 側のエラー: boom"))
        XCTAssertTrue(t.contains("BuddyOS の不具合ではなく"))
    }
}
