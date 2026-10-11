--- RainMachine irrigation controller, local HTTP API.
---
--- Devices:
---   controller (one per RainMachine): irrigation status, rain delay,
---     "Stop all watering", and the IP/password settings;
---   one child device per active zone: switch (on = water for the zone's
---     Watering Time), Watering Time, Time Remaining;
---   one child device per active program: switch (start/stop), Next Run.
---
--- Children are created as zones/programs are found. They are never deleted
--- automatically: a zone that goes inactive or disappears marks its device
--- offline instead, so routines and voice assistants keep their target. A
--- child the user deletes is remembered and not recreated until discovery
--- ("Scan for nearby devices") is run again.

local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"

local Client = require "rm_api"
local discovery = require "discovery"

local STATUS_CAP = capabilities["aboutisland47519.irrigationStatus"]
local RAIN_DELAY_CAP = capabilities["aboutisland47519.rainDelay"]
local STOP_ALL_CAP = capabilities["aboutisland47519.stopAllWatering"]
local WATERING_TIME_CAP = capabilities["aboutisland47519.wateringTime"]
local TIME_REMAINING_CAP = capabilities["aboutisland47519.timeRemaining"]
local NEXT_RUN_CAP = capabilities["aboutisland47519.nextRun"]
local NEXT_WATERING_CAP = capabilities["aboutisland47519.nextWatering"]
local FORECAST_CAP = capabilities["aboutisland47519.weatherForecast"]
local WEATHER_CAP = capabilities["aboutisland47519.weatherToday"]

local CONTROLLER_PROFILE = "rainmachine-controller.v5"
local ZONE_PROFILE = "rainmachine-zone.v1"
local PROGRAM_PROFILE = "rainmachine-program.v1"

local DEFAULT_WATERING_MINUTES = 10
local WATERING_POLL_SECONDS = 10
local COMMAND_REPOLL_SECONDS = 2
local CHILD_CREATE_RETRY_SECONDS = 120
local FORECAST_REFRESH_SECONDS = 15 * 60
local FORECAST_LAST_FIELD = "forecast_last"
local STOPPED_AT_FIELD = "stopped_at"
local STOPPED_SHOW_SECONDS = 30 * 60
local PCT_BY_DAY_FIELD = "watering_pct_by_day"
local DETAILS_FIELD = "program_day_details"
local MAX_COEF_FIELD = "max_watering_coef"

local CLIENT_FIELD = "client"
local CLIENT_KEY_FIELD = "client_key"
local HW_VER_FIELD = "hw_ver"
local DEDICATED_MV_FIELD = "dedicated_master_valve"
local POLL_TIMER_FIELD = "poll_timer"
local IGNORED_FIELD = "ignored_children"
local CHILD_OFFLINE_FIELD = "child_offline"

-- ===== Device helpers =====

--- Zone and program devices are recognised by their network id. Not by
--- parent_device_id: on a LAN device the platform sets that to the hub.
local function is_child(device)
  local dni = tostring(device.device_network_id)
  return dni:match("%-zone%-%d+$") ~= nil or dni:match("%-program%-%d+$") ~= nil
end

--- "zone", uid or "program", uid from a child's network id.
local function child_kind(device)
  local kind, uid = tostring(device.device_network_id):match("%-(%a+)%-(%d+)$")
  return kind, tonumber(uid)
end

local function child_key(parent, kind, uid)
  return parent.device_network_id .. "-" .. kind .. "-" .. tostring(uid)
end

local function children_of(driver, parent)
  local found = {}
  for _, d in ipairs(driver:get_devices()) do
    if d.parent_device_id == parent.id and is_child(d) then
      found[d.device_network_id] = d
    end
  end
  return found
end

local function set_child_online(child, online, reason)
  local offline = child:get_field(CHILD_OFFLINE_FIELD) == true
  if online and offline then
    child:online()
    child:set_field(CHILD_OFFLINE_FIELD, false)
  elseif not online and not offline then
    child:offline()
    child:set_field(CHILD_OFFLINE_FIELD, true)
    log.warn("RainMachine " .. tostring(child.label) .. " offline: " .. reason)
  end
end

local function get_settings(device)
  local prefs = device.preferences or {}
  return {
    ip = prefs.ipAddress,
    port = tonumber(prefs.port) or 8081,
    password = prefs.password,
    poll_interval = tonumber(prefs.pollInterval) or 30,
  }
end

local MDNS_IP_FIELD = "mdns_ip"
local MDNS_LAST_FIELD = "mdns_last_lookup"
local MDNS_RETRY_SECONDS = 60

local function ip_is_set(ip)
  return ip ~= nil and ip ~= "0.0.0.0" and ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

