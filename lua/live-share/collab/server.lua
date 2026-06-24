-- TCP server: accepts connections, auto-detects WS or raw TCP, broadcasts patches.
--
-- Protocol auto-detection (first 4 bytes):
--   "GET " → WebSocket mode (HTTP tunnel providers: serveo, localhost.run)
--   other  → raw TCP mode  (direct connections, ngrok tcp://)
--
-- Each peer is assigned a transport adapter at detection time:
--   peer.framer(payload) → framed bytes   (mode-specific, set once)
--   peer.reader          → stateful fn    (mode-specific, set once)
-- The upper layer only deals with encode/decode via protocol.lua.
--
-- Approval flow:
--   On connect, the peer enters `pending` and a synthetic "connect" event fires.
--   The host calls M.approve(peer_id) or M.reject(peer_id, msg) to proceed.
--   Only approved peers (in `clients`) receive broadcasts and can send patches.
local M = {}

local rate_limit = require("live-share.collab.rate_limit")
local peer_session = require("live-share.collab.peer_session")
local log = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local srv = nil
local pending = {} -- peer_id -> { handle, framer, mode, pending_timer }  (awaiting host approval)
local clients = {} -- peer_id -> { handle, framer, mode }  (approved peers)
local peer_roles = {} -- peer_id -> "rw" | "ro"
local peer_names = {} -- peer_id -> name (for synthesising bye on abrupt disconnect)
local last_seen = {} -- peer_id -> ms timestamp of last byte received from peer
local heartbeat_timer = nil
local next_peer = 1
local on_message = nil
local session_key = nil

-- Shared peer registry handed to each per-connection peer_session.  These
-- tables are mutated in place (never reassigned — see M.stop) so the reference
-- stays valid for every live connection.  The per-connection state machine
-- (transport detection, DH handshake, read loop) lives in
-- collab/peer_session.lua; server.lua owns the registry, approval, broadcast,
-- and heartbeat.
local reg = {
  pending = pending,
  clients = clients,
  roles = peer_roles,
  names = peer_names,
  last_seen = last_seen,
}

-- Heartbeat: server sends a ping to every approved peer every PING_INTERVAL_MS
-- and disconnects any peer with no inbound traffic for IDLE_KILL_MS.  The
-- 30 s deadline is ~2× the ping interval so a single dropped pong does not
-- kill an otherwise-healthy peer; two consecutive misses do.
local PING_INTERVAL_MS = 15 * 1000
local IDLE_KILL_MS = 30 * 1000

local function dbg(msg)
  log.dbg("server", msg)
end

-- Forward declaration (used inside heartbeat timer below).
local close_peer

---Register the callback invoked for every decoded inbound message.
---@param cb fun(msg: LiveShare.Message, peer_id: LiveShare.PeerId)
function M.setup(cb)
  on_message = cb
end

-- Heartbeat: walks the approved client table once per PING_INTERVAL_MS and
-- (a) sends a {t="ping"} to every healthy peer; (b) closes any peer that has
-- gone silent for longer than IDLE_KILL_MS.  Clients respond with {t="pong"};
-- the act of receiving any frame counts as keepalive evidence regardless of
-- the message type, so even a chatty session never trips the idle threshold.
local function start_heartbeat()
  if heartbeat_timer then
    return
  end
  heartbeat_timer = uv.new_timer()
  heartbeat_timer:start(
    PING_INTERVAL_MS,
    PING_INTERVAL_MS,
    vim.schedule_wrap(function()
      local now = uv.now()
      for pid, c in pairs(clients) do
        local seen = last_seen[pid] or now
        if now - seen > IDLE_KILL_MS then
          dbg("peer " .. pid .. " idle for " .. (now - seen) .. " ms — closing")
          close_peer(pid, "idle timeout")
        elseif not c.handle:is_closing() and c.encryptor then
          local ok, frame = pcall(function()
            return c.framer(c.encryptor:encode({ t = "ping", ts = now }))
          end)
          if ok and frame then
            c.handle:write(frame)
          end
        end
      end
    end)
  )
end

local function stop_heartbeat()
  if heartbeat_timer then
    heartbeat_timer:stop()
    heartbeat_timer:close()
    heartbeat_timer = nil
  end
end

---Bind and start listening for peers.
---@param ip string bind address
---@param port integer bind port
---@param key string|nil 32-byte session key (PSK), or nil for plaintext
---@return boolean ok true if the server bound and started listening
function M.start(ip, port, key)
  session_key = key
  srv = uv.new_tcp()
  local ok, err = srv:bind(ip, port)
  if not ok then
    srv:close()
    srv = nil
    session_key = nil
    vim.schedule(function()
      vim.api.nvim_err_writeln("live-share: bind failed: " .. tostring(err))
    end)
    return false
  end

  srv:listen(128, function(lerr)
    if lerr then
      vim.schedule(function()
        vim.api.nvim_err_writeln("live-share server listen error: " .. lerr)
      end)
      return
    end

    local conn = uv.new_tcp()
    srv:accept(conn)

    local peer_id = next_peer
    next_peer = next_peer + 1

    -- Hand the accepted socket to its own per-connection state machine.  The
    -- registry, approval, broadcast, and heartbeat stay here; everything
    -- specific to this one connection lives in peer_session.
    peer_session.start({
      peer_id = peer_id,
      conn = conn,
      session_key = session_key,
      on_message = on_message,
      reg = reg,
      close_peer = close_peer,
      send = M.send,
    })
  end)
  return true
end

-- ── Approval API ──────────────────────────────────────────────────────────────

---Move a pending peer into the active client set so it receives broadcasts.
---@param peer_id LiveShare.PeerId
function M.approve(peer_id)
  local p = pending[peer_id]
  if not p then
    dbg("approve: peer " .. peer_id .. " not in pending")
    return
  end
  if p.pending_timer then
    p.pending_timer:stop()
    p.pending_timer:close()
    p.pending_timer = nil
  end
  pending[peer_id] = nil
  clients[peer_id] = p
  last_seen[peer_id] = uv.now()
  start_heartbeat()
  dbg("peer " .. peer_id .. " approved")
end

---Set a peer's permission role.
---@param peer_id LiveShare.PeerId
---@param role LiveShare.Role
function M.set_role(peer_id, role)
  peer_roles[peer_id] = role
  dbg("peer " .. peer_id .. " role = " .. tostring(role))
end

---Get a peer's permission role, or nil if unknown.
---@param peer_id LiveShare.PeerId
---@return LiveShare.Role|nil
function M.get_role(peer_id)
  return peer_roles[peer_id]
end

---Set a peer's display name (used to synthesise `bye` on abrupt disconnect).
---@param peer_id LiveShare.PeerId
---@param name string
function M.set_name(peer_id, name)
  peer_names[peer_id] = name
  dbg("peer " .. peer_id .. " name = " .. tostring(name))
end

---Reject a pending peer: send `msg`, then close the connection shortly after.
---@param peer_id LiveShare.PeerId
---@param msg LiveShare.Message
function M.reject(peer_id, msg)
  local p = pending[peer_id]
  if not p or p.handle:is_closing() then
    if p and p.pending_timer then
      p.pending_timer:stop()
      p.pending_timer:close()
    end
    pending[peer_id] = nil
    return
  end
  if p.pending_timer then
    p.pending_timer:stop()
    p.pending_timer:close()
    p.pending_timer = nil
  end
  -- p.encryptor may still be the plaintext fallback if the peer was
  -- rejected pre-DH — that's fine, the rejection message just goes out
  -- in plaintext like the dh_offer would have.
  local ok, frame = pcall(function()
    return p.framer(p.encryptor:encode(msg))
  end)
  if ok and frame then
    p.handle:write(frame)
  end
  local t = uv.new_timer()
  t:start(100, 0, function()
    t:close()
    if not p.handle:is_closing() then
      p.handle:close()
    end
  end)
  pending[peer_id] = nil
  dbg("peer " .. peer_id .. " rejected")
end

-- ── Send helpers ─────────────────────────────────────────────────────────────

local function log_encode_err(result)
  vim.schedule(function()
    vim.api.nvim_err_writeln("live-share: encode error: " .. tostring(result))
  end)
end

---Send a message to a single approved peer (no-op if it's gone).
---@param peer_id LiveShare.PeerId
---@param msg LiveShare.Message
function M.send(peer_id, msg)
  local c = clients[peer_id]
  if not (c and not c.handle:is_closing()) then
    dbg("send skipped — peer " .. peer_id .. " not available")
    return
  end
  dbg("sending '" .. tostring(msg.t) .. "' to peer " .. peer_id)
  local ok, result = pcall(function()
    return c.framer(c.encryptor:encode(msg))
  end)
  if ok and result then
    c.handle:write(result)
  elseif not ok then
    log_encode_err(result)
  end
end

---Send a message to every approved peer, optionally excluding one.
---@param msg LiveShare.Message
---@param except_peer? LiveShare.PeerId peer to skip
function M.broadcast(msg, except_peer)
  -- Per-peer subkeys mean each recipient needs its own ciphertext: encode is
  -- now O(N) instead of O(1).  Counter increments per encode, salt stays
  -- constant per peer.  Plaintext sessions still produce identical bytes per
  -- peer, but the cost of re-encoding JSON is negligible.
  for pid, c in pairs(clients) do
    if pid ~= except_peer and not c.handle:is_closing() and c.encryptor then
      local ok, result = pcall(function()
        return c.framer(c.encryptor:encode(msg))
      end)
      if ok and result then
        c.handle:write(result)
      end
    end
  end
end

-- Internal: synchronous variant used by heartbeat / pending timeout, where
-- we want to close the socket and let the on_disconnect callback do the
-- registry cleanup naturally.  Differs from M.kick in that it does NOT
-- aggressively wipe state — letting on_disconnect run keeps the regular
-- "peer left" flow (presence cleanup, bye broadcast) intact.
close_peer = function(peer_id, _reason)
  local c = clients[peer_id] or pending[peer_id]
  if not c then
    return
  end
  if c.pending_timer then
    c.pending_timer:stop()
    c.pending_timer:close()
    c.pending_timer = nil
  end
  if not c.handle:is_closing() then
    c.handle:close()
  end
end

---Forcibly disconnect a peer and wipe all of its registry state.
---@param peer_id LiveShare.PeerId
---@return boolean ok true if a matching peer was found and kicked
function M.kick(peer_id)
  local c = clients[peer_id] or pending[peer_id]
  if not c then
    return false
  end
  if c.pending_timer then
    c.pending_timer:stop()
    c.pending_timer:close()
    c.pending_timer = nil
  end
  if not c.handle:is_closing() then
    c.handle:close()
  end
  clients[peer_id] = nil
  pending[peer_id] = nil
  peer_roles[peer_id] = nil
  peer_names[peer_id] = nil
  rate_limit.forget(peer_id)
  last_seen[peer_id] = nil
  dbg("peer " .. peer_id .. " kicked")
  return true
end

---Stop the server, close every connection, and reset all peer state.
function M.stop()
  stop_heartbeat()
  for _, c in pairs(pending) do
    if c.pending_timer then
      c.pending_timer:stop()
      c.pending_timer:close()
    end
    if not c.handle:is_closing() then
      c.handle:close()
    end
  end
  for _, c in pairs(clients) do
    if not c.handle:is_closing() then
      c.handle:close()
    end
  end
  -- Clear in place so the `reg` reference shared with peer_session stays valid.
  for _, t in ipairs({ pending, clients, peer_roles, peer_names, last_seen }) do
    for k in pairs(t) do
      t[k] = nil
    end
  end
  rate_limit.reset()
  next_peer = 1
  session_key = nil
  if srv and not srv:is_closing() then
    srv:close()
    srv = nil
  end
end

return M
