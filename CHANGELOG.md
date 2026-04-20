# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [2.1.0] — 2025 (current)

### Added
- **P2P transport via punch.lua** — when `transport = "punch"`, collaborative traffic flows
  over a direct encrypted UDP channel between host and guest, bypassing the tunnel server
  entirely after the short signaling phase (~5 s). Requires the
  [`punch`](https://luarocks.org/modules/azratul/punch) LuaRocks package on both sides.
- **Workspace browser** (`:LiveShareWorkspace`) — floating window listing all files in the
  remote workspace, with on-demand file requests.
- **Shared terminal** — host can open a PTY shell streamed to all guests as `terminal_data`
  messages.
- **Follow mode** (`:LiveShareFollow`) — guest's active buffer tracks the host's focus events.
- **Peer approval flow** — new guests enter a `pending` state; the host is prompted via
  `vim.ui.select` to approve/deny and assign a role (`rw` or `ro`) before the peer receives
  any broadcast.
- **Read-only guest role** — guests assigned `ro` cannot send patches; editing is disabled on
  their buffers.
- **Visual selection sharing** — cursor messages include `sel_*` fields when the sender is in
  visual mode; rendered as extmarks on remote peers.
- **Peer list** (`:LiveSharePeers`) — floating window showing connected peers and their active
  file.
- **Capabilities negotiation** — `hello` / `hello_ack` exchange `caps` arrays; the host
  advertises `required_caps` and `optional_caps`.
- **Protocol version check** — guest emits a `WARN` notification when the host's
  `protocol_version` differs from its own (`M.VERSION = 3`).

### Changed
- Replaced the `instant.nvim` dependency with a self-contained collaboration engine
  (`lua/live-share/collab/`): WebSocket transport, binary framing, AES-256-GCM encryption,
  buffer sync, and cursor tracking.
- Transport auto-detection: server reads the first 4 bytes of every connection — `"GET "`
  triggers a WebSocket upgrade; anything else is treated as raw length-prefixed TCP.
- Encryption is now mandatory — sessions will not start without OpenSSL.
- Protocol wire version bumped to **3**.

### Removed
- `instant.nvim` dependency.
- Plaintext fallback (encryption is now required).

---

## [1.1.0] — 2024

Last release based on `instant.nvim` as the collaboration engine.
See the [`v1.1.0`](https://github.com/azratul/live-share.nvim/releases/tag/v1.1.0) tag.
