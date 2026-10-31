import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { b64uDecodeStrict, credentialHash, displayName } from "./tunnelV3.js";

// 端末の一覧（devices.json と devices.json.bak）。spec/PROTOCOL-v3.md Appendix A・§14。
// mac の DeviceStore.swift と同じ形。変更はメモリの値に対して行い、その時点の値を丸ごと書く（古い写しを書き戻さない）。
// Node は 1 本のスレッドで動くので、メモリの変更と同期の書き込みを 1 つの関数の中で行えば、mac の lock と同じ順番になる。
// 行の state（pendingAck / unpairing）はメモリにだけ持ち、pendingAck の行はファイルに書かない。

/** 1 台の Bridge に登録できる端末（PROTOCOL-v3 §12）。 */
export const MAX_DEVICES = 20;
/** 外した端末の印を残す期間（PROTOCOL-v3 §12）。 */
export const REVOKED_MARK_MS = 90 * 24 * 60 * 60 * 1000;
/** 一度もつながっていない行を消すまで（PROTOCOL-v3 §12）。 */
export const NEVER_SEEN_TTL_MS = 24 * 60 * 60 * 1000;
/** lastSeenAt をファイルに書く間隔の下限（PROTOCOL-v3 §10.2）。 */
export const LAST_SEEN_WRITE_INTERVAL_MS = 5 * 60 * 1000;

export type DeviceState = "pendingAck" | "unpairing";
export type ResetReason =
  | "migration_v3"
  | "user_reset"
  | "account_removed"
  | "revoked_by_account"
  | "key_unreadable"
  | "machine_changed"
  | "devices_missing"
  | "devices_restored";

export interface DevicePush {
  /** APNs のトークン（小文字の 16 進）。 */
  token: string;
  env: "development" | "production";
  locale: "ja" | "en";
}

export interface DeviceRow {
  /** 端末の静的公開鍵（b64u 32 バイト）。 */
  pub: string;
  clientDeviceId: string;
  /** 端末が名乗った名前（PROTOCOL-v3 §5.3 で無害化済み）。 */
  name: string;
  /** デスクトップで付けたラベル。 */
  label: string | null;
  platform: string;
  /** bdc_ の SHA-256（16 進）。 */
  credHash: string;
  via: "qr" | "approval";
  createdAt: number;
  lastSeenAt?: number;
  push?: DevicePush;
  /**
   * スマホで許可してつないだ端末なら、許可したスマホの deviceKeyId（spec/PROTOCOL-v3.md §10.4.1）。
   * PC で入力したとき・QR のときは付けない。古いファイルとの互換のため任意（mac の Device.approvedBy と同じ）。
   */
  approvedBy?: string;
}

/** devices.json の settings。remoteApprovalsEnabled は任意（無ければ有効。spec/PROTOCOL-v3.md §10.4.1。mac と同じく変えたときだけ書く）。 */
export interface DeviceSettings {
  approvalsEnabled: boolean;
  remoteApprovalsEnabled?: boolean;
}

interface DevicesFile {
  v: 3;
  epoch: number;
  settings: DeviceSettings;
  devices: Record<string, DeviceRow>;
  revoked: Record<string, number>;
  lastReset?: { at: number; reason: ResetReason };
}

export type SetPushResult = "ok" | "unchanged" | "conflict" | "invalid" | "unknown";

export interface DeviceStoreOptions {
  now?: () => number;
  log?: (message: string) => void;
}

/** 長いポーリング（/local/devices/events）の待ち合わせ。 */
interface Waiter {
  resolve: () => void;
  timer: NodeJS.Timeout;
}

export class DeviceStore {
  readonly file: string;
  readonly backup: string;
  /** Bridge の起動ごとに変わる乱数（b64u 8 バイト。PROTOCOL-v3 Appendix A）。 */
  readonly bootId = crypto.randomBytes(8).toString("base64url");
  private data: DevicesFile;
  private readonly states = new Map<string, DeviceState>();
  private brokenValue = false;
  private versionValue = 0;
  private waiters = new Set<Waiter>();
  private lastSeenWrittenAt = 0;
  private lastSeenTimer?: NodeJS.Timeout;
  private readonly now: () => number;
  private readonly log: (message: string) => void;

