// 外のサービス（中継・登録簿・通知）と、任意の機能の設定の読み方。
// 環境変数 → officialDefaults.ts の値 → 無し（その機能は動かさない。Bridge は止めない）。
// 起動時に出どころを 1 行だけログに出す（値は出さない。中継の URL だけは出す）。
import { OFFICIAL_DEFAULTS, type OfficialDefaults } from "./officialDefaults.js";

export type SettingSource = "env" | "account-config" | "default" | "none";

export interface Resolved<T> {
  value: T;
  source: SettingSource;
}

/** 中継が無いときの案内（ログと /health の relay.hint）。 */
export const RELAY_HINT = "No relay is configured. Set BUDDYOS_PASEO_RELAY_URL to your Paseo relay (for example wss://relay.example.com/ws) and restart the bridge.";

const trimmed = (v: string | undefined): string => v?.trim() ?? "";

/** Paseo の中継の URL。BUDDYOS_PASEO_RELAY_URL → 既定値 → ""（中継につながない）。 */
export function resolveRelayURL(env: NodeJS.ProcessEnv = process.env, defaults: OfficialDefaults = OFFICIAL_DEFAULTS): Resolved<string> {
  const fromEnv = trimmed(env.BUDDYOS_PASEO_RELAY_URL);
  if (fromEnv) return { value: fromEnv, source: "env" };
  const fallback = trimmed(defaults.paseoRelayURL);
  return fallback ? { value: fallback, source: "default" } : { value: "", source: "none" };
}

/** 通知の送り方（Windows で使えるのは convex と none）。 */
export type WindowsPushMode = "none" | "convex";

/**
 * BUDDYOS_PUSH_MODE → （BUDDYOS_PUSH_RELAY_URL と _TOKEN が両方あれば convex）→ 既定値。
 * apns-direct は Windows では使えない（APNs の鍵を扱わない）ので、指定されても既定の決め方に戻す。
 */
export function resolvePushMode(env: NodeJS.ProcessEnv = process.env, defaults: OfficialDefaults = OFFICIAL_DEFAULTS): Resolved<WindowsPushMode> & { ignored?: string } {
  const raw = trimmed(env.BUDDYOS_PUSH_MODE).toLowerCase();
  if (raw === "none" || raw === "convex") return { value: raw, source: "env" };
  const ignored = raw ? raw.slice(0, 32) : undefined;
  if (trimmed(env.BUDDYOS_PUSH_RELAY_URL) && trimmed(env.BUDDYOS_PUSH_RELAY_TOKEN)) return { value: "convex", source: "env", ignored };
  const fallback: WindowsPushMode = defaults.pushMode === "none" ? "none" : "convex";
  return { value: fallback, source: "default", ignored };
}

/** Claude の使用量を読むか。BUDDYOS_CLAUDE_USAGE（on / off）→ 既定値。 */
export function resolveClaudeUsage(env: NodeJS.ProcessEnv = process.env, defaults: OfficialDefaults = OFFICIAL_DEFAULTS): Resolved<boolean> {
  const raw = trimmed(env.BUDDYOS_CLAUDE_USAGE).toLowerCase();
  if (raw === "on" || raw === "1" || raw === "true") return { value: true, source: "env" };
  if (raw === "off" || raw === "0" || raw === "false") return { value: false, source: "env" };
  return { value: defaults.claudeUsage === "on", source: "default" };
}

/** OpenRouter の HTTP-Referer。BUDDYOS_OPENROUTER_REFERER → 既定値 → 付けない（undefined）。 */
export function resolveOpenRouterReferer(env: NodeJS.ProcessEnv = process.env, defaults: OfficialDefaults = OFFICIAL_DEFAULTS): Resolved<string | undefined> {
  const fromEnv = trimmed(env.BUDDYOS_OPENROUTER_REFERER);
  if (fromEnv) return { value: fromEnv, source: "env" };
  const fallback = trimmed(defaults.openRouterReferer);
  return fallback ? { value: fallback, source: "default" } : { value: undefined, source: "none" };
}

/**
 * 起動時のログの 1 行。値は出さない（中継の URL だけは出す）。
 * registrySource は registry.ts の convexSiteSetting の出どころ（account.config.json を読むのはそちら）。
 */
export function describeSettings(
  registrySource: SettingSource,
  env: NodeJS.ProcessEnv = process.env,
  defaults: OfficialDefaults = OFFICIAL_DEFAULTS
): string {
  const relay = resolveRelayURL(env, defaults);
  const push = resolvePushMode(env, defaults);
  const usage = resolveClaudeUsage(env, defaults);
  const referer = resolveOpenRouterReferer(env, defaults);
  const parts = [
    `edition=${defaults.edition}`,
    `relay=${relay.source}${relay.value ? `(${relay.value})` : ""}`,
    `registry=${registrySource}`,
    `push=${push.value}(${push.source})${push.ignored ? ` ignored BUDDYOS_PUSH_MODE=${push.ignored}` : ""}`,
    `claudeUsage=${usage.value ? "on" : "off"}(${usage.source})`,
    `openrouterReferer=${referer.source}`
  ];
  return `[config] ${parts.join(" ")}`;
}
