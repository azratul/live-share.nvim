# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Security
- **Workspace sandbox hardening** — `lua/live-share/workspace.lua` now resolves
  every requested path through `uv.fs_realpath` and verifies the resolved path
  is contained inside `realpath(workspace_root)`. Closes a class of path
  traversal possibilities that the previous substring-based filter could miss
  (absolute paths like `/etc/passwd`, NUL bytes, segments equal to `..`, and
  symlinks pointing outside the workspace). For files that don't exist yet, the
  parent directory is validated instead so `write_file` can't escape via a
  symlinked subdirectory.
- **Sensitive-file filter** (default on) — `.env`, `.env.*`, SSH keys
  (`id_rsa`/`id_ed25519`/`id_ecdsa`/`id_dsa` and their `.pub` counterparts,
  `known_hosts`, `authorized_keys`), AWS / kube / gcloud / azure credential
  trees, `*.pem` / `*.key` / `*.p12` / `*.pfx` / `*.jks` / `*.keystore` /
  `*.asc` / `*.gpg`, and package-manager creds (`.npmrc`, `.pypirc`, `.netrc`,
  `_netrc`, `htpasswd`) are now excluded from `:LiveShareWorkspace` listings
  and refused on file requests / patches. Opt out with
  `setup({ allow_sensitive_files = true })`; extend with
  `setup({ extra_sensitive_patterns = { "%.tfstate$", "/secrets/" } })`.
- **Out-of-band session fingerprint** — the host now prints a 6-byte SHA-256
  prefix of the session key (e.g. `AB-CD-EF-12-34-56`) when the session
  starts; the guest prints the same fingerprint after connecting. A mismatch
  means the URL fragment was rewritten in transit. Also visible in
  `:LiveShareDebugInfo`. Pure UI — no protocol change.

### Added
- **Mid-session host control commands** (no protocol change — uses existing
  primitives):
  - `:LiveShareKick <peer_id>` — disconnect a peer immediately and broadcast a
    `bye` to remaining peers.
  - `:LiveShareReadonly <peer_id>` — demote a connected guest to read-only;
    subsequent patches from that peer are dropped server-side with the same
    `unauthorized` error already used for join-time RO assignment.
  Tab completion on both commands lists currently connected peer ids.
- **Local audit log** (`lua/live-share/audit.lua`) — append-only JSONL of
  session events at `stdpath('state')/live-share-audit.log` (configurable via
  `setup({ audit_log = "/path" })`, disable with `audit_log = false`). One
  JSON object per line: `ts`, `event`, `sid`, plus event-specific fields
  (`peer_id`, `peer_name`, `path`, `reason`, `role`). Events recorded:
  `session_start` / `session_stop`, `peer_connect_request`, `peer_approved` /
  `peer_denied`, `peer_joined`, `peer_disconnected`, `peer_kicked`,
  `role_changed`, `file_request_allowed` / `file_request_denied` (with
  reason: `sensitive` / `not-found-or-out-of-sandbox`),
  `patch_rejected_sensitive`, `terminal_opened`. File contents and patch
  payloads are NEVER written to the log.
- **Shared-terminal scrollback replay on join** — when a guest is approved
  after a `:LiveShareTerminal` was opened, the host now replays up to
  `terminal_scrollback_bytes` (default 64 KB) of recent shell output to that
  guest right after `open_files_snapshot`.  Previously, late-joining or
  reconnecting guests saw a blank terminal until the shell next produced
  output.  Implemented as a new `lua/live-share/scrollback.lua` ring buffer
  (head/tail markers, O(1) eviction, whole-chunk drops to avoid cutting
  mid-codepoint) plumbed into `shared_terminal.lua`.  Uses the existing
  `terminal_open` and `terminal_data` messages — no protocol change.  Tests:
  `tests/scrollback/scrollback_spec.lua` (7 tests) and
  `tests/shared_terminal/snapshot_spec.lua` (6 tests).
