-- SLIP (RFC 1055) framing used by the BAF i6 protocol to delimit protobuf
-- messages on the TCP stream. Ported from aiobafi6/wireutils.py, confirmed
-- against real fan responses during protocol discovery.

local slip = {}

local END = 0xC0
local ESC = 0xDB
local ESC_END = 0xDC
local ESC_ESC = 0xDD

slip.END_BYTE = string.char(END)

--- Escapes any literal 0xC0/0xDB bytes in `payload` and wraps it in 0xC0
--- delimiters.
function slip.encode(payload)
  local out = { string.char(END) }
  for i = 1, #payload do
    local b = string.byte(payload, i)
    if b == END then
      out[#out + 1] = string.char(ESC, ESC_END)
    elseif b == ESC then
      out[#out + 1] = string.char(ESC, ESC_ESC)
    else
      out[#out + 1] = string.char(b)
    end
  end
  out[#out + 1] = string.char(END)
  return table.concat(out)
end

--- Reverses slip.encode: strips the outer 0xC0 delimiters (if present) and
--- un-escapes any 0xDB sequences. `framed` may be a single complete frame
--- with or without the leading/trailing 0xC0 still attached.
function slip.decode(framed)
  local start_i = 1
  local end_i = #framed
  if end_i >= 1 and string.byte(framed, 1) == END then
    start_i = 2
  end
  if end_i >= start_i and string.byte(framed, end_i) == END then
    end_i = end_i - 1
  end

  local out = {}
  local i = start_i
  while i <= end_i do
    local b = string.byte(framed, i)
    if b == ESC then
      i = i + 1
      local nxt = string.byte(framed, i)
      if nxt == ESC_END then
        out[#out + 1] = string.char(END)
      elseif nxt == ESC_ESC then
        out[#out + 1] = string.char(ESC)
      else
        error("slip.decode: invalid emulation prevention sequence")
      end
    else
      out[#out + 1] = string.char(b)
    end
    i = i + 1
  end
  return table.concat(out)
end

return slip
