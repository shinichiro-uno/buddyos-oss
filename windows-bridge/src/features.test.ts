import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

// 実ホームに触れないよう、ホームを一時ディレクトリに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-features-"));
const fakeHome = path.join(tmp, "home");
fs.mkdirSync(fakeHome, { recursive: true });
process.env.HOME = fakeHome;
process.env.USERPROFILE = fakeHome;
process.env.PATH = path.join(tmp, "bin");

const { ProjectRegistry, normalizeProjectPath, projectDisplayName } = await import("./projects.js");
const { listSkills, loadSkill, saveSkill, deleteSkill, parseFrontmatterDescription } = await import("./skills.js");
const { parseLoginOutput, stripAnsi } = await import("./agentLogin.js");
const { codexWindows, parseAgyUsage, parseCodexSessionLine, readCodexUsageFromSessions, readClaudeUsage, UsageHub } = await import("./usage.js");
const { fullMcpSpecs, registerMcp } = await import("./mcpService.js");
const { extensionsList, extensionsSync, redactDetail } = await import("./extensionsShare.js");

after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const write = (rel: string, body: string): void => {
  const p = path.join(fakeHome, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, body);
};

test("プロジェクト: 先頭に足し、足し直しは名前だけ変え、並べ替えは知らないパスを無視する", () => {
  const reg = new ProjectRegistry(path.join(tmp, "projects.json"));
  reg.add("C:\\work\\alpha");
  reg.add("/home/u/beta/", "B");
  assert.deepEqual(reg.list().map((p) => p.name), ["B", "alpha"]);
  const addedAt = reg.list()[1].addedAt;
  reg.add("C:\\work\\alpha", "Alpha!");
  assert.equal(reg.list()[1].name, "Alpha!");
  assert.equal(reg.list()[1].addedAt, addedAt);
  reg.reorder(["C:\\work\\alpha", "/nope"]);
  assert.deepEqual(reg.list().map((p) => p.path), ["C:\\work\\alpha", "/home/u/beta"]);
  reg.remove("/home/u/beta/");
  assert.equal(reg.list().length, 1);
  assert.deepEqual(reg.add("   "), reg.list());
  assert.equal(normalizeProjectPath("~/x/../y"), path.posix.join(fakeHome.replace(/\\/g, "/"), "y"));
  assert.equal(projectDisplayName("C:\\work\\alpha"), "alpha");
});

test("スキル: プロジェクトは読み書き、ホームは 2 段まで読むだけ", async () => {
  const cwd = path.join(tmp, "proj");
  fs.mkdirSync(cwd, { recursive: true });
  assert.deepEqual(await saveSkill("claude", "native:claude", cwd, "my-skill", "---\ndescription: \"テスト\"\n---\nbody"), { ok: true });
  assert.deepEqual(await listSkills("claude", "native:claude", cwd), [{ name: "my-skill", description: "テスト" }]);
  assert.match((await loadSkill("claude", "native:claude", cwd, "my-skill")) ?? "", /body/);
  assert.equal((await saveSkill("claude", "native:claude", cwd, "../evil", "x")).ok, false);
  assert.equal((await saveSkill("claude", "native:claude", undefined, "x", "x")).ok, false);
  assert.deepEqual(await deleteSkill("claude", "native:claude", cwd, "my-skill"), { ok: true });
  assert.deepEqual(await listSkills("claude", "native:claude", cwd), []);

  write(".hermes/skills/cat/sub/SKILL.md", "---\ndescription: nested\n---\n");
  write(".hermes/skills/top/SKILL.md", "x");
  assert.deepEqual((await listSkills("hermes", "native:hermes", undefined)).map((s) => s.name), ["cat/sub", "top"]);
  assert.equal(await loadSkill("hermes", "native:hermes", undefined, "cat/sub"), "---\ndescription: nested\n---\n");
  assert.equal(parseFrontmatterDescription("---\r\ndescription: 'crlf'\r\n---\r\n"), "crlf");
});

test("ログイン: ANSI を落として URL と端末コードを拾う", () => {
  const out = "\u001b[1mOpen \u001b]8;;https://x\u0007link\u001b]8;;\u0007\u001b[0m\nhttps://auth.openai.com/codex/device\n  ABCD-12345\n";
  assert.equal(stripAnsi("\u001b[31mred\u001b[0m"), "red");
  assert.deepEqual(parseLoginOutput(out), { url: "https://auth.openai.com/codex/device", code: "ABCD-12345" });
});

