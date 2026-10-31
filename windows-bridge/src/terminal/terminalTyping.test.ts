import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";
import { metadataText } from "../agents/types.js";
import type { SessionEvent } from "../protocol.js";
import { ClaudeChannelInbox } from "./channelInbox.js";
import { ClaudeTerminalRegistry, ClaudeTerminalSession, isTypedByUser, markTypedByUser, slashCommand, type TerminalDeps } from "./claudeTerminal.js";
import { parsePanes, PASTE_END, PASTE_START, RELAY_MAX_KEYS, TYPING_CHUNK, TYPING_GAP_MS, TerminalKeyRouter, typingKeys } from "./keys.js";
import { TerminalPaneStatus } from "./paneStatus.js";
import { handleTerminalRoute, type TerminalServices } from "./routes.js";

/// 人が打った発話を、デスクトップのアプリ内ターミナルの claude に打ち込む流れ（mac の TerminalTypingTests と同じ場面）。実 claude は使わない。
/// デスクトップの pty は pid を名乗るだけ、claude の pid はこのテストのプロセス（生きている pid）で代える。
/// 打てるのは sessions/<pid>.json でその session の status が idle（か shell）と確かめられたときだけなので、
/// 既定ではそのファイル（idle）を置く。別の状態は writeStatus か readStatus（差し替え）で作る。

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-typing-"));
after(() => {
  try {
    fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  } catch {
    /* 掃除できなくても落とさない */
  }
});

const SID = "88888888-8888-4888-8888-888888888888";
/** デスクトップのアプリ内ターミナル（pty）の pid。名乗るだけなので実在しなくてよい。 */
const PTY = 100;
/** 打ち込み先の claude の pid。生きている必要があるので、このテストのプロセスを使う。 */
const CLAUDE = process.pid;
const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

type Timing = Pick<TerminalDeps, "typingBusyWaitMs" | "typingPollMs" | "typedDeliveryMs" | "typedCommandMs" | "typedKeyMs" | "readStatus">;

/** status: sessions/<pid>.json に置く状態（既定は idle。null なら置かない）。 */
function setup(timing: Timing = {}, parents = new Map([[CLAUDE, PTY]]), status: string | null = "idle") {
  // Claude Code のホーム（~/.claude/sessions/<pid>.json を置く）はテストごとに分ける。
  const home = fs.mkdtempSync(path.join(tmp, "home-"));
  if (status !== null) writeStatus(home, status);
  const published: SessionEvent[] = [];
  const inbox = new ClaudeChannelInbox();
  const keys = new TerminalKeyRouter(async () => parents);
  const panes = new TerminalPaneStatus();
  const registry = new ClaudeTerminalRegistry({
    publish: (e) => published.push(e),
    push: () => {},
    watchers: () => 1,
    inbox,
    keys,
    panes,
    bridgeId: "b1",
    persistFile: path.join(home, "ledger.json"),
    claudeHome: home,
    typingPollMs: 10,
    // 操作 1 つごとに足す待ち時間は、試験では 0（足す試験だけが指定する）。
    typedKeyMs: 0,
    ...timing
  });
  return { home, published, inbox, keys, panes, registry };
}

/** Claude Code が書く sessions/<pid>.json（status は idle / busy / waiting / shell）。 */
function writeStatus(home: string, status: string, sessionId = SID, pid = CLAUDE): void {
  const dir = path.join(home, ".claude", "sessions");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `${pid}.json`), JSON.stringify({ pid, sessionId, status, startedAt: 1 }));
}

const hook = (name: string, extra: Record<string, unknown> = {}): Record<string, unknown> => ({ session_id: SID, hook_event_name: name, ...extra });

async function until(pred: () => boolean | Promise<boolean>, what: string, ms = 3000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!(await pred())) {
    if (Date.now() > deadline) throw new Error(`timed out: ${what}`);
    await sleep(5);
  }
}

/* ── キーの列 ─────────────────────────────────────────────────────────── */

test("打ち込みのキー: 貼り付けで入れてから Enter。改行を含む文も 1 つの貼り付け", () => {
  assert.deepEqual(typingKeys("こんにちは\n二行目"), [`${PASTE_START}こんにちは\n二行目${PASTE_END}`, "\r"]);
});

test("打ち込みのキー: 制御文字は落とす。ESC で貼り付けを閉じて続きをキー操作として打たせない・\\r は Enter になるので \\n にそろえる", () => {
  const keys = typingKeys("a\u001b[201~\rrm -rf ~\r\nb\u0007\u009bc\td\u007f");
  assert.deepEqual(keys, [`${PASTE_START}a[201~\nrm -rf ~\nbc\td${PASTE_END}`, "\r"]);
  const body = keys![0].slice(PASTE_START.length, -PASTE_END.length);
  assert.ok(!body.includes("\u001b"));
  assert.ok(!body.includes("\r"));
});

test("打ち込みのキー: 先頭が ! だとシェルのコマンドとして実行されるので、空白を 1 つ付けて普通の発話にする", () => {
  assert.equal(typingKeys("!git status")?.[0], `${PASTE_START} !git status${PASTE_END}`);
  assert.equal(typingKeys("見て !important")?.[0], `${PASTE_START}見て !important${PASTE_END}`);
});

test("打ち込みのキー: 空・空白だけ・制御文字だけは null", () => {
  assert.equal(typingKeys(""), null);
  assert.equal(typingKeys(" \n\t "), null);
  assert.equal(typingKeys("\u001b\u0007"), null);
});

test("打ち込みのキー: 長い文は 1 つの貼り付けのまま途中で分ける。絵文字（サロゲート）の途中では分けない", () => {
  const text = "a".repeat(7995) + "😀".repeat(10) + "あ".repeat(9000);
  const keys = typingKeys(text)!;
  assert.ok(keys.length >= 3);
  assert.equal(keys.at(-1), "\r");
  const chunks = keys.slice(0, -1);
  assert.ok(chunks.every((c) => c.length <= TYPING_CHUNK));
  assert.equal(chunks.join(""), PASTE_START + text + PASTE_END);
  assert.ok(chunks[0].startsWith(PASTE_START));
  assert.ok(chunks.at(-1)!.endsWith(PASTE_END));
  assert.equal(chunks.filter((c) => c.includes(PASTE_START)).length, 1, "貼り付けの始まりは 1 つだけ");
  assert.equal(chunks.filter((c) => c.includes(PASTE_END)).length, 1, "貼り付けの終わりは 1 つだけ");
});

