/**
 * サブエージェント（Claude の Agent / Task、Codex の spawnAgent、OpenCode の task、Hermes の delegate_task 等）と
 * バックグラウンドのコマンドの進行を、dynamic workflow と同じ workflow_progress の形に正規化する
 * （mac-bridge の SubagentTracker.swift と同じ振る舞い。同じ入力から同じ JSON を出す）。
 * iPhone・Android・デスクトップは taskId = "subagents" の 1 枚のデータを、サブエージェントとバックグラウンドの
 * コマンドの 2 枚のカードとして描く。形と規則は docs/BACKGROUND_WORK_2026-10-21.md §3.1・§3.2。
 *
 * 入力は 2 系統ある（どちらも実測。claude 2.1.300）:
 *   spawn（stream-json）: system/task_started・task_progress・task_updated・task_notification・background_tasks_changed、
 *                         assistant 行の tool_use、Agent の tool_result（async_launched）。キーは task_id
 *   ターミナル（hooks）  : SubagentStart / SubagentStop、agent_id 付きの PreToolUse、PostToolUse（Agent / Bash / Monitor /
 *                         TaskStop）、Stop の background_tasks、task-notification の発話。キーは agent_id（task_id と同じ値）
 * Agent は既定でバックグラウンドで動き、最初の result（Stop）はその完了を待たない。終わると CLI が知らせのターンを始める。
 * 前景の Bash も 2〜5 秒を超えるとタスクになるが、行にするのは裏で動くものだけ（rowKind = shell。Monitor を含む）。
 *
 * 行の終わり方は done / failed / stopped。止めたもの（TaskStop・interrupt・後片付け）は stopped、本当の失敗だけが failed。
 * 同じ実行の中で failed / stopped を done に戻さない（再開は begin と、同じ task_id の task_started だけ）。
 */

import crypto from "node:crypto";

type Obj = Record<string, unknown>;

export type RowKind = "agent" | "shell";

interface Agent {
  index: number;
  /** CLI の識別子（task_id / agent_id / tool_use id / 子 thread id など。行のキー） */
  id: string;
  /** agent（サブエージェント）/ shell（バックグラウンドのコマンド。Monitor を含む） */
  rowKind: RowKind;
  label: string;
  /** label が既定文（説明が無い）。新しいアプリは自分の言語の既定文を出す。 */
  labelIsFallback: boolean;
  /** 委任の中身がタスクの配列のときの件数（既定文「{n} 件のタスク」用） */
  taskCount?: number;
  agentType?: string;
  /** running / done / failed / stopped */
  state: string;
  /** shell の行を起こしたツール（Bash / Monitor / exec など）と、そのコマンド（1 行、200 字まで） */
  tool?: string;
  command?: string;
  /** サブエージェントが起こしたシェルなら、親の行の id */
  parentId?: string;
  /** ターンより長く動く作業か（バックグラウンドのサブエージェント、run_in_background のシェル）。分からなければ undefined。 */
  background?: boolean;
  model?: string;
  tokens?: number;
  toolCalls?: number;
  durationMs?: number;
  /** durationMs が終わりの usage の duration_ms（いちばん確か。end_time や今の時刻で上書きしない） */
  exactDuration: boolean;
  /** 実行中は今やっていること、終わったら結果の冒頭。 */
  preview?: string;
  /** 作業の文・結果を消した行（アプリは届いた項目だけを上書きするので、空文字を送って持っている前の値を消させる）。 */
  clearedPreview?: boolean;
  clearedResult?: boolean;
  /** 終わった行の結果の本文（2000 字まで） */
  result?: string;
  startedAt: number;
  endedAt?: number;
  /** stream-json の run_id。再開すると変わる（前の実行の遅れて届いた行と見分ける） */
  runId?: string;
  /** 以下の 3 つは内部の項目（payload には stoppable だけを出す）。stream-json の task_type（hooks の行には入れない） */
  taskType?: string;
  /** 止める手がかりがある（Claude は claudeStopTask と taskType、Codex・OpenCode は setStopHandle） */
  stopHandle?: boolean;
  /** 停止を CLI に出して返事を待っている */
  stopRequested?: boolean;
}

/** beginStop の結果。ok のとき stopRequested を立てて payload を返す。 */
export type BeginStopResult =
  | { kind: "ok"; rowKind: RowKind; payload: string }
  | { kind: "notRunning" }
  | { kind: "unsupported" }
  | { kind: "inFlight" };

/** hooks: Agent / SendMessage の PreToolUse で受けた起動。SubagentStart（agent_type しか持たない）で引き当てる。 */
interface Launch {
  toolUseId?: string;
  agentType?: string;
  description: string;
  /** SendMessage の宛先。その id の SubagentStart とだけ突き合わせる。 */
  to?: string;
}

/** background_tasks（hooks の Stop。type は表示名）と background_tasks_changed（stream-json。task_type は内部名）の 1 件。 */
interface Listed {
  id: string;
  rowKind: RowKind;
  agentType?: string;
  label?: string;
  tool?: string;
  command?: string;
  parentId?: string;
  runId?: string;
  /** stream-json の task_type（background_tasks_changed の一覧だけ。hooks の一覧では入れない） */
  taskType?: string;
}

/** begin で分かったことを足す項目。rowKind は行を作るときだけ使う。 */
export interface BeginOptions {
  agentType?: string;
  model?: string;
  toolUseId?: string;
  background?: boolean;
  rowKind?: RowKind;
  tool?: string;
  command?: string;
  labelIsFallback?: boolean;
  taskCount?: number;
  /** 行を作る（か、終わった行を開き直す）ときの開始時刻（ミリ秒か Date）。CLI が開始時刻を知っているときだけ渡す。無ければ今。 */
  startedAt?: number | Date;
}

export interface AbandonOptions {
  /** 既定は stopped（自分で止めた）。プロセスが異常終了したときだけ failed。 */
  state?: string;
  /** false ではバックグラウンドのシェルを閉じない */
  includeShells?: boolean;
  /** true（Esc の中断）では background != true の行だけを閉じる（バックグラウンドのサブエージェントは Esc では止まらない） */
  onlyForeground?: boolean;
  /** 閉じない鍵（OpenClaw の委任の行は ACP プロセスが落ちても台帳を見続ける） */
  except?: ReadonlySet<string>;
}

/** 委任ツールの説明と種類。説明が無ければ label は空か「{n} 件のタスク」で、labelIsFallback が true。 */
export interface Delegation {
  label: string;
  agentType?: string;
  labelIsFallback: boolean;
  taskCount?: number;
}

/**
 * <task-notification> の 1 件。サブエージェントは <result>（最後の返事）と <usage> を持つ。
 * <summary> はサブエージェントなら「Agent "…" finished」、シェルなら「Background command "…" completed (exit code 0)」。
 */
export interface TaskNotification {
  taskId: string;
  status: string;
  summary?: string;
  result?: string;
  tokens?: number;
  toolUses?: number;
  durationMs?: number;
}

const asObj = (v: unknown): Obj | undefined => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : undefined);
const asStr = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const asBool = (v: unknown): boolean | undefined => (typeof v === "boolean" ? v : undefined);
/** 要素が全部オブジェクトの配列（mac の as? [[String: Any]] と同じく、1 つでも違えば undefined）。 */
const asObjs = (v: unknown): Obj[] | undefined => (Array.isArray(v) && v.every((x) => asObj(x) !== undefined) ? (v as Obj[]) : undefined);
const nonEmpty = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const isDefined = <T>(v: T | undefined): v is T => v !== undefined;
/** 数値（小数は切り捨て。mac の Int(Double) と同じ）。 */
const int = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : undefined);
/** 10 進の整数の文字列（mac の Int(String) と同じ）。 */
const intText = (s: string | undefined): number | undefined => (s !== undefined && /^[+-]?\d+$/.test(s) ? Number(s) : undefined);
/** undefined の項目を落とす（比べやすいように）。 */
const compact = <T extends object>(o: T): T => Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as T;

