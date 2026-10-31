import type http from "node:http";
import { tunnelOrigin, type AuthContext, type AuthDenial } from "../auth.js";
import { MeshError, orchestrator as sharedOrchestrator, ToolError, type Caller, type Orchestrator } from "./orchestrator.js";
import path from "node:path";
import { appendNote, mainAgentRoot, MCP_SERVER_NAME, NOTE_MAX_CHARS, NOTES_FILE } from "./workspace.js";

// mainagent に渡す MCP サーバ（Streamable HTTP の最小構成。mac の McpEndpoint.swift の移植）。POST /mcp に JSON-RPC を
// 1 件ずつ受け、JSON で返す（SSE は使わない。GET / DELETE は 405）。認証は orchestrator の合鍵（Bearer bmt_…）だけ。
// 道具の実体は orchestrator.ts。
// 設定 allSessions が有効なら mainagent 以外のセッションにも渡す。道具に pc を付けると別の PC で呼ぶ。

export const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
const MAX_BODY_BYTES = 1024 * 1024;

type Json = Record<string, unknown>;

/**
 * /mcp の関門（mac の BridgeAuth の .mainAgentToken と同じ）。Host / Origin は guardRejection が先に見ている。
 * - 送り元が 127.0.0.1・受けた番号が待ち受けの番号でなければ 401
 * - 中継のトンネル経由（端末から）は 403 local_only（呼ぶのはこの PC の中の CLI だけ）
 * - ?apiKey= は 401（合鍵はヘッダだけ。ログや履歴に残る）
 * 合鍵そのものはルート（handleMcpRequest）が確かめる。
 */
export function mainAgentRouteDenial(req: http.IncomingMessage, url: URL, ctx: Pick<AuthContext, "peers" | "listenPort">): AuthDenial | null {
  const address = req.socket.remoteAddress?.replace(/^::ffff:/i, "");
  const listen = ctx.listenPort();
  if (address !== "127.0.0.1" || listen === undefined || req.socket.localPort !== listen) return { status: 401, error: "unauthorized" };
  if (tunnelOrigin(req, ctx)) return { status: 403, error: "local_only" };
  if (url.searchParams.has("apiKey")) return { status: 401, error: "unauthorized" };
  return null;
}

function writeJson(res: http.ServerResponse, status: number, body: string): void {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "content-length": Buffer.byteLength(body) });
  res.end(body);
}

/** POST /mcp（関門は通った後）。合鍵を確かめ、JSON-RPC 1 件に答える。 */
export async function handleMcpRequest(req: http.IncomingMessage, res: http.ServerResponse, orch: Orchestrator = sharedOrchestrator): Promise<void> {
  if (req.method !== "POST") {
    req.resume();
    res.writeHead(405, { allow: "POST", "cache-control": "no-store" });
    res.end();
    return;
  }
  const m = /^Bearer (\S+)$/.exec(req.headers.authorization ?? "");
  const caller = m ? orch.caller(m[1]) : undefined;
  if (!caller) {
    req.resume();
    writeJson(res, 401, JSON.stringify({ error: "unauthorized" }));
    return;
  }
  const chunks: Buffer[] = [];
  let size = 0;
  let tooLarge = false;
  await new Promise<void>((resolve, reject) => {
    req.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        tooLarge = true;
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve());
    req.on("error", reject);
  });
  if (tooLarge) {
    writeJson(res, 413, JSON.stringify({ error: "too_large" }));
    return;
  }
  const out = await respondMcp(Buffer.concat(chunks).toString("utf8"), caller, orch);
  if (out === undefined) {
    res.writeHead(202, { "cache-control": "no-store" });
    res.end();
    return;
  }
  writeJson(res, 200, out);
}

/** JSON-RPC 1 件への応答（JSON の文字列）。通知（id 無し）なら undefined（HTTP は 202）。 */
export async function respondMcp(body: string, caller: Caller, orch: Orchestrator = sharedOrchestrator): Promise<string | undefined> {
  let msg: Json;
  try {
    const parsed = JSON.parse(body) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || typeof (parsed as Json).method !== "string") throw new Error("bad");
    msg = parsed as Json;
  } catch {
    return encode({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "parse error" } });
  }
  const id = msg.id;
  if (id === undefined || id === null) return undefined;
  const method = msg.method as string;
  const params = (msg.params && typeof msg.params === "object" ? msg.params : {}) as Json;
  const result = (r: unknown): string => encode({ jsonrpc: "2.0", id, result: r });
  const failure = (code: number, message: string): string => encode({ jsonrpc: "2.0", id, error: { code, message } });

  switch (method) {
    case "initialize": {
      const asked = typeof params.protocolVersion === "string" ? params.protocolVersion : undefined;
      return result({
        protocolVersion: asked && PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: MCP_SERVER_NAME, version: "1" },
        instructions:
          "BuddyOS の Bridge が持つセッションを操作する道具。作業は start_session / send_message で頼み、get_reply で返事を受け取る。子が承認待ち（needs_approval）なら answer_approval で答えられる。別の PC のエージェントに頼むときは list_pcs で PC を選び、道具に pc を付ける。覚えておくことは save_note で NOTES.md に残す。"
      });
    }
    case "ping":
      return result({});
    case "tools/list":
      return result({ tools: TOOLS });
    case "tools/call": {
      const name = params.name;
      if (typeof name !== "string") return failure(-32602, "name が無い");
      const args = (params.arguments && typeof params.arguments === "object" ? params.arguments : {}) as Json;
      try {
        const value = await callTool(name, args, caller, orch);
        return result({ content: [{ type: "text", text: JSON.stringify(sortKeys(value), null, 2) }], isError: false });
      } catch (error) {
        const text = error instanceof ToolError ? error.message : error instanceof Error ? error.message : String(error);
        return result({ content: [{ type: "text", text }], isError: true });
      }
    }
    default:
      return failure(-32601, `method not found: ${method}`);
  }
}

