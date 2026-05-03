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
local pending = {} -- peer_id -> { handle, framer, mode }  (awaiting host approval)
local clients = {} -- peer_id -> { handle, framer, mode }  (approved peers)
local peer_roles = {} -- peer_id -> "rw" | "ro"
local peer_names = {} -- peer_id -> name (for synthesising bye on abrupt disconnect)
local next_peer = 1
local on_message = nil
local session_key = nil

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

function M.setup(cb)
  on_message = cb
end

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
        pending[peer_id] = nil
        clients[peer_id] = nil
        peer_roles[peer_id] = nil
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
      local payloads = reader(data)
      for _, payload in ipairs(payloads) do
        local msg = protocol.decode(payload, session_key)
        if msg then
          dispatch(msg)
        end
      end
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
          reader = ws_trans.new_reader()
          dbg("peer " .. peer_id .. " → WebSocket mode")
          -- fall through to ws_hs handling below
        else
          state = "tcp"
          reader = tcp_trans.new_reader()
          pending[peer_id] = { handle = conn, framer = tcp_framer, mode = "tcp" }
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
  pending[peer_id] = nil
  clients[peer_id] = p
  dbg("peer " .. peer_id .. " approved")
end

function M.set_role(peer_id, role)
  peer_roles[peer_id] = role
  dbg("peer " .. peer_id .. " role = " .. tostring(role))
end

function M.set_name(peer_id, name)
  peer_names[peer_id] = name
  dbg("peer " .. peer_id .. " name = " .. tostring(name))
end

function M.reject(peer_id, msg)
  local p = pending[peer_id]
  if not p or p.handle:is_closing() then
    pending[peer_id] = nil
    return
  end
  local ok, frame = pcall(function()
    return p.framer(protocol.encode(msg, session_key))
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
    return c.framer(protocol.encode(msg, session_key))
  end)
  if ok and result then
    c.handle:write(result)
  elseif not ok then
    log_encode_err(result)
  end
end

function M.broadcast(msg, except_peer)
  -- Encode payload once; frame once per transport type.
  local payload = nil
  local framed = {} -- mode tag → framed bytes
  for pid, c in pairs(clients) do
    if pid == except_peer or c.handle:is_closing() then
      goto continue
    end

    if not payload then
      payload = protocol.encode(msg, session_key)
    end
    if not framed[c.mode] then
      framed[c.mode] = c.framer(payload)
    end
    c.handle:write(framed[c.mode])
    ::continue::
  end
end

function M.kick(peer_id)
  local c = clients[peer_id] or pending[peer_id]
  if not c then
    return false
  end
  if not c.handle:is_closing() then
    c.handle:close()
  end
  clients[peer_id] = nil
  pending[peer_id] = nil
  peer_roles[peer_id] = nil
  peer_names[peer_id] = nil
  dbg("peer " .. peer_id .. " kicked")
  return true
end

function M.stop()
  for _, c in pairs(pending) do
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
  next_peer = 1
  session_key = nil
  if srv and not srv:is_closing() then
    srv:close()
    srv = nil
  end
end

return M
