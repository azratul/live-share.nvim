-- Presence: tracks each peer's name, active file, and cursor position.
-- Cursor positions are displayed as extmarks with per-peer highlight groups.
local M = {}

local ns = vim.api.nvim_create_namespace("live_share_presence")

local HL_GROUPS = {
  "DiagnosticVirtualTextInfo",
  "DiagnosticVirtualTextWarn",
  "DiagnosticVirtualTextHint",
  "DiagnosticVirtualTextError",
  "WarningMsg",
}

-- peers[peer_id]    = { name, active_path, lnum, col }
-- extmarks[peer_id] = { buf, mark_id }
local peers    = {}
local extmarks = {}

local function hl_for(peer_id)
  return HL_GROUPS[((peer_id - 1) % #HL_GROUPS) + 1]
end

-- Update a peer's display name and optionally their active file.
function M.update_peer(peer_id, name, active_path)
  peers[peer_id] = peers[peer_id] or {}
  if name         then peers[peer_id].name        = name        end
  if active_path  then peers[peer_id].active_path = active_path end
end

-- Record that a peer changed their active file (no extmark change).
function M.update_focus(peer_id, path, name)
  peers[peer_id] = peers[peer_id] or {}
  peers[peer_id].active_path = path
  if name then peers[peer_id].name = name end
end

-- Update a peer's cursor position and render the extmark in buf.
-- sel (optional): { lnum, col, end_lnum, end_col } — visual selection range (0-indexed, inclusive end).
function M.update_cursor(buf, peer_id, lnum, col, name, path, sel)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  peers[peer_id] = peers[peer_id] or {}
  if name then peers[peer_id].name = name end
  if path then peers[peer_id].active_path = path end
  peers[peer_id].lnum = lnum
  peers[peer_id].col  = col

  -- Remove stale marks (may be in a different buffer).
  local old = extmarks[peer_id]
  if old then
    if vim.api.nvim_buf_is_valid(old.buf) then
      pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.mark_id)
      if old.sel_mark_id then
        pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.sel_mark_id)
      end
    end
    extmarks[peer_id] = nil
  end

  local label  = peers[peer_id].name or ("peer " .. peer_id)
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, col, {
    virt_text     = { { " " .. label .. " ", hl_for(peer_id) } },
    virt_text_pos = "eol",
    hl_mode       = "combine",
  })
  if not ok then return end

  local sel_mark_id = nil
  if sel then
    local sok, sid = pcall(vim.api.nvim_buf_set_extmark, buf, ns,
      sel.lnum, sel.col, {
        end_row  = sel.end_lnum,
        end_col  = sel.end_col + 1,
        hl_group = hl_for(peer_id),
        hl_mode  = "combine",
      })
    if sok then sel_mark_id = sid end
  end

  extmarks[peer_id] = { buf = buf, mark_id = id, sel_mark_id = sel_mark_id }
end

-- Remove a peer entirely (disconnected).
function M.remove_peer(peer_id)
  local old = extmarks[peer_id]
  if old and vim.api.nvim_buf_is_valid(old.buf) then
    pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.mark_id)
    if old.sel_mark_id then
      pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.sel_mark_id)
    end
  end
  extmarks[peer_id] = nil
  peers[peer_id]    = nil
end

-- Clear all marks associated with a specific buffer (e.g. file closed).
function M.clear_buf(buf)
  for pid, old in pairs(extmarks) do
    if old.buf == buf then
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, old.mark_id)
        if old.sel_mark_id then
          pcall(vim.api.nvim_buf_del_extmark, buf, ns, old.sel_mark_id)
        end
      end
      extmarks[pid] = nil
    end
  end
end

-- Clear everything (session ended).
function M.clear_all()
  for _, old in pairs(extmarks) do
    if vim.api.nvim_buf_is_valid(old.buf) then
      pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.mark_id)
      if old.sel_mark_id then
        pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.sel_mark_id)
      end
    end
  end
  extmarks = {}
  peers    = {}
end

-- Returns list of { peer_id, name, active_path, lnum, col }.
function M.get_all()
  local result = {}
  for pid, p in pairs(peers) do
    result[#result + 1] = {
      peer_id     = pid,
      name        = p.name or ("peer " .. pid),
      active_path = p.active_path,
      lnum        = p.lnum,
      col         = p.col,
    }
  end
  return result
end

return M
