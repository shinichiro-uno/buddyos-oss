import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

// mac にあって Windows に無かった機能（登録簿・push・ブランチ・画像・スキル・MCP・使用量・Hermes cron・端末画面）。
// 実ホームに触れないよう、ホームを一時ディレクトリに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-parity-"));
const fakeHome = path.join(tmp, "home");
fs.mkdirSync(fakeHome, { recursive: true });
process.env.HOME = fakeHome;
process.env.USERPROFILE = fakeHome;
process.env.PATH = path.join(tmp, "bin");
delete process.env.BUDDYOS_CONVEX_SITE;

const registry = await import("./registry.js");
const registryFiles = await import("./registryFiles.js");
const { parseGitHead, branchFromGitDir } = await import("./gitInfo.js");
const files = await import("./projectFiles.js");
const android = await import("./androidPreview.js");
const { listSkills, saveSkill, projectSkillsRel } = await import("./skills.js");
const { cliMcpAddArgs, listMcp, registerMcp, deleteMcp, mcpRegisterSupported, mcpTokenEnv, mcpTokenEnvVarName } = await import("./mcpService.js");
const { parseGrokBilling } = await import("./usage.js");
const { CronOutputHub } = await import("./cron/outputHub.js");
const { event } = await import("./protocol.js");
const { OFFICIAL_DEFAULTS } = await import("./officialDefaults.js");

after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const write = (p: string, body: string | Buffer): void => {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, body);
};

/* ── 登録簿 ─────────────────────────────────────────────────────────── */

test("登録簿: machineId は mac と同じ式、MachineGuid は reg query の出力から読む", () => {
  const out = "\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\r\n    MachineGuid    REG_SZ    1234abcd-0000-4000-8000-0123456789ab\r\n\r\n";
  assert.equal(registry.parseMachineGuid(out), "1234abcd-0000-4000-8000-0123456789ab");
  assert.equal(registry.parseMachineGuid("nothing"), undefined);
  const id = registry.registryMachineIdFrom("GUID", "me");
  assert.match(id, /^[a-f0-9]{64}$/);
  assert.equal(id, registry.registryMachineIdFrom("GUID", "me"));
  assert.notEqual(id, registry.registryMachineIdFrom("GUID", "other"));
});

test("登録簿: 失効は 403 + error:revoked のときだけ", () => {
  assert.equal(registry.isRevokedResponse(403, '{"error":"revoked"}'), true);
  assert.equal(registry.isRevokedResponse(403, '{"error":"forbidden"}'), false);
  assert.equal(registry.isRevokedResponse(401, '{"error":"revoked"}'), false);
  assert.equal(registry.isRevokedResponse(403, "not json"), false);
});

test("登録簿: registry-status.json は秒で書き、失敗しても前回の成功時刻を残す", () => {
  const dir = path.join(tmp, "status");
  const file = path.join(dir, "registry-status.json");
  write(path.join(dir, "device-token"), "bdt_x");
  registryFiles.recordRegistrySuccess(dir, 1000);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), { lastAttemptAt: 1000, hasDeviceToken: true, lastSuccessAt: 1000, auth: "device" });
  registryFiles.recordRegistryFailure(dir, "HTTP 500", 2000);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), {
    lastAttemptAt: 2000,
    hasDeviceToken: true,
    lastSuccessAt: 1000,
    auth: "device",
    lastError: "HTTP 500"
  });
});

