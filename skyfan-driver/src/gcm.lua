--- AES-128-GCM on top of lockbox's raw AES block function (lockbox has no
--- GCM mode). Needed for Tuya protocol 3.5, which wraps every frame in
--- AES-GCM instead of 3.3's AES-ECB.
---
--- Strings in, strings out (raw bytes). 96-bit IVs only, which is all Tuya
--- uses. Lua 5.3 compatible: a 128-bit GHASH block is held as two 64-bit
--- integers (hi, lo); `>>` is a logical shift, which is what GF(2^128)
--- needs.

local GCM = {}

-- ===== AES-128 encryption (table-driven) =====
-- lockbox's AES re-expands the key on every 16-byte block (~2 ms each on a
-- PC, far slower on a hub), and one 3.5 session needs dozens of blocks. This
-- expands once per key and uses the standard T-table form. Encryption only:
-- GCM never needs AES decryption.

local SBOX, TE0, TE1, TE2, TE3 = {}, {}, {}, {}, {}
do
  -- Build the S-box from GF(2^8) inverses (avoids a 256-entry literal).
  local function xtime(a)
    a = a << 1
    if a & 0x100 ~= 0 then a = a ~ 0x11B end
    return a
  end
  local p, q = 1, 1
  repeat
    p = p ~ xtime(p)                       -- p *= 3
    q = q ~ (q << 1); q = q ~ (q << 2); q = q ~ (q << 4); q = q & 0xFF
    if q & 0x80 ~= 0 then q = q ~ 0x09 end -- q /= 3
    local x = q ~ ((q << 1) | (q >> 7)) ~ ((q << 2) | (q >> 6))
      ~ ((q << 3) | (q >> 5)) ~ ((q << 4) | (q >> 4))
    SBOX[p] = (x ~ 0x63) & 0xFF
  until p == 1
  SBOX[0] = 0x63
  for i = 0, 255 do
    local s = SBOX[i]
    local s2 = xtime(s) & 0xFF
    local s3 = s2 ~ s
    local w = (s2 << 24) | (s << 16) | (s << 8) | s3
    TE0[i] = w
    TE1[i] = ((w >> 8) | (w << 24)) & 0xFFFFFFFF
    TE2[i] = ((w >> 16) | (w << 16)) & 0xFFFFFFFF
    TE3[i] = ((w >> 24) | (w << 8)) & 0xFFFFFFFF
  end
end

local function expand_key(key)
  local w = { string.unpack(">I4I4I4I4", key) }
  w[5] = nil -- drop unpack's trailing position
  local rcon = 1
  for i = 5, 44 do
    local t = w[i - 1]
    if (i - 1) % 4 == 0 then
      t = ((t << 8) | (t >> 24)) & 0xFFFFFFFF
      t = (SBOX[t >> 24] << 24) | (SBOX[(t >> 16) & 0xFF] << 16)
        | (SBOX[(t >> 8) & 0xFF] << 8) | SBOX[t & 0xFF]
      t = t ~ (rcon << 24)
      rcon = rcon << 1
      if rcon & 0x100 ~= 0 then rcon = (rcon ~ 0x11B) & 0xFF end
    end
    w[i] = w[i - 4] ~ t
  end
  return w
end

local function aes_block(w, block)
  local s0, s1, s2, s3 = string.unpack(">I4I4I4I4", block)
  s0, s1, s2, s3 = s0 ~ w[1], s1 ~ w[2], s2 ~ w[3], s3 ~ w[4]
  local k = 5
  for _ = 1, 9 do
    local t0 = TE0[s0 >> 24] ~ TE1[(s1 >> 16) & 0xFF] ~ TE2[(s2 >> 8) & 0xFF] ~ TE3[s3 & 0xFF] ~ w[k]
    local t1 = TE0[s1 >> 24] ~ TE1[(s2 >> 16) & 0xFF] ~ TE2[(s3 >> 8) & 0xFF] ~ TE3[s0 & 0xFF] ~ w[k + 1]
    local t2 = TE0[s2 >> 24] ~ TE1[(s3 >> 16) & 0xFF] ~ TE2[(s0 >> 8) & 0xFF] ~ TE3[s1 & 0xFF] ~ w[k + 2]
    local t3 = TE0[s3 >> 24] ~ TE1[(s0 >> 16) & 0xFF] ~ TE2[(s1 >> 8) & 0xFF] ~ TE3[s2 & 0xFF] ~ w[k + 3]
    s0, s1, s2, s3 = t0, t1, t2, t3
    k = k + 4
  end
  local function last(a, b, c, d, rk)
    return ((SBOX[a >> 24] << 24) | (SBOX[(b >> 16) & 0xFF] << 16)
      | (SBOX[(c >> 8) & 0xFF] << 8) | SBOX[d & 0xFF]) ~ rk
  end
  return string.pack(">I4I4I4I4",
    last(s0, s1, s2, s3, w[41]), last(s1, s2, s3, s0, w[42]),
    last(s2, s3, s0, s1, w[43]), last(s3, s0, s1, s2, w[44]))
