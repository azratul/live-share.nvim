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

local protocol = require("live-share.collab.protocol")
local tcp_trans = require("live-share.collab.transport.tcp")
local ws_trans = require("live-share.collab.transport.ws")
local log = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local srv = nil
local pending = {} -- peer_id -> { handle, framer, mode, pending_timer }  (awaiting host approval)
local clients = {} -- peer_id -> { handle, framer, mode }  (approved peers)
local peer_roles = {} -- peer_id -> "rw" | "ro"
local peer_names = {} -- peer_id -> name (for synthesising bye on abrupt disconnect)
local rate_buckets = {} -- peer_id -> { [kind] = { tokens, last_ms } }  (token-bucket rate limit)
local last_seen = {} -- peer_id -> ms timestamp of last byte received from peer
local heartbeat_timer = nil
local next_peer = 1
local on_message = nil
local session_key = nil
-- v4 AEAD: one outbound encryptor for the host (from_peer always = 0) and one
-- decryptor used for every inbound connection (from_peer is the connection's
-- authoritative peer_id, supplied per-call).
local encryptor = nil
local decryptor = nil

-- Maximum bytes per protocol frame.  Frames declaring a length above this are
-- dropped at the transport reader before any allocation, and the connection
-- is closed.  Defends against a malicious peer announcing huge sizes to
-- exhaust host memory.  Picked to comfortably cover today's largest
-- legitimate message (`workspace_info` for a ~50k-file monorepo, ~5 MB JSON)
-- while remaining well below the 4 GB WS frame ceiling.
local MAX_MESSAGE_BYTES = 10 * 1024 * 1024

-- Pending-peer timeout: an unapproved peer sitting in `pending` past this
-- deadline is force-closed.  Avoids leaks from clients that connect, sit on
-- the prompt, and never finish (or are deliberately camping the slot).
local PENDING_TIMEOUT_MS = 90 * 1000

-- Heartbeat: server sends a ping to every approved peer every PING_INTERVAL_MS
-- and disconnects any peer with no inbound traffic for IDLE_KILL_MS.  The
-- 30 s deadline is ~2× the ping interval so a single dropped pong does not
-- kill an otherwise-healthy peer; two consecutive misses do.
local PING_INTERVAL_MS = 15 * 1000
local IDLE_KILL_MS = 30 * 1000

-- Per-peer rate limits.  Defends against a malicious or buggy guest spamming
-- patches/cursors and saturating the host's main loop.  Numbers are generous
-- enough for normal interactive editing (a fast typist generates ~10 patches
-- per second; cursor moves are debounced at 100 ms ≈ 10/s).
local RATE_LIMITS = {
  patch = 100, -- patches per second per peer
  cursor = 60, -- cursor updates per second per peer
}

-- Token bucket: refills at `rate` tokens/sec up to capacity = rate (= 1 s burst).
-- Returns true iff a token is available and consumes it.
local function rate_allow(peer_id, kind)
  local rate = RATE_LIMITS[kind]
  if not rate then
    return true
  end
  local now = uv.now()
  rate_buckets[peer_id] = rate_buckets[peer_id] or {}
  local bucket = rate_buckets[peer_id][kind]
  if not bucket then
    bucket = { tokens = rate, last_ms = now }
    rate_buckets[peer_id][kind] = bucket
  end
  local elapsed = now - bucket.last_ms
  if elapsed > 0 then
    bucket.tokens = math.min(rate, bucket.tokens + elapsed * rate / 1000)
    bucket.last_ms = now
  end
  if bucket.tokens >= 1 then
    bucket.tokens = bucket.tokens - 1
    return true
  end
  return false
end

-- Module-level framers so broadcast can use them as stable cache keys.
local function ws_framer(payload)
  return ws_trans.frame(payload)
end
local function tcp_framer(payload)
  return tcp_trans.frame(payload)
end

local function dbg(msg)
  log.dbg("server", msg)
end

