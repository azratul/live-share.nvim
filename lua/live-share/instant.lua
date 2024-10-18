local M = {}

function M.setup(config)
  M.config = config
end

function M.start(port)
  port = port or M.config.port_internal

  vim.cmd("InstantStartServer " .. M.config.ip_local .. " " .. port)
  vim.cmd("InstantStartSession " .. M.config.ip_local .. " " .. port)
end

function M.join(url, port)
  url = url:gsub("^https?://", "")
  port = port or M.config.port
  vim.cmd("InstantJoinSession " .. url .. " " .. port)
end

return M
