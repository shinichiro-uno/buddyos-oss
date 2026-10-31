import type { ChildProcessWithoutNullStreams } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { event, type HistoryMessage, type SessionEvent, type SessionSummary } from "../protocol.js";
import { killProcessTree, spawnRuntime, type RuntimeCommand } from "../runtime/command.js";
import { pidAlive } from "./grokPresence.js";
import { finalState, parseTaskOutput, SubagentTracker, toolActivity } from "./subagentTracker.js";
import type { AgentSession, Emit, StopTaskOutcome, StopTaskRequest } from "./types.js";

/**
 * ターミナルの OpenCode（buddy-opencode）と Bridge で会話を共有するための `opencode serve`（mac の
 * OpenCodeServeClient / OpenCodeTerminals の移植。ターミナルで開いている会話を見る・送る分だけ）。
 *
 * - Bridge は serve を 1 本起動し、`~/.buddyos/opencode-serve.json`（url と pid）を書く。buddy-opencode は
 *   これを読んで `opencode attach <url>` で同じ serve に繋ぐ。同じ serve なので、どちらから送っても SSE で両方に流れる。
 * - buddy-opencode は起動中 `~/.buddyos/opencode-terminals/<pid>.json`（cwd）を置く。その場所の
 *   「いちばん最近更新されたセッション」をターミナルとみなす（TUI がどのセッションを開いているかは serve から分からないための近似）。
 * - iPhone から新しく始める会話は従来どおり ACP（opencodeAcp.ts）。serve を使うのはターミナルで開いている会話だけ。
 */

const buddyDir = (): string => path.join(os.homedir(), ".buddyos");
export const opencodeServeFile = (): string => path.join(buddyDir(), "opencode-serve.json");
export const opencodeTerminalsDir = (): string => path.join(buddyDir(), "opencode-terminals");
/** デスクトップのターミナル連携が置く buddy-opencode（これがあるときだけ serve を起動する）。 */
export const opencodeWrapperScript = (): string => path.join(buddyDir(), "bin", "buddy-opencode.mjs");

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" && v.length > 0 ? v : undefined);
const normDir = (p: string): string => path.resolve(p).replace(/[\\/]+$/, "").replace(/\\/g, "/").toLowerCase();

export const OpenCodeTerminals = {
  /** 生きている buddy-opencode の cwd（正規化済み）。pid が死んでいる台帳は掃除する。 */
  liveDirectories(dir = opencodeTerminalsDir(), alive: (pid: number) => boolean = pidAlive): Set<string> {
    const dirs = new Set<string>();
    let names: string[] = [];
    try {
      names = fs.readdirSync(dir);
    } catch {
      return dirs;
    }
    for (const name of names) {
      if (!name.endsWith(".json")) continue;
      const file = path.join(dir, name);
      const pid = Number(name.slice(0, -5));
      if (!Number.isInteger(pid) || pid <= 0 || !alive(pid)) {
        fs.rmSync(file, { force: true });
        continue;
      }
      try {
        const cwd = str(obj(JSON.parse(fs.readFileSync(file, "utf8"))).cwd);
        if (cwd) dirs.add(normDir(cwd));
      } catch {
        // 書きかけ
      }
    }
    return dirs;
  },

  /** 一覧（opencode の session オブジェクト）から、各ライブ cwd で最も新しく更新されたセッションの id。 */
  terminalSessionIds(list: Array<Record<string, unknown>>, liveDirs: Set<string>): Set<string> {
    const newest = new Map<string, { id: string; updated: number }>();
    if (liveDirs.size === 0) return new Set();
    for (const s of list) {
      const id = str(s.id);
      const directory = str(s.directory);
      // サブエージェントのセッションは除く。
      if (!id || !directory || str(s.parentID)) continue;
      const dir = normDir(directory);
      if (!liveDirs.has(dir)) continue;
      const updated = Number(obj(s.time).updated ?? 0) || 0;
      if (updated >= (newest.get(dir)?.updated ?? -1)) newest.set(dir, { id, updated });
    }
    return new Set([...newest.values()].map((v) => v.id));
  }
};

/**
 * 子セッション（task のサブエージェント）で起きたイベント。childSessionId は購読しているセッションの直下の子（task の行の子）、
 * originSessionId は実際に起きたセッション（孫のこともある）。
 */
export interface ServeChildEvent {
  childSessionId: string;
  originSessionId: string;
}

type ServeListener = (type: string, props: Record<string, unknown>, child?: ServeChildEvent) => void;

/** serve が終わった（購読しているセッションへの知らせ。SSE のイベントではない）。 */
export const SERVE_EXITED = "buddyos.serve.exited";

/**
 * 子セッションの進み具合。購読している祖先（iPhone が見ている親）へ回し、task（サブエージェント）の行の作業の文・ツール回数・
 * トークン・モデルと、background の task の終わり（子の idle）にだけ使う（opencode 1.18 は task の part に子の進み具合を載せない）。
 * 親の本文やターンには混ぜない。
 */
const CHILD_PROGRESS_TYPES = new Set(["message.part.updated", "message.updated", "session.status", "session.idle", "session.error"]);
const MAX_CHILD_PARENTS = 2000;

class OpenCodeServeImpl {
  private child?: ChildProcessWithoutNullStreams;
  private starting?: Promise<string | undefined>;
  private baseUrl?: string;
  private readonly routes = new Map<string, Set<ServeListener>>();
  /** 子セッション（task のサブエージェント）sid → 親 sid。session.created / updated の info.parentID と task の metadata から作る。 */
  private readonly childParents = new Map<string, string>();
  private sse?: http.ClientRequest;
  private sseRetry?: NodeJS.Timeout;

  get url(): string | undefined {
    return this.baseUrl;
  }

  /** serve を起動して URL を返す（起動済みならそのまま）。起動できなければ undefined。 */
  ensure(runtime: RuntimeCommand): Promise<string | undefined> {
    if (this.baseUrl && this.child && this.child.exitCode === null) return Promise.resolve(this.baseUrl);
    if (this.starting) return this.starting;
    this.starting = this.start(runtime).finally(() => {
      this.starting = undefined;
    });
    return this.starting;
  }

