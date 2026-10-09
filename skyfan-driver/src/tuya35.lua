--- Tuya local LAN protocol 3.5 — used by newer Tuya Wi-Fi modules (they
--- report hostname "lwip0" rather than ESP_xxxxxx). Kept separate from
--- tuya_protocol.lua so the proven 3.3 path stays untouched.
---
--- Confirmed against two real Skyfan DC units (2026-10-09) with a Python
--- reference client before this was written:
---
--- Frame (all big-endian):
---   4  prefix   0x00006699
---   2  unknown  0x0000
---   4  sequence
---   4  command
---   4  length   = 12 (IV) + ciphertext + 16 (tag)
---   12 IV, N ciphertext, 16 GCM tag
---   4  suffix   0x00009966
--- AES-128-GCM; the additional authenticated data is the 14 header bytes
--- after the prefix.
---
--- Session (one per TCP connection, before any command):
---   -> 0x03 SESS_KEY_NEG_START   local nonce (16), GCM with local_key
---   <- 0x04 SESS_KEY_NEG_RESP    retcode(4) remote nonce(16) HMAC(local_key, local nonce)(32)
---   -> 0x05 SESS_KEY_NEG_FINISH  HMAC(local_key, remote nonce), no reply
---   session key = first 16 bytes of GCM(local_key, IV = local nonce[1..12],
---   local nonce XOR remote nonce), i.e. the XOR against AES counter block 2.
--- Then: status query is 0x10 with "{}"; writes are 0x0d with
--- {"protocol":5,"t":..,"data":{"dps":{..}}} behind a clear "3.5" + 12 zero
--- byte header inside the plaintext. Replies: retcode(4), then for pushes
--- (0x08) the same 15-byte "3.5" header, then JSON.

local GCM = require("gcm")
local json = require("dkjson")

local Tuya35 = {}

local PREFIX = 0x00006699
local SUFFIX = 0x00009966
local HEADER_LEN = 18

Tuya35.COMMAND = {
  SESS_KEY_NEG_START = 0x03,
  SESS_KEY_NEG_RESP = 0x04,
  SESS_KEY_NEG_FINISH = 0x05,
  STATUS = 0x08,
  CONTROL_NEW = 0x0d,
  DP_QUERY_NEW = 0x10,
}

local VERSION_HEADER = "3.5" .. string.rep("\0", 12)

--- Random bytes. Only needs to be unique per message (GCM IV) and
--- unpredictable-ish (nonce); replaceable for tests.
Tuya35.random_bytes = function(n)
  local t = {}
  for i = 1, n do
    t[i] = string.char(math.random(0, 255))
  end
  return table.concat(t)
end

-- SHA-256 on native integers. lockbox's takes ~14 ms per HMAC on a PC, and
-- a session needs three; this is ~50x faster.
local K256 = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rotr(x, n)
  return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF
end

local function sha256(msg)
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64) .. string.pack(">I8", len * 8)
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 1, 16 do
      w[i] = string.unpack(">I4", msg, chunk + (i - 1) * 4)
    end
    for i = 17, 64 do
      local a, b = w[i - 15], w[i - 2]
      local s0 = rotr(a, 7) ~ rotr(a, 18) ~ (a >> 3)
      local s1 = rotr(b, 17) ~ rotr(b, 19) ~ (b >> 10)
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for i = 1, 64 do
      local S1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
      local ch = (e & f) ~ (~e & g)
      local t1 = (h + S1 + ch + K256[i] + w[i]) & 0xFFFFFFFF
      local S0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
      local maj = (a & b) ~ (a & c) ~ (b & c)
      local t2 = (S0 + maj) & 0xFFFFFFFF
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) & 0xFFFFFFFF, c, b, a, (t1 + t2) & 0xFFFFFFFF
    end
    h0, h1, h2, h3 = (h0 + a) & 0xFFFFFFFF, (h1 + b) & 0xFFFFFFFF, (h2 + c) & 0xFFFFFFFF, (h3 + d) & 0xFFFFFFFF
    h4, h5, h6, h7 = (h4 + e) & 0xFFFFFFFF, (h5 + f) & 0xFFFFFFFF, (h6 + g) & 0xFFFFFFFF, (h7 + h) & 0xFFFFFFFF
  end
  return string.pack(">I4I4I4I4I4I4I4I4", h0, h1, h2, h3, h4, h5, h6, h7)
end
Tuya35.sha256 = sha256

