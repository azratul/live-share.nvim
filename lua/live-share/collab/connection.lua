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

---Options for `new_listener` / `new_punch_listener`.
---@class LiveShare.ListenerOpts
---@field key string|nil 32-byte session key, or nil for plaintext
---@field on_msg fun(msg: LiveShare.Message, peer_id: LiveShare.PeerId) called for every decoded inbound message

---Options for `new_connector` / `new_punch_connector`.
---@class LiveShare.ConnectorOpts
---@field key string|nil 32-byte session key, or nil for plaintext
---@field mode? LiveShare.Transport transport mode for the WS/TCP backend; defaults to "ws"
---@field on_msg fun(msg: LiveShare.Message) called for every decoded inbound message

local M = {}

local server = require("live-share.collab.server")
local client = require("live-share.collab.client")

-- punch_conn is loaded lazily to avoid errors when punch.lua is not installed.
local function punch_conn()
  return require("live-share.collab.punch_conn")
end

-- ── Listener ─────────────────────────────────────────────────────────────────

---Create a host-side listener over the WebSocket/TCP backend.
---@param opts LiveShare.ListenerOpts
---@return LiveShare.Listener
function M.new_listener(opts)
  server.setup(opts.on_msg)

  ---The host side of a session: accepts peers, manages approval/roles, broadcasts.
  ---@class LiveShare.Listener
  local self = {}

  ---Start listening for incoming peers.
  ---@param ip string bind address
  ---@param port integer bind port
  ---@return boolean ok true if the server started
  function self:listen(ip, port)
    return server.start(ip, port, opts.key)
  end

  ---Send a message to a single peer.
  ---@param peer_id LiveShare.PeerId
  ---@param msg LiveShare.Message
  function self:send(peer_id, msg)
    server.send(peer_id, msg)
  end

  ---Broadcast a message to all approved peers.
  ---@param msg LiveShare.Message
  ---@param except_peer? LiveShare.PeerId peer to exclude from the broadcast
  function self:broadcast(msg, except_peer)
    server.broadcast(msg, except_peer)
  end

  ---Approve a pending peer, moving it into the active client set.
  ---@param peer_id LiveShare.PeerId
  function self:approve(peer_id)
    server.approve(peer_id)
  end

  ---Reject a pending peer and close its connection.
  ---@param peer_id LiveShare.PeerId
  ---@param msg LiveShare.Message reason payload sent to the peer before closing
  function self:reject(peer_id, msg)
    server.reject(peer_id, msg)
  end

  ---Change a peer's permission role.
  ---@param peer_id LiveShare.PeerId
  ---@param role LiveShare.Role
  function self:set_role(peer_id, role)
    server.set_role(peer_id, role)
  end

  ---Set a peer's display name.
  ---@param peer_id LiveShare.PeerId
  ---@param name string
  function self:set_name(peer_id, name)
    server.set_name(peer_id, name)
  end

  ---Forcibly disconnect an approved peer.
  ---@param peer_id LiveShare.PeerId
  ---@return boolean ok true if a matching peer was found and kicked
  function self:kick(peer_id)
    return server.kick(peer_id)
  end

  ---Stop the listener and close all connections.
  function self:stop()
    server.stop()
  end

  return self
end

-- ── Connector ────────────────────────────────────────────────────────────────

---Create a guest-side connector over the WebSocket/TCP backend.
---@param opts LiveShare.ConnectorOpts
---@return LiveShare.Connector
function M.new_connector(opts)
  client.setup(opts.on_msg)

  ---The guest side of a session: connects to a host and exchanges messages.
  ---@class LiveShare.Connector
  local self = {}

  ---Connect to a host (with exponential-backoff reconnect handled internally).
  ---@param host string host address
  ---@param port integer|string host port (coerced with tonumber)
  ---@param on_error? fun() called when all reconnect retries are exhausted or DNS fails
  function self:connect(host, port, on_error)
    client.connect(host, tonumber(port), opts.key, opts.mode or "ws", nil, on_error)
  end

  ---Send a message to the host.
  ---@param msg LiveShare.Message
  function self:send(msg)
    client.send(msg)
  end

  ---Disconnect and tear down the connector.
  function self:stop()
    client.stop()
  end

  return self
end

-- ── Punch Listener ───────────────────────────────────────────────────────────

---Same as `new_listener` but over direct P2P UDP via punch.lua.
---The returned object additionally exposes `conn.signaling_port` — the port of
---the local HTTP signaling server used during the handshake phase.
---@param opts LiveShare.ListenerOpts
---@return LiveShare.Listener
function M.new_punch_listener(opts)
  return punch_conn().new_punch_listener(opts)
end

-- ── Punch Connector ───────────────────────────────────────────────────────────

---Same as `new_connector` but over direct P2P UDP via punch.lua.
---Its `connect(signaling_url, _, on_error)` ignores the port argument.
---@param opts LiveShare.ConnectorOpts
---@return LiveShare.Connector
function M.new_punch_connector(opts)
  return punch_conn().new_punch_connector(opts)
end

return M
