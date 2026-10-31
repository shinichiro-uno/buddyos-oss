import Foundation

/// Built-in defaults for hosted services (registry, relay, push). This is the open-source
/// edition: every value is empty or off, so nothing is contacted unless you configure it.
/// Environment variables always win (see `BridgeConfig` and README.md):
///
///   BUDDYOS_PASEO_RELAY_URL   your Paseo relay, e.g. wss://relay.example.com/ws
///   BUDDYOS_CONVEX_SITE       your registry (Convex HTTP Actions site); empty = QR pairing only
///   BUDDYOS_PUSH_MODE         none | convex | apns-direct | auto
///   APNS_KEY_PATH / APNS_KEY_ID / APNS_TEAM_ID / APNS_BUNDLE_ID   for apns-direct
///   BUDDYOS_CLAUDE_USAGE      on | off
///   BUDDYOS_OPENROUTER_REFERER
///   BUDDYOS_ID_PREFIX         prefix for the LaunchAgent label
///
/// A distribution that runs its own services may ship its own copy of this file with the
/// same shape.
enum OfficialDefaults {
    /// "official" or "oss" (only printed in the startup log line).
    static let edition = "oss"
    static let convexSite = ""
    static let paseoRelayURL = ""
    /// "none" | "convex" | "apns-direct" | "auto" (auto = apns-direct when a .p8 key is present, else convex).
    static let pushMode = "none"
    static let apnsKeyId = ""
    static let apnsTeamId = ""
    static let apnsBundleId = ""
    /// Key file name inside ~/.buddyos/. Empty = no default location (use APNS_KEY_PATH).
    static let apnsKeyFile = ""
    /// "on" | "off"
    static let claudeUsage = "off"
    static let openRouterReferer = ""
    static let idPrefix = "dev.buddyos.oss"
}
