import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { JsonRpcProcess } from "../runtime/jsonRpcProcess.js";
import type { RuntimeCommand } from "../runtime/command.js";

/// Buddy が使う MCP サーバー（~/.buddyos/buddy-mcp.json）のクライアント（mac の BuddyMcpClient の移植）。
/// 使うのは tools/list と tools/call だけ。url のサーバーは Streamable HTTP、command のサーバーは stdio。

export interface BuddyMcpServer {
  name: string;
  url?: string;
  headers?: Record<string, string>;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
}

export interface BuddyTool {
  server: string;
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  /** MCP の tool annotations（readOnlyHint / destructiveHint）。サーバーが付けたときだけ。 */
  annotations?: { readOnlyHint?: boolean; destructiveHint?: boolean };
}

export function buddyMcpConfigPath(): string {
  return path.join(os.homedir(), ".buddyos", "buddy-mcp.json");
}

export function readBuddyMcpConfig(): Record<string, Record<string, unknown>> {
  try {
    const parsed = JSON.parse(fs.readFileSync(buddyMcpConfigPath(), "utf8")) as { mcpServers?: Record<string, Record<string, unknown>> };
    return parsed.mcpServers && typeof parsed.mcpServers === "object" ? parsed.mcpServers : {};
  } catch {
    return {};
  }
}

export function writeBuddyMcpConfig(servers: Record<string, Record<string, unknown>>): void {
  const file = buddyMcpConfigPath();
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let root: Record<string, unknown> = {};
  try {
    root = JSON.parse(fs.readFileSync(file, "utf8")) as Record<string, unknown>;
  } catch {
    /* 新規 */
  }
  root.mcpServers = servers;
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(root, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

export function buddyMcpServers(): BuddyMcpServer[] {
  const strMap = (v: unknown): Record<string, string> | undefined =>
    v && typeof v === "object" && !Array.isArray(v)
      ? Object.fromEntries(Object.entries(v as Record<string, unknown>).filter(([, x]) => typeof x === "string") as Array<[string, string]>)
      : undefined;
  const out: BuddyMcpServer[] = [];
  for (const [name, def] of Object.entries(readBuddyMcpConfig())) {
    if (def.enabled === false) continue;
    if (typeof def.url === "string") out.push({ name, url: def.url, headers: strMap(def.headers) });
    else if (typeof def.command === "string") {
      const args = Array.isArray(def.args) ? def.args.filter((a): a is string => typeof a === "string") : [];
      out.push({ name, command: def.command, args, env: strMap(def.env) });
    }
  }
  return out;
}

/** PATH から実行ファイルを探す（Windows は .exe / .cmd / .bat を補う。npx → npx.cmd）。 */
function resolveExecutable(command: string): string {
  if (path.isAbsolute(command) || command.includes("/") || command.includes("\\")) return command;
  const exts = process.platform === "win32" ? [".exe", ".cmd", ".bat", ""] : [""];
  for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
    for (const ext of exts) {
      const candidate = path.join(dir, command + ext);
      if (ext === "" && process.platform === "win32") continue;
      try {
        if (fs.statSync(candidate).isFile()) return candidate;
      } catch {
        /* 次へ */
      }
    }
  }
  return command;
}

interface Connection {
  listTools(): Promise<BuddyTool[]>;
  callTool(name: string, args: Record<string, unknown>): Promise<string>;
  close(): void;
}

const PROTOCOL = { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "buddyos-bridge", version: "1.0" } };

function toolText(result: Record<string, unknown>): string {
  const content = Array.isArray(result.content) ? result.content : [];
  return content
    .map((c) => {
      const o = c as Record<string, unknown>;
      return o.type === "text" && typeof o.text === "string" ? o.text : `[${String(o.type ?? "content")}]`;
    })
    .join("\n");
}

function toolsFrom(server: string, result: Record<string, unknown>): BuddyTool[] {
  const tools = Array.isArray(result.tools) ? result.tools : [];
  return tools.map((t) => {
    const o = t as Record<string, unknown>;
    const tool: BuddyTool = {
      server,
      name: String(o.name ?? ""),
      description: typeof o.description === "string" ? o.description : "",
      inputSchema: o.inputSchema && typeof o.inputSchema === "object" ? (o.inputSchema as Record<string, unknown>) : { type: "object" }
    };
    const a = o.annotations && typeof o.annotations === "object" ? (o.annotations as Record<string, unknown>) : undefined;
    if (a) {
      tool.annotations = {};
      if (typeof a.readOnlyHint === "boolean") tool.annotations.readOnlyHint = a.readOnlyHint;
      if (typeof a.destructiveHint === "boolean") tool.annotations.destructiveHint = a.destructiveHint;
    }
    return tool;
  });
}

class StdioConnection implements Connection {
  private client?: JsonRpcProcess;
  private ready?: Promise<void>;

  constructor(private readonly server: BuddyMcpServer) {}

