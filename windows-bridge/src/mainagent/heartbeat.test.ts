import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";
import type { AgentAdapter, AgentSession, SessionOptions } from "../agents/types.js";
import type { SessionEvent } from "../protocol.js";
import {
  clampInterval,
  DEFAULT_SETTINGS,
  defaultHeartbeatDir,
  HeartbeatService,
  heartbeatPrompt,
  inQuietHours,
  isDue,
  isHeartbeatOk,
  mergeSettings,
  nextRunAt,
  normalizeSettings,
  normalizeState,
  pushBody,
  SESSION_TITLE,
  type HeartbeatHub
} from "./heartbeat.js";
import { Orchestrator } from "./orchestrator.js";
import {
  appendNote,
  ensureHeartbeatFiles,
  ensureMainAgentWorkspace,
  HEARTBEAT_TEMPLATE,
  LEGACY_HEARTBEAT_TEMPLATES,
  MANAGED_BEGIN,
  MANAGED_END,
  MANAGED_VERSION,
  NOTES_TEMPLATE,
  ROLE_TEXT,
  setMainAgentRoot,
  TOOL_NAMES
} from "./workspace.js";
import { callTool } from "./mcpEndpoint.js";

// メインの定期チェック（docs/MAIN_HEARTBEAT_2026-10-20.md）の決まりと、回し方（台本の hub）を確かめる。

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-heartbeat-test-"));
after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));
// 本体のタイマー（時間切れ・猶予）は unref してある。それしか残っていないと、Node 22 は待っている途中のテストを
// 打ち切る（cancelledByParent）。このファイルのテストの間は event loop を生かしておく。
const keepAlive = setInterval(() => {}, 1000);
after(() => clearInterval(keepAlive));
let seq = 0;
const freshDir = (): string => {
  const d = path.join(tmp, `d${++seq}`);
  fs.mkdirSync(d, { recursive: true });
  return d;
};
const at = (hhmm: string, day = 20): Date => {
  const [h, m] = hhmm.split(":").map(Number);
  return new Date(2026, 9, day, h, m, 0, 0);
};

// ---- 決まり ----

test("間隔は 30〜1440 分に丸める（数でなければ今の値のまま）", () => {
  assert.equal(clampInterval(5), 30);
  assert.equal(clampInterval(5000), 1440);
  assert.equal(clampInterval(60.4), 60);
  assert.equal(clampInterval("60"), undefined);
  assert.equal(mergeSettings(normalizeSettings(undefined), { intervalMinutes: "x" }).intervalMinutes, 180);
});

test("設定: 無ければ既定、一部だけの変更は足りない項目を今の値のまま重ねる", () => {
  const d = normalizeSettings(undefined);
  assert.deepEqual(d, { enabled: true, intervalMinutes: 180, quietHours: { enabled: true, start: "22:00", end: "08:00" }, agentId: "claude", prompt: "" });
  assert.deepEqual(normalizeSettings("broken"), d);
  const m = mergeSettings(d, { enabled: false, quietHours: { start: "23:30" }, agentId: "codex" });
  assert.equal(m.enabled, false);
  assert.deepEqual(m.quietHours, { enabled: true, start: "23:30", end: "08:00" });
  assert.equal(m.agentId, "codex");
  // mainagent を扱えないエージェント・形の違う時刻は受けない。
  const bad = mergeSettings(m, { agentId: "opencode", quietHours: { end: "25:00", enabled: "yes" } });
  assert.equal(bad.agentId, "codex");
  assert.deepEqual(bad.quietHours, m.quietHours);
  // 既定の値そのものは書き換わらない。
  assert.equal(DEFAULT_SETTINGS.quietHours.start, "22:00");
});

test("静かな時間: 日をまたぐ範囲（22:00〜08:00）と同じ日の範囲、start = end は無し", () => {
  const night = { enabled: true, start: "22:00", end: "08:00" };
  assert.equal(inQuietHours(at("23:10"), night), true);
  assert.equal(inQuietHours(at("02:00"), night), true);
  assert.equal(inQuietHours(at("07:59"), night), true);
  assert.equal(inQuietHours(at("08:00"), night), false);
  assert.equal(inQuietHours(at("21:59"), night), false);
  assert.equal(inQuietHours(at("22:00"), night), true);
  const lunch = { enabled: true, start: "12:00", end: "13:00" };
  assert.equal(inQuietHours(at("12:30"), lunch), true);
  assert.equal(inQuietHours(at("13:00"), lunch), false);
  assert.equal(inQuietHours(at("02:00"), { ...night, enabled: false }), false);
  assert.equal(inQuietHours(at("02:00"), { enabled: true, start: "08:00", end: "08:00" }), false);
});

