-- v4 forward-secrecy subkey derivation and per-peer codec construction.
--
-- Each peer runs its own ephemeral X25519 handshake (`dh_offer`/`dh_accept`)
-- and derives an independent AEAD subkey via HKDF.  The URL-fragment master
-- key is never used to encrypt traffic directly — it acts as a pre-shared key
-- (PSK) that authenticates the public keys via HMAC-SHA256.  Pulling the
-- derivation out of server.lua keeps the crypto seam small and named.
--
-- Subkey derivation (RFC 5869):
--   PRK    = HMAC(salt = PSK, IKM = X25519(my_priv, peer_pub))
--   subkey = HKDF-Expand(PRK, info = "ls-v4-subkey|" || peer_id_be4, L = 32)
local M = {}

local crypto = require("live-share.collab.crypto")
local protocol = require("live-share.collab.protocol")

local SUBKEY_INFO_PREFIX = "ls-v4-subkey|"

-- Encode peer_id as 4-byte big-endian for HKDF info binding.
local function u32_be(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

---Derive a 32-byte AEAD subkey from a peer's X25519 shared secret.  Both
---sides feed the same PSK and the same peer_id, so they arrive at the same
---subkey without ever transmitting it.
---@param shared string the X25519 shared secret
---@param peer_id LiveShare.PeerId
---@param psk string the URL-fragment master key, used as the HKDF salt
---@return string|nil subkey 32 bytes, or nil if HKDF is unavailable
function M.derive(shared, peer_id, psk)
  return crypto.hkdf_sha256(shared, psk, SUBKEY_INFO_PREFIX .. u32_be(peer_id), 32)
end

---Build a fresh encryptor/decryptor pair bound to `subkey`.  The host is
---always from_peer = 0 on outbound; the inbound peer_id is supplied by the
---caller at decode time.
---@param subkey string
---@return LiveShare.Encryptor encryptor
---@return LiveShare.Decryptor decryptor
function M.make_codec(subkey)
  return protocol.new_encryptor(subkey, function()
    return 0
  end), protocol.new_decryptor(subkey)
end

return M
