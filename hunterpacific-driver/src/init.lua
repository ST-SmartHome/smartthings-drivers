local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"

local discovery = require "discovery"
local TuyaClient = require "tuya_client"
local socket = require "cosock.socket"

-- Hunter Pacific DC fans (Aqua DC confirmed 2026-10-10). The WiFi module is
-- Tuya product "9 Speed WiFi Remote" (agjbamgmrbcbazp7, category fsd), local
-- protocol 3.3. Transport, resilient writes and the light-child lifecycle are
-- shared with skyfan-driver; only the data points differ.
local DP = {
  FAN = "60",        -- bool
  SPEED = "62",      -- 1..9
  DIRECTION = "63",  -- "forward" / "reverse"; accepted while running
  LIGHT = "20",      -- bool
  BRIGHTNESS = "22", -- 1..9
}
local SPEED_MAX = 9
local BRIGHTNESS_MAX = 9

local POLL_TIMER_FIELD = "poll_timer"

local DIRECTION_CAP = capabilities["aboutisland47519.fanDirection"]
local ADD_ANOTHER_CAP = capabilities["aboutisland47519.addAnotherFan"]

-- The module reports the light data points whether or not a light kit is
-- fitted, so a light can't be detected. The light child exists only when
-- the user turns on Light Kit Fitted.
local LIGHT_CHILD_DNI_SUFFIX = "-light"
local LIGHT_CHILD_PROFILE = "hunterpacific-light-child.v1"

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

local function level_to_percent(value)
  return math.floor((value / BRIGHTNESS_MAX) * 100 + 0.5)
end

local function apply_fan_status(device, dps)
  if dps[DP.FAN] ~= nil then
    device:emit_event(capabilities.switch.switch(dps[DP.FAN] and "on" or "off"))
  end
  -- Off shows as speed 0 ("Off" on the slider); the fan keeps its last
  -- speed in DP 62 while off.
  if dps[DP.FAN] == false then
    device:emit_event(capabilities.fanSpeed.fanSpeed(0))
  elseif dps[DP.SPEED] ~= nil then
    device:emit_event(capabilities.fanSpeed.fanSpeed(dps[DP.SPEED]))
  end
  if dps[DP.DIRECTION] ~= nil then
    device:emit_event(DIRECTION_CAP.direction({ value = dps[DP.DIRECTION] == "reverse" and "Reverse" or "Forward" }))
  end
end

--- Only light children carry light state; the fan device never has a
--- light component.
local function apply_light_status(device, dps)
  if not is_light_child(device) then
    return
  end
  if dps[DP.LIGHT] ~= nil then
    device:emit_event(capabilities.switch.switch(dps[DP.LIGHT] and "on" or "off"))
  end
  if dps[DP.BRIGHTNESS] ~= nil then
    device:emit_event(capabilities.switchLevel.level(level_to_percent(dps[DP.BRIGHTNESS])))
  end
end

local after_successful_poll

-- ===== Connection health (2026-10-10) =====
-- A wrong local key still reaches the fan, but its reply can't be decoded.
-- That case marks the device offline at once and backs off to one try every
-- KEY_BACKOFF_SECONDS until the user saves new settings (info_changed clears
-- the backoff). Plain network failures mark it offline only after
-- OFFLINE_AFTER_FAILURES polls in a row, since single resets are routine.
local KEY_BACKOFF_SECONDS = 300
local OFFLINE_AFTER_FAILURES = 3
local KEY_BACKOFF_UNTIL_FIELD = "key_backoff_until"
local FAILURES_FIELD = "consecutive_poll_failures"
local OFFLINE_FIELD = "marked_offline"

local KEY_ERROR_PATTERNS = { "not a table", "decrypt failed", "HMAC", "no dps field", "wrong local key" }

local function is_key_error(err)
  local text = tostring(err)
  for _, pattern in ipairs(KEY_ERROR_PATTERNS) do
    if text:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