test("打ち込みのキー: 絵文字が分け目にかかっても、どの操作も片方だけのサロゲートを持たない", () => {
  // 先頭の ESC [200~ が 6 文字なので、a の数で分け目が絵文字の前後に動く（7993 = 絵文字が次の操作に回る・7992 = ちょうど収まる）。
  for (let a = 7988; a <= 7998; a += 1) {
    const text = "a".repeat(a) + "😀".repeat(4) + "あ".repeat(20);
    const chunks = typingKeys(text)!.slice(0, -1);
    assert.equal(chunks.join(""), PASTE_START + text + PASTE_END, `a=${a}`);
    for (const c of chunks) {
      assert.ok(c.length <= TYPING_CHUNK, `a=${a}`);
      assert.equal(Buffer.from(c, "utf8").toString("utf8"), c, `a=${a}: 片方だけのサロゲートがある`);
    }
  }
  assert.equal(typingKeys("a".repeat(7993) + "😀")![0].length, 7999, "絵文字は次の操作へ回す");
  assert.equal(typingKeys("a".repeat(7992) + "😀")![0].length, 8000, "ちょうど収まるなら同じ操作に入れる");
});

test("打ち込みのキー: デスクトップが 1 回で受け付ける数（Enter を含めて 32）を超えるなら null", () => {
  assert.equal(typingKeys("x".repeat(TYPING_CHUNK * RELAY_MAX_KEYS)), null);
  // 31 個の貼り付けの操作 + Enter でちょうど 32。1 文字増えると最後の貼り付けの終わりが次の操作に回り、33 になる。
  assert.equal(typingKeys("x".repeat(247_988))?.length, RELAY_MAX_KEYS);
  assert.equal(typingKeys("x".repeat(247_989)), null);
});

test("slashCommand: 先頭がコマンド名ならその名前。パスや文中のコマンドは普通の発話", () => {
  assert.equal(slashCommand("/compact"), "/compact");
  assert.equal(slashCommand("  /model sonnet"), "/model");
  assert.equal(slashCommand("/plugin:cmd 引数"), "/plugin:cmd");
  assert.equal(slashCommand("/Users/me/bar を見て"), null);
  assert.equal(slashCommand("見て /compact"), null);
  assert.equal(slashCommand(""), null);
});

/* ── 宛先 ─────────────────────────────────────────────────────────────── */

test("宛先: 打ち込みは typing=1 のデスクトップが持つ pty にだけ。古いデスクトップには選択肢の答えだけ", async () => {
  // claude(300) → shell(200) → pty(100)
  const keys = new TerminalKeyRouter(async () => new Map([[300, 200], [200, 100]]));
  void keys.poll("desktop", [100], 20, parsePanes("pane-1:100"));
  assert.equal(await keys.ptyOwner(300), 100, "選択肢の答えは送れる");
  assert.equal(await keys.typingOwner(300), undefined, "古いデスクトップには打ち込まない");
  assert.equal(keys.ptyForPane("pane-1"), 100);
  assert.equal(keys.typingPtyForPane("pane-1"), undefined);

  // 同じデスクトップが typing=1 で名乗り直せば打ち込める。
  void keys.poll("desktop", [100], 20, parsePanes("pane-1:100"), true);
  assert.equal(await keys.typingOwner(300), 100);
  assert.equal(keys.typingPtyForPane("pane-1"), 100);
  assert.equal(await keys.ptyOwner(300), 100);

  // 古いデスクトップに名乗り直せば、また打ち込めなくなる（毎回の poll で決まる）。
  void keys.poll("desktop", [100], 20, parsePanes("pane-1:100"));
  assert.equal(await keys.typingOwner(300), undefined);

  // 別のデスクトップが打ち込めても、持っている pty が違えば宛先にならない。
  void keys.poll("other", [999], 20, undefined, true);
  assert.equal(await keys.typingOwner(300), undefined);
  assert.equal(await keys.ptyOwner(300), 100);
  assert.equal(await keys.typingOwner(undefined), undefined);
  assert.equal(keys.typingPtyForPane(undefined), undefined);
});

