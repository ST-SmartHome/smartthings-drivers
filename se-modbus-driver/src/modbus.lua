--- Minimal Modbus TCP client: Read Holding Registers (function code 0x03) only.
--- Enough to read the SunSpec inverter model block from a SolarEdge inverter.
--- NOT tested against a live device — verify register values against a known
--- reading (e.g. current AC power shown on the inverter display) before trusting it.

local socket = require "cosock.socket"
local log = require "log"

local Modbus = {}
Modbus.__index = Modbus

local function u16(hi, lo)
  return (hi << 8) | lo
end

local function build_request(transaction_id, unit_id, start_addr, quantity)
  local pdu = string.pack(">BHH", 0x03, start_addr, quantity)
  local length = #pdu + 1 -- + unit id byte
  local mbap = string.pack(">HHHB", transaction_id, 0x0000, length, unit_id)
  return mbap .. pdu
end

--- Opens a TCP connection to the inverter. Returns a Modbus client object or nil+error.
function Modbus.connect(ip, port, timeout_sec)
  local sock, err = socket.tcp()
  if not sock then
    return nil, "socket create failed: " .. tostring(err)
  end
  sock:settimeout(timeout_sec or 5)
  local ok, connect_err = sock:connect(ip, port)
  if not ok then
    sock:close()
    return nil, "connect failed: " .. tostring(connect_err)
  end
  local self = setmetatable({ sock = sock, tid = 0 }, Modbus)
  return self
end

--- Reads `quantity` holding registers starting at `start_addr` (SunSpec addresses
--- are 1-based in documentation but 0-based on the wire — callers should pass the
--- wire address, i.e. documented_address - 40001 style offsets already applied).
--- Returns a table of raw 16-bit register values (unsigned), or nil+error.
function Modbus:read_holding_registers(start_addr, quantity)
  self.tid = (self.tid + 1) % 0xFFFF
  local request = build_request(self.tid, self.unit_id or 1, start_addr, quantity)

  local sent, send_err = self.sock:send(request)
  if not sent then
    return nil, "send failed: " .. tostring(send_err)
  end

  local header, header_err = self.sock:receive(7)
  if not header then
    return nil, "header receive failed: " .. tostring(header_err)
  end
  local resp_tid, proto_id, length, unit_id = string.unpack(">HHHB", header)
  if proto_id ~= 0x0000 then
    return nil, "unexpected protocol id: " .. tostring(proto_id)
  end

  local pdu, pdu_err = self.sock:receive(length - 1)
  if not pdu then
    return nil, "pdu receive failed: " .. tostring(pdu_err)
  end

  local func_code = string.byte(pdu, 1)
  if func_code == 0x83 then
    local exception_code = string.byte(pdu, 2)
    return nil, "modbus exception code " .. tostring(exception_code)
  elseif func_code ~= 0x03 then
    return nil, "unexpected function code " .. tostring(func_code)
  end

  local byte_count = string.byte(pdu, 2)
  local registers = {}
  for i = 1, byte_count / 2 do
    local offset = 3 + (i - 1) * 2
    local hi = string.byte(pdu, offset)
    local lo = string.byte(pdu, offset + 1)
    registers[i] = u16(hi, lo)
  end
  return registers
end

function Modbus:set_unit_id(unit_id)
  self.unit_id = unit_id
end

function Modbus:close()
  if self.sock then
    self.sock:close()
  end
end

--- Converts two consecutive 16-bit registers (big-endian, hi word first) into
--- an unsigned 32-bit integer. Used for the accumulated lifetime energy value.
function Modbus.registers_to_u32(hi_reg, lo_reg)
  return (hi_reg << 16) | lo_reg
end

--- Converts a raw unsigned 16-bit register into a signed 16-bit integer.
--- Several SunSpec fields (power, temperature, scale factors) are signed.
function Modbus.to_int16(raw)
  if raw >= 0x8000 then
    return raw - 0x10000
  end
  return raw
end

--- Applies a SunSpec scale factor register (a signed int16, typically -5..0)
--- to a raw value: real_value = raw_value * 10^SF
function Modbus.apply_scale_factor(raw_value, sf_raw)
  local sf = Modbus.to_int16(sf_raw)
  return raw_value * (10 ^ sf)
end

return Modbus
