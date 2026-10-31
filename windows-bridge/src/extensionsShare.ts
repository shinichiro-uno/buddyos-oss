import fs from "node:fs";
import path from "node:path";
import { agentHome, fullMcpSpecs, listMcp, mcpSpecSummary, registerMcp, type McpFullSpec } from "./mcpService.js";
import { parseFrontmatterDescription } from "./skills.js";

/// エージェント間で MCP サーバーとスキルを写す（mac の ExtensionsShare の移植）。
/// list: 入っているエージェントごとの MCP / スキルを並べる（MCP の秘密は出さない）。
/// sync: 選んだものを、持っていないエージェントへ写す（既にあるものは飛ばす）。

const KNOWN: Array<{ id: string; name: string; dir: string; skills: string }> = [
  { id: "claude", name: "Claude Code", dir: ".claude", skills: ".claude/skills" },
  { id: "codex", name: "Codex", dir: ".codex", skills: ".codex/skills" },
  { id: "opencode", name: "OpenCode", dir: ".config/opencode", skills: ".config/opencode/skills" },
  { id: "hermes", name: "Hermes", dir: ".hermes", skills: ".hermes/skills" }
];

interface Agent {
  id: string;
  name: string;
  home: string;
  runtimeLabel?: string;
}

interface SkillEntry {
  name: string;
  description: string;
  dir: string;
}

export type RuntimeLabelOf = (agentId: string) => string | undefined;

async function installedAgents(runtimeLabelOf: RuntimeLabelOf): Promise<Agent[]> {
  const out: Agent[] = [];
  for (const k of KNOWN) {
    const runtimeLabel = runtimeLabelOf(k.id);
    const home = await agentHome(k.id, runtimeLabel);
    if (home && fs.existsSync(path.join(home, k.dir))) out.push({ id: k.id, name: k.name, home, runtimeLabel });
  }
  return out;
}

function skillsRoot(agent: Agent): string {
  return path.join(agent.home, KNOWN.find((k) => k.id === agent.id)!.skills);
}

function agentSkills(agent: Agent): SkillEntry[] {
  const root = skillsRoot(agent);
  const out = new Map<string, SkillEntry>();
  const dirs = (d: string): string[] => {
    try {
      return fs
        .readdirSync(d, { withFileTypes: true })
        .filter((e) => !e.name.startsWith(".") && (e.isDirectory() || e.isSymbolicLink()))
        .map((e) => path.join(d, e.name));
    } catch {
      return [];
    }
  };
  const add = (dir: string): void => {
    const name = path.basename(dir);
    if (out.has(name)) return;
    let description = "";
    try {
      description = parseFrontmatterDescription(fs.readFileSync(path.join(dir, "SKILL.md"), "utf8")) ?? "";
    } catch {
      /* 説明なし */
    }
    out.set(name, { name, description, dir });
  };
  for (const d of dirs(root)) {
    if (fs.existsSync(path.join(d, "SKILL.md"))) add(d);
    else for (const sub of dirs(d)) if (fs.existsSync(path.join(sub, "SKILL.md"))) add(sub);
  }
  return [...out.values()].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }));
}

function skillTarget(agent: Agent, name: string): string | undefined {
  if (!name || name.includes("/") || name.includes("\\") || name.includes("..")) return undefined;
  const root = skillsRoot(agent);
  return agent.id === "hermes" ? path.join(root, "shared", name) : path.join(root, name);
}

/** url のクエリ（トークンが入りがち）を伏せる。 */
export function redactDetail(s: string): string {
  if (s.startsWith("http") && s.includes("?")) return `${s.slice(0, s.indexOf("?"))}?…`;
  return s;
}

/** mac の JSONEncoder(.sortedKeys) と同じく、キーを並べて書き出す。 */
function sortedJson(value: unknown): string {
  const sort = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(sort);
    if (v && typeof v === "object") {
      return Object.fromEntries(Object.keys(v as object).sort().map((k) => [k, sort((v as Record<string, unknown>)[k])]));
    }
    return v;
  };
  return JSON.stringify(sort(value));
}

