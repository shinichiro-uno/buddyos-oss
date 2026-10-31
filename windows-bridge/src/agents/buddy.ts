import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { event, type AgentInfo, type HistoryMessage, type ProviderCatalog, type SessionEvent, type SessionSummary } from "../protocol.js";
import { BaseAdapter, attachmentTextNotes, metadataText, type AgentSession, type Emit, type SessionOverrides } from "./types.js";
import { BuddyMcpClient, type BuddyTool } from "./buddyMcp.js";
import { resolveOpenRouterReferer } from "../settings.js";

/// Buddy: Bridge の中で動く汎用アシスタント（mac の BuddyAdapter / BuddySession の移植）。
/// OpenRouter の chat completions を直接呼び、MCP のツールは 1 回ずつ承認を取ってから実行する。
/// 会話は ~/.buddyos/buddy-sessions/<id>.json に残し、同じ id で開き直すと続きから話せる。

/** OpenRouter への要求のヘッダ。HTTP-Referer は設定があるときだけ（BUDDYOS_OPENROUTER_REFERER → 既定値。settings.ts）。 */
export function openRouterHeaders(key: string, env: NodeJS.ProcessEnv = process.env): Record<string, string> {
  const headers: Record<string, string> = { authorization: `Bearer ${key}`, "content-type": "application/json" };
  const referer = resolveOpenRouterReferer(env).value;
  if (referer) headers["HTTP-Referer"] = referer;
  headers["X-Title"] = "BuddyOS";
  return headers;
}

const DEFAULT_MODEL = "google/gemini-2.0-flash-001";
const MAX_TOOL_ROUNDS = 8;
const MAX_MESSAGES = 120;
const MAX_BYTES = 400_000;
const MAX_CONTENT = 16_000;
const SYSTEM_PROMPT =
  "あなたは BuddyOS の Buddy です。速く、簡潔に答えます。ユーザーと同じ言語で話してください。" +
  "道具（MCP ツール）が役立つときは使ってかまいません。実行の前にはユーザーの承認が入ります。";

const CATALOG: ProviderCatalog[] = [
  {
    id: "buddy",
    label: "Buddy (OpenRouter)",
    models: [
      { id: "google/gemini-2.0-flash-001", label: "Gemini 2.0 Flash", subtitle: "既定・高速" },
      { id: "google/gemini-flash-1.5", label: "Gemini 1.5 Flash" },
      { id: "anthropic/claude-3.5-haiku", label: "Claude 3.5 Haiku" },
      { id: "z-ai/glm-4.7", label: "GLM 4.7" }
    ]
  }
];

const buddyDir = (): string => path.join(os.homedir(), ".buddyos");
const configFile = (): string => path.join(buddyDir(), "buddy.json");
const sessionsDir = (): string => path.join(buddyDir(), "buddy-sessions");

export function buddyModel(): string {
  if (process.env.BUDDY_MODEL?.trim()) return process.env.BUDDY_MODEL.trim();
  try {
    const model = (JSON.parse(fs.readFileSync(configFile(), "utf8")) as { model?: unknown }).model;
    if (typeof model === "string" && model.trim()) return model.trim();
  } catch {
    /* 既定 */
  }
  return DEFAULT_MODEL;
}

