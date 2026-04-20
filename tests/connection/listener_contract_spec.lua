-- Contract test: every listener implementation must expose the same public API.
--
-- This catches the class of bug where a parallel implementation (e.g. punch_conn.lua)
-- adds a method to server.lua but forgets to mirror it in the alternative backend.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local connection = require("live-share.collab.connection")

local REQUIRED_METHODS = {
  "listen",
  "send",
  "broadcast",
  "approve",
  "reject",
  "set_role",
  "set_name",
  "stop",
}

describe("listener interface contract", function()
  it("new_listener exposes all required methods", function()
    local conn = connection.new_listener({ on_msg = function() end })
    for _, m in ipairs(REQUIRED_METHODS) do
      assert.is_function(conn[m], "new_listener is missing method: " .. m)
    end
  end)

  it("new_punch_listener exposes all required methods", function()
    local ok, conn = pcall(connection.new_punch_listener, { on_msg = function() end })
    if not ok then
      pending("punch not installed — skipping punch listener contract check")
      return
    end
    for _, m in ipairs(REQUIRED_METHODS) do
      assert.is_function(conn[m], "new_punch_listener is missing method: " .. m)
    end
    conn:stop()
  end)
end)