-- Forward declaration (used inside heartbeat timer below).
local close_peer

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
        elseif not c.handle:is_closing() then
          local ok, frame = pcall(function()
            return c.framer(encryptor:encode({ t = "ping", ts = now }))
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

function M.start(ip, port, key)
  session_key = key
  -- Host's outbound peer_id is always 0; the lambda is purely formal.
  encryptor = protocol.new_encryptor(key, function()
    return 0
  end)
  decryptor = protocol.new_decryptor(key)
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
    dbg("peer " .. peer_id .. " TCP accepted")

    -- State: "detecting" | "ws_hs" | "ws" | "tcp"
    local state = "detecting"
    local buf = ""
    local reader = nil -- stateful fn(chunk) → { payload, ... }; set at detection time

    local function dispatch(msg)
      -- Drop messages from unapproved peers (they're still in pending).
      if not clients[peer_id] then
        return
      end
      -- ping / pong are handled at this layer and never bubble up to the
      -- application: pong (and any incoming ping from the guest) only
      -- serves to bump last_seen, which already happened in the read
      -- callback.  Returning here keeps the upper layer's message handler
      -- focused on application-level events.
      if msg.t == "pong" or msg.t == "ping" then
        return
      end
      -- Enforce read-only: reject patch messages from ro peers.
      if msg.t == "patch" and peer_roles[peer_id] == "ro" then
        dbg("peer " .. peer_id .. " is read-only — rejecting patch")
        M.send(peer_id, {
          t = "error",
          code = "unauthorized",
          message = "read-only guests cannot send patches",
        })
        return
      end
      -- Per-peer rate limit (defends against patch/cursor flooding).
      if not rate_allow(peer_id, msg.t) then
        dbg("peer " .. peer_id .. " rate-limited (" .. tostring(msg.t) .. ")")
        return
      end
      -- peer_id binding: never trust a `peer` field set by the client.  The
      -- only authoritative identity is the connection's peer_id.  Without
      -- this, a malicious guest could spoof cursor/focus/bye broadcasts
      -- attributed to other peers.
      if msg.peer ~= nil then
        msg.peer = peer_id
      end
      vim.schedule(function()
        dbg("msg '" .. tostring(msg.t) .. "' from peer " .. peer_id)
        if on_message then
          on_message(msg, peer_id)
        end
      end)
    end

    local function on_disconnect(reason)
      vim.schedule(function()
        dbg("peer " .. peer_id .. " disconnected: " .. tostring(reason))
        local p = pending[peer_id]
        if p and p.pending_timer then
          p.pending_timer:stop()
          p.pending_timer:close()
        end
        pending[peer_id] = nil
        clients[peer_id] = nil
        peer_roles[peer_id] = nil
        rate_buckets[peer_id] = nil
        last_seen[peer_id] = nil
        local name = peer_names[peer_id]
        peer_names[peer_id] = nil
        if on_message then
          on_message({ t = "bye", peer = peer_id, name = name }, peer_id)
        end
      end)
      if not conn:is_closing() then
        conn:close()
      end
    end

    local function process(data)
      local payloads, rerr = reader(data)
      if not payloads then
        dbg("peer " .. peer_id .. " transport error: " .. tostring(rerr) .. " — closing")
        on_disconnect(rerr)
        return
      end
      -- Mark the peer alive on every parsed frame, regardless of message type.
      -- This is what lets the heartbeat consider any chatter (patches, cursor
      -- moves, pongs) as keepalive evidence.
      if #payloads > 0 then
        last_seen[peer_id] = uv.now()
      end
      for _, payload in ipairs(payloads) do
        -- AAD on inbound binds the message to the connection's authoritative
        -- peer_id; an attacker swapping the ciphertext between connections
        -- (or relabelling a recorded message) would fail GCM verification.
        local msg = decryptor:decode(payload, peer_id)
        if msg then
          dispatch(msg)
        end
      end
    end

    -- Arms the pending-peer timeout.  Called once we know the transport mode.
    local function arm_pending_timeout()
      local p = pending[peer_id]
      if not p then
        return
      end
      local t = uv.new_timer()
      p.pending_timer = t
      t:start(
        PENDING_TIMEOUT_MS,
        0,
        vim.schedule_wrap(function()
          if pending[peer_id] then
            dbg("peer " .. peer_id .. " unapproved after " .. PENDING_TIMEOUT_MS .. " ms — kicking")
            close_peer(peer_id, "pending timeout")
          end
        end)
      )
    end

    local function complete_ws_handshake(initial_buf)
      local response, rest, err_msg = ws_trans.server_handshake_response(initial_buf)
      if response == nil then
        return false
      end -- need more data

      if response == false then
        dbg("peer " .. peer_id .. " — " .. (err_msg or "bad WS request") .. "; closing")
        if not conn:is_closing() then
          conn:close()
        end
        return true -- done (with error)
      end

      conn:write(response)
      state = "ws"
      pending[peer_id] = { handle = conn, framer = ws_framer, mode = "ws" }
      arm_pending_timeout()
      dbg("peer " .. peer_id .. " WS handshake done — awaiting host approval")
      vim.schedule(function()
        if on_message then
          on_message({ t = "connect", peer = peer_id }, peer_id)
        end
      end)
      if #rest > 0 then
        process(rest)
      end
      return true
    end

    conn:read_start(function(read_err, data)
      if read_err or not data then
        on_disconnect(read_err)
        return
      end

      buf = buf .. data

      if state == "detecting" then
        if #buf < 4 then
          return
        end
        if buf:sub(1, 4) == "GET " then
          state = "ws_hs"
          reader = ws_trans.new_reader(MAX_MESSAGE_BYTES)
          dbg("peer " .. peer_id .. " → WebSocket mode")
          -- fall through to ws_hs handling below
        else
          state = "tcp"
          reader = tcp_trans.new_reader(MAX_MESSAGE_BYTES)
          pending[peer_id] = { handle = conn, framer = tcp_framer, mode = "tcp" }
          arm_pending_timeout()
          dbg("peer " .. peer_id .. " → raw TCP mode — awaiting host approval")
          vim.schedule(function()
            if on_message then
              on_message({ t = "connect", peer = peer_id }, peer_id)
            end
          end)
          process(buf)
          buf = ""
          return
        end
      end

      if state == "ws_hs" then
        if complete_ws_handshake(buf) then
          buf = ""
        end
        return
      end

      if state == "ws" then
        process(data)
        return
      end
      if state == "tcp" then
        process(data)
        return
      end
    end)
  end)
  return true
end

-- ── Approval API ──────────────────────────────────────────────────────────────

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

function M.set_role(peer_id, role)
  peer_roles[peer_id] = role
  dbg("peer " .. peer_id .. " role = " .. tostring(role))
end

function M.get_role(peer_id)
  return peer_roles[peer_id]
end

function M.set_name(peer_id, name)
  peer_names[peer_id] = name
  dbg("peer " .. peer_id .. " name = " .. tostring(name))
end

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
  local ok, frame = pcall(function()
    return p.framer(encryptor:encode(msg))
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

function M.send(peer_id, msg)
  local c = clients[peer_id]
  if not (c and not c.handle:is_closing()) then
    dbg("send skipped — peer " .. peer_id .. " not available")
    return
  end
  dbg("sending '" .. tostring(msg.t) .. "' to peer " .. peer_id)
  local ok, result = pcall(function()
    return c.framer(encryptor:encode(msg))
  end)
  if ok and result then
    c.handle:write(result)
  elseif not ok then
    log_encode_err(result)
  end
end

function M.broadcast(msg, except_peer)
  -- Encode payload once; frame once per transport type.  All recipients see
  -- the same nonce + AAD because from_peer is always 0 (host) on outbound.
  local payload = nil
  local framed = {} -- mode tag → framed bytes
  for pid, c in pairs(clients) do
    if pid == except_peer or c.handle:is_closing() then
      goto continue
    end

    if not payload then
      payload = encryptor:encode(msg)
    end
    if not framed[c.mode] then
      framed[c.mode] = c.framer(payload)
    end
    c.handle:write(framed[c.mode])
    ::continue::
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
  rate_buckets[peer_id] = nil
  last_seen[peer_id] = nil
  dbg("peer " .. peer_id .. " kicked")
  return true
end

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
  pending = {}
  clients = {}
  peer_roles = {}
  peer_names = {}
  rate_buckets = {}
  last_seen = {}
  next_peer = 1
  session_key = nil
  encryptor = nil
  decryptor = nil
  if srv and not srv:is_closing() then
    srv:close()
    srv = nil
  end
end

return M
