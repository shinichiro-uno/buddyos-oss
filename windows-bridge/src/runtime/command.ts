import { spawn, spawnSync, type ChildProcess, type ChildProcessWithoutNullStreams, type SpawnOptionsWithoutStdio } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import type { RuntimeMode } from "../config.js";
import { hardenExeSearch, systemExe } from "./systemExe.js";

export type RuntimeKind = "native" | "wsl";

export interface RuntimeCommand {
  kind: RuntimeKind;
  executable: string;
  label: string;
  shell: boolean;
  wslDistro?: string;
}

export function resolveRuntime(command: string, mode: RuntimeMode, nativeOverride?: string, wslDistro?: string): RuntimeCommand | undefined {
  if (mode === "off") return undefined;

  const nativeExecutable = resolveNativeCommand(nativeOverride ?? command);
  if ((mode === "native" || mode === "auto") && nativeExecutable) {
    return {
      kind: "native",
      executable: nativeExecutable,
      label: `native:${nativeExecutable}`,
      shell: false
    };
  }

  if ((mode === "wsl" || mode === "auto") && wslCommandExists(command, wslDistro)) {
    return {
      kind: "wsl",
      executable: command,
      label: `wsl:${wslDistro ?? "default"}:${command}`,
      shell: false,
      wslDistro
    };
  }

  return undefined;
}

export function spawnRuntime(
  runtime: RuntimeCommand,
  args: string[],
  options: SpawnOptionsWithoutStdio & { cwd?: string } = {}
): ChildProcessWithoutNullStreams {
  if (runtime.kind === "wsl") {
    const wslArgs: string[] = [];
    if (runtime.wslDistro) wslArgs.push("-d", runtime.wslDistro);
    const wslCwd = normalizeRuntimeCwd(runtime, options.cwd);
    const cdMode = process.env.BUDDYOS_WSL_USE_CD;
    if (cdMode === "1" && wslCwd) {
      wslArgs.push("--cd", wslCwd);
    }
    // 既定では wsl.exe の --cd ではなく sh 側で cd する（失敗時の扱いは WSL_EXEC_SCRIPT を参照。
    // BUDDYOS_WSL_USE_CD=0 で cd しない）。cd しないときも空の引数は渡さず "."（cd . は無害）にする。
    const shCwd = cdMode === "1" || cdMode === "0" ? "." : (wslCwd ?? ".");
    wslArgs.push("--exec", "sh", "-c", WSL_EXEC_SCRIPT, "sh", shCwd, runtime.executable, ...args);
    return spawn(systemExe("wsl.exe"), wslArgs, {
      ...options,
      env: withWslEnv(options.env),
      cwd: undefined,
      shell: false,
      windowsHide: true
    });
  }

  if (process.platform === "win32" && isCmdShim(runtime.executable)) {
    // cross-spawn と同じ方式: 行全体を外側の "..." で包み（/s で剥がされる）、Node に
    // 再クオートさせない（\" で包み直されると cmd.exe が解釈できず exit 1 になる）。
    // cmd.exe は System32 の絶対パスで呼ぶ（名前だけだと作業フォルダの cmd.exe が先に見つかる。systemExe.ts）。
    return spawn(systemExe("cmd.exe"), ["/d", "/s", "/c", `"${commandLine(runtime.executable, args)}"`], {
      ...options,
      env: withHardenedExeSearch(options.env),
      shell: false,
      windowsHide: true,
      windowsVerbatimArguments: true
    });
  }

  return spawn(runtime.executable, args, {
    ...options,
    env: withHardenedExeSearch(options.env),
    shell: false,
    windowsHide: true
  });
}

/** adapter が組み立てた env にも作業フォルダの探索を止める設定を載せる（未指定なら process.env を継ぐので不要）。 */
function withHardenedExeSearch(env: NodeJS.ProcessEnv | undefined): NodeJS.ProcessEnv | undefined {
  if (!env || process.platform !== "win32") return env;
  const next = { ...env };
  hardenExeSearch(next);
  return next;
}

/**
 * 子プロセスツリーを終了させる。codex exec / ACP サーバ（opencode serve, wsl 等）は
 * 孫プロセスを spawn するため、親だけを kill すると孤児が残る（本プロジェクト既知の
 * acp プロセスリーク）。Windows は taskkill /T で子孫ごと確実に落とす。POSIX は
 * detached 起動していないため当該プロセスのみ（孫の process-group kill は将来対応）。
 */