test("ルート: /terminal/keys/poll は typing=1 を読み、打ち込みの item にだけ expectPid と expectSession を付ける", async () => {
  const { registry, inbox, keys, panes } = setup();
  const services: TerminalServices = { registry, inbox, keys, panes, handOver: () => false };
  const server = http.createServer((req, res) => {
    void handleTerminalRoute(req, res, new URL(req.url ?? "/", "http://localhost"), services);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
  const poll = async (query: string): Promise<unknown> => (await fetch(`${base}/terminal/keys/poll?${query}`)).json();
  try {
    registry.register(SID, undefined, CLAUDE);
    // typing=1 を名乗らないデスクトップには打ち込まない。選択肢への答えは今までの形のまま（expectPid・expectSession が付かない）。
    const old = poll(`client=desktop&pids=${PTY}`);
    await until(async () => (await keys.ptyOwner(CLAUDE)) === PTY, "古いデスクトップが pty を名乗る");
    assert.equal(await registry.typePrompt(SID, "こんにちは", "こんにちは"), "unavailable");
    keys.enqueue({ pid: PTY, keys: ["1"], gapMs: 800 });
    assert.deepEqual(await old, { items: [{ pid: PTY, keys: ["1"], gapMs: 800 }] });
    // 同じデスクトップが typing=1 を名乗れば打ち込める。打ち込みの item には宛先の claude の pid と session id が付く。
    const modern = poll(`client=desktop&pids=${PTY}&typing=1`);
    await until(async () => (await keys.typingOwner(CLAUDE)) === PTY, "デスクトップが typing=1 を名乗る");
    assert.equal(await registry.typePrompt(SID, "こんにちは", "こんにちは"), "typed");
    assert.deepEqual(await modern, {
      items: [{ pid: PTY, keys: [`${PASTE_START}こんにちは${PASTE_END}`, "\r"], gapMs: TYPING_GAP_MS, expectPid: CLAUDE, expectSession: SID }]
    });
    // expectSession だけが無い配達（古い Bridge の形）は、expectPid だけを付ける。
    const partial = poll(`client=desktop&pids=${PTY}&typing=1`);
    await until(async () => (await keys.typingOwner(CLAUDE)) === PTY, "デスクトップが typing=1 を名乗り直す");
    keys.enqueue({ pid: PTY, keys: ["x"], gapMs: 500, expectPid: CLAUDE });
    assert.deepEqual(await partial, { items: [{ pid: PTY, keys: ["x"], gapMs: 500, expectPid: CLAUDE }] });
  } finally {
    server.closeAllConnections();
    server.close();
    registry.unregister(SID);
  }
});

/* ── 打ち込み（registry） ─────────────────────────────────────────────── */

test("typePrompt: 打ち込む。宛先の pty と expectPid・expectSession が付き、戻ってきた発話は二重に出さず、時間切れのエラーも出さない", async () => {
  const { registry, keys, published } = setup({ typedDeliveryMs: 100 });
  registry.register(SID, "C:\\w", CLAUDE);
  const desktop = keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await registry.typePrompt(SID, "テストを実行して", "テストを実行して"), "typed");
  assert.deepEqual(await desktop, [{ pid: PTY, keys: typingKeys("テストを実行して"), gapMs: TYPING_GAP_MS, expectPid: CLAUDE, expectSession: SID }]);

  // ターミナルに届いた（UserPromptSubmit）。画面に出している発話なので、もう一度吹き出しにしない。
  registry.ingest(hook("UserPromptSubmit", { prompt: "テストを実行して" }));
  registry.ingest(hook("Stop"));
  await sleep(250);
  assert.deepEqual(published.map((e) => e.type), ["done"]);
  registry.unregister(SID);
});

test("typePrompt: ペインを名乗っていれば親をたどらずにそのペインの pty に打つ", async () => {
  const { registry, keys } = setup({}, new Map());
  registry.register(SID, undefined, CLAUDE, undefined, undefined, "pane-t");
  const desktop = keys.poll("desktop", [PTY], 2000, parsePanes(`pane-t:${PTY}`), true);
  assert.equal(await registry.typePrompt(SID, "続けて", "続けて"), "typed");
  assert.deepEqual((await desktop).map((d) => [d.pid, d.expectPid, d.expectSession]), [[PTY, CLAUDE, SID]]);
  registry.unregister(SID);
});

test("typePrompt: 打ち込めなければ unavailable（古いデスクトップ・アプリ内ターミナルの外・空の文・pid の分からない会話・台帳に無い会話）", async () => {
  // typing=1 を名乗らない古いデスクトップ。
  const old = setup();
  old.registry.register(SID, undefined, CLAUDE);
  const oldPoll = old.keys.poll("desktop", [PTY], 80);
  assert.equal(await old.registry.typePrompt(SID, "こんにちは", "こんにちは"), "unavailable");
  assert.deepEqual(await oldPoll, [], "何も積まない");

  // 打ち込めるデスクトップはあるが、その claude はアプリ内ターミナルの外で動いている。
  const outside = setup();
  outside.registry.register(SID, undefined, CLAUDE);
  const outsidePoll = outside.keys.poll("desktop", [999], 80, undefined, true);
  assert.equal(await outside.registry.typePrompt(SID, "こんにちは", "こんにちは"), "unavailable");
  assert.deepEqual(await outsidePoll, []);

  // 空の文・制御文字だけの文は打つものが無い。
  const t = setup();
  t.registry.register(SID, undefined, CLAUDE);
  const poll = t.keys.poll("desktop", [PTY], 80, undefined, true);
  assert.equal(await t.registry.typePrompt(SID, " \n\u0007", "x"), "unavailable");
  // pid が分からない会話は、宛先の claude を確かめられない。台帳に無い会話にも打てない。
  // （sessions のファイルがあると、そこから pid が見つかってしまうので置かない。）
  const noPid = setup({}, undefined, null);
  noPid.registry.register(SID);
  noPid.keys.poll("desktop", [PTY], 80, undefined, true);
  assert.equal(await noPid.registry.typePrompt(SID, "こんにちは", "こんにちは"), "unavailable");
  assert.equal(await noPid.registry.typePrompt("unknown", "こんにちは", "こんにちは"), "unavailable");
  assert.deepEqual(await poll, []);
});

test("typePrompt: ターミナルに選択肢が出ている間は打たない（hook のカードも、Claude Code の status が waiting のときも）", async () => {
  // status は idle（この session のファイルがある）。台帳に答えられていない選択肢があれば、打たない。
  const card = setup();
  card.registry.register(SID, undefined, CLAUDE);
  const poll = card.keys.poll("desktop", [PTY], 100, undefined, true);
  await card.registry.ingestPermission({ session_id: SID, tool_name: "Bash", tool_input: { command: "rm -rf build" } });
  assert.equal(card.published.find((e) => e.type === "action_request")?.metadata?.answerVia, "pty");
  assert.equal(await card.registry.typePrompt(SID, "続けて", "続けて"), "dialogOpen");
  assert.deepEqual(await poll, [], "打った Enter で選択肢を選んでしまうので、何も積まない");
  // ターミナルで答えて先へ進めば（PostToolUse）、打てる。
  card.registry.ingest(hook("PostToolUse", { tool_name: "Bash" }));
  assert.equal(await card.registry.typePrompt(SID, "続けて", "続けて"), "typed");
  card.registry.unregister(SID);

  // 許可確認と /model などの一覧が出ている間は status が waiting になる（claude 2.1.300 で実測）。hook の取りこぼしに備えて status も見る。
  const waiting = setup({}, undefined, "waiting");
  waiting.registry.register(SID, undefined, CLAUDE);
  const waitingPoll = waiting.keys.poll("desktop", [PTY], 100, undefined, true);
  assert.equal(await waiting.registry.typePrompt(SID, "続けて", "続けて"), "dialogOpen");
  assert.deepEqual(await waitingPoll, []);
  waiting.registry.unregister(SID);
});

test("typePrompt: ターミナル側のターンが動いている間（status が busy）は待ち、終わってから打つ", async () => {
  const { registry, keys, home } = setup({}, undefined, "busy");
  registry.register(SID, undefined, CLAUDE);
  registry.ingest(hook("UserPromptSubmit", { prompt: "ターミナルで打った依頼" }));
  const desktop = keys.poll("desktop", [PTY], 2000, undefined, true);
  let outcome: string | undefined;
  const typing = registry.typePrompt(SID, "次はこれ", "次はこれ").then((o) => (outcome = o));
  await sleep(100);
  assert.equal(outcome, undefined, "ターンの途中は打たない");
  writeStatus(home, "idle");
  registry.ingest(hook("Stop", { last_assistant_message: "終わりました" }));
  await typing;
  assert.equal(outcome, "typed");
  assert.deepEqual((await desktop).map((d) => d.keys), [typingKeys("次はこれ")]);
  registry.unregister(SID);
});

test("typePrompt: 状態は Claude Code の status だけで見る（idle・shell は打つ。busy は待ち、idle になったら打つ）", async () => {
  // busy（AskUserQuestion の選択肢が出ている間も busy）: 待ち、idle になったら打つ。
  const t = setup({}, undefined, "busy");
  t.registry.register(SID, undefined, CLAUDE);
  const desktop = t.keys.poll("desktop", [PTY], 2000, undefined, true);
  let outcome: string | undefined;
  const typing = t.registry.typePrompt(SID, "質問に答えて", "質問に答えて").then((o) => (outcome = o));
  await sleep(100);
  assert.equal(outcome, undefined);
  writeStatus(t.home, "idle");
  await typing;
  assert.equal(outcome, "typed");
  assert.equal((await desktop).length, 1);
  t.registry.unregister(SID);

  // hook ではターン中（Stop が来ていない）でも、status が idle なら打つ。
  const idle = setup();
  idle.registry.register(SID, undefined, CLAUDE);
  idle.registry.ingest(hook("UserPromptSubmit", { prompt: "依頼" }));
  idle.keys.poll("desktop", [PTY], 100, undefined, true);
  assert.equal(await idle.registry.typePrompt(SID, "次", "次"), "typed");
  idle.registry.unregister(SID);

  // shell は、返事の後に裏のコマンド（dev サーバーなど）だけが動いている状態。入力欄は空いているので打つ。
  const shell = setup({}, undefined, "shell");
  shell.registry.register(SID, undefined, CLAUDE);
  const shellPoll = shell.keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await shell.registry.typePrompt(SID, "dev サーバーの様子を見て", "dev サーバーの様子を見て"), "typed");
  assert.deepEqual((await shellPoll).map((d) => d.keys), [typingKeys("dev サーバーの様子を見て")]);
  shell.registry.unregister(SID);
});

