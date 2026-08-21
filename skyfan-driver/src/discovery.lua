--- Discovery for the Skyfan DC. Same reasoning as the SolarEdge Modbus
--- driver: Tuya devices do send a local UDP broadcast, but it's a
--- proprietary format on a proprietary port, not SSDP/mDNS — SmartThings'
--- discovery-gating mechanism (search-parameters.yml) only understands
--- those two, so there's nothing to gate on here either. The real IP/
--- local_key/device ID are entered afterward via device preferences, for
--- every device this driver ever creates.
---
--- (A follow-on attempt to listen for that broadcast directly from this
--- driver's own discovery_handler — decrypting it with Tuya's known fixed
--- key — was built and tested on 2026-08-05, then reverted: SmartThings
--- Edge Drivers can only bind UDP sockets to port 0 (a platform
--- restriction, confirmed live on this hub and independently via the
--- SmartThings community), and Tuya's broadcast targets fixed protocol
--- ports (6666/6667) the driver has no ability to claim. Not fixable —
--- see smartthings-edge-driver-gotchas memory. Don't re-attempt this
--- without re-reading that entry first.)
---
--- How many fans: earlier versions tried a fixed single device, then a
--- bounded pool of numbered slots (both rejected — see git history/session
--- notes). The actual right pattern, confirmed against toddaustin07's
--- edge_WLED (a well-established community driver solving the exact same
--- "may have more than one, no discovery signal to count them" problem):
--- create exactly ONE device the first time discovery ever runs for this
--- driver, and expose an explicit "Add another fan" button (a local
--- push-only capability, see capabilitydefs.lua) on every fan device for
--- creating each additional one. Discovery fires repeatedly and
--- automatically in the background for the lifetime of the driver
--- (confirmed via hours of live logcat) — gating on "any Skyfan device
--- already exists" makes every one of those automatic re-fires a no-op
--- after the first, so nothing is ever created without the user explicitly
--- asking for it, either via "Add Device" (the first one) or the button
--- (every one after that). No bounded guess, no unwanted placeholder tiles.

local log = require "log"

local PROFILE = "skyfan-dc.v6"
local FIRST_DEVICE_NETWORK_ID = "skyfan-dc-tuya-1"

local Discovery = {}

--- Creates one new Skyfan DC device with a fresh, always-unique network id.
--- Called both by discovery (for the very first device) and by the "Add
--- another fan" button command (for every device after that).
function Discovery.create_device(driver, device_network_id, label)
  local metadata = {
    type = "LAN",
    device_network_id = device_network_id,
    label = label,
    profile = PROFILE,
    manufacturer = "Ventair",
    model = "Skyfan DC",
    vendor_provided_label = "Skyfan DC",
  }
  log.info("Creating Skyfan DC device (" .. device_network_id .. ") — set IP/local_key/device ID in device settings after adding")
  local ok, err = driver:try_create_device(metadata)
  if not ok and not tostring(err):find("DNI already exists") then
    log.error("Failed to create Skyfan DC device: " .. tostring(err))
  end
end

--- Called from the "Add another fan" button on an existing device.
function Discovery.create_another(driver)
  local device_network_id = "skyfan-dc-tuya-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  Discovery.create_device(driver, device_network_id, "Skyfan DC")
end

function Discovery.discovery_handler(driver, opts, cons)
  log.info("Skyfan DC discovery started (manual creation, not network-gated)")

  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id:sub(1, #"skyfan-dc-tuya-") == "skyfan-dc-tuya-" then
      log.info("A Skyfan DC device already exists — not creating another automatically (use the 'Add another fan' button for that)")
      return
    end
  end

  Discovery.create_device(driver, FIRST_DEVICE_NETWORK_ID, "Skyfan DC")
end

return Discovery
