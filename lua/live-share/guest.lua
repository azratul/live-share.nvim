-- Guest (client) logic: connects to a host session, manages the remote
-- workspace view, and handles all inbound protocol events.
local M = {}

local connection = require("live-share.collab.connection")
local dispatch = require("live-share.guest.dispatch")
local buffer_registry = require("live-share.buffer_registry")
local presence = require("live-share.presence")
local follow = require("live-share.follow")
local session = require("live-share.session")
local crypto = require("live-share.collab.crypto")
local log = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local config = nil
local conn = nil
local cursor_timer = nil
local cursor_aug = vim.api.nvim_create_augroup("LiveShareGuestCursor", { clear = true })

-- Mutable protocol state, shared by reference with guest/dispatch.lua's handlers.
-- Scalars live on this table (rather than as module locals) so the dispatch
-- module can mutate them in place; the table itself is never reassigned, so the
-- reference handed to `ctx` stays valid for the session's lifetime.
---@type LiveShare.GuestState
local gstate = {
  state = "handshake", -- "handshake" | "workspace_sync" | "active"
  guest_role = nil, -- "rw" | "ro" — set from the hello message
  workspace_files = {}, -- flat list of paths in the remote workspace
  workspace_root_name = nil,
  ws_chunks_seen = 0, -- v4 stage 6: counts incoming workspace_info_chunk messages
  msg_buffer = {}, -- patches/cursors buffered during workspace_sync
  sync_timer = nil, -- 10 s watchdog; cancelled when open_files_snapshot arrives
  last_seq_seen = nil, -- global monotonic seq; nil = accept any as first
}

local function get_username()
  return (config and config.username and config.username ~= "" and config.username)
    or (vim.g.live_share_username ~= nil and vim.g.live_share_username ~= "" and vim.g.live_share_username)
    or "guest"
end

-- ── Per-buffer autocmds ───────────────────────────────────────────────────────

local function register_cursor_emit(b, path)
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = cursor_aug,
    buffer = b,
    callback = function()
      local pos = vim.api.nvim_win_get_cursor(0)
      local mode = vim.fn.mode()
      local sel = nil
      if mode == "v" or mode == "V" or mode == "\22" then
        local vstart = vim.fn.getpos("v")
        local vend = vim.fn.getpos(".")
        local sl, sc = vstart[2] - 1, vstart[3] - 1
        local el, ec = vend[2] - 1, vend[3] - 1
        if sl > el or (sl == el and sc > ec) then
          sl, sc, el, ec = el, ec, sl, sc
        end
        if mode == "V" then
          sc = 0
          ec = 2147483647
        end
        sel = { sl = sl, sc = sc, el = el, ec = ec }
      end

      if cursor_timer then
        cursor_timer:stop()
      else
        cursor_timer = uv.new_timer()
      end
      cursor_timer:start(
        100,
        0,
        vim.schedule_wrap(function()
          local cmsg = {
            t = "cursor",
            path = path,
            lnum = pos[1] - 1,
            col = pos[2],
            name = get_username(),
          }
          if sel then
            cmsg.sel_lnum = sel.sl
            cmsg.sel_col = sel.sc
            cmsg.sel_end_lnum = sel.el
            cmsg.sel_end_col = sel.ec
          end
          conn:send(cmsg)
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = cursor_aug,
    buffer = b,
    callback = function()
      local old = vim.v.event.old_mode
      if old == "v" or old == "V" or old == "\22" then
        local pos = vim.api.nvim_win_get_cursor(0)
        conn:send({
          t = "cursor",
          path = path,
          lnum = pos[1] - 1,
          col = pos[2],
          name = get_username(),
        })
      end
    end,
  })
end

-- Tell the host which file the guest is currently looking at.
local function register_focus_emit(b, path)
  vim.api.nvim_create_autocmd("BufEnter", {
    group = cursor_aug,
    buffer = b,
    callback = function()
      conn:send({ t = "focus", path = path, name = get_username() })
    end,
  })
end

local function register_autocmds(b, path)
  register_cursor_emit(b, path)
  register_focus_emit(b, path)
end

-- ── Message handler ───────────────────────────────────────────────────────────

