import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { stripWrappers, stripPeerFrame } from "../agents/claudeProjectsScanner.js";
import type { HistoryReadFeed } from "../agents/claudeCode.js";
import type { AgentSession, Emit } from "../agents/types.js";
import { attachmentTextNotes, imageAttachments, metadataText } from "../agents/types.js";
import { event, type SessionEvent } from "../protocol.js";
import { BG_INTERRUPT_TEXT, readSessionFile, sessionFileNames, type BgEntry } from "./claudeAgentsRegistry.js";
import { validTranscriptPath } from "./claudeBackgroundJobs.js";
import { isAlive, postToInbox, readJsonLines, toolTitle } from "./claudeTerminal.js";

/// claude --bg のワーカーの会話（BACKGROUND_CONTROL §7.8、Windows は §7.10）。見るのは transcript、送るのは受け箱。
///   worker: ワーカーが生きている。status でターンを開け閉めし、受け箱で送る。
///   elsewhere: ほかのプロセスが同じ sessionId を握っている。見るだけで、送信は断る。

const AGENT = "claude";

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

/** テストが短くするための間隔。 */
export const bgSessionTiming = {
  /** ターンが開いている間・送った発話の行方が分からない間の読み取りの間隔。 */
  fastMs: 1000,
  slowMs: 5000,
  /** 最初の読み取りが履歴を読み終えるのを待つ時間。 */
  historyWaitMs: 3000,
  /** 送った発話が transcript に出るのを待つ時間（status が idle / shell のまま）。 */
  ackMs: 30_000,
  /** 受け箱へ書く時間切れ。 */
  postMs: 3000
};

const SENT_LIMIT = 20;
const SUMMARY_LIMIT = 200;

export interface BgHolder {
  pid: number;
  entrypoint?: string;
  status?: string;
}

/** 同じ sessionId を握っている生きている sessions の行（startedAt の新しいもの）。 */
/// kind が bg の行は、ジョブのワーカー自身（台帳がまだ古いだけ）なので握り手に数えない。見つけたら onWorker を呼ぶ。
export function findHolder(home: string, sessionId: string, onWorker?: () => void): BgHolder | undefined {
  const dir = path.join(home, ".claude", "sessions");
  let names: string[];
  try {
    names = fs.readdirSync(dir);
  } catch {
    return undefined;
  }
  let best: (BgHolder & { startedAt: number }) | undefined;
  for (const name of sessionFileNames(names)) {
    const o = readSessionFile(dir, Number.parseInt(name, 10));
    if (!o?.pid || o.sessionId !== sessionId || !isAlive(o.pid)) continue;
    if (o.kind === "bg") {
      onWorker?.();
      continue;
    }
    const startedAt = o.startedAt ?? 0;
    if (best && best.startedAt >= startedAt) continue;
    best = { pid: o.pid, entrypoint: o.entrypoint, status: o.status, startedAt };
  }
  return best && { pid: best.pid, entrypoint: best.entrypoint, status: best.status };
}

/** ClaudeBackgroundJobs のうち、この会話が使う口。 */
export interface BgSessionHost {
  readonly homeDir: string;
  entryFor(sessionId: string): BgEntry | undefined;
  watchEntry(sessionId: string, listener: (entry: BgEntry | undefined) => void): () => void;
  refresh(): Promise<void>;
}

export interface BgSessionOptions {
  mode: "worker" | "elsewhere";
  host: BgSessionHost;
  /** "claude:<sid>" の購読者へ配る（再接続用に記録する）。 */
  publish: (evt: SessionEvent) => void;
  history?: HistoryReadFeed;
  /** elsewhere: 握っているプロセス。 */
  holder?: BgHolder;
  post?: (socketPath: string, text: string, timeoutMs?: number) => Promise<void>;
  /** 画像を書き出す場所。 */
  attachmentDir?: string;
  now?: () => number;
}

interface Turn {
  messageId: string;
  /** message.id → 吹き出しの messageId。 */
  bubbles: Map<string, string>;
  implicit: boolean;
}

const isBusy = (status: string | undefined): boolean => status === "busy";
const isQuiet = (status: string | undefined): boolean => status === "idle" || status === "waiting" || status === "shell";

export class ClaudeBackgroundSession implements AgentSession {
  readonly supportsMidTurnInjection = true;
  readonly bgMode: "worker" | "elsewhere";

