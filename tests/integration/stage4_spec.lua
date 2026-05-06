-- Stage 4 (forward secrecy): X25519 ECDH + HKDF-SHA256 per-peer subkeys.
--
-- The URL-fragment master key (PSK) no longer encrypts traffic directly.
-- Each peer pair runs an ephemeral X25519 handshake at session start,
-- authenticated by HMAC-SHA256(PSK, pub).  The shared DH secret is fed into
-- HKDF together with the PSK and the peer_id to derive a 32-byte subkey
-- that AES-GCM uses for the rest of the session.
--
-- Coverage:
--   1. crypto: X25519 keypair returns 32-byte priv/pub; the ECDH operation
--      is symmetric (a_priv·b_pub == b_priv·a_pub).
--   2. crypto: HMAC-SHA256 outputs 32 bytes; HKDF-SHA256 is deterministic
--      and equal-input → equal-output.
--   3. crypto: different peer_id values feeding HKDF info produce different
--      subkeys — this is what isolates kicked peers and prevents one peer
--      decrypting another's traffic.
--   4. wire: a real server↔client encrypted session does the dh_offer /
--      dh_accept exchange before any other traffic, and the resulting
--      session can carry application messages.
--   5. wire: a client sending an HMAC-corrupt dh_accept is dropped without
--      establishing a session.
--   6. wire: a connect event ONLY fires on the host once DH completes —
--      i.e., the host's approval prompt runs against an authenticated
--      channel, not a freshly-accepted unauthenticated TCP connection.

local crypto = require("live-share.collab.crypto")
local protocol = require("live-share.collab.protocol")
local server = require("live-share.collab.server")
local client = require("live-share.collab.client")
local tcp_trans = require("live-share.collab.transport.tcp")
local uv = vim.uv or vim.loop

local BASE_PORT = 19960
local TIMEOUT_MS = 3000

local function wait_for(cond)
  return vim.wait(TIMEOUT_MS, cond, 10)
end

-- ── Crypto primitives ────────────────────────────────────────────────────────

