local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local BafClient = require "baf_client"
local baf = require "baf_protocol"

local POLL_TIMER_FIELD = "poll_timer"

local FAN_MODE_CAP = capabilities["aboutisland47519.fanMode"]
local FAN_DIRECTION_CAP = capabilities["aboutisland47519.fanDirection"]
local WHOOSH_CAP = capabilities["aboutisland47519.whoosh"]
local ECO_CAP = capabilities["aboutisland47519.ecoMode"]
local LED_INDICATORS_CAP = capabilities["aboutisland47519.ledIndicators"]
local FAN_BEEP_CAP = capabilities["aboutisland47519.fanBeep"]
local LEGACY_IR_REMOTE_CAP = capabilities["aboutisland47519.legacyIrRemote"]
local ADD_ANOTHER_CAP = capabilities["aboutisland47519.addAnotherFan"]

local OFF_ON_AUTO_TO_STRING = { [0] = "Off", [1] = "On", [2] = "Auto" }
local STRING_TO_OFF_ON_AUTO = { Off = 0, On = 1, Auto = 2 }

-- ===== Light child devices (2026-08-25) =====
--
-- Alexa's SmartThings integration discovers by *device*, not by
-- component — a fan's `light` component never showed up as its own
-- Alexa entity, only `main` did (confirmed live). The fix: a genuinely
-- separate ST device for the light, driven by this same driver, so Alexa
-- (and anything else that discovers by device) sees it independently.
-- Created automatically for every fan with a physical light (piloted
-- behind an opt-in preference on one fan first, then made unconditional
-- once confirmed working — see ensure_light_child below).
--
-- Identity is a plain device_network_id suffix, NOT device.profile.id.
-- A profile-id check would misidentify every device as "not a child" on
-- first boot after this ships (the profile UUID isn't known/hardcoded
-- yet — same bootstrap problem this driver already solved once for
-- hideAddFan/noLight by hardcoding a real UUID after the fact). A DNI
-- suffix is readable correctly from the very first init, no bootstrap
-- gap, and matches the one real precedent found for LAN-driver child
-- devices (frostmar/smartthings-broadlink-edge uses type="LAN" +
-- parent_device_id, not the EDGE_CHILD/parent_assigned_child_key path,
-- which has no confirmed LAN precedent) — deliberately not mixing the
-- two shapes.
local LIGHT_CHILD_DNI_SUFFIX = "-light"
local LIGHT_CHILD_PROFILE = "bigassfans-light-child.v1"

local function light_child_dni(parent)
  return parent.device_network_id .. LIGHT_CHILD_DNI_SUFFIX
end

--- True only for a light-child device this driver itself created. Real
--- fan DNIs (bigassfans-i6-<uuid> from mDNS, bigassfans-i6-manual-...
--- from "Add another fan") never end this way, so there's no collision
--- risk with a genuine parent/standalone device.
local function is_light_child(device)
  return device.device_network_id ~= nil
    and device.device_network_id:sub(-#LIGHT_CHILD_DNI_SUFFIX) == LIGHT_CHILD_DNI_SUFFIX
end

--- Finds a parent's already-created light-child device by scanning the
--- driver's known devices for the expected DNI — this is *observed live
--- state*, not a persisted "we already did this" flag. Deliberately not
--- a guard flag: this driver's own history (edge:drivers:install
--- reporting success without the process actually restarting, 2026-08-21)
--- means "we successfully asked the platform to create it" isn't proof it
--- exists — only actually seeing it in the device list is.
local function find_light_child(driver, parent)
  local expected_dni = light_child_dni(parent)
  for _, d in pairs(driver:get_devices()) do
    if d.device_network_id == expected_dni then
      return d
    end
  end
  return nil
end

