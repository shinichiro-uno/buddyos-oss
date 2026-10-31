import crypto from "node:crypto";
import net from "node:net";
import { WebSocket, type RawData } from "ws";
import { PENDING_LIFETIME_MS, type ApprovalQueue, type ApproveOutcome, type EndReason } from "./approvalQueue.js";
import type { TunnelPeer, TunnelPeers } from "./auth.js";
import type { DeviceRow, DeviceStore } from "./deviceStore.js";
import { E2EFrameReceiver, E2EFrameSender, FRAME_MAX_LENGTH, FRAME_VERSION_V3 } from "./e2e.js";
import type { PairingInvites } from "./pairingInvites.js";
import { RELAY_HINT } from "./settings.js";
import { trafficMeter } from "./trafficMeter.js";
import {
  APPROVAL_WAITING_MESSAGE,
  approveRevealMessage,
  b64u,
  CONTROL_MAX_BYTES,
  credentialHash,
  DEVICE_NAME_FALLBACK,
  deviceKeyId as deviceKeyIdOf,
  displayName,
  helloText,
  newCredential,
  pairedMessage,
  pairRejectedMessage,
  parseControl,
  parseInitV3,
  parsePayload1,
  payload2Error,
  payload2Ok,
  PROLOGUE,
  responderRead1,
  responderWrite2,
  sasCode,
  sasCommit,
  tunnelErrorText,
  ZERO_PSK,
  type Payload1,
  type Payload2Error,
  type PairRejectedReason,
  type Symmetric,
  type TunnelErrorCode
} from "./tunnelV3.js";

// NOTE: mac-bridge/Sources/Network/PaseoRelayTunnel.swift の Node 版（中継のサーバー側）。相手は
// ios/Sources/Core/PaseoRelayProxy.swift・desktop の paseoProxy.ts・Android の PaseoRelayProxy.kt（クライアント側）。
// トンネル v3（spec/PROTOCOL-v3.md §8）。ワイヤは shared/e2e-test-vectors.json の tunnelV3 で固定。
//
// 経路: 端末の 127.0.0.1 → Paseo v2 client WebSocket → 中継 → Paseo v2 server WebSocket（ここ）
//       → 127.0.0.1:<Bridge の待ち受け番号>。中継に平文で見えるのは一時鍵だけ。
//
// 制御用の接続（role=server、connectionId なし）に中継から次の TEXT が届く:
//   {"type":"connected","connectionId"} / {"type":"disconnected","connectionId"} / {"type":"sync","connectionIds":[...]}
// connected / sync のたびに、connectionId ごとのデータ用の接続（role=server&connectionId=...）を張る。
//
// データ用の接続 1 本の流れ（Noise_IKpsk2。端末が initiator、Bridge が responder）:
//   1. client → TEXT   {"type":"buddyos_tunnel_init","v":3,"e","s","p"}（350ms ごとに再送される）。v なし・v2 は version で断る
//   2. server → TEXT   {"type":"buddyos_tunnel_hello","v":3,"e","p"}（payload2。pair は招待の psk、それ以外は 0）
//   3. client → BINARY 最初のフレーム。connect は {"type":"open"}、pair は {"type":"pair_confirm"}、approve は {"type":"approve_nonce"}。
//      これが開けて初めて相手を信じる（それまでは何も書き換えない。PROTOCOL-v3 §10）
//   4. connect: 127.0.0.1:<待ち受け> へ TCP をつなぎ、送り元の番号 → 端末を TunnelPeers に入れてからバイト列を流す
//      pair: 行を仮登録して bdc_ を発行し {"type":"paired"} → {"type":"paired_ack"} で確定して close(1000)
//      approve（アカウントで見つけた PC からの承認。mac の runApprove）: msg2 に commit = H(nR) を入れ、approve_nonce で回数を数えて
//      承認待ち（approvalQueue.ts）を作り {"type":"approve_reveal","n":nR} を返す。待つ間は 20 秒ごとに approval_waiting。
//      PC（/local/devices/pending/approve）かスマホ（/device/approvals/approve）で番号が合ったら行を仮登録して paired、
//      60 秒以内の paired_ack で確定する。取り下げは {"type":"pair_rejected","reason"}。

/** 制御用の接続が受け取る 1 メッセージの上限（mac と同じ 1MB）。 */
const CONTROL_MAX_PAYLOAD = 1_048_576;
/** データ用の接続が受け取る 1 フレームの上限（16 MiB + ヘッダと tag。PROTOCOL-v3 §12）。 */
const DATA_MAX_PAYLOAD = FRAME_MAX_LENGTH;
/** 制御用の接続の死活確認。15 秒ごとに ping し、10 秒以内に pong が無ければ切って張り直す（mac と同じ）。 */
const HEARTBEAT_INTERVAL_MS = 15_000;
const PONG_DEADLINE_MS = 10_000;
/**
 * 制御用の接続がこの時間以上生きていたら「確立済み」とみなし、切れたときにバックオフを戻す。
 * ping の不達で切れるまで（約 25 秒）より長くして、つないだ直後に閉じられる中継で密な再接続ループにしない。
 */
const CONTROL_HEALTHY_UPTIME_MS = 60_000;
/** 中継への WebSocket の開通待ち。 */
const OPEN_TIMEOUT_MS = 20_000;
/** 中継へ送りきれていない量がこれを超えたらローカルの読み取りを止め、下回ったら再開する。 */
const SEND_HIGH_WATER = 4 * 1024 * 1024;
const SEND_LOW_WATER = 1024 * 1024;