test("typePrompt: sessions のファイルでその claude だと確かめられない・知らない状態なら unavailable（hook のターンの進み具合では見ない）", async () => {
  const sessionFile = (home: string): string => path.join(home, ".claude", "sessions", `${CLAUDE}.json`);
  const cases: Array<[string, (home: string) => void]> = [
    ["ファイルが無い", (home) => fs.unlinkSync(sessionFile(home))],
    ["pid を使い回した別の会話のファイル（idle）", (home) => writeStatus(home, "idle", "another-session")],
    ["この会話のファイルに status が無い", (home) => fs.writeFileSync(sessionFile(home), JSON.stringify({ pid: CLAUDE, sessionId: SID, startedAt: 1 }))],
    ["読めない形のファイル", (home) => fs.writeFileSync(sessionFile(home), "{")],
    ["知らない値（starting）", (home) => writeStatus(home, "starting")]
  ];
  for (const [label, arrange] of cases) {
    // hook ではターンが終わっている（Stop 済み）。ファイルで確かめられないので、それでも打たない。
    const t = setup({ typingBusyWaitMs: 60 });
    t.registry.register(SID, undefined, CLAUDE);
    t.registry.ingest(hook("UserPromptSubmit", { prompt: "依頼" }));
    t.registry.ingest(hook("Stop"));
    arrange(t.home);
    const desktop = t.keys.poll("desktop", [PTY], 100, undefined, true);
    assert.equal(await t.registry.typePrompt(SID, "こんにちは", "こんにちは"), "unavailable", label);
    assert.deepEqual(await desktop, [], label);
    t.registry.unregister(SID);
  }

  // 選択肢が出ていても、ファイルで確かめられなければ unavailable（呼び元は channel・受け箱へ）。
  const card = setup({}, undefined, null);
  card.registry.register(SID, undefined, CLAUDE);
  card.keys.poll("desktop", [PTY], 100, undefined, true);
  await card.registry.ingestPermission({ session_id: SID, tool_name: "Bash", tool_input: { command: "ls" } });
  assert.equal(await card.registry.typePrompt(SID, "続けて", "続けて"), "unavailable");
  card.registry.unregister(SID);
});

test("typePrompt: 状態を読む口（readStatus）には台帳の pid と session id が渡る。undefined・知らない状態は unavailable、waiting は dialogOpen、shell は打つ", async () => {
  let status: string | undefined;
  const calls: Array<[number, string]> = [];
  const t = setup({
    readStatus: (pid, sessionId) => {
      calls.push([pid, sessionId]);
      return status;
    }
  });
  t.registry.register(SID, undefined, CLAUDE);
  const quiet = t.keys.poll("desktop", [PTY], 100, undefined, true);
  status = undefined;
  assert.equal(await t.registry.typePrompt(SID, "こんにちは", "こんにちは"), "unavailable");
  status = "starting";
  assert.equal(await t.registry.typePrompt(SID, "こんにちは", "こんにちは"), "unavailable");
  status = "waiting";
  assert.equal(await t.registry.typePrompt(SID, "こんにちは", "こんにちは"), "dialogOpen");
  assert.deepEqual(await quiet, [], "何も積まない");
  assert.deepEqual(calls[0], [CLAUDE, SID]);

  status = "shell";
  const desktop = t.keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await t.registry.typePrompt(SID, "dev サーバーの様子を見て", "dev サーバーの様子を見て"), "typed");
  assert.deepEqual((await desktop).map((d) => [d.keys, d.expectPid, d.expectSession]), [[typingKeys("dev サーバーの様子を見て"), CLAUDE, SID]]);
  t.registry.unregister(SID);
});

test("typePrompt: ターンが終わらなければ busy で諦める（打たない）", async () => {
  const { registry, keys } = setup({ typingBusyWaitMs: 60 }, undefined, "busy");
  registry.register(SID, undefined, CLAUDE);
  registry.ingest(hook("UserPromptSubmit", { prompt: "長い作業" }));
  const desktop = keys.poll("desktop", [PTY], 150, undefined, true);
  assert.equal(await registry.typePrompt(SID, "割り込み", "割り込み"), "busy");
  assert.deepEqual(await desktop, []);
  registry.unregister(SID);
});

test("typePrompt: 待っている間に claude が終わったら unavailable（終わった後のシェルには打たない）", async () => {
  const { registry, keys } = setup({}, undefined, "busy");
  registry.register(SID, undefined, CLAUDE);
  registry.ingest(hook("UserPromptSubmit", { prompt: "依頼" }));
  const desktop = keys.poll("desktop", [PTY], 150, undefined, true);
  const typing = registry.typePrompt(SID, "次", "次");
  await sleep(50);
  registry.ingest(hook("SessionEnd"));
  assert.equal(await typing, "unavailable");
  assert.deepEqual(await desktop, []);
});

