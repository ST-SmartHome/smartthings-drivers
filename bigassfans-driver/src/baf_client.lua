-- Connects to a Big Ass Fans i6 device over its local TCP port (31415),
-- sends one SLIP-framed protobuf command, reads the response frame, and
-- closes. One connection per request rather than a held-open session —
-- same choice made for the Tuya and SolarEdge Modbus clients in the
-- sibling drivers, simpler to reason about in an Edge Driver's
-- cooperative-scheduling model than aiobafi6's persistent-connection/push
-- design. No authentication or encryption — confirmed empirically.

local socket = require "cosock.socket"
local slip = require "slip"
local baf = require "baf_protocol"

local BAF_PORT = 31415
local MAX_FRAME_BYTES = 8192 -- safety cap against a runaway/garbled stream

local BafClient = {}

--- Reads one complete SLIP frame (leading 0xC0 through the next 0xC0) off
--- `sock`, byte by byte since SLIP has no length prefix to read ahead by.
--- Returns the raw framed bytes (including both delimiters), or nil, error.
local function read_slip_frame(sock)
  local first, err = sock:receive(1)
  if not first then
    return nil, "read failed waiting for start delimiter: " .. tostring(err)
  end
  if first ~= slip.END_BYTE then
    return nil, "expected SLIP start delimiter, got byte " .. string.byte(first)
  end

  local chunks = { first }
  local total = 1
  while true do
    local b, recv_err = sock:receive(1)
    if not b then
      return nil, "read failed waiting for end delimiter: " .. tostring(recv_err)
    end
    chunks[#chunks + 1] = b
    total = total + 1
    if b == slip.END_BYTE then
      break
    end
    if total > MAX_FRAME_BYTES then
      return nil, "SLIP frame exceeded " .. MAX_FRAME_BYTES .. " bytes without a closing delimiter"
    end
  end
  return table.concat(chunks)
end

--- Sends a Query for `category_name` (a key of baf.QUERY_CATEGORY, e.g.
--- "FAN") and returns the parsed property table for that category, or
--- nil, error. Opens and closes its own connection — prefer
--- BafClient.query_multi when querying more than one category, so a poll
--- cycle doesn't open more TCP connections than it needs to (see there for
--- why that matters on this device).
function BafClient.query(ip, category_name, timeout_sec)
  local results, err = BafClient.query_multi(ip, { category_name }, timeout_sec)
  if not results then
    return nil, err
  end
  return results[category_name]
end

--- Sends a Query for each category in `category_names` (a list of keys of
--- baf.QUERY_CATEGORY, e.g. { "FAN", "LIGHT" }) over a single shared TCP
--- connection — one connect, N request/response round trips, one close —
--- and returns a table keyed by category name.
---
--- Deliberately NOT one Query message listing multiple categories: the
--- wire schema's Query.property_query field is a lone enum, not a repeated
--- one (see baf.build_query), and there's no confirmed evidence the real
--- device accepts more than one category per Query anyway. This achieves
--- the same reduction in connection count without depending on unverified
--- protocol behavior — same number of request/response exchanges as
--- before, just sequenced over one connection instead of opening a fresh
--- one per category.
---
--- Found 2026-08-13: this driver's default 30s poll cycle was opening two
--- fresh TCP connections per fan (one per category) — the fans' Wi-Fi
--- links started showing frequent disconnect/reconnect/roam events only
--- after this driver began polling them, strongly suggesting the
--- connection churn was overloading their embedded TCP stack. Each
--- reconnect is the suspected cause of intermittent, sub-poll-interval
--- light blips too brief for a 30s poll to ever observe as a state change
--- (confirmed: SmartThings device history showed no anomalous switch/level
--- events, which is what you'd expect either way at this poll interval).
--- Halving the connection count per poll is the direct fix for the
--- suspected cause; if reconnects continue at a similar rate after this
--- ships, the connection count wasn't the (whole) story and the poll
--- interval itself should be the next thing raised, not lowered further.
function BafClient.query_multi(ip, category_names, timeout_sec)
  local sock, err = socket.tcp()
  if not sock then
    return nil, "socket create failed: " .. tostring(err)
  end
  sock:settimeout(timeout_sec or 5)

  local ok, connect_err = sock:connect(ip, BAF_PORT)
  if not ok then
    sock:close()
    return nil, "connect failed: " .. tostring(connect_err)
  end

  local results = {}
  for _, category_name in ipairs(category_names) do
    local category = baf.QUERY_CATEGORY[category_name]
    if not category then
      sock:close()
      return nil, "unknown query category '" .. tostring(category_name) .. "'"
    end

    local message = baf.build_query(category)
    local sent, send_err = sock:send(slip.encode(message))
    if not sent then
      sock:close()
      return nil, "send failed for category '" .. category_name .. "': " .. tostring(send_err)
    end

    local frame, read_err = read_slip_frame(sock)
    if not frame then
      sock:close()
      return nil, "read failed for category '" .. category_name .. "': " .. tostring(read_err)
    end

    local payload = slip.decode(frame)
    local result = baf.parse_category_result(payload, category_name)
    if not result then
      sock:close()
      return nil, "response had no query_result for category '" .. category_name .. "'"
    end
    results[category_name] = result
  end

  sock:close()
  return results
end

--- Sends a Commit setting one or more properties (see baf.build_commit for
--- the shape of `props`). The fan applies the change and the next poll's
--- query picks up the new state; this call itself only confirms the send
--- succeeded, not that the fan accepted/applied it.
function BafClient.commit(ip, props, timeout_sec)
  local sock, err = socket.tcp()
  if not sock then
    return nil, "socket create failed: " .. tostring(err)
  end
  sock:settimeout(timeout_sec or 5)

  local ok, connect_err = sock:connect(ip, BAF_PORT)
  if not ok then
    sock:close()
    return nil, "connect failed: " .. tostring(connect_err)
  end

  local message = baf.build_commit(props)
  local sent, send_err = sock:send(slip.encode(message))
  sock:close()
  if not sent then
    return nil, "send failed: " .. tostring(send_err)
  end
  return true
end

return BafClient
