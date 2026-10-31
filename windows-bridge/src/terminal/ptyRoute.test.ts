import assert from "node:assert/strict";
import http from "node:http";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { WebSocket } from "ws";

// 端末の部品は、Bridge を起動するデスクトップアプリが同梱しているものを使う。手元ではリポジトリの desktop のものを借りる。
const here = path.dirname(fileURLToPath(import.meta.url));
const desktopPty = path.resolve(here, "../../../desktop/node_modules/node-pty");
if (!process.env.BUDDYOS_NODE_PTY && existsSync(desktopPty)) process.env.BUDDYOS_NODE_PTY = desktopPty;
const { Scrollback, dropPtySessions, handlePtyUpgrade, isInheritedMarker, isSecretEnv, mergeWinPath, ptyAvailable, startCommand } = await import("./ptyRoute.js");

// 読み込めても起動できないことがある（入れ方によって spawn-helper に実行の権限が付かない等）。そのときは本物の端末のテストを飛ばす。
function ptySkipReason(): string | false {
  if (process.platform === "win32") return "Windows では動かさない";
  if (!ptyAvailable()) return "node-pty が無い";
  try {
    const pty = createRequire(import.meta.url)(process.env.BUDDYOS_NODE_PTY || "node-pty") as {
      spawn(file: string, args: string[], opts: Record<string, unknown>): { kill(): void };
    };
    const p = pty.spawn("/bin/sh", ["-c", "exit 0"], { cols: 20, rows: 5 });
    try {
      p.kill();
    } catch {
      // すぐ終わるので、もう居なくてよい
    }
    return false;
  } catch (e) {
    return `node-pty で端末を起動できない（${e instanceof Error ? e.message : String(e)}）`;
  }
}

test("シェルに渡さない印: 子のセッションの印は消し、利用者の設定は残す", () => {
  for (const k of ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "ELECTRON_RUN_AS_NODE", "BUDDYOS_BRIDGE_PORT"]) {
    assert.equal(isInheritedMarker(k), true, k);
  }
  for (const k of ["CLAUDE_CODE_GIT_BASH_PATH", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_MAX_OUTPUT_TOKENS", "PATH"]) {
    assert.equal(isInheritedMarker(k), false, k);
  }
  // 秘密は渡さない（mac-bridge の ChildEnvironment と同じ）。
  for (const k of ["BUDDYOS_CLERK_TOKEN", "OPENCODE_SERVER_PASSWORD", "BUDDYOS_MCP_GITHUB"]) assert.equal(isSecretEnv(k), true, k);
  assert.equal(isSecretEnv("BUDDYOS_PANE_ID"), false);
});

test("PATH の読み直し: Bridge が足した項目を前に、レジストリの項目を後ろに（重なりは 1 つ）", () => {
  assert.equal(
    mergeWinPath("C:\\node;C:\\WINDOWS\\system32\\;C:\\old", ["C:\\Windows\\System32", "C:\\Users\\u\\AppData\\Roaming\\npm"]),
    "C:\\node;C:\\old;C:\\Windows\\System32;C:\\Users\\u\\AppData\\Roaming\\npm"
  );
});

test("起動するコマンド: 指定・再開・既定", () => {
  assert.equal(startCommand(new URLSearchParams("command=ls%20-la")), "ls -la");
  assert.equal(startCommand(new URLSearchParams("command=a%0Ab&agentId=claude")), "claude");
  assert.match(startCommand(new URLSearchParams("agentId=claude&resumeSessionId=abc-1")) ?? "", /^claude --resume .abc-1.$/);
  assert.equal(startCommand(new URLSearchParams("agentId=claude&resumeSessionId=bad;rm")), "claude");
  assert.equal(startCommand(new URLSearchParams("agentId=antigravity")), "agy");
  assert.equal(startCommand(new URLSearchParams("")), null);
});

test("直近の出力: バイト数で切り、文字の途中・行の途中から送り直さない", () => {
  const sb = new Scrollback(16);
  sb.push("abc\n");
  assert.equal(sb.text(), "abc\n");
  sb.push("あいう\nえお");
  // 4 + 10 + 6 = 20 バイト。先頭を 4 バイト以上切るので、切った行の残り（「あいう」の行）は送らない。
  assert.ok(sb.size <= 16);
  assert.equal(sb.text(), "えお");
  const one = new Scrollback(5);
  one.push("ああ");
  // 6 バイトを 5 バイトに切ると「あ」の途中になるので、次の文字の頭から。
  assert.equal(one.text(), "あ");
});

