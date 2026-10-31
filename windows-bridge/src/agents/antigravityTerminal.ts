import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { HistoryMessage } from "../protocol.js";

/**
 * ターミナルで開いている Antigravity（agy）の会話を iPhone から見る・送る（mac の AntigravityTerminal /
 * AntigravityPresence / AntigravitySummaries / AntigravityTranscript の移植）。native の agy だけが対象。
 */

const agyRoot = (): string => path.join(os.homedir(), ".gemini", "antigravity-cli");
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const isAgyConversationId = (id: string): boolean => UUID_RE.test(id);

/**
 * iPhone からターミナルの agy の会話へ送る「受け取り箱」。
 * デスクトップのターミナル連携が ~/.gemini/config/hooks.json に入れる PreInvocation hook（buddy-agy-inbox.mjs）が、
 * agy がモデルを呼ぶ直前に `<会話ID>.json` を読んで会話に差し込む。中身は hook の出力そのもの（{"injectSteps":[…]}）。
 */
const inboxDir = (): string => path.join(os.homedir(), ".buddyos", "agy-inbox");
const agyHooksPath = (): string => path.join(os.homedir(), ".gemini", "config", "hooks.json");
const inboxScriptPath = (): string => path.join(os.homedir(), ".buddyos", "bin", "buddy-agy-inbox.mjs");

export const AgyInbox = {
  directory: inboxDir,
  hooksPath: agyHooksPath,
  scriptPath: inboxScriptPath,

  /** ターミナル連携で hook を入れてあるか。 */
  isInstalled(hooksPath = agyHooksPath(), scriptPath = inboxScriptPath()): boolean {
    try {
      if (!fs.existsSync(scriptPath)) return false;
      const obj = JSON.parse(fs.readFileSync(hooksPath, "utf8")) as Record<string, unknown>;
      return obj["buddyos-inbox"] !== undefined;
    } catch {
      return false;
    }
  },

  /** 送る文を箱に足す（hook がまだ読んでいない分があれば、その後ろに並べる）。 */
  enqueue(conversationId: string, text: string, directory = inboxDir()): void {
    if (!isAgyConversationId(conversationId)) return;
    fs.mkdirSync(directory, { recursive: true });
    const file = path.join(directory, `${conversationId}.json`);
    let steps: unknown[] = [];
    try {
      const existing = (JSON.parse(fs.readFileSync(file, "utf8")) as { injectSteps?: unknown }).injectSteps;
      if (Array.isArray(existing)) steps = existing;
    } catch {
      // 無い・読めない
    }
    steps.push({ userMessage: text });
    // 一時ファイルに書いて置き換える（hook が書きかけを読まないように）。
    const tmp = `${file}.tmp-${crypto.randomUUID().slice(0, 8)}`;
    fs.writeFileSync(tmp, JSON.stringify({ injectSteps: steps }), "utf8");
    fs.renameSync(tmp, file);
  }
};

/**
 * ターミナルで開かれている agy の会話。agy は TUI を開いている間 `presence/<会話ID>.lock` をロックする。
 * mac は flock を試すが Windows には無いので、読み取りで開いて 1 バイト読み、ロック違反（EBUSY）なら開いているとみなす。
 * 読み取りで開くだけでファイルは変更しない。
 */
const presenceDir = (): string => path.join(agyRoot(), "presence");

export const AntigravityPresence = {
  directory: presenceDir,

  liveConversationIds(directory = presenceDir(), held: (file: string) => boolean = lockHeld): Set<string> {
    const live = new Set<string>();
    let names: string[] = [];
    try {
      names = fs.readdirSync(directory);
    } catch {
      return live;
    }
    for (const name of names) {
      if (!name.endsWith(".lock")) continue;
      if (held(path.join(directory, name))) live.add(name.slice(0, -5));
    }
    return live;
  }
};

const LOCK_ERRORS = new Set(["EBUSY", "ELOCKED", "EACCES", "EPERM"]);

