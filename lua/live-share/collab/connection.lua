-- Session connection abstraction.
--
-- host.lua and guest.lua program against this interface; the underlying transport
-- (currently TCP + WebSocket via server.lua + client.lua) is an implementation detail.
-- A future backend (QUIC, WebRTC, Iroh, …) only needs to satisfy this contract:
--   - ordered delivery of binary payloads
--   - maximum recommended message size: 10 MB
--   - per-peer or broadcast delivery (listener side)
--   - open / message / close lifecycle callbacks
--
-- ── Listener (host) ───────────────────────────────────────────────────────────
--   conn = connection.new_listener(opts)
--     opts.key    — 32-byte session key, or nil for plaintext
--     opts.on_msg — fn(msg, peer_id)  called for every decoded inbound message
--
--   conn:listen(ip, port)  → true | false
--   conn:send(peer_id, msg)
--   conn:broadcast(msg [, except_peer_id])
--   conn:approve(peer_id)
--   conn:reject(peer_id, error_msg_table)
--   conn:set_role(peer_id, "rw" | "ro")
--   conn:stop()
--
-- ── Connector (guest) ────────────────────────────────────────────────────────
--   conn = connection.new_connector(opts)
--     opts.key    — 32-byte session key, or nil for plaintext
--     opts.mode   — "ws" | "tcp"
--     opts.on_msg — fn(msg)  called for every decoded inbound message
--
--   conn:connect(host, port [, on_error])
--   conn:send(msg)
--   conn:stop()
local M = {}

local server = require("live-share.collab.server")
local client = require("live-share.collab.client")

-- punch_conn is loaded lazily to avoid errors when punch.lua is not installed.
local function punch_conn()
  return require("live-share.collab.punch_conn")
end

-- ── Listener ─────────────────────────────────────────────────────────────────

function M.new_listener(opts)
  server.setup(opts.on_msg)

  local self = {}

  function self:listen(ip, port)
    return server.start(ip, port, opts.key)
  end

  function self:send(peer_id, msg)
    server.send(peer_id, msg)
  end

  function self:broadcast(msg, except_peer)
    server.broadcast(msg, except_peer)
  end

  function self:approve(peer_id)
    server.approve(peer_id)
  end

  function self:reject(peer_id, msg)
    server.reject(peer_id, msg)
  end

  function self:set_role(peer_id, role)
    server.set_role(peer_id, role)
  end

  function self:stop()
    server.stop()
  end

  return self
end

-- ── Connector ────────────────────────────────────────────────────────────────

function M.new_connector(opts)
  client.setup(opts.on_msg)

  local self = {}

  function self:connect(host, port, on_error)
    client.connect(host, tonumber(port), opts.key, opts.mode or "ws", nil, on_error)
  end

  function self:send(msg)
    client.send(msg)
  end

  function self:stop()
    client.stop()
  end

  return self
end

-- ── Punch Listener ───────────────────────────────────────────────────────────

-- new_punch_listener(opts)
-- Same as new_listener but uses direct P2P UDP via punch.lua.
-- The returned object additionally exposes:
--   conn.signaling_port — port of the local HTTP signaling server
function M.new_punch_listener(opts)
  return punch_conn().new_punch_listener(opts)
end

-- ── Punch Connector ───────────────────────────────────────────────────────────

-- new_punch_connector(opts)
-- Same as new_connector but uses direct P2P UDP via punch.lua.
-- connect(signaling_url, _, on_error) — port arg is unused for punch.
function M.new_punch_connector(opts)
  return punch_conn().new_punch_connector(opts)
end

return M
