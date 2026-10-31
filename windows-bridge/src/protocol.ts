import type { StopTaskOutcome } from "./agents/types.js";

export type Metadata = Record<string, string>;

/**
 * この Bridge が知っている種別の一覧（送る・受ける・両方）。正本は shared/protocol.json の eventTypes で、
 * platforms に "windows" を含むものと一致することを protocol.test.ts が確かめる。
 * 種別を足す・消すときは protocol.json の "windows" も直す。
 */
export const EVENT_TYPES = [
  // アプリ → Bridge
  "action_response",
  "add_project_request",
  "agent_info_request",
  "agent_login_request",
  "create_cron_request",
  "cron_outputs_request",
  "delete_bg_session_request",
  "delete_cron_request",
  "delete_mcp_server_request",
  "delete_skill_request",
  "e2e_confirm",
  "extensions_share_request",
  "heartbeat_get",
  "heartbeat_run_now",
  "heartbeat_set",
  "interrupt",
  "list_bg_sessions_request",
  "list_commands_request",
  "list_cron_jobs_request",
  "list_mcp_servers_request",
  "list_models_request",
  "list_projects_request",
  "list_sessions_request",
  "list_skills_request",
  "load_history_request",
  "load_skill_request",
  "pause_cron_request",
  "ping",
  "queue_remove",
  "queue_user_message",
  "register_activity_token",
  "register_e2e_key",
  "register_mcp_server_request",
  "register_push_token",
  "remove_project_request",
  "rename_session_request",
  "reorder_projects_request",
  "resume_cron_request",
  "save_skill_request",
  "session_warm",
  "set_model_request",
  "sites_request",
  "stop_bg_session_request",
  "stop_task_request",
  "turn_status_request",
  "usage_request",
  // Bridge → アプリ
  "action_request",
  "action_resolved",
  "activity",
  "agent_info_result",
  "agent_login_status",
  "assistant_delta",
  "assistant_turn_end",
  "background_work_state",
  "bg_session_changed",
  "bg_session_item",
  "bg_session_list_end",
  "bg_session_result",
  "command_item",
  "commands_end",
  "cron_job_item",
  "cron_job_list_end",
  "cron_job_result",
  "cron_output",
  "cron_outputs_end",
  "done",
  "e2e_error",
  "e2e_hello",
  "e2e_register_result",
  "error",
  "extensions_share_result",
  "heartbeat_status",
  "history_message",
  "input_ack",
  "input_rejected",
  "load_history_end",
  "mcp_server_item",
  "mcp_server_op_result",
  "mcp_servers_end",
  "model_provider_item",
  "models_end",
  "plan_update",
  "pong",
  "proactive",
  "project_item",
  "projects_end",
  "queue_ack",
  "queue_dispatched",
  "queue_state",
  "rename_session_result",
  "session_list_end",
  "session_list_item",
  "session_started",
  "set_model_result",
  "sites_report",
  "skill_content",
  "skill_item",
  "skill_op_result",
  "skills_end",
  "stop_task_result",
  "tool_end",
  "tool_start",
  "turn_resume",
  "unsupported_message",
  "usage_report",
  "usage_update",
  "workflow_progress",
  // 両方向（Bridge もターミナルや別の端末で打った発話を流す）
  "user_message"
] as const;

export type EventType = (typeof EVENT_TYPES)[number];

export interface SessionEvent {
  /**
   * 種別。組み立てる側は EventType の外の文字列を書けない。受けたフレームは JSON.parse をこの型に
   * 当てているだけなので、実行時には知らない文字列も入りうる（handleMessage の default で unsupported_message を返す）。
   */
  type: EventType;
  agentId?: string;
  sessionId?: string;
  messageId?: string;
  seq?: number;
  toolUseId?: string;
  content?: string;
  toolName?: string;
  metadata?: Metadata;
}

