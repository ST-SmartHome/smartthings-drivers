--- Discovery for ClimateControl modules.
---
--- Each module announces itself over mDNS as a web server (_http._tcp; its
--- name is whatever was set on the module, "heatpump" by default). Every web
--- server found is asked GET /control, so a module is recognised by its
--- answer, not its name:
---   * a "heatpump" status: a module; its MAC address (from the status)
---     becomes the device network id, so a module is created once however
---     often discovery runs and keeps its device when its IP address changes;
---   * 401 "Not authenticated" from a server whose login page is a
---     ClimateControl one: a module with a web password. The passwords already
---     set on other ClimateControl devices are tried (one household usually
---     uses one; they are only ever sent to ClimateControl modules); if none
---     works the device is created from the module's mDNS name (plus its
---     address if another device already has that name), and works once its
---     password is entered in Settings.
---
--- Modules for other brands (same firmware family) are skipped: sys.hw names
--- the interface, "PANA_..." for Panasonic.
---
--- If mDNS finds nothing (e.g. the hub is on another network segment), one
--- device is created to be pointed at the module with the IP Address setting.

local log = require "log"
local mdns = require "st.mdns"

local Api = require "api"
local Status = require "status"

local PROFILE = "climacontrol-panasonic.v3"
local DNI_PREFIX = "climacontrol-"
local MANUAL_DNI = DNI_PREFIX .. "manual"
local HOST_PREFIX = DNI_PREFIX .. "host-"

local Discovery = { DNI_PREFIX = DNI_PREFIX, MANUAL_DNI = MANUAL_DNI, HOST_PREFIX = HOST_PREFIX,
  PASSWORD_FIELD = "password" }   -- a password found to work during a scan

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

--- A module's mDNS name as used in a device network id ("heatpump.local" -> "heatpump").
function Discovery.host_key(name)
  local n = tostring(name or ""):lower():gsub("%.local%.?$", ""):gsub("[^%w%-]", "")
  return n ~= "" and n or nil
end

--- Web servers found over mDNS, as a list of { ip, host }: likely modules
--- (by name) first, then every other one.
function Discovery.candidates()
  local first, rest, seen = {}, {}, {}
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
        if addr:match("^%d+%.%d+%.%d+%.%d+$") and not seen[addr] then
          seen[addr] = true
          local c = { ip = addr, host = Discovery.host_key(host.name) or Discovery.host_key(info.name) }
          table.insert((looks_like_module(info.name) or looks_like_module(host.name)) and first or rest, c)
        end
      end
      log.debug("ClimateControl mDNS " .. service_type .. " saw: " .. table.concat(names, ", "))
    end
  end
  for _, c in ipairs(rest) do
    table.insert(first, c)
  end
  return first
end

--- The module passwords set on the driver's devices (tried on new modules).
function Discovery.known_passwords(driver)
  local list, seen = {}, {}
  for _, device in ipairs(driver and driver:get_devices() or {}) do
    for _, pw in ipairs({ (device.preferences or {}).modulePassword, device:get_field(Discovery.PASSWORD_FIELD) }) do
      if type(pw) == "string" and pw ~= "" and not seen[pw] then
        seen[pw] = true
        table.insert(list, pw)
      end
    end
  end
  return list
end

--- True unless the status names a non-Panasonic interface (sys.hw).
local function is_panasonic(data)
  local hw = type(data.sys) == "table" and data.sys.hw or nil
  return hw == nil or tostring(hw):upper():find("^PANA") ~= nil
end

--- Modules that answer, as a list of { ip, host, mac, name, data, locked }.
--- A module whose password isn't known is listed with locked = true (no mac).
function Discovery.find_modules(passwords)
  local modules = {}
  for _, c in ipairs(Discovery.candidates()) do
    local data, err, kind = Api.status(c.ip)
    local used_pw
    if not data and kind == "auth" then
      if not Api.is_climatecontrol(c.ip) then
        kind, err = nil, "asks for a login but isn't a ClimateControl module"
      else
        for _, pw in ipairs(passwords or {}) do
          data, err, kind = Api.status(c.ip, pw)
          if data then
            used_pw = pw
            break
          end
        end
      end
    end
    if data and type(data.heatpump) == "table" and not is_panasonic(data) then
      log.info("ClimateControl module at " .. c.ip .. " is for another brand (" .. tostring((data.sys or {}).hw) .. "): skipped")
    elseif data and type(data.heatpump) == "table" then
      local parsed = Status.parse(data)
      table.insert(modules, { ip = c.ip, host = c.host, mac = Status.mac_key(parsed.mac), name = parsed.name, data = data,
        password = used_pw })
    elseif kind == "auth" then
      table.insert(modules, { ip = c.ip, host = c.host, locked = true })
    else
      log.debug("ClimateControl candidate " .. c.ip .. " is not a module: " .. tostring(err))
    end
  end
  return modules
