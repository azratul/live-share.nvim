-- Regression tests for the WORKSPACE_SYNC watchdog (#25): the guest must tell a slow
-- link (1 MB took 27-31 s over bore.pub) from a dead one. See PROTOCOL.md §8.
local uv = vim.uv or vim.loop
local client = require("live-share.collab.client")
local connection = require("live-share.collab.connection")

local PORT = 19891
local TIMEOUT_MS = 3000

local function wait_for(cond)
  return vim.wait(TIMEOUT_MS, cond, 10)
end

describe("transport activity signal", function()
  local srv = nil

  after_each(function()
    client.stop()
    if srv and not srv:is_closing() then
      srv:close()
    end
    srv = nil
  end)

  it("fires for inbound bytes that do not complete a message", function()
    srv = uv.new_tcp()
    assert.is_true(srv:bind("127.0.0.1", PORT) ~= nil, "bind failed")
    srv:listen(16, function()
      local c = uv.new_tcp()
      srv:accept(c)
      -- A 1 MB length prefix then a sliver of it: the shape of a large snapshot
      -- mid-flight, where the reader can deliver nothing until the last byte lands.
      c:write(string.char(0, 0, 16, 0) .. string.rep("x", 64))
    end)

    local activity, delivered = 0, 0
    client.setup(function()
      delivered = delivered + 1
    end, function()
      activity = activity + 1
    end)
    client.connect("127.0.0.1", PORT, nil, "tcp", 0, nil)

    assert.is_true(
      wait_for(function()
        return activity > 0
      end),
      "on_activity never fired — a slow snapshot would look identical to a dead link"
    )
    assert.equals(0, delivered)
  end)

  it("is optional — a caller that passes no on_activity still receives messages", function()
    local server = require("live-share.collab.server")
    local got = nil
    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        server.approve(peer_id)
        server.send(peer_id, { t = "hello", peer_id = peer_id, sid = "sid", protocol_version = 3 })
      end
    end)
    assert.is_true(server.start("127.0.0.1", PORT + 1, nil), "server failed to bind")

    client.setup(function(msg)
      got = msg
    end)
    client.connect("127.0.0.1", PORT + 1, nil, "tcp", 0, nil)

    assert.is_true(
      wait_for(function()
        return got ~= nil
      end),
      "client never received hello"
    )
    assert.equals("hello", got.t)
    server.stop()
  end)
end)

describe("connector wiring", function()
  it("new_connector forwards on_activity to the transport", function()
    local orig = client.setup
    local seen = nil
    client.setup = function(_on_msg, on_act)
      seen = on_act
    end
    local cb = function() end
    local ok, err = pcall(connection.new_connector, {
      on_msg = function() end,
      on_activity = cb,
    })
    client.setup = orig
    assert.is_true(ok, tostring(err))
    assert.equals(cb, seen)
  end)
end)