--- Resolves the IP to talk to: the "Manual IP Override" preference wins if
--- the user has set it to something other than the 0.0.0.0 sentinel;
--- otherwise the persisted field mDNS discovery populated (nil if this
--- device was created manually and mDNS hasn't found it yet). A
--- light-child device has neither of these itself — it falls back to
--- whatever its parent resolves to, recursively (one level in practice,
--- since a child never spawns its own child). Safe to call
--- device:get_parent_device() here: unlike the added/init lifecycle
--- events the SDK docs warn about, this only ever runs from a capability
--- command handler.
local function resolve_ip(device)
  if is_light_child(device) then
    local parent = device:get_parent_device()
    if not parent then
      return nil
    end
    return resolve_ip(parent)
  end
  local override = device.preferences and device.preferences.ipAddress
  if override and override ~= discovery.MANUAL_IP_SENTINEL and override ~= "" then
    return override
  end
  return device:get_field(discovery.IP_FIELD)
end

local function get_poll_interval(device)
  return tonumber(device.preferences and device.preferences.pollInterval) or 30
end

local function apply_fan_status(device, fan)
  device:emit_event(capabilities.switch.switch(fan.fan_mode == 0 and "off" or "on"))
  device:emit_event(capabilities.fanSpeed.fanSpeed(fan.speed))
  device:emit_event(FAN_MODE_CAP.mode({ value = OFF_ON_AUTO_TO_STRING[fan.fan_mode] or "Off" }))
  device:emit_event(FAN_DIRECTION_CAP.direction({ value = fan.reverse_enable and "Reverse" or "Forward" }))
  device:emit_event(WHOOSH_CAP.whoosh({ value = fan.whoosh_enable and "On" or "Off" }))
  device:emit_event(ECO_CAP.eco({ value = fan.eco_enable and "On" or "Off" }))
end

--- Handles three cases uniformly: (1) a light-child device — emits
--- directly on its own (only) "main" component; (2) a not-yet-split
--- device that still has a `light` component in its active profile —
--- emits there, unchanged from before; (3) a split/no-light device with
--- neither — safely no-ops, same as always. Reused for both the parent
--- (called from poll_once with its own light component) and a light
--- child (called from poll_once with the same fresh data, and from
--- verify_commit when a command landed directly on the child).
local function apply_light_status(device, light)
  if is_light_child(device) then
    device:emit_event(capabilities.switch.switch(light.light_mode == 0 and "off" or "on"))
    device:emit_event(capabilities.switchLevel.level(light.light_brightness_percent))
    return
  end
  local light_component = device.profile.components.light
  if not light_component then
    return
  end
  device:emit_component_event(light_component,
    capabilities.switch.switch(light.light_mode == 0 and "off" or "on"))
  device:emit_component_event(light_component,
    capabilities.switchLevel.level(light.light_brightness_percent))
end

--- Wrapped in pcall: an uncaught Lua error here must not propagate past
--- this function. start_polling calls this synchronously before
--- registering the recurring timer — if it throws instead of returning,
--- the timer registration line never runs and polling silently never
--- starts, permanently, until the driver restarts. Same lesson learned
--- the hard way on the Skyfan driver (see smartthings-edge-driver-gotchas
--- memory).
--- Only ever called on a parent (fan) device — a light-child device has
--- no polling timer of its own (see start_polling/device_init) and gets
--- its state exclusively from the parent's own poll cycle below. This is
--- deliberate: giving the child its own timer would reintroduce the
--- exact two-connections-per-cycle churn the 2026-08-13 query_multi fix
--- eliminated (one TCP connect/close per poll, not two, per fan).
local function poll_once(driver, device)
  local ok, err = pcall(function()
    if is_light_child(device) then
      return
    end
    local ip = resolve_ip(device)
    if not ip then
      log.info("BAF device has no known IP yet (mDNS hasn't found it) — skipping poll")
      return
    end

    -- Both categories over one shared connection, not two separate
    -- connect/close cycles — see BafClient.query_multi for why (2026-08-13
    -- connection-churn/light-blip finding).
    --
    -- One immediate retry on failure: on a sufficiently lossy Wi-Fi link,
    -- poll_once can fail with "read failed waiting for start delimiter:
    -- timeout" — a lost/delayed response, not a slow one, so a longer
    -- timeout wouldn't help; a fresh attempt is what actually has a
    -- chance of landing. Not tested against a controlled packet-loss
    -- rig, just live poll cycles — revisit if misses persist after this.
    local results, err = BafClient.query_multi(ip, { "FAN", "LIGHT" }, 5)
    if not results then
      log.warn("BAF poll query failed for " .. ip .. " (retrying once): " .. tostring(err))
      results, err = BafClient.query_multi(ip, { "FAN", "LIGHT" }, 5)
    end
    if not results then
      log.error("BAF poll query failed for " .. ip .. " after retry: " .. tostring(err))
      return
    end
    apply_fan_status(device, results.FAN)
    apply_light_status(device, results.LIGHT)

    -- If a light-child has been created for this fan, push the same
    -- fresh LIGHT data to it too — one poll, two devices updated, still
    -- exactly one TCP connection to the fan per cycle.
    local child = find_light_child(driver, device)
    if child then
      apply_light_status(child, results.LIGHT)
    end
  end)
  if not ok then
    log.error("BAF poll crashed: " .. tostring(err))
  end
end

--- Never called for a light-child device (device_init routes those away
--- before reaching this) — defensive check kept here too since a stray
--- call would otherwise start a redundant second poll loop against the
--- same fan.
local function start_polling(driver, device)
  if is_light_child(device) then
    return
  end
  local existing_timer = device:get_field(POLL_TIMER_FIELD)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
    device:set_field(POLL_TIMER_FIELD, nil)
  end

  poll_once(driver, device)
  local timer = device.thread:call_on_schedule(get_poll_interval(device), function()
    poll_once(driver, device)
  end, "baf_poll")
  device:set_field(POLL_TIMER_FIELD, timer)
end

-- How long to wait after a commit before re-querying state. Found
-- 2026-08-22: querying immediately (0s) reads back the fan's PRE-commit
-- state almost every time — confirmed via logcat, a setFanSpeed(7) command
-- was followed by an emitted fanSpeed=4 (the old value) only 172ms later,
-- nowhere near enough time for the fan to have applied a new speed
-- setpoint. That stale read-back looked exactly like "the value reverted"
-- in the app, because it did — to a snapshot taken before the commit had
-- landed. Not empirically tuned against real hardware response time, just
-- picked to clearly clear that race — revisit if state still reads stale
-- this long after a command.
local REFRESH_DELAY_SECONDS = 2

-- How many times to (re)send a commit if it doesn't verify as applied.
-- Mirrors the read-path retry above, for the same reason: on a
-- sufficiently lossy Wi-Fi link, BafClient.commit's local sock:send()
-- succeeding only proves the write left this box, not that it reached
-- the fan. Unlike reads, a lost commit produced no error and no retry at
-- all before this fix — the app's toggle would just spin and silently
-- revert to the fan's real (unchanged) state on the next refresh.
local MAX_COMMIT_ATTEMPTS = 2

--- Every send_commit call sets fields from exactly one query category
--- (FAN or LIGHT) — never both in the same call, across every capability
--- handler in this file. Used to know which category to re-query to
--- verify a commit actually took effect.
local function category_of_props(props)
  for name in pairs(props) do
    local def = baf.FIELDS[name]
    if def then
      return def.category
    end
  end
  return nil
end

--- Checks the freshly-queried category result against what we tried to
--- commit — true only if every committed field reads back as the value we
--- sent.
local function props_applied(props, category_result)
  if not category_result then
    return false
  end
  for name, value in pairs(props) do
    if category_result[name] ~= value then
      return false
    end
  end
  return true
end

--- Emits only the one category's status (FAN or LIGHT) — used after a
--- verified commit, where we've only just re-queried that one category and
--- shouldn't claim to have fresher data than we do for the other one.
local function apply_fan_status_or_light(device, category, result)
  if category == "FAN" then
    apply_fan_status(device, result)
  elseif category == "LIGHT" then
    apply_light_status(device, result)
  end
end

--- Verifies a commit actually landed on the fan, resending it once if not,
--- before finally refreshing the device's full state either way (so
--- SmartThings ends up in sync with reality even on the failure path,
--- rather than staying silently stale). Wrapped in pcall same as
--- poll_once — this also runs from a scheduled call_with_delay callback,
--- and an uncaught error here shouldn't take down the driver's event loop
--- (see smartthings-edge-driver-gotchas memory on this exact lesson).
local function verify_commit(driver, device, ip, props, category, attempt)
  local ok, err = pcall(function()
    local results, query_err = BafClient.query_multi(ip, { category }, 5)
    if results and props_applied(props, results[category]) then
      apply_fan_status_or_light(device, category, results[category])
      return
    end
    if attempt < MAX_COMMIT_ATTEMPTS then
      log.warn("BAF commit didn't verify as applied (attempt " .. attempt ..
        "), resending: " .. tostring(query_err))
      local resent, resend_err = BafClient.commit(ip, props, 5)
      if not resent then
        log.error("BAF commit resend failed: " .. tostring(resend_err))
      end
      device.thread:call_with_delay(REFRESH_DELAY_SECONDS, function()
        verify_commit(driver, device, ip, props, category, attempt + 1)
      end)
    else
      log.error("BAF commit did not verify as applied after " .. attempt ..
        " attempts — refreshing full state so the app reflects reality")
      poll_once(driver, device)
    end
  end)
  if not ok then
    log.error("BAF commit verification crashed: " .. tostring(err))
  end