/* ── 1 件ずつ ─────────────────────────────────────────────────────────── */

test("typePrompt: 続けて送った発話は 1 件ずつ、前の発話が届いて（UserPromptSubmit）そのターンが終わってから打つ", async () => {
  let status = "idle";
  const { registry, keys } = setup({ readStatus: () => status });
  registry.register(SID, undefined, CLAUDE);
  const first = keys.poll("desktop", [PTY], 5000, undefined, true);
  assert.equal(await registry.typePrompt(SID, "一つ目", "一つ目"), "typed");
  assert.deepEqual((await first).map((d) => d.keys), [typingKeys("一つ目")]);

  const second = keys.poll("desktop", [PTY], 5000, undefined, true);
  let delivered = false;
  void second.then(() => (delivered = true));
  let outcomeTwo: string | undefined;
  const two = registry.typePrompt(SID, "二つ目", "二つ目").then((o) => (outcomeTwo = o));
  // 一つ目がまだ届いていない（sessions は idle のまま）間は打たない。
  await sleep(300);
  assert.equal(outcomeTwo, undefined);
  assert.equal(delivered, false);
  // 一つ目が届いてターンが始まる。そのターンの間は打たない。
  status = "busy";
  registry.ingest(hook("UserPromptSubmit", { prompt: "一つ目" }));
  await sleep(300);
  assert.equal(outcomeTwo, undefined);
  assert.equal(delivered, false);
  // ターンが終われば打つ。
  status = "idle";
  registry.ingest(hook("Stop", { last_assistant_message: "OK" }));
  await two;
  assert.equal(outcomeTwo, "typed");
  assert.deepEqual((await second).map((d) => d.keys), [typingKeys("二つ目")]);
  registry.unregister(SID);
});

test("typePrompt: 前の発話が届くのを待つのは typingBusyWaitMs まで。それを過ぎたら次を打つ", async () => {
  const { registry, keys } = setup({ typingBusyWaitMs: 150 });
  registry.register(SID, undefined, CLAUDE);
  const first = keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await registry.typePrompt(SID, "一つ目", "一つ目"), "typed");
  await first; // 一つ目は届かない（UserPromptSubmit が来ない）まま。
  const second = keys.poll("desktop", [PTY], 2000, undefined, true);
  const started = Date.now();
  assert.equal(await registry.typePrompt(SID, "二つ目", "二つ目"), "typed");
  assert.ok(Date.now() - started >= 140, `一つ目が届くのを typingBusyWaitMs（150ms）まで待つ（${Date.now() - started}ms）`);
  assert.deepEqual((await second).map((d) => d.keys), [typingKeys("二つ目")]);
  registry.unregister(SID);
});

test("typePrompt: 呼び元には自分の打ち込みの結果が出た時点で返す（届くまで待たせない）。前の発話が済む前に会話が終われば unavailable、打てなかった発話は次を待たせない", async () => {
  const { registry, keys } = setup();
  registry.register(SID, undefined, CLAUDE);
  const desktop = keys.poll("desktop", [PTY], 2000, undefined, true);
  // 打ったあと、UserPromptSubmit が来る前に戻る。
  assert.equal(await registry.typePrompt(SID, "一つ目", "一つ目"), "typed");
  await desktop;

  // 二つ目は一つ目が済むまで待つ。その間に会話が終われば、打たずに unavailable で戻る。
  const two = registry.typePrompt(SID, "二つ目", "二つ目");
  await sleep(50);
  registry.ingest(hook("SessionEnd"));
  assert.equal(await two, "unavailable");

  // 打てなかった発話（dialogOpen）は、次の発話を待たせない。
  const t = setup({}, undefined, "waiting");
  t.registry.register(SID, undefined, CLAUDE);
  const poll = t.keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await t.registry.typePrompt(SID, "一つ目", "一つ目"), "dialogOpen");
  writeStatus(t.home, "idle");
  assert.equal(await t.registry.typePrompt(SID, "二つ目", "二つ目"), "typed", "前の発話が打てなかったので、すぐ打てる");
  assert.deepEqual((await poll).map((d) => d.keys), [typingKeys("二つ目")]);
  t.registry.unregister(SID);
});

test("typePrompt: 列は unregister で消え、届けば空になる。状態を読む口が失敗しても、次の発話は止まらない", async () => {
  const chain = (r: ClaudeTerminalRegistry): Map<string, unknown> => (r as unknown as { typingTail: Map<string, unknown> }).typingTail;
  const t = setup();
  t.registry.register(SID, undefined, CLAUDE);
  t.keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await t.registry.typePrompt(SID, "一つ目", "一つ目"), "typed");
  assert.equal(chain(t.registry).has(SID), true, "届くまでは列が残る");
  t.registry.unregister(SID);
  assert.equal(chain(t.registry).has(SID), false, "unregister で列を消す");

  // 届いたら、後ろに続く発話が無い列は空になる。
  const settled = setup();
  settled.registry.register(SID, undefined, CLAUDE);
  settled.keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await settled.registry.typePrompt(SID, "一つ目", "一つ目"), "typed");
  settled.registry.ingest(hook("UserPromptSubmit", { prompt: "一つ目" }));
  await until(() => !chain(settled.registry).has(SID), "届いた後に列が空になる");
  settled.registry.unregister(SID);

  // 状態を読む口が投げても、その発話の呼び元だけが失敗する。次の発話は止まらない。
  let broken = true;
  const failing = setup({
    readStatus: () => {
      if (broken) throw new Error("boom");
      return "idle";
    }
  });
  failing.registry.register(SID, undefined, CLAUDE);
  failing.keys.poll("desktop", [PTY], 2000, undefined, true);
  await assert.rejects(failing.registry.typePrompt(SID, "一つ目", "一つ目"), /boom/);
  broken = false;
  assert.equal(await failing.registry.typePrompt(SID, "二つ目", "二つ目"), "typed");
  failing.registry.unregister(SID);
});

/* ── 届いたかの見張り ─────────────────────────────────────────────────── */

