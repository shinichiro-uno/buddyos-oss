import XCTest
@testable import BridgeApp

/// 実 opencode CLI を spawn する E2E スモーク。cold start (~23s) があり opencode が
/// 必要なので、環境変数 RUN_OPENCODE_E2E=1 のときだけ走らせる（通常 CI ではスキップ）。
///
/// 検証する回帰: モデル切替が「チャットを開いて 1 通送る前」でも動くこと。
/// configOptions は session/new の result に乗るが、以前は初回 send まで bootstrap が
/// 遅延していたため、未送信だと一覧が空・setConfigOption が throw していた。
/// listAvailableModels(session:)/setModel(session:) が ensureStarted() で session を確立する修正を確認する。
///
/// model/mode/commands の問い合わせは「問い合わせ元コネクションの session」を渡す方式に
/// 変更済み（共有 weak スロットを別接続が上書きして nil 化する回帰の修正）。テストも
/// openSession で得た session を各クエリに渡す。
final class OpenCodeModelSwitchE2ETests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUN_OPENCODE_E2E"] == "1"
    }

    func testModelSwitchBeforeFirstMessage() async throws {
        try XCTSkipUnless(enabled, "set RUN_OPENCODE_E2E=1 to run (spawns real opencode acp)")

        let adapter = OpenCodeAdapter()
        // この接続の session。クエリにそのまま渡す（共有スロットには依存しない）。
        let session = await adapter.openSession(sessionId: nil, cwd: FileManager.default.currentDirectoryPath)
        defer { Task { await session.close() } }

        // --- 未送信のままモデル一覧を取得（fix の核心: ensureStarted で bootstrap）---
        let providers = await adapter.listAvailableModels(session: session)
        XCTAssertFalse(providers.isEmpty, "未送信でもモデル一覧が取得できるべき")
        let models = providers.first?.models ?? []
        XCTAssertFalse(models.isEmpty, "provider にモデルが 1 つ以上あるべき")

        // --- 現在モデルが読める ---
        let info0 = await adapter.currentInfo(session: session)
        XCTAssertEqual(info0?.provider, "opencode")
        let current = info0?.model
        XCTAssertNotNil(current, "未送信でも現在モデルが読めるべき")

        // --- 現在と違うモデルへ切替（throw しない & currentInfo に反映）---
        guard let target = models.first(where: { $0.id != current }) ?? models.first else {
            return XCTFail("切替先モデルが無い")
        }
        try await adapter.setModel(model: target.id, provider: "opencode",
                                   reasoningEffort: nil, codexMode: nil, session: session)
        let info1 = await adapter.currentInfo(session: session)
        XCTAssertEqual(info1?.model, target.id, "切替後の現在モデルが反映されるべき")
    }

    /// 回帰テスト: 別接続が openSession で共有状態を上書きしても、各接続が自分の
    /// session を渡せばモデル一覧が壊れないこと（weak 共有スロット撤廃の核心）。
    func testModelListSurvivesOtherConnectionChurn() async throws {
        try XCTSkipUnless(enabled, "set RUN_OPENCODE_E2E=1 to run (spawns real opencode acp)")

        let adapter = OpenCodeAdapter()
        let sessionA = await adapter.openSession(sessionId: nil, cwd: FileManager.default.currentDirectoryPath)
        defer { Task { await sessionA.close() } }

        // 別接続 B を開いて即閉じる（旧実装ではここで共有 weak スロットが nil 化した）。
        let sessionB = await adapter.openSession(sessionId: nil, cwd: FileManager.default.currentDirectoryPath)
        await sessionB.close()

        // A の session でモデル一覧を取得 → B の churn の影響を受けないこと。
        let providers = await adapter.listAvailableModels(session: sessionA)
        XCTAssertFalse(providers.isEmpty, "別接続が開閉してもモデル一覧は取得できるべき")
        XCTAssertFalse(providers.first?.models.isEmpty ?? true, "provider にモデルが 1 つ以上あるべき")
    }
}