  private readonly host: BgSessionHost;
  private readonly publish: (evt: SessionEvent) => void;
  private readonly post: (socketPath: string, text: string, timeoutMs?: number) => Promise<void>;
  private readonly home: string;
  private readonly holder?: BgHolder;
  private readonly sent: string[] = [];
  private readonly toolNames = new Map<string, string>();
  private turn?: Turn;
  private status?: string;
  private alive = true;
  private unusable = false;
  private closed = false;
  private file?: string;
  private offset?: number;
  private historyEnd?: number;
  private historyWaitUntil?: number;
  private readonly createdAt: number;
  private ackSince?: number;
  private timer?: NodeJS.Timeout;
  private unwatch?: () => void;
  private unhistory?: () => void;

  constructor(
    public readonly sessionId: string,
    private readonly options: BgSessionOptions
  ) {
    this.bgMode = options.mode;
    this.host = options.host;
    this.publish = options.publish;
    this.post = options.post ?? postToInbox;
    this.holder = options.holder;
    this.home = options.host.homeDir;
    this.createdAt = this.now();
    this.start();
  }

  private now(): number {
    return this.options.now ? this.options.now() : Date.now();
  }

  // ---- 開始・終了 ----

  private start(): void {
    const entry = this.host.entryFor(this.sessionId);
    this.findTranscript(entry);
    if (this.file) {
      try {
        this.offset = fs.statSync(this.file).size;
      } catch {
        this.offset = 0;
      }
    }
    const feed = this.options.history;
    // 前に開いたときの履歴の終わりは下限にだけ使う。今回の履歴の読み取りが済むか 3 秒たつまで最初の読み取りを待つ
    // （同じ行を履歴と live の両方に出さない）。
    const last = feed?.lastRead(this.sessionId);
    if (last) this.noteHistory(last);
    if (feed && this.file) {
      this.historyWaitUntil = this.createdAt + bgSessionTiming.historyWaitMs;
      this.unhistory = feed.onRead(this.sessionId, (read) => {
        this.noteHistory(read);
        this.historyWaitUntil = undefined;
        this.arm(0);
      });
    }
    if (this.options.mode === "worker") {
      this.unwatch = this.host.watchEntry(this.sessionId, (e) => this.onEntry(e));
      this.syncStatus(entry?.workerStatus, entry?.row.live === true, entry);
    } else {
      this.syncStatus(this.holder?.status, true, entry);
    }
    this.arm();
  }

  async close(): Promise<void> {
    this.closed = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    this.unwatch?.();
    this.unhistory?.();
  }

  isStillUsable(): boolean {
    if (this.unusable || this.closed) return false;
    if (this.options.mode === "elsewhere") {
      // ワーカーが生き返った（PC で respawn した）なら、次の acquire で worker に取り直す。
      if (this.host.entryFor(this.sessionId)?.row.live === true) return false;
      return this.holder !== undefined && isAlive(this.holder.pid);
    }
    return this.host.entryFor(this.sessionId)?.row.live === true;
  }

  // ---- transcript ----

  private noteHistory(read: { file?: string; end: number }): void {
    if (read.file && this.file && path.resolve(read.file).toLowerCase() !== path.resolve(this.file).toLowerCase()) return;
    this.historyEnd = read.end;
    if (this.offset !== undefined) this.offset = Math.max(this.offset, read.end);
  }

  private findTranscript(entry: BgEntry | undefined): void {
    if (this.file) return;
    let found = validTranscriptPath(entry?.linkScanPath, this.sessionId, this.home);
    if (!found) {
      const root = path.join(this.home, ".claude", "projects");
      try {
        for (const d of fs.readdirSync(root)) {
          const candidate = validTranscriptPath(path.join(root, d, `${this.sessionId}.jsonl`), this.sessionId, this.home);
          if (candidate) {
            found = candidate;
            break;
          }
        }
      } catch {
        /* まだ無い */
      }
    }
    if (!found) return;
    this.file = found;
    if (this.offset === undefined) this.offset = Math.max(0, this.historyEnd ?? 0);
  }

  // ---- 見張り ----

  private arm(delayMs?: number): void {
    if (this.closed) return;
    if (this.timer) clearTimeout(this.timer);
    const fast = this.turn !== undefined || this.sent.length > 0;
    this.timer = setTimeout(() => this.tick(), delayMs ?? (fast ? bgSessionTiming.fastMs : bgSessionTiming.slowMs));
    this.timer.unref();
  }

