-- Unit tests for lua/live-share/collab/transport/tcp.lua
-- and the framing helpers in lua/live-share/collab/transport/ws.lua
-- Run with: nvim --headless -u tests/minimal_init.lua \
--             -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local tcp = require("live-share.collab.transport.tcp")
local ws_transport = require("live-share.collab.transport.ws")
local ws = require("live-share.collab.websocket")

describe("transport.tcp", function()
  describe("frame", function()
    it("prepends a 4-byte little-endian length prefix", function()
      local payload = "hello"
      local framed = tcp.frame(payload)
      -- 4 bytes header + 5 bytes payload = 9 bytes
      assert.equals(9, #framed)
      -- Length field: 5 encoded as LE uint32
      assert.equals(5, framed:byte(1))
      assert.equals(0, framed:byte(2))
      assert.equals(0, framed:byte(3))
      assert.equals(0, framed:byte(4))
    end)

    it("encodes a 256-byte payload length correctly", function()
      local payload = string.rep("x", 256)
      local framed = tcp.frame(payload)
      assert.equals(0, framed:byte(1))
      assert.equals(1, framed:byte(2))
      assert.equals(0, framed:byte(3))
      assert.equals(0, framed:byte(4))
    end)

    it("payload is preserved verbatim after the header", function()
      local payload = "binary\x00\xff\x01"
      local framed = tcp.frame(payload)
      assert.equals(payload, framed:sub(5))
    end)
  end)

  describe("new_reader", function()
    it("round-trips a single message", function()
      local reader = tcp.new_reader()
      local payloads = reader(tcp.frame("hello"))
      assert.equals(1, #payloads)
      assert.equals("hello", payloads[1])
    end)

    it("round-trips multiple messages in one chunk", function()
      local chunk = tcp.frame("foo") .. tcp.frame("bar") .. tcp.frame("baz")
      local reader = tcp.new_reader()
      local payloads = reader(chunk)
      assert.equals(3, #payloads)
      assert.equals("foo", payloads[1])
      assert.equals("bar", payloads[2])
      assert.equals("baz", payloads[3])
    end)

    it("reassembles a message split across two chunks", function()
      local framed = tcp.frame("split")
      local reader = tcp.new_reader()
      local mid = math.floor(#framed / 2)
      local p1 = reader(framed:sub(1, mid))
      assert.equals(0, #p1)
      local p2 = reader(framed:sub(mid + 1))
      assert.equals(1, #p2)
      assert.equals("split", p2[1])
    end)

    it("reassembles a message delivered one byte at a time", function()
      local framed = tcp.frame("incremental")
      local reader = tcp.new_reader()
      local all = {}
      for i = 1, #framed do
        local got = reader(framed:sub(i, i))
        for _, p in ipairs(got) do
          table.insert(all, p)
        end
      end
      assert.equals(1, #all)
      assert.equals("incremental", all[1])
    end)

    it("returns empty table when chunk is incomplete", function()
      local framed = tcp.frame("pending")
      local reader = tcp.new_reader()
      -- just the header, no payload
      local partial = framed:sub(1, 4)
      assert.equals(0, #reader(partial))
    end)

    it("round-trips an empty payload", function()
      local reader = tcp.new_reader()
      local payloads = reader(tcp.frame(""))
      assert.equals(1, #payloads)
      assert.equals("", payloads[1])
    end)

    it("round-trips binary data", function()
      local payload = ""
      for i = 0, 255 do
        payload = payload .. string.char(i)
      end
      local reader = tcp.new_reader()
      local payloads = reader(tcp.frame(payload))
      assert.equals(1, #payloads)
      assert.equals(payload, payloads[1])
    end)
  end)
end)

describe("transport.ws (framing layer)", function()
  describe("frame (server→client, unmasked)", function()
    it("round-trips through websocket frame reader", function()
      local frame = ws_transport.frame("server message")
      local reader = ws.new_frame_reader()
      local payloads = reader(frame)
      assert.equals(1, #payloads)
      assert.equals("server message", payloads[1])
    end)

    it("produces an unmasked frame (mask bit not set)", function()
      local frame = ws_transport.frame("test")
      -- byte 2: mask bit is 0x80; if unmasked, byte 2 = payload length only
      local b2 = frame:byte(2)
      assert.equals(0, b2 % 256 >= 128 and 1 or 0)
    end)
  end)

  describe("frame_client (client→server, masked)", function()
    it("round-trips through websocket frame reader", function()
      local frame = ws_transport.frame_client("client message")
      local reader = ws.new_frame_reader()
      local payloads = reader(frame)
      assert.equals(1, #payloads)
      assert.equals("client message", payloads[1])
    end)

    it("produces a masked frame (mask bit set)", function()
      local frame = ws_transport.frame_client("test")
      local b2 = frame:byte(2)
      assert.equals(1, b2 >= 128 and 1 or 0)
    end)

    it("is larger than the unmasked equivalent (4 mask bytes)", function()
      local payload = "compare"
      local unmasked = ws_transport.frame(payload)
      local masked = ws_transport.frame_client(payload)
      assert.equals(#unmasked + 4, #masked)
    end)
  end)
end)