/** 他のプロセスがロックを持っているか（Windows: 読み取りがロック違反になる。それ以外: 判定できないので false）。 */
export function lockHeld(file: string): boolean {
  let fd: number;
  try {
    fd = fs.openSync(file, "r");
  } catch (error) {
    // 共有なしで開かれている（ERROR_SHARING_VIOLATION → EBUSY）。
    return (error as NodeJS.ErrnoException).code === "EBUSY";
  }
  try {
    fs.readSync(fd, Buffer.alloc(1), 0, 1, 0);
    return false;
  } catch (error) {
    return LOCK_ERRORS.has((error as NodeJS.ErrnoException).code ?? "");
  } finally {
    fs.closeSync(fd);
  }
}

/** agy が自動で付ける会話名（conversation_summaries.db）。node:sqlite が無い Node では空。 */
export interface AgySummary {
  title: string;
  preview: string;
  cwd?: string;
}

export async function readAgySummaries(file = path.join(agyRoot(), "conversation_summaries.db")): Promise<Map<string, AgySummary>> {
  const out = new Map<string, AgySummary>();
  if (!fs.existsSync(file)) return out;
  try {
    // 型定義の無い Node でも読めるよう、名前は変数で渡す（Node 22.13 以降は旗なしで使える）。
    const spec = "node:sqlite";
    const mod = (await import(spec)) as { DatabaseSync: new (p: string, o?: Record<string, unknown>) => SqliteDb };
    const db = new mod.DatabaseSync(file, { readOnly: true });
    try {
      const rows = db.prepare("SELECT conversation_id, title, preview, workspace_uris FROM conversation_summaries").all();
      for (const row of rows) {
        const id = String(row.conversation_id ?? "");
        if (!id) continue;
        out.set(id, {
          title: String(row.title ?? "").trim(),
          preview: String(row.preview ?? "").trim(),
          cwd: firstWorkspace(String(row.workspace_uris ?? ""))
        });
      }
    } finally {
      db.close();
    }
  } catch {
    // 読めなければ名前なし（BuddyOS の履歴の名前を使う）
  }
  return out;
}

interface SqliteDb {
  prepare(sql: string): { all(): Array<Record<string, unknown>> };
  close(): void;
}

/** `["file:///c%3A/a/b"]` の最初の要素をパスにする。 */
export function firstWorkspace(json: string): string | undefined {
  try {
    const arr = JSON.parse(json) as unknown;
    if (!Array.isArray(arr) || typeof arr[0] !== "string" || !arr[0].startsWith("file:")) return undefined;
    const p = fileURLToPath(arr[0]);
    return p && p !== "/" && p !== "\\" ? p : undefined;
  } catch {
    return undefined;
  }
}

/**
 * agy 自身が残す会話の記録（transcript.jsonl。1 行 = 1 段階）。ターミナルで始めた・続けた会話は
 * BuddyOS の履歴に無いので、開いたときにここから本文を読む。
 */
export const AntigravityTranscript = {
  path(conversationId: string, root = agyRoot()): string {
    return path.join(root, "brain", conversationId, ".system_generated", "logs", "transcript.jsonl");
  },

  read(conversationId: string, root = agyRoot()): HistoryMessage[] {
    // 会話 ID はパスに使うので、UUID の形以外は読まない。
    if (!isAgyConversationId(conversationId)) return [];
    try {
      return AntigravityTranscript.parse(fs.readFileSync(AntigravityTranscript.path(conversationId, root), "utf8"), conversationId);
    } catch {
      return [];
    }
  },

  /** 同じ返事の中で続く本文（道具を挟んだ前後）は 1 つの吹き出しにまとめる。 */
  parse(text: string, conversationId: string): HistoryMessage[] {
    const out: HistoryMessage[] = [];
    let pending: string[] = [];
    const flush = (): void => {
      if (pending.length === 0) return;
      out.push({ role: "assistant", content: pending.join("\n\n"), messageId: `${conversationId}-${out.length}` });
      pending = [];
    };
    for (const line of text.split(/\r?\n/)) {
      const obj = parseObject(line);
      const content = typeof obj?.content === "string" ? obj.content.trim() : "";
      if (!obj || !content) continue;
      if (obj.type === "USER_INPUT") {
        flush();
        out.push({ role: "user", content: userRequest(content), messageId: `${conversationId}-${out.length}` });
      } else if (obj.type === "PLANNER_RESPONSE") {
        pending.push(content);
      }
    }
    flush();
    return out;
  }
};

