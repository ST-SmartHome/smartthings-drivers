# bigassfans-i6-lan

LAN Edge Driver for Big Ass Fans Haiku H/I Series ceiling fans, controlling
them over their local "i6" protocol (SLIP-framed protobuf over TCP, port
31415) — no cloud dependency, no authentication of any kind.

SmartThings Community post: https://community.smartthings.com/t/st-edge-driver-big-a-fans-haiku-h-i-series-via-local-i6-protocol/310526

## Status: working end-to-end

Deployed as `bigassfans-i6-lan`, driverId
`e39b708d-4db9-4c7b-a76c-0d04e5fdcdd9`, channel `Drivers`
(`781ea3f1-a95c-492f-9952-59ef19f43505`), hub
`c215e4a2-98e7-4272-9cd8-ebf178079631` — same channel/hub as
other drivers in this account. Current profile: `bigassfans-h.v1`.

Both known fans (same model "Haiku H/I Series", firmware 3.3.7,
api_version 8) were auto-discovered via mDNS on the first
scan and confirmed fully working: every capability (fan switch/speed/mode/
direction/whoosh/eco, light switch/brightness) reads and writes correctly
against the real devices.

## Protocol details (confirmed empirically against two real fans, not from docs alone)

- **Transport**: plain TCP to port 31415, one connection per request.
- **Framing**: SLIP (RFC 1055) — `0xC0` start/end delimiters, `0xDB`
  escape sequences for literal `0xC0`/`0xDB` bytes in the payload.
- **Payload**: proto2 protobuf, `Root{ root2: Root2{ query | commit } }`.
  Full schema in `src/baf_protocol.lua`'s `FIELDS` table and comments;
  originally sourced from `jfroy/aiobafi6`'s `proto/aiobafi6.proto`.
- **Querying is category-scoped, and the "ALL" category is misleadingly
  named** — confirmed by direct probing, not documented anywhere: `ALL`
  only returns general/identity properties (model, firmware_version,
  mac_address, api_version). Fan properties need a `FAN`-category query,
  light properties a `LIGHT`-category query. This driver queries both
  every poll cycle.
- **Missing fields mean "at default"**: the firmware omits bool/enum
  fields that are at their zero value (OFF/false) rather than sending them
  explicitly, even in a full category response. `baf_protocol.lua`'s
  `parse_category_result` fills in known defaults for anything the
  category didn't mention, rather than leaving them nil.
- **Discovery**: mDNS service `_api._tcp`, domain `local`. TXT records
  include `model`, `uuid`, `name`, `api version`. Because `_api._tcp` is a
  very generic service name, every mDNS candidate is filtered on its TXT
  `model` record actually containing "Haiku" before a device gets
  created — not just on the service type matching.

### Known `Properties` field numbers

Field numbers from the fan's proto2 `Properties` message (`aiobafi6.proto`
plus fields confirmed empirically that aren't in the public reference
schema at all). "Category" is which `Query` reaches it directly — `MORE
push-only` means it's never returned by any direct query, only pushed
unsolicited after a commit on a connection that opened with an identity
query first (see `BafClient.commit_and_verify_more`).

