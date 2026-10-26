--- Panasonic air conditioners through the ProtoART ClimateControl module
--- (PANA_CNCNT_ATA_WIFI), over its local HTTP API.
---
--- One device per module (per indoor unit): power, mode, fan speed,
--- temperature setpoint, room temperature, outdoor temperature and power
--- use. Status is polled from GET /control; commands are
--- /control?cmd=heatpump&<key>=<value>.
---
--- API reference: https://protoart.net/knowledgebase/pana_cncnt_ata_wifi_http_api_mqtt_topics/

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"

local Api = require "api"
local Status = require "status"
local discovery = require "discovery"

local PRESET_CAP = capabilities["aboutisland47519.preset"]
local VANE_CAP = capabilities["aboutisland47519.verticalVane"]
local WIDEVANE_CAP = capabilities["aboutisland47519.horizontalVane"]
local LINK_CAP = capabilities["aboutisland47519.indoorUnitLink"]
local TEMP_INPUT_CAP = capabilities["aboutisland47519.temperatureInput"]
local WIFI_CAP = capabilities["aboutisland47519.wifiSignal"]
local IP_CAP = capabilities["aboutisland47519.ipAddress"]
local MAC_CAP = capabilities["aboutisland47519.macAddress"]
local FIRMWARE_CAP = capabilities["aboutisland47519.firmware"]
local UPTIME_CAP = capabilities["aboutisland47519.uptime"]
local MODULE_ID_CAP = capabilities["aboutisland47519.moduleId"]
local RESTART_CAP = capabilities["aboutisland47519.restartModule"]

local PROFILE = "climacontrol-panasonic.v3"

local IP_FIELD = "ip"
local FAILURES_FIELD = "failures"
local POLL_TIMER_FIELD = "poll_timer"
local EMIT_CACHE_FIELD = "emit_cache"
local LAYOUT_LOGGED_FIELD = "layout_logged"
local LAST_FIELD = "last_status"
local RANGE_FIELD = "setpoint_range"

local COMMAND_REPOLL_SECONDS = 2
local OFFLINE_AFTER_FAILURES = 3
local REDISCOVER_AFTER_FAILURES = 2
-- Setpoint range until the module reports its own (heatpump.coolmin/coolmax).
local SETPOINT_MIN, SETPOINT_MAX = 16, 30

-- ===== Settings and address =====

local function get_settings(device)
  local p = device.preferences or {}
  local ip = tostring(p.ipAddress or "0.0.0.0")
  if not ip:match("^%d+%.%d+%.%d+%.%d+$") or ip == "0.0.0.0" then
    ip = nil
  end
  return {
    ip = ip,
    poll_interval = math.max(5, tonumber(p.pollInterval) or 15),
    mode_turns_on = p.modeTurnsOn ~= false,
  }
end

