# Security Model

This document explains what live-share.nvim encrypts, what third-party servers can and cannot see, how session keys are exchanged, and what assumptions users should understand before using the plugin.

---

## What is encrypted

Every message exchanged between host and guest is individually encrypted with **AES-256-GCM**:

- Buffer patches (text edits)
- Cursor and selection positions
- File content (workspace sync)
- Shared terminal I/O
- Protocol control messages (hello, init, bye, …)

Encryption is mandatory. Sessions will not start if OpenSSL is unavailable.

Each message carries a fresh random **12-byte nonce**. The same nonce is never reused within a session. The GCM authentication tag detects any tampering or truncation.

---

## Key exchange

The host generates a **32-byte random session key** at session start. This key is appended to the share URL as a fragment:

```
https://some-tunnel-host/path#key=<base64url-encoded-key>
```

URL fragments (`#…`) are a browser/client-side concept — **they are never sent to the tunnel server** in HTTP requests. The tunnel server only sees the path before the `#`. The key exists only in the URL string itself, and is transmitted to guests exclusively through whatever channel the host uses to share the URL (clipboard, chat, etc.).

**Consequence:** the security of the session key is only as strong as the channel used to share the URL. Sharing over an encrypted channel (Signal, encrypted email) is safer than sharing over plaintext channels.

---

## What tunnel servers can see

With the default `ws` transport, all session traffic is routed through the configured tunnel provider (serveo.net, localhost.run, ngrok, bore). These servers act as TCP/HTTP reverse proxies.

What they **can** see:
- Connection timing and volume (number of bytes, frequency of messages)
- Source IP address of the connecting guest
- That a live-share.nvim session is active (based on the WebSocket upgrade and URL path pattern)

What they **cannot** see:
- Any session content — all payloads are AES-256-GCM ciphertext
- The session key — it travels in the URL fragment, never in the HTTP request

With the `punch` transport, tunnel traffic is limited to the ~5-second signaling phase. All subsequent session traffic flows directly between host and guest over UDP, bypassing the tunnel server entirely. The relay fallback (used when direct hole-punching fails) is hosted on the host's own signaling server — it is not a third-party service.

---

## Guest approval

Before a guest can receive any session data, the host is prompted to approve the connection via `vim.ui.select`. Read-only or read-write role is assigned at this point. Guests that are rejected receive an error message and are disconnected.

**There is no authentication beyond key possession.** Any guest who obtains the URL and is approved by the host can participate. The approval prompt is the only gate.

---

## Threat model

| Threat | Protected? |
|--------|-----------|
| Tunnel server reads session content | Yes — AES-256-GCM |
| Network eavesdropper reads traffic | Yes — encrypted end-to-end |
| Attacker replays or tampers with messages | Yes — GCM authentication tag detects this |
| Attacker obtains the session URL | Partial — they still need host approval to join |
| Host approves a malicious guest | No — the host is responsible for approving only trusted peers |
| Session key leaked via URL sharing channel | No — protect the channel used to share the URL |
| Tunnel provider logs connection metadata | No — IP addresses and timing are visible to the tunnel provider |

---

## Malicious actor scenarios

### Malicious guest

A guest who obtained the session URL and was approved by the host can:

- Send arbitrary protocol messages to the server.
- If approved as **read-write**: apply patches to the host's buffer — the same capability as a trusted RW guest. There is no content filtering.
- If approved as **read-only**: patch messages are dropped by the server before reaching the host's message handler (`server.lua`). The guest cannot escalate to RW without a new host approval.
- Send malformed or crafted messages. `protocol.decode` returns `nil` for invalid JSON or failed GCM authentication; such messages are silently discarded and do not crash the host.
- Spam cursor or terminal events. There is no rate limiting on incoming messages.

A malicious guest **cannot**:

- Decrypt sessions they are not part of (each session has an independent key).
- Forge messages that pass GCM authentication without the session key.
- Silently re-join after being disconnected — the host must approve each connection attempt.

### Malicious host

The guest trusts the host entirely. A malicious host can:

- Send arbitrary file content via `workspace_info` and `file_response`.
- Write arbitrary data to the guest's terminal buffer via `terminal_data`.
- Observe all guest edits, cursor positions, and keystrokes sent to the shared terminal.
- Assign a read-only role and then send patches — guests apply what they receive.

There is no mechanism for a guest to verify the host's identity or the integrity of the workspace content beyond the shared session key. **Do not join sessions from untrusted hosts.**

### Compromised relay / tunnel server

With the `ws` transport, a compromised relay can:

- Observe connection timing, byte volumes, and guest IP addresses.
- Drop or delay packets (denial of service).
- Inject arbitrary bytes into the TCP stream. Injected bytes will fail GCM authentication and be discarded, but can disrupt framing.

A compromised relay **cannot**:

- Read session content — all payloads are AES-256-GCM ciphertext.
- Inject valid messages without the session key.
- Obtain the session key — it travels in the URL fragment and is never sent over the network.

With the `punch` transport, the signaling phase (~5 s) and any relay fallback still pass through the configured tunnel provider — a compromised tunnel has the same capabilities listed above. Once direct hole-punching succeeds, all subsequent collaborative traffic flows over a direct UDP channel between host and guest, bypassing the tunnel entirely. The session key remains out of reach in both cases.

---

## In scope / Out of scope

**In scope** — what this plugin is designed to protect:

- Confidentiality of buffer content, file content, terminal I/O, and cursor positions against passive observers and tunnel servers.
- Integrity of messages in transit (AES-256-GCM authentication tag).
- Session key confidentiality from tunnel servers (URL fragment semantics).
- Role enforcement: read-only guests cannot apply patches to the host's buffer.

**Out of scope** — what this plugin explicitly does not protect against:

- A malicious approved host.
- Denial-of-service via message flooding.
- Guests sharing the session URL with unauthorized third parties.
- Forward secrecy: a session URL leaked after the fact can be used to decrypt logged traffic.
- Key rotation within an active session.
- Authentication of participants beyond URL possession and host approval.

---

## Assumptions and limitations

- **OpenSSL must be present.** The plugin uses LuaJIT FFI to call into `libcrypto`. If OpenSSL is not available, the session is aborted.
- **The session key is not rotated** during a session. A new key is generated for each new session.
- **No forward secrecy.** The tunnel provider sees encrypted traffic during the session and could log it. If the session URL were later leaked (e.g. via a breached chat log), that recorded traffic could in theory be decrypted retroactively. In practice this requires the tunnel provider to log traffic AND the URL to be independently compromised — an unlikely combination for typical pair programming use.
- **The URL is single-use by convention, not by enforcement.** Nothing prevents a guest from sharing the URL with a third party. The host approval prompt is the only protection against uninvited guests.
- **Host and guest should run the same protocol version.** See [COMPATIBILITY.md](./COMPATIBILITY.md) for version negotiation details.
