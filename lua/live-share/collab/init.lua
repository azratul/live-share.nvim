-- Public API for the native collaborative editing layer.
--
-- Multi-buffer model:
--   Host   — shares all open files; BufAdd/BufDelete autocmds keep the set live.
--   Client — receives a catalog on join; open_file/close_file keep it up to date.
--            Remote files are nofile buffers named liveshare://<sid>/<path>.
local M = {}

local server = require("live-share.collab.server")
local client = require("live-share.collab.client")
local sync   = require("live-share.collab.sync")
local cursor = require("live-share.collab.cursor")
local crypto = require("live-share.collab.crypto")
local log    = require("live-share.collab.log")
local uv     = vim.uv or vim.loop

local config         = nil
local seq            = 0        -- server-side monotonic sequence counter (global)
local sid            = nil      -- session id (random hex)
local peer_id        = nil      -- client's assigned peer id
local key            = nil      -- 32-byte session key, or nil (no encryption)
local workspace_root = nil      -- cwd at server start; used to make relative paths
local host_name      = nil      -- client-side: host's display name

local cursor_timer   = nil
local cursor_augroup = vim.api.nvim_create_augroup("LiveShareCursors", { clear = true })
local host_augroup   = vim.api.nvim_create_augroup("LiveShareHost",    { clear = true })

local function dbg(msg) log.dbg("collab", msg) end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function get_username()
  return (config and config.username ~= nil and config.username ~= "" and config.username)
      or (vim.g.live_share_username ~= nil and vim.g.live_share_username ~= "" and vim.g.live_share_username)
      or (vim.g.instant_username    ~= nil and vim.g.instant_username    ~= "" and vim.g.instant_username)
      or nil
end

