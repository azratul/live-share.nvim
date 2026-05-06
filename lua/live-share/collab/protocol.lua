-- Message codec for live-share.
--
-- Encodes/decodes a message table to/from a binary payload.  Transport
-- framing (length-prefix, WebSocket frames) is handled by the adapters in
-- transport/tcp.lua and transport/ws.lua.
--
-- ── Wire format (encrypted) ───────────────────────────────────────────────────
--
--   [ 4-byte salt ][ 8-byte counter (BE) ][ ciphertext ][ 16-byte GCM tag ]
--   └────── 12-byte nonce ──────┘
--
--   - salt: random per-direction, fixed for the lifetime of the encryptor.
--   - counter: monotonic per-direction, starts at 1.
--   - AAD (Additional Authenticated Data) bound into the GCM tag:
--       [ 8-byte counter (BE) ][ 4-byte from_peer (BE) ]
--     This binds each ciphertext to its sender and to its position in the
--     stream, so an attacker cannot replay or peer-swap a ciphertext even
--     if they recovered the encrypted message.
--
-- ── Wire format (plaintext) ───────────────────────────────────────────────────
--
--   JSON string.
--
-- ── Two APIs ──────────────────────────────────────────────────────────────────
--
-- The static M.encode / M.decode functions are kept for backward compatibility
-- (used by tests and by the v3 random-nonce path).  In encrypted mode they
-- generate a fresh random nonce per call and pass no AAD — equivalent to v3.
--
-- The v4 path goes through M.new_encryptor / M.new_decryptor, which manage
-- the deterministic counter nonce + AAD described above.  server.lua and
-- client.lua use the encryptor/decryptor objects exclusively.
local M = {}

-- Increment when the message schema changes in a backward-incompatible way.
M.VERSION = 4

-- ── 64-bit big-endian helpers (counter doesn't exceed 2^53 in practice) ──────

local function u64_be(n)
  -- Lua numbers are doubles; safe up to 2^53 — far above any realistic counter.
  local b = {}
  for i = 8, 1, -1 do
    b[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(b)
end

local function u32_be(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function decode_counter(nonce_bytes)
  -- Counter occupies the last 8 bytes of the 12-byte nonce.
  local n = 0
  for i = 5, 12 do
    n = n * 256 + nonce_bytes:byte(i)
  end
  return n
end

-- ── Static codec (plaintext fallback / v3-compatible path) ───────────────────

function M.encode(msg, key)
  local payload = vim.json.encode(msg)
  if not key then
    return payload
  end
  local crypto = require("live-share.collab.crypto")
  local nonce = crypto.random_bytes(12)
  return nonce .. crypto.encrypt(payload, key, nonce)
end

function M.decode(payload, key)
  if key then
    if #payload < 12 then
      return nil
    end
    local crypto = require("live-share.collab.crypto")
    payload = crypto.decrypt(payload:sub(13), key, payload:sub(1, 12))
    if not payload then
      return nil
    end
  end
  local ok, msg = pcall(vim.json.decode, payload)
  if ok and type(msg) == "table" then
    return msg
  end
  return nil
end

-- ── v4 AEAD encryptor ────────────────────────────────────────────────────────
--
-- `from_peer_fn` is a function returning the current sender's peer_id.  It is
-- called per-encode rather than captured at construction time because the
-- guest's peer_id is only known after `hello` arrives — but we want the
-- encryptor to exist before then so it can be reused without rewiring.
--
-- Plaintext mode (key == nil) returns a static codec that just JSON-encodes;
-- callers don't have to special-case the unencrypted path.
function M.new_encryptor(key, from_peer_fn)
  if not key then
    return {
      encode = function(_, msg)
        return vim.json.encode(msg)
      end,
    }
  end

  local crypto = require("live-share.collab.crypto")
  local salt = crypto.random_bytes(4) or string.rep("\0", 4)
  local counter = 0

  return {
    encode = function(_, msg)
      counter = counter + 1
      local plaintext = vim.json.encode(msg)
      local counter_bytes = u64_be(counter)
      local nonce = salt .. counter_bytes
      local from_peer = (from_peer_fn and from_peer_fn()) or 0
      local aad = counter_bytes .. u32_be(from_peer)
      return nonce .. crypto.encrypt(plaintext, key, nonce, aad)
    end,
    -- Exposed for debugging / tests; not used by the runtime.
    _state = function()
      return { counter = counter, salt = salt }
    end,
  }
end

-- ── v4 AEAD decryptor ────────────────────────────────────────────────────────
--
-- `decode(payload, from_peer)` requires the sender's peer_id (host = 0 from
-- the guest's perspective; the connection's peer_id from the server's
-- perspective).  The salt + counter come from the wire (the 12-byte nonce
-- prefix); only the AAD construction needs from_peer.
function M.new_decryptor(key)
  if not key then
    return {
      decode = function(_, payload, _from_peer)
        local ok, msg = pcall(vim.json.decode, payload)
        if ok and type(msg) == "table" then
          return msg
        end
        return nil
      end,
    }
  end

  local crypto = require("live-share.collab.crypto")

  return {
    decode = function(_, payload, from_peer)
      if #payload < 12 then
        return nil
      end
      local nonce = payload:sub(1, 12)
      local counter_bytes = nonce:sub(5, 12)
      local aad = counter_bytes .. u32_be(from_peer or 0)
      local plaintext = crypto.decrypt(payload:sub(13), key, nonce, aad)
      if not plaintext then
        return nil
      end
      local ok, msg = pcall(vim.json.decode, plaintext)
      if ok and type(msg) == "table" then
        return msg
      end
      return nil
    end,
    -- Exposed for tests: parse the counter out of an encrypted frame without
    -- decrypting it.  Useful for asserting deterministic-nonce ordering.
    counter_of = function(_, payload)
      if #payload < 12 then
        return nil
      end
      return decode_counter(payload:sub(1, 12))
    end,
  }
end

return M
