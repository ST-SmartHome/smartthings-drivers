--- Translation between the ClimateControl module's values and SmartThings'.
---
--- Pure Lua (no SmartThings modules), so it can be tested on its own.
---
--- The module's status JSON (GET /control) isn't documented for the
--- Panasonic version. ProtoART's Mitsubishi version nests the air
--- conditioner under "heatpump" (power, mode, fan, set_temperature,
--- actual_temperature, ...), and the Panasonic MQTT topics use the same
--- names, so the same layout is assumed. Each reading tries a few paths and
--- the driver logs the JSON's keys once, so a different layout shows up in
--- the hub log.

local Status = {}

--- Value at a dotted path ("heatpump.op.tout"), or nil.
function Status.get(data, path)
  local node = data
  for key in path:gmatch("[^%.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[key]
  end
  return node
end

--- First non-nil value among several dotted paths.
function Status.first(data, paths)
  for _, path in ipairs(paths) do
    local v = Status.get(data, path)
    if v ~= nil and v ~= "" then
      return v
    end
  end
  return nil
end

local function lower(v)
  if v == nil then
    return nil
  end
  return tostring(v):lower()
end

--- Mode: module "auto/0, cool/1, fan/fan_only/2, dry/3, heat/4, off".
local MODE_FROM_DEVICE = {
  auto = "auto", ["0"] = "auto",
  cool = "cool", ["1"] = "cool",
  fan = "fanOnly", fan_only = "fanOnly", ["2"] = "fanOnly",
  dry = "dry", ["3"] = "dry",
  heat = "heat", ["4"] = "heat",
}
local MODE_TO_DEVICE = { auto = "auto", cool = "cool", fanOnly = "fan", fan = "fan", wind = "fan", dry = "dry", heat = "heat" }
Status.SUPPORTED_MODES = { "auto", "cool", "dry", "fanOnly", "heat" }

function Status.mode_from_device(v)
  return MODE_FROM_DEVICE[lower(v)]
end

function Status.mode_to_device(v)
  return MODE_TO_DEVICE[v]
end

--- Fan: module "auto/0, silent/1, low/2, med/3, high/4, superhigh/5".
local FAN_FROM_DEVICE = {
  auto = "auto", ["0"] = "auto",
  silent = "quiet", quiet = "quiet", ["1"] = "quiet",
  low = "low", ["2"] = "low",
  med = "medium", medium = "medium", ["3"] = "medium",
  high = "high", ["4"] = "high",
  superhigh = "turbo", ["5"] = "turbo",
}
local FAN_TO_DEVICE = { auto = "auto", quiet = "silent", low = "low", medium = "med", high = "high", turbo = "superhigh" }
Status.SUPPORTED_FAN_MODES = { "auto", "quiet", "low", "medium", "high", "turbo" }

function Status.fan_from_device(v)
  return FAN_FROM_DEVICE[lower(v)]
end

function Status.fan_to_device(v)
  return FAN_TO_DEVICE[v]
end

--- Power: "on"/"off", 1/0 or true/false. nil when unknown.
function Status.power_from_device(v)
  local s = lower(v)
  if s == "on" or s == "1" or s == "true" then
    return "on"
  elseif s == "off" or s == "0" or s == "false" then
    return "off"
  end
  return nil
end

--- Vertical vane: module "1, 2, 3, 4, 5, swing/6, auto/6" (swing and auto
--- are the same setting, 6).
local VANE_FROM_DEVICE = {
  ["1"] = "1", ["2"] = "2", ["3"] = "3", ["4"] = "4", ["5"] = "5",
  swing = "auto", auto = "auto", ["6"] = "auto",
}
Status.VANE_VALUES = { "auto", "1", "2", "3", "4", "5" }

function Status.vane_from_device(v)
  return VANE_FROM_DEVICE[lower(v)]
end

--- Horizontal vane: module "maxleft/0, left/1, middle/2, right/3,
--- maxright/4, swing/5". Sent by name.
local WIDEVANE_BY_NUMBER = { ["0"] = "maxleft", ["1"] = "left", ["2"] = "middle", ["3"] = "right", ["4"] = "maxright", ["5"] = "swing" }
local WIDEVANE_NAMES = { maxleft = true, left = true, middle = true, right = true, maxright = true, swing = true }
Status.WIDEVANE_VALUES = { "swing", "maxleft", "left", "middle", "right", "maxright" }

function Status.widevane_from_device(v)
  local s = lower(v)
  if s == nil then
    return nil
  end
  if WIDEVANE_NAMES[s] then
    return s
  end
  return WIDEVANE_BY_NUMBER[s]
end

--- Preset: module "normal/1, powerful/2, quiet/3".
local PRESET_BY_NUMBER = { ["1"] = "normal", ["2"] = "powerful", ["3"] = "quiet" }
local PRESET_NAMES = { normal = true, powerful = true, quiet = true }
Status.PRESET_VALUES = { "normal", "powerful", "quiet" }

function Status.preset_from_device(v)
  local s = lower(v)
  if s == nil then
    return nil
  end
  if PRESET_NAMES[s] then
    return s
  end
  return PRESET_BY_NUMBER[s]
end

--- On/off features ("on/1/true, off/0/false"), keyed by the command name the
--- module uses; each is a switch in its own component of the same name.
Status.FEATURES = { "eco", "econavi", "nanoex", "milddry" }

function Status.number(v)
  local n = tonumber(v)
  if n == nil or n ~= n then
    return nil
  end
  return n
end

--- The readings the driver shows, from one status JSON.
--- Returns a table; any field the JSON doesn't have is nil.
function Status.parse(data)
  local hp_mode = Status.first(data, { "heatpump.mode" })
  local power = Status.power_from_device(Status.first(data, { "heatpump.power" }))
  -- The module lists "off" as a mode value too.
  if lower(hp_mode) == "off" then
    power = "off"
  end
  return {
    power = power,
    mode = Status.mode_from_device(hp_mode),
    fan = Status.fan_from_device(Status.first(data, { "heatpump.fan" })),
    setpoint = Status.number(Status.first(data, { "heatpump.set_temperature", "heatpump.settemperature" })),
    room = Status.number(Status.first(data, {
      "heatpump.actual_temperature", "heatpump.room_temperature", "heatpump.roomtemperature", "heatpump.temperature",
    })),
    outdoor = Status.number(Status.first(data, { "heatpump.op.tout", "heatpump.tout" })),
    watts = Status.number(Status.first(data, { "heatpump.op.pinp" })),
    vane = Status.vane_from_device(Status.first(data, { "heatpump.vane" })),
    widevane = Status.widevane_from_device(Status.first(data, { "heatpump.widevane" })),
    preset = Status.preset_from_device(Status.first(data, { "heatpump.preset" })),
    features = (function()
      local f = {}
      for _, key in ipairs(Status.FEATURES) do
        f[key] = Status.power_from_device(Status.first(data, { "heatpump." .. key }))
      end
      return f
    end)(),
    connected = Status.first(data, { "sys.conhp" }),
    ext_connected = Status.first(data, { "sys.conext" }),
    temp_input = Status.first(data, { "heatpump.tinp" }),
    rssi = Status.number(Status.first(data, { "wifi.rssi" })),
    ip = Status.first(data, { "wifi.ip" }),
    firmware_latest = Status.first(data, { "fw.last" }),
    uptime = Status.number(Status.first(data, { "sys.up" })),
    mac = Status.first(data, { "wifi.mac", "module.mac" }),
    module_id = Status.first(data, { "sys.id", "module.id" }),
    firmware = Status.first(data, { "fw.curr", "module.fw" }),
  }
end

--- True when the status says the module can't talk to the air conditioner.
function Status.unit_disconnected(parsed)
  local c = lower(parsed.connected)
  return c == "false" or c == "0"
end

-- ===== Module status text (the Module component's tiles) =====

local function yes(v)
  local s = lower(v)
  return s == "true" or s == "1" or s == "on"
end

local function no(v)
  local s = lower(v)
  return s == "false" or s == "0" or s == "off"
end

--- "Connected" / "Not connected (check the CN-CNT cable)", plus the EXT port.
function Status.link_text(parsed)
  local text
  if yes(parsed.connected) then
    text = "Connected"
  elseif no(parsed.connected) then
    text = "Not connected (check the CN-CNT cable)"
  else
    return nil
  end
  if yes(parsed.ext_connected) then
    text = text .. " · EXT port connected"
  elseif no(parsed.ext_connected) then
    text = text .. " · EXT port not connected"
  end
  return text
end

local TEMP_INPUT_TEXT = {
  wireless = "Wireless thermometer",
  external = "Remote temperature",
  internal = "Air conditioner's own sensor",
}

function Status.temp_input_text(v)
  if v == nil then
    return nil
  end
  return TEMP_INPUT_TEXT[lower(v)] or tostring(v)
end

function Status.rssi_text(dbm)
  if dbm == nil then
    return nil
  end
  local quality = dbm >= -50 and "excellent" or dbm >= -60 and "good" or dbm >= -70 and "fair" or "weak"
  return string.format("%d dBm (%s)", math.floor(dbm + 0.5), quality)
end

function Status.firmware_text(current, latest)
  if current == nil then
    return nil
  end
  current, latest = tostring(current), latest and tostring(latest)
  if latest and latest ~= "" and latest ~= current then
    return current .. " (update available: " .. latest .. ")"
  elseif latest == current then
    return current .. " (latest)"
  end
  return current
end

--- Uptime to the hour (the tile would otherwise change every poll):
--- "under 1 h", "5 h", "3 d 4 h".
function Status.uptime_text(seconds)
  if seconds == nil then
    return nil
  end
  local hours = math.floor(seconds / 3600)
  if hours < 1 then
    return "under 1 h"
  elseif hours < 24 then
    return hours .. " h"
  end
  return math.floor(hours / 24) .. " d " .. (hours % 24) .. " h"
end

--- MAC as AA:BB:CC:DD:EE:FF.
function Status.mac_text(mac)
  local key = Status.mac_key(mac)
  if not key then
    return mac and tostring(mac) or nil
  end
  return (key:gsub("(%x%x)", "%1:"):sub(1, -2))
end

--- A MAC in the form used for device network ids: upper case, no colons.
function Status.mac_key(mac)
  if mac == nil then
    return nil
  end
  local key = tostring(mac):upper():gsub("[^0-9A-F]", "")
  if #key ~= 12 then
    return nil
  end
  return key
end

--- Sorted top-level keys and heatpump keys, for the one-off layout log.
function Status.describe(data)
  local function keys(t)
    local out = {}
    if type(t) == "table" then
      for k in pairs(t) do
        table.insert(out, tostring(k))
      end
    end
    table.sort(out)
    return table.concat(out, ",")
  end
  return "top: " .. keys(data) .. " | heatpump: " .. keys(type(data) == "table" and data.heatpump)
end

return Status
