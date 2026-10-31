import Foundation

/// サブエージェント（Agent / Task ツール等で起きたもの）とバックグラウンドのコマンドの進行を、
/// dynamic workflow と同じ workflowProgress の形に正規化する。iPhone・Android・デスクトップは
/// taskId = "subagents" の 1 枚のデータを、サブエージェントとバックグラウンドのコマンドの 2 枚のカードとして描く。
/// 形と規則は docs/BACKGROUND_WORK_2026-10-21.md §3.1・§3.2（shared/protocol.json の payloads["workflow_progress.subagents"]）。
///
/// 入力は 2 系統ある（どちらも実測。claude 2.1.300）:
///   spawn（stream-json）: system/task_started・task_progress・task_updated・task_notification・background_tasks_changed、
///                         assistant 行の tool_use、Agent の tool_result（async_launched）。キーは task_id
///   ターミナル（hooks）  : SubagentStart / SubagentStop、agent_id 付きの PreToolUse、PostToolUse（Agent / Bash / Monitor /
///                         TaskStop）、Stop の background_tasks、task-notification の発話。キーは agent_id（task_id と同じ値）
/// Agent は既定でバックグラウンドで動き、最初の result（Stop）はその完了を待たない。終わると CLI が知らせのターンを始める。
/// 前景の Bash も 2〜5 秒を超えるとタスクになるが、行にするのは裏で動くものだけ（rowKind = shell。Monitor を含む）。
///
/// 行の終わり方は done / failed / stopped。止めたもの（TaskStop・interrupt・後片付け）は stopped、本当の失敗だけが failed。
/// 同じ実行の中で failed / stopped を done に戻さない（再開は begin と、同じ task_id の task_started だけ）。
///
/// 値型。呼び出し側のロック（procLock / actor）の下で使う。
struct SubagentTracker {
    static let taskId = "subagents"

    /// トラッカーの世代（UUID 小文字）。payload にいつも入れる。アプリは epoch が変われば持っている行を捨ててから重ねる
    /// （作り直したトラッカーの index 0 が、前の世代の index 0 の行の値を引き継がないように）。
    let epoch = UUID().uuidString.lowercased()

    private struct Agent: Equatable {
        let index: Int
        /// CLI の識別子（task_id / agent_id / tool_use id / 子 thread id など。行のキー）
        let id: String
        /// agent（サブエージェント）/ shell（バックグラウンドのコマンド。Monitor を含む）
        var rowKind = "agent"
        var label: String
        /// label が既定文（説明が無い）。新しいアプリは自分の言語の既定文を出す。
        var labelIsFallback = false
        /// 委任の中身がタスクの配列のときの件数（既定文「{n} 件のタスク」用）
        var taskCount: Int?
        var agentType: String?
        var state: String            // running / done / failed / stopped
        /// shell の行を起こしたツール（Bash / Monitor / exec など）と、そのコマンド（1 行、200 字まで）
        var tool: String?
        var command: String?
        /// サブエージェントが起こしたシェルなら、親の行の id
        var parentId: String?
        /// ターンより長く動く作業か（バックグラウンドのサブエージェント、run_in_background のシェル）。分からなければ nil。
        var background: Bool?
        var model: String?
        var tokens: Int?
        var toolCalls: Int?
        var durationMs: Int?
        /// durationMs が終わりの usage の duration_ms（いちばん確か。end_time や今の時刻で上書きしない）
        var exactDuration = false
        /// 実行中は今やっていること、終わったら結果の冒頭。
        var preview: String?
        /// 終わった行の結果の本文（2000 字まで）
        var result: String?
        var startedAt: Date
        var endedAt: Date?
        /// stream-json の run_id。再開すると変わる（前の実行の遅れて届いた行と見分ける）
        var runId: String?
        /// stream-json の task_type（local_agent / local_bash など。hooks の行には入れない）。payload には出さない。
        var taskType: String?
        /// Bridge がこの行を止める手がかりを持っている。payload には出さない。
        var stopHandle = false
        /// 停止を CLI に頼んで返事を待っている。payload には出さない。
        var stopRequested = false
    }

    /// beginStop の結果。ok は stopRequested を立てた行の rowKind と、その行の payload（stoppable が false に変わる）。
    enum BeginStop: Equatable {
        case ok(rowKind: String, payload: String?)
        case notRunning
        case unsupported
        case inFlight
    }

    /// hooks: Agent / SendMessage の PreToolUse で受けた起動。SubagentStart（agent_type しか持たない）で引き当てる。
    private struct Launch {
        let toolUseId: String?
        let agentType: String?
        let description: String
        /// SendMessage の宛先。その id の SubagentStart とだけ突き合わせる。
        let to: String?
    }

    /// background_tasks（hooks の Stop。type は表示名）と background_tasks_changed（stream-json。task_type は内部名）の 1 件。
    private struct Listed {
        let id: String
        let rowKind: String
        let agentType: String?
        let label: String?
        let tool: String?
        let command: String?
        let parentId: String?
        let runId: String?
        /// stream-json の task_type（hooks の一覧には無い）
        let taskType: String?
    }

    /// 上限つきの覚え書き。古いものから捨てる。
    private struct Recent<Value> {
        let limit: Int
        private var values: [String: Value] = [:]
        private var order: [String] = []

        init(limit: Int) { self.limit = limit }

        subscript(key: String) -> Value? { values[key] }

        mutating func set(_ key: String, _ value: Value) {
            if values.updateValue(value, forKey: key) == nil { order.append(key) }
            while order.count > limit { values.removeValue(forKey: order.removeFirst()) }
        }

        @discardableResult
        mutating func remove(_ key: String) -> Value? {
            guard let v = values.removeValue(forKey: key) else { return nil }
            order.removeAll { $0 == key }
            return v
        }
    }

    private var agents: [String: Agent] = [:]
    private var nextIndex = 0
    /// 親の tool_use id → サブエージェントのキー（stream-json のサブエージェント行は parent_tool_use_id を持つ）。
    private var keyByToolUseId: [String: String] = [:]
    /// stream-json: assistant 行の tool_use（id → ツール名とコマンド）。task_started.tool_use_id から Monitor
    /// （task_type は local_bash）を見分け、shell の行の tool と command を埋める。
    private var toolUses = Recent<(name: String, command: String?)>(limit: 128)
    /// stream-json: 前景のシェルの task_started（2〜5 秒を超えた普通の Bash もタスクになる）。行にはせず、
    /// 後で裏に回ったら（task_updated の is_backgrounded・background_tasks_changed に載る）行にする。
    private var foregroundTasks = Recent<[String: Any]>(limit: 32)
    /// stream-json: dynamic workflow（local_workflow か workflow_name 付き）の task_id。workflow のカードが出すので行にしない。
    private var workflowTasks: Set<String> = []
    private var pendingLaunches: [Launch] = []
    /// hooks: run_in_background で起動したツールの説明（tool_use id → 行の見出し）。PostToolUse の backgroundTaskId で引き当てる。
    private var pendingShells: [String: String] = [:]
    /// hooks: 行にしない SubagentStart（内部の補助と、起動の PreToolUse を伴わないもの）。
    private var ignored: Set<String> = []

    /// true の間、taskType が local_agent / local_bash の行に stopHandle を立てる（Claude の spawn 経路が stop_task を
    /// 宣言できたとき）。値が変わったら全行を計算し直す。payload が要るときは setClaudeStopTask を使う。
    var claudeStopTask = false {
        didSet { if claudeStopTask != oldValue { for key in agents.keys { applyClaudeStopHandle(key) } } }
    }