  private tick(): void {
    this.timer = undefined;
    if (this.closed) return;
    try {
      this.step();
    } catch {
      /* 読み取りの失敗は次の周期で試す */
    }
    this.arm();
  }

  private step(): void {
    if (this.options.mode === "elsewhere") {
      const holder = this.holder;
      const alive = holder !== undefined && isAlive(holder.pid);
      const status = holder && alive ? (readSessionFile(path.join(this.home, ".claude", "sessions"), holder.pid)?.status ?? holder.status) : undefined;
      this.syncStatus(status, alive, this.host.entryFor(this.sessionId));
    } else {
      const entry = this.host.entryFor(this.sessionId);
      this.syncStatus(entry?.workerStatus, entry?.row.live === true, entry);
    }
    if (this.historyWaitUntil !== undefined) {
      if (this.now() < this.historyWaitUntil) return;
      this.historyWaitUntil = undefined;
    }
    this.drain();
    this.checkAck();
    // 状態が変わらないまま transcript だけ動いた（PC で attach して打った）ターンは、動きが止まっていれば閉じる。
    if (this.turn?.implicit && !isBusy(this.status) && this.sent.length === 0) this.closeTurn();
  }

  private onEntry(entry: BgEntry | undefined): void {
    if (this.closed) return;
    this.syncStatus(entry?.workerStatus, entry?.row.live === true, entry);
    this.arm(0);
  }

  /** ワーカーの生の status の変化をターンに映す。 */
  private syncStatus(status: string | undefined, alive: boolean, entry: BgEntry | undefined): void {
    const gone = !alive;
    const wasAlive = this.alive;
    this.alive = alive;
    this.status = status;
    if (gone) {
      // 履歴を待つ間は読まない（先に読むと同じ行を履歴と live の両方に出す）。
      if (wasAlive || this.turn || this.sent.length > 0) {
        if (!this.waitingForHistory()) {
          try {
            this.drain();
          } catch {
            /* 読めなかった分は諦める */
          }
        }
        // 届いたと分かる前にワーカーが消えた発話は、もう届かない。1 秒ごとの読み取りが止まらなくなるので捨てて知らせる。
        let lost = false;
        if (this.sent.length > 0) {
          this.sent.length = 0;
          this.ackSince = undefined;
          lost = true;
          this.publish(event.error(AGENT, this.sessionId, "PC のバックグラウンドのセッションが、この発話を受け取る前に止まりました。"));
        }
        if (this.turn) this.closeTurn(entry, lost);
        else if (lost) this.publish({ ...event.done(AGENT, this.sessionId, crypto.randomUUID()), metadata: { errored: "true" } });
      }
      return;
    }
    if (isBusy(status)) {
      if (!this.turn) this.openTurn(false);
      else if (this.turn.implicit) this.turn.implicit = false;
    } else if (isQuiet(status) && this.turn) {
      this.closeTurn(entry);
    }
  }

  private openTurn(implicit: boolean): Turn {
    const turn: Turn = { messageId: crypto.randomUUID(), bubbles: new Map(), implicit };
    this.turn = turn;
    this.publish(event.activity(AGENT, this.sessionId, turn.messageId, ""));
    return turn;
  }

  /** transcript を最後まで読んでから done で閉じる。ワーカーが消えて失敗なら、先に error を流して done を errored にする。 */
  private closeTurn(entry?: BgEntry, errored = false): void {
    const turn = this.turn;
    if (!turn) return;
    // 履歴を待つ間は読まない（まだ届いていない履歴より先の行を流すと重複する。done は出す）。
    if (!this.waitingForHistory()) {
      try {
        this.drain();
      } catch {
        /* 読めなかった分は諦める */
      }
    }
    this.turn = undefined;
    this.toolNames.clear();
    const failed = !this.alive && (entry ?? this.host.entryFor(this.sessionId))?.row.state === "failed";
    if (failed) {
      this.publish(event.error(AGENT, this.sessionId, "PC のバックグラウンドのセッションが止まりました（失敗）"));
      this.publish({ ...event.done(AGENT, this.sessionId, turn.messageId), metadata: { errored: "true" } });
      return;
    }
    const done = event.done(AGENT, this.sessionId, turn.messageId);
    if (errored) {
      this.publish({ ...done, metadata: { errored: "true" } });
      return;
    }
    this.publish(this.sent.length > 0 ? { ...done, metadata: { pending: "1" } } : done);
  }

