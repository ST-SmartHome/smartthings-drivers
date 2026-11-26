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
local logged_in_at = {}   -- ip -> os.time() of the last login
-- ip -> { until_time, error, kind }: no login attempts until then. Set when the
-- session is lost again right after logging in, i.e. someone is using the
-- module's own web page (one login at a time): logging in again would log
-- them out.
local blocked = {}
-- ip -> { [password] = until_time }: that password was wrong, so it isn't
-- retried on every poll. Kept per password, so a wrong one (e.g. another
-- module's, tried during a scan) never holds back the right one.
local wrong_until = {}
local WRONG_PASSWORD_WAIT = 300
local PAGE_IN_USE_WAIT = 180
local RELOGIN_TOO_SOON = 60

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
  logged_in_at[ip] = os.time()
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
    local now = os.time()
    local b = blocked[ip]
    if b and now < b[1] then
      return nil, b[2], b[3]
    end
    blocked[ip] = nil
    local w = wrong_until[ip] and wrong_until[ip][password]
    if w and now < w then
      return nil, "login: wrong password (check the device's Settings)", "auth"
    end
    if logged_in_at[ip] and now - logged_in_at[ip] < RELOGIN_TOO_SOON then
      blocked[ip] = { now + PAGE_IN_USE_WAIT, "the module's web page is in use (one login at a time); trying again later", "busy" }
      logged_in_at[ip] = nil
      return nil, blocked[ip][2], "busy"
    end
    local ok, err = Api.login(ip, password)
    if not ok then
      if err == "wrong password" then
        wrong_until[ip] = wrong_until[ip] or {}
        wrong_until[ip][password] = now + WRONG_PASSWORD_WAIT
      end
      return nil, "login: " .. tostring(err), "auth"
    end
    wrong_until[ip] = nil
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
    sessions[ip], blocked[ip], logged_in_at[ip], wrong_until[ip] = nil, nil, nil, nil
  else
    sessions, blocked, logged_in_at, wrong_until = {}, {}, {}, {}
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
  local body, err, kind = get(ip, "/control?cmd=heatpump&" .. escape(key) .. "=" .. escape(value), password)
  if not body then
    return nil, err, kind
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
