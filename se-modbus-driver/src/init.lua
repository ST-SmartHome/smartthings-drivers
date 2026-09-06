local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local SolarEdge = require "solaredge"

local POLL_TIMER_FIELD = "poll_timer"
local POLL_IN_PROGRESS_FIELD = "poll_in_progress"
local STATUS_CAP = capabilities["examplens.inverterStatus"]
local GRID_ENERGY_CAP = capabilities["examplens.gridEnergy"]

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
      device:emit_component_event(dc, capabilities.voltageMeasurement.voltage({ value = reading.dc_voltage, unit = "V" }))
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
      device:emit_component_event(grid, GRID_ENERGY_CAP.exported({ value = reading.grid_exported_wh / 1000.0, unit = "kWh" }))
      device:emit_component_event(grid, GRID_ENERGY_CAP.imported({ value = reading.grid_imported_wh / 1000.0, unit = "kWh" }))
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

local CURRENT_PROFILE = "solaredge-inverter.v6"

local function device_init(driver, device)
  log.info("SolarEdge device init (profile migration check): " .. device.id)
  -- Migrate devices provisioned under an older profile name (e.g. adding
  -- inverterStatus required bumping v1 -> v2, adding the dc component for
  -- DC voltage/power required bumping v4 -> v5, since a profile's
  -- detailView layout is generated once at profile-creation time and
  -- doesn't regenerate just because the same-named profile's capability
  -- list changes on a later repackage).
  if device.profile.id ~= CURRENT_PROFILE then
    log.info("SolarEdge migrating device from profile " .. tostring(device.profile.id) .. " to " .. CURRENT_PROFILE)
    device:try_update_metadata({ profile = CURRENT_PROFILE })
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

local se_driver = Driver("se-modbus-v4", {
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
