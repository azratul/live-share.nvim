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
local ws_chunks_seen = 0 -- v4 stage 6: counts incoming workspace_info_chunk messages
local cursor_timer = nil
local cursor_aug = vim.api.nvim_create_augroup("LiveShareGuestCursor", { clear = true })

-- Protocol state machine: "handshake" | "workspace_sync" | "active"
local state = "handshake"
local msg_buffer = {} -- patches/cursors buffered during workspace_sync
local sync_timer = nil -- 10 s watchdog; cancelled when open_files_snapshot arrives
local last_seq_seen = nil -- global monotonic seq; nil = accept any as first

-- Capabilities this client supports (must match what hello_ack advertises).
local SUPPORTED_CAPS = { workspace = true, cursor = true, follow = true, terminal = true }

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
  -- State gate: during handshake only hello/rejected are meaningful.
  if state == "handshake" then
    if msg.t ~= "hello" and msg.t ~= "rejected" then
      return
    end
  end

  -- State gate: during workspace_sync buffer patches/cursors and any other
  -- application-level messages (file_response, open_file, close_file, focus,
  -- terminal_*) so they replay after `open_files_snapshot` switches us to
  -- "active".  Previously these were silently dropped, which on a large
  -- workspace caused `:LiveShareOpen` issued right after approval to look
  -- like it did nothing — `file_response` arrived while the guest was still
  -- decoding the huge `workspace_info` and was discarded.  v4 stage 6 split
  -- workspace_info into chunks (`workspace_info_chunk` + `workspace_info_done`)
  -- so each individual message is small, but the gate still matters because
  -- the host sends peers_snapshot/open_files_snapshot AFTER the chunk stream;
  -- a fast guest could otherwise see file_response in between.  Only init
  -- and safety messages bypass the buffer.
  if state == "workspace_sync" then
    local init_or_safety = {
      workspace_info_chunk = true,
      workspace_info_done = true,
      peers_snapshot = true,
      open_files_snapshot = true,
      bye = true,
      rejected = true,
      error = true,
    }
    if not init_or_safety[msg.t] then
      msg_buffer[#msg_buffer + 1] = msg
      return
    end
  end

  -- ── hello ─────────────────────────────────────────────────────────────────
  if msg.t == "hello" then
    local protocol = require("live-share.collab.protocol")
    -- Strict version check (v4): a mismatch is fatal.  Earlier versions only
    -- warned, but with the lifecycle changes introduced in v4 (heartbeat
    -- format, max-frame size, capability semantics) silent best-effort
    -- interop is no longer safe — the session would either drift or stall.
    if msg.protocol_version and msg.protocol_version ~= protocol.VERSION then
      local theirs = msg.protocol_version
      vim.schedule(function()
        vim.notify(
          string.format(
            "live-share: protocol version mismatch (host=%d, ours=%d) — disconnecting. "
              .. "Both sides must run the same major version.",
            theirs,
            protocol.VERSION
          ),
          vim.log.levels.ERROR
        )
      end)
      pcall(function()
        conn:send({ t = "bye" })
      end)
      M.stop()
      return
    end

    -- Validate required caps before acknowledging (§7.4).
    for _, cap in ipairs(msg.required_caps or {}) do
      if not SUPPORTED_CAPS[cap] then
        vim.schedule(function()
          vim.notify(
            'live-share: this session requires capability "' .. cap .. '" which is not supported by this client.',
            vim.log.levels.ERROR
          )
        end)
        conn:send({ t = "bye" })
        M.stop()
        return
      end
    end

    session.peer_id = msg.peer_id
    session.sid = msg.sid
    guest_role = msg.role or "rw"
    session.host_required_caps = msg.required_caps or {}
    session.host_optional_caps = msg.optional_caps or {}
    -- Register the host in presence so they appear in :LiveSharePeers.
    presence.update_peer(0, msg.host_name or "host")

    -- Acknowledge and advertise all supported caps.
    conn:send({ t = "hello_ack", name = get_username(), caps = { "workspace", "cursor", "follow", "terminal" } })

    -- Transition to workspace_sync and start 10 s watchdog (§8).
    state = "workspace_sync"
    sync_timer = uv.new_timer()
    sync_timer:start(
      10000,
      0,
      vim.schedule_wrap(function()
        vim.notify("live-share: timed out waiting for workspace snapshot — disconnecting", vim.log.levels.ERROR)
        M.stop()
      end)
    )

    vim.schedule(function()
      local role_label = guest_role == "ro" and " [read-only]" or ""
      vim.api.nvim_out_write(
        "live-share: connected as " .. get_username() .. role_label .. " (host: " .. (msg.host_name or "?") .. ")\n"
      )
      local fp = session.key and crypto.fingerprint(session.key)
      if fp then
        vim.api.nvim_out_write("live-share: session fingerprint " .. fp .. " — verify with the host\n")
      end
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

  -- ── workspace_info_chunk ──────────────────────────────────────────────────
  -- v4 stage 6: the workspace file list is streamed in chunks of up to ~1000
  -- paths.  The first chunk (seq=1) carries `root_name`; subsequent chunks
  -- only carry `files`.  The list is consumable progressively — :LiveShareOpen
  -- works for any path already received without waiting for `workspace_info_done`.
  elseif msg.t == "workspace_info_chunk" then
    if msg.seq == 1 then
      workspace_files = {}
      workspace_root_name = msg.root_name
      ws_chunks_seen = 0
    end
    ws_chunks_seen = (ws_chunks_seen or 0) + 1
    -- Tolerate out-of-order seq numbers in principle (the host always sends
    -- in order today, but we guard anyway): we just append, since the only
    -- consumer is the file explorer and it tolerates any ordering.
    if type(msg.files) == "table" then
      for _, p in ipairs(msg.files) do
        workspace_files[#workspace_files + 1] = p
      end
    end

  -- ── workspace_info_done ───────────────────────────────────────────────────
  -- v4 stage 6: terminator for the chunk stream.  Carries `total_files` for
  -- a sanity check against the chunks we accumulated, and `truncated` so the
  -- guest can warn that the listing is incomplete.
  elseif msg.t == "workspace_info_done" then
    local got = #workspace_files
    local total = msg.total_files or got
    if got ~= total then
      vim.schedule(function()
        vim.notify(
          string.format(
            "live-share: workspace listing arrived incomplete (got %d of %d files) — :LiveShareWorkspace may be missing entries",
            got,
            total
          ),
          vim.log.levels.WARN
        )
      end)
    end
    vim.schedule(function()
      local suffix = msg.truncated and " — host-side cap hit, listing is truncated" or ""
      vim.api.nvim_out_write(
        "live-share: workspace '"
          .. (workspace_root_name or "?")
          .. "' ("
          .. got
          .. " files"
          .. suffix
          .. "). Use :LiveShareWorkspace to explore.\n"
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

    -- Transition to active state, cancel watchdog, flush buffered messages.
    state = "active"
    if sync_timer then
      sync_timer:stop()
      sync_timer:close()
      sync_timer = nil
    end
    local buffered = msg_buffer
    msg_buffer = {}
    for _, m in ipairs(buffered) do
      on_message(m)
    end

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
    -- A file_response replaces the buffer wholesale; reset seq tracking so the
    -- next patch is accepted regardless of its seq number.
    last_seq_seen = nil
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
    if not msg.path then
      return
    end

    -- Seq gap detection (§7.1): stale or duplicate → drop; gap → resync.
    if msg.seq then
      if last_seq_seen ~= nil and msg.seq <= last_seq_seen then
        dbg("stale patch for " .. msg.path .. " (seq=" .. msg.seq .. " last=" .. last_seq_seen .. ") — dropped")
        return
      end
      if last_seq_seen ~= nil and msg.seq > last_seq_seen + 1 then
        dbg("seq gap on " .. msg.path .. ": expected " .. (last_seq_seen + 1) .. " got " .. msg.seq)
        last_seq_seen = nil
        conn:send({ t = "file_request", path = msg.path })
        return
      end
      last_seq_seen = msg.seq
    end

    -- Out-of-range patch check (§7.2): lnum beyond buffer length → resync.
    if msg.count ~= -1 and msg.lnum then
      local b = buffer_registry.get_buf(msg.path)
      if b then
        local line_count = vim.api.nvim_buf_line_count(b)
        if msg.lnum > line_count then
          dbg("out-of-range patch on " .. msg.path .. " (lnum=" .. msg.lnum .. " lines=" .. line_count .. ")")
          last_seq_seen = nil
          conn:send({ t = "file_request", path = msg.path })
          return
        end
      end
    end

    vim.schedule(function()
      buffer_registry.apply(msg.path, msg)
    end)

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
    if follow.get_followed_peer() == msg.peer then
      follow.disable()
      vim.schedule(function()
        vim.notify("live-share: " .. label .. " left — follow mode disabled", vim.log.levels.WARN)
      end)
    else
      vim.schedule(function()
        vim.api.nvim_out_write("live-share: " .. label .. " left\n")
      end)
    end

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
  if sync_timer then
    sync_timer:stop()
    sync_timer:close()
    sync_timer = nil
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
  ws_chunks_seen = 0
  guest_role = nil
  state = "handshake"
  msg_buffer = {}
  last_seq_seen = nil
  session.reset()
end

return M