  /** 今回の履歴の読み取りを待っている間か（3 秒たつか、履歴の読み取りが済むまで）。 */
  private waitingForHistory(): boolean {
    return this.historyWaitUntil !== undefined && this.now() < this.historyWaitUntil;
  }

  private drain(): void {
    if (!this.file) {
      this.findTranscript(this.host.entryFor(this.sessionId));
      if (!this.file) return;
    }
    const offset = this.offset ?? 0;
    const { lines, next } = readJsonLines(this.file, offset);
    this.offset = next;
    for (const line of lines) this.ingest(line);
  }

  private ingest(o: Obj): void {
    if (o.isSidechain === true || o.isMeta === true || o.isCompactSummary === true || o.isVisibleInTranscriptOnly === true) return;
    switch (o.type) {
      case "assistant":
        return this.ingestAssistant(o);
      case "user":
        return this.ingestUser(o);
      case "system":
        return this.ingestSystem(o);
      default:
        return;
    }
  }

  private ingestAssistant(o: Obj): void {
    const message = obj(o.message);
    const content = message.content;
    const blocks = typeof content === "string" ? [{ type: "text", text: content }] : Array.isArray(content) ? content : [];
    const key = str(message.id) ?? str(o.uuid) ?? "";
    for (const block of blocks) {
      const b = obj(block);
      if (b.type === "text" && typeof b.text === "string" && b.text) {
        const turn = this.turn ?? this.openTurn(true);
        let mid = turn.bubbles.get(key);
        if (!mid) {
          mid = turn.bubbles.size === 0 ? turn.messageId : crypto.randomUUID();
          turn.bubbles.set(key, mid);
        }
        this.publish(event.assistantDelta(AGENT, this.sessionId, mid, b.text));
      } else if (b.type === "tool_use") {
        const id = str(b.id);
        const name = str(b.name) ?? "tool";
        if (!id) continue;
        if (!this.turn) this.openTurn(true);
        this.toolNames.set(id, name);
        this.publish(event.toolStart(AGENT, this.sessionId, id, name, toolTitle(name, b.input), "tool"));
      }
    }
  }

  private ingestUser(o: Obj): void {
    const message = obj(o.message);
    const content = message.content;
    if (Array.isArray(content)) {
      for (const block of content) {
        const b = obj(block);
        if (b.type !== "tool_result") continue;
        const id = str(b.tool_use_id);
        if (!id) continue;
        const name = this.toolNames.get(id) ?? "tool";
        this.toolNames.delete(id);
        const summary = resultText(b.content).slice(0, SUMMARY_LIMIT);
        this.publish(event.toolEnd(AGENT, this.sessionId, id, name, b.is_error === true ? "failed" : "completed", summary || undefined));
      }
    }
    const raw = typeof content === "string" ? content : Array.isArray(content) ? content.map((c) => (obj(c).type === "text" ? (str(obj(c).text) ?? "") : "")).join("\n") : "";
    if (!raw.trim()) return;
    if (obj(o.origin).kind === "peer") {
      const body = stripPeerFrame(raw);
      const i = this.sent.findIndex((s) => s && body.includes(s));
      if (i >= 0) {
        // 送った発話が届いた。アプリは表示済み。
        this.sent.splice(i, 1);
        this.ackSince = undefined;
        if (!this.turn) this.openTurn(false);
        return;
      }
      if (body.trim()) this.publish(userMessage(this.sessionId, body));
      return;
    }
    const shown = stripWrappers(raw);
    if (shown) this.publish(userMessage(this.sessionId, shown));
  }

  private ingestSystem(o: Obj): void {
    const text = str(o.content) ?? str(obj(o.message).content);
    if (!text?.startsWith("Held peer message") || this.sent.length === 0) return;
    this.sent.shift();
    this.ackSince = undefined;
    this.publishFailure(
      `PC のバックグラウンドのセッションが、この発話を保留しました。PC で \`claude attach ${this.jobId()}\` を開いて「Deliver」を選ぶと届きます。`
    );
  }