  private constructor(dir: string, data: DevicesFile, opts: DeviceStoreOptions) {
    this.file = path.join(dir, "devices.json");
    this.backup = path.join(dir, "devices.json.bak");
    this.data = data;
    this.now = opts.now ?? Date.now;
    this.log = opts.log ?? ((m) => console.log(`[devices] ${m}`));
  }

  /** 移行・作り直しのときの空の一覧を作って書く。 */
  static createFresh(dir: string, reason: ResetReason, opts: DeviceStoreOptions = {}): DeviceStore {
    const now = (opts.now ?? Date.now)();
    const store = new DeviceStore(dir, emptyFile(1, { at: now, reason }), opts);
    store.write();
    return store;
  }

  /**
   * 移行済みの Bridge の起動時。devices.json が読めなければ .bak から戻し（devices_restored）、
   * どちらも無ければ空で作る（devices_missing）。どちらも読めない・形が違うときは上書きせず「壊れている」にする。
   */
  static open(dir: string, opts: DeviceStoreOptions = {}): DeviceStore {
    const now = (opts.now ?? Date.now)();
    const main = readDevicesFile(path.join(dir, "devices.json"));
    if (main.kind === "ok") return new DeviceStore(dir, main.data, opts);
    const bak = readDevicesFile(path.join(dir, "devices.json.bak"));
    if (bak.kind === "ok") {
      const store = new DeviceStore(dir, { ...bak.data, lastReset: { at: now, reason: "devices_restored" } }, opts);
      store.write();
      store.log(`devices.json ${main.kind === "missing" ? "was missing" : "was unreadable"}; restored from backup`);
      return store;
    }
    if (main.kind === "missing" && bak.kind === "missing") {
      const store = new DeviceStore(dir, emptyFile(1, { at: now, reason: "devices_missing" }), opts);
      store.write();
      return store;
    }
    const store = new DeviceStore(dir, emptyFile(0), opts);
    store.brokenValue = true;
    store.log("devices.json and its backup are unreadable; refusing devices until reset");
    return store;
  }

  /** devices.json が壊れていて、すべての端末に bridge_error を返す状態か。 */
  get broken(): boolean {
    return this.brokenValue;
  }

  /** 「すべての端末を切断」などで 1 増える数（PROTOCOL-v3 §10）。 */
  get epoch(): number {
    return this.data.epoch;
  }

  /** 端末・承認待ち・招待・窓のどれかが変わるたびに 1 増える（メモリだけ）。 */
  get version(): number {
    return this.versionValue;
  }

  get lastReset(): { at: number; reason: ResetReason } | undefined {
    return this.data.lastReset;
  }

  /** アカウントで見つけた PC からの承認を受け付けるか（設定 approvalsEnabled）。 */
  get approvalsSetting(): boolean {
    return this.data.settings.approvalsEnabled;
  }

  /** スマホからの許可を受け付けるか（設定が無ければ有効。spec/PROTOCOL-v3.md §10.4.1）。 */
  get remoteApprovalsEnabled(): boolean {
    return this.data.settings.remoteApprovalsEnabled ?? true;
  }

  /**
   * 許可できる端末か（spec/PROTOCOL-v3.md §10.4.1）。確定済みで、platform が ios か android の行。
   * デスクトップ（別の PC）は許可できない（PC の連鎖で増やせないように）。
   */
  isApprover(deviceKeyId: string): boolean {
    const row = this.data.devices[deviceKeyId];
    return !!row && !this.states.has(deviceKeyId) && isApproverPlatform(row.platform);
  }