/** PROTOCOL-v3 §12 の時間と上限。 */
export const TUNNEL_LIMITS = {
  /** データ用の接続を開いてから msg1 を待つ時間。 */
  msg1TimeoutMs: 5_000,
  /** msg2 を送ってから最初のバイナリを待つ時間。 */
  firstFrameTimeoutMs: 10_000,
  /** pair の paired を送ってから paired_ack を待つ時間。 */
  pairedAckTimeoutMs: 5_000,
  /** approve の paired を送ってから paired_ack を待つ時間（人が「入力しました」を押すまで待つ）。 */
  approveAckTimeoutMs: 60_000,
  /** approve の承認待ちの間に approval_waiting を送る間隔。 */
  approvalKeepaliveMs: 20_000,
  /** approve の承認待ちの長さ（approvalQueue.ts の 5 分と同じ）。 */
  approvalLifetimeMs: PENDING_LIFETIME_MS,
  /** 認証前の枠（満ちていたら一番古いものを閉じてから入れる）。 */
  preAuthSlots: 16,
  /** ペアリングの枠（超えたら msg2 で busy）。 */
  pairingSlots: 4,
  /** 認証済みの枠（超えたら開かない）と、1 台の端末の上限。 */
  authedSlots: 128,
  authedPerDevice: 48
};

/** 再接続までの待ち: 2, 4, 8, 16, 30, 30, ... 秒（mac の min(30, 2^min(attempt, 5))）。 */
export function relayBackoffMs(attempt: number): number {
  return Math.min(30, 2 ** Math.min(attempt, 5)) * 1000;
}

/** 中継の URL に v=2・role・serverId・connectionId を足す（mac の relayURL(role:connectionId:) と同じ。v=2 は Paseo の中継の版）。 */
export function relayEndpoint(
  relayURL: string,
  role: "server" | "client",
  serverId: string,
  connectionId?: string
): string {
  const url = new URL(relayURL);
  url.searchParams.append("v", "2");
  url.searchParams.append("role", role);
  url.searchParams.append("serverId", serverId);
  if (connectionId) url.searchParams.append("connectionId", connectionId);
  return url.toString();
}

// ---- 中継との接続 ----

/** トンネルが使う Bridge の身元（作り直しで変わるので、start のたびに読み直す）。 */
export interface TunnelIdentity {
  readonly e2eKey: Buffer | undefined;
  readonly relayId: string;
  readonly bridgeId: string;
}

export interface PaseoRelayTunnelOptions {
  relayURL: string;
  identity: TunnelIdentity;
  devices: DeviceStore;
  invites: PairingInvites;
  /** approve の承認待ち（PC・スマホでの入力と共有する）。 */
  approvals: ApprovalQueue;
  peers: TunnelPeers;
  /** payload2・paired に載せる PC の名前（PROTOCOL-v3 §5.3 で無害化済み）。 */
  bridgeName: () => string;
  /** 端末が増えた（paired_ack で確定した）とき。 */
  onDevicePaired?: (deviceKeyId: string, display: string) => void;
  log?: (message: string) => void;
  /** 再接続までの待ち。テストのときだけ差し替える。 */
  backoffMs?: (attempt: number) => number;
  /** PROTOCOL-v3 §12 の時間と上限。テストのときだけ差し替える。 */
  limits?: Partial<typeof TUNNEL_LIMITS>;
}

/** データ用の接続から見た、トンネル全体の持ち物（枠・身元・端末の一覧）。 */
interface TunnelHub {
  bridgeKey: Buffer;
  serverId: string;
  relayURL: string;
  options: PaseoRelayTunnelOptions;
  limits: typeof TUNNEL_LIMITS;
  localHost: string;
  localPort: number;
  log: (message: string) => void;
  leavePreAuth(conn: TunnelConnection): void;
  pairingBusy(deviceKeyId: string): boolean;
  enterPairing(conn: TunnelConnection, deviceKeyId: string): void;
  enterAuthed(conn: TunnelConnection, deviceKeyId: string): boolean;
  handshakeFailed(): void;
  closed(conn: TunnelConnection): void;
}

/**
 * Paseo v2 の中継を、BuddyOS の暗号化 TCP トンネル（v3）として使う（mac の PaseoRelayTunnelService）。
 * start で制御用の接続を張り、切れたらバックオフで張り直す。stop で全部閉じる。
 */
export class PaseoRelayTunnel {
  private generation = 0;
  private control?: WebSocket;
  private controlIsOpen = false;
  private wakeSleep?: () => void;
  private readonly connections = new Map<string, TunnelConnection>();
  private readonly preAuth = new Set<TunnelConnection>();
  private readonly pairing = new Map<TunnelConnection, string>();
  private readonly authed = new Map<TunnelConnection, string>();
  private readonly log: (message: string) => void;
  private readonly backoffMs: (attempt: number) => number;
  private readonly limits: typeof TUNNEL_LIMITS;
  private localHost = "127.0.0.1";
  private localPort = 8765;
  private bridgeKey?: Buffer;
  private serverId = "";
  private failures = 0;
  private relayMissingLogged = false;
  private failureTimer?: NodeJS.Timeout;

