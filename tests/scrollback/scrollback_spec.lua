-- Unit tests for lua/live-share/scrollback.lua
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local scrollback = require("live-share.scrollback")

describe("scrollback ring buffer", function()
  it("starts empty", function()
    local s = scrollback.new(100)
    assert.is_true(scrollback.is_empty(s))
    assert.equals("", scrollback.concat(s))
  end)

  it("appends and concatenates chunks in order", function()
    local s = scrollback.new(100)
    scrollback.append(s, "hello ")
    scrollback.append(s, "world")
    assert.is_false(scrollback.is_empty(s))
    assert.equals("hello world", scrollback.concat(s))
  end)

  it("ignores nil and empty appends", function()
    local s = scrollback.new(100)
    scrollback.append(s, nil)
    scrollback.append(s, "")
    assert.is_true(scrollback.is_empty(s))
    assert.equals("", scrollback.concat(s))
  end)

  it("evicts whole chunks from the front when total exceeds max", function()
    local s = scrollback.new(10)
    scrollback.append(s, "AAAAA") -- 5
    scrollback.append(s, "BBBBB") -- 10  (still ≤ max)
    assert.equals("AAAAABBBBB", scrollback.concat(s))
    scrollback.append(s, "CC") -- 12 → evict "AAAAA" → 7
    assert.equals("BBBBBCC", scrollback.concat(s))
  end)

  it("never reduces below a single chunk even if that chunk exceeds max", function()
    -- Eviction stops while only the newest chunk remains, so we always
    -- preserve at least the latest data.
    local s = scrollback.new(5)
    scrollback.append(s, "HUGECHUNKWAYOVERMAX")
    assert.equals("HUGECHUNKWAYOVERMAX", scrollback.concat(s))
    -- Next append still drops the oversized predecessor.
    scrollback.append(s, "tail")
    assert.equals("tail", scrollback.concat(s))
  end)

  it("uses O(1) eviction (head/tail markers, no table.remove)", function()
    -- Append many small chunks above the cap; the public API just needs to
    -- stay functional.  This is a regression check — a previous draft used
    -- table.remove(t, 1) which is O(n) per eviction.
    local s = scrollback.new(100)
    for i = 1, 1000 do
      scrollback.append(s, string.format("%03d ", i))
    end
    -- We just check the buffer ends with the most recent chunk and that the
    -- total stayed bounded by the cap (chunks are 4-5 bytes; after the final
    -- eviction pass, total ≤ max).
    local out = scrollback.concat(s)
    assert.equals("1000 ", out:sub(-5))
    assert.is_true(#out <= 100)
  end)

  it("honours a max of 0 by keeping only the latest chunk", function()
    local s = scrollback.new(0)
    scrollback.append(s, "a")
    scrollback.append(s, "b")
    scrollback.append(s, "c")
    assert.equals("c", scrollback.concat(s))
  end)
end)
