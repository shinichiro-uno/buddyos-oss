/// デスクトップのアプリ内ターミナルの、ペインごとのエージェントの状態（mac の TerminalPaneStatus の移植）。
/// ペインのシェルには BUDDYOS_PANE_ID が入っていて、その中で動く claude の hook が X-BuddyOS-Pane で名乗る。
/// デスクトップは GET /terminal/panes/poll で long-poll して読む。
///   working（main のターンが動いている）/ attention（選択肢が出ている）/ done（turn が 1 増える）/ error / idle
/// バックグラウンドのサブエージェントとコマンドはターンが終わっても動き続ける（終わると CLI が知らせのターンを始める）。
/// state には混ぜず、動いている数を backgroundAgents / backgroundShells で別に持つ（docs/BACKGROUND_WORK_2026-10-21.md §3.4）。

export interface PaneEntry {
  pane: string;
  /** そのペインで動いているエージェント（claude / codex …）。 */
  agent: string;
  state: string;
  sessionId?: string;
  cwd?: string;
  /** 終わったターンの数。ペインごとに増えるだけ（SessionEnd で entry が消えても、同じペインの次の会話は続きから数える）。 */
  turn: number;
  /** 最後に done になったターンの返事の文（REPLY_LIMIT 字で切る）。done のときだけ持ち、ほかの状態では消す。 */
  reply?: string;
  /** 動いているバックグラウンドのサブエージェント（workflow・teammate の行を含む）と、バックグラウンドのコマンド
   *  （Monitor を含む）の数。hook のたびに SubagentTracker から書く。 */
  backgroundAgents: number;
  /** backgroundAgents のうち background == true の行（Live Activity の数え方。docs/BACKGROUND_CONTROL_2026-10-21.md §8.2）。 */
  backgroundOnlyAgents: number;
  backgroundShells: number;
  updatedAt: number;
}

/** 動いているバックグラウンドの作業の数。 */
export interface BackgroundCounts {
  agents: number;
  shells: number;
  /** agents のうち background == true の行。省けば前の値のまま。 */
  onlyAgents?: number;
}

/** reply の上限（字数）。 */
export const REPLY_LIMIT = 16_000;
/** POST /terminal/pane-event で受け付ける state。 */
export const PANE_STATES: ReadonlySet<string> = new Set(["working", "attention", "done", "error", "idle"]);
/** attention にする Notification の notification_type（どれも、答えるまでセッションが止まる確認）。 */
export const ATTENTION_NOTIFICATIONS: ReadonlySet<string> = new Set([
  "permission_prompt",
  "elicitation_dialog",
  "elicitation_url_dialog",
  "worker_permission_prompt"
]);
/** turnFloor に残すペインの数の上限。 */
const TURN_FLOOR_LIMIT = 512;

/** POST /terminal/pane-event の本文（hook を使わないエージェント。Codex の proxy など）。 */
export interface PaneEvent {
  pane: string;
  agent: string;
  state: string;
  sessionId?: string;
  cwd?: string;
  reply?: string;
}

export function validPane(s: string | undefined | null): string | undefined {
  return s && /^[A-Za-z0-9_-]{1,64}$/.test(s) ? s : undefined;
}

/** エージェント名として受け付ける形（小文字・数字・ハイフン、32 字まで）。 */
export function validAgent(s: unknown): string | undefined {
  return typeof s === "string" && /^[a-z0-9-]{1,32}$/.test(s) ? s : undefined;
}

/** POST /terminal/pane-event の本文を確かめる。形が違えば undefined（400）。agent が無ければ claude。 */
export function parsePaneEvent(body: Record<string, unknown>): PaneEvent | undefined {
  const pane = validPane(typeof body.pane === "string" ? body.pane : undefined);
  const state = typeof body.state === "string" && PANE_STATES.has(body.state) ? body.state : undefined;
  if (!pane || !state) return undefined;
  let agent = "claude";
  if (body.agent !== undefined) {
    const a = validAgent(body.agent);
    if (!a) return undefined;
    agent = a;
  }
  const text = (v: unknown): string | undefined => (typeof v === "string" && v ? v : undefined);
  return { pane, agent, state, sessionId: text(body.sessionId), cwd: text(body.cwd), reply: text(body.reply) };
}

/** 字数（コードポイント）で切る。サロゲートペアの途中で切らない。 */
function clip(s: string, limit: number): string {
  if (s.length <= limit) return s;
  const chars = Array.from(s);
  return chars.length <= limit ? s : chars.slice(0, limit).join("");
}

