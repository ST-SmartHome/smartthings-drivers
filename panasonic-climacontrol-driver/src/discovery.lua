--- Discovery for ClimateControl modules.
---
--- Each module announces itself over mDNS (ProtoART: "heatpump.local"; with
--- several modules on one network each gets its own name). Every candidate
--- that answers GET /control with a "heatpump" status is a module; its MAC
--- address (from the status) becomes the device network id, so a module is
--- created once however often discovery runs and keeps its device when its
--- IP address changes.
---
--- If mDNS finds nothing (e.g. the hub is on another network segment), one
--- device is created to be pointed at the module with the IP Address setting.

local log = require "log"
local mdns = require "st.mdns"

local Api = require "api"
local Status = require "status"

local PROFILE = "climacontrol-panasonic.v2"
local DNI_PREFIX = "climacontrol-"
local MANUAL_DNI = DNI_PREFIX .. "manual"

local Discovery = { DNI_PREFIX = DNI_PREFIX, MANUAL_DNI = MANUAL_DNI }

local SERVICE_TYPES = { "_http._tcp" }
local NAME_HINTS = { "heatpump", "hvac", "clima", "factory" }

local function looks_like_module(name)
  local n = tostring(name or ""):lower()
  for _, hint in ipairs(NAME_HINTS) do
    if n:find(hint, 1, true) then
      return true
    end
  end
  return false
end

--- IPv4 addresses of mDNS services that might be modules.
function Discovery.candidate_ips()
  local ips, seen = {}, {}
  for _, service_type in ipairs(SERVICE_TYPES) do
    local ok, response = pcall(mdns.discover, service_type, "local")
    if not ok or not response then
      log.warn("ClimateControl mDNS " .. service_type .. " failed: " .. tostring(response))
    else
      local names = {}
      for _, found in ipairs(response.found or {}) do
        local info = found.service_info or {}
        local host = found.host_info or {}
        local addr = tostring(host.address)
        table.insert(names, tostring(info.name) .. "/" .. tostring(host.name) .. "@" .. addr)
        if (looks_like_module(info.name) or looks_like_module(host.name))
            and addr:match("^%d+%.%d+%.%d+%.%d+$") and not seen[addr] then
          seen[addr] = true
          table.insert(ips, addr)
        end
      end
      log.debug("ClimateControl mDNS " .. service_type .. " saw: " .. table.concat(names, ", "))
    end
  end
  return ips
end

--- Modules that answer, as a list of { ip, mac, data }.
function Discovery.find_modules()
  local modules = {}
  for _, ip in ipairs(Discovery.candidate_ips()) do
    local data, err = Api.status(ip)
    if data and type(data.heatpump) == "table" then
      local parsed = Status.parse(data)
      table.insert(modules, { ip = ip, mac = Status.mac_key(parsed.mac), data = data })
    else
      log.debug("ClimateControl candidate " .. ip .. " is not a module: " .. tostring(err))
    end
  end
  return modules
end

local function existing_dnis(driver)
  local dnis = {}
  for _, device in ipairs(driver:get_devices()) do
    dnis[tostring(device.device_network_id)] = device
  end
  return dnis
end

function Discovery.discovery_handler(driver, opts, cons)
  local existing = existing_dnis(driver)
  local modules = Discovery.find_modules()
  log.info("ClimateControl discovery: " .. #modules .. " module(s) answered")
  local created = 0
  for _, m in ipairs(modules) do
    local dni = DNI_PREFIX .. (m.mac or m.ip:gsub("%.", "-"))
    if not existing[dni] then
      local label = "Panasonic AC " .. (m.mac and m.mac:sub(-4) or m.ip)
      local ok, err = driver:try_create_device({
        type = "LAN",
        device_network_id = dni,
        label = label,
        profile = PROFILE,
        manufacturer = "Panasonic",
        model = "ClimateControl PANA_CNCNT",
        vendor_provided_label = "ClimateControl (Panasonic)",
      })
      if ok then
        created = created + 1
        driver.found_ips = driver.found_ips or {}
        driver.found_ips[dni] = m.ip
      elseif not tostring(err):find("DNI already exists") then
        log.error("Failed to create ClimateControl device: " .. tostring(err))
      end
    end
  end
  if #modules == 0 and not existing[MANUAL_DNI] then
    log.info("No ClimateControl module found over mDNS; creating one device for its IP Address setting")
    driver:try_create_device({
      type = "LAN",
      device_network_id = MANUAL_DNI,
      label = "Panasonic AC",
      profile = PROFILE,
      manufacturer = "Panasonic",
      model = "ClimateControl PANA_CNCNT",
      vendor_provided_label = "ClimateControl (Panasonic)",
    })
  end
  log.info("ClimateControl discovery created " .. created .. " device(s)")
end

return Discovery