  private start(runtime: RuntimeCommand): Promise<string | undefined> {
    return new Promise((resolve) => {
      let child: ChildProcessWithoutNullStreams;
      try {
        // --port 0 で空きポートを選ばせ、stdout の "listening on http://127.0.0.1:NNNN" から拾う。
        child = spawnRuntime(runtime, ["serve", "--port", "0", "--hostname", "127.0.0.1"], {
          cwd: os.homedir(),
          env: { ...process.env, XDG_CACHE_HOME: "/tmp/oc-cache" },
          stdio: "pipe"
        });
      } catch {
        resolve(undefined);
        return;
      }
      this.child = child;
      let seen = "";
      let settled = false;
      const finish = (url: string | undefined): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (!url) {
          killProcessTree(child);
          resolve(undefined);
          return;
        }
        this.baseUrl = url;
        this.publish(url, child.pid);
        process.stderr.write(`[opencode-serve] ready ${url}\n`);
        if (this.routes.size > 0) this.connectEvents();
        resolve(url);
      };
      const timer = setTimeout(() => finish(undefined), 30_000);
      const onData = (chunk: Buffer): void => {
        if (settled) return;
        seen = (seen + chunk.toString("utf8")).slice(-4000);
        const m = /listening on (http:\/\/[^\s]+)/i.exec(seen);
        if (m) finish(m[1].replace(/\/+$/, ""));
      };
      child.stdout.on("data", onData);
      child.stderr.on("data", onData);
      child.stdin.on("error", () => {});
      child.on("error", () => finish(undefined));
      child.on("exit", () => {
        finish(undefined);
        if (this.child !== child) return;
        this.child = undefined;
        this.baseUrl = undefined;
        this.unpublish();
        process.stderr.write("[opencode-serve] exited\n");
        this.serverExited();
      });
    });
  }

  /**
   * serve が（Bridge が止めたのではなく）終わった。子セッションも一緒に止まり、終わりの知らせはもう来ないので、購読している
   * セッションに知らせる（実行中の行を閉じる）。テストからも呼ぶ。
   */
  serverExited(): void {
    this.childParents.clear();
    for (const set of [...this.routes.values()]) for (const listener of [...set]) listener(SERVE_EXITED, {});
  }

  stop(): void {
    const child = this.child;
    this.child = undefined;
    this.baseUrl = undefined;
    this.sse?.destroy();
    this.sse = undefined;
    if (this.sseRetry) clearTimeout(this.sseRetry);
    this.unpublish();
    killProcessTree(child);
  }

  private publish(url: string, pid: number | undefined): void {
    try {
      fs.mkdirSync(buddyDir(), { recursive: true });
      fs.writeFileSync(opencodeServeFile(), JSON.stringify({ url, pid: pid ?? process.pid }), { encoding: "utf8", mode: 0o600 });
    } catch {
      // buddy-opencode は普通の opencode に倒れる
    }
  }

  private unpublish(): void {
    fs.rmSync(opencodeServeFile(), { force: true });
  }

  /** `?directory=` 付きの HTTP。opencode はこれでリクエストを instance に振り分ける。 */
  async http(method: string, route: string, body?: unknown, directory?: string, timeoutMs = 120_000): Promise<unknown> {
    const base = this.baseUrl;
    if (!base) throw new Error("opencode serve is not running");
    const url = new URL(`${base}/${route}`);
    if (directory) url.searchParams.set("directory", directory);
    // fetch（undici）は応答ヘッダーを 5 分で打ち切る。メッセージの POST はターンが終わるまで返らないので node:http で待つ。
    const { status, text } = await new Promise<{ status: number; text: string }>((resolve, reject) => {
      const req = http.request(url, { method, headers: { "content-type": "application/json" } }, (res) => {
        let data = "";
        res.setEncoding("utf8");
        res.on("data", (c: string) => (data += c));
        res.on("end", () => resolve({ status: res.statusCode ?? 0, text: data }));
        res.on("error", reject);
      });
      const timer = setTimeout(() => req.destroy(new Error(`timed out: ${method} ${route}`)), timeoutMs);
      req.on("close", () => clearTimeout(timer));
      req.on("error", reject);
      req.end(body === undefined ? undefined : JSON.stringify(body));
    });
    if (status < 200 || status >= 300) throw new Error(`HTTP ${status} ${method} ${route}: ${text.slice(0, 300)}`);
    return text ? (JSON.parse(text) as unknown) : null;
  }

  async listSessions(directory: string): Promise<Array<Record<string, unknown>>> {
    const res = await this.http("GET", "session", undefined, directory, 10_000);
    return Array.isArray(res) ? res.map(obj) : [];
  }

  /** ターミナルで開いている会話（serve が動いていて、buddy-opencode が生きている場所の最新のセッション）。 */
  async terminalSessions(): Promise<Array<Record<string, unknown>>> {
    if (!this.baseUrl) return [];
    const dirs = OpenCodeTerminals.liveDirectories();
    if (dirs.size === 0) return [];
    const all: Array<Record<string, unknown>> = [];
    for (const dir of dirs) {
      try {
        all.push(...(await this.listSessions(dir)));
      } catch {
        // その場所は飛ばす
      }
    }
    const ids = OpenCodeTerminals.terminalSessionIds(all, dirs);
    return all.filter((s) => ids.has(String(s.id)));
  }

  async history(sessionId: string): Promise<HistoryMessage[]> {
    const res = await this.http("GET", `session/${encodeURIComponent(sessionId)}/message`, undefined, undefined, 30_000);
    const list = Array.isArray(res) ? res : Array.isArray(obj(res).messages) ? (obj(res).messages as unknown[]) : [];
    return historyFromServe(list);
  }

  /** セッションのイベントを受ける。返り値で外す。 */
  subscribe(sessionId: string, listener: ServeListener): () => void {
    let set = this.routes.get(sessionId);
    if (!set) this.routes.set(sessionId, (set = new Set()));
    set.add(listener);
    this.connectEvents();
    return () => {
      set?.delete(listener);
      if (set?.size === 0) this.routes.delete(sessionId);
    };
  }

  /** `GET /global/event`（全セッション共有の SSE）を 1 本だけ開き、sessionID で配る。切れたら繋ぎ直す。 */
  private connectEvents(): void {
    if (this.sse || !this.baseUrl || this.sseRetry) return;
    const url = new URL(`${this.baseUrl}/global/event`);
    const req = http.get(url, { headers: { accept: "text/event-stream" } }, (res) => {
      if (res.statusCode !== 200) {
        res.resume();
        req.destroy();
        return;
      }
      res.setEncoding("utf8");
      let buf = "";
      res.on("data", (chunk: string) => {
        buf += chunk;
        for (;;) {
          const end = buf.search(/\r?\n\r?\n/);
          if (end < 0) break;
          const frame = buf.slice(0, end);
          buf = buf.slice(end).replace(/^\r?\n\r?\n/, "");
          const data = frame
            .split(/\r?\n/)
            .filter((l) => l.startsWith("data:"))
            .map((l) => l.slice(5).replace(/^ /, ""))
            .join("\n");
          if (data) this.dispatch(data);
        }
      });
    });
    this.sse = req;
    const retry = (): void => {
      if (this.sse !== req) return;
      this.sse = undefined;
      if (this.routes.size === 0 || !this.baseUrl) return;
      this.sseRetry = setTimeout(() => {
        this.sseRetry = undefined;
        this.connectEvents();
      }, 2000);
      this.sseRetry.unref();
    };
    req.on("error", retry);
    req.on("close", retry);
  }

  /**
   * task の part の metadata（sessionId = 子、parentSessionId = 親）から子セッションの親を覚える。
   * session.created を取りこぼしても（SSE の張り直し・Bridge の再起動）、子の進み具合を親へ回せるように。
   */
  linkChild(childId: string, parentId: string): void {
    if (!childId || !parentId || childId === parentId || this.childParents.get(childId) === parentId) return;
    if (this.childParents.size >= MAX_CHILD_PARENTS) this.childParents.clear();
    this.childParents.set(childId, parentId);
  }

  /** sid が ancestor の子孫のセッションか（task の子・孫）。ancestor 自身は含まない。 */
  isDescendant(sid: string, ancestor: string): boolean {
    let cur = sid;
    for (let hops = 0; hops < 8; hops += 1) {
      const parent = this.childParents.get(cur);
      if (!parent) return false;
      if (parent === ancestor) return true;
      cur = parent;
    }
    return false;
  }

  /** SSE の 1 フレーム（JSON）を sessionID で配る。テストからも呼ぶ。 */
  dispatch(data: string): void {
    let parsed: Record<string, unknown>;
    try {
      parsed = obj(JSON.parse(data));
    } catch {
      return;
    }
    // `/global/event` は {directory, payload:{type, properties}}。旧 `/event` 形式（{type, properties}）もそのまま読む。
    const ev = parsed.payload ? obj(parsed.payload) : parsed;
    const type = str(ev.type) ?? "";
    const props = obj(ev.properties);
    const info = obj(props.info);
    // 子セッション（サブエージェント）の親を覚える。
    if (type === "session.created" || type === "session.updated") {
      const id = str(info.id);
      const parent = str(info.parentID);
      if (id && parent) this.linkChild(id, parent);
    } else if (type === "session.deleted") {
      const id = str(info.id);
      if (id) this.childParents.delete(id);
    }
    const sid = str(props.sessionID) ?? str(info.sessionID) ?? str(obj(props.part).sessionID);
    if (!sid) return;
    // 子セッションの進み具合は、購読している祖先（iPhone が見ている親）まで辿って配る。
    let target = sid;
    let child: string | undefined;
    if (CHILD_PROGRESS_TYPES.has(type)) {
      for (let hops = 0; hops < 8 && !this.routes.get(target)?.size; hops += 1) {
        const parent = this.childParents.get(target);
        if (!parent) break;
        child = target;
        target = parent;
      }
    }
    const forwarded = child !== undefined ? { childSessionId: child, originSessionId: sid } : undefined;
    for (const listener of [...(this.routes.get(target) ?? [])]) listener(type, props, forwarded);
  }
}