  constructor(private readonly options: PaseoRelayTunnelOptions) {
    this.log = options.log ?? ((message) => console.log(`[paseo] ${message}`));
    this.backoffMs = options.backoffMs ?? relayBackoffMs;
    this.limits = { ...TUNNEL_LIMITS, ...options.limits };
  }

  /** 制御用の接続が中継につながっているか。 */
  get controlOpen(): boolean {
    return this.controlIsOpen;
  }

  /** 端末ごとの、認証済みのトンネルの数（DevicesView の online）。 */
  isOnline(deviceKeyId: string): boolean {
    for (const id of this.authed.values()) if (id === deviceKeyId) return true;
    return false;
  }

  /**
   * 中継から来た接続を localHost:port（Bridge 本体）へ流す。既に動いていれば張り直す。
   * 静的鍵と relayId はこのときの値を使う（作り直しの後は start し直す）。静的鍵が読めない間は張らない。
   */
  start(port: number, localHost = "127.0.0.1"): void {
    this.stop();
    this.localPort = port;
    this.localHost = localHost;
    if (!this.options.relayURL) {
      if (!this.relayMissingLogged) this.log(`relay is off: ${RELAY_HINT}`);
      this.relayMissingLogged = true;
      return;
    }
    const key = this.options.identity.e2eKey;
    if (!key) {
      this.log("relay is off: the connection key can't be read");
      return;
    }
    this.bridgeKey = key;
    this.serverId = this.options.identity.relayId;
    const run = this.generation;
    void this.runControlLoop(run);
  }

  stop(): void {
    this.generation += 1;
    const control = this.control;
    this.control = undefined;
    this.controlIsOpen = false;
    control?.terminate();
    this.wakeSleep?.();
    const connections = [...this.connections.values()];
    this.connections.clear();
    for (const connection of connections) connection.cancel();
  }

  /** その端末のトンネルを全部閉じる（端末を外したとき。PROTOCOL-v3 Appendix A）。 */
  closeTunnels(deviceKeyId: string): void {
    for (const connection of [...this.connections.values()]) {
      if (connection.deviceKeyId === deviceKeyId) connection.cancel();
    }
  }

  private async runControlLoop(run: number): Promise<void> {
    let attempt = 0;
    while (this.generation === run) {
      const connectedAt = Date.now();
      try {
        await this.runControlConnection(run);
        attempt = 0;
      } catch (error) {
        if (this.generation !== run) return;
        // 長く健全だった接続が切れたときは、溜まった attempt を戻してすぐ張り直す。
        if (Date.now() - connectedAt >= CONTROL_HEALTHY_UPTIME_MS) attempt = 0;
        attempt += 1;
        this.log(`relay control disconnected: ${describe(error)}`);
      }
      if (this.generation !== run) return;
      await this.sleep(this.backoffMs(attempt));
    }
  }

