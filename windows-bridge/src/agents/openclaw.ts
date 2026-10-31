import type { RuntimeCommand } from "../runtime/command.js";
import type { JsonSessionStore } from "../sessionStore.js";
import { AcpAdapter } from "./acpAdapter.js";

/// OpenClaw ACP adapter (Windows bridge 側)。
///
/// OpenClaw は npm でインストールされる Node.js CLI で、`openclaw acp` で
/// Hermes と同じ ACP プロトコル (protocolVersion: 1, stdio JSON-RPC) を喋る。
/// Gateway daemon が同ホストの port 18789 で動いている必要がある。
export class OpenclawAcpAdapter extends AcpAdapter {
  constructor(id: string, runtime: RuntimeCommand, store: JsonSessionStore) {
    super(id, runtime, store, {
      displayName: id === "openclaw" ? "OpenClaw" : `OpenClaw (${runtime.kind})`,
      args: ["acp"],
      tuning: () => ({ delegationLedger: "openclaw" })
    });
  }
}
