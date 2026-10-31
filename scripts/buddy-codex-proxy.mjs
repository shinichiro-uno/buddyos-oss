#!/usr/bin/env node
// buddy-codex の中継。Codex TUI（codex --remote）と共有 app-server の間に挟まり、
// TUI がいま開いている thread を BuddyOS Bridge に知らせる（iPhone の一覧の緑の印）。
//
// 通信は素通し（TCP をそのまま流す）。サーバ → TUI 方向だけ WebSocket フレームを読んで、
// thread/start・thread/resume・thread/fork の応答 {"result":{"thread":{"id":…}}} を拾う。
// アプリ内ターミナルのペイン（環境の BUDDYOS_PANE_ID）で動いているときは、その thread のターンの始まり・終わりと
// 返事の文も /terminal/pane-event で知らせる（音声会話の読み上げ。docs/TERMINAL_VOICE_2026-10-19.md §4）。
// 認証（Authorization: Bearer）は TUI のものをそのまま app-server に渡すので、
// この中継を挟んでも認証は弱くならない。permessage-deflate は交渉させない（中身を読むため）。
//
//   node buddy-codex-proxy.mjs <upstreamPort> <tuiPid> <portFile>
//
// 待ち受けポートを <portFile> に書く。<tuiPid> が消えたら closed を送って終了する。
// 依存は Node 標準のみ。
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';

const [upstreamPort, tuiPid, portFile] = process.argv.slice(2);
const HOME = os.homedir();
const readFile = (p) => { try { return fs.readFileSync(p, 'utf8').trim(); } catch { return ''; } };
const apiKey = readFile(path.join(HOME, '.buddyos', 'api-key'));
const cwd = process.env.BUDDY_CODEX_CWD || process.cwd();

let currentThread = null;
// TUI → サーバの要求 id → method。thread/read 等の応答にも result.thread が入るので、
// 開く系の要求への応答だけを拾うために使う。
const OPENING = new Set(['thread/start', 'thread/resume', 'thread/fork']);
const pendingOpen = new Set();

function onClientMessage(text) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }
  if (msg && msg.id !== undefined && OPENING.has(msg.method)) pendingOpen.add(msg.id);
}

// 動いている Bridge の待ち受け番号（送るたびに確かめる）。bridge.port が無い、または bridge.pid の
// プロセス（自分のもの）がその番号で待ち受けていなければ ''（何も送らない）。決め打ちの 8765 には送らない
// （Bridge が止まっている間にその番号を先に取った別のプロセスへ鍵が渡る）。
function bridgePort() {
  const port = readFile(path.join(HOME, '.buddyos', 'bridge.port'));
  const pid = readFile(path.join(HOME, '.buddyos', 'bridge.pid'));
  if (!/^\d+$/.test(port) || !/^[1-9]\d*$/.test(pid)) return Promise.resolve('');
  try { process.kill(Number(pid), 0); } catch { return Promise.resolve(''); }
  return new Promise((resolve) => {
    execFile('/usr/sbin/lsof', ['-nP', '-a', '-p', pid, `-iTCP:${port}`, '-sTCP:LISTEN', '-t'], { timeout: 3000 },
      (_err, stdout) => resolve(String(stdout || '').split(/\s+/).includes(pid) ? port : ''));
  });
}

async function notify(threadId, state) {
  if (!apiKey || !threadId) return;
  const port = await bridgePort();
  if (!port) return;
  try {
    await fetch(`http://127.0.0.1:${port}/codex/terminal`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ thread_id: threadId, cwd, state }),
      signal: AbortSignal.timeout(3000),
    });
  } catch { /* Bridge が落ちていても TUI は止めない。次の送り直しで戻る */ }
}

// ペインの状態（/terminal/pane-event）。BUDDYOS_PANE_ID が無い・形が違うときは何も送らない。
// 送るのは 1 本ずつ順に（working より先に done が届かないように）。待たずに積むだけなので TUI の流れは止めない。
const PANE_ID = /^[A-Za-z0-9_-]{1,64}$/.test(process.env.BUDDYOS_PANE_ID || '') ? process.env.BUDDYOS_PANE_ID : '';
const REPLY_MAX = 16000; // Bridge も 16,000 字で切る（本文の上限 64KB に収める）
let paneQueue = Promise.resolve();
let paneReply = '';
let paneBusy = false;

function paneEvent(state, threadId, reply) {
  if (!PANE_ID || !apiKey || !threadId) return paneQueue;
  const body = { pane: PANE_ID, agent: 'codex', state, sessionId: threadId, cwd };
  if (reply) body.reply = reply.slice(0, REPLY_MAX);
  paneQueue = paneQueue.then(async () => {
    const port = await bridgePort();
    if (!port) return;
    await fetch(`http://127.0.0.1:${port}/terminal/pane-event`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(3000),
    });
  }).catch(() => { /* Bridge が落ちていても TUI は止めない */ });
  return paneQueue;
}