end

local function send_commit(driver, device, props, refresh_after)
  local ip = resolve_ip(device)
  if not ip then
    log.warn("BAF command attempted before device has a known IP")
    return
  end
  local ok, err = BafClient.commit(ip, props, 5)
  if not ok then
    log.error("BAF commit failed: " .. tostring(err))
    return
  end
  if refresh_after then
    local category = category_of_props(props)
    device.thread:call_with_delay(REFRESH_DELAY_SECONDS, function()
      if category then
        verify_commit(driver, device, ip, props, category, 1)
      else
        poll_once(driver, device)
      end
    end)
  end
end

-- Maps a MORE field name (see baf_protocol.lua) to the emit function for
-- its capability, so send_more_commit can stay generic across all three.
local MORE_CAP_EMIT = {
  led_indicators_enable = function(device, value)
    device:emit_event(LED_INDICATORS_CAP.ledIndicators({ value = value and "On" or "Off" }))
  end,
  fan_beep_enable = function(device, value)
    device:emit_event(FAN_BEEP_CAP.fanBeep({ value = value and "On" or "Off" }))
  end,
  legacy_ir_remote_enable = function(device, value)
    device:emit_event(LEGACY_IR_REMOTE_CAP.legacyIrRemote({ value = value and "On" or "Off" }))
  end,
}

