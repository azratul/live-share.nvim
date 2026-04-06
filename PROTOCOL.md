# Live-Share.nvim Protocol Specification (v1.0.0)

This document describes the communication protocol used by `live-share.nvim`. It is designed to allow developers to implement compatible plugins for other editors.

---

## 1. Transport Layer

The protocol supports two transport modes, automatically detected by the server on the first 4 bytes of a connection.

### 1.1 WebSocket (WS)
Used for HTTP tunneling services (e.g., `serveo.net`, `localhost.run`).
- Messages are sent as **Binary Frames**.
- The server expects standard WebSocket handshakes on the initial connection.

### 1.2 Raw TCP
Used for direct connections or `ngrok` (TCP mode).
- **Framing:** Each message is prefixed with a **4-byte Little Endian unsigned integer** representing the length of the payload.
- Example: A 10-byte payload is prefixed with `0A 00 00 00`.

---

## 2. Security Layer (E2E Encryption)

The protocol uses **AES-256-GCM** for end-to-end encryption. The encryption key is shared via the URL fragment (`#key=...`) and never reaches the tunnel server.

### 2.1 Key Derivation
- The key is a 32-byte (256-bit) random string, Base64Url encoded in the connection URL.
- Clients must decode the Base64Url string to get the raw 32-byte key.

### 2.2 Payload Structure
If a key is present, the binary payload (after the TCP length prefix or inside the WS frame) is structured as follows:

1.  **Nonce (IV):** 12 random bytes.
2.  **Ciphertext:** The AES-encrypted JSON string.
3.  **Authentication Tag:** 16 bytes (appended to the ciphertext).

*Note: If no key is provided, the payload is simply the UTF-8 encoded JSON string.*

---

## 3. Synchronization Strategy

The protocol follows a **Central Authority (Host)** model. It does not use CRDTs.

- **Authority:** The Host is the source of truth. It assigns a monotonic `seq` (sequence number) to every `patch` message.
- **Line-based Patching:** Edits are synchronized as line-range replacements.
- **Virtual Filesystem:** Guests should treat remote files as virtual resources (e.g., `liveshare://<session_id>/<path>`) and should not save them to the local physical disk.

---

## 4. Protocol Versioning

The `hello` message carries a `protocol_version` integer field. Clients **should** warn the user if the received version differs from their own. The current version is **1**.

| Version | Change summary |
| :--- | :--- |
| 1 | Initial versioned release. Introduces this field. |
| 2 | Adds `caps` to `hello` / `hello_ack`; adds `error` message type; formalises `file_request` / `file_response` resync flow. |
| 3 | Replaces flat `caps` with `required_caps` / `optional_caps`; adds `req_id` to `file_request` / `file_response` / `error`. |

---

## 5. Message Types (JSON Schema)

Every message is a JSON object with a type field `t`.

### 5.1 Connection Handshake

| Type (`t`) | Sender | Description |
| :--- | :--- | :--- |
| `connect` | Guest | Initial request to join. |
| `hello` | Host | Response after approval. Contains `protocol_version`, `peer_id`, `role` (`rw`/`ro`), `host_name`, `required_caps`, and `optional_caps`. |
| `rejected` | Host | Sent instead of `hello` when the connection is denied. |
| `workspace_info` | Host | Sent after `hello`. Contains `root_name` and a flat array `files` of relative paths. |
| `peers_snapshot` | Host | Sent after `workspace_info` if other guests are already connected. |
| `open_files_snapshot` | Host | Sent after `workspace_info`. Full content of all currently open files. |
| `hello_ack` | Guest | Final handshake step. Guest sends their `name` and `caps`. |

#### `connect` (Guest → Host)
```json
{ "t": "connect" }
```

#### `hello` (Host → Guest)
```json
{
  "t": "hello",
  "protocol_version": 1,
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

#### `workspace_info` (Host → Guest)
```json
{
  "t": "workspace_info",
  "root_name": "my-project",
  "files": ["src/main.lua", "README.md", "lua/plugin/init.lua"]
}
```

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

### 5.5 Shared Terminal

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
