# 背景の作業の制御の実測データ

`docs/BACKGROUND_CONTROL_2026-10-21.md` を決めるときに、実際の CLI を動かして取った記録を、テストが読める形で写したもの。
mac-bridge と windows-bridge のテストが同じファイルを読み、同じ結果になることを確かめる（`shared/fixtures/codex` と同じ扱い）。

- 読み込み: Mac は `#filePath` から、Windows は `import.meta.url` から `shared/fixtures/background-control/` をたどる。
- 全て JSON か JSON Lines（1 ファイル 300 KB まで）。形は元の記録のまま（下の「形」）。
- 秘密とアカウントの情報は消してある（最後の「消したもの」）。形を変えたら、上の 2 つのテストを両方通してから直す。

## 出どころと形

| 場所 | 出どころ（題 / シナリオ名） | 形 |
|---|---|---|
| `claude-stop/` | Claude Code 2.1.300 の `stop_task`（題: claude-stop-task）。`s0-idle-control`（何も動いていないときの制御・不正な引数）・`s1-stop-bg-bash`・`s2-stop-bg-agent`・`s5b-interrupt-with-perTaskStop`・`s6-stop-id-variants`・`s12-idle-interrupt-declared` / `-undeclared`・`s15-stop-parent-with-bg-child`・`s16-stop-agent-with-pending-approval` | `{t, dir: mark\|in\|out, raw}`。`raw` は stream-json の 1 行（文字列）。`mark` は `{t, dir, text, ...}` |
| `workflow-phases/` | Claude Code の workflow の段階の実測（題: workflow-phases）。`W`（宣言した 3 段階）と `X`。`*.workflow-lines.jsonl` = CLI が出した行、`*.payloads.jsonl` = 当時の写像の入出力 | JSON Lines（`{t, cliSubtype, current, proposed, draw}` と CLI の system 行） |
| `codex-stop/` | Codex app-server の停止（題: codex-stop）。`s1a-terminal`・`s1b-two-terminals`・`s2a-subagent-after`・`s2c-child-cleanup`・`s5-child-edges`・`s9-errors`・`s12-parent-double-interrupt` | `{i, t, dir: note\|out\|in, msg}`。`msg` は JSON-RPC |
| `opencode-stop/` | OpenCode 1.18.32 の `serve` の中断（題: opencode-stop）。`e1b-abort-child`・`e3-two-children`・`e6-bg-abort`・`e9b2-edge-B2`・`e11-bg-abort-parent` | `{t, kind: sse\|probe, ...}`。`sse` は `frame.payload` にイベント |
| `opencode-stop/e9b3-edge-B.events.jsonl` | `e9b3-edge-B` は console.log しか残っていないので、承認の reject の順（`permission.asked` → 子の abort → `session.error` / `idle` → `permission.replied reject`）だけを、他と同じ形で組み直した。**id（`evt_e9b3_*`）と `probe` の中身は組み直したもの**。`t` は console の時刻（ms） | 上と同じ |
| `acp-delegation/` | ACP の背景の委任の実測（題: acp-delegation）。`grok-run1`（背景の spawn と起こされたターン）・`grok-run2`（子のセッションの行）・`grok-run3`（前景）・`hermes-run1`・`openclaw-run3` | `{t, rel, dir: send\|recv\|event, msg}`。`msg` は JSON-RPC |
| `acp-delegation/ledgers.json` | 台帳の列と値。`hermes.async_delegations`（running と completed の 2 行）、`openclaw.task_runs`（run3 の子と、その子が起こした exec の 2 行）。テストが一時 SQLite を作る元 | `{hermes\|openclaw: {database, table, columns: [{name, type, notnull, pk}], rows: [{列: 値}]}}` |
| `acp-delegation/hermes-run1.ledger.jsonl` | Hermes の台帳を 1 秒ごとに見た記録（running → completed） | `{t, row}` |
| `claude-bg/` | `claude --bg` の登録簿（題: claude-bg-sessions）。`examples-registry-files.json` = `daemon.json`・roster・sessions・`state.json` の例、`examples-agents-json.json` = `claude agents --json` の例 | JSON |

### acp-delegation の取り方

`raw.jsonl` は、テストが使う行だけに絞ってある。

- 残した: `send` の `initialize` / `session/new` / `session/prompt` / `session/set_config_option` / `session/list`、`stopReason` のある応答、`event`、`_x.ai/session_notification`・`_x.ai/queue/changed`・`_x.ai/session/prompt_complete`、`session/update` の `tool_call`・`tool_call_update`・`agent_message_chunk`・`user_message_chunk`・`session_info_update`・`config_option_update`・`usage_update`。
- `available_commands_update` は、セッションごとに最初の 1 行だけ。`availableCommands` は先頭 3 件に切った。
- 落とした: `agent_thought_chunk`、`_x.ai/mcp/*`・`models`・`settings`・`announcements`・`session/setup`・`sessions/changed`、`initialize` と `session/new` の応答。
- `ledgers.json` の `hermes` の running の行は、completed の行から `completed_at`・`results`・`result_json` を除いて作った（実測の running の `event_json` は残っていない）。

## 消したもの

- Claude の `initialize` の `control_response`（アカウントのメールと pid を含む）の行ごと。`stop_task` などほかの `control_response` は残してある。
- メールアドレスを含む値は `redacted-address` に。
- roster の `rvAuth` / `ptyAuth` の値は `"<redacted>"`、`state.json` の `providerEnv` は `{}`、`respawnFlags` は `[]`。
- `--append-system-prompt` の引数（argv の中）は `"<redacted>"`。
- モデルの `signature`（thinking の署名）は `"<redacted>"`。
- Claude の `commands` / `slash_commands` / `skills` / `plugins`（この Mac に入れているものの一覧）は `[]`。`system/init` の行はすべての行で、`mcp_servers`（つないでいるコネクタと状態）も `[]` にし、`tools` から `mcp__` で始まる名前を除いた。
- Codex の `account/updated` の `planType` は除き、`mcpServer/startupStatus/updated` のサーバー名とエラー文は汎用の値（`server` / `error`）に。Grok の手元の MCP のツール名は除いた。
- OS のユーザー名は `me` に（cwd から作られた名前も同じ）。会話のタイトルと実際のプロジェクト名・パスは、作った値（`orphan job`、`tui-1`、`/tmp/fixture/...`）に。
- 入れていない: `.key` の中身、OpenClaw の `gw.token`、mock の request 本文、`zai-key-check`。
- 元のホームのパスは `/Users/me`、作業用フォルダは `/tmp/fixture`（URL エンコードの `%2F` の形も同じ）に置き換えた。

テスト: `windows-bridge/src/fixturesPrivacy.test.ts` が、メールアドレス・`/Users/me` 以外のホームのパス・値のある `rvAuth` / `ptyAuth`・Bridge の端末トークンの頭・API キーの頭・コネクタ名・`mcp__` のツール名・実行している OS のユーザー名が 0 件、全ファイルが JSON / JSON Lines として読める、各ファイル 300 KB 以下であることを確かめる。
