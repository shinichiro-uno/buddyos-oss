# BuddyOS Bridge & Protocol

Control the coding agents on your computer — Claude Code, Codex, OpenCode, Hermes, Antigravity and others — from your phone, over an end-to-end encrypted relay.

This repository contains the parts of BuddyOS that run **on your own machine**, published so that anyone can audit exactly what runs there:

| Path | What it is |
|---|---|
| `mac-bridge/` | macOS bridge (Swift, Vapor). Launches agent CLIs, streams their sessions, shows a pairing QR. |
| `windows-bridge/` | Windows / Linux bridge (TypeScript, Node.js). Same wire protocol; prints the pairing QR in the terminal. Includes `scripts/install-linux.sh`. |
| `shared/` | The wire protocol (`protocol.json`), test vectors, and a reference implementation of tunnel v3 (`tools/tunnelV3Ref.mts`). |
| `scripts/` | Scripts that install BuddyOS hooks/channels into agent CLIs (they edit your agent configuration — read them before running). |
| `spec/` | `PROTOCOL-v3.md`, the public wire specification (CC-BY-4.0). |

The phone apps, the desktop manager app and the hosted services (account registry, push relay, billing) are **not** in this repository yet. You can pair a self-built bridge with the official BuddyOS app.

## How it works

```
phone app ──E2E (Noise IKpsk2, ChaCha20-Poly1305)──▶ relay ──▶ bridge (127.0.0.1 only) ──▶ agent CLI (PTY / ACP / stdio)
```

- The bridge listens on `127.0.0.1` only and keeps an **outbound** connection to a relay. No inbound port or firewall change is needed.
- Phones are paired with a one-time invite (QR code or `buddyos://pair?v=3…` link, valid 10 minutes, single use). Each paired device has its own static key; the relay only ever sees ciphertext and ephemeral keys.
- See [`spec/PROTOCOL-v3.md`](spec/PROTOCOL-v3.md) for the full protocol and `shared/*.json` for the test vectors every implementation must pass.

## Build

```bash
# macOS bridge — macOS 15.6+, Swift 6 (Xcode 16+)
cd mac-bridge
swift build -c release
swift test

# Windows / Linux bridge — Node.js 20+ (22 recommended)
cd windows-bridge
npm ci
npm run typecheck && npm test
npm run build && npm start

# Check the protocol reference implementation against the vectors
node --experimental-strip-types shared/tools/check-tunnel-v3.mts
```

`SOURCE_REVISION` at the repository root records the source commit this tree was exported from.

## Configuration

The open-source build contains **no official endpoints or IDs**. A feature whose setting is empty stays off.

| Setting | Purpose | Default |
|---|---|---|
| `BUDDYOS_PASEO_RELAY_URL` | Relay WebSocket URL, e.g. `wss://relay.example.com/ws` | empty — the bridge starts and tells you to set a relay |
| `BUDDYOS_CONVEX_SITE` or `~/.buddyos/account.config.json` | Account registry (lets your phone find your PCs) | empty — QR pairing only |
| `BUDDYOS_PUSH_MODE`: `none` or `convex` (macOS also `auto` and `apns-direct`). Setting both `BUDDYOS_PUSH_RELAY_URL` and `BUDDYOS_PUSH_RELAY_TOKEN` selects `convex` with that endpoint. `apns-direct` reads `APNS_KEY_PATH` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_BUNDLE_ID` | Push notifications | `none` |
| `BUDDYOS_CLAUDE_USAGE` (`off`, `on`) | Show Claude plan usage. Reads your local Claude Code login; **off by default** — enable only if you accept that | `off` |
| `BUDDYOS_ID_PREFIX` (macOS) | Prefix for the LaunchAgent label and keychain service names | `dev.buddyos.oss` |
| `BUDDYOS_BRIDGE_PORT` | Local port (the next free port is used if taken) | `8765` |

### Self-hosting the relay

Run [getpaseo/paseo-relay](https://github.com/getpaseo/paseo-relay) (Apache-2.0) at a pinned version, for example with Docker, and point `BUDDYOS_PASEO_RELAY_URL` at it. No account is needed for QR pairing. Note that the official phone apps only accept the official relay; to use your own relay end to end you currently need to build the client yourself.

## Scope and support

This project is maintained by a very small team.

- **Welcome:** adapters for new agent CLIs, Linux and Windows support, protocol fixes (with updated vectors), security hardening, bug fixes.
- **Not accepted here:** features of the hosted service, or anything that puts official endpoints, keys or IDs into the source.

Read [CONTRIBUTING.md](CONTRIBUTING.md) first (contributions use the DCO, `git commit -s`). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md) — never in a public issue.

## License

- Code: [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- `spec/`: CC-BY-4.0.
- The BuddyOS name, logos and icons are not covered by the license — see [TRADEMARKS.md](TRADEMARKS.md). Forks must use a different name and logo.
- "Claude Code", "Codex" and the other agent names are trademarks of their owners. BuddyOS works with these tools; it is not affiliated with or endorsed by their makers.

---

## 日本語

BuddyOS は、PC の上のコーディングエージェント（Claude Code、Codex、OpenCode、Hermes、Antigravity など）を、端から端まで暗号化された中継を通してスマホから操作する仕組みです。

このリポジトリは、**利用者の PC で動く部分**だけを公開しています。何が動いているかを誰でも確かめられるようにするためです。

- `mac-bridge/`（macOS 用の Bridge）、`windows-bridge/`（Windows / Linux 用の Bridge）、`shared/`（プロトコルとテストベクタ、参照実装）、`scripts/`（エージェントに hook を入れるスクリプト）、`spec/PROTOCOL-v3.md`（プロトコル仕様）。
- Bridge は `127.0.0.1` だけで待ち受け、中継へは外向きにつなぎます。中継から見えるのは暗号文だけです。ペアリングは 10 分・1 回限りの招待（QR かリンク）で行います。
- 公開版には公式の接続先や ID を入れていません。設定が空の機能は動きません（上の「Configuration」の表）。中継は `getpaseo/paseo-relay` を自分で立てられます。
- スマホのアプリ、デスクトップの管理アプリ、ホストしているサービスはまだ含みません。
- ライセンスはコードが Apache-2.0、`spec/` が CC-BY-4.0。名前・ロゴはライセンスの対象外です（[TRADEMARKS.md](TRADEMARKS.md)）。貢献は DCO（`git commit -s`）で受けます（[CONTRIBUTING.md](CONTRIBUTING.md)）。脆弱性は公開の Issue ではなく [SECURITY.md](SECURITY.md) の方法で知らせてください。
