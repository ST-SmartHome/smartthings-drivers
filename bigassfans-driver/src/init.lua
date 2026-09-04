local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local BafClient = require "baf_client"
local baf = require "baf_protocol"

local POLL_TIMER_FIELD = "poll_timer"

local FAN_MODE_CAP = capabilities["examplens.fanMode"]
local FAN_DIRECTION_CAP = capabilities["examplens.fanDirection"]
local WHOOSH_CAP = capabilities["examplens.whoosh"]
local ECO_CAP = capabilities["examplens.ecoMode"]
local LED_INDICATORS_CAP = capabilities["examplens.ledIndicators"]
local FAN_BEEP_CAP = capabilities["examplens.fanBeep"]
local LEGACY_IR_REMOTE_CAP = capabilities["examplens.legacyIrRemote"]
local SLEEP_MODE_CAP = capabilities["examplens.sleepMode"]
-- Phantom switch (2026-08-29, user request): purely local UI state, no
-- protocol commit at all -- unlike sleepMode/ledIndicators/etc above,
-- there's no real hardware behind this at all, just a stored value other
-- tiles' visibleCondition gates on. Deliberately chosen over sleepMode's
-- MORE_PUSH pattern for anything gate-only like this: device_init can
-- safely seed a real default immediately (see below), no stuck-null
-- window to fail open around.
local SHOW_SETTINGS_CAP = capabilities["examplens.showSettings"]
local ADD_ANOTHER_CAP = capabilities["examplens.addAnotherFan"]

