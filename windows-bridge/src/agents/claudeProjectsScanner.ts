import fs from "node:fs";
import path from "node:path";
import type { HistoryMessage, SessionSummary } from "../protocol.js";
import { fileExtension, type HistoryAttachment, type HistoryMessageWithImages } from "./attachmentStore.js";

/// ~/.claude/projects/<dir>/<uuid>.jsonl（Claude Code の会話記録）を読み、ターミナルで始めた会話も
/// 一覧・履歴に出す（mac の ClaudeCodeProjectsScanner の移植）。フォルダ名は復号せず、cwd は記録の中から読む。

const MAX_SCAN_LINES = 5000;
const TITLE_TAIL_BYTES = 512 * 1024;
const MAX_IMAGE_B64 = 4 * 1024 * 1024;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const WRAPPERS = [
  "local-command-caveat",
  "local-command-stdout",
  "system-reminder",
  "command-name",
  "command-message",
  "command-args",
  "task-notification"
];

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);

export function stripWrappers(text: string): string {
  let out = text;
  for (const tag of WRAPPERS) out = out.replace(new RegExp(`<${tag}>[\\s\\S]*?</${tag}>`, "g"), "");
  return out.trim();
}

/** 他の Claude セッション（受け箱）から届いた発話の枠を外す。1 行目を落とし、最後の「This came from another Claude session」から後ろを落とす。 */
export function stripPeerFrame(text: string): string {
  const nl = text.indexOf("\n");
  const rest = nl < 0 ? "" : text.slice(nl + 1);
  const cut = rest.lastIndexOf("\n\nThis came from another Claude session");
  return cut >= 0 ? rest.slice(0, cut) : rest;
}

/** タイトル候補（`/コマンド` ならその名前、そうでなければ包みを除いた本文）。 */
export function titleCandidate(text: string): string | undefined {
  const command = /<command-name>([\s\S]*?)<\/command-name>/.exec(text)?.[1]?.trim();
  if (command) return command;
  const stripped = stripWrappers(text);
  return stripped || undefined;
}

function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    const b = obj(block);
    if ((b.type === "text" || b.type === "thinking") && typeof (b.text ?? b.thinking) === "string") parts.push(String(b.text ?? b.thinking));
    else if (b.type === "tool_use") parts.push(`[tool_use: ${str(b.name) ?? "tool"}]`);
    else if (b.type === "tool_result") parts.push(extractText(b.content));
  }
  return parts.join("\n");
}