  /** 許可できる端末のうち push の宛先があるもの（pair_request の送り先）。 */
  approverPushTargets(): ReturnType<DeviceStore["pushTargets"]> {
    return this.pushTargets().filter((t) => isApproverPlatform(t.row.platform));
  }

  /** スマホでの許可が使えるか（設定が有効で、許可できる端末で push の宛先があるものが 1 台以上。spec/PROTOCOL-v3.md §10.4.1）。 */
  get remoteApprovalsAvailable(): boolean {
    return this.remoteApprovalsEnabled && this.approverPushTargets().length > 0;
  }

  /** 同じ name でラベルの無い行の数（承認待ちの sameNameExists。mac の sameNameCount と同じ）。 */
  sameNameCount(name: string): number {
    return Object.values(this.data.devices).filter((row) => row.label === null && row.name === name).length;
  }

  /** 招待など、この一覧の外の変化も version に載せる。 */
  bump(): void {
    this.versionValue += 1;
    const waiters = [...this.waiters];
    this.waiters.clear();
    for (const w of waiters) {
      clearTimeout(w.timer);
      w.resolve();
    }
  }

  /** version か bootId が違えばすぐ、そうでなければ変化か timeoutMs で戻る（PROTOCOL-v3 Appendix A の events）。 */
  waitForChange(since: number | undefined, boot: string | undefined, timeoutMs: number): Promise<void> {
    if (since !== this.versionValue || boot !== this.bootId) return Promise.resolve();
    return new Promise((resolve) => {
      const waiter: Waiter = {
        resolve,
        timer: setTimeout(() => {
          this.waiters.delete(waiter);
          resolve();
        }, timeoutMs)
      };
      waiter.timer.unref?.();
      this.waiters.add(waiter);
    });
  }

  get(deviceKeyId: string): DeviceRow | undefined {
    return this.data.devices[deviceKeyId];
  }

  state(deviceKeyId: string): DeviceState | undefined {
    return this.states.get(deviceKeyId);
  }

  /** 外した印があるか（90 日）。 */
  isRevoked(deviceKeyId: string): boolean {
    const at = this.data.revoked[deviceKeyId];
    return at !== undefined && this.now() - at < REVOKED_MARK_MS;
  }

  /** この端末を入れると 20 台を超えるか（その端末がまだ一覧に無いときだけ数える）。 */
  wouldExceedLimit(deviceKeyId: string): boolean {
    return !this.data.devices[deviceKeyId] && Object.keys(this.data.devices).length >= MAX_DEVICES;
  }

  /** 確定済みの行（state の無い行）の deviceKeyId。 */
  confirmedIds(): string[] {
    return Object.keys(this.data.devices).filter((id) => !this.states.has(id));
  }

  /**
   * ペアリングの途中の行を入れる（同じ deviceKeyId の行があれば置き換える。PROTOCOL-v3 §10.3）。
   * QR でのペアリングなので外した印も消す（PROTOCOL-v3 §8.10）。ファイルには確定してから書く。
   */
  putPending(deviceKeyId: string, row: DeviceRow): void {
    this.data.devices[deviceKeyId] = row;
    this.states.set(deviceKeyId, "pendingAck");
    if (row.via === "qr") delete this.data.revoked[deviceKeyId];
    this.bump();
  }

  /**
   * approve で番号が合った行を入れる（mac の insertPending と同じ）。壊れている・epoch が変わった・20 台を超えるなら false。
   * 承認では外した印を消さない（外した端末は msg1 で revoked。PROTOCOL-v3 §8.10）。
   */
  insertPending(deviceKeyId: string, row: DeviceRow, epoch: number): boolean {
    if (this.brokenValue || this.data.epoch !== epoch || this.wouldExceedLimit(deviceKeyId)) return false;
    this.putPending(deviceKeyId, row);
    return true;
  }

  /** paired_ack が届いた行を確定してファイルに書く。行が置き換わっていたら何もしない。 */
  confirm(deviceKeyId: string, credHash: string): boolean {
    const row = this.data.devices[deviceKeyId];
    if (!row || row.credHash !== credHash || this.states.get(deviceKeyId) !== "pendingAck") return false;
    this.states.delete(deviceKeyId);
    this.write();
    this.bump();
    return true;
  }

