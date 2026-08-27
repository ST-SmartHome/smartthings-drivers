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
--- Sends every category's query up front, then reads responses back
--- matched to a category by CONTENT (which known fields a frame actually
--- contains), not by assuming the Nth frame read answers the Nth query
--- sent. Found 2026-08-27: the fan's responses to back-to-back queries
--- on one connection do not reliably arrive in send order once more than
--- one category is involved — confirmed against the real deployed code,
--- affects the plain 2-category {"FAN","LIGHT"} call too, not just a
--- newly-added third category. See baf_protocol.lua's
--- parse_frame_fields and the project-status memory entry on this for
--- the full story and how it was confirmed.
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

  -- Validate every category up front so a typo fails before any I/O.
  for _, category_name in ipairs(category_names) do
    if not baf.QUERY_CATEGORY[category_name] then
      sock:close()
      return nil, "unknown query category '" .. tostring(category_name) .. "'"
    end
  end

  -- Send every query up front -- see the header comment above for why
  -- reading is no longer paired one-for-one with sending.
  for _, category_name in ipairs(category_names) do
    local message = baf.build_query(baf.QUERY_CATEGORY[category_name])
    local sent, send_err = sock:send(slip.encode(message))
    if not sent then
      sock:close()
      return nil, "send failed for category '" .. category_name .. "': " .. tostring(send_err)
    end
  end

  -- Pre-fill defaults per requested category, same as parse_category_result
  -- always has -- a field genuinely at its zero value can be omitted by
  -- the fan entirely, in any frame, so "never arrived" and "arrived as
  -- its default" have to look the same here.
  local results = {}
  local wanted = {}
  for _, category_name in ipairs(category_names) do
    wanted[category_name] = true
    local defaults = {}
    for field_name, def in pairs(baf.FIELDS) do
      if def.category == category_name and def.default ~= nil then
        defaults[field_name] = def.default
      end
    end
    results[category_name] = defaults
  end

  -- Read frames and, for each known field found, credit it to whichever
  -- requested category that field actually belongs to (baf.FIELDS is the
  -- source of truth, not the frame's position in the read sequence). A
  -- category counts as satisfied once at least one of its fields has
  -- shown up in some frame. Some headroom over category_names' own count
  -- since a stray/unrelated frame (or a category's response arriving as
  -- more than one chunk) shouldn't immediately exhaust the budget.
  local satisfied = {}
  local satisfied_count = 0
  local total_wanted = #category_names
  local max_frames = total_wanted + 4
  for _ = 1, max_frames do
    if satisfied_count >= total_wanted then
      break
    end
    local frame = read_slip_frame(sock)
    if not frame then
      break -- out of frames or timed out -- stop, evaluate what we got
    end
    local payload = slip.decode(frame)
    local found = baf.parse_frame_fields(payload)
    if found then
      for category_name in pairs(wanted) do
        for field_name, value in pairs(found) do
          local def = baf.FIELDS[field_name]
          if def.category == category_name then
            results[category_name][field_name] = value
            if not satisfied[category_name] then
              satisfied[category_name] = true
              satisfied_count = satisfied_count + 1
            end
          end
        end
      end
    end
  end

  sock:close()

  for _, category_name in ipairs(category_names) do
    if not satisfied[category_name] then
      return nil, "no response ever matched category '" .. category_name .. "'"
    end
  end

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

--- Commits one or more MORE-category properties (led_indicators_enable /
--- fan_beep_enable / legacy_ir_remote_enable — see baf_protocol.lua) and
--- attempts to verify them via the fan's own unsolicited push frames.
---
--- Confirmed empirically 2026-08-26 against a real fan: these three
--- fields are never returned by a direct category query, in any of the 7
--- known categories, in either field state — the official app instead
--- holds one persistent connection and the fan pushes them unsolicited
--- shortly after any commit. The push only happens on a connection that
--- began with an identity query first: a bare commit with no prior query
--- got zero pushes in 8s (a real negative control), while the identical
--- commit preceded by a FIRMWARE_MORE_DATETIME_API query got a burst of
--- ~5 frames within ~0.2s, with the just-committed field's new value
--- visible partway through the burst.
---
--- Deliberately a separate function from BafClient.commit/query_multi
--- rather than folded into their normal path — those stay a plain,
--- minimal connect→request→read→close, unmodified, for every other
--- field. Only ever call this for MORE-category properties.
---
--- Returns `sent_ok, verified_table, err`. `sent_ok` is true once the
--- commit itself has gone out (the identity-query preamble and read
--- burst can still fail without meaning the write failed — same
--- fire-and-forget caveat as BafClient.commit). `verified_table` maps
--- each requested field name to the value actually observed in the push
--- burst, if any showed up (a field committed but never confirmed within
--- the read window is simply absent from this table, not set to a wrong
--- value — check for its presence, don't assume it's there).
function BafClient.commit_and_verify_more(ip, props, timeout_sec)
  local sock, err = socket.tcp()
  if not sock then
    return false, nil, "socket create failed: " .. tostring(err)
  end
  sock:settimeout(timeout_sec or 5)

  local ok, connect_err = sock:connect(ip, BAF_PORT)
  if not ok then
    sock:close()
    return false, nil, "connect failed: " .. tostring(connect_err)
  end

  -- Identity query first -- this is what unlocks the push burst below.
  -- The response's actual content (name/model/mac/etc, same as any
  -- ALL/FIRMWARE_MORE_DATETIME_API query) is unused; sending it and
  -- reading the one response is what matters, not what's in it.
  local identity_msg = baf.build_query(baf.QUERY_CATEGORY.FIRMWARE_MORE_DATETIME_API)
  local identity_sent, identity_send_err = sock:send(slip.encode(identity_msg))
  if not identity_sent then
    sock:close()
    return false, nil, "identity query send failed: " .. tostring(identity_send_err)
  end
  local identity_frame, identity_read_err = read_slip_frame(sock)
  if not identity_frame then
    sock:close()
    return false, nil, "identity query read failed: " .. tostring(identity_read_err)
  end

  local commit_msg = baf.build_commit(props)
  local commit_sent, commit_send_err = sock:send(slip.encode(commit_msg))
  if not commit_sent then
    sock:close()
    return false, nil, "commit send failed: " .. tostring(commit_send_err)
  end

  -- Read the fan's push burst: several small frames arrive back-to-back
  -- within ~0.2s on a real device, then stop. A short per-frame timeout
  -- (rather than one long overall deadline) naturally ends the loop once
  -- the burst is over, without needing wall-clock bookkeeping -- cosock's
  -- socket doesn't expose a gettime() this driver already depends on
  -- elsewhere, so this avoids adding that dependency for one function.
  sock:settimeout(0.3)
  local verified = {}
  for _ = 1, 12 do -- generous headroom over the ~5 frames observed live
    local frame = read_slip_frame(sock)
    if not frame then
      break
    end
    local payload = slip.decode(frame)
    local result = baf.parse_category_result(payload, "MORE_PUSH")
    if result then
      for name in pairs(props) do
        if result[name] ~= nil then
          verified[name] = result[name]
        end
      end
    end
  end

  sock:close()
  return true, verified
end

return BafClient
