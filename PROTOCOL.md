# Live-Share.nvim Protocol Specification (v1.3.0-pre)

This document describes the communication protocol used by `live-share.nvim`. It is designed to allow developers to implement compatible plugins for other editors.

---

## Architecture overview

### `ws` transport (default)

```
  Host (Neovim)                  Tunnel / relay                   Guest (Neovim)
  ─────────────                  ──────────────                   ──────────────
       │                    TCP/WebSocket or raw TCP                   │
       │◄─────────────────────────────────────────────────────────────►│
       │              serveo · localhost.run · ngrok · bore            │
       │                                                               │
       │◄══════════════ AES-256-GCM (key never reaches relay) ════════►│

  Session key: URL fragment only — https://…#key=<base64url>
  The relay sees opaque ciphertext and cannot read or modify content.
```

### `punch` transport (P2P UDP)

```
  Host (Neovim)          Tunnel (signaling only ~5 s)          Guest (Neovim)
  ─────────────          ────────────────────────────          ──────────────
       │──── STUN ──────►  HTTP signaling server  ◄──── STUN ────────│
       │                   (any tunnel provider)                     │
       │◄═════════════════ direct AES-256-GCM UDP ══════════════════►│
                             (relay not involved)
```

After the signaling phase the tunnel is no longer in the data path. Both peers communicate directly over an encrypted UDP channel using the same session key.

### Encryption boundary

The session key is a 32-byte random value encoded as `base64url` in the URL fragment (`#key=…`). URL fragments are never sent in HTTP requests, so the key never reaches the tunnel server. Every message payload is wrapped as `[12-byte nonce][AES-256-GCM ciphertext+tag]` (§2.2). The relay sees only opaque byte streams.

---

## 1. Transport Layer

The protocol supports three transport modes. For WS and TCP the server auto-detects the mode from the first 4 bytes of the connection. For Punch the transport is indicated by the `punch+` URL prefix and uses a separate signaling flow.

### 1.1 WebSocket (WS)
Used for HTTP tunneling services (e.g., `serveo.net`, `localhost.run`).
- Messages are sent as **Binary Frames**.
- The server expects standard WebSocket handshakes on the initial connection.

### 1.2 Raw TCP
Used for direct connections or `ngrok` (TCP mode).
- **Framing:** Each message is prefixed with a **4-byte Little Endian unsigned integer** representing the length of the payload.
- Example: A 10-byte payload is prefixed with `0A 00 00 00`.

### 1.3 Punch (P2P UDP)

Used when `transport = "punch"` is configured. The tunnel is used only during the short signaling phase (~5 s); all collaborative traffic then flows over a **direct encrypted UDP channel** between host and guest, bypassing the tunnel server entirely.

**Dependency:** requires the [`punch`](https://luarocks.org/modules/azratul/punch) LuaRocks package on both sides.

**Compatibility:** the signaling client supports both `http://` and `https://` URLs (TLS is handled natively by the `punch` library). ngrok in TCP mode (`tcp://`) and HTTPS mode (`https://`) have both been confirmed to work. Compatibility with SSH-based tunnels (`localhost.run`, `serveo`) is untested.

#### 1.3.1 URL Format

The shared URL has a `punch+` scheme prefix:

```
punch+<signaling-server-url>#key=<base64url>
```

Examples:
```
punch+http://0.tcp.ngrok.io:12345#key=<base64url>
punch+tcp://0.tcp.ngrok.io:12345#key=<base64url>   ← tcp:// is normalized to http://
```

Guests strip the `punch+` prefix, normalize `tcp://` to `http://`, and treat the remainder as the signaling server URL.

#### 1.3.2 Signaling Flow

The host runs a lightweight HTTP signaling server (port chosen by the OS; exposed via the tunnel). The handshake proceeds as follows:

1. **Host** gathers local ICE candidates (local + STUN-reflexive via `stun.l.google.com:19302` by default) and publishes a *host description* to the signaling server.
2. **Guest** sends `GET /` to the signaling server (long-poll, up to 30 s) to fetch the host description and a `slot` identifier.
3. **Guest** concurrently gathers its own local candidates.
4. **Guest** sends `POST /guest/<slot>` with its own description.
5. **Host** receives the guest description; both peers attempt UDP hole-punching by sending keepalive probes to all candidate pairs.
6. Once the UDP channel reaches state `open`, collaborative traffic begins using the same message types as WS/TCP (§5).

The signaling server accepts only one pending guest at a time. While guest N is connecting, the host immediately prepares a new session slot for guest N+1 (star topology — each guest has an independent UDP socket).

#### 1.3.2.1 Signaling HTTP API

All requests and responses use JSON bodies (`Content-Type: application/json`).

**`GET /`** — Fetch the host description (long-poll).

The server holds the connection open until the host description is available, then responds:
```json
{ "slot": 1, "desc": { "candidates": ["192.168.1.10:54321", "1.2.3.4:54321"], "key": "<base64>" } }
```

- `slot` — integer identifier for this guest session; must be included in the subsequent POST.
- `desc.candidates` — array of `"ip:port"` strings (local and STUN-reflexive UDP endpoints).
- `desc.key` — base64-encoded ephemeral Diffie-Hellman public key material used by the punch library to authenticate the channel. Implementors using the `punch` library can treat this as opaque.

If the host description is not published within the long-poll timeout, the server returns `408 Request Timeout`. The guest should surface a connection error and not retry automatically.

**`POST /guest/<slot>`** — Post the guest description.

Request body uses the same structure as the host description:
```json
{ "candidates": ["10.0.0.5:60000", "5.6.7.8:60000"], "key": "<base64>" }
```

On success the server returns `200 OK` with an empty body. If `<slot>` does not match an active pending session the server returns `404 Not Found`; the guest should abort.

#### 1.3.2.2 Hole-Punching and Failure

After descriptions are exchanged, both peers simultaneously probe all candidate pairs. The pair that receives a valid response first becomes the active path; remaining probes are abandoned.

**Failure cases:**
- If no candidate pair succeeds within ~10 s, both peers should report a connection error to the user. There is no automatic fallback to WS/TCP; the user must reshare the URL.
- If the STUN server is unreachable, only local-network candidates are gathered. The connection will still work on the same LAN but will fail across NATs.
- Symmetric NAT (common on CGNAT and some corporate networks) may prevent hole-punching. The `punch` library does not support TURN relay; direct connectivity is required.

#### 1.3.3 Encryption

The session key from `#key=<base64url>` is passed directly to `punch.session.new()` for **channel-level AES-256-GCM** encryption. Protocol payloads are therefore **plain JSON** (no nonce/ciphertext wrapper — that layer is handled by punch itself).

Implementors not using the `punch` library must apply AES-256-GCM encryption at the UDP frame level with the same `[12-byte nonce][ciphertext+tag]` structure described in §2.2, using the decoded `#key` as the symmetric key.

#### 1.3.4 Framing

Each UDP datagram carries exactly one protocol message (after decryption). There is no length-prefix — the datagram boundary is the message boundary.

---

## 2. Security Layer (E2E Encryption)

The protocol uses **AES-256-GCM** for end-to-end encryption. The encryption key is shared via the URL fragment (`#key=...`) and never reaches the tunnel server.

### 2.1 Key Derivation
- The key is a 32-byte (256-bit) random string, Base64Url encoded in the connection URL.
- Clients must decode the Base64Url string to get the raw 32-byte key.

### 2.2 Payload Structure (v3)

If a key is present, the binary payload (after the TCP length prefix or inside the WS frame) is structured as follows:

1.  **Nonce (IV):** 12 random bytes.
2.  **Ciphertext:** The AES-encrypted JSON string.
3.  **Authentication Tag:** 16 bytes (appended to the ciphertext).

*Note: If no key is provided, the payload is simply the UTF-8 encoded JSON string.*

### 2.3 Payload Structure (v4)

v4 keeps the same total envelope size but replaces the random nonce with a deterministic counter and binds each ciphertext to its sender via Additional Authenticated Data (AAD).

```
[ 4-byte salt ][ 8-byte counter (BE) ][ ciphertext ][ 16-byte GCM tag ]
└──────── 12-byte AES-GCM nonce ────────┘
```

- **salt** — 4 random bytes generated per *direction* when the encryptor is constructed and reused for the lifetime of the session. Two encryptors built from the same key (e.g., the host and a guest) emit different salts, so their nonce streams cannot collide.
- **counter** — 8-byte big-endian unsigned integer, starts at 1 on the first outbound message and increments by 1 per encode. Combined with the salt this guarantees nonce uniqueness without relying on the birthday bound of a 12-byte random nonce.
- **AAD** (bound into the GCM tag, not transmitted in the clear): `[ 8-byte counter (BE) ][ 4-byte from_peer (BE) ]`. The receiver recomputes the AAD from (a) the counter parsed from the wire nonce and (b) the connection's authoritative peer_id (host = 0 from the guest's perspective; the connection's peer_id from the host's perspective). Any swap of recipient or relabelling of sender fails GCM verification.

