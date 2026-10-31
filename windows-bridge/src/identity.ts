import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DeviceStore, type ResetReason } from "./deviceStore.js";
import { clearRegistered, clearRegistryError, recordRegistryFailure, RegistryReason, setRegistryHold } from "./registryFiles.js";
import { x25519Pub } from "./tunnelV3.js";

// Bridge の身元（静的鍵・中継の ID・ローカル鍵・bridgeId）と、v3 への移行・作り直し。
// spec/PROTOCOL-v3.md §4・Appendix A（Windows の分。machineId は持たないので は行わない）。
//
// ファイル（設定フォルダ。Windows は %LOCALAPPDATA%\BuddyOS\Bridge）:
//   e2e-key          静的鍵（raw 32 バイトの base64）。無い・壊れているときだけ作り直す。読めない（権限・I/O）ときは待つ
//   paseo-relay-id   中継の ID
//   api-key          ローカル鍵（この PC の中のアプリだけが使う。トンネル越しでは使えない）
//   bridge-id        bridgeId
//   auth-v3.json     移行済みの印 {"migratedAt":<ms>,"machineId":null}
//   reset-pending    作り直しの途中の印 {"reason","at"}。起動時にあれば続きから行う
//   device-token     登録簿の端末トークン bdt_（registry.ts が書く。bridgeId を作り直すときに消す）
//   registry-status.json / registry-hold / registered.json  登録簿の結果・止めている印・最後に登録できた値（registryFiles.ts）

export type KeyState = "ok" | "io_error";

export interface IdentityOptions {
  env?: NodeJS.ProcessEnv;
  now?: () => number;
  log?: (message: string) => void;
  /** 移行で消す ~/.buddyos/push_tokens.json の場所（テスト用）。 */
  homeDir?: string;
}

/** 作り直しで bridgeId も作り直す理由（PROTOCOL-v3 Appendix A）。 */
const RENEWS_BRIDGE_ID: readonly ResetReason[] = ["account_removed", "machine_changed"];

export class BridgeIdentity {
  readonly devices: DeviceStore;
  private e2eKeyValue?: Buffer;
  private keyStateValue: KeyState = "ok";
  private relayIdValue = "";
  private localKeyValue = "";
  private bridgeIdValue: string;
  private readonly listeners: Array<(reason: ResetReason) => void> = [];
  private homeDir = os.homedir();
  private readonly env: NodeJS.ProcessEnv;
  private readonly now: () => number;
  private readonly log: (message: string) => void;

  /** BUDDYOS_BRIDGE_API_KEY でローカル鍵を固定しているか（作り直せない）。 */
  readonly localKeyFixed: boolean;

  private constructor(readonly dir: string, devices: DeviceStore, bridgeId: string, opts: IdentityOptions) {
    this.devices = devices;
    this.bridgeIdValue = bridgeId;
    this.env = opts.env ?? process.env;
    this.now = opts.now ?? Date.now;
    this.log = opts.log ?? ((m) => console.log(`[identity] ${m}`));
    this.localKeyFixed = !!this.env.BUDDYOS_BRIDGE_API_KEY;
    if (opts.homeDir) this.homeDir = opts.homeDir;
  }

  /** 起動時の確かめ。ルートを登録する前に呼ぶ。 */
  static open(dir: string, opts: IdentityOptions = {}): BridgeIdentity {
    const env = opts.env ?? process.env;
    const log = opts.log ?? ((m: string) => console.log(`[identity] ${m}`));
    const now = opts.now ?? Date.now;
    ensurePrivateDir(dir);
    const bridgeId = env.BUDDYOS_BRIDGE_ID ?? readOrCreate(path.join(dir, "bridge-id"), () => newBridgeId());
    const pending = readResetPending(path.join(dir, "reset-pending"));

    // 1. 作り直しの途中で落ちていたら、その理由で 2 から続ける。
    // 2. 初めての v3（auth-v3.json が無い）: 鍵・中継の ID・ローカル鍵を作り直す（古い値は QR・iPhone・別の PC に
    //    出回っているため）。移行も reset-pending を先に書き、途中で落ちたら次の起動で続ける。
    if (pending || !fs.existsSync(path.join(dir, "auth-v3.json"))) {
      const reason: ResetReason = pending?.reason ?? "migration_v3";
      if (!pending) writePrivateFile(path.join(dir, "reset-pending"), JSON.stringify({ reason, at: now() }));
      else log(`resuming an interrupted reset (${reason})`);
      const migrating = reason === "migration_v3";
      const devices = migrating ? DeviceStore.createFresh(dir, "migration_v3", { now, log }) : DeviceStore.open(dir, { now, log });
      const identity = new BridgeIdentity(dir, devices, bridgeId, opts);
      identity.finishReset(reason, migrating);
      return identity;
    }

    // 4・5. 移行済み。devices.json は無ければ .bak から、どちらも無ければ空で（DeviceStore.open）。
    const identity = new BridgeIdentity(dir, DeviceStore.open(dir, { now, log }), bridgeId, opts);
    identity.relayIdValue = loadOrCreatePaseoRelayId(path.join(dir, "paseo-relay-id"));
    identity.localKeyValue = identity.readLocalKey();
    // 6. 静的鍵（無い・壊れているときだけ作り直す。読めないときは作り直さない）。
    const key = readE2EKey(path.join(dir, "e2e-key"));
    if (key.kind === "ok") {
      identity.e2eKeyValue = key.key;
    } else if (key.kind === "io") {
      identity.keyStateValue = "io_error";
      recordRegistryFailure(dir, RegistryReason.keyIO);
      log(`e2e-key could not be read (${key.code}); the relay stays off until it can be read`);
    } else {
      log(`e2e-key was ${key.kind}; creating new connection details`);
      identity.resetIdentity("key_unreadable");
    }
    return identity;
  }

