-- Stage 3 (AEAD framing): per-direction counter nonce + AAD binding.
--
-- v3 shape:
--   [ 12-byte random nonce ][ ciphertext ][ 16-byte GCM tag ]
--
-- v4 shape (same length, structured):
--   [ 4-byte salt ][ 8-byte counter (BE) ][ ciphertext ][ tag ]
--   AAD = [ 8-byte counter ][ 4-byte from_peer (BE) ]
--
-- Coverage:
--   1. Encryptor emits a deterministic counter nonce: salt is fixed across
--      messages, counter increments by 1 per encode.
--   2. Decryptor with matching from_peer round-trips an encoded message.
--   3. Swapping from_peer on decode fails the GCM tag (AAD mismatch).
--   4. Two encryptors built from the same key produce different salts, so
--      their nonce streams cannot collide even if both started at counter=1.
--   5. Plaintext mode (key = nil) returns a degenerate encryptor/decryptor
--      pair that just JSON-encodes — used by tests and by sessions running
--      without OpenSSL.
--   6. The static M.encode / M.decode codec still works (kept for v3 / test
--      use), and the AEAD decryptor REJECTS payloads produced by it
--      (different envelope, no AAD).

local protocol = require("live-share.collab.protocol")
local crypto = require("live-share.collab.crypto")

describe("v4 AEAD encryptor", function()
  if not crypto.available then
    pending("OpenSSL not available — skipping AEAD tests")
    return
  end

  local key
  before_each(function()
    key = crypto.generate_key()
  end)

  it("uses a deterministic counter nonce: salt fixed, counter monotonic", function()
    local enc = protocol.new_encryptor(key, function()
      return 0
    end)
    local p1 = enc:encode({ t = "ping", ts = 1 })
    local p2 = enc:encode({ t = "ping", ts = 2 })
    local p3 = enc:encode({ t = "ping", ts = 3 })

    -- First 4 bytes (salt) are equal across the three encodes.
    assert.equals(p1:sub(1, 4), p2:sub(1, 4))
    assert.equals(p1:sub(1, 4), p3:sub(1, 4))

    -- Last 8 bytes of the 12-byte nonce encode the counter big-endian; counter
    -- starts at 1 and increments by 1.  Walk the bytes and reconstruct.
    local function read_counter(payload)
      local n = 0
      for i = 5, 12 do
        n = n * 256 + payload:byte(i)
      end
      return n
    end
    assert.equals(1, read_counter(p1))
    assert.equals(2, read_counter(p2))
    assert.equals(3, read_counter(p3))
  end)

  it("round-trips through a matching decryptor with the same from_peer", function()
    local enc = protocol.new_encryptor(key, function()
      return 7
    end)
    local dec = protocol.new_decryptor(key)

    local msg = { t = "patch", path = "main.lua", lnum = 0, count = 1, lines = { "x" } }
    local payload = enc:encode(msg)
    local decoded = dec:decode(payload, 7)
    assert.are.same(msg, decoded)
  end)

  it("REJECTS decryption when from_peer differs (AAD mismatch fails GCM tag)", function()
    local enc = protocol.new_encryptor(key, function()
      return 5
    end)
    local dec = protocol.new_decryptor(key)

    local payload = enc:encode({ t = "cursor", lnum = 1, col = 0 })
    -- Same key, same payload — but the receiver computes the AAD with a
    -- different from_peer than the sender used.  GCM detects the swap.
    assert.is_nil(dec:decode(payload, 6))
    assert.is_nil(dec:decode(payload, 0))
    -- And just to confirm the negative result is real, the right peer works.
    assert.is_not_nil(dec:decode(enc:encode({ t = "cursor", lnum = 2, col = 0 }), 5))
  end)

  it("two encryptors built from the same key use different salts", function()
    -- Salt is generated at construction time from the OpenSSL RNG, so two
    -- independent encryptors should disagree on the salt with overwhelming
    -- probability.  This protects against nonce collisions when, e.g., the
    -- same key is reused across host restarts.
    local enc_a = protocol.new_encryptor(key, function()
      return 0
    end)
    local enc_b = protocol.new_encryptor(key, function()
      return 0
    end)
    local pa = enc_a:encode({ t = "ping", ts = 1 })
    local pb = enc_b:encode({ t = "ping", ts = 1 })
    assert.are_not.equal(pa:sub(1, 4), pb:sub(1, 4))
  end)

  it("plaintext mode (key=nil) returns a JSON-only codec", function()
    local enc = protocol.new_encryptor(nil, nil)
    local dec = protocol.new_decryptor(nil)

    local msg = { t = "hello", peer_id = 1, sid = "abc" }
    local payload = enc:encode(msg)
    -- Plaintext encode produces a JSON string the static codec can parse.
    local decoded = dec:decode(payload, 0)
    assert.are.same(msg, decoded)
  end)

  it("AEAD decryptor refuses payloads produced by the static random-nonce codec", function()
    -- v3 static encode uses a random 12-byte nonce and no AAD.  An AEAD
    -- decryptor expects the AAD to be bound, so it must fail.  This is what
    -- enforces the v3↔v4 wire incompatibility at the cryptographic layer.
    local v3_payload = protocol.encode({ t = "ping", ts = 1 }, key)
    local dec = protocol.new_decryptor(key)
    assert.is_nil(dec:decode(v3_payload, 0))
  end)
end)