  /** 止めたら（stop）resolve、中継から切られたら reject する。 */
  private runControlConnection(run: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      let socket: WebSocket;
      try {
        socket = new WebSocket(relayEndpoint(this.options.relayURL, "server", this.serverId), {
          maxPayload: CONTROL_MAX_PAYLOAD,
          perMessageDeflate: false,
          handshakeTimeout: OPEN_TIMEOUT_MS
        });
      } catch (error) {
        reject(error instanceof Error ? error : new Error("invalid relay URL"));
        return;
      }
      if (this.generation !== run) {
        socket.terminate();
        resolve();
        return;
      }
      this.control = socket;
      this.log(`relay control connecting: serverId=${this.serverId.slice(0, 8)}…`);

      let lastError: Error | undefined;
      let pingTimer: NodeJS.Timeout | undefined;
      let pongTimer: NodeJS.Timeout | undefined;
      const schedulePing = () => {
        pingTimer = setTimeout(() => {
          if (socket.readyState !== WebSocket.OPEN) return;
          pongTimer = setTimeout(() => {
            lastError = new Error("pong timeout");
            socket.terminate();
          }, PONG_DEADLINE_MS);
          socket.ping(undefined, undefined, (error) => {
            if (!error) return;
            lastError = error;
            socket.terminate();
          });
        }, HEARTBEAT_INTERVAL_MS);
      };

      socket.on("open", () => {
        if (this.control === socket) this.controlIsOpen = true;
        this.log("relay control connected");
        schedulePing();
      });
      socket.on("pong", () => {
        clearTimeout(pongTimer);
        pongTimer = undefined;
        clearTimeout(pingTimer);
        schedulePing();
      });
      socket.on("message", (raw, isBinary) => {
        if (isBinary || this.generation !== run) return;
        this.handleControlEvent(rawToBuffer(raw).toString("utf8"), run);
      });
      socket.on("error", (error) => {
        lastError = error;
      });
      socket.on("close", (code) => {
        clearTimeout(pingTimer);
        clearTimeout(pongTimer);
        if (this.control === socket) {
          this.control = undefined;
          this.controlIsOpen = false;
        }
        if (this.generation !== run) resolve();
        else reject(lastError ?? new Error(`closed (${code})`));
      });
    });
  }

  private handleControlEvent(text: string, run: number): void {
    let event: { type?: unknown; connectionId?: unknown; connectionIds?: unknown };
    try {
      event = JSON.parse(text);
    } catch {
      return;
    }
    if (!event || typeof event !== "object") return;
    switch (event.type) {
      case "connected":
        if (typeof event.connectionId === "string") this.startDataConnection(event.connectionId, run);
        break;
      case "disconnected":
        if (typeof event.connectionId === "string") this.cancelDataConnection(event.connectionId);
        break;
      case "sync":
        if (Array.isArray(event.connectionIds)) {
          for (const id of event.connectionIds) {
            if (typeof id === "string") this.startDataConnection(id, run);
          }
        }
        break;
      default:
        break;
    }
  }

  private startDataConnection(id: string, run: number): void {
    if (this.connections.has(id) || this.generation !== run || !this.bridgeKey) return;
    let endpoint: string;
    try {
      endpoint = relayEndpoint(this.options.relayURL, "server", this.serverId, id);
    } catch {
      return;
    }
    // 認証前の枠が満ちていたら、一番古い認証前の接続を閉じてから入れる（PROTOCOL-v3 §12）。
    if (this.preAuth.size >= this.limits.preAuthSlots) {
      const oldest = this.preAuth.values().next().value;
      if (oldest) {
        this.preAuth.delete(oldest);
        oldest.cancel();
      }
    }
    const connection = new TunnelConnection(id, endpoint, this.hub());
    this.connections.set(id, connection);
    this.preAuth.add(connection);
    connection
      .run()
      .catch((error) => this.log(`tunnel ${id.slice(0, 8)} closed: ${describe(error)}`))
      .finally(() => {
        if (this.connections.get(id) === connection) this.connections.delete(id);
        this.forget(connection);
      });
  }

  private cancelDataConnection(id: string): void {
    const connection = this.connections.get(id);
    this.connections.delete(id);
    connection?.cancel();
  }

  private forget(connection: TunnelConnection): void {
    this.preAuth.delete(connection);
    this.pairing.delete(connection);
    this.authed.delete(connection);
  }

  private hub(): TunnelHub {
    return {
      bridgeKey: this.bridgeKey!,
      serverId: this.serverId,
      relayURL: this.options.relayURL,
      options: this.options,
      limits: this.limits,
      localHost: this.localHost,
      localPort: this.localPort,
      log: this.log,
      leavePreAuth: (conn) => this.preAuth.delete(conn),
      pairingBusy: (deviceKeyId) =>
        this.pairing.size >= this.limits.pairingSlots || [...this.pairing.values()].includes(deviceKeyId),
      enterPairing: (conn, deviceKeyId) => {
        this.pairing.set(conn, deviceKeyId);
      },
      enterAuthed: (conn, deviceKeyId) => {
        if (this.authed.size >= this.limits.authedSlots) return false;
        let mine = 0;
        for (const id of this.authed.values()) if (id === deviceKeyId) mine += 1;
        if (mine >= this.limits.authedPerDevice) return false;
        this.authed.set(conn, deviceKeyId);
        return true;
      },
      handshakeFailed: () => this.countFailure(),
      closed: (conn) => this.forget(conn)
    };
  }

  /** 握手の失敗は数えるだけ（1 分に 1 回まとめてログに出す）。受け付けを止める仕組みは持たない（PROTOCOL-v3 §12）。 */
  private countFailure(): void {
    this.failures += 1;
    if (this.failureTimer) return;
    this.failureTimer = setTimeout(() => {
      this.failureTimer = undefined;
      if (this.failures > 0) this.log(`${this.failures} tunnel handshake failure(s) in the last minute`);
      this.failures = 0;
    }, 60_000);
    this.failureTimer.unref?.();
  }

  /** stop で途中で起こせる待ち。 */
  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => {
      const timer = setTimeout(done, ms);
      const self = this;
      function done() {
        clearTimeout(timer);
        if (self.wakeSleep === done) self.wakeSleep = undefined;
        resolve();
      }
      this.wakeSleep = done;
    });
  }
}

/** approveWait = 承認待ち（番号の入力を待つ）、approveAck = paired を送って paired_ack を待つ、done = 閉じるところ。 */
type TunnelStage = "init" | "first" | "pairAck" | "approveWait" | "approveAck" | "done" | "connecting" | "piping";

/** データ用の接続 1 本（中継の connectionId 1 つ = 端末側の TCP 接続 1 つ）。 */
class TunnelConnection {
  /** msg1 から読んだ端末（断る理由を選ぶ・ログ・端末ごとに閉じるのに使う。信じるのは最初のフレームが開けてから）。 */
  deviceKeyId?: string;
  private socket?: WebSocket;
  private local?: net.Socket;
  private peer?: { port: number; entry: TunnelPeer };
  private closed = false;
  private cancelled = false;
  private failure?: Error;
  private timer?: NodeJS.Timeout;
  /** 仮登録した行の資格情報（paired_ack が来なければ消す）。 */
  private pendingCredHash?: string;
  /** approve の承認待ちの id（閉じたら承認待ちからも外す）。 */
  private approvalPendingId?: string;
  /** approve の keepalive と承認待ちの期限。 */
  private keepalive?: NodeJS.Timeout;
  private lifetime?: NodeJS.Timeout;

  constructor(
    private readonly id: string,
    private readonly endpoint: string,
    private readonly hub: TunnelHub
  ) {}

