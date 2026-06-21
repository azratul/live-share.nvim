-- Guest inbound-message dispatch.
--
-- Routes a decoded host message to a per-type handler, after applying the
-- protocol state gate (handshake → workspace_sync → active).  Extracted from
-- guest.lua to keep that module focused on connection lifecycle and the
-- local-edit/cursor autocmds.
--
-- Handlers receive a `ctx` (see LiveShare.GuestContext) carrying the live
-- connection, the shared protocol-state table (`gstate`), and the helpers
-- guest.lua owns (username, autocmd registration, stop).  All mutable
-- protocol state lives on `gstate` so both modules share it by reference.
local M = {}

local buffer_registry = require("live-share.buffer_registry")
local presence = require("live-share.presence")
local follow = require("live-share.follow")
local session = require("live-share.session")
local crypto = require("live-share.collab.crypto")
local log = require("live-share.collab.log")

local function dbg(m)
  log.dbg("guest", m)
end

-- Capabilities this client supports (must match what hello_ack advertises).
local SUPPORTED_CAPS = { workspace = true, cursor = true, follow = true, terminal = true }

---Mutable guest protocol state, shared by reference with guest.lua.
---@class LiveShare.GuestState
---@field state "handshake"|"workspace_sync"|"active" protocol state machine
---@field guest_role LiveShare.Role|nil role assigned by the host's hello
---@field workspace_files string[] flat list of remote workspace paths
---@field workspace_root_name string|nil display name of the workspace root
---@field ws_chunks_seen integer count of received workspace_info_chunk messages
---@field msg_buffer LiveShare.Message[] messages buffered during workspace_sync
---@field sync_timer uv_timer_t|nil 10s watchdog, cancelled on open_files_snapshot
---@field last_seq_seen integer|nil global monotonic seq; nil accepts any as first

---State and helpers guest.lua hands to its message handlers.
---@class LiveShare.GuestContext
---@field conn LiveShare.Connector the active guest connection (set by guest.lua on connect)
---@field gstate LiveShare.GuestState shared mutable protocol state
---@field get_username fun(): string the guest's display name
---@field register_autocmds fun(buf: integer, path: string) wire cursor/focus emit autocmds for a buffer
---@field stop fun() tear down the guest session

-- Per-type handlers, keyed by `msg.t`.  Each receives (ctx, msg).
local handlers = {}

-- ── hello ─────────────────────────────────────────────────────────────────
function handlers.hello(ctx, msg)
  local conn = ctx.conn
  local g = ctx.gstate
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
    ctx.stop()
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
      ctx.stop()
      return
    end
  end

  session.peer_id = msg.peer_id
  session.sid = msg.sid
  g.guest_role = msg.role or "rw"
  session.host_required_caps = msg.required_caps or {}
  session.host_optional_caps = msg.optional_caps or {}
  -- Register the host in presence so they appear in :LiveSharePeers.
  presence.update_peer(0, msg.host_name or "host")

  -- Acknowledge and advertise all supported caps.
  conn:send({ t = "hello_ack", name = ctx.get_username(), caps = { "workspace", "cursor", "follow", "terminal" } })

  -- Transition to workspace_sync and start 10 s watchdog (§8).
  g.state = "workspace_sync"
  g.sync_timer = vim.uv.new_timer()
  g.sync_timer:start(
    10000,
    0,
    vim.schedule_wrap(function()
      vim.notify("live-share: timed out waiting for workspace snapshot — disconnecting", vim.log.levels.ERROR)
      ctx.stop()
    end)
  )

  vim.schedule(function()
    local role_label = g.guest_role == "ro" and " [read-only]" or ""
    vim.api.nvim_out_write(
      "live-share: connected as " .. ctx.get_username() .. role_label .. " (host: " .. (msg.host_name or "?") .. ")\n"
    )
    local fp = session.key and crypto.fingerprint(session.key)
    if fp then
      vim.api.nvim_out_write("live-share: session fingerprint " .. fp .. " — verify with the host\n")
    end
    if g.guest_role == "ro" then
      vim.notify("live-share: you joined as read-only — editing is disabled", vim.log.levels.WARN)
    end
  end)
end

