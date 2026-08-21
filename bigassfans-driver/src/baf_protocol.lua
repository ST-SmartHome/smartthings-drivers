-- Builds and parses BAF i6 API messages (aiobafi6.proto), which are
-- SLIP-framed (see slip.lua) protobuf-encoded (see protobuf.lua) messages
-- exchanged over a plain TCP connection to port 31415. No authentication,
-- no encryption — confirmed empirically against two real Haiku H/I Series
-- fans (firmware 3.3.7, api_version 8).
--
-- IMPORTANT, confirmed by direct probing, not from any doc: despite its
-- name, `ProperyQuery.ALL` does NOT return every property — only the
-- general/identity ones (model, firmware_version, mac_address, ...). Fan
-- and light state must be queried with their own category codes. Every
-- integration reading this driver's code should query FAN and LIGHT
-- separately, never rely on ALL to cover them.
--
-- Wire schema (relevant subset of aiobafi6.proto):
--   Root       { root2 = 2 }
--   Root2      { commit = 2, query = 3, query_result = 4 }
--   Commit     { properties = 3 }
--   Query      { property_query = 1 }
--   QueryResult{ properties = 2 (repeated) }
--   Properties { see FIELDS below }
--
-- The fan splits its query reply into many small single/few-field
-- Properties chunks rather than one large message — confirmed empirically.
-- Fields that are at their zero value (false / OFF / 0) are often omitted
-- entirely rather than sent explicitly — also confirmed empirically (an
-- ON fan at 100% still didn't send reverse_enable or whoosh_enable, both
-- false). baf.parse_category_result fills in defaults for any known field
-- of the queried category that didn't appear in the reply.

local pb = require "protobuf"

local baf = {}

baf.QUERY_CATEGORY = {
  ALL = 0, -- general/identity only, despite the name
  FAN = 1,
  LIGHT = 2,
  FIRMWARE_MORE_DATETIME_API = 3,
  NETWORK = 4,
  SCHEDULES = 5,
  SENSORS = 6,
}

baf.OFF_ON_AUTO = { OFF = 0, ON = 1, AUTO = 2 }

-- Field numbers this driver reads/writes, per aiobafi6.proto's Properties
-- message, grouped by which query category returns them (used to know
-- which defaults to fill in per category — see parse_category_result).
-- kind: "string" | "bool" | "int" | "enum" (enum decodes to a raw int,
-- same as "int" — the distinction is documentation, not different code).
baf.FIELDS = {
  -- ALL (general/identity)
  name             = { no = 1,  kind = "string", category = "ALL" },
  model            = { no = 2,  kind = "string", category = "ALL" },
  firmware_version = { no = 7,  kind = "string", category = "ALL" },
  mac_address      = { no = 8,  kind = "string", category = "ALL" },
  api_version      = { no = 13, kind = "string", category = "ALL" },

  -- FAN
  fan_mode       = { no = 43, kind = "enum", category = "FAN", default = 0 },
  reverse_enable = { no = 44, kind = "bool", category = "FAN", default = false },
  speed_percent  = { no = 45, kind = "int",  category = "FAN", default = 0 },
  speed          = { no = 46, kind = "int",  category = "FAN", default = 0 },
  whoosh_enable  = { no = 58, kind = "bool", category = "FAN", default = false },
  eco_enable     = { no = 65, kind = "bool", category = "FAN", default = false },
  current_rpm    = { no = 64, kind = "int",  category = "FAN", default = 0 },

  -- LIGHT (color temperature intentionally not modeled — the Haiku H/I
  -- Series bulb is fixed-temperature, warmest == coolest == 2700K,
  -- confirmed via a real LIGHT query; the physical remote has no color
  -- temp control either)
  light_mode               = { no = 68, kind = "enum", category = "LIGHT", default = 0 },
  light_brightness_percent = { no = 69, kind = "int",  category = "LIGHT", default = 0 },
}

local FIELD_BY_NO = {}
for name, def in pairs(baf.FIELDS) do
  FIELD_BY_NO[def.no] = name
end

--- Serializes Root{ root2: Root2{ query: Query{ property_query: category } } }.
--- `category` is one of baf.QUERY_CATEGORY's values. Returns raw protobuf
--- bytes (not yet SLIP-framed — see slip.lua / baf_client.lua).
function baf.build_query(category)
  local query = pb.encode_varint_field(1, category)
  local root2 = pb.encode_bytes_field(3, query)
  return pb.encode_bytes_field(2, root2)
end

--- Serializes Root{ root2: Root2{ commit: Commit{ properties: Properties{...} } } }
--- for setting one or more properties. `props` is { field_name = value },
--- using the same names as baf.FIELDS; booleans as true/false, enums/ints
--- as their integer value. Returns raw protobuf bytes.
function baf.build_commit(props)
  local props_bytes = {}
  for name, value in pairs(props) do
    local def = baf.FIELDS[name]
    if not def then
      error("baf.build_commit: unknown property '" .. tostring(name) .. "'")
    end
    if def.kind == "string" then
      props_bytes[#props_bytes + 1] = pb.encode_bytes_field(def.no, value)
    elseif def.kind == "bool" then
      props_bytes[#props_bytes + 1] = pb.encode_varint_field(def.no, value and 1 or 0)
    else -- "int" or "enum"
      props_bytes[#props_bytes + 1] = pb.encode_varint_field(def.no, value)
    end
  end
  local properties = table.concat(props_bytes)
  local commit = pb.encode_bytes_field(3, properties)
  local root2 = pb.encode_bytes_field(2, commit)
  return pb.encode_bytes_field(2, root2)
end

local function decode_field_value(def, raw)
  if def.kind == "string" then
    return raw
  elseif def.kind == "bool" then
    return raw ~= 0
  else -- "int" or "enum"
    return raw
  end
end

--- Parses a full Root message (already SLIP-decoded raw bytes) received
--- from the fan and returns a flat table { field_name = value, ... },
--- merging every repeated Properties chunk in the QueryResult.
--- `category` (a baf.QUERY_CATEGORY name, e.g. "FAN") is used to fill in
--- defaults for known fields of that category that the fan omitted
--- because they're at their zero value. Returns nil if the message
--- doesn't contain a query_result at all (e.g. it was something else).
function baf.parse_category_result(payload, category)
  local root_fields = pb.parse_fields(payload)
  local root2_bytes = pb.last(root_fields, 2)
  if not root2_bytes then
    return nil
  end
  local root2_fields = pb.parse_fields(root2_bytes)
  local qr_bytes = pb.last(root2_fields, 4)
  if not qr_bytes then
    return nil
  end
  local qr_fields = pb.parse_fields(qr_bytes)

  local result = {}
  for name, def in pairs(baf.FIELDS) do
    if def.category == category and def.default ~= nil then
      result[name] = def.default
    end
  end

  for _, entry in ipairs(qr_fields[2] or {}) do
    local chunk_fields = pb.parse_fields(entry[2])
    for field_no, occurrences in pairs(chunk_fields) do
      local name = FIELD_BY_NO[field_no]
      if name then
        local def = baf.FIELDS[name]
        local _, raw = table.unpack(occurrences[#occurrences])
        result[name] = decode_field_value(def, raw)
      end
    end
  end
  return result
end

return baf