export interface SessionSummary {
  sessionId: string;
  title: string;
  lastActive: string;
  messageCount?: number;
  cwd?: string;
  /** ターミナルで開かれている会話（iPhone は印を付けて先頭に出す）。 */
  terminal?: boolean;
}

export interface HistoryMessage {
  role: string;
  content: string;
  messageId: string;
  createdAt?: string;
  seq?: number;
}

export interface CommandInfo {
  id: string;
  kind: string;
  title: string;
  subtitle?: string;
}

export interface AgentInfo {
  model?: string;
  provider?: string;
  reasoningEffort?: string;
  codexMode?: string;
  approvalPolicy?: string;
  sandboxMode?: string;
  runtime?: string;
}

export interface ModelCatalogItem {
  id: string;
  label: string;
  subtitle?: string;
}

export interface ProviderCatalog {
  id: string;
  label: string;
  models: ModelCatalogItem[];
}

export interface CronJobItem {
  id: string;
  name: string;
  prompt: string;
  scheduleDisplay: string;
  deliver: string;
  enabled: boolean;
  state: string;
  nextRunAt?: string;
  lastRunAt?: string;
  lastStatus?: string;
  lastSessionId?: string;
}

/** stop_task_result の reason（wire の語）。ログも同じ語を使う。 */
export function stopReason(outcome: StopTaskOutcome): string {
  return {
    stopped: "stopped",
    notRunning: "not_running",
    stale: "stale",
    unsupported: "unsupported",
    failed: "failed",
    timeout: "timeout"
  }[outcome.kind];
}

