// Run from the repository root:
//   node scripts/paseo-health-check.mts --relay wss://relay.example.com/ws   # 中継を通して、この Mac の Bridge のトンネル（v3）が答えるか
//   BUDDYOS_PASEO_RELAY_URL=wss://relay.example.com/ws node scripts/paseo-health-check.mts   # 同じ（環境変数で指定）
//   node scripts/paseo-health-check.mts --self-test # shared/e2e-test-vectors.json（v1 と tunnelV3・pairingV3）を確かめる
// 中継は --relay <url>（または最初の引数）、無ければ BUDDYOS_PASEO_RELAY_URL。どちらも無ければ止まる（既定の中継は持たない）。
//
// 端末認証 v3（spec/PROTOCOL-v3.md §8・§10.2）: 一覧に無い端末はトンネルの入口で断られる。
// ここではその場で作った（登録していない）鍵で握手し、Bridge の鍵で認証された msg2 が
// `{"ok":false,"error":"unknown_device"}` なら「Bridge のトンネルは動いている」とみなす。端末は登録されない。
// 資格情報・鍵・ペアリングの URL は表示しない。
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import assert from "node:assert/strict";
import { PROLOGUE, b64u, b64uDecodeStrict, initiatorWrite1, initiatorRead2 } from "../shared/tools/tunnelV3Ref.mts";

async function selfTest() {
  execFileSync(process.execPath, [new URL("../shared/tools/check-tunnel-v3.mts", import.meta.url).pathname], { stdio: "inherit" });
  console.log("PASS: shared tunnel v3 vectors");
}

/** 中継の URL: --relay <url> か最初の引数 → BUDDYOS_PASEO_RELAY_URL。 */
function relayArg(): string {
  const args = process.argv.slice(2);
  const i = args.indexOf("--relay");
  const fromArg = i >= 0 ? args[i + 1] : args.find((a) => !a.startsWith("--"));
  const relay = (fromArg || process.env.BUDDYOS_PASEO_RELAY_URL || "").trim();
  if (!relay) throw new Error("No relay given. Use --relay wss://<your relay>/ws or set BUDDYOS_PASEO_RELAY_URL");
  return relay;
}

async function check() {
  const root = join(homedir(), ".buddyos");
  const localKey = (await readFile(join(root, "api-key"), "utf8")).trim();
  const bridgeId = (await readFile(join(root, "bridge-id"), "utf8")).trim();
  const serverId = (await readFile(join(root, "paseo-relay-id"), "utf8")).trim();
  const port = Number((await readFile(join(root, "bridge.port"), "utf8")).trim());
  assert(Number.isInteger(port) && port > 0 && port < 65536, "Invalid Bridge port");
  assert(localKey && !/[\r\n]/.test(localKey), "Invalid local key");
  assert(serverId, "Missing Paseo relay identity");
  // この PC の中からはローカル鍵で /health を引ける（トンネル越しでは使えない）。
  const localResponse = await fetch(`http://127.0.0.1:${port}/health`, {
    headers: { Authorization: `Bearer ${localKey}` }, signal: AbortSignal.timeout(5000)
  });
  assert.equal(localResponse.status, 200, "Local Bridge health failed");
  const local = await localResponse.json() as { ok: boolean; bridgeId: string; e2e?: { pub?: string }; features?: string[] };
  assert.equal(local.bridgeId, bridgeId, "Port belongs to another Bridge");
  assert(local.features?.includes("auth-v3"), "Bridge does not speak device auth v3 (update BuddyOS)");
  const bridgePublic = b64uDecodeStrict(local.e2e?.pub ?? "", 32);
  assert(bridgePublic, "Invalid Bridge public key");

  const endpoint = new URL(relayArg());
  assert.equal(endpoint.protocol, "wss:", "Relay must use TLS");
  // v=2 は Paseo の中継の版（トンネルの v3 とは関係ない）。
  for (const [key, value] of Object.entries({ v: "2", role: "client", serverId, connectionId: randomUUID() })) {
    endpoint.searchParams.set(key, value);
  }
  const ini = { prologue: PROLOGUE, sI: randomBytes(32), eI: randomBytes(32), sRpub: bridgePublic, psk: Buffer.alloc(32) };
  const payload1 = Buffer.from(JSON.stringify({ mode: "connect", deviceId: `paseo-check-${randomUUID().slice(0, 8)}`, platform: "mac", app: "health-check" }));
  const m1 = initiatorWrite1(ini, payload1);
  const init = JSON.stringify({ type: "buddyos_tunnel_init", v: 3, e: b64u(m1.ePub), s: b64u(m1.sPubCt), p: b64u(m1.payloadCt) });
  const socket = new WebSocket(endpoint);
  let retry: ReturnType<typeof setInterval> | undefined;
  let stage = "relay connection";
  try {
    const answer = await new Promise<{ ok: boolean; error?: string }>((resolve, reject) => {
      const deadline = setTimeout(() => reject(new Error(`Timed out during ${stage}`)), 25000);
      const finish = (error?: Error, value?: { ok: boolean; error?: string }) => {
        clearTimeout(deadline);
        if (retry) clearInterval(retry);
        error ? reject(error) : resolve(value!);
      };
      socket.addEventListener("open", () => {
        stage = "v3 handshake";
        socket.send(init);
        // 中継が Bridge 側をつなぐまで、同じバイト列を 350 ms ごとに送り直す（spec/PROTOCOL-v3.md §8.10）。
        retry = setInterval(() => { if (socket.readyState === WebSocket.OPEN) socket.send(init); }, 350);
      });
      socket.addEventListener("error", () => finish(new Error(`WebSocket failed during ${stage}`)));
      socket.addEventListener("close", () => finish(new Error(`Connection closed before msg2 during ${stage}`)));
      socket.addEventListener("message", (event) => {
        try {
          if (typeof event.data !== "string") return;
          const msg = JSON.parse(event.data);
          if (msg.type === "buddyos_tunnel_error") throw new Error(`Bridge answered tunnel error: ${msg.code}`);
          if (msg.type !== "buddyos_tunnel_hello" || msg.v !== 3) return;
          const e = b64uDecodeStrict(msg.e, 32);
          const p = b64uDecodeStrict(msg.p);
          assert(e && p && p.length >= 16, "Invalid msg2");
          // msg2 が開ける = この Mac の Bridge の鍵で認証された答え。
          const r = initiatorRead2(ini, m1.st, e, p);
          finish(undefined, JSON.parse(r.payload.toString("utf8")));
        } catch (error) { finish(error instanceof Error ? error : new Error("Invalid relay response")); }
      });
    });
    assert.equal(answer.ok, false, "Bridge accepted an unregistered key (should never happen)");
    assert.equal(answer.error, "unknown_device", `Unexpected answer: ${answer.error}`);
    console.log("PASS: the relay reached this Mac's Bridge and its v3 tunnel answered (unregistered key → unknown_device)");
    console.log("Next: pair a device with a new QR code and test over cellular data.");
  } finally {
    if (retry) clearInterval(retry);
    socket.close();
  }
}

try {
  if (process.argv.includes("--self-test")) await selfTest();
  else await check();
} catch (error) {
  // Do not dump fetch/WebSocket objects, request headers, or pairing URLs.
  console.error(`Paseo check failed: ${error instanceof Error ? error.message : "unknown error"}`);
  process.exitCode = 1;
}