/** 履歴に出す本文（文字列か text ブロックだけ。包みと [Image #n] を除く）。 */
function conversationText(content: unknown): string {
  if (typeof content === "string") return stripWrappers(content);
  if (!Array.isArray(content)) return "";
  return content
    .map((b) => obj(b))
    .filter((b) => b.type === "text" && typeof b.text === "string")
    .map((b) => stripWrappers(String(b.text)).replace(/\[Image #\d+\]/g, "").trim())
    .filter(Boolean)
    .join("\n");
}

export function previewText(text: string): string {
  const collapsed = text.replace(/\s+/g, " ").trim();
  if (!collapsed) return "(no messages)";
  return collapsed.length > 80 ? `${collapsed.slice(0, 77)}...` : collapsed;
}

/** 大文字小文字・区切り・末尾の区切りを揃えて比べる（Windows の C:\\x と c:/x/ を同じとみなす）。 */
export function normalizeCwd(p: string): string {
  const t = p.trim();
  if (/^[A-Za-z]:[\\/]/.test(t) || t.startsWith("\\\\")) {
    return path.win32.normalize(t).replace(/[\\/]+$/, "").toLowerCase();
  }
  const n = path.posix.normalize(t);
  return n.length > 1 ? n.replace(/\/+$/, "") : n;
}

/// 行は生のバイト列のまま改行（0x0a）で切ってから 1 行ずつ decode する（chunk の境目で多バイト文字が壊れず、バイト数も狂わない）。
/// fn の第 2 引数は、その行が占めるバイト数（改行の分を含む）。
function forEachLine(file: string, maxLines: number, fn: (line: string, bytes: number) => boolean | void): void {
  const fd = fs.openSync(file, "r");
  try {
    const buf = Buffer.alloc(1024 * 1024);
    let rest: Buffer = Buffer.alloc(0);
    let pos = 0;
    let count = 0;
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, pos);
      if (n <= 0) break;
      pos += n;
      const chunk = rest.length > 0 ? Buffer.concat([rest, buf.subarray(0, n)]) : Buffer.from(buf.subarray(0, n));
      let start = 0;
      for (;;) {
        const nl = chunk.indexOf(0x0a, start);
        if (nl < 0) break;
        const line = chunk.toString("utf8", start, nl);
        const bytes = nl - start + 1;
        start = nl + 1;
        if (++count > maxLines || fn(line, bytes) === true) return;
      }
      rest = chunk.subarray(start);
    }
    if (rest.length > 0 && count < maxLines) fn(rest.toString("utf8"), rest.length + 1);
  } finally {
    fs.closeSync(fd);
  }
}

/** 読んだバイト数の数え方（行ごとに改行の分を足す）から、実際に読み終えた位置を出す。最後の行に改行が無ければ、その行は含めない。 */
function readEnd(file: string, consumed: number, lastBytes: number): number {
  if (consumed === 0) return 0;
  try {
    const fd = fs.openSync(file, "r");
    try {
      const b = Buffer.alloc(1);
      const n = fs.readSync(fd, b, 0, 1, consumed - 1);
      return n === 1 && b[0] === 0x0a ? consumed : consumed - lastBytes;
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return consumed - lastBytes;
  }
}

function readTail(file: string, size: number, bytes: number): string {
  const len = Math.min(size, bytes);
  const fd = fs.openSync(file, "r");
  try {
    const buf = Buffer.alloc(len);
    const n = fs.readSync(fd, buf, 0, len, size - len);
    let text = buf.toString("utf8", 0, n);
    if (size > len) text = text.slice(text.indexOf("\n") + 1);
    return text;
  } finally {
    fs.closeSync(fd);
  }
}

interface Parsed {
  summary: SessionSummary;
  cwd?: string;
}

export class ClaudeProjectsScanner {
  private readonly cache = new Map<string, { mtimeMs: number; size: number; parsed: Parsed | null }>();

  constructor(private readonly projectsDir: () => Promise<string | undefined>) {}

  async listSessions(limit: number, cwd?: string): Promise<SessionSummary[]> {
    const root = await this.projectsDir();
    if (!root) return [];
    const files: Array<{ file: string; mtimeMs: number; size: number }> = [];
    let dirs: fs.Dirent[];
    try {
      dirs = fs.readdirSync(root, { withFileTypes: true });
    } catch {
      return [];
    }
    for (const d of dirs) {
      if (!d.isDirectory()) continue;
      const dir = path.join(root, d.name);
      let names: string[];
      try {
        names = fs.readdirSync(dir);
      } catch {
        continue;
      }
      for (const name of names) {
        if (!name.endsWith(".jsonl")) continue;
        const file = path.join(dir, name);
        try {
          const st = fs.statSync(file);
          if (st.isFile()) files.push({ file, mtimeMs: st.mtimeMs, size: st.size });
        } catch {
          /* 消えた */
        }
      }
    }
    files.sort((a, b) => b.mtimeMs - a.mtimeMs);
    const want = cwd ? normalizeCwd(cwd) : undefined;
    const out: SessionSummary[] = [];
    const max = Math.max(1, limit);
    for (const f of files) {
      if (out.length >= max) break;
      const parsed = this.parse(f.file, f.mtimeMs, f.size);
      if (!parsed) continue;
      if (want !== undefined && (!parsed.cwd || normalizeCwd(parsed.cwd) !== want)) continue;
      out.push(parsed.summary);
    }
    return out;
  }

  async loadHistory(sessionId: string): Promise<HistoryMessage[]> {
    return (await this.loadHistoryRead(sessionId)).messages;
  }

  /** 履歴と、読み終えた位置（最後の改行まで）。claude --bg の会話は、ここから後ろを transcript の追いかけで流す。 */
  async loadHistoryRead(sessionId: string): Promise<{ messages: HistoryMessage[]; file?: string; end?: number }> {
    if (!UUID.test(sessionId)) return { messages: [] };
    const file = await this.findFile(sessionId);
    if (!file) return { messages: [] };
    const out: HistoryMessage[] = [];
    let consumed = 0;
    let lastBytes = 0;
    forEachLine(file, Number.MAX_SAFE_INTEGER, (line, bytes) => {
      lastBytes = bytes;
      consumed += lastBytes;
      if (!line.trim()) return;
      let o: Record<string, unknown>;
      try {
        o = obj(JSON.parse(line));
      } catch {
        return;
      }
      if (o.type !== "user" && o.type !== "assistant") return;
      if (o.isMeta === true || o.isCompactSummary === true || o.isVisibleInTranscriptOnly === true) return;
      const message = obj(o.message);
      let content = conversationText(message.content);
      if (o.type === "user" && obj(o.origin).kind === "peer") content = stripPeerFrame(content);
      // ユーザーが貼った写真（スマホから送った画像を含む）は image ブロックで残っている。実画像として返す（mac と同じ）。
      const images = o.type === "user" ? imageBlocks(message.content) : [];
      if (!content && images.length === 0) return;
      const item: HistoryMessageWithImages = {
        role: str(message.role) ?? String(o.type),
        content: content || "[image]",
        messageId: str(o.uuid) ?? cryptoId()
      };
      if (images.length > 0) item.attachments = images;
      const ts = str(o.timestamp);
      if (ts) item.createdAt = ts;
      out.push(item);
    });
    return { messages: out, file, end: readEnd(file, consumed, lastBytes) };
  }

  private async findFile(sessionId: string): Promise<string | undefined> {
    const root = await this.projectsDir();
    if (!root) return undefined;
    let dirs: string[];
    try {
      dirs = fs.readdirSync(root);
    } catch {
      return undefined;
    }
    for (const d of dirs) {
      const file = path.join(root, d, `${sessionId}.jsonl`);
      if (fs.existsSync(file)) return file;
    }
    return undefined;
  }

  private parse(file: string, mtimeMs: number, size: number): Parsed | null {
    const hit = this.cache.get(file);
    if (hit && hit.mtimeMs === mtimeMs && hit.size === size) return hit.parsed;
    const parsed = this.parseUncached(file, mtimeMs, size);
    this.cache.set(file, { mtimeMs, size, parsed });
    return parsed;
  }

  private parseUncached(file: string, mtimeMs: number, size: number): Parsed | null {
    const sessionId = path.basename(file, ".jsonl");
    if (!UUID.test(sessionId)) return null;
    let cwd: string | undefined;
    let firstUser: string | undefined;
    try {
      forEachLine(file, MAX_SCAN_LINES, (line) => {
        if (!line.trim()) return;
        let o: Record<string, unknown>;
        try {
          o = obj(JSON.parse(line));
        } catch {
          return;
        }
        if (!cwd && str(o.cwd)) cwd = str(o.cwd);
        if (!firstUser && o.type === "user") firstUser = titleCandidate(extractText(obj(o.message).content));
        return Boolean(cwd && firstUser);
      });
    } catch {
      return null;
    }
    let custom: string | undefined;
    let ai: string | undefined;
    try {
      for (const line of readTail(file, size, TITLE_TAIL_BYTES).split("\n")) {
        if (line.startsWith('{"type":"custom-title"')) custom = str(obj(safeJson(line)).customTitle) ?? custom;
        else if (line.startsWith('{"type":"ai-title"')) ai = str(obj(safeJson(line)).aiTitle) ?? ai;
      }
    } catch {
      /* タイトル無し */
    }
    const summary: SessionSummary = {
      sessionId,
      title: previewText(custom ?? ai ?? firstUser ?? ""),
      lastActive: new Date(mtimeMs).toISOString()
    };
    if (cwd) summary.cwd = cwd;
    return { summary, cwd };
  }
}

function safeJson(line: string): unknown {
  try {
    return JSON.parse(line);
  } catch {
    return undefined;
  }
}

/** user メッセージの image ブロック（base64）を添付にする。大きすぎるものは送らない。 */
function imageBlocks(content: unknown): HistoryAttachment[] {
  if (!Array.isArray(content)) return [];
  const out: HistoryAttachment[] = [];
  for (const b of content) {
    const o = obj(b);
    const src = obj(o.source);
    if (o.type !== "image" || src.type !== "base64" || typeof src.data !== "string" || src.data.length > MAX_IMAGE_B64) continue;
    const mime = str(src.media_type) ?? "image/png";
    out.push({ kind: "image", name: `image-${out.length + 1}.${fileExtension(mime, "")}`, mime, b64: src.data });
  }
  return out;
}

function cryptoId(): string {
  return globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2);
}
