-- Entry point: merges user config with defaults and wires modules.

---User-facing configuration, as passed to `require("live-share").setup(opts)`.
---All fields are optional; unset fields fall back to the documented defaults.
---@class LiveShare.Config
---@field port_internal? integer local TCP port for the collab server (default 9876)
---@field port? integer external tunnel port (default 80)
---@field max_attempts? integer URL-polling retries before giving up (default 40)
---@field service? string active tunnel provider (default "nokey@localhost.run")
---@field service_url? string path of the temp file the tunnel writes its URL to; defaults to an OS temp path
---@field ip_local? string local bind address (default "127.0.0.1")
---@field username? string display name; falls back to `vim.g.live_share_username`
---@field workspace_root? string host workspace root; defaults to the cwd
---@field debug? boolean enable debug logging (default false)
---@field openssl_lib? string explicit path to libcrypto when auto-detection fails
---@field transport? LiveShare.Transport transport backend: "ws" (default) or "punch"
---@field stun? string STUN server used when transport = "punch" (default "stun.l.google.com:19302")
---@field allow_sensitive_files? boolean serve sensitive files (.env, keys, …) instead of hiding them (default false)
---@field extra_sensitive_patterns? string[] extra Lua patterns appended to the sensitive-file filter
---@field audit_log? boolean|string enable the JSONL audit log (default true), or a string path to override its location
---@field scan_use_gitignore? boolean use `git ls-files` for a gitignore-aware listing when possible (default true)
---@field scan_max_files? integer hard cap on files in `workspace_info`; <=0 disables the cap (default 50000)
---@field scan_max_depth? integer max recursion depth for the manual workspace walker (default 20)
---@field scan_extra_ignore? string[] extra directory basenames to skip during the manual walk
---@field terminal_scrollback_bytes? integer bytes of shared-terminal scrollback replayed to late joiners; 0 disables (default 65536)

local M = {}

---@type LiveShare.Config|nil
local _config = nil

local function default_service_url()
  local dir = (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and os.getenv("TEMP")
    or (os.getenv("TMPDIR") or "/tmp")
  return dir .. "/live-share-service.url"
end

local defaults = {
  port_internal = 9876, -- local TCP port for the collab server
  port = 80, -- external tunnel port
  max_attempts = 40, -- URL polling retries
  service = "nokey@localhost.run", -- active tunnel provider
  service_url = nil, -- filled below from default_service_url()
  ip_local = "127.0.0.1",
  username = nil, -- display name; falls back to vim.g.live_share_username
  workspace_root = nil, -- host workspace root; defaults to cwd
  debug = false,
  -- Explicit path to libcrypto, for systems where auto-detection fails.
  -- Examples:
  --   NixOS:  "/nix/store/xxxx-openssl-3.x/lib/libcrypto.so.3"
  --   custom: "/usr/local/lib/libcrypto.so.3"
  openssl_lib = nil,
  -- Transport backend: "ws" (WebSocket over TCP tunnel, default) or "punch"
  -- (direct P2P UDP via punch.lua — tunnel used only for the handshake phase).
  transport = "ws",
  -- STUN server used when transport = "punch".
  stun = "stun.l.google.com:19302",
  -- Sandbox: when true, sensitive files (.env, SSH keys, .aws creds, *.pem,
  -- *.key, …) are listed and served as if they didn't exist.  Defaults to true.
  -- Set `allow_sensitive_files = true` to disable the filter.
  allow_sensitive_files = false,
  -- Extra Lua patterns appended to the sensitive-file filter (matched against
  -- the workspace-relative path, with forward slashes).
  -- Example: { "%.tfstate$", "/secrets/" }
  extra_sensitive_patterns = nil,
  -- Audit log: append-only JSONL log of session events (joins, leaves, file
  -- requests, denials, role changes, kicks).  Set to false to disable, or to a
  -- string path to override the default location.
  audit_log = true,
  -- Workspace scan tuning (host-side; doesn't change the protocol).
  -- `scan_use_gitignore`: when the workspace is a git repo, use `git ls-files`
  -- to get a fast, gitignore-aware listing.  Falls back to a manual walk if
  -- git isn't available or fails.
  scan_use_gitignore = true,
  -- Hard cap on the number of files included in `workspace_info`.  Protects
  -- the editor from monorepos with hundreds of thousands of files.  Set to 0
  -- (or any non-positive number) to disable the cap entirely.  When the cap
  -- is hit, the host gets a one-time `vim.notify` warning so the truncation
  -- isn't silent.
  scan_max_files = 50000,
  -- Maximum directory recursion depth for the manual walker (git mode is not
  -- depth-limited — git already excludes ignored subtrees).
  scan_max_depth = 20,
  -- Extra directory basenames to skip during the manual walk.  Stacked on top
  -- of the built-in list (.git, node_modules, target, .venv, dist, build, …).
  -- Example: { "fixtures", "snapshots" }
  scan_extra_ignore = nil,
  -- Shared-terminal scrollback budget (host-side).  When a guest is approved
  -- after a `:LiveShareTerminal` was opened, the host replays up to this many
  -- bytes of recent shell output so the guest sees prior context instead of a
  -- blank screen.  Set to 0 to disable the replay.
  terminal_scrollback_bytes = 65536,
}

---Merge user config over the defaults and wire up the plugin's modules.
---@param user_config? LiveShare.Config
function M.setup(user_config)
  local cfg = vim.tbl_deep_extend("force", defaults, user_config or {})
  if not cfg.service_url then
    cfg.service_url = default_service_url()
  end
  _config = cfg

  require("live-share.commands").setup(cfg)
  require("live-share.tunnel").setup(cfg)
end

---Return the merged, active configuration, or nil if `setup` hasn't run.
---@return LiveShare.Config|nil
function M.get_config()
  return _config
end

return M
