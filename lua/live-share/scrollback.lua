-- Bounded ring buffer of byte chunks.
--
-- Stores append-only chunks (Lua strings) and evicts whole chunks from the
-- front when the cumulative byte count exceeds `max`.  Whole-chunk eviction
-- avoids cutting mid-codepoint or mid-ANSI-escape, which would render badly on
-- a vt100 terminal emulator.  A modern shell redraws on any input, so a
-- truncated start of buffer is recoverable in practice.
--
-- A head/tail index is used instead of `table.remove(t, 1)` so eviction is
-- O(1) rather than O(n).  `table.concat` honours the i,j range, so the live
-- chunks are concatenated without copying the dropped ones.
local M = {}

function M.new(max)
  return { head = 1, tail = 0, total = 0, max = max or 65536 }
end

function M.append(s, data)
  if not data or data == "" then
    return
  end
  s.tail = s.tail + 1
  s[s.tail] = data
  s.total = s.total + #data
  while s.total > s.max and s.head < s.tail do
    s.total = s.total - #s[s.head]
    s[s.head] = nil
    s.head = s.head + 1
  end
end

function M.concat(s)
  if s.head > s.tail then
    return ""
  end
  return table.concat(s, "", s.head, s.tail)
end

function M.is_empty(s)
  return s.head > s.tail
end

return M
