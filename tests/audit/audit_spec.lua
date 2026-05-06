-- Unit tests for lua/live-share/audit.lua
--
-- Coverage:
--   1. Disabled when audit_log = false (no file created)
--   2. Custom path is honoured
--   3. Each call appends one JSON object per line
--   4. Records include ts, event, sid and any custom fields
--   5. set_session is reflected in subsequent log records
--   6. seq counter increments monotonically per session and resets on close
--   7. prev_hash chain: every entry's prev_hash equals SHA-256(previous line)
--   8. The chain spans sessions: a fresh setup() on an existing file uses the
--      file's tail hash as the new genesis, so truncating prior sessions
--      breaks the chain.
--   9. payload_hash is preserved when callers pass it through `fields`.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local audit = require("live-share.audit")
local crypto = require("live-share.collab.crypto")

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

local HEX = "0123456789abcdef"
local function to_hex(bytes)
  local out = {}
  for i = 1, #bytes do
    local b = bytes:byte(i)
    out[#out + 1] = HEX:sub(math.floor(b / 16) + 1, math.floor(b / 16) + 1)
    out[#out + 1] = HEX:sub(b % 16 + 1, b % 16 + 1)
  end
  return table.concat(out)
end

local ZERO_HASH = string.rep("0", 64)

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

  -- ── Stage 5: tamper-evident chain ──────────────────────────────────────────

  it("seq counter is monotonic per session and resets on close", function()
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.log("a")
    audit.log("b")
    audit.log("c")
    audit.close()
    local lines = read_lines(p)
    assert.equals(1, vim.json.decode(lines[1]).seq)
    assert.equals(2, vim.json.decode(lines[2]).seq)
    assert.equals(3, vim.json.decode(lines[3]).seq)

    -- A second session on a different file starts back at seq=1.
    local q = tmpfile()
    audit.setup({ audit_log = q })
    audit.log("x")
    audit.close()
    assert.equals(1, vim.json.decode(read_lines(q)[1]).seq)
  end)

  it("first record uses the all-zero genesis prev_hash on a fresh file", function()
    if not crypto.available then
      pending("OpenSSL unavailable — skipping chain tests")
      return
    end
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.log("genesis")
    audit.close()
    local r = vim.json.decode(read_lines(p)[1])
    assert.equals(ZERO_HASH, r.prev_hash)
  end)

  it("each record's prev_hash equals SHA-256(previous JSON line)", function()
    if not crypto.available then
      pending("OpenSSL unavailable — skipping chain tests")
      return
    end
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.log("a")
    audit.log("b")
    audit.log("c")
    audit.close()

    local lines = read_lines(p)
    assert.equals(3, #lines)

    -- Walk the chain.
    local expected_prev = ZERO_HASH
    for i, raw in ipairs(lines) do
      local rec = vim.json.decode(raw)
      assert.equals(expected_prev, rec.prev_hash, "chain break at line " .. i)
      expected_prev = to_hex(crypto.sha256(raw))
    end
  end)

  it("chain spans sessions: a new session links to the prior file's tail", function()
    if not crypto.available then
      pending("OpenSSL unavailable — skipping chain tests")
      return
    end
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.log("session-A-evt")
    audit.close()

    audit.setup({ audit_log = p })
    audit.log("session-B-evt")
    audit.close()

    local lines = read_lines(p)
    assert.equals(2, #lines)
    -- The 2nd session's first record's prev_hash must equal SHA-256 of the
    -- 1st session's last line (verbatim).
    local prior_hash = to_hex(crypto.sha256(lines[1]))
    assert.equals(prior_hash, vim.json.decode(lines[2]).prev_hash)
  end)

  it("payload_hash field is preserved when supplied by caller", function()
    local p = tmpfile()
    audit.setup({ audit_log = p })
    audit.log("file_request_allowed", { peer_id = 7, payload_hash = "deadbeef" })
    audit.close()
    local r = vim.json.decode(read_lines(p)[1])
    assert.equals("deadbeef", r.payload_hash)
    assert.equals(7, r.peer_id)
  end)

  it("M.hash returns hex SHA-256 (or nil when OpenSSL is unavailable)", function()
    if not crypto.available then
      assert.is_nil(audit.hash("anything"))
      return
    end
    local h = audit.hash("hello")
    assert.equals(64, #h)
    -- Known SHA-256("hello") prefix, sanity check.
    assert.equals("2cf24dba5fb0a30e26e83b2ac5b9e29e", h:sub(1, 32))
  end)
end)
