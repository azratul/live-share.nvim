if vim.g.loaded_liveshare then
  return
end
vim.g.loaded_liveshare = true

local save_cpo = vim.o.cpo
vim.o.cpo = vim.o.cpo .. "vim"

local cmd = vim.api.nvim_create_user_command

-- :LiveShareHostStart [port]
cmd("LiveShareHostStart", function(opts)
  local port = opts.args ~= "" and tonumber(opts.args) or nil
  require("live-share.commands").host_start(port)
end, {
  nargs = "?",
  desc = "Start hosting a Live Share session",
})

-- :LiveShareJoin <url> [port]
cmd("LiveShareJoin", function(opts)
  local args = vim.split(opts.args, "%s+")
  require("live-share.commands").join(args[1], tonumber(args[2]))
end, {
  nargs = "+",
  desc = "Join a Live Share session by URL",
})

-- :LiveShareStop
cmd("LiveShareStop", function()
  require("live-share.commands").stop()
end, {
  desc = "Stop the active Live Share session",
})

-- :LiveShareFollow [peer_id]
cmd("LiveShareFollow", function(opts)
  local arg = opts.args ~= "" and opts.args or nil
  require("live-share.commands").follow(arg)
end, {
  nargs = "?",
  desc = "Follow a peer: no arg = host, or :LiveShareFollow <peer_id>",
  complete = function(arg_lead)
    local ok, presence = pcall(require, "live-share.presence")
    if not ok then
      return {}
    end
    local result = {}
    for _, p in ipairs(presence.get_all()) do
      local s = tostring(p.peer_id)
      if arg_lead == "" or s:find(arg_lead, 1, true) then
        result[#result + 1] = s
      end
    end
    return result
  end,
})

-- :LiveShareUnfollow
cmd("LiveShareUnfollow", function()
  require("live-share.commands").follow_disable()
end, {
  desc = "Disable follow mode",
})

-- :LiveShareWorkspace
cmd("LiveShareWorkspace", function()
  require("live-share.commands").open_workspace()
end, {
  desc = "Open the remote workspace tree explorer (guest only)",
})

-- :LiveSharePeers
cmd("LiveSharePeers", function()
  require("live-share.commands").show_peers()
end, {
  desc = "Show all session peers and their positions",
})

-- :LiveShareOpen <path>
cmd("LiveShareOpen", function(opts)
  require("live-share.commands").open_file(opts.args)
end, {
  nargs = 1,
  desc = "Open a remote file from the workspace (guest only)",
  complete = function(arg_lead)
    local ok, commands = pcall(require, "live-share.commands")
    if not ok then
      return {}
    end
    return commands.complete_workspace_path(arg_lead)
  end,
})

-- :LiveShareTerminal
cmd("LiveShareTerminal", function()
  require("live-share.commands").terminal()
end, {
  desc = "Open a shared terminal (host: spawns shell; guest: connects automatically)",
})

-- :LiveShareDebugInfo
cmd("LiveShareDebugInfo", function()
  require("live-share.commands").debug_info()
end, {
  desc = "Open a scratch buffer with debug info for bug reports",
})

-- :LiveShareServer is a deprecated alias for :LiveShareHostStart (renamed in v2.0.0)
cmd("LiveShareServer", function(opts)
  vim.notify("live-share: :LiveShareServer is deprecated, use :LiveShareHostStart", vim.log.levels.WARN)
  local port = opts.args ~= "" and tonumber(opts.args) or nil
  require("live-share.commands").host_start(port)
end, {
  nargs = "?",
  desc = "Deprecated alias for :LiveShareHostStart",
})

vim.o.cpo = save_cpo