-- Sleep/Wake Up sub-settings (2026-08-27) -- see baf_protocol.lua for the
-- field-decode writeup and project-status memory for how each was
-- confirmed. All read via the normal FAN/LIGHT category poll (these are
-- directly queryable, unlike sleepMode/ledIndicators/etc above), written
-- via the normal send_commit/verify_commit path.
local SLEEP_FAN_MODE_CAP = capabilities["examplens.sleepAutoMode"]
-- Headless mirror of sleepAutoMode's own value (2026-08-29), never shown
-- in the app itself (no detailView entry). Real purpose (corrected
-- 2026-09-02 -- an earlier version of this comment attributed it to a
-- "can't hide a referenced-by capability" theory that live testing later
-- disproved; the actual platform bug is that a section's FIRST detailView
-- tile can never fully hide, regardless of what references it, worked
-- around by putting sleepMode itself first instead -- see project-status
-- memory and this file's own sleep_mode_enable comment for that fix):
-- sleepMode (the master Sleep Mode switch, its own separate MORE_PUSH-only
-- field) has no effect on sleepAutoMode's own real value on its own, so
-- the 7 sub-fields that should hide whenever Sleep Mode is off need to
-- gate on THIS capability instead of sleepAutoMode directly -- it folds
-- sleepMode's state in (see apply_sleep_status below), sleepAutoMode alone
-- never could.
local SLEEP_FAN_MODE_GATE_CAP = capabilities["examplens.sleepAutoModeGate"]
local SLEEP_SPEED_CAP = capabilities["examplens.sleepSpeed"]
local SLEEP_IDEAL_TEMP_CAP = capabilities["examplens.sleepIdealTemperature"]
local SLEEP_TIMER_CAP = capabilities["examplens.sleepTimer"]
local SLEEP_TIMER_END_SPEED_CAP = capabilities["examplens.sleepTimerEndSpeed"]
local SLEEP_TIMER_DURATION_CAP = capabilities["examplens.sleepTimerDuration"]
local SLEEP_RETURN_TO_AUTO_CAP = capabilities["examplens.sleepReturnToAuto"]
local SLEEP_RETURN_TO_AUTO_DURATION_CAP = capabilities["examplens.sleepReturnToAutoDuration"]
local SLEEP_BRIGHTNESS_MODE_CAP = capabilities["examplens.sleepBrightnessMode"]
-- Headless mirrors of sleepBrightnessMode/wakeUpMode (2026-08-29), same
-- pattern and same reason as SLEEP_FAN_MODE_GATE_CAP above: sleepMode
-- (the master Sleep Mode switch) has no effect on sleepBrightnessMode/
-- wakeUpMode's own real value, so sleepBrightnessPercent/wakeUpBrightness/
-- wakeUpMotionTimeout need to gate on THESE instead if they're to hide
-- when Sleep Mode is off. See apply_sleep_status for the fold-in logic.
local SLEEP_BRIGHTNESS_MODE_GATE_CAP = capabilities["examplens.sleepBrightnessModeGate"]
local SLEEP_BRIGHTNESS_PERCENT_CAP = capabilities["examplens.sleepBrightnessPercent"]
local WAKE_UP_MODE_CAP = capabilities["examplens.wakeUpMode"]
local WAKE_UP_MODE_GATE_CAP = capabilities["examplens.wakeUpModeGate"]
-- wakeUpBrightness should show for BOTH wakeUpMode "On" and "Auto" (Wake
-- Up brightness matters whenever the light does something at wake time),
-- but visibleCondition only ever accepted a single EQUALS operand --
-- ONE_OF (array operand) and NOT_EQUALS both got real 400 BadRequestErrors
-- from presentation:device-config:create (2026-08-28), confirmed still
-- true. Same fold-a-derived-gate pattern as the others: folds
-- wakeUpModeGate's On/Auto/Off into a plain On/Off, so wakeUpBrightness
-- can gate on a single EQUALS "On" against THIS instead.
local WAKE_UP_BRIGHTNESS_GATE_CAP = capabilities["examplens.wakeUpBrightnessGate"]
local WAKE_UP_BRIGHTNESS_CAP = capabilities["examplens.wakeUpBrightness"]

-- Schedule (2026-09-02, reworked 2026-09-03): binds SmartThings to the
-- fan's own on-device schedules, decoded via baf.build_schedule_commit/
-- parse_schedule_frame/set_schedule_enabled (see baf_protocol.lua's
-- "Schedule write path" comment for the full protocol writeup and the
-- near-miss that shaped this design). Never constructs a schedule from
-- scratch, always reads the real one first and patches only the one
-- field being changed (read-modify-write), since the exact rules for how
-- many schedules a fan will hold and what a write collision does are
-- still not fully understood. showSchedule is the same phantom-switch
-- pattern as showSettings (pure local UI state, no protocol commit) --
-- its own section, per explicit user design direction, not folded into
-- an existing component.
--
-- **Reworked 2026-09-03 from name-preference binding to real
-- auto-discovery**, per direct user pushback on the first version
-- ("rather than querying the schedule name, pull the whole schedule
-- config out") -- typing an exact name into a preference was clunky,
-- silently broke if a schedule got renamed in the official app, and gave
-- no visibility into what schedules actually exist. Now: every poll
-- queries all schedules, keeps only the ones that HAVE a name (the
-- Bedtime/Wake-Up shape has none -- see baf_protocol.lua, out of scope
-- here), and sorts them alphabetically by name. That sort order is what
-- makes "slot N" mean the same physical schedule poll to poll -- the
-- fan's own read-side "slot" field is confirmed to be a revision
-- counter, not a stable identity (see baf_protocol.lua), so it can't be
-- used directly. Each slot shows a read-only label (the real name, or
-- "(none)" if fewer than 3 named schedules exist) plus its own
-- enable/disable toggle; the toggle's handler re-runs the exact same
-- query+filter+sort at COMMAND time rather than trusting a stale
-- position, so it always targets whatever is currently in that slot --
-- consistent with whatever the last poll displayed. No preference gates
-- this anymore (per explicit user direction: "my fans schedules arent
-- production ready at the moment anyway") -- Show Schedule remains the
-- only visibility gate, same as before.
local SHOW_SCHEDULE_CAP = capabilities["examplens.showSchedule"]
local SCHEDULE_ONE_EXISTS_CAP = capabilities["examplens.scheduleOneExists"]
local SCHEDULE_TWO_EXISTS_CAP = capabilities["examplens.scheduleTwoExists"]
local SCHEDULE_THREE_EXISTS_CAP = capabilities["examplens.scheduleThreeExists"]
local FIRST_SCHEDULE_LABEL_CAP = capabilities["examplens.firstScheduleLabel"]
local SECOND_SCHEDULE_LABEL_CAP = capabilities["examplens.secondScheduleLabel"]
local THIRD_SCHEDULE_LABEL_CAP = capabilities["examplens.thirdScheduleLabel"]
local SCHEDULE_ENABLED_CAP = capabilities["examplens.scheduleEnabled"]
local SECOND_SCHEDULE_ENABLED_CAP = capabilities["examplens.secondScheduleEnabled"]
local THIRD_SCHEDULE_ENABLED_CAP = capabilities["examplens.thirdScheduleEnabled"]
-- Slots 4/5 added 2026-09-04, per explicit user correction: the original
-- requirement was to surface ALL named schedules, not just the first 3 --
-- SmartThings has no way to render a truly unbounded list (every tile
-- needs a capability declared statically ahead of time), and neither the
-- fan's firmware nor the official app documents any real maximum schedule
-- count, so 5 was picked as a generous practical ceiling, not derived
-- from a known limit. Same exact pattern as slots 1-3 in every respect.
local SCHEDULE_FOUR_EXISTS_CAP = capabilities["examplens.scheduleFourExists"]
local SCHEDULE_FIVE_EXISTS_CAP = capabilities["examplens.scheduleFiveExists"]
local FOURTH_SCHEDULE_LABEL_CAP = capabilities["examplens.fourthScheduleLabel"]
local FIFTH_SCHEDULE_LABEL_CAP = capabilities["examplens.fifthScheduleLabel"]
local FOURTH_SCHEDULE_ENABLED_CAP = capabilities["examplens.fourthScheduleEnabled"]
local FIFTH_SCHEDULE_ENABLED_CAP = capabilities["examplens.fifthScheduleEnabled"]
local WAKE_UP_MOTION_TIMEOUT_CAP = capabilities["examplens.wakeUpMotionTimeout"]

--- Auto-discovered schedule slots (Phase 1 of SCHEDULE_FEATURE_PLAN.md,
--- reworked 2026-09-03) -- `index` is this slot's 1-based position in
--- the alphabetically-sorted list of the fan's NAMED schedules, computed
--- fresh every time (see baf.sorted_named_schedules below), never
--- persisted.
--- `exists_cap`/`exists_attr` (added 2026-09-03, per explicit user
--- request "don't show the blank last schedule if it can't be edited or
--- created") are headless gate capabilities, same pattern as
--- sleepAutoModeGate elsewhere in this file: folds TWO conditions into
--- one EQUALS-able value -- "On" only when Show Schedule is on AND a
--- named schedule actually exists at this position, "Off" otherwise
--- (fail-closed, unlike the fail-open sleep gates, since there's nothing
--- useful to show for a slot with no schedule). The device-config's
--- visibleCondition for each slot's label+enabled tiles reads THIS gate,
--- not showSchedule directly -- visibleCondition only supports one
--- condition per entry, so folding is the only way to require both.
local SCHEDULE_SLOTS = {
  { index = 1, exists_cap = SCHEDULE_ONE_EXISTS_CAP, exists_attr = "scheduleOneExists",
    label_cap = FIRST_SCHEDULE_LABEL_CAP, label_attr = "firstScheduleLabel",
    cap = SCHEDULE_ENABLED_CAP, attr = "scheduleEnabled", command_name = "setScheduleEnabled" },
  { index = 2, exists_cap = SCHEDULE_TWO_EXISTS_CAP, exists_attr = "scheduleTwoExists",
    label_cap = SECOND_SCHEDULE_LABEL_CAP, label_attr = "secondScheduleLabel",
    cap = SECOND_SCHEDULE_ENABLED_CAP, attr = "secondScheduleEnabled", command_name = "setSecondScheduleEnabled" },
  { index = 3, exists_cap = SCHEDULE_THREE_EXISTS_CAP, exists_attr = "scheduleThreeExists",
    label_cap = THIRD_SCHEDULE_LABEL_CAP, label_attr = "thirdScheduleLabel",
    cap = THIRD_SCHEDULE_ENABLED_CAP, attr = "thirdScheduleEnabled", command_name = "setThirdScheduleEnabled" },
  { index = 4, exists_cap = SCHEDULE_FOUR_EXISTS_CAP, exists_attr = "scheduleFourExists",
    label_cap = FOURTH_SCHEDULE_LABEL_CAP, label_attr = "fourthScheduleLabel",
    cap = FOURTH_SCHEDULE_ENABLED_CAP, attr = "fourthScheduleEnabled", command_name = "setFourthScheduleEnabled" },
  { index = 5, exists_cap = SCHEDULE_FIVE_EXISTS_CAP, exists_attr = "scheduleFiveExists",
    label_cap = FIFTH_SCHEDULE_LABEL_CAP, label_attr = "fifthScheduleLabel",
    cap = FIFTH_SCHEDULE_ENABLED_CAP, attr = "fifthScheduleEnabled", command_name = "setFifthScheduleEnabled" },
}

local OFF_ON_AUTO_TO_STRING = { [0] = "Off", [1] = "On", [2] = "Auto" }
local STRING_TO_OFF_ON_AUTO = { Off = 0, On = 1, Auto = 2 }

-- sleep_fan_mode (field 100) shares the same Off/On/Auto order as the
-- main fan_mode enum -- confirmed via commit->readback round-trips
-- (committed 0/1/2 each read back identically right after) -- reuse the
-- same tables, don't duplicate.
--
-- sleep_brightness_mode (field 103): "2" = Auto is solidly confirmed
-- (matches the real app screenshot showing "Auto / 0%" as the current
-- Sleep light state, and the field's baseline value). CONFIRMED
-- 2026-08-28 via a real screenshot of the official app's Sleep > Light
-- sub-screen: the three options are OFF / ON / AUTO, not Off/Dim/Auto --
-- "Dim" was a guess, corrected here. Numeric order (0/1/2) unchanged,
-- only the label for 1 changes from "Dim" to "On".
local STRING_TO_BRIGHTNESS_MODE = { Off = 0, On = 1, Auto = 2 }
local BRIGHTNESS_MODE_TO_STRING = { [0] = "Off", [1] = "On", [2] = "Auto" }
-- wake_up_mode (field 107) turns out to share the SAME Off/On/Auto order
-- as fan_mode -- confirmed via the commit's own immediate read-back in
-- the pcap (committed 1 -> read back 1 right after "On"; committed 2 ->
-- read back 2 right after "Auto"), not just marker-timing proximity. An
-- earlier pass mis-ordered this as Off/Auto/On from timing alone before
-- the read-back cross-check was done -- if you're ever re-deriving this,
-- trust a commit's own read-back over marker timestamps.
local STRING_TO_WAKE_MODE = STRING_TO_OFF_ON_AUTO
local WAKE_MODE_TO_STRING = OFF_ON_AUTO_TO_STRING

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

--- SENSORS category, currently just ambient temperature (field 86 --
--- humidity/field 87 deliberately not modeled, see baf_protocol.lua).
--- Scale factor (÷100) confirmed against a real independent weather
--- station, not just guessed -- see project-status memory for the
--- verification. Lives on the `settings` component (moved there
--- 2026-08-27 at the user's request, alongside LED/Beep/IR -- profile
--- bumped to .v3 for the same detailView-caching reason as every other
--- capability-placement change in this driver) -- emit_component_event,
--- not plain emit_event, same reason as MORE_CAP_EMIT below: plain
--- emit_event implicitly targets "main" and would silently no-op for a
--- capability declared on a different component. Only the parent fan
--- has physical sensors, never called for a light-child.
local function apply_sensor_status(device, sensors)
  device:emit_component_event(device.profile.components.settings,
    capabilities.temperatureMeasurement.temperature({
      value = sensors.temperature_raw / 100.0, unit = "C" }))
end

--- Sleep/Wake Up sub-settings (2026-08-27). Unlike sensors/LED/Beep/IR,
--- these fields are directly queryable (FAN and LIGHT categories), so
--- they arrive on every normal poll_once call already -- no extra query
--- category needed. Only called for the parent (never a light-child --
--- these are fan-and-light-shared preset screens that only make sense on
--- the parent device, same reasoning as apply_sensor_status). fan/light
--- params are the FAN/LIGHT category results already fetched by the
--- caller; either may be nil if that category's query failed this cycle,
--- in which case its half is simply skipped for this emit.
---
--- sleepAutoModeGate (2026-08-29 fix): originally just mirrored
--- sleep_fan_mode unconditionally, same as sleepAutoMode itself -- which
--- meant the master "Sleep Mode" switch (sleepMode, field 98, a totally
--- separate MORE_PUSH-only field) had no actual effect on it, so
--- sleepSpeed/sleepTimer/sleepTimerEndSpeed/sleepTimerDuration stayed
--- visible even with Sleep Mode off (real bug, caught via a live
--- screenshot). Now folds in the last-known sleepMode value: an explicit
--- "Off" forces the gate to "Off" (hiding the sub-fields); anything else,
--- including nil (sleepMode's MORE-push value hasn't been captured yet,
--- e.g. right after a driver restart -- see the earlier "stuck at null"
--- incident), fails OPEN and passes the real fan value through. Failing
--- closed on nil would collapse the whole Sleep section by default on
--- every fresh driver start, which is worse than today's bug.
local function apply_sleep_status(device, fan, light)
  local sleep_component = device.profile.components.sleep
  if not sleep_component then
    return
  end
  -- Shared by both halves below (fan and light can arrive on different
  -- poll cycles if one category's query failed) -- see the fold-in note
  -- on sleepAutoModeGate above for why "Off" is the only value that
  -- forces a hide and nil/anything else fails open.
  local sleep_mode_state = device:get_latest_state("sleep", "examplens.sleepMode", "sleepMode")
  if fan then
    local sleep_fan_mode_str = OFF_ON_AUTO_TO_STRING[fan.sleep_fan_mode] or "Off"
    local gate_value = sleep_fan_mode_str
    if sleep_mode_state == "Off" then
      gate_value = "Off"
    end
    device:emit_component_event(sleep_component,
      SLEEP_FAN_MODE_CAP.sleepFanMode({ value = sleep_fan_mode_str }))
    device:emit_component_event(sleep_component,
      SLEEP_FAN_MODE_GATE_CAP.sleepAutoModeGate({ value = gate_value }))
    device:emit_component_event(sleep_component,
      SLEEP_SPEED_CAP.sleepSpeed({ value = fan.sleep_speed }))
    device:emit_component_event(sleep_component,
      SLEEP_IDEAL_TEMP_CAP.sleepIdealTemp({ value = fan.sleep_ideal_temp / 100.0, unit = "C" }))
    device:emit_component_event(sleep_component,
      SLEEP_TIMER_CAP.sleepTimerEnable({ value = fan.sleep_timer_enable and "On" or "Off" }))
    device:emit_component_event(sleep_component,
      SLEEP_TIMER_END_SPEED_CAP.sleepTimerEndSpeed({ value = fan.sleep_timer_end_speed }))
    device:emit_component_event(sleep_component,
      SLEEP_TIMER_DURATION_CAP.sleepTimerDuration({ value = math.floor(fan.sleep_timer_duration / 60), unit = "min" }))
    device:emit_component_event(sleep_component,
      SLEEP_RETURN_TO_AUTO_CAP.sleepReturnToAuto({ value = fan.sleep_return_to_auto and "On" or "Off" }))
    device:emit_component_event(sleep_component,
      SLEEP_RETURN_TO_AUTO_DURATION_CAP.sleepReturnToAutoDuration({ value = math.floor(fan.sleep_return_to_auto_secs / 60), unit = "min" }))
  end
  if light then
    local brightness_mode_str = BRIGHTNESS_MODE_TO_STRING[light.sleep_brightness_mode] or "Off"
    local wake_mode_str = WAKE_MODE_TO_STRING[light.wake_up_mode] or "Off"
    local brightness_gate_value = brightness_mode_str
    local wake_gate_value = wake_mode_str
    if sleep_mode_state == "Off" then
      brightness_gate_value = "Off"
      wake_gate_value = "Off"
    end
    device:emit_component_event(sleep_component,
      SLEEP_BRIGHTNESS_MODE_CAP.sleepBrightnessMode({ value = brightness_mode_str }))
    device:emit_component_event(sleep_component,
      SLEEP_BRIGHTNESS_MODE_GATE_CAP.sleepBrightnessModeGate({ value = brightness_gate_value }))
    device:emit_component_event(sleep_component,
      SLEEP_BRIGHTNESS_PERCENT_CAP.sleepBrightnessPercent({ value = light.sleep_brightness_percent, unit = "%" }))
    device:emit_component_event(sleep_component,
      WAKE_UP_MODE_CAP.wakeUpMode({ value = wake_mode_str }))
    device:emit_component_event(sleep_component,
      WAKE_UP_MODE_GATE_CAP.wakeUpModeGate({ value = wake_gate_value }))
    device:emit_component_event(sleep_component,
      WAKE_UP_BRIGHTNESS_GATE_CAP.wakeUpBrightnessGate(
        { value = (wake_gate_value ~= "Off") and "On" or "Off" }))
    device:emit_component_event(sleep_component,
      WAKE_UP_BRIGHTNESS_CAP.wakeUpBrightness({ value = light.wake_up_brightness, unit = "%" }))
    device:emit_component_event(sleep_component,
      WAKE_UP_MOTION_TIMEOUT_CAP.wakeUpMotionTimeout({ value = math.floor(light.wake_up_motion_timeout_secs / 60), unit = "min" }))
  end
end

--- Queries all schedules and emits the label, enabled state, AND
--- existence gate for each of SCHEDULE_SLOTS' 3 auto-discovered
--- positions. Deliberately its OWN connection (BafClient.query_schedules),
--- not folded into the regular FAN/LIGHT/SENSORS poll_once cycle --
--- schedule content changes rarely (only via SmartThings or the official
--- app), so paying for an extra TCP connection every single poll cycle
--- isn't worth it on this fan's known-lossy Wi-Fi; called instead from
--- device_init, the refresh command, right after this driver's own
--- schedule writes, AND now also from every Show Schedule toggle (so the
--- exists-gates update immediately, not just on the next poll).
--- **Reworked 2026-09-03 from preference-bound names to auto-discovery**
--- (see the header comment above SCHEDULE_SLOTS for why) -- every named
--- schedule found is sorted alphabetically (baf.sorted_named_schedules)
--- and assigned to slots 1/2/3 in that order; a slot beyond however many
--- named schedules actually exist still gets its label set to "(none)"
--- (harmless, since the tile itself is hidden) but its exists-gate goes
--- "Off", hiding the whole label+enabled pair per explicit user request
--- ("don't show the blank last schedule if it can't be edited or
--- created") -- see the exists_cap/exists_attr comment above
--- SCHEDULE_SLOTS for why this needs its own gate rather than reusing
--- showSchedule's visibleCondition directly.
local function apply_schedule_status(driver, device)
  local schedule_component = device.profile.components.schedule
  if not schedule_component then
    return
  end
  local ip = resolve_ip(device)
  if not ip then
    return
  end
  local show_schedule = device:get_latest_state("schedule", "examplens.showSchedule", "showSchedule")
  local schedules, err = BafClient.query_schedules(ip, 5)
  if not schedules then
    log.warn("BAF schedule status query failed: " .. tostring(err))
    return
  end
  local named = baf.sorted_named_schedules(schedules)
  for _, slot in ipairs(SCHEDULE_SLOTS) do
    local sched = named[slot.index]
    device:emit_component_event(schedule_component,
      slot.label_cap[slot.label_attr]({ value = sched and baf.schedule_name(sched) or "(none)" }))
    -- Always emit the enabled attribute, even when no schedule exists at
    -- this slot -- an attribute that's NEVER been emitted shows as a raw
    -- `null` with no timestamp in devices:status, which is exactly what
    -- triggers the app's "hasn't updated all of its status information
    -- yet" toast, and it recurs every time the section is opened since a
    -- never-populated value never self-heals. Matches the label's
    -- always-emit pattern above (which already uses "(none)" as its own
    -- absent-value default) instead of silently skipping like before.
    local enabled = sched and baf.schedule_enabled(sched)
    device:emit_component_event(schedule_component,
      slot.cap[slot.attr]({ value = enabled and "On" or "Off" }))
    local exists = (show_schedule == "On") and (sched ~= nil)
    device:emit_component_event(schedule_component,
      slot.exists_cap[slot.exists_attr]({ value = exists and "On" or "Off" }))
  end
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

    -- All three categories over one shared connection, not separate
    -- connect/close cycles — see BafClient.query_multi for why (2026-08-13
    -- connection-churn/light-blip finding). SENSORS added 2026-08-27,
    -- same connection, no extra TCP overhead.
    --
    -- One immediate retry on failure: found 2026-08-22 that on a
    -- sufficiently lossy Wi-Fi network (a congested 2.4GHz SSID with a
    -- high TX-retry rate on both fans, unrelated to this driver)
    -- poll_once fails with "read failed waiting for start delimiter:
    -- timeout" on roughly 1-in-5 cycles per fan — a lost/delayed response,
    -- not a slow one, so a longer timeout wouldn't help; a fresh attempt
    -- is what actually has a chance of landing. Failures are independent
    -- enough per-attempt that one retry should drop the effective miss
    -- rate from ~20% to ~4% (0.2 * 0.2). Not tested against a controlled
    -- packet-loss rig, just live poll cycles — revisit if misses persist
    -- after this.
    local results, err = BafClient.query_multi(ip, { "FAN", "LIGHT", "SENSORS" }, 5)
    if not results then
      log.warn("BAF poll query failed for " .. ip .. " (retrying once): " .. tostring(err))
      results, err = BafClient.query_multi(ip, { "FAN", "LIGHT", "SENSORS" }, 5)
    end
    if not results then
      log.error("BAF poll query failed for " .. ip .. " after retry: " .. tostring(err))
      return
    end
    apply_fan_status(device, results.FAN)
    apply_light_status(device, results.LIGHT)
    if results.SENSORS then
      apply_sensor_status(device, results.SENSORS)
    end
    apply_sleep_status(device, results.FAN, results.LIGHT)

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
-- Mirrors the read-path retry added 2026-08-22 for the same reason: this
-- fan's Wi-Fi has a high TX-retry rate, and BafClient.commit's local
-- sock:send() succeeding only proves the write left this box, not that it
-- reached the fan. Unlike reads, a lost commit produced no error and no
-- retry at all before this fix — the app's toggle would just spin and
-- silently revert to the fan's real (unchanged) state on the next refresh.
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
    apply_sleep_status(device, result, nil)
  elseif category == "LIGHT" then
    apply_light_status(device, result)
    apply_sleep_status(device, nil, result)
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
-- Targets the "settings" component explicitly via emit_component_event —
-- device:emit_event alone implicitly targets "main", and these three
-- capabilities live on their own "settings" component/page (moved there
-- 2026-08-26 at the user's request, off the main Fan controls). Using
-- plain emit_event here was a real bug caught live: the commit correctly
-- reached the fan every time, but the capability's status stayed null on
-- the platform forever, because the platform silently drops an event for
-- a capability/component combination the profile doesn't declare.
local MORE_CAP_EMIT = {
  -- REVERTED 2026-08-27: a lowercase-enum test here ("on"/"off", matching
  -- the stock `switch` capability's own convention) was tried to see if
  -- displayType:"switch" only tracks lowercase state -- instead of
  -- giving a clean signal, changing the enum values put the platform's
  -- own status cache into a stuck state (over a minute with zero update
  -- despite confirmed real hardware changes and multiple commands) rather
  -- than answering the question. Reverted back to "On"/"Off" to match
  -- fanBeep/legacyIrRemote and get the attribute unstuck. Don't retry
  -- this exact test on a live capability without a safer way to validate
  -- it first (a throwaway capability, not one of the shipped three) --
  -- see project-status memory for the full writeup and open question.
  led_indicators_enable = function(device, value)
    device:emit_component_event(device.profile.components.settings,
      LED_INDICATORS_CAP.ledIndicators({ value = value and "On" or "Off" }))
  end,
  fan_beep_enable = function(device, value)
    device:emit_component_event(device.profile.components.settings,
      FAN_BEEP_CAP.fanBeep({ value = value and "On" or "Off" }))
  end,
  legacy_ir_remote_enable = function(device, value)
    device:emit_component_event(device.profile.components.settings,
      LEGACY_IR_REMOTE_CAP.legacyIrRemote({ value = value and "On" or "Off" }))
  end,
  -- Sleep Mode moved from "main" to "sleep" (2026-08-29) -- see the
  -- visibleCondition/first-tile writeup in project-status memory: the
  -- platform can never fully hide a section's first detailView tile
  -- (renders disabled instead, confirmed via a live position-swap test),
  -- so Sleep Mode itself -- which should always be visible and never
  -- needs its own gate -- is deliberately placed first in "sleep" to
  -- absorb that un-hideable slot, freeing sleepAutoMode/
  -- sleepBrightnessMode/wakeUpMode (now positions 2+) to hide correctly.
  sleep_mode_enable = function(device, value)
    local sleep_component = device.profile.components.sleep
    if not sleep_component then
      return
    end
    device:emit_component_event(sleep_component,
      SLEEP_MODE_CAP.sleepMode({ value = value and "On" or "Off" }))
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
-- 2026-08-27: bumped v1 -> v2 to add temperatureMeasurement to `main`,
-- then v2 -> v3 the same day to move it onto `settings` instead (user
-- request) -- same detailView-caching rule as the earlier inverterStatus
-- (se-modbus-driver) and skyfanColorTemp (skyfan-driver) bumps: a
-- same-named profile's cached detailView doesn't regenerate just because
-- its capability list changed on a later repackage. The v2->v3 profile
-- YAML rename briefly didn't get mirrored here -- these constants still
-- said v2 for a while, silently requesting a profile name that no
-- longer existed in the package, which is why the migration never took
-- effect across several redeploys and even a hub reboot. Real lesson:
-- a profile-name bump has TWO places that must move together, the YAML
-- file's own `name:` and whatever constant here requests it by name --
-- treat them as one edit, never one without the other.
local WITH_ADDFAN_PROFILE = "bigassfans-h.v8"
local NO_ADDFAN_PROFILE = "bigassfans-h-no-addfan.v8"
local NO_LIGHT_PROFILE = "bigassfans-h-no-light.v9"
local NO_LIGHT_NO_ADDFAN_PROFILE = "bigassfans-h-no-light-no-addfan.v36"

-- Real deviceIntegrationProfile UUIDs, confirmed via live device query.
-- All four reset to nil after the 2026-08-27 v2->v3 bump above (a new
-- profile version gets a new UUID once first created by a real deploy,
-- so any older UUID would be stale, not current) -- honest nil
-- until confirmed live again, same reasoning as WITH_ADDFAN_PROFILE_ID
-- already used below (ensure_correct_profile always
-- attempts a switch when it doesn't match, which is harmless while
-- nothing is on that profile).
local WITH_ADDFAN_PROFILE_ID = nil
local NO_ADDFAN_PROFILE_ID = nil
local NO_LIGHT_PROFILE_ID = nil
local NO_LIGHT_NO_ADDFAN_PROFILE_ID = nil

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
--- anymore. Piloted behind a splitLightDevice preference on one fan
--- first (2026-08-25: created, confirmed mirroring state both
--- directions and controlling the real light, confirmed as its own
--- separate Alexa device) before making it unconditional here for every
--- other fan too, including ones added in the future. Still skipped for
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
---
--- 2026-09-01 — added a real capability check (fan's own reported
--- has_light/has_uplight, via the SENSORS-category `capabilities` field)
--- before creating, rather than doing so unconditionally for every fan.
--- This runs BEFORE start_polling (later in device_init), so there is no
--- cached poll data to check yet on a fan's very first pairing — the
--- only way to gate the actual creation decision on real data is a
--- direct, synchronous query right here, not a cache. Deliberately
--- fails OPEN (creates the light child, today's prior behavior) on any
--- query failure/timeout — an unreachable fan during pairing shouldn't
--- silently end up without a light child it may well have; only a
--- successful query that positively reports no light skips creation.
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
  local ip = resolve_ip(device)
  if ip then
    local results, query_err = BafClient.query_multi(ip, { "SENSORS" }, 5)
    local sensors = results and results.SENSORS
    if sensors and sensors.capabilities ~= nil then
      if not baf.decode_light_capability(sensors.capabilities) then
        log.info("BAF fan " .. device.id ..
          " reports no light capability (has_light/has_uplight both false) — skipping light-child creation")
        return
      end
    else
      log.info("BAF light-capability query for " .. device.id ..
        " came back without a capabilities field (" .. tostring(query_err) ..
        ") — creating light child anyway (fail-open)")
    end
  else
    log.info("BAF light-capability check attempted before device has a known IP — creating light child anyway (fail-open)")
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
  -- Seed showSettings' default here rather than leaving it to whatever
  -- happens first -- unlike sleepMode (MORE_PUSH, genuinely unknown
  -- until a real command), this is pure local state with nothing to
  -- wait on, so device_init can safely set it once. Guarded by
  -- get_latest_state so a restart never clobbers an explicit choice the
  -- user already made -- only a device that's never had this attribute
  -- at all gets the default. Only meaningful on profiles that actually
  -- declare the settings component/capability; a no-op emit on one that
  -- doesn't (older profile variants) is silently dropped, same as any
  -- other capability/component mismatch in this driver.
  local settings_component = device.profile.components.settings
  if settings_component and
      device:get_latest_state("settings", "examplens.showSettings", "showSettings") == nil then
    device:emit_component_event(settings_component,
      SHOW_SETTINGS_CAP.showSettings({ value = "On" }))
  end
  -- Same seed pattern as showSettings above -- pure local UI state, safe
  -- to default immediately. Real value "On" (see show_schedule_on's
  -- comment for the 2026-09-03 On/Off correction).
  local schedule_component = device.profile.components.schedule
  if schedule_component and
      device:get_latest_state("schedule", "examplens.showSchedule", "showSchedule") == nil then
    device:emit_component_event(schedule_component,
      SHOW_SCHEDULE_CAP.showSchedule({ value = "On" }))
  end
  -- Real, network-dependent status -- wrapped in pcall like poll_once,
  -- for the same reason: an uncaught error here must never stop
  -- start_polling below from ever running.
  local ok, err = pcall(apply_schedule_status, driver, device)
  if not ok then
    log.error("BAF apply_schedule_status crashed during device_init: " .. tostring(err))
  end
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

--- Cascades the light child's power state to match a fan on/off change —
--- "Fan+Light" combined control (2026-08-29, user request): turning the
--- fan off from the main switch or the Fan Mode control also turns the
--- light off, and back on again from either control, since the whole
--- physical unit is what most people mean by "turn the fan off," not
--- just the motor. A separate commit to the light child, never merged
--- into the fan's own commit — this driver always keeps FAN and LIGHT
--- fields in their own single-category commits (see
--- category_of_props/verify_commit above), never mixed in one, so the
--- existing verify/re-emit logic doesn't need to learn a mixed case.
--- No-ops silently if this fan has no light child yet (e.g. mid-split).
local function cascade_light(driver, device, turn_on)
  local light_child = find_light_child(driver, device)
  if not light_child then
    return
  end
  send_commit(driver, light_child, {
    light_mode = turn_on and baf.OFF_ON_AUTO.ON or baf.OFF_ON_AUTO.OFF,
  }, true)
end

--- command.component == "light" covers a not-yet-split device (still on
--- a profile with both main+light components); is_light_child(device)
--- covers a split device's separate light device (whose only component
--- is "main", so the component check alone would wrongly fall through to
--- the fan branch). Both checks needed side by side — devices in either
--- state can exist at once across a household mid-migration. Neither
--- branch here is itself the light-child device, so cascade_light is
--- only ever reached from the fan side, never recursing into the light.
local function switch_on(driver, device, command)
  if is_light_child(device) or command.component == "light" then
    send_commit(driver, device, { light_mode = baf.OFF_ON_AUTO.ON }, true)
  else
    send_commit(driver, device, { fan_mode = baf.OFF_ON_AUTO.ON }, true)
    cascade_light(driver, device, true)
  end
end

local function switch_off(driver, device, command)
  if is_light_child(device) or command.component == "light" then
    send_commit(driver, device, { light_mode = baf.OFF_ON_AUTO.OFF }, true)
  else
    send_commit(driver, device, { fan_mode = baf.OFF_ON_AUTO.OFF }, true)
    cascade_light(driver, device, false)
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
  -- Fan+Light cascade (see cascade_light above): Off turns the light off
  -- too; On or Auto turns it on — matching how the plain switch
  -- capability already collapses fan_mode's 3 states into on/off
  -- (fan_mode == 0 is the only "off" case there too).
  cascade_light(driver, device, value ~= baf.OFF_ON_AUTO.OFF)
end

-- CORRECTED 2026-08-25: the "never takes effect" conclusion that removed
-- this handler was wrong — reverse_enable does get committed, just with
-- an unpredictable delay (confirmed when one of the two test fans turned up
-- running reverse_enable=true, well after the original short wait-then-
-- verify test looked like it failed; see project-status memory for the
-- full writeup and the incident that caught it). Handler restored.
-- Known real limitation: a command sent here may not visibly apply for
-- some unknown period afterward (minutes, possibly longer) — the app
-- has no way to indicate "pending", so a user re-sending the same
-- command because nothing seemed to happen can end up with both the
-- original and the retry landing unpredictably later. No fix for that
-- currently; just something to keep in mind.
--
-- 2026-08-25: added a stop-the-fan-first interlock, since this original
-- code committed reverse_enable directly regardless of whether the fan
-- was spinning -- the exact sequence that likely put one of the two test fans
-- into reverse at full speed in the first place, and was worked around
-- manually (stop, verify stopped, then flip) via the standalone fix
-- script when that incident was caught. That manual sequence is now
-- built into the handler instead of relying on doing it by hand again.
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

-- 2026-08-27: added plain turnOn/turnOff commands (zero args) alongside
-- the three setXxx(value) commands above, so LED Indicators / Fan Beep /
-- Legacy IR Remote can render as a native switch toggle instead of a
-- list-style dropdown (per user request) -- SmartThings' displayType
-- "switch" needs two separate zero-arg commands, not one command taking
-- a value. Named turnOn/turnOff, not on/off -- literal "on"/"off" command
-- names were rejected by the device command endpoint ("not a valid
-- value") despite being accepted at capability-definition time, evidently
-- reserved for the built-in `switch` capability's own contract. The
-- original setXxx commands are left in place, unused by the current
-- presentation but harmless to keep.
local function led_indicators_on(driver, device, command)
  send_more_commit(device, "led_indicators_enable", true)
end

local function led_indicators_off(driver, device, command)
  send_more_commit(device, "led_indicators_enable", false)
end

--- showSettings turnOn/turnOff (2026-08-29): pure local state, no
--- protocol commit at all -- unlike every other switch handler in this
--- file, there's no real hardware behind this, just a stored value
--- other Settings tiles' visibleCondition gate on (see device_init's
--- seed call for why this is safe to default immediately, unlike
--- sleepMode's genuinely-unknown-until-a-real-command state).
local function show_settings_on(driver, device, command)
  device:emit_component_event(device.profile.components.settings,
    SHOW_SETTINGS_CAP.showSettings({ value = "On" }))
end

local function show_settings_off(driver, device, command)
  device:emit_component_event(device.profile.components.settings,
    SHOW_SETTINGS_CAP.showSettings({ value = "Off" }))
end

--- Presentation switched from "switch" to "list" (2026-08-29, user
--- request: a plain tap-to-open dropdown instead of a toggle, matching
--- fanMode/sleepMode elsewhere in this driver) -- setShowSettings is
--- the command that presentation actually invokes now; turnOn/turnOff
--- above are left wired but unused by the current presentation, same as
--- ledIndicators/etc's own unused setXxx leftovers.
local function set_show_settings(driver, device, command)
  device:emit_component_event(device.profile.components.settings,
    SHOW_SETTINGS_CAP.showSettings({ value = command.args.showSettings }))
end

--- showSchedule: same phantom-switch pattern as showSettings above --
--- pure local UI state, no protocol commit, safe to default immediately
--- (see device_init's seed call). Real value is "On"/"Off", not the
--- original "Show"/"Hide" directly ("Show"/"Hide" now only exist as this
--- tile's on/off LABEL text in its presentation).
---
--- RESOLVED 2026-09-03 -- real root cause found: this driver has zero
--- confirmed-working displayType:switch tiles at all (the LED/beep/IR
--- switch-flip saga's own conclusion was that the switch renderer's knob
--- "may never have actually tracked state"), while scheduleEnabled right
--- next to this one, list-style, has always rendered correctly. And
--- critically: a capability's *rendering* (displayType/switch/list) is
--- controlled entirely by its own `/capabilities/{id}/{version}/
--- presentation` sub-resource, NOT by anything in the device-config's
--- detailView entries -- every prior device-config edit attempting to
--- fix this tile's rendering was structurally inert; the platform
--- silently drops unrecognized display keys from a device-config submit
--- and only ever stores {component, capability, version, visibleCondition}
--- there. Real fix: PUT a list-style presentation directly onto the
--- showSchedule capability (matching scheduleEnabled's shape, key
--- Off/On -> display label Hide/Show), then bake a FRESH device-config
--- vid off of it (device-config presentations are frozen at creation
--- time from whatever the referenced capabilities' presentations were at
--- that moment -- an existing vid does not re-resolve on a later
--- capability-presentation change, and the platform's content-hash dedup
--- will silently hand back a stale vid for byte-identical resubmits, so
--- forcing a genuinely new one needs an actual structural diff
--- somewhere harmless, not just a capability-presentation change alone).
--- Re-runs apply_schedule_status right after a Show Schedule toggle so
--- the per-slot exists-gates (and thus each slot's own visibility)
--- update immediately rather than waiting for the next poll -- added
--- 2026-09-03 alongside the exists-gate feature itself. Wrapped in
--- pcall, same discipline as every other apply_schedule_status call
--- site, since it opens a real network connection to the fan.
local function refresh_schedule_exists_gates(driver, device)
  local ok, err = pcall(apply_schedule_status, driver, device)
  if not ok then
    log.error("BAF apply_schedule_status crashed after a Show Schedule toggle: " .. tostring(err))
  end
end

local function show_schedule_on(driver, device, command)
  device:emit_component_event(device.profile.components.schedule,
    SHOW_SCHEDULE_CAP.showSchedule({ value = "On" }))
  refresh_schedule_exists_gates(driver, device)
end

local function show_schedule_off(driver, device, command)
  device:emit_component_event(device.profile.components.schedule,
    SHOW_SCHEDULE_CAP.showSchedule({ value = "Off" }))
  refresh_schedule_exists_gates(driver, device)
end

--- 2026-09-03: root cause of the toggle-knob bug turned out to be much
--- simpler than any of the above -- the presentation was never actually
--- switched from displayType:switch to displayType:list (only the
--- capability's command schema was updated, not the device-config); a
--- `switch`-style tile has no confirmed-working example anywhere in this
--- driver (scheduleEnabled, the proven-good sibling tile right next to
--- this one, has always been list-style). This handler backs the new
--- `setShowSchedule` command that the list-style presentation actually
--- calls; turnOn/turnOff above are now unused leftovers, same pattern as
--- other capabilities in this driver that carry harmless dead commands.
local function set_show_schedule(driver, device, command)
  device:emit_component_event(device.profile.components.schedule,
    SHOW_SCHEDULE_CAP.showSchedule({ value = command.args.showSchedule }))
  refresh_schedule_exists_gates(driver, device)
end

--- Real read-modify-write: queries the current schedules, re-derives
--- `slot`'s auto-discovered target the same way apply_schedule_status
--- does (sort named schedules alphabetically, pick position `slot.index`
--- -- see the header comment above SCHEDULE_SLOTS), patches ONLY the
--- enable flag via baf.set_schedule_enabled (never reconstructs a
--- schedule from scratch), writes it back, and verifies via
--- BafClient.commit_schedule_and_verify. Every failure mode (no IP yet,
--- query failed, nothing at that position, patch refused, write not
--- verified) is logged and returns without emitting a new (possibly
--- wrong) status -- apply_schedule_status will pick up whatever the
--- fan's real state actually is on the next refresh/init rather than
--- this handler ever guessing.
--- **Re-resolves fresh at command time rather than trusting a cached
--- position** -- this is what makes auto-discovery safe to act on: the
--- schedule this command actually touches is always whatever the same
--- sort+pick algorithm currently returns for this slot, guaranteed
--- consistent with whatever apply_schedule_status most recently
--- displayed (same algorithm, just possibly a few seconds staler).
local function set_named_schedule_enabled(driver, device, command, slot)
  local ip = resolve_ip(device)
  if not ip then
    log.warn("BAF " .. slot.command_name .. " attempted before device is fully configured")
    return
  end
  local schedules, query_err = BafClient.query_schedules(ip, 5)
  if not schedules then
    log.error("BAF " .. slot.command_name .. ": schedule query failed: " .. tostring(query_err))
    return
  end
  local named = baf.sorted_named_schedules(schedules)
  local sched = named[slot.index]
  if not sched then
    log.error("BAF " .. slot.command_name .. ": no named schedule at position " .. slot.index ..
      " (" .. #named .. " named schedule(s) present)")
    return
  end
  local want_enabled = command.args.value == "On"
  local new_raw, patch_err = baf.set_schedule_enabled(sched.raw, want_enabled)
  if not new_raw then
    log.error("BAF " .. slot.command_name .. ": patch refused: " .. tostring(patch_err))
    return
  end
  local ok, write_err = BafClient.commit_schedule_and_verify(ip, new_raw, 5)
  if not ok then
    log.error("BAF " .. slot.command_name .. ": write did not verify: " .. tostring(write_err))
    return
  end
  device:emit_component_event(device.profile.components.schedule,
    slot.cap[slot.attr]({ value = want_enabled and "On" or "Off" }))
end

local function set_schedule_enabled(driver, device, command)
  set_named_schedule_enabled(driver, device, command, SCHEDULE_SLOTS[1])
end

local function set_second_schedule_enabled(driver, device, command)
  set_named_schedule_enabled(driver, device, command, SCHEDULE_SLOTS[2])
end

local function set_third_schedule_enabled(driver, device, command)
  set_named_schedule_enabled(driver, device, command, SCHEDULE_SLOTS[3])
end

local function set_fourth_schedule_enabled(driver, device, command)
  set_named_schedule_enabled(driver, device, command, SCHEDULE_SLOTS[4])
end

local function set_fifth_schedule_enabled(driver, device, command)
  set_named_schedule_enabled(driver, device, command, SCHEDULE_SLOTS[5])
end

local function fan_beep_on(driver, device, command)
  send_more_commit(device, "fan_beep_enable", true)
end

local function fan_beep_off(driver, device, command)
  send_more_commit(device, "fan_beep_enable", false)
end

local function legacy_ir_remote_on(driver, device, command)
  send_more_commit(device, "legacy_ir_remote_enable", true)
end

local function legacy_ir_remote_off(driver, device, command)
  send_more_commit(device, "legacy_ir_remote_enable", false)
end

local function set_sleep_mode(driver, device, command)
  send_more_commit(device, "sleep_mode_enable", command.args.sleepMode == "On")
end

-- Sleep/Wake Up sub-settings (2026-08-27) — all direct-query fields, so
-- these use the normal send_commit(..., true) path (verify_commit
-- re-queries the FAN or LIGHT category and calls apply_fan_status_or_light,
-- which now also calls apply_sleep_status — see above), unlike
-- send_more_commit's push-read mechanism needed for sleepMode/LED/Beep/IR.
local function set_sleep_fan_mode(driver, device, command)
  local value = STRING_TO_OFF_ON_AUTO[command.args.value]
  if value then
    send_commit(driver, device, { sleep_fan_mode = value }, true)
  end
end

local function set_sleep_speed(driver, device, command)
  send_commit(driver, device, { sleep_speed = math.floor(command.args.value) }, true)
end

local function set_sleep_ideal_temp(driver, device, command)
  local value = math.floor(command.args.value * 100 + 0.5)
  send_commit(driver, device, { sleep_ideal_temp = value }, true)
end

local function sleep_timer_on(driver, device, command)
  send_commit(driver, device, { sleep_timer_enable = true }, true)
end

local function sleep_timer_off(driver, device, command)
  send_commit(driver, device, { sleep_timer_enable = false }, true)
end

local function set_sleep_timer_end_speed(driver, device, command)
  send_commit(driver, device, { sleep_timer_end_speed = math.floor(command.args.value) }, true)
end

local function set_sleep_timer_duration(driver, device, command)
  send_commit(driver, device, { sleep_timer_duration = math.floor(command.args.value * 60) }, true)
end

local function sleep_return_to_auto_on(driver, device, command)
  send_commit(driver, device, { sleep_return_to_auto = true }, true)
end

local function sleep_return_to_auto_off(driver, device, command)
  send_commit(driver, device, { sleep_return_to_auto = false }, true)
end

local function set_sleep_return_to_auto_duration(driver, device, command)
  send_commit(driver, device, { sleep_return_to_auto_secs = math.floor(command.args.value * 60) }, true)
end

local function set_sleep_brightness_mode(driver, device, command)
  local value = STRING_TO_BRIGHTNESS_MODE[command.args.value]
  if value then
    send_commit(driver, device, { sleep_brightness_mode = value }, true)
  end
end

local function set_sleep_brightness_percent(driver, device, command)
  send_commit(driver, device, { sleep_brightness_percent = math.floor(command.args.value) }, true)
end

local function set_wake_up_mode(driver, device, command)
  local value = STRING_TO_WAKE_MODE[command.args.value]
  if value then
    send_commit(driver, device, { wake_up_mode = value }, true)
  end
end

local function set_wake_up_brightness(driver, device, command)
  send_commit(driver, device, { wake_up_brightness = math.floor(command.args.value) }, true)
end

local function set_wake_up_motion_timeout(driver, device, command)
  send_commit(driver, device, { wake_up_motion_timeout_secs = math.floor(command.args.value * 60) }, true)
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
  local ok, err = pcall(apply_schedule_status, driver, device)
  if not ok then
    log.error("BAF apply_schedule_status crashed during refresh: " .. tostring(err))
  end
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
      ["turnOn"] = led_indicators_on,
      ["turnOff"] = led_indicators_off,
    },
    [SHOW_SETTINGS_CAP.ID] = {
      [SHOW_SETTINGS_CAP.commands.setShowSettings.NAME] = set_show_settings,
      ["turnOn"] = show_settings_on,
      ["turnOff"] = show_settings_off,
    },
    [FAN_BEEP_CAP.ID] = {
      [FAN_BEEP_CAP.commands.setFanBeep.NAME] = set_fan_beep,
      ["turnOn"] = fan_beep_on,
      ["turnOff"] = fan_beep_off,
    },
    [LEGACY_IR_REMOTE_CAP.ID] = {
      [LEGACY_IR_REMOTE_CAP.commands.setLegacyIrRemote.NAME] = set_legacy_ir_remote,
      ["turnOn"] = legacy_ir_remote_on,
      ["turnOff"] = legacy_ir_remote_off,
    },
    [SLEEP_MODE_CAP.ID] = {
      [SLEEP_MODE_CAP.commands.setSleepMode.NAME] = set_sleep_mode,
    },
    -- Sleep/Wake Up sub-settings (2026-08-27): literal string command
    -- names throughout, not `.commands.X.NAME` -- these capabilities were
    -- created moments before this deploy, same capability-definition
    -- propagation-lag risk that caused a real driver-crashing FATAL
    -- earlier this session (see project-status memory). Once these have
    -- survived a redeploy or two, `.commands.X.NAME` would be safe to
    -- switch to, but there's no benefit to doing so.
    [SLEEP_FAN_MODE_CAP.ID] = {
      ["setSleepFanMode"] = set_sleep_fan_mode,
    },
    [SLEEP_SPEED_CAP.ID] = {
      ["setSleepSpeed"] = set_sleep_speed,
    },
    [SLEEP_IDEAL_TEMP_CAP.ID] = {
      ["setSleepIdealTemp"] = set_sleep_ideal_temp,
    },
    [SLEEP_TIMER_CAP.ID] = {
      ["setSleepTimerEnable"] = function(driver, device, command)
        send_commit(driver, device, { sleep_timer_enable = command.args.value == "On" }, true)
      end,
      ["turnOn"] = sleep_timer_on,
      ["turnOff"] = sleep_timer_off,
    },
    [SLEEP_TIMER_END_SPEED_CAP.ID] = {
      ["setSleepTimerEndSpeed"] = set_sleep_timer_end_speed,
    },
    [SLEEP_TIMER_DURATION_CAP.ID] = {
      ["setSleepTimerDuration"] = set_sleep_timer_duration,
    },
    [SLEEP_RETURN_TO_AUTO_CAP.ID] = {
      ["setSleepReturnToAuto"] = function(driver, device, command)
        send_commit(driver, device, { sleep_return_to_auto = command.args.value == "On" }, true)
      end,
      ["turnOn"] = sleep_return_to_auto_on,
      ["turnOff"] = sleep_return_to_auto_off,
    },
    [SLEEP_RETURN_TO_AUTO_DURATION_CAP.ID] = {
      ["setSleepReturnToAutoDuration"] = set_sleep_return_to_auto_duration,
    },
    [SLEEP_BRIGHTNESS_MODE_CAP.ID] = {
      ["setSleepBrightnessMode"] = set_sleep_brightness_mode,
    },
    [SLEEP_BRIGHTNESS_PERCENT_CAP.ID] = {
      ["setSleepBrightnessPercent"] = set_sleep_brightness_percent,
    },
    [WAKE_UP_MODE_CAP.ID] = {
      ["setWakeUpMode"] = set_wake_up_mode,
    },
    [WAKE_UP_BRIGHTNESS_CAP.ID] = {
      ["setWakeUpBrightness"] = set_wake_up_brightness,
    },
    [WAKE_UP_MOTION_TIMEOUT_CAP.ID] = {
      ["setWakeUpMotionTimeout"] = set_wake_up_motion_timeout,
    },
    -- Schedule (2026-09-02): literal string command names, same
    -- just-created-capability propagation-lag caution as the Sleep
    -- capabilities above.
    [SHOW_SCHEDULE_CAP.ID] = {
      ["turnOn"] = show_schedule_on,
      ["turnOff"] = show_schedule_off,
      ["setShowSchedule"] = set_show_schedule,
    },
    [SCHEDULE_ENABLED_CAP.ID] = {
      ["setScheduleEnabled"] = set_schedule_enabled,
    },
    [SECOND_SCHEDULE_ENABLED_CAP.ID] = {
      ["setSecondScheduleEnabled"] = set_second_schedule_enabled,
    },
    [THIRD_SCHEDULE_ENABLED_CAP.ID] = {
      ["setThirdScheduleEnabled"] = set_third_schedule_enabled,
    },
    [FOURTH_SCHEDULE_ENABLED_CAP.ID] = {
      ["setFourthScheduleEnabled"] = set_fourth_schedule_enabled,
    },
    [FIFTH_SCHEDULE_ENABLED_CAP.ID] = {
      ["setFifthScheduleEnabled"] = set_fifth_schedule_enabled,
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
