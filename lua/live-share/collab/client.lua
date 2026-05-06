-- TCP client: connects to host, speaks WS or raw TCP, reads frames, sends patches.
--
-- Mode is determined by the caller:
--   mode = "ws"  → WebSocket (HTTP tunnel providers)
--   mode = "tcp" → raw TCP   (direct connections, ngrok tcp://)
--
-- Internally both modes are handled through a transport adapter:
--   send_frame(payload) → framed bytes      (set at connect time)
--   reader(chunk)       → { payload, ... }  (set at connect time)
-- The upper layer only deals with encode/decode via protocol.lua.
local M = {}

local protocol = require("live-share.collab.protocol")
local session = require("live-share.session")
local tcp_trans = require("live-share.collab.transport.tcp")
local ws_trans = require("live-share.collab.transport.ws")
local log = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local conn = nil
local on_message = nil
local session_key = nil
local send_frame = nil -- fn(payload) → framed bytes; set at connect time
local last_seen_ms = nil
local idle_timer = nil
-- v4 AEAD: encryptor's from_peer is the guest's own peer_id (assigned by the
-- host in `hello`).  Resolved per-encode via the lambda below so the
-- encryptor can be built before `hello` arrives — outbound traffic before
-- that point would use 0 as a fallback, but in practice the guest doesn't
-- send anything until after `hello_ack`, by which point session.peer_id is
-- set.  Decryptor is stateless and used for every inbound frame; from_peer
-- is always 0 (the host) on the guest side.
local encryptor = nil
local decryptor = nil

-- Must match the server-side ceiling defined in server.lua.  Frames declared
-- larger than this are dropped at the transport reader and treated as fatal.
local MAX_MESSAGE_BYTES = 10 * 1024 * 1024

-- Idle timer: closes the connection if no inbound traffic arrives for
-- IDLE_KILL_MS.  The host's heartbeat sends a ping every 15 s; missing two
-- consecutive pings (≥ 30 s of silence) signals a dead transport.
local IDLE_CHECK_MS = 5 * 1000
local IDLE_KILL_MS = 30 * 1000

local function dbg(msg)
  log.dbg("client", msg)
end

function M.setup(cb)
  on_message = cb
end

local function close_conn()
  if idle_timer then
    idle_timer:stop()
    idle_timer:close()
    idle_timer = nil
  end
  if conn and not conn:is_closing() then
    conn:close()
  end
  conn = nil
  send_frame = nil
end

local function start_idle_timer()
  if idle_timer then
    return
  end
  last_seen_ms = (vim.uv or vim.loop).now()
  idle_timer = uv.new_timer()
  idle_timer:start(
    IDLE_CHECK_MS,
    IDLE_CHECK_MS,
    vim.schedule_wrap(function()
      if not last_seen_ms then
        return
      end
      local now = uv.now()
      if now - last_seen_ms > IDLE_KILL_MS then
        dbg("no inbound traffic for " .. (now - last_seen_ms) .. " ms — closing connection")
        vim.notify("live-share: lost contact with host (no heartbeat) — disconnecting", vim.log.levels.WARN)
        close_conn()
      end
    end)
  )
end

local function send_raw(msg)
  if not (conn and not conn:is_closing()) or not send_frame or not encryptor then
    return
  end
  local ok, frame = pcall(function()
    return send_frame(encryptor:encode(msg))
  end)
  if ok and frame then
    conn:write(frame)
  end
end

local function dispatch_payloads(payloads)
  if #payloads > 0 then
    last_seen_ms = uv.now()
  end
  for _, payload in ipairs(payloads) do
    -- Inbound from_peer is always 0 (the host) on the guest side; AAD binds
    -- the ciphertext to that identity.
    local msg = decryptor and decryptor:decode(payload, 0) or nil
    if msg then
      dbg("msg '" .. tostring(msg.t) .. "' received")
      -- Heartbeat: handled at this layer, never bubbled up.  A ping triggers
      -- a matching pong; a pong is silently absorbed (last_seen above is the
      -- only side effect we need).
      if msg.t == "ping" then
        send_raw({ t = "pong", ts = msg.ts })
      elseif msg.t == "pong" then
        -- nothing else to do; last_seen already bumped above.
      elseif on_message then
        on_message(msg)
      end
    end
  end
end

local function do_connect(ip, port, key, host, mode, attempt, on_error)
  dbg("connecting to " .. ip .. ":" .. tostring(port) .. " mode=" .. mode .. " (attempt " .. attempt .. ")")

  local tcp = uv.new_tcp()
  conn = tcp

  tcp:connect(ip, tonumber(port), function(err)
    if err then
      dbg("connect failed: " .. tostring(err))
      tcp:close()
      if conn == tcp then
        conn = nil
      end

      if attempt < 3 then
        local delay = (2 ^ attempt) * 500
        local t = uv.new_timer()
        t:start(delay, 0, function()
          t:close()
          vim.schedule(function()
            M.connect(host, port, key, mode, attempt + 1, on_error)
          end)
        end)
      else
        vim.schedule(function()
          vim.api.nvim_err_writeln("live-share: could not connect to " .. host .. ":" .. tostring(port))
          if on_error then
            on_error()
          end
        end)
      end
      return
    end

    local function on_disconnect(read_err)
      vim.schedule(function()
        dbg("disconnected: " .. tostring(read_err))
        if conn == tcp then
          conn = nil
        end
        vim.api.nvim_out_write("live-share: disconnected from session\n")
      end)
      if not tcp:is_closing() then
        tcp:close()
      end
    end

    if mode == "tcp" then
      dbg("TCP connected — raw TCP mode (encrypted=" .. tostring(key ~= nil) .. ")")
      vim.schedule(function()
        vim.notify("live-share: connected (tunnel relay)", vim.log.levels.INFO)
      end)
      send_frame = tcp_trans.frame
      local reader = tcp_trans.new_reader(MAX_MESSAGE_BYTES)
      start_idle_timer()
      -- Send a zero-length probe so the server can detect raw TCP mode.
      -- Without this both sides wait for the other to write first.
      tcp:write("\x00\x00\x00\x00")

      tcp:read_start(function(read_err, data)
        if read_err or not data then
          on_disconnect(read_err)
          return
        end
        local payloads, rerr = reader(data)
        if not payloads then
          vim.schedule(function()
            vim.api.nvim_err_writeln("live-share: oversized frame from host — closing")
          end)
          on_disconnect(rerr)
          return
        end
        vim.schedule(function()
          dispatch_payloads(payloads)
        end)
      end)
    else
      -- ── WebSocket mode ────────────────────────────────────────────────────
      dbg("TCP connected — sending WS upgrade request")
      send_frame = ws_trans.frame_client
      local upgrade_req, _ws_key = ws_trans.client_upgrade(host)
      local state = "handshaking"
      local hs_buf = ""
      local frame_reader = ws_trans.new_reader(MAX_MESSAGE_BYTES)

      local function process_ws(data)
        local payloads, rerr = frame_reader(data)
        if not payloads then
          vim.schedule(function()
            vim.api.nvim_err_writeln("live-share: oversized frame from host — closing")
          end)
          on_disconnect(rerr)
          return
        end
        vim.schedule(function()
          dispatch_payloads(payloads)
        end)
      end

      tcp:read_start(function(read_err, data)
        if read_err or not data then
          on_disconnect(read_err)
          return
        end

        if state == "handshaking" then
          hs_buf = hs_buf .. data
          local ok, rest, err_msg = ws_trans.complete_client_handshake(hs_buf)
          if ok == nil then
            return
          end -- need more data

          hs_buf = nil

          if not ok then
            vim.schedule(function()
              vim.api.nvim_err_writeln("live-share: " .. (err_msg or "WS handshake failed"))
              if on_error then
                on_error()
              end
            end)
            if not tcp:is_closing() then
              tcp:close()
            end
            return
          end

          dbg("WS handshake complete (encrypted=" .. tostring(session_key ~= nil) .. ")")
          state = "connected"
          start_idle_timer()
          vim.schedule(function()
            vim.notify("live-share: connected (tunnel relay)", vim.log.levels.INFO)
          end)
          if #rest > 0 then
            process_ws(rest)
          end
          return
        end

        process_ws(data)
      end)

      -- Send upgrade request after setting up the read handler
      tcp:write(upgrade_req)
    end
  end)
end

-- mode: "ws" (default) or "tcp"
-- on_error: optional callback called when all retries are exhausted or DNS fails
function M.connect(host, port, key, mode, attempt, on_error)
  attempt = attempt or 0
  mode = mode or "ws"
  session_key = key
  -- v4 AEAD setup: encryptor's salt is generated here (per session); the
  -- counter starts at 1 on the first outbound encode.  from_peer is read
  -- from session.peer_id at encode time — falls back to 0 in the unlikely
  -- case the guest sends something before `hello` arrives.
  encryptor = protocol.new_encryptor(key, function()
    return session.peer_id or 0
  end)
  decryptor = protocol.new_decryptor(key)

  dbg("resolving " .. host)
  uv.getaddrinfo(host, nil, { socktype = "stream" }, function(err, res)
    if err or not res or #res == 0 then
      vim.schedule(function()
        vim.api.nvim_err_writeln("live-share: could not resolve host '" .. host .. "': " .. tostring(err))
        if on_error then
          on_error()
        end
      end)
      return
    end
    dbg("resolved " .. host .. " -> " .. res[1].addr)
    do_connect(res[1].addr, port, key, host, mode, attempt, on_error)
  end)
end

function M.send(msg)
  if not (conn and not conn:is_closing()) then
    return
  end
  if not send_frame or not encryptor then
    return
  end

  local ok, result = pcall(function()
    return send_frame(encryptor:encode(msg))
  end)
  if ok then
    conn:write(result)
  else
    vim.schedule(function()
      vim.api.nvim_err_writeln("live-share: encode error: " .. tostring(result))
    end)
  end
end

function M.stop()
  close_conn()
  session_key = nil
  last_seen_ms = nil
  encryptor = nil
  decryptor = nil
end

return M
