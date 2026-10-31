import Foundation

enum SessionEventType: String, Codable, CaseIterable {
    case userMessage = "user_message"
    case assistantDelta = "assistant_delta"
    case done
    case proactive
    case error
    case ping
    case pong
    case unsupportedMessage = "unsupported_message"
    // Session management (Sprint 5)
    case listSessionsRequest = "list_sessions_request"
    case sessionListItem = "session_list_item"
    case sessionListEnd = "session_list_end"
    case loadHistoryRequest = "load_history_request"
    case historyMessage = "history_message"
    case loadHistoryEnd = "load_history_end"
    case sessionStarted = "session_started"
    case renameSessionRequest = "rename_session_request"
    case renameSessionResult = "rename_session_result"
    // Cron (Sprint 6)
    case listCronJobsRequest = "list_cron_jobs_request"
    case cronJobItem = "cron_job_item"
    case cronJobListEnd = "cron_job_list_end"
    case createCronRequest = "create_cron_request"
    case deleteCronRequest = "delete_cron_request"
    case pauseCronRequest = "pause_cron_request"
    case resumeCronRequest = "resume_cron_request"
    case cronJobResult = "cron_job_result"          // 作成/削除/pause の結果通知
    case cronOutput = "cron_output"                  // cron が発火して出力した
    case cronOutputsRequest = "cron_outputs_request" // 指定 job の過去出力一覧を要求
    case cronOutputsEnd = "cron_outputs_end"         // 過去出力 stream の終端
    // Skills 管理 (project-local: <cwd>/.claude/skills/<name>/SKILL.md)
    case listSkillsRequest = "list_skills_request"   // metadata: cwd
    case skillItem = "skill_item"                    // content: description, metadata: name/description
    case skillsEnd = "skills_end"
    case loadSkillRequest = "load_skill_request"     // metadata: cwd/name
    case skillContent = "skill_content"              // content: 全文 markdown
    case saveSkillRequest = "save_skill_request"     // content: 全文, metadata: cwd/name
    case deleteSkillRequest = "delete_skill_request" // metadata: cwd/name
    case skillOpResult = "skill_op_result"           // metadata: op/ok/name
    // MCP servers 管理 (read: ~/.hermes/config.yaml 等の mcp_servers)
    case listMcpServersRequest = "list_mcp_servers_request"
    case mcpServerItem = "mcp_server_item"            // metadata: name/transport
    case mcpServersEnd = "mcp_servers_end"
    // MCP servers 書き込み
    case registerMcpServerRequest = "register_mcp_server_request"  // metadata: serverName/transportKind/url/command/args/env
    case deleteMcpServerRequest = "delete_mcp_server_request"      // metadata: serverName
    case mcpServerOpResult = "mcp_server_op_result"               // metadata: op/ok/serverName/message
    // iPhone とデスクトップで共有するプロジェクト（~/.buddyos/projects.json）。どの要求にも全件を返す。
    case listProjectsRequest = "list_projects_request"
    case addProjectRequest = "add_project_request"            // metadata: path/name
    case removeProjectRequest = "remove_project_request"      // metadata: path
    case reorderProjectsRequest = "reorder_projects_request"  // metadata: paths（JSON 配列）
    case projectItem = "project_item"                         // metadata: path/name/addedAt
    case projectsEnd = "projects_end"
    // コネクタとスキルをエージェント間でそろえる（metadata: op=list|sync, items/targets は JSON 配列）。
    case extensionsShareRequest = "extensions_share_request"
    case extensionsShareResult = "extensions_share_result"   // content: JSON（list は表、sync は結果）
    // Push notifications (Sprint 6)
    case registerPushToken = "register_push_token"   // iOS → Bridge: APNs device token 登録
    // Commands / skills palette (Sprint 7)
    case listCommandsRequest = "list_commands_request"  // iOS → Bridge: 利用可能な skill / command を要求
    case commandItem = "command_item"                    // Bridge → iOS: コマンド 1 件
    case commandsEnd = "commands_end"                    // Bridge → iOS: 一覧終端
    // Agent info (model / provider) — chat header 表示用
    case agentInfoRequest = "agent_info_request"
    case agentInfoResult = "agent_info_result"
    case setModelRequest = "set_model_request"
    case setModelResult = "set_model_result"
    case listModelsRequest = "list_models_request"
    case modelProviderItem = "model_provider_item"
    case modelsEnd = "models_end"
    // Agent action requests (approval / option selection)
    case actionRequest = "action_request"
    case actionResponse = "action_response"
    case actionResolved = "action_resolved"   // Bridge → iOS: 承認要求が解決済み（messageId = requestId）。カードを閉じさせる
    case interrupt   // iOS → Bridge: 進行中の応答を中断
    case sessionWarm = "session_warm"   // アプリ → Bridge: チャットを開いた。送る前に裏の CLI を起こしておく（capabilities.warm の agent だけ）
    // ACP streaming (Sprint 8 — hermes acp 直結)
    case activity = "activity"                     // 思考のチラ見せ。生成中だけ表示し終了後は消える
    case toolStart = "tool_start"                  // tool 起動 (vision_analyze, file, ls 等)
    case toolEnd = "tool_end"                      // tool 完了 (status/durationMs を metadata)
    case assistantTurnEnd = "assistant_turn_end"   // 1 ターン内の bubble 分割
    case usageUpdate = "usage_update"              // token / コスト (任意表示)
    // 使用量 (5h / 週リミット %)。サイドバー表示用に Bridge → iOS へ broadcast。
    case usageRequest = "usage_request"            // iOS → Bridge: 即時リフレッシュ要求
    case usageReport = "usage_report"              // Bridge → iOS: content = UsageReport JSON
    // 公開したサイトの一覧（Vercel / Cloudflare Pages。SitesReader）。要求した端末にだけ返す。
    case sitesRequest = "sites_request"            // アプリ → Bridge: metadata["force"] = "1" でキャッシュを使わない
    case sitesReport = "sites_report"              // Bridge → アプリ: content = SiteList JSON（hosts / items / at）
    // メインの定期チェック（MainHeartbeat。docs/MAIN_HEARTBEAT_2026-10-20.md §4）。agentId は見ない（Bridge 全体のもの）。
    case heartbeatGet = "heartbeat_get"            // アプリ → Bridge: 設定と状態を求める
    case heartbeatSet = "heartbeat_set"            // アプリ → Bridge: content = 設定の JSON（一部だけでもよい）
    case heartbeatRunNow = "heartbeat_run_now"     // アプリ → Bridge: 間隔と静かな時間を無視してすぐ回す（動いている最中なら何もしない）
    case heartbeatStatus = "heartbeat_status"      // Bridge → アプリ: content = {"settings":{…},"state":{…}}。返事と、回し始め・終わりに全員へ
    case turnResume = "turn_resume"                // 再接続時の進行中ターン スナップショット
    case turnStatusRequest = "turn_status_request" // iOS → Bridge: 生成中固着の能動プローブ（idle なら done 再送）
    case inputAck = "input_ack"                    // user_message 受領確認（iOS の outbox をクリア）
    case inputRejected = "input_rejected"          // user_message の拒否（baseSeq より後に別の入力がある。content = 理由）
    // Dynamic workflow 進捗 (claude stream-json の system/task_* を正規化)。
    // content = JSON: { subtype, taskId, workflowName?, status?, summary?, description?,
    //   agents?: [{index,label,phaseIndex,phaseTitle,state,model,tokens,toolCalls,durationMs,resultPreview,stoppable}],
    //   phases?: [...]（まだ始まっていない phase の見出し）, stoppable?（カード全体を止められるか） }
    case workflowProgress = "workflow_progress"
    // TodoWrite / ACP plan のチェックリスト進捗（content = entries JSON、全置換スナップショット）
    case planUpdate = "plan_update"
    // Mac 側予約キュー（生成中に積んだ指示を Bridge が保持し、done 後に自動実行する。
    // iOS がアプリを閉じても予約が失われない）。
    case queueUserMessage = "queue_user_message"   // iOS → Bridge: 生成中ターン後に実行する予約
    case queueRemove = "queue_remove"              // iOS → Bridge: 予約取り消し（metadata clientMessageId）
    case queueAck = "queue_ack"                    // Bridge → iOS: 予約預かり確認（metadata clientMessageId）
    case queueDispatched = "queue_dispatched"      // Bridge → iOS: 予約を実行に移した（content = 本文）
    case queueState = "queue_state"                // Bridge → iOS: 予約一覧スナップショット（content = JSON 配列）
    // アプリ層 E2E 暗号化（spec/PROTOCOL-v3.md §13.6）
    case e2eHello = "e2e_hello"                        // Bridge → iOS: E2E 接続の平文 TEXT 1 通のみ。metadata: v/salt/kid (§13.6)
    case e2eError = "e2e_error"                        // Bridge → iOS: metadata["reason"] (unknown_device 等) → 平文継続
    case registerE2EKey = "register_e2e_key"           // iOS → Bridge: content = device_pub b64url、metadata: deviceId/deviceName (§13.6。v3 では断る)
    case e2eRegisterResult = "e2e_register_result"     // Bridge → iOS: metadata["ok"]
    case e2eConfirm = "e2e_confirm"                    // iOS → Bridge: hello 直後の鍵確認 (最初の暗号化フレーム、§13.6)
    // iPhone からエージェントの CLI にログインする（AgentLoginService）。
    case agentLoginRequest = "agent_login_request"     // iOS → Bridge: agentId = 対象、metadata["op"] = start/status/code/cancel、content = コード
    case agentLoginStatus = "agent_login_status"       // Bridge → iOS: metadata phase/url/code/needsCode/message
    // バックグラウンドの作業の停止・一覧・ロック画面（docs/BACKGROUND_CONTROL_2026-10-21.md）
    case stopTaskRequest = "stop_task_request"         // アプリ → Bridge: 行（カード）ごとの停止。metadata: requestId/taskId/rowId?/epoch?
    case stopTaskResult = "stop_task_result"           // Bridge → アプリ: 頼んだ接続にだけ。metadata: requestId/taskId/rowId?/ok/reason/message?
    case listBgSessionsRequest = "list_bg_sessions_request"     // アプリ → Bridge: claude --bg のセッション一覧
    case bgSessionItem = "bg_session_item"                       // Bridge → アプリ: 一覧の 1 件（content = bg_session の JSON）
    case bgSessionListEnd = "bg_session_list_end"                // Bridge → アプリ: 一覧の終わり（metadata count）
    case bgSessionChanged = "bg_session_changed"                 // Bridge → アプリ: 行の変化（全接続へ）
    case stopBgSessionRequest = "stop_bg_session_request"       // アプリ → Bridge: metadata id
    case deleteBgSessionRequest = "delete_bg_session_request"   // アプリ → Bridge: metadata id
    case bgSessionResult = "bg_session_result"                   // Bridge → アプリ: metadata op/ok/id/shells
    case registerActivityToken = "register_activity_token"       // iOS → Bridge: Live Activity の push token
    case backgroundWorkState = "background_work_state"           // Bridge → iOS: Bridge 全体の作業の状態（agentId・sessionId なし）
}

