-- Shared session state.  Mutated by host.lua and guest.lua; read everywhere.

---@alias LiveShare.Message table<string, any> A decoded protocol message (a JSON object); `msg.type` selects the handler.
---@alias LiveShare.PeerId integer Monotonic per-session peer identifier assigned by the host.
---@alias LiveShare.Role "rw"|"ro" Guest permission: read-write or read-only.
---@alias LiveShare.Transport "ws"|"tcp"|"punch" Wire transport backend.

---Shared, mutable session state. A singleton mutated by host/guest and read everywhere.
---@class LiveShare.Session
---@field id string|nil session id (hex string), set by the host
---@field role "host"|"guest"|nil current role, or nil when no session is active
---@field key string|nil 32-byte AES-256-GCM session key, or nil for plaintext
---@field peer_id LiveShare.PeerId|nil own peer_id assigned by the host (guest only)
---@field sid string|nil session id received from the host (guest only; equals the host's `id`)
---@field transport LiveShare.Transport|nil effective transport for this session; set by the guest on connect
---@field host_required_caps string[] caps the host requires; the client must support all of these
---@field host_optional_caps string[] caps the host supports but that the client may skip
local M = {}

M.id = nil -- session id (hex string), set by host
M.role = nil -- "host" | "guest" | nil
M.key = nil -- 32-byte AES-256-GCM key, or nil (no encryption)
M.peer_id = nil -- own peer_id assigned by host (guest only)
M.sid = nil -- session id received from host (guest only; same as host's M.id)
M.transport = nil -- effective transport used for this session ("ws" | "tcp" | "punch"); set by guest on connect
M.host_required_caps = {} -- caps the host requires; client must support all of these
M.host_optional_caps = {} -- caps the host supports but that the client may skip

---Whether a session (host or guest) is currently active.
---@return boolean
function M.active()
  return M.role ~= nil
end

---Clear all session state back to "no active session".
function M.reset()
  M.id = nil
  M.role = nil
  M.key = nil
  M.peer_id = nil
  M.sid = nil
  M.transport = nil
  M.host_required_caps = {}
  M.host_optional_caps = {}
end

return M
