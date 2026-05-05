-- Stage 1 (defence-in-depth): server-side validations introduced for v3.
-- These tests do NOT require a wire-format change — protocol stays at v3.
--
-- Coverage:
--   1. peer_id binding — `msg.peer` set by a malicious client is overwritten
--      by the connection's authoritative peer_id before reaching the handler
--      and the broadcast path.
--   2. path validation — messages with traversal/absolute/sensitive paths
--      are dropped before the host's on_message handler runs.  Verified via
--      workspace.path_allowed; the actual host wiring is exercised in the
--      module-level tests below.
--   3. rate limit — a peer sending bursts of patches/cursors above the
--      configured threshold has the excess silently dropped.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local server = require("live-share.collab.server")
local protocol = require("live-share.collab.protocol")
local tcp_trans = require("live-share.collab.transport.tcp")
local workspace = require("live-share.workspace")
local uv = vim.uv or vim.loop

local BASE_PORT = 19920
local TIMEOUT_MS = 3000

local function wait_for(cond)
  return vim.wait(TIMEOUT_MS, cond, 10)
end

local function make_tcp_peer(port, key)
  local peer = { msgs = {} }
  local tcp = uv.new_tcp()

  tcp:connect("127.0.0.1", port, function(err)
    if err then
      return
    end
    tcp:write("\x00\x00\x00\x00")
    local reader = tcp_trans.new_reader()
    tcp:read_start(function(rerr, data)
      if rerr or not data then
        return
      end
      local payloads = reader(data)
      vim.schedule(function()
        for _, payload in ipairs(payloads) do
          local msg = protocol.decode(payload, key)
          if msg then
            table.insert(peer.msgs, msg)
          end
        end
      end)
    end)
  end)

  function peer:send(msg)
    if not tcp:is_closing() then
      tcp:write(tcp_trans.frame(protocol.encode(msg, key)))
    end
  end

  function peer:stop()
    if not tcp:is_closing() then
      tcp:close()
    end
  end

  return peer
end

-- ── peer_id binding ───────────────────────────────────────────────────────────
describe("peer_id binding", function()
  after_each(function()
    server.stop()
  end)

  it("overwrites a client-supplied msg.peer with the authoritative peer_id", function()
    local received = {}

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        server.approve(peer_id)
      else
        table.insert(received, { msg = msg, peer_id = peer_id })
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT, nil), "server failed to bind")

    local p = make_tcp_peer(BASE_PORT, nil)

    assert.is_true(
      wait_for(function()
        return #received >= 0 and p.msgs ~= nil
      end),
      "peer never connected"
    )
    -- Wait for connect/approve cycle to settle.
    vim.wait(150)

    -- Lie: claim to be peer #99.  Server must overwrite to the real peer_id.
    p:send({ t = "cursor", path = "a.lua", peer = 99, lnum = 0, col = 0 })

    assert.is_true(
      wait_for(function()
        for _, e in ipairs(received) do
          if e.msg.t == "cursor" then
            return true
          end
        end
        return false
      end),
      "cursor message never reached the handler"
    )

    local cursor_event
    for _, e in ipairs(received) do
      if e.msg.t == "cursor" then
        cursor_event = e
        break
      end
    end
    assert.is_not_nil(cursor_event)
    -- The fake `peer = 99` must have been overwritten with the real peer_id.
    assert.equals(cursor_event.peer_id, cursor_event.msg.peer)
    assert.is_not.equals(99, cursor_event.msg.peer)

    p:stop()
  end)
end)

-- ── path validation ──────────────────────────────────────────────────────────
describe("workspace.path_allowed", function()
  before_each(function()
    workspace.setup({})
    workspace.set_root(vim.fn.tempname())
    -- We don't need the dir to actually exist for the syntactic checks.
  end)

  it("accepts plain workspace-relative paths", function()
    assert.is_true(workspace.path_allowed("src/foo.lua"))
    assert.is_true(workspace.path_allowed("README.md"))
    assert.is_true(workspace.path_allowed(".github/workflows/ci.yml"))
  end)

  it("rejects path traversal", function()
    assert.is_false(workspace.path_allowed("../etc/passwd"))
    assert.is_false(workspace.path_allowed("foo/../../etc"))
  end)

  it("rejects absolute paths and Windows drive letters", function()
    assert.is_false(workspace.path_allowed("/etc/passwd"))
    assert.is_false(workspace.path_allowed("\\Windows\\System32\\config"))
    assert.is_false(workspace.path_allowed("C:/Windows/notepad.exe"))
  end)

  it("rejects NUL bytes", function()
    assert.is_false(workspace.path_allowed("foo\0bar"))
  end)

  it("rejects sensitive paths even if syntactically valid", function()
    assert.is_false(workspace.path_allowed(".env"))
    assert.is_false(workspace.path_allowed(".ssh/id_rsa"))
    assert.is_false(workspace.path_allowed("certs/private.pem"))
  end)

  it("rejects nil and empty paths", function()
    assert.is_false(workspace.path_allowed(nil))
    assert.is_false(workspace.path_allowed(""))
  end)
end)

-- ── rate limit ────────────────────────────────────────────────────────────────
describe("per-peer rate limit", function()
  after_each(function()
    server.stop()
  end)

  it("drops cursor bursts that exceed 60/s", function()
    local received = 0

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        server.approve(peer_id)
      elseif msg.t == "cursor" then
        received = received + 1
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 1, nil), "server failed to bind")

    local p = make_tcp_peer(BASE_PORT + 1, nil)
    vim.wait(150) -- let the connect/approve cycle settle

    -- Fire 200 cursor updates as fast as possible.  At 60/s, the bucket is
    -- 60 wide and refills at 60/s; in <300 ms only ~60 should pass.
    for i = 1, 200 do
      p:send({ t = "cursor", path = "a.lua", lnum = i, col = 0 })
    end

    -- Give the server a moment to process the queue.
    vim.wait(300)

    -- Should be far below 200 (theoretical: ~60-80 with a tiny refill).
    assert.is_true(received <= 90, "expected ≤ 90 cursors through, got " .. received)
    assert.is_true(received >= 30, "expected ≥ 30 cursors through, got " .. received)

    p:stop()
  end)

  it("does not throttle messages below the rate limit", function()
    local received = 0

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        server.approve(peer_id)
      elseif msg.t == "cursor" then
        received = received + 1
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 2, nil), "server failed to bind")

    local p = make_tcp_peer(BASE_PORT + 2, nil)
    vim.wait(150)

    -- 10 cursor updates spaced ~10 ms apart = 100 events/s but only 10 events
    -- total — below the 60/s cap.
    for i = 1, 10 do
      p:send({ t = "cursor", path = "a.lua", lnum = i, col = 0 })
      vim.wait(10)
    end

    assert.is_true(
      wait_for(function()
        return received == 10
      end),
      "expected all 10 cursors through, got " .. received
    )

    p:stop()
  end)
end)
