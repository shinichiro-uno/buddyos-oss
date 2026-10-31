import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/// 作業フォルダ（プロジェクト）の一覧（mac の ProjectRegistry の移植）。iPhone とデスクトップが共有する。
/// 新しく足したものが先頭。同じパスを足し直すと名前だけ変わり、位置と追加時刻は保つ。

export interface ProjectItem {
  path: string;
  name: string;
  /** 追加時刻（epoch 秒、小数あり）。 */
  addedAt: number;
}

export class ProjectRegistry {
  constructor(private readonly file: string) {}

  list(): ProjectItem[] {
    try {
      const parsed = JSON.parse(fs.readFileSync(this.file, "utf8"));
      if (!Array.isArray(parsed)) return [];
      return parsed.filter(
        (p): p is ProjectItem => p && typeof p.path === "string" && typeof p.name === "string" && typeof p.addedAt === "number"
      );
    } catch {
      return [];
    }
  }

  add(rawPath: string, name?: string): ProjectItem[] {
    const p = normalizeProjectPath(rawPath);
    const items = this.list();
    if (!p) return items;
    const n = name?.trim() || projectDisplayName(p);
    const existing = items.find((i) => i.path === p);
    if (existing) existing.name = n;
    else items.unshift({ path: p, name: n, addedAt: Date.now() / 1000 });
    this.save(items);
    return items;
  }

  remove(rawPath: string): ProjectItem[] {
    const p = normalizeProjectPath(rawPath);
    const items = this.list().filter((i) => i.path !== p);
    this.save(items);
    return items;
  }

  reorder(paths: string[]): ProjectItem[] {
    const items = this.list();
    const byPath = new Map(items.map((i) => [i.path, i]));
    const out: ProjectItem[] = [];
    const used = new Set<string>();
    for (const raw of paths) {
      const p = normalizeProjectPath(raw);
      const item = byPath.get(p);
      if (!item || used.has(p)) continue;
      used.add(p);
      out.push(item);
    }
    for (const item of items) if (!used.has(item.path)) out.push(item);
    this.save(out);
    return out;
  }

  private save(items: ProjectItem[]): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(items, null, 2));
    fs.renameSync(tmp, this.file);
  }
}

const isWindowsPath = (p: string): boolean => /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("\\\\");

/** Windows のパス（C:\ / UNC）はそのまま、POSIX（WSL）のパスは ~ を展開して整える。末尾の / は 1 つ落とす。 */
export function normalizeProjectPath(raw: string): string {
  const p = raw.trim();
  if (!p) return "";
  if (isWindowsPath(p)) return p;
  let expanded = p;
  if (p === "~") expanded = os.homedir();
  else if (p.startsWith("~/")) expanded = path.posix.join(os.homedir().replace(/\\/g, "/"), p.slice(2));
  let normalized = path.posix.normalize(expanded);
  if (normalized.length > 1 && normalized.endsWith("/")) normalized = normalized.slice(0, -1);
  return normalized;
}

export function projectDisplayName(p: string): string {
  const base = isWindowsPath(p) ? path.win32.basename(p) : path.posix.basename(p);
  return base || p;
}
