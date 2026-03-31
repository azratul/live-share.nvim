-- TCP client: connects to host, speaks WS or raw TCP, reads frames, sends patches.
--
-- Mode is determined by the caller:
--   mode = "ws"  → WebSocket (HTTP tunnel providers)
--   mode = "tcp" → raw TCP   (direct connections, ngrok tcp://)
local M = {}

local protocol  = require("live-share.collab.protocol")
local websocket = require("live-share.collab.websocket")
local log       = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local conn        = nil
local on_message  = nil
local session_key = nil
local conn_mode   = "ws"  -- "ws" | "tcp"

local function dbg(msg) log.dbg("client", msg) end

function M.setup(cb)
  on_message = cb
end

local function do_connect(ip, port, key, host, mode, attempt)
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
            M.connect(host, port, key, mode, attempt + 1)
          end)
        end)
      else
        vim.schedule(function()
          vim.api.nvim_err_writeln(
            "live-share: could not connect to " .. host .. ":" .. tostring(port))
        end)
      end
      return
    end

    if mode == "tcp" then
      dbg("TCP connected — raw TCP mode (encrypted=" .. tostring(key ~= nil) .. ")")
      local raw_reader = protocol.new_raw_reader(session_key)

      tcp:read_start(function(read_err, data)
        if read_err or not data then
          vim.schedule(function()
            dbg("disconnected: " .. tostring(read_err))
            if conn == tcp then conn = nil end
            vim.api.nvim_out_write("live-share: disconnected from session\n")
          end)
          if not tcp:is_closing() then tcp:close() end
          return
        end
        local msgs = raw_reader(data)
        vim.schedule(function()
          for _, msg in ipairs(msgs) do
            if on_message then on_message(msg) end
          end
        end)
      end)

    else
      -- ── WebSocket mode ────────────────────────────────────────────────────
      dbg("TCP connected — sending WS upgrade request")
      local ws_key     = websocket.make_client_key()
      local state      = "handshaking"
      local hs_buf     = ""
      local frame_reader = websocket.new_frame_reader()

      local function process_ws(data)
        local payloads = frame_reader(data)
        for _, payload in ipairs(payloads) do
          local msg = protocol.decode(payload, session_key)
          if msg then
            vim.schedule(function()
              dbg("msg '" .. tostring(msg.t) .. "' received")
              if on_message then on_message(msg) end
            end)
          end
        end
      end

      tcp:read_start(function(read_err, data)
        if read_err or not data then
          vim.schedule(function()
            dbg("disconnected: " .. tostring(read_err))
            if conn == tcp then conn = nil end
            vim.api.nvim_out_write("live-share: disconnected from session\n")
          end)
          if not tcp:is_closing() then tcp:close() end
          return
        end

        if state == "handshaking" then
          hs_buf = hs_buf .. data
          local hend = hs_buf:find("\r\n\r\n", 1, true)
          if not hend then return end

          local headers = hs_buf:sub(1, hend + 3)
          local rest    = hs_buf:sub(hend + 4)
          hs_buf = nil

          dbg("WS handshake response: "
              .. headers:gsub("\r\n", " | "):sub(1, 300))

          if not headers:find("101") then
            vim.schedule(function()
              vim.api.nvim_err_writeln(
                "live-share: WS handshake failed — server replied:\n"
                .. headers:sub(1, 300))
            end)
            if not tcp:is_closing() then tcp:close() end
            return
          end

          dbg("WS handshake complete (encrypted=" .. tostring(session_key ~= nil) .. ")")
          state = "connected"
          if #rest > 0 then process_ws(rest) end
          return
        end

        process_ws(data)
      end)

      -- Send upgrade request after setting up the read handler
      tcp:write(websocket.client_request(host, ws_key))
    end
  end)
end

-- mode: "ws" (default) or "tcp"
function M.connect(host, port, key, mode, attempt)
  attempt     = attempt or 0
  mode        = mode or "ws"
  session_key = key
  conn_mode   = mode

  dbg("resolving " .. host)
  uv.getaddrinfo(host, nil, { socktype = "stream" }, function(err, res)
    if err or not res or #res == 0 then
      vim.schedule(function()
        vim.api.nvim_err_writeln(
          "live-share: could not resolve host '" .. host .. "': " .. tostring(err))
      end)
      return
    end
    dbg("resolved " .. host .. " -> " .. res[1].addr)
    do_connect(res[1].addr, port, key, host, mode, attempt)
  end)
end

function M.send(msg)
  if not (conn and not conn:is_closing()) then return end

  if conn_mode == "tcp" then
    local ok, frame = pcall(protocol.encode_raw, msg, session_key)
    if ok then
      conn:write(frame)
    else
      vim.schedule(function()
        vim.api.nvim_err_writeln("live-share: encode error: " .. tostring(frame))
      end)
    end
  else
    local ok, payload = pcall(protocol.encode, msg, session_key)
    if ok then
      conn:write(websocket.encode_frame(payload, true))  -- client→server: masked
    else
      vim.schedule(function()
        vim.api.nvim_err_writeln("live-share: encode error: " .. tostring(payload))
      end)
    end
  end
end

function M.stop()
  if conn and not conn:is_closing() then
    conn:close()
    conn = nil
  end
  session_key = nil
  conn_mode   = "ws"
end

return M