describe("X25519 / HMAC / HKDF (crypto layer)", function()
  if not crypto.available or not crypto.x25519_available then
    pending("OpenSSL X25519 unavailable — skipping")
    return
  end

  it("X25519 keypair generates 32-byte priv and pub", function()
    local priv, pub = crypto.x25519_keypair()
    assert.is_string(priv)
    assert.is_string(pub)
    assert.equals(32, #priv)
    assert.equals(32, #pub)
  end)

  it("X25519 ECDH is symmetric: a·B = b·A", function()
    local a_priv, a_pub = crypto.x25519_keypair()
    local b_priv, b_pub = crypto.x25519_keypair()
    local s_ab = crypto.x25519_shared(a_priv, b_pub)
    local s_ba = crypto.x25519_shared(b_priv, a_pub)
    assert.equals(32, #s_ab)
    assert.equals(s_ab, s_ba)
  end)

  it("HMAC-SHA256 returns 32 bytes and is deterministic", function()
    local h1 = crypto.hmac_sha256("a-key", "some data")
    local h2 = crypto.hmac_sha256("a-key", "some data")
    assert.equals(32, #h1)
    assert.equals(h1, h2)

    local h3 = crypto.hmac_sha256("different-key", "some data")
    assert.are_not.equal(h1, h3)
  end)

  it("HKDF-SHA256 is deterministic and length-respecting", function()
    local k1 = crypto.hkdf_sha256("ikm", "salt", "info", 32)
    local k2 = crypto.hkdf_sha256("ikm", "salt", "info", 32)
    assert.equals(32, #k1)
    assert.equals(k1, k2)

    local k_short = crypto.hkdf_sha256("ikm", "salt", "info", 16)
    assert.equals(16, #k_short)
    -- The first 16 bytes of the 32-byte output should match the 16-byte
    -- output (HKDF-Expand emits a stream).
    assert.equals(k_short, k1:sub(1, 16))
  end)

  it("different HKDF info yields different subkeys (per-peer isolation)", function()
    local ikm = "shared-secret"
    local salt = "psk"
    local k_peer1 = crypto.hkdf_sha256(ikm, salt, "ls-v4-subkey|" .. string.char(0, 0, 0, 1), 32)
    local k_peer2 = crypto.hkdf_sha256(ikm, salt, "ls-v4-subkey|" .. string.char(0, 0, 0, 2), 32)
    assert.are_not.equal(k_peer1, k_peer2)
  end)
end)

-- ── Wire-level DH handshake ──────────────────────────────────────────────────

describe("server↔client DH handshake (wire)", function()
  if not crypto.available or not crypto.x25519_available then
    pending("OpenSSL X25519 unavailable — skipping")
    return
  end

  after_each(function()
    server.stop()
    client.stop()
  end)

  it("encrypted TCP session completes DH and carries an application message", function()
    local key = crypto.generate_key()
    local connect_seen, hello_received = false, nil

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        connect_seen = true
        server.approve(peer_id)
        server.send(peer_id, { t = "hello", peer_id = peer_id, sid = "dh-tcp", protocol_version = protocol.VERSION })
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT, key), "server failed to bind")

    client.setup(function(msg)
      if msg.t == "hello" then
        hello_received = msg
      end
    end)
    client.connect("127.0.0.1", BASE_PORT, key, "tcp", 0, nil)

    assert.is_true(
      wait_for(function()
        return hello_received ~= nil
      end),
      "encrypted TCP DH session never delivered hello"
    )
    assert.equals("dh-tcp", hello_received.sid)
    assert.is_true(connect_seen, "connect event must fire on the host after DH")
  end)

  it("encrypted WS session completes DH and carries an application message", function()
    local key = crypto.generate_key()
    local hello_received = nil

    server.setup(function(msg, peer_id)
      if msg.t == "connect" then
        server.approve(peer_id)
        server.send(peer_id, { t = "hello", peer_id = peer_id, sid = "dh-ws", protocol_version = protocol.VERSION })
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 1, key), "server failed to bind")

    client.setup(function(msg)
      if msg.t == "hello" then
        hello_received = msg
      end
    end)
    client.connect("127.0.0.1", BASE_PORT + 1, key, "ws", 0, nil)

    assert.is_true(
      wait_for(function()
        return hello_received ~= nil
      end),
      "encrypted WS DH session never delivered hello"
    )
    assert.equals("dh-ws", hello_received.sid)
  end)
end)

-- ── HMAC tampering: a guest with the wrong PSK can't authenticate ───────────

describe("server rejects mis-authenticated DH attempts", function()
  if not crypto.available or not crypto.x25519_available then
    pending("OpenSSL X25519 unavailable — skipping")
    return
  end

  after_each(function()
    server.stop()
  end)

  it("a client whose dh_accept HMAC does not match the PSK is dropped without `connect`", function()
    local key = crypto.generate_key()
    local connect_event_fired = false

    server.setup(function(msg, _)
      if msg.t == "connect" then
        connect_event_fired = true
      end
    end)
    assert.is_true(server.start("127.0.0.1", BASE_PORT + 2, key), "server failed to bind")

    -- Build a custom raw-TCP "guest" that:
    --   1. sends the 4-byte detection probe;
    --   2. reads the dh_offer;
    --   3. responds with a dh_accept whose HMAC is wrong (computed with a
    --      different PSK).  A real attacker without the URL fragment would
    --      have to do exactly this — fail the HMAC check.
    local tcp = uv.new_tcp()
    local got_offer = nil
    local sent_accept = false

    tcp:connect("127.0.0.1", BASE_PORT + 2, function(err)
      if err then
        return
      end
      tcp:write("\x00\x00\x00\x00")
      local reader = tcp_trans.new_reader()
      tcp:read_start(function(rerr, data)
        if rerr or not data then
          return
        end
        local payloads = reader(data)
        if not payloads then
          return
        end
        for _, payload in ipairs(payloads) do
          if #payload > 0 and not sent_accept then
            local ok, parsed = pcall(vim.json.decode, payload)
            if ok and parsed and parsed.t == "dh_offer" then
              got_offer = parsed
              -- Forge an accept with a deliberately-wrong HMAC.
              local _, my_pub = crypto.x25519_keypair()
              local wrong_hmac = crypto.hmac_sha256("WRONG-PSK", my_pub)
              local accept = vim.json.encode({
                t = "dh_accept",
                pub = crypto.b64url_encode(my_pub),
                hmac = crypto.b64url_encode(wrong_hmac),
              })
              tcp:write(tcp_trans.frame(accept))
              sent_accept = true
            end
          end
        end
      end)
    end)

    -- Wait for the offer to arrive (so we know we got past detection).
    assert.is_true(
      wait_for(function()
        return got_offer ~= nil
      end),
      "server never sent dh_offer"
    )
    -- Give the server time to reject our forged accept.
    vim.wait(200)
    -- The connect event must NOT have fired — the rejection must happen
    -- before approval reaches host.lua.
    assert.is_false(connect_event_fired, "connect event must not fire for a peer with a bad PSK")

    if not tcp:is_closing() then
      tcp:close()
    end
  end)
end)
