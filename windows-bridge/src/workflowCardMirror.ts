import { finalState, SubagentTracker } from "./agents/subagentTracker.js";

/* ── workflow_progress のカードの写し（docs/BACKGROUND_WORK_2026-10-21.md §3.1・§3.5。mac の WorkflowCardMirror と同じ） ── */

type CardObj = Record<string, unknown>;

const isRecord = (v: unknown): v is CardObj => Boolean(v) && typeof v === "object" && !Array.isArray(v);

/** 動いているものの数。 */
export interface CardCounts {
  /** subagents のカードの running の行のうちサブエージェント（rowKind が agent。workflow・teammate の行も含む） */
  agents: number;
  /** agents のうち background == true の行（Live Activity の数え方。生成中は前景のサブエージェントを数えない） */
  backgroundOnlyAgents: number;
  /** subagents のカードの running の行のうちバックグラウンドのコマンド（rowKind が shell。Monitor を含む） */
  shells: number;
  /** 終わっていない dynamic workflow のカード */
  workflows: number;
}

/** 何か動いている（閉じない・list_sessions の background）。 */
export const anyBackground = (c: CardCounts): boolean => c.agents + c.shells + c.workflows > 0;
/** サブエージェントか workflow が動いている（スリープ抑止・完了の push を待つ）。バックグラウンドのコマンドだけでは
 *  数えない（dev サーバーは終わらないので、眠れない・知らせが来ないままになる）。 */
export const agentsOrWorkflows = (c: CardCounts): boolean => c.agents + c.workflows > 0;

/** apply で終わったもの（Live Activity の「終わった数」。docs/BACKGROUND_CONTROL_2026-10-21.md §8.2）。 */
export interface FinishedItem {
  state: "done" | "failed" | "stopped";
  /** バックグラウンドのもの（dynamic workflow はいつも true）。 */
  background: boolean;
}

interface MirrorCard {
  /** subtype と agents を除いた最新の項目（taskId・kind・epoch・workflowName・status・summary・outcome …） */
  fields: CardObj;
  /** index → 最新の行 */
  agents: Map<number, CardObj>;
}

const SUBAGENTS_TASK_ID = SubagentTracker.taskId;
/** サブエージェントのカード（kind の無い古い payload も taskId で見分ける）。 */
const isSubagentsCard = (c: MirrorCard): boolean => c.fields.kind === "subagents" || c.fields.taskId === SUBAGENTS_TASK_ID;
/** mainagent の子のカード（kind "sessions"）。バックグラウンドの作業には数えない。 */
const isSessionsCard = (c: MirrorCard): boolean => c.fields.kind === "sessions";
/** 終わった dynamic workflow か（status が completed / failed / stopped 等）。status が無ければ動いているとみなす。 */
const isFinishedCard = (c: MirrorCard): boolean => typeof c.fields.status === "string" && finalState(c.fields.status) !== undefined;
const isRunningRow = (row: CardObj): boolean => row.state === "running";

/**
 * workflow_progress のカード（dynamic workflow と、サブエージェント・バックグラウンドのコマンドの subagents）の写し。
 * taskId 単位で、届いた payload を重ねる（mac の SessionHub の WorkflowCardMirror と同じ規則）。再接続のスナップショットと、
 * バックグラウンドの作業があるか（閉じない・スリープ抑止・完了の push・一覧の background）に使う。
 */
export class WorkflowCardMirror {
  static readonly subagentsTaskId = SUBAGENTS_TASK_ID;
  /** taskId → カード（届いた順。再生の順） */
  private readonly cards = new Map<string, MirrorCard>();
  /** 直前の apply で終わったもの（apply のたびに上書き）。 */
  lastFinished: FinishedItem[] = [];

  get isEmpty(): boolean {
    return this.cards.size === 0;
  }

  get hasSubagents(): boolean {
    return this.cards.has(SUBAGENTS_TASK_ID);
  }

  /** subagents のカードの世代（SubagentTracker の epoch）。 */
  get subagentsEpoch(): string | undefined {
    const epoch = this.cards.get(SUBAGENTS_TASK_ID)?.fields.epoch;
    return typeof epoch === "string" ? epoch : undefined;
  }