--- Returns a description of an obviously bad setting, or nil.
local function settings_problem(s)
  if s.local_key == "0000000000000000" or s.device_id == "00000000000000000000" then
    return "Local Key or Device ID is still the placeholder"
  end
  if s.local_key:find("[\128-\255]") then
    return "Local Key contains a non-ASCII character (often a curly quote or dash inserted by the phone keyboard); paste it again"
  end
  if #s.local_key ~= 16 then
    return "Local Key is " .. #s.local_key .. " bytes, not 16"
  end
  return nil
end

local function mark_offline(device, reason)
  if not device:get_field(OFFLINE_FIELD) then
    device:offline()
    device:set_field(OFFLINE_FIELD, true)
  end
  log.error("Hunter Pacific " .. tostring(device.label) .. " offline: " .. reason)
end

local function mark_online(device)
  device:set_field(FAILURES_FIELD, 0)
  device:set_field(KEY_BACKOFF_UNTIL_FIELD, nil)
  if device:get_field(OFFLINE_FIELD) then
    device:online()
    device:set_field(OFFLINE_FIELD, false)
    log.info("Hunter Pacific " .. tostring(device.label) .. " back online")
  end
end

local function record_failure(device, err)
  if is_key_error(err) then
    device:set_field(KEY_BACKOFF_UNTIL_FIELD, os.time() + KEY_BACKOFF_SECONDS)
    mark_offline(device, "the fan answered but its reply can't be decoded. Check the Local Key and Device ID ("
      .. tostring(err) .. "). Retrying every " .. KEY_BACKOFF_SECONDS .. " s until the settings change")
    return
  end
  local failures = (device:get_field(FAILURES_FIELD) or 0) + 1
  device:set_field(FAILURES_FIELD, failures)
  if failures >= OFFLINE_AFTER_FAILURES then
    mark_offline(device, failures .. " polls in a row failed: " .. tostring(err) .. ". Check the IP address and that the fan has power")
  end
end

local function poll_once(driver, device)
  local ok, err = pcall(function()
    if is_light_child(device) then
      return
    end
    local s = get_settings(device)
    if not s.ip or not s.local_key or not s.device_id then
      log.warn("Hunter Pacific device missing IP/local_key/device_id — skipping poll")
      return
    end
    local problem = settings_problem(s)
    if problem then
      mark_offline(device, problem)
      return
    end
    local backoff_until = device:get_field(KEY_BACKOFF_UNTIL_FIELD)
    if backoff_until and os.time() < backoff_until then
      return
    end

    local dps, query_err = TuyaClient.query_status(s.ip, s.local_key, s.device_id, 5)
    if not dps and not is_key_error(query_err) then
      -- 2026-09-25: some fans reset the first connection after an idle
      -- gap but accept one made moments later (reproduced off-hub: RST,
      -- then OK 0.5s later), so retry once.
      log.warn("Hunter Pacific poll attempt 1 failed (" .. tostring(device.label) .. "): " .. tostring(query_err))
      socket.sleep(0.75)
      dps, query_err = TuyaClient.query_status(s.ip, s.local_key, s.device_id, 5)
    end
    if not dps then
      record_failure(device, query_err)
      return
    end
    mark_online(device)

    log.info("Hunter Pacific status: " .. (require "dkjson").encode(dps))
    apply_fan_status(device, dps)
    apply_light_status(device, dps)

    -- If a light-child has been created for this fan, push the same
    -- fresh dps to it too — one query, two devices updated.
    local child = find_light_child(driver, device)
    if child then
      apply_light_status(child, dps)
    end

    if after_successful_poll then
      after_successful_poll(driver, device, dps)
    end
  end)
  if not ok then
    log.error("Hunter Pacific poll crashed: " .. tostring(err))
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
    log.info("Hunter Pacific device not fully configured yet — not starting poll timer")
    return
  end

  poll_once(driver, device)
  local timer = device.thread:call_on_schedule(s.poll_interval, function()
    poll_once(driver, device)
  end, "hunterpacific_poll")
  device:set_field(POLL_TIMER_FIELD, timer)
  log.info(string.format("Hunter Pacific polling started (%s): %s every %ds", tostring(device.label), s.ip, s.poll_interval))
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