local function random_sid()
  math.randomseed(os.time())
  local t = {}
  for i = 1, 32 do t[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(t)
end

local function peer_label(pid, name)
  if name and name ~= "" then return name end
  return "peer " .. tostring(pid)
end

-- Return a workspace-relative path; fall back to absolute if outside cwd.
local function make_path(abs_name)
  if workspace_root and abs_name:sub(1, #workspace_root) == workspace_root then
    local rel = abs_name:sub(#workspace_root + 2)
    if rel ~= "" then return rel end
  end
  return abs_name
end

-- True for normal file buffers that should be shared.
local function is_shareable(b)
  if not vim.api.nvim_buf_is_valid(b) then return false end
  if not vim.api.nvim_buf_is_loaded(b) then return false end
  if vim.fn.buflisted(b) == 0 then return false end
  if vim.bo[b].buftype ~= "" then return false end
  return vim.api.nvim_buf_get_name(b) ~= ""
end

-- ── Cursor emit ───────────────────────────────────────────────────────────────
-- One CursorMoved autocmd per buffer; all share a single debounce timer.

local function register_cursor_emit(b, path, send_fn)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group  = cursor_augroup,
    buffer = b,
    callback = function()
      if cursor_timer then
        cursor_timer:stop()
      else
        cursor_timer = uv.new_timer()
      end
      cursor_timer:start(100, 0, vim.schedule_wrap(function()
        -- 0 = current window; safe for buffer-local autocmds.
        local pos = vim.api.nvim_win_get_cursor(0)
        send_fn({ t = "cursor", path = path, lnum = pos[1] - 1, col = pos[2], name = get_username() })
      end))
    end,
  })
end

local function stop_cursor_emit()
  vim.api.nvim_clear_autocmds({ group = cursor_augroup })
  if cursor_timer then
    cursor_timer:stop()
    cursor_timer:close()
    cursor_timer = nil
  end
end

-- ── Server mode ───────────────────────────────────────────────────────────────

local function on_server_message(msg, from_peer)
  if msg.t == "connect" then
    server.send(from_peer, {
      t         = "hello",
      sid       = sid,
      peer_id   = from_peer,
      seq       = seq,
      host_name = get_username(),
    })
    seq = seq + 1

    -- Send a snapshot of every currently open file.
    local files = {}
    for path, lines in pairs(sync.get_all()) do
      files[#files + 1] = { path = path, lines = lines }
    end
    server.send(from_peer, { t = "catalog", seq = seq, files = files })
    vim.api.nvim_out_write("live-share: peer " .. from_peer .. " joined\n")

  elseif msg.t == "patch" then
    seq = seq + 1
    local stamped = {
      t     = "patch",
      seq   = seq,
      peer  = from_peer,
      path  = msg.path,
      lnum  = msg.lnum,
      count = msg.count,
      lines = msg.lines,
    }
    sync.apply(msg.path, stamped)
    server.broadcast(stamped, from_peer)

  elseif msg.t == "cursor" then
    local b = sync.get_buf(msg.path)
    if b then cursor.update(b, from_peer, msg.lnum, msg.col, msg.name) end
    server.broadcast({
      t    = "cursor",
      path = msg.path,
      peer = from_peer,
      lnum = msg.lnum,
      col  = msg.col,
      name = msg.name,
    }, from_peer)

  elseif msg.t == "bye" then
    cursor.remove_peer(from_peer)
    server.broadcast({ t = "bye", peer = from_peer, name = msg.name }, from_peer)
    vim.api.nvim_out_write(
      "live-share: " .. peer_label(from_peer, msg.name) .. " left\n")
  end
end

function M.start_server(port)
  sid            = random_sid()
  seq            = 0
  workspace_root = vim.fn.getcwd()

  if crypto.available then
    key = crypto.generate_key()
  else
    key = nil
    vim.notify(
      "live-share: OpenSSL not found — session will run WITHOUT encryption",
      vim.log.levels.WARN)
  end

  server.setup(on_server_message)

  -- Broadcast local changes from any tracked buffer.
  sync.setup(function(path, patch)
    seq       = seq + 1
    patch.seq  = seq
    patch.peer = 0
    server.broadcast(patch)
  end)

  local ip            = (config and config.ip_local) or "127.0.0.1"
  local p             = port or (config and config.port_internal) or 9876
  local broadcast_cur = function(msg) msg.peer = 0; server.broadcast(msg) end

  -- Attach to all files already open when the server starts.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if is_shareable(b) then
      local path = make_path(vim.api.nvim_buf_get_name(b))
      sync.attach_host(path, b)
      register_cursor_emit(b, path, broadcast_cur)
      dbg("sharing existing buffer: " .. path)
    end
  end

  -- Share files the host opens during the session.
  vim.api.nvim_create_autocmd("BufAdd", {
    group    = host_augroup,
    callback = function(ev)
      local b = ev.buf
      -- Defer: BufAdd fires before buftype / name are fully set.
      vim.schedule(function()
        if not is_shareable(b) then return end
        local path = make_path(vim.api.nvim_buf_get_name(b))
        if sync.get_buf(path) then return end  -- already tracked
        sync.attach_host(path, b)
        register_cursor_emit(b, path, broadcast_cur)
        server.broadcast({ t = "open_file", path = path, lines = sync.get_lines(path) })
        dbg("new file shared: " .. path)
      end)
    end,
  })

  -- Stop sharing files the host closes.
  vim.api.nvim_create_autocmd("BufDelete", {
    group    = host_augroup,
    callback = function(ev)
      -- Use reverse lookup: the name may be gone by the time we run.
      local path = sync.get_path_for_buf(ev.buf)
      if not path then return end
      local b = sync.get_buf(path)
      if b then cursor.clear_buf(b) end
      sync.detach(path)
      server.broadcast({ t = "close_file", path = path })
      dbg("file unshared: " .. path)
    end,
  })

  server.start(ip, p, key)
  vim.api.nvim_out_write("live-share: server started on port " .. p .. "\n")
end

-- ── Client mode ───────────────────────────────────────────────────────────────

local function on_client_message(msg)
  if msg.t == "hello" then
    peer_id   = msg.peer_id
    sid       = msg.sid
    host_name = msg.host_name

  elseif msg.t == "catalog" then
    if not msg.files or #msg.files == 0 then
      vim.api.nvim_out_write("live-share: session joined — no files open yet\n")
      return
    end

    local send_fn   = function(m) client.send(m) end
    local first_buf = nil
    local names     = {}

    for _, f in ipairs(msg.files) do
      local b = sync.attach_remote(f.path, f.lines, sid)
      register_cursor_emit(b, f.path, send_fn)
      names[#names + 1] = f.path
      if not first_buf then first_buf = b end
    end

    -- Show the first file in the current window.
    if first_buf then
      vim.api.nvim_set_current_buf(first_buf)
    end

    local who  = peer_label(peer_id, get_username())
    local hstr = host_name and (" (host: " .. host_name .. ")") or ""
    vim.api.nvim_out_write(
      "live-share: joined as " .. who .. hstr
      .. " — " .. #names .. " file(s): " .. table.concat(names, ", ") .. "\n")

  elseif msg.t == "open_file" then
    if not msg.path then return end
    local send_fn = function(m) client.send(m) end
    local b = sync.attach_remote(msg.path, msg.lines or {}, sid)
    register_cursor_emit(b, msg.path, send_fn)
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_out_write("live-share: file opened by host: " .. msg.path .. "\n")

  elseif msg.t == "close_file" then
    if not msg.path then return end
    local b = sync.get_buf(msg.path)
    if b then cursor.clear_buf(b) end
    sync.detach(msg.path)
    vim.api.nvim_out_write("live-share: file closed by host: " .. msg.path .. "\n")

  elseif msg.t == "patch" then
    if msg.path then sync.apply(msg.path, msg) end

  elseif msg.t == "cursor" then
    if not msg.path then return end
    local b = sync.get_buf(msg.path)
    if not b then return end
    local name = msg.name or (msg.peer == 0 and host_name) or nil
    cursor.update(b, msg.peer, msg.lnum, msg.col, name)

  elseif msg.t == "bye" then
    cursor.remove_peer(msg.peer)
    local name = msg.name or (msg.peer == 0 and host_name) or nil
    vim.api.nvim_out_write(
      "live-share: " .. peer_label(msg.peer, name) .. " left\n")
  end
end

-- key_b64: base64url-encoded key string from the URL fragment, or nil.
-- mode:    "ws" (HTTP tunnel providers) | "tcp" (direct/ngrok tcp://).
function M.join_session(host, port, key_b64, mode)
  local session_key = nil
  if key_b64 and key_b64 ~= "" then
    if crypto.available then
      session_key = crypto.b64url_decode(key_b64)
    else
      vim.notify(
        "live-share: OpenSSL not found — cannot decrypt session",
        vim.log.levels.ERROR)
      return
    end
  end

  -- Wire up the sync callback before connecting so it is ready when catalog arrives.
  sync.setup(function(_, patch) client.send(patch) end)

  client.setup(on_client_message)
  client.connect(host, tonumber(port), session_key, mode or "ws")
end

-- ── Stop ──────────────────────────────────────────────────────────────────────

function M.stop()
  stop_cursor_emit()
  vim.api.nvim_clear_autocmds({ group = host_augroup })
  cursor.clear_all()
  sync.detach_all()
  server.stop()
  client.stop()
  seq            = 0
  sid            = nil
  peer_id        = nil
  host_name      = nil
  key            = nil
  workspace_root = nil
end

M.stop_server = M.stop
M.stop_client = M.stop

-- Exposed so tunnel.lua can append "#key=…" to the clipboard URL.
function M.get_key_fragment()
  if not key then return "" end
  return "#key=" .. crypto.b64url_encode(key)
end

function M.setup(cfg)
  config      = cfg
  log.enabled = cfg and cfg.debug or false
end

return M