/** 上限つきの覚え書き。古いものから捨てる（Map は入れた順を保つ。同じキーの上書きでは順を変えない）。 */
class Recent<V> {
  private readonly values = new Map<string, V>();

  constructor(private readonly limit: number) {}

  get(key: string): V | undefined {
    return this.values.get(key);
  }

  set(key: string, value: V): void {
    this.values.set(key, value);
    while (this.values.size > this.limit) this.values.delete(this.values.keys().next().value!);
  }

  remove(key: string): V | undefined {
    const v = this.values.get(key);
    this.values.delete(key);
    return v;
  }
}

export class SubagentTracker {
  static readonly taskId = "subagents";

  /**
   * トラッカーの世代（UUID 小文字）。payload にいつも入れる。アプリは epoch が変われば持っている行を捨ててから重ねる
   * （作り直したトラッカーの index 0 が、前の世代の index 0 の行の値を引き継がないように）。
   */
  readonly epoch = crypto.randomUUID().toLowerCase();

  private agents = new Map<string, Agent>();
  private nextIndex = 0;
  /** 親の tool_use id → サブエージェントのキー（stream-json のサブエージェント行は parent_tool_use_id を持つ）。 */
  private keyByToolUseId = new Map<string, string>();
  /**
   * stream-json: assistant 行の tool_use（id → ツール名とコマンド）。task_started.tool_use_id から Monitor
   * （task_type は local_bash）を見分け、shell の行の tool と command を埋める。
   */
  private toolUses = new Recent<{ name: string; command?: string }>(128);
  /**
   * stream-json: 前景のシェルの task_started（2〜5 秒を超えた普通の Bash もタスクになる）。行にはせず、
   * 後で裏に回ったら（task_updated の is_backgrounded・background_tasks_changed に載る）行にする。
   */
  private foregroundTasks = new Recent<Obj>(32);
  /** stream-json: dynamic workflow（local_workflow か workflow_name 付き）の task_id。workflow のカードが出すので行にしない。 */
  private workflowTasks = new Set<string>();
  private pendingLaunches: Launch[] = [];
  /** hooks: run_in_background で起動したツールの説明（tool_use id → 行の見出し）。PostToolUse の backgroundTaskId で引き当てる。 */
  private pendingShells = new Map<string, string>();
  /** hooks: 行にしない SubagentStart（内部の補助と、起動の PreToolUse を伴わないもの）。 */
  private ignored = new Set<string>();
  private claudeStop = false;

  get isEmpty(): boolean {
    return this.agents.size === 0;
  }

  get hasRunning(): boolean {
    return [...this.agents.values()].some((a) => a.state === "running");
  }

  /** 動いているサブエージェントがあるか（バックグラウンドのシェルは数えない）。ターンの終わりの扱いに使う。 */
  get hasRunningAgents(): boolean {
    return this.runningAgentCount > 0;
  }

  /** 動いているサブエージェントの行の数（ターミナル経路の workflow / teammate の行も含む）。 */
  get runningAgentCount(): number {
    return [...this.agents.values()].filter((a) => a.state === "running" && a.rowKind === "agent").length;
  }

  /** 動いていて background == true のサブエージェントの行の数（Live Activity の数え方。シェルは数えない）。 */
  get runningBackgroundOnlyAgentCount(): number {
    return [...this.agents.values()].filter((a) => a.state === "running" && a.rowKind === "agent" && a.background === true).length;
  }

  /** 動いているバックグラウンドのコマンドの行の数（Monitor を含む）。 */
  get runningShellCount(): number {
    return [...this.agents.values()].filter((a) => a.state === "running" && a.rowKind === "shell").length;
  }

  /**
   * stream-json で dynamic workflow（task_type = local_workflow か workflow_name 付き）として見た task_id か。
   * その task_* 行は workflow のカードに回す（このトラッカーでは行にしない）。
   */
  isWorkflowTask(taskId: string): boolean {
    return this.workflowTasks.has(taskId);
  }

  has(key: string): boolean {
    return this.agents.has(key);
  }

  // ---- 行ごとの停止 ----

  /** Claude の spawn 経路で TaskStop の control_request を出せるか。true の間、taskType が local_agent / local_bash の行に手がかりを立てる。 */
  get claudeStopTask(): boolean {
    return this.claudeStop;
  }

  /** claudeStopTask を変える。全行を計算し直し、変わった行があれば workflow_snapshot の payload を返す。 */
  setClaudeStopTask(on: boolean): string | undefined {
    if (this.claudeStop === on) return undefined;
    this.claudeStop = on;
    let changed = false;
    for (const a of this.agents.values()) {
      if (a.taskType === undefined) continue;
      const handle = on && isClaudeStoppable(a.taskType);
      if ((a.stopHandle ?? false) !== handle) {
        a.stopHandle = handle;
        changed = true;
      }
    }
    return changed ? this.snapshot() : undefined;
  }

  /** Codex・OpenCode が使う。行に止める手がかりがあるかを変え、変われば payload を返す。 */
  setStopHandle(key: string, on: boolean): string | undefined {
    const a = this.agents.get(key);
    if (!a || (a.stopHandle ?? false) === on) return undefined;
    a.stopHandle = on;
    return this.payload([a]);
  }

  /** 停止を始める。ok なら stopRequested を立てて payload を返す（返事を待つ間は stoppable: false）。 */
  beginStop(key: string): BeginStopResult {
    const a = this.agents.get(key);
    if (!a || a.state !== "running") return { kind: "notRunning" };
    if (a.stopRequested === true) return { kind: "inFlight" };
    if (a.stopHandle !== true) return { kind: "unsupported" };
    a.stopRequested = true;
    return { kind: "ok", rowKind: a.rowKind, payload: this.payload([a]) };
  }

  /** 停止が失敗したとき、返事待ちを戻す。変われば payload を返す。 */
  endStop(key: string): string | undefined {
    const a = this.agents.get(key);
    if (!a || a.stopRequested !== true) return undefined;
    a.stopRequested = false;
    return this.payload([a]);
  }

  isRunning(key: string): boolean {
    return this.agents.get(key)?.state === "running";
  }

  /** 行の state（running / done / failed / stopped）。行が無ければ undefined。 */
  stateOf(key: string): string | undefined {
    return this.agents.get(key)?.state;
  }

  isStopRequested(key: string): boolean {
    return this.agents.get(key)?.stopRequested === true;
  }

  /**
   * 新しいターンを始める前に、終わった行を忘れる（クライアントも送信で終わった行を捨てる）。
   * バックグラウンドで動き続けているものは残す。知らせのターンでは呼ばない（終わった結果をカードに残す）。
   */
  pruneFinished(): void {
    for (const [k, a] of this.agents) if (a.state !== "running") this.agents.delete(k);
    for (const [t, k] of this.keyByToolUseId) if (!this.agents.has(k)) this.keyByToolUseId.delete(t);
    this.pendingLaunches = [];
    this.pendingShells.clear();
    this.ignored.clear();
  }

  // ---- stream-json（spawn） ----

  /** system/task_* 行・background_tasks_changed・assistant 行・Agent の tool_result を反映する。変化があれば payload JSON を返す。 */
  ingestStreamLine(obj: Obj): string | undefined {
    switch (obj.type) {
      case "assistant":
        return this.ingestAssistant(obj);
      case "user":
        return this.ingestAsyncLaunch(obj);
      case "system":
        break;
      default:
        return undefined;
    }
    const subtype = asStr(obj.subtype);
    if (subtype === undefined) return undefined;
    // background_tasks_changed はトップレベルに task_id を持たない（tasks がその時点で動いているものの全部）。
    if (subtype === "background_tasks_changed") return this.ingestBackgroundTasks(obj.tasks);
    const key = nonEmpty(obj.task_id);
    if (key === undefined) return undefined;
    // workflow（local_workflow）は workflow のカードが別に出す。task_id を覚えて行にしない
    // （task_notification は task_type も workflow_name も持たないので、id で見分ける）。
    if (obj.task_type === "local_workflow" || obj.workflow_progress !== undefined || obj.workflow_name !== undefined) {
      this.workflowTasks.add(key);
      return undefined;
    }
    if (this.workflowTasks.has(key)) return undefined;
    switch (subtype) {
      case "task_started":
        return this.taskStarted(key, obj);
      case "task_progress":
        return this.taskProgress(key, obj);
      case "task_updated":
        return this.taskUpdated(key, obj);
      case "task_notification":
        return this.taskNotification(key, obj);
      default:
        return undefined;
    }
  }