test("回すか: 止めていない・間隔が過ぎた・静かな時間でない。初めては起きてから 10 分", () => {
  const s = normalizeSettings({ intervalMinutes: 60 });
  const boot = at("10:00");
  assert.equal(isDue(s, {}, at("10:09"), boot), false);
  assert.equal(isDue(s, {}, at("10:10"), boot), true);
  const ran = { lastRunAt: at("10:00").toISOString() };
  assert.equal(isDue(s, ran, at("10:59"), boot), false);
  assert.equal(isDue(s, ran, at("11:00"), boot), true);
  assert.equal(isDue({ ...s, enabled: false }, ran, at("11:00"), boot), false);
  // 静かな時間（22:00〜08:00）は回さない。
  const late = { lastRunAt: at("21:30").toISOString() };
  assert.equal(isDue(s, late, at("22:30"), boot), false);
  assert.equal(isDue(s, late, at("08:00", 21), boot), true);
});

test("次の予定: 間隔の後、静かな時間に当たれば明ける時刻、止めていれば無し", () => {
  const s = normalizeSettings({ intervalMinutes: 60 });
  const boot = at("10:00");
  assert.equal(nextRunAt(s, {}, at("10:00"), boot)?.getTime(), at("10:10").getTime());
  assert.equal(nextRunAt(s, { lastRunAt: at("12:00").toISOString() }, at("12:01"), boot)?.getTime(), at("13:00").getTime());
  assert.equal(nextRunAt(s, { lastRunAt: at("21:30").toISOString() }, at("21:31"), boot)?.getTime(), at("08:00", 21).getTime());
  assert.equal(nextRunAt({ ...s, enabled: false }, {}, at("10:00"), boot), undefined);
});

test("HEARTBEAT_OK の見分け（前後の空白を除いて始まり、40 文字以下）", () => {
  assert.equal(isHeartbeatOk("HEARTBEAT_OK"), true);
  assert.equal(isHeartbeatOk("  HEARTBEAT_OK\n"), true);
  assert.equal(isHeartbeatOk("HEARTBEAT_OK（異常なし）"), true);
  assert.equal(isHeartbeatOk(`HEARTBEAT_OK ${"x".repeat(27)}`), true); // 40 文字ちょうど
  assert.equal(isHeartbeatOk(`HEARTBEAT_OK ${"x".repeat(28)}`), false);
  assert.equal(isHeartbeatOk("承認待ちが 1 件あります。HEARTBEAT_OK"), false);
  assert.equal(isHeartbeatOk(""), false);
});

test("通知の本文: 頭 3 行・200 文字まで", () => {
  assert.equal(pushBody("一\n\n二\n三\n四"), "一\n二\n三");
  const long = pushBody("あ".repeat(500));
  assert.equal(Array.from(long).length, 200);
  assert.ok(long.endsWith("…"));
  assert.equal(pushBody("  短い  "), "短い");
});

test("送る文は固定で、手元の時刻（YYYY-MM-DD HH:mm）が入る", () => {
  const p = heartbeatPrompt(new Date(2026, 9, 20, 9, 5));
  assert.ok(p.startsWith("[定期チェック 2026-10-20 09:05]\n"));
  assert.ok(p.includes("HEARTBEAT.md"));
  assert.ok(p.includes("save_note"));
  assert.ok(p.includes("HEARTBEAT_OK とだけ返してください"));
});