--- Commits exactly one MORE-category field (led_indicators_enable /
--- fan_beep_enable / legacy_ir_remote_enable) via
--- BafClient.commit_and_verify_more and emits whatever it actually
--- confirmed. Deliberately separate from send_commit/verify_commit —
--- those exist for fields the regular FAN/LIGHT poll cycle can read back
--- on its own; these three can't be read back that way at all (see
--- baf_protocol.lua and BafClient.commit_and_verify_more for why), so
--- there's no "next poll picks it up" safety net to fall back on the way
--- every other command in this file has.
---
--- If the push burst didn't confirm the field within the read window,
--- this still emits the requested value optimistically (the commit did
--- go out — fire-and-forget applies here same as everywhere else in this
--- driver) rather than leaving the app showing stale/blank state, but
--- logs a warning so an actual failure doesn't look identical to a
--- merely-slow confirmation in the logs.
local function send_more_commit(device, field_name, value)
  local ip = resolve_ip(device)
  if not ip then
    log.warn("BAF command attempted before device has a known IP")
    return
  end
  local sent_ok, verified, err = BafClient.commit_and_verify_more(ip, { [field_name] = value }, 5)
  if not sent_ok then
    log.error("BAF MORE commit failed for " .. field_name .. ": " .. tostring(err))
    return
  end
  local emit = MORE_CAP_EMIT[field_name]
  if not emit then
    log.error("BAF MORE commit: no emit mapping for " .. field_name)
    return
  end
  if verified and verified[field_name] ~= nil then
    emit(device, verified[field_name])
  else
    log.warn("BAF MORE commit for " .. field_name ..
      " sent but not confirmed by a push within the read window — showing requested value optimistically")
    emit(device, value)
  end
end

-- ===== Lifecycle =====