The wire format is incompatible with v3 at the cryptographic layer: a v3 receiver would treat the payload as a random-nonce envelope and fail the GCM tag because of the missing AAD. This is what backs the strict version check in v4 — peers running mismatched majors cannot interop even if the handshake fields are syntactically compatible.

**Punch transport exception.** When `transport = "punch"` is in use, channel-level AES-GCM is provided by the `punch` library and the §2.3 envelope is *not* applied. Payloads on the wire are plain JSON. See §1.3.3.

### 2.4 Forward-Secrecy Handshake (v4)

The URL-fragment key is no longer used to encrypt traffic directly. It acts as a Pre-Shared Key (PSK) that authenticates a fresh ephemeral Diffie–Hellman exchange run at the start of every connection. The actual AEAD subkey is derived from the DH shared secret, so a future compromise of the URL fragment cannot decrypt recorded ciphertext.

#### 2.4.1 Wire flow

1. After TCP/WS detection, before any other traffic, the **host** sends `dh_offer` (plaintext JSON in a normal framed payload):
   ```json
   {
     "t": "dh_offer",
     "peer_id": 3,
     "pub":  "<base64url 32-byte X25519 public key>",
     "hmac": "<base64url 32-byte HMAC-SHA256(PSK, pub)>"
   }
   ```
2. The **guest** verifies the HMAC against its copy of the PSK (a mismatch ⇒ disconnect — either the URL was rewritten in transit or the guest decoded the fragment wrong). It generates its own ephemeral X25519 keypair and replies with `dh_accept`:
   ```json
   { "t": "dh_accept", "pub": "<…>", "hmac": "<…>" }
   ```
3. The **host** verifies the guest's HMAC the same way. Both sides compute the X25519 shared secret. From this point all traffic uses the §2.3 AEAD envelope with the per-peer subkey derived below.
4. The synthetic `connect` event (host-side approval prompt) only fires after this exchange completes — `host.lua` never sees an unauthenticated peer.

#### 2.4.2 Subkey derivation (HKDF-SHA256, RFC 5869)

```
PRK    = HMAC-SHA256(salt = PSK, IKM = X25519(my_priv, peer_pub))
subkey = HKDF-Expand(PRK, info = "ls-v4-subkey|" || peer_id_be4, L = 32 bytes)
```

- `peer_id_be4` is the host-assigned peer_id encoded as a 4-byte big-endian integer.
- Both sides feed identical inputs (PSK, shared, peer_id) and arrive at the same 32-byte subkey without ever transmitting it.
- Different peers in the same session derive **different** subkeys because `peer_id_be4` differs. A kicked guest cannot decrypt traffic destined for any other peer, even if they recorded it.

#### 2.4.3 OpenSSL availability

X25519 requires OpenSSL ≥ 1.1.1 (released 2018). If the runtime can load `libcrypto` but lacks X25519 (`crypto.x25519_available == false`), the host disables encryption entirely and prints a warning rather than silently downgrading to master-key encryption. Stage 4 adds forward secrecy as a defining v4 property; users on older OpenSSL must either upgrade or accept a plaintext session.

#### 2.4.4 Plaintext sessions

