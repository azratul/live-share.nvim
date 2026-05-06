-- Stage 6 (workspace_info chunking): the host streams the file list as
-- `workspace_info_chunk` messages of up to ~1000 paths each, terminated by
-- `workspace_info_done`.  The guest accumulates chunks into its file list
-- and uses `total_files` from the terminator as a sanity check.
--
-- Coverage:
--   1. Single small workspace: one chunk + done; the file list is preserved
--      and `root_name` arrives on the first chunk only.
--   2. Multi-chunk workspace (>1 chunk): chunks accumulate in order; the
--      reassembled list matches what the host scanned; `root_name` is
--      present only on the first chunk.
--   3. Empty workspace: even with zero files the host still sends one
--      empty chunk + done so the guest's workspace_sync state machine has
--      a deterministic stream to walk.
--   4. `truncated = true` is propagated when the host's scan cap was hit.
--
-- These tests drive a real server↔client TCP+DH session so that the chunk
-- ordering is exercised end-to-end through the encrypted transport.

local crypto = require("live-share.collab.crypto")
local server = require("live-share.collab.server")
local client = require("live-share.collab.client")
local protocol = require("live-share.collab.protocol")

local BASE_PORT = 19980
local TIMEOUT_MS = 4000

local function wait_for(cond)
  return vim.wait(TIMEOUT_MS, cond, 10)
end

-- Drives a one-shot session: the host approves the first connect, sends the
-- given chunk + done sequence, and we collect everything on the guest side.
local function run_session(port_offset, files_to_send, root_name, truncated, chunk_size)
  local key = crypto.generate_key()
  local port = BASE_PORT + port_offset

  -- Track every workspace_info_* message as it arrives on the guest.
  local recvd = {} -- ordered list of {t=..., seq=..., files=..., root_name=..., total_files=..., truncated=...}
  local done_seen = false

  server.setup(function(msg, peer_id)
    if msg.t == "connect" then
      server.approve(peer_id)
      server.send(peer_id, { t = "hello", peer_id = peer_id, sid = "ws6", protocol_version = protocol.VERSION })
      -- Stream the chunks exactly the way host.lua would.
      local total = #files_to_send
      local cs = chunk_size or 1000
      local idx, seq_n = 1, 0
      repeat
        seq_n = seq_n + 1
        local slice = {}
        local upper = math.min(idx + cs - 1, total)
        for i = idx, upper do
          slice[#slice + 1] = files_to_send[i]
        end
        local chunk = { t = "workspace_info_chunk", seq = seq_n, files = slice }
        if seq_n == 1 then
          chunk.root_name = root_name
        end
        server.send(peer_id, chunk)
        idx = upper + 1
      until idx > total
      server.send(peer_id, {
        t = "workspace_info_done",
        total_files = total,
        truncated = truncated and true or false,
      })
    end
  end)
  assert.is_true(server.start("127.0.0.1", port, key), "server failed to bind")

  client.setup(function(msg)
    if msg.t == "workspace_info_chunk" or msg.t == "workspace_info_done" then
      recvd[#recvd + 1] = msg
      if msg.t == "workspace_info_done" then
        done_seen = true
      end
    end
  end)
  client.connect("127.0.0.1", port, key, "tcp", 0, nil)

  assert.is_true(
    wait_for(function()
      return done_seen
    end),
    "workspace_info_done never arrived"
  )

  client.stop()
  server.stop()
  return recvd
end

describe("workspace_info chunking (stage 6)", function()
  if not crypto.available or not crypto.x25519_available then
    pending("OpenSSL X25519 unavailable — skipping")
    return
  end

  it("small workspace: single chunk + done with root_name on chunk #1", function()
    local files = { "src/main.lua", "README.md", "lua/init.lua" }
    local recvd = run_session(0, files, "demo", false, 1000)

    -- 1 chunk + 1 done = 2 messages.
    assert.equals(2, #recvd)

    local c = recvd[1]
    assert.equals("workspace_info_chunk", c.t)
    assert.equals(1, c.seq)
    assert.equals("demo", c.root_name)
    assert.same(files, c.files)

    local d = recvd[2]
    assert.equals("workspace_info_done", d.t)
    assert.equals(3, d.total_files)
    assert.is_false(d.truncated)
  end)

  it("multi-chunk workspace: chunks arrive in order, root_name only on #1", function()
    -- 5 files with chunk_size = 2 → chunks of [2, 2, 1] + done.
    local files = { "a.lua", "b.lua", "c.lua", "d.lua", "e.lua" }
    local recvd = run_session(1, files, "monorepo", false, 2)

    -- 3 chunks + 1 done = 4 messages.
    assert.equals(4, #recvd)

    -- Chunk 1: has root_name, files [a, b], seq=1.
    assert.equals("workspace_info_chunk", recvd[1].t)
    assert.equals(1, recvd[1].seq)
    assert.equals("monorepo", recvd[1].root_name)
    assert.same({ "a.lua", "b.lua" }, recvd[1].files)

    -- Chunk 2: NO root_name, files [c, d], seq=2.
    assert.equals(2, recvd[2].seq)
    assert.is_nil(recvd[2].root_name)
    assert.same({ "c.lua", "d.lua" }, recvd[2].files)

    -- Chunk 3: NO root_name, files [e], seq=3.
    assert.equals(3, recvd[3].seq)
    assert.is_nil(recvd[3].root_name)
    assert.same({ "e.lua" }, recvd[3].files)

    -- Reassembled file list matches input.
    local reassembled = {}
    for i = 1, 3 do
      for _, p in ipairs(recvd[i].files) do
        reassembled[#reassembled + 1] = p
      end
    end
    assert.same(files, reassembled)

    -- Done: total_files = 5.
    assert.equals("workspace_info_done", recvd[4].t)
    assert.equals(5, recvd[4].total_files)
  end)

  it("empty workspace: still sends one empty chunk + done", function()
    local recvd = run_session(2, {}, "empty", false, 1000)

    assert.equals(2, #recvd)
    assert.equals("workspace_info_chunk", recvd[1].t)
    assert.equals(1, recvd[1].seq)
    assert.equals("empty", recvd[1].root_name)
    assert.same({}, recvd[1].files)

    assert.equals("workspace_info_done", recvd[2].t)
    assert.equals(0, recvd[2].total_files)
  end)

  it("truncated = true is propagated when the host's scan cap was hit", function()
    local recvd = run_session(3, { "f1", "f2" }, "huge", true, 1000)
    local d = recvd[#recvd]
    assert.equals("workspace_info_done", d.t)
    assert.is_true(d.truncated)
  end)
end)