    /// claudeStopTask を変え、stoppable が変わった行があれば workflow_snapshot の payload を返す。
    mutating func setClaudeStopTask(_ on: Bool) -> String? {
        let before = agents.mapValues { $0.stopHandle }
        claudeStopTask = on
        guard agents.contains(where: { before[$0.key] != $0.value.stopHandle }) else { return nil }
        return snapshot()
    }

    var isEmpty: Bool { agents.isEmpty }
    var hasRunning: Bool { agents.values.contains { $0.state == "running" } }
    /// 動いているサブエージェントがあるか（バックグラウンドのシェルは数えない）。ターンの終わりの扱いに使う。
    var hasRunningAgents: Bool { runningAgentCount > 0 }
    /// 動いているサブエージェントの行の数（ターミナル経路の workflow / teammate の行も含む）。
    var runningAgentCount: Int { agents.values.filter { $0.state == "running" && $0.rowKind == "agent" }.count }
    /// 動いている背景のサブエージェントの行の数（Live Activity 用。background == true の agent 行だけ）。
    var runningBackgroundOnlyAgentCount: Int {
        agents.values.filter { $0.state == "running" && $0.rowKind == "agent" && $0.background == true }.count
    }
    /// 動いているバックグラウンドのコマンドの行の数（Monitor を含む）。
    var runningShellCount: Int { agents.values.filter { $0.state == "running" && $0.rowKind == "shell" }.count }

    /// stream-json で dynamic workflow（task_type = local_workflow か workflow_name 付き）として見た task_id か。
    /// その task_* 行は workflow のカードに回す（このトラッカーでは行にしない）。
    func isWorkflowTask(_ taskId: String) -> Bool { workflowTasks.contains(taskId) }

    /// 新しいターンを始める前に、終わった行を忘れる（クライアントも送信で終わった行を捨てる）。
    /// バックグラウンドで動き続けているものは残す。知らせのターンでは呼ばない（終わった結果をカードに残す）。
    mutating func pruneFinished() {
        agents = agents.filter { $0.value.state == "running" }
        let live = Set(agents.keys)
        keyByToolUseId = keyByToolUseId.filter { live.contains($0.value) }
        pendingLaunches.removeAll()
        pendingShells.removeAll()
        ignored.removeAll()
    }

    // MARK: - stream-json（spawn）

    /// system/task_* 行・background_tasks_changed・assistant 行・Agent の tool_result を反映する。
    /// 変化があれば payload JSON を返す。
    mutating func ingestStreamLine(_ obj: [String: Any]) -> String? {
        switch obj["type"] as? String {
        case "assistant": return ingestAssistant(obj)
        case "user": return ingestAsyncLaunch(obj)
        case "system": break
        default: return nil
        }
        guard let subtype = obj["subtype"] as? String else { return nil }
        // background_tasks_changed はトップレベルに task_id を持たない（tasks がその時点で動いているものの全部）。
        if subtype == "background_tasks_changed" { return ingestBackgroundTasks(obj["tasks"]) }
        guard let key = obj["task_id"] as? String, !key.isEmpty else { return nil }
        // workflow（local_workflow）は workflowEventPayload が別カードで出す。task_id を覚えて行にしない
        // （task_notification は task_type も workflow_name も持たないので、id で見分ける）。
        if obj["task_type"] as? String == "local_workflow" || obj["workflow_progress"] != nil
            || obj["workflow_name"] != nil {
            workflowTasks.insert(key)
            return nil
        }
        guard !workflowTasks.contains(key) else { return nil }
        switch subtype {
        case "task_started": return taskStarted(key, obj)
        case "task_progress": return taskProgress(key, obj)
        case "task_updated": return taskUpdated(key, obj)
        case "task_notification": return taskNotification(key, obj)
        default: return nil
        }
    }

    /// assistant 行。tool_use は main もサブエージェントも覚え（task_started の tool_use_id から引く）、
    /// サブエージェントの行ならモデルと、いま呼んだツールを拾う。
    private mutating func ingestAssistant(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        let uses = ((message["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "tool_use" }
        for block in uses {
            guard let id = Self.nonEmpty(block["id"]), let name = Self.nonEmpty(block["name"]) else { continue }
            let command = Self.nonEmpty((block["input"] as? [String: Any])?["command"]).map { Self.preview($0, limit: 200) }
            toolUses.set(id, (name: name, command: command))
        }
        guard let parent = obj["parent_tool_use_id"] as? String,
              let key = keyByToolUseId[parent], var a = agents[key], a.state == "running" else { return nil }
        var changed = false
        if let m = message["model"] as? String, !m.isEmpty, a.model != m { a.model = m; changed = true }
        for block in uses {
            a.preview = Self.toolActivity(name: block["name"] as? String ?? "tool", input: block["input"])
            changed = true
        }
        guard changed else { return nil }
        agents[key] = a
        return payload(key)
    }

    /// main の user 行の Agent の tool_result（tool_use_result.status = async_launched）。その id の行をバックグラウンドにする。
    private mutating func ingestAsyncLaunch(_ obj: [String: Any]) -> String? {
        guard obj["parent_tool_use_id"] as? String == nil,
              let r = obj["tool_use_result"] as? [String: Any], r["status"] as? String == "async_launched",
              let id = Self.nonEmpty(r["agentId"]) else { return nil }
        let toolUseId = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]])?
            .first { $0["type"] as? String == "tool_result" }?["tool_use_id"] as? String
        return bindAsyncLaunch(agentId: id, description: Self.nonEmpty(r["description"]), agentType: nil,
                               model: Self.nonEmpty(r["resolvedModel"]), toolUseId: toolUseId)
    }

    /// task_started。サブエージェント（local_agent か subagent_type）は前景・バックグラウンドに関係なく行にし、
    /// シェル（local_bash・monitor_*・mcp_task）は裏で動くものだけを行にする（前景のものは id だけ覚えておく）。
    /// 既にある行に来たら（run_id が違う・終わっている）再開とみなし、やり直す。
    private mutating func taskStarted(_ key: String, _ obj: [String: Any]) -> String? {
        let taskType = obj["task_type"] as? String
        let isAgent = taskType == "local_agent" || obj["subagent_type"] != nil
        guard isAgent || Self.isShellTask(taskType) else { return nil }
        if !isAgent, agents[key] == nil, obj["is_backgrounded"] as? Bool == false {
            foregroundTasks.set(key, obj)
            return nil
        }
        let runId = obj["run_id"] as? String
        if let a = agents[key], a.state == "running", let runId, let current = a.runId, runId != current {
            restart(key)
        }
        let toolUseId = obj["tool_use_id"] as? String
        let use = toolUseId.flatMap { toolUses[$0] }
        let label = (obj["description"] as? String) ?? (obj["command"] as? String).map { Self.preview($0, limit: 80) }
        _ = begin(key: key, label: label, agentType: isAgent ? obj["subagent_type"] as? String : nil,
                  toolUseId: toolUseId, background: isAgent ? obj["is_backgrounded"] as? Bool : true,
                  rowKind: isAgent ? "agent" : "shell", tool: isAgent ? nil : use?.name,
                  command: isAgent ? nil : (use?.command ?? obj["command"] as? String))
        if let runId { agents[key]?.runId = runId }
        if let taskType { agents[key]?.taskType = taskType; applyClaudeStopHandle(key) }
        if !isAgent, let parent = Self.nonEmpty(obj["parent_task_id"]) { agents[key]?.parentId = parent }
        return payload(key)
    }

    private mutating func taskProgress(_ key: String, _ obj: [String: Any]) -> String? {
        guard var a = agents[key], a.state == "running", Self.sameRun(a, obj) else { return nil }
        if let d = obj["description"] as? String, !d.isEmpty { a.preview = Self.preview(d) }
        else if let t = obj["last_tool_name"] as? String, !t.isEmpty { a.preview = t }
        Self.applyUsage(obj["usage"], to: &a, final: false)
        agents[key] = a
        return payload(key)
    }

