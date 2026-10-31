import type { AgentAdapter } from "../agents/types.js";
import { hermesCreate, hermesList, hermesOp, openclawCreate, openclawList, openclawOp } from "./nativeCron.js";
import type { BridgeCronScheduler, CronCreateSpec, CronJobSummary } from "./scheduler.js";

/// cron の操作をエージェントごとに振り分ける（mac の各 adapter の listCronJobs 等に相当）。
///   - Hermes / OpenClaw: 各 CLI の cron
///   - Bridge 内蔵 scheduler: CLI 1 ターンで完結するエージェント
///   - それ以外（OpenCode / echo / echo に落ちた adapter）: 非対応

const SCHEDULER_AGENTS = new Set(["claude", "codex", "cursor", "grok", "antigravity"]);

export type CronOp = "delete" | "pause" | "resume";

export type CronBackend = "scheduler" | "hermes" | "openclaw" | undefined;

/** echo に落ちた adapter・履歴だけの Codex（runtimeLabel が local:*）は実行先が無いので非対応にする。 */
export function cronBackend(adapter: AgentAdapter): CronBackend {
  if (adapter.runtimeLabel.startsWith("local:")) return undefined;
  if (adapter.id === "hermes") return "hermes";
  if (adapter.id === "openclaw") return "openclaw";
  return SCHEDULER_AGENTS.has(adapter.id) ? "scheduler" : undefined;
}

export class CronService {
  constructor(private readonly scheduler: BridgeCronScheduler) {}

  async list(adapter: AgentAdapter): Promise<CronJobSummary[]> {
    switch (cronBackend(adapter)) {
      case "hermes":
        return hermesList(adapter.runtimeLabel);
      case "openclaw":
        return openclawList(adapter.runtimeLabel);
      case "scheduler":
        return this.scheduler.list(adapter.id);
      default:
        return [];
    }
  }

  async create(adapter: AgentAdapter, spec: CronCreateSpec): Promise<string> {
    switch (cronBackend(adapter)) {
      case "hermes":
        return hermesCreate(adapter.runtimeLabel, spec);
      case "openclaw":
        return openclawCreate(adapter.runtimeLabel, spec);
      case "scheduler":
        return this.scheduler.create(adapter.id, spec);
      default:
        throw new Error("cron not supported");
    }
  }

  async op(adapter: AgentAdapter, op: CronOp, jobId: string): Promise<void> {
    switch (cronBackend(adapter)) {
      case "hermes":
        return hermesOp(adapter.runtimeLabel, op, jobId);
      case "openclaw":
        return openclawOp(adapter.runtimeLabel, op, jobId);
      case "scheduler":
        if (op === "delete") this.scheduler.delete(adapter.id, jobId);
        else this.scheduler.setEnabled(adapter.id, jobId, op === "resume");
        return;
      default:
        throw new Error("cron not supported");
    }
  }
}