struct SessionEvent: Codable {
    let type: SessionEventType
    let agentId: String?
    let sessionId: String?
    let messageId: String?
    let toolUseId: String?
    let content: String?
    let toolName: String?
    let metadata: [String: String]?
    /// セッション内で単調増加する配信番号（SessionHub が採番。Windows bridge の
    /// LiveHistoryIndex.seq と同義）。iOS は lastHistorySeq として保持し、再接続時の
    /// loadHistoryRequest(sinceSeq:) 差分同期に使う。採番対象外のイベントは nil。
    var seq: Int? = nil

    /// metadata を足した同じイベント（既存のキーは上書き）。
    func addingMetadata(_ extra: [String: String]) -> SessionEvent {
        var copy = SessionEvent(type: type, agentId: agentId, sessionId: sessionId, messageId: messageId,
                                toolUseId: toolUseId, content: content, toolName: toolName,
                                metadata: (metadata ?? [:]).merging(extra) { _, new in new })
        copy.seq = seq
        return copy
    }

    static func userMessage(_ text: String, agentId: String, sessionId: String) -> SessionEvent {
        SessionEvent(
            type: .userMessage, agentId: agentId, sessionId: sessionId,
            messageId: UUID().uuidString, toolUseId: nil, content: ClientTextLimit.clamp(text),
            toolName: nil, metadata: nil
        )
    }