    /// task_updated。patch.status（completed / failed / killed）で閉じ、patch.end_time を終わった時刻と所要時間にする。
    /// patch.is_backgrounded == true なら、前景で覚えていたシェルを行にする（後から裏に回された）。
    private mutating func taskUpdated(_ key: String, _ obj: [String: Any]) -> String? {
        let patch = obj["patch"] as? [String: Any] ?? [:]
        let status = patch["status"] as? String
        guard let current = agents[key] else {
            guard let started = foregroundTasks[key] else { return nil }
            if status.flatMap(Self.finalState) != nil { foregroundTasks.remove(key); return nil }
            guard patch["is_backgrounded"] as? Bool == true else { return nil }
            foregroundTasks.remove(key)
            var promoted = started
            promoted["is_backgrounded"] = true
            return taskStarted(key, promoted)
        }
        guard Self.sameRun(current, obj) else { return nil }
        if patch["is_backgrounded"] as? Bool == true { agents[key]?.background = true }
        let end = Self.int(patch["end_time"]).map { Date(timeIntervalSince1970: Double($0) / 1000) }
        if let status { settle(key, state: status, result: nil, endedAt: end) }
        // 終わりの知らせ（task_notification）が先に来ていても、end_time の方が正確。
        if let end, var a = agents[key], a.state != "running" {
            a.endedAt = end
            if !a.exactDuration { a.durationMs = Self.ms(from: a.startedAt, to: end) }
            agents[key] = a
        }
        return agents[key] == current ? nil : payload(key)
    }

    /// task_notification。status（completed / failed / stopped）で閉じ、summary を結果に、usage を数値にする。
    private mutating func taskNotification(_ key: String, _ obj: [String: Any]) -> String? {
        guard let current = agents[key] else {
            foregroundTasks.remove(key)   // 前景のまま終わったシェル
            return nil
        }
        guard Self.sameRun(current, obj) else { return nil }
        let summary = Self.informative(obj["summary"] as? String, label: current.label)
        settle(key, state: obj["status"] as? String ?? "completed", result: summary)
        if var a = agents[key] {
            Self.applyUsage(obj["usage"], to: &a, final: true)
            agents[key] = a
        }
        return agents[key] == current ? nil : payload(key)
    }

    /// system/background_tasks_changed（その時点で動いているバックグラウンドのタスクの全部。終われば []）。
    /// 知らないものは行を作り、background == true で動いているのに載っていない行は done で閉じる。前景の行は閉じない。
    private mutating func ingestBackgroundTasks(_ raw: Any?) -> String? {
        guard let tasks = raw as? [[String: Any]] else { return nil }
        var items: [Listed] = []
        for t in tasks {
            if t["task_type"] as? String == "local_workflow", let id = Self.nonEmpty(t["task_id"]) {
                workflowTasks.insert(id)
                continue
            }
            if let item = Self.listed(t), !workflowTasks.contains(item.id) { items.append(item) }
        }
        return reconcile(items, present: Set(tasks.compactMap(Self.listedId)), closeForeground: false)
    }

    // MARK: - hooks（ターミナル）

    /// 親（agent_id の無い）PreToolUse。Agent / Task ツールと、止まったサブエージェントに話しかけ直す SendMessage は
    /// 説明を SubagentStart まで、run_in_background なら PostToolUse まで取っておく。
    mutating func noteLaunch(toolName: String, input: Any?, toolUseId: String? = nil) {
        let dict = input as? [String: Any]
        if let toolUseId, dict?["run_in_background"] as? Bool == true, !Self.isAgentTool(toolName) {
            pendingShells[toolUseId] = Self.nonEmpty(dict?["description"]) ?? Self.toolActivity(name: toolName, input: input)
            if pendingShells.count > 20, let k = pendingShells.keys.first { pendingShells.removeValue(forKey: k) }
            return
        }
        if Self.isAgentTool(toolName) {
            pendingLaunches.append(Launch(toolUseId: toolUseId, agentType: Self.nonEmpty(dict?["subagent_type"]),
                                          description: Self.nonEmpty(dict?["description"]) ?? "", to: nil))
        } else if toolName == "SendMessage", let to = Self.nonEmpty(dict?["to"]) {
            // 動いている相手への SendMessage は次のツールの区切りで届くだけで、SubagentStart は来ない。積まない。
            guard agents[to]?.state != "running" else { return }
            let description = Self.nonEmpty(dict?["summary"])
                ?? Self.nonEmpty(dict?["message"]).map { Self.preview($0, limit: 80) } ?? ""
            pendingLaunches.removeAll { $0.to == to }
            pendingLaunches.append(Launch(toolUseId: toolUseId, agentType: nil, description: description, to: to))
        } else {
            return
        }
        if pendingLaunches.count > 20 { pendingLaunches.removeFirst() }
    }

    /// 行にしない SubagentStart の agent_id か（そのツール呼び出しも親の行に出さない）。
    func isIgnored(_ agentId: String) -> Bool { ignored.contains(agentId) }

    mutating func hookStart(agentId: String, agentType: String?) -> String? {
        // 内部の補助（agent_type が空か無い）は行にしない。
        if Self.isInternalHelper(agentId: agentId, agentType: agentType) {
            ignored.insert(agentId)
            return nil
        }
        // 知っている行（PostToolUse(Agent) が先に来た・話しかけ直された）は、起動待ちを使わずに続きとして動かす。
        if agents[agentId] != nil {
            pendingLaunches.removeAll { $0.to == agentId }
            return begin(key: agentId, label: nil, agentType: agentType)
        }
        // SendMessage は宛先の id とだけ、Agent は同じ種類のうち一番古い起動と突き合わせる
        // （並列起動でも PreToolUse → SubagentStart の順は保たれる。ずれたら PostToolUse(Agent) で直す）。
        guard let i = pendingLaunches.firstIndex(where: { $0.to == agentId })
                ?? pendingLaunches.firstIndex(where: { $0.to == nil && ($0.agentType == nil || $0.agentType == agentType) })
        else {
            // 起動の PreToolUse を伴わないもの（Skill の fork 等）は、まだ出さない。
            // 本物なら PostToolUse(Agent) か Stop の background_tasks で拾い直す。
            ignored.insert(agentId)
            return nil
        }
        let launch = pendingLaunches.remove(at: i)
        return begin(key: agentId, label: launch.description, agentType: agentType)
    }

    /// PostToolUse（main のスレッド）。バックグラウンドで起動したもの（Bash の backgroundTaskId・Monitor の taskId）は行を作る。
    /// Agent の async_launched は agentId の行に説明と種類を結び付け、TaskStop は止めた行をすぐ stopped で閉じる
    /// （止めたシェルには完了の知らせが来ない）。
    mutating func hookToolResult(toolUseId: String?, toolName: String, input: Any?, response: Any?) -> String? {
        let pending = toolUseId.flatMap { pendingShells.removeValue(forKey: $0) }
        let dict = input as? [String: Any]
        let resp = response as? [String: Any]
        if Self.isAgentTool(toolName) {
            guard resp?["status"] as? String == "async_launched", let id = Self.nonEmpty(resp?["agentId"]) else { return nil }
            return bindAsyncLaunch(agentId: id,
                                   description: Self.nonEmpty(dict?["description"]) ?? Self.nonEmpty(resp?["description"]),
                                   agentType: Self.nonEmpty(dict?["subagent_type"]),
                                   model: Self.nonEmpty(resp?["resolvedModel"]), toolUseId: toolUseId)
        }
        if toolName == "TaskStop" || toolName == "KillShell" {
            guard let id = Self.nonEmpty(resp?["task_id"]) ?? Self.nonEmpty(dict?["task_id"])
                    ?? Self.nonEmpty(dict?["shell_id"]) else { return nil }
            return finish(key: id, state: "stopped", result: nil)
        }
        let id = toolName == "Monitor" ? Self.nonEmpty(resp?["taskId"]) : Self.nonEmpty(resp?["backgroundTaskId"])
        guard let id else { return nil }
        let label = pending ?? Self.nonEmpty(dict?["description"]) ?? Self.toolActivity(name: toolName, input: input)
        return begin(key: id, label: label, background: true, rowKind: "shell", tool: toolName,
                     command: Self.nonEmpty(dict?["command"]))
    }

