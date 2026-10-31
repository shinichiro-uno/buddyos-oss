import fs from "node:fs";
import path from "node:path";
import { agentRuntime, execRuntime } from "../agentProbe.js";
import { agentHome } from "../mcpService.js";
import type { CronCreateSpec, CronJobSummary } from "./scheduler.js";

/// Hermes / OpenClaw は自前の cron を持つので、Bridge の scheduler ではなく各 CLI に任せる
/// （mac の HermesAdapter / OpenclawAdapter の cron と同じ）。WSL で動くときは WSL 側の CLI と設定を使う。

const CLI_TIMEOUT_MS = 30_000;

async function runCli(agentId: string, runtimeLabel: string, args: string[]): Promise<string> {
  const runtime = agentRuntime(agentId, runtimeLabel);
  if (!runtime) throw new Error(`${agentId} CLI が見つかりません`);
  const r = await execRuntime(runtime, args, CLI_TIMEOUT_MS);
  if (!r.ok) throw new Error((r.stderr.trim() || r.stdout.trim() || r.error) ?? "failed");
  return r.stdout;
}

async function readJson(agentId: string, runtimeLabel: string, rel: string): Promise<unknown> {
  const home = await agentHome(agentId, runtimeLabel);
  if (!home) return undefined;
  try {
    return JSON.parse(fs.readFileSync(path.join(home, rel), "utf8"));
  } catch {
    return undefined;
  }
}

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
const num = (v: unknown): number | undefined => (typeof v === "number" && Number.isFinite(v) ? v : undefined);

/* ── Hermes ─────────────────────────────────────────────────────────── */

export function hermesJobs(raw: unknown): CronJobSummary[] {
  const jobs = Array.isArray(obj(raw).jobs) ? (obj(raw).jobs as unknown[]) : [];
  const out: CronJobSummary[] = [];
  for (const item of jobs) {
    const j = obj(item);
    const id = str(j.id);
    const name = str(j.name);
    if (!id || !name) continue;
    const enabled = typeof j.enabled === "boolean" ? j.enabled : true;
    const summary: CronJobSummary = {
      id,
      name,
      prompt: str(j.prompt) ?? "",
      scheduleDisplay: str(j.schedule_display) ?? str(obj(j.schedule).display) ?? "(unknown)",
      deliver: str(j.deliver) ?? "local",
      enabled,
      state: (str(j.state) as CronJobSummary["state"]) ?? "scheduled"
    };
    const next = str(j.next_run_at);
    const last = str(j.last_run_at);
    const status = str(j.last_status);
    if (next) summary.nextRunAt = next;
    if (last) summary.lastRunAt = last;
    if (status) summary.lastStatus = status;
    out.push(summary);
  }
  return out;
}

export async function hermesList(runtimeLabel: string): Promise<CronJobSummary[]> {
  return hermesJobs(await readJson("hermes", runtimeLabel, ".hermes/cron/jobs.json"));
}

export async function hermesCreate(runtimeLabel: string, spec: CronCreateSpec): Promise<string> {
  const args = ["cron", "create"];
  if (spec.name) args.push("--name", spec.name);
  if (spec.deliver) args.push("--deliver", spec.deliver);
  if (spec.repeatCount && spec.repeatCount > 0) args.push("--repeat", String(spec.repeatCount));
  args.push(spec.schedule, spec.prompt);
  await runCli("hermes", runtimeLabel, args);
  return (await hermesList(runtimeLabel)).at(-1)?.id ?? "unknown";
}

export async function hermesOp(runtimeLabel: string, op: "delete" | "pause" | "resume", jobId: string): Promise<void> {
  await runCli("hermes", runtimeLabel, ["cron", op === "delete" ? "remove" : op, jobId]);
}

/* ── OpenClaw ───────────────────────────────────────────────────────── */

function formatDuration(ms: number): string {
  const s = Math.round(ms / 1000);
  if (s % 86400 === 0) return `${s / 86400}d`;
  if (s % 3600 === 0) return `${s / 3600}h`;
  if (s % 60 === 0) return `${s / 60}m`;
  return `${s}s`;
}

export function openclawJobs(raw: unknown): CronJobSummary[] {
  const jobs = Array.isArray(obj(raw).jobs) ? (obj(raw).jobs as unknown[]) : [];
  const out: CronJobSummary[] = [];
  for (const item of jobs) {
    const j = obj(item);
    const id = str(j.id) ?? (num(j.id) !== undefined ? String(j.id) : undefined);
    if (!id) continue;
    const enabled = typeof j.enabled === "boolean" ? j.enabled : true;
    const schedule = obj(j.schedule);
    const state = obj(j.state);
    let display = "(unknown)";
    if (schedule.kind === "every" && num(schedule.everyMs)) display = `every ${formatDuration(num(schedule.everyMs)!)}`;
    else if (schedule.kind === "cron" && str(schedule.expr)) display = `cron ${str(schedule.expr)}`;
    else if (schedule.kind === "at" && num(schedule.atMs)) display = `at ${new Date(num(schedule.atMs)!).toISOString()}`;
    const summary: CronJobSummary = {
      id,
      name: str(j.name) ?? str(j.description) ?? id,
      prompt: str(obj(j.payload).message) ?? "",
      scheduleDisplay: display,
      deliver: str(obj(j.delivery).mode) ?? "local",
      enabled,
      state: enabled ? "scheduled" : "paused"
    };
    const next = num(state.nextRunAtMs);
    const last = num(state.lastRunAtMs);
    const status = str(state.lastStatus) ?? str(state.lastRunStatus);
    if (next) summary.nextRunAt = new Date(next).toISOString();
    if (last) summary.lastRunAt = new Date(last).toISOString();
    if (status) summary.lastStatus = status;
    out.push(summary);
  }
  return out;
}

export async function openclawList(runtimeLabel: string): Promise<CronJobSummary[]> {
  try {
    return openclawJobs(JSON.parse(await runCli("openclaw", runtimeLabel, ["cron", "list", "--all", "--json"])));
  } catch {
    return openclawJobs(await readJson("openclaw", runtimeLabel, ".openclaw/cron/jobs.json"));
  }
}

export function openclawAddArgs(spec: CronCreateSpec): string[] {
  const args = ["cron", "add", "--json"];
  if (spec.name) args.push("--description", spec.name);
  const schedule = spec.schedule.trim();
  if (schedule.startsWith("every ")) args.push("--every", schedule.slice("every ".length).trim());
  else if (schedule.startsWith("+")) args.push("--at", schedule);
  else if (schedule.includes(" ")) args.push("--cron", schedule);
  else args.push("--every", schedule);
  if (spec.deliver === "announce") args.push("--announce");
  if (spec.repeatCount === 1) args.push("--delete-after-run");
  args.push(spec.prompt);
  return args;
}

export async function openclawCreate(runtimeLabel: string, spec: CronCreateSpec): Promise<string> {
  const stdout = await runCli("openclaw", runtimeLabel, openclawAddArgs(spec));
  try {
    const parsed = obj(JSON.parse(stdout));
    const id = str(parsed.id) ?? str(obj(parsed.job).id);
    if (id) return id;
  } catch {
    /* 一覧から拾う */
  }
  return (await openclawList(runtimeLabel)).at(-1)?.id ?? "unknown";
}

export async function openclawOp(runtimeLabel: string, op: "delete" | "pause" | "resume", jobId: string): Promise<void> {
  const verb = op === "delete" ? "rm" : op === "pause" ? "disable" : "enable";
  await runCli("openclaw", runtimeLabel, ["cron", verb, jobId]);
}
