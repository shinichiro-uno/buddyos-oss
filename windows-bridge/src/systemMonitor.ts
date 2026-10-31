import os from "node:os";

/// スリープからの復帰とネットワークの変化を見つける（mac の PowerEventMonitor / NetworkMonitor の代わり）。
/// 中継（Paseo）の接続は生存確認で張り直されるが、それを待たずにすぐ張り直すために使う。
///   復帰: 見回りのタイマーが大きく遅れた（PC が止まっていた）
///   ネットワーク: 使えるアドレスの組み合わせが変わった（最後の変化から 2 秒待ってから知らせる）

const TICK_MS = 5000;
const WAKE_GAP_MS = 20_000;
const DEBOUNCE_MS = 2000;

export function networkSignature(): string {
  const parts: string[] = [];
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs ?? []) if (!a.internal) parts.push(`${name}:${a.family}:${a.address}`);
  }
  return parts.sort().join(",");
}

export function startSystemMonitor(onChange: (reason: "wake" | "network") => void): () => void {
  let last = Date.now();
  let signature = networkSignature();
  let debounce: NodeJS.Timeout | undefined;
  const timer = setInterval(() => {
    const now = Date.now();
    const gap = now - last;
    last = now;
    if (gap > WAKE_GAP_MS) {
      signature = networkSignature();
      onChange("wake");
      return;
    }
    const next = networkSignature();
    if (next === signature) return;
    signature = next;
    if (debounce) clearTimeout(debounce);
    debounce = setTimeout(() => onChange("network"), DEBOUNCE_MS);
    debounce.unref();
  }, TICK_MS);
  timer.unref();
  return () => {
    clearInterval(timer);
    if (debounce) clearTimeout(debounce);
  };
}
