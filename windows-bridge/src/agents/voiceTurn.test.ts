import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

// 実ホームの ~/.claude を読まないよう、ホームを一時ディレクトリに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-voice-"));
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;

const { VOICE_DIRECTIVE, VOICE_SPOKEN_MAX, stripVoiceContext, voiceTurnFrom, withVoiceContext } = await import("./voiceTurn.js");
const { ClaudeCodeAdapter } = await import("./claudeCode.js");
const { voiceText } = await import("../server.js");

after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const inbound = (metadata?: Record<string, string>) => ({ type: "user_message" as const, content: "やあ", metadata });

test("音声ターン: voice=1 の印だけを見る。読み上げ済みは末尾 300 文字", () => {
  assert.equal(voiceTurnFrom(undefined), undefined);
  assert.equal(voiceTurnFrom(inbound({ voiceSpoken: "途中" })), undefined);
  assert.deepEqual(voiceTurnFrom(inbound({ voice: "1" })), {});
  assert.deepEqual(voiceTurnFrom(inbound({ voice: "1", voiceSpoken: "  " })), {});
  assert.deepEqual(voiceTurnFrom(inbound({ voice: "1", voiceSpoken: " 途中まで " })), { spoken: "途中まで" });
  const spoken = voiceTurnFrom(inbound({ voice: "1", voiceSpoken: "あ".repeat(400) + "末尾" }))?.spoken ?? "";
  assert.equal(Array.from(spoken).length, VOICE_SPOKEN_MAX);
  assert.ok(spoken.endsWith("末尾"));
});

test("音声ターン: <voice-context> の付け方と剥がし方", () => {
  assert.equal(withVoiceContext("やあ", undefined, true), "やあ");
  assert.equal(withVoiceContext("やあ", {}, false), "やあ", "system prompt で渡せるなら遮られていない限り何も付けない");
  const fallback = withVoiceContext("やあ", {}, true);
  assert.ok(fallback.startsWith(`やあ\n\n<voice-context>\n${VOICE_DIRECTIVE}`));
  assert.ok(fallback.endsWith("</voice-context>"));
  const note = withVoiceContext("じゃあ傘は？", { spoken: "明日は晴れ" }, false);
  assert.ok(note.includes('"明日は晴れ"'));
  assert.ok(!note.includes(VOICE_DIRECTIVE));
  assert.ok(note.startsWith("じゃあ傘は？"));
  const both = withVoiceContext("本文\n二行目", { spoken: "途中" }, true);
  assert.equal(stripVoiceContext(both), "本文\n二行目");
  assert.equal(stripVoiceContext("タグ無し"), "タグ無し");
  assert.equal(stripVoiceContext(both.slice(0, 30)), "本文\n二行目", "一覧タイトルのように閉じタグの前で切れたもの");
  assert.equal(stripVoiceContext("本文 <voice-con..."), "本文", "開きタグの途中で切れたもの");
  assert.equal(stripVoiceContext("本文 <v..."), "本文");
  assert.equal(stripVoiceContext("a <b> と <video> の違い"), "a <b> と <video> の違い");
  assert.equal(stripVoiceContext("<voice-context>\n指示\n</voice-context>\n\n本文"), "本文", "先頭に付けていた頃の形");
});

test("音声ターン: 自分で読めないセッションには本文末尾で渡す", () => {
  assert.equal(voiceText({ handlesVoice: true }, "やあ", inbound({ voice: "1" })), "やあ");
  assert.equal(voiceText({}, "やあ", inbound()), "やあ");
  const sent = voiceText({}, "やあ", inbound({ voice: "1" }));
  assert.ok(sent.startsWith("やあ\n\n<voice-context>"));
  // 一覧のタイトルは本文の先頭 77 文字で切られる。話した言葉が残る。
  const compacted = sent.replace(/\s+/g, " ").trim();
  assert.equal(stripVoiceContext(`${compacted.slice(0, 77)}...`), "やあ");
});

test("音声ターン: Claude Code は音声でも起動引数を変えない（指示は本文の <voice-context>）", async () => {
  const runtime = { kind: "native" as const, executable: "claude", label: "native", shell: false };
  const adapter = new ClaudeCodeAdapter("claude", runtime, {} as never);
  const session = (await adapter.openSession(undefined, tmp)) as unknown as {
    handlesVoice: boolean;
    argsForPrompt(voice?: { spoken?: string }): string[];
  };
  assert.equal(session.handlesVoice, true);
  const normal = session.argsForPrompt();
  assert.ok(!normal.includes("--effort"));
  assert.ok(!normal.includes("--append-system-prompt"));
  assert.deepEqual(session.argsForPrompt({}), normal);
  assert.ok(withVoiceContext("やあ", {}, true).includes(VOICE_DIRECTIVE));
});
