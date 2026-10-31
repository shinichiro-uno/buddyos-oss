import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import { fileURLToPath } from "node:url";

// shared/fixtures/codex は mac-bridge と共有する Codex の履歴・config.toml のテストデータ（README.md）。
// 書き込むので一時ディレクトリへ写し、HOME・CODEX の場所・PATH をそこへ向けてから読み込む。
const fixtureDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "shared", "fixtures", "codex");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-codex-fixture-"));
const emptyBin = path.join(tmp, "bin");
fs.mkdirSync(emptyBin, { recursive: true });
process.env.PATH = emptyBin;
delete process.env.CODEX_BIN;
delete process.env.CODEX_HOME;

const { event } = await import("../protocol.js");
const { CodexHistoryAdapter, stripImageTags } = await import("./codexHistory.js");
const { deleteMcp, listMcp, registerMcp } = await import("../mcpService.js");
type McpRegisterSpec = import("../mcpService.js").McpRegisterSpec;

after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

interface Expected {
  listSessions: { events: Array<Record<string, unknown>> };
  listSessionsByCwd: { cwd: string; sessionIds: string[] };
  loadHistory: { sessionId: string; events: Array<Record<string, unknown>> };
  mcpList: { items: Array<{ name: string; transport: string }> };
  mcpRegister: { specs: McpRegisterSpec[]; expectedFile: string };
  mcpDelete: { serverName: string; expectedFile: string };
}

const expected = JSON.parse(fs.readFileSync(path.join(fixtureDir, "expected.json"), "utf8")) as Expected;

/** fixture の home/ を新しい一時 HOME へ写して、そこを HOME / BUDDYOS_CODEX_HOME にする。 */
function freshHome(label: string): string {
  const home = path.join(tmp, label);
  fs.cpSync(path.join(fixtureDir, "home"), home, { recursive: true });
  process.env.HOME = home;
  process.env.USERPROFILE = home;
  process.env.BUDDYOS_CODEX_HOME = path.join(home, ".codex");
  return home;
}

/** expected に書いたキーだけ比べる（metadata は 1 段下まで）。 */
function assertPartial(actual: Record<string, unknown>, want: Record<string, unknown>, label: string): void {
  for (const [key, value] of Object.entries(want)) {
    if (value && typeof value === "object" && !Array.isArray(value)) {
      const inner = actual[key] as Record<string, unknown> | undefined;
      assert.ok(inner, `${label}: ${key} が無い`);
      for (const [k, v] of Object.entries(value)) assert.deepEqual(inner[k], v, `${label}: ${key}.${k}`);
    } else {
      assert.deepEqual(actual[key], value, `${label}: ${key}`);
    }
  }
}

const bySessionId = (a: { sessionId?: string }, b: { sessionId?: string }): number => (a.sessionId ?? "").localeCompare(b.sessionId ?? "");

test("Codex 履歴: 一覧は注入された文脈・サブエージェント・発言の無い会話を除き、題名は session_index → 先頭の発言", async () => {
  freshHome("list");
  const adapter = new CodexHistoryAdapter("codex");
  const events = (await adapter.listSessions(50)).map((s) => event.sessionListItem("codex", s)).sort(bySessionId);
  const want = [...expected.listSessions.events].sort((a, b) => bySessionId(a as { sessionId?: string }, b as { sessionId?: string }));
  assert.deepEqual(events.map((e) => e.sessionId), want.map((e) => e.sessionId));
  events.forEach((e, i) => assertPartial(e as unknown as Record<string, unknown>, want[i], `session_list_item[${i}]`));

  const filtered = await adapter.listSessions(50, expected.listSessionsByCwd.cwd);
  assert.deepEqual(filtered.map((s) => s.sessionId), expected.listSessionsByCwd.sessionIds);
});

test("Codex 履歴: load_history の history_message が期待どおり（重複をまとめ、壊れた行・ツール呼び出しを飛ばす）", async () => {
  freshHome("history");
  const adapter = new CodexHistoryAdapter("codex");
  const { sessionId } = expected.loadHistory;
  const events = (await adapter.loadHistory(sessionId)).map((m) => event.historyMessage("codex", sessionId, m));
  assert.equal(events.length, expected.loadHistory.events.length);
  events.forEach((e, i) => assertPartial(e as unknown as Record<string, unknown>, expected.loadHistory.events[i], `history_message[${i}]`));
});

test("Codex MCP: config.toml の一覧（行末コメント付きのヘッダ・クォート付きの名前・サブテーブル）", async () => {
  freshHome("mcp-list");
  assert.deepEqual(await listMcp("codex"), expected.mcpList.items);
});

test("Codex MCP: 登録は末尾へ足し、既存の行とコメントはそのまま", async () => {
  const home = freshHome("mcp-register");
  for (const spec of expected.mcpRegister.specs) {
    assert.deepEqual(await registerMcp("codex", spec), { ok: true, message: "ok" }, spec.serverName);
  }
  const actual = fs.readFileSync(path.join(home, ".codex", "config.toml"), "utf8");
  assert.equal(actual, fs.readFileSync(path.join(fixtureDir, expected.mcpRegister.expectedFile), "utf8"));
});

test("Codex MCP: 削除は離れた位置のサブテーブルも消し、他のコメントは残す", async () => {
  const home = freshHome("mcp-delete");
  assert.deepEqual(await deleteMcp("codex", expected.mcpDelete.serverName), { ok: true, message: "ok" });
  const actual = fs.readFileSync(path.join(home, ".codex", "config.toml"), "utf8");
  assert.equal(actual, fs.readFileSync(path.join(fixtureDir, expected.mcpDelete.expectedFile), "utf8"));
});

test("画像を挟む <image> の囲みを題名と本文から外す", () => {
  assert.equal(stripImageTags('<image name=[Image #1] path="/Users/me/日常/a.png">\n</image>\nこの絵を描き直して'), "この絵を描き直して");
  assert.equal(stripImageTags('<image name=[Image #1] path="/x.png">\n</image>'), "");
  assert.equal(stripImageTags("<images> の要素を使う"), "<images> の要素を使う");
});
