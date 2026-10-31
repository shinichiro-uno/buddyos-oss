import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { ClaudeProjectsScanner, normalizeCwd, stripPeerFrame, titleCandidate } from "./claudeProjectsScanner.js";
import { scanClaudeSkills } from "./claudeCode.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-claude-scan-"));
const projects = path.join(tmp, ".claude", "projects");
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";

function writeSession(dir: string, id: string, lines: unknown[], mtime: Date): void {
  const file = path.join(projects, dir, `${id}.jsonl`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  fs.utimesSync(file, mtime, mtime);
}

writeSession("C--work-app", A, [
  { type: "user", cwd: "C:\\work\\app", message: { role: "user", content: "<system-reminder>x</system-reminder>バグを直して" }, uuid: "u1" },
  { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "直しました" }, { type: "tool_use", name: "Edit" }] }, uuid: "a1" },
  { type: "user", isMeta: true, message: { role: "user", content: "meta" } },
  { type: "ai-title", aiTitle: "バグ修正" }
], new Date(2026, 9, 8, 10));
writeSession("home-u-other", B, [
  { type: "user", cwd: "/home/u/other", message: { role: "user", content: "<command-name>/review</command-name>" }, uuid: "u2" },
  { type: "custom-title", customTitle: "名前付き" }
], new Date(2026, 9, 8, 9));
fs.writeFileSync(path.join(projects, "C--work-app", "not-a-uuid.jsonl"), "{}\n");

test("会話記録を新しい順に並べ、タイトルは custom > ai > 最初の発言", async () => {
  const scanner = new ClaudeProjectsScanner(async () => projects);
  const all = await scanner.listSessions(10);
  assert.deepEqual(all.map((s) => [s.sessionId, s.title, s.cwd]), [
    [A, "バグ修正", "C:\\work\\app"],
    [B, "名前付き", "/home/u/other"]
  ]);
});

test("cwd の絞り込みは大文字小文字・区切り・末尾を揃えて比べる", async () => {
  const scanner = new ClaudeProjectsScanner(async () => projects);
  assert.deepEqual((await scanner.listSessions(10, "c:/WORK/app/")).map((s) => s.sessionId), [A]);
  assert.deepEqual((await scanner.listSessions(10, "/home/u/other/")).map((s) => s.sessionId), [B]);
  assert.equal(normalizeCwd("C:\\a\\"), "c:\\a");
});

test("履歴は user / assistant の本文だけ（meta と包みは除く）", async () => {
  const scanner = new ClaudeProjectsScanner(async () => projects);
  const history = await scanner.loadHistory(A);
  assert.deepEqual(history.map((h) => [h.role, h.content, h.messageId]), [
    ["user", "バグを直して", "u1"],
    ["assistant", "直しました", "a1"]
  ]);
  assert.deepEqual(await scanner.loadHistory("nope"), []);
  assert.equal(titleCandidate("<command-name>/x</command-name> rest"), "/x");
});

test("ユーザーとプラグインのスキルを / の候補にする", () => {
  const home = path.join(tmp, "h");
  const skill = path.join(home, ".claude", "skills", "mine");
  fs.mkdirSync(skill, { recursive: true });
  fs.writeFileSync(path.join(skill, "SKILL.md"), "---\ndescription: 'my skill'\n---\n");
  const install = path.join(tmp, "plug", "1.0.0");
  fs.mkdirSync(path.join(install, "skills", "p1"), { recursive: true });
  fs.writeFileSync(path.join(install, "skills", "p1", "SKILL.md"), "x");
  fs.mkdirSync(path.join(home, ".claude", "plugins"), { recursive: true });
  fs.writeFileSync(
    path.join(home, ".claude", "plugins", "installed_plugins.json"),
    JSON.stringify({ plugins: { "tool@market": [{ scope: "user", installPath: install }] } })
  );
  assert.deepEqual(scanClaudeSkills(home).map((s) => [s.id, s.subtitle]), [["mine", "my skill"], ["tool:p1", undefined]]);
});

const PEER = "55555555-5555-4555-8555-555555555555";
const FRAME_HEAD = "Another Claude session sent a message:";
const FRAME_TAIL = "\n\nThis came from another Claude session via cross-session messaging.";

test("peer の枠: 1 行目と最後の「This came from another Claude session」から後ろを落とす。無ければ 1 行目だけ", () => {
  assert.equal(stripPeerFrame(`${FRAME_HEAD}\nこんにちは${FRAME_TAIL}`), "こんにちは");
  assert.equal(stripPeerFrame(`${FRAME_HEAD}\n一行目\n\n二行目${FRAME_TAIL}`), "一行目\n\n二行目");
  assert.equal(stripPeerFrame(`${FRAME_HEAD}\n枠の後ろが無い`), "枠の後ろが無い");
  assert.equal(stripPeerFrame(FRAME_HEAD), "");
});

test("履歴: origin.kind が peer の user 行は枠を外し、読み終えた位置を最後の改行までで返す", async () => {
  writeSession("C--peer", PEER, [
    { type: "user", cwd: "C:\\peer", message: { role: "user", content: `${FRAME_HEAD}\n受け箱から${FRAME_TAIL}` }, origin: { kind: "peer" }, uuid: "p1" },
    { type: "user", message: { role: "user", content: `${FRAME_HEAD}\nそのまま` }, uuid: "p2" },
    { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "はい" }] }, uuid: "p3" }
  ], new Date(2026, 9, 8, 8));
  const file = path.join(projects, "C--peer", `${PEER}.jsonl`);
  const scanner = new ClaudeProjectsScanner(async () => projects);
  const read = await scanner.loadHistoryRead(PEER);
  assert.deepEqual(read.messages.map((m) => m.content), ["受け箱から", `${FRAME_HEAD}\nそのまま`, "はい"], "peer 以外の行は触らない");
  assert.equal(read.end, fs.statSync(file).size);
  assert.equal(read.file, file);
  // 書きかけの最後の行（改行が無い）は読み終えた位置に含めない。
  const size = fs.statSync(file).size;
  fs.appendFileSync(file, '{"type":"assistant","message":{"role":"assistant","content":[{"type":"te');
  assert.equal((await scanner.loadHistoryRead(PEER)).end, size);
  assert.deepEqual((await scanner.loadHistory(PEER)).map((m) => m.content), ["受け箱から", `${FRAME_HEAD}\nそのまま`, "はい"]);
});

test("履歴: 1 MiB の chunk の境目をまたぐ多バイト文字は壊れず、読み終えた位置はファイルの大きさと一致する", async () => {
  const C = "33333333-3333-4333-8333-333333333333";
  const file = path.join(projects, "big", `${C}.jsonl`);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const rows: string[] = [];
  let size = 0;
  // 3 バイトの文字を並べた行を、境目（1 MiB）が文字の途中に来るまで足す。
  let n = 0;
  while (size < 1024 * 1024 + 5000) {
    const row = JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "あ".repeat(100 + (n % 7)) }] }, uuid: `a${n++}` }) + "\n";
    rows.push(row);
    size += Buffer.byteLength(row);
  }
  fs.writeFileSync(file, rows.join(""));
  const scanner = new ClaudeProjectsScanner(async () => projects);
  const read = await scanner.loadHistoryRead(C);
  assert.equal(read.end, fs.statSync(file).size);
  assert.equal(read.messages.length, rows.length);
  assert.ok(read.messages.every((m) => !m.content.includes("�")));
});
