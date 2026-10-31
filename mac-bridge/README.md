# BuddyOS Bridge for macOS (`mac-bridge`)

The Bridge is a small resident process on your Mac. It starts local CLI coding agents
(Claude Code, Codex, OpenCode, Hermes, and others) and lets the BuddyOS phone and desktop apps
talk to them through an end-to-end encrypted tunnel over a [Paseo](https://github.com/getpaseo/paseo) relay.

- It listens only on `127.0.0.1` (port 8765, or the next free one; the actual port is written to `~/.buddyos/bridge.port`).
- Devices reach it only through the relay, using the device authentication and tunnel protocol in
  [`spec/PROTOCOL-v3.md`](../spec/PROTOCOL-v3.md) (Noise_IKpsk2 handshake, per-device keys, QR pairing).
- Only one Bridge runs per user (`~/.buddyos/bridge.lock`); a second one exits with status 75.
- Keys, pairings and settings live in `~/.buddyos/` (mode 0700). Nothing in this directory is ever sent anywhere.

## Requirements

- macOS 15.6 or later
- Swift 6 toolchain (Xcode 16 or later, or the matching command line tools)

## Build and run

```bash
cd mac-bridge
swift build
BUDDYOS_PASEO_RELAY_URL=wss://relay.example.com/ws swift run BridgeApp
```

When started from a terminal, the Bridge prints a one-time pairing QR code (valid for 10 minutes).
Set `BUDDYOS_MENU_BAR=1` to show a menu bar icon with a "Show QR" item instead.

Run the tests:

```bash
swift test
```

Tests that drive real agent CLIs are skipped unless you opt in (for example `BUDDYOS_LIVE_ACP=grok`).

### Run as a LaunchAgent

```bash
mac-bridge/scripts/setup-launchd.sh
```

This builds a release binary, copies it to `~/.buddyos/bin/BridgeApp`, signs it, installs
`~/Library/LaunchAgents/<prefix>.bridge.plist` (from `LaunchAgents/bridge.plist.template`) and starts it.
The script prints the label; stop the service with `launchctl bootout gui/$UID/<label>`.

- Signing uses `BUDDYOS_CODESIGN_IDENTITY` (default `-`, ad-hoc). With ad-hoc signing macOS forgets
  privacy permissions (microphone, speech recognition) after each rebuild; set the variable to the name of a
  code signing certificate in your keychain to keep them.
- The development LaunchAgent listens on port 8764. Add the environment variables below to the
  `EnvironmentVariables` dictionary of the installed plist if you need them.

## Configuration

Environment variables always win. Values that are not set fall back to the built-in defaults in
`Sources/BridgeApp/OfficialDefaults.swift`, which are **empty in the open-source edition**: a feature
without a value is simply off, and the Bridge keeps running. At startup the Bridge logs one line saying where
each setting came from (values are not logged, except the relay URL).

| Variable | Purpose | When unset (open-source edition) |
|---|---|---|
| `BUDDYOS_PASEO_RELAY_URL` | Paseo relay, e.g. `wss://relay.example.com/ws` | No tunnel. The Bridge logs a hint and `/health` contains `"relay":{"configured":false,"hint":"…"}` |
| `BUDDYOS_CONVEX_SITE` | Registry (HTTP API in spec §15) used to find this Mac from a signed-in account. `convexSiteUrl` in `~/.buddyos/account.config.json` is also read | Not registered; pair by QR code only |
| `BUDDYOS_PUSH_MODE` | `none`, `convex` (registry `/v3/push`), `apns-direct`, or `auto` (APNs if a key file exists, else `convex`) | `none`: no notifications |
| `BUDDYOS_PUSH_RELAY_URL`, `BUDDYOS_PUSH_RELAY_TOKEN` | Send pushes to your own relay with the `/v3/push` body (implies `convex` mode) | — |
| `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_ENV` | `apns-direct`: your own `.p8` key and app (`APNS_ENV` = `development` or `production`) | `apns-direct` is unavailable |
| `BUDDYOS_CLAUDE_USAGE` | `on` / `off`. Shows Claude subscription usage by reading the Claude Code login and calling its usage endpoint | `off`: the login is not read |
| `BUDDYOS_OPENROUTER_REFERER` | `HTTP-Referer` sent with OpenRouter requests | Header not sent |
| `BUDDYOS_ID_PREFIX` | Reverse-DNS prefix for the LaunchAgent label (`<prefix>.bridge`). `BridgeApp --print-id-prefix` prints the effective value | `dev.buddyos.oss` |
| `BUDDYOS_BRIDGE_PORT` | Listen port | 8765 or the next free port |
| `BUDDYOS_MENU_BAR` | `1` shows the menu bar icon | No icon |
| `HERMES_BIN` | Absolute path of the Hermes executable | Looked up on `PATH` |

Notifications are always end-to-end encrypted per device (spec §14); the relay and APNs only see a placeholder.

## Checking the relay path

```bash
node scripts/paseo-health-check.mts --relay wss://relay.example.com/ws   # or set BUDDYOS_PASEO_RELAY_URL
node scripts/paseo-health-check.mts --self-test                          # protocol test vectors only
```

The check performs a v3 handshake with a throw-away key and expects the Bridge to answer
`unknown_device`, which proves the tunnel works without pairing anything.

## Layout

| Path | Contents |
|---|---|
| `Sources/BridgeApp` | Entry point, server start-up, device store, pairing invites, approvals, configuration |
| `Sources/Network` | WebSocket and HTTP routes, relay tunnel (`PaseoRelayTunnel.swift`, `TunnelV3.swift`), push, registry, usage |
| `Sources/Agents` | Adapters for each agent CLI |
| `Sources/Preview` | Live preview (iOS Simulator stream, web reverse proxy) |
| `Tests/BridgeAppTests` | Unit tests, protocol conformance and shared test vectors (`../shared/e2e-test-vectors.json`) |

## 日本語

Mac で CLI のエージェントを動かし、スマホとデスクトップのアプリから Paseo の中継（エンドツーエンド暗号化）で操作するための常駐プロセスです。
中継・登録簿・通知の送り先は環境変数で指定します（上の表）。公開版は既定がすべて空なので、`BUDDYOS_PASEO_RELAY_URL` に自分の中継を指定してください。
指定が無い機能は動かないだけで、Bridge は止まりません。通信の仕様は [`spec/PROTOCOL-v3.md`](../spec/PROTOCOL-v3.md) です。