export function killProcessTree(child: ChildProcess | undefined): void {
  if (!child || child.pid === undefined) return;
  const pid = child.pid;
  if (process.platform === "win32") {
    try {
      const tk = spawn(systemExe("taskkill.exe"), ["/pid", String(pid), "/T", "/F"], { windowsHide: true, stdio: "ignore" });
      // spawn 失敗は非同期 'error' で届く（ENOENT / EDR・AppLocker の EACCES 等）。
      // リスナが無いと uncaughtException 化するので拾い、簡易 kill にフォールバックする。
      tk.on("error", () => {
        try {
          child.kill();
        } catch {
          /* already gone */
        }
      });
      return;
    } catch {
      /* fall through to kill() */
    }
  }
  try {
    child.kill();
  } catch {
    /* already gone */
  }
}

/**
 * 子プロセスの stderr（Buffer）を文字列に戻す。Windows の cmd.exe はコンソールのコードページ（日本語なら cp932）で、
 * wsl.exe は UTF-16LE で自分のエラーを書くので、UTF-8 として読むと文字化けする。行ごとに UTF-8 として読めなければ
 * Shift_JIS で読み直す（claude 自身の UTF-8 と cmd.exe の cp932 が混ざっても行単位なら崩れない）。
 * Windows 以外はそのまま UTF-8。
 */
export function decodeConsoleText(bytes: Buffer, platform: NodeJS.Platform = process.platform): string {
  if (platform !== "win32" || bytes.length === 0) return bytes.toString("utf8");
  if (looksUtf16le(bytes)) return bytes.toString("utf16le").replace(/^﻿/, "");
  const lines: string[] = [];
  let start = 0;
  for (;;) {
    const nl = bytes.indexOf(0x0a, start);
    const end = nl < 0 ? bytes.length : nl + 1;
    lines.push(decodeLine(bytes.subarray(start, end)));
    if (nl < 0) break;
    start = end;
  }
  return lines.join("");
}

function decodeLine(line: Buffer): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(line);
  } catch {
    try {
      return new TextDecoder("shift_jis").decode(line);
    } catch {
      // ICU を持たない Node は shift_jis を知らない。UTF-8 のまま返す。
      return line.toString("utf8");
    }
  }
}

/**
 * wsl.exe の UTF-16LE 出力か（BOM か、奇数番目に 0x00 がある）。UTF-8 と cp932 の文字列は 0x00 を含まない。
 * 日本語の多い文は奇数番目が 0x30 等になり 0x00 は少ないが、空白・英数字・改行の分だけ 0x00 が出るので 1 つあれば足りる。
 */
function looksUtf16le(bytes: Buffer): boolean {
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) return true;
  if (bytes.length < 4) return false;
  let oddZeros = 0;
  let evenZeros = 0;
  for (let i = 0; i < bytes.length; i += 1) {
    if (bytes[i] !== 0) continue;
    if (i % 2 === 1) oddZeros += 1;
    else evenZeros += 1;
  }
  return oddZeros > 0 && oddZeros > evenZeros;
}

export function normalizeRuntimeCwd(runtime: RuntimeCommand, cwd?: string): string | undefined {
  if (runtime.kind !== "wsl") return normalizeNativeCwd(cwd);

  const override = normalizeNativeCwd(process.env.BUDDYOS_WSL_CWD);
  const mapped = override ? toWslPath(override) : cwd ? toWslPath(cwd) : undefined;
  if (!mapped || mapped === "/root" || mapped.startsWith("/root/")) return undefined;
  return mapped;
}

export function toWslPath(input: string): string {
  const normalized = input.trim();
  const driveMatch = /^([a-zA-Z]):[\\/](.*)$/.exec(normalized);
  if (driveMatch) {
    const drive = driveMatch[1].toLowerCase();
    const rest = driveMatch[2].replace(/\\/g, "/");
    return `/mnt/${drive}/${rest}`;
  }
  // \\wsl$\<distro>\path / \\wsl.localhost\<distro>\path は WSL 内の /path そのもの。
  const wslUnc = /^[\\/]{2}wsl(?:\$|\.localhost)[\\/][^\\/]+(?:[\\/](.*))?$/i.exec(normalized);
  if (wslUnc) {
    return `/${(wslUnc[1] ?? "").replace(/\\/g, "/")}`;
  }
  if (normalized.startsWith("\\\\")) {
    return normalized.replace(/\\/g, "/");
  }
  return normalized.replace(/\\/g, "/");
}

