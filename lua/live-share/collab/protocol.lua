-- Message codec for live-share.
--
-- Encodes/decodes a message table to/from a binary payload.
-- Transport framing (length-prefix, WebSocket frames) is handled by the
-- transport adapters in transport/tcp.lua and transport/ws.lua.
--
-- Payload format:
--   Plaintext:  JSON string
--   Encrypted:  [ 12-byte nonce ][ ciphertext ][ 16-byte GCM tag ]
local M = {}

-- Increment when the message schema changes in a backward-incompatible way.
M.VERSION = 3

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

return M