--- The IP setting wins when it's filled in; otherwise the address found by
--- mDNS (looked up again at most every MDNS_RETRY_SECONDS when unknown, or
--- when polls start failing because the address changed).
local function resolve_ip(device, s, force)
  if ip_is_set(s.ip) then
    return s.ip
  end
  local known = device:get_field(MDNS_IP_FIELD)
  if known and not force then
    return known
  end
  local last = device:get_field(MDNS_LAST_FIELD)
  if last and os.time() - last < MDNS_RETRY_SECONDS then
    return known
  end
  device:set_field(MDNS_LAST_FIELD, os.time())
  local found = discovery.find_rainmachines()
  if #found > 0 then
    if found[1].ip ~= known then
      log.info("RainMachine found by mDNS at " .. found[1].ip .. " (" .. found[1].name .. ")")
    end
    device:set_field(MDNS_IP_FIELD, found[1].ip, { persist = true })
    return found[1].ip
  end
  return known
end

local function settings_problem(s)
  if not ip_is_set(s.ip) then
    return "RainMachine not found on the network yet. If this persists, enter its IP address in Settings"
  end
  if not s.password or s.password == "" or s.password == "change-me" then
    return "set the RainMachine password in Settings"
  end
  if s.password:find("[\128-\255]") then
    return "the password contains a non-ASCII character (often a curly quote or dash the phone keyboard inserted); paste it again"
  end
  if s.password:match("^%s") or s.password:match("%s$") then
    return "the password starts or ends with a space; remove it"
  end
  return nil
end

local function get_client(device, s)
  local key = s.ip .. ":" .. s.port .. ":" .. s.password
  local client = device:get_field(CLIENT_FIELD)
  if not client or device:get_field(CLIENT_KEY_FIELD) ~= key then
    client = Client.new(s.ip, s.port, s.password)
    device:set_field(CLIENT_FIELD, client)
    device:set_field(CLIENT_KEY_FIELD, key)
  end
  return client
end

