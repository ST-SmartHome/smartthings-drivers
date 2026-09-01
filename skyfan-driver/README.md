# skyfan-tuya-lan

LAN Edge Driver for the Ventair Skyfan DC ceiling fan, controlling it over
its local Tuya TCP protocol (port 6668) rather than through Tuya's cloud —
same "local control, no cloud dependency" goal as the SolarEdge Modbus
driver, adapted for a proprietary encrypted protocol instead of an open
industrial one.

SmartThings Community post: https://community.smartthings.com/t/st-edge-lan-driver-ventair-skyfan-dc-ceiling-fan/310702

## Status: working end-to-end

Confirmed live against real hardware: connects, decrypts and parses status
correctly, and every command (fan on/off, speed, mode, direction, sleep
timer, light on/off, brightness, color temperature) has been tested.
Multi-fan support is done via an explicit "Add another fan" button rather
than automatic discovery — see Architecture.

Each fan's light is its own separate SmartThings device (a child device,
not a component) — done for Alexa visibility, since Alexa discovers by
device rather than by component. This happens automatically the first
time the driver restarts after a fan is added; no preference to toggle.

Deployed as `skyfan-tuya-lan`, driverId
`b079f7d0-c6fd-4704-b760-131a6b660307`, channel `Drivers`
(`781ea3f1-a95c-492f-9952-59ef19f43505`), installed on hub
`c215e4a2-98e7-4272-9cd8-ebf178079631`. 4 profile variants exist, chosen
automatically per-device from preferences and whether a light child has
been created — once a fan has a light child device, it lands on
`skyfan-dc-no-light.v2` or `skyfan-dc-no-light-no-addfan.v2` depending on
the `hideAddFan` preference; `skyfan-dc.v6`/`skyfan-dc-no-addfan.v1`
(both still carrying an inline `light` component) are only ever a
device's profile for the few seconds between first pairing and its light
child appearing.

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
| 3 | `fan_speed` | int | 1–5 | main `fanSpeed` (custom 5-label slider — see Changelog) |
| 8 | `fan_direction` | enum | forward/reverse | main `skyfanDirection` (stop-first safety interlock — see Changelog) |
| 15 | `light` | bool | — | light `switch` |
| 16 | `bright_value` | int | 1–5 | light `switchLevel` (scaled to 0–100%) |
| 19 | `work_mode` | enum | Coolwhite/Naturalwhite/Warmwhite | light `skyfanColorTemp` (custom 3-preset capability — this is a genuine push-button 3-state hardware setting, not a continuous dial, so the standard `colorTemperature` capability originally used here was replaced; see Changelog) |
| 22 | `countdown_set` | enum | cancel, 1h–12h | main `skyfanSleepTimer` |

## Architecture

- `config.yml` — `lan` + `discovery` permissions only. No `internet`
  permission exists on this platform at all (confirmed empirically, not
  just from docs — see `smartthings-edge-driver-gotchas` memory); don't
  design any feature around the driver calling out to a cloud API.
- `profiles/*.yml` — 4 variants (see Status above). The two `no-light`
  variants each have their own hand-assembled device-config
  (`metadata.vid`) — Skyfan's first, added specifically to override
  `fanSpeed`'s range/labels (see Changelog); the two light-having
  transient variants have no vid, just a cheaper embedded `config:` range
  override, since nothing rests on them long enough to justify more.
  - `main` — fan `switch`, `fanSpeed`, `refresh`, and the three custom
    fan-control capabilities (mode/direction/sleep timer).
  - `light` (only on the two transient variants) — `switch`,
    `switchLevel`, `skyfanColorTemp`.
  - `management` — just the `addAnotherFan` button, kept in its own
    trailing component specifically so it renders at the bottom of the
    device screen (component declaration order controls on-screen tile
    order).
  - `profiles/skyfan-light-child.v1.yml` — the auto-created light child
    device's own profile (`switch`, `switchLevel`, `skyfanColorTemp`).

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
  8 DPs plus the add-another-fan button, the light-child-device split,
  the direction-reversal safety interlock, status polling loop (wrapped
  in `pcall` — an uncaught error in the first poll before the recurring
  timer is registered would otherwise permanently kill auto-polling for
  that device, see gotchas memory).

## Known open items

- `countdown_set`'s real-world behavior on the physical fan hasn't been
  cross-checked against what the enum values actually do.
- Protocol 3.4 support isn't implemented — only needed if a fan is ever
  found that doesn't speak 3.3.

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

**2026-09-01 — fan-speed slider fix + direction-reversal safety
interlock.** The native fan speed range (DP3) is 1–5, but the app's
slider had never been overridden from the stock `fanSpeed` capability's
default 0–4 — meaning "Off" on the slider actually set speed to 1 (not
off), and the fan's true top speed was unreachable. Fixed via this
driver's first-ever hand-assembled device-config, overriding the range to
1–5 with proper labels (Low / Med-Low / Medium / Med-High / High).
Separately, `setDirection` now stops the fan and confirms it's actually
stopped before committing a reversal, instead of committing directly
while potentially still spinning — ported from a sibling driver after a
real incident there proved that omission was a genuine risk, not just a
theoretical one.

**2026-08-25/27 — each fan's light now gets its own separate SmartThings
device.** Alexa discovers by device, not by component, so a fan's light
was invisible to Alexa as long as it lived on the fan's own device. Every
fan with a physical light now automatically gets a child device the
first time the driver restarts after updating. A related bug (4 of 5
light-having fans stuck showing duplicate light controls after rollout)
needed a full hub reboot to resolve — the driver process wasn't actually
restarting on a plain redeploy. Also fixed the same week: `skyfanColorTemp`
had no capability presentation defined at all, silently falling back to a
bare cycling button instead of a real Warm/Natural/Cool White picker.

**2026-08-20 — root cause found and fixed for a long-standing, hard-to-
diagnose write-command failure.** Fan speed/switch/light commands would
silently time out while status reads always worked — an extensive
investigation ruled out the network, hub, firewall, and cloud auth before
finding two real protocol bugs: a missing required Tuya-protocol header
on writes, and this fan's firmware not implementing the `CONTROL_NEW`
command at all (needed the older `CONTROL`). Both fixed, confirmed via a
standalone reference-implementation diff, a Lua test harness, live
logcat, and physical confirmation on multiple real fans.

**2026-08-18/19 — no-light profile support added**, plus two real
profile-switch bugs fixed (a repeating dialog, then a genuine infinite
oscillation) — both from re-evaluating the profile switch outside
`device_init`.

**2026-08-18 — light color control rebuilt** as a custom 3-preset
capability, since the real hardware is a 3-state push-button, not a
continuous dial.

**2026-08-04 — initial bring-up complete**, confirmed working end-to-end
against real hardware.
