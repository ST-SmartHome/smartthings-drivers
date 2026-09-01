# skyfan-tuya-lan

LAN Edge Driver for the Ventair Skyfan DC ceiling fan, controlling it over
its local Tuya TCP protocol (port 6668) rather than through Tuya's cloud —
same "local control, no cloud dependency" goal as the SolarEdge Modbus
driver, adapted for a proprietary encrypted protocol instead of an open
industrial one.

SmartThings Community post: https://community.smartthings.com/t/st-edge-lan-driver-ventair-skyfan-dc-ceiling-fan/310702

## Status: working end-to-end

Confirmed live against the real device: connects, decrypts and parses
status correctly, and every command (fan on/off, speed, mode, direction,
sleep timer, light on/off, brightness, color temperature) has been tested.
All three custom capability tiles (mode/direction/sleep timer) render
correctly in the app. Multi-fan support is done via an explicit "Add
another fan" button rather than automatic discovery — see Architecture.

Deployed as `skyfan-tuya-lan`, driverId
`b079f7d0-c6fd-4704-b760-131a6b660307`, channel `Drivers`
(`781ea3f1-a95c-492f-9952-59ef19f43505`), installed on hub
`c215e4a2-98e7-4272-9cd8-ebf178079631`. Several profile variants now exist
(`skyfan-dc[-no-light][-no-addfan].v1`, plus `skyfan-light-child.v1` for the
auto-created light devices — see Changelog), chosen automatically per-device
from preferences and whether a light child has been created, not a single
fixed profile.

Each fan's light is automatically split into its own child SmartThings
device (see the 2026-08-25 Changelog entry) — no action needed, this just
happens on first driver restart after updating.

**Deploy workflow** (repackaging requires all three steps, every time —
`install` alone on an already-installed driver is a no-op):
```bash
smartthings edge:drivers:package .
smartthings edge:channels:assign <driverId> <version> --channel <channelId>
smartthings edge:drivers:install <driverId> --hub <hubId> --channel <channelId>
```

## Device facts (verified via Tuya Cloud API, not guessed)

The driver was built and tested against a real physical fan — credentials
(local IP, `local_key`, device ID) aren't reproduced here since they're
per-device secrets, not something reusable by anyone reading this repo.
Real values live only in your own device preferences (set via the app) —
re-run the Tuya Cloud API device list (see "Adding a fan" below) if you
ever need them again.

