import type { AgentInfo, CommandInfo, HistoryMessage, ProviderCatalog, SessionEvent, SessionSummary } from "../protocol.js";

export type Emit = (event: SessionEvent) => void;

/** openSession の追加指定。cron の無人実行が使う（mac の SessionOptions と同じ）。 */
export interface SessionOptions {
  /** BuddyOS の権限モード（plan / edit / auto / dangerous）。指定があれば全体設定より優先する。 */
  permissionMode?: string;
  /** 誰も承認に答えない実行。承認の往復が必要な adapter は待たずに拒否する。 */
  unattended?: boolean;
  /**
   * メインの定期チェック（mainagent/heartbeat.ts）の会話の印。無人（unattended）でも、mainagent のフォルダなら
   * buddyos の道具（MCP）を渡す（cron の無人実行とはこの印で分ける）。
   */
  heartbeat?: boolean;
}

/**
 * チャット単位のモデル / Effort / 権限モード（mac の SessionOverrides と同じ）。
 * iOS / デスクトップが user_message の metadata（chatModel / chatProvider / chatEffort / chatMode）に毎回載せて送る。
 * 無い項目はエージェントの既定（setModel で保存した全体設定）に従う。上書きはそのチャットのプロセス・ターンにだけ効き、
 * 他のチャットや全体設定・CLI 本体の設定には書き込まない。
 */
export interface SessionOverrides {
  model?: string;
  provider?: string;
  reasoningEffort?: string;
  mode?: string;
}

/**
 * metadata から読む。`chatOverrides=1` の印が無い送信（古いアプリ等）は undefined を返し、セッションの上書きを触らない。
 * 印があって項目が無ければ全項目 undefined = 既定に戻す。
 */
export function parseChatOverrides(metadata: Record<string, string> | undefined): SessionOverrides | undefined {
  if (metadata?.chatOverrides !== "1") return undefined;
  const value = (key: string): string | undefined => {
    const v = metadata[key]?.trim();
    return v ? v : undefined;
  };
  return {
    model: value("chatModel"),
    provider: value("chatProvider"),
    reasoningEffort: value("chatEffort"),
    mode: value("chatMode")?.toLowerCase()
  };
}

/** stop_task_request の中身（行の停止は taskId = "subagents" で rowId と epoch 付き。dynamic workflow のカード全体は taskId だけ）。 */
export interface StopTaskRequest {
  taskId: string;
  rowId?: string;
  epoch?: string;
}

/** 行（カード）の停止の結果。reason への対応は protocol.ts の stopTaskResult。 */
export type StopTaskOutcome =
  | { kind: "stopped" }
  | { kind: "notRunning" }
  | { kind: "stale" }
  | { kind: "unsupported"; message?: string }
  | { kind: "failed"; message?: string }
  | { kind: "timeout" };

