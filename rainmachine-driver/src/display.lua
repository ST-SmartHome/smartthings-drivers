--- Text for the program zone slots, the controller's Irrigation Status while
--- a program runs, and the zone history/setup tiles. Pure functions (no
--- SmartThings modules), so they can be tested off the hub.
---
--- Times: RainMachine reports local wall-clock text ("2026-10-18 19:46:15").
--- civil() turns that into seconds on a "local epoch" (the text read as if
--- it were UTC), and the caller passes local_now on the same scale
--- (os.time() plus the offset from machine/time). Everything is formatted
--- with os.date("!..."), so the hub's own time zone never matters.

local M = {}

local NBSP = "\u{00A0}"

-- ===== Text length =====

--- Length as the platform counts it for a schema maxLength (UTF-16 code
--- units: emoji count 2, a variation selector 1).
function M.u16len(s)
  local n = 0
  for _, cp in utf8.codes(s) do
    n = n + (cp >= 0x10000 and 2 or 1)
  end
  return n
end

--- The first variant that fits in max; otherwise the last one cut short.
function M.fit(variants, max)
  for _, v in ipairs(variants) do
    if v and M.u16len(v) <= max then
      return v
    end
  end
  local last = variants[#variants] or ""
  local out, n = {}, 0
  for _, cp in utf8.codes(last) do
    local w = cp >= 0x10000 and 2 or 1
    if n + w > max - 1 then
      break
    end
    out[#out + 1] = utf8.char(cp)
    n = n + w
  end
  return table.concat(out) .. "\u{2026}"
end

-- ===== Time =====

local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end

--- "YYYY-MM-DD", "YYYY-MM-DD HH:MM" or "YYYY-MM-DD HH:MM:SS" to local-epoch seconds.
function M.civil(text)
  local y, mo, d, rest = tostring(text or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
  if not y then
    return nil
  end
  local h, mi, s = rest:match("^[ T](%d%d?):(%d%d):?(%d?%d?)")
  return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
    + (tonumber(h) or 0) * 3600 + (tonumber(mi) or 0) * 60 + (tonumber(s) or 0)
end

function M.clock(t)
  return os.date("!%H:%M", t)
end

local function day_name(t)
  return os.date("!%a", t)
end

local function day_date(t)
  return (os.date("!%a %d %b", t):gsub(" 0", " "):gsub(" ", NBSP))
end

--- "Mon 17:50" within the coming week, "Mon 27 Oct 17:50" further out.
function M.when(t, local_now)
  local label = (local_now and t - local_now < 6 * 86400) and day_name(t) or day_date(t)
  return label .. NBSP .. M.clock(t)
end

--- Whole minutes, rounded; at least 1 for any time at all.
function M.mins(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return 0
  end
  return math.max(1, math.floor(seconds / 60 + 0.5))
end

local function min_text(seconds)
  return M.mins(seconds) .. NBSP .. "min"
end

--- Minutes left on a running zone: rounded up, as the status always has.
local function mins_left(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return 0
  end
  return math.ceil(seconds / 60)
end

-- ===== Codes =====

-- dailystats/details wateringFlag, shortened for the tiles.
M.SKIP_REASONS = {
  [1] = "Stopped", [2] = "Below Threshold", [3] = "Freeze", [4] = "Restricted Day",
  [5] = "Restricted Day", [6] = "Water Surplus", [7] = "Rain Sensor", [8] = "Rain",
  [9] = "Restricted Month", [10] = "Rain Delay", [11] = "Rain",
}

-- zone/properties codes, as RainMachine's apps name them (web UI
-- js/ui-zones.js; 5 Rotors High Rate from the iOS app).
M.VEGETATION = {
  [2] = "Cool Season Grass", [3] = "Fruit Trees", [4] = "Flowers", [5] = "Vegetables", [6] = "Citrus",
  [7] = "Bushes", [9] = "Drought Tolerant Plants", [10] = "Warm Season Grass", [11] = "Trees", [99] = "Custom",
}
M.SOIL = {
  [1] = "Clay Loam", [2] = "Silty Clay", [3] = "Clay", [4] = "Loam", [5] = "Sandy Loam", [6] = "Loamy Sand",
  [7] = "Sand", [8] = "Sandy Clay", [9] = "Silt Loam", [10] = "Silt", [99] = "Custom",
}
M.SPRINKLER = {
  [1] = "Popup Spray", [2] = "Rotors", [3] = "Surface Drip", [4] = "Bubblers Drip", [5] = "Rotors High Rate", [99] = "Custom",
}
M.SLOPE = { [1] = "Flat", [2] = "Moderate", [3] = "High", [4] = "Very High", [99] = "Custom" }
M.EXPOSURE = { [1] = "Full Sun", [2] = "Partial Shade", [3] = "Full Shade" }

function M.setup_text(map, code)
  if code == nil then
    return "Not set"
  end
  return map[tonumber(code)] or "Other"
end

-- ===== Programs =====

--- The program's zones in run order: active wateringTimes entries that
--- aren't the master valve. Each item: {zid, name, duration}.
function M.program_zones(p, is_master)
  local list = {}
  for _, w in ipairs(p.wateringTimes or {}) do
    if w.active and not (is_master and is_master(w.id)) then
      list[#list + 1] = { zid = w.id, name = tostring(w.name), duration = tonumber(w.duration) or 0, order = tonumber(w.order) or 0 }
    end
  end
  table.sort(list, function(a, b)
    if a.order ~= b.order then
      return a.order < b.order
    end
    return a.zid < b.zid
  end)
  return list
end

--- Local-epoch start of the program's next run, or nil (not scheduled, or a
--- sunrise/sunset start, which has no clock time).
function M.program_next_start(p)
  if p.active == false or not p.nextRun then
    return nil
  end
  local params = p.startTimeParams or {}
  if (params.type or 0) ~= 0 then
    return nil
  end
  return M.civil(tostring(p.nextRun) .. " " .. tostring(p.startTime))
end

--- Per-zone plan for the program's next run: {zid, name, seconds, flag,
--- start}. Seconds are RainMachine's calculated time for that day
--- (dailystats/details) when known, otherwise the zone's time scaled by the
--- day's watering percentage. start is nil with cycle & soak (the cycles
--- interleave) or with no clock time.
function M.next_run_plan(p, zones, details, pct_by_day, max_coef)
  local first = M.program_next_start(p)
  local date_key = p.nextRun and tostring(p.nextRun):sub(1, 10)
  local known = details and date_key and details[date_key] and details[date_key][p.uid]
  local coef = (pct_by_day and date_key and pct_by_day[date_key]) and (pct_by_day[date_key] / 100) or 1
  coef = math.min(coef, max_coef or 2)
  local cs = p.cs_on and (tonumber(p.cycles) or 0) > 1
  local delay = (p.delay_on and tonumber(p.delay)) or 0
  local plan, t = {}, first
  for i, z in ipairs(zones) do
    local secs, flag = nil, nil
    local kz = known and known.zones and known.zones[z.zid]
    if kz then
      secs, flag = kz.seconds, kz.flag
    else
      secs = z.duration * coef
    end
    local item = { zid = z.zid, name = z.name, seconds = secs, flag = flag }
    if t and not cs and secs > 0 then
      item.start = t
      t = t + secs + delay
    end
    plan[i] = item
  end
  return plan
end

local function skip_text(flag)
  return "skipped:" .. NBSP .. (M.SKIP_REASONS[flag] or "no water needed")
end

--- Queue entries for a program, grouped by zone: {running, seconds left in
--- all its cycles, first entry, start offset}. ahead counts every entry in
--- the whole queue before this zone's first one (other programs and zones
--- started on their own included).
local function queue_by_zone(queue, pid, delay)
  local by_zid, ahead, seen_pid = {}, 0, false
  for _, e in ipairs(queue or {}) do
    local remaining = tonumber(e.remaining) or 0
    if e.pid == pid and e.zid then
      if seen_pid and delay > 0 then
        ahead = ahead + delay
      end
      local g = by_zid[e.zid]
      if not g then
        g = { seconds = 0, offset = ahead, cycle = tonumber(e.cycle), cycles = tonumber(e.cycles) }
        by_zid[e.zid] = g
      end
      g.seconds = g.seconds + remaining
      if e.running then
        g.running = true
        g.cycle = tonumber(e.cycle)
      end
      seen_pid = true
    end
    ahead = ahead + remaining
  end
  return by_zid
end

local function cycle_text(g)
  if g.cycles and g.cycles > 1 and g.cycle then
    return " cycle" .. NBSP .. g.cycle .. "/" .. g.cycles
  end
  return ""
end

M.ICON_RUNNING = "\u{1F4A6}"
M.ICON_QUEUED = "\u{23F3}"
M.ICON_DONE = "\u{2705}"

--- Programs that own the queue right now, and the queue with leftovers
--- assigned to them. A zone cut short in the RainMachine app is queued
--- again on its own (no pid) for the rest of its time; while its program
--- is running, or was on the last poll (carried), such an entry belongs to
--- that program, so the program page and the controller status follow it.
--- zone_sets: pid -> {zid = true}. Returns the new queue and the set of
--- active pids (pass it back as carried on the next poll).
function M.adopt(queue, zone_sets, carried)
  local active = {}
  for _, e in ipairs(queue or {}) do
    if e.pid and e.pid ~= 0 then
      active[e.pid] = true
    end
  end
  local owners = {}
  for pid in pairs(carried or {}) do
    owners[#owners + 1] = pid
  end
  for pid in pairs(active) do
    owners[#owners + 1] = pid
  end
  table.sort(owners)
  local out = {}
  for i, e in ipairs(queue or {}) do
    out[i] = e
    if not e.pid or e.pid == 0 then
      for _, pid in ipairs(owners) do
        if zone_sets[pid] and zone_sets[pid][e.zid] then
          local copy = {}
          for k, v in pairs(e) do
            copy[k] = v
          end
          copy.pid = pid
          out[i] = copy
          active[pid] = true
          break
        end
      end
    end
  end
  return out, active
end

--- Slot texts for a program device, in display order.
--- ctx: {queue, local_now, details, pct_by_day, max_coef, seen}. seen[pid]
--- is the set of zones that have been in the queue during this run: a zone
--- no longer queued is done if it was seen, skipped if it never was.
function M.program_slots(p, zones, ctx)
  local delay = (p.delay_on and tonumber(p.delay)) or 0
  local groups = queue_by_zone(ctx.queue, p.uid, delay)
  -- Only queue entries for zones on this list count (a zone made inactive
  -- mid-run can still be queued).
  local first_pos
  for i, z in ipairs(zones) do
    if groups[z.zid] then
      first_pos = first_pos or i
    end
  end
  local out = {}
  if first_pos then
    -- Running: zones before the first queued one have finished; zones after
    -- it that aren't queued were skipped by RainMachine.
    local seen = ctx.seen and ctx.seen[p.uid] or {}
    local done, active, skipped = {}, {}, {}
    for i, z in ipairs(zones) do
      local g = groups[z.zid]
      if g then
        active[#active + 1] = { z = z, g = g }
      elseif seen[z.zid] or i < first_pos then
        done[#done + 1] = M.ICON_DONE .. " " .. z.name .. " done"
      else
        skipped[#skipped + 1] = z.name .. " skipped"
      end
    end
    table.sort(active, function(a, b)
      if a.g.running ~= b.g.running then
        return a.g.running == true
      end
      return a.g.offset < b.g.offset
    end)
    for _, t in ipairs(done) do
      out[#out + 1] = t
    end
    for _, a in ipairs(active) do
      if a.g.running then
        out[#out + 1] = M.ICON_RUNNING .. " " .. a.z.name .. " " .. mins_left(a.g.seconds) .. NBSP .. "min left" .. cycle_text(a.g)
      else
        local text = M.ICON_QUEUED .. " " .. a.z.name .. " " .. min_text(a.g.seconds)
        if ctx.local_now then
          text = text .. " starts" .. NBSP .. M.clock(ctx.local_now + a.g.offset)
        end
        out[#out + 1] = text
      end
    end
    for _, t in ipairs(skipped) do
      out[#out + 1] = t
    end
    return out
  end
  -- Idle: today's calculated minutes and each zone's next start.
  for _, item in ipairs(M.next_run_plan(p, zones, ctx.details, ctx.pct_by_day, ctx.max_coef)) do
    if item.seconds <= 0 then
      out[#out + 1] = item.name .. " " .. skip_text(item.flag)
    else
      local text = item.name .. " " .. min_text(item.seconds)
      if item.start then
        text = text .. " " .. M.when(item.start, ctx.local_now)
      end
      out[#out + 1] = text
    end
  end
  return out
end

--- A zone's time in its next scheduled program, weather adjusted (that
--- run's calculated seconds, entry.items from next_run_plan), in whole
--- minutes for the Watering Time slider (1–120). Falls back to the
--- program's set time when that run skips the zone. nil when no scheduled
--- program waters the zone. entries: {p, zones, items} per program.
function M.program_minutes(zid, entries)
  local best_key, best
  for _, entry in ipairs(entries) do
    local p = entry.p
    local day = p.active ~= false and M.civil(p.nextRun)
    if day then
      for i, z in ipairs(entry.zones) do
        if z.zid == zid and z.duration > 0 then
          local key = M.program_next_start(p) or (day + 86399)
          if not best_key or key < best_key then
            local item = entry.items and entry.items[i]
            best_key = key
            best = (item and item.seconds and item.seconds > 0) and item.seconds or z.duration
          end
        end
      end
    end
  end
  if not best then
    return nil
  end
  return math.max(1, math.min(120, math.floor(best / 60 + 0.5)))
end

-- ===== Controller status =====

--- "Evening: Zone 1 5 min, done 20:30" while a program's zone is
--- running. nil when nothing is running or the running zone was started on
--- its own (the caller keeps the existing text then).
function M.program_status(queue, program_names, zone_names, local_now, max)
  local running
  for _, e in ipairs(queue or {}) do
    if e.running then
      running = e
      break
    end
  end
  if not running or not running.pid or running.pid == 0 or not program_names[running.pid] or not local_now then
    return nil
  end
  local total, others, other_seen, extra = 0, {}, {}, false
  for _, e in ipairs(queue) do
    total = total + (tonumber(e.remaining) or 0)
    if e.pid ~= running.pid then
      extra = true
      local name = e.pid and program_names[e.pid]
      if name and not other_seen[e.pid] then
        other_seen[e.pid] = true
        others[#others + 1] = name
      end
    end
  end
  local prog = program_names[running.pid]
  local zone = zone_names[running.zid] or ("Zone " .. tostring(running.zid))
  local finish = (extra and "all done" or "done") .. NBSP .. M.clock(local_now + total)
  local left = mins_left(running.remaining) .. NBSP .. "min"
  local variants = {}
  if #others > 0 then
    variants[#variants + 1] = prog .. ": " .. zone .. " " .. left .. ", then " .. table.concat(others, ", ") .. ", " .. finish
    variants[#variants + 1] = prog .. ": " .. zone .. " " .. left .. ", then " .. others[1] .. ", " .. finish
  end
  variants[#variants + 1] = prog .. ": " .. zone .. " " .. left .. ", " .. finish
  variants[#variants + 1] = prog .. ": " .. zone .. ", " .. finish
  variants[#variants + 1] = zone .. " " .. left .. ", " .. finish
  -- Last resort: cut the program name, never the finish time.
  local tail = ", " .. finish
  local room = max - M.u16len(tail)
  variants[#variants + 1] = M.fit({ zone .. " " .. left }, room) .. tail
  return M.fit(variants, max)
end

-- ===== Zone history =====

--- From watering/log/details: per zone {last = local-epoch start of the
--- latest run, last_seconds, week_seconds (since week_start)}. A run is the
--- zone's cycles in one program block that day, within 2 h of each other.
function M.zone_history(log, week_start)
  local by_zid = {}
  local days = log and log.waterLog and log.waterLog.days or {}
  for _, day in ipairs(days) do
    for _, prog in ipairs(day.programs or {}) do
      for _, z in ipairs(prog.zones or {}) do
        local h = by_zid[z.uid] or { week_seconds = 0 }
        by_zid[z.uid] = h
        local cycles = {}
        for _, c in ipairs(z.cycles or {}) do
          local secs = tonumber(c.realDuration) or 0
          local t = M.civil(c.startTime)
          if t and secs > 0 then
            cycles[#cycles + 1] = { t = t, secs = secs }
            if week_start and t >= week_start then
              h.week_seconds = h.week_seconds + secs
            end
          end
        end
        table.sort(cycles, function(a, b) return a.t < b.t end)
        local latest = cycles[#cycles]
        if latest then
          local first, total = latest.t, 0
          for i = #cycles, 1, -1 do
            if latest.t - cycles[i].t > 7200 then
              break
            end
            first = cycles[i].t
            total = total + cycles[i].secs
          end
          if not h.last or first > h.last then
            h.last, h.last_seconds = first, total
          end
        end
      end
    end
  end
  return by_zid
end

function M.last_watered_text(h, local_now, days)
  if not h or not h.last then
    return "Not in the last " .. days .. " days"
  end
  local secs = h.last_seconds or 0
  local dur = secs < 30 and ("<1" .. NBSP .. "min") or min_text(secs)
  return day_date(h.last) .. NBSP .. M.clock(h.last) .. " " .. dur
end

function M.week_text(h)
  local secs = h and h.week_seconds or 0
  if secs <= 0 then
    return "0" .. NBSP .. "min"
  end
  if secs < 30 then
    return "<1" .. NBSP .. "min"
  end
  return min_text(secs)
end

--- The zone's next scheduled watering across all active programs:
--- "Mon 17:50 10 min" or "Mon 17:50 skipped: Rain".
function M.zone_next_text(zid, plans, local_now)
  local best
  for _, plan in ipairs(plans) do
    for _, item in ipairs(plan.items) do
      if item.zid == zid then
        local t = item.start or plan.first
        if t and (not best or t < best.t) then
          best = { t = t, item = item, exact = item.start ~= nil }
        end
      end
    end
  end
  if not best then
    return "None scheduled"
  end
  local when = best.exact and M.when(best.t, local_now) or (os.date("!%a", best.t))
  if best.item.seconds <= 0 then
    return when .. " " .. skip_text(best.item.flag)
  end
  return when .. " " .. min_text(best.item.seconds)
end

return M
