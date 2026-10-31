import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import type { SessionEvent } from "../protocol.js";
import { JsonSessionStore } from "../sessionStore.js";
import { ANTIGRAVITY_PROFILE, HeadlessCliAdapter, parseAgyModels } from "./headlessCli.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-agy-"));
process.env.HOME = path.join(tmp, "home");
fs.mkdirSync(process.env.HOME, { recursive: true });

test("agy models の表を枠ごとに分ける", () => {
  const catalog = parseAgyModels("gemini-3.1-pro-high\tGemini 3.1 Pro (High)\nclaude-opus\tClaude Opus\ngpt-x\tGPT X\nbad id\tx\n");
  assert.deepEqual(catalog.map((c) => [c.id, c.models.map((m) => m.id)]), [
    ["google", ["gemini-3.1-pro-high"]],
    ["anthropic", ["claude-opus"]],
    ["openai", ["gpt-x"]]
  ]);
});

test("1 ターン: --add-dir で作業フォルダを渡し、step_update の差分を流して会話 id を確定する", { skip: process.platform === "win32" }, async () => {
  const argsLog = path.join(tmp, "args.txt");
  const bin = path.join(tmp, "agy");
  const sid = "33333333-3333-4333-8333-333333333333";
  fs.writeFileSync(
    bin,
    `#!/bin/sh
if [ "$1" = "models" ]; then printf 'gemini-3.1-pro-high\\tGemini\\n'; exit 0; fi
printf '%s\\n' "$@" > '${argsLog}'
echo '{"event":"init","conversation_id":"${sid}","init":{"model":"gemini"}}'
echo '{"event":"step_update","conversation_id":"${sid}","step_update":{"step_type":"agent_response","text_delta":"こん"}}'
echo '{"event":"step_update","conversation_id":"${sid}","step_update":{"step_type":"agent_response","text_delta":"にちは"}}'
echo '{"event":"result","conversation_id":"${sid}","result":{"response":"こんにちは"}}'
`,
    { mode: 0o755 }
  );
  const cwd = path.join(tmp, "work");
  fs.mkdirSync(cwd);
  const adapter = new HeadlessCliAdapter("antigravity", { kind: "native", executable: bin, label: `native:${bin}`, shell: false }, new JsonSessionStore(path.join(tmp, "store")), ANTIGRAVITY_PROFILE);
  const session = await adapter.openSession(undefined, cwd, { permissionMode: "plan" });
  const events: SessionEvent[] = [];
  await session.send("やあ", { type: "user_message", content: "やあ" }, (e) => events.push(e));
  const text = events.filter((e) => e.type === "assistant_delta").map((e) => e.content).join("");
  assert.equal(text, "こんにちは", "result の全文で二重にしない");
  assert.equal(events.find((e) => e.type === "session_started")?.sessionId, sid);
  assert.equal(events.at(-1)?.type, "done");
  const args = fs.readFileSync(argsLog, "utf8").trim().split("\n");
  assert.deepEqual(args.slice(0, 4), ["-p", "やあ", "--output-format", "stream-json"]);
  assert.ok(args.includes("--add-dir") && args[args.indexOf("--add-dir") + 1] === cwd);
  assert.deepEqual(args.slice(-2), ["--mode", "plan"]);
  // 2 ターン目は同じ会話を続ける。
  await session.send("続き", { type: "user_message", content: "続き" }, () => {});
  const args2 = fs.readFileSync(argsLog, "utf8").trim().split("\n");
  assert.equal(args2[args2.indexOf("--conversation") + 1], sid);
  assert.deepEqual((await adapter.listAvailableModels()).map((c) => c.id), ["google"]);
});
