--- Standard CRC-32 (IEEE 802.3 / zlib polynomial 0xEDB88320), table-based.
--- Tuya's protocol versions 3.1-3.3 use this to checksum each message frame.
--- Not cryptographic — just a standard, well-known checksum algorithm.

local CRC32 = {}

local crc_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if c % 2 == 1 then
      c = 0xEDB88320 ~ (c >> 1)
    else
      c = c >> 1
    end
  end
  crc_table[i] = c
end

--- Computes CRC32 over a Lua string (byte string). Returns an unsigned 32-bit integer.
function CRC32.compute(data)
  local crc = 0xFFFFFFFF
  for i = 1, #data do
    local byte = string.byte(data, i)
    crc = crc_table[(crc ~ byte) & 0xFF] ~ (crc >> 8)
  end
  return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

return CRC32