/** OpenRouter のキー（環境変数か ~/.hermes/.env）。 */
export function openRouterKey(): string | undefined {
  if (process.env.OPENROUTER_API_KEY?.trim()) return process.env.OPENROUTER_API_KEY.trim();
  try {
    const env = fs.readFileSync(path.join(os.homedir(), ".hermes", ".env"), "utf8");
    const m = /^OPENROUTER_API_KEY=(.*)$/m.exec(env);
    const v = m?.[1].trim().replace(/^(["'])(.*)\1$/, "$2");
    return v || undefined;
  } catch {
    return undefined;
  }
}

type ChatMessage = Record<string, unknown> & { role: string };

/** 送れる形に整える（応答の揃っていない tool_calls・宙に浮いた tool を落とし、最初の user から始める）。 */
export function sanitizeHistory(messages: ChatMessage[]): ChatMessage[] {
  const out: ChatMessage[] = [];
  for (let i = 0; i < messages.length; i += 1) {
    const m = messages[i];
    if (m.role === "assistant" && Array.isArray(m.tool_calls) && m.tool_calls.length > 0) {
      const ids = (m.tool_calls as Array<Record<string, unknown>>).map((c) => c.id);
      const replies = messages.slice(i + 1, i + 1 + ids.length);
      if (replies.length === ids.length && replies.every((r, k) => r.role === "tool" && r.tool_call_id === ids[k])) {
        out.push(m, ...replies);
        i += ids.length;
      }
      continue;
    }
    if (m.role === "tool") continue;
    if (m.role === "user" || m.role === "assistant") out.push(m);
  }
  const first = out.findIndex((m) => m.role === "user");
  return first >= 0 ? out.slice(first) : [];
}

function trimHistory(messages: ChatMessage[]): ChatMessage[] {
  let out = messages.map((m) => (typeof m.content === "string" && m.content.length > MAX_CONTENT ? { ...m, content: m.content.slice(0, MAX_CONTENT) } : m));
  while (out.length > MAX_MESSAGES || Buffer.byteLength(JSON.stringify(out)) > MAX_BYTES) {
    const next = out.findIndex((m, i) => i > 0 && m.role === "user");
    if (next <= 0) break;
    out = out.slice(next);
  }
  return out;
}

class BuddyHistoryStore {
  private file(id: string): string {
    return path.join(sessionsDir(), `${id}.json`);
  }

  load(id: string): ChatMessage[] {
    try {
      const parsed = JSON.parse(fs.readFileSync(this.file(id), "utf8"));
      return Array.isArray(parsed) ? sanitizeHistory(parsed as ChatMessage[]) : [];
    } catch {
      return [];
    }
  }

  save(id: string, messages: ChatMessage[]): void {
    fs.mkdirSync(sessionsDir(), { recursive: true, mode: 0o700 });
    const file = this.file(id);
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(trimHistory(sanitizeHistory(messages))), { mode: 0o600 });
    fs.renameSync(tmp, file);
    this.prune();
  }

  private prune(): void {
    try {
      const files = fs
        .readdirSync(sessionsDir())
        .filter((n) => n.endsWith(".json"))
        .map((n) => ({ file: path.join(sessionsDir(), n), mtime: fs.statSync(path.join(sessionsDir(), n)).mtimeMs }))
        .sort((a, b) => b.mtime - a.mtime);
      const cutoff = Date.now() - 30 * 86_400_000;
      files.forEach((f, i) => {
        if (i >= 200 || f.mtime < cutoff) fs.rmSync(f.file, { force: true });
      });
    } catch {
      /* 次回 */
    }
  }
}

const mcp = new BuddyMcpClient();

/** Buddy が開いた MCP サーバー（子プロセス）を閉じる。 */
export function closeBuddyMcp(): void {
  mcp.closeAll();
}
const history = new BuddyHistoryStore();

export class BuddyAdapter extends BaseAdapter {
  readonly displayName = "Buddy";
  readonly runtimeLabel = "builtin:buddy";
  readonly supportsInterrupt = true;

  constructor(readonly id = "buddy") {
    super();
  }

  async openSession(sessionId: string | undefined, _cwd?: string): Promise<AgentSession> {
    const id = sessionId && /^[0-9a-f-]{36}$/i.test(sessionId) ? sessionId : crypto.randomUUID();
    return new BuddySession(this.id, id, sessionId === id ? history.load(id) : []);
  }

  async listSessions(): Promise<SessionSummary[]> {
    return [];
  }

  async loadHistory(): Promise<HistoryMessage[]> {
    return [];
  }

  async renameSession(): Promise<boolean> {
    return false;
  }

  async currentInfo(): Promise<AgentInfo | undefined> {
    return { model: buddyModel(), provider: "buddy", runtime: this.runtimeLabel };
  }

  async setModel(model: string): Promise<void> {
    if (!model.trim()) return;
    let root: Record<string, unknown> = {};
    try {
      root = JSON.parse(fs.readFileSync(configFile(), "utf8")) as Record<string, unknown>;
    } catch {
      /* 新規 */
    }
    root.model = model.trim();
    fs.mkdirSync(buddyDir(), { recursive: true });
    fs.writeFileSync(configFile(), JSON.stringify(root, null, 2));
  }

  async listAvailableModels(): Promise<ProviderCatalog[]> {
    return CATALOG;
  }
}

interface ToolCall {
  id: string;
  name: string;
  arguments: string;
}

// 名前から、コマンドの実行や書き込み・送信をしそうなツール（「このセッションでは承認」を出さない）。
const RISKY_TOOL_NAME = /(shell|exec|run|command|cmd|bash|powershell|pwsh|terminal|script|eval|write|edit|create|update|delete|remove|rm|move|rename|copy|put|post|patch|upload|install|kill|send|push|commit|apply|save)/i;

/**
 * 「このセッションでは承認」を出してよいツールか。読み取りだけと申告したもの（readOnlyHint）か、
 * 申告が無く名前からも実行・書き込みに見えないものに限る。シェルや書き込みは毎回確かめる。
 */
export function allowsSessionApproval(tool: BuddyTool): boolean {
  const a = tool.annotations;
  if (a?.readOnlyHint === true && a.destructiveHint !== true) return true;
  if (a && (a.destructiveHint === true || a.readOnlyHint === false)) return false;
  return !RISKY_TOOL_NAME.test(tool.name);
}

/** セッションの承認の鍵。ツール名だけでなく引数まで同じ呼び出しに限る（引数を変えた別の操作は改めて聞く）。 */
export function sessionApprovalKey(name: string, rawArguments: string): string {
  let canonical = rawArguments.trim();
  try {
    canonical = stableJson(JSON.parse(canonical || "{}"));
  } catch {
    /* 読めない引数はそのまま */
  }
  return `${name}\u0000${crypto.createHash("sha256").update(canonical).digest("hex")}`;
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    const o = value as Record<string, unknown>;
    return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${stableJson(o[k])}`).join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

/** 承認カードに出す引数の全文（読める JSON なら整形する。切り詰めない）。 */
export function approvalArgumentsText(rawArguments: string): string {
  try {
    return JSON.stringify(JSON.parse(rawArguments || "{}"), null, 2);
  } catch {
    return rawArguments;
  }
}

/** OpenRouter に渡すツール名（[A-Za-z0-9_-] で 60 文字まで）。 */
export function toolFunctionName(tool: BuddyTool): string {
  return `${tool.server}__${tool.name}`.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 60);
}

class BuddySession implements AgentSession {
  private emit?: Emit;
  private abort?: AbortController;
  private readonly allowedForSession = new Set<string>();
  private readonly pending = new Map<string, (decision: string) => void>();
  private chain: Promise<void> = Promise.resolve();
  private didStart = false;
  /** このチャットだけのモデル（OpenRouter のモデル id）。無ければ buddy.json の既定。 */
  private chatModel?: string;

  constructor(
    private readonly agentId: string,
    public sessionId: string,
    private messages: ChatMessage[]
  ) {}

  send(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    // ターンは 1 本ずつ（前のターンが終わってから次を始める）。
    const run = this.chain.then(() => this.turn(text, originalEvent, emit));
    this.chain = run.catch(() => {});
    return run;
  }

  applyOverrides(overrides: SessionOverrides): void {
    this.chatModel = overrides.model;
  }

  async interrupt(): Promise<void> {
    this.abort?.abort();
    for (const resolve of this.pending.values()) resolve("decline");
    this.pending.clear();
  }

  async respondToAction(requestId: string, decision: string): Promise<void> {
    const resolve = this.pending.get(requestId);
    if (!resolve) return;
    this.pending.delete(requestId);
    resolve(decision);
  }

  async close(): Promise<void> {
    await this.interrupt();
  }

  private async turn(text: string, originalEvent: SessionEvent, emit: Emit): Promise<void> {
    this.emit = emit;
    const messageId = crypto.randomUUID();
    if (!this.didStart) {
      this.didStart = true;
      emit(event.sessionStarted(this.agentId, this.sessionId));
    }
    const key = openRouterKey();
    if (!key) {
      emit(event.error(this.agentId, this.sessionId, "OpenRouter の API キーがありません。環境変数 OPENROUTER_API_KEY を設定してください。"));
      emit(event.done(this.agentId, this.sessionId, messageId));
      return;
    }
    const notes = attachmentTextNotes(originalEvent);
    const userText = metadataText(originalEvent, text);
    this.messages.push({ role: "user", content: notes.length > 0 ? `${notes.join("\n\n")}\n\n${userText}` : userText });
    const abort = new AbortController();
    this.abort = abort;
    const tools = await mcp.tools().catch(() => [] as BuddyTool[]);
    const byName = new Map(tools.map((t) => [toolFunctionName(t), t]));
    try {
      for (let round = 0; round < MAX_TOOL_ROUNDS; round += 1) {
        const { text: reply, calls } = await this.complete(key, tools, messageId, abort.signal);
        if (calls.length === 0) {
          this.messages.push({ role: "assistant", content: reply });
          break;
        }
        this.messages.push({
          role: "assistant",
          content: reply || null,
          tool_calls: calls.map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: c.arguments } }))
        });
        for (const call of calls) {
          const result = abort.signal.aborted ? "ユーザーが中断したため実行しませんでした。" : await this.runTool(call, byName.get(call.name));
          this.messages.push({ role: "tool", tool_call_id: call.id, content: result });
        }
        if (abort.signal.aborted) break;
      }
    } catch (error) {
      if (!abort.signal.aborted) emit(event.error(this.agentId, this.sessionId, error instanceof Error ? error.message : String(error)));
    } finally {
      this.abort = undefined;
      try {
        history.save(this.sessionId, this.messages);
      } catch {
        /* 次のターンで保存 */
      }
      emit(event.done(this.agentId, this.sessionId, messageId));
    }
  }

  private async complete(key: string, tools: BuddyTool[], messageId: string, signal: AbortSignal): Promise<{ text: string; calls: ToolCall[] }> {
    const body: Record<string, unknown> = {
      model: this.chatModel ?? buddyModel(),
      stream: true,
      messages: [{ role: "system", content: SYSTEM_PROMPT }, ...this.messages]
    };
    if (tools.length > 0) {
      body.tools = tools.map((t) => ({ type: "function", function: { name: toolFunctionName(t), description: t.description, parameters: t.inputSchema } }));
    }
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: openRouterHeaders(key),
      body: JSON.stringify(body),
      signal
    });
    if (!res.ok || !res.body) throw new Error(`OpenRouter HTTP ${res.status}: ${(await res.text().catch(() => "")).slice(0, 300)}`);
    let text = "";
    const calls: ToolCall[] = [];
    let buffer = "";
    const decoder = new TextDecoder();
    for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
      buffer += decoder.decode(chunk, { stream: true });
      for (;;) {
        const nl = buffer.indexOf("\n");
        if (nl < 0) break;
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line.startsWith("data:")) continue;
        const data = line.slice(5).trim();
        if (data === "[DONE]") return { text, calls };
        let parsed: Record<string, unknown>;
        try {
          parsed = JSON.parse(data) as Record<string, unknown>;
        } catch {
          continue;
        }
        const delta = ((parsed.choices as Array<Record<string, unknown>> | undefined)?.[0]?.delta ?? {}) as Record<string, unknown>;
        if (typeof delta.content === "string" && delta.content) {
          text += delta.content;
          this.emit?.(event.assistantDelta(this.agentId, this.sessionId, messageId, delta.content));
        }
        for (const tc of (delta.tool_calls as Array<Record<string, unknown>> | undefined) ?? []) {
          const index = typeof tc.index === "number" ? tc.index : 0;
          const fn = (tc.function ?? {}) as Record<string, unknown>;
          const cur = calls[index] ?? { id: "", name: "", arguments: "" };
          if (typeof tc.id === "string") cur.id = tc.id;
          if (typeof fn.name === "string") cur.name += fn.name;
          if (typeof fn.arguments === "string") cur.arguments += fn.arguments;
          calls[index] = cur;
        }
      }
    }
    return { text, calls: calls.filter(Boolean) };
  }

  private async runTool(call: ToolCall, tool: BuddyTool | undefined): Promise<string> {
    const emit = this.emit;
    const toolUseId = call.id || crypto.randomUUID();
    emit?.(event.toolStart(this.agentId, this.sessionId, toolUseId, call.name, call.name, "other"));
    if (!tool) {
      emit?.(event.toolEnd(this.agentId, this.sessionId, toolUseId, call.name, "failed", "unknown tool"));
      return `ツール ${call.name} は見つかりません。`;
    }
    const approvalKey = sessionApprovalKey(call.name, call.arguments);
    if (!this.allowedForSession.has(approvalKey)) {
      const sessionApproval = allowsSessionApproval(tool);
      const decision = await this.askApproval(call, tool, sessionApproval);
      if (decision === "acceptForSession" && sessionApproval) this.allowedForSession.add(approvalKey);
      else if (decision !== "accept" && decision !== "acceptForSession") {
        emit?.(event.toolEnd(this.agentId, this.sessionId, toolUseId, call.name, "failed", "拒否されました"));
        return "ユーザーがこの操作の実行を拒否しました。";
      }
    }
    let args: Record<string, unknown> = {};
    try {
      args = call.arguments ? (JSON.parse(call.arguments) as Record<string, unknown>) : {};
    } catch {
      /* 空の引数で呼ぶ */
    }
    try {
      const result = await mcp.call(tool, args);
      emit?.(event.toolEnd(this.agentId, this.sessionId, toolUseId, call.name, "completed", result.slice(0, 120)));
      return result;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      emit?.(event.toolEnd(this.agentId, this.sessionId, toolUseId, call.name, "failed", message.slice(0, 120)));
      return `ツールの実行に失敗しました: ${message}`;
    }
  }

  private askApproval(call: ToolCall, tool: BuddyTool, sessionApproval: boolean): Promise<string> {
    const requestId = crypto.randomUUID();
    const title = `ツール「${tool.name}」を実行しますか`;
    // 引数は切り詰めずに全文を出す（途中で切ると、後ろに足された危険な引数が見えないまま承認してしまう）。
    const args = approvalArgumentsText(call.arguments);
    const options: Array<[string, string, string]> = [["承認", "一度だけ許可", "accept"]];
    if (sessionApproval) options.push(["このセッションでは承認", "同じ内容の呼び出しを続けて許可", "acceptForSession"]);
    options.push(["非承認", "実行しない", "decline"]);
    const metadata: Record<string, string> = {
      requestId,
      kind: "toolApproval",
      title,
      option_count: String(options.length),
      allowsOther: "0"
    };
    options.forEach(([optionTitle, optionSubtitle, value], i) => {
      metadata[`option_${i}_title`] = optionTitle;
      metadata[`option_${i}_subtitle`] = optionSubtitle;
      metadata[`option_${i}_value`] = value;
    });
    // 画面は subtitle を出す。detail にも同じ全文を載せる（要約を出す画面でも、全文を確かめられるように）。
    if (args) {
      metadata.subtitle = args;
      metadata.detail = args;
    }
    // 返事が同期的に来ても取りこぼさないよう、待ち受けを先に登録してからカードを出す。
    const answered = new Promise<string>((resolve) => this.pending.set(requestId, resolve));
    this.emit?.({ type: "action_request", agentId: this.agentId, sessionId: this.sessionId, messageId: requestId, content: title, metadata });
    return answered;
  }
}
