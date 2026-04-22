-- Integration tests for networking edge cases at the server/client layer.
--
-- Gaps covered:
--   1. Abrupt disconnect fires a synthesized "bye" event with the peer's name
--   2. Synthesized bye is broadcast to remaining peers on abrupt disconnect (§7.3)
--   3. Read-only guest sending a patch receives an "unauthorized" error (§5.4)
--   4. server.reject() delivers a rejection message before closing the connection
--   5. broadcast(msg, except_peer) — the excluded peer does not receive the message
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local server = require("live-share.collab.server")
local protocol = require("live-share.collab.protocol")
local tcp_trans = require("live-share.collab.transport.tcp")
local uv = vim.uv or vim.loop

local BASE_PORT = 19890
local TIMEOUT_MS = 3000

local function wait_for(cond)
  return vim.wait(TIMEOUT_MS, cond, 10)
end

-- Raw TCP peer with send capability.
-- Connects, sends the mode-detection probe, collects decoded messages.
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

local function find_msg(msgs, pred)
  for _, m in ipairs(msgs) do
    if pred(m) then
      return m
    end
  end
  return nil
end

-- ── Abrupt disconnect ─────────────────────────────────────────────────────────
describe("Abrupt disconnect", function()
  after_each(function()
    server.stop()
  end)

  it("fires a synthesized bye event with the disconnecting peer's name", function()
    local events = {}
    local peer_ids = {}

    server.setup(function(msg, peer_id)
      table.insert(events, { msg = msg, peer_id = peer_id })
      if msg.t == "connect" then
        table.insert(peer_ids, peer_id)
        server.approve(peer_id)
        if #peer_ids == 1 then
          server.set_name(peer_id, "alice")
        end
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT, nil), "server failed to bind")

    local p1 = make_tcp_peer(BASE_PORT, nil)
    local p2 = make_tcp_peer(BASE_PORT, nil)

    assert.is_true(
      wait_for(function()
        return #peer_ids == 2
      end),
      "timed out waiting for both peers to connect"
    )

    local victim_id = peer_ids[1]
    p1:stop()

    assert.is_true(
      wait_for(function()
        return find_msg(events, function(e)
          return e.msg.t == "bye" and e.msg.peer == victim_id
        end) ~= nil
      end),
      "timed out — server never fired a bye event for the disconnected peer"
    )

    local bye_event = find_msg(events, function(e)
      return e.msg.t == "bye" and e.msg.peer == victim_id
    end)
    assert.equals("alice", bye_event.msg.name)

    p2:stop()
  end)

  it("synthesized bye is broadcast to remaining peers (§7.3)", function()
    local peer_ids = {}

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        table.insert(peer_ids, peer_id)
        server.approve(peer_id)
        if #peer_ids == 1 then
          server.set_name(peer_id, "bob")
        end
      elseif msg.t == "bye" then
        server.broadcast({ t = "bye", peer = msg.peer, name = msg.name })
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 1, nil), "server failed to bind")

    local p1 = make_tcp_peer(BASE_PORT + 1, nil)
    local p2 = make_tcp_peer(BASE_PORT + 1, nil)

    assert.is_true(
      wait_for(function()
        return #peer_ids == 2
      end),
      "timed out waiting for both peers to connect"
    )

    p1:stop()

    assert.is_true(
      wait_for(function()
        return find_msg(p2.msgs, function(m)
          return m.t == "bye" and m.name == "bob"
        end) ~= nil
      end),
      "timed out — witness peer never received the synthesized bye broadcast"
    )

    assert.equals("bob", find_msg(p2.msgs, function(m)
      return m.t == "bye"
    end).name)

    p2:stop()
  end)
end)

-- ── Role enforcement ──────────────────────────────────────────────────────────
describe("Read-only role enforcement", function()
  after_each(function()
    server.stop()
  end)

  it("read-only guest sending a patch receives an unauthorized error (§5.4)", function()
    local peer_id_cap = nil

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        peer_id_cap = peer_id
        server.approve(peer_id)
        server.set_role(peer_id, "ro")
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 2, nil), "server failed to bind")

    local p = make_tcp_peer(BASE_PORT + 2, nil)

    assert.is_true(
      wait_for(function()
        return peer_id_cap ~= nil
      end),
      "timed out waiting for connect"
    )

    p:send({ t = "patch", path = "a.lua", lnum = 0, count = 1, lines = { "x" } })

    assert.is_true(
      wait_for(function()
        return find_msg(p.msgs, function(m)
          return m.t == "error" and m.code == "unauthorized"
        end) ~= nil
      end),
      "timed out — read-only guest never received an unauthorized error after sending a patch"
    )

    p:stop()
  end)
end)

-- ── Reject flow ───────────────────────────────────────────────────────────────
describe("Connection rejection", function()
  after_each(function()
    server.stop()
  end)

  it("server.reject() delivers a rejected message before closing the connection", function()
    local peer_id_cap = nil

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        peer_id_cap = peer_id
        server.reject(peer_id, { t = "rejected", reason = "test: access denied" })
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 3, nil), "server failed to bind")

    local p = make_tcp_peer(BASE_PORT + 3, nil)

    assert.is_true(
      wait_for(function()
        return peer_id_cap ~= nil
      end),
      "timed out waiting for connect"
    )

    assert.is_true(
      wait_for(function()
        return find_msg(p.msgs, function(m)
          return m.t == "rejected"
        end) ~= nil
      end),
      "timed out — client never received the rejected message"
    )

    local rej = find_msg(p.msgs, function(m)
      return m.t == "rejected"
    end)
    assert.equals("test: access denied", rej.reason)

    p:stop()
  end)
end)

-- ── Broadcast except_peer ─────────────────────────────────────────────────────
describe("Broadcast except_peer exclusion", function()
  after_each(function()
    server.stop()
  end)

  it("excluded peer does not receive a broadcast sent with its peer_id as except_peer", function()
    local peer_ids = {}
    local connected = 0

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        connected = connected + 1
        table.insert(peer_ids, peer_id)
        server.approve(peer_id)
        if connected == 2 then
          server.broadcast(
            { t = "patch", path = "x.lua", lnum = 0, count = 0, lines = { "exclusive" } },
            peer_ids[1]
          )
        end
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 4, nil), "server failed to bind")

    local p1 = make_tcp_peer(BASE_PORT + 4, nil)
    local p2 = make_tcp_peer(BASE_PORT + 4, nil)

    local function got_patch(peer)
      return find_msg(peer.msgs, function(m)
        return m.t == "patch"
      end) ~= nil
    end

    assert.is_true(
      wait_for(function()
        return got_patch(p2)
      end),
      "timed out — included peer never received the broadcast"
    )

    assert.equals("exclusive", p2.msgs[#p2.msgs].lines[1])
    assert.is_false(got_patch(p1), "excluded peer must not receive a broadcast sent with its peer_id as except_peer")

    p1:stop()
    p2:stop()
  end)
end)
