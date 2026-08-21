--- Tuya local LAN protocol (reverse-engineered, not officially published by
--- Tuya) — message framing, AES encryption, and DP encode/decode.
---
--- NOT tested against a live device — I have no LAN access from this
--- environment. Built to protocol version 3.3 as the most common baseline
--- for a device of this age (activated ~2022). If the device actually
--- speaks 3.4 (adds an HMAC integrity check and a version-header prefix on
--- the payload) or 3.1 (different, weaker key derivation), this module's
--- checksum/payload functions are the specific things that will need
--- adjusting — see the version-specific notes inline. Expect live
--- iteration via logcat, same as the SolarEdge Modbus offsets needed.
---
--- Wire format (all versions share this outer envelope):
---   4 bytes  prefix       0x000055AA
---   4 bytes  sequence     arbitrary, incrementing
---   4 bytes  command      see COMMAND table below
---   4 bytes  length       byte length of (payload + checksum + suffix)
---   N bytes  payload      encrypted (AES-128-ECB, key = local_key, PKCS7 padded)
---   4 bytes  checksum     CRC32 over [prefix..payload] (3.1-3.3) — 3.4 uses
---                         a 32-byte HMAC-SHA256 here instead, see notes
---   4 bytes  suffix       0x0000AA55

Lockbox = require("lockbox")
Lockbox.ALLOW_INSECURE = true -- AES-ECB is what Tuya's actual wire protocol
-- requires; this isn't a security choice being made here, it's matching an
-- external protocol this driver has to interoperate with.

local AES128 = require("lockbox.cipher.aes128")
local ECBMode = require("lockbox.cipher.mode.ecb")
local PKCS7 = require("lockbox.padding.pkcs7")
local Array = require("lockbox.util.array")
local Stream = require("lockbox.util.stream")
local CRC32 = require("crc32")
local json = require("dkjson")
local log = require("log")

local Tuya = {}

local PREFIX = 0x000055AA
local SUFFIX = 0x0000AA55

Tuya.COMMAND = {
  CONTROL = 0x07,
  STATUS = 0x08,
  DP_QUERY = 0x0a,
  CONTROL_NEW = 0x0d,
  DP_QUERY_NEW = 0x10,
}

local function u32(n)
  return string.pack(">I4", n & 0xFFFFFFFF)
end

local function read_u32(data, offset)
  return string.unpack(">I4", data, offset)
end

--- lockbox's ECB Decipher never strips PKCS7 padding on its own (its
--- `finish()` just re-runs the padding generator against whatever's left
--- in the input queue, which is empty since our ciphertext is always a
--- full multiple of the block size) — so padding must be removed by hand
--- from the decrypted plaintext.
local function pkcs7_unpad(data)
  local n = #data
  if n == 0 then return data end
  local pad = string.byte(data, n)
  if pad < 1 or pad > 16 or pad > n then
    return data
  end
  for i = n - pad + 1, n do
    if string.byte(data, i) ~= pad then
      return data
    end
  end
  return data:sub(1, n - pad)
end

--- AES-128-ECB encrypt with PKCS7 padding. `key` and `data` are raw byte strings.
local function aes_ecb_encrypt(key, data)
  local cipher = ECBMode.Cipher()
    .setKey(Array.fromString(key))
    .setBlockCipher(AES128)
    .setPadding(PKCS7)
    .init()

  cipher.update(Stream.fromString(data))
  cipher.finish()
  return Array.toString(cipher.asBytes())
end

--- AES-128-ECB decrypt with PKCS7 unpadding.
local function aes_ecb_decrypt(key, data)
  local cipher = ECBMode.Decipher()
    .setKey(Array.fromString(key))
    .setBlockCipher(AES128)
    .setPadding(PKCS7)
    .init()

  cipher.update(Stream.fromString(data))
  cipher.finish()
  return pkcs7_unpad(Array.toString(cipher.asBytes()))
end

--- Builds a complete wire message for the given command and Lua table payload.
--- `local_key` must be exactly 16 raw bytes (Tuya local keys are always 16
--- ASCII characters, used directly as the AES-128 key — no hashing needed
--- for protocol 3.3).
-- Protocol 3.2+ requires a 15-byte CLEAR "source header" — 3 ASCII version
-- bytes ("3.3") followed by 12 zero bytes — prepended to the ciphertext for
-- every command EXCEPT DP_QUERY/DP_QUERY_NEW/UPDATEDPS/HEART_BEAT/session-key
-- negotiation. Confirmed 2026-08-20 against jasonacox/tinytuya's actual wire
-- bytes for a real successful write on this exact fan: our decode() already
-- knew to strip this header from device->client responses (see the comment
-- there), but encode() never added it to client->device CONTROL/CONTROL_NEW
-- requests — the device silently drops any write missing it (TCP-acks the
-- data, never sends an application response), while DP_QUERY, correctly
-- excluded, always worked. This was the entire root cause of writes failing
-- fleet-wide while reads always succeeded.
local NO_HEADER_COMMANDS = {
  [Tuya.COMMAND.DP_QUERY] = true,
  [Tuya.COMMAND.DP_QUERY_NEW] = true,
}

