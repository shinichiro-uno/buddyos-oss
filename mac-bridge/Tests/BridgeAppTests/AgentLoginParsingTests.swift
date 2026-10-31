import XCTest
@testable import BridgeApp

/// iPhone からのログイン（AgentLoginService）が、各 CLI の実際の出力から URL とコードを拾えるか。
/// 出力は 2026-10-08 に一時 HOME で取ったもの（コードは期限切れ）。
final class AgentLoginParsingTests: XCTestCase {
    private func parse(_ raw: String) -> (String?, String?) {
        let text = AgentLoginService.stripAnsi(raw)
        return (AgentLoginService.firstURL(in: text), AgentLoginService.deviceCode(in: text))
    }

    func testCodexDeviceAuth() {
        let (url, code) = parse("\nWelcome to Codex [v\u{1B}[90m0.160.1\u{1B}[0m]\n\u{1B}[90mOpenAI's command-line coding agent\u{1B}[0m\n\nFollow these steps to sign in with ChatGPT using device code authorization:\n\n1. Open this link in your browser and sign in to your account\n   \u{1B}[94mhttps://auth.openai.com/codex/device\u{1B}[0m\n\n2. Enter this one-time code \u{1B}[90m(expires in 15 minutes)\u{1B}[0m\n   \u{1B}[94mKT4R-QOW5Q\u{1B}[0m\n\n\u{1B}[90mContinue only if you started this login in Codex. If a website or another person gave you this code, cancel.\u{1B}[0m\n\n")
        XCTAssertEqual(url, "https://auth.openai.com/codex/device")
        XCTAssertEqual(code, "KT4R-QOW5Q")
    }

    func testGrokDeviceAuth() {
        let (url, code) = parse("\nTo sign in, open this URL in your browser:\n\n  https://accounts.x.ai/oauth2/device?user_code=R44P-VDZ7\n\nConfirm this code in your browser:\n\n  R44P-VDZ7\n\n\u{1B}[90mOnly continue with a code you requested. Don't share it with anyone.\u{1B}[0m\n\nWaiting for authorization...\n")
        XCTAssertEqual(url, "https://accounts.x.ai/oauth2/device?user_code=R44P-VDZ7")
        XCTAssertEqual(code, "R44P-VDZ7")
    }

    func testCursorLogin() {
        let (url, code) = parse("Starting login process...\nAuthenticating with Cursor...\nWaiting for browser authentication...\nOpen a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=M0h1QFrRBB1ekjJZbRSD-R0lOHvcKgh0e_AXlzL91Pc&uuid=4b1f0738-0839-48c1-a644-4e2d9f4a4c63&mode=login&redirectTarget=cli\n")
        XCTAssertTrue(url?.hasPrefix("https://cursor.com/loginDeepControl?challenge=") == true)
        XCTAssertNil(code)
    }

    func testClaudeManualURLNotLocalhost() {
        let (url, code) = parse("Opening browser to sign in…\nIf the browser didn't open, visit: \u{1B}]8;;https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code+user%3Amcp_servers+user%3Afile_upload+user%3Aplugins&code_challenge=ZnEKptt76fFkAUuMzWqKA-akL5isREWjw34i6FOzHuM&code_challenge_method=S256&state=MozOEL2oIbI47kLslpPEBdou04zE1jRC1fbI7Kp63mY\u{07}https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code+user%3Amcp_servers+user%3Afile_upload+user%3Aplugins&code_challenge=ZnEKptt76fFkAUuMzWqKA-akL5isREWjw34i6FOzHuM&code_challenge_method=S256&state=MozOEL2oIbI47kLslpPEBdou04zE1jRC1fbI7Kp63mY\u{1B}]8;;\u{07}\nPaste code here if prompted > ")
        XCTAssertTrue(url?.hasPrefix("https://claude.com/cai/oauth/authorize?") == true)
        // iPhone で開くので、Mac の localhost に戻る URL ではなく、コードを表示する URL であること。
        XCTAssertTrue(url?.contains("platform.claude.com%2Foauth%2Fcode%2Fcallback") == true)
        XCTAssertNil(code)
    }
}
