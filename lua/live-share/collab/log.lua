-- Shared debug logger for the collab layer.
-- Set M.enabled = true (via config.debug) to show debug notifications.
local M = {}

M.enabled = false

function M.dbg(prefix, msg)
  if not M.enabled then
    return
  end
  vim.schedule(function()
    vim.notify("[live-share " .. prefix .. "] " .. msg, vim.log.levels.INFO)
  end)
end

return M
