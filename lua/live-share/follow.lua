-- Follow mode: automatically navigate to whatever file a specific peer
-- is currently focused on.  Opt-in; disabled by default.
--
-- followed_peer = nil  → follow mode OFF
-- followed_peer = 0    → follow the host (peer 0)
-- followed_peer = N    → follow guest with peer_id N
local M = {}

local followed_peer = nil
local on_follow = nil -- fn(path, lnum, col) — executes the actual buffer switch

---Set the callback that executes the actual buffer switch.  `lnum`/`col` may be
---nil (only `path` is required).
---@param cb fun(path: string, lnum: integer|nil, col: integer|nil)
function M.setup(cb)
  on_follow = cb
end

---Enable follow mode for a peer (0 = host).
---@param peer_id LiveShare.PeerId
function M.set_follow(peer_id)
  followed_peer = peer_id
  local label = peer_id == 0 and "host" or ("peer " .. tostring(peer_id))
  vim.notify("live-share: follow mode ON — following " .. label, vim.log.levels.INFO)
end

---Turn follow mode off.
function M.disable()
  followed_peer = nil
  vim.notify("live-share: follow mode OFF", vim.log.levels.INFO)
end

---Toggle follow mode: disable if on, else follow `peer_id` (default host).
---@param peer_id? LiveShare.PeerId
function M.toggle(peer_id)
  if followed_peer ~= nil then
    M.disable()
  else
    M.set_follow(peer_id or 0)
  end
end

---Whether follow mode is currently active.
---@return boolean
function M.is_enabled()
  return followed_peer ~= nil
end

---The peer currently being followed, or nil.
---@return LiveShare.PeerId|nil
function M.get_followed_peer()
  return followed_peer
end

---Called from message handlers when a peer changes active file or cursor.
---Triggers the callback only when that peer is the one being followed.
---@param path string workspace-relative path
---@param lnum integer|nil
---@param col integer|nil
---@param from_peer LiveShare.PeerId the peer the event came from
function M.maybe_follow(path, lnum, col, from_peer)
  if followed_peer ~= nil and from_peer == followed_peer and on_follow then
    on_follow(path, lnum, col)
  end
end

---Reset follow state (session ended).
function M.reset()
  followed_peer = nil
  on_follow = nil
end

return M