export const OpenCodeServe = new OpenCodeServeImpl();

/** serve の message 一覧（[{info, parts}]）を履歴にする。本文の part だけを拾う。 */
export function historyFromServe(list: unknown[]): HistoryMessage[] {
  const out: HistoryMessage[] = [];
  for (const raw of list) {
    const m = obj(raw);
    const info = obj(m.info ?? m);
    const role = str(info.role);
    if (role !== "user" && role !== "assistant") continue;
    const parts = Array.isArray(m.parts) ? m.parts.map(obj) : [];
    const text = parts
      .filter((p) => p.type === "text" && typeof p.text === "string" && p.synthetic !== true)
      .map((p) => String(p.text))
      .join("")
      .trim();
    if (!text) continue;
    const created = Number(obj(info.time).created);
    out.push({
      role,
      content: text,
      messageId: str(info.id) ?? crypto.randomUUID(),
      ...(Number.isFinite(created) && created > 0 ? { createdAt: new Date(created).toISOString() } : {})
    });
  }
  return out;
}

/** serve の session オブジェクトを一覧の行にする。 */
export function summaryFromServe(s: Record<string, unknown>): SessionSummary {
  const updated = Number(obj(s.time).updated);
  return {
    sessionId: String(s.id),
    title: str(s.title) ?? "OpenCode（ターミナル）",
    lastActive: new Date(Number.isFinite(updated) && updated > 0 ? updated : Date.now()).toISOString(),
    cwd: str(s.directory),
    terminal: true
  };
}

/**
 * serve のイベントを iPhone 向けのイベントにする（mac の OpenCodeServeSession.handleServeEvent の要点）。
 * ターミナルで打った発話は user_message として流し、iPhone から送った分は送った側が表示済みなので流さない。
 * 自分が送っていない新しい発言（ターミナルの TUI・裏で動いていたサブエージェントの結果の synthetic な差し込み）は、
 * 別のターンとして開いて本文と done を流す（差し込みで開いたターンは知らせのターン）。
 * サブエージェント（task）の行は docs/BACKGROUND_WORK_2026-10-21.md §3.6（opencode 1.18.32 の実測）。
 */
