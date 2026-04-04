-- Command handlers: bridge between user commands and host/guest modules.
local M = {}

local function host()    return require("live-share.host")    end
local function guest()   return require("live-share.guest")   end
local function follow()  return require("live-share.follow")  end
local function ui()      return require("live-share.ui")      end
local function session() return require("live-share.session") end
local function tunnel()  return require("live-share.tunnel")  end

function M.setup(config)
  M.config = config
end

-- :LiveShareHostStart [port]
function M.host_start(port)
  if session().active() then
    vim.notify("live-share: session already active — run :LiveShareStop first", vim.log.levels.WARN)
    return
  end
  local h = host()
  h.setup(M.config)
  if not h.start(port) then return end
  tunnel().start(port or M.config.port_internal)
end

-- :LiveShareJoin <url> [port]
function M.join(url, port)
  if session().active() then
    vim.notify("live-share: session already active — run :LiveShareStop first", vim.log.levels.WARN)
    return
  end
  port = port or M.config.port

  local key_b64 = url:match("#key=([A-Za-z0-9_%-]+)")
  url = url:gsub("#.*$", "")

  local mode
  if url:match("^tcp://") then
    local h, p = url:match("^tcp://([^:]+):(%d+)")
    url  = h
    port = tonumber(p)
    mode = "tcp"
  elseif url:match("^https?://") then
    url  = url:gsub("^https?://", "")
    mode = "ws"
  elseif url:match("^[%w._%-]+:%d+$") then
    -- bare host:port without scheme (e.g. bore.pub:12345)
    local h, p = url:match("^([^:]+):(%d+)")
    url  = h
    port = tonumber(p)
    mode = "ws"
  else
    mode = "ws"
  end

  local g = guest()
  g.setup(M.config)
  g.connect(url, port, key_b64, mode)
end

-- :LiveShareStop
function M.stop()
  if not session().active() then
    vim.api.nvim_err_writeln("live-share: no active session")
    return
  end
  local role = session().role
  if role == "host" then
    host().stop()
    tunnel().stop()
  elseif role == "guest" then
    guest().stop()
  end
  vim.api.nvim_out_write("live-share: session stopped\n")
end

-- :LiveShareFollow [peer_id]
-- No arg → follow the host (peer 0). With peer_id → follow that specific peer.
function M.follow(peer_id_str)
  if not session().active() then
    vim.notify("live-share: not in a session", vim.log.levels.WARN)
    return
  end
  local peer_id = peer_id_str and tonumber(peer_id_str) or 0
  if session().role == "host" and peer_id == 0 then
    vim.notify("live-share: you are the host — cannot follow yourself (peer 0)", vim.log.levels.WARN)
    return
  end
  follow().set_follow(peer_id)
end

-- :LiveShareUnfollow
function M.follow_disable()
  follow().disable()
end

-- :LiveShareWorkspace
function M.open_workspace()
  if session().role ~= "guest" then
    vim.notify("live-share: :LiveShareWorkspace is only available for guests", vim.log.levels.WARN)
    return
  end
  ui().open_workspace_explorer()
end

-- :LiveSharePeers
function M.show_peers()
  if not session().active() then
    vim.notify("live-share: not in a session", vim.log.levels.WARN)
    return
  end
  ui().show_peers()
end

-- :LiveShareOpen <path>
function M.open_file(path)
  if session().role ~= "guest" then
    vim.notify("live-share: :LiveShareOpen is only available for guests", vim.log.levels.WARN)
    return
  end
  if not path or path == "" then
    vim.notify("live-share: usage: :LiveShareOpen <workspace/relative/path>", vim.log.levels.WARN)
    return
  end
  guest().request_file(path)
end

-- :LiveShareTerminal
function M.terminal()
  if not session().active() then
    vim.notify("live-share: not in a session", vim.log.levels.WARN)
    return
  end
  if session().role == "host" then
    host().open_terminal()
  else
    vim.notify(
      "live-share: the host opens shared terminals — they appear automatically when ready",
      vim.log.levels.INFO)
  end
end

-- Tab-completion helper for :LiveShareOpen.
function M.complete_workspace_path(arg_lead)
  local ok, g = pcall(require, "live-share.guest")
  if not ok then return {} end
  local files = g.get_workspace_files()
  if arg_lead == "" then return files end
  return vim.tbl_filter(function(f) return f:find(arg_lead, 1, true) ~= nil end, files)
end

return M
