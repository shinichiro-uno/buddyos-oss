import type { RuntimeCommand } from "../runtime/command.js";
import type { JsonSessionStore } from "../sessionStore.js";
import { AcpAdapter } from "./acpAdapter.js";

/// 既存呼び出し元との互換を保つための thin wrapper。
/// Hermes は ACP プロセスに `GLM_BASE_URL` を export して endpoint probe (~12s)
/// をスキップする必要があるため、env を固定で渡す。
export class HermesAcpAdapter extends AcpAdapter {
  constructor(id: string, runtime: RuntimeCommand, store: JsonSessionStore) {
    super(id, runtime, store, {
      displayName: id === "hermes" ? "Hermes" : `Hermes (${runtime.kind})`,
      args: ["acp"],
      tuning: () => ({ delegationLedger: "hermes" }),
      env: {
        GLM_BASE_URL: process.env.GLM_BASE_URL ?? "https://api.z.ai/api/coding/paas/v4"
      }
    });
  }
}
