local M = {}

local get_default_service_url = function()
  local temp_dir

  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    temp_dir = os.getenv("TEMP")
  else
    temp_dir = os.getenv("TMPDIR") or "/tmp"
  end

  return temp_dir .. "/service.url"
end

function M.setup(config)
  config = config or {}
  M.config = {
    port = config.port or 80,
    port_internal = config.port_internal or 9876,
    max_attempts = config.max_attempts or 40,
    service_url = config.service_url or get_default_service_url(),
    service = config.service or "nokey@localhost.run",
    ip_local = config.ip_local or "127.0.0.1",
    ssh_pid = nil,
  }

  require("live-share.instant").setup(M.config)
  require("live-share.tunnel").setup(M.config)
  require("live-share.commands").setup(M.config)
end

return M