-- Same pattern as skyfan-driver's profile-switch mechanism (see
-- smartthings-edge-driver-gotchas memory for the full history of bugs
-- found building that one — both are already fixed here from the start):
-- only ever call ensure_correct_profile from device_init (never
-- info_changed — try_update_metadata appears to trigger its own new
-- info_changed as a side effect, which caused a real infinite oscillation
-- bug on skyfan-driver when this was called from there); compare
-- device.profile.id (a real, live UUID) directly against known profile
-- UUIDs rather than trusting any persisted "did we already ask" field as
-- the reason to skip a switch — a persisted skip-guard silently blocked
-- all future retries forever after one failed switch attempt on
-- skyfan-driver, found and fixed 2026-08-21, not repeated here.
-- 2026-08-22: extended from 2 profiles to a 4-profile (light x add-fan)
-- matrix, same reasoning as skyfan-driver's equivalent — some Haiku units
-- don't have the light kit fitted. The two pre-existing profile names are
-- unchanged so no already-deployed device moves unless its preferences
-- actually change.
local WITH_ADDFAN_PROFILE = "bigassfans-h.v1"
local NO_ADDFAN_PROFILE = "bigassfans-h-no-addfan.v1"
local NO_LIGHT_PROFILE = "bigassfans-h-no-light.v1"
local NO_LIGHT_NO_ADDFAN_PROFILE = "bigassfans-h-no-light-no-addfan.v1"

-- Real deviceIntegrationProfile UUIDs, confirmed via live device query.
-- 2026-08-25: adding, then later removing, the splitLightDevice
-- preference on these two profiles regenerated their UUIDs each time
-- (a profile's preference set is part of its identity, same as it was
-- for the no-light variants below on 2026-08-22) — the values below are
-- current as of the automatic-light-child deploy. WITH_ADDFAN_PROFILE_ID
-- and NO_LIGHT_PROFILE_ID are nil rather than stale: neither of this
-- household's two fans currently uses either variant (both have
-- hideAddFan=true, and both now have a light-child), so there's no live
-- device to confirm a real value from — a stale-but-plausible UUID would
-- be worse than an honest nil here (ensure_correct_profile always
-- attempts a switch when it doesn't match, which is harmless while
-- nothing is on that profile).
local WITH_ADDFAN_PROFILE_ID = nil
local NO_ADDFAN_PROFILE_ID = "35f1a587-782a-36e4-a4e5-29b16acc3ec7"
local NO_LIGHT_PROFILE_ID = nil
local NO_LIGHT_NO_ADDFAN_PROFILE_ID = "3c1f88a6-ea73-3f73-b026-eadfd5701fc7"

local PROFILE_TO_ID = {
  [WITH_ADDFAN_PROFILE] = WITH_ADDFAN_PROFILE_ID,
  [NO_ADDFAN_PROFILE] = NO_ADDFAN_PROFILE_ID,
  [NO_LIGHT_PROFILE] = NO_LIGHT_PROFILE_ID,
  [NO_LIGHT_NO_ADDFAN_PROFILE] = NO_LIGHT_NO_ADDFAN_PROFILE_ID,
}

--- has_light_child is computed by the caller via find_light_child (observed
--- live state) — once a light-child device is confirmed to actually exist,
--- this device is treated as noLight regardless of that preference's raw
--- value, since its light is now controlled through the child instead.
--- Deliberately does NOT write the noLight preference itself (no
--- preference-write path exists — see smartthings-edge-driver-gotchas
--- memory); this only affects which profile ensure_correct_profile picks.
local function profile_for(device, has_light_child)
  local prefs = device.preferences or {}
  local no_light = prefs.noLight or has_light_child
  if no_light and prefs.hideAddFan then
    return NO_LIGHT_NO_ADDFAN_PROFILE
  elseif no_light then
    return NO_LIGHT_PROFILE
  elseif prefs.hideAddFan then
    return NO_ADDFAN_PROFILE
  end
  return WITH_ADDFAN_PROFILE
end

local ACTIVE_PROFILE_FIELD = "active_profile"