Full DPS schema (from Tuya's Thing Model, not the filtered "standard
function" endpoint, which only showed 4 of these 8):

| DP ID | Code | Type | Values | Capability |
|---|---|---|---|---|
| 1 | `switch` | bool | — | main `switch` |
| 2 | `mode` | enum | Normal/ECO/Sleep | main `skyfanMode` |
| 3 | `fan_speed` | int | 1–5 | main `fanSpeed` |
| 8 | `fan_direction` | enum | forward/reverse | main `skyfanDirection` |
| 15 | `light` | bool | — | light `switch` |
| 16 | `bright_value` | int | 1–5 | light `switchLevel` (scaled to 0–100%) |
| 19 | `work_mode` | enum | Coolwhite/Naturalwhite/Warmwhite | light `skyfanColorTemp` (custom 3-preset capability — this is a genuine push-button 3-state hardware setting, not a continuous dial, so the standard `colorTemperature` capability originally used here was replaced; see Changelog) |
| 22 | `countdown_set` | enum | cancel, 1h–12h | main `skyfanSleepTimer` |

## Architecture

- `config.yml` — `lan` + `discovery` permissions only. No `internet`
  permission exists on this platform at all (confirmed empirically, not
  just from docs — see `smartthings-edge-driver-gotchas` memory); don't
  design any feature around the driver calling out to a cloud API.
- `profiles/skyfan-dc.yml` — three components:
  - `main` — fan `switch`, `fanSpeed`, `refresh`, and the three custom
    fan-control capabilities (mode/direction/sleep timer).
  - `light` — `switch`, `switchLevel`, `skyfanColorTemp`
    (present only until a fan's light child is created — see below).
  - `management` — just the `addAnotherFan` button, kept
    in its own trailing component specifically so it renders at the
    bottom of the device screen (component declaration order controls
    on-screen tile order).
- `profiles/skyfan-light-child.v1.yml` — the auto-created light child
  device's own profile (`switch`, `switchLevel`,
  `skyfanColorTemp`). Every fan with a physical light
  automatically gets one of these as a separate SmartThings device (DNI
  `<parent-dni>-light`), so the light is visible to Alexa, which discovers
  by device rather than by component. The parent fan device then migrates
  off its own `light` component onto a light-less profile variant — see
  the 2026-08-25 Changelog entry for the full mechanism.

  5 preferences: IP, local_key, device ID, protocol version, poll
  interval — every one has an obviously-fake placeholder `default`, which
  the profile schema requires even for per-device secrets (see gotchas
  memory for why).
- `src/discovery.lua` — creates exactly one device the first time
  discovery ever fires for this driver, then does nothing automatically
  on every subsequent fire (discovery re-fires repeatedly in the
  background for the driver's whole lifetime, confirmed via logcat).
  Every additional fan is created by the explicit "Add another fan"
  button instead — pattern borrowed from the community driver
  `toddaustin07/edge_WLED`, each new device getting a guaranteed-unique
  timestamp-based DNI (`skyfan-dc-tuya-<epoch>-<random>`). A bounded
  numbered-slot approach was tried first and rejected as bad UX (spams
  users with tiles for fans they don't have).
- `src/lockbox.lua` — bundled pure-Lua crypto library (Ross Tyler's
  SmartThings-Edge-compatible fork of lua-lockbox), providing AES-128,
  ECB/CBC modes, PKCS7 padding, MD5, SHA256, HMAC. SmartThings' sandbox
  has no native crypto; this is a confirmed-working, already-shipped-in-
  other-drivers library, not a hand-rolled implementation.
- `src/crc32.lua` — hand-rolled (not from lockbox, which doesn't include
  it) — standard table-based CRC-32, non-cryptographic, used for Tuya's
  message frame checksums in protocol 3.1–3.3.
- `src/tuya_protocol.lua` — message framing (magic prefix, sequence,
  command, length, encrypted payload, checksum, suffix) and AES-ECB
  encrypt/decrypt. Implements protocol **3.3**, confirmed correct against
  the live device.
- `src/tuya_client.lua` — one-connection-per-request TCP client (connect,
  send, read, close), mirroring the SolarEdge Modbus client's structure.
- `src/init.lua` — lifecycle handlers, capability command handlers for all
  8 DPs plus the add-another-fan button, status polling loop (wrapped in
  `pcall` — an uncaught error in the first poll before the recurring timer
  is registered would otherwise permanently kill auto-polling for that
  device, see gotchas memory).

## Bugs found and fixed

Profile validation / packaging:

1. Custom capability enum attributes needed an explicit `default` value in
   their schema — omitting it produced a generic `"default cannot be
   null"` error with no indication of which field was the problem. Found
   by bisecting the profile down to a minimal version and adding pieces
   back one at a time.
2. **Every** device preference needs a `default`, even ones with no
   sensible universal value (`localKey`, `deviceId` are per-device secrets/
   IDs) — same generic error. Fixed with obviously-fake placeholders
   (`"0000000000000000"` etc.) and descriptions telling the user to
   replace them.
3. Enumeration preference option **keys** must match `^\w+$` (word
   characters only) — `"3.3"`/`"3.4"` contain a period and were rejected.
   Changed to `v33`/`v34` as keys, with `"3.3"`/`"3.4"` as the display
   labels.

Protocol / Lua:

4. PKCS7 padding API misuse — `lockbox.padding.pkcs7` is a bare function,
   not an object with `.pad`/`.unpad` methods. Fixed by using
   `cipher.setPadding(PKCS7)` + an argless `.finish()`, and stripping
   padding by hand after decrypt.
5. Device-response framing case: some responses carry a clear 4-byte
   `retcode` field before the ciphertext, distinct from the documented
   15-byte "3.3" source header — detected by noticing decrypted payload
   length wasn't a clean multiple of 16, fixed by checking
   `#encrypted % 16 == 4` and stripping those 4 bytes when present.

Capability presentation:

6. The three custom fan-control capabilities were silently missing from
   the app's device screen because their presentations lacked top-level
   `dashboard`/`automation` keys (only `detailView` was set) — a custom
   capability with an incomplete presentation gets skipped by the
   auto-generated `detailView` builder, without any error. Fixed by
   adding empty `dashboard`/`automation` objects to each presentation.
   Getting the fix to actually show up additionally required reordering
   the capability list in the profile YAML (a name-only version bump
   wasn't enough — the auto-generated view is content-hashed by the
   capability set, not the profile name). Full story in the
   `smartthings-edge-driver-gotchas` memory.

## Known open items

- Some fans report `product_name: "Skyfan DC-no light"` via the Tuya
  Cloud API (vs. `"decomin-3 ceilingfan"` for the rest) — whether this
  driver's single profile (which always shows light controls) degrades
  gracefully on those units, or just shows dead controls, is untested.
- `countdown_set`'s real-world meaning: exposed as a raw enum
  (cancel/1h–12h) via the custom `skyfanSleepTimer` capability. Not
  cross-checked against how the fan actually behaves when set.
- Protocol 3.4 support (payload version-header prefix, HMAC-SHA256
  instead of CRC32 checksum) isn't implemented — only needed if a fan is
  ever found that doesn't speak 3.3. None found so far.

## Adding a fan (in the SmartThings app)

**Getting the IP/local_key/device ID first**: this driver doesn't include
a credential-lookup tool, since that needs your own Tuya IoT Platform
project's client ID/secret — real API credentials that don't belong in a
shared repo. Use [jasonacox/tinytuya](https://github.com/jasonacox/tinytuya)
directly (`pip install tinytuya`, then `python -m tinytuya wizard`) to pull
each fan's `local_key`/device ID/IP from the Tuya Cloud API — it's the
actively-maintained, full-featured version of the same Cloud-API flow this
driver's protocol layer was reverse-engineered against.

> **Don't use the Cloud API's `ip` field as the device's local IP.** It
> reports the address Tuya's servers last saw the device connect *from*,
> which is your router's public WAN IP, not the fan's LAN address — the
> `local_key`/device ID from this lookup are what you need from the cloud
> side, but the actual local IP still has to come from your own network
> (router/AP client list, by MAC address).

First fan: **Add Device → Scan Nearby** → "Skyfan DC" → add → device
settings → fill in the real IP/local_key/device ID (overwriting the
placeholders) → save. Polling starts automatically.

Every fan after that: use the **"Add another fan"** button on any existing
Skyfan device, then configure the new device's preferences the same way.

Watch live with:
```bash
smartthings edge:drivers:logcat b079f7d0-c6fd-4704-b760-131a6b660307 --hub-address <your-hub-ip> --token <pat>
```

## Changelog

**2026-08-25 — each fan's light now gets its own separate SmartThings
device, plus a real capability-presentation bug fixed.**

- **Light split into a child device (for Alexa).** Alexa discovers by
  device, not by component, so a fan's light was invisible to Alexa as
  long as it lived on the fan's own device. Every fan with a physical
  light now automatically gets a child device (profile
  `skyfan-light-child.v1`) the first time the driver restarts after
  updating — no preference to toggle, no manual action. The parent fan
  device keeps everything else (speed, mode, direction, sleep timer);
  the light child only handles switch/brightness/color-temp preset. The
  parent's regular poll cycle pushes fresh status to the child too, so
  this doesn't add a second TCP connection per cycle. If you see a new
  device appear next to an existing fan after updating, that's expected
  — it's the light, not a duplicate fan. (Ported from the same fix
  already shipped on a sibling driver in this account.)
- **`skyfanColorTemp` had no capability presentation defined at all** —
  confirmed via a direct API check (`404 Capability Presentation is not
  found`). SmartThings' fallback for an unpresented custom capability is
  a single button with no value picker, which is what was actually
  showing up in the app as a button that just cycles through colors with
  no way to pick one directly. Fixed with a proper `displayType: list`
  3-option presentation (Warm White / Natural White / Cool White),
  matching the working `skyfanMode`/`skyfanDirection` tiles.

No changes to existing fan speed/mode/direction/sleep-timer behavior.
Both changes apply automatically once the driver update reaches your
hub.

**2026-08-20 — root cause found and fixed for a long-standing, hard-to-diagnose
write-command failure.** Symptom: fan speed/switch/light commands would
silently time out (`header receive failed: timeout`) while status reads
always worked fine — looked exactly like a network/hub problem, and an
extensive investigation ruled out the router, the SmartThings hub,
firewall/IPS, Tuya cloud auth, and this driver's own code being stale, all
with hard evidence, before the real cause was found. Two real protocol
bugs, both required together:
- `Tuya.encode()` never added the 15-byte clear (unencrypted) header —
  `"3.3"` + 12 zero bytes — that Tuya protocol 3.2+ requires on every
  command except `DP_QUERY`/`DP_QUERY_NEW`. `decode()` already knew to
  *strip* this header from incoming responses; it was just never *added*
  to outgoing writes.
- These fans' firmware doesn't implement the `CONTROL_NEW` (0x0D) command
  at all — it silently TCP-acknowledges the frame and never sends an
  application response. Switched `TuyaClient.set_dps` to the older
  `CONTROL` (0x07), which this firmware does support.

Found by running a real reference implementation
([jasonacox/tinytuya](https://github.com/jasonacox/tinytuya)) standalone
against a physical fan and diffing its successful write's raw wire bytes
against this driver's failing one. Confirmed fixed via a standalone
Lua test harness (this driver's own protocol code run outside
SmartThings entirely), then via live `logcat` showing genuine DP value
changes on command, then via physical confirmation on multiple real
fans. Full technical writeup in the `skyfan-driver-project-status`
auto-memory entry if this ever needs revisiting.

**2026-08-18/19 — no-light profile support added** for the physical units
with no light fixture: a `noLight` boolean preference switches the device
onto a second profile (`skyfan-dc-no-light.v1`) with the `light` component
omitted entirely. Two real bugs surfaced and were fixed along the way — a
repeating "capabilities changed" dialog, then a genuine infinite
oscillation between the two profiles every ~5s — both caused by comparing
`device.profile.id` (a UUID) against a profile name and/or re-evaluating
the switch from `info_changed` (which `try_update_metadata` itself appears
to re-trigger). Fixed by moving all profile-switch logic to run only from
`device_init` (once per driver restart), never from `info_changed`.

**2026-08-18 — light color control rebuilt.** The standard `colorTemperature`
capability was replaced with a custom 3-preset capability
(`skyfanColorTemp`), since the real hardware is a 3-state
push-button (Warmwhite/Naturalwhite/Coolwhite), not a continuous dial —
see the DPS table above.

**2026-08-04 — initial bring-up complete**, confirmed working end-to-end
against real hardware; see "Bugs found and fixed" above for the
crypto/framing/presentation issues hit along the way.
