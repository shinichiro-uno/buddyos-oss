import Foundation

/// desktop（accountConfig.ts）と共有する `~/.buddyos/account.config.json` の読み手。
/// launchd 起動の bridge は desktop の spawn env (BUDDYOS_CONVEX_SITE) を受け取れないため、
/// env に無いときはこのファイル、最後に配布物の既定（OfficialDefaults）を使う（読む順は BridgeConfig.convexSite）。
enum AccountConfigFile {
    private struct Config: Decodable {
        let convexSiteUrl: String?
    }

    /// `~/.buddyos/account.config.json` の convexSiteUrl（無ければ nil）。
    static func convexSiteURL() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".buddyos/account.config.json")
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        let trimmed = config.convexSiteUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
