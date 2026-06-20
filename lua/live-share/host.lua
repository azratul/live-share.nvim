-- Host logic: serves the workspace, manages tracked buffers, handles
-- incoming messages from guests, and emits protocol events.
--
-- Sync strategy (MVP): line-level last-write-wins.
--   The host assigns a monotonically increasing `seq` to every PATCH and is
--   the ordering authority.  No CRDT — sufficient for low-latency sessions.
--   For files not open in Neovim the patch is applied directly to disk.
local M = {}

local connection = require("live-share.collab.connection")
local dispatch = require("live-share.host.dispatch")
local workspace = require("live-share.workspace")
local presence = require("live-share.presence")
local follow = require("live-share.follow")
local session = require("live-share.session")
local crypto = require("live-share.collab.crypto")
local audit = require("live-share.audit")
local log = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local config = nil
local conn = nil
local seq = 0

-- tracked[path] = { buf_id, applying }  — Neovim buffers currently open by host
local tracked = {}
local host_aug = vim.api.nvim_create_augroup("LiveShareHost", { clear = true })
local cursor_aug = vim.api.nvim_create_augroup("LiveShareHostCursor", { clear = true })
local cursor_timer = nil

local function dbg(m)
  log.dbg("host", m)
end

local function get_username()
  return (config and config.username and config.username ~= "" and config.username)
    or (vim.g.live_share_username ~= nil and vim.g.live_share_username ~= "" and vim.g.live_share_username)
    or "host"
end

-- Context handed to the inbound-message handlers in host/dispatch.lua.  It
-- shares this module's mutable state (the live connection, the tracked-buffer
-- table) and the seq/username accessors, so the handlers operate on the same
-- session without owning any of it.  `tracked` is cleared in place (never
-- reassigned) so this reference stays valid for the session's lifetime.
---@type LiveShare.HostContext
local ctx = {
  conn = nil,
  tracked = tracked,
  get_username = get_username,
  next_seq = function()
    seq = seq + 1
    return seq
  end,
}

-- ── Buffer tracking ───────────────────────────────────────────────────────────

local function make_path(abs)
  local root = workspace.get_root()
  if root and abs:sub(1, #root) == root then
    local rel = abs:sub(#root + 2)
    if rel ~= "" then
      return rel
    end
  end
  return abs
end

local function is_shareable(b)
  if not vim.api.nvim_buf_is_valid(b) then
    return false
  end
  if not vim.api.nvim_buf_is_loaded(b) then
    return false
  end
  if vim.fn.buflisted(b) == 0 then
    return false
  end
  if vim.bo[b].buftype ~= "" then
    return false
  end
  return vim.api.nvim_buf_get_name(b) ~= ""
end

-- Attach to a Neovim buffer and start watching it for local edits.
-- Returns the workspace-relative path if newly attached, nil otherwise.
local function attach_buffer(b)
  if not is_shareable(b) then
    return nil
  end
  local path = make_path(vim.api.nvim_buf_get_name(b))
  if tracked[path] then
    return nil
  end -- already tracked

  local applying = { value = false }
  tracked[path] = { buf_id = b, applying = applying }

  vim.api.nvim_buf_attach(b, false, {
    on_lines = function(_, buf, _, firstline, lastline, new_lastline)
      if applying.value then
        return
      end
      if firstline == lastline and new_lastline == firstline then
        return
      end
      seq = seq + 1
      local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)
      conn:broadcast({
        t = "patch",
        path = path,
        seq = seq,
        peer = 0,
        lnum = firstline,
        count = lastline - firstline,
        lines = lines,
      })
    end,
    on_detach = function()
      tracked[path] = nil
    end,
  })

  -- Per-buffer cursor emit, debounced at 100 ms.
  -- Position and selection are captured synchronously at event time so the
  -- 100 ms delay does not cause a stale mode read.
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
            peer = 0,
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
          conn:broadcast(cmsg)
        end)
      )
    end,
  })

  -- CursorMoved does not fire when leaving visual mode without moving the cursor
  -- (e.g. <Esc>). Send an immediate clear so remote highlights don't linger.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = cursor_aug,
    buffer = b,
    callback = function()
      local old = vim.v.event.old_mode
      if old == "v" or old == "V" or old == "\22" then
        local pos = vim.api.nvim_win_get_cursor(0)
        conn:broadcast({
          t = "cursor",
          path = path,
          peer = 0,
          lnum = pos[1] - 1,
          col = pos[2],
          name = get_username(),
        })
      end
    end,
  })

  dbg("tracking buffer: " .. path)
  return path
