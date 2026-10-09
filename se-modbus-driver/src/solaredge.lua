--- SolarEdge SunSpec inverter model (101 single-phase / 102 split-phase /
--- 103 three-phase, "int+SF" variant) register reading and parsing.
---
--- Locates the model dynamically via sunspec.lua's model-chain walk instead
--- of assuming a fixed address — a hardcoded "documented 40069" guess was
--- tried first and produced reserved/sentinel values (0x8000, NaN-producing
--- scale factors) on the actual device, confirming the fixed-address
--- assumption doesn't hold here. All offsets below are relative to the
--- model's OWN data start (i.e. right after its 2-register ID+Length
--- header), which is standard SunSpec and does not vary by device.

local Modbus = require "modbus"
local SunSpec = require "sunspec"
local log = require "log"

local SolarEdge = {}

-- Models 101 (single phase), 102 (split phase), 103 (three phase) share the
-- same fixed-length "int+SF" layout — only which phase fields are populated
-- differs, not the register offsets we care about here.
local INVERTER_MODEL_IDS = { [101] = true, [102] = true, [103] = true }

-- 201 (single phase), 202 (split phase), 203 (wye three phase), 204 (delta
-- three phase) — an optional SolarEdge production/consumption meter (e.g.
-- SE-RGMTR-1D-240C-A) that's a separate SunSpec model in the chain, present
-- only if physically installed. Confirmed present and readable on this
-- system (reports as 203 despite being a single-phase residential
-- installation — SolarEdge's own meter firmware appears to always report
-- 203 regardless of actual wiring; not evidence of a 3-phase installation).
local METER_MODEL_IDS = { [201] = true, [202] = true, [203] = true, [204] = true }

-- Offsets relative to the METER model's data start (right after its own
-- 2-register ID+Length header — confirmed empirically at wire register 190,
-- matching the doc's absolute "40190 M_AC_Current" exactly for this
-- installation's default single-meter addressing).
local METER_OFFSET = {
  AC_POWER = 17,     -- relative 16. Signed: negative = importing from grid
  AC_POWER_SF = 21,  -- (consuming), positive = exporting — confirmed via a
                     -- live night-time reading with the inverter asleep
                     -- (0W production), correctly showing a negative value.
  EXPORTED_HI = 37,  -- relative 36 -- M_Exported (lifetime), uint32
  EXPORTED_LO = 38,  -- relative 37
  IMPORTED_HI = 45,  -- relative 44 -- M_Imported (lifetime), uint32
  IMPORTED_LO = 46,  -- relative 45
  ENERGY_SF = 53,    -- relative 52 -- shared scale factor for both energy totals
  -- Per-phase values (SunSpec meter models 201-204, int+SF). Same block as
  -- above, no extra read. NOTE some single-phase meters report
  -- model 203 with phases B/C at 0 V / 0 W, so
  -- "three-phase" is decided by real voltage on B and C, not by model id.
  PHV_A = 7, PHV_B = 8, PHV_C = 9, -- relative 6..8  PhVphA/B/C (unsigned)
  V_SF = 14,                       -- relative 13
  W_A = 18, W_B = 19, W_C = 20,    -- relative 17..19 WphA/B/C (signed, SF = AC_POWER_SF)
  A_A = 2, A_B = 3, A_C = 4,       -- relative 1..3  AphA/B/C, measured by the meter's CTs
  A_SF = 5,                        -- relative 4
}
local THREE_PHASE_MIN_V = 50 -- a phase counts as present above this voltage
local METER_READ_COUNT = 53 -- covers offsets 1..53 above in one request

-- Offsets relative to the model's data start (right after its header).
local OFFSET = {
  AC_POWER = 13,        -- relative 12 -> registers are 1-indexed in Lua tables
  AC_POWER_SF = 14,
  AC_ENERGY_WH_HI = 23,  -- relative 22
  AC_ENERGY_WH_LO = 24,  -- relative 23
  AC_ENERGY_WH_SF = 25,  -- relative 24
  DC_CURRENT = 26,       -- relative 25
  DC_CURRENT_SF = 27,    -- relative 26
  DC_VOLTAGE = 28,       -- relative 27
  DC_VOLTAGE_SF = 29,    -- relative 28
  DC_POWER = 30,         -- relative 29
  DC_POWER_SF = 31,      -- relative 30
  -- TmpCab immediately follows DCW_SF, no reserved/padding register between
  -- them — an earlier version of this file had a phantom gap here, which
  -- shifted every field from here on by one register and produced garbage
  -- (53060000.0C) that the platform rejected outright.
  --
  -- SunSpec defines four temperature slots (Cabinet/Sink/Transformer/Other);
  -- vendors commonly only populate one, leaving the rest at the "not
  -- implemented" sentinel (raw 0x8000 / -32768). Read all four and use
  -- whichever actually has data — on this SE5000AU, TmpCab itself came back
  -- as the sentinel (confirmed: -327.68 = -32768 * 10^-2 exactly).
  TEMP_CAB = 32,   -- relative 31
  TEMP_SNK = 33,   -- relative 32
  TEMP_TRNS = 34,  -- relative 33
  TEMP_OT = 35,    -- relative 34
  TEMP_SF = 36,    -- relative 35
  STATUS = 37,     -- relative 36
}
local TEMP_SENTINEL_RAW = -32768
local READ_COUNT = 37 -- covers offsets 1..37 above in one request

