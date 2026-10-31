import assert from "node:assert/strict";
import { test } from "node:test";
import {
  delegation,
  finalState,
  isInternalHelper,
  normalizedToolName,
  parseTaskOutput,
  stripNotifications,
  SubagentTracker,
  taskNotifications
} from "./subagentTracker.js";

type Row = Record<string, unknown>;

const row = (p: string | undefined): Row => {
  assert.ok(p);
  const o = JSON.parse(p) as { taskId: string; agents: Row[] };
  assert.equal(o.taskId, "subagents");
  return o.agents[0];
};

const rows = (p: string | undefined): Row[] => (p ? (JSON.parse(p) as { agents: Row[] }).agents : []);

const card = (p: string | undefined): Row => {
  assert.ok(p);
  return JSON.parse(p) as Row;
};

const status = (p: string | undefined): unknown => card(p).status;

const obj = (json: string): Record<string, unknown> => JSON.parse(json) as Record<string, unknown>;

// 行は claude 2.1.280 の実出力（Explore サブエージェントを 1 つ起動）から抜いたもの。
test("Claude stream-json: task_* と子の assistant 行", () => {
  const t = new SubagentTracker();
  const started = row(
    t.ingestStreamLine({
      type: "system",
      subtype: "task_started",
      task_id: "a1",
      tool_use_id: "toolu_P",
      description: "JSONファイル探索",
      subagent_type: "Explore",
      task_type: "local_agent"
    })
  );
  assert.equal(started.label, "JSONファイル探索");
  assert.equal(started.state, "running");
  const tool = row(
    t.ingestStreamLine({
      type: "assistant",
      parent_tool_use_id: "toolu_P",
      message: { model: "claude-haiku-4-5", content: [{ type: "tool_use", name: "Glob", input: { pattern: "*.json" } }] }
    })
  );
  assert.equal(tool.resultPreview, "Glob: *.json");
  assert.equal(tool.model, "claude-haiku-4-5");
  const done = row(
    t.ingestStreamLine({ type: "system", subtype: "task_notification", task_id: "a1", status: "completed", summary: "settings.json", usage: { tool_uses: 1 } })
  );
  assert.equal(done.state, "done");
  assert.equal(done.toolCalls, 1);
  // workflow は出さない（別カード）
  assert.equal(t.ingestStreamLine({ type: "system", subtype: "task_started", task_id: "w", task_type: "local_workflow" }), undefined);
});

test("stream-json: バックグラウンドのシェルも行に出す（rowKind = shell）。サブエージェントとは数え分ける", () => {
  const t = new SubagentTracker();
  const started = row(t.ingestStreamLine({ type: "system", subtype: "task_started", task_id: "b", task_type: "local_bash", description: "npm run dev" }));
  assert.equal(started.label, "npm run dev");
  assert.equal(started.rowKind, "shell");
  assert.equal(typeof started.startedAtMs, "number");
  assert.ok(t.hasRunning);
  assert.ok(!t.hasRunningAgents);
  const done = row(t.ingestStreamLine({ type: "system", subtype: "task_notification", task_id: "b", status: "killed", summary: "stopped" }));
  // 止めたもの（killed）は失敗ではなく stopped。
  assert.equal(done.state, "stopped");
});

test("Claude 互換の Task tool_use / tool_result（Cursor 等）", () => {
  const t = new SubagentTracker();
  const [start] = t.ingestToolUseLine({
    type: "assistant",
    message: { content: [{ type: "tool_use", id: "tu1", name: "Task", input: { description: "調査", subagent_type: "general-purpose" } }] }
  });
  assert.equal(row(start).agentType, "general-purpose");
  const [end] = t.ingestToolUseLine({
    type: "user",
    message: { content: [{ type: "tool_result", tool_use_id: "tu1", content: [{ type: "text", text: "結果です" }] }] }
  });
  assert.equal(row(end).state, "done");
  assert.equal(row(end).resultPreview, "結果です");
});

test("ACP の委任ツール（Hermes の delegate_task）", () => {
  const t = new SubagentTracker();
  const start = row(
    t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "c1", title: "delegate_task", rawInput: { goal: "READMEを要約" }, status: "in_progress" })
  );
  assert.equal(start.label, "READMEを要約");
  const end = row(
    t.ingestAcpUpdate({ sessionUpdate: "tool_call_update", toolCallId: "c1", status: "failed", content: [{ type: "content", content: { type: "text", text: "timeout" } }] })
  );
  assert.equal(end.state, "failed");
  // 普通のツールはサブエージェントにしない
  assert.equal(t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "c2", title: "read_file", rawInput: { path: "/x" } }), undefined);
});

test("delegation: 名前と subagent_type で見分ける", () => {
  assert.equal(delegation("sessions_spawn", undefined, { task: "ビルド" })?.label, "ビルド");
  assert.equal(delegation("Read", undefined, { file_path: "/x" }), undefined);
  assert.equal(delegation("説明だけのタイトル", "説明だけのタイトル", { subagent_type: "Explore" })?.agentType, "Explore");
});

test("pruneFinished は実行中を残す / begin は終わったものを実行中に戻す", () => {
  const t = new SubagentTracker();
  t.begin("x", "A");
  t.begin("y", "B");
  t.finish("y", false, "ok");
  t.pruneFinished();
  assert.ok(t.has("x"));
  assert.ok(!t.has("y"));
  t.finish("x", false, undefined);
  assert.equal(row(t.begin("x")).state, "running");
});

test("hooks: 起動の PreToolUse を伴わない SubagentStart（次の発話の候補づくり等の補助）は行にしない", () => {
  const t = new SubagentTracker();
  assert.equal(t.hookStart("s1", ""), undefined);
  assert.ok(t.isIgnored("s1"));
  assert.equal(t.hookStop("s1", "", "そのまま続けて"), undefined);
  assert.ok(t.isEmpty);
  // SendMessage で話しかけ直したサブエージェントは出す。
  t.noteLaunch("SendMessage", { to: "a1", message: "続きを調べて", summary: "続きの調査" });
  assert.equal(row(t.hookStart("a1", "general-purpose")).label, "続きの調査");
  // 説明が空なら種類名を出す。
  t.noteLaunch("Agent", { subagent_type: "Explore" });
  assert.equal(row(t.hookStart("a2", "Explore")).label, "Explore");
});

test("hooks: run_in_background の Bash は PostToolUse の backgroundTaskId で行になり、完了の知らせで閉じる", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Bash", { command: "for i in $(seq 1 60); do dig …; done", description: "DNS の反映を待つ", run_in_background: true }, "toolu_B");
  const started = row(t.hookToolResult("toolu_B", "Bash", undefined, { stdout: "", backgroundTaskId: "b0fz5vnji" }));
  assert.equal(started.label, "DNS の反映を待つ");
  assert.equal(started.rowKind, "shell");
  // 前景の Bash（backgroundTaskId が無い）は行にしない。
  assert.equal(t.hookToolResult("toolu_C", "Bash", undefined, { stdout: "ok" }), undefined);
  // Esc の中断ではシェルは閉じない。
  assert.equal(t.abandonRunning(false), undefined);
  const text = [
    "<task-notification>",
    "<task-id>b0fz5vnji</task-id>",
    "<tool-use-id>toolu_B</tool-use-id>",
    "<status>completed</status>",
    '<summary>Background command "DNS の反映を待つ" completed (exit code 0)</summary>',
    "</task-notification>"
  ].join("\n");
  const done = t.ingestNotifications(text);
  assert.equal(done.length, 1);
  assert.equal(row(done[0]).state, "done");
  assert.equal(stripNotifications(`${text}\n続けて`), "続けて");
  assert.deepEqual(taskNotifications(text), [{ taskId: "b0fz5vnji", status: "completed", summary: 'Background command "DNS の反映を待つ" completed (exit code 0)' }]);
});

test("hooks: Stop の background_tasks と突き合わせる。知らないものは行を作り、一覧から消えたシェルは閉じる", () => {
  const t = new SubagentTracker();
  const added = t.reconcile([
    { id: "b1", type: "local_bash", status: "running", description: "npm run dev", command: "npm run dev" },
    { id: "a1", type: "local_agent", status: "running", description: "調査", agent_type: "Explore" }
  ]);
  assert.ok(added);
  assert.deepEqual((JSON.parse(added) as { agents: Array<{ rowKind: string }> }).agents.map((a) => a.rowKind), ["shell", "agent"]);
  const closed = row(t.reconcile([{ id: "a1", type: "local_agent", status: "running", description: "調査" }]));
  assert.equal(closed.state, "done");
  assert.equal(closed.label, "npm run dev");
  assert.ok(t.hasRunningAgents);
  assert.equal(t.reconcile(undefined), undefined);
});

test("中断では実行中の行だけを閉じる（既定は stopped）。終わった行と index はそのまま", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Agent", { subagent_type: "Explore" });
  t.noteLaunch("Agent", { subagent_type: "Plan" });
  t.hookStart("a", "Explore");
  t.hookStart("b", "Plan");
  t.hookStop("a", "Explore", "done");
  assert.equal(row(t.abandonRunning()).index, 1);
  assert.equal(t.abandonRunning(), undefined);
});

test("古い呼び方: 位置引数の begin、真偽値の finish・abandonRunning も受ける", () => {
  const t = new SubagentTracker();
  const started = row(t.begin("c1", undefined, "explorer", "gpt-5", "tu1", "agent"));
  assert.equal(started.label, "explorer");
  assert.equal(started.labelIsFallback, true);
  assert.equal(started.agentType, "explorer");
  assert.equal(started.model, "gpt-5");
  // toolUseId で子の行を引き当てる。
  const child = t.ingestStreamLine({ type: "assistant", parent_tool_use_id: "tu1", message: { content: [{ type: "tool_use", name: "Read", input: { file_path: "/a" } }] } });
  assert.equal(row(child).resultPreview, "Read: /a");
  assert.equal(row(t.finish("c1", true, "boom")).state, "failed");
  assert.equal(row(t.begin("s1", "dev", undefined, undefined, undefined, "shell")).rowKind, "shell");
  assert.equal(t.abandonRunning(false), undefined);
  assert.equal(row(t.abandonRunning(true)).state, "stopped");
});

