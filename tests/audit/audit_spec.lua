-- Unit tests for lua/live-share/audit.lua
--
-- Coverage:
--   1. Disabled when audit_log = false (no file created)
--   2. Custom path is honoured
--   3. Each call appends one JSON object per line
--   4. Records include ts, event, sid and any custom fields
--   5. set_session is reflected in subsequent log records
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local audit = require("live-share.audit")

local function tmpfile()
  return vim.fn.tempname() .. ".log"
end

local function read_lines(path)
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local out = {}
  for line in f:lines() do
    out[#out + 1] = line
  end
  f:close()
  return out
end

describe("audit", function()
  after_each(function()
    audit.close()
  end)

  it("does not create a file when audit_log = false", function()
    local p = tmpfile()
    audit.setup({ audit_log = false })
    audit.log("session_start")
    audit.close()
    assert.is_nil(vim.uv.fs_stat(p))
  end)

  it("writes one JSON line per log call to the configured path", function()
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.set_session("abc123")
    audit.log("session_start", { workspace = "demo" })
    audit.log("peer_joined", { peer_id = 1, peer_name = "alice" })
    audit.close()

    local lines = read_lines(p)
    assert.equals(2, #lines)

    local r1 = vim.json.decode(lines[1])
    assert.equals("session_start", r1.event)
    assert.equals("abc123", r1.sid)
    assert.equals("demo", r1.workspace)
    assert.is_truthy(r1.ts)

    local r2 = vim.json.decode(lines[2])
    assert.equals("peer_joined", r2.event)
    assert.equals(1, r2.peer_id)
    assert.equals("alice", r2.peer_name)
  end)

  it("appends to an existing file across setup() calls", function()
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.log("first")
    audit.close()

    audit.setup({ audit_log = p })
    audit.log("second")
    audit.close()

    local lines = read_lines(p)
    assert.equals(2, #lines)
    assert.equals("first", vim.json.decode(lines[1]).event)
    assert.equals("second", vim.json.decode(lines[2]).event)
  end)

  it("set_session updates sid for subsequent records", function()
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.set_session("session-A")
    audit.log("e1")
    audit.set_session("session-B")
    audit.log("e2")
    audit.close()

    local lines = read_lines(p)
    assert.equals("session-A", vim.json.decode(lines[1]).sid)
    assert.equals("session-B", vim.json.decode(lines[2]).sid)
  end)

  it("close() prevents further writes", function()
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.log("before")
    audit.close()
    audit.log("after-close") -- should be a no-op
    local lines = read_lines(p)
    assert.equals(1, #lines)
    assert.equals("before", vim.json.decode(lines[1]).event)
  end)
end)
