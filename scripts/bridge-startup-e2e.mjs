#!/usr/bin/env node
// BuddyOS Bridge 起動・cron 同期 E2E 回帰テスト
//
// 目的（このリポジトリで修正した 2 つの不具合の回帰ガード）:
//   1. 起動順序: WS リッスンが cron 初期化 (CronOutputHub の全ファイル走査) で
//      ブロックされ、「プロセスは生きているのに繋がらない」状態を作らないこと。
//      → BridgeApp バイナリをテストポートで直接起動し、HTTP が応答するまでの
//        server.start() 純粋レイテンシ (time-to-listen) を計測する。
//        launchd 経由 (zsh -lic ログインシェル) はプロファイル読込で数秒かかり
//        cron とは無関係なノイズになるため、回帰判定にはバイナリ直接起動を使う。
//   2. cron 同期: 稼働中ブリッジに対し cron RPC が往復すること。
//      → WS を開き list_cron_jobs_request を投げ、cron_job_list_end が返ることを確認。
//
// 使い方:
//   node scripts/bridge-startup-e2e.mjs                  # 直接起動で計測 + 稼働中ブリッジで cron 検証
//   node scripts/bridge-startup-e2e.mjs --skip-spawn     # 起動計測を省略 (バイナリ未ビルド時)
//   BRIDGE_HOST=127.0.0.1:8765 BRIDGE_BIN=/path/to/BridgeApp THRESHOLD_MS=3000 node scripts/bridge-startup-e2e.mjs
//
// 要件: Node 22+ (グローバル WebSocket / fetch)。依存パッケージなし。

import { readFileSync, existsSync, mkdtempSync, mkdirSync, symlinkSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { spawn } from "node:child_process";

const HOST = process.env.BRIDGE_HOST || "127.0.0.1:8765";
const AGENT = process.env.AGENT || "claude";
// server.start() の純粋レイテンシ許容値。実測は ~270ms。cron 全走査が起動経路に
// 戻れば秒単位に膨れるので、その回帰を 3 秒で検出する。
const THRESHOLD_MS = Number(process.env.THRESHOLD_MS || 3000);
const CRON_TIMEOUT_MS = Number(process.env.CRON_TIMEOUT_MS || 12000);
const SKIP_SPAWN = process.argv.includes("--skip-spawn");
// 計測対象バイナリ (launchd 常駐が指す既定パス)。
const BRIDGE_BIN =
  process.env.BRIDGE_BIN ||
  homedir() + "/develope/BuddyOS/mac-bridge/.build/release/BridgeApp";
const TEST_PORT = Number(process.env.TEST_PORT || 8769);

function readApiKey() {
  try {
    return readFileSync(homedir() + "/.buddyos/api-key", "utf8").trim();
  } catch {
    fail(`api-key が読めません (~/.buddyos/api-key)`);
    process.exit(1);
  }
}

const API_KEY = readApiKey();
const AUTH = { Authorization: `Bearer ${API_KEY}` };

const ok = (m) => console.log(`\x1b[32m✓\x1b[0m ${m}`);
const info = (m) => console.log(`  ${m}`);
function fail(m) {
  console.log(`\x1b[31m✗ ${m}\x1b[0m`);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// HTTP サーバが listen 済みか。listen 確立 = server.start() 完了の瞬間なので、
// 認証より手前で返る応答（無認証 /health は即 401）で判定する。
// /health は認証後に全エージェントを probe する重い経路なので、認証ヘッダは付けない。
// 「HTTP ステータスが返る」= バインド済み。接続拒否/タイムアウトのみ未 listen 扱い。
async function isListening(host = HOST) {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 2000);
    const res = await fetch(`http://${host}/health`, { signal: ctrl.signal });
    clearTimeout(t);
    return typeof res.status === "number"; // 200/401 いずれもサーバ稼働の証
  } catch {
    return false;
  }
}

// Phase 1 のテスト用 Bridge に渡す隔離ホーム。~/.buddyos を稼働中 Bridge と共有すると、
// 起動時の SpawnRegistry.sweepStaleProcesses() が稼働中 Bridge の agent プロセスグループを
// SIGTERM で殺し、bridge.port も TEST_PORT で上書きされたまま残る (ターミナル連携が死ぬ)。
// macOS の NSHomeDirectory() / homeDirectoryForCurrentUser は HOME を見ず
// CFFIXED_USER_HOME → passwd の順で解決するので、起動時に両方をここへ向ける。
// cron 出力ルートだけは実物へ symlink し、CronOutputHub の全走査コストを計測に残す
// (空ホームだと cron 初期化が起動経路に戻っても time-to-listen が膨れず回帰を見逃す)。
// CronOutputHub は出力ルートを読むだけで、書き込むのは隔離側の cron_pushed.json のみ。
function makeIsolatedHome() {
  const home = mkdtempSync(join(tmpdir(), "buddyos-e2e-home-"));
  for (const rel of [".hermes/cron/output", ".buddyos/cron/output"]) {
    const real = join(homedir(), rel);
    if (!existsSync(real)) continue;
    mkdirSync(dirname(join(home, rel)), { recursive: true });
    symlinkSync(real, join(home, rel));
  }
  return home;
}

