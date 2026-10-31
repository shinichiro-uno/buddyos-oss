import type { ChildProcessWithoutNullStreams } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { agentRuntime, clearProbeCache, probeAgent } from "./agentProbe.js";
import type { SessionEvent } from "./protocol.js";
import { killProcessTree, spawnRuntime } from "./runtime/command.js";

/// iPhone からエージェントの CLI にログインする（mac の AgentLoginService の移植）。
/// CLI のログインコマンドを起動し、出力から URL と端末コードを拾って iPhone に見せる。
/// Claude は認可後に表示されるコードを iPhone から入力してもらい、標準入力へ流す。

export type LoginPhase = "starting" | "waiting" | "verifying" | "succeeded" | "failed" | "cancelled" | "idle";

export interface LoginStatus {
  agentId: string;
  phase: LoginPhase;
  needsCode: boolean;
  url?: string;
  code?: string;
  message?: string;
}

interface LoginSpec {
  args: string[];
  needsCode: boolean;
  env?: Record<string, string>;
}

const SPECS: Record<string, LoginSpec> = {
  codex: { args: ["login", "--device-auth"], needsCode: false },
  grok: { args: ["login", "--device-auth"], needsCode: false },
  cursor: { args: ["login"], needsCode: false, env: { NO_OPEN_BROWSER: "1" } },
  claude: { args: ["auth", "login"], needsCode: true }
};

/** iPhone からログインできるか（id の先頭で引く。capabilities.login の出どころ）。 */
export function loginSupported(agentId: string): boolean {
  return SPECS[agentId.split("-")[0]] !== undefined;
}

const WATCHDOG_MS = 15 * 60_000;
const STATUS_TTL_MS = 30 * 60_000;
const OUTPUT_KEEP = 16_000;

export function loginStatusEvent(s: LoginStatus): SessionEvent {
  const metadata: Record<string, string> = { phase: s.phase, needsCode: s.needsCode ? "1" : "0" };
  if (s.url) metadata.url = s.url;
  if (s.code) metadata.code = s.code;
  if (s.message) metadata.message = s.message;
  return { type: "agent_login_status", agentId: s.agentId, metadata };
}

export function stripAnsi(s: string): string {
  return s
    .replace(/\u001b\][^\u0007\u001b]*(\u0007|\u001b\\)/g, "")
    .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "");
}

