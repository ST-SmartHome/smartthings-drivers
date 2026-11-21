--- Panasonic air conditioners through the ProtoART ClimateControl module
--- (PANA_CNCNT_ATA_WIFI), over its local HTTP API.
---
--- One device per module (per indoor unit): power, mode, fan speed,
--- temperature setpoint, room temperature, outdoor temperature and power
--- use, plus the wireless thermometer's readings when the module uses one. Status is polled from GET /control; commands are
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
local SENSOR_BATTERY_CAP = capabilities["aboutisland47519.sensorBattery"]
local GUARD_CAP = capabilities["aboutisland47519.roomGuard"]
-- The module accepts a guard range of 5-40 °C.
local GUARD_MIN, GUARD_MAX = 5, 40

local PROFILE = "climacontrol-panasonic.v3"
-- The same plus a Wireless Thermometer component, used while the module's
-- temperature input is its wireless thermometer.
local THERMO_PROFILE = "climacontrol-panasonic-thermometer.v1"
-- "Unit features" setting -> the profiles without the extras that unit lacks
-- (nanoe X, Eco Navi, Mild Dry, left/right louvre). "all" keeps every extra.
local FEATURE_SETS = { all = true, nanoex = true, econavi = true, basic = true }
-- What each feature set hides. "minimal" (Basic without Eco) is never a
-- setting: it's used when the unit itself rejected Eco.
-- What each feature set's PROFILE leaves out (profile names; never change,
-- devices use them).
local HIDES = {
  all = {},
  nanoex = { econavi = true, milddry = true },
  econavi = { nanoex = true, milddry = true },
  basic = { econavi = true, nanoex = true, milddry = true, widevane = true },
  minimal = { econavi = true, nanoex = true, milddry = true, widevane = true, eco = true },
}
-- What each "Unit features" choice hides. Basic leaves the left/right vane to
-- learning (units without louvres refuse it), so it also suits units that have it.
local SETTING_HIDES = {
  all = HIDES.all,
  nanoex = HIDES.nanoex,
  econavi = HIDES.econavi,
  basic = { econavi = true, nanoex = true, milddry = true },
}
local SET_ORDER = { "all", "nanoex", "econavi", "basic", "minimal" }
local AUTH_FIELD = "needs_password"

local IP_FIELD = "ip"
local FAILURES_FIELD = "failures"
local OFFLINE_FIELD = "marked_offline"
local POLL_TIMER_FIELD = "poll_timer"
local EMIT_CACHE_FIELD = "emit_cache"
local LAYOUT_LOGGED_FIELD = "layout_logged"
local LAST_FIELD = "last_status"
local RANGE_FIELD = "setpoint_range"
local PROFILE_REQUEST_FIELD = "profile_request"
local THERMO_ABSENT_FIELD = "thermometer_absent"
local WINDOW_ABSENT_FIELD = "window_absent"
-- Each paired window/door sensor is also its own child device (contact + battery)
local WINDOW_PROFILE = "climacontrol-window-sensor.v1"
local WINDOW_KEY = "-window-"
local CHILD_CACHE_FIELD = "child_cache"
local CHILD_RETRY_SECONDS = 300
-- Sensors whose devices the user deleted (by MAC): not added again until the
-- next "Scan nearby".
local IGNORED_WINDOWS_FIELD = "ignored_windows"
local WINDOW_MISSING_FIELD = "window_missing"
-- The module's MAC, learned from its status (devices added before their
-- password was known are named by host, not MAC).
local MAC_FIELD = "mac"
local LAST_SCAN_FIELD = "last_scan"
-- A module that stops answering is looked for on the network at most this often.
local RESCAN_SECONDS = 300

local COMMAND_REPOLL_SECONDS = 2
-- After a command, read the status every few seconds for about 60 s: the unit
-- puts back a setting it doesn't support 10-35 s later, and SmartThings shows
-- the real setting again at once.
local FAST_POLL_SECONDS = 5
local FAST_POLLS = 12
local FAST_POLLS_FIELD = "fast_polls"
-- Settings the unit rejected (put back within about 60 s), counted per key:
-- after LEARN_AFTER rejections the switch/control is hidden on this unit.
-- Cleared when the user changes "Unit features".
local LEARNED_FIELD = "rejected"
local PENDING_FIELD = "pending_checks"
local LEARN_AFTER = 2
local JUDGE_SECONDS = 60
local OFFLINE_AFTER_FAILURES = 3
local REDISCOVER_AFTER_FAILURES = 2
-- Polls without a paired thermometer before its component is removed.
local THERMO_REMOVE_AFTER_POLLS = 3
-- Setpoint range until the module reports its own (heatpump.coolmin/coolmax).
local SETPOINT_MIN, SETPOINT_MAX = 16, 30

