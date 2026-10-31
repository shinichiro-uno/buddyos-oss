# Contributing

Thanks for your interest in BuddyOS. This repository contains the parts that run on **your** computer — the macOS bridge, the Windows/Linux bridge, the shared wire protocol with its test vectors, and the scripts that install hooks into agent CLIs. Because this code runs shells and edits agent configuration, we review every change carefully.

## What we accept

| Welcome | Not accepted here |
|---|---|
| Adapters for new agent CLIs | Features of the hosted BuddyOS service (billing, accounts, integrations) |
| Linux and Windows support | Changes that add official hosted endpoints, IDs or keys to the source |
| Protocol fixes, with updated test vectors | Bundling proprietary SDKs or binaries into the repository |
| Security hardening, bug fixes, tests, docs | Large refactors without an issue discussed first |

The project is maintained by a very small team. Please open an issue before starting anything larger than a bug fix so we can agree on the approach.

## Developer Certificate of Origin (DCO)

We accept contributions under the **Developer Certificate of Origin 1.1** — no CLA. Contributions are accepted under the same license the project is published under (Apache-2.0; documents in `spec/` under CC-BY-4.0).

Every commit must carry a `Signed-off-by` line with your real name and an e-mail you can be reached at:

```
git commit -s -m "fix(windows-bridge): ..."
```

which adds:

```
Signed-off-by: Your Name <you@example.org>
```

By signing off you certify the following:

```text
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

A DCO check runs on every pull request. If you forgot, `git commit --amend -s` (one commit) or `git rebase --signoff main` (several) fixes it.

## How pull requests are merged (for now)

This public repository is currently **exported from a private source repository**. Your pull request is reviewed here as usual, but it is not merged with the GitHub button: once approved, a maintainer imports it into the source repository with your authorship and sign-off preserved, and the next export carries it back here with `Co-authored-by:`. The pull request is then closed with a link to the release/tag that contains it. It will look "closed, not merged" — that is expected, and your commit and credit are kept. We plan to make this repository the source of truth once contributions become regular.

## Building and testing

Requirements: macOS 15.6+ with Swift 6 (Xcode 16 or later) for `mac-bridge`; Node.js 20+ (22 recommended) for `windows-bridge` and the protocol tools.

```bash
# macOS bridge
cd mac-bridge && swift build && swift test

# Windows / Linux bridge
cd windows-bridge && npm ci && npm run typecheck && npm test

# Wire-protocol reference implementation against the test vectors
node --experimental-strip-types shared/tools/check-tunnel-v3.mts
```

Tests that drive real agent CLIs are skipped unless you opt in (`BUDDYOS_LIVE_*=1`, `RUN_*_E2E=1`); never make them run by default.

If you change the wire protocol, update `shared/protocol.json`, the vectors in `shared/*.json`, the reference implementation in `shared/tools/`, **both** bridges, and `spec/PROTOCOL-v3.md` in the same pull request.

## Rules that keep the project safe and redistributable

- **No secrets or official identifiers in source.** No API keys, tokens, signing identities, Team IDs, hosted deployment names or personal paths. Configuration comes from environment variables or `~/.buddyos/*.json`; without a value, the feature stays off.
- **No proprietary code in the tree.** `@anthropic-ai/claude-agent-sdk` is a dependency declared in `package.json` only; it is never vendored or copied into release artifacts by this repository.
- **No GPL-licensed runtimes bundled.** In particular, optional text-to-speech engines with GPL-3.0 dependencies (e.g. Kokoro via phonemizer/espeak-ng) must be downloaded by the user, never shipped inside an installer or the repository.
- **Third-party logos are not added.** Agents are shown by name only.
- **CI never receives secrets for pull requests**, and workflows must not use `pull_request_target`.
- Code comments may be in Japanese or English. Public documents (README, CONTRIBUTING, SECURITY, spec) are written in English with a Japanese summary.

## Reporting security problems

Never in a public issue — see [SECURITY.md](SECURITY.md).

---

## 日本語（要約）

- 受け付けるもの：新しいエージェントのアダプタ、Linux / Windows 対応、プロトコルの修正（テストベクタも更新）、セキュリティ強化と不具合の修正。受け付けないもの：ホスト版の機能、公式の値をソースに入れる変更、独自ライセンスの SDK やバイナリの同梱。
- 貢献は **DCO** で受けます（CLA はありません）。すべてのコミットに `git commit -s` で `Signed-off-by:` を付けてください。
- 当面、この公開リポジトリは非公開の正本から書き出しています。承認した PR は作者と署名を残したまま正本に取り込み、次の書き出しに `Co-authored-by:` 付きで載せて、PR は取り込んだタグを書いて閉じます（「merge されずに閉じた」表示になりますが、作者の記録は残ります）。
- 秘密情報・公式の識別子・個人のパスを入れない、Agent SDK を同梱しない、GPL の実行環境（Kokoro の Python 環境など）をインストーラーに入れない、他社のロゴを足さない、PR の CI にシークレットを渡さない。
- 脆弱性は公開の Issue に書かず、[SECURITY.md](SECURITY.md) の方法で知らせてください。
