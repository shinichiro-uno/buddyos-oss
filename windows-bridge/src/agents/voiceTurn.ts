import type { SessionEvent } from "../protocol.js";

/**
 * 音声会話モードから送られたターンの指定（mac の VoiceTurn と同じ）。
 * アプリが user_message の metadata に `voice=1`（と、遮られたときだけ `voiceSpoken`）を載せて送る。
 * 状態はアプリに持たせず、メッセージごとの印で決める（印の無い通常メッセージは通常の設定）。
 */
export interface VoiceTurn {
  /** 直前のアシスタント応答のうち、ユーザーに遮られるまでに読み上げ終えた部分。遮られていなければ undefined。 */
  spoken?: string;
}

/** 読み上げ済み部分として受け付ける最大文字数（アプリは末尾 300 文字を送る）。 */
export const VOICE_SPOKEN_MAX = 300;

/** 音声会話中の応え方。Claude Code では --append-system-prompt に、それ以外は本文末尾の `<voice-context>` に入れる。 */
export const VOICE_DIRECTIVE = [
  "The user is talking to you by voice right now: their messages come from speech recognition and your reply will be read aloud by text-to-speech.",
  "- Reply in the user's language, conversationally, in one to three short sentences. Lead with the answer.",
  "- Do not use Markdown, bullet points, tables, code blocks, URLs, or file paths in what you say. Describe them in plain words instead.",
  "- Speech recognition may mishear words. Infer the most likely intent rather than asking about obvious typos.",
  "- When real work is needed (editing files, running commands), say in one short sentence what you will do, do it, then report the result in one or two sentences.",
  "- If you need to ask something, ask only one question at a time."
].join("\n");

/** metadata から読む。`voice=1` が無ければ undefined（通常ターン）。 */
export function voiceTurnFrom(originalEvent: SessionEvent | undefined): VoiceTurn | undefined {
  const metadata = originalEvent?.metadata;
  if (metadata?.voice !== "1") return undefined;
  const spoken = (metadata.voiceSpoken ?? "").trim();
  return spoken ? { spoken: Array.from(spoken).slice(-VOICE_SPOKEN_MAX).join("") } : {};
}

/** 遮られたときの注記。そのターンのモデル入力にだけ付ける。 */
export function voiceInterruptionNote(voice: VoiceTurn): string | undefined {
  if (!voice.spoken) return undefined;
  return [
    `Your previous reply was interrupted while it was being read aloud. The user only heard it up to: "${voice.spoken}"`,
    "The rest of that reply was not heard. Do not assume the user knows it; repeat anything important only if it is still relevant."
  ].join("\n");
}

/**
 * 本文の末尾に `<voice-context>` を付ける。付けるものが無ければそのまま返す。
 * 末尾に置くのは、一覧のタイトル（本文の先頭数十文字）にユーザーの言葉を残すため。
 * `includeDirective` は system prompt を渡せないエージェント向けのフォールバックで true にする。
 */
export function withVoiceContext(text: string, voice: VoiceTurn | undefined, includeDirective: boolean): string {
  if (!voice) return text;
  const parts = [includeDirective ? VOICE_DIRECTIVE : undefined, voiceInterruptionNote(voice)].filter(
    (part): part is string => Boolean(part)
  );
  if (parts.length === 0) return text;
  return `${text}\n\n<voice-context>\n${parts.join("\n\n")}\n</voice-context>`;
}

/** 履歴・一覧の本文から `<voice-context>` を剥がす（ユーザーには見せない）。 */
export function stripVoiceContext(text: string): string {
  if (!text.includes("<v")) return text;
  return text
    .replace(/\s*<voice-context>[\s\S]*?<\/voice-context>\s*/g, "")
    // 一覧のタイトル（先頭数十文字）で閉じタグまで届かず切れたもの。
    .replace(/\s*<voice-context>[\s\S]*$/, "")
    // 開きタグの途中で切れたもの（「…<voice-con...」）。
    .replace(PARTIAL_OPEN_TAG, "");
}

/** 末尾の `<v` 〜 `<voice-context` と、切ったときに付く「...」。 */
const PARTIAL_OPEN_TAG = /\s*<v(?:o(?:i(?:c(?:e(?:-(?:c(?:o(?:n(?:t(?:e(?:x(?:t>?)?)?)?)?)?)?)?)?)?)?)?)?(?:\.\.\.|…)?$/;
