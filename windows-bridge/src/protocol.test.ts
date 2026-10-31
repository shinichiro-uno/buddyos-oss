import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { EVENT_TYPES } from "./protocol.js";

// shared/protocol.json は全コードベースの種別の正本。
// e2e.test.ts と同じくリポジトリ直下からの相対で読む。
const srcDir = path.dirname(fileURLToPath(import.meta.url));
const protocolPath = path.join(srcDir, "..", "..", "shared", "protocol.json");

interface Protocol {
  _rules: { windows: { ignore: string[] } };
  eventTypes: Record<string, { platforms: string[]; dead?: boolean }>;
}

const protocol = JSON.parse(fs.readFileSync(protocolPath, "utf8")) as Protocol;

/** 足りない・多いを両方出して比べる。 */
function assertSameSet(actual: Iterable<string>, expected: Iterable<string>, label: string): void {
  const a = new Set(actual);
  const e = new Set(expected);
  const missing = [...e].filter((x) => !a.has(x)).sort();
  const extra = [...a].filter((x) => !e.has(x)).sort();
  assert.deepEqual({ missing, extra }, { missing: [], extra: [] }, label);
}

test("EVENT_TYPES は protocol.json で platforms に windows を含む種別と一致する", () => {
  assert.equal(new Set(EVENT_TYPES).size, EVENT_TYPES.length, "EVENT_TYPES に重複がある");
  const expected = Object.entries(protocol.eventTypes)
    .filter(([, v]) => v.platforms.includes("windows"))
    .map(([k]) => k);
  assertSameSet(EVENT_TYPES, expected, "EVENT_TYPES と protocol.json の windows がずれている");
});

test("EVENT_TYPES に dead な種別が無い", () => {
  const dead = EVENT_TYPES.filter((t) => protocol.eventTypes[t]?.dead === true);
  assert.deepEqual(dead, []);
});

// SessionEvent を通さず ws.send する箇所（e2e_hello 等）は型で守れないので、_rules.windows の抽出ルールで
// src を走査して一覧と比べる。新しい非種別の { type: "…" } で落ちたら protocol.json の ignore に足す。
test("src の { type: \"…\" } と server.ts の case \"…\": は全て EVENT_TYPES にある（_rules.windows）", () => {
  const ignore = new Set(protocol._rules.windows.ignore);
  const found = new Set<string>();
  const walk = (dir: string): void => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(p);
      else if (p.endsWith(".ts") && !p.endsWith(".test.ts") && !p.endsWith(".d.ts")) {
        const text = fs.readFileSync(p, "utf8");
        for (const m of text.matchAll(/\{\s*type:\s*"([a-z0-9_]+)"/g)) found.add(m[1]);
        if (path.basename(p) === "server.ts" && path.dirname(p) === srcDir) {
          for (const m of text.matchAll(/case "([a-z0-9_]+)":/g)) found.add(m[1]);
        }
      }
    }
  };
  walk(srcDir);
  const used = [...found].filter((t) => !ignore.has(t));
  assertSameSet(used, EVENT_TYPES, "src で使っている種別と EVENT_TYPES がずれている");
});
