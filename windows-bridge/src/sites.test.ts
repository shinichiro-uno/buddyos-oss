import assert from "node:assert/strict";
import test from "node:test";
import {
  hostStatus,
  pagesItems,
  parseAgo,
  parseJsonTail,
  readCloudflare,
  readVercel,
  SitesService,
  vercelItems,
  type RunResult,
  type SiteList,
  type SiteRunner
} from "./sites.js";

const NOW = Date.parse("2026-10-20T12:00:00.000Z");
const ok = (out: string): RunResult => ({ ok: true, missing: false, out, err: "" });
const fail = (err: string): RunResult => ({ ok: false, missing: false, out: "", err });
const missing: RunResult = { ok: false, missing: true, out: "", err: "" };

/** 呼ばれた順に記録して、決めた結果を返す runner。 */
function fakeRunner(answer: (command: string, args: string[]) => RunResult): { run: SiteRunner; calls: Array<{ command: string; args: string[]; timeoutMs: number }> } {
  const calls: Array<{ command: string; args: string[]; timeoutMs: number }> = [];
  return {
    calls,
    run: async (command, args, timeoutMs) => {
      calls.push({ command, args, timeoutMs });
      return answer(command, args);
    }
  };
}

test("parseJsonTail: 先頭の案内を飛ばして読み、案内の中の [ は次の位置から読み直す", () => {
  assert.deepEqual(parseJsonTail("Vercel CLI 48.0.0\n> Fetching projects\n{\"a\":1}", "{"), { a: 1 });
  assert.deepEqual(parseJsonTail("▲ [WARNING] old version\n[{\"x\":2}]", "["), [{ x: 2 }]);
  assert.equal(parseJsonTail("no json here", "{"), null);
  assert.equal(parseJsonTail("{broken", "{"), null);
});

test("parseAgo: 「6 days ago」「a minute ago」をおおよその日時に、読めなければ undefined", () => {
  assert.equal(parseAgo("6 days ago", NOW), new Date(NOW - 6 * 86_400_000).toISOString());
  assert.equal(parseAgo("a minute ago", NOW), new Date(NOW - 60_000).toISOString());
  assert.equal(parseAgo("an hour ago", NOW), new Date(NOW - 3_600_000).toISOString());
  assert.equal(parseAgo(" 2 weeks ago ", NOW), new Date(NOW - 14 * 86_400_000).toISOString());
  assert.equal(parseAgo("yesterday", NOW), undefined);
  assert.equal(parseAgo("", NOW), undefined);
});

test("vercelItems: 名前の無いものを除き、本番 URL と更新日時を ISO にする", () => {
  assert.deepEqual(
    vercelItems([
      { name: "web", latestProductionUrl: "https://web.vercel.app", updatedAt: NOW },
      { name: "draft", latestProductionUrl: null },
      { latestProductionUrl: "https://nameless.vercel.app" }
    ]),
    [
      { host: "vercel", name: "web", url: "https://web.vercel.app", updatedAt: new Date(NOW).toISOString() },
      { host: "vercel", name: "draft", url: undefined, updatedAt: undefined }
    ]
  );
});

test("pagesItems: *.pages.dev より独自ドメインを先に、https を付ける", () => {
  const items = pagesItems(
    [
      { "Project Name": "blog", "Project Domains": "blog.pages.dev, blog.example.com", "Last Modified": "6 days ago" },
      { "Project Name": "docs", "Project Domains": "docs.pages.dev", "Last Modified": "?" },
      { "Project Name": "empty", "Project Domains": "" },
      { "Project Domains": "x.pages.dev" }
    ],
    NOW
  );
  assert.deepEqual(items, [
    { host: "cloudflare", name: "blog", url: "https://blog.example.com", updatedAt: new Date(NOW - 6 * 86_400_000).toISOString() },
    { host: "cloudflare", name: "docs", url: "https://docs.pages.dev", updatedAt: undefined },
    { host: "cloudflare", name: "empty", url: undefined, updatedAt: undefined }
  ]);
});

test("hostStatus: 見つからない → missing、ログインの言い回し → signedOut、ほかは末尾 3 行の error", () => {
  assert.deepEqual(hostStatus("vercel", missing), { host: "vercel", state: "missing" });
  assert.equal(hostStatus("vercel", fail("Error: No existing credentials found. Please run `vercel login`")).state, "signedOut");
  assert.equal(hostStatus("cloudflare", fail("You are not authenticated. Please run `wrangler login`.")).state, "signedOut");
  const err = hostStatus("cloudflare", fail("l1\r\nl2\nl3\nl4"));
  assert.deepEqual(err, { host: "cloudflare", state: "error", message: "l2\nl3\nl4" });
  assert.equal(hostStatus("cloudflare", fail("x".repeat(1000))).message?.length, 400);
});

