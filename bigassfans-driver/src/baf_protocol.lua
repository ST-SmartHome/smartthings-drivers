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
  -- ×100 (raw 3170 == 31.70°C) — confirmed via the household's own
  -- weather station, colocated with a planned future device, not just
  -- guessed: fan read 31.7°C, weather station read 32.9°C at the same
  -- moment, accepted as close enough for a different-but-nearby location.
  -- `humidity` (field 87) deliberately NOT modeled here — it consistently
  -- reads a suspiciously round 100000 on both fans, looking like a "not
  -- populated" sentinel rather than a real reading (both fans agree).
  --
  -- 2026-09-01 CORRECTION: this comment previously attributed that to a
  -- "hasHumiditySensor: false" capability flag -- checked against the
  -- upstream aiobafi6 proto verbatim and no such field exists. The real
  -- `Capabilities` submessage (SENSORS category, field 17) only names 4
  -- sub-fields: has_comfort1=1, has_comfort3=3, has_light=4, has_uplight=6.
  -- Live-queried on one of the two test fans: true sub-fields are {1,3,4,7,9,10,14}
  -- -- has_comfort1/has_comfort3/has_light all true (comfort-related
  -- capability flags being true is independent corroboration that the
  -- still-unconfirmed Comfort-screen fields elsewhere in this table are
  -- real, beyond just the original pcap correlation), has_uplight(6)
  -- correctly absent/false (this household's fans have no uplight
  -- module), and sub-fields 7/9/10/14 remain undocumented in the public
  -- schema. Also corrects an earlier, separately-wrong claim that field 3
  -- of this submessage was "hasOccupancySensor" -- the real occupancy
  -- fields are plain top-level Properties fields instead:
  -- `fan_occupancy_detected` (66, already modeled below) and
  -- `light_occupancy_detected` (85, confirmed to exist in the upstream
  -- schema but never queried/modeled here yet).
  temperature_raw = { no = 86, kind = "int", category = "SENSORS", default = 0 },

  -- 2026-09-01 -- promoted from documentation-only to an actively-used
  -- field: gates whether ensure_light_child creates a light-child device
  -- at all, instead of doing so unconditionally for every fan. Raw bytes
  -- (nested submessage, no encode path needed -- read-only). Use
  -- baf.decode_light_capability below rather than reading sub-fields
  -- directly -- keeps the "which sub-field numbers mean light" knowledge
  -- in one place.
  capabilities = { no = 17, kind = "bytes", category = "SENSORS" },

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
  -- decode — see project-status memory for the full writeup).
  --
  -- 2026-08-28: fields 101/111 (previously left unmodeled as "Min/Max
  -- Speed" guesses, never independently isolated) resolved via a fresh
  -- pcap capture of the real app's Sleep > Fan (ON mode) screen,
  -- confirmed against the screen's own "Speed"/"End Speed" sliders:
  -- 101 = sleep_speed (the Sleep tab's own fan speed, native 0-7, NOT a
  -- min/max pair), 111 = sleep_timer_end_speed (the Sleep Timer's
  -- gradual-decrease target speed, native 0-7). Same capture also found
  -- 104 = sleep_brightness_percent, paired with sleep_brightness_mode
  -- (103) the same way wake_up_brightness (108) pairs with wake_up_mode
  -- (107) — previously undiscovered, no field existed for it at all.
  sleep_fan_mode              = { no = 100, kind = "enum", category = "FAN",   default = 2 },   -- Off/On/Auto
  sleep_speed                 = { no = 101, kind = "int",  category = "FAN",   default = 0 },   -- native 0-7
  sleep_ideal_temp            = { no = 102, kind = "int",  category = "FAN",   default = 2050 }, -- x100 C
  sleep_timer_enable          = { no = 110, kind = "bool", category = "FAN",   default = false },
  sleep_timer_end_speed       = { no = 111, kind = "int",  category = "FAN",   default = 0 },   -- native 0-7
  sleep_timer_duration        = { no = 112, kind = "int",  category = "FAN",   default = 300 },  -- seconds
  sleep_return_to_auto        = { no = 129, kind = "bool", category = "FAN",   default = false },
  sleep_return_to_auto_secs   = { no = 130, kind = "int",  category = "FAN",   default = 7200 },
  sleep_brightness_mode       = { no = 103, kind = "enum", category = "LIGHT", default = 2 },   -- Off/On/Auto
  sleep_brightness_percent    = { no = 104, kind = "int",  category = "LIGHT", default = 0 },   -- percent
  wake_up_mode                = { no = 107, kind = "enum", category = "LIGHT", default = 0 },   -- Off/Auto/On
  wake_up_brightness          = { no = 108, kind = "int",  category = "LIGHT", default = 0 },   -- percent
  wake_up_motion_timeout_secs = { no = 128, kind = "int",  category = "LIGHT", default = 600 },

  -- 2026-09-02: found via a real pcap while narrating a schedule-editing
  -- walkthrough one field at a time -- committed value 1800 landed exactly
  -- where the narration said "Motion timeout 30min" (1800s = 30min),
  -- immediately after the Light-Auto mode screen. NOT the same field as
  -- the already-confirmed wake_up_motion_timeout_secs(128) -- this is the
  -- Sleep tab's own Light-Auto preset's motion timeout, a separate control
  -- from the Wake Up preset's. Single narrated data point, not an isolated
  -- toggle-only test like the fields above -- treat as strong-but-not-
  -- fully-isolated confidence until independently re-tested.
  sleep_light_auto_motion_timeout_secs = { no = 117, kind = "int", category = "LIGHT" },

  -- ===== 2026-08-29 pcap discovery — Comfort/Motion screens, NOT YET
  -- CONFIRMED. Decoded from raw commit values captured while navigating
  -- the official app's Comfort and Motion screens, same methodology as
  -- the original (later-corrected) Min/Max Speed guesses -- matched by
  -- value shape/count and rough correspondence to the screenshots seen
  -- the same session, NOT by a per-field isolated capture with narrated
  -- actions. Treat every mapping below as a candidate to verify (a
  -- fresh commit + the app's own displayed value, one field at a time)
  -- before relying on it, same as every previously-confirmed field in
  -- this table was. Defaults are the baseline values seen in the same
  -- QueryResult chunk these fields co-occurred in.
  comfort_enable      = { no = 47, kind = "bool", category = "FAN", default = true },  -- candidate: "Auto Comfort" master toggle
  comfort_ideal_temp  = { no = 48, kind = "int",  category = "FAN", default = 2444 },  -- candidate: Comfort's own Ideal Temperature, x100 C (2444 ~= 24.44C, close to the 24.5C shown on-screen)
  comfort_min_speed   = { no = 50, kind = "int",  category = "FAN", default = 0 },     -- candidate: "Min Speed" (native 0-7, paired with 51)
  comfort_max_speed   = { no = 51, kind = "int",  category = "FAN", default = 7 },     -- candidate: "Max Speed" (paired with 50)
  heat_assist_enable  = { no = 60, kind = "bool", category = "FAN", default = true },  -- candidate: "Heat Assist" toggle
  -- CONFLICT, not just unconfirmed: field 52 was already assigned to
  -- motion_sense_enable in an earlier session, confirmed via real
  -- hardware (a fan genuinely auto-started from live detected motion at
  -- fan_mode=AUTO) -- much stronger evidence than this single
  -- uncorroborated pcap commit (field 52 alone, value 1, no co-occurring
  -- fields in the same Commit to disambiguate). Do not trust this
  -- "heat_assist_reverse" label -- resolve via an isolated capture
  -- (toggle ONLY Heat Assist's Reverse switch, nothing under Motion)
  -- before wiring anything to field 52 for either meaning.
  heat_assist_reverse = { no = 52, kind = "bool", category = "FAN", default = false }, -- candidate: "Reverse" under Heat Assist -- only ever seen committed once (to true), baseline/off value not independently confirmed
  -- field 42 is a nested 2-field submessage (bytes, e.g. \x08\x01\x10\x02
  -- = {1: 1, 2: 2}), not a plain scalar -- candidate: "Unoccupied
  -- Behavior" ("Smart Mix" etc, a compound setting). decode_field_value
  -- passes an unrecognized kind through as raw bytes safely (falls into
  -- its int/enum branch), so this is safe to leave as "bytes" for
  -- reading, but build_commit has NO encode path for it -- do not wire
  -- any write handler to this field until build_commit gains real
  -- nested-message support, or it will encode garbage.
  unoccupied_behavior = { no = 42, kind = "bytes", category = "FAN" },
  -- 2026-09-01: ruled OUT as plain FAN-category queryable fields. Live
  -- test against a real fan -- baseline query, then 5
  -- separate real on-screen changes in sequence (Auto Comfort off,
  -- Ideal Temp 22.5C, Min Speed 3, Max Speed 6, Heat Assist on, Heat
  -- Assist Speed 5), re-querying FAN after each -- every single one of
  -- 42/47/48/50/51/52/54/55/60 stayed absent throughout, even though the
  -- app visibly showed each new value. Same shape of finding as
  -- sleepMode/ledIndicators/fanBeep/legacyIrRemote before they were
  -- solved: real values a plain query can never see because they only
  -- ever push unsolicited on the SAME connection as the commit that set
  -- them. Confirmation for this whole cluster needs an actual passive
  -- capture of the app's own connection (or the same
  -- query-then-commit-then-read-burst trick already used for the
  -- MORE_PUSH fields, if these turn out to share that mechanism) -- a
  -- live query from a separate connection, however well-timed, will not
  -- work, proven empirically here.
  -- Two more fields seen changing in the same Motion/Unoccupied cluster,
  -- meaning genuinely unclear yet -- lower confidence than the above.
  motion_field_54 = { no = 54, kind = "bool", category = "FAN", default = false },
  motion_field_55 = { no = 55, kind = "int",  category = "FAN", default = 900 },  -- seconds (900 = 15min baseline)

  -- 2026-09-01 -- full category sweep (ALL/FAN/LIGHT/
  -- FIRMWARE_MORE_DATETIME_API/NETWORK/SCHEDULES/SENSORS all queried,
  -- every field number found recorded), not from a pcap this time --
  -- direct live queries against one of the two test fans. All NOT YET CONFIRMED --
  -- no isolated-change testing done, just noting what a snapshot returns.
  -- fan_target_rpm(63) is notable: identical value to current_rpm(64) in
  -- the same query, worth checking whether it tracks a commanded setpoint
  -- distinct from the read-only actual RPM.
  fan_target_rpm      = { no = 63, kind = "int",    category = "FAN" },
  -- wifi_module_version(16, ALL category) is a nested 2-field submessage
  -- (sub-field 1 = a small int, sub-field 2 = a version string like
  -- "5.8.1") -- distinct from the main fan firmware_version(7, "3.3.7").
  -- No encode path exists for nested messages here (same caveat as
  -- unoccupied_behavior above) -- read-only candidate, bytes kind.
  wifi_module_version = { no = 16, kind = "bytes",  category = "ALL" },
  all_field_15         = { no = 15, kind = "int",    category = "ALL" },
  all_field_153        = { no = 153, kind = "int",   category = "ALL" },
  -- NETWORK category -- never queried by this driver before this sweep.
  network_ip           = { no = 120, kind = "string", category = "NETWORK" },
  network_field_121     = { no = 121, kind = "int",    category = "NETWORK" },
  -- network_wifi_info(124): nested submessage, sub-field 1 = the
  -- connected Wi-Fi SSID name in PLAINTEXT -- confirms the fan exposes
  -- its network's SSID to anyone on the LAN who queries it, unauthenticated,
  -- a real (minor) protocol-level privacy fact worth knowing regardless of
  -- whether this ever becomes a capability. A second sub-field looking
  -- like a signal-strength/RSSI reading appeared in one query but not an
  -- immediately following one -- possibly a live-changing value, possibly
  -- a parsing artifact; not confirmed either way.
  network_wifi_info    = { no = 124, kind = "bytes", category = "NETWORK" },
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

--- Decodes the raw bytes of the `capabilities` field (SENSORS category,
--- field 17) and answers "does this fan have a real light to control" --
--- true if either has_light (sub-field 4) or has_uplight (sub-field 6)
--- is present and true, matching the upstream schema's own guidance
--- ("integrations should check has_uplight in addition to has_light").
--- Sub-field ABSENCE means false, same "missing means default" convention
--- as everything else in this protocol. Returns false (not nil) on any
--- decode failure -- a malformed/unexpected blob should read as "no light
--- reported", never crash the caller (ensure_light_child's fail-open
--- fallback is for a failed *query*, not a failed *decode* of one that
--- succeeded).
function baf.decode_light_capability(raw_bytes)
  if type(raw_bytes) ~= "string" then
    return false
  end
  local ok, sub_fields = pcall(pb.parse_fields, raw_bytes)
  if not ok then
    return false
  end
  local has_light = pb.last(sub_fields, 4)
  local has_uplight = pb.last(sub_fields, 6)
  return (has_light ~= nil and has_light ~= 0) or (has_uplight ~= nil and has_uplight ~= 0)
end

-- ===== Schedule write path — DECODED 2026-09-02, NOT YET IMPLEMENTED =====
--
-- Confirmed via a real pcap capture of the official app editing the fan's
-- on-device schedules, narrated one action at a time. This is a real,
-- previously-unknown local write path -- nobody (this driver, aiobafi6,
-- homebridge-i6-bigAssFans) had ever found it before; every earlier
-- session's attempt concluded schedule writes must go through BAF's cloud
-- API, based on one specific screen (the app's own "Add Schedule" Wake
-- Up/Bedtime time pickers) showing zero local commits during that window.
-- That conclusion was too broad -- schedule writes ARE local, that one
-- screen's specific save action just happened not to be captured, or used
-- a different path than the one found here.
--
-- **`Commit` has a field 4, never modeled before**: `Root{2: Root2{2:
-- Commit{3: properties, 4: ScheduleWrite}}}`. `ScheduleWrite` is `{1:
-- <slot index, varint>, 2: <Schedule message, or empty for a delete>}`.
-- Three real captured examples, all against slot 1 except the delete:
--
-- 1. Re-saving the existing "My Schedule" unchanged (a light-type
--    schedule): `4: {1: 1, 2: {2: "My Schedule", 4: [1,2,3,4,5,6,7],
--    5: 1, 6: 1, 7: {1: "17:00", 2: {5: 2}, 2: {18: 10800}}}}` -- content
--    byte-identical to this schedule's already-known read-side decode
--    (day list, name, 17:00, light_mode=2/Auto via nested field 5, motion
--    timeout 10800s via nested field 18). Fields 5/6 (both varint 1 here)
--    are plausible "enabled" flags, not independently isolated from this
--    one capture alone.
-- 2. A brand new schedule saved (a Bedtime/Wake-Up-type schedule, no
--    name, no light action): `4: {1: 1, 2: {1: 1, 4: [2,3,4,5,6,7,1],
--    5: 2, 6: 1, 7: {1: "23:00"}, 8: {1: "06:00"}}}` -- day list is the
--    same 7 values as the light schedule's, just serialized in a
--    different order (harmless). Field 7/8 here are simple {1: STR time}
--    messages (Bedtime/Wake time), a genuinely different shape from the
--    light schedule's field 7 -- confirms `Schedule.7`'s content depends
--    on the schedule's own type, not a single fixed structure. Notably,
--    none of the individual Sleep sub-setting values configured earlier
--    in the same capture session (sleep_fan_mode, sleep_timer_*,
--    sleep_brightness_*, wake_up_*) appear anywhere in this schedule's
--    own payload -- they were separately committed via the normal
--    `Commit{3: properties}` path (see the individual FIELDS entries
--    above), all confirmed matching real narrated UI actions field-for-
--    field. Best-supported reading: a Bedtime/Wake-Up schedule doesn't
--    carry its own snapshot of Sleep settings at all -- it just triggers
--    Sleep Mode on/off at the given times, using whatever the fan's own
--    live Sleep configuration already is at trigger time (which is
--    exactly why the app lets you edit those live settings from the same
--    schedule-creation flow).
-- 3. Deleting the schedule created in (2): `4: {1: 2, 2: {1: 1}}` -- note
--    slot index 2 here, not 1 (the two schedules may have landed in
--    different slots, or slot indexing isn't simply "the Nth schedule" --
--    not resolved from this one capture). Payload is nearly empty (just
--    a bare `{1: 1}`), consistent with a delete needing little more than
--    a slot reference.
--
-- **2026-09-02, standalone-harness testing — a false "single schedule
-- slot" alarm, root-caused to a bug in the TEST SCRIPT, not the fan.**
-- First test (re-saving "My Schedule" unchanged) round-tripped correctly
-- and was genuinely safe. Second test (creating a second, differently-
-- named schedule) then appeared to have REPLACED "My Schedule" outright
-- -- a follow-up query seemed to show only the new schedule. Real cause,
-- found once the user independently created their own second schedule
-- via the official app and it showed up fine in the app's list: **the
-- fan sends one SLIP frame PER schedule in response to a single
-- SCHEDULES query**, and the test script's read function only consumed
-- the FIRST frame before closing the connection -- it wasn't that "My
-- Schedule" was gone, the probe just never read far enough to see it.
-- Reading properly (loop until an idle timeout, not just one frame)
-- immediately showed both schedules present and fully intact. **This
-- fan supports multiple coexisting schedules** -- there was no actual
-- data loss, but this was a real near-miss caused by trusting an
-- under-tested harness against live hardware; the "restore" performed
-- at the time was almost certainly a redundant no-op, not a genuine
-- recovery. Lesson for reuse: when probing a query response on this
-- protocol, always read to an idle timeout, never assume one frame is
-- the whole answer, even for message types (like Query, not just the
-- already-known MORE_PUSH commit acks) that hadn't previously shown
-- multi-frame behavior.
--
-- **A third, richer `Schedule` shape found from the user's own real
-- schedule** (a start/end time range with per-boundary fan+light
-- actions, distinct from both the light-only and Bedtime/Wake-Up shapes
-- above) -- raw decode only, most field meanings NOT independently
-- confirmed, don't trust the specific numbers below without isolated
-- testing:
-- `{1: 1, 2: "Test schedule", 4: [1..7], 5: 1, 6: 1,
--   7: {1: "22:00", 2: {1: 1}, 2: {4: 4}, 2: {5: 1}, 2: {6: 64}},
--   8: {1: "08:00", 2: {1: 2}, 2: {11: 1}, 2: {12: 2300}, 2: {13: 4},
--       2: {14: 3}, 2: {15: 1}}}`.
-- Matches the app's own screen (Start 22:00: Speed 4, Light 64%; End
-- 08:00: Fan Auto, no light action) well enough to guess at meaning --
-- field 7's `4`=4 plausibly the commanded speed, `6`=64 plausibly the
-- light percent; field 8's `12`=2300 plausibly an ideal-temp-style ×100
-- value (23.00°C) for the Auto fan mode, `1`=1 vs `1`=2 plausibly an
-- action-type discriminator (fixed-speed vs Auto) -- but none of this is
-- isolated-tested, treat purely as a lead for a future capture, not
-- documented behavior. **Important decode gotcha hit while reading this
-- frame**: a short bytes field that happens to be a plain ASCII time
-- string (e.g. "22:00", "08:00") can also happen to parse as a
-- syntactically-valid nested tag+varint sequence by coincidence -- a
-- naive decoder that always tries the nested-message interpretation
-- first will silently misread it (e.g. "08:00"'s bytes were first
-- misread as a nested `varint 56`). Always sanity-check a `bytes` field
-- as a plain string FIRST when its length/content looks stringy, before
-- trusting a recursive protobuf re-decode of it.
--
-- **Practical implication for any future feature, still true**: a write
-- should still default to read-modify-write (fetch existing schedules,
-- change only what's needed) rather than constructing one from scratch,
-- since the exact rules for how many schedules the fan will hold and
-- what happens on a genuine slot collision are still unconfirmed -- just
-- not because of a hard one-slot limit, which doesn't exist.
--
-- **2026-09-02, SHIPPED — `scheduleEnabled` capability live, verified
-- end-to-end.** The functions below are the real encode/decode
-- machinery, ported from the standalone Python harness that proved the
-- wire format, then refined once against real hardware (see
-- walk_top_level_fields' header comment for a real substring-collision
-- bug caught before it shipped). Deliberately does NOT attempt to fully
-- understand every field of every Schedule shape (three found so far,
-- likely more) -- baf.set_schedule_enabled operates on the RAW bytes a
-- query returned and only ever touches field 6 (the enable flag),
-- preserving every other byte including field order, which this fan's
-- firmware has already been confirmed order-sensitive about elsewhere
-- (see build_commit below). More conservative than parsing-then-re-
-- serializing the whole message, which could reorder fields the fan
-- might care about even if the semantic content were unchanged.
--
-- **A real bug found and fixed during the first live end-to-end test**:
-- `BafClient.commit_schedule_and_verify` originally reused a schedule's
-- own read-side "slot" (the outer wrap's field 1) as the write's slot
-- argument too — the write silently had no effect. A QueryResult's slot
-- field is NOT a stable per-schedule write target (both schedules on a
-- real fan have been observed reporting the identical value
-- simultaneously — more likely some kind of revision/generation
-- counter) — **the write's slot argument must always be the fixed value
-- `1`**, matching what the real official app used for every create/edit
-- in the original pcap regardless of the schedule's own read-side slot.
-- Verification correspondingly matches by schedule NAME, not slot
-- number. Confirmed live: real `setScheduleEnabled` commands sent
-- through the actual SmartThings API correctly toggled a real schedule
-- off and on, independently re-verified via a direct probe outside
-- SmartThings each time, with the household's real schedule ("My
-- Schedule") confirmed completely untouched throughout every test.

--- Serializes Root{2: Root2{2: Commit{4: {1: slot, 2: schedule_bytes}}}}.
--- `schedule_bytes` is a raw, already-encoded Schedule message -- pass
--- back exactly what a query returned (optionally patched via
--- baf.patch_schedule_field below), never hand-construct one from
--- scratch, per the read-modify-write safety rule established above.
function baf.build_schedule_commit(slot, schedule_bytes)
  local schedule_write = pb.encode_varint_field(1, slot) .. pb.encode_bytes_field(2, schedule_bytes)
  local commit = pb.encode_bytes_field(4, schedule_write)
  local root2 = pb.encode_bytes_field(2, commit)
  return pb.encode_bytes_field(2, root2)
end

--- Parses one already-SLIP-decoded response frame from a SCHEDULES query
--- into { slot = <int>, raw = <raw Schedule bytes>, fields = <parsed
--- via pb.parse_fields> }, or nil if this frame isn't a schedules
--- QueryResult (e.g. an echo of something else). The fan sends one frame
--- PER schedule -- callers must read multiple frames to an idle timeout,
--- never assume one frame is the whole answer (see BafClient.query_schedules
--- and the "false single slot alarm" writeup above for exactly why this
--- matters).
function baf.parse_schedule_frame(payload)
  local ok, top = pcall(pb.parse_fields, payload)
  if not ok then
    return nil
  end
  local root2_bytes = pb.last(top, 2)
  if not root2_bytes then
    return nil
  end
  local ok2, root2 = pcall(pb.parse_fields, root2_bytes)
  if not ok2 then
    return nil
  end
  local query_result_bytes = pb.last(root2, 4)
  if not query_result_bytes then
    return nil
  end
  local ok3, qr = pcall(pb.parse_fields, query_result_bytes)
  if not ok3 then
    return nil
  end
  local schedules_bytes = pb.last(qr, 3)
  if not schedules_bytes then
    return nil
  end
  local ok4, wrap = pcall(pb.parse_fields, schedules_bytes)
  if not ok4 then
    return nil
  end
  local slot = pb.last(wrap, 1)
  local raw = pb.last(wrap, 2)
  if not slot or not raw then
    return nil
  end
  local ok5, fields = pcall(pb.parse_fields, raw)
  if not ok5 then
    fields = nil
  end
  return { slot = slot, raw = raw, fields = fields }
end

--- Walks `buf`'s TOP-LEVEL fields only (does NOT recurse into nested
--- messages) and returns an ordered list of {field_no, wire_type,
--- tag_start, value_end}, one entry per occurrence, in byte order.
--- `tag_start` is the first byte of that occurrence's tag varint;
--- `value_end` is one past its last byte (i.e. `buf:sub(tag_start,
--- value_end - 1)` is that occurrence's complete encoded bytes).
--- **This is what makes a targeted top-level field edit safe even when
--- the exact same tag+value bytes also happen to appear elsewhere in
--- the message (e.g. nested inside a sub-message)** — confirmed a real,
--- live case of this 2026-09-02: field 5's top-level encoding (`{5:
--- 1}`) also appears, coincidentally, inside one schedule's own
--- action sub-structure, which a naive whole-buffer byte search cannot
--- tell apart from the real top-level occurrence.
local function walk_top_level_fields(buf)
  local entries = {}
  local i = 1
  local len = #buf
  while i <= len do
    local tag_start = i
    local tag, next_i = pb.decode_varint(buf, i)
    local field_no = tag >> 3
    local wire_type = tag & 0x7
    i = next_i
    if wire_type == 0 then
      local _, ni = pb.decode_varint(buf, i)
      i = ni
    elseif wire_type == 2 then
      local flen
      flen, i = pb.decode_varint(buf, i)
      i = i + flen
    elseif wire_type == 1 then
      i = i + 8
    elseif wire_type == 5 then
      i = i + 4
    else
      error("walk_top_level_fields: unsupported wire type " .. tostring(wire_type))
    end
    table.insert(entries, { field_no = field_no, wire_type = wire_type, tag_start = tag_start, value_end = i })
  end
  return entries
end

--- Returns a schedule's name (field 2), or nil if it doesn't have one --
--- some Schedule shapes (the Bedtime/Wake-Up type found in the original
--- pcap) have no name field at all.
function baf.schedule_name(sched)
  if not sched.fields then
    return nil
  end
  return pb.last(sched.fields, 2)
end

--- Whether a schedule is enabled, per field 6's presence -- confirmed
--- 2026-09-02 via live ON/OFF toggling on a real fan: present+1 =
--- enabled, entirely absent = disabled, same missing-means-default
--- convention as everywhere else in this protocol.
function baf.schedule_enabled(sched)
  if not sched.fields then
    return nil
  end
  return pb.last(sched.fields, 6) ~= nil
end

--- Finds the first schedule in `schedules` (a list from
--- BafClient.query_schedules) whose name (field 2) exactly matches
--- `name`. Returns nil if not found -- callers must handle this
--- gracefully, e.g. a configured name preference that doesn't match any
--- real schedule on this specific fan (a schedule-less schedule, or one
--- named differently, or a fan with none configured at all).
function baf.find_schedule_by_name(schedules, name)
  for _, sched in ipairs(schedules) do
    if baf.schedule_name(sched) == name then
      return sched
    end
  end
  return nil
end

--- Returns only the schedules in `schedules` that have a name (field 2),
--- sorted alphabetically by that name. Used to bind a stable "slot N"
--- position across independent polls/commands to the same physical
--- schedule -- the fan's own read-side "slot" field is a revision
--- counter, not an identity (see the "real bug found and fixed" note
--- above), and nameless schedules (the Bedtime/Wake-Up shape) have no
--- key to sort or match on at all, so they're excluded here rather than
--- risking an unstable position. Two schedules that happen to share the
--- exact same name are a known, accepted edge case (whichever byte-order
--- baf.parse_schedule_frame's caller happened to see them in wins the
--- tie) -- not expected in practice, not specially handled.
function baf.sorted_named_schedules(schedules)
  local named = {}
  for _, sched in ipairs(schedules) do
    if baf.schedule_name(sched) ~= nil then
      table.insert(named, sched)
    end
  end
  table.sort(named, function(a, b)
    return baf.schedule_name(a) < baf.schedule_name(b)
  end)
  return named
end

--- Returns a new raw Schedule message with field 6 (the enable flag)
--- set to match `enabled`, or the same raw_bytes unchanged if it's
--- already in that state (idempotent). Uses walk_top_level_fields above
--- to find field 5's/field 6's real TOP-LEVEL occurrence, immune to the
--- confirmed-real collision where a byte-identical tag+value also
--- appears nested inside the schedule's own action sub-structure.
--- Confirmed via direct byte-level observation across multiple real
--- ON/OFF toggles that field 6, when present, sits immediately after
--- field 5's top-level bytes and immediately before field 7's --
--- inserts/removes exactly there rather than attempting a general
--- re-serialize (this fan's firmware has already been confirmed
--- order-sensitive for at least one other message type -- see
--- build_commit below -- so never risk reordering fields this driver
--- doesn't need to touch). Requires exactly one top-level field 5 with
--- value 1 (true of every schedule shape seen so far) -- refuses rather
--- than guessing if that's not the case.
function baf.set_schedule_enabled(raw_bytes, enabled)
  local ok, top_fields = pcall(walk_top_level_fields, raw_bytes)
  if not ok then
    return nil, "failed to walk top-level fields: " .. tostring(top_fields)
  end

  local field5, field6
  for _, entry in ipairs(top_fields) do
    if entry.field_no == 5 and entry.wire_type == 0 then
      if field5 then
        return nil, "more than one top-level field 5 -- refusing to guess"
      end
      field5 = entry
    elseif entry.field_no == 6 and entry.wire_type == 0 then
      if field6 then
        return nil, "more than one top-level field 6 -- refusing to guess"
      end
      field6 = entry
    end
  end

  local currently_enabled = field6 ~= nil
  if enabled == currently_enabled then
    return raw_bytes
  end

  if enabled then
    if not field5 then
      return nil, "no top-level field 5 found -- can't determine where to insert field 6"
    end
    local field6_bytes = pb.encode_varint_field(6, 1)
    return raw_bytes:sub(1, field5.value_end - 1) .. field6_bytes .. raw_bytes:sub(field5.value_end)
  else
    -- field6 ~= nil here (currently_enabled was true, enabled is false)
    return raw_bytes:sub(1, field6.tag_start - 1) .. raw_bytes:sub(field6.value_end)
  end
end

return baf
