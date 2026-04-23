# Contributing to live-share.nvim

Contributions are welcome. The most useful things to contribute right now:

- **Bug reports** — especially for `punch` P2P transport and cross-platform encryption issues
- **Bug fixes** — open an issue first for anything non-trivial to align on approach
- **Test coverage** — integration tests for edge cases described in `PROTOCOL.md`
- **Documentation** — troubleshooting steps, configuration examples, platform-specific notes
- **Protocol clients** — if you're building a live-share.nvim client for another editor, open an issue; protocol feedback and compatibility testing are welcome

For large features or protocol changes, open an issue before writing code.

## Requirements

- Neovim 0.9+
- OpenSSL (`libcrypto`)
- [StyLua](https://github.com/JohnnyMorganz/StyLua) for formatting
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for running tests

## Development setup

Clone the repository and add the plugin to your Neovim runtime for local development:

```lua
-- lazy.nvim — point to your local clone
{ dir = "~/path/to/live-share.nvim" }
```

Enable debug logging to get detailed output during development:

```lua
require("live-share").setup({ debug = true })
```

## Code style

All Lua code must be formatted with StyLua using the project config:

```bash
stylua lua/ plugin/
```

To check without modifying files:

```bash
stylua --check lua/ plugin/
```

Style settings (`stylua.toml`): 2-space indentation, 120-column line width.

## Running tests

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) and require it on the runtime path.

**One-time setup:**

```bash
git clone --depth 1 https://github.com/nvim-lua/plenary.nvim \
  ~/.local/share/nvim/site/pack/vendor/start/plenary.nvim
```

**Run the full suite:**

```bash
nvim --headless \
  -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

**Run a single file:**

```bash
nvim --headless \
  -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/protocol/protocol_spec.lua"
```

Network behaviour (TCP connect, WebSocket handshake, broadcast, AES-256-GCM encryption end-to-end) is covered by the integration tests in `tests/integration/`. Neovim UI interactions (remote cursor extmarks, `vim.ui.select` approval prompts, buffer rendering) still require two running Neovim instances and must be tested manually.

## Manual testing

You need two Neovim instances: one host, one guest.

```
# Instance 1 (host)
:LiveShareServer

# Instance 2 (guest) — paste the URL copied by the host
:LiveShareJoin <url>
```

Test the golden path: open a file, edit it on the host, confirm the patch appears on the guest. Move the cursor on the host and confirm the remote cursor extmark appears on the guest.

## Protocol changes

The wire protocol is documented in [`PROTOCOL.md`](PROTOCOL.md). The current version is tracked in `lua/live-share/collab/protocol.lua` as `M.VERSION`.

**Rules for protocol changes:**

1. Backward-compatible additions (new optional fields, new message types): increment the minor version in the `PROTOCOL.md` header. No change to `M.VERSION`.
2. Breaking changes (removed fields, changed semantics, new required fields): increment `M.VERSION`. Update `PROTOCOL.md`. Add a compatibility note to `CHANGELOG.md`.
3. Any change to `M.VERSION` must also be reflected in the VS Code client at [`open-pair`](https://github.com/darkerthanblack2000/open-pair) — coordinate before merging.

**Protocol fixtures** live in `tests/fixtures/`. When adding a new message type, add a corresponding fixture file and a test in `tests/protocol/protocol_spec.lua`.

## Reporting bugs

Include the following in bug reports:

1. Output of `:checkhealth live-share`
2. Debug log from both host and guest (enable with `debug = true` in `setup()`, then `:messages`)
3. Neovim version (`:version`)
4. OS and how OpenSSL / punch are installed

For `punch` P2P issues, also include the tunnel service being used and whether the error mentions relay or only direct candidates.

## Submitting changes

- Open an issue first for non-trivial changes to align on design before writing code.
- Keep pull requests focused: one feature or fix per PR.
- Protocol changes require updating `PROTOCOL.md` and `CHANGELOG.md` in the same PR.
- All CI checks (style, tests) must pass.

**PR checklist:**

- [ ] `stylua --check lua/ plugin/` passes
- [ ] Full test suite passes (see [Running tests](#running-tests))
- [ ] New message types have a fixture in `tests/fixtures/` and a test in `tests/protocol/`
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] `PROTOCOL.md` updated if the wire format changed
