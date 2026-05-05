-- Stage 2 (lifecycle hardening): introduces the v3→v4 protocol bump.
--
-- Coverage:
--   1. Transport-layer ceilings — TCP and WS readers reject any frame whose
--      declared length exceeds the configured `max_bytes`, returning
--      `nil, "oversized"` *before* allocating memory.
--   2. Server-side ping/pong filtering — `ping` and `pong` are heartbeat
--      messages and must never bubble to the host's on_message handler.
--   3. Client-side ping/pong filtering plus auto-pong — `client.lua`
--      transparently answers an incoming `ping` with a matching `pong` and
--      never surfaces either message to the guest.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local server = require("live-share.collab.server")
local client = require("live-share.collab.client")
local protocol = require("live-share.collab.protocol")
local tcp_trans = require("live-share.collab.transport.tcp")
local ws_trans = require("live-share.collab.transport.ws")
local websocket = require("live-share.collab.websocket")
local uv = vim.uv or vim.loop

local BASE_PORT = 19940
local TIMEOUT_MS = 3000

local function wait_for(cond)
  return vim.wait(TIMEOUT_MS, cond, 10)
end

-- ── Transport reader ceilings ────────────────────────────────────────────────

describe("transport readers reject oversized frames", function()
  it("tcp.new_reader rejects a frame whose declared length exceeds max_bytes", function()
    local reader = tcp_trans.new_reader(100)
    -- 4-byte LE length prefix announcing 200 bytes (above the cap).
    local oversized_header = string.char(200, 0, 0, 0)
    local payloads, err = reader(oversized_header)
    assert.is_nil(payloads)
    assert.equals("oversized", err)
  end)

  it("tcp.new_reader still accepts frames at the cap", function()
    local reader = tcp_trans.new_reader(100)
    local payload = string.rep("x", 100)
    local payloads, err = reader(tcp_trans.frame(payload))
    assert.is_nil(err)
    assert.equals(1, #payloads)
    assert.equals(payload, payloads[1])
  end)

  it("ws.new_frame_reader rejects oversized binary frames", function()
    -- Build a server→client binary frame whose declared 16-bit length is 200,
    -- but cap reader at 100.  Just the 4-byte header is enough — the reader
    -- should bail before copying any payload bytes.
    local frame_header = string.char(0x82, 126, 0, 200)
    local reader = websocket.new_frame_reader(100)
    local payloads, err = reader(frame_header)
    assert.is_nil(payloads)
    assert.equals("oversized", err)
  end)

  it("ws.new_frame_reader passes through under-cap frames", function()
    local payload = string.rep("y", 50)
    local frame = ws_trans.frame(payload)
    local reader = websocket.new_frame_reader(100)
    local payloads, err = reader(frame)
    assert.is_nil(err)
    assert.equals(1, #payloads)
    assert.equals(payload, payloads[1])
  end)
end)

-- ── Server filters ping / pong out of dispatch ───────────────────────────────

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
      if not payloads then
        return
      end
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

describe("server absorbs heartbeat traffic", function()
  after_each(function()
    server.stop()
  end)

  it("never bubbles ping or pong frames to the host's on_message handler", function()
    local app_messages = {}

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        server.approve(peer_id)
      else
        table.insert(app_messages, msg.t)
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT, nil), "server failed to bind")

    local p = make_tcp_peer(BASE_PORT, nil)
    -- Wait for connect/approve cycle to settle.
    vim.wait(150)

    p:send({ t = "ping", ts = 42 })
    p:send({ t = "pong", ts = 42 })
    -- A real application message must still pass through; otherwise the test
    -- could pass simply because nothing was being dispatched at all.
    p:send({ t = "cursor", path = "a.lua", peer = 1, lnum = 0, col = 0 })

    assert.is_true(
      wait_for(function()
        for _, t in ipairs(app_messages) do
          if t == "cursor" then
            return true
          end
        end
        return false
      end),
      "cursor never reached on_message — dispatch broken"
    )

    -- After the cursor was observed, no ping or pong should have been bubbled.
    for _, t in ipairs(app_messages) do
      assert.is_not.equals("ping", t)
      assert.is_not.equals("pong", t)
    end

    p:stop()
  end)
end)

-- ── Client absorbs incoming ping and auto-replies with pong ──────────────────

-- A minimal raw-TCP server impersonator that accepts one peer, reads the
-- 4-byte detection probe, then lets the test drive write/read directly.
local function make_fake_server(port, key)
  local self = {
    received = {},
    handle = nil,
    accepted = nil,
  }
  local srv = uv.new_tcp()
  self.handle = srv
  assert(srv:bind("127.0.0.1", port))

  srv:listen(8, function()
    local conn = uv.new_tcp()
    srv:accept(conn)
    self.accepted = conn

    local detect_buf = ""
    local reader = tcp_trans.new_reader()
    conn:read_start(function(err, data)
      if err or not data then
        return
      end
      if #detect_buf < 4 then
        detect_buf = detect_buf .. data
        if #detect_buf < 4 then
          return
        end
        data = detect_buf:sub(5)
        if #data == 0 then
          return
        end
      end
      local payloads = reader(data)
      if not payloads then
        return
      end
      vim.schedule(function()
        for _, payload in ipairs(payloads) do
          local msg = protocol.decode(payload, key)
          if msg then
            table.insert(self.received, msg)
          end
        end
      end)
    end)
  end)

  function self:send(msg)
    if self.accepted and not self.accepted:is_closing() then
      self.accepted:write(tcp_trans.frame(protocol.encode(msg, key)))
    end
  end

  function self:stop()
    if self.accepted and not self.accepted:is_closing() then
      self.accepted:close()
    end
    if not srv:is_closing() then
      srv:close()
    end
  end

  return self
end

describe("client absorbs heartbeat traffic", function()
  after_each(function()
    client.stop()
  end)

  it("auto-replies to ping with a matching pong without bubbling either to on_message", function()
    local fake = make_fake_server(BASE_PORT + 1, nil)
    local guest_messages = {}

    client.setup(function(msg)
      table.insert(guest_messages, msg)
    end)
    client.connect("127.0.0.1", BASE_PORT + 1, nil, "tcp", 0, nil)

    -- Wait for the client's detection probe to land.
    assert.is_true(
      wait_for(function()
        return fake.accepted ~= nil
      end),
      "client never connected to the fake server"
    )
    -- Give the client a moment to wire up its reader.
    vim.wait(100)

    -- Fire a ping — expect a pong back on the wire.
    fake:send({ t = "ping", ts = 1234 })

    assert.is_true(
      wait_for(function()
        for _, m in ipairs(fake.received) do
          if m.t == "pong" and m.ts == 1234 then
            return true
          end
        end
        return false
      end),
      "client never sent a pong in response to ping"
    )

    -- Send a regular application message; the client must still surface it.
    fake:send({ t = "hello", peer_id = 1, sid = "s", protocol_version = protocol.VERSION })

    assert.is_true(
      wait_for(function()
        for _, m in ipairs(guest_messages) do
          if m.t == "hello" then
            return true
          end
        end
        return false
      end),
      "hello never reached the guest handler — dispatch broken"
    )

    -- Among the bubbled messages there must be no ping or pong.
    for _, m in ipairs(guest_messages) do
      assert.is_not.equals("ping", m.t)
      assert.is_not.equals("pong", m.t)
    end

    fake:stop()
  end)
end)