// ---- ここから mac-bridge の SubagentTrackerTests.swift と同じ入力・同じ期待（2 つのトラッカーが同じ JSON を出す） ----
// 行は claude の実出力から必要な分だけ抜いたもの。2.1.280（Explore サブエージェントを 1 つ起動）と、
// 2.1.300 の実測（docs/BACKGROUND_WORK_2026-10-21.md §1。probe-stream の S1〜S14、probe-hooks の A〜G）。

test("stream-json: サブエージェントの始まりから終わりまで（id・終わった時刻・結果の本文）", () => {
  const t = new SubagentTracker();
  const started = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"a1","tool_use_id":"toolu_P","description":"JSONファイル探索","subagent_type":"Explore","is_backgrounded":true,"task_type":"local_agent"}`
    )
  );
  assert.equal(row(started).label, "JSONファイル探索");
  assert.equal(row(started).agentType, "Explore");
  assert.equal(row(started).state, "running");
  assert.equal(row(started).id, "a1");
  assert.equal(status(started), "running");

  const tool = t.ingestStreamLine(
    obj(
      `{"type":"assistant","parent_tool_use_id":"toolu_P","message":{"model":"claude-haiku-4-5-20251001","content":[{"type":"tool_use","id":"toolu_G","name":"Glob","input":{"pattern":"*.json"}}]}}`
    )
  );
  assert.equal(row(tool).model, "claude-haiku-4-5-20251001");
  assert.equal(row(tool).resultPreview, "Glob: *.json");

  const progress = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_progress","task_id":"a1","tool_use_id":"toolu_P","description":"Finding *.json","usage":{"total_tokens":12449,"tool_uses":1,"duration_ms":3434},"last_tool_name":"Glob"}`
    )
  );
  assert.equal(row(progress).toolCalls, 1);
  assert.equal(row(progress).tokens, 12449);
  assert.equal(row(progress).resultPreview, "Finding *.json");

  const done = t.ingestStreamLine(
    obj(
      String.raw`{"type":"system","subtype":"task_notification","task_id":"a1","tool_use_id":"toolu_P","status":"completed","summary":"見つかったJSONファイル：\n\n- **settings.json**","usage":{"total_tokens":13525,"tool_uses":1,"duration_ms":5000}}`
    )
  );
  assert.equal(row(done).state, "done");
  assert.equal(row(done).resultPreview, "見つかったJSONファイル： - **settings.json**");
  assert.equal(row(done).result, "見つかったJSONファイル：\n\n- **settings.json**");
  assert.equal(row(done).durationMs, 5000);
  assert.equal(typeof row(done).endedAtMs, "number");
  assert.equal(status(done), "completed");

  t.pruneFinished();
  assert.ok(t.isEmpty);
});

test("stream-json: dynamic workflow は行にしない（task_id を覚え、後の task_notification も id で見分ける）", () => {
  const t = new SubagentTracker();
  assert.equal(t.ingestStreamLine(obj(`{"type":"system","subtype":"task_started","task_id":"w","task_type":"local_workflow","workflow_name":"review"}`)), undefined);
  assert.ok(t.isWorkflowTask("w"));
  // task_notification は task_type も workflow_name も持たない。覚えた id で見分け、行にしない。
  assert.equal(
    t.ingestStreamLine(obj(`{"type":"system","subtype":"task_notification","task_id":"w","status":"completed","summary":"Workflow review finished"}`)),
    undefined
  );
  // background_tasks_changed に載った workflow も行にしない。
  assert.equal(
    t.ingestStreamLine(
      obj(`{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"w2","run_id":"r","task_type":"local_workflow","description":"review"}]}`)
    ),
    undefined
  );
  assert.ok(t.isWorkflowTask("w2"));
  assert.ok(!t.isWorkflowTask("a1"));
  // 親の行（parent_tool_use_id が null）はサブエージェントではない。
  assert.equal(
    t.ingestStreamLine(obj(`{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}`)),
    undefined
  );
  assert.ok(t.isEmpty);
});

test("stream-json: バックグラウンドのシェルは shell の行。止めたもの（killed）は stopped で、要約の status は completed", () => {
  const t = new SubagentTracker();
  const started = t.ingestStreamLine(obj(`{"type":"system","subtype":"task_started","task_id":"b","task_type":"local_bash","description":"npm run dev"}`));
  assert.equal(row(started).label, "npm run dev");
  assert.equal(row(started).rowKind, "shell");
  assert.equal(typeof row(started).startedAtMs, "number");
  assert.ok(t.hasRunning);
  assert.ok(!t.hasRunningAgents);
  assert.equal(t.runningShellCount, 1);
  const done = t.ingestStreamLine(obj(`{"type":"system","subtype":"task_notification","task_id":"b","status":"killed","summary":"stopped"}`));
  // 止めたものは失敗ではない。
  assert.equal(row(done).state, "stopped");
  assert.equal(status(done), "completed");
});

// ---- claude 2.1.300 の stream-json ----

test("S1: バックグラウンドのサブエージェント。background_tasks_changed が先に来て、終わりは task_updated → task_notification → []", () => {
  const t = new SubagentTracker();
  const listed = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","task_type":"local_agent","subagent_type":"general-purpose","description":"sleep probe"}],"uuid":"u1","session_id":"s"}`
    )
  );
  assert.equal(row(listed).id, "a57c174413ad17401");
  assert.equal(row(listed).label, "sleep probe");
  assert.equal(row(listed).labelIsFallback, false);
  assert.equal(row(listed).agentType, "general-purpose");
  assert.equal(row(listed).rowKind, "agent");
  assert.equal(row(listed).background, true);
  assert.equal(card(listed).epoch, t.epoch);
  assert.equal(card(listed).kind, "subagents");

  const started = t.ingestStreamLine(
    obj(
      '{"type":"system","subtype":"task_started","task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","description":"sleep probe","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent","prompt":"Run the Bash command `sleep 20; echo hi` and report its output exactly as returned."}'
    )
  );
  // 同じ run_id なので再開ではなく、同じ行の続き。
  assert.equal(row(started).index, 0);
  assert.equal(row(started).state, "running");
  assert.equal(rows(t.snapshot()).length, 1);

  const launched = t.ingestStreamLine(
    obj(
      `{"type":"user","parent_tool_use_id":null,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","content":"Async agent launched successfully."}]},"tool_use_result":{"isAsync":true,"status":"async_launched","agentId":"a57c174413ad17401","description":"sleep probe","resolvedModel":"claude-haiku-5-5","canReadOutputFile":true,"canContinueAgent":true}}`
    )
  );
  assert.equal(row(launched).model, "claude-haiku-5-5");
  assert.equal(row(launched).background, true);
  assert.equal(t.runningAgentCount, 1);

  const tool = t.ingestStreamLine(
    obj(
      `{"type":"assistant","parent_tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_01NLgsBJ9DMyxtTkphdRxbJJ","name":"Bash","input":{"command":"sleep 20; echo hi","description":"Sleep 20 seconds then echo hi"}}]}}`
    )
  );
  assert.equal(row(tool).resultPreview, "Bash: Sleep 20 seconds then echo hi");
  const progress = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_progress","task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","description":"Running Sleep 20 seconds then echo hi","subagent_type":"general-purpose","usage":{"total_tokens":9792,"tool_uses":1,"duration_ms":1987},"last_tool_name":"Bash"}`
    )
  );
  assert.equal(row(progress).resultPreview, "Running Sleep 20 seconds then echo hi");
  assert.equal(row(progress).tokens, 9792);

  // サブエージェントの中の前景の Bash（owned_by_subagent、is_backgrounded:false）は行にしない。
  assert.equal(
    t.ingestStreamLine(
      obj(
        `{"type":"system","subtype":"task_started","task_id":"bew97awf2","run_id":"0mvgqsjr3-d44d1ef2","owned_by_subagent":true,"tool_use_id":"toolu_01NLgsBJ9DMyxtTkphdRxbJJ","description":"Sleep 20 seconds then echo hi","is_backgrounded":false,"parent_task_id":"a57c174413ad17401","task_type":"local_bash"}`
      )
    ),
    undefined
  );
  assert.equal(
    t.ingestStreamLine(
      obj(
        `{"type":"system","subtype":"task_notification","task_id":"bew97awf2","run_id":"0mvgqsjr3-d44d1ef2","tool_use_id":"toolu_01NLgsBJ9DMyxtTkphdRxbJJ","status":"completed","output_file":"","summary":"Sleep 20 seconds then echo hi"}`
      )
    ),
    undefined
  );
  assert.equal(rows(t.snapshot()).length, 1);

  // end_time は今から 1.5 秒後にする（行の開始は今）。所要時間は end_time − 開始で上書きする。
  const end = Date.now() + 1500;
  const updated = t.ingestStreamLine(
    obj(`{"type":"system","subtype":"task_updated","task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","patch":{"status":"completed","end_time":${end}}}`)
  );
  assert.equal(row(updated).state, "done");
  assert.equal(row(updated).endedAtMs, end);
  // 実行中の「いまの作業」は結果ではない。結果なしで閉じた行は、アプリが持つ作業の文を空文字で消させる。
  assert.equal(row(updated).resultPreview, "", "結果なしで閉じた行は、アプリが持つ作業の文を空文字で消させる");
  const duration = Number(row(updated).durationMs);
  assert.ok(duration >= 1300 && duration <= 1800, `durationMs = ${duration}`);

  const notified = t.ingestStreamLine(
    obj(
      '{"type":"system","subtype":"task_notification","task_id":"a57c174413ad17401","run_id":"0mvgqsf7a-a06fabb6","tool_use_id":"toolu_01NEYDAuv9CV68fDZ6xGGRqK","status":"completed","output_file":"/tmp/tasks/a57c174413ad17401.output","summary":"The command returned:\\n\\n```\\nhi\\n```","usage":{"total_tokens":10483,"tool_uses":1,"duration_ms":24486}}'
    )
  );
  assert.equal(row(notified).resultPreview, "The command returned: ``` hi ```");
  assert.equal(row(notified).result, "The command returned:\n\n```\nhi\n```");
  // usage の duration_ms を優先する。
  assert.equal(row(notified).durationMs, 24486);
  assert.equal(row(notified).tokens, 10483);
  assert.equal(row(notified).toolCalls, 1);
  assert.equal(row(notified).endedAtMs, end);
  assert.equal(status(notified), "completed");

  // 終われば []。閉じる行はもう無い。
  assert.equal(t.ingestStreamLine(obj(`{"type":"system","subtype":"background_tasks_changed","tasks":[]}`)), undefined);
  assert.ok(!t.hasRunning);
});

