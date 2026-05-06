-- Host logic: serves the workspace, manages tracked buffers, handles
-- incoming messages from guests, and emits protocol events.
--
-- Sync strategy (MVP): line-level last-write-wins.
--   The host assigns a monotonically increasing `seq` to every PATCH and is
--   the ordering authority.  No CRDT — sufficient for low-latency sessions.
--   For files not open in Neovim the patch is applied directly to disk.
local M = {}

local connection = require("live-share.collab.connection")
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

-- v4 stage 6: workspace listing is streamed as `workspace_info_chunk` messages
-- of at most this many paths each, terminated by `workspace_info_done`.
-- 1000 paths/chunk on a 50k-file monorepo yields 50 chunks of ~50 KB JSON
-- (well under MAX_MESSAGE_BYTES = 10 MB) without making the per-chunk
-- overhead dominate on small workspaces.
local WORKSPACE_CHUNK_SIZE = 1000

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

-- Messages from guests may include a `path` field as a workspace-relative
-- string.  Defence-in-depth: validate any such path against the same rules
-- the workspace sandbox uses (no traversal, no absolute, no NUL, not on the
-- sensitive blocklist) before letting the message reach a handler.  Without
-- this, a malicious guest could pollute presence/follow state for other
-- guests via cursor/focus broadcasts containing paths like `../../etc/passwd`.
local function path_field_ok(msg, from_peer)
  if msg.path == nil then
    return true
  end
  if type(msg.path) ~= "string" or not workspace.path_allowed(msg.path) then
    audit.log("path_rejected", {
      peer_id = from_peer,
      msg_type = msg.t,
      path = tostring(msg.path),
      payload_hash = msg.__payload_hash,
    })
    log.dbg("host", "rejected " .. tostring(msg.t) .. " from peer " .. from_peer .. ": invalid path")
    return false
  end
  return true
end