  /** 止めた（cancel）・ローカル側が閉じた・中継が閉じた、で終わる。不正な相手やエラーなら reject する。 */
  run(): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const hub = this.hub;
      const { devices, invites, peers, approvals } = hub.options;
      const socket = new WebSocket(this.endpoint, {
        maxPayload: DATA_MAX_PAYLOAD,
        perMessageDeflate: false,
        handshakeTimeout: OPEN_TIMEOUT_MS
      });
      this.socket = socket;
      let stage: TunnelStage = "init";
      let mode: "connect" | "pair" | "approve" | undefined;
      let payload: Payload1 | undefined;
      let devicePub: Buffer | undefined;
      let epoch = 0;
      let inviteIdValue: string | undefined;
      let sender: E2EFrameSender | undefined;
      let receiver: E2EFrameReceiver | undefined;
      // approve: Bridge の乱数 nR（msg2 では commit だけを見せ、承認待ちを作ってから明かす）と、握手のハッシュ。
      let nR: Buffer | undefined;
      let handshakeHash: Buffer | undefined;
      // ローカルへつなぐ間に届いた平文。つながったら順に書く。
      const pending: Buffer[] = [];
      let waitingDrain = false;

      const sendText = (text: string) => {
        if (socket.readyState === WebSocket.OPEN) socket.send(text);
      };
      const sendFrame = (plaintext: Buffer, done?: (error?: Error) => void) => {
        if (!sender || socket.readyState !== WebSocket.OPEN) {
          done?.(new Error("not open"));
          return;
        }
        let frame: Buffer;
        try {
          frame = sender.seal(plaintext);
        } catch (error) {
          done?.(error instanceof Error ? error : new Error(String(error)));
          return;
        }
        socket.send(frame, { binary: true }, (error) => done?.(error ?? undefined));
      };
      const setTimer = (ms: number, onTimeout: () => void) => {
        clearTimeout(this.timer);
        this.timer = setTimeout(onTimeout, ms);
      };
      /** 平文のエラー（PROTOCOL-v3 §8.9。認証されない）を送って閉じる。 */
      const refuseText = (code: TunnelErrorCode) => {
        if (code !== "version") hub.handshakeFailed();
        sendText(tunnelErrorText(code));
        this.close(1000);
      };

      const writeLocal = (local: net.Socket, plaintext: Buffer) => {
        if (local.write(plaintext) || waitingDrain) return;
        // ローカルが詰まったら中継からの読み取りを止める（mac は送り終わるまで次を受けない）。
        waitingDrain = true;
        socket.pause();
        local.once("drain", () => {
          waitingDrain = false;
          socket.resume();
        });
      };

      /** connect: open を確かめた後、127.0.0.1:<待ち受け> へつなぐ（PROTOCOL-v3 §10.2・§13.1）。 */
      const connectLocal = (keyId: string) => {
        const local = net.connect({ host: hub.localHost, port: hub.localPort });
        this.local = local;
        local.setNoDelay(true);
        local.on("connect", () => {
          if (this.closed) return;
          // 送り元の番号が取れない・つないだ先が待ち受けの番号でない・ローカル側の住所が 127.0.0.1 でないなら流さない
          // （通してしまうと、その要求が「この PC の中から」に見えるため）。
          const localPort = local.localPort;
          const localAddress = local.localAddress?.replace(/^::ffff:/i, "");
          if (!localPort || local.remotePort !== hub.localPort || localAddress !== "127.0.0.1") {
            hub.log(`tunnel ${this.id.slice(0, 8)}: local socket check failed; closing`);
            this.close(1011);
            return;
          }
          const entry: TunnelPeer = { deviceKeyId: keyId, connectionId: this.id, close: () => this.cancel() };
          peers.add(localPort, entry);
          this.peer = { port: localPort, entry };
          // 入れた後で、行がまだあるか（外されていないか）を確かめ直す（PROTOCOL-v3 §18.2）。
          if (!devices.get(keyId) || devices.state(keyId) || devices.epoch !== epoch) {
            this.close(1000);
            return;
          }
          for (const plaintext of pending.splice(0)) writeLocal(local, plaintext);
          stage = "piping";
          devices.touch(keyId);
        });
        local.on("data", (chunk: Buffer) => {
          if (this.closed || !sender) return;
          let frame: Buffer;
          try {
            frame = sender.seal(chunk);
          } catch (error) {
            this.fail(error);
            return;
          }
          trafficMeter.record("paseo.out", frame.length);
          socket.send(frame, { binary: true }, (error) => {
            if (error) {
              this.fail(error);
              return;
            }
            if (local.isPaused() && socket.bufferedAmount < SEND_LOW_WATER) local.resume();
          });
          if (socket.bufferedAmount > SEND_HIGH_WATER) local.pause();
        });
        // ローカル（Bridge 本体）が閉じたら、送りかけのフレームを流してから中継側も閉じる。
        local.on("end", () => this.close());
        local.on("error", (error) => this.fail(error));
        local.on("close", () => this.close());
      };

