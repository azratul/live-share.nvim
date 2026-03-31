-- WebSocket client/server handshake and frame encode/decode.
-- Needed because tunnel providers (serveo, localhost.run) are HTTP reverse proxies
-- and will only forward HTTP-based traffic, not raw TCP.
local M = {}

local bit = require("bit")
local band, bxor, bor, bnot = bit.band, bit.bxor, bit.bor, bit.bnot
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit

-- ── SHA-1 (pure Lua/LuaJIT, needed for Sec-WebSocket-Accept) ───────────────

local function sha1(msg)
  local len  = #msg
  local bits = len * 8

  -- Append 0x80, pad to 56 mod 64, then 8-byte big-endian bit count
  msg = msg .. "\x80"
  while #msg % 64 ~= 56 do msg = msg .. "\x00" end
  msg = msg .. "\x00\x00\x00\x00" .. string.char(
    math.floor(bits / 16777216) % 256,
    math.floor(bits / 65536)    % 256,
    math.floor(bits / 256)      % 256,
    bits % 256)

  local h = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 }

  for i = 1, #msg, 64 do
    local w = {}
    for j = 1, 16 do
      local o = i + (j - 1) * 4
      w[j] = bor(bor(bor(lshift(msg:byte(o), 24), lshift(msg:byte(o + 1), 16)),
                 lshift(msg:byte(o + 2), 8)), msg:byte(o + 3))
    end
    for j = 17, 80 do
      w[j] = rol(bxor(bxor(bxor(w[j-3], w[j-8]), w[j-14]), w[j-16]), 1)
    end

    local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]

    for j = 1, 80 do
      local f, k
      if j <= 20 then
        f = bor(band(b, c), band(bnot(b), d)); k = 0x5A827999
      elseif j <= 40 then
        f = bxor(bxor(b, c), d);               k = 0x6ED9EBA1
      elseif j <= 60 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d)); k = 0x8F1BBCDC
      else
        f = bxor(bxor(b, c), d);               k = 0xCA62C1D6
      end
      local temp = tobit(tobit(rol(a, 5)) + tobit(f) + tobit(e) + tobit(k) + tobit(w[j]))
      e = d; d = c; c = rol(b, 30); b = a; a = temp
    end

    h[1] = tobit(h[1] + a)
    h[2] = tobit(h[2] + b)
    h[3] = tobit(h[3] + c)
    h[4] = tobit(h[4] + d)
    h[5] = tobit(h[5] + e)
  end

  local res = {}
  for i = 1, 5 do
    local n = h[i]
    res[#res+1] = string.char(
      band(rshift(n, 24), 0xFF),
      band(rshift(n, 16), 0xFF),
      band(rshift(n, 8),  0xFF),
      band(n, 0xFF))
  end
  return table.concat(res)
end