-- ===== Connection health (same scheme as the author's Tuya fan drivers) =====
-- A rejected password marks the controller offline at once and backs off to
-- one try every AUTH_BACKOFF_SECONDS until the settings change. Network
-- failures mark it offline after OFFLINE_AFTER_FAILURES polls in a row.

local AUTH_BACKOFF_SECONDS = 300
local OFFLINE_AFTER_FAILURES = 3
local AUTH_BACKOFF_UNTIL_FIELD = "auth_backoff_until"
local FAILURES_FIELD = "consecutive_poll_failures"
local OFFLINE_FIELD = "marked_offline"

local function mark_offline(driver, device, reason)
  if not device:get_field(OFFLINE_FIELD) then
    device:offline()
    device:set_field(OFFLINE_FIELD, true)
    for _, child in pairs(children_of(driver, device)) do
      set_child_online(child, false, "controller offline")
    end
  end
  log.error("RainMachine " .. tostring(device.label) .. " offline: " .. reason)
end

local function mark_online(device)
  device:set_field(FAILURES_FIELD, 0)
  device:set_field(AUTH_BACKOFF_UNTIL_FIELD, nil)
  if device:get_field(OFFLINE_FIELD) then
    device:online()
    device:set_field(OFFLINE_FIELD, false)
    log.info("RainMachine " .. tostring(device.label) .. " back online")
  end
end

local function record_failure(driver, device, err)
  if err == Client.AUTH_ERROR then
    device:emit_event(STATUS_CAP.status("Password rejected: check it in Settings"))
    device:set_field(AUTH_BACKOFF_UNTIL_FIELD, os.time() + AUTH_BACKOFF_SECONDS)
    mark_offline(driver, device, "the RainMachine rejected the password. Retrying every "
      .. AUTH_BACKOFF_SECONDS .. " s until the settings change")
    return
  end
  local failures = (device:get_field(FAILURES_FIELD) or 0) + 1
  device:set_field(FAILURES_FIELD, failures)
  log.warn("RainMachine poll failed (" .. failures .. "): " .. tostring(err))
  if failures >= OFFLINE_AFTER_FAILURES then
    mark_offline(driver, device, failures .. " polls in a row failed. Check the IP address and that the RainMachine is powered")
  end
end

-- ===== Applying status =====

local function minutes_up(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return 0
  end
  return math.ceil(seconds / 60)
end

--- The master valve output, using the same rules as RainMachine's own web
--- UI (rainmachine-web-ui js/ui-zones.js):
---   * provision.system.dedicatedMasterValve (Pro-8/16, which have a separate
---     master valve terminal): valve 1 is that terminal, and zone N is
---     valve N+1;
---   * otherwise (Mini-8, HD-12/16): zone N is valve N, and a zone flagged
---     `master` is being used as the master valve.
--- hwVer for reference: 2 Mini-8, 3 HD-12/16, 5 Pro.
--- The master valve never gets a device: RainMachine opens it whenever a zone
--- runs, and switching it on alone can run a pump against closed zones.
--- (1st-generation units report only uid/name/state/remaining/type/master
--- per zone, with no `active` field, so a missing `active` counts as active.)
local function is_master_valve(zone, dedicated)
  return zone.master == true or (dedicated == true and zone.uid == 1)
end

--- The zone number RainMachine itself shows.
local function zone_label(zone, dedicated)
  local number = dedicated and (zone.uid - 1) or zone.uid
  return "Zone " .. number .. ": " .. tostring(zone.name)
end

local function ignored(parent)
  return parent:get_field(IGNORED_FIELD) or {}
end

local function request_child(driver, parent, kind, uid, label, profile)
  local key = child_key(parent, kind, uid)
  if ignored(parent)[key] then
    return
  end
  local field = "requested_" .. key
  local last = parent:get_field(field)
  if last and os.time() - last < CHILD_CREATE_RETRY_SECONDS then
    return
  end
  parent:set_field(field, os.time())
  log.info("RainMachine creating " .. kind .. " device: " .. label)
  local ok, err = driver:try_create_device({
    type = "LAN",
    device_network_id = key,
    label = label,
    profile = profile,
    manufacturer = "RainMachine",
    model = kind == "zone" and "Zone" or "Program",
    vendor_provided_label = label,
    parent_device_id = parent.id,
  })
  if not ok and not tostring(err):find("DNI already exists") then
    log.error("RainMachine failed to create " .. kind .. " device " .. label .. ": " .. tostring(err))
  end
end

-- ===== Next watering and forecast =====

local function parse_date(text)
  local y, m, d = tostring(text):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

--- Estimated run length, from the program's own settings:
---   * each active zone's time, scaled by RainMachine's weather-adjusted
---     watering percentage for that day (dailystats), capped at
---     provision.system.maxWateringCoef;
---   * the program's delay between zones (delay_on/delay, seconds);
---   * cycle & soak (cs_on/cycles/soak): a zone's soak pause overlaps the
---     other zones' cycles, so only the uncovered part of each pause adds
---     time: (cycles - 1) * max(0, soak - (zones - 1) * average zone time / cycles).
--- dailystats/details wateringFlag reasons (RainMachine API docs), shortened
--- for the tile.
local SKIP_REASONS = {
  [1] = "Stopped", [2] = "Below Threshold", [3] = "Freeze", [4] = "Restricted Day",
  [5] = "Restricted Day", [6] = "Water Surplus", [7] = "Rain Sensor", [8] = "Rain",
  [9] = "Restricted Month", [10] = "Rain Delay", [11] = "Rain",
}

local function estimated_minutes(p, date_key, pct_by_day, max_coef, details)
  local total, zones = 0, 0
  for _, w in ipairs(p.wateringTimes or {}) do
    if w.active and type(w.duration) == "number" and w.duration > 0 then
      total = total + w.duration
      zones = zones + 1
    end
  end
  if zones == 0 then
    return nil
  end
  -- Prefer RainMachine's own calculated run time for that day and program
  -- (dailystats/details); fall back to the percentage estimate.
  local known = details and details[date_key] and details[date_key][p.uid]
  local run
  if known then
    if known.seconds <= 0 then
      return 0, SKIP_REASONS[known.flag] or "Skipped"
    end
    run = known.seconds
  else
    local coef = (pct_by_day and pct_by_day[date_key]) and (pct_by_day[date_key] / 100) or 1
    coef = math.min(coef, max_coef or 2)
    run = total * coef
  end
  local seconds = run
  if p.delay_on and tonumber(p.delay) and p.delay > 0 then
    seconds = seconds + (zones - 1) * p.delay
  end
  local cycles = tonumber(p.cycles) or 0
  if p.cs_on and cycles > 1 and tonumber(p.soak) and p.soak > 0 then
    local covered = (zones - 1) * (run / zones) / cycles
    seconds = seconds + (cycles - 1) * math.max(0, p.soak - covered)
  end
  return math.floor(seconds / 60 + 0.5)
end

--- "Sun 11 Oct 17:50  ~53 min" for the earliest next run among active programs.
local function next_watering_text(programs, pct_by_day, max_coef, details)
  local best_key, best_text
  for _, p in ipairs(programs) do
    local t = p.active ~= false and parse_date(p.nextRun)
    if t then
      local params = p.startTimeParams or {}
      local clock = (params.type or 0) == 0 and tostring(p.startTime) or nil
      local key = os.date("!%Y-%m-%d", t) .. " " .. (clock or "99:99")
      if not best_key or key < best_key then
        best_key = key
        best_text = os.date("!%a %d %b", t):gsub(" 0", " ") .. (clock and (" " .. clock) or " (sunrise/sunset)")
        local minutes, reason = estimated_minutes(p, os.date("!%Y-%m-%d", t), pct_by_day, max_coef, details)
        if reason then
          best_text = best_text .. " Skipped: " .. reason
        elseif minutes then
          best_text = best_text .. " ~" .. minutes .. "\u{00A0}min"
        end
      end
    end
  end
  return best_text or "None scheduled"
end

--- Text layout: the app collapses repeated spaces and wraps at any space or
--- dash, so groups are separated by an em space (U+2003, not collapsed) and
--- spaces inside a group are non-breaking (U+00A0), with a word joiner
--- (U+2060) after the en dash in temperature ranges.

--- Units follow the owner's RainMachine app setting
--- (provision.system.uiUnitsMetric). The API itself is always metric.
local units_metric = true

local function fmt_temp(celsius)
  local v = units_metric and celsius or (celsius * 9 / 5 + 32)
  return math.floor(v + 0.5)
end

local function fmt_wind(ms)
  if units_metric then
    return string.format("%d\u{202F}km/h", math.floor(ms * 3.6 + 0.5))
  end
  return string.format("%d\u{202F}mph", math.floor(ms * 2.23694 + 0.5))
end

--- Rain amounts carry no unit (mm or in by the RainMachine setting), to
--- keep tile lines short; user preference 10-11.
local function fmt_rain(mm)
  if mm <= 0 then
    return "0"
  end
  return units_metric and string.format("%.1f", mm) or string.format("%.2f", mm / 25.4)
end

--- Weather condition codes from RainMachine's SDK (RMWeatherConditions,
--- rmWeatherData.py) mapped to emoji: custom tiles can't show icon images.
local CONDITION_ICONS = {
  [0] = "\u{1F325}\u{FE0F}", -- MostlyCloudy
  [1] = "\u{2600}\u{FE0F}", -- Fair
  [2] = "\u{1F324}\u{FE0F}", -- FewClouds
  [3] = "\u{26C5}", -- PartlyCloudy
  [4] = "\u{2601}\u{FE0F}", -- Overcast
  [5] = "\u{1F32B}\u{FE0F}", -- Fog
  [6] = "\u{1F32B}\u{FE0F}", -- Smoke
  [7] = "\u{1F328}\u{FE0F}", -- FreezingRain
  [8] = "\u{1F328}\u{FE0F}", -- IcePellets
  [9] = "\u{1F328}\u{FE0F}", -- RainIce
  [10] = "\u{1F328}\u{FE0F}", -- RainSnow
  [11] = "\u{1F326}\u{FE0F}", -- RainShowers
  [12] = "\u{26C8}\u{FE0F}", -- Thunderstorm
  [13] = "\u{2744}\u{FE0F}", -- Snow
  [14] = "\u{1F4A8}", -- Windy
  [15] = "\u{1F326}\u{FE0F}", -- ShowersInVicinity
  [16] = "\u{1F328}\u{FE0F}", -- HeavyFreezingRain
  [17] = "\u{26C8}\u{FE0F}", -- ThunderstormInVicinity
  [18] = "\u{1F326}\u{FE0F}", -- LightRain
  [19] = "\u{1F327}\u{FE0F}", -- HeavyRain
  [20] = "\u{1F32A}\u{FE0F}", -- FunnelCloud
  [21] = "\u{1F32B}\u{FE0F}", -- Dust
  [22] = "\u{1F32B}\u{FE0F}", -- Haze
  [23] = "\u{2600}\u{FE0F}", -- Hot
  [24] = "\u{2744}\u{FE0F}", -- Cold
}

local function condition_icon(day)
  local icon = CONDITION_ICONS[tonumber(day.condition)]
  return icon and (icon .. "\u{00A0}") or ""
end

local function day_forecast(label, day)
  local lo, hi = tonumber(day.minTemp), tonumber(day.maxTemp)
  local text = label .. "\u{00A0}" .. condition_icon(day)
  if lo and hi then
    text = text .. string.format("%d\u{2013}\u{2060}%d\u{00B0}", fmt_temp(lo), fmt_temp(hi))
  end
  -- Rain only when some is forecast: the app cuts tiles off after two lines.
  local qpf = tonumber(day.qpf) or 0
  if qpf > 0 then
    -- No unit here: a rainy forecast day otherwise overflows the tile.
    text = text .. "\u{1F4A6}" .. fmt_rain(qpf)
    if tonumber(day.pop) and day.pop > 0 then
      text = text .. "\u{2614}" .. math.floor(day.pop) .. "%"
    end
  end
  return text
end

--- Latest actual reading from the controller's observation sources (those
--- with historical data, e.g. the Australian Bureau of Meteorology): the
--- newest hourly row at or before the controller's current time, plus the
--- rain recorded today. nil when no enabled source reports observations.
local function latest_observation(client, today, now_text)
  local list = client:get("parser")
  local best, best_rain
  for _, parser in ipairs((list and list.parsers) or {}) do
    if parser.enabled and parser.hasHistorical then
      local data = client:get("parser/" .. parser.uid .. "/data/" .. today .. "/1")
      local latest, rain, seen = nil, 0, {}
      for _, block in ipairs((data and data.parserData) or {}) do
        for _, day in ipairs(block.dailyValues or {}) do
          for _, h in ipairs(day.hourlyValues or {}) do
            local hour = tostring(h.hour)
            if hour:sub(1, 10) == today and hour <= now_text then
              if type(h.temperature) == "number" and (not latest or hour > latest.hour) then
                latest = h
              end
              if type(h.rain) == "number" and not seen[hour] then
                seen[hour] = true
                rain = rain + h.rain
              end
            end
          end
        end
      end
      if latest and (not best or latest.hour > best.hour) then
        best, best_rain = latest, rain
      end
    end
  end
  return best, best_rain