/** 出力から URL と端末コード（ABCD-1234 の形）を拾う。 */
export function parseLoginOutput(raw: string): { url?: string; code?: string } {
  const text = stripAnsi(raw);
  const url = /https:\/\/[^\s"'<>]+/.exec(text)?.[0];
  const code = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .find((l) => !l.includes("://") && /^[A-Z0-9]{4,5}-[A-Z0-9]{4,6}$/.test(l));
  return { url, code };
}

interface Running {
  child: ChildProcessWithoutNullStreams;
  spec: LoginSpec;
  output: string;
  last: LoginStatus;
  cancelled: boolean;
  watchdog: NodeJS.Timeout;
}

type Listener = (s: LoginStatus) => void;

export class AgentLoginService {
  private readonly running = new Map<string, Running>();
  private readonly latest = new Map<string, { at: number; status: LoginStatus }>();
  private readonly listeners = new Set<Listener>();

  /** 1 本の接続につき 1 回。その接続にはすべてのエージェントのログイン状態が届く（iOS が agentId で絞る）。 */
  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  status(agentId: string): LoginStatus | undefined {
    const run = this.running.get(agentId);
    if (run) return run.last;
    const hit = this.latest.get(agentId);
    return hit && Date.now() - hit.at < STATUS_TTL_MS ? hit.status : undefined;
  }

  async start(agentId: string, runtimeLabel: string | undefined): Promise<void> {
    const existing = this.running.get(agentId);
    if (existing) {
      this.publish(existing.last);
      return;
    }
    const spec = SPECS[agentId.split("-")[0]];
    if (!spec) {
      this.publish({ agentId, phase: "failed", needsCode: false, message: "unsupported" });
      return;
    }
    const probe = await probeAgent(agentId, runtimeLabel);
    const runtime = agentRuntime(agentId.split("-")[0], runtimeLabel);
    if (!probe.installed || !runtime) {
      this.publish({ agentId, phase: "failed", needsCode: spec.needsCode, message: "not-installed" });
      return;
    }
    if (this.running.has(agentId)) {
      this.publish(this.running.get(agentId)!.last);
      return;
    }
    const env: NodeJS.ProcessEnv = { ...process.env, NO_COLOR: "1", ...spec.env };
    const grokBin = path.join(os.homedir(), ".grok", "bin");
    env.PATH = [grokBin, process.env.PATH ?? ""].filter(Boolean).join(path.delimiter);
    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawnRuntime(runtime, spec.args, { cwd: runtime.kind === "wsl" ? undefined : os.homedir(), env, stdio: "pipe" });
    } catch (error) {
      this.publish({ agentId, phase: "failed", needsCode: spec.needsCode, message: error instanceof Error ? error.message : String(error) });
      return;
    }
    const run: Running = {
      child,
      spec,
      output: "",
      last: { agentId, phase: "starting", needsCode: spec.needsCode },
      cancelled: false,
      watchdog: setTimeout(() => this.cancel(agentId), WATCHDOG_MS)
    };
    run.watchdog.unref();
    this.running.set(agentId, run);
    this.publish(run.last);

    const consume = (chunk: Buffer | string): void => {
      run.output = (run.output + String(chunk)).slice(-OUTPUT_KEEP);
      const { url, code } = parseLoginOutput(run.output);
      if (url && (url !== run.last.url || code !== run.last.code)) {
        run.last = { agentId, phase: "waiting", needsCode: spec.needsCode, url, code };
        this.publish(run.last);
      }
    };
    child.stdout.on("data", consume);
    child.stderr.on("data", consume);
    child.stdin.on("error", () => {});
    let exited = false;
    const onExit = (code: number | null): void => {
      if (exited) return;
      exited = true;
      void this.finish(agentId, run, code, runtimeLabel);
    };
    child.on("error", () => onExit(null));
    child.on("close", (code) => onExit(code));
  }

  submitCode(agentId: string, code: string): void {
    const run = this.running.get(agentId);
    const trimmed = code.trim();
    if (!run || !trimmed) return;
    try {
      run.child.stdin.write(`${trimmed}\n`);
    } catch {
      /* 終わった */
    }
  }

  cancel(agentId: string): void {
    const run = this.running.get(agentId);
    if (!run) return;
    run.cancelled = true;
    killProcessTree(run.child);
  }

  private async finish(agentId: string, run: Running, code: number | null, runtimeLabel: string | undefined): Promise<void> {
    clearTimeout(run.watchdog);
    this.running.delete(agentId);
    try {
      run.child.stdin.end();
    } catch {
      /* 閉じている */
    }
    if (run.cancelled) {
      this.publish({ agentId, phase: "cancelled", needsCode: run.spec.needsCode });
      return;
    }
    this.publish({ ...run.last, phase: "verifying" });
    clearProbeCache();
    const probe = await probeAgent(agentId, runtimeLabel);
    if (probe.configured) {
      this.publish({ agentId, phase: "succeeded", needsCode: run.spec.needsCode });
      return;
    }
    const tail = stripAnsi(run.output)
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean)
      .slice(-3)
      .join("\n");
    this.publish({ agentId, phase: "failed", needsCode: run.spec.needsCode, message: tail || `exit ${code ?? "?"}` });
  }

  private publish(status: LoginStatus): void {
    if (this.running.has(status.agentId)) this.running.get(status.agentId)!.last = status;
    this.latest.set(status.agentId, { at: Date.now(), status });
    for (const l of [...this.listeners]) l(status);
  }
}
