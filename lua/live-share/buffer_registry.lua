-- Virtual buffer registry: creates and manages remote nofile buffers on the guest.
--
-- Each remote file gets a Neovim buffer named:
--   liveshare://<session_id>/<workspace-relative-path>
--
-- Properties:
--   buftype  = "nofile"    → no backing file on disk
--   bufhidden = "hide"     → survives window close
--   swapfile = false
--   modifiable = false     → for read-only files (host hasn't opened them)
--
-- :w is intercepted by BufWriteCmd; no data is ever written to local disk.
local M = {}

-- by_path[path]   = { buf_id, applying }
-- by_buf[buf_id]  = path   (reverse index)
local by_path = {}
local by_buf  = {}

-- Called when a tracked buffer changes locally: fn(path, patch_msg)
local on_change_cb = nil

function M.setup(cb)
  on_change_cb = cb
end

-- Attach change watcher to an existing buffer entry.
local function watch(path, b, applying)
  vim.api.nvim_buf_attach(b, false, {
    on_lines = function(_, buf, _, firstline, lastline, new_lastline)
      if applying.value then return end
      if firstline == lastline and new_lastline == firstline then return end
      if on_change_cb then
        local lines = vim.api.nvim_buf_get_lines(buf, firstline, new_lastline, false)
        on_change_cb(path, {
          t     = "patch",
          path  = path,
          lnum  = firstline,
          count = lastline - firstline,
          lines = lines,
        })
      end
    end,
    on_detach = function()
      if by_path[path] and by_path[path].buf_id == b then
        by_path[path] = nil
        by_buf[b]     = nil
      end
    end,
  })
end

-- Open (or reuse) a virtual buffer for a remote file.
-- readonly = true  → modifiable=false, no change watcher (file not open on host)
-- readonly = false → editable, change watcher active
-- Returns buf_id.
function M.open(path, lines, session_id, readonly)
  -- Reuse existing buffer: just update content.
  if by_path[path] then
    M.apply(path, { lnum = 0, count = -1, lines = lines or {} })
    -- Upgrade read-only → editable if host just opened the file.
    if not readonly and vim.b[by_path[path].buf_id].live_share_readonly then
      M.set_editable(path)
    end
    return by_path[path].buf_id
  end

  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, "liveshare://" .. (session_id or "session") .. "/" .. path)
  vim.bo[b].buftype    = "nofile"
  vim.bo[b].bufhidden  = "hide"
  vim.bo[b].swapfile   = false
  vim.bo[b].modifiable = not readonly

  -- Trigger filetype detection for syntax highlighting.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_call, b, function()
        vim.cmd("silent! doautocmd filetypedetect BufRead " .. vim.fn.fnameescape(path))
      end)
    end
  end)

  -- Set content before attaching watcher to avoid a spurious change event.
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines or {})
  vim.bo[b].modifiable = not readonly

  -- Intercept :w
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer   = b,
    callback = function()
      vim.notify("live-share: '" .. path .. "' syncs automatically — no local write needed", vim.log.levels.INFO)
    end,
  })

  -- For read-only buffers, intercept insert-mode attempts to avoid a flood of
  -- E21 "Cannot make changes, 'modifiable' is off" errors on every keypress.
  if readonly then
    local ro_notified = false
    vim.api.nvim_create_autocmd("InsertEnter", {
      buffer   = b,
      callback = function()
        vim.schedule(function()
          vim.cmd("stopinsert")
          if not ro_notified then
            ro_notified = true
            vim.notify("live-share: read-only session — editing is disabled", vim.log.levels.WARN)
          end
        end)
      end,
    })
  end

  -- Buffer variables for statusline / external integrations.
  vim.b[b].live_share_remote   = true
  vim.b[b].live_share_path     = path
  vim.b[b].live_share_readonly = readonly

  local applying = { value = false }
  by_path[path] = { buf_id = b, applying = applying }
  by_buf[b]     = path

  if not readonly then
    watch(path, b, applying)
  end

  return b
end

-- Upgrade a previously read-only buffer to editable (host opened the file).
function M.set_editable(path)
  local e = by_path[path]
  if not e or not vim.api.nvim_buf_is_valid(e.buf_id) then return end
  vim.bo[e.buf_id].modifiable       = true
  vim.b[e.buf_id].live_share_readonly = false
  watch(path, e.buf_id, e.applying)
end

-- Apply a remote patch to the buffer for path.
-- patch = { lnum, count, lines }; count == -1 replaces the entire buffer.
function M.apply(path, patch)
  local e = by_path[path]
  if not e then return end
  local b = e.buf_id
  if not vim.api.nvim_buf_is_valid(b) then
    by_path[path] = nil
    by_buf[b]     = nil
    return
  end
  local end_line = patch.count == -1 and -1 or (patch.lnum + patch.count)
  local lines    = type(patch.lines) == "table" and patch.lines or {}
  local was_mod  = vim.bo[b].modifiable
  vim.bo[b].modifiable = true
  e.applying.value = true
  vim.api.nvim_buf_set_lines(b, patch.lnum, end_line, false, lines)
  e.applying.value = false
  vim.bo[b].modifiable = was_mod
end

function M.get_lines(path)
  local e = by_path[path]
  if not e or not vim.api.nvim_buf_is_valid(e.buf_id) then return {} end
  return vim.api.nvim_buf_get_lines(e.buf_id, 0, -1, false)
end

function M.get_buf(path)
  local e = by_path[path]
  return (e and vim.api.nvim_buf_is_valid(e.buf_id)) and e.buf_id or nil
end

function M.get_path(buf_id)
  return by_buf[buf_id]
end

function M.list_paths()
  local result = {}
  for path in pairs(by_path) do result[#result + 1] = path end
  return result
end

function M.close(path)
  local e = by_path[path]
  if not e then return end
  local b = e.buf_id
  by_path[path] = nil
  by_buf[b]     = nil
  if vim.api.nvim_buf_is_valid(b) then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end

function M.close_all()
  local paths = {}
  for path in pairs(by_path) do paths[#paths + 1] = path end
  for _, path in ipairs(paths) do M.close(path) end
end

return M
