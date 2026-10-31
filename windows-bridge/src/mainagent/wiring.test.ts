import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";

// mainagent のフォルダで開いたセッションだけに、Bridge の MCP を渡す（mac の testClaudeArgsOnlyForMainagent ほか）。
// 実ホームの設定に触れないよう、HOME を一時フォルダに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-mainagent-wiring-"));
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;

const { ClaudeCodeAdapter } = await import("../agents/claudeCode.js");
const { CodexConfigStore, CodexHistoryAdapter, codexModeValues } = await import("../agents/codexHistory.js");
const { JsonSessionStore } = await import("../sessionStore.js");
const { orchestrator, codexStrength, modeStrength, DEFAULT_CEILING } = await import("./orchestrator.js");
const { READ_ONLY_CONNECTOR_TOOLS, setMainAgentConfigDir, setMainAgentPort, setMainAgentRoot, TOOL_NAMES } = await import("./workspace.js");

const mainRoot = path.join(tmp, "main");
fs.mkdirSync(mainRoot, { recursive: true });
setMainAgentRoot(mainRoot);
setMainAgentConfigDir(path.join(tmp, "config"));
setMainAgentPort(4321);

const store = new JsonSessionStore(path.join(tmp, "store"));
const runtime = { kind: "native" as const, executable: "claude", label: "native:claude", shell: false };

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test("Claude CLI: mainagent のフォルダだけ --mcp-config（ファイル）・道具の許可と禁止・権限モード default。合鍵は引数に載せない", async () => {
  const adapter = new ClaudeCodeAdapter("claude", runtime, store);
  const main = (await adapter.openSession(undefined, mainRoot)) as unknown as { argsForPrompt(): string[]; close(): Promise<void>; mainToken?: string };
  const args = main.argsForPrompt();
  const configPath = args[args.indexOf("--mcp-config") + 1];
  const config = fs.readFileSync(configPath, "utf8");
  assert.ok(config.includes("http://127.0.0.1:4321/mcp"), config);
  assert.ok(config.includes("Bearer ${BUDDYOS_MCP_TOKEN}"), "合鍵は環境変数で渡し、CLI に展開させる");
  const token = main.mainToken!;
  assert.match(token, /^bmt_/);
  assert.ok(!args.join(" ").includes(token) && !config.includes(token), "引数・設定ファイルに合鍵を載せない");
  assert.equal(args[args.indexOf("--permission-mode") + 1], "default");
  assert.equal(args.filter((a) => a === "--permission-mode").length, 1);
  assert.ok(args[args.indexOf("--disallowedTools") + 1].includes("Edit"));
  const allowed = args[args.indexOf("--allowedTools") + 1].split(",");
  assert.equal(allowed.length, TOOL_NAMES.length + READ_ONLY_CONNECTOR_TOOLS.length, "送る・起こす・承認に答えるの確認は Bridge が出すので、Claude 側では道具を全部尋ねさせない");
  assert.ok(allowed.includes("mcp__claude_ai_Gmail__search_threads"), "Gmail / ドライブは読む道具だけ尋ねずに使わせる");
  assert.ok(!allowed.some((t) => /Gmail__(send|trash|create|update|delete|forward|reply)|Drive__(trash|create|update|copy|share)/.test(t)));
  assert.ok(allowed.includes("mcp__buddyos__answer_approval"));
  assert.ok(orchestrator.caller(token), "開いている間は合鍵が使える");
  await main.close();
  assert.equal(orchestrator.caller(token), undefined, "閉じたら合鍵は使えない");

  // ふつうのフォルダ（設定 allSessions が有効）: MCP と道具の許可だけ。書く道具は外さず、権限モードも固定しない。
  orchestrator.setAllSessions(true);
  const normal = (await adapter.openSession(undefined, tmp)) as unknown as { argsForPrompt(): string[]; close(): Promise<void>; mainToken?: string };
  const plain = normal.argsForPrompt();
  assert.ok(plain.includes("--mcp-config"), "ふつうのセッションにも MCP を渡す");
  assert.ok(!plain.includes("--disallowedTools"), "書く道具は外さない");
  assert.equal(plain[plain.indexOf("--allowedTools") + 1].split(",").length, TOOL_NAMES.length, "Gmail / ドライブの読む道具は mainagent だけ");
  assert.ok(!plain.join(" ").includes(normal.mainToken!), "合鍵は引数に載せない");
  assert.equal(orchestrator.depthOfToken(normal.mainToken!), 0, "利用者が開いたセッションは深さ 0");
  await normal.close();

  // 設定を切ると、ふつうのセッションには渡さない（mainagent のフォルダには渡す）。
  orchestrator.setAllSessions(false);
  const off = (await adapter.openSession(undefined, tmp)) as unknown as { argsForPrompt(): string[] };
  assert.ok(!off.argsForPrompt().includes("--mcp-config"));
  const mainOff = (await adapter.openSession(undefined, mainRoot)) as unknown as { argsForPrompt(): string[]; close(): Promise<void> };
  assert.ok(mainOff.argsForPrompt().includes("--mcp-config"));
  await mainOff.close();
  orchestrator.setAllSessions(true);

  const cron = (await adapter.openSession(undefined, mainRoot, { unattended: true, permissionMode: "plan" })) as unknown as { argsForPrompt(): string[] };
  assert.ok(!cron.argsForPrompt().includes("--mcp-config"), "無人実行には渡さない");
});

test("codex の ask（workspace-write ＋ on-request）。config.toml の読み方と、mainagent の子の強さ", () => {
  assert.deepEqual(codexModeValues("ask"), { sandboxMode: "workspace-write", approvalPolicy: "on-request" });
  const config = new CodexConfigStore(async () => path.join(tmp, ".codex"));
  assert.equal(config.currentCodexMode("on-request", "workspace-write"), "ask");
  assert.equal(config.currentCodexMode(undefined, "workspace-write"), "ask", "未設定も Codex の既定は尋ねる");
  assert.equal(config.currentCodexMode("never", "workspace-write"), "auto");
  assert.equal(config.currentCodexMode("never", "read-only"), "plan");
  assert.deepEqual(new CodexHistoryAdapter("codex").modes, ["plan", "ask", "auto", "dangerous"]);
  assert.equal(modeStrength("ask", "codex"), DEFAULT_CEILING);
  assert.equal(codexStrength("workspace-write", "on-request"), modeStrength("ask", "codex"), "名前と実際の設定の強さがそろう");
});
