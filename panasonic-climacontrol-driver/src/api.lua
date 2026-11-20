--- Minimal client for the ClimateControl module's local HTTP API.
---
--- GET http://<module>/control returns the status as JSON; commands are the
--- same path with a query, e.g. /control?cmd=heatpump&power=on. Port 80.
---
--- A module with a web password set answers 401 {"response":"ERROR","errors":
--- ["Not authenticated"]} until the client logs in: POST /login with the form
--- field "password" returns a "session" cookie, which every later request
--- sends. The session lasts until the module restarts, so a 401 means "log in
--- again" and the request is retried once.

local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local json = require "dkjson"

http.TIMEOUT = 6

local Api = {}

local sessions = {}   -- ip -> "session=..." cookie

local function escape(v)
  return (tostring(v):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function raw_get(ip, path)
  local out = {}
  local ok, code = http.request({
    url = "http://" .. ip .. path,
    method = "GET",
    sink = ltn12.sink.table(out),
    headers = { cookie = sessions[ip] },
    redirect = false,
  })
  if not ok then
    return nil, tostring(code)
  end
  return table.concat(out), code
end

--- Log in with the module's web password; remembers the session cookie.
--- Returns true, or nil and an error.
function Api.login(ip, password)
  local body = "password=" .. escape(password)
  local ok, code, headers = http.request({
    url = "http://" .. ip .. "/login",
    method = "POST",
    source = ltn12.source.string(body),
    sink = ltn12.sink.null(),
    headers = {
      ["content-type"] = "application/x-www-form-urlencoded",
      ["content-length"] = tostring(#body),
    },
    redirect = false,
  })
  if not ok then
    return nil, tostring(code)
  end
  local cookie = headers and tostring(headers["set-cookie"] or ""):match("(session=[^;,%s]+)")
  if not cookie then
    local where = headers and tostring(headers.location or "") or ""
    return nil, where:find("err=1", 1, true) and "wrong password" or ("login failed (HTTP " .. tostring(code) .. ")")
  end
  sessions[ip] = cookie
  return true
end

--- Whether a 401 body is the module's own "not authenticated" answer.
local function is_login_required(body)
  local data = json.decode(body or "")
  if type(data) ~= "table" or data.response ~= "ERROR" or type(data.errors) ~= "table" then
    return false
  end
  for _, e in ipairs(data.errors) do
    if tostring(e):lower() == "not authenticated" then
      return true
    end
  end
  return false
end

--- GET a path, logging in (once) if the module asks. Returns the body, or nil,
--- an error and, for a password-protected module, "auth".
local function get(ip, path, password)
  local body, code = raw_get(ip, path)
  if code == 401 and is_login_required(body) then
    sessions[ip] = nil
    if not password or password == "" then
      return nil, "the module has a password: enter it in the device's Settings", "auth"
    end
    local ok, err = Api.login(ip, password)
    if not ok then
      return nil, "login: " .. tostring(err), "auth"
    end
    body, code = raw_get(ip, path)
    if code == 401 then
      return nil, "not accepted after login", "auth"
    end
  end
  if not body then
    return nil, code
  end
  if code ~= 200 then
    return nil, "HTTP " .. tostring(code)
  end
  return body
end

--- Whether the web server at ip is a ClimateControl module: its login page is
--- titled "... ClimateControl". Checked before any password is sent to it.
function Api.is_climatecontrol(ip)
  local body, code = raw_get(ip, "/login")
  return code == 200 and type(body) == "string" and body:find("<title>[^<]*ClimateControl") ~= nil
end

--- Forget a module's session (e.g. after its password setting changed).
function Api.forget(ip)
  if ip then
    sessions[ip] = nil
  else
    sessions = {}
  end
end

--- Status JSON as a table, or nil, an error and (if it needs a password) "auth".
function Api.status(ip, password)
  local body, err, kind = get(ip, "/control", password)
  if not body then
    return nil, err, kind
  end
  local data = json.decode(body)
  if type(data) ~= "table" then
    return nil, "status is not JSON"
  end
  return data
end

--- One heatpump command, e.g. Api.command(ip, "power", "on", password).
--- Returns true, or nil and an error.
function Api.command(ip, key, value, password)
  local body, err = get(ip, "/control?cmd=heatpump&" .. escape(key) .. "=" .. escape(value), password)
  if not body then
    return nil, err
  end
  return true
end

--- Change module settings, as its own Settings page does:
--- /control?cmd=settings&<key>=<value>... (e.g. t_protmin=5). Returns true,
--- or nil and an error.
function Api.settings(ip, values, password)
  local parts = {}
  for _, kv in ipairs(values) do
    table.insert(parts, escape(kv[1]) .. "=" .. escape(kv[2]))
  end
  local body, err = get(ip, "/control?cmd=settings&" .. table.concat(parts, "&"), password)
  if not body then
    return nil, err
  end
  return true
end

--- Restart the module (GET /control?cmd=restart).
function Api.restart(ip, password)
  local body, err = get(ip, "/control?cmd=restart", password)
  if not body then
    return nil, err
  end
  return true
end

return Api