  /** payload（workflow_progress の content の JSON）を重ねる。重ねたカードの taskId を返す（読めなければ undefined）。 */
  apply(json: string | undefined): string | undefined {
    let obj: unknown;
    try {
      obj = JSON.parse(json ?? "");
    } catch {
      return undefined;
    }
    return isRecord(obj) ? this.applyObject(obj) : undefined;
  }

  /**
   * - epoch が持っているものと違えば、行を全部捨ててから重ねる（作り直したトラッカーの行と混ぜない）。
   * - subtype が workflow_snapshot なら、行を丸ごと置き換える（agents: [] なら行が無い）。
   * - ほかは index ごとに重ねる。epoch 付きの行（SubagentTracker。毎回全項目を入れる）は置き換え、epoch の無い行
   *   （dynamic workflow・古い Bridge）は届いた項目だけを上書きする。
   */
  applyObject(obj: CardObj): string | undefined {
    this.lastFinished = [];
    const taskId = typeof obj.taskId === "string" && obj.taskId ? obj.taskId : undefined;
    if (!taskId) return undefined;
    const before = this.cards.get(taskId);
    const card = before ?? { fields: {}, agents: new Map<number, CardObj>() };
    const epoch = typeof obj.epoch === "string" ? obj.epoch : undefined;
    // 終わったものを見つけるために、apply の前に動いていた行・終わっていなかったカードを覚える。
    const beforeEpoch = before?.fields.epoch;
    const wasRunning = before && isSubagentsCard(before) ? [...before.agents].filter(([, row]) => isRunningRow(row) && row.rowKind !== "shell") : [];
    const wasOpenWorkflow = before !== undefined && !isSubagentsCard(before) && !isSessionsCard(before) && !isFinishedCard(before);
    if (epoch !== undefined && card.fields.epoch !== epoch) card.agents.clear();
    if (obj.subtype === "workflow_snapshot") card.agents.clear();
    for (const [k, v] of Object.entries(obj)) if (k !== "subtype" && k !== "agents") card.fields[k] = v;
    // outcome（止めた workflow の印）は status に添えて届く。status だけが届いたら前の印を残さない。
    if (obj.status !== undefined && obj.outcome === undefined) delete card.fields.outcome;
    // taskId "subagents" は kind が無くても subagents のカード（再生する全行に kind を入れる）。
    if (taskId === SUBAGENTS_TASK_ID && typeof card.fields.kind !== "string") card.fields.kind = "subagents";
    if (typeof card.fields.status !== "string") {
      if (obj.subtype === "task_started") card.fields.status = "running";
      if (obj.subtype === "task_notification") card.fields.status = "completed";
    }
    for (const a of Array.isArray(obj.agents) ? obj.agents : []) {
      if (!isRecord(a) || typeof a.index !== "number" || !Number.isFinite(a.index)) continue;
      const index = Math.trunc(a.index);
      card.agents.set(index, epoch !== undefined ? { ...a } : { ...(card.agents.get(index) ?? {}), ...a });
    }
    this.cards.set(taskId, card);
    this.lastFinished = this.findFinished(card, wasRunning, wasOpenWorkflow, epoch !== undefined && beforeEpoch !== epoch);
    return taskId;
  }

  /**
   * apply で終わったもの。subagents のカードは、前に動いていた agent 行が同じ index で終わった（epoch が変わった・
   * 行が消えたときは stopped）もの。dynamic workflow は終わっていなかったカードが終わったら 1 つ。
   */
  private findFinished(card: MirrorCard, wasRunning: Array<[number, CardObj]>, wasOpenWorkflow: boolean, epochChanged: boolean): FinishedItem[] {
    const out: FinishedItem[] = [];
    if (isSubagentsCard(card)) {
      for (const [index, row] of wasRunning) {
        const now = epochChanged ? undefined : card.agents.get(index);
        const state = typeof now?.state === "string" ? now.state : "";
        const background = (now?.background ?? row.background) === true;
        if (!now) out.push({ state: "stopped", background });
        else if (state === "done" || state === "failed" || state === "stopped") out.push({ state, background });
      }
    } else if (wasOpenWorkflow && isFinishedCard(card)) {
      const status = typeof card.fields.status === "string" ? card.fields.status : "";
      const state = card.fields.outcome === "stopped" ? "stopped" : finalState(status) === "failed" ? "failed" : "done";
      out.push({ state, background: true });
    }
    return out;
  }