  get bridgeId(): string {
    return this.bridgeIdValue;
  }

  /** 静的鍵。読めない（io_error）間は undefined。 */
  get e2eKey(): Buffer | undefined {
    return this.e2eKeyValue;
  }

  get keyState(): KeyState {
    return this.keyStateValue;
  }

  get relayId(): string {
    return this.relayIdValue;
  }

  /** ローカル鍵（毎回いまの値。作り直しで変わる。PROTOCOL-v3 §13.2）。 */
  localKey(): string {
    return this.localKeyValue;
  }

  bridgePub(): Buffer | undefined {
    return this.e2eKeyValue ? x25519Pub(this.e2eKeyValue) : undefined;
  }

  /** 作り直しの後に呼ぶ（招待・プレビューのセッションを捨て、トンネルを張り直す）。 */
  onReset(listener: (reason: ResetReason) => void): void {
    this.listeners.push(listener);
  }

  /** 静的鍵が読めなかった（io_error）ときの読み直し（30 秒ごと）。読めたら true。 */
  retryKey(): boolean {
    if (this.keyStateValue === "ok") return true;
    const key = readE2EKey(path.join(this.dir, "e2e-key"));
    if (key.kind === "io") return false;
    if (key.kind === "ok") {
      this.e2eKeyValue = key.key;
      this.keyStateValue = "ok";
      clearRegistryError(this.dir, RegistryReason.keyIO);
      return true;
    }
    this.resetIdentity("key_unreadable");
    return true;
  }

  /**
   * PROTOCOL-v3 Appendix A の resetIdentity。reset-pending を最初に書き、端末の一覧を空にし、鍵・中継の ID・ローカル鍵を作り直し、
   * トンネルを張り直し（listener）、最後に reset-pending を消す。途中で落ちても次の起動で 2 から続ける。
   */
  resetIdentity(reason: ResetReason): void {
    writePrivateFile(path.join(this.dir, "reset-pending"), JSON.stringify({ reason, at: this.now() }));
    this.finishReset(reason);
  }

  private finishReset(reason: ResetReason, devicesDone = false): void {
    // 2. 端末を先に消す（途中で落ちても古い端末が残らない）。移行では空の一覧（epoch 1）を作ってある。
    if (!devicesDone) this.devices.resetAll(reason);
    // 3. 静的鍵・中継の ID・ローカル鍵（account_removed・machine_changed は bridgeId も。端末トークンと登録した値は捨てる）。
    this.regenerateSecrets();
    if (RENEWS_BRIDGE_ID.includes(reason)) {
      removeFile(path.join(this.dir, "device-token"));
      this.regenerateBridgeId();
      clearRegistered(this.dir);
    }
    // この PC をアカウントから外した: デスクトップでサインインし直す（/local/registry/resume）まで登録しない（PROTOCOL-v3 §15.7）。
    if (reason === "account_removed") setRegistryHold(this.dir, "account_removed");
    // 4. 中継のトンネルを張り直す・招待とプレビューのセッションを捨てる。
    for (const listener of this.listeners) {
      try {
        listener(reason);
      } catch (err) {
        this.log(`reset listener failed: ${String(err)}`);
      }
    }
    // 移行だけ: 使わなくなったファイルを消し、移行済みの印を書く。
    if (reason === "migration_v3") {
      for (const stale of ["e2e-devices.json", "push_tokens.json", "pairing-qr.png"]) removeFile(path.join(this.dir, stale));
      removeFile(path.join(this.homeDir, ".buddyos", "push_tokens.json"));
      writePrivateFile(path.join(this.dir, "auth-v3.json"), JSON.stringify({ migratedAt: this.now(), machineId: null }));
    }
    // 5.
    removeFile(path.join(this.dir, "reset-pending"));
    this.log(`connection details were recreated (${reason})`);
  }