--- Only ever called for a parent (fan) device — a light-child always has
--- exactly one profile (LIGHT_CHILD_PROFILE) and never switches, so it's
--- routed away from this in device_init before it would get here.
local function ensure_correct_profile(driver, device)
  local has_light_child = find_light_child(driver, device) ~= nil
  local target = profile_for(device, has_light_child)
  local target_id = PROFILE_TO_ID[target]

  if device.profile.id == target_id then
    if device:get_field(ACTIVE_PROFILE_FIELD) ~= target then
      device:set_field(ACTIVE_PROFILE_FIELD, target, { persist = true })
    end
    return
  end

  log.info("BAF switching device to profile " .. target
    .. " (live profile.id " .. tostring(device.profile.id)
    .. " expected " .. tostring(target_id) .. ")")
  device:try_update_metadata({ profile = target })
  device:set_field(ACTIVE_PROFILE_FIELD, target, { persist = true })
end

--- Automatic for every fan with a physical light — no per-device opt-in
--- anymore. Piloted behind a splitLightDevice preference on one real
--- fan first (created, confirmed mirroring state both directions and
--- controlling the real light, confirmed as its own separate Alexa
--- device) before making it unconditional here for every other fan too,
--- including ones added in the future. Still skipped for
--- a noLight device — nothing to split off if there's no physical light
--- kit. Idempotent via find_light_child (observed state), so safe to
--- call on every init. Deliberately does NOT also switch this device's
--- own profile in the same pass — ensure_correct_profile picks up
--- has_light_child on whichever LATER init actually observes the child
--- existing (naturally true here already, since try_create_device is
--- fire-and-forget and the platform won't have created it synchronously
--- within this same call) — create-then-confirm-then-switch stays two
--- effectively-separate steps even though the code is textually
--- adjacent, so a failed/delayed creation can never leave the light
--- orphaned mid-migration.
local function ensure_light_child(driver, device)
  if is_light_child(device) then
    return -- a child never spawns its own child
  end
  if device.preferences and device.preferences.noLight then
    return -- no physical light kit on this unit — nothing to split off
  end
  if find_light_child(driver, device) then
    return -- already created
  end
  local label = (device.label or device.id) .. " Light"
  local ok, err = driver:try_create_device({
    type = "LAN",
    device_network_id = light_child_dni(device),
    label = label,
    profile = LIGHT_CHILD_PROFILE,
    manufacturer = "Big Ass Fans",
    model = "Haiku H/I Series (light)",
    vendor_provided_label = label,
    parent_device_id = device.id,
  })
  if not ok and not tostring(err):find("DNI already exists") then
    log.error("BAF failed to create light-child device for " .. device.id .. ": " .. tostring(err))
  else
    log.info("BAF requested light-child device creation for " .. device.id)
  end
end

local function device_init(driver, device)
  log.info("BAF device init: " .. device.id)
  if is_light_child(device) then
    -- No profile-switch logic (always LIGHT_CHILD_PROFILE, never
    -- changes) and no polling timer of its own — state comes entirely
    -- from the parent's own poll cycle. See start_polling/poll_once.
    return
  end
  ensure_correct_profile(driver, device)
  ensure_light_child(driver, device)
  start_polling(driver, device)
end

local function device_added(driver, device)
  log.info("BAF device added: " .. device.id)
  discovery.apply_cached_ip(driver, device)
end

local function info_changed(driver, device, event, args)
  log.info("BAF preferences changed, restarting polling")
  start_polling(driver, device)
end

local function device_removed(driver, device)
  local existing_timer = device:get_field(POLL_TIMER_FIELD)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
  end
  log.info("BAF device removed: " .. device.id)
end

-- ===== Capability commands =====

--- command.component == "light" covers a not-yet-split device (still on
--- a profile with both main+light components); is_light_child(device)
--- covers a split device's separate light device (whose only component
--- is "main", so the component check alone would wrongly fall through to
--- the fan branch). Both checks needed side by side — devices in either
--- state can exist at once across a household mid-migration.
local function switch_on(driver, device, command)
  if is_light_child(device) or command.component == "light" then
    send_commit(driver, device, { light_mode = baf.OFF_ON_AUTO.ON }, true)
  else
    send_commit(driver, device, { fan_mode = baf.OFF_ON_AUTO.ON }, true)
  end
