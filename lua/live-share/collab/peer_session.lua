-- Per-connection state machine for the host's TCP server.
--
-- One `peer_session.start(deps)` runs per accepted socket.  It owns everything
-- that is specific to a single peer's connection:
--   - transport auto-detection (WebSocket vs. raw TCP from the first 4 bytes),
--   - the WebSocket upgrade handshake,
--   - the v4 forward-secrecy DH handshake (`dh_offer`/`dh_accept`),
--   - the framed read loop, decryption, and message dispatch.
--
-- It does NOT own the peer registry, approval, broadcast, or heartbeat — those
-- are cross-peer concerns that stay in server.lua.  The two communicate through
-- `deps`: the shared registry tables (`deps.reg`), the application message
-- callback (`deps.on_message`), and two server callbacks (`deps.close_peer`,
-- `deps.send`).  Keeping the registry in server.lua and the connection state
-- here is what makes the split safe — state ownership is unambiguous.
local M = {}

local protocol = require("live-share.collab.protocol")
local crypto = require("live-share.collab.crypto")
local subkey = require("live-share.collab.subkey")
local rate_limit = require("live-share.collab.rate_limit")
local tcp_trans = require("live-share.collab.transport.tcp")
local ws_trans = require("live-share.collab.transport.ws")
local log = require("live-share.collab.log")
local uv = vim.uv or vim.loop

-- Maximum bytes per protocol frame.  Frames declaring a length above this are
-- dropped at the transport reader before any allocation, and the connection
-- is closed.  Defends against a malicious peer announcing huge sizes to
-- exhaust host memory.  Picked to comfortably cover the largest legitimate
-- message after stage 6 (a single `workspace_info_chunk` of 1000 paths is
-- well under 1 MB; `file_response` for the 5 MB read_file cap is the next
-- biggest at ~6 MB after JSON-escape + nonce/tag overhead) while remaining
-- well below the 4 GB WS frame ceiling.
local MAX_MESSAGE_BYTES = 10 * 1024 * 1024

-- Pending-peer timeout: an unapproved peer sitting in `pending` past this
-- deadline is force-closed.  Avoids leaks from clients that connect, sit on
-- the prompt, and never finish (or are deliberately camping the slot).
local PENDING_TIMEOUT_MS = 90 * 1000

