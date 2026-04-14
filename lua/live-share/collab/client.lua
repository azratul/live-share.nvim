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

local protocol  = require("live-share.collab.protocol")
local tcp_trans = require("live-share.collab.transport.tcp")
local ws_trans  = require("live-share.collab.transport.ws")
local log       = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local conn        = nil
local on_message  = nil
local session_key = nil
local send_frame  = nil  -- fn(payload) → framed bytes; set at connect time

local function dbg(msg) log.dbg("client", msg) end

function M.setup(cb)
  on_message = cb
end

local function dispatch_payloads(payloads)
  for _, payload in ipairs(payloads) do
    local msg = protocol.decode(payload, session_key)
    if msg then
      dbg("msg '" .. tostring(msg.t) .. "' received")
      if on_message then on_message(msg) end
    end
  end
end

local function do_connect(ip, port, key, host, mode, attempt, on_error)
  dbg("connecting to " .. ip .. ":" .. tostring(port)
      .. " mode=" .. mode .. " (attempt " .. attempt .. ")")

  local tcp = uv.new_tcp()
  conn = tcp

  tcp:connect(ip, tonumber(port), function(err)
    if err then
      dbg("connect failed: " .. tostring(err))
      tcp:close()
      if conn == tcp then conn = nil end

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
          vim.api.nvim_err_writeln(
            "live-share: could not connect to " .. host .. ":" .. tostring(port))
          if on_error then on_error() end
        end)
      end
      return
    end

    local function on_disconnect(read_err)
      vim.schedule(function()
        dbg("disconnected: " .. tostring(read_err))
        if conn == tcp then conn = nil end
        vim.api.nvim_out_write("live-share: disconnected from session\n")
      end)
      if not tcp:is_closing() then tcp:close() end
    end

    if mode == "tcp" then
      dbg("TCP connected — raw TCP mode (encrypted=" .. tostring(key ~= nil) .. ")")
      vim.schedule(function()
        vim.notify("live-share: connected (tunnel relay)", vim.log.levels.INFO)
      end)
      send_frame   = tcp_trans.frame
      local reader = tcp_trans.new_reader()

      tcp:read_start(function(read_err, data)
        if read_err or not data then on_disconnect(read_err); return end
        local payloads = reader(data)
        vim.schedule(function() dispatch_payloads(payloads) end)
      end)

    else
      -- ── WebSocket mode ────────────────────────────────────────────────────
      dbg("TCP connected — sending WS upgrade request")
      send_frame = ws_trans.frame_client
      local upgrade_req, _ws_key = ws_trans.client_upgrade(host)
      local state        = "handshaking"
      local hs_buf       = ""
      local frame_reader = ws_trans.new_reader()

      local function process_ws(data)
        local payloads = frame_reader(data)
        vim.schedule(function() dispatch_payloads(payloads) end)
      end

      tcp:read_start(function(read_err, data)
        if read_err or not data then on_disconnect(read_err); return end

        if state == "handshaking" then
          hs_buf = hs_buf .. data
          local ok, rest, err_msg = ws_trans.complete_client_handshake(hs_buf)
          if ok == nil then return end  -- need more data

          hs_buf = nil

          if not ok then
            vim.schedule(function()
              vim.api.nvim_err_writeln("live-share: " .. (err_msg or "WS handshake failed"))
              if on_error then on_error() end
            end)
            if not tcp:is_closing() then tcp:close() end
            return
          end

          dbg("WS handshake complete (encrypted=" .. tostring(session_key ~= nil) .. ")")
          state = "connected"
          vim.schedule(function()
            vim.notify("live-share: connected (tunnel relay)", vim.log.levels.INFO)
          end)
          if #rest > 0 then process_ws(rest) end
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
  attempt     = attempt or 0
  mode        = mode or "ws"
  session_key = key

  dbg("resolving " .. host)
  uv.getaddrinfo(host, nil, { socktype = "stream" }, function(err, res)
    if err or not res or #res == 0 then
      vim.schedule(function()
        vim.api.nvim_err_writeln(
          "live-share: could not resolve host '" .. host .. "': " .. tostring(err))
        if on_error then on_error() end
      end)
      return
    end
    dbg("resolved " .. host .. " -> " .. res[1].addr)
    do_connect(res[1].addr, port, key, host, mode, attempt, on_error)
  end)
end

function M.send(msg)
  if not (conn and not conn:is_closing()) then return end
  if not send_frame then return end

  local ok, result = pcall(function()
    return send_frame(protocol.encode(msg, session_key))
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
  if conn and not conn:is_closing() then
    conn:close()
    conn = nil
  end
  session_key = nil
  send_frame  = nil
end

return M
