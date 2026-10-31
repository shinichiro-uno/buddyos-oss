# BuddyOS Windows Bridge

A protocol-compatible BuddyOS bridge for Windows (and Linux / WSL for development). It runs CLI coding agents
(Claude Code, Codex, Hermes, OpenCode, Cursor, Grok, Antigravity, ...) on this computer and lets paired phones and
desktops drive them through an end-to-end encrypted relay tunnel. It speaks the same protocol as `mac-bridge`.

The wire protocol (pairing invites, tunnel v3 handshake, transport frames, in-tunnel auth, push and the registry API)
is specified in [`spec/PROTOCOL-v3.md`](../spec/PROTOCOL-v3.md). Shared test vectors live in `shared/`.

## How it connects

```text
device ── Paseo v2 relay (WebSocket) ── src/paseoRelay.ts ── 127.0.0.1:<bridge port>
```

- The bridge listens on `127.0.0.1` only. Nothing has to be opened on the network or the firewall.
- `src/paseoRelay.ts` keeps an outbound control WebSocket to a Paseo v2 relay,
  opens one data WebSocket per relayed connection and forwards it to the local port. It reconnects with backoff
  (2 s up to 30 s).
- Every relayed connection is a tunnel v3 session (Noise_IKpsk2_25519_ChaChaPoly_SHA256, `src/tunnelV3.ts`,
  spec §8–§9). Devices and the bridge authenticate each other with static keys; the relay sees only ciphertext.
- Requests from this computer use the local key (`api-key`). Requests through the tunnel use the device's own `bdc_`
  credential (spec §13). Neither is accepted on the other path.
- Pairing uses one-time invites valid for 10 minutes (spec §6). When started from an interactive terminal the bridge
  prints an invite QR; a supervising desktop app can create invites with `POST /local/pairing/invites` (spec Appendix A).

**You need a relay.** Run your own Paseo relay (or use one you trust) and set `BUDDYOS_PASEO_RELAY_URL`.
Without a relay the bridge still starts, logs a hint, and reports
`"relay": {"configured": false, "hint": "..."}` in `/health`; pairing invites are refused with
`503 relay_not_configured` until a relay is set.

## Build and run

Requires Node.js 20 or newer.

```bash
cd windows-bridge
npm ci
npm run typecheck
npm test

# development (tsx)
BUDDYOS_PASEO_RELAY_URL=wss://relay.example.com/ws npm run dev

# production build
npm run build
BUDDYOS_PASEO_RELAY_URL=wss://relay.example.com/ws npm start
```

On Windows PowerShell set the variable with `$env:BUDDYOS_PASEO_RELAY_URL = "wss://relay.example.com/ws"`.
`scripts/` contains installers for a Task Scheduler task (Windows) and a systemd user unit (Linux / WSL2).

At startup the bridge prints one line that says where each setting came from (environment or built-in default),
without printing values other than the relay URL, for example:

```text
[config] edition=oss relay=env(wss://relay.example.com/ws) registry=none push=none(default) claudeUsage=off(default) openrouterReferer=none
```

Only one bridge runs per configuration directory (a second one exits with code 75). State lives in
`%LOCALAPPDATA%\BuddyOS\Bridge` on Windows and `~/.buddyos-windows-bridge` elsewhere (`api-key`, `bridge-id`,
`e2e-key`, `paseo-relay-id`, `devices.json`, `bridge.port`, ...). These files are private to the user; never share them.

To talk to the bridge from the same computer:

```bash
wscat -c "ws://127.0.0.1:8765/ws/agent/claude" -H "Authorization: Bearer <contents of api-key>"
```

## Configuration

Environment variables always win over the built-in defaults (`src/officialDefaults.ts`). In this public edition
the defaults for hosted services are empty, so each of those features is off until you configure it.

### Hosted services

