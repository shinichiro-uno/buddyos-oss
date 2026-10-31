import XCTest
@testable import BridgeApp

/// 新トランスポート(opencode serve HTTP + SSE) の E2E スモーク。実 opencode を
/// spawn するので環境変数 RUN_OPENCODE_E2E=1 のときだけ走らせる(通常はスキップ)。
///
/// 検証する核心: 従来の stdio ACP(1プロセス=1セッション、毎回コールドブート 13-23s)を
/// serve(1プロセスで複数セッション多重化) に置き換えても、(1) セッション作成→送信→
/// ストリーミング応答→done が正しく流れるか、(2) 複数セッションを並行に動かせるか。
final class OpenCodeServeTransportTests: XCTestCase {

    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUN_OPENCODE_E2E"] == "1"
    }

    /// 結果収集ホルダ(Task クロージャから可視的に書き換えるため class)。
    final class Box {
        var gotDelta = false
        var gotDone = false
        var gotError: String?
        var texts: [String] = []
    }

    func testServeChatStreamsAndCompletes() async throws {
        try XCTSkipUnless(enabled, "set RUN_OPENCODE_E2E=1 to run (spawns real opencode serve)")

        let client = OpenCodeServeClient.shared
        let url = await client.ensureServer()
        XCTAssertNotNil(url, "opencode serve が起動できるべき(バイナリ未インストールなら要セットアップ)")

        let sid = try await client.createSession()
        let session = OpenCodeServeSession(sessionId: sid, client: client)
        session.emitStarted()

        let box = Box()
        let consume = Task {
            for try await ev in session.events {
                switch ev.type {
                case .assistantDelta:
                    box.gotDelta = true
                    if let c = ev.content { box.texts.append(c) }
                case .done:
                    box.gotDone = true
                    return
                case .error:
                    box.gotError = ev.content
                    return
                default:
                    break
                }
            }
        }

        // send() は POST を detach して即復帰し、SSE が done を運ぶ。
        await session.send("reply with exactly the two letters: ok", skills: [], attachments: [])

        let start = Date()
        while !box.gotDone && box.gotError == nil && Date().timeIntervalSince(start) < 90 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        consume.cancel()
        await session.close()

        XCTAssertNil(box.gotError, "エラーイベントが来てはいけない: \(box.gotError ?? "")")
        XCTAssertTrue(box.gotDelta, "アシスタント応答のストリーミング差分(assistantDelta)が届くべき")
        XCTAssertTrue(box.gotDone, "ターン完了(done)が届くべき")
    }

    /// 1サーバプロセス上で2セッションを並行に動かせること(= 従来 N プロセス spawn を
    /// 1プロセス多重化で解消したことの証明)。両方とも独立に done する。
    func testServeParallelSessionsOnOneServer() async throws {
        try XCTSkipUnless(enabled, "set RUN_OPENCODE_E2E=1 to run (spawns real opencode serve)")

        let client = OpenCodeServeClient.shared
        _ = await client.ensureServer()

        let sid1 = try await client.createSession()
        let sid2 = try await client.createSession()
        let s1 = OpenCodeServeSession(sessionId: sid1, client: client)
        let s2 = OpenCodeServeSession(sessionId: sid2, client: client)
        s1.emitStarted(); s2.emitStarted()

        let box1 = Box(); let box2 = Box()
        func consume(_ s: OpenCodeServeSession, _ b: Box) -> Task<Void, Error> {
            Task {
                for try await ev in s.events {
                    switch ev.type {
                    case .assistantDelta: b.gotDelta = true
                    case .done: b.gotDone = true; return
                    case .error: b.gotError = ev.content; return
                    default: break
                    }
                }
            }
        }
        let c1 = consume(s1, box1)
        let c2 = consume(s2, box2)

        // ほぼ同時に両方へ送信。1プロセス多重化でも SSE が sessionID で demux され、
        // それぞれのセッションへ正しく届くことを検証する。
        async let r1: Void = s1.send("reply with just: one", skills: [], attachments: [])
        async let r2: Void = s2.send("reply with just: two", skills: [], attachments: [])
        _ = await (r1, r2)

        let start = Date()
        while (!(box1.gotDone && box2.gotDone) && box1.gotError == nil && box2.gotError == nil
                && Date().timeIntervalSince(start) < 90) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        c1.cancel(); c2.cancel()
        await s1.close(); await s2.close()

        XCTAssertTrue(box1.gotDelta && box1.gotDone, "セッション1 がストリーミング+完了すべき err=\(box1.gotError ?? "nil")")
        XCTAssertTrue(box2.gotDelta && box2.gotDone, "セッション2 がストリーミング+完了すべき err=\(box2.gotError ?? "nil")")
    }
}
