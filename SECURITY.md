# Security Policy

The bridges in this repository run shell commands and coding agents on your computer on behalf of a paired phone. We take reports about them seriously.

## Reporting a vulnerability

**Do not open a public issue, discussion or pull request for a security problem.**

Report it privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (GitHub Private Vulnerability Reporting). Only the maintainers can see the report.

Please include:

- the affected component (`mac-bridge`, `windows-bridge`, `shared/` protocol, a hook script) and version or commit (`SOURCE_REVISION`, `--version`),
- what an attacker needs (network position, a paired device, a malicious QR code or link, local access, ...),
- steps to reproduce or a proof of concept,
- the impact you observed.

What to expect:

| Step | Target |
|---|---|
| Acknowledgement | within 5 business days |
| First assessment (accepted / needs info / not a vulnerability) | within 14 days |
| Fix or mitigation for accepted High/Critical issues | as soon as practical, normally within 90 days |
| Public advisory | after a fixed release is available, credited to you unless you prefer otherwise |

This is a small project maintained by a few people; these are goals, not guarantees. We do not run a paid bug bounty.

## Supported versions

| Version | Supported |
|---|---|
| Latest release of each bridge (`mac-bridge`, `windows-bridge`) | Yes |
| Previous minor release | Critical fixes only, for 90 days after the next release |
| Older releases | No |
| Wire protocol v3 (`spec/PROTOCOL-v3.md`) | Yes |
| Wire protocol v1 / v2 (shared API key) | No — removed; do not re-enable |

## Scope

In scope: the code in this repository, the wire protocol and its reference implementation, the hook/installer scripts, and the default configuration they produce.

Out of scope (report to the respective owner): the agent CLIs launched by the bridges, the relay software you choose to run, Apple/Google push services, and hosted BuddyOS services, which are not part of this repository (you may still report hosted-service issues through the same channel; we will route them).

## Safe harbor

Good-faith research that respects users' privacy, avoids data destruction and service degradation, and gives us reasonable time to fix before disclosure will not be pursued by us. Only test against bridges, relays and accounts you own.

---

## 日本語（要約）

脆弱性は**公開の Issue に書かず**、このリポジトリの **Security → Report a vulnerability**（GitHub の非公開の脆弱性報告）から送ってください。5 営業日以内に受け取りを返し、14 日以内に一次判断をします。サポートするのは各 Bridge の最新版（と、次の版が出てから 90 日間は一つ前の版の重大な修正）と、プロトコル v3 だけです。v1 / v2（共有 API キー方式）は廃止済みで対象外です。
