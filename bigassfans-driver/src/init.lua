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
local ADD_ANOTHER_CAP = capabilities["aboutisland47519.addAnotherFan"]

local OFF_ON_AUTO_TO_STRING = { [0] = "Off", [1] = "On", [2] = "Auto" }
local STRING_TO_OFF_ON_AUTO = { Off = 0, On = 1, Auto = 2 }

--- Resolves the IP to talk to: the "Manual IP Override" preference wins if
--- the user has set it to something other than the 0.0.0.0 sentinel;
--- otherwise the persisted field mDNS discovery populated (nil if this
--- device was created manually and mDNS hasn't found it yet).
local function resolve_ip(device)
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

local function apply_light_status(device, light)
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
local function poll_once(driver, device)
  local ok, err = pcall(function()
    local ip = resolve_ip(device)
    if not ip then
      log.info("BAF device has no known IP yet (mDNS hasn't found it) — skipping poll")
      return
    end

    -- Both categories over one shared connection, not two separate
    -- connect/close cycles — see BafClient.query_multi for why (2026-08-13
    -- connection-churn/light-blip finding).
    local results, err = BafClient.query_multi(ip, { "FAN", "LIGHT" }, 5)
    if not results then
      log.error("BAF poll query failed for " .. ip .. ": " .. tostring(err))
      return
    end
    apply_fan_status(device, results.FAN)
    apply_light_status(device, results.LIGHT)
  end)
  if not ok then
    log.error("BAF poll crashed: " .. tostring(err))
  end
end

local function start_polling(driver, device)
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
    poll_once(driver, device)
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
local WITH_ADDFAN_PROFILE = "bigassfans-h.v1"
local NO_ADDFAN_PROFILE = "bigassfans-h-no-addfan.v1"

-- Real deviceIntegrationProfile UUIDs, confirmed via live device query.
local WITH_ADDFAN_PROFILE_ID = "5390ffa7-7abe-377e-a528-4cc7ee7eef93"
local NO_ADDFAN_PROFILE_ID = "ea2c24ce-41e8-3fbc-8e24-844af1f928ad"

local PROFILE_TO_ID = {
  [WITH_ADDFAN_PROFILE] = WITH_ADDFAN_PROFILE_ID,
  [NO_ADDFAN_PROFILE] = NO_ADDFAN_PROFILE_ID,
}

local function profile_for(device)
  local prefs = device.preferences or {}
  if prefs.hideAddFan then
    return NO_ADDFAN_PROFILE
  end
  return WITH_ADDFAN_PROFILE
end

local ACTIVE_PROFILE_FIELD = "active_profile"

local function ensure_correct_profile(device)
  local target = profile_for(device)
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

local function device_init(driver, device)
  log.info("BAF device init: " .. device.id)
  ensure_correct_profile(device)
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

local function switch_on(driver, device, command)
  if command.component == "light" then
    send_commit(driver, device, { light_mode = baf.OFF_ON_AUTO.ON }, true)
  else
    send_commit(driver, device, { fan_mode = baf.OFF_ON_AUTO.ON }, true)
  end
end

local function switch_off(driver, device, command)
  if command.component == "light" then
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

local function set_direction(driver, device, command)
  send_commit(driver, device, { reverse_enable = command.args.direction == "Reverse" }, true)
end

local function set_whoosh(driver, device, command)
  send_commit(driver, device, { whoosh_enable = command.args.whoosh == "On" }, true)
end

local function set_eco(driver, device, command)
  send_commit(driver, device, { eco_enable = command.args.eco == "On" }, true)
end

local function refresh_handler(driver, device, command)
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
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
    [ADD_ANOTHER_CAP.ID] = {
      [ADD_ANOTHER_CAP.commands.push.NAME] = add_another_handler,
    },
  },
})

baf_driver:run()