test("打ち込んだ発話が届かなければ、考え中を error + 応答の無い done で戻し、待っている送信も終わらせる", async () => {
  const { registry, keys, published } = setup({ typedDeliveryMs: 40 });
  registry.register(SID, undefined, CLAUDE);
  const desktop = keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await registry.typePrompt(SID, "届かない発話", "届かない発話"), "typed");
  const waiting = registry.waitTurn(SID); // send が打ち込んだ後に待つのと同じ
  await desktop;
  await waiting;
  assert.deepEqual(published.map((e) => e.type), ["error", "done"]);
  assert.equal(
    published[0].content,
    "アプリ内ターミナルに打ち込もうとしましたが、Claude Code が受け付けませんでした（0.04 秒たっても反応がありません）。ターミナルの画面を確かめてください（Claude Code が終わっている、打ち込む途中で許可の確認や一覧が開いた、など。途中まで貼った文が入力欄に残っていることがあります）。"
  );
  assert.equal(published[1].metadata?.errored, "true");
  registry.unregister(SID);
});

test("打ち込んだ発話の見張り: 待ち時間には操作（貼り付けと Enter）の数だけ足す。長い文を分けた貼り付けで、書き終える前に失敗にしない", async () => {
  // 1 操作 100ms。貼り付け + Enter の 2 操作なら 40 + 200 = 240ms。経った時間は下から確かめる（負荷で遅れても落ちない）。
  const short = setup({ typedDeliveryMs: 40, typedKeyMs: 100 });
  short.registry.register(SID, undefined, CLAUDE);
  short.keys.poll("desktop", [PTY], 2000, undefined, true);
  const shortStart = Date.now();
  assert.equal(await short.registry.typePrompt(SID, "届かない発話", "届かない発話"), "typed");
  await short.registry.waitTurn(SID);
  assert.ok(Date.now() - shortStart >= 220, `基本の待ち時間（40ms）だけで失敗にしない（${Date.now() - shortStart}ms）`);
  assert.match(short.published[0].content ?? "", /（0.24 秒たっても反応がありません）/);
  short.registry.unregister(SID);

  // 貼り付けが 2 つに分かれる長い文なら 3 操作で 40 + 300 = 340ms。
  const text = "あ".repeat(9000);
  assert.equal(typingKeys(text)?.length, 3);
  const long = setup({ typedDeliveryMs: 40, typedKeyMs: 100 });
  long.registry.register(SID, undefined, CLAUDE);
  long.keys.poll("desktop", [PTY], 2000, undefined, true);
  const longStart = Date.now();
  assert.equal(await long.registry.typePrompt(SID, text, text), "typed");
  await long.registry.waitTurn(SID);
  assert.ok(Date.now() - longStart >= 320, `3 操作分（340ms）までは失敗にしない（${Date.now() - longStart}ms）`);
  assert.match(long.published[0].content ?? "", /（0.34 秒たっても反応がありません）/);
  long.registry.unregister(SID);

  // コマンドも同じ（5 秒 + 操作の数の秒。ここでは 30 + 200 = 230ms）。
  const command = setup({ typedCommandMs: 30, typedKeyMs: 100 });
  command.registry.register(SID, undefined, CLAUDE);
  command.keys.poll("desktop", [PTY], 2000, undefined, true);
  const commandStart = Date.now();
  assert.equal(await command.registry.typePrompt(SID, "/compact", "/compact"), "typed");
  await command.registry.waitTurn(SID);
  assert.ok(Date.now() - commandStart >= 210, `コマンドも操作の数だけ足す（${Date.now() - commandStart}ms）`);
  assert.deepEqual(command.published.map((e) => e.type), ["assistant_delta", "done"]);
  command.registry.unregister(SID);
});

test("打ち込んだ発話が届かなければ、照合用に覚えた文を消す（後でターミナルで打った同じ文を、自分の送信の戻りと取り違えて隠さない）", async () => {
  // 発話: 時間切れのエラーを出した後に、本人がターミナルで同じ短い文を打った。吹き出しにして見せる。
  const { registry, keys, published } = setup({ typedDeliveryMs: 30 });
  registry.register(SID, undefined, CLAUDE);
  keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await registry.typePrompt(SID, "続けて", "続けて"), "typed");
  await registry.waitTurn(SID);
  assert.deepEqual(published.map((e) => e.type), ["error", "done"]);
  published.length = 0;
  registry.ingest(hook("UserPromptSubmit", { prompt: "続けて" }));
  assert.deepEqual(published.filter((e) => e.type === "user_message").map((e) => e.content), ["続けて"]);
  registry.unregister(SID);

  // コマンド: 打ち込んだことを伝えた後に、本人が同じ文を打った。
  const command = setup({ typedCommandMs: 30 });
  command.registry.register(SID, undefined, CLAUDE);
  command.keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await command.registry.typePrompt(SID, "/compact", "/compact"), "typed");
  await command.registry.waitTurn(SID);
  assert.deepEqual(command.published.map((e) => e.type), ["assistant_delta", "done"]);
  command.published.length = 0;
  command.registry.ingest(hook("UserPromptSubmit", { prompt: "/compact" }));
  assert.deepEqual(command.published.filter((e) => e.type === "user_message").map((e) => e.content), ["/compact"]);
  command.registry.unregister(SID);

  // 同じ文を続けて送り、1 つ目だけが届かなかった。消すのは届かなかった 1 つ目の分だけなので、2 つ目の戻りは自分の送信として
  // 隠し、その後にターミナルで打った同じ文は（覚えた分が残っていないので）吹き出しにする。
  const twice = setup({ typedDeliveryMs: 60 });
  twice.registry.register(SID, undefined, CLAUDE);
  twice.keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await twice.registry.typePrompt(SID, "同じ文", "同じ文"), "typed");
  await twice.registry.waitTurn(SID);
  twice.published.length = 0;
  assert.equal(await twice.registry.typePrompt(SID, "同じ文", "同じ文"), "typed");
  twice.registry.ingest(hook("UserPromptSubmit", { prompt: "同じ文" }));
  assert.deepEqual(twice.published.filter((e) => e.type === "user_message"), [], "2 つ目の戻りは自分の送信として隠す");
  twice.registry.ingest(hook("Stop"));
  twice.published.length = 0;
  twice.registry.ingest(hook("UserPromptSubmit", { prompt: "同じ文" }));
  assert.deepEqual(twice.published.filter((e) => e.type === "user_message").map((e) => e.content), ["同じ文"], "1 つ目の分が残っていれば、ここで隠してしまう");
  twice.registry.unregister(SID);
});