If no PSK is present (the share URL omits `#key=`, or OpenSSL is unavailable), neither side runs the §2.4 handshake. The connection skips straight from TCP/WS detection to the synthetic `connect` event and all traffic is JSON in the clear. This is unchanged from earlier protocol versions.

---

## 3. Synchronization Strategy

The protocol follows a **Central Authority (Host)** model. It does not use CRDTs.

- **Authority:** The Host is the source of truth. It assigns a monotonic `seq` (sequence number) to every `patch` message.
- **Line-based Patching:** Edits are synchronized as line-range replacements.
- **Virtual Filesystem:** Guests should treat remote files as virtual resources (e.g., `liveshare://<session_id>/<path>`) and should not save them to the local physical disk.

### 3.1 Last-Write-Wins Semantics

"Last-write-wins" means the host applies incoming patches in the order they arrive and broadcasts each one with an authoritative `seq`. There is no attempt to merge concurrent edits: if two guests modify the same line at the same time, one edit wins (whichever reached the host first) and the other is overwritten.

Resolution flow for concurrent edits to the same line:

1. Guest A and Guest B both edit line 10 simultaneously and send their patches (each without a `seq` — guests never assign seq).
2. The host receives Guest A's patch first, applies it, stamps it `seq: N`, and broadcasts it to all peers including Guest B.
3. The host then receives Guest B's patch, applies it (overwriting Guest A's result), stamps it `seq: N+1`, and broadcasts it.
4. Guest A receives `seq: N+1` and applies it, overwriting their own last edit. Guest A's change is lost.
5. The final state reflects Guest B's edit on top of Guest A's, as seen by every peer.

**Convergence guarantee:** after all broadcasts are applied, every peer (including the host) holds identical buffer contents. There are no permanent divergences.

### 3.2 Practical Implications for Implementors

- **Non-overlapping edits are safe.** Patches are line-range replacements, so edits to different lines never interfere.
- **Concurrent edits to the same line are unreliable.** One participant's change will be silently overwritten. The loser sees their change disappear when the next broadcast arrives.
- **Latency widens the conflict window.** At ~200 ms one-way latency, the probability of a same-line collision increases significantly. Clients should not infer correctness from locally-optimistic state; the host's broadcast is the only authoritative version.
- **The host's local edits race the same way.** If the host edits line 10 at the same instant a guest patch for line 10 arrives, the host applies whichever internal operation runs first. The resulting `seq`-stamped broadcast is authoritative regardless of the source.
- **Read-only guests (`role: ro`) cannot cause conflicts.** Their patches are rejected at the server before reaching the host; they only observe the authoritative stream.
- **Undo stacks are not coordinated.** Each peer has an independent undo history. Undoing a local change after a remote patch has been applied may produce unexpected results and is not recoverable.

### 3.3 Known Limitations

- **No operational transform or CRDT.** Concurrent same-line edits are resolved by TCP arrival order at the host, not by semantic intent. This is a deliberate trade-off: the expected collaboration pattern is one active author with observers, or light turn-based editing — not simultaneous heavy editing of the same lines.
- **No undo coordination across peers.** See §3.2.
- **No offline edit queuing.** Edits made during a transient disconnect are not buffered. On rejoin the guest receives a fresh snapshot; offline changes are discarded.
- **Large-block vs. small-edit races.** If guest A replaces a large block while guest B makes small edits within that block, the small edits may be dropped when the block replacement wins and is broadcast. The guest will resync via `file_request` if the resulting `lnum` goes out of range, but intermediate edits between the race and the resync are not recoverable.

---

## 4. Protocol Versioning

> **Note:** `protocol_version` (the integer in `hello`) is the **wire compatibility version** — the only value implementors need to care about. The `v1.2.0` in this document's title is the spec document version and is independent; it tracks editorial changes (clarifications, new sections) that do not affect the wire format.

The `hello` message carries a `protocol_version` integer field. From v4 onward clients **must** disconnect on a version mismatch (earlier versions only required a warning). The current version is **4**.

> **v4 status:** v4 is being staged on the `develop` branch and will only ship to Nightly once all migration steps land. Implementations targeting the released `main` branch should still treat v3 as the stable wire format. The full migration plan and per-stage notes live in `CHANGELOG.md` under the `[Unreleased]` section.

| Version | Change summary |
| :--- | :--- |
| 1 | Initial versioned release. Introduces this field. |
| 2 | Adds `caps` to `hello` / `hello_ack`; adds `error` message type; formalises `file_request` / `file_response` resync flow. |
| 3 | Replaces flat `caps` with `required_caps` / `optional_caps`; adds `req_id` to `file_request` / `file_response` / `error`. |
| 4 *(unreleased)* | Strict version check; max-frame size (10 MB); pending-peer timeout (90 s); ping/pong heartbeat (15 s ping / 30 s idle kill); AEAD framing with deterministic counter nonce + AAD binding sender peer_id (§2.3); X25519 forward-secrecy handshake (`dh_offer`/`dh_accept`) with HKDF-derived per-peer subkeys (§2.4); tamper-evident host-side audit log with per-record SHA-256 chain and optional `payload_hash` correlator (§7.6, no wire change); workspace listing streamed as `workspace_info_chunk` + `workspace_info_done` instead of a single `workspace_info` (§5.1). All six staging steps complete; ready for merge from `develop` to Nightly. |

---

## 5. Message Types (JSON Schema)

Every message is a JSON object with a type field `t`.

### 5.1 Connection Handshake