local function mac_of(device)
  local dni = tostring(device.device_network_id)
  local mac = dni:sub(#discovery.DNI_PREFIX + 1)
  return mac:match("^%x+$") and #mac == 12 and mac or nil
end

--- The module's IP: the setting if given, else the last known address,
--- else (or after repeated failures) found again over mDNS by MAC address.
local function resolve_ip(driver, device, force)
  local s = get_settings(device)
  if s.ip then
    return s.ip
  end
  local ip = device:get_field(IP_FIELD)
  if not ip and driver.found_ips then
    ip = driver.found_ips[device.device_network_id]
    if ip then
      device:set_field(IP_FIELD, ip, { persist = true })
    end
  end
  local mac = mac_of(device)
  if (force or not ip) and mac then
    for _, m in ipairs(discovery.find_modules()) do
      if m.mac == mac then
        if m.ip ~= ip then
          log.info(device.label .. ": module found at " .. m.ip)
        end
        ip = m.ip
        device:set_field(IP_FIELD, ip, { persist = true })
        break
      end
    end
  end
  return ip
end

-- ===== Events =====

--- Emit only when the value changed since the last emit (polling every few
--- seconds would otherwise fill the device history).
local function emit(device, component_id, key, event)
  local cache = device:get_field(EMIT_CACHE_FIELD) or {}
  local id = component_id .. "/" .. key
  local value = event.value
  if type(value) == "table" then
    value = tostring(value.value) .. (value.unit or "")
  end
  local text = tostring(value)
  if cache[id] == text then
    return
  end
  cache[id] = text
  device:set_field(EMIT_CACHE_FIELD, cache)
  if component_id == "main" then
    device:emit_event(event)
  else
    local component = device.profile.components[component_id]
    if component then
      device:emit_component_event(component, event)
    end
  end
end

--- The setpoint range: the module's, else the default.
local function setpoint_range(device)
  local r = device:get_field(RANGE_FIELD)
  if r then
    return r.min, r.max
  end
  return SETPOINT_MIN, SETPOINT_MAX
end

local function emit_setpoint_range(device)
  local min, max = setpoint_range(device)
  device:emit_event(capabilities.thermostatCoolingSetpoint.coolingSetpointRange(
    { value = { minimum = min, maximum = max, step = 0.5 }, unit = "C" }))
end

local function apply_status(device, parsed)
  local min, max = parsed.setpoint_min, parsed.setpoint_max
  if min and max and min < max then
    local old_min, old_max = setpoint_range(device)
    device:set_field(RANGE_FIELD, { min = min, max = max }, { persist = true })
    if min ~= old_min or max ~= old_max then
      emit_setpoint_range(device)
    end
  end
  if parsed.power then
    emit(device, "main", "switch", capabilities.switch.switch(parsed.power))
  end
  if parsed.mode then
    emit(device, "main", "mode", capabilities.airConditionerMode.airConditionerMode(parsed.mode))
  end
  if parsed.fan then
    emit(device, "main", "fan", capabilities.airConditionerFanMode.fanMode(parsed.fan))
  end
  if parsed.setpoint then
    emit(device, "main", "setpoint",
      capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = parsed.setpoint, unit = "C" }))
  end
  if parsed.room then
    emit(device, "main", "room", capabilities.temperatureMeasurement.temperature({ value = parsed.room, unit = "C" }))
  end
  if parsed.watts then
    emit(device, "main", "watts", capabilities.powerMeter.power({ value = parsed.watts, unit = "W" }))
  end
  if parsed.outdoor then
    emit(device, "outdoor", "temp", capabilities.temperatureMeasurement.temperature({ value = parsed.outdoor, unit = "C" }))
  end
  if parsed.preset then
    emit(device, "main", "preset", PRESET_CAP.preset(parsed.preset))
  end
  if parsed.vane then
    emit(device, "main", "vane", VANE_CAP.vane(parsed.vane))
  end
  if parsed.widevane then
    emit(device, "main", "widevane", WIDEVANE_CAP.vane(parsed.widevane))
  end
  for key, state in pairs(parsed.features or {}) do
    if state then
      emit(device, key, "switch", capabilities.switch.switch(state))
    end
  end
  -- Module component: diagnostics from the status's sys/wifi/fw sections.
  local module_tiles = {
    { "link", LINK_CAP.indoorUnitLink, Status.link_text(parsed) },
    { "tinp", TEMP_INPUT_CAP.temperatureInput, Status.temp_input_text(parsed.temp_input) },
    { "rssi", WIFI_CAP.wifiSignal, Status.rssi_text(parsed.rssi) },
    { "ip", IP_CAP.ipAddress, parsed.ip and tostring(parsed.ip) },
    { "mac", MAC_CAP.macAddress, Status.mac_text(parsed.mac) },
    { "fw", FIRMWARE_CAP.firmware, Status.firmware_text(parsed.firmware, parsed.firmware_latest) },
    { "up", UPTIME_CAP.uptime, Status.uptime_text(parsed.uptime) },
    { "id", MODULE_ID_CAP.moduleId, parsed.module_id and tostring(parsed.module_id) },
  }
  for _, tile in ipairs(module_tiles) do
    if tile[3] then
      emit(device, "module", tile[1], tile[2](tile[3]))
    end
  end
end

-- ===== Polling =====

local schedule_poll