test("S8: 2〜5 秒を超えた前景の Bash もタスクになるが行にはしない。後から裏に回されたら行にする", () => {
  const t = new SubagentTracker();
  assert.equal(
    t.ingestStreamLine(
      obj(
        `{"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_01MpLdfbFUH6GTKbfAtxTgV7","name":"Bash","input":{"command":"sleep 10; echo fg","description":"Sleep 10 seconds then echo fg"}}]}}`
      )
    ),
    undefined
  );
  assert.equal(
    t.ingestStreamLine(
      obj(
        `{"type":"system","subtype":"task_started","task_id":"b9bxo2mkw","run_id":"0mvgr1z4g-fcdbce7b","tool_use_id":"toolu_01MpLdfbFUH6GTKbfAtxTgV7","description":"Sleep 10 seconds then echo fg","is_backgrounded":false,"task_type":"local_bash"}`
      )
    ),
    undefined
  );
  assert.equal(
    t.ingestStreamLine(
      obj(
        `{"type":"system","subtype":"task_notification","task_id":"b9bxo2mkw","run_id":"0mvgr1z4g-fcdbce7b","tool_use_id":"toolu_01MpLdfbFUH6GTKbfAtxTgV7","status":"completed","output_file":"","summary":"Sleep 10 seconds then echo fg"}`
      )
    ),
    undefined
  );
  assert.ok(t.isEmpty);

  // 前景で始まったシェルが後から裏に回されたら（task_updated の is_backgrounded）、その時点で行にする。
  t.ingestStreamLine(
    obj(
      `{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"toolu_dev","name":"Bash","input":{"command":"npm run dev","description":"Start dev server"}}]}}`
    )
  );
  assert.equal(
    t.ingestStreamLine(
      obj(
        `{"type":"system","subtype":"task_started","task_id":"bdev","run_id":"r1","tool_use_id":"toolu_dev","description":"Start dev server","is_backgrounded":false,"task_type":"local_bash"}`
      )
    ),
    undefined
  );
  const promoted = t.ingestStreamLine(obj(`{"type":"system","subtype":"task_updated","task_id":"bdev","run_id":"r1","patch":{"is_backgrounded":true}}`));
  assert.equal(row(promoted).rowKind, "shell");
  assert.equal(row(promoted).background, true);
  assert.equal(row(promoted).tool, "Bash");
  assert.equal(row(promoted).command, "npm run dev");
});

test("S3r / S14: run_in_background の Bash は行になる（tool と command は main の tool_use から）。exit code ≠ 0 の本当の失敗だけが failed", () => {
  const t = new SubagentTracker();
  t.ingestStreamLine(
    obj(
      `{"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_01DJZLdsqwDVu7vtcG1JRFuK","name":"Bash","input":{"command":"sleep 4; echo bad; exit 3","description":"Run sleep-and-echo command in background","run_in_background":true}}]}}`
    )
  );
  t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bu2tmpln2","run_id":"0mvgr5vn0-f3e30550","task_type":"local_bash","description":"Run sleep-and-echo command in background"}]}`
    )
  );
  const started = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"bu2tmpln2","run_id":"0mvgr5vn0-f3e30550","tool_use_id":"toolu_01DJZLdsqwDVu7vtcG1JRFuK","description":"Run sleep-and-echo command in background","is_backgrounded":true,"task_type":"local_bash"}`
    )
  );
  assert.equal(row(started).rowKind, "shell");
  assert.equal(row(started).tool, "Bash");
  assert.equal(row(started).command, "sleep 4; echo bad; exit 3");
  assert.equal(row(started).background, true);
  assert.equal(t.runningShellCount, 1);
  assert.ok(!t.hasRunningAgents);

  const updated = t.ingestStreamLine(
    obj(`{"type":"system","subtype":"task_updated","task_id":"bu2tmpln2","run_id":"0mvgr5vn0-f3e30550","patch":{"status":"failed","end_time":${Date.now()}}}`)
  );
  assert.equal(row(updated).state, "failed");
  const notified = t.ingestStreamLine(
    obj(
      String.raw`{"type":"system","subtype":"task_notification","task_id":"bu2tmpln2","run_id":"0mvgr5vn0-f3e30550","tool_use_id":"toolu_01DJZLdsqwDVu7vtcG1JRFuK","status":"failed","output_file":"/tmp/tasks/bu2tmpln2.output","summary":"Background command \"Run sleep-and-echo command in background\" failed with exit code 3"}`
    )
  );
  assert.equal(row(notified).state, "failed");
  assert.equal(row(notified).resultPreview, 'Background command "Run sleep-and-echo command in background" failed with exit code 3');
  assert.equal(status(notified), "failed");
  assert.equal(t.ingestStreamLine(obj(`{"type":"system","subtype":"background_tasks_changed","tasks":[]}`)), undefined);
});

test("S4: Monitor は task_type が local_bash（monitor_* ではない）。main の tool_use の名前で見分ける", () => {
  const t = new SubagentTracker();
  t.ingestStreamLine(
    obj(
      `{"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_017t2KGSedEbo8zEHZcmrjaW","name":"Monitor","input":{"command":"for i in 1 2 3; do echo tick $i; sleep 6; done","description":"tick probe","timeout_ms":60000}}]}}`
    )
  );
  const listed = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bjx7sds73","run_id":"0mvgqsig5-a17e9012","task_type":"local_bash","description":"tick probe"}]}`
    )
  );
  assert.equal(row(listed).label, "tick probe");
  const started = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"bjx7sds73","run_id":"0mvgqsig5-a17e9012","tool_use_id":"toolu_017t2KGSedEbo8zEHZcmrjaW","description":"tick probe","is_backgrounded":true,"task_type":"local_bash"}`
    )
  );
  assert.equal(row(started).tool, "Monitor");
  assert.equal(row(started).command, "for i in 1 2 3; do echo tick $i; sleep 6; done");
  assert.equal(row(started).rowKind, "shell");
  assert.equal(row(started).index, 0);
  t.ingestStreamLine(
    obj(`{"type":"system","subtype":"task_updated","task_id":"bjx7sds73","run_id":"0mvgqsig5-a17e9012","patch":{"status":"completed","end_time":${Date.now()}}}`)
  );
  const done = t.ingestStreamLine(
    obj(
      String.raw`{"type":"system","subtype":"task_notification","task_id":"bjx7sds73","run_id":"0mvgqsig5-a17e9012","tool_use_id":"toolu_017t2KGSedEbo8zEHZcmrjaW","status":"completed","output_file":"/tmp/tasks/bjx7sds73.output","summary":"Monitor \"tick probe\" stream ended"}`
    )
  );
  assert.equal(row(done).state, "done");
  assert.equal(row(done).resultPreview, 'Monitor "tick probe" stream ended');
});

test("S5a / S6c: TaskStop・interrupt・SIGINT・後片付けは killed / stopped。失敗ではなく stopped で、説明そのままの summary は結果にしない", () => {
  const t = new SubagentTracker();
  t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"bqyx93sk0","run_id":"0mvgr1yqk-bf76503d","tool_use_id":"toolu_01TRtrHQBdMRhVyUHNsnNpYv","description":"Sleep 61 seconds then echo late","is_backgrounded":true,"task_type":"local_bash"}`
    )
  );
  const killed = t.ingestStreamLine(
    obj(`{"type":"system","subtype":"task_updated","task_id":"bqyx93sk0","run_id":"0mvgr1yqk-bf76503d","patch":{"status":"killed","end_time":${Date.now()}}}`)
  );
  assert.equal(row(killed).state, "stopped");
  // 古いアプリ向けの要約では stopped は失敗に数えない。
  assert.equal(status(killed), "completed");
  assert.equal(
    t.ingestStreamLine(
      obj(
        `{"type":"system","subtype":"task_notification","task_id":"bqyx93sk0","run_id":"0mvgr1yqk-bf76503d","tool_use_id":"toolu_01TRtrHQBdMRhVyUHNsnNpYv","status":"stopped","output_file":"/tmp/tasks/bqyx93sk0.output","summary":"Sleep 61 seconds then echo late"}`
      )
    ),
    undefined
  );
  // 同じ実行の中では、あとから completed が来ても done に戻らない。
  assert.equal(t.finish("bqyx93sk0", "done", "late"), undefined);
  const first = rows(t.snapshot())[0];
  assert.equal(first.state, "stopped");
  assert.equal(first.result, undefined);

  // S6c（SIGINT）: notification が updated より先に来る。end_time は後からでも反映する。
  t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"brkso4yke","run_id":"0mvgr23y0-61a359ee","owned_by_subagent":true,"tool_use_id":"toolu_01EaYd5Pneqmb9hRw6z8N1M5","description":"Sleep 27 seconds then echo hi","is_backgrounded":true,"parent_task_id":"aa7b6ff1a6cd9e144","task_type":"local_bash"}`
    )
  );
  const stopped = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_notification","task_id":"brkso4yke","run_id":"0mvgr23y0-61a359ee","tool_use_id":"toolu_01EaYd5Pneqmb9hRw6z8N1M5","status":"stopped","output_file":"","summary":"Sleep 27 seconds then echo hi"}`
    )
  );
  assert.equal(row(stopped).state, "stopped");
  assert.equal(row(stopped).parentId, "aa7b6ff1a6cd9e144");
  const end = Date.now() + 2000;
  const updated = t.ingestStreamLine(
    obj(`{"type":"system","subtype":"task_updated","task_id":"brkso4yke","run_id":"0mvgr23y0-61a359ee","patch":{"status":"killed","end_time":${end}}}`)
  );
  assert.equal(row(updated).endedAtMs, end);
  assert.equal(row(updated).state, "stopped");
});