- **Faster workspace scan for large repos** — when the host workspace is a
  git repo, `workspace.scan()` now defers to `git ls-files -co
  --exclude-standard` for a fast, gitignore-aware listing instead of walking
  the whole tree. Falls back to the manual walker if `git` is unavailable,
  fails, or `scan_use_gitignore = false`. Walk mode also gained a wider
  default ignore set (`target`, `.venv`, `.next`, `.turbo`, `.gradle`,
  `.terraform`, `coverage`, `bin`, `obj`, …) and a hard cap on the number of
  files included. New options: `scan_use_gitignore` (default `true`),
  `scan_max_files` (default 10000), `scan_max_depth` (default 8),
  `scan_extra_ignore` (extra dir basenames). The `workspace_info` message
  shape is unchanged — fully backwards-compatible with `open-pair`.
- **`RECIPES.md`** — practical walkthroughs for the seven most common workflows:
  Neovim ↔ Neovim, Neovim ↔ VS Code via `open-pair`, LAN-only session (custom
  provider), SSH-tunnel session with alternative providers, read-only review
  session, self-hosted relay (privacy-first, covers SSH server and `bore` server
  paths and how it applies to the `punch` transport), and shared terminal session.
- **README "Privacy-first option" callout** in the Tunnel providers section
  pointing to the self-hosted relay recipe.
- **Demo media slots in README** — placeholders (HTML comments) and a
  `docs/media/` directory ready for the hero, cross-editor, shared-terminal, and
  follow-mode GIFs.
- **`crypto.sha256`** — exposed for the fingerprint helper, with canonical
  test vectors (empty string and `"abc"`).
- **New tests:**
  - `tests/workspace/workspace_spec.lua` — 25 tests covering sandbox traversal,
    NUL bytes, symlink escape, sensitive-file scan/read/write rules, the
    `allow_sensitive_files` opt-out, `extra_sensitive_patterns`, the wider
    walk-mode ignore list, `scan_extra_ignore`, the `scan_max_files` cap, and
    the `git ls-files` fast path (gitignore respect, untracked inclusion,
    sensitive filter on top of git output, and fallback when disabled).
  - `tests/audit/audit_spec.lua` — 5 tests covering disabled mode, JSONL
    append-only writes, `set_session` propagation, and `close()` semantics.
  - `tests/integration/edge_cases_spec.lua` — 1 new test: `server.kick()`
    disconnects an approved peer and stops their broadcasts.
  - `tests/crypto/crypto_spec.lua` — 7 new tests for `sha256` and
    `fingerprint` (length, format, determinism, distinctness).