local function hmac_sha256(key, msg)
  if #key > 64 then
    key = sha256(key)
  end
  key = key .. string.rep("\0", 64 - #key)
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local b = string.byte(key, i)
    ipad[i] = string.char(b ~ 0x36)
    opad[i] = string.char(b ~ 0x5C)
  end
  return sha256(table.concat(opad) .. sha256(table.concat(ipad) .. msg))
end
Tuya35.hmac_sha256 = hmac_sha256

local function xor16(a, b)
  local a1, a2 = string.unpack(">i8i8", a)
  local b1, b2 = string.unpack(">i8i8", b)
  return string.pack(">i8i8", a1 ~ b1, a2 ~ b2)
end

--- Builds one frame. `plaintext` is raw bytes.
function Tuya35.encode(command, sequence, plaintext, key)
  local iv = Tuya35.random_bytes(12)
  local header = string.pack(">I4I2I4I4I4", PREFIX, 0, sequence, command, 12 + #plaintext + 16)
  local ciphertext, tag = GCM.encrypt(key, iv, plaintext, header:sub(5))
  return header .. iv .. ciphertext .. tag .. string.pack(">I4", SUFFIX)
end

--- Total frame size from the first 18 bytes, or nil if `data` is too short
--- or isn't a 3.5 frame.
function Tuya35.expected_length(data)
  if #data < HEADER_LEN then
    return nil
  end
  if string.unpack(">I4", data, 1) ~= PREFIX then
    return nil
  end
  return HEADER_LEN + string.unpack(">I4", data, 15) + 4
end

--- Decrypts one complete frame. Returns command, plaintext or nil, error.
function Tuya35.decode(frame, key)
  if #frame < HEADER_LEN + 28 + 4 then
    return nil, "3.5 frame too short (" .. #frame .. " bytes)"
  end
  local prefix, _, _, command, length = string.unpack(">I4I2I4I4I4", frame)
  if prefix ~= PREFIX then
    return nil, string.format("bad 3.5 prefix 0x%08X", prefix)
  end
  if #frame < HEADER_LEN + length then
    return nil, "3.5 frame truncated"
  end
  local body = frame:sub(HEADER_LEN + 1, HEADER_LEN + length)
  local iv = body:sub(1, 12)
  local ciphertext = body:sub(13, #body - 16)
  local tag = body:sub(#body - 15)
  local plaintext, err = GCM.decrypt(key, iv, ciphertext, frame:sub(5, HEADER_LEN), tag)
  if not plaintext then
    return nil, "3.5 decrypt failed: " .. tostring(err)
  end
  return command, plaintext
end

--- Strips the reply's retcode and/or "3.5" header, leaving JSON (or "").
function Tuya35.strip_payload(plaintext)
  local p = plaintext
  if #p >= 4 and p:sub(1, 1) ~= "{" and p:sub(1, 3) ~= "3.5" then
    p = p:sub(5)
  end
  if p:sub(1, 3) == "3.5" and #p >= 15 then
    p = p:sub(16)
  end
  return p
end

--- Parses a reply's JSON. Returns a table, or the raw string if it isn't JSON.
function Tuya35.parse_payload(plaintext)
  local p = Tuya35.strip_payload(plaintext)
  if p == "" then
    return {}
  end
  local ok, parsed = pcall(json.decode, p)
  if ok and type(parsed) == "table" then
    return parsed
  end
  return p
end

--- Runs the session-key handshake over an open connection. `read_frame` is
--- a function returning one raw frame (or nil, err); `send` sends bytes.
--- Returns the session key, or nil, error. `handshake_ok` (third return) is
--- true once the fan has proven it knows this local_key (HMAC verified),
--- which is what makes "this fan speaks 3.5" certain.
function Tuya35.negotiate(send, read_frame, local_key, next_sequence)
  local local_nonce = Tuya35.random_bytes(16)
  local ok, err = send(Tuya35.encode(Tuya35.COMMAND.SESS_KEY_NEG_START, next_sequence(), local_nonce, local_key))
  if not ok then
    return nil, "3.5 handshake send failed: " .. tostring(err)
  end

  local frame, read_err = read_frame()
  if not frame then
    return nil, "3.5 handshake receive failed: " .. tostring(read_err)
  end
  local command, plaintext = Tuya35.decode(frame, local_key)
  if not command then
    return nil, plaintext
  end
  if command ~= Tuya35.COMMAND.SESS_KEY_NEG_RESP then
    return nil, string.format("3.5 handshake: unexpected command 0x%02x", command)
  end
  if #plaintext == 52 then
    plaintext = plaintext:sub(5) -- retcode
  end
  if #plaintext < 48 then
    return nil, "3.5 handshake: short response (" .. #plaintext .. " bytes)"
  end
  local remote_nonce = plaintext:sub(1, 16)
  if plaintext:sub(17, 48) ~= hmac_sha256(local_key, local_nonce) then
    return nil, "3.5 handshake: fan's HMAC didn't verify (wrong local key?)"
  end

  ok, err = send(Tuya35.encode(Tuya35.COMMAND.SESS_KEY_NEG_FINISH, next_sequence(),
    hmac_sha256(local_key, remote_nonce), local_key))
  if not ok then
    return nil, "3.5 handshake finish failed: " .. tostring(err), true
  end

  local session_key = GCM.encrypt(local_key, local_nonce:sub(1, 12), xor16(local_nonce, remote_nonce))
  return session_key:sub(1, 16), nil, true
end

--- Plaintext for a status query.
function Tuya35.query_plaintext()
  return "{}"
end

--- Plaintext for a DP write.
function Tuya35.control_plaintext(dps)
  return VERSION_HEADER .. json.encode({protocol = 5, t = os.time(), data = {dps = dps}})
end

return Tuya35