-- ===== Resilient writes (2026-09-25) =====
--
-- Measured 2026-09-25: with no commands being sent at all, about 27% of
-- status queries across the fleet failed with "Connection reset by peer"
-- (13 of 48 in a 3-minute window, spread over at least 5 fans). A write
-- goes over the same one-shot connection, and send_dp used to send once
-- and give up, so roughly one command in four could be silently lost --
-- e.g. an Alexa group "turn off the lights" reaching only one of two fans.
--
-- Every write now:
--   * runs on the physical fan's (parent's) device thread, so a light
--     child's command can't open a second connection to the same fan
--     while the parent's poll or another command is using it (these Tuya
--     modules only handle one local connection at a time);
--   * retries transport failures with jittered backoff;
--   * reads the state back and resends only if a successful read shows
--     the wrong value (a failed read is retried, never treated as a
--     mismatch);
--   * gives up early if a newer command for the same DP has been issued
--     since ("latest value wins"), so a retry can never undo a newer
--     command such as an Alexa "off" arriving during an "on" retry;
--   * emits state from the verification read, so no extra refresh
--     connection is opened.
local WRITE_MAX_ATTEMPTS = 4
local WRITE_DEADLINE_SECONDS = 25
local VERIFY_DELAY_SECONDS = 0.7
local QUERY_MAX_ATTEMPTS = 3

-- desired_dps[parent_device_id][dp] = sequence number of the newest
-- command for that DP. Recorded when the command arrives, before it is
-- queued, so a queued or in-flight older write can see it is stale.
local desired_dps = {}
local write_sequence = 0

local function backoff(attempt)
  socket.sleep(attempt * 0.8 + math.random() * 0.6)
end

--- Normalizes a DP value for comparison: booleans stay booleans, numbers
--- stay numbers, everything else (enum strings like "forward"/"2h")
--- compares as a string.
local function normalize_dp(value)
  if type(value) == "boolean" or type(value) == "number" then
    return value
  end
  return tostring(value)
end

local function dps_match(wanted, actual)
  for dp, value in pairs(wanted) do
    if actual[dp] == nil or normalize_dp(actual[dp]) ~= normalize_dp(value) then
      return false
    end
  end
  return true
end

--- Status query with retries on transport failure. `is_current` (optional)
--- aborts early when the caller has been superseded. Returns dps or nil, err.
local function query_with_retry(s, label, is_current)
  local last_err
  for attempt = 1, QUERY_MAX_ATTEMPTS do
    if is_current and not is_current() then
      return nil, "superseded"
    end
    local dps, err = TuyaClient.query_status(s.ip, s.local_key, s.device_id, 5)
    if dps then
      return dps
    end
    last_err = err
    log.warn(string.format("Hunter Pacific query attempt %d/%d failed (%s): %s",
      attempt, QUERY_MAX_ATTEMPTS, tostring(label), tostring(err)))
    if attempt < QUERY_MAX_ATTEMPTS then
      backoff(attempt)
    end
  end
  return nil, last_err
end

--- Write with retries on transport failure only (no read-back); used by the
--- direction interlock, which does its own state verification.
local function set_dps_with_retry(s, dps, label, is_current)
  local last_err
  for attempt = 1, WRITE_MAX_ATTEMPTS do
    if is_current and not is_current() then
      return nil, "superseded"
    end
    local ok, err = TuyaClient.set_dps(s.ip, s.local_key, s.device_id, dps, 5)
    if ok then
      return true
    end
    last_err = err
    log.warn(string.format("Hunter Pacific write attempt %d/%d failed (%s): %s",
      attempt, WRITE_MAX_ATTEMPTS, tostring(label), tostring(err)))
    if attempt < WRITE_MAX_ATTEMPTS then
      backoff(attempt)
    end
  end
  return nil, last_err
end

--- Pushes one query's dps to the fan, its light component and its light
--- child -- the same fan-out poll_once does.
local function apply_all_status(driver, parent, dps)
  apply_fan_status(parent, dps)
  apply_light_status(parent, dps)
  local child = find_light_child(driver, parent)
  if child then
    apply_light_status(child, dps)
  end
