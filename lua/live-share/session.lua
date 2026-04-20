-- Shared session state.  Mutated by host.lua and guest.lua; read everywhere.
local M = {}

M.id = nil -- session id (hex string), set by host
M.role = nil -- "host" | "guest" | nil
M.key = nil -- 32-byte AES-256-GCM key, or nil (no encryption)
M.peer_id = nil -- own peer_id assigned by host (guest only)
M.sid = nil -- session id received from host (guest only; same as host's M.id)
M.host_required_caps = {} -- caps the host requires; client must support all of these
M.host_optional_caps = {} -- caps the host supports but that the client may skip

function M.active()
  return M.role ~= nil
end

function M.reset()
  M.id = nil
  M.role = nil
  M.key = nil
  M.peer_id = nil
  M.sid = nil
  M.host_required_caps = {}
  M.host_optional_caps = {}
end

return M
