import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test, { after } from "node:test";

// 実ホームに触れないよう、ホームを一時ディレクトリに向けてから読み込む。
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "buddyos-wb-opencode-"));
process.env.HOME = tmp;
process.env.USERPROFILE = tmp;
after(() => fs.rmSync(tmp, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 }));

const { isValidOpencodeSkillName, loadOpencodeSkill } = await import("./opencodeSkills.js");
const { opencodeCacheHome, opencodeLaunch, WSL_OPENCODE_CACHE_SCRIPT } = await import("./opencodeAcp.js");

test("スキル名: 単層のフォルダ名だけ読み、.. や区切りを含む名前は断る", () => {
  const dir = path.join(tmp, ".config", "opencode", "skills", "hello");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "SKILL.md"), "---\nname: hello\n---\nhi\n");
  fs.writeFileSync(path.join(tmp, ".config", "opencode", "SKILL.md"), "outside");
  assert.equal(loadOpencodeSkill("hello"), "---\nname: hello\n---\nhi\n");
  for (const bad of ["..", "../", "..\\..", "a/b", "a\\b", "C:x", "", "."]) {
    assert.equal(isValidOpencodeSkillName(bad), false, bad);
  }
  assert.equal(loadOpencodeSkill(".."), undefined);
  assert.equal(loadOpencodeSkill("../../.."), undefined);
  assert.equal(isValidOpencodeSkillName("my-skill_1"), true);
});

test("OpenCode のキャッシュはユーザー専用の場所に 0700 で作る（共有の /tmp・C:\\tmp には置かない）", () => {
  const dir = opencodeCacheHome(process.platform === "win32" ? "win32" : "linux", process.env, tmp);
  if (process.platform !== "win32") {
    assert.equal(dir, path.join(tmp, ".cache", "buddyos-oc"));
    assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  }
  assert.ok(!dir.startsWith("/tmp/oc-cache"));
  // シンボリックリンクにすり替えられていたら使わない
  if (process.platform !== "win32") {
    const home2 = fs.mkdtempSync(path.join(tmp, "oc2-"));
    fs.mkdirSync(path.join(home2, ".cache"), { recursive: true });
    fs.symlinkSync(os.tmpdir(), path.join(home2, ".cache", "buddyos-oc"));
    const fallback = opencodeCacheHome("linux", process.env, home2);
    assert.notEqual(fallback, path.join(home2, ".cache", "buddyos-oc"));
    assert.equal(fs.statSync(fallback).mode & 0o777, 0o700);
  }
  const native = opencodeLaunch({ kind: "native", executable: "opencode", label: "native:opencode", shell: false });
  assert.deepEqual(native.args, ["acp"]);
  if (process.platform !== "win32") assert.equal(native.env?.XDG_CACHE_HOME, path.join(tmp, ".cache", "buddyos-oc"));
  else assert.match(native.env?.XDG_CACHE_HOME ?? "", /\\BuddyOS\\oc-cache$/);
});

test("WSL は Linux 側の $HOME/.cache/buddyos-oc を 0700 で作ってから opencode を起動する", () => {
  const wsl = opencodeLaunch({ kind: "wsl", executable: "opencode", label: "wsl:default:opencode", shell: false });
  assert.equal(wsl.runtime.executable, "sh");
  assert.equal(wsl.runtime.label, "wsl:default:opencode");
  assert.deepEqual(wsl.args, ["-c", WSL_OPENCODE_CACHE_SCRIPT, "sh", "opencode", "acp"]);
  assert.equal(wsl.env, undefined);
  assert.ok(!WSL_OPENCODE_CACHE_SCRIPT.includes('"'), "wsl.exe の引数に \" を入れない");
  assert.match(WSL_OPENCODE_CACHE_SCRIPT, /\$HOME\/\.cache\/buddyos-oc/);
  assert.match(WSL_OPENCODE_CACHE_SCRIPT, /chmod 700/);
});

test("WSL の起動スクリプトは sh で動き、キャッシュを 0700 で作って XDG_CACHE_HOME を渡す", { skip: process.platform === "win32" }, async () => {
  const { spawnSync } = await import("node:child_process");
  const home = fs.mkdtempSync(path.join(tmp, "oc3-"));
  const r = spawnSync("sh", ["-c", WSL_OPENCODE_CACHE_SCRIPT, "sh", "sh", "-c", "printf %s \"$XDG_CACHE_HOME\""], { env: { ...process.env, HOME: home }, encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, path.join(home, ".cache", "buddyos-oc"));
  assert.equal(fs.statSync(path.join(home, ".cache", "buddyos-oc")).mode & 0o777, 0o700);
  assert.ok(fs.statSync(path.join(home, ".cache", "buddyos-oc", "opencode", "bin")).isDirectory());
});
