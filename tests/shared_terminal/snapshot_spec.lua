-- Unit tests for shared_terminal.snapshot_for() — the scrollback replay sent
-- to peers approved after a terminal was opened.  Uses the test hooks
-- (_test_seed_terminal / _test_record) to avoid spawning a real PTY shell.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local shared = require("live-share.shared_terminal")

local function collect()
  local msgs = {}
  return msgs, function(m)
    msgs[#msgs + 1] = m
  end
end

describe("shared_terminal.snapshot_for()", function()
  before_each(function()
    shared.stop()
    shared.setup("host", function() end)
  end)

  after_each(function()
    shared.stop()
  end)

  it("emits nothing when no terminals are open", function()
    local msgs, send = collect()
    shared.snapshot_for(send)
    assert.equals(0, #msgs)
  end)

  it("emits terminal_open for each open terminal", function()
    shared._test_seed_terminal(1, "/bin/bash")
    shared._test_seed_terminal(2, "/usr/bin/zsh")

    local msgs, send = collect()
    shared.snapshot_for(send)

    local opens = {}
    for _, m in ipairs(msgs) do
      if m.t == "terminal_open" then
        opens[m.term_id] = m.name
      end
    end
    assert.equals("/bin/bash", opens[1])
    assert.equals("/usr/bin/zsh", opens[2])
  end)

  it("emits terminal_data with concatenated scrollback after terminal_open", function()
    shared._test_seed_terminal(7, "sh")
    shared._test_record(7, "$ echo hi\n")
    shared._test_record(7, "hi\n")
    shared._test_record(7, "$ ")

    local msgs, send = collect()
    shared.snapshot_for(send)

    -- terminal_open must precede terminal_data for the same term_id, otherwise
    -- the guest discards the data (no buffer to render into).
    local seen_open, seen_data = false, false
    for _, m in ipairs(msgs) do
      if m.t == "terminal_open" and m.term_id == 7 then
        seen_open = true
      elseif m.t == "terminal_data" and m.term_id == 7 then
        assert.is_true(seen_open, "terminal_data arrived before terminal_open")
        assert.equals("$ echo hi\nhi\n$ ", m.data)
        seen_data = true
      end
    end
    assert.is_true(seen_open)
    assert.is_true(seen_data)
  end)

  it("does not emit terminal_data when scrollback is empty", function()
    shared._test_seed_terminal(3, "sh")

    local msgs, send = collect()
    shared.snapshot_for(send)

    local data_count = 0
    for _, m in ipairs(msgs) do
      if m.t == "terminal_data" then
        data_count = data_count + 1
      end
    end
    assert.equals(0, data_count)
  end)

  it("respects scrollback_bytes set via setup()", function()
    shared.stop()
    shared.setup("host", function() end, { scrollback_bytes = 8 })
    shared._test_seed_terminal(1, "sh")
    shared._test_record(1, "AAAA") -- 4
    shared._test_record(1, "BBBB") -- 8 (still at cap)
    shared._test_record(1, "CC") -- 10 → evict AAAA → 6

    local msgs, send = collect()
    shared.snapshot_for(send)

    local data
    for _, m in ipairs(msgs) do
      if m.t == "terminal_data" then
        data = m.data
      end
    end
    assert.equals("BBBBCC", data)
  end)

  it("stop() clears terminals so no snapshot is emitted afterwards", function()
    shared._test_seed_terminal(1, "sh")
    shared._test_record(1, "stuff")
    shared.stop()
    -- Re-setup so snapshot_for has a clean state to operate against.
    shared.setup("host", function() end)

    local msgs, send = collect()
    shared.snapshot_for(send)
    assert.equals(0, #msgs)
  end)
end)