  /**
   * assistant 行。tool_use は main もサブエージェントも覚え（task_started の tool_use_id から引く）、
   * サブエージェントの行ならモデルと、いま呼んだツールを拾う。
   */
  private ingestAssistant(obj: Obj): string | undefined {
    const message = asObj(obj.message);
    if (!message) return undefined;
    const uses = (asObjs(message.content) ?? []).filter((b) => b.type === "tool_use");
    for (const block of uses) {
      const id = nonEmpty(block.id);
      const name = nonEmpty(block.name);
      if (id === undefined || name === undefined) continue;
      const command = nonEmpty(asObj(block.input)?.command);
      this.toolUses.set(id, { name, command: command !== undefined ? preview(command, 200) : undefined });
    }
    const parent = asStr(obj.parent_tool_use_id);
    const key = parent !== undefined ? this.keyByToolUseId.get(parent) : undefined;
    const a = key !== undefined ? this.agents.get(key) : undefined;
    if (!a || a.state !== "running") return undefined;
    let changed = false;
    const m = nonEmpty(message.model);
    if (m !== undefined && a.model !== m) {
      a.model = m;
      changed = true;
    }
    for (const block of uses) {
      a.preview = toolActivity(asStr(block.name) ?? "tool", block.input);
      changed = true;
    }
    return changed ? this.payload([a]) : undefined;
  }

  /** main の user 行の Agent の tool_result（tool_use_result.status = async_launched）。その id の行をバックグラウンドにする。 */
  private ingestAsyncLaunch(obj: Obj): string | undefined {
    const r = asObj(obj.tool_use_result);
    const id = nonEmpty(r?.agentId);
    if (typeof obj.parent_tool_use_id === "string" || !r || r.status !== "async_launched" || id === undefined) return undefined;
    const toolUseId = asStr(asObjs(asObj(obj.message)?.content)?.find((b) => b.type === "tool_result")?.tool_use_id);
    return this.bindAsyncLaunch(id, nonEmpty(r.description), undefined, nonEmpty(r.resolvedModel), toolUseId);
  }

  /**
   * task_started。サブエージェント（local_agent か subagent_type）は前景・バックグラウンドに関係なく行にし、
   * シェル（local_bash・monitor_*・mcp_task）は裏で動くものだけを行にする（前景のものは id だけ覚えておく）。
   * 既にある行に来たら（run_id が違う・終わっている）再開とみなし、やり直す。
   */
  private taskStarted(key: string, obj: Obj): string | undefined {
    const taskType = asStr(obj.task_type);
    const isAgent = taskType === "local_agent" || obj.subagent_type !== undefined;
    if (!isAgent && !isShellTask(taskType)) return undefined;
    if (!isAgent && !this.agents.has(key) && obj.is_backgrounded === false) {
      this.foregroundTasks.set(key, obj);
      return undefined;
    }
    const runId = asStr(obj.run_id);
    const current = this.agents.get(key);
    if (current && current.state === "running" && runId !== undefined && current.runId !== undefined && runId !== current.runId) {
      this.restart(key);
    }
    const toolUseId = asStr(obj.tool_use_id);
    const use = toolUseId !== undefined ? this.toolUses.get(toolUseId) : undefined;
    const command = asStr(obj.command);
    const label = asStr(obj.description) ?? (command !== undefined ? preview(command, 80) : undefined);
    this.begin(key, label, {
      agentType: isAgent ? asStr(obj.subagent_type) : undefined,
      toolUseId,
      background: isAgent ? asBool(obj.is_backgrounded) : true,
      rowKind: isAgent ? "agent" : "shell",
      tool: isAgent ? undefined : use?.name,
      command: isAgent ? undefined : (use?.command ?? command)
    });
    const a = this.agents.get(key)!;
    if (runId !== undefined) a.runId = runId;
    if (taskType !== undefined) this.noteTaskType(a, taskType);
    const parent = nonEmpty(obj.parent_task_id);
    if (!isAgent && parent !== undefined) a.parentId = parent;
    return this.payload([a]);
  }

  private taskProgress(key: string, obj: Obj): string | undefined {
    const a = this.agents.get(key);
    if (!a || a.state !== "running" || !sameRun(a, obj)) return undefined;
    const d = nonEmpty(obj.description);
    const t = nonEmpty(obj.last_tool_name);
    if (d !== undefined) a.preview = preview(d);
    else if (t !== undefined) a.preview = t;
    applyUsage(obj.usage, a, false);
    return this.payload([a]);
  }

  /**
   * task_updated。patch.status（completed / failed / killed）で閉じ、patch.end_time を終わった時刻と所要時間にする。
   * patch.is_backgrounded == true なら、前景で覚えていたシェルを行にする（後から裏に回された）。
   */
  private taskUpdated(key: string, obj: Obj): string | undefined {
    const patch = asObj(obj.patch) ?? {};
    const status = asStr(patch.status);
    const a = this.agents.get(key);
    if (!a) {
      const started = this.foregroundTasks.get(key);
      if (!started) return undefined;
      if (status !== undefined && finalState(status) !== undefined) {
        this.foregroundTasks.remove(key);
        return undefined;
      }
      if (patch.is_backgrounded !== true) return undefined;
      this.foregroundTasks.remove(key);
      return this.taskStarted(key, { ...started, is_backgrounded: true });
    }
    if (!sameRun(a, obj)) return undefined;
    const before = { ...a };
    if (patch.is_backgrounded === true) a.background = true;
    const end = int(patch.end_time);
    if (status !== undefined) this.settle(key, status, undefined, end);
    // 終わりの知らせ（task_notification）が先に来ていても、end_time の方が正確。
    if (end !== undefined && a.state !== "running") {
      a.endedAt = end;
      if (!a.exactDuration) a.durationMs = msBetween(a.startedAt, end);
    }
    return sameAgent(a, before) ? undefined : this.payload([a]);
  }

  /** task_notification。status（completed / failed / stopped）で閉じ、summary を結果に、usage を数値にする。 */
  private taskNotification(key: string, obj: Obj): string | undefined {
    const a = this.agents.get(key);
    if (!a) {
      this.foregroundTasks.remove(key); // 前景のまま終わったシェル
      return undefined;
    }
    if (!sameRun(a, obj)) return undefined;
    const before = { ...a };
    const summary = informative(asStr(obj.summary), before.label);
    this.settle(key, asStr(obj.status) ?? "completed", summary);
    applyUsage(obj.usage, a, true);
    return sameAgent(a, before) ? undefined : this.payload([a]);
  }

  /**
   * system/background_tasks_changed（その時点で動いているバックグラウンドのタスクの全部。終われば []）。
   * 知らないものは行を作り、background == true で動いているのに載っていない行は done で閉じる。前景の行は閉じない。
   */
  private ingestBackgroundTasks(raw: unknown): string | undefined {
    const tasks = asObjs(raw);
    if (!tasks) return undefined;
    const items: Listed[] = [];
    for (const t of tasks) {
      const id = nonEmpty(t.task_id);
      if (t.task_type === "local_workflow" && id !== undefined) {
        this.workflowTasks.add(id);
        continue;
      }
      const item = listed(t);
      if (item && !this.workflowTasks.has(item.id)) items.push({ ...item, taskType: nonEmpty(t.task_type) });
    }
    return this.reconcileListed(items, new Set(tasks.map(listedId).filter(isDefined)), false);
  }

  // ---- hooks（ターミナル） ----

