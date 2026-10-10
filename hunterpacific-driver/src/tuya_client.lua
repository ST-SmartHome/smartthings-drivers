--- Connects to a Skyfan DC over its local Tuya TCP port (6668), sends one
--- framed command, reads the response, and closes. One connection per
--- request rather than a held-open session — simpler and more robust to
--- reason about in an Edge Driver's cooperative-scheduling model, same
--- choice made for the SolarEdge Modbus client.

local socket = require "cosock.socket"
local log = require "log"
local Tuya = require "tuya_protocol"
local Tuya35 = require "tuya35"

local TUYA_PORT = 6668

local TuyaClient = {}
local sequence = 0

-- Lua 5.3 doesn't seed math.random; 3.5's GCM IVs and nonces need it.
math.randomseed(math.floor((socket.gettime() * 1000000) % 2147483647))

-- Protocol per fan ("3.3" or "3.5"), keyed by ip|device_id, learned at
-- runtime (2026-10-09). Not a preference: the existing protocolVersion
-- preference was never read by the driver, and editing a live profile's
-- preferences is risky (it can reset saved values). A fan is marked 3.5
-- only after a 3.5 handshake proves it holds this local_key, which a 3.3
-- fan can never do. A fan marked 3.3 (it answered 3.3 since the driver
-- started) is never probed with 3.5.
local protocol_for = {}

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

--- Reads exactly one full 3.5 frame off `sock`.
local function read_frame35(sock)
  local header, err = sock:receive(18)
  if not header then
    return nil, "header receive failed: " .. tostring(err)
  end
  local total_length = Tuya35.expected_length(header)
  if not total_length then
    return nil, "not a 3.5 frame"
  end
  local rest
  rest, err = sock:receive(total_length - 18)
  if not rest then
    return nil, "body receive failed: " .. tostring(err)
  end
  return header .. rest
end

--- Protocol 3.5: opens a connection, negotiates a session key, sends one
--- command and returns the parsed reply to it. Returns reply, or nil, error,
--- handshake_ok.
local function send35(ip, local_key, command, plaintext, timeout_sec)
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

  local function send(bytes) return sock:send(bytes) end
  local function read() return read_frame35(sock) end

  local session_key, neg_err, handshake_ok = Tuya35.negotiate(send, read, local_key, next_sequence)
  if not session_key then
    sock:close()
    return nil, neg_err, handshake_ok
  end

  local sent, send_err = sock:send(Tuya35.encode(command, next_sequence(), plaintext, session_key))
  if not sent then
    sock:close()
    return nil, "send failed: " .. tostring(send_err), true
  end

  -- The reply to our command can be preceded by an unsolicited status push
  -- (0x08); skip anything that isn't the reply, up to a few frames.
  for _ = 1, 4 do
    local frame, read_err = read_frame35(sock)
    if not frame then
      sock:close()
      return nil, read_err, true
    end
    local reply_command, reply = Tuya35.decode(frame, session_key)
    if not reply_command then
      sock:close()
      return nil, reply, true
    end
    if reply_command == command then
      sock:close()
      return Tuya35.parse_payload(reply), nil, true
    end
  end
  sock:close()
  return nil, "no reply to command " .. command, true
end

--- Sends `payload_table` as `command` and returns the decoded response
--- table, or nil, error. `local_key` must be the raw 16-byte key string.
--- Protocol 3.3 only.
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

--- Queries current status of all DPs over protocol 3.3.
local function query_status33(ip, local_key, device_id, timeout_sec)
  local payload = {gwId = device_id, devId = device_id, uid = device_id, t = tostring(os.time())}
  local response, err = TuyaClient.send(ip, local_key, Tuya.COMMAND.DP_QUERY, payload, timeout_sec)
  if not response then
    return nil, err
  end

  log.info("Hunter Pacific fan raw response: command=" .. tostring(response.command) ..
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
local function set_dps33(ip, local_key, device_id, dps, timeout_sec)
  local payload = {devId = device_id, uid = device_id, t = tostring(os.time()), dps = dps}
  local response, err = TuyaClient.send(ip, local_key, Tuya.COMMAND.CONTROL, payload, timeout_sec)
  if not response then
    return nil, err
  end
  return true
end

local function query_status35(ip, local_key, timeout_sec)
  local reply, err, handshake_ok = send35(ip, local_key, Tuya35.COMMAND.DP_QUERY_NEW,
    Tuya35.query_plaintext(), timeout_sec)
  if not reply then
    return nil, err, handshake_ok
  end
  if type(reply) ~= "table" or type(reply.dps) ~= "table" then
    return nil, "3.5 status reply had no dps field", true
  end
  return reply.dps, nil, true
end

--- Queries current status of all DPs. Returns a table of {[dp_id_string] = value}.
--- Picks 3.3 or 3.5 per fan (see protocol_for above).
function TuyaClient.query_status(ip, local_key, device_id, timeout_sec)
  local id = ip .. "|" .. device_id
  if protocol_for[id] == "3.5" then
    return query_status35(ip, local_key, timeout_sec)
  end

  local dps, err = query_status33(ip, local_key, device_id, timeout_sec)
  if dps then
    protocol_for[id] = "3.3"
    return dps
  end

  -- A 3.5 fan ignores 3.3 frames, so the read times out. Resets and refused
  -- connections are the known 3.3 "first connection after idle" problem,
  -- not a protocol mismatch, so they never trigger a 3.5 attempt.
  if protocol_for[id] == nil and tostring(err):find("timeout") then
    local dps35, err35, handshake_ok = query_status35(ip, local_key, timeout_sec)
    if handshake_ok then
      protocol_for[id] = "3.5"
      log.info("Hunter Pacific fan at " .. ip .. " speaks Tuya protocol 3.5; using it from now on")
    end
    if dps35 then
      return dps35
    end
    log.debug("3.5 attempt at " .. ip .. " failed too: " .. tostring(err35))
  end
  return nil, err
end

--- Sets one or more DPs. `dps` is a table like {["1"] = true, ["3"] = 4}.
function TuyaClient.set_dps(ip, local_key, device_id, dps, timeout_sec)
  local id = ip .. "|" .. device_id
  if protocol_for[id] == nil then
    -- Protocol not learned yet (a command arrived before the first poll
    -- after a restart): a status query learns it, so a 3.5 fan isn't sent
    -- 3.3 writes it will never answer.
    TuyaClient.query_status(ip, local_key, device_id, timeout_sec)
  end
  if protocol_for[id] == "3.5" then
    local reply, err = send35(ip, local_key, Tuya35.COMMAND.CONTROL_NEW,
      Tuya35.control_plaintext(dps), timeout_sec)
    if not reply then
      return nil, err
    end
    return true
  end
  return set_dps33(ip, local_key, device_id, dps, timeout_sec)
end

--- Test hook.
TuyaClient._protocol_for = protocol_for

return TuyaClient