end

-- ── Message dispatch ──────────────────────────────────────────────────────────

-- Inbound guest messages are routed by host/dispatch.lua; this thin wrapper
-- just binds the per-message handlers to this session's `ctx`.
local function on_message(msg, from_peer)
  dispatch.handle(ctx, msg, from_peer)
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.setup(cfg)
  config = cfg
  log.enabled = cfg and cfg.debug or false
end

function M.start(port)
  local root = (config and config.workspace_root and config.workspace_root ~= "") and config.workspace_root
    or vim.fn.getcwd()
  workspace.setup(config or {})
  workspace.set_root(root)
  session.id = M.random_sid()
  session.role = "host"
  seq = 0
  audit.setup(config or {})
  audit.set_session(session.id)
  audit.log(
    "session_start",
    { workspace = vim.fn.fnamemodify(root, ":t"), transport = (config and config.transport) or "ws" }
  )

  if crypto.available and crypto.x25519_available then
    -- Full v4: AES-GCM with per-peer subkeys derived via X25519 + HKDF.
    session.key = crypto.generate_key()
  elseif crypto.available then
    -- AES-GCM exists but X25519 (OpenSSL ≥ 1.1.1) does not.  Stage 4
    -- requires X25519 for forward secrecy, so fall back to plaintext rather
    -- than silently downgrading to master-key encryption — the user can
    -- upgrade OpenSSL to recover encryption.
    session.key = nil
    vim.notify(
      "live-share: OpenSSL too old for X25519 (need ≥ 1.1.1) — session runs WITHOUT encryption",
      vim.log.levels.WARN
    )
  else
    session.key = nil
    vim.notify("live-share: OpenSSL not found — session runs WITHOUT encryption", vim.log.levels.WARN)
  end

  local p
  if config and config.transport == "punch" then
    local ok_conn, punch_listener = pcall(connection.new_punch_listener, {
      key = session.key,
      on_msg = on_message,
      stun = config.stun,
    })
    if not ok_conn then
      vim.notify("live-share: punch transport unavailable: " .. tostring(punch_listener), vim.log.levels.ERROR)
      M.stop()
      return false
    end
    conn = punch_listener
    conn:listen()
    p = conn.signaling_port
  else
    conn = connection.new_listener({ key = session.key, on_msg = on_message })
    local ip = (config and config.ip_local) or "127.0.0.1"
    p = port or (config and config.port_internal) or 9876
    if not conn:listen(ip, p) then
      M.stop()
      return false
    end
  end

  -- Hand the live connection to the message handlers.
  ctx.conn = conn

  require("live-share.shared_terminal").setup("host", function(msg)
    conn:broadcast(msg)
  end, { scrollback_bytes = config and config.terminal_scrollback_bytes })

  -- Follow mode: when host follows a guest, switch to their active tracked buffer.
  follow.setup(function(path, lnum, col)
    local t = tracked[path]
    if t and vim.api.nvim_buf_is_valid(t.buf_id) then
      vim.schedule(function()
        vim.api.nvim_set_current_buf(t.buf_id)
        if lnum then
          pcall(vim.api.nvim_win_set_cursor, 0, { lnum + 1, col or 0 })
        end
      end)
    end
  end)

  -- Attach to all currently open files.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    attach_buffer(b)
  end

  -- New files opened by the host during the session.
  vim.api.nvim_create_autocmd("BufAdd", {
    group = host_aug,
    callback = function(ev)
      local b = ev.buf
      vim.schedule(function()
        local path = attach_buffer(b)
        if path then
          local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          conn:broadcast({ t = "open_file", path = path, lines = lines })
        end
      end)
    end,
  })

  -- Files closed by the host.
  vim.api.nvim_create_autocmd("BufDelete", {
    group = host_aug,
    callback = function(ev)
      for path, t in pairs(tracked) do
        if t.buf_id == ev.buf then
          local b = ev.buf
          presence.clear_buf(b)
          tracked[path] = nil
          conn:broadcast({ t = "close_file", path = path })
          dbg("unshared: " .. path)
          break
        end
      end
    end,
  })

  -- Focus events: host switched active buffer.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = host_aug,
    callback = function(ev)
      vim.schedule(function()
        local path = make_path(vim.api.nvim_buf_get_name(ev.buf))
        if tracked[path] then
          conn:broadcast({ t = "focus", path = path, peer = 0, name = get_username() })
        end
      end)
    end,
  })

  -- Save events.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = host_aug,
    callback = function(ev)
      local path = make_path(vim.api.nvim_buf_get_name(ev.buf))
      if tracked[path] then
        conn:broadcast({ t = "save_file", path = path })
      end
    end,
  })

  -- Status message.
  p = p or (conn and conn.signaling_port) or "0"
  vim.api.nvim_out_write("live-share: hosting '" .. vim.fn.fnamemodify(root, ":t") .. "' on port " .. p .. "\n")
  local fp = session.key and crypto.fingerprint(session.key)
  if fp then
    vim.api.nvim_out_write("live-share: session fingerprint " .. fp .. " — verify with each guest\n")
  end
  return true
