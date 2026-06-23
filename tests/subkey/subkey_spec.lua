-- Unit tests for lua/live-share/collab/subkey.lua (v4 forward-secrecy helpers)
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local crypto = require("live-share.collab.crypto")
local subkey = require("live-share.collab.subkey")

describe("subkey derivation", function()
  if not crypto.available or not crypto.x25519_available then
    pending("OpenSSL X25519 unavailable — skipping")
    return
  end

  -- Stand-in for the URL-fragment master key (PSK).
  local psk = string.rep("P", 32)

  it("both peers derive the same subkey from the ECDH shared secret", function()
    local hpriv, hpub = crypto.x25519_keypair()
    local gpriv, gpub = crypto.x25519_keypair()
    local hshared = crypto.x25519_shared(hpriv, gpub)
    local gshared = crypto.x25519_shared(gpriv, hpub)
    assert.equals(hshared, gshared) -- ECDH symmetry

    local hk = subkey.derive(hshared, 1, psk)
    local gk = subkey.derive(gshared, 1, psk)
    assert.is_string(hk)
    assert.equals(32, #hk)
    assert.equals(hk, gk)
  end)

  it("binds the subkey to the peer id", function()
    local hpriv, _ = crypto.x25519_keypair()
    local _, gpub = crypto.x25519_keypair()
    local shared = crypto.x25519_shared(hpriv, gpub)
    assert.are_not.equals(subkey.derive(shared, 1, psk), subkey.derive(shared, 2, psk))
  end)

  it("a different PSK yields a different subkey", function()
    local hpriv, _ = crypto.x25519_keypair()
    local _, gpub = crypto.x25519_keypair()
    local shared = crypto.x25519_shared(hpriv, gpub)
    assert.are_not.equals(subkey.derive(shared, 1, psk), subkey.derive(shared, 1, string.rep("Q", 32)))
  end)

  it("make_codec round-trips a message", function()
    local hpriv, _ = crypto.x25519_keypair()
    local _, gpub = crypto.x25519_keypair()
    local sk = subkey.derive(crypto.x25519_shared(hpriv, gpub), 1, psk)

    local enc, dec = subkey.make_codec(sk)
    local payload = enc:encode({ t = "hi", n = 42 })
    -- The encryptor stamps from_peer = 0; the decryptor must be told the same.
    local msg = dec:decode(payload, 0)
    assert.is_table(msg)
    assert.equals("hi", msg.t)
    assert.equals(42, msg.n)
  end)

  it("make_codec rejects a payload decoded with the wrong sender id", function()
    local hpriv, _ = crypto.x25519_keypair()
    local _, gpub = crypto.x25519_keypair()
    local sk = subkey.derive(crypto.x25519_shared(hpriv, gpub), 1, psk)

    local enc, dec = subkey.make_codec(sk)
    local payload = enc:encode({ t = "hi" })
    -- AAD binds the ciphertext to from_peer = 0; decoding as peer 7 must fail.
    assert.is_nil(dec:decode(payload, 7))
  end)
end)