end

local function switch_off(driver, device, command)
  if is_light_child(device) or command.component == "light" then
    send_commit(driver, device, { light_mode = baf.OFF_ON_AUTO.OFF }, true)
  else
    send_commit(driver, device, { fan_mode = baf.OFF_ON_AUTO.OFF }, true)
  end
end

--- Setting a nonzero speed also turns the fan on (fan_mode = ON) and
--- setting speed to 0 turns it off — a UX judgment call, not a confirmed
--- device behavior: the protocol keeps `speed` and `fan_mode` as separate
--- properties, and whether the firmware itself couples them isn't
--- verified. See known open items.
local function set_fan_speed(driver, device, command)
  local speed = math.max(0, math.min(7, math.floor(command.args.speed)))
  send_commit(driver, device, {
    speed = speed,
    fan_mode = speed > 0 and baf.OFF_ON_AUTO.ON or baf.OFF_ON_AUTO.OFF,
  }, true)
end

local function set_level(driver, device, command)
  local percent = math.max(0, math.min(100, math.floor(command.args.level)))
  send_commit(driver, device, { light_brightness_percent = percent }, true)
end

local function set_mode(driver, device, command)
  local value = STRING_TO_OFF_ON_AUTO[command.args.mode]
  if not value then
    log.error("BAF setMode: unknown mode '" .. tostring(command.args.mode) .. "'")
    return
  end
  send_commit(driver, device, { fan_mode = value }, true)
end

-- CORRECTED: the "never takes effect" conclusion that removed this
-- handler was wrong — reverse_enable does get committed, just with an
-- unpredictable delay (confirmed when a fan turned up running
-- reverse_enable=true, well after the original short wait-then-verify
-- test looked like it failed). Handler restored. Known real limitation:
-- a command sent here may not visibly apply for some unknown period
-- afterward (minutes, possibly longer) — the app has no way to indicate
-- "pending", so a user re-sending the same command because nothing
-- seemed to happen can end up with both the original and the retry
-- landing unpredictably later. No fix for that currently; just something
-- to keep in mind.
--
-- Also added a stop-the-fan-first interlock, since this original code
-- committed reverse_enable directly regardless of whether the fan was
-- spinning -- the exact sequence that likely caused the incident above,
-- worked around manually (stop, verify stopped, then flip) via a
-- standalone fix script at the time. That manual sequence is now built
-- into the handler instead of relying on doing it by hand again.
local MAX_STOP_ATTEMPTS = 3

--- Re-queries FAN and, once confirmed stopped (fan_mode OFF and speed 0),
--- commits reverse_enable and hands off to the normal verify_commit path.
--- Retries the stop commit up to MAX_STOP_ATTEMPTS times if the fan
--- hasn't confirmed stopped yet -- fan_mode/speed are both known to apply
--- immediately (unlike reverse_enable/whoosh_enable), so this shouldn't
--- need more than one or two rounds in practice. Wrapped in pcall for the
--- same reason as verify_commit -- runs from a scheduled callback.
local function verify_stopped_then_set_direction(driver, device, ip, target_reverse, attempt)
  local ok, err = pcall(function()
    local results, query_err = BafClient.query_multi(ip, { "FAN" }, 5)
    local fan = results and results["FAN"]
    if fan and fan.fan_mode == baf.OFF_ON_AUTO.OFF and fan.speed == 0 then
      apply_fan_status(device, fan)
      local props = { reverse_enable = target_reverse }
      local committed, commit_err = BafClient.commit(ip, props, 5)
      if not committed then
        log.error("BAF direction commit failed after confirming stopped: " .. tostring(commit_err))
        return
      end
      device.thread:call_with_delay(REFRESH_DELAY_SECONDS, function()
        verify_commit(driver, device, ip, props, "FAN", 1)
      end)
      return
    end
    if attempt < MAX_STOP_ATTEMPTS then
      log.warn("BAF fan not yet confirmed stopped before direction change (attempt " ..
        attempt .. "), resending stop: " .. tostring(query_err))
      BafClient.commit(ip, { fan_mode = baf.OFF_ON_AUTO.OFF }, 5)
      device.thread:call_with_delay(REFRESH_DELAY_SECONDS, function()
        verify_stopped_then_set_direction(driver, device, ip, target_reverse, attempt + 1)
      end)
    else
      log.error("BAF fan did not confirm stopped after " .. attempt ..
        " attempts -- aborting direction change for motor safety")
      poll_once(driver, device)
    end
  end)
  if not ok then
    log.error("BAF stop-then-direction sequence crashed: " .. tostring(err))
  end
