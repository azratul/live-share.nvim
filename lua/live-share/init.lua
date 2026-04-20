-- Entry point: merges user config with defaults and wires modules.
local M = {}

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
}

function M.setup(user_config)
  local cfg = vim.tbl_deep_extend("force", defaults, user_config or {})
  if not cfg.service_url then
    cfg.service_url = default_service_url()
  end

  require("live-share.commands").setup(cfg)
  require("live-share.tunnel").setup(cfg)
end

return M