end

--- "☀️ 28°  79%RH  💨11 km/h  💦0 mm  @21:30" from an actual
--- reading; the icon is RainMachine's condition for the day.
local function observed_weather(obs, rain_today, day)
  local parts = { string.format("%d\u{00B0}", fmt_temp(obs.temperature)) }
  if type(obs.rh) == "number" then
    table.insert(parts, string.format("%d%%RH", math.floor(obs.rh + 0.5)))
  end
  if type(obs.wind) == "number" then
    table.insert(parts, "\u{1F4A8}" .. fmt_wind(obs.wind))
  end
  table.insert(parts, "\u{1F4A6}" .. fmt_rain(rain_today))
  table.insert(parts, "@" .. tostring(obs.hour):sub(12, 16))
  return condition_icon(day or {}) .. table.concat(parts, " ")
end

--- Today's weather as RainMachine itself sees it: the "mixer" result that
--- combines all of its enabled weather sources, the same numbers its
--- dashboard uses. Daily values, so it works for every owner whatever
--- sources they use (observation stations or forecast-only).
local function today_weather(day)
  local parts = {}
  if type(day.temperature) == "number" then
    table.insert(parts, string.format("Avg\u{00A0}%d\u{00B0}", fmt_temp(day.temperature)))
  end
  if type(day.rh) == "number" then
    table.insert(parts, string.format("%d%%RH", math.floor(day.rh + 0.5)))
  end
  if type(day.wind) == "number" then
    table.insert(parts, "\u{1F4A8}" .. fmt_wind(day.wind))
  end
  local rain = type(day.rain) == "number" and day.rain or 0
  table.insert(parts, "\u{1F4A6}" .. fmt_rain(rain))
  if #parts == 1 then
    return "No weather data yet"
  end
  -- Kept short: the app shows two lines per tile.
  return condition_icon(day) .. table.concat(parts, " ")