export async function extensionsList(runtimeLabelOf: RuntimeLabelOf): Promise<string> {
  const agents = await installedAgents(runtimeLabelOf);
  const mcp = new Map<string, { detail: string; agents: string[] }>();
  const skill = new Map<string, { detail: string; agents: string[] }>();
  for (const a of agents) {
    for (const s of await fullMcpSpecs(a.id, a.runtimeLabel)) {
      const e = mcp.get(s.name) ?? { detail: mcpSpecSummary(s), agents: [] };
      e.agents.push(a.id);
      mcp.set(s.name, e);
    }
    for (const s of agentSkills(a)) {
      const e = skill.get(s.name) ?? { detail: s.description, agents: [] };
      e.agents.push(a.id);
      skill.set(s.name, e);
    }
  }
  const items = [
    ...[...mcp].map(([name, e]) => ({ kind: "mcp", name, detail: redactDetail(e.detail), agents: e.agents })),
    ...[...skill].map(([name, e]) => ({ kind: "skill", name, detail: e.detail, agents: e.agents }))
  ].sort((a, b) => (a.kind !== b.kind ? a.kind.localeCompare(b.kind) : a.name.toLowerCase().localeCompare(b.name.toLowerCase())));
  return sortedJson({ agents: agents.map((a) => ({ id: a.id, name: a.name })), items });
}

export async function extensionsSync(runtimeLabelOf: RuntimeLabelOf, items: string[], targetIds: string[]): Promise<string> {
  const agents = await installedAgents(runtimeLabelOf);
  const targets = agents.filter((a) => targetIds.includes(a.id));
  const copied: string[] = [];
  const failed: string[] = [];
  const skipped: string[] = [];
  const specsCache = new Map<string, McpFullSpec[]>();
  const specsOf = async (a: Agent): Promise<McpFullSpec[]> => {
    let hit = specsCache.get(a.id);
    if (!hit) {
      hit = await fullMcpSpecs(a.id, a.runtimeLabel);
      specsCache.set(a.id, hit);
    }
    return hit;
  };
  for (const item of items) {
    const colon = item.indexOf(":");
    if (colon <= 0) continue;
    const kind = item.slice(0, colon);
    const name = item.slice(colon + 1);
    if (kind === "mcp") {
      let source: McpFullSpec | undefined;
      for (const a of agents) {
        source = (await specsOf(a)).find((s) => s.name === name);
        if (source) break;
      }
      if (!source) {
        failed.push(`${item}（元が見つかりません）`);
        continue;
      }
      for (const t of targets) {
        const has = (await specsOf(t)).some((s) => s.name === name) || (await listMcp(t.id, t.runtimeLabel)).some((s) => s.name === name);
        if (has) {
          skipped.push(`${item} → ${t.id}`);
          continue;
        }
        const r = await registerMcp(
          t.id,
          { serverName: name, transportKind: source.kind, url: source.url, command: source.command, args: source.args, authType: "none", env: source.env },
          t.runtimeLabel
        );
        if (r.ok) copied.push(`${item} → ${t.id}`);
        else failed.push(`${item} → ${t.id}: ${r.message ?? "失敗"}`);
      }
    } else if (kind === "skill") {
      let source: SkillEntry | undefined;
      for (const a of agents) {
        source = agentSkills(a).find((s) => s.name === name);
        if (source) break;
      }
      if (!source) {
        failed.push(`${item}（元が見つかりません）`);
        continue;
      }
      for (const t of targets) {
        if (agentSkills(t).some((s) => s.name === name)) {
          skipped.push(`${item} → ${t.id}`);
          continue;
        }
        const dest = skillTarget(t, name);
        if (!dest) {
          failed.push(`${item} → ${t.id}`);
          continue;
        }
        try {
          fs.mkdirSync(path.dirname(dest), { recursive: true });
          fs.cpSync(source.dir, dest, { recursive: true, errorOnExist: true, force: false });
          copied.push(`${item} → ${t.id}`);
        } catch (error) {
          failed.push(`${item} → ${t.id}: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
    }
  }
  return sortedJson({ copied, failed, skipped });
}
