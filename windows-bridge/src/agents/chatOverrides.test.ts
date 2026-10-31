import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import type { SessionEvent } from "../protocol.js";

// 実ホームの ~/.buddyos・~/.claude を読まないよう、ホームを一時ディレクトリに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-overrides-"));
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;
delete process.env.BUDDYOS_CLAUDE_PERMISSION_MODE;
delete process.env.BUDDYOS_CLAUDE_PERMISSION_PROMPTS;
after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const { parseChatOverrides } = await import("./types.js");
const { ClaudeCodeAdapter } = await import("./claudeCode.js");
const { CURSOR_PROFILE, GROK_PROFILE, HeadlessCliAdapter } = await import("./headlessCli.js");
const { codexChatOverrides } = await import("./codexHistory.js");
const { AcpAdapter, AcpSession, matchConfigOption } = await import("./acpAdapter.js");
const { JsonSessionStore } = await import("../sessionStore.js");

const store = new JsonSessionStore(path.join(tmp, "store"));
const runtime = (executable: string) => ({ kind: "native" as const, executable, label: `native:${executable}`, shell: false });
type ArgsSession = { argsForPrompt(...a: unknown[]): string[]; applyOverrides(o: Record<string, string | undefined>): void };
const flag = (args: string[], name: string): string | undefined => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);

test("chatOverrides=1 の印があるときだけ読む。項目が無ければ既定に戻す", () => {
  assert.equal(parseChatOverrides(undefined), undefined);
  assert.equal(parseChatOverrides({ chatMode: "plan" }), undefined, "印の無い古いクライアントは触らない");
  assert.deepEqual(parseChatOverrides({ chatOverrides: "1" }), { model: undefined, provider: undefined, reasoningEffort: undefined, mode: undefined });
  assert.deepEqual(parseChatOverrides({ chatOverrides: "1", chatModel: " opus ", chatProvider: "anthropic", chatEffort: "high", chatMode: "PLAN" }), {
    model: "opus",
    provider: "anthropic",
    reasoningEffort: "high",
    mode: "plan"
  });
});

test("Claude Code（CLI）: チャットの Plan / モデル / Effort を起動引数に。cron の指定はそれより優先", async () => {
  fs.mkdirSync(path.join(tmp, ".buddyos"), { recursive: true });
  fs.writeFileSync(path.join(tmp, ".buddyos", "claude.mode"), "dangerous");
  const adapter = new ClaudeCodeAdapter("claude", runtime("claude"), store);
  const session = (await adapter.openSession(undefined, tmp)) as unknown as ArgsSession;
  let args = session.argsForPrompt();
  assert.equal(flag(args, "--permission-mode"), "bypassPermissions", "上書きが無ければ全体設定");
  assert.equal(flag(args, "--input-format"), "stream-json");
  assert.equal(flag(args, "--permission-prompt-tool"), "stdio", "承認を iPhone に尋ねる");
  session.applyOverrides({ mode: "plan", model: "claude-opus-x", reasoningEffort: "ultracode" });
  args = session.argsForPrompt();
  assert.equal(flag(args, "--permission-mode"), "plan", "このチャットの Plan が全体設定に勝つ");
  assert.equal(flag(args, "--model"), "claude-opus-x");
  assert.equal(flag(args, "--effort"), "xhigh");
  // 音声のターンでも起動引数は変えない（Effort はユーザーが選んだまま。指示は本文の <voice-context>）
  assert.deepEqual(session.argsForPrompt({}), args);
  // 既定に戻す
  session.applyOverrides({});
  assert.equal(flag(session.argsForPrompt(), "--permission-mode"), "bypassPermissions");
  assert.equal(flag(session.argsForPrompt(), "--effort"), undefined);

  // cron（無人実行）: 指定のモードが勝ち、答える人が居ないので尋ねない
  const cron = (await adapter.openSession(undefined, tmp, { permissionMode: "plan", unattended: true })) as unknown as ArgsSession;
  cron.applyOverrides({ mode: "dangerous" });
  const cronArgs = cron.argsForPrompt();
  assert.equal(flag(cronArgs, "--permission-mode"), "plan");
  assert.ok(!cronArgs.includes("--permission-prompt-tool"));
  fs.rmSync(path.join(tmp, ".buddyos", "claude.mode"));
});

