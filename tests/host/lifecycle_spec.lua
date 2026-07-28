-- Regression tests for the host session lifecycle around `nvim_buf_attach`.
--
-- Buffer attachments are NOT autocmds: `nvim_clear_autocmds` does not remove
-- them and there is no detach API — the callback has to return true to retire
-- itself.  M.stop() therefore bumps a generation counter that each attachment
-- captured at attach time.
--
-- Coverage:
--   1. Editing a tracked buffer after :LiveShareStop does not raise
--      "attempt to index upvalue 'conn' (a nil value)".
--   2. A stop/start cycle does not leave the old attachment live, which would
--      broadcast every subsequent patch twice.
--   3. The retiring stale attachment's on_detach does not untrack a buffer the
--      restarted session is still sharing.

local connection = require("live-share.collab.connection")
local host = require("live-share.host")

-- Fake listener installed over connection.new_listener.  host.lua calls it
-- through the module table, so replacing the field is enough — no sockets.
local function install_fake_listener(broadcasts)
  local original = connection.new_listener
  connection.new_listener = function()
    return {
      listen = function()
        return true
      end,
      stop = function() end,
      broadcast = function(_, msg)
        broadcasts[#broadcasts + 1] = msg
      end,
      set_role = function() end,
      get_role = function()
        return "rw"
      end,
    }
  end
  return function()
    connection.new_listener = original
  end
end

describe("host lifecycle: buffer attachments", function()
  local broadcasts, restore, tmpfile, buf

  before_each(function()
    broadcasts = {}
    restore = install_fake_listener(broadcasts)

    tmpfile = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "line one" }, tmpfile)
    vim.cmd("edit " .. vim.fn.fnameescape(tmpfile))
    buf = vim.api.nvim_get_current_buf()

    host.setup({ username = "test", ip_local = "127.0.0.1", port_internal = 19876, transport = "ws" })
  end)

  after_each(function()
    host.stop()
    restore()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.fn.delete(tmpfile)
  end)

  local function patches()
    local out = {}
    for _, m in ipairs(broadcasts) do
      if m.t == "patch" then
        out[#out + 1] = m
      end
    end
    return out
  end

  it("editing a tracked buffer after stop does not error", function()
    assert.is_true(host.start(19876))
    -- Sanity: while the session is live, an edit does broadcast.
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "during session" })
    assert.equals(1, #patches())

    host.stop()

    -- This is the reported crash: the attachment outlives the session and
    -- reaches for `conn`, which stop() set to nil.
    local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 1, 1, false, { "after stop" })
    assert.is_true(ok, "editing after stop raised: " .. tostring(err))
    -- And nothing new was sent.
    assert.equals(1, #patches())
  end)

  it("does not broadcast twice after a stop/start cycle", function()
    assert.is_true(host.start(19876))
    host.stop()

    broadcasts = {}
    restore()
    restore = install_fake_listener(broadcasts)

    assert.is_true(host.start(19876))
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "second session" })

    -- The stale attachment from the first session must have retired instead of
    -- emitting a duplicate patch alongside the live one.
    assert.equals(1, #patches())
  end)

  it("keeps tracking the buffer after the stale attachment retires", function()
    assert.is_true(host.start(19876))
    host.stop()

    broadcasts = {}
    restore()
    restore = install_fake_listener(broadcasts)

    assert.is_true(host.start(19876))
    -- First edit is the one that retires the stale attachment; its on_detach
    -- must not clear the entry the live session just created.
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "first" })
    vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "second" })

    assert.equals(2, #patches())
  end)
end)
