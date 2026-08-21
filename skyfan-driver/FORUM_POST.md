# [LAN Driver] Ventair Skyfan DC ceiling fan via local Tuya protocol

Controls a Ventair Skyfan DC ceiling fan entirely over its **local Tuya
LAN protocol** (port 6668, AES-encrypted) — no cloud dependency for actual
operation once set up. Fan on/off, speed, mode, direction, sleep timer,
plus the optional light kit's on/off, brightness, and color temperature
preset. Multiple fans supported via an in-app "Add another fan" button.

**Channel invite**: https://bestow-regional.api.smartthings.com/invite/RBlE0gaNvL2E

Tested against 8 physical units across a full household install — the
Skyfan-branded Wi-Fi dongle (an optional add-on accessory, not built into
the fan) is what this driver actually talks to; should work on any fan
using the same dongle.

## Requirements

- A Skyfan DC fan with the Wi-Fi dongle accessory fitted and already
  joined to your Wi-Fi (via the Smart Life/Tuya Smart app's normal pairing
  flow — this driver doesn't do initial Wi-Fi provisioning, only ongoing
  local control after that's done).
- A **Tuya IoT Platform** developer account (free) — needed once per
  household, not per fan, to retrieve each fan's local encryption key. See
  below, this is the fiddly part.
- A SmartThings Hub on the same network/VLAN as the fan(s).

## Setup

### Part 1 — get each fan's local key via Tuya's IoT Platform

Tuya's local protocol needs a per-device AES key (`local_key`) that isn't
visible anywhere in the Smart Life app itself — you have to pull it from
Tuya's developer/cloud side once, even though the driver never talks to
that cloud again afterward. Rather than hand-rolling the signed API
calls yourself, use [TinyTuya](https://github.com/jasonacox/tinytuya)'s
built-in wizard — it does the whole credential-retrieval flow for you.
(Good writeup of this same process, for a different device type but the
same Tuya-side steps, [here on this
forum](https://community.smartthings.com/t/st-edge-tuya-smart-life-wi-fi-air-purifiers/309519).)

1. `pip install tinytuya` (a virtualenv is fine but not required).
2. Go to **iot.tuya.com**, sign up or log in (free tier is enough).
3. **Cloud → Create Cloud Project.** Pick a **Data Center region that
   matches your existing Smart Life/Tuya Smart app account's region** —
   this matters, get it wrong and the project simply won't see your
   devices later with no clear error explaining why. If unsure, check
   which region your app account signed up under (Tuya's docs have a
   region lookup) rather than guessing.
4. On project creation, it'll prompt you to **subscribe to API
   services** — make sure **IoT Core** is included (this is what exposes
   the device-list/device-detail endpoints you need). The free tier's
   default trial subscription covers this.
5. **Devices tab → Link Tuya App Account → Add App Account**, then scan
   the QR code shown using the Smart Life/Tuya Smart app on your phone
   (Me → the QR/scan icon). This authorizes the cloud project to see the
   devices already paired in your app account — it doesn't move or
   re-pair anything.
6. Grab your **Client ID** and **Client Secret** from the project's
   **Overview** page.
7. Run `python -m tinytuya wizard`, paste in the Client ID/Secret and
   your region when prompted. It downloads every linked device's info to
   `devices.json`, including each fan's `id` (device ID) and `key`
   (`local_key`).
8. **The `ip` field in that output is often just the last-seen public/
   WAN-facing address, not reliably the real LAN IP.** Run
   `python -m tinytuya scan` separately to get each device's actual
   local IP directly, or set a DHCP reservation per fan on your router so
   it doesn't move.

### Part 2 — add the device in SmartThings

1. Accept the channel invite above and enroll your hub.
2. Install the driver ("Skyfan DC" or similar) from the channel.
3. In the SmartThings app: **Add Device → Scan Nearby** → "Skyfan DC" →
   add.
4. Open the new device's **settings** and fill in the real IP,
   `local_key`, and device ID from Part 1 (overwriting the obviously-fake
   placeholders). If this specific fan has no light kit fitted, also tick
   **"No Physical Light"** here. Save.
5. Polling starts automatically on save.
6. For additional fans, use the **"Add another fan"** button on any
   existing Skyfan device (in its settings, alongside the light toggle)
   rather than scanning again — repeat step 4 for each new device it
   creates.

## Why manual credential entry, not auto-discovery

Tuya devices do broadcast locally for discovery (a fixed encrypted UDP
format on ports 6666/6667), but SmartThings Edge Drivers can only bind a
socket to **port 0** (OS-assigned) — never a specific chosen port,
confirmed via a live `"forbidden"` error attempting to bind Tuya's actual
broadcast port, and verbatim in SmartThings' own LAN driver docs. That
blocks listening for the broadcast at the protocol level, not just as an
inconvenience — there's no code-level workaround. So every fan needs its
IP/key/ID entered once by hand; there's no way around it on this
platform. (Contrast with this account's other driver for a similarly
"dumb" fan, Big Ass Fans' Haiku series, also posted on this channel — that
one uses genuine mDNS, which SmartThings *does* natively support, so it's
fully zero-config. Not every LAN protocol is equally friendly here.)

## Protocol notes, for anyone extending this or hitting something similar

- Transport: TCP port 6668, protocol version **3.3**, AES-128-ECB
  encrypted payloads, CRC32 frame checksums. Crypto is hand-implemented
  in pure Lua (`lockbox`) since the Edge Driver sandbox has no native
  crypto.
- **If your fan's status reads work fine but every write (on/off, speed,
  etc.) silently times out**, check two things before assuming it's a
  network problem — this exact symptom cost a lot of debugging time here
  before being traced to the actual protocol layer, not the network:
  1. Protocol 3.2+ needs a 15-byte **clear** (unencrypted) header —
     3 ASCII version bytes (`"3.3"`) + 12 zero bytes — prepended to the
     ciphertext on every command *except* `DP_QUERY`/`DP_QUERY_NEW`. Easy
     to miss since reads work perfectly without it, which makes writes
     failing look like a connectivity issue rather than a framing one.
  2. Not every Tuya firmware implements the newer `CONTROL_NEW` (0x0D)
     command — some devices TCP-acknowledge it and then just never
     respond at the application layer. The older `CONTROL` (0x07) command
     is more broadly supported; worth trying if `CONTROL_NEW` goes
     nowhere. Confirmed by diffing raw wire bytes against
     [jasonacox/tinytuya](https://github.com/jasonacox/tinytuya)'s own
     successful write against the same hardware.
- Full DP (data point) schema — switch, speed, mode, direction, sleep
  timer, and the light's switch/brightness/color-temp-preset — is
  documented inline in `src/init.lua` and the README, pulled from Tuya's
  full Thing Model API rather than the filtered "standard function"
  endpoint (which only exposes a subset).

## Light kit handling

Some Skyfan units ship without the light kit. There's a per-device **"No
Physical Light"** preference that switches the device onto a second
profile with the light tile removed entirely, rather than showing dead
controls for hardware that isn't there. Set by hand per fan, same as the
IP/key/device ID and (optionally) the poll interval — nothing about this
driver auto-detects anything, everything's an explicit preference.

## Hiding the "Add Another Fan" button

Once every fan you own is added, the "Add another fan" button on each
device's screen is just clutter. A **"Hide 'Add Another Fan' Button"**
preference removes it the same way the light toggle removes the Light
tile — a separate, independent switch, so any combination of light/
no-light and button-shown/button-hidden works per device. Same manual,
per-fan preference as everything else here.

## Known limitations

- Local key retrieval genuinely requires the Tuya IoT Platform detour
  above — there's no way around this, it's not this driver being lazy,
  the key simply isn't exposed anywhere in the consumer app.
- No Wi-Fi provisioning — the fan needs to already be joined to your
  network via the Smart Life/Tuya app before this driver can do anything
  with it.
- Only tested against this one Skyfan DC model/dongle. If you hit
  something broken on a different variant, especially around the
  `CONTROL` vs `CONTROL_NEW` behavior above, I'd like to hear about it.

## Source

Happy to share the driver's source if anyone wants to read/modify it —
just ask. Same as the other
drivers on this channel, not posted inline here.
