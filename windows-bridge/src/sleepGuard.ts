import { spawn, type ChildProcess } from "node:child_process";
import { systemExe } from "./runtime/systemExe.js";

/// 生成中・cron の実行中だけ、PC のアイドルスリープを止める（mac の SleepGuard と同じ考え方）。
/// スリープすると走っているエージェントも完了の通知も止まるため。Windows は SetThreadExecutionState を
/// 持ち続ける小さな PowerShell を起こしておき、要らなくなったら終わらせる（プロセスが終われば OS が解除する）。
/// owner（"sessions" / "cron" / "claude-bg"）ごとに要求を持ち、どれかが残っている間は止め続ける。

const SCRIPT =
  "$sig='[DllImport(\"kernel32.dll\")] public static extern uint SetThreadExecutionState(uint f);';" +
  "$k=Add-Type -MemberDefinition $sig -Name P -Namespace W -PassThru;" +
  "[void]$k::SetThreadExecutionState([uint32]'0x80000001');" +
  "[Console]::In.ReadToEnd() | Out-Null";

export class SleepGuard {
  private readonly owners = new Set<string>();
  private child?: ChildProcess;

  constructor(private readonly enabled = process.platform === "win32") {}

  setActive(active: boolean, owner = "sessions"): void {
    if (active) this.owners.add(owner);
    else this.owners.delete(owner);
    if (!this.enabled) return;
    if (this.owners.size > 0 && !this.child) this.hold();
    else if (this.owners.size === 0 && this.child) this.release();
  }

  get held(): boolean {
    return this.owners.size > 0;
  }

  private hold(): void {
    try {
      const child = spawn(systemExe("powershell.exe"), ["-NoProfile", "-NonInteractive", "-Command", SCRIPT], {
        stdio: ["pipe", "ignore", "ignore"],
        windowsHide: true
      });
      child.on("error", () => {
        if (this.child === child) this.child = undefined;
      });
      child.on("exit", () => {
        if (this.child === child) this.child = undefined;
      });
      child.stdin?.on("error", () => {});
      this.child = child;
      console.log(`[sleep-guard] sleep prevented (owners=${[...this.owners].sort().join(",")})`);
    } catch (error) {
      console.warn(`[sleep-guard] could not prevent sleep: ${String(error)}`);
    }
  }

  private release(): void {
    const child = this.child;
    this.child = undefined;
    // 標準入力を閉じると PowerShell が終わり、OS がスリープの抑止を解く。
    try {
      child?.stdin?.end();
    } catch {
      /* 終わっている */
    }
    setTimeout(() => child?.kill(), 2000).unref();
    console.log("[sleep-guard] sleep allowed (idle)");
  }

  stop(): void {
    this.owners.clear();
    if (this.child) this.release();
  }
}
