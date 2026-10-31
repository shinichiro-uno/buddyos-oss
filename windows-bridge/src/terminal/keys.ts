import { execFile } from "node:child_process";
import { systemExe } from "../runtime/systemExe.js";
import { validPane } from "./paneStatus.js";

/// ターミナルの対話画面（TUI）に出た選択肢へ、キー入力で答える（mac の TerminalKeyRouter / TerminalKeyPlan の移植）。
/// デスクトップ（main）が GET /terminal/keys/poll?pids=… で自分の pty の pid を名乗りながら long-poll し、
/// 返ってきたキーをその pty に間をあけて書く。Bridge は選択肢を出した claude の pid から親をたどり、
/// 名乗られた pty に行き当たれば「キーで答えられる」とみなす。
/// Windows のデスクトップはペイン id（BUDDYOS_PANE_ID）も panes=<id>:<pid> で名乗る。hook が X-BuddyOS-Pane で
/// ペインを名乗っていれば、親をたどらずにそれで決める（Windows の親の表は PowerShell で引くので遅い）。
///
/// 人がペアリング済みの端末の入力欄で打った発話も、同じ口でターミナルに打ち込む（typingKeys）。
/// 受け箱（cross-session messaging）で送ると「別の Claude セッションからの依頼」として届き、本人の承認として
/// 扱われない。打ち込めばキーボードで打ったのと同じ発話になる（mac の TerminalKeyPlan.typing と同じ）。
/// 打ち込みは、宛先の claude が生きていて前面にいるか、その session の入力欄が空いているかを書く前に確かめる
/// デスクトップ（poll の typing=1）にだけ送る。

export interface KeyDelivery {
  pid: number;
  keys: string[];
  gapMs: number;
  /** 発話の打ち込みの宛先の claude の pid。デスクトップは書く前に、これが生きているか（前面にいるか）を確かめ、
   *  違えば残りを書かない（claude が終わった後のシェルに、発話をコマンドとして打たない）。 */
  expectPid?: number;
  /** その claude の session id。デスクトップは書く前に毎回 ~/.claude/sessions/<expectPid>.json を読み、この session で
   *  status が idle（か shell）のときだけ書く（貼り付けている間に許可の確認や一覧が開いたら、Enter で選ばない）。 */
  expectSession?: string;
}

interface Client {
  pids: Set<number>;
  /** ペイン id → pty の pid。 */
  panes: Map<string, number>;
  /** 発話の打ち込みを受け付けるか（expectPid を確かめてから書くデスクトップ。poll の typing=1）。 */
  canType: boolean;
  lastSeen: number;
  queue: KeyDelivery[];
  waiter?: { token: number; resolve: (d: KeyDelivery[]) => void };
}

const connected = (c: Client): boolean => c.waiter !== undefined || Date.now() - c.lastSeen < 10_000;

/* ── 親プロセスの表 ─────────────────────────────────────────────────── */

let parentsCache: { at: number; map: Map<number, number> } | undefined;
let parentsInflight: Promise<Map<number, number>> | undefined;

function runText(cmd: string, args: string[]): Promise<string> {
  return new Promise((resolve) => {
    execFile(cmd, args, { windowsHide: true, timeout: 8000, maxBuffer: 16 * 1024 * 1024 }, (_err, stdout) => resolve(String(stdout ?? "")));
  });
}

/** 表を使い回す時間。Windows は引くのに 1 秒ほどかかるので長めにする（知らない pid が来たら引き直す）。 */
const PARENTS_TTL_MS = process.platform === "win32" ? 15_000 : 3000;

