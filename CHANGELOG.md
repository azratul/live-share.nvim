# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Protocol
- **`protocol_version` bumped from 3 to 4 (stage 2 of the v4 migration).**
  v4 is staged on `develop` and will only ship to Nightly once stages 3–6
  also land. Plain v3 clients can no longer interop: the guest's
  version-mismatch handler now sends `bye` and disconnects instead of
  emitting a warning. Each subsequent stage will extend v4 in place
  (no further bumps); the open-pair (VS Code) port is deferred until all
  stages land and `develop` is merged to Nightly.

### Documentation
- **LuaCATS type annotations across the public modules** — `init.lua`
  (`LiveShare.Config`, `setup`, `get_config`), `session.lua` (shared-state
  class plus the `LiveShare.Message`/`PeerId`/`Role`/`Transport` aliases),
  `collab/connection.lua` (`Listener`/`Connector` classes and their methods),
  `collab/protocol.lua` (`Encryptor`/`Decryptor` plus `encode`/`decode`),
  `collab/crypto.lua` (encrypt/decrypt, X25519, HKDF, HMAC, fingerprint,
  base64url), and the role/engine modules `host.lua`, `guest.lua`,
  `collab/server.lua`, `collab/client.lua`, `workspace.lua`, `presence.lua`,
  `buffer_registry.lua`, and `follow.lua`. Comments only — no behavioural
  change; improves lua-ls completion/diagnostics and lowers the barrier to
  contribution.
- **Added `.luarc.json`** so lua-language-server picks up the LuaJIT runtime,
  the `vim` global (and busted test globals), and the Neovim/luv libraries on
  first clone — contributors get working completion and diagnostics without
  any manual setup. Formatting is left to StyLua (`format.enable: false`).
- **Expanded `CONTRIBUTING.md`** with a "where the code lives" orientation
  (role modules + `*/dispatch.lua`, the `collab/` engine, supporting modules),
  an lua-language-server note, and a single-suite test example; aligned the
  manual-test snippet with the current `:LiveShareHostStart` command.

### Internal
- **Split the host message dispatch out of `host.lua`** — the ~290-line
  `on_message` if/elseif chain moved verbatim into a new
  `live-share/host/dispatch.lua` keyed by message type, leaving `host.lua`
  focused on session lifecycle and buffer tracking (761 → 467 lines). Handlers
  receive an explicit `LiveShare.HostContext` (the live connection, the
  tracked-buffer table, and the seq/username accessors) instead of reaching
  into host-module locals. No behavioural or wire change.
- **Split the guest message dispatch out of `guest.lua`** — the ~390-line
  `on_message` (state gate + per-type handlers) moved into a new
  `live-share/guest/dispatch.lua`, leaving `guest.lua` focused on the
  connection lifecycle and cursor/focus autocmds (661 → 293 lines). The guest's
  mutable protocol state now lives on a shared `LiveShare.GuestState` table
  handed to handlers via `LiveShare.GuestContext`. No behavioural or wire change.
- **Extracted two self-contained helpers out of `collab/server.lua`** — the
  per-peer token-bucket rate limiter is now `collab/rate_limit.lua` (encapsulated
  bucket state behind `allow`/`forget`/`reset`), and the v4 forward-secrecy
  subkey derivation + per-peer codec construction is now `collab/subkey.lua`
  (`derive`/`make_codec`). No behavioural or wire change.
- **Split the per-connection state machine out of `collab/server.lua`
  (758 → 367 lines)** — transport auto-detection, the WebSocket upgrade, the v4
  DH handshake, and the framed read/decrypt/dispatch loop now live in
  `collab/peer_session.lua` (`start(deps)` runs once per accepted socket).
  server.lua retains the cross-peer concerns: the registry, approval, broadcast,
  and heartbeat. The two communicate through a `deps` table — the shared
  registry (`LiveShare.PeerRegistry`), the message callback, and `close_peer`/
  `send`. `M.stop` now clears the registry tables in place so the shared
  reference stays valid. No behavioural or wire change.
- **Added unit tests for the refactored code (+29 tests, 182 → 211)** — new
  suites `tests/host/` and `tests/guest/` drive the extracted dispatch modules
  through a fake `ctx` (recording connection) and cover the host handlers
  (patch seq stamping, sandbox/sensitive rejection, cursor/focus/bye broadcast
  identity, file_request success/missing/sensitive, hello_ack) and the guest
  state gate, workspace-chunk accumulation, patch seq-gap/stale handling, and
  hello version negotiation. `tests/rate_limit/` and `tests/subkey/` cover the
  two new `collab/` helpers (bucket cap/forget/reset; ECDH-subkey determinism,
  peer/PSK binding, and AEAD round-trip).
