# BuddyOS Device Authentication and Tunnel Protocol, Version 3

- **Status:** Draft. Wire-compatible with the reference Bridges in `mac-bridge/` and `windows-bridge/` and the reference implementation in `shared/tools/tunnelV3Ref.mts`.
- **License:** This document is licensed under [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/). Code in this repository is licensed separately (see `LICENSE`).
- **Normative test vectors:** `shared/e2e-test-vectors.json` (`keys`, `tunnelV3`, `pairingV3`, `push`). Where this text and the vectors disagree, the vectors win and this text is a bug.

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in BCP 14 ([RFC 2119], [RFC 8174]) when, and only when, they appear in all capitals.

---

## Table of contents

1. Overview
2. Roles
3. Threat model (summary)
4. Identifiers and key material
5. Common encoding rules
6. Pairing invite (QR code and `buddyos://pair` link)
7. Relay transport
8. Tunnel handshake (Noise_IKpsk2_25519_ChaChaPoly_SHA256)
9. Transport frames
10. Session modes: `connect`, `pair`, `approve`
11. Device-side pinning rules
12. Timers and limits
13. Authentication inside the tunnel
14. Push notifications
15. Registry HTTP API (`/v3/*`)
16. Error code reference
17. Versioning
18. Test vectors
19. Security considerations
20. Remaining work

Appendix A. Bridge local administration API (informative)

---

## 1. Overview

BuddyOS lets a phone (or another computer) drive command-line coding agents that run on a user's computer. A long-running process on that computer, the **Bridge**, listens only on `127.0.0.1` and exposes an HTTP / WebSocket API. Remote **devices** reach the Bridge through a public, untrusted WebSocket **relay**. All traffic between a device and a Bridge is end-to-end encrypted and mutually authenticated with the Noise Protocol Framework; the relay sees only ephemeral public keys and ciphertext.

Version 3 ("v3") has the following properties:

1. **No long-lived shared secret ever leaves the computer.** Pairing codes, links, the registry, and devices never carry a reusable Bridge-wide secret.
2. **Per-device identity.** Every device has its own static X25519 key and receives its own bearer credential (`bdc_…`) at pairing time. Devices can be revoked one at a time.
3. **Mutual authentication with forward secrecy.** The tunnel uses `Noise_IKpsk2_25519_ChaChaPoly_SHA256`. A Bridge refuses any device key it has not paired (no trust-on-first-use).
4. **Short-lived, single-use invites.** A pairing QR code / link carries a 32-byte invite secret that expires after 10 minutes and is mixed into the handshake as the Noise PSK.
5. **Discovery without secrets.** An optional account **registry** lets signed-in devices find the user's computers. Registry entries contain no secrets; joining a computer found in the registry requires a 6-digit short authentication string (SAS) to be entered on the target computer (or on a phone already paired to it).
6. **Registry data never silently replaces pinned keys.** Devices pin the Bridge static public key obtained during pairing.
7. **Encrypted push.** Notification content is end-to-end encrypted per device; the push relay only ever sees a fixed placeholder text.

Earlier tunnel versions (no `v` field, and `v: 2`) are not supported by a v3 Bridge and MUST be refused (§8.9).

### 1.1 Notation

- `||` is byte concatenation.
- `SHA256(x)` is SHA-256. `HMAC(k, m)` is HMAC-SHA256.
- `HKDF(ikm, salt, info, L)` is HKDF-SHA256 per [RFC 5869]. "Empty salt" is the zero-length byte string (equivalent, per RFC 5869, to 32 zero bytes).
- `X25519(priv, pub)` is the function from [RFC 7748].
- `AEAD` is ChaCha20-Poly1305 per [RFC 8439]: 32-byte key, 12-byte nonce, 16-byte tag; output is `ciphertext || tag`.
- `b64u(x)` is base64url without padding (§5.1). `hex(x)` is lowercase hexadecimal.
- String literals such as `"buddyos/v3/sas"` denote their ASCII bytes.
- `x[a..b]` is the byte slice from offset `a` (inclusive) to `b` (exclusive).
- "ms" timestamps are integer UNIX epoch milliseconds.

---

## 2. Roles

| Role | Description |
|---|---|
| **Bridge** | Runs on the user's computer (macOS, Windows, Linux). Owns the static key `S_b`, the relay identifier `relayId`, the device list, and the HTTP / WebSocket API on `127.0.0.1:<port>`. Acts as the Noise **responder** and as the relay **server**. |
| **Device** | A phone app, or a desktop app connecting to *another* computer. Owns the static key `S_d`. Acts as the Noise **initiator** and as the relay **client**. A device typically runs a local TCP proxy on its own loopback interface; each proxied TCP connection is carried over one tunnel. |
| **Relay** | An untrusted WebSocket forwarder that pairs a Bridge's server socket with a device's client socket by `serverId` and `connectionId` (§7). The reference relay protocol is the Paseo relay protocol, version 2. The relay is not trusted for confidentiality, integrity, or authentication. |
| **Registry** (optional) | An HTTP service that lists a user's Bridges (`/v3/my-bridges`), stores push targets, and forwards encrypted push notifications (§15). Authenticated by the user's identity-provider session (for devices) or by a per-Bridge registry token `bdt_…` (for Bridges). It holds no secrets that grant access to a Bridge. |
| **Local admin client** (informative) | The desktop application on the same computer that supervises the Bridge and manages devices through `/local/*` (Appendix A). |

A Bridge MUST be usable without a registry: pairing by QR code / link (§10.2) requires only a Bridge, a device, and a relay.

---

## 3. Threat model (summary)

### 3.1 Assets

- Command execution on the computer (agents and terminals). Access to a Bridge is equivalent to a shell as the user.
- Conversation contents, attachments, previews, and notification text.

### 3.2 Adversaries and what v3 provides

| Adversary | Outcome under v3 |
|---|---|
| Relay operator, or anyone who controls the relay | Sees only ephemeral public keys, sizes, timing, `serverId`, `connectionId`, and IP addresses. Cannot read or forge traffic. Forward secrecy against later static-key compromise. Corrupting pairing frames does not consume an invite (§10.2). |
| Anyone with write access to the registry | Obtains no secret. Devices that are already paired never change pinned keys from registry data (§11). An unpaired device asking to join a forged entry gets nothing stored unless the user enters a code on the *real* computer (§10.3). |
| Attacker holding a stolen identity-provider session | Obtains no secret. Can request to join a computer, but cannot get in unless someone at that computer (or a paired phone) enters the attacker's code. Cannot take over the registry token of a running Bridge (§15.4). Can remove a computer from the account (denial of service). |
| Someone who saw a QR code / link | Can pair at most once, within 10 minutes. Use is visible on the computer (notification and invite history). |
| Lost or stolen device | Can be revoked individually on the computer. A revoked key cannot rejoin through the approval flow (§10.3). |
| Other apps on the same device connecting to the device's local proxy | Have no `bdc_` credential; the Bridge rejects them (§13). |
| A compromised agent running on the computer that can read the Bridge's state directory | The local key is not accepted over the tunnel. Device management additionally requires an admin key that is never written to disk or the environment (Appendix A). |

### 3.3 Out of scope (residual risks)

- A fully compromised device (malware, jailbreak) leaks its key and credential until revoked.
- Processes running as the same OS user on the computer can use the Bridge's local key, and can tamper with Bridge binaries; v3 does not defend against same-user code execution beyond the admin-key barrier.
- Theft of a Bridge's registry token `bdt_` allows rewriting that Bridge's registry entry. The `key_changed` check (§15.5) prevents accidents, not attacks; defense is the device-side pinning rule (§11) and the SAS step (§10.3).
- A forged Bridge reached through a forged registry entry can return `paired` to an unpaired device. The device does not store the result until the user confirms they entered the code on their computer (§10.3 step 8).
- Device names are self-asserted (§5.3).
- Relay metadata (IP, timing, volume, identifiers) is visible.
- Denial of service: anyone who knows a `relayId` can flood handshakes or contend for the relay `serverId`. Mitigated only by rate limits and pre-authentication slot limits (§12). "Disconnect all devices" regenerates the `relayId`.
- Approval spam: anyone who knows `relayId` and `S_b.pub` can submit join requests while approvals are open. Requests cannot succeed without the correct code.
- Devices that are not signed in to the registry cannot learn that a computer was removed from the account.
- Custom URL scheme interception (§19.3).

---

## 4. Identifiers and key material