/** pid → 親 pid（Windows は CIM、ほかは ps）。しばらく使い回す（選択肢が出るたびに引くので）。fresh なら引き直す。 */
export async function processParents(fresh = false): Promise<Map<number, number>> {
  if (!fresh && parentsCache && Date.now() - parentsCache.at < PARENTS_TTL_MS) return parentsCache.map;
  if (parentsInflight) return parentsInflight;
  parentsInflight = (async () => {
    const map = new Map<number, number>();
    const text =
      process.platform === "win32"
        ? await runText(systemExe("powershell.exe"), [
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "Get-CimInstance Win32_Process | ForEach-Object { \"$($_.ProcessId) $($_.ParentProcessId)\" }"
          ])
        : await runText("ps", ["-A", "-o", "pid=,ppid="]);
    for (const line of text.split(/\r?\n/)) {
      const [pid, ppid] = line.trim().split(/\s+/).map((v) => Number.parseInt(v, 10));
      if (Number.isFinite(pid) && Number.isFinite(ppid)) map.set(pid, ppid);
    }
    parentsCache = { at: Date.now(), map };
    return map;
  })().finally(() => {
    parentsInflight = undefined;
  });
  return parentsInflight;
}

export class TerminalKeyRouter {
  private readonly clients = new Map<string, Client>();
  private token = 0;

  constructor(private readonly parents: (fresh?: boolean) => Promise<Map<number, number>> = processParents) {}

  /** ペイン id から、デスクトップが持っている pty の pid を返す（名乗られていなければ undefined）。 */
  ptyForPane(pane: string | undefined): number | undefined {
    return this.paneOwner(pane, () => true);
  }

  /** ペイン id から、発話を打ち込める pty（打ち込みを受け付けるデスクトップが持っているもの）の pid を返す。 */
  typingPtyForPane(pane: string | undefined): number | undefined {
    return this.paneOwner(pane, (c) => c.canType);
  }

  private paneOwner(pane: string | undefined, match: (c: Client) => boolean): number | undefined {
    if (!pane) return undefined;
    for (const c of this.clients.values()) {
      const pid = connected(c) && match(c) ? c.panes.get(pane) : undefined;
      if (pid !== undefined && c.pids.has(pid)) return pid;
    }
    return undefined;
  }

  /** claude 本体の pid から親をたどり、デスクトップが持っている pty の pid を返す（無ければ undefined）。 */
  ptyOwner(pid: number | undefined): Promise<number | undefined> {
    return this.owner(pid, () => true);
  }

  /** 発話を打ち込める pty（打ち込みを受け付けるデスクトップが持っているもの）の pid。古いデスクトップのものは数えない。 */
  typingOwner(pid: number | undefined): Promise<number | undefined> {
    return this.owner(pid, (c) => c.canType);
  }

  private async owner(pid: number | undefined, match: (c: Client) => boolean): Promise<number | undefined> {
    if (!pid) return undefined;
    const owned = new Set<number>();
    for (const c of this.clients.values()) if (connected(c) && match(c)) for (const p of c.pids) owned.add(p);
    if (owned.size === 0) return undefined;
    let parents = await this.parents();
    // 表を引いた後に起きた claude は載っていない。そのときだけ引き直す。
    if (!parents.has(pid)) parents = await this.parents(true);
    let cur = pid;
    for (let i = 0; i < 8; i += 1) {
      if (owned.has(cur)) return cur;
      const parent = parents.get(cur);
      if (!parent || parent <= 1 || parent === cur) return undefined;
      cur = parent;
    }
    return undefined;
  }

  enqueue(delivery: KeyDelivery): void {
    for (const c of this.clients.values()) {
      if (!connected(c) || !c.pids.has(delivery.pid)) continue;
      if (c.waiter) {
        const w = c.waiter;
        c.waiter = undefined;
        w.resolve([delivery]);
      } else {
        c.queue.push(delivery);
      }
      return;
    }
  }