test("登録簿: site は env → ~/.buddyos/account.config.json → 既定値（officialDefaults.ts）→ 無し", () => {
  assert.equal(registry.convexSite({}), OFFICIAL_DEFAULTS.convexSite.replace(/\/$/, ""));
  assert.deepEqual(registry.convexSiteSetting({}, undefined, { ...OFFICIAL_DEFAULTS, convexSite: "" }), { value: "", source: "none" });
  assert.deepEqual(registry.convexSiteSetting({}, undefined, { ...OFFICIAL_DEFAULTS, convexSite: "https://default.convex.site/" }), {
    value: "https://default.convex.site",
    source: "default"
  });
  write(path.join(fakeHome, ".buddyos", "account.config.json"), JSON.stringify({ convexSiteUrl: "https://dev.convex.site/" }));
  assert.equal(registry.convexSite({}), "https://dev.convex.site");
  // account.config.json の値は既定値が空（公開版）でも使う
  assert.deepEqual(registry.convexSiteSetting({}, undefined, { ...OFFICIAL_DEFAULTS, convexSite: "" }), { value: "https://dev.convex.site", source: "account-config" });
  assert.equal(registry.convexSite({ BUDDYOS_CONVEX_SITE: "https://env.convex.site" }), "https://env.convex.site");
  fs.rmSync(path.join(fakeHome, ".buddyos", "account.config.json"));
});

test("登録簿: 端末トークンは設定フォルダの device-token（空・無しは undefined）", () => {
  const dir = path.join(tmp, "cfg-token");
  assert.equal(registry.readDeviceToken(dir), undefined);
  write(path.join(dir, "device-token"), "bdt_abc\n");
  assert.equal(registry.readDeviceToken(dir), "bdt_abc");
});

/* ── push（既定の中継） ─────────────────────────────────────────────── */

test("push: env が無ければ既定の中継を端末トークンで使い、トークンが無い間は送らない", async () => {
  const { PushService } = await import("./pushService.js");
  delete process.env.BUDDYOS_PUSH_RELAY_URL;
  delete process.env.BUDDYOS_PUSH_RELAY_TOKEN;
  let token: string | undefined;
  const push = new PushService(undefined, { url: "https://example.invalid/push", token: () => token });
  assert.equal(push.enabled, true);
  assert.match((await push.sendTest()).error ?? "", /no bridge device token/);
  token = "bdt_x";
  // 端末トークンが入れば、送り先の端末が無いことだけが理由になる
  assert.equal((await push.sendTest()).error, "no device token registered");
});

/* ── git ブランチ ───────────────────────────────────────────────────── */

test("git: HEAD からブランチ名、detached は HEAD、worktree の gitdir ファイルもたどる", () => {
  assert.equal(parseGitHead("ref: refs/heads/feat/x\n"), "feat/x");
  assert.equal(parseGitHead("0123456789abcdef0123456789abcdef01234567\n"), "HEAD");
  assert.equal(parseGitHead("garbage"), undefined);
  const repo = path.join(tmp, "repo");
  write(path.join(repo, ".git", "HEAD"), "ref: refs/heads/main\n");
  fs.mkdirSync(path.join(repo, "src", "deep"), { recursive: true });
  assert.equal(branchFromGitDir(path.join(repo, "src", "deep")), "main");
  const wt = path.join(tmp, "wt");
  write(path.join(tmp, "gitdirs", "wt", "HEAD"), "ref: refs/heads/topic\n");
  write(path.join(wt, ".git"), `gitdir: ${path.join(tmp, "gitdirs", "wt")}\n`);
  assert.equal(branchFromGitDir(wt), "topic");
});

test("git: agent_info_result は branch と cwd が揃ったときだけ載せる（mac と同じキー）", () => {
  assert.deepEqual(event.agentInfoResult("claude", { model: "m" }, { branch: "main", cwd: "C:\\p" }).metadata, { branch: "main", cwd: "C:\\p", model: "m" });
  assert.deepEqual(event.agentInfoResult("claude", { model: "m" }, { branch: undefined, cwd: "C:\\p" }).metadata, { model: "m" });
});

/* ── /files/image ───────────────────────────────────────────────────── */

const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(16)]);

