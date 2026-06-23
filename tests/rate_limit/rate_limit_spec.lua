-- Unit tests for lua/live-share/collab/rate_limit.lua
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"

local rate_limit = require("live-share.collab.rate_limit")

describe("rate_limit token bucket", function()
  after_each(function()
    rate_limit.reset()
  end)

  it("never throttles a kind without a configured limit", function()
    for _ = 1, 1000 do
      assert.is_true(rate_limit.allow(1, "unknown_kind"))
    end
  end)

  it("permits a burst up to the cap, then throttles", function()
    -- cursor cap is 60/s; in a tight synchronous loop the libuv clock does not
    -- advance, so the bucket never refills: exactly the capacity passes.
    local allowed = 0
    for _ = 1, 200 do
      if rate_limit.allow(1, "cursor") then
        allowed = allowed + 1
      end
    end
    assert.is_true(allowed >= 60, "expected >= 60 allowed, got " .. allowed)
    assert.is_true(allowed <= 75, "expected <= 75 allowed, got " .. allowed)
  end)

  it("tracks peers independently", function()
    for _ = 1, 200 do
      rate_limit.allow(1, "cursor")
    end
    -- peer 2 has its own full bucket.
    assert.is_true(rate_limit.allow(2, "cursor"))
  end)

  it("forget() restores a single peer's bucket", function()
    for _ = 1, 200 do
      rate_limit.allow(1, "cursor")
    end
    assert.is_false(rate_limit.allow(1, "cursor"))
    rate_limit.forget(1)
    assert.is_true(rate_limit.allow(1, "cursor"))
  end)

  it("reset() clears every peer's bucket", function()
    for _ = 1, 200 do
      rate_limit.allow(1, "cursor")
    end
    rate_limit.reset()
    assert.is_true(rate_limit.allow(1, "cursor"))
  end)
end)
