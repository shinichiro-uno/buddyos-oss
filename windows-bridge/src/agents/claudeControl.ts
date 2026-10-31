import type { SessionEvent } from "../protocol.js";

/// Claude Code の `--permission-prompt-tool stdio`（SDK ホスト用の制御プロトコル）と、承認・質問カード
/// （mac の ClaudeControlProtocol.swift の移植）。
///
/// `claude -p --input-format stream-json` は、このフラグ無しだと承認が要る場面で何も尋ねずに自動拒否する。
/// 付けると stdout に次の 1 行が出て、返事が来るまで待つ:
///
///   {"type":"control_request","request_id":"<uuid>","request":{"subtype":"can_use_tool",
///     "tool_name":"Bash","input":{...},"permission_suggestions":[...],"tool_use_id":"..."}}
///
/// 返事は stdin に 1 行:
///
///   {"type":"control_response","response":{"subtype":"success","request_id":"<uuid>",
///     "response":{"behavior":"allow","updatedInput":{...}}}}      許可（updatedInput は元の input）
///   {"type":"control_response","response":{"subtype":"success","request_id":"<uuid>",
///     "response":{"behavior":"deny","message":"..."}}}            拒否（message は Claude に伝わる）
///
/// `allow` に `updatedPermissions`（permission_suggestions の要素）を付けると同種の操作を続けて許可できる。
/// suggestions の destination は既定で localSettings（プロジェクトの settings.local.json に書かれる）なので、
/// 「このセッションでは承認」では session に付け替える。
///
/// こちらから書く制御要求は、承認の返事のほかに次の 3 つ（返事は success / error の control_response で、request_id で結ぶ）:
///
///   {"type":"control_request","request_id":"<uuid>","request":{"subtype":"initialize","perTaskStopAffordance":true}}
///     プロセスを起こしたら最初の user 行より前に 1 行書く。success なら行ごとの停止（stop_task）が使える。
///     返事（約 21 KB）にはアカウントのメールと pid が入るので、ログにも store にも出さない。
///   {"type":"control_request","request_id":"<uuid>","request":{"subtype":"stop_task","task_id":"<行か workflow の task_id>"}}
///     背景のサブエージェント・コマンド・dynamic workflow を 1 つ止める。
///   interrupt は claudeCode.ts の interruptRequest（今のターンだけを止める）。

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" && v.length > 0 ? v : undefined);

export interface ToolRequest {
  requestId: string;
  toolName: string;
  input: Obj;
  /** claude が出す「次から聞かない」候補（permission_suggestions）。あれば「このセッションでは承認」を出す。 */
  suggestions: Obj[];
  /** 背景のサブエージェントの承認なら、その行の id（task_id）。main の承認は無し。 */
  agentId?: string;
}

export type ControlLine =
  | { kind: "canUseTool"; request: ToolRequest }
  /** Claude 側が要求を取り下げた（ツール呼び出しが中断された等）。カードを閉じる。 */
  | { kind: "cancel"; requestId: string }
  /** 対応していない制御要求。返事をしないと Claude が待ち続けるので、エラーで返す。 */
  | { kind: "unsupported"; requestId: string; subtype: string };

/** stdout の 1 行が制御行ならパースして返す。普通の行（本文の差分など）は JSON を読まずに undefined。 */
export function parseControlLine(line: string): ControlLine | undefined {
  if (!line.includes('"control_request"') && !line.includes('"control_cancel_request"')) return undefined;
  let o: Obj;
  try {
    o = obj(JSON.parse(line));
  } catch {
    return undefined;
  }
  const requestId = str(o.request_id);
  if (!requestId) return undefined;
  if (o.type === "control_cancel_request") return { kind: "cancel", requestId };
  if (o.type !== "control_request") return undefined;
  const request = obj(o.request);
  const subtype = str(request.subtype) ?? "";
  const toolName = str(request.tool_name);
  if (subtype !== "can_use_tool" || !toolName) return { kind: "unsupported", requestId, subtype };
  return {
    kind: "canUseTool",
    request: {
      requestId,
      toolName,
      input: obj(request.input),
      suggestions: (Array.isArray(request.permission_suggestions) ? request.permission_suggestions : []).map(obj),
      ...(str(request.agent_id) ? { agentId: str(request.agent_id) } : {})
    }
  };
}

/* ── カード ─────────────────────────────────────────────── */

export function questionsIn(input: Obj): Obj[] {
  return Array.isArray(input.questions) ? input.questions.map(obj) : [];
}

/** AskUserQuestion として質問カードを出すか（質問が 1 つ以上あるとき）。 */
export function isQuestionRequest(toolName: string, input: Obj): boolean {
  return toolName === "AskUserQuestion" && questionsIn(input).length > 0;
}

function setOptions(meta: Record<string, string>, options: Array<[string, string, string]>): void {
  meta.option_count = String(options.length);
  options.forEach(([title, subtitle, value], i) => {
    meta[`option_${i}_title`] = title;
    meta[`option_${i}_subtitle`] = subtitle;
    meta[`option_${i}_value`] = value;
  });
}

