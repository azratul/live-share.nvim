-- Workspace: directory scanning and on-demand file I/O (host-side).
-- All paths are relative to the workspace root.
local M = {}

local log = require("live-share.collab.log")
local uv = vim.uv or vim.loop

local MAX_DEPTH = 8
local FILE_SIZE_CAP = 5 * 1024 * 1024 -- 5 MB

local IGNORE = {
  [".git"] = true,
  ["node_modules"] = true,
  [".DS_Store"] = true,
  ["__pycache__"] = true,
  [".svn"] = true,
  ["vendor"] = true,
  [".hg"] = true,
  ["dist"] = true,
  ["build"] = true,
}

local root = nil

function M.set_root(path)
  root = path
end

function M.get_root()
  return root
end

-- Returns a flat sorted list of workspace-relative file paths.
function M.scan()
  if not root then
    return {}
  end
  local paths = {}

  local function scan_dir(dir, prefix, depth)
    if depth > MAX_DEPTH then
      return
    end
    local handle = uv.fs_opendir(dir, nil, 256)
    if not handle then
      return
    end

    while true do
      local entries = uv.fs_readdir(handle)
      if not entries then
        break
      end
      for _, entry in ipairs(entries) do
        if not IGNORE[entry.name] and entry.name:sub(1, 1) ~= "." then
          local rel = prefix ~= "" and (prefix .. "/" .. entry.name) or entry.name
          if entry.type == "file" then
            paths[#paths + 1] = rel
          elseif entry.type == "directory" then
            scan_dir(dir .. "/" .. entry.name, rel, depth + 1)
          end
        end
      end
    end
    uv.fs_closedir(handle)
  end

  scan_dir(root, "", 0)
  table.sort(paths)
  return paths
end

-- Safety check: reject path-traversal attempts.
local function safe_abs(path)
  if not root or not path then
    return nil
  end
  if path:find("%.%./", 1, true) or path:find("/%.%.", 1, true) or path:sub(1, 2) == ".." then
    return nil
  end
  return root .. "/" .. path
end

-- Read a workspace file. Returns lines table, or nil on error.
function M.read_file(path)
  local abs = safe_abs(path)
  if not abs then
    return nil
  end

  local fd, err = uv.fs_open(abs, "r", 292) -- 0444
  if not fd then
    log.dbg("workspace", "read_file '" .. path .. "': " .. tostring(err))
    return nil
  end

  local stat = uv.fs_fstat(fd)
  if not stat or stat.size > FILE_SIZE_CAP then
    uv.fs_close(fd)
    return nil
  end

  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then
    return nil
  end

  local lines = vim.split(data, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

-- Write lines back to a workspace file. Returns true on success.
function M.write_file(path, lines)
  local abs = safe_abs(path)
  if not abs then
    return false
  end

  local content = table.concat(lines, "\n") .. "\n"
  local fd, err = uv.fs_open(abs, "w", 420) -- 0644
  if not fd then
    log.dbg("workspace", "write_file '" .. path .. "': " .. tostring(err))
    return false
  end
  uv.fs_write(fd, content, 0)
  uv.fs_close(fd)
  return true
end

-- Apply a patch (from a client) to a file that isn't open in Neovim.
-- Reads, patches in-memory, writes back. Returns true on success.
function M.apply_patch_to_disk(path, lnum, count, new_lines)
  local lines = M.read_file(path) or {}
  local end_idx = count == -1 and #lines or (lnum + count)

  local result = {}
  for i = 1, lnum do
    result[#result + 1] = lines[i]
  end
  for _, l in ipairs(new_lines or {}) do
    result[#result + 1] = l
  end
  for i = end_idx + 1, #lines do
    result[#result + 1] = lines[i]
  end

  return M.write_file(path, result)
end

return M
