// shared/fixtures は公開リポジトリに書き出される。個人の情報が入っていないことを確かめる。
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { userInfo } from "node:os";
import { dirname, join, relative } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "shared", "fixtures");
const dirs = ["background-control", "live-activity"].map((d) => join(root, d));

function walk(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out;
}

const files = dirs.flatMap(walk);
const osUser = userInfo().username;

const rules: [string, RegExp][] = [
  ["e-mail", /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/],
  ["home path", /\/Users\/(?!me(?![A-Za-z0-9_.-]))/],
  ["encoded home path", /%2FUsers%2F(?!me(?![A-Za-z0-9_.-]))/i],
  ["bridge device token", /bdt_/],
  ["api key", /\bsk-[A-Za-z0-9]/],
  ["rvAuth/ptyAuth value", /"(?:rvAuth|ptyAuth)"\s*:\s*"(?!<redacted>")/],
  ["connector name", /claude\.ai /],
  ["connector tool", /mcp__claude_ai_/],
  ["mcp tool", /\b[A-Za-z-]*mcp__\w+/],
  ["codex plan", /"planType"/],
];

test("fixtures: 走査の対象がある", () => {
  assert.ok(files.length > 20, `files=${files.length}`);
});

test("fixtures: 個人の情報・秘密の値が無い", () => {
  const hits: string[] = [];
  for (const p of files) {
    const text = readFileSync(p, "utf8");
    for (const [label, re] of rules) {
      if (re.test(text)) hits.push(`${relative(root, p)}: ${label}`);
    }
    if (osUser.length >= 3 && osUser !== "me" && text.includes(osUser)) {
      hits.push(`${relative(root, p)}: OS user name`);
    }
  }
  assert.deepEqual(hits, []);
});

test("fixtures: 300 KB 以下で、JSON / JSON Lines として読める", () => {
  const problems: string[] = [];
  for (const p of files) {
    const rel = relative(root, p);
    if (statSync(p).size > 300 * 1024) problems.push(`${rel}: too big`);
    const text = readFileSync(p, "utf8");
    try {
      if (p.endsWith(".jsonl")) {
        text.split("\n").forEach((line, i) => {
          if (line.trim() === "") return;
          try { JSON.parse(line); } catch { problems.push(`${rel}:${i + 1}: bad json line`); }
        });
      } else if (p.endsWith(".json")) JSON.parse(text);
    } catch { problems.push(`${rel}: bad json`); }
  }
  assert.deepEqual(problems, []);
});