| No. | Name | Kind | Category | Meaning |
|---|---|---|---|---|
| 1 | `name` | string | ALL | Fan's configured name |
| 2 | `model` | string | ALL | Hardware model string (e.g. "Haiku H/I Series") |
| 7 | `firmware_version` | string | ALL | e.g. "3.3.7" |
| 8 | `mac_address` | string | ALL | Fan's MAC address |
| 13 | `api_version` | string | ALL | e.g. "8" |
| 43 | `fan_mode` | enum | FAN | Off/On/Auto |
| 44 | `reverse_enable` | bool | FAN | Direction (false=forward, true=reverse). Confirmed to apply with unpredictable delay, sometimes minutes — see the direction-control section below |
| 45 | `speed_percent` | int | FAN | Fan speed as 0–100% |
| 46 | `speed` | int | FAN | Fan speed, native 0–7 range |
| 52 | `motion_sense_enable` | bool | FAN | Motion/occupancy sensing master enable. Only takes effect while `fan_mode = AUTO`. Confirmed working — write applies immediately, not delayed |
| 53 | `motion_sense_timeout` | int (seconds) | FAN | How long to keep running after motion stops, once triggered by occupancy (confirmed 7200 = 2 hours on one fan's setting) |
| 58 | `whoosh_enable` | bool | FAN | Confirmed to apply with unpredictable delay, sometimes minutes — same caveat as `reverse_enable` |
| 64 | `current_rpm` | int | FAN | Live motor RPM, read-only telemetry |
| 65 | `eco_enable` | bool | FAN | Confirmed not instant — typically ~1–2 minutes to apply |
| 66 | `fan_occupancy_detected` | bool | FAN | Read-only — whether the fan currently detects motion in the room |
| 68 | `light_mode` | enum | LIGHT | Off/On/Auto |
| 69 | `light_brightness_percent` | int | LIGHT | 0–100%, maps directly to the app's brightness slider |
| 98 | `sleep_mode_enable` | bool | MORE push-only | Sleep Mode master toggle (a real physical remote button) |
| 100/101/110/111/112 | — | — | MORE push-only | Seen alongside field 98 in the same push burst, suspected to be Sleep Mode's other sub-settings (fan/light preset, Wake Up behavior) — **not individually confirmed**, deliberately not implemented until they are |
| 134 | `led_indicators_enable` | bool | MORE push-only | LED indicators on/off |
| 135 | `fan_beep_enable` | bool | MORE push-only | Fan beep on/off |
| 136 | `legacy_ir_remote_enable` | bool | MORE push-only | Legacy IR remote support on/off |

Separately, `QueryResult.schedules` (field 3, unmodeled in every public
reference project) carries a `Schedule` message per configured on-device
schedule — its own `action` sub-field uses field numbers 5 (light mode
enum) and 18 (`light_auto_motion_timeout` in seconds) when the light
action is Auto. These live inside a completely different nested message
from the `Properties` table above — the field numbers coincidentally
overlapping with unrelated `Properties` fields is not a conflict, just
two independent numbering spaces. The schedule **write** path (creating/
editing a schedule entry) remains completely unknown — see Known open
items.

## Architecture

- `config.yml` — `lan` + `discovery` permissions.
- `search-parameters.yml` — gates the hub's pre-scan on the `_api._tcp`
  mDNS service, so `discovery_handler` only fires when something matching
  is actually present.
- `profiles/bigassfans-h.yml` — three components:
  - `main` — `switch`, `fanSpeed` (native range 0–7, not a percentage),
    `refresh`, and three custom capabilities: `fanMode` (Off/On/Auto),
    `fanDirection` (Forward/Reverse), `whoosh` (Off/On), `ecoMode`
    (Off/On).
  - `light` — `switch`, `switchLevel` (0–100%, maps directly to the
    device's own `light_brightness_percent` field, no scaling needed).
  - `management` — `aboutisland47519.addAnotherFan`, the same custom
    capability (and already-correct presentation) reused from
    another driver in this workspace — capability IDs are account-wide,
    not per-driver.
  - One preference: "Manual IP Override" (`ipAddress`, sentinel
    `0.0.0.0` meaning "use the mDNS-discovered address"), plus
    `pollInterval`. No secrets to enter — see protocol notes above.
- `src/slip.lua` — SLIP encode/decode.
- `src/protobuf.lua` — minimal hand-written protobuf wire codec (varint +
  length-delimited encode/decode). Not a general protobuf library — just
  enough for this schema; no packed-repeated or 32/64-bit fixed type
  support, since BAF's schema never uses them.
- `src/baf_protocol.lua` — builds Query/Commit messages and parses
  QueryResult responses into flat property tables, using the field-number
  schema from `aiobafi6.proto`.
- `src/baf_client.lua` — TCP client: connect, send a SLIP frame, read the
  response frame byte-by-byte until the closing delimiter (SLIP has no
  length prefix to read ahead by), close.
- `src/discovery_mdns.lua` — wraps `st.mdns.discover`, decodes TXT
  records, filters for real BAF fans, returns candidates keyed by a DNI
  derived from the fan's own `uuid` TXT record (stable across DHCP IP
  changes, unlike a DNI derived from the IP itself).
- `src/discovery.lua` — orchestrates device creation for new candidates
  and **self-heals the persisted IP** of already-known devices if mDNS
  reports a different current address (unless the user has set a real
  "Manual IP Override" value, which always wins). Also exposes
  `create_another` for the manual-fallback button.
- `src/init.lua` — lifecycle handlers, all capability command handlers,
  polling (queries `FAN` then `LIGHT` each cycle, wrapped in `pcall` — an
  uncaught error here would otherwise stop the recurring poll timer from
  ever registering, silently killing polling for good, not just for one
  cycle).

## Development approach: verify offline before touching the hub

Every protocol layer (SLIP framing, protobuf encode/decode, category-query
parsing, the TCP client's byte-by-byte frame reader) was unit-tested
against **real bytes captured from the actual fans** using a Lua 5.4
interpreter extracted locally via `apt-get download lua5.4 liblua5.4-0` +
`dpkg-deb -x` (no root needed) — before any of it was ever packaged or
deployed to the hub. This is a different, cheaper development loop than earlier drivers in
this workspace used, which iterated live against the hub via `logcat`
from early on. Worth reusing for future protocol-heavy drivers: get a
local interpreter, capture real traffic with a throwaway Python probe
script, and unit-test the Lua wire-format code against it directly.

## Known open items

- Only tested against two real fans, both the same model/firmware.
  Behavior on other Haiku/i6 models (e.g. ones without a light kit) is
  unconfirmed.
- `setFanSpeed` also sets `fan_mode` (nonzero speed → ON, zero → OFF) —
  a UX judgment call, not a confirmed device behavior. The protocol keeps
  `speed` and `fan_mode` as genuinely separate properties; whether the
  firmware itself couples them isn't verified.
- Whoosh/eco/comfort-mode interactions with each other aren't modeled or
  tested — e.g. what happens if eco and whoosh are both on.
- Fields seen in real `FAN` responses but not in the reference `.proto`
  (e.g. field 207) are silently ignored — likely properties added by
  firmware newer than the library's schema capture, harmless to ignore
  for this driver's scope.
- mDNS reflection across VLANs depends on a "Multicast DNS" or similar
  setting on your router/controller (exact name and location vary) —
  confirmed enabled network-wide on the network this was tested on, but
  not empirically tested with a fan actually segmented onto a different
  VLAN from the hub (both fans tested are on the same network as each
  other and, presumably, the hub).
- Fields 100/101/110/111/112, suspected Sleep Mode sub-settings, aren't
  individually confirmed — see the field table above.
- No write path exists for the fan's own on-device schedule (creating or
  editing a schedule entry) — only reading an already-configured
  schedule is implemented. No known `Commit{schedules}` equivalent to
  the `Commit{properties}` path used for everything else in this driver.
- Motion sensing (field 52) is implemented at the protocol level and
  confirmed working, but isn't exposed as a SmartThings capability yet —
  no command handler wired up in `init.lua`.
