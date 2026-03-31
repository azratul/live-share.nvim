-- Buffer synchronisation: multi-buffer registry.
--
-- Tracks both host-side local buffers (attach_host) and client-side virtual
-- nofile buffers (attach_remote).  All operations run on the main thread.
local M = {}

-- entries[path] = { buf_id, applying_remote, is_remote }
local entries = {}

-- Callback fired when any tracked buffer changes locally: fn(path, patch_msg)
local on_change = nil

function M.setup(cb)
  on_change = cb
end

-- ── Internal helpers ──────────────────────────────────────────────────────────

local function make_entry(path, b, is_remote)
  local e = { buf_id = b, applying_remote = false, is_remote = is_remote }
  entries[path] = e

  vim.api.nvim_buf_attach(b, false, {
    on_lines = function(_, buf, _, firstline, lastline, new_lastline)
      if e.applying_remote then return end
      if firstline == lastline and new_lastline == firstline then return end
      if on_change then
        local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)
        on_change(path, {
          t     = "patch",
          path  = path,
          lnum  = firstline,
          count = lastline - firstline,
          lines = lines,
        })
      end
    end,
    on_detach = function()
      -- Buffer was wiped externally; clean up registry.
      if entries[path] and entries[path].buf_id == b then
        entries[path] = nil
      end
    end,
  })

  return e
end

-- ── Public API ────────────────────────────────────────────────────────────────

-- Host: attach to an existing local buffer already open in Neovim.
function M.attach_host(path, buf_id)
  if entries[path] then return end
  make_entry(path, buf_id, false)
end

-- Client: create a virtual nofile buffer for a remote file.
-- Returns the new buffer id.
function M.attach_remote(path, lines, session_id)
  if entries[path] then
    -- Buffer already exists for this path: just replace its content.
    M.apply(path, { lnum = 0, count = -1, lines = lines or {} })
    return entries[path].buf_id
  end

  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, "liveshare://" .. (session_id or "session") .. "/" .. path)
  vim.bo[b].buftype   = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile  = false

  -- Intercept save attempts: the buffer has no backing file on disk.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer   = b,
    callback = function()
      vim.api.nvim_out_write(
        "live-share: '" .. path .. "' is a remote buffer — changes sync automatically\n")
    end,
  })

  -- Set initial content before attaching on_lines to avoid a spurious patch.
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines or {})

  make_entry(path, b, true)
  return b
end

-- Apply a remote patch to the buffer for the given path.
-- patch = { lnum, count, lines }; count == -1 replaces the entire buffer.
function M.apply(path, patch)
  local e = entries[path]
  if not e then return end
  if not vim.api.nvim_buf_is_valid(e.buf_id) then
    entries[path] = nil
    return
  end
  local end_line = patch.count == -1 and -1 or (patch.lnum + patch.count)
  local lines    = type(patch.lines) == "table" and patch.lines or {}
  e.applying_remote = true
  vim.api.nvim_buf_set_lines(e.buf_id, patch.lnum, end_line, false, lines)
  e.applying_remote = false
end

function M.get_lines(path)
  local e = entries[path]
  if not e or not vim.api.nvim_buf_is_valid(e.buf_id) then return {} end
  return vim.api.nvim_buf_get_lines(e.buf_id, 0, -1, false)
end

function M.get_buf(path)
  local e = entries[path]
  return (e and vim.api.nvim_buf_is_valid(e.buf_id)) and e.buf_id or nil
end

-- Reverse lookup: return the path tracked for a given buffer id, or nil.
function M.get_path_for_buf(buf_id)
  for path, e in pairs(entries) do
    if e.buf_id == buf_id then return path end
  end
  return nil
end

-- Return { path = lines, ... } for all valid tracked paths.
-- Used by the host to build the catalog sent to joining clients.
function M.get_all()
  local result = {}
  for path, e in pairs(entries) do
    if vim.api.nvim_buf_is_valid(e.buf_id) then
      result[path] = vim.api.nvim_buf_get_lines(e.buf_id, 0, -1, false)
    end
  end
  return result
end

-- Remove tracking for a path.
-- For remote (nofile) buffers the underlying Neovim buffer is also deleted.
function M.detach(path)
  local e = entries[path]
  if not e then return end
  entries[path] = nil
  if e.is_remote and vim.api.nvim_buf_is_valid(e.buf_id) then
    pcall(vim.api.nvim_buf_delete, e.buf_id, { force = true })
  end
end

function M.detach_all()
  local paths = {}
  for path in pairs(entries) do paths[#paths + 1] = path end
  for _, path in ipairs(paths) do
    M.detach(path)
  end
end

return M