- **Added luacheck static analysis to CI** — a new `luacheck` job runs over
  `lua/`, `plugin/`, and `tests/`, with a `.luacheckrc` tuned for the plugin:
  `vim` as a writable global (so `vim.bo`/`vim.b` assignments aren't false
  positives), formatting deferred to StyLua, and the noisy stylistic checks
  (unused arguments, shadowing, intentional empty branches) disabled while the
  high-value ones (unused/dead locals, undefined globals) stay on. Fixed the
  genuine findings it surfaced: a stray `uv` require and write-only `role`
  state in `shared_terminal.lua`, an unused `_ws_key` return in
  `collab/client.lua`, and two dead stores in the integration tests. No
  behavioural or wire change.
- **Added a `Versioning checks` workflow (develop-only enforcement)** — runs on
  push/PR to `develop` and never publishes anything. It asserts the
  version-related invariants so the tree is always release-ready: the
  `PROTOCOL.md` title must carry a `-pre` spec version (dropping it belongs in
  the release PR to `main`), `protocol.lua`'s `M.VERSION` must match the
  "current version is" line in `PROTOCOL.md` §4, and a PR must add an entry
  under `[Unreleased]` in `CHANGELOG.md` (skippable with a `skip-changelog`
  label). Release automation itself remains a separate, main-only concern.

### Changed
- **Workspace listing is now streamed (stage 6 of v4 migration; extends v4 in place)**
  — replaces the single `workspace_info` message with a sequence of
  `workspace_info_chunk` messages of at most 1000 paths each, terminated
  by `workspace_info_done`.  This is the final stage of the v4 migration;
  develop is now ready to merge to Nightly.
  - **Wire** — two new message types added, one removed:
    - `workspace_info_chunk { seq, files[], root_name? }` — repeating.
      `seq` is 1-indexed and monotonic per session; `root_name` is sent
      only on the first chunk; `files` is a workspace-relative path
      array, may be empty.
    - `workspace_info_done { total_files, truncated }` — terminator.
      `total_files` lets the guest sanity-check that no chunks were lost;
      `truncated` propagates the host-side `scan_max_files` cap.
    - `workspace_info` is removed (it was v3); v4 hosts and guests do not
      emit or accept it.
  - **Why** — on a 50 k-file monorepo the old `workspace_info` was a
    single ~5 MB JSON message that blocked the guest's WORKSPACE_SYNC
    state for hundreds of milliseconds.  During that window
    `:LiveShareOpen` issued right after approval looked like it did
    nothing because `file_response` was buffered out, then dropped.
    Streaming in 1000-path chunks keeps each individual message small
    (well under MAX_MESSAGE_BYTES) and lets the guest render its file
    explorer progressively — `:LiveShareOpen` works as soon as a path
    appears, no need to wait for the whole listing.
  - **Order** — `workspace_info_chunk`* → `workspace_info_done` →
    `peers_snapshot` (if any) → `open_files_snapshot`.  Guest stays in
    WORKSPACE_SYNC until `open_files_snapshot`, but MAY render the file
    explorer as chunks arrive.  Even an empty workspace produces one
    empty chunk + done so the state machine has a deterministic stream.
  - **Backward compatibility** — none.  v3 guests will sit in
    workspace_sync until the 10 s watchdog fires.  This is intentional;
    v4 is a develop-branch wire format until the merge to Nightly.
  See `PROTOCOL.md` §5.1 (chunked message defs) and §8 (state-machine
  notes).  Tests: `tests/integration/stage6_spec.lua` (small + multi-chunk
  + empty + truncated workspaces over a real DH-encrypted TCP session).