| Variable | Meaning | When unset |
|---|---|---|
| `BUDDYOS_PASEO_RELAY_URL` | Paseo v2 relay, e.g. `wss://relay.example.com/ws` | No tunnel; hint in the log and `/health` |
| `BUDDYOS_CONVEX_SITE` | Base URL of a registry that implements spec §15 (`/v3/device-token`, `/v3/bridges/register`, `/v3/push-targets`, `/v3/push`). Also read from `~/.buddyos/account.config.json` (`convexSiteUrl`) | No registration; pair with the QR only |
| `BUDDYOS_CLERK_TOKEN` | User session token used once to mint the bridge's registry token (`bdt_`). A desktop app can instead write `~/.buddyos/clerk-access-token` | Registration waits for sign-in |
| `BUDDYOS_PUSH_MODE` | `convex` (seal per device and send through the registry's `/v3/push`, spec §14) or `none`. `apns-direct` is not supported on Windows and is ignored | `convex` if a push relay is configured below, otherwise the default (`none`) |
| `BUDDYOS_PUSH_RELAY_URL`, `BUDDYOS_PUSH_RELAY_TOKEN` | Your own push relay endpoint and bearer token (both required). Payloads are still sealed per device | The registry's `/v3/push` with the bridge's `bdt_` token |
| `BUDDYOS_CLAUDE_USAGE` | `on` reads the Claude Code login on this computer to show subscription usage; `off` never reads or calls it | `off` |
| `BUDDYOS_OPENROUTER_REFERER` | `HTTP-Referer` sent to OpenRouter by the built-in Buddy agent | No header |

### Bridge and agents

| Variable | Meaning |
|---|---|
| `BUDDYOS_BRIDGE_PORT` | Local port (default `8765`). Startup fails if the port is taken; the port in use is written to `bridge.port` |
| `BUDDYOS_BRIDGE_ID` | Fixed bridge id (tests) |
| `BUDDYOS_BRIDGE_API_KEY` | Fixed local key (tests) |
| `BUDDYOS_DEFAULT_CWD` | Working directory for new sessions (default: home) |
| `BUDDYOS_HERMES_MODE`, `BUDDYOS_CLAUDE_MODE`, `BUDDYOS_CODEX_MODE`, `BUDDYOS_OPENCLAW_MODE`, `BUDDYOS_OPENCODE_MODE`, `BUDDYOS_CURSOR_MODE`, `BUDDYOS_GROK_MODE`, `BUDDYOS_ANTIGRAVITY_MODE` | `auto`, `native`, `wsl` or `off` for each agent runtime |
| `BUDDYOS_WSL_DISTRO`, `BUDDYOS_WSL_CWD` | WSL distribution and working directory override for WSL-backed agents |
| `BUDDYOS_WSL_USE_CD` | Inside WSL, `sh` tries to `cd` into the session directory by default. `1` passes `--cd <cwd>` to `wsl.exe` instead, `0` skips the `cd` |
| `HERMES_BIN`, `CLAUDE_BIN`, `CODEX_BIN`, `OPENCODE_BIN`, `OPENCLAW_BIN`, `CURSOR_AGENT_BIN`, `GROK_BIN`, `ANTIGRAVITY_BIN` | Native executable overrides |
| `BUDDYOS_CLAUDE_PERMISSION_MODE`, `BUDDYOS_CLAUDE_MODEL` | Claude Code permission mode and model for headless runs |

## Agents and runtimes

Each agent is an adapter. The bridge itself always runs on the Windows host (pairing, auth, tunnel, push, service
lifecycle); an adapter can run its CLI natively on Windows or inside WSL2. Native is convenient for Windows projects;
WSL2 is usually more stable for POSIX-heavy toolchains. Agents that are not installed are reported as such in
`/health` and fall back to an `echo` adapter that is useful for connection tests.

## 日本語

BuddyOS の Windows 用 Bridge（Linux / WSL でも開発用に動く）。プロトコルは `spec/PROTOCOL-v3.md`。
中継（Paseo）・登録簿・通知は既定で空なので、自分のものを環境変数で指定する
（`BUDDYOS_PASEO_RELAY_URL`・`BUDDYOS_CONVEX_SITE`・`BUDDYOS_PUSH_MODE` など。上の表）。
中継が無くても起動は止まらず、ログと `/health` の `relay.hint` に指定のしかたを出す。
ビルドとテストは `npm ci && npm run typecheck && npm test`。