    /// バックグラウンドで起動した Agent（PostToolUse / tool_result の async_launched と agentId）を、その id の行に結び付ける。
    /// SubagentStart より先に来ることがあるので、行が無ければ作る。起動待ちは tool_use id で消す。
    private mutating func bindAsyncLaunch(agentId: String, description: String?, agentType: String?,
                                          model: String?, toolUseId: String?) -> String? {
        if let toolUseId { pendingLaunches.removeAll { $0.toolUseId == toolUseId } }
        ignored.remove(agentId)
        guard var a = agents[agentId] else {
            return begin(key: agentId, label: description, agentType: agentType, model: model, background: true)
        }
        let old = a
        let newModel = a.model == nil ? model : nil
        Self.fill(&a, label: description, agentType: agentType, model: newModel, background: true)
        guard a != old else { return nil }
        agents[agentId] = a
        return payload(agentId)
    }

    /// 完了の知らせ（<task-notification> … </task-notification>。発話として届くか、transcript に積まれる）。
    /// 知っている行を閉じ、<result>（無ければ <summary>）を結果に、<usage> を数値にする。変化した行の payload を返す。
    mutating func ingestNotifications(_ text: String) -> [String] {
        guard text.contains("<task-notification>") else { return [] }
        var out: [String] = []
        for n in Self.taskNotifications(in: text) {
            guard let current = agents[n.taskId] else { continue }
            // <summary> はサブエージェントだと「Agent "…" finished」の決まり文句。既に結果のある終わった行は上書きしない。
            let summary = current.state != "running" && current.preview != nil
                ? nil : Self.informative(n.summary, label: current.label)
            settle(n.taskId, state: Self.finalState(n.status) ?? "done", result: n.result ?? summary)
            if var a = agents[n.taskId] {
                if let v = n.tokens { a.tokens = v }
                if let v = n.toolUses { a.toolCalls = v }
                if let v = n.durationMs { a.durationMs = v; a.exactDuration = true }
                agents[n.taskId] = a
            }
            if agents[n.taskId] != current, let p = payload(n.taskId) { out.append(p) }
        }
        return out
    }

    /// Stop hook の background_tasks（その時点で動いている・待っているバックグラウンドの作業の全部）と突き合わせる。
    /// 知らないものは行を作り（種類は完全一致で振り分ける）、一覧に無い実行中の行はサブエージェントもシェルも done で閉じる
    /// （終わりの知らせを取りこぼしても残らない）。照合に使うのは Stop の一覧だけ（SubagentStop の一覧は、終わった
    /// サブエージェント自身を running のまま含む）。closeForeground = false では background != true の行を閉じない。
    mutating func reconcile(backgroundTasks raw: Any?, closeForeground: Bool = true) -> String? {
        guard let tasks = raw as? [[String: Any]] else { return nil }
        return reconcile(tasks.compactMap(Self.listed), present: Set(tasks.compactMap(Self.listedId)),
                         closeForeground: closeForeground)
    }

    private mutating func reconcile(_ items: [Listed], present: Set<String>, closeForeground: Bool) -> String? {
        var changed: [String] = []
        for t in items {
            if let current = agents[t.id] {
                if let run = t.runId, let prev = current.runId, run != prev {
                    // 同じ task_id が新しい run_id で載った（終わったサブエージェントの再開）。
                    restart(t.id)
                    agents[t.id]?.runId = run
                }
                // 一覧に載るのは裏で動くものだけ。
                if agents[t.id]?.state == "running" { agents[t.id]?.background = true }
                if let type = t.taskType, agents[t.id]?.taskType == nil {
                    agents[t.id]?.taskType = type
                    applyClaudeStopHandle(t.id)
                }
                if agents[t.id] != current { changed.append(t.id) }
                continue
            }
            ignored.remove(t.id)
            if let started = foregroundTasks.remove(t.id) {
                // 前景で覚えていたシェルが裏に回った。task_started の中身（ツール・コマンド・親）を使う。
                var promoted = started
                promoted["is_backgrounded"] = true
                _ = taskStarted(t.id, promoted)
            } else {
                _ = begin(key: t.id, label: t.label, agentType: t.agentType, background: true, rowKind: t.rowKind,
                          tool: t.tool, command: t.command)
                if let run = t.runId { agents[t.id]?.runId = run }
                if let type = t.taskType { agents[t.id]?.taskType = type; applyClaudeStopHandle(t.id) }
                if t.rowKind == "shell", let parent = t.parentId { agents[t.id]?.parentId = parent }
            }
            if agents[t.id] != nil { changed.append(t.id) }
        }
        for (key, a) in agents where a.state == "running" && !present.contains(key)
            && (closeForeground || a.background == true) {
            if settle(key, state: "done", result: nil) { changed.append(key) }
        }
        guard !changed.isEmpty else { return nil }
        return payload(rows: changed.compactMap { agents[$0] }.sorted { $0.index < $1.index })
    }

    /// サブエージェントの中で呼ばれたツール。SubagentStart を受けていないもの（hook が古い install 等）は
    /// 行を作らない（終わりの SubagentStop も来ないので、行が「実行中」のまま残る）。呼び出し側は contains で
    /// 確かめて、知らないものは今までどおり親のツール行として出す。
    mutating func hookTool(agentId: String, agentType: String?, toolName: String, input: Any?) -> String? {
        activity(key: agentId, text: Self.toolActivity(name: toolName, input: input), toolCall: true)
    }

    mutating func hookStop(agentId: String, agentType: String?, lastMessage: String?) -> String? {
        // 行にしていない補助と、SubagentStart を受けていないもの（hook が古い install 等）は出さない。
        guard agents[agentId] != nil else { ignored.remove(agentId); return nil }
        // Esc で stopped にした行は done に戻さない（finish が受けない）。
        return finish(key: agentId, state: "done", result: lastMessage)
    }

    /// 中断・プロセス終了・close で、もう終わりの知らせが来ない実行中の行を閉じる。既定は stopped（自分で止めた）。
    /// プロセスが異常終了したときだけ failed を渡す。閉じた行があれば payload を返す（index は使い回さない）。
    /// includeShells = false ではバックグラウンドのシェルを閉じない。onlyForeground = true（Esc の中断）では
    /// background != true の行だけを閉じる（バックグラウンドのサブエージェントは Esc では止まらない）。
    /// except に入れた鍵の行は閉じない（OpenClaw の子は ACP プロセスが死んでも gateway で動き続ける）。
    mutating func abandonRunning(state: String = "stopped", includeShells: Bool = true,
                                 onlyForeground: Bool = false, except: Set<String> = []) -> String? {
        let keys = agents.values.filter {
            $0.state == "running" && (includeShells || $0.rowKind == "agent") && !(onlyForeground && $0.background == true)
                && !except.contains($0.id)
        }.map(\.id)
        var closed: [Agent] = []
        for key in keys {
            if settle(key, state: state, result: nil), let a = agents[key] { closed.append(a) }
        }
        guard !closed.isEmpty else { return nil }
        return payload(rows: closed.sorted { $0.index < $1.index })
    }