local STATUS_NAMES = {
  [1] = "OFF", [2] = "SLEEPING", [3] = "STARTING", [4] = "MPPT",
  [5] = "THROTTLED", [6] = "SHUTTING_DOWN", [7] = "FAULT", [8] = "STANDBY",
}

--- Shared read-raw/apply-scale-factor shapes, factored out of what used to
--- be 7 hand-duplicated inline blocks in SolarEdge.read (one per field) --
--- this file has already paid for that duplication once (see OFFSET's own
--- "phantom gap" comment above), so a future register-map revision only
--- needs to get one of these three shapes right per field, not
--- independently re-derive the to_int16-or-not / u32-or-not choice each
--- time.
local function scaled_signed16(regs, value_offset, sf_offset)
  return Modbus.apply_scale_factor(Modbus.to_int16(regs[value_offset]), regs[sf_offset])
end

local function scaled_unsigned16(regs, value_offset, sf_offset)
  return Modbus.apply_scale_factor(regs[value_offset], regs[sf_offset])
end

local function scaled_u32(regs, hi_offset, lo_offset, sf_offset)
  return Modbus.apply_scale_factor(Modbus.registers_to_u32(regs[hi_offset], regs[lo_offset]), regs[sf_offset])
end

-- SolarEdge battery (StorEdge / hybrid) block. Not SunSpec: SolarEdge's own
-- manufacturer-specific holding registers, on the SAME unit ID as the
-- inverter. Battery 1's block starts at 0xE100 (57600); battery 2 at 0xE200.
-- Layout cross-checked against the Home Assistant solaredge-modbus-multi
-- integration (BATTERY_REG_BASE / BatteryInfo / BatteryData), which is
-- widely used with real StorEdge systems. NOTE 0xE000-0xE012 is the storage
-- CONTROL block (control mode, AC charge policy, limits): this driver never
-- reads or writes it. Everything here is read-only (function code 0x03).
--
-- All 32-bit values are little-endian WORD order (low word first). Floats
-- are IEEE-754 float32; 0x7FC00000 (NaN) means "not implemented".
local BATTERY1_READ_START = 57666 -- 0xE142 rated energy, first field read
local BATTERY_READ_COUNT = 70     -- 57666..57735 (rated energy .. status)
-- 1-based indexes into the 70-register read starting at 57666
local BATT_IDX = {
  RATED_ENERGY = 1,  -- 57666 0xE142 float32 Wh (0 / NaN = no battery)
  TEMP_AVG = 43,     -- 57708 0xE16C float32 degC
  DC_VOLTAGE = 47,   -- 57712 0xE170 float32 V
  DC_CURRENT = 49,   -- 57714 0xE172 float32 A
  DC_POWER = 51,     -- 57716 0xE174 float32 W (+ charging, - discharging)
  ENERGY_AVAIL = 63, -- 57728 0xE180 float32 Wh
  SOH = 65,          -- 57730 0xE182 float32 %
  SOE = 67,          -- 57732 0xE184 float32 % (state of energy = charge level)
  STATUS = 69,       -- 57734 0xE186 uint32
}
local BATTERY_STATUS_NAMES = {
  [0] = "Off", [1] = "Standby", [2] = "Initialising", [3] = "Charging",
  [4] = "Discharging", [5] = "Fault", [6] = "Preserve charge", [7] = "Idle",
  [10] = "Power saving",
}

--- float32 from two registers in little-endian word order (low word first).
--- Returns nil for NaN / infinity / the "not implemented" pattern, and for
--- absurd magnitudes (a firmware glitch has been reported returning
--- -3.4e38 for state of energy after a reconnect).
local function float32_le(regs, idx)
  local lo, hi = regs[idx], regs[idx + 1]
  if lo == nil or hi == nil then return nil end
  local bits = (hi << 16) | lo
  if bits == 0x7FC00000 or (bits & 0x7F800000) == 0x7F800000 then return nil end
  local value = string.unpack(">f", string.pack(">I4", bits))
  if value ~= value or value > 1e9 or value < -1e9 then return nil end
  return value
end

