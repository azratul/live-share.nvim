-- Local audit log for the host: append-only JSONL of session events.
--
-- Format: one JSON object per line, fields:
--   ts        ISO-8601 UTC timestamp
--   event     short event name (see below)
--   sid       session id (set by the host on each session_start)
--   …         event-specific fields (peer_id, peer_name, path, reason, role, …)
--
-- Disable with `setup({ audit_log = false })` or override the location with
-- `setup({ audit_log = "/path/to/log" })`.  The default location is
-- `stdpath('state')/live-share-audit.log`.
--
-- Writes are non-blocking via libuv; the module silently no-ops if the log
-- can't be opened.  Contents of files and patches are NEVER written here.
local M = {}

local uv = vim.uv or vim.loop

local fd = nil
local sid = nil

local function default_path()
  local ok, state = pcall(vim.fn.stdpath, "state")
  if not ok or not state or state == "" then
    state = vim.fn.stdpath("cache")
  end
  return state .. "/live-share-audit.log"
end

local function ensure_dir(path)
  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" then
    pcall(vim.fn.mkdir, dir, "p")
  end
end

function M.setup(cfg)
  M.close()
  if not cfg or cfg.audit_log == false then
    return
  end
  local path = (type(cfg.audit_log) == "string" and cfg.audit_log ~= "") and cfg.audit_log or default_path()
  ensure_dir(path)
  local handle, err = uv.fs_open(path, "a", 384) -- 0600 — log may contain peer names / paths
  if not handle then
    vim.schedule(function()
      vim.notify("live-share: audit log disabled — open failed: " .. tostring(err), vim.log.levels.WARN)
    end)
    return
  end
  fd = handle
  M.path = path
end

function M.set_session(session_id)
  sid = session_id
end

function M.log(event, fields)
  if not fd then
    return
  end
  local rec = { ts = os.date("!%Y-%m-%dT%H:%M:%SZ"), event = event, sid = sid }
  if type(fields) == "table" then
    for k, v in pairs(fields) do
      rec[k] = v
    end
  end
  local ok, line = pcall(vim.json.encode, rec)
  if not ok then
    return
  end
  uv.fs_write(fd, line .. "\n", -1)
end

function M.close()
  if fd then
    pcall(uv.fs_close, fd)
    fd = nil
  end
  sid = nil
end

return M
