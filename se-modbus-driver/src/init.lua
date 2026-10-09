local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local SolarEdge = require "solaredge"

local POLL_TIMER_FIELD = "poll_timer"
local POLL_IN_PROGRESS_FIELD = "poll_in_progress"
local HAS_BATTERY_FIELD = "has_battery"
local THREE_PHASE_FIELD = "three_phase"
-- Profile per detected hardware. Non-battery single-phase installs stay
-- on CURRENT_PROFILE. Both detections are persisted and only
-- ever switch ON, once, so profiles never oscillate.
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
      return
    end

    local temp_display = reading.temp_c and string.format("%.1fC", reading.temp_c) or "n/a"
    log.info(string.format("SolarEdge reading: %.1fW, %.1fWh lifetime, %.1fV DC, %.1fW DC, %s, status=%s",
      reading.power_w, reading.energy_wh, reading.dc_voltage, reading.dc_power_w, temp_display, reading.status_name))

    device:emit_event(capabilities.powerMeter.power({ value = reading.power_w, unit = "W" }))
    device:emit_event(capabilities.energyMeter.energy({ value = reading.energy_wh / 1000.0, unit = "kWh" }))
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
      device:emit_component_event(dc, DC_INPUT_CAP.voltage({ value = round(reading.dc_voltage, 1), unit = "V" }))
      if reading.dc_current_a then
        device:emit_component_event(dc, DC_INPUT_CAP.current({ value = round(reading.dc_current_a, 1), unit = "A" }))
      end
      device:emit_component_event(dc, capabilities.powerMeter.power({ value = reading.dc_power_w, unit = "W" }))
    end

    -- Grid meter is optional hardware — nil means this installation doesn't
    -- have one wired up (or it wasn't readable this cycle), not an error.
    local grid = device.profile.components.grid
    if grid and reading.grid_power_w then
      log.info(string.format("SolarEdge grid meter: %.1fW net (%s), %.1fkWh exported, %.1fkWh imported",
        reading.grid_power_w, reading.grid_power_w >= 0 and "exporting" or "importing",
        reading.grid_exported_wh / 1000.0, reading.grid_imported_wh / 1000.0))
      device:emit_component_event(grid, capabilities.powerMeter.power({ value = reading.grid_power_w, unit = "W" }))
      -- Whole kWh: lifetime totals in the thousands wrap their tile otherwise.
      device:emit_component_event(grid, GRID_ENERGY_CAP.exported({ value = round(reading.grid_exported_wh / 1000.0), unit = "kWh" }))
      device:emit_component_event(grid, GRID_ENERGY_CAP.imported({ value = round(reading.grid_imported_wh / 1000.0), unit = "kWh" }))
    end

    -- Per-phase grid power/voltage: only when the meter shows real voltage
    -- on phases B and C (solaredge.lua decides). First detection switches
    -- the profile once, same pattern as the battery below.
    local ph = reading.grid_phases
    local one = reading.grid_phase_one
    if not ph and one and grid and device:supports_capability(PHASE_CAPS[1], "grid") then
      -- Single phase: the one row shows L1's voltage and current too.
      device:emit_component_event(grid, PHASE_CAPS[1].power({ value = round(one.power), unit = "W" }))
      device:emit_component_event(grid, PHASE_CAPS[1].voltage({ value = round(one.voltage, 1), unit = "V" }))
      device:emit_component_event(grid, PHASE_CAPS[1].current({ value = round(one.current, 1), unit = "A" }))
    end
    if ph then
      if not device:get_field(THREE_PHASE_FIELD) then
        device:set_field(THREE_PHASE_FIELD, true, { persist = true })
        log.info("SolarEdge: three-phase grid meter detected, switching to profile " .. target_profile(device))
        device:try_update_metadata({ profile = target_profile(device) })
      end
      log.info(string.format("SolarEdge grid phases: L1 %.0fW %.1fV %.1fA, L2 %.0fW %.1fV %.1fA, L3 %.0fW %.1fV %.1fA",
        ph.power[1], ph.voltage[1], ph.current[1], ph.power[2], ph.voltage[2], ph.current[2],
        ph.power[3], ph.voltage[3], ph.current[3]))
      local gc = device.profile.components.grid
      if gc and device:supports_capability(PHASE_CAPS[1], "grid") then
        for i, cap in ipairs(PHASE_CAPS) do
          -- Whole watts so "826 W" fits its cell without wrapping.
          device:emit_component_event(gc, cap.power({ value = round(ph.power[i]), unit = "W" }))
          device:emit_component_event(gc, cap.voltage({ value = round(ph.voltage[i], 1), unit = "V" }))
          device:emit_component_event(gc, cap.current({ value = round(ph.current[i], 1), unit = "A" }))
        end
      end
    end

    -- Battery (StorEdge / hybrid) is optional hardware, read-only. The
    -- first time one is detected, remember it and move the device to the
    -- battery profile once (guarded by the persisted field, so this never
    -- repeats or oscillates; installs without a battery never switch).
    local batt = reading.battery
    if batt then
      if not device:get_field(HAS_BATTERY_FIELD) then
        device:set_field(HAS_BATTERY_FIELD, true, { persist = true })
        log.info(string.format("SolarEdge: battery detected (rated %.0f Wh), switching to profile %s",
          batt.rated_energy_wh, target_profile(device)))
        device:try_update_metadata({ profile = target_profile(device) })
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
    end
  end)
  device:set_field(POLL_IN_PROGRESS_FIELD, false)
  if not ok then
    log.error("SolarEdge poll crashed: " .. tostring(err))
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
  local target = target_profile(device)
  if device.profile.id ~= target then
    log.info("SolarEdge migrating device from profile " .. tostring(device.profile.id) .. " to " .. target)
    device:try_update_metadata({ profile = target })
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
local function info_changed(driver, device, event, args)
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