// Windows で spawn できる拡張子（.cmd/.bat は cmd.exe 経由）。npm の cmd-shim が置く
// 拡張子なしの sh スクリプトや .ps1 は libuv が .com/.exe しか補わず ENOENT になる。
const WIN_RUNNABLE_EXTS = [".exe", ".com", ".cmd", ".bat"];

function isWinRunnable(file: string): boolean {
  return WIN_RUNNABLE_EXTS.includes(path.win32.extname(file).toLowerCase());
}

/** Windows でパス指定（*_BIN 等）を実行するファイルに解決する。server.ts の非同期判定と共用。 */
export function resolveWinPath(command: string): string | undefined {
  if (isWinRunnable(command)) return fs.existsSync(command) ? command : undefined;
  // *_BIN に拡張子なしのシム（%APPDATA%\npm\codex 等）が渡されたら同じ場所の .exe/.cmd を補う。
  const withExt = WIN_RUNNABLE_EXTS.map((ext) => command + ext).find((candidate) => fs.existsSync(candidate));
  return withExt ?? (fs.existsSync(command) ? command : undefined);
}

/** where.exe の出力から実行するファイルを選ぶ。server.ts の非同期判定と共用。 */
export function pickWhereResult(stdout: string): string | undefined {
  // where.exe は拡張子なしのシムを .cmd より先に返すので、PATH 順で最初の実行可能な行を採る。
  return stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line && isWinRunnable(line));
}

function resolveNativeCommand(command: string): string | undefined {
  if (process.platform === "win32") {
    if (looksLikePath(command)) return resolveWinPath(command);
    const result = spawnSync(systemExe("where.exe"), [command], {
      windowsHide: true,
      timeout: 5000,
      encoding: "utf8"
    });
    if (result.status !== 0) return undefined;
    return pickWhereResult(result.stdout);
  }

  const result = spawnSync(command, ["--version"], {
    shell: false,
    windowsHide: true,
    timeout: 5000,
    stdio: "ignore"
  });
  return result.status === 0 ? command : undefined;
}

// `sh -l` と同じ /etc/profile と ~/.profile をサブシェルで読み、PATH だけを取り込む（~/.local/bin 等）。
// profile の export や cd が adapter の注入した env（WSLENV）・削除したキー・cwd を上書きしないようにする。
// 出力は JSON-RPC / stream-json の stdout を壊さないよう捨て、stdin も読ませない。
// wsl.exe の引数に " を渡すと引用が崩れ得るので（agentProbe / codexHistory と同じ前提）、" は使わない。
const WSL_PROFILE_PRELUDE =
  "p=$({ [ -r /etc/profile ] && . /etc/profile; [ -r ~/.profile ] && . ~/.profile; } >/dev/null 2>&1 </dev/null; IFS=; set -f; printf %s $PATH); PATH=${p:-$PATH}; ";

// --exec はシェルを通さず PATH が WSL 既定のままなので、判定（wslCommandExists）と同じ
// profile を読んでから exec する。$1 = cwd（cd しないときは "."）、$2 以降 = コマンドと引数。
// cd できない（/mnt に無いネットワークドライブ・UNC 等）ときはブリッジの継承 cwd で黙って動かさず、
// native の spawn と同じく失敗させる（sh が理由を stderr に出す）。"$1" / "$@" は q（printf '\042' = "）
// と eval で組み立てる（空の引数も落とさない）。
const WSL_EXEC_SCRIPT = `${WSL_PROFILE_PRELUDE}q=$(printf '\\042'); eval cd $q'$1'$q || exit 1; shift; eval exec $q'$@'$q`;

function wslCommandExists(command: string, distro?: string): boolean {
  if (process.platform !== "win32") return false;
  const args: string[] = [];
  if (distro) args.push("-d", distro);
  args.push("--exec", "sh", "-c", `${WSL_PROFILE_PRELUDE}command -v $1 >/dev/null 2>&1`, "sh", command);
  const result = spawnSync(systemExe("wsl.exe"), args, {
    windowsHide: true,
    timeout: 5000,
    stdio: "ignore"
  });
  return result.status === 0;
}

// WSLENV に載せないキー（Windows の PATH を /u で渡すと Linux 側の PATH を丸ごと潰す）。
const WSL_ENV_EXCLUDE = new Set(["PATH", "WSLENV"]);