| Type (`t`) | Sender | Description |
| :--- | :--- | :--- |
| `dh_offer` | Host | *(v4, encrypted sessions only.)* Plaintext-framed. Host's ephemeral X25519 public key + PSK-HMAC. See §2.4. |
| `dh_accept` | Guest | *(v4, encrypted sessions only.)* Plaintext-framed. Guest's ephemeral X25519 public key + PSK-HMAC. |
| `connect` | Guest | Initial request to join. |
| `hello` | Host | Response after approval. Contains `protocol_version`, `peer_id`, `role` (`rw`/`ro`), `host_name`, `required_caps`, and `optional_caps`. |
| `rejected` | Host | Sent instead of `hello` when the connection is denied. |
| `workspace_info_chunk` | Host | *(v4.)* Sent after `hello`, repeated. Chunk of the workspace file list (≤ 1000 paths each). The first chunk (`seq=1`) carries `root_name`; subsequent chunks carry only `seq` and `files`. |
| `workspace_info_done` | Host | *(v4.)* Terminator for the `workspace_info_chunk` stream. Carries `total_files` and `truncated`. |
| `peers_snapshot` | Host | Sent after `workspace_info_done` if other guests are already connected. |
| `open_files_snapshot` | Host | Sent after `workspace_info_done`. Full content of all currently open files. |
| `hello_ack` | Guest | Final handshake step. Guest sends their `name` and `caps`. |

#### `connect` (Guest → Host)
```json
{ "t": "connect" }
```

#### `hello` (Host → Guest)
```json
{
  "t": "hello",
  "protocol_version": 4,
  "peer_id": 1,
  "sid": "a1b2c3d4",
  "role": "rw",
  "host_name": "alice",
  "required_caps": ["workspace"],
  "optional_caps": ["terminal", "cursor", "follow"]
}
```

`required_caps` lists features the client **must** support to participate. If the client does not support one or more of them, it must disconnect immediately with a clear error. `optional_caps` lists features the client may skip — the session will still work without them.

Defined capability tokens:

| Token | Required / Optional | Meaning |
| :--- | :--- | :--- |
| `workspace` | Required | Multi-buffer workspace: file list, `open_file` / `close_file` notifications |
| `terminal` | Optional | Shared PTY terminal (`terminal_open` / `terminal_data` / `terminal_close`) |
| `cursor` | Optional | Cursor and visual-selection sync (`cursor` messages) |
| `follow` | Optional | Follow-mode: host broadcasts `focus` events |

#### `workspace_info_chunk` (Host → Guest, repeating) *(v4)*
```json
{
  "t": "workspace_info_chunk",
  "seq": 1,
  "root_name": "my-project",
  "files": ["src/main.lua", "README.md", "lua/plugin/init.lua"]
}
```

The host streams the workspace file list as one or more `workspace_info_chunk` messages of at most ~1000 paths each, terminated by `workspace_info_done` (below).