  /**
   * 新しいターン（生成中でない送信・予約の実行・ほかの画面からの発話）: subagents のカードの終わった行と、終わった
   * dynamic workflow を捨てる。動いているもの（ターンより長く動く作業）は残す。アプリと adapter のトラッカー
   * （SubagentTracker.pruneFinished）も同じ時点で捨てる。
   */
  pruneFinished(): void {
    for (const [taskId, card] of [...this.cards]) {
      if (isSubagentsCard(card)) {
        for (const [index, row] of [...card.agents]) if (!isRunningRow(row)) card.agents.delete(index);
      } else if (!isSessionsCard(card) && isFinishedCard(card)) {
        this.cards.delete(taskId);
      }
    }
  }

  /** ターンの終わり（done・error で閉じた）: 終わった dynamic workflow だけを捨てる。subagents のカード（終わった行も、
   *  知らせのターンまで結果を残す）と、終わっていない workflow（バックグラウンドで続く）は残す。 */
  dropFinishedWorkflows(): void {
    for (const [taskId, card] of [...this.cards]) {
      if (!isSubagentsCard(card) && !isSessionsCard(card) && isFinishedCard(card)) this.cards.delete(taskId);
    }
  }

  /** 動いているものの数。 */
  get counts(): CardCounts {
    const c: CardCounts = { agents: 0, backgroundOnlyAgents: 0, shells: 0, workflows: 0 };
    for (const card of this.cards.values()) {
      if (isSubagentsCard(card)) {
        for (const row of card.agents.values()) {
          if (!isRunningRow(row)) continue;
          if (row.rowKind === "shell") c.shells += 1;
          else {
            c.agents += 1;
            if (row.background === true) c.backgroundOnlyAgents += 1;
          }
        }
      } else if (!isSessionsCard(card) && !isFinishedCard(card)) {
        c.workflows += 1;
      }
    }
    return c;
  }

  /** subagents のカードの全行（workflow_snapshot。kind・epoch 付き）。カードが無ければ undefined。 */
  subagentsSnapshot(): string | undefined {
    return this.snapshotJSON(SUBAGENTS_TASK_ID);
  }

  /** subagents 以外のカード（dynamic workflow）の全行を届いた順に。unfinishedOnly なら終わっていないものだけ
   *  （ターンが終わった後もバックグラウンドで続くもの）。 */
  workflowSnapshots(unfinishedOnly: boolean): string[] {
    const out: string[] = [];
    for (const [taskId, card] of this.cards) {
      if (isSubagentsCard(card) || (unfinishedOnly && isFinishedCard(card))) continue;
      const json = this.snapshotJSON(taskId);
      if (json) out.push(json);
    }
    return out;
  }

  /** 1 枚のカードの全行（subtype = workflow_snapshot。アプリは行を丸ごと置き換える）。subagents のカードの status
   *  （古いアプリ向けの要約）は行から数え直す（終わった行を捨てた後にも合うように。SubagentTracker と同じ規則）。 */
  snapshotJSON(taskId: string): string | undefined {
    const card = this.cards.get(taskId);
    if (!card) return undefined;
    const rows = [...card.agents.entries()].sort(([a], [b]) => a - b).map(([, row]) => row);
    const out: CardObj = { ...card.fields, subtype: "workflow_snapshot", taskId, agents: rows };
    if (isSubagentsCard(card)) {
      out.kind = "subagents";
      const states = rows.map((row) => (typeof row.state === "string" ? row.state : ""));
      out.status = states.includes("running") ? "running" : states.length > 0 && states.every((s) => s === "failed") ? "failed" : "completed";
    }
    return JSON.stringify(out);
  }

  /** subagents の全行（session の subagentSnapshot など）から、世代と動いている行の数を読む。subagents のカードでなければ undefined。 */
  static rowCounts(json: string): { epoch?: string; agents: number; shells: number } | undefined {
    const mirror = new WorkflowCardMirror();
    const taskId = mirror.apply(json);
    const card = taskId !== undefined ? mirror.cards.get(taskId) : undefined;
    if (!card || !isSubagentsCard(card)) return undefined;
    const c = mirror.counts;
    return { epoch: mirror.subagentsEpoch, agents: c.agents, shells: c.shells };
  }
}
