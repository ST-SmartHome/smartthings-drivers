local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local TuyaClient = require "tuya_client"

local POLL_TIMER_FIELD = "poll_timer"

local MODE_CAP = capabilities["aboutisland47519.skyfanMode"]
local DIRECTION_CAP = capabilities["aboutisland47519.skyfanDirection"]
local SLEEP_TIMER_CAP = capabilities["aboutisland47519.skyfanSleepTimer"]
local ADD_ANOTHER_CAP = capabilities["aboutisland47519.addAnotherFan"]
local COLOR_TEMP_CAP = capabilities["aboutisland47519.skyfanColorTemp"]

-- work_mode (DP 19) is a genuine 3-value enum on the device, not a
-- continuous Kelvin range — the physical remote controls it as a push
-- button cycling Warmwhite/Naturalwhite/Coolwhite, not a dial. Modeled as
-- a custom enum capability (matching how skyfanMode/skyfanDirection
-- already model this hardware's other discrete-state controls) instead of
-- the standard colorTemperature capability, which forced a continuous
-- slider onto hardware that doesn't have one. dps["19"] is already one of
-- these exact three strings, so no conversion is needed either direction.
local VALID_WORK_MODES = {Warmwhite = true, Naturalwhite = true, Coolwhite = true}

local function get_settings(device)
  local prefs = device.preferences or {}
  return {
    ip = prefs.ipAddress,
    local_key = prefs.localKey,
    device_id = prefs.deviceId,
    poll_interval = tonumber(prefs.pollInterval) or 30,
  }
end

-- Some physical units are sold as "Skyfan DC-no light" (confirmed via the
-- Tuya Cloud API's product_name field) — no light hardware at all, so the
-- standard profile's Light tile would just show dead controls on those.
-- User-facing preference toggle rather than a hardcoded device-ID list:
-- generalizes to any installation, not just whichever units happened to
-- be no-light ones on the driver author's own network.

local function apply_status(device, dps)
  if dps["1"] ~= nil then
    device:emit_event(capabilities.switch.switch(dps["1"] and "on" or "off"))
  end
  if dps["3"] ~= nil then
    device:emit_event(capabilities.fanSpeed.fanSpeed(dps["3"]))
  end
  if dps["2"] ~= nil then
    device:emit_event(MODE_CAP.mode({value = dps["2"]}))
  end
  if dps["8"] ~= nil then
    device:emit_event(DIRECTION_CAP.direction({value = dps["8"]}))
  end
  if dps["22"] ~= nil then
    device:emit_event(SLEEP_TIMER_CAP.countdown({value = tostring(dps["22"])}))
  end

  local light = device.profile.components.light
  if light and dps["15"] ~= nil then
    device:emit_component_event(light, capabilities.switch.switch(dps["15"] and "on" or "off"))
  end
  if light and dps["16"] ~= nil then
    local percent = math.floor((dps["16"] / 5) * 100 + 0.5)
    device:emit_component_event(light, capabilities.switchLevel.level(percent))
  end
  if light and dps["19"] ~= nil then
    local preset = VALID_WORK_MODES[dps["19"]] and dps["19"] or "Naturalwhite"
    device:emit_component_event(light, COLOR_TEMP_CAP.colorTempPreset(preset))
  end
end

--- Wrapped in pcall: an uncaught Lua error here (protocol bug, bad response
--- shape, anything) must not propagate past this function. start_polling
--- calls this synchronously before registering the recurring timer — if it
--- throws instead of returning, the timer registration line never runs and
--- polling silently never starts, permanently, until the driver restarts.
local function poll_once(driver, device)
  local ok, err = pcall(function()
    local s = get_settings(device)
    if not s.ip or not s.local_key or not s.device_id then
      log.warn("Skyfan DC device missing IP/local_key/device_id — skipping poll")
      return
    end

    local dps, query_err = TuyaClient.query_status(s.ip, s.local_key, s.device_id, 5)
    if not dps then
      log.error("Skyfan DC poll failed: " .. tostring(query_err))
      return
    end

    log.info("Skyfan DC status: " .. (require "dkjson").encode(dps))
    apply_status(device, dps)
  end)
  if not ok then
    log.error("Skyfan DC poll crashed: " .. tostring(err))
  end
end

local function start_polling(driver, device)
  local existing_timer = device:get_field(POLL_TIMER_FIELD)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
    device:set_field(POLL_TIMER_FIELD, nil)
  end

  local s = get_settings(device)
  if not s.ip or not s.local_key or not s.device_id then
    log.info("Skyfan DC device not fully configured yet — not starting poll timer")
    return
  end

  poll_once(driver, device)
  local timer = device.thread:call_on_schedule(s.poll_interval, function()
    poll_once(driver, device)
  end, "skyfan_poll")
  device:set_field(POLL_TIMER_FIELD, timer)
  log.info(string.format("Skyfan DC polling started: %s every %ds", s.ip, s.poll_interval))
end

local function send_dp(driver, device, dps, refresh_after)
  local s = get_settings(device)
  if not s.ip or not s.local_key or not s.device_id then
    log.warn("Skyfan DC command attempted before device is fully configured")
    return
  end
  -- 2026-08-19: tested a longer write timeout here (10s vs the 5s reads
  -- use) on the theory that acking a control command needs more time than
  -- acking a status query, since one device was reliably timing out on
  -- every write while its reads succeeded. Disproven: writes still failed
  -- identically at the full 10s mark, same "header receive failed:
  -- timeout" — not a slow-ack issue, no response arrives at all either
  -- way. Reverted to 5s; don't retry this fix without new information.
  local ok, err = TuyaClient.set_dps(s.ip, s.local_key, s.device_id, dps, 5)
  if not ok then
    log.error("Skyfan DC set_dps failed: " .. tostring(err))
    return
  end
  if refresh_after then
    poll_once(driver, device)
  end
end

-- ===== Lifecycle =====

-- Four profiles now, one per (light x add-fan-button) combination — the
-- with-light/with-addfan and no-light/with-addfan names are unchanged
-- from before this feature existed, so no already-deployed device moves
-- unless its preferences actually change.
local WITH_LIGHT_PROFILE = "skyfan-dc.v6"
local NO_LIGHT_PROFILE = "skyfan-dc-no-light.v1"
local NO_ADDFAN_PROFILE = "skyfan-dc-no-addfan.v1"
local NO_LIGHT_NO_ADDFAN_PROFILE = "skyfan-dc-no-light-no-addfan.v1"

--- Which profile a device should be on right now, given its currently-saved
--- noLight/hideAddFan preferences. Defaults to the original with-light,
--- with-add-fan-button profile — the same default this driver has always
--- used — unless the user has explicitly opted a given tile away.
local function profile_for(device)
  local prefs = device.preferences or {}
  if prefs.noLight and prefs.hideAddFan then
    return NO_LIGHT_NO_ADDFAN_PROFILE
  elseif prefs.noLight then
    return NO_LIGHT_PROFILE
  elseif prefs.hideAddFan then
    return NO_ADDFAN_PROFILE
  end
  return WITH_LIGHT_PROFILE
end

local ACTIVE_PROFILE_FIELD = "active_profile"

-- device.profile.id IS a real, comparable UUID (not the profile name
-- string) — these are this driver's actual current deviceIntegrationProfile
-- UUIDs, confirmed directly via the REST API. Comparing device.profile.id
-- against a NAME string is always true and unsafe (see
-- smartthings-edge-driver-gotchas memory) — but comparing it against its
-- own real UUID is meaningful and is the only reliable source of truth for
-- what profile a device is *actually* on right now.
local WITH_LIGHT_PROFILE_ID = "07f4d74f-0463-378c-9796-87cd62302025"
local NO_LIGHT_PROFILE_ID = "ea46b612-81c6-30d6-a1d4-c2dd0c3f7b10"
local NO_ADDFAN_PROFILE_ID = "13d30ff3-d727-3988-b1ef-e761a6744bbf"
local NO_LIGHT_NO_ADDFAN_PROFILE_ID = "66f2e67d-4d23-34a3-8324-7aff58002d30"

local PROFILE_TO_ID = {
  [WITH_LIGHT_PROFILE] = WITH_LIGHT_PROFILE_ID,
  [NO_LIGHT_PROFILE] = NO_LIGHT_PROFILE_ID,
  [NO_ADDFAN_PROFILE] = NO_ADDFAN_PROFILE_ID,
  [NO_LIGHT_NO_ADDFAN_PROFILE] = NO_LIGHT_NO_ADDFAN_PROFILE_ID,
}

-- 2026-08-20: found live that a device's persisted ACTIVE_PROFILE_FIELD
-- can silently desync from its actual cloud-side profile — a driver
-- repackage/reinstall reverted a device's real assigned profile back to
-- the package's default (with-light) even though this driver's own
-- persisted field still said "already switched to no-light", so the
-- old field-only check saw no mismatch and never re-asserted. Now
-- checks device.profile.id (the live, real UUID) directly instead of
-- trusting the persisted field alone — that field is still used to
-- avoid a redundant identical call to try_update_metadata within the
-- same restart, but it is never the sole reason to skip a switch.
-- Still only ever called from device_init (fires once per driver
-- restart) — see the info_changed history below for why that matters.
--
-- Historical note, still true: comparing device.profile.id against a
-- profile NAME string (not a UUID) is always true and was harmless only
-- because this whole function used to run infrequently — it stopped
-- being harmless once it also ran on every info_changed (every single
-- preference save): it re-requested the same already-correct profile
-- switch on every save, and the app surfaced that as a repeating
-- "capabilities changed, leave and come back" dialog. A second, worse
-- failure mode followed: try_update_metadata itself appears to trigger
-- a new info_changed as a side effect of a genuine profile change,
-- causing an infinite ~5s oscillation between the two profiles. Real
-- fix: this function must only ever be called from device_init.
-- 2026-08-21 CORRECTION: the previous version of this function added an
-- "already_requested == target -> skip" guard, reasoning it would avoid a
-- redundant try_update_metadata call "within one device_init". That
-- reasoning was wrong: ACTIVE_PROFILE_FIELD is a *persisted* field, so it
-- survives across restarts — and this function has exactly one call site
-- (device_init, which itself fires exactly once per restart), so there
-- was never a real risk of a same-restart double-call to guard against in
-- the first place. What that guard actually did in practice: the first
-- time a switch attempt didn't visibly take effect (confirmed happening —
-- device.profile.id stayed on the old profile across three separate
-- redeploys), every subsequent restart saw already_requested == target and
-- silently gave up retrying forever, only logging a warning. Removed
-- entirely — now always retries try_update_metadata on every device_init
-- where the live profile doesn't match, which is safe precisely because
-- device_init can't fire more than once per restart.
local function ensure_correct_profile(device)
  local target = profile_for(device)
  local target_id = PROFILE_TO_ID[target]

  if device.profile.id == target_id then
    -- Live cloud-side profile already matches — nothing to do, and
    -- resync the persisted field in case it was the stale one.
    if device:get_field(ACTIVE_PROFILE_FIELD) ~= target then
      device:set_field(ACTIVE_PROFILE_FIELD, target, { persist = true })
    end
    return
  end

  log.info("Skyfan DC switching device to profile " .. target
    .. " (live profile.id " .. tostring(device.profile.id)
    .. " expected " .. tostring(target_id) .. ")")
  device:try_update_metadata({ profile = target })
  device:set_field(ACTIVE_PROFILE_FIELD, target, { persist = true })
end

local function device_init(driver, device)
  log.info("Skyfan DC device init: " .. device.id)
  -- Also covers migrating devices provisioned under an older with-light
  -- profile name (v1 -> v2 added the "Add another fan" button) — same
  -- pattern/reasoning as the SolarEdge driver's migration, see
  -- smartthings-edge-driver-gotchas memory.
  ensure_correct_profile(device)
  start_polling(driver, device)
end

local function device_added(driver, device)
  log.info("Skyfan DC device added: " .. device.id)
end

local function info_changed(driver, device, event, args)
  log.info("Skyfan DC preferences changed")
  -- EMERGENCY FIX, 2026-08-19: do NOT call ensure_correct_profile here.
  -- device:try_update_metadata appears to itself trigger a new infoChanged
  -- lifecycle event as a side effect of the profile actually changing —
  -- confirmed live via logcat: a device oscillated between the two
  -- profiles every ~5 seconds, switch -> new infoChanged -> re-evaluate
  -- -> switch back -> new infoChanged -> forever, once this ran from here.
  -- The persisted-field fix from earlier today only prevented *identical*
  -- repeated requests; it did nothing against a genuine alternating loop
  -- like this one, because each evaluation was a real, different target.
  -- Profile correctness is now checked ONLY in device_init (fires once
  -- per driver restart, not as a side effect of anything this function
  -- does) — same frequency the pre-existing one-way migration check
  -- always used before today's no-light feature existed, which never hit
  -- this failure mode. Tradeoff: a noLight preference change now needs a
  -- driver restart to take effect, not an instant switch on save. Don't
  -- re-add this call without a real mechanism to detect "was this
  -- infoChanged caused by our own try_update_metadata" first.
  start_polling(driver, device)
end

local function device_removed(driver, device)
  local existing_timer = device:get_field(POLL_TIMER_FIELD)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
  end
  log.info("Skyfan DC device removed: " .. device.id)
end

-- ===== Capability commands =====

local function switch_on(driver, device, command)
  if command.component == "light" then
    send_dp(driver, device, {["15"] = true}, true)
  else
    send_dp(driver, device, {["1"] = true}, true)
  end
end

local function switch_off(driver, device, command)
  if command.component == "light" then
    send_dp(driver, device, {["15"] = false}, true)
  else
    send_dp(driver, device, {["1"] = false}, true)
  end
end

local function set_fan_speed(driver, device, command)
  local speed = math.max(1, math.min(5, math.floor(command.args.speed)))
  send_dp(driver, device, {["3"] = speed}, true)
end

local function set_level(driver, device, command)
  local percent = math.max(0, math.min(100, command.args.level))
  local bright_value = math.max(1, math.min(5, math.floor((percent / 100) * 5 + 0.5)))
  send_dp(driver, device, {["16"] = bright_value}, true)
end

local function set_color_temp_preset(driver, device, command)
  send_dp(driver, device, {["19"] = command.args.colorTempPreset}, true)
end

local function set_mode(driver, device, command)
  send_dp(driver, device, {["2"] = command.args.mode}, true)
end

local function set_direction(driver, device, command)
  send_dp(driver, device, {["8"] = command.args.direction}, true)
end

local function set_countdown(driver, device, command)
  send_dp(driver, device, {["22"] = command.args.countdown}, true)
end

local function refresh_handler(driver, device, command)
  poll_once(driver, device)
end

local function add_another_handler(driver, device, command)
  discovery.create_another(driver)
end

-- ===== Driver =====

local skyfan_driver = Driver("skyfan-tuya-lan", {
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
    [COLOR_TEMP_CAP.ID] = {
      [COLOR_TEMP_CAP.commands.setColorTempPreset.NAME] = set_color_temp_preset,
    },
    [MODE_CAP.ID] = {
      [MODE_CAP.commands.setMode.NAME] = set_mode,
    },
    [DIRECTION_CAP.ID] = {
      [DIRECTION_CAP.commands.setDirection.NAME] = set_direction,
    },
    [SLEEP_TIMER_CAP.ID] = {
      [SLEEP_TIMER_CAP.commands.setCountdown.NAME] = set_countdown,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
    [ADD_ANOTHER_CAP.ID] = {
      [ADD_ANOTHER_CAP.commands.push.NAME] = add_another_handler,
    },
  },
})

skyfan_driver:run()