test("送る文の本文は設定で変えられる（頭と HEARTBEAT_OK の決まりは残る。空なら既定）", () => {
  const p = heartbeatPrompt(new Date(2026, 9, 20, 9, 5), "  承認待ちだけ見てください  ");
  assert.ok(p.startsWith("[定期チェック 2026-10-20 09:05]\n承認待ちだけ見てください\n"));
  assert.ok(!p.includes("HEARTBEAT.md"));
  assert.ok(p.includes("HEARTBEAT_OK とだけ返してください"));
  assert.equal(heartbeatPrompt(new Date(2026, 9, 20, 9, 5), "   "), heartbeatPrompt(new Date(2026, 9, 20, 9, 5)));
  assert.equal(mergeSettings(normalizeSettings(undefined), { prompt: "  x  " }).prompt, "x");
  assert.equal(mergeSettings(normalizeSettings(undefined), { prompt: 1 }).prompt, "");
  assert.equal(mergeSettings(normalizeSettings(undefined), { prompt: "あ".repeat(3000) }).prompt.length, 2000);
});

test("状態: 回している最中に止まった（running のまま）なら error として読む", () => {
  const s = normalizeState({ sessionId: "s1", agentId: "claude", lastResult: "running", lastRunAt: "2026-10-20T00:00:00.000Z" });
  assert.equal(s.lastResult, "error");
  assert.equal(s.sessionId, "s1");
  assert.deepEqual(normalizeState("x"), {});
});

test("置き場所: Windows は %USERPROFILE%\\.buddyos、それ以外は設定フォルダ", () => {
  assert.equal(defaultHeartbeatDir("C:\\cfg", "win32", { USERPROFILE: "C:\\Users\\me" }), "C:\\Users\\me\\.buddyos");
  assert.equal(defaultHeartbeatDir("/cfg", "darwin", {}), "/cfg");
});

// ---- ファイルと save_note ----

test("HEARTBEAT.md / NOTES.md は無いときだけ作り、利用者が直したものは書き換えない", () => {
  const root = freshDir();
  ensureHeartbeatFiles(root);
  assert.equal(fs.readFileSync(path.join(root, "HEARTBEAT.md"), "utf8"), HEARTBEAT_TEMPLATE);
  assert.equal(fs.readFileSync(path.join(root, "NOTES.md"), "utf8"), NOTES_TEMPLATE);
  fs.writeFileSync(path.join(root, "HEARTBEAT.md"), "# 自分の項目\n");
  ensureHeartbeatFiles(root);
  assert.equal(fs.readFileSync(path.join(root, "HEARTBEAT.md"), "utf8"), "# 自分の項目\n");
  // 前の版のまま（手を入れていない）なら今の版に置き換える。
  fs.writeFileSync(path.join(root, "HEARTBEAT.md"), LEGACY_HEARTBEAT_TEMPLATES[0]);
  ensureHeartbeatFiles(root);
  assert.equal(fs.readFileSync(path.join(root, "HEARTBEAT.md"), "utf8"), HEARTBEAT_TEMPLATE);
});

test("save_note: NOTES.md の末尾に日時付きの 1 行（改行は空白、500 文字まで）。別の PC からは使えない", async () => {
  const root = freshDir();
  const line = appendNote(root, "  好み:\n短く  ", new Date(2026, 9, 20, 7, 3));
  assert.equal(line, "- 2026-10-20 07:03 好み: 短く");
  assert.ok(fs.readFileSync(path.join(root, "NOTES.md"), "utf8").endsWith(`${NOTES_TEMPLATE}${line}\n`));
  // 改行で終わらないファイルにも 1 行として足す。
  fs.writeFileSync(path.join(root, "NOTES.md"), "手で書いた");
  appendNote(root, "次", new Date(2026, 9, 20, 7, 4));
  assert.equal(fs.readFileSync(path.join(root, "NOTES.md"), "utf8"), "手で書いた\n- 2026-10-20 07:04 次\n");
  assert.throws(() => appendNote(root, " \n "));

  setMainAgentRoot(root);
  try {
    const orch = new Orchestrator();
    const caller = { token: "t", agentId: "claude", main: true };
    const r = (await callTool("save_note", { text: "x".repeat(600) }, caller, orch)) as { saved: string; file: string };
    assert.equal(r.saved.length, "- 2026-10-20 07:04 ".length + 500);
    assert.equal(r.file, path.join(root, "NOTES.md"));
    await assert.rejects(callTool("save_note", { text: "a" }, { ...caller, remote: { deviceKeyId: "d", capMode: 0, depth: 0 } }, orch), /mainagent のセッションだけ/);
    await assert.rejects(callTool("save_note", { text: "a" }, { ...caller, main: false }, orch), /mainagent のセッションだけ/);
    await assert.rejects(callTool("save_note", {}, caller, orch), /text が無い/);
  } finally {
    setMainAgentRoot(undefined);
  }
  assert.ok(TOOL_NAMES.includes("save_note"));
});

