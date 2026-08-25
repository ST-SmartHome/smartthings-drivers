local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local TuyaClient = require "tuya_client"

local POLL_TIMER_FIELD = "poll_timer"

local MODE_CAP = capabilities["examplens.skyfanMode"]
local DIRECTION_CAP = capabilities["examplens.skyfanDirection"]
local SLEEP_TIMER_CAP = capabilities["examplens.skyfanSleepTimer"]
local ADD_ANOTHER_CAP = capabilities["examplens.addAnotherFan"]
local COLOR_TEMP_CAP = capabilities["examplens.skyfanColorTemp"]

-- work_mode (DP 19) is a genuine 3-value enum on the device, not a
-- continuous Kelvin range — the physical remote controls it as a push
-- button cycling Warmwhite/Naturalwhite/Coolwhite, not a dial. Modeled as
-- a custom enum capability (matching how skyfanMode/skyfanDirection
-- already model this hardware's other discrete-state controls) instead of
-- the standard colorTemperature capability, which forced a continuous
-- slider onto hardware that doesn't have one. dps["19"] is already one of
-- these exact three strings, so no conversion is needed either direction.
local VALID_WORK_MODES = {Warmwhite = true, Naturalwhite = true, Coolwhite = true}

-- ===== Light child devices (2026-08-25) =====
--
-- Ported from bigassfans-driver, where this is already confirmed working
-- end-to-end (Alexa's SmartThings integration discovers by *device*, not
-- by component — a fan's `light` component never showed up as its own
-- Alexa entity, only `main` did). Same design, adapted to this driver's
-- Tuya DPS protocol instead of BAF's i6 protocol:
--
-- Identity is a plain device_network_id suffix, NOT device.profile.id —
-- a profile-id check would misidentify every device as "not a child" on
-- first boot (the profile UUID isn't known/hardcoded yet). Real fan DNIs
-- here (`skyfan-dc-tuya-1`, `skyfan-dc-tuya-<timestamp>-<random>` from
-- "Add another fan") never end in "-light", so there's no collision risk.
--
-- Piloted on one real fan first before being made automatic here for
-- every fan with a physical light, including ones
-- added in the future — confirmed working end-to-end on this driver's
-- own Tuya/DPS write path specifically, not just carried over from
-- bigassfans-driver's confirmation. See skyfan-driver-project-status
-- memory for the pilot's test results.
local LIGHT_CHILD_DNI_SUFFIX = "-light"
local LIGHT_CHILD_PROFILE = "skyfan-light-child.v1"

local function light_child_dni(parent)
  return parent.device_network_id .. LIGHT_CHILD_DNI_SUFFIX
end

--- True only for a light-child device this driver itself created.
local function is_light_child(device)
  return device.device_network_id ~= nil
    and device.device_network_id:sub(-#LIGHT_CHILD_DNI_SUFFIX) == LIGHT_CHILD_DNI_SUFFIX
end

--- Finds a parent's already-created light-child device by scanning the
--- driver's known devices for the expected DNI — observed live state,
--- not a persisted "we already did this" flag (this project's own
--- history: install/redeploy reporting success is not proof the driver
--- process actually restarted, let alone that a requested device
--- creation landed).
local function find_light_child(driver, parent)
  local expected_dni = light_child_dni(parent)
  for _, d in pairs(driver:get_devices()) do
    if d.device_network_id == expected_dni then
      return d
    end
  end
  return nil
end

--- A light-child device has no ipAddress/localKey/deviceId preferences of
--- its own (its profile doesn't declare them) — falls back to whatever
--- its parent resolves to, recursively (one level in practice, since a
--- child never spawns its own child). Safe to call device:get_parent_device()
--- here: unlike the added/init lifecycle events the SDK docs warn about,
--- this only ever runs from a capability command handler or the poll
--- path, neither of which is added/init.
local function get_settings(device)
  if is_light_child(device) then
    local parent = device:get_parent_device()
    if not parent then
      return {}
    end
    return get_settings(parent)
  end
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

local function apply_fan_status(device, dps)
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
end

--- Handles three cases uniformly, same pattern as bigassfans-driver's
--- equivalent function: (1) a light-child device — emits directly on its
--- own (only) "main" component; (2) a not-yet-split device that still has
--- a `light` component in its active profile — emits there, unchanged
--- from before; (3) a split/no-light device with neither — safely
--- no-ops. Reused for both the parent (called from poll_once with its
--- own light component) and a light child (called from poll_once with
--- the same fresh dps).
local function apply_light_status(device, dps)
  if is_light_child(device) then
    if dps["15"] ~= nil then
      device:emit_event(capabilities.switch.switch(dps["15"] and "on" or "off"))
    end
    if dps["16"] ~= nil then
      local percent = math.floor((dps["16"] / 5) * 100 + 0.5)
      device:emit_event(capabilities.switchLevel.level(percent))
    end
    if dps["19"] ~= nil then
      local preset = VALID_WORK_MODES[dps["19"]] and dps["19"] or "Naturalwhite"
      device:emit_event(COLOR_TEMP_CAP.colorTempPreset(preset))
    end
    return
  end

  local light = device.profile.components.light
  if not light then
    return
  end
  if dps["15"] ~= nil then
    device:emit_component_event(light, capabilities.switch.switch(dps["15"] and "on" or "off"))
  end
  if dps["16"] ~= nil then
    local percent = math.floor((dps["16"] / 5) * 100 + 0.5)
    device:emit_component_event(light, capabilities.switchLevel.level(percent))
  end
  if dps["19"] ~= nil then
    local preset = VALID_WORK_MODES[dps["19"]] and dps["19"] or "Naturalwhite"
    device:emit_component_event(light, COLOR_TEMP_CAP.colorTempPreset(preset))
  end
end

--- Wrapped in pcall: an uncaught Lua error here (protocol bug, bad response
--- shape, anything) must not propagate past this function. start_polling
--- calls this synchronously before registering the recurring timer — if it
--- throws instead of returning, the timer registration line never runs and
--- polling silently never starts, permanently, until the driver restarts.
--- Only ever called on a parent (fan) device — a light-child has no
--- polling timer of its own (see start_polling/device_init) and gets its
--- state exclusively from the parent's own poll cycle below, so this
--- stays one TCP connection per cycle per physical fan either way.
local function poll_once(driver, device)
  local ok, err = pcall(function()
    if is_light_child(device) then
      return
    end
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
    apply_fan_status(device, dps)
    apply_light_status(device, dps)

    -- If a light-child has been created for this fan, push the same
    -- fresh dps to it too — one query, two devices updated.
    local child = find_light_child(driver, device)
    if child then
      apply_light_status(child, dps)
    end
  end)
  if not ok then
    log.error("Skyfan DC poll crashed: " .. tostring(err))
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

--- poll_once is a no-op when called directly on a light-child (it has no
--- polling loop of its own — see poll_once/start_polling above), so a
--- command's post-write refresh needs redirecting to the parent's
--- poll_once instead, or a command sent to the child would silently
--- never show its own result. get_parent_device() is safe here: this
--- only ever runs from a capability command handler, not added/init.
local function refresh_after_command(driver, device)
  if is_light_child(device) then
    local parent = device:get_parent_device()
    if parent then
      poll_once(driver, parent)
    end
    return
  end
  poll_once(driver, device)
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
    refresh_after_command(driver, device)
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
--- has_light_child is computed by the caller via find_light_child
--- (observed live state) — once a light-child device is confirmed to
--- actually exist, this device is treated as noLight regardless of that
--- preference's raw value, since its light is now controlled through the
--- child instead. Deliberately does NOT write the noLight preference
--- itself (no preference-write path exists — see
--- smartthings-edge-driver-gotchas memory); this only affects which
--- profile ensure_correct_profile picks.
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
--- Only ever called for a parent (fan) device — a light-child always has
--- exactly one profile (LIGHT_CHILD_PROFILE) and never switches, so it's
--- routed away from this in device_init before it would get here.
local function ensure_correct_profile(driver, device)
  local has_light_child = find_light_child(driver, device) ~= nil
  local target = profile_for(device, has_light_child)
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

--- Creates a light-child device for this fan — automatic for every fan
--- with a physical light (confirmed working end-to-end via a real pilot
--- fan, see skyfan-driver-project-status memory), skipped
--- for a noLight device (nothing to split off) or if called on a child
--- itself. Idempotent via find_light_child (observed state), so safe to
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
    return
  end
  if device.preferences and device.preferences.noLight then
    return
  end
  if find_light_child(driver, device) then
    return
  end
  local label = (device.label or device.id) .. " Light"
  local ok, err = driver:try_create_device({
    type = "LAN",
    device_network_id = light_child_dni(device),
    label = label,
    profile = LIGHT_CHILD_PROFILE,
    manufacturer = "Ventair",
    model = "Skyfan DC (light)",
    vendor_provided_label = label,
    parent_device_id = device.id,
  })
  if not ok and not tostring(err):find("DNI already exists") then
    log.error("Skyfan DC failed to create light-child device for " .. device.id .. ": " .. tostring(err))
  else
    log.info("Skyfan DC requested light-child device creation for " .. device.id)
  end
end

local function device_init(driver, device)
  log.info("Skyfan DC device init: " .. device.id)
  if is_light_child(device) then
    -- No profile-switch logic (always LIGHT_CHILD_PROFILE, never
    -- changes) and no polling timer of its own — state comes entirely
    -- from the parent's own poll cycle. See start_polling/poll_once.
    return
  end
  -- Also covers migrating devices provisioned under an older with-light
  -- profile name (v1 -> v2 added the "Add another fan" button) — same
  -- pattern/reasoning as the SolarEdge driver's migration, see
  -- smartthings-edge-driver-gotchas memory.
  ensure_correct_profile(driver, device)
  ensure_light_child(driver, device)
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

--- command.component == "light" covers a not-yet-split device (still on
--- a profile with both main+light components); is_light_child(device)
--- covers a split device's separate light device (whose only component
--- is "main", so the component check alone would wrongly fall through to
--- the fan branch). Both checks needed side by side — devices in either
--- state can exist at once while the pilot is scoped to one fan.
local function switch_on(driver, device, command)
  if is_light_child(device) or command.component == "light" then
    send_dp(driver, device, {["15"] = true}, true)
  else
    send_dp(driver, device, {["1"] = true}, true)
  end
end

local function switch_off(driver, device, command)
  if is_light_child(device) or command.component == "light" then
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
  refresh_after_command(driver, device)
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