end

--- "Today 23–34 °C, no rain · Tomorrow 23–36 °C, 0.4 mm (50%)", from the
--- controller's own weather mix. Refreshed every FORECAST_REFRESH_SECONDS.
local function update_forecast(device, client, force)
  local last = device:get_field(FORECAST_LAST_FIELD)
  if not force and last and os.time() - last < FORECAST_REFRESH_SECONDS then
    return
  end
  local now = client:get("machine/time")
  local today = now and tostring(now.appDate or ""):match("^(%d%d%d%d%-%d%d%-%d%d)")
  if not today then
    return
  end
  -- Re-read the unit setting so a change in the RainMachine app shows up
  -- within one refresh.
  local provision = client:get("provision")
  if provision and provision.system then
    units_metric = provision.system.uiUnitsMetric ~= false
  end
  local mix = client:get("mixer/" .. today .. "/2")
  local days = mix and mix.mixerDataByDate
  if not days or not days[1] then
    return
  end
  local text = day_forecast("Today", days[1])
  if days[2] then
    local t = parse_date(days[2].day)
    text = text .. "\n" .. day_forecast(t and os.date("!%a", t) or "Tomorrow", days[2])
  end
  device:set_field(FORECAST_LAST_FIELD, os.time())
  device:emit_event(FORECAST_CAP.forecast(text))
  local stats = client:get("dailystats?days=7")
  if stats and stats.DailyStats then
    local pct = {}
    for _, d in ipairs(stats.DailyStats) do
      if d.day and tonumber(d.percentage) then
        pct[tostring(d.day):sub(1, 10)] = tonumber(d.percentage)
      end
    end
    device:set_field(PCT_BY_DAY_FIELD, pct)
  end
  -- Per day and program: RainMachine's calculated seconds, and the reason
  -- code when nothing will water.
  local det = client:get("dailystats/details")
  if det and det.DailyStatsDetails then
    local by_day = {}
    for _, d in ipairs(det.DailyStatsDetails) do
      local day_key = tostring(d.day or ""):sub(1, 10)
      by_day[day_key] = {}
      for _, prog in ipairs(d.programs or {}) do
        local secs, flag = 0, nil
        for _, z in ipairs(prog.zones or {}) do
          secs = secs + (tonumber(z.computedWateringTime) or 0)
          local f = tonumber(z.wateringFlag)
          if f and f ~= 0 and not flag then
            flag = f
          end
        end
        by_day[day_key][prog.id] = { seconds = secs, flag = flag }
      end
    end
    device:set_field(DETAILS_FIELD, by_day)
  end
  if device:supports_capability_by_id(WEATHER_CAP.ID) then
    -- Actual readings when a source reports them, otherwise RainMachine's
    -- combined figure for the day.
    local ok, obs, rain_today = pcall(latest_observation, client, today, tostring(now.appDate))
    if ok and obs then
      device:emit_event(WEATHER_CAP.weather(observed_weather(obs, rain_today, days[1])))
    else
      device:emit_event(WEATHER_CAP.weather(today_weather(days[1])))
    end
  end
