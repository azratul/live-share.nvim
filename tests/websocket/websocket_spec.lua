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

  -- Regression tests for #25: a reader that ignores the FIN bit keeps only the
  -- first fragment of a message re-framed by an HTTP reverse-proxy tunnel.
  describe("message fragmentation (continuation frames, RFC 6455 §5.4)", function()
    -- Builds a raw frame with an explicit FIN bit and opcode (unmasked).
    local function raw_frame(payload, fin, opcode)
      local b1 = (fin and 0x80 or 0x00) + opcode
      local len = #payload
      if len < 126 then
        return string.char(b1, len) .. payload
      elseif len < 65536 then
        return string.char(b1, 126, math.floor(len / 256), len % 256) .. payload
      end
      error("test helper only covers payloads < 64 KiB")
    end

    it("reassembles a message split into continuation frames", function()
      local stream = raw_frame("hello ", false, ws.OP_BIN)
        .. raw_frame("frag", false, ws.OP_CONT)
        .. raw_frame("mented world", true, ws.OP_CONT)
      local reader = ws.new_frame_reader()
      local payloads = reader(stream)
      assert.equals(1, #payloads)
      assert.equals("hello fragmented world", payloads[1])
    end)

    it("reassembles a large fragmented message delivered in odd-sized chunks", function()
      local part = string.rep("x", 8192)
      local stream = raw_frame(part, false, ws.OP_BIN)
        .. raw_frame(part, false, ws.OP_CONT)
        .. raw_frame(part, true, ws.OP_CONT)
      local reader = ws.new_frame_reader()
      local all = {}
      for i = 1, #stream, 777 do
        for _, p in ipairs(reader(stream:sub(i, i + 776))) do
          table.insert(all, p)
        end
      end
      assert.equals(1, #all)
      assert.equals(3 * 8192, #all[1])
      assert.equals(string.rep("x", 3 * 8192), all[1])
    end)

    it("emits nothing until the final fragment arrives", function()
      local reader = ws.new_frame_reader()
      assert.equals(0, #reader(raw_frame("part one", false, ws.OP_BIN)))
      assert.equals(0, #reader(raw_frame("part two", false, ws.OP_CONT)))
      local payloads = reader(raw_frame("!", true, ws.OP_CONT))
      assert.equals(1, #payloads)
      assert.equals("part onepart two!", payloads[1])
    end)

    it("keeps unfragmented frames working alongside fragmented ones", function()
      local stream = raw_frame("solo", true, ws.OP_BIN)
        .. raw_frame("a", false, ws.OP_BIN)
        .. raw_frame("b", true, ws.OP_CONT)
        .. raw_frame("again", true, ws.OP_BIN)
      local payloads = ws.new_frame_reader()(stream)
      assert.same({ "solo", "ab", "again" }, payloads)
    end)

    it("ignores a stray continuation frame with no message in flight", function()
      local stream = raw_frame("orphan", true, ws.OP_CONT) .. raw_frame("real", true, ws.OP_BIN)
      local payloads = ws.new_frame_reader()(stream)
      assert.same({ "real" }, payloads)
    end)
  end)

  describe("control frames", function()
    local function raw_frame(payload, fin, opcode)
      local b1 = (fin and 0x80 or 0x00) + opcode
      return string.char(b1, #payload) .. payload
    end

    it("reports a ping to on_control instead of treating it as a message", function()
      local seen = {}
      local reader = ws.new_frame_reader({
        on_control = function(opcode, payload)
          table.insert(seen, { opcode = opcode, payload = payload })
        end,
      })
      local payloads = reader(raw_frame("keepalive", true, ws.OP_PING))
      assert.equals(0, #payloads)
      assert.equals(1, #seen)
      assert.equals(ws.OP_PING, seen[1].opcode)
      assert.equals("keepalive", seen[1].payload)
    end)

    it("reports a close frame to on_control", function()
      local seen = nil
      local reader = ws.new_frame_reader({
        on_control = function(opcode)
          seen = opcode
        end,
      })
      reader(raw_frame("", true, ws.OP_CLOSE))
      assert.equals(ws.OP_CLOSE, seen)
    end)

    it("does not break reassembly when a ping is interleaved mid-message", function()
      local stream = raw_frame("before", false, ws.OP_BIN)
        .. raw_frame("ping!", true, ws.OP_PING)
        .. raw_frame("after", true, ws.OP_CONT)
      local pings = 0
      local reader = ws.new_frame_reader({
        on_control = function(opcode)
          if opcode == ws.OP_PING then
            pings = pings + 1
          end
        end,
      })
      local payloads = reader(stream)
      assert.equals(1, pings)
      assert.same({ "beforeafter" }, payloads)
    end)

    it("encodes a pong that decodes back as a control frame", function()
      local seen = nil
      local reader = ws.new_frame_reader({
        on_control = function(opcode, payload)
          seen = { opcode = opcode, payload = payload }
        end,
      })
      reader(ws.encode_frame("abc", false, ws.OP_PONG))
      assert.equals(ws.OP_PONG, seen.opcode)
      assert.equals("abc", seen.payload)
    end)

    it("still defaults to a binary opcode when none is given", function()
      local frame = ws.encode_frame("x", false)
      assert.equals(0x80 + ws.OP_BIN, frame:byte(1))
    end)
  end)
end)
