-- Unit tests for lua/live-share/collab/protocol.lua
-- Run with: nvim --headless -u tests/minimal_init.lua \
--             -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local protocol = require("live-share.collab.protocol")

describe("protocol", function()
  describe("VERSION", function()
    it("is a positive integer", function()
      assert.is_number(protocol.VERSION)
      assert.is_true(protocol.VERSION >= 1)
    end)
  end)

  describe("encode / decode (plaintext)", function()
    it("round-trips a simple message", function()
      local msg = { t = "patch", path = "foo.lua", lnum = 0, count = 1, lines = { "hello" } }
      local payload = protocol.encode(msg, nil)
      assert.is_string(payload)
      local decoded = protocol.decode(payload, nil)
      assert.are.same(msg, decoded)
    end)

    it("encodes to valid JSON", function()
      local msg = { t = "hello", peer_id = 1, sid = "abc" }
      local payload = protocol.encode(msg, nil)
      local ok, result = pcall(vim.json.decode, payload)
      assert.is_true(ok)
      assert.equals("hello", result.t)
    end)

    it("decode returns nil for malformed input", function()
      assert.is_nil(protocol.decode("not json at all {{{{", nil))
    end)

    it("decode returns nil for empty string", function()
      assert.is_nil(protocol.decode("", nil))
    end)

    it("decode returns nil when payload is not a table", function()
      assert.is_nil(protocol.decode('"just a string"', nil))
    end)

    it("round-trips a cursor message", function()
      local msg = { t = "cursor", path = "init.lua", peer = 2, lnum = 10, col = 5, name = "alice" }
      assert.are.same(msg, protocol.decode(protocol.encode(msg, nil), nil))
    end)

    it("round-trips a bye message", function()
      local msg = { t = "bye", peer = 3, name = "bob" }
      assert.are.same(msg, protocol.decode(protocol.encode(msg, nil), nil))
    end)

    it("round-trips a terminal_data message with binary-safe content", function()
      local msg = { t = "terminal_data", term_id = 1, data = "ls -la\r\n" }
      assert.are.same(msg, protocol.decode(protocol.encode(msg, nil), nil))
    end)

    it("preserves unicode content", function()
      local msg = { t = "patch", path = "x.lua", lines = { "-- こんにちは", "print('世界')" } }
      assert.are.same(msg, protocol.decode(protocol.encode(msg, nil), nil))
    end)
  end)

  describe("encode / decode (encrypted)", function()
    local crypto = require("live-share.collab.crypto")

    if not crypto.available then
      pending("OpenSSL not available — skipping encrypted tests")
      return
    end

    it("round-trips with a 32-byte key", function()
      local key = crypto.random_bytes(32)
      local msg = { t = "patch", path = "main.lua", lnum = 3, count = 1, lines = { "x = 1" } }
      local payload = protocol.encode(msg, key)
      -- Encrypted payload is binary, not valid JSON.
      assert.is_false(pcall(vim.json.decode, payload))
      assert.are.same(msg, protocol.decode(payload, key))
    end)

    it("returns nil when decrypted with the wrong key", function()
      local key1 = crypto.random_bytes(32)
      local key2 = crypto.random_bytes(32)
      local msg = { t = "cursor", lnum = 0, col = 0 }
      local payload = protocol.encode(msg, key1)
      assert.is_nil(protocol.decode(payload, key2))
    end)

    it("returns nil when payload is too short to contain a nonce", function()
      local key = crypto.random_bytes(32)
      assert.is_nil(protocol.decode("short", key))
    end)

    it("produces different ciphertext each call (fresh nonce)", function()
      local key = crypto.random_bytes(32)
      local msg = { t = "hello", peer_id = 1 }
      local p1 = protocol.encode(msg, key)
      local p2 = protocol.encode(msg, key)
      assert.are_not.equal(p1, p2)
    end)
  end)
end)