  private async ensure(): Promise<JsonRpcProcess> {
    if (this.client?.alive && this.ready) {
      await this.ready;
      return this.client;
    }
    const runtime: RuntimeCommand = { kind: "native", executable: resolveExecutable(this.server.command!), label: `native:${this.server.command}`, shell: false };
    const client = new JsonRpcProcess(runtime, this.server.args ?? [], undefined, this.server.env);
    client.on("stderr", () => {});
    this.client = client;
    this.ready = (async () => {
      const res = await client.request("initialize", PROTOCOL, 60_000);
      if (res.error) throw new Error(`initialize failed: ${JSON.stringify(res.error)}`);
      client.notify("notifications/initialized", {});
    })();
    await this.ready;
    return client;
  }

  async listTools(): Promise<BuddyTool[]> {
    const res = await (await this.ensure()).request("tools/list", {}, 30_000);
    if (res.error) throw new Error(JSON.stringify(res.error));
    return toolsFrom(this.server.name, (res.result ?? {}) as Record<string, unknown>);
  }

  async callTool(name: string, args: Record<string, unknown>): Promise<string> {
    const res = await (await this.ensure()).request("tools/call", { name, arguments: args }, 180_000);
    if (res.error) throw new Error(JSON.stringify(res.error));
    return toolText((res.result ?? {}) as Record<string, unknown>);
  }

  close(): void {
    this.client?.close();
    this.client = undefined;
  }
}

class HttpConnection implements Connection {
  private sessionId?: string;
  private nextId = 0;
  private initialized = false;

  constructor(private readonly server: BuddyMcpServer) {}

  private async post(body: Record<string, unknown>, timeoutMs: number): Promise<Record<string, unknown> | undefined> {
    const headers: Record<string, string> = {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      ...(this.server.headers ?? {})
    };
    if (this.sessionId) headers["mcp-session-id"] = this.sessionId;
    const res = await fetch(this.server.url!, { method: "POST", headers, body: JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) });
    const sid = res.headers.get("mcp-session-id");
    if (sid) this.sessionId = sid;
    if (!("id" in body)) return undefined;
    const text = await res.text();
    if (!res.ok) throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
    if ((res.headers.get("content-type") ?? "").includes("text/event-stream")) {
      let last: Record<string, unknown> | undefined;
      for (const line of text.split(/\r?\n/)) {
        if (!line.startsWith("data:")) continue;
        try {
          const o = JSON.parse(line.slice(5).trim()) as Record<string, unknown>;
          if (o.id !== undefined) last = o;
        } catch {
          /* 途中 */
        }
      }
      return last;
    }
    return JSON.parse(text) as Record<string, unknown>;
  }

  private async request(method: string, params: Record<string, unknown>, timeoutMs: number): Promise<Record<string, unknown>> {
    if (!this.initialized && method !== "initialize") {
      await this.request("initialize", PROTOCOL, 60_000);
      await this.post({ jsonrpc: "2.0", method: "notifications/initialized", params: {} }, 30_000);
      this.initialized = true;
    }
    this.nextId += 1;
    const res = await this.post({ jsonrpc: "2.0", id: this.nextId, method, params }, timeoutMs);
    if (!res) throw new Error(`${method}: empty response`);
    if (res.error) throw new Error(JSON.stringify(res.error));
    return (res.result ?? {}) as Record<string, unknown>;
  }

  async listTools(): Promise<BuddyTool[]> {
    return toolsFrom(this.server.name, await this.request("tools/list", {}, 30_000));
  }

  async callTool(name: string, args: Record<string, unknown>): Promise<string> {
    return toolText(await this.request("tools/call", { name, arguments: args }, 180_000));
  }

  close(): void {}
}

/** Buddy の全セッションで共有する MCP クライアント（ツール一覧はサーバーごとにキャッシュ。失敗はキャッシュしない）。 */
export class BuddyMcpClient {
  private readonly connections = new Map<string, Connection>();
  private readonly toolCache = new Map<string, BuddyTool[]>();
  private configKey = "";

  private sync(): BuddyMcpServer[] {
    const servers = buddyMcpServers();
    const key = JSON.stringify(servers);
    if (key !== this.configKey) {
      for (const c of this.connections.values()) c.close();
      this.connections.clear();
      this.toolCache.clear();
      this.configKey = key;
    }
    return servers;
  }

  private connection(server: BuddyMcpServer): Connection {
    let c = this.connections.get(server.name);
    if (!c) {
      c = server.url ? new HttpConnection(server) : new StdioConnection(server);
      this.connections.set(server.name, c);
    }
    return c;
  }

  async tools(): Promise<BuddyTool[]> {
    const out: BuddyTool[] = [];
    for (const server of this.sync()) {
      let tools = this.toolCache.get(server.name);
      if (!tools) {
        try {
          tools = await this.connection(server).listTools();
          this.toolCache.set(server.name, tools);
        } catch {
          continue;
        }
      }
      out.push(...tools);
    }
    return out;
  }

  /** 開いている MCP サーバーをすべて閉じる（Bridge の終了・テストの後片付け）。 */
  closeAll(): void {
    for (const c of this.connections.values()) c.close();
    this.connections.clear();
    this.toolCache.clear();
    this.configKey = "";
  }

  async call(tool: BuddyTool, args: Record<string, unknown>): Promise<string> {
    const server = this.sync().find((s) => s.name === tool.server);
    if (!server) throw new Error(`MCP server not found: ${tool.server}`);
    return this.connection(server).callTool(tool.name, args);
  }
}
