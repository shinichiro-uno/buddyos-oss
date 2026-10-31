// Built-in defaults for hosted services (registry, relay, push). The public edition ships
// with every value empty or off: configure your own services with environment variables
// (see README.md). Environment variables always win over these values (resolution in
// settings.ts). A feature whose value is empty stays off; the bridge still starts.
// 公開版の既定値。中継・登録簿・通知は環境変数で自分のものを指定する（README.md）。

export type PushMode = "none" | "convex" | "apns-direct";

export interface OfficialDefaults {
  /** "official" or "oss" (only printed in the startup log). */
  readonly edition: "official" | "oss";
  /** Registry (Convex HTTP actions) site. Overridden by BUDDYOS_CONVEX_SITE. Empty: no registration (QR pairing only). */
  readonly convexSite: string;
  /** Paseo relay. Overridden by BUDDYOS_PASEO_RELAY_URL. Empty: no tunnel, a hint is logged and shown in /health. */
  readonly paseoRelayURL: string;
  /** Push delivery. Overridden by BUDDYOS_PUSH_MODE. The Windows bridge supports "convex" (registry /v3/push) or "none". */
  readonly pushMode: PushMode;
  /** Claude usage display (calls the usage API with the Claude Code login). Overridden by BUDDYOS_CLAUDE_USAGE. */
  readonly claudeUsage: "on" | "off";
  /** HTTP-Referer sent to OpenRouter. Overridden by BUDDYOS_OPENROUTER_REFERER. Empty: no header. */
  readonly openRouterReferer: string;
}

export const OFFICIAL_DEFAULTS: OfficialDefaults = {
  edition: "oss",
  convexSite: "",
  paseoRelayURL: "",
  pushMode: "none",
  claudeUsage: "off",
  openRouterReferer: ""
};