test("画像: cwd とプロジェクトの中だけ返し、外・ホームそのもの・中身が画像でないものは断る", async () => {
  const proj = path.join(tmp, "work", "proj");
  write(path.join(proj, "docs", "shot.png"), PNG);
  write(path.join(proj, "docs", "fake.png"), "not an image");
  write(path.join(tmp, "work", "other", "x.png"), PNG);
  const ok = await files.loadProjectImage("docs/shot.png", proj, [], fakeHome);
  assert.equal(ok.ok && ok.mime, "image/png");
  assert.deepEqual(await files.loadProjectImage("docs/fake.png", proj, [], fakeHome), { ok: false, failure: "not_image" });
  assert.deepEqual(await files.loadProjectImage("docs/none.png", proj, [], fakeHome), { ok: false, failure: "not_found" });
  assert.deepEqual(await files.loadProjectImage("../other/x.png", proj, [], fakeHome), { ok: false, failure: "outside_project" });
  // 登録済みのプロジェクトなら cwd が無くても絶対パスで読める
  const abs = await files.loadProjectImage(path.join(tmp, "work", "other", "x.png"), undefined, [path.join(tmp, "work", "other")], fakeHome);
  assert.equal(abs.ok, true);
  // 相対パスは cwd が無いと解決できない
  assert.deepEqual(await files.loadProjectImage("docs/shot.png", undefined, [proj], fakeHome), { ok: false, failure: "bad_path" });
  // ホームそのものはプロジェクトとして扱わない
  write(path.join(fakeHome, "a.png"), PNG);
  assert.deepEqual(await files.loadProjectImage("a.png", fakeHome, [], fakeHome), { ok: false, failure: "bad_path" });
});

test("画像: 中身の先頭で種類を決める・/mnt/c は C:\\ に直す", () => {
  assert.equal(files.sniffImage(Buffer.from([0xff, 0xd8, 0xff, 0x00]), "jpg"), "image/jpeg");
  assert.equal(files.sniffImage(Buffer.from("GIF89a"), "gif"), "image/gif");
  assert.equal(files.sniffImage(Buffer.from("RIFF0000WEBPVP8 "), "webp"), "image/webp");
  assert.equal(files.sniffImage(Buffer.from("<?xml?><svg></svg>"), "svg"), "image/svg+xml");
  assert.equal(files.sniffImage(Buffer.from("<svg></svg>"), "png"), undefined);
  assert.equal(files.mntPathToWindows("/mnt/c/Users/me/p.png"), "C:\\Users\\me\\p.png");
  assert.equal(files.mntPathToWindows("/home/me"), undefined);
});

/* ── Android の端末画面 ─────────────────────────────────────────────── */

test("Android: adb devices -l・wm size・PNG の大きさ・input text の引数", () => {
  const devices = android.parseAdbDevices(
    "List of devices attached\nemulator-5554          device product:sdk_gphone64 model:sdk_gphone64_x86_64 device:emu64x transport_id:1\nR58M123  unauthorized usb:1-1 transport_id:2\n\n"
  );
  assert.deepEqual(devices, [
    { serial: "emulator-5554", state: "device", model: "sdk gphone64 x86 64" },
    { serial: "R58M123", state: "unauthorized" }
  ]);
  assert.deepEqual(android.parseWmSize("Physical size: 1080x2400\n"), { w: 1080, h: 2400 });
  assert.deepEqual(android.parseWmSize("Physical size: 1080x2400\nOverride size: 720x1600\n"), { w: 720, h: 1600 });
  assert.equal(android.parseWmSize("error"), undefined);
  const png = Buffer.alloc(24);
  png.writeUInt32BE(0x89504e47, 0);
  png.write("IHDR", 12, "latin1");
  png.writeUInt32BE(2400, 16);
  png.writeUInt32BE(1080, 20);
  assert.deepEqual(android.pngSize(png), { w: 2400, h: 1080 });
  assert.equal(android.pngSize(Buffer.from("nope")), undefined);
  assert.equal(android.adbInputTextArg("hello world"), "'hello%sworld'");
  assert.equal(android.adbInputTextArg("it's"), "'it'\\''s'");
});