  /** paired_ack が来なかった行を消す（同じ資格情報の、まだ確定していない行だけ）。 */
  removePending(deviceKeyId: string, credHash: string): void {
    const row = this.data.devices[deviceKeyId];
    if (!row || row.credHash !== credHash || this.states.get(deviceKeyId) !== "pendingAck") return;
    delete this.data.devices[deviceKeyId];
    this.states.delete(deviceKeyId);
    // 置き換えた古い行もファイルから消える（pendingAck の行は書かないので、その時点のメモリの値を書く）。
    this.write();
    this.bump();
  }

  /** PC から外す（外した印を 90 日残す。PROTOCOL-v3 Appendix A）。 */
  revoke(deviceKeyId: string): boolean {
    if (!this.data.devices[deviceKeyId]) return false;
    delete this.data.devices[deviceKeyId];
    this.states.delete(deviceKeyId);
    this.data.revoked[deviceKeyId] = this.now();
    this.write();
    this.bump();
    return true;
  }

  /** 端末からの解除（PROTOCOL-v3 §13.5）。受けた時点で unpairing にし、新しい connect・HTTP を断る。 */
  markUnpairing(deviceKeyId: string): boolean {
    if (!this.data.devices[deviceKeyId] || this.states.has(deviceKeyId)) return false;
    this.states.set(deviceKeyId, "unpairing");
    this.bump();
    return true;
  }

  /** 解除中の行を消す（外した印は残さない）。 */
  removeUnpairing(deviceKeyId: string): void {
    if (this.states.get(deviceKeyId) !== "unpairing") return;
    delete this.data.devices[deviceKeyId];
    this.states.delete(deviceKeyId);
    this.write();
    this.bump();
  }

  /** デスクトップで付けるラベル（空ならラベルを外す）。成功なら表示名を返す。 */
  rename(deviceKeyId: string, label: string | null): string | undefined {
    const row = this.data.devices[deviceKeyId];
    if (!row || this.states.has(deviceKeyId)) return undefined;
    row.label = label;
    this.write();
    this.bump();
    return displayName(label ?? row.name, deviceKeyId);
  }

  /** トンネルの中の Bearer（bdc_）の照合。定数時間で比べ、state のある行は通さない（PROTOCOL-v3 §13.2）。 */
  verify(deviceKeyId: string, credential: string): boolean {
    const row = this.data.devices[deviceKeyId];
    if (!row || this.states.has(deviceKeyId) || !credential.startsWith("bdc_")) return false;
    const a = Buffer.from(credentialHash(credential), "hex");
    const b = Buffer.from(row.credHash, "hex");
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }

  /**
   * register_push_token（PROTOCOL-v3 §14）。トークンは小文字にしてから形を確かめる。同じトークンが別の端末の行にあれば、
   * clientDeviceId が同じときだけ移し、違えば何も変えずに断る（悪い端末が他の端末の通知を止められないように）。
   */
  setPush(deviceKeyId: string, rawToken: string, environment: string | undefined, locale: string | undefined): SetPushResult {
    const row = this.data.devices[deviceKeyId];
    if (!row || this.states.has(deviceKeyId)) return "unknown";
    const token = rawToken.toLowerCase();
    if (!/^[0-9a-f]{64,200}$/.test(token)) return "invalid";
    const env: DevicePush["env"] = environment === "production" ? "production" : "development";
    const loc: DevicePush["locale"] = locale === "en" ? "en" : "ja";
    let moveFrom: string | undefined;
    for (const [id, other] of Object.entries(this.data.devices)) {
      if (id === deviceKeyId || other.push?.token !== token) continue;
      if (other.clientDeviceId !== row.clientDeviceId) {
        this.log(`push token of ${id.slice(0, 8)} is claimed by ${deviceKeyId.slice(0, 8)}; refused`);
        return "conflict";
      }
      moveFrom = id;
    }
    if (!moveFrom && row.push?.token === token && row.push.env === env && row.push.locale === loc) return "unchanged";
    if (moveFrom) delete this.data.devices[moveFrom].push;
    row.push = { token, env, locale: loc };
    this.write();
    this.bump();
    return "ok";
  }

