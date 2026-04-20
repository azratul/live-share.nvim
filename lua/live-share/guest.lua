-- Guest (client) logic: connects to a host session, manages the remote
-- workspace view, and handles all inbound protocol events.
local M = {}

local connection = require("live-share.collab.connection")
local buffer_registry = require("live-share.buffer_registry")
local presence = require("live-share.presence")
local follow = require("live-share.follow")
local session = require("live-share.session")
local crypto = require("live-share.collab.crypto")
local log = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local config = nil
local conn = nil
local guest_role = nil -- "rw" | "ro" — set from the hello message
local workspace_files = {} -- flat list of paths in the remote workspace
local workspace_root_name = nil
local cursor_timer = nil
local cursor_aug = vim.api.nvim_create_augroup("LiveShareGuestCursor", { clear = true })

local function dbg(m)
  log.dbg("guest", m)
end

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

local function on_message(msg)
  -- ── hello ─────────────────────────────────────────────────────────────────
  if msg.t == "hello" then
    local protocol = require("live-share.collab.protocol")
    if msg.protocol_version and msg.protocol_version ~= protocol.VERSION then
      vim.schedule(function()
        vim.notify(
          string.format(
            "live-share: protocol version mismatch (host=%d, ours=%d) — behaviour may be undefined",
            msg.protocol_version,
            protocol.VERSION
          ),
          vim.log.levels.WARN
        )
      end)
    end
    session.peer_id = msg.peer_id
    session.sid = msg.sid
    guest_role = msg.role or "rw"
    session.host_required_caps = msg.required_caps or {}
    session.host_optional_caps = msg.optional_caps or {}
    -- Register the host in presence so they appear in :LiveSharePeers.
    presence.update_peer(0, msg.host_name or "host")
    conn:send({ t = "hello_ack", name = get_username(), caps = { "cursor", "follow" } })
    vim.schedule(function()
      local role_label = guest_role == "ro" and " [read-only]" or ""
      vim.api.nvim_out_write(
        "live-share: connected as " .. get_username() .. role_label .. " (host: " .. (msg.host_name or "?") .. ")\n"
      )
      if guest_role == "ro" then
        vim.notify("live-share: you joined as read-only — editing is disabled", vim.log.levels.WARN)
      end
    end)

  -- ── error ─────────────────────────────────────────────────────────────────
  elseif msg.t == "error" then
    vim.schedule(function()
      vim.notify(
        "live-share: host error [" .. (msg.code or "unknown") .. "] " .. (msg.message or ""),
        vim.log.levels.ERROR
      )
    end)

  -- ── rejected ─────────────────────────────────────────────────────────────
  elseif msg.t == "rejected" then
    vim.schedule(function()
      vim.api.nvim_err_writeln("live-share: connection rejected by host: " .. (msg.reason or "no reason given"))
      M.stop()
    end)

  -- ── peers_snapshot ────────────────────────────────────────────────────────
  -- Received on join: presence snapshot of all already-connected peers.
  elseif msg.t == "peers_snapshot" then
    for _, p in ipairs(msg.peers or {}) do
      presence.update_peer(p.peer_id, p.name, p.active_path)
    end

  -- ── workspace_info ────────────────────────────────────────────────────────
  -- Received right after hello: the full flat file list of the remote workspace.
  elseif msg.t == "workspace_info" then
    workspace_files = msg.files or {}
    workspace_root_name = msg.root_name
    vim.schedule(function()
      vim.api.nvim_out_write(
        "live-share: workspace '"
          .. (workspace_root_name or "?")
          .. "' ("
          .. #workspace_files
          .. " files). Use :LiveShareWorkspace to explore.\n"
      )
    end)

  -- ── open_files_snapshot ───────────────────────────────────────────────────
  -- Host's currently open files: create editable buffers for all of them.
  elseif msg.t == "open_files_snapshot" then
    for _, f in ipairs(msg.files or {}) do
      local b = buffer_registry.open(f.path, f.lines, session.sid, guest_role == "ro")
      if guest_role ~= "ro" then
        register_autocmds(b, f.path)
      end
    end
    dbg("received open_files_snapshot (" .. #(msg.files or {}) .. " file(s))")

  -- ── open_file ─────────────────────────────────────────────────────────────
  -- Host opened a new file during the session.
  elseif msg.t == "open_file" then
    if not msg.path then
      return
    end
    local existing = buffer_registry.get_buf(msg.path)
    if existing and vim.b[existing].live_share_readonly and guest_role ~= "ro" then
      buffer_registry.set_editable(msg.path)
      buffer_registry.apply(msg.path, { lnum = 0, count = -1, lines = msg.lines or {} })
    else
      local b = buffer_registry.open(msg.path, msg.lines, session.sid, guest_role == "ro")
      if guest_role ~= "ro" then
        register_autocmds(b, msg.path)
      end
    end

    if follow.is_enabled() then
      local b = buffer_registry.get_buf(msg.path)
      vim.schedule(function()
        if b then
          vim.api.nvim_set_current_buf(b)
        end
      end)
    else
      vim.schedule(function()
        vim.api.nvim_out_write(
          "live-share: host opened " .. msg.path .. "  (follow mode is off — use :LiveShareFollow to auto-switch)\n"
        )
      end)
    end

  -- ── close_file ────────────────────────────────────────────────────────────
  elseif msg.t == "close_file" then
    if not msg.path then
      return
    end
    local b = buffer_registry.get_buf(msg.path)
    if b then
      presence.clear_buf(b)
    end
    buffer_registry.close(msg.path)
    vim.schedule(function()
      vim.api.nvim_out_write("live-share: host closed " .. msg.path .. "\n")
    end)

  -- ── file_response ─────────────────────────────────────────────────────────
  elseif msg.t == "file_response" then
    if not msg.path then
      return
    end
    local ro = msg.readonly or (guest_role == "ro")
    local b = buffer_registry.open(msg.path, msg.lines, session.sid, ro)
    if not ro then
      register_autocmds(b, msg.path)
    end
    vim.schedule(function()
      vim.api.nvim_set_current_buf(b)
    end)

  -- ── patch ─────────────────────────────────────────────────────────────────
  elseif msg.t == "patch" then
    if msg.path then
      vim.schedule(function()
        buffer_registry.apply(msg.path, msg)
      end)
    end

  -- ── save_file ─────────────────────────────────────────────────────────────
  elseif msg.t == "save_file" then
    if msg.path then
      vim.schedule(function()
        vim.api.nvim_out_write("live-share: host saved " .. msg.path .. "\n")
      end)
    end

  -- ── focus ─────────────────────────────────────────────────────────────────
  -- A peer switched their active buffer.
  elseif msg.t == "focus" then
    if not msg.path then
      return
    end
    presence.update_focus(msg.peer, msg.path, msg.name)
    follow.maybe_follow(msg.path, nil, nil, msg.peer)

  -- ── cursor ────────────────────────────────────────────────────────────────
  elseif msg.t == "cursor" then
    if not msg.path then
      return
    end
    local b = buffer_registry.get_buf(msg.path)
    if not b then
      return
    end
    local name = msg.name or (msg.peer == 0 and "host") or nil
    local sel = msg.sel_lnum
        and {
          lnum = msg.sel_lnum,
          col = msg.sel_col,
          end_lnum = msg.sel_end_lnum,
          end_col = msg.sel_end_col,
        }
      or nil
    vim.schedule(function()
      presence.update_cursor(b, msg.peer, msg.lnum, msg.col, name, msg.path, sel)
    end)

  -- ── bye ───────────────────────────────────────────────────────────────────
  elseif msg.t == "bye" then
    presence.remove_peer(msg.peer)
    local label = msg.name or (msg.peer == 0 and "host") or ("peer " .. tostring(msg.peer))
    vim.schedule(function()
      vim.api.nvim_out_write("live-share: " .. label .. " left\n")
    end)

  -- ── terminal_open ─────────────────────────────────────────────────────────
  elseif msg.t == "terminal_open" then
    vim.schedule(function()
      require("live-share.shared_terminal").open_guest(msg.term_id, msg.name)
    end)

  -- ── terminal_data ─────────────────────────────────────────────────────────
  elseif msg.t == "terminal_data" then
    vim.schedule(function()
      require("live-share.shared_terminal").on_data(msg.term_id, msg.data)
    end)

  -- ── terminal_close ────────────────────────────────────────────────────────
  elseif msg.t == "terminal_close" then
    vim.schedule(function()
      require("live-share.shared_terminal").on_close(msg.term_id)
    end)
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.setup(cfg)
  config = cfg
  log.enabled = cfg and cfg.debug or false
end

function M.connect(host_addr, port, key_b64, mode)
  session.role = "guest"

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
    if guest_role ~= "ro" then
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
  return guest_role
end

function M.get_workspace_files()
  return workspace_files
end

function M.get_workspace_root_name()
  return workspace_root_name
end

function M.stop()
  vim.api.nvim_clear_autocmds({ group = cursor_aug })
  if cursor_timer then
    cursor_timer:stop()
    cursor_timer:close()
    cursor_timer = nil
  end
  presence.clear_all()
  follow.reset()
  require("live-share.shared_terminal").stop()
  buffer_registry.close_all()
  if conn then
    conn:stop()
    conn = nil
  end
  workspace_files = {}
  workspace_root_name = nil
  guest_role = nil
  session.reset()
end

return M