test("Android: 画面ページは udid を JS 文字列として安全に埋め込む", () => {
  const html = android.androidPageHTML("a'b</script>", 0.5);
  assert.ok(html.includes("const UDID='a\\'b\\u003C/script\\u003E';"));
  assert.ok(html.includes("const AR_FALLBACK=0.5;"));
});

/* ── スキル ─────────────────────────────────────────────────────────── */

test("スキル: Cursor・Grok・Antigravity はそれぞれが読む場所を使う（mac と同じ）", async () => {
  assert.equal(projectSkillsRel("cursor"), ".cursor/skills");
  assert.equal(projectSkillsRel("grok"), ".grok/skills");
  assert.equal(projectSkillsRel("antigravity"), ".agents/skills");
  assert.equal(projectSkillsRel("claude"), ".claude/skills");
  const proj = path.join(tmp, "skills-proj");
  fs.mkdirSync(proj, { recursive: true });
  assert.deepEqual(await saveSkill("antigravity", undefined, proj, "s1", "---\ndescription: d\n---\n"), { ok: true });
  assert.ok(fs.existsSync(path.join(proj, ".agents", "skills", "s1", "SKILL.md")));
  write(path.join(fakeHome, ".grok", "skills", "g1", "SKILL.md"), "---\ndescription: grok skill\n---\n");
  assert.deepEqual(await listSkills("grok", undefined, undefined), [{ name: "g1", description: "grok skill" }]);
});

/* ── MCP ────────────────────────────────────────────────────────────── */

const spec = (over: Record<string, unknown>) => ({ serverName: "gh", transportKind: "url", url: "https://x/mcp", args: [], authType: "none", env: {}, ...over });

test("MCP: Cursor は ~/.cursor/mcp.json に足し・消し、ほかのキーは残す", async () => {
  write(path.join(fakeHome, ".cursor", "mcp.json"), JSON.stringify({ other: 1, mcpServers: { old: { command: "npx", args: ["-y", "o"] } } }));
  assert.equal(mcpRegisterSupported("cursor"), true);
  assert.equal(mcpRegisterSupported("grok"), true);
  assert.equal(mcpRegisterSupported("antigravity"), true);
  assert.equal((await registerMcp("cursor", spec({ env: { Authorization: "Bearer t" } }) as never, "native:cursor")).ok, true);
  const root = JSON.parse(fs.readFileSync(path.join(fakeHome, ".cursor", "mcp.json"), "utf8"));
  assert.equal(root.other, 1);
  assert.deepEqual(root.mcpServers.gh, { url: "https://x/mcp", headers: { Authorization: "Bearer t" } });
  assert.deepEqual((await listMcp("cursor", "native:cursor")).map((s) => s.name), ["gh", "old"]);
  assert.equal((await deleteMcp("cursor", "gh", "native:cursor")).ok, true);
  assert.deepEqual((await listMcp("cursor", "native:cursor")).map((s) => s.name), ["old"]);
});

test("MCP: Antigravity は serverUrl も読み、Grok は ~/.grok/config.toml を読む", async () => {
  write(path.join(fakeHome, ".gemini", "config", "mcp_config.json"), JSON.stringify({ mcpServers: { a: { serverUrl: "https://a" }, off: { url: "https://o", disabled: true } } }));
  assert.deepEqual(await listMcp("antigravity", "native:agy"), [{ name: "a", transport: "https://a" }]);
  write(path.join(fakeHome, ".grok", "config.toml"), '[mcp_servers.g]\ncommand = "npx"\nargs = ["-y", "g"]\n');
  assert.deepEqual(await listMcp("grok", "native:grok"), [{ name: "g", transport: "npx -y g" }]);
});

test("MCP: grok / agy の mcp add はフラグを名前の前、コマンドは -- の後ろ", () => {
  assert.deepEqual(cliMcpAddArgs("n", spec({ env: { B: "2", A: "1" } }) as never), ["mcp", "add", "--header", "A: 1", "--header", "B: 2", "n", "https://x/mcp"]);
  assert.deepEqual(cliMcpAddArgs("n", spec({ transportKind: "command", url: undefined, command: "npx", args: ["-y", "p"], env: { K: "v" } }) as never), [
    "mcp",
    "add",
    "--env",
    "K=v",
    "n",
    "--",
    "npx",
    "-y",
    "p"
  ]);
});

