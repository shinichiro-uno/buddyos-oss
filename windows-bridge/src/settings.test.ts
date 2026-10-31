import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, test } from "node:test";

import { openRouterHeaders } from "./agents/buddy.js";
import { BridgeIdentity } from "./identity.js";
import { OFFICIAL_DEFAULTS, type OfficialDefaults } from "./officialDefaults.js";
import { PushService } from "./pushService.js";
import { BridgeRegistry } from "./registry.js";
import { describeSettings, resolveClaudeUsage, resolveOpenRouterReferer, resolvePushMode, resolveRelayURL } from "./settings.js";

// 設定の読み方（環境変数 → officialDefaults.ts → 無し）。公式版・公開版のどちらの officialDefaults.ts でも通るように、
// 既定値はテストの中で差し込む。

const root = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-settings-"));
after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const EMPTY: OfficialDefaults = {
  edition: "oss",
  convexSite: "",
  paseoRelayURL: "",
  pushMode: "none",
  claudeUsage: "off",
  openRouterReferer: ""
};
const FULL: OfficialDefaults = {
  edition: "official",
  convexSite: "https://registry.example.com",
  paseoRelayURL: "wss://relay.example.com/ws",
  pushMode: "convex",
  claudeUsage: "on",
  openRouterReferer: "https://app.example.com"
};

test("既定の値は officialDefaults.ts から読む（形は公式版・公開版で同じ）", () => {
  assert.deepEqual(Object.keys(OFFICIAL_DEFAULTS).sort(), Object.keys(EMPTY).sort());
  assert.equal(resolveRelayURL({}).value, OFFICIAL_DEFAULTS.paseoRelayURL);
  assert.equal(resolveClaudeUsage({}).value, OFFICIAL_DEFAULTS.claudeUsage === "on");
});

test("中継: 環境変数が一番強く、無ければ既定値、どちらも無ければ空", () => {
  assert.deepEqual(resolveRelayURL({}, FULL), { value: "wss://relay.example.com/ws", source: "default" });
  assert.deepEqual(resolveRelayURL({ BUDDYOS_PASEO_RELAY_URL: " wss://relay.example.com/x " }, FULL), { value: "wss://relay.example.com/x", source: "env" });
  assert.deepEqual(resolveRelayURL({}, EMPTY), { value: "", source: "none" });
});

test("通知: BUDDYOS_PUSH_MODE → 自前の relay の指定 → 既定値。apns-direct は Windows では使わない", () => {
  assert.deepEqual(resolvePushMode({}, FULL), { value: "convex", source: "default", ignored: undefined });
  assert.deepEqual(resolvePushMode({}, EMPTY), { value: "none", source: "default", ignored: undefined });
  assert.deepEqual(resolvePushMode({ BUDDYOS_PUSH_MODE: "none" }, FULL), { value: "none", source: "env" });
  assert.deepEqual(resolvePushMode({ BUDDYOS_PUSH_MODE: "Convex" }, EMPTY), { value: "convex", source: "env" });
  assert.deepEqual(resolvePushMode({ BUDDYOS_PUSH_RELAY_URL: "https://push.example.com", BUDDYOS_PUSH_RELAY_TOKEN: "t" }, EMPTY), {
    value: "convex",
    source: "env",
    ignored: undefined
  });
  assert.deepEqual(resolvePushMode({ BUDDYOS_PUSH_MODE: "apns-direct" }, EMPTY), { value: "none", source: "default", ignored: "apns-direct" });
  assert.deepEqual(resolvePushMode({ BUDDYOS_PUSH_MODE: "apns-direct" }, FULL), { value: "convex", source: "default", ignored: "apns-direct" });
});

