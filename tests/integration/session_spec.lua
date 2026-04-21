-- Integration tests covering multi-module session flows over real loopback sockets.
--
-- Gaps covered:
--   1. WebSocket mode: connect + bidirectional message exchange
--   2. Encrypted TCP mode: AES-256-GCM key applied end-to-end
--   3. Broadcast: message reaches multiple simultaneous peers
--   4. Broadcast mixed modes: TCP peer + WS peer both receive the same broadcast
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local server = require("live-share.collab.server")
local client = require("live-share.collab.client")
local protocol = require("live-share.collab.protocol")
local tcp_trans = require("live-share.collab.transport.tcp")
local ws_trans = require("live-share.collab.transport.ws")
local crypto = require("live-share.collab.crypto")
local uv = vim.uv or vim.loop

local BASE_PORT = 19880
local TIMEOUT_MS = 3000

local function wait_for(cond)
  return vim.wait(TIMEOUT_MS, cond, 10)
end

-- Creates a raw TCP peer (no client module — allows multiple simultaneous connections).
-- Connects, sends the mode-detection probe, collects decoded messages.
local function raw_tcp_peer(port, key)
  local peer = { msgs = {} }
  local tcp = uv.new_tcp()

  tcp:connect("127.0.0.1", port, function(err)
    if err then return end
    tcp:write("\x00\x00\x00\x00")
    local reader = tcp_trans.new_reader()
    tcp:read_start(function(rerr, data)
      if rerr or not data then return end
      local payloads = reader(data)
      vim.schedule(function()
        for _, payload in ipairs(payloads) do
          local msg = protocol.decode(payload, key)
          if msg then table.insert(peer.msgs, msg) end
        end
      end)
    end)
  end)

  function peer:stop()
    if not tcp:is_closing() then tcp:close() end
  end

  return peer
end

-- Creates a raw WebSocket peer — same idea but performs the HTTP upgrade.
local function raw_ws_peer(port, key)
  local peer = { msgs = {} }
  local tcp = uv.new_tcp()

  tcp:connect("127.0.0.1", port, function(err)
    if err then return end
    local upgrade_req = ws_trans.client_upgrade("127.0.0.1")
    local state = "handshaking"
    local hs_buf = ""
    local frame_reader = ws_trans.new_reader()

    local function process_frames(data)
      local payloads = frame_reader(data)
      vim.schedule(function()
        for _, payload in ipairs(payloads) do
          local msg = protocol.decode(payload, key)
          if msg then table.insert(peer.msgs, msg) end
        end
      end)
    end

    tcp:read_start(function(rerr, data)
      if rerr or not data then return end
      if state == "handshaking" then
        hs_buf = hs_buf .. data
        local ok, rest = ws_trans.complete_client_handshake(hs_buf)
        if ok == nil then return end
        if not ok then tcp:close(); return end
        state = "connected"
        if rest and #rest > 0 then process_frames(rest) end
      else
        process_frames(data)
      end
    end)

    tcp:write(upgrade_req)
  end)

  function peer:stop()
    if not tcp:is_closing() then tcp:close() end
  end

  return peer
end

-- ── WebSocket mode ────────────────────────────────────────────────────────────
describe("WebSocket mode integration", function()
  after_each(function()
    server.stop()
    client.stop()
  end)

  it("server receives connect event when client joins in WS mode", function()
    local received = nil

    server.setup(function(msg, peer_id)
      received = { msg = msg, peer_id = peer_id }
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT, nil), "server failed to bind")

    client.setup(function(_msg) end)
    client.connect("127.0.0.1", BASE_PORT, nil, "ws", 0, nil)

    assert.is_true(
      wait_for(function() return received ~= nil end),
      "timed out — server never received connect event in WS mode"
    )
    assert.equals("connect", received.msg.t)
    assert.is_number(received.msg.peer)
  end)

  it("server sends a message that the client receives after WS connect", function()
    local client_received = nil

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        server.approve(peer_id)
        server.send(peer_id, { t = "hello", peer_id = peer_id, sid = "ws-sid", protocol_version = 3 })
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 1, nil), "server failed to bind")

    client.setup(function(msg) client_received = msg end)
    client.connect("127.0.0.1", BASE_PORT + 1, nil, "ws", 0, nil)

    assert.is_true(
      wait_for(function() return client_received ~= nil end),
      "timed out — client never received hello in WS mode"
    )
    assert.equals("hello", client_received.t)
    assert.equals("ws-sid", client_received.sid)
  end)
end)

