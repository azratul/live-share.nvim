# Live Share Plugin for Neovim

[![CI](https://github.com/azratul/live-share.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/azratul/live-share.nvim/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/azratul/live-share.nvim)](https://github.com/azratul/live-share.nvim/releases/latest)
[![Neovim 0.9+](https://img.shields.io/badge/Neovim-0.9%2B-blueviolet?logo=neovim)](https://neovim.io)
[![License](https://img.shields.io/github/license/azratul/live-share.nvim)](LICENSE)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/azratul/live-share.nvim)
![GitHub repo size](https://img.shields.io/github/repo-size/azratul/live-share.nvim)

<a href="https://dotfyle.com/plugins/azratul/live-share.nvim">
	<img src="https://dotfyle.com/plugins/azratul/live-share.nvim/shield?style=flat-square" />
</a>

## Overview

A **Neovim-native, end-to-end encrypted alternative to VS Code Live Share**. Real-time collaborative editing, remote cursors and selections, and shared terminals — no Microsoft account, no telemetry, an open protocol, and self-hostable / SSH / P2P-friendly workflows.

**Neovim ↔ VS Code collaboration is supported** through [open-pair](https://github.com/darkerthanblack2000/open-pair), tested in both directions (Neovim host ↔ VS Code guest, and VS Code host ↔ Neovim guest), including cross-platform Windows ↔ Linux sessions. See [Editor interoperability](#editor-interoperability) for details.

> Note: This plugin is **not protocol-compatible with Microsoft Visual Studio Code Live Share sessions**. The `live-share.nvim` protocol is open and editor-independent — cross-editor collaboration happens through compatible clients like `open-pair`.

## Quick Start

**Recommended setup** — no extra Lua dependencies, SSH already installed on most systems:

```lua
-- lazy.nvim
{
  "azratul/live-share.nvim",
  config = function()
    require("live-share").setup({
      username = "your-name",
    })
  end,
}
```

Start hosting: `:LiveShareHostStart` — the share URL is copied to your clipboard.
Join a session: `:LiveShareJoin <url>`

This uses `nokey@localhost.run` as the tunnel (SSH-based, no account required) and `ws` as the transport. Both are the most tested paths and work on Linux, macOS, and Windows.

**Advanced: P2P setup** (direct UDP after the initial handshake, requires [`punch`](https://github.com/azratul/punch.lua) ≥ 0.3.2 — currently Linux only):

```lua
{
  "vhyrro/luarocks.nvim",
  lazy = false, priority = 1000, config = true,
  opts = { rocks = { "punch >= 0.3.2" } },
},
{
  "azratul/live-share.nvim",
  dependencies = { "vhyrro/luarocks.nvim" },
  config = function()
    require("live-share").setup({ username = "your-name", transport = "punch" })
  end,
}
```

See the [Installation](#installation) section for packer.nvim, vim-plug, and alternative tunnel providers.

## Editor interoperability

`live-share.nvim` can interoperate with other editors through the open collaboration protocol described in [PROTOCOL.md](./PROTOCOL.md).

The VS Code client [open-pair](https://github.com/darkerthanblack2000/open-pair) has been tested successfully with `live-share.nvim` in both directions:

- `live-share.nvim` as host and `open-pair` as guest.
- `open-pair` as host and `live-share.nvim` as guest.

Cross-platform sessions have also been tested between Windows and Linux, with participants using different editors — Neovim and VS Code — on either side.

This means Neovim ↔ VS Code collaboration is supported when both clients implement the compatible protocol version. For details about protocol compatibility and version negotiation, see [COMPATIBILITY.md](./COMPATIBILITY.md).

### Requirements

- **Neovim 0.9+**
- **OpenSSL** (required — sessions will not start without it)
- **Tunneling Binary**:
  - `serveo.net` / `localhost.run`: requires **SSH**
  - `ngrok`: requires the `ngrok` CLI ([download](https://ngrok.com/download)) authenticated once with:
    ```bash
    ngrok config add-authtoken <your_token>
    ```
    The free plan works fine.
  - `bore`: requires the [`bore`](https://github.com/ekzhang/bore) CLI
- **P2P transport** (optional): requires the [`punch`](https://github.com/azratul/punch.lua) Lua library ≥ 0.3.2
  (includes container support, relay fallback, and localhost.run compatibility):
  ```bash
  luarocks install punch
  ```

- **Tested Environments** (`ws` transport): Linux, OpenBSD, macOS, and Windows (Git Bash). The `punch` P2P transport is tested on Linux with all four built-in tunnel providers; use `ws` for environments where `punch` has not been tested.

For a detailed summary of what changed in each release, see [CHANGELOG.md](./CHANGELOG.md).

## Installation

No external plugin dependencies required for the default `ws` transport.
If you want to use the `punch` P2P transport, the `punch` Lua library is required (see options below).

### lazy.nvim

Basic installation (no P2P transport):

```lua
{
  "azratul/live-share.nvim",
  config = function()
    require("live-share").setup({
      username = "your-name",
    })
  end
}
```

**Option A** — auto-install punch via a build hook (runs once on install/update):

```lua
{
  "azratul/live-share.nvim",
  build = "luarocks install punch",
  config = function()
    require("live-share").setup({
      transport = "punch",
      service   = "bore",   -- or "ngrok", "serveo.net", "nokey@localhost.run"
      username  = "your-name",
    })
  end
}
```

**Option B** — auto-install punch via [luarocks.nvim](https://github.com/vhyrro/luarocks.nvim)
(recommended — makes punch part of your Neovim config and pins the required version):

```lua
{
  "vhyrro/luarocks.nvim",
  lazy = false,          -- must load before everything else
  priority = 1000,
  config = true,
  opts = { rocks = { "punch >= 0.3.2" } },
},
{
  "azratul/live-share.nvim",
  dependencies = { "vhyrro/luarocks.nvim" },
  config = function()
    require("live-share").setup({
      transport = "punch",
      service   = "bore",   -- or "ngrok", "serveo.net", "nokey@localhost.run"
      username  = "your-name",
    })
  end,
}
```

### packer.nvim

```lua
use {
  "azratul/live-share.nvim",
  config = function()
    require("live-share").setup({
      username = "your-name",
    })
  end
}
```

### vim-plug

```vim
Plug 'azratul/live-share.nvim'

lua << EOF
require("live-share").setup({
  username = "your-name",
})
EOF
```

## Commands

| Command | Role | Description |
|---|---|---|
| `:LiveShareHostStart [port]` | Host | Start hosting. URL with session key is copied to clipboard. |
| `:LiveShareJoin <url> [port]` | Guest | Join a session by URL. |
| `:LiveShareStop` | Both | End the active session. |
| `:LiveShareTerminal` | Host | Open a shared terminal. Guests receive it automatically. |
| `:LiveShareWorkspace` | Guest | Browse the host's workspace. Uses `vim.ui.select` if a fuzzy finder plugin is active; collapsible tree otherwise. |
| `:LiveShareOpen <path>` | Guest | Open a specific file from the workspace. |
| `:LiveShareFollow [peer_id]` | Both | Follow a peer's active buffer (no arg = follow host). |
| `:LiveShareUnfollow` | Both | Stop following. |
| `:LiveSharePeers` | Both | Show connected participants and their cursor positions. |
| `:LiveShareDebugInfo` | Both | Open a scratch buffer with environment and session details for bug reports. |

> **Migration note:** `:LiveShareServer` was renamed to `:LiveShareHostStart` in v2.0.0. The old command still works but emits a deprecation warning.

After starting the server, wait for the message indicating the URL has been copied to the clipboard. Share that URL with anyone you want to invite.

### Preview

1. Neovim to Neovim

![Neovim to Neovim](https://raw.githubusercontent.com/azratul/azratul/main/nvim-nvim.gif)

2. Cross-editor

![Neovim to VS Code](https://raw.githubusercontent.com/azratul/azratul/main/nvim-vscode.gif)

![VS Code to Neovim](https://raw.githubusercontent.com/azratul/azratul/main/vscode-nvim.gif)

3. Shared Terminal

![Neovim Shared Terminal](https://raw.githubusercontent.com/azratul/azratul/main/shared_terminal.gif)

4. Follow mode

![Neovim Follow Mode](https://raw.githubusercontent.com/azratul/azratul/main/follow_mode.gif)


For step-by-step walkthroughs of common scenarios (Neovim ↔ Neovim, Neovim ↔ VS Code, LAN-only, SSH tunnel, read-only review, self-hosted relay, shared terminal), see [RECIPES.md](./RECIPES.md).

## Configuration

All settings are optional.

```lua
require("live-share").setup({
  username       = "your-name",           -- displayed to other participants
  port_internal  = 9876,                  -- local TCP port for the collab server (ws/tcp transport)
  port           = 80,                    -- external tunnel port
  max_attempts   = 40,                    -- URL polling retries (× 250 ms = 10 s)
  service_url    = "/tmp/service.url",    -- temp file where the tunnel writes its URL
  service        = "nokey@localhost.run", -- tunnel provider (see below)
  workspace_root = nil,                   -- defaults to cwd
  debug          = false,                 -- enable verbose logging
  openssl_lib    = nil,                   -- explicit path to libcrypto, for systems where
                                          -- auto-detection fails (NixOS, custom builds, etc.)
                                          -- e.g. "/nix/store/xxxx-openssl-3.x/lib/libcrypto.so.3"
  -- P2P transport (requires: luarocks install punch)
  transport      = "ws",                  -- "ws" (default) or "punch" (direct P2P UDP)
  stun           = "stun.l.google.com:19302", -- STUN server; accepts a string or table of strings
})
```

### Tunnel providers

Built-in providers: `"serveo.net"`, `"localhost.run"`, `"nokey@localhost.run"`, `"ngrok"`.

Custom providers can be registered via the provider API:

```lua
require("live-share.provider").register("bore", {
  command = function(_, port, service_url)
    return string.format(
      "bore local %d --to bore.pub > %s 2>&1",
      port, service_url)
  end,
  pattern = "bore%.pub:%d+",
})

require("live-share").setup({ service = "bore" })
```

> **Privacy-first option.** You can self-host the tunnel on your own VPS (any SSH server with `GatewayPorts`, or `bore server`) so no third-party ever sees your encrypted traffic. With the `punch` transport this also gives you a self-hosted signaling and relay server "for free", since both ride on top of the chosen tunnel. See [RECIPES.md §6](./RECIPES.md#6-self-hosted-relay-privacy-first).

## Protocol overview

For the full specification — transport modes, encryption envelope, message schemas, synchronization semantics, and edge cases — see [PROTOCOL.md](./PROTOCOL.md).

The sync model is **line-level last-write-wins**: the host assigns a monotonic `seq` to every patch and is the sole ordering authority. Non-overlapping edits are always safe. Concurrent edits to the same line are resolved by arrival order at the host; one edit silently wins. See [§3 of PROTOCOL.md](./PROTOCOL.md#3-synchronization-strategy) for the convergence guarantees and known limitations.

## Stability matrix

| Feature | Status | Notes |
|---------|--------|-------|
| `ws` transport | **Stable** | Default mode; WebSocket over TCP, auto-detects raw TCP vs WS from first 4 bytes |
| AES-256-GCM encryption | **Stable** | Required; sessions will not start without OpenSSL |
| Buffer sync (patch) | **Stable** | Line-level LWW, host-assigned monotonic seq |
| Remote cursors and selections | **Stable** | EOL extmarks, per-peer color, visual range highlight |
| Guest approval and roles | **Stable** | RW / RO per guest, prompted via `vim.ui.select` |
| Protocol v3 | **Stable** | Spec in [PROTOCOL.md](./PROTOCOL.md); version negotiation in [COMPATIBILITY.md](./COMPATIBILITY.md) |
| Follow mode | **Stable** | Host and guest follow; auto-disables when followed peer disconnects |
| Workspace browser | **Stable** | Collapsible tree or fuzzy picker (auto-detected); initial sync is slow on very large workspaces |
| Shared terminal | **Beta** | PTY streaming works; edge cases under active testing |
| `punch` P2P transport | **Beta** | NAT hole-punching via [punch.lua](https://github.com/azratul/punch.lua) ≥ 0.3.2; direct + relay paths work on Linux with all built-in providers; other platforms not yet tested |
| Cross-editor interop (open-pair) | **Tested** | Verified with `live-share.nvim` as host and guest, including Windows ↔ Linux sessions with Neovim and VS Code |

The `ws` transport, encryption, and buffer sync are the most exercised paths and can be considered production-ready for same-version peers on Linux, macOS, and Windows. The `punch` transport (≥ 0.3.2) is tested on Linux with all four built-in tunnel providers; relay fallback for symmetric/double NAT works end-to-end. Other platforms and edge-case NAT topologies may still have rough edges. Issues and feedback are welcome.

## Test coverage

The test suite runs under [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) and covers the following areas:

| Suite | What it tests |
|-------|---------------|
| `tests/crypto/` | AES-256-GCM key generation, encrypt/decrypt round-trips, wrong-key and tamper detection, nonce uniqueness, base64url encoding |
| `tests/websocket/` | HTTP upgrade handshake (request and response headers, `Sec-WebSocket-Accept` against the RFC 6455 test vector), binary frame encode/decode, 16-bit length extension, fragmentation across chunks, client-side masking |
| `tests/protocol/` | JSON message codec, encrypted round-trips, wrong-key rejection, fixture validation for all message types (`connect`, `hello`, `hello_ack`, `patch`, `cursor`, `terminal_data`, `bye`, `workspace_info`, `file_request`, `file_response`, `open_files_snapshot`) |
| `tests/transport/` | TCP framing (4-byte little-endian length prefix): encoding, multi-message reassembly, byte-by-byte delivery; WS framing layer: masked and unmasked round-trips |
| `tests/connection/` | Listener interface contract — confirms `new_listener` and `new_punch_listener` expose the required method set |
| `tests/integration/` | Real TCP server/client over loopback: connect events, message delivery, broadcast to 2 and 3 simultaneous peers (TCP and mixed TCP+WS), AES-256-GCM encrypted sessions, sequential patch ordering, concurrent patches from multiple guests, abrupt-disconnect `bye` synthesis and re-broadcast (§7.3), read-only role enforcement, connection rejection, `except_peer` exclusion |

Run the full suite:

```bash
nvim --headless \
  -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

Network behavior (TCP connect, WebSocket handshake, broadcast, encryption) is covered by the integration suite. Neovim UI interactions (extmarks, `vim.ui.select`, cursor rendering) require two live Neovim instances and are covered by the [local smoke test](./TROUBLESHOOTING.md#local-two-instance-smoke-test-no-tunnel-required) in TROUBLESHOOTING.md.

## Known limitations

- **Simultaneous edits to the same line** — the sync model is line-level last-write-wins with the host as ordering authority. If two participants edit the same line at the same time, one edit is silently overwritten. For conflict-free collaboration, use read-only guests or coordinate turns explicitly.
- **Large workspace initial sync** — the host sends the full workspace file list on connect. Very large directories (tens of thousands of files) make the initial sync slow. File content is only transferred on demand, so the delay is proportional to the number of paths, not their size.
- **`punch` transport is Linux-only for now** — direct UDP hole-punching and relay fallback are confirmed on Linux with all four built-in tunnel providers. macOS and Windows are untested.
- **Shared terminal state is lost on guest reconnect** — if a guest disconnects and reconnects, the terminal buffer starts fresh; scrollback from before the reconnect is not replayed.
- **No authentication beyond key possession** — any guest who obtains the share URL can attempt to join. The host approval prompt is the only gate. Share the URL only through trusted channels.
- **No forward secrecy** — the tunnel provider sees encrypted traffic during the session and could log it. If the session URL were later leaked (e.g. via a breached chat log), that recorded traffic could in theory be decrypted retroactively. In practice this requires the tunnel provider to log traffic AND the URL to be independently compromised — an unlikely combination for typical pair programming use.
- **Same protocol version expected** — host and guest should run the same version of live-share.nvim. See [COMPATIBILITY.md](./COMPATIBILITY.md) for the version negotiation details.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md) for development setup, code style, running tests, and PR guidelines.

## Security

See [SECURITY.md](./SECURITY.md) for the full security model: what is encrypted, what tunnel servers can see, how keys are exchanged, and the threat model.

## Troubleshooting

See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for common issues with OpenSSL, tunnel providers, and the P2P transport.
Run `:checkhealth live-share` first — it catches most configuration problems automatically.

## Roadmap

See [ROADMAP.md](./ROADMAP.md).

## License

This project is licensed under the GPL-3.0 License.