export interface AgentSession {
  sessionId: string;
  /**
   * このチャットだけのモデル / Effort / モードを受け取る（server が send / inject / warm の直前に呼ぶ）。反映は次のターン
   * （1 ターン = 1 プロセスなら次の起動）から。無い session は上書きに対応しない。
   */
  applyOverrides?(overrides: SessionOverrides): void;
  // true when this session can absorb a follow-up user message into the in-flight
  // turn (streaming-input agents). Absent/false => the caller queues it as a new turn.
  supportsMidTurnInjection?: boolean;
  // true when the session reads the voice-mode metadata (voice / voiceSpoken) itself.
  // Absent/false => the server appends a `<voice-context>` block to the text instead.
  handlesVoice?: boolean;
  send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void>;
  // Push a follow-up into the running turn. Returns false if no live turn exists,
  // so the caller can fall back to send() as a fresh turn.
  inject?(text: string, originalEvent: SessionEvent, emit: Emit): boolean;
  /** 登録済みで終わっていないターンがある（差し込んだ発話が CLI の待ち行列で、前のターンの done の後に走る場合など）。
   *  server はこの間 session を閉じない（閉じると発話ごとプロセスが止まり、返事もエラーも来ない）。 */
  readonly hasPendingTurn?: boolean;
  // Cancel the in-flight turn (streaming-input agents).
  interrupt?(): Promise<void>;
  // Start the CLI before the first message (session_warm). Only for sessions that keep one
  // process across turns (Claude Code keeps a resident stream-json process per chat).
  warm?(): Promise<void>;
  // 行（カード）ごとの停止（stop_task_request）。無い session は unsupported。
  stopTask?(req: StopTaskRequest): Promise<StopTaskOutcome>;
  respondToAction?(requestId: string, decision: string, answers: Record<string, string>): Promise<void>;
  // ターミナルで開いている会話を、iPhone から送る前から見る（ターミナル側のターンを emit に流す）。
  watch?(emit: Emit): Promise<void>;
  // バックグラウンドのサブエージェント / workflow の全行（workflow_snapshot の payload JSON）。無ければ undefined。
  subagentSnapshot?(): string | undefined | Promise<string | undefined>;
  /** 使い直してよいか（false なら server は閉じて取り直す。claude --bg の会話で、握っていたプロセスが消えたとき等）。 */
  isStillUsable?(): boolean;
  close(): Promise<void>;
}

export interface AgentAdapter {
  id: string;
  displayName: string;
  runtimeLabel: string;
  // true for adapters whose sessions support mid-turn follow-up injection +
  // interrupt (Claude Code / Codex app-server). Drives the advertised capabilities.
  supportsMidTurnInjection?: boolean;
  // true for adapters whose sessions implement interrupt() (kill the turn's CLI process /
  // ACP session/cancel) without mid-turn injection. Drives capabilities.interrupt.
  supportsInterrupt?: boolean;
  // true for adapters whose sessions implement warm(). Drives capabilities.warm (apps send
  // session_warm only when it is true).
  supportsWarm?: boolean;
  /** set_model_request の reasoningEffort で切り替えられる effort（capabilities.efforts）。無し = 切り替えられない。 */
  readonly efforts?: readonly string[];
  /** set_model_request の codexMode で切り替えられる権限モード（capabilities.modes。plan / edit / auto / dangerous / build）。 */
  readonly modes?: readonly string[];
  /** ターミナルで開いている会話を見る・送れるか（capabilities.terminal。Claude Code は server が別に持つ）。 */
  readonly terminal?: boolean;
  /** その会話がいまターミナルで開かれているか（開いた時点から watch で流す）。 */
  terminalSession?(sessionId: string): Promise<boolean>;
  openSession(sessionId: string | undefined, cwd: string | undefined, options?: SessionOptions): Promise<AgentSession>;
  listSessions(limit: number, cwd?: string): Promise<SessionSummary[]>;
  loadHistory(sessionId: string): Promise<HistoryMessage[]>;
  renameSession(sessionId: string, title: string): Promise<boolean>;
  listCommands(): Promise<CommandInfo[]>;
  currentInfo(): Promise<AgentInfo | undefined>;
  setModel(model: string, provider?: string, reasoningEffort?: string, codexMode?: string): Promise<void>;
  listAvailableModels(): Promise<ProviderCatalog[]>;
}

export abstract class BaseAdapter implements AgentAdapter {
  abstract id: string;
  abstract displayName: string;
  abstract runtimeLabel: string;
  abstract openSession(sessionId: string | undefined, cwd: string | undefined, options?: SessionOptions): Promise<AgentSession>;
  abstract listSessions(limit: number, cwd?: string): Promise<SessionSummary[]>;
  abstract loadHistory(sessionId: string): Promise<HistoryMessage[]>;
  abstract renameSession(sessionId: string, title: string): Promise<boolean>;

  async listCommands(): Promise<CommandInfo[]> {
    return [];
  }

  async currentInfo(): Promise<AgentInfo | undefined> {
    return { provider: this.id, runtime: this.runtimeLabel };
  }

  async setModel(_model: string, _provider?: string, _reasoningEffort?: string, _codexMode?: string): Promise<void> {
    throw new Error("set model not supported");
  }