  /** 送った発話が 30 秒たっても transcript に出ない（status が idle / shell のまま）。busy の間は数えない。 */
  private checkAck(): void {
    if (this.sent.length === 0) {
      this.ackSince = undefined;
      return;
    }
    if (!this.alive) {
      this.sent.length = 0;
      this.ackSince = undefined;
      return;
    }
    if (isBusy(this.status)) {
      this.ackSince = undefined;
      return;
    }
    const now = this.now();
    this.ackSince ??= now;
    if (now - this.ackSince < bgSessionTiming.ackMs) return;
    this.sent.shift();
    this.ackSince = this.sent.length > 0 ? now : undefined;
    this.publishFailure("PC のバックグラウンドのセッションが、この発話を受け付けませんでした（30 秒たっても反応がありません）。");
  }

  private publishFailure(message: string): void {
    this.publish(event.error(AGENT, this.sessionId, message));
    // 失敗は送った発話のもので、動いているターンのものではない。ターンが開いていれば、その done は pending にして終わらせない。
    if (this.turn) this.publish({ ...event.done(AGENT, this.sessionId, crypto.randomUUID()), metadata: { errored: "true", pending: "1" } });
    else this.publish({ ...event.done(AGENT, this.sessionId, crypto.randomUUID()), metadata: { errored: "true" } });
  }

  private jobId(): string {
    return this.host.entryFor(this.sessionId)?.row.id ?? this.sessionId.slice(0, 8);
  }

  // ---- 送信 ----

  async send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    const fail = (message: string): void => {
      emit(event.error(AGENT, this.sessionId, message));
      emit({ ...event.done(AGENT, this.sessionId, crypto.randomUUID()), metadata: { errored: "true" } });
    };
    if (this.options.mode === "elsewhere") {
      const holder = this.holder;
      const where = holder?.entrypoint === "cli" ? "ターミナル" : "ほかのアプリ";
      return fail(`この会話は PC の別の Claude Code（${where}、pid ${holder?.pid ?? "?"}）で開かれています。そちらを閉じてから送ってください。`);
    }
    const entry = this.host.entryFor(this.sessionId);
    if (!entry?.row.live) {
      this.unusable = true;
      return fail("PC のバックグラウンドのセッションが止まりました。もう一度送ると、BuddyOS で続きから再開します。");
    }
    if (entry.row.state === "blocked") {
      return fail(`PC で承認を待っています。PC で \`claude attach ${entry.row.id}\` を開いて答えてから、もう一度送ってください。`);
    }
    const prompt = this.promptText(text, originalEvent);
    if (!entry.inbox) return fail("PC のバックグラウンドのセッションに届けられませんでした（受け箱が見つかりません）。");
    try {
      await this.post(entry.inbox, prompt, bgSessionTiming.postMs);
    } catch (error) {
      return fail(`PC のバックグラウンドのセッションに届けられませんでした（${error instanceof Error ? error.message : String(error)}）。`);
    }
    this.sent.push(prompt.trim());
    while (this.sent.length > SENT_LIMIT) this.sent.shift();
    this.ackSince = undefined;
    this.arm(0);
  }

  /** 添付と skill を本文に展開する（画像はファイルに書き出してパスを添える）。 */
  private promptText(text: string, originalEvent: SessionEvent): string {
    const notes = attachmentTextNotes(originalEvent);
    for (const image of imageAttachments(originalEvent)) {
      const dir = this.options.attachmentDir ?? path.join(os.tmpdir(), "buddyos-attachments");
      try {
        fs.mkdirSync(dir, { recursive: true });
        const file = path.join(dir, `${crypto.randomUUID().slice(0, 8)}-${path.basename(image.name).replace(/[^\w.-]/g, "_")}`);
        fs.writeFileSync(file, Buffer.from(image.b64, "base64"));
        notes.push(`[image "${image.name}" attached: ${file}]`);
      } catch {
        notes.push(`[image "${image.name}" attached: ${image.mime}, ${image.byteLength} bytes]`);
      }
    }
    return [...notes, metadataText(originalEvent, text)].filter(Boolean).join("\n\n");
  }

  /** 返事だけは止められない。 */
  async interrupt(): Promise<void> {
    this.publish(event.error(AGENT, this.sessionId, BG_INTERRUPT_TEXT));
  }

  async warm(): Promise<void> {}

  async respondToAction(): Promise<void> {}

  subagentSnapshot(): string | undefined {
    return undefined;
  }
}

function userMessage(sessionId: string, content: string): SessionEvent {
  return { type: "user_message", agentId: AGENT, sessionId, messageId: crypto.randomUUID(), content };
}

function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((c) => str(obj(c).text) ?? "")
    .filter(Boolean)
    .join("\n");
}
