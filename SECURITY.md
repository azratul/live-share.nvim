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

## Assumptions and limitations

- **OpenSSL must be present.** The plugin uses LuaJIT FFI to call into `libcrypto`. If OpenSSL is not available, the session is aborted.
- **The session key is not rotated** during a session. A new key is generated for each new session.
- **No forward secrecy.** The tunnel provider sees encrypted traffic during the session and could log it. If the session URL were later leaked (e.g. via a breached chat log), that recorded traffic could in theory be decrypted retroactively. In practice this requires the tunnel provider to log traffic AND the URL to be independently compromised — an unlikely combination for typical pair programming use.
- **The URL is single-use by convention, not by enforcement.** Nothing prevents a guest from sharing the URL with a third party. The host approval prompt is the only protection against uninvited guests.
- **Host and guest should run the same protocol version.** See [COMPATIBILITY.md](./COMPATIBILITY.md) for version negotiation details.