test("headless（cursor / grok）: チャットの上書きを起動引数に", async (t) => {
  // 既定は ACP で動くので、1 ターン 1 プロセスの headless 実行に戻して起動引数を見る。
  process.env.BUDDYOS_CURSOR_HEADLESS = "1";
  process.env.BUDDYOS_GROK_HEADLESS = "1";
  t.after(() => {
    delete process.env.BUDDYOS_CURSOR_HEADLESS;
    delete process.env.BUDDYOS_GROK_HEADLESS;
  });
  const cursor = (await new HeadlessCliAdapter("cursor", runtime("cursor-agent"), store, CURSOR_PROFILE).openSession(undefined, tmp)) as unknown as ArgsSession;
  assert.ok(!cursor.argsForPrompt("x").includes("--mode"));
  cursor.applyOverrides({ mode: "plan", model: "composer-2" });
  const c = cursor.argsForPrompt("x");
  assert.equal(flag(c, "--mode"), "plan");
  assert.equal(flag(c, "--model"), "composer-2");

  const grok = (await new HeadlessCliAdapter("grok", runtime("grok"), store, GROK_PROFILE).openSession(undefined, tmp)) as unknown as ArgsSession;
  grok.applyOverrides({ mode: "plan", reasoningEffort: "low", model: "grok-x" });
  const g = grok.argsForPrompt("x");
  assert.equal(flag(g, "--permission-mode"), "plan");
  assert.equal(flag(g, "--effort"), "low");
  assert.equal(flag(g, "-m"), "grok-x");
  grok.applyOverrides({ reasoningEffort: "bogus" });
  assert.equal(flag(grok.argsForPrompt("x"), "--effort"), undefined, "受け付けない effort は渡さない");

  // cron の指定はチャットの上書きより優先
  const cron = (await new HeadlessCliAdapter("grok", runtime("grok"), store, GROK_PROFILE).openSession(undefined, tmp, { permissionMode: "plan" })) as unknown as ArgsSession;
  cron.applyOverrides({ mode: "dangerous" });
  assert.equal(flag(cron.argsForPrompt("x"), "--permission-mode"), "plan");
});

test("codex exec: チャットのモデル / Effort は -c で渡し、config.toml は書き換えない", () => {
  assert.deepEqual(codexChatOverrides({}), []);
  assert.deepEqual(codexChatOverrides({ model: 'gpt-"x', reasoningEffort: "high" }), ["-c", 'model="gpt-\\"x"', "-c", 'model_reasoning_effort="high"']);
  assert.deepEqual(codexChatOverrides({ reasoningEffort: "ultra" }), [], "受け付けない effort は渡さない");
});

test("ACP: 選択肢の値への合わせ方（完全一致 → 変種 → 表示名）", () => {
  const options = [
    { value: "composer-2.5[fast=true]", name: "Composer 2.5" },
    { value: "build", name: "Build" },
    { value: "plan", name: "Plan" }
  ];
  assert.equal(matchConfigOption("plan", options), "plan");
  assert.equal(matchConfigOption("composer-2.5", options), "composer-2.5[fast=true]");
  assert.equal(matchConfigOption("build", options), "build");
  assert.equal(matchConfigOption("BUILD", options), "build");
  assert.equal(matchConfigOption("auto", options), undefined);
});

/* ── ACP の偽エージェント（node のスクリプト。Windows では実行ビットが無いので飛ばす） ── */

const FAKE_ACP = `#!/usr/bin/env node
const fs = require("node:fs");
const log = process.env.FAKE_ACP_LOG;
const write = (m) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\\n");
let mode = "build";
const config = () => [
  { id: "mode", currentValue: mode, options: [{ value: "build", name: "Build" }, { value: "plan", name: "Plan" }] }
];
let buf = "";
process.stdin.on("data", (c) => {
  buf += c;
  let i;
  while ((i = buf.indexOf("\\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    const m = JSON.parse(line);
    fs.appendFileSync(log, JSON.stringify({ method: m.method, params: m.params }) + "\\n");
    if (m.method === "initialize") write({ id: m.id, result: { protocolVersion: 1 } });
    else if (m.method === "session/new") write({ id: m.id, result: { sessionId: "acp-1", configOptions: config() } });
    else if (m.method === "session/set_config_option") { if (m.params.configId === "mode") mode = m.params.value; write({ id: m.id, result: { configOptions: config() } }); }
    else if (m.method === "session/prompt") {
      const text = m.params.prompt[0].text;
      if (text.includes("hang")) continue; // cancel にも応じない
      write({ method: "session/update", params: { sessionId: "acp-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "mode=" + mode } } } });
      write({ id: m.id, result: { stopReason: "end_turn" } });
    }
  }
});
`;