export class OpenCodeServeTranslator {
  private readonly roles = new Map<string, string>();
  private readonly partTypes = new Map<string, string>();
  private readonly partSent = new Map<string, number>();
  private readonly shownUserParts = new Set<string>();
  private readonly tools = new Map<string, { name: string; start: number }>();
  private readonly ownTexts: string[] = [];
  private turnActive = false;
  private lastAssistant?: string;
  /** 自分が送っていない発言で開いたターンの user messageID（自分の送信で開いたターンなら undefined）。 */
  private turnOpener?: string;
  /** そのターンを開いたのが、裏で動いていたサブエージェントの結果の差し込み（<task id=子 state=…>）か。 */
  private openerIsNotification = false;
  /** そのターンに発言（ターミナルの発言・自分の送信）があったか。あれば知らせのターンではない。 */
  private openerHasUtterance = false;
  /** サブエージェント（task ツール。キーは callID）。セッションに 1 つ。 */
  private readonly subagents = new SubagentTracker();
  /** 行の state（payload から覚える）。終わった行を、後から届いた task の part で実行中に戻さない。 */
  private readonly taskStates = new Map<string, string>();
  /** 見た task の callID（最近の 256 件まで）。新しいターンで忘れた行の遅れた part を、行にし直さない。 */
  private readonly seenTasks = new Set<string>();
  /** 子セッション（task の metadata.sessionId）ごとの覚え書き。子のイベントを行に結び付ける。 */
  private readonly children = new Map<string, ServeChild>();
  /** metadata.background == true の task（親のターンより長く動く）の callID。 */
  private readonly backgroundTasks = new Set<string>();
  /** 開いたターンの通し番号（自分の送信・ほかの画面の発言で開くたびに進む）。 */
  private turnSeq = 0;

  constructor(
    private readonly agentId: string,
    private readonly sessionId: string,
    /** task の part で分かった子セッションとその親（OpenCodeServe.linkChild。子のイベントをこのセッションへ回す）。 */
    private readonly onChild?: (childId: string, parentId: string) => void
  ) {}

  get active(): boolean {
    return this.turnActive;
  }

  /** いまのターンの通し番号（finish(turn) で、その後に開いたほかの画面のターンを閉じないために使う）。 */
  get currentTurn(): number {
    return this.turnSeq;
  }

  /** iPhone から送った文（serve から user として戻ってきたら出し直さない）。 */
  noteOwnText(text: string): void {
    this.ownTexts.push(text.trim());
    if (!this.turnActive) {
      // 新しいターン（生成中でない自分の送信）。終わった行を忘れる（アプリも送信で終わった行を捨てる）。
      this.pruneFinished();
      this.turnSeq += 1;
    }
    // 自分の発言の入ったターンは、知らせのターンではない。
    this.openerHasUtterance = true;
    this.turnActive = true;
  }

  /**
   * ターンを閉じる（done を出すときだけ返す）。差し込みで開いたターンの done は metadata.origin = "task-notification"。
   * turn を渡すと、そのターンがまだ開いているときだけ閉じる。
   */
  finish(turn?: number): SessionEvent[] {
    if (!this.turnActive || (turn !== undefined && turn !== this.turnSeq)) return [];
    this.turnActive = false;
    this.tools.clear();
    const notification = this.turnOpener !== undefined && this.openerIsNotification && !this.openerHasUtterance;
    this.turnOpener = undefined;
    this.openerIsNotification = false;
    this.openerHasUtterance = false;
    const done = event.done(this.agentId, this.sessionId, this.lastAssistant ?? crypto.randomUUID());
    return [notification ? { ...done, metadata: { origin: "task-notification" } } : done];
  }

  /** 実行中の行を閉じる（中断・送信の失敗・close・serve の終了）。onlyForeground なら background の task は残す。 */
  abandon(state: string, onlyForeground: boolean): SessionEvent[] {
    return this.rows(this.subagents.abandonRunning({ state, onlyForeground }));
  }

  /** サブエージェントのカードの全行（workflow_snapshot。行が無くても agents: []）。 */
  snapshot(): string | undefined {
    return this.subagents.snapshot({ includeEmpty: true });
  }

  feed(type: string, props: Record<string, unknown>): SessionEvent[] {
    const out: SessionEvent[] = [];
    const sid = this.sessionId;
    switch (type) {
      case "message.updated": {
        const info = obj(props.info);
        const id = str(info.id);
        const role = str(info.role);
        if (id && role) {
          if (role === "user" && !this.roles.has(id)) this.noteNewUserMessage(id, info);
          this.roles.set(id, role);
        }
        return out;
      }
      case "message.part.updated": {
        const part = obj(props.part);
        const pid = str(part.id) ?? "";
        const mid = str(part.messageID) ?? "";
        const ptype = str(part.type) ?? "";
        if (pid) this.partTypes.set(pid, ptype);
        if (this.roles.get(mid) === "user") {
          if (ptype !== "text" || this.shownUserParts.has(pid)) return out;
          if (part.synthetic === true) return this.injectedPart(mid, part);
          const text = typeof part.text === "string" ? part.text.trim() : "";
          if (!text) return out;
          this.shownUserParts.add(pid);
          const own = this.ownTexts.findIndex((t) => t === text || text.includes(t) || t.includes(text));
          if (own >= 0) this.ownTexts.splice(own, 1);
          else {
            // ほかの画面（ターミナルの TUI）の発言で開いたターンなら、新しいターンなので終わった行を捨てる（1 回だけ）。
            if (mid === this.turnOpener && !this.openerHasUtterance) this.pruneFinished();
            this.openerHasUtterance = true;
            out.push({ type: "user_message", agentId: this.agentId, sessionId: sid, messageId: mid || crypto.randomUUID(), content: text });
          }
          return out;
        }
        if (ptype === "text" || ptype === "reasoning") {
          const full = typeof part.text === "string" ? part.text : "";
          const sent = this.partSent.get(pid) ?? 0;
          if (full.length <= sent) return out;
          const rest = full.slice(sent);
          this.partSent.set(pid, full.length);
          this.turnActive = true;
          if (ptype === "reasoning") out.push(event.activity(this.agentId, sid, mid || "pending-thought", rest));
          else {
            this.lastAssistant = mid || this.lastAssistant;
            out.push(event.assistantDelta(this.agentId, sid, mid || crypto.randomUUID(), rest));
          }
        } else if (ptype === "tool") {
          const callId = str(part.callID);
          if (!callId) return out;
          const name = str(part.tool) ?? "tool";
          const state = obj(part.state);
          const status = str(state.status) ?? "";
          if (name === "task") out.push(...this.taskPart(callId, state, status));
          if ((status === "pending" || status === "running") && !this.tools.has(callId)) {
            this.turnActive = true;
            this.tools.set(callId, { name, start: Date.now() });
            const title = str(state.title) ?? str(obj(state.input).command) ?? str(obj(state.input).filePath) ?? name;
            out.push(event.toolStart(this.agentId, sid, callId, name, title, toolKind(name)));
          } else if (status === "completed" || status === "error") {
            const t = this.tools.get(callId);
            this.tools.delete(callId);
            const output = typeof state.output === "string" ? state.output.slice(0, 1200) : undefined;
            // 中断で終わった task は失敗ではない（赤くしない）。
            const aborted = name === "task" && status === "error" && isAbortError(str(state.error));
            out.push(event.toolEnd(this.agentId, sid, callId, name, status === "error" ? (aborted ? "interrupted" : "failed") : "completed", output, t ? Date.now() - t.start : undefined));
          }
        }
        return out;
      }
      case "message.part.delta": {
        if (str(props.field) !== "text") return out;
        const delta = typeof props.delta === "string" ? props.delta : "";
        const pid = str(props.partID) ?? "";
        const mid = str(props.messageID) ?? "";
        if (!delta || !pid || this.roles.get(mid) === "user") return out;
        this.partSent.set(pid, (this.partSent.get(pid) ?? 0) + delta.length);
        this.turnActive = true;
        if (this.partTypes.get(pid) === "reasoning") out.push(event.activity(this.agentId, sid, mid || "pending-thought", delta));
        else {
          this.lastAssistant = mid || this.lastAssistant;
          out.push(event.assistantDelta(this.agentId, sid, mid || crypto.randomUUID(), delta));
        }
        return out;
      }
      case "session.idle":
        return this.finish();
      case "session.error": {
        if (!this.turnActive) return out;
        const err = obj(props.error);
        const message = str(obj(err.data).message) ?? str(err.message) ?? str(err.name) ?? "OpenCode error";
        out.push(event.error(this.agentId, sid, message));
        return [...out, ...this.finish()];
      }
      default:
        return out;
    }
  }

