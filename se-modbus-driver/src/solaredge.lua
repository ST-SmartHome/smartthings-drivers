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
}
local METER_READ_COUNT = 53 -- covers offsets 1..53 above in one request

-- Offsets relative to the model's data start (right after its header).
local OFFSET = {
  AC_POWER = 13,        -- relative 12 -> registers are 1-indexed in Lua tables
  AC_POWER_SF = 14,
  AC_ENERGY_WH_HI = 23,  -- relative 22
  AC_ENERGY_WH_LO = 24,  -- relative 23
  AC_ENERGY_WH_SF = 25,  -- relative 24
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

--- Reads and parses one full sample from the inverter.
--- Returns { power_w, energy_wh, dc_voltage, dc_power_w, temp_c, status, status_name }
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
  local meter_addr, meter_length = SunSpec.find_model(client, METER_MODEL_IDS)
  local meter_regs = nil
  if meter_addr and meter_length >= METER_READ_COUNT then
    meter_regs = client:read_holding_registers(meter_addr, METER_READ_COUNT)
  end
  client:close()

  local ac_power_raw = Modbus.to_int16(regs[OFFSET.AC_POWER])
  local ac_power_sf = regs[OFFSET.AC_POWER_SF]
  local power_w = Modbus.apply_scale_factor(ac_power_raw, ac_power_sf)

  local energy_wh_raw = Modbus.registers_to_u32(regs[OFFSET.AC_ENERGY_WH_HI], regs[OFFSET.AC_ENERGY_WH_LO])
  local energy_wh_sf = regs[OFFSET.AC_ENERGY_WH_SF]
  local energy_wh = Modbus.apply_scale_factor(energy_wh_raw, energy_wh_sf)

  local dc_voltage_raw = regs[OFFSET.DC_VOLTAGE]
  local dc_voltage_sf = regs[OFFSET.DC_VOLTAGE_SF]
  local dc_voltage = Modbus.apply_scale_factor(dc_voltage_raw, dc_voltage_sf)

  local dc_power_raw = Modbus.to_int16(regs[OFFSET.DC_POWER])
  local dc_power_sf = regs[OFFSET.DC_POWER_SF]
  local dc_power_w = Modbus.apply_scale_factor(dc_power_raw, dc_power_sf)

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
  if meter_regs then
    local grid_power_raw = Modbus.to_int16(meter_regs[METER_OFFSET.AC_POWER])
    local grid_power_sf = meter_regs[METER_OFFSET.AC_POWER_SF]
    grid_power_w = Modbus.apply_scale_factor(grid_power_raw, grid_power_sf)

    local energy_sf = meter_regs[METER_OFFSET.ENERGY_SF]
    local exported_raw = Modbus.registers_to_u32(meter_regs[METER_OFFSET.EXPORTED_HI], meter_regs[METER_OFFSET.EXPORTED_LO])
    local imported_raw = Modbus.registers_to_u32(meter_regs[METER_OFFSET.IMPORTED_HI], meter_regs[METER_OFFSET.IMPORTED_LO])
    grid_exported_wh = Modbus.apply_scale_factor(exported_raw, energy_sf)
    grid_imported_wh = Modbus.apply_scale_factor(imported_raw, energy_sf)
  end

  return {
    power_w = power_w,
    energy_wh = energy_wh,
    dc_voltage = dc_voltage,
    dc_power_w = dc_power_w,
    temp_c = temp_c,
    status = status,
    status_name = STATUS_NAMES[status] or ("UNKNOWN(" .. tostring(status) .. ")"),
    model_id = model_id,
    grid_power_w = grid_power_w,
    grid_exported_wh = grid_exported_wh,
    grid_imported_wh = grid_imported_wh,
  }
end

return SolarEdge
