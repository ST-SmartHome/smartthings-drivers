--- Discovery for the RainMachine. RainMachine advertises an mDNS
--- "_http._tcp" service whose instance name starts with "rainmachine" (the
--- same signal Home Assistant uses), so the controller's IP address is found
--- automatically; only the password has to be entered. The IP setting stays
--- as an override for networks where mDNS doesn't reach the hub.
---
--- Discovery creates one controller the first time it runs and does nothing
--- after that; zone and program devices are created by the controller itself
--- once it can log in.

local log = require "log"
local mdns = require "st.mdns"

local PROFILE = "rainmachine-controller.v5"
local DNI_PREFIX = "rainmachine-"
local FIRST_DEVICE_NETWORK_ID = "rainmachine-1"

local Discovery = {}

--- Returns a list of { ip = ..., name = ... } for RainMachines answering mDNS.
--- RainMachine advertises "_http._tcp" (instance "rainmachine*", what Home
--- Assistant matches) and, on HomeKit-capable models, "_hap._tcp".
local SERVICE_TYPES = { "_http._tcp", "_hap._tcp" }

function Discovery.find_rainmachines()
  local found_list, seen = {}, {}
  for _, service_type in ipairs(SERVICE_TYPES) do
    local ok, response = pcall(mdns.discover, service_type, "local")
    if not ok or not response then
      log.warn("RainMachine mDNS " .. service_type .. " failed: " .. tostring(response))
    else
      local names = {}
      for _, found in ipairs(response.found or {}) do
        local info = found.service_info or {}
        local host = found.host_info or {}
        local name = tostring(info.name or "")
        table.insert(names, name .. "@" .. tostring(host.address))
        if name:lower():find("rainmachine", 1, true) and tostring(host.address):match("^%d+%.%d+%.%d+%.%d+$")
          and not seen[host.address] then
          seen[host.address] = true
          table.insert(found_list, { ip = host.address, name = name })
        end
      end
      log.debug("RainMachine mDNS " .. service_type .. " saw: " .. table.concat(names, ", "))
    end
  end
  return found_list
end

function Discovery.discovery_handler(driver, opts, cons)
  for _, device in ipairs(driver:get_devices()) do
    local dni = tostring(device.device_network_id)
    -- Controllers only: zone/program devices end in -zone-N / -program-N.
    -- (parent_device_id can't tell them apart; LAN devices get the hub's id.)
    if dni:sub(1, #DNI_PREFIX) == DNI_PREFIX and not dni:match("%-zone%-%d+$") and not dni:match("%-program%-%d+$") then
      log.info("A RainMachine controller already exists; not creating another")
      return
    end
  end
  log.info("Creating RainMachine controller: enter its password in the device settings (the IP is found automatically)")
  local ok, err = driver:try_create_device({
    type = "LAN",
    device_network_id = FIRST_DEVICE_NETWORK_ID,
    label = "RainMachine",
    profile = PROFILE,
    manufacturer = "RainMachine",
    model = "Controller",
    vendor_provided_label = "RainMachine",
  })
  if not ok and not tostring(err):find("DNI already exists") then
    log.error("Failed to create RainMachine controller: " .. tostring(err))
  end
end

return Discovery
