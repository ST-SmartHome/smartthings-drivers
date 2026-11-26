--- Walks the SunSpec model chain to find the actual register address of a
--- given model, instead of assuming a fixed address. This replaces the
--- earlier hardcoded "documented 40069" guess, which turned out wrong on
--- a real inverter (readings came back as reserved/sentinel values —
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
--- `resume_addr`, if given, skips the "SunS" identifier re-check and the
--- header rescan and starts walking directly from that wire address
--- instead -- pass a previous call's `model_addr + model_length` (the
--- wire address right after the model you already found) to continue the
--- SAME chain walk instead of re-reading the identifier and every earlier
--- model's header again. Omit for the first walk of a connection.
function SunSpec.find_model(client, target_model_ids, resume_addr)
  local addr
  if resume_addr then
    addr = resume_addr
  else
    local header, err = client:read_holding_registers(0, 2)
    if not header then
      return nil, "failed reading SunSpec identifier: " .. tostring(err)
    end
    if header[1] ~= SUNS_HI or header[2] ~= SUNS_LO then
      return nil, string.format("no SunSpec 'SunS' identifier at register 0 (got 0x%04X 0x%04X) — this device may not be SunSpec-compliant at this address, or uses a non-default base",
        header[1], header[2])
    end
    addr = 2
  end

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

--- Text from a run of registers (two ASCII bytes each, high byte first),
--- with trailing NULs and spaces removed.
local function registers_to_text(regs)
  local bytes = {}
  for _, r in ipairs(regs) do
    bytes[#bytes + 1] = string.char((r >> 8) & 0xFF, r & 0xFF)
  end
  return (table.concat(bytes):gsub("[%z%s]+$", ""))
end
SunSpec._registers_to_text = registers_to_text

-- In a Common (model 1) block, C_Option is 8 registers at data offset 32.
-- SolarEdge meters put their role there: "Export+Import", "Consumption",
-- "Production" (as Home Assistant's solaredge-modbus-multi reads it).
local COMMON_MODEL_ID = 1
local OPTION_OFFSET = 32
local OPTION_LENGTH = 8

--- Walks the rest of the chain from `resume_addr` and returns the meter
--- that measures the grid connection: the first meter model whose own
--- Common block says "Export" in its option, else the first meter found
--- (the old behaviour). Returns data address, length, model id and role
--- text (nil if unreadable), or nil + error when there's no meter.
function SunSpec.find_grid_meter(client, meter_model_ids, resume_addr)
  local addr = resume_addr
  local common_addr = nil
  local first = nil
  for _ = 1, MAX_MODELS_TO_SCAN do
    local model_header, mh_err = client:read_holding_registers(addr, 2)
    if not model_header then
      if first then
        break -- keep the meter already found
      end
      return nil, "failed reading model header at wire " .. addr .. ": " .. tostring(mh_err)
    end
    local model_id, model_length = model_header[1], model_header[2]
    if model_id == END_MODEL_ID then
      break
    end
    if model_id == COMMON_MODEL_ID then
      common_addr = addr + 2
    elseif meter_model_ids[model_id] then
      local role = nil
      if common_addr then
        local opt = client:read_holding_registers(common_addr + OPTION_OFFSET, OPTION_LENGTH)
        role = opt and registers_to_text(opt) or nil
      end
      local meter = { addr = addr + 2, length = model_length, id = model_id, role = role }
      if role and role:lower():find("export", 1, true) then
        return meter.addr, meter.length, meter.id, role
      end
      first = first or meter
    end
    addr = addr + 2 + model_length
  end
  if first then
    return first.addr, first.length, first.id, first.role
  end
  return nil, "no meter model in the SunSpec chain"
end

return SunSpec