/**
 * hook のイベントからペインの状態を決める。変えないイベントなら undefined。current: そのペインの今の状態（同じ会話のもの）。
 * サブエージェントの中の hook（agent_id 付き）は状態を変えない。バックグラウンドのサブエージェントはターンの外でも動き、
 * 選択肢が出ている間（attention）に届いても作業中に戻さない。選択肢そのもの（許可の確認・確認の知らせ）だけは
 * サブエージェントのものでも attention にする（答えるまでターミナルが止まる）。
 */
export function paneState(event: string, hook: Record<string, unknown>, current?: string): string | undefined {
  const fromSubagent = typeof hook.agent_id === "string" && hook.agent_id !== "";
  switch (event) {
    case "UserPromptSubmit":
    case "PreToolUse":
    case "PostToolUse":
    case "PostToolUseFailure":
      return fromSubagent ? undefined : "working";
    case "MessageDisplay":
      // ターンの途中でだけ「作業中」を続ける。終わった後にも届く（離席中のまとめ（recap）の表示など）が、
      // その後に Stop は来ないので、ここで作業中に戻すと終わっても作業中のまま残る。
      if (fromSubagent) return undefined;
      return current === "working" || current === "attention" ? "working" : undefined;
    case "PermissionRequest":
      return "attention";
    case "Notification": {
      // 許可・確認の知らせは PermissionRequest と同じ扱い。入力待ち（idle_prompt）などでは変えない。
      const type = hook.notification_type;
      return typeof type === "string" && ATTENTION_NOTIFICATIONS.has(type) ? "attention" : undefined;
    }
    case "Stop":
      // Esc で中断した（ClaudeTerminalRegistry の見張りが送る）。見ていたはずなので「終わった」にしない。
      if (hook.buddy_interrupted === true) return "idle";
      // main のターンが終わった。バックグラウンドの作業が残っていても done にする（返事を読み上げ、話しかけられるように。
      // 残っている作業は backgroundAgents / backgroundShells で別に知らせる）。
      return "done";
    case "StopFailure":
      return "error";
    default:
      // SubagentStart / SubagentStop（サブエージェントの始まり・終わり）などでは変えない。
      return undefined;
  }
}

export class TerminalPaneStatus {
  private readonly entries = new Map<string, PaneEntry>();
  // Bridge を起こし直しても、前の番号を持ったデスクトップが待ち続けないよう、適当な番号から始める。
  private version = 1000 + Math.floor(Math.random() * 1_000_000_000);
  private readonly waiters = new Set<() => void>();
  /** 前の done の後に main のスレッドの動き（作業中・本文）があったペイン。done が続いても、動きがあれば 1 回に数える。 */
  private readonly active = new Set<string>();
  /** entry を消したペインの turn。同じペインで次に動く会話（/clear の後など）は、ここから数える
   *  （デスクトップは turn が増えたのを見て「終わった」を知らせ、音声会話は返事を読む。0 に戻すと前の回数を超えるまで黙る）。 */
  private readonly turnFloor = new Map<string, number>();
  /** backgroundAgents・backgroundOnlyAgents・state のどれかが変わった（Live Activity の数を見直す）。 */
  onBackgroundChanged?: () => void;

  /**
   * reply は state が done のときだけ使う（ほかの状態では前の返事を消す）。
   * turn は done になったときに 1 つ増やす。done が続いても、前の done の後に main のスレッドの動き（作業中・本文）が
   * あれば数える（UserPromptSubmit の来ないターン）。動きの無い done の繰り返しは数えない。
   * background: 動いているバックグラウンドのサブエージェントとコマンドの数（undefined なら変えない）。
   */
  set(
    pane: string,
    state: string,
    sessionId: string | undefined,
    cwd: string | undefined,
    agent = "claude",
    reply?: string,
    background?: BackgroundCounts
  ): void {
    const e: PaneEntry = this.entries.get(pane) ?? {
      pane,
      agent,
      state: "idle",
      turn: this.turnFloor.get(pane) ?? 0,
      backgroundAgents: 0,
      backgroundOnlyAgents: 0,
      backgroundShells: 0,
      updatedAt: Date.now()
    };
    const wasState = e.state;
    const wasAgents = e.backgroundAgents;
    const wasOnly = e.backgroundOnlyAgents;
    const wasSession = e.sessionId;
    const finished = state === "done" && (e.state !== "done" || this.active.has(pane));
    if (state === "working") this.active.add(pane);
    else if (state !== "attention") this.active.delete(pane);
    const counts = background ?? { agents: e.backgroundAgents, shells: e.backgroundShells };
    const onlyAgents = counts.onlyAgents ?? e.backgroundOnlyAgents;
    const countsChanged = counts.agents !== e.backgroundAgents || counts.shells !== e.backgroundShells || onlyAgents !== e.backgroundOnlyAgents;
    // 同じ状態の繰り返し（ツールごとの working、動きの無い done の重複）は知らせない。
    const same = e.state === state && e.sessionId === sessionId && e.agent === agent && !finished;
    if (same && !countsChanged) return;
    if (!same) {
      if (finished) e.turn += 1;
      e.state = state;
      e.sessionId = sessionId;
      e.agent = agent;
      if (state === "done" && reply) e.reply = clip(reply, REPLY_LIMIT);
      else delete e.reply;
      if (cwd) e.cwd = cwd;
      e.updatedAt = Date.now();
    }
    e.backgroundAgents = counts.agents;
    e.backgroundOnlyAgents = onlyAgents;
    e.backgroundShells = counts.shells;
    this.entries.set(pane, e);
    this.turnFloor.delete(pane);
    this.bump();
    if (e.state !== wasState || e.backgroundAgents !== wasAgents || e.backgroundOnlyAgents !== wasOnly || e.sessionId !== wasSession) this.onBackgroundChanged?.();
  }