local function poll_once(driver, device)
  local failures = device:get_field(FAILURES_FIELD) or 0
  local ip = resolve_ip(driver, device, failures >= REDISCOVER_AFTER_FAILURES)
  if not ip then
    log.warn(device.label .. ": module not found; set its IP Address in Settings or check it's on the network")
    return false
  end
  local data, err = Api.status(ip)
  if not data then
    log.warn(device.label .. ": status from " .. ip .. " failed: " .. tostring(err))
    return false
  end
  if not device:get_field(LAYOUT_LOGGED_FIELD) then
    device:set_field(LAYOUT_LOGGED_FIELD, true)
    log.info(device.label .. ": status JSON layout " .. Status.describe(data))
  end
  local parsed = Status.parse(data)
  if Status.unit_disconnected(parsed) then
    log.warn(device.label .. ": module is up but not connected to the air conditioner (check the CN-CNT cable)")
  end
  device:set_field(LAST_FIELD, parsed)
  apply_status(device, parsed)
  return true
end

local function poll(driver, device)
  local ok, result = pcall(poll_once, driver, device)
  if not ok then
    log.error(device.label .. ": poll error: " .. tostring(result))
  end
  if ok and result then
    if (device:get_field(FAILURES_FIELD) or 0) >= OFFLINE_AFTER_FAILURES then
      device:online()
    end
    device:set_field(FAILURES_FIELD, 0)
  else
    local failures = (device:get_field(FAILURES_FIELD) or 0) + 1
    device:set_field(FAILURES_FIELD, failures)
    if failures == OFFLINE_AFTER_FAILURES then
      device:offline()
    end
  end
  schedule_poll(driver, device, get_settings(device).poll_interval)
end

schedule_poll = function(driver, device, delay)
  local timer = device:get_field(POLL_TIMER_FIELD)
  if timer then
    device.thread:cancel_timer(timer)
  end
  device:set_field(POLL_TIMER_FIELD, device.thread:call_with_delay(math.max(delay, 0), function()
    device:set_field(POLL_TIMER_FIELD, nil)
    poll(driver, device)
  end, "climacontrol poll"))
end

-- ===== Commands =====

--- Send commands (a list of {key, value}), then read the status back soon.
local function send(driver, device, commands)
  local ip = resolve_ip(driver, device, false)
  if not ip then
    log.warn(device.label .. ": command ignored, module address unknown")
    return false
  end
  for _, c in ipairs(commands) do
    local ok, err = Api.command(ip, c[1], c[2])
    if not ok then
      log.warn(device.label .. ": " .. c[1] .. "=" .. tostring(c[2]) .. " failed: " .. tostring(err))
      schedule_poll(driver, device, COMMAND_REPOLL_SECONDS)
      return false
    end
  end
  schedule_poll(driver, device, COMMAND_REPOLL_SECONDS)
  return true
end

--- The main switch is power; the eco/econavi/nanoex/milddry components'
--- switches are those features, sent under the component's name.
local function set_switch(driver, device, command, state)
  local component = command.component or "main"
  local key = component == "main" and "power" or component
  if send(driver, device, { { key, state } }) then
    emit(device, component, "switch", capabilities.switch.switch(state))
  end
end

local function switch_on(driver, device, command)
  set_switch(driver, device, command, "on")
end

local function switch_off(driver, device, command)
  set_switch(driver, device, command, "off")
end

local function set_preset(driver, device, command)
  local value = command.args.value
  if send(driver, device, { { "preset", value } }) then
    emit(device, "main", "preset", PRESET_CAP.preset(value))
  end
end

local function set_vane(driver, device, command)
  local value = command.args.value
  if send(driver, device, { { "vane", value } }) then
    emit(device, "main", "vane", VANE_CAP.vane(value))
  end
end

local function set_widevane(driver, device, command)
  local value = command.args.value
  if send(driver, device, { { "widevane", value } }) then
    emit(device, "main", "widevane", WIDEVANE_CAP.vane(value))
  end
end

local function set_mode(driver, device, command)
  local mode = command.args.mode
  local value = Status.mode_to_device(mode)
  if not value then
    log.warn(device.label .. ": unsupported mode " .. tostring(mode))
    return
  end
  local commands = { { "mode", value } }
  local last = device:get_field(LAST_FIELD) or {}
  local turn_on = get_settings(device).mode_turns_on and last.power ~= "on"
  if turn_on then
    table.insert(commands, { "power", "on" })
  end
  if send(driver, device, commands) then
    emit(device, "main", "mode", capabilities.airConditionerMode.airConditionerMode(Status.mode_from_device(value)))
    if turn_on then
      emit(device, "main", "switch", capabilities.switch.switch("on"))
    end
  end
