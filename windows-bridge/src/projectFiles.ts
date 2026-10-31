import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

/// プロジェクト（作業フォルダ）の中の画像ファイルを端末へ返す（mac の ProjectFileRoutes / ProjectFileAccess の移植）。
///
///   GET /files/image?path=<絶対 or 作業フォルダからの相対パス>&cwd=<作業フォルダ>&max=<長辺 px>
///
/// エージェントの返事に出てくる `docs/shot.png` のようなパスを、チャットの中でそのまま見るためのもの。
/// 返すのは次をすべて満たすときだけ:
///   - 登録済みのプロジェクトか、渡された cwd の中にある（リンクは解決してから判定）
///   - cwd・プロジェクトはドライブの直下やホームそのもの、システムのフォルダではない
///   - 中身の先頭のバイトが画像（拡張子だけでは信じない）で、大きさが上限以下
/// Windows の Bridge は画像を縮めない（max は受け取るだけ）。WSL のパス（/home/...）は \\wsl.localhost\... に直して読む。

export const FILES_MARKER_HEADER = "X-BuddyOS-Files";
/** 元のファイルの上限。中継を通すので、写真の原寸程度までにする（mac と同じ）。 */
export const MAX_FILE_BYTES = 30 * 1024 * 1024;

export type FileFailure = "bad_path" | "outside_project" | "not_found" | "too_large" | "not_image";

export const FAILURE_STATUS: Record<FileFailure, number> = {
  bad_path: 400,
  outside_project: 403,
  not_found: 404,
  too_large: 413,
  not_image: 415
};

export type ImageResult = { ok: true; data: Buffer; mime: string } | { ok: false; failure: FileFailure };

/** 画像として扱う拡張子。中身の確認（sniff）と両方を通ったものだけ返す。 */
const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "avif", "svg"]);

/** WSL のパス（/home/... 等）を Windows から読めるパスに直す。直せなければ undefined。 */
export type PosixPathResolver = (posixPath: string) => Promise<string | undefined>;

const isWin = (): boolean => process.platform === "win32";
const fold = (p: string): string => (isWin() ? p.toLowerCase() : p);

/** /mnt/c/... → C:\...（WSL から見た Windows のドライブ）。それ以外は undefined。 */
export function mntPathToWindows(p: string): string | undefined {
  const m = /^\/mnt\/([a-zA-Z])(?:\/(.*))?$/.exec(p);
  if (!m) return undefined;
  return `${m[1].toUpperCase()}:\\${(m[2] ?? "").replace(/\//g, "\\")}`;
}

/** file:// と ~ を外し、Windows では /mnt/c/... と WSL のパスを Windows から読めるパスに直す。 */
export async function toLocalPath(raw: string, home: string, resolvePosix?: PosixPathResolver): Promise<string | undefined> {
  let p = raw.trim();
  if (!p || p.includes("\0")) return undefined;
  if (p.startsWith("file://")) {
    try {
      p = fileURLToPath(p);
    } catch {
      p = p.slice("file://".length);
    }
  }
  if (p === "~") p = home;
  else if (p.startsWith("~/") || p.startsWith("~\\")) p = path.join(home, p.slice(2));
  if (isWin() && p.startsWith("/") && !p.startsWith("//")) {
    return mntPathToWindows(p) ?? (resolvePosix ? await resolvePosix(p) : undefined);
  }
  return p;
}

/** 区切りの手前まで一致するか（Windows は大文字小文字を区別しない）。 */
export function isInside(target: string, root: string): boolean {
  const r = fold(root.endsWith(path.sep) ? root : root + path.sep);
  return fold(target).startsWith(r);
}

function systemRoots(): string[] {
  if (!isWin()) return ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/dev", "/cores"];
  const sys = process.env.SystemRoot ?? "C:\\Windows";
  const drive = path.parse(sys).root;
  return [
    sys,
    process.env.ProgramFiles ?? path.join(drive, "Program Files"),
    process.env["ProgramFiles(x86)"] ?? path.join(drive, "Program Files (x86)"),
    process.env.ProgramData ?? path.join(drive, "ProgramData")
  ];
}

function realpath(p: string): string | undefined {
  try {
    return fs.realpathSync.native(p);
  } catch {
    return undefined;
  }
}

/**
 * プロジェクトとして扱ってよいフォルダなら、リンクを解決したパスを返す。
 * ドライブ（共有）の直下とその 1 段下・ホームそのもの・ホームより上・システムのフォルダは認めない。
 */