### Security
- **Tamper-evident audit log (stage 5 of v4 migration; host-only, no wire change)**
  — every entry written to the host's audit log (`stdpath('state')/live-share-audit.log`
  by default) now carries `seq` (monotonic per-session counter), `prev_hash`
  (hex SHA-256 of the previous JSON line, verbatim), and an optional
  `payload_hash` (hex SHA-256 of the inbound encrypted envelope that
  triggered the event).
  - **Chain** — verifying a log is a single linear walk: for line N, the
    `prev_hash` field MUST equal `SHA-256(line N-1)`. The first line of
    a fresh file uses 64 zero hex characters as the genesis value; on
    a file that already has prior sessions, the new session's first
    record's `prev_hash` is set to the SHA-256 of the file's tail line,
    so deleting earlier sessions invalidates the chain head.
  - **Payload correlator** — when an inbound encrypted message is the
    direct cause of an audit entry (`peer_connect_request`, `peer_joined`,
    `file_request_allowed`, `file_request_denied`, `patch_rejected_sensitive`,
    `peer_disconnected`, `path_rejected`), the host stamps the payload's
    SHA-256 onto the record. Lets an investigator reconcile the audit
    trail with a packet capture without ever recording plaintext.
    Host-initiated events (`session_start`, `session_stop`, `peer_kicked`,
    `peer_approved`, `peer_denied`, `role_changed`, `terminal_opened`)
    omit `payload_hash` because they are not triggered by a wire message.
  - **No wire impact** — `protocol_version` stays at 4. v4 clients
    don't need to know about the audit format. The chain is purely a
    forensic property of the host-side log.
  - **Threat model** — detects offline tampering with the file (line
    edits, reorder, mid-file truncation). Does **not** prevent a live
    root attacker from rewriting the chain entirely; that is out of
    scope. `payload_hash` is **not** an authenticator (the GCM tag is) —
    it is purely a correlator.
  - **OpenSSL absent** — `audit.hash` returns `nil` and the chain
    degrades gracefully (records still written, but `prev_hash` stays
    at the prior value). Plaintext sessions already warn loudly; the
    chain breakage is an expected consequence of running without
    OpenSSL.
  See `PROTOCOL.md` §7.6 for the verification algorithm. Tests:
  `tests/audit/audit_spec.lua` (chain genesis, per-record SHA-256
  match, cross-session continuity, payload_hash pass-through, seq
  monotonicity).

- **Forward secrecy via X25519 ECDH (stage 4 of v4 migration; extends v4 in place)**
  — the URL-fragment master key (the PSK) no longer encrypts traffic
  directly.  Each peer pair runs an ephemeral X25519 handshake at session
  start; the AES-GCM subkey is derived from the DH shared secret via HKDF.
  - **Wire** — two new plaintext messages added: `dh_offer` (Host →
    Guest, immediately after TCP/WS detection) and `dh_accept` (Guest →
    Host, in reply).  Each carries a fresh ephemeral X25519 public key
    and an `HMAC-SHA256(PSK, pub)` tag.  An MITM rewriting the URL
    fragment (or a guest who decoded the wrong fragment) fails the
    HMAC check and is dropped before any application traffic.  The
    synthetic `connect` event in `host.lua` only fires *after* the
    handshake completes — host approval prompts always run against an
    authenticated channel.  See `PROTOCOL.md` §2.4 for the full
    description.
  - **Subkey** — `HKDF-SHA256(IKM = X25519(priv, peer_pub),
    salt = PSK, info = "ls-v4-subkey|" || peer_id_be4, L = 32)`.  Each
    peer in a multi-guest session has a unique subkey because of the
    peer_id binding in the HKDF info string; a kicked guest cannot
    decrypt other peers' broadcast traffic even if they recorded it.
    Server-side `M.broadcast` therefore re-encrypts per peer (was
    encrypt-once-frame-per-mode) — extra cost is negligible relative
    to the JSON encode itself.
  - **Crypto module** — `crypto.lua` gains `x25519_keypair`,
    `x25519_shared`, `hmac_sha256`, `hkdf_sha256`.  X25519 requires
    OpenSSL ≥ 1.1.1; `crypto.x25519_available` exposes the result of
    a one-time probe at module load.
  - **Fallback** — if OpenSSL is unavailable *or* lacks X25519,
    `host.lua` disables encryption entirely (plaintext session, with
    a clear warning).  Forward secrecy is now a defining property of
    a v4 encrypted session; we do not silently downgrade to master-key
    encryption, since a user upgrading to v4 expects forward secrecy.
  - **Backward compatibility** — none.  v3 clients did not run a DH
    handshake; on v4 they would hang waiting for `hello` while the
    host waits for `dh_accept`.
  Tests: `tests/integration/stage4_spec.lua` (X25519 ECDH symmetry,
  HMAC/HKDF determinism, per-peer subkey isolation, full DH session in
  TCP and WS modes, mis-authenticated dh_accept rejected before
  `connect`).

- **AEAD framing upgrade (stage 3 of v4 migration; extends v4 in place)**
  — replaces the v3 random 12-byte nonce with a deterministic counter nonce
  and binds each ciphertext to its sender via Additional Authenticated Data:
  - **Wire envelope** (same total length as v3): `[4-byte salt][8-byte
    counter BE][ciphertext][16-byte GCM tag]`.  Salt is generated per
    direction at session start; counter starts at 1 and increments per
    encode.  See `PROTOCOL.md` §2.3 for the full description.
  - **AAD** = `[8-byte counter BE][4-byte from_peer BE]`.  Receiver
    recomputes the AAD using the counter parsed from the nonce and the
    connection's authoritative peer_id; any swap of recipient or
    relabelling of sender fails GCM verification.
  - **Implementation** — `crypto.encrypt`/`crypto.decrypt` now accept an
    optional `aad` argument; `protocol.lua` exposes `new_encryptor(key,
    from_peer_fn)` and `new_decryptor(key)` for the v4 path.  `server.lua`
    and `client.lua` instantiate one of each at session start and route
    every send/recv through them.  The static `protocol.encode/decode`
    functions are kept as a v3-compatible plaintext fallback (used by
    tests and the punch transport, where channel-level encryption is
    provided by the `punch` library).
  - **Backward compatibility** — none.  v3 receivers fail GCM tag
    verification on a v4 payload (no AAD) and vice versa, on top of the
    strict version check from stage 2.
  Tests: `tests/integration/stage3_spec.lua` (deterministic nonce,
  round-trip, AAD-mismatch rejection, distinct salts per encryptor,
  plaintext mode, v3↔v4 envelope incompatibility).

