# Compatibility

## Protocol versioning

The wire protocol version is an integer sent in the `hello` message (host → guest) during the connection handshake:

```json
{ "t": "hello", "protocol_version": 3, ... }
```

This integer is the only value that determines wire compatibility. The spec document version (`v1.2.0` in PROTOCOL.md) is independent — it tracks editorial changes and does not affect the wire format.

### Version history

| Protocol version | Introduced in plugin | Changes |
|:---|:---|:---|
| 1 | v2.0.0 | Initial versioned release; introduces the `protocol_version` field |
| 2 | v2.0.x | Adds `caps` to `hello` / `hello_ack`; adds `error` message type; formalises `file_request` / `file_response` resync flow |
| 3 | v2.1.0 | Replaces flat `caps` list with `required_caps` / `optional_caps`; adds `req_id` to `file_request`, `file_response`, and `error` |

> **v1.x (instant.nvim era):** versions before v2.0.0 used the `instant.nvim` collaboration engine and a completely different wire format. They are not compatible with any v2.x or later release.

### Behavior on version mismatch

When the guest receives a `hello` with a `protocol_version` different from its own, it emits a `WARN` notification and continues:

```
live-share: protocol version mismatch (host=2, ours=3) — behaviour may be undefined
```

The session is not terminated automatically. In practice, a v3 guest connecting to a v2 host will likely work for basic buffer sync but may malfunction for capabilities introduced in v3 (`required_caps` / `optional_caps` negotiation). The safest path is to keep both sides on the same plugin version.

### Recommended compatibility rule

| Host | Guest | Expected outcome |
|:---|:---|:---|
| v2.1.x (protocol 3) | v2.1.x (protocol 3) | Fully supported |
| v2.1.x (protocol 3) | v2.0.x (protocol 1–2) | WARN; basic sync may work, capability negotiation unreliable |
| v2.0.x (protocol 1–2) | v2.1.x (protocol 3) | WARN; same as above |
| v1.x | any v2.x | Not compatible |

---

## Capabilities negotiation

Protocol v3 uses two capability lists in `hello`:

- **`required_caps`** — the guest must implement all of these or disconnect immediately (before sending `hello_ack`).
- **`optional_caps`** — the host suppresses messages for capabilities absent from the guest's `hello_ack.caps`; the guest may silently ignore messages for capabilities it did not advertise.

Unknown tokens in `optional_caps` or `hello_ack.caps` must be silently ignored (forward compatibility). Unknown tokens in `required_caps` must be treated as unsupported (disconnect).

Built-in capability tokens: `workspace`, `terminal`, `cursor`, `follow`.

---

## Cross-editor interoperability

The protocol is editor-agnostic. Any client that implements the message types in [PROTOCOL.md](./PROTOCOL.md) and passes the `protocol_version: 3` check in `hello` can interoperate with a live-share.nvim host.

The [open-pair](https://github.com/darkerthanblack2000/open-pair) VS Code extension is an early-stage third-party client targeting this protocol. It has not been tested by this plugin's maintainer; treat it as experimental.

If you are building a client for another editor, open an issue — protocol feedback and compatibility testing are welcome.

---

## Platform support

| Platform | `ws` transport | `punch` transport |
|:---|:---|:---|
| Linux | Confirmed | Confirmed (all built-in providers) |
| macOS | Confirmed | Not yet tested |
| Windows (Git Bash) | Confirmed | Not yet tested |
| OpenBSD | Confirmed | Not yet tested |

**Neovim requirement:** 0.9 or later. The plugin uses `vim.uv` (falling back to `vim.loop`), `nvim_buf_set_extmark`, and `vim.health` — none of which are available in older versions.

**OpenSSL requirement:** `libcrypto` must be discoverable at runtime (LuaJIT FFI). If auto-detection fails, set `openssl_lib` explicitly in `setup()`. See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for platform-specific paths.