end

function M.stop()
  vim.api.nvim_clear_autocmds({ group = host_aug })
  vim.api.nvim_clear_autocmds({ group = cursor_aug })
  if cursor_timer then
    cursor_timer:stop()
    cursor_timer:close()
    cursor_timer = nil
  end
  audit.log("session_stop")
  audit.close()
  presence.clear_all()
  follow.reset()
  require("live-share.shared_terminal").stop()
  if conn then
    conn:stop()
    conn = nil
  end
  ctx.conn = nil
  -- Clear in place so the reference shared with host/dispatch.lua's ctx stays valid.
  for k in pairs(tracked) do
    tracked[k] = nil
  end
  seq = 0
  workspace.set_root(nil)
  session.reset()
end

-- Open a shared terminal that guests can see and interact with.
function M.open_terminal()
  audit.log("terminal_opened")
  require("live-share.shared_terminal").open_host()
end

-- ── Mid-session control (host-only) ───────────────────────────────────────────

-- Disconnect a peer immediately.  Sends a "bye" to remaining peers.
function M.kick(peer_id)
  if not conn then
    return false
  end
  local name = (presence.get_all() or {})[peer_id] and presence.get_all()[peer_id].name or nil
  -- presence.get_all returns a list, not a map; fall back by scanning.
  for _, p in ipairs(presence.get_all() or {}) do
    if p.peer_id == peer_id then
      name = p.name
      break
    end
  end
  if conn.kick then
    conn:kick(peer_id)
  end
  presence.remove_peer(peer_id)
  conn:broadcast({ t = "bye", peer = peer_id, name = name })
  audit.log("peer_kicked", { peer_id = peer_id, peer_name = name })
  return true
end

-- Change a peer's role mid-session.  Subsequent patches from that peer are
-- silently dropped server-side if role == "ro".
function M.set_peer_role(peer_id, role)
  if not conn or (role ~= "rw" and role ~= "ro") then
    return false
  end
  conn:set_role(peer_id, role)
  audit.log("role_changed", { peer_id = peer_id, role = role })
  return true
end

-- Returns the host-side role ("rw" / "ro") of a connected peer, or nil if the
-- peer is unknown.  Used by the UI to label peers in :LiveSharePeers.
function M.get_peer_role(peer_id)
  if not conn or not conn.get_role then
    return nil
  end
  return conn:get_role(peer_id)
end

-- Exposed for tunnel.lua: appends the encryption key to the share URL.
function M.get_key_fragment()
  if not session.key then
    return ""
  end
  return "#key=" .. crypto.b64url_encode(session.key)
end

-- Returns the signaling server port when using the punch transport, else nil.
function M.get_signaling_port()
  return conn and conn.signaling_port
end

function M.random_sid()
  math.randomseed(os.time())
  local t = {}
  for i = 1, 16 do
    t[i] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(t)
end

return M
