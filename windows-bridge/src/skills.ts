import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { agentRuntime, wslWindowsPath } from "./agentProbe.js";
import { agentHome } from "./mcpService.js";

/// スキル（SKILL.md）の一覧・読み書き（mac の SkillsService の移植）。
///   - cwd があるとき: <cwd>/.claude/skills（Cursor・Grok・Antigravity はそれぞれが読む場所。読み書きできる）
///   - cwd が無いとき: エージェントごとのホームのスキル（読むだけ）
/// WSL で動くエージェントは、WSL 側のホーム・作業フォルダを Windows から読める UNC パスに直して使う。

export interface SkillSummary {
  name: string;
  description: string;
}

export type SkillOpResult = { ok: true } | { ok: false; message: string };

/** cwd が無いときに読む、エージェントごとのホームのスキル置き場（ホームからの相対）。 */
function globalSkillsRel(agentId: string): string | undefined {
  const base = agentId.split("-")[0];
  switch (base) {
    case "claude":
      return ".claude/skills";
    case "codex":
      return ".codex/skills";
    case "openclaw":
      return ".openclaw/skills";
    case "hermes":
      return ".hermes/skills";
    case "cursor":
      return ".cursor/skills";
    case "grok":
      return ".grok/skills";
    case "antigravity":
      return ".gemini/antigravity-cli/skills";
    default:
      return undefined;
  }
}

/** プロジェクトのスキルの置き場（その CLI が読む場所。mac の projectSkillsDirectory と同じ）。 */
export function projectSkillsRel(agentId: string): string {
  switch (agentId.split("-")[0]) {
    case "cursor":
      return ".cursor/skills";
    case "grok":
      return ".grok/skills";
    // agy は .agents/skills を読む（.claude は読まない）。
    case "antigravity":
      return ".agents/skills";
    default:
      return ".claude/skills";
  }
}

/** 作業フォルダを Windows から読めるパスにする（WSL の /home/... は \\wsl.localhost\... へ）。 */
async function readableCwd(agentId: string, runtimeLabel: string | undefined, cwd: string): Promise<string | undefined> {
  let p = cwd.trim();
  if (!p) return undefined;
  const runtime = agentRuntime(agentId, runtimeLabel);
  if (runtime?.kind === "wsl" && p.startsWith("/")) {
    return wslWindowsPath(runtime, `wslpath -w '${p.replace(/'/g, "'\\''")}'`);
  }
  if (p === "~") p = os.homedir();
  else if (p.startsWith("~/") || p.startsWith("~\\")) p = path.join(os.homedir(), p.slice(2));
  return p;
}

async function skillsRoot(agentId: string, runtimeLabel: string | undefined, cwd: string | undefined): Promise<{ root: string; global: boolean } | undefined> {
  if (cwd?.trim()) {
    const dir = await readableCwd(agentId, runtimeLabel, cwd);
    return dir ? { root: path.join(dir, ...projectSkillsRel(agentId).split("/")), global: false } : undefined;
  }
  const rel = globalSkillsRel(agentId);
  if (!rel) return undefined;
  const home = await agentHome(agentId.split("-")[0], runtimeLabel);
  return home ? { root: path.join(home, rel), global: true } : undefined;
}

/** フロントマターの description（YAML としてではなく 1 行だけ読む。mac と同じ）。 */
export function parseFrontmatterDescription(content: string): string | undefined {
  const lines = content.split(/\r?\n/);
  if (lines[0]?.trim() !== "---") return undefined;
  for (const line of lines.slice(1)) {
    const t = line.trim();
    if (t === "---") break;
    if (!t.toLowerCase().startsWith("description:")) continue;
    let v = t.slice("description:".length).trim();
    if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) v = v.slice(1, -1);
    return v;
  }
  return undefined;
}

function readDescription(dir: string): string {
  try {
    return parseFrontmatterDescription(fs.readFileSync(path.join(dir, "SKILL.md"), "utf8")) ?? "";
  } catch {
    return "";
  }
}

function subdirs(dir: string): string[] {
  try {
    return fs
      .readdirSync(dir, { withFileTypes: true })
      .filter((d) => !d.name.startsWith(".") && (d.isDirectory() || d.isSymbolicLink()))
      .map((d) => d.name);
  } catch {
    return [];
  }
}

const hasSkill = (dir: string): boolean => fs.existsSync(path.join(dir, "SKILL.md"));

export async function listSkills(agentId: string, runtimeLabel: string | undefined, cwd: string | undefined): Promise<SkillSummary[]> {
  const resolved = await skillsRoot(agentId, runtimeLabel, cwd);
  if (!resolved) return [];
  const out: SkillSummary[] = [];
  for (const name of subdirs(resolved.root)) {
    const dir = path.join(resolved.root, name);
    if (hasSkill(dir)) out.push({ name, description: readDescription(dir) });
    // ホームのスキルは「分類/スキル」の 2 段まで見る（~/.hermes/skills/<分類>/<スキル> 等）。
    if (resolved.global) {
      for (const sub of subdirs(dir)) {
        const subDir = path.join(dir, sub);
        if (hasSkill(subDir)) out.push({ name: `${name}/${sub}`, description: readDescription(subDir) });
      }
    }
  }
  return out.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
}

/** スキル名 → フォルダ。".." と、プロジェクトでは "/" を含む名前を断る（ホームは 2 段まで）。 */
function skillDir(root: string, rawName: string, global: boolean): string | undefined {
  const name = rawName.trim().replace(/^\/+|\/+$/g, "");
  if (!name || name.includes("..") || name.includes("\\")) return undefined;
  const parts = name.split("/");
  if (parts.length > (global ? 2 : 1)) return undefined;
  return path.join(root, ...parts);
}

export async function loadSkill(agentId: string, runtimeLabel: string | undefined, cwd: string | undefined, name: string): Promise<string | undefined> {
  const resolved = await skillsRoot(agentId, runtimeLabel, cwd);
  if (!resolved) return undefined;
  const dir = skillDir(resolved.root, name, resolved.global);
  if (!dir) return undefined;
  try {
    return fs.readFileSync(path.join(dir, "SKILL.md"), "utf8");
  } catch {
    return undefined;
  }
}

async function writableDir(agentId: string, runtimeLabel: string | undefined, cwd: string | undefined, name: string): Promise<string | SkillOpResult> {
  if (!cwd?.trim()) return { ok: false, message: "global skills are read-only" };
  const resolved = await skillsRoot(agentId, runtimeLabel, cwd);
  if (!resolved) return { ok: false, message: "project folder is not reachable" };
  const dir = skillDir(resolved.root, name, false);
  return dir ?? { ok: false, message: "invalid skill name" };
}

export async function saveSkill(agentId: string, runtimeLabel: string | undefined, cwd: string | undefined, name: string, content: string): Promise<SkillOpResult> {
  const dir = await writableDir(agentId, runtimeLabel, cwd, name);
  if (typeof dir !== "string") return dir;
  try {
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, "SKILL.md");
    const tmp = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, content, "utf8");
    fs.renameSync(tmp, file);
    return { ok: true };
  } catch (error) {
    return { ok: false, message: error instanceof Error ? error.message : String(error) };
  }
}

export async function deleteSkill(agentId: string, runtimeLabel: string | undefined, cwd: string | undefined, name: string): Promise<SkillOpResult> {
  const dir = await writableDir(agentId, runtimeLabel, cwd, name);
  if (typeof dir !== "string") return dir;
  try {
    fs.rmSync(dir, { recursive: true, force: true });
    return { ok: true };
  } catch (error) {
    return { ok: false, message: error instanceof Error ? error.message : String(error) };
  }
}