end

local function existing_dnis(driver)
  local dnis, ips, macs = {}, {}, {}
  for _, device in ipairs(driver:get_devices()) do
    dnis[tostring(device.device_network_id)] = device
    for _, ip in ipairs({ device:get_field("ip"), (device.preferences or {}).ipAddress }) do
      if ip and ip ~= "0.0.0.0" then
        ips[ip] = ips[ip] or device
      end
    end
    local mac = device:get_field("mac")
    if mac then
      macs[mac] = device
    end
  end
  return dnis, ips, macs
end

--- Stands in for a device created earlier in the same scan.
local function placeholder(ip)
  return { preferences = {}, get_field = function(_, k) return k == "ip" and ip or nil end }
end

function Discovery.discovery_handler(driver, opts, cons)
  if Discovery.on_scan then
    Discovery.on_scan(driver)   -- e.g. deleted sensor devices may be added again
  end
  local existing, existing_ips, existing_macs = existing_dnis(driver)
  local modules = Discovery.find_modules(Discovery.known_passwords(driver))
  log.info("ClimateControl discovery: " .. #modules .. " module(s) answered")
  local created = 0
  for _, m in ipairs(modules) do
    local ip_key = m.ip:gsub("%.", "-")
    local dni = m.mac and (DNI_PREFIX .. m.mac)
        or (m.host and (HOST_PREFIX .. m.host))
        or (DNI_PREFIX .. ip_key)
    local known
    if m.locked then
      -- Already added (by name, by MAC once unlocked, or by address). Two locked
      -- modules can share a name ("heatpump" by default): one at a different
      -- address from the device of that name is another module.
      known = existing_ips[m.ip]
      if not known and existing[dni] then
        local other = existing[dni]
        local other_ip = other:get_field("ip") or (other.preferences or {}).ipAddress
        if other_ip and other_ip ~= "0.0.0.0" and other_ip ~= m.ip then
          dni = dni .. "-" .. ip_key
          known = existing[dni]
        else
          known = other
        end
      end
    else
      -- By address only if that device isn't another module's (by MAC): after
      -- a power cut a new module can get an address an existing one had.
      local by_ip = existing_ips[m.ip]
      local by_ip_mac = by_ip and by_ip.get_field and by_ip:get_field("mac")
      if by_ip_mac and m.mac and by_ip_mac ~= m.mac then
        by_ip = nil
      end
      known = existing[dni] or (m.mac and existing_macs[m.mac]) or by_ip
      -- Added while locked, under its name, and its address not known yet.
      local by_host = m.host and existing[HOST_PREFIX .. m.host]
      if not known and by_host and not by_host:get_field("ip") and not by_host:get_field("mac") then
        known = by_host
      end
      -- Unlocked with another device's password: remember it for this one.
      if known and m.password and known.set_field and not known:get_field(Discovery.PASSWORD_FIELD)
          and ((known.preferences or {}).modulePassword or "") == "" then
        known:set_field(Discovery.PASSWORD_FIELD, m.password, { persist = true })
      end
    end
    if m.locked then
      log.info("ClimateControl module at " .. m.ip .. " (" .. tostring(m.host) .. ") has a password: "
        .. "enter it in the device's Settings")
    end
    if not known then
      -- The name set in the module's web page (e.g. the room), if any.
      local name = m.name and tostring(m.name):match("^%s*(.-)%s*$")
      local label = (name and name ~= "") and name
        or ("Panasonic AC " .. (m.mac and m.mac:sub(-4) or m.host or m.ip))
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
        if m.password then
          driver.found_passwords = driver.found_passwords or {}
          driver.found_passwords[dni] = m.password
        end
        existing[dni] = placeholder(m.ip)
        existing_ips[m.ip] = existing[dni]
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