test("使用量: Codex の枠の振り分け・記録の読み取り・agy の表", () => {
  assert.deepEqual(codexWindows({ usedPercent: 1, windowMinutes: 10_080 }, { usedPercent: 2, windowMinutes: 300 }), {
    sevenDay: { usedPercent: 1, windowMinutes: 10_080 },
    fiveHour: { usedPercent: 2, windowMinutes: 300 }
  });
  const future = Math.floor(Date.now() / 1000) + 3600;
  const line = JSON.stringify({
    type: "event_msg",
    payload: {
      type: "token_count",
      info: { model_context_window: 1000, last_token_usage: { total_tokens: 250 } },
      rate_limits: { primary: { used_percent: 12.4, window_minutes: 300, resets_at: future }, secondary: { used_percent: 50, window_minutes: 10080, resets_at: 1 }, plan_type: "pro" }
    }
  });
  const parsed = parseCodexSessionLine(line)!;
  assert.equal(parsed.fiveHour?.usedPercent, 12);
  assert.equal(parsed.sevenDay?.usedPercent, 0, "リセット済みの枠は 0");
  assert.equal(parsed.contextPressure, 25);
  assert.equal(parsed.planType, "pro");
  write(".codex/sessions/2026/10/08/rollout.jsonl", `${line}\n`);
  assert.equal(readCodexUsageFromSessions(fakeHome).fiveHour?.usedPercent, 12);
  assert.equal(readCodexUsageFromSessions(path.join(tmp, "none")).error, "Codex sessions directory not found");
  const agy = parseAgyUsage("Gemini Models\tWeekly Limit Remaining\t80%\t2026-10-10T00:00:00Z\nClaude Models\tFive Hour Limit Remaining\t100%\n");
  assert.deepEqual(agy.map((p) => [p.provider, p.sevenDay?.usedPercent ?? p.fiveHour?.usedPercent]), [["antigravity", 20], ["antigravity:claude", 0]]);
  // モデル専用の枠（実機 2026-10-19）は「Gemini」と取り違えず、名前のまま別の枠にする。
  const argon = parseAgyUsage("Gemini 4 Argon\tGemini 4 Argon Weekly Limit\t99%\t2026-10-24T08:29:05Z\n");
  assert.deepEqual(argon.map((p) => [p.provider, p.label, p.sevenDay?.usedPercent]), [["antigravity:gemini-4-argon", "Gemini 4 Argon", 1]]);
});

test("使用量: トークンが無ければ失敗の項目、読み直しに失敗しても 30 分は直前の値を出す", async () => {
  assert.equal((await readClaudeUsage(fakeHome)).error, "Claude OAuth token unavailable");
  let good = true;
  const hub = new UsageHub({ runtimeLabel: () => undefined }, async () => ({
    providers: [good ? { provider: "claude", fiveHour: { usedPercent: 5 } } : { provider: "claude", error: "x" }]
  }));
  const got: string[] = [];
  const off = hub.register((e) => got.push(e.content ?? ""));
  await hub.refresh();
  good = false;
  await hub.refresh();
  hub.stop();
  off();
  assert.ok(got.length >= 2);
  assert.deepEqual(JSON.parse(got.at(-1)!), { providers: [{ provider: "claude", fiveHour: { usedPercent: 5 } }] });
});

test("MCP の全設定（秘密込み）を各エージェントの形式から読む", async () => {
  write(".codex/config.toml", '[mcp_servers.gh]\nurl = "https://x/mcp?token=1"\n[mcp_servers.gh.http_headers]\nAuthorization = "Bearer t"\n[mcp_servers.fs]\ncommand = "npx"\nargs = ["-y", "fs"]\nenv = { KEY = "v" }\n');
  const codex = await fullMcpSpecs("codex", "native:codex");
  assert.deepEqual(codex.find((s) => s.name === "gh")?.env, { Authorization: "Bearer t" });
  assert.deepEqual(codex.find((s) => s.name === "fs"), { name: "fs", kind: "command", command: "npx", args: ["-y", "fs"], env: { KEY: "v" } });
  write(".hermes/config.yaml", "mcp_servers:\n  notes:\n    command: uvx\n    args:\n      - notes-mcp\n    env:\n      TOKEN: abc\nother: 1\n");
  assert.deepEqual(await fullMcpSpecs("hermes", "native:hermes"), [{ name: "notes", kind: "command", command: "uvx", args: ["notes-mcp"], env: { TOKEN: "abc" } }]);
});

