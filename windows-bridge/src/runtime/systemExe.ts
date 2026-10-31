import path from "node:path";

// Windows の実行ファイル探索の安全策。
// cmd.exe と CreateProcess（libuv の search_path）は、名前だけで起動したコマンドを PATH より先に
// 作業フォルダから探す。信頼できないリポジトリを作業フォルダに選ぶと、そこに置かれた cmd.exe / node.exe が
// 承認より前に動いてしまう。npm の .cmd シムは中で "node" を名前で起動するので、環境変数で
// 作業フォルダの探索を止め、Bridge 自身が起動する Windows のコマンドは System32 の絶対パスで呼ぶ。
// この module を読み込んだ時点で設定する（index.ts は最初に読み込み、子プロセスはこの値を受け継ぐ）。
export function hardenExeSearch(env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform = process.platform): void {
  if (platform === "win32") env.NoDefaultCurrentDirectoryInExePath = "1";
}

hardenExeSearch();

/** %SystemRoot%（無ければ C:\Windows）。 */
function systemRoot(env: NodeJS.ProcessEnv): string {
  const root = env.SystemRoot || env.windir || "C:\\Windows";
  // ドライブから始まる絶対パスだけを使う（相対パスや UNC で作業フォルダ・ネットワーク上のものを掴まないように）。
  return /^[a-zA-Z]:\\/.test(root) ? root : "C:\\Windows";
}

/**
 * Windows の標準コマンド（cmd.exe / taskkill.exe / where.exe / powershell.exe / wsl.exe など）を
 * %SystemRoot%\System32 の絶対パスにする。Windows 以外では名前のまま返す。
 */
export function systemExe(name: string, platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env): string {
  if (platform !== "win32") return name;
  const file = path.win32.extname(name) ? name : `${name}.exe`;
  if (file.toLowerCase() === "powershell.exe") {
    return path.win32.join(systemRoot(env), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
  }
  return path.win32.join(systemRoot(env), "System32", file);
}