test("打ち込んだのがコマンドなら、短く待って打ち込んだことを本文で伝える（エラーにしない）", async () => {
  const { registry, keys, published } = setup({ typedDeliveryMs: 5000, typedCommandMs: 30 });
  registry.register(SID, undefined, CLAUDE);
  const desktop = keys.poll("desktop", [PTY], 2000, undefined, true);
  assert.equal(await registry.typePrompt(SID, "/compact", "/compact"), "typed");
  const waiting = registry.waitTurn(SID);
  assert.deepEqual((await desktop).map((d) => d.keys), [[`${PASTE_START}/compact${PASTE_END}`, "\r"]]);
  await waiting;
  assert.deepEqual(published.map((e) => e.type), ["assistant_delta", "done"]);
  assert.equal(published[0].content, "ターミナルに `/compact` を打ち込みました。結果はターミナルに出ます。");
  assert.equal(published[0].messageId, published[1].messageId, "本文と done は同じ吹き出し");
  assert.equal(published[1].metadata?.errored, undefined);
  registry.unregister(SID);
});

test("打ち込んだ発話の見張り: 届いた印（main の UserPromptSubmit・PreToolUse・Stop）と終わりで外れ、サブエージェントの hook では外れない", async () => {
  const cases: Array<[string, string, Record<string, unknown>, boolean]> = [
    ["main の UserPromptSubmit", "UserPromptSubmit", { prompt: "x" }, true],
    ["main の PreToolUse", "PreToolUse", { tool_name: "Bash", tool_use_id: "t1", tool_input: {} }, true],
    ["main の Stop", "Stop", {}, true],
    ["SessionEnd（unregister）", "SessionEnd", {}, true],
    ["サブエージェントの PreToolUse", "PreToolUse", { agent_id: "sub1", agent_type: "Explore", tool_name: "Read", tool_use_id: "t2", tool_input: {} }, false],
    ["本文（MessageDisplay）", "MessageDisplay", { message_id: "m", delta: "ターミナルの本文" }, false]
  ];
  for (const [label, name, extra, clears] of cases) {
    const { registry, keys, published } = setup({ typedDeliveryMs: 80 });
    registry.register(SID, undefined, CLAUDE);
    keys.poll("desktop", [PTY], 100, undefined, true);
    assert.equal(await registry.typePrompt(SID, "文", "文"), "typed", label);
    registry.ingest(hook(name, extra));
    // UserPromptSubmit は見張りを外すだけでなく、ターンも始める（動いている間は時間切れにしない）。ターンだけ終わらせて確かめる。
    if (name === "UserPromptSubmit") registry.ingest(hook("StopFailure"));
    published.length = 0;
    await sleep(220);
    // 外れていなければ、届かなかったエラー（時間切れ）が出る。
    const timedOut = published.filter((e) => e.type === "error" && (e.content ?? "").includes("打ち込もうとしましたが")).length;
    assert.equal(timedOut, clears ? 0 : 1, label);
    registry.unregister(SID);
  }
});

test("打ち込んだ発話の見張り: ターミナル側のターンが動いている間は時間切れにしない", async () => {
  const { registry, keys, published } = setup({ typedDeliveryMs: 80 });
  registry.register(SID, undefined, CLAUDE);
  keys.poll("desktop", [PTY], 100, undefined, true);
  assert.equal(await registry.typePrompt(SID, "文", "文"), "typed");
  registry.noteChannelPrompt(SID); // 別の経路で始まったターン（generating）
  await sleep(250);
  assert.deepEqual(published, []);
  registry.unregister(SID);
});

/* ── 送信（ClaudeTerminalSession） ────────────────────────────────────── */

function typedEvent(content: string): SessionEvent {
  const evt: SessionEvent = { type: "user_message", content };
  markTypedByUser(evt);
  return evt;
}

test("送信: 人が打った発話は打ち込んでターンの終わりまで待つ。印の無い文（mainagent・定期の見回り）は今までどおり受け箱へ", async () => {
  const { registry, inbox, keys } = setup();
  registry.register(SID, undefined, CLAUDE);
  const session = new ClaudeTerminalSession(SID, registry, inbox);
  const desktop = keys.poll("desktop", [PTY], 2000, undefined, true);
  const events: SessionEvent[] = [];
  let finished = false;
  const sending = session.send("続けて", typedEvent("続けて"), (e) => events.push(e)).then(() => (finished = true));
  assert.deepEqual(await desktop, [{ pid: PTY, keys: typingKeys("続けて"), gapMs: TYPING_GAP_MS, expectPid: CLAUDE, expectSession: SID }]);
  await sleep(30);
  assert.equal(finished, false, "Stop が来るまで送信中");
  registry.ingest(hook("UserPromptSubmit", { prompt: "続けて" }));
  registry.ingest(hook("Stop"));
  await sending;
  assert.deepEqual(events, []);

  // 印の無い文は、channel が繋がっていれば受け箱に置く。キーは打たない。
  const got = inbox.poll(SID, 2000);
  const automatic = session.send("自動の文", { type: "user_message", content: "自動の文" }, () => {});
  assert.deepEqual(await got, [{ kind: "text", text: "自動の文" }]);
  assert.deepEqual(await keys.poll("desktop", [PTY], 50, undefined, true), []);
  registry.ingest(hook("Stop"));
  await automatic;

  // 印は object に付くので、コピーには引き継がれない（metadata にも載らない）。
  const typed = typedEvent("x");
  assert.equal(isTypedByUser(typed), true);
  assert.equal(isTypedByUser({ ...typed }), false);
  assert.equal(typed.metadata, undefined);
  assert.equal(isTypedByUser({ type: "user_message", content: "x", metadata: { typedByUser: "1" } }), false, "端末の JSON で名乗れない");
  registry.unregister(SID);
});

test("送信: 打ち込めない（古いデスクトップ）ときは、印があっても channel・受け箱へ。どちらも無ければ閲覧のみ", async () => {
  const { registry, inbox, keys } = setup();
  registry.register(SID, undefined, CLAUDE);
  const session = new ClaudeTerminalSession(SID, registry, inbox);
  const oldDesktop = keys.poll("desktop", [PTY], 100); // typing=1 を名乗らない
  const events: SessionEvent[] = [];
  await session.send("続けて", typedEvent("続けて"), (e) => events.push(e));
  assert.deepEqual(events.map((e) => e.type), ["error", "done"]);
  assert.match(events[0].content ?? "", /閲覧のみ/);
  assert.equal(events[1].metadata?.errored, "true");
  assert.deepEqual(await oldDesktop, []);

  const got = inbox.poll(SID, 2000);
  const sending = session.send("続けて", typedEvent("続けて"), () => {});
  assert.deepEqual(await got, [{ kind: "text", text: "続けて" }]);
  registry.ingest(hook("Stop"));
  await sending;
  registry.unregister(SID);
});