-- Hex encoder for SHA-256 digests stamped onto inbound messages
-- (`msg.__payload_hash`) for the audit log.
local HEX = "0123456789abcdef"
local function to_hex(bytes)
  local out = {}
  for i = 1, #bytes do
    local b = bytes:byte(i)
    out[#out + 1] = HEX:sub(math.floor(b / 16) + 1, math.floor(b / 16) + 1)
    out[#out + 1] = HEX:sub(b % 16 + 1, b % 16 + 1)
  end
  return table.concat(out)
end

-- Framers wrap the transport-specific framing so they can be stored on the
-- peer record and reused by server.lua's send/broadcast.
local function ws_framer(payload)
  return ws_trans.frame(payload)
end
local function tcp_framer(payload)
  return tcp_trans.frame(payload)
end

local function dbg(msg)
  log.dbg("server", msg)
end

---The shared peer registry tables, owned by server.lua and mutated in place.
---@class LiveShare.PeerRegistry
---@field pending table<LiveShare.PeerId, table> peers awaiting host approval
---@field clients table<LiveShare.PeerId, table> approved peers
---@field roles table<LiveShare.PeerId, LiveShare.Role>
---@field names table<LiveShare.PeerId, string>
---@field last_seen table<LiveShare.PeerId, integer> ms timestamp of last inbound byte

---Dependencies for a single peer connection.
---@class LiveShare.PeerSessionDeps
---@field peer_id LiveShare.PeerId authoritative id for this connection
---@field conn userdata the accepted uv TCP handle
---@field session_key string|nil 32-byte PSK, or nil for plaintext
---@field on_message fun(msg: LiveShare.Message, peer_id: LiveShare.PeerId)|nil app callback
---@field reg LiveShare.PeerRegistry shared registry tables
---@field close_peer fun(peer_id: LiveShare.PeerId, reason: string) server's soft-close
---@field send fun(peer_id: LiveShare.PeerId, msg: LiveShare.Message) server's per-peer send

---Drive one accepted connection through detection, handshake, and the read loop.
---@param deps LiveShare.PeerSessionDeps
function M.start(deps)
  local peer_id = deps.peer_id
  local conn = deps.conn
  local session_key = deps.session_key
  local on_message = deps.on_message
  local reg = deps.reg
  local close_peer = deps.close_peer
  local send = deps.send

  dbg("peer " .. peer_id .. " TCP accepted")

  -- State: "detecting" | "ws_hs" | "ws" | "tcp"
  local state = "detecting"
  local buf = ""
  local reader = nil -- stateful fn(chunk) → { payload, ... }; set at detection time
  -- The peer record is created at detection time and stored in `reg.pending`
  -- (and later `reg.clients`); the closure below references it through the
  -- `peer_id` lookup so that codec swaps after the DH handshake reach
  -- subsequent reads/writes.
  local function rec()
    return reg.pending[peer_id] or reg.clients[peer_id]
  end

  local function dispatch(msg)
    -- Drop messages from unapproved peers (they're still in pending).
    if not reg.clients[peer_id] then
      return
    end
    -- ping / pong are handled at this layer and never bubble up to the
    -- application: pong (and any incoming ping from the guest) only
    -- serves to bump last_seen, which already happened in the read
    -- callback.  Returning here keeps the upper layer's message handler
    -- focused on application-level events.
    if msg.t == "pong" or msg.t == "ping" then
      return
    end
    -- Enforce read-only: reject patch messages from ro peers.
    if msg.t == "patch" and reg.roles[peer_id] == "ro" then
      dbg("peer " .. peer_id .. " is read-only — rejecting patch")
      send(peer_id, {
        t = "error",
        code = "unauthorized",
        message = "read-only guests cannot send patches",
      })
      return
    end
    -- Per-peer rate limit (defends against patch/cursor flooding).
    if not rate_limit.allow(peer_id, msg.t) then
      dbg("peer " .. peer_id .. " rate-limited (" .. tostring(msg.t) .. ")")
      return
    end
    -- peer_id binding: never trust a `peer` field set by the client.  The
    -- only authoritative identity is the connection's peer_id.  Without
    -- this, a malicious guest could spoof cursor/focus/bye broadcasts
    -- attributed to other peers.
    if msg.peer ~= nil then
      msg.peer = peer_id
    end
    vim.schedule(function()
      dbg("msg '" .. tostring(msg.t) .. "' from peer " .. peer_id)
      if on_message then
        on_message(msg, peer_id)
      end
    end)
  end

  local function on_disconnect(reason)
    vim.schedule(function()
      dbg("peer " .. peer_id .. " disconnected: " .. tostring(reason))
      local p = reg.pending[peer_id]
      if p and p.pending_timer then
        p.pending_timer:stop()
        p.pending_timer:close()
      end
      reg.pending[peer_id] = nil
      reg.clients[peer_id] = nil
      reg.roles[peer_id] = nil
      rate_limit.forget(peer_id)
      reg.last_seen[peer_id] = nil
      local name = reg.names[peer_id]
      reg.names[peer_id] = nil
      if on_message then
        on_message({ t = "bye", peer = peer_id, name = name }, peer_id)
      end
    end)
    if not conn:is_closing() then
      conn:close()
    end
  end

  -- Handle the guest's reply to dh_offer: verify HMAC over their public
  -- key with the URL-fragment PSK, derive the per-peer subkey via X25519
  -- + HKDF, and swap the peer's encryptor/decryptor to use it.  Only
  -- after this completes does the synthetic `connect` event fire — the
  -- host.lua approval prompt then runs against an authenticated channel.
  local function finish_dh(msg)
    local r = rec()
    if not r or msg.t ~= "dh_accept" or type(msg.pub) ~= "string" or type(msg.hmac) ~= "string" then
      dbg("peer " .. peer_id .. " — protocol violation during DH: " .. tostring(msg and msg.t))
      on_disconnect("dh violation")
      return false
    end
    local their_pub = crypto.b64url_decode(msg.pub)
    local their_hmac = crypto.b64url_decode(msg.hmac)
    if #their_pub ~= 32 or #their_hmac ~= 32 then
      dbg("peer " .. peer_id .. " — malformed DH key/HMAC")
      on_disconnect("dh shape")
      return false
    end
    local expected = crypto.hmac_sha256(session_key, their_pub)
    if not expected or expected ~= their_hmac then
      dbg("peer " .. peer_id .. " — DH HMAC mismatch (PSK wrong or MITM); closing")
      on_disconnect("dh hmac")
      return false
    end
    local shared, derr = crypto.x25519_shared(r.dh_priv, their_pub)
    if not shared then
      dbg("peer " .. peer_id .. " — X25519 derive failed: " .. tostring(derr))
      on_disconnect("dh derive")
      return false
    end
    local sk = subkey.derive(shared, peer_id, session_key)
    if not sk then
      dbg("peer " .. peer_id .. " — HKDF failed")
      on_disconnect("dh hkdf")
      return false
    end
    r.encryptor, r.decryptor = subkey.make_codec(sk)
    r.dh_priv = nil
    r.dh_state = "established"
    dbg("peer " .. peer_id .. " — DH established, switching to per-peer subkey")
    vim.schedule(function()
      if on_message then
        on_message({ t = "connect", peer = peer_id }, peer_id)
      end
    end)
    return true
  end

  local function process(data)
    local payloads, rerr = reader(data)
    if not payloads then
      dbg("peer " .. peer_id .. " transport error: " .. tostring(rerr) .. " — closing")
      on_disconnect(rerr)
      return
    end
    -- Mark the peer alive on every parsed frame, regardless of message type.
    -- This is what lets the heartbeat consider any chatter (patches, cursor
    -- moves, pongs) as keepalive evidence.
    if #payloads > 0 then
      reg.last_seen[peer_id] = uv.now()
    end
    for _, payload in ipairs(payloads) do
      local r = rec()
      if not r then
        return
      end
      if r.dh_state == "awaiting_accept" then
        -- The TCP-mode 4-byte probe (`\x00\x00\x00\x00`) decodes as a
        -- zero-length payload; that's a transport artefact, not a real
        -- message — skip silently.  Anything else must be valid JSON.
        if #payload == 0 then
          goto continue_payload
        end
        local ok, parsed = pcall(vim.json.decode, payload)
        if not ok or type(parsed) ~= "table" then
          dbg("peer " .. peer_id .. " — invalid pre-DH payload; closing")
          on_disconnect("dh parse")
          return
        end
        if not finish_dh(parsed) then
          return
        end
      else
        -- AAD on inbound binds the message to the connection's authoritative
        -- peer_id; an attacker swapping the ciphertext between connections
        -- (or relabelling a recorded message) would fail GCM verification.
        local msg = r.decryptor:decode(payload, peer_id)
        if msg then
          -- Stamp the inbound encrypted payload's SHA-256 onto the message
          -- so the audit log (host.lua) can record `payload_hash` for the
          -- exact ciphertext that triggered the event — useful when later
          -- correlating the audit trail against a packet capture.  The
          -- hash is over the full `[salt][counter][ciphertext+tag]` blob.
          local digest = crypto.sha256(payload)
          if digest then
            msg.__payload_hash = to_hex(digest)
          end
          dispatch(msg)
        end
      end
      ::continue_payload::
    end
  end

  -- Generate an ephemeral X25519 keypair, send `dh_offer` plaintext-framed
  -- with PSK-HMAC over the public key, and stash the private key on the
  -- peer record so finish_dh() can complete the exchange when the guest
  -- replies.  Returns false on any local crypto failure (and closes the
  -- connection); v4 sessions with a key cannot proceed without DH.
  local function start_dh()
    local r = rec()
    if not r then
      return false
    end
    local priv, pub = crypto.x25519_keypair()
    if not priv or not pub then
      dbg("peer " .. peer_id .. " — X25519 keygen failed; closing")
      on_disconnect("dh keygen")
      return false
    end
    local hmac = crypto.hmac_sha256(session_key, pub)
    if not hmac then
      dbg("peer " .. peer_id .. " — HMAC failed; closing")
      on_disconnect("dh hmac-gen")
      return false
    end
    r.dh_priv = priv
    r.dh_state = "awaiting_accept"
    local payload = vim.json.encode({
      t = "dh_offer",
      peer_id = peer_id,
      pub = crypto.b64url_encode(pub),
      hmac = crypto.b64url_encode(hmac),
    })
    conn:write(r.framer(payload))
    dbg("peer " .. peer_id .. " — dh_offer sent, awaiting accept")
    return true
  end

  -- Initialise the peer record's codec.  In plaintext sessions both
  -- encryptor and decryptor are the JSON-only fallback returned by
  -- protocol.new_*(nil); in encrypted sessions they start as plaintext
  -- too (so the dh_offer/dh_accept exchange itself rides as JSON) and
  -- are swapped inside finish_dh() once the subkey is derived.
  local function init_peer_record(framer, mode)
    reg.pending[peer_id] = {
      handle = conn,
      framer = framer,
      mode = mode,
      encryptor = protocol.new_encryptor(nil, nil),
      decryptor = protocol.new_decryptor(nil),
      dh_state = nil,
    }
  end

  -- Arms the pending-peer timeout.  Called once we know the transport mode.
  local function arm_pending_timeout()
    local p = reg.pending[peer_id]
    if not p then
      return
    end
    local t = uv.new_timer()
    p.pending_timer = t
    t:start(
      PENDING_TIMEOUT_MS,
      0,
      vim.schedule_wrap(function()
        if reg.pending[peer_id] then
          dbg("peer " .. peer_id .. " unapproved after " .. PENDING_TIMEOUT_MS .. " ms — kicking")
          close_peer(peer_id, "pending timeout")
        end
      end)
    )
  end

  -- Decide whether to start the DH handshake or fire the synthetic
  -- `connect` event directly.  Encrypted sessions defer the connect
  -- event until DH completes (finish_dh schedules it).
  local function after_detect()
    arm_pending_timeout()
    if session_key then
      if not start_dh() then
        return
      end
    else
      vim.schedule(function()
        if on_message then
          on_message({ t = "connect", peer = peer_id }, peer_id)
        end
      end)
    end
  end

  local function complete_ws_handshake(initial_buf)
    local response, rest, err_msg = ws_trans.server_handshake_response(initial_buf)
    if response == nil then
      return false
    end -- need more data

    if response == false then
      dbg("peer " .. peer_id .. " — " .. (err_msg or "bad WS request") .. "; closing")
      if not conn:is_closing() then
        conn:close()
      end
      return true -- done (with error)
    end

    conn:write(response)
    state = "ws"
    init_peer_record(ws_framer, "ws")
    dbg("peer " .. peer_id .. " WS handshake done")
    after_detect()
    if #rest > 0 then
      process(rest)
    end
    return true
  end

  conn:read_start(function(read_err, data)
    if read_err or not data then
      on_disconnect(read_err)
      return
    end

    buf = buf .. data

    if state == "detecting" then
      if #buf < 4 then
        return
      end
      if buf:sub(1, 4) == "GET " then
        state = "ws_hs"
        reader = ws_trans.new_reader(MAX_MESSAGE_BYTES)
        dbg("peer " .. peer_id .. " → WebSocket mode")
        -- fall through to ws_hs handling below
      else
        state = "tcp"
        reader = tcp_trans.new_reader(MAX_MESSAGE_BYTES)
        init_peer_record(tcp_framer, "tcp")
        dbg("peer " .. peer_id .. " → raw TCP mode")
        after_detect()
        process(buf)
        buf = ""
        return
      end
    end

    if state == "ws_hs" then
      if complete_ws_handshake(buf) then
        buf = ""
      end
      return
    end

    if state == "ws" then
      process(data)
      return
    end
    if state == "tcp" then
      process(data)
      return
    end
  end)
end

return M
