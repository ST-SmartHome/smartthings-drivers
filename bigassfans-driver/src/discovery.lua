-- Two ways a BAF fan device gets created:
--
--  1. Automatic (the normal case): real mDNS discovery (see
--     discovery_mdns.lua) finds every "_api._tcp" service on the LAN
--     whose TXT "model" record looks like a Haiku/BAF fan, and creates a
--     device for each one not already known. SmartThings re-invokes
--     discovery periodically in the background for the driver's whole
--     lifetime (confirmed via logcat during the Skyfan driver's
--     development, a platform behavior, not something this driver
--     controls) — so a fan added to the network later gets picked up
--     automatically too, no manual step needed. This is NOT possible for
--     the sibling Skyfan driver: Tuya's local discovery is a proprietary
--     UDP broadcast, not mDNS, and its cloud API isn't reachable from a
--     driver at all — see smartthings-edge-driver-gotchas memory.
--
--  2. Manual fallback: the "Add another fan" button, for the rare case
--     mDNS doesn't find a fan (e.g. it's temporarily unreachable) and the
--     user wants to create the device ahead of time. It's created with no
--     known IP; the "Manual IP Override" preference lets the user point
--     it at a real address, or it self-heals automatically once mDNS
--     actually finds it (see below). Reuses the same custom capability as
--     the Skyfan driver (aboutisland47519.addAnotherFan) — capability IDs
--     are account-wide, not per-driver.
--
-- Every discovery pass also refreshes the persisted IP of already-known
-- devices whose "Manual IP Override" preference is still at its
-- 0.0.0.0/unset sentinel, if mDNS reports a current address for them —
-- this self-heals DHCP drift without user action.

local log = require "log"
local socket = require "cosock.socket"
local discovery_mdns = require "discovery_mdns"

local PROFILE = "bigassfans-h.v1"
local IP_FIELD = "ip"
local MANUAL_IP_SENTINEL = "0.0.0.0"

local Discovery = {}
Discovery.IP_FIELD = IP_FIELD
Discovery.MANUAL_IP_SENTINEL = MANUAL_IP_SENTINEL

--- Creates one device. `ip` may be nil (the manual "Add another fan"
--- path) — the device starts with no known address until a preference
--- override or a later discovery pass supplies one.
local function create_device(driver, device_network_id, label, ip)
  local metadata = {
    type = "LAN",
    device_network_id = device_network_id,
    label = label,
    profile = PROFILE,
    manufacturer = "Big Ass Fans",
    model = "Haiku H/I Series",
    vendor_provided_label = "Haiku H/I Series",
  }
  log.info("Creating BAF device (" .. device_network_id .. ") ip=" .. tostring(ip))
  driver.datastore.discovery_cache = driver.datastore.discovery_cache or {}
  driver.datastore.discovery_cache[device_network_id] = ip
  local ok, err = driver:try_create_device(metadata)
  if not ok and not tostring(err):find("DNI already exists") then
    log.error("Failed to create BAF device: " .. tostring(err))
  end
end

--- Called from device_added (see init.lua) to pull a freshly-created
--- device's discovered IP (if any) out of the driver-level cache and
--- persist it onto the device itself.
function Discovery.apply_cached_ip(driver, device)
  local cache = driver.datastore.discovery_cache
  local ip = cache and cache[device.device_network_id]
  if ip then
    device:set_field(IP_FIELD, ip, { persist = true })
    cache[device.device_network_id] = nil
  end
end

--- Called from the "Add another fan" button.
function Discovery.create_another(driver)
  local device_network_id = "bigassfans-i6-manual-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  create_device(driver, device_network_id, "BAF Fan", nil)
end

--- Runs one discovery pass: creates devices for any newly-found fan, and
--- self-heals the persisted IP of already-known ones (skipping any device
--- whose "Manual IP Override" preference has a real, non-sentinel value —
--- that's the user explicitly pinning it).
local function discovery_pass(driver)
  local known_by_dni = {}
  for _, device in pairs(driver:get_devices()) do
    known_by_dni[device.device_network_id] = device
  end

  local candidates = discovery_mdns.find_fans(driver)
  for _, candidate in ipairs(candidates) do
    local existing = known_by_dni[candidate.dni]
    if not existing then
      create_device(driver, candidate.dni, candidate.name or "BAF Fan", candidate.ip)
    else
      local override = existing.preferences and existing.preferences.ipAddress
      local has_manual_override = override and override ~= MANUAL_IP_SENTINEL and override ~= ""
      if not has_manual_override then
        local current = existing:get_field(IP_FIELD)
        if current ~= candidate.ip then
          log.info("BAF device " .. candidate.dni .. " IP changed " ..
            tostring(current) .. " -> " .. candidate.ip .. " (self-healed via mDNS)")
          existing:set_field(IP_FIELD, candidate.ip, { persist = true })
        end
      end
    end
  end
end

--- The driver's discovery_handler. Loops on a short interval for as long
--- as the platform tells it to (should_continue) — matching the same
--- periodic-rescan shape used by the official Aqara/JBL mDNS drivers —
--- rather than a single one-shot pass.
function Discovery.discovery_handler(driver, _, should_continue)
  log.info("BAF discovery started (mDNS, self-healing, no credentials needed)")
  while should_continue() do
    local ok, err = pcall(discovery_pass, driver)
    if not ok then
      log.error("BAF discovery pass failed: " .. tostring(err))
    end
    socket.sleep(2)
  end
end

return Discovery
