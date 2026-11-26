local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local SolarEdge = require "solaredge"

local POLL_TIMER_FIELD = "poll_timer"
local POLL_IN_PROGRESS_FIELD = "poll_in_progress"
local HAS_BATTERY_FIELD = "has_battery"
local THREE_PHASE_FIELD = "three_phase"
local BATTERY_SEEN_FIELD = "battery_seen_polls"
local BATTERY_CONFIRM_POLLS = 3
local PHASES_SEEN_FIELD = "phases_seen_polls"
local PHASES_CONFIRM_POLLS = 3
local APPLIED_PROFILE_FIELD = "applied_profile"
local FAILURES_FIELD = "consecutive_poll_failures"
local OFFLINE_FIELD = "marked_offline"
local OFFLINE_AFTER_FAILURES = 3
-- The battery section / three-phase rows are removed only after this long
-- with clean "not there" reads in a row. A failed read never counts, and a
-- battery that sleeps overnight isn't removed (it was 60 polls, i.e. 10 min
-- at a 10 s poll interval).
local GONE_AFTER_SECONDS = 24 * 3600
local BATTERY_ABSENT_SINCE_FIELD = "battery_absent_since"
local PHASES_ABSENT_SINCE_FIELD = "phases_absent_since"
-- The profiles' default IP: still set means the real one was never entered.
local PLACEHOLDER_IP = "192.168.1.100"
-- Profile per detected hardware. Non-battery single-phase installs stay
-- on CURRENT_PROFILE. Three-phase needs 3 polls in a row, is persisted and
-- only ever switches ON.
-- The battery needs 3 polls in a row to switch on and 60 polls in a row
-- without one to switch off again, so it can't oscillate.
local CURRENT_PROFILE = "solaredge-inverter.v8"
local BATTERY_PROFILE = "solaredge-inverter-battery.v4"
local THREE_PHASE_PROFILE = "solaredge-inverter-3ph.v4"
local BATTERY_THREE_PHASE_PROFILE = "solaredge-inverter-battery-3ph.v4"
-- One row per phase (L1..L3): power, voltage and current.
local PHASE_CAPS = {
  capabilities["aboutisland47519.gridPhaseOne"],
  capabilities["aboutisland47519.gridPhaseTwo"],
  capabilities["aboutisland47519.gridPhaseThree"],
}

local function round(x, places)
  local m = 10 ^ (places or 0)
  local v = math.floor(x * m + 0.5) / m
  if (places or 0) == 0 then return math.tointeger(v) or v end
  return v
end

--- "%.1f"-style text for a value that may be nil (not implemented).
local function fmt(pattern, v)
  return v and string.format(pattern, v) or "n/a"
end

local function target_profile(device)
  local batt = device:get_field(HAS_BATTERY_FIELD)
  local three = device:get_field(THREE_PHASE_FIELD)
  if batt and three then return BATTERY_THREE_PHASE_PROFILE end
  if batt then return BATTERY_PROFILE end
  if three then return THREE_PHASE_PROFILE end
  return CURRENT_PROFILE
end
local STATUS_CAP = capabilities["aboutisland47519.inverterStatus"]
local GRID_ENERGY_CAP = capabilities["aboutisland47519.gridEnergy"]
local DC_INPUT_CAP = capabilities["aboutisland47519.dcInput"]
local BATTERY_STATUS_CAP = capabilities["aboutisland47519.batteryStatus"]
local BATTERY_STORAGE_CAP = capabilities["aboutisland47519.batteryStorage"]

--- Switches the device to the profile its flags call for, remembering it.
local function apply_profile(device, target)
  device:try_update_metadata({ profile = target })
  device:set_field(APPLIED_PROFILE_FIELD, target, { persist = true })
end

--- Whether the device's actual profile has the sections its flags call for
--- (a profile switch can fail silently, and then needs repeating).
local function profile_matches(device)
  local comps = device.profile and device.profile.components or {}
  local has_battery = comps.battery ~= nil
  local has_phases = comps.grid ~= nil and device:supports_capability(PHASE_CAPS[2], "grid")
  return has_battery == (device:get_field(HAS_BATTERY_FIELD) == true)
    and has_phases == (device:get_field(THREE_PHASE_FIELD) == true)
end