test("S7: 終わったサブエージェントが同じ task_id・新しい run_id で再開する。行をやり直し、前の実行の遅れて届いた行は捨てる", () => {
  const t = new SubagentTracker();
  t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqsgen-7a08e34c","tool_use_id":"toolu_01VzL1Mfsd2NNKScsRqdVLit","description":"followup probe","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent"}`
    )
  );
  t.ingestStreamLine(
    obj(`{"type":"system","subtype":"task_updated","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqsgen-7a08e34c","patch":{"status":"completed","end_time":${Date.now()}}}`)
  );
  const first = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_notification","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqsgen-7a08e34c","tool_use_id":"toolu_01VzL1Mfsd2NNKScsRqdVLit","status":"completed","summary":"The foreground run was blocked, so I started it in the background.","usage":{"total_tokens":11200,"tool_uses":2,"duration_ms":8400}}`
    )
  );
  assert.equal(row(first).state, "done");
  assert.equal(row(first).durationMs, 8400);

  // 再開は background_tasks_changed（新しい run_id）が task_started より先に来る。
  const reopened = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"aaa2e86b2db1ba716","run_id":"0mvgqtd1y-c82e5ef4","task_type":"local_agent","subagent_type":"general-purpose","description":"followup probe"}]}`
    )
  );
  assert.equal(row(reopened).state, "running");
  assert.equal(row(reopened).index, 0);
  assert.equal(row(reopened).durationMs, undefined);
  assert.equal(row(reopened).resultPreview, "", "再開した行は前の実行の結果を空文字で消させる");
  assert.equal(row(reopened).result, "");
  assert.equal(row(reopened).endedAtMs, undefined);
  // 同じ run_id の task_started は二重にやり直さない。
  const started = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqtd1y-c82e5ef4","tool_use_id":"toolu_01VzL1Mfsd2NNKScsRqdVLit","description":"followup probe","subagent_type":"general-purpose","is_backgrounded":true,"spawn_depth":1,"task_type":"local_agent","prompt":"<task-notification>…"}`
    )
  );
  assert.equal(row(started).startedAtMs, row(reopened).startedAtMs);
  // 前の実行の遅れて届いた知らせは捨てる。
  assert.equal(
    t.ingestStreamLine(
      obj(`{"type":"system","subtype":"task_notification","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqsgen-7a08e34c","status":"completed","summary":"old"}`)
    ),
    undefined
  );
  const progress = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_progress","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqtd1y-c82e5ef4","description":"Reading bzihmbpeo","subagent_type":"general-purpose","usage":{"total_tokens":11865,"tool_uses":3,"duration_ms":43806},"last_tool_name":"Read"}`
    )
  );
  assert.equal(row(progress).resultPreview, "Reading bzihmbpeo");
  const done = t.ingestStreamLine(
    obj(`{"type":"system","subtype":"task_updated","task_id":"aaa2e86b2db1ba716","run_id":"0mvgqtd1y-c82e5ef4","patch":{"status":"completed","end_time":${Date.now()}}}`)
  );
  assert.equal(row(done).state, "done");
  // background_tasks_changed を取りこぼしても、終わった行への task_started で再開する。
  const again = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"aaa2e86b2db1ba716","run_id":"third","tool_use_id":"toolu_01VzL1Mfsd2NNKScsRqdVLit","description":"followup probe","subagent_type":"general-purpose","is_backgrounded":true,"task_type":"local_agent"}`
    )
  );
  assert.equal(row(again).state, "running");
  assert.equal(rows(t.snapshot()).length, 1);
});

test("S2: background_tasks_changed に載っていない background の行は done で閉じるが、前景のサブエージェントは閉じない", () => {
  const t = new SubagentTracker();
  const b = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"a79ab777d21c0dcd9","run_id":"0mvgqsh4q-0d8ebd56","tool_use_id":"toolu_016ogRUek8Agmdc4CARfVpLg","description":"probe B","subagent_type":"general-purpose","is_backgrounded":false,"spawn_depth":1,"task_type":"local_agent"}`
    )
  );
  assert.equal(row(b).background, false);
  t.ingestStreamLine(
    obj(
      `{"type":"assistant","parent_tool_use_id":"toolu_016ogRUek8Agmdc4CARfVpLg","message":{"model":"claude-haiku-5-5","content":[{"type":"tool_use","id":"toolu_01JeTqykjewGCFtrNqr69MUt","name":"Bash","input":{"command":"sleep 31; echo B","description":"Sleep 31 seconds then echo B","run_in_background":true}}]}}`
    )
  );
  t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bnebie9kn","run_id":"0mvgqskoi-f48d5ae7","task_type":"local_bash","description":"Sleep 31 seconds then echo B","parent_task_id":"a79ab777d21c0dcd9"}]}`
    )
  );
  const shell = t.ingestStreamLine(
    obj(
      `{"type":"system","subtype":"task_started","task_id":"bnebie9kn","run_id":"0mvgqskoi-f48d5ae7","owned_by_subagent":true,"tool_use_id":"toolu_01JeTqykjewGCFtrNqr69MUt","description":"Sleep 31 seconds then echo B","is_backgrounded":true,"parent_task_id":"a79ab777d21c0dcd9","task_type":"local_bash"}`
    )
  );
  assert.equal(row(shell).parentId, "a79ab777d21c0dcd9");
  assert.equal(row(shell).tool, "Bash");
  assert.equal(row(shell).command, "sleep 31; echo B");
  // 前景のサブエージェントの中の前景の Bash は行にしない。
  assert.equal(
    t.ingestStreamLine(
      obj(
        `{"type":"system","subtype":"task_started","task_id":"bn40n3gxw","run_id":"0mvgqsmxb-5f9f4650","owned_by_subagent":true,"tool_use_id":"toolu_011CjR3w6nnmYNWTBjFyF8Uo","description":"Sleep 16 seconds then echo A","is_backgrounded":false,"parent_task_id":"afb1dfb27dee16255","task_type":"local_bash"}`
      )
    ),
    undefined
  );
  // シェルの終わりを取りこぼしても、一覧から消えたら閉じる。前景のサブエージェントはそのまま。
  const closed = t.ingestStreamLine(obj(`{"type":"system","subtype":"background_tasks_changed","tasks":[]}`));
  assert.deepEqual(
    rows(closed).map((r) => r.id),
    ["bnebie9kn"]
  );
  assert.equal(row(closed).state, "done");
  assert.ok(t.hasRunningAgents);
  assert.equal(t.runningShellCount, 0);
  // hooks の Stop（closeForeground 既定 true）なら前景の行も閉じる。
  assert.equal(row(t.reconcile([])).id, "a79ab777d21c0dcd9");
  assert.ok(!t.hasRunning);
});

// ---- hooks（ターミナル） ----

test("hooks: PreToolUse(Agent) → SubagentStart → サブエージェント内の PreToolUse → SubagentStop", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Agent", { description: "JSONファイル探索", subagent_type: "Explore", prompt: "…" });
  const started = t.hookStart("a1", "Explore");
  assert.equal(row(started).label, "JSONファイル探索");

  const tool = t.hookTool("a1", "Glob", { pattern: "*.json" });
  assert.equal(row(tool).toolCalls, 1);
  assert.equal(row(tool).resultPreview, "Glob: *.json");
  assert.ok(t.hasRunning);

  const stopped = t.hookStop("a1", "Explore", "settings.json のみ");
  assert.equal(row(stopped).state, "done");
  assert.equal(row(stopped).resultPreview, "settings.json のみ");
  assert.equal(row(stopped).result, "settings.json のみ");
  assert.ok(!t.hasRunning);
});

test("hooks: 並列の起動は同じ種類のうち一番古いものと突き合わせる。説明が空なら種類名（既定文）", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Agent", { description: "調査A", subagent_type: "Explore" });
  t.noteLaunch("Agent", { description: "計画B", subagent_type: "Plan" });
  t.noteLaunch("Read", { file_path: "/x" }); // Agent 以外は無視
  assert.equal(row(t.hookStart("p", "Plan")).label, "計画B");
  assert.equal(row(t.hookStart("e", "Explore")).label, "調査A");
  // SubagentStart を受けていないサブエージェントのツールは行を作らない（呼び出し側が親のツール行に出す）。
  assert.equal(t.hookTool("z", "Bash", undefined), undefined);
  assert.ok(!t.has("z"));
  // 説明が空なら種類名を出す（既定文。新しいアプリは labelIsFallback を見て自分の言語で出す）。
  t.noteLaunch("Agent", { subagent_type: "general-purpose" });
  const fallback = row(t.hookStart("z", "general-purpose"));
  assert.equal(fallback.label, "general-purpose");
  assert.equal(fallback.labelIsFallback, true);
  // 実行中のものは pruneFinished で消えない。
  t.pruneFinished();
  assert.ok(!t.isEmpty);
  assert.deepEqual(
    rows(t.snapshot()).map((r) => r.index),
    [0, 1, 2]
  );
});

test("hooks: 内部の補助（agent_type が空の SubagentStart）は行にしない。SendMessage で話しかけ直したサブエージェントは出す", () => {
  const t = new SubagentTracker();
  assert.equal(t.hookStart("s1", ""), undefined);
  assert.ok(t.isIgnored("s1"));
  assert.equal(t.hookStop("s1", "", "そのまま続けて"), undefined);
  assert.ok(t.isEmpty);
  t.noteLaunch("SendMessage", { to: "a1", message: "続きを調べて", summary: "続きの調査" });
  assert.equal(row(t.hookStart("a1", "general-purpose")).label, "続きの調査");
});

test("hooks: 次の発話の候補づくり（agent_type が空）とバックグラウンドの要約（agent_type キーが無い）は内部の補助", () => {
  const suggestion = obj(
    `{"agent_id":"ad7946b3eb4bb42a7","agent_type":"","hook_event_name":"SubagentStop","stop_hook_active":false,"last_assistant_message":"check on sleeper A","background_tasks":[{"id":"adecffdf418d355ef","type":"subagent","status":"running","description":"probe sleeper A","agent_type":"general-purpose"}],"session_crons":[]}`
  );
  assert.ok(isInternalHelper(suggestion.agent_id as string, suggestion.agent_type));
  const summarizer = obj(
    `{"agent_id":"a9ffe224a77f5eda2","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ping -c 40 127.0.0.1 > /dev/null; echo hi"},"tool_use_id":"toolu_01F6CFcapFeqbUriAzCy4vdW"}`
  );
  assert.ok(isInternalHelper(summarizer.agent_id as string, summarizer.agent_type));
  assert.ok(isInternalHelper("a1", null));
  assert.ok(!isInternalHelper("adecffdf418d355ef", "general-purpose"));
  // main のスレッドの hook（agent_id が無い）は補助ではない。
  assert.ok(!isInternalHelper(undefined, undefined));

  // 補助の SubagentStart は起動待ちを使わない（本物の SubagentStart が説明を受け取る）。
  const t = new SubagentTracker();
  t.noteLaunch("Agent", { description: "probe sleeper A", subagent_type: "general-purpose" });
  assert.equal(t.hookStart("ad7946b3eb4bb42a7", ""), undefined);
  assert.equal(row(t.hookStart("adecffdf418d355ef", "general-purpose")).label, "probe sleeper A");
});