end

--- `opts` (optional): { deadline = seconds, attempts = n } overrides the
--- write retry window.
local function send_dp(driver, device, dps, refresh_after, opts)
  local s = get_settings(device)
  if not s.ip or not s.local_key or not s.device_id then
    log.warn("Hunter Pacific command attempted before device is fully configured (" .. tostring(device.label) .. ")")
    return
  end
  local parent = device
  if is_light_child(device) then
    parent = device:get_parent_device()
    if not parent then
      log.warn("Hunter Pacific light command has no parent fan (" .. tostring(device.label) .. ")")
      return
    end
  end
  local label = tostring(parent.label)

  write_sequence = write_sequence + 1
  local seq = write_sequence
  local desired = desired_dps[parent.id] or {}
  desired_dps[parent.id] = desired
  for dp, _ in pairs(dps) do
    desired[dp] = seq
  end
  local function is_current()
    for dp, _ in pairs(dps) do
      if desired[dp] ~= seq then
        return false
      end
    end
    return true
  end
  local wanted = (require "dkjson").encode(dps)

  parent.thread:queue_event(function()
    local ok, err = pcall(function()
      local deadline = os.time() + ((opts and opts.deadline) or WRITE_DEADLINE_SECONDS)
      local max_attempts = (opts and opts.attempts) or WRITE_MAX_ATTEMPTS
      for attempt = 1, max_attempts do
        if not is_current() then
          log.info(string.format("Hunter Pacific write %s superseded by a newer command (%s)", wanted, label))
          return
        end
        local sent, send_err = TuyaClient.set_dps(s.ip, s.local_key, s.device_id, dps, 5)
        if sent then
          socket.sleep(VERIFY_DELAY_SECONDS)
          local status, query_err = query_with_retry(s, label, is_current)
          if status then
            apply_all_status(driver, parent, status)
            if dps_match(dps, status) then
              log.info(string.format("Hunter Pacific write %s verified on attempt %d (%s)", wanted, attempt, label))
              return
            end
            log.warn(string.format("Hunter Pacific write %s not applied (read back %s), attempt %d/%d (%s)",
              wanted, (require "dkjson").encode(status), attempt, max_attempts, label))
          elseif query_err == "superseded" then
            log.info(string.format("Hunter Pacific write %s superseded during verification (%s)", wanted, label))
            return
          else
            log.warn(string.format("Hunter Pacific write %s sent but could not be verified (%s): %s",
              wanted, label, tostring(query_err)))
            return
          end
        else
          log.warn(string.format("Hunter Pacific write %s attempt %d/%d failed (%s): %s",
            wanted, attempt, max_attempts, label, tostring(send_err)))
        end
        if attempt < max_attempts then
          if os.time() >= deadline then
            break
          end
          backoff(attempt)
        end
      end
      log.error(string.format("Hunter Pacific write %s gave up after %d attempts (%s)", wanted, max_attempts, label))
    end)
    if not ok then
      log.error("Hunter Pacific write crashed (" .. label .. "): " .. tostring(err))
    end
  end)
end

-- ===== Lifecycle =====

local WITH_ADDFAN_PROFILE = "hunterpacific-fan.v3"
local NO_ADDFAN_PROFILE = "hunterpacific-fan-no-addfan.v3"

local function profile_for(device)
  local prefs = device.preferences or {}
  if prefs.hideAddFan then
    return NO_ADDFAN_PROFILE
  end
  return WITH_ADDFAN_PROFILE
end

local ACTIVE_PROFILE_FIELD = "active_profile"

