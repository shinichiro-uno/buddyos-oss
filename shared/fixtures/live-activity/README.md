# Live Activity の送り方の共有テストデータ

`docs/BACKGROUND_CONTROL_2026-10-21.md` §8.7。Mac（`LiveActivityRules` / `LiveActivityPublisher`）と Windows（`liveActivity/rules.ts` / `publisher.ts`）が、同じケースで同じ push と同じ状態の列を出すことを確かめる。

| ファイル | 中身 |
|---|---|
| `publisher-cases.json` | 期待値。`{cfg, cases: [{name, T, ids, steps: [{t, op, arg}], expectPushes, expectStates}]}`。**手で直さない**（`simulate.mjs` が書く） |
| `rules.mjs` | §8.7 の規則の参照実装。設計用の作り直し元で、リポジトリのコードではない |
| `simulate.mjs` | `rules.mjs` を 1 秒ずつ進めて `publisher-cases.json` を書き直す。`node simulate.mjs`（置き場所は `import.meta.url` から決まる） |

## 形（§8.7）

- `cfg` = `END_GRACE 20`・`MIN_INTERVAL 10`・`KEEPALIVE 600`・`STALE_AFTER 1500`・`DISMISS_DONE 300`・`DISMISS_FAILED 900`・`ENDED_MEMORY 900`（秒）。
- `op` は `counts`（arg = running）・`finished`（arg = `{done?, failed?, stopped?}`）・`register`（arg = `{device, activityId, batch, shownRunning, shownFailed}`）・`clear`（arg = `{device, activityId}`）。
- テストは 0 秒から `T` 秒まで 1 秒ずつ進め、その秒の `steps` を順に入れてから tick する。batch の id は `ids` を順に使う。
- `expectPushes` の項目は `t, device, activityId, event, priority, state, staleAfterSec | dismissAfterSec`（`keepalive` は比べない）。`expectStates` は `t, batch, phase, running, failed, since`（`rev`・`boot`・`push`・`now` は actor が足すので比べない）。
- ケースは 12 個。規則を変えるときは `rules.mjs` を直して `simulate.mjs` で書き直し、両方の Bridge のテストを通す。
