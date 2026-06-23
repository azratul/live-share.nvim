-- Unit tests for lua/live-share/guest/dispatch.lua
--
-- The dispatch module takes an explicit `ctx` (live connection + shared
-- `gstate`), so the state gate and per-type handlers can be driven directly.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local dispatch = require("live-share.guest.dispatch")
local session = require("live-share.session")
local protocol = require("live-share.collab.protocol")

-- Build a fake guest context with a recording connection and a fresh gstate.
local function make_ctx(state)
  local rec = { sent = {}, stopped = false, autocmds = {} }
  local gstate = {
    state = state or "active",
    guest_role = nil,
    workspace_files = {},
    workspace_root_name = nil,
    ws_chunks_seen = 0,
    msg_buffer = {},
    sync_timer = nil,
    last_seq_seen = nil,
  }
  local ctx = {
    conn = {
      send = function(_, msg)
        rec.sent[#rec.sent + 1] = msg
      end,
    },
    gstate = gstate,
    get_username = function()
      return "guest"
    end,
    register_autocmds = function(_buf, path)
      rec.autocmds[#rec.autocmds + 1] = path
    end,
    stop = function()
      rec.stopped = true
    end,
  }
  return ctx, rec, gstate
end

describe("guest dispatch", function()
  after_each(function()
    session.reset()
  end)

  describe("state gate", function()
    it("ignores non-hello messages during handshake", function()
      local ctx, rec, g = make_ctx("handshake")
      dispatch.handle(ctx, { t = "patch", path = "a.lua", seq = 1, lnum = 0, count = 0, lines = {} })
      assert.equals(0, #rec.sent)
      assert.equals(0, #g.msg_buffer)
    end)

    it("buffers application messages during workspace_sync", function()
      local ctx, _, g = make_ctx("workspace_sync")
      dispatch.handle(ctx, { t = "patch", path = "a.lua", seq = 1, lnum = 0, count = 0, lines = {} })
      dispatch.handle(ctx, { t = "cursor", path = "a.lua", lnum = 0, col = 0 })
      assert.equals(2, #g.msg_buffer)
    end)

    it("lets init/safety messages through during workspace_sync", function()
      local ctx, _, g = make_ctx("workspace_sync")
      dispatch.handle(ctx, { t = "workspace_info_chunk", seq = 1, files = { "a.lua" }, root_name = "proj" })
      assert.equals(0, #g.msg_buffer)
      assert.equals(1, #g.workspace_files)
    end)
  end)

  describe("workspace chunk accumulation", function()
    it("resets on seq 1 and appends on later chunks", function()
      local ctx, _, g = make_ctx("active")
      dispatch.handle(ctx, { t = "workspace_info_chunk", seq = 1, files = { "a.lua", "b.lua" }, root_name = "proj" })
      dispatch.handle(ctx, { t = "workspace_info_chunk", seq = 2, files = { "c.lua" } })
      assert.same({ "a.lua", "b.lua", "c.lua" }, g.workspace_files)
      assert.equals("proj", g.workspace_root_name)
      assert.equals(2, g.ws_chunks_seen)
    end)
  end)

  describe("patch seq tracking", function()
    it("drops a stale or duplicate patch", function()
      local ctx, rec, g = make_ctx("active")
      g.last_seq_seen = 6
      dispatch.handle(ctx, { t = "patch", path = "a.lua", seq = 6, lnum = 0, count = 0, lines = {} })
      assert.equals(0, #rec.sent)
      assert.equals(6, g.last_seq_seen)
    end)

    it("requests a resync on a seq gap", function()
      local ctx, rec, g = make_ctx("active")
      g.last_seq_seen = 6
      dispatch.handle(ctx, { t = "patch", path = "a.lua", seq = 8, lnum = 0, count = 0, lines = {} })
      assert.equals(1, #rec.sent)
      assert.equals("file_request", rec.sent[1].t)
      assert.equals("a.lua", rec.sent[1].path)
      assert.is_nil(g.last_seq_seen) -- reset until the snapshot arrives
    end)

    it("advances last_seq_seen for an in-order patch", function()
      local ctx, _, g = make_ctx("active")
      g.last_seq_seen = 6
      dispatch.handle(ctx, { t = "patch", path = "a.lua", seq = 7, lnum = 0, count = 0, lines = {} })
      assert.equals(7, g.last_seq_seen)
    end)
  end)

  describe("hello", function()
    it("disconnects on a protocol version mismatch", function()
      local ctx, rec = make_ctx("handshake")
      dispatch.handle(
        ctx,
        { t = "hello", protocol_version = protocol.VERSION + 99, peer_id = 1, sid = "x", role = "rw" }
      )
      assert.is_true(rec.stopped)
    end)

    it("acknowledges and enters workspace_sync on a matching version", function()
      local ctx, rec, g = make_ctx("handshake")
      dispatch.handle(
        ctx,
        { t = "hello", protocol_version = protocol.VERSION, peer_id = 2, sid = "sid1", role = "ro", host_name = "h" }
      )
      assert.equals("workspace_sync", g.state)
      assert.equals("ro", g.guest_role)
      assert.equals(2, session.peer_id)

      local acked = false
      for _, m in ipairs(rec.sent) do
        if m.t == "hello_ack" then
          acked = true
        end
      end
      assert.is_true(acked)

      -- Clean up the 10 s watchdog timer the handler started.
      if g.sync_timer then
        g.sync_timer:stop()
        g.sync_timer:close()
        g.sync_timer = nil
      end
    end)
  end)
end)