### Changed
- **README positioning** — overview rewritten to position the project as a GPL-3.0,
  Neovim-native, end-to-end encrypted alternative to VS Code Live Share. Cross-editor
  collaboration with VS Code via [open-pair](https://github.com/darkerthanblack2000/open-pair)
  is now highlighted in the overview rather than buried in a footnote.
- **`:LiveShareDebugInfo`** now includes the session fingerprint.

### Internals
- `server.lua` gains `kick(peer_id)` for immediate disconnect of an approved
  or pending peer.
- `connection.lua` exposes `:kick(peer_id)` on the listener handle.
- `host.lua` wires `audit.setup` / `audit.set_session` on `M.start` and
  `audit.close` on `M.stop`. Adds `M.kick`, `M.set_peer_role`.
  Defence-in-depth: incoming patches against paths that fail
  `workspace.is_sensitive` are silently dropped before reaching the broadcast
  path.
- New defaults in `init.lua`: `allow_sensitive_files = false`,
  `extra_sensitive_patterns = nil`, `audit_log = true`.

---

## [2.1.4] — 2026-04-24 (current)

### Changed
- **`punch` 0.3.2 now required** — the published 0.3.2 rock now includes container
  support (peer-reflexive candidate learning for Docker/Podman internal IPs), HTTPS proxy
  compatibility (ALPN forces HTTP/1.1 so localhost.run and similar reverse proxies do not
  negotiate HTTP/2), and chunked-encoding support in the signaling HTTP client.
- **`punch` P2P transport status** — upgraded from **Experimental** to **Beta** in the
  stability matrix.  The relay fallback for symmetric/double NAT is now end-to-end tested
  on Linux with all four built-in tunnel providers (serveo.net, localhost.run, ngrok, bore).
- **`punch` connection type notification** — when NAT hole-punching fails and the session
  falls back to the relay broker, the status notification now correctly reads
  connected (relay) instead of connected (P2P). The same correction applies to the
  disconnect notification (relay connection closed vs. P2P connection closed).
  Affected both the host side (per-peer notification) and the guest side. 

---

## [2.1.3] — 2026-04-22

### Fixed
- **`punch` signaling server bind address** — the host-side signaling server now
  binds to `127.0.0.1` instead of `0.0.0.0`.  Binding to `0.0.0.0` caused the
  relay fallback to fail silently: the host session was configured with relay URL
  `ws://0.0.0.0:PORT/relay`, which is not a valid connection target on most
  systems.  With `127.0.0.1` the host can connect to its own relay broker and
  the symmetric-NAT relay path works end-to-end.
  Requires [`punch`](https://luarocks.org/modules/azratul/punch) ≥ 0.3.2.
- **`punch` relay token mismatch** — the connector (guest) no longer generates its
  own relay token; it reads the host's token from the remote description instead.
  Previously both peers generated independent tokens and never matched at the relay
  broker, so relay fallback always failed in symmetric/double NAT scenarios.
  Requires [`punch`](https://luarocks.org/modules/azratul/punch) ≥ 0.3.2.
- **`punch` relay URL for HTTPS tunnels** — `https://` signaling URLs are now
  correctly converted to `wss://` for the relay WebSocket connection (previously
  only `http://` → `ws://` was handled, leaving HTTPS tunnel relay broken).

### Added
- **Improved `:checkhealth`** — health checks now report the configured transport mode
  (`ws` / `punch`), verify the correct tunnel-provider binary for the active `service`
  setting (`ssh`, `ngrok`, `bore`), check that the `punch` library is installed when
  `transport = "punch"`, warn when no username is configured, and provide
  platform-specific install hints for OpenSSL (Linux distros, macOS, Windows).
  Fixed Neovim version requirement in health check from 0.5 to 0.9 to match actual
  requirements.
- **LWW conflict model documentation** — `PROTOCOL.md` §3 now has three subsections:
  §3.1 describes last-write-wins semantics with a step-by-step concurrent-edit example;
  §3.2 documents practical implications for client implementors (safe vs. unsafe scenarios,
  latency effects, undo behavior); §3.3 lists known limitations. `README.md` gains a
  "Conflict model" quick-reference table linking to the full spec.
- **Networking edge-case tests** — two new integration test suites:
  - `tests/integration/edge_cases_spec.lua` (5 tests): synthesized `bye` on abrupt
    disconnect, `bye` broadcast to remaining peers (§7.3), `unauthorized` error for
    read-only guest patch (§5.4), `rejected` message delivery via `server.reject()`,
    and `broadcast(msg, except_peer)` exclusion guarantee.
  - `tests/integration/concurrent_spec.lua` (4 tests): three-peer broadcast, sequential
    message delivery order (5 patches in send order), and concurrent patches from two
    and three guests all reaching the server.

---

## [2.1.2] — 2026-04-21

### Changed
- **`punch` relay fallback** — when UDP hole-punching fails (symmetric NAT, double NAT),
  sessions now fall back automatically through a relay broker hosted on the same signaling
  server. Requires [`punch`](https://luarocks.org/modules/azratul/punch) ≥ 0.3.0.
  No configuration changes needed.

---

## [2.1.1] — 2026-04

### Fixed
- **ngrok TCP transport deadlock** — the client now sends a zero-length probe frame
  immediately on connect in raw TCP mode. Previously both sides waited for the other to
  write first, so ngrok TCP sessions never progressed past the initial connection.
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
