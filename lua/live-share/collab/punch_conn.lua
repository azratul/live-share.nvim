-- collab/punch_conn.lua
-- Punch (P2P UDP hole-punching) transport backend.
--
-- Uses punch.lua (https://github.com/azratul/punch.lua) for direct peer-to-peer
-- sessions.  The tunnel is only used during the signaling phase (~5 s); all
-- collaborative traffic flows over a direct encrypted UDP channel.
--
-- ── Multi-guest model (star topology) ────────────────────────────────────────
--
-- Each guest gets its own punch session (its own UDP socket).  Sessions are
-- established sequentially: once guest N's session opens, the host starts
-- gathering for guest N+1 and updates the signaling server's host description.
-- Concurrent arrivals are handled gracefully: the second guest long-polls until
-- the host is ready for them.
--
-- Limitation: if two guests post their description within the same gather
-- window (before the first session opens), only one will be served; the other
-- must retry after the URL is reshared.  For the typical "join one at a time"
-- workflow this is not an issue.
local M = {}

local ok_punch, punch = pcall(require, "punch")
local ok_sig, sig = pcall(require, "punch.signaling_server")

local protocol = require("live-share.collab.protocol")
local log = require("live-share.collab.log")

local function dbg(m)
  log.dbg("punch_conn", m)
end

-- ── Listener (host side) ─────────────────────────────────────────────────────

-- new_punch_listener(opts)
--   opts.key    — 32-byte AES session key (or nil for plaintext)
--   opts.on_msg — fn(msg, peer_id)
--   opts.stun   — STUN server "host:port"
--
-- Returns a connection object with the standard listener interface plus:
--   conn.signaling_port — TCP port the signaling HTTP server is bound to
function M.new_punch_listener(opts)
  if not ok_punch or not ok_sig then
    error("punch.lua is not installed — run: luarocks install punch")
  end

  local session_key = opts.key
  local on_message = opts.on_msg
  local stun = opts.stun or "stun.l.google.com:19302"

  local sig_srv, srv_err = sig.new({ port = 0 })
  if not sig_srv then
    error("punch_conn: failed to start signaling server: " .. tostring(srv_err))
  end

  local sessions = {} -- peer_id → punch session object
  local approved = {} -- peer_id → true  (after host calls approve)
  local peer_roles = {} -- peer_id → "rw" | "ro"
  local peer_names = {} -- peer_id → name (for synthesising bye on abrupt disconnect)
  local next_peer = 1
  local stopped = false

  local self = {
    signaling_port = tonumber(sig_srv.url:match(":(%d+)$")),
  }

  -- Register a global callback once to handle all incoming guests.
  sig_srv:on_guest(function(slot, guest_desc)
    dbg("guest posted desc for slot " .. tostring(slot))
    -- Heuristic: try to set this description on any session that is ready.
    local found = false
    -- Try most recent sessions first.
    local pids = {}
    for pid in pairs(sessions) do
      table.insert(pids, pid)
    end
    table.sort(pids, function(a, b)
      return a > b
    end)

    for _, pid in ipairs(pids) do
      local s = sessions[pid]
      if s.state == "ready" then
        dbg("associating guest with peer " .. pid)
        s:set_remote_description(guest_desc)
        found = true
        break
      end
    end
    if not found then
      dbg("no ready session found for guest in slot " .. tostring(slot))
    end
  end)

  -- Encode a message and send it over a specific punch session.
  local function send_via_session(s, msg)
    if not s or s.state ~= "open" then
      return
    end
    local payload = protocol.encode(msg, nil)
    s:send(payload)
  end

  -- Prepare the signaling server for the next incoming guest.
  -- Creates a new punch session, gathers candidates, publishes the host
  -- description, then waits for a guest to post theirs.
  local function prepare_for_guest()
    if stopped then
      return
    end

    local peer_id = next_peer
    next_peer = next_peer + 1
    dbg("preparing for guest " .. peer_id)

    -- Create session; key is used by the channel for AES-256-GCM encryption.
    -- Pass relay URL so the session can fall back through the signaling server's
    -- /relay broker when UDP hole-punching fails (e.g. symmetric / double NAT).
    local relay_url = sig_srv and (sig_srv.url:gsub("^http://", "ws://") .. "/relay") or nil
    local s = punch.session.new({ stun = stun, key = session_key, relay = relay_url })

    s:on("error", function(e)
      local msg = "peer " .. peer_id .. " punch error: " .. tostring(e and e.message or e)
      dbg(msg)
      vim.schedule(function()
        vim.notify("live-share: " .. msg, vim.log.levels.ERROR)
      end)
    end)

    s:on("message", function(data)
      local msg = protocol.decode(data, nil)
      if not msg then
        return
      end
      -- Drop messages from unapproved peers.
      if not approved[peer_id] then
        dbg("dropping msg from unapproved peer " .. peer_id .. " (t=" .. tostring(msg.t) .. ")")
        return
      end
      -- Enforce read-only: reject patch messages from ro peers.
      if msg.t == "patch" and peer_roles[peer_id] == "ro" then
        dbg("peer " .. peer_id .. " is read-only — rejecting patch")
        send_via_session(s, {
          t = "error",
          code = "unauthorized",
          message = "read-only guests cannot send patches",
        })
        return
      end
      vim.schedule(function()
        dbg("msg '" .. tostring(msg.t) .. "' from peer " .. peer_id)
        if on_message then
          on_message(msg, peer_id)
        end
      end)
    end)

    s:on("open", function()
      dbg("peer " .. peer_id .. " punch open — notifying host")
      -- Notify the host that a new guest wants to join (approval prompt).
      vim.schedule(function()
        vim.notify("live-share: peer " .. peer_id .. " connected (P2P)", vim.log.levels.INFO)
        if on_message then
          on_message({ t = "connect", peer = peer_id }, peer_id)
        end
      end)
      -- Start preparing for the next guest right away so another one can join.
      prepare_for_guest()
    end)

    s:on("close", function(reason)
      dbg("peer " .. peer_id .. " closed: " .. tostring(reason))
      sessions[peer_id] = nil
      approved[peer_id] = nil
      peer_roles[peer_id] = nil
      local name = peer_names[peer_id]
      peer_names[peer_id] = nil
      vim.schedule(function()
        if on_message then
          on_message({ t = "bye", peer = peer_id, name = name }, peer_id)
        end
      end)
    end)

    -- Gather local candidates.  The callback fires after _local_desc is set,
    -- so get_local_description() is guaranteed to return a non-nil value here.
    -- (Using state_change instead would race: session.lua emits state_change
    -- synchronously inside _set_state, which runs before _local_desc is assigned.)
    s:gather(function(err)
      if stopped then
        s:close()
        return
      end
      if err then
        dbg("gather failed for peer " .. peer_id .. ": " .. tostring(err and err.message or err))
        vim.defer_fn(prepare_for_guest, 2000)
        return
      end

      local desc, derr = s:get_local_description()
      if not desc then
        dbg("no local desc for peer " .. peer_id .. ": " .. tostring(derr))
        vim.defer_fn(prepare_for_guest, 2000)
        return
      end

      sessions[peer_id] = s
      sig_srv:set_host_desc(desc)
      dbg("peer " .. peer_id .. " — host desc published, waiting for guest")
    end)
  end

  -- ── Public API ─────────────────────────────────────────────────────────────

  -- listen() is a no-op for punch: the signaling server is already running.
  -- The ip/port parameters are accepted for API compatibility but ignored.
  function self:listen(_ip, _port)
    prepare_for_guest()
    return true
  end

  function self:send(peer_id, msg)
    local s = sessions[peer_id]
    if not s then
      dbg("send: no session for peer " .. tostring(peer_id))
      return
    end
    send_via_session(s, msg)
  end

  function self:broadcast(msg, except_peer)
    local payload = protocol.encode(msg, nil)
    for pid, s in pairs(sessions) do
      if pid ~= except_peer and s.state == "open" then
        s:send(payload)
      end
    end
  end

  function self:approve(peer_id)
    approved[peer_id] = true
    dbg("peer " .. peer_id .. " approved")
  end

  function self:reject(peer_id, error_msg_table)
    local s = sessions[peer_id]
    if s then
      if s.state == "open" then
        send_via_session(s, error_msg_table)
      end
      s:close()
    end
    sessions[peer_id] = nil
    approved[peer_id] = nil
    peer_roles[peer_id] = nil
    dbg("peer " .. peer_id .. " rejected")
  end

  function self:set_role(peer_id, role)
    peer_roles[peer_id] = role
    dbg("peer " .. peer_id .. " role = " .. tostring(role))
  end

  function self:set_name(peer_id, name)
    peer_names[peer_id] = name
    dbg("peer " .. peer_id .. " name = " .. tostring(name))
  end

  function self:stop()
    if stopped then
      return
    end
    stopped = true
    if sig_srv then
      sig_srv:stop()
      sig_srv = nil
    end
    for _, s in pairs(sessions) do
      s:close()
    end
    sessions = {}
    approved = {}
    peer_roles = {}
    peer_names = {}
  end

  return self
end

-- ── Connector (guest side) ────────────────────────────────────────────────────

-- new_punch_connector(opts)
--   opts.key    — 32-byte AES session key (or nil for plaintext)
--   opts.on_msg — fn(msg)
--   opts.stun   — STUN server "host:port"
--
-- Returns a connection object with the standard connector interface.
-- connect() takes the signaling server URL as its first argument; port is unused.
function M.new_punch_connector(opts)
  if not ok_punch or not ok_sig then
    error("punch is not installed — run: luarocks install punch")
  end

  local session_key = opts.key
  local on_message = opts.on_msg
  local stun = opts.stun or "stun.l.google.com:19302"

  -- `s` is set inside connect() once the signaling URL is known (needed to
  -- derive the relay URL for the fallback broker on the same server).
  local s = nil
  local self = {}

  -- connect(signaling_url, _port, on_error)
  -- Gathers local candidates and exchanges descriptions via the signaling server.
  -- Gather and signaling fetch run concurrently; the punch attempt starts once
  -- both sides have each other's description.
  function self:connect(signaling_url, _port, on_error)
    dbg("connecting via signaling URL: " .. tostring(signaling_url))

    -- Derive relay WebSocket URL from the signaling URL and append /relay.
    -- The connector is a relay consumer: it does not generate its own relay_token;
    -- it will use the host's token from the remote description instead.
    local relay_url = signaling_url:gsub("^http://", "ws://"):gsub("^https://", "wss://") .. "/relay"

    s = punch.session.new({ stun = stun, key = session_key, relay = relay_url, relay_is_consumer = true })

    s:on("error", function(e)
      local msg = "connector punch error: " .. tostring(e and e.message or e)
      dbg(msg)
      vim.schedule(function()
        vim.notify("live-share: " .. msg, vim.log.levels.ERROR)
      end)
    end)

    s:on("message", function(data)
      -- We pass nil as the key because punch.lua already provides
      -- E2E encryption via the channel layer.
      local msg = protocol.decode(data, nil)
      if not msg then
        return
      end
      vim.schedule(function()
        if on_message then
          on_message(msg)
        end
      end)
    end)

    s:on("close", function(reason)
      dbg("connector: punch closed: " .. tostring(reason))
      vim.schedule(function()
        if reason and reason ~= "closed by local peer" then
          vim.notify("live-share: P2P connection closed: " .. tostring(reason), vim.log.levels.WARN)
        end
        if on_message then
          on_message({ t = "bye", peer = 0 })
        end
      end)
    end)

    s:on("open", function()
      dbg("connector: punch open")
      vim.schedule(function()
        vim.notify("live-share: connected (P2P)", vim.log.levels.INFO)
      end)
      -- We NO LONGER send an over-the-wire "connect" message because the host
      -- generates one locally when the punch session opens. This avoids race
      -- conditions and double-prompting.
    end)

    local my_desc = nil
    local host_desc = nil
    local slot_id = nil
    local joined = false

    local function try_exchange()
      if joined or not my_desc or not host_desc or not slot_id then
        return
      end
      joined = true

      sig.post_guest(signaling_url, slot_id, my_desc, function(post_err)
        if post_err then
          dbg("post_guest error: " .. tostring(post_err))
          if on_error then
            vim.schedule(function()
              on_error("signaling post failed: " .. post_err)
            end)
          end
        end
      end)

      s:set_remote_description(host_desc)
    end

    -- Gather local candidates; fire try_exchange() once _local_desc is ready.
    -- Must use the gather callback (not state_change) because session.lua emits
    -- state_change before assigning _local_desc, so get_local_description()
    -- would return nil from a state_change handler.
    s:gather(function(err)
      if err then
        local msg = "punch gather failed: " .. tostring(err and err.message or err)
        dbg(msg)
        if on_error then
          vim.schedule(function()
            on_error(msg)
          end)
        end
        return
      end
      my_desc = s:get_local_description()
      dbg("gather complete; local desc ready")
      try_exchange()
    end)

    -- Fetch host description (long-polls until host is ready).
    sig.fetch_host(signaling_url, 30000, function(fetch_err, hdesc, slot)
      if fetch_err then
        local msg = "signaling fetch failed: " .. tostring(fetch_err)
        dbg(msg)
        if on_error then
          vim.schedule(function()
            on_error(msg)
          end)
        end
        return
      end
      host_desc = hdesc
      slot_id = slot
      dbg("fetched host desc (slot " .. tostring(slot) .. ")")
      try_exchange()
    end)
  end

  function self:send(msg)
    if not s or s.state ~= "open" then
      dbg("connector send: session not open (state=" .. tostring(s and s.state) .. ")")
      return
    end
    local payload = protocol.encode(msg, nil)
    s:send(payload)
  end

  function self:stop()
    if s then
      s:close()
    end
  end

  return self
end

return M
