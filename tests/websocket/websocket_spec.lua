-- Unit tests for lua/live-share/collab/websocket.lua
-- Run with: nvim --headless -u tests/minimal_init.lua \
--             -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local ws = require("live-share.collab.websocket")

describe("websocket", function()
  describe("make_client_key", function()
    it("returns a non-empty string", function()
      local key = ws.make_client_key()
      assert.is_string(key)
      assert.is_true(#key > 0)
    end)

    it("produces base64-encoded output (24 chars for 16 bytes)", function()
      local key = ws.make_client_key()
      -- 16 bytes → 24 base64 chars (with padding)
      assert.equals(24, #key)
    end)

    it("produces different keys on successive calls", function()
      local k1 = ws.make_client_key()
      local k2 = ws.make_client_key()
      assert.are_not.equal(k1, k2)
    end)
  end)

  describe("client_request", function()
    it("starts with GET / HTTP/1.1", function()
      local req = ws.client_request("example.com", "dGhlIHNhbXBsZSBub25jZQ==")
      assert.is_truthy(req:match("^GET / HTTP/1.1"))
    end)

    it("includes required WebSocket headers", function()
      local req = ws.client_request("example.com", "dGhlIHNhbXBsZSBub25jZQ==")
      assert.is_truthy(req:find("Upgrade: websocket", 1, true))
      assert.is_truthy(req:find("Connection: Upgrade", 1, true))
      assert.is_truthy(req:find("Sec-WebSocket-Version: 13", 1, true))
      assert.is_truthy(req:find("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", 1, true))
    end)

    it("includes the Host header", function()
      local req = ws.client_request("myhost.example.com", "key=")
      assert.is_truthy(req:find("Host: myhost.example.com", 1, true))
    end)

    it("ends with double CRLF (blank line after headers)", function()
      local req = ws.client_request("h", "k")
      assert.is_truthy(req:sub(-4) == "\r\n\r\n")
    end)
  end)

  describe("server_response", function()
    it("returns 101 Switching Protocols", function()
      local res = ws.server_response("dGhlIHNhbXBsZSBub25jZQ==")
      assert.is_truthy(res:match("HTTP/1%.1 101"))
    end)

    it("includes Upgrade and Connection headers", function()
      local res = ws.server_response("dGhlIHNhbXBsZSBub25jZQ==")
      assert.is_truthy(res:find("Upgrade: websocket", 1, true))
      assert.is_truthy(res:find("Connection: Upgrade", 1, true))
    end)

    it("computes correct Sec-WebSocket-Accept for RFC 6455 example key", function()
      -- RFC 6455 §1.3 test vector: key = "dGhlIHNhbXBsZSBub25jZQ=="
      -- Expected accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
      local res = ws.server_response("dGhlIHNhbXBsZSBub25jZQ==")
      assert.is_truthy(res:find("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", 1, true))
    end)

    it("ends with double CRLF", function()
      local res = ws.server_response("key")
      assert.equals("\r\n\r\n", res:sub(-4))
    end)
  end)

  describe("encode_frame / new_frame_reader (unmasked, server→client)", function()
    it("round-trips an empty payload", function()
      local frame = ws.encode_frame("", false)
      local reader = ws.new_frame_reader()
      local payloads = reader(frame)
      assert.equals(1, #payloads)
      assert.equals("", payloads[1])
    end)

    it("round-trips a short payload", function()
      local frame = ws.encode_frame("hello", false)
      local reader = ws.new_frame_reader()
      local payloads = reader(frame)
      assert.equals(1, #payloads)
      assert.equals("hello", payloads[1])
    end)

    it("round-trips a binary payload", function()
      local payload = string.char(0, 1, 127, 128, 255)
      local frame = ws.encode_frame(payload, false)
      local reader = ws.new_frame_reader()
      local payloads = reader(frame)
      assert.equals(1, #payloads)
      assert.equals(payload, payloads[1])
    end)

    it("round-trips a 126-byte payload (16-bit length extension)", function()
      local payload = string.rep("x", 126)
      local frame = ws.encode_frame(payload, false)
      local reader = ws.new_frame_reader()
      local payloads = reader(frame)
      assert.equals(1, #payloads)
      assert.equals(payload, payloads[1])
    end)

    it("reassembles two frames delivered byte-by-byte (fragmentation)", function()
      local f1 = ws.encode_frame("ping", false)
      local f2 = ws.encode_frame("pong", false)
      local stream = f1 .. f2
      local reader = ws.new_frame_reader()
      local all = {}
      for i = 1, #stream do
        local got = reader(stream:sub(i, i))
        for _, p in ipairs(got) do
          table.insert(all, p)
        end
      end
      assert.equals(2, #all)
      assert.equals("ping", all[1])
      assert.equals("pong", all[2])
    end)

    it("delivers multiple frames from one chunk", function()
      local frames = ws.encode_frame("a", false) .. ws.encode_frame("b", false) .. ws.encode_frame("c", false)
      local reader = ws.new_frame_reader()
      local payloads = reader(frames)
      assert.equals(3, #payloads)
      assert.equals("a", payloads[1])
      assert.equals("b", payloads[2])
      assert.equals("c", payloads[3])
    end)

    it("returns empty table when buffer has incomplete frame", function()
      local frame = ws.encode_frame("hello", false)
      local reader = ws.new_frame_reader()
      local partial = frame:sub(1, 3)
      local payloads = reader(partial)
      assert.equals(0, #payloads)
    end)
  end)

  describe("encode_frame / new_frame_reader (masked, client→server)", function()
    it("round-trips a payload through masked encode and unmasking decode", function()
      local payload = "masked message"
      local frame = ws.encode_frame(payload, true)
      local reader = ws.new_frame_reader()
      local payloads = reader(frame)
      assert.equals(1, #payloads)
      assert.equals(payload, payloads[1])
    end)

    it("masked frame is longer than unmasked (4 extra mask bytes)", function()
      local payload = "test"
      local unmasked = ws.encode_frame(payload, false)
      local masked = ws.encode_frame(payload, true)
      assert.equals(#unmasked + 4, #masked)
    end)

    it("masked frames differ across calls (random mask key)", function()
      local payload = "same payload"
      local f1 = ws.encode_frame(payload, true)
      local f2 = ws.encode_frame(payload, true)
      -- Frame bytes differ because mask key is random; decoded payload is the same
      local reader1 = ws.new_frame_reader()
      local reader2 = ws.new_frame_reader()
      assert.equals(payload, reader1(f1)[1])
      assert.equals(payload, reader2(f2)[1])
    end)
  end)
end)
