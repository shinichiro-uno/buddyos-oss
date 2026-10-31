import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { HistoryMessage } from "../protocol.js";
import type { ImageAttachment } from "./types.js";

/**
 * 送られた画像を Bridge の手元に保管し、履歴を開いたときに実画像へ戻すためのサイドカー（mac の AttachmentStore と同じ）。
 * Claude Code / Codex 等の履歴には `[image "<name>" attached: <mime>, <N> bytes]` の目印しか残らないので、
 * 送信時にバイトをここへ置き、load_history で目印と突き合わせて attachments に戻す。
 * key = `<name>|<byteCount>|<mime>`（目印に全部入っているので、sessionId の確定を待たずに引ける）。
 */

/** 保持する最大ファイル数（古い順に消す）。 */
const MAX_FILES = 500;

// 末尾の「(file: …)」は、画像をファイルで渡す CLI 向けに足したパス。一緒に消す（mac と同じ）。
const PLACEHOLDER = /\[image "([^"]+)" attached: ([^,]+), (\d+) bytes\](?: \(file: [^)\n]*\))?/g;

export interface HistoryAttachment {
  kind: string;
  name: string;
  mime: string;
  b64: string;
}

/** 実画像を持った履歴（Claude の transcript は画像ブロックがそのまま残っている）。 */
export type HistoryMessageWithImages = HistoryMessage & { attachments?: HistoryAttachment[] };

export function attachmentsDir(): string {
  return path.join(os.homedir(), ".buddyos", "attachments");
}

/** exportImageFile の置き場所。agy はワークスペースの外を読めないので、ここを --add-dir で渡す。 */
export function attachmentExportDir(): string {
  return path.join(attachmentsDir(), "files");
}

function hashKey(name: string, byteCount: number, mime: string): string {
  return crypto.createHash("sha256").update(`${name}|${byteCount}|${mime}`).digest("hex");
}

/** 画像を保管する（既にあれば更新日時だけ進めて、消される順を後ろへ回す）。失敗はログだけ。 */
export function putImage(image: ImageAttachment): void {
  const data = Buffer.from(image.b64, "base64");
  const dir = attachmentsDir();
  writeOrTouch(dir, path.join(dir, `${hashKey(image.name, data.byteLength, image.mime)}.img`), data);
}

/** 画像をファイルでしか渡せない CLI（cursor / grok / agy）向けに、拡張子つきで書き出してパスを返す。 */
export function exportImageFile(image: ImageAttachment): string | undefined {
  const data = Buffer.from(image.b64, "base64");
  const dir = attachmentExportDir();
  const file = path.join(dir, `${hashKey(image.name, data.byteLength, image.mime).slice(0, 24)}.${fileExtension(image.mime, image.name)}`);
  return writeOrTouch(dir, file, data) ? file : undefined;
}

/** 目印の (name, byteCount, mime) から保管済みのバイトを引く。 */
export function lookupImage(name: string, byteCount: number, mime: string): Buffer | undefined {
  try {
    return fs.readFileSync(path.join(attachmentsDir(), `${hashKey(name, byteCount, mime)}.img`));
  } catch {
    return undefined;
  }
}

/**
 * 履歴の本文の画像の目印を、保管済みの実画像に戻す。戻せた目印は本文から消す。
 * 戻せる画像が無ければ attachments は空で、本文もそのまま返す。
 */
export function restoreHistoryImages(message: HistoryMessage): { content: string; attachments: HistoryAttachment[] } {
  if (!message.content.includes("[image \"")) return { content: message.content, attachments: [] };
  const attachments: HistoryAttachment[] = [];
  for (const match of message.content.matchAll(PLACEHOLDER)) {
    const [, name, rawMime, size] = match;
    const mime = rawMime.trim();
    const data = lookupImage(name, Number.parseInt(size, 10), mime);
    if (data) attachments.push({ kind: "image", name, mime, b64: data.toString("base64") });
  }
  if (attachments.length === 0) return { content: message.content, attachments };
  return { content: message.content.replace(PLACEHOLDER, "").trim(), attachments };
}

/** history_message の metadata に載せる形（mac の SessionEvent.historyMessage と同じ attachment_<i>_*）。 */
export function historyAttachmentMetadata(attachments: HistoryAttachment[]): Record<string, string> {
  const meta: Record<string, string> = {};
  if (attachments.length === 0) return meta;
  meta.attachment_count = String(attachments.length);
  attachments.forEach((a, i) => {
    meta[`attachment_${i}_kind`] = a.kind;
    meta[`attachment_${i}_name`] = a.name;
    meta[`attachment_${i}_mime`] = a.mime;
    meta[`attachment_${i}_b64`] = a.b64;
  });
  return meta;
}

export function fileExtension(mime: string, name: string): string {
  switch (mime.toLowerCase()) {
    case "image/png":
      return "png";
    case "image/jpeg":
    case "image/jpg":
      return "jpg";
    case "image/gif":
      return "gif";
    case "image/webp":
      return "webp";
    case "image/heic":
      return "heic";
    default: {
      const ext = path.extname(name).slice(1).toLowerCase();
      return /^[a-z0-9]{1,8}$/.test(ext) ? ext : "bin";
    }
  }
}

function writeOrTouch(dir: string, file: string, data: Buffer): boolean {
  try {
    fs.mkdirSync(dir, { recursive: true });
    if (fs.existsSync(file)) {
      const now = new Date();
      fs.utimesSync(file, now, now);
    } else {
      fs.writeFileSync(file, data);
    }
    prune(dir);
    return true;
  } catch (error) {
    process.stderr.write(`[attachment-store] save failed: ${error instanceof Error ? error.message : String(error)}\n`);
    return false;
  }
}

/** 上限を超えた分を、更新日時の古い順に消す。 */
function prune(dir: string): void {
  let entries: Array<{ file: string; mtime: number }>;
  try {
    entries = fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isFile() && !e.name.startsWith("."))
      .map((e) => {
        const file = path.join(dir, e.name);
        return { file, mtime: fs.statSync(file).mtimeMs };
      });
  } catch {
    return;
  }
  if (entries.length <= MAX_FILES) return;
  entries.sort((a, b) => a.mtime - b.mtime);
  for (const { file } of entries.slice(0, entries.length - MAX_FILES)) {
    try {
      fs.rmSync(file, { force: true });
    } catch {
      /* 他で使用中 */
    }
  }
}
