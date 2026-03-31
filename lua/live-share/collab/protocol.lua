-- Message encode/decode for live-share.
--
-- Two transport modes:
--   WebSocket (HTTP tunnel providers: serveo, localhost.run)
--     encode(msg, key)       → binary payload (goes inside a WS frame)
--     decode(payload, key)   → msg table
--
--   Raw TCP (direct connections, ngrok tcp://)
--     encode_raw(msg, key)   → length-prefixed frame
--     new_raw_reader(key)    → stateful decoder (handles TCP fragmentation)
--
-- Payload format:
--   Plaintext:  JSON string
--   Encrypted:  [ 12-byte nonce ][ ciphertext ][ 16-byte GCM tag ]
local M = {}

-- ── Payload encode/decode (used by both modes) ──────────────────────────────

function M.encode(msg, key)
  local payload = vim.json.encode(msg)
  if not key then return payload end
  local crypto = require("live-share.collab.crypto")
  local nonce  = crypto.random_bytes(12)
  return nonce .. crypto.encrypt(payload, key, nonce)
end

function M.decode(payload, key)
  if key then
    if #payload < 12 then return nil end
    local crypto = require("live-share.collab.crypto")
    payload = crypto.decrypt(payload:sub(13), key, payload:sub(1, 12))
    if not payload then return nil end
  end
  local ok, msg = pcall(vim.json.decode, payload)
  if ok and type(msg) == "table" then return msg end
  return nil
end

-- ── Raw TCP framing (4-byte LE length prefix) ───────────────────────────────

local function len_prefix(s)
  local n = #s
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256) .. s
end

function M.encode_raw(msg, key)
  return len_prefix(M.encode(msg, key))
end

-- Returns a stateful decoder for raw TCP (handles fragmentation).
function M.new_raw_reader(key)
  local buf = ""
  return function(data)
    buf = buf .. data
    local msgs = {}
    while #buf >= 4 do
      local b1, b2, b3, b4 = buf:byte(1, 4)
      local len = b1 + b2*256 + b3*65536 + b4*16777216
      if #buf < 4 + len then break end
      local payload = buf:sub(5, 4 + len)
      buf = buf:sub(5 + len)
      local msg = M.decode(payload, key)
      if msg then table.insert(msgs, msg) end
    end
    return msgs
  end
end

return M