/** 7 つの道具（pc を付けると別の PC で呼ぶ。B の /device/orchestrator/<tool> で呼べるのもこの 7 つ）。 */
export const SESSION_TOOLS: readonly string[] = ["list_projects", "list_agents", "list_sessions", "start_session", "send_message", "get_reply", "answer_approval"];

export async function callTool(name: string, args: Json, caller: Caller, orch: Orchestrator = sharedOrchestrator): Promise<unknown> {
  const str = (key: string): string => {
    const v = args[key];
    if (typeof v !== "string" || !v) throw new ToolError(`${key} が無い`);
    return v;
  };
  const num = (key: string): number | undefined => (typeof args[key] === "number" && Number.isFinite(args[key]) ? (args[key] as number) : undefined);
  if (name === "list_pcs") {
    // 別の PC から頼まれたとき（B）は使わせない（7 つの道具だけ）。
    if (caller.remote) throw new MeshError("unknown_tool", name);
    return orch.listPcs();
  }
  if (name === "save_note") {
    // メインのメモ（NOTES.md）に 1 行足す。承認は要らない。別の PC・ふつうのセッションからは使えない（mac と同じ）。
    if (caller.remote || !caller.main) throw new ToolError("save_note は mainagent のセッションだけが使える");
    const root = mainAgentRoot();
    if (!root) throw new ToolError("mainagent のフォルダが無い");
    try {
      return { saved: appendNote(root, str("text")), file: path.join(root, NOTES_FILE) };
    } catch (error) {
      throw new ToolError(`メモを残せなかった: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (!SESSION_TOOLS.includes(name)) throw new MeshError("unknown_tool", `知らない道具: ${name}`);
  // pc が別の PC なら、そちらの Bridge で呼ぶ。
  const remote = orch.resolvePc(caller, typeof args.pc === "string" ? args.pc : undefined);
  if (remote) return orch.forward(caller, remote, name, args);
  switch (name) {
    case "list_projects":
      return orch.listProjects();
    case "list_agents":
      return orch.listAgents();
    case "list_sessions":
      return orch.listSessions(caller);
    case "start_session":
      return orch.startSession(
        caller,
        typeof args.agent === "string" && args.agent ? args.agent : "claude",
        str("cwd"),
        str("prompt"),
        typeof args.mode === "string" ? args.mode : undefined,
        num("wait_seconds") ?? 0
      );
    case "send_message":
      return orch.sendMessage(caller, str("agent"), str("session_id"), str("text"), num("wait_seconds") ?? 0);
    case "get_reply":
      return orch.getReply(caller, str("agent"), str("session_id"), num("wait_seconds") ?? 60);
    case "answer_approval":
      return orch.answerApproval(caller, str("agent"), str("session_id"), str("request_id"), str("decision"));
    default:
      throw new MeshError("unknown_tool", `知らない道具: ${name}`);
  }
}

// ---- 道具の定義（mac と同じ名前・引数・説明） ----

function schema(props: Record<string, Json>, required: string[]): Json {
  return { type: "object", properties: props, required, additionalProperties: false };
}

/** 7 つの道具に足す pc（別の PC で呼ぶ）。 */
const PC_PROPERTY: Json = {
  type: "string",
  description: "どの PC で呼ぶか（list_pcs の pc か name）。省略時・自分の PC ならこの PC。別の PC で頼む・許可するときも、この PC のユーザーに承認を取る"
};

/** 7 つの道具の引数に pc を足す。 */
function withPc(props: Record<string, Json>, required: string[]): Json {
  return schema({ ...props, pc: PC_PROPERTY }, required);
}

export const TOOLS: readonly Json[] = [
  {
    name: "list_pcs",
    description:
      "道具で使える PC の一覧。pcs[] に pc（bridgeId）/ name / platform / self（この PC なら true）。別の PC のエージェントに頼むときは、ほかの道具の pc にこの pc か name を渡す。",
    inputSchema: schema({}, [])
  },
  {
    name: "save_note",
    description:
      "覚えておくとよいこと（利用者の好み・続いている作業・決まったこと）を、メインのメモ（~/.buddyos/main/NOTES.md）の末尾に 1 行で残す。承認は要らない。前に残したことは NOTES.md を読めばわかる。",
    inputSchema: schema({ text: { type: "string", description: `残すこと（${NOTE_MAX_CHARS} 文字まで。改行は空白になる）` } }, ["text"])
  },
  {
    name: "list_projects",
    description: "登録されているプロジェクト（作業フォルダ）の名前とパス。どのプロジェクトの話かを決めるのに使う。",
    inputSchema: withPc({}, [])
  },
  {
    name: "list_agents",
    description: "使えるエージェント（claude / codex / opencode など）と、入っているか・設定済みか。",
    inputSchema: withPc({}, [])
  },
  {
    name: "list_sessions",
    description:
      "動いているセッションの一覧。agent / session_id / cwd / project / state（working=作業中、idle=待機、closed=閉じたが送れば開き直す）/ source（bridge=BuddyOS が起こした、terminal=ターミナルの Claude）。頼んだセッションには last_request / last_request_state（queued / running / needs_approval / done / error）と、承認待ちなら pending_approvals が付く。",
    inputSchema: withPc({}, [])
  },
  {
    name: "start_session",
    description:
      "プロジェクトのフォルダで新しいセッションを起こし、最初の指示を送る。送る前にユーザーの承認を取る。返事は wait_seconds で待つか、get_reply で受け取る。",
    inputSchema: withPc(
      {
        agent: { type: "string", description: "エージェント ID（list_agents の agent）。省略時は claude" },
        cwd: { type: "string", description: "作業フォルダの絶対パス（list_projects の path）" },
        prompt: { type: "string", description: "最初の指示。目的・やること・やらないこと・終わりの条件・報告の形を書く" },
        mode: {
          type: "string",
          enum: ["plan", "ask", "edit", "auto", "dangerous"],
          description:
            "子の権限モード（その agent での意味。claude の auto と codex の ask は毎回尋ねる、codex の auto は作業フォルダに尋ねずに書く）。このチャットで選んだモード（無ければ「毎回尋ねる」）より強くはならず、上限以下のモードを持たない agent は起こせない。省略時は上限以下で一番強いもの"
        },
        wait_seconds: { type: "number", description: "そのまま返事を待つ秒数（0〜300、既定 0 = 待たない）" }
      },
      ["cwd", "prompt"]
    )
  },
  {
    name: "send_message",
    description:
      "既存のセッションに指示を送る。送る前にユーザーの承認を取る。相手のモードが このチャットの上限より強ければ送らない。作業中なら今のターンの後に実行される。返事は wait_seconds で待つか、get_reply で受け取る。",
    inputSchema: withPc(
      {
        agent: { type: "string" },
        session_id: { type: "string" },
        text: { type: "string", description: "送る指示" },
        wait_seconds: { type: "number", description: "そのまま返事を待つ秒数（0〜300、既定 0 = 待たない）" }
      },
      ["agent", "session_id", "text"]
    )
  },
  {
    name: "get_reply",
    description:
      "セッションの返事を待って受け取る。status: running（作業中）/ queued（順番待ち）/ needs_approval（承認待ち。approval に request_id・title・summary・choices が付く。answer_approval で答えるか、ユーザーに開いてもらう）/ done / error / idle。reply が最後の返事。",
    inputSchema: withPc(
      {
        agent: { type: "string" },
        session_id: { type: "string" },
        wait_seconds: { type: "number", description: "終わるまで待つ秒数（0〜300、既定 60）。0 なら今の状態だけ見る" }
      },
      ["agent", "session_id"]
    )
  },
  {
    name: "answer_approval",
    description:
      "子のセッションが待っている承認（get_reply の approval）に答える。deny はすぐ答える。allow / allow_for_session は、その前に BuddyOS がユーザーに承認を取る。このチャットのモードが上限で、計画（読むだけ）なら許可できない・allow_for_session は「編集は尋ねない」以上のときだけ・相手のモードが上限より強ければ答えない。何を許すのか分からないときは、答えずにユーザーに聞く。",
    inputSchema: withPc(
      {
        agent: { type: "string" },
        session_id: { type: "string" },
        request_id: { type: "string", description: "get_reply の approval.request_id" },
        decision: {
          type: "string",
          enum: ["allow", "allow_for_session", "deny"],
          description:
            "allow = 一度だけ許可、allow_for_session = このセッションでは同種の操作を許可（選べるのは approval.choices にあるものだけ）、deny = 断る"
        }
      },
      ["agent", "session_id", "request_id", "decision"]
    )
  }
];

function encode(obj: Json): string {
  return JSON.stringify(sortKeys(obj));
}

/** キーを並べる（mac の .sortedKeys と同じ）。 */
export function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value as Json).sort().map((k) => [k, sortKeys((value as Json)[k])]));
  }
  return value;
}
