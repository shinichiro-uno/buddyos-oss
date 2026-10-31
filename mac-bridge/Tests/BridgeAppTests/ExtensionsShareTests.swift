import XCTest
@testable import BridgeApp

final class ExtensionsShareTests: XCTestCase {
    private var home: String!

    override func setUp() {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)").path
        for d in ["/.claude/skills/review", "/.codex/skills/.system/builtin", "/.codex/skills/tools/lint", "/.hermes/skills"] {
            try? FileManager.default.createDirectory(atPath: home + d, withIntermediateDirectories: true)
        }
        try? "---\ndescription: レビューする\n---\n本文".write(toFile: home + "/.claude/skills/review/SKILL.md", atomically: true, encoding: .utf8)
        try? "---\ndescription: lint\n---".write(toFile: home + "/.codex/skills/tools/lint/SKILL.md", atomically: true, encoding: .utf8)
        try? "x".write(toFile: home + "/.codex/skills/.system/builtin/SKILL.md", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
    }

    func testInstalledAgentsAndSkillListing() {
        // opencode は設定フォルダが無いので対象外
        XCTAssertEqual(ExtensionsShare.installedAgents(home: home).map(\.id), ["claude", "codex", "hermes"])
        XCTAssertEqual(ExtensionsShare.skills(agentId: "claude", home: home).map(\.name), ["review"])
        // 分類フォルダの下も拾い、隠しフォルダ（組み込み）は除く
        XCTAssertEqual(ExtensionsShare.skills(agentId: "codex", home: home).map(\.name), ["lint"])
        XCTAssertEqual(ExtensionsShare.skills(agentId: "claude", home: home).first?.description, "レビューする")
    }

    /// Hermes にコマンド型のコネクタ（npx で起こす filesystem 等）も書ける。書いたものは読み戻せる。
    func testHermesAcceptsCommandMcp() {
        try? "model: x\nmcp_servers:\n  context7:\n    url: \"https://mcp.context7.com/mcp\"\n    enabled: true\n"
            .write(toFile: home + "/.hermes/config.yaml", atomically: true, encoding: .utf8)
        let spec = McpRegisterSpec(serverName: "filesystem", transportKind: "command", url: nil, command: "npx",
                                   args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/dev"],
                                   env: ["API_KEY": "k"])
        let r = McpService.registerHermes(name: "filesystem", spec: spec, home: home)
        XCTAssertTrue(r.0, r.1 ?? "")
        let specs = McpService.hermesFullSpecs(home: home)
        XCTAssertEqual(specs.map(\.name), ["context7", "filesystem"])
        let fs = specs.first { $0.name == "filesystem" }
        XCTAssertEqual(fs?.kind, "command")
        XCTAssertEqual(fs?.command, "npx")
        XCTAssertEqual(fs?.args, ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/dev"])
        XCTAssertEqual(fs?.env, ["API_KEY": "k"])
        // ほかのキーは残る
        let raw = (try? String(contentsOfFile: home + "/.hermes/config.yaml", encoding: .utf8)) ?? ""
        XCTAssertTrue(raw.hasPrefix("model: x\n"))
        XCTAssertFalse(McpService.registerHermes(name: "filesystem", spec: spec, home: home).0, "同じ名前は足さない")
    }

    func testSyncCopiesSkillsWithoutOverwriting() {
        let r = ExtensionsShare.sync(items: ["skill:review", "skill:lint"], targets: ["claude", "codex", "hermes", "opencode"], home: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.codex/skills/review/SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.hermes/skills/shared/review/SKILL.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home + "/.claude/skills/lint/SKILL.md"))
        XCTAssertTrue(r.skipped.contains("skill:review → claude"))
        XCTAssertFalse(r.copied.contains { $0.hasSuffix("opencode") }, "入っていないエージェントには写さない")
        // 2 回目は全部 skip
        let again = ExtensionsShare.sync(items: ["skill:review"], targets: ["codex", "hermes"], home: home)
        XCTAssertTrue(again.copied.isEmpty)
    }

    func testRedactHidesQuery() {
        XCTAssertEqual(ExtensionsShare.redact("https://mcp.example.com/sse?token=abc"), "https://mcp.example.com/sse?…")
        XCTAssertEqual(ExtensionsShare.redact("npx -y server"), "npx -y server")
    }
}
