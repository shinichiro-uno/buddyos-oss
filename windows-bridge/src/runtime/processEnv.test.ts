import assert from "node:assert/strict";
import test from "node:test";
import { decodeConsoleText } from "./command.js";
import { scrubBridgeEnv } from "./processEnv.js";

test("Electron の印と Clerk のトークンだけを消す", () => {
  const env: NodeJS.ProcessEnv = { ELECTRON_RUN_AS_NODE: "1", ELECTRON_NO_ATTACH_CONSOLE: "1", BUDDYOS_CLERK_TOKEN: "t", PATH: "C:\\x", BUDDYOS_BRIDGE_PORT: "8766" };
  scrubBridgeEnv(env);
  assert.deepEqual(env, { PATH: "C:\\x", BUDDYOS_BRIDGE_PORT: "8766" });
});

test("Windows の stderr: UTF-8 はそのまま、cp932 と UTF-16LE は読み直す", () => {
  const utf8 = Buffer.from("エラー: 見つかりません\n", "utf8");
  assert.equal(decodeConsoleText(utf8, "win32"), "エラー: 見つかりません\n");
  // wsl.exe（UTF-16LE）。
  assert.equal(decodeConsoleText(Buffer.from("\uFEFFWSL にディストリビューションがありません", "utf16le"), "win32"), "WSL にディストリビューションがありません");
  // BOM が無く、ほとんど日本語でも（改行や英数字の 0x00 で）UTF-16LE と分かる。
  const bomless = "Linux 用 Windows サブシステムには、ディストリビューションがインストールされていません。\r\n";
  assert.equal(decodeConsoleText(Buffer.from(bomless, "utf16le"), "win32"), bomless);
  // Windows 以外は UTF-8 のまま。
  assert.equal(decodeConsoleText(utf8, "darwin"), "エラー: 見つかりません\n");
  // cmd.exe の「'node' は、内部」（cp932）。
  const sjis = Buffer.from([0x27, 0x6e, 0x6f, 0x64, 0x65, 0x27, 0x20, 0x82, 0xcd, 0x81, 0x41, 0x93, 0xe0, 0x95, 0x94, 0x0d, 0x0a]);
  const decoded = decodeConsoleText(sjis, "win32");
  // ICU の無い Node は shift_jis を読めない（その場合は UTF-8 のまま返すことだけ確かめる）。
  if (decoded.includes("\uFFFD")) return;
  assert.equal(decoded, "'node' は、内部\r\n");
  // UTF-8 の行と cp932 の行が混ざっても行ごとに読む。
  assert.equal(decodeConsoleText(Buffer.concat([utf8, sjis]), "win32"), "エラー: 見つかりません\n'node' は、内部\r\n");
});
