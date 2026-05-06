-- Local audit log for the host: append-only JSONL of session events.
--
-- Format: one JSON object per line.  Fields written on every record:
--   ts          ISO-8601 UTC timestamp
--   seq         monotonic counter, starts at 1 and increments on every record
--   event       short event name (peer_joined, file_request_allowed, …)
--   sid         session id (set by the host on each session_start)
--   prev_hash   hex SHA-256 of the previous JSON line, or 64 zero hex chars
--               for the first ever entry in the file.  Chains the entire log
--               into a tamper-evident sequence: any in-place edit, deletion,
--               or reorder breaks the chain at the next record.
--   payload_hash (optional) hex SHA-256 of the encrypted protocol payload that
--               triggered the event, when applicable.  Set by the caller via
--               `fields.payload_hash` (server.lua attaches `__payload_hash` to
--               inbound messages; host.lua passes it through).
--   …           event-specific fields (peer_id, peer_name, path, reason, role)
--
-- Verifier algorithm:
--   1. Read the file line by line.
--   2. For line N>1, recompute SHA-256(line N-1 as written, no trailing \n)
--      and compare to line N's `prev_hash`.  Mismatch ⇒ tampering.
--   3. The first line's `prev_hash` MUST be 64 zero hex characters.  If a
--      previous session existed in the same file, its tail's hash must match
--      the new session's first prev_hash (the chain spans sessions).
--
-- Disable with `setup({ audit_log = false })` or override the location with
-- `setup({ audit_log = "/path/to/log" })`.  The default location is
-- `stdpath('state')/live-share-audit.log`.
--
-- Writes are non-blocking via libuv; the module silently no-ops if the log
-- can't be opened.  Contents of files and patches are NEVER written here.
local M = {}

local uv = vim.uv or vim.loop
local crypto = require("live-share.collab.crypto")

local fd = nil
local sid = nil
local seq = 0
local prev_hash_hex = string.rep("0", 64)

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

local HEX = "0123456789abcdef"
local function to_hex(bytes)
  if not bytes then
    return nil
  end
  local out = {}
  for i = 1, #bytes do
    local b = bytes:byte(i)
    out[#out + 1] = HEX:sub(math.floor(b / 16) + 1, math.floor(b / 16) + 1)
    out[#out + 1] = HEX:sub(b % 16 + 1, b % 16 + 1)
  end
  return table.concat(out)
end

-- Hex SHA-256 of a Lua string.  Returns nil if OpenSSL is unavailable —
-- callers should skip hash fields in that case.
function M.hash(input)
  if input == nil then
    return nil
  end
  local digest = crypto.sha256(input)
  return digest and to_hex(digest) or nil
end

-- Read the last non-empty line of an existing log file.  Used at setup() to
-- seed prev_hash so the chain spans sessions: a tamper attempt that truncates
-- prior sessions invalidates the new session's first record.  Returns nil if
-- the file is missing or empty.
local function tail_line(path)
  local f, _ = io.open(path, "rb")
  if not f then
    return nil
  end
  local size = f:seek("end") or 0
  if size == 0 then
    f:close()
    return nil
  end
  -- Read up to the last 8 KB; any audit line is well below that.
  local window = math.min(size, 8 * 1024)
  f:seek("set", size - window)
  local chunk = f:read(window) or ""
  f:close()
  -- Trim trailing newlines and pick the last \n-delimited segment.
  chunk = chunk:gsub("\n+$", "")
  local last_nl = chunk:find("\n[^\n]*$")
  if last_nl then
    return chunk:sub(last_nl + 1)
  end
  return chunk
end

function M.setup(cfg)
  M.close()
  if not cfg or cfg.audit_log == false then
    return
  end
  local path = (type(cfg.audit_log) == "string" and cfg.audit_log ~= "") and cfg.audit_log or default_path()
  ensure_dir(path)

  -- Seed prev_hash from the existing file's tail, if any.  This makes the
  -- chain continuous across host restarts on the same log file.
  local last = tail_line(path)
  if last and last ~= "" then
    local h = M.hash(last)
    if h then
      prev_hash_hex = h
    else
      -- crypto.sha256 unavailable: chain integrity is degraded; the caller is
      -- already going to be running in plaintext mode in that case.
      prev_hash_hex = string.rep("0", 64)
    end
  else
    prev_hash_hex = string.rep("0", 64)
  end
  seq = 0

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
  seq = seq + 1
  local rec = {
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    seq = seq,
    event = event,
    sid = sid,
    prev_hash = prev_hash_hex,
  }
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
  -- Update the chain: the next record's prev_hash is the SHA-256 of the line
  -- we just wrote (without the trailing newline).  If sha256 is unavailable
  -- (no OpenSSL), keep the previous value — the chain degrades but the file
  -- remains parseable.
  local h = M.hash(line)
  if h then
    prev_hash_hex = h
  end
end

function M.close()
  if fd then
    pcall(uv.fs_close, fd)
    fd = nil
  end
  sid = nil
  seq = 0
  prev_hash_hex = string.rep("0", 64)
end

return M