-- ===== Settings and address =====

local function get_settings(device)
  local p = device.preferences or {}
  local ip = tostring(p.ipAddress or "0.0.0.0")
  if not ip:match("^%d+%.%d+%.%d+%.%d+$") or ip == "0.0.0.0" then
    ip = nil
  end
  local pw = p.modulePassword
  if type(pw) ~= "string" or pw == "" then
    pw = device:get_field(discovery.PASSWORD_FIELD)   -- one that worked during a scan
  end
  return {
    ip = ip,
    password = (type(pw) == "string" and pw ~= "") and pw or nil,
    poll_interval = math.max(5, tonumber(p.pollInterval) or 15),
    mode_turns_on = p.modeTurnsOn ~= false,
    cooling_only = p.coolingOnly == true,
    features = FEATURE_SETS[p.unitFeatures] and p.unitFeatures or "all",
  }
end

local function mac_of(device)
  local dni = tostring(device.device_network_id)
  local mac = dni:sub(#discovery.DNI_PREFIX + 1)
  if mac:match("^%x+$") and #mac == 12 then
    return mac
  end
  return device:get_field(MAC_FIELD)
end

--- The mDNS name a device was added under (network id climacontrol-host-<name>,
--- or ...-<name>-<a-b-c-d> when another module already had that name).
local function host_of(device)
  local dni = tostring(device.device_network_id)
  local prefix = discovery.HOST_PREFIX
  if dni:sub(1, #prefix) ~= prefix then
    return nil
  end
  local host = dni:sub(#prefix + 1)
  return (host:gsub("%-%d+%-%d+%-%d+%-%d+$", ""))
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
  local host = not mac and host_of(device)
  if (force or not ip) and (mac or host) then
    device:set_field(LAST_SCAN_FIELD, os.time())
    local match, count = nil, 0
    for _, m in ipairs(discovery.find_modules({ s.password })) do
      if mac and m.mac == mac then
        match, count = m, 1
        break
      elseif host and m.host == host then
        match, count = match or m, count + 1
      end
    end
    -- By name only when exactly one module has it (several can be "heatpump").
    if match and count == 1 then
      if match.ip ~= ip then
        log.info(device.label .. ": module found at " .. match.ip)
      end
      ip = match.ip
      device:set_field(IP_FIELD, ip, { persist = true })
    elseif count > 1 then
      log.warn(device.label .. ": " .. count .. " modules are named " .. host
        .. "; give each a different name on its web page, or set the IP Address")
    end
  end
  return ip
end

-- ===== Events =====

--- Emit only when the value changed since the last emit (polling every few
--- seconds would otherwise fill the device history).
--- True (and remembered) when event's value differs from the last one cached
--- under id in the device's field.
local function changed(device, field, id, event)
  local cache = device:get_field(field) or {}
  local value = event.value
  if type(value) == "table" then
    value = tostring(value.value) .. (value.unit or "")
  end
  local text = tostring(value)
  if cache[id] == text then
    return false
  end
  cache[id] = text
  device:set_field(field, cache)
  return true
end

local function emit(device, component_id, key, event)
  local component = component_id ~= "main" and device.profile.components[component_id]
  if component_id ~= "main" and not component then
    -- Not in this profile (yet): don't cache, so it's sent once it is.
    return
  end
  if not changed(device, EMIT_CACHE_FIELD, component_id .. "/" .. key, event) then
    return
  end
  if component_id == "main" then
    device:emit_event(event)
  else
    device:emit_component_event(component, event)
  end
end

-- Extras that can be hidden, in profile-name order, with their name letters
-- (tools/make_profiles.py generates a profile for every combination).
local EXTRAS = { "eco", "econavi", "nanoex", "milddry", "widevane" }
local EXTRA_CODE = { eco = "e", econavi = "v", nanoex = "n", milddry = "d", widevane = "w" }

local wanted_hidden

--- A hidden set as a code ("" = nothing hidden), for naming and comparing.
local function hidden_code(hidden)
  local code = ""
  for _, k in ipairs(EXTRAS) do
    if hidden[k] then
      code = code .. EXTRA_CODE[k]
    end
  end
  return code
end

--- The profile for this device: with or without the thermometer and window
--- components, without the extras its settings say (or the unit showed) it lacks.
local function wanted_profile(device, thermometer, window)
  local code = hidden_code(wanted_hidden(device))
  local named
  for _, name in ipairs(SET_ORDER) do
    if hidden_code(HIDES[name]) == code then
      named = name
    end
  end
  if named == "all" and not window then
    return thermometer and THERMO_PROFILE or PROFILE
  end
  local suffix = named and (named == "all" and "" or ("-" .. named)) or ("-x" .. code)
  return "climacontrol-panasonic" .. (thermometer and "-thermometer" or "") .. (window and "-window" or "")
      .. suffix .. ".v1"
end

--- The extras the device's current profile leaves out (from its components).
local function profile_hidden(device)
  local c, hidden = device.profile.components, {}
  for _, k in ipairs(EXTRAS) do
    if k == "widevane" then
      hidden[k] = not device:supports_capability_by_id(WIDEVANE_CAP.ID) or nil
    else
      hidden[k] = c[k] == nil or nil
    end
  end
  return hidden
end

--- Ask for a profile once (the change arrives as infoChanged).
local function request_profile(device, profile)
  if device:get_field(PROFILE_REQUEST_FIELD) == profile then
    return
  end
  device:set_field(PROFILE_REQUEST_FIELD, profile)
  log.info(tostring(device.label) .. ": switching to profile " .. profile)
  device:try_update_metadata({ profile = profile })
end

-- ===== Learning what the unit doesn't support =====

local function rejected(device, key)
  return ((device:get_field(LEARNED_FIELD) or {})[key] or 0) >= LEARN_AFTER
end

--- The extras to hide: what the "Unit features" setting leaves out, plus
--- what the unit itself rejected.
wanted_hidden = function(device)
  local hidden = {}
  for k in pairs(SETTING_HIDES[get_settings(device).features]) do
    hidden[k] = true
  end
  for _, k in ipairs(EXTRAS) do
    if rejected(device, k) then
      hidden[k] = true
    end
  end
  return hidden
end

--- Remember a command whose result is judged over the next minute.
--- Only while the unit is on in Cool or Heat and no window is open (the window
--- function overrides settings), and never for "off".
local function expect(device, key, value, before)
  local last = device:get_field(LAST_FIELD) or {}
  local pending = device:get_field(PENDING_FIELD) or {}
  pending[key] = nil
  local window_open = false
  for _, w in ipairs(last.windows or {}) do
    window_open = window_open or w.open
  end
  -- Extras are only judged in Cool or Heat: a unit may refuse e.g. Eco in Auto,
  -- Dry or Fan mode although it has it, which would hide a working switch.
  local mode_ok = key == "heat" or last.mode == "cool" or last.mode == "heat"
  if before ~= nil and before ~= value and not window_open and mode_ok then
    -- The other settings at the time: if one changes (another command, the
    -- remote, the module's page), a put-back may be that change's doing
    -- (e.g. Powerful cancelling Eco), so the check is dropped.
    pending[key] = { value = value, before = before, at = os.time(),
      preset = last.preset, mode = last.mode, fan = last.fan }
  end
  device:set_field(PENDING_FIELD, pending)
end

--- The status value a pending check compares.
local function current_value(parsed, key)
  if key == "widevane" then
    return parsed.widevane
  elseif key == "heat" then
    return parsed.mode
  end
  return (parsed.features or {})[key]
end

--- Judge pending commands against a fresh status. Put back to the old value:
--- a rejection (hidden after LEARN_AFTER). Still set after JUDGE_SECONDS: accepted.
--- Returns true when the set of hidden things changed.
local function judge(device, parsed)
  local pending = device:get_field(PENDING_FIELD)
  if not pending or next(pending) == nil then
    return false
  end
  local window_open = false
  for _, w in ipairs(parsed.windows or {}) do
    window_open = window_open or w.open
  end
  local learned = device:get_field(LEARNED_FIELD) or {}
  local changed_any = false
  for key, p in pairs(pending) do
    local now = current_value(parsed, key)
    local age = os.time() - p.at
    local others_changed = parsed.preset ~= p.preset or parsed.fan ~= p.fan
        or (key ~= "heat" and parsed.mode ~= p.mode)
    if window_open or parsed.power ~= "on" or others_changed then
      pending[key] = nil
    elseif now == p.before and age < 4 then
      -- Too soon: the module may not have passed the command on yet.
    elseif now == p.before and age <= JUDGE_SECONDS then
      pending[key] = nil
      local before_hidden = rejected(device, key)
      learned[key] = (learned[key] or 0) + 1
      log.info(device.label .. ": unit put " .. key .. " back to " .. tostring(now) .. " (" .. learned[key] .. "x)")
      device:set_field(LEARNED_FIELD, learned, { persist = true })
      if not before_hidden and rejected(device, key) then
        log.info(device.label .. ": " .. key .. " isn't supported by this unit; hiding it")
        changed_any = true
      end
    elseif age >= JUDGE_SECONDS then
      pending[key] = nil
      if now == p.value and learned[key] then
        learned[key] = nil
        device:set_field(LEARNED_FIELD, learned, { persist = true })
      end
    elseif now ~= p.value then
      pending[key] = nil   -- changed some other way
    end
  end
  device:set_field(PENDING_FIELD, pending)
  return changed_any
end

-- ===== Window/door sensor child devices =====

--- A window sensor's device: network id <module's>-window-<sensor MAC>.
--- The parent's network id and the sensor's MAC from a window device's id
--- (it ends in -window- and exactly 12 hex digits, which no module name does).
local function window_parts(device)
  return tostring(device.device_network_id):match("^(.+)%-window%-(%x%x%x%x%x%x%x%x%x%x%x%x)$")
end

local function is_window_child(device)
  return window_parts(device) ~= nil
end

local function window_parent(driver, child)
  local parent_dni = window_parts(child)
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == parent_dni then
      return d
    end
  end
end

local function child_emit(child, key, event)
  if changed(child, CHILD_CACHE_FIELD, key, event) then
    child:emit_event(event)
  end
  -- Online again after the module was unreachable (or the hub marked it offline).
  if child:get_field("online") ~= true then
    child:online()
    child:set_field("online", true)
  end
end

--- Mark a module's window/door devices offline with it.
local function child_offline(child)
  if child:get_field("online") ~= false then
    child:offline()
    child:set_field("online", false)
  end
end

--- This module's window/door devices, by sensor MAC.
local function window_children(driver, device)
  local found = {}
  for _, d in ipairs(driver:get_devices()) do
    local parent_dni, mac = window_parts(d)
    if parent_dni == device.device_network_id then
      found[mac] = d
    end
  end
  return found
end

local function window_children_offline(driver, device)
  for _, child in pairs(window_children(driver, device)) do
    child_offline(child)
  end
end

--- Create (once, retried after a few minutes) and update each sensor's device.
local function update_window_children(driver, device, windows)
  local children = window_children(driver, device)
  local ignored = device:get_field(IGNORED_WINDOWS_FIELD) or {}
  local missing = device:get_field(WINDOW_MISSING_FIELD) or {}
  local present = {}
  for i, w in ipairs(windows) do
    if w.mac then
      present[w.mac] = true
      missing[w.mac] = nil
      local dni = device.device_network_id .. WINDOW_KEY .. w.mac
      local child = children[w.mac]
      if not child and ignored[w.mac] then
        -- Deleted by the user: left out until the next "Scan nearby".
      elseif not child then
        local field = "requested_" .. dni
        local last = device:get_field(field)
        if not last or os.time() - last >= CHILD_RETRY_SECONDS then
          device:set_field(field, os.time())
          local label = tostring(device.label) .. " Window/Door " .. i
          log.info(tostring(device.label) .. ": adding window/door sensor " .. tostring(w.name) .. " as " .. label)
          driver:try_create_device({
            type = "LAN",
            device_network_id = dni,
            label = label,
            profile = WINDOW_PROFILE,
            manufacturer = "ProtoART",
            model = "Window/Door sensor",
            vendor_provided_label = "Window/Door sensor",
            parent_device_id = device.id,
          })
        end
      else
        child_emit(child, "contact", capabilities.contactSensor.contact(w.open and "open" or "closed"))
        if w.battery then
          child_emit(child, "battery", capabilities.battery.battery({ value = w.battery, unit = "%" }))
        end
      end
    end
  end
  -- A sensor no longer paired to the module (or out of range): its device goes
  -- offline after a few polls instead of keeping its last state. It stays, so
  -- routines using it survive re-pairing; delete it in the app if unwanted.
  for mac, child in pairs(children) do
    if not present[mac] then
      missing[mac] = (missing[mac] or 0) + 1
      if missing[mac] >= THERMO_REMOVE_AFTER_POLLS then
        child_offline(child)
      end
    end
  end
  device:set_field(WINDOW_MISSING_FIELD, missing)
end

--- Paired sensors get their own components: the wireless thermometer
--- (temperature, humidity, battery) whenever one is paired, whether or not the
--- module uses it as its temperature input; the window sensors as one
--- "Windows" component (open if any is open; the lowest battery). A component
--- is removed only after its sensor has been missing for a few polls, so a
--- flat battery still shows.
local function update_sensors(device, parsed)
  local comps = device.profile.components
  local has_t, has_w = comps.thermometer ~= nil, comps.window ~= nil
  local function want(present, has, field)
    if present then
      device:set_field(field, 0)
      return true
    end
    if not has then
      return false
    end
    local absent = (device:get_field(field) or 0) + 1
    device:set_field(field, absent)
    return absent < THERMO_REMOVE_AFTER_POLLS
  end
  local want_t = want(parsed.thermometer, has_t, THERMO_ABSENT_FIELD)
  local want_w = want(#(parsed.windows or {}) > 0, has_w, WINDOW_ABSENT_FIELD)
  -- What the sensors call for; poll_once asks for the profile once, together
  -- with anything learned in the same poll.
  device:set_field("want_sensors", { want_t, want_w })
  if want_t ~= has_t or want_w ~= has_w then
    device:set_field("profile_due", true)
  end
  if has_t and parsed.thermometer then
    if parsed.thermo_temp then
      emit(device, "thermometer", "temp",
        capabilities.temperatureMeasurement.temperature({ value = parsed.thermo_temp, unit = "C" }))
    end
    if parsed.thermo_humidity then
      emit(device, "thermometer", "humidity",
        capabilities.relativeHumidityMeasurement.humidity({ value = parsed.thermo_humidity, unit = "%" }))
    end
    if parsed.thermo_battery then
      emit(device, "thermometer", "battery", SENSOR_BATTERY_CAP.sensorBattery(Status.battery_text(parsed.thermo_battery)))
    end
  end
  if has_w and #(parsed.windows or {}) > 0 then
    local open, battery = false, nil
    for _, w in ipairs(parsed.windows) do
      open = open or w.open
      if w.battery and (not battery or w.battery < battery) then
        battery = w.battery
      end
    end
    emit(device, "window", "contact", capabilities.contactSensor.contact(open and "open" or "closed"))
    if battery then
      emit(device, "window", "battery", SENSOR_BATTERY_CAP.sensorBattery(Status.battery_text(battery)))
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
  if parsed.widevane and device:supports_capability_by_id(WIDEVANE_CAP.ID) then
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
    { "guard", GUARD_CAP.roomGuard, Status.guard_text(parsed) },
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
  update_sensors(device, parsed)
end

-- ===== Polling =====

local schedule_poll
local emit_supported

local function poll_once(driver, device)
  local failures = device:get_field(FAILURES_FIELD) or 0
  local last_scan = device:get_field(LAST_SCAN_FIELD) or 0
  -- An auth failure may be another module now at the old address, so the
  -- rescan (by MAC, at most every RESCAN_SECONDS) still runs.
  local rescan = failures >= REDISCOVER_AFTER_FAILURES and os.time() - last_scan >= RESCAN_SECONDS
  local ip = resolve_ip(driver, device, rescan)
  if not ip then
    log.warn(device.label .. ": module not found; set its IP Address in Settings or check it's on the network")
    return false
  end
  local data, err, kind = Api.status(ip, get_settings(device).password)
  device:set_field(AUTH_FIELD, kind == "auth" or nil)
  if not data then
    log.warn(device.label .. ": status from " .. ip .. " failed: " .. tostring(err))
    -- Someone is logged in on the module's page: not the module's fault.
    return kind == "busy" and "busy" or false
  end
  if not device:get_field(LAYOUT_LOGGED_FIELD) then
    device:set_field(LAYOUT_LOGGED_FIELD, true)
    log.info(device.label .. ": status JSON layout " .. Status.describe(data))
  end
  local parsed = Status.parse(data)
  local mac = Status.mac_key(parsed.mac)
  local own = mac_of(device)
  if mac and own and mac ~= own then
    -- Another module now has this address (e.g. after a power cut): look for
    -- this device's own module instead of taking over the other one.
    log.warn(device.label .. ": " .. ip .. " is now another module (" .. mac .. "); looking for its own")
    device:set_field(IP_FIELD, nil, { persist = true })
    if driver.found_ips then
      driver.found_ips[device.device_network_id] = nil
    end
    device:set_field(LAST_SCAN_FIELD, 0)
    return false
  end
  if mac and not own then
    device:set_field(MAC_FIELD, mac, { persist = true })
  end
  if Status.unit_disconnected(parsed) then
    log.warn(device.label .. ": module is up but not connected to the air conditioner (check the CN-CNT cable)")
  end
  device:set_field(LAST_FIELD, parsed)
  apply_status(device, parsed)
  if judge(device, parsed) then
    emit_supported(device)
    device:set_field("profile_due", true)
  end
  if device:get_field("profile_due") then
    device:set_field("profile_due", nil)
    local comps, want = device.profile.components, device:get_field("want_sensors")
    local t, w = comps.thermometer ~= nil, comps.window ~= nil
    if want then
      t, w = want[1], want[2]
    end
    request_profile(device, wanted_profile(device, t, w))
  end
  update_window_children(driver, device, parsed.windows or {})
  return true
end

local retry_guard   -- send_guard, defined with the settings below

local function poll(driver, device)
  local ok, result = pcall(poll_once, driver, device)
  if ok and result == true and retry_guard then
    pcall(retry_guard, driver, device)
  end
  if not ok then
    log.error(device.label .. ": poll error: " .. tostring(result))
  end
  if ok and result then
    -- Its own field: Settings changes reset the failure count. nil (just after
    -- a driver restart) also calls online().
    if device:get_field(OFFLINE_FIELD) ~= false then
      device:online()
      device:set_field(OFFLINE_FIELD, false)
    end
    device:set_field(FAILURES_FIELD, 0)
  else
    local failures = (device:get_field(FAILURES_FIELD) or 0) + 1
    device:set_field(FAILURES_FIELD, failures)
    if failures >= OFFLINE_AFTER_FAILURES and device:get_field(OFFLINE_FIELD) ~= true then
      device:offline()
      device:set_field(OFFLINE_FIELD, true)
      window_children_offline(driver, device)
    end
  end
  local fast = device:get_field(FAST_POLLS_FIELD) or 0
  local interval = get_settings(device).poll_interval
  if fast > 0 then
    device:set_field(FAST_POLLS_FIELD, fast - 1)
    interval = math.min(interval, FAST_POLL_SECONDS)
  end
  schedule_poll(driver, device, interval)
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
--- check = { key, value, before } (optional): judge over the next minute
--- whether the unit keeps it. Any command cancels earlier pending checks.
local function send(driver, device, commands, check)
  device:set_field(PENDING_FIELD, nil)
  local ip = resolve_ip(driver, device, false)
  if not ip then
    log.warn(device.label .. ": command ignored, module address unknown")
    return false
  end
  for _, c in ipairs(commands) do
    local ok, err = Api.command(ip, c[1], c[2], get_settings(device).password)
    if not ok then
      log.warn(device.label .. ": " .. c[1] .. "=" .. tostring(c[2]) .. " failed: " .. tostring(err))
      schedule_poll(driver, device, COMMAND_REPOLL_SECONDS)
      return false
    end
  end
  if check then
    expect(device, check[1], check[2], check[3])
  end
  device:set_field(FAST_POLLS_FIELD, FAST_POLLS)
  schedule_poll(driver, device, COMMAND_REPOLL_SECONDS)
  return true
end

--- The main switch is power; the eco/econavi/nanoex/milddry components'
--- switches are those features, sent under the component's name.
local function set_switch(driver, device, command, state)
  local component = command.component or "main"
  local key = component == "main" and "power" or component
  local check
  if key ~= "power" then
    local last = device:get_field(LAST_FIELD) or {}
    check = { key, state, state == "on" and last.power == "on" and (last.features or {})[key] or nil }
  end
  if send(driver, device, { { key, state } }, check) then
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
  local last = device:get_field(LAST_FIELD) or {}
  if send(driver, device, { { "widevane", value } }, { "widevane", value, last.power == "on" and last.widevane or nil }) then
    emit(device, "main", "widevane", WIDEVANE_CAP.vane(value))
  end
end

local function set_mode(driver, device, command)
  local mode = command.args.mode
  if mode == "heat" and (get_settings(device).cooling_only or rejected(device, "heat")) then
    log.warn(device.label .. ": Heat ignored, the unit is set as cooling only")
    return
  end
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
  local check = mode == "heat" and { "heat", "heat", (last.power == "on" or turn_on) and last.mode or nil } or nil
  if send(driver, device, commands, check) then
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
  local ok, err = Api.restart(ip, get_settings(device).password)
  if ok then
    log.info(device.label .. ": module restarting")
  else
    log.warn(device.label .. ": restart failed: " .. tostring(err))
  end
  -- It's back in a few seconds; read the status once it should be.
  schedule_poll(driver, device, 20)
end

local function refresh(driver, device)
  if is_window_child(device) then
    device:set_field(CHILD_CACHE_FIELD, {})
    local parent = window_parent(driver, device)
    if parent then
      parent:set_field(EMIT_CACHE_FIELD, {})
      schedule_poll(driver, parent, 0)
    end
    return
  end
  device:set_field(EMIT_CACHE_FIELD, {})
  schedule_poll(driver, device, 0)
end

-- ===== Lifecycle =====

local function supported_modes(device)
  if not get_settings(device).cooling_only and not rejected(device, "heat") then
    return Status.SUPPORTED_MODES
  end
  local modes = {}
  for _, m in ipairs(Status.SUPPORTED_MODES) do
    if m ~= "heat" then
      table.insert(modes, m)
    end
  end
  return modes
end

emit_supported = function(device)
  device:emit_event(capabilities.airConditionerMode.supportedAcModes(supported_modes(device)))
  device:emit_event(capabilities.airConditionerFanMode.supportedAcFanModes(Status.SUPPORTED_FAN_MODES))
  emit_setpoint_range(device)
end

--- A password that unlocked this module during the scan that added it.
local function adopt_found_password(driver, device)
  local pw = driver.found_passwords and driver.found_passwords[device.device_network_id]
  if pw and not device:get_field(discovery.PASSWORD_FIELD) then
    device:set_field(discovery.PASSWORD_FIELD, pw, { persist = true })
  end
end

local function device_init(driver, device)
  if is_window_child(device) then
    device:set_field(CHILD_CACHE_FIELD, {})   -- the parent's next poll fills it
    return
  end
  adopt_found_password(driver, device)
  -- A device created with an older profile gets the current one.
  if not device:supports_capability_by_id(RESTART_CAP.ID) then
    log.info(tostring(device.label) .. ": switching to profile " .. PROFILE)
    device:try_update_metadata({ profile = PROFILE })
  end
  device:set_field(PROFILE_REQUEST_FIELD, nil)
  -- Hide what the unit rejected before (or show what's no longer hidden).
  if device:supports_capability_by_id(RESTART_CAP.ID)
      and hidden_code(profile_hidden(device)) ~= hidden_code(wanted_hidden(device)) then
    request_profile(device, wanted_profile(device, device.profile.components.thermometer ~= nil,
      device.profile.components.window ~= nil))
  end
  emit_supported(device)
  device:set_field(EMIT_CACHE_FIELD, {})
  device:set_field(LAYOUT_LOGGED_FIELD, nil)
  schedule_poll(driver, device, 1)
end

local function device_added(driver, device)
  if is_window_child(device) then
    return
  end
  adopt_found_password(driver, device)
  emit_supported(device)
end

--- Room guard values waiting to reach the module (persisted, retried on
--- every poll until the module accepts them).
local GUARD_PENDING_FIELD = "guard_pending"

local function send_guard(driver, device)
  local values = device:get_field(GUARD_PENDING_FIELD)
  if type(values) ~= "table" or #values == 0 then
    return
  end
  local ip = resolve_ip(driver, device, false)
  if not ip then
    return
  end
  local ok, err = Api.settings(ip, values, get_settings(device).password)
  if ok then
    local text = {}
    for _, kv in ipairs(values) do
      table.insert(text, kv[1] .. "=" .. kv[2])
    end
    log.info(device.label .. ": room guard set (" .. table.concat(text, ", ") .. ")")
    device:set_field(GUARD_PENDING_FIELD, nil, { persist = true })
  else
    log.warn(device.label .. ": room guard not sent yet (" .. tostring(err) .. "); will retry")
  end
end

--- Room guard settings changed in SmartThings. Only a setting that was there
--- before and changed counts (so new settings arriving with an update never
--- overwrite the module's own guard); changing either limit sends both, as
--- shown in Settings.
local function apply_guard_settings(driver, device, old)
  if type(old) ~= "table" then
    return
  end
  local p = device.preferences or {}
  local function changed_key(k)
    return old[k] ~= nil and p[k] ~= nil and p[k] ~= old[k]
  end
  local values = {}
  if changed_key("roomGuard") and (p.roomGuard == "on" or p.roomGuard == "off") then
    table.insert(values, { "t_protena", p.roomGuard == "on" and "true" or "false" })
  end
  if changed_key("roomGuardLow") or changed_key("roomGuardHigh") then
    -- A value outside the module's 5-40 °C becomes the nearest limit.
    local function clamp(v, lo, hi)
      return math.max(lo, math.min(hi, math.floor(v + 0.5)))
    end
    local lo, hi = tonumber(p.roomGuardLow), tonumber(p.roomGuardHigh)
    if lo and hi then
      lo, hi = clamp(lo, GUARD_MIN, GUARD_MAX), clamp(hi, GUARD_MIN, GUARD_MAX)
      if lo < hi then
        table.insert(values, { "t_protmin", tostring(lo) })
        table.insert(values, { "t_protmax", tostring(hi) })
      else
        log.warn(device.label .. ": room guard lowest (" .. lo .. ") must be below highest (" .. hi .. "); limits not sent")
      end
    end
  end
  if #values == 0 then
    return
  end
  device:set_field(GUARD_PENDING_FIELD, values, { persist = true })
  send_guard(driver, device)
end

retry_guard = send_guard

local function info_changed(driver, device, event, args)
  if is_window_child(device) then
    return
  end
  -- A profile change arrives here too: send every value again so the new
  -- components fill at once.
  device:set_field(PROFILE_REQUEST_FIELD, nil)
  device:set_field(EMIT_CACHE_FIELD, {})
  device:set_field(FAILURES_FIELD, 0)
  emit_supported(device)
  -- "Unit features" changed: forget what the unit rejected (that's how a
  -- wrongly hidden switch comes back), then switch to the matching profile.
  local old_prefs = args and args.old_st_store and args.old_st_store.preferences
  if old_prefs and old_prefs.unitFeatures ~= (device.preferences or {}).unitFeatures then
    device:set_field(LEARNED_FIELD, nil, { persist = true })
    device:set_field(PENDING_FIELD, nil)
    emit_supported(device)
  end
  if hidden_code(profile_hidden(device)) ~= hidden_code(wanted_hidden(device)) then
    request_profile(device, wanted_profile(device, device.profile.components.thermometer ~= nil,
      device.profile.components.window ~= nil))
  end
  if args and args.old_st_store and args.old_st_store.preferences
      and args.old_st_store.preferences.modulePassword ~= (device.preferences or {}).modulePassword then
    -- Log in again with the new one (at the address resolve_ip uses first).
    local ip = get_settings(device).ip or device:get_field(IP_FIELD)
    if ip then
      Api.forget(ip)
    end
  end
  apply_guard_settings(driver, device, args and args.old_st_store and args.old_st_store.preferences)
  schedule_poll(driver, device, 1)
end

local function device_removed(driver, device)
  if is_window_child(device) then
    -- Deleted in the app: don't add it again on the next poll.
    local parent, mac = window_parent(driver, device), select(2, window_parts(device))
    if parent then
      local ignored = parent:get_field(IGNORED_WINDOWS_FIELD) or {}
      ignored[mac] = true
      parent:set_field(IGNORED_WINDOWS_FIELD, ignored, { persist = true })
      log.info(tostring(parent.label) .. ": window/door sensor " .. mac .. " deleted; Scan nearby adds it again")
    end
    return
  end
  local timer = device:get_field(POLL_TIMER_FIELD)
  if timer then
    device.thread:cancel_timer(timer)
  end
end

-- "Scan nearby" brings deleted window/door sensor devices back.
discovery.on_scan = function(driver)
  for _, d in ipairs(driver:get_devices()) do
    if not is_window_child(d) and d:get_field(IGNORED_WINDOWS_FIELD) then
      d:set_field(IGNORED_WINDOWS_FIELD, nil, { persist = true })
    end
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
