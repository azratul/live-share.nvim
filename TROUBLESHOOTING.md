# Troubleshooting

Run `:checkhealth live-share` first — it catches the most common configuration problems automatically.

---

## Session won't start

### "OpenSSL libcrypto not found"

Encryption is required. The plugin looks for `libcrypto` in standard system paths.

| Platform | Fix |
|----------|-----|
| Ubuntu / Debian | `sudo apt install libssl-dev` |
| Arch / Manjaro | `sudo pacman -S openssl` |
| Fedora / RHEL | `sudo dnf install openssl-devel` |
| macOS | `brew install openssl` |
| Windows | Install [Win32 OpenSSL](https://slproweb.com/products/Win32OpenSSL.html) |
| NixOS | Set `openssl_lib` explicitly (see below) |

If OpenSSL is installed but not found (custom paths, NixOS, Homebrew):

```lua
require("live-share").setup({
  openssl_lib = "/path/to/libcrypto.so.3",
  -- examples:
  -- NixOS: "/nix/store/xxxx-openssl-3.x/lib/libcrypto.so.3"
  -- Homebrew arm64: "/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib"
  -- Homebrew x86: "/usr/local/opt/openssl@3/lib/libcrypto.dylib"
})
```

To find the path: `find /nix /opt /usr -name "libcrypto*" 2>/dev/null | head -5`

### "LuaJIT FFI not available"

Your Neovim build was compiled without LuaJIT. Install a standard Neovim binary from
[neovim.io](https://neovim.io) or your package manager — do not use the `--with-lua` PUC Lua build.

---

## Tunnel not connecting

### URL never copied to clipboard

The plugin polls a temp file for the tunnel URL. If the tunnel process fails silently, the URL never appears.

1. Check the tunnel binary is in PATH: `:checkhealth live-share`
2. Try the tunnel command manually:
   ```bash
   ssh -R 80:localhost:9876 nokey@localhost.run
   ```
   If it hangs or errors, the problem is with SSH or the tunnel service, not the plugin.
3. If you're behind a corporate firewall, port 22/80 may be blocked. Try `ngrok` instead:
   ```lua
   require("live-share").setup({ service = "ngrok" })
   ```

---

### Tunnel connects but guests can't reach the URL

Some networks block the ports used by tunnel services. Switch providers:

```lua
-- Try in order until one works
service = "nokey@localhost.run"  -- port 80
service = "serveo.net"           -- port 80
service = "ngrok"                -- port configurable
service = "bore"                 -- port configurable
```

---

## Guest can't connect

### "Connection refused" immediately

The host's tunnel hasn't finished starting. Wait for the "URL copied to clipboard" message before sharing the URL.

### Session appears to connect but no content appears

The guest may be running a different plugin version. Check that both sides are on the same release:

```vim
:echo require("live-share").version
```

Protocol v3 peers are not compatible with v1/v2 peers.

### Wrong key / decryption fails

The URL must be shared exactly as copied — the `#key=...` fragment is the encryption key. If the URL was truncated (some chat apps strip fragments), the session will fail to decrypt. Share via a plain-text channel or paste tool.

---

## P2P punch transport

### "punch library not found"

```bash
luarocks install punch
```

Or via lazy.nvim + luarocks.nvim (recommended — pins the version):

```lua
{ "vhyrro/luarocks.nvim", opts = { rocks = { "punch >= 0.3.2" } } }
```

### "all N candidate pairs failed" — no relay

All NAT traversal attempts failed, including the relay fallback. Check:

1. **punch version** — relay fallback requires ≥ 0.3.2:
   ```bash
   luarocks show punch | grep version
   ```
2. **Signaling URL reachable** — the guest must be able to reach the `punch+https://...` URL. Open it in a browser: you should get a JSON response. If not, the tunnel is the problem, not punch.
3. **Enable debug logging** to see which candidate pairs were tried:
   ```lua
   require("live-share").setup({ debug = true })
   ```
   Then check `:messages` after the failure.

### Relay fallback fails after direct pairs fail

This usually means the relay broker (hosted on the signaling server) was unreachable. Known causes:

- `punch` < 0.3.2 on the host (signaling server bound to `0.0.0.0` instead of `127.0.0.1`)
- The tunnel service used is `https://` but the relay was connecting to `ws://`

Update both sides to punch ≥ 0.3.2.

### Running inside a container (Docker, Podman, etc.)

Containers assign internal IPs (e.g. `172.17.0.0/16`) that appear as host candidates in ICE but are unreachable from the outside. punch ≥ 0.3.2 handles this automatically: it learns the real peer address from the first decrypted packet (peer-reflexive candidate) and updates the channel accordingly. If you're on an older version, upgrade:

```bash
luarocks install punch
```

If direct hole-punching still fails from inside a container, the relay fallback will kick in automatically — no extra configuration needed.

### P2P connects but drops immediately

The punch channel has a keepalive mechanism. If packets are filtered by a firewall after the initial hole-punch, the channel will close. Fall back to `ws` transport for environments with strict egress filtering.

---

## Performance and sync issues

### Edits lag or appear out of order

The `ws` transport uses TCP which guarantees ordering. For high-latency connections (> 200 ms), the conflict window for same-line edits is larger — see [§3 of PROTOCOL.md](./PROTOCOL.md#3-synchronization-strategy). This is a known limitation of the LWW sync model.

### Remote cursors not appearing

Extmarks require the buffer to be loaded on the guest side. Open the file via `:LiveShareOpen <path>` before expecting cursor events.

---

## Getting more information

Enable debug logging and reproduce the issue:

```lua
require("live-share").setup({ debug = true })
```

Logs appear in `:messages`. To capture them:

When reporting a bug, include:
- Output of `:checkhealth live-share`
- Debug log from both host and guest
- Neovim version (`:version`)
- OS and how punch/OpenSSL are installed