test("MCP: Codex の OAuth は bearer_token_env_var で参照させ、上書きでもツールの承認を残す", async () => {
  const cfg = path.join(fakeHome, ".codex", "config.toml");
  write(cfg, 'model = "x"\n[mcp_servers.gh]\nurl = "https://old"\n[mcp_servers.gh.tools.search]\napproval = "always"\n');
  const r = await registerMcp("codex", spec({ authType: "oauth", env: { Authorization: "Bearer tok1" } }) as never, "native:codex");
  assert.equal(r.ok, true);
  const raw = fs.readFileSync(cfg, "utf8");
  assert.ok(raw.includes('bearer_token_env_var = "BUDDYOS_MCP_GH"'));
  assert.ok(raw.includes("[mcp_servers.gh.tools.search]"));
  assert.ok(!raw.includes("https://old"));
  assert.ok(!raw.includes("tok1"));
  assert.deepEqual(mcpTokenEnv(), { BUDDYOS_MCP_GH: "tok1" });
  assert.equal(mcpTokenEnvVarName("my-server.v2"), "BUDDYOS_MCP_MY_SERVER_V2");
  // 削除はツールの承認もトークンも消す
  assert.equal((await deleteMcp("codex", "gh", "native:codex")).ok, true);
  assert.ok(!fs.readFileSync(cfg, "utf8").includes("mcp_servers.gh"));
  assert.deepEqual(mcpTokenEnv(), {});
});

/* ── 使用量 ─────────────────────────────────────────────────────────── */

test("使用量: Grok の _x.ai/billing を週の枠に入れる", () => {
  assert.deepEqual(
    parseGrokBilling({ config: { creditUsagePercent: 3.4, currentPeriod: { type: "USAGE_PERIOD_TYPE_WEEKLY", end: "2026-10-20T00:00:00Z" } }, subscription_tier: "X Premium" }),
    { provider: "grok", sevenDay: { usedPercent: 3, resetsAt: "2026-10-20T00:00:00Z", windowMinutes: 10_080 }, planType: "X Premium" }
  );
  assert.deepEqual(parseGrokBilling({ config: { creditUsagePercent: 50, billingPeriodEnd: "e" } }), { provider: "grok", sevenDay: { usedPercent: 50, resetsAt: "e" } });
  assert.equal(parseGrokBilling({ config: {} }), undefined);
});

/* ── Hermes の cron ─────────────────────────────────────────────────── */

test("Hermes cron: 足した場所の新しい結果を hermes として配り、足す前からあったものは配らない", () => {
  const root = path.join(tmp, "cron-parity");
  const hermesOut = path.join(root, "hermes", "output");
  write(path.join(hermesOut, "job9", "2020-01-01_00-00-00.md"), "# 古い\n\nold\n");
  const pushes: Record<string, string>[] = [];
  const hub = new CronOutputHub(path.join(root, "bridge"), (_t, _b, data) => pushes.push(data), path.join(root, "seen.json"));
  const got: Array<{ agentId?: string; content?: string }> = [];
  hub.register((e) => got.push(e));
  hub.start();
  hub.stop();
  hub.addRoot(hermesOut, "hermes");
  hub.poll();
  assert.equal(got.length, 0);
  // WSL の時刻帯で名前が古く見えても、更新時刻が新しければ配る
  write(path.join(hermesOut, "job9", "2020-01-02_00-00-00.md"), "# 日報\n\n---\nreport\n");
  hub.poll();
  assert.equal(got.length, 1);
  assert.equal(got[0].agentId, "hermes");
  assert.equal(got[0].content, "report");
  assert.equal(pushes[0].jobId, "job9");
  assert.equal(hub.loadPast("job9").length, 2);
});