function Tuya.encode(command, payload_table, local_key, sequence)
  local payload_json = json.encode(payload_table)
  local encrypted = aes_ecb_encrypt(local_key, payload_json)

  if not NO_HEADER_COMMANDS[command] then
    encrypted = "3.3" .. string.rep("\0", 12) .. encrypted
  end

  local length = #encrypted + 4 + 4 -- + checksum(4) + suffix(4)

  local head = u32(PREFIX) .. u32(sequence) .. u32(command) .. u32(length)
  local before_checksum = head .. encrypted
  local checksum = CRC32.compute(before_checksum)

  return before_checksum .. u32(checksum) .. u32(SUFFIX)
end

--- Parses a complete wire message. Returns {command, payload_table} or nil, error.
--- Assumes exactly one message is in `data` (the caller is responsible for
--- framing multiple messages read off the socket, using the length field).
function Tuya.decode(data, local_key)
  if #data < 16 then
    return nil, "message too short for header"
  end

  local prefix = read_u32(data, 1)
  if prefix ~= PREFIX then
    return nil, string.format("bad prefix 0x%08X", prefix)
  end

  local command = read_u32(data, 9)
  local length = read_u32(data, 13)

  local payload_end = 16 + length - 4 - 4 -- exclude checksum+suffix from payload
  local encrypted = data:sub(17, payload_end)

  if #encrypted == 0 then
    return {command = command, payload = {}}
  end

  do
    local hex = {}
    for i = 1, math.min(20, #encrypted) do
      hex[i] = string.format("%02x", string.byte(encrypted, i))
    end
    log.info("Skyfan DC raw payload bytes (first 20): " .. table.concat(hex, " ") ..
      " (total len " .. #encrypted .. ")")
  end

  -- Protocol 3.3+ responses to STATUS/DP_QUERY (and sometimes CONTROL) are
  -- prefixed with a 15-byte CLEAR "source header" — 3 ASCII version bytes
  -- ("3.3") followed by CRC32(4)/sequence(4)/source-id(4) — before the
  -- actual AES-ECB ciphertext begins. This header is NOT encrypted and is
  -- NOT part of the ciphertext; feeding it into the decrypt call misaligns
  -- every subsequent AES block boundary and produces garbage that can
  -- coincidentally still parse as valid (wrong) JSON. Confirmed against
  -- jasonacox/tinytuya's PROTOCOL.md. Strip it first if present.
  if encrypted:sub(1, 3) == "3.3" and #encrypted >= 15 then
    encrypted = encrypted:sub(16)
  elseif #encrypted % 16 == 4 then
    -- Device→client responses can carry a clear, unencrypted 4-byte
    -- `retcode` field (0 = success) immediately before the ciphertext,
    -- separate from the 15-byte "3.3" source header above — confirmed
    -- directly against this fan (protocol.md documents the source header
    -- but not this variant; found by noticing the ciphertext length was 4
    -- bytes short of a clean multiple of 16, and that those 4 leading bytes
    -- were always 0x00000000). Strip it the same way.
    encrypted = encrypted:sub(5)
  end

  if #encrypted == 0 then
    return {command = command, payload = {}}
  end

  local ok, decrypted = pcall(aes_ecb_decrypt, local_key, encrypted)
  if not ok then
    return nil, "decrypt failed: " .. tostring(decrypted)
  end

  local ok2, parsed = pcall(json.decode, decrypted)
  if not ok2 or not parsed then
    -- Some responses (e.g. bare ACKs) aren't JSON — return the raw string.
    return {command = command, payload = decrypted}
  end

  return {command = command, payload = parsed}
end

--- Returns the total expected message length (header + rest) if `data`
--- contains at least a full header, so the caller knows how many more
--- bytes to read from the socket before calling Tuya.decode. Returns nil
--- if fewer than 16 bytes are available yet.
function Tuya.expected_length(data)
  if #data < 16 then
    return nil
  end
  local length = read_u32(data, 13)
  return 16 + length
end

return Tuya
