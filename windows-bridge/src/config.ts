import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { BridgeIdentity, ensurePrivateDir, loadOrCreatePaseoRelayId, migrateLegacyDir as migrateIdentityDir } from "./identity.js";
import { OFFICIAL_DEFAULTS, type OfficialDefaults } from "./officialDefaults.js";
import { resolveRelayURL } from "./settings.js";

export type RuntimeMode = "auto" | "native" | "wsl" | "off";

/** 待ち受けアドレス。iPhone は Paseo の中継でつながるので、Bridge は自分の PC の中（127.0.0.1）だけで待ち受ける。 */
export const LISTEN_HOST = "127.0.0.1";

export interface BridgeConfig {
  configDir: string;
  /**
   * 身元（静的鍵・中継の ID・ローカル鍵・bridgeId）と端末の一覧。作り直しで値が変わるので、起動時の値を
   * 閉じ込めず、使うたびにここから読む（spec/PROTOCOL-v3.md §13.2）。
   */
  identity: BridgeIdentity;
  /** identity.bridgeId と同じ（作り直しで変わることがある）。 */
  readonly bridgeId: string;
  port: number;
  /** Paseo 中継の URL（BUDDYOS_PASEO_RELAY_URL → officialDefaults.ts）。空なら中継につながない（settings.ts の RELAY_HINT）。 */
  paseoRelayURL: string;
  defaultCwd: string;
  hermesMode: RuntimeMode;
  claudeMode: RuntimeMode;
  codexMode: RuntimeMode;
  openclawMode: RuntimeMode;
  opencodeMode: RuntimeMode;
  cursorMode: RuntimeMode;
  grokMode: RuntimeMode;
  antigravityMode?: RuntimeMode;
  wslDistro?: string;
}

/** 設定の読み込み。dir は resolveConfigDir() の値（インスタンスの鍵を取ってから呼ぶ。移行を 2 つの Bridge で同時に行わない）。 */
export function loadConfig(dir: string = resolveConfigDir()): BridgeConfig {
  ensurePrivateDir(dir);
  const legacy = legacyConfigDir();
  if (legacy) migrateLegacyDir(legacy, dir);
  const identity = BridgeIdentity.open(dir);

  return {
    configDir: dir,
    identity,
    get bridgeId() {
      return identity.bridgeId;
    },
    port: numberEnv("BUDDYOS_BRIDGE_PORT", 8765),
    paseoRelayURL: paseoRelayURL(),
    defaultCwd: process.env.BUDDYOS_DEFAULT_CWD ?? os.homedir(),
    hermesMode: modeEnv("BUDDYOS_HERMES_MODE"),
    claudeMode: modeEnv("BUDDYOS_CLAUDE_MODE"),
    codexMode: modeEnv("BUDDYOS_CODEX_MODE"),
    openclawMode: modeEnv("BUDDYOS_OPENCLAW_MODE"),
    opencodeMode: modeEnv("BUDDYOS_OPENCODE_MODE"),
    cursorMode: modeEnv("BUDDYOS_CURSOR_MODE"),
    grokMode: modeEnv("BUDDYOS_GROK_MODE"),
    antigravityMode: modeEnv("BUDDYOS_ANTIGRAVITY_MODE"),
    wslDistro: process.env.BUDDYOS_WSL_DISTRO
  };
}

/**
 * 設定フォルダ。Windows は %LOCALAPPDATA%\BuddyOS\Bridge（Roaming の %APPDATA% はドメインのプロファイルで
 * 他の PC に写り、2 台が同じ鍵で動いてしまうためやめた）。Linux / WSL の開発用は ~/.buddyos-windows-bridge。
 */
export function resolveConfigDir(env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform = process.platform): string {
  if (platform === "win32") {
    const localAppData = env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local");
    return path.join(localAppData, "BuddyOS", "Bridge");
  }
  return path.join(os.homedir(), ".buddyos-windows-bridge");
}

/** 以前の設定フォルダ（%APPDATA%\BuddyOS\Bridge）。Windows のときだけ。 */
export function legacyConfigDir(env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform = process.platform): string | undefined {
  if (platform !== "win32") return undefined;
  const appData = env.APPDATA ?? path.join(os.homedir(), "AppData", "Roaming");
  return path.join(appData, "BuddyOS", "Bridge");
}

/**
 * 古い置き場所（Roaming）からの移行。鍵と ID の扱いは identity.ts の migrateLegacyDir（鍵は移さない）。
 * 加えて、止まった Bridge が Roaming に残した bridge.port / bridge.pid を消す（古い番号へ繋ぎに行かないように）。
 */
export function migrateLegacyDir(legacyDir: string, dir: string, log: (m: string) => void = (m) => console.log(`[bridge] ${m}`)): void {
  migrateIdentityDir(legacyDir, dir, log);
  if (path.resolve(legacyDir) === path.resolve(dir) || !fs.existsSync(legacyDir)) return;
  const pid = Number.parseInt(readQuietly(path.join(legacyDir, "bridge.pid")), 10);
  if (!pidAlive(pid)) {
    removeQuietly(path.join(legacyDir, "bridge.port"));
    removeQuietly(path.join(legacyDir, "bridge.pid"));
  }
}

function readQuietly(file: string): string {
  try {
    return fs.readFileSync(file, "utf8").trim();
  } catch {
    return "";
  }
}

function removeQuietly(file: string): void {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    /* 消せなくても、新しい方が先に読まれる */
  }
}

function pidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

export { ensurePrivateDir, loadOrCreatePaseoRelayId };

/** Paseo 中継の URL。BUDDYOS_PASEO_RELAY_URL → 既定値（officialDefaults.ts）→ ""（mac の relayURLString と同じ順）。 */
export function paseoRelayURL(env: NodeJS.ProcessEnv = process.env, defaults: OfficialDefaults = OFFICIAL_DEFAULTS): string {
  return resolveRelayURL(env, defaults).value;
}

function numberEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function modeEnv(name: string): RuntimeMode {
  const raw = (process.env[name] ?? "auto").toLowerCase();
  if (raw === "native" || raw === "wsl" || raw === "off" || raw === "auto") return raw;
  return "auto";
}
