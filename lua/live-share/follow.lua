-- Follow mode: automatically navigate to whatever file a specific peer
-- is currently focused on.  Opt-in; disabled by default.
--
-- followed_peer = nil  → follow mode OFF
-- followed_peer = 0    → follow the host (peer 0)
-- followed_peer = N    → follow guest with peer_id N
local M = {}

local followed_peer = nil
local on_follow     = nil   -- fn(path, lnum, col) — executes the actual buffer switch

-- Set the callback that executes the actual buffer switch.
-- lnum and col may be nil (only path is required).
function M.setup(cb)
  on_follow = cb
end

function M.set_follow(peer_id)
  followed_peer = peer_id
  local label = peer_id == 0 and "host" or ("peer " .. tostring(peer_id))
  vim.notify("live-share: follow mode ON — following " .. label, vim.log.levels.INFO)
end

function M.disable()
  followed_peer = nil
  vim.notify("live-share: follow mode OFF", vim.log.levels.INFO)
end

function M.toggle(peer_id)
  if followed_peer ~= nil then
    M.disable()
  else
    M.set_follow(peer_id or 0)
  end
end

function M.is_enabled()
  return followed_peer ~= nil
end

function M.get_followed_peer()
  return followed_peer
end

-- Called from message handlers when a peer changes active file or cursor.
-- Only triggers the callback when that peer is the one being followed.
function M.maybe_follow(path, lnum, col, from_peer)
  if followed_peer ~= nil and from_peer == followed_peer and on_follow then
    on_follow(path, lnum, col)
  end
end

function M.reset()
  followed_peer = nil
  on_follow     = nil
end

return M