test("送信: sessions のファイルで確かめられない（打ち込めない）ときは、印があっても channel・受け箱へ", async () => {
  const { registry, inbox, keys } = setup({}, undefined, null);
  registry.register(SID, undefined, CLAUDE);
  const session = new ClaudeTerminalSession(SID, registry, inbox);
  const desktop = keys.poll("desktop", [PTY], 100, undefined, true);
  const got = inbox.poll(SID, 2000);
  const sending = session.send("続けて", typedEvent("続けて"), () => {});
  assert.deepEqual(await got, [{ kind: "text", text: "続けて" }]);
  assert.deepEqual(await desktop, [], "キーは打たない");
  registry.ingest(hook("Stop"));
  await sending;
  registry.unregister(SID);
});

test("送信: 選択肢か一覧が出ている・ターンが終わらないときは打たずに、理由を error + 応答の無い done で返す", async () => {
  const dialog = setup();
  dialog.registry.register(SID, undefined, CLAUDE);
  writeStatus(dialog.home, "waiting");
  dialog.keys.poll("desktop", [PTY], 100, undefined, true);
  const events: SessionEvent[] = [];
  await new ClaudeTerminalSession(SID, dialog.registry, dialog.inbox).send("続けて", typedEvent("続けて"), (e) => events.push(e));
  assert.deepEqual(events.map((e) => e.type), ["error", "done"]);
  assert.equal(events[0].content, "ターミナルに選択肢か一覧（許可の確認・質問・/model など）が出ているので、打ち込みませんでした。カードかターミナルで答えるか閉じてから、もう一度送ってください。");
  assert.equal(events[1].metadata?.errored, "true");
  assert.equal(events[1].sessionId, SID);

  const busy = setup({ typingBusyWaitMs: 50 }, undefined, "busy");
  busy.registry.register(SID, undefined, CLAUDE);
  busy.registry.ingest(hook("UserPromptSubmit", { prompt: "長い作業" }));
  busy.keys.poll("desktop", [PTY], 100, undefined, true);
  const busyEvents: SessionEvent[] = [];
  await new ClaudeTerminalSession(SID, busy.registry, busy.inbox).send("割り込み", typedEvent("割り込み"), (e) => busyEvents.push(e));
  assert.deepEqual(busyEvents.map((e) => e.type), ["error", "done"]);
  assert.equal(busyEvents[0].content, "ターミナルの Claude Code が作業を続けているので、打ち込みませんでした。終わってから、もう一度送ってください。");
  assert.equal(busyEvents[1].metadata?.errored, "true");
  dialog.registry.unregister(SID);
  busy.registry.unregister(SID);
});

test("skill の行: ターミナルに打ち込む文は / で始めない（Claude Code が /skill をコマンドとして読む）。受け箱・channel へ送る文は今までどおり", () => {
  const evt: SessionEvent = { type: "user_message", content: "見て", metadata: { skills: "a,b" } };
  const typed = metadataText(evt, "見て", { typed: true });
  assert.equal(typed, "Use these skills: a, b\n見て");
  assert.equal(slashCommand(typed), null, "Bridge もコマンドとは見ない");
  // 受け箱・channel・ほかのエージェントへ送る文は変わらない。
  assert.equal(metadataText(evt, "見て"), "/skill a,b\n見て");
  assert.equal(slashCommand(metadataText(evt, "見て")), "/skill", "以前は、この行がコマンドとして読まれていた");
  // skill が無ければ本文のまま。
  assert.equal(metadataText({ type: "user_message", content: "見て" }, "見て", { typed: true }), "見て");
  assert.equal(metadataText({ type: "user_message", content: "見て", metadata: { skills: " , " } }, "見て", { typed: true }), "見て");
});

test("送信: 添付と skill は本文に展開して打ち込む（skill の行は / で始めない）。照合には元の本文を使う。受け箱へ送る文は /skill のまま", async () => {
  const { registry, inbox, keys, published } = setup();
  registry.register(SID, undefined, CLAUDE);
  const session = new ClaudeTerminalSession(SID, registry, inbox);
  const desktop = keys.poll("desktop", [PTY], 2000, undefined, true);
  const attachment = Buffer.from("中身です", "utf8").toString("base64");
  const evt: SessionEvent = {
    type: "user_message",
    content: "これを見て",
    metadata: { skills: "review", attachment_count: "1", attachment_0_kind: "file", attachment_0_name: "memo.txt", attachment_0_mime: "text/plain", attachment_0_b64: attachment }
  };
  markTypedByUser(evt);
  const sending = session.send("これを見て", evt, () => {});
  const sent = (await desktop)[0].keys.join("");
  await sleep(20); // hook が届くのは、キーをターミナルに書いた後
  assert.equal(sent, `${PASTE_START}<file name="memo.txt" mime="text/plain">\n中身です\n</file>\n\nUse these skills: review\nこれを見て${PASTE_END}\r`);
  // 戻ってきた発話は、元の本文（これを見て）で照合して二重に出さない。
  registry.ingest(hook("UserPromptSubmit", { prompt: '<file name="memo.txt" mime="text/plain">\n中身です\n</file>\n\nUse these skills: review\nこれを見て' }));
  assert.equal(published.filter((e) => e.type === "user_message").length, 0);
  registry.ingest(hook("Stop"));
  await sending;

  // skill だけで添付が無い発話は、先頭が skill の行になる。コマンドとして読まれる `/skill` では始めない。
  const onlySkills: SessionEvent = { type: "user_message", content: "見て", metadata: { skills: "a,b" } };
  markTypedByUser(onlySkills);
  const desktop2 = keys.poll("desktop", [PTY], 2000, undefined, true);
  const typedSending = session.send("見て", onlySkills, () => {});
  assert.deepEqual((await desktop2)[0].keys, [`${PASTE_START}Use these skills: a, b\n見て${PASTE_END}`, "\r"]);
  await sleep(20); // hook が届くのは、キーをターミナルに書いた後
  registry.ingest(hook("UserPromptSubmit", { prompt: "Use these skills: a, b\n見て" }));
  registry.ingest(hook("Stop"));
  await typedSending;

  // 人が打った発話でなければ（mainagent・定期の見回り）、受け箱へ送る文は今までどおり `/skill a,b`。
  const got = inbox.poll(SID, 2000);
  const automatic = session.send("見て", { type: "user_message", content: "見て", metadata: { skills: "a,b" } }, () => {});
  assert.deepEqual(await got, [{ kind: "text", text: "/skill a,b\n見て" }]);
  registry.ingest(hook("Stop"));
  await automatic;
  registry.unregister(SID);
});