  /**
   * デスクトップの long-poll。pids は今開いている pty の pid、panes はペイン id → pid（毎回まるごと名乗る）。
   * canType は発話の打ち込みを受け付けるか（古いデスクトップは名乗らないので、選択肢への答えだけを送る）。
   */
  poll(client: string, pids: number[], timeoutMs: number, panes?: Map<string, number>, canType = false): Promise<KeyDelivery[]> {
    const c = this.clients.get(client) ?? { pids: new Set<number>(), panes: new Map<string, number>(), canType: false, lastSeen: Date.now(), queue: [] };
    this.clients.set(client, c);
    c.pids = new Set(pids);
    c.panes = panes ?? new Map();
    c.canType = canType;
    c.lastSeen = Date.now();
    if (c.queue.length > 0) return Promise.resolve(c.queue.splice(0));
    c.waiter?.resolve([]);
    const token = ++this.token;
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (c.waiter?.token !== token) return;
        c.waiter = undefined;
        c.lastSeen = Date.now();
        resolve([]);
      }, timeoutMs);
      c.waiter = {
        token,
        resolve: (d) => {
          clearTimeout(timer);
          c.lastSeen = Date.now();
          resolve(d);
        }
      };
    });
  }
}

/** panes=<id>:<pid>,… を読む（id はペインの名前として正しいものだけ）。 */
export function parsePanes(raw: string | null | undefined): Map<string, number> {
  const out = new Map<string, number>();
  for (const part of (raw ?? "").split(",")) {
    const i = part.lastIndexOf(":");
    if (i <= 0) continue;
    const id = validPane(part.slice(0, i));
    const pid = Number.parseInt(part.slice(i + 1), 10);
    if (id && Number.isFinite(pid) && pid > 0) out.set(id, pid);
  }
  return out;
}

/* ── 答え → キー ─────────────────────────────────────────────────────── */

export const ESC = "\u001b";
export const ENTER = "\r";
export const RIGHT = "\u001b[C";
export const DOWN = "\u001b[B";

export const PASTE_START = "\u001b[200~";
export const PASTE_END = "\u001b[201~";
/** 打ち込みの 1 操作の長さ（UTF-16 の数）。デスクトップが受け付ける 8192 より少し短くする。 */
export const TYPING_CHUNK = 8000;
/** デスクトップが 1 回で受け付ける操作の数と、1 操作の長さ（terminalKeyRelay.ts の MAX_KEYS / MAX_KEY_LENGTH）。 */
export const RELAY_MAX_KEYS = 32;
export const RELAY_MAX_KEY_LENGTH = 8192;
/** 貼り付けから Enter まで（と、長い文を分けた貼り付けの間）の時間。claude 2.1.300 で 500ms なら確実に送られた。 */
export const TYPING_GAP_MS = 500;

/**
 * 人が打った発話を、ターミナルの claude に打ち込むキーの列。貼り付け（bracketed paste）で入れてから Enter。
 * 空のとき・長すぎてデスクトップが受け付けないときは null。claude 2.1.300 で実測（mac と同じ）:
 * - 改行を含む文も 1 つの発話になる。長い文は貼り付けの途中で分けても、閉じる印までが 1 つの貼り付けになる。
 * - 長い文・行の多い文は、ターミナルで貼り付けたときと同じく `<pasted_content>` に包まれて届く。
 * - 先頭が `/` の文は、コマンド名でなければ普通の発話になる。`@` はファイルの指定として読まれる（打ったときと同じ）。
 * - 先頭が `!` だと、シェルのコマンドとしてすぐ実行される（bash モード。許可の確認も auto の判定も通らない）。
 *   空白を 1 つ前に付けると普通の発話になるので、そうして Claude に渡す。
 */
export function typingKeys(text: string): string[] | null {
  let body = sanitizedForTyping(text);
  if (body.trim() === "") return null;
  if (body.startsWith("!")) body = ` ${body}`;
  // 文字（コードポイント）の途中では分けない（サロゲートの片方だけを書くと、デスクトップで文字化けする）。
  const chunks: string[] = [];
  let current = PASTE_START;
  for (const ch of body) {
    if (current.length + ch.length > TYPING_CHUNK && current.length > 0) {
      chunks.push(current);
      current = "";
    }
    current += ch;
  }
  if (current.length + PASTE_END.length > TYPING_CHUNK) {
    chunks.push(current);
    current = "";
  }
  chunks.push(current + PASTE_END);
  if (chunks.length >= RELAY_MAX_KEYS || chunks.some((chunk) => chunk.length > RELAY_MAX_KEY_LENGTH)) return null;
  return [...chunks, ENTER];
}