test("役割の文は v3（定期チェックとメモの段落）。v2 の範囲は起動で v3 に書き直し、範囲の外は残す", () => {
  assert.equal(MANAGED_VERSION, 3);
  assert.ok(ROLE_TEXT.includes("[定期チェック …] で始まる依頼"));
  assert.ok(ROLE_TEXT.includes("save_note"));
  const root = freshDir();
  const old = `前に足した文\n${MANAGED_BEGIN} v2 — 古い -->\n古い役割\n${MANAGED_END}\n後ろに足した文\n`;
  fs.writeFileSync(path.join(root, "CLAUDE.md"), old);
  const projects = { list: () => [{ path: root, name: "メイン" }], add: () => {} } as never;
  ensureMainAgentWorkspace(root, projects);
  const now = fs.readFileSync(path.join(root, "CLAUDE.md"), "utf8");
  assert.ok(now.startsWith("前に足した文\n"));
  assert.ok(now.includes(`${MANAGED_BEGIN} v3`));
  assert.ok(now.includes("HEARTBEAT_OK とだけ返す"));
  assert.ok(!now.includes("古い役割"));
  assert.ok(now.endsWith("後ろに足した文\n"));
  // ワークスペースを用意すると、定期チェックのファイルもそろう。
  assert.ok(fs.existsSync(path.join(root, "HEARTBEAT.md")));
  assert.ok(fs.existsSync(path.join(root, "NOTES.md")));
});

test("道具の印: 無人でも定期チェックの印が付いた mainagent のフォルダの会話にだけ道具を渡す", () => {
  const root = freshDir();
  const other = freshDir();
  setMainAgentRoot(root);
  try {
    const orch = new Orchestrator();
    assert.equal(orch.planFor("claude", undefined, root, true), undefined, "cron の無人実行には渡さない");
    assert.deepEqual(orch.planFor("claude", undefined, root, true, true), { main: true, depth: 0 });
    assert.equal(orch.planFor("claude", undefined, other, true, true), undefined, "印があってもメイン以外には渡さない");
    const grant = orch.grantFor("claude", undefined, root, true, true);
    assert.ok(grant?.token.startsWith("bmt_") && grant.main);
  } finally {
    setMainAgentRoot(undefined);
  }
});

// ---- 回し方（台本の hub） ----

type Script = (prompt: string, emit: (evt: SessionEvent) => void, sid: string) => void | Promise<void>;

interface FakeHub extends HeartbeatHub {
  opened: Array<{ agentId: string; sessionId?: string; cwd?: string; options?: SessionOptions }>;
  prompts: string[];
  busy: Set<string>;
  released: number;
}

function fakeHub(script: Script, opts: { failResume?: Set<string>; newId?: () => string } = {}): FakeHub {
  let n = 0;
  const hub: FakeHub = {
    opened: [],
    prompts: [],
    busy: new Set(),
    released: 0,
    adapter: (agentId) => ({ id: agentId }) as AgentAdapter,
    snapshot: () => [...hub.busy].map((sid) => ({ agentId: "claude", sessionId: sid, generating: true, queued: 0 })),
    acquire: async (agentId, sessionId, cwd, send, options) => {
      hub.opened.push({ agentId, sessionId, cwd, options });
      if (sessionId && opts.failResume?.has(sessionId)) throw new Error("no such session");
      const session = { sessionId: sessionId ?? `pending-${++n}`, async send() {}, async close() {} } as AgentSession;
      return {
        session,
        holds: () => true,
        submit: (cmid, content) => {
          hub.prompts.push(content);
          const emit = (evt: SessionEvent): void => send(evt);
          emit({ type: "queue_dispatched", agentId, sessionId: session.sessionId, metadata: { clientMessageId: cmid } });
          if (session.sessionId.startsWith("pending")) {
            const real = opts.newId?.() ?? `hb-${n}`;
            session.sessionId = real;
            emit({ type: "session_started", agentId, sessionId: real });
          }
          void script(content, emit, session.sessionId);
          return "sent";
        },
        release: () => {
          hub.released++;
        }
      };
    }
  };
  return hub;
}