  /**
   * 状態は変えずに書く（同じ会話のペインだけ）。activity: main のスレッドの動き（本文だけのターンも、次の Stop の done を
   * 1 回に数える）。background: 動いているバックグラウンドの作業の数（変わったときだけ知らせる）。
   */
  note(pane: string, sessionId: string | undefined, opts: { activity?: boolean; background?: BackgroundCounts } = {}): void {
    const e = this.entries.get(pane);
    if (!e || e.sessionId !== sessionId) return;
    if (opts.activity) this.active.add(pane);
    const b = opts.background;
    if (!b) return;
    const onlyAgents = b.onlyAgents ?? e.backgroundOnlyAgents;
    if (b.agents === e.backgroundAgents && b.shells === e.backgroundShells && onlyAgents === e.backgroundOnlyAgents) return;
    const countChanged = b.agents !== e.backgroundAgents || onlyAgents !== e.backgroundOnlyAgents;
    e.backgroundAgents = b.agents;
    e.backgroundOnlyAgents = onlyAgents;
    e.backgroundShells = b.shells;
    this.bump();
    if (countChanged) this.onBackgroundChanged?.();
  }

  /**
   * Live Activity の数（sessionId または pane:<pane> → 数）。state が working / attention なら backgroundOnlyAgents
   * （main のターンの間は前景のサブエージェントを数えない）、ほかは backgroundAgents。シェルは数えない。
   */
  liveActivityCounts(): Record<string, number> {
    const out: Record<string, number> = {};
    for (const e of this.entries.values()) {
      const n = e.state === "working" || e.state === "attention" ? e.backgroundOnlyAgents : e.backgroundAgents;
      if (n <= 0) continue;
      const key = e.sessionId ?? `pane:${e.pane}`;
      out[key] = Math.max(out[key] ?? 0, n);
    }
    return out;
  }

  /** そのペインの今の状態。別の会話のものなら undefined。 */
  state(pane: string, sessionId: string | undefined): string | undefined {
    const e = this.entries.get(pane);
    return e && e.sessionId === sessionId ? e.state : undefined;
  }

  /** そのペインの今の状態（会話は問わない。/terminal/share/panes の state）。 */
  stateOfPane(pane: string): string | undefined {
    return this.entries.get(pane)?.state;
  }

  /** claude が終わった（SessionEnd / プロセスが消えた）。そのペインはただのシェルに戻る。turn は残し、
   *  同じペインで次に動く会話はその続きから数える。 */
  remove(pane: string, sessionId: string): void {
    const e = this.entries.get(pane);
    if (!e || e.sessionId !== sessionId) return;
    this.entries.delete(pane);
    this.active.delete(pane);
    this.turnFloor.set(pane, e.turn);
    if (this.turnFloor.size > TURN_FLOOR_LIMIT) {
      const old = [...this.turnFloor.keys()].find((k) => k !== pane);
      if (old !== undefined) this.turnFloor.delete(old);
    }
    this.bump();
    if (e.backgroundAgents > 0 || e.backgroundOnlyAgents > 0) this.onBackgroundChanged?.();
  }

  /** version が since から変わるまで待つ（最長 timeoutMs）。 */
  async poll(since: number, timeoutMs: number): Promise<{ version: number; panes: PaneEntry[] }> {
    if (this.version === since) {
      await new Promise<void>((resolve) => {
        const done = (): void => {
          clearTimeout(timer);
          this.waiters.delete(done);
          resolve();
        };
        const timer = setTimeout(done, timeoutMs);
        this.waiters.add(done);
      });
    }
    return { version: this.version, panes: [...this.entries.values()] };
  }

  private bump(): void {
    this.version += 1;
    const waiters = [...this.waiters];
    this.waiters.clear();
    for (const w of waiters) w();
  }
}
