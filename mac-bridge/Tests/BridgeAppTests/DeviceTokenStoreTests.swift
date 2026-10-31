import XCTest
@testable import BridgeApp

/// デバイストークンは Clerk セッションが切れた後もこの Mac を発見可能に保つ唯一の
/// 資格情報なので、保管まわりの前提をここで固定する。
///
/// bridge-id の書き込み検証も併せて見る。1台の Mac に 117 行が溜まったとき、
/// 書き込み失敗が黙って握り潰されていて原因を追えなかった。
///
/// 本物の ~/.buddyos は動いている Bridge が使っているので触らない。テストごとに空の
/// 一時フォルダを BuddyPaths に差して、そこへ書く。
final class DeviceTokenStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-token-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
        BuddyPaths.setOverride(root)
    }

    override func tearDownWithError() throws {
        BuddyPaths.setOverride(nil)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private var tokenURL: URL { root.appendingPathComponent("device-token") }

    /// テスト中の置き場所が本物の ~/.buddyos でないこと。ここが崩れると、テストを
    /// 走らせるたびに動いている Bridge の device-token / bridge-id が書き換わる。
    func testDefaultRootIsNotRealHomeDuringTests() {
        BuddyPaths.setOverride(nil)
        defer { BuddyPaths.setOverride(root) }
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".buddyos", isDirectory: true).standardizedFileURL.path
        XCTAssertTrue(BuddyPaths.isTesting)
        XCTAssertNotEqual(BuddyPaths.root.standardizedFileURL.path, real)
    }

    /// 書き込みは差し替えた先へ行く。
    func testWritesGoToOverriddenRoot() {
        KeyStore.setDeviceToken("bdt_override_example")
        KeyStore.setBridgeId("mac-bridge-override-example")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("bridge-id").path))
    }

    func testRoundTrip() {
        KeyStore.setDeviceToken("bdt_roundtrip_example")
        XCTAssertEqual(KeyStore.deviceToken(), "bdt_roundtrip_example")
    }

    /// api-key と同格の機密。他ユーザーや同期ツールから読める権限に置かない。
    func testStoredOwnerOnly() throws {
        KeyStore.setDeviceToken("bdt_permissions_example")
        let path = tokenURL.path
        let perms = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(perms.int16Value & 0o777, 0o600)
    }

    /// サーバーが 401 を返したら捨てる。死んだ資格情報を再試行し続けないため。
    func testClearRemovesToken() {
        KeyStore.setDeviceToken("bdt_to_be_cleared")
        KeyStore.clearDeviceToken()
        XCTAssertNil(KeyStore.deviceToken())
    }

    /// 空ファイルは「トークンなし」。空文字を Bearer に載せて 401 を踏まない。
    func testEmptyFileReadsAsAbsent() throws {
        KeyStore.setDeviceToken("bdt_before_empty")
        try Data().write(to: tokenURL, options: [.atomic])
        XCTAssertNil(KeyStore.deviceToken())
    }

    /// 前後の空白・改行は落とす。エディタ等が触っても Authorization が壊れない。
    func testWhitespaceIsTrimmed() throws {
        KeyStore.setDeviceToken("bdt_before_padded")
        try "  bdt_padded_example\n".data(using: .utf8)!.write(to: tokenURL, options: [.atomic])
        XCTAssertEqual(KeyStore.deviceToken(), "bdt_padded_example")
    }

    /// サーバーが権威の bridgeId を返したとき、bridge 側が確実に追従できること。
    /// ここが黙って失敗すると、登録行が毎回増えるという以前の症状に戻る。
    func testBridgeIdWriteIsVerifiable() {
        let id = "mac-bridge-write-verify-example"
        KeyStore.setBridgeId(id)
        XCTAssertEqual(KeyStore.bridgeId(), id, "書いた ID が読み戻せなければ追従が成立しない")
    }
}
