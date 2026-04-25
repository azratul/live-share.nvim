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

This plugin brings VS Code-like Live Share functionality natively to Neovim: real-time collaborative editing, remote cursors and selections, shared terminals, and E2E encryption — with no external plugin dependencies.

> Note: This plugin is designed to work exclusively between Neovim instances and is not compatible with Visual Studio Code Live Share sessions. However, the underlying protocol is now publicly available, allowing developers of VS Code or any other editor to build their own client implementation and interoperate with the collaboration system. In that sense, while the plugin itself is Neovim-focused, the protocol is now editor-independent and open to broader ecosystem adoption.

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

There is also early work on a VS Code client built around the `azratul/live-share.nvim` protocol: [open-pair](https://github.com/darkerthanblack2000/open-pair).

This project is currently a work in progress and has not been tested by this plugin's maintainer. Compatibility should therefore be considered experimental for now.

If you're interested in cross-editor collaboration between Neovim and VS Code, keep an eye on `open-pair` as it evolves.

### Removal of the instant.nvim dependency

Previous versions relied on [jbyuki/instant.nvim](https://github.com/jbyuki/instant.nvim) as the collaborative editing engine. That dependency was removed for two reasons:

- **The project appears abandoned.** `instant.nvim` has not received updates in four years and no longer seems actively maintained, which makes relying on it risky.
- **Encryption was a hard requirement.** The plugin routes traffic through third-party reverse SSH tunneling services (serveo.net, localhost.run, ngrok). Sending plaintext editor content through those servers is not acceptable, and instant.nvim offered no path to support end-to-end encryption.

Replacing `instant.nvim` meant reimplementing the entire collaboration layer from scratch. The key design decisions were:

- **WebSocket over plain TCP** — required because HTTP tunnel providers (serveo, localhost.run) act as HTTP reverse proxies and reject raw TCP. The server auto-detects WebSocket vs. raw TCP from the first 4 bytes of each connection, keeping both modes behind the same port.
- **AES-256-GCM via LuaJIT FFI** — chosen to avoid a Lua native extension dependency while still getting authenticated encryption. Each message carries a fresh 12-byte nonce; the session key never leaves the URL fragment.
- **Line-level last-write-wins with host-assigned sequence numbers** — deliberately simple. A CRDT would handle concurrent edits more gracefully, but adds significant complexity for a use case where one participant is almost always the authority. The host's monotonic `seq` counter is sufficient for the expected collaboration patterns.
- **No external plugin dependencies** — the WebSocket handshake (including SHA-1 for `Sec-WebSocket-Accept`) is implemented in pure Lua to avoid pulling in a third-party library for a single handshake operation.

The rewrite was carried out with AI assistance as a development tool, with all architectural decisions, protocol design, and code review done by the maintainer.

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

## What's new in v2.1.0

### P2P transport via punch.lua
A new `transport = "punch"` mode establishes a direct peer-to-peer UDP channel between host and guest using NAT hole-punching ([punch.lua](https://github.com/azratul/punch.lua)). The tunnel is used only during the ~5-second signaling phase; all collaborative traffic flows over a direct encrypted UDP channel afterwards, bypassing the tunnel server entirely. When direct hole-punching fails (e.g. symmetric NAT or double NAT), the session automatically falls back to a relay broker hosted on the same signaling server — no extra configuration required.

The P2P channel is encrypted with AES-256-GCM using the same session key that travels in the URL fragment.

To use P2P transport, install punch ≥ 0.3.2 and configure any tunnel service. The tunnel is only used during the ~5-second HTTP signaling phase, so HTTP reverse proxies (serveo, localhost.run) work just as well as TCP-level tunnels (bore, ngrok):

```lua
require("live-share").setup({
  transport = "punch",
  service   = "bore",   -- or "ngrok", "serveo.net", "nokey@localhost.run"
  stun      = { "stun.l.google.com:19302", "stun1.l.google.com:19302" },
  username  = "your-name",
})
```

## What's new in v2.0.0

### Multi-buffer workspace
The host shares the entire workspace, not just a single file. Guests can browse and open any file via `:LiveShareWorkspace` (fuzzy picker if telescope-ui-select, fzf-lua, or snacks is installed; collapsible tree otherwise) or `:LiveShareOpen <path>`.

### E2E encryption
Sessions are encrypted with AES-256-GCM via OpenSSL (LuaJIT FFI). The session key travels in the URL fragment (`#key=…`) and never reaches the tunnel server.

### Remote cursors and selections
Each peer's cursor is rendered as a labeled EOL marker in a per-peer highlight color. When a peer enters visual mode (`v`, `V`, `^V`), the selected range is highlighted in their color in every other participant's buffer in real time.

### Shared terminal
`:LiveShareTerminal` (host only) spawns a PTY shell locally and streams its I/O to all guests. Guests receive a fully interactive terminal buffer — their keystrokes are forwarded to the host's shell over the same encrypted connection.

### Guest approval and roles
The host is prompted to approve or deny each incoming connection and can assign a **Read/Write** or **Read-only** role per guest.

### Follow mode
`:LiveShareFollow [peer_id]` switches your active buffer to track another participant's movements in real time. Omit the peer ID to follow the host.

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

![Live Share Preview](https://raw.githubusercontent.com/azratul/azratul/86d27acdbe36f0d4402a21e13b79fafbaec1ffc9/live-share.gif)

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

## Protocol overview

For a detailed technical specification of the communication layer, message schemas, and synchronization strategy, see [PROTOCOL.md](./PROTOCOL.md).

- **Transport**: Two modes available:
  - `ws` (default): WebSocket over TCP. Auto-detects WebSocket vs. raw TCP from the first 4 bytes — WebSocket for HTTP tunnel providers (serveo, localhost.run), raw length-prefixed TCP for direct connections and ngrok.
  - `punch`: Direct P2P UDP via NAT hole-punching (punch.lua => `luarocks intall punch` or `luarocks install --local punch`). The tunnel exposes only the HTTP signaling server (~5 s); all subsequent traffic flows peer-to-peer. Compatible with any tunnel provider (bore, ngrok, serveo, localhost.run).
- **Encryption**: `[12-byte nonce][AES-256-GCM ciphertext+tag]` per message. For `ws`, encryption is applied at the protocol layer; for `punch`, the channel layer handles it. Required — sessions will not start if OpenSSL is unavailable.
- **Buffer sync**: line-level last-write-wins. The host assigns a monotonic sequence number to every patch and is the ordering authority.
- **Shared terminal**: PTY I/O streamed over the same encrypted connection as all other session events.

### Conflict model

The plugin uses **line-level last-write-wins**: the host is the sole ordering authority and applies guest edits in the order they arrive over TCP/UDP. If two participants edit the same line simultaneously, one edit wins (whichever reached the host first) and the other is silently overwritten. After all broadcasts are applied, every peer converges to identical state — there are no permanent divergences.

**What this means in practice:**

| Scenario | Result |
|----------|--------|
| Two users edit different lines simultaneously | Safe — no interference |
| Two users edit the same line simultaneously | One edit is lost (arrival order at host decides) |
| High-latency connection (> 200 ms) | Conflict window is larger; same-line edits less reliable |
| Read-only guest (`role: ro`) | Cannot cause conflicts; receives authoritative stream only |

This is a deliberate trade-off. The expected collaboration pattern is one active author with observers, or light turn-based editing. For use cases requiring true simultaneous editing of the same lines, a CRDT-based protocol would be more appropriate at significantly higher implementation complexity.

For the full semantics, known limitations, and convergence guarantees, see [§3 of PROTOCOL.md](./PROTOCOL.md#3-synchronization-strategy).

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
| Cross-editor interop (open-pair) | **Experimental** | Third-party VS Code client; not tested by this maintainer |

The `ws` transport, encryption, and buffer sync are the most exercised paths and can be considered production-ready for same-version peers on Linux, macOS, and Windows. The `punch` transport (≥ 0.3.2) is tested on Linux with all four built-in tunnel providers; relay fallback for symmetric/double NAT works end-to-end. Other platforms and edge-case NAT topologies may still have rough edges. Issues and feedback are welcome.

## Test coverage

The test suite runs under [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) and covers the following areas:

| Suite | What it tests |
|-------|---------------|
| `tests/crypto/` | AES-256-GCM key generation, encrypt/decrypt round-trips, wrong-key and tamper detection, nonce uniqueness, base64url encoding |
| `tests/websocket/` | HTTP upgrade handshake (request and response headers, `Sec-WebSocket-Accept` against the RFC 6455 test vector), binary frame encode/decode, 16-bit length extension, fragmentation across chunks, client-side masking |
| `tests/protocol/` | JSON message codec, encrypted round-trips, wrong-key rejection, fixture validation for all message types (`hello`, `patch`, `cursor`, `terminal_data`, `bye`) |
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