- **Lifecycle hardening (stage 2 of v4 migration; introduces the v3→v4 bump)**
  — three host-side ceilings closed in one pass:
  - **Max frame size** — both `transport/tcp.lua` (length-prefix) and
    `websocket.lua` (binary frames) now enforce a 10 MB ceiling on the
    declared payload length.  Oversized frames are dropped before any
    allocation and the connection is closed.  Caller chooses the limit by
    passing it to `new_reader(max_bytes)`; `server.lua` and `client.lua`
    pass `MAX_MESSAGE_BYTES = 10 * 1024 * 1024`.
  - **Pending-peer timeout (90 s)** — a peer that connects but never
    receives `hello` (host has not approved or rejected) is force-closed
    by `server.lua` after the deadline.  Fixes a leak where a guest
    parking on the approval prompt could camp the slot indefinitely.
  - **Heartbeat ping/pong (15 s ping / 30 s idle kill)** — host sends
    `{t="ping", ts=...}` to every approved peer every 15 s; any peer with
    no inbound frame for 30 s is closed.  Guest auto-replies with `pong`
    inside `client.lua` (never bubbles to the application handler) and
    runs its own 30 s idle watchdog so a dead host disconnects the guest
    cleanly instead of hanging.
  - **Strict version check** — `guest.lua` now hard-disconnects on a
    `protocol_version` mismatch with a clear error message; previously
    only warned.
  Tests: `tests/integration/stage2_spec.lua` (oversized-frame rejection
  on both transports, heartbeat round-trip, idle disconnect, pending-peer
  timeout cancellation on approve).

- **Server-side defence-in-depth (stage 1 of v4 migration; no protocol bump)**
  — three host-side validations applied before any guest message reaches a
  handler:
  - **peer_id binding** — `server.lua` dispatch overwrites the `msg.peer`
    field of every wire message with the connection's authoritative peer_id.
    A malicious guest can no longer spoof cursor/focus/bye broadcasts as if
    they came from a different peer.
  - **Path validation on every message that carries a `path`** — `host.lua`
    pre-checks `msg.path` against `workspace.path_allowed()` (sandbox check
    + sensitive-file blocklist) for any incoming message; failures are
    audit-logged as `path_rejected{peer_id, msg_type, path}` and dropped.
    Closes the gap where a `cursor` or `focus` message with
    `path = "../../etc/passwd"` would be broadcast verbatim to other peers
    and pollute their presence/follow state.
  - **Per-peer rate limit on `patch` and `cursor`** — token bucket in
    `server.lua`, defaults 100 patches/s and 60 cursors/s per peer (1 s
    burst).  Excess messages are silently dropped; debug-logged.  Defends
    against a buggy or malicious guest saturating the host's main loop.
  Tests: `tests/integration/stage1_spec.lua` (9 tests covering peer_id
  binding, path_allowed semantics for traversal/absolute/NUL/sensitive/empty,
  burst dropping, and below-cap pass-through).

### Security (previous unreleased entries)
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
  `scan_max_files` (default 50000; set to 0 to disable the cap entirely),
  `scan_max_depth` (default 8), `scan_extra_ignore` (extra dir basenames).
  The `workspace_info` message shape is unchanged — fully
  backwards-compatible with `open-pair`.
- **`:LiveSharePeers` now shows peer IDs and roles** — every entry is prefixed
  with `#<id>` and tagged `[rw]` / `[ro]`, so the host knows which id to pass
  to `:LiveShareKick` / `:LiveShareReadonly`. Host gets a one-line hint at the
  bottom listing both commands. The host's own line is shown as `host (#0)`.
  The peer-joined notification on the host now reads
  `"<name> joined as peer #<id>"`.
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
- **Workspace scan default cap raised** from 10 000 to 50 000 files; when the
  cap is hit the host now gets a `vim.notify` warning telling them how many
  files were sent and how to raise/disable the cap. Set `scan_max_files = 0`
  to send the full tree (the prior unbounded behaviour).

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