test("ACP: チャットのモードを session/prompt の前に set_config_option で切り替え、外したら既定に戻す", { skip: process.platform === "win32" }, async () => {
  const bin = path.join(tmp, "fake-acp.cjs");
  fs.writeFileSync(bin, FAKE_ACP, { mode: 0o755 });
  const log = path.join(tmp, "acp-log.jsonl");
  fs.writeFileSync(log, "");
  const adapter = new AcpAdapter("opencode", runtime(bin), store, { args: [], env: { FAKE_ACP_LOG: log } });
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  const emit = (e: SessionEvent): void => {
    events.push(e);
  };
  const text = (): string => events.filter((e) => e.type === "assistant_delta").map((e) => e.content).join("|");
  try {
    session.applyOverrides?.({ mode: "plan" });
    await session.send("1", { type: "user_message", content: "1" }, emit);
    assert.equal(text(), "mode=plan");
    session.applyOverrides?.({});
    await session.send("2", { type: "user_message", content: "2" }, emit);
    assert.equal(text(), "mode=plan|mode=build", "上書きを外したら session 開始時の既定に戻す");
    const methods = fs.readFileSync(log, "utf8").trim().split("\n").map((l) => JSON.parse(l) as { method: string; params: Record<string, unknown> });
    const order = methods.map((m) => (m.method === "session/set_config_option" ? `set:${m.params.value}` : m.method));
    assert.deepEqual(order, ["initialize", "session/new", "set:plan", "session/prompt", "set:build", "session/prompt"]);
  } finally {
    await session.close();
  }
});

test("ACP: session/prompt に時間切れは付けず、止めたのに応じないエージェントは猶予の後に done で畳む", { skip: process.platform === "win32" }, async () => {
  const bin = path.join(tmp, "fake-acp2.cjs");
  fs.writeFileSync(bin, FAKE_ACP, { mode: 0o755 });
  const log = path.join(tmp, "acp-log2.jsonl");
  fs.writeFileSync(log, "");
  const grace = AcpSession.interruptGraceMs;
  const wait = AcpSession.cancelledPromptWaitMs;
  AcpSession.interruptGraceMs = 200;
  AcpSession.cancelledPromptWaitMs = 300;
  const adapter = new AcpAdapter("hermes", runtime(bin), store, { args: [], env: { FAKE_ACP_LOG: log } });
  const session = await adapter.openSession(undefined, tmp);
  const events: SessionEvent[] = [];
  const emit = (e: SessionEvent): void => {
    events.push(e);
  };
  try {
    const turn = session.send("hang", { type: "user_message", content: "hang" }, emit);
    // 走り出すまで待ってから止める
    for (let i = 0; i < 100 && !fs.readFileSync(log, "utf8").includes("session/prompt"); i += 1) await new Promise((r) => setTimeout(r, 20));
    await session.interrupt?.();
    const started = Date.now();
    await turn;
    assert.ok(Date.now() - started < 3000);
    assert.ok(events.some((e) => e.type === "done"), "done で畳む");
    assert.ok(!events.some((e) => e.type === "error"), "止めたターンはエラーにしない");
    assert.match(fs.readFileSync(log, "utf8"), /session\/cancel/);
    // 次のターンは旧ターンの戻りを（上限まで）待ってから送り、普通に答える
    events.length = 0;
    await session.send("next", { type: "user_message", content: "next" }, emit);
    assert.equal(events.filter((e) => e.type === "assistant_delta").map((e) => e.content).join(""), "mode=build");
  } finally {
    AcpSession.interruptGraceMs = grace;
    AcpSession.cancelledPromptWaitMs = wait;
    await session.close();
  }
});
