# Codex の読み書きの共有テストデータ

mac-bridge と windows-bridge は Codex の履歴（`~/.codex/sessions/**/*.jsonl`・`session_index.jsonl`）と `~/.codex/config.toml` の `[mcp_servers.*]` を別々に実装している。
ここにあるファイルを**両方の Bridge のテストが読み**、同じ結果になることを確かめる（`shared/e2e-test-vectors.json` と同じ扱い）。

- 中身は全て合成。実際のユーザーの会話・設定・トークンは入れない。
- `home/` = テスト中の HOME（`CODEX_HOME` / `BUDDYOS_CODEX_HOME` なら `home/.codex`）。書き込むテストは一時ディレクトリへ写してから使う。
- 期待する結果は `expected.json`（イベントは部分一致）と `config.after-*.toml`（完全一致）。
- 形を変えたら両方のテストを通してから直す。片方だけ通らないなら、それは Bridge 間のずれ（`docs/PROTOCOL_DRIFT_2026-10-10.md`）。

| ファイル | 確かめること |
|---|---|
| `home/.codex/sessions/…/*000001.jsonl` | 注入された文脈を飛ばす・同じ発言をまとめる・壊れた行を無視する・`session_index.jsonl` の題名 |
| `…000002.jsonl` | 題名が無いときの先頭 80 文字の要約・cwd での絞り込み |
| `…000003.jsonl` / `…000004.jsonl` | サブエージェントの会話と、発言の無い会話は一覧に出さない |
| `home/.codex/config.toml` | MCP の一覧・登録・削除（コメント・サブテーブル・クォート付きの名前） |

使っているテスト: `windows-bridge/src/agents/codexFixtures.test.ts`。mac は未対応（`mac-bridge/Tests/BridgeAppTests` に足す）。