function actionRequest(agentId: string, sessionId: string, requestId: string, title: string, subtitle: string | undefined, meta: Record<string, string>, toolName: string): SessionEvent {
  const metadata: Record<string, string> = { ...meta, requestId, title };
  if (subtitle) metadata.subtitle = subtitle;
  return { type: "action_request", agentId, sessionId, messageId: requestId, content: title, toolName, metadata };
}

/** 承認カード。選択肢の value は respondToAction の decision に入ってくる。 */
export function approvalCard(r: ToolRequest, agentId: string, sessionId: string): SessionEvent {
  const meta: Record<string, string> = { kind: "approval", allowsOther: "0" };
  const options: Array<[string, string, string]> = [["承認", "一度だけ許可", "allow"]];
  // 同種の操作を続けて許可できるのは、Claude が候補（permission_suggestions）を出したときだけ。
  if (r.suggestions.length > 0) options.push(["このセッションでは承認", "同種の操作を続けて許可", "allowForSession"]);
  options.push(["非承認", "実行しない", "deny"]);
  setOptions(meta, options);
  return actionRequest(agentId, sessionId, r.requestId, `「${r.toolName}」を実行しますか？`, toolSummary(r.toolName, r.input), meta, r.toolName);
}

/**
 * AskUserQuestion（Claude が選択肢つきで質問してくる）。全部の質問は questions_json で渡す
 * （新しい iOS / デスクトップは全問・複数選択を出す）。option_N_* は最初の質問だけ（古いクライアント向け）。
 */
export function questionCard(r: ToolRequest, agentId: string, sessionId: string): SessionEvent | undefined {
  const qs = questionsIn(r.input);
  if (qs.length === 0) return undefined;
  return actionRequest(agentId, sessionId, r.requestId, str(qs[0].header) ?? "選択してください", str(qs[0].question), questionMetadata(qs), r.toolName);
}

/** ExitPlanMode（計画を見せて、実装に進んでよいか聞いてくる）。「直してほしい」は自由記述で受け、その文を添えて差し戻す。 */
export function planCard(r: ToolRequest, agentId: string, sessionId: string): SessionEvent {
  const meta: Record<string, string> = { kind: "plan", plan: str(r.input.plan) ?? "", allowsOther: "1", otherPlaceholder: "直してほしいところ" };
  setOptions(meta, [
    ["この計画で進める", "計画を承認して実装に進みます", "allow"],
    ["計画を続ける", "まだ実装に進みません", "deny"]
  ]);
  return actionRequest(agentId, sessionId, r.requestId, "この計画で進めますか？", toolSummary("ExitPlanMode", r.input), meta, r.toolName);
}

/** ツールに合ったカード（質問 / 計画 / 承認）。質問の形が想定外なら undefined（呼び元は待たずに通す）。 */
export function cardFor(r: ToolRequest, agentId: string, sessionId: string): SessionEvent | undefined {
  if (r.toolName === "AskUserQuestion") return questionCard(r, agentId, sessionId);
  if (r.toolName === "ExitPlanMode") return planCard(r, agentId, sessionId);
  return approvalCard(r, agentId, sessionId);
}

/** 質問カードの metadata（kind / allowsOther / questions_json / 最初の質問の option_N_*）。requestId は呼び元が足す。 */
export function questionMetadata(qs: Obj[]): Record<string, string> {
  const first = qs[0] ?? {};
  const options = (Array.isArray(first.options) ? first.options : []).map(obj);
  const meta: Record<string, string> = { kind: "userInput", allowsOther: "1", questions_json: questionsJson(qs) };
  if (first.multiSelect === true) meta.multiSelect = "1";
  setOptions(
    meta,
    options.map((o, i): [string, string, string] => {
      const label = str(o.label) ?? `Option ${i + 1}`;
      return [label, str(o.description) ?? "", label];
    })
  );
  return meta;
}

/** 全部の質問をクライアント向けの形（id / question / header / multiSelect / options[label, description]）に揃えた JSON。id は質問文。 */
export function questionsJson(qs: Obj[]): string {
  return JSON.stringify(
    qs.map((q, i) => {
      const question = str(q.question) ?? "";
      return {
        id: str(q.id) ?? (question || `q${i}`),
        question,
        header: str(q.header) ?? "",
        multiSelect: q.multiSelect === true,
        options: (Array.isArray(q.options) ? q.options : []).map(obj).map((o, j) => ({ label: str(o.label) ?? `Option ${j + 1}`, description: str(o.description) ?? "" }))
      };
    })
  );
}

/** クライアントが返した answers_json（{ 質問 id: 文字列 | [文字列] }）。複数選択は ", " でつなぐ。無ければ空。 */
export function parsedAnswers(meta: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  let parsed: Obj;
  try {
    parsed = obj(JSON.parse(meta.answers_json ?? "{}"));
  } catch {
    return out;
  }
  for (const [k, v] of Object.entries(parsed)) {
    if (typeof v === "string") out[k] = v;
    else if (Array.isArray(v)) out[k] = v.filter((x): x is string => typeof x === "string").join(", ");
  }
  return out;
}