  /**
   * 親（agent_id の無い）PreToolUse。Agent / Task ツールと、止まったサブエージェントに話しかけ直す SendMessage は
   * 説明を SubagentStart まで、run_in_background なら PostToolUse まで取っておく。
   */
  noteLaunch(toolName: string, input: unknown, toolUseId?: string): void {
    const d = asObj(input);
    if (toolUseId !== undefined && d?.run_in_background === true && !isAgentTool(toolName)) {
      this.pendingShells.set(toolUseId, nonEmpty(d.description) ?? toolActivity(toolName, input));
      if (this.pendingShells.size > 20) this.pendingShells.delete(this.pendingShells.keys().next().value!);
      return;
    }
    const to = toolName === "SendMessage" ? nonEmpty(d?.to) : undefined;
    if (isAgentTool(toolName)) {
      this.pendingLaunches.push({ toolUseId, agentType: nonEmpty(d?.subagent_type), description: nonEmpty(d?.description) ?? "" });
    } else if (to !== undefined) {
      // 動いている相手への SendMessage は次のツールの区切りで届くだけで、SubagentStart は来ない。積まない。
      if (this.agents.get(to)?.state === "running") return;
      const message = nonEmpty(d?.message);
      const description = nonEmpty(d?.summary) ?? (message !== undefined ? preview(message, 80) : "");
      this.pendingLaunches = this.pendingLaunches.filter((l) => l.to !== to);
      this.pendingLaunches.push({ toolUseId, description, to });
    } else {
      return;
    }
    if (this.pendingLaunches.length > 20) this.pendingLaunches.shift();
  }

  /** 行にしない SubagentStart の agent_id か（そのツール呼び出しも親の行に出さない）。 */
  isIgnored(agentId: string): boolean {
    return this.ignored.has(agentId);
  }

  hookStart(agentId: string, agentType?: string): string | undefined {
    // 内部の補助（agent_type が空か無い）は行にしない。
    if (isInternalHelper(agentId, agentType)) {
      this.ignored.add(agentId);
      return undefined;
    }
    // 知っている行（PostToolUse(Agent) が先に来た・話しかけ直された）は、起動待ちを使わずに続きとして動かす。
    if (this.agents.has(agentId)) {
      this.pendingLaunches = this.pendingLaunches.filter((l) => l.to !== agentId);
      return this.begin(agentId, undefined, { agentType });
    }
    // SendMessage は宛先の id とだけ、Agent は同じ種類のうち一番古い起動と突き合わせる
    // （並列起動でも PreToolUse → SubagentStart の順は保たれる。ずれたら PostToolUse(Agent) で直す）。
    let i = this.pendingLaunches.findIndex((l) => l.to === agentId);
    if (i < 0) i = this.pendingLaunches.findIndex((l) => l.to === undefined && (l.agentType === undefined || l.agentType === agentType));
    if (i < 0) {
      // 起動の PreToolUse を伴わないもの（Skill の fork 等）は、まだ出さない。
      // 本物なら PostToolUse(Agent) か Stop の background_tasks で拾い直す。
      this.ignored.add(agentId);
      return undefined;
    }
    const [launch] = this.pendingLaunches.splice(i, 1);
    return this.begin(agentId, launch.description, { agentType });
  }

  /**
   * PostToolUse（main のスレッド）。バックグラウンドで起動したもの（Bash の backgroundTaskId・Monitor の taskId）は行を作る。
   * Agent の async_launched は agentId の行に説明と種類を結び付け、TaskStop は止めた行をすぐ stopped で閉じる
   * （止めたシェルには完了の知らせが来ない）。
   */
  hookToolResult(toolUseId: string | undefined, toolName: string, input: unknown, response: unknown): string | undefined {
    const pending = toolUseId !== undefined ? this.pendingShells.get(toolUseId) : undefined;
    if (toolUseId !== undefined) this.pendingShells.delete(toolUseId);
    const d = asObj(input);
    const r = asObj(response);
    if (isAgentTool(toolName)) {
      const id = nonEmpty(r?.agentId);
      if (r?.status !== "async_launched" || id === undefined) return undefined;
      return this.bindAsyncLaunch(id, nonEmpty(d?.description) ?? nonEmpty(r?.description), nonEmpty(d?.subagent_type), nonEmpty(r?.resolvedModel), toolUseId);
    }
    if (toolName === "TaskStop" || toolName === "KillShell") {
      const id = nonEmpty(r?.task_id) ?? nonEmpty(d?.task_id) ?? nonEmpty(d?.shell_id);
      return id !== undefined ? this.finish(id, "stopped") : undefined;
    }
    const id = toolName === "Monitor" ? nonEmpty(r?.taskId) : nonEmpty(r?.backgroundTaskId);
    if (id === undefined) return undefined;
    const label = pending ?? nonEmpty(d?.description) ?? toolActivity(toolName, input);
    return this.begin(id, label, { background: true, rowKind: "shell", tool: toolName, command: nonEmpty(d?.command) });
  }

  /**
   * バックグラウンドで起動した Agent（PostToolUse / tool_result の async_launched と agentId）を、その id の行に結び付ける。
   * SubagentStart より先に来ることがあるので、行が無ければ作る。起動待ちは tool_use id で消す。
   */
  private bindAsyncLaunch(
    agentId: string,
    description: string | undefined,
    agentType: string | undefined,
    model: string | undefined,
    toolUseId: string | undefined
  ): string | undefined {
    if (toolUseId !== undefined) this.pendingLaunches = this.pendingLaunches.filter((l) => l.toolUseId !== toolUseId);
    this.ignored.delete(agentId);
    const a = this.agents.get(agentId);
    if (!a) return this.begin(agentId, description, { agentType, model, background: true });
    const before = { ...a };
    fill(a, description, { agentType, model: a.model === undefined ? model : undefined, background: true });
    return sameAgent(a, before) ? undefined : this.payload([a]);
  }

  /**
   * 完了の知らせ（<task-notification> … </task-notification>。発話として届くか、transcript に積まれる）。
   * 知っている行を閉じ、<result>（無ければ <summary>）を結果に、<usage> を数値にする。変化した行の payload を返す。
   */
  ingestNotifications(text: string): string[] {
    if (!text.includes("<task-notification>")) return [];
    const out: string[] = [];
    for (const n of taskNotifications(text)) {
      const a = this.agents.get(n.taskId);
      if (!a) continue;
      const before = { ...a };
      // <summary> はサブエージェントだと「Agent "…" finished」の決まり文句。既に結果のある終わった行は上書きしない。
      const summary = before.state !== "running" && before.preview !== undefined ? undefined : informative(n.summary, before.label);
      this.settle(n.taskId, finalState(n.status) ?? "done", n.result ?? summary);
      if (n.tokens !== undefined) a.tokens = n.tokens;
      if (n.toolUses !== undefined) a.toolCalls = n.toolUses;
      if (n.durationMs !== undefined) {
        a.durationMs = n.durationMs;
        a.exactDuration = true;
      }
      if (!sameAgent(a, before)) out.push(this.payload([a]));
    }
    return out;
  }

  /**
   * Stop hook の background_tasks（その時点で動いている・待っているバックグラウンドの作業の全部）と突き合わせる。
   * 知らないものは行を作り（種類は完全一致で振り分ける）、一覧に無い実行中の行はサブエージェントもシェルも done で閉じる
   * （終わりの知らせを取りこぼしても残らない）。照合に使うのは Stop の一覧だけ（SubagentStop の一覧は、終わった
   * サブエージェント自身を running のまま含む）。closeForeground = false では background != true の行を閉じない。
   */
  reconcile(raw: unknown, opts: { closeForeground?: boolean } = {}): string | undefined {
    const tasks = asObjs(raw);
    if (!tasks) return undefined;
    return this.reconcileListed(tasks.map(listed).filter(isDefined), new Set(tasks.map(listedId).filter(isDefined)), opts.closeForeground ?? true);
  }