test("hooks: PostToolUse(Agent) の async_launched が SubagentStart より先に来ても、その id の行に説明を結び付ける", () => {
  const t = new SubagentTracker();
  t.noteLaunch(
    "Agent",
    { description: "probe sleeper C", subagent_type: "general-purpose", prompt: "Run the Bash command `sleep 45; echo hi`" },
    "toolu_01SQpCCyhZTNaC2GguVSTXPN"
  );
  const hook = obj(
    '{"hook_event_name":"PostToolUse","tool_name":"Agent","tool_input":{"description":"probe sleeper C","prompt":"Run the Bash command `sleep 45; echo hi`","subagent_type":"general-purpose"},"tool_response":{"isAsync":true,"status":"async_launched","agentId":"ae2e9cbe3e734c8cb","description":"probe sleeper C","resolvedModel":"claude-haiku-5-5","outputFile":"/tmp/tasks/ae2e9cbe3e734c8cb.output","canReadOutputFile":true,"canContinueAgent":true},"tool_use_id":"toolu_01SQpCCyhZTNaC2GguVSTXPN","duration_ms":13}'
  );
  const bound = t.hookToolResult(hook.tool_use_id as string, "Agent", hook.tool_input, hook.tool_response);
  assert.equal(row(bound).id, "ae2e9cbe3e734c8cb");
  assert.equal(row(bound).label, "probe sleeper C");
  assert.equal(row(bound).agentType, "general-purpose");
  assert.equal(row(bound).background, true);
  assert.equal(row(bound).model, "claude-haiku-5-5");

  t.noteLaunch("Agent", { description: "next one", subagent_type: "general-purpose" }, "toolu_next");
  const started = t.hookStart("ae2e9cbe3e734c8cb", "general-purpose");
  assert.equal(row(started).index, 0);
  assert.equal(row(started).label, "probe sleeper C");
  // 起動待ちは残っているので、次のサブエージェントが自分の説明を受け取る。
  assert.equal(row(t.hookStart("a2", "general-purpose")).label, "next one");
});

test("hooks: SubagentStart が先なら PostToolUse(Agent) で background を付ける。並列の同じ種類で順がずれても正しい説明に直る", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Agent", { description: "probe sleeper A", subagent_type: "general-purpose" }, "toolu_01RkBL9LaBTzzECsVUukefrE");
  assert.equal(row(t.hookStart("adecffdf418d355ef", "general-purpose")).background, undefined);
  const bound = t.hookToolResult(
    "toolu_01RkBL9LaBTzzECsVUukefrE",
    "Agent",
    { description: "probe sleeper A", subagent_type: "general-purpose" },
    { isAsync: true, status: "async_launched", agentId: "adecffdf418d355ef", description: "probe sleeper A", resolvedModel: "claude-haiku-5-5" }
  );
  assert.equal(row(bound).background, true);
  assert.equal(row(bound).label, "probe sleeper A");
  assert.equal(rows(t.snapshot()).length, 1);

  t.noteLaunch("Agent", { description: "A1", subagent_type: "Explore" }, "t1");
  t.noteLaunch("Agent", { description: "A2", subagent_type: "Explore" }, "t2");
  // x は本当は A2（t2）だが、順番どおり A1 を受け取る。
  assert.equal(row(t.hookStart("x", "Explore")).label, "A1");
  const fixed = t.hookToolResult("t2", "Agent", { description: "A2", subagent_type: "Explore" }, { status: "async_launched", agentId: "x" });
  assert.equal(row(fixed).label, "A2");
  // t1 は x が使い、t2 は PostToolUse で消えたので、y の SubagentStart には起動待ちが無い。
  assert.equal(t.hookStart("y", "Explore"), undefined);
  assert.ok(t.isIgnored("y"));
  const y = t.hookToolResult("t1", "Agent", { description: "A1", subagent_type: "Explore" }, { status: "async_launched", agentId: "y" });
  assert.equal(row(y).label, "A1");
  assert.ok(!t.isIgnored("y"));
});

test("hooks: SendMessage は宛先（to）の id とだけ突き合わせる。動いている相手への SendMessage は積まない", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Agent", { description: "依存関係を調べる", subagent_type: "Explore" }, "tA");
  t.hookStart("a1", "Explore");
  // 動いている a1 への SendMessage は次のツールの区切りで届くだけ（SubagentStart は来ない）。
  t.noteLaunch("SendMessage", { to: "a1", message: "ついでに", summary: "追加の依頼" });
  // 止まった a9 への SendMessage は、a9 の SubagentStart とだけ突き合わせる。
  t.noteLaunch("SendMessage", { to: "a9", message: "続きを調べて", summary: "続きの調査" });
  t.noteLaunch("Agent", { description: "設定を調べる", subagent_type: "Explore" }, "tB");
  assert.equal(row(t.hookStart("b2", "Explore")).label, "設定を調べる");
  assert.equal(row(t.hookStart("a9", "general-purpose")).label, "続きの調査");
  // 知っている行の SubagentStart は、起動待ちを使わずに再開する。
  t.hookStop("a1", "Explore", "done");
  const resumed = t.hookStart("a1", "Explore");
  assert.equal(row(resumed).state, "running");
  assert.equal(row(resumed).label, "依存関係を調べる");
  assert.equal(row(resumed).result, "");
});

test("hooks: run_in_background の Bash は backgroundTaskId で shell の行（tool・background 付き）になり、Esc では閉じず、知らせで閉じる", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Bash", { command: "for i in $(seq 1 60); do dig …; done", description: "DNS の反映を待つ", run_in_background: true }, "toolu_B");
  const started = t.hookToolResult("toolu_B", "Bash", undefined, { stdout: "", backgroundTaskId: "b0fz5vnji" });
  assert.equal(row(started).label, "DNS の反映を待つ");
  assert.equal(row(started).rowKind, "shell");
  assert.equal(row(started).tool, "Bash");
  assert.equal(row(started).background, true);
  // 前景の Bash（backgroundTaskId が無い）は行にしない。
  assert.equal(t.hookToolResult("toolu_C", "Bash", undefined, { stdout: "ok" }), undefined);
  // Esc の中断ではシェルは閉じない。
  assert.equal(t.abandonRunning({ includeShells: false }), undefined);
  const text = [
    "<task-notification>",
    "<task-id>b0fz5vnji</task-id>",
    "<tool-use-id>toolu_B</tool-use-id>",
    "<status>completed</status>",
    '<summary>Background command "DNS の反映を待つ" completed (exit code 0)</summary>',
    "</task-notification>"
  ].join("\n");
  const done = t.ingestNotifications(text);
  assert.equal(done.length, 1);
  assert.equal(row(done[0]).state, "done");
  assert.equal(row(done[0]).resultPreview, 'Background command "DNS の反映を待つ" completed (exit code 0)');
  assert.equal(stripNotifications(`${text}\n続けて`), "続けて");
});

test("hooks: PostToolUse(TaskStop) の task_id の行はすぐ stopped で閉じる（止めたシェルには知らせが来ない）。Monitor は taskId で行にする", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Bash", { command: "ping 127.0.0.1 > /dev/null", run_in_background: true }, "toolu_G");
  const started = t.hookToolResult(
    "toolu_G",
    "Bash",
    { command: "ping 127.0.0.1 > /dev/null", run_in_background: true },
    { stdout: "", stderr: "", interrupted: false, backgroundTaskId: "bc3mclkys" }
  );
  assert.equal(row(started).command, "ping 127.0.0.1 > /dev/null");
  const hook = obj(
    `{"hook_event_name":"PostToolUse","tool_name":"TaskStop","tool_input":{"task_id":"bc3mclkys"},"tool_response":{"message":"Successfully stopped task: bc3mclkys (ping 127.0.0.1 > /dev/null)","task_id":"bc3mclkys","task_type":"local_bash","command":"ping 127.0.0.1 > /dev/null"},"tool_use_id":"toolu_017vzJEvJeao6HGgVVYzRtUg","duration_ms":108}`
  );
  const stopped = t.hookToolResult(hook.tool_use_id as string, "TaskStop", hook.tool_input, hook.tool_response);
  assert.equal(row(stopped).state, "stopped");
  assert.equal(typeof row(stopped).endedAtMs, "number");
  assert.equal(status(stopped), "completed");
  // 次の Stop（一覧は空）でも done に変わらない。
  assert.equal(t.reconcile([]), undefined);
  assert.equal(rows(t.snapshot())[0].state, "stopped");

  const monitor = t.hookToolResult(
    "toolu_M",
    "Monitor",
    { command: "tail -f app.log", description: "watch app log" },
    { taskId: "bm1", timeoutMs: 60000, persistent: false }
  );
  assert.equal(row(monitor).tool, "Monitor");
  assert.equal(row(monitor).label, "watch app log");
  assert.equal(row(monitor).rowKind, "shell");
});

