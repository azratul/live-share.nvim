-- Host logic: serves the workspace, manages tracked buffers, handles
-- incoming messages from guests, and emits protocol events.
--
-- Sync strategy (MVP): line-level last-write-wins.
--   The host assigns a monotonically increasing `seq` to every PATCH and is
--   the ordering authority.  No CRDT — sufficient for low-latency sessions.
--   For files not open in Neovim the patch is applied directly to disk.
local M = {}

local server   = require("live-share.collab.server")
local workspace = require("live-share.workspace")
local presence  = require("live-share.presence")
local follow   = require("live-share.follow")
local session   = require("live-share.session")
local crypto    = require("live-share.collab.crypto")
local log       = require("live-share.collab.log")
local uv        = vim.uv or vim.loop

local config   = nil
local seq      = 0

-- tracked[path] = { buf_id, applying }  — Neovim buffers currently open by host
local tracked    = {}
local host_aug   = vim.api.nvim_create_augroup("LiveShareHost",       { clear = true })
local cursor_aug = vim.api.nvim_create_augroup("LiveShareHostCursor", { clear = true })
local cursor_timer = nil

local function dbg(m) log.dbg("host", m) end

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
    if rel ~= "" then return rel end
  end
  return abs
end

local function is_shareable(b)
  if not vim.api.nvim_buf_is_valid(b) then return false end
  if not vim.api.nvim_buf_is_loaded(b) then return false end
  if vim.fn.buflisted(b) == 0 then return false end
  if vim.bo[b].buftype ~= "" then return false end
  return vim.api.nvim_buf_get_name(b) ~= ""
end

-- Attach to a Neovim buffer and start watching it for local edits.
-- Returns the workspace-relative path if newly attached, nil otherwise.
local function attach_buffer(b)
  if not is_shareable(b) then return nil end
  local path = make_path(vim.api.nvim_buf_get_name(b))
  if tracked[path] then return nil end  -- already tracked

  local applying = { value = false }
  tracked[path] = { buf_id = b, applying = applying }

  vim.api.nvim_buf_attach(b, false, {
    on_lines = function(_, buf, _, firstline, lastline, new_lastline)
      if applying.value then return end
      if firstline == lastline and new_lastline == firstline then return end
      seq = seq + 1
      local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)
      server.broadcast({
        t     = "patch",
        path  = path,
        seq   = seq,
        peer  = 0,
        lnum  = firstline,
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
    group  = cursor_aug,
    buffer = b,
    callback = function()
      local pos  = vim.api.nvim_win_get_cursor(0)
      local mode = vim.fn.mode()
      local sel  = nil
      if mode == "v" or mode == "V" or mode == "\22" then
        local vstart = vim.fn.getpos("v")
        local vend   = vim.fn.getpos(".")
        local sl, sc = vstart[2] - 1, vstart[3] - 1
        local el, ec = vend[2] - 1,   vend[3] - 1
        if sl > el or (sl == el and sc > ec) then
          sl, sc, el, ec = el, ec, sl, sc
        end
        if mode == "V" then sc = 0; ec = 2147483647 end
        sel = { sl = sl, sc = sc, el = el, ec = ec }
      end

      if cursor_timer then cursor_timer:stop()
      else cursor_timer = uv.new_timer() end
      cursor_timer:start(100, 0, vim.schedule_wrap(function()
        local cmsg = {
          t    = "cursor",
          path = path,
          peer = 0,
          lnum = pos[1] - 1,
          col  = pos[2],
          name = get_username(),
        }
        if sel then
          cmsg.sel_lnum = sel.sl; cmsg.sel_col = sel.sc
          cmsg.sel_end_lnum = sel.el; cmsg.sel_end_col = sel.ec
        end
        server.broadcast(cmsg)
      end))
    end,
  })

  -- CursorMoved does not fire when leaving visual mode without moving the cursor
  -- (e.g. <Esc>). Send an immediate clear so remote highlights don't linger.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group    = cursor_aug,
    buffer   = b,
    callback = function()
      local old = vim.v.event.old_mode
      if old == "v" or old == "V" or old == "\22" then
        local pos = vim.api.nvim_win_get_cursor(0)
        server.broadcast({
          t    = "cursor",
          path = path,
          peer = 0,
          lnum = pos[1] - 1,
          col  = pos[2],
          name = get_username(),
        })
      end
    end,
  })

  dbg("tracking buffer: " .. path)
  return path
end

-- ── Message dispatch ──────────────────────────────────────────────────────────

