-- Integration tests: server + client over a real loopback socket.
--
-- These tests catch interaction bugs that unit tests can't see, such as the
-- TCP mode-detection deadlock where both sides waited for the other to write
-- first and the connection silently hung.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local server = require("live-share.collab.server")
local client = require("live-share.collab.client")

local PORT = 19877
local TIMEOUT_MS = 3000

local function wait_for(cond)
  return vim.wait(TIMEOUT_MS, cond, 10)
end

describe("TCP mode integration", function()
  after_each(function()
    server.stop()
    client.stop()
  end)

  it("server receives connect event when client joins in TCP mode", function()
    local received = nil

    server.setup(function(msg, peer_id)
      received = { msg = msg, peer_id = peer_id }
    end)
    assert.is_true(server.start("127.0.0.1", PORT, nil), "server failed to bind")

    client.setup(function(_msg) end)
    client.connect("127.0.0.1", PORT, nil, "tcp", 0, nil)

    assert.is_true(
      wait_for(function() return received ~= nil end),
      "timed out — server never received connect event (TCP mode deadlock?)"
    )
    assert.equals("connect", received.msg.t)
    assert.is_number(received.msg.peer)
  end)

  it("server can send a message to the peer after TCP connect", function()
    local server_received = nil
    local client_received = nil

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        server_received = peer_id
        server.approve(peer_id)
        server.send(peer_id, { t = "hello", peer_id = peer_id, sid = "test-sid", protocol_version = 3 })
      end
    end)
    assert.is_true(server.start("127.0.0.1", PORT + 1, nil), "server failed to bind")

    client.setup(function(msg)
      client_received = msg
    end)
    client.connect("127.0.0.1", PORT + 1, nil, "tcp", 0, nil)

    assert.is_true(
      wait_for(function() return client_received ~= nil end),
      "timed out — client never received hello from server"
    )
    assert.equals("hello", client_received.t)
    assert.equals("test-sid", client_received.sid)
  end)
end)
