-- TCP server: accepts connections, auto-detects WS or raw TCP, broadcasts patches.
--
-- Protocol auto-detection (first 4 bytes):
--   "GET " → WebSocket mode (HTTP tunnel providers: serveo, localhost.run)
--   other  → raw TCP mode  (direct connections, ngrok tcp://)
--
-- Approval flow:
--   On connect, the peer enters `pending` and a synthetic "connect" event fires.
--   The host calls M.approve(peer_id) or M.reject(peer_id, msg) to proceed.
--   Only approved peers (in `clients`) receive broadcasts and can send patches.
local M = {}

local protocol  = require("live-share.collab.protocol")
local websocket = require("live-share.collab.websocket")
local log       = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local srv         = nil
local pending     = {}   -- peer_id -> { handle, mode }  (awaiting host approval)
local clients     = {}   -- peer_id -> { handle, mode }  (approved peers)
local peer_roles  = {}   -- peer_id -> "rw" | "ro"
local next_peer   = 1
local on_message  = nil
local session_key = nil

local function dbg(msg) log.dbg("server", msg) end

function M.setup(cb)
  on_message = cb
end

function M.start(ip, port, key)
  session_key = key
  srv = uv.new_tcp()
  local ok, err = srv:bind(ip, port)
  if not ok then
    vim.schedule(function()
      vim.api.nvim_err_writeln("live-share: bind failed: " .. tostring(err))
    end)
    return
  end

  srv:listen(128, function(lerr)
    if lerr then
      vim.schedule(function()
        vim.api.nvim_err_writeln("live-share server listen error: " .. lerr)
      end)
      return
    end

    local conn    = uv.new_tcp()
    srv:accept(conn)

    local peer_id = next_peer
    next_peer = next_peer + 1
    dbg("peer " .. peer_id .. " TCP accepted")

    -- State: "detecting" | "ws_hs" | "ws" | "tcp"
    local state        = "detecting"
    local buf          = ""
    local frame_reader = nil  -- WS decoder (ws mode)
    local raw_reader   = nil  -- length-prefix decoder (tcp mode)

    local function dispatch(msg)
      -- Drop messages from unapproved peers (they're still in pending).
      if not clients[peer_id] then return end
      -- Enforce read-only: silently drop patch messages from ro peers.
      if msg.t == "patch" and peer_roles[peer_id] == "ro" then
        dbg("peer " .. peer_id .. " is read-only — dropping patch")
        return
      end
      vim.schedule(function()
        dbg("msg '" .. tostring(msg.t) .. "' from peer " .. peer_id)
        if on_message then on_message(msg, peer_id) end
      end)
    end

    local function on_disconnect(reason)
      vim.schedule(function()
        dbg("peer " .. peer_id .. " disconnected: " .. tostring(reason))
        pending[peer_id]    = nil
        clients[peer_id]    = nil
        peer_roles[peer_id] = nil
        if on_message then on_message({ t = "bye", peer = peer_id }, peer_id) end
      end)
      if not conn:is_closing() then conn:close() end
    end

    local function process_ws(data)
      local payloads = frame_reader(data)
      for _, payload in ipairs(payloads) do
        local msg = protocol.decode(payload, session_key)
        if msg then dispatch(msg) end
      end
    end

    local function process_tcp(data)
      local msgs = raw_reader(data)
      for _, msg in ipairs(msgs) do dispatch(msg) end
    end

    local function complete_ws_handshake(initial_buf)
      -- Look for end of HTTP headers
      local hend = initial_buf:find("\r\n\r\n", 1, true)
      if not hend then return false end  -- need more data

      local headers = initial_buf:sub(1, hend + 3)
      local rest    = initial_buf:sub(hend + 4)

      -- Debug: print sanitised headers
      dbg("peer " .. peer_id .. " headers: "
          .. headers:gsub("\r\n", " | "):sub(1, 300))

      -- HTTP headers are case-insensitive (RFC 7230); serveo sends "Sec-Websocket-Key"
      local ws_key = headers:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Kk]ey:%s*([^\r\n]+)")
      if ws_key then ws_key = ws_key:match("^(.-)%s*$") end  -- trim trailing whitespace
      if not ws_key then
        dbg("peer " .. peer_id .. " — Sec-WebSocket-Key missing; closing")
        if not conn:is_closing() then conn:close() end
        return true  -- done (with error)
      end

      conn:write(websocket.server_response(ws_key))
      state = "ws"
      -- Register in pending (not clients) until the host approves.
      pending[peer_id] = { handle = conn, mode = "ws" }
      dbg("peer " .. peer_id .. " WS handshake done — awaiting host approval")
      vim.schedule(function()
        if on_message then on_message({ t = "connect", peer = peer_id }, peer_id) end
      end)
      if #rest > 0 then process_ws(rest) end
      return true
    end

    conn:read_start(function(read_err, data)
      if read_err or not data then
        on_disconnect(read_err)
        return
      end

      buf = buf .. data

      if state == "detecting" then
        if #buf < 4 then return end  -- need at least 4 bytes to decide
        if buf:sub(1, 4) == "GET " then
          state        = "ws_hs"
          frame_reader = websocket.new_frame_reader()
          dbg("peer " .. peer_id .. " → WebSocket mode")
          -- fall through to ws_hs handling below
        else
          state      = "tcp"
          raw_reader = protocol.new_raw_reader(session_key)
          -- Register in pending (not clients) until the host approves.
          pending[peer_id] = { handle = conn, mode = "tcp" }
          dbg("peer " .. peer_id .. " → raw TCP mode — awaiting host approval")
          vim.schedule(function()
            if on_message then on_message({ t = "connect", peer = peer_id }, peer_id) end
          end)
          process_tcp(buf)
          buf = ""
          return
        end
      end

      if state == "ws_hs" then
        if complete_ws_handshake(buf) then buf = "" end
        return
      end

      if state == "ws"  then process_ws(data);  return end
      if state == "tcp" then process_tcp(data); return end
    end)
  end)
end

-- ── Approval API ──────────────────────────────────────────────────────────────

-- Promote a peer from pending → clients (host approved them).
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

-- Set the role for an approved (or just-approved) peer.
function M.set_role(peer_id, role)
  peer_roles[peer_id] = role
  dbg("peer " .. peer_id .. " role = " .. tostring(role))
end

-- Send a message to a pending peer then close their connection.
function M.reject(peer_id, msg)
  local p = pending[peer_id]
  if not p or p.handle:is_closing() then
    pending[peer_id] = nil
    return
  end
  local ok, frame
  if p.mode == "tcp" then
    ok, frame = pcall(protocol.encode_raw, msg, session_key)
  else
    local ok2, payload = pcall(protocol.encode, msg, session_key)
    if ok2 then
      ok    = true
      frame = websocket.encode_frame(payload, false)
    end
  end
  if ok and frame then p.handle:write(frame) end
  -- Close after a brief delay so the frame can be flushed.
  local t = uv.new_timer()
  t:start(100, 0, function()
    t:close()
    if not p.handle:is_closing() then p.handle:close() end
  end)
  pending[peer_id] = nil
  dbg("peer " .. peer_id .. " rejected")
end

-- ── Send helpers ─────────────────────────────────────────────────────────────

local function encode_for(c, msg)
  if c.mode == "tcp" then
    local ok, frame = pcall(protocol.encode_raw, msg, session_key)
    return ok and frame or nil
  end
  -- ws mode
  local ok, payload = pcall(protocol.encode, msg, session_key)
  if not ok then return nil end
  return websocket.encode_frame(payload, false)  -- server→client: unmasked
end

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
  local ok, result = pcall(encode_for, c, msg)
  if ok and result then
    c.handle:write(result)
  elseif not ok then
    log_encode_err(result)
  end
end

function M.broadcast(msg, except_peer)
  -- Encode once per mode
  local ws_frame, tcp_frame
  for pid, c in pairs(clients) do
    if pid == except_peer or c.handle:is_closing() then goto continue end

    local frame
    if c.mode == "tcp" then
      if tcp_frame == nil then
        local ok, r = pcall(protocol.encode_raw, msg, session_key)
        tcp_frame = ok and r or false
      end
      frame = tcp_frame
    else
      if ws_frame == nil then
        local ok, payload = pcall(protocol.encode, msg, session_key)
        ws_frame = ok and websocket.encode_frame(payload, false) or false
      end
      frame = ws_frame
    end

    if frame then c.handle:write(frame) end
    ::continue::
  end
end

function M.stop()
  for _, c in pairs(pending) do
    if not c.handle:is_closing() then c.handle:close() end
  end
  for _, c in pairs(clients) do
    if not c.handle:is_closing() then c.handle:close() end
  end
  pending     = {}
  clients     = {}
  peer_roles  = {}
  next_peer   = 1
  session_key = nil
  if srv and not srv:is_closing() then
    srv:close()
    srv = nil
  end
end

return M