test("hooks: task-notification の <result> を結果に、<usage> を数値にする。決まり文句の <summary> で結果を上書きしない", () => {
  const text = [
    "<task-notification>",
    "<task-id>adecffdf418d355ef</task-id>",
    "<tool-use-id>toolu_01RkBL9LaBTzzECsVUukefrE</tool-use-id>",
    "<output-file>/tmp/tasks/adecffdf418d355ef.output</output-file>",
    "<status>completed</status>",
    '<summary>Agent "probe sleeper A" finished</summary>',
    "<note>A task-notification fires each time this agent stops with no live background children of its own. The user can send it another message and resume it, so the same task-id may notify more than once.</note>",
    "<result>hi</result>",
    "<usage><subagent_tokens>24570</subagent_tokens><tool_uses>1</tool_uses><duration_ms>24935</duration_ms></usage>",
    "</task-notification>"
  ].join("\n");
  assert.deepEqual(taskNotifications(text), [
    { taskId: "adecffdf418d355ef", status: "completed", summary: 'Agent "probe sleeper A" finished', result: "hi", tokens: 24570, toolUses: 1, durationMs: 24935 }
  ]);

  const t = new SubagentTracker();
  t.noteLaunch("Agent", { description: "probe sleeper A", subagent_type: "general-purpose" });
  t.hookStart("adecffdf418d355ef", "general-purpose");
  assert.equal(row(t.hookStop("adecffdf418d355ef", "general-purpose", "hi")).state, "done");
  const p = t.ingestNotifications(text);
  assert.equal(p.length, 1);
  assert.equal(row(p[0]).resultPreview, "hi");
  assert.equal(row(p[0]).tokens, 24570);
  assert.equal(row(p[0]).toolCalls, 1);
  assert.equal(row(p[0]).durationMs, 24935);

  // 同じ task-id がもう一度届いても、<result> が無ければ決まり文句で上書きしない。
  const again = t.ingestNotifications(
    '<task-notification><task-id>adecffdf418d355ef</task-id><status>completed</status><summary>Agent "probe sleeper A" finished</summary></task-notification>'
  );
  assert.equal(again.length, 0);
  assert.equal(rows(t.snapshot())[0].resultPreview, "hi");

  // 結果の本文にタグの文字があっても切らない。<usage> はその後ろから読む。
  const [tricky] = taskNotifications(
    "<task-notification><task-id>x</task-id><status>failed</status>" +
      "<result>use </result> literally</result><usage><total_tokens>5</total_tokens><tool_uses>2</tool_uses></usage>" +
      "</task-notification>"
  );
  assert.equal(tricky.result, "use </result> literally");
  assert.equal(tricky.toolUses, 2);
  assert.equal(tricky.tokens, 5);
  assert.equal(tricky.status, "failed");
});

test("hooks: Stop の background_tasks（古い内部名も受ける）と突き合わせる。知らないものは行を作り、一覧から消えた行は閉じる", () => {
  const t = new SubagentTracker();
  const added = t.reconcile([
    { id: "b1", type: "local_bash", status: "running", description: "npm run dev", command: "npm run dev" },
    { id: "a1", type: "local_agent", status: "running", description: "調査", agent_type: "Explore" }
  ]);
  assert.deepEqual(
    rows(added).map((r) => r.rowKind),
    ["shell", "agent"]
  );
  const closed = t.reconcile([{ id: "a1", type: "local_agent", status: "running", description: "調査" }]);
  assert.equal(row(closed).state, "done");
  assert.equal(row(closed).label, "npm run dev");
  assert.ok(t.hasRunningAgents);
  assert.equal(t.reconcile(undefined), undefined);
});

test("hooks: Stop の background_tasks の type は表示名。完全一致で振り分け、dream などは出さない。一覧に無い実行中の行は全部閉じる", () => {
  const t = new SubagentTracker();
  const added = t.reconcile([
    { id: "adecffdf418d355ef", type: "subagent", status: "running", description: "probe sleeper A", agent_type: "general-purpose" },
    { id: "b5x8zhq6o", type: "shell", status: "running", description: "probe bg shell B", command: "sleep 25; echo done" },
    { id: "w1", type: "workflow", status: "running", description: "review the repo", name: "review" },
    { id: "r1", type: "cloud session", status: "running", description: "remote fix" },
    { id: "tm1", type: "teammate", status: "pending", description: "researcher" },
    { id: "m1", type: "monitor", status: "running", description: "watch logs" },
    { id: "mcp1", type: "MCP task", status: "running", description: "export", server: "figma", tool: "export_frames" },
    { id: "d1", type: "dream", status: "running", description: "dreaming" },
    { id: "s1", type: "auto-mode scan", status: "running", description: "scanning for auto-mode setup" },
    { id: "i1", type: "memory import", status: "running", description: "importing memories" }
  ]);
  const byId = Object.fromEntries(rows(added).map((r) => [String(r.id), r]));
  assert.deepEqual(Object.keys(byId).sort(), ["adecffdf418d355ef", "b5x8zhq6o", "m1", "mcp1", "r1", "tm1", "w1"]);
  assert.equal(byId["adecffdf418d355ef"].rowKind, "agent");
  assert.equal(byId["adecffdf418d355ef"].agentType, "general-purpose");
  assert.equal(byId["b5x8zhq6o"].rowKind, "shell");
  assert.equal(byId["b5x8zhq6o"].command, "sleep 25; echo done");
  assert.equal(byId["b5x8zhq6o"].background, true);
  assert.equal(byId["w1"].rowKind, "agent");
  assert.equal(byId["w1"].agentType, "workflow");
  assert.equal(byId["w1"].label, "review the repo");
  assert.equal(byId["r1"].rowKind, "agent");
  assert.equal(byId["r1"].agentType, "cloud session");
  assert.equal(byId["tm1"].agentType, "teammate");
  assert.equal(byId["m1"].rowKind, "shell");
  assert.equal(byId["m1"].tool, "Monitor");
  assert.equal(byId["mcp1"].rowKind, "shell");
  assert.equal(t.runningAgentCount, 4);
  assert.equal(t.runningShellCount, 3);

  const closed = t.reconcile([{ id: "b5x8zhq6o", type: "shell", status: "running", description: "probe bg shell B" }]);
  assert.equal(rows(closed).length, 6);
  assert.ok(rows(closed).every((r) => r.state === "done"));
  assert.ok(!t.hasRunningAgents);
  assert.equal(t.runningShellCount, 1);
});

test("hooks: Esc の中断で閉じるのは background でない実行中の agent 行だけ（stopped）。後の SubagentStop で done に戻らない。異常終了だけが failed", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Agent", { description: "裏の調査", subagent_type: "Explore" }, "tb");
  t.hookStart("bg", "Explore");
  t.hookToolResult("tb", "Agent", { description: "裏の調査" }, { status: "async_launched", agentId: "bg" });
  t.noteLaunch("Agent", { description: "前の調査", subagent_type: "Plan" }, "tf");
  t.hookStart("fg", "Plan");
  t.hookToolResult("tsh", "Bash", { command: "npm run dev" }, { backgroundTaskId: "sh" });
  const p = t.abandonRunning({ includeShells: false, onlyForeground: true });
  assert.deepEqual(
    rows(p).map((r) => r.id),
    ["fg"]
  );
  assert.equal(row(p).state, "stopped");
  assert.equal(t.runningAgentCount, 1);
  assert.equal(t.runningShellCount, 1);
  assert.equal(t.hookStop("fg", "Plan", "途中まで"), undefined);

  const crashed = t.abandonRunning({ state: "failed" });
  assert.deepEqual(
    rows(crashed).map((r) => r.id),
    ["bg", "sh"]
  );
  assert.deepEqual(
    rows(crashed).map((r) => r.state),
    ["failed", "failed"]
  );
});

test("中断・プロセス終了・close では実行中の行だけを閉じる（既定は stopped）。終わった行の状態はそのまま", () => {
  const t = new SubagentTracker();
  t.noteLaunch("Agent", { subagent_type: "Explore" });
  t.noteLaunch("Agent", { subagent_type: "Plan" });
  t.hookStart("a", "Explore");
  t.hookStart("b", "Plan");
  t.hookStop("a", "Explore", "done");
  const p = t.abandonRunning();
  assert.equal(row(p).index, 1);
  assert.equal(row(p).state, "stopped");
  assert.ok(!t.hasRunning);
  assert.equal(t.abandonRunning(), undefined);
  assert.deepEqual(
    rows(t.snapshot()).map((r) => r.state),
    ["done", "stopped"]
  );
});