--- A lifetime total for display: nil if missing, zero (SunSpec "not
--- accumulated") or lower than the last one shown (a garbled read).
local function steady_total(device, field, value)
  if not value or value <= 0 then
    return nil
  end
  local last = device:get_field(field)
  if last and value < last then
    log.warn(string.format("SolarEdge: %s went backwards (%.0f after %.0f), not shown", field, value, last))
    return nil
  end
  device:set_field(field, value)
  return value
end

local function get_settings(device)
  local prefs = device.preferences or {}
  return {
    ip = prefs.ipAddress,
    port = tonumber(prefs.modbusPort) or 1502,
    unit_id = tonumber(prefs.unitId) or 1,
    poll_interval = tonumber(prefs.pollInterval) or 30,
  }
end

--- Wrapped in pcall: an uncaught Lua error here must not propagate past this
--- function. Also guarded by POLL_IN_PROGRESS_FIELD: pcall only protects
--- against this throwing, not against it taking a long time to return
--- (an unreachable/slow inverter can stall well past a minute --
--- SunSpec.find_model alone allows up to 20 round-trips at a 5s socket
--- timeout each, for both the inverter and the meter lookups), and
--- start_polling now registers the recurring timer BEFORE the immediate
--- first call below rather than after, specifically so a slow first
--- call no longer delays the timer's own existence. Without this guard,
--- that reordering could let a still-running slow poll overlap with the
--- next scheduled one for the same device -- a real problem here since
--- the inverter's own Modbus stack only accepts one TCP connection at a
--- time (confirmed via the vendor's technical note, see solaredge.lua).
local function record_poll_failure(device)
  local failures = (device:get_field(FAILURES_FIELD) or 0) + 1
  device:set_field(FAILURES_FIELD, failures)
  if failures >= OFFLINE_AFTER_FAILURES and device:get_field(OFFLINE_FIELD) ~= true then
    device:offline()
    device:set_field(OFFLINE_FIELD, true)
    log.warn("SolarEdge device offline after " .. failures .. " failed polls")
  end
end

-- nil (just after a driver restart) also calls online(), since the platform
-- may still have the device offline from before the restart.
local function record_poll_success(device)
  device:set_field(FAILURES_FIELD, 0)
  if device:get_field(OFFLINE_FIELD) ~= false then
    device:online()
    device:set_field(OFFLINE_FIELD, false)
  end
end

local function poll_once(driver, device)
  if device:get_field(POLL_IN_PROGRESS_FIELD) then
    log.info("SolarEdge poll already in progress for this device, skipping overlapping call")
    return
  end
  device:set_field(POLL_IN_PROGRESS_FIELD, true)
  local ok, err = pcall(function()
    local settings = get_settings(device)
    if not settings.ip or settings.ip == "" then
      log.warn("SolarEdge device has no IP address configured yet — skipping poll")
      return
    end

    local reading, read_err = SolarEdge.read(settings.ip, settings.port, settings.unit_id, 5)
    if not reading then
      log.error(string.format("SolarEdge poll failed (%s:%d unit %d): %s",
        settings.ip, settings.port, settings.unit_id, tostring(read_err)))
      if settings.ip == PLACEHOLDER_IP then
        log.warn("SolarEdge: the IP Address setting is still the example " .. PLACEHOLDER_IP
          .. "; enter your inverter's IP address in the device's Settings")
      end
      record_poll_failure(device)
      return
    end
    record_poll_success(device)

    local temp_display = reading.temp_c and string.format("%.1fC", reading.temp_c) or "n/a"
    log.info(string.format("SolarEdge reading: %sW, %sWh lifetime, %sV DC, %sW DC, %s, status=%s",
      fmt("%.1f", reading.power_w), fmt("%.1f", reading.energy_wh), fmt("%.1f", reading.dc_voltage),
      fmt("%.1f", reading.dc_power_w), temp_display, reading.status_name))

    if reading.power_w then
      device:emit_event(capabilities.powerMeter.power({ value = reading.power_w, unit = "W" }))
    end
    local energy_wh = steady_total(device, "last_energy_wh", reading.energy_wh)
    if energy_wh then
      device:emit_event(capabilities.energyMeter.energy({ value = energy_wh / 1000.0, unit = "kWh" }))
    end
    device:emit_event(STATUS_CAP.status({ value = reading.status_name }))

    -- Defensive bound matching the platform's own TemperatureValue constraint
    -- (min -460, max 10000). A bad register offset produced 53060000.0 here
    -- once already, which the platform rejected and crashed the event thread
    -- over — better to skip a single bad reading and log it than repeat that.
    if reading.temp_c and reading.temp_c >= -460 and reading.temp_c <= 10000 then
      device:emit_event(capabilities.temperatureMeasurement.temperature({ value = reading.temp_c, unit = "C" }))
    elseif reading.temp_c then
      log.warn(string.format("SolarEdge temperature reading out of sane bounds (%.1fC) — skipping emit, likely a register offset problem", reading.temp_c))
    end
    -- reading.temp_c == nil means all four temperature slots are unpopulated
    -- on this device (already logged in solaredge.lua) — nothing to emit.

    -- DC voltage/power come off the same inverter model registers as
    -- power_w/energy_wh above, so they're always present whenever a
    -- reading succeeds at all -- no optional-hardware guard needed here,
    -- unlike the grid meter below.
    local dc = device.profile.components.dc
    if dc then
      -- One "DC Input" row (Voltage, Current) under the power tile.
      if reading.dc_voltage then
        device:emit_component_event(dc, DC_INPUT_CAP.voltage({ value = round(reading.dc_voltage, 1), unit = "V" }))
      end
      if reading.dc_current_a then
        device:emit_component_event(dc, DC_INPUT_CAP.current({ value = round(reading.dc_current_a, 1), unit = "A" }))
      end
      if reading.dc_power_w then
        device:emit_component_event(dc, capabilities.powerMeter.power({ value = reading.dc_power_w, unit = "W" }))
      end
    end

    -- Grid meter is optional hardware — nil means this installation doesn't
    -- have one wired up (or it wasn't readable this cycle), not an error.
    local grid = device.profile.components.grid
    if grid and reading.grid_power_w then
      log.info(string.format("SolarEdge grid meter (%s): %.1fW net (%s), %.1fkWh exported, %.1fkWh imported",
        tostring(reading.meter_role or "role not reported"),
        reading.grid_power_w, reading.grid_power_w >= 0 and "exporting" or "importing",
        reading.grid_exported_wh / 1000.0, reading.grid_imported_wh / 1000.0))
      device:emit_component_event(grid, capabilities.powerMeter.power({ value = reading.grid_power_w, unit = "W" }))
      -- Whole kWh: lifetime totals in the thousands wrap their tile otherwise.
      local exported = steady_total(device, "last_exported_wh", reading.grid_exported_wh)
      local imported = steady_total(device, "last_imported_wh", reading.grid_imported_wh)
      if exported then
        device:emit_component_event(grid, GRID_ENERGY_CAP.exported({ value = round(exported / 1000.0), unit = "kWh" }))
      end
      if imported then
        device:emit_component_event(grid, GRID_ENERGY_CAP.imported({ value = round(imported / 1000.0), unit = "kWh" }))
      end
    end

    -- Per-phase grid power/voltage: only when the meter shows real voltage
    -- on phases B and C (solaredge.lua decides). First detection switches
    -- the profile once, same pattern as the battery below.
    local ph = reading.grid_phases
    local one = reading.grid_phase_one
    if device:get_field(THREE_PHASE_FIELD) then
      -- Removed again after GONE_AFTER_SECONDS of meter reads without B/C
      -- voltage (e.g. phantom voltage on unconnected inputs set it once).
      if ph or not reading.meter_read then
        device:set_field(PHASES_ABSENT_SINCE_FIELD, nil, { persist = true })
      else
        local since = device:get_field(PHASES_ABSENT_SINCE_FIELD)
        if not since then
          device:set_field(PHASES_ABSENT_SINCE_FIELD, os.time(), { persist = true })
        elseif os.time() - since >= GONE_AFTER_SECONDS then
          device:set_field(THREE_PHASE_FIELD, nil, { persist = true })
          device:set_field(PHASES_ABSENT_SINCE_FIELD, nil, { persist = true })
          log.info("SolarEdge: no voltage on phases B and C for 24 h, back to single phase (profile "
            .. target_profile(device) .. ")")
          apply_profile(device, target_profile(device))
        end
      end
    else
      local seen = ph and (device:get_field(PHASES_SEEN_FIELD) or 0) + 1 or 0
      device:set_field(PHASES_SEEN_FIELD, seen)
      if seen < PHASES_CONFIRM_POLLS then
        if ph then
          log.info(string.format("SolarEdge: three phases read, confirming %d/%d", seen, PHASES_CONFIRM_POLLS))
        end
        ph = nil
      end
    end
    if not ph and one and grid and device:supports_capability(PHASE_CAPS[1], "grid") then
      -- Single phase: the one row shows L1's voltage and current too.
      if one.power then
        device:emit_component_event(grid, PHASE_CAPS[1].power({ value = round(one.power), unit = "W" }))
      end
      device:emit_component_event(grid, PHASE_CAPS[1].voltage({ value = round(one.voltage, 1), unit = "V" }))
      if one.current then
        device:emit_component_event(grid, PHASE_CAPS[1].current({ value = round(one.current, 1), unit = "A" }))
      end
    end
    if ph then
      if not device:get_field(THREE_PHASE_FIELD) then
        device:set_field(THREE_PHASE_FIELD, true, { persist = true })
        log.info("SolarEdge: three-phase grid meter detected, switching to profile " .. target_profile(device))
        apply_profile(device, target_profile(device))
      end
      local parts = {}
      for i = 1, 3 do
        parts[i] = string.format("L%d %sW %sV %sA", i, fmt("%.0f", ph.power[i]), fmt("%.1f", ph.voltage[i]), fmt("%.1f", ph.current[i]))
      end
      log.info("SolarEdge grid phases: " .. table.concat(parts, ", "))
      local gc = device.profile.components.grid
      if gc then
        for i, cap in ipairs(PHASE_CAPS) do
          -- Each row checked on its own: right after the switch the old
          -- single-phase profile has only L1.
          if device:supports_capability(cap, "grid") then
            -- Whole watts so "826 W" fits its cell without wrapping.
            if ph.power[i] then
              device:emit_component_event(gc, cap.power({ value = round(ph.power[i]), unit = "W" }))
            end
            device:emit_component_event(gc, cap.voltage({ value = round(ph.voltage[i], 1), unit = "V" }))
            if ph.current[i] then
              device:emit_component_event(gc, cap.current({ value = round(ph.current[i], 1), unit = "A" }))
            end
          end
        end
      end
    end

    -- Battery (StorEdge / hybrid) is optional hardware, read-only. The
    -- battery section (and the header battery icon) appears only after a
    -- battery has been read on BATTERY_CONFIRM_POLLS polls in a row, and
    -- is removed again after GONE_AFTER_SECONDS of clean "no battery"
    -- reads (failed reads don't count). A single garbled read after a driver update once added it to a
    -- battery-less inverter for good (2026-10-10).
    local batt = reading.battery
    if batt then
      device:set_field(BATTERY_ABSENT_SINCE_FIELD, nil, { persist = true })
      if not device:get_field(HAS_BATTERY_FIELD) then
        local seen = (device:get_field(BATTERY_SEEN_FIELD) or 0) + 1
        device:set_field(BATTERY_SEEN_FIELD, seen)
        if seen >= BATTERY_CONFIRM_POLLS then
          device:set_field(HAS_BATTERY_FIELD, true, { persist = true })
          log.info(string.format("SolarEdge: battery confirmed (rated %.0f Wh, %d polls), switching to profile %s",
            batt.rated_energy_wh, seen, target_profile(device)))
          apply_profile(device, target_profile(device))
        else
          log.info(string.format("SolarEdge: battery read (rated %.0f Wh), confirming %d/%d",
            batt.rated_energy_wh, seen, BATTERY_CONFIRM_POLLS))
        end
      end
      log.info(string.format("SolarEdge battery: %s%%, %sW, %sV, %s, status=%s",
        tostring(batt.soe_pct), tostring(batt.power_w), tostring(batt.voltage_v),
        batt.temp_c and string.format("%.1fC", batt.temp_c) or "n/a", tostring(batt.status_name)))
      local bc = device.profile.components.battery
      if bc then
        if batt.soe_pct then
          local pct = math.floor(math.max(0, math.min(100, batt.soe_pct)) + 0.5)
          device:emit_component_event(bc, capabilities.battery.battery({ value = pct }))
        end
        if batt.power_w then
          device:emit_component_event(bc, capabilities.powerMeter.power({ value = batt.power_w, unit = "W" }))
        end
        -- No voltage tile: on hybrids (e.g. SE10K-RWB48 with a 48 V
        -- battery) 0xE170 reported ~820 V = the inverter's DC bus, not the
        -- battery terminals, so it was misleading. Still logged above.
        if batt.temp_c then
          device:emit_component_event(bc, capabilities.temperatureMeasurement.temperature({ value = batt.temp_c, unit = "C" }))
        end
        -- Battery Status on its own line, then one Battery Storage row
        -- (Charge Level, Health, Available): four values in one row wrapped
        -- on Android. The standard battery % only renders in the header.
        if batt.status_name then
          device:emit_component_event(bc, BATTERY_STATUS_CAP.status({ value = batt.status_name }))
        end
        if batt.soe_pct then
          local lvl = math.floor(math.max(0, math.min(100, batt.soe_pct)) * 10 + 0.5) / 10
          device:emit_component_event(bc, BATTERY_STORAGE_CAP.chargeLevel({ value = lvl, unit = "%" }))
        end
        if batt.soh_pct then
          local h = math.floor(math.max(0, math.min(100, batt.soh_pct)) * 10 + 0.5) / 10
          device:emit_component_event(bc, BATTERY_STORAGE_CAP.health({ value = h, unit = "%" }))
        end
        if batt.energy_available_wh and batt.energy_available_wh >= 0 then
          local kwh = round(batt.energy_available_wh / 1000, 1)
          device:emit_component_event(bc, BATTERY_STORAGE_CAP.energyAvailable({ value = kwh, unit = "kWh" }))
        end
      end
    else
      device:set_field(BATTERY_SEEN_FIELD, 0)
      -- Only clean "no battery" reads count; a failed read says nothing.
      if device:get_field(HAS_BATTERY_FIELD) and reading.battery_state == "absent" then
        local since = device:get_field(BATTERY_ABSENT_SINCE_FIELD)
        if not since then
          device:set_field(BATTERY_ABSENT_SINCE_FIELD, os.time(), { persist = true })
        elseif os.time() - since >= GONE_AFTER_SECONDS then
          device:set_field(HAS_BATTERY_FIELD, nil, { persist = true })
          device:set_field(BATTERY_ABSENT_SINCE_FIELD, nil, { persist = true })
          log.info("SolarEdge: no battery for 24 h, removing the battery section (profile "
            .. target_profile(device) .. ")")
          apply_profile(device, target_profile(device))
        end
      end
    end
  end)
  device:set_field(POLL_IN_PROGRESS_FIELD, false)
  if not ok then
    log.error("SolarEdge poll crashed: " .. tostring(err))
    record_poll_failure(device)
  end
end

local function start_polling(driver, device)
  local existing_timer = device:get_field(POLL_TIMER_FIELD)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
    device:set_field(POLL_TIMER_FIELD, nil)
  end

  local settings = get_settings(device)
  if not settings.ip or settings.ip == "" then
    log.info("SolarEdge device has no IP configured yet — not starting poll timer")
    return
  end

  -- Register the recurring timer BEFORE the immediate poll below (not
  -- after, as this used to) -- poll_once's own comment explains why:
  -- a slow first call (unreachable/misconfigured inverter) no longer
  -- delays the timer's own registration, safe now that poll_once's
  -- in-flight guard prevents this device's scheduled and immediate
  -- calls from ever overlapping.
  local timer = device.thread:call_on_schedule(settings.poll_interval, function()
    poll_once(driver, device)
  end, "solaredge_poll")
  device:set_field(POLL_TIMER_FIELD, timer)
  log.info(string.format("SolarEdge polling started: %s:%d every %ds",
    settings.ip, settings.port, settings.poll_interval))
  poll_once(driver, device)
end


local function device_init(driver, device)
  log.info("SolarEdge device init (profile migration check): " .. device.id)
  -- Migrate devices provisioned under an older profile name. Capability
  -- changes need a new profile name, since a profile's detailView layout
  -- is generated once at creation and doesn't regenerate when the
  -- same-named profile's capability list changes on a later repackage.
  -- (device.profile.id is a UUID, so it can't be compared to these names.)
  local target = target_profile(device)
  if device:get_field(APPLIED_PROFILE_FIELD) ~= target or not profile_matches(device) then
    log.info("SolarEdge applying profile " .. target)
    apply_profile(device, target)
  end
  start_polling(driver, device)
end

local function device_added(driver, device)
  log.info("SolarEdge device added: " .. device.id)
  device:emit_event(capabilities.powerMeter.power({ value = 0, unit = "W" }))
end

--- Fires when the user changes device settings (IP, port, unit ID, poll
--- interval) in the SmartThings app. This is how the real IP actually gets
--- into the driver, since discovery.lua creates the device without one.
--- Also fires on the driver's own profile switches and on renames: polling
--- restarts only when a connection setting changed (an extra poll right
--- after another one contends for the inverter's single Modbus connection).
local function info_changed(driver, device, event, args)
  local old = args and args.old_st_store and args.old_st_store.preferences
  local new = device.preferences or {}
  if old then
    local changed = false
    for _, key in ipairs({ "ipAddress", "modbusPort", "unitId", "pollInterval" }) do
      if old[key] ~= new[key] then
        changed = true
      end
    end
    if not changed then
      return
    end
  end
  log.info("SolarEdge device preferences changed, restarting polling")
  start_polling(driver, device)
end

local function device_removed(driver, device)
  local existing_timer = device:get_field(POLL_TIMER_FIELD)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
  end
  log.info("SolarEdge device removed: " .. device.id)
end

local function refresh_handler(driver, device, command)
  poll_once(driver, device)
end

local se_driver = Driver("se-modbus-tcp", {
  discovery = discovery.discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    infoChanged = info_changed,
    removed = device_removed,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
  },
})

se_driver:run()