// サーバ → TUI の通知（id の無いもの）。今開いている thread のものだけを見る。
//   turn/started → working / item/completed の agentMessage → 文を覚える（ターンの最後のもの）
//   turn/completed → done + 返事の文（status が failed なら error、interrupted（Esc で中断）なら idle）
function onPaneNotification(msg) {
  const p = msg.params;
  if (!PANE_ID || !currentThread || !p || typeof p !== 'object') return;
  const tid = typeof p.threadId === 'string' ? p.threadId : (p.thread && p.thread.id);
  if (tid !== currentThread) return;
  if (msg.method === 'turn/started') {
    paneReply = '';
    paneBusy = true;
    paneEvent('working', tid);
  } else if (msg.method === 'item/completed') {
    const item = p.item;
    if (item && item.type === 'agentMessage' && typeof item.text === 'string' && item.text) paneReply = item.text;
  } else if (msg.method === 'turn/completed') {
    const status = p.turn && p.turn.status;
    const reply = paneReply;
    paneReply = '';
    paneBusy = false;
    if (status === 'failed') paneEvent('error', tid);
    else if (status === 'interrupted') paneEvent('idle', tid);
    else paneEvent('done', tid, reply);
  }
}

function setThread(id) {
  if (!id || id === currentThread) return;
  const prev = currentThread;
  currentThread = id;
  // ターンの途中で別の thread に移ったら、前のペインの「作業中」を戻す。
  if (prev && paneBusy) paneEvent('idle', prev);
  paneReply = '';
  paneBusy = false;
  if (prev) notify(prev, 'closed');
  notify(id, 'open');
}

function onServerMessage(text) {
  let msg;
  try { msg = JSON.parse(text); } catch { return; }
  if (!msg) return;
  if (msg.id === undefined) {
    if (typeof msg.method === 'string') onPaneNotification(msg);
    return;
  }
  // 開く系の要求への応答だけを見る。thread/started 通知は他の接続の thread も流れてくるので使わない。
  if (!pendingOpen.has(msg.id)) return;
  pendingOpen.delete(msg.id);
  if (msg.result && msg.result.thread && typeof msg.result.thread.id === 'string') {
    setThread(msg.result.thread.id);
  }
}

// WebSocket フレームを読む最小パーサ（TUI → サーバはマスク付き、サーバ → TUI はマスク無し）。
function frameReader(onText) {
  let buf = Buffer.alloc(0);
  let frag = [];
  return (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      if (buf.length < 2) return;
      const fin = (buf[0] & 0x80) !== 0;
      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f;
      let off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      if (masked) off += 4;
      if (buf.length < off + len) return;
      let payload = buf.subarray(off, off + len);
      if (masked) {
        const key = buf.subarray(off - 4, off);
        payload = Buffer.from(payload.map((b, i) => b ^ key[i % 4]));
      }
      buf = buf.subarray(off + len);
      if (opcode === 0x1 || opcode === 0x0) {
        frag.push(payload);
        if (fin) { onText(Buffer.concat(frag).toString('utf8')); frag = []; }
      }
    }
  };
}

const server = net.createServer((client) => {
  let head = Buffer.alloc(0);
  let upstream = null;
  const readClient = frameReader(onClientMessage);
  const onClientData = (chunk) => {
    if (upstream) { upstream.write(chunk); readClient(chunk); return; }
    head = Buffer.concat([head, chunk]);
    const end = head.indexOf('\r\n\r\n');
    if (end < 0) return;
    // ハンドシェイクから圧縮の交渉だけ外す（フレームの中身を平文で読むため）。
    const lines = head.subarray(0, end).toString('latin1').split('\r\n')
      .filter((l) => !/^sec-websocket-extensions:/i.test(l));
    const rest = head.subarray(end + 4);
    // 接続完了前の write は順番どおりに溜まるので、ハンドシェイクを先頭に積んでおく。
    upstream = net.connect(Number(upstreamPort), '127.0.0.1');
    upstream.write(lines.join('\r\n') + '\r\n\r\n');
    if (rest.length) upstream.write(rest);
    if (rest.length) readClient(rest);
    let handshakeDone = false;
    let resp = Buffer.alloc(0);
    const read = frameReader(onServerMessage);
    upstream.on('data', (d) => {
      client.write(d);
      if (handshakeDone) { read(d); return; }
      resp = Buffer.concat([resp, d]);
      const e = resp.indexOf('\r\n\r\n');
      if (e >= 0) { handshakeDone = true; const after = resp.subarray(e + 4); if (after.length) read(after); }
    });
    upstream.on('close', () => client.destroy());
    upstream.on('error', () => client.destroy());
  };
  client.on('data', onClientData);
  client.on('close', () => upstream && upstream.destroy());
  client.on('error', () => upstream && upstream.destroy());
});

server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(portFile, String(server.address().port));
});

// 送り直し（Bridge の再起動に備える）。
setInterval(() => { if (currentThread) notify(currentThread, 'open'); }, 15000);

// TUI の終了検知。ターミナルのウィンドウを閉じると SIGHUP が来るが、Node は nohup の
// 無視を引き継がずに落ちる（実測）。無視して、TUI が消えたのを確かめてから closed を送る。
let exiting = false;
function exitWithClose() {
  if (exiting) return;
  exiting = true;
  const last = currentThread;
  currentThread = null;
  // ターンの途中で TUI が終わったら、ペインの「作業中」を戻してから終わる。
  const pane = last && paneBusy ? paneEvent('idle', last) : null;
  Promise.allSettled([last && notify(last, 'closed'), pane]).finally(() => process.exit(0));
}
process.on('SIGHUP', () => {});
process.on('SIGTERM', exitWithClose);
process.on('SIGINT', exitWithClose);
setInterval(() => {
  try { process.kill(Number(tuiPid), 0); } catch { exitWithClose(); }
}, 1000);