  /**
   * bridgeId を作り直す（account_removed・machine_changed・アカウントから外されたとき・登録簿の 409）。
   * BUDDYOS_BRIDGE_ID で固定しているときは作り直せない（false）。
   */
  regenerateBridgeId(): boolean {
    if (this.env.BUDDYOS_BRIDGE_ID) {
      this.log("BUDDYOS_BRIDGE_ID is set; the bridgeId cannot be renewed");
      return false;
    }
    this.bridgeIdValue = newBridgeId();
    writePrivateFile(path.join(this.dir, "bridge-id"), `${this.bridgeIdValue}\n`);
    return true;
  }

  /** 登録簿が返した bridgeId（端末トークンの行のもの）に合わせる。BUDDYOS_BRIDGE_ID のときはファイルに書かない。 */
  adoptBridgeId(id: string): void {
    this.bridgeIdValue = id;
    if (!this.env.BUDDYOS_BRIDGE_ID) writePrivateFile(path.join(this.dir, "bridge-id"), `${id}\n`);
  }

  /**
   * 登録簿で 403 revoked（アカウントから外された。PROTOCOL-v3 §15.7）。端末トークンを消し、bridgeId を作り直し、registry-hold を置く。
   * 端末の一覧と鍵はここでは消さない（Clerk のトークンだけで全ペアリングを消させないため。端末も切断するかはデスクトップで選ぶ）。
   */
  accountRevoked(): void {
    removeFile(path.join(this.dir, "device-token"));
    this.regenerateBridgeId();
    clearRegistered(this.dir);
    setRegistryHold(this.dir, "revoked_by_account");
    this.devices.bump();
    this.log("removed from the account; bridgeId renewed and registration on hold");
  }

  private regenerateSecrets(): void {
    const key = crypto.randomBytes(32);
    writePrivateFile(path.join(this.dir, "e2e-key"), `${key.toString("base64")}\n`);
    this.e2eKeyValue = key;
    if (this.keyStateValue === "io_error") clearRegistryError(this.dir, RegistryReason.keyIO);
    this.keyStateValue = "ok";
    this.relayIdValue = crypto.randomBytes(32).toString("base64url");
    writePrivateFile(path.join(this.dir, "paseo-relay-id"), this.relayIdValue);
    if (this.localKeyFixed) {
      this.log("BUDDYOS_BRIDGE_API_KEY is set; the local key cannot be recreated");
      this.localKeyValue = this.env.BUDDYOS_BRIDGE_API_KEY!;
    } else {
      this.localKeyValue = randomSecret();
      writePrivateFile(path.join(this.dir, "api-key"), `${this.localKeyValue}\n`);
    }
  }

  private readLocalKey(): string {
    if (this.localKeyFixed) {
      this.log("BUDDYOS_BRIDGE_API_KEY is set; the local key cannot be recreated by a reset");
      return this.env.BUDDYOS_BRIDGE_API_KEY!;
    }
    return readOrCreate(path.join(this.dir, "api-key"), () => randomSecret());
  }
}

// ---- ファイル ----

/**
 * 設定フォルダ（鍵・会話の履歴・ロック）を所有者だけが入れる 0700 で作る。以前の版で 0755 で作ったものも絞り直す
 * （Linux / WSL 向け。Windows は %LOCALAPPDATA% の ACL がユーザー専用なので mode は効かない）。
 */
export function ensurePrivateDir(dir: string): void {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  if (process.platform === "win32") return;
  try {
    fs.chmodSync(dir, 0o700);
  } catch (err) {
    console.error(`[bridge] could not restrict ${dir}: ${String(err)}`);
  }
}

/** 一時ファイルに 0600 で書いてから置き換える（書きかけをデスクトップアプリに読ませない）。 */
export function writePrivateFile(file: string, content: string): void {
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, content, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

function removeFile(file: string): void {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    /* 消せなくても続ける */
  }
}

function readOrCreate(file: string, create: () => string): string {
  try {
    const value = fs.readFileSync(file, "utf8").trim();
    if (value) return value;
  } catch {
    /* 未作成 = 生成へ */
  }
  const value = create();
  writePrivateFile(file, `${value}\n`);
  return value;
}