end

local function status_text(zones, restrictions)
  local queued = 0
  for _, z in ipairs(zones) do
    if z.state == 1 then
      return "Watering " .. tostring(z.name) .. ", " .. minutes_up(z.remaining) .. " min left"
    elseif z.state == 2 then
      queued = queued + 1
    end
  end
  if queued > 0 then
    return queued .. (queued == 1 and " zone" or " zones") .. " queued"
  end
  local r = restrictions or {}
  if r.rainDelay then
    return "Paused: rain delay"
  elseif r.freeze then
    return "Paused: freeze protection"
  elseif r.rainSensor then
    return "Paused: rain sensor"
  elseif r.month or r.weekDay or r.hourly then
    return "Restricted now (schedule restriction)"
  end
  return "Idle"
end

local function apply_status(driver, device, zones, programs, restrictions, s)
  local dedicated = device:get_field(DEDICATED_MV_FIELD) == true
  local existing = children_of(driver, device)
  local seen = {}
  local watering = false

  for _, z in ipairs(zones) do
    if z.state ~= 0 then
      watering = true
    end
    local key = child_key(device, "zone", z.uid)
    seen[key] = true
    local eligible = z.active ~= false and not is_master_valve(z, dedicated)
    local child = existing[key]
    if child then
      if eligible then
        set_child_online(child, true)
        child:emit_event(capabilities.switch.switch(z.state ~= 0 and "on" or "off"))
        child:emit_event(TIME_REMAINING_CAP.timeRemaining({ value = z.state == 1 and minutes_up(z.remaining) or 0, unit = "min" }))
      else
        set_child_online(child, false, z.active ~= false and "zone is now the master valve; RainMachine opens it automatically" or "zone is inactive in RainMachine")
      end
    elseif eligible then
      request_child(driver, device, "zone", z.uid, zone_label(z, dedicated), ZONE_PROFILE)
    end
  end

  for _, p in ipairs(programs) do
    local key = child_key(device, "program", p.uid)
    seen[key] = true
    local child = existing[key]
    if child then
      if p.active ~= false then
        set_child_online(child, true)
        child:emit_event(capabilities.switch.switch((p.status or 0) ~= 0 and "on" or "off"))
        local next_run = "Not scheduled"
        if p.nextRun then
          local params = p.startTimeParams or {}
          next_run = p.nextRun .. ((params.type or 0) == 0 and (" " .. tostring(p.startTime)) or "")
        end
        child:emit_event(NEXT_RUN_CAP.nextRun(next_run))
      else
        set_child_online(child, false, "program is inactive in RainMachine")
      end
      if (p.status or 0) ~= 0 then
        watering = true
      end
    elseif p.active ~= false then
      -- "Program: <name>"; set at creation only.
      request_child(driver, device, "program", p.uid, "Program: " .. tostring(p.name), PROGRAM_PROFILE)
    end
  end

  for key, child in pairs(existing) do
    if not seen[key] then
      set_child_online(child, false, "no longer exists in RainMachine")
    end
  end

  -- After "Stop all watering", show that it worked until watering starts
  -- again or STOPPED_SHOW_SECONDS pass (RainMachine keeps no such state).
  local status = status_text(zones, restrictions)
  local stopped_at = device:get_field(STOPPED_AT_FIELD)
  if stopped_at then
    if watering or os.time() - stopped_at > STOPPED_SHOW_SECONDS then
      device:set_field(STOPPED_AT_FIELD, nil)
    elseif status == "Idle" then
      status = "Stopped by user"
    end
  end
  device:emit_event(STATUS_CAP.status(status))
  if device:supports_capability_by_id(NEXT_WATERING_CAP.ID) then
    device:emit_event(NEXT_WATERING_CAP.nextWatering(next_watering_text(programs,
      device:get_field(PCT_BY_DAY_FIELD), device:get_field(MAX_COEF_FIELD), device:get_field(DETAILS_FIELD))))
  end
  local delay_days = 0
  if restrictions and restrictions.rainDelay then
    delay_days = math.max(1, math.ceil((tonumber(restrictions.rainDelayCounter) or 0) / 86400))
  end
  device:emit_event(RAIN_DELAY_CAP.rainDelay({ value = math.min(delay_days, 14), unit = "days" }))
  return watering
end

-- ===== Polling =====

