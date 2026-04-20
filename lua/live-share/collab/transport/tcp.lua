-- Raw TCP transport: 4-byte little-endian length-prefix framing.
--
-- Interface:
--   frame(payload)  → framed bytes ready to write to a TCP socket
--   new_reader()    → stateful fn(chunk) → { payload, ... }
--
-- The reader handles TCP fragmentation and delivers complete binary payloads.
-- Message decoding (JSON + crypto) is done by the caller (protocol.lua).
local M = {}

local function len_prefix(s)
  local n = #s
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
    .. s
end

function M.frame(payload)
  return len_prefix(payload)
end

-- Returns a stateful decoder that handles TCP fragmentation.
-- Call reader(chunk) → list of complete binary payloads.
function M.new_reader()
  local buf = ""
  return function(data)
    buf = buf .. data
    local payloads = {}
    while #buf >= 4 do
      local b1, b2, b3, b4 = buf:byte(1, 4)
      local len = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
      if #buf < 4 + len then
        break
      end
      table.insert(payloads, buf:sub(5, 4 + len))
      buf = buf:sub(5 + len)
    end
    return payloads
  end
end

return M