  private reconcileListed(items: Listed[], present: Set<string>, closeForeground: boolean): string | undefined {
    const changed: string[] = [];
    for (const t of items) {
      const a = this.agents.get(t.id);
      if (a) {
        const before = { ...a };
        if (t.runId !== undefined && before.runId !== undefined && t.runId !== before.runId) {
          // 同じ task_id が新しい run_id で載った（終わったサブエージェントの再開）。
          this.restart(t.id);
          a.runId = t.runId;
        }
        // 一覧に載るのは裏で動くものだけ。
        if (a.state === "running") a.background = true;
        if (t.taskType !== undefined) this.noteTaskType(a, t.taskType);
        if (!sameAgent(a, before)) changed.push(t.id);
        continue;
      }
      this.ignored.delete(t.id);
      const started = this.foregroundTasks.remove(t.id);
      if (started) {
        // 前景で覚えていたシェルが裏に回った。task_started の中身（ツール・コマンド・親）を使う。
        this.taskStarted(t.id, { ...started, is_backgrounded: true });
      } else {
        this.begin(t.id, t.label, { agentType: t.agentType, background: true, rowKind: t.rowKind, tool: t.tool, command: t.command });
        const row = this.agents.get(t.id)!;
        if (t.runId !== undefined) row.runId = t.runId;
        if (t.rowKind === "shell" && t.parentId !== undefined) row.parentId = t.parentId;
        if (t.taskType !== undefined) this.noteTaskType(row, t.taskType);
      }
      if (this.agents.has(t.id)) changed.push(t.id);
    }
    for (const [key, a] of [...this.agents]) {
      if (a.state !== "running" || present.has(key) || !(closeForeground || a.background === true)) continue;
      if (this.settle(key, "done")) changed.push(key);
    }
    if (changed.length === 0) return undefined;
    return this.payload(changed.map((k) => this.agents.get(k)).filter(isDefined).sort((x, y) => x.index - y.index));
  }

  /**
   * サブエージェントの中で呼ばれたツール。SubagentStart を受けていないもの（hook が古い install 等）は
   * 行を作らない（終わりの SubagentStop も来ないので、行が「実行中」のまま残る）。呼び出し側は has で
   * 確かめて、知らないものは今までどおり親のツール行として出す。
   */
  hookTool(agentId: string, toolName: string, input: unknown): string | undefined {
    return this.activity(agentId, toolActivity(toolName, input), { toolCall: true });
  }

  hookStop(agentId: string, _agentType: string | undefined, lastMessage: string | undefined): string | undefined {
    // 行にしていない補助と、SubagentStart を受けていないもの（hook が古い install 等）は出さない。
    if (!this.agents.has(agentId)) {
      this.ignored.delete(agentId);
      return undefined;
    }
    // Esc で stopped にした行は done に戻さない（finish が受けない）。
    return this.finish(agentId, "done", lastMessage);
  }

  /**
   * 中断・プロセス終了・close で、もう終わりの知らせが来ない実行中の行を閉じる。既定は stopped（自分で止めた）。
   * プロセスが異常終了したときだけ state: "failed" を渡す。閉じた行があれば payload を返す（index は使い回さない）。
   * includeShells = false ではバックグラウンドのシェルを閉じない。onlyForeground = true（Esc の中断）では
   * background != true の行だけを閉じる（バックグラウンドのサブエージェントは Esc では止まらない）。
   */
  abandonRunning(opts?: AbandonOptions): string | undefined;
  /** 古い呼び方（includeShells だけ）。閉じた行は stopped。 */
  abandonRunning(includeShells: boolean): string | undefined;
  abandonRunning(arg: AbandonOptions | boolean = {}): string | undefined {
    const o: AbandonOptions = typeof arg === "boolean" ? { includeShells: arg } : arg;
    const { state = "stopped", includeShells = true, onlyForeground = false, except } = o;
    const keys = [...this.agents.values()]
      .filter((a) => a.state === "running" && (includeShells || a.rowKind === "agent") && !(onlyForeground && a.background === true) && !except?.has(a.id))
      .map((a) => a.id);
    const closed = keys.filter((k) => this.settle(k, state)).map((k) => this.agents.get(k)!);
    return closed.length > 0 ? this.payload(closed.sort((x, y) => x.index - y.index)) : undefined;
  }

  // ---- 汎用（Codex / OpenCode / ACP 等。キーは各 CLI のサブエージェント識別子） ----

  /**
   * 行の開始。既にあれば分かったことを足す（rowKind は作るときだけ）。終わっていた行（Codex の sendInput 等で
   * 話しかけ直された・再開した）は実行中に戻し、開始時刻をやり直して、所要時間・作業の文・結果を消す。
   * labelIsFallback = true の label（「3 件のタスク」等）は、説明の入った label を上書きしない。
   */
  begin(key: string, label?: string, opts?: BeginOptions): string | undefined;
  /** 古い呼び方（位置引数）。 */
  begin(key: string, label: string | undefined, agentType: string | undefined, model?: string, toolUseId?: string, rowKind?: RowKind): string | undefined;
  begin(key: string, label?: string, third?: BeginOptions | string, model?: string, toolUseId?: string, rowKind?: RowKind): string | undefined {
    const o: BeginOptions = typeof third === "object" ? third : { agentType: third, model, toolUseId, rowKind };
    if (o.toolUseId !== undefined) this.keyByToolUseId.set(o.toolUseId, key);
    const startedAt = o.startedAt instanceof Date ? o.startedAt.getTime() : o.startedAt;
    let a = this.agents.get(key);
    if (!a) {
      const kind = o.rowKind ?? "agent";
      // 説明が無いときの既定文（古いアプリ向け。新しいアプリは labelIsFallback を見て自分の言語で出す）。
      a = {
        index: this.nextIndex++,
        id: key,
        rowKind: kind,
        label: kind === "shell" ? "バックグラウンドのコマンド" : "サブエージェント",
        labelIsFallback: true,
        state: "running",
        exactDuration: false,
        startedAt: startedAt ?? Date.now()
      };
      this.agents.set(key, a);
    } else if (a.state !== "running") {
      this.restart(key, startedAt);
    }
    fill(a, label, o);
    return this.payload([a]);
  }

  /** いまやっていること。toolCall なら呼び出し回数も数える。知らないキーか、終わった行なら undefined。 */
  activity(key: string, text?: string, opts: { toolCall?: boolean; toolCalls?: number; tokens?: number; model?: string } = {}): string | undefined {
    const a = this.agents.get(key);
    if (!a || a.state !== "running") return undefined;
    if (text) a.preview = preview(text, 120);
    if (opts.toolCall) a.toolCalls = (a.toolCalls ?? 0) + 1;
    if (opts.toolCalls !== undefined) a.toolCalls = opts.toolCalls;
    if (opts.tokens !== undefined) a.tokens = opts.tokens;
    if (opts.model) a.model = opts.model;
    a.durationMs = msBetween(a.startedAt, Date.now());
    return this.payload([a]);
  }

  /**
   * 終了。state は done / failed / stopped（completed・killed・interrupted 等の CLI の語も受ける）。
   * result は結果の本文（冒頭を resultPreview に、2000 字までを result に出す）。同じ実行の中で failed / stopped を
   * done に戻さない（done → failed / stopped は受ける。例: reconcile で閉じた後に届いた失敗の知らせ）。再開は begin だけ。
   * 変化が無ければ undefined。
   */
  finish(key: string, state: string, result?: string, durationMs?: number): string | undefined;
  /** 古い呼び方。failed でなければ done。 */
  finish(key: string, failed: boolean, result?: string): string | undefined;
  finish(key: string, state: string | boolean, result?: string, durationMs?: number): string | undefined {
    const target = typeof state === "boolean" ? (state ? "failed" : "done") : state;
    const a = this.agents.get(key);
    const before = a ? { ...a } : undefined;
    const changed = this.settle(key, target, result);
    // CLI が所要時間を知らせているとき（Codex の durationMs）は、計算した値より正確なのでそれを残す。
    if (a && durationMs !== undefined && a.state !== "running") {
      a.durationMs = durationMs;
      a.exactDuration = true;
    }
    return a && (changed || (before !== undefined && !sameAgent(a, before))) ? this.payload([a]) : undefined;
  }