| Name | Definition | Created by | Lifetime |
|---|---|---|---|
| **Bridge static key** `S_b` | X25519 key pair. `S_b.pub` appears in the invite (`key`), in the registry (`bridgePub`), and in `/health`. | Bridge | Regenerated on "disconnect all devices", when the state directory is detected on a different machine, and when the key file is missing or corrupt. MUST NOT be regenerated on transient I/O or permission errors. |
| **`relayId`** | Relay `serverId`: `b64u` of 32 random bytes (43 characters). Not secret, but unguessable. | Bridge | Regenerated together with `S_b`. |
| **`bridgeId`** | Bridge identifier, `^[A-Za-z0-9._-]{8,100}$`. An attribute of a pairing, **not** the pinning key. | Bridge | Long-lived; regenerated when the Bridge is removed from an account. |
| **Local key** | Bearer secret for clients running on the same computer. | Bridge | Regenerated with `S_b`. MUST NOT appear in invites, the registry, or any UI, and MUST NOT be accepted over the tunnel (§13). |
| **Device static key** `S_d` | X25519 key pair. One per app installation, shared across all Bridges. | Device | Until the app's secure storage is cleared. |
| **`clientDeviceId`** | Installation identifier claimed by the device, `^[A-Za-z0-9._-]{8,80}$`. Used for push-key derivation and as a consistency check. **Not an authenticator.** | Device | Same as `S_d`. |
| **`deviceKeyId`** | `b64u(SHA256(S_d.pub)[0..16])` (22 characters). The Bridge's primary key for a device. | Both sides compute it | Changes when `S_d` changes. |
| **Device credential** `bdc_…` | `"bdc_" || b64u(32 random bytes)` (47 characters). Bearer credential for HTTP / WebSocket requests inside the tunnel. | Bridge, at pairing | No expiry. Invalidated by revocation, re-pairing, or Bridge reset. The Bridge stores only `credHash = hex(SHA256(UTF-8(credential)))`. |
| **Invite secret** `secret` | 32 random bytes. Carried only in the invite. | Bridge (memory only) | 10 minutes. Once used by a `deviceKeyId`, usable again only by that same `deviceKeyId` (retry). |
| **`inviteId`** | `b64u(HKDF(ikm=secret, salt=empty, info="buddyos/v3/invite-id", L=16))` (22 characters). | Both | — |
| **Invite PSK** `psk` | `HKDF(ikm=secret, salt=empty, info="buddyos/v3/invite-psk", L=32)`. | Both | — |
| **Registry token** `bdt_…` | Opaque Bridge credential for the registry, issued by `/v3/device-token`. | Registry | 180 days, auto-rotated (§15.5). |
| **Push key** `k_push` | `HKDF(ikm=X25519(S_b, S_d.pub), salt="buddyos/push/v1", info=UTF-8(bridgeId || "|" || clientDeviceId), L=32)`. | Both | Changes when either static key changes. |
| **Push key identifier** `kid` | `hex(SHA256(S_b.pub)[0..8])` (16 hex characters). | Both | — |

Random values MUST come from the operating system's CSPRNG, and implementations MUST check for failure of the random source.

---

## 5. Common encoding rules

### 5.1 base64url (`b64u`)

`b64u` is base64url ([RFC 4648] §5) **without padding**. Receivers MUST reject input unless all of the following hold:

1. Every character is in `[A-Za-z0-9_-]` (no `=`, `+`, `/`, or whitespace).
2. `length mod 4 != 1`.
3. Re-encoding the decoded bytes yields exactly the input string (rejects non-zero trailing bits).
4. For fixed-length values (keys and nonces: 32 bytes; invite secret: 32 bytes; `inviteId`: 16 bytes), the decoded length is exactly that length.

Note: some platform decoders (e.g. Node.js `Buffer.from(s, "base64url")`) silently skip invalid characters and MUST NOT be used without these checks. See `b64uDecodeStrict` in `shared/tools/tunnelV3Ref.mts`.

The push envelope fields `n` and `c` (§14) use **standard base64 with padding**, for compatibility with the v1 push format. Everything else introduced by v3 uses `b64u`.

### 5.2 JSON and time

- JSON is UTF-8. Receivers MUST ignore unknown object keys unless stated otherwise.
- Byte limits are on the UTF-8 encoding.
- All JSON timestamps are integer UNIX milliseconds, **except** the invite field `exp`, which is UNIX **seconds**.

### 5.3 Name sanitization

Bridge names, device names, and user labels MUST be sanitized as follows, operating on Unicode scalar values (not UTF-16 code units, not grapheme clusters):

1. Map every scalar in general category `Zs`, `Zl`, or `Zp`, and every scalar in U+0009..U+000D or U+0085, to U+0020 SPACE.
2. Remove every remaining scalar in general category `Cc`, `Cf`, or `Cs` (this includes U+200B..U+200F, U+202A..U+202E, U+2066..U+2069, U+00AD, U+FEFF, and U+200D).
3. Collapse runs of spaces to one space; trim leading and trailing spaces.
4. Truncate to the first 64 scalar values; trim trailing spaces again.
5. If the result is empty, use the fallback: for devices `"端末"` (U+7AEF U+672B), for Bridges `"PC"`. (These literal fallbacks are part of the test vectors.)

No Unicode normalization is applied.

**Display name.** Bridges and local admin clients display a device as `<name> · <first 4 characters of deviceKeyId>` (separator: U+0020 U+00B7 U+0020), e.g. `iPhone · 815W`. The name part is self-asserted; the suffix is derived from the key.

### 5.4 URL query encoding (invites)

- **Producers** MUST percent-encode every byte of the UTF-8 value outside `[A-Za-z0-9-._~]` as `%XX` with uppercase hex. In particular `+` MUST be encoded as `%2B` and space as `%20`. Keys MUST appear in the order given in §6.
- **Consumers** MUST decode only `%XX` sequences and MUST NOT turn `+` into a space. Consumers MUST reject a `%` not followed by two hex digits, and any value that is not valid UTF-8 after decoding. (Split on `&`, then on the first `=`.)

---

## 6. Pairing invite (QR code and `buddyos://pair` link)

```
buddyos://pair?v=3&bridgeId=<bridgeId>&name=<name>&platform=<mac|windows>&relay=<relay URL>&relayId=<relayId>&key=<b64u S_b.pub>&secret=<b64u secret>&exp=<UNIX seconds>
```

Example with placeholder relay (the normative example, with a different relay URL, is `pairingV3.qrUrl` in the vectors):

```
buddyos://pair?v=3&bridgeId=bridge-test-1&name=Test%20Mac%20%2B%202&platform=mac&relay=wss%3A%2F%2Frelay.example.com%2Fws&relayId=4OHi4-Tl5ufo6err7O3u7_Dx8vP09fb3-Pn6-_z9_v8&key=hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo&secret=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8&exp=1789000600
```

| Key | Content | Consumer validation |
|---|---|---|
| `v` | `3` | MUST be exactly `3`. Anything else is an unsupported (old) invite. |
| `bridgeId` | Bridge identifier | `^[A-Za-z0-9._-]{8,100}$` |
| `name` | Bridge name, for display before the handshake (self-asserted) | Sanitize per §5.3 with fallback `"PC"`. |
| `platform` | `mac` or `windows` | Unknown values are treated as `mac`. |
| `relay` | Relay WebSocket URL | MUST exactly match an entry of the consumer's **built-in relay allowlist** (§19.4). |
| `relayId` | Relay `serverId` | `^[A-Za-z0-9_-]{16,128}$` |
| `key` | `S_b.pub` | `b64u`, exactly 32 bytes. |
| `secret` | Invite secret | `b64u`, exactly 32 bytes. |
| `exp` | Expiry, UNIX seconds | Decimal integer. Consumers SHOULD reject if expired, allowing 2 minutes of clock skew. The Bridge makes the final decision. |

Additional rules:

- A key that appears twice makes the invite invalid. A missing key makes the invite invalid.
- An invite containing `apiKey` is a legacy (v2) invite and MUST be rejected as unsupported.
- Only the Bridge generates invite URLs. A local admin client that displays a QR code renders the URL returned by the Bridge verbatim.
- An invite is valid for 10 minutes and for one device key (§10.2). A Bridge keeps at most 3 outstanding invites; creating a fourth discards the oldest.
- Consumers MUST record the **source** of an invite: `camera` (scanned by the app's own camera UI) or `link` (deep link, clipboard, paste). The source affects replacement of existing pairings (§11).
- Before the handshake the name MUST be presented as "the name written in the QR code". After the handshake, the authenticated `name` from payload2 / `paired` replaces it.

---

## 7. Relay transport

The tunnel runs over a relay that forwards WebSocket messages between one server socket and one client socket. The reference relay protocol is the Paseo relay protocol, version 2. The relay protocol version (`v=2` in relay URLs) is unrelated to the tunnel version (v3) and MUST NOT be changed by implementations of this specification.

### 7.1 Relay URLs

Given a relay base URL `R` (for example `wss://relay.example.com/ws`), endpoints are formed by appending query parameters:

| Socket | Query parameters |
|---|---|
| Bridge control socket | `v=2&role=server&serverId=<relayId>` |
| Bridge data socket | `v=2&role=server&serverId=<relayId>&connectionId=<connectionId>` |
| Device data socket | `v=2&role=client&serverId=<relayId>&connectionId=<connectionId>` |

The device chooses a fresh random `connectionId` (the reference implementations use a random UUID) for every tunnel.

### 7.2 Control socket

The Bridge keeps one control socket open. The relay sends TEXT messages:

```json
{"type":"connected","connectionId":"<id>"}
{"type":"disconnected","connectionId":"<id>"}
{"type":"sync","connectionIds":["<id>", "..."]}
```

On `connected` (and for every id in `sync`), the Bridge opens a data socket for that `connectionId`. On `disconnected` it closes it. Reference Bridges ping the control socket every 15 s, reconnect if no pong arrives within 10 s, and reconnect with exponential backoff `min(30, 2^min(attempt, 5))` seconds, resetting the backoff after 60 s of healthy uptime. Reference Bridges accept control messages up to 1 MiB.

### 7.3 Data sockets

Each data socket pair carries exactly one tunnel session (§8–§10). WebSocket TEXT messages carry handshake JSON; WebSocket BINARY messages carry transport frames (§9). Message ordering is provided by the relay and the underlying TCP connections.

---

## 8. Tunnel handshake

The handshake is `Noise_IKpsk2_25519_ChaChaPoly_SHA256` as defined by the Noise Protocol Framework, revision 34. The device is the initiator; the Bridge is the responder. The device knows `S_b.pub` beforehand (from the invite, the registry, or a stored pairing).

```
IKpsk2:
  <- s
  ...
  -> e, es, s, ss
  <- e, ee, se, psk
```

### 8.1 Primitives

- `DH(priv, pub) = X25519(priv, pub)`. An all-zero 32-byte result MUST be treated as failure, even if the library does not raise an error.
- `HKDF2(ck, ikm) -> (o1, o2)` and `HKDF3(ck, ikm) -> (o1, o2, o3)`:
  ```
  t  = HMAC(ck, ikm)
  o1 = HMAC(t, 0x01)
  o2 = HMAC(t, o1 || 0x02)
  o3 = HMAC(t, o2 || 0x03)
  ```
  (Equal to RFC 5869 with salt = `ck`, empty info. Implement with HMAC directly, because some HKDF APIs reject an empty `ikm`.)
- Handshake AEAD nonce: `0x00000000 || uint64_le(n)` — **little-endian**, as in Noise. (Transport frames in §9 use a big-endian counter; do not mix them up.)
- Symmetric state: `ck` (32 bytes), `h` (32 bytes), `k` (32 bytes or empty), `n` (uint64).
  - `MixHash(d)`: `h = SHA256(h || d)`
  - `MixKey(ikm)`: `(ck, k) = HKDF2(ck, ikm)`; `n = 0`
  - `MixKeyAndHash(ikm)`: `(ck, t, k) = HKDF3(ck, ikm)`; `MixHash(t)`; `n = 0`
  - `EncryptAndHash(pt)`: `c = AEAD(k, nonce(n), ad=h, pt)`; `n += 1`; `MixHash(c)`; return `c`
  - `DecryptAndHash(c)`: `pt = AEAD_open(k, nonce(n), ad=h, c)` (failure aborts the handshake); `n += 1`; `MixHash(c)`
  - `Split()`: `(k_c2s, k_s2c) = HKDF2(ck, empty)`

### 8.2 Initialization (both sides)

```
h  = SHA256("Noise_IKpsk2_25519_ChaChaPoly_SHA256")   // name is 36 bytes > 32, so it is hashed
ck = h
MixHash("buddyos-tunnel-v3")                          // prologue, 17 ASCII bytes
MixHash(S_b.pub)                                      // pre-message <- s
```

### 8.3 Message 1 (device -> Bridge, TEXT)

Device:

```
E_d = fresh X25519 key pair (per tunnel)
MixHash(E_d.pub); MixKey(E_d.pub)          // PSK rule: e is also mixed into the key
MixKey(DH(E_d, S_b.pub))                   // es
s = EncryptAndHash(S_d.pub)                // 48 bytes
MixKey(DH(S_d, S_b.pub))                   // ss
p = EncryptAndHash(payload1)
```

```json
{"type":"buddyos_tunnel_init","v":3,"e":"<b64u 32 bytes>","s":"<b64u 48 bytes>","p":"<b64u >= 16 bytes>"}
```

Bridge: `MixHash(e); MixKey(e); MixKey(DH(S_b, e)); S_d.pub = DecryptAndHash(s); MixKey(DH(S_b, S_d.pub)); payload1 = DecryptAndHash(p)`.

The Bridge MUST validate `e` (32 bytes), `s` (48 bytes), and `p` (at least 16 bytes) with the strict `b64u` rules before processing. The TEXT message MUST NOT exceed 4096 bytes.

### 8.4 Message 2 (Bridge -> device, TEXT)

The Bridge chooses `psk` **after** reading payload1: the invite PSK for `mode = "pair"`, otherwise 32 zero bytes.

```
E_b = fresh X25519 key pair (per tunnel)
MixHash(E_b.pub); MixKey(E_b.pub)
MixKey(DH(E_b, E_d.pub))                   // ee
MixKey(DH(E_b, S_d.pub))                   // se
MixKeyAndHash(psk)                         // psk
p = EncryptAndHash(payload2)
```

```json
{"type":"buddyos_tunnel_hello","v":3,"e":"<b64u 32 bytes>","p":"<b64u >= 16 bytes>"}
```

Device: `MixHash(e); MixKey(e); MixKey(DH(E_d, e)); MixKey(DH(S_d, e)); MixKeyAndHash(psk); payload2 = DecryptAndHash(p)`. If decryption fails, the handshake fails (wrong Bridge, or wrong invite).

### 8.5 Split and handshake hash

```
(k_c2s, k_s2c) = Split()      // c2s = device -> Bridge
H = h                         // the value of h immediately after EncryptAndHash/DecryptAndHash(payload2)
```

`H` is used for the SAS (§10.3). Ephemeral private keys and `ck` MUST be discarded after `Split()`.

### 8.6 payload1 (device -> Bridge)

JSON object, at most 1024 bytes.

| Key | Type | Required | Content |
|---|---|---|---|
| `mode` | string | yes | `connect`, `pair`, or `approve` |
| `deviceId` | string | yes | `clientDeviceId`, `^[A-Za-z0-9._-]{8,80}$` |
| `name` | string | `pair`, `approve` | Device name (e.g. device model). Sanitized by the Bridge (§5.3, device fallback). Ignored for `connect`. |
| `platform` | string | yes | `ios`, `android`, `mac`, or `windows`. Anything else is `bad_request`. |
| `app` | string | no | App version, at most 32 characters, informational. |
| `invite` | string | `pair` | `inviteId` (`b64u`, 22 characters / 16 bytes) |

### 8.7 payload2 (Bridge -> device)

JSON object, at most 1024 bytes. payload2 is authenticated by `S_b`; the device MAY change pairing state based on it.

| Key | Type | When | Content |
|---|---|---|---|
| `ok` | bool | always | |
| `error` | string | `ok = false` | §8.8 |
| `bridgeId` | string | `ok = true` | Handled per §11 (never used as the pinning key). |
| `name` | string | `ok = true` | Sanitized Bridge name. The device updates its stored name. |
| `platform` | string | `ok = true` | `mac` or `windows` |
| `deviceKeyId` | string | `ok = true` | The device MUST verify it equals its own computed value and abort otherwise. |
| `commit` | string | `approve`, `ok = true` | `b64u(SHA256("buddyos/v3/sas-commit" || N_b))` |

Reference Bridges emit keys in the order `ok, bridgeId, name, platform, deviceKeyId, commit`; receivers MUST NOT depend on key order.

### 8.8 payload2 errors (authenticated)

| `error` | When | Recommended device behavior |
|---|---|---|
| `unknown_device` | `connect`: key not in the device list; row still awaiting `paired_ack`; or `deviceId` differs from the stored `clientDeviceId` | Mark the pairing as needing repair; stop retrying. If the device has just paired and still holds a valid invite, it MAY retry `pair` once (§10.2 step 7). |
| `revoked` | `connect` / `approve`: key carries a revocation mark (90 days); `connect`: row is being unpaired | Mark as revoked by the Bridge; stop retrying. |
| `bad_request` | payload1 is malformed | Client bug. |
| `approval_unavailable` | `approve`: approvals disabled, or the approval window is closed and remote approval (§10.3.1) is not available | Suggest opening "add device" on the computer, enabling remote approval, or using an invite. |
| `busy` | `pair` / `approve`: a request for the same key is in progress; `approve`: 3 approvals already pending; pairing slots full | Retry later. |
| `rate_limited` | Rate limit reached; key was rejected within the last 24 h | Retry later. |
| `too_many_devices` | `pair` / `approve`: 20 devices already paired and this key is not among them | Ask the user to remove a device. |
| `bridge_error` | Bridge state is corrupt (e.g. device list unreadable) | Show a generic error. |

### 8.9 Plaintext errors (unauthenticated)

Only when the Bridge cannot send message 2 (unsupported version, unknown invite, malformed message 1), it sends one TEXT message and closes:

```json
{"type":"buddyos_tunnel_error","v":3,"code":"version|invite_invalid|bad_message|rate_limited"}
```

This message is **not authenticated** — the relay can forge it. Devices MUST use it only to choose a user-facing message, and MUST NOT delete pairings or change keys because of it.

A message 1 with no `v`, or `v` other than `3` (e.g. `2`), MUST be answered with `code: "version"` and closed. A v3 Bridge MUST NOT perform v2 or unversioned handshakes.

### 8.10 Handshake processing rules

- The device resends the identical message 1 every 350 ms until message 2 arrives, for up to 10 s.
- On a data socket the Bridge uses only the first valid message 1. Before message 1, TEXT messages whose `type` is not `buddyos_tunnel_init` are ignored; a BINARY message before message 1 closes the socket.
- After sending message 2, the Bridge ignores TEXT messages (e.g. message 1 resends) until the first BINARY frame. A TEXT message after the first BINARY frame closes the socket.
- The device ignores TEXT messages other than `buddyos_tunnel_hello` and `buddyos_tunnel_error` until message 2. A TEXT message after message 2 closes the socket.
- Malformed payload1: the Bridge answers with payload2 `{"ok":false,"error":"bad_request"}`. For `mode = "pair"` with an invite that is usable by this key, the Bridge SHOULD encrypt that message 2 with the invite PSK so the device can read it; if there is no usable invite it MUST send `invite_invalid` (§8.9).

---

## 9. Transport frames

After message 2, both directions carry only BINARY frames:

```
offset 0      : uint8   version = 0x03
offset 1      : uint8   flags   = 0x00
offset 2..9   : uint64  seq, big-endian (per direction, starts at 1, increments by 1)
offset 10..   : ChaCha20-Poly1305 ciphertext || tag (16 bytes)

key   = k_c2s (device -> Bridge) or k_s2c (Bridge -> device)
nonce = 0x00000000 || seq (8 bytes, big-endian)
AAD   = the 10 header bytes
```

Before decrypting, the receiver MUST check all of the following and close the connection **without decrypting** if any fails:

1. `26 <= length <= 16 MiB + 26`.
2. `version == 0x03`.
3. `flags == 0x00` (non-zero values are reserved).
4. `seq == previous seq + 1` (the first frame has `seq = 1`; `0` is invalid). A sender MUST close before `seq` would exceed `2^64 - 1`.

If decryption fails, the receiver MUST close.

This is the same layout as the v1 inner-WebSocket frame (§13.6) with the version byte set to `0x03`.

---

## 10. Session modes

### 10.1 Common Bridge rules

- **Nothing is trusted or changed until the first BINARY frame from the device decrypts correctly.** Message 1 can be replayed by anyone; only message 2 adds `ee` and `se`. Before that point the Bridge MUST NOT mark invites as used, create pending approvals, count rate-limit attempts, update last-seen times, or register the connection as a tunnel peer. The Bridge MAY use the `deviceKeyId` from message 1 to choose a refusal reason.
- Every data connection starts in the pre-authentication slot pool (§12). After the first frame decrypts, `connect` moves to the authenticated pool and `pair` / `approve` move to the pairing pool.
- The Bridge maintains an `epoch` counter that increments on "disconnect all devices" and similar resets. The Bridge records `epoch` when it reads message 1 and, when processing `pair_confirm`, an SAS match, `paired_ack`, or `open`, MUST verify under the device-list lock that `epoch` is unchanged; otherwise it closes without writing anything.
- At most one `pair` / `approve` session per `deviceKeyId` at a time; a second gets `busy`.
- On `pair` / `approve` sessions, any control message other than the next expected one (unknown `type`, wrong direction, a second `approve_nonce`, non-JSON, more than 4096 bytes) closes the session. On `connect` sessions, the first frame MUST be `open`.
- `pair` / `approve` sessions never carry TCP data. After completion they close; the device reconnects with `connect`.

### 10.1.1 Control messages inside the tunnel

JSON objects, at most 4096 bytes, each sent as one transport frame.

| `type` | Direction | Mode | Fields |
|---|---|---|---|
| `open` | c2s | `connect` (first frame) | — |
| `pair_confirm` | c2s | `pair` (first frame) | — |
| `approve_nonce` | c2s | `approve` (first frame, once) | `n`: `b64u` 32 bytes (`N_d`) |
| `approve_reveal` | s2c | `approve` | `n`: `b64u` 32 bytes (`N_b`) |
| `approval_waiting` | s2c | `approve` | — (keep-alive; the device ignores it) |
| `paired` | s2c | `pair`, `approve` | `deviceKeyId`, `credential` (`bdc_…`), `bridge`: `{bridgeId, name, platform, relayId, relayURL}` |
| `paired_ack` | c2s | `pair`, `approve` (after `paired`, once) | — |
| `pair_cancel` | c2s | `approve` (after `approve_reveal`) | — |
| `pair_rejected` | s2c | `pair`, `approve` | `reason`: `rejected`, `timeout`, `code_mismatch`, `closed`, `busy`, `rate_limited`, `too_many_devices`, `bridge_error`, `reset` |

### 10.2 `connect`

1. Bridge: derive `deviceKeyId` from `S_d.pub` and look it up. If absent: `revoked` if a revocation mark exists, otherwise `unknown_device`. If the row is awaiting `paired_ack`: `unknown_device`. If the row is being unpaired: `revoked`. If `payload1.deviceId` differs from the stored `clientDeviceId`: `unknown_device`. If the device list is corrupt: `bridge_error`.
2. Otherwise the Bridge sends message 2 with `ok = true` (zero PSK).
3. Device: sends `{"type":"open"}`.
4. Bridge: if the first frame decrypts to `open`, verify `epoch` and the row under the lock, open a TCP connection to `127.0.0.1:<Bridge listen port>`, check the conditions of §13.1, register `local port -> {deviceKeyId, connectionId}` as a tunnel peer, re-check under the lock that the row still exists (otherwise unregister and close), and then start relaying bytes. On close, the tunnel peer MUST be unregistered **before** the local TCP connection is closed. Update the device's last-seen time (in memory immediately; on disk at most every 5 minutes).

After `open`, the payload of each frame is opaque TCP byte stream data in the respective direction.

### 10.3 `pair` (invite)

1. Bridge: look up `payload1.invite`. If it does not exist, has expired, or was used by a **different** `deviceKeyId`, send plaintext `invite_invalid` (§8.9) and close (the PSK is unknown, so message 2 cannot be sent).
2. Bridge: if the device list is corrupt, send `bridge_error`; if 20 devices are paired and this key is not among them, `too_many_devices`; if another pairing for the same key is in progress or the pairing pool is full, `busy` — each as message 2 (`ok = false`) **encrypted with the invite PSK**, then close. The invite is left unchanged. Otherwise send message 2 (`ok = true`) with the invite PSK.
3. Device: if message 2 decrypts (the PSK matched), send `{"type":"pair_confirm"}`. If not, report an invite error.
4. Bridge: if the first BINARY frame arrives within 10 s and decrypts to `pair_confirm`, verify under the lock `epoch` and the invite (unexpired, and unused or used by this key), record the invite as used by this `deviceKeyId` with a timestamp, insert the device row in state `pendingAck` (replacing any row for the same key; `via: "qr"`; clearing any revocation mark), issue a new `bdc_` credential, and send `paired`. If sending fails, delete the row and close.
   - A first frame that does not decrypt, or is not `pair_confirm`: close. **The invite is not consumed and no failure is counted.** (Without the PSK no one can read message 2, so guessing is impossible, and relay-injected garbage cannot burn the invite.)
   - No frame within 10 s: close.
5. Device: on `paired`, validate it (`deviceKeyId` equals its own; `bridge.relayURL` is in the allowlist; all fields well-formed), store it provisionally according to §11, and send `{"type":"paired_ack"}`. Wait up to 5 s for the Bridge to close, then commit the pairing regardless of how the socket closed. Use `connect` from then on.
6. Bridge: if `paired_ack` arrives within 5 s, clear the row state, persist it, and close with WebSocket status 1000. Otherwise delete the row and close. Until it expires, the invite remains usable by the same `deviceKeyId` for a retry.
7. Device: if the first `connect` after committing fails with `unknown_device` and the invite is still held in memory and unexpired, retry `pair` once (recovery when `paired_ack` was lost).

### 10.4 `approve` (join a computer found in the registry)

`approve` lets a device join a Bridge it knows only from the registry. The registry is untrusted, so the user proves that the device is talking to the real Bridge by entering a 6-digit code — displayed **only on the requesting device** — on the target computer, or on a phone already paired with it (§10.4.1).

1. Bridge, after reading message 1, checks admission **without changing state**, and refuses with message 2 (`ok = false`, zero PSK) in this order:
   - approvals disabled, or the "add device" window is closed and remote approval is unavailable -> `approval_unavailable`
   - the key carries a revocation mark -> `revoked`
   - the key was rejected within 24 h, or a rate limit is reached -> `rate_limited`
   - a request for this key is in progress, or 3 approvals are pending -> `busy`
   - 20 devices are paired and this key is not among them -> `too_many_devices`
   - the device list is corrupt -> `bridge_error`
2. Bridge: generate `N_b` (32 random bytes) and send message 2 (`ok = true`, zero PSK) including `commit`.
3. Device: generate `N_d` (32 random bytes) and send `{"type":"approve_nonce","n":"<b64u N_d>"}` within 10 s.
4. Bridge: if the first frame decrypts to a valid `approve_nonce`, **count the attempt now** (per key and globally). If over the limit, send `pair_rejected` (`rate_limited`) and close. Re-check pending capacity under the lock (else `pair_rejected` with `busy`). Send `{"type":"approve_reveal","n":"<b64u N_b>"}` and create a pending approval holding the computed code **in memory only**. The code MUST NOT be displayed on, or exposed through any API of, the Bridge.
5. Device: verify `SHA256("buddyos/v3/sas-commit" || N_b) == commit` (abort if not), compute and display the code, and ask the user to enter it on the computer. The device offers "I entered it" and "Cancel" and keeps the screen awake.
6. Bridge: send `{"type":"approval_waiting"}` every 20 s (prevents idle disconnects by the relay).
7. When a code entered on the computer (or on an approver phone, §10.4.1) matches this pending approval: verify `epoch` under the lock and that the tunnel is still open (if not, discard the pending approval and report `device_gone`), insert the row in state `pendingAck` with `via: "approval"`, issue `bdc_`, and send `paired`. If sending fails, delete the row.
8. Device: **store only when it has received `paired` AND the user has pressed "I entered it".** If `paired` arrives first, ask the user to confirm that they entered the code. When both conditions hold, store and send `paired_ack`, then wait for close as in `pair` step 5. If the user cancels, send `{"type":"pair_cancel"}`, discard the credential, and close.
9. Bridge: on `paired_ack` within 60 s of `paired`, commit the row (as in `pair` step 6). On `pair_cancel` or after 60 s, delete the row and close.
10. Other terminations (Bridge sends `pair_rejected` and closes):
    - rejected on the computer -> `rejected`; the key is refused for 24 h (memory only)
    - 5 minutes elapsed -> `timeout`
    - 3 wrong codes entered in one window -> all pending approvals are withdrawn with `code_mismatch` and the window closes
    - the local admin client closed the window -> `closed` (local, non-remote approvals only)
    - `epoch` changed -> `reset`
    - the device disconnected first -> the pending approval is withdrawn

Revocation marks are cleared only by `pair` (QR / link), never by `approve`.

#### 10.4.1 Remote approval by a paired phone

A Bridge MAY accept `approve` requests while the local window is closed if **remote approval** is available: the setting `remoteApprovalsEnabled` is on (default on), and at least one *approver* device exists that has a push target. Approver devices are committed devices whose `platform` is `ios` or `android`; desktop devices MUST NOT be approvers (to prevent chained additions).

For a remote request, the Bridge sends one end-to-end encrypted push (§14) to each approver with a push target, with plaintext payload `{"kind":"pair_request","pendingId":"<id>"}` and a title/body describing the requesting device. The approver phone then uses the device API (§13.5): `GET /device/approvals`, `POST /device/approvals/approve {"code"}`, `POST /device/approvals/:pendingId/reject`. The code is still shown only on the requesting device. Additional limits for remote requests: at most 6 per hour globally (counted at `approve_nonce`). Wrong codes entered on the computer and on phones count toward the same limit of 3. Closing the local window does not withdraw remote requests. The committed row records `approvedBy` (the approver's `deviceKeyId`) when approved from a phone.

#### 10.4.2 SAS computation

```
N_d, N_b  = 32 random bytes each (device, Bridge)
commit    = SHA256("buddyos/v3/sas-commit" || N_b)          // sent in message 2
d         = SHA256("buddyos/v3/sas" || H || N_d || N_b)      // H from §8.5
code      = uint32_be(d[0..4]) mod 1_000_000, zero-padded to 6 digits
display   = "213 854"  (two groups of three digits; device only)
input     = Bridge strips spaces and "-" and accepts exactly 6 ASCII digits; compared in constant time
```

Order matters: the Bridge commits to `N_b` before seeing `N_d`, and reveals `N_b` only after receiving `N_d`. A man-in-the-middle runs two separate handshakes with different `H`, and on each side must fix its own nonce before seeing the peer's; it can therefore make the code shown on the device equal the code awaited by the real Bridge only with probability about 10^-6 per attempt. The modulo bias (`2^32 mod 10^6 = 967,296`) is about 1/4295 and is negligible. Combined with the attempt limits (§12), online guessing is not practical.

---

## 11. Device-side pinning rules

These rules apply to every device implementation.

- Stored pairings are keyed by the **Bridge static public key** (`bridgePub`). `bridgeId` is an attribute, not the key. The pinned key is the `S_b.pub` used in the handshake (`key` from the invite, or `bridgePub` from the registry for `approve`).
- When storing `paired`:
  1. If a pairing with the same `bridgePub` exists, update it (credential, `deviceKeyId`, and the `paired.bridge` values).
  2. Else, if a pairing with a **different** key has the same `bridgeId`, it MAY be replaced only when the new pairing came from an invite scanned with the app's own camera (after user confirmation) or from `approve`. For `source = link` the device MUST detect this case **before starting the handshake**, refuse, and not use the invite. When replacing, the old pairing and its push-decryption entry MUST be deleted first.
  3. Otherwise add a new pairing.
- If `bridgeId` in a `connect` payload2 differs from the stored value: if no other stored pairing (with a different key) has that `bridgeId`, update the stored `bridgeId` and push-decryption mapping (the Bridge regenerated its id). Otherwise close the connection without changing anything and log it.
- Store the authenticated `paired.bridge` values in preference to invite or registry values. `relayURL` MUST be checked against the relay allowlist; if it is not allowed, do not store.
- Push decryption entries are looked up by `kid` and used only if the entry's `bridgeId` equals the push `bid` (§14).
- Registry data MUST NOT change the pinned key, `relayId`, or `relayURL` of a paired Bridge. A device MAY flag a pairing as "key changed" only after two consecutive `connect` failures (no response, or message 2 does not decrypt) **and** a registry entry for the same `bridgeId` with different values. The only remedy is re-pairing (invite or `approve`).
- Devices MUST NOT update pinned keys from the `/health` response.

A successful handshake proves the peer holds the pinned key. That the key belongs to the user's own computer is established by the user scanning the code on their own screen (`pair`) or entering the code on their own computer (`approve`).

---

## 12. Timers and limits

Values used by the reference implementations. Implementations SHOULD use the same values; interoperability does not depend on exact values unless marked MUST.

| Item | Value |
|---|---|
| Device: message 1 resend interval / wait for message 2 | 350 ms / 10 s |
| Bridge: wait for message 1 after a data socket opens | 5 s |
| Bridge: wait for first BINARY frame after message 2 | 10 s |
| Bridge: pre-authentication pool | 16 connections; when full, the oldest pre-auth connection is closed to admit a new one |
| Bridge: pairing pool (`pair` + `approve`) | 4 concurrent (excess gets `busy`) |
| Bridge: authenticated pool (`connect`) | 128 total, 48 per device (excess is closed) |
| Bridge: wait for `paired_ack` after `paired` | `pair` 5 s / `approve` 60 s |
| Device: wait for close after `paired_ack` | 5 s |
| Pending approval lifetime | 5 min |
| Approval window | 10 min from open; reopening extends to 10 min from that moment |
| Pending approvals | 3 concurrent, 1 per device |
| Approval attempts (counted at `approve_nonce`) | 3 per hour per `deviceKeyId`, 20 per hour globally; remote requests additionally 6 per hour globally |
| Rejected device | `approve` refused with `rate_limited` for 24 h |
| Wrong code entries | 3 per window; then all pending approvals are withdrawn |
| Invites | 10 min; at most 3 outstanding; not consumed by failures |
| Devices per Bridge | 20 |
| Never-seen device rows | deleted 24 h after creation |
| Revocation marks | 90 days |
| Handshake failures | counted and logged only; MUST NOT disable acceptance (otherwise garbage traffic would lock out all devices) |
| Device local proxy | 32 concurrent connections per Bridge |
| TEXT handshake messages and control messages | 4096 bytes (MUST: larger messages are closed unread) |
| payload1 / payload2 | 1024 bytes |
| Transport frame | 16 MiB + 26 bytes (MUST) |

---

## 13. Authentication inside the tunnel

### 13.1 Tunnel peers

The Bridge listens on `127.0.0.1` (IPv4) only. Tunneled traffic enters through a TCP connection that the Bridge itself opens to `127.0.0.1:<listen port>` (never `localhost`). The Bridge maps that connection's **local port** to `{deviceKeyId, connectionId}` after `open` is verified and before the first byte is relayed, and removes the mapping before the TCP connection is closed. The Bridge MUST close without relaying if the local port cannot be determined, if the local address is not IPv4 `127.0.0.1`, or if the remote port is not the current listen port. If a local port is already mapped, the older tunnel is closed first.

When serving a request, the Bridge looks up the request's source (`127.0.0.1`, source port) in the peer table, and verifies that the request arrived on the listen port. Requests whose source is not `127.0.0.1` are refused.

### 13.2 Principals

```
principal(request):
  if source port is a registered tunnel peer for device D:
     credential starts with "bdc_", SHA256(credential) == D.credHash (constant time),
     and D is committed                                  -> device(D)
     otherwise (including the local key)                 -> none (401)
  else (direct local connection):
     credential == local key (constant time)             -> local
     otherwise (including any bdc_)                      -> none (401)
```

- Credentials are sent as `Authorization: Bearer <credential>`. Because browser WebSockets cannot set headers, the query parameter `?apiKey=<credential>` is also accepted on routes other than `/local/*` and `/preview/*` (the name is kept for compatibility; the value is a `bdc_` or the local key).
- If both header and query are present and differ, the request MUST be rejected with 401.
- `/local/*` accepts the header only (a query credential yields 401), additionally requires the admin key (Appendix A), and any request with an `Origin` header gets 403 `forbidden`.
- The local key MUST be read at request time (it can be regenerated).
- No route may be reachable without a credential. Misclassifying a request is then fail-safe: a tunnel request still needs `bdc_`, a local request still needs the local key.

### 13.3 Route classes

| Route class | `local` | `device` |
|---|---|---|
| `/health`, `/status` | allowed | allowed |
| `/ws/agent/:id`, `/terminal/pty` (WebSocket), `/files/*`, `/preview/*` | allowed | allowed |
| Diagnostics and local integrations (agent hooks, channels, traffic counters, push tests) | allowed | 403 `local_only` |
| `/local/*` | allowed with admin key | 403 `local_only` |
| `/device/*` | 403 `device_only` | allowed |
| Any route not explicitly classified | 404 `not_found` | 404 `not_found` |

Routes are default-deny: every route MUST be registered with a class.

Preview sessions created via `POST /preview/session` remember the creating principal (`local` or a `deviceKeyId`); session-authenticated preview routes are allowed only for the same principal. Revoking a device discards its preview sessions.

### 13.4 Error bodies

401 `{"error":"unauthorized"}`; 403 `{"error":"local_only"}`, `{"error":"device_only"}`, `{"error":"forbidden"}`, `{"error":"admin_unavailable"}`; 404 `{"error":"not_found"}`. Bridges SHOULD NOT reveal more detail.

### 13.5 Device API (`/device/*`, `device` principal only)

| Method and path | Response |
|---|---|
| `GET /device/self` | 200 `{"deviceKeyId","display","platform","createdAt"}` |
| `POST /device/unpair` | 200 `{"ok":true}`. The row is immediately marked as unpairing (new `connect` gets `revoked`, new requests get 401); about 1 s after responding, the row is deleted and its tunnels are closed. No revocation mark is left (a self-unpaired device may rejoin via `approve`). |
| `GET /device/approvals` | 200 `{"pending":[{"pendingId","display","platform","requestedAt","expiresAt","sameNameExists","remote"}],"enabled":bool}` (never contains codes). Non-approvers get 403 `not_approver`. If remote approval is disabled: `enabled: false` and an empty list. |
| `POST /device/approvals/approve` | Body `{"code":"213854"}` (spaces and `-` ignored). 200 `{"ok":true,"deviceKeyId","display"}`; 400 `{"error":"code_mismatch","remaining":n}`; 400 `bad_code`; 404 `no_pending`; 410 `device_gone`; 403 `not_approver`; 409 `disabled` |
| `POST /device/approvals/:pendingId/reject` | 200 `{"ok":true}`; 404 `not_found`; 403 `not_approver`; 409 `disabled`. Refuses that key for 24 h. |

### 13.6 Inner WebSocket encryption (legacy v1, optional)

The agent WebSocket MAY additionally use the v1 application-layer encryption (`?e2e=v1&deviceId=<clientDeviceId>`). It is redundant under the v3 tunnel; new clients need not use it.

- The Bridge first sends plaintext TEXT `{"type":"e2e_hello","metadata":{"v":"1","salt":"<b64u 32-byte connSalt>","kid":"<16 hex>"}}`.
- Keys: `SS = X25519(static, static)`; `k_c2s = HKDF(SS, connSalt, "buddyos/ws/v1/c2s", 32)`; `k_s2c = HKDF(SS, connSalt, "buddyos/ws/v1/s2c", 32)`.
- Frames: as §9 with `version = 0x01`. The client sends an encrypted `{"type":"e2e_confirm"}` first.
- For a `device(D)` WebSocket the Bridge MUST verify `deviceId == D.clientDeviceId` (otherwise send `e2e_error` and close with 1008) and MUST use `D`'s pinned key. For `local` WebSockets the `e2e` query is ignored.
- The legacy `register_e2e_key` message MUST be refused with `{"type":"e2e_register_result","metadata":{"ok":"0","reason":"unsupported"}}`. Device keys are established only by pairing.

Vectors: `keys` and `ws` in `shared/e2e-test-vectors.json`.

### 13.7 `/health`

`/health` includes `e2e: {v: 1, pub: <b64u S_b.pub>}` for compatibility and `features` containing `"auth-v3"`. Devices MUST NOT use `e2e.pub` to change a pinned key.

The application-level message catalog carried over the agent WebSocket (event types, payloads, capabilities) is specified separately in `shared/protocol.json`.

---

## 14. Push notifications

### 14.1 Registration

- Over a `device(D)` agent WebSocket, the device sends `register_push_token` with `content` = the APNs token in hex, `metadata.environment` = `development` or `production`, and `metadata.locale` = `ja` or `en` (default `ja`). The Bridge lowercases the token and validates `^[0-9a-f]{64,200}$`, and stores `{token, env, locale}` on D's row. Registration from `local` principals is ignored.
- If the same token is already stored on another device row: when that row has the same `clientDeviceId`, move the token to D; otherwise change nothing and log (a malicious device must not be able to hijack another device's notifications).
- Devices SHOULD send `register_push_token` on every agent WebSocket connection.
- The Bridge publishes its push targets to the registry (`/v3/push-targets`, §15.6) when they change (debounced ~2 s) and after its first successful registration. `tokenHash = hex(SHA256(UTF-8(lowercase hex token)))`; `env` is `production` or `sandbox` (`development` maps to `sandbox`).

### 14.2 Sealing

For each target device, the Bridge seals the plaintext

```json
{"title":"...","body":"...","payload":{"kind":"...", "...": "..."}}
```

with `k_push` (§4) using ChaCha20-Poly1305, a random 12-byte nonce, and **no associated data**, and builds the envelope

```json
{"v":1,"bid":"<bridgeId>","kid":"<16 hex>","n":"<base64 12-byte nonce>","c":"<base64 ciphertext||tag>"}
```

(`n`, `c` are standard base64 with padding.) Bridges MUST NOT send plaintext notification content through any path. The only exception is the Live Activity content state (§14.4), which carries `phase` and two integers in plaintext. Devices without a push target receive nothing.

Delivery is either through the registry (`/v3/push`, §15.6), one request per device, or directly to APNs with the developer's own credentials, in which case the alert MUST carry `mutable-content: 1` and only placeholder title/body.

### 14.3 Receiving

The device's notification extension looks up the pairing by `kid`, verifies that its `bridgeId` equals `bid`, derives `k_push`, decrypts, and replaces the placeholder content. On any mismatch or failure it MUST leave the placeholder unchanged.

Vector: `push` in `shared/e2e-test-vectors.json`.

### 14.4 Live Activities

The device starts the activity itself (foreground only) and sends its ActivityKit push token with `register_activity_token`. The Bridge registers the token hash with `/v3/live-activity-targets` and sends updates and the end through `/v3/live-activity` (§15.6). The content state MUST consist of exactly `phase` (`running`, `done`, `failed` or `stopped`), `running` and `failed` (integers). Bridges MUST NOT put any string derived from conversations, files, agent output, user or machine names, or session ids into a Live Activity, and the registry MUST NOT accept free text for it.

---

## 15. Registry HTTP API (`/v3/*`)

All endpoints are `POST` with JSON bodies, rooted at a deployment-specific base URL (e.g. `https://registry.example.com`).

### 15.1 Common rules

- **Rows are always keyed by `(userSub, bridgeId)`.** `bridgeId` is not unique across users; a registry MUST NOT reject a `bridgeId` because another user uses it, and MUST NOT index by `bridgeId` alone.
- Body limits: 8 KiB for `/v3/push`, 4 KiB otherwise. If `Content-Length` exceeds the limit, respond 413 `{"error":"too_large"}` without reading; without `Content-Length`, count while reading. Invalid JSON: 400 `{"error":"bad_json"}`. Invalid field: 400 `{"error":"bad_request","field":"<name>"}` (`field` is optional).
- Authentication:
  - **User** (devices): an identity-provider session JWT, or an OAuth access token validated through the provider's userinfo endpoint. A bearer value starting with `bdt_` MUST NOT be forwarded to the identity provider; respond 401. If an authorized-parties allowlist is configured, the JWT `azp` claim MUST be in it, and a JWT without `azp` MUST be rejected. Userinfo results MAY be cached for at most `min(5 minutes, token expiry)`.
  - **Bridge**: `Authorization: Bearer bdt_…`. Unknown or expired token: 401 `{"error":"unauthenticated"}`. Revoked token or a revocation record for `(userSub, bridgeId)`: **403 `{"error":"revoked"}`**.
- Rate limits: 429 `{"error":"rate_limited"}` with `Retry-After` (seconds).
- `relayURL` values MUST exactly match the deployment's relay allowlist.

String formats: `bridgeId` `^[A-Za-z0-9._-]{8,100}$`; `machineName` sanitized (§5.3, fallback `"PC"`); `relayId` `^[A-Za-z0-9_-]{16,128}$`; `bridgePub` strict `b64u` 32 bytes; `machineId` (optional) `^[a-f0-9]{64}$`; token (after lowercasing) `^[0-9a-f]{64,200}$`; `tokenHash` `^[0-9a-f]{64}$`.

### 15.2 `POST /v3/my-bridges` (user)

```json
{
  "bridges": [
    {"bridgeId":"mac-bridge-example","machineName":"MacBook Pro","platform":"mac",
     "relayURL":"wss://relay.example.com/ws","relayId":"...","bridgePub":"<b64u 32>",
     "online":true,"updatedAt":1789000000000,"addedAt":1788000000000,
     "keyRotatedAt":1789000000000,"previouslyRevoked":false}
  ],
  "revoked": [{"bridgeId":"mac-bridge-old","machineName":"MacBook Air","revokedAt":1789000000000}]
}
```

- Only the caller's rows. No secrets and no `machineId` are returned.
- `online` = `updatedAt` within the last 3 minutes. Rows not updated for 30 days are omitted (and purged).
- Rows are merged only when **both** `bridgePub` and `relayId` are equal (newest `updatedAt` wins). Rows sharing only one of them, or only `machineId` / name, MUST NOT be merged.
- `previouslyRevoked`: a revocation record of the same user carries the same `machineId`.
- `revoked`: Bridges removed within the last 180 days.
- Rows whose `relayURL` is not allowlisted are omitted.

Device rules: unpaired entries are usable only as `approve` targets; paired entries follow §11; Bridges listed in `revoked` MUST NOT be connected to automatically and the user is offered to delete or keep the pairing.

### 15.3 Rate limits (reference)

| Endpoint | Key | Limit |
|---|---|---|
| `/v3/device-token` | per user | 10 / hour |
| `/v3/bridges/register` | per user and Bridge | 240 / hour |
| registration with `keyRotation` | per user and Bridge | 5 / day |
| `/v3/my-bridges` | per user | 60 / minute |
| `/v3/revoke-bridge` | per user | 20 / hour |
| `/v3/push-targets` | per user and Bridge | 60 / hour |
| `/v3/push` | per user and Bridge | 30 / minute and 500 / hour |
| `/v3/live-activity-targets` | per user and Bridge | 120 / hour |
| `/v3/live-activity` | per user and Bridge | 30 / minute and 600 / hour |

Row limits: 20 registered Bridges per user (409 `too_many_bridges` for a new one), 20 push targets and 8 Live Activity targets per Bridge, 500 revocation records per user (oldest purged after 180 days), 2 `bdt_` rows per Bridge (current + grace).

### 15.4 `POST /v3/device-token` (user)

```json
{"bridgeId":"mac-bridge-example","machineName":"MacBook Pro","machineId":"<64 hex, optional>","platform":"mac"}
```

Optional header `X-BuddyOS-Device-Token: bdt_…` (the token currently held).

- Revocation record for `(userSub, bridgeId)` -> 403 `revoked`.
- A valid `bdt_` already exists for `(userSub, bridgeId)` and the header does not present it -> 409 `already_registered`. (A user session alone cannot take over a running Bridge's token.)
- Otherwise -> 200 `{"deviceToken":"bdt_…"}` (replacing older tokens).

Bridge behavior: on 409, save the current `bridgeId` as "previous registration", generate a new `bridgeId`, and retry once (pairings continue because they are keyed by `S_b.pub`; devices follow the new id via payload2). On 403, the Bridge treats itself as removed from the account (§15.7).

### 15.5 `POST /v3/bridges/register` (Bridge)

```json
{"v":3,"bridgeId":"mac-bridge-example","machineName":"MacBook Pro","platform":"mac","machineId":"<64 hex, optional>",
 "relayURL":"wss://relay.example.com/ws","relayId":"...","bridgePub":"<b64u 32>",
 "keyRotation":{"prevBridgePub":"<b64u 32>","prevRelayId":"..."}}
```

- `(userSub, bridgeId)` comes from the `bdt_` row; the body `bridgeId` is ignored.
- No row: create it (subject to the 20-row limit).
- Row exists with the same `bridgePub`, `relayId`, and `relayURL`: update `updatedAt` and name.
- Values differ: update only if `keyRotation` is present, its values equal the current row, and the rotation limit allows; record `keyRotatedAt`. Otherwise 409 `key_changed`. **This prevents accidental overwrites (e.g. an old Bridge writing back); it is not proof of ownership.**
- Revoked: 403 `revoked`.
- 200 `{"ok":true,"bridgeId":"…","deviceToken":"bdt_…"}` (`deviceToken` only when the registry rotated the token; the Bridge MUST then replace its stored token).

Bridges SHOULD register about once per minute. A Bridge remembers the last successfully registered `{bridgePub, relayId, relayURL}` and sends `keyRotation` when they change. On 409 `key_changed` it re-registers under a new `bridgeId` (saving the previous one).

### 15.6 `POST /v3/push-targets` and `POST /v3/push` (Bridge)

```json
// /v3/push-targets — replaces all device push targets of this (userSub, bridgeId) (Live Activity targets are not touched), at most 20
{"targets":[{"tokenHash":"<64 hex>","env":"production"}]}
// 200 {"ok":true,"count":1}

// /v3/push — exactly one recipient per request
{"environment":"production","token":"<64..200 hex>",
 "e2e":{"v":1,"bid":"mac-bridge-example","kid":"<16 hex>","n":"<base64>","c":"<base64, at most 4096 chars>"},
 "placeholder":"ja","interruptionLevel":"time-sensitive"}
// 200 {"ok":true,"sent":true,"invalid":false}
```

- The registry lowercases `token`, hashes it, and checks that it is a target of the same `(userSub, bridgeId)` and environment; otherwise 403 `unknown_token` and nothing is sent.
- `e2e` is required; `e2e.bid` MUST equal the `bdt_` row's `bridgeId` (else 400 `bad_bid`).
- The registry never accepts title/body. It sends only a fixed placeholder (`ja` or `en`), always with `mutable-content: 1`. `interruptionLevel` is restricted to `active` or `time-sensitive` (default `time-sensitive`).
- `invalid: true` means the push service reported the token invalid; the Bridge removes that target and republishes its targets. On 403 `unknown_token`, the Bridge republishes its targets and retries once.
- If the push service is not configured or fails, the reference registry responds 503 or 502 with `{"ok":false,"error":"<reason>"}`.

### 15.6.1 `POST /v3/live-activity-targets` and `POST /v3/live-activity` (Bridge)

```json
// /v3/live-activity-targets — replaces all Live Activity targets of this (userSub, bridgeId), at most 8
{"targets":[{"tokenHash":"<64 hex>","env":"production"}]}
// 200 {"ok":true,"count":1}

// /v3/live-activity — exactly one activity per request
{"environment":"production","token":"<64..400 hex>","event":"update","timestamp":1792540805,
 "state":{"phase":"running","running":3,"failed":0},"staleAfterSec":1500}
{"environment":"production","token":"<64..400 hex>","event":"end","timestamp":1792541100,
 "state":{"phase":"done","running":0,"failed":0},"dismissAfterSec":300}
// 200 {"ok":true,"sent":true,"invalid":false}
```

- `/v3/live-activity-targets` has the same shape and responses as `/v3/push-targets`; more than 8 targets is 400 `bad_request` (field `targets`). It does not touch the device push targets.
- The registry lowercases `token`, hashes it, and checks that it is a Live Activity target of the same `(userSub, bridgeId)` and environment; otherwise 403 `unknown_token` and nothing is sent.
- `event` is `update` or `end` (`start` is 400). `state` carries nothing but `phase`, `running` and `failed`: for `update`, `phase` is `running`, `running` is 1-999 and `failed` 0-999; for `end`, `phase` is `done`, `failed` or `stopped`, `running` is 0 and `failed` 0-999. `timestamp` is accepted but ignored: the registry always uses its own current time for the APNs `timestamp`, and `stale-date` / `dismissal-date` are computed from it. `staleAfterSec` (update only) is 60-3600, default 1500; `dismissAfterSec` (end only) is 0-14400, default 300.
- The registry never accepts free text. It sends `apns-push-type: liveactivity` with no alert and no sound.
- `invalid: true` means the push service reported the token invalid; the Bridge removes that target and republishes its Live Activity targets. On 403 `unknown_token` the Bridge republishes its targets and retries once. If the push service is not configured or fails, the reference registry responds 503 or 502 as for `/v3/push`.

### 15.7 `POST /v3/revoke-bridge` (user only; `bdt_` gets 401)

```json
{"bridgeId":"mac-bridge-example"}
// 200 {"ok":true}
// 404 {"error":"not_found"}   (no registration and no bdt_ for this user and bridgeId)
```

The registry records a permanent revocation for `(userSub, bridgeId)`, revokes the `bdt_`, and deletes the registration and push targets. **There is no way to undo this.** Device lists on the computer are not touched by the registry.

When a removed Bridge next contacts the registry and receives 403 `revoked`, it deletes its `bdt_`, generates a **new** `bridgeId` (the old one is never reused), and stops registering until the user explicitly signs in again on the computer. It does not delete its paired devices or keys by itself; the user at the computer decides whether to also disconnect all devices.

### 15.8 Legacy endpoints

Unversioned predecessors of these endpoints are out of scope. A registry that still serves them SHOULD be able to answer them with 410 `{"error":"upgrade_required"}` and `Retry-After` without reading any data.

---

## 16. Error code reference

| Layer | Codes |
|---|---|
| Plaintext tunnel error (§8.9, unauthenticated) | `version`, `invite_invalid`, `bad_message`, `rate_limited` |
| payload2 `error` (§8.8, authenticated) | `unknown_device`, `revoked`, `bad_request`, `approval_unavailable`, `busy`, `rate_limited`, `too_many_devices`, `bridge_error` |
| `pair_rejected.reason` (§10.1.1) | `rejected`, `timeout`, `code_mismatch`, `closed`, `busy`, `rate_limited`, `too_many_devices`, `bridge_error`, `reset` |
| Bridge HTTP (§13.4, §13.5) | `unauthorized`, `local_only`, `device_only`, `forbidden`, `admin_unavailable`, `not_found`, `code_mismatch`, `bad_code`, `no_pending`, `device_gone`, `not_approver`, `disabled` |
| Registry (§15) | `too_large`, `bad_json`, `bad_request`, `unauthenticated`, `revoked`, `rate_limited`, `already_registered`, `key_changed`, `too_many_bridges`, `unknown_token`, `bad_bid`, `not_found`, `upgrade_required` |

---

## 17. Versioning

- **Tunnel version.** `v` in `buddyos_tunnel_init` / `buddyos_tunnel_hello` / `buddyos_tunnel_error` and the transport frame `version` byte (`0x03`) identify this specification. A v3 Bridge refuses other versions with `version`. A future version MUST change both the `v` value and the Noise prologue.
- **Invite version.** `v=3` in `buddyos://pair`. Consumers reject other values.
- **Relay version.** `v=2` in relay URLs refers to the relay protocol and is independent.
- **Reserved bits.** Frame `flags` MUST be zero; receivers close on non-zero flags. Future extensions that need flags MUST bump the frame version.
- **Extensibility.** JSON receivers ignore unknown keys; new control-message types MUST NOT be sent to peers that have not advertised support, because unknown control messages close `pair` / `approve` sessions.
- **Feature advertisement.** `/health.features` contains `"auth-v3"` on v3 Bridges.
- **Inner encryption.** The v1 inner WebSocket encryption (§13.6) and v1 push envelope (§14) are unchanged by v3.

---

## 18. Test vectors

All vectors live in `shared/e2e-test-vectors.json`:

| Section | Covers |
|---|---|
| `keys` | Static key pairs: Bridge = RFC 7748 §6.1 "Alice", device = "Bob"; their X25519 shared secret |
| `tunnelV3` | Fixed ephemeral keys; for each of `connect`, `pair`, `approve`: `psk`, `payload1`, `init` (message 1), `payload2`, `hello` (message 2), `handshakeHash` (`H`), `kC2S`, `kS2C`, and sample transport `frames`. Plus `deviceKeyId`, `pair.inviteSecret` / `inviteId` / `psk` / `credential` / `credentialHash`, and `approve.nI` (`N_d`) / `nR` (`N_b`) / `commit` / `sas` |
| `pairingV3` | Name sanitization cases, display name, strict `b64u` accept/reject cases, query encoding, invite URL build/parse (including literal `+`), SAS display, code-input normalization |
| `push` | `k_push` derivation and a sealed push payload |
| `ws` | v1 inner WebSocket keys and frames (§13.6) |

Encoding inside the vectors: `init.e`, `init.s`, `init.p`, `hello.e`, `hello.p` are `b64u`; all other keys, hashes, and frames are hex. `payload1`, `payload2`, and `frames[].plaintext` are byte-exact strings and MUST NOT be re-serialized. Note that `connect` and `approve` share ephemeral keys and PSK, so their `kC2S` / `kS2C` coincide (Split depends only on `ck`), while `handshakeHash` differs.

The `tunnelV3` values were also cross-checked against the official Noise test vectors for `Noise_IKpsk2_25519_ChaChaPoly_SHA256` (cacophony).

### 18.1 Running the reference check

```sh
node shared/tools/check-tunnel-v3.mts
```

Requires Node.js 22.6 or newer (native TypeScript type stripping; on Node 22.6–23.5 add `--experimental-strip-types`). The script uses `shared/tools/tunnelV3Ref.mts` (a dependency-free TypeScript reference built on `node:crypto`) to:

1. run initiator and responder for all three modes with the fixed ephemeral keys and compare every message, `H`, both transport keys, and every frame;
2. check that the responder recovers `payload1` and `devicePub`, and the initiator recovers `payload2`;
3. check `inviteId`, invite `psk`, `deviceKeyId`, `credentialHash`, `commit`, and `sas`;
4. check that a zero-PSK initiator cannot open the `pair` message 2;
5. check frame rejection (version `0x01`, flags `0x01`, out-of-order `seq`, 25-byte frame);
6. check every `pairingV3` case.

It prints `check-tunnel-v3: all N checks passed` and exits 0, or lists failures and exits 1.

### 18.2 Negative tests every implementation should have

1. `pair` message 2 read by an initiator with a zero PSK -> decryption failure.
2. One bit flipped in `connect` `init.s`, `init.p`, or `hello.p` -> decryption failure.
3. Responder with the wrong static key reading `init` -> `s` decryption failure.
4. All-zero `init.e` -> DH failure.
5. Frames with version `0x01`, flags `0x01`, `seq` starting at 2, `seq = 0`, or length 25 -> rejected without decryption.
6. `approve` with one byte of `approve_reveal.n` changed -> commitment mismatch; device aborts.
7. Invites with `v=2`, missing `secret`, a duplicated key, a non-allowlisted `relay`, expired `exp`, a 31-byte `key`, a padded `key`, or an `apiKey` field -> rejected.
8. `pair`: 10 undecryptable frames after message 2 -> invite still valid; a correct `pair_confirm` afterwards succeeds.
9. `pair`: a used invite presented by a different key -> `invite_invalid`; by the same key -> retry allowed (new `bdc_`).
10. `approve`: the same message 1 resent 10 times -> no attempts counted.
11. Authorization header and `?apiKey=` differing -> 401; `/local/*` with query credential -> 401; with `Origin` -> 403; unknown route -> 404.

---

## 19. Security considerations

### 19.1 What the relay can do

The relay can drop, delay, reorder at the connection level, replay message 1, inject garbage, and forge plaintext `buddyos_tunnel_error` messages. It cannot read or modify transport frames, learn device identities (the device static key is encrypted in message 1), or complete a handshake. Bridges must therefore treat nothing before the first decrypted frame as evidence (§10.1), and devices must never act destructively on unauthenticated errors (§8.9).

### 19.2 Invites

An invite is a bearer capability for 10 minutes. It is consumed only by a successful `pair_confirm`, and after that is usable only by the same device key. Its use is visible on the computer. Invites MUST be kept in memory only and MUST NOT be logged.

### 19.3 Custom URL scheme interception

`buddyos://pair` links carry the invite `secret` and the Bridge key. On platforms where any app can register the same custom scheme, a malicious app may receive the link instead of the BuddyOS app and pair first within the 10-minute window. Mitigations: invites are single-use and short-lived; the computer notifies the user and lists the paired device so it can be revoked. Implementations SHOULD prefer scanning invites with the app's own camera, and deployments SHOULD offer verified https links (Universal Links / Android App Links) instead of, or in addition to, the custom scheme. A link-sourced invite never replaces an existing pairing with a different key (§11).

### 19.4 Relay allowlist

The invite's `relay` URL decides where the device sends its handshake. A malicious invite pointing to an attacker-controlled relay cannot break the cryptography, but would let the attacker observe metadata and mount denial of service. Devices MUST therefore accept only relay URLs that exactly match a **built-in allowlist** fixed at build time, and MUST apply the same check to `relayURL` in `paired` and in registry entries. If a deployment allows users to add relays at run time, this MUST be done only through an explicit settings UI with a warning — never from an invite, link, or registry entry. The registry independently enforces its own relay allowlist.

### 19.5 Credential handling

- `bdc_` credentials, the local key, the admin key, invite secrets, static private keys, and SAS codes MUST NOT be logged. Logs SHOULD show only the first 8 characters of `deviceKeyId` and the display name. Request URLs MUST NOT be logged with their query (it may carry `?apiKey=`).
- All comparisons of `credHash`, the local key, the admin key, and SAS codes MUST be constant time.
- Bridges store only `credHash`. Devices store `bdc_` and `S_d` in platform secure storage (e.g. Keychain with this-device-only accessibility, Android Keystore-backed storage, OS-encrypted storage on desktop). On desktop, credentials SHOULD stay in the privileged process and not be exposed to renderer/web content.
- Child processes spawned by the Bridge (agents) MUST NOT inherit the admin-key pipe (stdin redirected to the null device).

### 19.6 Registry

The registry holds no material that grants access to a Bridge. Its compromise allows denial of service and attempts to lure *unpaired* devices to forged entries, which the SAS step defeats. Because the registry API is public, deployments need per-account limits on registered Bridges, rate limits on push, and abuse monitoring (§15.3).

### 19.7 Denial of service

Knowledge of `relayId` allows flooding a Bridge with handshakes and approval requests. The pre-authentication slot pool, pairing pool, approval limits, and the rule that failures never disable acceptance bound the impact; "disconnect all devices" rotates `relayId`.

---

## 20. Remaining work

Items not yet covered by this draft:

1. **Relay protocol details.** §7 documents only what Bridges and devices use. A full description of the Paseo relay protocol v2 (server/client pairing semantics, close codes, limits, heartbeat expectations on the relay side) should be referenced from or written down for self-hosters.
2. **Device-side local proxy.** Behavior of the device loopback proxy (port selection, one tunnel per TCP connection, reconnection, the 32-connection cap) is described only informally.
3. **Bridge state and storage formats** (`devices.json`, invite and approval state, revocation marks, reset/migration procedure) are implementation details today; a self-hosting or third-party Bridge would benefit from an informative appendix.
4. **Local administration API** (Appendix A) is summarized, not fully specified; the `DevicesView` schema and `lastReset.reason` values are not included.
5. **Preview authentication** (`/preview/*` sessions, iframe sandbox, CSP) is only referenced; vectors are in `shared/preview-auth-vectors.json` and a dedicated spec is pending.
6. **Application message catalog.** `shared/protocol.json` is the machine-readable source; a human-readable companion is pending.
7. **Registry data model and retention** (row schema, cron purge rules) are described only through API behavior.
8. **IANA-style registries** for error codes and control-message types, and a formal change-control process.
9. **Japanese translation** of this document.

---

## Appendix A. Bridge local administration API (informative)

Used only by the desktop application on the same computer that launched the Bridge. Not reachable through the tunnel.

- **Admin key.** On each Bridge launch the supervising desktop app generates `"bda_" || b64u(32 random bytes)`, keeps it in memory only, and writes one line `{"adminKey":"bda_…"}\n` to the Bridge's stdin, keeping stdin open for the Bridge's lifetime. The Bridge reads at most 256 bytes for at most 5 s if stdin is not a TTY, and accepts `^bda_[A-Za-z0-9_-]{43}$`. EOF on stdin closes the approval window and withdraws local pending approvals with `closed`. The admin key MUST NOT be passed by environment variable, argument, file, or log. A Bridge without an admin key answers every `/local/*` request with 403 `admin_unavailable`.
- **Authentication.** `/local/*` requires both `Authorization: Bearer <local key>` and `X-BuddyOS-Admin: <admin key>`, compared in constant time (401 on mismatch).
- **Endpoints** (JSON bodies up to 4 KiB):

| Method and path | Purpose |
|---|---|
| `POST /local/pairing/invites` | Create an invite: 201 `{"inviteId","url","expiresAt"}` |
| `DELETE /local/pairing/invites/:inviteId` | Cancel an invite |
| `GET /local/devices`, `GET /local/devices/events?since=&boot=` | Device list snapshot; long-poll for changes (25 s) |
| `POST /local/devices/:deviceKeyId/revoke` | Revoke one device (row deleted, 90-day revocation mark, tunnels closed, preview sessions and push target removed) |
| `POST /local/devices/:deviceKeyId/rename` | Set a sanitized label |
| `POST /local/approvals/open`, `POST /local/approvals/close` | Open (10 min) / close the approval window |
| `POST /local/devices/pending/approve` | Enter a code: `{"code":"213854"}` -> 200, or `code_mismatch` with `remaining`, `bad_code`, `no_pending`, `device_gone` |
| `POST /local/devices/pending/:pendingId/reject` | Reject (24 h block) |
| `POST /local/devices/reset` | "Disconnect all devices": clear devices and pending state, increment `epoch`, regenerate `S_b`, `relayId`, and the local key, reconnect to the relay, then re-register with `keyRotation` |
| `POST /local/devices/settings` | `approvalsEnabled`, `remoteApprovalsEnabled` |

The device list returned to the admin client MUST NOT contain SAS codes.

---

## References

- [RFC 2119] Bradner, S., "Key words for use in RFCs to Indicate Requirement Levels".
- [RFC 8174] Leiba, B., "Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words".
- [RFC 4648] Josefsson, S., "The Base16, Base32, and Base64 Data Encodings".
- [RFC 5869] Krawczyk, H., Eronen, P., "HMAC-based Extract-and-Expand Key Derivation Function (HKDF)".
- [RFC 7748] Langley, A., Hamburg, M., Turner, S., "Elliptic Curves for Security".
- [RFC 8439] Nir, Y., Langley, A., "ChaCha20 and Poly1305 for IETF Protocols".
- Perrin, T., "The Noise Protocol Framework", revision 34.
