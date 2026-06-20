-- Host inbound-message dispatch.
--
-- Routes a decoded guest message to a per-type handler.  Extracted from
-- host.lua to keep that module focused on session lifecycle and buffer
-- tracking; the handlers here are the "what does the host do when a guest
-- says X" half.
--
-- Handlers receive a `ctx` (see LiveShare.HostContext) carrying the live
-- connection, the tracked-buffer table, and the seq/username accessors that
-- host.lua owns.  They are otherwise free of host.lua's internal state, which
-- is what makes this split safe: state stays in host.lua, behaviour lives here.
local M = {}

local workspace = require("live-share.workspace")
local presence = require("live-share.presence")
local follow = require("live-share.follow")
local session = require("live-share.session")
local audit = require("live-share.audit")
local log = require("live-share.collab.log")

-- v4 stage 6: workspace listing is streamed as `workspace_info_chunk` messages
-- of at most this many paths each, terminated by `workspace_info_done`.
-- 1000 paths/chunk on a 50k-file monorepo yields 50 chunks of ~50 KB JSON
-- (well under MAX_MESSAGE_BYTES = 10 MB) without making the per-chunk
-- overhead dominate on small workspaces.
local WORKSPACE_CHUNK_SIZE = 1000

---State and accessors host.lua hands to its message handlers.
---@class LiveShare.HostContext
---@field conn LiveShare.Listener the active host connection (set by host.lua at start)
---@field tracked table<string, { buf_id: integer, applying: { value: boolean } }> open buffers keyed by workspace-relative path
---@field get_username fun(): string the host's display name
---@field next_seq fun(): integer increment and return the monotonic patch sequence counter

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

-- Per-type handlers, keyed by `msg.t`.  Each receives (ctx, msg, from_peer).
local handlers = {}

-- ── connect ──────────────────────────────────────────────────────────────
function handlers.connect(ctx, msg, from_peer)
  local conn = ctx.conn
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
            host_name = ctx.get_username(),
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
          for path, t in pairs(ctx.tracked) do
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
end

-- ── hello_ack ─────────────────────────────────────────────────────────────
function handlers.hello_ack(ctx, msg, from_peer)
  local label = (msg.name and msg.name ~= "") and msg.name or ("guest " .. from_peer)
  ctx.conn:set_name(from_peer, label)
  presence.update_peer(from_peer, msg.name)
  if msg.caps then
    log.dbg("host", "guest " .. from_peer .. " caps: " .. vim.inspect(msg.caps))
  end
  audit.log("peer_joined", { peer_id = from_peer, peer_name = msg.name, payload_hash = msg.__payload_hash })
  vim.schedule(function()
    vim.api.nvim_out_write("live-share: " .. label .. " joined as peer #" .. from_peer .. "\n")
  end)
end

-- ── file_request ──────────────────────────────────────────────────────────
function handlers.file_request(ctx, msg, from_peer)
  local conn = ctx.conn
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
    local t = ctx.tracked[path]
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
end

-- ── patch ─────────────────────────────────────────────────────────────────
function handlers.patch(ctx, msg, from_peer)
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

  local seq = ctx.next_seq()
  local stamped = {
    t = "patch",
    path = path,
    seq = seq,
    peer = from_peer,
    lnum = msg.lnum,
    count = msg.count,
    lines = msg.lines,
  }

  local t = ctx.tracked[path]
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

  ctx.conn:broadcast(stamped, from_peer)
end

-- ── cursor ────────────────────────────────────────────────────────────────
function handlers.cursor(ctx, msg, from_peer)
  -- Render the guest's cursor in the host's own Neovim buffer.
  local entry = msg.path and ctx.tracked[msg.path]
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
  ctx.conn:broadcast({
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
end

-- ── focus ─────────────────────────────────────────────────────────────────
function handlers.focus(ctx, msg, from_peer)
  local label = (msg.name and msg.name ~= "") and msg.name or ("guest " .. from_peer)
  presence.update_focus(from_peer, msg.path, msg.name)
  presence.update_peer(from_peer, label)
  follow.maybe_follow(msg.path, nil, nil, from_peer)
  ctx.conn:broadcast({
    t = "focus",
    path = msg.path,
    peer = from_peer,
    name = msg.name,
  }, from_peer)
end

-- ── bye ───────────────────────────────────────────────────────────────────
function handlers.bye(ctx, msg, from_peer)
  presence.remove_peer(from_peer)
  ctx.conn:broadcast({ t = "bye", peer = from_peer, name = msg.name }, from_peer)
  audit.log("peer_disconnected", {
    peer_id = from_peer,
    peer_name = msg.name,
    payload_hash = msg.__payload_hash,
  })
  vim.schedule(function()
    local label = msg.name or ("guest " .. from_peer)
    vim.api.nvim_out_write("live-share: " .. label .. " left\n")
  end)
end

-- ── terminal_input ────────────────────────────────────────────────────────
function handlers.terminal_input(_ctx, msg, _from_peer)
  if msg.term_id and msg.data then
    require("live-share.shared_terminal").on_guest_input(msg.term_id, msg.data)
  end
end

---Route a decoded guest message to its handler.
---@param ctx LiveShare.HostContext
---@param msg LiveShare.Message
---@param from_peer LiveShare.PeerId
function M.handle(ctx, msg, from_peer)
  if not path_field_ok(msg, from_peer) then
    return
  end
  local h = handlers[msg.t]
  if h then
    h(ctx, msg, from_peer)
  end
end

return M