  /**
   * Claude 互換 stream-json で task_* 行を出さない CLI（Cursor 等）向け。親の assistant 行の
   * Task / Agent の tool_use を開始、その tool_result を終了とみなす（キーは tool_use id）。
   * 子の行（parent_tool_use_id 付き）は ingestStreamLine が拾う。
   */
  ingestToolUseLine(obj: Obj): string[] {
    const content = asObjs(asObj(obj.message)?.content);
    if (typeof obj.parent_tool_use_id === "string" || !content) return [];
    const out: string[] = [];
    if (obj.type === "assistant") {
      for (const block of content) {
        if (block.type !== "tool_use") continue;
        const id = asStr(block.id);
        const d = delegation(asStr(block.name) ?? "", undefined, block.input);
        if (id === undefined || !d) continue;
        const p = this.begin(id, d.label, { agentType: d.agentType, toolUseId: id, labelIsFallback: d.labelIsFallback, taskCount: d.taskCount });
        if (p) out.push(p);
      }
    } else if (obj.type === "user") {
      for (const block of content) {
        if (block.type !== "tool_result") continue;
        const id = asStr(block.tool_use_id);
        if (id === undefined || !this.agents.has(id)) continue;
        const text = asStr(block.content) ?? asObjs(block.content)?.map((c) => asStr(c.text)).filter(isDefined).join("\n");
        const p = this.finish(id, block.is_error === true, text);
        if (p) out.push(p);
      }
    }
    return out;
  }

  /**
   * ACP の session/update（tool_call / tool_call_update）。委任ツールならサブエージェントとして扱う。
   * opencode acp は pending の tool_call では title と rawInput が空で、in_progress の更新で届くので、そこで埋め直す。
   */
  ingestAcpUpdate(update: Obj, opts: { background?: boolean } = {}): string | undefined {
    const id = nonEmpty(update.toolCallId);
    if (id === undefined) return undefined;
    const status = asStr(update.status);
    const title = asStr(update.title);
    let p: string | undefined;
    switch (update.sessionUpdate) {
      case "tool_call": {
        const d = delegation(title ?? "", title, update.rawInput);
        if (!d) return undefined;
        p = this.begin(id, d.label, { agentType: d.agentType, labelIsFallback: d.labelIsFallback, taskCount: d.taskCount, background: opts.background });
        break;
      }
      case "tool_call_update": {
        const a = this.agents.get(id);
        if (!a) return undefined;
        if (a.state === "running" && (Boolean(title) || asObj(update.rawInput) !== undefined)) {
          const d = delegationLabel(title, update.rawInput);
          if (d.label || d.agentType !== undefined) {
            p = this.begin(id, d.label, { agentType: d.agentType, labelIsFallback: d.labelIsFallback, taskCount: d.taskCount, background: opts.background });
          }
        }
        break;
      }
      default:
        return undefined;
    }
    // 状態の無い更新は終わりではない（title・rawInput の埋め直しだけ。Grok は子が始まる前に届く）。
    if (status !== "completed" && status !== "failed") return p;
    const text = acpText(update.content);
    // opencode の task の出力（<task … state=…>）は中身を取り出す。running は裏で動く task の起動の返事。ACP は
    // 終わりの知らせ（親に差し込まれる synthetic な user の text part・子の idle）を転送しないので、後から閉じる印が
    // 来ない。実行中のまま残さず、起動の返事（summary）で閉じる（opencode serve の経路は idle で本当の終わりが分かる）。
    const task = text !== undefined ? parseTaskOutput(text) : undefined;
    if (task?.state === "running") return this.finish(id, "done", task.summary ?? task.result) ?? p;
    const failed = status === "failed" || (task?.state !== undefined && finalState(task.state) === "failed");
    const result = (task ? (task.result ?? task.summary) : undefined) ?? text;
    return this.finish(id, failed ? "failed" : "done", result) ?? p;
  }

  // ---- 共通 ----

  /** 終わった行（か、run_id の変わった行）を実行中に戻す。開始時刻をやり直し、所要時間・作業の文・結果を消す。 */
  private restart(key: string, startedAt?: number): void {
    const a = this.agents.get(key);
    if (!a) return;
    a.state = "running";
    a.startedAt = startedAt ?? Date.now();
    a.endedAt = undefined;
    a.durationMs = undefined;
    a.exactDuration = false;
    // 新しい実行。停止の返事待ちは消す（stopHandle は持ち越す）。
    a.stopRequested = false;
    if (a.preview !== undefined) a.clearedPreview = true;
    if (a.result !== undefined) a.clearedResult = true;
    a.preview = undefined;
    a.result = undefined;
  }

  /** stream-json の task_type を覚える。claudeStopTask が true で local_agent / local_bash なら止める手がかりを立てる。 */
  private noteTaskType(a: Agent, taskType: string): void {
    a.taskType = taskType;
    a.stopHandle = this.claudeStop && isClaudeStoppable(taskType);
  }

  /**
   * 行を終わりの状態にする。running → done / failed / stopped、done → failed / stopped と、同じ状態での結果の更新だけを
   * 受ける。endedAt は CLI の end_time（無ければ今）。所要時間は usage の duration_ms があればそれを残す。変化があれば true。
   */
  private settle(key: string, state: string, result?: string, endedAt?: number): boolean {
    const a = this.agents.get(key);
    const target = finalState(state);
    if (!a || target === undefined) return false;
    const text = result !== undefined && result.trim() !== "" ? result : undefined;
    const before = { ...a };
    switch (a.state) {
      case "running":
        a.state = target;
        // 作業の文は結果ではない（失敗の理由に見えないように消す）。結果なしで閉じるときは resultPreview: "" で
        // アプリに持っている作業の文を消させる。
        if (a.preview !== undefined) a.clearedPreview = true;
        a.preview = undefined;
        a.endedAt = endedAt ?? Date.now();
        if (!a.exactDuration) a.durationMs = msBetween(a.startedAt, a.endedAt);
        break;
      case target:
        if (text === undefined) return false;
        break;
      case "done":
        a.state = target;
        break;
      default:
        return false;
    }
    if (text !== undefined) {
      a.preview = preview(text);
      a.result = clip(text);
    }
    return !sameAgent(a, before);
  }

  /**
   * 全行（subtype = workflow_snapshot。アプリは行を丸ごと置き換える）。後から開いたクライアントに今の状態を渡す。
   * 行が無ければ undefined。includeEmpty なら行が無くても agents: [] で返す（アプリが持っている幽霊行を消せるように）。
   */
  snapshot(opts: { includeEmpty?: boolean } = {}): string | undefined {
    if (!opts.includeEmpty && this.agents.size === 0) return undefined;
    return this.payload([...this.agents.values()].sort((x, y) => x.index - y.index), "workflow_snapshot");
  }

  /** 行は毎回、持っている項目を全部入れる（アプリは届いた項目だけを上書きする）。undefined の項目は JSON に出ない。 */
  private payload(rows: Agent[], subtype = "task_progress"): string {
    const all = [...this.agents.values()];
    // 古いアプリ向けの要約。1 行でも running なら running、全部 failed なら failed（stopped は失敗に数えない）。
    const status = all.some((a) => a.state === "running")
      ? "running"
      : all.length > 0 && all.every((a) => a.state === "failed")
        ? "failed"
        : "completed";
    return JSON.stringify({
      subtype,
      taskId: SubagentTracker.taskId,
      kind: "subagents",
      workflowName: "サブエージェント",
      status,
      epoch: this.epoch,
      agents: rows.map((a) => ({
        index: a.index,
        id: a.id,
        label: a.label,
        labelIsFallback: a.labelIsFallback,
        state: a.state,
        rowKind: a.rowKind,
        startedAtMs: a.startedAt,
        taskCount: a.taskCount,
        agentType: a.agentType,
        tool: a.tool,
        command: a.command,
        parentId: a.parentId,
        background: a.background,
        stoppable: a.state === "running" && a.stopHandle === true && a.stopRequested !== true,
        model: a.model,
        tokens: a.tokens,
        toolCalls: a.toolCalls,
        durationMs: a.durationMs,
        // アプリは届いた項目だけを上書きする。作業の文を消した行（結果なしで閉じた・実行中に戻した）は空文字を送り、
        // アプリが持っている前の作業の文・結果を消させる（空は「無い」として扱われる）。
        resultPreview: a.preview ?? (a.clearedPreview ? "" : undefined),
        // 終わった時刻と結果の本文は、終わった行だけ。
        endedAtMs: a.state !== "running" ? a.endedAt : undefined,
        result: a.state !== "running" ? (a.result ?? (a.clearedResult ? "" : undefined)) : a.clearedResult ? "" : undefined
      }))
    });
  }
}

