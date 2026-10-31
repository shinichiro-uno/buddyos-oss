// OpenCode skills (read-only) for windows-bridge.
//
// OpenCode のスキルは `~/.config/opencode/skills/<name>/SKILL.md` に置かれ、
// frontmatter の `name` / `description` を持つ単層ディレクトリ構成。BuddyOS からは
// 読み取り専用（save/delete 不可）。mac SkillsService の opencode 分岐と同形。

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export interface OpenCodeSkill {
  name: string;
  description: string;
}

/** `~/.config/opencode/skills` の絶対パス。 */
export function opencodeSkillsRoot(): string {
  return join(homedir(), ".config", "opencode", "skills");
}

/** 直下の各 `<name>/SKILL.md` を列挙し、frontmatter から name/description を取る。 */
export function listOpencodeSkills(): OpenCodeSkill[] {
  const root = opencodeSkillsRoot();
  if (!existsSync(root)) return [];
  let entries: string[];
  try {
    entries = readdirSync(root);
  } catch {
    return [];
  }
  const skills: OpenCodeSkill[] = [];
  for (const entry of entries) {
    const skillFile = join(root, entry, "SKILL.md");
    let raw: string;
    try {
      if (!statSync(join(root, entry)).isDirectory()) continue;
      raw = readFileSync(skillFile, "utf8");
    } catch {
      continue;
    }
    const front = parseFrontmatter(raw);
    skills.push({
      name: front.name ?? entry,
      description: front.description ?? ""
    });
  }
  return skills.sort((a, b) => a.name.localeCompare(b.name));
}

/** スキル名集合（commands との de-dup 用）。 */
export function opencodeSkillNames(): Set<string> {
  return new Set(listOpencodeSkills().map((skill) => skill.name));
}

/** スキル名として使えるか（単層のフォルダ名だけ。".."・区切り・ドライブ指定・空は断る）。 */
export function isValidOpencodeSkillName(name: string): boolean {
  return name.length > 0 && name !== "." && !name.includes("..") && !/[\\/:\0]/.test(name);
}

/** 指定スキルの SKILL.md 全文（無ければ・名前が不正なら undefined）。 */
export function loadOpencodeSkill(name: string): string | undefined {
  if (!isValidOpencodeSkillName(name)) return undefined;
  const skillFile = join(opencodeSkillsRoot(), name, "SKILL.md");
  try {
    return readFileSync(skillFile, "utf8");
  } catch {
    return undefined;
  }
}

/** `---` で囲んだ YAML 風 frontmatter から name/description を抽出する。 */
function parseFrontmatter(raw: string): { name?: string; description?: string } {
  const match = /^---\s*\n([\s\S]*?)\n---/.exec(raw);
  if (!match) return {};
  const out: { name?: string; description?: string } = {};
  for (const line of match[1].split("\n")) {
    const idx = line.indexOf(":");
    if (idx < 0) continue;
    const key = line.slice(0, idx).trim();
    const value = stripQuotes(line.slice(idx + 1).trim());
    if (key === "name") out.name = value;
    else if (key === "description") out.description = value;
  }
  return out;
}

function stripQuotes(s: string): string {
  if (s.length >= 2 && ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))) {
    return s.slice(1, -1);
  }
  return s;
}