/**
 * 質問の答え。キーは質問文（AskUserQuestion の形式）。
 * answers_json（全問の答え。質問文か id がキー）→ 質問文をキーにした explicit（旧クライアントの Other）→ decision の順に使う。
 */
export function questionAnswers(questions: Obj[], decision: string, explicit: Record<string, string>): Record<string, string> {
  const all = parsedAnswers(explicit);
  const out: Record<string, string> = {};
  questions.forEach((q, i) => {
    const key = str(q.question) ?? str(q.header) ?? "answer";
    // questionsJson の id（q.id か q<i>）で返すクライアントにも合わせる。
    const id = str(q.id) ?? `q${i}`;
    out[key] = all[key] ?? all[id] ?? explicit[key] ?? decision;
  });
  return out;
}

/** カードの 2 行目に出す、何を実行しようとしているかの要約。 */
export function toolSummary(toolName: string, input: Obj, limit = 300): string {
  const s = (k: string): string | undefined => str(input[k]);
  let text: string;
  switch (toolName) {
    case "Bash":
      text = s("command") ?? "シェルコマンドを実行";
      break;
    case "Write":
    case "Edit":
    case "MultiEdit":
    case "Read":
    case "NotebookEdit":
      text = s("file_path") ?? s("path") ?? s("notebook_path") ?? jsonText(input);
      break;
    case "WebFetch":
      text = s("url") ?? jsonText(input);
      break;
    case "WebSearch":
      text = s("query") ?? jsonText(input);
      break;
    case "ExitPlanMode":
      text = s("plan") ?? "計画を承認して実装に進みます";
      break;
    default:
      text = jsonText(input);
  }
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

function jsonText(input: Obj): string {
  try {
    return JSON.stringify(Object.fromEntries(Object.keys(input).sort().map((k) => [k, input[k]])));
  } catch {
    return "";
  }
}

/* ── Claude への返事 ─────────────────────────────────────────── */

/**
 * iPhone の答えを Claude の許可結果（{behavior, updatedInput | message}）にする。CLI へは control_response に包んで返す。
 */
export function permissionResult(r: ToolRequest, decision: string, answers: Record<string, string>): Obj {
  if (isQuestionRequest(r.toolName, r.input)) {
    return { behavior: "allow", updatedInput: { ...r.input, answers: questionAnswers(questionsIn(r.input), decision, answers) } };
  }
  switch (decision) {
    case "allow":
      return { behavior: "allow", updatedInput: r.input };
    case "allowForSession": {
      const updatedPermissions = sessionScoped(r.suggestions);
      return updatedPermissions.length > 0
        ? { behavior: "allow", updatedInput: r.input, updatedPermissions }
        : { behavior: "allow", updatedInput: r.input };
    }
    case "deny":
      return {
        behavior: "deny",
        message:
          r.toolName === "ExitPlanMode"
            ? "The user wants to keep planning. Do not start implementing yet; ask what they would like to change."
            : "The user denied this tool call from their phone. Do not retry it; ask what they would like instead."
      };
    default:
      // 選択肢以外の文（計画への注文・断る理由）。その文を添えて差し戻す。
      return {
        behavior: "deny",
        message:
          r.toolName === "ExitPlanMode"
            ? `The user wants changes to the plan before implementing: ${decision}\nRevise the plan and call ExitPlanMode again.`
            : `The user denied this tool call from their phone and said: ${decision}`
      };
  }
}

export function successResponse(requestId: string, body: Obj): Obj {
  return { type: "control_response", response: { subtype: "success", request_id: requestId, response: body } };
}

export function allowResponse(requestId: string, input: Obj): Obj {
  return successResponse(requestId, { behavior: "allow", updatedInput: input });
}

export function denyResponse(requestId: string, message: string): Obj {
  return successResponse(requestId, { behavior: "deny", message });
}

export function errorResponse(requestId: string, message: string): Obj {
  return { type: "control_response", response: { subtype: "error", request_id: requestId, error: message } };
}

/** 「このセッションでは承認」用。候補の保存先を session に付け替える（既定の localSettings だとプロジェクトに許可が残る）。 */
export function sessionScoped(suggestions: Obj[]): Obj[] {
  return suggestions.map((s) => ({ ...s, destination: "session" }));
}

/** プロセスを起こした直後に書く宣言。行ごとの停止ができる CLI は success を返す（古い CLI は error）。 */
export function initializeRequest(requestId: string): Obj {
  return { type: "control_request", request_id: requestId, request: { subtype: "initialize", perTaskStopAffordance: true } };
}

/** 背景の作業を 1 つ止める。task_id は行の id（index・tool_use_id・説明は CLI が黙って無視する）か workflow の task_id。 */
export function stopTaskRequest(requestId: string, taskId: string): Obj {
  return { type: "control_request", request_id: requestId, request: { subtype: "stop_task", task_id: taskId } };
}