function service(hub: FakeHub, root: string, extra: Partial<ConstructorParameters<typeof HeartbeatService>[0]> = {}, initialState?: object) {
  const pushes: Array<{ title: string; body: string; data: Record<string, string> }> = [];
  const renames: string[] = [];
  const statuses: SessionEvent[] = [];
  const dir = freshDir();
  if (initialState) fs.writeFileSync(path.join(dir, "heartbeat-state.json"), JSON.stringify(initialState));
  const svc = new HeartbeatService({
    dir,
    mainRoot: () => root,
    hub: () => hub,
    push: (title, body, data) => pushes.push({ title, body, data }),
    bridgeId: () => "bridge-1",
    rename: (agentId, sid, title) => renames.push(`${agentId}:${sid}:${title}`),
    log: () => {},
    ...extra
  });
  svc.register((evt) => statuses.push(evt));
  return { svc, pushes, renames, statuses, dir };
}

const reply = (text: string): Script => (_p, emit, sid) => {
  emit({ type: "assistant_delta", agentId: "claude", sessionId: sid, messageId: "m1", content: text });
  emit({ type: "done", agentId: "claude", sessionId: sid });
};

test("HEARTBEAT_OK: 通知せず ok。会話の ID を覚え、新しい会話に「定期チェック」の名前を付け、無人＋印で開く", async () => {
  const root = freshDir();
  const hub = fakeHub(reply("HEARTBEAT_OK"));
  const { svc, pushes, renames, statuses, dir } = service(hub, root);
  assert.equal(svc.runNow(), true);
  assert.equal(svc.runNow(), false, "動いている最中は何もしない");
  await svc.idle();
  assert.equal(svc.state.lastResult, "ok");
  assert.equal(svc.state.sessionId, "hb-1");
  assert.equal(pushes.length, 0);
  assert.deepEqual(renames, [`claude:hb-1:${SESSION_TITLE}`]);
  assert.deepEqual(hub.opened[0], { agentId: "claude", sessionId: undefined, cwd: root, options: { unattended: true, heartbeat: true } });
  assert.ok(hub.prompts[0].startsWith("[定期チェック "));
  assert.equal(hub.released, 1);
  assert.ok(fs.existsSync(path.join(root, "HEARTBEAT.md")));
  // 回し始め（running）と終わり（ok）を配る。
  const results = statuses.map((e) => (JSON.parse(e.content ?? "{}") as { state: { lastResult: string } }).state.lastResult);
  assert.deepEqual(results, ["running", "ok"]);
  assert.equal(statuses[0].type, "heartbeat_status");
  // 状態はファイルに残る。
  const saved = JSON.parse(fs.readFileSync(path.join(dir, "heartbeat-state.json"), "utf8")) as { sessionId: string; lastResult: string; nextRunAt: string };
  assert.equal(saved.sessionId, "hb-1");
  assert.equal(saved.lastResult, "ok");
  assert.ok(saved.nextRunAt);

  // 2 回目は続き（resume）で開き、名前は付け直さない。
  assert.equal(svc.runNow(), true);
  await svc.idle();
  assert.equal(hub.opened[1].sessionId, "hb-1");
  assert.equal(renames.length, 1);
});

test("伝えることがあれば reported で全端末に通知（chat・その会話を開く。頭 3 行）", async () => {
  const root = freshDir();
  const hub = fakeHub((_p, emit, sid) => {
    emit({ type: "assistant_delta", agentId: "claude", sessionId: sid, messageId: "m1", content: "見てみます" });
    emit({ type: "assistant_turn_end", agentId: "claude", sessionId: sid });
    emit({ type: "assistant_delta", agentId: "claude", sessionId: sid, messageId: "m2", content: "承認待ちが 1 件\n" });
    emit({ type: "assistant_delta", agentId: "claude", sessionId: sid, messageId: "m2", content: "BuddyOS claude\n終わった作業 2 件\n4 行目" });
    emit({ type: "done", agentId: "claude", sessionId: sid });
  });
  const { svc, pushes } = service(hub, root);
  svc.runNow();
  await svc.idle();
  assert.equal(svc.state.lastResult, "reported");
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].title, "メイン（定期チェック）");
  assert.equal(pushes[0].body, "承認待ちが 1 件\nBuddyOS claude\n終わった作業 2 件");
  assert.deepEqual(pushes[0].data, { kind: "chat", agentId: "claude", sessionId: "hb-1", bridgeId: "bridge-1" });
});

