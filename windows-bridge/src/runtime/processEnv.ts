/**
 * Bridge 自身の環境から、エージェントとその先のコマンドへ漏らしたくない変数を消す。
 * デスクトップは Windows で Bridge を `BuddyOS.exe bridge.cjs` と ELECTRON_RUN_AS_NODE=1 で動かすので、
 * 消さないとエージェントが起こす Electron のアプリ（`npx electron .` 等）が素の Node として動いて落ちる。
 * Clerk のトークンも Bridge は使わないので、ツールや MCP サーバーに見せない。
 * index.ts の最初の import で読み込み、どの子プロセスより先に消す（各 adapter は process.env を写して使う）。
 */
const DROPPED_KEYS = ["ELECTRON_RUN_AS_NODE", "ELECTRON_NO_ATTACH_CONSOLE", "BUDDYOS_CLERK_TOKEN"];

export function scrubBridgeEnv(env: NodeJS.ProcessEnv = process.env): void {
  for (const key of Object.keys(env)) {
    if (DROPPED_KEYS.includes(key.toUpperCase())) delete env[key];
  }
}

scrubBridgeEnv();