test("readVercel: --next でページをたどり、contextName を account にする", async () => {
  const pages: Record<string, string> = {
    first: `Vercel CLI 48\n${JSON.stringify({ contextName: "my-team", projects: [{ name: "a" }], pagination: { next: 111 } })}`,
    "111": JSON.stringify({ contextName: "my-team", projects: [{ name: "b" }], pagination: { next: null } })
  };
  const { run, calls } = fakeRunner((_c, args) => {
    const i = args.indexOf("--next");
    return ok(pages[i < 0 ? "first" : args[i + 1]]);
  });
  const r = await readVercel(run);
  assert.deepEqual(r.status, { host: "vercel", state: "ok", account: "my-team" });
  assert.deepEqual(r.items.map((i) => i.name), ["a", "b"]);
  assert.deepEqual(calls.map((c) => c.args), [
    ["project", "ls", "--format", "json"],
    ["project", "ls", "--format", "json", "--next", "111"]
  ]);
});

test("readVercel: 5 ページで止め、2 ページ目以降で読めなければ読めた分を返す", async () => {
  let n = 0;
  const endless = fakeRunner(() => ok(JSON.stringify({ projects: [{ name: `p${n}` }], pagination: { next: ++n } })));
  const r = await readVercel(endless.run);
  assert.equal(endless.calls.length, 5);
  assert.equal(r.items.length, 5);

  let m = 0;
  const broken = fakeRunner(() => (m++ === 0 ? ok(JSON.stringify({ contextName: "me", projects: [{ name: "x" }], pagination: { next: 9 } })) : fail("boom")));
  const r2 = await readVercel(broken.run);
  assert.deepEqual(r2.status, { host: "vercel", state: "ok", account: "me" });
  assert.deepEqual(r2.items.map((i) => i.name), ["x"]);
});

test("readVercel: 最初のページで失敗したら状態だけ返す", async () => {
  assert.deepEqual(await readVercel(fakeRunner(() => missing).run), { status: { host: "vercel", state: "missing" }, items: [] });
  const signedOut = await readVercel(fakeRunner(() => fail("Error: The specified token is not valid. Use `vercel login` to generate a new token.")).run);
  assert.equal(signedOut.status.state, "signedOut");
});

test("readCloudflare: wrangler が無ければ npx --yes wrangler@4 を 120 秒で動かす", async () => {
  const json = JSON.stringify([{ "Project Name": "blog", "Project Domains": "blog.pages.dev", "Last Modified": "2 hours ago" }]);
  const { run, calls } = fakeRunner((command) => (command === "wrangler" ? missing : ok(`npm warn exec\n${json}`)));
  const r = await readCloudflare(run, () => NOW);
  assert.deepEqual(r.status, { host: "cloudflare", state: "ok" });
  assert.deepEqual(r.items, [{ host: "cloudflare", name: "blog", url: "https://blog.pages.dev", updatedAt: new Date(NOW - 2 * 3_600_000).toISOString() }]);
  assert.deepEqual(
    calls.map((c) => [c.command, c.args.join(" "), c.timeoutMs]),
    [
      ["wrangler", "pages project list --json", 60_000],
      ["npx", "--yes wrangler@4 pages project list --json", 120_000]
    ]
  );
});

test("readCloudflare: wrangler があれば npx は使わず、どちらも無ければ missing", async () => {
  const direct = fakeRunner(() => ok("[]"));
  assert.deepEqual(await readCloudflare(direct.run), { status: { host: "cloudflare", state: "ok" }, items: [] });
  assert.equal(direct.calls.length, 1);
  assert.deepEqual(await readCloudflare(fakeRunner(() => missing).run), { status: { host: "cloudflare", state: "missing" }, items: [] });
});

test("SitesService: 5 分はキャッシュ、force で読み直し、同時の要求は 1 回の読み取りを待つ", async () => {
  let clock = NOW;
  let reads = 0;
  const value = (): SiteList => ({ hosts: [], items: [], at: String(++reads) });
  const svc = new SitesService(async () => value(), () => clock);
  const [a, b] = await Promise.all([svc.list(), svc.list()]);
  assert.equal(reads, 1);
  assert.equal(a, b);
  assert.equal((await svc.list()).at, "1");
  assert.equal((await svc.list(true)).at, "2");
  clock += 5 * 60_000 - 1;
  assert.equal((await svc.list()).at, "2");
  clock += 1;
  assert.equal((await svc.list()).at, "3");
});

test("SitesService: 読み取りの失敗はキャッシュせず、次の要求で読み直す", async () => {
  let calls = 0;
  const svc = new SitesService(async () => {
    if (++calls === 1) throw new Error("boom");
    return { hosts: [], items: [], at: "ok" };
  });
  await assert.rejects(svc.list(), /boom/);
  assert.equal((await svc.list()).at, "ok");
});