-- v3 (2026-10-10): metadata.vid gives the speed slider Off + 1-9 labels
-- (the stock fanSpeed UI ignores the profile range, as on BAF). The profile
-- must NOT also embed a fanSpeed config: range, or the platform generates
-- its own vid and ignores ours (v2 did exactly that).
-- device.profile.id is the DeviceProfile UUID, not the name. Fill these in
-- from the packaged profiles; a renamed profile gets a new UUID. While a
-- UUID is unknown (nil), the persisted field is used instead.
local PROFILE_TO_ID = {
  [WITH_ADDFAN_PROFILE] = "e2bd826d-1f6d-3630-a720-4d8209bb8fca",
  [NO_ADDFAN_PROFILE] = "5a0a1fc1-3ea4-38c9-b58a-2be9f274eb46",
}

--- Called from device_init and from info_changed only when the user
--- changed hideAddFan (our own try_update_metadata never changes a
--- preference, so it can't loop).
local function ensure_correct_profile(driver, device)
  local target = profile_for(device)
  local target_id = PROFILE_TO_ID[target]
  local matches
  if target_id then
    matches = device.profile.id == target_id
  else
    matches = device:get_field(ACTIVE_PROFILE_FIELD) == target
  end
  if matches then
    if device:get_field(ACTIVE_PROFILE_FIELD) ~= target then
      device:set_field(ACTIVE_PROFILE_FIELD, target, { persist = true })
    end
    return
  end
  log.info("Hunter Pacific switching " .. tostring(device.label) .. " to profile " .. target
    .. " (live profile.id " .. tostring(device.profile.id) .. ")")
  device:try_update_metadata({ profile = target })
  device:set_field(ACTIVE_PROFILE_FIELD, target, { persist = true })
end

-- Light child: created only when Light Kit Fitted is on and a successful
-- poll has returned the light DP; deleted when the user turns it off.
local LIGHT_CHILD_REQUESTED_FIELD = "light_child_requested_at"

local function ensure_light_child(driver, device, dps)
  if is_light_child(device) then
    return
  end
  if not (device.preferences and device.preferences.lightFitted) then
    return
  end
  if find_light_child(driver, device) or dps[DP.LIGHT] == nil then
    return
  end
  -- Creation is asynchronous; don't re-request on every poll meanwhile.
  local last = device:get_field(LIGHT_CHILD_REQUESTED_FIELD)
  if last and os.time() - last < 300 then
    return
  end
  device:set_field(LIGHT_CHILD_REQUESTED_FIELD, os.time())
  local label = (device.label or device.id) .. " Light"
  local ok, err = driver:try_create_device({
    type = "LAN",
    device_network_id = light_child_dni(device),
    label = label,
    profile = LIGHT_CHILD_PROFILE,
    manufacturer = "Hunter Pacific",
    model = "DC Fan (light)",
    vendor_provided_label = label,
    parent_device_id = device.id,
  })
  if not ok and not tostring(err):find("DNI already exists") then
    log.error("Hunter Pacific failed to create light device for " .. device.id .. ": " .. tostring(err))
  else
    log.info("Hunter Pacific requested light device creation for " .. device.id)
  end
end

after_successful_poll = ensure_light_child

--- Removes this fan's light device. Called only when the user turns No Physical Light on.
local function delete_light_child(driver, device)
  local child = find_light_child(driver, device)
  if not child then
    return
  end
  if type(driver.try_delete_device) == "function" then
    local ok, err = pcall(driver.try_delete_device, driver, child.id)
    log.info("Hunter Pacific Light Kit Fitted is off: deleting " .. tostring(child.label)
      .. " (" .. tostring(ok) .. (err and (", " .. tostring(err)) or "") .. ")")
  else
    local names = {}
    for _, t in ipairs({ driver, getmetatable(driver) and getmetatable(driver).__index or {} }) do
      if type(t) == "table" then
        for k in pairs(t) do
          if tostring(k):lower():find("delete") or tostring(k):lower():find("remove") then
            names[#names + 1] = tostring(k)
          end
        end
      end
    end
    log.warn("Hunter Pacific Light Kit Fitted is off, but this hub has no try_delete_device; delete "
      .. tostring(child.label) .. " manually. Delete/remove functions available: " .. table.concat(names, ", "))
  end
end


local function device_init(driver, device)
  log.info("Hunter Pacific device init: " .. device.id)
  if is_light_child(device) then
    return
  end
  ensure_correct_profile(driver, device)
  log.info("Hunter Pacific prefs for " .. tostring(device.label) .. ": lightFitted=" .. tostring(device.preferences and device.preferences.lightFitted)
    .. " hideAddFan=" .. tostring(device.preferences and device.preferences.hideAddFan)
    .. " light child=" .. tostring(find_light_child(driver, device) ~= nil))
  start_polling(driver, device)
end

local function device_added(driver, device)
  log.info("Hunter Pacific device added: " .. device.id)
end

local function info_changed(driver, device, event, args)
  -- New settings get an immediate try, even during a wrong-key backoff.
  device:set_field(KEY_BACKOFF_UNTIL_FIELD, nil)
  device:set_field(FAILURES_FIELD, 0)
  local old = args and args.old_st_store and args.old_st_store.preferences
  if old and not is_light_child(device) then
    if old.hideAddFan ~= device.preferences.hideAddFan then
      ensure_correct_profile(driver, device)
    end
    if old.lightFitted and not device.preferences.lightFitted then
      delete_light_child(driver, device)
    elseif device.preferences.lightFitted and not old.lightFitted then
      device:set_field(LIGHT_CHILD_REQUESTED_FIELD, nil)
    end
  end
  start_polling(driver, device)
end

local function device_removed(driver, device)
  local existing_timer = device:get_field(POLL_TIMER_FIELD)
  if existing_timer then
    device.thread:cancel_timer(existing_timer)
  end
  log.info("Hunter Pacific device removed: " .. device.id)
end

-- ===== Capability commands =====

local function switch_on(driver, device, command)
  send_dp(driver, device, { [is_light_child(device) and DP.LIGHT or DP.FAN] = true }, true)
end

local function switch_off(driver, device, command)
  send_dp(driver, device, { [is_light_child(device) and DP.LIGHT or DP.FAN] = false }, true)
end

--- Speed 0 turns the fan off; any other speed also turns it on.
local function set_fan_speed(driver, device, command)
  local speed = math.floor(tonumber(command.args.speed) or 0)
  if speed <= 0 then
    send_dp(driver, device, { [DP.FAN] = false }, true)
    return
  end
  send_dp(driver, device, { [DP.FAN] = true, [DP.SPEED] = math.min(SPEED_MAX, speed) }, true)
end

--- 0 % turns the light off (the module's minimum brightness is 1).
local function set_level(driver, device, command)
  local percent = math.max(0, math.min(100, command.args.level))
  if percent == 0 then
    send_dp(driver, device, { [DP.LIGHT] = false }, true)
    return
  end
  local value = math.max(1, math.min(BRIGHTNESS_MAX, math.floor((percent / 100) * BRIGHTNESS_MAX + 0.5)))
  send_dp(driver, device, { [DP.LIGHT] = true, [DP.BRIGHTNESS] = value }, true)
end

--- Confirmed 2026-10-10: the fan slows, stops and reverses by itself, so
--- no stop-first interlock (unlike Skyfan). It rejects a second direction
--- command for ~20 s while reversing (speed changes are accepted), so
--- direction writes keep retrying for up to 45 s; a quick change of mind
--- lands once the reversal finishes.
local DIRECTION_WRITE = { deadline = 45, attempts = 8 }

local function set_direction(driver, device, command)
  local value = command.args.direction == "Reverse" and "reverse" or "forward"
  send_dp(driver, device, { [DP.DIRECTION] = value }, true, DIRECTION_WRITE)
end

local function refresh_handler(driver, device, command)
  refresh_after_command(driver, device)
end

local function add_another_handler(driver, device, command)
  discovery.create_another(driver)
end

-- ===== Driver =====

local hunter_driver = Driver("hunterpacific-tuya-lan", {
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
    [DIRECTION_CAP.ID] = {
      [DIRECTION_CAP.commands.setDirection.NAME] = set_direction,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
    [ADD_ANOTHER_CAP.ID] = {
      [ADD_ANOTHER_CAP.commands.push.NAME] = add_another_handler,
    },
  },
})

hunter_driver:run()