/** `<USER_REQUEST>` の中身。タグが無ければ全体。 */
export function userRequest(content: string): string {
  const m = /<USER_REQUEST>([\s\S]*?)<\/USER_REQUEST>/.exec(content);
  return m ? m[1].trim() : content;
}

function parseObject(line: string): Record<string, unknown> | undefined {
  if (!line.trim()) return undefined;
  try {
    const v = JSON.parse(line) as unknown;
    return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

export type MirrorEvent =
  | { kind: "user"; text: string }
  | { kind: "assistant"; text: string }
  | { kind: "toolStart"; name: string }
  | { kind: "toolEnd" }
  /** 道具を呼ばない返事 = ターンの終わり。 */
  | { kind: "turnEnd" };

/** transcript の 1 行（1 段階）から流すものを取り出す。 */
export function mirrorEvents(line: string): MirrorEvent[] {
  const obj = parseObject(line);
  if (!obj) return [];
  const content = typeof obj.content === "string" ? obj.content.trim() : "";
  switch (obj.type) {
    case "USER_INPUT":
      return content ? [{ kind: "user", text: userRequest(content) }] : [];
    case "PLANNER_RESPONSE": {
      const out: MirrorEvent[] = content ? [{ kind: "assistant", text: content }] : [];
      const calls = Array.isArray(obj.tool_calls) ? obj.tool_calls : [];
      if (calls.length === 0) out.push({ kind: "turnEnd" });
      for (const c of calls) {
        const name = c && typeof c === "object" && typeof (c as { name?: unknown }).name === "string" ? (c as { name: string }).name : "tool";
        out.push({ kind: "toolStart", name });
      }
      return out;
    }
    case "GENERIC":
      return [{ kind: "toolEnd" }];
    default:
      return [];
  }
}

/**
 * ターミナルで開いている agy の会話を、記録（transcript.jsonl）を追いかけて流す。
 * agy は段階ごとに 1 行ずつ書き足すので、返事は文字ごとではなく段階ごとに届く。今ある分は流さない。
 */
export class AntigravityTerminalMirror {
  private offset = 0;
  private partial = Buffer.alloc(0);
  private timer?: NodeJS.Timeout;
  private readonly file: string;

  constructor(conversationId: string, private readonly onEvent: (e: MirrorEvent) => void, root = agyRoot()) {
    this.file = AntigravityTranscript.path(conversationId, root);
  }

  start(intervalMs = 1000): void {
    if (this.timer) return;
    try {
      this.offset = fs.statSync(this.file).size;
    } catch {
      this.offset = 0;
    }
    this.timer = setInterval(() => this.poll(), intervalMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  poll(): void {
    let fd: number;
    try {
      fd = fs.openSync(this.file, "r");
    } catch {
      return;
    }
    let chunk = Buffer.alloc(0);
    try {
      const size = fs.fstatSync(fd).size;
      // 記録が作り直された（短くなった）ら頭から読む。
      if (size < this.offset) this.offset = 0;
      if (size === this.offset) return;
      chunk = Buffer.alloc(size - this.offset);
      fs.readSync(fd, chunk, 0, chunk.length, this.offset);
      this.offset = size;
    } catch {
      return;
    } finally {
      fs.closeSync(fd);
    }
    // 行の途中（日本語の 1 文字の途中もあり得る）で切れた分はバイトのまま持ち越す。
    let buf = Buffer.concat([this.partial, chunk]);
    for (let nl = buf.indexOf(0x0a); nl >= 0; nl = buf.indexOf(0x0a)) {
      const line = buf.subarray(0, nl).toString("utf8");
      buf = buf.subarray(nl + 1);
      for (const e of mirrorEvents(line)) this.onEvent(e);
    }
    this.partial = Buffer.from(buf);
  }
}