test("通知: none なら自前の relay の指定があっても送らない", async () => {
  const saved = { url: process.env.BUDDYOS_PUSH_RELAY_URL, token: process.env.BUDDYOS_PUSH_RELAY_TOKEN };
  process.env.BUDDYOS_PUSH_RELAY_URL = "https://push.example.com/push";
  process.env.BUDDYOS_PUSH_RELAY_TOKEN = "relay-token";
  try {
    const off = new PushService(undefined, { url: "https://registry.example.com/v3/push", token: () => "bdt_x" }, "none");
    assert.equal(off.enabled, false);
    assert.equal((await off.sendTest()).error, "push relay is not configured");
    assert.equal(new PushService(undefined, undefined, "convex").enabled, true, "convex なら自前の relay を使う");
  } finally {
    if (saved.url === undefined) delete process.env.BUDDYOS_PUSH_RELAY_URL;
    else process.env.BUDDYOS_PUSH_RELAY_URL = saved.url;
    if (saved.token === undefined) delete process.env.BUDDYOS_PUSH_RELAY_TOKEN;
    else process.env.BUDDYOS_PUSH_RELAY_TOKEN = saved.token;
  }
  delete process.env.BUDDYOS_PUSH_RELAY_URL;
  delete process.env.BUDDYOS_PUSH_RELAY_TOKEN;
  assert.equal(new PushService(undefined, undefined, "convex").enabled, false, "送り先が無ければ送らない");
});

test("Claude の使用量: on / off を環境変数で切り替え、無ければ既定値", () => {
  assert.deepEqual(resolveClaudeUsage({}, FULL), { value: true, source: "default" });
  assert.deepEqual(resolveClaudeUsage({}, EMPTY), { value: false, source: "default" });
  assert.deepEqual(resolveClaudeUsage({ BUDDYOS_CLAUDE_USAGE: "off" }, FULL), { value: false, source: "env" });
  assert.deepEqual(resolveClaudeUsage({ BUDDYOS_CLAUDE_USAGE: "ON" }, EMPTY), { value: true, source: "env" });
});

test("OpenRouter の Referer: 値があるときだけヘッダを付ける", () => {
  assert.deepEqual(resolveOpenRouterReferer({}, EMPTY), { value: undefined, source: "none" });
  assert.deepEqual(resolveOpenRouterReferer({}, FULL), { value: "https://app.example.com", source: "default" });
  const custom = openRouterHeaders("k", { BUDDYOS_OPENROUTER_REFERER: "https://me.example.com" });
  assert.equal(custom["HTTP-Referer"], "https://me.example.com");
  assert.equal(custom.authorization, "Bearer k");
  assert.equal(custom["X-Title"], "BuddyOS");
  const fallback = openRouterHeaders("k", {});
  assert.equal(fallback["HTTP-Referer"], OFFICIAL_DEFAULTS.openRouterReferer || undefined);
});

test("起動時のログは 1 行で、中継の URL のほかは値を出さない", () => {
  const line = describeSettings("default", { BUDDYOS_OPENROUTER_REFERER: "https://secret-referer.example.com" }, FULL);
  assert.equal(line.split("\n").length, 1);
  assert.match(line, /relay=default\(wss:\/\/relay\.example\.com\/ws\)/);
  assert.match(line, /registry=default/);
  assert.match(line, /push=convex\(default\)/);
  assert.match(line, /openrouterReferer=env/);
  assert.ok(!line.includes("registry.example.com"));
  assert.ok(!line.includes("secret-referer"));
  assert.match(describeSettings("none", {}, EMPTY), /edition=oss relay=none registry=none push=none\(default\) claudeUsage=off\(default\) openrouterReferer=none/);
});

test("登録簿: サイトも中継も無ければ通信せず、ログは 1 回だけ", async () => {
  const base = path.join(root, "registry-off");
  const identity = BridgeIdentity.open(path.join(base, "cfg"), { env: {}, homeDir: base, log: () => {} });
  fs.mkdirSync(path.join(base, "buddyos"), { recursive: true });
  fs.writeFileSync(path.join(base, "buddyos", "clerk-access-token"), "clerk_test");
  let calls = 0;
  const logs: string[] = [];
  const make = (relayURL: string, defaults: OfficialDefaults) =>
    new BridgeRegistry({
      identity,
      relayURL,
      machineName: () => "PC",
      env: {},
      defaults,
      buddyosDir: path.join(base, "buddyos"),
      fetch: (async () => {
        calls++;
        return new Response("{}", { status: 500 });
      }) as typeof fetch,
      machineId: async () => undefined,
      log: (m) => logs.push(m)
    });
  const noSite = make("wss://relay.example.com/ws", EMPTY);
  await noSite.register();
  await noSite.register();
  const noRelay = make("", FULL);
  await noRelay.register();
  assert.equal(calls, 0);
  assert.equal(logs.length, 2);
  assert.match(logs[0], /BUDDYOS_CONVEX_SITE/);
  assert.match(logs[1], /no relay URL/);
});
