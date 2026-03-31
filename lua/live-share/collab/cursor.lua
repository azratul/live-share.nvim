-- Remote cursor display using extmarks and virtual text.
local M = {}

local ns = vim.api.nvim_create_namespace("live_share_cursors")

-- Highlight groups cycled per peer so each collaborator gets a distinct colour.
-- These groups exist in every Neovim colorscheme.
local HL_GROUPS = {
  "DiagnosticVirtualTextInfo",
  "DiagnosticVirtualTextWarn",
  "DiagnosticVirtualTextHint",
  "DiagnosticVirtualTextError",
  "WarningMsg",
}

-- marks[peer_id] = { buf = buf_id, id = extmark_id }
-- A peer's cursor lives in exactly one buffer at a time.
local marks = {}

local function hl_for(peer_id)
  return HL_GROUPS[((peer_id - 1) % #HL_GROUPS) + 1]
end

function M.update(buf, peer_id, lnum, col, name)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end

  local old = marks[peer_id]
  if old then
    -- Remove stale mark; it may be in a different buffer.
    if vim.api.nvim_buf_is_valid(old.buf) then
      pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.id)
    end
    marks[peer_id] = nil
  end

  local label    = name or ("peer " .. peer_id)
  local ok, id   = pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, col, {
    virt_text     = { { " " .. label .. " ", hl_for(peer_id) } },
    virt_text_pos = "eol",
    hl_mode       = "combine",
  })
  if ok then marks[peer_id] = { buf = buf, id = id } end
end

-- Remove a peer's cursor from wherever it currently is.
function M.remove_peer(peer_id)
  local old = marks[peer_id]
  if not old then return end
  if vim.api.nvim_buf_is_valid(old.buf) then
    pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.id)
  end
  marks[peer_id] = nil
end

-- Remove all cursors associated with a specific buffer (e.g. file closed).
function M.clear_buf(buf)
  for pid, old in pairs(marks) do
    if old.buf == buf then
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_del_extmark, buf, ns, old.id)
      end
      marks[pid] = nil
    end
  end
end

-- Remove all cursors everywhere (session ended).
function M.clear_all()
  for _, old in pairs(marks) do
    if vim.api.nvim_buf_is_valid(old.buf) then
      pcall(vim.api.nvim_buf_del_extmark, old.buf, ns, old.id)
    end
  end
  marks = {}
end

return M