--- Returns true while something is watering or queued (poll faster then).
local function poll_once(driver, device)
  local s = get_settings(device)
  s.ip = resolve_ip(device, s, (device:get_field(FAILURES_FIELD) or 0) >= 2)
  local problem = settings_problem(s)
  if problem then
    device:emit_event(STATUS_CAP.status("Not set up: " .. problem))
    mark_offline(driver, device, problem)
    return false
  end
  local backoff_until = device:get_field(AUTH_BACKOFF_UNTIL_FIELD)
  if backoff_until and os.time() < backoff_until then
    return false
  end
  local client = get_client(device, s)
  if not device:get_field(HW_VER_FIELD) then
    local v = client:api_version()
    if v and v.hwVer then
      device:set_field(HW_VER_FIELD, tonumber(v.hwVer), { persist = true })
      log.info("RainMachine hwVer " .. tostring(v.hwVer) .. ", firmware " .. tostring(v.swVer) .. ", API " .. tostring(v.apiVer))
    end
  end
  if device:get_field(DEDICATED_MV_FIELD) == nil then
    local provision = client:get("provision")
    if provision and provision.system then
      device:set_field(DEDICATED_MV_FIELD, provision.system.dedicatedMasterValve == true)
      device:set_field(MAX_COEF_FIELD, tonumber(provision.system.maxWateringCoef))
      units_metric = provision.system.uiUnitsMetric ~= false
      log.info("RainMachine dedicated master valve terminal: " .. tostring(provision.system.dedicatedMasterValve == true)
        .. ", valves " .. tostring(provision.system.localValveCount))
    end
  end
  local zones, err = client:get("zone")
  if not zones then
    record_failure(driver, device, err)
    return false
  end
  local programs, perr = client:get("program")
  if not programs then
    record_failure(driver, device, perr)
    return false
  end
  local restrictions = client:get("restrictions/currently")
  mark_online(device)
  if device:supports_capability_by_id(FORECAST_CAP.ID) then
    local ok, err = pcall(update_forecast, device, client, false)
    if not ok then
      log.warn("RainMachine forecast failed: " .. tostring(err))
    end
  end
  return apply_status(driver, device, zones.zones or {}, programs.programs or {}, restrictions, s)
end

local schedule_poll

local function poll(driver, device)
  local ok, result = pcall(poll_once, driver, device)
  if not ok then
    log.error("RainMachine poll error: " .. tostring(result))
  end
  local s = get_settings(device)
  local delay = (ok and result) and WATERING_POLL_SECONDS or s.poll_interval
  local backoff_until = device:get_field(AUTH_BACKOFF_UNTIL_FIELD)
  if backoff_until then
    delay = math.max(delay, backoff_until - os.time())
  end
  schedule_poll(driver, device, delay)
end

schedule_poll = function(driver, device, delay)
  local timer = device:get_field(POLL_TIMER_FIELD)
  if timer then
    device.thread:cancel_timer(timer)
  end
  device:set_field(POLL_TIMER_FIELD, device.thread:call_with_delay(math.max(delay, 0), function()
    device:set_field(POLL_TIMER_FIELD, nil)
    poll(driver, device)
  end, "rainmachine poll"))
end

-- ===== Commands =====

local function controller_for(device)
  if is_child(device) then
    return device:get_parent_device()
  end
  return device
end

--- Sends one command through the controller's client, then re-polls soon.
local function send(driver, device, path, body)
  local parent = controller_for(device)
  if not parent then
    log.error("RainMachine " .. tostring(device.label) .. " has no controller")
    return
  end
  local s = get_settings(parent)
  s.ip = resolve_ip(parent, s, false)
  local problem = settings_problem(s)
  if problem then
    log.error("RainMachine command not sent: " .. problem)
    return
  end
  local client = get_client(parent, s)
  local data, err = client:post(path, body)
  if data then
    log.info("RainMachine " .. path .. " OK")
  else
    log.error("RainMachine " .. path .. " failed: " .. tostring(err))
    if err == Client.AUTH_ERROR then
      record_failure(driver, parent, err)
    end
  end
  schedule_poll(driver, parent, COMMAND_REPOLL_SECONDS)
end

local function watering_minutes(device)
  local value = device:get_latest_state("main", WATERING_TIME_CAP.ID, "wateringTime")
  return tonumber(value) or DEFAULT_WATERING_MINUTES
end

local function switch_on(driver, device, command)
  local kind, uid = child_kind(device)
  if kind == "zone" then
    send(driver, device, "zone/" .. uid .. "/start", { time = watering_minutes(device) * 60 })
  elseif kind == "program" then
    send(driver, device, "program/" .. uid .. "/start", { pid = uid })
  end
end

local function switch_off(driver, device, command)
  local kind, uid = child_kind(device)
  if kind == "zone" then
    send(driver, device, "zone/" .. uid .. "/stop", { zid = uid })
  elseif kind == "program" then
    send(driver, device, "program/" .. uid .. "/stop", { pid = uid })
  end
end