      /** msg1 を読んで msg2 を返す（PROTOCOL-v3 §8.3・§10）。ここではまだ何も書き換えない。 */
      const handleInit = (text: string) => {
        const init = parseInitV3(text);
        if (init.kind === "ignore") return;
        if (init.kind === "version") return refuseText("version");
        if (init.kind === "bad") return refuseText("bad_message");
        const ephemeral = crypto.randomBytes(32);
        const responder = { prologue: PROLOGUE, sR: hub.bridgeKey, eR: ephemeral };
        let st: Symmetric;
        let read: { sIpub: Buffer; payload: Buffer };
        try {
          const r = responderRead1(responder, init.e, init.s, init.p);
          st = r.st;
          read = r;
        } catch {
          return refuseText("bad_message");
        }
        devicePub = read.sIpub;
        const keyId = deviceKeyIdOf(read.sIpub);
        this.deviceKeyId = keyId;
        epoch = devices.epoch;
        const parsed = parsePayload1(read.payload);

        // psk: pair は招待の psk（招待が無ければ msg2 は送れない）、それ以外は 0。
        let psk: Buffer = ZERO_PSK;
        const wantsPair = parsed.kind === "ok" ? parsed.payload.mode === "pair" : parsed.mode === "pair";
        if (wantsPair) {
          const id = parsed.kind === "ok" ? parsed.payload.invite : parsed.invite;
          const invite = id ? invites.usableBy(id, keyId) : undefined;
          if (!invite) return refuseText("invite_invalid");
          psk = invite.psk;
          inviteIdValue = invite.id;
        }

        let answer: Payload2Error | undefined;
        if (parsed.kind !== "ok") {
          answer = "bad_request";
        } else if (parsed.payload.mode === "approve") {
          // 状態を変えずに受け付けられるかを確かめる（PROTOCOL-v3 §10.4。順番は mac と同じ）。
          const admission = approvals.admit(keyId, devices.approvalsSetting, devices.remoteApprovalsAvailable);
          if (admission.kind === "refused" && admission.error === "approval_unavailable") answer = "approval_unavailable";
          else if (devices.isRevoked(keyId)) answer = "revoked";
          else if (admission.kind === "refused") answer = admission.error;
          else if (devices.wouldExceedLimit(keyId)) answer = "too_many_devices";
          else if (devices.broken) answer = "bridge_error";
          else if (hub.pairingBusy(keyId)) answer = "busy";
          else nR = crypto.randomBytes(32);
        } else if (devices.broken) {
          answer = "bridge_error";
        } else if (parsed.payload.mode === "connect") {
          answer = connectRefusal(devices, keyId, parsed.payload.deviceId);
          if (answer === "unknown_device") hub.log(`tunnel ${this.id.slice(0, 8)}: unknown device ${keyId.slice(0, 8)}`);
        } else if (devices.wouldExceedLimit(keyId)) {
          answer = "too_many_devices";
        } else if (hub.pairingBusy(keyId)) {
          answer = "busy";
        }

        const bridgeName = hub.options.bridgeName();
        const p2 = answer
          ? payload2Error(answer)
          : payload2Ok({
              bridgeId: hub.options.identity.bridgeId,
              name: bridgeName,
              platform: "windows",
              deviceKeyId: keyId,
              ...(nR ? { commit: sasCommit(nR) } : {})
            });
        let written: ReturnType<typeof responderWrite2>;
        try {
          written = responderWrite2(responder, st, init.e, read.sIpub, psk, p2);
        } catch {
          return refuseText("bad_message");
        }
        sendText(helloText(written.eRpub, written.payloadCt));
        if (answer || parsed.kind !== "ok") {
          this.close(1000);
          return;
        }
        payload = parsed.payload;
        mode = parsed.payload.mode;
        handshakeHash = written.handshakeHash;
        if (mode !== "connect") hub.enterPairing(this, keyId);
        receiver = new E2EFrameReceiver(written.c2s, FRAME_VERSION_V3);
        sender = new E2EFrameSender(written.s2c, FRAME_VERSION_V3);
        stage = "first";
        setTimer(hub.limits.firstFrameTimeoutMs, () => this.close(1000));
      };

      /** pair: pair_confirm を確かめたら行を仮登録して bdc_ を送る（PROTOCOL-v3 §10.3）。 */
      const handlePairConfirm = (keyId: string) => {
        const invite = inviteIdValue ? invites.usableBy(inviteIdValue, keyId) : undefined;
        if (devices.epoch !== epoch || !invite || !payload || !devicePub) {
          this.close(1000);
          return;
        }
        if (devices.broken || devices.wouldExceedLimit(keyId)) {
          sendFrame(pairRejectedMessage(devices.broken ? "bridge_error" : "too_many_devices"), () => this.close(1000));
          return;
        }
        const credential = newCredential();
        const credHash = credentialHash(credential);
        const name = payload.name ?? "端末";
        const row: DeviceRow = {
          pub: b64u(devicePub),
          clientDeviceId: payload.deviceId,
          name,
          // ペアリングし直し（同じ deviceKeyId）では、デスクトップで付けたラベルを引き継ぐ（mac と同じ）。
          label: devices.get(keyId)?.label ?? null,
          platform: payload.platform,
          credHash,
          via: "qr",
          createdAt: Date.now()
        };
        const display = displayName(name, keyId);
        invites.markUsed(invite, keyId, display);
        devices.putPending(keyId, row);
        this.pendingCredHash = credHash;
        stage = "pairAck";
        const bridge = {
          bridgeId: hub.options.identity.bridgeId,
          name: hub.options.bridgeName(),
          platform: "windows" as const,
          relayId: hub.serverId,
          relayURL: hub.relayURL
        };
        sendFrame(pairedMessage(keyId, credential, bridge), (error) => {
          if (error) this.close(1011);
        });
        setTimer(hub.limits.pairedAckTimeoutMs, () => this.close(1000));
      };

      /** pair_rejected を送ってから閉じる（以降のフレームは読まない）。 */
      const rejectAndClose = (reason: PairRejectedReason) => {
        stage = "done";
        sendFrame(pairRejectedMessage(reason), () => this.close(1000));
      };

