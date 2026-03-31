-- UI layer: workspace tree explorer and participants panel.
-- Pure Neovim API — no external plugin dependencies.
local M = {}

-- ── Workspace explorer ────────────────────────────────────────────────────────
--
-- Opens a vsplit with a tree view of the remote workspace.
-- <CR> / o  → request file from host and open it
-- q         → close explorer
-- R         → refresh (re-open with current file list)
-- ?         → show help

local EXPLORER_NAME = "live-share://workspace"

-- Build a tree from a flat path list.
-- Returns root node: { children = { name → node }, files = { name → path }, _order = [...] }
local function build_tree(paths)
  local root = { children = {}, files = {}, _order = {} }

  for _, path in ipairs(paths) do
    local parts = vim.split(path, "/", { plain = true })
    local node  = root
    for i = 1, #parts - 1 do
      local dir = parts[i]
      if not node.children[dir] then
        node.children[dir] = { name = dir, children = {}, files = {}, _order = {} }
        node._order[#node._order + 1] = { kind = "dir", name = dir }
      end
      node = node.children[dir]
    end
    local fname = parts[#parts]
    node.files[fname] = path
    node._order[#node._order + 1] = { kind = "file", name = fname, path = path }
  end

  return root
end

-- Render the tree into a lines array.
-- path_map[line_number] = workspace-relative path (only for file lines).
local function render_tree(node, lines, indent, path_map)
  -- Sort: dirs before files, alphabetical within each group.
  local order = vim.deepcopy(node._order)
  table.sort(order, function(a, b)
    if a.kind ~= b.kind then return a.kind == "dir" end
    return a.name < b.name
  end)

  for _, item in ipairs(order) do
    if item.kind == "dir" then
      lines[#lines + 1] = indent .. "▸ " .. item.name .. "/"
      render_tree(node.children[item.name], lines, indent .. "  ", path_map)
    else
      lines[#lines + 1] = indent .. "  " .. item.name
      path_map[#lines]  = item.path
    end
  end
end

function M.open_workspace_explorer()
  local ok_g, guest = pcall(require, "live-share.guest")
  if not ok_g then
    vim.notify("live-share: workspace explorer requires guest mode", vim.log.levels.WARN)
    return
  end

  local files = guest.get_workspace_files()
  if #files == 0 then
    vim.notify("live-share: workspace not yet received (still connecting?)", vim.log.levels.WARN)
    return
  end

  local root_name = guest.get_workspace_root_name() or "workspace"

  -- Close existing explorer if already open.
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local wb = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(wb) == EXPLORER_NAME then
      vim.api.nvim_win_close(w, true)
      break
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, EXPLORER_NAME)
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "wipe"
  vim.bo[buf].swapfile   = false
  vim.bo[buf].filetype   = "live_share_workspace"

  local lines    = { "  " .. root_name .. "/", "" }
  local path_map = {}

  local tree = build_tree(files)
  render_tree(tree, lines, "  ", path_map)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  ? for help"

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Open in a left vsplit.
  vim.cmd("topleft vsplit")
  vim.api.nvim_set_current_buf(buf)
  vim.cmd("vertical resize 38")

  local opts = { noremap = true, silent = true, buffer = buf }

  local function open_file_at_cursor()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local path = path_map[lnum]
    if path then
      vim.cmd("wincmd p")
      guest.request_file(path)
    end
  end

  vim.keymap.set("n", "<CR>", open_file_at_cursor, opts)
  vim.keymap.set("n", "o",    open_file_at_cursor, opts)
  vim.keymap.set("n", "q",    "<cmd>close<CR>",    opts)
  vim.keymap.set("n", "R", function()
    vim.cmd("close")
    M.open_workspace_explorer()
  end, opts)
  vim.keymap.set("n", "?", function()
    vim.notify(
      "live-share workspace:\n"
      .. "  <CR> / o  open file\n"
      .. "  q         close\n"
      .. "  R         refresh",
      vim.log.levels.INFO)
  end, opts)
end

-- ── Participants panel ────────────────────────────────────────────────────────
--
-- Floating window listing all peers with their active file and cursor position.

function M.show_participants()
  local presence = require("live-share.presence")
  local session  = require("live-share.session")

  if not session.active() then
    vim.notify("live-share: no active session", vim.log.levels.WARN)
    return
  end

  local peers = presence.get_all()
  local g_role = require("live-share.guest").get_role and require("live-share.guest").get_role() or nil
  local role_suffix = (g_role == "ro") and " [read-only]" or ""
  local role  = session.role == "host" and "host" or ("guest #" .. tostring(session.peer_id) .. role_suffix)

  local lines = {
    "  Live Share — Peers",
    "  " .. string.rep("─", 36),
    "  You: " .. role,
    "",
  }

  if #peers == 0 then
    lines[#lines + 1] = "  (no other participants yet)"
  else
    for _, p in ipairs(peers) do
      local loc = p.active_path or "(unknown file)"
      local pos = p.lnum and ("  L" .. (p.lnum + 1)) or ""
      local ro  = ""
      if p.active_path then
        local b = require("live-share.buffer_registry").get_buf(p.active_path)
        if b and vim.b[b] and vim.b[b].live_share_readonly then ro = " [ro]" end
      end
      lines[#lines + 1] = "  • " .. p.name .. "  →  " .. loc .. pos .. ro
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  [q / <Esc> to close]"

  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, #l + 2) end
  local h = #lines

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden  = "wipe"

  vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width    = math.max(w, 42),
    height   = h,
    row      = math.floor((vim.o.lines   - h) / 2),
    col      = math.floor((vim.o.columns - w) / 2),
    style    = "minimal",
    border   = "rounded",
    title    = " Peers ",
    title_pos = "center",
  })

  local fopts = { noremap = true, silent = true, buffer = fbuf }
  vim.keymap.set("n", "q",     "<cmd>close<CR>", fopts)
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", fopts)
end

return M