// Phase 1: 起動速度 (server.start() 純粋レイテンシ)
// BridgeApp をテストポートで直接起動し、listen 確立までの経過を計測する。
// launchd 経由の zsh -lic ログインシェル初期化 (数秒) を挟まないので、
// cron 初期化が起動経路に戻った場合のみ数値が膨れる = Bug1 の純粋な回帰ガード。
async function testStartupSpeed() {
  console.log("── Phase 1: 起動速度 (server.start() time-to-listen) ──");
  if (SKIP_SPAWN) {
    info("--skip-spawn: 起動計測を省略");
    return true;
  }
  if (!existsSync(BRIDGE_BIN)) {
    fail(`BridgeApp が見つかりません: ${BRIDGE_BIN}（BRIDGE_BIN= で指定可）`);
    return false;
  }
  const testHost = `127.0.0.1:${TEST_PORT}`;
  const isoHome = makeIsolatedHome();
  const env = {
    ...process.env,
    HOME: isoHome,
    CFFIXED_USER_HOME: isoHome,
    BUDDYOS_BRIDGE_PORT: String(TEST_PORT),
  };
  // 同じ machineId での registry 登録 (本番の発見エントリを押しのけうる) をさせない
  delete env.BUDDYOS_CLERK_TOKEN;
  info(`直接起動: ${BRIDGE_BIN} (port ${TEST_PORT}, loopback, 隔離ホーム ${isoHome})`);
  const start = Date.now();
  const proc = spawn(BRIDGE_BIN, [], {
    env,
    stdio: "ignore",
    detached: true,
  });
  const exited = new Promise((r) => proc.once("exit", r));

  let elapsed = -1;
  const deadline = start + THRESHOLD_MS + 7000; // 計測自体は余裕を持つ
  while (Date.now() < deadline) {
    if (await isListening(testHost)) {
      elapsed = Date.now() - start;
      break;
    }
    await sleep(25);
  }

  // テストインスタンスを確実に停止 (プロセスグループごと)。SIGTERM ハンドラの
  // killAllRegistered (隔離ホームの記録のみ対象) が自分の子 (opencode prewarm 等) を
  // 回収できるよう終了を待ち、時間切れのときだけ SIGKILL にフォールバックする。
  try { process.kill(-proc.pid, "SIGTERM"); } catch {}
  const stopped = await Promise.race([exited.then(() => true), sleep(3000).then(() => false)]);
  if (!stopped) {
    try { process.kill(-proc.pid, "SIGKILL"); } catch {}
    await Promise.race([exited, sleep(1000)]);
  }
  // 取りこぼした子 (SIGKILL フォールバック時や、killAllRegistered の後に prewarm が
  // setpgid + register を済ませた競合) の記録は隔離ホームにしか無く、本番 Bridge の
  // sweep では回収されない。ホームを消す前に記録のグループを SIGTERM しておく
  // (記録はこの実行中のものだけなので pid 再利用はほぼ考えなくてよい)。
  // pid > 1 は SpawnRegistry と同じガード (-1 / -0 は全プロセス / 自グループ宛てになる)。
  try {
    const records = JSON.parse(readFileSync(join(isoHome, ".buddyos/spawned_pgids.json"), "utf8"));
    for (const key of Object.keys(records)) {
      const pid = Number(key);
      if (!Number.isInteger(pid) || pid <= 1) continue;
      try { process.kill(-pid, "SIGTERM"); } catch {}
    }
  } catch {}
  // symlink は辿らず削除される (実物の cron 出力は消えない)
  try { rmSync(isoHome, { recursive: true, force: true }); } catch {}

  if (elapsed < 0) {
    fail(`直接起動後 ${THRESHOLD_MS + 7000}ms 以内に listen しませんでした`);
    return false;
  }
  info(`time-to-listen = ${elapsed}ms (しきい値 ${THRESHOLD_MS}ms)`);
  if (elapsed <= THRESHOLD_MS) {
    ok(`server.start() が ${elapsed}ms で listen（cron 初期化が起動経路をブロックしていない）`);
    return true;
  }
  fail(`time-to-listen ${elapsed}ms がしきい値 ${THRESHOLD_MS}ms を超過。cron 初期化が起動経路に戻った疑い`);
  return false;
}

// Phase 2: cron 同期 RPC 往復
function testCronSync() {
  console.log("── Phase 2: cron 同期 RPC (list → list_end) ──");
  return new Promise((resolve) => {
    const url = `ws://${HOST}/ws/agent/${AGENT}`;
    const ws = new WebSocket(url, { headers: AUTH });
    let settled = false;
    const items = [];

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      fail(`${CRON_TIMEOUT_MS}ms 以内に cron_job_list_end が来ませんでした`);
      try { ws.close(); } catch {}
      resolve(false);
    }, CRON_TIMEOUT_MS);

    ws.addEventListener("open", () => {
      ws.send(JSON.stringify({ type: "list_cron_jobs_request", agentId: AGENT }));
    });

    ws.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data.toString()); } catch { return; }
      if (msg.type === "cron_job_item") {
        items.push(msg);
      } else if (msg.type === "cron_job_list_end") {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        ok(`cron_job_list_end 受信（既存ジョブ ${items.length} 件）`);
        try { ws.close(); } catch {}
        resolve(true);
      }
    });

    ws.addEventListener("error", (ev) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fail(`WS エラー: ${ev.message || ev.error || "unknown"}`);
      resolve(false);
    });
  });
}

(async () => {
  console.log(`\nBuddyOS Bridge startup E2E  host=${HOST} agent=${AGENT}\n`);
  const p1 = await testStartupSpeed();
  // listen 確立後に少しだけ猶予（asyncBoot 直後の adapter 初期化に余裕）
  await sleep(300);
  const p2 = await testCronSync();

  console.log("\n──────── 結果 ────────");
  console.log(`Phase 1 起動速度 : ${p1 ? "PASS" : "FAIL"}`);
  console.log(`Phase 2 cron同期 : ${p2 ? "PASS" : "FAIL"}`);
  const pass = p1 && p2;
  console.log(pass ? "\x1b[32m\nALL PASS\x1b[0m\n" : "\x1b[31m\nFAILED\x1b[0m\n");
  process.exit(pass ? 0 : 1);
})();