    static func assistantDelta(_ text: String, agentId: String, sessionId: String, messageId: String) -> SessionEvent {
        SessionEvent(
            type: .assistantDelta, agentId: agentId, sessionId: sessionId,
            messageId: messageId, toolUseId: nil, content: text,
            toolName: nil, metadata: nil
        )
    }

    static func done(agentId: String, sessionId: String, messageId: String) -> SessionEvent {
        SessionEvent(
            type: .done, agentId: agentId, sessionId: sessionId,
            messageId: messageId, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    static func sitesReport(_ list: SiteList) -> SessionEvent {
        SessionEvent(
            type: .sitesReport, agentId: nil, sessionId: nil,
            messageId: nil, toolUseId: nil, content: SitesReader.json(list),
            toolName: nil, metadata: nil
        )
    }

    static func heartbeatStatus(_ json: String) -> SessionEvent {
        SessionEvent(
            type: .heartbeatStatus, agentId: nil, sessionId: nil,
            messageId: nil, toolUseId: nil, content: json,
            toolName: nil, metadata: nil
        )
    }

    /// Bridge 全体のバックグラウンドの作業の状態（content = JSON）。heartbeatStatus と同じ形で、agentId・sessionId は付けない。
    static func backgroundWorkState(_ json: String) -> SessionEvent {
        SessionEvent(
            type: .backgroundWorkState, agentId: nil, sessionId: nil,
            messageId: nil, toolUseId: nil, content: json,
            toolName: nil, metadata: nil
        )
    }

    static func agentLoginStatus(_ e: AgentLoginService.Event) -> SessionEvent {
        var meta: [String: String] = ["phase": e.phase.rawValue, "needsCode": e.needsCode ? "1" : "0"]
        if let url = e.url { meta["url"] = url }
        if let code = e.code { meta["code"] = code }
        if let message = e.message { meta["message"] = message }
        return SessionEvent(
            type: .agentLoginStatus, agentId: e.agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: meta
        )
    }

    /// まだ何もしていない（status の問い合わせへの答え）。
    static func agentLoginIdle(agentId: String) -> SessionEvent {
        SessionEvent(
            type: .agentLoginStatus, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: ["phase": "idle", "needsCode": "0"]
        )
    }

    static func unsupported(rawType: String) -> SessionEvent {
        SessionEvent(
            type: .unsupportedMessage, agentId: nil, sessionId: nil,
            messageId: nil, toolUseId: nil, content: rawType,
            toolName: nil, metadata: nil
        )
    }

    /// user_message 受領確認。iOS は clientMessageId 一致で outbox から消す。
    /// これが無いと outbox が永久に残り、再接続のたびに同じ prompt を再送してしまう。
    /// seq: 記録済み user_message の採番。iOS の lastHistorySeq を送信時点まで進める
    /// （Windows bridge が inputAck に userSeq を載せるのと同形）。
    static func inputAck(agentId: String, sessionId: String, clientMessageId: String, seq: Int? = nil) -> SessionEvent {
        SessionEvent(
            type: .inputAck, agentId: agentId, sessionId: sessionId,
            messageId: clientMessageId, toolUseId: nil, content: nil,
            toolName: nil, metadata: ["clientMessageId": clientMessageId], seq: seq
        )
    }

    /// user_message の拒否（Windows の inputRejected と同形）。content = 理由、messageId = clientMessageId。
    /// クライアントは差分同期してから送り直す。
    static func inputRejected(agentId: String, sessionId: String, clientMessageId: String?, reason: String) -> SessionEvent {
        var meta: [String: String] = ["reason": reason]
        if let clientMessageId, !clientMessageId.isEmpty { meta["clientMessageId"] = clientMessageId }
        return SessionEvent(
            type: .inputRejected, agentId: agentId, sessionId: sessionId,
            messageId: clientMessageId, toolUseId: nil, content: reason,
            toolName: nil, metadata: meta
        )
    }

    // MARK: - Mac 側予約キュー

    /// 予約預かり確認。iOS はこれを受けたら「Mac 側で管理中」印を付け、ローカル自動送信を止める。
    static func queueAck(agentId: String, sessionId: String, clientMessageId: String) -> SessionEvent {
        SessionEvent(
            type: .queueAck, agentId: agentId, sessionId: sessionId,
            messageId: clientMessageId, toolUseId: nil, content: nil,
            toolName: nil, metadata: ["clientMessageId": clientMessageId]
        )
    }

    /// 予約を実行に移した通知。iOS は該当の予約カードを消し、通常のユーザーバブルへ置き換える。
    static func queueDispatched(agentId: String, sessionId: String, clientMessageId: String, content: String) -> SessionEvent {
        SessionEvent(
            type: .queueDispatched, agentId: agentId, sessionId: sessionId,
            messageId: clientMessageId, toolUseId: nil, content: content,
            toolName: nil, metadata: ["clientMessageId": clientMessageId]
        )
    }

    /// 予約一覧スナップショット。content = [{"clientMessageId":…,"content":…}] の JSON 配列。
    /// 再接続時にクライアントの予約カード表示を Mac 側の実態へ同期させる。
    static func queueState(agentId: String, sessionId: String, itemsJSON: String) -> SessionEvent {
        SessionEvent(
            type: .queueState, agentId: agentId, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: itemsJSON,
            toolName: nil, metadata: nil
        )
    }

    // MARK: - Session management

    /// preview/lastActive は metadata["title"], metadata["lastActive"], metadata["messageCount"] に入れて運ぶ。
    static func sessionListItem(agentId: String, summary: SessionSummary, running: Bool = false, awaiting: Bool = false) -> SessionEvent {
        var meta: [String: String] = [
            "title": summary.title,
            "lastActive": summary.lastActive
        ]
        if let count = summary.messageCount {
            meta["messageCount"] = String(count)
        }
        if let cwd = summary.cwd, !cwd.isEmpty {
            meta["cwd"] = cwd
        }
        if running {
            meta["running"] = "1"
        }
        if awaiting {
            meta["awaiting"] = "1"
        }
        if summary.terminal {
            meta["terminal"] = "1"
        }
        return SessionEvent(
            type: .sessionListItem, agentId: agentId, sessionId: summary.sessionId,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: meta
        )
    }

    static func sessionListEnd(agentId: String) -> SessionEvent {
        SessionEvent(
            type: .sessionListEnd, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    /// 過去メッセージ。role は metadata["role"] ("user" / "assistant" / "system")。
    /// 画像など添付は userMessage と同じ `attachment_<i>_*` 形式で metadata に inline する
    /// （iOS / desktop の既存デコーダをそのまま再利用できる）。
    static func historyMessage(agentId: String, sessionId: String, role: String, content: String, messageId: String, attachments: [HistoryAttachment] = []) -> SessionEvent {
        var meta: [String: String] = ["role": role]
        if !attachments.isEmpty {
            meta["attachment_count"] = String(attachments.count)
            for (i, a) in attachments.enumerated() {
                meta["attachment_\(i)_kind"] = a.kind
                meta["attachment_\(i)_name"] = a.name
                meta["attachment_\(i)_mime"] = a.mime
                meta["attachment_\(i)_b64"]  = a.b64
            }
        }
        return SessionEvent(
            type: .historyMessage, agentId: agentId, sessionId: sessionId,
            messageId: messageId, toolUseId: nil, content: ClientTextLimit.clamp(content),
            toolName: nil, metadata: meta
        )
    }

    static func loadHistoryEnd(agentId: String, sessionId: String, latestSeq: Int? = nil) -> SessionEvent {
        // latestSeq: live buffer の最新採番。iOS はこれを lastHistorySeq に取り込み、
        // 次回の再接続から sinceSeq 差分要求に切り替える（Windows の loadHistoryEnd と同形）。
        SessionEvent(
            type: .loadHistoryEnd, agentId: agentId, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil, seq: latestSeq
        )
    }

    static func sessionStarted(agentId: String, sessionId: String) -> SessionEvent {
        SessionEvent(
            type: .sessionStarted, agentId: agentId, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    /// rename 結果。content に新タイトル(削除時は空)、metadata["ok"] に "1"/"0"。
    static func renameSessionResult(agentId: String, sessionId: String, title: String, ok: Bool, message: String? = nil) -> SessionEvent {
        var meta: [String: String] = ["ok": ok ? "1" : "0", "title": title]
        if let m = message { meta["message"] = m }
        return SessionEvent(
            type: .renameSessionResult, agentId: agentId, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: title,
            toolName: nil, metadata: meta
        )
    }

    // MARK: - Cron

    /// cron job 1件。sessionId フィールドに job_id を流用。
    static func cronJobItem(agentId: String, job: CronJobSummary) -> SessionEvent {
        var meta: [String: String] = [
            "name": job.name,
            "schedule": job.scheduleDisplay,
            "enabled": job.enabled ? "1" : "0",
            "state": job.state,
            "deliver": job.deliver
        ]
        if let next = job.nextRunAt { meta["nextRunAt"] = next }
        if let last = job.lastRunAt { meta["lastRunAt"] = last }
        if let status = job.lastStatus { meta["lastStatus"] = status }
        if let sid = job.lastSessionId { meta["lastSessionId"] = sid }
        return SessionEvent(
            type: .cronJobItem, agentId: agentId, sessionId: job.id,
            messageId: nil, toolUseId: nil, content: job.prompt,
            toolName: nil, metadata: meta
        )
    }

    static func cronJobListEnd(agentId: String) -> SessionEvent {
        SessionEvent(
            type: .cronJobListEnd, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    /// cron CRUD の応答。content に "ok" / エラー文、metadata["jobId"] に対象 ID、metadata["op"] に "create"/"delete"/"pause"/"resume"。
    static func cronJobResult(agentId: String, op: String, jobId: String?, ok: Bool, message: String) -> SessionEvent {
        var meta: [String: String] = ["op": op, "ok": ok ? "1" : "0"]
        if let jid = jobId { meta["jobId"] = jid }
        return SessionEvent(
            type: .cronJobResult, agentId: agentId, sessionId: jobId,
            messageId: nil, toolUseId: nil, content: message,
            toolName: nil, metadata: meta
        )
    }

    /// cron が発火して出力を生成した。
    static func cronOutput(
        agentId: String,
        jobId: String,
        jobName: String,
        timestamp: String,
        content: String,
        continuableSessionId: String? = nil,
        silent: Bool = false
    ) -> SessionEvent {
        var metadata = ["jobName": jobName, "timestamp": timestamp]
        if let continuableSessionId, !continuableSessionId.isEmpty {
            metadata["continuableSessionId"] = continuableSessionId
        }
        if silent {
            metadata["silent"] = "1"
        }
        return SessionEvent(
            type: .cronOutput, agentId: agentId, sessionId: jobId,
            messageId: nil, toolUseId: nil, content: content,
            toolName: nil, metadata: metadata
        )
    }

    // MARK: - Commands

    static func commandItem(agentId: String, command: CommandInfo) -> SessionEvent {
        var meta: [String: String] = [
            "id": command.id,
            "kind": command.kind,
            "title": command.title
        ]
        if let s = command.subtitle { meta["subtitle"] = s }
        return SessionEvent(
            type: .commandItem, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: meta
        )
    }

    static func commandsEnd(agentId: String) -> SessionEvent {
        SessionEvent(
            type: .commandsEnd, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    /// agent の現在モデル/プロバイダ。chat header 左に表示する用途。
    static func agentInfoResult(
        agentId: String,
        model: String?,
        provider: String?,
        supportedReasoningEfforts: [String]? = nil,
        reasoningEffort: String? = nil,
        codexMode: String? = nil,
        approvalPolicy: String? = nil,
        sandboxMode: String? = nil,
        gitBranch: String? = nil,
        cwd: String? = nil
    ) -> SessionEvent {
        var meta: [String: String] = [:]
        if let m = model { meta["model"] = m }
        if let p = provider { meta["provider"] = p }
        if let values = supportedReasoningEfforts { meta["supportedReasoningEfforts"] = values.joined(separator: ",") }
        if let e = reasoningEffort { meta["reasoningEffort"] = e }
        if let mode = codexMode { meta["codexMode"] = mode }
        if let approval = approvalPolicy { meta["approvalPolicy"] = approval }
        if let sandbox = sandboxMode { meta["sandboxMode"] = sandbox }
        // 作業ディレクトリ（cwd）と、その git ブランチ。iOS の最下部バーが cwd 別に表示する。
        // cwd は branch を cwd へ紐づけるためのキーなので、branch が取れた時だけ両方入れる。
        if let branch = gitBranch, !branch.isEmpty, let cwd, !cwd.isEmpty {
            meta["branch"] = branch
            meta["cwd"] = cwd
        }
        return SessionEvent(
            type: .agentInfoResult, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: meta
        )
    }

    /// hermes config set の結果。metadata["ok"] = "1"/"0"、content にエラーメッセージ。
    static func setModelResult(agentId: String, ok: Bool, message: String?) -> SessionEvent {
        SessionEvent(
            type: .setModelResult, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: message,
            toolName: nil, metadata: ["ok": ok ? "1" : "0"]
        )
    }

    /// プロバイダ 1 件 + 配下のモデル一覧。models は JSON エンコード文字列で metadata["models"]。
    /// content にも providerId を入れて legacy 互換を確保。
    static func modelProviderItem(agentId: String, provider: ProviderCatalog) -> SessionEvent {
        let payload: [[String: String]] = provider.models.map { m in
            var d: [String: String] = ["id": m.id, "label": m.label]
            if let s = m.subtitle { d["subtitle"] = s }
            return d
        }
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "[]"
        let meta: [String: String] = [
            "providerId": provider.id,
            "providerLabel": provider.label,
            "models": json
        ]
        return SessionEvent(
            type: .modelProviderItem, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: provider.id,
            toolName: nil, metadata: meta
        )
    }

    static func modelsEnd(agentId: String) -> SessionEvent {
        SessionEvent(
            type: .modelsEnd, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    // MARK: - Agent actions

    static func actionRequest(
        agentId: String,
        sessionId: String,
        messageId: String,
        title: String,
        subtitle: String?,
        metadata: [String: String]
    ) -> SessionEvent {
        var meta = metadata
        meta["title"] = title
        if let subtitle, !subtitle.isEmpty {
            meta["subtitle"] = subtitle
        }
        return SessionEvent(
            type: .actionRequest,
            agentId: agentId,
            sessionId: sessionId,
            messageId: messageId,
            toolUseId: nil,
            content: title,
            toolName: nil,
            metadata: meta
        )
    }

    /// 承認要求が（別の端末・ターミナル・プロセス終了などで）解決済みになった通知。
    /// iOS は同じ requestId のカードを閉じる。
    /// 既知の劣化: 未対応の旧 iOS（build 106 以前）は未知 type を unsupported_message に落とし、
    /// 空の「未対応メッセージ: 」をチャットに出す（採番対象なので差分 replay でも出る）。
    /// クライアントの対応申告が無いため送り分けはしていない。
    static func actionResolved(agentId: String, sessionId: String, requestId: String) -> SessionEvent {
        SessionEvent(
            type: .actionResolved, agentId: agentId, sessionId: sessionId,
            messageId: requestId, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    // MARK: - ACP streaming

    /// agent_thought_chunk → 一時表示用。content に思考 delta、messageId は属する bubble の id。
    static func activity(agentId: String, sessionId: String, messageId: String, text: String) -> SessionEvent {
        SessionEvent(
            type: .activity, agentId: agentId, sessionId: sessionId,
            messageId: messageId, toolUseId: nil, content: text,
            toolName: nil, metadata: nil
        )
    }

    /// stop_task_request の返事。messageId = requestId。頼んだ接続にだけ送る（記録しない）。
    static func stopTaskResult(agentId: String, sessionId: String, requestId: String, taskId: String,
                               rowId: String?, outcome: StopTaskOutcome) -> SessionEvent {
        var meta: [String: String] = ["requestId": requestId, "taskId": taskId,
                                      "ok": outcome.ok ? "1" : "0", "reason": outcome.reason]
        if let rowId { meta["rowId"] = rowId }
        if let message = outcome.message, !message.isEmpty { meta["message"] = String(message.prefix(200)) }
        return SessionEvent(
            type: .stopTaskResult, agentId: agentId, sessionId: sessionId,
            messageId: requestId, toolUseId: nil, content: nil,
            toolName: nil, metadata: meta
        )
    }

    /// claude --bg のセッションの一覧の 1 件。content は bg_session の JSON。
    static func bgSessionItem(json: String, sessionId: String) -> SessionEvent {
        SessionEvent(
            type: .bgSessionItem, agentId: nil, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: json,
            toolName: nil, metadata: nil
        )
    }

    static func bgSessionListEnd(count: Int) -> SessionEvent {
        SessionEvent(
            type: .bgSessionListEnd, agentId: nil, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: ["count": String(count)]
        )
    }

    /// claude --bg のセッションの行の変化。消えた行は {id, sessionId, removed: true} だけの JSON。
    static func bgSessionChanged(json: String, sessionId: String) -> SessionEvent {
        SessionEvent(
            type: .bgSessionChanged, agentId: nil, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: json,
            toolName: nil, metadata: nil
        )
    }

    /// stop_bg_session_request / delete_bg_session_request の返事。op は stop / delete。
    static func bgSessionResult(op: String, ok: Bool, id: String, shells: Int,
                                sessionId: String?, content: String) -> SessionEvent {
        SessionEvent(
            type: .bgSessionResult, agentId: nil, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: content,
            toolName: nil, metadata: ["op": op, "ok": ok ? "1" : "0", "id": id, "shells": String(shells)]
        )
    }

    /// Dynamic workflow の進捗スナップショット。content は正規化済み JSON 文字列。
    static func workflowProgress(agentId: String, sessionId: String, payloadJSON: String) -> SessionEvent {
        SessionEvent(
            type: .workflowProgress, agentId: agentId, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: payloadJSON,
            toolName: nil, metadata: nil
        )
    }

    /// TodoWrite / ACP plan のチェックリスト進捗スナップショット（全置換）。
    /// content は正規化 JSON: { entries: [{content, status, activeForm?}] }。
    static func planUpdate(agentId: String, sessionId: String, entriesJSON: String) -> SessionEvent {
        SessionEvent(
            type: .planUpdate, agentId: agentId, sessionId: sessionId,
            messageId: nil, toolUseId: nil, content: entriesJSON,
            toolName: nil, metadata: nil
        )
    }

    /// tool_call 開始。kind は "execute"/"read"/"search"/"fetch"/"edit"/"delete"/"move"/"think"/"other"。
    static func toolStart(agentId: String, sessionId: String, toolUseId: String,
                          toolName: String, title: String, kind: String) -> SessionEvent {
        SessionEvent(
            type: .toolStart, agentId: agentId, sessionId: sessionId,
            messageId: nil, toolUseId: toolUseId, content: title,
            toolName: toolName,
            // 開始時刻。クライアントは実行中のツールの経過時間を出す（開き直して流し直されても正しく数える）。
            metadata: ["kind": kind, "startedAtMs": String(Int(Date().timeIntervalSince1970 * 1000))]
        )
    }

    /// tool_call 完了。status は "completed" / "failed" / "in_progress"。
    static func toolEnd(agentId: String, sessionId: String, toolUseId: String,
                        toolName: String, status: String, summary: String?,
                        durationMs: Int?) -> SessionEvent {
        var meta: [String: String] = ["status": status]
        if let d = durationMs { meta["durationMs"] = String(d) }
        return SessionEvent(
            type: .toolEnd, agentId: agentId, sessionId: sessionId,
            messageId: nil, toolUseId: toolUseId, content: summary,
            toolName: toolName, metadata: meta
        )
    }

    /// 1 ターン内の bubble 分割マーカー。messageId は終わったばかりの bubble の id。
    static func assistantTurnEnd(agentId: String, sessionId: String, messageId: String) -> SessionEvent {
        SessionEvent(
            type: .assistantTurnEnd, agentId: agentId, sessionId: sessionId,
            messageId: messageId, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    /// 再接続した購読者だけに送る進行中ターンのスナップショット。
    /// - phase: "thinking" | "streaming"
    /// - messageId: 進行中 bubble の id（streaming 時。thinking で bubble 未開始なら空）
    /// - textSoFar: 進行中 bubble の現時点テキスト（クライアントは「置換」して欠落中間を埋める）
    /// - tool*: 実行中の tool があれば再構築用に渡す
    /// - snapshotSeq: スナップショット時点の最終採番。iOS は同じ bubble でこれ以下の seq の
    ///   assistant_delta（差分 replay で再送される置換済み区間）を捨てる。トップレベルの seq には
    ///   載せない（iOS の lastHistorySeq が進み、欠落区間の差分が取れなくなる）。
    static func turnResume(agentId: String, sessionId: String, phase: String,
                           messageId: String?, textSoFar: String,
                           toolUseId: String?, toolName: String?, toolKind: String?,
                           toolStatus: String?, snapshotSeq: Int? = nil) -> SessionEvent {
        var meta: [String: String] = ["phase": phase]
        if let k = toolKind { meta["kind"] = k }
        if let st = toolStatus { meta["toolStatus"] = st }
        if let snapshotSeq { meta["snapshotSeq"] = String(snapshotSeq) }
        return SessionEvent(
            type: .turnResume, agentId: agentId, sessionId: sessionId,
            messageId: messageId, toolUseId: toolUseId, content: textSoFar,
            toolName: toolName, metadata: meta
        )
    }

    static func cronOutputsEnd(agentId: String, jobId: String) -> SessionEvent {
        SessionEvent(
            type: .cronOutputsEnd, agentId: agentId, sessionId: jobId,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }
}

/// 受信フレームの解釈。enum に無い type でも type 名は失わない（unsupported_message の content に入れて返す）。
enum InboundFrame {
    case event(SessionEvent)
    /// type は読めたが、この Bridge が知らない種別（新しいアプリ → 古い Bridge）。
    case unknownType(String)
    /// JSON でない・type が無い・知っている type なのに形が合わない。
    case malformed

    private struct TypeProbe: Decodable { let type: String? }

    static func parse(_ data: Data) -> InboundFrame {
        if let event = try? JSONDecoder().decode(SessionEvent.self, from: data) { return .event(event) }
        if let raw = (try? JSONDecoder().decode(TypeProbe.self, from: data))?.type, !raw.isEmpty,
           SessionEventType(rawValue: raw) == nil {
            return .unknownType(raw)
        }
        return .malformed
    }

    /// 通信量の集計に使う種別名。知らない type は "unknown" にまとめる（集計のキーを増やさない）。
    static func meterType(_ data: Data) -> String {
        guard let raw = (try? JSONDecoder().decode(TypeProbe.self, from: data))?.type,
              let type = SessionEventType(rawValue: raw) else { return "unknown" }
        return type.rawValue
    }

    private static let loggedLock = NSLock()
    nonisolated(unsafe) private static var loggedUnknown: Set<String> = []

    /// 知らない type を種別ごとに 1 回だけ記録するか。上限を超えたら記録しない。
    static func shouldLogUnknown(_ type: String) -> Bool {
        loggedLock.lock(); defer { loggedLock.unlock() }
        guard loggedUnknown.count < 64 else { return false }
        return loggedUnknown.insert(type).inserted
    }
}

/// Session 一覧表示用の最小データ。
/// クライアント（iPhone / デスクトップ）へ送る 1 メッセージ本文の上限。
/// ターミナルに貼られたクラッシュレポート等（数万字）をそのまま送ると iOS 側の
/// レイアウトが固まり、画面が真っ白になる（2026-09-23 実測: 50,000 字の user 発話）。
/// 先頭だけ送り、省略したことを本文の末尾に明示する。
enum ClientTextLimit {
    static let maxChars = 12_000

    static func clamp(_ text: String) -> String {
        guard text.count > maxChars else { return text }
        let omitted = text.count - maxChars
        return String(text.prefix(maxChars)) + "\n\n…（長いので省略: 残り \(omitted) 文字。全文はターミナル側で）"
    }
}

struct SessionSummary: Sendable {
    let sessionId: String
    let title: String          // = 最初のユーザ発話 preview (~60 char)
    let lastActive: String     // RFC3339 or 自由フォーマット
    let messageCount: Int?
    let cwd: String?
    /// ターミナル（ユーザーが自分で開いた CLI）で今まさに開かれている session。
    /// 一覧では最上部に固定し、クライアントは緑の印を付ける。
    var terminal: Bool = false
}

/// 履歴復元用メッセージ。
struct HistoryMessage: Sendable {
    let role: String           // "user" | "assistant" | "system"
    let content: String
    let messageId: String
    /// 復元する添付（画像など）。空ならテキストのみ。
    var attachments: [HistoryAttachment]

    init(role: String, content: String, messageId: String, attachments: [HistoryAttachment] = []) {
        self.role = role
        self.content = content
        self.messageId = messageId
        self.attachments = attachments
    }
}

/// 履歴メッセージに再添付する 1 件（画像 / ファイル）。b64 は data: プレフィックス無し。
struct HistoryAttachment: Sendable {
    let kind: String           // "image" | "file"
    let name: String
    let mime: String
    let b64: String
}

/// `~/.buddyos/models.json` から取り出すプロバイダごとのモデル一覧。
struct ModelCatalogItem: Sendable, Hashable {
    let id: String
    let label: String
    let subtitle: String?
}

struct ProviderCatalog: Sendable, Hashable {
    let id: String
    let label: String
    let models: [ModelCatalogItem]
}

/// `/` コマンドパレット 1 件。skill = Hermes skill, local = アプリ内 UI コマンド。
struct CommandInfo: Sendable {
    let id: String              // skill name 等。送信時に Hermes へ渡す識別子
    let kind: String            // "skill" | "local"
    let title: String           // 表示名
    let subtitle: String?       // 説明 (category 等)
}

/// Skills 一覧の 1 件 (project-local SKILL.md の frontmatter 抜粋)。
struct SkillSummary: Sendable {
    let name: String           // ディレクトリ名 (= skill id)
    let description: String    // frontmatter の description (なければ空)
}

extension SessionEvent {
    static func skillItem(agentId: String, summary: SkillSummary) -> SessionEvent {
        let meta: [String: String] = [
            "name": summary.name,
            "description": summary.description
        ]
        return SessionEvent(
            type: .skillItem, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: summary.description,
            toolName: nil, metadata: meta
        )
    }

    static func skillsEnd(agentId: String) -> SessionEvent {
        SessionEvent(
            type: .skillsEnd, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    static func skillContent(agentId: String, name: String, content: String) -> SessionEvent {
        SessionEvent(
            type: .skillContent, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: content,
            toolName: nil, metadata: ["name": name]
        )
    }

    static func skillOpResult(agentId: String, op: String, name: String, ok: Bool, message: String?) -> SessionEvent {
        var meta: [String: String] = ["op": op, "ok": ok ? "1" : "0", "name": name]
        if let m = message { meta["message"] = m }
        return SessionEvent(
            type: .skillOpResult, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: message,
            toolName: nil, metadata: meta
        )
    }

    static func mcpServerItem(agentId: String, summary: McpServerSummary) -> SessionEvent {
        let meta: [String: String] = [
            "name": summary.name,
            "transport": summary.transport
        ]
        return SessionEvent(
            type: .mcpServerItem, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: summary.transport,
            toolName: nil, metadata: meta
        )
    }

    static func projectItem(agentId: String, project: SharedProject) -> SessionEvent {
        SessionEvent(
            type: .projectItem, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: ["path": project.path, "name": project.name, "addedAt": String(project.addedAt)]
        )
    }

    static func projectsEnd(agentId: String) -> SessionEvent {
        SessionEvent(
            type: .projectsEnd, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    static func mcpServersEnd(agentId: String) -> SessionEvent {
        SessionEvent(
            type: .mcpServersEnd, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: nil,
            toolName: nil, metadata: nil
        )
    }

    /// MCP サーバの register/delete の結果。skillOpResult と同形。
    static func mcpServerOpResult(agentId: String, op: String, serverName: String, ok: Bool, message: String?) -> SessionEvent {
        var meta: [String: String] = ["op": op, "ok": ok ? "1" : "0", "serverName": serverName]
        if let m = message { meta["message"] = m }
        return SessionEvent(
            type: .mcpServerOpResult, agentId: agentId, sessionId: nil,
            messageId: nil, toolUseId: nil, content: message,
            toolName: nil, metadata: meta
        )
    }
}

/// cron jobs.json から取り出すサマリ。
struct CronJobSummary: Sendable {
    let id: String
    let name: String
    let prompt: String
    let scheduleDisplay: String   // "every 2h" 等
    let deliver: String           // "local" / "origin" / "telegram" 等
    let enabled: Bool
    let state: String             // "scheduled" / "paused" / "running" 等
    let nextRunAt: String?
    let lastRunAt: String?
    let lastStatus: String?
    /// 前回の実行の会話（開ける場合だけ）。
    var lastSessionId: String? = nil
}