test("続きで開けなければ新しい会話を作って覚え直す", async () => {
  const root = freshDir();
  const hub = fakeHub(reply("HEARTBEAT_OK"), { failResume: new Set(["gone"]), newId: () => "hb-new" });
  // 前の状態に消えた会話を覚えている。
  const { svc, renames } = service(hub, root, {}, { sessionId: "gone", agentId: "claude", lastRunAt: new Date().toISOString() });
  svc.runNow();
  await svc.idle();
  assert.deepEqual(hub.opened.map((o) => o.sessionId), ["gone", undefined]);
  assert.equal(svc.state.sessionId, "hb-new");
  assert.equal(svc.state.lastResult, "ok");
  assert.deepEqual(renames, [`claude:hb-new:${SESSION_TITLE}`]);
});

test("返事なしの失敗で resume が効かなければ新しく作り直す。新しい会話でも失敗なら error（通知しない）", async () => {
  const root = freshDir();
  const hub = fakeHub((_p, emit, sid) => {
    emit({ type: "error", agentId: "claude", sessionId: sid, content: "boom" });
    emit({ type: "done", agentId: "claude", sessionId: sid });
  });
  const { svc, pushes } = service(hub, root, {}, { sessionId: "old", agentId: "claude" });
  svc.runNow();
  await svc.idle();
  assert.deepEqual(hub.opened.map((o) => o.sessionId), ["old", undefined]);
  assert.equal(svc.state.lastResult, "error");
  assert.equal(svc.state.lastMessage, "boom");
  assert.equal(pushes.length, 0);
});

test("時間切れは止めて error（通知しない）", async () => {
  const root = freshDir();
  let interrupted = 0;
  const hub = fakeHub(() => {
    /* 何も返さない */
  });
  const acquire = hub.acquire;
  const { svc, pushes } = service(hub, root, { runTimeoutMs: 30 });
  // 打ち切りの猶予（6 秒）を待たずに済むよう、止めたら done を返す。
  hub.acquire = async (...args) => {
    const sub = await acquire(...args);
    (sub.session as AgentSession).interrupt = async () => {
      interrupted++;
      args[3]({ type: "done", agentId: "claude", sessionId: sub.session.sessionId });
    };
    return sub;
  };
  svc.runNow();
  await svc.idle();
  assert.equal(interrupted, 1);
  assert.equal(svc.state.lastResult, "error");
  assert.match(svc.state.lastMessage ?? "", /時間切れ/);
  assert.equal(pushes.length, 0);
});

test("見回り: 前の回の会話が動いていれば skipped（lastRunAt は進めない）。止めていれば回さない", async () => {
  const root = freshDir();
  const hub = fakeHub(reply("HEARTBEAT_OK"));
  let clock = new Date(2026, 9, 20, 12, 0);
  const { svc, dir } = service(hub, root, { now: () => clock });
  svc.runNow();
  await svc.idle();
  const firstRun = svc.state.lastRunAt;
  hub.busy.add("hb-1");
  clock = new Date(2026, 9, 20, 15, 30);
  assert.equal(svc.tick(), undefined);
  assert.equal(svc.state.lastResult, "skipped");
  assert.equal(svc.state.lastRunAt, firstRun);
  hub.busy.clear();
  const run = svc.tick();
  assert.ok(run);
  await run;
  assert.equal(svc.state.lastResult, "ok");
  assert.notEqual(svc.state.lastRunAt, firstRun);
  // 止めると回さない。設定はファイルに残る。
  svc.setSettings({ enabled: false });
  clock = new Date(2026, 9, 21, 12, 0);
  assert.equal(svc.tick(), undefined);
  assert.equal(svc.state.nextRunAt, undefined);
  const saved = JSON.parse(fs.readFileSync(path.join(dir, "heartbeat.json"), "utf8")) as { enabled: boolean; intervalMinutes: number };
  assert.equal(saved.enabled, false);
  assert.equal(saved.intervalMinutes, 180);
});

