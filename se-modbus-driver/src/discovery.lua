--- Discovery for a device with no self-announcing LAN protocol (SolarEdge's
--- Modbus TCP service is passive — it never broadcasts SSDP/mDNS, it just waits
--- for a client to connect). Because of that, this driver does NOT use
--- search-parameters.yml to gate discovery on network traffic — there is no
--- traffic to gate on. Instead, discovery unconditionally offers exactly one
--- device, and the user fills in the real IP/port afterward via device
--- preferences (see profiles/solaredge-inverter.yml and init.lua's
--- infoChanged handler).
---
--- This is deliberately the opposite of the previous (se-modbus-v2/v3) approach,
--- which gated on `searchParameters.ssdp` and consequently never invoked this
--- code at all — confirmed via a zero-output logcat capture during a live
--- "Add Device" attempt.

local log = require "log"

local PROFILE = "solaredge-inverter.v4"
-- Static placeholder network id — this is not the inverter's real network
-- identity (that's the IP, set later via preferences), just a stable id for
-- the one discoverable device this driver offers.
local DEVICE_NETWORK_ID = "solaredge-modbus-inverter-1"

local function discovery_handler(driver, opts, cons)
  log.info("SolarEdge Modbus discovery started (manual creation, not network-gated)")

  -- get_device_info() takes a SmartThings device UUID, not our chosen
  -- network_id — there's no direct "does this DNI exist" lookup, so check
  -- the driver's own device list instead.
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == DEVICE_NETWORK_ID then
      log.info("SolarEdge inverter device already exists, skipping creation")
      return
    end
  end

  local metadata = {
    type = "LAN",
    device_network_id = DEVICE_NETWORK_ID,
    label = "SolarEdge Inverter",
    profile = PROFILE,
    manufacturer = "SolarEdge",
    model = "Modbus TCP",
    vendor_provided_label = "SolarEdge Inverter",
  }

  log.info("Creating SolarEdge inverter device — set the real IP/port/unit ID in device settings after adding")
  local ok, err = driver:try_create_device(metadata)
  if not ok then
    -- A duplicate-DNI failure here just means the device list check above
    -- raced with a device that already existed — benign, not a real error.
    if tostring(err):find("DNI already exists") then
      log.info("SolarEdge inverter device already exists (caught at creation)")
    else
      log.error("Failed to create SolarEdge inverter device: " .. tostring(err))
    end
  end
end

return {
  discovery_handler = discovery_handler,
}