// adapter が参照・解決するキー。ブリッジ自身の環境に同じ値があると差分に出ないので、値があれば必ず転送する
// （Windows 側の XAI_API_KEY で grok を configured と判定したのに WSL の grok にキーが無い、を防ぐ）。
// XDG_CACHE_HOME のように Windows 側の値（Windows パス）が Linux 側を壊し得るキーは入れない。
const WSL_ENV_PASSTHROUGH = new Set([
  "ANTHROPIC_BASE_URL",
  "ANTHROPIC_AUTH_TOKEN",
  "XAI_API_KEY",
  "GROK_DISABLE_UPDATE_CHECK",
  "CURSOR_API_KEY",
  "CURSOR_AUTH_TOKEN",
  "GLM_BASE_URL"
]);

/**
 * wsl.exe は WSLENV に列挙された変数しか Linux 側へ引き継がない。adapter が注入・変更した
 * キー（process.env との差分: hermes の GLM_BASE_URL、opencode の XDG_CACHE_HOME、
 * claude の BUDDYOS_SPAWNED 等）と WSL_ENV_PASSTHROUGH のキーを `KEY/u` で既存の WSLENV に追記する。値は URL・
 * トークン・Linux パスなので /p（パス変換）は付けない。秘密値をコマンドラインに載せないため `env K=V` 方式は使わない。
 * adapter が削除したキーは転送されず、WSL_PROFILE_PRELUDE も profile の export を
 * 取り込まないので Linux 側にも現れない。
 */
function withWslEnv(env: NodeJS.ProcessEnv | undefined): NodeJS.ProcessEnv | undefined {
  if (!env) return env;
  const wslenvKey = Object.keys(env).find((key) => key.toUpperCase() === "WSLENV");
  const current = (wslenvKey ? env[wslenvKey] : undefined) ?? "";
  const listed = new Set(current.split(":").map((entry) => entry.split("/")[0].toUpperCase()).filter(Boolean));
  const added: string[] = [];
  for (const [key, value] of Object.entries(env)) {
    const upper = key.toUpperCase();
    if (value === undefined || WSL_ENV_EXCLUDE.has(upper) || listed.has(upper)) continue;
    if (process.env[key] === value && !(value && WSL_ENV_PASSTHROUGH.has(upper))) continue;
    listed.add(upper);
    added.push(`${key}/u`);
  }
  if (added.length === 0) return env;
  const next = { ...env };
  if (wslenvKey) delete next[wslenvKey];
  next.WSLENV = [current, ...added].filter(Boolean).join(":");
  return next;
}

function normalizeNativeCwd(cwd?: string): string | undefined {
  const trimmed = cwd?.trim();
  return trimmed ? trimmed : undefined;
}

function looksLikePath(command: string): boolean {
  return command.includes(path.sep) || command.includes("/") || /^[a-zA-Z]:[\\/]/.test(command);
}

export function isCmdShim(command: string): boolean {
  return /\.(cmd|bat)$/i.test(command);
}

export function commandLine(executable: string, args: string[], reparse = true): string {
  // パスに " は入らず、引用符の内側の空白・& ・( ) はそのまま通るので実行ファイルは素の "..." で包む。
  // reparse=false は cmd.exe から .exe を直接起動するとき（%* の再パースが無いので ^ は 1 回だけ）。
  return [`"${executable}"`, ...args.map((a) => quoteCmdArg(a, reparse))].join(" ");
}

// cmd.exe のメタ文字（cross-spawn と同じ集合）。
const CMD_META_CHARS = /([()\][%!^"`<>&|;, *?])/g;

function quoteCmdArg(value: string, reparse = true): string {
  // qntm.org/cmd（cross-spawn と同じ）: CommandLineToArgvW 向けに \ と " を処理して "..." で包み、
  // 引用符ごとメタ文字を ^ でエスケープする（引用符の内側の ^ はエスケープにならず、文字として届くため）。
  // .cmd/.bat（npm シム）は %* で引数を再パースするので ^ は二重に掛ける。改行は cmd.exe では
  // 渡せず以降が切り捨てられるので空白に置き換える（長文・複数行のプロンプトは stdin で渡すこと）。
  const quoted = `"${value
    .replace(/\r\n|[\r\n]/g, " ")
    .replace(/(\\*)"/g, "$1$1\\\"")
    .replace(/(\\+)$/g, "$1$1")}"`;
  const once = quoted.replace(CMD_META_CHARS, "^$1");
  return reparse ? once.replace(CMD_META_CHARS, "^$1") : once;
}
