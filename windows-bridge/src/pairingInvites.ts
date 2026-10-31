import crypto from "node:crypto";
import { b64u, buildPairUrl, inviteId, invitePsk } from "./tunnelV3.js";

// QR・ペアリングのリンクに載せる招待（spec/PROTOCOL-v3.md §4・§6・§10.3・§12）。
// Bridge のメモリにだけ持つ（再起動で消える）。10 分・同時に 3 つまで。使われたら、その端末（deviceKeyId）の
// やり直しにだけ使える。失敗の回数では消さない（psk を知らない人は msg2 を開けないので、推測はできない）。

export const INVITE_TTL_MS = 10 * 60 * 1000;
export const MAX_INVITES = 3;

export interface Invite {
  id: string;
  secret: Buffer;
  psk: Buffer;
  createdAt: number;
  expiresAt: number;
  usedBy?: { deviceKeyId: string; display: string; at: number };
}

export class PairingInvites {
  private readonly invites = new Map<string, Invite>();
  private readonly now: () => number;

  constructor(private readonly opts: { now?: () => number; onChange?: () => void } = {}) {
    this.now = opts.now ?? Date.now;
  }

  /** 新しい招待を作る。4 つ目で一番古いものを捨てる。secret はテストのときだけ渡す。 */
  create(secret: Buffer = crypto.randomBytes(32)): Invite {
    this.purge();
    while (this.invites.size >= MAX_INVITES) {
      let oldest: Invite | undefined;
      for (const invite of this.invites.values()) if (!oldest || invite.createdAt < oldest.createdAt) oldest = invite;
      if (!oldest) break;
      this.invites.delete(oldest.id);
    }
    const t = this.now();
    const invite: Invite = { id: inviteId(secret), secret, psk: invitePsk(secret), createdAt: t, expiresAt: t + INVITE_TTL_MS };
    this.invites.set(invite.id, invite);
    this.opts.onChange?.();
    return invite;
  }

  /** 期限内の招待を引く。 */
  find(id: string): Invite | undefined {
    const invite = this.invites.get(id);
    if (!invite) return undefined;
    if (this.now() >= invite.expiresAt) {
      this.invites.delete(id);
      this.opts.onChange?.();
      return undefined;
    }
    return invite;
  }

  /** その端末が使える招待か（期限内で、未使用か、その端末が使ったもの）。 */
  usableBy(id: string, deviceKeyId: string): Invite | undefined {
    const invite = this.find(id);
    if (!invite) return undefined;
    if (invite.usedBy && invite.usedBy.deviceKeyId !== deviceKeyId) return undefined;
    return invite;
  }

  /** pair_confirm を確かめたときに「この端末が使った・時刻」を記録する。 */
  markUsed(invite: Invite, deviceKeyId: string, display: string): void {
    invite.usedBy = { deviceKeyId, display, at: this.now() };
    this.opts.onChange?.();
  }

  remove(id: string): boolean {
    const removed = this.invites.delete(id);
    if (removed) this.opts.onChange?.();
    return removed;
  }

  clear(): void {
    if (this.invites.size === 0) return;
    this.invites.clear();
    this.opts.onChange?.();
  }

  get size(): number {
    this.purge();
    return this.invites.size;
  }

  /** DevicesView の invites（PROTOCOL-v3 Appendix A）。 */
  views(): Array<{ inviteId: string; expiresAt: number; usedBy: { display: string; at: number } | null }> {
    this.purge();
    return [...this.invites.values()]
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((i) => ({ inviteId: i.id, expiresAt: i.expiresAt, usedBy: i.usedBy ? { display: i.usedBy.display, at: i.usedBy.at } : null }));
  }

  private purge(): void {
    const t = this.now();
    let changed = false;
    for (const [id, invite] of this.invites) {
      if (t >= invite.expiresAt) {
        this.invites.delete(id);
        changed = true;
      }
    }
    if (changed) this.opts.onChange?.();
  }
}

/** PROTOCOL-v3 §6 の QR・リンク（キーの順番どおり。exp は UNIX 秒）。 */
export function invitePairUrl(
  invite: Invite,
  bridge: { bridgeId: string; name: string; relayURL: string; relayId: string; bridgePub: Buffer }
): string {
  return buildPairUrl({
    v: "3",
    bridgeId: bridge.bridgeId,
    name: bridge.name,
    platform: "windows",
    relay: bridge.relayURL,
    relayId: bridge.relayId,
    key: b64u(bridge.bridgePub),
    secret: b64u(invite.secret),
    exp: String(Math.floor(invite.expiresAt / 1000))
  });
}
