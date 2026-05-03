-- Entry point: merges user config with defaults and wires modules.
local M = {}

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
  -- the editor from monorepos with hundreds of thousands of files.
  scan_max_files = 10000,
  -- Maximum directory recursion depth for the manual walker (git mode is not
  -- depth-limited — git already excludes ignored subtrees).
  scan_max_depth = 8,
  -- Extra directory basenames to skip during the manual walk.  Stacked on top
  -- of the built-in list (.git, node_modules, target, .venv, dist, build, …).
  -- Example: { "fixtures", "snapshots" }
  scan_extra_ignore = nil,
}

function M.setup(user_config)
  local cfg = vim.tbl_deep_extend("force", defaults, user_config or {})
  if not cfg.service_url then
    cfg.service_url = default_service_url()
  end
  _config = cfg

  require("live-share.commands").setup(cfg)
  require("live-share.tunnel").setup(cfg)
end

function M.get_config()
  return _config
end

return M