-- ── Standard Base64 (with = padding, for WS headers) ───────────────────────

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function b64_encode(s)
  local res, i = {}, 1
  while i <= #s do
    local b1, b2, b3 = s:byte(i), s:byte(i+1) or 0, s:byte(i+2) or 0
    local n = b1*65536 + b2*256 + b3
    res[#res+1] = B64:sub(math.floor(n/262144)+1,      math.floor(n/262144)+1)
    res[#res+1] = B64:sub(math.floor(n/4096)%64+1,     math.floor(n/4096)%64+1)
    res[#res+1] = i+1 <= #s and B64:sub(math.floor(n/64)%64+1, math.floor(n/64)%64+1) or "="
    res[#res+1] = i+2 <= #s and B64:sub(n%64+1, n%64+1) or "="
    i = i + 3
  end
  return table.concat(res)
end

-- ── Handshake helpers ───────────────────────────────────────────────────────

local WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- Generate a random 16-byte nonce, base64-encoded (the Sec-WebSocket-Key value).
function M.make_client_key()
  local ok, crypto = pcall(require, "live-share.collab.crypto")
  local bytes
  if ok and crypto.available then
    bytes = crypto.random_bytes(16)
  else
    local t = {}
    for i = 1, 16 do t[i] = string.char(math.random(0, 255)) end
    bytes = table.concat(t)
  end
  return b64_encode(bytes)
end

-- HTTP GET upgrade request sent by the client.
function M.client_request(host, key_b64)
  return table.concat({
    "GET / HTTP/1.1",
    "Host: " .. host,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key_b64,
    "Sec-WebSocket-Version: 13",
    "", "",
  }, "\r\n")
end

-- HTTP 101 response sent by the server.
function M.server_response(ws_key)
  local accept = b64_encode(sha1(ws_key .. WS_MAGIC))
  return table.concat({
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. accept,
    "", "",
  }, "\r\n")
end

-- ── Frame encode ────────────────────────────────────────────────────────────

-- Encode a binary WebSocket frame.
--   masked = true  → client→server (RFC 6455 §5.3 requires masking)
--   masked = false → server→client
function M.encode_frame(payload, masked)
  local len    = #payload
  local b2base = masked and 0x80 or 0x00

  local header
  if len < 126 then
    header = string.char(0x82, b2base + len)
  elseif len < 65536 then
    header = string.char(0x82, b2base + 126,
      math.floor(len/256), len%256)
  else
    header = string.char(0x82, b2base + 127,
      0, 0, 0, 0,
      math.floor(len/16777216)%256,
      math.floor(len/65536)%256,
      math.floor(len/256)%256,
      len%256)
  end

  if not masked then return header .. payload end

  local mk = { math.random(0,255), math.random(0,255),
               math.random(0,255), math.random(0,255) }
  local bytes = {}
  for i = 1, len do
    bytes[i] = string.char(bxor(payload:byte(i), mk[(i-1)%4+1]))
  end
  return header .. string.char(mk[1],mk[2],mk[3],mk[4]) .. table.concat(bytes)
end

-- ── Frame decode ────────────────────────────────────────────────────────────

-- Returns a stateful decoder that handles TCP fragmentation.
-- Call fn(chunk) → list of binary payloads extracted from complete WS frames.
function M.new_frame_reader()
  local buf = ""

  return function(data)
    buf = buf .. data
    local payloads = {}

    while true do
      if #buf < 2 then break end

      local b1, b2   = buf:byte(1), buf:byte(2)
      local opcode   = band(b1, 0x0F)
      local masked   = band(b2, 0x80) ~= 0
      local plen7    = band(b2, 0x7F)

      local ext      = (plen7 == 126) and 2 or (plen7 == 127) and 8 or 0
      local hdr_size = 2 + ext + (masked and 4 or 0)

      if #buf < hdr_size then break end

      local plen
      if     plen7 < 126  then plen = plen7
      elseif plen7 == 126 then plen = buf:byte(3)*256 + buf:byte(4)
      else
        -- Ignore the high 4 bytes (messages < 4 GB)
        plen = buf:byte(7)*16777216 + buf:byte(8)*65536
             + buf:byte(9)*256      + buf:byte(10)
      end

      if #buf < hdr_size + plen then break end

      local payload = buf:sub(hdr_size + 1, hdr_size + plen)

      if masked then
        local mk_pos = 2 + ext + 1
        local mk     = { buf:byte(mk_pos, mk_pos + 3) }
        local bytes  = {}
        for i = 1, plen do
          bytes[i] = string.char(bxor(payload:byte(i), mk[(i-1)%4+1]))
        end
        payload = table.concat(bytes)
      end

      buf = buf:sub(hdr_size + plen + 1)

      if opcode == 1 or opcode == 2 then  -- text or binary
        table.insert(payloads, payload)
      end
      -- opcode 8 (close), 9 (ping), 10 (pong): ignore; TCP disconnect handles cleanup
    end

    return payloads
  end
end

return M
