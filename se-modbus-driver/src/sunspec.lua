--- Walks the SunSpec model chain to find the actual register address of a
--- given model, instead of assuming a fixed address. This replaces the
--- earlier hardcoded "documented 40069" guess, which turned out wrong for
--- this specific inverter (readings came back as reserved/sentinel values —
--- 0x8000, NaN-producing scale factors — a classic "wrong register block"
--- symptom, not a math bug).
---
--- SunSpec layout on the wire (wire address = documented Modicon address - 40001):
---   wire 0-1:  "SunS" identifier (0x5375, 0x6E53)
---   wire 2:    Model 1 (Common) ID = 1
---   wire 3:    Model 1 Length (registers, not counting the 2-register header)
---   wire 4..(4+Length-1): Model 1 data
---   wire (4+Length): Model 2 ID
---   wire (4+Length+1): Model 2 Length
---   ... repeats until a model ID of 0xFFFF (end marker)

local Modbus = require "modbus"
local log = require "log"

local SunSpec = {}

local SUNS_HI = 0x5375
local SUNS_LO = 0x6E53
local END_MODEL_ID = 0xFFFF
local MAX_MODELS_TO_SCAN = 20 -- safety bound, a real device has a handful

--- Returns the wire address of the given model's DATA (i.e. right after its
--- 2-register header), and its declared length, or nil + error.
--- `target_model_ids` is a set-like table, e.g. { [101]=true, [102]=true, [103]=true }.
function SunSpec.find_model(client, target_model_ids)
  local header, err = client:read_holding_registers(0, 2)
  if not header then
    return nil, "failed reading SunSpec identifier: " .. tostring(err)
  end
  if header[1] ~= SUNS_HI or header[2] ~= SUNS_LO then
    return nil, string.format("no SunSpec 'SunS' identifier at register 0 (got 0x%04X 0x%04X) — this device may not be SunSpec-compliant at this address, or uses a non-default base",
      header[1], header[2])
  end

  local addr = 2
  for _ = 1, MAX_MODELS_TO_SCAN do
    local model_header, mh_err = client:read_holding_registers(addr, 2)
    if not model_header then
      return nil, "failed reading model header at wire " .. addr .. ": " .. tostring(mh_err)
    end

    local model_id = model_header[1]
    local model_length = model_header[2]

    if model_id == END_MODEL_ID then
      return nil, "reached SunSpec end-of-model marker without finding a matching model"
    end

    if target_model_ids[model_id] then
      log.info(string.format("SunSpec: found model %d at wire address %d (length %d)", model_id, addr, model_length))
      return addr + 2, model_length, model_id
    end

    addr = addr + 2 + model_length
  end

  return nil, "scanned " .. MAX_MODELS_TO_SCAN .. " models without finding a match or end marker — giving up"
end

return SunSpec