  /**
   * 子セッション（task のサブエージェント）のイベント。OpenCodeServe が、購読している祖先（このセッション）へ回す。
   * childSessionId はこのセッションの直下の子（task の行の子）、originSessionId は実際に起きたセッション（孫のこともある）。
   * ツールの title を行の作業の文とツール回数に、assistant の tokens・modelID を行に入れ、background の task は
   * 子の idle で閉じる。本文やターンには混ぜない。
   */
  feedChild(childSessionId: string, originSessionId: string, type: string, props: Record<string, unknown>): SessionEvent[] {
    const c = this.children.get(childSessionId);
    if (!c || !this.subagents.has(c.callID)) return [];
    const direct = originSessionId === childSessionId;
    switch (type) {
      case "message.part.updated": {
        const part = obj(props.part);
        if (part.type === "tool") {
          const state = obj(part.state);
          const name = str(part.tool) ?? "tool";
          const key = str(part.callID) ?? str(part.id) ?? "";
          const first = key !== "" && !c.toolCalls.has(key);
          if (first) c.toolCalls.add(key);
          const title = str(state.title);
          const text = title ? `${name}: ${title}` : toolActivity(name, state.input);
          // 実行中の出力の更新（metadata.output が伸びるたびに届く）は、文が変わらなければ送らない。
          if (!first && text === c.lastActivity) return [];
          c.lastActivity = text;
          return this.rows(this.subagents.activity(c.callID, text, { toolCall: first }));
        }
        // 子への依頼（user の発言）ではなく、子の返事の本文だけ（background の task を子の idle で閉じるときの結果）。
        const mid = str(part.messageID);
        const text = str(part.text);
        if (part.type === "text" && direct && mid && c.assistantMessages.has(mid) && text) c.lastText = text;
        return [];
      }
      case "message.updated": {
        const info = obj(props.info);
        if (!direct || info.role !== "assistant") return [];
        const mid = str(info.id);
        const isNewMessage = mid !== undefined && !c.assistantMessages.has(mid);
        if (mid) c.assistantMessages.add(mid);
        if (info.error && typeof info.error === "object") c.end = childEnd(info.error);
        else if (isNewMessage) c.end = undefined; // エラーの後に新しい返事を始めた（再試行等）
        const total = totalTokens(obj(info.tokens));
        if (mid && total !== undefined && total > 0) c.tokensByMessage.set(mid, total);
        const sum = c.tokensByMessage.size > 0 ? [...c.tokensByMessage.values()].reduce((a, b) => a + b, 0) : undefined;
        const model = str(info.modelID);
        if (sum === c.lastTokens && (model === undefined || model === c.model)) return [];
        c.lastTokens = sum;
        if (model) c.model = model;
        return this.rows(this.subagents.activity(c.callID, undefined, { tokens: sum, model }));
      }
      case "session.error":
        if (direct && c.end === undefined) c.end = childEnd(props.error);
        return [];
      case "session.idle":
      case "session.status":
        // 前景の task は親の task の part の終わりで閉じる。background の task だけ、子の idle で閉じる。
        if (!direct || !this.backgroundTasks.has(c.callID)) return [];
        if (type === "session.status" && obj(props.status).type !== "idle") return [];
        return this.rows(this.subagents.finish(c.callID, c.end?.state ?? "done", c.end?.message ?? c.lastText));
      default:
        return [];
    }
  }

  /**
   * 新しい user message。開いているターン（自分の送信・opencode がターンの途中に足す発言）なら、そのターンの発言。
   * 閉じていれば、自分が送っていない発言（ターミナルの TUI・裏で動いていた子の結果の差し込み）で opencode がターンを
   * 始めたので、別のターンとして開く。前からある発言の再 publish（作られたのが古い）では開かない。
   */
  private noteNewUserMessage(id: string, info: Record<string, unknown>): void {
    if (this.turnActive) return;
    const created = Number(obj(info.time).created);
    if (Number.isFinite(created) && created > 0 && Date.now() - created > REMOTE_TURN_FRESHNESS_MS) return;
    this.turnActive = true;
    this.turnSeq += 1;
    this.turnOpener = id;
    this.openerIsNotification = false;
    this.openerHasUtterance = false;
  }

