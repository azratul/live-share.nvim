-- Per-peer token-bucket rate limiter.
--
-- Defends against a malicious or buggy guest spamming patches/cursors and
-- saturating the host's main loop.  Each peer gets an independent bucket per
-- message kind; a bucket refills at `rate` tokens/sec up to a capacity of
-- `rate` (a 1-second burst).  Extracted from server.lua so the limiting policy
-- is testable and tunable in isolation from the transport code.
--
-- The default limits are generous enough for normal interactive editing (a
-- fast typist generates ~10 patches/s; cursor moves are debounced at 100 ms
-- ≈ 10/s).
local M = {}

local uv = vim.uv or vim.loop

-- kind -> tokens per second per peer.  Kinds not listed here are unlimited.
local RATE_LIMITS = {
  patch = 100, -- patches per second per peer
  cursor = 60, -- cursor updates per second per peer
}

-- peer_id -> { [kind] = { tokens, last_ms } }
local buckets = {}

---Consume a token for `(peer_id, kind)`.  Returns true iff one was available
---(and consumes it); kinds without a configured limit always pass.
---@param peer_id LiveShare.PeerId
---@param kind string message kind (e.g. "patch", "cursor")
---@return boolean allowed
function M.allow(peer_id, kind)
  local rate = RATE_LIMITS[kind]
  if not rate then
    return true
  end
  local now = uv.now()
  buckets[peer_id] = buckets[peer_id] or {}
  local bucket = buckets[peer_id][kind]
  if not bucket then
    bucket = { tokens = rate, last_ms = now }
    buckets[peer_id][kind] = bucket
  end
  local elapsed = now - bucket.last_ms
  if elapsed > 0 then
    bucket.tokens = math.min(rate, bucket.tokens + elapsed * rate / 1000)
    bucket.last_ms = now
  end
  if bucket.tokens >= 1 then
    bucket.tokens = bucket.tokens - 1
    return true
  end
  return false
end

---Drop all buckets for a peer (call on disconnect/kick).
---@param peer_id LiveShare.PeerId
function M.forget(peer_id)
  buckets[peer_id] = nil
end

---Drop every peer's buckets (call on server stop).
function M.reset()
  buckets = {}
end

return M
