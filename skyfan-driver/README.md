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
Multi-fan support is an explicit "Add another fan" button rather than
automatic discovery — see Architecture.

Each fan's light is its own separate SmartThings device (a child device,
not a component) — done for Alexa visibility, since Alexa discovers by
device rather than by component. This happens automatically the first
time the driver restarts after a fan is added.

Deployed as `skyfan-tuya-lan`, distributed via a SmartThings channel
invite (see the Community thread above). 4 profile variants exist, chosen
automatically per-device from preferences and whether a light child has
been created — once a fan has a light child, it lands on
`skyfan-dc-no-light.v2` or `skyfan-dc-no-light-no-addfan.v2` depending on
`hideAddFan`; the two variants still carrying an inline `light` component
are only ever a device's profile for the few seconds between first
pairing and its light child appearing.

## Device facts (verified via Tuya Cloud API)

Credentials (local IP, `local_key`, device ID) aren't reproduced here —
they're per-device secrets, not reusable by anyone reading this repo. Set
real values via your own device preferences in the app; re-run the Tuya
Cloud API device list (see "Adding a fan" below) if you need them again.

Full DPS schema (from Tuya's Thing Model, not the filtered "standard
function" endpoint, which only showed 4 of these 8):

| DP ID | Code | Type | Values | Capability |
|---|---|---|---|---|
| 1 | `switch` | bool | — | main `switch` |
| 2 | `mode` | enum | Normal/ECO/Sleep | main `skyfanMode` |
| 3 | `fan_speed` | int | 1–5 | main `fanSpeed` (custom 5-label slider) |
| 8 | `fan_direction` | enum | forward/reverse | main `skyfanDirection` (stop-first safety interlock) |
| 15 | `light` | bool | — | light `switch` |
| 16 | `bright_value` | int | 1–5 | light `switchLevel` (scaled to 0–100%) |
| 19 | `work_mode` | enum | Coolwhite/Naturalwhite/Warmwhite | light `skyfanColorTemp` (custom 3-preset capability) |
| 22 | `countdown_set` | enum | cancel, 1h–12h | main `skyfanSleepTimer` |

## Architecture

- `config.yml` — `lan` + `discovery` permissions only. No `internet`
  permission exists on this platform at all — don't design around the
  driver calling a cloud API.
- `profiles/*.yml` — 4 variants (see Status). The two `no-light` variants
  each have a hand-assembled device-config (`metadata.vid`) overriding
  `fanSpeed`'s range/labels; the two transient light-having variants use
  a cheaper embedded `config:` range override instead, since nothing
  rests on them long enough to justify more.
  - `main` — fan `switch`, `fanSpeed`, `refresh`, plus the three custom
    fan-control capabilities (mode/direction/sleep timer).
  - `light` (transient variants only) — `switch`, `switchLevel`,
    `skyfanColorTemp`.
  - `management` — just `addAnotherFan`, kept in its own trailing
    component so it renders at the bottom of the device screen.
  - `profiles/skyfan-light-child.v1.yml` — the light child device's own
    profile (`switch`, `switchLevel`, `skyfanColorTemp`).

  5 preferences: IP, local_key, device ID, protocol version, poll
  interval — each has an obviously-fake placeholder `default`, required
  by the profile schema even for per-device secrets.
- `src/discovery.lua` — creates one device the first time discovery ever
  fires, then no-ops on every later fire. Every additional fan comes from
  the "Add another fan" button instead (pattern borrowed from
  `toddaustin07/edge_WLED`), each getting a timestamp-based DNI
  (`skyfan-dc-tuya-<epoch>-<random>`) — a bounded numbered-slot approach
  was tried first and rejected (spams tiles for fans you don't have).
- `src/lockbox.lua` — bundled pure-Lua crypto (Ross Tyler's
  SmartThings-Edge-compatible fork of lua-lockbox): AES-128, ECB/CBC,
  PKCS7, MD5, SHA256, HMAC. The sandbox has no native crypto.
- `src/crc32.lua` — hand-rolled table-based CRC-32 (lockbox doesn't
  include it), used for Tuya's frame checksums in protocol 3.1–3.3.
- `src/tuya_protocol.lua` — message framing (magic/sequence/command/
  length/encrypted payload/checksum/suffix) and AES-ECB encrypt/decrypt.
  Implements protocol **3.3**.
- `src/tuya_client.lua` — one-connection-per-request TCP client, mirrors
  the SolarEdge Modbus client's structure.
- `src/init.lua` — lifecycle handlers, command handlers for all 8 DPs
  plus add-another-fan, the light-child split, the direction-reversal
  safety interlock, and the polling loop (wrapped in `pcall` — an
  uncaught error before the recurring timer registers would otherwise
  permanently kill auto-polling for that device).

## Known open items

- `countdown_set`'s real-world behavior hasn't been cross-checked against
  what the enum values actually do.
- Protocol 3.4 isn't implemented — only needed if a fan is found that
  doesn't speak 3.3.

## Adding a fan (in the SmartThings app)

**Getting the IP/local_key/device ID first**: this driver has no
credential-lookup tool of its own (that needs your own Tuya IoT Platform
client ID/secret). Use [jasonacox/tinytuya](https://github.com/jasonacox/tinytuya)
(`pip install tinytuya`, then `python -m tinytuya wizard`) to pull each
fan's `local_key`/device ID/IP from the Tuya Cloud API.

> **Don't use the Cloud API's `ip` field as the local IP** — it's the
> address Tuya's servers last saw the device connect *from* (your
> router's public WAN IP), not the fan's LAN address. Get the real local
> IP from your own network (router/AP client list, by MAC).

First fan: **Add Device → Scan Nearby** → "Skyfan DC" → add → device
settings → fill in the real IP/local_key/device ID → save. Polling starts
automatically.

Every fan after that: use **"Add another fan"** on any existing Skyfan
device, then configure the new device's preferences the same way.

## Changelog

- **2026-09-02** — Light-child creation is now gated on a live DP-15
  probe (creates unconditionally only if the query fails or the fan
  positively lacks the light DP), instead of always creating one. Also
  found and fixed a real bug from the day before: the 09-01 profile bump
  never updated the driver's own hardcoded profile-ID constants, so the
  fan-speed fix was silently never actually applied to any device
  regardless of redeploys. Both confirmed live end-to-end.
- **2026-09-01** — Fan-speed slider fixed to the fan's real 1–5 range
  (was defaulting to the stock capability's 0–4, making "Off" actually
  set speed 1 and leaving true top speed unreachable) via this driver's
  first hand-assembled device-config. Added a stop-first safety interlock
  to direction changes, ported from a sibling driver after a real
  spinning-reversal incident there.
- **2026-08-25/27** — Each fan's light now gets its own child device
  (Alexa discovers by device, not component), created automatically on
  first restart after updating. Fixed a rollout bug needing a full hub
  reboot to clear duplicate light controls, and a missing
  `skyfanColorTemp` presentation that had silently fallen back to a bare
  cycling button.
- **2026-08-20** — Root-caused a long-standing silent write-command
  timeout (reads always worked, writes never did) to two real protocol
  bugs: a missing required Tuya header on writes, and this fan's firmware
  not implementing `CONTROL_NEW` at all (needed the older `CONTROL`).
- **2026-08-18/19** — No-light profile support added, plus two
  profile-switch bugs (a repeating dialog, then a genuine infinite
  oscillation) fixed by moving the switch logic outside `device_init`.
- **2026-08-18** — Light color control rebuilt as a custom 3-preset
  capability — the real hardware is a 3-state push-button, not a
  continuous dial.
- **2026-08-04** — Initial bring-up complete, confirmed working
  end-to-end against real hardware.