local function on_message(msg, from_peer)
  if not path_field_ok(msg, from_peer) then
    return
  end

  -- ── connect ──────────────────────────────────────────────────────────────
  if msg.t == "connect" then
    audit.log("peer_connect_request", { peer_id = from_peer, payload_hash = msg.__payload_hash })
    -- Step 1: host approves or denies the incoming connection.
    vim.ui.select(
      { "Allow", "Deny" },
      { prompt = "Guest #" .. from_peer .. " wants to join — allow?" },
      function(choice)
        if choice ~= "Allow" then
          conn:reject(from_peer, { t = "rejected", reason = "Host denied the connection" })
          vim.api.nvim_out_write("live-share: denied guest #" .. from_peer .. "\n")
          audit.log("peer_denied", { peer_id = from_peer })
          return
        end

        -- Step 2: choose the guest's role.
        vim.ui.select(
          { "Read/Write", "Read only" },
          { prompt = "Role for guest #" .. from_peer .. ":" },
          function(role_choice)
            -- Treat dismiss (nil) as Read/Write to avoid orphaned pending entries.
            local ro = (role_choice == "Read only")
            conn:approve(from_peer)
            conn:set_role(from_peer, ro and "ro" or "rw")
            audit.log("peer_approved", { peer_id = from_peer, role = ro and "ro" or "rw" })

            conn:send(from_peer, {
              t = "hello",
              protocol_version = require("live-share.collab.protocol").VERSION,
              sid = session.id,
              peer_id = from_peer,
              host_name = get_username(),
              role = ro and "ro" or "rw",
              required_caps = { "workspace" },
              optional_caps = { "terminal", "cursor", "follow" },
            })

            -- Workspace file list (flat).
            local files = workspace.scan()
            local truncated = workspace.scan_was_truncated()
            if truncated then
              local n = #files
              vim.schedule(function()
                vim.notify(
                  "live-share: workspace listing truncated at "
                    .. n
                    .. " files. Raise `scan_max_files` (or set it to 0 to disable the cap) in setup() to send the full tree.",
                  vim.log.levels.WARN
                )
              end)
            end

            -- v4 stage 6: stream the file list as `workspace_info_chunk`
            -- messages of at most WORKSPACE_CHUNK_SIZE paths each, terminated
            -- by `workspace_info_done`.  This keeps every individual frame
            -- well below MAX_MESSAGE_BYTES on monorepos with tens of
            -- thousands of files, and lets the guest render its file
            -- explorer (and accept :LiveShareOpen for already-known paths)
            -- incrementally instead of after a multi-MB JSON decode.
            local root_name = vim.fn.fnamemodify(workspace.get_root() or ".", ":t")
            local total = #files
            local chunk_size = WORKSPACE_CHUNK_SIZE
            local idx = 1
            local seq_n = 0
            -- Always send at least one chunk, even for an empty workspace —
            -- the guest's WORKSPACE_SYNC state needs a deterministic stream
            -- to walk before `workspace_info_done`.
            repeat
              seq_n = seq_n + 1
              local slice = {}
              local upper = math.min(idx + chunk_size - 1, total)
              for i = idx, upper do
                slice[#slice + 1] = files[i]
              end
              local chunk = { t = "workspace_info_chunk", seq = seq_n, files = slice }
              if seq_n == 1 then
                -- root_name only travels in the first chunk; subsequent
                -- chunks are pure file-list payload.  Saves repeating it
                -- N times on a 50-chunk monorepo stream.
                chunk.root_name = root_name
              end
              conn:send(from_peer, chunk)
              idx = upper + 1
            until idx > total

            conn:send(from_peer, {
              t = "workspace_info_done",
              total_files = total,
              truncated = truncated and true or false,
            })

            -- Snapshot of currently connected peers so the new guest sees them immediately.
            -- Sent before open_files_snapshot per protocol §8.
            local peer_list = presence.get_all()
            if #peer_list > 0 then
              conn:send(from_peer, { t = "peers_snapshot", peers = peer_list })
            end

            -- Snapshot of all currently open (tracked) buffers.
            -- Always sent (even if empty) so the guest can transition out of WORKSPACE_SYNC.
            local open_list = {}
            for path, t in pairs(tracked) do
              if vim.api.nvim_buf_is_valid(t.buf_id) then
                open_list[#open_list + 1] = {
                  path = path,
                  lines = vim.api.nvim_buf_get_lines(t.buf_id, 0, -1, false),
                }
              end
            end
            conn:send(from_peer, { t = "open_files_snapshot", files = open_list })

            -- Replay shared-terminal scrollback to the new peer.  Uses the
            -- existing `terminal_open` / `terminal_data` messages — no
            -- protocol change.  Only emits anything if a terminal is open.
            require("live-share.shared_terminal").snapshot_for(function(snap_msg)
              conn:send(from_peer, snap_msg)
            end)
          end
        )
      end
    )

  -- ── hello_ack ─────────────────────────────────────────────────────────────
  elseif msg.t == "hello_ack" then
    local label = (msg.name and msg.name ~= "") and msg.name or ("guest " .. from_peer)
    conn:set_name(from_peer, label)
    presence.update_peer(from_peer, msg.name)
    if msg.caps then
      log.dbg("host", "guest " .. from_peer .. " caps: " .. vim.inspect(msg.caps))
    end
    audit.log("peer_joined", { peer_id = from_peer, peer_name = msg.name, payload_hash = msg.__payload_hash })
    vim.schedule(function()
      vim.api.nvim_out_write("live-share: " .. label .. " joined as peer #" .. from_peer .. "\n")
    end)

  -- ── file_request ──────────────────────────────────────────────────────────
  elseif msg.t == "file_request" then
    local path = msg.path
    if not path then
      return
    end

    -- Sandbox / sensitive-file enforcement: reject before disk access.
    local denied_reason = nil
    if workspace.is_sensitive(path) then
      denied_reason = "sensitive"
    end

    local lines
    if not denied_reason then
      local t = tracked[path]
      if t and vim.api.nvim_buf_is_valid(t.buf_id) then
        lines = vim.api.nvim_buf_get_lines(t.buf_id, 0, -1, false)
      else
        lines = workspace.read_file(path)
        if not lines then
          denied_reason = "not-found-or-out-of-sandbox"
        end
      end
    end

    if denied_reason then
      audit.log("file_request_denied", {
        peer_id = from_peer,
        path = path,
        reason = denied_reason,
        payload_hash = msg.__payload_hash,
      })
      conn:send(from_peer, {
        t = "error",
        code = "file_not_found",
        message = "file not found in workspace: " .. path,
        req_id = msg.req_id,
      })
      return
    end

    audit.log("file_request_allowed", { peer_id = from_peer, path = path, payload_hash = msg.__payload_hash })
    conn:send(from_peer, {
      t = "file_response",
      path = path,
      lines = lines,
      readonly = false,
      req_id = msg.req_id,
    })

  -- ── patch ─────────────────────────────────────────────────────────────────
  elseif msg.t == "patch" then
    local path = msg.path
    if not path then
      return
    end

    -- Sandbox: silently ignore patches targeting paths outside the workspace
    -- or against sensitive files (defence-in-depth: server.lua already rejects
    -- ro guests, but a misbehaving rw guest could still try a stray path).
    if workspace.is_sensitive(path) then
      audit.log("patch_rejected_sensitive", { peer_id = from_peer, path = path, payload_hash = msg.__payload_hash })
      return
    end

    seq = seq + 1
    local stamped = {
      t = "patch",
      path = path,
      seq = seq,
      peer = from_peer,
      lnum = msg.lnum,
      count = msg.count,
      lines = msg.lines,
    }

    local t = tracked[path]
    if t and vim.api.nvim_buf_is_valid(t.buf_id) then
      local end_line = msg.count == -1 and -1 or (msg.lnum + msg.count)
      local lines = type(msg.lines) == "table" and msg.lines or {}
      t.applying.value = true
      vim.api.nvim_buf_set_lines(t.buf_id, msg.lnum, end_line, false, lines)
      t.applying.value = false
    else
      -- File not open in Neovim: apply directly to disk.
      workspace.apply_patch_to_disk(path, msg.lnum, msg.count, msg.lines)
    end

    conn:broadcast(stamped, from_peer)

  -- ── cursor ────────────────────────────────────────────────────────────────
  elseif msg.t == "cursor" then
    -- Render the guest's cursor in the host's own Neovim buffer.
    local entry = msg.path and tracked[msg.path]
    if entry and vim.api.nvim_buf_is_valid(entry.buf_id) then
      local sel = msg.sel_lnum
          and {
            lnum = msg.sel_lnum,
            col = msg.sel_col,
            end_lnum = msg.sel_end_lnum,
            end_col = msg.sel_end_col,
          }
        or nil
      presence.update_cursor(entry.buf_id, from_peer, msg.lnum, msg.col, msg.name, msg.path, sel)
    end
    conn:broadcast({
      t = "cursor",
      path = msg.path,
      peer = from_peer,
      lnum = msg.lnum,
      col = msg.col,
      name = msg.name,
      sel_lnum = msg.sel_lnum,
      sel_col = msg.sel_col,
      sel_end_lnum = msg.sel_end_lnum,
      sel_end_col = msg.sel_end_col,
    }, from_peer)

  -- ── focus ─────────────────────────────────────────────────────────────────
  elseif msg.t == "focus" then
    local label = (msg.name and msg.name ~= "") and msg.name or ("guest " .. from_peer)
    presence.update_focus(from_peer, msg.path, msg.name)
    presence.update_peer(from_peer, label)
    follow.maybe_follow(msg.path, nil, nil, from_peer)
    conn:broadcast({
      t = "focus",
      path = msg.path,
      peer = from_peer,
      name = msg.name,
    }, from_peer)

  -- ── bye ───────────────────────────────────────────────────────────────────
  elseif msg.t == "bye" then
    presence.remove_peer(from_peer)
    conn:broadcast({ t = "bye", peer = from_peer, name = msg.name }, from_peer)
    audit.log("peer_disconnected", {
      peer_id = from_peer,
      peer_name = msg.name,
      payload_hash = msg.__payload_hash,
    })
    vim.schedule(function()
      local label = msg.name or ("guest " .. from_peer)
      vim.api.nvim_out_write("live-share: " .. label .. " left\n")
    end)

  -- ── terminal_input ────────────────────────────────────────────────────────
  elseif msg.t == "terminal_input" then
    if msg.term_id and msg.data then
      require("live-share.shared_terminal").on_guest_input(msg.term_id, msg.data)
    end
  end
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
  tracked = {}
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