local function uint32_le(regs, idx)
  local lo, hi = regs[idx], regs[idx + 1]
  if lo == nil or hi == nil then return nil end
  return (hi << 16) | lo
end

--- Reads battery 1 over an already-open session. Returns a table, or nil
--- when no battery is present (Modbus exception on this range, or a zero /
--- not-implemented rated energy, which is how SolarEdge reports "no
--- battery"). Never raises.
local function read_battery(client)
  local regs, err = client:read_holding_registers(BATTERY1_READ_START, BATTERY_READ_COUNT)
  if not regs then
    log.debug("SolarEdge: no battery block (" .. tostring(err) .. ")")
    return nil
  end
  local rated = float32_le(regs, BATT_IDX.RATED_ENERGY)
  if not rated or rated <= 0 then
    return nil
  end
  local status = uint32_le(regs, BATT_IDX.STATUS)
  local soe = float32_le(regs, BATT_IDX.SOE)
  if soe and (soe < 0 or soe > 100.5) then soe = nil end
  local soh = float32_le(regs, BATT_IDX.SOH)
  if soh and (soh < 0 or soh > 100.5) then soh = nil end
  local temp = float32_le(regs, BATT_IDX.TEMP_AVG)
  if temp and (temp < -60 or temp > 120) then temp = nil end
  return {
    rated_energy_wh = rated,
    soe_pct = soe,
    soh_pct = soh,
    power_w = float32_le(regs, BATT_IDX.DC_POWER),
    voltage_v = float32_le(regs, BATT_IDX.DC_VOLTAGE),
    current_a = float32_le(regs, BATT_IDX.DC_CURRENT),
    energy_available_wh = float32_le(regs, BATT_IDX.ENERGY_AVAIL),
    temp_c = temp,
    status = status,
    status_name = status and (BATTERY_STATUS_NAMES[status] or ("Unknown (" .. tostring(status) .. ")")) or nil,
  }
end

-- Exposed for offline unit tests only.
SolarEdge._float32_le = float32_le
SolarEdge._read_battery = read_battery
SolarEdge._meter_offset = METER_OFFSET

--- Reads and parses one full sample from the inverter.
--- Returns { power_w, energy_wh, dc_voltage, dc_current_a, dc_power_w, temp_c, status, status_name }
--- or nil + error string.
function SolarEdge.read(ip, port, unit_id, timeout_sec)
  local client, err = Modbus.connect(ip, port, timeout_sec)
  if not client then
    return nil, err
  end
  client:set_unit_id(unit_id)

  local model_addr, model_length, model_id = SunSpec.find_model(client, INVERTER_MODEL_IDS)
  if not model_addr then
    client:close()
    return nil, "SunSpec model lookup failed: " .. tostring(model_length) -- model_length holds the error string on failure
  end

  if model_length < READ_COUNT then
    client:close()
    return nil, string.format("inverter model %d is shorter (%d registers) than expected (need %d) — offset table may not match this firmware",
      model_id, model_length, READ_COUNT)
  end

  local regs, read_err = client:read_holding_registers(model_addr, READ_COUNT)
  if not regs then
    client:close()
    return nil, "failed reading inverter model data: " .. tostring(read_err)
  end

  -- Meter is optional — read it in this same session (the inverter only
  -- accepts one Modbus TCP connection at a time, confirmed via the
  -- vendor's technical note, so opening a second connection to check for a
  -- meter would risk contending with this very read). A missing meter is
  -- not an error; just means this installation doesn't have one wired up.
  -- Resume the chain walk from right after the inverter model instead of
  -- re-reading the "SunS" identifier and every earlier model's header
  -- again from address 2 -- model_addr is already that model's DATA start
  -- (post-header), so its own data occupies exactly model_length
  -- registers from there; the next model's header starts right after.
  local meter_addr, meter_length = SunSpec.find_model(client, METER_MODEL_IDS, model_addr + model_length)
  local meter_regs = nil
  if meter_addr and meter_length >= METER_READ_COUNT then
    local meter_read_err
    meter_regs, meter_read_err = client:read_holding_registers(meter_addr, METER_READ_COUNT)
    if not meter_regs then
      -- Unlike a missing meter (meter_addr == nil, silently normal), this
      -- is a meter the model-chain walk DID find but couldn't then read --
      -- worth logging distinctly, since a persistent failure here looks
      -- identical to "no meter installed" everywhere else (the app, this
      -- function's own return value) with no diagnostic trail otherwise.
      log.warn("SolarEdge: grid meter found at model chain address " .. tostring(meter_addr) ..
        " but read failed: " .. tostring(meter_read_err))
    end
  end
  -- Battery is optional hardware, read in the same single session for the
  -- same one-connection-at-a-time reason as the meter. Read-only.
  local battery = read_battery(client)
  client:close()

  local power_w = scaled_signed16(regs, OFFSET.AC_POWER, OFFSET.AC_POWER_SF)
  local energy_wh = scaled_u32(regs, OFFSET.AC_ENERGY_WH_HI, OFFSET.AC_ENERGY_WH_LO, OFFSET.AC_ENERGY_WH_SF)
  local dc_current_a = scaled_unsigned16(regs, OFFSET.DC_CURRENT, OFFSET.DC_CURRENT_SF)
  local dc_voltage = scaled_unsigned16(regs, OFFSET.DC_VOLTAGE, OFFSET.DC_VOLTAGE_SF)
  local dc_power_w = scaled_signed16(regs, OFFSET.DC_POWER, OFFSET.DC_POWER_SF)

  local temp_sf = regs[OFFSET.TEMP_SF]
  local temp_c = nil
  for _, offset_key in ipairs({ "TEMP_CAB", "TEMP_SNK", "TEMP_TRNS", "TEMP_OT" }) do
    local raw = Modbus.to_int16(regs[OFFSET[offset_key]])
    if raw ~= TEMP_SENTINEL_RAW then
      temp_c = Modbus.apply_scale_factor(raw, temp_sf)
      log.info("SolarEdge: using " .. offset_key .. " for temperature (first non-sentinel slot)")
      break
    end
  end
  if not temp_c then
    log.warn("SolarEdge: all four temperature slots are unpopulated (sentinel) on this device")
  end

  local status = regs[OFFSET.STATUS]

  local grid_power_w, grid_exported_wh, grid_imported_wh = nil, nil, nil
  local grid_phases, grid_phase_one = nil, nil
  if meter_regs then
    local va = scaled_unsigned16(meter_regs, METER_OFFSET.PHV_A, METER_OFFSET.V_SF)
    local vb = scaled_unsigned16(meter_regs, METER_OFFSET.PHV_B, METER_OFFSET.V_SF)
    local vc = scaled_unsigned16(meter_regs, METER_OFFSET.PHV_C, METER_OFFSET.V_SF)
    if vb > THREE_PHASE_MIN_V and vc > THREE_PHASE_MIN_V and vb < 1000 and vc < 1000 then
      grid_phases = {
        power = {
          scaled_signed16(meter_regs, METER_OFFSET.W_A, METER_OFFSET.AC_POWER_SF),
          scaled_signed16(meter_regs, METER_OFFSET.W_B, METER_OFFSET.AC_POWER_SF),
          scaled_signed16(meter_regs, METER_OFFSET.W_C, METER_OFFSET.AC_POWER_SF),
        },
        voltage = { va, vb, vc },
        -- Magnitude only; the power sign carries the direction.
        current = {
          math.abs(scaled_signed16(meter_regs, METER_OFFSET.A_A, METER_OFFSET.A_SF)),
          math.abs(scaled_signed16(meter_regs, METER_OFFSET.A_B, METER_OFFSET.A_SF)),
          math.abs(scaled_signed16(meter_regs, METER_OFFSET.A_C, METER_OFFSET.A_SF)),
        },
      }
    end
    grid_phase_one = {
      power = scaled_signed16(meter_regs, METER_OFFSET.W_A, METER_OFFSET.AC_POWER_SF),
      voltage = va,
      current = math.abs(scaled_signed16(meter_regs, METER_OFFSET.A_A, METER_OFFSET.A_SF)),
    }
    grid_power_w = scaled_signed16(meter_regs, METER_OFFSET.AC_POWER, METER_OFFSET.AC_POWER_SF)
    grid_exported_wh = scaled_u32(meter_regs, METER_OFFSET.EXPORTED_HI, METER_OFFSET.EXPORTED_LO, METER_OFFSET.ENERGY_SF)
    grid_imported_wh = scaled_u32(meter_regs, METER_OFFSET.IMPORTED_HI, METER_OFFSET.IMPORTED_LO, METER_OFFSET.ENERGY_SF)
  end

  return {
    power_w = power_w,
    energy_wh = energy_wh,
    dc_voltage = dc_voltage,
    dc_current_a = dc_current_a,
    dc_power_w = dc_power_w,
    temp_c = temp_c,
    status = status,
    status_name = STATUS_NAMES[status] or ("UNKNOWN(" .. tostring(status) .. ")"),
    model_id = model_id,
    grid_power_w = grid_power_w,
    grid_exported_wh = grid_exported_wh,
    grid_imported_wh = grid_imported_wh,
    battery = battery,
    grid_phases = grid_phases, -- nil unless the meter shows real voltage on phases B and C
    grid_phase_one = grid_phase_one, -- L1 power/voltage/current whenever a meter is read
  }
end

return SolarEdge
