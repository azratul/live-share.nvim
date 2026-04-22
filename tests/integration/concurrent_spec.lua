-- Integration tests for concurrent and multi-peer scenarios.
--
-- Gaps covered:
--   1. Three-peer broadcast: all three peers receive the message
--   2. Sequential delivery: server sends N messages, peer receives them in send order
--   3. Concurrent guest patches: patches from two guests both reach the server
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local server = require("live-share.collab.server")
local protocol = require("live-share.collab.protocol")
local tcp_trans = require("live-share.collab.transport.tcp")
local uv = vim.uv or vim.loop

local BASE_PORT = 19900
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

local function patches(peer)
  local result = {}
  for _, m in ipairs(peer.msgs) do
    if m.t == "patch" then
      table.insert(result, m)
    end
  end
  return result
end

-- ── Three-peer broadcast ──────────────────────────────────────────────────────
describe("Three-peer broadcast", function()
  local peers = {}

  after_each(function()
    for _, p in ipairs(peers) do
      p:stop()
    end
    peers = {}
    server.stop()
  end)

  it("broadcast reaches three simultaneous TCP peers", function()
    local connected = 0

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        connected = connected + 1
        server.approve(peer_id)
        if connected == 3 then
          server.broadcast({ t = "patch", path = "a.lua", lnum = 0, count = 0, lines = { "three-peer" } })
        end
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT, nil), "server failed to bind")

    local p1 = make_tcp_peer(BASE_PORT, nil)
    local p2 = make_tcp_peer(BASE_PORT, nil)
    local p3 = make_tcp_peer(BASE_PORT, nil)
    peers = { p1, p2, p3 }

    assert.is_true(
      wait_for(function()
        return #patches(p1) > 0 and #patches(p2) > 0 and #patches(p3) > 0
      end),
      "timed out — not all three peers received the broadcast"
    )

    assert.equals("three-peer", patches(p1)[1].lines[1])
    assert.equals("three-peer", patches(p2)[1].lines[1])
    assert.equals("three-peer", patches(p3)[1].lines[1])
  end)
end)

-- ── Sequential delivery ordering ─────────────────────────────────────────────
describe("Sequential message delivery", function()
  after_each(function()
    server.stop()
  end)

  it("five sequential patches from server arrive at peer in send order", function()
    local peer_id_cap = nil

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        peer_id_cap = peer_id
        server.approve(peer_id)
        for i = 1, 5 do
          server.send(peer_id, {
            t = "patch",
            path = "seq.lua",
            seq = i,
            lnum = i - 1,
            count = 0,
            lines = { "line-" .. i },
          })
        end
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 1, nil), "server failed to bind")

    local p = make_tcp_peer(BASE_PORT + 1, nil)

    assert.is_true(
      wait_for(function()
        return #patches(p) >= 5
      end),
      "timed out — peer did not receive all 5 patches"
    )

    local received = patches(p)
    for i = 1, 5 do
      assert.equals(i, received[i].seq, "patch at position " .. i .. " has wrong seq (arrival order mismatch)")
      assert.equals("line-" .. i, received[i].lines[1])
    end

    p:stop()
  end)
end)

-- ── Concurrent guest patches ──────────────────────────────────────────────────
describe("Concurrent guest patches", function()
  after_each(function()
    server.stop()
  end)

  it("patches from two concurrent guests both reach the server's on_message callback", function()
    local peer_ids = {}
    local patch_msgs = {}

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        table.insert(peer_ids, peer_id)
        server.approve(peer_id)
      elseif msg.t == "patch" then
        table.insert(patch_msgs, { peer_id = peer_id, msg = msg })
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 2, nil), "server failed to bind")

    local p1 = make_tcp_peer(BASE_PORT + 2, nil)
    local p2 = make_tcp_peer(BASE_PORT + 2, nil)

    assert.is_true(
      wait_for(function()
        return #peer_ids == 2
      end),
      "timed out waiting for both peers to connect"
    )

    p1:send({ t = "patch", path = "a.lua", lnum = 0, count = 1, lines = { "from-p1" } })
    p2:send({ t = "patch", path = "a.lua", lnum = 0, count = 1, lines = { "from-p2" } })

    assert.is_true(
      wait_for(function()
        return #patch_msgs == 2
      end),
      "timed out — server did not receive both concurrent patches"
    )

    local lines = {}
    for _, entry in ipairs(patch_msgs) do
      table.insert(lines, entry.msg.lines[1])
    end
    table.sort(lines)
    assert.same({ "from-p1", "from-p2" }, lines)

    p1:stop()
    p2:stop()
  end)

  it("three guests sending patches concurrently all reach the server", function()
    local peer_ids = {}
    local patch_msgs = {}

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        table.insert(peer_ids, peer_id)
        server.approve(peer_id)
      elseif msg.t == "patch" then
        table.insert(patch_msgs, { peer_id = peer_id, msg = msg })
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 3, nil), "server failed to bind")

    local p1 = make_tcp_peer(BASE_PORT + 3, nil)
    local p2 = make_tcp_peer(BASE_PORT + 3, nil)
    local p3 = make_tcp_peer(BASE_PORT + 3, nil)

    assert.is_true(
      wait_for(function()
        return #peer_ids == 3
      end),
      "timed out waiting for all three peers to connect"
    )

    p1:send({ t = "patch", path = "a.lua", lnum = 0, count = 1, lines = { "from-p1" } })
    p2:send({ t = "patch", path = "a.lua", lnum = 0, count = 1, lines = { "from-p2" } })
    p3:send({ t = "patch", path = "a.lua", lnum = 0, count = 1, lines = { "from-p3" } })

    assert.is_true(
      wait_for(function()
        return #patch_msgs == 3
      end),
      "timed out — server did not receive all three concurrent patches"
    )

    local lines = {}
    for _, entry in ipairs(patch_msgs) do
      table.insert(lines, entry.msg.lines[1])
    end
    table.sort(lines)
    assert.same({ "from-p1", "from-p2", "from-p3" }, lines)

    p1:stop()
    p2:stop()
    p3:stop()
  end)
end)
