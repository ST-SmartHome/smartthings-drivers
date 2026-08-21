--- Connects to a Skyfan DC over its local Tuya TCP port (6668), sends one
--- framed command, reads the response, and closes. One connection per
--- request rather than a held-open session — simpler and more robust to
--- reason about in an Edge Driver's cooperative-scheduling model, same
--- choice made for the SolarEdge Modbus client.

local socket = require "cosock.socket"
local log = require "log"
local Tuya = require "tuya_protocol"

local TUYA_PORT = 6668

local TuyaClient = {}
local sequence = 0

local function next_sequence()
  sequence = (sequence + 1) % 0xFFFFFFFF
  return sequence
end

--- Reads exactly one full Tuya frame off `sock`. Returns the raw bytes or nil, error.
local function read_frame(sock)
  local header, err = sock:receive(16)
  if not header then
    return nil, "header receive failed: " .. tostring(err)
  end

  local total_length = Tuya.expected_length(header)
  if not total_length then
    return nil, "could not determine message length from header"
  end

  local remaining = total_length - 16
  local rest = ""
  if remaining > 0 then
    rest, err = sock:receive(remaining)
    if not rest then
      return nil, "body receive failed: " .. tostring(err)
    end
  end

  return header .. rest
end

--- Sends `payload_table` as `command` and returns the decoded response
--- table, or nil, error. `local_key` must be the raw 16-byte key string.
function TuyaClient.send(ip, local_key, command, payload_table, timeout_sec)
  local sock, err = socket.tcp()
  if not sock then
    return nil, "socket create failed: " .. tostring(err)
  end
  sock:settimeout(timeout_sec or 5)

  local ok, connect_err = sock:connect(ip, TUYA_PORT)
  if not ok then
    sock:close()
    return nil, "connect failed: " .. tostring(connect_err)
  end

  local message = Tuya.encode(command, payload_table, local_key, next_sequence())
  local sent, send_err = sock:send(message)
  if not sent then
    sock:close()
    return nil, "send failed: " .. tostring(send_err)
  end

  local frame, read_err = read_frame(sock)
  sock:close()
  if not frame then
    return nil, read_err
  end

  local decoded, decode_err = Tuya.decode(frame, local_key)
  if not decoded then
    return nil, decode_err
  end

  return decoded
end

--- Queries current status of all DPs. Returns a table of {[dp_id_string] = value}.
function TuyaClient.query_status(ip, local_key, device_id, timeout_sec)
  local payload = {gwId = device_id, devId = device_id, uid = device_id, t = tostring(os.time())}
  local response, err = TuyaClient.send(ip, local_key, Tuya.COMMAND.DP_QUERY, payload, timeout_sec)
  if not response then
    return nil, err
  end

  log.info("Skyfan DC raw response: command=" .. tostring(response.command) ..
    " payload=" .. tostring(response.payload) .. " (type " .. type(response.payload) .. ")")

  if type(response.payload) ~= "table" then
    return nil, "response payload was not a table (got " .. type(response.payload) .. ": " .. tostring(response.payload) .. ")"
  end

  local dps = response.payload.dps
  if not dps then
    return nil, "response had no dps field"
  end
  return dps
end

--- Sets one or more DPs. `dps` is a table like {["1"] = true, ["3"] = 4}.
--- Uses the older CONTROL command (0x07), not CONTROL_NEW (0x0D) — confirmed
--- 2026-08-20 this fan's firmware silently drops every CONTROL_NEW request
--- (TCP-acks it, never sends an application response) regardless of framing,
--- but responds normally to CONTROL. Root-caused via a standalone reference
--- implementation (jasonacox/tinytuya) succeeding against the same device
--- where this driver's original CONTROL_NEW send did not; see
--- skyfan-driver-project-status memory for the full investigation. Paired
--- with the encode()-side header fix in tuya_protocol.lua — both were
--- required together, neither alone was sufficient.
function TuyaClient.set_dps(ip, local_key, device_id, dps, timeout_sec)
  local payload = {devId = device_id, uid = device_id, t = tostring(os.time()), dps = dps}
  local response, err = TuyaClient.send(ip, local_key, Tuya.COMMAND.CONTROL, payload, timeout_sec)
  if not response then
    return nil, err
  end
  return true
end

return TuyaClient