test("Hermes にコマンド型のコネクタも書ける（config.yaml に直接追記し、ほかのキーは残す）", async () => {
  write(".hermes/config.yaml", "model: x\nmcp_servers:\n  context7:\n    url: \"https://mcp.context7.com/mcp\"\n    enabled: true\nother: 1\n");
  const spec = { serverName: "filesystem", transportKind: "command", url: null, command: "npx", args: ["-y", "fs-mcp", "/p"], authType: "none", env: { API_KEY: "k" } };
  const r = await registerMcp("hermes", spec as never, "native:hermes");
  assert.equal(r.ok, true, r.message);
  const specs = await fullMcpSpecs("hermes", "native:hermes");
  assert.deepEqual(specs.find((x) => x.name === "filesystem"), { name: "filesystem", kind: "command", command: "npx", args: ["-y", "fs-mcp", "/p"], env: { API_KEY: "k" } });
  const raw = fs.readFileSync(path.join(fakeHome, ".hermes/config.yaml"), "utf8");
  assert.ok(raw.startsWith("model: x\n") && raw.includes("other: 1"));
  assert.equal((await registerMcp("hermes", spec as never, "native:hermes")).ok, false);
});

test("Claude: トークン入りのコネクタは CLI の引数に載せず ~/.claude.json に 0600 で直接書く", async () => {
  write(".claude.json", JSON.stringify({ numStartups: 3, mcpServers: { old: { type: "stdio", command: "x" } } }));
  const spec = { serverName: "gh", transportKind: "url", url: "https://api.example/mcp", command: null, args: [], authType: "oauth", env: { Authorization: "Bearer secret" } };
  const r = await registerMcp("claude", spec as never, "native:claude");
  assert.equal(r.ok, true, r.message);
  const file = path.join(fakeHome, ".claude.json");
  const root = JSON.parse(fs.readFileSync(file, "utf8"));
  assert.equal(root.numStartups, 3);
  assert.deepEqual(root.mcpServers.old, { type: "stdio", command: "x" });
  assert.deepEqual(root.mcpServers.gh, { type: "http", url: "https://api.example/mcp", headers: { Authorization: "Bearer secret" } });
  if (process.platform !== "win32") assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  const cmd = { serverName: "fs", transportKind: "command", url: null, command: "npx", args: ["-y", "fs"], authType: "none", env: { API_KEY: "k" } };
  assert.equal((await registerMcp("claude", cmd as never, "native:claude")).ok, true);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")).mcpServers.fs, { type: "stdio", command: "npx", args: ["-y", "fs"], env: { API_KEY: "k" } });
  assert.equal((await registerMcp("claude", cmd as never, "native:claude")).ok, false, "同名は断る");
  // 壊れた ~/.claude.json は上書きしない
  write(".claude.json", "{ broken");
  assert.equal((await registerMcp("claude", { ...cmd, serverName: "z" } as never, "native:claude")).ok, false);
  assert.equal(fs.readFileSync(file, "utf8"), "{ broken");
  fs.rmSync(file);
});

test("拡張機能の共有: 一覧は秘密を伏せ、スキルは持っていないエージェントへ写す", async () => {
  fs.mkdirSync(path.join(fakeHome, ".claude"), { recursive: true });
  write(".claude/skills/hello/SKILL.md", "---\ndescription: hi\n---\n");
  const labelOf = (id: string) => `native:${id}`;
  const list = JSON.parse(await extensionsList(labelOf));
  assert.deepEqual(list.agents.map((a: { id: string }) => a.id), ["claude", "codex", "hermes"]);
  const gh = list.items.find((i: { name: string }) => i.name === "gh");
  assert.equal(gh.detail, "https://x/mcp?…");
  const r = JSON.parse(await extensionsSync(labelOf, ["skill:hello", "skill:nope", "bad"], ["claude", "hermes"]));
  assert.deepEqual(r, { copied: ["skill:hello → hermes"], failed: ["skill:nope（元が見つかりません）"], skipped: ["skill:hello → claude"] });
  assert.ok(fs.existsSync(path.join(fakeHome, ".hermes/skills/shared/hello/SKILL.md")));
  assert.equal(redactDetail("npx foo"), "npx foo");
});
