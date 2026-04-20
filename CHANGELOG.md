# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [2.1.1] — 2026-04 (current)

### Fixed
- **Guest state machine** — `on_message` now gates messages by connection state
  (`handshake` → `workspace_sync` → `active`). Patches and cursor events that arrive
  before `open_files_snapshot` are buffered and replayed in order once the workspace
  snapshot lands, preventing spurious buffer mutations during the join sequence.
- **`open_files_snapshot` always sent** — the host now sends this message even when no
  files are currently open, so guests always exit `workspace_sync` cleanly.
- **`peers_snapshot` ordering** — the host now sends `peers_snapshot` before
  `open_files_snapshot`, matching the order mandated by PROTOCOL.md §8.
- **`hello_ack` caps corrected** — the guest now advertises `workspace`, `cursor`,
  `follow`, and `terminal` (previously `cursor` and `follow` only).
- **`required_caps` validation** — if the host requires a capability the guest does not
  support, the guest sends `bye` and disconnects with an error message instead of
  proceeding with undefined behaviour.
- **Seq gap detection** (§7.1) — the guest tracks the last seen global `seq` number.
  A gap triggers `file_request` for the affected path; stale/duplicate patches are
  silently dropped. Seq tracking resets after `file_response` or `open_files_snapshot`.
- **Out-of-range patch detection** (§7.2) — if a patch's `lnum` exceeds the current
  buffer length, the guest sends `file_request` rather than applying a broken patch.
- **`bye` name on abrupt disconnect** — the server now tracks peer names (set when
  `hello_ack` is received) and includes the name in the synthesised `bye` broadcast on
  unexpected disconnection.
- **10 s workspace-sync watchdog** — if `open_files_snapshot` is not received within
  10 seconds of the handshake completing, the guest disconnects with an error.

---

## [2.1.0] — 2026-03

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