  /**
   * 発言（user）の synthetic な part。`<task id=子 state=…>` は裏で動いていたサブエージェントの結果の差し込みなので、
   * その task の行を閉じ、それで開いたターンは知らせのターンにする（done に origin を付ける）。
   */
  private injectedPart(mid: string, part: Record<string, unknown>): SessionEvent[] {
    const text = typeof part.text === "string" ? part.text : "";
    const child = taskOutputSessionId(text);
    if (!child) return [];
    if (mid === this.turnOpener) this.openerIsNotification = true;
    const task = parseTaskOutput(text);
    const callID = this.children.get(child)?.callID;
    if (task.state === "running" || !callID) return [];
    return this.rows(this.subagents.finish(callID, (task.state !== undefined ? finalState(task.state) : undefined) ?? "done", task.result ?? task.summary));
  }

  /**
   * task ツール = サブエージェント（行のキーは callID）。input = { description, prompt, subagent_type, background? }。
   * running の metadata は { parentSessionId, sessionId（子セッション）, model, background? }（1.18。1.17 以前は子のツールの一覧
   * summary）。子の進み具合は子セッションのイベントで届く（feedChild）。出力は `<task id=子 state=completed|running|error>`
   * （parseTaskOutput）で、running は終わりではない。background の task はすぐ completed（state="running"）になるので
   * 行は実行中のまま持ち、子の idle か、差し込まれた `<task id=子 state=…>` で閉じる。
   * 終わった行は実行中に戻さない（中断で閉じた後に届く part）。忘れた行（新しいターンで捨てた）は行にし直さない。
   */
  private taskPart(callID: string, state: Record<string, unknown>, status: string): SessionEvent[] {
    const input = obj(state.input);
    const metadata = state.metadata && typeof state.metadata === "object" ? obj(state.metadata) : undefined;
    const child = str(metadata?.sessionId);
    const parent = str(metadata?.parentSessionId) ?? this.sessionId;
    const known = this.subagents.has(callID);
    if (!known && this.seenTasks.has(callID)) return [];
    this.seenTasks.delete(callID);
    this.seenTasks.add(callID);
    if (this.seenTasks.size > 256) this.seenTasks.delete(this.seenTasks.values().next().value!);
    if (child && this.children.get(child)?.callID !== callID) this.children.set(child, newChild(callID));
    if (metadata?.background === true || input.background === true) this.backgroundTasks.add(callID);
    const background = this.backgroundTasks.has(callID) ? true : metadata === undefined ? undefined : false;
    const out: SessionEvent[] = [];
    if (!known || (this.taskStates.get(callID) === "running" && (status === "pending" || status === "running"))) {
      out.push(
        ...this.rows(
          this.subagents.begin(callID, str(input.description) ?? str(state.title), {
            agentType: str(input.subagent_type),
            model: str(obj(metadata?.model).modelID),
            background
          })
        )
      );
    }
    switch (status) {
      case "completed": {
        const output = typeof state.output === "string" ? state.output : "";
        const task = parseTaskOutput(output);
        if (task.state === "running") {
          // 裏で動き出した（background か、前景から移された）。終わりにせず、子の idle か差し込みを待つ。
          this.backgroundTasks.add(callID);
          if (this.subagents.activity(callID, task.summary) !== undefined) out.push(...this.rows(this.subagents.begin(callID, undefined, { background: true })));
        } else {
          const outcome = (task.state !== undefined ? finalState(task.state) : undefined) ?? "done";
          out.push(...this.rows(this.subagents.finish(callID, outcome, task.result ?? task.summary ?? (output.trim() || undefined))));
        }
        break;
      }
      case "error": {
        // 中断で止まったもの（「Task cancelled」「Tool execution aborted」）は失敗ではない。
        const error = str(state.error);
        out.push(...this.rows(this.subagents.finish(callID, isAbortError(error) ? "stopped" : "failed", error)));
        break;
      }
      default: {
        // 1.17 以前の、実行中の metadata.summary（子のツールの一覧）。
        const summary = Array.isArray(metadata?.summary) ? (metadata.summary as unknown[]).map(obj) : [];
        const lastTool = summary.at(-1);
        if (lastTool) out.push(...this.rows(this.subagents.activity(callID, str(obj(lastTool.state).title) ?? str(lastTool.tool), { toolCalls: summary.length })));
      }
    }
    // 子のセッション id が分かった実行中の行は、abort で止められる。
    if (child && this.subagents.isRunning(callID)) out.push(...this.rows(this.subagents.setStopHandle(callID, true)));
    // session.created を取りこぼしても（SSE の張り直し等）、子のイベントをこのセッションへ回せるように。
    if (child) this.onChild?.(child, parent);
    return out;
  }

  /** カードの epoch（stop_task_request の epoch と照らす）。 */
  get epoch(): string {
    return this.subagents.epoch;
  }

  hasRow(callID: string): boolean {
    return this.subagents.has(callID);
  }

  isRowRunning(callID: string): boolean {
    return this.subagents.isRunning(callID);
  }

  /** 行の state（running / done / failed / stopped）。行が無ければ undefined。 */
  rowState(callID: string): string | undefined {
    return this.subagents.stateOf(callID);
  }

  /** 行の子セッション id（task の metadata.sessionId で分かったもの）。 */
  childSessionOf(callID: string): string | undefined {
    for (const [child, c] of this.children) if (c.callID === callID) return child;
    return undefined;
  }

  /** 停止を始める。ok なら返事待ち（stoppable: false）の payload を events で返す。 */
  beginStop(callID: string): { kind: "ok"; child: string; events: SessionEvent[] } | { kind: "notRunning" | "unsupported" | "inFlight" } {
    const child = this.childSessionOf(callID);
    const begin = this.subagents.beginStop(callID);
    if (begin.kind !== "ok") return { kind: begin.kind };
    if (!child) {
      this.subagents.endStop(callID);
      return { kind: "unsupported" };
    }
    return { kind: "ok", child, events: this.rows(begin.payload) };
  }

  /** 停止が失敗した。返事待ちを戻す（stoppable: true に戻して送る）。 */
  endStop(callID: string): SessionEvent[] {
    return this.rows(this.subagents.endStop(callID));
  }

  /** 親のターンが閉じているときの done（interrupt が何も止めずに、停止ボタンの表示だけ戻す）。 */
  doneAgain(): SessionEvent {
    return event.done(this.agentId, this.sessionId, this.lastAssistant ?? crypto.randomUUID());
  }