test("本物の端末: 入力・大きさ・つなぎ直し・終了", { skip: ptySkipReason() }, async () => {
  const server = http.createServer();
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    // テストでは開いた端末を ?as= で決める（本物は Principal から）。
    handlePtyUpgrade(req, socket, head, url, url.searchParams.get("as") ?? "local");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;

  const sockets: WebSocket[] = [];
  const open = (query: string) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}/terminal/pty?${query}`);
    sockets.push(ws);
    ws.on("error", () => {});
    const box = { output: "", events: [] as Array<Record<string, unknown>> };
    ws.on("message", (data, isBinary) => {
      if (isBinary) box.output += String(data);
      else {
        const msg = JSON.parse(String(data));
        box.events.push(msg);
        if (msg.type === "replay") box.output += msg.data;
      }
    });
    return { ws, box };
  };
  const until = async (cond: () => boolean, ms = 15000) => {
    const end = Date.now() + ms;
    while (Date.now() < end && !cond()) await new Promise((r) => setTimeout(r, 50));
    return cond();
  };
  const ev = (box: { events: Array<Record<string, unknown>> }, type: string) => box.events.find((e) => e.type === type);

  try {
    const id = `t-${Date.now()}`;
    const a = open(`id=${id}&cols=100&rows=30`);
    assert.ok(await until(() => !!ev(a.box, "attached")), JSON.stringify(a.box.events));
    assert.equal(ev(a.box, "attached")?.restored, false);
    a.ws.send(JSON.stringify({ type: "input", data: "echo BUDDY_$((40+2))\r" }));
    assert.ok(await until(() => a.box.output.includes("BUDDY_42")), a.box.output.slice(-300));
    a.ws.send(JSON.stringify({ type: "resize", cols: 123, rows: 40 }));
    a.ws.send(JSON.stringify({ type: "input", data: "echo COLS_$(tput cols)\r" }));
    assert.ok(await until(() => a.box.output.includes("COLS_123")), a.box.output.slice(-300));
    a.ws.close();

    // ほかの端末からは、同じ id でもつながらない。
    const other = open(`id=${id}&attach=1&as=device:other`);
    assert.ok(await until(() => !!ev(other.box, "gone"), 5000));

    const b = open(`id=${id}&attach=1`);
    assert.ok(await until(() => !!ev(b.box, "attached")));
    assert.equal(ev(b.box, "attached")?.restored, true);
    assert.ok(b.box.output.includes("BUDDY_42"));
    b.ws.send(JSON.stringify({ type: "kill" }));
    assert.ok(await until(() => !!ev(b.box, "exit"), 10000));

    const c = open(`id=${id}&attach=1`);
    assert.ok(await until(() => !!ev(c.box, "gone"), 5000));

    // 端末を外したら、その端末が開いたターミナルは止まる（ほかの端末のものは残る）。
    const d = open(`id=${id}-d&as=device:gone`);
    const e = open(`id=${id}-e&as=device:kept`);
    assert.ok(await until(() => !!ev(d.box, "attached") && !!ev(e.box, "attached")));
    dropPtySessions("device:gone");
    assert.ok(await until(() => !!ev(d.box, "exit"), 5000));
    const d2 = open(`id=${id}-d&attach=1&as=device:gone`);
    assert.ok(await until(() => !!ev(d2.box, "gone"), 5000));
    assert.equal(ev(e.box, "exit"), undefined);

    // 大量の出力でも、送りきるのを待って読みを止め・再開し、最後まで届く（固まらない）。
    const f = open(`id=${id}-f`);
    assert.ok(await until(() => !!ev(f.box, "attached")));
    f.ws.send(JSON.stringify({ type: "input", data: "head -c 8000000 /dev/zero | tr '\\0' a; echo; echo HEAVY_$((40+2))\r" }));
    assert.ok(await until(() => f.box.output.includes("HEAVY_42"), 60000), f.box.output.slice(-200));
  } finally {
    // 途中で失敗しても、端末と待ち受けを残してテストの実行が終わらなくならないように片付ける。
    for (const ws of sockets) {
      if (ws.readyState !== WebSocket.OPEN) continue;
      ws.send(JSON.stringify({ type: "kill" }));
      ws.close();
    }
    await until(() => sockets.every((ws) => ws.readyState === WebSocket.CLOSED), 3000);
    for (const ws of sockets) ws.terminate();
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
  }
});