export function acceptableRoot(local: string, home: string): string | undefined {
  if (!path.isAbsolute(local)) return undefined;
  const p = realpath(path.resolve(local));
  if (!p) return undefined;
  try {
    if (!fs.statSync(p).isDirectory()) return undefined;
  } catch {
    return undefined;
  }
  const homeResolved = realpath(home) ?? path.resolve(home);
  if (fold(p) === fold(homeResolved) || isInside(homeResolved, p)) return undefined;
  if (systemRoots().some((s) => fold(p) === fold(s) || isInside(p, s))) return undefined;
  const parsed = path.parse(p);
  const depth = p.slice(parsed.root.length).split(/[\\/]+/).filter(Boolean).length;
  // mac は /Users/me/proj（ルートから 2 段以上）を求める。Windows も C:\dev\proj のように 2 段以上。
  // WSL の \\wsl.localhost\<distro>\home\<user> は WSL のホームそのものなので 3 段以上にする。
  if (depth < (/^[\\/]{2}wsl/i.test(p) ? 3 : 2)) return undefined;
  return p;
}

/** 先頭のバイトから画像の種類を決める。画像でなければ undefined。 */
export function sniffImage(data: Buffer, ext: string): string | undefined {
  const starts = (sig: number[] | string, offset = 0): boolean => {
    const bytes = typeof sig === "string" ? Buffer.from(sig, "latin1") : Buffer.from(sig);
    return data.length >= offset + bytes.length && data.subarray(offset, offset + bytes.length).equals(bytes);
  };
  if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
  if (starts([0xff, 0xd8, 0xff])) return "image/jpeg";
  if (starts("GIF8")) return "image/gif";
  if (starts("RIFF") && starts("WEBP", 8)) return "image/webp";
  if (starts("BM")) return "image/bmp";
  if (starts("ftyp", 4) && data.length >= 12) {
    const brand = data.subarray(8, 12).toString("latin1");
    if (["avif", "avis"].includes(brand)) return "image/avif";
    if (["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"].includes(brand)) return "image/heic";
  }
  if (ext === "svg" && data.subarray(0, 4096).toString("utf8").toLowerCase().includes("<svg")) return "image/svg+xml";
  return undefined;
}

/** `rawPath`（絶対・~・cwd からの相対）を実体のパスに直し、許された場所の中にあるかを確かめる。 */
export async function resolveProjectFile(
  rawPath: string,
  cwd: string | undefined,
  projects: string[],
  home: string = os.homedir(),
  resolvePosix?: PosixPathResolver
): Promise<{ ok: true; file: string } | { ok: false; failure: FileFailure }> {
  const trimmed = rawPath.trim();
  if (!trimmed || trimmed.includes("\0")) return { ok: false, failure: "bad_path" };
  const cwdLocal = cwd ? await toLocalPath(cwd, home, resolvePosix) : undefined;
  const cwdRoot = cwdLocal ? acceptableRoot(cwdLocal, home) : undefined;
  const roots: string[] = [];
  if (cwdRoot) roots.push(cwdRoot);
  for (const p of projects) {
    const local = await toLocalPath(p, home, resolvePosix);
    const root = local ? acceptableRoot(local, home) : undefined;
    if (root) roots.push(root);
  }
  const local = await toLocalPath(trimmed, home, resolvePosix);
  if (!local) return { ok: false, failure: "bad_path" };
  let candidate: string;
  if (path.isAbsolute(local)) {
    candidate = path.resolve(local);
  } else {
    // 相対パスは渡された cwd を基準にする（cwd が使えないなら解決できない）。
    if (!cwdRoot) return { ok: false, failure: "bad_path" };
    candidate = path.resolve(cwdRoot, local);
  }
  if (!fs.existsSync(candidate)) return { ok: false, failure: "not_found" };
  const target = realpath(candidate);
  if (!target) return { ok: false, failure: "not_found" };
  if (!roots.some((r) => isInside(target, r))) return { ok: false, failure: "outside_project" };
  return { ok: true, file: target };
}

export async function loadProjectImage(
  rawPath: string,
  cwd: string | undefined,
  projects: string[],
  home: string = os.homedir(),
  resolvePosix?: PosixPathResolver
): Promise<ImageResult> {
  const resolved = await resolveProjectFile(rawPath, cwd, projects, home, resolvePosix);
  if (!resolved.ok) return resolved;
  const ext = path.extname(resolved.file).slice(1).toLowerCase();
  if (!IMAGE_EXTENSIONS.has(ext)) return { ok: false, failure: "not_image" };
  let size: number;
  try {
    const st = fs.statSync(resolved.file);
    if (!st.isFile()) return { ok: false, failure: "not_found" };
    size = st.size;
  } catch {
    return { ok: false, failure: "not_found" };
  }
  if (size > MAX_FILE_BYTES) return { ok: false, failure: "too_large" };
  let data: Buffer;
  try {
    data = fs.readFileSync(resolved.file);
  } catch {
    return { ok: false, failure: "not_found" };
  }
  const mime = sniffImage(data, ext);
  return mime ? { ok: true, data, mime } : { ok: false, failure: "not_image" };
}