-- Context handed to the inbound-message handlers in guest/dispatch.lua.  It
-- shares this module's connection and protocol-state table and exposes the
-- helpers the handlers need (username, autocmd registration, stop).
---@type LiveShare.GuestContext
local ctx = {
  conn = nil,
  gstate = gstate,
  get_username = get_username,
  register_autocmds = register_autocmds,
  stop = function()
    M.stop()
  end,
}

-- Inbound host messages are routed by guest/dispatch.lua; this thin wrapper
-- just binds the per-message handlers to this session's `ctx`.
local function on_message(msg)
  dispatch.handle(ctx, msg)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.setup(cfg)
  config = cfg
  log.enabled = cfg and cfg.debug or false
end

function M.connect(host_addr, port, key_b64, mode)
  session.role = "guest"
  session.transport = mode or "ws"

  local session_key = nil
  if key_b64 and key_b64 ~= "" then
    if crypto.available then
      session_key = crypto.b64url_decode(key_b64)
    else
      vim.notify("live-share: cannot decrypt — OpenSSL not found", vim.log.levels.ERROR)
      session.role = nil
      return
    end
  end
  session.key = session_key

  -- Wire up local-edit → server callback (read-only guests never send patches).
  buffer_registry.setup(function(_, patch)
    if gstate.guest_role ~= "ro" then
      conn:send(patch)
    end
  end)

  -- Follow mode callback: switch to the host's active buffer.
  follow.setup(function(path, lnum, col)
    local b = buffer_registry.get_buf(path)
    if not b then
      -- We don't have the file yet — request it and switch when it arrives.
      conn:send({ t = "file_request", path = path })
    else
      vim.schedule(function()
        vim.api.nvim_set_current_buf(b)
        if lnum then
          pcall(vim.api.nvim_win_set_cursor, 0, { lnum + 1, col or 0 })
        end
      end)
    end
  end)

  if mode == "punch" then
    local ok_conn, punch_connector = pcall(connection.new_punch_connector, {
      key = session_key,
      on_msg = on_message,
      stun = (config and config.stun),
    })
    if not ok_conn then
      vim.notify("live-share: punch transport unavailable: " .. tostring(punch_connector), vim.log.levels.ERROR)
      session.role = nil
      return
    end
    conn = punch_connector
    ctx.conn = conn
    -- host_addr is the signaling server URL (e.g. "https://tunnel.host/...")
    require("live-share.shared_terminal").setup("guest", function(msg)
      conn:send(msg)
    end)
    conn:connect(host_addr, nil, function(err)
      if err then
        vim.schedule(function()
          vim.notify("live-share: connection failed: " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
      M.stop()
    end)
  else
    conn = connection.new_connector({ key = session_key, mode = mode or "ws", on_msg = on_message })
    ctx.conn = conn
    require("live-share.shared_terminal").setup("guest", function(msg)
      conn:send(msg)
    end)
    conn:connect(host_addr, port, function()
      M.stop()
    end)
  end
end

-- Request a specific file from the host workspace and open it.
-- If the buffer already exists, just switch to it.
function M.request_file(path)
  if session.role ~= "guest" then
    vim.notify("live-share: not connected as guest", vim.log.levels.WARN)
    return
  end
  local b = buffer_registry.get_buf(path)
  if b then
    vim.api.nvim_set_current_buf(b)
    return
  end
  conn:send({ t = "file_request", path = path })
end

function M.get_role()
  return gstate.guest_role
end

function M.get_workspace_files()
  return gstate.workspace_files
end

function M.get_workspace_root_name()
  return gstate.workspace_root_name
end

function M.stop()
  vim.api.nvim_clear_autocmds({ group = cursor_aug })
  if cursor_timer then
    cursor_timer:stop()
    cursor_timer:close()
    cursor_timer = nil
  end
  if gstate.sync_timer then
    gstate.sync_timer:stop()
    gstate.sync_timer:close()
    gstate.sync_timer = nil
  end
  presence.clear_all()
  follow.reset()
  require("live-share.shared_terminal").stop()
  buffer_registry.close_all()
  if conn then
    conn:stop()
    conn = nil
  end
  ctx.conn = nil
  gstate.workspace_files = {}
  gstate.workspace_root_name = nil
  gstate.ws_chunks_seen = 0
  gstate.guest_role = nil
  gstate.state = "handshake"
  gstate.msg_buffer = {}
  gstate.last_seq_seen = nil
  session.reset()
end

return M
