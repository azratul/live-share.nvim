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

-- ── Sensitive-file filter ─────────────────────────────────────────────────────
-- Files matching these rules are excluded from workspace listings and refused on
-- read/write requests, even if the path is otherwise inside the workspace.
-- Opt out with `setup({ allow_sensitive_files = true })` and extend with
-- `setup({ extra_sensitive_patterns = { "%.tfstate$", ... } })`.

local SENSITIVE_BASENAMES = {
  -- SSH
  ["id_rsa"] = true,
  ["id_dsa"] = true,
  ["id_ecdsa"] = true,
  ["id_ed25519"] = true,
  ["id_rsa.pub"] = true,
  ["id_dsa.pub"] = true,
  ["id_ecdsa.pub"] = true,
  ["id_ed25519.pub"] = true,
  ["known_hosts"] = true,
  ["authorized_keys"] = true,
  -- Cloud / package manager creds
  ["credentials"] = true,
  ["htpasswd"] = true,
  [".npmrc"] = true,
  [".pypirc"] = true,
  [".netrc"] = true,
  ["_netrc"] = true,
  -- Dotenv variants
  [".env"] = true,
  [".env.local"] = true,
  [".env.development"] = true,
  [".env.production"] = true,
  [".env.test"] = true,
}

local SENSITIVE_EXTENSIONS = {
  pem = true,
  key = true,
  p12 = true,
  pfx = true,
  jks = true,
  keystore = true,
  asc = true,
  gpg = true,
}

-- Patterns matched against the workspace-relative path (forward slashes).
local SENSITIVE_PATH_PATTERNS = {
  "^%.env%.", -- .env.foo
  "^%.aws/",
  "/%.aws/",
  "^%.kube/",
  "/%.kube/",
  "^%.gcloud/",
  "/%.gcloud/",
  "^%.ssh/",
  "/%.ssh/",
  "^%.azure/",
  "/%.azure/",
  "^%.config/gcloud/",
  "/%.config/gcloud/",
}

local extra_patterns = {}
local allow_sensitive = false

local function is_sensitive(rel_path)
  if allow_sensitive or not rel_path or rel_path == "" then
    return false
  end
  local norm = rel_path:gsub("\\", "/")
  local basename = norm:match("([^/]+)$") or norm
  if SENSITIVE_BASENAMES[basename] then
    return true
  end
  local ext = basename:match("%.([^%.]+)$")
  if ext and SENSITIVE_EXTENSIONS[ext:lower()] then
    return true
  end
  for _, pat in ipairs(SENSITIVE_PATH_PATTERNS) do
    if norm:match(pat) then
      return true
    end
  end
  for _, pat in ipairs(extra_patterns) do
    if norm:match(pat) then
      return true
    end
  end
  return false
end

M.is_sensitive = is_sensitive

-- ── Setup ─────────────────────────────────────────────────────────────────────

local root = nil
local real_root = nil -- canonicalised root for sandbox checks

function M.setup(cfg)
  cfg = cfg or {}
  allow_sensitive = cfg.allow_sensitive_files == true
  extra_patterns = {}
  if type(cfg.extra_sensitive_patterns) == "table" then
    for _, p in ipairs(cfg.extra_sensitive_patterns) do
      if type(p) == "string" and p ~= "" then
        extra_patterns[#extra_patterns + 1] = p
      end
    end
  end
end

function M.set_root(path)
  root = path
  real_root = path and uv.fs_realpath(path) or nil
end

function M.get_root()
  return root
end

-- ── Sandbox ───────────────────────────────────────────────────────────────────
-- Reject path traversal, absolute paths, NUL bytes, and any resolution that
-- escapes the workspace root (including via symlinks).
local function sandbox_check(path)
  if not root or not path or path == "" then
    return nil, "no-root"
  end
  if path:find("\0", 1, true) then
    return nil, "nul-byte"
  end
  -- Reject leading separators and Windows drive letters (absolute paths).
  local first = path:sub(1, 1)
  if first == "/" or first == "\\" then
    return nil, "absolute"
  end
  if path:match("^%a:[/\\]") then
    return nil, "drive-letter"
  end
  -- Reject any segment that is exactly "..".
  for seg in path:gmatch("[^/\\]+") do
    if seg == ".." then
      return nil, "traversal"
    end
  end
  return true
end

-- Returns the absolute on-disk path if it's safely inside the workspace.
-- For new files (which don't exist yet), the parent directory must resolve
-- inside the workspace root.
local function safe_abs(path)
  local ok, reason = sandbox_check(path)
  if not ok then
    log.dbg("workspace", "rejected '" .. tostring(path) .. "': " .. tostring(reason))
    return nil
  end

  if is_sensitive(path) then
    log.dbg("workspace", "rejected '" .. path .. "': sensitive file")
    return nil
  end

  local candidate = root .. "/" .. path
  local rroot = real_root or uv.fs_realpath(root) or root
  local prefix = rroot .. "/"

  local real = uv.fs_realpath(candidate)
  if real then
    if real == rroot then
      return nil -- candidate resolves to root itself, not a file
    end
    if real:sub(1, #prefix) ~= prefix then
      log.dbg("workspace", "rejected '" .. path .. "': escapes workspace via realpath")
      return nil
    end
    return real
  end

  -- Path doesn't exist yet. Validate the parent directory resolves inside root
  -- so creating the file can't escape via a symlinked subdirectory.
  local parent_rel = path:match("^(.*)/[^/]+$")
  local parent_abs = parent_rel and (root .. "/" .. parent_rel) or root
  local real_parent = uv.fs_realpath(parent_abs)
  if not real_parent then
    return candidate -- parent doesn't exist either; let the open syscall decide
  end
  if real_parent ~= rroot and real_parent:sub(1, #prefix) ~= prefix then
    log.dbg("workspace", "rejected '" .. path .. "': parent dir escapes workspace")
    return nil
  end
  local basename = path:match("([^/]+)$") or path
  return real_parent .. "/" .. basename
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
            if not is_sensitive(rel) then
              paths[#paths + 1] = rel
            end
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
