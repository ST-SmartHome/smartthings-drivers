--- Minimal client for the ClimateControl module's local HTTP API.
---
--- GET http://<module>/control returns the status as JSON; commands are the
--- same path with a query, e.g. /control?cmd=heatpump&power=on. Port 80, no
--- authentication (ProtoART: trusted LAN only).

local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local json = require "dkjson"

http.TIMEOUT = 6

local Api = {}

local function get(url)
  local out = {}
  local ok, code = http.request({ url = url, method = "GET", sink = ltn12.sink.table(out) })
  if not ok then
    return nil, tostring(code)
  end
  if code ~= 200 then
    return nil, "HTTP " .. tostring(code)
  end
  return table.concat(out)
end

--- Status JSON as a table, or nil and an error.
function Api.status(ip)
  local body, err = get("http://" .. ip .. "/control")
  if not body then
    return nil, err
  end
  local data = json.decode(body)
  if type(data) ~= "table" then
    return nil, "status is not JSON"
  end
  return data
end

local function escape(v)
  return (tostring(v):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- One heatpump command, e.g. Api.command(ip, "power", "on").
--- Returns true, or nil and an error.
function Api.command(ip, key, value)
  local body, err = get("http://" .. ip .. "/control?cmd=heatpump&" .. escape(key) .. "=" .. escape(value))
  if not body then
    return nil, err
  end
  return true
end

--- Restart the module (GET /control?cmd=restart).
function Api.restart(ip)
  local body, err = get("http://" .. ip .. "/control?cmd=restart")
  if not body then
    return nil, err
  end
  return true
end

return Api