local function on_message(msg, from_peer)
  -- ── connect ──────────────────────────────────────────────────────────────
  if msg.t == "connect" then
    -- Step 1: host approves or denies the incoming connection.
    vim.ui.select(
      { "Allow", "Deny" },
      { prompt = "Guest #" .. from_peer .. " wants to join — allow?" },
      function(choice)
        if choice ~= "Allow" then
          server.reject(from_peer, { t = "rejected", reason = "Host denied the connection" })
          vim.api.nvim_out_write("live-share: denied guest #" .. from_peer .. "\n")
          return
        end

        -- Step 2: choose the guest's role.
        vim.ui.select(
          { "Read/Write", "Read only" },
          { prompt = "Role for guest #" .. from_peer .. ":" },
          function(role_choice)
            -- Treat dismiss (nil) as Read/Write to avoid orphaned pending entries.
            local ro = (role_choice == "Read only")
            server.approve(from_peer)
            server.set_role(from_peer, ro and "ro" or "rw")

            server.send(from_peer, {
              t         = "hello",
              sid       = session.id,
              peer_id   = from_peer,
              host_name = get_username(),
              role      = ro and "ro" or "rw",
            })

            -- Workspace file list (flat).
            local files = workspace.scan()
            server.send(from_peer, {
              t         = "workspace_info",
              root_name = vim.fn.fnamemodify(workspace.get_root() or ".", ":t"),
              files     = files,
            })

            -- Snapshot of all currently open (tracked) buffers.
            local open_list = {}
            for path, t in pairs(tracked) do
              if vim.api.nvim_buf_is_valid(t.buf_id) then
                open_list[#open_list + 1] = {
                  path  = path,
                  lines = vim.api.nvim_buf_get_lines(t.buf_id, 0, -1, false),
                }
              end
            end
            if #open_list > 0 then
              server.send(from_peer, { t = "open_files_snapshot", files = open_list })
            end

            -- Snapshot of currently connected peers so the new guest sees them immediately.
            local peer_list = presence.get_all()
            if #peer_list > 0 then
              server.send(from_peer, { t = "peers_snapshot", peers = peer_list })
            end
          end
        )
      end
    )

  -- ── hello_ack ─────────────────────────────────────────────────────────────
  elseif msg.t == "hello_ack" then
    local label = (msg.name and msg.name ~= "") and msg.name or ("guest " .. from_peer)
    presence.update_peer(from_peer, msg.name)
    vim.schedule(function()
      vim.api.nvim_out_write("live-share: " .. label .. " joined\n")
    end)

  -- ── file_request ──────────────────────────────────────────────────────────
  elseif msg.t == "file_request" then
    local path = msg.path
    if not path then return end

    local lines, readonly
    local t = tracked[path]
    if t and vim.api.nvim_buf_is_valid(t.buf_id) then
      lines    = vim.api.nvim_buf_get_lines(t.buf_id, 0, -1, false)
      readonly = false
    else
      lines    = workspace.read_file(path)
      readonly = false
    end

    server.send(from_peer, {
      t        = "file_response",
      path     = path,
      lines    = lines or {},
      readonly = readonly,
    })

  -- ── patch ─────────────────────────────────────────────────────────────────
  elseif msg.t == "patch" then
    local path = msg.path
    if not path then return end

    seq = seq + 1
    local stamped = {
      t     = "patch", path = path, seq = seq, peer = from_peer,
      lnum  = msg.lnum, count = msg.count, lines = msg.lines,
    }

    local t = tracked[path]
    if t and vim.api.nvim_buf_is_valid(t.buf_id) then
      -- Apply to the live Neovim buffer (we're already on main thread via vim.schedule).
      local end_line = msg.count == -1 and -1 or (msg.lnum + msg.count)
      local lines    = type(msg.lines) == "table" and msg.lines or {}
      t.applying.value = true
      vim.api.nvim_buf_set_lines(t.buf_id, msg.lnum, end_line, false, lines)
      t.applying.value = false
    else
      -- File not open in Neovim: apply directly to disk.
      workspace.apply_patch_to_disk(path, msg.lnum, msg.count, msg.lines)
    end

    server.broadcast(stamped, from_peer)

  -- ── cursor ────────────────────────────────────────────────────────────────
  elseif msg.t == "cursor" then
    -- Render the guest's cursor in the host's own Neovim buffer.
    local entry = msg.path and tracked[msg.path]
    if entry and vim.api.nvim_buf_is_valid(entry.buf_id) then
      local sel = msg.sel_lnum and {
        lnum = msg.sel_lnum, col = msg.sel_col,
        end_lnum = msg.sel_end_lnum, end_col = msg.sel_end_col,
      } or nil
      presence.update_cursor(entry.buf_id, from_peer, msg.lnum, msg.col, msg.name, msg.path, sel)
    end
    server.broadcast({
      t    = "cursor", path = msg.path, peer = from_peer,
      lnum = msg.lnum, col  = msg.col,  name = msg.name,
      sel_lnum = msg.sel_lnum, sel_col = msg.sel_col,
      sel_end_lnum = msg.sel_end_lnum, sel_end_col = msg.sel_end_col,
    }, from_peer)

  -- ── focus ─────────────────────────────────────────────────────────────────
  elseif msg.t == "focus" then
    local label = (msg.name and msg.name ~= "") and msg.name or ("guest " .. from_peer)
    presence.update_focus(from_peer, msg.path, msg.name)
    -- If we haven't seen this peer's name yet (hello_ack not received), show it now.
    presence.update_peer(from_peer, label)
    follow.maybe_follow(msg.path, nil, nil, from_peer)
    server.broadcast({
      t = "focus", path = msg.path, peer = from_peer, name = msg.name,
    }, from_peer)

  -- ── bye ───────────────────────────────────────────────────────────────────
  elseif msg.t == "bye" then
    presence.remove_peer(from_peer)
    server.broadcast({ t = "bye", peer = from_peer, name = msg.name }, from_peer)
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
  config      = cfg
  log.enabled = cfg and cfg.debug or false
end

function M.start(port)
  local root = (config and config.workspace_root and config.workspace_root ~= "")
      and config.workspace_root
      or vim.fn.getcwd()
  workspace.set_root(root)
  session.id   = M.random_sid()
  session.role = "host"
  seq          = 0

  if crypto.available then
    session.key = crypto.generate_key()
  else
    session.key = nil
    vim.notify("live-share: OpenSSL not found — session runs WITHOUT encryption", vim.log.levels.WARN)
  end

  require("live-share.shared_terminal").setup("host", function(msg) server.broadcast(msg) end)
  server.setup(on_message)

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

  local ip = (config and config.ip_local) or "127.0.0.1"
  local p  = port or (config and config.port_internal) or 9876
  server.start(ip, p, session.key)

  -- Attach to all currently open files.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    attach_buffer(b)
  end

  -- New files opened by the host during the session.
  vim.api.nvim_create_autocmd("BufAdd", {
    group    = host_aug,
    callback = function(ev)
      local b = ev.buf
      -- Defer: buftype and name are not yet finalised at BufAdd fire time.
      vim.schedule(function()
        local path = attach_buffer(b)
        if path then
          local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
          server.broadcast({ t = "open_file", path = path, lines = lines })
        end
      end)
    end,
  })

  -- Files closed by the host.
  vim.api.nvim_create_autocmd("BufDelete", {
    group    = host_aug,
    callback = function(ev)
      for path, t in pairs(tracked) do
        if t.buf_id == ev.buf then
          local b = ev.buf
          presence.clear_buf(b)
          tracked[path] = nil
          server.broadcast({ t = "close_file", path = path })
          dbg("unshared: " .. path)
          break
        end
      end
    end,
  })

  -- Focus events: host switched active buffer.
  vim.api.nvim_create_autocmd("BufEnter", {
    group    = host_aug,
    callback = function(ev)
      vim.schedule(function()
        local path = make_path(vim.api.nvim_buf_get_name(ev.buf))
        if tracked[path] then
          server.broadcast({ t = "focus", path = path, peer = 0, name = get_username() })
        end
      end)
    end,
  })

  -- Save events.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group    = host_aug,
    callback = function(ev)
      local path = make_path(vim.api.nvim_buf_get_name(ev.buf))
      if tracked[path] then
        server.broadcast({ t = "save_file", path = path })
      end
    end,
  })

  vim.api.nvim_out_write(
    "live-share: hosting '" .. vim.fn.fnamemodify(root, ":t") .. "' on port " .. p .. "\n")
end

function M.stop()
  vim.api.nvim_clear_autocmds({ group = host_aug })
  vim.api.nvim_clear_autocmds({ group = cursor_aug })
  if cursor_timer then
    cursor_timer:stop()
    cursor_timer:close()
    cursor_timer = nil
  end
  presence.clear_all()
  follow.reset()
  require("live-share.shared_terminal").stop()
  server.stop()
  tracked = {}
  seq     = 0
  workspace.set_root(nil)
  session.reset()
end

-- Open a shared terminal that guests can see and interact with.
function M.open_terminal()
  require("live-share.shared_terminal").open_host()
end

-- Exposed for tunnel.lua: appends the encryption key to the share URL.
function M.get_key_fragment()
  if not session.key then return "" end
  return "#key=" .. crypto.b64url_encode(session.key)
end

function M.random_sid()
  math.randomseed(os.time())
  local t = {}
  for i = 1, 16 do t[i] = string.format("%02x", math.random(0, 255)) end
  return table.concat(t)
end

return M