  /** 無効になったトークンを外す（push の応答で invalid と言われたもの）。 */
  removePushToken(token: string): void {
    let changed = false;
    for (const row of Object.values(this.data.devices)) {
      if (row.push?.token === token.toLowerCase()) {
        delete row.push;
        changed = true;
      }
    }
    if (changed) {
      this.write();
      this.bump();
    }
  }

  /** push の宛先がある、確定済みの端末。 */
  pushTargets(): Array<{ deviceKeyId: string; row: DeviceRow; push: DevicePush }> {
    const out: Array<{ deviceKeyId: string; row: DeviceRow; push: DevicePush }> = [];
    for (const [id, row] of Object.entries(this.data.devices)) {
      if (!this.states.has(id) && row.push) out.push({ deviceKeyId: id, row, push: row.push });
    }
    return out;
  }

  /** つながった時刻（メモリはすぐ、ファイルは 5 分に 1 回まで。行がまだあるときだけ）。 */
  touch(deviceKeyId: string): void {
    const row = this.data.devices[deviceKeyId];
    if (!row || this.states.has(deviceKeyId)) return;
    const firstSeen = row.lastSeenAt === undefined;
    row.lastSeenAt = this.now();
    if (firstSeen || this.now() - this.lastSeenWrittenAt >= LAST_SEEN_WRITE_INTERVAL_MS) {
      this.write();
      return;
    }
    if (this.lastSeenTimer) return;
    this.lastSeenTimer = setTimeout(() => {
      this.lastSeenTimer = undefined;
      if (!this.brokenValue) this.write();
    }, LAST_SEEN_WRITE_INTERVAL_MS - (this.now() - this.lastSeenWrittenAt));
    this.lastSeenTimer.unref?.();
  }

  /** アカウントで見つけた PC からの承認（設定 approvalsEnabled）。切ったときの承認待ちの取り下げは呼び出し側（localRoutes.ts）が行う。 */
  setApprovalsEnabled(enabled: boolean): void {
    if (this.brokenValue) return;
    this.data.settings.approvalsEnabled = enabled;
    this.write();
    this.bump();
  }

  /** スマホからの許可（spec/PROTOCOL-v3.md §10.4.1）。切ったときの remote の申し込みの取り下げは呼び出し側が行う。 */
  setRemoteApprovalsEnabled(enabled: boolean): void {
    if (this.brokenValue || this.data.settings.remoteApprovalsEnabled === enabled) return;
    this.data.settings.remoteApprovalsEnabled = enabled;
    this.write();
    this.bump();
  }

  /** 一度もつながらない行（24 時間）と、古い外した印（90 日）を消す（起動時と 1 時間ごと）。 */
  purge(): void {
    if (this.brokenValue) return;
    const t = this.now();
    let changed = false;
    for (const [id, row] of Object.entries(this.data.devices)) {
      if (this.states.has(id)) continue;
      if (row.lastSeenAt === undefined && t - row.createdAt >= NEVER_SEEN_TTL_MS) {
        delete this.data.devices[id];
        changed = true;
      }
    }
    for (const [id, at] of Object.entries(this.data.revoked)) {
      if (t - at >= REVOKED_MARK_MS) {
        delete this.data.revoked[id];
        changed = true;
      }
    }
    if (changed) {
      this.write();
      this.bump();
    }
  }