  /** トラッカーの payload をイベントにし、行の state を覚える。 */
  private rows(payload: string | undefined): SessionEvent[] {
    if (!payload) return [];
    for (const a of (JSON.parse(payload) as { agents?: Array<{ id?: string; state?: string }> }).agents ?? []) {
      if (a.id && a.state) this.taskStates.set(a.id, a.state);
    }
    return [event.workflowProgress(this.agentId, this.sessionId, payload)];
  }

  /** 新しいターン（自分の送信・ほかの画面の発言）で、終わった行を忘れる（裏で動き続けている task は残す。知らせのターンでは呼ばない）。 */
  private pruneFinished(): void {
    this.subagents.pruneFinished();
    for (const [child, c] of this.children) if (!this.subagents.has(c.callID)) this.children.delete(child);
    for (const id of this.backgroundTasks) if (!this.subagents.has(id)) this.backgroundTasks.delete(id);
    for (const id of this.taskStates.keys()) if (!this.subagents.has(id)) this.taskStates.delete(id);
  }
}

/** 行の停止の待ち時間（abort の HTTP と、行が閉じるまで）。テストが短くする。 */
export const serveStopTiming = { abortMs: 10_000, closeMs: 5_000, rejectMs: 3_000 };

/** ほかの画面のターンとして開く発言の新しさ。これより前に作られた発言の再 publish（summary の更新等）は開かない。 */
const REMOTE_TURN_FRESHNESS_MS = 120_000;

/** 子セッション（task のサブエージェント）の覚え書き。 */
interface ServeChild {
  callID: string;
  /** 子のツール呼び出し（callID）。数えたものは数えない。 */
  toolCalls: Set<string>;
  /** 最後に送った作業の文 */
  lastActivity?: string;
  /** assistant messageID → そのメッセージのトークン数（合計を行のトークン数にする） */
  tokensByMessage: Map<string, number>;
  lastTokens?: number;
  model?: string;
  /** 子の最後の返事（background の task を子の idle で閉じるときの結果）。子の assistant の発言の本文だけを見る。 */
  lastText?: string;
  assistantMessages: Set<string>;
  /** 子の最後の assistant の error（中断なら stopped、ほかは failed とその理由） */
  end?: { state: string; message?: string };
}

const newChild = (callID: string): ServeChild => ({ callID, toolCalls: new Set(), tokensByMessage: new Map(), assistantMessages: new Set() });

/** task の出力（とその差し込み）の `<task id="…"` の id（子セッション）。無ければ undefined。 */
export function taskOutputSessionId(text: string): string | undefined {
  const attrs = /<task ([^>]*)>/.exec(text)?.[1];
  return attrs !== undefined ? /(?:^| )id="([^"]+)"/.exec(attrs)?.[1] : undefined;
}

/** 中断で止まった task のエラーか（「Task cancelled」「Tool execution aborted」等）。 */
function isAbortError(text: string | undefined): boolean {
  const t = text?.toLowerCase() ?? "";
  return t.includes("cancel") || t.includes("abort");
}

/** 子の error。MessageAbortedError（中断）は stopped、ほかは failed とその理由。 */
function childEnd(raw: unknown): { state: string; message?: string } | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const err = raw as Record<string, unknown>;
  if (err.name === "MessageAbortedError") return { state: "stopped" };
  const name = str(err.name);
  const message = str(obj(err.data).message) ?? str(err.message);
  return { state: "failed", message: name && message ? `${name}: ${message}` : (message ?? name) };
}

/** assistant の tokens（{total?, input, output, reasoning, cache: {read, write}}）の合計。 */
function totalTokens(t: Record<string, unknown>): number | undefined {
  const n = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : undefined);
  const total = n(t.total);
  if (total !== undefined) return total;
  const cache = obj(t.cache);
  const parts = [n(t.input), n(t.output), n(t.reasoning), n(cache.read), n(cache.write)].filter((v): v is number => v !== undefined);
  return parts.length > 0 ? parts.reduce((a, b) => a + b, 0) : undefined;
}

function toolKind(name: string): string {
  if (name === "bash") return "execute";
  if (name === "edit" || name === "write" || name === "patch") return "edit";
  if (name === "read" || name === "glob" || name === "grep" || name === "list") return "read";
  return "other";
}

/**
 * ターミナルの OpenCode が開いている会話を、同じ serve 越しに見る・送るセッション。
 * 送ったターンの承認（permission.asked）はターミナルの TUI が受ける。
 */
export class OpenCodeServeTerminalSession implements AgentSession {
  private emit?: Emit;
  private unsubscribe?: () => void;
  private readonly translator: OpenCodeServeTranslator;
  private turnDone?: () => void;
  /** 同じ行への停止の実行中（同時に押されたら、最初の結果を返す）。 */
  private readonly stopRuns = new Map<string, Promise<StopTaskOutcome>>();

  constructor(
    private readonly agentId: string,
    public sessionId: string,
    private readonly directory: string | undefined
  ) {
    this.translator = new OpenCodeServeTranslator(agentId, sessionId, (child, parent) => OpenCodeServe.linkChild(child, parent));
  }

  /** 開いた時点からターミナルのターンを流す。 */
  async watch(emit: Emit): Promise<void> {
    this.emit ??= emit;
    this.ensureSubscribed();
  }

  async send(text: string, _originalEvent: SessionEvent, emit: Emit): Promise<void> {
    this.emit = emit;
    this.ensureSubscribed();
    this.translator.noteOwnText(text);
    const turn = this.translator.currentTurn;
    const finished = new Promise<void>((resolve) => (this.turnDone = resolve));
    // POST はターン完了まで返らない。返事は SSE で流れ、session.idle で done にする。
    OpenCodeServe.http("POST", `session/${encodeURIComponent(this.sessionId)}/message`, { parts: [{ type: "text", text }] }, this.directory, 7 * 24 * 3600_000)
      .then(() => {
        // idle を取りこぼしても、POST が返ればターンは終わっている（その後に開いた、ほかの画面・差し込みのターンは閉じない）。
        setTimeout(() => {
          this.deliver(this.translator.finish(turn));
          this.turnDone?.();
        }, 1500).unref();
      })
      .catch((error: unknown) => {
        // 送信に失敗したターンの前景の task は続かない（background の task は子の idle で閉じる）。
        this.deliver([
          ...this.translator.abandon("failed", true),
          event.error(this.agentId, this.sessionId, `ターミナルの OpenCode に送れませんでした: ${error instanceof Error ? error.message : String(error)}`),
          ...this.translator.finish()
        ]);
        this.turnDone?.();
      });
    await finished;
    this.turnDone = undefined;
  }

