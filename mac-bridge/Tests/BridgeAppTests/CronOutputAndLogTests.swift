import Foundation
import XCTest
@testable import BridgeApp

/// cron の出力（jobId の検証・[SILENT] の判定）と、Bridge のログの書き方を確かめる。
final class CronOutputAndLogTests: XCTestCase {
    func testJobIdValidation() {
        XCTAssertTrue(CronOutputHub.isValidJobId("613a170e8df3"))
        XCTAssertTrue(CronOutputHub.isValidJobId("7F3C2A10-1B2C-4D5E-8F90-0123456789AB"))
        XCTAssertTrue(CronOutputHub.isValidJobId("daily_report.v2"))
        XCTAssertFalse(CronOutputHub.isValidJobId(""))
        XCTAssertFalse(CronOutputHub.isValidJobId("."))
        XCTAssertFalse(CronOutputHub.isValidJobId(".."))
        XCTAssertFalse(CronOutputHub.isValidJobId("../../.ssh"))
        XCTAssertFalse(CronOutputHub.isValidJobId("a/b"))
        XCTAssertFalse(CronOutputHub.isValidJobId("x' OR 1=1 --"))
        XCTAssertFalse(CronOutputHub.isValidJobId(String(repeating: "a", count: 129)))
        // 形の違う jobId は何も読まない。
        XCTAssertTrue(CronOutputHub.loadPastOutputs(jobId: "../..").isEmpty)
    }

    func testSilentMarkerIsExactLineMatch() {
        let prompt = """
        # Cron Job: 毎朝

        ## Prompt

        SILENT: If there is nothing new, respond with exactly "[SILENT]" (nothing else).

        ## Response

        """
        XCTAssertTrue(CronOutputHub.isSilentCronOutput(prompt + "[SILENT]\n"))
        XCTAssertTrue(CronOutputHub.isSilentCronOutput(prompt + "  [silent]  \n"))
        XCTAssertTrue(CronOutputHub.isSilentCronOutput(prompt + "[SILENT]\n(nothing new)\n"))
        XCTAssertTrue(CronOutputHub.isSilentCronOutput(prompt + "今日は特になし\n[SILENT]\n"))
        // hermes が配信を止める書き方（gateway/response_filters.py と同じ）。
        XCTAssertTrue(CronOutputHub.isSilentCronOutput(prompt + "[SILENT] No changes detected\n"))
        XCTAssertTrue(CronOutputHub.isSilentCronOutput(prompt + "NO_REPLY\n"))
        XCTAssertTrue(CronOutputHub.isSilentCronOutput(prompt + "*NO_REPLY*\n"))
        XCTAssertTrue(CronOutputHub.isSilentCronOutput(prompt + "変化なし。\nsilent\n"))
        XCTAssertFalse(CronOutputHub.isSilentCronOutput(prompt + "Silent retry succeeded\n"))
        // 文の途中・プロンプトの説明文に含まれるだけでは止めない。
        XCTAssertFalse(CronOutputHub.isSilentCronOutput(prompt + "新着 3 件。[SILENT] は使いません。\n詳細は以下。\n"))
        XCTAssertFalse(CronOutputHub.isSilentCronOutput(prompt + "Report\n- item [SILENT] mention\n- done\n"))
        XCTAssertFalse(CronOutputHub.isSilentCronOutput(prompt))
        XCTAssertFalse(CronOutputHub.isSilentCronOutput("**Status:** silent"))
    }

    func testLogFileIsPrivateAndDoesNotFollowSymlinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("buddyos-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let logDir = dir.appendingPathComponent("Logs/BuddyOS").path
        XCTAssertTrue(WebSocketServer.prepareLogDirectory(logDir))
        let dirMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logDir)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(dirMode.intValue & 0o777, 0o700)

        let log = logDir + "/bridge-ws.log"
        XCTAssertTrue(WebSocketServer.appendLogLine("hello\n", toFile: log))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: log)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "hello\n")

        // 既にあった広い権限のファイルは 0600 に絞る。
        let wide = logDir + "/wide.log"
        FileManager.default.createFile(atPath: wide, contents: Data(), attributes: [.posixPermissions: 0o644])
        XCTAssertTrue(WebSocketServer.appendLogLine("x\n", toFile: wide))
        let wideMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: wide)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(wideMode.intValue & 0o777, 0o600)

        // シンボリックリンクの先へは書かない。
        let target = dir.appendingPathComponent("victim.txt").path
        FileManager.default.createFile(atPath: target, contents: Data("keep".utf8))
        let link = logDir + "/link.log"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertFalse(WebSocketServer.appendLogLine("evil\n", toFile: link))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep")

        // フォルダがシンボリックリンクなら使わない。
        let linkedDir = dir.appendingPathComponent("linked").path
        try FileManager.default.createSymbolicLink(atPath: linkedDir, withDestinationPath: dir.path)
        XCTAssertFalse(WebSocketServer.prepareLogDirectory(linkedDir))
    }
}