function randomSecret(): string {
  return crypto.randomBytes(32).toString("base64url");
}

function newBridgeId(): string {
  return `windows-bridge-${crypto.randomUUID()}`;
}

export type E2EKeyRead =
  | { kind: "ok"; key: Buffer }
  | { kind: "missing" }
  | { kind: "corrupt" }
  /** 権限・I/O の一時的な失敗（EACCES・EPERM・EIO など）。作り直さない。 */
  | { kind: "io"; code: string };

/** e2e-key を読み、読めない原因を分ける（無い・壊れている＝作り直す、権限・I/O＝待つ）。 */
export function readE2EKey(file: string): E2EKeyRead {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code ?? "EIO";
    return code === "ENOENT" ? { kind: "missing" } : { kind: "io", code };
  }
  const trimmed = text.trim();
  const raw = Buffer.from(trimmed, "base64");
  if (raw.length !== 32 || raw.toString("base64").replace(/=+$/, "") !== trimmed.replace(/=+$/, "")) return { kind: "corrupt" };
  return { kind: "ok", key: raw };
}

function readResetPending(file: string): { reason: ResetReason; at: number } | undefined {
  try {
    const value = JSON.parse(fs.readFileSync(file, "utf8")) as { reason?: unknown; at?: unknown };
    const reasons: readonly string[] = ["migration_v3", "user_reset", "account_removed", "revoked_by_account", "key_unreadable", "machine_changed"];
    if (typeof value.reason === "string" && reasons.includes(value.reason)) {
      return { reason: value.reason as ResetReason, at: typeof value.at === "number" ? value.at : 0 };
    }
    // 読めない印は「ユーザーの作り直し」として続ける（途中で止めたままにしない）。
    return { reason: "user_reset", at: 0 };
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    return { reason: "user_reset", at: 0 };
  }
}

/**
 * 中継の serverId（paseo-relay-id）の readOrCreate。mac の KeyStore.loadOrCreatePaseoRelayId と同じく
 * 乱数 32B の base64url（padding なし、改行なし）で保存する。資格情報ではないが推測できない値にする。
 */
export function loadOrCreatePaseoRelayId(file: string): string {
  try {
    const id = fs.readFileSync(file, "utf8").trim();
    if (id) return id;
  } catch {
    /* 未作成 = 生成へ */
  }
  const id = crypto.randomBytes(32).toString("base64url");
  try {
    writePrivateFile(file, id);
  } catch (err) {
    console.error(`[paseo] could not save paseo-relay-id: ${String(err)}`);
  }
  return id;
}

/** 以前の置き場所（%APPDATA%\BuddyOS\Bridge）から移すもの。鍵は移さない。 */
const LEGACY_STATE = ["sessions.json", "session-overrides.json", "projects.json", "claude-terminals.json", "cron_pushed.json", "cron"];
const LEGACY_SECRETS = ["e2e-key", "api-key", "paseo-relay-id", "e2e-devices.json"];

/**
 * %APPDATA%（Roaming）からの移行。ドメインのプロファイルでは Roaming が他の PC に写り、2 台が
 * 同じ鍵と relayId で動いてしまうため、bridge-id だけを移し（Roaming からは消す）、Roaming の鍵は消す。
 * 会話の一覧・定期実行などの鍵でない状態は、新しい置き場所に無いときだけ写す（Roaming 側は残す）。
 */
export function migrateLegacyDir(legacyDir: string, dir: string, log: (m: string) => void = (m) => console.log(`[bridge] ${m}`)): void {
  if (path.resolve(legacyDir) === path.resolve(dir) || !fs.existsSync(legacyDir)) return;
  ensurePrivateDir(dir);
  const legacyId = path.join(legacyDir, "bridge-id");
  try {
    if (fs.existsSync(legacyId)) {
      if (!fs.existsSync(path.join(dir, "bridge-id"))) fs.copyFileSync(legacyId, path.join(dir, "bridge-id"));
      fs.rmSync(legacyId, { force: true });
      log(`moved bridge-id from ${legacyDir}`);
    }
  } catch (err) {
    log(`could not move bridge-id: ${String(err)}`);
  }
  for (const name of LEGACY_STATE) {
    const from = path.join(legacyDir, name);
    const to = path.join(dir, name);
    try {
      if (fs.existsSync(from) && !fs.existsSync(to)) fs.cpSync(from, to, { recursive: true });
    } catch (err) {
      log(`could not copy ${name}: ${String(err)}`);
    }
  }
  for (const name of LEGACY_SECRETS) removeFile(path.join(legacyDir, name));
}