/** 既にある行に、分かったことを足す。既定文の label は説明で上書きし、説明を既定文では上書きしない。 */
function fill(a: Agent, label: string | undefined, o: BeginOptions): void {
  const text = label !== undefined ? preview(label, 80) : "";
  if (text) {
    const fallback = o.labelIsFallback ?? false;
    if (!fallback || a.labelIsFallback) {
      a.label = text;
      a.labelIsFallback = fallback;
    }
  }
  if (o.taskCount !== undefined) a.taskCount = o.taskCount;
  if (o.agentType) {
    a.agentType = o.agentType;
    // 説明の無い行の既定文は種類名（古いアプリ向け）。
    if (a.labelIsFallback && a.taskCount === undefined) a.label = o.agentType;
  }
  if (o.model) a.model = o.model;
  if (o.background !== undefined) a.background = o.background;
  if (o.tool) a.tool = o.tool;
  if (o.command) a.command = preview(o.command, 200);
}

/** 行の中身が同じか（変化の判定。mac の Equatable と同じく全項目を比べる）。 */
function sameAgent(a: Agent, b: Agent): boolean {
  for (const k of new Set([...Object.keys(a), ...Object.keys(b)]) as Set<keyof Agent>) if (a[k] !== b[k]) return false;
  return true;
}

export const isAgentTool = (name: string): boolean => name === "Agent" || name === "Task";

/**
 * hooks の内部の補助か（agent_id があり、agent_type が無いか空）。Stop のたびに来る次の発話の候補づくり
 * （SubagentStop の agent_type: ""）と、バックグラウンドのエージェントの要約（PreToolUse に agent_type キーが無い）。
 * 行にも親のツール行にもペインの状態にも使わない。
 */
export function isInternalHelper(agentId: string | undefined, agentType: unknown): boolean {
  if (!agentId) return false;
  return typeof agentType !== "string" || agentType === "";
}

/** stream-json の task_type のうち、バックグラウンドのシェル等として行に出すもの（Monitor も local_bash で来る）。 */
const SHELL_TASK_TYPES = new Set(["local_bash", "monitor_mcp", "monitor_ws", "mcp_task", "bash", "shell"]);

/** Claude の TaskStop で止められる task_type（monitor_* と mcp_task、teammate 等は止められない）。 */
const isClaudeStoppable = (type: string): boolean => type === "local_agent" || type === "local_bash";

const isShellTask = (type: string | undefined): boolean => type !== undefined && SHELL_TASK_TYPES.has(type);

const listedId = (t: Obj): string | undefined => nonEmpty(t.id) ?? nonEmpty(t.task_id);

/**
 * 一覧の 1 件を行の形にする。種類は完全一致で振り分ける（hooks の表示名と、stream-json・古い版の内部名の両方）。
 * 内部の作業（dream・auto-mode scan・memory import）と知らない種類は行にしない。
 */
function listed(t: Obj): Listed | undefined {
  const id = listedId(t);
  if (id === undefined) return undefined;
  const type = nonEmpty(t.type) ?? nonEmpty(t.task_type) ?? "";
  let agentType = nonEmpty(t.agent_type) ?? nonEmpty(t.subagent_type);
  let tool = nonEmpty(t.tool);
  let rowKind: RowKind;
  switch (type) {
    case "subagent":
    case "local_agent":
      rowKind = "agent";
      break;
    case "shell":
    case "local_bash":
    case "MCP task":
    case "mcp_task":
      rowKind = "shell";
      break;
    case "monitor":
    case "monitor_mcp":
    case "monitor_ws":
      rowKind = "shell";
      tool = "Monitor";
      break;
    case "workflow":
    case "local_workflow":
      // ターミナル経路には workflow のカードが無いので、サブエージェントの行として出す。
      rowKind = "agent";
      agentType = "workflow";
      break;
    case "teammate":
    case "in_process_teammate":
    case "cloud session":
    case "remote_agent":
      rowKind = "agent";
      agentType = type;
      break;
    default:
      return undefined;
  }
  return {
    id,
    rowKind,
    agentType,
    label: nonEmpty(t.description) ?? nonEmpty(t.name) ?? nonEmpty(t.command),
    tool: rowKind === "shell" ? tool : undefined,
    command: nonEmpty(t.command),
    parentId: nonEmpty(t.parent_task_id),
    runId: nonEmpty(t.run_id)
  };
}

/** <task-notification> を抜き出す（複数あれば全部）。<usage> の subagent_tokens（か total_tokens）・tool_uses・duration_ms も読む。 */
export function taskNotifications(text: string): TaskNotification[] {
  const open = "<task-notification>";
  const close = "</task-notification>";
  const out: TaskNotification[] = [];
  let from = 0;
  for (;;) {
    const a = text.indexOf(open, from);
    const b = a < 0 ? -1 : text.indexOf(close, a + open.length);
    if (b < 0) break;
    const body = text.slice(a + open.length, b);
    // <result> は最後の閉じタグまで（返事の本文にタグの文字が入っていても切らない）。<usage> はその後ろから読む。
    const result = tagValue("result", body, true);
    const last = body.lastIndexOf("</result>");
    const usage = tagValue("usage", last < 0 ? body : body.slice(last + "</result>".length)) ?? "";
    const taskId = tagValue("task-id", body);
    if (taskId !== undefined) {
      out.push(
        compact({
          taskId,
          status: tagValue("status", body) ?? "completed",
          summary: tagValue("summary", body),
          result,
          tokens: intText(tagValue("subagent_tokens", usage) ?? tagValue("total_tokens", usage)),
          toolUses: intText(tagValue("tool_uses", usage)),
          durationMs: intText(tagValue("duration_ms", usage))
        })
      );
    }
    from = b + close.length;
  }
  return out;
}

/** 発話から <task-notification> の塊を取り除いた残り（前後の空白も詰める）。 */
export function stripNotifications(text: string): string {
  return text.replace(/<task-notification>[\s\S]*?<\/task-notification>/g, "").trim();
}

/**
 * OpenCode の task の出力から中身を取り出す。1.18 の形は
 * `<task id="ses_…" state="completed|running|error">`（`<summary>…</summary>`）`<task_result>…</task_result>`
 * （失敗は `<task_error>…</task_error>`）`</task>`。古い形（本文の後ろに `<task_metadata>`）も受ける。
 * state は属性の値そのまま（無くて <task_error> なら "error"、古い形は undefined）。どちらの形でもなければ全部 undefined。
 */
export function parseTaskOutput(text: string): { state?: string; summary?: string; result?: string } {
  const error = tagValue("task_error", text, true);
  const body = tagValue("task_result", text, true) ?? error;
  const summary = tagValue("summary", text);
  const attrs = /<task ([^>]*)>/.exec(text)?.[1];
  const state = attrs !== undefined ? /state="([^"]*)"/.exec(attrs)?.[1] : undefined;
  if (body !== undefined || summary !== undefined || state !== undefined) {
    return { state: state ?? (error !== undefined ? "error" : undefined), summary, result: body };
  }
  const r = text.indexOf("<task_metadata>");
  if (r >= 0) return { result: text.slice(0, r).trim() || undefined };
  return {};
}