/**
 * 打ち込む文から制御文字を落とす（改行とタブは残す）。ESC を通すと貼り付けを途中で閉じ、続きをキー操作として
 * 打たせられる（`ESC [201~` の後ろの文字や Enter）。改行は \n にそろえる（\r は Enter として送られてしまう）。
 * 落とすのは C0（改行とタブを除く）・DEL・C1。
 */
export function sanitizedForTyping(text: string): string {
  return text.replace(/\r\n?/g, "\n").replace(/[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/g, "");
}

/** 許可確認。allow → 1、allowForSession → 2（候補があるときだけ画面にある）、それ以外 → Esc。 */
export function approvalKeys(decision: string, hasSuggestions: boolean): string[] {
  if (decision === "allow") return ["1"];
  if (decision === "allowForSession") return [hasSuggestions ? "2" : "1"];
  return [ESC];
}

/**
 * 受け箱の保留（YOLO のセッションがほかから届いた発話を止めたときのダイアログ。claude 2.1.293 で実測）。
 *   Deny — drop it and tell the sender it was declined（最初に選ばれている）/ Deliver this message to Claude
 *   番号は無く番号キーでは選べず、↑↓ は端で折り返す。
 * allow → ↓ Enter（Deliver）、それ以外 → Esc（Deny。届かない）。
 */
export function heldKeys(decision: string): string[] {
  return decision.startsWith("allow") ? [DOWN, ENTER] : [ESC];
}

/** 計画の承認。allowAuto → 1、allow → 2、deny → Esc、それ以外の文 → 3 で入力欄に移って打ち、Enter。 */
export function planKeys(decision: string): string[] {
  if (decision === "allowAuto") return ["1"];
  if (decision === "allow") return ["2"];
  if (decision === "deny") return [ESC];
  const text = decision.trim();
  return text ? ["3", text, ENTER] : [ESC];
}

type Question = Record<string, unknown>;

/** AskUserQuestion。answers は 質問文 → 選んだ label（複数選択は配列）。答えの無い質問があれば undefined。 */
export function questionKeys(questions: Question[], answers: Record<string, string[]>): string[] | undefined {
  const keys: string[] = [];
  let needsSubmit = questions.length > 1;
  for (const q of questions) {
    const question = typeof q.question === "string" ? q.question : "";
    const labels = (Array.isArray(q.options) ? q.options : []).map((o) => String((o as Record<string, unknown>).label ?? ""));
    const picked = answers[question] ?? [];
    if (picked.length === 0) return undefined;
    if (q.multiSelect === true) {
      needsSubmit = true;
      for (const p of picked) {
        const i = labels.indexOf(p);
        if (i >= 0 && i < 9) keys.push(String(i + 1));
      }
      keys.push(RIGHT);
    } else {
      const p = picked[0];
      const i = labels.indexOf(p);
      if (i >= 0 && i < 9) keys.push(String(i + 1));
      else if (labels.length < 9) keys.push(String(labels.length + 1), p, ENTER);
      else return undefined;
    }
  }
  if (needsSubmit) keys.push(ENTER);
  return keys;
}

/** answers_json（{質問 id: 文字列 | [文字列]}）を 質問 → 選んだもの の形に。古いクライアントは decision だけ。 */
export function answerLists(meta: Record<string, string>, decision: string, questions: Question[]): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  try {
    const parsed = JSON.parse(meta.answers_json ?? "{}") as Record<string, unknown>;
    for (const [k, v] of Object.entries(parsed)) {
      if (typeof v === "string" && v) out[k] = [v];
      else if (Array.isArray(v)) out[k] = v.filter((x): x is string => typeof x === "string" && x.length > 0);
    }
  } catch {
    /* decision だけ */
  }
  const first = questions[0]?.question;
  if (Object.keys(out).length === 0 && typeof first === "string" && decision) out[first] = decision.split(", ").filter(Boolean);
  return out;
}
