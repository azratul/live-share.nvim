-- Unit tests for lua/live-share/collab/crypto.lua
-- Run with: nvim --headless -u tests/minimal_init.lua \
--             -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local crypto = require("live-share.collab.crypto")

describe("crypto", function()
  describe("availability flag", function()
    it("M.available is a boolean", function()
      assert.is_boolean(crypto.available)
    end)
  end)

  if not crypto.available then
    pending("OpenSSL not available — skipping all crypto tests")
    return
  end

  describe("random_bytes", function()
    it("returns a string of the requested length", function()
      for _, n in ipairs({ 1, 12, 16, 32 }) do
        local b = crypto.random_bytes(n)
        assert.is_string(b)
        assert.equals(n, #b)
      end
    end)

    it("produces different output on successive calls", function()
      local a = crypto.random_bytes(32)
      local b = crypto.random_bytes(32)
      assert.are_not.equal(a, b)
    end)
  end)

  describe("generate_key", function()
    it("returns a 32-byte string", function()
      local k = crypto.generate_key()
      assert.is_string(k)
      assert.equals(32, #k)
    end)

    it("produces different keys on successive calls", function()
      local k1 = crypto.generate_key()
      local k2 = crypto.generate_key()
      assert.are_not.equal(k1, k2)
    end)
  end)

  describe("encrypt / decrypt", function()
    it("round-trips plaintext", function()
      local key = crypto.generate_key()
      local nonce = crypto.random_bytes(12)
      local plaintext = "hello, world"
      local ciphertext = crypto.encrypt(plaintext, key, nonce)
      assert.is_string(ciphertext)
      local decrypted = crypto.decrypt(ciphertext, key, nonce)
      assert.equals(plaintext, decrypted)
    end)

    it("produces ciphertext longer than plaintext (appends 16-byte GCM tag)", function()
      local key = crypto.generate_key()
      local nonce = crypto.random_bytes(12)
      local plaintext = "test"
      local ct = crypto.encrypt(plaintext, key, nonce)
      assert.equals(#plaintext + 16, #ct)
    end)

    it("returns nil when decrypting with the wrong key", function()
      local key1 = crypto.generate_key()
      local key2 = crypto.generate_key()
      local nonce = crypto.random_bytes(12)
      local ct = crypto.encrypt("secret", key1, nonce)
      assert.is_nil(crypto.decrypt(ct, key2, nonce))
    end)

    it("returns nil when decrypting with the wrong nonce", function()
      local key = crypto.generate_key()
      local nonce1 = crypto.random_bytes(12)
      local nonce2 = crypto.random_bytes(12)
      local ct = crypto.encrypt("secret", key, nonce1)
      assert.is_nil(crypto.decrypt(ct, key, nonce2))
    end)

    it("returns nil when ciphertext is tampered", function()
      local key = crypto.generate_key()
      local nonce = crypto.random_bytes(12)
      local ct = crypto.encrypt("original", key, nonce)
      -- Flip one byte in the ciphertext body
      local tampered = ct:sub(1, 1) .. string.char((ct:byte(2) + 1) % 256) .. ct:sub(3)
      assert.is_nil(crypto.decrypt(tampered, key, nonce))
    end)

    it("returns nil for payload shorter than the 16-byte GCM tag", function()
      local key = crypto.generate_key()
      local nonce = crypto.random_bytes(12)
      assert.is_nil(crypto.decrypt(string.rep("\x00", 10), key, nonce))
    end)

    it("round-trips empty plaintext", function()
      local key = crypto.generate_key()
      local nonce = crypto.random_bytes(12)
      local ct = crypto.encrypt("", key, nonce)
      assert.equals("", crypto.decrypt(ct, key, nonce))
    end)

    it("round-trips binary data (all byte values)", function()
      local plaintext = ""
      for i = 0, 255 do
        plaintext = plaintext .. string.char(i)
      end
      local key = crypto.generate_key()
      local nonce = crypto.random_bytes(12)
      local ct = crypto.encrypt(plaintext, key, nonce)
      assert.equals(plaintext, crypto.decrypt(ct, key, nonce))
    end)
  end)

  describe("b64url_encode / b64url_decode", function()
    it("round-trips arbitrary bytes", function()
      local raw = crypto.random_bytes(32)
      local encoded = crypto.b64url_encode(raw)
      assert.equals(raw, crypto.b64url_decode(encoded))
    end)

    it("uses URL-safe alphabet (no +, /, or = characters)", function()
      -- Generate enough data to hit all alphabet positions
      for _ = 1, 20 do
        local raw = crypto.random_bytes(32)
        local encoded = crypto.b64url_encode(raw)
        assert.is_nil(encoded:find("[+/=]"))
      end
    end)

    it("round-trips a known 32-byte key", function()
      local key = crypto.generate_key()
      assert.equals(key, crypto.b64url_decode(crypto.b64url_encode(key)))
    end)
  end)

  describe("sha256", function()
    it("returns a 32-byte digest", function()
      local d = crypto.sha256("hello")
      assert.is_string(d)
      assert.equals(32, #d)
    end)

    it("produces the canonical digest for the empty string", function()
      -- e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
      local expected = string.char(
        0xe3,
        0xb0,
        0xc4,
        0x42,
        0x98,
        0xfc,
        0x1c,
        0x14,
        0x9a,
        0xfb,
        0xf4,
        0xc8,
        0x99,
        0x6f,
        0xb9,
        0x24,
        0x27,
        0xae,
        0x41,
        0xe4,
        0x64,
        0x9b,
        0x93,
        0x4c,
        0xa4,
        0x95,
        0x99,
        0x1b,
        0x78,
        0x52,
        0xb8,
        0x55
      )
      assert.equals(expected, crypto.sha256(""))
    end)

    it("produces the canonical digest for 'abc'", function()
      -- ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
      local expected = string.char(
        0xba,
        0x78,
        0x16,
        0xbf,
        0x8f,
        0x01,
        0xcf,
        0xea,
        0x41,
        0x41,
        0x40,
        0xde,
        0x5d,
        0xae,
        0x22,
        0x23,
        0xb0,
        0x03,
        0x61,
        0xa3,
        0x96,
        0x17,
        0x7a,
        0x9c,
        0xb4,
        0x10,
        0xff,
        0x61,
        0xf2,
        0x00,
        0x15,
        0xad
      )
      assert.equals(expected, crypto.sha256("abc"))
    end)
  end)

  describe("fingerprint", function()
    it("returns nil for nil input", function()
      assert.is_nil(crypto.fingerprint(nil))
    end)

    it("returns the AB-CD-EF-12-34-56 format (6 bytes hex with dashes)", function()
      local key = crypto.generate_key()
      local fp = crypto.fingerprint(key)
      assert.is_string(fp)
      assert.is_truthy(fp:match("^%x%x%-%x%x%-%x%x%-%x%x%-%x%x%-%x%x$"))
    end)

    it("is deterministic for the same key", function()
      local key = crypto.generate_key()
      assert.equals(crypto.fingerprint(key), crypto.fingerprint(key))
    end)

    it("differs across keys", function()
      local k1 = crypto.generate_key()
      local k2 = crypto.generate_key()
      -- Collisions on a 6-byte prefix are vanishingly unlikely (1 in 2^48).
      assert.are_not.equal(crypto.fingerprint(k1), crypto.fingerprint(k2))
    end)
  end)
end)