    // MARK: - 汎用（Codex / OpenCode / ACP 等。キーは各 CLI のサブエージェント識別子）

    func contains(_ key: String) -> Bool { agents[key] != nil }

    func isRunning(key: String) -> Bool { agents[key]?.state == "running" }

    /// 行の state（running / done / failed / stopped）。行が無ければ nil。
    func state(key: String) -> String? { agents[key]?.state }

    func isStopRequested(key: String) -> Bool { agents[key]?.stopRequested == true }

    /// Codex・OpenCode が、行を止める手がかり（processId・子の turn id・子のセッション id）を持ったか持たなくなったかを知らせる。
    /// stoppable が変わったときだけ、その行の payload を返す。
    mutating func setStopHandle(key: String, on: Bool) -> String? {
        guard var a = agents[key], a.stopHandle != on else { return nil }
        a.stopHandle = on
        agents[key] = a
        return payload(key)
    }

    /// 停止を CLI に頼む前に呼ぶ。ok なら stopRequested を立てて（stoppable が false の行を payload で返す）、頼んでよい。
    mutating func beginStop(key: String) -> BeginStop {
        guard var a = agents[key], a.state == "running" else { return .notRunning }
        if a.stopRequested { return .inFlight }
        guard a.stopHandle else { return .unsupported }
        a.stopRequested = true
        agents[key] = a
        return .ok(rowKind: a.rowKind, payload: payload(key))
    }

    /// 停止が失敗・時間切れ・対応外だったとき。返事待ちを戻し、stoppable が変わった行の payload を返す。
    mutating func endStop(key: String) -> String? {
        guard var a = agents[key], a.stopRequested else { return nil }
        a.stopRequested = false
        agents[key] = a
        return payload(key)
    }

    /// claudeStopTask が true の間、task_type が local_agent / local_bash の行に stopHandle を立てる（false なら下ろす）。
    /// task_type を持たない行（hooks・Codex など）は触らない。
    private mutating func applyClaudeStopHandle(_ key: String) {
        guard let type = agents[key]?.taskType, Self.claudeStoppableTypes.contains(type) else { return }
        agents[key]?.stopHandle = claudeStopTask
    }

    private static let claudeStoppableTypes: Set<String> = ["local_agent", "local_bash"]

    /// 行の開始。既にあれば分かったことを足す（rowKind は作るときだけ）。終わっていた行（Codex の sendInput 等で
    /// 話しかけ直された・再開した）は実行中に戻し、開始時刻をやり直して、所要時間・作業の文・結果を消す。
    /// labelIsFallback = true の label（「3 件のタスク」等）は、説明の入った label を上書きしない。
    /// startedAt は CLI が知らせた開始時刻（Codex の item/started の startedAtMs など）。行を作る・開き直すときだけ使い、
    /// 無ければ今の時刻。
    mutating func begin(key: String, label: String?, agentType: String? = nil, model: String? = nil,
                        toolUseId: String? = nil, background: Bool? = nil, rowKind: String = "agent",
                        tool: String? = nil, command: String? = nil, labelIsFallback: Bool? = nil,
                        taskCount: Int? = nil, startedAt: Date? = nil) -> String? {
        if let toolUseId { keyByToolUseId[toolUseId] = key }
        if agents[key] == nil {
            // 説明が無いときの既定文（古いアプリ向け。新しいアプリは labelIsFallback を見て自分の言語で出す）。
            let fallback = rowKind == "shell" ? "バックグラウンドのコマンド" : "サブエージェント"
            agents[key] = Agent(index: nextIndex, id: key, rowKind: rowKind, label: fallback, labelIsFallback: true,
                                state: "running", startedAt: startedAt ?? Date())
            nextIndex += 1
        } else if agents[key]?.state != "running" {
            restart(key, startedAt: startedAt)
        }
        Self.fill(&agents[key]!, label: label, labelIsFallback: labelIsFallback, taskCount: taskCount,
                  agentType: agentType, model: model, background: background, tool: tool, command: command)
        return payload(key)
    }

    /// いまやっていること。toolCall なら呼び出し回数も数える。知らないキーか、終わった行なら nil。
    mutating func activity(key: String, text: String?, toolCall: Bool = false,
                           toolCalls: Int? = nil, tokens: Int? = nil, model: String? = nil) -> String? {
        guard var a = agents[key], a.state == "running" else { return nil }
        if let text, !text.isEmpty { a.preview = Self.preview(text, limit: 120) }
        if toolCall { a.toolCalls = (a.toolCalls ?? 0) + 1 }
        if let toolCalls { a.toolCalls = toolCalls }
        if let tokens { a.tokens = tokens }
        if let model, !model.isEmpty { a.model = model }
        a.durationMs = Self.elapsedMs(since: a.startedAt)
        agents[key] = a
        return payload(key)
    }

    /// 終了。state は done / failed / stopped（completed・killed・interrupted 等の CLI の語も受ける）。
    /// result は結果の本文（冒頭を resultPreview に、2000 字までを result に出す）。同じ実行の中で failed / stopped を
    /// done に戻さない（done → failed / stopped は受ける。例: reconcile で閉じた後に届いた失敗の知らせ）。再開は begin だけ。
    /// durationMs は CLI が知らせた所要時間（Codex の item の durationMs など）。あれば計算した所要時間の代わりに使う。
    /// 変化が無ければ nil。
    mutating func finish(key: String, state: String, result: String?, durationMs: Int? = nil) -> String? {
        settle(key, state: state, result: result, durationMs: durationMs) ? payload(key) : nil
    }

    /// 終了（古い呼び方）。failed でなければ done。
    mutating func finish(key: String, failed: Bool, result: String?) -> String? {
        finish(key: key, state: failed ? "failed" : "done", result: result)
    }