  /**
   * 「すべての端末を切断」などの 2 番目の手順（PROTOCOL-v3 Appendix A）。端末を空にして epoch を 1 増やす。壊れたファイルは
   * devices.json.broken-<UNIX ミリ秒> に移してから書き直す。
   */
  resetAll(reason: ResetReason): void {
    const t = this.now();
    if (this.brokenValue) {
      try {
        if (fs.existsSync(this.file)) fs.renameSync(this.file, `${this.file}.broken-${t}`);
      } catch (err) {
        this.log(`could not move the broken devices.json aside: ${String(err)}`);
      }
      this.brokenValue = false;
    }
    const revoked = this.data.revoked;
    this.data = emptyFile(this.data.epoch + 1, { at: t, reason }, this.data.settings);
    this.data.revoked = revoked;
    this.states.clear();
    this.write();
    this.bump();
  }

  /** 設定画面に出す一覧（PROTOCOL-v3 Appendix A の DevicesView のうち、端末の部分）。 */
  deviceViews(isOnline: (deviceKeyId: string) => boolean): Array<Record<string, unknown>> {
    // approvedBy は許可した端末の表示名。その端末が一覧から消えていれば deviceKeyId の先頭 4 文字（spec/PROTOCOL-v3.md §10.4.1）。
    const approverName = (id: string | undefined): string | null => {
      if (!id) return null;
      const approver = this.data.devices[id];
      return approver && !this.states.has(id) ? displayName(approver.label ?? approver.name, id) : id.slice(0, 4);
    };
    const rows = Object.entries(this.data.devices).filter(([id]) => !this.states.has(id));
    // sameNameCount はラベルの無い端末どうしで、同じ name の数（PROTOCOL-v3 Appendix A。Mac と同じ）。ラベルを付けた端末は 1。
    const nameCounts = new Map<string, number>();
    for (const [, row] of rows) {
      if (row.label === null) nameCounts.set(row.name, (nameCounts.get(row.name) ?? 0) + 1);
    }
    return rows
      .sort((a, b) => a[1].createdAt - b[1].createdAt)
      .map(([id, row]) => ({
        deviceKeyId: id,
        name: row.name,
        label: row.label,
        display: displayName(row.label ?? row.name, id),
        platform: row.platform,
        via: row.via,
        createdAt: row.createdAt,
        lastSeenAt: row.lastSeenAt ?? null,
        online: isOnline(id),
        push: !!row.push,
        sameNameCount: row.label === null ? (nameCounts.get(row.name) ?? 1) : 1,
        approvedBy: approverName(row.approvedBy)
      }));
  }

  /** その時点のメモリの値を devices.json と .bak に書く（どちらも一時ファイル → rename）。壊れている間は書かない。 */
  private write(): void {
    if (this.brokenValue) return;
    const devices: Record<string, DeviceRow> = {};
    for (const [id, row] of Object.entries(this.data.devices)) {
      if (this.states.get(id) !== "pendingAck") devices[id] = row;
    }
    const text = JSON.stringify({ ...this.data, devices });
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true, mode: 0o700 });
      for (const target of [this.file, this.backup]) {
        const tmp = `${target}.${process.pid}.tmp`;
        fs.writeFileSync(tmp, text, { mode: 0o600 });
        fs.renameSync(tmp, target);
      }
      if (this.lastSeenTimer) {
        clearTimeout(this.lastSeenTimer);
        this.lastSeenTimer = undefined;
      }
      this.lastSeenWrittenAt = this.now();
    } catch (err) {
      this.log(`could not save devices.json: ${String(err)}`);
    }
  }
}

function emptyFile(epoch: number, lastReset?: { at: number; reason: ResetReason }, settings: DeviceSettings = { approvalsEnabled: true }): DevicesFile {
  return { v: 3, epoch, settings: { ...settings }, devices: {}, revoked: {}, ...(lastReset ? { lastReset } : {}) };
}

/** 許可できる端末の platform（spec/PROTOCOL-v3.md §10.4.1）。 */
export function isApproverPlatform(platform: string): boolean {
  return platform === "ios" || platform === "android";
}

type ReadResult = { kind: "ok"; data: DevicesFile } | { kind: "missing" } | { kind: "bad" };