test("snapshot: workflow_snapshot で全行を epoch 付きで返す。includeEmpty なら行が無くても agents: []", () => {
  const t = new SubagentTracker();
  assert.equal(t.snapshot(), undefined);
  const empty = card(t.snapshot({ includeEmpty: true }));
  assert.equal(empty.subtype, "workflow_snapshot");
  assert.equal(empty.kind, "subagents");
  assert.equal(empty.taskId, "subagents");
  assert.equal(empty.epoch, t.epoch);
  assert.equal(empty.status, "completed");
  assert.deepEqual(empty.agents, []);
  assert.match(t.epoch, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  // 作り直すと世代が変わる。
  assert.notEqual(new SubagentTracker().epoch, t.epoch);

  t.begin("a", "x");
  t.begin("b", undefined, { rowKind: "shell" });
  const snap = card(t.snapshot());
  assert.equal(snap.subtype, "workflow_snapshot");
  assert.equal(snap.epoch, t.epoch);
  const all = snap.agents as Row[];
  assert.deepEqual(
    all.map((r) => r.id),
    ["a", "b"]
  );
  assert.equal(all[1].label, "バックグラウンドのコマンド");
  assert.equal(all[1].labelIsFallback, true);
  assert.equal(all[0].labelIsFallback, false);
  // ふだんの変化は task_progress（変わった行だけ）。
  const changed = card(t.activity("a", "Read: /x"));
  assert.equal(changed.subtype, "task_progress");
  assert.equal((changed.agents as Row[]).length, 1);
});

test("汎用: begin / activity / finish と、話しかけ直しでの再開。failed / stopped は同じ実行の中で done に戻らない", () => {
  const t = new SubagentTracker();
  assert.equal(row(t.begin("th1", "ファイル一覧を調べて\n詳しく", { model: "gpt-5" })).label, "ファイル一覧を調べて 詳しく");
  assert.equal(row(t.activity("th1", "command: ls", { toolCall: true })).toolCalls, 1);
  assert.equal(t.activity("unknown", "x"), undefined);
  assert.equal(row(t.finish("th1", false, "3 files")).state, "done");
  // 同じ状態で結果も無い finish は送らない（Codex の agentsStates は何度も届く）。
  assert.equal(t.finish("th1", false), undefined);
  // 終わった行の作業の文は送らない。
  assert.equal(t.activity("th1", "late"), undefined);
  // 話しかけ直された（sendInput）ら実行中に戻る。結果と所要時間はやり直す。
  const reopened = row(t.begin("th1"));
  assert.equal(reopened.state, "running");
  assert.equal(reopened.resultPreview, "");
  assert.equal(reopened.result, "");
  assert.equal(reopened.durationMs, undefined);
  assert.equal(reopened.model, "gpt-5");

  // 中断・失敗は同じ実行の中で done に戻らない（Codex の completed が interrupted の後に来る等）。
  t.begin("th2", "子");
  assert.equal(row(t.finish("th2", "interrupted")).state, "stopped");
  assert.equal(t.finish("th2", "done", "完了"), undefined);
  assert.equal(t.finish("th2", true), undefined);
  t.begin("th3", "子 3");
  assert.equal(row(t.finish("th3", "failed", "rate limited")).resultPreview, "rate limited");
  assert.equal(t.finish("th3", false, "ok"), undefined);
  // done の後に届いた失敗は受ける（reconcile で閉じた後の失敗の知らせ等）。
  t.begin("th4", "子 4");
  t.finish("th4", "done");
  assert.equal(row(t.finish("th4", "failed", "exit code 1")).state, "failed");
  // 結果の本文は 2000 字まで、冒頭は 1 行で 160 字まで。
  t.begin("th5", "長い");
  const long = row(t.finish("th5", "done", "あ".repeat(2500)));
  assert.equal(Array.from(String(long.result)).length, 2001);
  assert.equal(Array.from(String(long.resultPreview)).length, 161);
});

test("finalState: CLI の終わり方の語を done / failed / stopped にする", () => {
  for (const s of ["completed", "done", "success"]) assert.equal(finalState(s), "done", s);
  for (const s of ["failed", "error"]) assert.equal(finalState(s), "failed", s);
  for (const s of ["killed", "stopped", "cancelled", "canceled", "interrupted", "aborted"]) assert.equal(finalState(s), "stopped", s);
  for (const s of ["running", "pending", "started", ""]) assert.equal(finalState(s), undefined, s);
});

test("delegation: 名前と subagent_type で見分ける。説明の無いタスクの配列は既定文（件数付き）", () => {
  assert.equal(delegation("delegate_task", undefined, { goal: "要約" })?.label, "要約");
  assert.equal(delegation("sessions_spawn", undefined, { task: "ビルド", agentId: "coder" })?.agentType, "coder");
  assert.equal(delegation("read_file", undefined, { path: "/x" }), undefined);
  // claude-code-acp はタイトルに説明が入るので subagent_type で見分ける。
  assert.equal(delegation("調査", "調査", { subagent_type: "Explore" })?.agentType, "Explore");
  // 説明の無いタスクの配列は既定文（件数付き）。
  const tasks = delegation("delegate_task", undefined, { tasks: [{ goal: "a" }, { goal: "b" }] });
  assert.equal(tasks?.label, "2 件のタスク");
  assert.equal(tasks?.labelIsFallback, true);
  assert.equal(tasks?.taskCount, 2);
  const t = new SubagentTracker();
  const p = t.begin("h", tasks?.label, { labelIsFallback: tasks?.labelIsFallback, taskCount: tasks?.taskCount });
  assert.equal(row(p).label, "2 件のタスク");
  assert.equal(row(p).labelIsFallback, true);
  assert.equal(row(p).taskCount, 2);
  // 既定文は説明で上書きし、説明は既定文で上書きしない。
  assert.equal(row(t.begin("h", "3 つのファイルを調べる")).labelIsFallback, false);
  assert.equal(row(t.begin("h", "2 件のタスク", { labelIsFallback: true })).label, "3 つのファイルを調べる");
});

test("ACP の title は「<tool>: <中身>」（Hermes / OpenClaw）。名前は先頭の識別子にし、説明からは「<tool>: 」を外す", () => {
  assert.equal(normalizedToolName("delegate_task: 3 tasks: a | b | c"), "delegate_task");
  assert.equal(normalizedToolName("sessions_spawn: task: ビルドして, agentId: coder"), "sessions_spawn");
  assert.equal(normalizedToolName("  read_file: /tmp/x"), "read_file");
  assert.equal(normalizedToolName("mcp.server-tool(x)"), "mcp.server-tool");
  assert.equal(normalizedToolName("delegate_task"), "delegate_task");
  assert.equal(normalizedToolName("調査 する"), "調査");

  // Hermes は delegate_task の rawInput を送らない。title の残りが説明になる。
  const hermes = delegation("delegate_task:", "delegate_task: 3 tasks: a | b | c", undefined);
  assert.equal(hermes?.label, "3 tasks: a | b | c");
  assert.equal(hermes?.labelIsFallback, false);
  const openclaw = delegation("sessions_spawn:", "sessions_spawn: task: ビルドして, agentId: coder", { task: "ビルドして", agentId: "coder" });
  assert.equal(openclaw?.label, "ビルドして");
  assert.equal(openclaw?.agentType, "coder");

  const t = new SubagentTracker();
  const h = t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "h1", title: "delegate_task: 3 tasks: a | b | c", kind: "execute", status: "in_progress" });
  assert.equal(row(h).label, "3 tasks: a | b | c");
  // opencode acp: pending の tool_call は title が task だけで rawInput が空。in_progress の更新で説明が届く。
  const pending = t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "o1", title: "task", kind: "think", rawInput: {}, status: "pending" });
  assert.equal(row(pending).label, "サブエージェント");
  assert.equal(row(pending).labelIsFallback, true);
  const filled = t.ingestAcpUpdate({
    sessionUpdate: "tool_call_update",
    toolCallId: "o1",
    title: "List scratch dir",
    status: "in_progress",
    rawInput: { description: "List scratch dir", prompt: "…", subagent_type: "general" }
  });
  assert.equal(row(filled).label, "List scratch dir");
  assert.equal(row(filled).agentType, "general");
  assert.equal(row(filled).labelIsFallback, false);
  const done = t.ingestAcpUpdate({
    sessionUpdate: "tool_call_update",
    toolCallId: "o1",
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: '<task id="ses_ea64d4d99ffe0NI5OBH0EOs20r" state="completed">\n<task_result>\n2\n</task_result>\n</task>' } }]
  });
  assert.equal(row(done).state, "done");
  assert.equal(row(done).resultPreview, "2");
});

test("parseTaskOutput: OpenCode 1.18 の task の出力（<task id=… state=…>）と、古い形（<task_metadata>）", () => {
  const done = parseTaskOutput('<task id="ses_ea64d4d99ffe0NI5OBH0EOs20r" state="completed">\n<task_result>\n2\n</task_result>\n</task>');
  assert.equal(done.state, "completed");
  assert.equal(done.summary, undefined);
  assert.equal(done.result, "2");
  const background = parseTaskOutput(
    '<task id="ses_C" state="running">\n<summary>Background task started</summary>\n<task_result>\n' + "The task is working in the background.\n</task_result>\n</task>"
  );
  assert.equal(background.state, "running");
  assert.equal(background.summary, "Background task started");
  assert.equal(background.result, "The task is working in the background.");
  const failed = parseTaskOutput('<task id="ses_E" state="error">\n<task_error>\nprovider rejected the request\n</task_error>\n</task>');
  assert.equal(failed.state, "error");
  assert.equal(failed.result, "provider rejected the request");
  assert.equal(finalState(failed.state ?? ""), "failed");
  const legacy = parseTaskOutput("見つかったファイルは 3 つ\n\n<task_metadata>\nsession_id: ses_old\n</task_metadata>");
  assert.equal(legacy.state, undefined);
  assert.equal(legacy.result, "見つかったファイルは 3 つ");
  const plain = parseTaskOutput("ただの返事");
  assert.equal(plain.state, undefined);
  assert.equal(plain.summary, undefined);
  assert.equal(plain.result, undefined);
});

test("ACP: 委任ツールの tool_call で始め、tool_call_update の completed で結果を入れる。普通のツールは行にしない", () => {
  const t = new SubagentTracker();
  const start = t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "c1", title: "delegate_task", rawInput: { goal: "README を要約" }, status: "in_progress" });
  assert.equal(row(start).label, "README を要約");
  const end = t.ingestAcpUpdate({
    sessionUpdate: "tool_call_update",
    toolCallId: "c1",
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: "要約しました" } }]
  });
  assert.equal(row(end).resultPreview, "要約しました");
  assert.equal(t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "c2", title: "read_file" }), undefined);
});

test("Claude 互換の Task tool_use / tool_result。子の行は parent_tool_use_id で引き当てる", () => {
  const t = new SubagentTracker();
  const started = t.ingestToolUseLine(
    obj(`{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"Task","input":{"description":"調査","subagent_type":"general-purpose"}}]}}`)
  );
  assert.equal(row(started[0]).agentType, "general-purpose");
  // 子の行は parent_tool_use_id で引き当てる。
  const child = t.ingestStreamLine(
    obj(`{"type":"assistant","parent_tool_use_id":"tu1","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a.txt"}}]}}`)
  );
  assert.equal(row(child).resultPreview, "Read: /a.txt");
  const ended = t.ingestToolUseLine(obj(`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"終わり"}]}}`));
  assert.equal(row(ended[0]).state, "done");
});

test("begin の startedAt と finish の durationMs は計算した値より優先される", () => {
  const t = new SubagentTracker();
  const started = Date.now() - 60_000;
  const p = JSON.parse(t.begin("x1", "build", { rowKind: "shell", startedAt: started })!);
  assert.equal(p.agents[0].startedAtMs, started);
  const done = JSON.parse(t.finish("x1", "done", "ok", 1234)!);
  assert.equal(done.agents[0].durationMs, 1234);
  // 開き直しでも startedAt を使う（Date も受ける）。
  const again = JSON.parse(t.begin("x1", "build", { rowKind: "shell", startedAt: new Date(started + 1000) })!);
  assert.equal(again.agents[0].startedAtMs, started + 1000);
  // 渡さなければ今まで通り計算する。
  const t2 = new SubagentTracker();
  t2.begin("y1", "a");
  const d2 = JSON.parse(t2.finish("y1", "done")!);
  assert.equal(typeof d2.agents[0].durationMs, "number");
});