/** <name>…</name> の中身（前後の空白を詰め、空なら undefined）。lastClose なら最後の閉じタグまで。 */
function tagValue(name: string, s: string, lastClose = false): string | undefined {
  const open = `<${name}>`;
  const close = `</${name}>`;
  const a = s.indexOf(open);
  if (a < 0) return undefined;
  const start = a + open.length;
  const b = lastClose ? s.lastIndexOf(close) : s.indexOf(close, start);
  if (b < start) return undefined;
  return s.slice(start, b).trim() || undefined;
}

/**
 * 各 CLI がサブエージェントへ仕事を任せるツール。
 * Claude / Cursor: Task・Agent、Codex(ACP): spawn_agent、Hermes: delegate_task、OpenClaw: sessions_spawn。
 */
const DELEGATION_TOOLS = new Set(["task", "agent", "spawn_agent", "spawnagent", "delegate_task", "sessions_spawn", "subagent", "spawn_subagent"]);

/**
 * ツール呼び出しがサブエージェントの起動なら、行に出す説明と種類を返す。名前は先頭の識別子にそろえて照合する
 * （ACP の title は「delegate_task: …」の形）。名前で見分けられない ACP（タイトルに説明が入る claude-code-acp 等）は
 * 入力の subagent_type で見分ける。説明が無ければ label は空か「{n} 件のタスク」で、labelIsFallback が true。
 */
export function delegation(toolName: string, title: string | undefined, input: unknown): Delegation | undefined {
  if (isDelegateControl(toolName, title, input)) return undefined;
  if (!DELEGATION_TOOLS.has(normalizedToolName(toolName).toLowerCase()) && asObj(input)?.subagent_type === undefined) return undefined;
  return delegationLabel(title, input);
}

/**
 * Hermes の delegate_task の control call（list / steer / stop）は委任ではない。rawInput.action か、title の「delegate_task:」の
 * 後（list / steer / stop で始まり、その後が空白・「:」・終わり）で見分ける。本物の title は「delegate_task: 1 tasks: …」の形。
 */
function isDelegateControl(toolName: string, title: string | undefined, input: unknown): boolean {
  const text = title ?? toolName;
  const head = identifierHead(text.trim());
  if (head.toLowerCase() !== "delegate_task" && normalizedToolName(toolName).toLowerCase() !== "delegate_task") return false;
  const action = asStr(asObj(input)?.action);
  if (action === "list" || action === "steer" || action === "stop") return true;
  const rest = text.trim().slice(head.length);
  return head.toLowerCase() === "delegate_task" && rest.startsWith(":") && /^(list|steer|stop)(?=$|[\s:])/.test(rest.slice(1).trimStart());
}

/** 委任の説明と種類。title の「<tool>: 」は外す。説明が無くタスクの配列なら「{n} 件のタスク」（既定文）。 */
function delegationLabel(title: string | undefined, input: unknown): Delegation {
  const d = asObj(input);
  const agentType = nonEmpty(d?.subagent_type) ?? nonEmpty(d?.agent_type) ?? nonEmpty(d?.agentId);
  const taskCount = Array.isArray(d?.tasks) ? d.tasks.length : undefined;
  let label = title !== undefined ? strippedToolPrefix(title) : "";
  for (const k of ["description", "goal", "label", "task", "prompt", "message"]) {
    const v = nonEmpty(d?.[k]);
    if (v !== undefined) {
      label = v;
      break;
    }
  }
  if (!label && taskCount !== undefined) return { label: `${taskCount} 件のタスク`, agentType, labelIsFallback: true, taskCount };
  return { label, agentType, labelIsFallback: !label, taskCount };
}

/** 先頭の識別子（[A-Za-z0-9_.-]+。無ければ空）。 */
const identifierHead = (s: string): string => /^[A-Za-z0-9_.-]*/.exec(s)![0];

/**
 * ACP の title からツール名を作る。先頭の識別子（[A-Za-z0-9_.-]+）だけを取る（「delegate_task: 3 tasks」→「delegate_task」）。
 * 識別子で始まらなければ、最初の語をそのまま返す。
 */
export function normalizedToolName(raw: string): string {
  const s = raw.trim();
  const head = identifierHead(s);
  if (head) return head;
  return s.split(/\s+/).find(Boolean) ?? s;
}

/** 委任ツールの title「<tool>: <中身>」から「<tool>: 」を外す。ツール名だけの title は空にする（説明ではない）。 */
function strippedToolPrefix(title: string): string {
  const s = title.trim();
  const head = identifierHead(s);
  if (!head || !DELEGATION_TOOLS.has(head.toLowerCase())) return s;
  const rest = s.slice(head.length);
  if (!rest) return "";
  if (!rest.startsWith(":")) return s;
  return rest.slice(1).trim();
}

/**
 * CLI の終わり方の語を行の state にする。終わりでなければ undefined。
 * completed / done / success → done、failed / error → failed、
 * killed / stopped / cancelled / canceled / interrupted / aborted → stopped（止めたものは失敗ではない）。
 */
export function finalState(status: string): string | undefined {
  if (["completed", "done", "success"].includes(status)) return "done";
  if (["failed", "error"].includes(status)) return "failed";
  if (["killed", "stopped", "cancelled", "canceled", "interrupted", "aborted"].includes(status)) return "stopped";
  return undefined;
}

/**
 * usage（total_tokens・tool_uses・duration_ms）。final = 終わりの知らせの usage（所要時間はこれが正）。
 * 実行中の duration_ms は、閉じるときに end_time か今の時刻で上書きする。
 */
function applyUsage(usage: unknown, a: Agent, final: boolean): void {
  const u = asObj(usage);
  if (!u) return;
  const tokens = int(u.total_tokens) ?? int(u.subagent_tokens);
  if (tokens !== undefined) a.tokens = tokens;
  const tools = int(u.tool_uses);
  if (tools !== undefined) a.toolCalls = tools;
  const duration = int(u.duration_ms);
  if (duration !== undefined) {
    a.durationMs = duration;
    if (final) a.exactDuration = true;
  }
}

/** 同じ実行の行か（run_id の違う行は、再開する前の実行の遅れて届いたもの）。 */
function sameRun(a: Agent, obj: Obj): boolean {
  const run = asStr(obj.run_id);
  return run === undefined || a.runId === undefined || run === a.runId;
}

/** 結果として意味のある要約か（説明をそのまま返しただけのもの＝止めた知らせ等は結果にしない）。 */
function informative(summary: string | undefined, label: string): string | undefined {
  const s = summary?.trim();
  if (!s || preview(s, 80) === label) return undefined;
  return s;
}

function acpText(raw: unknown): string | undefined {
  const text = (asObjs(raw) ?? [])
    .map((c) => asStr(asObj(c.content)?.text) ?? asStr(c.text))
    .filter(isDefined)
    .join("\n");
  return text || undefined;
}

const msBetween = (start: number, end: number): number => Math.max(0, Math.round(end - start));

/** 「Glob: *.json」「Bash: ls /tmp」のような、いまやっていることの 1 行。 */
export function toolActivity(name: string, input: unknown): string {
  const d = asObj(input);
  for (const k of ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt"]) {
    const v = asStr(d?.[k]);
    if (v) return `${name}: ${preview(v, 100)}`;
  }
  return name;
}

/** limit 字（コードポイントで数える）を超えたら切って「…」を付ける。 */
function cut(s: string, limit: number): string {
  if (s.length <= limit) return s;
  const chars = Array.from(s);
  return chars.length > limit ? chars.slice(0, limit).join("") + "…" : s;
}

/** 改行で区切った各行の前後を詰め、空行を除いて 1 行にする（mac の isNewline と同じ区切り）。 */
function preview(s: string, limit = 160): string {
  const one = s
    .split(/\r\n|[\n\r\v\f\x85\u{2028}\u{2029}]/u)
    .map((l) => l.trim())
    .filter(Boolean)
    .join(" ");
  return cut(one, limit);
}

/** 結果の本文（詳細を開いたときに出す）。前後の空白を詰め、2000 字まで。 */
function clip(s: string, limit = 2000): string {
  return cut(s.trim(), limit);
}