  async interrupt(): Promise<void> {
    // 親のターンが動いていないときの abort は、裏で動いている子まで止めてしまう（実測 e11）。何も止めず done だけ返す。
    if (!this.translator.active) {
      this.deliver([this.translator.doneAgain()]);
      return;
    }
    await OpenCodeServe.http("POST", `session/${encodeURIComponent(this.sessionId)}/abort`, {}, this.directory, 10_000).catch(() => undefined);
    // 前景の task は abort で子ごと止まり、動いている background の子も止まる（CLI の仕様。行は子の終わりの知らせで閉じる）。
    // 後から届く task の part は、閉じた行を実行中に戻さない。
    this.deliver(this.translator.abandon("stopped", true));
    // abort は保留中の承認・質問をサーバーに残す（実測 e9b2）。アプリのカードは閉じたので、サーバー側でも断る。
    await this.rejectPendingRequests((sid) => sid === this.sessionId || OpenCodeServe.isDescendant(sid, this.sessionId));
  }

  /// 背景の作業（task の子）を 1 つ止める（stop_task_request）。親のターンには触らない。
  /// 同じ行への停止がもう出ていれば、その結果を待つ。
  async stopTask(req: StopTaskRequest): Promise<StopTaskOutcome> {
    if (req.taskId !== SubagentTracker.taskId) return { kind: "unsupported" };
    if (!req.rowId || req.epoch !== this.translator.epoch) return { kind: "stale" };
    const rowId = req.rowId;
    const running = this.stopRuns.get(rowId);
    if (running) return running;
    const run = this.stopRow(rowId);
    this.stopRuns.set(rowId, run);
    try {
      return await run;
    } finally {
      if (this.stopRuns.get(rowId) === run) this.stopRuns.delete(rowId);
    }
  }

  private async stopRow(rowId: string): Promise<StopTaskOutcome> {
    const begin = this.translator.beginStop(rowId);
    if (begin.kind === "notRunning") return this.translator.hasRow(rowId) ? { kind: "notRunning" } : { kind: "stale" };
    if (begin.kind === "inFlight") return this.stopRuns.get(rowId) ?? { kind: "notRunning" };
    if (begin.kind !== "ok") return { kind: "unsupported" };
    this.deliver(begin.events);
    const child = begin.child;
    try {
      await OpenCodeServe.http("POST", `session/${encodeURIComponent(child)}/abort`, {}, this.directory, serveStopTiming.abortMs);
    } catch (error) {
      this.deliver(this.translator.endStop(rowId));
      const message = error instanceof Error ? error.message : String(error);
      return message.startsWith("timed out") ? { kind: "timeout" } : { kind: "failed", message: message.slice(0, 200) };
    }
    // 子と子孫の保留中の承認・質問を断る（TUI の表示も消える）。行が閉じるのを待つのと並べて走らせ、15 秒の上限を越えないようにする。
    const rejecting = this.rejectPendingRequests((sid) => sid === child || OpenCodeServe.isDescendant(sid, child), serveStopTiming.rejectMs);
    // 行が閉じるのは今の処理（task の part の error、子の session.error と idle）。自分では閉じない。
    const deadline = Date.now() + serveStopTiming.closeMs;
    while (this.translator.isRowRunning(rowId) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
    void rejecting;
    if (this.translator.isRowRunning(rowId)) {
      this.deliver(this.translator.endStop(rowId));
      return { kind: "failed" };
    }
    // 先に終わった行（done / failed）は stopped と言わない。
    return { kind: this.translator.rowState(rowId) === "stopped" ? "stopped" : "notRunning" };
  }

  /** 保留中の承認（POST /permission/<id>/reply reject）と質問（POST /question/<id>/reject）のうち、match のセッションのものを断る。 */
  private async rejectPendingRequests(match: (sessionId: string) => boolean, timeoutMs = 10_000): Promise<void> {
    const reject = async (kind: "permission" | "question"): Promise<void> => {
      const pending = await OpenCodeServe.http("GET", kind, undefined, this.directory, timeoutMs).catch(() => undefined);
      const items = Array.isArray(pending) ? pending.map(obj) : [];
      await Promise.all(
        items.map(async (item) => {
          const id = str(item.id);
          const sid = str(item.sessionID);
          if (!id || !sid || !match(sid)) return;
          const route = kind === "permission" ? `permission/${encodeURIComponent(id)}/reply` : `question/${encodeURIComponent(id)}/reject`;
          await OpenCodeServe.http("POST", route, kind === "permission" ? { reply: "reject" } : {}, this.directory, timeoutMs).catch(() => undefined);
        })
      );
    };
    await Promise.all([reject("permission"), reject("question")]);
  }

  async close(): Promise<void> {
    // 閉じた後は終わりの知らせを受けられないので、実行中の行を stopped で閉じる（裏で動く子も。serve は共有なので子は止めない）。
    this.deliver(this.translator.abandon("stopped", false));
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.turnDone?.();
  }

  /**
   * サブエージェントのカードの全行（workflow_snapshot。行が無くても agents: []）。接続したときと turn_status_request の
   * ときに server が送る（ターンの後も動いている task を、後から開いた画面に出す）。
   */
  subagentSnapshot(): string | undefined {
    return this.translator.snapshot();
  }

  private ensureSubscribed(): void {
    if (this.unsubscribe) return;
    this.unsubscribe = OpenCodeServe.subscribe(this.sessionId, (type, props, child) => {
      if (type === SERVE_EXITED) this.serverExited();
      else this.deliver(child ? this.translator.feedChild(child.childSessionId, child.originSessionId, type, props) : this.translator.feed(type, props));
    });
  }

  /**
   * serve が終了した。子セッションも一緒に止まり、終わりの知らせはもう来ないので、実行中の行を failed で閉じる。
   * 自分の送信のターンは POST の失敗で閉じるが、ほかの画面の発言で開いたターンは閉じる手段が無くなるので、ここで閉じる。
   */
  private serverExited(): void {
    this.deliver([...this.translator.abandon("failed", false), ...(this.turnDone ? [] : this.translator.finish())]);
  }

  private deliver(events: SessionEvent[]): void {
    for (const e of events) {
      this.emit?.(e);
      if (e.type === "done") this.turnDone?.();
    }
  }
}
