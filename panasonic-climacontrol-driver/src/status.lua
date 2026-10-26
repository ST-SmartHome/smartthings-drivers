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
    connected = Status.first(data, { "sys.conhp" }),
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