end

local function set_direction(driver, device, command)
  local ip = resolve_ip(device)
  if not ip then
    log.warn("BAF setDirection attempted before device has a known IP")
    return
  end
  local target_reverse = command.args.direction == "Reverse"
  local stopped, err = BafClient.commit(ip, { fan_mode = baf.OFF_ON_AUTO.OFF }, 5)
  if not stopped then
    log.error("BAF direction-change stop commit failed: " .. tostring(err))
    return
  end
  device.thread:call_with_delay(REFRESH_DELAY_SECONDS, function()
    verify_stopped_then_set_direction(driver, device, ip, target_reverse, 1)
  end)
end

local function set_whoosh(driver, device, command)
  send_commit(driver, device, { whoosh_enable = command.args.whoosh == "On" }, true)
end

local function set_eco(driver, device, command)
  send_commit(driver, device, { eco_enable = command.args.eco == "On" }, true)
end

local function set_led_indicators(driver, device, command)
  send_more_commit(device, "led_indicators_enable", command.args.ledIndicators == "On")
end

local function set_fan_beep(driver, device, command)
  send_more_commit(device, "fan_beep_enable", command.args.fanBeep == "On")
end

local function set_legacy_ir_remote(driver, device, command)
  send_more_commit(device, "legacy_ir_remote_enable", command.args.legacyIrRemote == "On")
end

--- poll_once is a no-op when called directly on a light-child (it has no
--- polling loop of its own, see poll_once/start_polling above) — so a
--- refresh command on the child needs redirecting to its parent's
--- poll_once instead, or its own "refresh" button would silently do
--- nothing. get_parent_device() is safe here: this only ever runs from a
--- capability command handler, not an added/init lifecycle event.
local function refresh_handler(driver, device, command)
  if is_light_child(device) then
    local parent = device:get_parent_device()
    if parent then
      poll_once(driver, parent)
    end
    return
  end
  poll_once(driver, device)
end

local function add_another_handler(driver, device, command)
  discovery.create_another(driver)
end

-- ===== Driver =====

local baf_driver = Driver("bigassfans-i6-lan", {
  discovery = discovery.discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = switch_on,
      [capabilities.switch.commands.off.NAME] = switch_off,
    },
    [capabilities.fanSpeed.ID] = {
      [capabilities.fanSpeed.commands.setFanSpeed.NAME] = set_fan_speed,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = set_level,
    },
    [FAN_MODE_CAP.ID] = {
      [FAN_MODE_CAP.commands.setMode.NAME] = set_mode,
    },
    [FAN_DIRECTION_CAP.ID] = {
      [FAN_DIRECTION_CAP.commands.setDirection.NAME] = set_direction,
    },
    [WHOOSH_CAP.ID] = {
      [WHOOSH_CAP.commands.setWhoosh.NAME] = set_whoosh,
    },
    [ECO_CAP.ID] = {
      [ECO_CAP.commands.setEco.NAME] = set_eco,
    },
    [LED_INDICATORS_CAP.ID] = {
      [LED_INDICATORS_CAP.commands.setLedIndicators.NAME] = set_led_indicators,
    },
    [FAN_BEEP_CAP.ID] = {
      [FAN_BEEP_CAP.commands.setFanBeep.NAME] = set_fan_beep,
    },
    [LEGACY_IR_REMOTE_CAP.ID] = {
      [LEGACY_IR_REMOTE_CAP.commands.setLegacyIrRemote.NAME] = set_legacy_ir_remote,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
    [ADD_ANOTHER_CAP.ID] = {
      [ADD_ANOTHER_CAP.commands.push.NAME] = add_another_handler,
    },
  },
})

baf_driver:run()