      /** approve: PC かスマホで番号が合った（PROTOCOL-v3 §10.4）。行を仮登録して paired を送る。 */
      const approveMatched = (keyId: string, display: string, approvedBy: string | undefined): Promise<ApproveOutcome> => {
        this.approvalPendingId = undefined;
        if (this.closed || stage !== "approveWait" || !payload || !devicePub) return Promise.resolve({ kind: "device_gone" });
        const credential = newCredential();
        const credHash = credentialHash(credential);
        const row: DeviceRow = {
          pub: b64u(devicePub),
          clientDeviceId: payload.deviceId,
          name: payload.name ?? DEVICE_NAME_FALLBACK,
          label: devices.get(keyId)?.label ?? null,
          platform: payload.platform,
          credHash,
          via: "approval",
          createdAt: Date.now(),
          ...(approvedBy ? { approvedBy } : {})
        };
        if (!devices.insertPending(keyId, row, epoch)) {
          rejectAndClose(devices.broken ? "bridge_error" : devices.epoch !== epoch ? "reset" : "too_many_devices");
          return Promise.resolve({ kind: "device_gone" });
        }
        this.pendingCredHash = credHash;
        stage = "approveAck";
        clearTimeout(this.lifetime);
        // 60 秒以内に paired_ack が来なければ閉じる（close で仮の行も消える。PROTOCOL-v3 §12）。
        setTimer(hub.limits.approveAckTimeoutMs, () => this.close(1000));
        const bridge = {
          bridgeId: hub.options.identity.bridgeId,
          name: hub.options.bridgeName(),
          platform: "windows" as const,
          relayId: hub.serverId,
          relayURL: hub.relayURL
        };
        return new Promise((resolve) => {
          sendFrame(pairedMessage(keyId, credential, bridge), (error) => {
            if (error) {
              this.close(1011);
              resolve({ kind: "device_gone" });
              return;
            }
            // 送っている間にトンネルが閉じていたら、仮の行は close が消している（その間に paired_ack で確定していれば、そのまま）。
            if (this.closed && !(devices.state(keyId) === undefined && devices.get(keyId)?.credHash === credHash)) {
              resolve({ kind: "device_gone" });
              return;
            }
            resolve({ kind: "ok", display });
          });
        });
      };

      /** approve: approve_nonce を受けたら回数を数え、承認待ちを作って nR を明かす（PROTOCOL-v3 §10.4）。 */
      const handleApproveNonce = (keyId: string, nD: Buffer) => {
        if (!nR || !handshakeHash || !payload) return this.close(1008);
        if (devices.epoch !== epoch) return rejectAndClose("reset");
        // 窓が閉じていればスマホでの許可（remote）。msg1 の後で設定が切られていたら、数えずに断る。
        const remote = approvals.wouldBeRemote();
        if (!devices.approvalsSetting || (remote && !devices.remoteApprovalsAvailable)) return rejectAndClose("closed");
        // ここで回数を数える（msg1 だけでは数えない。PROTOCOL-v3 §18.2）。
        if (!approvals.countAttempt(keyId, remote)) return rejectAndClose("rate_limited");
        const code = sasCode(handshakeHash, nD, nR);
        const name = payload.name ?? DEVICE_NAME_FALLBACK;
        const display = displayName(name, keyId);
        const pending = approvals.add({
          deviceKeyId: keyId,
          display,
          name,
          platform: payload.platform,
          sameNameExists: devices.sameNameCount(name) > 0,
          remote,
          code,
          approve: (approvedBy) => approveMatched(keyId, display, approvedBy),
          end: (reason: EndReason) => {
            this.approvalPendingId = undefined;
            // paired を送った後の取り下げは無視する（paired_ack か 60 秒で終わる）。
            if (stage === "approveWait") rejectAndClose(reason);
          }
        });
        if (!pending) return rejectAndClose("busy");
        this.approvalPendingId = pending.pendingId;
        stage = "approveWait";
        sendFrame(approveRevealMessage(nR));
        this.keepalive = setInterval(() => {
          if (stage === "approveWait" || stage === "approveAck") sendFrame(APPROVAL_WAITING_MESSAGE);
        }, hub.limits.approvalKeepaliveMs);
        this.lifetime = setTimeout(() => {
          if (stage !== "approveWait") return;
          if (this.approvalPendingId) approvals.remove(this.approvalPendingId);
          this.approvalPendingId = undefined;
          rejectAndClose("timeout");
        }, hub.limits.approvalLifetimeMs);
        hub.log(`approval waiting for ${keyId.slice(0, 8)}${remote ? " (phone)" : ""}`);
      };

      socket.on("open", () => {
        setTimer(hub.limits.msg1TimeoutMs, () => {
          if (stage === "init") this.close(1000);
        });
      });

