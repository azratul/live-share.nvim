-- UI layer: workspace file picker and participants panel.
-- Pure Neovim API — no external plugin dependencies.
local M = {}

-- ── Workspace file picker ─────────────────────────────────────────────────────
--
-- Uses vim.ui.select when a plugin has overridden it (telescope-ui-select,
-- fzf-lua, snacks, …); falls back to a custom collapsible tree otherwise.

local function has_ui_select_override()
  local info = debug.getinfo(vim.ui.select, "S")
  return info and info.source and not info.source:find("vim/ui%.lua", 1, false)
end

-- ── Tree fallback ─────────────────────────────────────────────────────────────

local function build_tree(paths)
  local root = { children = {}, files = {}, _order = {} }
  for _, path in ipairs(paths) do
    local parts = vim.split(path, "/", { plain = true })
    local node = root
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

local function render_tree(node, lines, path_map, dir_map, collapsed, indent, node_path)
  local order = vim.deepcopy(node._order)
  table.sort(order, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "dir"
    end
    return a.name < b.name
  end)

  for _, item in ipairs(order) do
    if item.kind == "dir" then
      local full_path = node_path .. item.name
      local icon = collapsed[full_path] and "▸" or "▾"
      lines[#lines + 1] = indent .. icon .. " " .. item.name .. "/"
      dir_map[#lines] = full_path
      if not collapsed[full_path] then
        render_tree(node.children[item.name], lines, path_map, dir_map, collapsed, indent .. "  ", full_path .. "/")
      end
    else
      lines[#lines + 1] = indent .. "  " .. item.name
      path_map[#lines] = item.path
    end
  end
end

local EXPLORER_NAME = "live-share://workspace"

local function open_tree_explorer(files, root_name, on_select)
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local wb = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_buf_get_name(wb) == EXPLORER_NAME then
      vim.api.nvim_win_close(w, true)
      break
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, EXPLORER_NAME)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  local tree = build_tree(files)
  local collapsed = {}
  local path_map = {}
  local dir_map = {}

  local function refresh()
    for k in pairs(path_map) do
      path_map[k] = nil
    end
    for k in pairs(dir_map) do
      dir_map[k] = nil
    end
    local lines = { "  " .. root_name .. "/", "" }
    render_tree(tree, lines, path_map, dir_map, collapsed, "  ", "")
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end

  refresh()

  vim.cmd("topleft vsplit")
  vim.api.nvim_set_current_buf(buf)
  vim.cmd("vertical resize 38")

  local opts = { noremap = true, silent = true, buffer = buf }

  vim.keymap.set("n", "<CR>", function()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local file_path = path_map[lnum]
    local dir_path = dir_map[lnum]
    if file_path then
      vim.cmd("wincmd p")
      on_select(file_path)
    elseif dir_path then
      collapsed[dir_path] = not collapsed[dir_path] or nil
      local cursor = vim.api.nvim_win_get_cursor(0)
      refresh()
      cursor[1] = math.min(cursor[1], vim.api.nvim_buf_line_count(buf))
      vim.api.nvim_win_set_cursor(0, cursor)
    end
  end, opts)

  vim.keymap.set("n", "q", "<cmd>close<CR>", opts)
  vim.keymap.set("n", "R", function()
    vim.cmd("close")
    open_tree_explorer(files, root_name, on_select)
  end, opts)
end

-- ── Public API ────────────────────────────────────────────────────────────────

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

  if has_ui_select_override() then
    vim.ui.select(files, { prompt = "Workspace files" }, function(path)
      if path then
        guest.request_file(path)
      end
    end)
  else
    local root_name = guest.get_workspace_root_name() or "workspace"
    open_tree_explorer(files, root_name, function(path)
      guest.request_file(path)
    end)
  end
end

-- ── Participants panel ────────────────────────────────────────────────────────
--
-- Floating window listing all peers with their active file and cursor position.

function M.show_peers()
  local presence = require("live-share.presence")
  local session = require("live-share.session")

  if not session.active() then
    vim.notify("live-share: no active session", vim.log.levels.WARN)
    return
  end

  local peers = presence.get_all()
  local g_role = require("live-share.guest").get_role and require("live-share.guest").get_role() or nil
  local role_suffix = (g_role == "ro") and " [read-only]" or ""
  local role = session.role == "host" and "host" or ("guest #" .. tostring(session.peer_id) .. role_suffix)

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
      local ro = ""
      if p.active_path then
        local b = require("live-share.buffer_registry").get_buf(p.active_path)
        if b and vim.b[b] and vim.b[b].live_share_readonly then
          ro = " [ro]"
        end
      end
      lines[#lines + 1] = "  • " .. p.name .. "  →  " .. loc .. pos .. ro
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  [q / <Esc> to close]"

  local w = 0
  for _, l in ipairs(lines) do
    w = math.max(w, #l + 2)
  end
  local h = #lines

  local fbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, lines)
  vim.bo[fbuf].modifiable = false
  vim.bo[fbuf].bufhidden = "wipe"

  vim.api.nvim_open_win(fbuf, true, {
    relative = "editor",
    width = math.max(w, 42),
    height = h,
    row = math.floor((vim.o.lines - h) / 2),
    col = math.floor((vim.o.columns - w) / 2),
    style = "minimal",
    border = "rounded",
    title = " Peers ",
    title_pos = "center",
  })

  local fopts = { noremap = true, silent = true, buffer = fbuf }
  vim.keymap.set("n", "q", "<cmd>close<CR>", fopts)
  vim.keymap.set("n", "<Esc>", "<cmd>close<CR>", fopts)
end

return M
