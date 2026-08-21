-- mDNS discovery for BAF i6 devices. Confirmed via aiobafi6's own
-- discovery.py source that these fans advertise a real, standard
-- "_api._tcp.local." DNS-SD service — this is genuine LAN service
-- discovery, not the (impossible) Tuya-cloud-API auto-discovery dead end
-- documented in the Skyfan driver's memory. SmartThings Edge Drivers have
-- native platform support for exactly this via the `st.mdns` module,
-- confirmed against the real, shipped Aqara presence-sensor driver's
-- discovery_mdns.lua.
--
-- "_api._tcp" is a very generic service name — other unrelated devices on
-- the LAN could plausibly advertise it too. Every candidate is filtered
-- on its TXT "model" record actually looking like a BAF/Haiku fan before
-- a device gets created, not just on the service type matching.

local log = require "log"
local mdns = require "st.mdns"

local discovery_mdns = {}

discovery_mdns.SERVICE_TYPE = "_api._tcp"
discovery_mdns.DOMAIN = "local"

local function byte_array_to_string(byte_array)
  return string.char(table.unpack(byte_array))
end

--- Decodes a found item's raw TXT records into a { key = value } table.
--- Each record is "key=value"; anything without an "=" is ignored.
local function parse_txt(found)
  local out = {}
  for _, raw in ipairs((found.txt or {}).text or {}) do
    local text = byte_array_to_string(raw)
    local key, value = text:match("^([^=]+)=(.*)$")
    if key then
      out[key] = value
    end
  end
  return out
end

--- Returns true if this candidate's TXT "model" record looks like a Big
--- Ass Fans / Haiku device, not just any unrelated "_api._tcp" service.
local function looks_like_baf_fan(txt)
  local model = txt.model
  return type(model) == "string" and model:lower():find("haiku", 1, true) ~= nil
end

--- Runs one mDNS discovery pass and returns a list of candidates:
--- { { dni = ..., ip = ..., uuid = ..., model = ..., name = ... }, ... }
--- dni is derived from the fan's own dns_sd_uuid (stable across IP
--- changes from DHCP), not from its current IP.
function discovery_mdns.find_fans(driver)
  local response, err = mdns.discover(discovery_mdns.SERVICE_TYPE, discovery_mdns.DOMAIN)
  if not response then
    log.warn("BAF mDNS discovery failed: " .. tostring(err))
    return {}
  end

  local candidates = {}
  local seen_uuid = {}
  for _, found in ipairs(response.found or {}) do
    if found.service_info and found.service_info.service_type == discovery_mdns.SERVICE_TYPE
        and found.host_info and found.host_info.address then
      local txt = parse_txt(found)
      if looks_like_baf_fan(txt) then
        local uuid = txt.uuid
        if uuid and not seen_uuid[uuid] then
          seen_uuid[uuid] = true
          table.insert(candidates, {
            dni = "bigassfans-i6-" .. uuid,
            ip = found.host_info.address,
            uuid = uuid,
            model = txt.model,
            name = txt.name,
          })
        elseif not uuid then
          log.warn("BAF mDNS candidate at " .. tostring(found.host_info.address) ..
            " matched model filter but had no TXT uuid record — skipping, can't form a stable DNI")
        end
      end
    end
  end
  return candidates
end

return discovery_mdns