const RESET_REASONS: readonly string[] = [
  "migration_v3",
  "user_reset",
  "account_removed",
  "revoked_by_account",
  "key_unreadable",
  "machine_changed",
  "devices_missing",
  "devices_restored"
];

/** devices.json を読み、形を確かめる（1 行でも形が違えば、全体を読めないものとして扱う）。 */
export function readDevicesFile(file: string): ReadResult {
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "ENOENT" ? { kind: "missing" } : { kind: "bad" };
  }
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return { kind: "bad" };
  }
  if (!isObject(value) || value.v !== 3 || !Number.isInteger(value.epoch) || (value.epoch as number) < 0) return { kind: "bad" };
  if (!isObject(value.devices) || !isObject(value.revoked)) return { kind: "bad" };
  const settings = isObject(value.settings) ? value.settings : {};
  const devices: Record<string, DeviceRow> = {};
  for (const [id, raw] of Object.entries(value.devices)) {
    const row = parseRow(raw);
    if (!row || !b64uDecodeStrict(id, 16)) return { kind: "bad" };
    devices[id] = row;
  }
  const revoked: Record<string, number> = {};
  for (const [id, at] of Object.entries(value.revoked)) {
    if (typeof at !== "number") return { kind: "bad" };
    revoked[id] = at;
  }
  let lastReset: DevicesFile["lastReset"];
  if (isObject(value.lastReset) && typeof value.lastReset.at === "number" && RESET_REASONS.includes(String(value.lastReset.reason))) {
    lastReset = { at: value.lastReset.at, reason: value.lastReset.reason as ResetReason };
  }
  return {
    kind: "ok",
    data: {
      v: 3,
      epoch: value.epoch as number,
      settings: {
        approvalsEnabled: settings.approvalsEnabled !== false,
        ...(typeof settings.remoteApprovalsEnabled === "boolean" ? { remoteApprovalsEnabled: settings.remoteApprovalsEnabled } : {})
      },
      devices,
      revoked,
      ...(lastReset ? { lastReset } : {})
    }
  };
}

function parseRow(raw: unknown): DeviceRow | undefined {
  if (!isObject(raw)) return undefined;
  const { pub, clientDeviceId, name, label, platform, credHash, via, createdAt, lastSeenAt, push, approvedBy } = raw;
  if (typeof pub !== "string" || !b64uDecodeStrict(pub, 32)) return undefined;
  if (typeof clientDeviceId !== "string" || typeof name !== "string" || typeof platform !== "string") return undefined;
  if (label !== null && label !== undefined && typeof label !== "string") return undefined;
  if (typeof credHash !== "string" || !/^[0-9a-f]{64}$/.test(credHash)) return undefined;
  if (via !== "qr" && via !== "approval") return undefined;
  if (typeof createdAt !== "number" || (lastSeenAt !== undefined && typeof lastSeenAt !== "number")) return undefined;
  // approvedBy は任意（古いファイルには無い）。null は無いのと同じ（mac の String? と同じ読み方）。
  if (approvedBy !== undefined && approvedBy !== null && typeof approvedBy !== "string") return undefined;
  let pushValue: DevicePush | undefined;
  if (push !== undefined) {
    if (!isObject(push) || typeof push.token !== "string" || !/^[0-9a-f]{64,200}$/.test(push.token)) return undefined;
    pushValue = {
      token: push.token,
      env: push.env === "production" ? "production" : "development",
      locale: push.locale === "en" ? "en" : "ja"
    };
  }
  return {
    pub,
    clientDeviceId,
    name,
    label: typeof label === "string" ? label : null,
    platform,
    credHash,
    via,
    createdAt,
    ...(lastSeenAt !== undefined ? { lastSeenAt: lastSeenAt as number } : {}),
    ...(pushValue ? { push: pushValue } : {}),
    ...(typeof approvedBy === "string" ? { approvedBy } : {})
  };
}

function isObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