test("エージェントを変えたら、前のエージェントの会話は使わずに新しく作る", async () => {
  const root = freshDir();
  const hub = fakeHub(reply("HEARTBEAT_OK"));
  const { svc } = service(hub, root);
  svc.runNow();
  await svc.idle();
  svc.setSettings({ agentId: "codex" });
  svc.runNow();
  await svc.idle();
  assert.deepEqual(hub.opened.map((o) => [o.agentId, o.sessionId]), [["claude", undefined], ["codex", undefined]]);
  assert.equal(svc.state.agentId, "codex");
});

test("承認カード: 定期チェックのほかに誰も見ていなければ承認の通知で呼び出す", async () => {
  const root = freshDir();
  const script: Script = (_p, emit, sid) => {
    emit({ type: "action_request", agentId: "claude", sessionId: sid, messageId: "req-1", metadata: { title: "start_session の確認" } });
    emit({ type: "assistant_delta", agentId: "claude", sessionId: sid, messageId: "m1", content: "HEARTBEAT_OK" });
    emit({ type: "done", agentId: "claude", sessionId: sid });
  };
  let watchers = 1;
  const { svc, pushes } = service(fakeHub(script), root, { watchers: () => watchers });
  svc.runNow();
  await svc.idle();
  assert.deepEqual(pushes, [
    { title: "メイン（定期チェック）", body: "start_session の確認", data: { kind: "approval_request", agentId: "claude", sessionId: "hb-1", requestId: "req-1", bridgeId: "bridge-1" } }
  ]);
  // iPhone が開いている（定期チェック + 1）なら通知しない（hub の承認カードと同じ）。
  watchers = 2;
  svc.runNow();
  await svc.idle();
  assert.equal(pushes.length, 1);
});

const rowEvent = (sid: string, state: string): SessionEvent => ({
  type: "workflow_progress",
  agentId: "claude",
  sessionId: sid,
  content: JSON.stringify({ subtype: "task_progress", taskId: "subagents", kind: "subagents", epoch: "E1", agents: [{ index: 0, id: "a1", state, rowKind: "agent" }] })
});

test("バックグラウンドのサブエージェントが動いている間は起動の返事で終わらせず、知らせのターンの結論を報告にする", async () => {
  const root = freshDir();
  const hub = fakeHub((_p, emit, sid) => {
    emit(rowEvent(sid, "running"));
    emit({ type: "assistant_delta", agentId: "claude", sessionId: sid, messageId: "m1", content: "調べています" });
    emit({ type: "done", agentId: "claude", sessionId: sid, messageId: "m1" });
    setTimeout(() => {
      emit(rowEvent(sid, "done"));
      emit({ type: "assistant_delta", agentId: "claude", sessionId: sid, messageId: "m2", content: "承認待ちが 2 件ありました" });
      emit({ type: "done", agentId: "claude", sessionId: sid, messageId: "m2", metadata: { origin: "task-notification" } });
    }, 80);
  });
  const { svc, pushes } = service(hub, root);
  svc.runNow();
  await svc.idle();
  assert.equal(svc.state.lastResult, "reported");
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].body, "承認待ちが 2 件ありました", "起動の返事ではなく結論");
});

test("バックグラウンドの行が終わっても知らせのターンが来なければ、猶予のあと起動の返事で終える", async () => {
  const root = freshDir();
  const hub = fakeHub((_p, emit, sid) => {
    emit(rowEvent(sid, "running"));
    emit({ type: "assistant_delta", agentId: "claude", sessionId: sid, messageId: "m1", content: "HEARTBEAT_OK" });
    emit({ type: "done", agentId: "claude", sessionId: sid, messageId: "m1" });
    setTimeout(() => emit(rowEvent(sid, "done")), 50);
  });
  const { svc } = service(hub, root, { backgroundSettleMs: 80 });
  svc.runNow();
  await svc.idle();
  assert.equal(svc.state.lastResult, "ok");
});