end

local function set_fan_mode(driver, device, command)
  local fan = command.args.fanMode
  local value = Status.fan_to_device(fan)
  if not value then
    log.warn(device.label .. ": unsupported fan speed " .. tostring(fan))
    return
  end
  if send(driver, device, { { "fan", value } }) then
    emit(device, "main", "fan", capabilities.airConditionerFanMode.fanMode(fan))
  end
end

local function set_cooling_setpoint(driver, device, command)
  local value = tonumber(command.args.setpoint)
  if not value then
    return
  end
  -- Panasonic remotes step in 0.5 °C.
  value = math.floor(value * 2 + 0.5) / 2
  local min, max = setpoint_range(device)
  value = math.max(min, math.min(max, value))
  local text = (value % 1 == 0) and string.format("%d", value) or string.format("%.1f", value)
  if send(driver, device, { { "set_temperature", text } }) then
    emit(device, "main", "setpoint", capabilities.thermostatCoolingSetpoint.coolingSetpoint({ value = value, unit = "C" }))
  end
end

local function restart_module(driver, device)
  local ip = resolve_ip(driver, device, false)
  if not ip then
    log.warn(device.label .. ": restart ignored, module address unknown")
    return
  end
  local ok, err = Api.restart(ip)
  if ok then
    log.info(device.label .. ": module restarting")
  else
    log.warn(device.label .. ": restart failed: " .. tostring(err))
  end
  -- It's back in a few seconds; read the status once it should be.
  schedule_poll(driver, device, 20)
end

local function refresh(driver, device)
  device:set_field(EMIT_CACHE_FIELD, {})
  schedule_poll(driver, device, 0)
end

-- ===== Lifecycle =====

local function emit_supported(device)
  device:emit_event(capabilities.airConditionerMode.supportedAcModes(Status.SUPPORTED_MODES))
  device:emit_event(capabilities.airConditionerFanMode.supportedAcFanModes(Status.SUPPORTED_FAN_MODES))
  emit_setpoint_range(device)
end

local function device_init(driver, device)
  -- A device created with an older profile gets the current one.
  if not device:supports_capability_by_id(RESTART_CAP.ID) then
    log.info(tostring(device.label) .. ": switching to profile " .. PROFILE)
    device:try_update_metadata({ profile = PROFILE })
  end
  emit_supported(device)
  device:set_field(EMIT_CACHE_FIELD, {})
  device:set_field(LAYOUT_LOGGED_FIELD, nil)
  schedule_poll(driver, device, 1)
end

local function device_added(driver, device)
  emit_supported(device)
end

local function info_changed(driver, device, event, args)
  device:set_field(FAILURES_FIELD, 0)
  schedule_poll(driver, device, 1)
end

local function device_removed(driver, device)
  local timer = device:get_field(POLL_TIMER_FIELD)
  if timer then
    device.thread:cancel_timer(timer)
  end
end

local climacontrol_driver = Driver("panasonic-climacontrol-lan", {
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
    [capabilities.airConditionerMode.ID] = {
      [capabilities.airConditionerMode.commands.setAirConditionerMode.NAME] = set_mode,
    },
    [capabilities.airConditionerFanMode.ID] = {
      [capabilities.airConditionerFanMode.commands.setFanMode.NAME] = set_fan_mode,
    },
    [capabilities.thermostatCoolingSetpoint.ID] = {
      [capabilities.thermostatCoolingSetpoint.commands.setCoolingSetpoint.NAME] = set_cooling_setpoint,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh,
    },
    [PRESET_CAP.ID] = {
      [PRESET_CAP.commands.setPreset.NAME] = set_preset,
    },
    [VANE_CAP.ID] = {
      [VANE_CAP.commands.setVane.NAME] = set_vane,
    },
    [WIDEVANE_CAP.ID] = {
      [WIDEVANE_CAP.commands.setVane.NAME] = set_widevane,
    },
    [RESTART_CAP.ID] = {
      [RESTART_CAP.commands.push.NAME] = restart_module,
    },
  },
})

climacontrol_driver:run()
