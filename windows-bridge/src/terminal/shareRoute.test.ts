import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { WebSocket } from "ws";
import { routeAccess } from "../auth.js";
import { dropShareViewers, handleShareHostUpgrade, handleShareViewerUpgrade, sharePanes, shareTimeouts } from "./shareRoute.js";

type Msg = Record<string, unknown>;

test("ルートの表: 見る口は any、常駐プロセスの口はこの PC の中だけ、一覧は HTTP の any", () => {
  assert.equal(routeAccess("/terminal/share", true), "any");
  assert.equal(routeAccess("/terminal/share/host", true), "local");
  assert.equal(routeAccess("/terminal/share/panes", false), "any");
  assert.equal(routeAccess("/terminal/share", false), undefined);
  assert.equal(routeAccess("/terminal/share/host", false), undefined);
  assert.equal(routeAccess("/terminal/share/panes", true), undefined);
});

test("常駐プロセスと見る人の中継", async () => {
  shareTimeouts.hostWaitMs = 300;
  const server = http.createServer();
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (url.pathname === "/terminal/share/host") handleShareHostUpgrade(req, socket, head, url);
    // テストでは見る端末を ?as= で、その名前を ?name= で決める（本物は Principal から）。
    else handleShareViewerUpgrade(req, socket, head, url, url.searchParams.get("as") ?? "local", url.searchParams.get("name") ?? undefined);
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;

  const sockets: WebSocket[] = [];
  const connect = (path: string) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}${path}`);
    sockets.push(ws);
    ws.on("error", () => {});
    const box = { output: "", events: [] as Msg[], closed: false, code: 0 };
    ws.on("message", (data, isBinary) => {
      if (isBinary) box.output += String(data);
      else box.events.push(JSON.parse(String(data)));
    });
    ws.on("close", (code) => {
      box.closed = true;
      box.code = code;
    });
    return { ws, box };
  };
  const until = async (cond: () => boolean, ms = 5000) => {
    const end = Date.now() + ms;
    while (Date.now() < end && !cond()) await new Promise((r) => setTimeout(r, 20));
    return cond();
  };
  const opened = (ws: WebSocket) => until(() => ws.readyState === WebSocket.OPEN);
  const ev = (box: { events: Msg[] }, key: string, value: string) => box.events.filter((e) => e[key] === value);
  // 常駐プロセスの代わり。attach には写し付きで答える。
  const host = (client: string, ids: string[]) => {
    const h = connect(`/terminal/share/host?client=${client}`);
    h.ws.on("message", (data) => {
      const m = JSON.parse(String(data)) as Msg;
      if (m.t === "attach") h.ws.send(JSON.stringify({ t: "attached", sid: m.sid, cols: 100, rows: 30, snapshot: `SNAP:${m.id}` }));
    });
    h.ws.on("open", () => h.ws.send(JSON.stringify({ t: "panes", panes: ids.map((id) => ({ id, agentId: "claude", cols: 100, rows: 30 })) })));
    return h;
  };

  try {
    // 常駐プロセスがいなければ、待ってから gone。
    const lonely = connect("/terminal/share?pane=p1");
    assert.ok(await until(() => lonely.box.closed));
    assert.equal(ev(lonely.box, "type", "gone").length, 1);
    assert.deepEqual(sharePanes(), { available: false, panes: [] });

    // 見る人が先に来ても、panes が届けばつなぐ。
    const early = connect("/terminal/share?pane=p1&cols=90&rows=20");
    await opened(early.ws);
    const h = host("prod", ["p1", "p2"]);
    assert.ok(await until(() => ev(early.box, "type", "size").length === 1), JSON.stringify(early.box.events));
    assert.deepEqual(
      early.box.events.map((e) => e.type),
      ["attached", "replay", "size"]
    );
    assert.equal(early.box.events[1].data, "SNAP:p1");
    assert.deepEqual(early.box.events[2], { type: "size", cols: 100, rows: 30 });
    const attach = ev(h.box, "t", "attach")[0];
    assert.deepEqual(attach, { t: "attach", sid: attach.sid, id: "p1", cols: 90, rows: 20 });
    const sid = String(attach.sid);
    assert.match(sid, /^v\d+$/);

    // 入力・大きさは sid を付けて常駐プロセスへ。kill と知らない種類は捨てる。
    early.ws.send(JSON.stringify({ type: "kill" }));
    early.ws.send(JSON.stringify({ type: "bogus" }));
    early.ws.send(JSON.stringify({ type: "input", data: "ls\r" }));
    early.ws.send(JSON.stringify({ type: "resize", cols: 5000, rows: 1 }));
    assert.ok(await until(() => ev(h.box, "t", "resize").length === 1));
    assert.deepEqual(ev(h.box, "t", "input"), [{ t: "input", sid, data: "ls\r" }]);
    assert.deepEqual(ev(h.box, "t", "resize"), [{ t: "resize", sid, cols: 1000, rows: 2 }]);
    assert.equal(h.box.events.filter((e) => e.t !== "attach" && e.t !== "input" && e.t !== "resize").length, 0);

    // 出力はバイナリ（UTF-8）で。知らない sid は捨てる。
    h.ws.send(JSON.stringify({ t: "data", sid, data: "こんにちは" }));
    h.ws.send(JSON.stringify({ t: "data", sid: "v999999", data: "NOPE" }));
    assert.ok(await until(() => early.box.output.includes("こんにちは")));

    // 一覧: 見ている数と状態。
    const list = sharePanes((p) => (p === "p1" ? "working" : undefined));
    assert.equal(list.available, true);
    assert.deepEqual(list.panes, [
      { id: "p1", agentId: "claude", cols: 100, rows: 30, viewers: 1, state: "working" },
      { id: "p2", agentId: "claude", cols: 100, rows: 30, viewers: 0 }
    ]);

    // 違う client は並べて持ち、見る人はペインを持つ方へ。
    const dev = host("dev", ["d1"]);
    const onDev = connect("/terminal/share?pane=d1&name=MacBook");
    assert.ok(await until(() => ev(onDev.box, "type", "size").length === 1));
    assert.equal(ev(dev.box, "t", "attach").length, 1);
    // 見ている端末の名前は attach に載せる（B の画面に「○○ が見ています」と出す）。
    assert.equal(ev(dev.box, "t", "attach")[0].name, "MacBook");
    assert.equal(sharePanes().panes.length, 3);

    // 見る人が閉じたら detach。
    early.ws.close();
    assert.ok(await until(() => ev(h.box, "t", "detach").length === 1));
    assert.deepEqual(ev(h.box, "t", "detach")[0], { t: "detach", sid });

    // exit は A へ送って閉じる。
    const second = connect("/terminal/share?pane=p2");
    assert.ok(await until(() => ev(second.box, "type", "attached").length === 1));
    const sid2 = String(ev(h.box, "t", "attach").at(-1)?.sid);
    h.ws.send(JSON.stringify({ t: "exit", sid: sid2, code: 3 }));
    assert.ok(await until(() => second.box.closed));
    assert.deepEqual(ev(second.box, "type", "exit"), [{ type: "exit", code: 3 }]);

    // 端末を外したら、その端末が見ているものだけ切る。
    const gone = connect("/terminal/share?pane=p1&as=device:gone");
    const kept = connect("/terminal/share?pane=p2&as=device:kept");
    assert.ok(await until(() => ev(gone.box, "type", "attached").length === 1 && ev(kept.box, "type", "attached").length === 1));
    dropShareViewers("device:gone");
    assert.ok(await until(() => gone.box.closed));
    assert.deepEqual(ev(gone.box, "type", "exit"), [{ type: "exit", code: -1 }]);
    assert.equal(kept.box.closed, false);

    // 同じ client で新しくつながったら、古い方を 4000 で閉じ、古い方の見る人も切る（ほかの client はそのまま）。
    const h2 = host("prod", ["p1"]);
    assert.ok(await until(() => h.box.closed && kept.box.closed));
    assert.equal(h.box.code, 4000);
    assert.equal(onDev.box.closed, false);
    await opened(h2.ws);

    // 常駐プロセスが切れたら、そこの見る人を全部閉じる。
    dev.ws.close();
    assert.ok(await until(() => onDev.box.closed));
    assert.equal(ev(onDev.box, "type", "gone").length, 0);
  } finally {
    for (const ws of sockets) ws.terminate();
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
  }
});

test("送りきれないときは捨て、追いついたら写しを頼み直す", async () => {
  const server = http.createServer();
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://localhost");
    if (url.pathname === "/terminal/share/host") handleShareHostUpgrade(req, socket, head, url);
    else handleShareViewerUpgrade(req, socket, head, url, "local");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const port = (server.address() as { port: number }).port;
  const until = async (cond: () => boolean, ms = 20000) => {
    const end = Date.now() + ms;
    while (Date.now() < end && !cond()) await new Promise((r) => setTimeout(r, 20));
    return cond();
  };
  const host = new WebSocket(`ws://127.0.0.1:${port}/terminal/share/host?client=lag`);
  const hostEvents: Msg[] = [];
  host.on("message", (data) => {
    const m = JSON.parse(String(data)) as Msg;
    hostEvents.push(m);
    if (m.t === "attach") host.send(JSON.stringify({ t: "attached", sid: m.sid, cols: 80, rows: 24, snapshot: "" }));
  });
  await new Promise((r) => host.on("open", r));
  host.send(JSON.stringify({ t: "panes", panes: [{ id: "big", cols: 80, rows: 24 }] }));
  const viewer = new WebSocket(`ws://127.0.0.1:${port}/terminal/share?pane=big`);
  let received = 0;
  let output = "";
  const events: Msg[] = [];
  viewer.on("message", (data, isBinary) => {
    if (isBinary) {
      received += (data as Buffer).length;
      output += String(data).slice(-64);
    } else events.push(JSON.parse(String(data)));
  });
  try {
    assert.ok(await until(() => events.some((e) => e.type === "size")));
    const sid = String(hostEvents.find((e) => e.t === "attach")?.sid);
    // 見る人が読むのを止めている間に、たくさん出力する（Bridge は溜めずに捨てる）。
    const socket = (viewer as unknown as { _socket: { pause(): void; resume(): void } })._socket;
    socket.pause();
    const chunk = "a".repeat(256 * 1024);
    const total = 64 * chunk.length;
    for (let i = 0; i < 64; i++) host.send(JSON.stringify({ t: "data", sid, data: chunk }));
    assert.ok(await until(() => host.bufferedAmount === 0));
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(hostEvents.filter((e) => e.t === "resync").length, 0);
    socket.resume();
    assert.ok(await until(() => hostEvents.some((e) => e.t === "resync")), "resync が来ない");
    assert.deepEqual(hostEvents.find((e) => e.t === "resync"), { t: "resync", sid });
    // replay までの出力は捨てる（写しに含まれる）。
    host.send(JSON.stringify({ t: "data", sid, data: "DROPPED" }));
    host.send(JSON.stringify({ t: "replay", sid, cols: 81, rows: 25, snapshot: "SNAPSHOT" }));
    host.send(JSON.stringify({ t: "data", sid, data: "AFTER" }));
    assert.ok(await until(() => output.includes("AFTER")));
    assert.ok(!output.includes("DROPPED"));
    assert.ok(received < total, `${received} >= ${total}`);
    assert.deepEqual(events.filter((e) => e.type !== "attached").slice(-2), [
      { type: "replay", data: "SNAPSHOT" },
      { type: "size", cols: 81, rows: 25 }
    ]);
    assert.equal(hostEvents.filter((e) => e.t === "resync").length, 1);
  } finally {
    viewer.terminate();
    host.terminate();
    server.closeAllConnections();
    await new Promise<void>((r) => server.close(() => r()));
  }
});