      socket.on("message", (raw, isBinary) => {
        if (this.closed) return;
        try {
          const data = rawToBuffer(raw);
          if (!isBinary) {
            // TEXT: msg1 の前は msg1 を探す。msg2 の後、最初のバイナリまでは読み捨てる（msg1 の再送）。その後は不正。
            if (data.length > CONTROL_MAX_BYTES) return this.close(1009);
            if (stage === "init") return handleInit(data.toString("utf8"));
            if (stage === "first" || stage === "done") return;
            return this.close(1008);
          }
          if (stage === "done") return;
          if (stage === "init" || !receiver || !this.deviceKeyId) return this.close(1008);
          const keyId = this.deviceKeyId;
          if (stage === "connecting" || stage === "piping") {
            trafficMeter.record("paseo.in", data.length);
            const plaintext = receiver.open(data);
            if (stage === "connecting" || !this.local) pending.push(plaintext);
            else writeLocal(this.local, plaintext);
            return;
          }
          let plaintext: Buffer;
          try {
            plaintext = receiver.open(data);
          } catch {
            // 開けないフレーム: 閉じるだけ。招待は変えず、回数も数えない（PROTOCOL-v3 §10.3。中継がゴミを入れても招待は消えない）
            hub.handshakeFailed();
            this.close(1008);
            return;
          }
          const control = parseControl(plaintext);
          if (stage === "first") {
            clearTimeout(this.timer);
            hub.leavePreAuth(this);
            if (mode === "connect") {
              if (control?.type !== "open") return this.close(1008);
              // 認証済みの枠（128 本・1 台 48 本）。lock の中（同期）で epoch と行を確かめてからつなぐ。
              if (!hub.enterAuthed(this, keyId)) return this.close(1013);
              if (devices.epoch !== epoch || !devices.get(keyId) || devices.state(keyId)) return this.close(1000);
              stage = "connecting";
              connectLocal(keyId);
              return;
            }
            if (mode === "approve") {
              if (control?.type !== "approve_nonce") return this.close(1008);
              handleApproveNonce(keyId, Buffer.from(control.n, "base64url"));
              return;
            }
            if (control?.type !== "pair_confirm") return this.close(1008);
            handlePairConfirm(keyId);
            return;
          }
          // 承認待ちの間に来てよいのは pair_cancel だけ（閉じると承認待ちからも外れる）。
          if (stage === "approveWait") return this.close(control?.type === "pair_cancel" ? 1000 : 1008);
          // paired の後: paired_ack（確定）か pair_cancel（取り消し。close で仮の行を消す）。
          if (stage === "approveAck" && control?.type === "pair_cancel") return this.close(1000);
          // stage === "pairAck" / "approveAck"
          if (control?.type !== "paired_ack" || !this.pendingCredHash) return this.close(1008);
          clearTimeout(this.timer);
          if (devices.epoch !== epoch || !devices.confirm(keyId, this.pendingCredHash)) return this.close(1000);
          this.pendingCredHash = undefined;
          const row = devices.get(keyId);
          const display = displayName(row?.label ?? row?.name ?? "端末", keyId);
          hub.log(`paired ${display}${mode === "approve" ? " via approval" : ""}`);
          hub.options.onDevicePaired?.(keyId, display);
          this.close(1000);
        } catch (error) {
          this.fail(error);
        }
      });
      socket.on("error", (error) => {
        this.failure ??= error;
      });
      socket.on("close", () => {
        this.close();
        if (this.failure && !this.cancelled) reject(this.failure);
        else resolve();
      });
    });
  }

  cancel(): void {
    this.cancelled = true;
    this.close(1000);
  }

  private fail(error: unknown): void {
    this.failure ??= error instanceof Error ? error : new Error(String(error));
    this.close(1011);
  }

  private close(code = 1001): void {
    if (this.closed) return;
    this.closed = true;
    clearTimeout(this.timer);
    clearInterval(this.keepalive);
    clearTimeout(this.lifetime);
    const { devices, peers, approvals } = this.hub.options;
    // 端末が先に切った・pair_cancel・時間切れ: 承認待ちから外す。
    if (this.approvalPendingId) approvals.remove(this.approvalPendingId);
    this.approvalPendingId = undefined;
    // paired_ack の来なかった仮の行は消す（PROTOCOL-v3 §10.3）。
    if (this.pendingCredHash && this.deviceKeyId) devices.removePending(this.deviceKeyId, this.pendingCredHash);
    this.pendingCredHash = undefined;
    // ローカルの TCP を閉じる前に TunnelPeers から外す（PROTOCOL-v3 §10.2）。
    if (this.peer) peers.remove(this.peer.port, this.peer.entry);
    this.peer = undefined;
    this.hub.closed(this);
    const socket = this.socket;
    if (socket) {
      // close は送信待ちのフレームを先に流してから close フレームを送る。開通前なら捨てる。
      if (socket.readyState === WebSocket.OPEN) socket.close(code);
      else if (socket.readyState === WebSocket.CONNECTING) socket.terminate();
    }
    this.local?.destroy();
  }
}

/** connect の msg2 で断る理由（PROTOCOL-v3 §10.2）。通すなら undefined。 */
export function connectRefusal(devices: DeviceStore, deviceKeyId: string, clientDeviceId: string): Payload2Error | undefined {
  if (devices.broken) return "bridge_error";
  const row = devices.get(deviceKeyId);
  if (!row) return devices.isRevoked(deviceKeyId) ? "revoked" : "unknown_device";
  const state = devices.state(deviceKeyId);
  if (state === "pendingAck") return "unknown_device";
  if (state === "unpairing") return "revoked";
  if (row.clientDeviceId !== clientDeviceId) return "unknown_device";
  return undefined;
}

function rawToBuffer(raw: RawData): Buffer {
  if (Buffer.isBuffer(raw)) return raw;
  if (Array.isArray(raw)) return Buffer.concat(raw);
  return Buffer.from(raw);
}

function describe(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}