  async listAvailableModels(): Promise<ProviderCatalog[]> {
    return [];
  }
}

/**
 * 本文の前に skill の行を付ける。typed: アプリ内ターミナルに打ち込む文（ClaudeTerminalRegistry.typePrompt）。skill の行を `/` で
 * 始めない（Claude Code は貼り付けた先頭の `/skill a,b` をコマンドとして読み、「Unknown command: /skill」になる。2.1.300 で実測）。
 * 受け箱・channel やほかのエージェントへ送る文は今までどおり `/skill a,b`。
 */
export function metadataText(originalEvent: SessionEvent, text: string, options: { typed?: boolean } = {}): string {
  const skills = (originalEvent.metadata?.skills ?? "")
    .split(",")
    .map((skill) => skill.trim())
    .filter(Boolean);
  if (skills.length === 0) return text;
  if (options.typed) return `Use these skills: ${skills.join(", ")}\n${text}`;
  return `/skill ${skills.join(",")}\n${text}`;
}

export function attachmentBlocks(originalEvent: SessionEvent): Array<Record<string, unknown>> {
  const metadata = originalEvent.metadata ?? {};
  const count = Number.parseInt(metadata.attachment_count ?? "0", 10);
  const blocks: Array<Record<string, unknown>> = [];
  for (let i = 0; i < count; i += 1) {
    const kind = metadata[`attachment_${i}_kind`];
    const mime = metadata[`attachment_${i}_mime`];
    const b64 = metadata[`attachment_${i}_b64`];
    if (kind === "image" && mime && b64) {
      blocks.push({ type: "image", data: b64, mimeType: mime });
    }
  }
  return blocks;
}

export interface ImageAttachment {
  name: string;
  mime: string;
  b64: string;
  byteLength: number;
}

/** 送られてきた画像の添付（metadata の attachment_<i>_*）。 */
export function imageAttachments(originalEvent: SessionEvent): ImageAttachment[] {
  const metadata = originalEvent.metadata ?? {};
  const count = Number.parseInt(metadata.attachment_count ?? "0", 10);
  const images: ImageAttachment[] = [];
  for (let i = 0; i < count; i += 1) {
    const b64 = metadata[`attachment_${i}_b64`];
    if (metadata[`attachment_${i}_kind`] !== "image" || !b64) continue;
    images.push({
      name: metadata[`attachment_${i}_name`] ?? `image-${i}`,
      mime: metadata[`attachment_${i}_mime`] ?? "image/png",
      b64,
      byteLength: Buffer.from(b64, "base64").byteLength
    });
  }
  return images;
}

/** 履歴に残す画像の目印。AttachmentStore と突き合わせて、履歴を開いたときに実画像へ戻す（mac と同じ書式）。 */
export function imagePlaceholder(image: ImageAttachment): string {
  return `[image "${image.name}" attached: ${image.mime}, ${image.byteLength} bytes]`;
}

export function attachmentTextNotes(originalEvent: SessionEvent): string[] {
  const metadata = originalEvent.metadata ?? {};
  const count = Number.parseInt(metadata.attachment_count ?? "0", 10);
  const notes: string[] = [];
  for (let i = 0; i < count; i += 1) {
    const kind = metadata[`attachment_${i}_kind`];
    const name = metadata[`attachment_${i}_name`] ?? `attachment-${i}`;
    const mime = metadata[`attachment_${i}_mime`] ?? "application/octet-stream";
    const b64 = metadata[`attachment_${i}_b64`];
    if (kind !== "file" || !b64) continue;
    const bytes = Buffer.from(b64, "base64");
    const decoded = bytes.toString("utf8");
    if (decoded.includes("\uFFFD")) {
      notes.push(`[file "${name}" attached: ${mime}, ${bytes.byteLength} bytes]`);
    } else {
      notes.push(`<file name="${name}" mime="${mime}">\n${decoded}\n</file>`);
    }
  }
  return notes;
}
