-- Unit tests for lua/live-share/host/dispatch.lua
--
-- The dispatch module takes an explicit `ctx`, so handlers can be driven with a
-- fake connection that records send/broadcast calls — no live sockets needed.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local dispatch = require("live-share.host.dispatch")
local workspace = require("live-share.workspace")
local audit = require("live-share.audit")
local presence = require("live-share.presence")
local session = require("live-share.session")

-- Build a fake host context that records everything the handlers do.
local function make_ctx()
  local rec = { sent = {}, broadcast = {}, names = {}, approved = {}, roles = {} }
  local seq = 0
  local ctx = {
    conn = {
      send = function(_, peer_id, msg)
        rec.sent[#rec.sent + 1] = { peer = peer_id, msg = msg }
      end,
      broadcast = function(_, msg, except)
        rec.broadcast[#rec.broadcast + 1] = { msg = msg, except = except }
      end,
      set_name = function(_, peer_id, name)
        rec.names[peer_id] = name
      end,
      approve = function(_, peer_id)
        rec.approved[#rec.approved + 1] = peer_id
      end,
      set_role = function(_, peer_id, role)
        rec.roles[peer_id] = role
      end,
      reject = function(_, peer_id, msg)
        rec.sent[#rec.sent + 1] = { peer = peer_id, msg = msg, rejected = true }
      end,
    },
    tracked = {},
    get_username = function()
      return "host"
    end,
    next_seq = function()
      seq = seq + 1
      return seq
    end,
  }
  return ctx, rec
end

describe("host dispatch", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    workspace.setup({})
    workspace.set_root(root)
    audit.setup({ audit_log = false }) -- keep the audit log a no-op
    presence.clear_all()
  end)

  after_each(function()
    workspace.set_root(nil)
    presence.clear_all()
    session.reset()
  end)

  it("stamps a monotonic seq and broadcasts a patch", function()
    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "patch", path = "a.lua", lnum = 0, count = 0, lines = { "hi" } }, 3)
    assert.equals(1, #rec.broadcast)
    local b = rec.broadcast[1]
    assert.equals("patch", b.msg.t)
    assert.equals(1, b.msg.seq)
    assert.equals(3, b.msg.peer) -- authoritative sender id
    assert.equals(3, b.except) -- not echoed back to the sender

    dispatch.handle(ctx, { t = "patch", path = "a.lua", lnum = 1, count = 0, lines = { "yo" } }, 3)
    assert.equals(2, rec.broadcast[2].msg.seq)
  end)

  it("rejects a patch targeting a sensitive file", function()
    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "patch", path = ".env", lnum = 0, count = 0, lines = { "secret" } }, 1)
    assert.equals(0, #rec.broadcast)
  end)

  it("rejects any message whose path fails the sandbox gate", function()
    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "cursor", path = "../etc/passwd", lnum = 0, col = 0 }, 1)
    assert.equals(0, #rec.broadcast)
  end)

  it("broadcasts a cursor with the authoritative peer id", function()
    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "cursor", path = "a.lua", lnum = 2, col = 1, name = "g" }, 7)
    assert.equals(1, #rec.broadcast)
    assert.equals("cursor", rec.broadcast[1].msg.t)
    assert.equals(7, rec.broadcast[1].msg.peer)
  end)

  it("broadcasts focus and bye with the sender id", function()
    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "focus", path = "a.lua", name = "g" }, 5)
    dispatch.handle(ctx, { t = "bye", name = "g" }, 5)
    assert.equals("focus", rec.broadcast[1].msg.t)
    assert.equals(5, rec.broadcast[1].msg.peer)
    assert.equals("bye", rec.broadcast[2].msg.t)
    assert.equals(5, rec.broadcast[2].msg.peer)
  end)

  it("serves an existing workspace file on file_request", function()
    local fd = assert(io.open(root .. "/hello.lua", "w"))
    fd:write("line1\nline2\n")
    fd:close()

    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "file_request", path = "hello.lua", req_id = 9 }, 2)
    assert.equals(1, #rec.sent)
    assert.equals("file_response", rec.sent[1].msg.t)
    assert.same({ "line1", "line2" }, rec.sent[1].msg.lines)
    assert.equals(9, rec.sent[1].msg.req_id)
  end)

  it("returns an error for a missing file_request", function()
    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "file_request", path = "nope.lua", req_id = 1 }, 2)
    assert.equals(1, #rec.sent)
    assert.equals("error", rec.sent[1].msg.t)
    assert.equals("file_not_found", rec.sent[1].msg.code)
  end)

  it("refuses to serve a sensitive file_request", function()
    local fd = assert(io.open(root .. "/.env", "w"))
    fd:write("SECRET=1\n")
    fd:close()

    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "file_request", path = ".env", req_id = 1 }, 2)
    -- The sandbox gate rejects the path before the handler runs.
    assert.equals(0, #rec.sent)
  end)

  it("records the guest name on hello_ack", function()
    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "hello_ack", name = "alice" }, 4)
    assert.equals("alice", rec.names[4])
  end)

  it("ignores unknown message types", function()
    local ctx, rec = make_ctx()
    dispatch.handle(ctx, { t = "totally_unknown" }, 1)
    assert.equals(0, #rec.broadcast)
    assert.equals(0, #rec.sent)
  end)
end)