- `seq` (integer, 1-indexed) — monotonic chunk counter for this session. The host sends chunks in order; guests SHOULD nevertheless tolerate out-of-order reception (e.g. on a transport that interleaves) and rely on `total_files` from the terminator for completeness.
- `root_name` (string) — present **only** on the chunk with `seq = 1`. Subsequent chunks carry `seq` and `files` only.
- `files` (array of strings) — workspace-relative paths in this chunk; may be empty (the host always sends at least one chunk + a terminator, even for an empty workspace, so the guest's WORKSPACE_SYNC state machine has a deterministic stream to walk).

Guests SHOULD render their file explorer progressively as chunks arrive — `:LiveShareOpen` for any path already received works without waiting for `workspace_info_done`.

#### `workspace_info_done` (Host → Guest, once) *(v4)*
```json
{
  "t": "workspace_info_done",
  "total_files": 4231,
  "truncated": false
}
```

- `total_files` (integer) — total number of paths the host sent across all `workspace_info_chunk` messages. Guests SHOULD verify this matches the number of paths they accumulated and warn the user on mismatch.
- `truncated` (boolean) — `true` if the host's scan hit `scan_max_files` and the listing is incomplete. Guests SHOULD surface this to the user.

#### `hello_ack` (Guest → Host)
```json
{ "t": "hello_ack", "name": "bob", "caps": ["workspace", "terminal", "cursor", "follow"] }
```

The `caps` array lists all capability tokens the guest client supports. Hosts **may** use this to suppress messages the guest cannot handle (e.g. skip `terminal_open` if `"terminal"` is absent).

#### `rejected` (Host → Guest)
Sent instead of `hello` when the host denies the connection.
```json
{ "t": "rejected", "reason": "Host denied the connection" }
```
The client must treat this as terminal — no reconnect should be attempted.

#### `peers_snapshot` (Host → Guest)
Sent after `hello` if other guests are already connected. Allows the new guest to populate its presence state immediately.
```json
{
  "t": "peers_snapshot",
  "peers": [
    { "peer_id": 2, "name": "gojo", "active_path": "src/main.lua" }
  ]
}
```

#### `open_files_snapshot` (Host → Guest)
Sent after `workspace_info`. Contains the full content of every file the host currently has open in the editor. Clients should create virtual buffers for each entry.
```json
{
  "t": "open_files_snapshot",
  "files": [
    { "path": "src/main.lua", "lines": ["line 1", "line 2"] }
  ]
}
```

### 5.2 Content Synchronization

#### `patch` (Host ↔ Guest)
Sent when a buffer is modified.
```json
{
  "t": "patch",
  "path": "src/main.lua",
  "seq": 105,
  "lnum": 10,        // 0-indexed start line
  "count": 2,       // Number of lines replaced (-1 for full buffer replace)
  "lines": ["new line 1", "new line 2"],
  "peer": 0         // ID of the peer who originated the edit
}
```

#### `cursor` (Host ↔ Guest)
Broadcasts cursor position and visual selection.
```json
{
  "t": "cursor",
  "path": "src/main.lua",
  "lnum": 15,
  "col": 4,
  "name": "Alice",
  "sel_lnum": 10,      // Optional: Visual selection start line
  "sel_col": 0,       // Optional: Visual selection start col
  "sel_end_lnum": 15, // Optional: Visual selection end line
  "sel_end_col": 4    // Optional: Visual selection end col
}
```

#### `focus` (Host ↔ Guest)
Indicates which file a user is currently viewing.
```json
{ "t": "focus", "path": "src/main.lua", "peer": 1, "name": "Bob" }
```

#### `open_file` (Host → Guest)
The host opened a new file during an active session.
```json
{ "t": "open_file", "path": "src/new.lua", "lines": ["line 1", "line 2"] }
```

#### `close_file` (Host → Guest)
The host closed a file during an active session. Clients should clean up the corresponding virtual buffer.
```json
{ "t": "close_file", "path": "src/old.lua" }
```

#### `save_file` (Host → Guest)
The host saved a file to disk. Informational only — no buffer update is required.
```json
{ "t": "save_file", "path": "src/main.lua" }
```

#### `bye` (both directions)
Signals an intentional disconnect. Guests send it before closing; the host broadcasts it when a guest disconnects so other peers can clean up their presence state.
```json
{ "t": "bye", "peer": 2, "name": "gojo" }
```

### 5.3 File Request / Resync

Guests may request a full snapshot of any workspace file at any time — on initial open, after a detected desync, or when joining late.

#### `file_request` (Guest → Host)
```json
{ "t": "file_request", "path": "src/main.lua", "req_id": 1 }
```

`req_id` is an optional integer chosen by the client. When present, the host echoes it back in the corresponding `file_response` or `error`, allowing clients to correlate concurrent or retried requests.

#### `file_response` (Host → Guest)
```json
{
  "t": "file_response",
  "path": "src/main.lua",
  "lines": ["line 1", "line 2"],
  "readonly": false,
  "req_id": 1
}
```

If the file does not exist in the workspace the host replies with an `error` message (`code: "file_not_found"`, same `req_id`) instead.

**Recommended resync flow:** if a guest detects an inconsistent document state (e.g. a patch references a line beyond the current buffer length), it should send `file_request` for the affected path. The host will reply with the authoritative full snapshot, which the guest applies unconditionally to reset state.

### 5.4 Errors

#### `error` (Host → Guest)
Sent when the host rejects or cannot fulfil a request.
```json
{ "t": "error", "code": "file_not_found", "message": "file not found in workspace: src/foo.lua", "req_id": 1 }
```

`req_id` is echoed from the originating request when present.

Defined error codes:

| Code | Trigger |
| :--- | :--- |
| `unauthorized` | A read-only guest sent a `patch` message |
| `file_not_found` | A `file_request` path does not exist in the workspace |

Clients **must** display the `message` field to the user and **should not** treat unknown codes as fatal.

### 5.5 Heartbeat (v4+)

Both ends keep the transport warm with an application-level ping/pong exchange. The host pings every approved peer every 15 s and closes the connection if no inbound traffic arrives for 30 s. Guests respond to every `ping` with a matching `pong` echoing the host's `ts`. Either side **may** send a `ping` at any time; the receiver **must** answer with a `pong`. Any received frame counts as keepalive evidence regardless of `t`, so a busy session never trips the idle threshold.

Heartbeat traffic is invisible above the transport layer — implementors should handle `ping`/`pong` inside the framing/transport module and not surface them to the application.

#### `ping` (Host → Guest, optional Guest → Host)
```json
{ "t": "ping", "ts": 173400000 }
```
`ts` is an arbitrary monotonic timestamp (milliseconds). It has no semantic meaning for the receiver beyond echoing it back.

#### `pong` (Guest → Host, optional Host → Guest)
```json
{ "t": "pong", "ts": 173400000 }
```
The `ts` field **must** be the same value received in the corresponding `ping`.

### 5.6 Shared Terminal

#### `terminal_open` (Host → Guest)
Notifies guests that a shared terminal session has started.
```json
{ "t": "terminal_open", "term_id": "main", "name": "bash" }
```

#### `terminal_data` (Host → Guest)
Raw PTY output from the host.
```json
{ "t": "terminal_data", "term_id": "main", "data": "SGVsbG8gV29ybGQh..." } // Base64 encoded
```

#### `terminal_close` (Host → Guest)
Notifies guests that the shared terminal has ended.
```json
{ "t": "terminal_close", "term_id": "main" }
```

#### `terminal_input` (Guest → Host)
User keystrokes to be sent to the host's PTY.
```json
{ "t": "terminal_input", "term_id": "main", "data": "\u0003" } // Raw string (e.g. Ctrl+C)
```

---

## 6. Implementation Notes for Clients

1.  **Read-only Mode:** If `role` is `ro` in the `hello` message, the client must disable all local editing and only apply incoming patches.
2.  **Path Mapping:** All paths in the protocol are relative to the workspace root.
3.  **Syntax Highlighting:** Clients should infer the language from the file extension in the `path` field.
4.  **Debouncing:** Cursor movements should be debounced (e.g., 100ms) to avoid flooding the network.
5.  **Transport detection from the URL:**
    - URL starts with `punch+` → Punch transport (§1.3). Strip the prefix and use the remainder as the signaling server URL.
    - URL starts with `tcp://` → Raw TCP transport (§1.2).
    - URL starts with `http://` or `https://` → WebSocket transport (§1.1).
    - Bare `host:port` (no scheme) → WebSocket transport (§1.1).
6.  **Punch — signaling timeout:** `fetch_host` should long-poll for at least 30 s to handle slow tunnel startup. If the host description is not available after the timeout, surface a connection error to the user without retrying automatically.
7.  **Punch — encryption:** Do not apply the §2.2 nonce/ciphertext wrapping when using the Punch transport. Encryption is handled at the channel level by the punch library. Payload bytes are raw JSON.

---

## 7. Edge Cases and Normative Behavior

### 7.1 Concurrent Patches and `seq` Ordering

The host is the sole authority for `seq` assignment. When two guests submit patches concurrently:

1. The host receives both patches in some order (TCP/WS) or by arrival order (UDP).
2. The host applies the first patch to its buffer, stamps it with the next `seq`, and broadcasts it to all peers **including the originating guest**.
3. The host then applies the second patch (which may now reference stale line numbers), stamps it with `seq+1`, and broadcasts it.
4. Guests **must** apply patches in `seq` order. A patch with `seq` N+1 arriving before N should be buffered until N is applied, then N+1 applied immediately after.
5. Guests **must not** assume their own patch was applied as submitted. They must wait for the host's broadcast (which carries the authoritative `seq`) before updating their local state.

If a guest detects a gap in `seq` (e.g., receives seq 5 then 7 without 6), it should issue a `file_request` for the affected path to force a full resync.

### 7.2 Out-of-Range Patch

If a `patch` references a `lnum` beyond the current buffer length (indicating a missed update or desync), the guest **must not** apply the patch. Instead it must immediately send `file_request` for the affected path. The host will reply with the authoritative full snapshot, which the guest applies unconditionally to reset state.

### 7.3 Abrupt Disconnect (No `bye`)

When a TCP/WS connection closes without a `bye` message (e.g., network drop, process kill):

- The **host** detects the closed socket, removes the peer from its registry, and broadcasts `{ "t": "bye", "peer": <id>, "name": "<name>" }` to all remaining guests on their behalf.
- **Guests** detecting a broken connection (read error, EOF) should treat it as equivalent to receiving `bye` from the host and clean up all presence state (cursors, extmarks).
- In Punch transport, the `close` event on the UDP session serves as the disconnect signal; the host synthesizes and broadcasts `bye` identically.

After an abrupt disconnect the guest **should not** attempt automatic reconnection. The session URL is single-use; the user must rejoin manually.

### 7.4 Capability Negotiation Edge Cases

**Missing required cap:** If `hello.required_caps` contains a token the guest does not implement, the guest **must** send `bye` immediately (before `hello_ack`) and display an error such as:
```
live-share: this session requires capability "workspace" which is not supported by this client.
```
No collaborative traffic should be exchanged.

**Missing optional cap:** The session continues normally. The host **should** suppress messages for that capability (e.g., omit `terminal_open` if `"terminal"` is absent from `hello_ack.caps`). The guest **may** silently ignore messages for capabilities it did not advertise.

**Unknown cap token:** Clients encountering an unrecognised token in `required_caps` must treat it as unsupported (disconnect). An unrecognised token in `optional_caps` or in `hello_ack.caps` must be silently ignored — forward compatibility requires ignoring unknown optional tokens.

### 7.5 Lifecycle Limits (v4+)

The following ceilings are enforced at the transport layer. Frames violating them are dropped before any allocation, and the connection is closed.

| Limit | Value | Behaviour on violation |
| :--- | :--- | :--- |
| Max bytes per frame | 10 × 1024 × 1024 (10 MB) | Connection closed immediately. No `error` is sent — by the time the limit fires the framer cannot trust the stream. |
| Pending-peer timeout | 90 s | A peer that connects but never receives `hello` (host has not approved or rejected) is force-closed. |
| Ping interval | 15 s | Sent automatically by the host to every approved peer. |
| Idle-kill threshold | 30 s | A peer with no inbound frames for this long is closed (≈ two missed pings). |

Clients **must not** assume any specific ceiling; the values above are the host-side defaults. New connections that disconnect immediately and consistently should be debugged by checking message size first.

### 7.6 Audit Log Forensics (v4+, host-only, no wire impact)

The host writes an append-only JSONL audit log (`stdpath('state')/live-share-audit.log` by default; disable with `audit_log = false` or override the path in `setup({ audit_log = "/path" })`). This section is purely informational for tooling that wants to verify a log; the file format is host-private and never crosses the wire.

Each record carries the following fields in addition to event-specific data:

| Field | Type | Purpose |
| :--- | :--- | :--- |
| `ts` | string (ISO-8601 UTC) | Wall-clock timestamp when the record was written. |
| `seq` | integer | Monotonic counter, starts at 1 on each session and increments per record. |
| `event` | string | Short event name (`session_start`, `peer_joined`, `file_request_allowed`, …). |
| `sid` | string | Session ID set by the host on `session_start`. |
| `prev_hash` | hex string (64) | SHA-256 of the previous JSON line (verbatim, **no trailing newline**). The very first record ever written to a fresh file uses 64 zero hex characters as the genesis value. |
| `payload_hash` | hex string (64), optional | Present on records triggered by an inbound encrypted protocol message. Equal to SHA-256 over the full `[salt][counter][ciphertext+tag]` envelope (i.e. the bytes the transport reader handed to `protocol.decode`). Lets an investigator correlate the audit trail with a packet capture without ever recording plaintext. |

**Verification algorithm:**

1. Read the file line by line, preserving each line verbatim (no whitespace normalisation).
2. For line N > 1, recompute SHA-256 of line N−1 and compare against line N's `prev_hash`. Any mismatch ⇒ the log was tampered with at or before line N.
3. The first line's `prev_hash` MUST be either 64 zero hex characters (genesis) or SHA-256 of a previously truncated tail. The chain is continuous across host restarts on the same file: a new session's first record's `prev_hash` is the hash of the prior session's last line, so deleting earlier sessions invalidates the new session's chain head.
4. `seq` resets to 1 at every `session_start`; gaps within a session indicate dropped writes (the file open is non-blocking and silently no-ops on I/O errors).

**Threat model:** the chain detects offline edits to the log file (replacing a line, reordering, truncating mid-file). It does **not** prevent an attacker who has live root on the host from rewriting the chain entirely — that is out of scope. `payload_hash` does not authenticate the wire (the GCM tag does that); it exists so that a recorded `peer_joined` / `file_request_*` entry can be tied back to a specific encrypted frame on the wire.

---

## 8. Client State Transitions

A guest client moves through the following states after initiating a connection. Implementing these transitions explicitly reduces the chance of acting on messages that arrive out of order.

```
 ┌─────────────┐
 │  CONNECTING │  TCP/WS connection established (or Punch channel open)
 └──────┬──────┘
        │ send: connect
        ▼
 ┌─────────────┐
 │  HANDSHAKE  │  Waiting for host response
 └──────┬──────┘
        │ recv: hello        recv: rejected
        ├─────────────────────────────────────► TERMINAL (show error, close)
        ▼
 ┌──────────────────┐
 │ CAPS_CHECK       │  Verify required_caps; disconnect if unsupported
 └──────┬───────────┘
        │ caps OK → send: hello_ack
        ▼
 ┌──────────────────┐
 │ WORKSPACE_SYNC   │  Receiving workspace_info_chunk… → workspace_info_done → open_files_snapshot
 └──────┬───────────┘
        │ recv: open_files_snapshot (last expected init message)
        ▼
 ┌──────────────────┐
 │     ACTIVE       │  Full collaborative mode; all message types in §5 valid
 └──────┬───────────┘
        │ recv/send: bye  OR  connection error
        ▼
 ┌──────────────────┐
 │    TERMINAL      │  Clean up presence state; do not reconnect
 └──────────────────┘
```

**Notes on WORKSPACE_SYNC:**
- The init sequence in this window is: one or more `workspace_info_chunk`, exactly one `workspace_info_done`, optionally `peers_snapshot`, then `open_files_snapshot`. The host emits them in that order.
- The client should buffer but not yet display any `patch` or `cursor` messages that arrive before `open_files_snapshot` is processed — apply them immediately after the snapshot is committed.
- The client MAY render the file explorer progressively as `workspace_info_chunk` messages arrive (no need to wait for `workspace_info_done`); but it MUST stay in WORKSPACE_SYNC until `open_files_snapshot`.
- If no `open_files_snapshot` is received within a reasonable timeout (suggested: 10 s), the client should disconnect and surface an error.

**Notes on ACTIVE:**
- `file_request` / `file_response` may be used at any time during ACTIVE.
- A `rejected` message arriving outside HANDSHAKE should be treated as a fatal error and transition to TERMINAL.

---

## 9. End-to-End Example Session

This section walks through a minimal but complete session: one guest joining, making one edit, and disconnecting. All payloads are shown unencrypted for readability; in practice each one is wrapped as described in §2.

### Setup

- Host is sharing the file `src/hello.lua` containing two lines: `print("hello")` and `print("world")`.
- Transport: WebSocket (tunnel URL `https://abc.localhost.run`).
- Share URL copied to clipboard: `https://abc.localhost.run#key=dGVzdGtleWhlcmUxMjM0NTY3OA`

### 1. Guest connects

Guest opens a TCP connection to `abc.localhost.run:443` and completes the WebSocket upgrade (HTTP `Upgrade: websocket`). Then sends:

```json
{ "t": "connect" }
```

### 2. Host approves and sends hello

The host prompts the user ("Bob wants to join — approve?") and on approval sends:

```json
{
  "t": "hello",
  "protocol_version": 4,
  "peer_id": 1,
  "sid": "f4a9b2c1",
  "role": "rw",
  "host_name": "alice",
  "required_caps": ["workspace"],
  "optional_caps": ["cursor", "follow"]
}
```

### 3. Guest checks caps and acknowledges

Guest supports `workspace` and `cursor`; does not implement `follow`. Responds:

```json
{ "t": "hello_ack", "name": "bob", "caps": ["workspace", "cursor"] }
```

### 4. Host sends workspace init sequence

```json
{ "t": "workspace_info_chunk", "seq": 1, "root_name": "my-project", "files": ["src/hello.lua", "README.md"] }
{ "t": "workspace_info_done", "total_files": 2, "truncated": false }
```

No other guests are connected, so `peers_snapshot` is omitted. Then:

```json
{
  "t": "open_files_snapshot",
  "files": [
    { "path": "src/hello.lua", "lines": ["print(\"hello\")", "print(\"world\")"] }
  ]
}
```

Guest is now in ACTIVE state and opens a virtual buffer for `src/hello.lua`.

### 5. Guest edits line 1

Bob changes `print("hello")` to `print("hi")`. Guest sends:

```json
{ "t": "patch", "path": "src/hello.lua", "seq": 0, "lnum": 0, "count": 1, "lines": ["print(\"hi\")"], "peer": 1 }
```

Host applies the patch, assigns `seq: 42` (its current counter), and broadcasts to all peers including the originating guest:

```json
{ "t": "patch", "path": "src/hello.lua", "seq": 42, "lnum": 0, "count": 1, "lines": ["print(\"hi\")"], "peer": 1 }
```

Guest receives the broadcast, confirms `seq: 42`, and treats it as the authoritative version (replacing any optimistic local state).

### 6. Guest disconnects

Bob closes the session. Guest sends:

```json
{ "t": "bye", "peer": 1, "name": "bob" }
```

Guest closes the connection. Host removes the peer from its registry. If other guests were connected, the host would broadcast the `bye` on Bob's behalf — but in this example there are none.

---

## 10. Compatibility and Stability

### What is stable

The following are considered stable across minor version bumps and will not change without a `protocol_version` increment:

- All message types defined in §5 and their required fields.
- The transport auto-detection mechanism (§1).
- The encryption envelope format (§2.2).
- The `seq`-based ordering contract (§7.1).
- The capability token names defined in §5.1.

### What may still change

- **New optional fields** may be added to any message without a version bump. Clients must ignore unknown fields.
- **New optional capability tokens** may be introduced without a version bump. Clients must ignore unknown tokens in `optional_caps`.
- **New message types** may be added without a version bump. Clients must silently discard messages with an unrecognised `t` field.
- **Punch transport details** (§1.3) — the signaling HTTP API and hole-punching flow are still maturing and may change in a minor release with notice in the changelog.

### Breaking changes

A change is considered breaking if it:
- Removes or renames an existing field in a stable message.
- Changes the semantic meaning of an existing field.
- Adds a new **required** capability that existing clients cannot negotiate around.

Breaking changes will always increment `protocol_version`. The changelog in §4 will describe the delta. Clients receiving a `protocol_version` higher than their own **must** warn the user and **may** refuse to connect.

### How breaking changes are announced

When a breaking protocol change ships:

1. `protocol_version` is incremented in the source and in this document's header.
2. The [CHANGELOG](./CHANGELOG.md) entry for that release is marked **BREAKING** and lists every removed or renamed field.
3. The GitHub release notes for that tag include a plain-language migration note: what changed, whether any action is required, and how to tell if your peer is running an incompatible version.
4. A deprecation notice is added to this document at least one minor release before the field or behavior is removed, whenever the change can be staged.

### `file_request` response timeout

`file_request` is a fire-and-forget message — the guest sends it once and waits for the matching `file_response` or `error`. There is no retry mechanism. If no response arrives within 10 seconds, the guest should treat the silence as a connection error and transition to TERMINAL state.

### Terminal input encoding

The `data` field of `terminal_input` is a raw byte string (UTF-8). Control sequences (e.g. `\u0003` for Ctrl+C, `\u001b[A` for arrow-up) are included verbatim and must not be escaped or transformed. The host passes the bytes directly to the PTY via `chansend` without any modification; the guest must do the same in the opposite direction.

---

## 11. Design decisions

This section documents the key trade-offs made when designing the protocol. It is informational only and does not affect wire compatibility.

### Why WebSocket instead of raw TCP for the default transport

HTTP tunnel providers (serveo.net, localhost.run) are HTTP reverse proxies — they speak HTTP/1.1 and require a valid `Upgrade: websocket` handshake before forwarding arbitrary byte streams. Raw TCP connections sent through these tunnels are rejected or corrupted at the proxy layer. The server therefore auto-detects the transport from the first 4 bytes of each connection: `"GET "` indicates a WebSocket upgrade; any other value is treated as a raw TCP connection with a 4-byte length prefix. This keeps both modes behind a single port and allows ngrok (TCP mode) and bore to work without WebSocket overhead.

### Why AES-256-GCM via LuaJIT FFI instead of a Lua library

Neovim has LuaJIT available everywhere, and OpenSSL is present on virtually every system that runs Neovim. Binding to `libcrypto` via FFI costs a few lines of C-style declarations and avoids pulling in a native Lua extension (which would require a compiler on every install). AES-256-GCM gives authenticated encryption in a single pass; the 12-byte random nonce per message means key reuse is not a concern in practice. The session key never leaves the URL fragment and never reaches the tunnel server.

### Why line-level last-write-wins instead of CRDT or OT

The expected collaboration pattern is one active author with one or more observers, or light turn-based editing — not simultaneous heavy editing of the same lines by multiple people. A CRDT (e.g. YATA, RGA) or operational transform would handle concurrent same-line edits gracefully but adds significant complexity: persistent document state, tombstones or history vectors, and a non-trivial merge function. LWW with host-assigned monotonic sequence numbers achieves full convergence for the common case, is easy to reason about, and is straightforward to implement in any language. The trade-off is documented explicitly in §3 so users know what to expect.

### Why no external plugin dependencies

The WebSocket handshake, including SHA-1 for `Sec-WebSocket-Accept`, is implemented in pure Lua. The alternative — depending on a third-party Neovim library just for a one-time handshake — would add an install-time dependency for a single operation. The pure-Lua SHA-1 implementation is small, self-contained, and covered by the test suite against the RFC 6455 test vector.

---

## 12. Patch Operation Reference

This section is aimed at third-party client implementors. It describes how to encode and decode `patch` messages precisely.

### Line indexing

All line numbers in `patch`, `cursor`, and snapshot messages are **0-indexed**. The first line of a file is `lnum: 0`.

### Applying a patch

A patch replaces `count` lines starting at `lnum` with the content of `lines`:

```
buffer[lnum : lnum + count] = lines
```

This maps directly to `nvim_buf_set_lines(buf, lnum, lnum + count, false, lines)`.

| Field | Meaning |
|:---|:---|
| `lnum` | First line to replace (0-indexed, inclusive) |
| `count` | Number of lines to remove (0 = pure insertion) |
| `lines` | Replacement lines; may have a different length than `count` |

Special value: **`count = -1`** replaces the entire buffer (equivalent to `lnum = 0, end = -1`).

### Operation examples

All examples start from this 5-line buffer:

```
0: "line 1"
1: "line 2"
2: "line 3"
3: "line 4"
4: "line 5"
```

**Insert a line** (between "line 2" and "line 3"):
```json
{ "lnum": 2, "count": 0, "lines": ["new line"] }
```
→ `["line 1", "line 2", "new line", "line 3", "line 4", "line 5"]`

**Delete a line** (remove "line 3"):
```json
{ "lnum": 2, "count": 1, "lines": [] }
```
→ `["line 1", "line 2", "line 4", "line 5"]`

**Replace a line** ("line 3" → "replacement"):
```json
{ "lnum": 2, "count": 1, "lines": ["replacement"] }
```
→ `["line 1", "line 2", "replacement", "line 4", "line 5"]`

**Multi-line replace** (replace lines 1–3 with two lines):
```json
{ "lnum": 1, "count": 3, "lines": ["new 2", "new 3"] }
```
→ `["line 1", "new 2", "new 3", "line 5"]`

**Append at end** (buffer has 5 lines, so the next index is 5):
```json
{ "lnum": 5, "count": 0, "lines": ["last line"] }
```
→ `["line 1", "line 2", "line 3", "line 4", "line 5", "last line"]`

Set `lnum` to the current line count to append after the last line.

**Full buffer replace**:
```json
{ "lnum": 0, "count": -1, "lines": ["only line"] }
```
→ `["only line"]`

**Clear buffer** (replace with a single empty line — buffers always have at least one line):
```json
{ "lnum": 0, "count": -1, "lines": [""] }
```

### Line endings

Lines in `lines` arrays are stored **without line terminators**. Before encoding a patch, strip any trailing `\n` or `\r\n` from each line. When applying a received patch, do not add line terminators to the stored lines. The protocol is LF-agnostic at the wire level: all normalization is the client's responsibility.

### Empty files

An empty file is represented as `"lines": [""]` — a single empty string. This follows the Neovim buffer model where a buffer always has at least one line. Clients receiving `"lines": []` in an `open_files_snapshot` or `file_response` should treat it as equivalent to `[""]`.

### Host rebroadcast to sender

The host broadcasts every applied patch to **all connected peers, including the peer that originated it**. Guests must not apply their own edits optimistically and rely on local state as authoritative. A guest's outgoing patch (sent without a `seq`) is considered pending until the matching host broadcast arrives with an assigned `seq`. Only at that point should the guest treat the edit as committed.

### Protocol fixtures

Reference payloads for all message types are available in [`tests/fixtures/`](./tests/fixtures/). These are static JSON files suitable for validating a parser or testing a handshake implementation against known-good inputs. Encryption fixtures (raw key → nonce → ciphertext) are not included; the encryption envelope is described in §2.2.