end

-- Reduction constant for GHASH's bit-reflected field: 0xE1 in the top byte.
local R_HI = 0xE100000000000000

local function xor_bytes(a, b)
  if #a == 16 then
    local a1, a2 = string.unpack(">i8i8", a)
    local b1, b2 = string.unpack(">i8i8", b)
    return string.pack(">i8i8", a1 ~ b1, a2 ~ b2)
  end
  local out = {}
  for i = 1, #a do
    out[i] = string.char(string.byte(a, i) ~ string.byte(b, i))
  end
  return table.concat(out)
end

--- Multiplies two 128-bit field elements (each as hi, lo) in GF(2^128).
local function gf_mul(xh, xl, yh, yl)
  local zh, zl = 0, 0
  local vh, vl = yh, yl
  for i = 0, 127 do
    local bit
    if i < 64 then
      bit = (xh >> (63 - i)) & 1
    else
      bit = (xl >> (127 - i)) & 1
    end
    if bit == 1 then
      zh, zl = zh ~ vh, zl ~ vl
    end
    local carry = vl & 1
    vl = (vl >> 1) | ((vh & 1) << 63)
    vh = vh >> 1
    if carry == 1 then
      vh = vh ~ R_HI
    end
  end
  return zh, zl
end

local function ghash(h, aad, ciphertext)
  local hh, hl = string.unpack(">i8i8", h)
  local yh, yl = 0, 0
  local function absorb(data)
    for i = 1, #data, 16 do
      local block = data:sub(i, i + 15)
      if #block < 16 then
        block = block .. string.rep("\0", 16 - #block)
      end
      local bh, bl = string.unpack(">i8i8", block)
      yh, yl = gf_mul(yh ~ bh, yl ~ bl, hh, hl)
    end
  end
  absorb(aad)
  absorb(ciphertext)
  local lh, ll = #aad * 8, #ciphertext * 8
  yh, yl = gf_mul(yh ~ lh, yl ~ ll, hh, hl)
  return string.pack(">i8i8", yh, yl)
end

--- Counter block number `n` for a 96-bit IV (J0 is n = 1).
local function counter_block(iv, n)
  return iv .. string.pack(">I4", n)
end

--- AES-CTR keystream applied to `data`, starting at counter block `first`.
local function ctr(key_array, iv, data, first)
  local out = {}
  local n = first
  for i = 1, #data, 16 do
    local chunk = data:sub(i, i + 15)
    local ks = aes_block(key_array, counter_block(iv, n))
    out[#out + 1] = xor_bytes(chunk, ks:sub(1, #chunk))
    n = n + 1
  end
  return table.concat(out)
end

--- Returns ciphertext, tag (16 bytes).
function GCM.encrypt(key, iv, plaintext, aad)
  assert(#key == 16 and #iv == 12, "GCM: 16-byte key and 12-byte IV required")
  aad = aad or ""
  local k = expand_key(key)
  local h = aes_block(k, string.rep("\0", 16))
  local ciphertext = ctr(k, iv, plaintext, 2)
  local tag = xor_bytes(aes_block(k, counter_block(iv, 1)), ghash(h, aad, ciphertext))
  return ciphertext, tag
end

--- Returns plaintext, or nil, "auth failed" if the tag doesn't verify.
function GCM.decrypt(key, iv, ciphertext, aad, tag)
  assert(#key == 16 and #iv == 12, "GCM: 16-byte key and 12-byte IV required")
  aad = aad or ""
  local k = expand_key(key)
  local h = aes_block(k, string.rep("\0", 16))
  local expected = xor_bytes(aes_block(k, counter_block(iv, 1)), ghash(h, aad, ciphertext))
  if expected ~= tag then
    return nil, "auth failed"
  end
  return ctr(k, iv, ciphertext, 2)
end

GCM._aes_block = function(key, block) return aes_block(expand_key(key), block) end

return GCM