export const event = {
  sessionStarted(agentId: string, sessionId: string): SessionEvent {
    return { type: "session_started", agentId, sessionId };
  },

  assistantDelta(agentId: string, sessionId: string, messageId: string, content: string): SessionEvent {
    return { type: "assistant_delta", agentId, sessionId, messageId, content };
  },

  /// TodoWrite / plan のチェックリスト全置換スナップショット。content は JSON 文字列
  /// `{entries:[{content,status,activeForm?}]}`（mac の plan_update と同形）。
  planUpdate(agentId: string, sessionId: string, entriesJson: string): SessionEvent {
    return { type: "plan_update", agentId, sessionId, content: entriesJson };
  },

  /// サブエージェント / dynamic workflow の進行。content は JSON 文字列
  /// `{subtype,taskId,kind?,workflowName?,status?,agents:[...]}`（mac の workflow_progress と同形）。
  workflowProgress(agentId: string, sessionId: string, payloadJson: string): SessionEvent {
    return { type: "workflow_progress", agentId, sessionId, content: payloadJson };
  },

  /// stop_task_request の返事（頼んだ接続にだけ送る。messageId = requestId）。
  stopTaskResult(agentId: string, sessionId: string, requestId: string, taskId: string, rowId: string | undefined, outcome: StopTaskOutcome): SessionEvent {
    const ok = outcome.kind === "stopped" || outcome.kind === "notRunning" || outcome.kind === "stale";
    const reason = stopReason(outcome);
    const metadata: Metadata = { requestId, taskId, ok: ok ? "1" : "0", reason };
    if (rowId) metadata.rowId = rowId;
    if ((outcome.kind === "failed" || outcome.kind === "unsupported") && outcome.message) metadata.message = outcome.message.slice(0, 200);
    return { type: "stop_task_result", agentId, sessionId, messageId: requestId, metadata };
  },

  /// claude --bg のセッションの一覧の 1 件（content = payloads.bg_session の JSON）。
  bgSessionItem(sessionId: string, rowJson: string): SessionEvent {
    return { type: "bg_session_item", sessionId, content: rowJson };
  },

  bgSessionListEnd(count: number): SessionEvent {
    return { type: "bg_session_list_end", metadata: { count: String(count) } };
  },

  /// 行が変わった（消えた行は {id, sessionId, removed: true} だけの JSON）。
  bgSessionChanged(sessionId: string, rowJson: string): SessionEvent {
    return { type: "bg_session_changed", sessionId, content: rowJson };
  },

  bgSessionResult(sessionId: string | undefined, op: "stop" | "delete", ok: boolean, id: string, shells: number, text: string): SessionEvent {
    return { type: "bg_session_result", sessionId, content: text, metadata: { op, ok: ok ? "1" : "0", id, shells: String(shells) } };
  },

  /// Bridge 全体のバックグラウンドの作業の状態（agentId・sessionId なし。content = payloads.background_work_state の JSON）。
  backgroundWorkState(content: string): SessionEvent {
    return { type: "background_work_state", content };
  },

  done(agentId: string, sessionId: string, messageId: string): SessionEvent {
    return { type: "done", agentId, sessionId, messageId };
  },

  error(agentId: string, sessionId: string | undefined, content: string): SessionEvent {
    return { type: "error", agentId, sessionId, messageId: cryptoRandomId(), content };
  },

  unsupported(rawType: string): SessionEvent {
    return { type: "unsupported_message", content: rawType };
  },

  pong(agentId: string, sessionId?: string): SessionEvent {
    return { type: "pong", agentId, sessionId };
  },

  sessionListItem(agentId: string, summary: SessionSummary, running = false, awaiting = false): SessionEvent {
    const metadata: Metadata = {
      title: summary.title,
      lastActive: summary.lastActive
    };
    if (summary.messageCount !== undefined) metadata.messageCount = String(summary.messageCount);
    if (summary.cwd) metadata.cwd = summary.cwd;
    if (summary.terminal) metadata.terminal = "1";
    // タスクキル復帰直後（未接続）でもサイドバーに稼働中を出すための running フラグ。
    if (running) metadata.running = "1";
    // 承認や質問への回答待ち。開いていないチャットでもサイドバーに「回答待ち」を出す。
    if (awaiting) metadata.awaiting = "1";
    return { type: "session_list_item", agentId, sessionId: summary.sessionId, metadata };
  },

  sessionListEnd(agentId: string): SessionEvent {
    return { type: "session_list_end", agentId };
  },

  historyMessage(agentId: string, sessionId: string, message: HistoryMessage): SessionEvent {
    const metadata: Metadata = { role: message.role };
    if (message.createdAt) metadata.createdAt = message.createdAt;
    if (message.seq !== undefined) metadata.seq = String(message.seq);
    return {
      type: "history_message",
      agentId,
      sessionId,
      messageId: message.messageId,
      content: message.content,
      seq: message.seq,
      metadata
    };
  },

  loadHistoryEnd(agentId: string, sessionId: string, latestSeq?: number): SessionEvent {
    return {
      type: "load_history_end",
      agentId,
      sessionId,
      seq: latestSeq,
      metadata: latestSeq !== undefined ? { latestSeq: String(latestSeq) } : undefined
    };
  },

  inputAck(agentId: string, sessionId: string, clientMessageId: string, acceptedSeq: number): SessionEvent {
    return {
      type: "input_ack",
      agentId,
      sessionId,
      messageId: clientMessageId,
      seq: acceptedSeq,
      metadata: {
        clientMessageId,
        acceptedSeq: String(acceptedSeq)
      }
    };
  },

  inputRejected(agentId: string, sessionId: string | undefined, clientMessageId: string | undefined, reason: string): SessionEvent {
    const metadata: Metadata = { reason };
    if (clientMessageId) metadata.clientMessageId = clientMessageId;
    return {
      type: "input_rejected",
      agentId,
      sessionId,
      messageId: clientMessageId,
      content: reason,
      metadata
    };
  },

  renameSessionResult(agentId: string, sessionId: string, title: string, ok: boolean, message?: string): SessionEvent {
    const metadata: Metadata = { ok: ok ? "1" : "0", title };
    if (message) metadata.message = message;
    return { type: "rename_session_result", agentId, sessionId, content: title, metadata };
  },

  commandItem(agentId: string, command: CommandInfo): SessionEvent {
    const metadata: Metadata = {
      id: command.id,
      kind: command.kind,
      title: command.title
    };
    if (command.subtitle) metadata.subtitle = command.subtitle;
    return { type: "command_item", agentId, metadata };
  },

  commandsEnd(agentId: string): SessionEvent {
    return { type: "commands_end", agentId };
  },

  agentInfoResult(agentId: string, info?: AgentInfo, git?: { branch?: string; cwd?: string }): SessionEvent {
    const metadata: Metadata = {};
    // 作業フォルダとその git ブランチ（iOS の最下部バー用）。branch を cwd に紐づけるので両方揃ったときだけ入れる（mac と同じ）。
    if (git?.branch && git.cwd) {
      metadata.branch = git.branch;
      metadata.cwd = git.cwd;
    }
    if (info?.model) metadata.model = info.model;
    if (info?.provider) metadata.provider = info.provider;
    if (info?.reasoningEffort) metadata.reasoningEffort = info.reasoningEffort;
    if (info?.codexMode) metadata.codexMode = info.codexMode;
    if (info?.approvalPolicy) metadata.approvalPolicy = info.approvalPolicy;
    if (info?.sandboxMode) metadata.sandboxMode = info.sandboxMode;
    if (info?.runtime) metadata.runtime = info.runtime;
    return { type: "agent_info_result", agentId, metadata };
  },

  setModelResult(agentId: string, ok: boolean, message?: string): SessionEvent {
    return { type: "set_model_result", agentId, content: message, metadata: { ok: ok ? "1" : "0" } };
  },

  modelProviderItem(agentId: string, provider: ProviderCatalog): SessionEvent {
    return {
      type: "model_provider_item",
      agentId,
      content: provider.id,
      metadata: {
        providerId: provider.id,
        providerLabel: provider.label,
        models: JSON.stringify(provider.models)
      }
    };
  },

  modelsEnd(agentId: string): SessionEvent {
    return { type: "models_end", agentId };
  },

  /// 送信予約を Bridge が預かった（iOS は自前の自動送信をやめる）。
  queueAck(agentId: string, sessionId: string, clientMessageId: string): SessionEvent {
    return { type: "queue_ack", agentId, sessionId, messageId: clientMessageId, metadata: { clientMessageId } };
  },

  /// 予約していた送信を実行した（iOS は予約カードを普通の吹き出しに替える）。
  queueDispatched(agentId: string, sessionId: string, clientMessageId: string, content: string): SessionEvent {
    return { type: "queue_dispatched", agentId, sessionId, messageId: clientMessageId, content, metadata: { clientMessageId } };
  },

  /// 予約の全件スナップショット。content は JSON `[{clientMessageId, content}]`。
  queueState(agentId: string, sessionId: string, items: Array<{ clientMessageId: string; content: string }>): SessionEvent {
    return { type: "queue_state", agentId, sessionId, content: JSON.stringify(items) };
  },

  projectItem(agentId: string, item: { path: string; name: string; addedAt: number }): SessionEvent {
    return { type: "project_item", agentId, metadata: { path: item.path, name: item.name, addedAt: String(item.addedAt) } };
  },

  projectsEnd(agentId: string): SessionEvent {
    return { type: "projects_end", agentId };
  },

  cronJobItem(agentId: string, job: CronJobItem): SessionEvent {
    const metadata: Metadata = {
      name: job.name,
      schedule: job.scheduleDisplay,
      enabled: job.enabled ? "1" : "0",
      state: job.state,
      deliver: job.deliver
    };
    if (job.nextRunAt) metadata.nextRunAt = job.nextRunAt;
    if (job.lastRunAt) metadata.lastRunAt = job.lastRunAt;
    if (job.lastStatus) metadata.lastStatus = job.lastStatus;
    if (job.lastSessionId) metadata.lastSessionId = job.lastSessionId;
    return { type: "cron_job_item", agentId, sessionId: job.id, content: job.prompt, metadata };
  },

  cronJobListEnd(agentId: string): SessionEvent {
    return { type: "cron_job_list_end", agentId };
  },

  cronOutputsEnd(agentId: string, jobId: string): SessionEvent {
    return { type: "cron_outputs_end", agentId, sessionId: jobId };
  },

  cronJobResult(agentId: string, op: string, jobId: string | undefined, ok: boolean, message: string): SessionEvent {
    const metadata: Metadata = { op, ok: ok ? "1" : "0" };
    if (jobId) metadata.jobId = jobId;
    return { type: "cron_job_result", agentId, sessionId: jobId, content: message, metadata };
  },

  skillItem(agentId: string, name: string, description: string): SessionEvent {
    return { type: "skill_item", agentId, content: description, metadata: { name, description } };
  },

  skillsEnd(agentId: string): SessionEvent {
    return { type: "skills_end", agentId };
  },

  skillContent(agentId: string, name: string, content: string): SessionEvent {
    return { type: "skill_content", agentId, content, metadata: { name } };
  },

  skillOpResult(agentId: string, op: string, name: string, ok: boolean, message?: string): SessionEvent {
    const metadata: Metadata = { op, name, ok: ok ? "1" : "0" };
    if (message) metadata.message = message;
    return { type: "skill_op_result", agentId, content: message, metadata };
  },

  mcpServerItem(agentId: string, name: string, transport: string): SessionEvent {
    return { type: "mcp_server_item", agentId, content: transport, metadata: { name, transport } };
  },

  mcpServersEnd(agentId: string): SessionEvent {
    return { type: "mcp_servers_end", agentId };
  },

  mcpServerOpResult(agentId: string, op: string, serverName: string, ok: boolean, message?: string): SessionEvent {
    const metadata: Metadata = { op, serverName, ok: ok ? "1" : "0" };
    if (message) metadata.message = message;
    return { type: "mcp_server_op_result", agentId, content: message, metadata };
  },

  activity(agentId: string, sessionId: string, messageId: string, content: string): SessionEvent {
    return { type: "activity", agentId, sessionId, messageId, content };
  },

  toolStart(agentId: string, sessionId: string, toolUseId: string, toolName: string, title: string, kind: string): SessionEvent {
    // 開始時刻。クライアントは実行中のツールの経過時間を出す（開き直して流し直されても正しく数える）。
    return { type: "tool_start", agentId, sessionId, toolUseId, toolName, content: title, metadata: { kind, startedAtMs: String(Date.now()) } };
  },

  toolEnd(
    agentId: string,
    sessionId: string,
    toolUseId: string,
    toolName: string,
    status: string,
    summary?: string,
    durationMs?: number
  ): SessionEvent {
    const metadata: Metadata = { status };
    if (durationMs !== undefined) metadata.durationMs = String(durationMs);
    return { type: "tool_end", agentId, sessionId, toolUseId, toolName, content: summary, metadata };
  },

  assistantTurnEnd(agentId: string, sessionId: string, messageId: string): SessionEvent {
    return { type: "assistant_turn_end", agentId, sessionId, messageId };
  },

  /// 再接続した購読者へ進行中ターンのスナップショットを送る（phase=thinking|streaming、
  /// content=進行中 bubble の現時点テキスト＝クライアントは置換）。
  turnResume(
    agentId: string,
    sessionId: string,
    phase: "thinking" | "streaming",
    messageId: string | undefined,
    textSoFar: string,
    toolUseId?: string,
    toolName?: string,
    toolKind?: string
  ): SessionEvent {
    const metadata: Metadata = { phase };
    if (toolKind) metadata.kind = toolKind;
    if (toolUseId) metadata.toolStatus = "in_progress";
    return { type: "turn_resume", agentId, sessionId, messageId, content: textSoFar, toolUseId, toolName, metadata };
  }
};

function cryptoRandomId(): string {
  return globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2);
}