-- ── error ─────────────────────────────────────────────────────────────────
function handlers.error(_ctx, msg)
  vim.schedule(function()
    vim.notify(
      "live-share: host error [" .. (msg.code or "unknown") .. "] " .. (msg.message or ""),
      vim.log.levels.ERROR
    )
  end)
end

-- ── rejected ───────────────────────────────────────────────────────────────
function handlers.rejected(ctx, msg)
  vim.schedule(function()
    vim.api.nvim_err_writeln("live-share: connection rejected by host: " .. (msg.reason or "no reason given"))
    ctx.stop()
  end)
end

-- ── peers_snapshot ──────────────────────────────────────────────────────────
-- Received on join: presence snapshot of all already-connected peers.
function handlers.peers_snapshot(_ctx, msg)
  for _, p in ipairs(msg.peers or {}) do
    presence.update_peer(p.peer_id, p.name, p.active_path)
  end
end

-- ── workspace_info_chunk ────────────────────────────────────────────────────
-- v4 stage 6: the workspace file list is streamed in chunks of up to ~1000
-- paths.  The first chunk (seq=1) carries `root_name`; subsequent chunks
-- only carry `files`.  The list is consumable progressively — :LiveShareOpen
-- works for any path already received without waiting for `workspace_info_done`.
function handlers.workspace_info_chunk(ctx, msg)
  local g = ctx.gstate
  if msg.seq == 1 then
    g.workspace_files = {}
    g.workspace_root_name = msg.root_name
    g.ws_chunks_seen = 0
  end
  g.ws_chunks_seen = (g.ws_chunks_seen or 0) + 1
  -- Tolerate out-of-order seq numbers in principle (the host always sends
  -- in order today, but we guard anyway): we just append, since the only
  -- consumer is the file explorer and it tolerates any ordering.
  if type(msg.files) == "table" then
    for _, p in ipairs(msg.files) do
      g.workspace_files[#g.workspace_files + 1] = p
    end
  end
end

-- ── workspace_info_done ─────────────────────────────────────────────────────
-- v4 stage 6: terminator for the chunk stream.  Carries `total_files` for
-- a sanity check against the chunks we accumulated, and `truncated` so the
-- guest can warn that the listing is incomplete.
function handlers.workspace_info_done(ctx, msg)
  local g = ctx.gstate
  local got = #g.workspace_files
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
        .. (g.workspace_root_name or "?")
        .. "' ("
        .. got
        .. " files"
        .. suffix
        .. "). Use :LiveShareWorkspace to explore.\n"
    )
  end)
end

