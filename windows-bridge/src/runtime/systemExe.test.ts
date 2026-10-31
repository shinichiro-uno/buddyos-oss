import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { hardenExeSearch, systemExe } from "./systemExe.js";

// Windows で、作業フォルダに置かれた cmd.exe / node.exe が PATH より先に動かないようにする。

test("Windows の標準コマンドは System32 の絶対パスで呼ぶ", () => {
  const env = { SystemRoot: "C:\\Windows" };
  assert.equal(systemExe("cmd.exe", "win32", env), "C:\\Windows\\System32\\cmd.exe");
  assert.equal(systemExe("taskkill", "win32", env), "C:\\Windows\\System32\\taskkill.exe");
  assert.equal(systemExe("where.exe", "win32", env), "C:\\Windows\\System32\\where.exe");
  assert.equal(systemExe("wsl.exe", "win32", env), "C:\\Windows\\System32\\wsl.exe");
  assert.equal(systemExe("powershell.exe", "win32", env), "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe");
  assert.equal(systemExe("cmd.exe", "win32", { windir: "D:\\Win" }), "D:\\Win\\System32\\cmd.exe");
  // 相対パスや UNC の SystemRoot は使わない
  assert.equal(systemExe("cmd.exe", "win32", { SystemRoot: ".\\evil" }), "C:\\Windows\\System32\\cmd.exe");
  assert.equal(systemExe("cmd.exe", "win32", { SystemRoot: "\\\\host\\share" }), "C:\\Windows\\System32\\cmd.exe");
  assert.equal(systemExe("cmd.exe", "win32", {}), "C:\\Windows\\System32\\cmd.exe");
  // Windows 以外は名前のまま
  assert.equal(systemExe("ps", "linux", env), "ps");
});

test("作業フォルダからの実行ファイル探索を止める環境変数を、Windows でだけ立てる", () => {
  const win: NodeJS.ProcessEnv = {};
  hardenExeSearch(win, "win32");
  assert.equal(win.NoDefaultCurrentDirectoryInExePath, "1");
  const mac: NodeJS.ProcessEnv = {};
  hardenExeSearch(mac, "darwin");
  assert.equal(mac.NoDefaultCurrentDirectoryInExePath, undefined);
});

test("Bridge のコードは Windows の標準コマンドを名前だけで起動しない", () => {
  // spawn / execFile / spawnSync に "cmd.exe" "taskkill" "where.exe" "powershell.exe" "wsl.exe" を直接渡していないこと。
  const src = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
  const files: string[] = [];
  const walk = (dir: string): void => {
    for (const d of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, d.name);
      if (d.isDirectory()) walk(p);
      else if (p.endsWith(".ts") && !p.endsWith(".test.ts") && !p.endsWith(".d.ts")) files.push(p);
    }
  };
  walk(src);
  const bare = /\b(spawn|spawnSync|execFile|execFileSync|runText)\(\s*"(cmd|cmd\.exe|taskkill|taskkill\.exe|where|where\.exe|powershell|powershell\.exe|wsl|wsl\.exe)"/;
  const offenders = files.filter((f) => bare.test(fs.readFileSync(f, "utf8"))).map((f) => path.relative(src, f));
  assert.deepEqual(offenders, []);
  // 起動時に最初に読み込む
  const index = fs.readFileSync(path.join(src, "index.ts"), "utf8");
  const firstImport = /^import .*$/m.exec(index)?.[0];
  assert.equal(firstImport, 'import "./runtime/systemExe.js";');
});
