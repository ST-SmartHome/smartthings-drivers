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
  -- uuid9/dns_sd_uuid: present in the public jfroy/aiobafi6 reference
  -- schema but never previously modeled here. dns_sd_uuid is the same
  -- uuid discovery_mdns.lua already reads from the fan's mDNS TXT record
  -- to build a stable DNI -- confirmed identical via a real probe (field
  -- 10's value matched a real fan's DNI-embedded uuid exactly). Modeling
  -- it here means a future feature could cross-check "is this the fan I
  -- think it is" over the protocol connection itself, without depending
  -- on mDNS still being reachable at read time -- not used for that yet,
  -- just available. uuid9's exact purpose vs. dns_sd_uuid isn't explained
  -- anywhere in the reference schema; both are real, distinct UUID
  -- strings on a live fan, not the same value as each other.
  uuid9            = { no = 9,  kind = "string", category = "ALL" },
  dns_sd_uuid      = { no = 10, kind = "string", category = "ALL" },
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

  -- SENSORS — never swept before 2026-08-27. `temperature_raw` is scaled
  -- ×100 (raw 3170 == 31.70°C) — confirmed via a separate independent
  -- weather station reading, not just guessed: fan read 31.7°C, weather
  -- station read 32.9°C at the same moment, accepted as close enough for
  -- a different-but-nearby location.
  -- `humidity` (field 87) deliberately NOT modeled here — it consistently
  -- reads a suspiciously round 100000 on both fans, matching
  -- `hasHumiditySensor: false` already confirmed via the capabilities
  -- blob (field 17) -- this looks like a "not populated" sentinel, not a
  -- real reading, and both fans agree, so it's not being treated as one.
  temperature_raw = { no = 86, kind = "int", category = "SENSORS", default = 0 },

  -- MORE — confirmed 2026-08-26 via a real packet capture of the official
  -- app: these three are NEVER returned by a direct category query (all 7
  -- known categories tried, in both field states) — the app instead holds
  -- one persistent connection and the fan pushes them unsolicited
  -- following any commit. No `default` set here, unlike every field
  -- above: these never participate in parse_category_result's normal
  -- default-fill pass, since that only runs for an explicit category
  -- query — data these fields never arrive through. See
  -- BafClient.commit_and_verify_more, the only code path that ever reads
  -- or writes them.
  led_indicators_enable   = { no = 134, kind = "bool", category = "MORE_PUSH" },
  fan_beep_enable         = { no = 135, kind = "bool", category = "MORE_PUSH" },
  legacy_ir_remote_enable = { no = 136, kind = "bool", category = "MORE_PUSH" },

  -- Sleep Mode master enable, confirmed 2026-08-26 the same way as the
  -- three MORE fields above (never returned by a direct category query,
  -- only ever seen via the fan's unsolicited push after a commit — same
  -- BafClient.commit_and_verify_more path, reused as-is). A cluster of
  -- other fields (100/101/110/111/112) showed up alongside this one in
  -- the same push burst and are suspected to be Sleep's other
  -- sub-settings (fan/light preset, Wake Up behavior) but are NOT
  -- individually confirmed — deliberately not added here until they are.
  sleep_mode_enable = { no = 98, kind = "bool", category = "MORE_PUSH" },

  -- Sleep/Wake Up sub-settings, confirmed 2026-08-27 via a 3rd packet
  -- capture — UNLIKE the MORE_PUSH cluster above, these ARE reachable via
  -- a direct category query (confirmed against all 7 categories with the
  -- probe): the fan-side fields live under FAN, the light-side ones under
  -- LIGHT. Field meanings confirmed by matching a specific committed
  -- value to a specific real UI action, then cross-checked against real
  -- app screenshots (which corrected two guesses from the pcap-only
  -- decode — see project-status memory for the full writeup). Two
  -- adjacent fields (101/111, "Min/Max Speed" on the real Auto screen)
  -- were deliberately left unmodeled — never independently isolated.
  sleep_fan_mode              = { no = 100, kind = "enum", category = "FAN",   default = 2 },   -- Off/On/Auto
  sleep_ideal_temp            = { no = 102, kind = "int",  category = "FAN",   default = 2050 }, -- x100 C
  sleep_timer_enable          = { no = 110, kind = "bool", category = "FAN",   default = false },
  sleep_timer_duration        = { no = 112, kind = "int",  category = "FAN",   default = 300 },  -- seconds
  sleep_return_to_auto        = { no = 129, kind = "bool", category = "FAN",   default = false },
  sleep_return_to_auto_secs   = { no = 130, kind = "int",  category = "FAN",   default = 7200 },
  sleep_brightness_mode       = { no = 103, kind = "enum", category = "LIGHT", default = 2 },   -- Off/Dim/Auto
  wake_up_mode                = { no = 107, kind = "enum", category = "LIGHT", default = 0 },   -- Off/Auto/On
  wake_up_brightness          = { no = 108, kind = "int",  category = "LIGHT", default = 0 },   -- percent
  wake_up_motion_timeout_secs = { no = 128, kind = "int",  category = "LIGHT", default = 600 },
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
-- Field order within a single commit is NOT cosmetic: confirmed live against
-- real hardware 2026-08-27 that this fan's firmware silently drops a speed
-- change if the speed field (46) is written before the fan_mode field (43)
-- in the same commit message, even though the two are semantically
-- independent and fan_mode's value wasn't even changing. Lua's pairs()
-- gives no ordering guarantee over the props table, and for this runtime it
-- was consistently landing in the bad (speed-first) order -- every
-- SmartThings-issued setFanSpeed silently failed as a result, never logged
-- as an error because the commit itself succeeds at the socket level; only
-- the fan's own interpretation of it is order-sensitive. Sorting by field
-- number here makes every caller's commit byte-order deterministic and
-- matches the one order confirmed to work, regardless of what order the
-- caller happened to build the props table in.
function baf.build_commit(props)
  local names = {}
  for name in pairs(props) do
    names[#names + 1] = name
  end
  table.sort(names, function(a, b)
    local def_a, def_b = baf.FIELDS[a], baf.FIELDS[b]
    if not def_a then error("baf.build_commit: unknown property '" .. tostring(a) .. "'") end
    if not def_b then error("baf.build_commit: unknown property '" .. tostring(b) .. "'") end
    return def_a.no < def_b.no
  end)
  local props_bytes = {}
  for _, name in ipairs(names) do
    local value = props[name]
    local def = baf.FIELDS[name]
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
--- from the fan and returns a flat table { field_name = value, ... } for
--- every KNOWN field actually present, merging every repeated Properties
--- chunk in the QueryResult. No category filtering and no default-fill —
--- just what's actually in this one frame. Returns nil if the message
--- doesn't contain a query_result at all (e.g. it was something else).
---
--- Building block for BafClient.query_multi's content-based response
--- matching (2026-08-27) — a frame is identified by which fields it
--- actually contains, not by assuming it answers whichever query was
--- sent in the same position. See project-status memory for why: a real
--- off-by-one response lag was found in the fan's back-to-back-query
--- behavior on one connection (confirmed against the real deployed code,
--- affects the already-shipped FAN+LIGHT poll too, not just a new
--- addition) — the Nth frame read does not reliably correspond to the
--- Nth category queried, for N >= 2.
function baf.parse_frame_fields(payload)
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

  local found = {}
  for _, entry in ipairs(qr_fields[2] or {}) do
    local chunk_fields = pb.parse_fields(entry[2])
    for field_no, occurrences in pairs(chunk_fields) do
      local name = FIELD_BY_NO[field_no]
      if name then
        local def = baf.FIELDS[name]
        local _, raw = table.unpack(occurrences[#occurrences])
        found[name] = decode_field_value(def, raw)
      end
    end
  end
  return found
end

--- Same result shape this function has always returned — kept for the
--- single-category callers (verify_commit, commit_and_verify_more),
--- where there's no second read to lag and the original approach is
--- already correct. `category` fills in defaults for known fields of
--- that category the fan omitted because they're at their zero value.
--- Implemented in terms of parse_frame_fields above.
function baf.parse_category_result(payload, category)
  local found = baf.parse_frame_fields(payload)
  if not found then
    return nil
  end
  local result = {}
  for name, def in pairs(baf.FIELDS) do
    if def.category == category and def.default ~= nil then
      result[name] = def.default
    end
  end
  for name, value in pairs(found) do
    result[name] = value
  end
  return result
end

return baf
