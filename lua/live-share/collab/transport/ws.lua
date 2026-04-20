-- WebSocket transport adapter.
--
-- Mirrors the interface of transport/tcp.lua so callers can treat both
-- transports uniformly. The upper layer (protocol.lua) only deals with
-- binary payloads; all framing details stay here.
--
-- Framing:
--   frame(payload)        → unmasked binary WS frame  (server→client)
--   frame_client(payload) → masked binary WS frame    (client→server, RFC 6455 §5.3)
--   new_reader()          → stateful fn(chunk) → { payload, ... }
--
-- Handshake (server side):
--   server_handshake_response(buf)
--     → nil                      need more data
--     → false, nil, err_msg      bad/incomplete request
--     → response_bytes, rest     OK — write response_bytes, then process rest
--
-- Handshake (client side):
--   client_upgrade(host)
--     → upgrade_request_string, ws_key
--   complete_client_handshake(buf)
--     → nil                      need more data
--     → false, nil, err_msg      server rejected the upgrade
--     → true, rest               OK — process rest
local M = {}

local ws = require("live-share.collab.websocket")

-- ── Framing ──────────────────────────────────────────────────────────────────

function M.frame(payload)
  return ws.encode_frame(payload, false)
end

function M.frame_client(payload)
  return ws.encode_frame(payload, true)
end

M.new_reader = ws.new_frame_reader

-- ── Server-side handshake ─────────────────────────────────────────────────────

function M.server_handshake_response(buf)
  local hend = buf:find("\r\n\r\n", 1, true)
  if not hend then
    return nil
  end -- need more data

  local headers = buf:sub(1, hend + 3)
  local rest = buf:sub(hend + 4)

  -- HTTP headers are case-insensitive (RFC 7230); serveo sends "Sec-Websocket-Key"
  local ws_key = headers:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Kk]ey:%s*([^\r\n]+)")
  if ws_key then
    ws_key = ws_key:match("^(.-)%s*$")
  end
  if not ws_key then
    return false, nil, "Sec-WebSocket-Key missing"
  end

  return ws.server_response(ws_key), rest
end

-- ── Client-side handshake ─────────────────────────────────────────────────────

-- Returns the HTTP upgrade request and the ws_key used in the request.
function M.client_upgrade(host)
  local key = ws.make_client_key()
  return ws.client_request(host, key), key
end

-- Checks the server's 101 response.  ws_key is unused here (Sec-WebSocket-Accept
-- validation is intentionally skipped for simplicity, consistent with prior behaviour).
function M.complete_client_handshake(buf)
  local hend = buf:find("\r\n\r\n", 1, true)
  if not hend then
    return nil
  end -- need more data

  local headers = buf:sub(1, hend + 3)
  local rest = buf:sub(hend + 4)

  if not headers:find("101") then
    return false, nil, "WS handshake failed — server replied:\n" .. headers:sub(1, 300)
  end

  return true, rest
end

return M