test("結果なしで閉じた行・実行中に戻した行は、空の resultPreview / result を送って、アプリが持つ前の値を消させる", () => {
  const t = new SubagentTracker();
  const parse = (p: string | undefined): Array<Record<string, unknown>> => (JSON.parse(p ?? "{}") as { agents: Array<Record<string, unknown>> }).agents;
  t.begin("k1", "作業", { background: true });
  const withPreview = parse(t.activity("k1", "command: npm test"))[0];
  assert.equal(withPreview.resultPreview, "command: npm test");
  const failed = parse(t.abandonRunning({ state: "failed" }))[0];
  assert.equal(failed.state, "failed");
  assert.equal(failed.resultPreview, "", "最後の作業の文を失敗の理由に見せない");
  // 作業の文が一度も無い行は項目を足さない。
  t.begin("k2", "別の作業");
  assert.equal(parse(t.finish("k2", "done"))[0].resultPreview, undefined);
  // 結果つきで終わった行を実行中に戻すと、前の結果も消させる。
  t.begin("k3", "もう一つ");
  t.finish("k3", "done", "1 回目の結果");
  const reopened = parse(t.begin("k3", "もう一つ"))[0];
  assert.equal(reopened.state, "running");
  assert.equal(reopened.resultPreview, "");
  assert.equal(reopened.result, "");
});

test("ACP: opencode の running の task は起動の返事で閉じる（終わりの知らせが転送されないので、実行中のまま残さない）", () => {
  const t = new SubagentTracker();
  t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "b1", title: "task", status: "pending", rawInput: {} });
  t.ingestAcpUpdate({ sessionUpdate: "tool_call_update", toolCallId: "b1", status: "in_progress", title: "Explore", rawInput: { description: "Explore", subagent_type: "explore" } });
  const p = t.ingestAcpUpdate({
    sessionUpdate: "tool_call_update",
    toolCallId: "b1",
    status: "completed",
    content: [{ type: "content", content: { type: "text", text: '<task id="ses_C" state="running">\n<summary>Background task started</summary>\n</task>' } }]
  });
  assert.equal(row(p).state, "done");
  assert.equal(row(p).resultPreview, "Background task started");
  assert.equal(t.hasRunning, false);
});

const agentsOf = (p: string | undefined): Row[] => (JSON.parse(p ?? "{}") as { agents: Row[] }).agents;

test("stoppable: running で手がかりがあり返事待ちでない行だけ true。false も毎回入る", () => {
  const t = new SubagentTracker();
  assert.equal(row(t.begin("k1", "作業")).stoppable, false);
  assert.equal(row(t.setStopHandle("k1", true)).stoppable, true);
  assert.equal(t.setStopHandle("k1", true), undefined, "変わらなければ payload なし");
  assert.equal(t.setStopHandle("nothing", true), undefined);
  assert.equal(row(t.finish("k1", "done")).stoppable, false);
});

test("claudeStopTask: local_agent / local_bash の行だけ手がかりが立つ。monitor_mcp・mcp_task・teammate・hooks の行は立たない", () => {
  const t = new SubagentTracker();
  assert.equal(t.claudeStopTask, false);
  const start = (id: string, taskType: string): Row =>
    row(t.ingestStreamLine({ type: "system", subtype: "task_started", task_id: id, task_type: taskType, description: id, is_backgrounded: true }));
  assert.equal(start("a", "local_agent").stoppable, false, "false の間は立たない");
  start("b", "local_bash");
  start("m", "monitor_mcp");
  start("c", "mcp_task");
  t.noteLaunch("Agent", { description: "hooks の行", subagent_type: "Explore" });
  t.hookStart("h", "Explore");
  const snap = agentsOf(t.setClaudeStopTask(true));
  const by = (id: string): Row => snap.find((r) => r.id === id)!;
  assert.equal(JSON.parse(t.setClaudeStopTask(true) ?? "null"), null, "変わらなければ undefined");
  assert.equal(by("a").stoppable, true);
  assert.equal(by("b").stoppable, true);
  assert.equal(by("m").stoppable, false);
  assert.equal(by("c").stoppable, false);
  assert.equal(by("h").stoppable, false);
  // true の間に始まった行は最初から立つ
  assert.equal(start("d", "local_agent").stoppable, true);
  const listedTeammate = t.ingestStreamLine({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "t", task_type: "in_process_teammate" }] });
  assert.equal(agentsOf(listedTeammate).find((r) => r.id === "t")?.stoppable, false);
  // false に戻すと全行が戻り、workflow_snapshot が返る
  const off = JSON.parse(t.setClaudeStopTask(false)!) as { subtype: string; agents: Row[] };
  assert.equal(off.subtype, "workflow_snapshot");
  assert.ok(off.agents.every((r) => r.stoppable === false));
});

test("claudeStopTask: background_tasks_changed の一覧の task_type でも手がかりが立つ。hooks の Stop の一覧では立たない", () => {
  const t = new SubagentTracker();
  t.setClaudeStopTask(true);
  const p = t.ingestStreamLine({ type: "system", subtype: "background_tasks_changed", tasks: [{ task_id: "x", task_type: "local_bash", command: "sleep 9" }] });
  assert.equal(row(p).stoppable, true);
  const h = t.reconcile([{ id: "y", type: "shell", command: "sleep 8" }]);
  assert.equal(agentsOf(h).find((r) => r.id === "y")?.stoppable, false);
});

test("beginStop: ok / notRunning / unsupported / inFlight。endStop で戻り、restart で返事待ちが消える", () => {
  const t = new SubagentTracker();
  assert.deepEqual(t.beginStop("none"), { kind: "notRunning" });
  t.begin("k", "作業", { background: true });
  assert.deepEqual(t.beginStop("k"), { kind: "unsupported" });
  t.setStopHandle("k", true);
  const ok = t.beginStop("k");
  assert.equal(ok.kind, "ok");
  if (ok.kind !== "ok") return;
  assert.equal(ok.rowKind, "agent");
  assert.equal(row(ok.payload).stoppable, false, "返事待ちの間は false");
  assert.equal(t.isStopRequested("k"), true);
  assert.equal(t.isRunning("k"), true);
  assert.deepEqual(t.beginStop("k"), { kind: "inFlight" });
  assert.equal(row(t.endStop("k")).stoppable, true);
  assert.equal(t.isStopRequested("k"), false);
  assert.equal(t.endStop("k"), undefined);
  // 返事待ちのまま終わっても、新しい実行では消える。stopHandle は持ち越す
  assert.equal(t.beginStop("k").kind, "ok");
  t.finish("k", "stopped");
  assert.deepEqual(t.beginStop("k"), { kind: "notRunning" });
  assert.equal(t.isRunning("k"), false);
  const again = row(t.begin("k", "作業"));
  assert.equal(again.state, "running");
  assert.equal(again.stoppable, true);
  assert.equal(t.isStopRequested("k"), false);
});

test("stopped の行は後から来た failed で変わらない", () => {
  const t = new SubagentTracker();
  t.begin("k", "作業");
  t.finish("k", "stopped");
  assert.equal(t.finish("k", "failed"), undefined);
  assert.equal(row(t.snapshot()).state, "stopped");
});

test("ACP: 状態の無い tool_call_update では行を閉じない（title・rawInput の埋め直しだけ）", () => {
  const t = new SubagentTracker();
  t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "g1", title: "task", rawInput: {} });
  const p = t.ingestAcpUpdate({ sessionUpdate: "tool_call_update", toolCallId: "g1", title: "Explore", rawInput: { description: "調べる", subagent_type: "explore" } });
  assert.equal(row(p).state, "running");
  assert.equal(row(p).label, "調べる");
  assert.equal(t.ingestAcpUpdate({ sessionUpdate: "tool_call_update", toolCallId: "g1" }), undefined);
  assert.equal(t.hasRunning, true);
});

test("ACP: tool_call の background を行に渡せる", () => {
  const t = new SubagentTracker();
  const p = t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "d1", title: "delegate_task: 1 tasks: 調べる", rawInput: { tasks: [{ goal: "調べる" }] } }, { background: true });
  assert.equal(row(p).background, true);
  assert.equal(row(p).stoppable, false, "委任の行に停止は出さない");
  assert.equal(t.runningBackgroundOnlyAgentCount, 1);
});

test("delegation: delegate_task の list / steer / stop は委任にしない。本物の title は作る", () => {
  assert.equal(delegation("delegate_task", undefined, { action: "list" }), undefined);
  assert.equal(delegation("delegate_task", undefined, { action: "steer", id: "x" }), undefined);
  assert.equal(delegation("delegate_task", undefined, { action: "stop" }), undefined);
  assert.equal(delegation("delegate_task: list", "delegate_task: list", undefined), undefined);
  assert.equal(delegation("delegate_task: stop abc", "delegate_task: stop abc", undefined), undefined);
  assert.equal(delegation("delegate_task:steer", "delegate_task:steer", undefined), undefined);
  assert.equal(delegation("delegate_task: stop: x", "delegate_task: stop: x", undefined), undefined);
  assert.ok(delegation("delegate_task: 1 tasks: list files", "delegate_task: 1 tasks: list files", undefined));
  assert.ok(delegation("delegate_task: listing the repo", "delegate_task: listing the repo", undefined), "list の後が空白・「:」・終わりでなければ委任");
  assert.ok(delegation("delegate_task", undefined, { tasks: [{ goal: "a" }], action: "delegate" }));
  const t = new SubagentTracker();
  assert.equal(t.ingestAcpUpdate({ sessionUpdate: "tool_call", toolCallId: "c1", title: "delegate_task: list", rawInput: {} }), undefined);
  assert.equal(t.isEmpty, true);
});

test("abandonRunning(except): 渡した鍵の行は閉じない", () => {
  const t = new SubagentTracker();
  t.begin("a", "A", { background: true });
  t.begin("b", "B", { background: true });
  const p = t.abandonRunning({ state: "failed", except: new Set(["b"]) });
  assert.deepEqual(agentsOf(p).map((r) => [r.id, r.state]), [["a", "failed"]]);
  assert.equal(t.isRunning("b"), true);
});

test("runningBackgroundOnlyAgentCount: running・agent・background == true だけ数える", () => {
  const t = new SubagentTracker();
  t.begin("fg", "前景");
  t.begin("bg1", "背景", { background: true });
  t.begin("bg2", "背景 2", { background: true });
  t.begin("sh", "シェル", { rowKind: "shell", background: true });
  assert.equal(t.runningBackgroundOnlyAgentCount, 2);
  t.finish("bg1", "done");
  assert.equal(t.runningBackgroundOnlyAgentCount, 1);
  assert.equal(t.runningAgentCount, 2);
});
