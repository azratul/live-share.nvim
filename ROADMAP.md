# Roadmap

This document describes the direction of live-share.nvim. It is a statement of intent, not a commitment — priorities may shift as the project evolves.

---

## Now (active)

**Promote `punch` to stable**
Transport is beta on Linux with all four built-in providers (direct + relay). Needs confirmation on macOS and Windows before graduating to stable.

**Shared terminal stability**
PTY streaming works. The remaining gaps are around guest reconnect (terminal state is lost on reconnect) and resize propagation on Windows.

---

## Later

**More tunnel providers out of the box**
`bore` is already supported via the custom provider API. A built-in `bore` registration would remove the manual setup step. Other candidates: Cloudflare Tunnel, FRP.

---

## Not planned

- **CRDT / OT sync** — the LWW model is a deliberate trade-off. The expected collaboration pattern is one active author with observers, or light turn-based editing. A CRDT would handle simultaneous same-line edits more gracefully but at significant complexity cost. If this becomes a pain point for your team, open an issue with your use case.
- **Neovim < 0.9** — `vim.uv`, `nvim_buf_set_extmark`, and `vim.health` APIs used throughout the plugin are not available in older versions.
- **Built-in relay infrastructure** — the relay broker runs on the host's signaling server during a session; there are no plans to operate a shared public relay service.

---

## Cross-editor interoperability

The [live-share.nvim protocol](./PROTOCOL.md) is editor-agnostic. There is an early-stage VS Code client ([open-pair](https://github.com/darkerthanblack2000/open-pair)) being developed independently. The protocol spec and the SDK (`sdk/`) are the intended interface for other editor implementations.

If you are building a client for another editor, open an issue — compatibility testing and protocol feedback are welcome.
