# Live Share Plugin for Neovim

[![total lines](https://tokei.rs/b1/github/azratul/live-share.nvim)](https://github.com/XAMPPRocky/tokei)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/azratul/live-share.nvim)
![GitHub repo size](https://img.shields.io/github/repo-size/azratul/live-share.nvim)

<a href="https://dotfyle.com/plugins/azratul/live-share.nvim">
	<img src="https://dotfyle.com/plugins/azratul/live-share.nvim/shield?style=flat-square" />
</a>

✨ v2.0.0 – Native Collaboration Engine

> ⚠️ **Heads up:** If the latest commit causes any issues, please [open an issue](https://github.com/azratul/live-share.nvim/issues).
> Meanwhile, you can use the last stable version by checking out the [`v1.1.0`](https://github.com/azratul/live-share.nvim/releases/tag/v1.1.0) tag:

```lua
-- lazy.nvim
{ "azratul/live-share.nvim", version = "v1.1.0" }
```

## Overview

This plugin brings VS Code-like Live Share functionality natively to Neovim: real-time collaborative editing, remote cursors and selections, shared terminals, and E2E encryption — with no external plugin dependencies.

> Note: This plugin is designed to work exclusively between Neovim instances and is not compatible with Visual Studio Code Live Share sessions.

### Removal of the instant.nvim dependency

Previous versions relied on [jbyuki/instant.nvim](https://github.com/jbyuki/instant.nvim) as the collaborative editing engine. That dependency was removed for two reasons:

- **The project appears abandoned.** `instant.nvim` has not received updates in four years and no longer seems actively maintained, which makes relying on it risky.
- **Encryption was a hard requirement.** The plugin routes traffic through third-party reverse SSH tunneling services (serveo.net, localhost.run, ngrok). Sending plaintext editor content through those servers is not acceptable, and instant.nvim offered no path to support end-to-end encryption.

Replacing `instant.nvim` required reimplementing the entire collaboration layer from scratch: WebSocket transport, binary framing, buffer sync, cursor tracking, and AES-256-GCM crypto via LuaJIT FFI. Given the scope and complexity of that rewrite, it was carried out with the assistance of **AI vibecoding tools**.

### Requirements

- **Neovim 0.9+**
- **OpenSSL** (optional but recommended — without it the session runs unencrypted)
- **Tunneling Binary**:
  - `serveo.net` / `localhost.run`: requires **SSH**
  - `ngrok`: requires the `ngrok` CLI ([download](https://ngrok.com/download)) authenticated once with:
    ```bash
    ngrok config add-authtoken <your_token>
    ```
    The free plan works fine.

- **Tested Environments**: Linux and OpenBSD. macOS and Windows (GitBash only) are untested.

## What's new in v2.0.0

### Multi-buffer workspace
The host shares the entire workspace, not just a single file. Guests can browse and open any file via `:LiveShareWorkspace` or `:LiveShareOpen <path>`.

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

No external plugin dependencies required.

### lazy.nvim

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
| `:LiveShareWorkspace` | Guest | Browse the host's workspace file tree. |
| `:LiveShareOpen <path>` | Guest | Open a specific file from the workspace. |
| `:LiveShareFollow [peer_id]` | Both | Follow a peer's active buffer (no arg = follow host). |
| `:LiveShareUnfollow` | Both | Stop following. |
| `:LiveSharePeers` | Both | Show connected participants and their cursor positions. |

After starting the server, wait for the message indicating the URL has been copied to the clipboard. Share that URL with anyone you want to invite.

### Preview

![Live Share Preview](https://raw.githubusercontent.com/azratul/azratul/86d27acdbe36f0d4402a21e13b79fafbaec1ffc9/live-share.gif)

## Configuration

All settings are optional.

```lua
require("live-share").setup({
  username       = "your-name",           -- displayed to other participants
  port_internal  = 9876,                  -- local TCP port for the collab server
  port           = 80,                    -- external tunnel port
  max_attempts   = 40,                    -- URL polling retries (× 250 ms = 10 s)
  service_url    = "/tmp/service.url",    -- temp file where the tunnel writes its URL
  service        = "nokey@localhost.run", -- tunnel provider (see below)
  workspace_root = nil,                   -- defaults to cwd
  debug          = false,                 -- enable verbose logging
})
```

### Tunnel providers

Built-in providers: `"serveo.net"`, `"localhost.run"`, `"nokey@localhost.run"`, `"ngrok"`.

Custom providers can be registered via the provider API:

```lua
require("live-share.provider").register("bore", {
  command = function(_, port, service_url)
    return string.format(
      "bore local %d --to bore.pub > %s 2>/dev/null",
      port, service_url)
  end,
  pattern = "bore%.pub:%d+",
})

require("live-share").setup({ service = "bore" })
```

## Protocol overview

- **Transport**: WebSocket over TCP for HTTP tunnel providers (serveo, localhost.run); raw length-prefixed TCP for direct connections and ngrok. Auto-detected on the first 4 bytes of each connection.
- **Encryption**: `[12-byte nonce][AES-256-GCM ciphertext+tag]` per message when a key is present. Falls back to plaintext JSON if OpenSSL is unavailable.
- **Buffer sync**: line-level last-write-wins. The host assigns a monotonic sequence number to every patch and is the ordering authority.
- **Shared terminal**: PTY I/O streamed over the same encrypted WebSocket connection as all other session events.

## Contributing

Feel free to open issues or submit pull requests.

## License

This project is licensed under the GPL-3.0 License.