--- Changing Watering Time while the zone is on restarts it with the new
--- time, so a run can be shortened or extended without stopping it first.
local function set_watering_time(driver, device, command)
  local minutes = math.max(1, math.min(120, math.floor(tonumber(command.args.minutes) or DEFAULT_WATERING_MINUTES)))
  device:emit_event(WATERING_TIME_CAP.wateringTime({ value = minutes, unit = "min" }))
  local kind, uid = child_kind(device)
  if kind == "zone" and device:get_latest_state("main", capabilities.switch.ID, "switch") == "on" then
    log.info("RainMachine " .. tostring(device.label) .. " is on: restarting it for " .. minutes .. " min")
    send(driver, device, "zone/" .. uid .. "/stop", { zid = uid })
    send(driver, device, "zone/" .. uid .. "/start", { time = minutes * 60 })
  end
end

local function set_rain_delay(driver, device, command)
  local days = math.max(0, math.min(14, math.floor(tonumber(command.args.days) or 0)))
  send(driver, device, "restrictions/raindelay", { rainDelay = days })
end

local function stop_all(driver, device, command)
  device:set_field(STOPPED_AT_FIELD, os.time())
  send(driver, device, "watering/stopall", { all = true })
end

local function refresh(driver, device, command)
  local parent = controller_for(device)
  if parent then
    schedule_poll(driver, parent, 0)
  end
end

-- ===== Lifecycle =====

local function device_init(driver, device)
  if is_child(device) then
    local kind = child_kind(device)
    if kind == "zone" and device:get_latest_state("main", WATERING_TIME_CAP.ID, "wateringTime") == nil then
      device:emit_event(WATERING_TIME_CAP.wateringTime({ value = DEFAULT_WATERING_MINUTES, unit = "min" }))
    end
    return
  end
  log.info("RainMachine controller init: " .. tostring(device.label))
  -- Move the controller to the current layout whenever its version changes
  -- (a capability check alone misses layouts that only remove tiles).
  if device:get_field("controller_profile") ~= CONTROLLER_PROFILE
      or not device:supports_capability_by_id(WEATHER_CAP.ID)
      or device:supports_capability_by_id(capabilities.temperatureMeasurement.ID) then
    log.info("RainMachine switching controller to profile " .. CONTROLLER_PROFILE)
    device:try_update_metadata({ profile = CONTROLLER_PROFILE })
    device:set_field("controller_profile", CONTROLLER_PROFILE, { persist = true })
  end
  schedule_poll(driver, device, 2)
end

local function device_added(driver, device)
  if is_child(device) then
    local kind = child_kind(device)
    if kind == "zone" then
      device:emit_event(WATERING_TIME_CAP.wateringTime({ value = DEFAULT_WATERING_MINUTES, unit = "min" }))
      device:emit_event(TIME_REMAINING_CAP.timeRemaining({ value = 0, unit = "min" }))
    end
    device:emit_event(capabilities.switch.switch("off"))
    local parent = device:get_parent_device()
    if parent then
      schedule_poll(driver, parent, COMMAND_REPOLL_SECONDS)
    end
    return
  end
  device:emit_event(STATUS_CAP.status("Not set up: enter the RainMachine password in Settings"))
  device:emit_event(RAIN_DELAY_CAP.rainDelay({ value = 0, unit = "days" }))
end

local function info_changed(driver, device, event, args)
  if is_child(device) then
    return
  end
  -- New settings get an immediate try, even during a password backoff.
  device:set_field(AUTH_BACKOFF_UNTIL_FIELD, nil)
  device:set_field(FAILURES_FIELD, 0)
  schedule_poll(driver, device, 1)
end

local function device_removed(driver, device)
  if is_child(device) then
    -- Remember that the user deleted it, so polling doesn't recreate it.
    local parent = device:get_parent_device()
    if parent then
      local list = ignored(parent)
      list[device.device_network_id] = true
      parent:set_field(IGNORED_FIELD, list, { persist = true })
      log.info("RainMachine " .. tostring(device.label) .. " deleted by the user; won't recreate it until discovery is run")
    end
    return
  end
  local timer = device:get_field(POLL_TIMER_FIELD)
  if timer then
    device.thread:cancel_timer(timer)
  end
end

--- Discovery creates the first controller; run again, it clears the list of
--- deleted zone/program devices so they come back.
local function discovery_handler(driver, opts, cons)
  for _, device in ipairs(driver:get_devices()) do
    if not is_child(device) and device:get_field(IGNORED_FIELD) then
      device:set_field(IGNORED_FIELD, nil, { persist = true })
      log.info("RainMachine discovery: deleted zone/program devices will be recreated")
      schedule_poll(driver, device, 1)
    end
  end
  discovery.discovery_handler(driver, opts, cons)
end

local rainmachine_driver = Driver("rainmachine-lan", {
  discovery = discovery_handler,
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
    [WATERING_TIME_CAP.ID] = {
      [WATERING_TIME_CAP.commands.setWateringTime.NAME] = set_watering_time,
    },
    [RAIN_DELAY_CAP.ID] = {
      [RAIN_DELAY_CAP.commands.setRainDelay.NAME] = set_rain_delay,
    },
    [STOP_ALL_CAP.ID] = {
      [STOP_ALL_CAP.commands.push.NAME] = stop_all,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh,
    },
  },
})

rainmachine_driver:run()
