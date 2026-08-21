-- Minimal protobuf wire-format encoder/decoder — just enough to build and
-- parse the small, fixed set of BAF i6 API messages (aiobafi6.proto).
-- Not a general protobuf library: no support for packed repeated scalars,
-- groups, or 32/64-bit fixed types beyond raw pass-through, none of which
-- the BAF schema uses.

local pb = {}

--- Encodes a non-negative integer as a protobuf base-128 varint.
--- BAF's schema never needs negative varints for the fields this driver
--- reads/writes (enums and small non-negative counts/percentages), so this
--- intentionally does not implement 10-byte sign-extended varints.
function pb.encode_varint(n)
  assert(n >= 0, "encode_varint: negative values not supported")
  local out = {}
  repeat
    local b = n & 0x7F
    n = n >> 7
    if n ~= 0 then
      b = b | 0x80
    end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

--- Decodes a varint starting at 1-based position `pos` in `buf`.
--- Returns value, next_pos.
function pb.decode_varint(buf, pos)
  local result = 0
  local shift = 0
  while true do
    local b = string.byte(buf, pos)
    pos = pos + 1
    result = result | ((b & 0x7F) << shift)
    if (b & 0x80) == 0 then
      break
    end
    shift = shift + 7
  end
  return result, pos
end

local function encode_tag(field_no, wire_type)
  return pb.encode_varint((field_no << 3) | wire_type)
end

--- Encodes a varint-typed field (wire type 0) — used for enums, bools, and
--- non-negative int32s.
function pb.encode_varint_field(field_no, value)
  return encode_tag(field_no, 0) .. pb.encode_varint(value)
end

--- Encodes a length-delimited field (wire type 2) — used for strings and
--- embedded messages alike (an embedded message is just its serialized
--- bytes passed in as `bytes`).
function pb.encode_bytes_field(field_no, bytes)
  return encode_tag(field_no, 2) .. pb.encode_varint(#bytes) .. bytes
end

--- Parses a flat (non-recursive) protobuf message into
--- { [field_no] = { {wire_type, value}, {wire_type, value}, ... }, ... }
--- `value` is a Lua integer for wire type 0, or a raw byte-string slice for
--- wire type 2. Wire types 1 (64-bit) and 5 (32-bit) are captured as raw
--- byte strings too, in case they ever show up — none of the fields this
--- driver cares about use them.
function pb.parse_fields(buf)
  local fields = {}
  local i = 1
  local len = #buf
  while i <= len do
    local tag
    tag, i = pb.decode_varint(buf, i)
    local field_no = tag >> 3
    local wire_type = tag & 0x7
    local value
    if wire_type == 0 then
      value, i = pb.decode_varint(buf, i)
    elseif wire_type == 2 then
      local field_len
      field_len, i = pb.decode_varint(buf, i)
      value = buf:sub(i, i + field_len - 1)
      i = i + field_len
    elseif wire_type == 1 then
      value = buf:sub(i, i + 7)
      i = i + 8
    elseif wire_type == 5 then
      value = buf:sub(i, i + 3)
      i = i + 4
    else
      error("pb.parse_fields: unsupported wire type " .. tostring(wire_type))
    end
    if not fields[field_no] then
      fields[field_no] = {}
    end
    table.insert(fields[field_no], { wire_type, value })
  end
  return fields
end

--- Convenience: returns the *last* value seen for `field_no` (protobuf
--- semantics — later occurrences of a non-repeated field override earlier
--- ones), or nil if the field wasn't present.
function pb.last(fields, field_no)
  local entries = fields[field_no]
  if not entries then
    return nil
  end
  return entries[#entries][2]
end

return pb
