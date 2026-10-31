import XCTest
@testable import BridgeApp

/// registry-status.json は「この Mac は iPhone から見つかるか」を desktop に伝える
/// 唯一の経路なので、状態遷移そのものをここで固定する。
///
/// とくに重要なのは失敗記録が成功時刻を消さないこと。「最後に見つかったのが4分前」と
/// 「6日前」では画面に出すべき言葉が違うのに、失敗のたびに上書きしていると区別が
/// できなくなる。実際、6日間発見されないまま気付けなかった事故がこの情報の欠落から
/// 起きている。
final class RegistryStatusTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 本物の ~/.buddyos/registry-status.json は desktop が読んでいるので触らない。
        // テストごとに空の一時フォルダへ書く。
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-status-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        BuddyPaths.setOverride(root)
    }

    override func tearDownWithError() throws {
        BuddyPaths.setOverride(nil)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testSuccessRecordsTimestampAndAuth() {
        RegistryStatus.recordSuccess(usedDeviceToken: true)
        let s = RegistryStatus.read()
        XCTAssertEqual(s?.auth, "device")
        XCTAssertNil(s?.lastError)
        XCTAssertNotNil(s?.lastSuccessAt)
        XCTAssertEqual(s?.lastSuccessAt ?? 0, s?.lastAttemptAt ?? -1, accuracy: 0.001)
    }

    func testClerkAuthIsDistinguishedFromDevice() {
        RegistryStatus.recordSuccess(usedDeviceToken: false)
        XCTAssertEqual(RegistryStatus.read()?.auth, "clerk")
    }

    /// 失敗しても直近の成功時刻は残す。「いつから見つかっていないか」が言えなくなる。
    func testFailureKeepsPreviousSuccessTimestamp() {
        RegistryStatus.recordSuccess(usedDeviceToken: true)
        let successAt = RegistryStatus.read()?.lastSuccessAt
        XCTAssertNotNil(successAt)

        RegistryStatus.recordFailure("HTTP 401")
        let after = RegistryStatus.read()
        XCTAssertEqual(after?.lastError, "HTTP 401")
        XCTAssertEqual(after?.lastSuccessAt ?? 0, successAt ?? -1, accuracy: 0.001,
                       "失敗記録が成功時刻を消してはいけない")
        XCTAssertGreaterThanOrEqual(after?.lastAttemptAt ?? 0, successAt ?? 0,
                                    "試行時刻は更新される")
    }

    /// 成功したら前回のエラーは消える。直っているのに警告が残り続けない。
    func testSuccessClearsPreviousError() {
        RegistryStatus.recordFailure("signin-required")
        XCTAssertEqual(RegistryStatus.read()?.lastError, "signin-required")
        RegistryStatus.recordSuccess(usedDeviceToken: true)
        XCTAssertNil(RegistryStatus.read()?.lastError)
    }

    /// サインイン前の状態。desktop はこれを見て「サインインすれば見つかる」と出す。
    func testSigninRequiredIsRecordedVerbatim() {
        RegistryStatus.recordFailure("signin-required")
        XCTAssertEqual(RegistryStatus.read()?.lastError, "signin-required")
    }
}