-- ── open_files_snapshot ─────────────────────────────────────────────────────
-- Host's currently open files: create editable buffers for all of them.
function handlers.open_files_snapshot(ctx, msg)
  local g = ctx.gstate
  for _, f in ipairs(msg.files or {}) do
    local b = buffer_registry.open(f.path, f.lines, session.sid, g.guest_role == "ro")
    if g.guest_role ~= "ro" then
      ctx.register_autocmds(b, f.path)
    end
  end
  dbg("received open_files_snapshot (" .. #(msg.files or {}) .. " file(s))")

  -- Transition to active state, cancel watchdog, flush buffered messages.
  g.state = "active"
  if g.sync_timer then
    g.sync_timer:stop()
    g.sync_timer:close()
    g.sync_timer = nil
  end
  local buffered = g.msg_buffer
  g.msg_buffer = {}
  for _, m in ipairs(buffered) do
    M.handle(ctx, m)
  end
end

-- ── open_file ───────────────────────────────────────────────────────────────
-- Host opened a new file during the session.
function handlers.open_file(ctx, msg)
  local g = ctx.gstate
  if not msg.path then
    return
  end
  local existing = buffer_registry.get_buf(msg.path)
  if existing and vim.b[existing].live_share_readonly and g.guest_role ~= "ro" then
    buffer_registry.set_editable(msg.path)
    buffer_registry.apply(msg.path, { lnum = 0, count = -1, lines = msg.lines or {} })
  else
    local b = buffer_registry.open(msg.path, msg.lines, session.sid, g.guest_role == "ro")
    if g.guest_role ~= "ro" then
      ctx.register_autocmds(b, msg.path)
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
end

-- ── close_file ──────────────────────────────────────────────────────────────
function handlers.close_file(_ctx, msg)
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
end

-- ── file_response ───────────────────────────────────────────────────────────
function handlers.file_response(ctx, msg)
  local g = ctx.gstate
  if not msg.path then
    return
  end
  -- A file_response replaces the buffer wholesale; reset seq tracking so the
  -- next patch is accepted regardless of its seq number.
  g.last_seq_seen = nil
  local ro = msg.readonly or (g.guest_role == "ro")
  local b = buffer_registry.open(msg.path, msg.lines, session.sid, ro)
  if not ro then
    ctx.register_autocmds(b, msg.path)
  end
  vim.schedule(function()
    vim.api.nvim_set_current_buf(b)
  end)
end

-- ── patch ───────────────────────────────────────────────────────────────────
function handlers.patch(ctx, msg)
  local conn = ctx.conn
  local g = ctx.gstate
  if not msg.path then
    return
  end

  -- Seq gap detection (§7.1): stale or duplicate → drop; gap → resync.
  if msg.seq then
    if g.last_seq_seen ~= nil and msg.seq <= g.last_seq_seen then
      dbg("stale patch for " .. msg.path .. " (seq=" .. msg.seq .. " last=" .. g.last_seq_seen .. ") — dropped")
      return
    end
    if g.last_seq_seen ~= nil and msg.seq > g.last_seq_seen + 1 then
      dbg("seq gap on " .. msg.path .. ": expected " .. (g.last_seq_seen + 1) .. " got " .. msg.seq)
      g.last_seq_seen = nil
      conn:send({ t = "file_request", path = msg.path })
      return
    end
    g.last_seq_seen = msg.seq
  end

  -- Out-of-range patch check (§7.2): lnum beyond buffer length → resync.
  if msg.count ~= -1 and msg.lnum then
    local b = buffer_registry.get_buf(msg.path)
    if b then
      local line_count = vim.api.nvim_buf_line_count(b)
      if msg.lnum > line_count then
        dbg("out-of-range patch on " .. msg.path .. " (lnum=" .. msg.lnum .. " lines=" .. line_count .. ")")
        g.last_seq_seen = nil
        conn:send({ t = "file_request", path = msg.path })
        return
      end
    end
  end

  vim.schedule(function()
    buffer_registry.apply(msg.path, msg)
  end)
end

-- ── save_file ───────────────────────────────────────────────────────────────
function handlers.save_file(_ctx, msg)
  if msg.path then
    vim.schedule(function()
      vim.api.nvim_out_write("live-share: host saved " .. msg.path .. "\n")
    end)
  end
end

-- ── focus ───────────────────────────────────────────────────────────────────
-- A peer switched their active buffer.
function handlers.focus(_ctx, msg)
  if not msg.path then
    return
  end
  presence.update_focus(msg.peer, msg.path, msg.name)
  follow.maybe_follow(msg.path, nil, nil, msg.peer)
end

-- ── cursor ──────────────────────────────────────────────────────────────────
function handlers.cursor(_ctx, msg)
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
end

-- ── bye ─────────────────────────────────────────────────────────────────────
function handlers.bye(_ctx, msg)
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
end

-- ── terminal_open ───────────────────────────────────────────────────────────
function handlers.terminal_open(_ctx, msg)
  vim.schedule(function()
    require("live-share.shared_terminal").open_guest(msg.term_id, msg.name)
  end)
end

-- ── terminal_data ───────────────────────────────────────────────────────────
function handlers.terminal_data(_ctx, msg)
  vim.schedule(function()
    require("live-share.shared_terminal").on_data(msg.term_id, msg.data)
  end)
end

-- ── terminal_close ──────────────────────────────────────────────────────────
function handlers.terminal_close(_ctx, msg)
  vim.schedule(function()
    require("live-share.shared_terminal").on_close(msg.term_id)
  end)
end

---Route a decoded host message, applying the protocol state gate first.
---@param ctx LiveShare.GuestContext
---@param msg LiveShare.Message
function M.handle(ctx, msg)
  local g = ctx.gstate

  -- State gate: during handshake only hello/rejected are meaningful.
  if g.state == "handshake" then
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
  if g.state == "workspace_sync" then
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
      g.msg_buffer[#g.msg_buffer + 1] = msg
      return
    end
  end

  local h = handlers[msg.t]
  if h then
    h(ctx, msg)
  end
end

return M