    /// Claude 互換 stream-json で task_* 行を出さない CLI（Cursor 等）向け。親の assistant 行の
    /// Task / Agent の tool_use を開始、その tool_result を終了とみなす（キーは tool_use id）。
    /// 子の行（parent_tool_use_id 付き）は ingestStreamLine が拾う。
    mutating func ingestToolUseLine(_ obj: [String: Any]) -> [String] {
        guard obj["parent_tool_use_id"] as? String == nil,
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        var out: [String] = []
        switch obj["type"] as? String {
        case "assistant":
            for block in content where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String,
                      let d = Self.delegation(toolName: block["name"] as? String ?? "", title: nil, input: block["input"])
                else { continue }
                if let p = begin(key: id, label: d.label, agentType: d.agentType, toolUseId: id,
                                 labelIsFallback: d.labelIsFallback, taskCount: d.taskCount) { out.append(p) }
            }
        case "user":
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, contains(id) else { continue }
                let text: String? = (block["content"] as? String)
                    ?? (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if let p = finish(key: id, failed: block["is_error"] as? Bool == true, result: text) { out.append(p) }
            }
        default:
            break
        }
        return out
    }

    /// ACP の session/update（tool_call / tool_call_update）。委任ツールならサブエージェントとして扱う。
    /// opencode acp は pending の tool_call では title と rawInput が空で、in_progress の更新で届くので、そこで埋め直す。
    /// background == true は、受領票が非同期の開始を示した tool_call（委任の行を running のまま残し、background にする）。
    /// status の無い tool_call_update では行を閉じない（title・rawInput の埋め直しだけ）。
    mutating func ingestAcpUpdate(_ update: [String: Any], background: Bool? = nil) -> String? {
        guard let id = update["toolCallId"] as? String, !id.isEmpty else { return nil }
        let status = update["status"] as? String
        let title = update["title"] as? String
        var p: String?
        switch update["sessionUpdate"] as? String {
        case "tool_call":
            guard let d = Self.delegation(toolName: title ?? "", title: title, input: update["rawInput"]) else { return nil }
            p = begin(key: id, label: d.label, agentType: d.agentType, background: background,
                      labelIsFallback: d.labelIsFallback, taskCount: d.taskCount)
        case "tool_call_update":
            guard let a = agents[id] else { return nil }
            if a.state == "running", title?.isEmpty == false || update["rawInput"] is [String: Any] {
                let d = Self.delegationLabel(title: title, input: update["rawInput"])
                if !d.label.isEmpty || d.agentType != nil {
                    p = begin(key: id, label: d.label, agentType: d.agentType, background: background,
                              labelIsFallback: d.labelIsFallback, taskCount: d.taskCount)
                }
            }
            if background == true, agents[id]?.background != true, let q = setBackground(id) { p = q }
        default:
            return nil
        }
        guard status == "completed" || status == "failed" else { return p }
        // 非同期で始めた委任の受領票（background == true の completed）は、行を running のまま残す。
        if background == true, status == "completed" { return p }
        let text = Self.acpText(update["content"])
        // opencode の task の出力（<task … state=…>）は中身を取り出す。running は裏で動き出した（実験フラグの
        // バックグラウンドの task）だが、ACP には子の完了も、親に差し込まれる知らせも流れてこない（§4。ほかの ACP の
        // 非同期の委任と同じ）。実行中のまま残すと、カード・SessionHub の「閉じない」・スリープ抑止・push の保留が
        // 中断か close まで続くので、起動の知らせ（summary）を結果にして done で閉じる。
        let task = text.map(Self.parseTaskOutput)
        if task?.state == "running" {
            return finish(key: id, state: "done", result: task?.summary ?? task?.result) ?? p
        }
        let failed = status == "failed" || task?.state.flatMap(Self.finalState) == "failed"
        let result = task.flatMap { $0.result ?? $0.summary } ?? text
        return finish(key: id, state: failed ? "failed" : "done", result: result) ?? p
    }

    /// 非同期の委任の受領票が知らせた task の数（Hermes の count）。複数なら名前は「{n} 件のタスク」（既定文）にする。
    mutating func setTaskCount(key: String, count: Int) -> String? {
        guard var a = agents[key], a.state == "running", count > 0 else { return nil }
        a.taskCount = count
        if count > 1 {
            a.label = "\(count) 件のタスク"
            a.labelIsFallback = true
        }
        guard a != agents[key] else { return nil }
        agents[key] = a
        return payload(key)
    }

    private mutating func setBackground(_ key: String) -> String? {
        guard agents[key]?.state == "running" else { return nil }
        agents[key]?.background = true
        return payload(key)
    }

    static func acpText(_ raw: Any?) -> String? {
        let items = raw as? [[String: Any]] ?? []
        let text = items.compactMap { ($0["content"] as? [String: Any])?["text"] as? String ?? $0["text"] as? String }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // MARK: - 共通

    /// 既にある行に、分かったことを足す。既定文の label は説明で上書きし、説明を既定文では上書きしない。
    private static func fill(_ a: inout Agent, label: String?, labelIsFallback: Bool? = nil, taskCount: Int? = nil,
                             agentType: String? = nil, model: String? = nil, background: Bool? = nil,
                             tool: String? = nil, command: String? = nil) {
        if let text = label.map({ preview($0, limit: 80) }), !text.isEmpty {
            let fallback = labelIsFallback ?? false
            if !fallback || a.labelIsFallback {
                a.label = text
                a.labelIsFallback = fallback
            }
        }
        if let taskCount { a.taskCount = taskCount }
        if let agentType, !agentType.isEmpty {
            a.agentType = agentType
            // 説明の無い行の既定文は種類名（古いアプリ向け）。
            if a.labelIsFallback, a.taskCount == nil { a.label = agentType }
        }
        if let model, !model.isEmpty { a.model = model }
        if let background { a.background = background }
        if let tool, !tool.isEmpty { a.tool = tool }
        if let command, !command.isEmpty { a.command = preview(command, limit: 200) }
    }

    /// 終わった行（か、run_id の変わった行）を実行中に戻す。開始時刻をやり直し（CLI の開始時刻が無ければ今）、
    /// 所要時間・作業の文・結果を消す。
    private mutating func restart(_ key: String, startedAt: Date? = nil) {
        guard var a = agents[key] else { return }
        a.state = "running"
        a.startedAt = startedAt ?? Date()
        a.endedAt = nil
        a.durationMs = nil
        a.exactDuration = false
        a.preview = nil
        a.result = nil
        a.stopRequested = false
        agents[key] = a
    }

    /// 行を終わりの状態にする。running → done / failed / stopped、done → failed / stopped と、同じ状態での結果の更新だけを
    /// 受ける。endedAt は CLI の end_time（無ければ今）。所要時間は usage の duration_ms があればそれを残す。
    /// durationMs（CLI が知らせた所要時間）があれば、計算した値の代わりに入れる。変化があれば true。
    @discardableResult
    private mutating func settle(_ key: String, state: String, result: String?, endedAt: Date? = nil,
                                 durationMs: Int? = nil) -> Bool {
        guard var a = agents[key], let target = Self.finalState(state) else { return false }
        let text = result.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch a.state {
        case "running":
            a.state = target
            // 作業の文は結果ではない（失敗の理由に見えないように消す）。
            a.preview = nil
            a.endedAt = endedAt ?? Date()
            if let durationMs, durationMs >= 0 {
                a.durationMs = durationMs
                a.exactDuration = true
            } else if !a.exactDuration {
                a.durationMs = Self.ms(from: a.startedAt, to: a.endedAt ?? Date())
            }
        case target:
            guard text != nil else { return false }
        case "done":
            a.state = target
        default:
            return false
        }
        if let text {
            a.preview = Self.preview(text)
            a.result = Self.clip(text)
        }
        guard a != agents[key] else { return false }
        agents[key] = a
        return true
    }

    /// 全行（subtype = workflow_snapshot。アプリは行を丸ごと置き換える）。後から開いたクライアントに今の状態を渡す。
    /// 行が無ければ nil。includeEmpty なら行が無くても agents: [] で返す（アプリが持っている幽霊行を消せるように）。
    func snapshot(includeEmpty: Bool = false) -> String? {
        guard includeEmpty || !agents.isEmpty else { return nil }
        return payload(rows: agents.values.sorted { $0.index < $1.index }, subtype: "workflow_snapshot")
    }

    /// 変化した 1 行と、カード全体の status。クライアントは index で行を重ねる。
    private func payload(_ key: String) -> String? {
        guard let a = agents[key] else { return nil }
        return payload(rows: [a])
    }

    /// 行は毎回、持っている項目を全部入れる（アプリは届いた項目だけを上書きする）。
    /// resultPreview（と終わった行の result）は無くても空文字で送る。アプリは届いた項目だけを重ねるので、送らないと
    /// 前の値（実行中の作業の文・前の実行の結果）が残り、失敗の理由や「→ 結果」に見える。アプリは空を無いものとして出す。
    private func payload(rows: [Agent], subtype: String = "task_progress") -> String? {
        let rowsJSON: [[String: Any]] = rows.map { a in
            var row: [String: Any] = ["index": a.index, "id": a.id, "label": a.label,
                                      "labelIsFallback": a.labelIsFallback, "state": a.state, "rowKind": a.rowKind,
                                      "startedAtMs": Self.epochMs(a.startedAt), "resultPreview": a.preview ?? ""]
            if let v = a.taskCount { row["taskCount"] = v }
            if let v = a.agentType { row["agentType"] = v }
            if let v = a.tool { row["tool"] = v }
            if let v = a.command { row["command"] = v }
            if let v = a.parentId { row["parentId"] = v }
            if let v = a.background { row["background"] = v }
            if let v = a.model { row["model"] = v }
            if let v = a.tokens { row["tokens"] = v }
            if let v = a.toolCalls { row["toolCalls"] = v }
            if let v = a.durationMs { row["durationMs"] = v }
            row["stoppable"] = a.state == "running" && a.stopHandle && !a.stopRequested
            if a.state != "running" {
                if let v = a.endedAt { row["endedAtMs"] = Self.epochMs(v) }
                row["result"] = a.result ?? ""
            }
            return row
        }
        // 古いアプリ向けの要約。1 行でも running なら running、全部 failed なら failed（stopped は失敗に数えない）。
        let all = agents.values
        let status = all.contains { $0.state == "running" } ? "running"
            : !all.isEmpty && all.allSatisfy { $0.state == "failed" } ? "failed" : "completed"
        let out: [String: Any] = [
            "subtype": subtype,
            "taskId": Self.taskId,
            "kind": "subagents",
            "workflowName": "サブエージェント",
            "status": status,
            "epoch": epoch,
            "agents": rowsJSON,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: out) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isAgentTool(_ name: String) -> Bool { name == "Agent" || name == "Task" }

    /// hooks の内部の補助か（agent_id があり、agent_type が無いか空）。Stop のたびに来る次の発話の候補づくり
    /// （SubagentStop の agent_type: ""）と、バックグラウンドのエージェントの要約（PreToolUse に agent_type キーが無い）。
    /// 行にも親のツール行にもペインの状態にも使わない。
    static func isInternalHelper(agentId: String?, agentType: Any?) -> Bool {
        guard let agentId, !agentId.isEmpty else { return false }
        guard let type = agentType as? String else { return true }
        return type.isEmpty
    }

    /// stream-json の task_type のうち、バックグラウンドのシェル等として行に出すもの（Monitor も local_bash で来る）。
    private static func isShellTask(_ type: String?) -> Bool {
        guard let type else { return false }
        return ["local_bash", "monitor_mcp", "monitor_ws", "mcp_task", "bash", "shell"].contains(type)
    }

    private static func listedId(_ t: [String: Any]) -> String? {
        nonEmpty(t["id"]) ?? nonEmpty(t["task_id"])
    }

    /// 一覧の 1 件を行の形にする。種類は完全一致で振り分ける（hooks の表示名と、stream-json・古い版の内部名の両方）。
    /// 内部の作業（dream・auto-mode scan・memory import）と知らない種類は行にしない。
    private static func listed(_ t: [String: Any]) -> Listed? {
        guard let id = listedId(t) else { return nil }
        let type = nonEmpty(t["type"]) ?? nonEmpty(t["task_type"]) ?? ""
        var agentType = nonEmpty(t["agent_type"]) ?? nonEmpty(t["subagent_type"])
        var tool = nonEmpty(t["tool"])
        let rowKind: String
        switch type {
        case "subagent", "local_agent":
            rowKind = "agent"
        case "shell", "local_bash", "MCP task", "mcp_task":
            rowKind = "shell"
        case "monitor", "monitor_mcp", "monitor_ws":
            rowKind = "shell"
            tool = "Monitor"
        case "workflow", "local_workflow":
            // ターミナル経路には workflow のカードが無いので、サブエージェントの行として出す。
            rowKind = "agent"
            agentType = "workflow"
        case "teammate", "in_process_teammate", "cloud session", "remote_agent":
            rowKind = "agent"
            agentType = type
        default:
            return nil
        }
        return Listed(id: id, rowKind: rowKind, agentType: agentType,
                      label: nonEmpty(t["description"]) ?? nonEmpty(t["name"]) ?? nonEmpty(t["command"]),
                      tool: rowKind == "shell" ? tool : nil, command: nonEmpty(t["command"]),
                      parentId: nonEmpty(t["parent_task_id"]), runId: nonEmpty(t["run_id"]),
                      taskType: nonEmpty(t["task_type"]))
    }

    /// <task-notification> の 1 件。サブエージェントは <result>（最後の返事）と <usage> を持つ。
    /// <summary> はサブエージェントなら「Agent "…" finished」、シェルなら「Background command "…" completed (exit code 0)」。
    struct TaskNotification: Equatable {
        let taskId: String
        let status: String
        let summary: String?
        let result: String?
        let tokens: Int?
        let toolUses: Int?
        let durationMs: Int?
    }

    /// <task-notification> を抜き出す（複数あれば全部）。<usage> の subagent_tokens（か total_tokens）・tool_uses・duration_ms も読む。
    static func taskNotifications(in text: String) -> [TaskNotification] {
        var out: [TaskNotification] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<task-notification>"),
              let close = rest.range(of: "</task-notification>", range: open.upperBound..<rest.endIndex) {
            let body = rest[open.upperBound..<close.lowerBound]
            // <result> は最後の閉じタグまで（返事の本文にタグの文字が入っていても切らない）。<usage> はその後ろから読む。
            let result = tagValue("result", in: body, lastClose: true)
            let tail = body.range(of: "</result>", options: .backwards).map { body[$0.upperBound...] } ?? body
            let usage = tagValue("usage", in: tail).map { Substring($0) } ?? ""
            if let id = tagValue("task-id", in: body) {
                out.append(TaskNotification(
                    taskId: id, status: tagValue("status", in: body) ?? "completed",
                    summary: tagValue("summary", in: body), result: result,
                    tokens: (tagValue("subagent_tokens", in: usage) ?? tagValue("total_tokens", in: usage)).flatMap { Int($0) },
                    toolUses: tagValue("tool_uses", in: usage).flatMap { Int($0) },
                    durationMs: tagValue("duration_ms", in: usage).flatMap { Int($0) }))
            }
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// 発話から <task-notification> の塊を取り除いた残り（前後の空白も詰める）。
    static func stripNotifications(_ text: String) -> String {
        text.replacingOccurrences(of: #"<task-notification>[\s\S]*?</task-notification>"#, with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OpenCode の task の出力から中身を取り出す。1.18 の形は
    /// `<task id="ses_…" state="completed|running|error">`（`<summary>…</summary>`）`<task_result>…</task_result>`
    /// （失敗は `<task_error>…</task_error>`）`</task>`。古い形（本文の後ろに `<task_metadata>`）も受ける。
    /// state は属性の値そのまま（無くて <task_error> なら "error"、古い形は nil）。どちらの形でもなければ全部 nil。
    static func parseTaskOutput(_ text: String) -> (state: String?, summary: String?, result: String?) {
        let all = Substring(text)
        let error = tagValue("task_error", in: all, lastClose: true)
        let body = tagValue("task_result", in: all, lastClose: true) ?? error
        let summary = tagValue("summary", in: all)
        var state: String?
        if let open = all.range(of: "<task "), let end = all[open.upperBound...].range(of: ">") {
            let attrs = all[open.upperBound..<end.lowerBound]
            if let s = attrs.range(of: "state=\""), let e = attrs[s.upperBound...].range(of: "\"") {
                state = String(attrs[s.upperBound..<e.lowerBound])
            }
        }
        if body != nil || summary != nil || state != nil {
            return (state ?? (error != nil ? "error" : nil), summary, body)
        }
        if let r = text.range(of: "<task_metadata>") {
            let v = text[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, nil, v.isEmpty ? nil : v)
        }
        return (nil, nil, nil)
    }

    /// <name>…</name> の中身（前後の空白を詰め、空なら nil）。lastClose なら最後の閉じタグまで。
    private static func tagValue(_ name: String, in s: Substring, lastClose: Bool = false) -> String? {
        guard let a = s.range(of: "<\(name)>"),
              let b = lastClose ? s.range(of: "</\(name)>", options: .backwards)
                                : s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex),
              a.upperBound <= b.lowerBound else { return nil }
        let v = s[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// 各 CLI がサブエージェントへ仕事を任せるツール。
    /// Claude / Cursor: Task・Agent、Codex(ACP): spawn_agent、Hermes: delegate_task、OpenClaw: sessions_spawn。
    private static let delegationTools: Set<String> = [
        "task", "agent", "spawn_agent", "spawnagent", "delegate_task", "sessions_spawn", "subagent", "spawn_subagent",
    ]

    /// ツール呼び出しがサブエージェントの起動なら、行に出す説明と種類を返す。名前は先頭の識別子にそろえて照合する
    /// （ACP の title は「delegate_task: …」の形）。名前で見分けられない ACP（タイトルに説明が入る claude-code-acp 等）は
    /// 入力の subagent_type で見分ける。説明が無ければ label は空か「{n} 件のタスク」で、labelIsFallback が true。
    static func delegation(toolName: String, title: String?, input: Any?)
        -> (label: String, agentType: String?, labelIsFallback: Bool, taskCount: Int?)? {
        let dict = input as? [String: Any]
        guard delegationTools.contains(normalizedToolName(toolName).lowercased()) || dict?["subagent_type"] != nil
        else { return nil }
        if isDelegateControl(toolName: toolName, title: title, input: dict) { return nil }
        return delegationLabel(title: title, input: input)
    }

    /// Hermes の delegate_task の control call（list / steer / stop）か。委任ではないので行を作らない。
    /// rawInput.action が list / steer / stop か、title の「delegate_task:」の後がその語で始まる（後が空白・「:」・終わり）。
    /// 本物の委任の title は「delegate_task: 1 tasks: …」の形。
    private static func isDelegateControl(toolName: String, title: String?, input: [String: Any]?) -> Bool {
        let controls: Set<String> = ["list", "steer", "stop"]
        guard normalizedToolName(toolName).lowercased() == "delegate_task" else { return false }
        if let action = nonEmpty(input?["action"]), controls.contains(action.lowercased()) { return true }
        let raw = (title ?? toolName).trimmingCharacters(in: .whitespacesAndNewlines)
        let head = raw.prefix { isIdentifierChar($0) }
        guard head.lowercased() == "delegate_task" else { return false }
        let rest = raw.dropFirst(head.count)
        guard rest.first == ":" else { return false }
        let after = rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return controls.contains { word in
            guard after.hasPrefix(word) else { return false }
            let next = after.dropFirst(word.count).first
            return next == nil || next == ":" || next!.isWhitespace
        }
    }

    /// 委任の説明と種類。title の「<tool>: 」は外す。説明が無くタスクの配列なら「{n} 件のタスク」（既定文）。
    private static func delegationLabel(title: String?, input: Any?)
        -> (label: String, agentType: String?, labelIsFallback: Bool, taskCount: Int?) {
        let dict = input as? [String: Any]
        let agentType = nonEmpty(dict?["subagent_type"]) ?? nonEmpty(dict?["agent_type"]) ?? nonEmpty(dict?["agentId"])
        let taskCount = (dict?["tasks"] as? [Any])?.count
        var label = title.map(strippedToolPrefix) ?? ""
        for k in ["description", "goal", "label", "task", "prompt", "message"] {
            if let v = nonEmpty(dict?[k]) { label = v; break }
        }
        if label.isEmpty, let taskCount { return ("\(taskCount) 件のタスク", agentType, true, taskCount) }
        return (label, agentType, label.isEmpty, taskCount)
    }

    /// ACP の title からツール名を作る。先頭の識別子（[A-Za-z0-9_.-]+）だけを取る（「delegate_task: 3 tasks」→「delegate_task」）。
    /// 識別子で始まらなければ、最初の語をそのまま返す。
    static func normalizedToolName(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = s.prefix { isIdentifierChar($0) }
        if !head.isEmpty { return String(head) }
        return s.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? s
    }

    /// 委任ツールの title「<tool>: <中身>」から「<tool>: 」を外す。ツール名だけの title は空にする（説明ではない）。
    private static func strippedToolPrefix(_ title: String) -> String {
        let s = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = s.prefix { isIdentifierChar($0) }
        guard !head.isEmpty, delegationTools.contains(head.lowercased()) else { return s }
        let rest = s.dropFirst(head.count)
        if rest.isEmpty { return "" }
        guard rest.first == ":" else { return s }
        return rest.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isIdentifierChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "." || c == "-")
    }

    /// CLI の終わり方の語を行の state にする。終わりでなければ nil。
    /// completed / done / success → done、failed / error → failed、
    /// killed / stopped / cancelled / canceled / interrupted / aborted → stopped（止めたものは失敗ではない）。
    static func finalState(_ status: String) -> String? {
        switch status {
        case "completed", "done", "success": return "done"
        case "failed", "error": return "failed"
        case "killed", "stopped", "cancelled", "canceled", "interrupted", "aborted": return "stopped"
        default: return nil
        }
    }

    /// usage（total_tokens・tool_uses・duration_ms）。final = 終わりの知らせの usage（所要時間はこれが正）。
    /// 実行中の duration_ms は、閉じるときに end_time か今の時刻で上書きする。
    private static func applyUsage(_ usage: Any?, to a: inout Agent, final: Bool) {
        guard let u = usage as? [String: Any] else { return }
        if let v = int(u["total_tokens"]) ?? int(u["subagent_tokens"]) { a.tokens = v }
        if let v = int(u["tool_uses"]) { a.toolCalls = v }
        if let v = int(u["duration_ms"]) {
            a.durationMs = v
            if final { a.exactDuration = true }
        }
    }

    /// 同じ実行の行か（run_id の違う行は、再開する前の実行の遅れて届いたもの）。
    private static func sameRun(_ a: Agent, _ obj: [String: Any]) -> Bool {
        guard let run = obj["run_id"] as? String, let current = a.runId else { return true }
        return run == current
    }

    /// 結果として意味のある要約か（説明をそのまま返しただけのもの＝止めた知らせ等は結果にしない）。
    private static func informative(_ summary: String?, label: String) -> String? {
        guard let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
              preview(s, limit: 80) != label else { return nil }
        return s
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    /// 丸める（CLI の end_time を Date にして戻したときに 1 ずれないように）。
    private static func epochMs(_ d: Date) -> Int { Int((d.timeIntervalSince1970 * 1000).rounded()) }

    private static func ms(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private static func elapsedMs(since start: Date) -> Int { ms(from: start, to: Date()) }

    /// 「Glob: *.json」「Bash: ls /tmp」のような、いまやっていることの 1 行。
    static func toolActivity(name: String, input: Any?) -> String {
        guard let dict = input as? [String: Any] else { return name }
        for k in ["description", "command", "file_path", "path", "pattern", "url", "query", "prompt"] {
            if let v = dict[k] as? String, !v.isEmpty { return "\(name): \(preview(v, limit: 100))" }
        }
        return name
    }

    private static func preview(_ s: String, limit: Int = 160) -> String {
        let oneLine = s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }

    /// 結果の本文（詳細を開いたときに出す）。前後の空白を詰め、2000 字まで。
    private static func clip(_ s: String, limit: Int = 2000) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > limit ? String(t.prefix(limit)) + "…" : t
    }
}
