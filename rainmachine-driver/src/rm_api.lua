--- Minimal client for the RainMachine local API (v4), over plain HTTP.
---
--- RainMachine serves its API over HTTPS on 8080 with a self-signed
--- certificate, and over plain HTTP on 8081 when "HTTP" is enabled in its
--- settings (it is by default). This uses 8081, the same approach as the
--- community RainMachine Connector driver.
---
--- The access token travels as an ?access_token= query parameter, so request
--- URLs are never logged: only the API path is.

local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local json = require "dkjson"
local log = require "log"

http.TIMEOUT = 10

local Client = {}
Client.__index = Client

--- Error text that means the password was rejected. init.lua treats it as a
--- settings problem (offline at once, slow retries) rather than a network one.
Client.AUTH_ERROR = "password rejected"

function Client.new(ip, port, password)
  return setmetatable({ base = "http://" .. ip .. ":" .. tostring(port) .. "/api/4/", password = password }, Client)
end

--- One HTTP round trip. Returns the decoded JSON body and the HTTP status,
--- or nil and an error string.
function Client:raw(method, path, body, with_token)
  local url = self.base .. path
  if with_token then
    url = url .. (path:find("?", 1, true) and "&" or "?") .. "access_token=" .. self.token
  end
  local out = {}
  local req = { url = url, method = method, sink = ltn12.sink.table(out) }
  if body ~= nil then
    local text = json.encode(body)
    req.source = ltn12.source.string(text)
    req.headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#text) }
  end
  local ok, code = http.request(req)
  if not ok then
    return nil, method .. " " .. path .. ": " .. tostring(code)
  end
  local data = json.decode(table.concat(out))
  if type(data) ~= "table" then
    return nil, method .. " " .. path .. ": HTTP " .. tostring(code) .. ", not JSON"
  end
  return data, code
end

function Client:login()
  local data, code = self:raw("POST", "auth/login", { pwd = self.password, remember = 1 }, false)
  if not data then
    return nil, code
  end
  if data.access_token then
    self.token = data.access_token
    log.info("RainMachine login OK")
    return true
  end
  if code == 401 or data.statusCode == 2 then
    log.warn("RainMachine login rejected: HTTP " .. tostring(code) .. " statusCode " .. tostring(data.statusCode)
      .. " (" .. tostring(data.message) .. ")")
    return nil, Client.AUTH_ERROR
  end
  return nil, "login failed: HTTP " .. tostring(code) .. " statusCode " .. tostring(data.statusCode)
end

--- Authenticated call. Logs in when there's no token, and once more if the
--- token has been rejected (e.g. the controller was reset).
function Client:call(method, path, body)
  for attempt = 1, 2 do
    if not self.token then
      local ok, err = self:login()
      if not ok then
        return nil, err
      end
    end
    local data, code = self:raw(method, path, body, true)
    if not data then
      return nil, code
    end
    if code == 401 or data.statusCode == 2 then
      self.token = nil
      if attempt == 2 then
        return nil, Client.AUTH_ERROR
      end
    elseif code ~= 200 then
      return nil, method .. " " .. path .. ": HTTP " .. tostring(code) .. " " .. tostring(data.message)
    else
      return data
    end
  end
end

function Client:get(path)
  return self:call("GET", path, nil)
end

function Client:post(path, body)
  return self:call("POST", path, body or {})
end

--- Unauthenticated: firmware and hardware version.
function Client:api_version()
  return self:raw("GET", "apiVer", nil, false)
end

return Client
